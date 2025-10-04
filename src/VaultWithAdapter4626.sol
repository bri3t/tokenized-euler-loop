// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ERC4626} from "openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ReentrancyGuard} from "openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "openzeppelin/contracts/utils/Pausable.sol";
import {Ownable} from "openzeppelin/contracts/access/Ownable.sol";
import {SafeERC20} from "openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IStrategyAdapter} from "./strategy/IStrategyAdapter.sol";

contract VaultWithAdapter4626 is ERC4626, ERC20Permit, ReentrancyGuard, Pausable, Ownable {
    using SafeERC20 for IERC20;

    IStrategyAdapter public strategy;  
    uint256 public depositCap;         // 0 = no limit
    bool    public investOnDeposit = true;

    event StrategyUpdated(address indexed oldStrat1egy, address indexed newStrategy);
    event DepositCapUpdated(uint256 newCap);

    constructor(IERC20 _asset, string memory _name, string memory _symbol, address _owner)
        ERC20(_name, _symbol)
        ERC20Permit(_name)
        ERC4626(_asset)
        Ownable(_owner)
    {}

    // --- Admin ---
    function setStrategy(IStrategyAdapter newStrat) external onlyOwner {
        require(address(newStrat) != address(0), "ZERO");
        require(newStrat.asset() == address(asset()), "ASSET_MISMATCH");
        emit StrategyUpdated(address(strategy), address(newStrat));
        strategy = newStrat;
    }
    function setDepositCap(uint256 newCap) external onlyOwner { depositCap = newCap; emit DepositCapUpdated(newCap); }
    function setInvestOnDeposit(bool v) external onlyOwner { investOnDeposit = v; }
    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    function totalAssets() public view override returns (uint256) {
        uint256 idle = IERC20(asset()).balanceOf(address(this));
        address s = address(strategy);
        if (s == address(0)) return idle;
        return idle + IStrategyAdapter(s).totalAssets();
    }

    function deposit(uint256 assets, address receiver)
        public
        override
        nonReentrant
        whenNotPaused
        returns (uint256 shares)
    {
        require(assets != 0, "ZERO_ASSETS");

        // Todo change with maxDeposi
        if (depositCap != 0) require(totalAssets() + assets <= depositCap, "CAP_EXCEEDED");

        shares = super.deposit(assets, receiver);

        // todo change for an approve, so vault keeps de funds 
        if (investOnDeposit && address(strategy) != address(0)) {
            IERC20(asset()).safeTransfer(address(strategy), assets);
            strategy.afterDeposit(assets, bytes(""));
        }
    }

    function mint(uint256 shares, address receiver)
        public
        override
        nonReentrant
        whenNotPaused
        returns (uint256 assets)
    {
        require(shares > 0, "ZERO_SHARES");
        assets = previewMint(shares);
        if (depositCap != 0) require(totalAssets() + assets <= depositCap, "CAP_EXCEEDED");

        assets = super.mint(shares, receiver);

        if (investOnDeposit && address(strategy) != address(0)) {
            IERC20(asset()).safeTransfer(address(strategy), assets);
            strategy.afterDeposit(assets, bytes(""));
        }
    }

    function withdraw(uint256 assets, address receiver, address owner_)
        public
        override
        nonReentrant
        whenNotPaused
        returns (uint256 shares)
    {
        require(assets > 0, "ZERO_ASSETS");

        _prepareAssets(assets);

        shares = super.withdraw(assets, receiver, owner_);
    }

    function redeem(uint256 shares, address receiver, address owner_)
        public
        override
        nonReentrant
        whenNotPaused
        returns (uint256 assets)
    {
        require(shares > 0, "ZERO_SHARES");

        assets = previewRedeem(shares);
        if (assets > 0) _prepareAssets(assets);

        assets = super.redeem(shares, receiver, owner_);
    }

    // --- helpers ---
    // todo delete function??
    function _prepareAssets(uint256 needed) internal {
        uint256 idle = IERC20(asset()).balanceOf(address(this));
        if (idle >= needed) return;

        address s = address(strategy);
        if (s == address(0)) return; 

        (uint256 freed, ) = IStrategyAdapter(s).beforeWithdraw(needed - idle, bytes(""));
    }

    function decimals() public view override(ERC20, ERC4626) returns (uint8) {
        return super.decimals();
    }
}
