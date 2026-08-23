// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";

import {IERC8183Escrow} from "../interfaces/IERC8183Escrow.sol";
import {IFluxaHook} from "../interfaces/IFluxaHook.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title MockERC8183Escrow
/// @notice Agentic escrow — LPs hire an AI agent to manage their RWA pool.
/// @dev LP deposits payment into escrow. At deadline, an on-chain evaluator
/// checks yield vs benchmark. If passed, payment released to agent. If failed, refund to LP.
/// This is the ERC-8183 "agentic escrow" pattern: trustless agent hiring.
contract MockERC8183Escrow is IERC8183Escrow {
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolId;

    IFluxaHook public immutable hook;
    IERC20 public immutable paymentToken;

    mapping(PoolId => Hire) private _hires;

    constructor(address _hook, address _paymentToken) {
        hook = IFluxaHook(_hook);
        paymentToken = IERC20(_paymentToken);
    }

    /// @inheritdoc IERC8183Escrow
    function hireAgent(
        PoolId poolId,
        uint256 agentId,
        address agent,
        uint256 paymentAmount,
        uint256 benchmarkYieldBps,
        uint256 deadline
    ) external override {
        if (_hires[poolId].active) revert HireAlreadyExists(poolId);
        if (paymentAmount == 0) revert("zero-payment");
        if (deadline <= block.timestamp) revert("past-deadline");

        paymentToken.safeTransferFrom(msg.sender, address(this), paymentAmount);

        _hires[poolId] = Hire({
            poolId: poolId,
            agentId: agentId,
            lp: msg.sender,
            agent: agent,
            paymentAmount: paymentAmount,
            benchmarkYieldBps: benchmarkYieldBps,
            deadline: deadline,
            active: true,
            completed: false
        });

        emit AgentHired(poolId, agentId, msg.sender, paymentAmount, benchmarkYieldBps, deadline);
    }

    /// @inheritdoc IERC8183Escrow
    /// @dev Evaluator: reads cumulativeYield + totalLiquidity1 from FluxaHook,
    /// computes actual yield in bps, compares to benchmark.
    function evaluateAndSettle(PoolId poolId) external override returns (bool passed) {
        Hire storage hire = _hires[poolId];
        if (!hire.active) revert NoActiveHire(poolId);
        if (hire.completed) revert AlreadySettled(poolId);
        if (block.timestamp < hire.deadline) revert DeadlineNotReached(poolId, hire.deadline);

        // Read yield data from FluxaHook (on-chain, trustless)
        IFluxaHook.PoolMetadata memory meta = hook.getPoolMetadata(poolId);
        uint256 actualYieldBps;
        if (meta.totalLiquidity1 > 0) {
            actualYieldBps = (meta.cumulativeYield * 10000) / meta.totalLiquidity1;
        }

        passed = actualYieldBps >= hire.benchmarkYieldBps;

        hire.completed = true;
        hire.active = false;

        if (passed) {
            paymentToken.safeTransfer(hire.agent, hire.paymentAmount);
        } else {
            paymentToken.safeTransfer(hire.lp, hire.paymentAmount);
        }

        emit EscrowSettled(poolId, hire.agentId, passed, actualYieldBps, passed ? hire.paymentAmount : 0);
    }

    function getHire(PoolId poolId) external view override returns (Hire memory) {
        return _hires[poolId];
    }
}
