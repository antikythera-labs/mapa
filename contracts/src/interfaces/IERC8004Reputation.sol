// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title IERC8004Reputation
/// @notice Minimal external surface of the ERC-8004 Reputation Registry that MAPA uses for the
///         mirror-only bonus path. Real deployments live at:
///           - Sepolia 0x8004B663056A597Dffe9eCcC1965A193B7388713
///           - Mainnet 0x8004BAa17C55a88189AE136b182e5fdA19dE9b63
///         The exact giveFeedback ABI is treated as opaque until verified on Sepolia during deploy;
///         this interface captures the shape MAPA's adapter encodes.
///
///         EIP-8004 verbatim: "The feedback submitter MUST NOT be the agent owner or an approved
///         operator for agentId." Our adapter is the submitter, so the adapter address must never
///         coincide with the agent owner address in the Identity Registry.
interface IERC8004Reputation {
    function giveFeedback(uint256 agentId, int128 feedbackValue, uint8 authType, bytes32 tag1, bytes32 tag2) external;
}
