// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IChronicleOracle} from "../interfaces/IChronicleOracle.sol";

contract MockChronicleOracle is IChronicleOracle {
    mapping(address => uint256) public prices;
    mapping(address => uint256) public updateTimestamps;
    mapping(address => uint256) public yields;
    mapping(address => bool)    public defaulted;
    mapping(address => bool)    public unbacked;

    mapping(bytes32 => bool)    public attestations;
    mapping(bytes32 => uint256) public attestedPrices;

    function setPrice(address token, uint256 price) external {
        prices[token] = price;
        updateTimestamps[token] = block.timestamp;
    }

    function setYield(address token, uint256 apyBps) external {
        yields[token] = apyBps;
    }

    function setDefaulted(address token, bool flag) external {
        defaulted[token] = flag;
    }

    function setUnbacked(address token, bool flag) external {
        unbacked[token] = flag;
    }

    function setAttestation(bytes32 proofHash, uint256 price) external {
        attestations[proofHash] = true;
        attestedPrices[proofHash] = price;
    }

    function readPrice(address rwaToken) external view override returns (uint256 price, uint256 updateTs) {
        return (prices[rwaToken], updateTimestamps[rwaToken]);
    }

    function readYield(address rwaToken) external view override returns (uint256 apyBps) {
        return yields[rwaToken];
    }

    function isDefaulted(address rwaToken) external view override returns (bool) {
        return defaulted[rwaToken];
    }

    function isUnbacked(address rwaToken) external view override returns (bool) {
        return unbacked[rwaToken];
    }

    function verifyAttestation(bytes calldata proof) external view override returns (bool valid, uint256 price) {
        bytes32 proofHash = keccak256(proof);
        return (attestations[proofHash], attestedPrices[proofHash]);
    }
}
