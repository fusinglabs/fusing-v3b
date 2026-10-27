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
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Hop, HopKind} from "./libraries/Hop.sol";
import {FusingQuoteAssetProbe} from "./libraries/FusingQuoteAssetProbe.sol";
import {IPythMinimal, IAggregatorV3Minimal} from "./interfaces/IOracles.sol";
import {FusingOraclePrice} from "./libraries/FusingOraclePrice.sol";
import {FusingPoolDepth} from "./libraries/FusingPoolDepth.sol";

/// @dev The only part of the Uniswap V3 pool interface the pricer reads.
interface IUniswapV3PoolMinimal {
    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint8 feeProtocol,
            bool unlocked
        );
}

interface IUniswapV3FactoryMinimal {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address pool);
}

/// @dev The only part of the Uniswap V2 factory the pricer reads.
interface IUniswapV2FactoryMinimal {
    function getPair(address tokenA, address tokenB) external view returns (address pair);
}

/// @dev The only part of a Uniswap V2 pair the pricer reads. `getReserves`
/// returns the pair's accounted reserves in token0, token1 order.
interface IUniswapV2PairMinimal {
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
}

/**
 * @dev Supplies Uniswap V4 pool keys for tokens that came out of a launch
 * factory. The pricer queries every registered registry for `token` and
 * treats any pool it gets back exactly like a hand-registered one, so a
 * token whose only market is its factory's V4 pool can serve as a quote
 * with no setup by anyone. One adapter per factory; the implementation
 * lives in FusingReferenceRegistries.sol.
 */
interface IQuoteReferenceRegistry {
    function referencePool(address token) external view returns (bool found, PoolKey memory key);
}

/**
 * @title FusingQuotePricer
 * @notice Translates the ETH-denominated terms of a launch config (the
 * opening market cap) into the native units of an ERC-20 quote asset, at
 * the current price along a chain of pools leading from that asset to ETH.
 *
 * A route is an ordered list of hops, each one a Uniswap V3 or V4 pool,
 * beginning at the asset and ending at ETH (native or WETH). Two routes are
 * discovered with no setup at all: a direct pool against ETH, and a two-hop
 * path through the dollar anchor, each leg being the deepest pool for its
 * pair. Anything longer must be registered by whoever wants to launch
 * against the asset: the interface scans the chain's pools for a route, and
 * `registerPath` validates and stores it. Once stored, a route serves every
 * subsequent launch in that asset. A route may have up to `MAX_HOPS` hops,
 * enough for an asset paired to a token paired to a stock paired to the
 * dollar anchor paired to ETH.
 *
 * Every hop has to be deep. Walking in from the ETH end, a hop qualifies
 * when its pool holds at least `minReferenceEth` worth of the side nearer
 * ETH, with that floor converted along the hops already walked. On V3 that
 * is the balance the pool physically holds. On V4 the PoolManager keeps
 * every pool's tokens in a single balance, so there is nothing to read
 * directly; `_v4Depth` explains what is measured instead and what faking it
 * would cost. A route qualifies when all of its hops do, and its strength is
 * its weakest hop's depth divided by that hop's floor. When a registered
 * route and an automatic one both qualify, the stronger of the two prices
 * the asset.
 *
 * V4 hops must carry a hook from the allow-list (the empty hook is allowed
 * from deployment). V4 pools for the automatic routes come from hand
 * registration and from factory registries; V3 pools come from the V3
 * factory at the standard fee tiers.
 *
 * The price used is spot. There is no averaging and no waiting period: an
 * asset becomes usable as a quote the instant a deep enough route exists.
 * The cost of that decision is spelled out in the docs: a launcher can shove
 * a route's price inside their own transaction and pull it back afterwards,
 * paying nothing but the pools' swap fees, and thereby open their own token
 * at a market cap other than the one advertised. That distorts nothing
 * beyond that single launch, and the interface displays the live market cap
 * regardless.
 *
 * What the depth floor does about that, stated precisely: it neither sets
 * a minimum size for the shove nor
 * prevents one. It sets a minimum on the capital that has to sit in a pool
 * before the pool is considered at all, and therefore a minimum on what a
 * shove of a given size pays in pool fees and surrenders to arbitrage. That
 * capital may be borrowed for the span of one transaction, on a V3 hop and a
 * V4 hop alike, so the floor is a cost rather than a barrier. A depth
 * measure that can be satisfied with a hundredth of the capital it claims is
 * an altogether different thing, and that is what `_v4Depth` corrects.
 */
