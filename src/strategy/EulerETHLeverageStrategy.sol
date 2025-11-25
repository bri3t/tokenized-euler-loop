// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IEVault} from "euler-vault-kit/src/EVault/IEVault.sol"; 
import {ILeverageStrategy} from "./ILeverageStrategy.sol";
import {ISwapRouterV3} from "../interfaces/ISwapRouterV3.sol";

/// @notice Euler-based leverage strategy for an ETH (WETH) looping vault.
/// @dev Current version:
///      - Has wiring for WETH + EVault_WETH (collateral),
///        USDC + EVault_USDC (debt/flash),
///        and Uniswap V3 router.
///      - The high-level flow for openPosition is documented as comments,
///        but the exact EVault calls (flashLoan, borrow, repay) are left as TODO
///        so you can plug in the correct signatures from your local EVK.
contract EulerETHLeverageStrategy is ILeverageStrategy {
    // using SafeERC20 for IERC20;

    /// @notice Underlying asset for the vault.
    IERC20 public immutable vaultAsset;

    /// @notice Debt asset.
    IERC20 public immutable dToken;

    /// @notice Euler EVault for vaultAsset collateral.
    IEVault public immutable eCollateral;

    /// @notice Euler EVault for dToken (flash + borrow).
    IEVault public immutable eDebt;

    /// @notice Uniswap V3 router for swaps.
    ISwapRouterV3 public immutable uniRouter;

    /// @notice Looping vault that is allowed to call this strategy.
    address public immutable vault;

    /// @notice Target leverage (e.g. 5e18 = 5x).
    uint256 public immutable targetLeverage; // scaled by 1e18

    modifier onlyVault() {
        require(msg.sender == vault, "Strategy: caller is not vault");
        _;
    }

    /// @param _vaultAsset Address of asset token (vault underlying).
    /// @param _dToken Address of debt token.
    /// @param _eCollateral Address of the Euler EVault for collateral.
    /// @param _eDebt Address of the Euler EVault for debt.
    /// @param _uniRouter Address of Uniswap V3 router.
    /// @param _vault Address of the LoopingVault that owns this strategy.
    /// @param _targetLeverage Target leverage (e.g. 5e18 for 5x).
    constructor(
        address _vaultAsset,
        address _dToken,
        address _eCollateral,
        address _eDebt,
        address _uniRouter,
        address _vault,
        uint256 _targetLeverage
    ) {
        require(_vaultAsset != address(0), "WETH address is zero");
        require(_dToken != address(0), "USDC address is zero");
        require(_eCollateral != address(0), "eCollateral address is zero");
        require(_eDebt != address(0), "eUSDC address is zero");
        // require(_uniRouter != address(0), "Router address is zero");
        require(_vault != address(0), "Vault address is zero");
        require(_targetLeverage >= 1e18, "Leverage must be >= 1x");

        vaultAsset = IERC20(_vaultAsset);
        dToken = IERC20(_dToken);
        eCollateral = IEVault(_eCollateral);
        eDebt = IEVault(_eDebt);
        uniRouter = ISwapRouterV3(_uniRouter);
        vault = _vault;
        targetLeverage = _targetLeverage;
    }

    /// @notice Called by the vault after a user deposit of the underlying asset.
    /// @dev High-level target flow for 5x leverage (example):
    ///      - Let equity = amount (underlying asset from user).
    ///      - Compute target position size in underlying asset: pos = equity * targetLeverage.
    ///      - Derive how much debt token you need as flash liquidity to reach that position.
    ///      - Flash loan debt token from eDebt.
    ///      - Swap debt token -> underlying asset via Uniswap.
    ///      - Deposit total underlying asset (user + swapped) into eCollateral as collateral.
    ///      - Borrow debt token from eDebt against that collateral.
    ///      - Use borrowed debt token to repay the flash loan.
    function openPosition(uint256 amount) external override onlyVault {
        if (amount == 0) return;

        // 1) Pull underlying asset from the vault into this strategy.
        vaultAsset.transferFrom(msg.sender, address(this), amount);

        // ============================
        //  A. Compute leverage numbers
        // ============================
        //
        // NOTE: For now you can hardcode something simple just to get the pattern working,
        //       and later replace with a proper formula using oracle prices.
        //
        // Example pseudo:
        //
        // uint256 equityUnderlying = amount;
        // uint256 targetPosUnderlying = equityUnderlying * targetLeverage / 1e18; // total underlying asset exposure wanted
        // uint256 extraUnderlyingNeeded = targetPosUnderlying - equityUnderlying;
        //
        // To get extraUnderlyingNeeded you will flash loan debt token and swap to underlying asset.
        // You will then borrow enough debt token so that, after repaying the flash loan,
        // the remaining state is:
        //   - eCollateral: targetPosUnderlying supplied
        //   - eDebt: some debt token debt
        //
        // For now, we leave this math as TODO.

        // ============================
        //  B. Flash loan debt token
        // ============================
        //
        // Here you will:
        //  - request a flash loan of `flashAmountUsdc` from eDebt.
        //  - pass encoded data so that the callback knows:
        //      - how much underlying asset to buy
        //      - how much to deposit
        //      - how much debt token to borrow at the end
        //
        // PSEUDO-CODE (replace with actual EVault flashLoan API):
        //
        // bytes memory data = abi.encode(amount, /* any other params needed */);
        // eDebt.flashLoan(address(this), address(dToken), flashAmountDebtToken, data);
        //
        // Where this contract must implement the appropriate onFlashLoan/onDeferredLiquidityCheck
        // callback required by EVK/EVC.
        //
        // For now, we leave this as TODO, because the exact signature depends on your EVK version.

        // ============================
        //  C. No-op fallback deposit (for now)
        // ============================
        //
        // So that you can still run tests without flash logic completed, you can keep
        // a simple "no leverage" deposit as a temporary fallback:
        vaultAsset.approve(address(eCollateral), 0);
        vaultAsset.approve(address(eCollateral), amount);
        eCollateral.deposit(amount, address(this));
    }

    /// @notice Called by the vault before a user withdrawal.
    /// @dev High-level target flow:
    ///      - Compute the proportion of the global position that corresponds to
    ///        `assetsToReturn` (based on vault shares / totalAssets).
    ///      - Optionally use a small flash loan in USDC to help unwind:
    ///          * repay a proportional part of the USDC debt,
    ///          * free the corresponding WETH collateral,
    ///          * swap some WETH back to USDC to repay flash,
    ///          * send remaining WETH to the vault.
    ///      - In this skeleton, we only support the "no leverage" case and simply
    ///        withdraw WETH from eCollateral and send it back to the vault.
    function closePosition(uint256 assetsToReturn) external override onlyVault {
        if (assetsToReturn == 0) return;

        // TODO: once leverage is implemented, this must:
        //  - calculate proportional position to unwind,
        //  - repay part of eDebt debt,
        //  - withdraw WETH collateral,
        //  - handle flash loan repays if used.

        // For now: simple withdraw from eCollateral (no debt assumed).
        eCollateral.withdraw(assetsToReturn, address(this), address(this));

        // Send WETH back to the vault so it can complete the ERC-4626 withdraw.
        vaultAsset.transfer(msg.sender, assetsToReturn);
    }

    /// @notice Returns the net value managed by the strategy, denominated in WETH units.
    /// @dev Current simple version:
    ///      - Only considers WETH supplied to eCollateral + idle WETH here.
    ///      Future version (with leverage):
    ///      - Must price:
    ///          * WETH collateral in eCollateral
    ///          * USDC debt in eDebt
    ///        using oracle prices, and return NAV in WETH.
    function totalAssets() external view override returns (uint256) {
        uint256 eShares = eCollateral.balanceOf(address(this));
        uint256 supplied = eCollateral.convertToAssets(eShares);
        uint256 idle = vaultAsset.balanceOf(address(this));

        // TODO: when you add leverage, subtract USDC debt valued in WETH terms.
        // uint256 usdcDebt = eDebt.debtOf(address(this)); // or similar, check EVK API
        // uint256 usdcPriceInWeth = ...;                  // use price oracle
        // uint256 debtInWeth = usdcDebt * usdcPriceInWeth / 1e18;
        // return supplied + idle - debtInWeth;

        return supplied + idle;
    }
}
