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
#   0 — all receipts verified (signature + chain link)
#   1 — at least one verification failed or server/key unreachable

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

# ── Step 3: Show K8s annotations (best-effort; skipped in offline file mode) ───
if [ -z "${CHAIN_FILE}" ]; then
  echo ""
  echo "── K8s annotations on demo Deployment ─────────────────────────────"
  kubectl get deployment szl-demo-agent -n szl-demo-workload \
    -o jsonpath='{range .metadata.annotations}{@}{"\n"}{end}' 2>/dev/null | \
    grep "szl\." || echo "(szl-demo-workload/szl-demo-agent not found — run demo:workload first)"
fi

echo ""
if [ "${VERIFY_RC}" -eq 0 ]; then
  echo "Verification complete — all receipts verified (Ed25519 + hash chain)."
else
  echo "Verification complete — one or more receipts did not verify (exit ${VERIFY_RC})."
fi

exit "${VERIFY_RC}"
