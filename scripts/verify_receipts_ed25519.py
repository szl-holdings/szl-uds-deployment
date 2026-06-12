#!/usr/bin/env python3
# Copyright 2026 SZL Holdings
# SPDX-License-Identifier: Apache-2.0
#
# verify_receipts_ed25519.py — INDEPENDENT offline verifier for szl-receipts.
#
# This is the auditor's tool. It does NOT trust the server's `valid` field. It
# rebuilds the canonical DSSE Pre-Authentication Encoding (PAE) for each receipt,
# base64url-decodes the 64-byte Ed25519 signature, and verifies it against a
# PUBLISHED Ed25519 public key. It also walks the hash chain to confirm
# tamper-evidence (prev_hash linkage + per-receipt envelope hash).
#
# Crucially, the verification is identical whether the receipt was signed by the
# "file" backend (PEM in a Secret) or the "vault" backend (Vault Transit) — both
# produce a raw Ed25519 signature over the same PAE, so the published public key
# verifies either one. That is the whole point of Tier 2 custody: the key MOVED,
# the proof did not change.
#
# Public key sources (any one):
#   --pubkey-url URL   GET /pubkey (default: <--url>/pubkey); reads public_key_b64u
#   --pubkey-b64u STR  raw 32-byte Ed25519 public key, base64url (no padding)
#   --pubkey-b64 STR   raw 32-byte Ed25519 public key, standard base64
#   --pubkey-pem FILE  PEM SubjectPublicKeyInfo file
#
# Receipt sources (any one):
#   --url URL          GET <URL>/receipts (live server)
#   --receipts FILE    a JSON file/array of receipts (e.g. saved GET /receipts)
#
# Exit code 0 only if every signed receipt verifies AND the chain is intact.
# Unsigned receipts (sentinel sig) are reported and, by default, FAIL the run
# unless --allow-unsigned is given.
#
# Requires: cryptography. (Pure-Python; no server deps.)
#
# Examples:
#   scripts/verify_receipts_ed25519.py --url https://receipts.admin.uds.dev -k
#   scripts/verify_receipts_ed25519.py --receipts dump.json --pubkey-b64u AAAA...
from __future__ import annotations

import argparse
import base64
import hashlib
import json
import ssl
import sys
import urllib.request

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


def b64u_decode(s: str) -> bytes:
    s = s.strip()
    pad = "=" * (-len(s) % 4)
    return base64.urlsafe_b64decode(s + pad)


def dsse_pae(payload_type: str, body: bytes) -> bytes:
    t = payload_type.encode("utf-8")
    return b" ".join([
        b"DSSEv1",
        str(len(t)).encode("ascii"), t,
        str(len(body)).encode("ascii"), body,
    ])


def _http_get(url: str, insecure: bool) -> bytes:
    ctx = None
    if url.startswith("https"):
        ctx = ssl.create_default_context()
        if insecure:
            ctx.check_hostname = False
            ctx.verify_mode = ssl.CERT_NONE
    with urllib.request.urlopen(url, timeout=15, context=ctx) as r:
        return r.read()


def load_public_key(args):
    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey
    from cryptography.hazmat.primitives.serialization import load_pem_public_key
    if args.pubkey_pem:
        with open(args.pubkey_pem, "rb") as f:
            return load_pem_public_key(f.read())
    if args.pubkey_b64u:
        return Ed25519PublicKey.from_public_bytes(b64u_decode(args.pubkey_b64u))
    if args.pubkey_b64:
        return Ed25519PublicKey.from_public_bytes(base64.b64decode(args.pubkey_b64))
    # default: fetch from the server's /pubkey
    purl = args.pubkey_url or ((args.url or "").rstrip("/") + "/pubkey")
    if not purl:
        raise SystemExit("ERROR: no public key source (use --pubkey-* or --url)")
    meta = json.loads(_http_get(purl, args.insecure))
    if not meta.get("signed"):
        raise SystemExit("ERROR: /pubkey reports the server is running UNSIGNED")
    b64u = meta.get("public_key_b64u")
    if not b64u:
        raise SystemExit("ERROR: /pubkey returned no public_key_b64u")
    print(f"[pubkey] keyid={meta.get('keyid')} backend={meta.get('backend')} "
          f"alg={meta.get('alg')}")
    return Ed25519PublicKey.from_public_bytes(b64u_decode(b64u))


