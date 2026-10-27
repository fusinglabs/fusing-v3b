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

import {IQuoteReferenceRegistry} from "./FusingQuotePricer.sol";

/// @dev The one function of FusingLaunchFactory this adapter needs.
interface IFusingFactoryPoolKeys {
    function poolKeyFor(address token) external view returns (PoolKey memory);
}

/**
 * @notice Lets the quote pricer look up the pool key of any token that came
 * out of a fusi.ng factory. That is what allows a token launched on the
 * protocol to serve as the quote asset for a later launch the moment its
 * pool carries enough depth. Deploy one per factory: one for the V2 factory
 * and one for the live V1 factory, so FUSE and every V1 launch qualify too.
 */
contract FusingReferenceRegistry is IQuoteReferenceRegistry {
    IFusingFactoryPoolKeys public immutable factory;

    constructor(IFusingFactoryPoolKeys factory_) {
        factory = factory_;
    }

    function referencePool(address token) external view returns (bool found, PoolKey memory key) {
        try factory.poolKeyFor(token) returns (PoolKey memory k) {
            return (true, k);
        } catch {
            return (false, key);
        }
    }
}
