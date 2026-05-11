// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

import { IReputation } from "./interfaces/IReputation.sol";
import { IAlloraConsumer } from "./interfaces/IAlloraConsumer.sol";

/// @title OddsOracle
/// @notice Display odds for the front-end. Pari-mutuel payouts in BetMarket are derived
///         from pool composition; these odds are a UX hint, not a payout formula.
///         Base = Elo expected-score (table-approximated, ±100 steps). Allora BTC/USD
///         topic 1 inference adds a small ±1% skew when the consumer call succeeds;
///         on revert / unconfigured consumer the contract falls back to pure Elo.
contract OddsOracle is Ownable {
    /// @notice Scale of `getOdds` return values (1e6 → "100%" = 1_000_000).
    uint256 public constant ODDS_SCALE = 1e6;
    /// @notice Default Elo used when an agent has not been seeded in IReputation.
    uint256 public constant DEFAULT_ELO = 1500;
    /// @notice Max absolute Elo difference recognised by the lookup table.
    int256 public constant MAX_ELO_DIFF = 800;
    /// @notice Allora skew magnitude in basis points (1% of probability space).
    uint256 public constant ALLORA_SKEW_BPS = 100;
    /// @notice Lower/upper bound for skewed probability (in bps) to keep odds strictly inside (0, 1).
    uint256 private constant PROB_FLOOR_BPS = 100;
    uint256 private constant PROB_CEIL_BPS = 9_900;
    uint256 private constant BPS_DENOM = 10_000;

    IReputation public immutable reputation;

    IAlloraConsumer public allora;
    uint256 public alloraTopicId;

    event AlloraConfigSet(address indexed consumer, uint256 topicId);

    error ZeroAddress();

    constructor(IReputation reputation_, IAlloraConsumer allora_, uint256 alloraTopicId_, address initialOwner)
        Ownable(initialOwner)
    {
        if (address(reputation_) == address(0)) revert ZeroAddress();
        reputation = reputation_;
        allora = allora_;
        alloraTopicId = alloraTopicId_;
    }

    function setAlloraConfig(IAlloraConsumer consumer, uint256 topicId) external onlyOwner {
        allora = consumer;
        alloraTopicId = topicId;
        emit AlloraConfigSet(address(consumer), topicId);
    }

    /// @notice Returns display odds for both sides of a match, scaled to ODDS_SCALE and summing to ODDS_SCALE.
    function getOdds(uint256 agentA, uint256 agentB) external view returns (uint256 oddsA, uint256 oddsB) {
        uint256 probBps = _eloWinProbBps(_elo(agentA), _elo(agentB));
        probBps = _applyAlloraSkew(probBps);
        oddsA = (probBps * ODDS_SCALE) / BPS_DENOM;
        oddsB = ODDS_SCALE - oddsA;
    }

    function _elo(uint256 agentId) internal view returns (uint256) {
        uint256 e = reputation.getElo(agentId);
        return e == 0 ? DEFAULT_ELO : e;
    }

    /// @dev Elo expected-score, basis points, symmetric around 0 (P(A) + P(B) = 10_000).
    ///      Table sampled at 100-Elo increments (0..800); outside ±800 clamped to ±MAX_ELO_DIFF.
    function _eloWinProbBps(uint256 eloA, uint256 eloB) internal pure returns (uint256) {
        int256 d = int256(eloA) - int256(eloB);
        if (d > MAX_ELO_DIFF) d = MAX_ELO_DIFF;
        if (d < -MAX_ELO_DIFF) d = -MAX_ELO_DIFF;

        bool negative = d < 0;
        uint256 absD = uint256(negative ? -d : d);
        uint256 idx = absD / 100;

        uint256[9] memory tbl = [
            uint256(5_000), // diff 0    → 50.00%
            uint256(6_400), // diff 100  → 64.00%
            uint256(7_600), // diff 200  → 76.00%
            uint256(8_490), // diff 300  → 84.90%
            uint256(9_090), // diff 400  → 90.90%
            uint256(9_460), // diff 500  → 94.60%
            uint256(9_690), // diff 600  → 96.90%
            uint256(9_830), // diff 700  → 98.30%
            uint256(9_900) //  diff 800  → 99.00% (capped)
        ];
        uint256 p = tbl[idx];
        return negative ? BPS_DENOM - p : p;
    }

    function _applyAlloraSkew(uint256 probBps) internal view returns (uint256) {
        if (address(allora) == address(0)) return probBps;

        try allora.getInferenceByTopicId(alloraTopicId) returns (
            int256 inference,
            uint256 /*ts*/
        ) {
            int256 skew;
            if (inference > 0) {
                skew = int256(ALLORA_SKEW_BPS);
            } else if (inference < 0) {
                skew = -int256(ALLORA_SKEW_BPS);
            }
            int256 result = int256(probBps) + skew;
            if (result < int256(PROB_FLOOR_BPS)) return PROB_FLOOR_BPS;
            if (result > int256(PROB_CEIL_BPS)) return PROB_CEIL_BPS;
            return uint256(result);
        } catch {
            return probBps;
        }
    }
}
