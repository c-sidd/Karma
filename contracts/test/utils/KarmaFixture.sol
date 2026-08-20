// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";

import {Guardian} from "../../src/Guardian.sol";

/// @notice Shared deployment helpers for the protocol's test suites.
abstract contract KarmaFixture is Test {
    Guardian internal guardian;

    address internal owner = makeAddr("owner");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public virtual {
        vm.warp(1_700_000_000);
        guardian = new Guardian(owner);
    }
}
