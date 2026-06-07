#!/usr/bin/env python3
# Copyright 2026 SZL Holdings
# SPDX-License-Identifier: Apache-2.0
#
# verify_receipts_ed25519.py — Independent, public-key-only Ed25519/DSSE-PAE
# receipt-chain verifier (pure Python).
#
# This is the Python sibling of scripts/verify_receipts.sh. It exists so that CI
# can prove, with NO cluster and NO network, that the receipt signing scheme the
# live szl-receipts-server uses (Finding A2 / PR-4) round-trips end-to-end:
#
#   * sign  : Ed25519_sign(privkey, PAE(payloadType, payloadBytes))
#   * verify: Ed25519_verify(pubkey, sig, PAE(payloadType, payloadBytes))
#   * chain : SHA-256 hash chain over the canonical signed envelope, prev=GENESIS
#
#   PAE = "DSSEv1" SP LEN(type) SP type SP LEN(body) SP body  (canonical DSSE v1)
#
# It is INDEPENDENT of the server code: it re-implements the scheme from the
# spec, so if a future server edit silently diverges (HMAC, dropped PAE prefix,
# changed hash input), the freshly generated chain in --self-test still proves
# what the documented scheme is, and verifying a server-produced chain against
# this verifier will fail loudly.
#
# Modes
# -----
#   # 1) Self-test: generate a fresh, signed, chained set of receipts with an
#   #    ephemeral Ed25519 key, verify them, then prove tampering is caught.
#   #    (No external input. This is what CI runs.)
#   python3 scripts/verify_receipts_ed25519.py --self-test
#   python3 scripts/verify_receipts_ed25519.py            # default == --self-test
#
#   # 2) Verify a real chain offline (parity with verify_receipts.sh file mode):
#   python3 scripts/verify_receipts_ed25519.py \
#       --chain chain.json --pubkey pub.b64
#   #   --pubkey accepts either a base64url raw Ed25519 key (as served by
#   #   GET /pubkey -> public_key_b64u) OR a PEM public key file.
#   #   You may also pass --pubkey-b64 <string> directly.
#
# Exit codes:
#   0 — all checks passed (chain verified; tamper correctly rejected)
#   1 — a verification regressed (bad signature, broken chain link, or a
#       tampered/forged receipt verified when it must not)
#   2 — usage / environment error (e.g. cryptography not installed)

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import sys

try:
    from cryptography.hazmat.primitives.asymmetric.ed25519 import (
        Ed25519PrivateKey,
        Ed25519PublicKey,
    )
    from cryptography.hazmat.primitives import serialization
    from cryptography.exceptions import InvalidSignature
except Exception:  # pragma: no cover
    print("ERROR: python3 'cryptography' package is required (pip install cryptography).")
    sys.exit(2)

KEY_ID = "szl-receipts-ed25519-2026"
PAYLOAD_TYPE = "application/vnd.szl.receipt.v1+json"
GENESIS = "GENESIS"


# ── Canonical scheme primitives (mirror server + verify_receipts.sh) ──────────
def canonical_payload_bytes(payload: dict) -> bytes:
    return json.dumps(payload, separators=(",", ":")).encode("utf-8")


def dsse_pae(payload_type: str, body: bytes) -> bytes:
    """Canonical DSSE v1 Pre-Authentication Encoding."""
    t = payload_type.encode("utf-8")
    return b" ".join([
        b"DSSEv1",
        str(len(t)).encode(), t,
        str(len(body)).encode(), body,
    ])


def b64u(b: bytes) -> str:
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode()


def b64u_decode(s: str) -> bytes:
    return base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))


