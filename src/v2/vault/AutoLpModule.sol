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
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

import {FuseModuleBase} from "./FuseModuleBase.sol";
import {FusingSwapGuard} from "../libraries/FusingSwapGuard.sol";
import {Hop, HopKind} from "../libraries/Hop.sol";
import {IFusingLaunchFactory} from "../interfaces/ILaunchpadV2.sol";

interface IAutoLpFactory is IFusingLaunchFactory {
    function poolKeyFor(address token) external view returns (PoolKey memory);
    function launchForwarder() external view returns (address);
}

interface IAutoLpRouter {
    function swapExactIn(PoolKey calldata key, bool zeroForOne, uint256 amountIn, uint256 minAmountOut, address recipient)
        external
        payable
        returns (uint256 amountOut);
    function quoteToEth(Currency quote, uint256 amountIn, Hop[] calldata leg, uint256 minEthOut, address recipient)
        external
        returns (uint256 ethOut);
}

interface IAutoLpLocker {
    function addLiquidity(address token, uint256 tokenAmount, uint256 quoteAmount)
        external
        payable
        returns (uint128 liquidity, uint256 used0, uint256 used1);
}

interface IAutoLpPricer {
    function route(address quoteToken) external view returns (Hop[] memory hops, bool qualifies);
    function priceEthAmountInQuote(address quoteToken, uint256 ethAmount) external view returns (uint256);
}

interface IAutoLpHookFee {
    function currentFee(PoolId id) external view returns (uint24);
}

/**
 * @title AutoLpModule
 * @notice Adds fees back into the launch's locked primary position. It
 * holds what it is given per launch, buys or sells the fraction the
 * position needs at the current price so both sides are covered (a sale
 * of fee tokens for pairing is a contract sale, allowed), and calls the
 * locker's addLiquidity. Too little to add just waits for the next call.
 * A quote of another market is sold to ETH first when the primary pool is
 * ETH-quoted. No configuration.
 */
