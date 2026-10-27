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

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";

import {FusingLauncherToken} from "./FusingLauncherToken.sol";
import {FusingFeeHook} from "./FusingFeeHook.sol";
import {FusingTerms} from "./libraries/FusingTerms.sol";
import {FusingTermsCheck} from "./libraries/FusingTermsCheck.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {FusingLaunchLocker} from "./FusingLaunchLocker.sol";
import {FusingPositionMinter} from "./FusingPositionMinter.sol";
import {LaunchDeployment, FusingLaunchDeployer} from "./FusingLaunchDeployer.sol";
import {FusingQuotePricer} from "./FusingQuotePricer.sol";
import {FusingPositionMath} from "./libraries/FusingPositionMath.sol";
import {FusingQuoteAssetProbe} from "./libraries/FusingQuoteAssetProbe.sol";
import {IFusingFeeEscrow, IFusingLaunchFactory} from "./interfaces/ILaunchpadV2.sol";

/// @dev The Fuse Vault as the factory sees it: registration at launch.
interface IFuseVaultForFactory {
    function register(address token, address launcher, address owner_) external;
}

/**
 * @title FusingLaunchFactory
 * @notice Creates a launch token and opens its Uniswap V4 pool in a single
 * transaction. The pool is deliberately plain: its only hook is the fee
 * hook, which does nothing but decide the LP fee of each swap, and the
 * entire supply sits in one permanently locked position that runs from the
 * opening price to the top of the range. Such a position behaves exactly
 * like a constant-product bonding curve backed by a phantom quote reserve,
 * and because the hook never touches balances, any router, aggregator or
 * trading terminal that understands Uniswap V4 can trade it from block one
 * with no allowlist to pass.
 *
 * The pool's LP fee is the full trading fee of the launch: fusi.ng's base
 * fee plus whatever creator tax was chosen. It accrues to the locked
 * position and FusingLaunchLocker collects and splits it.
 */
