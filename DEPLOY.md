# Fluxa Hook — Deploy Guide

## Prerequisites

- [Foundry](https://getfoundry.sh/) installed
- A wallet with ETH on Base Sepolia (for deploy gas, ~0.001 ETH needed)
- Private key for deployer wallet

## Deploy to Base Sepolia

```bash
# Set your private key
export PRIVATE_KEY=0x...

# Dry-run (simulation)
forge script script/DeployFluxaHook.s.sol \
  --fork-url https://sepolia.base.org \
  -vvv

# Broadcast (actual deployment)
forge script script/DeployFluxaHook.s.sol \
  --rpc-url https://sepolia.base.org \
  --broadcast \
  --private-key $PRIVATE_KEY \
  -vvv
```

## What Gets Deployed

1. **MockChronicleOracle** — Mock oracle (replace with real Chronicle for production)
2. **MockERC8004** — Mock reputation registry
3. **MockERC7857** — Mock agent NFT
4. **FluxaHook** — The main hook contract (deployed via CREATE2 with correct permission bits)

## Hook Address

The hook is deployed at a CREATE2-mined address with the following permission bits encoded:

| Permission | Flag | Value |
|---|---|---|
| AFTER_INITIALIZE | bit 12 | `1 << 12` |
| BEFORE_ADD_LIQUIDITY | bit 11 | `1 << 11` |
| BEFORE_REMOVE_LIQUIDITY | bit 9 | `1 << 9` |
| BEFORE_SWAP | bit 7 | `1 << 7` |
| AFTER_SWAP | bit 6 | `1 << 6` |
| BEFORE_SWAP_RETURNS_DELTA | bit 3 | `1 << 3` |

**Total flags:** `6856 (0x1AC8)`

The `validateHookPermissions` check in the FluxaHook constructor ensures the deployed address has the exact permission bits required.

## After Deploy

1. Note the **FluxaHook address** from the deploy output
2. Open the FE at http://localhost:3000
3. Paste the FluxaHook address in the Contract Config input
4. Select "Base Sepolia" network
5. Connect wallet and start interacting

## Frontend

```bash
cd ../fluxa-fe
pnpm install
pnpm dev
```

Open [http://localhost:3000](http://localhost:3000) and enter the hook address.

## Verify on BaseScan

```bash
forge verify-contract \
  <HOOK_ADDRESS> \
  src/FluxaHook.sol:FluxaHook \
  --chain base-sepolia \
  --constructor-args $(cast abi-encode "constructor(address,address,address,address,address)" <POOL_MANAGER> <CHRONICLE> <ERC8004> <ERC7857> <OWNER>)
```
