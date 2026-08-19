// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

interface IFluxaHook {
    enum PoolState { Normal, Distress, Resolution }

    struct RWAInstrument {
        address token;
        uint8   riskTier;
        address oracle;
        bool    illiquid;
        uint256 maturityTs;
    }

    struct Auction {
        bool    active;
        bytes32 highestBidHash;
        address highestBidder;
        uint256 highestAmount;
        uint256 revealDeadline;
        uint256 commitDeadline;
    }

    event HookSwap(
        address indexed poolManager,
        PoolId indexed poolId,
        address sender,
        int128 amount0,
        int128 amount1,
        bytes hookData
    );

    event HookFee(
        address indexed poolManager,
        PoolId indexed poolId,
        address sender,
        uint256 feeAmount
    );

    event InstrumentRegistered(PoolId indexed poolId, address token, uint8 riskTier, bool illiquid, uint256 maturityTs);
    event PoolStateChanged(PoolId indexed poolId, PoolState oldState, PoolState newState);
    event BidCommitted(PoolId indexed poolId, address indexed bidder);
    event BidRevealed(PoolId indexed poolId, address indexed bidder, uint256 amount);
    event AuctionSettled(PoolId indexed poolId, address winner, uint256 amount);

    error InvalidState(PoolId poolId, PoolState current, PoolState expected);
    error AuctionNotActive(PoolId poolId);
    error CommitDeadlinePassed(PoolId poolId);
    error RevealDeadlinePassed(PoolId poolId);
    error InvalidReveal(PoolId poolId, address bidder);
    error NoValidBids(PoolId poolId);
    error ReputationTooLow(address agent, uint256 score);
    error OracleDefaulted(PoolId poolId);
    error OracleStale(PoolId poolId);
    error NotAgentOwner(address caller, uint256 agentId);
    error InstrumentNotRegistered(PoolId poolId);
    error OnlyOwner();

    function registerInstrument(PoolId poolId, RWAInstrument calldata instrument) external;
    function setDistress(PoolId poolId, PoolState newState) external;
    function commitBid(PoolId poolId, bytes32 commitHash) external;
    function revealBid(PoolId poolId, uint256 amount, bytes32 nonce) external;
    function settleAuction(PoolId poolId) external;
}
