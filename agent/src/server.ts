import Fastify, { type FastifyInstance } from "fastify";
import { loadConfig, type Config } from "./config.js";
import { computeFairPrice, type FairPriceResult } from "./llm.js";
import { buildAttestation, buildHookData, type Attestation } from "./attestation.js";
import { makeClients, registerAttestation, verifyAttestationOnchain, type OnchainClients } from "./onchain.js";

interface PriceBody {
  volume24h?: number;
  lastTradeTs?: number;     // unix seconds
  oraclePrice?: number;
  oracleStale?: boolean;
  rwaName?: string;
  rwaSymbol?: string;
  rwaDescription?: string;
  rwaLastPrice?: number;
}

interface AttestBody extends PriceBody {
  // Run /price internally, then build attestation. If `priceResult` is
  // provided, use it directly instead of recomputing (FE may have cached).
  priceResult?: FairPriceResult;
}

interface RegisterBody extends AttestBody {}

/** Recursively convert BigInt values to strings for JSON serialization. */
function stringifyBigInts(obj: unknown): unknown {
  if (typeof obj === "bigint") return obj.toString();
  if (Array.isArray(obj)) return obj.map(stringifyBigInts);
  if (obj && typeof obj === "object") {
    const out: Record<string, unknown> = {};
    for (const [k, v] of Object.entries(obj as Record<string, unknown>)) out[k] = stringifyBigInts(v);
    return out;
  }
  return obj;
}

function makeHandler(cfg: Config) {
  const clients: OnchainClients | null = cfg.privateKey ? makeClients(cfg) : null;

  return {
    health: async () => ({ ok: true, agentId: cfg.agentId.toString(), chain: cfg.chainId, llm: cfg.llmProvider, time: new Date().toISOString() }),

    price: async (body: PriceBody): Promise<FairPriceResult> => {
      const marketContext = {
        volume24h: body.volume24h ?? 4200,
        lastTradeTs: body.lastTradeTs ?? Math.floor(Date.now() / 1000) - 3600,
        oraclePrice: body.oraclePrice ?? cfg.rwaMetadata.lastPrice,
        oracleStale: body.oracleStale ?? false,
      };
      // Apply RWA metadata overrides
      if (body.rwaName) cfg.rwaMetadata.name = body.rwaName;
      if (body.rwaSymbol) cfg.rwaMetadata.symbol = body.rwaSymbol;
      if (body.rwaDescription) cfg.rwaMetadata.description = body.rwaDescription;
      if (body.rwaLastPrice) cfg.rwaMetadata.lastPrice = body.rwaLastPrice;
      return computeFairPrice(cfg, marketContext);
    },

    attest: async (body: AttestBody): Promise<Attestation & { hookData: `0x${string}` }> => {
      const result = body.priceResult ?? await computeFairPrice(cfg, {
        volume24h: body.volume24h ?? 4200,
        lastTradeTs: body.lastTradeTs ?? Math.floor(Date.now() / 1000) - 3600,
        oraclePrice: body.oraclePrice ?? cfg.rwaMetadata.lastPrice,
        oracleStale: body.oracleStale ?? false,
      });
      const signerAddress = clients
        ? clients.account.address
        : "0x0000000000000000000000000000000000000000" as `0x${string}`;
      const attestation = buildAttestation(cfg.agentId, result, signerAddress);
      const hookData = buildHookData(attestation);
      return { ...attestation, hookData };
    },

    register: async (body: RegisterBody): Promise<{ attestation: Attestation; hookData: `0x${string}`; txHash: `0x${string}`; blockNumber: bigint | null; verified: boolean }> => {
      if (!clients) throw new Error("PRIVATE_KEY not set — cannot register on-chain");
      const result = body.priceResult ?? await computeFairPrice(cfg, {
        volume24h: body.volume24h ?? 4200,
        lastTradeTs: body.lastTradeTs ?? Math.floor(Date.now() / 1000) - 3600,
        oraclePrice: body.oraclePrice ?? cfg.rwaMetadata.lastPrice,
        oracleStale: body.oracleStale ?? false,
      });
      const attestation = buildAttestation(cfg.agentId, result, clients.account.address);
      const hookData = buildHookData(attestation);
      const { txHash, blockNumber } = await registerAttestation(clients, cfg.contracts.chronicleOracle, attestation);
      const { valid } = await verifyAttestationOnchain(clients, cfg.contracts.chronicleOracle, attestation);
      return { attestation, hookData, txHash, blockNumber, verified: valid };
    },

    verify: async (proofHash: `0x${string}`) => {
      if (!clients) throw new Error("PRIVATE_KEY not set — cannot read on-chain");
      return verifyAttestationOnchain(clients, cfg.contracts.chronicleOracle, { proofHash } as Attestation);
    },
  };
}

