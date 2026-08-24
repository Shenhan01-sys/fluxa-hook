// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IChronicleOracle} from "../interfaces/IChronicleOracle.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract MockChronicleOracle is IChronicleOracle, Ownable {
    mapping(address => uint256) public prices;
    mapping(address => uint256) public updateTimestamps;
    mapping(address => uint256) public yields;
    mapping(address => bool)    public defaulted;
    mapping(address => bool)    public unbacked;

    mapping(bytes32 => bool)    public attestations;
    mapping(bytes32 => uint256) public attestedPrices;
    mapping(bytes32 => uint256) public attestationTimestamps;  // D23.6: expiry support

    /// Attestation expiry: 1 hour (3600s). 0 = disabled (for testing).
    uint256 public attestationTTL = 3600;

    constructor() Ownable(msg.sender) {}

    function setPrice(address token, uint256 price) external onlyOwner {
        prices[token] = price;
        updateTimestamps[token] = block.timestamp;
    }

    function setYield(address token, uint256 apyBps) external onlyOwner {
        yields[token] = apyBps;
    }

    function setDefaulted(address token, bool flag) external onlyOwner {
        defaulted[token] = flag;
    }

    function setUnbacked(address token, bool flag) external onlyOwner {
        unbacked[token] = flag;
    }

    /// @notice Register TEE attestation (only owner = attester multisig in prod)
    /// @param proofHash keccak256(proof) — must match what Mode B swap will pass
    /// @param price Fair price in 1e18 scale
    function setAttestation(bytes32 proofHash, uint256 price) external onlyOwner {
        require(price > 0, "price=0");
        attestations[proofHash] = true;
        attestedPrices[proofHash] = price;
        attestationTimestamps[proofHash] = block.timestamp;
    }

    /// @notice Set attestation TTL (0 = no expiry, used in tests). Owner only.
    function setAttestationTTL(uint256 ttl) external onlyOwner {
        attestationTTL = ttl;
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

    /// @notice Verify TEE attestation. Returns (valid, price).
    /// @dev D23.6: now checks expiry — attestation must be within attestationTTL seconds of registration.
    ///      TTL=0 disables expiry (used in tests for deterministic behaviour).
    function verifyAttestation(bytes calldata proof) external view override returns (bool valid, uint256 price) {
        bytes32 proofHash = keccak256(proof);
        if (!attestations[proofHash]) return (false, 0);
        if (attestationTTL != 0) {
            uint256 registered = attestationTimestamps[proofHash];
            if (block.timestamp > registered + attestationTTL) {
                return (false, 0);
            }
        }
        return (true, attestedPrices[proofHash]);
    }
}
