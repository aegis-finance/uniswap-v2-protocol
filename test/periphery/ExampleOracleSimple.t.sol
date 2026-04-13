// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";

interface IExampleOracleSimple {
    function update() external;

    function consult(
        address token,
        uint amountIn
    ) external view returns (uint amountOut);

    function price0Average() external view returns (uint224);

    function price1Average() external view returns (uint224);
}

/// @dev Forge port of v2-periphery/test/ExampleOracleSimple.spec.ts
contract ExampleOracleSimpleTest is Test {
    IUniswapV2Factory factory;
    IUniswapV2Pair pair;
    IExampleOracleSimple oracle;

    address token0addr;
    address token1addr;

    uint256 constant TOKEN0_AMOUNT = 5e18;
    uint256 constant TOKEN1_AMOUNT = 10e18;

    // FixedPoint UQ112x112 encode: (y << 112) / x
    function _encodePrice(
        uint256 r0,
        uint256 r1
    ) internal pure returns (uint256 price0, uint256 price1) {
        price0 = (r1 << 112) / r0;
        price1 = (r0 << 112) / r1;
    }

    function setUp() public {
        // Deploy two ERC20s
        address tA = deployCode(
            "src/periphery/test/ERC20.sol:ERC20",
            abi.encode(uint256(10_000e18))
        );
        address tB = deployCode(
            "src/periphery/test/ERC20.sol:ERC20",
            abi.encode(uint256(10_000e18))
        );

        factory = IUniswapV2Factory(
            deployCode(
                "UniswapV2Factory.sol:UniswapV2Factory",
                abi.encode(address(this))
            )
        );
        factory.createPair(tA, tB);
        pair = IUniswapV2Pair(factory.getPair(tA, tB));

        // Sort
        if (pair.token0() == tA) {
            token0addr = tA;
            token1addr = tB;
        } else {
            token0addr = tB;
            token1addr = tA;
        }

        // Add liquidity
        _transfer(token0addr, address(pair), TOKEN0_AMOUNT);
        _transfer(token1addr, address(pair), TOKEN1_AMOUNT);
        pair.mint(address(this));

        // Deploy oracle
        oracle = IExampleOracleSimple(
            deployCode(
                "ExampleOracleSimple.sol:ExampleOracleSimple",
                abi.encode(address(factory), token0addr, token1addr)
            )
        );
    }

    function _transfer(address token, address to, uint256 amount) internal {
        (bool ok, ) = token.call(
            abi.encodeWithSignature("transfer(address,uint256)", to, amount)
        );
        require(ok);
    }

    // -------------------------------------------------------------------------
    // update: requires 24-hour period, then snapshots TWAP prices
    // -------------------------------------------------------------------------
    function test_update() public {
        (, , uint32 blockTs) = pair.getReserves();

        // < 24 h → revert
        vm.warp(blockTs + 23 hours);
        vm.expectRevert();
        oracle.update();

        // exactly 24 h → succeeds
        vm.warp(blockTs + 24 hours);
        oracle.update();

        (uint256 expectedPrice0, uint256 expectedPrice1) = _encodePrice(
            TOKEN0_AMOUNT,
            TOKEN1_AMOUNT
        );

        // UQ112x112 values are stored as uint224 in the first word of the struct
        assertEq(oracle.price0Average(), uint224(expectedPrice0));
        assertEq(oracle.price1Average(), uint224(expectedPrice1));

        // consult: 5e18 token0 in → 10e18 token1 out (1:2 ratio)
        assertEq(oracle.consult(token0addr, TOKEN0_AMOUNT), TOKEN1_AMOUNT);
        // consult: 10e18 token1 in → 5e18 token0 out
        assertEq(oracle.consult(token1addr, TOKEN1_AMOUNT), TOKEN0_AMOUNT);
    }
}
