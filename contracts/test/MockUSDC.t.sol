// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { Test } from "forge-std/Test.sol";

import { MockUSDC } from "../src/MockUSDC.sol";

contract MockUSDCTest is Test {
    MockUSDC internal usdc;

    address internal alice = address(0xA11CE);

    function setUp() public {
        usdc = new MockUSDC();
    }

    function test_DecimalsIsSix() public view {
        assertEq(usdc.decimals(), 6);
    }

    function test_MetadataMatchesUSDC() public view {
        assertEq(usdc.name(), "Mock USDC");
        assertEq(usdc.symbol(), "USDC");
    }

    function test_OpenMint() public {
        usdc.mint(alice, 1_000_000); // 1 USDC
        assertEq(usdc.balanceOf(alice), 1_000_000);
        assertEq(usdc.totalSupply(), 1_000_000);
    }

    function test_AnyoneCanMintToAnyAddress() public {
        vm.prank(alice);
        usdc.mint(address(this), 500_000);
        assertEq(usdc.balanceOf(address(this)), 500_000);
    }
}
