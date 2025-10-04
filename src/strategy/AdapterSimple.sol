// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IStrategyAdapter} from "./IStrategyAdapter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract AdapterSimple is IStrategyAdapter, Ownable {
    using SafeERC20 for IERC20;

    address public immutable VAULT;    
    address public immutable ASSET;      

    constructor(address _vault, address _asset, address _owner) Ownable(_owner) {
        require(_vault != address(0) && _asset != address(0), "ZERO");
        VAULT = _vault;
        ASSET = _asset;
    }

    modifier onlyVault() { require(msg.sender == VAULT, "ONLY_VAULT"); _; }

    function asset() external view returns (address) {
         return ASSET; 
    }

    function totalAssets() external view returns (uint256) {
        return IERC20(ASSET).balanceOf(address(this));
    }

    function afterDeposit(uint256 /*assets*/, bytes calldata /*data*/) external onlyVault {
    }

    function beforeWithdraw(uint256 assetsNeeded, bytes calldata /*data*/)
        external
        onlyVault
        returns (uint256 assetsFreed, uint256 loss)
    {
        uint256 bal = IERC20(ASSET).balanceOf(address(this));
        assetsFreed = bal < assetsNeeded ? bal : assetsNeeded;
        loss = assetsNeeded > bal ? (assetsNeeded - bal) : 0;

        if (assetsFreed > 0) {
            IERC20(ASSET).safeTransfer(VAULT, assetsFreed);
        }
    }
}
