// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BitMath} from "@uniswap/v4-core/src/libraries/BitMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

interface IUniswapV2PairReserves {
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
}

/**
 * @notice The pool-reading arithmetic of FusingQuotePricer, deployed once as
 * an external library and reached by delegatecall. Moved out of the pricer
 * for size alone: with V2 pairs, taxed quotes and oracle stocks the pricer
 * outgrew the 24,576-byte contract limit, and this is its largest
 * self-contained block. Every function is `view` and reads only what the
 * pricer passes in; the logic is byte for byte what the pricer ran inline,
 * and the pricer's own comments on why it measures the way it does stay
 * with the call sites there.
 */
library FusingPoolDepth {
    using StateLibrary for IPoolManager;

    /// @dev The measured band: 500 bps of the square root of the price, about 10.25% of the price.
    uint256 internal constant DEPTH_SQRT_WINDOW_BPS = 500;
    uint256 private constant BASIS_POINTS = 10_000;
    /// @dev How many bitmap words to walk looking for the nearest initialized tick.
    uint256 private constant MAX_BITMAP_WORDS = 5;

    /**
     * @notice The amount of `side` a V4 pool really holds in range within
     * the measured band, scaled to the units a V3 `balanceOf` reports and
     * capped at the constant-product virtual reserve. See the pricer.
     */
    function v4Depth(
        IPoolManager poolManager,
        PoolId id,
        PoolKey memory key,
        address side,
        uint160 sqrtPriceX96,
        int24 tick,
        uint128 liquidity
    ) public view returns (uint256 depth) {
        int24 spacing = key.tickSpacing;
        if (spacing <= 0) return 0;

        bool sideIsCurrency0 = side == Currency.unwrap(key.currency0);
        uint256 move = (uint256(sqrtPriceX96) * DEPTH_SQRT_WINDOW_BPS) / BASIS_POINTS;
        if (move == 0) return 0;

        uint256 virtualReserve = sideIsCurrency0
            ? FullMath.mulDiv(liquidity, 1 << 96, sqrtPriceX96)
            : FullMath.mulDiv(liquidity, sqrtPriceX96, 1 << 96);

        uint256 inRange;
        if (sideIsCurrency0) {
            // Currency0 drains out of the pool as the price climbs.
            uint256 raised = uint256(sqrtPriceX96) + move;
            uint160 window = raised > TickMath.MAX_SQRT_PRICE ? TickMath.MAX_SQRT_PRICE : uint160(raised);
            uint160 edge = _liquidityEdge(poolManager, id, tick, spacing, true);
            // The active liquidity spans the entire band: the scaled figure
            // equals the constant-product one exactly.
            if (edge >= window) return virtualReserve;
            if (edge <= sqrtPriceX96) return 0;
            inRange = SqrtPriceMath.getAmount0Delta(sqrtPriceX96, edge, liquidity, false);
        } else {
            // Currency1 drains out of the pool as the price drops. `move` is
            // a fraction of the price itself, so the subtraction cannot underflow.
            uint160 window = uint160(uint256(sqrtPriceX96) - move);
            if (window < TickMath.MIN_SQRT_PRICE) window = TickMath.MIN_SQRT_PRICE;
            uint160 edge = _liquidityEdge(poolManager, id, tick, spacing, false);
            if (edge <= window) return virtualReserve;
            if (edge >= sqrtPriceX96) return 0;
            inRange = SqrtPriceMath.getAmount1Delta(edge, sqrtPriceX96, liquidity, false);
        }

        // Scale the band back up into the units the V3 branch reports. The
        // currency0 amount varies as 1/sqrtP rather than sqrtP, which makes
        // its band a factor of (1 + w) smaller for the same w.
        uint256 scaleNumerator = sideIsCurrency0 ? BASIS_POINTS + DEPTH_SQRT_WINDOW_BPS : BASIS_POINTS;
        depth = FullMath.mulDiv(inRange, scaleNumerator, DEPTH_SQRT_WINDOW_BPS);
        if (depth > virtualReserve) depth = virtualReserve;
    }

    /**
     * @notice A V2 pair's reserves as a V4-style sqrtPriceX96 (currency1 per
     * currency0). Zero for an empty pair, or one whose reserves differ by
     * more than 2**64, where the quotient would overflow; such a pair is
     * passed over quietly rather than making the asset unpriceable by
     * exception. Computed as `sqrt(reserve1 * 2**192 / reserve0)` in one
     * step so the precision is not thrown away on lopsided pairs.
     */
    function v2SqrtPriceX96(address pair) public view returns (uint160) {
        (uint112 reserve0, uint112 reserve1,) = IUniswapV2PairReserves(pair).getReserves();
        if (reserve0 == 0 || reserve1 == 0) return 0;
        if (uint256(reserve1) > uint256(reserve0) << 64) return 0;
        if (uint256(reserve0) > uint256(reserve1) << 64) return 0;

        uint256 ratioX192 = FullMath.mulDiv(uint256(reserve1), 1 << 192, uint256(reserve0));
        uint256 root = Math.sqrt(ratioX192);
        if (root == 0 || root > type(uint160).max) return 0;
        return uint160(root);
    }

    /// @dev The square root price at which the active liquidity ceases to be
    /// active, looking `up` or down from `tick`: the nearest initialized tick
    /// within `MAX_BITMAP_WORDS` words, or the end of the price range.
    function _liquidityEdge(IPoolManager poolManager, PoolId id, int24 tick, int24 spacing, bool up)
        private
        view
        returns (uint160)
    {
        (bool found, int24 edgeTick) = _nextInitializedTick(poolManager, id, tick, spacing, up);
        if (!found) return up ? TickMath.MAX_SQRT_PRICE : TickMath.MIN_SQRT_PRICE;
        return TickMath.getSqrtPriceAtTick(edgeTick);
    }

    /// @dev The nearest initialized tick strictly above `tick`, or else the
    /// nearest at or below it, read from the tick bitmap the way a swap reads it.
    function _nextInitializedTick(IPoolManager poolManager, PoolId id, int24 tick, int24 spacing, bool up)
        private
        view
        returns (bool found, int24 result)
    {
        int24 compressed = tick / spacing;
        if (tick < 0 && tick % spacing != 0) --compressed;

        if (up) {
            int24 cursor = compressed + 1;
            for (uint256 i = 0; i < MAX_BITMAP_WORDS; ++i) {
                (int16 wordPos, uint8 bitPos) = _bitmapPosition(cursor);
                uint256 masked = poolManager.getTickBitmap(id, wordPos) & (type(uint256).max << bitPos);
                if (masked != 0) {
                    int24 offset = int24(uint24(BitMath.leastSignificantBit(masked))) - int24(uint24(bitPos));
                    return (true, (cursor + offset) * spacing);
                }
                cursor += int24(256 - int256(uint256(bitPos)));
            }
        } else {
            int24 cursor = compressed;
            for (uint256 i = 0; i < MAX_BITMAP_WORDS; ++i) {
                (int16 wordPos, uint8 bitPos) = _bitmapPosition(cursor);
                uint256 mask = bitPos == 255 ? type(uint256).max : (uint256(1) << (bitPos + 1)) - 1;
                uint256 masked = poolManager.getTickBitmap(id, wordPos) & mask;
                if (masked != 0) {
                    int24 offset = int24(uint24(BitMath.mostSignificantBit(masked))) - int24(uint24(bitPos));
                    return (true, (cursor + offset) * spacing);
                }
                cursor -= int24(int256(uint256(bitPos))) + 1;
            }
        }
    }

    /// @dev Uniswap's TickBitmap.position applied to a compressed tick.
    function _bitmapPosition(int24 compressed) private pure returns (int16 wordPos, uint8 bitPos) {
        wordPos = int16(compressed >> 8);
        bitPos = uint8(uint24(compressed) & 0xff);
    }
}
