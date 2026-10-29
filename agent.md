# Gangster Pixel — Agent Handbook

> Read this whole file before acting. Every write operation: build the preview, show it to the user, get an explicit OK, then add `--send`.

Website: https://gangsterpixel.com · Data API: https://meta.gangsterpixel.com · Skill repository: https://github.com/Gangster-pixel/gangster-pixel

## 1. What it is

Gangster Pixel is a three-tier NFT collection on BNB Chain: **Soldier** (1 unit) / **Captain** (4 units) / **Boss** (16 units).
Each NFT locks a fixed amount of the project token in a vault contract. Burn it anytime to get 90% of the locked tokens back (10% stays in the contract and can only be destroyed by the owner).
Holders share the token's outer-market trading tax by weight (Soldier 100 / Captain 480 / Boss 2400), settled per round; claim within 30 days.
Only Binance Agentic Wallets holding a **.ai Agent ID** can mint / craft / receive / buy. NFTs trade only on the built-in market.

## 2. Contracts (BSC, chain id 56)

The skill loads the Vault / Market / Distributor addresses from `https://meta.gangsterpixel.com/skill/gangster.json` on every run; `GET https://meta.gangsterpixel.com/api/stats` → `contracts` lists them too.
Agent ID registry: 0x60b9262456de011f7d15a54cdd8c48baaa8b022f

Fees, caps and tokens-per-unit are read from chain: `gangster status`, or `GET https://meta.gangsterpixel.com/api/stats` → `params`.

## 3. What the user needs first

1. Binance App → Wallet → **Agentic Wallet** → create. Claim a **.ai Agent ID** from the banner. In settings enable **Developer Mode** and **Trade all tokens**. Fund a little BNB (fees + gas).
2. Hold the project token (launched on gang.fun; NFT features open after graduation). Buy with the gang CLI: `gang buy --token <CA> --amount 0.1`.

## 4. Install

```bash
# Binance Agentic Wallet CLI + official skill
npm i -g @binance/agentic-wallet
npx skills add binance/binance-skills-hub/skills/binance-web3/binance-agentic-wallet
# gang CLI (to buy the token, optional)
npm i -g @gangfun/cli@latest
# gangster skill — option A: from GitHub
npx skills add Gangster-pixel/gangster-pixel/skill
# gangster skill — option B: download the files
pip install web3
D="$HOME/.claude/skills/gangster"; mkdir -p "$D/references" "$D/abi"
curl -fsSL "https://meta.gangsterpixel.com/skill/SKILL.md" -o "$D/SKILL.md"
curl -fsSL "https://meta.gangsterpixel.com/skill/abi/GangsterDistributor.json" -o "$D/abi/GangsterDistributor.json"
curl -fsSL "https://meta.gangsterpixel.com/skill/abi/GangsterMarket.json" -o "$D/abi/GangsterMarket.json"
curl -fsSL "https://meta.gangsterpixel.com/skill/abi/GangsterVault.json" -o "$D/abi/GangsterVault.json"
curl -fsSL "https://meta.gangsterpixel.com/skill/gangster.json" -o "$D/gangster.json"
curl -fsSL "https://meta.gangsterpixel.com/skill/gangster.py" -o "$D/gangster.py"
curl -fsSL "https://meta.gangsterpixel.com/skill/references/flow.md" -o "$D/references/flow.md"
curl -fsSL "https://meta.gangsterpixel.com/skill/references/market.md" -o "$D/references/market.md"
```

Then tell the agent "log in to my Binance Agentic Wallet" and confirm the pairing code in the Binance App. Wallet address: `baw wallet address --json`.
The session expires after 48 hours idle; just scan again.

## 5. Commands

Run from the skill folder: `python gangster.py <cmd> --address <wallet> [--send]`. Without `--send` the CLI only returns a preview (`transactions: [{to, data, value, description}]`); with `--send` it signs through baw.

| Intent | Command |
|---|---|
| Status, fees, caps, my holdings | `status --address <addr>` |
| My NFTs | `my --address <addr>` |
| Mint N soldiers | `mint --count N --address <addr> --send` |
| Craft a captain / boss | `craft --tier 2|3 [--ids a,b,c,d] --address <addr> --send` |
| Burn (refund) | `burn --id N --address <addr> --send` |
| See listings | `market [--tier t] [--limit n]` |
| List / cancel / cancel all / buy | `list --id N --price <bnb>` · `cancel --id N` · `cancel-all` · `buy --id N` (all with `--address … --send`) |
| Buy several by id (partial fill) | `buy-many --ids 8@0.01,10,14@0.02 [--max-price <bnb>] --address <addr> --send` |
| Sweep the floor (partial fill) | `sweep --count N [--max-price <bnb>] [--tier t] --address <addr> --send` |
| Claim dividends | `claim --address <addr> --send` |

