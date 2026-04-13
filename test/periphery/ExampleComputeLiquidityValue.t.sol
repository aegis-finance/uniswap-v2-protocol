// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";
import "@uniswap/v2-periphery/interfaces/IUniswapV2Router02.sol";

interface IComputeLiquidityValue {
    function factory() external view returns (address);
    function getLiquidityValue(address tokenA, address tokenB, uint256 liquidityAmount)
        external
        view
        returns (uint256 tokenAAmount, uint256 tokenBAmount);
    function getReservesAfterArbitrage(address tokenA, address tokenB, uint256 truePriceTokenA, uint256 truePriceTokenB)
        external
        view
        returns (uint256 reserveA, uint256 reserveB);
    function getLiquidityValueAfterArbitrageToPrice(
        address tokenA,
        address tokenB,
        uint256 truePriceTokenA,
        uint256 truePriceTokenB,
        uint256 liquidityAmount
    ) external view returns (uint256 tokenAAmount, uint256 tokenBAmount);
    function getGasCostOfGetLiquidityValueAfterArbitrageToPrice(
        address tokenA,
        address tokenB,
        uint256 truePriceTokenA,
        uint256 truePriceTokenB,
        uint256 liquidityAmount
    ) external view returns (uint256 gasCost);
}

interface IERC20CLV {
    function approve(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
}

/// @dev Forge port of v2-periphery/test/ExampleComputeLiquidityValue.spec.ts
contract ExampleComputeLiquidityValueTest is Test {
    IUniswapV2Factory factory;
    IUniswapV2Pair pair;
    IComputeLiquidityValue computeLiquidity;
    IUniswapV2Router02 router;

    address token0addr;
    address token1addr;

    function _transfer(address token, address to, uint256 amount) internal {
        (bool ok,) = token.call(abi.encodeWithSignature("transfer(address,uint256)", to, amount));
        require(ok, "transfer failed");
    }

    function _addLiquidity(uint256 amt0, uint256 amt1, address to) internal {
        if (amt0 > 0) _transfer(token0addr, address(pair), amt0);
        if (amt1 > 0) _transfer(token1addr, address(pair), amt1);
        pair.mint(to);
    }

    function setUp() public {
        address tA = deployCode("src/periphery/test/ERC20.sol:ERC20", abi.encode(uint256(100_000e18)));
        address tB = deployCode("src/periphery/test/ERC20.sol:ERC20", abi.encode(uint256(100_000e18)));

        factory = IUniswapV2Factory(deployCode("UniswapV2Factory.sol:UniswapV2Factory", abi.encode(address(this))));
        factory.createPair(tA, tB);
        pair = IUniswapV2Pair(factory.getPair(tA, tB));

        if (pair.token0() == tA) token0addr = tA;
        token1addr = tB;
        else token0addr = tB;
        token1addr = tA;

        address weth = deployCode("WETH9.sol:WETH9");

        router = IUniswapV2Router02(
            deployCode("UniswapV2Router02.sol:UniswapV2Router02", abi.encode(address(factory), weth))
        );

        // Seed: 10 token0 + 1000 token1 → 100e18 LP
        _addLiquidity(10e18, 1000e18, address(this));
        assertEq(pair.totalSupply(), 100e18);

        computeLiquidity = IComputeLiquidityValue(
            deployCode("ExampleComputeLiquidityValue.sol:ExampleComputeLiquidityValue", abi.encode(address(factory)))
        );
    }

    // -------------------------------------------------------------------------
    // factory address
    // -------------------------------------------------------------------------
    function test_factory() public view {
        assertEq(computeLiquidity.factory(), address(factory));
    }

    // -------------------------------------------------------------------------
    // #getLiquidityValue — fee off
    // -------------------------------------------------------------------------
    function test_getLiquidityValue_5shares() public view {
        (uint256 v0, uint256 v1) = computeLiquidity.getLiquidityValue(token0addr, token1addr, 5e18);
        assertEq(v0, 500_000_000_000_000_000);
        assertEq(v1, 50_000_000_000_000_000_000);
    }

    function test_getLiquidityValue_7shares() public view {
        (uint256 v0, uint256 v1) = computeLiquidity.getLiquidityValue(token0addr, token1addr, 7e18);
        assertEq(v0, 700_000_000_000_000_000);
        assertEq(v1, 70_000_000_000_000_000_000);
    }

    function test_getLiquidityValue_afterSwap() public {
        IERC20CLV(token0addr).approve(address(router), type(uint256).max);
        address[] memory path = new address[](2);
        path[0] = token0addr;
        path[1] = token1addr;
        router.swapExactTokensForTokens(10e18, 0, path, address(this), type(uint256).max);

        (uint256 v0, uint256 v1) = computeLiquidity.getLiquidityValue(token0addr, token1addr, 7e18);
        assertEq(v0, 1_400_000_000_000_000_000);
        assertEq(v1, 35_052_578_868_302_453_680);
    }

    function test_getLiquidityValue_feeOn_afterSwap() public {
        factory.setFeeTo(address(this));
        _addLiquidity(10e18, 1000e18, address(0));
        assertEq(pair.totalSupply(), 200e18);

        IERC20CLV(token0addr).approve(address(router), type(uint256).max);
        address[] memory path = new address[](2);
        path[0] = token0addr;
        path[1] = token1addr;
        router.swapExactTokensForTokens(20e18, 0, path, address(this), type(uint256).max);

        (uint256 v0, uint256 v1) = computeLiquidity.getLiquidityValue(token0addr, token1addr, 7e18);
        assertEq(v0, 1_399_824_934_325_735_058);
        assertEq(v1, 35_048_195_651_620_807_684);
    }

    // -------------------------------------------------------------------------
    // #getReservesAfterArbitrage
    // -------------------------------------------------------------------------
    function test_getReservesAfterArbitrage_1to400() public view {
        (uint256 r0, uint256 r1) = computeLiquidity.getReservesAfterArbitrage(token0addr, token1addr, 1, 400);
        assertEq(r0, 5_007_516_917_298_542_016);
        assertEq(r1, 1_999_997_739_838_173_075_192);
    }

    function test_getReservesAfterArbitrage_1to200() public view {
        (uint256 r0, uint256 r1) = computeLiquidity.getReservesAfterArbitrage(token0addr, token1addr, 1, 200);
        assertEq(r0, 7_081_698_338_256_310_291);
        assertEq(r1, 1_413_330_640_570_018_326_894);
    }

    function test_getReservesAfterArbitrage_1to100() public view {
        (uint256 r0, uint256 r1) = computeLiquidity.getReservesAfterArbitrage(token0addr, token1addr, 1, 100);
        assertEq(r0, 10_000_000_000_000_000_000);
        assertEq(r1, 1_000_000_000_000_000_000_000);
    }

    function test_getReservesAfterArbitrage_1to50() public view {
        (uint256 r0, uint256 r1) = computeLiquidity.getReservesAfterArbitrage(token0addr, token1addr, 1, 50);
        assertEq(r0, 14_133_306_405_700_183_269);
        assertEq(r1, 708_169_833_825_631_029_041);
    }

    function test_getReservesAfterArbitrage_1to25() public view {
        (uint256 r0, uint256 r1) = computeLiquidity.getReservesAfterArbitrage(token0addr, token1addr, 1, 25);
        assertEq(r0, 19_999_977_398_381_730_752);
        assertEq(r1, 500_751_691_729_854_201_595);
    }

    function test_getReservesAfterArbitrage_25to1() public view {
        (uint256 r0, uint256 r1) = computeLiquidity.getReservesAfterArbitrage(token0addr, token1addr, 25, 1);
        assertEq(r0, 500_721_601_459_041_764_285);
        assertEq(r1, 20_030_067_669_194_168_064);
    }

    function test_getReservesAfterArbitrage_largeNumbers() public view {
        (uint256 r0, uint256 r1) = computeLiquidity.getReservesAfterArbitrage(
            token0addr, token1addr, type(uint256).max / 1000, type(uint256).max / 1000
        );
        assertEq(r0, 100_120_248_075_158_403_008);
        assertEq(r1, 100_150_338_345_970_840_319);
    }

    // -------------------------------------------------------------------------
    // #getLiquidityValueAfterArbitrageToPrice — fee off
    // -------------------------------------------------------------------------
    function test_getLiquidityValueAfterArbitrage_feeOff_1to105() public view {
        (uint256 v0, uint256 v1) =
            computeLiquidity.getLiquidityValueAfterArbitrageToPrice(token0addr, token1addr, 1, 105, 5e18);
        assertEq(v0, 488_683_612_488_266_114);
        assertEq(v1, 51_161_327_957_205_755_422);
    }

    function test_getLiquidityValueAfterArbitrage_feeOff_1to95() public view {
        (uint256 v0, uint256 v1) =
            computeLiquidity.getLiquidityValueAfterArbitrageToPrice(token0addr, token1addr, 1, 95, 5e18);
        assertEq(v0, 512_255_881_944_227_034);
        assertEq(v1, 48_807_237_571_060_645_526);
    }

    function test_getLiquidityValueAfterArbitrage_feeOff_1to100() public view {
        (uint256 v0, uint256 v1) =
            computeLiquidity.getLiquidityValueAfterArbitrageToPrice(token0addr, token1addr, 1, 100, 5e18);
        assertEq(v0, 500_000_000_000_000_000);
        assertEq(v1, 50_000_000_000_000_000_000);
    }

    function test_getLiquidityValueAfterArbitrage_feeOff_afterSwap_1to25() public {
        IERC20CLV(token0addr).approve(address(router), type(uint256).max);
        address[] memory path = new address[](2);
        path[0] = token0addr;
        path[1] = token1addr;
        router.swapExactTokensForTokens(10e18, 0, path, address(this), type(uint256).max);

        (uint112 r0, uint112 r1,) = pair.getReserves();
        assertEq(r0, 20_000_000_000_000_000_000);
        assertEq(r1, 500_751_126_690_035_052_579);

        (uint256 v0, uint256 v1) =
            computeLiquidity.getLiquidityValueAfterArbitrageToPrice(token0addr, token1addr, 1, 25, 5e18);
        assertEq(v0, 1_000_000_000_000_000_000);
        assertEq(v1, 25_037_556_334_501_752_628);
    }

    function test_getLiquidityValueAfterArbitrage_feeOff_afterSwap_arbBackTo1to100() public {
        IERC20CLV(token0addr).approve(address(router), type(uint256).max);
        address[] memory path = new address[](2);
        path[0] = token0addr;
        path[1] = token1addr;
        router.swapExactTokensForTokens(10e18, 0, path, address(this), type(uint256).max);

        (uint256 v0, uint256 v1) =
            computeLiquidity.getLiquidityValueAfterArbitrageToPrice(token0addr, token1addr, 1, 100, 5e18);
        assertEq(v0, 501_127_678_536_722_155);
        assertEq(v1, 50_037_429_168_613_534_246);
    }

    // -------------------------------------------------------------------------
    // #getLiquidityValueAfterArbitrageToPrice — fee on
    // -------------------------------------------------------------------------
    function test_getLiquidityValueAfterArbitrage_feeOn_1to105() public {
        factory.setFeeTo(address(this));
        _addLiquidity(10e18, 1000e18, address(0));
        assertEq(pair.totalSupply(), 200e18);

        (uint256 v0, uint256 v1) =
            computeLiquidity.getLiquidityValueAfterArbitrageToPrice(token0addr, token1addr, 1, 105, 5e18);
        assertEq(v0, 488_680_839_243_189_328);
        assertEq(v1, 51_161_037_620_273_529_068);
    }

    function test_getLiquidityValueAfterArbitrage_feeOn_1to95() public {
        factory.setFeeTo(address(this));
        _addLiquidity(10e18, 1000e18, address(0));

        (uint256 v0, uint256 v1) =
            computeLiquidity.getLiquidityValueAfterArbitrageToPrice(token0addr, token1addr, 1, 95, 5e18);
        assertEq(v0, 512_252_817_918_759_166);
        assertEq(v1, 48_806_945_633_721_895_174);
    }

    function test_getLiquidityValueAfterArbitrage_feeOn_1to100() public {
        factory.setFeeTo(address(this));
        _addLiquidity(10e18, 1000e18, address(0));

        (uint256 v0, uint256 v1) =
            computeLiquidity.getLiquidityValueAfterArbitrageToPrice(token0addr, token1addr, 1, 100, 5e18);
        assertEq(v0, 500_000_000_000_000_000);
        assertEq(v1, 50_000_000_000_000_000_000);
    }

    function test_getLiquidityValueAfterArbitrage_feeOn_afterSwap_1to25() public {
        factory.setFeeTo(address(this));
        _addLiquidity(10e18, 1000e18, address(0));

        IERC20CLV(token0addr).approve(address(router), type(uint256).max);
        address[] memory path = new address[](2);
        path[0] = token0addr;
        path[1] = token1addr;
        router.swapExactTokensForTokens(20e18, 0, path, address(this), type(uint256).max);

        (uint112 r0, uint112 r1,) = pair.getReserves();
        assertEq(r0, 40_000_000_000_000_000_000);
        assertEq(r1, 1_001_502_253_380_070_105_158);

        (uint256 v0, uint256 v1) =
            computeLiquidity.getLiquidityValueAfterArbitrageToPrice(token0addr, token1addr, 1, 25, 5e18);
        assertEq(v0, 999_874_953_089_810_756);
        assertEq(v1, 25_034_425_465_443_434_060);
    }

    function test_getLiquidityValueAfterArbitrage_feeOn_afterSwap_arbBackTo1to100() public {
        factory.setFeeTo(address(this));
        _addLiquidity(10e18, 1000e18, address(0));

        IERC20CLV(token0addr).approve(address(router), type(uint256).max);
        address[] memory path = new address[](2);
        path[0] = token0addr;
        path[1] = token1addr;
        router.swapExactTokensForTokens(20e18, 0, path, address(this), type(uint256).max);

        (uint256 v0, uint256 v1) =
            computeLiquidity.getLiquidityValueAfterArbitrageToPrice(token0addr, token1addr, 1, 100, 5e18);
        assertEq(v0, 501_002_443_792_372_662);
        assertEq(v1, 50_024_924_521_757_597_314);
    }

    // -------------------------------------------------------------------------
    // gas cost sanity checks
    // -------------------------------------------------------------------------
    function test_gasCost_positive_feeOff() public view {
        assertGt(
            computeLiquidity.getGasCostOfGetLiquidityValueAfterArbitrageToPrice(token0addr, token1addr, 1, 100, 5e18), 0
        );
    }

    function test_gasCost_positive_feeOn() public {
        factory.setFeeTo(address(this));
        _addLiquidity(10e18, 1000e18, address(0));
        assertGt(
            computeLiquidity.getGasCostOfGetLiquidityValueAfterArbitrageToPrice(token0addr, token1addr, 1, 100, 5e18), 0
        );
    }
}
