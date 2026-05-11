// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { Test } from "forge-std/Test.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import { BetMarket } from "../src/BetMarket.sol";
import { ArenaRegistry } from "../src/ArenaRegistry.sol";
import { MockUSDC } from "../src/MockUSDC.sol";

contract BetMarketTest is Test {
    using MessageHashUtils for bytes32;

    BetMarket internal market;
    ArenaRegistry internal registry;
    MockUSDC internal usdc;

    uint256 internal constant ORACLE_PK = 0xA0BA;
    uint256 internal constant ROGUE_PK = 0xBADBAD;
    address internal oracle;
    address internal rogue;

    address internal admin = address(0xAD);
    address internal feeRecipient = address(0xFEE);
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal carol = address(0xCA401);
    address internal dave = address(0xDA7E);

    uint256 internal constant STAKE = 10 * 10 ** 6; // 10 USDC
    address internal constant AGENT_A_ADDR = address(0xA11);
    address internal constant AGENT_B_ADDR = address(0xB22);
    uint256 internal constant AGENT_A_ID = 1;
    uint256 internal constant AGENT_B_ID = 2;

    event MatchCreated(uint256 indexed matchId, uint256 indexed agentA, uint256 indexed agentB, uint64 deadline);
    event BetPlaced(uint256 indexed matchId, address indexed bettor, BetMarket.Choice choice, uint256 amount);
    event MatchResolved(uint256 indexed matchId, BetMarket.Winner winner, int256 pnlA, int256 pnlB);
    event WinningsClaimed(uint256 indexed matchId, address indexed bettor, uint256 amount);
    event AgentDecision(uint256 indexed agentId, uint8 action, uint16 sizeBp, uint64 timestamp);
    event OracleSet(address indexed previous, address indexed next);
    event FeeRecipientSet(address indexed previous, address indexed next);
    event FeesWithdrawn(address indexed to, uint256 amount);

    function setUp() public {
        oracle = vm.addr(ORACLE_PK);
        rogue = vm.addr(ROGUE_PK);

        usdc = new MockUSDC();
        registry = new ArenaRegistry(IERC20(address(usdc)), STAKE, admin);
        market = new BetMarket(IERC20(address(usdc)), registry, oracle, feeRecipient, admin);

        // seed two active agents
        usdc.mint(address(this), 2 * STAKE);
        usdc.approve(address(registry), 2 * STAKE);
        registry.registerAgent(AGENT_A_ADDR, "agent-a", address(this));
        registry.registerAgent(AGENT_B_ADDR, "agent-b", address(this));

        // fund bettors
        usdc.mint(alice, 1_000 * 10 ** 6);
        usdc.mint(bob, 1_000 * 10 ** 6);
        usdc.mint(carol, 1_000 * 10 ** 6);
        usdc.mint(dave, 1_000 * 10 ** 6);
    }

    // ───────────────────────────── helpers ─────────────────────────────

    function _bet(address bettor, uint256 matchId, BetMarket.Choice c, uint256 amount) internal {
        vm.prank(bettor);
        usdc.approve(address(market), amount);
        vm.prank(bettor);
        market.placeBet(matchId, c, amount);
    }

    function _sign(uint256 matchId, int256 pnlA, int256 pnlB, uint256 pk) internal view returns (bytes memory) {
        bytes32 digest = keccak256(abi.encode(block.chainid, address(market), matchId, pnlA, pnlB));
        bytes32 eth = digest.toEthSignedMessageHash();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, eth);
        return abi.encodePacked(r, s, v);
    }

    function _openMatch(uint256 windowSec) internal returns (uint256 matchId) {
        matchId = market.createMatch(AGENT_A_ID, AGENT_B_ID, windowSec);
    }

    function _resolveAt(uint256 matchId, int256 pnlA, int256 pnlB) internal {
        BetMarket.Match memory m = market.getMatch(matchId);
        vm.warp(uint256(m.deadline) + 1);
        bytes memory sig = _sign(matchId, pnlA, pnlB, ORACLE_PK);
        market.resolveMatch(matchId, pnlA, pnlB, sig);
    }

    // ─────────────────────────── constructor ───────────────────────────

    function test_ConstructorStoresState() public view {
        assertEq(address(market.usdc()), address(usdc));
        assertEq(address(market.registry()), address(registry));
        assertEq(market.oracle(), oracle);
        assertEq(market.feeRecipient(), feeRecipient);
        assertEq(market.owner(), admin);
        assertEq(market.nextMatchId(), 1);
        assertEq(market.FEE_BPS(), 200);
    }

    function test_ConstructorRevertsOnZeroUSDC() public {
        vm.expectRevert(BetMarket.ZeroAddress.selector);
        new BetMarket(IERC20(address(0)), registry, oracle, feeRecipient, admin);
    }

    function test_ConstructorRevertsOnZeroRegistry() public {
        vm.expectRevert(BetMarket.ZeroAddress.selector);
        new BetMarket(IERC20(address(usdc)), ArenaRegistry(address(0)), oracle, feeRecipient, admin);
    }

    function test_ConstructorRevertsOnZeroOracle() public {
        vm.expectRevert(BetMarket.ZeroAddress.selector);
        new BetMarket(IERC20(address(usdc)), registry, address(0), feeRecipient, admin);
    }

    function test_ConstructorRevertsOnZeroFeeRecipient() public {
        vm.expectRevert(BetMarket.ZeroAddress.selector);
        new BetMarket(IERC20(address(usdc)), registry, oracle, address(0), admin);
    }

    // ─────────────────────────── createMatch ───────────────────────────

    function test_CreateMatchHappyPath() public {
        uint64 expectedDeadline = uint64(block.timestamp + 600);

        vm.expectEmit(true, true, true, true, address(market));
        emit MatchCreated(1, AGENT_A_ID, AGENT_B_ID, expectedDeadline);

        uint256 id = market.createMatch(AGENT_A_ID, AGENT_B_ID, 600);
        assertEq(id, 1);
        assertEq(market.nextMatchId(), 2);

        BetMarket.Match memory m = market.getMatch(id);
        assertEq(m.agentA, AGENT_A_ID);
        assertEq(m.agentB, AGENT_B_ID);
        assertEq(m.deadline, expectedDeadline);
        assertEq(uint256(m.status), uint256(BetMarket.Status.Open));
        assertEq(uint256(m.winner), uint256(BetMarket.Winner.None));
    }

    function test_CreateMatchRevertsOnSameAgents() public {
        vm.expectRevert(BetMarket.AgentsMustDiffer.selector);
        market.createMatch(AGENT_A_ID, AGENT_A_ID, 600);
    }

    function test_CreateMatchRevertsOnWindowTooShort() public {
        vm.expectRevert(BetMarket.WindowTooShort.selector);
        market.createMatch(AGENT_A_ID, AGENT_B_ID, 59);
    }

    function test_CreateMatchRevertsOnWindowTooLong() public {
        vm.expectRevert(BetMarket.WindowTooLong.selector);
        market.createMatch(AGENT_A_ID, AGENT_B_ID, 7 days + 1);
    }

    function test_CreateMatchRevertsOnInactiveAgent() public {
        vm.expectRevert(abi.encodeWithSelector(BetMarket.AgentNotActive.selector, uint256(99)));
        market.createMatch(99, AGENT_B_ID, 600);
    }

    function test_CreateMatchPausedReverts() public {
        vm.prank(admin);
        market.pause();
        vm.expectRevert(abi.encodeWithSelector(Pausable.EnforcedPause.selector));
        market.createMatch(AGENT_A_ID, AGENT_B_ID, 600);
    }

    // ─────────────────────────── placeBet ───────────────────────────

    function test_PlaceBetHappyPath() public {
        uint256 id = _openMatch(600);

        vm.prank(alice);
        usdc.approve(address(market), 50 * 10 ** 6);

        vm.expectEmit(true, true, false, true, address(market));
        emit BetPlaced(id, alice, BetMarket.Choice.AgentA, 50 * 10 ** 6);

        vm.prank(alice);
        market.placeBet(id, BetMarket.Choice.AgentA, 50 * 10 ** 6);

        assertEq(market.stakeOnA(id, alice), 50 * 10 ** 6);
        assertEq(market.getMatch(id).totalA, 50 * 10 ** 6);
        assertEq(usdc.balanceOf(address(market)), 50 * 10 ** 6);
    }

    function test_PlaceBetAccumulatesAcrossCalls() public {
        uint256 id = _openMatch(600);
        _bet(alice, id, BetMarket.Choice.AgentA, 10 * 10 ** 6);
        _bet(alice, id, BetMarket.Choice.AgentA, 20 * 10 ** 6);
        assertEq(market.stakeOnA(id, alice), 30 * 10 ** 6);
        assertEq(market.getMatch(id).totalA, 30 * 10 ** 6);
    }

    function test_PlaceBetOnBothSidesAllowed() public {
        uint256 id = _openMatch(600);
        _bet(alice, id, BetMarket.Choice.AgentA, 10 * 10 ** 6);
        _bet(alice, id, BetMarket.Choice.AgentB, 5 * 10 ** 6);
        assertEq(market.stakeOnA(id, alice), 10 * 10 ** 6);
        assertEq(market.stakeOnB(id, alice), 5 * 10 ** 6);
    }

    function test_PlaceBetInvariantPoolEqualsSumOfStakes() public {
        uint256 id = _openMatch(600);
        _bet(alice, id, BetMarket.Choice.AgentA, 100 * 10 ** 6);
        _bet(bob, id, BetMarket.Choice.AgentA, 50 * 10 ** 6);
        _bet(carol, id, BetMarket.Choice.AgentB, 75 * 10 ** 6);
        _bet(dave, id, BetMarket.Choice.AgentB, 25 * 10 ** 6);

        BetMarket.Match memory m = market.getMatch(id);
        assertEq(m.totalA, 150 * 10 ** 6);
        assertEq(m.totalB, 100 * 10 ** 6);
        assertEq(m.totalA + m.totalB, usdc.balanceOf(address(market)));
        assertEq(
            m.totalA + m.totalB,
            market.stakeOnA(id, alice) + market.stakeOnA(id, bob) + market.stakeOnB(id, carol)
                + market.stakeOnB(id, dave)
        );
    }

    function test_PlaceBetRevertsOnUnknownMatch() public {
        vm.prank(alice);
        usdc.approve(address(market), 1);
        vm.expectRevert(abi.encodeWithSelector(BetMarket.MatchNotFound.selector, uint256(42)));
        vm.prank(alice);
        market.placeBet(42, BetMarket.Choice.AgentA, 1);
    }

    function test_PlaceBetRevertsOnZeroAmount() public {
        uint256 id = _openMatch(600);
        vm.expectRevert(BetMarket.ZeroAmount.selector);
        vm.prank(alice);
        market.placeBet(id, BetMarket.Choice.AgentA, 0);
    }

    function test_PlaceBetRevertsOnInvalidChoice() public {
        uint256 id = _openMatch(600);
        vm.prank(alice);
        usdc.approve(address(market), 1);
        vm.expectRevert(BetMarket.InvalidChoice.selector);
        vm.prank(alice);
        market.placeBet(id, BetMarket.Choice.None, 1);
    }

    function test_PlaceBetRevertsAfterDeadline() public {
        uint256 id = _openMatch(600);
        vm.warp(block.timestamp + 600);
        vm.prank(alice);
        usdc.approve(address(market), 1);
        vm.expectRevert(BetMarket.MatchExpired.selector);
        vm.prank(alice);
        market.placeBet(id, BetMarket.Choice.AgentA, 1);
    }

    function test_PlaceBetRevertsOnResolvedMatch() public {
        uint256 id = _openMatch(600);
        _bet(alice, id, BetMarket.Choice.AgentA, 10 * 10 ** 6);
        _bet(bob, id, BetMarket.Choice.AgentB, 10 * 10 ** 6);
        _resolveAt(id, int256(100), int256(50));

        vm.prank(carol);
        usdc.approve(address(market), 1);
        vm.expectRevert(BetMarket.MatchAlreadyResolved.selector);
        vm.prank(carol);
        market.placeBet(id, BetMarket.Choice.AgentA, 1);
    }

    function test_PlaceBetPausedReverts() public {
        uint256 id = _openMatch(600);
        vm.prank(admin);
        market.pause();
        vm.prank(alice);
        usdc.approve(address(market), 1);
        vm.expectRevert(abi.encodeWithSelector(Pausable.EnforcedPause.selector));
        vm.prank(alice);
        market.placeBet(id, BetMarket.Choice.AgentA, 1);
    }

    // ─────────────────────────── resolveMatch ───────────────────────────

    function test_ResolveAWins() public {
        uint256 id = _openMatch(600);
        _bet(alice, id, BetMarket.Choice.AgentA, 100 * 10 ** 6);
        _bet(bob, id, BetMarket.Choice.AgentB, 100 * 10 ** 6);

        BetMarket.Match memory m = market.getMatch(id);
        vm.warp(uint256(m.deadline) + 1);

        bytes memory sig = _sign(id, int256(500), int256(-100), ORACLE_PK);

        vm.expectEmit(true, false, false, true, address(market));
        emit MatchResolved(id, BetMarket.Winner.AgentA, int256(500), int256(-100));
        market.resolveMatch(id, int256(500), int256(-100), sig);

        BetMarket.Match memory after_ = market.getMatch(id);
        assertEq(uint256(after_.status), uint256(BetMarket.Status.Resolved));
        assertEq(uint256(after_.winner), uint256(BetMarket.Winner.AgentA));
        assertEq(market.accruedFees(), (200 * 10 ** 6) * 200 / 10_000); // 2% of 200 USDC
    }

    function test_ResolveBWins() public {
        uint256 id = _openMatch(600);
        _bet(alice, id, BetMarket.Choice.AgentA, 100 * 10 ** 6);
        _bet(bob, id, BetMarket.Choice.AgentB, 100 * 10 ** 6);
        _resolveAt(id, int256(-50), int256(200));
        assertEq(uint256(market.getMatch(id).winner), uint256(BetMarket.Winner.AgentB));
    }

    function test_ResolveTie() public {
        uint256 id = _openMatch(600);
        _bet(alice, id, BetMarket.Choice.AgentA, 50 * 10 ** 6);
        _bet(bob, id, BetMarket.Choice.AgentB, 50 * 10 ** 6);
        _resolveAt(id, int256(123), int256(123));
        assertEq(uint256(market.getMatch(id).winner), uint256(BetMarket.Winner.Tie));
        assertEq(market.accruedFees(), 0); // no fee on tie
    }

    function test_ResolveRevertsOnBadSignature() public {
        uint256 id = _openMatch(600);
        BetMarket.Match memory m = market.getMatch(id);
        vm.warp(uint256(m.deadline) + 1);
        bytes memory sig = _sign(id, int256(100), int256(50), ROGUE_PK);
        vm.expectRevert(BetMarket.BadSignature.selector);
        market.resolveMatch(id, int256(100), int256(50), sig);
    }

    function test_ResolveRevertsOnMutatedPayload() public {
        uint256 id = _openMatch(600);
        BetMarket.Match memory m = market.getMatch(id);
        vm.warp(uint256(m.deadline) + 1);
        // sign for pnlA=100 but submit pnlA=101 → digest mismatch
        bytes memory sig = _sign(id, int256(100), int256(50), ORACLE_PK);
        vm.expectRevert(BetMarket.BadSignature.selector);
        market.resolveMatch(id, int256(101), int256(50), sig);
    }

    function test_ResolveRevertsBeforeDeadline() public {
        uint256 id = _openMatch(600);
        bytes memory sig = _sign(id, int256(100), int256(50), ORACLE_PK);
        vm.expectRevert(BetMarket.MatchNotExpired.selector);
        market.resolveMatch(id, int256(100), int256(50), sig);
    }

    function test_ResolveRevertsOnUnknownMatch() public {
        bytes memory sig = _sign(999, int256(0), int256(0), ORACLE_PK);
        vm.expectRevert(abi.encodeWithSelector(BetMarket.MatchNotFound.selector, uint256(999)));
        market.resolveMatch(999, int256(0), int256(0), sig);
    }

    function test_ResolveTwiceReverts() public {
        uint256 id = _openMatch(600);
        _resolveAt(id, int256(10), int256(5));
        bytes memory sig = _sign(id, int256(10), int256(5), ORACLE_PK);
        vm.expectRevert(BetMarket.MatchAlreadyResolved.selector);
        market.resolveMatch(id, int256(10), int256(5), sig);
    }

    function test_ResolveZeroPoolNoFee() public {
        uint256 id = _openMatch(600);
        _resolveAt(id, int256(100), int256(50));
        assertEq(market.accruedFees(), 0);
    }

    function test_ResolveOneSidedPoolNoFee() public {
        uint256 id = _openMatch(600);
        _bet(alice, id, BetMarket.Choice.AgentA, 100 * 10 ** 6);
        _resolveAt(id, int256(100), int256(50)); // A wins, only side
        assertEq(market.accruedFees(), 0); // one-sided → no fee
    }

    // ─────────────────────────── claimWinnings ───────────────────────────

    function test_ClaimPariMutuelMath() public {
        // alice 100 A, bob 100 A, carol 200 B → totalA=200, totalB=200
        // A wins → gross 400, fee 8, netPool 392
        // alice payout = 100/200 * 392 = 196
        // bob payout = 100/200 * 392 = 196
        // carol payout = 0
        // accruedFees = 8; sum payouts + fee = 400 ✓
        uint256 id = _openMatch(600);
        _bet(alice, id, BetMarket.Choice.AgentA, 100 * 10 ** 6);
        _bet(bob, id, BetMarket.Choice.AgentA, 100 * 10 ** 6);
        _bet(carol, id, BetMarket.Choice.AgentB, 200 * 10 ** 6);
        _resolveAt(id, int256(100), int256(-100));

        assertEq(market.payoutOf(id, alice), 196 * 10 ** 6);
        assertEq(market.payoutOf(id, bob), 196 * 10 ** 6);
        assertEq(market.payoutOf(id, carol), 0);

        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.expectEmit(true, true, false, true, address(market));
        emit WinningsClaimed(id, alice, 196 * 10 ** 6);
        vm.prank(alice);
        market.claimWinnings(id);
        assertEq(usdc.balanceOf(alice) - aliceBefore, 196 * 10 ** 6);

        vm.prank(bob);
        market.claimWinnings(id);

        uint256 marketBal = usdc.balanceOf(address(market));
        assertEq(marketBal, market.accruedFees());
        assertEq(marketBal, 8 * 10 ** 6);
    }

    function test_ClaimTieRefundsBothSides() public {
        uint256 id = _openMatch(600);
        _bet(alice, id, BetMarket.Choice.AgentA, 100 * 10 ** 6);
        _bet(bob, id, BetMarket.Choice.AgentB, 100 * 10 ** 6);
        _resolveAt(id, int256(42), int256(42));

        assertEq(market.payoutOf(id, alice), 100 * 10 ** 6);
        assertEq(market.payoutOf(id, bob), 100 * 10 ** 6);

        vm.prank(alice);
        market.claimWinnings(id);
        vm.prank(bob);
        market.claimWinnings(id);

        assertEq(usdc.balanceOf(address(market)), 0);
        assertEq(market.accruedFees(), 0);
    }

    function test_ClaimOneSidedWinnerRefunds() public {
        uint256 id = _openMatch(600);
        _bet(alice, id, BetMarket.Choice.AgentA, 100 * 10 ** 6);
        _resolveAt(id, int256(100), int256(50));

        assertEq(market.payoutOf(id, alice), 100 * 10 ** 6);
        vm.prank(alice);
        market.claimWinnings(id);
        assertEq(usdc.balanceOf(address(market)), 0);
    }

    function test_ClaimBettorOnBothSidesGetsWinnerOnlyPayout() public {
        // alice stakes both sides: 60 on A, 40 on B; bob stakes 100 on B
        // totalA=60, totalB=140, gross=200, fee=4, netPool=196
        // A wins: alice payout = 60/60 * 196 = 196 (her sB is lost)
        uint256 id = _openMatch(600);
        _bet(alice, id, BetMarket.Choice.AgentA, 60 * 10 ** 6);
        _bet(alice, id, BetMarket.Choice.AgentB, 40 * 10 ** 6);
        _bet(bob, id, BetMarket.Choice.AgentB, 100 * 10 ** 6);
        _resolveAt(id, int256(50), int256(-50));

        assertEq(market.payoutOf(id, alice), 196 * 10 ** 6);
        assertEq(market.payoutOf(id, bob), 0);
    }

    function test_ClaimRevertsBeforeResolve() public {
        uint256 id = _openMatch(600);
        _bet(alice, id, BetMarket.Choice.AgentA, 10 * 10 ** 6);
        vm.expectRevert(BetMarket.MatchNotResolved.selector);
        vm.prank(alice);
        market.claimWinnings(id);
    }

    function test_ClaimRevertsOnDoubleClaim() public {
        uint256 id = _openMatch(600);
        _bet(alice, id, BetMarket.Choice.AgentA, 100 * 10 ** 6);
        _bet(bob, id, BetMarket.Choice.AgentB, 100 * 10 ** 6);
        _resolveAt(id, int256(100), int256(-100));
        vm.prank(alice);
        market.claimWinnings(id);
        vm.expectRevert(BetMarket.AlreadyClaimed.selector);
        vm.prank(alice);
        market.claimWinnings(id);
    }

    function test_ClaimRevertsWithoutStake() public {
        uint256 id = _openMatch(600);
        _bet(alice, id, BetMarket.Choice.AgentA, 100 * 10 ** 6);
        _bet(bob, id, BetMarket.Choice.AgentB, 100 * 10 ** 6);
        _resolveAt(id, int256(100), int256(-100));
        vm.expectRevert(BetMarket.NothingToClaim.selector);
        vm.prank(carol); // never bet
        market.claimWinnings(id);
    }

    function test_ClaimRevertsForLoserOnlyStake() public {
        uint256 id = _openMatch(600);
        _bet(alice, id, BetMarket.Choice.AgentA, 100 * 10 ** 6);
        _bet(bob, id, BetMarket.Choice.AgentB, 100 * 10 ** 6);
        _resolveAt(id, int256(100), int256(-100));
        vm.expectRevert(BetMarket.NothingToClaim.selector);
        vm.prank(bob);
        market.claimWinnings(id);
    }

    function test_ClaimRevertsOnUnknownMatch() public {
        vm.expectRevert(abi.encodeWithSelector(BetMarket.MatchNotFound.selector, uint256(123)));
        market.claimWinnings(123);
    }

    function test_ClaimAllowedWhilePaused() public {
        uint256 id = _openMatch(600);
        _bet(alice, id, BetMarket.Choice.AgentA, 100 * 10 ** 6);
        _bet(bob, id, BetMarket.Choice.AgentB, 100 * 10 ** 6);
        _resolveAt(id, int256(100), int256(-100));

        vm.prank(admin);
        market.pause();

        vm.prank(alice);
        market.claimWinnings(id); // intentional: claim works while paused
    }

    // ─────────────────────────── recordDecision ───────────────────────────

    function test_RecordDecisionEmits() public {
        vm.expectEmit(true, false, false, true, address(market));
        emit AgentDecision(1, 1, 5000, uint64(block.timestamp));
        vm.prank(oracle);
        market.recordDecision(1, 1, 5000);
    }

    function test_RecordDecisionRevertsForNonOracle() public {
        vm.expectRevert(BetMarket.NotOracle.selector);
        vm.prank(alice);
        market.recordDecision(1, 1, 5000);
    }

    function test_RecordDecisionRevertsWhenPaused() public {
        vm.prank(admin);
        market.pause();
        vm.expectRevert(abi.encodeWithSelector(Pausable.EnforcedPause.selector));
        vm.prank(oracle);
        market.recordDecision(1, 1, 5000);
    }

    // ─────────────────────────── admin: setters ───────────────────────────

    function test_SetOracle() public {
        address newOracle = address(0xC0FFEE);
        vm.expectEmit(true, true, false, true, address(market));
        emit OracleSet(oracle, newOracle);
        vm.prank(admin);
        market.setOracle(newOracle);
        assertEq(market.oracle(), newOracle);
    }

    function test_SetOracleRevertsForNonOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        market.setOracle(address(0x1));
    }

    function test_SetOracleRevertsOnZeroAddress() public {
        vm.expectRevert(BetMarket.ZeroAddress.selector);
        vm.prank(admin);
        market.setOracle(address(0));
    }

    function test_SetFeeRecipient() public {
        address newR = address(0xFEE2);
        vm.expectEmit(true, true, false, true, address(market));
        emit FeeRecipientSet(feeRecipient, newR);
        vm.prank(admin);
        market.setFeeRecipient(newR);
        assertEq(market.feeRecipient(), newR);
    }

    function test_SetFeeRecipientRevertsForNonOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        market.setFeeRecipient(address(0x1));
    }

    function test_SetFeeRecipientRevertsOnZeroAddress() public {
        vm.expectRevert(BetMarket.ZeroAddress.selector);
        vm.prank(admin);
        market.setFeeRecipient(address(0));
    }

    // ─────────────────────────── admin: pause ───────────────────────────

    function test_PauseUnpauseOwnerOnly() public {
        vm.prank(admin);
        market.pause();
        assertTrue(market.paused());
        vm.prank(admin);
        market.unpause();
        assertFalse(market.paused());
    }

    function test_PauseRevertsForNonOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        market.pause();
    }

    function test_UnpauseRevertsForNonOwner() public {
        vm.prank(admin);
        market.pause();
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        market.unpause();
    }

    // ─────────────────────────── admin: withdrawFees ───────────────────────────

    function test_WithdrawFees() public {
        uint256 id = _openMatch(600);
        _bet(alice, id, BetMarket.Choice.AgentA, 100 * 10 ** 6);
        _bet(bob, id, BetMarket.Choice.AgentB, 100 * 10 ** 6);
        _resolveAt(id, int256(100), int256(-100));

        uint256 fee = market.accruedFees();
        assertEq(fee, 4 * 10 ** 6);

        vm.expectEmit(true, false, false, true, address(market));
        emit FeesWithdrawn(feeRecipient, fee);
        vm.prank(admin);
        market.withdrawFees(feeRecipient);
        assertEq(usdc.balanceOf(feeRecipient), fee);
        assertEq(market.accruedFees(), 0);
    }

    function test_WithdrawFeesRevertsForNonOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        market.withdrawFees(alice);
    }

    function test_WithdrawFeesRevertsOnZeroAddress() public {
        vm.expectRevert(BetMarket.ZeroAddress.selector);
        vm.prank(admin);
        market.withdrawFees(address(0));
    }

    function test_WithdrawFeesRevertsWhenEmpty() public {
        vm.expectRevert(BetMarket.NothingToClaim.selector);
        vm.prank(admin);
        market.withdrawFees(feeRecipient);
    }

    // ───────────────────────────── fuzz ─────────────────────────────

    function testFuzz_ClaimPayoutInvariant(uint96 a1, uint96 a2, uint96 b1) public {
        // Bound stakes to keep balance/overflow comfortable.
        a1 = uint96(bound(a1, 1, 100 * 10 ** 6));
        a2 = uint96(bound(a2, 1, 100 * 10 ** 6));
        b1 = uint96(bound(b1, 1, 100 * 10 ** 6));

        uint256 id = _openMatch(600);
        _bet(alice, id, BetMarket.Choice.AgentA, a1);
        _bet(bob, id, BetMarket.Choice.AgentA, a2);
        _bet(carol, id, BetMarket.Choice.AgentB, b1);
        _resolveAt(id, int256(1), int256(0));

        uint256 gross = uint256(a1) + uint256(a2) + uint256(b1);
        uint256 expectedFee = (gross * 200) / 10_000;
        assertEq(market.accruedFees(), expectedFee);

        uint256 payAlice = market.payoutOf(id, alice);
        uint256 payBob = market.payoutOf(id, bob);
        assertEq(market.payoutOf(id, carol), 0);

        // Sum of winner payouts + fee ≤ gross pool (possible 1-wei rounding loss is left in contract).
        assertLe(payAlice + payBob + expectedFee, gross);
        assertGe(payAlice + payBob + expectedFee + 2, gross); // rounding slack ≤ 2 wei across two winners
    }
}
