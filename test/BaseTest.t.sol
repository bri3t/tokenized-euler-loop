// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/* ------------------------ External Libraries ------------------------ */
import "forge-std/Test.sol";
import "forge-std/console2.sol";
import {DeployPermit2} from "permit2/test/utils/DeployPermit2.sol";


/* ------------------------ EVK Core Imports --------------------------- */
import {EVault} from "euler-vault-kit/src/EVault/EVault.sol";
import {GenericFactory} from "euler-vault-kit/src/GenericFactory/GenericFactory.sol";
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

import {EulerETHLeverageStrategy} from "../src/strategy/EulerETHLeverageStrategy.sol";
import {ISwapRouterV3} from "../src/interfaces/ISwapRouterV3.sol";

/* ------------------------ Mocks --------------------------- */
import {TestERC20} from "euler-vault-kit/test/mocks/TestERC20.sol";
import {MockBalanceTracker} from "euler-vault-kit/test/mocks/MockBalanceTracker.sol";
import {MockPriceOracle} from "euler-vault-kit/test/mocks/MockPriceOracle.sol";
import {IRMTestDefault} from "euler-vault-kit/test/mocks/IRMTestDefault.sol";
import {SequenceRegistry} from "euler-vault-kit/src/SequenceRegistry/SequenceRegistry.sol";

contract BaseTest is Test, DeployPermit2 {

    /* ================================================================
                             EVK State
       ================================================================ */

    EthereumVaultConnector public evc;
    ProtocolConfig protocolConfig;
    GenericFactory public factory;
    MockPriceOracle oracle;

    address admin;
    address feeReceiver;
    address protocolFeeReceiver;

    address sequenceRegistry;
    address balanceTracker;
    address permit2;
    address unitOfAccount;

    Base.Integrations integrations;
    Dispatch.DeployedModules modules;

    /* ================================================================
                            Tokens + EVaults
       ================================================================ */

    TestERC20 weth;
    TestERC20 usdc;

    IEVault public eVaultWeth;
    IEVault public eVaultUsdc;

    address initializeModule;
    address tokenModule;
    address vaultModule;
    address borrowingModule;
    address liquidationModule;
    address riskManagerModule;
    address balanceForwarderModule;
    address governanceModule;

    /* ================================================================
                              Strategy
       ================================================================ */

    EulerETHLeverageStrategy public strategy;

    address public vault; // In this test, vault = this contract

    ISwapRouterV3 public dummyRouter;

    function setUp() public virtual {
        /* ------------------------------
           EVK Standard Infra Deployment
        ------------------------------ */

        admin = vm.addr(1000);
        feeReceiver = makeAddr("feeReceiver");
        protocolFeeReceiver = makeAddr("protocolFeeReceiver");
        factory = new GenericFactory(admin);

        evc = new EthereumVaultConnector();
        protocolConfig = new ProtocolConfig(admin, protocolFeeReceiver);
        balanceTracker = address(new MockBalanceTracker());
        oracle = new MockPriceOracle();
        unitOfAccount = address(1);
        permit2 = deployPermit2();
        sequenceRegistry = address(new SequenceRegistry());


        // Build Integrations struct
        integrations = Base.Integrations({
            evc: address(evc),
            protocolConfig: address(protocolConfig),
            sequenceRegistry: sequenceRegistry,
            balanceTracker: balanceTracker,
            permit2: permit2
        });

        initializeModule = address(new Initialize(integrations));
        tokenModule      = address(new Token(integrations));
        vaultModule      = address(new Vault(integrations));
        borrowingModule  = address(new Borrowing(integrations));
        liquidationModule= address(new Liquidation(integrations));
        riskManagerModule= address(new RiskManager(integrations));
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

        // Deploy EVault Implementation
        address evaultImpl = address(new EVault(integrations, modules));

        vm.prank(admin);
        factory.setImplementation(evaultImpl);

        /* ------------------------------
           Deploy Underlying Assets
        ------------------------------ */

        weth = new TestERC20("Mock WETH", "WETH", 18, false);
        usdc = new TestERC20("Mock USDC", "USDC", 6, false);

        /* ------------------------------
           Create real EVault_WETH
        ------------------------------ */

        bytes memory wethInit = abi.encodePacked(
            address(weth),     
            address(oracle),   
            unitOfAccount      
        );

        eVaultWeth = IEVault(
            factory.createProxy(address(0), true, wethInit)
        );

        eVaultWeth.setHookConfig(address(0), 0);
        eVaultWeth.setInterestRateModel(address(new IRMTestDefault()));
        eVaultWeth.setMaxLiquidationDiscount(0.2e4);
        eVaultWeth.setFeeReceiver(feeReceiver);

        /* ------------------------------
           Create real EVault_USDC
        ------------------------------ */

        bytes memory usdcInit = abi.encodePacked(
            address(usdc),     // underlying
            address(oracle),   // priceOracle
            unitOfAccount
        );

        eVaultUsdc = IEVault(
            factory.createProxy(address(0), true, usdcInit)
        );

        eVaultUsdc.setHookConfig(address(0), 0);
        eVaultUsdc.setInterestRateModel(address(new IRMTestDefault()));
        eVaultUsdc.setMaxLiquidationDiscount(0.2e4);
        eVaultUsdc.setFeeReceiver(feeReceiver);

        /* ------------------------------
           Deploy Dummy Router (not swapping yet)
        ------------------------------ */

        dummyRouter = ISwapRouterV3(address(0)); // we do not test swaps yet

        /* ------------------------------
           Deploy Strategy
        ------------------------------ */
        vault = address(this);

        strategy = new EulerETHLeverageStrategy(
            address(weth),
            address(usdc),
            address(eVaultWeth),
            address(eVaultUsdc),
            address(dummyRouter),
            vault,
            1e18 // 1x leverage for now
        );
    }

    /* ================================================================
                               TESTS
       ================================================================ */

    function test_openPosition_into_real_eWeth() public {
        uint256 amount = 1 ether;

        // 1) Mint WETH to the "vault" (this test contract)
        weth.mint(vault, amount);

        // 2) Approve the strategy
        vm.prank(vault);
        weth.approve(address(strategy), amount);

        // 3) Call openPosition
        vm.prank(vault);
        strategy.openPosition(amount);

        // Vault should now have 0 WETH
        assertEq(weth.balanceOf(vault), 0);

        // Strategy should own shares in eVaultWeth
        uint256 shares = eVaultWeth.balanceOf(address(strategy));
        assertEq(shares, amount);

        // TotalAssets should match convertToAssets
        uint256 expected = eVaultWeth.convertToAssets(shares);
        assertEq(strategy.totalAssets(), expected);
    }

    function test_closePosition_returns_WETH() public {
        uint256 amount = 1 ether;

        // Open position
        weth.mint(vault, amount);
        vm.startPrank(vault);
        weth.approve(address(strategy), amount);
        strategy.openPosition(amount);
        vm.stopPrank();

        // Sanity checks
        assertEq(eVaultWeth.balanceOf(address(strategy)), amount);
        assertEq(weth.balanceOf(vault), 0);

        // Close
        vm.prank(vault);
        strategy.closePosition(amount);

        // Strategy no longer has shares
        assertEq(eVaultWeth.balanceOf(address(strategy)), 0);

        // Vault recovered the WETH
        assertEq(weth.balanceOf(vault), amount);

        // NAV must be 0
        assertEq(strategy.totalAssets(), 0);
    }
}
