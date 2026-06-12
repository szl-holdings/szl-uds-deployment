#!/usr/bin/env bash
# Copyright 2026 SZL Holdings
# SPDX-License-Identifier: Apache-2.0
#
# verify_receipts.sh — Offline, PUBLIC-KEY-ONLY receipt chain verification.
#
# Usage:
#   bash scripts/verify_receipts.sh
#   # or:
#   uds run demo:verify
#
# What this does (matches the live szl-receipts-server, Finding A2 / PR-4):
#   1. Port-forwards the receipts server to localhost:9999 (skipped if a local
#      RECEIPTS_URL / chain file is supplied — see env below).
#   2. Fetches the Ed25519 PUBLIC key from GET /pubkey (or SZL_PUBKEY_B64 /
#      SZL_PUBKEY_FILE). The private key is NEVER needed to verify.
#   3. Fetches all stored receipts via GET /receipts.
#   4. For each receipt:
#      a. Reconstructs the canonical DSSE Pre-Authentication Encoding (PAE):
#           "DSSEv1" SP LEN(type) SP type SP LEN(body) SP body
#      b. Verifies the Ed25519 signature over that PAE with the public key.
#      c. Verifies the SHA-256 hash-chain link (prev_hash == hash of prior).
#      d. Prints VERIFIED / FAILED per receipt.
#   5. Shows the Kubernetes annotations on the demo workload (if present).
#
# This is the SAME scheme the server signs with (Ed25519 over DSSE PAE,
# keyid=szl-receipts-ed25519-2026). A single flipped byte in any receipt
# payload breaks that receipt's signature AND every downstream chain link.
#
# Offline mode (no cluster):
#   SZL_CHAIN_FILE=/path/chain.json SZL_PUBKEY_FILE=/path/pub.b64 \
#     bash scripts/verify_receipts.sh
#
# Exit codes:
#   0 — all receipts verified (signature + chain link) AND, if an anchor is
#       supplied, the live chain is at or above the durable checkpoint
#   1 — at least one verification failed, server/key unreachable, OR the live
#       chain regressed below the durable checkpoint (see "Durable-checkpoint
#       mode" below)
#
# Durable-checkpoint mode (opt-in; no-op unless one of these is set):
#   SZL_ANCHOR_FILE=/path/checkpoint.json   {chain_index, head_hash} anchor
#   SZL_MIN_CHAIN_INDEX=<n>                  explicit live-head index floor
#   SZL_EXPECTED_HEAD_HASH=<hex>             expected hash at the checkpoint index
#   Fails (exit 1) if the live head index falls below the checkpoint
#   (truncation/rollback) or a windowed checkpointed receipt's hash changed
#   (tamper). Used by the box `szl-receipt-checkpoint` timer.

set -euo pipefail

NAMESPACE="${SZL_NAMESPACE:-szl-receipts}"
SVC="${SZL_SVC:-szl-receipts-server}"
LOCAL_PORT="${SZL_LOCAL_PORT:-9999}"
RECEIPTS_URL="${SZL_RECEIPTS_URL:-}"          # if set, skip port-forward
CHAIN_FILE="${SZL_CHAIN_FILE:-}"              # if set, verify from a local file
PUBKEY_B64="${SZL_PUBKEY_B64:-}"             # base64url raw Ed25519 public key
PUBKEY_FILE="${SZL_PUBKEY_FILE:-}"

PF_PID=""
cleanup() {
  rc=$?
  [ -n "${PF_PID}" ] && kill "${PF_PID}" 2>/dev/null || true
  [ -n "${PF_PID}" ] && echo "Port-forward stopped."
  exit "$rc"
}
trap cleanup EXIT

echo "── SZL Receipt Verification (Ed25519 / DSSE PAE — offline, public-key only) ──"

