// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IEVault} from "euler-vault-kit/src/EVault/IEVault.sol";
import {IPriceOracle} from "euler-vault-kit/src/interfaces/IPriceOracle.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {LeverageVault} from "../../../src/vaults/LeverageVault.sol";
import {TestERC20} from "euler-vault-kit/test/mocks/TestERC20.sol";

/// @dev Only contains fuzzable actions + ghost state, no deployment logic.
contract LoopHandler is Test {
    /* -------------------- Refs (system under test) ------------------- */
    LeverageVault public vault;
    IEVault public cEVault;
    IEVault public dEVault;
    IEVault public fEVault;
    TestERC20 public cToken;
    TestERC20 public dToken;
    address public unitOfAccount;

    IPriceOracle public oracle;

    address[] public actors;
    address public actor;

    /* ------------------------ Ghost variables ------------------------ */
    mapping(address => uint256) public ghostDeposited; // cToken assets deposited into LeverageVault
    mapping(address => uint256) public ghostRedeemed; // cToken assets received out of LeverageVault

    uint256 public ghostTotalDeposited;
    uint256 public ghostTotalRedeemed;

    /* -------------------- Debug / invariant flags -------------------- */
    bool public debtIncreasedOnRedeem;
    bool public leverageDivergedOnRebalance;

    bool public lastRedeemSucceeded;
    bool public lastRebalanceSucceeded;

    uint256 public lastCPrice;
    uint256 public lastDPrice;
    uint256 public prevCPrice;
    uint256 public prevDPrice;

    uint256 public lastLeverage;

    struct Refs {
        LeverageVault vault;
        IEVault cEVault;
        IEVault dEVault;
        IEVault fEVault;
        TestERC20 cToken;
        TestERC20 dToken;
        IPriceOracle oracle;
        address unitOfAccount;
    }

    constructor(Refs memory r, address[] memory _actors) {
        vault = r.vault;
        cEVault = r.cEVault;
        dEVault = r.dEVault;
        fEVault = r.fEVault;
        cToken = r.cToken;
        dToken = r.dToken;
        oracle = r.oracle;
        unitOfAccount = r.unitOfAccount;

        actors = _actors;
        actor = _actors.length > 0 ? _actors[0] : address(0);

        // Initialize price tracking with current oracle values
        lastCPrice = 3000e18;
        lastDPrice = 1e18;
        prevCPrice = lastCPrice;
        prevDPrice = lastDPrice;
    }

    /* --------------------------- Actor utils ------------------------- */

    function numActors() external view returns (uint256) {
        return actors.length;
    }

    function getActor(uint256 idx) public view returns (address) {
        if (actors.length == 0) return address(0);
        return actors[idx % actors.length];
    }

    function _pickActor(uint256 idx) internal {
        actor = getActor(idx);
    }

    /* -------------------------- Fuzz actions ------------------------- */

    function act_deposit(uint256 amount, uint256 idx) external {
        _pickActor(idx);

        // Keep within reasonable range for gas + to avoid insane overflows
        amount = bound(amount, 1e6, 1e21);

        cToken.mint(actor, amount);

        vm.startPrank(actor);
        cToken.approve(address(vault), amount);

        try vault.deposit(amount, actor) returns (uint256 /*shares*/) {
            ghostDeposited[actor] += amount;
            ghostTotalDeposited += amount;
        } catch {}
        vm.stopPrank();
    }

    function act_redeemFraction(uint256 fractionBps, uint256 idx) external {
        _pickActor(idx);

        fractionBps = bound(fractionBps, 1, 10_000);

        uint256 shares = vault.balanceOf(actor);
        if (shares == 0) return;

        uint256 toRedeem = Math.mulDiv(shares, fractionBps, 10_000);
        if (toRedeem == 0) return;

        uint256 debtBefore = dEVault.debtOf(address(vault));

        vm.startPrank(actor);
        lastRedeemSucceeded = false;

        try vault.redeem(toRedeem, actor, actor) returns (uint256 assetsOut) {
            lastRedeemSucceeded = true;

            // Ghost accounting: track what the actor received
            ghostRedeemed[actor] += assetsOut;
            ghostTotalRedeemed += assetsOut;
        } catch {
            // Swallow
        }
        vm.stopPrank();

        if (lastRedeemSucceeded) {
            uint256 debtAfter = dEVault.debtOf(address(vault));

            // Use a slightly safer epsilon than "2 wei"
            // - allow tiny dust + tiny accrual quirks
            uint256 eps = _debtEpsilon(debtBefore);
            if (debtAfter > debtBefore + eps) {
                debtIncreasedOnRedeem = true;
            }
        }
    }

    /// @dev Adversarial action: skew oracle prices. Only include in adversarial campaign.
    function act_skewPrices(uint256 cPrice, uint256 dPrice) external {
        // Bounded but still "adversarial"
        cPrice = bound(cPrice, 1e12, 1e20);
        dPrice = bound(dPrice, 1e12, 1e20);

        prevCPrice = lastCPrice;
        prevDPrice = lastDPrice;

        // Note: oracle interface IPriceOracle doesn't include setPrice, this is a mock.
        (bool ok1, ) = address(oracle).call(
            abi.encodeWithSignature(
                "setPrice(address,address,uint256)",
                address(cToken),
                unitOfAccount,
                cPrice
            )
        );
        (bool ok2, ) = address(oracle).call(
            abi.encodeWithSignature(
                "setPrice(address,address,uint256)",
                address(dToken),
                unitOfAccount,
                dPrice
            )
        );
        // If calls fail, do nothing, continues.
        if (ok1 && ok2) {
            lastCPrice = cPrice;
            lastDPrice = dPrice;
        }
    }

    function act_rebalance() external {
        uint256 beforeLev = _currentLeverage();

        leverageDivergedOnRebalance = false;
        lastRebalanceSucceeded = false;

        // Try rebalance
        try vault.rebalance() {
            lastRebalanceSucceeded = true;
        } catch {
            // Swallow
        }
        if (!lastRebalanceSucceeded) return;

        uint256 afterLev = _currentLeverage();
        lastLeverage = afterLev;

        // Heuristic: only consider divergence if price move is "small-ish"
        // (simulate keeper reacting to mild drift, not massive shocks)
        bool deltaOk = _deltaOk20pct();
        if (!deltaOk) return;

        uint256 target = vault.targetLeverage();
        uint256 beforeDist = beforeLev > target
            ? beforeLev - target
            : target - beforeLev;
        uint256 afterDist = afterLev > target
            ? afterLev - target
            : target - afterLev;

        if (beforeDist == 0) return;

        uint256 tol = beforeDist / 20; // 5%
        if (tol == 0) tol = 1;

        // Only flag if we moved meaningfully away from target
        if (afterDist > beforeDist + tol) {
            leverageDivergedOnRebalance = true;
        }
    }

    /* --------------------------- Helpers ----------------------------- */

    function _deltaOk20pct() internal view returns (bool) {
        if (prevCPrice == 0 || prevDPrice == 0) return false;
        uint256 cP = lastCPrice;
        uint256 dP = lastDPrice;

        uint256 cDelta = cP > prevCPrice ? cP - prevCPrice : prevCPrice - cP;
        uint256 dDelta = dP > prevDPrice ? dP - prevDPrice : prevDPrice - dP;

        uint256 cRel = (cDelta * 1e18) / prevCPrice;
        uint256 dRel = (dDelta * 1e18) / prevDPrice;

        return (cRel <= 2e17) && (dRel <= 2e17);
    }

    function _debtEpsilon(uint256 debtBefore) internal pure returns (uint256) {
        uint256 absDust = 1e6; // 1e6 wei of debt token
        uint256 relDust = debtBefore / 1e12; // 1e-12 relative
        if (relDust < absDust) return absDust;
        return relDust;
    }

    function _currentLeverage() internal view returns (uint256) {
        uint256 collateral = cEVault.convertToAssets(
            cEVault.balanceOf(address(vault))
        );
        uint256 debt = dEVault.debtOf(address(vault));
        if (collateral == 0 && debt == 0) return 0;

        address oracleAddr = cEVault.oracle();
        address uoa = cEVault.unitOfAccount();

        uint256 priceAssetInUoA = IPriceOracle(oracleAddr).getQuote(
            1e18,
            address(cToken),
            uoa
        );
        uint256 priceDebtInUoA = IPriceOracle(oracleAddr).getQuote(
            1e18,
            address(dToken),
            uoa
        );
        if (priceDebtInUoA == 0) return 0;

        uint256 ratio = (priceAssetInUoA * 1e18) / priceDebtInUoA;

        uint256 debtDecimals = ERC20(address(dToken)).decimals();
        uint256 assetDecimals = ERC20(address(cToken)).decimals();

        uint256 priceCInDebt = (ratio * (10 ** debtDecimals)) / 1e18;
        uint256 assetsValue = (collateral * priceCInDebt) /
            (10 ** assetDecimals);

        if (assetsValue <= debt || assetsValue == 0) return 0;

        uint256 equityValue = assetsValue - debt;
        return (assetsValue * 1e18) / equityValue;
    }
}
