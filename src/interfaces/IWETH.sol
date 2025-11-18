// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Minimal WETH interface used to wrap/unwrap ETH.
interface IWETH {
    function deposit() external payable;
    function withdraw(uint256) external;
}
