// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";

import {FuseModuleBase} from "./FuseModuleBase.sol";
import {FusingSwapGuard} from "../libraries/FusingSwapGuard.sol";

interface IBurnFactory {
    struct Market {
        address pairToken;
        uint256 phantomQuote;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint256 positionId;
    }

    function poolKeyFor(address token, uint256 index) external view returns (PoolKey memory);
    function marketsOf(address token) external view returns (Market[] memory);
    function launchForwarder() external view returns (address);
}

interface IBurnRouter {
    function swapExactIn(PoolKey calldata key, bool zeroForOne, uint256 amountIn, uint256 minAmountOut, address recipient)
        external
        payable
        returns (uint256 amountOut);
}

interface IBurnHookFee {
    function currentFee(PoolId id) external view returns (uint24);
}

/**
 * @title BurnModule
 * @notice Burns what it is given. The launch token goes straight to the
 * dead address; ETH or a quote asset first buys the token on the launch's
 * matching pool, bounded so one call moves the price by no more than
 * MAX_SQRT_MOVE_BPS, then what was bought is burned. Anything the bound
 * left unspent waits here for the next call, so a big fee round burns over
 * several collections rather than lifting the pool. No configuration.
 */
contract BurnModule is FuseModuleBase, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint256 public constant MAX_SQRT_MOVE_BPS = 50;
    uint256 public constant TOLERANCE_BPS = 100;
    uint256 public constant MIN_SWAP = 1000;
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    error NoMarketFor(address currency);

    IBurnFactory public immutable factory;
    IBurnRouter public immutable router;
    IPoolManager public immutable poolManager;

    /// @notice Unspent quote per launch and currency, waiting for the next call.
    mapping(address token => mapping(address currency => uint256)) public waiting;
    mapping(address token => uint256) public burnedTotal;

    event Burned(address indexed token, address indexed currency, uint256 spent, uint256 burned, uint256 total);

    constructor(address vault_, IBurnFactory factory_, IBurnRouter router_, IPoolManager poolManager_) FuseModuleBase(vault_) {
        if (address(factory_) == address(0) || address(router_) == address(0) || address(poolManager_) == address(0)) revert ZeroAddress();
        factory = factory_;
        router = router_;
        poolManager = poolManager_;
    }

    function configure(address, bytes calldata) external view onlyVault {}

    function onFees(address token, address currency, uint256 amount) external payable onlyVault nonReentrant {
        // Use what arrived, not what we were told: a taxed quote delivers less.
        amount = _take(currency, amount);
        if (currency == token) {
            IERC20(token).safeTransfer(DEAD, amount);
            burnedTotal[token] += amount;
            emit Burned(token, currency, 0, amount, burnedTotal[token]);
            return;
        }
        uint256 available = waiting[token][currency] + amount;
        (PoolKey memory key, bool quoteIs0) = _marketFor(token, currency);
        uint256 spent = _buy(key, quoteIs0, currency, available);
        waiting[token][currency] = available - spent;
        uint256 bought = IERC20(token).balanceOf(address(this));
        if (bought > 0) {
            IERC20(token).safeTransfer(DEAD, bought);
            burnedTotal[token] += bought;
        }
        emit Burned(token, currency, spent, bought, burnedTotal[token]);
    }

    /// @notice Anyone may push waiting quote through once the pool has room again.
    function poke(address token, address currency) external nonReentrant {
        uint256 available = waiting[token][currency];
        if (available == 0) return;
        (PoolKey memory key, bool quoteIs0) = _marketFor(token, currency);
        uint256 spent = _buy(key, quoteIs0, currency, available);
        waiting[token][currency] = available - spent;
        uint256 bought = IERC20(token).balanceOf(address(this));
        if (bought > 0) {
            IERC20(token).safeTransfer(DEAD, bought);
            burnedTotal[token] += bought;
        }
        emit Burned(token, currency, spent, bought, burnedTotal[token]);
    }

    function _marketFor(address token, address currency) private view returns (PoolKey memory key, bool quoteIs0) {
        IBurnFactory.Market[] memory ms = factory.marketsOf(token);
        for (uint256 i = 0; i < ms.length; i++) {
            if (ms[i].pairToken == currency) {
                key = factory.poolKeyFor(token, i);
                quoteIs0 = Currency.unwrap(key.currency0) == currency;
                return (key, quoteIs0);
            }
        }
        revert NoMarketFor(currency);
    }

    function _fee(PoolKey memory key) private view returns (uint24) {
        if (key.fee != LPFeeLibrary.DYNAMIC_FEE_FLAG) return key.fee;
        try IBurnHookFee(address(key.hooks)).currentFee(key.toId()) returns (uint24 f) {
            return f;
        } catch {
            return uint24(FusingSwapGuard.PIPS);
        }
    }

    /// @dev Buys the token with up to `available` of the quote, bounded by the price move cap. Returns what was spent.
    function _buy(PoolKey memory key, bool quoteIs0, address currency, uint256 available) private returns (uint256 spent) {
        uint24 fee = _fee(key);
        if (fee >= FusingSwapGuard.PIPS) return 0;
        (uint160 sqrtP,,,) = poolManager.getSlot0(key.toId());
        uint128 liq = poolManager.getLiquidity(key.toId());
        if (sqrtP == 0 || liq == 0) return 0;
        uint256 amountIn = FusingSwapGuard.cappedInput(sqrtP, liq, fee, quoteIs0, available, MAX_SQRT_MOVE_BPS);
        if (amountIn < MIN_SWAP) return 0;
        (uint256 minOut, bool ok) = FusingSwapGuard.floor(sqrtP, fee, quoteIs0, amountIn, TOLERANCE_BPS);
        if (!ok) return 0;
        address r = factory.launchForwarder();
        if (r == address(0)) r = address(router);
        if (currency == address(0)) {
            IBurnRouter(r).swapExactIn{value: amountIn}(key, quoteIs0, amountIn, minOut, address(this));
        } else {
            IERC20(currency).forceApprove(r, amountIn);
            IBurnRouter(r).swapExactIn(key, quoteIs0, amountIn, minOut, address(this));
            IERC20(currency).forceApprove(r, 0);
        }
        return amountIn;
    }
}
