// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {UnitBaseTest} from "../UnitBaseTest.t.sol";
import "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title Deposit Tests
/// @notice Tests for deposit functionality and basic redeem operations
contract VaultFlows is UnitBaseTest {
    function setUp() public override {
        super.setUp();
    }

    /// @notice Fuzz: single user deposit and full redeem across varied amounts
    function testFuzz_deposit_and_redeem(uint256 amount) public {
        amount = bound(amount, 1, 1e23);

        address user = makeAddr("fuzzUser");

        cToken.mint(user, amount);
        vm.startPrank(user);
        cToken.approve(address(vault), amount);

        uint256 previewShares = vault.previewDeposit(amount);
        uint256 shares = vault.deposit(amount, user);
        vm.stopPrank();

        assertApproxEqAbs(shares, previewShares, 1, "shares != previewDeposit");

        // Sanity: position is levered
        assertGt(cEVault.convertToAssets(cEVault.balanceOf(address(vault))), 0);
        assertGt(dEVault.debtOf(address(vault)), 0);

        // Redeem all shares
        vm.startPrank(user);
        uint256 balBefore = cToken.balanceOf(user);
        vault.redeem(shares, user, user);
        uint256 balAfter = cToken.balanceOf(user);
        vm.stopPrank();

        assertApproxEqAbs(balAfter, balBefore + amount, 1, "redeem amount mismatch");

        // Vault cleanup
        assertApproxEqAbs(cToken.balanceOf(address(vault)), 0, 1, "residual cToken");
        assertApproxEqAbs(dToken.balanceOf(address(vault)), 0, 1, "residual dToken");
        assertApproxEqAbs(dEVault.debtOf(address(vault)), 0, 1, "residual debt");
    }

    /// @notice Fuzz: proportional unwind for random dual-user deposits
    function testFuzz_redeem_proportional(uint256 aDeposit, uint256 bDeposit) public {
        aDeposit = bound(aDeposit, 1, 1e22);
        bDeposit = bound(bDeposit, 1, 1e22);

        address a = makeAddr("fuzzA");
        address b = makeAddr("fuzzB");

        // User A deposits
        cToken.mint(a, aDeposit);
        vm.startPrank(a);
        cToken.approve(address(vault), aDeposit);
        uint256 aShares = vault.deposit(aDeposit, a);
        vm.stopPrank();

        // User B deposits
        cToken.mint(b, bDeposit);
        vm.startPrank(b);
        cToken.approve(address(vault), bDeposit);
        uint256 bShares = vault.deposit(bDeposit, b);
        vm.stopPrank();

        uint256 totalShares = vault.totalSupply();
        assertEq(totalShares, aShares + bShares, "total shares mismatch");

        uint256 cBefore = cEVault.convertToAssets(cEVault.balanceOf(address(vault)));
        uint256 dBefore = dEVault.debtOf(address(vault));
        assertGt(cBefore, 0);
        assertGt(dBefore, 0);

        // Expected proportional removal for user A
        uint256 expC = Math.mulDiv(cBefore, aShares, totalShares);
        uint256 expD = Math.mulDiv(dBefore, aShares, totalShares);

        // A fully redeems
        vm.startPrank(a);
        vault.redeem(aShares, a, a);
        vm.stopPrank();

        uint256 cAfter = cEVault.convertToAssets(cEVault.balanceOf(address(vault)));
        uint256 dAfter = dEVault.debtOf(address(vault));

        uint256 actC = cBefore - cAfter;
        uint256 actD = dBefore - dAfter;

        // Tolerances account for rounding errors
        // Higher tolerance for debt due to Ceil rounding in extreme redemption scenarios
        // Use max(0.5% of expD, 10000) to ensure minimum tolerance
        uint256 debtTolerance = expD / 200; // 0.5%
        if (debtTolerance < 10000) {
            debtTolerance = 10000;
        }
        assertApproxEqAbs(actC, expC, 1e6, "collateral not proportional");
        assertApproxEqAbs(actD, expD, debtTolerance, "debt not proportional");

        // Only B remains
        assertEq(vault.totalSupply(), bShares, "remaining supply != b shares");
    }

    /// @notice Unit: redeem reduces position proportionally
    function test_redeem_reduces_position_proportionally() public {
        uint256 a1 = 2e18;
        uint256 a2 = 4e18;
        address user1 = makeAddr("user1");
        address user2 = makeAddr("user2");

        // Setup
        cToken.mint(user1, a1);
        vm.startPrank(user1);
        cToken.approve(address(vault), a1);
        uint256 user1Shares = vault.deposit(a1, user1);
        vm.stopPrank();

        cToken.mint(user2, a2);
        vm.startPrank(user2);
        cToken.approve(address(vault), a2);
        uint256 user2Shares = vault.deposit(a2, user2);
        vm.stopPrank();

        uint256 totalSharesBefore = vault.totalSupply();
        assertEq(totalSharesBefore, user1Shares + user2Shares);

        uint256 cBefore = cEVault.convertToAssets(cEVault.balanceOf(address(vault)));
        uint256 dBefore = dEVault.debtOf(address(vault));
        assertGt(cBefore, 0);
        assertGt(dBefore, 0);

        uint256 expectedCRemoved = Math.mulDiv(cBefore, user1Shares, totalSharesBefore);
        uint256 expectedDRemoved = Math.mulDiv(dBefore, user1Shares, totalSharesBefore);

        // User1 exits
        vm.startPrank(user1);
        vault.redeem(user1Shares, user1, user1);
        vm.stopPrank();

        uint256 cAfter = cEVault.convertToAssets(cEVault.balanceOf(address(vault)));
        uint256 dAfter = dEVault.debtOf(address(vault));

        uint256 actualCRemoved = cBefore - cAfter;
        uint256 actualDRemoved = dBefore - dAfter;

        assertApproxEqAbs(actualCRemoved, expectedCRemoved, 1e6, "collateral removal not proportional");
        assertApproxEqAbs(actualDRemoved, expectedDRemoved, 1, "debt removal not proportional");

        // Only user2 remains
        assertEq(vault.totalSupply(), user2Shares, "remaining supply != user2 shares");
    }

    /// @notice Integration: basic 2-users deposit/withdraw flow
    function test_multiple_users_deposit_and_withdraw() public {
        uint256 a1 = 2e18;
        uint256 a2 = 4e18;

        // User 1 deposits
        vm.startPrank(user1);
        uint256 expectedUser1Shares = vault.previewDeposit(a1);
        cToken.approve(address(vault), a1);
        uint256 user1Shares = vault.deposit(a1, user1);
        vm.stopPrank();

        assertEq(user1Shares, expectedUser1Shares, "user1 shares != previewDeposit");

        // User 2 deposits
        vm.startPrank(user2);
        uint256 expectedUser2Shares = vault.previewDeposit(a2);
        cToken.approve(address(vault), a2);
        uint256 user2Shares = vault.deposit(a2, user2);
        vm.stopPrank();

        assertEq(user2Shares, expectedUser2Shares, "user2 shares != previewDeposit");

        // Basic vault state
        uint256 nav = vault.totalAssets();
        assertApproxEqAbs(nav, a1 + a2, 1, "NAV mismatch after both deposits");

        uint256 cShares = cEVault.balanceOf(address(vault));
        uint256 cUnderlying = cEVault.convertToAssets(cShares);
        assertGt(cUnderlying, a1 + a2, "collateral should be levered above raw deposits");

        uint256 vaultDebt = dEVault.debtOf(address(vault));
        assertGt(vaultDebt, 0, "vault should have some borrow debt after rebalancing");

        // User 1 withdraws
        vm.startPrank(user1);
        uint256 user1BalanceBefore = cToken.balanceOf(user1);
        vault.redeem(user1Shares, user1, user1);
        uint256 user1BalanceAfter = cToken.balanceOf(user1);
        vm.stopPrank();

        assertApproxEqAbs(user1BalanceAfter, user1BalanceBefore + a1, 1, "user1 final cToken balance mismatch");

        // User 2 withdraws
        vm.startPrank(user2);
        uint256 user2BalanceBefore = cToken.balanceOf(user2);
        vault.redeem(user2Shares, user2, user2);
        uint256 user2BalanceAfter = cToken.balanceOf(user2);
        vm.stopPrank();

        assertApproxEqAbs(user2BalanceAfter, user2BalanceBefore + a2, 1, "user2 final cToken balance mismatch");

        // Final sanity checks
        assertEq(vault.totalSupply(), 0, "vault totalSupply not zero after full exit");
        assertApproxEqAbs(cToken.balanceOf(address(vault)), 0, 1, "vault still holds cToken after full exit");
        assertApproxEqAbs(dToken.balanceOf(address(vault)), 0, 1, "vault still holds dToken after full exit");
        assertApproxEqAbs(dEVault.debtOf(address(vault)), 0, 1, "vault still has debt after full exit");
    }
}
