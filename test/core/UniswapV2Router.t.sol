// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";
import "@uniswap/v2-periphery/interfaces/IUniswapV2Router02.sol";

/// @dev Minimal ERC20 surface used by test tokens
interface IERC20Minimal {
    event Transfer(address indexed from, address indexed to, uint256 value);
    function balanceOf(address) external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function approve(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function allowance(address, address) external view returns (uint256);
    // EIP-2612
    function DOMAIN_SEPARATOR() external view returns (bytes32);
    function PERMIT_TYPEHASH() external pure returns (bytes32);
    function nonces(address) external view returns (uint256);
    function permit(address,address,uint256,uint256,uint8,bytes32,bytes32) external;
}

interface IWETH {
    function deposit() external payable;
    function withdraw(uint256) external;
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function approve(address, uint256) external returns (bool);
}

/// @dev Forge port of v2-periphery/test/UniswapV2Router01.spec.ts
///      and  v2-periphery/test/UniswapV2Router02.spec.ts
contract UniswapV2RouterTest is Test {
    uint256 constant MINIMUM_LIQUIDITY = 1_000;

    IUniswapV2Factory  factory;
    IUniswapV2Router02 router01;
    IUniswapV2Router02 router02;

    IERC20Minimal token0;
    IERC20Minimal token1;
    IWETH         weth;
    IERC20Minimal wethPartner;

    IUniswapV2Pair pair;
    IUniswapV2Pair wethPair;

    // Use a deterministic key/address for permit signing
    uint256 walletKey = 0xA11CE;
    address wallet;

    // -------------------------------------------------------------------------
    // Setup
    // -------------------------------------------------------------------------
    function setUp() public {
        wallet = vm.addr(walletKey);
        vm.deal(address(this), 1_000 ether);
        vm.deal(wallet, 100 ether);

        // Tokens
        address tokenA        = deployCode("src/periphery/test/ERC20.sol:ERC20",  abi.encode(uint256(10_000e18)));
        address tokenB        = deployCode("src/periphery/test/ERC20.sol:ERC20",  abi.encode(uint256(10_000e18)));
        address wethAddr      = deployCode("WETH9.sol:WETH9");
        address wethPartnerAddr = deployCode("src/periphery/test/ERC20.sol:ERC20", abi.encode(uint256(10_000e18)));

        weth        = IWETH(wethAddr);
        wethPartner = IERC20Minimal(wethPartnerAddr);

        // Factory & routers
        address factoryAddr = deployCode(
            "UniswapV2Factory.sol:UniswapV2Factory",
            abi.encode(address(this))
        );
        factory = IUniswapV2Factory(factoryAddr);

        router01 = IUniswapV2Router02(deployCode(
            "UniswapV2Router01.sol:UniswapV2Router01",
            abi.encode(factoryAddr, wethAddr)
        ));
        router02 = IUniswapV2Router02(deployCode(
            "UniswapV2Router02.sol:UniswapV2Router02",
            abi.encode(factoryAddr, wethAddr)
        ));

        // Create token0/token1 pair
        factory.createPair(tokenA, tokenB);
        address pairAddr = factory.getPair(tokenA, tokenB);
        pair = IUniswapV2Pair(pairAddr);
        if (pair.token0() == tokenA) {
            token0 = IERC20Minimal(tokenA);
            token1 = IERC20Minimal(tokenB);
        } else {
            token0 = IERC20Minimal(tokenB);
            token1 = IERC20Minimal(tokenA);
        }

        // Create WETH pair
        factory.createPair(wethAddr, wethPartnerAddr);
        wethPair = IUniswapV2Pair(factory.getPair(wethAddr, wethPartnerAddr));
    }

    // Receive ETH from router removals
    receive() external payable {}

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------
    function _addLiquidityDirect(uint256 amount0, uint256 amount1) internal {
        token0.transfer(address(pair), amount0);
        token1.transfer(address(pair), amount1);
        pair.mint(address(this));
    }

    // -------------------------------------------------------------------------
    // factory / WETH
    // -------------------------------------------------------------------------
    function test_factoryAndWETH_router01() public view {
        assertEq(router01.factory(), address(factory));
        assertEq(router01.WETH(),    address(weth));
    }

    function test_factoryAndWETH_router02() public view {
        assertEq(router02.factory(), address(factory));
        assertEq(router02.WETH(),    address(weth));
    }

    // -------------------------------------------------------------------------
    // quote / getAmountOut / getAmountIn
    // -------------------------------------------------------------------------
    function test_quote() public {
        assertEq(router02.quote(1, 100, 200), 2);
        assertEq(router02.quote(2, 200, 100), 1);

        vm.expectRevert();
        router02.quote(0, 100, 200);

        vm.expectRevert();
        router02.quote(1, 0, 200);

        vm.expectRevert();
        router02.quote(1, 100, 0);
    }

    function test_getAmountOut() public {
        assertEq(router02.getAmountOut(2, 100, 100), 1);

        vm.expectRevert();
        router02.getAmountOut(0, 100, 100);

        vm.expectRevert();
        router02.getAmountOut(2, 0, 100);

        vm.expectRevert();
        router02.getAmountOut(2, 100, 0);
    }

    function test_getAmountIn() public {
        assertEq(router02.getAmountIn(1, 100, 100), 2);

        vm.expectRevert();
        router02.getAmountIn(0, 100, 100);

        vm.expectRevert();
        router02.getAmountIn(1, 0, 100);

        vm.expectRevert();
        router02.getAmountIn(1, 100, 0);
    }

    function test_getAmountsOut() public {
        token0.approve(address(router02), type(uint256).max);
        token1.approve(address(router02), type(uint256).max);
        router02.addLiquidity(
            address(token0), address(token1),
            10_000, 10_000, 0, 0,
            address(this), type(uint256).max
        );

        address[] memory path = new address[](1);
        path[0] = address(token0);
        vm.expectRevert();
        router02.getAmountsOut(2, path);

        address[] memory path2 = new address[](2);
        path2[0] = address(token0);
        path2[1] = address(token1);
        uint256[] memory amounts = router02.getAmountsOut(2, path2);
        assertEq(amounts[0], 2);
        assertEq(amounts[1], 1);
    }

    function test_getAmountsIn() public {
        token0.approve(address(router02), type(uint256).max);
        token1.approve(address(router02), type(uint256).max);
        router02.addLiquidity(
            address(token0), address(token1),
            10_000, 10_000, 0, 0,
            address(this), type(uint256).max
        );

        address[] memory path = new address[](1);
        path[0] = address(token0);
        vm.expectRevert();
        router02.getAmountsIn(1, path);

        address[] memory path2 = new address[](2);
        path2[0] = address(token0);
        path2[1] = address(token1);
        uint256[] memory amounts = router02.getAmountsIn(1, path2);
        assertEq(amounts[0], 2);
        assertEq(amounts[1], 1);
    }

    // -------------------------------------------------------------------------
    // addLiquidity (common to Router01 & Router02)
    // -------------------------------------------------------------------------
    function _testAddLiquidity(IUniswapV2Router02 router) internal {
        uint256 amount0 = 1e18;
        uint256 amount1 = 4e18;
        uint256 expectedLiq = 2e18;

        token0.approve(address(router), type(uint256).max);
        token1.approve(address(router), type(uint256).max);

        vm.expectEmit(true, true, false, true, address(pair));
        emit IUniswapV2Pair.Transfer(address(0), address(0), MINIMUM_LIQUIDITY);
        vm.expectEmit(true, true, false, true, address(pair));
        emit IUniswapV2Pair.Transfer(address(0), address(this), expectedLiq - MINIMUM_LIQUIDITY);
        vm.expectEmit(false, false, false, true, address(pair));
        emit IUniswapV2Pair.Sync(uint112(amount0), uint112(amount1));
        vm.expectEmit(true, false, false, true, address(pair));
        emit IUniswapV2Pair.Mint(address(router), amount0, amount1);

        router.addLiquidity(
            address(token0), address(token1),
            amount0, amount1, 0, 0,
            address(this), type(uint256).max
        );

        assertEq(pair.balanceOf(address(this)), expectedLiq - MINIMUM_LIQUIDITY);
    }

    function test_addLiquidity_router01() public { _testAddLiquidity(router01); }
    function test_addLiquidity_router02() public { _testAddLiquidity(router02); }

    // -------------------------------------------------------------------------
    // addLiquidityETH (common to Router01 & Router02)
    // -------------------------------------------------------------------------
    function _testAddLiquidityETH(IUniswapV2Router02 router) internal {
        uint256 partnerAmount = 1e18;
        uint256 ethAmount     = 4e18;
        uint256 expectedLiq   = 2e18;

        address wethPairToken0 = wethPair.token0();
        wethPartner.approve(address(router), type(uint256).max);

        vm.expectEmit(true, true, false, true, address(wethPair));
        emit IUniswapV2Pair.Transfer(address(0), address(0), MINIMUM_LIQUIDITY);
        vm.expectEmit(true, true, false, true, address(wethPair));
        emit IUniswapV2Pair.Transfer(address(0), address(this), expectedLiq - MINIMUM_LIQUIDITY);

        router.addLiquidityETH{value: ethAmount}(
            address(wethPartner),
            partnerAmount, partnerAmount, ethAmount,
            address(this), type(uint256).max
        );

        assertEq(wethPair.balanceOf(address(this)), expectedLiq - MINIMUM_LIQUIDITY);
        (wethPairToken0) = (wethPairToken0); // silence unused warning
    }

    function test_addLiquidityETH_router01() public { _testAddLiquidityETH(router01); }
    function test_addLiquidityETH_router02() public { _testAddLiquidityETH(router02); }

    // -------------------------------------------------------------------------
    // removeLiquidity (common to Router01 & Router02)
    // -------------------------------------------------------------------------
    function _testRemoveLiquidity(IUniswapV2Router02 router) internal {
        uint256 amount0 = 1e18;
        uint256 amount1 = 4e18;
        _addLiquidityDirect(amount0, amount1);

        uint256 expectedLiq = 2e18;
        pair.approve(address(router), type(uint256).max);

        router.removeLiquidity(
            address(token0), address(token1),
            expectedLiq - MINIMUM_LIQUIDITY,
            0, 0,
            address(this), type(uint256).max
        );

        assertEq(pair.balanceOf(address(this)), 0);

        uint256 total0 = token0.totalSupply();
        uint256 total1 = token1.totalSupply();
        assertEq(token0.balanceOf(address(this)), total0 - 500);
        assertEq(token1.balanceOf(address(this)), total1 - 2000);
    }

    function test_removeLiquidity_router01() public { _testRemoveLiquidity(router01); }
    function test_removeLiquidity_router02() public { _testRemoveLiquidity(router02); }

    // -------------------------------------------------------------------------
    // removeLiquidityETH (common to Router01 & Router02)
    // -------------------------------------------------------------------------
    function _testRemoveLiquidityETH(IUniswapV2Router02 router) internal {
        uint256 partnerAmount = 1e18;
        uint256 ethAmount     = 4e18;
        uint256 expectedLiq   = 2e18;

        // Direct deposit to pair
        wethPartner.transfer(address(wethPair), partnerAmount);
        weth.deposit{value: ethAmount}();
        weth.transfer(address(wethPair), ethAmount);
        wethPair.mint(address(this));

        wethPair.approve(address(router), type(uint256).max);
        router.removeLiquidityETH(
            address(wethPartner),
            expectedLiq - MINIMUM_LIQUIDITY,
            0, 0,
            address(this), type(uint256).max
        );

        assertEq(wethPair.balanceOf(address(this)), 0);
    }

    function test_removeLiquidityETH_router01() public { _testRemoveLiquidityETH(router01); }
    function test_removeLiquidityETH_router02() public { _testRemoveLiquidityETH(router02); }

    // -------------------------------------------------------------------------
    // removeLiquidityWithPermit (Router01 & Router02)
    // -------------------------------------------------------------------------
    function _testRemoveLiquidityWithPermit(IUniswapV2Router02 router) internal {
        uint256 amount0 = 1e18;
        uint256 amount1 = 4e18;
        // Add liquidity; wallet receives LP tokens via direct transfer + mint
        token0.transfer(address(pair), amount0);
        token1.transfer(address(pair), amount1);
        pair.mint(wallet);                         // LP goes to wallet

        uint256 liq      = pair.balanceOf(wallet);
        uint256 deadline = type(uint256).max;

        bytes32 digest = keccak256(abi.encodePacked(
            "\x19\x01",
            pair.DOMAIN_SEPARATOR(),
            keccak256(abi.encode(
                pair.PERMIT_TYPEHASH(),
                wallet,
                address(router),
                liq,
                pair.nonces(wallet),
                deadline
            ))
        ));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(walletKey, digest);

        vm.prank(wallet);
        router.removeLiquidityWithPermit(
            address(token0), address(token1),
            liq, 0, 0,
            wallet, deadline,
            false, v, r, s
        );

        assertEq(pair.balanceOf(wallet), 0);
    }

    function test_removeLiquidityWithPermit_router01() public { _testRemoveLiquidityWithPermit(router01); }
    function test_removeLiquidityWithPermit_router02() public { _testRemoveLiquidityWithPermit(router02); }

    // -------------------------------------------------------------------------
    // swapExactTokensForTokens (common to Router01 & Router02)
    // -------------------------------------------------------------------------
    function _testSwapExactTokensForTokens(IUniswapV2Router02 router) internal {
        uint256 amount0 = 5e18;
        uint256 amount1 = 10e18;
        _addLiquidityDirect(amount0, amount1);

        token0.approve(address(router), type(uint256).max);

        address[] memory path = new address[](2);
        path[0] = address(token0);
        path[1] = address(token1);

        uint256 swapAmountIn     = 1e18;
        uint256 expectedAmountOut = 1_662_497_915_624_478_906;

        uint256 balBefore = token1.balanceOf(address(this));
        router.swapExactTokensForTokens(swapAmountIn, 0, path, address(this), type(uint256).max);
        uint256 received = token1.balanceOf(address(this)) - balBefore;

        assertEq(received, expectedAmountOut);
    }

    function test_swapExactTokensForTokens_router01() public { _testSwapExactTokensForTokens(router01); }
    function test_swapExactTokensForTokens_router02() public { _testSwapExactTokensForTokens(router02); }

    // -------------------------------------------------------------------------
    // swapTokensForExactTokens (common to Router01 & Router02)
    // -------------------------------------------------------------------------
    function _testSwapTokensForExactTokens(IUniswapV2Router02 router) internal {
        uint256 amount0 = 5e18;
        uint256 amount1 = 10e18;
        _addLiquidityDirect(amount0, amount1);

        token0.approve(address(router), type(uint256).max);

        address[] memory path = new address[](2);
        path[0] = address(token0);
        path[1] = address(token1);

        uint256 exactOut   = 1e18;
        // Note: UniswapV2Router01 has a known bug — its getAmountIn() calls getAmountOut()
        // internally. Use router02's correct implementation as the reference for both tests.
        uint256 expectedIn = router02.getAmountIn(exactOut, amount0, amount1);

        uint256 balBefore = token0.balanceOf(address(this));
        router.swapTokensForExactTokens(exactOut, type(uint256).max, path, address(this), type(uint256).max);
        uint256 spent = balBefore - token0.balanceOf(address(this));

        assertEq(spent, expectedIn);
        assertEq(token1.balanceOf(address(this)), token1.totalSupply() - amount1 + exactOut);
    }

    function test_swapTokensForExactTokens_router01() public { _testSwapTokensForExactTokens(router01); }
    function test_swapTokensForExactTokens_router02() public { _testSwapTokensForExactTokens(router02); }

    // -------------------------------------------------------------------------
    // swapExactETHForTokens (common to Router01 & Router02)
    // -------------------------------------------------------------------------
    function _testSwapExactETHForTokens(IUniswapV2Router02 router) internal {
        uint256 wethPartnerAmount = 10e18;
        uint256 ethAmount         = 5e18;

        // Seed WETH pair directly
        wethPartner.transfer(address(wethPair), wethPartnerAmount);
        weth.deposit{value: ethAmount}();
        weth.transfer(address(wethPair), ethAmount);
        wethPair.mint(address(this));

        address[] memory path = new address[](2);
        path[0] = address(weth);
        path[1] = address(wethPartner);

        uint256 swapEth  = 1e18;
        uint256 balBefore = wethPartner.balanceOf(address(this));
        router.swapExactETHForTokens{value: swapEth}(0, path, address(this), type(uint256).max);
        uint256 received = wethPartner.balanceOf(address(this)) - balBefore;

        assertGt(received, 0);
    }

    function test_swapExactETHForTokens_router01() public { _testSwapExactETHForTokens(router01); }
    function test_swapExactETHForTokens_router02() public { _testSwapExactETHForTokens(router02); }

    // -------------------------------------------------------------------------
    // swapExactTokensForETH (common to Router01 & Router02)
    // -------------------------------------------------------------------------
    function _testSwapExactTokensForETH(IUniswapV2Router02 router) internal {
        uint256 wethPartnerAmount = 5e18;
        uint256 ethAmount         = 10e18;

        wethPartner.transfer(address(wethPair), wethPartnerAmount);
        weth.deposit{value: ethAmount}();
        weth.transfer(address(wethPair), ethAmount);
        wethPair.mint(address(this));

        wethPartner.approve(address(router), type(uint256).max);

        address[] memory path = new address[](2);
        path[0] = address(wethPartner);
        path[1] = address(weth);

        uint256 swapIn   = 1e18;
        uint256 balBefore = address(this).balance;
        router.swapExactTokensForETH(swapIn, 0, path, address(this), type(uint256).max);
        uint256 ethReceived = address(this).balance - balBefore;

        assertGt(ethReceived, 0);
    }

    function test_swapExactTokensForETH_router01() public { _testSwapExactTokensForETH(router01); }
    function test_swapExactTokensForETH_router02() public { _testSwapExactTokensForETH(router02); }

    // =========================================================================
    // fee-on-transfer token tests (Router02 only)
    // =========================================================================
    IERC20Minimal dtt; // DeflatingERC20
    IUniswapV2Pair dttPair;

    function _setupFOT() internal {
        dtt = IERC20Minimal(deployCode("src/periphery/test/DeflatingERC20.sol:DeflatingERC20", abi.encode(uint256(10_000e18))));
        factory.createPair(address(dtt), address(weth));
        dttPair = IUniswapV2Pair(factory.getPair(address(dtt), address(weth)));
    }

    function _addDTTLiquidity(uint256 dttAmount, uint256 ethAmount) internal {
        dtt.approve(address(router02), type(uint256).max);
        router02.addLiquidityETH{value: ethAmount}(
            address(dtt),
            dttAmount, dttAmount, ethAmount,
            address(this), type(uint256).max
        );
    }

    function test_removeLiquidityETHSupportingFeeOnTransferTokens() public {
        _setupFOT();
        uint256 dttAmount = 1e18;
        uint256 ethAmount = 4e18;
        _addDTTLiquidity(dttAmount, ethAmount);

        uint256 dttInPair   = dtt.balanceOf(address(dttPair));
        uint256 wethInPair  = weth.balanceOf(address(dttPair));
        uint256 liq         = dttPair.balanceOf(address(this));
        uint256 totalSupply = dttPair.totalSupply();

        uint256 naiveDTTExpected  = dttInPair  * liq / totalSupply;
        uint256 wethExpected      = wethInPair * liq / totalSupply;

        dttPair.approve(address(router02), type(uint256).max);
        router02.removeLiquidityETHSupportingFeeOnTransferTokens(
            address(dtt),
            liq,
            naiveDTTExpected, wethExpected,
            address(this), type(uint256).max
        );

        // Router must hold no ETH after the operation
        assertEq(address(router02).balance, 0);
    }

    function test_swapExactTokensForTokensSupportingFeeOnTransferTokens() public {
        _setupFOT();
        uint256 dttAmount = 5e18;
        uint256 ethAmount = 10e18;

        // Seed DTT–WETH pair
        dtt.transfer(address(dttPair), dttAmount);
        weth.deposit{value: ethAmount}();
        weth.transfer(address(dttPair), ethAmount);
        dttPair.mint(address(this));

        dtt.approve(address(router02), type(uint256).max);

        address[] memory path = new address[](2);
        path[0] = address(dtt);
        path[1] = address(weth);

        uint256 swapIn = 1e18;
        uint256 balBefore = weth.balanceOf(address(this));
        router02.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            swapIn, 0, path, address(this), type(uint256).max
        );
        assertGt(weth.balanceOf(address(this)) - balBefore, 0);
    }