Flow notes:
- **mint**: locks `UNIT × N` tokens + fee `feePerUnit × N` BNB; the first time adds an approve tx. Soldiers are uncapped.
- **craft**: 4 units → Captain, 16 units → Boss (16 soldiers / 4 captains / a mix). Ingredients are burned permanently; their locked tokens merge into the new NFT, nothing is lost; the fee is paid again. Omit `--ids` to auto-pick. Captains and Bosses are capped; one Boss per wallet.
- **burn**: 90% of the locked tokens come back, fee `burnFeePerUnit × units`. Burning and transfers can never be paused.
- **market**: non-custodial; the NFT stays in the seller's wallet and keeps earning. The first listing adds a one-time market approval. Buyers pay the listed BNB price; the fee is inside the price (seller gets price − fee). A transfer, a revoked approval or `cancel-all` voids old listings.
- **batch buys**: `buy-many` / `sweep` send one buy per listing and allow partial fills: sold, cancelled, re-priced or unaffordable listings are skipped. The website's market page can generate a ready-to-paste prompt for either.
- **claim**: one tx claims every open round. Round files (amounts + Merkle proofs) live at `https://meta.gangsterpixel.com/rounds/<id>.json`; the CLI fetches them.

## 6. Hard rules

- Preview → show each description, the BNB fee and the tokens to be locked → user confirms → `--send`.
- Send every `value` exactly as returned; the contract rejects any other amount (`WrongFee`).
- A tx that burns several NFTs (craft) is flagged high-risk by Binance: `execute` returns `PENDING_CONFIRMATION`; ask the user to confirm in the Binance App. The CLI waits up to 10 minutes.
- No investment advice; prices and listings are data.
- Errors: `NO_AGENT_ID` no .ai Agent ID; `TokenNotSet` token not graduated; `TierSoldOut` / `WalletCap` cap reached; `minting is paused` affects only mint / craft.

## 7. Read-only API (no auth, CORS enabled)

- `GET https://meta.gangsterpixel.com/api/stats` overview + chain params + contract addresses
- `GET https://meta.gangsterpixel.com/api/nfts?tier=soldier|captain|boss&offset=0&limit=60` gallery
- `GET https://meta.gangsterpixel.com/api/nft/<id>` one NFT (owner, history, listing, refund)
- `GET https://meta.gangsterpixel.com/api/holder/<address or Agent ID name>` holder page (holdings, units, per-round amounts + proofs, listings, activity)
- `GET https://meta.gangsterpixel.com/api/market` active listings (verified on-chain)
- `GET https://meta.gangsterpixel.com/api/rounds` dividend rounds · `GET https://meta.gangsterpixel.com/rounds/<id>.json` round file
- `GET https://meta.gangsterpixel.com/api/activity?limit=50&kind=mint|craft|burn|sold|list|claim` activity feed
- `GET https://meta.gangsterpixel.com/metadata/<id>` tokenURI JSON · `GET https://meta.gangsterpixel.com/image/<id>.jpg` artwork

## 8. One-line prompts the user can give you

- "Read https://meta.gangsterpixel.com/agent.md, then mint 2 Gangster soldiers for me"
- "Read https://meta.gangsterpixel.com/agent.md, then show my Gangster holdings and claimable dividends"
- "Read https://meta.gangsterpixel.com/agent.md, then list my Gangster #12 for 0.05 BNB"

---

## 中文摘要

- Gangster Pixel 是 BNB 链上的三级 NFT：小弟（1 当量）/ 骨干（4 当量）/ 头目（16 当量）。每张锁定固定数量的项目代币，随时退币拿回 90%；持有人按权重分外盘交易税，按期领取，30 天内有效。只有持 .ai Agent ID 的币安 Agentic Wallet 能参与。
- 用户先准备：币安 App 开通 Agentic Wallet、领取 .ai Agent ID、打开 Developer Mode 和 Trade all tokens、充一点 BNB、持有项目代币。
- 安装：见第 4 节；`npx skills add Gangster-pixel/gangster-pixel/skill` 或按 curl 逐个下载。
- 命令：`status` / `my` / `mint --count N` / `craft --tier 2|3` / `burn --id N` / `market` / `list --id N --price X` / `cancel --id N` / `cancel-all` / `buy --id N` / `claim`，都带 `--address <钱包>`，确认后加 `--send` 才真发。
- 硬规则：先预览给用户看、用户确认再发；金额不能改；一笔烧多张 NFT 会要求在币安 App 二次确认；不给投资建议。
