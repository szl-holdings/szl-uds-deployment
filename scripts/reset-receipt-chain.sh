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
#   1. Empty the store dir + head pointer ON the running pod.
#   2. DELETE the pod (NOT `rollout restart`): the deployment uses RollingUpdate
#      maxSurge>0, which on a single-node RWO PVC would try to schedule a second
#      pod that can never attach the volume -> deadlock. Deleting the one pod lets
#      the controller recreate it cleanly once the volume is free.
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
set -euo pipefail

NS="${NS:-szl-receipts}"
DEPLOY="${DEPLOY:-szl-receipts-server}"
CONTAINER="${CONTAINER:-receipts-server}"
SELECTOR="${SELECTOR:-app.kubernetes.io/name=szl-receipts-server}"
STORE="${STORE:-/data/receipts}"
PORT="${PORT:-8080}"
SEED="${SEED:-3}"
TIMEOUT="${TIMEOUT:-120s}"

CONFIRM="no"
[ "${1:-}" = "--yes" ] && CONFIRM="yes"

log() { printf '[reset-receipt-chain] %s\n' "$*"; }

pod() { kubectl get pod -n "$NS" -l "$SELECTOR" \
          -o jsonpath='{.items[0].metadata.name}' 2>/dev/null; }

count_on_disk() {
  kubectl exec -n "$NS" "$1" -c "$CONTAINER" -- \
    sh -c "ls $STORE/*.json 2>/dev/null | wc -l" 2>/dev/null | tr -d '[:space:]'
}

P="$(pod)"
[ -n "$P" ] || { log "ERROR: no $SELECTOR pod found in ns $NS"; exit 1; }

BEFORE="$(count_on_disk "$P")"
BYTES="$(kubectl exec -n "$NS" "$P" -c "$CONTAINER" -- du -sh "$STORE" 2>/dev/null | awk '{print $1}')"
log "current chain: ${BEFORE:-?} receipts (${BYTES:-?}) on pod $P"
log "plan: wipe store -> delete pod -> reboot to genesis -> seed $SEED signed receipts"

if [ "$CONFIRM" != "yes" ]; then
  log "DRY-RUN (no changes). Re-run with --yes to perform the reset."
  exit 0
fi

# 1. wipe persisted chain + head pointer on the live volume
log "wiping $STORE on pod $P ..."
kubectl exec -n "$NS" "$P" -c "$CONTAINER" -- \
  sh -c "rm -f $STORE/*.json $STORE/.chain_head; ls -A $STORE | wc -l"

# 2. delete the pod (no surge) so the new one boots from the empty store
log "deleting pod $P (avoids RollingUpdate RWO-PVC surge deadlock) ..."
kubectl delete pod -n "$NS" "$P" --wait=true

# 3. wait for the fresh pod to be Ready (2/2)
log "waiting for a new Ready pod ..."
kubectl rollout status deploy/"$DEPLOY" -n "$NS" --timeout="$TIMEOUT"
kubectl wait --for=condition=ready pod -n "$NS" -l "$SELECTOR" --timeout="$TIMEOUT"
P="$(pod)"
log "new pod: $P"

# 4. seed a handful of receipts through the server (real Ed25519 signatures)
log "seeding $SEED baseline receipts via POST /receipt ..."
kubectl exec -i -n "$NS" "$P" -c "$CONTAINER" -- python3 - "$SEED" "$PORT" <<'PY'
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
kubectl exec -i -n "$NS" "$P" -c "$CONTAINER" -- python3 - "$PORT" "$SEED" <<'PY'
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
