import { loadConfig } from "./config.js";
import { computeFairPrice } from "./llm.js";
import { buildAttestation, buildHookData } from "./attestation.js";
import { makeClients, registerAttestation, verifyAttestationOnchain } from "./onchain.js";
import { startServer } from "./server.js";

function banner() {
  console.log("\n" + "═".repeat(72));
  console.log("  Fluxa AI Agent Service — off-chain fair-price oracle for illiquid RWA");
  console.log("  Mode B (TEE-attested pricing) for Uniswap v4 FluxaHook");
  console.log("═".repeat(72) + "\n");
}

function formatResult(r: { price: number; confidence: number; rationale: string; inputsHash: string }) {
  console.log("  LLM Fair Price Result:");
  console.log(`    price (USDC): ${r.price}`);
  console.log(`    confidence:   ${(r.confidence * 100).toFixed(1)}%`);
  console.log(`    rationale:    ${r.rationale}`);
  console.log(`    inputsHash:   0x${r.inputsHash}`);
}

async function main() {
  const args = process.argv.slice(2);

  // HTTP server mode: --serve [--port=3030]
  if (args.includes("--serve")) {
    const portArg = args.find((a) => a.startsWith("--port"));
    const port = portArg ? parseInt(portArg.split("=")[1] ?? "3030", 10) : 3030;
    return startServer(port);
  }

  const priceOnly = args.includes("--price-only");
  const register = args.includes("--register");
  const hookdataOnly = args.includes("--hookdata");

  banner();
  const cfg = loadConfig();
  console.log(`  LLM provider: ${cfg.llmProvider}`);
  console.log(`  Agent ID:     ${cfg.agentId}`);
  console.log(`  RWA:          ${cfg.rwaMetadata.name} (${cfg.rwaMetadata.symbol})`);
  console.log(`  Chain:        ${cfg.chainId} (Base Sepolia)`);
  console.log(`  Hook:         ${cfg.contracts.fluxaHook}`);
  console.log(`  Chronicle:    ${cfg.contracts.chronicleOracle}\n`);

  // 1. Compute fair price via LLM (or mock heuristic)
  console.log("─".repeat(72));
  console.log("  [1/4] Computing fair price for illiquid RWA via LLM…");
  const marketContext = {
    volume24h: 4200,
    lastTradeTs: Math.floor(Date.now() / 1000) - 3600,
    oraclePrice: cfg.rwaMetadata.lastPrice,
    oracleStale: false,
  };
  const result = await computeFairPrice(cfg, marketContext);
  formatResult(result);

  if (priceOnly) {
    console.log("\n  (--price-only — stopping after LLM step)");
    return;
  }

  // 2. Build TEE-mock attestation proof
  console.log("\n" + "─".repeat(72));
  console.log("  [2/4] Building TEE-mock attestation proof…");
  const signerAddress = cfg.privateKey
    ? (await import("viem/accounts")).privateKeyToAccount(cfg.privateKey as `0x${string}`).address
    : "0x0000000000000000000000000000000000000000" as `0x${string}`;
  const attestation = buildAttestation(cfg.agentId, result, signerAddress);
  console.log("  Attestation:");
  console.log(`    proof:         ${attestation.proof.slice(0, 50)}…${attestation.proof.slice(-8)}`);
  console.log(`    proofHash:     ${attestation.proofHash}`);
  console.log(`    price (wei):   ${attestation.priceWei.toString()}`);
  console.log(`    timestamp:     ${attestation.timestamp}`);
  console.log(`    enclaveHash:   ${attestation.enclaveHash}`);
  console.log(`    signature:     ${attestation.signature}`);

  // 3. Build hookData for swap (always — even if not registering)
  console.log("\n" + "─".repeat(72));
  console.log("  [3/4] Building hookData for Mode B swap…");
  const hookData = buildHookData(attestation);
  console.log(`  hookData (${hookData.length} chars):`);
  console.log(`    ${hookData.slice(0, 80)}…`);
  console.log(`    (full length: ${Math.floor(hookData.length / 2 - 1)} bytes)`);

  if (hookdataOnly) {
    console.log("\n  Full hookData (copy-paste into swap call):");
    console.log(`  ${hookData}`);
    return;
  }

  // 4. Register attestation on-chain (optional — requires PRIVATE_KEY)
  console.log("\n" + "─".repeat(72));
  if (!register) {
    console.log("  [4/4] Skipping on-chain registration (--register flag not set).");
    console.log("        Run with --register to submit setAttestation() tx.");
    console.log("\n  To use this attestation in a swap:");
    console.log("    1. Register on-chain:  npm run register");
    console.log("    2. Pass hookData into your swap call (Mode B, exact-input, negative amountSpecified)");
    console.log("\n  Full hookData:");
    console.log(`  ${hookData}`);
    return;
  }

  console.log("  [4/4] Registering attestation on-chain at MockChronicleOracle…");
  const clients = makeClients(cfg);
  console.log(`  Signer: ${clients.account.address}`);
  const { txHash, blockNumber } = await registerAttestation(
    clients,
    cfg.contracts.chronicleOracle,
    attestation
  );

  // Verify on-chain
  console.log("\n  Verifying on-chain registration…");
  const { valid, storedPrice } = await verifyAttestationOnchain(
    clients,
    cfg.contracts.chronicleOracle,
    attestation
  );
  console.log(`    attestations[proofHash] = ${valid}`);
  console.log(`    attestedPrices[proofHash] = ${storedPrice.toString()} (expected ${attestation.priceWei.toString()})`);

  if (!valid || storedPrice !== attestation.priceWei) {
    console.error("\n  ✗ Verification failed!");
    process.exit(1);
  }

  console.log("\n" + "═".repeat(72));
  console.log("  ✓ Attestation registered + verified on-chain");
  console.log("═".repeat(72));
  console.log(`\n  txHash:   ${txHash}`);
  console.log(`  block:    ${blockNumber}`);
  console.log(`  proofHash: ${attestation.proofHash}`);
  console.log(`  price:    ${attestation.priceUsdc} USDC (${attestation.priceWei} wei)`);
  console.log(`\n  hookData for Mode B swap:`);
  console.log(`  ${hookData}`);
  console.log("\n  Next: call poolManager.swap(key, params, hookData) with:");
  console.log("    - params.amountSpecified = -<input amount> (exact input, negative)");
  console.log("    - params.zeroForOne = true (RWA → USDC)");
  console.log("    - hookData = bytes above");
  console.log("");
}

main().catch((err) => {
  console.error("\n✗ Agent service failed:", err);
  process.exit(1);
});
