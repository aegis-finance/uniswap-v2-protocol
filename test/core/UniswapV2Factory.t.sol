// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";

/// @dev Forge port of v2-core/test/UniswapV2Factory.spec.ts
contract UniswapV2FactoryTest is Test {
    address constant TOKEN_A = 0x1000000000000000000000000000000000000000;
    address constant TOKEN_B = 0x2000000000000000000000000000000000000000;

    IUniswapV2Factory factory;
    address other;

    function setUp() public {
        other = makeAddr("other");
        factory = IUniswapV2Factory(
            deployCode("UniswapV2Factory.sol:UniswapV2Factory", abi.encode(address(this)))
        );
    }

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    /// @dev Compute the CREATE2 address of the pair (mirrors UniswapV2Library).
    function _pairAddress(address tokenA, address tokenB) internal view returns (address) {
        (address t0, address t1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        bytes32 initCodeHash = keccak256(vm.getCode("UniswapV2Pair.sol:UniswapV2Pair"));
        return address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            hex"ff",
                            address(factory),
                            keccak256(abi.encodePacked(t0, t1)),
                            initCodeHash
                        )
                    )
                )
            )
        );
    }

    // -------------------------------------------------------------------------
    // Initial state
    // -------------------------------------------------------------------------
    function test_initialState() public view {
        assertEq(factory.feeTo(),         address(0));
        assertEq(factory.feeToSetter(),   address(this));
        assertEq(factory.allPairsLength(), 0);
    }

    // -------------------------------------------------------------------------
    // createPair
    // -------------------------------------------------------------------------
    function _assertPairCreated(address tokenA, address tokenB) internal {
        address expectedPair = _pairAddress(tokenA, tokenB);

        vm.expectEmit(true, true, false, true, address(factory));
        emit IUniswapV2Factory.PairCreated(TOKEN_A, TOKEN_B, expectedPair, 1);

        factory.createPair(tokenA, tokenB);

        // Bidirectional lookup
        assertEq(factory.getPair(TOKEN_A, TOKEN_B), expectedPair);
        assertEq(factory.getPair(TOKEN_B, TOKEN_A), expectedPair);
        assertEq(factory.allPairs(0),               expectedPair);
        assertEq(factory.allPairsLength(),           1);

        // Pair internal state
        IUniswapV2Pair pair = IUniswapV2Pair(expectedPair);
        assertEq(pair.factory(), address(factory));
        assertEq(pair.token0(),  TOKEN_A);
        assertEq(pair.token1(),  TOKEN_B);
    }

    function test_createPair() public {
        _assertPairCreated(TOKEN_A, TOKEN_B);
    }

    function test_createPair_reverse() public {
        _assertPairCreated(TOKEN_B, TOKEN_A);
    }

    function test_createPair_revertDuplicate() public {
        factory.createPair(TOKEN_A, TOKEN_B);

        vm.expectRevert();
        factory.createPair(TOKEN_A, TOKEN_B);

        vm.expectRevert();
        factory.createPair(TOKEN_B, TOKEN_A);
    }

    function test_createPair_revertIdenticalAddresses() public {
        vm.expectRevert();
        factory.createPair(TOKEN_A, TOKEN_A);
    }

    function test_createPair_revertZeroAddress() public {
        vm.expectRevert();
        factory.createPair(address(0), TOKEN_B);
    }

    // -------------------------------------------------------------------------
    // setFeeTo
    // -------------------------------------------------------------------------
    function test_setFeeTo_onlyFeeToSetter() public {
        vm.prank(other);
        vm.expectRevert();
        factory.setFeeTo(other);

        factory.setFeeTo(address(this));
        assertEq(factory.feeTo(), address(this));
    }

    // -------------------------------------------------------------------------
    // setFeeToSetter
    // -------------------------------------------------------------------------
    function test_setFeeToSetter_transfersRole() public {
        // Non-setter cannot call
        vm.prank(other);
        vm.expectRevert();
        factory.setFeeToSetter(other);

        // Original setter transfers role to `other`
        factory.setFeeToSetter(other);
        assertEq(factory.feeToSetter(), other);

        // Old setter no longer authorised
        vm.expectRevert();
        factory.setFeeToSetter(address(this));
    }
}
