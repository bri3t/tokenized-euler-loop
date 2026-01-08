// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockPriceOracle} from "euler-vault-kit/test/mocks/MockPriceOracle.sol";
import "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";

/**
 * @title MockSwapRouterV3
 * @notice Mock implementation of Uniswap V3 SwapRouter for testing
 * @dev Uses the oracle to determine exchange rates for swaps
 */
contract MockSwapRouterV3 is ISwapRouter {
    MockPriceOracle public immutable oracle;
    address public immutable unitOfAccount;

    constructor(address _oracle, address _unitOfAccount) {
        oracle = MockPriceOracle(_oracle);
        unitOfAccount = _unitOfAccount;
    }

    function exactInputSingle(ExactInputSingleParams calldata params)
        external
        payable
        override
        returns (uint256 amountOut)
    {
        require(params.tokenIn != address(0) && params.tokenOut != address(0), "MockSwapRouterV3: zero token");
        require(params.amountIn > 0, "MockSwapRouterV3: zero amount");
        require(params.recipient != address(0), "MockSwapRouterV3: zero recipient");
        require(params.deadline >= block.timestamp, "MockSwapRouterV3: deadline expired");

        // 1) Pull tokenIn from the caller
        bool pulled = IERC20(params.tokenIn).transferFrom(msg.sender, address(this), params.amountIn);
        require(pulled, "MockSwapRouterV3: pull failed");

        // 2) Convert amountIn to Unit of Account (UoA)
        uint256 amountInUoA = oracle.getQuote(params.amountIn, params.tokenIn, unitOfAccount);
        require(amountInUoA > 0, "MockSwapRouterV3: amountInUoA is zero");

        // 3) Get price of 1 unit of tokenOut in UoA
        uint256 priceOutInUoA = oracle.getQuote(1e18, params.tokenOut, unitOfAccount);
        require(priceOutInUoA > 0, "MockSwapRouterV3: priceOutInUoA is zero");

        // 4) Calculate amountOut
        amountOut = (amountInUoA * 1e18) / priceOutInUoA;

        // 5) Check minimum output
        require(amountOut >= params.amountOutMinimum, "MockSwapRouterV3: insufficient output");

        // 6) Mint tokenOut to recipient
        (bool ok,) = params.tokenOut.call(abi.encodeWithSignature("mint(address,uint256)", params.recipient, amountOut));
        require(ok, "MockSwapRouterV3: mint failed");

        return amountOut;
    }

    function exactInput(ExactInputParams calldata params) external payable override returns (uint256 amountOut) {
        revert("MockSwapRouterV3: exactInput not implemented");
    }

    function exactOutputSingle(ExactOutputSingleParams calldata params)
        external
        payable
        override
        returns (uint256 amountIn)
    {
        revert("MockSwapRouterV3: exactOutputSingle not implemented");
    }

    function exactOutput(ExactOutputParams calldata params) external payable override returns (uint256 amountIn) {
        revert("MockSwapRouterV3: exactOutput not implemented");
    }

    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external override {
        revert("MockSwapRouterV3: uniswapV3SwapCallback not implemented");
    }
}
