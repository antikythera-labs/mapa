// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title IReputation
/// @notice Elo storage read by OddsOracle. Production impl = MockReputation (deployer-controlled).
///         ERC8004ReputationAdapter mirrors values to the public ERC-8004 registry but is NOT a source.
interface IReputation {
    event EloUpdated(uint256 indexed agentId, uint256 oldElo, uint256 newElo);

    /// @notice Returns the stored Elo for an agent. Returns 0 if never set.
    function getElo(uint256 agentId) external view returns (uint256);

    /// @notice Writes Elo for a single agent. Permissioned in implementations.
    function setElo(uint256 agentId, uint256 elo) external;
}
