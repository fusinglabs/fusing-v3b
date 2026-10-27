// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @notice What a Fuse Vault module is: a contract the Vault hands fees to,
 * per launch, that does one thing with them. Modules are stateless between
 * calls apart from per-launch configuration and escrowed credits; if a
 * call reverts the Vault keeps the amount owed and anyone can retry.
 *
 * Every function is Vault-only. `currency` is address zero for ETH, which
 * then arrives as msg.value; an ERC-20 is transferred to the module before
 * the call.
 */
interface IFuseModule {
    /// @notice Stores this launch's configuration for the module. Reverts on anything it cannot accept.
    function configure(address token, bytes calldata params) external;

    /// @notice Takes `amount` of `currency` for `token` and does the module's work with it, or reverts.
    function onFees(address token, address currency, uint256 amount) external payable;
}

/// @notice What the Vault reads off the factory at registration.
interface IFuseVaultFactoryView {
    function termsOf(address launcher) external view returns (bytes memory);
}
