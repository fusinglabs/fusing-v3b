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

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/**
 * @notice Which AMM a hop trades on.
 *
 * V2 is here because depth does not all live on V3. Plenty of tokens with
 * real money behind them never migrated: at the time of writing, TRUMP held
 * 123 WETH in its V2 pair and had no V3 pool at any tier, and Mog and WXMR
 * sat in the live pad's own quote list unpriceable for the same reason. A
 * pricer that only reads V3 and V4 throws that away and tells the user the
 * token has no liquidity, which is not what it means.
 */
enum HopKind {
    V4,
    V3,
    V2
}

/**
 * @notice A single pool along a route from one asset to another. The quote
 * pricer values an asset by walking a chain of these from that asset to ETH,
 * and the router trades along the very same chain with real funds. Sharing
 * one struct between the two guarantees that any route the pricer accepts
 * is also, hop for hop, a route the router is able to execute.
 * @param key For a Uniswap V4 hop this is the pool key as V4 defines it. For
 *        a Uniswap V3 hop, `currency0` and `currency1` hold the pool's two
 *        tokens sorted by address, `fee` holds the V3 fee tier, and both
 *        `tickSpacing` and `hooks` must be zero; the pool address is then
 *        whatever the V3 factory resolves for that triple. For a Uniswap V2
 *        hop, `currency0` and `currency1` hold the pair's two tokens sorted
 *        by address and every other field must be zero, including `fee`:
 *        V2's 0.3% is fixed in its own code and is not ours to state.
 * @param kind Which AMM the hop trades on.
 */
struct Hop {
    PoolKey key;
    HopKind kind;
}
