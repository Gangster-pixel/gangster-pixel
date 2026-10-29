#!/usr/bin/env python3
# gangster CLI: reads the chain and builds calldata; signing / broadcasting always goes through
# the Binance Agentic Wallet CLI (`baw contract-call`). Nothing here holds keys.
# Usage: python gangster.py <cmd> [options] [--send] [--json]
#   without --send it only prints the transactions to send (to / data / value);
#   with --send it runs baw preview -> execute for each of them in order.
import argparse, json, os, subprocess, sys, time
from pathlib import Path

try:
    from web3 import Web3
except ImportError:
    print(json.dumps({"success": False, "error": "web3 missing: pip install web3"})); sys.exit(1)

HERE = Path(__file__).resolve().parent
CONFIG_URL = "https://meta.gangsterpixel.com/skill/gangster.json"
ADDR_KEYS = ("vault", "market", "distributor")


def load_config():
    # The website copy (configUrl) is the source of truth for contract addresses.
    # - addresses missing locally -> take them from the website (no website, no run)
    # - addresses pinned locally and the website lists different ones -> stop: an old install must never act on old contracts
    # - website unreachable -> keep the local addresses and warn on stderr
    # GANGSTER_CONFIG points at a custom config (local fork / testing) and is used as is.
    if os.getenv("GANGSTER_CONFIG"):
        return json.load(open(os.getenv("GANGSTER_CONFIG"), encoding="utf-8"))
    local = json.load(open(HERE / "gangster.json", encoding="utf-8"))
    url = local.get("configUrl") or CONFIG_URL
    remote, err = None, ""
    try:
        import urllib.request
        req = urllib.request.Request(url, headers={"User-Agent": "gangster-skill", "Cache-Control": "no-cache"})
        remote = json.loads(urllib.request.urlopen(req, timeout=10).read().decode("utf-8"))
        if not all(remote.get(k) for k in ("vault", "market")):
            remote, err = None, "no contract addresses in it"
    except Exception as e:
        err = str(e)[:150]

    def stop(msg):
        print(json.dumps({"success": False, "error": msg}, ensure_ascii=False)); sys.exit(1)

    pinned = [k for k in ADDR_KEYS if local.get(k)]
    if not pinned:
        if not remote:
            stop(f"cannot load contract addresses from {url} ({err}); check the network and retry")
    elif remote:
        diff = [k for k in pinned if remote.get(k) and str(remote[k]).lower() != str(local[k]).lower()]
        if diff:
            stop("contract addresses changed (" + ", ".join(f"{k}: local {local[k]} -> website {remote[k]}" for k in diff)
                 + "). This install is outdated: re-install the skill (see https://meta.gangsterpixel.com/agent.md section 4) before doing anything.")
    else:
        print(f"warning: could not check {url} ({err}); using the addresses in gangster.json", file=sys.stderr)
    for k, v in (remote or {}).items():  # fill what the local file leaves out (addresses, deployBlock, rounds...)
        if not k.startswith("_") and local.get(k) in (None, ""):
            local[k] = v
    return local


CFG = load_config()
RPC = os.getenv("BSC_RPC", CFG["rpc"])
w3 = Web3(Web3.HTTPProvider(RPC, request_kwargs={"timeout": 30}))
try:  # BSC is a POA chain: block extraData exceeds 32 bytes, so reading blocks needs this middleware (name differs between web3 v6 / v7)
    from web3.middleware import ExtraDataToPOAMiddleware as _poa
    w3.middleware_onion.inject(_poa, layer=0)
except ImportError:
    try:
        from web3.middleware import geth_poa_middleware as _poa
        w3.middleware_onion.inject(_poa, layer=0)
    except ImportError:
        pass
ERC20_ABI = json.loads('[{"name":"balanceOf","type":"function","stateMutability":"view","inputs":[{"name":"a","type":"address"}],"outputs":[{"type":"uint256"}]},'
                       '{"name":"allowance","type":"function","stateMutability":"view","inputs":[{"name":"o","type":"address"},{"name":"s","type":"address"}],"outputs":[{"type":"uint256"}]},'
                       '{"name":"approve","type":"function","stateMutability":"nonpayable","inputs":[{"name":"s","type":"address"},{"name":"v","type":"uint256"}],"outputs":[{"type":"bool"}]},'
                       '{"name":"symbol","type":"function","stateMutability":"view","inputs":[],"outputs":[{"type":"string"}]}]')
