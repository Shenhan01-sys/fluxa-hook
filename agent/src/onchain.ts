import { createWalletClient, createPublicClient, http, defineChain } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import type { Config } from "./config.js";
import type { Attestation } from "./attestation.js";

// Base Sepolia chain definition
const baseSepolia = defineChain({
  id: 84532,
  name: "Base Sepolia",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: {
    default: { http: ["https://sepolia.base.org"] },
  },
  blockExplorers: {
    default: { name: "Basescan", url: "https://sepolia.basescan.org" },
  },
  testnet: true,
});

export interface OnchainClients {
  public: ReturnType<typeof createPublicClient>;
  wallet: ReturnType<typeof createWalletClient>;
  account: ReturnType<typeof privateKeyToAccount>;
  chain: typeof baseSepolia;
}

export function makeClients(cfg: Config): OnchainClients {
  if (!cfg.privateKey) {
    throw new Error("PRIVATE_KEY not set — required to register attestation on-chain");
  }
  const account = privateKeyToAccount(cfg.privateKey as `0x${string}`);
  const chain = baseSepolia;
  const transport = http(cfg.rpcUrl);
  return {
    public: createPublicClient({ chain, transport }),
    wallet: createWalletClient({ account, chain, transport }),
    account,
    chain,
  };
}

// Minimal ABI for MockChronicleOracle.setAttestation(bytes32, uint256)
const CHRONICLE_ABI = [
  {
    name: "setAttestation",
    type: "function",
    stateMutability: "nonpayable",
    inputs: [
      { name: "proofHash", type: "bytes32" },
      { name: "price", type: "uint256" },
    ],
    outputs: [],
  },
  {
    name: "attestations",
    type: "function",
    stateMutability: "view",
    inputs: [{ name: "proofHash", type: "bytes32" }],
    outputs: [{ name: "", type: "bool" }],
  },
  {
    name: "attestedPrices",
    type: "function",
    stateMutability: "view",
    inputs: [{ name: "proofHash", type: "bytes32" }],
    outputs: [{ name: "", type: "uint256" }],
  },
] as const;

export async function registerAttestation(
  clients: OnchainClients,
  chronicleAddr: `0x${string}`,
  attestation: Attestation
): Promise<{ txHash: `0x${string}`; blockNumber: bigint | null }> {
  console.log(`  → Registering attestation on MockChronicleOracle ${chronicleAddr}`);
  console.log(`    proofHash: ${attestation.proofHash}`);
  console.log(`    price (wei): ${attestation.priceWei.toString()}`);

  const hash = await clients.wallet.writeContract({
    address: chronicleAddr,
    abi: CHRONICLE_ABI,
    functionName: "setAttestation",
    args: [attestation.proofHash, attestation.priceWei],
    chain: clients.chain,
    account: clients.account,
  });

  console.log(`  ✓ tx submitted: ${hash}`);
  const receipt = await clients.public.waitForTransactionReceipt({ hash });
  console.log(`  ✓ mined in block ${receipt.blockNumber} (gas used: ${receipt.gasUsed.toString()})`);
  return { txHash: hash, blockNumber: receipt.blockNumber };
}

export async function verifyAttestationOnchain(
  clients: OnchainClients,
  chronicleAddr: `0x${string}`,
  attestation: Attestation
): Promise<{ valid: boolean; storedPrice: bigint }> {
  const valid = (await clients.public.readContract({
    address: chronicleAddr,
    abi: CHRONICLE_ABI,
    functionName: "attestations",
    args: [attestation.proofHash],
  })) as boolean;

  const storedPrice = (await clients.public.readContract({
    address: chronicleAddr,
    abi: CHRONICLE_ABI,
    functionName: "attestedPrices",
    args: [attestation.proofHash],
  })) as bigint;

  return { valid, storedPrice };
}
