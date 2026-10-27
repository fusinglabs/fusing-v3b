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

import {FusingLauncherToken, IFusingTokenSetup} from "./FusingLauncherToken.sol";
import {FusingHolderDistributor} from "./FusingHolderDistributor.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {FusingTerms} from "./libraries/FusingTerms.sol";

/**
 * @notice Everything FusingLaunchFactory passes to the deployer to bring
 * up a single launch token.
 */
/// @dev Both answer address(0) when the launch does not qualify for the plain token.
interface ILeanDeployer {
    function deploy(address launcher, bytes32 salt, string calldata name, string calldata symbol, address supplyRecipient, uint256 supply)
        external
        returns (address token);
    function predict(address launcher, bytes32 salt, string calldata name, string calldata symbol, address supplyRecipient, uint256 supply)
        external
        view
        returns (address);
}

struct LaunchDeployment {
    address originalDeployer;
    address supplyRecipient;
    uint256 supply;
    bytes32 salt;
    string name;
    string symbol;
    string logo;
    string description;
    FusingLauncherToken.Socials socials;
}

/**
 * @title FusingLaunchDeployer
 * @notice Creates the launch token for a fusi.ng launch when the factory
 * asks. It is a separate contract for one reason: keeping the factory's
 * deployed bytecode under EIP-170's 24576-byte cap. Embedding the token's
 * creation code with `new` is the largest single item in the factory's
 * size. The token still stores the true factory address, never this one.
 */
/**
 * @dev What this contract reads back from the factory: the guard a
 * launcher staged for their next launch.
 *
 * It is read here instead of passed through the launch call because adding
 * it there pushed the factory over the compiler's stack limit. Reading it
 * keeps the launch path byte for byte what it was.
 */
interface IGuardConfig {
    function guardSecondsOf(address launcher) external view returns (uint64);
    function guardListOf(address launcher) external view returns (address[] memory);
    // V2 additions: the launcher's staged terms, and the plumbing the token caps must skip.
    function termsOf(address launcher) external view returns (FusingTerms.LaunchTerms memory);
    function limitExemptions() external view returns (address[] memory);
    function whitelistOf(address launcher) external view returns (address[] memory);
}

