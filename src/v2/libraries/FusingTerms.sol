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

/**
 * @notice The launch terms introduced in V2, used by the factory (stages and
 * validates them), the deployer (applies the token-side ones), the fee hook
 * (the fee schedule), the Fuse Vault (the fee configuration) and the fee
 * converter (the payout mode).
 */
library FusingTerms {
    /**
     * @notice The well-known module ids in the Fuse Vault's registry. The
     * Vault is deployed with these five in this order; the admin may add
     * more afterwards, and their ids follow on.
     */
    uint8 internal constant MODULE_WALLETS = 0;
    uint8 internal constant MODULE_BURN = 1;
    uint8 internal constant MODULE_AUTO_LP = 2;
    uint8 internal constant MODULE_HOLDERS = 3;
    uint8 internal constant MODULE_HANDLES = 4;

    /**
     * @notice One destination of a launch's fees: a Vault module and its
     * share. `params` is the module's own configuration for this launch
     * (the wallet list and shares, the reward assets, the handle list), ABI
     * encoded the way that module documents; the Vault hands it to the
     * module to validate and store.
     */
    struct Allocation {
        uint8 moduleId;
        uint16 bps;
        bytes params;
    }

    /**
     * @notice The asset the creator's fees are paid in. The protocol's share
     * is converted to ETH no matter which mode the creator picks. All
     * conversions share the same bounds (FusingSwapGuard), and anything that
     * does not fit within them is queued.
     *
     *   ETH              everything is converted along the pricer's route and
     *                    paid as ETH. The default, since its value is zero.
     *   QUOTE            the token side is sold into the pool and everything
     *                    is paid in the pool's quote asset: PEPE for a PEPE
     *                    pair, USDC for a USDC pair, the stock for a stock
     *                    pair. On an ETH-quoted pool this is identical to ETH.
     *   TOKEN_AND_QUOTE  none of the creator's share is sold: the token side
     *                    is handed over as tokens and the quote side as quote,
     *                    just as the LP fees accrued. This is what V1 paid.
     *   TOKEN            the quote side buys the launch token back out of its
     *                    own pool and everything is paid in tokens.
     *
     * Burning and adding liquidity are not modes: they are Vault modules
     * within the creator's split, and each accepts whatever asset the mode
     * produces.
     */
    enum PayoutMode {
        ETH,
        QUOTE,
        TOKEN_AND_QUOTE,
        TOKEN
    }

    /**
     * @notice The parameters the anti-sniper switch runs on. The protocol
     * owner sets them once and every launch that enables the switch uses them.
     */
    struct Presets {
        // Flat surcharge in pips applied in the launch block and for sniperBlocks - 1 blocks after it.
        uint24 sniperPremium;
        uint32 sniperBlocks;
    }

    /**
     * @notice The terms a creator stages ahead of their next launch. The zero
     * value of every field means V1 behaviour, so an all-zero struct describes
     * a V1 launch paid in ETH.
     *
     * The limits and the fee schedule are chosen by the creator within bounds
     * the protocol enforces (FusingLaunchFactory): caps from 0.1% to 3% of
     * supply, and an opening fee of at most 20% decaying to the base fee, each
     * lasting no longer than 20 minutes. Once they expire there are no limits
     * and the fee is base plus creator tax.
     */
    struct LaunchTerms {
        // Token caps as basis points of supply. A zero field means no cap of that kind; both zero means limits are off.
        uint16 maxWalletBps;
        uint16 maxTxBps;
        uint32 limitsSeconds;
        // Fee schedule: the pool's total fee at the moment of launch, in pips
        // (1% = 10_000), decaying linearly to the resting fee across decaySeconds. Zero disables it.
        uint24 startFee;
        uint32 decaySeconds;
        // Turns on the anti-sniper window using the protocol's preset figures.
        bool antiSniper;
        PayoutMode payoutMode;
        // As many as 33 wallets exempted from the caps and the launch-block
        // premium: the creator's own circle, allowed in before the bots.
        address[] whitelist;
        // The creator's opening buy: at most 6% of supply held freely, or at
        // most 20% when it goes directly into a lock lasting at least seven
        // days (devLockSeconds), then vesting linearly over devVestSeconds
        // (zero means everything at once).
        uint32 devLockSeconds;
        uint32 devVestSeconds;
        // Holder rewards: the minimum balance that qualifies to earn, relevant when the holders module is allocated. Set by the creator.
        uint256 minHolding;
        // HARD: the fee configuration below is fixed for the life of the launch (the Vault admin excepted).
        // FLEX: the configuration's owner may change it at will.
        bool hard;
        // Opts this launch into a quote asset that charges a fee on transfer.
        //
        // Off by default, and deliberately not something the pad decides for
        // the creator. A taxed quote costs a slice of every fee collection
        // for the life of the launch, and where the tax is one somebody can
        // raise later, the creator is accepting a lever a third party holds
        // over their market. The pricer measures the tax and flags an
        // apparent owner; this flag is the creator saying they read it.
        bool allowTaxedQuote;
        // Where the creator's share goes: up to six modules by share, summing to 100%.
        // Empty means everything to the creator fee recipient through the wallets module.
        Allocation[] allocations;
    }
}
