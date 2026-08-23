// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";

import {IEigenLayerAVS} from "../interfaces/IEigenLayerAVS.sol";

/// @title MockEigenLayerAVS
/// @notice Stub AVS validator — always returns true in MVP.
/// @dev In production, a distributed set of AVS operators (staked on EigenLayer)
/// would re-execute the agent's pricing decision and reach consensus.
/// This mock simulates that consensus is always reached affirmatively.
contract MockEigenLayerAVS is IEigenLayerAVS {
    mapping(uint256 => bool) public agentAllowed;

    event DecisionValidated(uint256 indexed agentId, bytes32 indexed decisionHash, bool valid);

    function setAgentAllowed(uint256 agentId, bool allowed) external {
        agentAllowed[agentId] = allowed;
    }

    /// @dev Stub: returns true if agent is allowed. Production: re-execute + consensus.
    function validateDecision(
        uint256 agentId,
        bytes32 decisionHash,
        bytes calldata
    ) external view override returns (bool valid, string memory reason) {
        if (!agentAllowed[agentId]) {
            return (false, "agent-not-registered");
        }
        return (true, "");
    }
}
