// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
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

    /// @notice Euler EVault for debt token (flash + borrow).
    IEVault public immutable dEVault;

    /// @notice Euler EVault for collateral token.
    IEVault public immutable cEVault;


    ISwapper public immutable swapper;

    /// @notice Target leverage (e.g. 5e18 = 5x).
    uint256 public immutable targetLeverage;

    struct VaultState {
        uint256 collateral;      // in asset() units
        uint256 debt;            // in dToken units
        uint256 assetsValue;     // value of collateral in dToken units
        uint256 equityValue;     // NAV in dToken units (max(equity, 0))
        uint256 leverage;        // A / E, 1e18-scaled (0 if E==0)
        uint256 collateralPrice; // price of 1 asset() in dToken (1e18-scaled)
    }
    
    /// @param _asset ERC-4626 underlying, e.g. WETH (collateral token C).
    /// @param _name ERC-20 name for the vault shares.
    /// @param _symbol ERC-20 symbol for the vault shares.
    /// @param _cEVault Address of the Euler EVault for collateral (asset()).
    /// @param _dEVault Address of the Euler EVault for debt.
    /// @param _dToken Address of the debt token.
    /// @param _targetLeverage Target leverage (e.g. 5e18 for 5x).
    /// @param _swapper Address of the swapper contract (DEX/router abstraction).
    constructor(
        IERC20 _asset,
        string memory _name,
        string memory _symbol,
        address _cEVault,
        address _dEVault,
        address _dToken,
        address _swapper,
        uint256 _targetLeverage
    )
        ERC20(_name, _symbol)
        ERC4626(_asset)
        Ownable(msg.sender)
    {
        require(address(_asset) != address(0), "asset is zero");
        require(_cEVault != address(0), "cEVault is zero");
        require(_dEVault != address(0), "dEVault is zero");
        require(_dToken != address(0), "dToken is zero");
        require(_swapper != address(0), "swapper is zero");

        // Collateral EVault must manage the same asset as this ERC4626.
        require(IEVault(_cEVault).asset() == address(_asset), "cEVault asset mismatch");
        // Debt EVault must manage the debt token.
        require(IEVault(_dEVault).asset() == address(_dToken), "dEVault asset mismatch");

        cEVault = IEVault(_cEVault);
        dEVault = IEVault(_dEVault);
        dToken = IERC20(_dToken);
        swapper = ISwapper(_swapper);
        targetLeverage = _targetLeverage;
    }


    /// @dev Returns the current economic state of the vault.
    function _getState() internal view returns (VaultState memory s) {
        s.collateral = _collateralAssets();
        s.debt = _debt();
        s.collateralPrice = _getPriceCInDebt();

        if (s.collateral == 0 && s.debt == 0) {
            // Everything stays zero, leverage = 0
            return s;
        }

        // Collateral value in dToken units.
        s.assetsValue = s.collateral * s.collateralPrice / 1e18;

        if (s.assetsValue <= s.debt) {
            // Underwater or zero equity: equity = 0, leverage = 0 (from our POV).
            s.equityValue = 0;
            s.leverage = 0;
            return s;
        }

        s.equityValue = s.assetsValue - s.debt;

        // Leverage L = A / E, 1e18-scaled.
        s.leverage = (s.equityValue > 0)
            ? (s.assetsValue * 1e18 / s.equityValue)
            : 0;
    }


    /// @dev Internal hook that rebalances the position to targetLeverage.
    ///      This only computes the required notional and calls the strategy hooks.
    function _rebalanceToTarget() internal {
        VaultState memory s = _getState();

        // If there is no equity, nothing to do.
        if (s.equityValue == 0) return;

        // Compute target assets value: A_target = L* * E
        uint256 targetAssetsValue = targetLeverage * s.equityValue / 1e18;
        console2.log(" targetAssetsValue   :", targetAssetsValue);
        console2.log(" current assetsValue :", s.assetsValue);

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
        if (delta == 0) return;

        bytes memory data = abi.encode(delta);
        dEVault.flashLoan(delta, data);
    }


    function onFlashLoan(bytes calldata data) external override {
        require(msg.sender == address(dEVault), "onFlashLoan: not dEVault");

        uint256 delta = abi.decode(data, (uint256));

        if (delta == 0) return;

        // 1) Swap dToken -> asset()
        dToken.approve(address(swapper), delta);
        uint256 boughtCollateral = swapper.swapExactInput(
            address(dToken),
            address(asset()),
            delta,
            0,              // TODO: put a real minAmountOut with slippage
            address(this)
        );

        // 2) Deposit asset() in cEVault as collateral
        IERC20(asset()).approve(address(cEVault), boughtCollateral);
        cEVault.deposit(boughtCollateral, address(this));

        // 3) Open permanent debt in dEVault for `delta`
        uint256 borrowed = dEVault.borrow(delta, address(this));

        // 4) Repay the flash loan: send the dToken back to dEVault
        dToken.safeTransfer(address(dEVault), borrowed);
    }



    /// @dev Decreases leverage by a notional "delta" denominated in dToken units.
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
        uint256 collateralToWithdraw = delta * 1e18 / s.collateralPrice;
        if (collateralToWithdraw > s.collateral) collateralToWithdraw = s.collateral;

        // 2) Withdraw collateral from cEVault to this contract.
        cEVault.withdraw(collateralToWithdraw, address(this), address(this));

        // 3) Swap asset() -> dToken via the swapper.
        IERC20(asset()).approve(address(swapper), collateralToWithdraw);
        uint256 receivedDebtToken = swapper.swapExactInput(
            address(asset()),
            address(dToken),
            collateralToWithdraw,
            0,                  // minAmountOut = 0 for now.
            address(this)
        );

        if (receivedDebtToken == 0) return;

        // 4) Repay part of the outstanding debt in dEVault.
        uint256 repayAmount = receivedDebtToken;
        if (repayAmount > s.debt) repayAmount = s.debt;

        dToken.approve(address(dEVault), repayAmount);
        dEVault.repay(repayAmount, address(this));
    }



    /// @dev Returns collateral amount in underlying asset() units.
    function _collateralAssets() internal view returns (uint256) {
        uint256 shares = cEVault.balanceOf(address(this));
        if (shares == 0) return 0;

        // EVault is ERC4626-compatible, so shares -> assets via convertToAssets
        return cEVault.convertToAssets(shares);
    }

    /// @dev Returns current debt in dToken units.
    function _debt() internal view returns (uint256) {
        // Euler EVault exposes debtOf(account)
        return dEVault.debtOf(address(this));
    }

    /// @dev Returns price of 1 unit of collateral (asset()) in dToken units, 1e18-scaled.
    ///      For now stubbed to 1e18 (1:1). 
    function _getPriceCInDebt() internal view returns (uint256) {
        address oracle = cEVault.oracle();

        uint8 cDec = ERC20(asset()).decimals();
        uint8 dDec = ERC20(address(dToken)).decimals();
    
        uint256 oneC = 10 ** cDec;

        
        uint out = IPriceOracle(oracle).getQuote(
            oneC, 
            asset(), 
            address(dToken)
        );

        // return out scaled to 1e18
        return out * 1e18 / (10 ** dDec);
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
        // 1) Unwind proportional position in Euler before burning shares
        _unwindForWithdraw(shares);

        super._withdraw(caller, receiver, owner, assets, shares);
    }

    function _unwindForWithdraw(uint256 shares) internal {
        if (shares == 0) return;

        VaultState memory s = _getState();

        // If there is no position, nothing to unwind
        if (s.collateral == 0 || s.debt == 0) return;

        // If underwater, cannot unwind
        if (s.assetsValue <= s.debt) revert("LeverageVault: vault underwater");

        // else, the vault is solvent, so can pro-rata unwind
        
        uint256 totalShares = totalSupply();
        if (totalShares == 0) return;

        // r = shares / totalShares (proportion of the position to unwind)
        // C_user = C * r
        // D_user = D * r
        uint256 collateralToWithdraw = Math.mulDiv(s.collateral, shares, totalShares);
        uint256 debtToRepay          = Math.mulDiv(s.debt, shares, totalShares);


        // 1) Withdraw user's proportional collateral from cEVault
        if (collateralToWithdraw > 0) { 
            cEVault.withdraw(collateralToWithdraw, address(this), address(this));
        }

        if (debtToRepay == 0) return; // TODO: maybe not needed verification

        // price = dToken per 1 asset(), 1e18 scaled
        uint256 price = s.collateralPrice;
        if (price == 0) return;

        // 2) Compute how much collateral we need to sell to get `debtToRepay` dToken
        uint256 collateralForDebt = (debtToRepay * 1e18) / price;

        if (collateralForDebt > collateralToWithdraw) {
            collateralForDebt = collateralToWithdraw;
        }

        // 3) Swap asset() -> dToken to repay that slice of debt
        IERC20(asset()).approve(address(swapper), collateralForDebt);
        uint256 amountOut = swapper.swapExactInput(
            address(asset()),
            address(dToken),
            collateralForDebt,
            0, // TODO: real minAmountOut for slippage protection
            address(this)
        );

        if (amountOut < debtToRepay) revert("LeverageVault: insufficient swap output to repay debt");

        // Repay up to the proportional debt slice
        uint256 repayAmount = amountOut;

        dToken.approve(address(dEVault), repayAmount);
        dEVault.repay(repayAmount, address(this));

        // Note: the collateral we did NOT sell (collateralToWithdraw - collateralForDebt)
        // remains as free asset() in this contract.
        // That is the pool from which super._withdraw will take `assets` for the user.
    }


    /// @notice Total underlying assets managed by this vault (NAV), in asset() units.
    function totalAssets() public view override returns (uint256) {
        uint256 collateral = _collateralAssets(); // collateral amount in asset() units
        uint256 debt = _debt();          // debt amount in dToken units

        // If no position at all, NAV is zero.
        if (collateral == 0 && debt == 0) return 0;

        uint256 collateralPrice = _getPriceCInDebt(); // dToken per 1 cToken, 1e18-scale

        // Value of collateral in deb t token units.
        uint256 assetsValue = collateral * collateralPrice / 1e18;

        // If underwater or equal, equity is zero.
        if (assetsValue <= debt) return 0;

        // Equity in debt token units.
        uint256 equityValue = assetsValue - debt;

        // Convert equity back to asset() units.
        uint256 eInC = equityValue * 1e18 / collateralPrice;

        return eInC;
    }


    function rebalance() external onlyOwner {
        _rebalanceToTarget();
    }


}