# ── Step 1: Resolve a receipts source ────────────────────────────────────────
if [ -z "${CHAIN_FILE}" ]; then
  if [ -z "${RECEIPTS_URL}" ]; then
    echo "Port-forwarding ${SVC}:8080 → localhost:${LOCAL_PORT}…"
    kubectl port-forward "svc/${SVC}" "${LOCAL_PORT}:8080" -n "${NAMESPACE}" &
    PF_PID=$!
    sleep 2
    RECEIPTS_URL="http://localhost:${LOCAL_PORT}"
  fi
  echo "Fetching receipts from ${RECEIPTS_URL}/receipts…"
  RECEIPTS_JSON=$(curl -sf "${RECEIPTS_URL}/receipts") || {
    echo "ERROR: Could not reach receipts server. Is the bundle deployed?"
    exit 1
  }
  # Fetch the public key (offline verify needs only this — never the private key)
  if [ -z "${PUBKEY_B64}" ] && [ -z "${PUBKEY_FILE}" ]; then
    PUBKEY_JSON=$(curl -sf "${RECEIPTS_URL}/pubkey" 2>/dev/null || echo "")
    if [ -n "${PUBKEY_JSON}" ]; then
      PUBKEY_B64=$(echo "${PUBKEY_JSON}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('public_key_b64u',''))" 2>/dev/null || echo "")
    fi
  fi
else
  echo "Reading receipts from local chain file ${CHAIN_FILE}…"
  RECEIPTS_JSON=$(cat "${CHAIN_FILE}")
fi

if [ -n "${PUBKEY_FILE}" ] && [ -s "${PUBKEY_FILE}" ]; then
  PUBKEY_B64=$(cat "${PUBKEY_FILE}")
fi

if [ -z "${PUBKEY_B64}" ]; then
  echo "ERROR: No Ed25519 public key available."
  echo "       Provide one of: GET /pubkey reachable, SZL_PUBKEY_B64, or SZL_PUBKEY_FILE."
  exit 1
fi

RECEIPT_COUNT=$(echo "${RECEIPTS_JSON}" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))")
echo "Public key (Ed25519): ${PUBKEY_B64:0:24}…"
echo "Found ${RECEIPT_COUNT} receipt(s)."
echo ""

# ── Step 2: Verify each receipt (signature + chain link) ──────────────────────
VERIFY_RC=0
RECEIPTS_JSON="${RECEIPTS_JSON}" PUBKEY_B64="${PUBKEY_B64}" python3 - << 'PYEOF' || VERIFY_RC=$?
import os, sys, json, base64, hashlib

try:
    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey
    from cryptography.exceptions import InvalidSignature
except Exception:
    print("ERROR: python3 'cryptography' package is required for Ed25519 verify.")
    print("       pip install cryptography")
    sys.exit(1)

receipts   = json.loads(os.environ["RECEIPTS_JSON"])
pubkey_b64 = os.environ["PUBKEY_B64"]
PAYLOAD_TYPE = "application/vnd.szl.receipt.v1+json"


def b64u_decode(s: str) -> bytes:
    return base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))


def dsse_pae(payload_type: str, body: bytes) -> bytes:
    t = payload_type.encode("utf-8")
    return b" ".join([
        b"DSSEv1",
        str(len(t)).encode(), t,
        str(len(body)).encode(), body,
    ])


