// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

import { IReputation } from "./interfaces/IReputation.sol";

/// @title MockReputation
/// @notice Deployer-controlled Elo store. Main path for OddsOracle reads.
///         ERC-8004 stores int128 feedback values and forbids owner-writes (EIP-8004:
///         "submitter MUST NOT be the agent owner"), so we keep Elo here and mirror to
///         ERC-8004 via a separate MAPA_JUDGE EOA in ERC8004ReputationAdapter.
contract MockReputation is IReputation, Ownable {
    error LengthMismatch();

    mapping(uint256 => uint256) private _elo;

    constructor(address initialOwner) Ownable(initialOwner) { }

    /// @inheritdoc IReputation
    function getElo(uint256 agentId) external view returns (uint256) {
        return _elo[agentId];
    }

    /// @inheritdoc IReputation
    function setElo(uint256 agentId, uint256 elo) external onlyOwner {
        _setElo(agentId, elo);
    }

    /// @notice Batch helper used by scripts/seed-agents.ts to seed initial Elo for the operated pool.
    function setEloBatch(uint256[] calldata agentIds, uint256[] calldata elos) external onlyOwner {
        if (agentIds.length != elos.length) revert LengthMismatch();
        for (uint256 i = 0; i < agentIds.length; i++) {
            _setElo(agentIds[i], elos[i]);
        }
    }

    function _setElo(uint256 agentId, uint256 elo) internal {
        uint256 old = _elo[agentId];
        _elo[agentId] = elo;
        emit EloUpdated(agentId, old, elo);
    }
}
