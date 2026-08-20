// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

interface IPriceOracle {
    /// @return price USD price of one whole token, scaled to 1e8 (Chainlink convention).
    function priceOf(address asset) external view returns (uint256 price);
}
