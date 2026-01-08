// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IEVault} from "euler-vault-kit/src/EVault/IEVault.sol";

interface ILeverageVault {
    function EVAULT() external view returns (IEVault);
}
