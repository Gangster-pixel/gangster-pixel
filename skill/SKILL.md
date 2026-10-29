---
name: gangster
description: |
  Use when the user wants to mint, craft, burn, list, buy, or check Gangster Pixel NFTs — the agent-only
  NFT collection on BNB Chain built on top of a gang.fun token. Every NFT locks a fixed amount of the
  project token; burning it returns 90% (10% stays in the vault for the owner to burn, deflation). Only
  Binance Agentic Wallets holding a .ai Agent ID can mint / craft / receive one.
  Triggers: gangster, gangster pixel, soldier / captain / boss NFT, lock tokens for an NFT, craft,
  burn NFT to get tokens back, gangster market / list / buy NFT, gangster dividends / claim,
  my gangster NFTs, highest tier avatar.
metadata:
  author: gangsterpixel
  version: '0.2.0'
  requires:
    bins: [baw, python3]
  install:
    - kind: node
      package: '@binance/agentic-wallet'
      bins: [baw]
      label: Binance Agentic Wallet CLI
    - kind: pip
      package: web3
      label: web3.py (the CLI reads the chain with it)
---

# Gangster Pixel Skill

Gangster Pixel is a three-tier NFT collection on BNB Chain. Each NFT is a **vault receipt**: it holds a fixed
number of the project token (the token is launched on gang.fun; NFT features open **after graduation**).

| Tier | Units | How to get | Tokens inside |
|---|---|---|---|
| Soldier (1) | 1 | `mint`: lock `UNIT` tokens | UNIT |
| Captain (2) | 4 | `craft --tier 2`: burn 4 units of lower NFTs | 4 × UNIT |
| Boss (3) | 16 | `craft --tier 3`: burn 16 units (16 soldiers, 4 captains, or a mix) | 16 × UNIT |

- **burn** any NFT any time → 90% of the locked tokens come back (`refundOf`); 10% stays in the vault and can only be sent to 0xdead by the owner. Fee = `burnFeePerUnit × units` BNB.
- mint / craft fee = `feePerUnitFor(address) × units` BNB (shown by `status`; the owner can only lower fees).
- **Agent-gated**: minting, crafting and *receiving* an NFT all require a .ai Agent ID (`NO_AGENT_ID` otherwise).
- Transfers are guarded: only the Gangster market may act as operator; no other marketplace works.
- **Dividends are paid per round.** The team settles the token's outer-market tax periodically: a block snapshot of every holder, weights soldier 100 / captain 480 / boss 2400, a public round file with each address's amount + Merkle proof, and the BNB funded into `GangsterDistributor`. Holders `claim` within the round's expiry (30 days). `status` shows the latest round and `me.claimableRounds`.
- Avatar = highest tier held (`status` → `me.highestTier`). Captain / boss may be limited.

All commands read the chain and build calldata; **signing goes through the user's Agentic Wallet via `baw`**. Nothing holds keys.

Run from the skill folder: `python gangster.py <cmd> --address <wallet> [...]`. The wallet address: `baw wallet address --json`.
Contract addresses come from the website (`configUrl` in `gangster.json`, https://meta.gangsterpixel.com/skill/gangster.json) on every run. If `gangster.json` pins addresses and the website lists different ones, every command stops with `contract addresses changed`: re-install the skill, never edit the addresses by hand.

## Command routing

| User intent | Command | Reference |
|---|---|---|
| Project status / fees / limits / my holdings | `gangster status --address 0x…` | [flow.md](references/flow.md) |
| My NFTs | `gangster my --address 0x…` | [flow.md](references/flow.md) |
| Mint soldiers | `gangster mint --count N --address 0x…` | [flow.md](references/flow.md#mint) |
| Craft captain / boss | `gangster craft --tier 2\|3 [--ids a,b,c,d] --address 0x…` | [flow.md](references/flow.md#craft) |
| Burn to get tokens back | `gangster burn --id N --address 0x…` | [flow.md](references/flow.md#burn) |
| See listings | `gangster market [--tier t] [--limit n]` | [market.md](references/market.md) |
| List / cancel / buy | `gangster list --id N --price <bnb>` · `cancel --id N` · `cancel-all` · `buy --id N` (all with `--address`) | [market.md](references/market.md) |
| Buy several by id | `gangster buy-many --ids 8@0.01,10,14@0.02 [--max-price <bnb>] --address 0x…` | [market.md](references/market.md#batch-buys) |
| Sweep the floor | `gangster sweep --count N [--max-price <bnb>] [--tier t] --address 0x…` | [market.md](references/market.md#batch-buys) |
| Claim dividends | `gangster claim --address 0x…` | [flow.md](references/flow.md#claim) |

Every command prints JSON. Without `--send` it returns `transactions: [{to, data, value, description}]` to be sent **in order**
with `baw contract-call preview --binanceChainId 56 --from <addr> --to <to> --value <value> --inputData <data> --json`
then `baw contract-call execute --requestId <id> --json`. With `--send` the CLI does that itself and returns `sent: [...]`.

## Hard rules

- **Preview → show → confirm → execute.** Show the user every `description`, the BNB fee and (for mint) the tokens that will be locked, and get an OK before sending. Never chain `--send` unless the user skipped confirmation.
- **Fees are exact.** Each tx's `value` must be sent as returned; the contract rejects any other amount (`WrongFee`).
- **Tokens are not lost.** Burning returns 90% of the locked amount; crafting merges the locked tokens into the new NFT. Say so when the user hesitates.
- **Crafting burns the ingredients permanently.** Confirm the ids with the user (`--ids`), or show the auto-picked ids before sending.
- **Binance App double-confirm.** A tx that burns several NFTs at once (craft) is flagged high-risk by the Agentic Wallet: `execute` returns `PENDING_CONFIRMATION` and the user must approve it in the Binance App. The CLI waits up to 10 minutes; tell the user to open the App.
- **Buying pays the listed price exactly**; the market fee is already inside the price (the seller gets price − fee).
- **Batch buys allow partial fills.** `buy-many` / `sweep` buy one listing per tx; anything sold, cancelled, re-priced above the cap or unaffordable is skipped and the rest continue. Show the user `planned` / `skipped` and the total first; after sending, report `bought`, `failed` and `filled`.
- **Listings don't escrow.** A listed NFT stays in the seller's wallet; it still counts as avatar and earns dividends. Transferring it elsewhere voids the listing.
- **No investment advice.** Prices and listings are data.
- **Errors**: `NO_AGENT_ID` → the wallet has no .ai Agent ID (claim one from the Agentic Wallet banner in the Binance App); `TokenNotSet` → token not graduated yet; `TierSoldOut` / `WalletCap` → limits reached; `minting is paused` → paused by the owner (burn still works).
