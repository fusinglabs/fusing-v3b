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

import {FusingTokenLean} from "./FusingTokenLean.sol";
import {FusingTerms} from "../libraries/FusingTerms.sol";

interface ILeanTerms {
    function guardSecondsOf(address launcher) external view returns (uint64);
    function termsOf(address launcher) external view returns (FusingTerms.LaunchTerms memory);
}

/**
 * @title FusingLeanDeployer
 * @notice Creates the plain launch token (FusingTokenLean) for the main
 * launch deployer, which has no room left for a second token's creation code.
 * Only that deployer may call it. The address is a CREATE2 of this contract,
 * the caller's salt and the constructor arguments, so it can be predicted and
 * a vanity ending mined before the launch is sent, as for the full token.
 *
 * The plain token is handed no address at all, not even this stack's
 * factory: a token with an address written into it is reported as having a
 * hidden owner by the scanners wallets embed, however powerless that address
 * is. Which factory launched a token is still on the factory's own record.
 */
contract FusingLeanDeployer {
    address public immutable launchDeployer;
    address public immutable factory;

    error NotLaunchDeployer();

    constructor(address launchDeployer_, address factory_) {
        launchDeployer = launchDeployer_;
        factory = factory_;
    }

    /**
     * @notice True when a launch gets the plain token: it asked for nothing
     * that lives in a token (no caps, no whitelist window, no holder
     * rewards) and its name and symbol fit in 32 bytes. Caps, the window and
     * rewards are the only reasons a launch token needs more than ERC-20;
     * the sniper tax and the opening fee belong to the pool, not the token.
     */
    function isLean(address launcher, string calldata name, string calldata symbol) public view returns (bool) {
        if (bytes(name).length > 32 || bytes(symbol).length > 32) return false;
        if (ILeanTerms(factory).guardSecondsOf(launcher) != 0) return false;
        FusingTerms.LaunchTerms memory terms = ILeanTerms(factory).termsOf(launcher);
        if (terms.maxWalletBps != 0 || terms.maxTxBps != 0) return false;
        for (uint256 i = 0; i < terms.allocations.length; i++) {
            if (terms.allocations[i].moduleId == FusingTerms.MODULE_HOLDERS) return false;
        }
        return true;
    }

    /// @notice Creates the plain token, or answers address(0) when the launch needs the full one.
    function deploy(address launcher, bytes32 salt, string calldata name, string calldata symbol, address supplyRecipient, uint256 supply)
        external
        returns (address token)
    {
        if (msg.sender != launchDeployer) revert NotLaunchDeployer();
        if (!isLean(launcher, name, symbol)) return address(0);
        token = address(new FusingTokenLean{salt: keccak256(abi.encode(launcher, salt))}(name, symbol, supplyRecipient, supply));
    }

    function predict(address launcher, bytes32 salt, string calldata name, string calldata symbol, address supplyRecipient, uint256 supply)
        external
        view
        returns (address)
    {
        if (!isLean(launcher, name, symbol)) return address(0);
        bytes32 initHash = keccak256(abi.encodePacked(type(FusingTokenLean).creationCode, abi.encode(name, symbol, supplyRecipient, supply)));
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), keccak256(abi.encode(launcher, salt)), initHash)))));
    }
}
