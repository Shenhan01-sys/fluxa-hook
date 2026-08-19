// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Minimal ERC-8004 Reputation Registry interface
interface IERC8004Registry {
    struct ReputationSummary {
        int128 score;
        bytes32 tag1;
        bytes32 tag2;
    }

    function getSummary(uint256 agentId, address requester, bytes32 context)
        external
        view
        returns (ReputationSummary memory);

    function giveFeedback(uint256 agentId, int128 delta, bytes32 tag) external;
}

/// @notice Minimal ERC-7857 Agent NFT interface
interface IERC7857Agent {
    function ownerOf(uint256 agentId) external view returns (address);
    function isAuthorizedOperator(uint256 agentId, address operator) external view returns (bool);
    function strategyCommitment(uint256 agentId) external view returns (bytes32);
}
