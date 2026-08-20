// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Guarded} from "./Guarded.sol";

/// @title  RiskParams
/// @notice Turns a credit score into a collateral requirement.
///
/// @dev The curve is a straight line in integer arithmetic:
///
///        ratioBps(s) = ratioAtMinScore - ((s - MIN_SCORE) * (ratioAtMinScore - ratioAtMaxScore)) / SCORE_SPAN
///
///      Truncating division means the line is non-increasing in `s` for every
///      admissible configuration, which is what the monotonicity fuzz test pins down.
///      `model/risk_curve.py` implements the same expression with Python floor division
///      over non-negative integers, so the two agree exactly, not approximately.
///
///      Endpoints are governable but caged: no configuration can price a loan below
///      ABS_MIN_RATIO_BPS collateral, whatever the owner does.
contract RiskParams is Guarded {
    error RatioOutOfBounds();
    error CurveNotDecreasing();
    error ScoreOutOfRange();
    error BufferTooLarge();

    uint256 public constant BPS = 10_000;

    uint16 public constant MIN_SCORE = 300;
    uint16 public constant MAX_SCORE = 900;
    uint256 public constant SCORE_SPAN = uint256(MAX_SCORE - MIN_SCORE); // 600

    /// @notice Hard cage on the governable curve. 105% floor, 300% ceiling.
    uint256 public constant ABS_MIN_RATIO_BPS = 10_500;
    uint256 public constant ABS_MAX_RATIO_BPS = 30_000;

    /// @notice Collateral required at the bottom of the score range (worst credit).
    uint256 public ratioAtMinScore = 15_000; // 150%
    /// @notice Collateral required at the top of the score range (best credit).
    uint256 public ratioAtMaxScore = 11_000; // 110%
    /// @notice How far below the borrow ratio a position may drift before liquidation.
    uint256 public liquidationBufferBps = 500;

    event CurveSet(uint256 ratioAtMinScore, uint256 ratioAtMaxScore);
    event LiquidationBufferSet(uint256 bufferBps);

    constructor(address guardian_) Guarded(guardian_) {}

    // ---------------------------------------------------------------- pricing

    /// @notice Collateral ratio in bps required to borrow at `score`.
    /// @dev Reverts outside [MIN_SCORE, MAX_SCORE]: an out-of-range score is a bug
    ///      upstream, not something to silently clamp.
    function collateralRatioBps(uint16 score) public view returns (uint256) {
        if (score < MIN_SCORE || score > MAX_SCORE) revert ScoreOutOfRange();
        uint256 drop = ratioAtMinScore - ratioAtMaxScore;
        return ratioAtMinScore - ((uint256(score) - MIN_SCORE) * drop) / SCORE_SPAN;
    }

    /// @notice Ratio at which a position at `score` becomes liquidatable.
    function liquidationRatioBps(uint16 score) public view returns (uint256) {
        uint256 borrowRatio = collateralRatioBps(score);
        uint256 liq = borrowRatio - liquidationBufferBps;
        return liq < ABS_MIN_RATIO_BPS ? ABS_MIN_RATIO_BPS : liq;
    }

    /// @notice The most conservative ratio the current curve can produce.
    /// @dev Used by LendingPool for health checks when a borrower has no valid
    ///      attestation: absent evidence, assume the worst credit.
    function worstCaseRatioBps() external view returns (uint256) {
        return ratioAtMinScore;
    }

    function worstCaseLiquidationRatioBps() external view returns (uint256) {
        return liquidationRatioBps(MIN_SCORE);
    }

    // ------------------------------------------------------------- governance

    function setCurve(uint256 atMinScore, uint256 atMaxScore) external onlyOwner {
        if (atMinScore > ABS_MAX_RATIO_BPS || atMaxScore < ABS_MIN_RATIO_BPS) revert RatioOutOfBounds();
        if (atMinScore <= atMaxScore) revert CurveNotDecreasing();
        ratioAtMinScore = atMinScore;
        ratioAtMaxScore = atMaxScore;
        emit CurveSet(atMinScore, atMaxScore);
    }

    function setLiquidationBufferBps(uint256 bufferBps) external onlyOwner {
        // The buffer may not be able to push the liquidation ratio below the cage floor
        // by more than the cage allows, and may never exceed the top-of-curve ratio.
        if (bufferBps >= ratioAtMaxScore) revert BufferTooLarge();
        liquidationBufferBps = bufferBps;
        emit LiquidationBufferSet(bufferBps);
    }
}
