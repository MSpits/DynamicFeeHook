// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "../src/IOracle.sol";

contract MockOracle is IOracle {
    int256 private price;

    constructor(int256 _initialPrice) {
        price = _initialPrice;
    }

    function setLatestPrice(int256 _price) external {
        price = _price;
    }

    function latestRoundData()
        external
        view
        override
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (0, price, 0, 0, 0);
    }
}
