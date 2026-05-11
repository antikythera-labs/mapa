// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title IAlloraConsumer
/// @notice Minimal read surface for an Allora Network inference consumer.
///         Real Allora consumer contract on Mantle is wired in post-A2 via
///         `OddsOracle.setAlloraConfig`. Phase A1 ships with `address(0)` and the
///         fallback path stays exercised by tests.
interface IAlloraConsumer {
    /// @notice Returns the latest network inference for `topicId`.
    /// @return networkInference Signed inference value (semantics topic-dependent).
    /// @return timestamp Block timestamp at which the inference was published.
    function getInferenceByTopicId(uint256 topicId) external view returns (int256 networkInference, uint256 timestamp);
}
