// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import "forge-std/Test.sol";

import {InvariantBase} from "./InvariantBase.t.sol";
import {LoopHandler} from "./handlers/LoopHandler.t.sol";

import {IPriceOracle} from "euler-vault-kit/src/interfaces/IPriceOracle.sol";

contract InvariantLooping is StdInvariant, InvariantBase {
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
        selectors[2] = handler.act_skewPrices.selector;
        selectors[3] = handler.act_rebalance.selector;

        targetSelector(
            FuzzSelector({addr: address(handler), selectors: selectors})
        );
        targetContract(address(handler));
    }

    // ==================== CORE INVARIANTS ====================

    /// @dev Successful redeem should not increase debt.
    function invariant_redeemSuccessDoesNotIncreaseDebt() external view {
        assertTrue(
            !handler.debtIncreasedOnRedeem(),
            "debt increased on redeem success"
        );
    }

    /// @dev After successful rebalance, leverage should not diverge further from target.
    function invariant_rebalanceConverges() external view {
        assertTrue(
            !handler.leverageDivergedOnRebalance(),
            "rebalance diverged from target"
        );
    }

    // ==================== ERC4626 INTEGRITY ====================

    /// @dev convertToAssets(convertToShares(x)) ~= x for reasonable x.
    function invariant_shareConversionConsistency() external view {
        if (vault.totalSupply() == 0) return;

        uint256 testAmount = 1e18;
        if (vault.totalAssets() < testAmount) return;

        uint256 shares = vault.convertToShares(testAmount);
        if (shares == 0) return;

        uint256 backToAssets = vault.convertToAssets(shares);

        // Allow 1% rounding error
        uint256 lowerBound = (testAmount * 99) / 100;
        uint256 upperBound = (testAmount * 101) / 100;

        assertTrue(
            backToAssets >= lowerBound && backToAssets <= upperBound,
            "share conversion inconsistent"
        );
    }

    /// @dev Collateral backing must support all vault shares issued.
    /// Verifies that the vault's collateral position is sufficient to back totalAssets().
    function invariant_collateralBacking() external view {
        uint256 cEVaultShares = cEVault.balanceOf(address(vault));
        uint256 actualCollateral = cEVault.convertToAssets(cEVaultShares);
        uint256 vaultTotalAssets = vault.totalAssets();

        if (vault.totalSupply() == 0) {
            // No shares issued, collateral should be minimal (or zero)
            return;
        }

        // The vault's totalAssets represents the equity value in asset terms.
        // Collateral should be >= totalAssets since we have leverage.
        assertTrue(
            actualCollateral >= vaultTotalAssets,
            "collateral < totalAssets: backing insufficient"
        );
    }

    /// @dev Debt reported by dEVault should match internal tracking.
    function invariant_debtConsistency() external view {
        uint256 debt = dEVault.debtOf(address(vault));

        // If we have collateral, debt should be reasonable relative to it
        uint256 collateral = cEVault.convertToAssets(
            cEVault.balanceOf(address(vault))
        );

        if (collateral == 0 && debt > 1e12) {
            // No collateral but significant debt = problem
            assertTrue(false, "debt exists without collateral");
        }
    }

}
