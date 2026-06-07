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
import argparse
import base64
import hashlib
import json
import ssl
import sys
import urllib.request


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
    args = ap.parse_args()

    if not args.url and not args.receipts:
        ap.error("provide --url or --receipts")

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
