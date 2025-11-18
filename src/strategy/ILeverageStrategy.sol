// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Strategy interface used by the looping vault to manage leveraged positions.
interface ILeverageStrategy {
    /// @notice Called by the vault after receiving `amount` of underlying (WETH).
    /// @dev Implementation must move `amount` from the vault into the strategy and build the leveraged position.
    function openPosition(uint256 amount) external;

    /// @notice Called by the vault before sending `assetsToReturn` back to the user.
    /// @dev Implementation must unwind a proportional part of the leveraged position
    ///      and send exactly `assetsToReturn` underlying tokens back to the vault.
    function closePosition(uint256 assetsToReturn) external;

    /// @notice Returns the total net value (NAV) of the strategy, denominated in underlying units.
    /// @dev This is used by the ERC-4626 vault as `totalAssets()`.
    function totalAssets() external view returns (uint256);
}
