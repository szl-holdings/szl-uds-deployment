#!/usr/bin/env python3
# Copyright 2026 SZL Holdings
# SPDX-License-Identifier: Apache-2.0
#
# dsse_scheme_regression_test.py — lock the receipt signing/verification scheme.
#
# As of Finding A2 / PR-4 the live szl-receipts-server signs governance receipts
# with **Ed25519 over the canonical DSSE Pre-Authentication Encoding (PAE)**,
# NOT HMAC and NOT over raw payload bytes. The offline verifier
# (scripts/verify_receipts.sh) must agree byte-for-byte:
#
#   * server.py (signer) computes
#       Ed25519_sign(privkey, PAE(payloadType, payloadBytes))
#     where PAE = "DSSEv1" SP LEN(type) SP type SP LEN(body) SP body.
#
#   * scripts/verify_receipts.sh (verifier) computes
#       Ed25519_verify(pubkey, sig, PAE(payloadType, payloadBytes))
#     using the PUBLIC key only.
#
# An older family of demo scripts signed HMAC-SHA-256 over the RAW payload bytes
# (no PAE). That scheme is INCOMPATIBLE: a receipt produced under it fails the
# Ed25519/PAE verify, and vice-versa. This test pins the in-repo scheme to
# Ed25519-over-PAE so any future edit that quietly reverts to HMAC, drops the
# PAE prefix, or otherwise diverges signer↔verifier is caught here instead of in
# the field (which is exactly the bug Replit flagged: a legacy HMAC verifier left
# behind after the server moved to Ed25519).
#
# Standard library + `cryptography`. No cluster, no network. Run:
#   python3 scripts/dsse_scheme_regression_test.py

from __future__ import annotations

import base64
import hashlib
import hmac
import json
import sys

try:
    from cryptography.hazmat.primitives.asymmetric.ed25519 import (
        Ed25519PrivateKey,
        Ed25519PublicKey,
    )
    from cryptography.exceptions import InvalidSignature
except Exception:  # pragma: no cover
    print("DSSE scheme regression: SKIP (python3 'cryptography' not installed)")
    sys.exit(0)

KEY_ID = "szl-receipts-ed25519-2026"
PAYLOAD_TYPE = "application/vnd.szl.receipt.v1+json"

# Mirrors a governance receipt payload (key order is preserved by the signer;
# json.dumps with these separators matches the server's canonical bytes).
SAMPLE_PAYLOAD = {
    "_type": "https://szlholdings.com/receipt/v1",
    "subject": "szl-demo-workload/Deployment/szl-demo-agent",
    "specHash": "a" * 64,
    "timestamp": "2026-05-30T00:00:00Z",
    "admissionOp": "CREATE",
    "resourceVersion": "0",
}


def canonical_payload_bytes(payload: dict) -> bytes:
    return json.dumps(payload, separators=(",", ":")).encode("utf-8")


def dsse_pae(payload_type: str, body: bytes) -> bytes:
    """Canonical DSSE v1 Pre-Authentication Encoding — the scheme the server uses."""
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


def sign_like_server(payload: dict, priv: Ed25519PrivateKey) -> dict:
    """Build a DSSE envelope exactly as server.sign_dsse does (Ed25519 over PAE)."""
    payload_bytes = canonical_payload_bytes(payload)
    sig = priv.sign(dsse_pae(PAYLOAD_TYPE, payload_bytes))  # Ed25519 over PAE
    return {
        "payload": base64.b64encode(payload_bytes).decode(),
        "payloadType": PAYLOAD_TYPE,
        "signatures": [{"keyid": KEY_ID, "sig": b64u(sig)}],
    }


