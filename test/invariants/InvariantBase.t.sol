// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {BaseTest} from "../BaseTest.t.sol";

/// @dev Deploys the whole EVK stack via BaseTest.setUp and seeds liquidity.
contract InvariantBase is BaseTest {
    address[] internal actors;

    function setUp() public virtual override {
        super.setUp();

        actors.push(makeAddr("actorA"));
        actors.push(makeAddr("actorB"));
        actors.push(makeAddr("actorC"));
        actors.push(makeAddr("actorD"));
        actors.push(makeAddr("actorE"));
        actors.push(makeAddr("actorF"));

        // Seed liquidity
        address depositor = makeAddr("seedDepositor");

        vm.startPrank(depositor);
        dToken.mint(depositor, 10_000_000e18);
        dToken.approve(address(dEVault), type(uint256).max);
        dEVault.deposit(5_000_000e18, depositor);

        dToken.approve(address(fEVault), type(uint256).max);
        fEVault.deposit(5_000_000e18, depositor);
        vm.stopPrank();
    }

    function _actors() internal view returns (address[] memory) {
        return actors;
    }
}
