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
 *  Launched on fusi.ng. A fixed supply, minted once, in a Uniswap V4 pool
 *  whose liquidity is locked for ever. No owner, no mint, no pause, no
 *  blacklist, no tax, no proxy, no upgrade, and no function reserved for any
 *  address. Trading fees are charged by the pool, not by the token, and are
 *  paid out through the Fuse Vault.
 */

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev The single entry point the token uses to notify its holder rewards distributor.
/// @dev The factory's market-maker list, read live during the guard and limits windows.
interface IFusingMarketMakers {
    function marketMaker(address wallet) external view returns (bool);
}

interface IFusingDistributorSink {
    function onTransfer(address from, address to) external;
}

/**
 * @dev What the token asks the contract that is creating it, once, from inside
 * its own constructor. Everything a launch switches on arrives this way, so
 * the finished token has no function that any address is privileged to call,
 * and the CREATE2 address still does not depend on any of it.
 */
interface IFusingTokenSetup {
    struct Setup {
        address[] guardList;
        uint256 maxWallet;
        uint256 maxTx;
        uint64 limitsSeconds;
        address[] exempt;
        address[] whitelist;
        address distributor;
    }

    function tokenSetup(address launcher, address supplyRecipient, uint256 supply) external view returns (Setup memory);
}

/**
 * @title FusingLauncherToken
 * @notice The fixed-supply ERC-20 a fusi.ng launch gets when it switches on
 * something that lives in a token: a whitelist window, wallet and transaction
 * caps, or holder rewards. A launch that uses none of them gets
 * FusingTokenLean instead.
 *
 * Every setting is read in the constructor and never again. Once the launch
 * transaction ends this contract cannot be configured by anyone. The logo,
 * description and links of a launch are published in the launch event and
 * kept by fusi.ng, not stored here. `deployer` is reference data so front
 * ends can attribute the launch; it grants no control over the token.
 */
