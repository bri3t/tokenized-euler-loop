// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "forge-std/console2.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {EulerETHLeverageStrategy} from "../src/strategy/EulerETHLeverageStrategy.sol";
import {ISwapRouterV3} from "../src/interfaces/ISwapRouterV3.sol";

// -------------------------
//   Mocks
// -------------------------

/// @notice Simple ERC20 mock with public mint function.
contract MockERC20 is ERC20 {
    uint8 private _decimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Minimal EVault-like mock used by the strategy.
/// @dev It only implements the functions that the strategy actually calls:
///      - deposit(uint256,address)
///      - withdraw(uint256,address,address)
///      - balanceOf(address)
///      - convertToAssets(uint256)
///      Internamente asumimos 1 share = 1 underlying (sin intereses, sin deuda).
contract MockEVault {
    IERC20 public immutable underlying;

    mapping(address => uint256) internal _shares;
    uint256 internal _totalShares;
    uint256 internal _totalUnderlying;

    constructor(IERC20 _underlying) {
        underlying = _underlying;
    }

    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        require(assets > 0, "assets=0");

        // Transfer underlying from caller (strategy) to this EVault
        underlying.transferFrom(msg.sender, address(this), assets);

        // 1:1 shares
        shares = assets;
        _shares[receiver] += shares;
        _totalShares += shares;
        _totalUnderlying += assets;
    }

    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares) {
        require(assets > 0, "assets=0");
        // 1:1 shares
        shares = assets;
        require(_shares[owner] >= shares, "insufficient shares");

        _shares[owner] -= shares;
        _totalShares -= shares;
        _totalUnderlying -= assets;

        // Send underlying to receiver
        underlying.transfer(receiver, assets);
    }

    function balanceOf(address account) external view returns (uint256) {
        return _shares[account];
    }

    function convertToAssets(uint256 shares) external pure returns (uint256) {
        // 1:1 for this mock
        return shares;
    }

    // Helper para los asserts del test
    function totalUnderlying() external view returns (uint256) {
        return _totalUnderlying;
    }
}

/// @notice Dummy Uniswap V3 router mock: never actually used in this basic test,
///         but required by the strategy constructor.
contract DummyRouter is ISwapRouterV3 {
    function exactInputSingle(
        ExactInputSingleParams calldata params
    ) external payable override returns (uint256 amountOut) {
        // For this basic test we don't do any real swap logic.
        // Just return 0 so calls won't revert if somehow reached.
        return 0;
    }
}

// -------------------------
//   Test contract
// -------------------------

contract EulerETHLeverageStrategyTest is Test {
    MockERC20 internal weth;
    MockERC20 internal usdc;
    MockEVault internal eWeth;
    MockEVault internal eUsdc;
    DummyRouter internal router;
    EulerETHLeverageStrategy internal strategy;

    address internal constant ALICE = address(0xA11CE);

    function setUp() public {
        // Create mock WETH (18 decimals) and mock USDC (6 decimals)
        weth = new MockERC20("Mock WETH", "WETH", 18);
        usdc = new MockERC20("Mock USDC", "USDC", 6);

        // Create mock EVaults for WETH and USDC
        eWeth = new MockEVault(IERC20(address(weth)));
        eUsdc = new MockEVault(IERC20(address(usdc)));

        // Dummy Uniswap V3 router
        router = new DummyRouter();

        // Deploy strategy
        //
        // NOTE: we set `vault = address(this)` so that this test contract
        //       is allowed to call `openPosition` and `closePosition`.
        strategy = new EulerETHLeverageStrategy(
            address(weth),
            address(usdc),
            address(eWeth),
            address(eUsdc),
            address(router),
            address(this),    // vault
            1e18              // targetLeverage = 1x for this basic test
        );
    }

    function test_openPosition_depositsWETHIntoEWeth() public {
        uint256 amount = 1 ether;

        // Mint WETH to "vault" (this test contract)
        weth.mint(address(this), amount);

        // Approve strategy to pull WETH (strategy uses transferFrom(msg.sender, ...)
        weth.approve(address(strategy), amount);

        // Call openPosition as "vault"
        strategy.openPosition(amount);

        // Strategy should have moved WETH from vault -> strategy -> eWeth
        // 1) Vault ends up with no WETH
        assertEq(weth.balanceOf(address(this)), 0, "vault should have 0 WETH after openPosition");

        // 2) EVault mock holds the underlying
        assertEq(eWeth.totalUnderlying(), amount, "eWeth should hold all WETH");

        // 3) Strategy has shares in the EVault
        // (in the mock, shares = assets)
        uint256 shares = eWeth.balanceOf(address(strategy));
        assertEq(shares, amount, "strategy should own eWeth shares");

        // 4) Strategy totalAssets() matches the amount
        uint256 nav = strategy.totalAssets();
        assertEq(nav, amount, "NAV should equal deposited amount in this simple version");
    }

    function test_closePosition_withdrawsFromEWethAndReturnsToVault() public {
        uint256 amount = 1 ether;

        // Prepare: open a position first
        weth.mint(address(this), amount);
        weth.approve(address(strategy), amount);
        strategy.openPosition(amount);

        // Check initial state
        assertEq(eWeth.totalUnderlying(), amount, "eWeth should hold WETH before close");
        assertEq(weth.balanceOf(address(this)), 0, "vault should have 0 WETH before close");

        // Now close the position completely
        strategy.closePosition(amount);

        // 1) eWeth should no longer hold any WETH
        assertEq(eWeth.totalUnderlying(), 0, "eWeth should be empty after close");

        // 2) The vault (this contract) should have the WETH back
        assertEq(weth.balanceOf(address(this)), amount, "vault should recover all WETH after close");

        // 3) Strategy NAV should be 0
        uint256 nav = strategy.totalAssets();
        assertEq(nav, 0, "NAV should be 0 after closing entire position");
    }
}
