// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ILeverageStrategy} from "../strategy/ILeverageStrategy.sol";
import {IWETH} from "../interfaces/IWETH.sol";

/// @notice ERC-4626 vault that accepts WETH as underlying
///         and delegates leverage logic to an external strategy.
/// @dev Users can deposit WETH directly via `deposit`/`mint`,
///      or deposit ETH via `depositETH`, which wraps to WETH and then deposits.
contract LoopingETHVault is ERC20, ERC4626 {
    using SafeERC20 for IERC20;

    /// @notice Override decimals to resolve ambiguity between ERC20 and ERC4626.
    function decimals() public view virtual override(ERC20, ERC4626) returns (uint8) {
        return ERC4626.decimals();
    }

    /// @notice Leverage strategy that manages the underlying position (Euler + Uniswap + flash loans).
    ILeverageStrategy public immutable strategy;

    /// @notice WETH token used as the underlying for this vault.
    IWETH public immutable weth;

    /// @param _weth Address of the WETH token (will be the ERC-4626 underlying).
    /// @param _strategy Address of the strategy contract managing the leveraged position.
    /// @param _name ERC-20 name for the vault shares.
    /// @param _symbol ERC-20 symbol for the vault shares.
    constructor(
        IERC20 _weth,
        ILeverageStrategy _strategy,
        string memory _name,
        string memory _symbol
    )
        ERC20(_name, _symbol)
        ERC4626(_weth)
    {
        require(address(_weth) != address(0), "WETH address is zero");
        require(address(_strategy) != address(0), "Strategy address is zero");

        strategy = _strategy;
        weth = IWETH(address(_weth));
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
        IERC20(address(weth)).approve(address(strategy), 0);
        IERC20(address(weth)).approve(address(strategy), assets);

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

    // =========================
    //      ETH CONVENIENCE
    // =========================

    /// @notice Convenience function: deposit ETH directly instead of WETH.
    /// @dev Wraps ETH into WETH, then calls the standard ERC-4626 `deposit`.
    /// @param receiver Address that will receive the vault shares.
    /// @return shares Amount of vault shares minted to `receiver`.
    function depositETH(address receiver) external payable returns (uint256 shares) {
        require(msg.value > 0, "No ETH sent");

        // 1) Wrap ETH into WETH. The ETH sent in this call is held by this contract,
        //    so we can safely call `deposit` on WETH with msg.value.
        weth.deposit{value: msg.value}();

        // 2) Now this contract holds `msg.value` WETH.
        //    Use the standard ERC-4626 deposit flow, where `caller` is this contract.
        shares = deposit(msg.value, receiver);
    }

    /// @notice Allow receiving ETH (required for WETH.deposit to work).
    receive() external payable {
        // This contract should only receive ETH from the WETH contract during unwrap,
        // or from users calling `depositETH`. No extra logic needed.
    }
}
