// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";
import "@uniswap/v2-periphery/interfaces/IUniswapV2Router01.sol";
import "./helpers/MockUniswapV1.sol";

interface IERC20MigMin {
    function approve(address, uint256) external returns (bool);

    function balanceOf(address) external view returns (uint256);

    function transfer(address, uint256) external returns (bool);
}

interface IWETH9Mig {
    function deposit() external payable;

    function transfer(address, uint256) external returns (bool);

    function balanceOf(address) external view returns (uint256);
}

interface IMigrator {
    function migrate(address token, uint256 amountTokenMin, uint256 amountETHMin, address to, uint256 deadline) external;
}

/// @dev Forge port of v2-periphery/test/UniswapV2Migrator.spec.ts
contract UniswapV2MigratorTest is Test {
    uint256 constant MINIMUM_LIQUIDITY = 1_000;

    IUniswapV2Factory factoryV2;
    MockUniswapV1Factory factoryV1;
    IUniswapV2Router01 router01;
    IMigrator migrator;
    IERC20MigMin wethPartner;
    IUniswapV2Pair wethPair;
    MockUniswapV1Exchange wethExchangeV1;
    IWETH9Mig weth;

    receive() external payable {}

    function setUp() public {
        vm.deal(address(this), 100 ether);

        // Deploy WETH9
        weth = IWETH9Mig(deployCode("WETH9.sol:WETH9"));

        // Deploy mock V1 factory
        factoryV1 = new MockUniswapV1Factory();

        // Deploy V2 factory and router
        factoryV2 = IUniswapV2Factory(deployCode("UniswapV2Factory.sol:UniswapV2Factory", abi.encode(address(this))));
        router01 = IUniswapV2Router01(
            deployCode("UniswapV2Router01.sol:UniswapV2Router01", abi.encode(address(factoryV2), address(weth)))
        );

        // Deploy Migrator
        migrator = IMigrator(
            deployCode("UniswapV2Migrator.sol:UniswapV2Migrator", abi.encode(address(factoryV1), address(router01)))
        );

        // Deploy WETHPartner token and create V1 exchange
        wethPartner = IERC20MigMin(deployCode("src/periphery/test/ERC20.sol:ERC20", abi.encode(uint256(10_000e18))));
        address exchAddr = factoryV1.createExchange(address(wethPartner));
        wethExchangeV1 = MockUniswapV1Exchange(payable(exchAddr));

        // Create V2 WETH/WETHPartner pair
        factoryV2.createPair(address(weth), address(wethPartner));
        wethPair = IUniswapV2Pair(factoryV2.getPair(address(weth), address(wethPartner)));
    }

    /// @dev Forge port of the single "migrate" test in UniswapV2Migrator.spec.ts
    function test_migrate() public {
        uint256 wethPartnerAmount = 1e18;
        uint256 ethAmount = 4e18;

        // Add liquidity to V1 (1 token : 4 ETH)
        wethPartner.approve(address(wethExchangeV1), type(uint256).max);
        wethExchangeV1.addLiquidity{value: ethAmount}(1, wethPartnerAmount, type(uint256).max);

        // V1 LP minted = msg.value = 4e18
        assertEq(wethExchangeV1.balanceOf(address(this)), ethAmount);

        // Approve Migrator to pull V1 LP
        wethExchangeV1.approve(address(migrator), type(uint256).max);

        // Expected V2 LP = sqrt(1e18 * 4e18) - MINIMUM_LIQUIDITY = 2e18 - 1000
        uint256 expectedLiquidity = 2e18;
        address pairToken0 = wethPair.token0();

        vm.expectEmit(true, true, false, true, address(wethPair));
        emit IUniswapV2Pair.Transfer(address(0), address(0), MINIMUM_LIQUIDITY);

        vm.expectEmit(true, true, false, true, address(wethPair));
        emit IUniswapV2Pair.Transfer(address(0), address(this), expectedLiquidity - MINIMUM_LIQUIDITY);

        vm.expectEmit(false, false, false, true, address(wethPair));
        emit IUniswapV2Pair.Sync(
            uint112(pairToken0 == address(wethPartner) ? wethPartnerAmount : ethAmount),
            uint112(pairToken0 == address(wethPartner) ? ethAmount : wethPartnerAmount)
        );

        vm.expectEmit(true, false, false, true, address(wethPair));
        emit IUniswapV2Pair.Mint(
            address(router01),
            pairToken0 == address(wethPartner) ? wethPartnerAmount : ethAmount,
            pairToken0 == address(wethPartner) ? ethAmount : wethPartnerAmount
        );

        migrator.migrate(address(wethPartner), wethPartnerAmount, ethAmount, address(this), type(uint256).max);

        assertEq(wethPair.balanceOf(address(this)), expectedLiquidity - MINIMUM_LIQUIDITY);
        assertEq(wethPair.totalSupply(), expectedLiquidity);
    }
}
