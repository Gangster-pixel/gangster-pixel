# Gangster Pixel

**English** | [中文](README.zh-CN.md)

Agent-only pixel NFTs on BNB Chain. This repository holds the **skill** and the **handbook** that let an AI agent (Claude Code, Cursor, Codex, OpenClaw, Binance AI Pro…) mint, craft, burn, trade and claim dividends for its user through the Binance Agentic Wallet.

Website: https://gangsterpixel.com · Data API: https://meta.gangsterpixel.com · Agent handbook: https://meta.gangsterpixel.com/agent.md

## How it works

- Three tiers: **Soldier** (1 unit) · **Captain** (4 units) · **Boss** (16 units). Crafting burns lower-tier NFTs into a higher one.
- Every NFT locks a fixed amount of the project token in a vault contract. Burn it anytime and 90% comes back; 10% stays in the contract and can only be destroyed.
- Holders share the token's outer-market trading tax by weight (100 / 480 / 2400), settled per round with Merkle proofs; claim within 30 days.
- Only Binance Agentic Wallets holding a **.ai Agent ID** can mint, craft, receive or buy. NFTs trade only on the built-in market.
- The skill never holds keys: it reads the chain, builds the transaction, and signing goes through the user's Agentic Wallet (`baw`), with a second confirmation in the Binance App for high-risk actions.

## Quick start (for the user)

1. Binance App → Wallet → Agentic Wallet → create; claim a .ai Agent ID; enable Developer Mode and Trade all tokens; fund a little BNB.
2. Install in your agent environment:

```bash
npm i -g @binance/agentic-wallet
npx skills add binance/binance-skills-hub/skills/binance-web3/binance-agentic-wallet
npx skills add Gangster-pixel/gangster-pixel/skill
pip install web3
```

3. Tell your agent: **"Read https://meta.gangsterpixel.com/agent.md, then show my Gangster status."**

## Commands

| Intent | Command |
|---|---|
| Status, fees, caps, my holdings | `gangster status --address <wallet>` |
| My NFTs | `gangster my --address <wallet>` |
| Mint N soldiers | `gangster mint --count N --address <wallet> --send` |
| Craft a captain / boss | `gangster craft --tier 2\|3 [--ids a,b,c,d] --address <wallet> --send` |
| Burn (refund 90%) | `gangster burn --id N --address <wallet> --send` |
| Listings | `gangster market [--tier t]` |
| List / cancel / buy | `gangster list --id N --price <bnb>` · `cancel --id N` · `cancel-all` · `buy --id N` |
| Batch buy / sweep floor | `gangster buy-many --ids 8@0.01,10` · `gangster sweep --count 3 --max-price 0.02` |
| Claim dividends | `gangster claim --address <wallet> --send` |

Without `--send` every command only prints the transactions to be sent. Full reference: [`skill/SKILL.md`](skill/SKILL.md), [`skill/references/flow.md`](skill/references/flow.md), [`skill/references/market.md`](skill/references/market.md).

## Safety

- Preview → show the user → confirm → send. The skill never chains `--send` on its own.
- Fees are exact: the contract rejects any other amount.
- Crafting burns the ingredient NFTs permanently; their locked tokens merge into the new NFT.
- A transaction that burns several NFTs is flagged high-risk by Binance and needs a second confirmation in the App.

## Layout

```
skill/            the skill (SKILL.md, gangster.py, gangster.json, abi/, references/)
agent.md          single-file handbook for agents (also served at https://meta.gangsterpixel.com/agent.md)
README.zh-CN.md   Chinese README
```

## Contracts

The skill loads them from `https://meta.gangsterpixel.com/skill/gangster.json` on every run and stops if a pinned address differs · also `GET https://meta.gangsterpixel.com/api/stats`. Chain: BNB Smart Chain (56).
