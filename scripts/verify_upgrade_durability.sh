#!/usr/bin/env bash
# Copyright 2026 SZL Holdings
# SPDX-License-Identifier: Apache-2.0
#
# verify_upgrade_durability.sh — prove the szl-receipts trust state SURVIVES a
# helm upgrade.
#
# The two durability guarantees that matter most for szl-receipts are:
#   1. the PERSISTENT Ed25519 signing identity — the same /pubkey keyid (and raw
#      public key) before and after the upgrade, so previously-signed receipts
#      still verify; and
#   2. the APPEND-ONLY receipt chain — chain_index never goes backwards and the
#      whole persisted chain still verifies (every prev_hash link + Ed25519
#      signature intact), i.e. the chain was not wiped, truncated, or reset.
#
# `tasks.yaml test-upgrade` proves a helm upgrade *happened* (revision 1 -> 2) but
# NOT that the data + trust state survived it. An upgrade that silently rotated
# the key or reset the chain would still pass that revision check. This closes the
# gap.
#
# WHY this reads the on-disk store and NOT GET /receipts: an upgrade replaces the
# pod, and the server boots fast from its .chain_head pointer with an EMPTY
# in-memory window that only forward-fills with NEW receipts (the full history
# stays on the PVC). So GET /receipts on a freshly-upgraded pod shows only
# post-upgrade receipts. The authoritative survival check is the server's own
# `verify-store` full at-rest audit (bounded, shard-by-shard) plus the disk-backed
# szl_chain_index gauge from /metrics — both reflect the persisted PVC chain.
#
# Subcommands (both take an optional state dir; default /tmp/szl-upgrade-durability):
#   capture <statedir>  — run on the BASELINE release, BEFORE the current-branch
#       upgrade. Seeds a couple of real signed receipts so the chain is
#       non-trivial (a wipe of an empty chain is invisible), then snapshots the
#       signing keyid + public key and the persisted chain head index.
#   assert  <statedir>  — run AFTER the upgrade. Re-reads the live key + persisted
#       chain and FAILS LOUDLY if the key rotated, the persisted chain no longer
#       verifies end-to-end, or the head chain_index regressed below the captured
#       value.
#
# Reaching the server:
#   * HTTP (/pubkey, /metrics, POST /receipt) — by default port-forwards
#     svc/szl-receipts-server:8080 with `zarf tools kubectl`. Set
#     SZL_RECEIPTS_URL=http://host:port to talk to a reachable server directly.
#   * verify-store — by default `kubectl exec`s `python3 /app/server.py
#     verify-store` inside the receipts-server pod (reads the PVC). For the
#     cluster-free self-test set SZL_LOCAL_STORE=<dir> (+ SZL_LOCAL_KEY=<pem> and
#     SZL_LOCAL_SERVER=<server.py>) to run verify-store directly on a store dir.
set -euo pipefail

MODE="${1:-}"
STATE_DIR="${2:-/tmp/szl-upgrade-durability}"

NAMESPACE="${SZL_NAMESPACE:-szl-receipts}"
SVC="${SZL_SVC:-szl-receipts-server}"
POD_SELECTOR="${SZL_POD_SELECTOR:-app.kubernetes.io/name=szl-receipts-server}"
CONTAINER="${SZL_CONTAINER:-receipts-server}"
LOCAL_PORT="${SZL_LOCAL_PORT:-9998}"
RECEIPTS_URL="${SZL_RECEIPTS_URL:-}"
SEED_COUNT="${SZL_UPGRADE_SEED_COUNT:-2}"

# Cluster-free self-test hooks (unset in CI / live).
LOCAL_STORE="${SZL_LOCAL_STORE:-}"
LOCAL_KEY="${SZL_LOCAL_KEY:-}"
LOCAL_SERVER="${SZL_LOCAL_SERVER:-}"

kctl() {
  if command -v zarf >/dev/null 2>&1; then
    zarf tools kubectl "$@"
  else
    kubectl "$@"
  fi
}

PF_PID=""
cleanup() {
  rc=$?
  [ -n "${PF_PID}" ] && kill "${PF_PID}" 2>/dev/null || true
  exit "$rc"
}
trap cleanup EXIT

