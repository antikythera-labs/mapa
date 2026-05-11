// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

import { IERC8004Reputation } from "./interfaces/IERC8004Reputation.sol";

/// @title ERC8004ReputationAdapter
/// @notice Bonus narrative path that mirrors agent Elo into the public ERC-8004 Reputation
///         Registry. NOT on the critical path: OddsOracle reads Elo from MockReputation only.
///         If this adapter ever fails (registry down, ABI changed, etc.), the rest of MAPA keeps
///         working.
///
///         Auth model: only `judge` (the MAPA_JUDGE EOA) may call mirrorElo. From ERC-8004's
///         point of view the submitter is this adapter contract — it must therefore never be the
///         agent owner in the Identity Registry (verified pre-deploy).
contract ERC8004ReputationAdapter is Ownable {
    bytes32 public constant TAG1 = bytes32("MAPA-Elo");
    bytes32 public constant TAG2 = bytes32("v1");
    uint8 public constant AUTH_TYPE = 0;

    IERC8004Reputation public immutable reputation;
    address public judge;

    event JudgeSet(address indexed previous, address indexed next);
    event EloMirrored(uint256 indexed agentId, int128 elo);

    error ZeroAddress();
    error NotJudge();

    modifier onlyJudge() {
        if (msg.sender != judge) revert NotJudge();
        _;
    }

    constructor(IERC8004Reputation reputation_, address judge_, address initialOwner) Ownable(initialOwner) {
        if (address(reputation_) == address(0) || judge_ == address(0)) revert ZeroAddress();
        reputation = reputation_;
        judge = judge_;
    }

    function setJudge(address newJudge) external onlyOwner {
        if (newJudge == address(0)) revert ZeroAddress();
        emit JudgeSet(judge, newJudge);
        judge = newJudge;
    }

    /// @notice Push agent Elo into the public ERC-8004 registry under the MAPA-Elo tag.
    function mirrorElo(uint256 agentId, int128 elo) external onlyJudge {
        reputation.giveFeedback(agentId, elo, AUTH_TYPE, TAG1, TAG2);
        emit EloMirrored(agentId, elo);
    }
}
