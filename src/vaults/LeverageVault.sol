// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    ERC4626
} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {
    SafeERC20
} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {ILeverageVault} from "../interfaces/ILeverageVault.sol";

import {IEVault} from "euler-vault-kit/src/EVault/IEVault.sol";
import {IPriceOracle} from "euler-vault-kit/src/interfaces/IPriceOracle.sol";
import {IFlashLoan} from "euler-vault-kit/src/interfaces/IFlashLoan.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import "forge-std/console2.sol";

interface ISwapper {
    /// @notice Swaps 'amountIn' of tokenIn into tokenOut, sending the output to 'to'.
    /// @param tokenIn  Address of input token.
    /// @param tokenOut Address of output token.
    /// @param amountIn Amount of tokenIn to swap.
    /// @param minAmountOut Min acceptable amount of tokenOut (0 for now in tests).
    /// @param to Recipient of tokenOut.
    /// @return amountOut Actual amount of tokenOut received.
    function swapExactInput(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        address to
    ) external returns (uint256 amountOut);
}

contract LeverageVault is ERC4626, Ownable, IFlashLoan {
    using SafeERC20 for IERC20;

    /// @notice Debt asset (borrow token B).
    IERC20 public immutable dToken;

    /// @notice Euler EVault for collateral token.
    IEVault public immutable cEVault;

    /// @notice Euler EVault for debt token (flash borrow).
    IEVault public immutable dEVault;

    /// @notice Euler EVault for flash loans of debt token.
    IEVault public immutable fEVault;

    ISwapper public immutable swapper;

    /// @notice Target leverage (e.g. 5e18 = 5x).
    uint256 public immutable targetLeverage;

    uint8 public immutable assetDecimals;
    uint8 public immutable debtDecimals;

    struct VaultState {
        uint256 collateral; // in asset() smallest units
        uint256 debt; // in dToken smallest units
        uint256 assetsValue; // value of collateral in dToken smallest units
        uint256 equityValue; // NAV in dToken smallest units (max(equity, 0))
        uint256 leverage; // A / E, 1e18-scaled (0 if E==0)
        uint256 collateralPrice; // dToken smallest units per 1 asset() smallest unit
    }

    error E_ZeroAddress();

    /// @param _name ERC-20 name for the vault shares.
    /// @param _symbol ERC-20 symbol for the vault shares.
    /// @param _cEVault Address of the Euler EVault for collateral (asset()).
    /// @param _dEVault Address of the Euler EVault for debt.
    /// @param _dToken Address of the debt token.
    /// @param _fEVault Address of the Euler EVault for flash loans of debt token.
    /// @param _targetLeverage Target leverage (e.g. 5e18 for 5x).
    /// @param _swapper Address of the swapper contract (DEX/router abstraction).
    constructor(
        string memory _name,
        string memory _symbol,
        address _cEVault,
        address _dEVault,
        address _fEVault,
        address _dToken,
        address _swapper,
        uint256 _targetLeverage
    )
        ERC20(_name, _symbol)
        ERC4626(IERC20(IEVault(_cEVault).asset()))
        Ownable(msg.sender)
    {
        if (
            _cEVault == address(0) ||
            _dEVault == address(0) ||
            _dToken == address(0) ||
            _fEVault == address(0) ||
            _swapper == address(0)
        ) revert E_ZeroAddress();

        cEVault = IEVault(_cEVault);
        dEVault = IEVault(_dEVault);
        dToken = IERC20(_dToken);
        fEVault = IEVault(_fEVault);
        swapper = ISwapper(_swapper);
        targetLeverage = _targetLeverage;

        assetDecimals = ERC20(asset()).decimals();
        debtDecimals = ERC20(_dToken).decimals();
    }

    /// @dev Returns the current economic state of the vault.
    function _getState() internal view returns (VaultState memory s) {
        s.collateral = _collateralAssets();
        s.debt = _debt();
        s.collateralPrice = _getPriceCInDebtNative();

        if (s.collateral == 0 && s.debt == 0) {
            // Everything stays zero, leverage = 0
            return s;
        }
        // Collateral value in dToken units (native). Price is per smallest unit.
        s.assetsValue =
            (s.collateral * s.collateralPrice) /
            (10 ** ERC20(asset()).decimals());

        if (s.assetsValue <= s.debt) {
            // Underwater or zero equity: equity = 0, leverage = 0 (from our POV).
            s.equityValue = 0;
            s.leverage = 0;
            return s;
        }

        s.equityValue = s.assetsValue - s.debt;

        // Leverage L = A / E, 1e18-scaled.
        s.leverage = (s.equityValue != 0)
            ? ((s.assetsValue * 1e18) / s.equityValue)
            : 0;
    }

    /// @dev Internal hook that rebalances the position to targetLeverage.
    ///      This only computes the required notional and calls the strategy hooks.
    function _rebalanceToTarget() internal {
        VaultState memory s = _getState();

        // If there is no equity, nothing to do.
        if (s.equityValue == 0) return;

        // Compute target assets value: A_target = L* * E
        uint256 targetAssetsValue = (targetLeverage * s.equityValue) / 1e18;

        if (targetAssetsValue > s.assetsValue) {
            // Need to increase leverage by "delta" value in dToken units.
            uint256 delta = targetAssetsValue - s.assetsValue;
            _increaseLeverage(delta);
        } else if (targetAssetsValue < s.assetsValue) {
            // Need to decrease leverage by "delta" value in dToken units.
            uint256 delta = s.assetsValue - targetAssetsValue;
            _decreaseLeverage(delta);
        } else {
            // Already at exact target, nothing to do.
            return;
        }
    }

    /// @dev Increases leverage by a notional "delta" denominated in dToken units.
    function _increaseLeverage(uint256 delta) internal {
        bytes memory data = abi.encode(uint8(0), delta); // mode 0: increase leverage
        fEVault.flashLoan(delta, data);
    }

    function onFlashLoan(bytes calldata data) external override {
        require(msg.sender == address(fEVault), "onFlashLoan: not fEVault");

        (uint8 mode, uint256 delta) = abi.decode(data, (uint8, uint256));

        if (delta == 0) return;
        if (mode == 0) {
            // Increase leverage path
            dToken.approve(address(swapper), delta);
            uint256 boughtCollateral = swapper.swapExactInput(
                address(dToken),
                address(asset()),
                delta,
                0,
                address(this)
            );

            IERC20(asset()).approve(address(cEVault), boughtCollateral);
            cEVault.deposit(boughtCollateral, address(this));

            uint256 borrowed = dEVault.borrow(delta, address(this));
            dToken.safeTransfer(address(fEVault), borrowed);
        } else if (mode == 1) {
            // Repay debt first using flash loan, then withdraw collateral and swap to repay loan
            dToken.approve(address(dEVault), delta);
            dEVault.repay(delta, address(this));

            // Compute collateral needed to repay the flash loan
            uint256 price = _getPriceCInDebtNative();
            require(price > 0, "LeverageVault: invalid price");
            uint256 collateralForLoan = Math.mulDiv(
                delta,
                10 ** assetDecimals,
                price,
                Math.Rounding.Ceil
            );

            // Withdraw collateral after debt reduced (should pass liquidity checks)
            cEVault.withdraw(collateralForLoan, address(this), address(this));

            // Swap asset -> dToken to repay flash loan
            IERC20(asset()).approve(address(swapper), collateralForLoan);
            uint256 out = swapper.swapExactInput(
                address(asset()),
                address(dToken),
                collateralForLoan,
                0,
                address(this)
            );
            require(
                out >= delta,
                "LeverageVault: insufficient swap to repay loan"
            );

            dToken.safeTransfer(address(fEVault), delta);
        } else {
            revert("onFlashLoan: unknown mode");
        }
    }

    /// @dev Decreases leverage by a notional "delta" denominated in dToken units (native smallest units).
    function _decreaseLeverage(uint256 delta) internal {
        if (delta == 0) return;

        VaultState memory s = _getState();

        // If there is no collateral or no debt, nothing to do.
        if (s.collateral == 0 || s.debt == 0) return;

        // Avoid removing more value than assetsValue or debt.
        if (delta > s.assetsValue) delta = s.assetsValue;

        // Also cap by debt.
        if (delta > s.debt) delta = s.debt;

        // 1) Compute how much collateral (asset()) we need to withdraw for value "delta".
        uint256 collateralToWithdraw = (delta *
            (10 ** ERC20(asset()).decimals())) / s.collateralPrice;
        if (collateralToWithdraw > s.collateral)
            collateralToWithdraw = s.collateral;

        // 2) Withdraw collateral from cEVault to this contract.
        cEVault.withdraw(collateralToWithdraw, address(this), address(this));

        // 3) Swap asset() -> dToken via the swapper.
        IERC20(asset()).approve(address(swapper), collateralToWithdraw);
        uint256 receivedDebtToken = swapper.swapExactInput(
            address(asset()),
            address(dToken),
            collateralToWithdraw,
            0, // minAmountOut = 0 for now.
            address(this)
        );

        // 4) Repay part of the outstanding debt in dEVault.
        uint256 repayAmount = receivedDebtToken;
        if (repayAmount > s.debt) repayAmount = s.debt;

        dToken.approve(address(dEVault), repayAmount);
        dEVault.repay(repayAmount, address(this));
    }

    /// @dev Returns collateral amount in underlying asset() units.
    function _collateralAssets() internal view returns (uint256) {
        uint256 shares = cEVault.balanceOf(address(this));

        // EVault is ERC4626-compatible, so shares -> assets via convertToAssets
        return cEVault.convertToAssets(shares);
    }

    /// @dev Returns current debt in dToken units.
    function _debt() internal view returns (uint256) {
        // Euler EVault exposes debtOf(account)
        return dEVault.debtOf(address(this));
    }

    /// @dev Returns price of 1 unit of collateral (asset()) in dToken units (native smallest units per asset smallest unit).
    ///      Computes via unitOfAccount to avoid missing direct base->quote price in tests.
    function _getPriceCInDebtNative() internal view returns (uint256) {
        address oracle = cEVault.oracle();
        address uoa = cEVault.unitOfAccount();

        // price of 1 asset() in unitOfAccount
        uint256 priceAssetInUoA = IPriceOracle(oracle).getQuote(
            1e18,
            asset(),
            uoa
        );

        // price of 1 dToken in unitOfAccount
        uint256 priceDebtInUoA = IPriceOracle(oracle).getQuote(
            1e18,
            address(dToken),
            uoa
        );

        // ratio = (asset price / debt token price), scaled to 1e18
        uint256 ratio = (priceAssetInUoA * 1e18) / priceDebtInUoA;

        uint256 priceCInDebt = (ratio * (10 ** debtDecimals)) / 1e18;

        return priceCInDebt;
    }

    /// @notice Internal hook called by ERC-4626 after shares have been minted and assets have been pulled
    ///         from the user into this contract.
    function _deposit(
        address caller,
        address receiver,
        uint256 assets,
        uint256 shares
    ) internal override {
        // 1) Let the base ERC4626 handle accounting + pull of assets from caller.
        super._deposit(caller, receiver, assets, shares);

        // 2) Move deposited assets into cEVault as collateral.
        // NOTE: We increase allowance instead of setting exact to avoid resetting to 0 each time.
        IERC20(asset()).approve(address(cEVault), assets);
        cEVault.deposit(assets, address(this));

        // 3) Rebalance global leverage towards targetLeverage.
        _rebalanceToTarget();
    }

    /// @notice Internal hook called by ERC-4626 before burning shares and transferring assets to receiver.
    function _withdraw(
        address caller,
        address receiver,
        address owner,
        uint256 assets,
        uint256 shares
    ) internal override {
        // 1) Unwind position to enable this exact asset redemption
        _unwindForWithdraw(assets, shares);

        super._withdraw(caller, receiver, owner, assets, shares);
    }

    function _unwindForWithdraw(uint256 assets, uint256 shares) internal {
        if (shares == 0) return;

        VaultState memory s = _getState();

        // if there is no position, nothing to unwind
        if (s.collateral == 0 && s.debt == 0) return;

        // Price in native units: dToken_units per 1 asset_unit
        uint256 price = s.collateralPrice;
        if (price == 0) revert("LeverageVault: invalid price");

        // Vault must be solvent to allow withdrawals
        if (s.assetsValue <= s.debt) revert("LeverageVault: vault underwater");

        uint256 totalShares = totalSupply();
        if (totalShares == 0) revert("LeverageVault: no shares");

        // proportion of debt associated with these shares
        uint256 debtShare = Math.mulDiv(
            s.debt,
            shares,
            totalShares,
            Math.Rounding.Ceil
        );

        // 1) Repay the user's pro-rata share of the debt
        if (debtShare > 0) {
            // 1.a) Use idle dToken if available in the vault
            uint256 idleDebt = dToken.balanceOf(address(this));
            uint256 useIdle = idleDebt < debtShare ? idleDebt : debtShare;
            if (useIdle > 0) {
                dToken.approve(address(dEVault), useIdle);
                dEVault.repay(useIdle, address(this));
                debtShare -= useIdle;
            }

            // 1.b) If there is still debt to repay, use flash loan to avoid temporary insolvency
            if (debtShare > 0) {
                // Request flash loan of dToken to repay debt before withdrawing collateral
                bytes memory data = abi.encode(uint8(1), debtShare); // mode 1: repay-then-withdraw
                fEVault.flashLoan(debtShare, data);
                debtShare = 0;
            }
        }

        // 2) Withdraw the net assets to be delivered to the user
        if (assets > 0) {
            // Recalculate collateral after repaying the debt
            uint256 updatedCollateral = _collateralAssets();

            // We should not reach here under normal conditions
            if (updatedCollateral < assets)
                revert(
                    "LeverageVault: insufficient collateral after debt repay"
                );

            // Second withdraw: user's equity in the form of asset()
            cEVault.withdraw(assets, address(this), address(this));
        }

        // At this point:
        // - The user's pro-rata share of the debt has been repaid.
        // - The vault has at least `assets` units of asset() in its local balance.
        // super._withdraw takes care of:
        //   - _burn(owner, shares)
        //   - transfer(asset, receiver, assets)
    }

    /// @notice Total underlying assets managed by this vault (NAV), in asset() units.
    function totalAssets() public view override returns (uint256) {
        uint256 collateral = _collateralAssets(); // collateral amount in asset() units
        uint256 debt = _debt(); // debt amount in dToken units

        // If no position at all, NAV is zero.
        if (collateral == 0 && debt == 0) return 0;

        uint256 collateralPrice = _getPriceCInDebtNative(); // dToken per 1 asset() smallest unit
        // Value of collateral in debt token units (native smallest units)
        uint256 assetsValue = (collateral * collateralPrice) /
            (10 ** assetDecimals);

        // If underwater or equal, equity is zero.
        if (assetsValue <= debt) return 0;

        // Equity in debt token units.
        uint256 equityValue = assetsValue - debt;

        // Convert equity back to asset() units (native smallest units)
        uint256 eInC = (equityValue * (10 ** assetDecimals)) / collateralPrice;

        return eInC;
    }

    function rebalance() external onlyOwner {
        _rebalanceToTarget();
    }
}
