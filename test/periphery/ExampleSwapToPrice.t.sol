// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";
import "@uniswap/v2-periphery/interfaces/IUniswapV2Router02.sol";

interface ISwapToPrice {
    function router() external view returns (address);

    function swapToPrice(
        address tokenA,
        address tokenB,
        uint256 truePriceTokenA,
        uint256 truePriceTokenB,
        uint256 maxSpendTokenA,
        uint256 maxSpendTokenB,
        address to,
        uint256 deadline
    ) external;
}

interface IERC20STP {
    function approve(address, uint256) external returns (bool);

    function balanceOf(address) external view returns (uint256);

    function transfer(address, uint256) external returns (bool);
}

/// @dev Forge port of v2-periphery/test/ExampleSwapToPrice.spec.ts
contract ExampleSwapToPriceTest is Test {
    IUniswapV2Factory factory;
    IUniswapV2Pair pair;
    ISwapToPrice swapToPrice;
    IUniswapV2Router02 router;

    address token0addr;
    address token1addr;

    function _transfer(address token, address to, uint256 amount) internal {
        (bool ok,) = token.call(abi.encodeWithSignature("transfer(address,uint256)", to, amount));
        require(ok, "transfer failed");
    }

    function setUp() public {
        address tA = deployCode("src/periphery/test/ERC20.sol:ERC20", abi.encode(uint256(10_000e18)));
        address tB = deployCode("src/periphery/test/ERC20.sol:ERC20", abi.encode(uint256(10_000e18)));

        factory = IUniswapV2Factory(deployCode("UniswapV2Factory.sol:UniswapV2Factory", abi.encode(address(this))));
        factory.createPair(tA, tB);
        pair = IUniswapV2Pair(factory.getPair(tA, tB));

        if (pair.token0() == tA) {
            token0addr = tA;
            token1addr = tB;
        } else {
            token0addr = tB;
            token1addr = tA;
        }

        // Deploy WETH (needed by router) and router02
        address weth = deployCode("WETH9.sol:WETH9");
        router = IUniswapV2Router02(
            deployCode("UniswapV2Router02.sol:UniswapV2Router02", abi.encode(address(factory), weth))
        );

        // Deploy ExampleSwapToPrice
        swapToPrice = ISwapToPrice(
            deployCode("ExampleSwapToPrice.sol:ExampleSwapToPrice", abi.encode(address(factory), address(router)))
        );

        // Set up price differential of 1:100 (no LP, just sync reserves)
        _transfer(token0addr, address(pair), 10e18);
        _transfer(token1addr, address(pair), 1000e18);
        pair.sync();

        // Approve swapToPrice to spend both tokens (MaxUint256 equivalent)
        IERC20STP(token0addr).approve(address(swapToPrice), type(uint256).max);
        IERC20STP(token1addr).approve(address(swapToPrice), type(uint256).max);
    }

    // -------------------------------------------------------------------------
    // misc
    // -------------------------------------------------------------------------
    function test_routerAddress() public view {
        assertEq(swapToPrice.router(), address(router));
    }

    // -------------------------------------------------------------------------
    // #swapToPrice — input validation
    // -------------------------------------------------------------------------
    function test_requiresNonZeroTruePrice_bothZero() public {
        vm.expectRevert();
        swapToPrice.swapToPrice(
            token0addr, token1addr, 0, 0, type(uint256).max, type(uint256).max, address(this), type(uint256).max
        );
    }

    function test_requiresNonZeroTruePrice_aZero() public {
        vm.expectRevert();
        swapToPrice.swapToPrice(
            token0addr, token1addr, 0, 10, type(uint256).max, type(uint256).max, address(this), type(uint256).max
        );
    }

    function test_requiresNonZeroTruePrice_bZero() public {
        vm.expectRevert();
        swapToPrice.swapToPrice(
            token0addr, token1addr, 10, 0, type(uint256).max, type(uint256).max, address(this), type(uint256).max
        );
    }

    function test_requiresNonZeroMaxSpend() public {
        vm.expectRevert();
        swapToPrice.swapToPrice(token0addr, token1addr, 1, 100, 0, 0, address(this), type(uint256).max);
    }

    // -------------------------------------------------------------------------
    // #swapToPrice — moves price correctly
    // -------------------------------------------------------------------------
    /// @dev Moves price from 1:100 to 1:90 by selling token0 into the pair.
    ///      Exact amounts verified against the JS test values.
    function test_movePriceTo_1to90() public {
        uint256 token0Before = IERC20STP(token0addr).balanceOf(address(this));
        uint256 token1Before = IERC20STP(token1addr).balanceOf(address(this));

        swapToPrice.swapToPrice(
            token0addr, token1addr, 1, 90, type(uint256).max, type(uint256).max, address(this), type(uint256).max
        );

        // token0 decreases by exactly 526682316179835569
        assertEq(token0Before - IERC20STP(token0addr).balanceOf(address(this)), 526_682_316_179_835_569);
        // token1 increases by exactly 49890467170695440744
        assertEq(IERC20STP(token1addr).balanceOf(address(this)) - token1Before, 49_890_467_170_695_440_744);
    }

    /// @dev Moves price from 1:100 to 1:110 by selling token1 into the pair.
    function test_movePriceTo_1to110() public {
        uint256 token0Before = IERC20STP(token0addr).balanceOf(address(this));
        uint256 token1Before = IERC20STP(token1addr).balanceOf(address(this));

        swapToPrice.swapToPrice(
            token0addr, token1addr, 1, 110, type(uint256).max, type(uint256).max, address(this), type(uint256).max
        );

        // token1 decreases by exactly 47376582963642643588
        assertEq(token1Before - IERC20STP(token1addr).balanceOf(address(this)), 47_376_582_963_642_643_588);
        // token0 increases by exactly 451039908682851138
        assertEq(IERC20STP(token0addr).balanceOf(address(this)) - token0Before, 451_039_908_682_851_138);
    }

    /// @dev Reverse token argument order has the same effect as 1:110 above.
    function test_movePriceTo_reverseOrder() public {
        uint256 token0Before = IERC20STP(token0addr).balanceOf(address(this));
        uint256 token1Before = IERC20STP(token1addr).balanceOf(address(this));

        // token1 / token0 = 110/1 is equivalent to token0 / token1 = 1/110
        swapToPrice.swapToPrice(
            token1addr, token0addr, 110, 1, type(uint256).max, type(uint256).max, address(this), type(uint256).max
        );

        assertEq(token1Before - IERC20STP(token1addr).balanceOf(address(this)), 47_376_582_963_642_643_588);
        assertEq(IERC20STP(token0addr).balanceOf(address(this)) - token0Before, 451_039_908_682_851_138);
    }
}