VAULT = w3.eth.contract(address=Web3.to_checksum_address(CFG["vault"]), abi=json.load(open(HERE / "abi" / "GangsterVault.json")))
MARKET = w3.eth.contract(address=Web3.to_checksum_address(CFG["market"]), abi=json.load(open(HERE / "abi" / "GangsterMarket.json")))
DIST = w3.eth.contract(address=Web3.to_checksum_address(CFG["distributor"]), abi=json.load(open(HERE / "abi" / "GangsterDistributor.json"))) if CFG.get("distributor") else None
TIER_NAME = {1: "soldier", 2: "captain", 3: "boss"}
ERRORS = {}  # custom error selector -> name (web3 does not decode these, so we do it ourselves)
for _abi in (VAULT.abi, MARKET.abi) + ((DIST.abi,) if DIST else ()):
    for _e in _abi:
        if _e["type"] == "error":
            _sig = _e["name"] + "(" + ",".join(i["type"] for i in _e["inputs"]) + ")"
            ERRORS[Web3.keccak(text=_sig)[:4].hex().replace("0x", "")] = _e["name"]
ERRORS["7e273289"] = "ERC721NonexistentToken"


def decode_err(e):
    import re
    m = re.search(r"0x([0-9a-f]{8})", str(e))
    name = ERRORS.get(m.group(1)) if m else None
    return (name + ": " if name else "") + str(e)[:300]
UNITS = {1: 1, 2: 4, 3: 16}
BAW_JS = os.path.join(os.environ.get("APPDATA", ""), "npm", "node_modules", "@binance", "agentic-wallet", "dist", "index.js").replace("\\", "/")


def out(obj):
    print(json.dumps(obj, ensure_ascii=False, indent=2, default=str))


def fail(msg):
    out({"success": False, "error": msg}); sys.exit(1)


def eth(x):
    return f"{x / 1e18:.6f}"


def bnb_exact(wei):
    # full precision, no float rounding: used inside commands that pin a price (id@price)
    from decimal import Decimal
    v = format(Decimal(int(wei)) / Decimal(10**18), "f")
    return v.rstrip("0").rstrip(".") if "." in v else v


AGENT_ID_REGISTRY = "0x60b9262456de011f7d15a54cdd8c48baaa8b022f"


def check_contracts():
    # The addresses come from a config file / the website. Make sure they are one consistent, genuine Gangster set before
    # any command runs: the market must point at this vault and be allowed by it, the distributor must point at this vault,
    # and on BNB Chain the vault must use the real Agent ID registry. A forged config fails here.
    try:
        bad = []
        if MARKET.functions.NFT().call() != VAULT.address or MARKET.functions.VAULT().call() != VAULT.address:
            bad.append("market does not belong to this vault")
        if not VAULT.functions.operatorAllowed(MARKET.address).call():
            bad.append("market is not allowed by the vault")
        if DIST and DIST.functions.VAULT().call() != VAULT.address:
            bad.append("distributor does not belong to this vault")
        if int(CFG.get("chainId", 56)) == 56 and VAULT.functions.AGENT_ID().call().lower() != AGENT_ID_REGISTRY:
            bad.append("vault does not use the Binance Agent ID registry")
    except Exception as e:
        bad = [f"cannot read the contracts ({str(e)[:120]})"]
    if bad:
        fail("contract check failed: " + "; ".join(bad) + ". Do not send anything; re-install the skill from https://github.com/Gangster-pixel/gangster-pixel")


