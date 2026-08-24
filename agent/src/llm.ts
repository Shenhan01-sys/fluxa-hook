import type { Config } from "./config.js";

export interface FairPriceResult {
  price: number;        // in USDC units (e.g. 1.5 = 1 RWA = 1.5 USDC)
  confidence: number;   // 0..1
  rationale: string;    // human-readable explanation
  inputsHash: string;   // hex string of keccak256(inputs) for attestation
}

const SYSTEM_PROMPT = `You are Fluxa, an on-chain AI pricing agent for illiquid real-world asset (RWA) tokens on Uniswap v4.

You are given an RWA instrument metadata and recent market context. Your job: produce a fair price (in USDC units) that a trader should pay for this RWA token right now.

Rules:
1. Output ONLY a JSON object with these exact fields:
   {"price": number, "confidence": number, "rationale": string}
2. "price" — fair price in USDC (1 RWA = N USDC). Use 6 significant figures.
3. "confidence" — 0.0 to 1.0 indicating your confidence in the price.
4. "rationale" — one sentence explaining the key driver (max 200 chars).
5. If you lack enough information, output a price close to the last known price with low confidence.
6. Do not include any markdown, code fences, or text outside the JSON.`;

export async function computeFairPrice(
  cfg: Config,
  marketContext: { volume24h: number; lastTradeTs: number; oraclePrice: number; oracleStale: boolean }
): Promise<FairPriceResult> {
  const inputsBlob = buildInputsBlob(cfg, marketContext);
  const inputsHash = hashInputs(inputsBlob);

  if (cfg.llmProvider === "mock") {
    return mockPricing(cfg, marketContext, inputsHash);
  }

  const prompt = buildUserPrompt(cfg, marketContext);
  let raw: string;

  if (cfg.llmProvider === "groq") {
    if (!cfg.groqApiKey) throw new Error("GROQ_API_KEY not set");
    raw = await callGroq(cfg, prompt);
  } else {
    return mockPricing(cfg, marketContext, inputsHash);
  }

  const parsed = parseLlmJson(raw);
  const clamped = clampPrice(parsed, cfg.rwaMetadata.lastPrice, marketContext.oraclePrice);
  return { ...clamped, inputsHash };
}

function buildInputsBlob(
  cfg: Config,
  ctx: { volume24h: number; lastTradeTs: number; oraclePrice: number; oracleStale: boolean }
): string {
  return JSON.stringify({
    rwa: cfg.rwaMetadata,
    market: ctx,
    agentId: cfg.agentId.toString(),
    ts: Math.floor(Date.now() / 1000),
  });
}

function hashInputs(blob: string): string {
  // Simple non-crypto hash for demo (proof binding). On-chain proof uses keccak256 of full abi-encoded attestation.
  let h = 0x811c9dc5;
  for (let i = 0; i < blob.length; i++) {
    h ^= blob.charCodeAt(i);
    h = Math.imul(h, 0x01000193);
  }
  return ("00000000" + (h >>> 0).toString(16)).slice(-8);
}

function buildUserPrompt(
  cfg: Config,
  ctx: { volume24h: number; lastTradeTs: number; oraclePrice: number; oracleStale: boolean }
): string {
  return `RWA Instrument:
- Name: ${cfg.rwaMetadata.name} (${cfg.rwaMetadata.symbol})
- Description: ${cfg.rwaMetadata.description}
- Last known price (USDC): ${cfg.rwaMetadata.lastPrice}
- Last price timestamp: ${cfg.rwaMetadata.lastPriceTs}

Market context:
- 24h volume (USDC): ${ctx.volume24h}
- Last trade timestamp: ${ctx.lastTradeTs}
- Chronicle oracle price (USDC): ${ctx.oraclePrice}
- Oracle stale (>6h old): ${ctx.oracleStale}

Compute the fair price now. Remember: output only JSON.`;
}

function parseLlmJson(raw: string): { price: number; confidence: number; rationale: string } {
  // Strip code fences if present
  const cleaned = raw.replace(/```json\s*|\s*```/g, "").trim();
  const obj = JSON.parse(cleaned);
  if (typeof obj.price !== "number" || typeof obj.confidence !== "number" || typeof obj.rationale !== "string") {
    throw new Error(`LLM JSON missing fields: ${cleaned}`);
  }
  if (obj.price <= 0 || obj.confidence < 0 || obj.confidence > 1) {
    throw new Error(`LLM returned invalid price/confidence: ${cleaned}`);
  }
  return obj;
}

