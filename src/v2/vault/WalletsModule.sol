// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {FuseModuleBase} from "./FuseModuleBase.sol";

interface IWalletsEscrow {
    function credit(address recipient) external payable;
    function creditToken(address recipient, address token, uint256 amount) external;
}

/// @dev The one thing this module asks the Vault: who owns a launch's fee configuration.
interface IFuseVaultConfigOwner {
    function configOwner(address token) external view returns (address);
}

/**
 * @title WalletsModule
 * @notice Splits fees across up to six wallets by share, crediting the fee
 * escrow so each wallet claims on its own. Params: abi.encode(address[] wallets, uint16[] bps).
 */
contract WalletsModule is FuseModuleBase {
    using SafeERC20 for IERC20;

    uint256 public constant MAX_WALLETS = 6;

    struct Split {
        address[] wallets;
        uint16[] bps;
    }

    IWalletsEscrow public immutable escrow;
    mapping(address token => Split) private _splits;

    event Configured(address indexed token, address[] wallets, uint16[] bps);
    event Paid(address indexed token, address indexed currency, uint256 amount, uint256 wallets);

    constructor(address vault_, IWalletsEscrow escrow_) FuseModuleBase(vault_) {
        if (address(escrow_) == address(0)) revert ZeroAddress();
        escrow = escrow_;
    }

    function splitOf(address token) external view returns (address[] memory wallets, uint16[] memory bps) {
        return (_splits[token].wallets, _splits[token].bps);
    }

    function configure(address token, bytes calldata params) external onlyVault {
        (address[] memory wallets, uint16[] memory bps) = abi.decode(params, (address[], uint16[]));
        _checkShares(wallets.length, bps, MAX_WALLETS);
        for (uint256 i = 0; i < wallets.length; i++) {
            if (wallets[i] == address(0)) revert BadParams();
        }
        _splits[token] = Split({wallets: wallets, bps: bps});
        emit Configured(token, wallets, bps);
    }

    function onFees(address token, address currency, uint256 amount) external payable onlyVault {
        Split storage s = _splits[token];
        // Use what arrived, not what we were told: a taxed quote delivers less.
        amount = _take(currency, amount);
        uint256 n = s.wallets.length;
        /*
         * Nothing stored means the default plan: the launch asked for nothing
         * but "pay the creator", so the whole amount goes to whoever owns the
         * fee configuration, read from the Vault at payout time rather than
         * copied in at launch. Writing that default down instead cost about
         * 240k gas on every launch (a configure call plus its params in
         * storage) to describe what the code already does, and reading it
         * live means a fee-owner transfer needs no rewrite here either.
         */
        if (n == 0) {
            address to = IFuseVaultConfigOwner(vault).configOwner(token);
            if (to == address(0)) revert BadParams();
            if (currency == address(0)) {
                escrow.credit{value: amount}(to);
            } else {
                IERC20(currency).forceApprove(address(escrow), amount);
                escrow.creditToken(to, currency, amount);
            }
            emit Paid(token, currency, amount, 1);
            return;
        }
        uint256 paid;
        if (currency != address(0)) IERC20(currency).forceApprove(address(escrow), amount);
        for (uint256 i = 0; i < n; i++) {
            uint256 share = i + 1 == n ? amount - paid : amount * s.bps[i] / 10_000;
            paid += share;
            if (share == 0) continue;
            if (currency == address(0)) escrow.credit{value: share}(s.wallets[i]);
            else escrow.creditToken(s.wallets[i], currency, share);
        }
        emit Paid(token, currency, amount, n);
    }
}
