// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {BaseTest} from "./BaseTest.t.sol";
import "forge-std/Test.sol";

contract LoopingInteraction is BaseTest {

    address user1;
    address user2;

    uint256 a1;
    uint256 a2;

    function setUp() public override {
        super.setUp();

        user1 = makeAddr("user1");
        user2 = makeAddr("user2");

        a1 = 1e18;
        a2 = 2e18;

        weth.mint(user1, a1);
        assertEq(weth.balanceOf(user1), a1);
        weth.mint(user2, a2);
        assertEq(weth.balanceOf(user2), a2);


        // Mint WETH to both users
        vm.deal(user1, a1);
        vm.deal(user2, a2);
        assertEq(user1.balance, a1);
        assertEq(user2.balance, a2);
    }

    /// @notice Ensure only the configured vault address can call strategy methods.
    function test_onlyVault_can_call_strategy() public {
        address attacker = makeAddr("attacker");
        uint256 amount = 1 ether;

        // Mint some WETH to the attacker
        weth.mint(attacker, amount);
        // Attacker tries to call openPosition directly -> should revert
        vm.prank(attacker);
        vm.expectRevert(bytes("Strategy: caller is not vault"));
        strategy.openPosition(amount);

        // Attacker tries to call closePosition directly -> should revert
        vm.prank(attacker);
        vm.expectRevert(bytes("Strategy: caller is not vault"));
        strategy.closePosition(amount);
    }

    /// @notice Simulate two users depositing WETH to the vault (the test contract acts as the vault)
    /// and withdrawing later. This checks interaction between users, the vault and the strategy.
    function test_multiple_users_deposit_and_withdraw() public {
        

        assertEq(weth.balanceOf(address(strategy)), 0, "Strategy WETH balance should be zero at start");

        // User1 deposits 1 ETH via the looping vault
        vm.startPrank(user1);
        weth.approve(address(vault), a1);
        vault.deposit(a1, user1);
        vm.stopPrank();

        assertEq(weth.balanceOf(user1), 0, "User1 WETH balance should be zero after deposit");
        assertEq(vault.totalAssets(), a1, "Vault total assets should be a1 after user1 deposit");

        // Strategy should have deposited into eWeth
        assertEq(eVaultWeth.balanceOf(address(strategy)), a1);


        // User2 deposits 2 ETH via the looping vault
        vm.startPrank(user2);
        weth.approve(address(vault), a2);
        vault.deposit(a2, user2);
        vm.stopPrank();

        // Strategy now holds both deposits in eWeth 
        assertEq(eVaultWeth.balanceOf(address(strategy)), a1 + a2);

        // Total assets reported by strategy should match eWeth.convertToAssets(shares)
        uint256 shares = eVaultWeth.balanceOf(address(strategy));
        uint256 expectedAssets = eVaultWeth.convertToAssets(shares);
        assertEq(strategy.totalAssets(), expectedAssets);

        // Now simulate USER1 withdrawing their assets: vault asks strategy to close position
        vm.prank(user1);
        vault.withdraw(a1, user1, user1);

        // Vault should have received WETH back
        assertEq(user1.balance, a1, "User1 ETH balance should match a1 after withdrawal");

        // Strategy should have reduced its eWeth holdings
        assertEq(eVaultWeth.balanceOf(address(strategy)), a2, "Strategy eWeth balance should match a2 after user1 withdrawal");

        // Remaining assets on strategy should match a2
        uint256 remainingShares = eVaultWeth.balanceOf(address(strategy));
        uint256 remainingAssets = eVaultWeth.convertToAssets(remainingShares);
        assertEq(strategy.totalAssets(), remainingAssets);
        assertEq(remainingAssets, a2);
    }
}
