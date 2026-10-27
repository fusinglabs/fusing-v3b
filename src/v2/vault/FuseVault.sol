// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/*
 *  fusi.ng  |  the Ethereum launchpad
 *  ----------------------------------
 *  Web:       https://fusi.ng
 *  X:         https://x.com/fusi_ng
 *  Telegram:  https://t.me/fusi_ng
 *  Docs:      https://fusi.ng/docs
 */

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {FusingTerms} from "../libraries/FusingTerms.sol";
import {IFuseModule} from "./IFuseModule.sol";
import {Hop, HopKind} from "../libraries/Hop.sol";
import {IFusingLaunchFactory} from "../interfaces/ILaunchpadV2.sol";

/// @dev The factory views the Vault needs: staged terms, the launch record and the primary pool key.
interface IFuseVaultFactory is IFusingLaunchFactory {
    function termsOf(address launcher) external view returns (FusingTerms.LaunchTerms memory);
    function poolKeyFor(address token) external view returns (PoolKey memory);
    function marketsOf(address token) external view returns (Market[] memory);
    struct Market {
        address pairToken;
        uint256 phantomQuote;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint256 positionId;
    }
}

/// @dev The locker call that collects every market and deposits the creator remainder here.
interface IFuseVaultLocker {
    function collectFees(address token) external returns (uint256 amount0, uint256 amount1);
    function pendingFeesAll(address token) external view returns (uint256[] memory amount0s, uint256[] memory amount1s);
}

/// @dev The pricer, for the ETH value of a quote asset.
interface IFuseVaultPricer {
    function priceEthAmountInQuote(address quoteToken, uint256 ethAmount) external view returns (uint256);
    function isPriceable(address quoteToken) external view returns (bool);
    function route(address quoteToken) external view returns (Hop[] memory hops, bool qualifies);
}

/// @dev The router calls used to turn a refund slice into ETH.
interface IFuseVaultRouter {
    function quoteToEth(Currency quote, uint256 amountIn, Hop[] calldata leg, uint256 minEthOut, address recipient)
        external
        returns (uint256 ethOut);
    function sellToEth(PoolKey calldata key, bool tokenIsCurrency0, uint256 tokensIn, Hop[] calldata leg, uint256 minEthOut, address recipient)
        external
        returns (uint256 ethOut);
}

/// @dev The factory's record hand-off when the creator transfers the fee owner on this side.
interface IFuseVaultFactorySync {
    function syncCreatorFeeRecipient(address token, address to) external;
}

/**
 * @title FuseVault
 * @notice The registry every launch's fees flow through. Per launch it holds
 * the fee configuration (owner, HARD or FLEX, payout currency, up to six
 * module allocations) and an owed ledger; it holds no fee logic of its own.
 * The locker deposits a launch's creator remainder here; `collect` routes
 * it to the modules by share, each in its own try, and refunds the caller's
 * gas from the fees. Anything a module could not take stays owed and can
 * be retried or, on FLEX launches, redirected.
 *
 * The protocol's share never comes here: the locker pays it in ETH first.
 * Launch tokens have no owner; the fee owner lives in this contract, is
 * handed on one way, and overridden only by the protocol through a
 * three-day timelock with a three-day execution window.
 */
