// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {VaultWithAdapter4626} from "../src/VaultWithAdapter4626.sol";



contract DeployPassthrough is Script {
    function run() external {
        // Rellena estos valores:
        address asset = vm.envAddress("ASSET_ADDRESS");
        string memory name = vm.envString("VAULT_NAME");
        string memory symbol = vm.envString("VAULT_SYMBOL");


        vm.startBroadcast();

        VaultWithAdapter4626 vault = new VaultWithAdapter4626(
            IERC20(asset),
            name,
            symbol,
            msg.sender // owner
        );

        // Opcional: cap inicial
        // vault.setDepositCap(1_000_000e18);

        vm.stopBroadcast();
    }
}