def receipt_hash(record: dict) -> str:
    """SHA-256 over the canonical signed envelope (matches verify_receipts.sh)."""
    canonical = json.dumps(record["envelope"], sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(canonical.encode("utf-8")).hexdigest()


# ── Chain generation (what a correct server would emit) ───────────────────────
def sign_envelope(payload: dict, priv: Ed25519PrivateKey) -> dict:
    payload_bytes = canonical_payload_bytes(payload)
    sig = priv.sign(dsse_pae(PAYLOAD_TYPE, payload_bytes))
    return {
        "payload": base64.b64encode(payload_bytes).decode(),
        "payloadType": PAYLOAD_TYPE,
        "signatures": [{"keyid": KEY_ID, "sig": b64u(sig)}],
    }


def generate_chain(priv: Ed25519PrivateKey, count: int) -> list:
    receipts: list = []
    prev = GENESIS
    for i in range(count):
        payload = {
            "_type": "https://szlholdings.com/receipt/v1",
            "subject": f"szl-demo-workload/Deployment/szl-demo-agent-{i}",
            "specHash": (format(i, "x") or "0").rjust(64, "0"),
            "timestamp": f"2026-05-30T00:00:{i:02d}Z",
            "admissionOp": "CREATE",
            "resourceVersion": str(i),
        }
        env = sign_envelope(payload, priv)
        record = {"envelope": env, "chain": {"prev_hash": prev}}
        h = receipt_hash(record)
        record["chain"]["hash"] = h
        record["id"] = h
        receipts.append(record)
        prev = h
    return receipts


# ── Verification (public key only) ────────────────────────────────────────────
def verify_chain(receipts: list, pub: Ed25519PublicKey, verbose: bool = True) -> int:
    pass_count = 0
    fail_count = 0
    prev = GENESIS

    for i, r in enumerate(receipts):
        env = r.get("envelope", {})
        payload_type = env.get("payloadType", PAYLOAD_TYPE)
        payload_b64 = env.get("payload", "")
        sigs = env.get("signatures", [])

        sig_ok = False
        try:
            body = base64.b64decode(payload_b64)
            sig = b64u_decode(sigs[0]["sig"])
            pub.verify(sig, dsse_pae(payload_type, body))
            sig_ok = True
        except (InvalidSignature, Exception):
            sig_ok = False

        chain = r.get("chain", {})
        link_ok = chain.get("prev_hash", None) == prev
        recomputed = receipt_hash(r)
        hash_ok = chain.get("hash", None) == recomputed
        prev = recomputed

        verified = sig_ok and link_ok and hash_ok
        if verified:
            pass_count += 1
            icon, status = "\u2713", "VERIFIED"
        else:
            fail_count += 1
            why = []
            if not sig_ok:
                why.append("Ed25519 sig FAIL")
            if not link_ok:
                why.append("prev_hash link FAIL")
            if not hash_ok:
                why.append("hash mismatch")
            icon, status = "\u2717", "FAILED (" + ", ".join(why) + ")"

        if verbose:
            rid = (r.get("id") or recomputed)[:16]
            keyid = sigs[0].get("keyid", "?") if sigs else "(unsigned)"
            print(f"  {icon} #{i + 1}  {rid}\u2026  keyid={keyid}  status={status}")

    if verbose:
        print(f"\u2500\u2500 Summary: {pass_count} VERIFIED, {fail_count} FAILED "
              f"out of {len(receipts)} receipts")
    return fail_count


def load_pubkey(pubkey_b64: str | None, pubkey_path: str | None) -> Ed25519PublicKey:
    if pubkey_b64:
        return Ed25519PublicKey.from_public_bytes(b64u_decode(pubkey_b64.strip()))
    if pubkey_path:
        with open(pubkey_path, "rb") as fh:
            data = fh.read()
        # Try PEM first, then raw base64url.
        try:
            key = serialization.load_pem_public_key(data)
            if isinstance(key, Ed25519PublicKey):
                return key
            raise ValueError("PEM is not an Ed25519 public key")
        except Exception:
            return Ed25519PublicKey.from_public_bytes(b64u_decode(data.decode().strip()))
    raise SystemExit("ERROR: provide --pubkey or --pubkey-b64 to verify a chain.")


# ── Self-test (generate fresh chain, verify, prove tamper is caught) ──────────
def self_test(count: int) -> int:
    print("\u2500\u2500 verify_receipts_ed25519 self-test "
          "(Ed25519 / DSSE PAE, freshly generated chain) \u2500\u2500")
    priv = Ed25519PrivateKey.generate()
    pub = priv.public_key()
    receipts = generate_chain(priv, count)

    failures: list[str] = []

    # 1. The freshly signed, chained receipts must all verify.
    print(f"[1] Verifying {count} freshly generated receipts:")
    if verify_chain(receipts, pub) != 0:
        failures.append("a freshly generated, correctly signed chain did not verify")

    # 2. The wrong public key must NOT verify the chain.
    print("[2] Verifying the same chain under the WRONG public key (must fail):")
    other_pub = Ed25519PrivateKey.generate().public_key()
    if verify_chain(receipts, other_pub, verbose=False) == 0:
        failures.append("chain verified under the wrong public key")
    else:
        print("    OK \u2014 wrong key correctly rejected")

    # 3. Tampering with a payload after signing must break that receipt + the
    #    downstream chain links.
    print("[3] Tampering with a signed payload (must be detected):")
    tampered = json.loads(json.dumps(receipts))
    bad_payload = {
        "_type": "https://szlholdings.com/receipt/v1",
        "subject": "ATTACKER",
        "specHash": "b" * 64,
        "timestamp": "2026-05-30T00:00:00Z",
        "admissionOp": "CREATE",
        "resourceVersion": "0",
    }
    tampered[0]["envelope"]["payload"] = base64.b64encode(
        canonical_payload_bytes(bad_payload)
    ).decode()
    if verify_chain(tampered, pub, verbose=False) == 0:
        failures.append("a tampered payload verified \u2014 signature/chain not bound to payload")
    else:
        print("    OK \u2014 tampering correctly detected")

    print()
    if failures:
        print("verify_receipts_ed25519 self-test: FAIL")
        for f in failures:
            print(f"  - {f}")
        return 1
    print("verify_receipts_ed25519 self-test: PASS")
    print("  - a freshly generated Ed25519/DSSE-PAE chain verifies end-to-end")
    print("  - the chain does not verify under the wrong public key")
    print("  - a tampered payload is rejected (sig + hash chain bound to bytes)")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(
        description="Independent Ed25519/DSSE-PAE receipt-chain verifier."
    )
    ap.add_argument("--chain", help="Path to a receipts chain JSON file to verify.")
    ap.add_argument("--pubkey", help="Path to an Ed25519 public key (PEM or base64url raw).")
    ap.add_argument("--pubkey-b64", help="Base64url raw Ed25519 public key string.")
    ap.add_argument("--self-test", action="store_true",
                    help="Generate a fresh chain with an ephemeral key and verify it.")
    ap.add_argument("--count", type=int, default=3,
                    help="Number of receipts to generate in --self-test (default 3).")
    args = ap.parse_args()

    if args.chain:
        with open(args.chain) as fh:
            receipts = json.load(fh)
        pub = load_pubkey(args.pubkey_b64, args.pubkey)
        fail = verify_chain(receipts, pub)
        return 0 if fail == 0 else 1

    # Default behaviour (and explicit --self-test): run the self-test.
    return self_test(max(1, args.count))


if __name__ == "__main__":
    sys.exit(main())
