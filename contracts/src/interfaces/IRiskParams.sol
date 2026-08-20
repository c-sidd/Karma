// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

interface IRiskParams {
    function collateralRatioBps(uint16 score) external view returns (uint256);
    function liquidationRatioBps(uint16 score) external view returns (uint256);
    function worstCaseRatioBps() external view returns (uint256);
    function worstCaseLiquidationRatioBps() external view returns (uint256);
    function MIN_SCORE() external view returns (uint16);
    function MAX_SCORE() external view returns (uint16);
}
