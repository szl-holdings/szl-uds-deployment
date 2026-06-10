#!/usr/bin/env bash
# Copyright 2026 SZL Holdings
# SPDX-License-Identifier: Apache-2.0
#
# reset-receipt-chain.sh — prune the in-cluster szl-receipts chain to a small,
# valid, hash-chained baseline (genesis + a handful of server-signed receipts).
#
# WHY: the receipt-on-deploy webhook plus repeated rehearsals can grow the chain
# on the receipts data PVC to tens/hundreds of thousands of receipts (hundreds of
# MB). That bloat forces an oversized memory limit and slows boot rehydration.
# For a live demo the chain only needs a tiny, still-valid baseline so the server
# boots fast and fits its normal 512Mi limit.
#
# HOW (safe, repeatable):
#   1. Empty the store dir + head pointer ON the running pod. This clears BOTH the
#      legacy flat-root receipts (<store>/*.json) AND the sharded layout
#      (<store>/shards/<bucket>/*.json) the server uses once the chain grows past
#      SZL_RECEIPT_SHARD_SIZE (default 10000) — a large/bloated chain (exactly the
#      case that needs a reset) is almost always sharded, so wiping only the flat
#      root would silently leave the bulk of the chain behind.
#   2. DELETE the pod (NOT `rollout restart`): the deployment uses RollingUpdate
#      maxSurge>0, which on a single-node RWO PVC would try to schedule a second
#      pod that can never attach the volume -> deadlock. On a MULTI-NODE cluster
#      (e.g. the tower) the surge pod can also land on a different node that
#      cannot attach the RWO volume — same deadlock. Deleting the one pod is
#      node-agnostic and lets the controller recreate it cleanly once the volume
#      is free.
#   3. The new pod boots from an empty store -> chain_index=0, head=GENESIS.
#   4. Seed N receipts THROUGH the server's POST /receipt so every receipt is
#      really Ed25519-signed and properly chained (the server is the signer).
#   5. Verify: 2/2 Running, /healthz 200, /pubkey signed, POST valid:true,
#      /metrics szl_chain_valid==1 and szl_chain_length==N.
#
# This script is idempotent: re-running it always lands the same small baseline.
#
# Usage:
#   scripts/reset-receipt-chain.sh --yes            # reset to default SEED receipts
#   SEED=5 scripts/reset-receipt-chain.sh --yes     # custom baseline size
#   scripts/reset-receipt-chain.sh                  # dry-run (prints plan, no change)
#
# Target a non-default cluster (e.g. the tower) without switching your current
# kube-context by exporting KCONTEXT:
#   KCONTEXT=tower-context scripts/reset-receipt-chain.sh           # dry-run on tower
#   KCONTEXT=tower-context scripts/reset-receipt-chain.sh --yes     # reset on tower
set -euo pipefail

NS="${NS:-szl-receipts}"
DEPLOY="${DEPLOY:-szl-receipts-server}"
CONTAINER="${CONTAINER:-receipts-server}"
SELECTOR="${SELECTOR:-app.kubernetes.io/name=szl-receipts-server}"
STORE="${STORE:-/data/receipts}"
PORT="${PORT:-8080}"
SEED="${SEED:-3}"
TIMEOUT="${TIMEOUT:-120s}"
KCONTEXT="${KCONTEXT:-}"

# All kubectl calls go through KC so an optional --context applies everywhere
# (informational reads, exec/wipe, pod delete, rollout/wait).
KC=(kubectl)
[ -n "$KCONTEXT" ] && KC=(kubectl --context "$KCONTEXT")

CONFIRM="no"
[ "${1:-}" = "--yes" ] && CONFIRM="yes"

log() { printf '[reset-receipt-chain] %s\n' "$*"; }

pod() { "${KC[@]}" get pod -n "$NS" -l "$SELECTOR" \
          -o jsonpath='{.items[0].metadata.name}' 2>/dev/null; }

# Count receipts across BOTH the legacy flat root and the sharded buckets so the
# "current chain" figure is honest on a large (sharded) chain too.
count_on_disk() {
  "${KC[@]}" exec -n "$NS" "$1" -c "$CONTAINER" -- \
    sh -c "find $STORE -type f -name '*.json' 2>/dev/null | wc -l" 2>/dev/null | tr -d '[:space:]'
}

log "target context: ${KCONTEXT:-<current kube-context>}  ns: $NS  deploy: $DEPLOY"

