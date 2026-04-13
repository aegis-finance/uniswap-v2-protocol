// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";

interface ISlidingWindowOracle {
    function update(address tokenA, address tokenB) external;

    function consult(
        address tokenIn,
        uint amountIn,
        address tokenOut
    ) external view returns (uint amountOut);

    function observationIndexOf(uint timestamp) external view returns (uint8);

    function pairObservations(
        address pair,
        uint index
    ) external view returns (uint, uint, uint);

    function periodSize() external view returns (uint);
}

/// @dev Forge port of v2-periphery/test/ExampleSlidingWindowOracle.spec.ts
contract ExampleSlidingWindowOracleTest is Test {
    IUniswapV2Factory factory;
    IUniswapV2Pair pair;
    address token0addr;
    address token1addr;
    address wethAddr;

    uint256 constant DEFAULT_TOKEN0 = 5e18;
    uint256 constant DEFAULT_TOKEN1 = 10e18;
    uint256 constant WINDOW_SIZE = 86_400; // 24 hours
    uint8 constant GRANULARITY = 24;
    uint256 constant PERIOD_SIZE = WINDOW_SIZE / GRANULARITY; // 3600

    // match JS helper
    function _observationIndexOf(uint256 ts) internal pure returns (uint8) {
        return uint8((ts / PERIOD_SIZE) % GRANULARITY);
    }

    function _encodePrice(
        uint256 r0,
        uint256 r1
    ) internal pure returns (uint256 p0, uint256 p1) {
        p0 = (r1 << 112) / r0;
        p1 = (r0 << 112) / r1;
    }

    // 1 Jan 2020 00:00 UTC — must not be 0 and not 86400
    uint256 constant START_TIME = 1_577_836_800;

    function _deployOracle(
        uint256 windowSize,
        uint8 granularity
    ) internal returns (ISlidingWindowOracle) {
        return
            ISlidingWindowOracle(
                deployCode(
                    "ExampleSlidingWindowOracle.sol:ExampleSlidingWindowOracle",
                    abi.encode(address(factory), windowSize, granularity)
                )
            );
    }

    function _transfer(address token, address to, uint256 amount) internal {
        (bool ok, ) = token.call(
            abi.encodeWithSignature("transfer(address,uint256)", to, amount)
        );
        require(ok);
    }

    function _addLiquidity(uint256 amount0, uint256 amount1) internal {
        if (amount0 > 0) _transfer(token0addr, address(pair), amount0);
        if (amount1 > 0) _transfer(token1addr, address(pair), amount1);
        pair.sync();
    }

    function setUp() public {
        // Deploy tokens, factory, pair
        address tA = deployCode(
            "src/periphery/test/ERC20.sol:ERC20",
            abi.encode(uint256(100_000e18))
        );
        address tB = deployCode(
            "src/periphery/test/ERC20.sol:ERC20",
            abi.encode(uint256(100_000e18))
        );

        factory = IUniswapV2Factory(
            deployCode(
                "UniswapV2Factory.sol:UniswapV2Factory",
                abi.encode(address(this))
            )
        );
        factory.createPair(tA, tB);
        pair = IUniswapV2Pair(factory.getPair(tA, tB));

        if (pair.token0() == tA) {
            token0addr = tA;
            token1addr = tB;
        } else {
            token0addr = tB;
            token1addr = tA;
        }

        wethAddr = makeAddr("weth"); // not used in oracle tests, needed for invalid-pair checks

        // Set timestamp to START_TIME before any pair interaction
        vm.warp(START_TIME);
    }

    // -------------------------------------------------------------------------
    // Constructor validation
    // -------------------------------------------------------------------------
    function test_requiresGranularityGtZero() public {
        vm.expectRevert();
        _deployOracle(WINDOW_SIZE, 0);
    }

    function test_requiresWindowEvenlyDivisible() public {
        vm.expectRevert();
        _deployOracle(WINDOW_SIZE - 1, GRANULARITY);
    }

    function test_periodSizeComputed() public {
        ISlidingWindowOracle oracle = _deployOracle(WINDOW_SIZE, GRANULARITY);
        assertEq(oracle.periodSize(), 3600);

        ISlidingWindowOracle oracle2 = _deployOracle(
            WINDOW_SIZE * 2,
            GRANULARITY / 2
        );
        assertEq(oracle2.periodSize(), 3600 * 4);
    }

    // -------------------------------------------------------------------------
    // #observationIndexOf
    // -------------------------------------------------------------------------
    function test_observationIndexOf_examples() public {
        ISlidingWindowOracle oracle = _deployOracle(WINDOW_SIZE, GRANULARITY);
        assertEq(oracle.observationIndexOf(0), 0);
        assertEq(oracle.observationIndexOf(3599), 0);
        assertEq(oracle.observationIndexOf(3600), 1);
        assertEq(oracle.observationIndexOf(4800), 1);
        assertEq(oracle.observationIndexOf(7199), 1);
        assertEq(oracle.observationIndexOf(7200), 2);
        assertEq(oracle.observationIndexOf(86399), 23);
        assertEq(oracle.observationIndexOf(86400), 0);
        assertEq(oracle.observationIndexOf(90000), 1);
    }

    function test_observationIndexOf_overflowSafe() public {
        ISlidingWindowOracle oracle = _deployOracle(25500, 255); // 100 period size
        assertEq(oracle.observationIndexOf(0), 0);
        assertEq(oracle.observationIndexOf(99), 0);
        assertEq(oracle.observationIndexOf(100), 1);
        assertEq(oracle.observationIndexOf(199), 1);
        assertEq(oracle.observationIndexOf(25499), 254);
        assertEq(oracle.observationIndexOf(25500), 0);
    }

    function test_observationIndexOf_matchesOffline() public {
        ISlidingWindowOracle oracle = _deployOracle(WINDOW_SIZE, GRANULARITY);
        uint256[7] memory timestamps = [
            uint256(0),
            5000,
            1000,
            25000,
            86399,
            86400,
            86401
        ];
        for (uint i; i < timestamps.length; i++) {
            assertEq(
                oracle.observationIndexOf(timestamps[i]),
                _observationIndexOf(timestamps[i])
            );
        }
    }

    // -------------------------------------------------------------------------
    // #update
    // -------------------------------------------------------------------------
    function test_update_succeeds() public {
        ISlidingWindowOracle oracle = _deployOracle(WINDOW_SIZE, GRANULARITY);
        _addLiquidity(DEFAULT_TOKEN0, DEFAULT_TOKEN1);
        oracle.update(token0addr, token1addr);
    }

    function test_update_setsEpochSlot() public {
        ISlidingWindowOracle oracle = _deployOracle(WINDOW_SIZE, GRANULARITY);
        _addLiquidity(DEFAULT_TOKEN0, DEFAULT_TOKEN1);

        (, , uint32 blockTs) = pair.getReserves();
        oracle.update(token0addr, token1addr);

        (uint obsTs, uint obsCum0, uint obsCum1) = oracle.pairObservations(
            address(pair),
            _observationIndexOf(blockTs)
        );

        assertEq(obsTs, blockTs);
        assertEq(obsCum0, pair.price0CumulativeLast());
        assertEq(obsCum1, pair.price1CumulativeLast());
    }

    function test_update_secondInSamePeriodDoesNotOverwrite() public {
        ISlidingWindowOracle oracle = _deployOracle(WINDOW_SIZE, GRANULARITY);
        _addLiquidity(DEFAULT_TOKEN0, DEFAULT_TOKEN1);

        oracle.update(token0addr, token1addr);
        (uint ts0, uint c0_0, uint c1_0) = oracle.pairObservations(
            address(pair),
            _observationIndexOf(0)
        );

        // Still within same hour window
        vm.warp(START_TIME + 1800);
        oracle.update(token0addr, token1addr);
        (uint ts1, uint c0_1, uint c1_1) = oracle.pairObservations(
            address(pair),
            _observationIndexOf(1800)
        );

        assertEq(_observationIndexOf(1800), _observationIndexOf(0));
        assertEq(ts0, ts1);
        assertEq(c0_0, c0_1);
        assertEq(c1_0, c1_1);
    }

    function test_update_failsForInvalidPair() public {
        ISlidingWindowOracle oracle = _deployOracle(WINDOW_SIZE, GRANULARITY);
        _addLiquidity(DEFAULT_TOKEN0, DEFAULT_TOKEN1);
        vm.expectRevert();
        oracle.update(wethAddr, token1addr);
    }

    // -------------------------------------------------------------------------
    // #consult — happy path
    // -------------------------------------------------------------------------
    function test_consult_failsMissingHistoricalObservation() public {
        ISlidingWindowOracle oracle = _deployOracle(WINDOW_SIZE, GRANULARITY);
        _addLiquidity(DEFAULT_TOKEN0, DEFAULT_TOKEN1);
        oracle.update(token0addr, token1addr);

        vm.expectRevert();
        oracle.consult(token0addr, 0, token1addr);
    }

    function test_consult_failsInvalidPair() public {
        ISlidingWindowOracle oracle = _deployOracle(WINDOW_SIZE, GRANULARITY);
        _addLiquidity(DEFAULT_TOKEN0, DEFAULT_TOKEN1);
        vm.expectRevert();
        oracle.consult(wethAddr, 0, token1addr);
    }

    function test_consult_providesCorrectRatioToken0() public {
        ISlidingWindowOracle oracle = _deployOracle(WINDOW_SIZE, GRANULARITY);
        _addLiquidity(DEFAULT_TOKEN0, DEFAULT_TOKEN1);
        oracle.update(token0addr, token1addr);

        // Jump ~23 hours and take second observation
        vm.warp(START_TIME + 23 * 3600);
        oracle.update(token0addr, token1addr);

        // 5:10 ratio → 100 in gives 200 out
        assertEq(oracle.consult(token0addr, 100, token1addr), 200);
    }

    function test_consult_providesCorrectRatioToken1() public {
        ISlidingWindowOracle oracle = _deployOracle(WINDOW_SIZE, GRANULARITY);
        _addLiquidity(DEFAULT_TOKEN0, DEFAULT_TOKEN1);
        oracle.update(token0addr, token1addr);

        vm.warp(START_TIME + 23 * 3600);
        oracle.update(token0addr, token1addr);

        // 10:5 ratio → 100 in gives 50 out
        assertEq(oracle.consult(token1addr, 100, token0addr), 50);
    }

    // -------------------------------------------------------------------------
    // #consult — price changes over the window
    // -------------------------------------------------------------------------
    function _buildPriceHistory(ISlidingWindowOracle oracle) internal {
        // hour 0: price 1:2 (DEFAULT_TOKEN0=5, DEFAULT_TOKEN1=10)
        _addLiquidity(DEFAULT_TOKEN0, DEFAULT_TOKEN1);
        oracle.update(token0addr, token1addr);

        // hour 3: add equal token0 → price becomes 1:1
        vm.warp(START_TIME + 3 * 3600);
        _addLiquidity(DEFAULT_TOKEN0, 0); // add 5 more token0, reserves now 10:10
        oracle.update(token0addr, token1addr);

        // hour 6: add 2x token0 → price becomes 2:1 (don't update immediately)
        vm.warp(START_TIME + 6 * 3600);
        _transfer(token0addr, address(pair), DEFAULT_TOKEN0 * 2);
        pair.sync();

        // hour 9: update (price 2:1 has been in effect for 3 hours)
        vm.warp(START_TIME + 9 * 3600);
        oracle.update(token0addr, token1addr);

        // advance to hour 23 to check prices
        vm.warp(START_TIME + 23 * 3600);
    }

    function test_consult_priceChanges_token0AtHour23() public {
        ISlidingWindowOracle oracle = _deployOracle(WINDOW_SIZE, GRANULARITY);
        _buildPriceHistory(oracle);
        // token0 spent 3h at 2, 3h at 1, 17h at 0.5 → weighted avg < 1
        assertEq(oracle.consult(token0addr, 100, token1addr), 76);
    }

    function test_consult_priceChanges_token1AtHour23() public {
        ISlidingWindowOracle oracle = _deployOracle(WINDOW_SIZE, GRANULARITY);
        _buildPriceHistory(oracle);
        assertEq(oracle.consult(token1addr, 100, token0addr), 167);
    }

    function test_consult_priceChanges_token0AtHour32() public {
        ISlidingWindowOracle oracle = _deployOracle(WINDOW_SIZE, GRANULARITY);
        _buildPriceHistory(oracle);
        vm.warp(START_TIME + 32 * 3600);
        // all 24-hour window now at 2:1
        assertEq(oracle.consult(token0addr, 100, token1addr), 50);
    }

    function test_consult_priceChanges_token1AtHour32() public {
        ISlidingWindowOracle oracle = _deployOracle(WINDOW_SIZE, GRANULARITY);
        _buildPriceHistory(oracle);
        vm.warp(START_TIME + 32 * 3600);
        assertEq(oracle.consult(token1addr, 100, token0addr), 200);
    }
}
