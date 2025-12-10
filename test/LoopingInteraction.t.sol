// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {BaseTest} from "./BaseTest.t.sol";
import "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

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
        cToken.mint(user2, a2);
        assertEq(cToken.balanceOf(user2), a2);

        startHoax(depositor);

        dToken.mint(depositor, type(uint256).max);
        dToken.approve(address(dEVault), type(uint256).max);
        // Provide ample liquidity for borrows (USDC 18 decimals)
        dEVault.deposit(1_000_000_000_000e18, depositor);

        dToken.approve(address(fEVault), type(uint256).max);
        // Provide ample liquidity for flash loans (USDC 18 decimals)
        fEVault.deposit(1_000_000_000_000e18, depositor);
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

        uint256 expectedUser1Shares = vault.previewDeposit(a1);
        // Approve vault to pull cToken
        cToken.approve(address(vault), a1);
        uint256 user1Shares = vault.deposit(a1, user1);

        vm.stopPrank();

        assertEq(user1Shares, expectedUser1Shares, "user1 shares != previewDeposit");

        // -----------------------------
        // 2) user2 deposits a2
        // -----------------------------
        vm.startPrank(user2);

        uint256 expectedUser2Shares = vault.previewDeposit(a2);
        cToken.approve(address(vault), a2);
        uint256 user2Shares = vault.deposit(a2, user2);
        vm.stopPrank();

        assertEq(user2Shares, expectedUser2Shares, "user2 shares != previewDeposit");


        // -----------------------------
        // 3) Check basic vault state
        // -----------------------------

        // NAV should be approximately a1 + a2 in underlying units
        uint256 nav = vault.totalAssets();
        assertApproxEqAbs(nav, a1 + a2, 1, "NAV mismatch after both deposits");


        // Collateral in cEVault should be > deposited sum because of leverage (target 2x)
        uint256 cShares = cEVault.balanceOf(address(vault));
        uint256 cUnderlying = cEVault.convertToAssets(cShares);
        assertGt(
            cUnderlying,
            a1 + a2,
            "collateral should be levered above raw deposits"
        );

        // There should be some debt opened in dEVault
        uint256 vaultDebt = dEVault.debtOf(address(vault));
        assertGt(
            vaultDebt,
            0,
            "vault should have some borrow debt after rebalancing"
        );

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
        assertEq(
            vault.totalSupply(),
            0,
            "vault totalSupply not zero after full exit"
        );

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

    function test_redeem_reverts_when_price_is_zero() public {
        address user = makeAddr("user");
        uint256 amount = 2e18;

        cToken.mint(user, amount);
        vm.startPrank(user);
        cToken.approve(address(vault), amount);
        uint256 shares = vault.deposit(amount, user);
        vm.stopPrank();

        // Sanity: there is collateral and debt
        assertGt(cEVault.balanceOf(address(vault)), 0);
        assertGt(dEVault.debtOf(address(vault)), 0);

        // 2) Break the oracle: return 0 for the asset()
        oracle.setPrice(address(cToken), unitOfAccount, 0);

        // 3) Try redeem -> should revert with "LeverageVault: invalid price"
        vm.startPrank(user);
        vm.expectRevert(bytes("LeverageVault: invalid price"));
        vault.redeem(shares, user, user);
        vm.stopPrank();
    }

    function test_redeem_reverts_when_underwater() public {
        address user = makeAddr("underwaterUser");
        uint256 amount = 2e18;

        // 1) User deposits and creates the leveraged position
        cToken.mint(user, amount);
        vm.startPrank(user);
        cToken.approve(address(vault), amount);
        uint256 shares = vault.deposit(amount, user);
        vm.stopPrank();

        // Sanity: there is collateral and debt
        uint256 cBefore = cEVault.convertToAssets(
            cEVault.balanceOf(address(vault))
        );
        uint256 dBefore = dEVault.debtOf(address(vault));
        assertGt(cBefore, 0, "no collateral before");
        assertGt(dBefore, 0, "no debt before");

        // 2) Adjust prices in the oracle:
        // dToken remains at 1e18 vs unitOfAccount
        oracle.setPrice(address(dToken), unitOfAccount, 3000e18);
        oracle.setPrice(address(cToken), unitOfAccount, 1500e18); 

        // With this:
        // - assetsValue drops significantly => assetsValue << debt => underwater

        vm.startPrank(user);
        vm.expectRevert(bytes("LeverageVault: vault underwater"));
        vault.redeem(shares, user, user);
        vm.stopPrank();
    }

    function test_redeem_reduces_position_proportionally() public {
        // Same setup as the happy path: user1 and user2
        vm.startPrank(user1);
        cToken.approve(address(vault), a1);
        uint256 user1Shares = vault.deposit(a1, user1);
        vm.stopPrank();

        vm.startPrank(user2);
        cToken.approve(address(vault), a2);
        uint256 user2Shares = vault.deposit(a2, user2);
        vm.stopPrank();

        // Basic sanity
        uint256 totalSharesBefore = vault.totalSupply();
        assertEq(totalSharesBefore, user1Shares + user2Shares);

        uint256 cBefore = cEVault.convertToAssets(
            cEVault.balanceOf(address(vault))
        );
        uint256 dBefore = dEVault.debtOf(address(vault));

        assertGt(cBefore, 0, "no collateral before");
        assertGt(dBefore, 0, "no debt before");

        // Fraction of position represented by user1
        // s = user1Shares / totalShares
        // C_user1 = C * s ; D_user1 = D * s
        uint256 expectedCRemoved = Math.mulDiv(
            cBefore,
            user1Shares,
            totalSharesBefore
        );
        uint256 expectedDRemoved = Math.mulDiv(
            dBefore,
            user1Shares,
            totalSharesBefore
        );

        // 1) user1 exits completely
        vm.startPrank(user1);
        vault.redeem(user1Shares, user1, user1);
        vm.stopPrank();

        // 2) Measure the new state of the vault
        uint256 cAfter = cEVault.convertToAssets(
            cEVault.balanceOf(address(vault))
        );
        uint256 dAfter = dEVault.debtOf(address(vault));

        // How much collateral and debt left with user1
        uint256 actualCRemoved = cBefore - cAfter;
        uint256 actualDRemoved = dBefore - dAfter;

        // Allow a little slack for rounding (in wei)
        uint256 tolC = 1e6; // 1e-12 of 1e18, effectively negligible for tests
        uint256 tolD = 1; // 1 unit in dToken (6 decimals in this setup)

        assertApproxEqAbs(
            actualCRemoved,
            expectedCRemoved,
            tolC,
            "collateral removal not proportional to user1 shares"
        );
        assertApproxEqAbs(
            actualDRemoved,
            expectedDRemoved,
            tolD,
            "debt removal not proportional to user1 shares"
        );

        // 3) Extra sanity: only user2 shares remain
        assertEq(
            vault.totalSupply(),
            user2Shares,
            "remaining supply != user2 shares"
        );
    }

    function test_unwind_sells_less_collateral_when_idle_dToken() public {
        address user = makeAddr("idleUser");
        uint256 amount = 2e18;

        // ---------- BASE SCENARIO: deposit + leverage ----------
        cToken.mint(user, amount);
        vm.startPrank(user);
        cToken.approve(address(vault), amount);
        uint256 shares = vault.deposit(amount, user);
        vm.stopPrank();

        // Sanity: there is collateral and debt
        uint256 cBeforeGlobal = cEVault.convertToAssets(
            cEVault.balanceOf(address(vault))
        );
        uint256 dBeforeGlobal = dEVault.debtOf(address(vault));
        assertGt(cBeforeGlobal, 0, "no collateral before");
        assertGt(dBeforeGlobal, 0, "no debt before");

        // Save snapshot of the state to repeat the test
        uint256 snap = vm.snapshot();

        /* ------------------------------------------------------ */
        /*   SCENARIO A: WITHOUT idle dToken                      */
        /* ------------------------------------------------------ */
        uint256 cBeforeA = cEVault.convertToAssets(
            cEVault.balanceOf(address(vault))
        );
        uint256 dBeforeA = dEVault.debtOf(address(vault));

        vm.startPrank(user);
        vault.redeem(shares, user, user);
        vm.stopPrank();

        uint256 cAfterA = cEVault.convertToAssets(
            cEVault.balanceOf(address(vault))
        );
        uint256 dAfterA = dEVault.debtOf(address(vault));

        uint256 collateralSoldA = cBeforeA - cAfterA;
        uint256 debtRepaidA = dBeforeA - dAfterA;

        // Sanity: some debt has been repaid
        assertGt(debtRepaidA, 0, "no debt repaid in scenario A");

        // Revert to snapshot: state exactly the same as before redeem
        vm.revertTo(snap);

        /* ------------------------------------------------------ */
        /*   SCENARIO B: WITH idle dToken                         */
        /* ------------------------------------------------------ */
        // Obtain shares again 
        // Redo the deposit to have the same state as before
        cToken.mint(user, amount);
        vm.startPrank(user);
        cToken.approve(address(vault), amount);
        shares = vault.deposit(amount, user);
        vm.stopPrank();

        // Prefund the vault with idle dToken
        uint256 debtBeforeB = dEVault.debtOf(address(vault));
        dToken.mint(address(vault), debtBeforeB); // sufficient to cover all its debt

        uint256 cBeforeB = cEVault.convertToAssets(
            cEVault.balanceOf(address(vault))
        );
        uint256 dBeforeB = dEVault.debtOf(address(vault));

        vm.startPrank(user);
        vault.redeem(shares, user, user);
        vm.stopPrank();

        uint256 cAfterB = cEVault.convertToAssets(
            cEVault.balanceOf(address(vault))
        );
        uint256 dAfterB = dEVault.debtOf(address(vault));

        uint256 collateralSoldB = cBeforeB - cAfterB;
        uint256 debtRepaidB = dBeforeB - dAfterB;

        // Again sanity: debt is repaid
        assertGt(debtRepaidB, 0, "no debt repaid in scenario B");

        // And here's the interesting part:
        // With idle dToken we should sell EQUAL or LESS collateral
        assertLe(
            collateralSoldB,
            collateralSoldA,
            "idle dToken did not reduce collateral sold"
        );
    }
}
