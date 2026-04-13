// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";
import "./helpers/MockUniswapV1.sol";

interface IWETH9Flash {
    function deposit() external payable;

    function withdraw(uint256) external;

    function transfer(address, uint256) external returns (bool);

    function balanceOf(address) external view returns (uint256);
}

interface IRouter01Flash {
    function WETH() external pure returns (address);
}

interface IERC20Flash {
    function approve(address, uint256) external returns (bool);

    function transfer(address, uint256) external returns (bool);

    function balanceOf(address) external view returns (uint256);
}

/// @dev Forge port of v2-periphery/test/ExampleFlashSwap.spec.ts
contract ExampleFlashSwapTest is Test {
    IUniswapV2Factory factoryV2;
    MockUniswapV1Factory factoryV1;
    IWETH9Flash weth;
    IERC20Flash wethPartner;
    IUniswapV2Pair wethPair;
    address flashSwapExample;
    address router;

    receive() external payable {}

    function setUp() public {
        vm.deal(address(this), 200 ether);

        // Deploy WETH9
        weth = IWETH9Flash(deployCode("WETH9.sol:WETH9"));

        // Deploy mock V1 factory
        factoryV1 = new MockUniswapV1Factory();

        // Deploy V2 factory
        factoryV2 = IUniswapV2Factory(
            deployCode(
                "UniswapV2Factory.sol:UniswapV2Factory",
                abi.encode(address(this))
            )
        );

        // Deploy a minimal router (only used to satisfy ExampleFlashSwap constructor's WETH() call)
        router = deployCode(
            "UniswapV2Router01.sol:UniswapV2Router01",
            abi.encode(address(factoryV2), address(weth))
        );

        // Deploy WETHPartner ERC20 token
        wethPartner = IERC20Flash(
            deployCode(
                "src/periphery/test/ERC20.sol:ERC20",
                abi.encode(uint256(10_000e18))
            )
        );

        // Create V1 exchange for WETHPartner
        factoryV1.createExchange(address(wethPartner));

        // Create V2 WETH/WETHPartner pair
        factoryV2.createPair(address(weth), address(wethPartner));
        wethPair = IUniswapV2Pair(
            factoryV2.getPair(address(weth), address(wethPartner))
        );

        // Deploy ExampleFlashSwap(factory_v2, factory_v1, router)
        flashSwapExample = deployCode(
            "ExampleFlashSwap.sol:ExampleFlashSwap",
            abi.encode(address(factoryV2), address(factoryV1), router)
        );
    }

    // -------------------------------------------------------------------------
    // Helper: add V1 liquidity (ETH+WETHPartner)
    // -------------------------------------------------------------------------
    function _addV1Liquidity(uint256 tokenAmount, uint256 ethAmount) internal {
        MockUniswapV1Exchange v1Exchange = MockUniswapV1Exchange(
            payable(factoryV1.getExchange(address(wethPartner)))
        );
        wethPartner.approve(address(v1Exchange), type(uint256).max);
        v1Exchange.addLiquidity{value: ethAmount}(
            1,
            tokenAmount,
            type(uint256).max
        );
    }

    // -------------------------------------------------------------------------
    // Helper: add V2 WETH/WETHPartner liquidity
    // -------------------------------------------------------------------------
    function _addV2Liquidity(uint256 tokenAmount, uint256 ethAmount) internal {
        wethPartner.transfer(address(wethPair), tokenAmount);
        weth.deposit{value: ethAmount}();
        weth.transfer(address(wethPair), ethAmount);
        wethPair.mint(address(this));
    }

    // -------------------------------------------------------------------------
    // uniswapV2Call:0
    //   V1 liquidity  = 2000 WETHPartner / 10 ETH  (rate = 200 tokens per ETH)
    //   V2 liquidity  = 1000 WETHPartner / 10 WETH  (rate = 100 tokens per ETH)
    //   Action: flash borrow 1 ETH from V2, arb on V1, repay V2 in tokens
    //   Expected profit: ~69 WETHPartner tokens (integer division of wei amount / 1e18)
    // -------------------------------------------------------------------------
    function test_uniswapV2Call_0_ethArbitrage() public {
        _addV1Liquidity(2000e18, 10 ether);
        _addV2Liquidity(1000e18, 10 ether);

        uint256 balanceBefore = wethPartner.balanceOf(address(this));

        // Flash borrow 1 ETH (WETH) from V2
        uint256 arbitrageAmount = 1e18;
        address token0 = wethPair.token0();
        uint256 amount0 = token0 == address(wethPartner) ? 0 : arbitrageAmount;
        uint256 amount1 = token0 == address(wethPartner) ? arbitrageAmount : 0;

        wethPair.swap(
            amount0,
            amount1,
            flashSwapExample,
            abi.encode(uint256(1))
        );

        uint256 balanceAfter = wethPartner.balanceOf(address(this));
        uint256 profit = balanceAfter - balanceBefore;

        // Profit ÷ 1e18 ≈ 69 (JS: profit.div(expandTo18Decimals(1)).toString() === '69')
        assertEq(profit / 1e18, 69, "profit should be ~69 tokens");

        // Sanity: V1 price should have dropped (V2 price risen)
        MockUniswapV1Exchange v1Exchange = MockUniswapV1Exchange(
            payable(factoryV1.getExchange(address(wethPartner)))
        );
        uint256 v1TokenReserve = wethPartner.balanceOf(address(v1Exchange));
        uint256 v1EthReserve = address(v1Exchange).balance;
        assertApproxEqAbs(
            v1TokenReserve / v1EthReserve,
            165,
            5,
            "V1 price should be ~165"
        );
    }

    // -------------------------------------------------------------------------
    // uniswapV2Call:1
    //   V1 liquidity  = 1000 WETHPartner / 10 ETH  (rate = 100 tokens per ETH)
    //   V2 liquidity  = 2000 WETHPartner / 10 WETH  (rate = 200 tokens per ETH)
    //   Action: flash borrow 200 WETHPartner from V2, arb on V1, repay V2 in WETH
    //   Expected profit: 548043441089763649 wei (~0.548 ETH)
    // -------------------------------------------------------------------------
    function test_uniswapV2Call_1_tokenArbitrage() public {
        _addV1Liquidity(1000e18, 10 ether);
        _addV2Liquidity(2000e18, 10 ether);

        uint256 balanceBefore = address(this).balance;

        // Flash borrow 200 tokens from V2
        uint256 arbitrageAmount = 200e18;
        address token0 = wethPair.token0();
        uint256 amount0 = token0 == address(wethPartner) ? arbitrageAmount : 0;
        uint256 amount1 = token0 == address(wethPartner) ? 0 : arbitrageAmount;

        wethPair.swap(
            amount0,
            amount1,
            flashSwapExample,
            abi.encode(uint256(1))
        );

        uint256 balanceAfter = address(this).balance;
        uint256 profit = balanceAfter - balanceBefore;

        // JS expects profit == 548043441089763649 wei
        assertEq(
            profit,
            548_043_441_089_763_649,
            "profit should be ~0.548 ETH"
        );

        // Sanity: V1 price should have risen, V2 price dropped
        MockUniswapV1Exchange v1Exchange = MockUniswapV1Exchange(
            payable(factoryV1.getExchange(address(wethPartner)))
        );
        uint256 v1TokenReserve = wethPartner.balanceOf(address(v1Exchange));
        uint256 v1EthReserve = address(v1Exchange).balance;
        assertApproxEqAbs(
            v1TokenReserve / v1EthReserve,
            143,
            5,
            "V1 price should be ~143"
        );
    }
}
