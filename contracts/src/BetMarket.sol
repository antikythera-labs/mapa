// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import { ArenaRegistry } from "./ArenaRegistry.sol";

/// @title BetMarket
/// @notice Pari-mutuel betting market on agent-vs-agent PnL matches.
///         Winners split the pool minus a 2% fee, prorated to their stake. Tie or one-sided
///         pool → full refund (no fee). Resolution requires an off-chain ECDSA signature
///         from the oracle EOA over (chainId, market, matchId, pnlA, pnlB).
contract BetMarket is Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using MessageHashUtils for bytes32;

    enum Choice {
        None,
        AgentA,
        AgentB
    }

    enum Status {
        Open,
        Resolved
    }

    enum Winner {
        None,
        AgentA,
        AgentB,
        Tie
    }

    struct Match {
        uint256 agentA;
        uint256 agentB;
        uint64 deadline;
        Status status;
        Winner winner;
        int256 pnlA;
        int256 pnlB;
        uint256 totalA;
        uint256 totalB;
    }

    uint256 public constant FEE_BPS = 200;
    uint256 public constant BPS_DENOM = 10_000;
    uint256 public constant MIN_WINDOW = 60; // 1 minute
    uint256 public constant MAX_WINDOW = 7 days;

    IERC20 public immutable usdc;
    ArenaRegistry public immutable registry;

    address public oracle;
    address public feeRecipient;
    uint256 public accruedFees;
    uint256 public nextMatchId = 1;

    mapping(uint256 matchId => Match) private _matches;
    mapping(uint256 matchId => mapping(address bettor => uint256)) public stakeOnA;
    mapping(uint256 matchId => mapping(address bettor => uint256)) public stakeOnB;
    mapping(uint256 matchId => mapping(address bettor => bool)) public claimed;

    event MatchCreated(uint256 indexed matchId, uint256 indexed agentA, uint256 indexed agentB, uint64 deadline);
    event BetPlaced(uint256 indexed matchId, address indexed bettor, Choice choice, uint256 amount);
    event MatchResolved(uint256 indexed matchId, Winner winner, int256 pnlA, int256 pnlB);
    event WinningsClaimed(uint256 indexed matchId, address indexed bettor, uint256 amount);
    event AgentDecision(uint256 indexed agentId, uint8 action, uint16 sizeBp, uint64 timestamp);
    event OracleSet(address indexed previous, address indexed next);
    event FeeRecipientSet(address indexed previous, address indexed next);
    event FeesWithdrawn(address indexed to, uint256 amount);

    error ZeroAddress();
    error AgentsMustDiffer();
    error WindowTooShort();
    error WindowTooLong();
    error AgentNotActive(uint256 agentId);
    error MatchNotFound(uint256 matchId);
    error MatchAlreadyResolved();
    error MatchNotResolved();
    error MatchExpired();
    error MatchNotExpired();
    error InvalidChoice();
    error ZeroAmount();
    error BadSignature();
    error AlreadyClaimed();
    error NothingToClaim();
    error NotOracle();

    modifier onlyOracle() {
        if (msg.sender != oracle) revert NotOracle();
        _;
    }

    constructor(IERC20 usdc_, ArenaRegistry registry_, address oracle_, address feeRecipient_, address initialOwner)
        Ownable(initialOwner)
    {
        if (
            address(usdc_) == address(0) || address(registry_) == address(0) || oracle_ == address(0)
                || feeRecipient_ == address(0)
        ) {
            revert ZeroAddress();
        }
        usdc = usdc_;
        registry = registry_;
        oracle = oracle_;
        feeRecipient = feeRecipient_;
    }

    // ───────────────────────────── admin ─────────────────────────────

    function setOracle(address newOracle) external onlyOwner {
        if (newOracle == address(0)) revert ZeroAddress();
        emit OracleSet(oracle, newOracle);
        oracle = newOracle;
    }

    function setFeeRecipient(address newRecipient) external onlyOwner {
        if (newRecipient == address(0)) revert ZeroAddress();
        emit FeeRecipientSet(feeRecipient, newRecipient);
        feeRecipient = newRecipient;
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function withdrawFees(address to) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        uint256 amount = accruedFees;
        if (amount == 0) revert NothingToClaim();
        accruedFees = 0;
        usdc.safeTransfer(to, amount);
        emit FeesWithdrawn(to, amount);
    }

    // ─────────────────────────── core flow ──────────────────────────

    function createMatch(uint256 agentA, uint256 agentB, uint256 windowSec)
        external
        whenNotPaused
        returns (uint256 matchId)
    {
        if (agentA == agentB) revert AgentsMustDiffer();
        if (windowSec < MIN_WINDOW) revert WindowTooShort();
        if (windowSec > MAX_WINDOW) revert WindowTooLong();
        if (!registry.isActive(agentA)) revert AgentNotActive(agentA);
        if (!registry.isActive(agentB)) revert AgentNotActive(agentB);

        matchId = nextMatchId++;
        uint64 deadline = uint64(block.timestamp + windowSec);
        _matches[matchId] = Match({
            agentA: agentA,
            agentB: agentB,
            deadline: deadline,
            status: Status.Open,
            winner: Winner.None,
            pnlA: 0,
            pnlB: 0,
            totalA: 0,
            totalB: 0
        });

        emit MatchCreated(matchId, agentA, agentB, deadline);
    }

    function placeBet(uint256 matchId, Choice choice, uint256 amount) external nonReentrant whenNotPaused {
        Match storage m = _matches[matchId];
        if (m.deadline == 0) revert MatchNotFound(matchId);
        if (m.status != Status.Open) revert MatchAlreadyResolved();
        if (block.timestamp >= m.deadline) revert MatchExpired();
        if (amount == 0) revert ZeroAmount();

        if (choice == Choice.AgentA) {
            stakeOnA[matchId][msg.sender] += amount;
            m.totalA += amount;
        } else if (choice == Choice.AgentB) {
            stakeOnB[matchId][msg.sender] += amount;
            m.totalB += amount;
        } else {
            revert InvalidChoice();
        }

        usdc.safeTransferFrom(msg.sender, address(this), amount);
        emit BetPlaced(matchId, msg.sender, choice, amount);
    }

    function resolveMatch(uint256 matchId, int256 pnlA, int256 pnlB, bytes calldata signature) external nonReentrant {
        Match storage m = _matches[matchId];
        if (m.deadline == 0) revert MatchNotFound(matchId);
        if (m.status != Status.Open) revert MatchAlreadyResolved();
        if (block.timestamp < m.deadline) revert MatchNotExpired();

        bytes32 digest = keccak256(abi.encode(block.chainid, address(this), matchId, pnlA, pnlB));
        address signer = ECDSA.recover(digest.toEthSignedMessageHash(), signature);
        if (signer != oracle) revert BadSignature();

        Winner w;
        if (pnlA > pnlB) {
            w = Winner.AgentA;
        } else if (pnlB > pnlA) {
            w = Winner.AgentB;
        } else {
            w = Winner.Tie;
        }

        // Accrue fee on the two-sided pool. Tie or one-sided pool → no fee (full refund path in claim).
        if (w != Winner.Tie && m.totalA > 0 && m.totalB > 0) {
            uint256 gross = m.totalA + m.totalB;
            accruedFees += (gross * FEE_BPS) / BPS_DENOM;
        }

        m.status = Status.Resolved;
        m.winner = w;
        m.pnlA = pnlA;
        m.pnlB = pnlB;

        emit MatchResolved(matchId, w, pnlA, pnlB);
    }

    function claimWinnings(uint256 matchId) external nonReentrant {
        Match storage m = _matches[matchId];
        if (m.deadline == 0) revert MatchNotFound(matchId);
        if (m.status != Status.Resolved) revert MatchNotResolved();
        if (claimed[matchId][msg.sender]) revert AlreadyClaimed();

        uint256 sA = stakeOnA[matchId][msg.sender];
        uint256 sB = stakeOnB[matchId][msg.sender];
        if (sA == 0 && sB == 0) revert NothingToClaim();

        uint256 payout = _payout(m, sA, sB);
        if (payout == 0) revert NothingToClaim();

        claimed[matchId][msg.sender] = true;
        usdc.safeTransfer(msg.sender, payout);
        emit WinningsClaimed(matchId, msg.sender, payout);
    }

    function recordDecision(uint256 agentId, uint8 action, uint16 sizeBp) external onlyOracle whenNotPaused {
        emit AgentDecision(agentId, action, sizeBp, uint64(block.timestamp));
    }

    // ───────────────────────────── views ─────────────────────────────

    function getMatch(uint256 matchId) external view returns (Match memory) {
        return _matches[matchId];
    }

    function payoutOf(uint256 matchId, address bettor) external view returns (uint256) {
        Match storage m = _matches[matchId];
        if (m.status != Status.Resolved) return 0;
        if (claimed[matchId][bettor]) return 0;
        return _payout(m, stakeOnA[matchId][bettor], stakeOnB[matchId][bettor]);
    }

    // ─────────────────────────── internals ───────────────────────────

    function _payout(Match storage m, uint256 sA, uint256 sB) internal view returns (uint256) {
        if (m.winner == Winner.Tie) {
            return sA + sB;
        }

        uint256 totalW;
        uint256 totalL;
        uint256 sWinner;
        if (m.winner == Winner.AgentA) {
            totalW = m.totalA;
            totalL = m.totalB;
            sWinner = sA;
        } else {
            totalW = m.totalB;
            totalL = m.totalA;
            sWinner = sB;
        }

        if (sWinner == 0) return 0;
        if (totalL == 0) return sWinner; // one-sided pool: refund stake, no fee

        uint256 gross = totalW + totalL;
        uint256 fee = (gross * FEE_BPS) / BPS_DENOM;
        uint256 netPool = gross - fee;
        return (sWinner * netPool) / totalW;
    }
}
