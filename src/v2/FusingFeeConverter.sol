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
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {FusingLaunchFactory} from "./FusingLaunchFactory.sol";
import {FusingRouter} from "./FusingRouter.sol";
import {FusingQuotePricer} from "./FusingQuotePricer.sol";
import {FusingTerms} from "./libraries/FusingTerms.sol";
import {FusingSwapGuard} from "./libraries/FusingSwapGuard.sol";
import {Hop, HopKind} from "./libraries/Hop.sol";
import {IFusingFeeEscrow, IFusingLaunchFactory} from "./interfaces/ILaunchpadV2.sol";

/// @dev The single fee hook getter this contract reads.
/// @dev The Fuse Vault as the converter sees it: the payout mode per launch, and the deposit that hands the creator's share over.
interface IStockDesk {
    function book(address stock, address launchToken, uint256 creatorAmount, address protocolRecipient, uint256 protocolAmount) external;
}

interface IFuseVaultSink {
    function payoutOf(address token) external view returns (FusingTerms.PayoutMode);
    function deposit(address token, address currency, uint256 amount) external payable;
}

interface IFusingFeeHookFee {
    function currentFee(PoolId id) external view returns (uint24);
}

/**
 * @title FusingFeeConverter
 * @notice Converts each collected fee into the asset it is to be paid in.
 *
 * A Uniswap V4 pool charges its fee in whatever the trader sent, so buys pay
 * fees in the quote asset and sells pay them in the launch token. In V1 the
 * creator received both as they were and the protocol's token side was
 * burned. In V2 the locker passes every collection to this contract, which
 *
 *   1. divides it 60/40 (or on whatever split the launch fixed) between the
 *      creator and the protocol,
 *   2. sells the protocol's token side into the launch's own pool, converts
 *      the protocol's whole share to ETH without exception (along the
 *      pricer's route whenever the quote is not ETH), and pays it out,
 *   3. pays the creator according to the launch's payout mode:
 *        ETH              everything is sold and converted the same way,
 *        QUOTE            the token side is sold, all of it paid in the quote,
 *        TOKEN_AND_QUOTE  nothing is sold; tokens stay tokens, quote stays quote,
 *        TOKEN            the quote side buys the token back from the pool,
 *                         all of it paid in tokens,
 *      and credits that to the escrow, where the launch's payout plan splits
 *      it between the dev wallet, the liquidity vault and the burn vault.
 *
 * Each sale and each buyback is bounded by FusingSwapGuard: no more than a
 * MAX_SQRT_MOVE_BPS move in the pool's square-root price per call, with a
 * floor at the pre-swap price minus TOLERANCE_BPS. Anything a call cannot
 * trade inside those bounds is kept here as `pending` and retried on the
 * next collection, or when anyone calls `convert`. A trade whose floor
 * cannot be met is skipped; it is never sent unprotected.
 *
 * This contract has no owner. Only the locker may call `settle`; `convert`
 * is open to all; and every path pays the recipients recorded for the
 * launch and no one else.
 */
