// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {BaseTest} from "./BaseTest.t.sol";
import "forge-std/Test.sol";

contract LoopingInteraction is BaseTest {

    address user1;
    address user2;
    address depositor;

    uint256 a1;
    uint256 a2;

    function setUp() public override {
        super.setUp();

        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        depositor = makeAddr("depositor");

        a1 = 2e18;
        a2 = 4e18;

        // Mint collateral token (cToken, acting as WETH) to users
        cToken.mint(user1, a1);
        assertEq(cToken.balanceOf(user1), a1);
        console2.log("user1 cToken balance:", cToken.balanceOf(user1));
        cToken.mint(user2, a2);
        assertEq(cToken.balanceOf(user2), a2);

        startHoax(depositor);

        dToken.mint(depositor, type(uint256).max);
        dToken.approve(address(dEVault), type(uint256).max);
        dEVault.deposit(100_000_000e18, depositor);

        dToken.approve(address(fEVault), type(uint256).max);
        fEVault.deposit(100_000_000e18, depositor);
        vm.stopPrank();

        vm.startPrank(address(vault));
        evc.enableCollateral(address(vault), address(cEVault));
        evc.enableController(address(vault), address(dEVault));
        vm.stopPrank();

    }

    /// @notice Basic 2-users deposit/withdraw flow against LeverageVault.
    function test_multiple_users_deposit_and_withdraw() public {
        // -----------------------------
        // 1) user1 deposits a1
        // -----------------------------
        vm.startPrank(user1);

        // Approve vault to pull cToken
        cToken.approve(address(vault), a1);

        // Deposit into the leverage vault
        uint256 user1Shares = vault.deposit(a1, user1);

        vm.stopPrank();

        console.log(vault.totalSupply());
        // After first deposit, since totalSupply was 0, user1Shares == a1
        assertEq(user1Shares, a1, "user1 shares mismatch after first deposit");

        // -----------------------------
        // 2) user2 deposits a2
        // -----------------------------
        vm.startPrank(user2);

        cToken.approve(address(vault), a2);
        uint256 user2Shares = vault.deposit(a2, user2);

        vm.stopPrank();
        console.log(vault.totalSupply());

        // With ERC4626 math and 1:1 NAV in this ideal setup,
        // user2Shares should be a2 as well (same share price).
        assertEq(user2Shares, a2, "user2 shares mismatch after second deposit");

        // Total supply == a1 + a2
        assertEq(vault.totalSupply(), a1 + a2, "total shares mismatch");

        // -----------------------------
        // 3) Check basic vault state
        // -----------------------------

        // NAV should be approximately a1 + a2 in underlying units
        uint256 nav = vault.totalAssets();
        assertApproxEqAbs(nav, a1 + a2, 1, "NAV mismatch after both deposits");

        // Collateral in cEVault should be > deposited sum because of leverage (target 2x)
        uint256 cShares = cEVault.balanceOf(address(vault));
        uint256 cUnderlying = cEVault.convertToAssets(cShares);
        assertGt(cUnderlying, a1 + a2, "collateral should be levered above raw deposits");

        // There should be some debt opened in dEVault
        uint256 vaultDebt = dEVault.debtOf(address(vault));
        assertGt(vaultDebt, 0, "vault should have some borrow debt after rebalancing");

        // -----------------------------
        // 4) user1 withdraws everything
        // -----------------------------
        vm.startPrank(user1);

        uint256 user1BalanceBefore = cToken.balanceOf(user1);

        // Redeem all user1 shares
        vault.redeem(user1Shares, user1, user1);

        uint256 user1BalanceAfter = cToken.balanceOf(user1);
        vm.stopPrank();

        // user1 should have ~a1 back (within 1 wei tolerance)
        assertApproxEqAbs(
            user1BalanceAfter,
            user1BalanceBefore + a1,
            1,
            "user1 final cToken balance mismatch"
        );

        // -----------------------------
        // 5) user2 withdraws everything
        // -----------------------------
        vm.startPrank(user2);

        uint256 user2BalanceBefore = cToken.balanceOf(user2);

        vault.redeem(user2Shares, user2, user2);

        uint256 user2BalanceAfter = cToken.balanceOf(user2);
        vm.stopPrank();

        // user2 should have ~a2 back (within 1 wei tolerance)
        assertApproxEqAbs(
            user2BalanceAfter,
            user2BalanceBefore + a2,
            1,
            "user2 final cToken balance mismatch"
        );

        // -----------------------------
        // 6) Final sanity checks
        // -----------------------------

        // All shares should be burned
        assertEq(vault.totalSupply(), 0, "vault totalSupply not zero after full exit");

        // Vault should not hold meaningful leftover cToken or dToken
        assertApproxEqAbs(
            cToken.balanceOf(address(vault)),
            0,
            1,
            "vault still holds cToken after full exit"
        );

        assertApproxEqAbs(
            dToken.balanceOf(address(vault)),
            0,
            1,
            "vault still holds dToken after full exit"
        );

        // And debt on dEVault should be (almost) zero
        assertApproxEqAbs(
            dEVault.debtOf(address(vault)),
            0,
            1,
            "vault still has debt after full exit"
        );
    }
}
