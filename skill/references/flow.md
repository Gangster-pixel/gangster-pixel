# Mint / craft / burn / claim

All amounts in output are human-readable (tokens with 18 decimals applied, BNB in ether units).

## `gangster status --address <addr>`

Read-only. `unitTokens` = tokens locked per unit. `mintFeePerUnitBNB` / `burnFeePerUnitBNB` are per unit (soldier ×1, captain ×4, boss ×16).
`minted` / `maxMint` are lifetime counters (burned NFTs do not free a slot).
`me` block: `isAgent`, `highestTier`, `held` per tier, `claimableRounds`, `tokenBalance`, `allowanceToVault`, `marketApproved`.

## `gangster my --address <addr>`

Lists the wallet's NFTs with `tier`, `units`, `lockedTokens`, `seed` (random image seed; the seed → image mapping lives on the metadata server and is fixed at mint).

## Mint

`gangster mint --count N --address <addr>` → up to two txs: `approve` (only if the allowance is short) then `mint(N)` with `value = feePerUnit × N`.
Locks `UNIT × N` tokens. Fails early if the wallet has too few tokens, no Agent ID, or minting is paused. Soldiers are uncapped.

## Craft

`gangster craft --tier 2 --ids 1,2,3,4` burns four soldiers for one captain (fee = feePerUnit × 4).
`gangster craft --tier 3 [--ids …]` needs 16 units: 16 soldiers, 4 captains, or any mix whose units sum to 16 (fee = feePerUnit × 16).
Without `--ids` the CLI picks from the wallet's NFTs (captains first for a boss). Ingredients must all be below the target tier and owned by the sender.
Boss may be limited per wallet (`WalletCap`) and in total (`TierSoldOut`). Burning several NFTs in one tx usually needs a second confirmation in the Binance App.

## Burn

`gangster burn --id N --address <addr>` → one tx, `value = burnFeePerUnit × units`. Returns 90% of `UNIT × units` tokens to the wallet; 10% stays in the vault (deflation). Works even when minting is paused.

## Claim

`gangster claim --address <addr>` → looks up every open round (not expired, not yet claimed, address present in the round file), verifies each proof on-chain with `claimable`, then sends one `claimMany` tx. Dividends are paid in BNB to the wallet.
Weights per unit: soldier 1.0 / captain 1.2 / boss 1.5 (constants 100 / 480 / 2400 on the distributor). A round's snapshot block is fixed in the round; holdings after the snapshot do not count for that round.
Round files are fetched from `gangster.json` → `rounds` (URL template with `{id}`) or from the uri recorded on-chain.