contract FuseVault is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    // ------------------------------------------------------------------ types

    struct Config {
        address owner;
        bool hard;
        FusingTerms.PayoutMode payout;
        uint64 version;
        uint64 lastCollectAt;
        FusingTerms.Allocation[] allocations;
    }

    struct Module {
        address impl;
        bool enabled;
        string name;
    }

    struct PendingOwner {
        address to;
        uint64 effectiveAt;
        uint64 expiresAt;
    }

    struct Keeper {
        uint32 minInterval; // seconds between collections of one launch
        uint16 minWorthMultiple; // fees must be worth this many refunds
        uint16 refundMultiplier; // bps of measured gas cost refunded, 15_000 = 150%
        uint64 maxGasPrice; // wei; the refund never prices gas above this
        uint128 maxRefund; // wei; hard ceiling per collection
        uint32 refundGasEstimate; // gas a collection is assumed to cost, for the worth view
    }

    // ----------------------------------------------------------------- errors

    error ZeroAddress();
    error NotFactory();
    error NotLocker();
    error NotDepositor();
    error NotConfigOwner();
    error Hard();
    error UnknownLaunch(address token);
    error AlreadyRegistered(address token);
    error TooManyAllocations();
    error SharesInvalid();
    error ModuleUnavailable(uint8 moduleId);
    error TooSoon(uint64 nextAt);
    error NotWorthCollecting(uint256 valueEth, uint256 needEth);
    error NothingOwed();
    error BadKeeperParams();
    error NoPendingChange();
    error TimelockNotElapsed(uint256 effectiveAt);
    error TimelockExpired(uint256 expiresAt);

    // ----------------------------------------------------------------- events

    event ModuleAdded(uint8 indexed moduleId, address impl, string name);
    event ModuleImplSet(uint8 indexed moduleId, address impl, bool enabled);
    event DepositorSet(address indexed who, bool allowed);
    event KeeperSet(Keeper keeper);
    event Registered(address indexed token, address indexed owner, bool hard, FusingTerms.PayoutMode payout, uint256 allocations);
    event ConfigChanged(address indexed token, uint64 version, FusingTerms.PayoutMode payout, uint256 allocations, address by);
    event Hardened(address indexed token, address by);
    event OwnerTransferred(address indexed token, address indexed from, address indexed to, bool byOverride);
    event OwnerChangeProposed(address indexed token, address indexed from, address indexed to, uint64 effectiveAt, uint64 expiresAt);
    event OwnerChangeCancelled(address indexed token, address indexed to);
    event Deposited(address indexed token, address indexed currency, uint256 amount, address from);
    event Delivered(address indexed token, uint8 indexed moduleId, address indexed currency, uint256 amount);
    event Deferred(address indexed token, uint8 indexed moduleId, address indexed currency, uint256 amount, bytes reason);
    event Redirected(address indexed token, uint8 fromModule, uint8 toModule, address currency, uint256 amount);
    event Collected(address indexed token, address indexed caller, uint256 valueEth, uint256 refundEth);

    // ---------------------------------------------------------------- storage

    uint256 private constant BPS = 10_000;
    uint256 public constant MAX_ALLOCATIONS = 6;
    /// @notice A protocol override of a launch's fee owner waits this long, then may be executed for this long.
    uint64 public constant OWNER_OVERRIDE_TIMELOCK = 3 days;
    uint64 public constant OWNER_OVERRIDE_WINDOW = 3 days;

    IFuseVaultFactory public immutable factory;
    IFuseVaultLocker public immutable locker;
    IFuseVaultPricer public immutable pricer;
    IFuseVaultRouter public immutable router;
    IPoolManager public immutable poolManager;

    Module[] private _modules;
    /// @notice Contracts that may deposit fees: the locker and the converter.
    mapping(address who => bool allowed) public depositors;
    Keeper public keeper;

    mapping(address token => Config) private _configs;
    /// @notice A protocol override of the fee owner that is waiting out its timelock.
    mapping(address token => PendingOwner) public pendingOwner;
    /// @notice Deposited and not yet routed, per launch and currency (address zero = ETH).
    mapping(address token => mapping(address currency => uint256)) public pool;
    /// @notice Routed to a module that could not take it, per launch, module and currency.
    mapping(address token => mapping(uint8 moduleId => mapping(address currency => uint256))) public owed;
    /// @dev The currencies a launch has ever held here, so `collect` and `retry` know what to walk.
    mapping(address token => address[]) private _currencies;
    mapping(address token => mapping(address currency => bool)) private _known;

    modifier onlyConfigOwner(address token) {
        if (msg.sender != _configs[token].owner) revert NotConfigOwner();
        _;
    }

    constructor(
        address initialOwner,
        IFuseVaultFactory factory_,
        IFuseVaultLocker locker_,
        IFuseVaultPricer pricer_,
        IFuseVaultRouter router_,
        IPoolManager poolManager_
    ) Ownable(initialOwner) {
        if (
            address(factory_) == address(0) || address(locker_) == address(0) || address(pricer_) == address(0)
                || address(router_) == address(0) || address(poolManager_) == address(0)
        ) revert ZeroAddress();
        factory = factory_;
        locker = locker_;
        pricer = pricer_;
        router = router_;
        poolManager = poolManager_;
        depositors[address(locker_)] = true;
        keeper = Keeper({
            minInterval: 1 hours,
            minWorthMultiple: 3,
            refundMultiplier: 15_000,
            maxGasPrice: 50 gwei,
            maxRefund: 0.01 ether,
            refundGasEstimate: 900_000
        });
    }

    receive() external payable {}

    // ------------------------------------------------------------------ admin

    /// @notice Registers a module. Ids are assigned in order and never reused; the first five are the well-known ones.
    function addModule(address impl, string calldata name) external onlyOwner returns (uint8 id) {
        if (impl == address(0)) revert ZeroAddress();
        id = uint8(_modules.length);
        _modules.push(Module({impl: impl, enabled: true, name: name}));
        emit ModuleAdded(id, impl, name);
    }

    /// @notice Swaps a module's implementation or switches it off. Launches keep their allocations; a disabled module defers.
    function setModule(uint8 id, address impl, bool enabled) external onlyOwner {
        if (id >= _modules.length) revert ModuleUnavailable(id);
        if (impl == address(0)) revert ZeroAddress();
        _modules[id].impl = impl;
        _modules[id].enabled = enabled;
        emit ModuleImplSet(id, impl, enabled);
    }

    function setDepositor(address who, bool allowed) external onlyOwner {
        if (who == address(0)) revert ZeroAddress();
        depositors[who] = allowed;
        emit DepositorSet(who, allowed);
    }

    function setKeeper(Keeper calldata k) external onlyOwner {
        if (k.minWorthMultiple == 0 || k.refundMultiplier < BPS || k.maxGasPrice == 0 || k.refundGasEstimate == 0) revert BadKeeperParams();
        keeper = k;
        emit KeeperSet(k);
    }

    /// @notice Admin may set any launch's configuration, HARD or not: the way a broken plan is repaired.
    function adminSetConfig(address token, FusingTerms.PayoutMode payout, FusingTerms.Allocation[] calldata allocations)
        external
        onlyOwner
    {
        _requireLaunch(token);
        _setConfig(token, payout, allocations, msg.sender);
    }

    function renounceOwnership() public pure override {
        revert("FuseVault: no renounce");
    }

    // ------------------------------------------------------------ registry

    function modules(uint8 id) external view returns (Module memory) {
        return _modules[id];
    }

    function modulesLength() external view returns (uint256) {
        return _modules.length;
    }

    function configOf(address token) external view returns (Config memory) {
        return _configs[token];
    }

    function configOwner(address token) external view returns (address) {
        return _configs[token].owner;
    }

    function payoutOf(address token) external view returns (FusingTerms.PayoutMode) {
        return _configs[token].payout;
    }

    /**
     * @notice Called by the factory in the launch transaction, before it
     * wipes the launcher's staged terms. Reads the terms itself. Staged
     * nothing means the plain launch: FLEX, paid in ETH, all to `owner`.
     */
    function register(address token, address launcher, address owner_) external {
        if (msg.sender != address(factory)) revert NotFactory();
        if (_configs[token].owner != address(0)) revert AlreadyRegistered(token);
        if (owner_ == address(0)) revert ZeroAddress();
        FusingTerms.LaunchTerms memory t = factory.termsOf(launcher);
        Config storage c = _configs[token];
        c.owner = owner_;
        c.hard = t.hard;
        c.payout = t.payoutMode;
        c.version = 1;
        /*
         * The default plan is deliberately not written down. A launch that
         * staged nothing leaves the allocation list empty, and `_route` reads
         * an empty list as "all of it to the config owner". Writing a
         * synthetic "100% to the owner via the wallets module" allocation
         * instead cost around 240k gas on every launch - a module configure
         * call, plus its 128 bytes of encoded params in cold storage - purely
         * to describe the behaviour the code already has.
         */
        if (t.allocations.length != 0) _applyAllocations(token, t.allocations);
        emit Registered(token, owner_, c.hard, c.payout, c.allocations.length);
    }

    function _single(address a) private pure returns (address[] memory l) {
        l = new address[](1);
        l[0] = a;
    }

    function _single16() private pure returns (uint16[] memory l) {
        l = new uint16[](1);
        l[0] = uint16(BPS);
    }

    // ---------------------------------------------------------- ownership

    /// @notice Hands the configuration on. One way: the previous owner has no path back.
    function transferOwner(address token, address to) external onlyConfigOwner(token) {
        if (to == address(0)) revert ZeroAddress();
        emit OwnerTransferred(token, msg.sender, to, false);
        _configs[token].owner = to;
        _followDefault(token, msg.sender, to);
        // The factory's launch record follows, so every reader of `creatorFeeRecipient` sees the same owner.
        IFuseVaultFactorySync(address(factory)).syncCreatorFeeRecipient(token, to);
    }

    /**
     * @notice Opens a protocol override of a launch's fee owner, the
     * recovery route for a lost wallet and the community takeover path.
     * Nothing changes until the timelock has passed and somebody calls
     * `executeOwnerChange`. A matured proposal wins over any transfer the
     * owner made in the meantime: the timelock gives notice, not a veto.
     */
    function proposeOwner(address token, address to) external onlyOwner {
        _requireLaunch(token);
        if (to == address(0)) revert ZeroAddress();
        uint64 effectiveAt = uint64(block.timestamp) + OWNER_OVERRIDE_TIMELOCK;
        uint64 expiresAt = effectiveAt + OWNER_OVERRIDE_WINDOW;
        pendingOwner[token] = PendingOwner({to: to, effectiveAt: effectiveAt, expiresAt: expiresAt});
        emit OwnerChangeProposed(token, _configs[token].owner, to, effectiveAt, expiresAt);
    }

    /// @notice Lands a matured override. Anyone may call it inside the window.
    function executeOwnerChange(address token) external {
        PendingOwner memory p = pendingOwner[token];
        if (p.to == address(0)) revert NoPendingChange();
        if (block.timestamp < p.effectiveAt) revert TimelockNotElapsed(p.effectiveAt);
        if (block.timestamp > p.expiresAt) revert TimelockExpired(p.expiresAt);
        delete pendingOwner[token];
        address from = _configs[token].owner;
        emit OwnerTransferred(token, from, p.to, true);
        _configs[token].owner = p.to;
        _followDefault(token, from, p.to);
        IFuseVaultFactorySync(address(factory)).syncCreatorFeeRecipient(token, p.to);
    }

    /**
     * @dev A plain launch pays everything to its owner through the wallets
     * module; when the owner changes, so does that default, HARD or not,
     * so a hand-over or a takeover moves the fees with it. A custom plan is
     * left as it is: the new owner (FLEX) or the admin (HARD) decides.
     */
    function _followDefault(address token, address from, address to) private {
        Config storage c = _configs[token];
        if (c.allocations.length != 1) return;
        FusingTerms.Allocation storage a = c.allocations[0];
        if (a.moduleId != FusingTerms.MODULE_WALLETS || a.bps != BPS) return;
        if (keccak256(a.params) != keccak256(abi.encode(_single(from), _single16()))) return;
        a.params = abi.encode(_single(to), _single16());
        IFuseModule(_modules[FusingTerms.MODULE_WALLETS].impl).configure(token, a.params);
        c.version += 1;
        emit ConfigChanged(token, c.version, c.payout, 1, msg.sender);
    }

    function cancelOwnerChange(address token) external onlyOwner {
        PendingOwner memory p = pendingOwner[token];
        if (p.to == address(0)) revert NoPendingChange();
        delete pendingOwner[token];
        emit OwnerChangeCancelled(token, p.to);
    }

    // ------------------------------------------------------ configuration

    /// @notice FLEX launches: the owner may change payout and allocations at will. Owed amounts follow the new plan on the next retry.
    function setConfig(address token, FusingTerms.PayoutMode payout, FusingTerms.Allocation[] calldata allocations)
        external
        onlyConfigOwner(token)
    {
        if (_configs[token].hard) revert Hard();
        _setConfig(token, payout, allocations, msg.sender);
    }

    /**
     * @notice FLEX to HARD, one way. The owner gives up the right to change
     * the payout and the allocations, the same as if the launch had been
     * made HARD from the start: the configuration as it stands is now fixed
     * for the life of the launch (the Vault admin excepted). A creator
     * launches FLEX to tune the plan in the open, then hardens it as a
     * commitment to holders. There is no way back.
     */
    function harden(address token) external onlyConfigOwner(token) {
        Config storage c = _configs[token];
        if (c.hard) revert Hard();
        c.hard = true;
        emit Hardened(token, msg.sender);
    }

    function _setConfig(address token, FusingTerms.PayoutMode payout, FusingTerms.Allocation[] memory allocations, address by)
        private
    {
        Config storage c = _configs[token];
        c.payout = payout;
        c.version += 1;
        delete c.allocations;
        _applyAllocations(token, allocations);
        emit ConfigChanged(token, c.version, payout, allocations.length, by);
    }

    function _applyAllocations(address token, FusingTerms.Allocation[] memory allocations) private {
        if (allocations.length == 0 || allocations.length > MAX_ALLOCATIONS) revert TooManyAllocations();
        uint256 sum;
        Config storage c = _configs[token];
        for (uint256 i = 0; i < allocations.length; i++) {
            FusingTerms.Allocation memory a = allocations[i];
            if (a.bps == 0) revert SharesInvalid();
            if (a.moduleId >= _modules.length || !_modules[a.moduleId].enabled) revert ModuleUnavailable(a.moduleId);
            sum += a.bps;
            // The module keeps its own copy of the parameters and refuses what it cannot use.
            IFuseModule(_modules[a.moduleId].impl).configure(token, a.params);
            c.allocations.push(a);
        }
        if (sum != BPS) revert SharesInvalid();
    }

    // ------------------------------------------------------------ deposits

    /// @notice The locker (and the converter on its behalf) deposit a launch's creator remainder here.
    function deposit(address token, address currency, uint256 amount) external payable {
        if (!depositors[msg.sender]) revert NotDepositor();
        if (currency == address(0)) {
            if (msg.value != amount) revert SharesInvalid();
        } else {
            if (msg.value != 0) revert SharesInvalid();
            // Credit what ARRIVED, not what was asked for. A quote asset that
            // charges a fee on transfer delivers less than it was sent, and
            // crediting the nominal figure would have the Vault owe more than
            // it holds, which surfaces as the last claimant being unable to
            // withdraw. Measuring is also strictly correct for an ordinary
            // token, where the two figures are the same.
            uint256 before = IERC20(currency).balanceOf(address(this));
            IERC20(currency).safeTransferFrom(msg.sender, address(this), amount);
            amount = IERC20(currency).balanceOf(address(this)) - before;
        }
        if (amount == 0) return;
        pool[token][currency] += amount;
        if (!_known[token][currency]) {
            _known[token][currency] = true;
            _currencies[token].push(currency);
        }
        emit Deposited(token, currency, amount, msg.sender);
    }

    function currenciesOf(address token) external view returns (address[] memory) {
        return _currencies[token];
    }

    // ----------------------------------------------------------- collection

    /**
     * @notice Collects every market of `token`, routes the creator remainder
     * to the modules by share and refunds the caller's gas from the fees.
     * Anyone may call it. Reverts, moving nothing, when it is too soon or
     * the fees are not worth the refund.
     */
    function collect(address token) external nonReentrant returns (uint256 amount0, uint256 amount1) {
        uint256 gasStart = gasleft();
        Config storage c = _configs[token];
        if (c.owner == address(0)) revert UnknownLaunch(token);
        // The first collection of a launch is always allowed; after that the interval applies.
        uint64 nextAt = c.lastCollectAt == 0 ? 0 : c.lastCollectAt + keeper.minInterval;
        if (block.timestamp < nextAt) revert TooSoon(nextAt);

        // The locker pays the protocol in ETH and deposits the rest here.
        (amount0, amount1) = locker.collectFees(token);

        uint256 valueEth = _poolValueEth(token);
        uint256 refundCap = _refundEstimate();
        if (valueEth < refundCap * keeper.minWorthMultiple) revert NotWorthCollecting(valueEth, refundCap * keeper.minWorthMultiple);

        c.lastCollectAt = uint64(block.timestamp);
        // Reserve the refund in ETH before routing, converting a slice if the pool holds none.
        uint256 refund = _reserveRefund(token, refundCap);
        _route(token);

        // The actual gas, capped; anything reserved above it goes back into the pool.
        uint256 used = gasStart - gasleft() + 35_000;
        uint256 due = _refundFor(used);
        if (due > refund) due = refund;
        if (refund > due) pool[token][address(0)] += refund - due;
        if (due > 0) {
            (bool ok,) = msg.sender.call{value: due}("");
            if (!ok) pool[token][address(0)] += due;
        }
        emit Collected(token, msg.sender, valueEth, due);
    }

    /// @notice Re-attempts what a module could not take. Anyone may call it.
    function retry(address token, uint8 moduleId) external nonReentrant {
        _requireLaunch(token);
        address[] memory cs = _currencies[token];
        bool any;
        for (uint256 i = 0; i < cs.length; i++) {
            uint256 amount = owed[token][moduleId][cs[i]];
            if (amount == 0) continue;
            any = true;
            owed[token][moduleId][cs[i]] = 0;
            _deliver(token, moduleId, cs[i], amount);
        }
        if (!any) revert NothingOwed();
    }

    /// @notice Moves what one module is owed to another. The owner on FLEX launches, the admin on any.
    function redirect(address token, uint8 fromModule, uint8 toModule) external nonReentrant {
        Config storage c = _configs[token];
        if (c.owner == address(0)) revert UnknownLaunch(token);
        bool admin = msg.sender == owner();
        if (!admin) {
            if (msg.sender != c.owner) revert NotConfigOwner();
            if (c.hard) revert Hard();
        }
        if (toModule >= _modules.length || !_modules[toModule].enabled) revert ModuleUnavailable(toModule);
        address[] memory cs = _currencies[token];
        for (uint256 i = 0; i < cs.length; i++) {
            uint256 amount = owed[token][fromModule][cs[i]];
            if (amount == 0) continue;
            owed[token][fromModule][cs[i]] = 0;
            emit Redirected(token, fromModule, toModule, cs[i], amount);
            _deliver(token, toModule, cs[i], amount);
        }
    }

    /// @dev Splits every currency in the pool across the allocations. Each delivery is isolated.
    function _route(address token) private {
        Config storage c = _configs[token];
        address[] memory cs = _currencies[token];
        uint256 n = c.allocations.length;
        for (uint256 i = 0; i < cs.length; i++) {
            uint256 total = pool[token][cs[i]];
            if (total == 0) continue;
            pool[token][cs[i]] = 0;
            // No allocations is the default plan, not an empty one: the whole
            // amount goes through the wallets module, which pays the config owner.
            if (n == 0) {
                _deliver(token, FusingTerms.MODULE_WALLETS, cs[i], total);
                continue;
            }
            uint256 handed;
            for (uint256 j = 0; j < n; j++) {
                FusingTerms.Allocation storage a = c.allocations[j];
                uint256 share = j + 1 == n ? total - handed : total * a.bps / BPS;
                handed += share;
                if (share == 0) continue;
                _deliver(token, a.moduleId, cs[i], share);
            }
        }
    }

    /// @dev One module call in its own try. Success is the only thing that marks an amount delivered.
    function _deliver(address token, uint8 moduleId, address currency, uint256 amount) private {
        Module storage m = _modules[moduleId];
        if (!m.enabled) {
            owed[token][moduleId][currency] += amount;
            emit Deferred(token, moduleId, currency, amount, "module disabled");
            return;
        }
        if (currency != address(0)) IERC20(currency).forceApprove(m.impl, amount);
        try IFuseModule(m.impl).onFees{value: currency == address(0) ? amount : 0}(token, currency, amount) {
            emit Delivered(token, moduleId, currency, amount);
        } catch (bytes memory reason) {
            if (currency != address(0)) IERC20(currency).forceApprove(m.impl, 0);
            owed[token][moduleId][currency] += amount;
            emit Deferred(token, moduleId, currency, amount, reason);
        }
    }

    // --------------------------------------------------------------- keeper

    /// @notice For keepers and the interface: what the pending fees are worth, what a collection would refund, and whether it is worth doing now.
    function worth(address token) external view returns (uint256 valueEth, uint256 refundEth, bool worthIt, uint64 nextAt) {
        Config storage c = _configs[token];
        nextAt = c.lastCollectAt == 0 ? 0 : c.lastCollectAt + keeper.minInterval;
        refundEth = _refundEstimate();
        valueEth = _pendingValueEth(token) + _poolValueEth(token);
        worthIt = block.timestamp >= nextAt && valueEth >= refundEth * keeper.minWorthMultiple;
    }

    function _refundEstimate() private view returns (uint256) {
        return _refundFor(keeper.refundGasEstimate);
    }

    function _refundFor(uint256 gasUsed) private view returns (uint256) {
        uint256 price = tx.gasprice < keeper.maxGasPrice ? tx.gasprice : keeper.maxGasPrice;
        uint256 r = gasUsed * price * keeper.refundMultiplier / BPS;
        return r > keeper.maxRefund ? keeper.maxRefund : r;
    }

    /// @dev Takes the refund out of the pool's ETH; sells a slice of another currency for ETH when there is none.
    function _reserveRefund(address token, uint256 wanted) private returns (uint256 reserved) {
        uint256 eth = pool[token][address(0)];
        if (eth >= wanted) {
            pool[token][address(0)] = eth - wanted;
            return wanted;
        }
        reserved = eth;
        pool[token][address(0)] = 0;
        address[] memory cs = _currencies[token];
        for (uint256 i = 0; i < cs.length && reserved < wanted; i++) {
            address cur = cs[i];
            if (cur == address(0) || pool[token][cur] == 0) continue;
            uint256 needEth = wanted - reserved;
            uint256 amount = _amountForEth(token, cur, needEth);
            if (amount > pool[token][cur]) amount = pool[token][cur];
            if (amount == 0) continue;
            pool[token][cur] -= amount;
            uint256 got = _sellForEth(token, cur, amount);
            reserved += got;
        }
    }

    /// @dev Sells `amount` of `currency` (the launch token or a quote) for ETH through the router; returns what arrived.
    function _sellForEth(address token, address currency, uint256 amount) private returns (uint256 got) {
        uint256 before = address(this).balance;
        IERC20(currency).forceApprove(address(router), amount);
        if (currency == token) {
            PoolKey memory key = factory.poolKeyFor(token);
            Hop[] memory none;
            try router.sellToEth(key, Currency.unwrap(key.currency0) == token, amount, none, 0, address(this)) {} catch {}
        } else {
            (Hop[] memory hops, bool qualifies) = pricer.route(currency);
            if (qualifies && hops.length > 0) {
                try router.quoteToEth(Currency.wrap(currency), amount, hops, 0, address(this)) {} catch {}
            }
        }
        got = address(this).balance - before;
        // Whatever the router did not take stays in the pool.
        uint256 leftAllowance = IERC20(currency).allowance(address(this), address(router));
        if (leftAllowance > 0) {
            IERC20(currency).forceApprove(address(router), 0);
            pool[token][currency] += leftAllowance;
        }
    }

    // ------------------------------------------------------------ valuation

    function _poolValueEth(address token) private view returns (uint256 v) {
        address[] memory cs = _currencies[token];
        for (uint256 i = 0; i < cs.length; i++) {
            v += _valueEth(token, cs[i], pool[token][cs[i]]);
        }
    }

    /// @dev The creator's part of the pending fees of every market, valued in ETH the same way. The protocol takes its share of the base fee first; the creator tax is the creator's alone.
    function _pendingValueEth(address token) private view returns (uint256 v) {
        (uint256[] memory a0s, uint256[] memory a1s) = locker.pendingFeesAll(token);
        IFuseVaultFactory.Market[] memory ms = factory.marketsOf(token);
        for (uint256 i = 0; i < ms.length; i++) {
            // Native ETH is always currency0; an ERC-20 quote is currency0 when its address sorts below the token.
            bool tokenIs0 = ms[i].pairToken != address(0) && token < ms[i].pairToken;
            uint256 tokenAmt = tokenIs0 ? a0s[i] : a1s[i];
            uint256 quoteAmt = tokenIs0 ? a1s[i] : a0s[i];
            v += _valueEth(token, token, tokenAmt) + _valueEth(token, ms[i].pairToken, quoteAmt);
        }
        if (v == 0) return 0;
        IFusingLaunchFactory.LaunchedToken memory l = factory.getLaunchedToken(token);
        uint256 total = uint256(l.baseFeeBps) + l.creatorTaxBps;
        if (total == 0) return v;
        uint256 creatorPart = uint256(l.baseFeeBps) * (BPS - l.protocolFeeShareBps) / BPS + l.creatorTaxBps;
        v = v * creatorPart / total;
    }

    /// @dev ETH value of `amount` of `currency`: ETH as is, the launch token at its primary pool's spot, a quote through the pricer. Unpriceable is worth zero here.
    function _valueEth(address token, address currency, uint256 amount) private view returns (uint256) {
        if (amount == 0) return 0;
        if (currency == address(0)) return amount;
        if (currency == token) return _tokenValueEth(token, amount);
        try pricer.priceEthAmountInQuote(currency, 1 ether) returns (uint256 quotePerEth) {
            return quotePerEth == 0 ? 0 : FullMath.mulDiv(amount, 1 ether, quotePerEth);
        } catch {
            return 0;
        }
    }

    /// @dev Spot value of launch tokens in ETH from the primary pool, zero when that pool is not ETH-quoted.
    function _tokenValueEth(address token, uint256 amount) private view returns (uint256) {
        PoolKey memory key = factory.poolKeyFor(token);
        if (Currency.unwrap(key.currency0) != address(0)) return 0;
        (uint160 sqrtP,,,) = poolManager.getSlot0(key.toId());
        if (sqrtP == 0) return 0;
        // ETH is currency0, token currency1: price1 (token per ETH) = (sqrtP/2^96)^2, so eth = amount / price.
        uint256 priceX96 = FullMath.mulDiv(uint256(sqrtP), uint256(sqrtP), 1 << 96);
        if (priceX96 == 0) return 0;
        return FullMath.mulDiv(amount, 1 << 96, priceX96);
    }

    /// @dev How much of `currency` is worth `ethAmount`, the inverse of `_valueEth`.
    function _amountForEth(address token, address currency, uint256 ethAmount) private view returns (uint256) {
        if (currency == token) {
            uint256 oneTokenEth = _tokenValueEth(token, 1 ether);
            return oneTokenEth == 0 ? 0 : FullMath.mulDiv(ethAmount, 1 ether, oneTokenEth);
        }
        try pricer.priceEthAmountInQuote(currency, ethAmount) returns (uint256 q) {
            return q;
        } catch {
            return 0;
        }
    }

    function _requireLaunch(address token) private view {
        if (_configs[token].owner == address(0)) revert UnknownLaunch(token);
    }
}
