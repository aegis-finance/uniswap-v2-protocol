// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2ERC20.sol";

/// @dev Forge port of v2-core/test/UniswapV2ERC20.spec.ts
contract UniswapV2ERC20Test is Test {
    uint256 constant TOTAL_SUPPLY = 10_000e18;
    uint256 constant TEST_AMOUNT = 10e18;

    // Artifact path: out/test/ERC20.sol/ERC20.json  (src/core/test/ERC20.sol — extends UniswapV2ERC20)
    IUniswapV2ERC20 token;

    uint256 walletKey = 0xA11CE;
    address wallet;
    address other;

    function setUp() public {
        wallet = vm.addr(walletKey);
        other  = makeAddr("other");

        // Deploy core LP token wrapper; test contract is the minter
        address t = deployCode("src/core/test/ERC20.sol:ERC20", abi.encode(TOTAL_SUPPLY));
        token = IUniswapV2ERC20(t);

        // Mirror the original fixture: wallet owns all supply
        token.transfer(wallet, TOTAL_SUPPLY);
    }

    // -------------------------------------------------------------------------
    // name / symbol / decimals / totalSupply / balanceOf / DOMAIN_SEPARATOR / PERMIT_TYPEHASH
    // -------------------------------------------------------------------------
    function test_metadata() public view {
        assertEq(token.name(),     "Uniswap V2");
        assertEq(token.symbol(),   "UNI-V2");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(),       TOTAL_SUPPLY);
        assertEq(token.balanceOf(wallet),   TOTAL_SUPPLY);

        bytes32 expectedDomainSep = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("Uniswap V2")),
                keccak256(bytes("1")),
                block.chainid,
                address(token)
            )
        );
        assertEq(token.DOMAIN_SEPARATOR(), expectedDomainSep);

        assertEq(
            token.PERMIT_TYPEHASH(),
            keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)")
        );
    }

    // -------------------------------------------------------------------------
    // approve
    // -------------------------------------------------------------------------
    function test_approve() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit IUniswapV2ERC20.Approval(wallet, other, TEST_AMOUNT);

        vm.prank(wallet);
        token.approve(other, TEST_AMOUNT);

        assertEq(token.allowance(wallet, other), TEST_AMOUNT);
    }

    // -------------------------------------------------------------------------
    // transfer
    // -------------------------------------------------------------------------
    function test_transfer() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit IUniswapV2ERC20.Transfer(wallet, other, TEST_AMOUNT);

        vm.prank(wallet);
        token.transfer(other, TEST_AMOUNT);

        assertEq(token.balanceOf(wallet), TOTAL_SUPPLY - TEST_AMOUNT);
        assertEq(token.balanceOf(other),  TEST_AMOUNT);
    }

    function test_transfer_revertInsufficientBalance() public {
        // transferring more than balance
        vm.prank(wallet);
        vm.expectRevert();
        token.transfer(other, TOTAL_SUPPLY + 1);

        // `other` has no tokens
        vm.prank(other);
        vm.expectRevert();
        token.transfer(wallet, 1);
    }

    // -------------------------------------------------------------------------
    // transferFrom
    // -------------------------------------------------------------------------
    function test_transferFrom() public {
        vm.prank(wallet);
        token.approve(other, TEST_AMOUNT);

        vm.expectEmit(true, true, false, true, address(token));
        emit IUniswapV2ERC20.Transfer(wallet, other, TEST_AMOUNT);

        vm.prank(other);
        token.transferFrom(wallet, other, TEST_AMOUNT);

        assertEq(token.allowance(wallet, other),  0);
        assertEq(token.balanceOf(wallet),          TOTAL_SUPPLY - TEST_AMOUNT);
        assertEq(token.balanceOf(other),            TEST_AMOUNT);
    }

    function test_transferFrom_maxAllowanceNotDecremented() public {
        // type(uint256).max == uint(-1) in Solidity 0.5.x → allowance never decremented
        vm.prank(wallet);
        token.approve(other, type(uint256).max);

        vm.prank(other);
        token.transferFrom(wallet, other, TEST_AMOUNT);

        assertEq(token.allowance(wallet, other), type(uint256).max);
        assertEq(token.balanceOf(wallet), TOTAL_SUPPLY - TEST_AMOUNT);
        assertEq(token.balanceOf(other),  TEST_AMOUNT);
    }

    // -------------------------------------------------------------------------
    // permit (EIP-2612)
    // -------------------------------------------------------------------------
    function test_permit() public {
        uint256 nonce    = token.nonces(wallet);
        uint256 deadline = type(uint256).max;

        bytes32 structHash = keccak256(
            abi.encode(
                token.PERMIT_TYPEHASH(),
                wallet,
                other,
                TEST_AMOUNT,
                nonce,
                deadline
            )
        );
        bytes32 digest = keccak256(
            abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash)
        );

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(walletKey, digest);

        vm.expectEmit(true, true, false, true, address(token));
        emit IUniswapV2ERC20.Approval(wallet, other, TEST_AMOUNT);

        token.permit(wallet, other, TEST_AMOUNT, deadline, v, r, s);

        assertEq(token.allowance(wallet, other), TEST_AMOUNT);
        assertEq(token.nonces(wallet), 1);
    }

    // -------------------------------------------------------------------------
    // fuzz: transfer never violates balance invariant
    // -------------------------------------------------------------------------
    function testFuzz_transfer(uint256 amount) public {
        vm.assume(amount <= TOTAL_SUPPLY);
        vm.prank(wallet);
        token.transfer(other, amount);
        assertEq(token.balanceOf(wallet), TOTAL_SUPPLY - amount);
        assertEq(token.balanceOf(other),  amount);
    }
}
