// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @notice The slice of Pyth's price feeds contract the pricer reads: one
 * price no older than a given age, plus the update entry point so a launch
 * can post the signed price it needs in the same transaction.
 */
interface IPythMinimal {
    struct Price {
        int64 price;
        uint64 conf;
        int32 expo;
        uint256 publishTime;
    }

    function getPriceNoOlderThan(bytes32 id, uint256 age) external view returns (Price memory);
    function updatePriceFeeds(bytes[] calldata updateData) external payable;
    function getUpdateFee(bytes[] calldata updateData) external view returns (uint256);
}

/// @notice The slice of a Chainlink aggregator the pricer reads for ETH/USD.
interface IAggregatorV3Minimal {
    function decimals() external view returns (uint8);
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}
