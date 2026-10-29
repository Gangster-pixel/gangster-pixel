# Gangster Pixel

[English](README.md) | **中文**

BNB 链上仅限 AI agent 参与的像素 NFT。这个仓库放的是 **skill** 和给 agent 读的**说明文件**，让 AI agent（Claude Code、Cursor、Codex、OpenClaw、Binance AI Pro 等）通过币安 Agentic Wallet 替用户 mint、合成、退币、买卖和领取分红。

网站：https://gangsterpixel.com · 数据接口：https://meta.gangsterpixel.com · agent 手册：https://meta.gangsterpixel.com/agent.md

## 玩法

- 三级：**小弟**（1 当量）· **骨干**（4 当量）· **头目**（16 当量）。合成是烧掉低级 NFT 换高级。
- 每张 NFT 把固定数量的项目代币锁进金库合约。随时可以烧掉退币，拿回 90%；10% 留在合约里，只能被销毁。
- 持有人按权重（100 / 480 / 2400）分代币的外盘交易税，按期结算、用 Merkle 证明领取，30 天内有效。
- 只有持 **.ai Agent ID** 的币安 Agentic Wallet 能 mint、合成、接收和购买。NFT 只在自家市场成交。
- skill 不保管任何私钥：它只读链、组交易，签名经用户自己的 Agentic Wallet（`baw`），高风险操作需在币安 App 二次确认。

## 快速开始（给用户）

1. 币安 App → 钱包 → Agentic Wallet → 创建；领取 .ai Agent ID；打开 Developer Mode 和 Trade all tokens；充少量 BNB。
2. 在你的 agent 环境里安装：

```bash
npm i -g @binance/agentic-wallet
npx skills add binance/binance-skills-hub/skills/binance-web3/binance-agentic-wallet
npx skills add Gangster-pixel/gangster-pixel/skill
pip install web3
```

3. 对 agent 说：**「读 https://meta.gangsterpixel.com/agent.md，然后看看我的 Gangster 状态」**

## 命令

| 意图 | 命令 |
|---|---|
| 状态、费用、限量、我的持仓 | `gangster status --address <钱包>` |
| 我的 NFT | `gangster my --address <钱包>` |
| mint N 张小弟 | `gangster mint --count N --address <钱包> --send` |
| 合成骨干 / 头目 | `gangster craft --tier 2\|3 [--ids a,b,c,d] --address <钱包> --send` |
| 退币（拿回 90%） | `gangster burn --id N --address <钱包> --send` |
| 看挂单 | `gangster market [--tier t]` |
| 挂单 / 撤单 / 购买 | `gangster list --id N --price <bnb>` · `cancel --id N` · `cancel-all` · `buy --id N` |
| 批量购买 / 扫地板 | `gangster buy-many --ids 8@0.01,10` · `gangster sweep --count 3 --max-price 0.02` |
| 领分红 | `gangster claim --address <钱包> --send` |

不加 `--send` 时每条命令只打印要发的交易。完整说明见 [`skill/SKILL.md`](skill/SKILL.md)、[`skill/references/flow.md`](skill/references/flow.md)、[`skill/references/market.md`](skill/references/market.md)（英文）。

## 安全

- 先预览 → 给用户看 → 用户确认 → 再发送。skill 不会自己连发 `--send`。
- 手续费金额是精确的，合约拒绝任何不一致的金额。
- 合成会永久烧掉作为材料的 NFT，它们锁定的代币合并进新 NFT。
- 一笔烧多张 NFT 的交易会被币安判为高风险，需要在 App 里二次确认。

## 目录

```
skill/            skill 本体（SKILL.md、gangster.py、gangster.json、abi/、references/）
agent.md          给 agent 读的单文件手册（网站上也有：https://meta.gangsterpixel.com/agent.md）
README.md         英文 README
```

## 合约地址

skill 每次运行都从 `https://meta.gangsterpixel.com/skill/gangster.json` 读取，固定的地址和网站不一致时会停下，也可以看 `GET https://meta.gangsterpixel.com/api/stats`。链：BNB Smart Chain（56）。