contract FusingFeeConverter is ReentrancyGuard {
    using SafeERC20 for IERC20;
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    error NotLocker();
    error ZeroAddress();
    error NativeMismatch(uint256 expected, uint256 got);
    /// @dev The router returned less than the floor it was asked to honour. Only a router other than fusi.ng's could do that.
    error ShortFill(uint256 got, uint256 minOut);

    /**
     * @notice Emitted once per settlement or conversion round. `quoteToCreator`
     * is only ever nonzero for a pool not quoted in ETH running in QUOTE or
     * TOKEN_AND_QUOTE mode; `tokensHanded` only in TOKEN_AND_QUOTE and TOKEN
     * mode (and in TOKEN mode it includes `tokensBought`, the amount the quote
     * side bought back).
     */
    event Settled(
        address indexed token,
        uint256 ethToProtocol,
        uint256 ethToCreator,
        uint256 quoteToCreator,
        uint256 tokensHanded,
        uint256 tokensBought,
        uint256 tokensSold,
        uint256 quoteSold
    );
    event Pending(address indexed token, uint256 protocolToken, uint256 creatorToken, uint256 protocolQuote, uint256 creatorQuote);

    /// @notice Cap on how far one trade may push the pool's sqrt price: 0.5%, roughly 1% in price terms.
    uint256 public constant MAX_SQRT_MOVE_BPS = 50;
    /// @notice How far below the pre-swap price a trade may fill: 3%.
    uint256 public constant TOLERANCE_BPS = 300;
    /// @notice Amounts under this many raw units are not traded; they pile up as dust until they are.
    uint256 public constant MIN_SWAP = 1000;
    uint256 private constant BPS = 10_000;
    uint256 private constant WAD = 1e18;

    address public immutable locker;
    FusingLaunchFactory public immutable factory;
    FusingRouter public immutable router;
    FusingQuotePricer public immutable pricer;
    IFusingFeeEscrow public immutable feeEscrow;
    IPoolManager public immutable poolManager;

    /**
     * @notice Per-launch fees that have been collected but not converted yet.
     * Launch tokens are queued to be sold for the quote; the protocol's quote
     * is queued to be sold for ETH. `creatorQuote` has one of two meanings,
     * decided per launch by its mode: under ETH mode it is quote waiting to
     * be sold for ETH; under TOKEN mode it is quote (or ETH, on a native
     * pool) waiting to buy the token back. In the remaining modes the
     * creator's quote is paid straight through and is never queued.
     */
    struct PendingFees {
        uint256 protocolToken;
        uint256 creatorToken;
        uint256 protocolQuote;
        uint256 creatorQuote;
    }

    mapping(address token => PendingFees) public pending;

    /// @dev Running totals of what a round pays out, filled in step by step.
    struct Payout {
        uint256 ethProtocol;
        uint256 ethCreator;
        uint256 quoteCreator;
        /// @dev The protocol's share in the quote itself: only for a quote that has no route to ETH.
        uint256 quoteProtocol;
        uint256 tokensHanded;
        uint256 tokensBought;
        uint256 tokensSold;
        uint256 quoteSold;
    }

    constructor(address locker_, FusingLaunchFactory factory_, FusingRouter router_, FusingQuotePricer pricer_, IFusingFeeEscrow escrow_, IPoolManager poolManager_) {
        if (
            locker_ == address(0) || address(factory_) == address(0) || address(router_) == address(0)
                || address(pricer_) == address(0) || address(escrow_) == address(0) || address(poolManager_) == address(0)
        ) revert ZeroAddress();
        locker = locker_;
        factory = factory_;
        router = router_;
        pricer = pricer_;
        feeEscrow = escrow_;
        poolManager = poolManager_;
    }

    receive() external payable {}

    /// @dev Where the creator's share goes and where the payout mode is read: the Fuse Vault.
    IFuseVaultSink public vault;
    /// @notice Where fees that arrive as a route-less quote (a tokenised stock) go to be sold for ETH. Unset: they are paid in kind.
    IStockDesk public desk;

    function setDesk(IStockDesk desk_) external {
        if (msg.sender != factory.owner()) revert NotFactoryOwner();
        desk = desk_;
    }

    event VaultSet(address vault);

    error NotFactoryOwner();

    /// @notice Wired once by the factory owner; the converter pays the creator's share into it from then on.
    function setVault(IFuseVaultSink vault_) external {
        if (msg.sender != factory.owner()) revert NotFactoryOwner();
        if (address(vault_) == address(0)) revert ZeroAddress();
        vault = vault_;
        emit VaultSet(address(vault_));
    }

    /**
     * @notice The router trades are sent through. It is the factory's launch
     * forwarder, which is the fusi.ng router and can be rotated on the
     * factory, so a fixed router reaches this contract with no redeploy. The
     * router passed at construction serves as the fallback while no
     * forwarder is set. Every trade compares what actually arrived with its
     * floor, so a forwarder that is not our router cannot short-change us;
     * the worst it can do is fail.
     */
    function activeRouter() public view returns (FusingRouter) {
        address forwarder = factory.launchForwarder();
        return forwarder == address(0) ? router : FusingRouter(payable(forwarder));
    }

    /// @dev This contract's balance of `asset` (address zero means ETH).
    function _held(address asset) private view returns (uint256) {
        return asset == address(0) ? address(this).balance : IERC20(asset).balanceOf(address(this));
    }

    /**
     * @notice Entry point for the locker to deliver one collection:
     * `tokenAmount` of the launch token and `quoteAmount` of the quote, both
     * already sent to this contract (a native quote comes as msg.value).
     * Splits it, converts it and pays it out.
     */
    function settle(address token, uint256 tokenAmount, uint256 quoteAmount) external payable nonReentrant {
        if (msg.sender != locker) revert NotLocker();
        IFusingLaunchFactory.LaunchedToken memory launch = factory.getLaunchedToken(token);
        PoolKey memory key = factory.poolKeyFor(token);
        bool nativeQuote = launch.pairToken == address(0);
        if (nativeQuote ? msg.value != quoteAmount : msg.value != 0) revert NativeMismatch(nativeQuote ? quoteAmount : 0, msg.value);

        uint256 protocolWad = _protocolShareWad(launch);
        PendingFees storage p = pending[token];
        FusingTerms.PayoutMode mode = vault.payoutOf(token);
        Payout memory out;

        // A quote that charges a fee on transfer delivers less than the
        // locker sent. Everything this contract holds of the quote is either
        // already queued or just arrived, so the arrival is whatever sits
        // above the queue. For an ordinary asset the two figures are equal.
        if (!nativeQuote) {
            uint256 held = _held(launch.pairToken);
            uint256 queued = p.protocolQuote + p.creatorQuote;
            // Never underflow: a queue that has run ahead of the balance by
            // rounding must not brick every later collection of this launch.
            uint256 unaccounted = held > queued ? held - queued : 0;
            if (quoteAmount > unaccounted) quoteAmount = unaccounted;
        }

        // The token side. The protocol's portion is sold, always. The creator's
        // is passed on as tokens if the mode pays in tokens, otherwise sold.
        {
            uint256 protocolTok = tokenAmount * protocolWad / WAD;
            uint256 creatorTok = tokenAmount - protocolTok;
            p.protocolToken += protocolTok;
            if (mode == FusingTerms.PayoutMode.TOKEN_AND_QUOTE || mode == FusingTerms.PayoutMode.TOKEN) {
                out.tokensHanded += creatorTok;
            } else {
                p.creatorToken += creatorTok;
            }
        }

        // The quote side. The protocol's portion: kept as is when it is ETH,
        // queued for conversion otherwise. The creator's: depends on the mode.
        {
            uint256 protocolQ = quoteAmount * protocolWad / WAD;
            uint256 creatorQ = quoteAmount - protocolQ;
            if (nativeQuote) out.ethProtocol += protocolQ;
            else p.protocolQuote += protocolQ;

            if (mode == FusingTerms.PayoutMode.TOKEN) {
                p.creatorQuote += creatorQ; // spent on the buyback further down
            } else if (nativeQuote) {
                out.ethCreator += creatorQ;
            } else if (mode == FusingTerms.PayoutMode.ETH) {
                p.creatorQuote += creatorQ; // converted to ETH further down
            } else {
                out.quoteCreator += creatorQ; // QUOTE and TOKEN_AND_QUOTE: passed through unchanged
            }
        }

        _convert(token, launch, key, p, mode, out);
        _pay(token, launch, out);
        _emit(token, p, out);
    }

    /**
     * @notice Converts and pays out everything still queued for `token`.
     * Anyone may call it, so a trade that was deferred need not wait for the
     * next collection to happen.
     */
    function convert(address token) external nonReentrant {
        IFusingLaunchFactory.LaunchedToken memory launch = factory.getLaunchedToken(token);
        PoolKey memory key = factory.poolKeyFor(token);
        PendingFees storage p = pending[token];
        Payout memory out;
        _convert(token, launch, key, p, vault.payoutOf(token), out);
        _pay(token, launch, out);
        _emit(token, p, out);
    }

    function _emit(address token, PendingFees storage p, Payout memory out) private {
        emit Settled(
            token,
            out.ethProtocol,
            out.ethCreator,
            out.quoteCreator,
            out.tokensHanded,
            out.tokensBought,
            out.tokensSold,
            out.quoteSold
        );
        emit Pending(token, p.protocolToken, p.creatorToken, p.protocolQuote, p.creatorQuote);
    }

    // ---------------------------------------------------------------------
    // Converting
    // ---------------------------------------------------------------------

    /**
     * @dev Three bounded steps, each one skipped if it has nothing to do:
     * queued launch tokens are sold into the pool for the quote; queued quote
     * is sold for ETH along the pricer's route; and, under TOKEN mode, the
     * creator's queued quote buys the token back. When a sale covers both
     * parties, the proceeds are divided between protocol and creator in the
     * ratio of what each had queued, so a partial fill pays each their fair
     * fraction and leaves the remainder queued in that same ratio.
     */
    function _convert(
        address token,
        IFusingLaunchFactory.LaunchedToken memory launch,
        PoolKey memory key,
        PendingFees storage p,
        FusingTerms.PayoutMode mode,
        Payout memory out
    ) private {
        bool nativeQuote = launch.pairToken == address(0);
        bool creatorInQuote =
            mode == FusingTerms.PayoutMode.QUOTE || mode == FusingTerms.PayoutMode.TOKEN_AND_QUOTE;

        // 1. Launch token into quote (straight into ETH when the pool is quoted in ETH).
        uint256 totalTok = p.protocolToken + p.creatorToken;
        if (totalTok >= MIN_SWAP) {
            (uint256 sold, uint256 got) = _sellToken(token, key, launch.pairToken, totalTok);
            if (sold > 0) {
                uint256 protocolPart = sold * p.protocolToken / totalTok;
                uint256 creatorPart = sold - protocolPart;
                p.protocolToken -= protocolPart;
                p.creatorToken -= creatorPart;
                out.tokensSold += sold;
                uint256 gotProtocol = got * protocolPart / sold;
                uint256 gotCreator = got - gotProtocol;
                if (nativeQuote) out.ethProtocol += gotProtocol;
                else p.protocolQuote += gotProtocol;

                if (mode == FusingTerms.PayoutMode.TOKEN) p.creatorQuote += gotCreator;
                else if (nativeQuote) out.ethCreator += gotCreator;
                else if (creatorInQuote) out.quoteCreator += gotCreator;
                else p.creatorQuote += gotCreator;
            }
        }

        // 2. Quote into ETH along the pricer's route: always for the protocol,
        //    for the creator only under ETH mode.
        if (!nativeQuote && _noRoute(launch.pairToken)) {
            // A quote with no pool route to ETH at all (a tokenised stock priced by oracle): nothing here
            // can sell it, and queueing it would hold it for ever. Everyone is paid in the quote itself,
            // whatever the mode; the protocol's share is sold off chain by the treasury.
            out.quoteProtocol += p.protocolQuote;
            out.quoteCreator += p.creatorQuote;
            p.protocolQuote = 0;
            p.creatorQuote = 0;
        } else if (!nativeQuote) {
            uint256 creatorQ = mode == FusingTerms.PayoutMode.ETH ? p.creatorQuote : 0;
            uint256 totalQ = p.protocolQuote + creatorQ;
            if (totalQ >= MIN_SWAP) {
                uint256 got = _sellQuote(launch.pairToken, totalQ);
                if (got > 0) {
                    uint256 gotProtocol = got * p.protocolQuote / totalQ;
                    out.ethProtocol += gotProtocol;
                    out.ethCreator += got - gotProtocol;
                    out.quoteSold += totalQ;
                    p.protocolQuote = 0;
                    p.creatorQuote -= creatorQ;
                }
            }
        }

        // 3. Under TOKEN mode, the creator's quote is spent buying the token back.
        if (mode == FusingTerms.PayoutMode.TOKEN && p.creatorQuote >= MIN_SWAP) {
            // Spend no more than is really here (a taxed quote's queue can overstate it).
            uint256 available = p.creatorQuote;
            if (!nativeQuote && available > _held(launch.pairToken)) available = _held(launch.pairToken);
            (uint256 spent, uint256 got) = _buyToken(token, key, launch.pairToken, available);
            if (spent > 0) {
                p.creatorQuote -= spent;
                out.tokensBought += got;
                out.tokensHanded += got;
            }
        }
    }

    /// @dev The pool's fee right now: the static fee, or what the V2 hook's schedule says. A value of PIPS means "do not trade".
    function _fee(PoolKey memory key, PoolId id) private view returns (uint24 fee) {
        fee = key.fee;
        if (fee == LPFeeLibrary.DYNAMIC_FEE_FLAG) {
            try IFusingFeeHookFee(address(key.hooks)).currentFee(id) returns (uint24 f) {
                fee = f;
            } catch {
                fee = uint24(FusingSwapGuard.PIPS);
            }
        }
    }

    /// @dev A single bounded sale of the launch token into its own pool. Returns the amount sold and the amount received, both measured from this contract's balance rather than trusted from the router.
    function _sellToken(address token, PoolKey memory key, address quote, uint256 available)
        private
        returns (uint256 sold, uint256 got)
    {
        PoolId id = key.toId();
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(id);
        uint128 liquidity = poolManager.getLiquidity(id);
        if (sqrtPriceX96 == 0 || liquidity == 0) return (0, 0);
        uint24 fee = _fee(key, id);
        if (fee >= FusingSwapGuard.PIPS) return (0, 0);
        bool tokenIs0 = Currency.unwrap(key.currency0) == token;
        uint256 amountIn = FusingSwapGuard.cappedInput(sqrtPriceX96, liquidity, fee, tokenIs0, available, MAX_SQRT_MOVE_BPS);
        if (amountIn < MIN_SWAP) return (0, 0);
        (uint256 minOut, bool ok) = FusingSwapGuard.floor(sqrtPriceX96, fee, tokenIs0, amountIn, TOLERANCE_BPS);
        if (!ok) return (0, 0);

        FusingRouter r = activeRouter();
        uint256 before = _held(quote);
        IERC20(token).forceApprove(address(r), amountIn);
        try r.swapExactIn(key, tokenIs0, amountIn, minOut, address(this)) returns (uint256) {}
        catch {
            IERC20(token).forceApprove(address(r), 0);
            return (0, 0);
        }
        IERC20(token).forceApprove(address(r), 0);
        got = _held(quote) - before;
        if (got < minOut) revert ShortFill(got, minOut);
        sold = amountIn;
    }

    /// @dev A single bounded buyback of the launch token via its own pool, paid for in the quote (or ETH). Returns the amount spent and the amount received, measured from this contract's balance.
    function _buyToken(address token, PoolKey memory key, address quote, uint256 available) private returns (uint256 spent, uint256 got) {
        PoolId id = key.toId();
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(id);
        uint128 liquidity = poolManager.getLiquidity(id);
        if (sqrtPriceX96 == 0 || liquidity == 0) return (0, 0);
        uint24 fee = _fee(key, id);
        if (fee >= FusingSwapGuard.PIPS) return (0, 0);
        bool zeroForOne = Currency.unwrap(key.currency0) != token; // the quote is the input side
        uint256 amountIn = FusingSwapGuard.cappedInput(sqrtPriceX96, liquidity, fee, zeroForOne, available, MAX_SQRT_MOVE_BPS);
        if (amountIn < MIN_SWAP) return (0, 0);
        (uint256 minOut, bool ok) = FusingSwapGuard.floor(sqrtPriceX96, fee, zeroForOne, amountIn, TOLERANCE_BPS);
        if (!ok) return (0, 0);

        FusingRouter r = activeRouter();
        uint256 before = _held(token);
        if (quote == address(0)) {
            try r.swapExactIn{value: amountIn}(key, zeroForOne, amountIn, minOut, address(this)) returns (uint256) {}
            catch {
                return (0, 0);
            }
        } else {
            IERC20(quote).forceApprove(address(r), amountIn);
            try r.swapExactIn(key, zeroForOne, amountIn, minOut, address(this)) returns (uint256) {}
            catch {
                IERC20(quote).forceApprove(address(r), 0);
                return (0, 0);
            }
            IERC20(quote).forceApprove(address(r), 0);
        }
        got = _held(token) - before;
        if (got < minOut) revert ShortFill(got, minOut);
        spent = amountIn;
    }

    /// @dev Sells a quote asset for ETH along the pricer's route, with a floor at the pricer's own valuation minus the tolerance. Returns the ETH that arrived, measured from this contract's balance.
    function _sellQuote(address quote, uint256 amount) private returns (uint256 got) {
        (Hop[] memory hops, bool qualifies) = pricer.route(quote);
        if (!qualifies || hops.length == 0) return 0;
        uint256 quotePerEth;
        try pricer.priceEthAmountInQuote(quote, 1 ether) returns (uint256 q) {
            quotePerEth = q;
        } catch {
            return 0;
        }
        if (quotePerEth == 0) return 0;
        // Never offer more than is actually here: a taxed quote's queue can
        // run ahead of the balance by rounding, and the router pulls exactly
        // what it is told.
        uint256 held = _held(quote);
        if (amount > held) amount = held;
        uint256 expectedEth = amount * 1 ether / quotePerEth;
        // A taxed quote loses its tax twice on the way to ETH: once into the
        // router and once into the pool. The floor allows for both, so the
        // tax the pricer measured is not mistaken for a bad fill.
        uint256 tax = pricer.transferTaxBps(quote);
        if (tax != 0) expectedEth = expectedEth * (BPS - tax) / BPS * (BPS - tax) / BPS;
        uint256 minOut = expectedEth * (BPS - TOLERANCE_BPS) / BPS;
        if (minOut == 0) return 0;

        FusingRouter r = activeRouter();
        uint256 before = address(this).balance;
        IERC20(quote).forceApprove(address(r), amount);
        try r.quoteToEth(Currency.wrap(quote), amount, hops, minOut, address(this)) returns (uint256) {}
        catch {
            IERC20(quote).forceApprove(address(r), 0);
            return 0;
        }
        IERC20(quote).forceApprove(address(r), 0);
        got = address(this).balance - before;
        if (got < minOut) revert ShortFill(got, minOut);
    }

    // ---------------------------------------------------------------------
    // Paying out
    // ---------------------------------------------------------------------

    /**
     * @dev The protocol gets paid directly under a capped gas stipend, with
     * the escrow as fallback if the recipient rejects the transfer. The
     * creator's ETH, quote and tokens, whichever the mode produces, are
     * credited to the escrow for the launch's payout plan to divide.
     */
    /// @dev True for a quote the pricer values without any pool route (oracle-priced): it cannot be sold along one.
    function _noRoute(address quote) private view returns (bool) {
        (Hop[] memory hops, bool qualifies) = pricer.route(quote);
        return qualifies && hops.length == 0;
    }

    function _pay(address token, IFusingLaunchFactory.LaunchedToken memory launch, Payout memory out) private {
        if (address(desk) != address(0) && out.quoteProtocol + out.quoteCreator > 0 && _noRoute(launch.pairToken)) {
            // A stock: the desk sells it for ETH through solvers and pays the protocol and this launch's Vault from the proceeds.
            IERC20(launch.pairToken).safeTransfer(address(desk), out.quoteProtocol + out.quoteCreator);
            desk.book(launch.pairToken, token, out.quoteCreator, launch.protocolFeeRecipient, out.quoteProtocol);
            out.quoteProtocol = 0;
            out.quoteCreator = 0;
        }
        if (out.quoteProtocol > 0) IERC20(launch.pairToken).safeTransfer(launch.protocolFeeRecipient, out.quoteProtocol);
        if (out.ethProtocol > 0) {
            (bool ok,) = launch.protocolFeeRecipient.call{value: out.ethProtocol, gas: 50_000}("");
            if (!ok) feeEscrow.credit{value: out.ethProtocol}(launch.protocolFeeRecipient);
        }
        // The creator's share, whichever assets the mode produced, goes to the Vault for its modules.
        if (out.ethCreator > 0) vault.deposit{value: out.ethCreator}(token, address(0), out.ethCreator);
        if (out.quoteCreator > 0) {
            IERC20(launch.pairToken).forceApprove(address(vault), out.quoteCreator);
            vault.deposit(token, launch.pairToken, out.quoteCreator);
        }
        if (out.tokensHanded > 0) {
            IERC20(token).forceApprove(address(vault), out.tokensHanded);
            vault.deposit(token, token, out.tokensHanded);
        }
    }

    /// @dev The protocol's fraction of the total fee, scaled by 1e18: its share of the base fee, taken as a fraction of base plus creator tax. The same arithmetic the V1 locker used, carried at full precision.
    function _protocolShareWad(IFusingLaunchFactory.LaunchedToken memory launch) private pure returns (uint256) {
        uint256 total = uint256(launch.baseFeeBps) + launch.creatorTaxBps;
        if (total == 0) return 0;
        return uint256(launch.baseFeeBps) * launch.protocolFeeShareBps * WAD / (total * BPS);
    }
}
