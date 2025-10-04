// SPDX-License-Identifier: GPL-2.0-or-later

pragma solidity ^0.8.0;


import {EulerLoopingVaultTest, console2} from "./EulerLoopingVaultBase.t.sol";

import "euler-vault-kit/src/EVault/shared/types/Types.sol";
import "euler-vault-kit/src/EVault/shared/Errors.sol";

contract VaultTest_Borrow is EulerLoopingVaultTest {

    using TypesLib for uint256;

    address depositor;
    address borrower;
    address borrower2;

    function setUp() public override {

        super.setUp();

        depositor = makeAddr("depositor");
        borrower = makeAddr("borrower");
        borrower2 = makeAddr("borrower_2");

        // Setup

        oracle.setPrice(address(assetTST), unitOfAccount, 1e18);
        oracle.setPrice(address(assetTST2), unitOfAccount, 1e18);

        eTST.setLTV(address(eTST2), 0.9e4, 0.9e4, 0);

        // Depositor

        startHoax(depositor);

        assetTST.mint(depositor, type(uint256).max);
        assetTST.approve(address(eTST), type(uint256).max);
        eTST.deposit(100e18, depositor);

        // Borrower

        startHoax(borrower);

        assetTST2.mint(borrower, type(uint256).max);
        assetTST2.approve(address(eTST2), type(uint256).max);
        eTST2.deposit(10e18, borrower);

        vm.stopPrank();
    }



     function test_BasicBorrow() public{ 
        startHoax(borrower);
 
        vm.expectRevert(Errors.E_ControllerDisabled.selector);
        eTST.borrow(5e18, borrower);

        evc.enableController(borrower, address(eTST));

        vm.expectRevert(Errors.E_AccountLiquidity.selector);
        eTST.borrow(5e18, borrower);

        // still no borrow hence possible to disable controller
        assertEq(evc.isControllerEnabled(borrower, address(eTST)), true);
        eTST.disableController();
        assertEq(evc.isControllerEnabled(borrower, address(eTST)), false);
        evc.enableController(borrower, address(eTST));
        assertEq(evc.isControllerEnabled(borrower, address(eTST)), true);


        evc.enableCollateral(borrower, address(eTST2));

        eTST.borrow(5e18, borrower);
        assertEq(assetTST.balanceOf(borrower), 5e18);
        assertEq(eTST.debtOf(borrower), 5e18);
        assertEq(eTST.debtOfExact(borrower), 5e18 << INTERNAL_DEBT_PRECISION_SHIFT);

        assertEq(eTST.totalBorrows(), 5e18);
        assertEq(eTST.totalBorrowsExact(), 5e18 << INTERNAL_DEBT_PRECISION_SHIFT);

        // no longer possible to disable controller
        vm.expectRevert(Errors.E_OutstandingDebt.selector);
        eTST.disableController();

        vm.expectRevert(Errors.E_AccountLiquidity.selector);
        eTST.borrow(4.0001e18, borrower);

        // Disable collateral should fail

        vm.expectRevert(Errors.E_AccountLiquidity.selector);
        evc.disableCollateral(borrower, address(eTST2));


        // Repay

        assetTST.approve(address(eTST), type(uint256).max);
        eTST.repay(type(uint256).max, borrower);

        evc.disableCollateral(borrower, address(eTST2));
        assertEq(evc.getCollaterals(borrower).length, 0);

        eTST.disableController();
        assertEq(evc.getControllers(borrower).length, 0);
    }


    
    // test if hook is correctly blocking borrowing operations  
    function test_BorrowIsDisabled() public {
        vm.startPrank(borrower);


        evc.enableController(borrower, address(eTST2));
        assertEq(evc.isControllerEnabled(borrower, address(eTST2)), true);

        evc.enableCollateral(borrower, address(eTST2));

        vm.expectRevert(Errors.E_OperationDisabled.selector);
        eTST2.borrow(5e18, borrower);

    }

}