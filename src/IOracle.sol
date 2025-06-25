// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IOracle {
    function latestRoundData()
        external
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}