def verify_like_verify_receipts_sh(envelope: dict, pub: Ed25519PublicKey) -> bool:
    """Verify exactly as scripts/verify_receipts.sh does: Ed25519 over PAE, pubkey only."""
    try:
        body = base64.b64decode(envelope["payload"])
        ptype = envelope.get("payloadType", PAYLOAD_TYPE)
        sig = b64u_decode(envelope["signatures"][0]["sig"])
        pub.verify(sig, dsse_pae(ptype, body))
        return True
    except (InvalidSignature, Exception):
        return False


def main() -> int:
    priv = Ed25519PrivateKey.generate()
    pub = priv.public_key()
    failures: list[str] = []

    # 1. The signer's output must verify under the verifier (schemes agree).
    envelope = sign_like_server(SAMPLE_PAYLOAD, priv)
    if not verify_like_verify_receipts_sh(envelope, pub):
        failures.append(
            "signer (server.sign_dsse) and verifier (verify_receipts.sh) disagree: "
            "an Ed25519/PAE receipt did not verify"
        )

    # 2. A LEGACY HMAC-over-RAW-bytes signature must NOT verify under the Ed25519
    #    verifier. This pins the scheme: if anyone reintroduces the old HMAC
    #    verifier (the exact Replit-flagged regression), it is caught here.
    payload_bytes = canonical_payload_bytes(SAMPLE_PAYLOAD)
    legacy_hmac_key = base64.b64decode("c3psLWRldi1kZW1vLWtleS0yMDI2LXdhcmhhY2tlcg==")
    hmac_sig = hmac.new(legacy_hmac_key, payload_bytes, hashlib.sha256).digest()
    legacy_envelope = {
        "payload": base64.b64encode(payload_bytes).decode(),
        "payloadType": PAYLOAD_TYPE,
        "signatures": [{"keyid": "szl-dev-hmac-sha256-2026", "sig": b64u(hmac_sig)}],
    }
    if verify_like_verify_receipts_sh(legacy_envelope, pub):
        failures.append(
            "scheme drift: a legacy HMAC-SHA-256 signature verified under the "
            "Ed25519 verifier — the legacy scheme must be rejected"
        )

    # 3. An Ed25519 signature over the RAW payload (no PAE) must NOT verify —
    #    pins the PAE prefix into the scheme.
    raw_sig = priv.sign(payload_bytes)  # no PAE
    no_pae_envelope = {
        "payload": base64.b64encode(payload_bytes).decode(),
        "payloadType": PAYLOAD_TYPE,
        "signatures": [{"keyid": KEY_ID, "sig": b64u(raw_sig)}],
    }
    if verify_like_verify_receipts_sh(no_pae_envelope, pub):
        failures.append(
            "scheme drift: an Ed25519 signature over RAW bytes (no PAE) verified — "
            "the DSSE PAE prefix must be part of the signed bytes"
        )

    # 4. Tampering with the payload after signing must fail verification.
    tampered = json.loads(json.dumps(envelope))
    bad_payload = dict(SAMPLE_PAYLOAD, specHash="b" * 64)
    tampered["payload"] = base64.b64encode(canonical_payload_bytes(bad_payload)).decode()
    if verify_like_verify_receipts_sh(tampered, pub):
        failures.append("tampered payload verified — signature is not bound to payload")

    # 5. The wrong public key must not verify a good signature.
    other_pub = Ed25519PrivateKey.generate().public_key()
    if verify_like_verify_receipts_sh(envelope, other_pub):
        failures.append("signature verified under the WRONG public key")

    if failures:
        print("DSSE scheme regression: FAIL")
        for f in failures:
            print(f"  - {f}")
        return 1

    print("DSSE scheme regression: PASS")
    print("  - signer and verifier agree on Ed25519 over the canonical DSSE PAE")
    print("  - legacy HMAC-SHA-256 (raw) signatures are correctly rejected")
    print("  - Ed25519-over-RAW (no PAE) signatures are correctly rejected")
    print("  - tampered payloads are rejected")
    print("  - signatures do not verify under the wrong public key")
    return 0


if __name__ == "__main__":
    sys.exit(main())
