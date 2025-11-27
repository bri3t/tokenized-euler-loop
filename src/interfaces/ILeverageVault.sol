
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IEVault} from "euler-vault-kit/src/EVault/IEVault.sol";

/// @notice Minimal interface for the `LeverageVault` ERC-4626 implementation used in this repo.
interface ILeverageVault {

	/// @notice Immutable reference to the Euler `EVault` wrapper used by the system.
	function EVAULT() external view returns (IEVault);
}
