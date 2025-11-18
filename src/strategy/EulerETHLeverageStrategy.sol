// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

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
    using SafeERC20 for IERC20;

    /// @notice WETH used as underlying for the vault.
    IERC20 public immutable weth;

    /// @notice USDC used as debt / flash asset.
    IERC20 public immutable usdc;

    /// @notice Euler EVault for WETH collateral.
    IEVault public immutable eWeth;

    /// @notice Euler EVault for USDC (flash + borrow).
    IEVault public immutable eUsdc;

    /// @notice Uniswap V3 router for USDC <-> WETH swaps.
    ISwapRouterV3 public immutable uniRouter;

    /// @notice Looping vault that is allowed to call this strategy.
    address public immutable vault;

    /// @notice Target leverage (e.g. 5e18 = 5x).
    uint256 public immutable targetLeverage; // scaled by 1e18

    modifier onlyVault() {
        require(msg.sender == vault, "Strategy: caller is not vault");
        _;
    }

    /// @param _weth Address of WETH token (vault underlying).
    /// @param _usdc Address of USDC token (debt asset).
    /// @param _eWeth Address of the Euler EVault for WETH.
    /// @param _eUsdc Address of the Euler EVault for USDC.
    /// @param _uniRouter Address of Uniswap V3 router.
    /// @param _vault Address of the LoopingETHVault that owns this strategy.
    /// @param _targetLeverage Target leverage (e.g. 5e18 for 5x).
    constructor(
        address _weth,
        address _usdc,
        address _eWeth,
        address _eUsdc,
        address _uniRouter,
        address _vault,
        uint256 _targetLeverage
    ) {
        require(_weth != address(0), "WETH address is zero");
        require(_usdc != address(0), "USDC address is zero");
        require(_eWeth != address(0), "eWETH address is zero");
        require(_eUsdc != address(0), "eUSDC address is zero");
        require(_uniRouter != address(0), "Router address is zero");
        require(_vault != address(0), "Vault address is zero");
        require(_targetLeverage >= 1e18, "Leverage must be >= 1x");

        weth = IERC20(_weth);
        usdc = IERC20(_usdc);
        eWeth = IEVault(_eWeth);
        eUsdc = IEVault(_eUsdc);
        uniRouter = ISwapRouterV3(_uniRouter);
        vault = _vault;
        targetLeverage = _targetLeverage;
    }

    // =========================
    //     ILeverageStrategy
    // =========================

    /// @notice Called by the vault after a user deposit of WETH.
    /// @dev High-level target flow for 5x leverage (example):
    ///      - Let equity = amount (WETH from user).
    ///      - Compute target position size in WETH: pos = equity * targetLeverage.
    ///      - Derive how much USDC you need as flash liquidity to reach that position.
    ///      - Flash loan USDC from eUsdc.
    ///      - Swap USDC -> WETH via Uniswap.
    ///      - Deposit total WETH (user + swapped) into eWeth as collateral.
    ///      - Borrow USDC from eUsdc against that collateral.
    ///      - Use borrowed USDC to repay the flash loan.
    function openPosition(uint256 amount) external override onlyVault {
        if (amount == 0) return;

        // 1) Pull WETH from the vault into this strategy.
        weth.safeTransferFrom(msg.sender, address(this), amount);

        // ============================
        //  A. Compute leverage numbers
        // ============================
        //
        // NOTE: For now you can hardcode something simple just to get the pattern working,
        //       and later replace with a proper formula using oracle prices.
        //
        // Example pseudo:
        //
        // uint256 equityWeth = amount;
        // uint256 targetPosWeth = equityWeth * targetLeverage / 1e18; // total WETH exposure wanted
        // uint256 extraWethNeeded = targetPosWeth - equityWeth;
        //
        // To get extraWethNeeded you will flash loan USDC and swap to WETH.
        // You will then borrow enough USDC so that, after repaying the flash loan,
        // the remaining state is:
        //   - eWeth: targetPosWeth supplied
        //   - eUsdc: some USDC debt
        //
        // For now, we leave this math as TODO.

        // ============================
        //  B. Flash loan USDC
        // ============================
        //
        // Here you will:
        //  - request a flash loan of `flashAmountUsdc` from eUsdc.
        //  - pass encoded data so that the callback knows:
        //      - how much WETH to buy
        //      - how much to deposit
        //      - how much USDC to borrow at the end
        //
        // PSEUDO-CODE (replace with actual EVault flashLoan API):
        //
        // bytes memory data = abi.encode(amount, /* any other params needed */);
        // eUsdc.flashLoan(address(this), address(usdc), flashAmountUsdc, data);
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
        weth.approve(address(eWeth), 0);
        weth.approve(address(eWeth), amount);
        eWeth.deposit(amount, address(this));
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
    ///        withdraw WETH from eWeth and send it back to the vault.
    function closePosition(uint256 assetsToReturn) external override onlyVault {
        if (assetsToReturn == 0) return;

        // TODO: once leverage is implemented, this must:
        //  - calculate proportional position to unwind,
        //  - repay part of eUsdc debt,
        //  - withdraw WETH collateral,
        //  - handle flash loan repays if used.

        // For now: simple withdraw from eWeth (no debt assumed).
        eWeth.withdraw(assetsToReturn, address(this), address(this));

        // Send WETH back to the vault so it can complete the ERC-4626 withdraw.
        weth.safeTransfer(msg.sender, assetsToReturn);
    }

    /// @notice Returns the net value managed by the strategy, denominated in WETH units.
    /// @dev Current simple version:
    ///      - Only considers WETH supplied to eWeth + idle WETH here.
    ///      Future version (with leverage):
    ///      - Must price:
    ///          * WETH collateral in eWeth
    ///          * USDC debt in eUsdc
    ///        using oracle prices, and return NAV in WETH.
    function totalAssets() external view override returns (uint256) {
        uint256 eShares = eWeth.balanceOf(address(this));
        uint256 supplied = eWeth.convertToAssets(eShares);
        uint256 idle = weth.balanceOf(address(this));

        // TODO: when you add leverage, subtract USDC debt valued in WETH terms.
        // uint256 usdcDebt = eUsdc.debtOf(address(this)); // or similar, check EVK API
        // uint256 usdcPriceInWeth = ...;                  // use price oracle
        // uint256 debtInWeth = usdcDebt * usdcPriceInWeth / 1e18;
        // return supplied + idle - debtInWeth;

        return supplied + idle;
    }
}