contract AutoLpModule is FuseModuleBase, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint256 public constant MIN_QUOTE = 1000;
    uint256 public constant MAX_SQRT_MOVE_BPS = 50;
    uint256 public constant SWAP_TOLERANCE_BPS = 100;
    uint256 public constant ROUTE_TOLERANCE_BPS = 300;
    uint128 private constant PROBE = 1 << 96;

    error UnusableCurrency(address currency);

    IAutoLpFactory public immutable factory;
    IAutoLpRouter public immutable router;
    IAutoLpLocker public immutable locker;
    IAutoLpPricer public immutable pricer;
    IPoolManager public immutable poolManager;

    /// @notice Held for a launch: its primary quote (ETH or ERC-20) and its tokens, waiting to be paired.
    mapping(address token => uint256) public cashOf;
    mapping(address token => uint256) public tokensOf;
    mapping(address token => uint256) public addedTotal;

    event Added(address indexed token, uint128 liquidity, uint256 tokensAdded, uint256 quoteAdded, uint256 total);
    event Waiting(address indexed token, uint256 cash, uint256 tokens);

    constructor(address vault_, IAutoLpFactory factory_, IAutoLpRouter router_, IAutoLpLocker locker_, IAutoLpPricer pricer_, IPoolManager pm)
        FuseModuleBase(vault_)
    {
        if (
            address(factory_) == address(0) || address(router_) == address(0) || address(locker_) == address(0)
                || address(pricer_) == address(0) || address(pm) == address(0)
        ) revert ZeroAddress();
        factory = factory_;
        router = router_;
        locker = locker_;
        pricer = pricer_;
        poolManager = pm;
    }

    function configure(address, bytes calldata) external view onlyVault {}

    function onFees(address token, address currency, uint256 amount) external payable onlyVault nonReentrant {
        // Use what arrived, not what we were told: a taxed quote delivers less.
        amount = _take(currency, amount);
        IFusingLaunchFactory.LaunchedToken memory launch = factory.getLaunchedToken(token);
        address quote = launch.pairToken;
        if (currency == token) {
            tokensOf[token] += amount;
        } else if (currency == quote) {
            cashOf[token] += amount;
        } else if (quote == address(0)) {
            // Another market's quote: sold for ETH along the pricer's route; what cannot be sold waits as is.
            cashOf[token] += _toEth(currency, amount);
        } else {
            revert UnusableCurrency(currency);
        }
        _tryAdd(token, launch);
    }

    /// @notice Anyone may push what is waiting once it is enough or the pool has room.
    function poke(address token) external nonReentrant {
        _tryAdd(token, factory.getLaunchedToken(token));
    }

    function _tryAdd(address token, IFusingLaunchFactory.LaunchedToken memory launch) private {
        uint256 cash = cashOf[token];
        uint256 tokens = tokensOf[token];
        if (cash < MIN_QUOTE && tokens == 0) {
            emit Waiting(token, cash, tokens);
            return;
        }
        PoolKey memory key = factory.poolKeyFor(token);
        bool tokenIs0 = Currency.unwrap(key.currency0) == token;
        (uint160 sqrtP,,,) = poolManager.getSlot0(key.toId());
        uint128 liq = poolManager.getLiquidity(key.toId());
        if (sqrtP == 0) {
            emit Waiting(token, cash, tokens);
            return;
        }
        // The fraction of value the position wants on the token side at this price.
        (uint256 tokenSide, uint256 quoteSide) = _mix(launch, tokenIs0, sqrtP);
        uint256 tokenValue = _valueInQuote(sqrtP, tokenSide, tokenIs0);
        uint256 heldValue = _valueInQuote(sqrtP, tokens, tokenIs0);
        uint256 wantValue = tokenValue + quoteSide == 0 ? 0 : (cash + heldValue) * tokenValue / (tokenValue + quoteSide);
        if (wantValue > heldValue) {
            uint256 toSpend = wantValue - heldValue;
            if (toSpend > cash) toSpend = cash;
            uint256 spent = _swap(key, !tokenIs0, launch.pairToken, toSpend, sqrtP, liq);
            cash -= spent;
            tokens = IERC20(token).balanceOf(address(this));
        } else if (heldValue > wantValue) {
            // More tokens than the position can pair: sell the excess into the pool for quote.
            uint256 excessValue = heldValue - wantValue;
            uint256 excessTokens = _valueInQuote(sqrtP, 1e18, tokenIs0) == 0 ? 0 : FullMath.mulDiv(excessValue, 1e18, _valueInQuote(sqrtP, 1e18, tokenIs0));
            if (excessTokens > tokens) excessTokens = tokens;
            uint256 sold = _swap(key, tokenIs0, token, excessTokens, sqrtP, liq);
            tokens -= sold;
            cash = launch.pairToken == address(0) ? address(this).balance : IERC20(launch.pairToken).balanceOf(address(this));
        }
        (uint128 added, uint256 usedTok, uint256 usedQuote) = _add(token, launch.pairToken, cash, tokens);
        cashOf[token] = launch.pairToken == address(0) ? address(this).balance : IERC20(launch.pairToken).balanceOf(address(this));
        tokensOf[token] = IERC20(token).balanceOf(address(this));
        if (added == 0) {
            emit Waiting(token, cashOf[token], tokensOf[token]);
            return;
        }
        addedTotal[token] += added;
        emit Added(token, added, usedTok, usedQuote, addedTotal[token]);
    }

    /// @dev What one unit of probe liquidity holds on each side of the range at the current price.
    function _mix(IFusingLaunchFactory.LaunchedToken memory launch, bool tokenIs0, uint160 sqrtP)
        private
        pure
        returns (uint256 tokenSide, uint256 quoteSide)
    {
        uint160 lower = TickMath.getSqrtPriceAtTick(launch.tickLower);
        uint160 upper = TickMath.getSqrtPriceAtTick(launch.tickUpper);
        uint160 p = sqrtP < lower ? lower : (sqrtP > upper ? upper : sqrtP);
        uint256 a0 = SqrtPriceMath.getAmount0Delta(p, upper, PROBE, false);
        uint256 a1 = SqrtPriceMath.getAmount1Delta(lower, p, PROBE, false);
        (tokenSide, quoteSide) = tokenIs0 ? (a0, a1) : (a1, a0);
    }

    function _valueInQuote(uint160 sqrtP, uint256 tokens, bool tokenIs0) private pure returns (uint256) {
        if (tokens == 0) return 0;
        uint256 priceX96 = FullMath.mulDiv(uint256(sqrtP), uint256(sqrtP), 1 << 96); // token1 per token0
        return tokenIs0 ? FullMath.mulDiv(tokens, priceX96, 1 << 96) : FullMath.mulDiv(tokens, 1 << 96, priceX96);
    }

    function _fee(PoolKey memory key) private view returns (uint24) {
        if (key.fee != LPFeeLibrary.DYNAMIC_FEE_FLAG) return key.fee;
        try IAutoLpHookFee(address(key.hooks)).currentFee(key.toId()) returns (uint24 f) {
            return f;
        } catch {
            return uint24(FusingSwapGuard.PIPS);
        }
    }

    /// @dev A bounded swap on the primary pool. Returns the input spent.
    function _swap(PoolKey memory key, bool zeroForOne, address currencyIn, uint256 available, uint160 sqrtP, uint128 liq)
        private
        returns (uint256)
    {
        uint24 fee = _fee(key);
        if (fee >= FusingSwapGuard.PIPS || liq == 0) return 0;
        uint256 amountIn = FusingSwapGuard.cappedInput(sqrtP, liq, fee, zeroForOne, available, MAX_SQRT_MOVE_BPS);
        if (amountIn < MIN_QUOTE) return 0;
        (uint256 minOut, bool ok) = FusingSwapGuard.floor(sqrtP, fee, zeroForOne, amountIn, SWAP_TOLERANCE_BPS);
        if (!ok) return 0;
        address r = factory.launchForwarder();
        if (r == address(0)) r = address(router);
        if (currencyIn == address(0)) {
            IAutoLpRouter(r).swapExactIn{value: amountIn}(key, zeroForOne, amountIn, minOut, address(this));
        } else {
            IERC20(currencyIn).forceApprove(r, amountIn);
            IAutoLpRouter(r).swapExactIn(key, zeroForOne, amountIn, minOut, address(this));
            IERC20(currencyIn).forceApprove(r, 0);
        }
        return amountIn;
    }

    /// @dev Sells a foreign quote for ETH along the pricer's route; returns the ETH received (zero when it cannot).
    function _toEth(address currency, uint256 amount) private returns (uint256 got) {
        (Hop[] memory hops, bool qualifies) = pricer.route(currency);
        if (!qualifies || hops.length == 0) return 0;
        uint256 quotePerEth = pricer.priceEthAmountInQuote(currency, 1 ether);
        if (quotePerEth == 0) return 0;
        uint256 minOut = FullMath.mulDiv(amount, 1 ether, quotePerEth) * (10_000 - ROUTE_TOLERANCE_BPS) / 10_000;
        address r = factory.launchForwarder();
        if (r == address(0)) r = address(router);
        uint256 before = address(this).balance;
        IERC20(currency).forceApprove(r, amount);
        try IAutoLpRouter(r).quoteToEth(Currency.wrap(currency), amount, hops, minOut, address(this)) {} catch {}
        IERC20(currency).forceApprove(r, 0);
        got = address(this).balance - before;
    }

    function _add(address token, address quote, uint256 cash, uint256 tokens)
        private
        returns (uint128 liquidity, uint256 usedTok, uint256 usedQuote)
    {
        if (cash < MIN_QUOTE && tokens == 0) return (0, 0, 0);
        if (tokens > 0) IERC20(token).forceApprove(address(locker), tokens);
        uint256 value;
        if (quote == address(0)) value = cash;
        else if (cash > 0) IERC20(quote).forceApprove(address(locker), cash);
        try locker.addLiquidity{value: value}(token, tokens, cash) returns (uint128 l, uint256 u0, uint256 u1) {
            liquidity = l;
            (usedTok, usedQuote) = (u0, u1);
        } catch {}
        if (tokens > 0) IERC20(token).forceApprove(address(locker), 0);
        if (quote != address(0) && cash > 0) IERC20(quote).forceApprove(address(locker), 0);
    }
}
