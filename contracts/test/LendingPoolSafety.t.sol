// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {KarmaFixture} from "./utils/KarmaFixture.sol";
import {LendingPool} from "../src/LendingPool.sol";

contract LendingPoolSafetyTest is KarmaFixture {
    uint256 internal constant TEN_ETH = 10 ether;

    function test_defundCannotWithdrawOutstandingPrincipal() public {
        fundCollateral(alice, TEN_ETH); attest(alice, 900);
        vm.prank(alice); pool.borrow(10_000e6);
        uint256 balance = usdc.balanceOf(address(pool)); uint256 protectedPrincipal = 10_000e6;
        vm.prank(owner); vm.expectRevert(LendingPool.InsufficientReserves.selector); pool.defund(balance - protectedPrincipal + 1);
        vm.prank(owner); pool.defund(balance - protectedPrincipal);
        assertEq(usdc.balanceOf(address(pool)), protectedPrincipal);
    }

    function test_defundStillWorksWhenNoDebt() public {
        uint256 balance = usdc.balanceOf(address(pool));
        vm.prank(owner); pool.defund(balance / 2);
        assertEq(usdc.balanceOf(address(pool)), balance / 2);
    }

    function test_zeroOraclePriceIsRejected() public {
        fundCollateral(alice, TEN_ETH); attest(alice, 900);
        vm.prank(owner); priceOracle.setPrice(address(weth), 0);
        vm.prank(alice); vm.expectRevert(LendingPool.InvalidPrice.selector); pool.borrow(1_000e6);
    }

    function test_tinyDebtCanBeLiquidated() public {
        fundCollateral(alice, TEN_ETH); attest(alice, 900);
        vm.prank(alice); pool.borrow(1);
        vm.prank(owner); priceOracle.setPrice(address(weth), 1e8);
        usdc.mint(liquidator, 1); vm.prank(liquidator); usdc.approve(address(pool), 1);
        vm.prank(liquidator); pool.liquidate(alice, 1);
        assertEq(pool.debtOf(alice), 0);
    }

    function testFuzz_repayNeverIncreasesDebt(uint256 borrowAmount, uint256 repayAmount) public {
        borrowAmount = bound(borrowAmount, 1e6, 50_000e6);
        repayAmount = bound(repayAmount, 1, borrowAmount);
        fundCollateral(alice, TEN_ETH); attest(alice, 900);
        vm.prank(alice); pool.borrow(borrowAmount);
        uint256 beforeDebt = pool.debtOf(alice);
        vm.prank(alice); pool.repay(alice, repayAmount);
        uint256 afterDebt = pool.debtOf(alice);
        assertLe(afterDebt, beforeDebt);
    }

    function testFuzz_fullRepaymentLeavesZeroDebt(uint256 borrowAmount) public {
        borrowAmount = bound(borrowAmount, 1e6, 50_000e6);
        fundCollateral(alice, TEN_ETH); attest(alice, 900);
        vm.prank(alice); pool.borrow(borrowAmount);
        uint256 debt = pool.debtOf(alice);
        vm.prank(alice); pool.repay(alice, debt);
        assertEq(pool.debtOf(alice), 0);
        assertEq(pool.scaledDebtOf(alice), 0);
    }

    function test_interestIndexNeverDecreases() public {
        fundCollateral(alice, TEN_ETH); attest(alice, 900);
        vm.prank(alice); pool.borrow(10_000e6);
        uint256 beforeIndex = pool.borrowIndex();
        vm.warp(block.timestamp + 30 days);
        pool.accrue();
        assertGe(pool.borrowIndex(), beforeIndex);
    }
}
