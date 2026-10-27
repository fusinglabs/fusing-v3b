// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IFuseModule} from "./IFuseModule.sol";

/**
 * @notice What every module shares: the Vault is the only caller, ETH
 * arrives as msg.value, an ERC-20 is pulled from the Vault's allowance.
 * Modules keep per-launch configuration and, where a job cannot finish in
 * one call, per-launch holdings; they never hold anything the Vault did
 * not hand them for a specific launch and they have no withdrawal path.
 */
abstract contract FuseModuleBase is IFuseModule {
    using SafeERC20 for IERC20;

    error NotVault();
    error ZeroAddress();
    error BadParams();

    address public immutable vault;

    modifier onlyVault() {
        if (msg.sender != vault) revert NotVault();
        _;
    }

    constructor(address vault_) {
        if (vault_ == address(0)) revert ZeroAddress();
        vault = vault_;
    }

    receive() external payable {}

    /// @dev Takes the fees the Vault is handing over: msg.value for ETH, an allowance for an ERC-20.
    /**
     * @dev Pulls the fee in and returns what ACTUALLY arrived.
     *
     * The return value matters for a quote asset that charges a fee on
     * transfer: the module is told `amount` and receives less, and paying out
     * the figure it was told rather than the figure it holds would leave the
     * last recipient of a split unable to claim. Callers must use the return
     * value for every subsequent calculation, never the argument. For an
     * ordinary token the two are identical, so nothing changes.
     */
    function _take(address currency, uint256 amount) internal returns (uint256 received) {
        if (currency == address(0)) {
            if (msg.value != amount) revert BadParams();
            return amount;
        }
        if (msg.value != 0) revert BadParams();
        uint256 before = IERC20(currency).balanceOf(address(this));
        IERC20(currency).safeTransferFrom(msg.sender, address(this), amount);
        received = IERC20(currency).balanceOf(address(this)) - before;
    }

    function _checkShares(uint256 count, uint16[] memory bps, uint256 max) internal pure {
        if (count == 0 || count > max || bps.length != count) revert BadParams();
        uint256 sum;
        for (uint256 i = 0; i < count; i++) {
            if (bps[i] == 0) revert BadParams();
            sum += bps[i];
        }
        if (sum != 10_000) revert BadParams();
    }
}
