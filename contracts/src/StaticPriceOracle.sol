// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Guarded} from "./Guarded.sol";
import {IPriceOracle} from "./interfaces/IPriceOracle.sol";

/// @title  StaticPriceOracle
/// @notice TESTNET ONLY. Owner-published prices, 1e8 scale.
/// @dev    Sepolia has no liquid markets, so there is nothing honest to read. This
///         contract is not part of the security argument and must be swapped for
///         Chainlink feeds before any deployment that holds real value. It is named
///         Static so that it can never be mistaken for a market oracle.
contract StaticPriceOracle is Guarded, IPriceOracle {
    error NoPrice();

    mapping(address => uint256) private _prices;

    event PriceSet(address indexed asset, uint256 price);

    constructor(address guardian_) Guarded(guardian_) {}

    function setPrice(address asset, uint256 price) external onlyOwner {
        _prices[asset] = price;
        emit PriceSet(asset, price);
    }

    function priceOf(address asset) external view returns (uint256) {
        uint256 p = _prices[asset];
        if (p == 0) revert NoPrice();
        return p;
    }
}
