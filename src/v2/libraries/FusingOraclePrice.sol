// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IPythMinimal, IAggregatorV3Minimal} from "../interfaces/IOracles.sol";

/**
 * @title FusingOraclePrice
 * @notice Oracle pricing for the tokenised stocks, kept outside the pricer
 * as an external library so the pricer stays under the size limit.
 *
 * A quote in the asset is `ethAmount * ETH/USD / ASSET/USD`. ETH/USD comes
 * from Chainlink, whose mainnet feed updates hourly or on a 0.5% move, so it
 * is allowed 75 minutes. The asset's price follows the market it trades on:
 *
 *   while US equities can be open (Monday to Friday, 13:00 to 21:30 UTC,
 *   which covers both summer and winter time) the price must be fresh,
 *   no older than `maxAge`: a launch posts a signed update in its own
 *   transaction, so there is no excuse for an old one;
 *
 *   outside that window the market is shut and the last close is the
 *   price, accepted up to `closedAge` old (four days by default, a long
 *   weekend). The stock token's own fair value is that close too, so
 *   there is nothing to arbitrage against.
 *
 * An exchange holiday on a weekday is inside the fresh window with no fresh
 * price, so stock launches wait those few hours. That is the safe side.
 */
library FusingOraclePrice {
    uint256 internal constant ETH_USD_MAX_AGE = 75 minutes;
    /// @dev A signed price may be at most this old when it is posted, and prices a launch for this long after it was taken.
    uint256 internal constant SIGNED_MAX_AGE = 15 minutes;

    struct SignedPrice {
        uint64 priceUsd8;
        uint64 takenAt;
    }

    error BadAttestation(address asset);

    event SignedPricePosted(address indexed asset, uint64 priceUsd8, uint64 takenAt);

    /**
     * @notice Stores price attestations. `prices[i]` is abi.encode(asset,
     * priceUsd8, takenAt, signature). One is kept only when `signer` made
     * it, it is no older than fifteen minutes, not from the future, and
     * newer than what is stored. The digest binds the chain, the pricer,
     * the asset, the price and the time, so a signature cannot be replayed
     * anywhere else or for another asset. Runs in the pricer's context.
     */
    function post(mapping(address => SignedPrice) storage store, bytes[] calldata prices, address signer) external {
        for (uint256 i = 0; i < prices.length; i++) {
            (address asset, uint64 priceUsd8, uint64 takenAt, bytes memory sig) = abi.decode(prices[i], (address, uint64, uint64, bytes));
            if (
                signer == address(0) || priceUsd8 == 0 || priceUsd8 > uint64(type(int64).max) || takenAt > block.timestamp
                    || block.timestamp - takenAt > SIGNED_MAX_AGE || takenAt <= store[asset].takenAt || asset.code.length == 0
                    || _signerOf(asset, priceUsd8, takenAt, sig) != signer
            ) revert BadAttestation(asset);
            store[asset] = SignedPrice({priceUsd8: priceUsd8, takenAt: takenAt});
            emit SignedPricePosted(asset, priceUsd8, takenAt);
        }
    }

    function _signerOf(address asset, uint64 priceUsd8, uint64 takenAt, bytes memory sig) private view returns (address) {
        if (sig.length != 65) return address(0);
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19Ethereum Signed Message:\n32",
                keccak256(abi.encode("fusi.ng price attestation", block.chainid, address(this), asset, priceUsd8, takenAt))
            )
        );
        bytes32 r;
        bytes32 sv;
        uint8 v;
        assembly {
            r := mload(add(sig, 32))
            sv := mload(add(sig, 64))
            v := byte(0, mload(add(sig, 96)))
        }
        // Low-s only, so one attestation has one valid signature.
        if (uint256(sv) > 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0) return address(0);
        return ecrecover(digest, v, r, sv);
    }

    /// @notice True while US equity markets can be open, by the clock alone.
    function marketWindowOpen(uint256 timestamp) internal pure returns (bool) {
        uint256 day = (timestamp / 1 days + 4) % 7; // 0 is Sunday
        uint256 secs = timestamp % 1 days;
        return day >= 1 && day <= 5 && secs >= 13 hours && secs < 21 hours + 30 minutes;
    }

    /// @notice How old the asset's price may be right now.
    function allowedAge(uint256 maxAge, uint256 closedAge) internal view returns (uint256) {
        return marketWindowOpen(block.timestamp) || closedAge < maxAge ? maxAge : closedAge;
    }

    /**
     * @notice `ethAmount` of ETH in units of the asset, or `ok == false`
     * when any price involved is missing, non-positive or too old. The
     * asset's price comes from, in order: a signed attestation taken in the
     * last fifteen minutes, its Pyth feed, its USD aggregator.
     * @param pythId The asset's Pyth feed, or zero to read `feed` instead (an aggregator quoting the asset in USD).
     */
    function quote(
        IPythMinimal pyth,
        IAggregatorV3Minimal ethUsdFeed,
        bytes32 pythId,
        IAggregatorV3Minimal feed,
        address asset,
        uint8 assetDecimals,
        uint256 ethAmount,
        uint256 maxAge,
        uint256 closedAge,
        uint64 signedPriceUsd8,
        uint64 signedAt
    ) external view returns (bool ok, uint256 amount) {
        if (address(ethUsdFeed) == address(0)) return (false, 0);
        (, int256 ethUsd,, uint256 updatedAt,) = ethUsdFeed.latestRoundData();
        if (ethUsd <= 0 || block.timestamp - updatedAt > ETH_USD_MAX_AGE) return (false, 0);

        uint256 age = allowedAge(maxAge, closedAge);
        int64 price;
        int32 expo;
        if (signedAt != 0 && block.timestamp - signedAt <= SIGNED_MAX_AGE) {
            // A price the fusi.ng price signer attested, posted in the last few minutes.
            // Taken first: the launch that needs it has just posted it.
            (price, expo) = (int64(signedPriceUsd8), -8);
        } else if (pythId != bytes32(0)) {
            if (address(pyth) == address(0)) return (false, 0);
            try pyth.getPriceNoOlderThan(pythId, age) returns (IPythMinimal.Price memory got) {
                (price, expo) = (got.price, got.expo);
            } catch {
                return (false, 0);
            }
        } else if (address(feed) == address(0)) {
            return (false, 0);
        } else {
            (, int256 answer,, uint256 at,) = feed.latestRoundData();
            if (answer <= 0 || answer > int256(uint256(uint64(type(int64).max))) || block.timestamp - at > age) return (false, 0);
            (price, expo) = (int64(answer), -int32(uint32(feed.decimals())));
        }
        if (price <= 0) return (false, 0);
        // An asset known only through attestations has no registered decimals: read them.
        if (assetDecimals == 0) assetDecimals = IERC20Metadata(asset).decimals();

        // num is USD scaled by 10^(18 + feedDecimals); dividing by the asset's USD price gives asset units at that scale.
        uint256 num = ethAmount * uint256(ethUsd);
        uint256 scale = 18 + ethUsdFeed.decimals();
        uint256 px = uint256(uint64(price));
        uint256 units = expo >= 0 ? num / (px * 10 ** uint256(int256(expo))) : FullMath.mulDiv(num, 10 ** uint256(int256(-expo)), px);
        amount = scale == assetDecimals ? units : scale > assetDecimals ? units / 10 ** (scale - assetDecimals) : units * 10 ** (assetDecimals - scale);
        ok = true;
    }
}