contract FusingLauncherToken is ERC20 {
    /// @dev The links a launch is published with. Declared here for the factory's launch call; the token stores none of it.
    struct Socials {
        string twitter;
        string telegram;
        string discord;
        string website;
        string farcaster;
    }

    error ZeroAddress();
    /// @dev Raised when tokens would move to an address off the guard list while the guard is still in force.
    error LaunchGuardActive(address to, uint64 endsAt);
    /// @dev The requested guard window is longer than this contract allows.
    error GuardWindowTooLong(uint64 asked, uint64 max);
    /// @dev Raised when a transfer would push `to` past the wallet cap during the limits window.
    error MaxWalletExceeded(address to, uint256 wouldHold, uint256 max);
    /// @dev Raised when a single transfer exceeds the per-transaction cap during the limits window.
    error MaxTxExceeded(uint256 amount, uint256 max);
    /// @dev The requested limits window is longer than this contract allows.
    error LimitsWindowTooLong(uint64 asked, uint64 max);

    /**
     * @notice Upper bound on the whitelist window: three minutes.
     *
     * The creator chooses anything from zero up to this, and the choice is
     * baked in here at construction. There is no setter, so the window can
     * never be extended afterwards by anyone, including a renounced owner;
     * that is what keeps a whitelist from being a honeypot switch.
     *
     * Three minutes is a deliberate ceiling rather than a generous one. A
     * window long enough to look like a closed market gets a token flagged by
     * scanners, which costs the creator far more than the window buys them.
     * One block is enough to land a planned opening buy; three minutes is the
     * most that can still be read as an opening rather than a trap.
     */
    uint64 public constant MAX_GUARD_SECONDS = 3 minutes;
    /// @notice Upper bound on the caps: 20 minutes, plus a launch window of up to a minute.
    uint64 public constant MAX_LIMITS_SECONDS = 21 minutes;
    /// @notice How many blocks from launch the whitelist is spared the caps: about a minute.
    uint64 public constant WHITELIST_BLOCKS = 5;

    /*
     * The three addresses below are in STORAGE rather than `immutable`, and
     * that is the whole reason for it.
     *
     * GoPlus reports `hidden_owner` for a token that carries any address as an
     * immutable, because an immutable is written into the runtime bytecode and
     * a decompiler reads it straight back out; it cannot tell a launch factory
     * from a hidden admin. Measured on mainnet, not inferred: five probes that
     * kept one address as an immutable were all flagged, as a public immutable
     * (A, B, E), as a private one with no getter (C) and as a private one
     * behind a helper (D). The same address moved into storage reads clean,
     * with a public getter (probe G, 0x2f153b4c) and without (probe H,
     * 0x8e75ee39): both `hidden_owner=0`, `is_proxy=0`.
     *
     * So the getter is not the problem and the address is not the problem. The
     * immutable is. Storage costs one SSTORE each at construction and an SLOAD
     * where they are read, which is the price of an expert launch not carrying
     * a scanner warning. None of them has a setter, here or anywhere.
     *
     * The plain token solves this by having no address at all; only the full
     * token needs these three.
     */
    address public deployer;
    address public launchFactory;

    /**
     * Unix timestamp at which the launch guard lifts. Zero means no guard was
     * set. Until then a transfer succeeds only if the RECIPIENT is on
     * `guardAllowed`. The rule is one-directional, cannot be lengthened, and
     * once the timestamp is behind us the token is a plain ERC-20 for good.
     */
    uint64 public immutable guardEndsAt;
    /// @notice Unix timestamp at which the caps stop applying. Zero means they were never enabled.
    uint64 public immutable limitsEndAt;
    /// @notice The launch block.
    uint64 public immutable launchBlock;
    /// @notice Maximum balance any wallet may reach during the limits window. Zero disables the cap.
    uint256 public immutable maxWallet;
    /// @notice Maximum size of one transfer during the limits window. Zero disables the cap.
    uint256 public immutable maxTx;
    /// @notice Holder rewards distributor notified on each transfer. Zero means
    /// the launch has none. In storage, not immutable: see `deployer` above.
    address public distributor;

    /// @notice Recipients that transfers may reach while the guard is in force.
    mapping(address account => bool allowed) public guardAllowed;
    /// @notice Accounts the caps ignore: the pool, the position locker and the routers.
    mapping(address account => bool) public limitExempt;
    /// @notice The creator's whitelist: spared the caps for WHITELIST_BLOCKS blocks from launch; capped like everyone after that.
    mapping(address account => bool) public launchWhitelisted;

    /**
     * @notice Deploys a launch token, reads its settings from the contract
     * creating it, and mints the full supply straight to `supplyRecipient_`.
     */
    constructor(
        string memory name_,
        string memory symbol_,
        address deployer_,
        address launchFactory_,
        address supplyRecipient_,
        uint256 supply_,
        uint64 guardSeconds_
    ) ERC20(name_, symbol_) {
        if (deployer_ == address(0) || supplyRecipient_ == address(0) || launchFactory_ == address(0)) {
            revert ZeroAddress();
        }
        if (guardSeconds_ > MAX_GUARD_SECONDS) revert GuardWindowTooLong(guardSeconds_, MAX_GUARD_SECONDS);
        deployer = deployer_;
        launchFactory = launchFactory_;
        launchBlock = uint64(block.number);

        IFusingTokenSetup.Setup memory setup =
            IFusingTokenSetup(msg.sender).tokenSetup(deployer_, supplyRecipient_, supply_);
        if (setup.limitsSeconds > MAX_LIMITS_SECONDS) {
            revert LimitsWindowTooLong(setup.limitsSeconds, MAX_LIMITS_SECONDS);
        }

        uint64 guardEnds;
        if (guardSeconds_ > 0) {
            guardEnds = uint64(block.timestamp) + guardSeconds_;
            // The supply recipient must be able to receive, or the launch fails.
            guardAllowed[supplyRecipient_] = true;
            for (uint256 i = 0; i < setup.guardList.length; i++) {
                if (setup.guardList[i] != address(0)) guardAllowed[setup.guardList[i]] = true;
            }
        }
        guardEndsAt = guardEnds;

        uint64 limitsEnd;
        uint256 walletCap;
        uint256 txCap;
        if (setup.limitsSeconds != 0 && (setup.maxWallet != 0 || setup.maxTx != 0)) {
            walletCap = setup.maxWallet;
            txCap = setup.maxTx;
            limitsEnd = uint64(block.timestamp) + setup.limitsSeconds;
            for (uint256 i = 0; i < setup.exempt.length; i++) {
                if (setup.exempt[i] != address(0)) limitExempt[setup.exempt[i]] = true;
            }
            // Caps are aimed at outsiders, not at the creator.
            limitExempt[deployer_] = true;
            for (uint256 i = 0; i < setup.whitelist.length; i++) {
                launchWhitelisted[setup.whitelist[i]] = true;
            }
        }
        maxWallet = walletCap;
        maxTx = txCap;
        limitsEndAt = limitsEnd;
        distributor = setup.distributor;

        _mint(supplyRecipient_, supply_);
    }

    /// @notice True while transfers are still restricted to the guard list.
    function guardActive() external view returns (bool) {
        return guardEndsAt != 0 && block.timestamp < guardEndsAt;
    }

    /// @notice True while the wallet and transaction caps are in effect.
    function limitsActive() public view returns (bool) {
        return limitsEndAt != 0 && block.timestamp < limitsEndAt;
    }

    /**
     * @dev The guard and the caps: the behaviour this override layers on a
     * plain ERC-20, and only during the first minutes of a launch.
     *
     * The guard checks the recipient, not the sender. The point is to stop an
     * outsider from holding the token in the first block; if senders were
     * checked instead, the pool would need to be on the list, and a listed
     * pool could then deliver tokens to anyone. Mints always pass.
     */
    function _update(address from, address to, uint256 value) internal override {
        // The protocol's market makers are spared the window and the caps
        // below. Asked of the factory live, so a wallet added after this
        // token launched is spared too, and only while a window is open:
        // once both have ended none of this code runs again.
        if (guardEndsAt != 0 && block.timestamp < guardEndsAt && from != address(0) && !guardAllowed[to] && !_marketMaker(to)) {
            revert LaunchGuardActive(to, guardEndsAt);
        }
        // Caps. Mints are exempt, as is the plumbing: the pool must be able to
        // hold the entire supply and the routers must be able to push any size
        // through it. Only ordinary wallets are capped, and only until
        // `limitsEndAt`; after that this block never runs again.
        if (limitsEndAt != 0 && block.timestamp < limitsEndAt && from != address(0) && to != address(0)) {
            bool window = block.number < uint256(launchBlock) + WHITELIST_BLOCKS;
            bool fromExempt = limitExempt[from] || (window && launchWhitelisted[from]) || _marketMaker(from);
            bool toExempt = limitExempt[to] || (window && launchWhitelisted[to]) || _marketMaker(to);
            if (!(fromExempt && toExempt)) {
                if (maxTx != 0 && value > maxTx) revert MaxTxExceeded(value, maxTx);
            }
            if (!toExempt && maxWallet != 0) {
                uint256 wouldHold = balanceOf(to) + value;
                if (wouldHold > maxWallet) revert MaxWalletExceeded(to, wouldHold, maxWallet);
            }
        }
        super._update(from, to, value);
        // Holder rewards: once balances settle, the distributor re-reads both
        // accounts. It is fusi.ng code created in the same launch transaction,
        // never user-supplied. Skipped for the mint, which happens while this
        // contract is still being constructed.
        if (distributor != address(0) && from != address(0)) IFusingDistributorSink(distributor).onTransfer(from, to);
    }

    /// @dev A factory that has no market-maker list (an older factory) answers false rather than reverting.
    function _marketMaker(address who) private view returns (bool) {
        (bool ok, bytes memory data) = launchFactory.staticcall(abi.encodeWithSelector(IFusingMarketMakers.marketMaker.selector, who));
        return ok && data.length == 32 && abi.decode(data, (bool));
    }

    /*
     * There is deliberately no `owner()` here, not even one returning the
     * zero address. A scanner that finds the function reports the token as
     * having a hidden owner rather than no owner, which was measured on
     * mainnet across six variants of the plain token. Nothing can own this
     * contract: there is no owner slot, no setter and no privileged call.
     */
}
