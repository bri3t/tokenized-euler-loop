// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {ILeverageVault} from "../interfaces/ILeverageVault.sol";

import {IEVault} from "euler-vault-kit/src/EVault/IEVault.sol";
import {IPriceOracle} from "euler-vault-kit/src/interfaces/IPriceOracle.sol";
import {IFlashLoan} from "euler-vault-kit/src/interfaces/IFlashLoan.sol";

import "@uniswap/v3-periphery/contracts/libraries/TransferHelper.sol";
import "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";

import "forge-std/console2.sol";

contract LeverageVault is ERC4626, Ownable, IFlashLoan, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Debt asset (borrow token B).
    IERC20 public immutable dToken;

    /// @notice Euler EVault for collateral token.
    IEVault public immutable cEVault;

    /// @notice Euler EVault for debt token (flash borrow).
    IEVault public immutable dEVault;

    /// @notice Euler EVault for flash loans of debt token.
    IEVault public immutable fEVault;

    ISwapRouter public immutable swapRouter;
    uint24 internal constant poolFee = 3000;

    /// @notice Maximum allowed slippage in basis points (e.g., 100 = 1%).
    uint256 internal constant MAX_BPS = 1e4; // 100% (MAX_BPS bps)
    uint256 internal constant MAX_SLIPPAGE_BPS = 1e2; // 1% (100 bps)

    uint256 internal constant ONE = 1e18;

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
    /// @param _swapper Address of the swapRouter contract (DEX/router abstraction).
    constructor(
        string memory _name,
        string memory _symbol,
        address _cEVault,
        address _dEVault,
        address _fEVault,
        address _dToken,
        ISwapRouter _swapper,
        uint256 _targetLeverage
    ) ERC20(_name, _symbol) ERC4626(IERC20(IEVault(_cEVault).asset())) Ownable(msg.sender) {
        if (
            _cEVault == address(0) || _dEVault == address(0) || _dToken == address(0) || _fEVault == address(0)
                || address(_swapper) == address(0)
        ) revert E_ZeroAddress();

        cEVault = IEVault(_cEVault);
        dEVault = IEVault(_dEVault);
        dToken = IERC20(_dToken);
        fEVault = IEVault(_fEVault);
        swapRouter = _swapper;
        targetLeverage = _targetLeverage;

        assetDecimals = ERC20(asset()).decimals();
        debtDecimals = ERC20(_dToken).decimals();

        // Validate target leverage against dEVault's LTV configuration
        // This prevents deploying a vault with impossible leverage target
        uint16 ltv = dEVault.LTVBorrow(address(cEVault));
        if (ltv > 1e4 || ltv == 0) {
            revert("LeverageVault: invalid LTV");
        }

        // Calculate max safe leverage: 1 / (1 - LTV)
        uint256 maxLeverage = (ONE * 1e4) / (1e4 - ltv);
        // change to if revert
        if (_targetLeverage < ONE || _targetLeverage > maxLeverage) {
            revert("LeverageVault: target leverage exceeds maximum");
        }
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
        s.assetsValue = (s.collateral * s.collateralPrice) / (10 ** ERC20(asset()).decimals());

        if (s.assetsValue <= s.debt) {
            // Underwater or zero equity: equity = 0, leverage = 0 (from our POV).
            s.equityValue = 0;
            s.leverage = 0;
            return s;
        }

        s.equityValue = s.assetsValue - s.debt;

        // Leverage L = A / E, 1e18-scaled.
        s.leverage = (s.equityValue != 0) ? ((s.assetsValue * ONE) / s.equityValue) : 0;
    }

    /// @dev Internal hook that rebalances the position to targetLeverage.
    ///      This only computes the required notional and calls the strategy hooks.
    function _rebalanceToTarget() internal {
        VaultState memory s = _getState();

        // If there is no equity, nothing to do.
        if (s.equityValue == 0) return;

        // Compute target assets value: A_target = L* * E
        uint256 targetAssetsValue = (targetLeverage * s.equityValue) / ONE;

        // Apply 1% tolerance band to avoid oscillations and unnecessary rebalances
        uint256 tol = targetAssetsValue / 100;
        if (tol == 0) tol = 1;

        uint256 delta;
        if (targetAssetsValue > s.assetsValue) {
            // Need to increase leverage by "delta" value in dToken units.
            delta = targetAssetsValue - s.assetsValue;
            if (delta > tol) _increaseLeverage(delta);
        } else if (targetAssetsValue < s.assetsValue) {
            // Need to decrease leverage by "delta" value in dToken units.
            delta = s.assetsValue - targetAssetsValue;
            if (delta > tol) _decreaseLeverage(delta, s);
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
        require(msg.sender == address(fEVault) && _reentrancyGuardEntered(), "onFlashLoan: not fEVault");

        (uint8 mode, uint256 delta) = abi.decode(data, (uint8, uint256));

        if (delta == 0) return;
        if (mode == 0) {
            // Increase leverage
            dToken.approve(address(swapRouter), delta);

            // Calculate minimum output based on oracle price with slippage tolerance
            uint256 price = _getPriceCInDebtNative();
            uint256 expectedCollateral = Math.mulDiv(delta, 10 ** assetDecimals, price);
            uint256 minCollateral = (expectedCollateral * (MAX_BPS - MAX_SLIPPAGE_BPS)) / MAX_BPS;
            ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
                tokenIn: address(dToken),
                tokenOut: address(asset()),
                fee: poolFee,
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: delta,
                amountOutMinimum: minCollateral,
                sqrtPriceLimitX96: 0
            });
            uint256 boughtCollateral = swapRouter.exactInputSingle(params);

            IERC20(asset()).approve(address(cEVault), boughtCollateral);
            cEVault.deposit(boughtCollateral, address(this));

            uint256 borrowed = dEVault.borrow(delta, address(this));
            dToken.safeTransfer(address(fEVault), borrowed);
        } else if (mode == 1) {
            // Decrease leverage

            // Repay debt first using flash loan, then withdraw collateral and swap to repay loan
            dToken.approve(address(dEVault), delta);
            dEVault.repay(delta, address(this));

            // Compute collateral needed to repay the flash loan
            uint256 price = _getPriceCInDebtNative();
            require(price > 0, "LeverageVault: invalid price");
            uint256 collateralForLoan = Math.mulDiv(delta, 10 ** assetDecimals, price, Math.Rounding.Ceil);

            // Withdraw collateral after debt reduced (should pass liquidity checks)
            cEVault.withdraw(collateralForLoan, address(this), address(this));

            // Swap asset -> dToken to repay flash loan
            IERC20(asset()).approve(address(swapRouter), collateralForLoan);

            ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
                tokenIn: address(asset()),
                tokenOut: address(dToken),
                fee: poolFee,
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: collateralForLoan,
                amountOutMinimum: delta,
                sqrtPriceLimitX96: 0
            });
            uint256 out = swapRouter.exactInputSingle(params);

            // Repay flash loan
            dToken.safeTransfer(address(fEVault), delta);

            // If we have excess tokens from the swap, use them to repay additional debt
            if (out > delta) {
                uint256 excess = out - delta;
                uint256 currentDebt = _debt();

                // Only repay if we still have debt remaining
                if (currentDebt > 0) {
                    // TODO: implementa a solution for excess that exceeds currentDebt, e.g. send to owner or keep in vault
                    uint256 toRepay = excess > currentDebt ? currentDebt : excess;
                    dToken.approve(address(dEVault), toRepay);
                    dEVault.repay(toRepay, address(this));
                }
            }
        } else {
            revert("onFlashLoan: unknown mode");
        }
    }

    /// @dev Decreases leverage by a notional "delta" denominated in dToken units (native smallest units).
    function _decreaseLeverage(uint256 delta, VaultState memory s) internal {
        if (delta == 0) return;

        // If there is no collateral or no debt, nothing to do.
        if (s.collateral == 0 || s.debt == 0) return;

        // Avoid removing more value than assetsValue or debt.
        if (delta > s.assetsValue) delta = s.assetsValue;

        // Also cap by debt.
        if (delta > s.debt) delta = s.debt;

        // 1) Compute how much collateral (asset()) we need to withdraw for value "delta".
        uint256 collateralToWithdraw = (delta * (10 ** ERC20(asset()).decimals())) / s.collateralPrice;
        if (collateralToWithdraw > s.collateral) {
            collateralToWithdraw = s.collateral;
        }

        // 2) Withdraw collateral from cEVault to this contract.
        cEVault.withdraw(collateralToWithdraw, address(this), address(this));

        // 3) Swap asset() -> dToken via the swapRouter.
        IERC20(asset()).approve(address(swapRouter), collateralToWithdraw);

        // Calculate minimum output based on oracle price with slippage tolerance
        uint256 price = s.collateralPrice;
        uint256 expectedDebt = Math.mulDiv(collateralToWithdraw, price, 10 ** assetDecimals);
        uint256 minDebt = (expectedDebt * (MAX_BPS - MAX_SLIPPAGE_BPS)) / MAX_BPS;

        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: address(asset()),
            tokenOut: address(dToken),
            fee: poolFee,
            recipient: address(this),
            deadline: block.timestamp,
            amountIn: collateralToWithdraw,
            amountOutMinimum: minDebt,
            sqrtPriceLimitX96: 0
        });
        uint256 receivedDebtToken = swapRouter.exactInputSingle(params);

        if (receivedDebtToken == 0) {
            revert("LeverageVault: swap returned zero");
        }

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

    /// @dev Returns price of 1 unit of collateral (asset()) in dToken units
    function _getPriceCInDebtNative() internal view returns (uint256) {
        address oracle = cEVault.oracle();
        address uoa = cEVault.unitOfAccount();

        // price of 1 asset() in unitOfAccount
        uint256 priceAssetInUoA = IPriceOracle(oracle).getQuote(ONE, asset(), uoa);

        // price of 1 dToken in unitOfAccount
        uint256 priceDebtInUoA = IPriceOracle(oracle).getQuote(ONE, address(dToken), uoa);

        require(priceAssetInUoA > 0 && priceDebtInUoA > 0, "Invalid oracle price");

        // ratio = (asset price / debt token price), scaled to 1e18
        uint256 ratio = (priceAssetInUoA * ONE) / priceDebtInUoA;

        uint256 priceCInDebt = (ratio * (10 ** debtDecimals)) / ONE;

        return priceCInDebt;
    }

    /// @notice Internal hook called by ERC-4626 after shares have been minted and assets have been pulled
    ///         from the user into this contract.
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        if (assets == 0 || shares == 0) revert("LeverageVault: zero deposit");

        // 1) Let the base ERC4626 handle accounting + pull of assets from caller.
        super._deposit(caller, receiver, assets, shares);

        // 2) Move deposited assets into cEVault as collateral.
        IERC20(asset()).approve(address(cEVault), assets);
        cEVault.deposit(assets, address(this));

        // 3) Rebalance global leverage towards targetLeverage.
        _rebalanceToTarget();
    }

    /// @notice Internal hook called by ERC-4626 before burning shares and transferring assets to receiver.
    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
        internal
        override
    {
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
        uint256 debtShare = Math.mulDiv(s.debt, shares, totalShares, Math.Rounding.Ceil);

        // 1) Repay the user's pro-rata share of the debt
        if (debtShare > 0) {
            // Request flash loan of dToken to repay debt before withdrawing collateral
            bytes memory data = abi.encode(uint8(1), debtShare); // mode 1: repay-then-withdraw
            fEVault.flashLoan(debtShare, data);
            debtShare = 0;
        }

        // 2) Withdraw the net assets to be delivered to the user
        if (assets > 0) {
            // Recalculate collateral after repaying the debt
            uint256 updatedCollateral = _collateralAssets();

            // We should not reach here under normal conditions
            if (updatedCollateral < assets) {
                revert("LeverageVault: insufficient collateral after debt repay");
            }

            // Second withdraw: user's equity in the form of asset()
            cEVault.withdraw(assets, address(this), address(this));
        }
    }

    /// @notice Total underlying assets managed by this vault (NAV), in asset() units.
    function totalAssets() public view override returns (uint256) {
        uint256 collateral = _collateralAssets(); // collateral amount in asset() units
        uint256 debt = _debt(); // debt amount in dToken units

        // If no position at all, NAV is zero.
        if (collateral == 0 && debt == 0) return 0;

        uint256 collateralPrice = _getPriceCInDebtNative(); // dToken per 1 asset() smallest unit
        // Value of collateral in debt token units (native smallest units)
        uint256 assetsValue = (collateral * collateralPrice) / (10 ** assetDecimals);

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

    function deposit(uint256 assets, address receiver) public override nonReentrant returns (uint256 shares) {
        shares = super.deposit(assets, receiver);
        if (shares == 0) revert("LeverageVault: zero shares minted");
        return shares;
    }

    function mint(uint256 shares, address receiver) public override nonReentrant returns (uint256 assets) {
        assets = super.mint(shares, receiver);
        if (assets == 0) revert("LeverageVault: zero assets deposited");
        return assets;
    }

    function withdraw(uint256 assets, address receiver, address owner)
        public
        override
        nonReentrant
        returns (uint256 shares)
    {
        return super.withdraw(assets, receiver, owner);
    }

    function redeem(uint256 shares, address receiver, address owner)
        public
        override
        nonReentrant
        returns (uint256 assets)
    {
        return super.redeem(shares, receiver, owner);
    }


}
