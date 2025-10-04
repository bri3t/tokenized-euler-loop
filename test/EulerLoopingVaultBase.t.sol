// SPDX-License-Identifier: GPL-2.0-or-later

pragma solidity ^0.8.30;

import {Test, console2, stdError} from "forge-std/Test.sol";
import {DeployPermit2} from "permit2/test/utils/DeployPermit2.sol";

import {GenericFactory} from "euler-vault-kit/src/GenericFactory/GenericFactory.sol";

import {EVault} from "euler-vault-kit/src/EVault/EVault.sol";
import {ProtocolConfig} from "euler-vault-kit/src/ProtocolConfig/ProtocolConfig.sol";

import {Dispatch} from "euler-vault-kit/src/EVault/Dispatch.sol";

import {Initialize} from "euler-vault-kit/src/EVault/modules/Initialize.sol";
import {Token} from "euler-vault-kit/src/EVault/modules/Token.sol";
import {Vault} from "euler-vault-kit/src/EVault/modules/Vault.sol";
import {Borrowing} from "euler-vault-kit/src/EVault/modules/Borrowing.sol";
import {Liquidation} from "euler-vault-kit/src/EVault/modules/Liquidation.sol";
import {BalanceForwarder} from "euler-vault-kit/src/EVault/modules/BalanceForwarder.sol";
import {Governance} from "euler-vault-kit/src/EVault/modules/Governance.sol";
import {RiskManager} from "euler-vault-kit/src/EVault/modules/RiskManager.sol";

import {IEVault, IERC20} from "euler-vault-kit/src/EVault/IEVault.sol";
import {TypesLib} from "euler-vault-kit/src/EVault/shared/types/Types.sol";
import {Base} from "euler-vault-kit/src/EVault/shared/Base.sol";

import {EthereumVaultConnector} from "ethereum-vault-connector/EthereumVaultConnector.sol";

import {TestERC20} from "euler-vault-kit/test/mocks/TestERC20.sol";
import {MockBalanceTracker} from "euler-vault-kit/test/mocks/MockBalanceTracker.sol";
import {MockPriceOracle} from "euler-vault-kit/test/mocks/MockPriceOracle.sol";
import {IRMTestDefault} from "euler-vault-kit/test/mocks/IRMTestDefault.sol";
import {IHookTarget} from "euler-vault-kit/src/interfaces/IHookTarget.sol";
import {SequenceRegistry} from "euler-vault-kit/src/SequenceRegistry/SequenceRegistry.sol";

import {AssertionsCustomTypes} from "euler-vault-kit/test/helpers/AssertionsCustomTypes.sol";


import "euler-vault-kit/src/EVault/shared/Constants.sol";
import {Errors} from "euler-vault-kit/src/EVault/shared/Errors.sol";

contract EulerLoopingVaultTest is Test, AssertionsCustomTypes, DeployPermit2 {
    EthereumVaultConnector public evc;

    address admin;
    address feeReceiver;
    address protocolFeeReceiver;
    ProtocolConfig protocolConfig;
    address balanceTracker;
    MockPriceOracle oracle;
    address unitOfAccount;
    address permit2;
    address sequenceRegistry;
    GenericFactory public factory;

    Base.Integrations integrations;
    Dispatch.DeployedModules modules;

    TestERC20 assetTST;
    TestERC20 assetTST2;

    IEVault public eTST;
    IEVault public eTST2;

    address initializeModule;
    address tokenModule;
    address vaultModule;
    address borrowingModule;
    address liquidationModule;
    address riskManagerModule;
    address balanceForwarderModule;
    address governanceModule;



    function setUp() public virtual {
       
        admin = vm.addr(1000);
        feeReceiver = makeAddr("feeReceiver");
        protocolFeeReceiver = makeAddr("protocolFeeReceiver");
    
        factory = new GenericFactory(admin);
        evc = new EthereumVaultConnector();
        protocolConfig = new ProtocolConfig(admin, feeReceiver);
        // balanceTracker = address(new MockBalanceTracker());
        balanceTracker = address(0);
        oracle = new MockPriceOracle();
        unitOfAccount = address(1);
        permit2 = deployPermit2();
        sequenceRegistry = address(new SequenceRegistry());
        integrations =
            Base.Integrations(address(evc), address(protocolConfig), sequenceRegistry, balanceTracker, permit2);
        
        initializeModule = address(new Initialize(integrations));
        tokenModule = address(new Token(integrations));
        vaultModule = address(new Vault(integrations));
        borrowingModule = address(new Borrowing(integrations));
        // borrowingModule = address(0);
        liquidationModule = address(new Liquidation(integrations));
        riskManagerModule = address(new RiskManager(integrations));
        balanceForwarderModule = address(new BalanceForwarder(integrations));
        governanceModule = address(new Governance(integrations));


        modules = Dispatch.DeployedModules({
            initialize: initializeModule,
            token: tokenModule,
            vault: vaultModule,
            borrowing: borrowingModule,
            liquidation: liquidationModule,
            riskManager: riskManagerModule,
            balanceForwarder: balanceForwarderModule,
            governance: governanceModule
        });

        address evaultImpl;
        evaultImpl = address(new EVault(integrations, modules));


        vm.prank(admin);
        factory.setImplementation(evaultImpl);

        assetTST = new TestERC20("Test Token", "TST", 18, false);
        assetTST2 = new TestERC20("Test Token 2", "TST2", 18, false);


        eTST = IEVault(
            factory.createProxy(address(0), false, abi.encodePacked(address(assetTST), address(oracle), unitOfAccount))
        );

        eTST.setHookConfig(address(0), 0);
        eTST.setInterestRateModel(address(new IRMTestDefault()));
        eTST.setMaxLiquidationDiscount(0.2e4);
        eTST.setFeeReceiver(feeReceiver);

        oracle.setPrice(address(assetTST), unitOfAccount, 1e18);
        oracle.setPrice(address(assetTST2), unitOfAccount, 1e18);

        eTST.setLTV(address(eTST2), 0.9e4, 0.9e4, 0);

        eTST2 = IEVault(
            factory.createProxy(address(0), true, abi.encodePacked(address(assetTST2), address(oracle), unitOfAccount))
        );
        // eTST2.setHookConfig(address(0), 0);
        uint32 mask =
            OP_BORROW | OP_REPAY |OP_REPAY_WITH_SHARES | OP_FLASHLOAN; 

        eTST2.setHookConfig(address(0), mask);
        eTST2.setInterestRateModel(address(new IRMTestDefault()));
        eTST2.setMaxLiquidationDiscount(0.2e4);
        eTST2.setFeeReceiver(feeReceiver);

      
    }


    
}