// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { Test } from "forge-std/Test.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

import { ERC8004ReputationAdapter } from "../src/ERC8004ReputationAdapter.sol";
import { IERC8004Reputation } from "../src/interfaces/IERC8004Reputation.sol";

/// @dev Mock that emulates the relevant slice of ERC-8004 Reputation Registry behaviour:
///      enforces "submitter MUST NOT be agent owner" and emits a FeedbackGiven event whose
///      indexed `clientAddress` mirrors the real registry's filtering surface.
contract MockERC8004Reputation is IERC8004Reputation {
    mapping(uint256 agentId => address) public agentOwnerOf;

    event FeedbackGiven(
        uint256 indexed agentId,
        address indexed clientAddress,
        int128 feedbackValue,
        uint8 authType,
        bytes32 tag1,
        bytes32 tag2
    );

    error SubmitterIsAgentOwner();

    function setAgentOwner(uint256 agentId, address owner) external {
        agentOwnerOf[agentId] = owner;
    }

    function giveFeedback(uint256 agentId, int128 feedbackValue, uint8 authType, bytes32 tag1, bytes32 tag2) external {
        if (msg.sender == agentOwnerOf[agentId]) revert SubmitterIsAgentOwner();
        emit FeedbackGiven(agentId, msg.sender, feedbackValue, authType, tag1, tag2);
    }
}

contract ERC8004ReputationAdapterTest is Test {
    ERC8004ReputationAdapter internal adapter;
    MockERC8004Reputation internal reputation;

    address internal admin = address(0xAD);
    address internal judge = address(0x1AD6E); // "JUDGE"
    address internal stranger = address(0xBAD);
    address internal agentOwner = address(0xA9E47);

    event JudgeSet(address indexed previous, address indexed next);
    event EloMirrored(uint256 indexed agentId, int128 elo);
    event FeedbackGiven(
        uint256 indexed agentId,
        address indexed clientAddress,
        int128 feedbackValue,
        uint8 authType,
        bytes32 tag1,
        bytes32 tag2
    );

    function setUp() public {
        reputation = new MockERC8004Reputation();
        adapter = new ERC8004ReputationAdapter(IERC8004Reputation(address(reputation)), judge, admin);
    }

    // ─────────────────────────── constructor ───────────────────────────

    function test_ConstructorStoresState() public view {
        assertEq(address(adapter.reputation()), address(reputation));
        assertEq(adapter.judge(), judge);
        assertEq(adapter.owner(), admin);
        assertEq(adapter.TAG1(), bytes32("MAPA-Elo"));
        assertEq(adapter.TAG2(), bytes32("v1"));
        assertEq(adapter.AUTH_TYPE(), 0);
    }

    function test_ConstructorRevertsOnZeroReputation() public {
        vm.expectRevert(ERC8004ReputationAdapter.ZeroAddress.selector);
        new ERC8004ReputationAdapter(IERC8004Reputation(address(0)), judge, admin);
    }

    function test_ConstructorRevertsOnZeroJudge() public {
        vm.expectRevert(ERC8004ReputationAdapter.ZeroAddress.selector);
        new ERC8004ReputationAdapter(IERC8004Reputation(address(reputation)), address(0), admin);
    }

    // ─────────────────────────── mirrorElo ───────────────────────────

    function test_MirrorEloForwardsToReputationAndEmits() public {
        uint256 agentId = 1;
        int128 elo = 1700;
        reputation.setAgentOwner(agentId, agentOwner);

        // Two events expected: registry FeedbackGiven with clientAddress = adapter, then adapter EloMirrored.
        vm.expectEmit(true, true, false, true, address(reputation));
        emit FeedbackGiven(agentId, address(adapter), elo, 0, bytes32("MAPA-Elo"), bytes32("v1"));
        vm.expectEmit(true, false, false, true, address(adapter));
        emit EloMirrored(agentId, elo);

        vm.prank(judge);
        adapter.mirrorElo(agentId, elo);
    }

    function test_MirrorEloRevertsForNonJudge() public {
        reputation.setAgentOwner(1, agentOwner);
        vm.expectRevert(ERC8004ReputationAdapter.NotJudge.selector);
        vm.prank(stranger);
        adapter.mirrorElo(1, 1500);
    }

    function test_MirrorEloHandlesNegativeFeedback() public {
        // int128 supports negative scores — verify forward unchanged.
        reputation.setAgentOwner(2, agentOwner);

        vm.expectEmit(true, true, false, true, address(reputation));
        emit FeedbackGiven(2, address(adapter), int128(-300), 0, bytes32("MAPA-Elo"), bytes32("v1"));

        vm.prank(judge);
        adapter.mirrorElo(2, int128(-300));
    }

    /// @notice EIP-8004 verbatim: "submitter MUST NOT be the agent owner". If the adapter is ever
    ///         (mis)configured as the agent owner in the Identity Registry, the mock — like the
    ///         real registry — must reject the giveFeedback call. We test that the adapter
    ///         propagates this revert instead of silently succeeding.
    function test_RevertsIfAdapterIsAgentOwner() public {
        uint256 agentId = 42;
        reputation.setAgentOwner(agentId, address(adapter));

        vm.expectRevert(MockERC8004Reputation.SubmitterIsAgentOwner.selector);
        vm.prank(judge);
        adapter.mirrorElo(agentId, 1800);
    }

    function test_MirrorEloUnaffectedByDeployerBeingAgentOwner() public {
        // The agent owner in Identity Registry is the deployer EOA — a different EOA from both
        // the adapter and JUDGE. Mirror should succeed because the submitter (adapter) ≠ owner.
        uint256 agentId = 7;
        reputation.setAgentOwner(agentId, address(0xDEEDEE)); // some "deployer" EOA, ≠ adapter, ≠ JUDGE

        vm.prank(judge);
        adapter.mirrorElo(agentId, 1500);
    }

    // ─────────────────────────── setJudge ───────────────────────────

    function test_SetJudgeByOwnerEmits() public {
        address newJudge = address(0xC0FFEE);
        vm.expectEmit(true, true, false, true, address(adapter));
        emit JudgeSet(judge, newJudge);
        vm.prank(admin);
        adapter.setJudge(newJudge);
        assertEq(adapter.judge(), newJudge);
    }

    function test_SetJudgeRevertsOnZeroAddress() public {
        vm.expectRevert(ERC8004ReputationAdapter.ZeroAddress.selector);
        vm.prank(admin);
        adapter.setJudge(address(0));
    }

    function test_SetJudgeRevertsForNonOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vm.prank(stranger);
        adapter.setJudge(stranger);
    }

    function test_SetJudgeRotatesAuthority() public {
        address newJudge = address(0xC0FFEE);
        vm.prank(admin);
        adapter.setJudge(newJudge);

        // old judge no longer accepted
        vm.expectRevert(ERC8004ReputationAdapter.NotJudge.selector);
        vm.prank(judge);
        adapter.mirrorElo(1, 1500);

        // new judge accepted
        reputation.setAgentOwner(1, agentOwner);
        vm.prank(newJudge);
        adapter.mirrorElo(1, 1500);
    }
}
