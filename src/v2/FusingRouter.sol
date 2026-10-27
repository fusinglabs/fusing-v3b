// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/*
 *  fusi.ng  |  the Ethereum launchpad
 *  ----------------------------------
 *  Web:       https://fusi.ng
 *  X:         https://x.com/fusi_ng
 *  Telegram:  https://t.me/fusi_ng
 *  Docs:      https://fusi.ng/docs
 *
 *  Fusing V2 contracts. Every launch pays 1.1% per trade, 60% to the creator
 *  and 40% to the protocol, paid out in ETH. V2 puts the terms in the
 *  creator's hands: token limits, fee schedules, anti-sniper windows, holder
 *  rewards, five-way fee splits and the payout mode.
 */

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {FusingLaunchFactory} from "./FusingLaunchFactory.sol";
import {FusingQuotePricer} from "./FusingQuotePricer.sol";

/// @dev Raised when someone other than the factory's owner tries to administer the router.

import {Hop, HopKind} from "./libraries/Hop.sol";
import {FusingTerms} from "./libraries/FusingTerms.sol";

/// @dev The single FusingTokenLock entry point the router depends on.
interface IFusingTokenLock {
    function lock(address token, address beneficiary, uint256 amount, uint64 unlockAt, uint32 vestSeconds) external returns (uint256 id);
}

/// @dev The part of Uniswap's SwapRouter02 this router calls. When ETH is
/// attached as value and `tokenIn` is WETH9, SwapRouter02 does the wrapping.
interface ISwapRouter02 {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}

/// @dev Resolving a pair from the same factory the pricer routed against.
interface IUniswapV2FactoryLookup {
    function getPair(address tokenA, address tokenB) external view returns (address pair);
}

/// @dev The part of a Uniswap V2 pair the router trades against. V2 has no
/// router of its own here on purpose: the pair is called directly, so there
/// is no third-party contract between the route the pricer approved and the
/// swap that executes it.
interface IUniswapV2PairSwap {
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
}

interface IWETH9 is IERC20 {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
}

/**
 * @title FusingRouter
 * @notice The router behind the fusi.ng frontend. It does three things:
 *
 * - Exact-input swaps through a launch pool. Launch pools are ordinary V4
 *   pools whose hook only sets the fee, so any V4 router could trade them;
 *   this contract exists so the frontend talks to one address for every
 *   flow listed here.
 * - Moving ETH into and out of pools quoted in an ERC-20, over a route of
 *   Uniswap V3 and V4 pools in any order. The route is the same hop list the
 *   quote pricer uses to value the asset, so no matter how many pools sit
 *   between a quote asset and ETH, buyers pay plain ETH and sellers get
 *   plain ETH back. The whole route runs inside a single PoolManager unlock:
 *   V4 hops net their deltas against each other there, and a V3 hop in the
 *   middle is fed by taking the previous hop's output out of the manager and
 *   settling the next hop's input back in.
 * - Atomic launch-and-buy, in its role as the factory's trusted launch
 *   forwarder: the token is launched on behalf of the real caller and their
 *   opening buy fills in the same transaction, before anyone else can trade.
 *
 * Nothing is held here between transactions.
 */
