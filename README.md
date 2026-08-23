# Fluxa — RWA Exit Liquidity Hook

> **Fluxa turns frozen RWA into flow.** A Uniswap v4 hook that gives real-world asset (RWA) liquidity an instant exit.

Fluxa is a single Uniswap v4 hook managing the full liquidity lifecycle of RWA positions through three pricing modes, coordinated by autonomous AI agents:

- **Mode A — Yield Allocation:** idle vault capital routes into an internal v4 swap pool with custom accounting (CSMM pattern via ERC-6909 claims). LPs earn yield and can exit instantly — no withdrawal queue.
- **Mode B — AI-Inferred Pricing:** for illiquid RWAs with no live oracle, an autonomous AI agent (ERC-7857 NFT in TEE) attests a fair price via Chronicle, enabling instant exit at a modeled mark instead of a months-long queue.
- **Mode C — Sealed-Bid Resolution:** on default or stale oracle, the hook freezes the pool and runs a sealed-bid commit-reveal auction among registered liquidators, resolving bad debt in minutes instead of seasons.

**The problem:** $38.29B tokenized RWAs across 1.79M holders (+58%/mo), yet Goldfinch FIDU holders face a ~1-year withdrawal queue at 100% utilization — trading at a 26% NAV discount just to exit. The exit layer is missing. Fluxa is that layer.

## Architecture

```
LP/User ──► PoolManager (Uniswap v4 singleton)
                 │ callbacks (onlyPoolManager)
                 ▼
            FluxaHook ──── State machine: Normal ⇄ Distress ⇄ Resolution
            ├─ Mode A: oracle pricing + dynamic fee + internal pool yield route
            ├─ Mode B: TEE-attested agent pricing (AgentPricing library)
            └─ Mode C: sealed-bid auction (commit/reveal/settle)
                 │
    ┌────────────┼────────────────┐
    ▼            ▼                ▼
ERC-6909      Chronicle       ERC-8004
LP Shares     Oracle          Reputation Gate
```

Key design points:
- **Hook is the only primitive that moves funds.** The AI agent is the actor; the hook enforces every rule on-chain.
- **Yield accumulates as unspent claims in the PoolManager** — LP shares appreciate automatically without extra transfers (flash accounting net-zero deltas maintained).
- Every state transition emits `HookSwap` / `HookFee` / `ModeBSwap` events per the Atrium standard, feeding the ERC-8004 reputation loop.
- Deterministic `quote()` + `getPoolMetadata()` views for router/solver integration.

## Partner Integrations

| Partner / Standard | Role |
|---|---|
| **Uniswap v4** | Core venue: singleton PoolManager, hooks, flash accounting, ERC-6909 claims |
| **OpenZeppelin** | `BaseCustomAccountingHook` pattern (extend-don't-fork), SafeERC20, Ownable, ReentrancyGuardTransient |
| **Chronicle Oracle** | Verified Asset Oracle: `readPrice`/`isDefaulted`/`isUnbacked` (Mode A) + TEE attestation verification (Mode B) |
| **ERC-8004** | Reputation registry — gate for agents in `beforeAddLiquidity` (threshold enforced on-chain) |
| **ERC-7857** | Autonomous agent identity as NFT (TEE-held strategy) |
| **EigenLayer AVS** | Validation stub for agent decision re-execution (roadmap) |

## Tech Stack

- **Foundry** (solc 0.8.26, EVM cancun, via-ir, fuzz runs ≥10,000)
- **@uniswap/v4-core** + **@uniswap/v4-periphery** + **forge-std** + **OpenZeppelin** + **solmate**
- Frontend: [fluxa-fe](https://github.com/Shenhan01-sys/fluxa-fe) — Next.js 16 + wagmi v3 + viem v2 + Tailwind v4

## Getting Started

```bash
git clone https://github.com/Shenhan01-sys/fluxa-hook
cd fluxa-hook
forge install
forge test          # 47/47 tests passing
```

Deploy to Base Sepolia (see [DEPLOY.md](DEPLOY.md)):

```bash
export PRIVATE_KEY=0x...
forge script script/DeployFluxaHook.s.sol \
  --rpc-url https://sepolia.base.org \
  --broadcast --private-key $PRIVATE_KEY -vvv
```

The deploy script mines a CREATE2 salt via HookMiner so the hook address encodes its exact permission flags (`0x1AC8`): `AFTER_INITIALIZE | BEFORE_ADD_LIQUIDITY | BEFORE_REMOVE_LIQUIDITY | BEFORE_SWAP | AFTER_SWAP | BEFORE_SWAP_RETURNS_DELTA`.

## Security

- Slither static analysis: **0 critical, 0 high**, 2 medium (mitigated), 11 low — risk score 11/33 (Medium)
- Manual review per v4-security-foundations checklist: `onlyPoolManager` on all callbacks, CEI pattern in all modes, `nonReentrant` on user-facing functions, delta accounting verified (`sum(deltas) == 0`)
- Full report: [SECURITY_REPORT.md](SECURITY_REPORT.md)

## Repository Layout

```
src/
├── FluxaHook.sol          # Main hook: 3 pricing modes + lifecycle state machine
├── FluxaLPShares.sol      # ERC-20 LP shares (hook-only mint/burn gates)
├── libraries/AgentPricing.sol   # Mode B curve math (attested price → BeforeSwapDelta)
├── interfaces/            # IChronicleOracle, IERC8004Registry, IFluxaHook
├── mocks/                 # MockChronicleOracle, MockERC8004, MockERC7857, MockRWAInstrument
└── vendor/BaseHook.sol    # Minimal BaseHook (adapted OZ pattern)
test/                      # FluxaHook.t.sol, ModeB.t.sol, ModeC.t.sol, Tao.t.sol
script/                    # DeployFluxaHook.s.sol (HookMiner CREATE2)
```

---

*Built for the Uniswap Hook Incubator #10 (Atrium Academy) Hookathon. Deployed on Base.*
