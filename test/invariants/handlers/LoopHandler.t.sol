// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IEVault} from "euler-vault-kit/src/EVault/IEVault.sol";
import {IPriceOracle} from "euler-vault-kit/src/interfaces/IPriceOracle.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import "forge-std/console2.sol";

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
    bool public ppsDiverged;

    uint256 public lastPps; // assets per 1 share unit

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

    function getActor(uint256 idx) public view returns (address) {
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

        uint256 beforePps = _pps();

        try vault.deposit(amount, actor) returns (
            uint256 /*shares*/
        ) {
            ghostDeposited[actor] += amount;
            ghostTotalDeposited += amount;

            uint256 afterPps = _pps();
            _checkPps(beforePps, afterPps);
        } catch {}
        vm.stopPrank();
    }

    function act_withdrawFraction(uint256 fractionBps, uint256 idx) external {
        _pickActor(idx);

        fractionBps = bound(fractionBps, 1, 10_000);

        uint256 shares = vault.balanceOf(actor);
        if (shares == 0) return;

        uint256 maxAssets = vault.convertToAssets(shares);
        if (maxAssets == 0) return;

        uint256 toWithdraw = Math.mulDiv(maxAssets, fractionBps, 10_000);

        if (toWithdraw == 0) return;

        vm.startPrank(actor);

        uint256 beforePps = _pps();
        try vault.withdraw(toWithdraw, actor, actor) returns (uint256 assetsOut) {
            ghostRedeemed[actor] += assetsOut;
            ghostTotalRedeemed += assetsOut;
            uint256 afterPps = _pps();
            _checkPps(beforePps, afterPps);
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

        uint256 beforePps = _pps();
        try vault.redeem(toRedeem, actor, actor) returns (uint256 assetsOut) {
            lastRedeemSucceeded = true;

            ghostRedeemed[actor] += assetsOut;
            ghostTotalRedeemed += assetsOut;
            uint256 afterPps = _pps();
            _checkPps(beforePps, afterPps);
        } catch {}
        vm.stopPrank();

        if (lastRedeemSucceeded) {
            uint256 debtAfter = dEVault.debtOf(address(vault));
            if (debtAfter > debtBefore) debtIncreasedOnRedeem = true;
        }
    }

    /// @dev Adversarial action: skew oracle prices. Only included in adversarial campaign.
    function act_skewPrices(uint256 cPrice, uint256 dPrice) external {
        // Bounded but still "adversarial"
        cPrice = bound(cPrice, 1e12, 1e20);
        dPrice = bound(dPrice, 1e12, 1e20);

        prevCPrice = lastCPrice;
        prevDPrice = lastDPrice;

        (bool ok1,) = address(oracle)
            .call(abi.encodeWithSignature("setPrice(address,address,uint256)", address(cToken), unitOfAccount, cPrice));
        (bool ok2,) = address(oracle)
            .call(abi.encodeWithSignature("setPrice(address,address,uint256)", address(dToken), unitOfAccount, dPrice));
        // If calls fail, do nothing, continues.
        if (ok1 && ok2) {
            lastCPrice = cPrice;
            lastDPrice = dPrice;
        }
    }

    function act_rebalance() external {
        uint256 beforeLev = vault.currentLeverage();

        leverageDivergedOnRebalance = false;
        lastRebalanceSucceeded = false;

        // Try rebalance
        try vault.rebalance() {
            lastRebalanceSucceeded = true;
        } catch {}
        if (!lastRebalanceSucceeded) return;

        uint256 afterLev = vault.currentLeverage();
        lastLeverage = afterLev;

        // Heuristic: only consider divergence if price move is "small-ish"
        // (simulate keeper reacting to mild drift, not massive shocks)
        bool deltaOk = _deltaOk20pct();
        if (!deltaOk) return;

        uint256 target = vault.targetLeverage();
        uint256 beforeDist = beforeLev > target ? beforeLev - target : target - beforeLev;
        uint256 afterDist = afterLev > target ? afterLev - target : target - afterLev;

        // if (beforeDist == 0) return;

        uint256 tol = beforeDist / 20; // 5%
        if (tol == 0) tol = 1;

        // Only flag if we moved meaningfully away from target
        if (afterDist > beforeDist + tol) {
            leverageDivergedOnRebalance = true;
        }
    }

    /* --------------------------- Helpers ----------------------------- */

    function _pps() internal view returns (uint256) {
        if (vault.totalSupply() == 0) return 0;
        uint256 oneShare = 10 ** vault.decimals();
        return vault.convertToAssets(oneShare);
    }

    function _checkPps(uint256 beforePps, uint256 afterPps) internal {
        // Establish a baseline on the first non-zero PPS observation.
        if (beforePps == 0) {
            lastPps = afterPps;
            return;
        }

        // Allow tiny rounding dust (relative tolerance).
        uint256 eps = beforePps / 1e12; // 1e-12 relative
        if (eps == 0) eps = 1;

        uint256 diff = afterPps > beforePps ? afterPps - beforePps : beforePps - afterPps;
        if (diff > eps && vault.totalSupply() > 0) {
            ppsDiverged = true;
        }

        lastPps = afterPps;
    }

    function _deltaOk20pct() internal view returns (bool) {
        if (prevCPrice == 0 || prevDPrice == 0) return false;

        uint256 cDelta = lastCPrice > prevCPrice ? lastCPrice - prevCPrice : prevCPrice - lastCPrice;
        uint256 dDelta = lastDPrice > prevDPrice ? lastDPrice - prevDPrice : prevDPrice - lastDPrice;

        uint256 cRel = (cDelta * 1e18) / prevCPrice;
        uint256 dRel = (dDelta * 1e18) / prevDPrice;

        return (cRel <= 2e17) && (dRel <= 2e17);
    }
}
