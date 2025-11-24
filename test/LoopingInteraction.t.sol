// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {BaseTest} from "./BaseTest.t.sol";
import "forge-std/Test.sol";

contract LoopingInteraction is BaseTest {

    function setUp() public override {
        super.setUp();
    }

    /// @notice Ensure only the configured vault address can call strategy methods.
    function test_onlyVault_can_call_strategy() public {
        address attacker = makeAddr("attacker");
        uint256 amount = 1 ether;

        // Mint some WETH to the attacker
        // weth.mint(attacker, amount);
        vm.deal(attacker, 1 ether);
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
        address user1 = makeAddr("user1");
        address user2 = makeAddr("user2");

        uint256 a1 = 1 ether;
        uint256 a2 = 2 ether;

        // Mint WETH to both users
        vm.deal(user1, a1);
        vm.deal(user2, a2);
        assertEq(user1.balance, a1);
        assertEq(user2.balance, a2);

        // USER1 approves the vault and the vault pulls WETH 
        // Using `setAllowance` on the mock to avoid transfer/allowance edge-cases
        // weth.setAllowance(user1, vault, a1);

        vm.prank(user1);
        

        vm.prank(vault);
        weth.transferFrom(user1, vault, a1);
        assertEq(weth.balanceOf(vault), a1);

        // Now the vault forwards to strategy (vault calls strategy.openPosition)
        // Vault must approve the strategy to pull the WETH it holds
        vm.prank(vault);
        weth.approve(address(strategy), a1);

        vm.prank(vault);
        strategy.openPosition(a1);

        // Strategy should have deposited into eWeth
        assertEq(eVaultWeth.balanceOf(address(strategy)), a1);
        assertEq(weth.balanceOf(vault), 0);

        // USER2 approves and vault pulls WETH
        weth.setAllowance(user2, vault, a2);
        vm.prank(vault);
        weth.transferFrom(user2, vault, a2);
        assertEq(weth.balanceOf(vault), a2);

        // Vault approves strategy for the second deposit as well
        vm.prank(vault);
        weth.approve(address(strategy), a2);

        vm.prank(vault);
        strategy.openPosition(a2);

        // Strategy now holds both deposits in eWeth (no leverage mode)
        assertEq(eVaultWeth.balanceOf(address(strategy)), a1 + a2);

        // Total assets reported by strategy should match eWeth.convertToAssets(shares)
        uint256 shares = eVaultWeth.balanceOf(address(strategy));
        uint256 expectedAssets = eVaultWeth.convertToAssets(shares);
        assertEq(strategy.totalAssets(), expectedAssets);

        // Now simulate USER1 withdrawing their assets: vault asks strategy to close position
        // For simplicity we return `a1` back to the vault, then vault sends to user1.
        vm.prank(vault);
        strategy.closePosition(a1);

        // Vault should have received WETH back
        assertEq(weth.balanceOf(vault), a1);

        // Strategy should have reduced its eWeth holdings
        assertEq(eVaultWeth.balanceOf(address(strategy)), a2);

        // Vault sends withdrawn WETH to user1
        vm.prank(vault);
        weth.transfer(user1, a1);

        assertEq(weth.balanceOf(user1), a1);

        // Remaining assets on strategy should match a2
        uint256 remainingShares = eVaultWeth.balanceOf(address(strategy));
        uint256 remainingAssets = eVaultWeth.convertToAssets(remainingShares);
        assertEq(strategy.totalAssets(), remainingAssets);
        assertEq(remainingAssets, a2);
    }
}
