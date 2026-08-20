// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

interface IGuardian {
    function owner() external view returns (address);
    function isGuardian(address account) external view returns (bool);
    function paused() external view returns (bool);
}
