// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Chronicle Verified Asset Oracle interface for RWA
/// @dev Covers 3 Fluxa modes:
///   - Mode A (liquid RWA): readPrice + readYield via Scribe feed
///   - Mode B (illiquid RWA): verifyAttestation for TEE-inferred price
///   - Mode C (liquidation): isDefaulted + isUnbacked triggers
interface IChronicleOracle {
    function readPrice(address rwaToken) external view returns (uint256 price, uint256 updateTs);
    function readYield(address rwaToken) external view returns (uint256 apyBps);
    function isDefaulted(address rwaToken) external view returns (bool);
    function isUnbacked(address rwaToken) external view returns (bool);
    function verifyAttestation(bytes calldata proof) external view returns (bool valid, uint256 price);
}
