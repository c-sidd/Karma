// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {KarmaFixture} from "./utils/KarmaFixture.sol";
import {Guarded} from "../src/Guarded.sol";
import {LendingPool} from "../src/LendingPool.sol";
import {ScoreOracle} from "../src/ScoreOracle.sol";
import {Attestation} from "../src/types/Attestation.sol";

contract LendingPoolTest is KarmaFixture {
    // Redeclared locally: emit Contract.Event(...) needs solc >= 0.8.21.
    event Borrowed(address indexed user, uint256 amount, uint16 score, uint256 ratioBps);

    uint256 internal constant TEN_ETH = 10 ether; // $20,000 at the fixture price

    // ------------------------------------------------- the claim: no score, no loan

    function test_borrowWithoutAttestation_reverts() public {
        fundCollateral(alice, TEN_ETH);

        vm.prank(alice);
        vm.expectRevert(ScoreOracle.NoAttestation.selector);
        pool.borrow(1_000e6);
    }

    function test_borrowWithExpiredAttestation_reverts() public {
        fundCollateral(alice, TEN_ETH);
        Attestation memory a = attest(alice, 900);

        vm.warp(a.expiry);
        vm.prank(alice);
        vm.expectRevert(ScoreOracle.AttestationExpired.selector);
        pool.borrow(1_000e6);
    }

    function test_borrowWithRetiredModelVersion_reverts() public {
        fundCollateral(alice, TEN_ETH);
        attest(alice, 900);

        vm.prank(owner);
        oracle.setMinModelVersion(2);

        vm.prank(alice);
        vm.expectRevert(ScoreOracle.StaleModelVersion.selector);
        pool.borrow(1_000e6);
    }

    function test_attestationForSomeoneElseDoesNotHelp() public {
        fundCollateral(alice, TEN_ETH);
        attest(bob, 900); // bob is scored, alice is not

        vm.prank(alice);
        vm.expectRevert(ScoreOracle.NoAttestation.selector);
        pool.borrow(1_000e6);
    }

    // ------------------------------------------------- happy path

    function test_borrowSucceedsWithVerifiedScore() public {
        fundCollateral(alice, TEN_ETH);
        attest(alice, 900);

        uint256 before = usdc.balanceOf(alice);
        vm.prank(alice);
        pool.borrow(10_000e6);

        assertEq(usdc.balanceOf(alice) - before, 10_000e6, "borrower did not receive funds");
        assertEq(pool.debtOf(alice), 10_000e6, "debt not recorded");
        assertEq(pool.collateralOf(alice), TEN_ETH, "collateral should be untouched");
    }

    function test_borrowEmitsScoreAndRatio() public {
        fundCollateral(alice, TEN_ETH);
        attest(alice, 750);

        vm.expectEmit(true, false, false, true);
        emit Borrowed(alice, 5_000e6, 750, 12000);
        vm.prank(alice);
        pool.borrow(5_000e6);
    }

    /// @notice The product claim, as a test: the same collateral buys more credit at a
    ///         better score, and the difference is exactly the curve.
    function test_higherScoreBorrowsMore() public {
        fundCollateral(alice, TEN_ETH);
        fundCollateral(bob, TEN_ETH);
        attest(alice, 320);
        attest(bob, 880);

        uint256 aliceMax = pool.maxBorrowable(alice);
        uint256 bobMax = pool.maxBorrowable(bob);

        assertGt(bobMax, aliceMax, "better credit must buy more credit");
        // $20,000 of collateral at 148.67% (score 320) vs at 111.34% (score 880).
        assertEq(riskParams.collateralRatioBps(320), 14867);
        assertEq(riskParams.collateralRatioBps(880), 11134);
        assertEq(aliceMax, uint256(20_000e8) * 10_000 / 14867 * 1e6 / 1e8);
        assertEq(bobMax, uint256(20_000e8) * 10_000 / 11134 * 1e6 / 1e8);
    }

    // ------------------------------------------------- limits

    function test_borrowLimitEnforcedAtTheBoundary() public {
        fundCollateral(alice, TEN_ETH);
        attest(alice, 900);

        uint256 limit = pool.maxBorrowable(alice);

        vm.prank(alice);
        vm.expectRevert(LendingPool.InsufficientCollateral.selector);
        pool.borrow(limit + 1);

        vm.prank(alice);
        pool.borrow(limit);
        assertEq(pool.debtOf(alice), limit);
        assertEq(pool.maxBorrowable(alice), 0, "no headroom left at the limit");
    }

    function test_secondBorrowRespectsCumulativeLimit() public {
        fundCollateral(alice, TEN_ETH);
        attest(alice, 900);
        uint256 limit = pool.maxBorrowable(alice);

        vm.startPrank(alice);
        pool.borrow(limit / 2);
        vm.expectRevert(LendingPool.InsufficientCollateral.selector);
        pool.borrow(limit); // would exceed in aggregate
        pool.borrow(limit - limit / 2);
        vm.stopPrank();

        assertEq(pool.debtOf(alice), limit);
    }

    function test_perWalletBorrowCapEnforced() public {
        vm.prank(owner);
        pool.setMaxBorrowPerWallet(1_000e6);

        fundCollateral(alice, TEN_ETH);
        attest(alice, 900);

        vm.prank(alice);
        vm.expectRevert(LendingPool.BorrowCapExceeded.selector);
        pool.borrow(1_000e6 + 1);

        vm.prank(alice);
        pool.borrow(1_000e6);
    }

    function test_insufficientLiquidity_reverts() public {
        uint256 drain = usdc.balanceOf(address(pool)) - 100e6;
        vm.prank(owner);
        pool.defund(drain);

        fundCollateral(alice, TEN_ETH);
        attest(alice, 900);

        vm.prank(alice);
        vm.expectRevert(LendingPool.InsufficientLiquidity.selector);
        pool.borrow(101e6);
    }

    function test_borrowWithoutCollateral_reverts() public {
        attest(alice, 900);
        vm.prank(alice);
        vm.expectRevert(LendingPool.InsufficientCollateral.selector);
        pool.borrow(1e6);
    }

    function testFuzz_borrowNeverExceedsRatio(uint16 score, uint256 amount) public {
        score = uint16(bound(score, 300, 900));
        amount = bound(amount, 1e6, 50_000e6);

        fundCollateral(alice, TEN_ETH);
        attest(alice, score);

        uint256 ratioBps = riskParams.collateralRatioBps(score);
        uint256 capacity = (20_000e8 * 10_000) / ratioBps;
        bool shouldFit = (amount * 1e8 / 1e6) <= capacity;

        vm.prank(alice);
        if (shouldFit) {
            pool.borrow(amount);
            assertGe(pool.currentRatioBps(alice), ratioBps, "position below its own ratio");
        } else {
            vm.expectRevert(LendingPool.InsufficientCollateral.selector);
            pool.borrow(amount);
        }
    }

    // ------------------------------------------------- collateral

    function test_withdrawBlockedWhenItWouldBreachRatio() public {
        fundCollateral(alice, TEN_ETH);
        attest(alice, 900);

        vm.startPrank(alice);
        pool.borrow(10_000e6);

        // Needs 110% of $10,000 = $11,000 = 5.5 WETH. Leaving 5 WETH is not enough.
        vm.expectRevert(LendingPool.InsufficientCollateral.selector);
        pool.withdrawCollateral(5 ether);

        pool.withdrawCollateral(4 ether);
        vm.stopPrank();
        assertEq(pool.collateralOf(alice), 6 ether);
    }

    function test_withdrawWithExpiredScoreUsesWorstCaseRatio() public {
        fundCollateral(alice, TEN_ETH);
        Attestation memory a = attest(alice, 900);

        vm.prank(alice);
        pool.borrow(10_000e6);

        vm.warp(a.expiry);

        // At 150% the position needs $15,000 = 7.5 WETH, so 3 WETH may not leave.
        vm.prank(alice);
        vm.expectRevert(LendingPool.InsufficientCollateral.selector);
        pool.withdrawCollateral(3 ether);

        vm.prank(alice);
        pool.withdrawCollateral(2 ether);
        assertEq(pool.collateralOf(alice), 8 ether);
    }

    function test_debtFreeUserCanWithdrawEverything() public {
        fundCollateral(alice, TEN_ETH);
        vm.prank(alice);
        pool.withdrawCollateral(TEN_ETH);
        assertEq(pool.collateralOf(alice), 0);
        assertEq(weth.balanceOf(alice), TEN_ETH);
    }

    // ------------------------------------------------- repay and interest

    function test_repayReducesAndClearsDebt() public {
        fundCollateral(alice, TEN_ETH);
        attest(alice, 900);

        vm.startPrank(alice);
        pool.borrow(10_000e6);
        pool.repay(alice, 4_000e6);
        assertEq(pool.debtOf(alice), 6_000e6);

        usdc.approve(address(pool), type(uint256).max);
        pool.repay(alice, 6_000e6);
        vm.stopPrank();

        assertEq(pool.debtOf(alice), 0);
        assertEq(pool.scaledDebtOf(alice), 0, "dust left in scaled debt");
    }

    function test_repayMoreThanOwedOnlyTakesWhatIsOwed() public {
        fundCollateral(alice, TEN_ETH);
        attest(alice, 900);
        usdc.mint(alice, 5_000e6);

        vm.startPrank(alice);
        pool.borrow(10_000e6);
        uint256 balanceBefore = usdc.balanceOf(alice);
        pool.repay(alice, 15_000e6);
        vm.stopPrank();

        assertEq(pool.debtOf(alice), 0);
        assertEq(balanceBefore - usdc.balanceOf(alice), 10_000e6, "overpaid");
    }

    function test_interestAccrues() public {
        fundCollateral(alice, TEN_ETH);
        attest(alice, 900);

        vm.prank(alice);
        pool.borrow(10_000e6);
        assertEq(pool.debtOf(alice), 10_000e6);

        vm.warp(block.timestamp + 365 days);

        // 5% APR, linear.
        uint256 expected = 10_500e6;
        assertApproxEqRel(pool.debtOf(alice), expected, 1e15, "one year of interest");
        assertGt(pool.totalDebt(), 10_000e6);
    }

    function test_noInterestWithoutDebt() public {
        vm.warp(block.timestamp + 365 days);
        pool.accrue();
        assertEq(pool.borrowIndex(), pool.WAD(), "index moved with no debt outstanding");
    }

    function test_rateCeilingEnforced() public {
        uint256 tooHigh = pool.MAX_RATE_PER_SECOND_WAD() + 1;
        vm.prank(owner);
        vm.expectRevert(LendingPool.RateTooHigh.selector);
        pool.setRatePerSecondWad(tooHigh);
    }

    // ------------------------------------------------- liquidation

    function test_healthyPositionIsNotLiquidatable() public {
        fundCollateral(alice, TEN_ETH);
        attest(alice, 900);
        vm.prank(alice);
        pool.borrow(15_000e6);

        assertFalse(pool.isLiquidatable(alice));
        assertGt(pool.liquidationDistanceBps(alice), 0);

        usdc.mint(liquidator, 10_000e6);
        vm.startPrank(liquidator);
        usdc.approve(address(pool), type(uint256).max);
        vm.expectRevert(LendingPool.NotLiquidatable.selector);
        pool.liquidate(alice, 1_000e6);
        vm.stopPrank();
    }

    function test_priceDropMakesPositionLiquidatable() public {
        fundCollateral(alice, TEN_ETH);
        attest(alice, 900);
        vm.prank(alice);
        pool.borrow(18_000e6);

        assertFalse(pool.isLiquidatable(alice));

        vm.prank(owner);
        priceOracle.setPrice(address(weth), 1_800e8); // collateral now $18,000

        assertTrue(pool.isLiquidatable(alice));
        assertEq(pool.liquidationDistanceBps(alice), 0);

        usdc.mint(liquidator, 20_000e6);
        vm.startPrank(liquidator);
        usdc.approve(address(pool), type(uint256).max);

        uint256 wethBefore = weth.balanceOf(liquidator);
        pool.liquidate(alice, 5_000e6);
        vm.stopPrank();

        uint256 seized = weth.balanceOf(liquidator) - wethBefore;
        // $5,000 of debt repaid buys $5,250 of collateral at a 5% bonus.
        assertEq(seized, uint256(5_000e8) * 10_500 * 1e18 / (10_000 * 1_800e8));
        assertEq(pool.debtOf(alice), 13_000e6);
        assertEq(pool.collateralOf(alice), TEN_ETH - seized);
    }

    function test_closeFactorCapsLiquidation() public {
        fundCollateral(alice, TEN_ETH);
        attest(alice, 900);
        vm.prank(alice);
        pool.borrow(18_000e6);

        vm.prank(owner);
        priceOracle.setPrice(address(weth), 1_800e8);

        usdc.mint(liquidator, 20_000e6);
        vm.startPrank(liquidator);
        usdc.approve(address(pool), type(uint256).max);
        vm.expectRevert(LendingPool.CloseFactorExceeded.selector);
        pool.liquidate(alice, 9_000e6 + 1);
        pool.liquidate(alice, 9_000e6);
        vm.stopPrank();
    }

    // ------------------------------------------------- governance and guards

    function test_onlyOwnerCanFund() public {
        usdc.mint(alice, 1_000e6);
        vm.startPrank(alice);
        usdc.approve(address(pool), type(uint256).max);
        vm.expectRevert(Guarded.NotOwner.selector);
        pool.fund(1_000e6);
        vm.stopPrank();
    }

    function test_zeroAmountsRejected() public {
        vm.startPrank(alice);
        vm.expectRevert(LendingPool.ZeroAmount.selector);
        pool.depositCollateral(0);
        vm.expectRevert(LendingPool.ZeroAmount.selector);
        pool.borrow(0);
        vm.expectRevert(LendingPool.ZeroAmount.selector);
        pool.withdrawCollateral(0);
        vm.stopPrank();
    }

    function test_repayWithNoDebt_reverts() public {
        usdc.mint(alice, 1_000e6);
        vm.startPrank(alice);
        usdc.approve(address(pool), type(uint256).max);
        vm.expectRevert(LendingPool.NothingBorrowed.selector);
        pool.repay(alice, 1_000e6);
        vm.stopPrank();
    }

    function test_maxBorrowableIsZeroWithoutValidScore() public {
        fundCollateral(alice, TEN_ETH);
        assertEq(pool.maxBorrowable(alice), 0);
    }

    function test_maxBorrowableRespectsLiquidity() public {
        uint256 drain = usdc.balanceOf(address(pool)) - 500e6;
        vm.prank(owner);
        pool.defund(drain);

        fundCollateral(alice, TEN_ETH);
        attest(alice, 900);
        assertEq(pool.maxBorrowable(alice), 500e6);
    }
}
