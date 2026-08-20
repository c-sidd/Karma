// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

/// @title  Guardian
/// @notice Single source of authority for the Karma protocol: one owner, a set of
///         pause-only guardians, and one protocol-wide pause switch.
/// @dev    Deployed once. ScoreOracle, RiskParams and LendingPool read from it rather
///         than each keeping their own owner, so there is exactly one key to rotate.
contract Guardian {
    error NotOwner();
    error NotGuardian();
    error NotPendingOwner();
    error ZeroAddress();

    address public owner;
    address public pendingOwner;
    bool public paused;

    mapping(address => bool) public isGuardian;

    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event GuardianSet(address indexed account, bool allowed);
    event PauseSet(bool paused, address indexed by);

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(address owner_) {
        if (owner_ == address(0)) revert ZeroAddress();
        owner = owner_;
        isGuardian[owner_] = true;
        emit OwnershipTransferred(address(0), owner_);
        emit GuardianSet(owner_, true);
    }

    /// @notice Two-step handover. A typo in `newOwner` does not brick the protocol.
    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotPendingOwner();
        address previous = owner;
        owner = pendingOwner;
        pendingOwner = address(0);
        emit OwnershipTransferred(previous, owner);
    }

    function setGuardian(address account, bool allowed) external onlyOwner {
        if (account == address(0)) revert ZeroAddress();
        isGuardian[account] = allowed;
        emit GuardianSet(account, allowed);
    }

    /// @notice Any guardian can stop the protocol. Only the owner can restart it.
    ///         Asymmetric on purpose: pausing is a fire alarm, unpausing is a decision.
    function pause() external {
        if (!isGuardian[msg.sender]) revert NotGuardian();
        paused = true;
        emit PauseSet(true, msg.sender);
    }

    function unpause() external onlyOwner {
        paused = false;
        emit PauseSet(false, msg.sender);
    }
}
