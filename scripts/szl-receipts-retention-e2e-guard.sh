# Copyright 2026 SZL Holdings
# SPDX-License-Identifier: Apache-2.0
#
# szl-receipts-retention-e2e-guard.sh — drive the REAL szl-receipts-retention
# daily auto-trim job end-to-end against a REAL on-disk receipt store and the
# REAL server.py archive/verify CLI (mocked kubectl, no live cluster) and assert
# the observable RESULT of a retention cycle: the live store SHRINKS, the
# archived buckets LAND in the cold dir, the TAIL bucket is never deleted, a
# post-archive `verify-store` reports chain_ok=true, and the runner no-ops when
# the cluster is down.
#
# WHY THIS EXISTS (and how it differs from the canned-JSON guard)
# scripts/szl-receipts-retention-guard-checks.sh already runs the real runner
# under a mocked kubectl, but it feeds the runner CANNED verify-store /
# archive-shards JSON — server.py never executes against a real store. That
# proves the runner's control flow (verify gate, prune gate, no-op, de-dup) but
# CANNOT prove the data-level safety properties the retention job actually exists
# to guarantee:
#   * the live store really SHRINKS (sealed buckets are removed off the PVC);
#   * archived buckets really LAND in the cold dir (tar.gz + manifest + ledger);
#   * the TAIL bucket (the one still being written) is NEVER archived/deleted;
#   * archival is per-bucket VERIFY-GATED — a tampered sealed bucket is SKIPPED
#     (never archived, never deleted) and pages, while the healthy buckets still
#     archive (it never "archives without verifying");
#   * a post-archive verify-store on the SHRUNK live store still reports
#     chain_ok=true (the bucket-at-a-time chain stays verifiable after trimming).
#
# Those are properties of the runner + the REAL server.py archive_sealed_shards /
# verify_store_offline working together. The only honest way to prove them is to
# build a real signed store, run the real runner, and inspect the real on-disk
# result. So this guard:
#   1. SEEDS a real store: an ephemeral Ed25519 key + N real DSSE receipts spread
#      across several small shard buckets (SZL_RECEIPT_SHARD_SIZE is set small)
#      so there are sealed buckets BELOW the tail bucket to archive;
#   2. mocks `kubectl` so `kubectl exec … -- <cmd>` runs <cmd> LOCALLY against the
#      seeded store — i.e. the runner's `verify-store`, `archive-shards --delete`,
#      `cat` (offload) and `rm` (prune) execute the REAL server.py / real files;
#   3. runs the REAL box-scripts/sbin/szl-receipts-retention;
#   4. asserts the observable result (store shrank, cold dir populated, tail
#      survived, no false page, post-archive verify-store chain_ok=true), plus a
#      cluster-down no-op and a tampered-bucket ALERT-without-deletion path.
#
# Usage: bash scripts/szl-receipts-retention-e2e-guard.sh [path-to-runner]
#   SERVER_SRC=<server.py> overrides which server.py is exercised — the
#   negative-fixture self-test points it at deliberately-broken copies (tail
#   guard removed / per-bucket verify gate removed) and asserts THIS guard FAILS.
# Exit 0 if every assertion holds, 1 otherwise.
#
# No cluster, no root, no network: everything runs in a temp dir and is cleaned
# up on exit.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
RUNNER="${1:-$REPO_ROOT/box-scripts/sbin/szl-receipts-retention}"
SERVER_SRC="${SERVER_SRC:-$REPO_ROOT/services/szl-receipts-server/server.py}"

if [ ! -r "$RUNNER" ]; then
  echo "FATAL szl-receipts-retention runner not found/readable: $RUNNER" >&2
  exit 1
fi
if [ ! -r "$SERVER_SRC" ]; then
  echo "FATAL server.py not found/readable: $SERVER_SRC" >&2
  exit 1
fi
if ! python3 -c 'import cryptography' >/dev/null 2>&1; then
  echo "FATAL python3 'cryptography' is required to build a real signed store (pip install cryptography)" >&2
  exit 1
fi

PASS=0; FAIL=0
ok()  { echo "ok   $*"; PASS=$((PASS+1)); }
bad() { echo "FAIL $*"; FAIL=$((FAIL+1)); }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
BIN="$T/bin"; mkdir -p "$BIN"

