// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {KarmaFixture} from "./utils/KarmaFixture.sol";
import {Guarded} from "../src/Guarded.sol";
import {RiskParams} from "../src/RiskParams.sol";

contract RiskParamsTest is KarmaFixture {
    /// @dev Expected ratio at every 50 points across the range, written out by hand
    ///      rather than recomputed from the formula. A test that recomputes the thing
    ///      it is testing proves nothing.
    function test_ratioAtEvery50Points() public view {
        uint16[13] memory scores = [uint16(300), 350, 400, 450, 500, 550, 600, 650, 700, 750, 800, 850, 900];
        uint256[13] memory expected =
            [uint256(15000), 14667, 14334, 14000, 13667, 13334, 13000, 12667, 12334, 12000, 11667, 11334, 11000];

        for (uint256 i = 0; i < scores.length; i++) {
            assertEq(
                riskParams.collateralRatioBps(scores[i]),
                expected[i],
                string.concat("ratio wrong at score ", vm.toString(scores[i]))
            );
        }
    }

    function test_endpointsExact() public view {
        assertEq(riskParams.collateralRatioBps(300), 15000, "worst credit pays 150%");
        assertEq(riskParams.collateralRatioBps(900), 11000, "best credit pays 110%");
    }

    function test_boundsHoldAtEveryScoreInRange() public view {
        for (uint16 s = 300; s <= 900; s++) {
            uint256 r = riskParams.collateralRatioBps(s);
            assertLe(r, riskParams.ratioAtMinScore(), "above curve top");
            assertGe(r, riskParams.ratioAtMaxScore(), "below curve bottom");
            assertGe(r, riskParams.ABS_MIN_RATIO_BPS(), "below hard floor");
            assertLe(r, riskParams.ABS_MAX_RATIO_BPS(), "above hard ceiling");
        }
    }

    function test_liquidationRatioIsBelowBorrowRatioAndAboveFloor() public view {
        for (uint16 s = 300; s <= 900; s += 25) {
            uint256 borrowRatio = riskParams.collateralRatioBps(s);
            uint256 liq = riskParams.liquidationRatioBps(s);
            assertLt(liq, borrowRatio, "liquidation must sit below borrow ratio");
            assertGe(liq, riskParams.ABS_MIN_RATIO_BPS(), "liquidation below hard floor");
        }
    }

    function test_outOfRangeReverts() public {
        vm.expectRevert(RiskParams.ScoreOutOfRange.selector);
        riskParams.collateralRatioBps(299);

        vm.expectRevert(RiskParams.ScoreOutOfRange.selector);
        riskParams.collateralRatioBps(901);
    }

    // ---------------------------------------------------------------- fuzz

    /// @notice The property the pricing rests on: a better score never costs more collateral.
    function testFuzz_monotonic(uint16 lo, uint16 hi) public view {
        lo = uint16(bound(lo, 300, 900));
        hi = uint16(bound(hi, lo, 900));
        assertGe(
            riskParams.collateralRatioBps(lo),
            riskParams.collateralRatioBps(hi),
            "higher score must not require more collateral"
        );
    }

    function testFuzz_adjacentScoresNeverJump(uint16 score) public view {
        score = uint16(bound(score, 300, 899));
        uint256 here = riskParams.collateralRatioBps(score);
        uint256 next = riskParams.collateralRatioBps(score + 1);
        assertGe(here, next, "not monotonic across adjacent scores");
        // 4000 bps of drop spread over 600 points: at most 7 bps per step.
        assertLe(here - next, 7, "single-point step too large");
    }

    function testFuzz_inBounds(uint16 score) public view {
        score = uint16(bound(score, 300, 900));
        uint256 r = riskParams.collateralRatioBps(score);
        assertGe(r, 11000);
        assertLe(r, 15000);
    }

    /// @notice Monotonicity is a property of the curve shape, not of the default
    ///         numbers: it must survive any configuration governance can reach.
    function testFuzz_monotonicUnderAnyAdmissibleCurve(uint256 atMin, uint256 atMax, uint16 lo, uint16 hi) public {
        atMax = bound(atMax, riskParams.ABS_MIN_RATIO_BPS(), riskParams.ABS_MAX_RATIO_BPS() - 1);
        atMin = bound(atMin, atMax + 1, riskParams.ABS_MAX_RATIO_BPS());

        vm.prank(owner);
        riskParams.setCurve(atMin, atMax);

        lo = uint16(bound(lo, 300, 900));
        hi = uint16(bound(hi, lo, 900));

        uint256 rLo = riskParams.collateralRatioBps(lo);
        uint256 rHi = riskParams.collateralRatioBps(hi);
        assertGe(rLo, rHi, "monotonicity broken by a reachable curve");
        assertLe(rLo, atMin, "escaped configured top");
        assertGe(rHi, atMax, "escaped configured bottom");
        assertGe(rHi, riskParams.ABS_MIN_RATIO_BPS(), "escaped the hard floor");
    }

    // ---------------------------------------------------------------- governance

    function test_setCurve_onlyOwner() public {
        vm.prank(alice);
        vm.expectRevert(Guarded.NotOwner.selector);
        riskParams.setCurve(14000, 12000);
    }

    function test_setCurve_cannotBreachFloor() public {
        uint256 belowFloor = riskParams.ABS_MIN_RATIO_BPS() - 1;
        vm.prank(owner);
        vm.expectRevert(RiskParams.RatioOutOfBounds.selector);
        riskParams.setCurve(14000, belowFloor);
    }

    function test_setCurve_cannotBreachCeiling() public {
        uint256 aboveCeiling = riskParams.ABS_MAX_RATIO_BPS() + 1;
        vm.prank(owner);
        vm.expectRevert(RiskParams.RatioOutOfBounds.selector);
        riskParams.setCurve(aboveCeiling, 12000);
    }

    function test_setCurve_mustDecrease() public {
        vm.prank(owner);
        vm.expectRevert(RiskParams.CurveNotDecreasing.selector);
        riskParams.setCurve(12000, 12000);
    }

    function test_setLiquidationBuffer_cannotExceedTopRatio() public {
        uint256 tooBig = riskParams.ratioAtMaxScore();
        vm.prank(owner);
        vm.expectRevert(RiskParams.BufferTooLarge.selector);
        riskParams.setLiquidationBufferBps(tooBig);
    }

    function test_worstCaseIsTheTopOfTheCurve() public view {
        assertEq(riskParams.worstCaseRatioBps(), riskParams.collateralRatioBps(300));
        assertEq(riskParams.worstCaseLiquidationRatioBps(), riskParams.liquidationRatioBps(300));
    }
}