P="$(pod)"
[ -n "$P" ] || { log "ERROR: no $SELECTOR pod found in ns $NS"; exit 1; }

BEFORE="$(count_on_disk "$P")"
BYTES="$(${KC[@]} exec -n "$NS" "$P" -c "$CONTAINER" -- du -sh "$STORE" 2>/dev/null | awk '{print $1}')"
log "current chain: ${BEFORE:-?} receipts (${BYTES:-?}) on pod $P"
log "plan: wipe store (flat + shards) -> delete pod -> reboot to genesis -> seed $SEED signed receipts"

if [ "$CONFIRM" != "yes" ]; then
  log "DRY-RUN (no changes). Re-run with --yes to perform the reset."
  exit 0
fi

# 1. wipe persisted chain + head pointer on the live volume (flat root AND shards)
log "wiping $STORE on pod $P (flat *.json + .chain_head + shards/) ..."
"${KC[@]}" exec -n "$NS" "$P" -c "$CONTAINER" -- \
  sh -c "rm -f $STORE/*.json $STORE/.chain_head; rm -rf $STORE/shards; find $STORE -type f | wc -l"

# 2. delete the pod (no surge) so the new one boots from the empty store
log "deleting pod $P (avoids RollingUpdate RWO-PVC surge deadlock) ..."
"${KC[@]}" delete pod -n "$NS" "$P" --wait=true

# 3. wait for the fresh pod to be Ready (2/2)
log "waiting for a new Ready pod ..."
"${KC[@]}" rollout status deploy/"$DEPLOY" -n "$NS" --timeout="$TIMEOUT"
"${KC[@]}" wait --for=condition=ready pod -n "$NS" -l "$SELECTOR" --timeout="$TIMEOUT"
P="$(pod)"
log "new pod: $P"

# 4. seed a handful of receipts through the server (real Ed25519 signatures)
log "seeding $SEED baseline receipts via POST /receipt ..."
"${KC[@]}" exec -i -n "$NS" "$P" -c "$CONTAINER" -- python3 - "$SEED" "$PORT" <<'PY'
import json, sys, time, urllib.request
n = int(sys.argv[1]); port = sys.argv[2]
url = f"http://127.0.0.1:{port}/receipt"
ok = 0
for i in range(n):
    body = json.dumps({
        "action": "baseline",
        "subject": f"warhacker-clean-baseline-{i}",
        "note": "clean-reset baseline seed",
    }).encode()
    req = urllib.request.Request(url, data=body,
                                 headers={"Content-Type": "application/json"})
    r = urllib.request.urlopen(req, timeout=10)
    resp = json.loads(r.read().decode())
    print(f"  seed {i}: status={r.status} valid={resp.get('valid')} "
          f"chain_index={resp.get('chain',{}).get('chain_index')}")
    if r.status == 200 and resp.get("valid"):
        ok += 1
    time.sleep(0.25)  # stay under the ingest rate limit
print(f"seeded {ok}/{n} valid receipts")
sys.exit(0 if ok == n else 1)
PY

# 5. verify the new baseline
log "verifying baseline ..."
"${KC[@]}" exec -i -n "$NS" "$P" -c "$CONTAINER" -- python3 - "$PORT" "$SEED" <<'PY'
import json, sys, urllib.request
port = sys.argv[1]; seed = int(sys.argv[2])
def get(path):
    return urllib.request.urlopen(f"http://127.0.0.1:{port}{path}", timeout=5).read().decode()
hz = json.loads(get("/healthz")); assert hz.get("status") == "ok", hz
pk = json.loads(get("/pubkey")); assert pk.get("signed") is True, pk
m = {}
for line in get("/metrics").splitlines():
    if line and not line.startswith("#"):
        k, _, v = line.partition(" ")
        m[k] = v.strip()
clen = int(float(m.get("szl_chain_length", "-1")))
cvalid = int(float(m.get("szl_chain_valid", "-1")))
print(f"  /healthz ok  /pubkey signed=True keyid={pk.get('keyid')}")
print(f"  szl_chain_length={clen} szl_chain_valid={cvalid}")
assert cvalid == 1, "chain not valid"
assert clen == seed, f"expected {seed} receipts, got {clen}"
print("VERIFY OK: small, valid, hash-chained baseline")
PY

log "done. baseline = $SEED signed receipts, chain valid."
