// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {UnitBaseTest} from "../UnitBaseTest.t.sol";
import "forge-std/Test.sol";

/// @title Operation Reversions Tests
/// @notice Tests for operations that should revert under specific conditions
contract OperationReversionsTest is UnitBaseTest {
    function setUp() public override {
        super.setUp();
    }

    /// @notice Unit: redeem reverts when oracle price is zero
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

        // Break the oracle: return 0 for the asset
        oracle.setPrice(address(cToken), unitOfAccount, 0);

        // Try redeem -> should revert
        vm.startPrank(user);
        vm.expectRevert(bytes("LeverageVault: invalid price"));
        vault.redeem(shares, user, user);
        vm.stopPrank();
    }

    /// @notice Unit: redeem reverts when vault is underwater
    function test_redeem_reverts_when_underwater() public {
        address user = makeAddr("underwaterUser");
        uint256 amount = 2e18;

        // User deposits and creates leveraged position
        cToken.mint(user, amount);
        vm.startPrank(user);
        cToken.approve(address(vault), amount);
        uint256 shares = vault.deposit(amount, user);
        vm.stopPrank();

        // Sanity: there is collateral and debt
        uint256 cBefore = cEVault.convertToAssets(cEVault.balanceOf(address(vault)));
        uint256 dBefore = dEVault.debtOf(address(vault));
        assertGt(cBefore, 0, "no collateral before");
        assertGt(dBefore, 0, "no debt before");

        // Adjust prices to make vault underwater
        // assetsValue drops significantly => underwater
        oracle.setPrice(address(dToken), unitOfAccount, 3000e18);
        oracle.setPrice(address(cToken), unitOfAccount, 1500e18);

        vm.startPrank(user);
        vm.expectRevert(bytes("LeverageVault: vault underwater"));
        vault.redeem(shares, user, user);
        vm.stopPrank();
    }
}
