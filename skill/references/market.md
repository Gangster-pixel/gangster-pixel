# Market (BNB-priced, non-custodial)

The market is the only operator allowed by the vault, so Gangster NFTs trade only here. Listings do **not** escrow: the NFT stays in the seller's wallet (still the seller's avatar, still earns dividends) and the market transfers it at purchase time.

## `gangster market [--tier t] [--limit n]`

Read-only. Returns active listings (`id`, `tier`, `priceBNB`, `seller`, `lockedTokens`), sorted by tier then price. Stale listings are filtered with the contract's `isActive`.

## `gangster list --id N --price <bnb> --address <addr>`

Up to two txs: `setApprovalForAll(market, true)` (first time only) then `list(id, price)`. Listing again with a new price just overwrites.
A listing stays valid until: the NFT changes hands, the seller revokes the market approval, the seller runs `cancel` / `cancel-all`, or the market is removed from the vault's operator allow-list. Re-approving never revives an old listing.

## `gangster cancel --id N` / `gangster cancel-all`

`cancel` removes one listing. `cancel-all` bumps the seller's epoch so every listing of that wallet becomes invalid in one tx.

## `gangster buy --id N --address <addr>`

Checks the listing is active and the buyer can receive (Agent ID required while public mint is closed), then one tx `buy(id)` with `value = price`.
The market fee (`feeBps`, capped at 5%) is taken from the price: the seller receives `price − fee`. If the fee rate changed after listing, the lower of the two applies.

## Batch buys

Both commands allow **partial fills**: one `buy` tx per listing, sent in order; a listing that was sold, cancelled or re-priced above its cap before its turn is skipped and the rest continue. Without `--send` they print `planned`, `skipped` (with reasons), `plannedTotalBNB` and the transactions; with `--send` the result adds `bought`, `failed`, `filled` (e.g. `3/5`) and `spentBNB`.

### `gangster buy-many --ids <list> [--max-price <bnb>] --address <addr>`

`--ids` is comma-separated; each id may carry its own price cap after `@`, e.g. `8@0.000012,10@0.000021,14`. `--max-price` caps every id. The website's "Select to buy" prompt passes each listing at the price the user saw, so a later price increase is skipped.

### `gangster sweep --count N [--max-price <bnb>] [--tier t] --address <addr>`

Buys the N cheapest active listings (optionally one tier) priced at or below `--max-price`. Listings are picked when the command runs, so the result follows the market at that moment; if fewer than N match, it buys as many as match.

Without `--send` it prints `planned`, `plannedTotalBNB` and a `confirmCommand`: a `buy-many --ids id@price,… --send` that buys exactly the previewed listings at no more than the previewed prices. Use that after the user confirms. `sweep --send` re-picks the floor at send time; without `--max-price` that has no price bound, so the CLI adds a warning.