contract FusingQuotePricer is Ownable2Step, ReentrancyGuard {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    error QuoteAssetNotPriceable(address quoteToken);
    error ZeroAddress();
    error ConversionOverflow();
    error HookNotAllowed(address hook);
    error NotAnAnchorPool();
    error PoolNotInitialized();
    error PoolAlreadyRegistered(bytes32 poolId);
    error PoolNotRegistered(bytes32 poolId);
    error TooManyPools(address token);
    error TooManyRegistries();
    error RegistryAlreadyAdded(address registry);
    error UnknownRegistry(address registry);
    error NotAContract(address registry);
    /// @dev The route is badly formed; `hopIndex` points at the offending hop.
    error InvalidPath(PathFault fault, uint256 hopIndex);
    /// @dev The route is well formed but at least one hop sits below its depth floor.
    error PathNotQualifying(uint256 hopIndex);
    /// @dev A stored route already qualifies and is at least as strong as the one offered.
    error PathNotStronger(uint256 storedStrengthX18, uint256 offeredStrengthX18);
    error NoPathStored(address token);
    /// @dev The probe on offer is too small to demonstrate anything.
    error ProbeTooSmall(address asset, uint256 required, uint256 offered);
    /// @dev `setProbeEth` was given zero or something above the depth floor.
    error ProbeEthOutOfRange(uint256 probeEth);
    /// @dev An oracle read came back unusable: not set, stale, or non-positive.
    error OracleUnavailable(address asset);
    /// @dev `setProvenCodehash` was given the empty codehash.
    error EmptyCodehash();

    event MinReferenceDepthUpdated(uint256 minReferenceEth);
    event ProbeEthUpdated(uint256 probeEth);
    event CodehashProven(bytes32 indexed codehash, bool proven);
    event OracleSet(address indexed asset, bytes32 pythId, address feed);
    event OracleSourcesSet(address pyth, address ethUsdFeed, uint256 maxAge);
    event V4HookAllowed(address indexed hook, bool allowed);
    event V4PoolRegistered(bytes32 indexed poolId, address indexed token, address indexed anchor, PoolKey key);
    event V4PoolUnregistered(bytes32 indexed poolId, address indexed token);
    event ProbeAmountOverridden(address indexed asset, uint256 amount);
    event RegistryAdded(address indexed registry);
    event RegistryRemoved(address indexed registry);
    event PathRegistered(address indexed token, address indexed by, Hop[] hops, uint256 strengthX18);
    event PathCleared(address indexed token);
    event ExactTransfersProven(address indexed asset, address indexed by, uint256 amount);

    struct V4Pool {
        PoolKey key;
        /// @dev The asset this pool prices, meaning the side that is not the anchor.
        address token;
        /// @dev One of native ETH (address zero), WETH, or the dollar anchor.
        address anchor;
        bool registered;
    }

    /// @notice The ways a route can be malformed.
    enum PathFault {
        None,
        Empty,
        TooLong,
        /// @dev The hop has no side matching the asset the previous hop handed over.
        Disconnected,
        /// @dev The same asset shows up twice along the route.
        Revisits,
        /// @dev A V3 hop refers to native ETH, but V3 pools only ever hold WETH.
        NativeOnV3,
        /// @dev The V3 factory knows no pool for this hop's pair at this fee.
        NoV3Pool,
        /// @dev A V3 hop carries a non-zero tickSpacing or hooks field.
        V3KeyNotBare,
        HookNotAllowed,
        NotInitialized,
        /// @dev The final hop ends somewhere other than ETH or WETH.
        NotToEth,
        /// @dev ETH or WETH turns up before the final hop.
        EthMidRoute
    }

    /// @notice A single hop of a route as the pricer measured it, for interfaces to display.
    struct HopReport {
        Hop hop;
        /// @dev The asset that enters the hop, travelling from the quote toward ETH.
        address tokenIn;
        /// @dev The asset that leaves the hop, one step closer to ETH.
        address tokenOut;
        /// @dev The amount of `tokenOut` the pool holds (V3) or has in range (V4).
        uint256 depth;
        /// @dev The bar `depth` must clear: `minReferenceEth` expressed in `tokenOut` units.
        uint256 floor;
        bool qualifies;
    }

    /// @notice A whole route together with its measurements, for interfaces to display.
    struct PathReport {
        HopReport[] hops;
        /// @dev Every hop is well formed and meets or exceeds its floor.
        bool qualifies;
        /// @dev The route was stored via `registerPath` instead of found by the automatic search.
        bool registered;
        /// @dev The weakest hop's depth divided by its floor, scaled up by 1e18.
        uint256 strengthX18;
        PathFault fault;
        uint256 faultHop;
    }

    /// @dev All four Uniswap V3 fee tiers enabled on Ethereum mainnet, each
    /// scanned when searching for an automatic route. The 0.01% tier counts
    /// for more than its size suggests: correlated pairs park nearly all of
    /// their depth there, and omitting it left wstETH and USDe unpriceable
    /// even though their 0.01% pools held 1,032 WETH and 1.1M USDC.
    uint24 private constant FEE_LOWEST = 100;
    uint24 private constant FEE_LOW = 500;
    uint24 private constant FEE_MEDIUM = 3_000;
    uint24 private constant FEE_HIGH = 10_000;

    uint8 public constant MAX_HOPS = 4;
    uint8 public constant MAX_V4_POOLS_PER_TOKEN = 8;
    uint8 public constant MAX_REGISTRIES = 8;

    /**
     * @notice The width of the band over which a V4 hop's depth is measured,
     * in basis points of the square root of the price. 500 bps on the square
     * root works out to roughly 10.25% of the price itself. See FusingPoolDepth.
     */
    uint256 public constant DEPTH_SQRT_WINDOW_BPS = FusingPoolDepth.DEPTH_SQRT_WINDOW_BPS;
    uint256 private constant BASIS_POINTS = 10_000;
    IUniswapV3FactoryMinimal public immutable v3Factory;
    IPoolManager public immutable poolManager;
    address public immutable weth;
    address public immutable usdAnchor;

    /// @notice The Uniswap V2 factory, or zero to leave V2 out of routing.
    /// @dev Settable rather than immutable for one reason: if V2 routing ever
    /// has to be switched off, that has to be possible in one transaction
    /// without redeploying the pricer and re-pointing everything at it.
    /// Starts at zero, so a pricer behaves exactly as before until an owner
    /// turns V2 on deliberately.
    IUniswapV2FactoryMinimal public v2Factory;

    event V2FactorySet(address factory);

    /// @notice The ETH value of the side nearer ETH that every hop of a route
    /// must hold (V3) or keep in range (V4).
    uint256 public minReferenceEth = 5 ether;

    /**
     * @notice The ETH value of the round trip `proveExactTransfers` asks
     * for, converted into the asset's own units at its route price. A
     * little over a dollar: enough that a percentage transfer fee cannot
     * round to nothing, and since every wei comes back the only real cost
     * is gas. Independent of `minReferenceEth` on purpose: raising the
     * depth floor must never make proving an asset expensive.
     */
    uint256 public probeEth = 0.0006 ether;

    /// @notice The hooks a V4 hop is permitted to carry. Address zero, meaning
    /// no hook, is permitted from deployment onward.
    mapping(address hook => bool) public allowedV4Hooks;
    mapping(bytes32 poolId => V4Pool) private _v4Pools;
    mapping(address token => bytes32[]) private _v4PoolsOf;
    /// @notice All V4 pools registered by hand.
    bytes32[] public allV4Pools;
    /// @notice Factory registries queried for V4 pool keys.
    IQuoteReferenceRegistry[] public registries;
    /// @dev Routes saved via `registerPath`, ordered from the asset to ETH.
    mapping(address token => Hop[]) private _paths;
    /**
     * @notice Assets that have demonstrated exact transfers through
     * `proveExactTransfers`. The launch factory demands this of every ERC-20
     * quote, because the route walk is blind to transfer fees: the depth it
     * measures is always on the side nearer ETH, so a fee-taking or
     * share-rounding token clears the floor just as a well behaved one would
     * and only fails once the pool is live and nothing can be undone.
     */
    mapping(address asset => bool) private _exactTransferProven;
    /**
     * @notice Contract classes proven as a whole. Every token an issuer
     * deploys behind one beacon shares one runtime codehash, so proving one
     * of them the ordinary way and marking its codehash here proves the
     * class: the transfer code is literally the same code. Set by the owner
     * after a real proof; an issuer upgrade changes the hash and the class
     * has to be proven again.
     */
    mapping(bytes32 codehash => bool proven) public provenCodehash;

    /// @notice Whether `asset` has proven exact transfers, itself or through its contract class.
    function exactTransferProven(address asset) public view returns (bool) {
        if (_exactTransferProven[asset]) return true;
        bytes32 h = asset.codehash;
        return h != bytes32(0) && provenCodehash[h];
    }

    /**
     * @notice What a round trip through `asset` actually costs, in basis
     * points, once `assessTransfers` has measured it. Zero for an asset that
     * transfers exactly, and zero for one never assessed, so always read
     * `transfersAssessed` alongside it.
     */
    mapping(address asset => uint16) public transferTaxBps;

    /// @notice Whether `asset` has been measured by `assessTransfers`.
    mapping(address asset => bool) public transfersAssessed;

    /**
     * @notice Whether an `owner()` or `getOwner()` call on `asset` answered
     * with a non-zero address.
     *
     * Named for exactly what it checks, because an earlier name implied more.
     * TRUMP on mainnet taxes every transfer 1% and this reads FALSE, since it
     * exposes no owner function at all. So:
     *
     *   true  means an owner was found, and that owner may be able to change
     *         how the token behaves after a launch is paired against it.
     *   false means NO OWNER FUNCTION ANSWERED. It does not mean the token is
     *         safe, immutable, or unable to turn hostile. A token can hold
     *         the same power behind any name, or behind a proxy.
     *
     * The proxy check cannot live here: a contract cannot read another
     * contract's storage, so the EIP-1967 slot is unreachable on chain. Any
     * interface presenting this to a creator must do that check itself with
     * `eth_getStorageAt` and must not present a false as a clearance.
     */
    mapping(address asset => bool) public quoteOwnerFound;

    event TransfersAssessed(address indexed asset, address indexed by, uint256 taxBps, bool ownerFound);
    /**
     * @notice A probe size the owner has fixed by hand for an asset, in the
     * asset's own units, taking precedence over the route-derived figure.
     * This is what keeps the factories' curated `setPairTokenEconomics` path
     * workable: an asset priced by hand has no qualifying route, so the
     * pricer has no way to say what a probe of it is worth, and with no
     * figure `proveExactTransfers` could never run and nobody could ever
     * launch against the asset. Zero means there is no override.
     */
    mapping(address asset => uint256) public probeAmountOverride;

    /**
     * @notice Assets priced from an oracle instead of a pool route: the
     * tokenised stocks. Most of them have no ETH pool deep enough to walk,
     * but every one has a published USD price. `pythId` is the Pyth feed
     * of the underlying; ETH/USD comes from Chainlink. A quote in the asset
     * is then `ethAmount * ETH/USD / STOCK/USD`, in the asset's decimals.
     */
    struct Oracle {
        /// @dev A Pyth feed id, or zero when the asset is priced by `feed`.
        bytes32 pythId;
        /// @dev A Chainlink-style aggregator quoting the asset in USD, used when `pythId` is zero.
        IAggregatorV3Minimal feed;
        uint8 decimals;
        bool set;
    }

    mapping(address asset => Oracle) public oracleOf;
    IPythMinimal public pyth;
    IAggregatorV3Minimal public ethUsdFeed;
    /// @notice How old an oracle price may be and still price a launch. Pull feeds are refreshed by the launch itself.
    uint256 public maxOracleAge = 15 minutes;
    /// @notice Outside US market hours the last close prices a stock, up to this old: a long weekend.
    uint256 public closedOracleAge = 4 days;

    /// @notice The key that attests prices for assets without an on-chain feed. The owner can replace it; zero turns the source off.
    address public priceSigner;
    /// @notice The latest attested price per asset. An asset with one is oracle-priced from then on.
    mapping(address asset => FusingOraclePrice.SignedPrice) public signedPriceOf;

    event PriceSignerSet(address signer);

    constructor(
        address initialOwner,
        IUniswapV3FactoryMinimal v3Factory_,
        address weth_,
        address usdAnchor_,
        IPoolManager poolManager_
    ) Ownable(initialOwner) {
        if (
            address(v3Factory_) == address(0) || weth_ == address(0) || usdAnchor_ == address(0)
                || address(poolManager_) == address(0)
        ) revert ZeroAddress();
        v3Factory = v3Factory_;
        weth = weth_;
        usdAnchor = usdAnchor_;
        poolManager = poolManager_;
        allowedV4Hooks[address(0)] = true;
        emit V4HookAllowed(address(0), true);
    }

    // ---------------------------------------------------------------------
    // Owner settings
    // ---------------------------------------------------------------------

    /// @notice Points the pricer at a Uniswap V2 factory, or zero to stop
    /// routing through V2 at all. Routes already registered through a V2 hop
    /// stop qualifying the moment this is cleared, which is the intent.
    function setV2Factory(IUniswapV2FactoryMinimal factory) external onlyOwner {
        v2Factory = factory;
        emit V2FactorySet(address(factory));
    }

    /// @notice Sets the ETH-denominated depth every hop of a route must carry.
    function setMinReferenceEth(uint256 minEth) external onlyOwner {
        minReferenceEth = minEth;
        emit MinReferenceDepthUpdated(minEth);
    }

    /// @notice Sets the ETH value of the exact-transfer probe. Must be above zero and no more than the depth floor.
    function setProbeEth(uint256 newProbeEth) external onlyOwner {
        if (newProbeEth == 0 || newProbeEth > minReferenceEth) revert ProbeEthOutOfRange(newProbeEth);
        probeEth = newProbeEth;
        emit ProbeEthUpdated(newProbeEth);
    }

    /**
     * @notice Permits or bans a hook on V4 hops. Banning one leaves its
     * pools and routes registered but takes them out of pricing, and that
     * applies to pools handed back by a registry as well.
     */
    function setV4HookAllowed(address hook, bool allowed) external onlyOwner {
        allowedV4Hooks[hook] = allowed;
        emit V4HookAllowed(hook, allowed);
    }

    /// @notice Registers a factory registry.
    function addRegistry(IQuoteReferenceRegistry registry) external onlyOwner {
        if (address(registry) == address(0)) revert ZeroAddress();
        if (address(registry).code.length == 0) revert NotAContract(address(registry));
        if (registries.length >= MAX_REGISTRIES) revert TooManyRegistries();
        for (uint256 i = 0; i < registries.length; ++i) {
            if (registries[i] == registry) revert RegistryAlreadyAdded(address(registry));
        }
        registries.push(registry);
        emit RegistryAdded(address(registry));
    }

    /// @notice Drops a factory registry.
    function removeRegistry(IQuoteReferenceRegistry registry) external onlyOwner {
        uint256 n = registries.length;
        for (uint256 i = 0; i < n; ++i) {
            if (registries[i] != registry) continue;
            registries[i] = registries[n - 1];
            registries.pop();
            emit RegistryRemoved(address(registry));
            return;
        }
        revert UnknownRegistry(address(registry));
    }

    function registriesLength() external view returns (uint256) {
        return registries.length;
    }

    /**
     * @notice Fixes the probe size `proveExactTransfers` requires for
     * `asset`, in the asset's own units; zero removes it and defers to the
     * route price again. Use it alongside the factory's
     * `setPairTokenEconomics` when curating an asset the pricer cannot value
     * by itself, and size it the way the automatic figure is sized: about
     * `probeEth` worth, big enough that a percentage transfer fee cannot
     * round down to nothing. Every wei of a probe
     * returns to whoever funded it, so an oversized figure costs extra gas
     * and nothing more.
     */
    function setProbeAmount(address asset, uint256 amount) external onlyOwner {
        if (asset == address(0)) revert ZeroAddress();
        probeAmountOverride[asset] = amount;
        emit ProbeAmountOverridden(asset, amount);
    }

    /// @notice Marks a contract class as proven (or not). Do it only after proving one member the ordinary way.
    function setProvenCodehash(bytes32 codehash, bool proven) external onlyOwner {
        if (codehash == bytes32(0)) revert EmptyCodehash();
        provenCodehash[codehash] = proven;
        emit CodehashProven(codehash, proven);
    }

    /// @notice Wires the oracle sources: Pyth for the assets, Chainlink for ETH/USD, and the freshness bound.
    function setOracleSources(IPythMinimal pyth_, IAggregatorV3Minimal ethUsdFeed_, uint256 maxAge) external onlyOwner {
        if (address(pyth_) == address(0) || address(ethUsdFeed_) == address(0) || maxAge == 0) revert ZeroAddress();
        pyth = pyth_;
        ethUsdFeed = ethUsdFeed_;
        maxOracleAge = maxAge;
        emit OracleSourcesSet(address(pyth_), address(ethUsdFeed_), maxAge);
    }

    /**
     * @notice Prices `asset` from an oracle from now on: a Pyth feed id, or
     * when that is zero an aggregator quoting the asset in USD (Chainlink,
     * or any push feed with the same interface: the second source for the
     * tickers Pyth does not carry). Both zero removes the oracle and the
     * route search applies again.
     */
    function setOracle(address asset, bytes32 pythId, IAggregatorV3Minimal feed) external onlyOwner {
        if (asset == address(0)) revert ZeroAddress();
        if (pythId == bytes32(0) && address(feed) == address(0)) {
            delete oracleOf[asset];
        } else {
            if (asset.code.length == 0) revert NotAContract(asset);
            oracleOf[asset] = Oracle({pythId: pythId, feed: feed, decimals: IERC20Metadata(asset).decimals(), set: true});
        }
        emit OracleSet(asset, pythId, address(feed));
    }

    /// @notice Posts signed Pyth prices ahead of a launch or a probe; the fee is whatever Pyth quotes, refunds nothing.
    function updateOraclePrices(bytes[] calldata updateData) external payable {
        pyth.updatePriceFeeds{value: msg.value}(updateData);
    }

    /// @dev Priced by an oracle rather than a pool route: registered with a feed, or ever given a signed price.
    function _oracled(address asset) private view returns (bool) {
        return oracleOf[asset].set || signedPriceOf[asset].takenAt != 0;
    }

    /// @dev `ethAmount` in `asset` units at oracle prices (FusingOraclePrice has the freshness rules). Reverts OracleUnavailable on anything stale or missing.
    function _oraclePrice(address asset, uint256 ethAmount) private view returns (uint256) {
        Oracle memory o = oracleOf[asset];
        FusingOraclePrice.SignedPrice memory sp = signedPriceOf[asset];
        (bool ok, uint256 amount) = FusingOraclePrice.quote(
            pyth, ethUsdFeed, o.pythId, o.feed, asset, o.decimals, ethAmount, maxOracleAge, closedOracleAge, sp.priceUsd8, sp.takenAt
        );
        if (!ok) revert OracleUnavailable(asset);
        return amount;
    }

    /// @notice Posts prices the fusi.ng price signer attested: the source for the tickers no on-chain feed carries (rules in FusingOraclePrice.post).
    function postSignedPrices(bytes[] calldata prices) external {
        FusingOraclePrice.post(signedPriceOf, prices, priceSigner);
    }

    function setPriceSigner(address signer) external onlyOwner {
        priceSigner = signer;
        emit PriceSignerSet(signer);
    }

    /// @notice How old a stock's last close may be while its market is shut. Zero turns the rule off: fresh prices only, at all hours.
    function setClosedOracleAge(uint256 age) external onlyOwner {
        closedOracleAge = age;
    }

    /// @notice Deletes a stored route. The automatic search keeps working as before.
    function clearPath(address token) external onlyOwner {
        if (_paths[token].length == 0) revert NoPathStored(token);
        delete _paths[token];
        emit PathCleared(token);
    }

    // ---------------------------------------------------------------------
    // Hand-registered V4 pools feeding the automatic search
    // ---------------------------------------------------------------------

    /**
     * @notice Adds an initialized V4 pool to the automatic search. One side
     * has to be an anchor: native ETH, WETH or the dollar anchor. A pool of
     * the dollar anchor against ETH is recorded as pricing the dollar anchor
     * in ETH, which is the second leg of the two-hop route. Tokens known to
     * a registry have no need of this, and neither does anything reached
     * through `registerPath`.
     */
    function registerV4Pool(PoolKey calldata key) external returns (bytes32 poolId) {
        if (!allowedV4Hooks[address(key.hooks)]) revert HookNotAllowed(address(key.hooks));
        address c0 = Currency.unwrap(key.currency0);
        address c1 = Currency.unwrap(key.currency1);
        (address anchor, address token, bool ok) = _splitAnchor(c0, c1);
        if (!ok) revert NotAnAnchorPool();

        poolId = PoolId.unwrap(key.toId());
        if (_v4Pools[poolId].registered) revert PoolAlreadyRegistered(poolId);
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(PoolId.wrap(poolId));
        if (sqrtPriceX96 == 0) revert PoolNotInitialized();
        if (_v4PoolsOf[token].length >= MAX_V4_POOLS_PER_TOKEN) revert TooManyPools(token);

        _v4Pools[poolId] = V4Pool({key: key, token: token, anchor: anchor, registered: true});
        _v4PoolsOf[token].push(poolId);
        allV4Pools.push(poolId);
        emit V4PoolRegistered(poolId, token, anchor, key);
    }

    /**
     * @notice Removes a hand-registered V4 pool and frees its slot.
     * Registration is open to all and capped at `MAX_V4_POOLS_PER_TOKEN`, so
     * without this a stranger could stuff a token's slots with initialized
     * pools holding a wei apiece and permanently lock it out of its genuine
     * V4 reference. Owner only, because removal can only ever narrow what
     * the pricer considers: any pool the owner removes can be registered
     * again by anyone.
     */
    function unregisterV4Pool(bytes32 poolId) external onlyOwner {
        V4Pool storage p = _v4Pools[poolId];
        if (!p.registered) revert PoolNotRegistered(poolId);
        address token = p.token;

        bytes32[] storage ids = _v4PoolsOf[token];
        for (uint256 i = 0; i < ids.length; ++i) {
            if (ids[i] != poolId) continue;
            ids[i] = ids[ids.length - 1];
            ids.pop();
            break;
        }
        for (uint256 i = 0; i < allV4Pools.length; ++i) {
            if (allV4Pools[i] != poolId) continue;
            allV4Pools[i] = allV4Pools[allV4Pools.length - 1];
            allV4Pools.pop();
            break;
        }
        delete _v4Pools[poolId];
        emit V4PoolUnregistered(poolId, token);
    }

    function allV4PoolsLength() external view returns (uint256) {
        return allV4Pools.length;
    }

    function v4PoolsOf(address token) external view returns (bytes32[] memory) {
        return _v4PoolsOf[token];
    }

    function v4PoolIdFor(PoolKey calldata key) external pure returns (bytes32) {
        return PoolId.unwrap(key.toId());
    }

    // ---------------------------------------------------------------------
    // Stored routes
    // ---------------------------------------------------------------------

    /**
     * @notice Saves a route from `token` to ETH that anyone may then price
     * against. The route has to be well formed with every hop at or above
     * its floor at the time of the call. It only displaces an existing
     * stored route when that one has stopped qualifying or this one is
     * stronger, so a route can never be traded down for a worse one. Open
     * to all callers: the checks are identical whoever calls.
     */
    function registerPath(address token, Hop[] calldata hops) external returns (uint256 strengthX18) {
        if (token == address(0) || token == weth) revert ZeroAddress();
        Hop[] memory offered = hops;
        (PathReport memory rep,) = _walk(token, offered, 0);
        if (rep.fault != PathFault.None) revert InvalidPath(rep.fault, rep.faultHop);
        if (!rep.qualifies) revert PathNotQualifying(_firstFailing(rep));

        Hop[] memory current = _paths[token];
        if (current.length != 0) {
            (PathReport memory cur,) = _walk(token, current, 0);
            if (cur.qualifies && cur.strengthX18 >= rep.strengthX18) {
                revert PathNotStronger(cur.strengthX18, rep.strengthX18);
            }
            delete _paths[token];
        }
        for (uint256 i = 0; i < offered.length; ++i) {
            _paths[token].push(offered[i]);
        }
        emit PathRegistered(token, msg.sender, offered, rep.strengthX18);
        return rep.strengthX18;
    }

    /// @notice The stored route for `token`, or an empty array when there is none.
    function pathOf(address token) external view returns (Hop[] memory) {
        return _paths[token];
    }

    /**
     * @notice Measures a route without saving it. A malformed route never
     * causes a revert here: the report states what is wrong and at which hop.
     */
    function evaluatePath(address token, Hop[] calldata hops) external view returns (PathReport memory rep) {
        (rep,) = _walk(token, hops, 0);
    }

    // ---------------------------------------------------------------------
    // Exact-transfer proofs
    // ---------------------------------------------------------------------

    /**
     * @notice The amount of `asset` that `proveExactTransfers` insists on:
     * the owner's override where one exists, otherwise `probeEth` converted
     * into the asset's own units at its route price.
     *
     * Reverts when the asset has neither an override nor a qualifying route,
     * and reverts with `ProbeTooSmall(asset, 0, 0)` when the route price
     * rounds the probe down to zero, as a very expensive asset with few
     * decimals can. A zero probe proves nothing whatsoever: both legs of a
     * zero transfer arrive exactly no matter what the token does, so without
     * this check the gate would wave through an asset it had never actually
     * moved.
     */
    function probeAmountRequired(address asset) public view returns (uint256 required) {
        required = probeAmountOverride[asset];
        if (required != 0) return required;
        required = priceEthAmountInQuote(asset, probeEth);
        if (required == 0) revert ProbeTooSmall(asset, 0, 0);
    }

    /**
     * @notice Establishes once and for all that `asset` moves exact amounts,
     * by pulling `amount` of it out of the caller and sending it straight
     * back. Open to anyone and paid for by the caller, so a creator who later
     * launches against this asset still needs to hold nothing but ETH.
     * Reverts unless both legs of the round trip land to the wei.
     *
     * `amount` may not be below `probeAmountRequired(asset)`, which rules out
     * a proof at a size where a percentage fee would round down to nothing.
     * Anything above that is accepted and handed back in full.
     *
     * `nonReentrant` because the probe cedes control to the asset twice, and
     * the asset is by definition one that nobody has vouched for yet.
     */
    function proveExactTransfers(address asset, uint256 amount) external nonReentrant {
        if (asset == address(0)) revert ZeroAddress();
        uint256 required = probeAmountRequired(asset);
        if (amount < required) revert ProbeTooSmall(asset, required, amount);
        FusingQuoteAssetProbe.requireExactTransfers(asset, msg.sender, amount);
        _exactTransferProven[asset] = true;
        transfersAssessed[asset] = true;
        transferTaxBps[asset] = 0;
        quoteOwnerFound[asset] = _ownerFunctionAnswers(asset);
        emit ExactTransfersProven(asset, msg.sender, amount);
        emit TransfersAssessed(asset, msg.sender, 0, quoteOwnerFound[asset]);
    }

    /**
     * @notice Measures what a round trip through `asset` costs instead of
     * demanding it cost nothing, so a fee-on-transfer token can be used as a
     * quote asset by a creator who accepts the cost.
     *
     * Same shape as `proveExactTransfers`: open to anyone, funded by the
     * caller, and everything that survives the round trip goes back. An
     * asset measured at zero tax is also marked exact-transfer proven, so
     * this is a strict superset of the old path and a caller never has to
     * choose between them.
     *
     * `nonReentrant` for the same reason as the strict probe: control is
     * ceded to an asset nobody has vouched for, twice.
     */
    function assessTransfers(address asset, uint256 amount) external nonReentrant returns (uint256 taxBps) {
        if (asset == address(0)) revert ZeroAddress();
        uint256 required = probeAmountRequired(asset);
        if (amount < required) revert ProbeTooSmall(asset, required, amount);

        taxBps = FusingQuoteAssetProbe.measureTransferTax(asset, msg.sender, amount);
        if (taxBps > type(uint16).max) taxBps = type(uint16).max;

        transfersAssessed[asset] = true;
        transferTaxBps[asset] = uint16(taxBps);
        quoteOwnerFound[asset] = _ownerFunctionAnswers(asset);
        if (taxBps == 0) _exactTransferProven[asset] = true;

        emit TransfersAssessed(asset, msg.sender, taxBps, quoteOwnerFound[asset]);
    }

    /**
     * @dev Best-effort check for somebody holding a lever over the token:
     * an `owner()` or `getOwner()` that answers with a non-zero address.
     * Staticcalls throughout, so a hostile or absent implementation cannot
     * revert the assessment.
     *
     * What this deliberately does NOT do is detect a proxy. A contract
     * cannot read another contract's storage, so the EIP-1967 slot is
     * unreachable from here; that check belongs in the interface, which can
     * read it with `eth_getStorageAt`. A false from this function therefore
     * means "no owner function answered", never "nobody can change this
     * token". Treat it as one signal, not a clearance.
     */
    function _ownerFunctionAnswers(address asset) private view returns (bool) {
        (bool ok, bytes memory data) = asset.staticcall(abi.encodeWithSignature("owner()"));
        if (ok && data.length == 32 && abi.decode(data, (address)) != address(0)) return true;

        (ok, data) = asset.staticcall(abi.encodeWithSignature("getOwner()"));
        if (ok && data.length == 32 && abi.decode(data, (address)) != address(0)) return true;

        return false;
    }

    // ---------------------------------------------------------------------
    // Price queries
    // ---------------------------------------------------------------------

    /**
     * @notice Expresses a launch's ETH-denominated phantom reserve in
     * `quoteToken` units at the route price. Reverts if the asset lacks a
     * qualifying route or the result rounds down to zero.
     */
    function quoteEconomics(address quoteToken, uint256 phantomQuoteEth) external view returns (uint256 phantomQuote) {
        phantomQuote = priceEthAmountInQuote(quoteToken, phantomQuoteEth);
        if (phantomQuote == 0) revert QuoteAssetNotPriceable(quoteToken);
    }

    /**
     * @notice The quantity of `quoteToken` worth `ethAmount` of ETH along
     * the asset's route. WETH counts as ETH at one-to-one.
     */
    function priceEthAmountInQuote(address quoteToken, uint256 ethAmount) public view returns (uint256) {
        if (quoteToken == weth) return ethAmount;
        if (_oracled(quoteToken)) return _oraclePrice(quoteToken, ethAmount);
        (, PathReport memory rep, uint256 amount) = _route(quoteToken, ethAmount);
        if (!rep.qualifies) revert QuoteAssetNotPriceable(quoteToken);
        return amount;
    }

    /**
     * @notice Whether `quoteToken` has a qualifying route right now, so a
     * frontend can check before offering it in the create flow.
     */
    function isPriceable(address quoteToken) external view returns (bool) {
        if (quoteToken == weth) return true;
        if (_oracled(quoteToken)) {
            try this.priceEthAmountInQuote(quoteToken, 1 ether) returns (uint256 got) {
                return got > 0;
            } catch {
                return false;
            }
        }
        (, PathReport memory rep,) = _route(quoteToken, 0);
        return rep.qualifies;
    }

    /**
     * @notice The route pricing `quoteToken`, listed in trade order from the
     * asset to ETH, plus whether it qualifies. If nothing qualifies, the
     * nearest miss is returned regardless so a frontend can still trade
     * along it; empty when no pool is known at all.
     */
    function route(address quoteToken) external view returns (Hop[] memory hops, bool qualifies) {
        if (quoteToken == weth) return (hops, true);
        // An oracle-priced asset has no route to walk: empty hops, priced all the same.
        if (_oracled(quoteToken)) return (hops, true);
        PathReport memory rep;
        (hops, rep,) = _route(quoteToken, 0);
        qualifies = rep.qualifies;
    }

    /**
     * @notice The route pricing `quoteToken`, with the depth and floor of
     * every hop, so an interface can explain what is lacking. Chosen the
     * same way `route` chooses.
     */
    function describe(address quoteToken) external view returns (PathReport memory rep) {
        if (quoteToken == weth || _oracled(quoteToken)) {
            rep.qualifies = true;
            rep.strengthX18 = type(uint256).max;
            return rep;
        }
        (, rep,) = _route(quoteToken, 0);
    }

    // ---------------------------------------------------------------------
    // Choosing a route
    // ---------------------------------------------------------------------

    /**
     * @dev Chooses between the stored route and the automatic one. A
     * qualifying route always beats a failing one, and of two qualifying
     * routes the stronger wins. When neither qualifies the nearer miss is
     * reported so the interface has something to explain. `amount` is
     * `ethAmount` converted along whichever route was chosen.
     */
    function _route(address token, uint256 ethAmount)
        private
        view
        returns (Hop[] memory hops, PathReport memory rep, uint256 amount)
    {
        (Hop[] memory autoHops, PathReport memory autoRep, uint256 autoAmount) = _auto(token, ethAmount);

        Hop[] memory stored = _paths[token];
        if (stored.length == 0) return (autoHops, autoRep, autoAmount);

        (PathReport memory storedRep, uint256 storedAmount) = _walk(token, stored, ethAmount);
        storedRep.registered = true;
        if (_prefer(storedRep, autoRep)) return (stored, storedRep, storedAmount);
        return (autoHops, autoRep, autoAmount);
    }

    function _prefer(PathReport memory a, PathReport memory b) private pure returns (bool) {
        if (a.qualifies != b.qualifies) return a.qualifies;
        if (b.hops.length == 0) return true;
        if (a.hops.length == 0) return false;
        return a.strengthX18 >= b.strengthX18;
    }

    /**
     * @dev The automatic routes: the deepest direct pool against ETH, or
     * failing that the deepest pool against the dollar anchor followed by
     * the deepest dollar anchor pool against ETH. The direct route wins
     * whenever it qualifies; otherwise whichever of the two comes closer is
     * reported.
     */
    function _auto(address token, uint256 ethAmount)
        private
        view
        returns (Hop[] memory hops, PathReport memory rep, uint256 amount)
    {
        (Hop memory direct, bool hasDirect) = _bestPool(token, true);
        if (hasDirect) {
            hops = new Hop[](1);
            hops[0] = direct;
            (rep, amount) = _walk(token, hops, ethAmount);
            if (rep.qualifies) return (hops, rep, amount);
        }

        (Hop memory viaUsdg, bool hasViaUsdg) = _bestPool(token, false);
        (Hop memory usdAnchorLeg, bool hasUsdAnchorLeg) = _bestPool(usdAnchor, true);
        if (hasViaUsdg && (hasUsdAnchorLeg || !hasDirect)) {
            Hop[] memory two = new Hop[](hasUsdAnchorLeg ? 2 : 1);
            two[0] = viaUsdg;
            if (hasUsdAnchorLeg) two[1] = usdAnchorLeg;
            (PathReport memory twoRep, uint256 twoAmount) = _walk(token, two, ethAmount);
            if (!hasDirect || _prefer(twoRep, rep)) return (two, twoRep, twoAmount);
        }
        // No pool of any kind: return an empty report with the fault set so
        // that `describe` tells the truth about it.
        if (!hasDirect) {
            rep.fault = PathFault.Empty;
        }
    }

    // ---------------------------------------------------------------------
    // Walking a route
    // ---------------------------------------------------------------------

    /**
     * @dev Validates a route's shape and measures each of its hops. First
     * walks from the quote toward ETH to confirm the hops chain together,
     * then walks back from ETH to the quote, converting the floor and
     * `ethAmount` hop by hop at spot. A malformed route produces a report
     * with `fault` set and never reverts; the one exception is an amount
     * that overflows the conversion.
     */
    function _walk(address token, Hop[] memory hops, uint256 ethAmount)
        private
        view
        returns (PathReport memory rep, uint256 amount)
    {
        uint256 n = hops.length;
        if (n == 0) return (_faulted(rep, PathFault.Empty, 0), 0);
        if (n > MAX_HOPS) return (_faulted(rep, PathFault.TooLong, MAX_HOPS), 0);

        address[] memory chain = new address[](n + 1);
        chain[0] = token;
        for (uint256 i = 0; i < n; ++i) {
            (address next, PathFault fault) = _step(hops[i], chain[i]);
            if (fault != PathFault.None) return (_faulted(rep, fault, i), 0);
            for (uint256 j = 0; j <= i; ++j) {
                if (chain[j] == next) return (_faulted(rep, PathFault.Revisits, i), 0);
            }
            if (_isEth(next) && i + 1 < n) return (_faulted(rep, PathFault.EthMidRoute, i), 0);
            chain[i + 1] = next;
        }
        if (!_isEth(chain[n])) return (_faulted(rep, PathFault.NotToEth, n - 1), 0);

        rep.hops = new HopReport[](n);
        rep.qualifies = true;
        rep.strengthX18 = type(uint256).max;
        uint256 floor = minReferenceEth;
        amount = ethAmount;
        for (uint256 k = n; k > 0; --k) {
            uint256 i = k - 1;
            (uint160 sqrtPriceX96, uint256 depth) = _hopState(hops[i], chain[i + 1]);
            HopReport memory h = rep.hops[i];
            h.hop = hops[i];
            h.tokenIn = chain[i];
            h.tokenOut = chain[i + 1];
            h.depth = depth;
            h.floor = floor;
            h.qualifies = depth >= floor;
            if (!h.qualifies) rep.qualifies = false;
            uint256 strength = floor == 0 ? type(uint256).max : FullMath.mulDiv(depth, 1e18, floor);
            if (strength < rep.strengthX18) rep.strengthX18 = strength;

            if (i > 0) floor = _convertOrCap(sqrtPriceX96, floor, chain[i + 1], chain[i]);
            if (amount != 0) {
                if (amount > type(uint128).max) revert ConversionOverflow();
                amount = _quoteAtSqrtPrice(sqrtPriceX96, uint128(amount), chain[i + 1], chain[i]);
            }
        }
    }

    function _faulted(PathReport memory rep, PathFault fault, uint256 hopIndex)
        private
        pure
        returns (PathReport memory)
    {
        rep.fault = fault;
        rep.faultHop = hopIndex;
        rep.qualifies = false;
        return rep;
    }

    function _firstFailing(PathReport memory rep) private pure returns (uint256) {
        for (uint256 i = 0; i < rep.hops.length; ++i) {
            if (!rep.hops[i].qualifies) return i;
        }
        return 0;
    }

    /**
     * @dev Confirms a single hop is well formed and includes `tokenIn`, and
     * returns the asset on its other side. A V3 hop must resolve to a pool at
     * the factory for the stated pair and fee; a V4 hop must carry an
     * allowed hook. In both cases the pool has to be initialized.
     */
    function _step(Hop memory hop, address tokenIn) private view returns (address tokenOut, PathFault fault) {
        address c0 = Currency.unwrap(hop.key.currency0);
        address c1 = Currency.unwrap(hop.key.currency1);
        if (tokenIn == c0) tokenOut = c1;
        else if (tokenIn == c1) tokenOut = c0;
        else return (address(0), PathFault.Disconnected);

        if (hop.kind == HopKind.V2) {
            // V2 has no native ETH side and no key parameters of its own, so
            // the same bare-key rule as V3 applies, with `fee` zero as well.
            if (c0 == address(0)) return (tokenOut, PathFault.NativeOnV3);
            if (hop.key.fee != 0 || hop.key.tickSpacing != 0 || address(hop.key.hooks) != address(0)) {
                return (tokenOut, PathFault.V3KeyNotBare);
            }
            address pair = _v2Pair(hop.key);
            if (pair == address(0)) return (tokenOut, PathFault.NoV3Pool);
            if (FusingPoolDepth.v2SqrtPriceX96(pair) == 0) return (tokenOut, PathFault.NotInitialized);
        } else if (hop.kind == HopKind.V3) {
            if (c0 == address(0)) return (tokenOut, PathFault.NativeOnV3);
            if (hop.key.tickSpacing != 0 || address(hop.key.hooks) != address(0)) {
                return (tokenOut, PathFault.V3KeyNotBare);
            }
            address pool = v3Factory.getPool(c0, c1, hop.key.fee);
            if (pool == address(0)) return (tokenOut, PathFault.NoV3Pool);
            (uint160 sqrtPriceX96,,,,,,) = IUniswapV3PoolMinimal(pool).slot0();
            if (sqrtPriceX96 == 0) return (tokenOut, PathFault.NotInitialized);
        } else {
            if (!allowedV4Hooks[address(hop.key.hooks)]) return (tokenOut, PathFault.HookNotAllowed);
            (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(hop.key.toId());
            if (sqrtPriceX96 == 0) return (tokenOut, PathFault.NotInitialized);
        }
        return (tokenOut, PathFault.None);
    }

    /**
     * @dev A hop's spot price together with how much of `side` it holds: the
     * balance a V3 pool physically holds, or `_v4Depth` for a V4 pool. V3
     * pools are ranked by held balance rather than by their `liquidity()`
     * figure on purpose: that figure is almost free to inflate with a narrow
     * position placed at a tick of the attacker's choosing, whereas tokens
     * sent to a V3 pool beyond its accounted reserves are simply gone, so
     * displacing an honest pool costs more than the entirety of what it holds.
     */
    function _hopState(Hop memory hop, address side) private view returns (uint160 sqrtPriceX96, uint256 depth) {
        if (hop.kind == HopKind.V2) {
            address pair = _v2Pair(hop.key);
            if (pair == address(0)) return (0, 0);
            sqrtPriceX96 = FusingPoolDepth.v2SqrtPriceX96(pair);
            if (sqrtPriceX96 == 0) return (0, 0);
            // Measured the same way as V3: what the pair physically holds,
            // not what it accounts for. Tokens sent to a V2 pair above its
            // reserves are claimable by the next caller of `skim`, so the
            // balance is if anything the more conservative of the two.
            depth = IERC20(side).balanceOf(pair);
        } else if (hop.kind == HopKind.V3) {
            address pool = v3Factory.getPool(
                Currency.unwrap(hop.key.currency0), Currency.unwrap(hop.key.currency1), hop.key.fee
            );
            (sqrtPriceX96,,,,,,) = IUniswapV3PoolMinimal(pool).slot0();
            depth = IERC20(side).balanceOf(pool);
        } else {
            PoolId id = hop.key.toId();
            int24 tick;
            (sqrtPriceX96, tick,,) = poolManager.getSlot0(id);
            uint128 liquidity = poolManager.getLiquidity(id);
            if (sqrtPriceX96 == 0 || liquidity == 0) return (sqrtPriceX96, 0);
            depth = FusingPoolDepth.v4Depth(poolManager, id, hop.key, side, sqrtPriceX96, tick, liquidity);
        }
    }

    // The V4 depth measure and the tick walk behind it live in
    // FusingPoolDepth (an external library, for contract size). What it
    // measures, in one line: the amount of `side` really held in range
    // within a 500 bps sqrt-price band, scaled to V3 balanceOf units and
    // capped at the virtual reserve, so a one-tick position cannot fake
    // the floor. The full reasoning is in that library's source history.

    function _isEth(address token) private view returns (bool) {
        return token == address(0) || token == weth;
    }

    // ---------------------------------------------------------------------
    // Automatic pool discovery
    // ---------------------------------------------------------------------

    /**
     * @dev The deepest pool that pairs `token` with ETH (a V3 WETH pool, or
     * a V4 native or WETH pool) or with the dollar anchor, packaged as a hop.
     */
    function _bestPool(address token, bool ethAnchor) private view returns (Hop memory hop, bool found) {
        address anchor = ethAnchor ? weth : usdAnchor;
        (address v3Pool, uint24 v3Fee, uint256 v3Depth) = _bestV3Pool(token, anchor);
        (PoolKey memory v4Key, uint256 v4Depth, bool v4Found) = _bestV4Pool(token, ethAnchor);
        (address v2Pair, uint256 v2Depth) = _bestV2Pool(token, anchor);

        if (v3Pool == address(0) && !v4Found && v2Pair == address(0)) return (hop, false);

        // Deepest wins, and depth is measured the same way on all three, so
        // the comparison is meaningful across venues. V3 keeps precedence on
        // a tie because its concentrated liquidity moves less for the same
        // held balance, which makes it the better price reference.
        bool v3Wins = v3Pool != address(0) && v3Depth >= v4Depth && v3Depth >= v2Depth;
        bool v4Wins = !v3Wins && v4Found && v4Depth >= v2Depth;

        if (v3Wins) {
            (address c0, address c1) = token < anchor ? (token, anchor) : (anchor, token);
            hop.key = PoolKey({
                currency0: Currency.wrap(c0),
                currency1: Currency.wrap(c1),
                fee: v3Fee,
                tickSpacing: 0,
                hooks: IHooks(address(0))
            });
            hop.kind = HopKind.V3;
        } else if (v4Wins) {
            hop.key = v4Key;
            hop.kind = HopKind.V4;
        } else {
            (address c0, address c1) = token < anchor ? (token, anchor) : (anchor, token);
            hop.key = PoolKey({
                currency0: Currency.wrap(c0),
                currency1: Currency.wrap(c1),
                fee: 0,
                tickSpacing: 0,
                hooks: IHooks(address(0))
            });
            hop.kind = HopKind.V2;
        }
        found = true;
    }

    /// @dev The V2 pair for a hop's key, or zero when V2 routing is off or
    /// the key is not a well formed V2 hop. `fee`, `tickSpacing` and `hooks`
    /// must all be zero: a V2 pair has no such parameters, so a key carrying
    /// them describes a pool that does not exist and must not be honoured.
    function _v2Pair(PoolKey memory key) private view returns (address pair) {
        if (address(v2Factory) == address(0)) return address(0);
        if (key.fee != 0 || key.tickSpacing != 0 || address(key.hooks) != address(0)) return address(0);
        address a = Currency.unwrap(key.currency0);
        address b = Currency.unwrap(key.currency1);
        if (a == address(0) || b == address(0)) return address(0);
        pair = v2Factory.getPair(a, b);
    }

    /// @dev The V2 pair for the token against an anchor, with what it holds
    /// of that anchor. Zero when V2 routing is off or no pair exists.
    function _bestV2Pool(address token, address anchor) private view returns (address pair, uint256 balance) {
        if (address(v2Factory) == address(0)) return (address(0), 0);
        pair = v2Factory.getPair(token, anchor);
        if (pair == address(0)) return (address(0), 0);
        (uint112 r0, uint112 r1,) = IUniswapV2PairMinimal(pair).getReserves();
        if (r0 == 0 || r1 == 0) return (address(0), 0);
        balance = IERC20(anchor).balanceOf(pair);
    }

    /// @dev Of the standard-tier V3 pools for the pair, the one holding the most anchor.
    function _bestV3Pool(address token, address anchor)
        private
        view
        returns (address best, uint24 bestFee, uint256 bestBalance)
    {
        uint24[4] memory tiers = [FEE_LOWEST, FEE_LOW, FEE_MEDIUM, FEE_HIGH];
        for (uint256 i = 0; i < tiers.length; ++i) {
            address pool = v3Factory.getPool(token, anchor, tiers[i]);
            if (pool == address(0)) continue;
            (uint160 sqrtPriceX96,,,,,,) = IUniswapV3PoolMinimal(pool).slot0();
            if (sqrtPriceX96 == 0) continue;
            uint256 anchorBalance = IERC20(anchor).balanceOf(pool);
            if (anchorBalance > bestBalance) {
                bestBalance = anchorBalance;
                bestFee = tiers[i];
                best = pool;
            }
        }
    }

    /**
     * @dev The V4 pool pairing `token` with ETH (native or WETH) or with the
     * dollar anchor that has the deepest in-range anchor reserve, chosen from
     * hand-registered pools and pools the registries report, restricted to
     * those whose hook is allowed.
     */
    function _bestV4Pool(address token, bool ethAnchor)
        private
        view
        returns (PoolKey memory bestKey, uint256 bestDepth, bool found)
    {
        bytes32[] storage ids = _v4PoolsOf[token];
        for (uint256 i = 0; i < ids.length; ++i) {
            V4Pool storage p = _v4Pools[ids[i]];
            (uint256 depth, bool ok) = _v4Candidate(p.key, p.anchor, ethAnchor);
            if (ok && (!found || depth > bestDepth)) (bestKey, bestDepth, found) = (p.key, depth, true);
        }
        for (uint256 i = 0; i < registries.length; ++i) {
            (bool has, PoolKey memory key) = _registryPool(registries[i], token);
            if (!has) continue;
            (address anchor, address priced, bool split) =
                _splitAnchor(Currency.unwrap(key.currency0), Currency.unwrap(key.currency1));
            if (!split || priced != token) continue;
            (uint256 depth, bool ok) = _v4Candidate(key, anchor, ethAnchor);
            if (ok && (!found || depth > bestDepth)) (bestKey, bestDepth, found) = (key, depth, true);
        }
    }

    /**
     * @dev A reverting registry is skipped rather than treated as fatal. The
     * code-size check is essential: a high-level call to a codeless address
     * reverts in the caller, outside the try block, and would drag every
     * launch down with it.
     */
    function _registryPool(IQuoteReferenceRegistry registry, address token)
        private
        view
        returns (bool found, PoolKey memory key)
    {
        if (address(registry).code.length == 0) return (false, key);
        try registry.referencePool(token) returns (bool f, PoolKey memory k) {
            return (f, k);
        } catch {
            return (false, key);
        }
    }

    function _v4Candidate(PoolKey memory key, address anchor, bool ethAnchor)
        private
        view
        returns (uint256 depth, bool ok)
    {
        if (_isEth(anchor) != ethAnchor) return (0, false);
        if (!allowedV4Hooks[address(key.hooks)]) return (0, false);
        Hop memory hop;
        hop.key = key;
        (, depth) = _hopState(hop, anchor);
        ok = depth > 0;
    }

    function _splitAnchor(address c0, address c1) private view returns (address anchor, address token, bool ok) {
        if (_isEth(c0) || _isEth(c1)) {
            // An ETH side is always the anchor, so a pool of ETH against the
            // dollar anchor prices the dollar anchor.
            return _isEth(c0) ? (c0, c1, true) : (c1, c0, true);
        }
        if (c0 == usdAnchor) return (c0, c1, true);
        if (c1 == usdAnchor) return (c1, c0, true);
        return (address(0), address(0), false);
    }

    // ---------------------------------------------------------------------
    // Unit conversion
    // ---------------------------------------------------------------------

    /// @dev `_quoteAtSqrtPrice` that saturates rather than reverting, used for floors.
    function _convertOrCap(uint160 sqrtPriceX96, uint256 amount, address base, address quote)
        private
        pure
        returns (uint256)
    {
        if (amount > type(uint128).max) return type(uint256).max;
        return _quoteAtSqrtPrice(sqrtPriceX96, uint128(amount), base, quote);
    }

    /**
     * @dev The arithmetic of Uniswap V3's OracleLibrary.getQuoteAtTick, fed
     * the sqrt price directly instead of a tick. `baseToken` and `quoteToken`
     * are the pool's currency addresses (address zero for native ETH), so
     * comparing them reproduces the pool's own ordering.
     */
    function _quoteAtSqrtPrice(uint160 sqrtRatioX96, uint128 baseAmount, address baseToken, address quoteToken)
        private
        pure
        returns (uint256 quoteAmount)
    {
        if (sqrtRatioX96 <= type(uint128).max) {
            uint256 ratioX192 = uint256(sqrtRatioX96) * sqrtRatioX96;
            quoteAmount = baseToken < quoteToken
                ? FullMath.mulDiv(ratioX192, baseAmount, 1 << 192)
                : FullMath.mulDiv(1 << 192, baseAmount, ratioX192);
        } else {
            uint256 ratioX128 = FullMath.mulDiv(sqrtRatioX96, sqrtRatioX96, 1 << 64);
            quoteAmount = baseToken < quoteToken
                ? FullMath.mulDiv(ratioX128, baseAmount, 1 << 128)
                : FullMath.mulDiv(1 << 128, baseAmount, ratioX128);
        }
    }
}