contract FusingLaunchDeployer {
    // The token stores this metadata and serves it back through view
    // functions with unbounded return sizes, so an oversized write here
    // would make the token permanently unreadable: `socials()` hands back
    // all five strings together and could exhaust gas or time out an RPC
    // node. The strings are immutable once written, so bounding the write
    // is the only place a limit can live.
    uint256 private constant MAX_NAME_LENGTH = 64;
    uint256 private constant MAX_SYMBOL_LENGTH = 16;
    uint256 private constant MAX_LOGO_LENGTH = 512;
    uint256 private constant MAX_DESCRIPTION_LENGTH = 2048;
    uint256 private constant MAX_SOCIAL_LENGTH = 256;

    /// @notice The presentation of a launch. Tokens store none of it; fusi.ng reads it from here.
    event LaunchDetails(address indexed launcher, bytes32 salt, string logo, string description, FusingLauncherToken.Socials socials);

    error NotFactory();
    error MetadataTooLong();

    address public immutable factory;

    modifier onlyFactory() {
        if (msg.sender != factory) revert NotFactory();
        _;
    }

    /// @dev The holder distributor every launch that opts in gets a clone of. Its initialiser is this deployer.
    address public distributorImplementation;

    error DistributorNotWired();
    error DistributorAlreadyWired();
    error NotFactoryOwner();
    /// @dev The token would land on an address that does not end in FFFF, the fusi.ng signature.
    error NotVanity(address token);
    event RequireVanitySet(bool on);

    /**
     * @notice Wires the distributor implementation, once, by the factory
     * owner. Set after construction because the implementation's constructor
     * needs this deployer's address and this deployer needs the
     * implementation's: one of the two has to come second.
     */
    function setDistributorImplementation(address implementation) external {
        // The account that deployed this contract, or the factory's owner: the
        // deploy script is both, a test stack is only the first.
        if (msg.sender != installer && msg.sender != Ownable(factory).owner()) revert NotFactoryOwner();
        if (distributorImplementation != address(0)) revert DistributorAlreadyWired();
        if (implementation == address(0)) revert DistributorNotWired();
        distributorImplementation = implementation;
    }

    /// @dev The account that deployed this contract, allowed to wire the distributor implementation once.
    address public immutable installer;

    constructor(address factory_) {
        installer = msg.sender;
        if (factory_ == address(0)) revert NotFactory();
        factory = factory_;
    }

    /**
     * @notice Creates a new launch token and hands back its address.
     */
    /// @notice The deployer of the plain token (FusingTokenLean). Unset: every launch gets the full token.
    ILeanDeployer public leanDeployer;

    function setLeanDeployer(ILeanDeployer lean) external {
        if (msg.sender != installer && msg.sender != Ownable(factory).owner()) revert NotFactoryOwner();
        leanDeployer = lean;
    }

    /**
     * @notice When on, every token this deployer creates, plain or full, must
     * land on an address ending in FFFF, or the launch reverts. The owner's
     * rule (2026-09-28): the signature is not a convention the launch paths
     * keep, it is a property of every fusi.ng token. Off by default so the
     * test suites, which launch on random salts, are unchanged; production
     * turns it on. Whoever launches mines the salt (the site, the bots and
     * the SDK all do); this only refuses what they never send.
     */
    bool public requireVanity;

    function setRequireVanity(bool on) external {
        if (msg.sender != installer && msg.sender != Ownable(factory).owner()) revert NotFactoryOwner();
        requireVanity = on;
        emit RequireVanitySet(on);
    }

    function _checkVanity(address token) private view {
        if (requireVanity && uint16(uint160(token)) != 0xFFFF) revert NotVanity(token);
    }

    /**
     * @notice Deploys the launch token.
     *
     * The FFFF suffix every fusi.ng token carries is mined into the salt by
     * whoever launches: the site, the launchbots and the SDK all do it. It is
     * deliberately NOT checked here. A check would force every caller to mine
     * before calling, including integrators and the launchbots, to stop
     * nothing worse than a stranger deliberately launching an unmarked token
     * on this pad. The mark is a convention the launch paths keep, not a
     * toll on everyone who touches the factory.
     */
    function deployToken(LaunchDeployment calldata params) external onlyFactory returns (address token) {
        _requireMetadataWithinLimits(params);
        emit LaunchDetails(params.originalDeployer, params.salt, params.logo, params.description, params.socials);
        // The plain token, when the launch asks for nothing that lives in a token; the lean deployer decides and says zero when not.
        if (address(leanDeployer) != address(0)) {
            token = leanDeployer.deploy(params.originalDeployer, params.salt, params.name, params.symbol, params.supplyRecipient, params.supply);
            if (token != address(0)) {
                _checkVanity(token);
                return token;
            }
        }

        // The full token. Its rewards distributor, when the plan names one,
        // is created first: the token reads every setting, that address
        // included, from tokenSetup() inside its own constructor.
        if (_wantsHolders(params.originalDeployer)) {
            if (distributorImplementation == address(0)) revert DistributorNotWired();
            _pendingDistributor = _clone(distributorImplementation);
        }
        token = address(
            new FusingLauncherToken{salt: keccak256(abi.encode(params.originalDeployer, params.salt))}(
                params.name,
                params.symbol,
                params.originalDeployer,
                factory,
                params.supplyRecipient,
                params.supply,
                IGuardConfig(factory).guardSecondsOf(params.originalDeployer)
            )
        );
        if (_pendingDistributor != address(0)) {
            FusingTerms.LaunchTerms memory terms = IGuardConfig(factory).termsOf(params.originalDeployer);
            FusingHolderDistributor(_pendingDistributor).initialise(token, terms.minHolding, _exempt(params.supplyRecipient));
            distributorOf[token] = _pendingDistributor;
            _pendingDistributor = address(0);
        }
        _checkVanity(token);
    }

    /// @notice The holder rewards distributor deployed for `token`, or zero if it has none.
    mapping(address token => address) public distributorOf;

    /// @dev The distributor created for the token being constructed right now; zero at all other times.
    address private _pendingDistributor;

    /**
     * @notice What a launch token reads, once, from inside its constructor:
     * the whitelist window list, the caps as amounts, the accounts the caps
     * skip, the creator whitelist and the rewards distributor.
     */
    function tokenSetup(address launcher, address supplyRecipient, uint256 supply)
        external
        view
        returns (IFusingTokenSetup.Setup memory setup)
    {
        FusingTerms.LaunchTerms memory terms = IGuardConfig(factory).termsOf(launcher);
        uint64 guardSeconds = IGuardConfig(factory).guardSecondsOf(launcher);
        if (guardSeconds > 0) setup.guardList = IGuardConfig(factory).guardListOf(launcher);
        // The factory has already range-checked the caps, given as shares of supply.
        setup.maxWallet = supply * terms.maxWalletBps / 10_000;
        setup.maxTx = supply * terms.maxTxBps / 10_000;
        if (setup.maxWallet != 0 || setup.maxTx != 0) {
            // The caps are meant for the open market: on a whitelisted launch they start counting when the window ends.
            setup.limitsSeconds = uint64(terms.limitsSeconds);
            if (setup.limitsSeconds != 0) setup.limitsSeconds += guardSeconds;
            setup.whitelist = IGuardConfig(factory).whitelistOf(launcher);
        }
        setup.exempt = _exempt(supplyRecipient);
        setup.distributor = _pendingDistributor;
    }

    /// @dev The plumbing, the supply recipient and the burn address: not wallets the caps are aimed at, and none should collect holder rewards.
    function _exempt(address supplyRecipient) private view returns (address[] memory exempt) {
        address[] memory plumbing = IGuardConfig(factory).limitExemptions();
        exempt = new address[](plumbing.length + 2);
        for (uint256 i = 0; i < plumbing.length; i++) {
            exempt[i] = plumbing[i];
        }
        exempt[plumbing.length] = supplyRecipient;
        exempt[plumbing.length + 1] = 0x000000000000000000000000000000000000dEaD;
    }

    function _wantsHolders(address launcher) private view returns (bool) {
        FusingTerms.LaunchTerms memory terms = IGuardConfig(factory).termsOf(launcher);
        for (uint256 i = 0; i < terms.allocations.length; i++) {
            if (terms.allocations[i].moduleId == FusingTerms.MODULE_HOLDERS) return true;
        }
        return false;
    }

    /// @dev An EIP-1167 minimal proxy of `implementation`: 45 bytes of runtime that delegate every call to it.
    function _clone(address implementation) private returns (address instance) {
        bytes20 target = bytes20(implementation);
        assembly {
            let ptr := mload(0x40)
            mstore(ptr, 0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000000000000000000000)
            mstore(add(ptr, 0x14), target)
            mstore(add(ptr, 0x28), 0x5af43d82803e903d91602b57fd5bf30000000000000000000000000000000000)
            instance := create(0, ptr, 0x37)
        }
        if (instance == address(0)) revert DistributorNotWired();
    }

    /**
     * @notice The address `deployToken` will produce for these inputs, so a
     * token's address is known before its launch transaction is sent.
     */
    function predictTokenAddress(LaunchDeployment calldata params) external view returns (address) {
        bytes32 tokenSalt = keccak256(abi.encode(params.originalDeployer, params.salt));
        if (address(leanDeployer) != address(0)) {
            address lean = leanDeployer.predict(params.originalDeployer, params.salt, params.name, params.symbol, params.supplyRecipient, params.supply);
            if (lean != address(0)) return lean;
        }
        return address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), tokenSalt, _initCodeHash(params)))))
        );
    }

    /**
     * @dev Separated out and given a memory argument because ABI-encoding
     * eleven constructor arguments directly from calldata exhausts the Yul
     * optimizer's stack. The copy to memory costs a little gas on a view
     * call and keeps the encoding in a single place, which is what counts:
     * this hash and the one CREATE2 computes in `deployToken` must match
     * exactly, or a mined address ends up somewhere else.
     */
    function _initCodeHash(LaunchDeployment memory params) private view returns (bytes32) {
        return keccak256(
            abi.encodePacked(
                type(FusingLauncherToken).creationCode,
                abi.encode(
                    params.name,
                    params.symbol,
                    params.originalDeployer,
                    factory,
                    params.supplyRecipient,
                    params.supply,
                    IGuardConfig(factory).guardSecondsOf(params.originalDeployer)
                )
            )
        );
    }

    function _requireMetadataWithinLimits(LaunchDeployment calldata params) private pure {
        if (
            bytes(params.name).length > MAX_NAME_LENGTH || bytes(params.symbol).length > MAX_SYMBOL_LENGTH
                || bytes(params.logo).length > MAX_LOGO_LENGTH
                || bytes(params.description).length > MAX_DESCRIPTION_LENGTH
        ) {
            revert MetadataTooLong();
        }
        if (
            bytes(params.socials.twitter).length > MAX_SOCIAL_LENGTH
                || bytes(params.socials.telegram).length > MAX_SOCIAL_LENGTH
                || bytes(params.socials.discord).length > MAX_SOCIAL_LENGTH
                || bytes(params.socials.website).length > MAX_SOCIAL_LENGTH
                || bytes(params.socials.farcaster).length > MAX_SOCIAL_LENGTH
        ) {
            revert MetadataTooLong();
        }
    }
}