resolve_url() {
  if [ -n "${RECEIPTS_URL}" ]; then
    return 0
  fi
  echo "Port-forwarding svc/${SVC}:8080 -> localhost:${LOCAL_PORT} (ns ${NAMESPACE})..."
  kctl port-forward "svc/${SVC}" "${LOCAL_PORT}:8080" -n "${NAMESPACE}" >/dev/null 2>&1 &
  PF_PID=$!
  for _ in $(seq 1 30); do
    if curl -sf "http://localhost:${LOCAL_PORT}/healthz" >/dev/null 2>&1; then break; fi
    sleep 1
  done
  RECEIPTS_URL="http://localhost:${LOCAL_PORT}"
}

# Echo the value of a Prometheus gauge/counter line from GET /metrics.
metric() {
  curl -sf "${RECEIPTS_URL}/metrics" \
    | awk -v k="$1" '$1==k {print $2; found=1} END{ if(!found) exit 1 }'
}

# Run the server's verify-store audit and echo its JSON report. Locally when
# SZL_LOCAL_STORE is set; otherwise inside the receipts-server pod (reads the PVC).
run_verify_store() {
  if [ -n "${LOCAL_STORE}" ]; then
    SZL_RECEIPT_STORE="${LOCAL_STORE}" SZL_ED25519_KEY_PATH="${LOCAL_KEY}" \
      python3 "${LOCAL_SERVER}" verify-store
  else
    local pod
    pod="$(kctl get pod -n "${NAMESPACE}" -l "${POD_SELECTOR}" \
            -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
    [ -n "${pod}" ] || { echo '{"chain_ok": false, "error": "no receipts-server pod"}'; return 0; }
    kctl exec -n "${NAMESPACE}" "${pod}" -c "${CONTAINER}" -- \
      python3 /app/server.py verify-store
  fi
}

require_pubkey_signed() {
  python3 - "$1" << 'PYEOF'
import sys, json
p = json.load(open(sys.argv[1]))
if not p.get("signed") or not p.get("public_key_b64u") or not p.get("keyid"):
    print(f"::error::szl-receipts is NOT signing (pubkey={p}); cannot prove key survival")
    sys.exit(1)
PYEOF
}

jget() { python3 -c 'import sys,json;print(json.load(open(sys.argv[1])).get(sys.argv[2]) or "")' "$1" "$2"; }

