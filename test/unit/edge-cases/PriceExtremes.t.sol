// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {BaseTest} from "../../BaseTest.t.sol";
import {UnitBaseTest} from "../UnitBaseTest.t.sol";
import "forge-std/Test.sol";

/// @title Price Edge Cases Tests
/// @notice Tests for extreme price scenarios and oracle edge cases
contract PriceExtremesTest is UnitBaseTest {
    function setUp() public override {
        super.setUp();
    }

    /// @notice Fuzz: redeem should revert if oracle price causes underwater state
    function testFuzz_redeem_reverts_when_underwater_prices(uint256 cPrice, uint256 dPrice, uint256 deposit) public {
        deposit = bound(deposit, 1e9, 1e24);
        cPrice = bound(cPrice, 1e9, 1e22);
        dPrice = bound(dPrice, 1e9, 1e22);

        address u = makeAddr("underwaterFuzz");
        cToken.mint(u, deposit);
        vm.startPrank(u);
        cToken.approve(address(vault), deposit);
        uint256 shares = vault.deposit(deposit, u);
        vm.stopPrank();

        // Ensure some starting leverage
        assertGt(dEVault.debtOf(address(vault)), 0);

        // Manipulate oracle to push underwater
        uint256 cheapC = cPrice / 2;
        uint256 richD = dPrice * 2;

        cheapC = cheapC == 0 ? 1 : cheapC;
        richD = richD == 0 ? 1 : richD;

        oracle.setPrice(address(cToken), unitOfAccount, cheapC);
        oracle.setPrice(address(dToken), unitOfAccount, richD);

        // Compute underwater condition
        uint256 cAssets = cEVault.convertToAssets(cEVault.balanceOf(address(vault)));
        uint256 dDebt = dEVault.debtOf(address(vault));
        uint256 assetsValue = (cAssets * cheapC) / 1e18;
        uint256 debtValue = (dDebt * richD) / 1e18;

        // Only test underwater scenarios
        vm.assume(assetsValue < debtValue);

        vm.startPrank(u);
        vm.expectRevert();
        vault.redeem(shares, u, u);
        vm.stopPrank();
    }
}