def load_receipts(args):
    if args.receipts:
        with open(args.receipts) as f:
            data = json.load(f)
    else:
        data = json.loads(_http_get(args.url.rstrip("/") + "/receipts", args.insecure))
    if isinstance(data, dict):
        data = data.get("receipts", [])
    return data


def envelope_hash(envelope: dict) -> str:
    canonical = json.dumps(envelope, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(canonical.encode()).hexdigest()



def canonical_payload_bytes(payload: dict) -> bytes:
    return json.dumps(payload, separators=(",", ":")).encode("utf-8")


def b64u(b: bytes) -> str:
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode()


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


def main():
    ap = argparse.ArgumentParser(description="Offline Ed25519 verifier for szl-receipts")
    ap.add_argument("--url", help="receipts server base URL (uses /receipts and /pubkey)")
    ap.add_argument("--receipts", help="JSON file of receipts instead of --url")
    ap.add_argument("--pubkey-url", help="explicit /pubkey URL")
    ap.add_argument("--pubkey-b64u", help="raw Ed25519 public key, base64url")
    ap.add_argument("--pubkey-b64", help="raw Ed25519 public key, std base64")
    ap.add_argument("--pubkey-pem", help="PEM public key file")
    ap.add_argument("-k", "--insecure", action="store_true", help="skip TLS verify")
    ap.add_argument("--allow-unsigned", action="store_true",
                    help="do not fail on UNSIGNED sentinel receipts")
    ap.add_argument("--self-test", action="store_true",
                    help="generate a fresh ephemeral-key chain and verify it (no network)")
    ap.add_argument("--count", type=int, default=4,
                    help="number of receipts to generate in --self-test (default 4)")
    args = ap.parse_args()

    if args.self_test:
        sys.exit(self_test(max(1, args.count)))

    if not args.url and not args.receipts:
        ap.error("provide --url, --receipts, or --self-test")

    try:
        from cryptography.exceptions import InvalidSignature
    except Exception:
        raise SystemExit("ERROR: pip install cryptography")

    pub = load_public_key(args)
    receipts = load_receipts(args)
    print(f"[receipts] loaded {len(receipts)}")

    ok = 0
    unsigned = 0
    bad_sig = 0
    bad_chain = 0
    prev = "GENESIS"

    # Order by chain_index for the chain walk (server returns creation order).
    receipts = sorted(receipts, key=lambda r: r.get("chain", {}).get("chain_index", 0))

    for i, rec in enumerate(receipts):
        env = rec.get("envelope", {})
        sigs = env.get("signatures", [])
        sig = sigs[0].get("sig", "") if sigs else ""
        payload_type = env.get("payloadType", "application/vnd.szl.receipt.v1+json")
        idx = rec.get("chain", {}).get("chain_index", i)

        # 1) chain linkage
        rec_prev = rec.get("chain", {}).get("prev_hash")
        if rec_prev != prev:
            print(f"  ✗ receipt[{idx}] chain break: prev_hash={rec_prev} expected={prev}")
            bad_chain += 1
        # 2) envelope hash matches the stored chain.hash
        h = envelope_hash(env)
        stored = rec.get("chain", {}).get("hash")
        if stored and stored != h:
            print(f"  ✗ receipt[{idx}] envelope hash mismatch: {h[:12]}… != {stored[:12]}…")
            bad_chain += 1
        prev = stored or h

        # 3) signature
        if not sig or sig.startswith("UNSIGNED"):
            print(f"  ⚠ receipt[{idx}] UNSIGNED ({sig or 'no-sig'})")
            unsigned += 1
            continue
        try:
            body = base64.b64decode(env["payload"])
            pae = dsse_pae(payload_type, body)
            pub.verify(b64u_decode(sig), pae)
            ok += 1
        except Exception as e:
            print(f"  ✗ receipt[{idx}] BAD SIGNATURE: {e}")
            bad_sig += 1

    print(f"\n[summary] verified={ok} unsigned={unsigned} "
          f"bad_signature={bad_sig} chain_errors={bad_chain} total={len(receipts)}")

    failed = bad_sig > 0 or bad_chain > 0 or (unsigned > 0 and not args.allow_unsigned)
    if failed:
        print("[result] FAIL")
        sys.exit(1)
    print("[result] PASS — all signed receipts verify offline and the chain is intact")
    sys.exit(0)


if __name__ == "__main__":
    main()