def tok_fmt(x):
    # token amount as a string: whole tokens as an integer, otherwise 18 decimals with trailing zeros stripped
    if x % 10**18 == 0:
        return str(x // 10**18)
    return f"{x // 10**18}.{x % 10**18:018d}".rstrip("0").rstrip(".")  # integer math: no float error


# ---------------------------------------------------------------- baw
def baw(args):
    # Arguments go through process.argv via a file to dodge the Windows command-line length limit.
    # BAW_SSH=user@host runs baw on a remote machine where it is already signed in (arguments via stdin).
    ssh = os.getenv("BAW_SSH")
    if ssh:
        js = ("const a=JSON.parse(require('fs').readFileSync(0,'utf8'));process.argv=['node','baw',...a];"
              f"import('{os.getenv('BAW_JS_REMOTE', '/usr/lib/node_modules/@binance/agentic-wallet/dist/index.js')}');")
        key = os.getenv("BAW_SSH_KEY", "")
        cmd = ["ssh", "-o", "StrictHostKeyChecking=no", "-o", "BatchMode=yes"] + (["-i", key] if key else []) + [ssh, "node", "-e", json.dumps(js)]
        p = subprocess.run(cmd, input=json.dumps(args), capture_output=True, text=True, encoding="utf-8", timeout=240)
    elif os.name == "nt" and os.path.exists(BAW_JS):
        f = HERE / "_baw_args.json"
        json.dump(args, open(f, "w", encoding="utf-8"))
        js = ("const fs=require('fs');const a=JSON.parse(fs.readFileSync(process.argv[1],'utf8'));"
              f"process.argv=['node','baw',...a];import('file:///{BAW_JS}');")
        p = subprocess.run(["node", "-e", js, str(f).replace("\\", "/")], capture_output=True, text=True, encoding="utf-8", timeout=180)
    else:
        p = subprocess.run(["baw"] + args, capture_output=True, text=True, encoding="utf-8", timeout=180)
    o = (p.stdout or "") + (p.stderr or "")
    i = o.find("{")
    if i < 0:
        fail(f"no output from baw: {o[:300]}")
    return json.loads(o[i:o.rfind("}") + 1])


class TxFailed(Exception):
    pass


def send_tx(tx, me, strict=True):
    def bad(info):
        if strict:
            fail(info)
        raise TxFailed(json.dumps(info, default=str)[:300])
    pv = baw(["contract-call", "preview", "--binanceChainId", str(CFG["chainId"]), "--from", me, "--to", tx["to"],
              "--value", str(tx["value"]), "--inputData", tx["data"], "--json"])
    if not pv.get("success", True) or "error" in pv:
        bad({"step": tx["description"], "preview": pv})
    rid = pv.get("data", pv).get("requestId")
    nonce0 = w3.eth.get_transaction_count(me)
    ex = baw(["contract-call", "execute", "--requestId", rid, "--json"])
    d = ex.get("data", ex)
    txh = d.get("txHash") or d.get("hash")
    if not txh and d.get("status") == "PENDING_CONFIRMATION":
        # Flagged high-risk by Binance (e.g. burning NFTs): the user must confirm in the Binance App.
        # Wait for the nonce to advance, then find the hash in tx-history by nonce.
        sys.stderr.write(f"Binance App asks for a second confirmation (orderId={d.get('orderId')}). Please confirm in the App; waiting up to 10 minutes.\n")
        t0 = time.time()
        while time.time() - t0 < 600 and not txh:
            time.sleep(10)
            if w3.eth.get_transaction_count(me) <= nonce0:
                continue
            for t in baw(["wallet", "tx-history", "--binanceChainId", str(CFG["chainId"]), "--json"]).get("data", {}).get("transactions", []):
                try:
                    t2 = w3.eth.get_transaction(t["txHash"]) if t.get("txHash") else None
                except Exception:
                    t2 = None
                if t2 and t2["nonce"] == nonce0 and (t2["to"] or "").lower() == tx["to"].lower():
                    txh = t["txHash"]; break
    if not txh:
        bad({"step": tx["description"], "execute": ex})
    r = w3.eth.wait_for_transaction_receipt(txh, timeout=180)
    return {"description": tx["description"], "txHash": txh, "status": "ok" if r.status == 1 else "reverted", "gasUsed": r.gasUsed}


def tx_of(contract, fn, value=0, description=""):
    return {"to": contract.address, "data": fn._encode_transaction_data(), "value": int(value), "description": description}


def finish(txs, args, extra=None):
    res = dict(extra or {})
    res["success"] = True
    if args.send:
        res["sent"] = [send_tx(t, args.address) for t in txs]
        if any(s["status"] != "ok" for s in res["sent"]):
            res["success"] = False
    else:
        res["transactions"] = txs
        res["hint"] = "Send each transaction in order with `baw contract-call preview` / `execute`, or add --send to let this CLI do it."
    out(res)


def me_of(args):
    if not args.address:
        fail("--address is required (your Agentic Wallet address; see `baw wallet address`)")
    return Web3.to_checksum_address(args.address)


def token():
    t = VAULT.functions.token().call()
    if int(t, 16) == 0:
        fail("token not set yet (NFT features open after the token graduates)")
    return w3.eth.contract(address=t, abi=ERC20_ABI)


def my_ids(me):
    # No Enumerable extension: scan Transfer(to=me) logs for candidate ids, then confirm each with ownerOf
    frm = int(CFG.get("deployBlock", 0))
    latest = w3.eth.block_number
    ids = set()
    step = 50000  # publicnode accepts 50k-block windows; the official dataseed node rejects getLogs with "limit exceeded"
    topic = "0x" + Web3.keccak(text="Transfer(address,address,uint256)").hex().lstrip("0x")
    me_topic = "0x" + me[2:].lower().rjust(64, "0")
    for a in range(frm, latest + 1, step):
        logs = w3.eth.get_logs({"address": VAULT.address, "fromBlock": a, "toBlock": min(a + step - 1, latest), "topics": [topic, None, me_topic]})
        for l in logs:
            ids.add(int(l["topics"][3].hex(), 16))
    res = []
    for i in sorted(ids):
        try:
            if VAULT.functions.ownerOf(i).call() == me:
                res.append(i)
        except Exception:
            pass
    return res


def nft_info(i):
    t = VAULT.functions.tierOf(i).call()
    return {"id": i, "tier": t, "tierName": TIER_NAME.get(t), "units": UNITS.get(t), "seed": VAULT.functions.seedOf(i).call().hex(),
            "lockedTokens": tok_fmt(VAULT.functions.lockedOf(i).call())}


# ---------------------------------------------------------------- commands
def cmd_status(args):
    tok = VAULT.functions.token().call()
    r = {
        "vault": VAULT.address, "market": MARKET.address, "token": tok if int(tok, 16) else None,
        "unitTokens": tok_fmt(VAULT.functions.UNIT().call()),
        "mintFeePerUnitBNB": eth(VAULT.functions.mintFeePerUnit().call()),
        "burnFeePerUnitBNB": eth(VAULT.functions.burnFeePerUnit().call()),
        "marketFeePct": MARKET.functions.feeBps().call() / 100,
        "mintPaused": VAULT.functions.mintPaused().call(),
        "publicMintEnabled": VAULT.functions.publicMintEnabled().call(),
        "publicFeePerUnitBNB": eth(VAULT.functions.publicFeePerUnit().call()),
        "burnKeepPct": VAULT.functions.burnKeepBps().call() / 100,
        "retainedTokens": tok_fmt(VAULT.functions.retainedTokens().call()),
        "totalSupply": VAULT.functions.totalSupply().call(),
        "minted": {TIER_NAME[t]: VAULT.functions.mintedByTier(t).call() for t in (1, 2, 3)},
        "maxMint": {TIER_NAME[t]: VAULT.functions.maxMintByTier(t).call() or "unlimited" for t in (2, 3)},
        "maxPerWallet": {TIER_NAME[t]: VAULT.functions.maxPerWalletByTier(t).call() or "unlimited" for t in (1, 2, 3)},
        "listedCount": MARKET.functions.listedCount().call(),
        "totalVolumeBNB": eth(MARKET.functions.totalVolume().call()),
        "dividend": dividend_status(),
    }
    if args.address:
        me = Web3.to_checksum_address(args.address)
        r["me"] = {
            "address": me, "isAgent": VAULT.functions.isAgent(me).call(),
            "highestTier": TIER_NAME.get(VAULT.functions.highestTier(me).call(), "none"),
            "held": {TIER_NAME[t]: VAULT.functions.balanceByTier(me, t).call() for t in (1, 2, 3)},
            "claimableRounds": [{"roundId": x["id"], "amountBNB": eth(x["amount"]), "expiresAt": x["expiresAt"]} for x in my_rounds(me)] if DIST else [],
            "bnb": eth(w3.eth.get_balance(me)),
        }
        if r["token"]:
            tk = w3.eth.contract(address=tok, abi=ERC20_ABI)
            r["me"]["tokenBalance"] = tok_fmt(tk.functions.balanceOf(me).call())
            r["me"]["allowanceToVault"] = tok_fmt(tk.functions.allowance(me, VAULT.address).call())
            r["me"]["marketApproved"] = VAULT.functions.isApprovedForAll(me, MARKET.address).call()
    out({"success": True, **r})


def dividend_status():
    # Dividends: the team settles the outer-market tax per round; GangsterDistributor pays out by block snapshot + Merkle proof.
    d = {"mode": "per-round Merkle (GangsterDistributor)", "distributor": CFG.get("distributor"), "accruedFeesBNB": eth(VAULT.functions.accruedFees().call())}
    if not DIST:
        d["note"] = "distributor not configured"; return d
    try:
        n = DIST.functions.roundCount().call()
        d.update({"rounds": n, "claimExpiryDays": DIST.functions.EXPIRY().call() // 86400,
                  "totalFundedBNB": eth(DIST.functions.totalFunded().call()), "totalClaimedBNB": eth(DIST.functions.totalClaimed().call()),
                  "totalSweptBNB": eth(DIST.functions.totalSwept().call()),
                  "weights": {"soldier": DIST.functions.WEIGHT_SOLDIER().call(), "captain": DIST.functions.WEIGHT_CAPTAIN().call(), "boss": DIST.functions.WEIGHT_BOSS().call()}})
        if n:
            r = DIST.functions.round(n - 1).call()
            d["latest"] = {"roundId": n - 1, "snapshotBlock": r[3], "totalBNB": eth(r[1]), "claimedBNB": eth(r[2]), "fundedAt": r[4], "expiresAt": r[5], "swept": r[6], "uri": r[7]}
    except Exception as e:
        d["error"] = str(e)[:120]
    return d


def load_round(rid):
    # Round file (amounts + Merkle proofs): GANGSTER_ROUNDS (directory or URL template with {id}) first,
    # then the uri recorded on-chain, then rounds/ next to this script.
    import urllib.request
    cands = []
    tpl = os.getenv("GANGSTER_ROUNDS") or CFG.get("rounds")
    if tpl:
        cands.append(tpl.replace("{id}", str(rid)) if "{id}" in tpl else os.path.join(tpl, f"round_{rid}.json"))
    try:
        uri = DIST.functions.round(rid).call()[7]
        if uri.startswith("http"):
            cands.append(uri)
        elif uri.startswith("ipfs://"):
            cands.append("https://ipfs.io/ipfs/" + uri[7:])
    except Exception:
        pass
    cands.append(str(HERE / "rounds" / f"round_{rid}.json"))
    for c in cands:
        try:
            if c.startswith("http"):
                with urllib.request.urlopen(urllib.request.Request(c, headers={"User-Agent": "gangster-skill/1.0"}), timeout=20) as f:  # Cloudflare blocks the default Python UA
                    return json.load(f)
            if os.path.exists(c):
                return json.load(open(c, encoding="utf-8"))
            d = os.path.dirname(c)  # settlement tool naming: <profile>_round_<id>.json
            if os.path.isdir(d):
                for fn in os.listdir(d):
                    if fn.endswith(f"_round_{rid}.json"):
                        return json.load(open(os.path.join(d, fn), encoding="utf-8"))
        except Exception:
            continue
    return None


def my_rounds(me):
    # Rounds still claimable: not expired, not yet claimed, address present in the round file, proof verifies on-chain
    out_ = []
    if not DIST:
        return out_
    now = w3.eth.get_block("latest")["timestamp"]  # expiry judged by chain time
    for rid in range(DIST.functions.roundCount().call()):
        r = DIST.functions.round(rid).call()
        if now > r[5] or DIST.functions.claimed(rid, me).call():
            continue
        data = load_round(rid)
        if not data:
            out_.append({"id": rid, "amount": 0, "expiresAt": r[5], "note": "round file not found"}); continue
        h = next((x for x in data["holders"] if x["address"].lower() == me.lower()), None)
        if not h:
            continue
        amt, proof = int(h["amountWei"]), [bytes.fromhex(p[2:]) for p in h["proof"]]
        if DIST.functions.claimable(rid, me, amt, proof).call():
            out_.append({"id": rid, "amount": amt, "proof": h["proof"], "expiresAt": r[5]})
    return out_


def cmd_my(args):
    me = me_of(args)
    out({"success": True, "address": me, "nfts": [nft_info(i) for i in my_ids(me)]})


WBNB_ABI = [{"name": "deposit", "type": "function", "stateMutability": "payable", "inputs": [], "outputs": []},
            {"name": "symbol", "type": "function", "stateMutability": "view", "inputs": [], "outputs": [{"type": "string"}]},
            {"name": "name", "type": "function", "stateMutability": "view", "inputs": [], "outputs": [{"type": "string"}]}]


def is_wrapped_bnb(tk):
    # true when the vault's locked token is Wrapped BNB, so BNB can be wrapped into it one to one
    try:
        c = w3.eth.contract(address=tk.address, abi=WBNB_ABI)
        return c.functions.symbol().call() == "WBNB" and c.functions.name().call() == "Wrapped BNB"
    except Exception:
        return False


def token_shortfall(tk, need, bal):
    # BNB alone is not enough to mint: the vault locks its token, BNB only pays the fee and gas. Say which token and how to get it.
    try:
        sym = tk.functions.symbol().call()
    except Exception:
        sym = "token"
    how = (f"wrap BNB into {sym} first (ask your Binance Agentic Wallet to swap BNB to {sym}), then mint" if sym.upper() == "WBNB"
           else f"buy {sym} first, e.g. `gang buy --token {tk.address} --amount <bnb>` (gang CLI), then mint")
    return (f"not enough {sym} to lock: need {tok_fmt(need)}, have {tok_fmt(bal)}, short {tok_fmt(need - bal)} {sym} "
            f"(token {tk.address}). Minting locks {sym}; BNB only pays the fee and gas. To fix: {how}.")


def cmd_mint(args):
    me = me_of(args)
    if not VAULT.functions.canParticipate(me).call():
        fail("NO_AGENT_ID: this address has no .ai Agent ID and public mint is not open")
    if VAULT.functions.mintPaused().call():
        fail("minting is paused")
    tk = token()
    unit = VAULT.functions.UNIT().call()
    need = unit * args.count
    bal = tk.functions.balanceOf(me).call()
    fee = VAULT.functions.feePerUnitFor(me).call() * args.count  # agent fee / public fee per unit, read from chain
    txs = []
    wrap = 0
    if bal < need:
        if not is_wrapped_bnb(tk):
            fail(token_shortfall(tk, need, bal))
        # The vault locks WBNB and the wallet holds plain BNB: wrap the missing amount first (WBNB.deposit, 1 BNB -> 1 WBNB)
        wrap = need - bal
        have = w3.eth.get_balance(me)
        if have < wrap + fee:
            fail(f"not enough BNB: wrapping {tok_fmt(wrap)} BNB into WBNB plus the {eth(fee)} BNB mint fee needs {tok_fmt(wrap + fee)} BNB (plus gas), wallet has {tok_fmt(have)} BNB")
        wt = w3.eth.contract(address=tk.address, abi=WBNB_ABI)
        txs.append(tx_of(wt, wt.functions.deposit(), wrap, f"wrap {tok_fmt(wrap)} BNB into WBNB (the vault locks WBNB; you had {tok_fmt(bal)})"))
    if tk.functions.allowance(me, VAULT.address).call() < need:
        txs.append(tx_of(tk, tk.functions.approve(VAULT.address, need), 0, f"approve {tok_fmt(need)} tokens to the vault"))
    txs.append(tx_of(VAULT, VAULT.functions.mint(args.count), fee, f"mint {args.count} soldier(s), lock {tok_fmt(need)} tokens, fee {eth(fee)} BNB"))
    finish(txs, args, {"count": args.count, "lockTokens": tok_fmt(need), "feeBNB": eth(fee), **({"wrapBNB": tok_fmt(wrap)} if wrap else {})})


def cmd_craft(args):
    me = me_of(args)
    target = args.tier
    if target not in (2, 3):
        fail("--tier must be 2 (captain) or 3 (boss)")
    need = UNITS[target]
    if args.ids:
        ids = [int(x) for x in args.ids.split(",")]
    else:
        # auto-pick: lower tiers first, units must add up exactly to the target
        mine = [nft_info(i) for i in my_ids(me)]
        ids, got = [], 0
        for tier in (2, 1) if target == 3 else (1,):
            for n in mine:
                if n["tier"] == tier and got + UNITS[tier] <= need:
                    ids.append(n["id"]); got += UNITS[tier]
            if got == need:
                break
        if got != need:
            fail(f"not enough ingredients: crafting a {TIER_NAME[target]} needs {need} units, you can only gather {got}")
    fee = VAULT.functions.feePerUnitFor(me).call() * need
    txs = [tx_of(VAULT, VAULT.functions.craft(target, ids), fee, f"burn {ids} to craft a {TIER_NAME[target]}, fee {eth(fee)} BNB")]
    finish(txs, args, {"target": TIER_NAME[target], "burnIds": ids, "feeBNB": eth(fee)})


def cmd_burn(args):
    me = me_of(args)
    info = nft_info(args.id)
    fee = VAULT.functions.burnFee(info["tier"]).call()
    refund = VAULT.functions.refundOf(args.id).call()
    keep_pct = VAULT.functions.burnKeepBps().call() / 100
    txs = [tx_of(VAULT, VAULT.functions.burn(args.id), fee, f"burn #{args.id} ({info['tierName']}) and get {tok_fmt(refund)} tokens back (locked {info['lockedTokens']}, {keep_pct:g}% stays in the contract), fee {eth(fee)} BNB")]
    finish(txs, args, {"nft": info, "refundTokens": tok_fmt(refund), "keepPct": keep_pct, "feeBNB": eth(fee)})


def cmd_list(args):
    me = me_of(args)
    price = Web3.to_wei(args.price, "ether")
    txs = []
    if not VAULT.functions.isApprovedForAll(me, MARKET.address).call():
        txs.append(tx_of(VAULT, VAULT.functions.setApprovalForAll(MARKET.address, True), 0, "approve the market contract as operator (once)"))
    txs.append(tx_of(MARKET, MARKET.functions.list(args.id, price), 0, f"list #{args.id} at {args.price} BNB"))
    finish(txs, args, {"id": args.id, "priceBNB": args.price, "nft": nft_info(args.id)})


def cmd_cancel(args):
    finish([tx_of(MARKET, MARKET.functions.cancel(args.id), 0, f"cancel listing #{args.id}")], args)


def cmd_buy(args):
    me = me_of(args)
    l = MARKET.functions.listings(args.id).call()
    if int(l[0], 16) == 0 or not MARKET.functions.isActive(args.id).call():
        fail("no active listing for this id")
    if not VAULT.functions.canReceive(me).call():
        fail("this address cannot receive NFTs right now (no Agent ID while public mint is closed, or a contract not on the allow-list)")
    price = l[1]
    cap = parse_bnb(getattr(args, "max_price", None))
    if cap is not None and price > cap:  # the seller re-priced above what the user saw: never pay more than the cap
        fail(f"price {bnb_exact(price)} BNB is above your --max-price {bnb_exact(cap)} BNB; not buying")
    fee = price * min(MARKET.functions.feeBps().call(), l[5]) // 10000  # fee = min(rate at listing time, current rate)
    txs = [tx_of(MARKET, MARKET.functions.buy(args.id), price, f"buy #{args.id} for {eth(price)} BNB (market fee {eth(fee)} included)")]
    finish(txs, args, {"id": args.id, "priceBNB": eth(price), "seller": l[0], "nft": nft_info(args.id)})


def active_listings():
    rows = []
    n = MARKET.functions.listedCount().call()
    for off in range(0, n, 200):
        for i in MARKET.functions.listedIds(off, 200).call():
            if MARKET.functions.isActive(i).call():
                l = MARKET.functions.listings(i).call()
                rows.append({"id": i, "seller": l[0], "price": l[1], "feeBps": l[5], "tier": VAULT.functions.tierOf(i).call()})
    return rows


def parse_bnb(x):
    return None if x in (None, "") else Web3.to_wei(str(x), "ether")


def buy_batch(args, me, picks, skipped, pin=False):
    # picks: listings to buy, in order. Partial fills are expected: anything that fails is skipped and the rest continue.
    bal = w3.eth.get_balance(me)
    cur_fee = MARKET.functions.feeBps().call()
    plan, total = [], 0
    for r in picks:
        if total + r["price"] > bal:
            skipped.append({"id": r["id"], "reason": "insufficient BNB balance"}); continue
        total += r["price"]
        fee = r["price"] * min(cur_fee, r["feeBps"]) // 10000
        plan.append({**r, "tx": tx_of(MARKET, MARKET.functions.buy(r["id"]), r["price"], f"buy #{r['id']} ({TIER_NAME.get(r['tier'])}) for {eth(r['price'])} BNB (market fee {eth(fee)} included)")})
    res = {"success": True, "partialFillAllowed": True,
           "planned": [{"id": p["id"], "tier": TIER_NAME.get(p["tier"]), "priceBNB": eth(p["price"])} for p in plan],
           "plannedTotalBNB": eth(total), "skipped": skipped, "balanceBNB": eth(bal)}
    if not plan:
        res["success"] = False
        res["error"] = "nothing to buy (all requested listings are gone, above your price cap, or unaffordable)"
        out(res); sys.exit(1)
    if not args.send:
        res["transactions"] = [p["tx"] for p in plan]
        res["hint"] = "Send in order; if one fails (sold or re-priced meanwhile), skip it and continue. Or add --send to let this CLI do that."
        if pin:  # sweep: lock in exactly what was previewed, so confirming never re-picks a different floor at send time
            res["confirmCommand"] = f"gangster buy-many --ids {','.join(str(p['id']) + '@' + bnb_exact(p['price']) for p in plan)} --address {me} --send"
            res["hint"] = "Show 'planned' and 'plannedTotalBNB' to the user. After they confirm, run 'confirmCommand' (it buys exactly these ids at no more than these prices)."
        out(res); return
    bought, failed, spent = [], [], 0
    for p in plan:
        if not MARKET.functions.isActive(p["id"]).call() or MARKET.functions.listings(p["id"]).call()[1] != p["price"]:
            failed.append({"id": p["id"], "reason": "listing gone or re-priced before sending"}); continue
        try:
            r = send_tx(p["tx"], me, strict=False)
        except TxFailed as e:
            failed.append({"id": p["id"], "reason": str(e)[:200]}); continue
        if r["status"] == "ok":
            bought.append({"id": p["id"], "priceBNB": eth(p["price"]), "txHash": r["txHash"]}); spent += p["price"]
        else:
            failed.append({"id": p["id"], "reason": "reverted", "txHash": r["txHash"]})
    res.update({"bought": bought, "failed": failed, "filled": f"{len(bought)}/{len(plan)}", "spentBNB": eth(spent), "success": bool(bought)})
    out(res)


def cmd_buy_many(args):
    # --ids "8@0.000012,10,14@0.00003": optional per-id price cap after @; --max-price caps every item
    me = me_of(args)
    if not VAULT.functions.canReceive(me).call():
        fail("this address cannot receive NFTs right now (no Agent ID while public mint is closed, or a contract not on the allow-list)")
    cap_all = parse_bnb(args.max_price)
    live = {r["id"]: r for r in active_listings()}
    picks, skipped, seen = [], [], set()
    for item in [x.strip() for x in args.ids.split(",") if x.strip()]:
        sid, _, cap = item.partition("@")
        i = int(sid.lstrip("#"))
        if i in seen:
            continue
        seen.add(i)
        caps = [c for c in (parse_bnb(cap) if cap else None, cap_all) if c is not None]
        r = live.get(i)
        if not r:
            skipped.append({"id": i, "reason": "not listed / listing no longer active"}); continue
        if caps and r["price"] > min(caps):
            skipped.append({"id": i, "reason": f"price {eth(r['price'])} BNB above cap {eth(min(caps))} BNB"}); continue
        picks.append(r)
    buy_batch(args, me, picks, skipped)


def cmd_sweep(args):
    # Buy the N cheapest active listings (optionally one tier) within --max-price
    me = me_of(args)
    if args.count <= 0:
        fail("--count must be at least 1")
    if not VAULT.functions.canReceive(me).call():
        fail("this address cannot receive NFTs right now (no Agent ID while public mint is closed, or a contract not on the allow-list)")
    cap = parse_bnb(args.max_price)
    rows = [r for r in active_listings() if (not args.tier or r["tier"] == args.tier)]
    rows.sort(key=lambda r: (r["price"], r["id"]))
    picks = [r for r in rows if cap is None or r["price"] <= cap][: args.count]
    skipped = []
    if cap is None and args.send:
        skipped.append({"warning": "no --max-price: these are bought at whatever the floor is at send time; prefer preview + confirmCommand"})
    if len(picks) < args.count:
        skipped.append({"reason": f"only {len(picks)} listing(s) match (wanted {args.count})" + (f" under the {eth(cap)} BNB cap" if cap is not None else "")})
    buy_batch(args, me, picks, skipped, pin=True)


def cmd_market(args):
    n = MARKET.functions.listedCount().call()
    rows = []
    for off in range(0, n, 200):
        for i in MARKET.functions.listedIds(off, 200).call():
            if not MARKET.functions.isActive(i).call():
                continue
            l = MARKET.functions.listings(i).call()
            rows.append({**nft_info(i), "priceBNB": eth(l[1]), "seller": l[0]})
    rows.sort(key=lambda r: (r["tier"], float(r["priceBNB"])))
    if args.tier:
        rows = [r for r in rows if r["tier"] == args.tier]
    out({"success": True, "count": len(rows), "listings": rows[: args.limit]})


def cmd_cancel_all(args):
    me = me_of(args)
    finish([tx_of(MARKET, MARKET.functions.cancelAll(), 0, "void all my listings (cancelAll)")], args)


def cmd_claim(args):
    me = me_of(args)
    if not DIST:
        fail("distributor not configured")
    rounds = [x for x in my_rounds(me) if x["amount"] > 0]
    if not rounds:
        fail("nothing to claim (no open round, already claimed, or not a holder at the snapshot)")
    ids = [x["id"] for x in rounds]; amts = [x["amount"] for x in rounds]
    proofs = [[bytes.fromhex(p[2:]) for p in x["proof"]] for x in rounds]
    txs = [tx_of(DIST, DIST.functions.claimMany(ids, me, amts, proofs), 0, f"claim {len(ids)} round(s) ≈ {eth(sum(amts))} BNB (rounds {ids})")]
    finish(txs, args, {"rounds": [{"roundId": x["id"], "amountBNB": eth(x["amount"]), "expiresAt": x["expiresAt"]} for x in rounds], "totalBNB": eth(sum(amts))})


def main():
    # Common options are attached to every sub-command so both `gangster status --address 0x…` and `gangster --address 0x… status` work
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--address", help="your Agentic Wallet address", default=os.getenv("BAW_ADDRESS"))
    common.add_argument("--send", action="store_true", help="send the transactions through baw")
    common.add_argument("--json", action="store_true", help="(output is always JSON)")
    p = argparse.ArgumentParser(prog="gangster", parents=[common])
    sp = p.add_subparsers(dest="cmd", required=True)
    sp.add_parser("status", help="project status, fees, limits and my holdings", parents=[common])
    sp.add_parser("my", help="my NFTs", parents=[common])
    a = sp.add_parser("mint", help="lock tokens and mint soldiers", parents=[common]); a.add_argument("--count", type=int, default=1)
    a = sp.add_parser("craft", help="craft a captain / boss", parents=[common]); a.add_argument("--tier", type=int, required=True); a.add_argument("--ids", help="comma-separated ids; auto-picked if omitted")
    a = sp.add_parser("burn", help="burn an NFT and get the tokens back", parents=[common]); a.add_argument("--id", type=int, required=True)
    a = sp.add_parser("list", help="list an NFT for sale", parents=[common]); a.add_argument("--id", type=int, required=True); a.add_argument("--price", type=float, required=True, help="BNB")
    a = sp.add_parser("cancel", help="cancel a listing", parents=[common]); a.add_argument("--id", type=int, required=True)
    a = sp.add_parser("buy", help="buy a listed NFT", parents=[common]); a.add_argument("--id", type=int, required=True); a.add_argument("--max-price", help="refuse if the listing now costs more than this (BNB)")
    a = sp.add_parser("buy-many", help="buy several listings by id (partial fill allowed)", parents=[common]); a.add_argument("--ids", required=True, help="comma-separated ids, each optionally with a price cap: 8@0.01,10,14@0.02"); a.add_argument("--max-price", help="max price per NFT in BNB (applies to every id)")
    a = sp.add_parser("sweep", help="buy the N cheapest listings (partial fill allowed)", parents=[common]); a.add_argument("--count", type=int, required=True); a.add_argument("--max-price", help="max price per NFT in BNB"); a.add_argument("--tier", type=int, help="1 soldier / 2 captain / 3 boss")
    a = sp.add_parser("market", help="show active listings", parents=[common]); a.add_argument("--tier", type=int); a.add_argument("--limit", type=int, default=50)
    sp.add_parser("claim", help="claim dividends", parents=[common])
    sp.add_parser("cancel-all", help="void all my listings in one tx", parents=[common]).set_defaults(func=cmd_cancel_all)
    args = p.parse_args()
    check_contracts()
    try:
        globals()[f"cmd_{args.cmd.replace('-', '_')}"](args)
    except SystemExit:
        raise
    except Exception as e:
        fail(decode_err(e))


if __name__ == "__main__":
    main()
