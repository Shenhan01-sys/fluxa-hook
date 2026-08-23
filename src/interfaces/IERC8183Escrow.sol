// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @notice Minimal ERC-8183 Agentic Escrow interface
/// @dev LPs hire an agent to manage their RWA pool. Payment is escrowed.
/// An evaluator (smart contract) checks yield vs benchmark at deadline.
/// If yield >= benchmark → payment released to agent. Else → refunded to LP.
interface IERC8183Escrow {
    struct Hire {
        PoolId poolId;
        uint256 agentId;
        address lp;
        address agent;
        uint256 paymentAmount;
        uint256 benchmarkYieldBps; // e.g., 500 = 5% APY benchmark
        uint256 deadline;
        bool active;
        bool completed;
    }

    event AgentHired(PoolId indexed poolId, uint256 indexed agentId, address indexed lp, uint256 payment, uint256 benchmarkBps, uint256 deadline);
    event EscrowSettled(PoolId indexed poolId, uint256 indexed agentId, bool passed, uint256 actualYieldBps, uint256 paymentReleased);

    error NoActiveHire(PoolId poolId);
    error HireAlreadyExists(PoolId poolId);
    error DeadlineNotReached(PoolId poolId, uint256 deadline);
    error AlreadySettled(PoolId poolId);

    function hireAgent(
        PoolId poolId,
        uint256 agentId,
        address agent,
        uint256 paymentAmount,
        uint256 benchmarkYieldBps,
        uint256 deadline
    ) external;

    function evaluateAndSettle(PoolId poolId) external returns (bool passed);
    function getHire(PoolId poolId) external view returns (Hire memory);
}
