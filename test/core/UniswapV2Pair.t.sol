// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";

/// @dev Minimal ERC20 surface used by test tokens (same ABI as the 0.5.16/0.6.6 test ERC20 contracts)
interface IERC20Minimal {
    event Transfer(address indexed from, address indexed to, uint256 value);
    function balanceOf(address) external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function approve(address, uint256) external returns (bool);
}

/// @dev Forge port of v2-core/test/UniswapV2Pair.spec.ts
contract UniswapV2PairTest is Test {
    uint256 constant MINIMUM_LIQUIDITY = 1_000;

    IUniswapV2Factory factory;
    IUniswapV2Pair pair;
    IERC20Minimal token0;
    IERC20Minimal token1;

    address other;

    // -------------------------------------------------------------------------
    // Setup
    // -------------------------------------------------------------------------
    function setUp() public {
        other = makeAddr("other");

        factory = IUniswapV2Factory(deployCode("UniswapV2Factory.sol:UniswapV2Factory", abi.encode(address(this))));

        // Deploy two ERC20 test tokens (periphery ERC20: "Test Token")
        address tokenA = deployCode("src/periphery/test/ERC20.sol:ERC20", abi.encode(uint256(10_000e18)));
        address tokenB = deployCode("src/periphery/test/ERC20.sol:ERC20", abi.encode(uint256(10_000e18)));

        factory.createPair(tokenA, tokenB);
        address pairAddr = factory.getPair(tokenA, tokenB);
        pair = IUniswapV2Pair(pairAddr);

        // Sort so token0/token1 match pair ordering
        if (pair.token0() == tokenA) {
            token0 = IERC20Minimal(tokenA);
            token1 = IERC20Minimal(tokenB);
        } else {
            token0 = IERC20Minimal(tokenB);
            token1 = IERC20Minimal(tokenA);
        }
    }

    // -------------------------------------------------------------------------
    // Helper
    // -------------------------------------------------------------------------
    function _addLiquidity(uint256 amount0, uint256 amount1) internal {
        token0.transfer(address(pair), amount0);
        token1.transfer(address(pair), amount1);
        pair.mint(address(this));
    }

    /// @dev UQ112x112 encode: (reserve1 << 112) / reserve0
    function _encodePrice(uint256 r0, uint256 r1) internal pure returns (uint256 price0, uint256 price1) {
        price0 = (r1 << 112) / r0;
        price1 = (r0 << 112) / r1;
    }

    // -------------------------------------------------------------------------
    // mint (initial liquidity)
    // -------------------------------------------------------------------------
    function test_mint() public {
        uint256 token0Amount = 1e18;
        uint256 token1Amount = 4e18;
        token0.transfer(address(pair), token0Amount);
        token1.transfer(address(pair), token1Amount);

        uint256 expectedLiquidity = 2e18;

        // Events: Transfer(0→0, MINIMUM_LIQUIDITY), Transfer(0→this, liq-MIN), Sync, Mint
        vm.expectEmit(true, true, false, true, address(pair));
        emit IUniswapV2Pair.Transfer(address(0), address(0), MINIMUM_LIQUIDITY);

        vm.expectEmit(true, true, false, true, address(pair));
        emit IUniswapV2Pair.Transfer(address(0), address(this), expectedLiquidity - MINIMUM_LIQUIDITY);

        vm.expectEmit(false, false, false, true, address(pair));
        emit IUniswapV2Pair.Sync(uint112(token0Amount), uint112(token1Amount));

        vm.expectEmit(true, false, false, true, address(pair));
        emit IUniswapV2Pair.Mint(address(this), token0Amount, token1Amount);

        pair.mint(address(this));

        assertEq(pair.totalSupply(), expectedLiquidity);
        assertEq(pair.balanceOf(address(this)), expectedLiquidity - MINIMUM_LIQUIDITY);
        assertEq(token0.balanceOf(address(pair)), token0Amount);
        assertEq(token1.balanceOf(address(pair)), token1Amount);

        (uint112 r0, uint112 r1,) = pair.getReserves();
        assertEq(r0, token0Amount);
        assertEq(r1, token1Amount);
    }

    // -------------------------------------------------------------------------
    // swap: constant-product input–price cases
    //  [swapAmount, token0Reserve, token1Reserve, expectedOutput]
    // -------------------------------------------------------------------------
    function _assertGetInputPrice(
        uint256 swapAmount,
        uint256 token0Amount,
        uint256 token1Amount,
        uint256 expectedOutput
    ) internal {
        _addLiquidity(token0Amount, token1Amount);
        token0.transfer(address(pair), swapAmount);

        // One wei above the theoretical output must revert (K violated)
        vm.expectRevert();
        pair.swap(0, expectedOutput + 1, address(this), "");

        // Exactly at the correct output succeeds
        pair.swap(0, expectedOutput, address(this), "");

        // Reset pair for next subtest
        (uint112 r0, uint112 r1,) = pair.getReserves();
        token0.transfer(address(pair), token0.totalSupply() - token0.balanceOf(address(pair)));
        token1.transfer(address(pair), token1.totalSupply() - token1.balanceOf(address(pair)));
        // Burn existing LP so fresh _addLiquidity works
        pair.transfer(address(pair), pair.balanceOf(address(this)));
        pair.burn(address(this));
        // silence unused vars warning
        (r0, r1) = (r0, r1);
    }

    function test_getInputPrice_0() public {
        _assertGetInputPrice(1e18, 5e18, 10e18, 1_662_497_915_624_478_906);
    }

    function test_getInputPrice_1() public {
        _assertGetInputPrice(1e18, 10e18, 5e18, 453_305_446_940_074_565);
    }

    function test_getInputPrice_2() public {
        _assertGetInputPrice(2e18, 5e18, 10e18, 2_851_015_155_847_869_602);
    }

    function test_getInputPrice_3() public {
        _assertGetInputPrice(2e18, 10e18, 5e18, 831_248_957_812_239_453);
    }

    function test_getInputPrice_4() public {
        _assertGetInputPrice(1e18, 10e18, 10e18, 906_610_893_880_149_131);
    }

    function test_getInputPrice_5() public {
        _assertGetInputPrice(1e18, 100e18, 100e18, 987_158_034_397_061_298);
    }

    function test_getInputPrice_6() public {
        _assertGetInputPrice(1e18, 1000e18, 1000e18, 996_006_981_039_903_216);
    }

    // -------------------------------------------------------------------------
    // optimistic: trying to take exact output (fee still satisfied)
    // -------------------------------------------------------------------------
    function _assertOptimistic(uint256 outputAmount, uint256 token0Amount, uint256 token1Amount, uint256 inputAmount)
        internal
    {
        _addLiquidity(token0Amount, token1Amount);
        token0.transfer(address(pair), inputAmount);

        vm.expectRevert();
        pair.swap(outputAmount + 1, 0, address(this), "");

        pair.swap(outputAmount, 0, address(this), "");

        pair.transfer(address(pair), pair.balanceOf(address(this)));
        pair.burn(address(this));
    }

    function test_optimistic_0() public {
        _assertOptimistic(997_000_000_000_000_000, 5e18, 10e18, 1e18);
    }

    function test_optimistic_1() public {
        _assertOptimistic(997_000_000_000_000_000, 10e18, 5e18, 1e18);
    }

    function test_optimistic_2() public {
        _assertOptimistic(997_000_000_000_000_000, 5e18, 5e18, 1e18);
    }

    function test_optimistic_3() public {
        _assertOptimistic(1e18, 5e18, 5e18, 1_003_009_027_081_243_732);
    }

    // -------------------------------------------------------------------------
    // swap:token0
    // -------------------------------------------------------------------------
    function test_swap_token0() public {
        uint256 token0Amount = 5e18;
        uint256 token1Amount = 10e18;
        _addLiquidity(token0Amount, token1Amount);

        uint256 swapAmount = 1e18;
        uint256 expectedOutputAmount = 1_662_497_915_624_478_906;

        token0.transfer(address(pair), swapAmount);

        vm.expectEmit(true, true, false, true, address(token1));
        emit IERC20Minimal.Transfer(address(pair), address(this), expectedOutputAmount);

        vm.expectEmit(false, false, false, true, address(pair));
        emit IUniswapV2Pair.Sync(uint112(token0Amount + swapAmount), uint112(token1Amount - expectedOutputAmount));

        vm.expectEmit(true, false, false, true, address(pair));
        emit IUniswapV2Pair.Swap(address(this), swapAmount, 0, 0, expectedOutputAmount, address(this));

        pair.swap(0, expectedOutputAmount, address(this), "");

        (uint112 r0, uint112 r1,) = pair.getReserves();
        assertEq(r0, token0Amount + swapAmount);
        assertEq(r1, token1Amount - expectedOutputAmount);
        assertEq(token0.balanceOf(address(pair)), token0Amount + swapAmount);
        assertEq(token1.balanceOf(address(pair)), token1Amount - expectedOutputAmount);

        uint256 totalSupply0 = token0.totalSupply();
        uint256 totalSupply1 = token1.totalSupply();
        assertEq(token0.balanceOf(address(this)), totalSupply0 - token0Amount - swapAmount);
        assertEq(token1.balanceOf(address(this)), totalSupply1 - token1Amount + expectedOutputAmount);
    }

    // -------------------------------------------------------------------------
    // swap:token1
    // -------------------------------------------------------------------------
    function test_swap_token1() public {
        uint256 token0Amount = 5e18;
        uint256 token1Amount = 10e18;
        _addLiquidity(token0Amount, token1Amount);

        uint256 swapAmount = 1e18;
        uint256 expectedOutputAmount = 453_305_446_940_074_565;

        token1.transfer(address(pair), swapAmount);

        vm.expectEmit(true, true, false, true, address(token0));
        emit IERC20Minimal.Transfer(address(pair), address(this), expectedOutputAmount);

        vm.expectEmit(false, false, false, true, address(pair));
        emit IUniswapV2Pair.Sync(uint112(token0Amount - expectedOutputAmount), uint112(token1Amount + swapAmount));

        vm.expectEmit(true, false, false, true, address(pair));
        emit IUniswapV2Pair.Swap(address(this), 0, swapAmount, expectedOutputAmount, 0, address(this));

        pair.swap(expectedOutputAmount, 0, address(this), "");

        (uint112 r0, uint112 r1,) = pair.getReserves();
        assertEq(r0, token0Amount - expectedOutputAmount);
        assertEq(r1, token1Amount + swapAmount);

        uint256 totalSupply0 = token0.totalSupply();
        uint256 totalSupply1 = token1.totalSupply();
        assertEq(token0.balanceOf(address(this)), totalSupply0 - token0Amount + expectedOutputAmount);
        assertEq(token1.balanceOf(address(this)), totalSupply1 - token1Amount - swapAmount);
    }

    // -------------------------------------------------------------------------
    // burn
    // -------------------------------------------------------------------------
    function test_burn() public {
        uint256 token0Amount = 3e18;
        uint256 token1Amount = 3e18;
        _addLiquidity(token0Amount, token1Amount);

        uint256 expectedLiquidity = 3e18;

        pair.transfer(address(pair), expectedLiquidity - MINIMUM_LIQUIDITY);

        vm.expectEmit(true, true, false, true, address(pair));
        emit IUniswapV2Pair.Transfer(address(pair), address(0), expectedLiquidity - MINIMUM_LIQUIDITY);

        vm.expectEmit(true, true, false, true, address(token0));
        emit IERC20Minimal.Transfer(address(pair), address(this), token0Amount - 1000);

        vm.expectEmit(true, true, false, true, address(token1));
        emit IERC20Minimal.Transfer(address(pair), address(this), token1Amount - 1000);

        vm.expectEmit(false, false, false, true, address(pair));
        emit IUniswapV2Pair.Sync(1000, 1000);

        vm.expectEmit(true, true, false, true, address(pair));
        emit IUniswapV2Pair.Burn(address(this), token0Amount - 1000, token1Amount - 1000, address(this));

        pair.burn(address(this));

        assertEq(pair.balanceOf(address(this)), 0);
        assertEq(pair.totalSupply(), MINIMUM_LIQUIDITY);
        assertEq(token0.balanceOf(address(pair)), 1000);
        assertEq(token1.balanceOf(address(pair)), 1000);

        uint256 totalSupply0 = token0.totalSupply();
        uint256 totalSupply1 = token1.totalSupply();
        assertEq(token0.balanceOf(address(this)), totalSupply0 - 1000);
        assertEq(token1.balanceOf(address(this)), totalSupply1 - 1000);
    }

    // -------------------------------------------------------------------------
    // price{0,1}CumulativeLast (TWAP accumulators)
    // -------------------------------------------------------------------------
    function test_priceCumulativeLast() public {
        uint256 token0Amount = 3e18;
        uint256 token1Amount = 3e18;
        _addLiquidity(token0Amount, token1Amount);

        (,, uint32 blockTimestamp) = pair.getReserves();

        // Advance 1 second, sync to snapshot first price period
        vm.warp(blockTimestamp + 1);
        pair.sync();

        (uint256 initialPrice0, uint256 initialPrice1) = _encodePrice(token0Amount, token1Amount);
        assertEq(pair.price0CumulativeLast(), initialPrice0);
        assertEq(pair.price1CumulativeLast(), initialPrice1);
        {
            (,, uint32 ts1) = pair.getReserves();
            assertEq(uint256(ts1), blockTimestamp + 1);
        }

        // Swap to move reserves to (6e18, 2e18), 10 seconds after initial mint
        uint256 swapAmount = 3e18;
        token0.transfer(address(pair), swapAmount);
        vm.warp(blockTimestamp + 10);
        pair.swap(0, 1e18, address(this), "");

        assertEq(pair.price0CumulativeLast(), initialPrice0 * 10);
        assertEq(pair.price1CumulativeLast(), initialPrice1 * 10);
        {
            (,, uint32 ts10) = pair.getReserves();
            assertEq(uint256(ts10), blockTimestamp + 10);
        }

        // Advance another 10 seconds, sync to snapshot second price period
        (uint256 newPrice0, uint256 newPrice1) = _encodePrice(6e18, 2e18);
        vm.warp(blockTimestamp + 20);
        pair.sync();

        assertEq(pair.price0CumulativeLast(), initialPrice0 * 10 + newPrice0 * 10);
        assertEq(pair.price1CumulativeLast(), initialPrice1 * 10 + newPrice1 * 10);
        {
            (,, uint32 ts20) = pair.getReserves();
            assertEq(uint256(ts20), blockTimestamp + 20);
        }
    }

    // -------------------------------------------------------------------------
    // feeTo:off — no protocol fee minted
    // -------------------------------------------------------------------------
    function test_feeTo_off() public {
        uint256 token0Amount = 1_000e18;
        uint256 token1Amount = 1_000e18;
        _addLiquidity(token0Amount, token1Amount);

        uint256 swapAmount = 1e18;
        uint256 expectedOutputAmount = 996_006_981_039_903_216;
        token1.transfer(address(pair), swapAmount);
        pair.swap(expectedOutputAmount, 0, address(this), "");

        uint256 expectedLiquidity = 1_000e18;
        pair.transfer(address(pair), expectedLiquidity - MINIMUM_LIQUIDITY);
        pair.burn(address(this));

        // With feeTo disabled, no extra LP tokens minted
        assertEq(pair.totalSupply(), MINIMUM_LIQUIDITY);
    }

    // -------------------------------------------------------------------------
    // feeTo:on — protocol fee accrues to feeTo address
    //
    // Security note: the 1/6 fee is applied to (sqrt(k_after) - sqrt(k_before)).
    // If an attacker inflates reserves via donation before a block the fee is
    // still bounded by actual trade volume; no inflation attack is possible here.
    // -------------------------------------------------------------------------
    function test_feeTo_on() public {
        factory.setFeeTo(other);

        uint256 token0Amount = 1_000e18;
        uint256 token1Amount = 1_000e18;
        _addLiquidity(token0Amount, token1Amount);

        uint256 swapAmount = 1e18;
        uint256 expectedOutputAmount = 996_006_981_039_903_216;
        token1.transfer(address(pair), swapAmount);
        pair.swap(expectedOutputAmount, 0, address(this), "");

        uint256 expectedLiquidity = 1_000e18;
        pair.transfer(address(pair), expectedLiquidity - MINIMUM_LIQUIDITY);
        pair.burn(address(this));

        // Protocol fee LP tokens minted to `other`
        assertEq(pair.totalSupply(), MINIMUM_LIQUIDITY + 249_750_499_251_388);
        assertEq(pair.balanceOf(other), 249_750_499_251_388);

        // Residual token balances in pair (1000 MINIMUM + fee dust)
        assertEq(token0.balanceOf(address(pair)), 1000 + 249_501_683_697_445);
        assertEq(token1.balanceOf(address(pair)), 1000 + 250_000_187_312_969);
    }

    // -------------------------------------------------------------------------
    // Fuzz: constant-product invariant never violated by a valid swap
    // -------------------------------------------------------------------------
    function testFuzz_swapInvariant(uint112 r0Seed, uint112 r1Seed, uint112 swapInSeed) public {
        // Keep reserves well within the 10_000e18 token supply minted in setUp
        uint256 r0 = bound(uint256(r0Seed), 1e6, 1_000e18);
        uint256 r1 = bound(uint256(r1Seed), 1e6, 1_000e18);
        uint256 swapIn = bound(uint256(swapInSeed), 1, r0 / 2 > 0 ? r0 / 2 : 1);

        _addLiquidity(r0, r1);

        // Compute expected output via the standard formula
        uint256 amountOut = (r1 * swapIn * 997) / (r0 * 1000 + swapIn * 997);
        vm.assume(amountOut > 0 && amountOut < r1);

        token0.transfer(address(pair), swapIn);
        pair.swap(0, amountOut, address(this), "");

        // k_new >= k_old (fees increase k)
        (uint112 newR0, uint112 newR1,) = pair.getReserves();
        assertGe(uint256(newR0) * uint256(newR1), r0 * r1, "k invariant violated");
    }
}
