// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Strategy interface used by the looping vault to manage leveraged positions.
interface ILeverageStrategy {
    function openPosition(uint256 amount) external;

    function closePosition(uint256 assetsToReturn) external;

    /// @notice Returns the total net value (NAV) of the strategy, denominated in underlying units.
    /// @dev This is used by the ERC-4626 vault as `totalAssets()`.
    function totalAssets() external view returns (uint256);
}
