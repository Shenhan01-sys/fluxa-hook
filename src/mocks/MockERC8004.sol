// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC8004Registry, IERC7857Agent} from "../interfaces/IERC8004Registry.sol";

contract MockERC8004 is IERC8004Registry {
    mapping(uint256 => ReputationSummary) public summaries;
    mapping(uint256 => int128) public feedback;

    function setReputation(uint256 agentId, int128 score) external {
        summaries[agentId].score = score;
    }

    function getSummary(uint256 agentId, address, bytes32)
        external
        view
        override
        returns (ReputationSummary memory)
    {
        return summaries[agentId];
    }

    function giveFeedback(uint256 agentId, int128 delta, bytes32) external override {
        summaries[agentId].score += delta;
        feedback[agentId] += delta;
    }
}

contract MockERC7857 is IERC7857Agent {
    mapping(uint256 => address) public owners;
    mapping(uint256 => mapping(address => bool)) public operators;
    mapping(uint256 => bytes32) public commitments;
    uint256 public nextId;

    function mint(address owner) external returns (uint256 id) {
        id = ++nextId;
        owners[id] = owner;
    }

    function setAuthorizedOperator(uint256 agentId, address operator, bool auth) external {
        operators[agentId][operator] = auth;
    }

    function setStrategyCommitment(uint256 agentId, bytes32 commitment) external {
        commitments[agentId] = commitment;
    }

    function ownerOf(uint256 agentId) external view override returns (address) {
        return owners[agentId];
    }

    function isAuthorizedOperator(uint256 agentId, address operator) external view override returns (bool) {
        return operators[agentId][operator];
    }

    function strategyCommitment(uint256 agentId) external view override returns (bytes32) {
        return commitments[agentId];
    }
}
