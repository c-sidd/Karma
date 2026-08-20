// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {KarmaFixture} from "./utils/KarmaFixture.sol";
import {Guardian} from "../src/Guardian.sol";

contract GuardianTest is KarmaFixture {
    function test_deployerSetsOwnerAndFirstGuardian() public view {
        assertEq(guardian.owner(), owner);
        assertTrue(guardian.isGuardian(owner));
        assertFalse(guardian.paused());
    }

    function test_constructorRejectsZeroOwner() public {
        vm.expectRevert(Guardian.ZeroAddress.selector);
        new Guardian(address(0));
    }

    function test_ownershipTransferIsTwoStep() public {
        vm.prank(owner);
        guardian.transferOwnership(alice);

        // Not owner yet: a mistyped address does not brick the protocol.
        assertEq(guardian.owner(), owner);
        assertEq(guardian.pendingOwner(), alice);

        vm.prank(bob);
        vm.expectRevert(Guardian.NotPendingOwner.selector);
        guardian.acceptOwnership();

        vm.prank(alice);
        guardian.acceptOwnership();
        assertEq(guardian.owner(), alice);
        assertEq(guardian.pendingOwner(), address(0));
    }

    function test_onlyOwnerCanTransfer() public {
        vm.prank(alice);
        vm.expectRevert(Guardian.NotOwner.selector);
        guardian.transferOwnership(alice);
    }

    function test_guardianCanPauseButNotUnpause() public {
        vm.prank(owner);
        guardian.setGuardian(bob, true);

        vm.prank(bob);
        guardian.pause();
        assertTrue(guardian.paused());

        vm.prank(bob);
        vm.expectRevert(Guardian.NotOwner.selector);
        guardian.unpause();

        vm.prank(owner);
        guardian.unpause();
        assertFalse(guardian.paused());
    }

    function test_nonGuardianCannotPause() public {
        vm.prank(alice);
        vm.expectRevert(Guardian.NotGuardian.selector);
        guardian.pause();
    }

    function test_revokedGuardianCannotPause() public {
        vm.startPrank(owner);
        guardian.setGuardian(bob, true);
        guardian.setGuardian(bob, false);
        vm.stopPrank();

        vm.prank(bob);
        vm.expectRevert(Guardian.NotGuardian.selector);
        guardian.pause();
    }

    function test_pauseStopsBorrowAcrossProtocol() public {
        fundCollateral(alice, 10 ether);
        attest(alice, 800);

        vm.prank(owner);
        guardian.pause();

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("ProtocolPaused()"));
        pool.borrow(1_000e6);
    }
}
