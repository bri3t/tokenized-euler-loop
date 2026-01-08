// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {BaseTest} from "../BaseTest.t.sol";

contract UnitBaseTest is BaseTest {
    address user1;
    address user2;
    address depositor;

    uint256 a1;
    uint256 a2;

    function setUp() public virtual override {
        super.setUp();

        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        depositor = makeAddr("depositor");

        a1 = 2e18;
        a2 = 4e18;

        // Mint collateral token to users
        cToken.mint(user1, a1);
        assertEq(cToken.balanceOf(user1), a1);
        cToken.mint(user2, a2);
        assertEq(cToken.balanceOf(user2), a2);

        startHoax(depositor);

        dToken.mint(depositor, type(uint256).max);
        dToken.approve(address(dEVault), type(uint256).max);
        dEVault.deposit(1_000_000_000_000e18, depositor);

        dToken.approve(address(fEVault), type(uint256).max);
        fEVault.deposit(1_000_000_000_000e18, depositor);
        vm.stopPrank();

        vm.startPrank(address(vault));
        evc.enableCollateral(address(vault), address(cEVault));
        evc.enableController(address(vault), address(dEVault));
        vm.stopPrank();
    }
}