export async function startServer(port: number = 3030): Promise<void> {
  const cfg = loadConfig();
  const h = makeHandler(cfg);
  const app: FastifyInstance = Fastify({ logger: true });

  // CORS — allow FE (Next.js dev on :3000) to call agent service
  app.addHook("onRequest", async (req, reply) => {
    reply.header("Access-Control-Allow-Origin", "*");
    reply.header("Access-Control-Allow-Methods", "GET, POST, OPTIONS");
    reply.header("Access-Control-Allow-Headers", "Content-Type");
    if (req.method === "OPTIONS") return reply.code(204).send();
  });

  app.get("/health", async () => h.health());

  app.post<{ Body: PriceBody }>("/price", async (req, reply) => {
    try {
      const result = await h.price(req.body ?? {});
      return { ok: true, result };
    } catch (e: any) {
      req.log.error(e);
      return reply.code(500).send({ ok: false, error: e.message });
    }
  });

  app.post<{ Body: AttestBody }>("/attest", async (req, reply) => {
    try {
      const result = await h.attest(req.body ?? {});
      return stringifyBigInts({ ok: true, ...result });
    } catch (e: any) {
      req.log.error(e);
      return reply.code(500).send({ ok: false, error: e.message });
    }
  });

  app.post<{ Body: RegisterBody }>("/register", async (req, reply) => {
    try {
      const result = await h.register(req.body ?? {});
      return stringifyBigInts({ ok: true, ...result });
    } catch (e: any) {
      req.log.error(e);
      return reply.code(500).send({ ok: false, error: e.message });
    }
  });

  app.get<{ Params: { proofHash: string } }>("/verify/:proofHash", async (req, reply) => {
    try {
      const { valid, storedPrice } = await h.verify(req.params.proofHash as `0x${string}`);
      return { ok: true, valid, storedPrice: storedPrice?.toString() };
    } catch (e: any) {
      return reply.code(500).send({ ok: false, error: e.message });
    }
  });

  app.get("/contracts", async () => ({
    ok: true,
    chainId: cfg.chainId,
    contracts: cfg.contracts,
    agentId: cfg.agentId.toString(),
    rwaMetadata: cfg.rwaMetadata,
  }));

  try {
    await app.listen({ port, host: "0.0.0.0" });
    console.log(`\n  Fluxa Agent Service running on http://localhost:${port}`);
    console.log(`  Endpoints:`);
    console.log(`    GET  /health        — service status`);
    console.log(`    POST /price        — compute fair price (LLM/mock)`);
    console.log(`    POST /attest       — build TEE-mock attestation + hookData`);
    console.log(`    POST /register     — attest + register on-chain (requires PRIVATE_KEY)`);
    console.log(`    GET  /verify/:hash — verify on-chain attestation`);
    console.log(`    GET  /contracts    — list deployed addresses`);
    console.log(`\n  LLM provider: ${cfg.llmProvider}`);
    console.log(`  Agent ID: ${cfg.agentId}`);
    console.log(`  Hook: ${cfg.contracts.fluxaHook}\n`);
  } catch (err) {
    app.log.error(err);
    process.exit(1);
  }
}