case "${MODE}" in
  capture)
    mkdir -p "${STATE_DIR}"
    resolve_url

    # Seed a couple of distinct, real signed receipts so the chain is non-trivial:
    # a silent wipe of an empty chain would otherwise look identical to a
    # preserved one.
    ts="$(date -u +%s)"
    for n in $(seq 1 "${SEED_COUNT}"); do
      curl -sf -X POST "${RECEIPTS_URL}/receipt" \
        -H 'Content-Type: application/json' \
        -d "{\"event\":\"upgrade-durability-seed\",\"ts\":\"${ts}\",\"n\":${n}}" \
        >/dev/null || { echo "::error::could not POST seed receipt ${n}"; exit 1; }
    done

    curl -sf "${RECEIPTS_URL}/pubkey" -o "${STATE_DIR}/pre-pubkey.json"
    require_pubkey_signed "${STATE_DIR}/pre-pubkey.json"

    KEYID="$(jget "${STATE_DIR}/pre-pubkey.json" keyid)"
    PUBKEY="$(jget "${STATE_DIR}/pre-pubkey.json" public_key_b64u)"
    # szl_chain_index = NEXT index to assign; head index = next - 1.
    NEXT_INDEX="$(metric szl_chain_index)" || { echo "::error::could not read szl_chain_index from /metrics"; exit 1; }
    if [ "${NEXT_INDEX%.*}" -lt 1 ]; then
      echo "::error::baseline chain is empty after seeding (next index=${NEXT_INDEX}) — nothing to prove survives"
      exit 1
    fi

    {
      echo "PRE_KEYID=${KEYID}"
      echo "PRE_PUBKEY=${PUBKEY}"
      echo "PRE_NEXT_INDEX=${NEXT_INDEX%.*}"
    } > "${STATE_DIR}/baseline.env"
    echo "Captured baseline trust state:"
    echo "  signing keyid    : ${KEYID}"
    echo "  chain next-index : ${NEXT_INDEX%.*} (head index $(( ${NEXT_INDEX%.*} - 1 )))"
    ;;

  assert)
    [ -f "${STATE_DIR}/baseline.env" ] || {
      echo "::error::no captured baseline at ${STATE_DIR}/baseline.env — the capture step did not run"
      exit 1
    }
    # shellcheck disable=SC1091
    . "${STATE_DIR}/baseline.env"
    resolve_url
    curl -sf "${RECEIPTS_URL}/pubkey" -o "${STATE_DIR}/post-pubkey.json"

    POST_KEYID="$(jget "${STATE_DIR}/post-pubkey.json" keyid)"
    POST_PUBKEY="$(jget "${STATE_DIR}/post-pubkey.json" public_key_b64u)"

    fail=0

    # 1) Signing KEY must be unchanged (keyid AND raw public key).
    if [ "${POST_KEYID}" != "${PRE_KEYID}" ]; then
      echo "::error::SIGNING KEY ROTATED across upgrade: keyid '${PRE_KEYID}' -> '${POST_KEYID}'"
      fail=1
    elif [ "${POST_PUBKEY}" != "${PRE_PUBKEY}" ]; then
      echo "::error::SIGNING KEY ROTATED across upgrade: public key changed (keyid '${PRE_KEYID}' reused)"
      fail=1
    else
      echo "OK: signing key unchanged across upgrade (keyid=${PRE_KEYID})."
    fi

    # 2) The PERSISTED chain must still verify end-to-end (every prev_hash link +
    #    Ed25519 signature) — the chain head verifies and the chain is intact.
    #    verify-store emits a "[INFO] key loaded" log line before its JSON report,
    #    so extract the trailing JSON object before parsing.
    run_verify_store > "${STATE_DIR}/post-verify-store.raw" 2>&1 || true
    python3 - "${STATE_DIR}/post-verify-store.raw" "${STATE_DIR}/post-verify-store.json" << 'PYEOF'
import sys, json
txt = open(sys.argv[1]).read()
i = txt.find('{')
try:
    report = json.loads(txt[i:]) if i >= 0 else {}
except Exception:
    report = {"chain_ok": False, "error": "unparseable verify-store output"}
json.dump(report, open(sys.argv[2], "w"))
print(json.dumps(report, indent=2))
PYEOF
    echo "verify-store report:"; cat "${STATE_DIR}/post-verify-store.json"; echo
    if python3 - "${STATE_DIR}/post-verify-store.json" << 'PYEOF'
import sys, json
r = json.load(open(sys.argv[1]))
ok = bool(r.get("chain_ok")) and int(r.get("total", 0)) >= 1 and int(r.get("valid", 0)) == int(r.get("total", 0))
sys.exit(0 if ok else 1)
PYEOF
    then
      echo "OK: persisted chain verifies end-to-end (chain_ok, valid==total)."
    else
      echo "::error::persisted chain FAILED verify-store: the chain was reset, truncated, or tampered across the upgrade."
      fail=1
    fi

    # 3) The head chain_index must not have regressed below the captured value.
    POST_NEXT_INDEX="$(metric szl_chain_index)" || { echo "::error::could not read szl_chain_index from /metrics post-upgrade"; POST_NEXT_INDEX=-1; }
    POST_NEXT_INDEX="${POST_NEXT_INDEX%.*}"
    if [ "${POST_NEXT_INDEX}" -lt "${PRE_NEXT_INDEX}" ]; then
      echo "::error::CHAIN ROLLBACK: post-upgrade next chain_index ${POST_NEXT_INDEX} < pre-upgrade ${PRE_NEXT_INDEX} — the chain shrank."
      fail=1
    else
      echo "OK: chain_index did not regress (pre next=${PRE_NEXT_INDEX}, post next=${POST_NEXT_INDEX})."
    fi

    if [ "${fail}" -ne 0 ]; then
      echo "::error::receipts and/or the signing key did NOT survive the upgrade."
      exit 1
    fi
    echo "PROVEN: the receipt chain AND the signing key survived the upgrade."
    ;;

  *)
    echo "usage: $0 {capture|assert} [state_dir]" >&2
    exit 2
    ;;
esac