contract FusingRouter is IUnlockCallback, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IPoolManager public immutable manager;
    FusingLaunchFactory public immutable factory;
    ISwapRouter02 public immutable swapRouter;
    IWETH9 public immutable weth;

    error NotPoolManager();
    error ZeroAmount();
    error ZeroAddress();
    error NativeValueMismatch();
    error SlippageExceeded(uint256 amountOut, uint256 minAmountOut);
    error EthTransferFailed();
    error NativeQuoteNeedsNoBolt();
    error InsufficientLaunchValue();
    /// @dev The pool at hop `index` has no side matching the asset the previous hop output.
    error RouteBroken(uint256 index);
    /// @dev The asset at the end of the route is not the one the caller expected.
    error RouteEndMismatch(address expected, address actual);

    event BoltBuy(bytes32 indexed poolId, address indexed buyer, uint256 ethIn, uint256 tokensOut);
    event BoltSell(bytes32 indexed poolId, address indexed seller, uint256 tokensIn, uint256 ethOut);

    /// @dev Tracks the current location of the asset moving through a route.
    enum Where {
        /// @dev Not yet taken from the caller: either native value already
        /// sent with the call, or an ERC-20 still to be pulled via allowance.
        Caller,
        /// @dev Sitting as a positive delta (a credit) inside the PoolManager.
        Manager,
        /// @dev In this contract's own balance, whether native ETH or an ERC-20.
        Router
    }

    /// @dev Everything one unlock needs: send `amountIn` of `currencyIn` through `hops`, first to last.
    struct Route {
        Hop[] hops;
        Currency currencyIn;
        uint256 amountIn;
        uint256 minAmountOut;
        /// @dev The account doing the trade. It supplies the input and gets
        /// back whatever a hop could not take.
        address payer;
        /// @dev Destination of the route's final output.
        address recipient;
        /// @dev When true, the route ends in native ETH, and WETH coming out
        /// of the last hop is unwrapped to get there. When false, the output
        /// has to be `currencyOut` exactly.
        bool ethOut;
        Currency currencyOut;
    }

    constructor(IPoolManager manager_, FusingLaunchFactory factory_, ISwapRouter02 swapRouter_, IWETH9 weth_) {
        if (
            address(manager_) == address(0) || address(factory_) == address(0) || address(swapRouter_) == address(0)
                || address(weth_) == address(0)
        ) revert ZeroAddress();
        manager = manager_;
        factory = factory_;
        swapRouter = swapRouter_;
        weth = weth_;
    }

    // ---------------------------------------------------------------------
    // Swapping through one pool
    // ---------------------------------------------------------------------

    /**
     * @param key        Pool key of the launch pool to trade.
     * @param zeroForOne Trade direction; true spends currency0 and receives currency1.
     * @param amountIn   The exact amount to spend. When the input is native
     *                   ETH it must match msg.value exactly; when it is an
     *                   ERC-20, msg.value must be zero and the caller must
     *                   have approved the router for at least this amount.
     */
    function swapExactIn(
        PoolKey calldata key,
        bool zeroForOne,
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient
    ) external payable nonReentrant returns (uint256 amountOut) {
        if (amountIn == 0) revert ZeroAmount();
        if (recipient == address(0)) revert ZeroAddress();

        Currency currencyIn = zeroForOne ? key.currency0 : key.currency1;
        if (currencyIn.isAddressZero()) {
            if (msg.value != amountIn) revert NativeValueMismatch();
        } else if (msg.value != 0) {
            revert NativeValueMismatch();
        }

        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({key: key, kind: HopKind.V4});
        (amountOut,) = _route(
            Route({
                hops: hops,
                currencyIn: currencyIn,
                amountIn: amountIn,
                minAmountOut: minAmountOut,
                payer: msg.sender,
                recipient: recipient,
                ethOut: false,
                currencyOut: zeroForOne ? key.currency1 : key.currency0
            })
        );
    }

    // ---------------------------------------------------------------------
    // Native ETH into and out of ERC-20-quoted pools
    // ---------------------------------------------------------------------

    /**
     * @notice Buys the launch token in pool `key` with native ETH. The value
     * sent with the call is routed along `leg` (starting from ETH, ending at
     * the quote asset), then through the launch pool, and the tokens land
     * with `recipient`. On an ETH-quoted pool, pass an empty leg and this is
     * simply a direct buy.
     */
    function buyWithEth(PoolKey calldata key, Hop[] calldata leg, uint256 minTokensOut, address recipient)
        external
        payable
        nonReentrant
        returns (uint256 tokensOut)
    {
        if (msg.value == 0) revert ZeroAmount();
        if (recipient == address(0)) revert ZeroAddress();
        tokensOut = _buyAlongLeg(key, leg, msg.value, minTokensOut, recipient);
        emit BoltBuy(_poolId(key), msg.sender, msg.value, tokensOut);
    }

    /**
     * @notice Sells the launch token in pool `key` and pays `recipient` in
     * native ETH. The trade goes through the launch pool first and then
     * along `leg` (starting from the quote asset, ending at ETH). The caller
     * must have approved the router to spend the launch token.
     */
    function sellToEth(
        PoolKey calldata key,
        bool tokenIsCurrency0,
        uint256 tokensIn,
        Hop[] calldata leg,
        uint256 minEthOut,
        address recipient
    ) external nonReentrant returns (uint256 ethOut) {
        if (tokensIn == 0) revert ZeroAmount();
        if (recipient == address(0)) revert ZeroAddress();

        Hop[] memory hops = new Hop[](1 + leg.length);
        hops[0] = Hop({key: key, kind: HopKind.V4});
        for (uint256 i = 0; i < leg.length; i++) {
            hops[i + 1] = leg[i];
        }

        (ethOut,) = _route(
            Route({
                hops: hops,
                currencyIn: tokenIsCurrency0 ? key.currency0 : key.currency1,
                amountIn: tokensIn,
                minAmountOut: minEthOut,
                payer: msg.sender,
                recipient: recipient,
                ethOut: true,
                currencyOut: Currency.wrap(address(0))
            })
        );
        emit BoltSell(_poolId(key), msg.sender, tokensIn, ethOut);
    }

    /**
     * @notice Sells `amountIn` of a quote asset along `leg` (quote first, ETH
     * last, the order the pricer keeps it in) and sends the resulting native
     * ETH to `recipient`. The caller must have approved the router for the
     * quote. This is how V2 pays fees in ETH regardless of what the pool is
     * quoted in.
     */
    function quoteToEth(Currency quote, uint256 amountIn, Hop[] calldata leg, uint256 minEthOut, address recipient)
        external
        nonReentrant
        returns (uint256 ethOut)
    {
        if (amountIn == 0) revert ZeroAmount();
        if (recipient == address(0)) revert ZeroAddress();
        if (leg.length == 0) revert ZeroAmount();
        Hop[] memory hops = new Hop[](leg.length);
        for (uint256 i = 0; i < leg.length; i++) {
            hops[i] = leg[i];
        }
        (ethOut,) = _route(
            Route({
                hops: hops,
                currencyIn: quote,
                amountIn: amountIn,
                minAmountOut: minEthOut,
                payer: msg.sender,
                recipient: recipient,
                ethOut: true,
                currencyOut: Currency.wrap(address(0))
            })
        );
    }

    /**
     * @notice Spends the ETH sent with the call along `leg` (ETH first, quote
     * asset last, which is the pricer's route walked backwards) and sends the
     * `quote` it buys to `recipient`. A liquidity vault does this before it
     * adds to a pool quoted in an ERC-20: the vault holds ETH but the pool
     * needs the quote.
     */
    function ethToQuote(Currency quote, Hop[] calldata leg, uint256 minQuoteOut, address recipient)
        external
        payable
        nonReentrant
        returns (uint256 quoteOut)
    {
        if (msg.value == 0 || leg.length == 0) revert ZeroAmount();
        if (recipient == address(0)) revert ZeroAddress();
        if (quote.isAddressZero() || Currency.unwrap(quote) == address(weth)) revert NativeQuoteNeedsNoBolt();
        Hop[] memory hops = new Hop[](leg.length);
        for (uint256 i = 0; i < leg.length; i++) {
            hops[i] = leg[i];
        }
        (quoteOut,) = _route(
            Route({
                hops: hops,
                currencyIn: Currency.wrap(address(0)),
                amountIn: msg.value,
                minAmountOut: minQuoteOut,
                payer: msg.sender,
                recipient: recipient,
                ethOut: false,
                currencyOut: quote
            })
        );
    }

    // ---------------------------------------------------------------------
    // Launch-and-buy in one transaction (as the factory's launch forwarder)
    // ---------------------------------------------------------------------

    /**
     * @notice Launches a token and fills the caller's opening buy in the same
     * transaction, with native ETH covering both. Whatever value is left
     * after the launch fee is routed along `leg` into the quote asset and
     * then into the new pool. When the launch is quoted in ETH, `leg` is
     * not used.
     * @param minTokensOut Minimum tokens the opening buy must return.
     */
    function launchAndBuyWithEth(
        FusingLaunchFactory.TokenParams calldata params,
        uint256 launchConfigId,
        address pairToken,
        Hop[] calldata leg,
        uint256 minTokensOut
    ) external payable nonReentrant returns (address token, PoolId poolId, uint256 tokensOut) {
        address[] memory one = new address[](1);
        one[0] = pairToken;
        return _launchAndBuyWithEth(params, launchConfigId, one, leg, minTokensOut, msg.value);
    }

    /**
     * @notice The one entry point for every launch: one to six quote assets,
     * an optional opening buy funded by the ETH sent beyond the launch fee.
     * The opening buy lands in market 0, so list the asset you want to buy
     * through first; `leg` routes ETH into that asset when it is not ETH.
     * Send exactly the launch fee to launch without buying.
     */
    function launchAndBuyWithEth(
        FusingLaunchFactory.TokenParams calldata params,
        uint256 launchConfigId,
        address[] calldata pairTokens,
        Hop[] calldata leg,
        uint256 minTokensOut
    ) external payable nonReentrant returns (address token, PoolId poolId, uint256 tokensOut) {
        return _launchAndBuyWithEth(params, launchConfigId, pairTokens, leg, minTokensOut, msg.value);
    }

    /**
     * @notice The entry point for a launch quoted in a stock or any other
     * oracle-priced asset: posts the signed Pyth prices first, then launches
     * on them in the same transaction, so the opening price can never be
     * older than the block it lands in. `priceUpdate` is what Hermes
     * returns for the feeds involved; its fee is taken from the value sent,
     * ahead of the launch fee and the opening buy. An empty update is the
     * plain entry point.
     */
    function launchAndBuyWithEth(
        FusingLaunchFactory.TokenParams calldata params,
        uint256 launchConfigId,
        address[] calldata pairTokens,
        Hop[] calldata leg,
        uint256 minTokensOut,
        bytes[] calldata priceUpdate
    ) external payable nonReentrant returns (address token, PoolId poolId, uint256 tokensOut) {
        uint256 oracleFee = _postPrices(priceUpdate);
        return _launchAndBuyWithEth(params, launchConfigId, pairTokens, leg, minTokensOut, msg.value - oracleFee);
    }

    /**
     * @notice The same entry point for assets priced by a signed attestation
     * (the tickers no on-chain feed carries): posts the attestations, then
     * launches on them. `signedPrices[i]` is what the fusi.ng price service
     * returns: abi.encode(asset, priceUsd8, takenAt, signature). Free to post.
     */
    function launchWithSignedPrices(
        FusingLaunchFactory.TokenParams calldata params,
        uint256 launchConfigId,
        address[] calldata pairTokens,
        Hop[] calldata leg,
        uint256 minTokensOut,
        bytes[] calldata signedPrices
    ) external payable nonReentrant returns (address token, PoolId poolId, uint256 tokensOut) {
        factory.quotePricer().postSignedPrices(signedPrices);
        return _launchAndBuyWithEth(params, launchConfigId, pairTokens, leg, minTokensOut, msg.value);
    }

    /// @dev Pays Pyth its update fee out of the value sent and posts the prices through the pricer. Returns the fee spent.
    function _postPrices(bytes[] calldata priceUpdate) private returns (uint256 fee) {
        if (priceUpdate.length == 0) return 0;
        FusingQuotePricer pricer = factory.quotePricer();
        fee = pricer.pyth().getUpdateFee(priceUpdate);
        if (msg.value < fee) revert InsufficientLaunchValue();
        pricer.updateOraclePrices{value: fee}(priceUpdate);
        emit PricesPosted(msg.sender, priceUpdate.length, fee);
    }

    event PricesPosted(address indexed launcher, uint256 feeds, uint256 fee);

    error SeedPlanMismatch();

    /**
     * @notice Launch-and-buy that also lights up every pool in the same
     * transaction. A pool is listed by scanners only once it has had a
     * swap; a multi-market launch mints one single-sided position per pool
     * and the opening buy goes through pool 0, so pools 1..n-1 would sit
     * unseen until somebody trades them. Here the value sent is the launch
     * fee, the opening buy, and one seed amount per extra pool:
     *
     *   msg.value = launchFee + openingBuy + seedEth[1] + ... + seedEth[n-1]
     *
     * `legs[i]` is the route from ETH to pool i's quote (empty for an
     * ETH-quoted pool) and `seedEth[i]` how much ETH buys through pool i;
     * `legs[0]` and the remaining value are the opening buy, exactly as in
     * launchAndBuyWithEth (dev lock included). A zero seed skips the pool,
     * which is how the caller leaves out a quote the pricer cannot route
     * (a stock with no market yet: nothing can seed that pool). The seeds'
     * tokens go to the launcher, unlocked: they are dust by design.
     */
    function launchAndBuyAllWithEth(
        FusingLaunchFactory.TokenParams calldata params,
        uint256 launchConfigId,
        address[] calldata pairTokens,
        Hop[][] calldata legs,
        uint256[] calldata seedEth,
        uint256 minTokensOut
    ) external payable nonReentrant returns (address token, PoolId poolId, uint256 tokensOut) {
        if (legs.length != pairTokens.length || seedEth.length != pairTokens.length || seedEth[0] != 0) revert SeedPlanMismatch();
        uint256 seeds;
        for (uint256 i = 1; i < seedEth.length; i++) {
            seeds += seedEth[i];
        }
        if (msg.value < seeds) revert InsufficientLaunchValue();
        (token, poolId, tokensOut) = _launchAndBuyWithEth(params, launchConfigId, pairTokens, legs[0], minTokensOut, msg.value - seeds);
        for (uint256 i = 1; i < pairTokens.length; i++) {
            if (seedEth[i] == 0) continue;
            PoolKey memory key = factory.poolKeyFor(token, i);
            uint256 out = _buyAlongLeg(key, legs[i], seedEth[i], 0, msg.sender);
            emit BoltBuy(keccak256(abi.encode(key)), msg.sender, seedEth[i], out);
        }
    }

    // ---------------------------------------------------------------------
    // Balanced execution across every pool of a multi-market launch
    // ---------------------------------------------------------------------

    error NoActiveMarket();

    /// @dev The factory's equal split: 1/n per pool, market 0 taking the rounding remainder. Kept in step with FusingLaunchFactory.marketShareBps.
    function _shareBps(uint256 n, uint256 index) private pure returns (uint256) {
        if (n == 1) return 10_000;
        uint256 each = 10_000 / n;
        return index == 0 ? 10_000 - (n - 1) * each : each;
    }

    /**
     * @notice Buys `token` with native ETH across every one of its pools at
     * once, each pool taking its share of the value, so the pools move
     * together and no pool is left cheaper than the rest. `legs[i]` is the
     * route from ETH to pool i's quote (empty for an ETH-quoted pool). A
     * non-ETH pool whose leg is empty has no route and is left out; the value
     * is split over the pools that can be reached. One transaction, however
     * many pools, which is what a buyer during a closed window needs so the
     * launch never opens with a gap for arbitrage.
     */
    function buyWithEthAll(address token, Hop[][] calldata legs, uint256 minTokensOut, address recipient)
        external
        payable
        nonReentrant
        returns (uint256 tokensOut)
    {
        if (msg.value == 0) revert ZeroAmount();
        if (recipient == address(0)) revert ZeroAddress();
        FusingLaunchFactory.Market[] memory markets = factory.marketsOf(token);
        uint256 n = markets.length;
        if (legs.length != n) revert SeedPlanMismatch();
        // Shares over the reachable pools only.
        uint256 activeBps;
        for (uint256 i = 0; i < n; i++) {
            if (markets[i].pairToken == address(0) || legs[i].length > 0) activeBps += _shareBps(n, i);
        }
        if (activeBps == 0) revert NoActiveMarket();
        uint256 spent;
        for (uint256 i = 0; i < n; i++) {
            if (markets[i].pairToken != address(0) && legs[i].length == 0) continue;
            uint256 amount = (msg.value * _shareBps(n, i)) / activeBps;
            // The last reachable pool takes the rounding remainder so the whole value is spent.
            if (i == n - 1 || _isLastActive(markets, legs, i)) amount = msg.value - spent;
            if (amount == 0) continue;
            spent += amount;
            PoolKey memory key = factory.poolKeyFor(token, i);
            uint256 out = _buyAlongLeg(key, legs[i], amount, 0, recipient);
            tokensOut += out;
            emit BoltBuy(keccak256(abi.encode(key)), msg.sender, amount, out);
        }
        if (tokensOut < minTokensOut) revert SlippageExceeded(tokensOut, minTokensOut);
    }

    /// @dev True when no reachable pool follows index `i`.
    function _isLastActive(FusingLaunchFactory.Market[] memory markets, Hop[][] calldata legs, uint256 i) private pure returns (bool) {
        for (uint256 j = i + 1; j < markets.length; j++) {
            if (markets[j].pairToken == address(0) || legs[j].length > 0) return false;
        }
        return true;
    }

    /**
     * @notice Sells `tokensIn` of `token` across every one of its pools by
     * share and pays `recipient` in native ETH. `legs[i]` is the route from
     * pool i's quote to ETH (empty for an ETH-quoted pool); a non-ETH pool
     * with an empty leg is left out and its share goes to the others. The
     * caller must have approved the router for the tokens.
     */
    function sellToEthAll(address token, uint256 tokensIn, Hop[][] calldata legs, uint256 minEthOut, address recipient)
        external
        nonReentrant
        returns (uint256 ethOut)
    {
        if (tokensIn == 0) revert ZeroAmount();
        if (recipient == address(0)) revert ZeroAddress();
        FusingLaunchFactory.Market[] memory markets = factory.marketsOf(token);
        uint256 n = markets.length;
        if (legs.length != n) revert SeedPlanMismatch();
        uint256 activeBps;
        for (uint256 i = 0; i < n; i++) {
            if (markets[i].pairToken == address(0) || legs[i].length > 0) activeBps += _shareBps(n, i);
        }
        if (activeBps == 0) revert NoActiveMarket();
        uint256 sold;
        for (uint256 i = 0; i < n; i++) {
            if (markets[i].pairToken != address(0) && legs[i].length == 0) continue;
            uint256 amount = (tokensIn * _shareBps(n, i)) / activeBps;
            if (i == n - 1 || _isLastActive(markets, legs, i)) amount = tokensIn - sold;
            if (amount == 0) continue;
            sold += amount;
            PoolKey memory key = factory.poolKeyFor(token, i);
            bool tokenIs0 = Currency.unwrap(key.currency0) == token;
            Hop[] memory hops = new Hop[](1 + legs[i].length);
            hops[0] = Hop({key: key, kind: HopKind.V4});
            for (uint256 h = 0; h < legs[i].length; h++) {
                hops[h + 1] = legs[i][h];
            }
            (uint256 out,) = _route(
                Route({
                    hops: hops,
                    currencyIn: tokenIs0 ? key.currency0 : key.currency1,
                    amountIn: amount,
                    minAmountOut: 0,
                    payer: msg.sender,
                    recipient: recipient,
                    ethOut: true,
                    currencyOut: Currency.wrap(address(0))
                })
            );
            ethOut += out;
            emit BoltSell(keccak256(abi.encode(key)), msg.sender, amount, out);
        }
        if (ethOut < minEthOut) revert SlippageExceeded(ethOut, minEthOut);
    }

    /// @notice A launch with no opening buy: the plain form of the entry point, for any number of markets.
    function launch(FusingLaunchFactory.TokenParams calldata params, uint256 launchConfigId, address[] calldata pairTokens)
        external
        payable
        nonReentrant
        returns (address token, PoolId poolId)
    {
        if (msg.value != factory.launchFee()) revert InsufficientLaunchValue();
        return factory.launchTokenFor{value: msg.value}(params, launchConfigId, pairTokens, msg.sender);
    }

    function _launchAndBuyWithEth(
        FusingLaunchFactory.TokenParams calldata params,
        uint256 launchConfigId,
        address[] memory pairTokens,
        Hop[] calldata leg,
        uint256 minTokensOut,
        uint256 value
    ) private returns (address token, PoolId poolId, uint256 tokensOut) {
        uint256 launchFee = factory.launchFee();
        if (value < launchFee) revert InsufficientLaunchValue();
        uint256 buyValue = value - launchFee;

        // Launching clears the creator's staged terms, so the dev-lock choice has to be read before the launch call.
        (uint32 lockSecs, uint32 vestSecs) = _devLockTerms(msg.sender);
        (token, poolId) = factory.launchTokenFor{value: launchFee}(params, launchConfigId, pairTokens, msg.sender);
        if (buyValue == 0) return (token, poolId, 0);

        PoolKey memory key = factory.poolKeyFor(token);
        address to = lockSecs == 0 ? msg.sender : address(this);
        if (pairTokens[0] == address(0)) {
            Hop[] memory none;
            tokensOut = _buyAlongLeg(key, none, buyValue, minTokensOut, to);
        } else {
            tokensOut = _buyAlongLeg(key, leg, buyValue, minTokensOut, to);
            emit BoltBuy(PoolId.unwrap(poolId), msg.sender, buyValue, tokensOut);
        }
        _settleDevBuy(token, launchConfigId, tokensOut, lockSecs, vestSecs);
    }

    /**
     * @notice Launch-and-buy for a creator who already has the quote asset in
     * hand. The launch fee is sent as value; the opening buy is funded
     * straight from the caller's quote balance, so no swap leg is involved.
     */
    function launchAndBuyWithQuote(
        FusingLaunchFactory.TokenParams calldata params,
        uint256 launchConfigId,
        address pairToken,
        uint256 quoteIn,
        uint256 minTokensOut
    ) external payable nonReentrant returns (address token, PoolId poolId, uint256 tokensOut) {
        if (pairToken == address(0)) revert NativeQuoteNeedsNoBolt();
        if (msg.value != factory.launchFee()) revert InsufficientLaunchValue();

        (uint32 lockSecs, uint32 vestSecs) = _devLockTerms(msg.sender);
        address[] memory one = new address[](1);
        one[0] = pairToken;
        (token, poolId) = factory.launchTokenFor{value: msg.value}(params, launchConfigId, one, msg.sender);
        if (quoteIn == 0) return (token, poolId, 0);

        PoolKey memory key = factory.poolKeyFor(token);
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({key: key, kind: HopKind.V4});
        (tokensOut,) = _route(
            Route({
                hops: hops,
                currencyIn: Currency.wrap(pairToken),
                amountIn: quoteIn,
                minAmountOut: minTokensOut,
                payer: msg.sender,
                recipient: lockSecs == 0 ? msg.sender : address(this),
                ethOut: false,
                currencyOut: Currency.unwrap(key.currency0) == token ? key.currency0 : key.currency1
            })
        );
        _settleDevBuy(token, launchConfigId, tokensOut, lockSecs, vestSecs);
    }

    // ---------------------------------------------------------------------
    // Creator opening-buy cap
    // ---------------------------------------------------------------------

    error DevBuyTooLarge(uint256 tokens, uint256 cap);
    error TokenLockNotWired();

    event DevBuyLocked(address indexed token, address indexed creator, uint256 amount, uint64 unlockAt, uint32 vestSeconds, uint256 lockId);

    /// @dev Reads the lock and vest lengths the creator staged, ahead of the launch clearing those terms.
    function _devLockTerms(address launcher) private view returns (uint32 lockSecs, uint32 vestSecs) {
        FusingTerms.LaunchTerms memory t = factory.termsOf(launcher);
        return (t.devLockSeconds, t.devVestSeconds);
    }

    /**
     * @dev Enforces the opening-buy cap. Up to DEV_BUY_FREE_BPS of supply may
     * go directly to the creator's wallet; up to DEV_BUY_LOCKED_BPS may be
     * bought if the whole amount goes into FusingTokenLock for no less than
     * the minimum lock. When a lock is staged the buy is delivered to this
     * contract and passed to the lock within the same transaction, so at no
     * point do the tokens rest in the creator's wallet.
     */
    function _settleDevBuy(address token, uint256 launchConfigId, uint256 tokensOut, uint32 lockSecs, uint32 vestSecs) private {
        uint256 supply = factory.getLaunchConfig(launchConfigId).supply;
        if (lockSecs == 0) {
            uint256 free = supply * factory.DEV_BUY_FREE_BPS() / 10_000;
            if (tokensOut > free) revert DevBuyTooLarge(tokensOut, free);
            return;
        }
        uint256 cap = supply * factory.DEV_BUY_LOCKED_BPS() / 10_000;
        if (tokensOut > cap) revert DevBuyTooLarge(tokensOut, cap);
        address lockAddr = factory.tokenLock();
        if (lockAddr == address(0)) revert TokenLockNotWired();
        uint64 unlockAt = uint64(block.timestamp) + lockSecs;
        IERC20(token).forceApprove(lockAddr, tokensOut);
        uint256 id = IFusingTokenLock(lockAddr).lock(token, msg.sender, tokensOut, unlockAt, vestSecs);
        emit DevBuyLocked(token, msg.sender, tokensOut, unlockAt, vestSecs, id);
    }

    // ---------------------------------------------------------------------
    // Building the hop list
    // ---------------------------------------------------------------------

    /// @dev Routes `ethIn` down `leg` and then through launch pool `key`.
    function _buyAlongLeg(
        PoolKey memory key,
        Hop[] memory leg,
        uint256 ethIn,
        uint256 minTokensOut,
        address recipient
    ) private returns (uint256 tokensOut) {
        Hop[] memory hops = new Hop[](leg.length + 1);
        for (uint256 i = 0; i < leg.length; i++) {
            hops[i] = leg[i];
        }
        hops[leg.length] = Hop({key: key, kind: HopKind.V4});
        Currency tokenCurrency = _launchTokenOf(key, leg);

        (tokensOut,) = _route(
            Route({
                hops: hops,
                currencyIn: Currency.wrap(address(0)),
                amountIn: ethIn,
                minAmountOut: minTokensOut,
                payer: msg.sender,
                recipient: recipient,
                ethOut: false,
                currencyOut: tokenCurrency
            })
        );
    }

    /**
     * @dev Which side of the launch pool is the launch token: the one the
     * leg does not deliver into. Without a leg the buy arrives in ETH, so
     * the token is whichever side is not ETH.
     */
    function _launchTokenOf(PoolKey memory key, Hop[] memory leg) private view returns (Currency) {
        if (leg.length == 0) return _isEth(key.currency0) ? key.currency1 : key.currency0;
        PoolKey memory last = leg[leg.length - 1].key;
        bool quoteIs0 = key.currency0 == last.currency0 || key.currency0 == last.currency1;
        return quoteIs0 ? key.currency1 : key.currency0;
    }

    // ---------------------------------------------------------------------
    // Walking a route
    // ---------------------------------------------------------------------

    function _route(Route memory r) private returns (uint256 amountOut, Currency currencyOut) {
        bytes memory result = manager.unlock(abi.encode(r));
        (amountOut, currencyOut) = abi.decode(result, (uint256, Currency));
    }

    /**
     * @dev Runs the route one hop at a time while keeping track of where the
     * asset is. A V4 hop swaps inside the PoolManager, and its input is paid
     * from wherever the asset currently sits: offset against a credit
     * already in the manager, sent from this contract, or pulled from the
     * caller. A V3 hop can only trade what this contract holds, so any
     * manager credit is taken out beforehand, and its output stays here for
     * the following hop to settle in. Native ETH and WETH count as the same
     * asset and are converted whenever a hop needs the other form. If a hop
     * exhausts its liquidity it consumes less than it was offered, and the
     * remainder is returned to the payer immediately.
     */
    function unlockCallback(bytes calldata raw) external returns (bytes memory) {
        if (msg.sender != address(manager)) revert NotPoolManager();
        Route memory r = abi.decode(raw, (Route));

        Currency cur = r.currencyIn;
        uint256 amt = r.amountIn;
        Where at = Where.Caller;
        uint256 n = r.hops.length;
        for (uint256 i = 0; i < n; i++) {
            Hop memory hop = r.hops[i];
            (Currency hopIn, Currency hopOut, bool ok) = _sides(hop, cur);
            if (!ok) revert RouteBroken(i);

            if (hop.kind == HopKind.V2) {
                (cur, amt, at) = _v2Hop(hop, cur, hopOut, amt, at, r.payer);
            } else if (hop.kind == HopKind.V3) {
                (cur, amt, at) = _v3Hop(hop, cur, hopOut, amt, at, r.payer);
            } else {
                (cur, amt, at) = _v4Hop(hop, cur, hopIn, hopOut, amt, at, r.payer);
            }
        }
        if (amt < r.minAmountOut) revert SlippageExceeded(amt, r.minAmountOut);

        if (r.ethOut) {
            if (!_isEth(cur)) revert RouteEndMismatch(address(0), Currency.unwrap(cur));
            (cur, amt, at) = _asNative(cur, amt, at);
            if (at == Where.Manager) manager.take(cur, r.recipient, amt);
            else _sendEth(r.recipient, amt);
        } else {
            if (!(cur == r.currencyOut)) revert RouteEndMismatch(Currency.unwrap(r.currencyOut), Currency.unwrap(cur));
            if (at == Where.Manager) manager.take(cur, r.recipient, amt);
            else if (cur.isAddressZero()) _sendEth(r.recipient, amt);
            else IERC20(Currency.unwrap(cur)).safeTransfer(r.recipient, amt);
        }
        return abi.encode(amt, cur);
    }

    /**
     * @dev A single V4 swap. The input is settled from wherever the asset is
     * at that moment; the output is left as a PoolManager credit for the
     * hop after it.
     */
    function _v4Hop(
        Hop memory hop,
        Currency cur,
        Currency hopIn,
        Currency hopOut,
        uint256 amt,
        Where at,
        address payer
    ) private returns (Currency, uint256, Where) {
        if (!(cur == hopIn)) {
            // This pool wants ETH in the other form, so bring it here and convert.
            (cur, amt, at) = _bring(cur, amt, at, payer);
            (cur, amt) = hopIn.isAddressZero() ? _toNative(cur, amt) : _toWeth(cur, amt);
        }

        // Settle FIRST, then size the swap by what the PoolManager reports
        // it actually received. The obvious order, swap then settle, is
        // wrong for a quote asset that charges a fee on transfer: the manager
        // receives less than was sent, the swap sized on the sent figure
        // leaves a delta nobody can clear, and the unlock reverts with
        // CurrencyNotSettled. Settling first makes the arithmetic true for a
        // taxed asset and an ordinary one alike, since for an ordinary one
        // the two figures are identical. Whatever the swap leaves unused is
        // still a credit and is taken out to the payer.
        //
        // Split into two helpers on purpose: this loop sits at the Yul
        // optimiser's stack limit, and the first attempt at this fix, written
        // inline, pushed it over.
        if (at != Where.Manager) amt = _prefund(cur, amt, at, payer);
        uint256 out;
        (out, amt) = _swapCredit(hop.key, cur, amt, payer);
        if (amt != 0) manager.take(cur, payer, amt);
        return (hopOut, out, Where.Manager);
    }

    /**
     * @dev Moves `amt` of `cur` from wherever it sits (this contract, or the
     * caller) into the PoolManager as a credit, and returns what the manager
     * reports it received, which is less than `amt` for a taxed asset.
     */
    function _prefund(Currency cur, uint256 amt, Where at, address payer) private returns (uint256 received) {
        manager.sync(cur);
        if (cur.isAddressZero()) {
            // Attached native value already sits in this contract.
            return manager.settle{value: amt}();
        }
        if (at == Where.Router) IERC20(Currency.unwrap(cur)).safeTransfer(address(manager), amt);
        else IERC20(Currency.unwrap(cur)).safeTransferFrom(payer, address(manager), amt);
        received = manager.settle();
    }

    /// @dev Swaps a PoolManager credit of `amt` in `cur` through `key`; returns the output and the unused credit.
    function _swapCredit(PoolKey memory key, Currency cur, uint256 amt, address payer)
        private
        returns (uint256 out, uint256 leftover)
    {
        bool zeroForOne = cur == key.currency0;
        BalanceDelta delta = manager.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amt),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            // V2: passes the real trader to the fee hook, so a whitelisted wallet
            // is spared the launch-block premium. Only this contract sets it; the caller never does.
            abi.encode(payer)
        );
        int128 inSigned = zeroForOne ? delta.amount0() : delta.amount1();
        int128 outSigned = zeroForOne ? delta.amount1() : delta.amount0();
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 consumed = uint256(uint128(-inSigned));
        // forge-lint: disable-next-line(unsafe-typecast)
        out = uint256(uint128(outSigned));
        leftover = amt - consumed;
    }

    /**
     * @dev A single V3 swap via SwapRouter02. The input must already be in
     * this contract, and the output is delivered back here.
     */
    function _v3Hop(Hop memory hop, Currency cur, Currency hopOut, uint256 amt, Where at, address payer)
        private
        returns (Currency, uint256, Where)
    {
        (cur, amt, at) = _bring(cur, amt, at, payer);
        address tokenOut = Currency.unwrap(hopOut);
        uint256 value;
        if (cur.isAddressZero()) {
            // With tokenIn set to WETH9, SwapRouter02 wraps the attached value itself.
            value = amt;
        } else {
            IERC20(Currency.unwrap(cur)).forceApprove(address(swapRouter), amt);
        }
        uint256 out = swapRouter.exactInputSingle{value: value}(
            ISwapRouter02.ExactInputSingleParams({
                tokenIn: cur.isAddressZero() ? address(weth) : Currency.unwrap(cur),
                tokenOut: tokenOut,
                fee: hop.key.fee,
                recipient: address(this),
                amountIn: amt,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );
        return (hopOut, out, Where.Router);
    }

    /**
     * @dev A single Uniswap V2 swap, executed against the pair directly.
     *
     * The pair is resolved from the factory the PRICER holds rather than one
     * of the router's own, so the two can never disagree about what a V2 hop
     * means: clearing `v2Factory` on the pricer stops the router executing V2
     * hops in the same transaction, with no second switch to remember.
     *
     * V2 pairs hold WETH, never native ETH, so a native input is wrapped
     * first. The output is left as WETH; the caller's exit path converts it
     * back if the route ends in ETH, exactly as it does after a V3 hop.
     */
    function _v2Hop(Hop memory hop, Currency cur, Currency hopOut, uint256 amt, Where at, address payer)
        private
        returns (Currency, uint256, Where)
    {
        (cur, amt, at) = _bring(cur, amt, at, payer);
        (cur, amt) = _toWeth(cur, amt);

        address tokenIn = Currency.unwrap(cur);
        address tokenOut = Currency.unwrap(hopOut);
        if (tokenOut == address(0)) tokenOut = address(weth);

        address factoryV2 = address(factory.quotePricer().v2Factory());
        if (factoryV2 == address(0)) revert RouteBroken(0);

        // Resolved from the hop's own key rather than from the assets in
        // hand, so the swap lands in the pool the pricer approved and not
        // merely in some pool joining the same two tokens.
        address pair = IUniswapV2FactoryLookup(factoryV2).getPair(
            Currency.unwrap(hop.key.currency0), Currency.unwrap(hop.key.currency1)
        );
        if (pair == address(0)) revert RouteBroken(0);

        bool inIsToken0 = tokenIn < tokenOut;

        // Send FIRST, then read the reserves, then size the swap from the
        // pair's balance over its reserve: exactly what the pair itself will
        // compute as the input.
        //
        // The obvious order, read and compute then send, is wrong twice over
        // for a taxed asset. The pair receives less than was sent, so an
        // output sized on the sent figure is too large. And a taxed token's
        // transfer can run the token's own "swapback", selling its collected
        // tax through this very pair from inside our transfer, so reserves
        // read beforehand are stale by the time the swap runs. Either way
        // V2's invariant check rejects the swap with "UniswapV2: K". Reading
        // after the transfer is what Uniswap's own fee-on-transfer router
        // does, and for an ordinary token the figures are identical.
        IERC20(tokenIn).safeTransfer(pair, amt);
        (uint112 r0, uint112 r1,) = IUniswapV2PairSwap(pair).getReserves();
        (uint256 reserveIn, uint256 reserveOut) = inIsToken0 ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
        if (reserveIn == 0 || reserveOut == 0) revert RouteBroken(0);
        uint256 arrived = IERC20(tokenIn).balanceOf(pair) - reserveIn;
        if (arrived == 0) revert RouteBroken(0);

        // V2's constant product with its fixed 0.3% fee. Computed here rather
        // than read from the pair because V2 exposes no quoting function.
        uint256 amountInWithFee = arrived * 997;
        uint256 out = (amountInWithFee * reserveOut) / (reserveIn * 1000 + amountInWithFee);
        if (out == 0) revert RouteBroken(0);

        // What the pair sends and what this contract receives also differ for
        // a taxed OUTPUT asset, so the hop reports what it actually holds.
        uint256 heldBefore = IERC20(tokenOut).balanceOf(address(this));
        IUniswapV2PairSwap(pair).swap(inIsToken0 ? 0 : out, inIsToken0 ? out : 0, address(this), "");
        uint256 received = IERC20(tokenOut).balanceOf(address(this)) - heldBefore;

        return (Currency.wrap(tokenOut), received, Where.Router);
    }

    /// @dev Brings the asset into this contract's balance, whatever its current location.
    function _bring(Currency cur, uint256 amt, Where at, address payer) private returns (Currency, uint256, Where) {
        // Native ETH sent by the caller already sits in this contract, and
        // native taken out of the manager arrives in full.
        if (at == Where.Router || cur.isAddressZero()) {
            if (at == Where.Manager) manager.take(cur, address(this), amt);
            return (cur, amt, Where.Router);
        }
        // An ERC-20 is credited by what actually arrived, not what was sent:
        // a taxed asset delivers less, and the next hop must trade only what
        // this contract really holds.
        IERC20 t = IERC20(Currency.unwrap(cur));
        uint256 before = t.balanceOf(address(this));
        if (at == Where.Manager) manager.take(cur, address(this), amt);
        else t.safeTransferFrom(payer, address(this), amt);
        return (cur, t.balanceOf(address(this)) - before, Where.Router);
    }

    /// @dev Takes ETH in whichever form it currently has and makes sure it ends up native.
    function _asNative(Currency cur, uint256 amt, Where at) private returns (Currency, uint256, Where) {
        if (cur.isAddressZero()) return (cur, amt, at);
        if (at == Where.Manager) {
            manager.take(cur, address(this), amt);
            at = Where.Router;
        }
        (cur, amt) = _toNative(cur, amt);
        return (cur, amt, at);
    }

    function _toNative(Currency cur, uint256 amt) private returns (Currency, uint256) {
        if (cur.isAddressZero()) return (cur, amt);
        weth.withdraw(amt);
        return (Currency.wrap(address(0)), amt);
    }

    function _toWeth(Currency cur, uint256 amt) private returns (Currency, uint256) {
        if (!cur.isAddressZero()) return (cur, amt);
        weth.deposit{value: amt}();
        return (Currency.wrap(address(weth)), amt);
    }

    /**
     * @dev Works out the entry and exit sides of `hop` for the asset. Native
     * ETH and WETH are accepted for each other, which lets a route cross
     * between V3 pools (WETH) and native-ETH V4 pools; the caller does the
     * conversion.
     */
    function _sides(Hop memory hop, Currency cur) private view returns (Currency hopIn, Currency hopOut, bool ok) {
        Currency c0 = hop.key.currency0;
        Currency c1 = hop.key.currency1;
        if (cur == c0) return (c0, c1, true);
        if (cur == c1) return (c1, c0, true);
        if (_isEth(cur)) {
            if (_isEth(c0)) return (c0, c1, true);
            if (_isEth(c1)) return (c1, c0, true);
        }
        return (hopIn, hopOut, false);
    }

    function _isEth(Currency c) private view returns (bool) {
        return c.isAddressZero() || Currency.unwrap(c) == address(weth);
    }

    // ---------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------

    function _poolId(PoolKey calldata key) private pure returns (bytes32) {
        return keccak256(abi.encode(key));
    }

    function _sendEth(address recipient, uint256 amount) private {
        (bool sent,) = payable(recipient).call{value: amount}("");
        if (!sent) revert EthTransferFailed();
    }

    /// @notice Receives ETH coming back from the PoolManager and from WETH withdrawals.
    receive() external payable {}
}