# Small shard buckets so a handful of receipts span several sealed buckets plus a
# tail. SHARD=4, N=10 => buckets 00000000(0-3) 00000001(4-7) [sealed] and
# 00000002(8-9) [the TAIL, still being written]. Sealed buckets get archived;
# the tail must survive.
SHARD=4
N=10

# ── Seeder: build a real signed store using the server's OWN signing + chain
# helpers (so every receipt verifies under verify-store). Written once, reused
# for each fresh store. Imports SERVER_SRC by path so a broken copy is exercised.
SEEDER="$T/seed.py"
cat >"$SEEDER" <<'PYEOF'
import os, sys, json, time, hashlib, importlib.util
store, key, shard, n, src = sys.argv[1:6]
os.environ["SZL_RECEIPT_STORE"] = store
os.environ["SZL_ED25519_KEY_PATH"] = key
os.environ["SZL_RECEIPT_SHARD_SIZE"] = shard
os.environ["SZL_SIGNING_BACKEND"] = "file"
os.makedirs(store, exist_ok=True)
os.makedirs(os.path.dirname(key), exist_ok=True)
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives import serialization
k = Ed25519PrivateKey.generate()
with open(key, "wb") as f:
    f.write(k.private_bytes(serialization.Encoding.PEM,
                            serialization.PrivateFormat.PKCS8,
                            serialization.NoEncryption()))
spec = importlib.util.spec_from_file_location("server", src)
server = importlib.util.module_from_spec(spec)
spec.loader.exec_module(server)
server._signer = server.build_signer()
server._public_key_b64 = server._signer.public_key_b64u
if not (server._signer and server._signer.available):
    print("SEED-FATAL signer unavailable", file=sys.stderr); sys.exit(2)
n = int(n)
prev = server.GENESIS
ts = time.strftime("%Y-%m-%dT%H:%M:%SZ")
for i in range(n):
    payload = json.dumps({"i": i, "src": "retention-e2e"}, sort_keys=True).encode()
    env = server.sign_dsse(payload)
    rid = hashlib.sha256(
        json.dumps(env, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
    rec = {"id": rid, "created_at": ts, "timestamp": ts, "valid": True,
           "envelope": env, "chain": {"prev_hash": prev, "chain_index": i}}
    rec["chain"]["hash"] = server._receipt_hash(rec)
    dest = server._store_path_for(rid, i)
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    with open(dest, "w") as f:
        json.dump(rec, f)
    prev = rec["chain"]["hash"]
server._write_head_pointer(n, prev, count=n)
print("SEEDED %d receipts; buckets=%s" %
      (n, sorted(os.listdir(os.path.join(store, "shards")))))
PYEOF

# ── Tamper: corrupt the stored chain hash of one receipt in a given bucket so
# that bucket fails per-bucket verification (hash_ok=False) inside server.py.
TAMPER="$T/tamper.py"
cat >"$TAMPER" <<'PYEOF'
import os, sys, json
bdir = sys.argv[1]
files = sorted(x for x in os.listdir(bdir) if x.endswith(".json"))
p = os.path.join(bdir, files[0])
with open(p) as f:
    d = json.load(f)
h = d["chain"]["hash"]
d["chain"]["hash"] = "deadbeef" + h[8:]   # break hash_ok without touching the sig
with open(p, "w") as f:
    json.dump(d, f)
print("TAMPERED", p)
PYEOF

# ── Mock cluster bins ─────────────────────────────────────────────────────────
# kubectl: canned for the readiness/discovery probes; for `exec … -- <cmd>` it
# runs <cmd> LOCALLY so the runner's verify-store / archive-shards / cat / rm hit
# the REAL server.py and the REAL seeded store.
cat >"$BIN/kubectl" <<'KEOF'
#!/usr/bin/env bash
full="$*"
case "$full" in
  *"--raw=/readyz"*) echo ok; exit 0 ;;
  *"get deploy szl-receipts-server"*) exit 0 ;;
  *"get pods"*)
    printf '%s' '{"items":[{"metadata":{"name":"szl-receipts-server-test"},"status":{"containerStatuses":[{"name":"receipts-server","ready":true}]}}]}'
    exit 0 ;;
esac
# exec passthrough: run everything after the first bare `--`.
seen=0; cmd=()
for a in "$@"; do
  if [ "$seen" = 1 ]; then cmd+=("$a"); continue; fi
  [ "$a" = "--" ] && seen=1
