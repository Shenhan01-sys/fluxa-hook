import { encodePacked, keccak256, toHex, encodeAbiParameters, parseAbiParameters } from "viem";
import type { FairPriceResult } from "./llm.js";

/**
 * TEE Attestation Mock
 *
 * In production, this would be a quote from an SGX/TDX enclave proving that
 * `computeFairPrice()` ran inside TEE with a specific code hash. For the MVP
 * demo, we generate a structured attestation payload signed by the agent
 * operator key and abi-encode it as the "proof" bytes the hook will hash.
 *
 * The on-chain MockChronicleOracle.verifyAttestation(proof) does:
 *   proofHash = keccak256(proof)
 *   return (attestations[proofHash], attestedPrices[proofHash])
 *
 * So registering the attestation = call setAttestation(keccak256(proof), price).
 * Using the swap = pass hookData = abi.encode(proof) into the swap call.
 */

export interface Attestation {
  proof: `0x${string}`;          // abi-encoded attestation bytes
  proofHash: `0x${string}`;      // keccak256(proof) — used as attestation key
  priceWei: bigint;              // price in 1e18 (matches hook's expected scale)
  priceUsdc: number;              // human-readable price
  timestamp: number;             // unix seconds
  agentId: bigint;
  enclaveHash: `0x${string}`;    // mock enclave measurement
  signature: `0x${string}`;      // mock ECDSA signature over the attestation
}

/**
 * Build the TEE-mock attestation proof. The proof is abi.encode of:
 *   (uint256 agentId, uint256 price, uint256 timestamp, bytes32 enclaveHash, bytes32 signature)
 *
 * The hook does NOT decode this — it only keccak256's the bytes and looks up
 * the registered attestation. So the format is opaque to the hook; we choose
 * a structured abi-encoded payload so the off-chain service can verify it.
 */
export function buildAttestation(
  agentId: bigint,
  result: FairPriceResult,
  signerAddress: `0x${string}`
): Attestation {
  const timestamp = Math.floor(Date.now() / 1000);

  // Mock enclave measurement — a fixed hash representing "the TEE code hash".
  // In production this would come from the SGX quote's REPORT_BODY.mr_enclave.
  const enclaveHash = keccak256(toHex("fluxa-tee-enclave-v1", { size: 32 })) as `0x${string}`;

  // Price in 1e18 scale (matches on-chain aiPrice used in AgentPricing.computeSwap)
  const priceWei = BigInt(Math.round(result.price * 1e18));

  // Mock signature: keccak256(agentId || priceWei || timestamp || enclaveHash || signer)
  // In production this would be the enclave's report signature (e.g. RA quote).
  const sigPayload = encodePacked(
    ["uint256", "uint256", "uint256", "bytes32", "address"],
    [agentId, priceWei, BigInt(timestamp), enclaveHash, signerAddress]
  );
  const signature = keccak256(sigPayload) as `0x${string}`;

  // abi-encode the proof bytes (this is what gets hashed on-chain)
  const proof = encodePacked(
    ["uint256", "uint256", "uint256", "bytes32", "bytes32"],
    [agentId, priceWei, BigInt(timestamp), enclaveHash, signature]
  ) as `0x${string}`;

  const proofHash = keccak256(proof) as `0x${string}`;

  return {
    proof,
    proofHash,
    priceWei,
    priceUsdc: result.price,
    timestamp,
    agentId,
    enclaveHash,
    signature,
  };
}

/**
 * Build hookData for a Mode B swap. The hook expects:
 *   hookData = abi.encode(bytes proof)
 *
 * _extractModeBProof in FluxaHook decodes this as abi.encode(bytes) —
 * offset (32B) + length (32B) + data. We mimic that here with a manual
 * encoding because viem's encodeAbiParameters handles dynamic bytes.
 */
export function buildHookData(attestation: Attestation): `0x${string}` {
  // viem's encodeAbiParameters for a single bytes element produces the
  // abi.encode(bytes) layout the hook's _extractModeBProof expects.
  return encodeAbiParameters(
    parseAbiParameters(["bytes"]),
    [attestation.proof]
  ) as `0x${string}`;
}
