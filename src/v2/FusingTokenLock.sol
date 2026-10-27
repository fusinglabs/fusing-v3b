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

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title FusingTokenLock
 * @notice Time-locked ERC-20 balances with optional linear vesting.
 *
 * Written for the V2 opening-buy rule: a creator may buy up to 6% of supply
 * with no strings attached, or up to 20% provided the whole amount goes
 * directly into a lock of at least seven days, vesting after that if they
 * choose. The router opens that lock inside the launch transaction itself,
 * so the tokens never pass through the creator's wallet on the way in.
 * Anyone else is free to use it for team or partner allocations.
 *
 * Each lock has a beneficiary, an unlock timestamp and a vesting length.
 * Before `unlockAt` nothing can be released. After it, a `vestSeconds` of
 * zero makes everything releasable immediately; any other value releases
 * the amount linearly across that many seconds. A release only ever pays
 * the beneficiary, though anyone may trigger it. There is no owner, no
 * early withdrawal and no way to reassign a lock to a different wallet.
 */
contract FusingTokenLock is ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct Lock {
        address token;
        address beneficiary;
        uint256 amount;
        uint256 released;
        uint64 unlockAt;
        uint32 vestSeconds;
    }

    error ZeroAddress();
    error ZeroAmount();
    error UnlockInThePast(uint64 unlockAt);
    error NothingToRelease(uint256 id);
    error InexactTransfer(uint256 expected, uint256 received);

    event Locked(uint256 indexed id, address indexed token, address indexed beneficiary, uint256 amount, uint64 unlockAt, uint32 vestSeconds);
    event Released(uint256 indexed id, address indexed beneficiary, uint256 amount);

    Lock[] private _locks;
    mapping(address beneficiary => uint256[] ids) private _byBeneficiary;
    mapping(address token => uint256[] ids) private _byToken;

    /**
     * @notice Takes `amount` of `token` from the caller and opens a new lock
     * for `beneficiary`. The amount received is checked against the amount
     * requested; a token that delivers less is rejected rather than locked
     * short.
     */
    function lock(address token, address beneficiary, uint256 amount, uint64 unlockAt, uint32 vestSeconds)
        external
        nonReentrant
        returns (uint256 id)
    {
        if (token == address(0) || beneficiary == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (unlockAt <= block.timestamp) revert UnlockInThePast(unlockAt);

        uint256 before = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = IERC20(token).balanceOf(address(this)) - before;
        if (received != amount) revert InexactTransfer(amount, received);

        id = _locks.length;
        _locks.push(Lock({token: token, beneficiary: beneficiary, amount: amount, released: 0, unlockAt: unlockAt, vestSeconds: vestSeconds}));
        _byBeneficiary[beneficiary].push(id);
        _byToken[token].push(id);
        emit Locked(id, token, beneficiary, amount, unlockAt, vestSeconds);
    }

    /// @notice The amount lock `id` could release at this moment.
    function releasable(uint256 id) public view returns (uint256) {
        Lock storage l = _locks[id];
        if (block.timestamp < l.unlockAt) return 0;
        uint256 vested;
        if (l.vestSeconds == 0) {
            vested = l.amount;
        } else {
            uint256 elapsed = block.timestamp - l.unlockAt;
            vested = elapsed >= l.vestSeconds ? l.amount : l.amount * elapsed / l.vestSeconds;
        }
        return vested - l.released;
    }

    /// @notice Sends the beneficiary all that is currently releasable from lock `id`. Open to any caller.
    function release(uint256 id) external nonReentrant returns (uint256 amount) {
        amount = releasable(id);
        if (amount == 0) revert NothingToRelease(id);
        Lock storage l = _locks[id];
        l.released += amount;
        IERC20(l.token).safeTransfer(l.beneficiary, amount);
        emit Released(id, l.beneficiary, amount);
    }

    function lockOf(uint256 id) external view returns (Lock memory) {
        return _locks[id];
    }

    function locksOf(address beneficiary) external view returns (uint256[] memory) {
        return _byBeneficiary[beneficiary];
    }

    function locksForToken(address token) external view returns (uint256[] memory) {
        return _byToken[token];
    }

    function lockCount() external view returns (uint256) {
        return _locks.length;
    }

    /// @notice How much `token` this contract still holds for `beneficiary`, summed over every lock of theirs.
    function lockedBalance(address token, address beneficiary) external view returns (uint256 total) {
        uint256[] storage ids = _byBeneficiary[beneficiary];
        for (uint256 i = 0; i < ids.length; i++) {
            Lock storage l = _locks[ids[i]];
            if (l.token == token) total += l.amount - l.released;
        }
    }
}
