// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IStrategyAdapter {
    function asset() external view returns (address);

    function totalAssets() external view returns (uint256);

    function afterDeposit(uint256 assets, bytes calldata data) external;

    function beforeWithdraw(uint256 assetsNeeded, bytes calldata data)
        external
        returns (uint256 assetsFreed, uint256 loss);
}
