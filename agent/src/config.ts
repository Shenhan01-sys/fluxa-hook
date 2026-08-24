import "dotenv/config";

export interface Config {
  llmProvider: "groq" | "mock";
  groqApiKey?: string;
  groqModel: string;
  rpcUrl: string;
  chainId: number;
  privateKey?: string;
  contracts: {
    fluxaHook: `0x${string}`;
    chronicleOracle: `0x${string}`;
    reputationRegistry: `0x${string}`;
    agentNft: `0x${string}`;
    avsValidator: `0x${string}`;
    escrow: `0x${string}`;
    rwaToken: `0x${string}`;
  };
  agentId: bigint;
  rwaMetadata: {
    name: string;
    symbol: string;
    description: string;
    lastPrice: number;
    lastPriceTs: number;
  };
}

function requiredAddr(key: string, fallback: string): `0x${string}` {
  const v = process.env[key] ?? fallback;
  if (!/^0x[a-fA-F0-9]{40}$/.test(v)) {
    throw new Error(`Invalid address for ${key}: ${v}`);
  }
  return v as `0x${string}`;
}

function requiredInt(key: string, fallback: number): number {
  const v = process.env[key];
  return v ? parseInt(v, 10) : fallback;
}

export function loadConfig(): Config {
  const provider = (process.env.LLM_PROVIDER ?? "groq") as Config["llmProvider"];
  if (!["groq", "mock"].includes(provider)) {
    throw new Error(`LLM_PROVIDER must be groq|mock, got: ${provider}`);
  }
  return {
    llmProvider: provider,
    groqApiKey: process.env.GROQ_API_KEY,
    groqModel: process.env.GROQ_MODEL ?? "llama-3.3-70b-versatile",
    rpcUrl: process.env.RPC_URL ?? "https://sepolia.base.org",
    chainId: requiredInt("CHAIN_ID", 84532),
    privateKey: process.env.PRIVATE_KEY,
    contracts: {
      fluxaHook: requiredAddr("FLUXA_HOOK", "0x98aBecc8db108969028b01E709Eb8126661bdac8"),
      chronicleOracle: requiredAddr("CHRONICLE_ORACLE", "0x40F0676F5C470CE425706F0FA45c7b768a0D2D94"),
      reputationRegistry: requiredAddr("REPUTATION_REGISTRY", "0x506382E2875C92F2555a2fd0377E5E66551B8700"),
      agentNft: requiredAddr("AGENT_NFT", "0xC3C89A8aCf5AB4aCb31048AA88852F700f729471"),
      avsValidator: requiredAddr("AVS_VALIDATOR", "0xD604fA15Ee7217F0238471F56bc8da703E19c27c"),
      escrow: requiredAddr("ESCROW", "0x9f2B663a5B622332f3062A956e410dE92e12aE86"),
      rwaToken: requiredAddr("RWA_TOKEN", "0xA92FB17c8AC46bEfa63d0b3951EA5a5Edd81FCC7"),
    },
    agentId: BigInt(requiredInt("AGENT_ID", 1)),
    rwaMetadata: {
      name: process.env.RWA_NAME ?? "Fluxa RWA Bond",
      symbol: process.env.RWA_SYMBOL ?? "FRWA",
      description: process.env.RWA_DESCRIPTION ??
        "Tokenized private credit instrument backed by real-world asset pool (invoice receivables). Illiquid, no public market.",
      lastPrice: parseFloat(process.env.RWA_LAST_PRICE ?? "1.0"),
      lastPriceTs: requiredInt("RWA_LAST_PRICE_TS", 1724592000),
    },
  };
}
