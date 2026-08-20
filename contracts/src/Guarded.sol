// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {IGuardian} from "./interfaces/IGuardian.sol";

/// @notice Mixin giving a contract the Guardian's owner and pause state.
abstract contract Guarded {
    error NotOwner();
    error ProtocolPaused();
    error ZeroAddress();

    IGuardian public immutable guardian;

    constructor(address guardian_) {
        if (guardian_ == address(0)) revert ZeroAddress();
        guardian = IGuardian(guardian_);
    }

    modifier onlyOwner() {
        if (msg.sender != guardian.owner()) revert NotOwner();
        _;
    }

    modifier whenNotPaused() {
        if (guardian.paused()) revert ProtocolPaused();
        _;
    }

    function owner() public view returns (address) {
        return guardian.owner();
    }
}