    function test_swapExactETHForTokensSupportingFeeOnTransferTokens() public {
        _setupFOT();
        uint256 dttAmount = 10e18;
        uint256 ethAmount = 5e18;

        dtt.transfer(address(dttPair), dttAmount);
        weth.deposit{value: ethAmount}();
        weth.transfer(address(dttPair), ethAmount);
        dttPair.mint(address(this));

        address[] memory path = new address[](2);
        path[0] = address(weth);
        path[1] = address(dtt);

        uint256 balBefore = dtt.balanceOf(address(this));
        router02.swapExactETHForTokensSupportingFeeOnTransferTokens{value: 1e18}(
            0, path, address(this), type(uint256).max
        );
        assertGt(dtt.balanceOf(address(this)) - balBefore, 0);
    }

    function test_swapExactTokensForETHSupportingFeeOnTransferTokens() public {
        _setupFOT();
        uint256 dttAmount = 5e18;
        uint256 ethAmount = 10e18;

        dtt.transfer(address(dttPair), dttAmount);
        weth.deposit{value: ethAmount}();
        weth.transfer(address(dttPair), ethAmount);
        dttPair.mint(address(this));

        dtt.approve(address(router02), type(uint256).max);

        address[] memory path = new address[](2);
        path[0] = address(dtt);
        path[1] = address(weth);

        uint256 balBefore = address(this).balance;
        router02.swapExactTokensForETHSupportingFeeOnTransferTokens(
            1e18, 0, path, address(this), type(uint256).max
        );
        assertGt(address(this).balance - balBefore, 0);
    }

    // -------------------------------------------------------------------------
    // Aftercheck: router never holds ETH
    // -------------------------------------------------------------------------
    function invariant_routerHoldsNoETH() public view {
        assertEq(address(router01).balance, 0);
        assertEq(address(router02).balance, 0);
    }
}