done
if [ "$seen" = 1 ] && [ "${#cmd[@]}" -gt 0 ]; then exec "${cmd[@]}"; fi
exit 0
KEOF
chmod +x "$BIN/kubectl"

# k3d: `kubeconfig write` prints a path; fails (cluster absent) when STUB_K3D_DOWN=1.
cat >"$BIN/k3d" <<KEOF
#!/usr/bin/env bash
if [ "\${STUB_K3D_DOWN:-0}" = "1" ]; then exit 1; fi
echo "$T/kubeconfig"
exit 0
KEOF
chmod +x "$BIN/k3d"
: >"$T/kubeconfig"

# Capturing notifier — record each page so we can count edges.
PAGES="$T/pages"; : >"$PAGES"
cat >"$BIN/notify" <<KEOF
#!/usr/bin/env bash
cat >>"$PAGES"
printf '\n---PAGE-END---\n' >>"$PAGES"
KEOF
chmod +x "$BIN/notify"

# ── Per-scenario state (reset each run) ───────────────────────────────────────
STORE=""; KEY=""; STATE=""; LOGD=""; HOSTCOLD=""; PODCOLD=""
RC=0

fresh_dirs() {
  local tag="$1"
  STORE="$T/$tag/store"; KEY="$T/$tag/key/ed25519.pem"
  STATE="$T/$tag/state"; LOGD="$T/$tag/log"
  HOSTCOLD="$T/$tag/hostcold"; PODCOLD="$STORE/cold"
  rm -rf "$T/$tag"; mkdir -p "$STORE" "$STATE" "$LOGD" "$HOSTCOLD"
}

seed() {  # seed the current $STORE with a fresh signed chain
  python3 "$SEEDER" "$STORE" "$KEY" "$SHARD" "$N" "$SERVER_SRC" >/dev/null 2>"$T/seed.err" || {
    echo "FATAL seeding failed:"; sed 's/^/   | /' "$T/seed.err" >&2; exit 1
  }
}

run_runner() {  # drive the REAL runner against the current scenario
  : >"$PAGES"
  env PATH="$BIN:$PATH" \
    SZL_RECEIPT_STORE="$STORE" SZL_ED25519_KEY_PATH="$KEY" \
    SZL_RECEIPT_SHARD_SIZE="$SHARD" SZL_SIGNING_BACKEND=file \
    CLUSTER=testcl KUBECONFIG_FILE="" \
    RNS=szl-receipts RX_CONTAINER=receipts-server \
    STATE_DIR="$STATE" LOG_DIR="$LOGD" \
    HOST_COLD_DIR="$HOSTCOLD" POD_COLD_DIR="$PODCOLD" \
    PRUNE_AFTER_OFFLOAD=1 \
    SERVER_PY="$SERVER_SRC" PY=python3 \
    NOTIFY_CMD="$BIN/notify" ALERT_PREFIX="[TEST] " \
    STUB_K3D_DOWN="${STUB_K3D_DOWN:-0}" \
    bash "$RUNNER" >"$T/stdout" 2>&1
  RC=$?
}

pages_count() { grep -c '^---PAGE-END---$' "$PAGES" 2>/dev/null || true; }
status_overall() { sed -n 's/.*"overall":"\([^"]*\)".*/\1/p' "$STATE/testcl.status.json" 2>/dev/null; }
bucket_exists() { test -d "$STORE/shards/$1"; }
verify_chain_ok() {  # post-archive: run the REAL verify-store on the SHRUNK store
  SZL_RECEIPT_STORE="$STORE" SZL_ED25519_KEY_PATH="$KEY" \
    SZL_RECEIPT_SHARD_SIZE="$SHARD" SZL_SIGNING_BACKEND=file \
    python3 "$SERVER_SRC" verify-store 2>/dev/null | grep -q '"chain_ok": true'
}

# ── Phase H: a healthy retention cycle trims the store and lands the cold archive
echo "== Phase H: healthy cycle — store shrinks, cold dir lands, tail survives, no page =="
fresh_dirs H; seed
# sanity: all three buckets present before the run
if bucket_exists 00000000 && bucket_exists 00000001 && bucket_exists 00000002; then
  ok "H0 seeded store has the expected sealed + tail buckets"
else
  bad "H0 seeded store is missing expected buckets ($(ls "$STORE/shards" 2>/dev/null | tr '\n' ' '))"
