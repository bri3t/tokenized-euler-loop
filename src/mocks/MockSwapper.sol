// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// Minimal interface matching LeverageVault's ISwapper expectations
interface ISwapper {
    function swapExactInput(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 /*minAmountOut*/,
        address to
    ) external returns (uint256 amountOut);
}

// Test-only swapper that performs 1:1 swaps using TestERC20 semantics:
// - Pulls tokenIn from caller (must approve)
// - Mints tokenOut to recipient for same amount
// This relies on EVK's TestERC20 allowing public mint in tests.
contract MockSwapper is ISwapper {
    function swapExactInput(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 /*minAmountOut*/,
        address to
    ) external override returns (uint256 amountOut) {
        require(tokenIn != address(0) && tokenOut != address(0), "MockSwapper: zero token");
        require(amountIn > 0, "MockSwapper: zero amount");
        require(to != address(0), "MockSwapper: zero recipient");

        // Credit tokenOut to recipient 1:1 (do not pull tokenIn for test simplicity)
        // The EVK TestERC20 exposes mint(address,uint256) but not via IERC20.
        // Use low-level call for mint to be compatible in tests.
        (bool ok, ) = tokenOut.call(abi.encodeWithSignature("mint(address,uint256)", to, amountIn));
        require(ok, "MockSwapper: mint failed");

        return amountIn;
    }
}
