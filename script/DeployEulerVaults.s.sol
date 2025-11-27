// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console2.sol";

import {ProtocolConfig} from "euler-vault-kit/src/ProtocolConfig/ProtocolConfig.sol";
import {EVault} from "euler-vault-kit/src/EVault/EVault.sol";
import {IEVault} from "euler-vault-kit/src/EVault/IEVault.sol";
import {GenericFactory} from "euler-vault-kit/src/GenericFactory/GenericFactory.sol";

import {Dispatch} from "euler-vault-kit/src/EVault/Dispatch.sol";
import {Base} from "euler-vault-kit/src/EVault/shared/Base.sol";

import {Initialize} from "euler-vault-kit/src/EVault/modules/Initialize.sol";
import {Token} from "euler-vault-kit/src/EVault/modules/Token.sol";
import {Vault} from "euler-vault-kit/src/EVault/modules/Vault.sol";
import {Borrowing} from "euler-vault-kit/src/EVault/modules/Borrowing.sol";
import {Liquidation} from "euler-vault-kit/src/EVault/modules/Liquidation.sol";
import {BalanceForwarder} from "euler-vault-kit/src/EVault/modules/BalanceForwarder.sol";
import {Governance} from "euler-vault-kit/src/EVault/modules/Governance.sol";
import {RiskManager} from "euler-vault-kit/src/EVault/modules/RiskManager.sol";

import {EthereumVaultConnector} from "ethereum-vault-connector/EthereumVaultConnector.sol";

// Reuse EVK test mocks for dev deployment
import {MockBalanceTracker} from "euler-vault-kit/test/mocks/MockBalanceTracker.sol";
import {MockPriceOracle} from "euler-vault-kit/test/mocks/MockPriceOracle.sol";
import {IRMTestDefault} from "euler-vault-kit/test/mocks/IRMTestDefault.sol";
import {SequenceRegistry} from "euler-vault-kit/src/SequenceRegistry/SequenceRegistry.sol";

import {console2} from "forge-std/console2.sol";

contract DeployEulerVaults is Script {

    address public constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(pk);

        address admin = vm.addr(pk);
        address protocolFeeReceiver = admin;

        // Core protocol components

        ProtocolConfig protocolConfig = new ProtocolConfig(admin, protocolFeeReceiver);

        EthereumVaultConnector evc = new EthereumVaultConnector();

        // Unit of account and auxiliary integrations
        address unitOfAccount = address(1); // simple placeholder used in EVK tests
        address balanceTracker = address(new MockBalanceTracker());
        address sequenceRegistry = address(new SequenceRegistry());
        address permit2 = address(0); // not needed for basic dev flows

        MockPriceOracle oracle = new MockPriceOracle();

        Base.Integrations memory integrations = Base.Integrations({
            evc: address(evc),
            protocolConfig: address(protocolConfig),
            sequenceRegistry: sequenceRegistry,
            balanceTracker: balanceTracker,
            permit2: permit2
        });

        // Deploy EVault modules and implementation

        Initialize initializeModule = new Initialize(integrations);
        Token tokenModule           = new Token(integrations);
        Vault vaultModule           = new Vault(integrations);
        Borrowing borrowingModule   = new Borrowing(integrations);
        Liquidation liquidationModule = new Liquidation(integrations);
        RiskManager riskManagerModule = new RiskManager(integrations);
        BalanceForwarder balanceForwarderModule = new BalanceForwarder(integrations);
        Governance governanceModule = new Governance(integrations);

        Dispatch.DeployedModules memory modules = Dispatch.DeployedModules({
            initialize: address(initializeModule),
            token: address(tokenModule),
            vault: address(vaultModule),
            borrowing: address(borrowingModule),
            liquidation: address(liquidationModule),
            riskManager: address(riskManagerModule),
            balanceForwarder: address(balanceForwarderModule),
            governance: address(governanceModule)
        });

        // EVault implementation contract
        EVault evaultImpl = new EVault(integrations, modules);


        GenericFactory factory = new GenericFactory(admin);
        factory.setImplementation(address(evaultImpl));


        bytes memory wethInitData = abi.encodePacked(
            WETH,
            address(oracle),
            unitOfAccount
        );

        address eWethProxy = factory.createProxy(
            address(0), // implementation is taken from factory's stored impl
            true,       // upgradeable (BeaconProxy)
            wethInitData
        );

        IEVault eWeth = IEVault(eWethProxy);

        eWeth.setHookConfig(address(0), 0);
        eWeth.setInterestRateModel(address(new IRMTestDefault()));
        eWeth.setMaxLiquidationDiscount(0.2e4); // 20% in EVK's format
        eWeth.setFeeReceiver(protocolFeeReceiver);

        /* --------------------------------------------------------------
           Deploy EVault_USDC
           -------------------------------------------------------------- */

        bytes memory usdcInitData = abi.encodePacked(
            USDC,
            address(oracle),
            unitOfAccount
        );

        address eUsdcProxy = factory.createProxy(
            address(0),
            true,
            usdcInitData
        );

        IEVault eUsdc = IEVault(eUsdcProxy);

        eUsdc.setHookConfig(address(0), 0);
        eUsdc.setInterestRateModel(address(new IRMTestDefault()));
        eUsdc.setMaxLiquidationDiscount(0.2e4);
        eUsdc.setFeeReceiver(protocolFeeReceiver);


        console2.log("Admin:           ", admin);
        console2.log("ProtocolConfig:  ", address(protocolConfig));
        console2.log("EVC:             ", address(evc));
        console2.log("Oracle:          ", address(oracle));
        console2.log("Factory:         ", address(factory));
        console2.log("EVault_WETH:     ", eWethProxy);
        console2.log("EVault_USDC:     ", eUsdcProxy);

        vm.stopBroadcast();
    }
}
