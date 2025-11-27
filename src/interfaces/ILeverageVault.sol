
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ILeverageStrategy} from "../strategy/ILeverageStrategy.sol";
import {IEVault} from "euler-vault-kit/src/EVault/IEVault.sol";

/// @notice Minimal interface for the `LeverageVault` ERC-4626 implementation used in this repo.
interface ILeverageVault {
	/// @notice Set the leverage strategy contract that will manage positions.
	function setStrategy(ILeverageStrategy _strategy) external;

	/// @notice The current leverage strategy in use.
	function strategy() external view returns (ILeverageStrategy);

	/// @notice Immutable reference to the Euler `EVault` wrapper used by the system.
	function EVAULT() external view returns (IEVault);
}