def receipt_hash(record: dict) -> str:
    # Matches server._receipt_hash: SHA-256 over the canonical signed envelope.
    canonical = json.dumps(record["envelope"], sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(canonical.encode("utf-8")).hexdigest()


pub = Ed25519PublicKey.from_public_bytes(b64u_decode(pubkey_b64))

pass_count = 0
fail_count = 0
prev = "GENESIS"

for i, r in enumerate(receipts):
    rid = (r.get("id") or r.get("chain", {}).get("hash", "?"))[:16]
    env = r.get("envelope", {})
    payload_type = env.get("payloadType", PAYLOAD_TYPE)
    payload_b64 = env.get("payload", "")
    sigs = env.get("signatures", [])

    sig_ok = False
    try:
        body = base64.b64decode(payload_b64)
        sig = b64u_decode(sigs[0]["sig"])
        pub.verify(sig, dsse_pae(payload_type, body))   # raises InvalidSignature on bad sig
        sig_ok = True
    except (InvalidSignature, Exception):
        sig_ok = False

    # Chain link: prev_hash must equal the running prior hash; stored hash must
    # equal the recomputed hash of this receipt.
    chain = r.get("chain", {})
    link_ok = chain.get("prev_hash", None) == prev
    recomputed = receipt_hash(r)
    hash_ok = chain.get("hash", None) == recomputed
    prev = recomputed

    verified = sig_ok and link_ok and hash_ok
    if verified:
        pass_count += 1
        icon, status = "✓", "VERIFIED"
    else:
        fail_count += 1
        why = []
        if not sig_ok:  why.append("Ed25519 sig FAIL")
        if not link_ok: why.append("prev_hash link FAIL")
        if not hash_ok: why.append("hash mismatch")
        icon, status = "✗", "FAILED (" + ", ".join(why) + ")"

    keyid = sigs[0].get("keyid", "?") if sigs else "(unsigned)"
    print(f"  {icon} #{i+1}  {rid}…  keyid={keyid}")
    print(f"       status={status}")
    print()

print(f"── Summary: {pass_count} VERIFIED, {fail_count} FAILED out of {len(receipts)} receipts")
if fail_count > 0:
    print("   A FAILED receipt means its Ed25519 signature and/or hash-chain link")
    print("   did not verify against the public key — i.e. tampering was detected.")
sys.exit(0 if fail_count == 0 else 1)
PYEOF


# ── Step 2b: Durable-checkpoint / anchor regression check (additive, opt-in) ──
# Asserts the LIVE chain has not regressed BELOW a durable, pod-unwritable
# checkpoint of the chain head (the "tamper-proof receipt-log checkpoint").
#
# Gated ENTIRELY on the anchor inputs below — when NONE are set this block is a
# pure no-op, so existing callers (receipts-e2e, the DSSE regression test,
# `uds run demo:verify`) behave EXACTLY as before:
#   SZL_ANCHOR_FILE        path to a checkpoint JSON {chain_index, head_hash}
#                          (head_hash alias: "hash") — the durable anchor.
#   SZL_MIN_CHAIN_INDEX    explicit floor for the live head chain_index (stands
#                          in for / raises the anchor's chain_index).
#   SZL_EXPECTED_HEAD_HASH explicit expected hash for the checkpointed index.
#
# GET /receipts returns a most-recent WINDOW (capped MAX_IN_MEMORY) but the head
# (highest chain_index) is ALWAYS present, so this checks:
#   * TRUNCATION/ROLLBACK  live head chain_index < checkpoint index → FAIL
#     ("the live chain fell below the last checkpoint").
#   * TAMPER/REWRITE       if the checkpointed receipt is still in the window,
#     its stored hash must equal the checkpoint head_hash → else FAIL.
ANCHOR_RC=0
if [ -n "${SZL_ANCHOR_FILE:-}" ] || [ -n "${SZL_MIN_CHAIN_INDEX:-}" ] || [ -n "${SZL_EXPECTED_HEAD_HASH:-}" ]; then
  echo ""
  echo "── Durable checkpoint / anchor regression check ───────────────────"
  RECEIPTS_JSON="${RECEIPTS_JSON}" \
  SZL_ANCHOR_FILE="${SZL_ANCHOR_FILE:-}" \
  SZL_MIN_CHAIN_INDEX="${SZL_MIN_CHAIN_INDEX:-}" \
  SZL_EXPECTED_HEAD_HASH="${SZL_EXPECTED_HEAD_HASH:-}" \
  python3 - << 'ANCHOREOF' || ANCHOR_RC=$?
import os, sys, json

receipts = json.loads(os.environ["RECEIPTS_JSON"])

# Live head = the highest chain_index present in the returned window (the server
# always includes the head). by_index lets us hash-check the anchored receipt if
# it is still inside the window.
live_idx = None
live_head = None
by_index = {}
for r in receipts:
    c = r.get("chain") or {}
    ci = c.get("chain_index")
    if ci is None:
        continue
    ci = int(ci)
    by_index[ci] = c.get("hash")
    if live_idx is None or ci > live_idx:
        live_idx, live_head = ci, c.get("hash")
if live_idx is None:
    live_idx = -1

anchor_idx = None
anchor_head = None
af = os.environ.get("SZL_ANCHOR_FILE", "")
if af:
    try:
        with open(af) as fh:
            a = json.load(fh)
        anchor_idx = int(a["chain_index"])
        anchor_head = a.get("head_hash") or a.get("hash")
    except Exception as e:
        print(f"  x anchor file {af!r} unreadable: {e}")
        sys.exit(1)

mci = os.environ.get("SZL_MIN_CHAIN_INDEX", "")
if mci != "":
    anchor_idx = int(mci) if anchor_idx is None else max(anchor_idx, int(mci))

ehh = os.environ.get("SZL_EXPECTED_HEAD_HASH", "")
if ehh:
    anchor_head = ehh

failures = []
if anchor_idx is not None:
    print(f"  durable checkpoint chain_index={anchor_idx}  live head chain_index={live_idx}")
    if live_idx < anchor_idx:
        failures.append(
            f"TRUNCATION/ROLLBACK: live head index {live_idx} is BELOW the durable "
            f"checkpoint index {anchor_idx} - the chain has shrunk."
        )

if anchor_head:
    at = anchor_idx if anchor_idx is not None else live_idx
    if at in by_index:
        if by_index[at] != anchor_head:
            failures.append(
                f"TAMPER: receipt at chain_index {at} has hash "
                f"{str(by_index[at])[:16]} but the checkpoint recorded "
                f"{str(anchor_head)[:16]}"
            )
        else:
            print(f"  ok checkpointed head hash at index {at} is unchanged")
    elif anchor_idx is not None and live_idx == anchor_idx and live_head != anchor_head:
        failures.append(
            f"TAMPER: live head hash {str(live_head)[:16]} != checkpoint "
            f"{str(anchor_head)[:16]} at index {anchor_idx}"
        )

if failures:
    print("  x DURABLE-CHECKPOINT REGRESSION:")
    for f in failures:
        print(f"     - {f}")
    sys.exit(1)
print("  ok live chain is at or above the durable checkpoint; no regression.")
sys.exit(0)
ANCHOREOF
  if [ "${ANCHOR_RC}" -ne 0 ]; then
    echo "  Durable-checkpoint regression detected (exit ${ANCHOR_RC})."
  fi
fi

# ── Step 3: Show K8s annotations (best-effort; skipped in offline file mode) ───
if [ -z "${CHAIN_FILE}" ]; then
  echo ""
  echo "── K8s annotations on demo Deployment ─────────────────────────────"
  kubectl get deployment szl-demo-agent -n szl-demo-workload \
    -o jsonpath='{range .metadata.annotations}{@}{"\n"}{end}' 2>/dev/null | \
    grep "szl\." || echo "(szl-demo-workload/szl-demo-agent not found — run demo:workload first)"
fi

echo ""
FINAL_RC="${VERIFY_RC}"
if [ "${ANCHOR_RC:-0}" -ne 0 ]; then
  FINAL_RC=1
fi
if [ "${VERIFY_RC}" -eq 0 ] && [ "${ANCHOR_RC:-0}" -eq 0 ]; then
  echo "Verification complete — all receipts verified (Ed25519 + hash chain)."
else
  echo "Verification complete — FAILED (per-receipt exit ${VERIFY_RC}, durable-checkpoint exit ${ANCHOR_RC:-0})."
fi

exit "${FINAL_RC}"
