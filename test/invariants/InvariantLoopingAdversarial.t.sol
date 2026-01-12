// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import "forge-std/Test.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {InvariantBase} from "./InvariantBase.t.sol";
import {LoopHandler} from "./handlers/LoopHandler.t.sol";

import {IPriceOracle} from "euler-vault-kit/src/interfaces/IPriceOracle.sol";

contract InvariantLoopingAdversarial is StdInvariant, InvariantBase {
    LoopHandler internal handler;

    function setUp() public override {
        super.setUp();

        LoopHandler.Refs memory r = LoopHandler.Refs({
            vault: vault,
            cEVault: cEVault,
            dEVault: dEVault,
            fEVault: fEVault,
            cToken: cToken,
            dToken: dToken,
            oracle: IPriceOracle(address(oracle)),
            unitOfAccount: unitOfAccount
        });

        handler = new LoopHandler(r, _actors());

        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = handler.act_deposit.selector;
        selectors[1] = handler.act_redeemFraction.selector;
        selectors[2] = handler.act_rebalance.selector;
        selectors[3] = handler.act_skewPrices.selector;

        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    // ==================== CORE INVARIANTS ====================

    /// @dev After successful rebalance, leverage should not diverge further from target.
    function invariant_rebalanceConverges() external view {
        assertTrue(!handler.leverageDivergedOnRebalance(), "rebalance diverged from target");
    }
}