/**
 * D23.6: Price sanity check + clamp.
 *
 * LLMs hallucinate. We clamp the returned price to a reasonable band around
 * the oracle price and last known price to prevent catastrophic outputs
 * (e.g. 1e18 USDC for a $1 RWA). The attestation still binds to the clamped
 * price — the LLM cannot push an out-of-band price on-chain.
 *
 * Band: [0.1x oracle, 10x oracle] hard bounds.
 * Soft band: if price is outside [0.5x, 2x] of oracle, we re-tag confidence
 * as "low" (≤ 0.5) so downstream consumers (FE display, AVS) can react.
 */
function clampPrice(
  parsed: { price: number; confidence: number; rationale: string },
  lastKnownPrice: number,
  oraclePrice: number
): { price: number; confidence: number; rationale: string } {
  const reference = oraclePrice > 0 ? oraclePrice : lastKnownPrice;
  if (reference <= 0) {
    // No reference at all — can't clamp. Trust LLM but cap at sane maximum.
    return { ...parsed, price: Math.min(parsed.price, 1e9) };
  }

  const HARD_FLOOR = reference * 0.1;
  const HARD_CAP = reference * 10;
  const SOFT_FLOOR = reference * 0.5;
  const SOFT_CAP = reference * 2;

  let { price, confidence, rationale } = parsed;
  let clamped = false;

  if (price < HARD_FLOOR) {
    price = HARD_FLOOR;
    clamped = true;
  } else if (price > HARD_CAP) {
    price = HARD_CAP;
    clamped = true;
  }

  // If outside soft band, force low confidence (downstream can fallback to Mode A)
  if (price < SOFT_FLOOR || price > SOFT_CAP) {
    confidence = Math.min(confidence, 0.5);
  }

  if (clamped) {
    rationale = `Clamped to [${HARD_FLOOR.toFixed(4)}, ${HARD_CAP.toFixed(4)}] (LLM hallucination guard). ${rationale}`;
  }

  return { price, confidence, rationale };
}

async function callGroq(cfg: Config, userPrompt: string): Promise<string> {
  // Groq is OpenAI-compatible: https://api.groq.com/openai/v1/chat/completions
  const res = await fetch("https://api.groq.com/openai/v1/chat/completions", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${cfg.groqApiKey}`,
    },
    body: JSON.stringify({
      model: cfg.groqModel,
      max_tokens: 512,
      temperature: 0.3,           // deterministic-ish for price reasoning
      response_format: { type: "json_object" },
      messages: [
        { role: "system", content: SYSTEM_PROMPT },
        { role: "user", content: userPrompt },
      ],
    }),
  });
  if (!res.ok) {
    const errText = await res.text();
    throw new Error(`Groq API error ${res.status}: ${errText}`);
  }
  const data = await res.json() as {
    choices: { message: { content: string } }[];
  };
  return data.choices[0].message.content;
}

function mockPricing(
  cfg: Config,
  ctx: { volume24h: number; lastTradeTs: number; oraclePrice: number; oracleStale: boolean },
  inputsHash: string
): FairPriceResult {
  // Deterministic heuristic: blend last price + oracle price with volume adjustment.
  // When oracle is stale, give more weight to last price (illiquid — no fresh info).
  const oracleWeight = ctx.oracleStale ? 0.3 : 0.6;
  const blended = oracleWeight * ctx.oraclePrice + (1 - oracleWeight) * cfg.rwaMetadata.lastPrice;

  // Volume premium: low 24h volume → small liquidity discount
  const volumeDiscount = Math.min(0.05, Math.max(0, (10000 - ctx.volume24h) / 200000));
  const price = blended * (1 - volumeDiscount);

  // Confidence: high if oracle fresh and we have volume data
  const confidence = ctx.oracleStale ? 0.55 : 0.82;

  return {
    price: Math.round(price * 1e6) / 1e6,  // 6 decimals like USDC
    confidence,
    rationale: ctx.oracleStale
      ? "Oracle stale — blended last price with low volume discount; low confidence."
      : "Fresh oracle + volume-aware blend; high confidence on illiquid RWA.",
    inputsHash,
  };
}
