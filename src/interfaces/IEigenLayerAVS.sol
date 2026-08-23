// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Minimal EigenLayer AVS validation interface
/// @dev AVS (Actively Validated Services) re-executes agent decisions to verify correctness.
/// In production, a distributed network of operators stakes ETH and re-executes the agent's
/// pricing decision. If consensus disagrees, the decision is rejected.
interface IEigenLayerAVS {
    /// @param agentId The ERC-7857 agent NFT id making the decision
    /// @param decisionHash Hash of the agent's decision (e.g., keccak256(aiPrice))
    /// @param proof TEE attestation proof from Chronicle
    /// @return valid True if AVS consensus confirms the decision
    /// @return reason Human-readable reason if invalid (empty if valid)
    function validateDecision(
        uint256 agentId,
        bytes32 decisionHash,
        bytes calldata proof
    ) external view returns (bool valid, string memory reason);
}
