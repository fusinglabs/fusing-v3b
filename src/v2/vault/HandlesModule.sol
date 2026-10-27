// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {FuseModuleBase} from "./FuseModuleBase.sol";

interface IHandlesEscrow {
    function creditHandle(bytes32 handle, address asset, uint256 amount) external payable;
}

/**
 * @title HandlesModule
 * @notice Splits fees across up to six X or Telegram handles by share. The
 * escrow holds the balance under the handle; whoever proves the handle
 * through the attester claims it, after logging in on that platform.
 * Params: abi.encode(bytes32[] handles, uint16[] bps), a handle being
 * `FusingFeeEscrow.handleKey(platform, name)`: keccak256 of
 * `<platform>:<name>` lower-cased, platform "x" or "tg", at-sign removed.
 */
contract HandlesModule is FuseModuleBase {
    using SafeERC20 for IERC20;

    uint256 public constant MAX_HANDLES = 6;

    struct Split {
        bytes32[] handles;
        uint16[] bps;
    }

    IHandlesEscrow public immutable escrow;
    mapping(address token => Split) private _splits;

    event Configured(address indexed token, bytes32[] handles, uint16[] bps);
    event Paid(address indexed token, address indexed currency, uint256 amount, uint256 handles);

    constructor(address vault_, IHandlesEscrow escrow_) FuseModuleBase(vault_) {
        if (address(escrow_) == address(0)) revert ZeroAddress();
        escrow = escrow_;
    }

    function splitOf(address token) external view returns (bytes32[] memory handles, uint16[] memory bps) {
        return (_splits[token].handles, _splits[token].bps);
    }

    function configure(address token, bytes calldata params) external onlyVault {
        (bytes32[] memory handles, uint16[] memory bps) = abi.decode(params, (bytes32[], uint16[]));
        _checkShares(handles.length, bps, MAX_HANDLES);
        for (uint256 i = 0; i < handles.length; i++) {
            if (handles[i] == bytes32(0)) revert BadParams();
        }
        _splits[token] = Split({handles: handles, bps: bps});
        emit Configured(token, handles, bps);
    }

    function onFees(address token, address currency, uint256 amount) external payable onlyVault {
        Split storage s = _splits[token];
        if (s.handles.length == 0) revert BadParams();
        // Use what arrived, not what we were told: a taxed quote delivers less.
        amount = _take(currency, amount);
        uint256 n = s.handles.length;
        uint256 paid;
        if (currency != address(0)) IERC20(currency).forceApprove(address(escrow), amount);
        for (uint256 i = 0; i < n; i++) {
            uint256 share = i + 1 == n ? amount - paid : amount * s.bps[i] / 10_000;
            paid += share;
            if (share == 0) continue;
            if (currency == address(0)) escrow.creditHandle{value: share}(s.handles[i], address(0), share);
            else escrow.creditHandle(s.handles[i], currency, share);
        }
        emit Paid(token, currency, amount, n);
    }
}