contract FusingLaunchFactory is Ownable2Step, ReentrancyGuard, IFusingLaunchFactory {
    using StateLibrary for IPoolManager;

    uint256 private constant BASIS_POINTS = 10_000;
    uint256 private constant MAX_BASE_FEE_BPS = 1_000; // 10% of each trade
    uint256 private constant MAX_CREATOR_TAX_CEILING_BPS = 1_000; // 10% ceiling
    uint256 private constant MAX_TOTAL_TRADE_FEE_BPS = 2_000; // 20% all in
    // Uniswap V4 quotes LP fees in pips, one hundredth of a basis point.
    uint24 private constant PIPS_PER_BP = 100;
    uint8 private constant MIN_PAIR_TOKEN_DECIMALS = 6;
    uint256 private constant MIN_LAUNCH_SUPPLY = 1 ether;
    // Pool balance changes in V4 travel as a BalanceDelta packing two int128
    // values, so a launch supply must fit in a signed 128-bit integer.
    uint256 private constant MAX_SUPPLY = uint256(uint128(type(int128).max));
    int24 private constant MAX_TICK_SPACING = 32767;
    // How long the protocol owner's override of a creator fee recipient has
    // to sit in public view before anyone can execute it.

    struct TokenParams {
        string name;
        string symbol;
        string logo;
        string description;
        FusingLauncherToken.Socials socials;
        address creatorFeeRecipient;
        // Extra trade fee the creator layers on top of fusi.ng's base fee,
        // bounded by maxCreatorTaxBps when the launch happens. Goes to the
        // creator in full; the protocol takes no share of it.
        uint16 creatorTaxBps;
        // Optional pin on the economics this launch commits to. Leave zero
        // to skip the check; previewLaunchEconomics returns the value to pass.
        bytes32 expectedEconomics;
        // Salt for the token's CREATE2 deployment, scoped to the initiating
        // account. Call FusingLaunchDeployer.predictTokenAddress to learn
        // the address before sending.
        bytes32 salt;
    }

    /**
     * @notice Economics for a launch quoted in native ETH. `phantomQuote` is
     * a wei figure here; when the quote is an ERC-20 the factory derives it
     * from the quote pricer (or an owner-curated override) so that every
     * launch opens at one and the same market cap.
     */
    struct LaunchConfig {
        uint256 supply;
        uint256 phantomQuote;
        int24 tickSpacing;
        bool enabled;
    }

    /**
     * @notice An owner-curated phantom reserve for a single ERC-20 quote
     * asset, expressed in that asset's decimals. When set, it wins over the
     * pricer.
     */
    struct PairTokenEconomics {
        uint256 phantomQuote;
        uint8 decimals;
    }

    error InvalidLaunchConfigId();
    error LaunchConfigDisabled();
    error InvalidBasisPoints();
    error CreatorTaxTooHigh();
    error CombinedFeeTooHigh();
    error SupplyTooLow();
    error SupplyTooHigh();
    error InvalidTickSpacing();
    error LaunchFeeNotPaid();
    error NotWhitelisted();
    /// @dev Nobody has yet proven that this ERC-20 quote transfers exact amounts.
    error QuoteAssetNotProven(address quoteToken);
    error FeeTransferFailed();
    error ZeroAddress();
    error AlreadySet();
    error OwnershipCannotBeRenounced();
    error InvalidTokenParams();
    error TokenNotFound();
    error NotLaunchForwarder();
    error LaunchDependenciesNotWired();
    error PairTokenValidationFailed();
    error InvalidPhantomQuote();
    error PairTokenEconomicsInvalid();
    error PairTokenDecimalsMismatch(uint8 expected, uint8 actual);
    error PairTokenDecimalsUnavailable();
    error LaunchEconomicsMismatch(bytes32 expected, bytes32 actual);

    event GuardStaged(address indexed launcher, uint64 guardSeconds, uint256 count);

    /// @dev This exact pool key was initialised before the launch got there.
    /// Retry with another salt: a new token address means a new key.
    error PoolAlreadyExists();

    event TokenLaunched(
        address indexed token,
        bytes32 indexed poolId,
        address indexed deployer,
        address pairToken,
        uint256 launchConfigId,
        uint24 poolFee
    );
    /**
     * @notice Describes the locked position a launch was given; fired next
     * to TokenLaunched. `tokenAmount` is how much supply actually entered
     * the pool.
     */
    /**
     * @notice One pool of a launch, emitted per market in market order.
     * Market 0 is also reported by `TokenLaunched` and
     * `LaunchPositionMinted`, exactly as a one-pool launch always was, so
     * readers of those two events keep working; this one is how a reader
     * learns about the other pools.
     */
    event MarketOpened(
        address indexed token,
        bytes32 indexed poolId,
        uint8 marketIndex,
        address pairToken,
        uint256 positionId,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        uint256 tokenAmount,
        uint256 phantomQuote
    );

    event LaunchPositionMinted(
        address indexed token,
        uint256 positionId,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        uint256 tokenAmount,
        uint256 phantomQuote
    );
    event CreatorFeeRecipientUpdated(
        address indexed token, address indexed previousRecipient, address indexed newRecipient
    );
    event LaunchConfigAdded(uint256 indexed id);
    event LaunchConfigUpdated(uint256 indexed id);
    event LaunchFeeUpdated(uint256 launchFee);
    event LaunchEnabledUpdated(bool enabled);
    event WhitelistedLauncherUpdated(address indexed launcher, bool enabled);
    event MaxCreatorTaxUpdated(uint256 bps);
    event BaseFeeUpdated(uint256 bps);
    event ProtocolFeeShareUpdated(uint256 bps);
    event ProtocolFeeRecipientUpdated(address recipient);
    event PositionMinterSet(address minter);
    event LaunchDeployerSet(address deployer);
    event LaunchForwarderSet(address forwarder);
    event PairTokenEconomicsUpdated(address indexed pairToken, uint256 phantomQuote, uint8 decimals);
    event PairTokenEconomicsCleared(address indexed pairToken);

    IPoolManager public immutable poolManager;
    IPositionManager public immutable positionManager;
    FusingLaunchLocker public immutable locker;
    IFusingFeeEscrow public immutable feeEscrow;
    FusingQuotePricer public immutable quotePricer;

    // These cannot be immutable. Both helpers take the factory address in
    // their constructors, so they are deployed after the factory and attached once.
    FusingPositionMinter public positionMinter;
    FusingLaunchDeployer public launchDeployer;

    // -------------------------------------------------------- V2 launch terms

    error FeeHookNotWired();

    event FeeHookSet(address indexed hook);

    /**
     * @notice The protocol's market makers. A listed wallet trading through
     * the fusi.ng router pays no pool fee on any launch (no LP fee, no
     * creator tax, no opening fee, no sniper premium: the hook returns a
     * zero fee) and is spared every token-side rule (the whitelist window
     * and the wallet and transaction caps, which the token checks live).
     * Owner-set, so the list changes for every launch, past and future, in
     * one call. Readable by anyone: this is a disclosed programme.
     */
    mapping(address wallet => bool) public marketMaker;

    event MarketMakersSet(address[] wallets, bool on);

    function setMarketMakers(address[] calldata wallets, bool on) external onlyOwner {
        for (uint256 i = 0; i < wallets.length; i++) {
            if (wallets[i] != address(0)) marketMaker[wallets[i]] = on;
        }
        emit MarketMakersSet(wallets, on);
    }
    event TermsStaged(address indexed launcher, uint256 payees);
    event TermsApplied(address indexed token, address indexed distributor);

    /// @notice The dynamic-fee hook attached to every V2 pool. Wired once at deployment.
    FusingFeeHook public feeHook;
    /// @dev What a launcher has staged for their upcoming launch; wiped once that launch goes through.
    mapping(address launcher => FusingTerms.LaunchTerms) private _termsOf;
    /// @notice The payout mode for a launch's creator fees on the token side, fixed at launch time.
    /// @notice The Fuse Vault every launch's fee configuration lives in. Set once.
    IFuseVaultForFactory public vault;

    event VaultSet(address vault);

    function setVault(IFuseVaultForFactory vault_) external onlyOwner {
        if (address(vault_) == address(0)) revert ZeroAddress();
        if (address(vault) != address(0)) revert VaultAlreadySet();
        vault = vault_;
        emit VaultSet(address(vault_));
    }

    error VaultAlreadySet();
    error NotVault();

    /// @notice The Vault reports a creator-side ownership hand-off so this record follows it.
    function syncCreatorFeeRecipient(address token, address to) external {
        if (msg.sender != address(vault)) revert NotVault();
        _setCreatorFeeRecipient(token, _launchedTokens[token], to);
    }

    /**
     * @notice The figures behind the anti-sniper toggle. The protocol sets
     * them; a creator only decides whether the window is on, and these say
     * how steep and how long. Default: an extra 80% on every swap in the
     * launch block, for exactly one block.
     */
    FusingTerms.Presets public presets = FusingTerms.Presets({sniperPremium: 800_000, sniperBlocks: 1});

    /// @notice Limits on what a creator may choose: wallet and tx caps between 0.1% and 3% of
    /// supply, an opening fee of at most 20%, and neither running longer than 20 minutes.
    uint16 public constant MIN_LIMIT_BPS = FusingTermsCheck.MIN_LIMIT_BPS;
    uint16 public constant MAX_LIMIT_BPS = FusingTermsCheck.MAX_LIMIT_BPS;
    uint32 public constant MAX_LIMITS_SECONDS = FusingTermsCheck.MAX_LIMITS_SECONDS;
    uint24 public constant MAX_START_FEE = FusingTermsCheck.MAX_START_FEE;
    uint32 public constant MAX_DECAY_SECONDS = FusingTermsCheck.MAX_DECAY_SECONDS;
    /// @notice Up to MAX_WHITELIST whitelisted wallets skip both the caps and the launch-block premium.
    uint256 public constant MAX_WHITELIST = FusingTermsCheck.MAX_WHITELIST;
    /**
     * @notice The whitelist window a staged whitelist applies by default: a
     * minute, about five blocks.
     *
     * A constant on purpose. It is only the DEFAULT, not a ceiling: a launcher
     * who wants a different window calls `setGuardList(seconds, list)` after
     * staging, which overrides this for their next launch and is bounded by the
     * token's own `MAX_GUARD_SECONDS` of three minutes. So choosing between,
     * say, 30, 60, 120 and 180 seconds is a matter of what the interface passes
     * to `setGuardList`, and needs nothing from this contract.
     */
    uint64 public constant WHITELIST_GUARD_SECONDS = 60;
    /// @notice Dev buy allowance: 6% of supply with no strings, 20% if it goes into a lock of seven days or more.
    uint16 public constant DEV_BUY_FREE_BPS = 600;
    uint16 public constant DEV_BUY_LOCKED_BPS = 2_000;
    uint32 public constant MIN_DEV_LOCK_SECONDS = FusingTermsCheck.MIN_DEV_LOCK_SECONDS;
    uint32 public constant MAX_DEV_LOCK_SECONDS = FusingTermsCheck.MAX_DEV_LOCK_SECONDS;

    /// @notice The FusingTokenLock a locked dev buy is parked in. Wired once at deployment and never subject to the caps.
    address public tokenLock;

    event TokenLockSet(address indexed tokenLock);

    /// @notice Points future launches at a new token lock. Locks already created stay where they are.
    function setTokenLock(address lock) external onlyOwner {
        if (lock == address(0)) revert ZeroAddress();
        tokenLock = lock;
        emit TokenLockSet(lock);
    }

    /// @notice The wallets `launcher` staged to bypass the caps and the launch-block premium.
    function whitelistOf(address launcher) external view returns (address[] memory) {
        return _termsOf[launcher].whitelist;
    }

    event PresetsSet(FusingTerms.Presets presets);

    function setPresets(FusingTerms.Presets calldata p) external onlyOwner {
        if (p.sniperBlocks > 10 || p.sniperPremium > 900_000) revert FusingTermsCheck.TermsInvalid();
        presets = p;
        emit PresetsSet(p);
    }

    /**
     * @notice Records the V2 terms for the caller's next launch: token
     * limits, fee schedule, anti-sniper window and payout plan. The launch
     * consumes them. Stage nothing, or an all-zero struct, and you get a V1
     * launch.
     * @dev Anyone may call this; it only shapes launches the caller makes.
     * It lives outside the launch call so that call's signature and stack
     * stay as they are, the same approach the launch guard takes.
     */
    function stageTerms(FusingTerms.LaunchTerms calldata terms) external {
        _stageTerms(msg.sender, terms);
    }

    /// @notice Lets the launch-and-buy router stage terms for the account it is launching for.
    function stageTermsFor(address launcher, FusingTerms.LaunchTerms calldata terms) external {
        if (msg.sender != launchForwarder) revert NotLaunchForwarder();
        _stageTerms(launcher, terms);
    }

    /// @notice Whatever `launcher` has staged for their upcoming launch.
    function termsOf(address launcher) external view returns (FusingTerms.LaunchTerms memory) {
        return _termsOf[launcher];
    }

    /// @notice The pool plumbing and routers that the token limits must never apply to.
    function limitExemptions() external view returns (address[] memory list) {
        list = new address[](8);
        list[7] = tokenLock;
        list[0] = address(poolManager);
        list[1] = address(positionMinter);
        list[2] = address(locker);
        list[3] = launchForwarder;
        list[4] = address(feeEscrow);
        // On its way into the pool the supply passes through Uniswap's
        // PositionManager and Permit2, each of which holds it briefly during
        // the launch transaction.
        list[5] = address(positionManager);
        list[6] = address(positionMinter.permit2());
    }

    /**
     * @notice Sets the dynamic-fee hook future pools open with. A hook is
     * baked into a pool's key and can never be swapped, so a new one only
     * reaches launches from this point on; every live pool keeps the hook
     * it started with. The hook has to have been deployed for this factory.
     */
    function setFeeHook(FusingFeeHook hook) external onlyOwner {
        if (address(hook) == address(0)) revert ZeroAddress();
        if (hook.factory() != address(this)) revert FeeHookNotWired();
        feeHook = hook;
        emit FeeHookSet(address(hook));
    }

    /// @notice Ceiling on payees per plan: five wallets or handles plus the two vaults. Same figure the escrow uses.

    /// @notice A launch opens between one and this many pools, one per quote asset.
    uint256 public constant MAX_MARKETS = 6;

    error InvalidMarketCount();
    error DuplicatePairToken(address pairToken);

    /**
     * @notice The share of supply market `index` of an `n`-market launch
     * receives, in bps: every pool takes 1/n, with the rounding remainder
     * on market 0 so the shares sum to exactly 100%. Each pool also carries
     * a whole one-pool reserve (see `_phantoms`), so the pools are equal in
     * depth, open at one price, and no one of them is "the" market: an
     * aggregator rotates buys across all of them as each becomes the
     * cheapest. Market 0 is only the one the launch record describes.
     */
    function marketShareBps(uint256 n, uint256 index) private pure returns (uint256) {
        if (n == 1) return BASIS_POINTS;
        uint256 each = BASIS_POINTS / n;
        return index == 0 ? BASIS_POINTS - (n - 1) * each : each;
    }

    /**
     * @notice One pool of a launch. Market 0 is the primary market and is
     * also what `getLaunchedToken` and `poolKeyFor(token)` describe, so
     * every reader written for one-pool launches keeps working unchanged.
     */
    struct Market {
        address pairToken;
        uint256 phantomQuote;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint256 positionId;
    }

    mapping(address token => Market[] markets) private _markets;

    /// @notice Every market of `token`, in the order the launcher listed the quote assets.
    function marketsOf(address token) external view returns (Market[] memory) {
        return _markets[token];
    }

    /// @notice The pool key of market `index` of `token`.
    function poolKeyFor(address token, uint256 index) public view returns (PoolKey memory) {
        LaunchedToken storage launch = _launchedTokens[token];
        if (!launch.exists) revert TokenNotFound();
        Market storage m = _markets[token][index];
        return _poolKey(token, m.pairToken, launch.poolFee, launch.tickSpacing, hookOf[token]);
    }

    /// @notice Every pool key of `token`, in market order.
    function poolKeysFor(address token) external view returns (PoolKey[] memory keys) {
        uint256 n = _markets[token].length;
        keys = new PoolKey[](n);
        for (uint256 i = 0; i < n; i++) {
            keys[i] = poolKeyFor(token, i);
        }
    }


    function _stageTerms(address launcher, FusingTerms.LaunchTerms calldata terms) private {
        FusingTermsCheck.validate(terms);
        // The field-by-field copy lives in the library too, for size.
        FusingTermsCheck.store(_termsOf[launcher], terms);
        // A whitelist is a launch window: for WHITELIST_GUARD_SECONDS after
        // the launch only the list, the creator and the launch plumbing can
        // receive the token (the token's own guard), and the list is spared
        // the caps for the first blocks. Staged here so the creator signs one
        // transaction, not two; a re-stage without a whitelist clears it.
        if (terms.whitelist.length > 0) {
            guardSecondsOf[launcher] = WHITELIST_GUARD_SECONDS;
            delete _guardListOf[launcher];
            address[] storage g = _guardListOf[launcher];
            g.push(address(poolManager));
            g.push(address(positionManager));
            g.push(address(positionMinter));
            g.push(address(locker));
            g.push(launchForwarder);
            if (tokenLock != address(0)) g.push(tokenLock);
            g.push(launcher);
            for (uint256 i = 0; i < terms.whitelist.length; i++) {
                if (terms.whitelist[i] != address(0)) g.push(terms.whitelist[i]);
            }
        } else if (guardSecondsOf[launcher] == WHITELIST_GUARD_SECONDS) {
            // Equality, not "is it non-zero": it means "still exactly the window
            // staging set, so nobody has overridden it". A launcher who called
            // `setGuardList` with their own figure owns that guard, and clearing
            // it is theirs to do, not ours.
            guardSecondsOf[launcher] = 0;
            delete _guardListOf[launcher];
        }
        emit TermsStaged(launcher, terms.allocations.length);
    }

    /**
     * @dev Stores the pool's fee terms on the hook ahead of pool
     * initialisation. The resting fee is the V1 fee; the premiums come from
     * what the launcher staged. Invoked from the launch path.
     */
    /// @dev The CREATE2 deployment of the launch token, kept out of the launch function to spare its stack: the five strings alone are ten stack slots.
    function _deployLaunchToken(TokenParams calldata params, address originalDeployer, uint256 supply)
        private
        returns (address)
    {
        // Assembled in memory one field at a time on purpose: encoding five
        // calldata strings in one expression keeps ten stack slots live at
        // once, which is what tips the launch path over the Yul stack limit
        // when the optimiser inlines this. A memory struct encodes from one
        // pointer.
        LaunchDeployment memory d;
        d.originalDeployer = originalDeployer;
        d.supplyRecipient = address(positionMinter);
        d.supply = supply;
        d.salt = params.salt;
        d.name = params.name;
        d.symbol = params.symbol;
        d.logo = params.logo;
        d.description = params.description;
        d.socials = params.socials;
        return launchDeployer.deployToken(d);
    }

    /**
     * @dev The key a launch opens under, with the hook recorded for the
     * token. The hook goes on only when the launcher's staged terms need it:
     * an opening fee above the resting fee, or the sniper tax. Kept out of
     * the launch function to spare its stack.
     */
    function _launchKey(address token, address pairToken, uint24 poolFee, int24 tickSpacing, address launcher)
        private
        returns (PoolKey memory key)
    {
        /*
         * The hook goes on only where the launcher's terms need it: an
         * opening fee above the resting fee, or the sniper tax. A beginner
         * launch asks for neither, so it opens a hookless pool carrying a
         * plain static fee.
         *
         * That is what makes a beginner launch tradable everywhere from
         * block one. A hook that sets the fee per swap needs the pool's
         * dynamic-fee flag, and Uniswap leaves a dynamic-fee hook out of its
         * routing allowlist unless it is submitted and approved; out of that
         * allowlist means no route in MetaMask, 1inch, Paraswap or the
         * Uniswap app. The hook was on every pool for a while so the
         * market-maker exemption would reach all of them. Being quotable in
         * every wallet is worth more than that exemption on a plain launch.
         */
        FusingTerms.LaunchTerms storage terms = _termsOf[launcher];
        bool needsHook = terms.antiSniper || terms.startFee > poolFee;
        address hook = needsHook ? address(feeHook) : address(0);
        hookOf[token] = hook;
        key = _poolKey(token, pairToken, poolFee, tickSpacing, hook);
        // A pool someone initialised ahead of the launch would open at a price they chose: refused (see the note in the launch path).
        (uint160 existingPrice,,,) = poolManager.getSlot0(key.toId());
        if (existingPrice != 0) revert PoolAlreadyExists();
    }

    function _applyHookTerms(PoolId poolId, uint24 restingFee, address launcher) private {
        FusingTerms.LaunchTerms storage t = _termsOf[launcher];
        FusingTerms.Presets memory p = presets;
        // The creator gives the opening fee; the hook wants the premium above
        // the resting fee, which is what decays. An opening fee no higher
        // than the resting fee means there is no schedule.
        uint24 premium = t.startFee > restingFee ? t.startFee - restingFee : 0;
        feeHook.setTerms(
            poolId,
            FusingFeeHook.Terms({
                restingFee: restingFee,
                startPremium: premium,
                decaySeconds: premium > 0 ? t.decaySeconds : 0,
                sniperPremium: t.antiSniper ? p.sniperPremium : 0,
                sniperBlocks: t.antiSniper ? p.sniperBlocks : 0,
                // On input: the delay before the schedule starts, which is a whitelisted launch's window.
                launchedAt: guardSecondsOf[launcher],
                launchBlock: 0,
                // When the forwarder launches, the creator's dev buy rides in the same
                // transaction, and that single swap is not a snipe and must not be charged as one.
                devBuyExempt: msg.sender == launchForwarder,
                set: false
            })
        );
        if (t.whitelist.length > 0) feeHook.setWhitelist(poolId, t.whitelist);
    }

    /**
     * @dev Stores the launch's payout plan on the escrow, substituting the
     * distributor the deployer created wherever a HOLDERS payee appears, and
     * then wipes the staged terms so nothing carries over to the launcher's
     * next launch.
     */
    function _applyPlan(address token, address launcher, address owner_) private {
        address distributor = launchDeployer.distributorOf(token);
        // The Vault reads the staged terms itself and keeps the configuration from here on.
        vault.register(token, launcher, owner_);
        delete _termsOf[launcher];
        // The whitelist window staged with these terms goes with them - but only
        // if it is still the window staging set. A launcher who overrode it with
        // `setGuardList` keeps their own guard until they clear it themselves,
        // which is what test_fork_whitelistWindow_threeMinutes pins down.
        if (guardSecondsOf[launcher] == WHITELIST_GUARD_SECONDS) {
            guardSecondsOf[launcher] = 0;
            delete _guardListOf[launcher];
        }
        emit TermsApplied(token, distributor);
    }
    address public launchForwarder;

    // The fee terms a new launch copies at creation. Updating them leaves
    // live pools alone, since the LP fee is baked into each pool's key.
    /**
     * The fee a launch quoted in a tokenised stock pays, and where its
     * protocol share goes. A stock launch costs more than an ordinary one
     * because part of that fee is turned into permanent liquidity in the
     * stock's own ETH pool, which is what lets an ETH wallet reach the stock
     * pool at all. Ordinary launches are untouched and still pay baseFeeBps.
     *
     * Zero in `stockBaseFeeBps` turns the whole arrangement off: stock
     * launches then behave exactly like any other.
     */
    uint256 public stockBaseFeeBps;
    uint256 public stockProtocolFeeShareBps;
    address public stockFeeRecipient;

    uint256 public baseFeeBps = 110; // 1.1%: fusi.ng's signature fee
    uint256 public protocolFeeShareBps = 3_000; // the V1 default; the V2 deploy sets 4_000, protocol 40% and creator 60%
    address public protocolFeeRecipient;
    uint256 public maxCreatorTaxBps = 1_000; // 10% cap

    uint256 public launchFee;
    bool public launchEnabled;

    mapping(address launcher => bool enabled) public whitelistedLaunchers;

    /**
     * The anti-snipe guard a launcher's next launch will carry.
     *
     * It is staged here and picked up by FusingLaunchDeployer at deploy time
     * instead of travelling through the launch call, because putting it in
     * TokenParams pushed the launch path over the compiler's stack limit.
     * The launch path is therefore untouched, and a launch without a guard
     * costs the same gas it always has.
     *
     * Keyed by launcher, so nobody can set anybody else's.
     */
    mapping(address launcher => uint64 seconds_) public guardSecondsOf;
    mapping(address launcher => address[] allowed) private _guardListOf;

    mapping(address pairToken => PairTokenEconomics economics) public pairTokenEconomics;
    mapping(address token => LaunchedToken launched) private _launchedTokens;
    LaunchConfig[] private _launchConfigs;

    constructor(
        address initialOwner,
        IPoolManager poolManager_,
        IPositionManager positionManager_,
        FusingLaunchLocker locker_,
        IFusingFeeEscrow feeEscrow_,
        FusingQuotePricer quotePricer_,
        address protocolFeeRecipient_,
        uint256 initialLaunchFee
    ) Ownable(initialOwner) {
        if (address(poolManager_) == address(0) || address(positionManager_) == address(0)) revert ZeroAddress();
        if (address(locker_) == address(0) || address(feeEscrow_) == address(0)) revert ZeroAddress();
        if (address(quotePricer_) == address(0) || protocolFeeRecipient_ == address(0)) revert ZeroAddress();
        if (address(positionManager_.poolManager()) != address(poolManager_)) revert LaunchDependenciesNotWired();

        poolManager = poolManager_;
        positionManager = positionManager_;
        locker = locker_;
        feeEscrow = feeEscrow_;
        quotePricer = quotePricer_;
        protocolFeeRecipient = protocolFeeRecipient_;
        launchFee = initialLaunchFee;
    }

    // ---------------------------------------------------------------------
    // Read-only views
    // ---------------------------------------------------------------------

    function launchConfigCount() external view returns (uint256) {
        return _launchConfigs.length;
    }

    function getLaunchConfig(uint256 id) external view returns (LaunchConfig memory) {
        if (id >= _launchConfigs.length) revert InvalidLaunchConfigId();
        return _launchConfigs[id];
    }

    /// @notice Who owns `token`'s fees right now; the token reads this to decide who may edit its details.
    function feeOwnerOf(address token) external view returns (address) {
        return _launchedTokens[token].creatorFeeRecipient;
    }

    function getLaunchedToken(address token) external view override returns (LaunchedToken memory) {
        return _launchedTokens[token];
    }

    /**
     * @notice Builds the pool key for a launched token.
     */
    function poolKeyFor(address token) public view returns (PoolKey memory) {
        LaunchedToken storage launch = _launchedTokens[token];
        if (!launch.exists) revert TokenNotFound();
        // A pool keeps the hook it launched with forever, since the hook is
        // in the key; whatever hook the factory holds now only matters for
        // the next launch. Zero means the pool opened without one.
        return _poolKey(token, launch.pairToken, launch.poolFee, launch.tickSpacing, hookOf[token]);
    }

    /// @notice The hook a launch's pool was created with. Set once at launch and never rewritten.
    mapping(address token => address hook) public hookOf;

    function poolIdFor(address token) external view returns (PoolId) {
        return poolKeyFor(token).toId();
    }

    /**
     * @notice Says whether `launcher` can launch at this moment: yes for
     * everyone while public launching is on, and yes for whitelisted
     * addresses even when it is off.
     */
    function canLaunch(address launcher) public view returns (bool) {
        return launchEnabled || whitelistedLaunchers[launcher];
    }

    /**
     * @notice The LP fee a launch carrying `creatorTaxBps` would get today,
     * in Uniswap V4's pips (hundredths of a basis point).
     */
    /**
     * @notice The terms a launch quoted in `pairToken` is recorded with: the
     * ordinary ones, or the stock ones when the launch is quoted in a token
     * rather than in ETH and stock terms are configured.
     */
    function _termsFor(address pairToken) internal view returns (uint256 feeBps, uint256 shareBps, address recipient) {
        if (pairToken != address(0) && stockBaseFeeBps > 0) {
            return (stockBaseFeeBps, stockProtocolFeeShareBps, stockFeeRecipient);
        }
        return (baseFeeBps, protocolFeeShareBps, protocolFeeRecipient);
    }

    function poolFeeFor(uint16 creatorTaxBps) public view returns (uint24) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint24((baseFeeBps + creatorTaxBps) * PIPS_PER_BP);
    }

    // ---------------------------------------------------------------------
    // Owner configuration
    // ---------------------------------------------------------------------

    function addLaunchConfig(LaunchConfig calldata config) external onlyOwner returns (uint256 id) {
        _validateLaunchConfig(config);
        id = _launchConfigs.length;
        _launchConfigs.push(config);
        emit LaunchConfigAdded(id);
    }

    /**
     * @notice Overwrites a launch configuration in place. Tokens that have
     * already launched keep the pool parameters they snapshotted.
     */
    function updateLaunchConfig(uint256 id, LaunchConfig calldata config) external onlyOwner {
        if (id >= _launchConfigs.length) revert InvalidLaunchConfigId();
        _validateLaunchConfig(config);
        _launchConfigs[id] = config;
        emit LaunchConfigUpdated(id);
    }

    function setLaunchFee(uint256 newLaunchFee) external onlyOwner {
        launchFee = newLaunchFee;
        emit LaunchFeeUpdated(newLaunchFee);
    }

    function setLaunchEnabled(bool enabled) external onlyOwner {
        launchEnabled = enabled;
        emit LaunchEnabledUpdated(enabled);
    }


    /**
     * @notice Records the anti-snipe guard for the caller's next launch.
     *
     * During the first `guardSeconds` after that launch, the token can only
     * be received by addresses in `list`. Zero seconds means an open launch,
     * which is the default and what every launch was before this feature.
     * The token itself caps the window at MAX_GUARD_SECONDS (three minutes) and
     * never lets it grow once set.
     *
     * @dev Anyone may call this; it only shapes launches the caller makes.
     */
    function setGuardList(uint64 guardSeconds, address[] calldata list) external {
        guardSecondsOf[msg.sender] = guardSeconds;
        delete _guardListOf[msg.sender];
        for (uint256 i = 0; i < list.length; i++) {
            if (list[i] != address(0)) _guardListOf[msg.sender].push(list[i]);
        }
        emit GuardStaged(msg.sender, guardSeconds, list.length);
    }

    /// @notice The addresses `launcher` staged for their guard window.
    function guardListOf(address launcher) external view returns (address[] memory) {
        return _guardListOf[launcher];
    }

    function setWhitelistedLauncher(address launcher, bool enabled) external onlyOwner {
        if (launcher == address(0)) revert ZeroAddress();
        whitelistedLaunchers[launcher] = enabled;
        emit WhitelistedLauncherUpdated(launcher, enabled);
    }

    /**
     * @notice Fixes the phantom reserve for launches quoted in a given
     * asset, in that asset's own decimals, taking precedence over the
     * pricer. Launches already made keep their figures.
     * @param expectedDecimals The decimals the caller sized the figure for.
     * Checked against what the asset itself reports, so a figure meant for
     * 18 decimals can never be applied to a 6-decimal asset.
     */
    function setPairTokenEconomics(address pairToken, uint256 phantomQuote, uint8 expectedDecimals)
        external
        onlyOwner
    {
        if (pairToken == address(0) || phantomQuote == 0) revert PairTokenEconomicsInvalid();
        // Fees are whole basis points of the quote amount; with fewer than
        // six decimals a small trade's fee would round down to nothing.
        if (expectedDecimals < MIN_PAIR_TOKEN_DECIMALS) revert PairTokenEconomicsInvalid();
        _requireDecimals(pairToken, expectedDecimals, false);
        pairTokenEconomics[pairToken] = PairTokenEconomics({phantomQuote: phantomQuote, decimals: expectedDecimals});
        emit PairTokenEconomicsUpdated(pairToken, phantomQuote, expectedDecimals);
    }

    function clearPairTokenEconomics(address pairToken) external onlyOwner {
        delete pairTokenEconomics[pairToken];
        emit PairTokenEconomicsCleared(pairToken);
    }

    function setMaxCreatorTaxBps(uint256 bps) external onlyOwner {
        if (bps > MAX_CREATOR_TAX_CEILING_BPS) revert InvalidBasisPoints();
        maxCreatorTaxBps = bps;
        emit MaxCreatorTaxUpdated(bps);
    }

    /**
     * @notice Updates fusi.ng's base trading fee for launches made from
     * here on. Pools that already exist keep the fee baked into their key.
     */
    /**
     * @notice Sets the terms for stock-quoted launches: the fee they pay, the
     * protocol's share of it, and the contract that share is paid to. Passing
     * a zero fee turns the arrangement off and returns them to the ordinary
     * terms. Only launches made after this call are affected: every launch
     * keeps the terms it was made under.
     */
    function setStockTerms(uint256 bps, uint256 shareBps, address recipient) external onlyOwner {
        if (bps > MAX_BASE_FEE_BPS || shareBps > BASIS_POINTS) revert InvalidBasisPoints();
        if (bps > 0 && recipient == address(0)) revert ZeroAddress();
        stockBaseFeeBps = bps;
        stockProtocolFeeShareBps = shareBps;
        stockFeeRecipient = recipient;
    }

    function setBaseFeeBps(uint256 bps) external onlyOwner {
        if (bps > MAX_BASE_FEE_BPS) revert InvalidBasisPoints();
        baseFeeBps = bps;
        emit BaseFeeUpdated(bps);
    }

    /**
     * @notice Updates the protocol's cut of the base fee for launches made
     * from here on. The creator receives the remainder of the base fee plus
     * the entire creator tax.
     */
    function setProtocolFeeShareBps(uint256 bps) external onlyOwner {
        if (bps > BASIS_POINTS) revert InvalidBasisPoints();
        protocolFeeShareBps = bps;
        emit ProtocolFeeShareUpdated(bps);
    }

    /**
     * @notice Sets the address that receives the protocol's fee share and
     * the launch fee, for launches made from here on.
     */
    function setProtocolFeeRecipient(address recipient) external onlyOwner {
        if (recipient == address(0)) revert ZeroAddress();
        protocolFeeRecipient = recipient;
        emit ProtocolFeeRecipientUpdated(recipient);
    }

    /**
     * @notice Swaps in the module that plans and mints launch positions.
     * Launches from here on go through the new one; positions already
     * minted sit in the locker and are unaffected. Must have been deployed
     * for this factory.
     */
    function setPositionMinter(FusingPositionMinter minter) external onlyOwner {
        if (address(minter) == address(0)) revert ZeroAddress();
        if (minter.factory() != address(this)) revert ModuleNotWired();
        positionMinter = minter;
        emit PositionMinterSet(address(minter));
    }

    /**
     * @notice Swaps in the module that carries the token bytecode and
     * deploys each launch token (CREATE2, limits, distributor). This is the
     * path for shipping a new token implementation without replacing the
     * factory: launches from here on use the new deployer and existing
     * tokens are untouched. Predicted vanity addresses depend on which
     * deployer is current, so the launch interface mines against that one.
     * Must have been deployed for this factory.
     */
    function setLaunchDeployer(FusingLaunchDeployer deployer) external onlyOwner {
        if (address(deployer) == address(0)) revert ZeroAddress();
        if (deployer.factory() != address(this)) revert ModuleNotWired();
        launchDeployer = deployer;
        emit LaunchDeployerSet(address(deployer));
    }

    /// @dev The module being wired points at some other factory.
    error ModuleNotWired();

    /**
     * @notice Names the router permitted to launch on another account's
     * behalf (the atomic launch-and-buy flow). Can be rotated when the
     * router is upgraded.
     */
    function setLaunchForwarder(address forwarder) external onlyOwner {
        if (forwarder == address(0)) revert ZeroAddress();
        launchForwarder = forwarder;
        emit LaunchForwarderSet(forwarder);
    }

    /**
     * @notice Always reverts. Ownership can only move to a new owner
     * through the two-step transfer, never be given up.
     */
    function renounceOwnership() public pure override {
        revert OwnershipCannotBeRenounced();
    }

    // ---------------------------------------------------------------------
    // Launching
    // ---------------------------------------------------------------------

    /**
     * @notice The economics digest that launching `launchConfigId` against
     * `pairToken` would commit to right now; pass it as
     * TokenParams.expectedEconomics.
     */
    /// @notice The economics digest and per-market opening reserves a multi-market launch would open with now.
    function previewLaunchEconomics(uint256 launchConfigId, address[] calldata pairTokens)
        external
        view
        returns (bytes32 digest, uint256[] memory phantoms)
    {
        if (launchConfigId >= _launchConfigs.length) revert InvalidLaunchConfigId();
        LaunchConfig memory config = _launchConfigs[launchConfigId];
        // The preview allows a taxed quote unconditionally, so an interface
        // can show what a launch WOULD open with before the creator has
        // decided whether to accept the tax. The launch path itself still
        // requires the flag.
        phantoms = _phantoms(config, pairTokens, true);
        digest = _economicsDigest(config, phantoms);
    }

    /**
     * @notice The phantom reserve a launch quoted in `pairToken` would open
     * with at this moment, in that asset's own units.
     */
    function previewQuoteEconomics(uint256 launchConfigId, address pairToken)
        external
        view
        returns (uint256 phantomQuote)
    {
        if (launchConfigId >= _launchConfigs.length) revert InvalidLaunchConfigId();
        return _quoteEconomics(_launchConfigs[launchConfigId], pairToken);
    }

    /**
     * @notice Creates a launch token and opens one pool per quote asset in
     * `pairTokens` (one to MAX_MARKETS, no duplicates, address zero for
     * ETH). The supply is split equally across the pools and each pool
     * carries a whole one-pool reserve, so all pools open at one price and
     * the launch opens at n times the one-pool cap. Market 0 is the one
     * the launch record describes: the dev buy lands there and the fee
     * converter settles it.
     */
    function launchToken(TokenParams calldata params, uint256 launchConfigId, address[] calldata pairTokens)
        external
        payable
        nonReentrant
        returns (address token, PoolId poolId)
    {
        return _launchToken(params, launchConfigId, pairTokens, msg.sender);
    }

    /**
     * @notice The launch entry point for the trusted launch-and-buy router,
     * launching for the user who initiated the call. Only the configured
     * `launchForwarder` may pass `originalDeployer`, which is how the real
     * caller is recorded without resorting to `tx.origin`.
     */
    function launchTokenFor(
        TokenParams calldata params,
        uint256 launchConfigId,
        address[] calldata pairTokens,
        address originalDeployer
    ) external payable nonReentrant returns (address token, PoolId poolId) {
        if (msg.sender != launchForwarder) revert NotLaunchForwarder();
        return _launchToken(params, launchConfigId, pairTokens, originalDeployer);
    }

    function _launchToken(
        TokenParams calldata params,
        uint256 launchConfigId,
        address[] memory pairTokens,
        address originalDeployer
    ) private returns (address token, PoolId poolId) {
        _requireLaunchDependenciesWired();
        if (!canLaunch(originalDeployer)) revert NotWhitelisted();
        if (msg.value != launchFee) revert LaunchFeeNotPaid();
        if (launchConfigId >= _launchConfigs.length) revert InvalidLaunchConfigId();
        if (bytes(params.name).length == 0 || bytes(params.symbol).length == 0) revert InvalidTokenParams();
        if (params.creatorTaxBps > maxCreatorTaxBps) revert CreatorTaxTooHigh();

        LaunchConfig memory config = _launchConfigs[launchConfigId];
        if (!config.enabled) revert LaunchConfigDisabled();

        // One opening reserve per market, so every pool opens at one and the
        // same price. The pricer establishes that each asset has a market;
        // the exact-transfer proof (see `_phantoms`) establishes that it
        // moves what it says. Read straight from storage rather than
        // threaded through a local: the launch path sits close to the Yul
        // optimiser's stack limit and one more local here costs more than
        // the lookup does.
        uint256[] memory phantoms = _phantoms(config, pairTokens, _termsOf[originalDeployer].allowTaxedQuote);
        // In its own frame: the launch path sits at the Yul optimiser's
        // stack limit and the digest compare needs slots of its own.
        _requireEconomics(params.expectedEconomics, config, phantoms);

        // Deploy the token before anything else, since the pool keys'
        // currency ordering depends on its address. The entire supply is
        // minted to the position minter.
        token = _deployLaunchToken(params, originalDeployer, config.supply);

        // Open every pool, mint every position, lock them all. Market 0 comes
        // back so the launch record below can describe it the way a one-pool
        // launch always has.
        // The terms this launch is made under, decided once from its primary
        // quote before a single pool exists: a stock launch carries a
        // different fee and sends the protocol's share somewhere that turns
        // part of it into liquidity. Resolved here so the pools, the pool id
        // and the record all carry the same number.
        (uint256 feeBps, uint256 shareBps, address feeRecipient) = _termsFor(pairTokens[0]);
        if (feeBps + params.creatorTaxBps > MAX_TOTAL_TRADE_FEE_BPS) revert CombinedFeeTooHigh();
        uint24 launchPoolFee = uint24((feeBps + params.creatorTaxBps) * PIPS_PER_BP);
        (Market memory m0, uint256 tokenAmount0) =
            _openMarkets(token, config, pairTokens, phantoms, originalDeployer, launchPoolFee);
        poolId = _poolKey(token, m0.pairToken, launchPoolFee, config.tickSpacing, hookOf[token]).toId();

        _launchedTokens[token] = LaunchedToken({
            token: token,
            deployer: originalDeployer,
            creatorFeeRecipient: params.creatorFeeRecipient == address(0) ? originalDeployer : params.creatorFeeRecipient,
            pairToken: m0.pairToken,
            phantomQuote: m0.phantomQuote,
            poolFee: launchPoolFee,
            tickSpacing: config.tickSpacing,
            tickLower: m0.tickLower,
            tickUpper: m0.tickUpper,
            liquidity: m0.liquidity,
            positionId: m0.positionId,
            baseFeeBps: uint16(feeBps),
            creatorTaxBps: params.creatorTaxBps,
            protocolFeeShareBps: uint16(shareBps),
            protocolFeeRecipient: feeRecipient,
            launchedAt: uint64(block.timestamp),
            exists: true
        });
        // The Vault registers the launch last, so a module reading the launch record sees it complete.
        _applyPlan(token, originalDeployer, params.creatorFeeRecipient == address(0) ? originalDeployer : params.creatorFeeRecipient);

        // Done last, with the launch already recorded in full: this sends
        // ETH to the protocol recipient, and that recipient could be a
        // contract that re-enters.
        _payLaunchFee();

        emit TokenLaunched(
            token, PoolId.unwrap(poolId), originalDeployer, m0.pairToken, launchConfigId, launchPoolFee
        );
        emit LaunchPositionMinted(token, m0.positionId, m0.tickLower, m0.tickUpper, m0.liquidity, tokenAmount0, m0.phantomQuote);
    }

    /**
     * @dev Validates the quote list and prices each asset: one to
     * MAX_MARKETS entries, no duplicates, every ERC-20 proven to transfer
     * exact amounts. Returns each market's opening reserve, scaled to the
     * market's share of the supply.
     */
    function _phantoms(LaunchConfig memory config, address[] memory pairTokens, bool allowTaxedQuote)
        private
        view
        returns (uint256[] memory phantoms)
    {
        uint256 n = pairTokens.length;
        if (n == 0 || n > MAX_MARKETS) revert InvalidMarketCount();
        phantoms = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            address pairToken = pairTokens[i];
            for (uint256 j = 0; j < i; j++) {
                if (pairTokens[j] == pairToken) revert DuplicatePairToken(pairToken);
            }
            // Priced first, so an asset with no market says so. The pricer
            // cannot establish that an asset transfers exact amounts: the
            // depth it reads is on the side nearer ETH and it never exercises
            // the candidate's transfer code. That proof is a separate one-time
            // permissionless call; until it exists, launching is refused,
            // because a quote that delivers less than sent breaks every buy
            // and every fee collection, permanently.
            // The launch carries n one-pool reserves, one per pool, against
            // 1/n of the supply each. Each pool is then exactly as deep in
            // value as a one-pool launch, and the launch opens at n times the
            // one-pool cap (two pools open at twice it, six at six times).
            // The reserve is scaled by the pool's exact share, so market 0's
            // rounding remainder does not put it off-price: every pool opens
            // at one and the same price.
            phantoms[i] = _quoteEconomics(config, pairToken) * n * marketShareBps(n, i) / BASIS_POINTS;
            if (pairToken != address(0) && !quotePricer.exactTransferProven(pairToken)) {
                // A taxed asset is allowed, but only where the creator asked
                // for it and only where somebody has actually measured the
                // tax. An unmeasured asset is still refused: the failure mode
                // is a launch whose whole supply sits locked in a position
                // whose market does not work, and nobody discovers it until
                // the first fee collection.
                if (!allowTaxedQuote || !quotePricer.transfersAssessed(pairToken)) {
                    revert QuoteAssetNotProven(pairToken);
                }
            }
        }
    }

    /**
     * @dev Opens one pool per quote asset: writes the hook terms where the
     * launcher's staged terms call for a hook (the same sniper block,
     * opening fee and whitelist on every pool), initialises each pool at
     * its planned price, mints all positions in one go and locks them.
     * Returns market 0 and the supply that went into it.
     */
    function _openMarkets(
        address token,
        LaunchConfig memory config,
        address[] memory pairTokens,
        uint256[] memory phantoms,
        address launcher,
        uint24 poolFee
    ) private returns (Market memory m0, uint256 tokenAmount0) {
        uint256 n = pairTokens.length;
        PoolKey[] memory keys = new PoolKey[](n);
        FusingPositionMath.Plan[] memory plans = new FusingPositionMath.Plan[](n);
        // The same shares `_phantoms` sized the reserves under; the supplies
        // must be cut the same way or the pools open at different prices.
        uint256[] memory supplies = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            supplies[i] = config.supply * marketShareBps(n, i) / BASIS_POINTS;
        }
        for (uint256 i = 0; i < n; i++) {
            // The hook goes on every pool or none: the decision is the launcher's terms, not the asset.
            keys[i] = _launchKey(token, pairTokens[i], poolFee, config.tickSpacing, launcher);
            plans[i] = positionMinter.plan(
                Currency.unwrap(keys[i].currency0) == token, supplies[i], phantoms[i], config.tickSpacing
            );
            // V2 ordering: the hook rejects initialisation of a pool without
            // terms, so terms are written first, then the pool is opened.
            if (address(keys[i].hooks) != address(0)) _applyHookTerms(keys[i].toId(), poolFee, launcher);
            poolManager.initialize(keys[i], plans[i].sqrtPriceX96);
        }
        (uint256[] memory positionIds, uint256[] memory tokenAmounts) =
            positionMinter.mintLaunchPositions(token, keys, plans, supplies);
        locker.lockPositions(token, positionIds);
        for (uint256 i = 0; i < n; i++) {
            Market memory m = Market({
                pairToken: pairTokens[i],
                phantomQuote: phantoms[i],
                tickLower: plans[i].tickLower,
                tickUpper: plans[i].tickUpper,
                liquidity: plans[i].liquidity,
                positionId: positionIds[i]
            });
            _markets[token].push(m);
            emit MarketOpened(
                token,
                PoolId.unwrap(keys[i].toId()),
                uint8(i),
                m.pairToken,
                m.positionId,
                m.tickLower,
                m.tickUpper,
                m.liquidity,
                tokenAmounts[i],
                m.phantomQuote
            );
            if (i == 0) {
                m0 = m;
                tokenAmount0 = tokenAmounts[0];
            }
        }
    }

    // ---------------------------------------------------------------------
    // Creator fee recipient
    // ---------------------------------------------------------------------
    // The creator-side owner of a launch's fees lives in the Fuse Vault:
    // handed on there by the owner, or overridden by the protocol through
    // the Vault's timelock. The Vault mirrors every change into this
    // record so `creatorFeeRecipient` stays the one figure to read.

    function _setCreatorFeeRecipient(address token, LaunchedToken storage launch, address newRecipient) private {
        if (newRecipient == address(0)) revert ZeroAddress();
        address previousRecipient = launch.creatorFeeRecipient;
        launch.creatorFeeRecipient = newRecipient;
        emit CreatorFeeRecipientUpdated(token, previousRecipient, newRecipient);
    }

    // ---------------------------------------------------------------------
    // Internal helpers
    // ---------------------------------------------------------------------

    /**
     * @dev Works out the phantom reserve for whichever quote asset is used.
     * Native ETH uses the config's figure directly; a curated ERC-20 uses
     * the owner-set override; any other ERC-20 gets a figure from the quote
     * pricer at the reference pool's current price, so the opening market
     * cap matches regardless of the quote.
     */
    function _quoteEconomics(LaunchConfig memory config, address pairToken) private view returns (uint256) {
        if (pairToken == address(0)) return config.phantomQuote;

        PairTokenEconomics memory curated = pairTokenEconomics[pairToken];
        if (curated.phantomQuote != 0) {
            _requireDecimals(pairToken, curated.decimals, true);
            return curated.phantomQuote;
        }

        if (pairToken.code.length == 0) revert PairTokenValidationFailed();
        if (_readDecimals(pairToken) < MIN_PAIR_TOKEN_DECIMALS) revert PairTokenValidationFailed();
        return quotePricer.quoteEconomics(pairToken, config.phantomQuote);
    }

    function _requireDecimals(address pairToken, uint8 expectedDecimals, bool required) private view {
        if (!required && pairToken.code.length == 0) return;
        try IERC20Metadata(pairToken).decimals() returns (uint8 actual) {
            if (actual != expectedDecimals) revert PairTokenDecimalsMismatch(expectedDecimals, actual);
        } catch {
            if (required) revert PairTokenDecimalsUnavailable();
        }
    }

    function _readDecimals(address pairToken) private view returns (uint8) {
        try IERC20Metadata(pairToken).decimals() returns (uint8 actual) {
            return actual;
        } catch {
            revert PairTokenDecimalsUnavailable();
        }
    }

    /**
     * @dev Hashes every owner-controlled term that determines what a
     * creator is signing up for: the curve's shape, the tick spacing and
     * the fees.
     */
    function _economicsDigest(LaunchConfig memory config, uint256 phantomQuote) private view returns (bytes32) {
        return keccak256(
            abi.encode(phantomQuote, config.supply, config.tickSpacing, baseFeeBps, protocolFeeShareBps)
        );
    }

    /**
     * @dev The digest of a multi-market launch: for one market it is the
     * one-pool digest to the bit, so an interface that mines and asserts
     * economics for one-pool launches never notices; for more it commits to
     * every market's opening reserve in order.
     */
    /// @dev A non-zero expected digest must match what the launch would commit to now.
    function _requireEconomics(bytes32 expected, LaunchConfig memory config, uint256[] memory phantoms) private view {
        if (expected == bytes32(0)) return;
        bytes32 actual = _economicsDigest(config, phantoms);
        if (expected != actual) revert LaunchEconomicsMismatch(expected, actual);
    }

    function _economicsDigest(LaunchConfig memory config, uint256[] memory phantoms) private view returns (bytes32) {
        if (phantoms.length == 1) return _economicsDigest(config, phantoms[0]);
        return keccak256(abi.encode(phantoms, config.supply, config.tickSpacing, baseFeeBps, protocolFeeShareBps));
    }

    /**
     * @dev Blocks launching until every helper points back at this factory
     * and shares its core dependencies.
     */
    function _requireLaunchDependenciesWired() private view {
        if (address(positionMinter) == address(0) || address(launchDeployer) == address(0)) {
            revert LaunchDependenciesNotWired();
        }
        if (launchDeployer.factory() != address(this) || positionMinter.factory() != address(this)) {
            revert LaunchDependenciesNotWired();
        }
        if (address(feeHook) == address(0)) revert FeeHookNotWired();
        if (address(vault) == address(0)) revert LaunchDependenciesNotWired();
        if (address(locker.factory()) != address(this)) revert LaunchDependenciesNotWired();
        if (
            address(locker.positionManager()) != address(positionManager)
                || address(locker.feeEscrow()) != address(feeEscrow)
        ) {
            revert LaunchDependenciesNotWired();
        }
        if (
            address(positionMinter.positionManager()) != address(positionManager)
                || address(positionMinter.locker()) != address(locker)
        ) {
            revert LaunchDependenciesNotWired();
        }
    }

    /**
     * @dev A hooked V2 pool key carries the fee hook and the dynamic-fee
     * flag, and the hook tells the pool manager what each swap pays; the
     * resting fee then lives on the launch record for the locker's split. A
     * pool that needed no hook carries the resting fee in the key like V1.
     */
    function _poolKey(address token, address pairToken, uint24 poolFee, int24 tickSpacing, address hook)
        private
        pure
        returns (PoolKey memory)
    {
        (Currency currency0, Currency currency1) = pairToken < token
            ? (Currency.wrap(pairToken), Currency.wrap(token))
            : (Currency.wrap(token), Currency.wrap(pairToken));
        return PoolKey({
            currency0: currency0,
            currency1: currency1,
            // A hooked pool takes its fee from the hook each swap; a plain pool carries the resting fee itself.
            fee: hook == address(0) ? poolFee : LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: tickSpacing,
            hooks: IHooks(hook)
        });
    }

    function _payLaunchFee() private {
        if (launchFee == 0) return;
        (bool sent,) = payable(protocolFeeRecipient).call{value: launchFee}("");
        if (!sent) revert FeeTransferFailed();
    }

    function _validateLaunchConfig(LaunchConfig calldata config) private view {
        if (config.supply < MIN_LAUNCH_SUPPLY) revert SupplyTooLow();
        if (config.supply > MAX_SUPPLY) revert SupplyTooHigh();
        if (config.phantomQuote == 0) revert InvalidPhantomQuote();
        if (config.tickSpacing <= 0 || config.tickSpacing > MAX_TICK_SPACING) revert InvalidTickSpacing();
        // Reject a config the position math cannot plan here, once, instead
        // of on every launch. Both currency orderings are tried since the
        // token's address decides which one applies.
        if (address(positionMinter) != address(0)) {
            positionMinter.plan(true, config.supply, config.phantomQuote, config.tickSpacing);
            positionMinter.plan(false, config.supply, config.phantomQuote, config.tickSpacing);
        }
    }


}
