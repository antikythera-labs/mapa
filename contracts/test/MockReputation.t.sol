// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { Test } from "forge-std/Test.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

import { IReputation } from "../src/interfaces/IReputation.sol";
import { MockReputation } from "../src/MockReputation.sol";

contract MockReputationTest is Test {
    MockReputation internal rep;

    address internal owner = address(0xA11CE);
    address internal stranger = address(0xB0B);

    event EloUpdated(uint256 indexed agentId, uint256 oldElo, uint256 newElo);

    function setUp() public {
        rep = new MockReputation(owner);
    }

    function test_ConstructorSetsOwner() public view {
        assertEq(rep.owner(), owner);
    }

    function test_GetEloDefaultsToZero() public view {
        assertEq(rep.getElo(1), 0);
        assertEq(rep.getElo(type(uint256).max), 0);
    }

    function test_SetEloUpdatesAndEmits() public {
        vm.expectEmit(true, false, false, true, address(rep));
        emit EloUpdated(42, 0, 1700);

        vm.prank(owner);
        rep.setElo(42, 1700);

        assertEq(rep.getElo(42), 1700);
    }

    function test_SetEloOverwritesPreviousValue() public {
        vm.startPrank(owner);
        rep.setElo(1, 1500);
        rep.setElo(1, 1800);
        vm.stopPrank();

        assertEq(rep.getElo(1), 1800);
    }

    function test_SetEloRevertsForNonOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vm.prank(stranger);
        rep.setElo(1, 1500);
    }

    function test_SetEloBatchUpdatesAll() public {
        uint256[] memory ids = new uint256[](3);
        uint256[] memory elos = new uint256[](3);
        ids[0] = 1;
        ids[1] = 2;
        ids[2] = 3;
        elos[0] = 1500;
        elos[1] = 1700;
        elos[2] = 1900;

        vm.prank(owner);
        rep.setEloBatch(ids, elos);

        assertEq(rep.getElo(1), 1500);
        assertEq(rep.getElo(2), 1700);
        assertEq(rep.getElo(3), 1900);
    }

    function test_SetEloBatchEmitsPerEntry() public {
        uint256[] memory ids = new uint256[](2);
        uint256[] memory elos = new uint256[](2);
        ids[0] = 7;
        ids[1] = 8;
        elos[0] = 1600;
        elos[1] = 1800;

        vm.expectEmit(true, false, false, true, address(rep));
        emit EloUpdated(7, 0, 1600);
        vm.expectEmit(true, false, false, true, address(rep));
        emit EloUpdated(8, 0, 1800);

        vm.prank(owner);
        rep.setEloBatch(ids, elos);
    }

    function test_SetEloBatchRevertsOnLengthMismatch() public {
        uint256[] memory ids = new uint256[](2);
        uint256[] memory elos = new uint256[](1);
        ids[0] = 1;
        ids[1] = 2;
        elos[0] = 1500;

        vm.expectRevert(MockReputation.LengthMismatch.selector);
        vm.prank(owner);
        rep.setEloBatch(ids, elos);
    }

    function test_SetEloBatchRevertsForNonOwner() public {
        uint256[] memory ids = new uint256[](1);
        uint256[] memory elos = new uint256[](1);
        ids[0] = 1;
        elos[0] = 1500;

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vm.prank(stranger);
        rep.setEloBatch(ids, elos);
    }

    function test_OwnershipTransfer() public {
        vm.prank(owner);
        rep.transferOwnership(stranger);

        vm.prank(stranger);
        rep.setElo(1, 1234);

        assertEq(rep.getElo(1), 1234);
    }

    function test_ReadsThroughInterface() public {
        vm.prank(owner);
        rep.setElo(99, 2100);

        IReputation viaInterface = IReputation(address(rep));
        assertEq(viaInterface.getElo(99), 2100);
    }

    function testFuzz_SetEloRoundTrip(uint256 agentId, uint256 elo) public {
        vm.prank(owner);
        rep.setElo(agentId, elo);
        assertEq(rep.getElo(agentId), elo);
    }
}
