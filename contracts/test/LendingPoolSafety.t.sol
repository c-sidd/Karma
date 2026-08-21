// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {KarmaFixture} from "./utils/KarmaFixture.sol";
import {LendingPool} from "../src/LendingPool.sol";

contract LendingPoolSafetyTest is KarmaFixture {
    uint256 internal constant TEN_ETH = 10 ether;

    function test_defundCannotWithdrawOutstandingPrincipal() public {
        fundCollateral(alice, TEN_ETH);
        attest(alice, 900);

        vm.prank(alice);
        pool.borrow(10_000e6);

        uint256 balance = usdc.balanceOf(address(pool));
        uint256 protectedPrincipal = 10_000e6;

        vm.prank(owner);
        vm.expectRevert(LendingPool.InsufficientReserves.selector);
        pool.defund(balance - protectedPrincipal + 1);

        vm.prank(owner);
        pool.defund(balance - protectedPrincipal);

        assertEq(usdc.balanceOf(address(pool)), protectedPrincipal);
    }

    function test_defundStillWorksWhenNoDebt() public {
        uint256 balance = usdc.balanceOf(address(pool));
        uint256 withdrawal = balance / 2;

        vm.prank(owner);
        pool.defund(withdrawal);

        assertEq(usdc.balanceOf(address(pool)), balance - withdrawal);
    }

    function test_zeroOraclePriceIsRejected() public {
        fundCollateral(alice, TEN_ETH);
        attest(alice, 900);

        vm.prank(owner);
        priceOracle.setPrice(address(weth), 0);

        vm.prank(alice);
        vm.expectRevert(LendingPool.InvalidPrice.selector);
        pool.borrow(1_000e6);
    }
}
