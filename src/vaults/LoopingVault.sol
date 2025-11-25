// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {ILeverageStrategy} from "../strategy/ILeverageStrategy.sol";
import {IWETH} from "../interfaces/IWETH.sol";

/// @notice ERC-4626 vault that accepts WETH as underlying
///         and delegates leverage logic to an external strategy.
/// @dev Users can deposit WETH directly via `deposit`/`mint`,
///      or deposit ETH via `depositETH`, which wraps to WETH and then deposits.
contract LoopingVault is ERC20, ERC4626, Ownable {
    using SafeERC20 for IERC20;

    /// @notice Override decimals to resolve ambiguity between ERC20 and ERC4626.
    function decimals() public view virtual override(ERC20, ERC4626) returns (uint8) {
        return ERC4626.decimals();
    }

    /// @notice Leverage strategy that manages the underlying position (Euler + Uniswap + flash loans).
    ILeverageStrategy public strategy;


    /// @param _asset Address of the WETH token (will be the ERC-4626 underlying).
    /// @param _name ERC-20 name for the vault shares.
    /// @param _symbol ERC-20 symbol for the vault shares.
    constructor(
        IERC20 _asset,
        string memory _name,
        string memory _symbol
    )
        ERC20(_name, _symbol)
        ERC4626(_asset)
        Ownable(msg.sender)
    {
        require(address(_asset) != address(0), "WETH address is zero");
    }

    /// @param _strategy Address of the strategy contract managing the leveraged position.
    function setStrategy(ILeverageStrategy _strategy) external onlyOwner {
        strategy = _strategy;
    }

    // =========================
    //        VIEW LOGIC
    // =========================

    /// @notice Total underlying assets managed by this vault (NAV).
    /// @dev Delegates to the strategy, which must account for:
    ///      - collateral in Euler
    ///      - debt in Euler
    ///      - any idle balances under its control
    function totalAssets() public view override returns (uint256) {
        return strategy.totalAssets();
    }

    // =========================
    //      DEPOSIT / WITHDRAW
    // =========================

    /// @notice Internal hook called by ERC-4626 after shares have been minted and assets have been pulled
    ///         from the user into this contract.
    /// @dev At this point the vault holds `assets` WETH. We forward them to the strategy
    ///      so it can build/update the leveraged position.
    function _deposit(
        address caller,
        address receiver,
        uint256 assets,
        uint256 shares
    ) internal override {
        // 1) Let the base ERC4626 handle accounting + pull of assets from caller
        super._deposit(caller, receiver, assets, shares);

        // 2) Vault now holds `assets` WETH.
        //    Approve and delegate to strategy to open/update the leveraged position.
        IERC20(address(asset())).approve(address(strategy), assets);

        strategy.openPosition(assets);
    }

    /// @notice Internal hook called by ERC-4626 before burning shares and transferring assets to receiver.
    /// @dev We first ask the strategy to unwind enough of the leveraged position
    ///      so that this vault holds at least `assets` WETH, then the base ERC4626
    ///      will handle accounting + transfer to receiver.
    function _withdraw(
        address caller,
        address receiver,
        address owner,
        uint256 assets,
        uint256 shares
    ) internal override {
        // 1) Ask the strategy to close a proportional part of the position and
        //    send `assets` WETH back to this vault.
        strategy.closePosition(assets);

        // 2) Now that this vault holds the WETH to return, let ERC4626 do accounting + transfer.
        super._withdraw(caller, receiver, owner, assets, shares);
    }

}