fi
STUB_K3D_DOWN=0 run_runner
[ "$RC" -eq 0 ] && ok "H1 healthy cycle exits 0" || bad "H1 healthy cycle exit $RC (want 0)"
[ "$(pages_count)" -eq 0 ] && ok "H2 healthy cycle pages nothing" || bad "H2 healthy cycle PAGED ($(pages_count))"
[ "$(status_overall)" = "OK" ] && ok "H3 status overall=OK" || bad "H3 status overall='$(status_overall)' (want OK)"
# store shrinks: the sealed buckets are gone off the live store
if ! bucket_exists 00000000 && ! bucket_exists 00000001; then
  ok "H4 store SHRANK — sealed buckets 00000000/00000001 removed off the live store"
else
  bad "H4 sealed buckets were NOT removed off the live store (store did not shrink)"
fi
# tail bucket survives
if bucket_exists 00000002; then ok "H5 TAIL bucket 00000002 survived (never archived/deleted)"; else bad "H5 TAIL bucket 00000002 was deleted"; fi
# archived buckets land in the cold dir on the box
if [ -f "$HOSTCOLD/00000000.tar.gz" ] && [ -f "$HOSTCOLD/00000000.manifest.json" ] \
   && [ -f "$HOSTCOLD/00000001.tar.gz" ] && [ -f "$HOSTCOLD/00000001.manifest.json" ] \
   && [ -f "$HOSTCOLD/archived.json" ]; then
  ok "H6 archived buckets LANDED in the cold dir (tar.gz + manifest + ledger)"
else
  bad "H6 archived buckets did not land in the cold dir ($(ls "$HOSTCOLD" 2>/dev/null | tr '\n' ' '))"
fi
# the in-pod cold copy was pruned after the verified offload
if [ ! -f "$PODCOLD/00000000.tar.gz" ] && [ ! -f "$PODCOLD/00000001.tar.gz" ]; then
  ok "H7 in-pod cold copies were pruned after the sha256-verified offload"
else
  bad "H7 in-pod cold copies were NOT pruned ($(ls "$PODCOLD" 2>/dev/null | tr '\n' ' '))"
fi
# post-archive verify-store on the shrunk store is still chain_ok=true
if verify_chain_ok; then ok "H8 post-archive verify-store reports chain_ok=true on the shrunk store"; else bad "H8 post-archive verify-store did NOT report chain_ok=true"; fi

# ── Phase D: cluster down — the runner no-ops
echo "== Phase D: cluster down — runner no-ops (exit 0, no page, store untouched) =="
fresh_dirs D; seed
STUB_K3D_DOWN=1 run_runner
[ "$RC" -eq 0 ] && ok "D1 cluster-down run exits 0 (no-op)" || bad "D1 cluster-down exit $RC (want 0)"
[ "$(pages_count)" -eq 0 ] && ok "D2 cluster-down run pages nothing" || bad "D2 cluster-down PAGED ($(pages_count))"
if bucket_exists 00000000 && bucket_exists 00000001 && bucket_exists 00000002; then
  ok "D3 cluster-down left the store untouched (nothing archived/deleted)"
else
  bad "D3 cluster-down mutated the store"
fi

# ── Phase T: a tampered SEALED bucket is SKIPPED (not archived/deleted) + pages
echo "== Phase T: tampered sealed bucket — ALERT, and that bucket is never deleted =="
fresh_dirs T; seed
python3 "$TAMPER" "$STORE/shards/00000000" >/dev/null 2>&1 || { echo "FATAL tamper failed" >&2; exit 1; }
STUB_K3D_DOWN=0 run_runner
[ "$(pages_count)" -ge 1 ] && ok "T1 a tampered sealed bucket fires an ALERT page" || bad "T1 tampered bucket did NOT page"
[ "$(status_overall)" = "ALERT" ] && ok "T2 status overall=ALERT" || bad "T2 status overall='$(status_overall)' (want ALERT)"
if bucket_exists 00000000; then
  ok "T3 the tampered bucket 00000000 was NOT archived/deleted (no archiving without verifying)"
else
  bad "T3 the tampered bucket 00000000 was DELETED off the live store (archived without verifying!)"
fi
if bucket_exists 00000002; then ok "T4 TAIL bucket 00000002 still present"; else bad "T4 TAIL bucket 00000002 was deleted"; fi

echo ""
echo "==================================================================="
echo "szl-receipts-retention e2e guard: $PASS passed, $FAIL failed"
echo "==================================================================="
[ "$FAIL" -eq 0 ]
