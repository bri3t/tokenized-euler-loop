// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockPriceOracle} from "euler-vault-kit/test/mocks/MockPriceOracle.sol";

interface ISwapper {
    function swapExactInput(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 /*minAmountOut*/,
        address to
    ) external returns (uint256 amountOut);
}

contract MockSwapper is ISwapper {
    MockPriceOracle public immutable oracle;
    address public immutable unitOfAccount;

    constructor(address _oracle, address _unitOfAccount) {
        oracle = MockPriceOracle(_oracle);
        unitOfAccount = _unitOfAccount;
    }

    function swapExactInput(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 /*minAmountOut*/,
        address to
    ) external override returns (uint256 amountOut) {
        require(
            tokenIn != address(0) && tokenOut != address(0),
            "MockSwapper: zero token"
        );
        require(amountIn > 0, "MockSwapper: zero amount");
        require(to != address(0), "MockSwapper: zero recipient");

        // 1) Pull tokenIn from the caller (vault) – simulate consuming the swap input
        bool pulled = IERC20(tokenIn).transferFrom(
            msg.sender,
            address(this),
            amountIn
        );
        require(pulled, "MockSwapper: pull failed");

        // 2) Convert amountIn to Unit of Account (UoA) using the oracle (tokenIn -> unitOfAccount)
        uint256 amountInUoA = oracle.getQuote(amountIn, tokenIn, unitOfAccount);
        require(amountInUoA > 0, "MockSwapper: amountInUoA is zero");

        // 3) Price of 1 unit of tokenOut in UoA
        //    getQuote(1e18, tokenOut, unitOfAccount) -> price per 1 tokenOut in UoA
        uint256 priceOutInUoA = oracle.getQuote(1e18, tokenOut, unitOfAccount);
        require(priceOutInUoA > 0, "MockSwapper: priceOutInUoA is zero");

        // 4) amountOut (in tokenOut units) = amountInUoA / priceOutPerTokenOut
        //    Note the 1e18 scaling: both amountInUoA and priceOutInUoA use 18 decimals in UoA
        amountOut = (amountInUoA * 1e18) / priceOutInUoA;

        // 5) Mint tokenOut to recipient (leveraging TestERC20's public mint in tests)
        (bool ok, ) = tokenOut.call(
            abi.encodeWithSignature("mint(address,uint256)", to, amountOut)
        );
        require(ok, "MockSwapper: mint failed");

        return amountOut;
    }
}
