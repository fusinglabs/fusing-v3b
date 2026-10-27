// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FusingTerms} from "./FusingTerms.sol";

/**
 * @title FusingTermsCheck
 * @notice The protocol's bounds on creator-chosen launch terms, and the
 * check that staged terms sit inside them. An external library, linked into
 * the factory: the checks are pure and cost the factory no bytecode, which
 * is what lets the launch path carry six markets under the size limit.
 *
 * The factory exposes the same figures as public constants that read from
 * here, so there is one definition of every bound.
 */
library FusingTermsCheck {
    uint256 internal constant BASIS_POINTS = 10_000;

    /// @notice Bounds on the caps a creator may put on wallets and transactions, in bps of supply, and for how long.
    uint16 internal constant MIN_LIMIT_BPS = 10;
    uint16 internal constant MAX_LIMIT_BPS = 300;
    uint32 internal constant MAX_LIMITS_SECONDS = 20 minutes;
    /// @notice The opening pool fee may start this high (20%) and must decay within this long.
    uint24 internal constant MAX_START_FEE = 200_000;
    uint32 internal constant MAX_DECAY_SECONDS = 20 minutes;
    /**
     * @notice Wallets a launch may whitelist for its opening window.
     *
     * A creator picks any number from zero to this. The ceiling exists for gas,
     * not policy: every entry is an SSTORE in the token's constructor, so a
     * full list adds meaningfully to what a launch costs. 100 is the point at
     * which that is still a few dollars rather than a surprise.
     */
    uint256 internal constant MAX_WHITELIST = 100;
    /// @notice The creator's locked opening buy: no shorter than a week, no longer than four years.
    uint32 internal constant MIN_DEV_LOCK_SECONDS = 7 days;
    uint32 internal constant MAX_DEV_LOCK_SECONDS = 4 * 365 days;
    /// @notice Ceiling on Vault allocations per launch.
    uint256 internal constant MAX_ALLOCATIONS = 6;

    error TooManyAllocations();
    error SharesInvalid();
    error TermsInvalid();

    /**
     * @notice Reverts unless `terms` are acceptable: allocation shares sum
     * to 100%, holder rewards carry a minimum holding, every figure sits
     * inside the bounds above, and the launch takes the sniper tax or a
     * whitelist window, never both. The modules themselves check their
     * parameters when the Vault registers the launch.
     */
    function validate(FusingTerms.LaunchTerms calldata terms) external pure {
        if (terms.allocations.length > MAX_ALLOCATIONS) revert TooManyAllocations();
        uint256 sum;
        bool holders;
        for (uint256 i = 0; i < terms.allocations.length; i++) {
            FusingTerms.Allocation calldata a = terms.allocations[i];
            if (a.bps == 0) revert SharesInvalid();
            if (a.moduleId == FusingTerms.MODULE_HOLDERS) holders = true;
            sum += a.bps;
        }
        if (terms.allocations.length > 0 && sum != BASIS_POINTS) revert SharesInvalid();
        if (holders && terms.minHolding == 0) revert TermsInvalid();
        if (terms.maxWalletBps != 0 && (terms.maxWalletBps < MIN_LIMIT_BPS || terms.maxWalletBps > MAX_LIMIT_BPS)) revert TermsInvalid();
        if (terms.maxTxBps != 0 && (terms.maxTxBps < MIN_LIMIT_BPS || terms.maxTxBps > MAX_LIMIT_BPS)) revert TermsInvalid();
        bool caps = terms.maxWalletBps != 0 || terms.maxTxBps != 0;
        if (caps && (terms.limitsSeconds == 0 || terms.limitsSeconds > MAX_LIMITS_SECONDS)) revert TermsInvalid();
        if (terms.startFee > MAX_START_FEE) revert TermsInvalid();
        if (terms.startFee != 0 && (terms.decaySeconds == 0 || terms.decaySeconds > MAX_DECAY_SECONDS)) revert TermsInvalid();
        if (terms.whitelist.length > MAX_WHITELIST) revert TermsInvalid();
        // One protection or the other, never both: the sniper tax on the
        // launch block, or a whitelist window in which only the list can buy.
        if (terms.antiSniper && terms.whitelist.length > 0) revert TermsInvalid();
        if (terms.devLockSeconds != 0 && (terms.devLockSeconds < MIN_DEV_LOCK_SECONDS || terms.devLockSeconds > MAX_DEV_LOCK_SECONDS)) revert TermsInvalid();
        if (terms.devVestSeconds > MAX_DEV_LOCK_SECONDS) revert TermsInvalid();
        if (terms.devVestSeconds != 0 && terms.devLockSeconds == 0) revert TermsInvalid();
    }

    /**
     * @notice Copies validated terms into the factory's storage slot for
     * the launcher, field by field (a calldata struct with dynamic members
     * cannot be assigned to storage in one go). Whitelist entries that are
     * the zero address are dropped. Lives here rather than in the factory
     * for contract size alone.
     */
    function store(FusingTerms.LaunchTerms storage t, FusingTerms.LaunchTerms calldata terms) external {
        t.maxWalletBps = terms.maxWalletBps;
        t.maxTxBps = terms.maxTxBps;
        t.limitsSeconds = terms.limitsSeconds;
        t.startFee = terms.startFee;
        t.decaySeconds = terms.decaySeconds;
        t.antiSniper = terms.antiSniper;
        t.payoutMode = terms.payoutMode;
        t.minHolding = terms.minHolding;
        t.devLockSeconds = terms.devLockSeconds;
        t.devVestSeconds = terms.devVestSeconds;
        t.hard = terms.hard;
        t.allowTaxedQuote = terms.allowTaxedQuote;
        delete t.whitelist;
        for (uint256 i = 0; i < terms.whitelist.length; i++) {
            if (terms.whitelist[i] != address(0)) t.whitelist.push(terms.whitelist[i]);
        }
        delete t.allocations;
        for (uint256 i = 0; i < terms.allocations.length; i++) {
            t.allocations.push(terms.allocations[i]);
        }
    }
}
