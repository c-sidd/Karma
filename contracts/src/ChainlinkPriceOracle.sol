// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Guarded} from "./Guarded.sol";
import {IPriceOracle} from "./interfaces/IPriceOracle.sol";
import {IAggregatorV3} from "./interfaces/IAggregatorV3.sol";

/// @title ChainlinkPriceOracle
/// @notice Production-oriented USD oracle adapter using Chainlink AggregatorV3 feeds.
/// @dev Feed answers are normalized to 1e8. Stale, negative, incomplete, and zero data revert.
contract ChainlinkPriceOracle is Guarded, IPriceOracle {
    error NoFeed();
    error InvalidAnswer();
    error StalePrice();
    error IncompleteRound();
    error UnsupportedDecimals();

    uint256 public immutable maxPriceAge;
    mapping(address => IAggregatorV3) public feedOf;

    event FeedSet(address indexed asset, address indexed feed);

    constructor(address guardian_, uint256 maxPriceAge_) Guarded(guardian_) {
        if (maxPriceAge_ == 0) revert StalePrice();
        maxPriceAge = maxPriceAge_;
    }

    function setFeed(address asset, address feed) external onlyOwner {
        if (asset == address(0) || feed == address(0)) revert NoFeed();
        uint8 decimals_ = IAggregatorV3(feed).decimals();
        if (decimals_ > 18) revert UnsupportedDecimals();
        feedOf[asset] = IAggregatorV3(feed);
        emit FeedSet(asset, feed);
    }

    function priceOf(address asset) external view returns (uint256) {
        IAggregatorV3 feed = feedOf[asset];
        if (address(feed) == address(0)) revert NoFeed();

        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) = feed.latestRoundData();
        if (answer <= 0) revert InvalidAnswer();
        if (updatedAt == 0 || block.timestamp - updatedAt > maxPriceAge) revert StalePrice();
        if (answeredInRound < roundId) revert IncompleteRound();

        uint8 decimals_ = feed.decimals();
        uint256 value = uint256(answer);
        if (decimals_ == 8) return value;
        if (decimals_ < 8) return value * (10 ** (8 - decimals_));
        return value / (10 ** (decimals_ - 8));
    }
}
