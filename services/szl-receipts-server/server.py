#!/usr/bin/env python3
# Copyright 2026 SZL Holdings
# SPDX-License-Identifier: Apache-2.0
#
# SZL Receipts server.
#
# Extracted from charts/szl-receipts/templates/configmap.yaml (inline source)
# and refactored for v0.3.1 per PhD Systems Scope 6 (durability) and PhD Crypto
# Finding A2 (signature scheme) + Finding A1 (canonical DSSE PAE).
#
# HTTP surface (unchanged from the ConfigMap build, with additions noted):
#   POST /receipt    — accept a receipt body, sign it, append it to the chain
#   GET  /receipts   — return all stored receipts as JSON
#   GET  /pubkey     — publish the active signing public key (Ed25519, base64url)
#   GET  /stream     — SSE stream of new receipts for the dashboard
#   GET  /health     — readiness/liveness probe (preserved)
#   GET  /healthz    — readiness/liveness probe (alias; matches Dockerfile HEALTHCHECK)
#   GET  /metrics    — Prometheus-compatible counters (preserved)
#
# Changes in v0.3.1:
#   1. Receipts are signed with Ed25519 (cryptography.hazmat) instead of
#      HMAC-SHA-256. The private key is loaded from a PEM file
#      (SZL_ED25519_KEY_PATH, default /run/secrets/szl-receipts/ed25519.pem).
#      The signature is a base64url-encoded 64-byte Ed25519 signature placed in
#      the DSSE envelope's signatures[].sig, with a stable keyid.
#   2. The signature is computed over the canonical DSSE PAE:
#         "DSSEv1" SP LEN(type) SP type SP LEN(body) SP body
#      where SP = 0x20 and LEN is ASCII decimal. (PhD_CRYPTO_VERDICT Finding A1.)
#   3. Each receipt carries a chain block {prev_hash, hash, chain_index} and a
#      created_at timestamp. On startup the server walks STORE_PATH, rehydrates
#      the in-memory _receipts list ordered by created_at, and reconstructs the
#      chain pointers by reading each JSON's chain.prev_hash. It logs the count.
#   4. A boot OTel span (szl_receipts.boot) is emitted on startup and a per-POST
#      span (szl_receipts.append) is emitted on each receipt, exported via OTLP
#      gRPC when OTEL_EXPORTER_OTLP_ENDPOINT is set (default unset = no export).
#
# Changes in v0.4.0 — KEY CUSTODY (Tier 1 / Tier 2; see docs/KEY_CUSTODY_RUNBOOK.md):
#   5. The signer is now a pluggable backend selected by SZL_SIGNING_BACKEND:
#        * "file"  (default) — Ed25519 PEM mounted from a Kubernetes Secret
#                   (Tier 0 software key; same behaviour as v0.3.1). A
#                   SealedSecret (Tier 1) feeds the SAME Secret with no code
#                   change — the encrypted blob is safe to commit to git.
#        * "vault" — HashiCorp Vault Transit "signing as a service" (Tier 2,
#                   managed-KMS custody). The Ed25519 private key is GENERATED
#                   AND HELD INSIDE Vault and NEVER leaves it: the server sends
#                   the DSSE PAE to Vault's transit/sign endpoint and receives
#                   back the 64-byte Ed25519 signature. The pod holds only a
#                   short-lived Vault token (Kubernetes auth) or a token Secret —
#                   reading a Kubernetes Secret no longer yields the private key.
#   6. The receipt DSSE envelope is byte-for-byte identical across backends: a
#      raw 64-byte Ed25519 signature, base64url-encoded, over the canonical PAE.
#      So the offline verifier (rebuild PAE, base64url-decode sig, Ed25519-verify
#      against the published public key) works unchanged for either backend.
#   7. GET /pubkey publishes the active signing public key (raw Ed25519, both
#      base64url and base64-std) plus the keyid and backend, so verifiers can
#      fetch the published key for independent offline verification.
#
# Honest labeling: with backend=file this is an Ed25519 SOFTWARE-key signer — the
# private key lives in a Kubernetes Secret (Tier 0; SealedSecret = Tier 1 closes
# the git-leak hole but the decrypted key still exists in-cluster). With
# backend=vault the private key never exists in cluster etcd or pod memory —
# this is the Tier 2 managed-KMS custody path (HSM-grade assurance depends on the
# Vault seal). See PhD_CRYPTO_VERDICT section I and docs/KEY_CUSTODY_RUNBOOK.md.

import os
import ssl
import sys
import json
import time
import heapq
import shlex
import shutil
import base64
import hashlib
import tarfile
import tempfile
import threading
import subprocess
import urllib.request
import urllib.error
from http.server import HTTPServer, ThreadingHTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse

# ── Configuration ─────────────────────────────────────────────────────────────

PORT       = int(os.environ.get("SZL_PORT", 8080))
STORE_PATH = os.environ.get("SZL_RECEIPT_STORE", "/data/receipts")
LOG_LEVEL  = os.environ.get("SZL_LOG_LEVEL", "info")

# Key-custody backend: "file" (Ed25519 PEM from a k8s Secret; default) or
# "vault" (HashiCorp Vault Transit managed-KMS custody — key never leaves Vault).
SIGNING_BACKEND = os.environ.get("SZL_SIGNING_BACKEND", "file").strip().lower()

# Ed25519 private key (PEM, PKCS#8 or OpenSSH-unencrypted) mounted from a Secret.
# Used only by the "file" backend.
ED25519_KEY_PATH = os.environ.get(
    "SZL_ED25519_KEY_PATH", "/run/secrets/szl-receipts/ed25519.pem"
)
# Stable identifier for the signing key, surfaced in DSSE signatures[].keyid.
KEY_ID = os.environ.get("SZL_KEY_ID", "szl-receipts-ed25519-2026")

# DSSE payloadType for SZL governance receipts.
PAYLOAD_TYPE = "application/vnd.szl.receipt.v1+json"

# Genesis sentinel for the first receipt's prev_hash.
GENESIS = "GENESIS"

# Signer self-healing: if the signing backend (e.g. Vault Transit) is sealed or
# unreachable at boot, the signer starts UNAVAILABLE. Rather than requiring a pod
# restart to recover, the server lazily re-establishes the signer — on the sign
# path, on a /pubkey read, and via a background watchdog — so signing resumes on
# its own once the backend is healthy again (no restart, no pod delete needed).
# Tunables (seconds): the minimum gap between on-demand re-init attempts (so a
# burst of requests can't hammer Vault) and the background watchdog cadence.
SIGNER_REINIT_MIN_INTERVAL = float(os.environ.get("SZL_SIGNER_REINIT_INTERVAL", "10"))
SIGNER_RECHECK_INTERVAL    = float(os.environ.get("SZL_SIGNER_RECHECK_INTERVAL", "30"))

# Memory-bounded chain handling. The receipt store is append-only and grows
# without bound (one file per receipt). Loading the WHOLE store into memory at
# boot — or on every /metrics scrape, or on a /receipts dump — OOM-kills the
# process once the chain reaches tens/hundreds of thousands of receipts, which
# crashloops the signer and takes signing down. Instead we:
#   * persist a tiny head pointer (.chain_head) updated on every append, so boot
#     reconstructs the chain head/index in O(1) without scanning the store;
#   * keep only the most-recent MAX_IN_MEMORY receipts in RAM (for the live
#     /receipts list, /stream replay, and the integrity gauge), trimming older
#     ones — the full history stays durable on disk for offline verification.
# Tunable via SZL_MAX_IN_MEMORY_RECEIPTS (default 2000).
MAX_IN_MEMORY = max(1, int(os.environ.get("SZL_MAX_IN_MEMORY_RECEIPTS", "2000")))
# Head-pointer file. Deliberately has NO ".json" suffix so the store scans
# (which filter on .endswith(".json")) never pick it up as a receipt.
HEAD_FILE = os.path.join(STORE_PATH, ".chain_head")

# ── Receipt store sharding ──────────────────────────────────────────────────
# A single flat directory holding hundreds of thousands of receipt files hurts
# filesystem performance, backups and integrity scans, even though RAM is now
# bounded. New receipts are therefore written into index-sharded subdirectories
# under <store>/shards/<bucket>/, where bucket = chain_index // SHARD_SIZE
# (zero-padded). Each bucket holds a CONTIGUOUS range of the chain, which keeps
# every directory bounded and lets a completed ("sealed") bucket be tar'd to
# cold storage while preserving end-to-end chain verifiability — prev_hash links
# still chain across bucket boundaries, so an offline auditor can verify the full
# history one bounded bucket at a time.
#
# Legacy receipts written before this change remain flat in the store root and
# are still read and verified — sharding is additive and backward compatible.
# Set SZL_RECEIPT_SHARD_SIZE=0 to disable sharding (write flat, legacy mode).
SHARD_SIZE = max(0, int(os.environ.get("SZL_RECEIPT_SHARD_SIZE", "10000")))
SHARDS_DIR = os.path.join(STORE_PATH, "shards")
# --- Ingest rate limiting (anti-flood) ---------------------------------------
# A runaway minting loop -- a reconcile hot-loop, a misbehaving emitter, or a
# stuck test/daemon POSTing to /receipt -- can push thousands of receipts/sec
# into this append-only chain, ballooning the on-disk store and crash-looping
# the signer under memory/CPU pressure (observed: chain past 267k, repeated
# OOMKills on the 2-vCPU box). A token-bucket gate on POST /receipt caps the
# SUSTAINED accept rate while allowing a short burst, so genuine, spaced events
# (a real deploy mints a handful of receipts) still chain, but a flood is shed
# with HTTP 429. The pepr deploy webhook POST path is fail-open, so a 429 just
# drops the excess receipt without blocking admission. Set rate<=0 to disable.
INGEST_RATE_LIMIT = float(os.environ.get("SZL_INGEST_RATE_LIMIT", "1.0"))   # receipts/sec sustained
INGEST_BURST      = max(1.0, float(os.environ.get("SZL_INGEST_BURST", "60")))  # max burst tokens
_ingest_tokens = INGEST_BURST
_ingest_last   = time.monotonic()
_ingest_lock   = threading.Lock()


def _ingest_allowed():
    """Token-bucket gate for POST /receipt. Refills INGEST_RATE_LIMIT tokens/sec
    up to INGEST_BURST and consumes one token per accepted receipt; returns
    False (shed the request) when the bucket is empty. Always True when the
    configured rate is <= 0 (limiter disabled)."""
    if INGEST_RATE_LIMIT <= 0:
        return True
    global _ingest_tokens, _ingest_last
    with _ingest_lock:
        now = time.monotonic()
        _ingest_tokens = min(
            INGEST_BURST,
            _ingest_tokens + (now - _ingest_last) * INGEST_RATE_LIMIT,
        )
        _ingest_last = now
        if _ingest_tokens >= 1.0:
            _ingest_tokens -= 1.0
            return True
        return False


os.makedirs(STORE_PATH, exist_ok=True)

_receipts      = []
_receipt_lock  = threading.Lock()
_sse_clients   = []
_client_lock   = threading.Lock()
_counter_total = 0
_counter_valid = 0
_counter_deny  = 0         # # SZL-METRICS-129 receipts whose verdict is DENY
_counter_allow = 0         # receipts whose verdict is ALLOW
_counter_tamper = 0        # persisted receipts found tampered at rest (once per id)
_counter_throttled = 0     # POST /receipt requests shed by the ingest rate limit
_chain_head    = GENESIS   # hash of the most recent receipt, or GENESIS
_chain_index   = 0         # next chain index to assign
_persisted_count = 0       # receipts on disk; seeded at boot, ++ per append (avoids
                           # re-scanning the unbounded store on every receipt write)
_chain_valid_flag = 1      # gauge: 1 if the last integrity scan found the chain intact
_chain_len     = 0         # gauge: receipts on disk at the last integrity scan
_tampered_ids  = set()     # ids already counted as tampered (keep the counter monotonic)
_integrity_lock = threading.Lock()

_signer         = None     # active Signer instance (set in boot())
_public_key_b64 = None     # base64url raw public key, for diagnostics/back-compat


def log(level, msg):
    if LOG_LEVEL == "debug" or level in ("info", "warn", "error"):
        print(f"[{level.upper()}] {time.strftime('%Y-%m-%dT%H:%M:%SZ')} {msg}", flush=True)


# ── base64url helpers (no padding, per JOSE/DSSE convention) ───────────────────

def b64u_encode(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode("ascii")


def b64u_decode(s: str) -> bytes:
    pad = "=" * (-len(s) % 4)
    return base64.urlsafe_b64decode(s + pad)


# ── DSSE canonical Pre-Authentication Encoding ─────────────────────────────────

def dsse_pae(payload_type: str, body: bytes) -> bytes:
    """Canonical DSSE Pre-Authentication Encoding (DSSEv1).

    PAE = "DSSEv1" SP LEN(type) SP type SP LEN(body) SP body
    where SP = 0x20 (single space) and LEN is the ASCII-decimal byte length.
    Ref: github.com/secure-systems-lab/dsse/protocol.md
         PhD_CRYPTO_VERDICT.md Finding A1."""
    type_bytes = payload_type.encode("utf-8")
    return b" ".join([
        b"DSSEv1",
        str(len(type_bytes)).encode("ascii"),
        type_bytes,
        str(len(body)).encode("ascii"),
        body,
    ])


# ── Signing backends ───────────────────────────────────────────────────────────
#
# Every backend produces the SAME wire format: a raw 64-byte Ed25519 signature
# over PAE(PAYLOAD_TYPE, payload_bytes). Only the custody of the private key
# differs. `available` is True only when a real signing key is present; otherwise
# the server runs in honest UNSIGNED mode (it never fabricates a signature).

class SignerUnavailable(Exception):
    """Raised when a backend cannot sign (no key / not authenticated)."""


class BaseSigner:
    backend = "base"

    def __init__(self):
        self.key_id = KEY_ID
        self.public_key_raw = None   # 32-byte raw Ed25519 public key, or None
        self._reinit_lock = threading.Lock()
        self._last_reinit = 0.0      # monotonic time of the last re-init attempt

    @property
    def available(self) -> bool:
        return self.public_key_raw is not None

    def _reinit(self):
        """Backend-specific attempt to (re-)establish signing capability.

        Override in subclasses. Must set self.public_key_raw on success and be
        safe to call repeatedly. Default is a no-op (nothing to recover)."""
        return

    def ensure_available(self, force: bool = False) -> bool:
        """Return True if the signer can sign, attempting a throttled re-init if
        it currently cannot.

        This is what lets an already-running server recover with NO restart: if
        the backend (e.g. Vault) was sealed/unreachable at boot — or was sealed
        after boot — the signer comes up unavailable; the next sign attempt,
        /pubkey read, or background watchdog tick calls this, which retries the
        backend handshake and flips the signer back to available once the backend
        is healthy again. Throttled by SIGNER_REINIT_MIN_INTERVAL so a burst of
        requests can't hammer the backend. Thread-safe and never raises."""
        if self.available:
            return True
        now = time.monotonic()
        with self._reinit_lock:
            if self.available:
                return True
            if not force and (now - self._last_reinit) < SIGNER_REINIT_MIN_INTERVAL:
                return False
            self._last_reinit = now
            try:
                self._reinit()
            except Exception as e:
                log("debug", f"signer re-init attempt failed: {e}")
        return self.available

    @property
    def public_key_b64u(self):
        return b64u_encode(self.public_key_raw) if self.public_key_raw else None

    def sign(self, pae: bytes) -> bytes:
        """Return the raw 64-byte Ed25519 signature over `pae`."""
        raise NotImplementedError

    def verify(self, pae: bytes, raw_sig: bytes) -> bool:
        """Verify a raw Ed25519 signature against the published public key.

        Verification is always done locally against the public key — the same
        check an external auditor runs offline — so it is identical regardless
        of where the private key lives."""
        if not self.public_key_raw:
            return False
        try:
            from cryptography.hazmat.primitives.asymmetric.ed25519 import (
                Ed25519PublicKey,
            )
            Ed25519PublicKey.from_public_bytes(self.public_key_raw).verify(
                raw_sig, pae
            )
            return True
        except Exception as e:
            log("debug", f"verify failed: {e}")
            return False


class FileSigner(BaseSigner):
    """Tier 0/1: Ed25519 private key read from a PEM file mounted from a Secret.

    Tier 1 (SealedSecret) feeds the SAME Secret with an encrypted blob that is
    safe to commit to git; from this signer's perspective nothing changes — it
    still reads the decrypted PEM the controller materializes."""

    backend = "file"

    def __init__(self):
        super().__init__()
        self._key = None
        self._load()

    def _load(self):
        try:
            from cryptography.hazmat.primitives.serialization import (
                load_pem_private_key, Encoding, PublicFormat,
            )
            from cryptography.hazmat.primitives.asymmetric.ed25519 import (
                Ed25519PrivateKey,
            )
        except Exception as e:  # cryptography missing
            log("warn", f"cryptography unavailable, running unsigned: {e}")
            return

        if not os.path.exists(ED25519_KEY_PATH):
            log("warn",
                f"Ed25519 key not found at {ED25519_KEY_PATH}; running unsigned "
                f"(operator must provision the szl-receipts-ed25519 secret, or "
                f"set SZL_SIGNING_BACKEND=vault for KMS custody)")
            return

        try:
            with open(ED25519_KEY_PATH, "rb") as f:
                pem = f.read()
            key = load_pem_private_key(pem, password=None)
            if not isinstance(key, Ed25519PrivateKey):
                log("error", "loaded key is not Ed25519; running unsigned")
                return
            self._key = key
            self.public_key_raw = key.public_key().public_bytes(
                Encoding.Raw, PublicFormat.Raw
            )
            log("info",
                f"[file] Ed25519 signing key loaded; keyid={self.key_id} "
                f"pub={self.public_key_b64u}")
        except Exception as e:
            log("error", f"failed to load Ed25519 key, running unsigned: {e}")

    def _reinit(self):
        # The Secret/PEM may be provisioned after boot (e.g. a SealedSecret
        # controller materialises it late); re-read it so signing can start
        # without a pod restart. _load() is idempotent and silent on absence.
        self._load()

    def sign(self, pae: bytes) -> bytes:
        if self._key is None:
            raise SignerUnavailable("no Ed25519 file key loaded")
        return self._key.sign(pae)  # 64 bytes for Ed25519


class VaultTransitSigner(BaseSigner):
    """Tier 2: HashiCorp Vault Transit "signing as a service" (managed KMS).

    The Ed25519 private key is generated and held inside Vault and NEVER leaves
    it. The server authenticates to Vault (Kubernetes auth by default, or a
    token Secret), fetches the PUBLIC key for local/offline verification, and
    asks Vault to sign the DSSE PAE. Reading a Kubernetes Secret no longer
    yields the private key — that is the single-Secret compromise path this
    backend removes."""

    backend = "vault"

    def __init__(self):
        super().__init__()
        self.addr = os.environ.get("VAULT_ADDR", "").rstrip("/")
        self.mount = os.environ.get("SZL_VAULT_TRANSIT_MOUNT", "transit").strip("/")
        self.key_name = os.environ.get("SZL_VAULT_TRANSIT_KEY", "szl-receipts")
        self.namespace = os.environ.get("VAULT_NAMESPACE", "").strip()
        self.auth_method = os.environ.get("SZL_VAULT_AUTH_METHOD", "kubernetes").strip().lower()
        self.k8s_role = os.environ.get("SZL_VAULT_K8S_ROLE", "szl-receipts")
        self.k8s_auth_mount = os.environ.get("SZL_VAULT_K8S_AUTH_MOUNT", "kubernetes").strip("/")
        self.sa_token_path = os.environ.get(
            "SZL_VAULT_SA_TOKEN_PATH",
            "/var/run/secrets/kubernetes.io/serviceaccount/token",
        )
        self.skip_verify = os.environ.get("VAULT_SKIP_VERIFY", "").strip().lower() in ("1", "true", "yes")
        self.cacert = os.environ.get("VAULT_CACERT", "").strip()
        self.timeout = float(os.environ.get("SZL_VAULT_TIMEOUT", "10"))
        self._base_key_id = os.environ.get("SZL_KEY_ID", KEY_ID)
        self._token = None
        self._key_version = None
        self._init()

    # ── HTTP plumbing (stdlib only; no hvac dependency) ────────────────────────

    def _ctx(self):
        if not self.addr.startswith("https"):
            return None
        if self.skip_verify:
            c = ssl.create_default_context()
            c.check_hostname = False
            c.verify_mode = ssl.CERT_NONE
            return c
        if self.cacert:
            return ssl.create_default_context(cafile=self.cacert)
        return ssl.create_default_context()

    def _request(self, method, path, payload=None, token=None):
        url = f"{self.addr}/v1/{path}"
        data = json.dumps(payload).encode() if payload is not None else None
        req = urllib.request.Request(url, data=data, method=method)
        req.add_header("Content-Type", "application/json")
        if token:
            req.add_header("X-Vault-Token", token)
        if self.namespace:
            req.add_header("X-Vault-Namespace", self.namespace)
        with urllib.request.urlopen(req, timeout=self.timeout, context=self._ctx()) as r:
            return json.loads(r.read().decode())

    # ── Auth ───────────────────────────────────────────────────────────────────

    def _login(self):
        if self.auth_method == "token":
            tok = os.environ.get("VAULT_TOKEN", "").strip()
            if not tok:
                raise SignerUnavailable("VAULT_TOKEN empty for token auth")
            return tok
        # Kubernetes auth: present the pod's projected ServiceAccount JWT.
        with open(self.sa_token_path) as f:
            jwt = f.read().strip()
        resp = self._request(
            "POST", f"auth/{self.k8s_auth_mount}/login",
            {"role": self.k8s_role, "jwt": jwt},
        )
        return resp["auth"]["client_token"]

    # ── Public key (for offline verification + GET /pubkey) ────────────────────

    def _load_public_key(self):
        resp = self._request("GET", f"{self.mount}/keys/{self.key_name}", token=self._token)
        data = resp.get("data", {})
        if data.get("type") != "ed25519":
            raise SignerUnavailable(
                f"transit key {self.mount}/{self.key_name} type "
                f"{data.get('type')!r} is not ed25519")
        keys = data.get("keys", {})
        if not keys:
            raise SignerUnavailable("transit key has no versions")
        latest = data.get("latest_version") or max(int(k) for k in keys)
        self._key_version = str(latest)
        pub = keys[self._key_version].get("public_key", "")
        if not pub:
            raise SignerUnavailable("transit key version has no public_key")
        if pub.startswith("-----BEGIN"):
            from cryptography.hazmat.primitives.serialization import (
                load_pem_public_key, Encoding, PublicFormat,
            )
            pk = load_pem_public_key(pub.encode())
            self.public_key_raw = pk.public_bytes(Encoding.Raw, PublicFormat.Raw)
        else:
            # Vault returns the Ed25519 public key as base64-std of 32 raw bytes.
            self.public_key_raw = base64.b64decode(pub)
        # Surface the Vault key version in the keyid so rotation is auditable.
        self.key_id = f"{self._base_key_id}:vault-v{self._key_version}"

    def _init(self):
        if not self.addr:
            log("warn", "[vault] VAULT_ADDR unset; running unsigned "
                        "(set signing.vault.address)")
            return
        try:
            self._token = self._login()
            self._load_public_key()
            log("info",
                f"[vault] Transit signer ready; addr={self.addr} "
                f"key={self.mount}/{self.key_name} keyid={self.key_id} "
                f"auth={self.auth_method} pub={self.public_key_b64u}")
        except Exception as e:
            log("error", f"[vault] init failed, running unsigned: {e}")
            self._token = None
            self.public_key_raw = None

    def _reinit(self):
        # Re-run the Vault handshake (login + fetch public key). This is the
        # recovery path: when the server booted while Vault was sealed/unreachable
        # and Vault has since been unsealed, this re-establishes the signer with
        # NO pod restart. _init() resets state on failure so it stays honest.
        self._init()

    # ── Signing ──────────────────────────────────────────────────────────────

    def _sign_once(self, inp_b64):
        resp = self._request(
            "POST", f"{self.mount}/sign/{self.key_name}",
            {"input": inp_b64}, token=self._token,
        )
        sig = resp["data"]["signature"]   # "vault:vN:<base64-std>"
        return base64.b64decode(sig.split(":")[-1])

    def sign(self, pae: bytes) -> bytes:
        if not self._token:
            raise SignerUnavailable("vault not authenticated")
        inp = base64.b64encode(pae).decode("ascii")
        try:
            return self._sign_once(inp)
        except urllib.error.HTTPError as e:
            if e.code in (401, 403):
                # token may have expired; re-login once and retry.
                log("warn", "[vault] token rejected, re-authenticating")
                self._token = self._login()
                return self._sign_once(inp)
            raise


def build_signer():
    if SIGNING_BACKEND == "vault":
        return VaultTransitSigner()
    if SIGNING_BACKEND == "file":
        return FileSigner()
    log("warn", f"unknown SZL_SIGNING_BACKEND={SIGNING_BACKEND!r}; using file")
    return FileSigner()


# ── DSSE envelope (sign / verify) ──────────────────────────────────────────────

def sign_dsse(payload_bytes: bytes):
    """Return a DSSE envelope signing payload_bytes with Ed25519 via the active
    backend. The signature is over PAE(PAYLOAD_TYPE, payload_bytes). If no key
    is available, sig is an explicit unsigned sentinel (honest, not a forgery)."""
    payload_b64 = base64.b64encode(payload_bytes).decode("ascii")
    pae = dsse_pae(PAYLOAD_TYPE, payload_bytes)
    # ensure_available() retries a sealed/unreachable backend (throttled) so a
    # receipt that arrives after Vault is unsealed gets signed with no restart.
    if _signer is not None and _signer.ensure_available():
        try:
            raw_sig = _signer.sign(pae)   # 64 bytes for Ed25519
            sig_b64u = b64u_encode(raw_sig)
            keyid = _signer.key_id
        except Exception as e:
            log("error",
                f"signing failed (backend={getattr(_signer, 'backend', '?')}): {e}; "
                f"emitting unsigned sentinel")
            sig_b64u = "UNSIGNED-SIGNER-ERROR"
            keyid = f"{KEY_ID}#unsigned"
    else:
        sig_b64u = "UNSIGNED-NO-ED25519-KEY"
        keyid = f"{KEY_ID}#unsigned"
    return {
        "payload": payload_b64,
        "payloadType": PAYLOAD_TYPE,
        "signatures": [{"keyid": keyid, "sig": sig_b64u}],
    }


def verify_dsse(envelope: dict) -> bool:
    """Verify the Ed25519 signature on a DSSE envelope against the published
    public key. Returns False in unsigned mode or if verification fails.
    Verification is over the canonical PAE, matching sign_dsse."""
    if _signer is None or not _signer.available:
        return False
    try:
        payload_b64 = envelope.get("payload", "")
        sigs = envelope.get("signatures", [])
        payload_type = envelope.get("payloadType", PAYLOAD_TYPE)
        if not sigs:
            return False
        sig_b64u = sigs[0].get("sig", "")
        if not sig_b64u or sig_b64u.startswith("UNSIGNED"):
            return False
        body = base64.b64decode(payload_b64)
        pae = dsse_pae(payload_type, body)
        raw_sig = b64u_decode(sig_b64u)
        return _signer.verify(pae, raw_sig)
    except Exception as e:
        log("debug", f"DSSE verify failed: {e}")
        return False


# ── OpenTelemetry (optional; exported only when endpoint is set) ───────────────

_tracer = None


def _init_tracer():
    """Initialize an OTLP/gRPC tracer if OTEL_EXPORTER_OTLP_ENDPOINT is set.

    Returns a tracer or None. No-op (returns None) when the endpoint env var is
    unset, so the default posture is no export."""
    global _tracer
    endpoint = os.environ.get("OTEL_EXPORTER_OTLP_ENDPOINT")
    if not endpoint:
        log("info", "OTEL_EXPORTER_OTLP_ENDPOINT unset; OTel export disabled")
        return None
    try:
        from opentelemetry import trace
        from opentelemetry.sdk.resources import Resource
        from opentelemetry.sdk.trace import TracerProvider
        from opentelemetry.sdk.trace.export import BatchSpanProcessor
        from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import (
            OTLPSpanExporter,
        )
        service_name = os.environ.get("OTEL_SERVICE_NAME", "szl-receipts-server")
        resource = Resource.create({"service.name": service_name})
        provider = TracerProvider(resource=resource)
        exporter = OTLPSpanExporter(endpoint=endpoint)
        provider.add_span_processor(BatchSpanProcessor(exporter))
        trace.set_tracer_provider(provider)
        _tracer = trace.get_tracer("szl.receipts")
        log("info", f"OTel tracer initialized; endpoint={endpoint} service={service_name}")
        return _tracer
    except Exception as e:
        log("warn", f"OTel init failed, continuing without export: {e}")
        return None


def _span(name, attributes=None):
    """Context manager helper that emits an OTel span if a tracer exists, else
    a no-op context."""
    if _tracer is None:
        from contextlib import nullcontext
        return nullcontext()
    cm = _tracer.start_as_current_span(name)
    return _SpanWrapper(cm, attributes or {})


class _SpanWrapper:
    def __init__(self, cm, attributes):
        self._cm = cm
        self._attributes = attributes
        self._span = None

    def __enter__(self):
        self._span = self._cm.__enter__()
        try:
            for k, v in self._attributes.items():
                if v is not None:
                    self._span.set_attribute(k, v)
        except Exception:
            pass
        return self._span

    def __exit__(self, *args):
        return self._cm.__exit__(*args)


# ── Chain helpers ──────────────────────────────────────────────────────────────

def _receipt_hash(record: dict) -> str:
    """Stable SHA-256 over the receipt's signed envelope. Used as the chain link
    value (the next receipt's prev_hash)."""
    canonical = json.dumps(record["envelope"], sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(canonical.encode("utf-8")).hexdigest()


def _shard_bucket(chain_index):
    """Zero-padded shard bucket name for a chain index, or None when sharding is
    disabled (SHARD_SIZE <= 0). Buckets sort lexically in chain order."""
    if SHARD_SIZE <= 0:
        return None
    return f"{chain_index // SHARD_SIZE:08d}"


def _store_path_for(receipt_id, chain_index):
    """Absolute path a receipt is written to: an index-sharded subdir when
    sharding is enabled, else the (legacy) store root."""
    bucket = _shard_bucket(chain_index)
    if bucket is None:
        return os.path.join(STORE_PATH, f"{receipt_id}.json")
    return os.path.join(SHARDS_DIR, bucket, f"{receipt_id}.json")


def _iter_shard_buckets():
    """Yield (bucket_name, abs_dir) for every shard subdir, in chain order.
    Constant memory aside from the (small, bounded) list of bucket names."""
    try:
        buckets = sorted(
            (e.name, e.path) for e in os.scandir(SHARDS_DIR) if e.is_dir()
        )
    except FileNotFoundError:
        return
    for name, path in buckets:
        yield name, path


def _iter_receipt_files():
    """Yield absolute paths of every persisted receipt (.json) in the store, in
    CONSTANT memory: the legacy flat files in the store root first, then every
    sharded subdir under <store>/shards/ in chain order. A generator — it never
    materializes the full file list — so it stays bounded no matter how large the
    store grows (the fix that keeps the slow rehydrate path and the offline
    verifier from OOMing as the chain reaches hundreds of thousands of files)."""
    try:
        with os.scandir(STORE_PATH) as it:
            for e in it:
                if e.is_file() and e.name.endswith(".json"):
                    yield e.path
    except FileNotFoundError:
        return
    for _name, bdir in _iter_shard_buckets():
        try:
            with os.scandir(bdir) as it:
                for e in it:
                    if e.is_file() and e.name.endswith(".json"):
                        yield e.path
        except FileNotFoundError:
            continue


def _count_store():
    """Cheap count of persisted receipt files (no parsing) across the legacy flat
    root AND every shard subdir, in constant memory. Used to seed the persisted
    count at boot/fallback; the /metrics hot path uses the in-memory
    _persisted_count instead so a scrape never walks the (unbounded) store."""
    n = 0
    for _path in _iter_receipt_files():
        n += 1
    return n


def _write_head_pointer(chain_index, chain_head, count=None):
    """Atomically persist the chain head/index so the next boot can resume the
    chain in O(1) without scanning the (unbounded) store. Best-effort: a failure
    here never blocks a receipt append — the slow scan is always a valid fallback."""
    try:
        payload = {
            "chain_index": chain_index,
            "chain_head": chain_head,
            "count": count if count is not None else _count_store(),
            "updated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ"),
        }
        tmp = HEAD_FILE + ".tmp"
        with open(tmp, "w") as f:
            json.dump(payload, f)
        os.replace(tmp, HEAD_FILE)
    except Exception as e:
        log("warn", f"could not persist chain head pointer: {e}")


def _read_head_pointer():
    """Return the persisted head pointer dict, or None if absent/unreadable."""
    try:
        with open(HEAD_FILE, "r") as f:
            p = json.load(f)
        if isinstance(p, dict) and "chain_index" in p and "chain_head" in p:
            return p
    except FileNotFoundError:
        return None
    except Exception as e:
        log("warn", f"chain head pointer unreadable, falling back to scan: {e}")
    return None


def _rehydrate():
    """Reconstruct the chain head/index and a BOUNDED in-memory window of recent
    receipts, in O(1) memory.

    Fast path: read the persisted .chain_head pointer (updated on every append)
    to set chain_index/head instantly — no store scan, so boot stays fast and
    memory-flat even with hundreds of thousands of persisted receipts. The live
    in-memory list starts empty and forward-fills as new receipts arrive; the
    full history remains on disk for offline verification.

    Slow path (no pointer — e.g. a legacy store from before this change): stream
    every receipt ONCE in constant memory, tracking only the chain tail (max
    chain_index) and the most-recent MAX_IN_MEMORY receipts, then write the
    pointer so subsequent boots take the fast path."""
    global _receipts, _chain_head, _chain_index, _persisted_count

    ptr = _read_head_pointer()
    if ptr is not None:
        with _receipt_lock:
            _receipts = []
            _chain_head = ptr["chain_head"] or GENESIS
            _chain_index = int(ptr["chain_index"])
            _persisted_count = int(ptr.get("count") or 0)
        cnt = ptr.get("count")
        log("info", f"Rehydrated from head pointer; chain_index={_chain_index} "
                    f"head={str(_chain_head)[:12]}… persisted={cnt}")
        return _chain_index

    # Slow path: constant-memory streaming scan (no pointer yet). Streams over
    # the legacy flat root AND every shard subdir via the _iter_receipt_files
    # generator, so the scan never materializes the full (unbounded) file list.

    def _key(r):
        return (
            r.get("created_at", ""),
            r.get("chain", {}).get("chain_index", 0),
        )

    tail = None          # receipt with the highest (created_at, chain_index)
    recent = []          # bounded heap (by _key) of the most-recent MAX_IN_MEMORY
    scanned = 0
    for path in _iter_receipt_files():
        try:
            with open(path, "r") as f:
                rec = json.load(f)
        except Exception as e:
            log("warn", f"skipping unreadable receipt {os.path.basename(path)}: {e}")
            continue
        scanned += 1
        k = _key(rec)
        if tail is None or k > _key(tail):
            tail = rec
        # Keep only the MAX_IN_MEMORY most-recent receipts (min-heap on _key).
        heapq.heappush(recent, (k, rec.get("id", ""), rec))
        if len(recent) > MAX_IN_MEMORY:
            heapq.heappop(recent)

    window = [item[2] for item in sorted(recent, key=lambda t: t[0])]

    with _receipt_lock:
        _receipts = window
        if tail is not None:
            _chain_head = tail.get("chain", {}).get("hash") or _receipt_hash(tail)
            _chain_index = tail.get("chain", {}).get("chain_index", scanned - 1) + 1
        else:
            _chain_head = GENESIS
            _chain_index = 0

    _persisted_count = scanned
    if tail is not None:
        _write_head_pointer(_chain_index, _chain_head, count=scanned)
    log("info", f"Rehydrated via scan: {scanned} receipt(s) on disk, "
                f"{len(window)} kept in memory; chain_index={_chain_index} "
                f"head={str(_chain_head)[:12]}…")
    return _chain_index


def _verdict_of(payload_bytes):
    """Best-effort extraction of the governance verdict (ALLOW/DENY) from a
    receipt payload. Returns 'DENY', 'ALLOW' or '' (unknown). Real, payload-
    driven — no synthetic data."""
    try:
        obj = json.loads(payload_bytes)
    except Exception:
        return ""
    if not isinstance(obj, dict):
        return ""
    for field in ("verdict", "decision", "effect", "result"):
        v = obj.get(field)
        if isinstance(v, str):
            u = v.strip().upper()
            if u in ("DENY", "DENIED", "REJECT", "REJECTED", "BLOCK", "BLOCKED"):
                return "DENY"
            if u in ("ALLOW", "ALLOWED", "PERMIT", "PERMITTED", "PASS"):
                return "ALLOW"
    return ""


def _verify_chain_on_disk():
    """Re-read every persisted receipt from disk and verify the chain end to
    end: each receipt's Ed25519 signature (DSSE PAE), its stored hash, and the
    prev_hash linkage. This is the at-rest tamper detector — editing a stored
    receipt file (e.g. via kubectl exec) makes its signature/hash/link fail and
    flips the chain-valid gauge to 0.

    Returns (chain_ok, length, valid_count, newly_tampered_ids). Verification is
    over the canonical DSSE PAE against the server's published Ed25519 public
    key — the same check an offline auditor runs. No HMAC, no synthetic pass.

    Memory-bounded: rather than re-reading the entire (unbounded) store on every
    scrape — which OOM-kills the process once the chain reaches tens of thousands
    of receipts — this verifies the most-recent in-memory window (the live
    _receipts list, ordered, capped at MAX_IN_MEMORY) and reports the total chain
    length from the in-memory _persisted_count (seeded from the head pointer at
    boot, incremented per append) so a scrape NEVER walks the (unbounded, now
    sharded) store directory tree. Each window receipt's signature, hash and
    intra-window prev_hash linkage are checked; expected_prev is seeded from the
    first window receipt's own stored prev_hash. The older, on-disk history (and
    cold-archived shards) remains independently verifiable offline via the
    published public key — run `python server.py verify-store` for the full,
    shard-by-shard, bounded-memory at-rest audit."""
    with _receipt_lock:
        window = list(_receipts)
    total = _persisted_count

    chain_ok = True
    valid_count = 0
    newly = []
    expected_prev = None
    for rec in window:
        chain = rec.get("chain", {}) or {}
        rid = rec.get("id", "")
        if expected_prev is None:
            # Seed linkage from the first window receipt's own prev_hash so we
            # verify the window's internal consistency without the full history.
            expected_prev = chain.get("prev_hash", GENESIS)
        try:
            hash_ok = (_receipt_hash(rec) == chain.get("hash"))
        except Exception:
            hash_ok = False
        sig_ok = verify_dsse(rec.get("envelope", {}) or {})
        link_ok = (chain.get("prev_hash") == expected_prev)
        ok = bool(hash_ok and sig_ok and link_ok)
        if ok:
            valid_count += 1
        else:
            chain_ok = False
            if rid and rid not in _tampered_ids:
                newly.append(rid)
        # Advance the expected linkage using the STORED hash so a single tamper
        # both fails locally and cascades to every later prev_hash link.
        expected_prev = chain.get("hash") or expected_prev
    return chain_ok, total, valid_count, newly


def _broadcast_sse(data: str):
    dead = []
    with _client_lock:
        for wfile in list(_sse_clients):
            try:
                wfile.write(f"data: {data}\n\n".encode())
                wfile.flush()
            except Exception:
                dead.append(wfile)
        for d in dead:
            _sse_clients.remove(d)


# ── HTTP handler ───────────────────────────────────────────────────────────────

class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        log("debug", fmt % args)

    def _send(self, code, content_type, body):
        if isinstance(body, str):
            body = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", len(body))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(body)

    def do_OPTIONS(self):
        self.send_response(200)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.end_headers()

    def do_GET(self):
        global _counter_tamper, _chain_valid_flag, _chain_len
        path = urlparse(self.path).path
        if path in ("/health", "/healthz"):
            self._send(200, "application/json", json.dumps({"status": "ok"}))
        elif path == "/receipts":
            with _receipt_lock:
                body = json.dumps(_receipts)
            self._send(200, "application/json", body)
        elif path == "/pubkey":
            # Publish the active signing public key so verifiers can fetch it
            # for independent offline Ed25519 verification of any receipt.
            # ensure_available() lets a /pubkey poll itself drive recovery, so
            # signed flips back to true once Vault is unsealed (no restart).
            if _signer is not None and _signer.ensure_available():
                body = json.dumps({
                    "keyid": _signer.key_id,
                    "backend": _signer.backend,
                    "alg": "ed25519",
                    "signed": True,
                    "public_key_b64u": _signer.public_key_b64u,
                    "public_key_b64std": base64.b64encode(_signer.public_key_raw).decode(),
                })
            else:
                body = json.dumps({
                    "keyid": None,
                    "backend": getattr(_signer, "backend", "none"),
                    "alg": "ed25519",
                    "signed": False,
                    "public_key_b64u": None,
                })
            self._send(200, "application/json", body)
        elif path == "/metrics":
            # Run an at-rest chain integrity scan so the gauges/counters
            # reflect the real, current chain state on every scrape
            # (Prometheus pulls ~every 30s). Server-driven — no synthetic series.
            with _integrity_lock:
                chain_ok, chain_len, valid_count, newly = _verify_chain_on_disk()
                for rid in newly:
                    _tampered_ids.add(rid)
                    _counter_tamper += 1
                _chain_valid_flag = 1 if chain_ok else 0
                _chain_len = chain_len
            body = (
                f"# HELP szl_receipts_total Total receipts received\n"
                f"# TYPE szl_receipts_total counter\n"
                f"szl_receipts_total {_counter_total}\n"
                f"# HELP szl_receipts_valid_total Receipts that verified at append time\n"
                f"# TYPE szl_receipts_valid_total counter\n"
                f"szl_receipts_valid_total {_counter_valid}\n"
                f"# HELP szl_receipts_allow_total Receipts whose governance verdict is ALLOW\n"
                f"# TYPE szl_receipts_allow_total counter\n"
                f"szl_receipts_allow_total {_counter_allow}\n"
                f"# HELP szl_receipts_deny_total Receipts whose governance verdict is DENY\n"
                f"# TYPE szl_receipts_deny_total counter\n"
                f"szl_receipts_deny_total {_counter_deny}\n"
                f"# HELP szl_receipts_tamper_total Persisted receipts found tampered/invalid at rest\n"
                f"# TYPE szl_receipts_tamper_total counter\n"
                f"szl_receipts_tamper_total {_counter_tamper}\n"
                f"# HELP szl_receipts_throttled_total POST /receipt requests shed by the ingest rate limiter\n"
                f"# TYPE szl_receipts_throttled_total counter\n"
                f"szl_receipts_throttled_total {_counter_throttled}\n"
                f"# HELP szl_chain_index Next chain index (head pointer) of the receipt chain\n"
                f"# TYPE szl_chain_index gauge\n"
                f"szl_chain_index {_chain_index}\n"
                f"# HELP szl_chain_length Receipts currently persisted in the chain\n"
                f"# TYPE szl_chain_length gauge\n"
                f"szl_chain_length {_chain_len}\n"
                f"# HELP szl_chain_valid Whole-chain integrity at last scan (1=intact, 0=tamper)\n"
                f"# TYPE szl_chain_valid gauge\n"
                f"szl_chain_valid {_chain_valid_flag}\n"
            )
            self._send(200, "text/plain; version=0.0.4", body)
        elif path == "/stream":
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-cache")
            self.send_header("Access-Control-Allow-Origin", "*")
            self.end_headers()
            with _receipt_lock:
                for r in _receipts[-20:]:
                    self.wfile.write(f"data: {json.dumps(r)}\n\n".encode())
            self.wfile.flush()
            with _client_lock:
                _sse_clients.append(self.wfile)
            try:
                while True:
                    time.sleep(1)
            except Exception:
                pass
        else:
            self._send(404, "text/plain", "not found")

    def do_POST(self):
        global _counter_total, _counter_valid, _counter_deny, _counter_allow, _counter_throttled
        global _chain_head, _chain_index, _persisted_count
        path = urlparse(self.path).path
        if path != "/receipt":
            self._send(404, "text/plain", "not found")
            return
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length)
        try:
            incoming = json.loads(body)
        except json.JSONDecodeError:
            self._send(400, "text/plain", "invalid JSON")
            return

        # Anti-flood: shed receipts that exceed the sustained ingest rate. Checked
        # BEFORE signing/appending so a runaway loop costs ~nothing and can neither
        # balloon the chain nor OOM the box. A genuine, spaced deploy receipt still
        # passes (token burst); the fail-open pepr POST path just drops the 429'd
        # excess.
        if not _ingest_allowed():
            _counter_throttled += 1
            self._send(429, "application/json",
                       json.dumps({"error": "rate_limited",
                                   "detail": "receipt ingest rate exceeded"}))
            return

        _counter_total += 1

        # The server is the signer: it (re)signs the receipt payload with
        # Ed25519. If the POST body is already a DSSE envelope we re-sign its
        # payload; otherwise we treat the whole body as the payload object.
        if isinstance(incoming, dict) and "payload" in incoming and "signatures" in incoming:
            try:
                payload_bytes = base64.b64decode(incoming["payload"])
            except Exception:
                payload_bytes = json.dumps(incoming, sort_keys=True).encode()
        else:
            payload_bytes = json.dumps(incoming, sort_keys=True).encode()

        # Real, payload-driven verdict accounting (ALLOW/DENY) feeds the
        # szl_receipts_deny_total / _allow_total series. Server-driven.
        _verdict = _verdict_of(payload_bytes)
        if _verdict == "DENY":
            _counter_deny += 1
        elif _verdict == "ALLOW":
            _counter_allow += 1

        envelope = sign_dsse(payload_bytes)
        valid = verify_dsse(envelope)
        if valid:
            _counter_valid += 1

        with _receipt_lock:
            prev_hash = _chain_head
            chain_index = _chain_index
            created_at = time.strftime("%Y-%m-%dT%H:%M:%SZ")
            # receipt_id is the SHA-256 of the signed envelope (stable).
            receipt_id = hashlib.sha256(
                json.dumps(envelope, sort_keys=True, separators=(",", ":")).encode()
            ).hexdigest()
            record = {
                "id":         receipt_id,
                "created_at": created_at,
                "timestamp":  created_at,   # preserved field name for the dashboard
                "valid":      valid,
                "envelope":   envelope,
                "chain": {
                    "prev_hash":   prev_hash,
                    "chain_index": chain_index,
                },
            }
            record["chain"]["hash"] = _receipt_hash(record)
            _receipts.append(record)
            # Keep the in-memory list bounded so /receipts, /stream and the
            # integrity gauge can never balloon the heap as the chain grows.
            if len(_receipts) > MAX_IN_MEMORY:
                del _receipts[:-MAX_IN_MEMORY]
            _chain_head = record["chain"]["hash"]
            _chain_index = chain_index + 1
            try:
                dest = _store_path_for(receipt_id, chain_index)
                # Index-sharded subdir; cheap exist_ok makedirs (the bucket only
                # rolls over once every SHARD_SIZE appends). Keeps the on-disk
                # store from piling 200k+ files into one directory.
                os.makedirs(os.path.dirname(dest), exist_ok=True)
                with open(dest, "w") as f:
                    json.dump(record, f)
                _persisted_count += 1
            except Exception as e:
                log("warn", f"Could not persist receipt: {e}")
            # Persist the head pointer so the next boot resumes in O(1) without
            # scanning the (unbounded) store. Best-effort; never blocks the append.
            # Pass the in-memory count so this never re-scans the 200k+ store on
            # the hot append path (which, at flood rates, would serialize and
            # starve liveness behind a full directory walk per receipt).
            _write_head_pointer(_chain_index, _chain_head, count=_persisted_count)

        with _span("szl_receipts.append", {
            "receipt_id": receipt_id,
            "prev_hash": record["chain"]["prev_hash"],
            "chain_index": record["chain"]["chain_index"],
        }):
            _broadcast_sse(json.dumps(record))

        log("info",
            f"Receipt {receipt_id[:12]}… valid={valid} "
            f"chain_index={chain_index} prev={prev_hash[:12]}…")
        resp = {
            "id": receipt_id,
            "valid": valid,
            "chain": record["chain"],
        }
        self._send(200, "application/json", json.dumps(resp))


def _signer_recheck_loop():
    """Background watchdog that re-establishes the signer with NO pod restart.

    When the signer is unavailable — e.g. the server booted while Vault was
    sealed/unreachable (the box-reboot case) — poll the backend on a fixed
    cadence and re-init as soon as it is healthy again, so GET /pubkey flips to
    signed:true and signing resumes on its own even with zero request traffic.
    While the signer is available this is a single cheap check per tick. This is
    what makes the auto-unseal helper's receipts pod-delete nudge unnecessary."""
    while True:
        time.sleep(SIGNER_RECHECK_INTERVAL)
        try:
            s = _signer
            if s is not None and not s.available:
                if s.ensure_available(force=True):
                    log("info",
                        f"[signer] re-established without restart; "
                        f"backend={s.backend} keyid={s.key_id} signed=True")
        except Exception as e:
            log("debug", f"signer recheck loop error: {e}")


def boot():
    """Startup hook: build the signer, init tracer, rehydrate chain, emit span."""
    global _signer, _public_key_b64
    _signer = build_signer()
    _public_key_b64 = _signer.public_key_b64u if _signer else None
    _init_tracer()
    # Background watchdog: recover the signer on its own if the backend was down
    # at boot and later comes back (no restart / no pod delete required).
    threading.Thread(
        target=_signer_recheck_loop, name="signer-recheck", daemon=True
    ).start()
    count = _rehydrate()
    with _span("szl_receipts.boot", {
        "store_path": STORE_PATH,
        "rehydrated": count,
        "backend": _signer.backend if _signer else "none",
        "signed": bool(_signer and _signer.available),
        "keyid": _signer.key_id if _signer else KEY_ID,
    }):
        log("info", f"SZL Receipts boot complete; rehydrated={count} "
                    f"backend={_signer.backend if _signer else 'none'} "
                    f"signed={bool(_signer and _signer.available)}")


# ── Offline full-store audit + cold-storage archival (CLI) ──────────────────────

def _group_paths():
    """Return [(label, [paths])] for the whole store, in chain order: the legacy
    flat root first (as one group), then each shard bucket. The group LIST is
    bounded (one entry per bucket); paths within a group are not loaded here."""
    groups = []
    legacy = []
    try:
        with os.scandir(STORE_PATH) as it:
            for e in it:
                if e.is_file() and e.name.endswith(".json"):
                    legacy.append(e.path)
    except FileNotFoundError:
        pass
    if legacy:
        groups.append(("(legacy-root)", legacy))
    for name, bdir in _iter_shard_buckets():
        paths = []
        try:
            with os.scandir(bdir) as it:
                for e in it:
                    if e.is_file() and e.name.endswith(".json"):
                        paths.append(e.path)
        except FileNotFoundError:
            continue
        if paths:
            groups.append((name, paths))
    return groups


def verify_store_offline():
    """Full at-rest integrity audit of the ENTIRE on-disk store (legacy flat root
    + every shard bucket) in BOUNDED memory: receipts are verified one GROUP at a
    time (a shard bucket holds at most SHARD_SIZE receipts; the legacy root is a
    finite, frozen pre-sharding chunk), carrying only the running prev_hash link
    across group boundaries. Verifies each receipt's Ed25519 DSSE signature, its
    stored hash, and the prev_hash chain linkage in chain_index order — the same
    checks an offline auditor runs against the published public key.

    This is the unbounded-safe replacement for ever re-reading the whole store on
    the /metrics hot path: memory never scales with TOTAL chain length, only with
    a single group. Returns a report dict; chain_ok=False on any tamper."""
    groups = _group_paths()
    total = valid = bad_sig = bad_hash = bad_link = 0
    tampered = []
    expected_prev = None
    chain_ok = True
    for label, paths in groups:
        recs = []
        for p in paths:
            try:
                with open(p) as f:
                    recs.append(json.load(f))
            except Exception as e:
                log("warn", f"unreadable receipt {os.path.basename(p)}: {e}")
                chain_ok = False
        recs.sort(key=lambda r: r.get("chain", {}).get("chain_index", 0))
        for rec in recs:
            total += 1
            chain = rec.get("chain", {}) or {}
            rid = rec.get("id", "")
            if expected_prev is None:
                expected_prev = chain.get("prev_hash", GENESIS)
            try:
                hash_ok = (_receipt_hash(rec) == chain.get("hash"))
            except Exception:
                hash_ok = False
            sig_ok = verify_dsse(rec.get("envelope", {}) or {})
            link_ok = (chain.get("prev_hash") == expected_prev)
            if hash_ok and sig_ok and link_ok:
                valid += 1
            else:
                chain_ok = False
                bad_sig += 0 if sig_ok else 1
                bad_hash += 0 if hash_ok else 1
                bad_link += 0 if link_ok else 1
                if rid:
                    tampered.append(rid)
            expected_prev = chain.get("hash") or expected_prev
        recs = None  # release the group before the next bucket
    return {
        "store_path": STORE_PATH,
        "shard_size": SHARD_SIZE,
        "groups": len(groups),
        "total": total,
        "valid": valid,
        "chain_ok": chain_ok,
        "bad_sig": bad_sig,
        "bad_hash": bad_hash,
        "bad_link": bad_link,
        "tampered_sample": tampered[:20],
    }


def _verify_bucket(paths):
    """Bounded verify of a single shard bucket's receipts (used before sealing).
    Returns (ok, count, first_prev_hash, last_hash)."""
    recs = []
    for p in paths:
        with open(p) as f:
            recs.append(json.load(f))
    recs.sort(key=lambda r: r.get("chain", {}).get("chain_index", 0))
    ok = True
    expected_prev = recs[0].get("chain", {}).get("prev_hash", GENESIS) if recs else GENESIS
    first_prev = expected_prev
    last_hash = None
    for rec in recs:
        chain = rec.get("chain", {}) or {}
        hash_ok = (_receipt_hash(rec) == chain.get("hash"))
        sig_ok = verify_dsse(rec.get("envelope", {}) or {})
        link_ok = (chain.get("prev_hash") == expected_prev)
        ok = ok and hash_ok and sig_ok and link_ok
        expected_prev = chain.get("hash") or expected_prev
        last_hash = chain.get("hash") or last_hash
    return ok, len(recs), first_prev, last_hash


def archive_sealed_shards(cold_dir, delete=False):
    """Roll completed ("sealed") shard buckets off the live store into cold
    storage. A bucket is SEALED when it is strictly below the TAIL bucket
    (the bucket the current chain head writes into) — no further receipts will
    ever land in it. Each sealed bucket is VERIFIED, then tar.gz'd into
    <cold_dir>/<bucket>.tar.gz with a sidecar <bucket>.manifest.json recording
    count, first prev_hash, last hash and the tarball sha256, and appended to
    <cold_dir>/archived.json. Only with delete=True is the live bucket removed.

    Chain verifiability is preserved: the manifest's first prev_hash + last hash
    let an auditor stitch a cold-archived bucket back into the live chain, and the
    head-pointer count remains the authoritative chain length (archived receipts
    still count). Returns a summary dict. A bucket that fails verification is
    SKIPPED (never archived/deleted) and flagged in the result."""
    if SHARD_SIZE <= 0:
        return {"error": "sharding disabled (SHARD_SIZE=0); nothing to archive"}
    ptr = _read_head_pointer()
    if ptr is None:
        return {"error": "no head pointer; refusing to archive without a known tail"}
    head_index = int(ptr["chain_index"])  # next index to assign
    last_written = max(head_index - 1, 0)
    tail_bucket = f"{last_written // SHARD_SIZE:08d}"
    os.makedirs(cold_dir, exist_ok=True)

    ledger_path = os.path.join(cold_dir, "archived.json")
    try:
        with open(ledger_path) as f:
            ledger = json.load(f)
    except Exception:
        ledger = {"archived": []}
    already = {e["bucket"] for e in ledger.get("archived", [])}

    archived, skipped = [], []
    for name, bdir in _iter_shard_buckets():
        if name >= tail_bucket:
            continue  # the tail bucket (and beyond) is still being written
        if name in already:
            continue
        paths = [e.path for e in os.scandir(bdir)
                 if e.is_file() and e.name.endswith(".json")]
        if not paths:
            continue
        ok, count, first_prev, last_hash = _verify_bucket(paths)
        if not ok:
            skipped.append(name)
            log("error", f"[archive] bucket {name} failed verification; skipping")
            continue
        tar_path = os.path.join(cold_dir, f"{name}.tar.gz")
        with tarfile.open(tar_path, "w:gz") as tar:
            tar.add(bdir, arcname=name)
        sha = hashlib.sha256()
        with open(tar_path, "rb") as f:
            for chunk in iter(lambda: f.read(1 << 20), b""):
                sha.update(chunk)
        manifest = {
            "bucket": name,
            "count": count,
            "first_prev_hash": first_prev,
            "last_hash": last_hash,
            "tarball": os.path.basename(tar_path),
            "tarball_sha256": sha.hexdigest(),
            "archived_at": time.strftime("%Y-%m-%dT%H:%M:%SZ"),
            "deleted_from_live": bool(delete),
        }
        with open(os.path.join(cold_dir, f"{name}.manifest.json"), "w") as f:
            json.dump(manifest, f, indent=2)
        ledger["archived"].append(manifest)
        if delete:
            for p in paths:
                os.remove(p)
            try:
                os.rmdir(bdir)
            except OSError:
                pass
        archived.append(name)
        log("info", f"[archive] sealed bucket {name} → {tar_path} "
                    f"({count} receipts, delete={delete})")

    with open(ledger_path, "w") as f:
        json.dump(ledger, f, indent=2)
    return {
        "cold_dir": cold_dir,
        "tail_bucket": tail_bucket,
        "archived": archived,
        "skipped_failed_verify": skipped,
        "delete": bool(delete),
    }


def _safe_extract_bucket(tar_path, bucket, dest_dir):
    """Extract a cold bucket tarball into dest_dir, refusing any member that
    would escape dest_dir or land outside the expected `<bucket>/` prefix
    (path-traversal / absolute-path hardening — these tarballs are operator
    input from cold storage). Returns the list of extracted receipt file paths
    under dest_dir/<bucket>/."""
    extracted = []
    with tarfile.open(tar_path, "r:gz") as tar:
        members = tar.getmembers()
        for m in members:
            name = m.name
            # Reject absolute paths, parent traversal, and anything not under the
            # bucket dir the manifest says this tarball holds.
            norm = os.path.normpath(name)
            if (os.path.isabs(name) or norm.startswith("..")
                    or (norm != bucket and not norm.startswith(bucket + os.sep))):
                raise ValueError(
                    f"cold tarball {os.path.basename(tar_path)} contains an "
                    f"unexpected member {name!r} (not under {bucket}/)")
            if not (m.isfile() or m.isdir()):
                raise ValueError(
                    f"cold tarball {os.path.basename(tar_path)} contains a "
                    f"non-regular member {name!r} (only files/dirs allowed)")
        tar.extractall(dest_dir, members=members)
    bdir = os.path.join(dest_dir, bucket)
    if os.path.isdir(bdir):
        for e in os.scandir(bdir):
            if e.is_file() and e.name.endswith(".json"):
                extracted.append(e.path)
    return extracted


def restore_archived_shards(cold_dir, bucket=None, dry_run=False):
    """Inverse of archive_sealed_shards: stitch one (or every) cold-archived
    shard bucket back into the LIVE store under <store>/shards/<bucket>/.

    For each candidate bucket this VERIFIES before it ever touches the live
    store, and refuses (skips) on any mismatch — a cold bucket is never trusted
    blindly:
      1. the cold tarball's sha256 matches the tarball_sha256 its manifest
         recorded (no silent corruption of the archive at rest);
      2. the bucket extracts cleanly (no path-traversal / unexpected members);
      3. every receipt re-verifies its Ed25519/DSSE signature + stored hash +
         intra-bucket prev_hash link (the same _verify_bucket gate archival
         used), the receipt count matches the manifest, and the bucket's real
         first_prev_hash / last_hash match the manifest's recorded boundary
         hashes — so chain linkage is proven, not assumed.

    Only after a bucket passes ALL of the above is it moved into the live store.
    A bucket that already exists live is REFUSED (never clobbered). On success
    the cold ledger entry is removed and the cold tarball + manifest are deleted,
    so the bucket is no longer treated as archived and a later archive-shards run
    can re-seal it. Returns a summary dict; `error`/`failed` signal a non-zero
    operator exit.

    `bucket` (optional) restores only that one bucket; otherwise every bucket in
    the cold ledger is restored.

    `dry_run` (optional) PREVIEW mode (already applied: dry_run): it runs every
    verification step above — already-live detection, cold tarball presence,
    tarball_sha256, clean extraction, and the full chain/count/boundary
    check — and reports a per-bucket verdict (`would-restore` /
    `already-live-skip` / `verify-FAIL`) WITHOUT writing a single byte to
    the live store or mutating the cold ledger/artifacts, so an operator
    can rehearse a recovery first. It still signals a non-zero exit if any
    tarball fails verification, mirroring the live refuse-on-mismatch."""
    ledger_path = os.path.join(cold_dir, "archived.json")
    try:
        with open(ledger_path) as f:
            ledger = json.load(f)
    except FileNotFoundError:
        return {"error": f"no cold ledger at {ledger_path}; nothing to restore"}
    except Exception as e:
        return {"error": f"cold ledger {ledger_path} unreadable: {e}"}

    entries = ledger.get("archived", []) or []
    by_bucket = {e.get("bucket"): e for e in entries}
    if bucket is not None:
        if bucket not in by_bucket:
            return {"error": f"bucket {bucket!r} is not in the cold ledger "
                             f"{ledger_path}"}
        targets = [bucket]
    else:
        targets = sorted(by_bucket)

    restored, failed = [], []
    verdicts = {}
    for name in targets:
        entry = by_bucket[name]
        # Prefer the per-bucket manifest sidecar; fall back to the ledger entry
        # (they carry the same fields). The manifest is the at-rest source of
        # truth written alongside the tarball.
        manifest_path = os.path.join(cold_dir, f"{name}.manifest.json")
        try:
            with open(manifest_path) as f:
                mf = json.load(f)
        except Exception:
            mf = entry
        tar_name = mf.get("tarball") or f"{name}.tar.gz"
        tar_path = os.path.join(cold_dir, tar_name)

        live_dir = os.path.join(SHARDS_DIR, name)
        if os.path.isdir(live_dir) and any(
                e.name.endswith(".json") for e in os.scandir(live_dir)):
            if dry_run:
                verdicts[name] = "already-live-skip"
                log("info", f"[restore:dry-run] bucket {name} already exists "
                            f"live at {live_dir}; would skip (no clobber)")
                continue
            failed.append(name)
            log("error", f"[restore] bucket {name} already exists live at "
                         f"{live_dir}; refusing to clobber")
            continue
        if not os.path.exists(tar_path):
            failed.append(name)
            verdicts[name] = "verify-FAIL"
            log("error", f"[restore] cold tarball missing for bucket {name} "
                         f"({tar_path})")
            continue

        # (1) integrity at rest: tarball bytes must match the manifest sha256
        # BEFORE we unpack anything.
        expected_sha = mf.get("tarball_sha256")
        sha = hashlib.sha256()
        with open(tar_path, "rb") as f:
            for chunk in iter(lambda: f.read(1 << 20), b""):
                sha.update(chunk)
        if not expected_sha or sha.hexdigest() != expected_sha:
            failed.append(name)
            verdicts[name] = "verify-FAIL"
            log("error", f"[restore] bucket {name} tarball sha256 mismatch "
                         f"(got {sha.hexdigest()[:12]}…, manifest "
                         f"{str(expected_sha)[:12]}…); refusing")
            continue

        if dry_run:
            # Extract to a throwaway temp dir OFF the cold dir so a dry-run
            # leaves no trace in the cold store at all.
            staging = tempfile.mkdtemp(prefix=f"szl-restore-dry-{name}-")
        else:
            staging = os.path.join(cold_dir, f".restore-{name}")
            if os.path.isdir(staging):
                shutil.rmtree(staging, ignore_errors=True)
            os.makedirs(staging, exist_ok=True)
        try:
            try:
                paths = _safe_extract_bucket(tar_path, name, staging)
            except Exception as e:
                failed.append(name)
                verdicts[name] = "verify-FAIL"
                log("error", f"[restore] bucket {name} failed to extract: {e}")
                continue
            if not paths:
                failed.append(name)
                verdicts[name] = "verify-FAIL"
                log("error", f"[restore] bucket {name} extracted no receipts")
                continue
            # (2)/(3) chain verification of the extracted receipts.
            ok, count, first_prev, last_hash = _verify_bucket(paths)
            if not ok:
                failed.append(name)
                verdicts[name] = "verify-FAIL"
                log("error", f"[restore] bucket {name} failed chain verification; "
                             f"refusing to restore")
                continue
            exp_count = mf.get("count")
            if exp_count is not None and count != exp_count:
                failed.append(name)
                verdicts[name] = "verify-FAIL"
                log("error", f"[restore] bucket {name} receipt count {count} != "
                             f"manifest count {exp_count}; refusing")
                continue
            if (first_prev != mf.get("first_prev_hash")
                    or last_hash != mf.get("last_hash")):
                failed.append(name)
                verdicts[name] = "verify-FAIL"
                log("error", f"[restore] bucket {name} boundary hashes do not "
                             f"match the manifest (chain linkage); refusing")
                continue

            if dry_run:
                # Every check passed and the bucket is not live → it WOULD be
                # restored. Make ZERO changes: no live-store write, no ledger
                # mutation, no cold-artifact deletion.
                verdicts[name] = "would-restore"
                log("info", f"[restore:dry-run] bucket {name} verified "
                            f"({count} receipts); would restore to {live_dir}")
                continue

            # Verified — move the bucket into the live store atomically-ish.
            os.makedirs(SHARDS_DIR, exist_ok=True)
            extracted_bdir = os.path.join(staging, name)
            if os.path.isdir(live_dir):
                # empty dir left behind (e.g. by a prior aborted run): replace it.
                try:
                    os.rmdir(live_dir)
                except OSError:
                    pass
            try:
                os.replace(extracted_bdir, live_dir)
            except OSError:
                # cross-device or non-empty: fall back to a per-file move.
                os.makedirs(live_dir, exist_ok=True)
                for p in paths:
                    shutil.move(p, os.path.join(live_dir, os.path.basename(p)))
        finally:
            shutil.rmtree(staging, ignore_errors=True)

        # Restored: drop the ledger entry + remove the (now redundant) cold
        # artifacts so the bucket is no longer treated as archived and a later
        # archive-shards run can re-seal it.
        ledger["archived"] = [e for e in ledger.get("archived", [])
                              if e.get("bucket") != name]
        for stale in (tar_path, manifest_path):
            try:
                os.remove(stale)
            except OSError:
                pass
        restored.append(name)
        log("info", f"[restore] bucket {name} → {live_dir} "
                    f"({count} receipts) restored from cold storage")

    if not dry_run:
        with open(ledger_path, "w") as f:
            json.dump(ledger, f, indent=2)
    result = {
        "cold_dir": cold_dir,
        "store_path": STORE_PATH,
        "requested": bucket or "(all)",
        "restored": restored,
        "failed": failed,
    }
    if dry_run:
        # Preview-only summary: no bytes were written. `failed` carries the
        # verify-FAILs (already-live is a benign skip, NOT a failure), so the
        # CLI still exits non-zero iff a tarball failed verification.
        result["dry_run"] = True
        result["verdicts"] = verdicts
        result["would_restore"] = sorted(
            k for k, v in verdicts.items() if v == "would-restore")
        result["already_live_skip"] = sorted(
            k for k, v in verdicts.items() if v == "already-live-skip")
        result["verify_fail"] = sorted(
            k for k, v in verdicts.items() if v == "verify-FAIL")
    return result


# ── off-box / remote cold-source staging (restore from an offsite backup) ────────
# restore_archived_shards reads cold tarballs+manifests from a LOCAL --cold-dir.
# But the box retention job already mirrors the sealed cold archive OFF the box for
# durability (box-scripts/sbin/szl-receipts-cold-offsite → a mounted volume, a 2nd
# host over ssh, or an rclone/s3 object store), because if box 167.233.50.75 is lost
# so is the on-box cold dir. After data loss an operator wants to restore STRAIGHT
# from that off-box copy without hand-staging tarballs into a local dir first.
#
# These helpers stage the needed cold artifacts (archived.json + each target
# bucket's <bucket>.tar.gz + <bucket>.manifest.json) from the remote into a local
# staging dir; restore_archived_shards then runs its UNCHANGED per-tarball gate
# (tarball_sha256 + chain linkage: count / first_prev_hash / last_hash) before
# unpacking, refusing on any mismatch — so an off-box restore is verified exactly
# like a local one. The transports mirror the offsite mirror's transports in the
# DOWNLOAD direction: local (a mounted volume / object mount), ssh (scp), rclone
# (any S3/B2/GCS/... remote) and s3 (aws cli). `local` is fully self-contained.


class ColdRemoteError(Exception):
    """A remote cold-source was mis-specified (not a per-bucket fetch miss)."""


def _run_capture(cmd):
    """Run cmd, returning (rc, stdout_bytes, stderr_bytes). A missing transport
    binary (ssh/scp/rclone/aws) surfaces as rc=127 rather than an exception."""
    try:
        p = subprocess.run(cmd, capture_output=True)
        return p.returncode, p.stdout, p.stderr
    except FileNotFoundError:
        return 127, b"", f"{cmd[0]}: command not found".encode()


def _remote_fetch_object(remote, name, dest_path):
    """Fetch a single object `name` from the configured remote cold-source into
    dest_path. Returns True on success, False if the object could not be fetched
    (missing object, transport error, or missing transport tool) — the reason is
    logged. A False on a REQUIRED tarball/manifest makes restore refuse that
    bucket (recorded under failed), never silently skip it."""
    t = remote["transport"]
    if t == "local":
        src = os.path.join(remote["dir"], name)
        if not os.path.exists(src):
            return False
        try:
            shutil.copyfile(src, dest_path)
            return True
        except OSError as e:
            log("error", f"[restore] local copy of {name} from {src} failed: {e}")
            return False
    if t == "ssh":
        target = remote["ssh_target"].rstrip("/")
        host, _, path = target.partition(":")
        remote_path = f"{path.rstrip('/')}/{name}"
        key = remote.get("ssh_key")
        ssh_base = ["ssh"] + (["-i", key] if key else []) + [
            "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=accept-new"]
        rc, _, err = _run_capture(
            ssh_base + [host, f"test -f {shlex.quote(remote_path)}"])
        if rc == 1:
            return False  # object absent on the remote (clean miss)
        if rc != 0:       # transport/auth/tool error, not a clean miss
            log("error", f"[restore] ssh probe to {host} failed (rc={rc}): "
                         f"{err.decode('utf-8', 'replace').strip()}")
            return False
        scp = ["scp"] + (["-i", key] if key else []) + [
            "-B", "-o", "StrictHostKeyChecking=accept-new",
            f"{host}:{remote_path}", dest_path]
        rc, _, err = _run_capture(scp)
        if rc != 0:
            log("error", f"[restore] scp of {name} from {target} failed (rc={rc}): "
                         f"{err.decode('utf-8', 'replace').strip()}")
            return False
        return os.path.exists(dest_path)
    if t == "rclone":
        remote_obj = f"{remote['rclone_remote'].rstrip('/')}/{name}"
        rc, _, err = _run_capture(["rclone", "copyto", remote_obj, dest_path])
        if rc != 0:
            log("error", f"[restore] rclone copyto {remote_obj} failed (rc={rc}): "
                         f"{err.decode('utf-8', 'replace').strip()}")
            return False
        return os.path.exists(dest_path)
    if t == "s3":
        uri = f"{remote['s3_uri'].rstrip('/')}/{name}"
        endpoint = remote.get("s3_endpoint")
        cmd = ["aws"] + (["--endpoint-url", endpoint] if endpoint else []) + [
            "s3", "cp", uri, dest_path]
        rc, _, err = _run_capture(cmd)
        if rc != 0:
            log("error", f"[restore] aws s3 cp {uri} failed (rc={rc}): "
                         f"{err.decode('utf-8', 'replace').strip()}")
            return False
        return os.path.exists(dest_path)
    raise ColdRemoteError(f"unknown remote transport {t!r}")


def _resolve_remote_source(argv):
    """Parse the off-box cold-source flags out of the restore-shards argv, or fall
    back to the OFFSITE_* environment (mirroring box-scripts/sbin/szl-receipts-cold-
    offsite) when --from-offsite is given. Returns a remote dict (with a
    `transport` key and a `source` label) or None when no off-box source was
    requested (caller then does a plain local --cold-dir restore). Raises
    ColdRemoteError on a contradictory / incomplete spec."""
    flags = {
        "--remote-local": None,
        "--remote-ssh": None,
        "--remote-ssh-key": None,
        "--remote-rclone": None,
        "--remote-s3": None,
        "--remote-s3-endpoint": None,
        "--remote-transport": None,
    }
    from_offsite = False
    for i, a in enumerate(argv):
        if a == "--from-offsite":
            from_offsite = True
        elif a in flags and i + 1 < len(argv):
            flags[a] = argv[i + 1]

    explicit = {k: v for k, v in flags.items()
                if v is not None and k not in (
                    "--remote-ssh-key", "--remote-s3-endpoint",
                    "--remote-transport")}
    if not from_offsite and not explicit:
        return None
    if from_offsite and explicit:
        raise ColdRemoteError(
            "--from-offsite cannot be combined with explicit --remote-* flags; "
            "use one or the other")

    if from_offsite:
        env = os.environ
        transport = (flags["--remote-transport"]
                     or env.get("OFFSITE_TRANSPORT") or "").strip()
        if not transport:
            if env.get("OFFSITE_SSH_TARGET"):
                transport = "ssh"
            elif env.get("OFFSITE_LOCAL_DIR"):
                transport = "local"
            elif env.get("OFFSITE_RCLONE_REMOTE"):
                transport = "rclone"
            elif env.get("OFFSITE_S3_URI"):
                transport = "s3"
        if not transport:
            raise ColdRemoteError(
                "--from-offsite given but no OFFSITE_* destination is set in the "
                "environment (nothing to restore from)")
        if transport == "local":
            d = env.get("OFFSITE_LOCAL_DIR")
            if not d:
                raise ColdRemoteError(
                    "OFFSITE_TRANSPORT=local but OFFSITE_LOCAL_DIR is unset")
            return {"transport": "local", "dir": d, "source": f"local:{d}"}
        if transport == "ssh":
            tgt = env.get("OFFSITE_SSH_TARGET")
            if not tgt:
                raise ColdRemoteError(
                    "OFFSITE_TRANSPORT=ssh but OFFSITE_SSH_TARGET is unset")
            return {"transport": "ssh", "ssh_target": tgt,
                    "ssh_key": env.get("OFFSITE_SSH_KEY") or None,
                    "source": f"ssh:{tgt}"}
        if transport == "rclone":
            r = env.get("OFFSITE_RCLONE_REMOTE")
            if not r:
                raise ColdRemoteError(
                    "OFFSITE_TRANSPORT=rclone but OFFSITE_RCLONE_REMOTE is unset")
            return {"transport": "rclone", "rclone_remote": r,
                    "source": f"rclone:{r}"}
        if transport == "s3":
            u = env.get("OFFSITE_S3_URI")
            if not u:
                raise ColdRemoteError(
                    "OFFSITE_TRANSPORT=s3 but OFFSITE_S3_URI is unset")
            return {"transport": "s3", "s3_uri": u,
                    "s3_endpoint": env.get("OFFSITE_S3_ENDPOINT") or None,
                    "source": f"s3:{u}"}
        raise ColdRemoteError(f"unknown OFFSITE_TRANSPORT {transport!r}")

    # explicit --remote-* flags
    if len(explicit) > 1:
        raise ColdRemoteError(
            f"specify exactly one off-box cold-source, got {sorted(explicit)}")
    forced = flags["--remote-transport"]
    if flags["--remote-local"] is not None:
        if forced and forced != "local":
            raise ColdRemoteError(
                f"--remote-local conflicts with --remote-transport {forced}")
        d = flags["--remote-local"]
        return {"transport": "local", "dir": d, "source": f"local:{d}"}
    if flags["--remote-ssh"] is not None:
        if forced and forced != "ssh":
            raise ColdRemoteError(
                f"--remote-ssh conflicts with --remote-transport {forced}")
        tgt = flags["--remote-ssh"]
        if ":" not in tgt:
            raise ColdRemoteError(
                "--remote-ssh must be USER@HOST:/PATH (missing ':PATH')")
        return {"transport": "ssh", "ssh_target": tgt,
                "ssh_key": flags["--remote-ssh-key"], "source": f"ssh:{tgt}"}
    if flags["--remote-rclone"] is not None:
        if forced and forced != "rclone":
            raise ColdRemoteError(
                f"--remote-rclone conflicts with --remote-transport {forced}")
        r = flags["--remote-rclone"]
        return {"transport": "rclone", "rclone_remote": r,
                "source": f"rclone:{r}"}
    if flags["--remote-s3"] is not None:
        if forced and forced != "s3":
            raise ColdRemoteError(
                f"--remote-s3 conflicts with --remote-transport {forced}")
        u = flags["--remote-s3"]
        return {"transport": "s3", "s3_uri": u,
                "s3_endpoint": flags["--remote-s3-endpoint"],
                "source": f"s3:{u}"}
    raise ColdRemoteError("no recognized off-box cold-source flag given")


def _write_staging_ledger(stage_dir, remote, staged, fetch_failed):
    """Drop a small JSON note in the staging dir recording what was pulled from
    the off-box source and from where (operator-facing audit of the staging step;
    the authoritative ledger remains the staged archived.json)."""
    try:
        with open(os.path.join(stage_dir, ".staging.json"), "w") as f:
            json.dump({
                "source": remote.get("source"),
                "transport": remote.get("transport"),
                "staged": sorted(staged),
                "fetch_failed": sorted(fetch_failed),
                "staged_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            }, f, indent=2)
    except OSError as e:
        log("warn", f"[restore] could not write staging ledger: {e}")


def restore_from_remote(remote, stage_dir, bucket=None, dry_run=False):
    """Stage the cold archive from an OFF-box source into stage_dir, then run the
    UNCHANGED restore_archived_shards over the staged copy — so an off-box restore
    is verified (tarball_sha256 + chain linkage) and refuses on mismatch exactly
    like a local one. A bucket whose tarball/manifest cannot be fetched off-box is
    recorded as a fetch failure (folded into `failed`), never silently skipped.

    Returns the restore report augmented with `source` (the off-box location) and
    `fetch_failed`; `error`/`failed` still signal a non-zero operator exit."""
    os.makedirs(stage_dir, exist_ok=True)
    source = remote.get("source")

    # (1) pull the cold ledger — without it there is nothing to restore.
    ledger_dest = os.path.join(stage_dir, "archived.json")
    if not _remote_fetch_object(remote, "archived.json", ledger_dest):
        return {"error": f"could not fetch cold ledger 'archived.json' from "
                         f"{source} (off-box source empty or unreachable)",
                "source": source, "restored": [], "failed": [],
                "fetch_failed": []}
    try:
        with open(ledger_dest) as f:
            ledger = json.load(f)
    except Exception as e:
        return {"error": f"staged cold ledger from {source} is unreadable: {e}",
                "source": source, "restored": [], "failed": [],
                "fetch_failed": []}

    by_bucket = {e.get("bucket"): e
                 for e in (ledger.get("archived", []) or [])}
    targets = [bucket] if bucket is not None else sorted(by_bucket)

    # (2) stage each target bucket's tarball + manifest sidecar.
    staged, fetch_failed = [], []
    for name in targets:
        tar_ok = _remote_fetch_object(
            remote, f"{name}.tar.gz",
            os.path.join(stage_dir, f"{name}.tar.gz"))
        mf_ok = _remote_fetch_object(
            remote, f"{name}.manifest.json",
            os.path.join(stage_dir, f"{name}.manifest.json"))
        if tar_ok and mf_ok:
            staged.append(name)
        else:
            fetch_failed.append(name)
            log("error", f"[restore] bucket {name} could not be staged from "
                         f"{source} (tarball_ok={tar_ok} manifest_ok={mf_ok}); "
                         f"refusing")
    _write_staging_ledger(stage_dir, remote, staged, fetch_failed)

    # (3) if a single requested bucket could not be staged, fail it directly —
    # restore_archived_shards would otherwise only see a ledger miss.
    if bucket is not None and bucket in fetch_failed:
        return {"source": source, "store_path": STORE_PATH,
                "requested": bucket, "restored": [], "failed": [bucket],
                "fetch_failed": fetch_failed}

    # (4) run the UNCHANGED local restore over the staged copy. It applies the
    # full per-tarball verification (sha256 + chain linkage) and refuses on any
    # mismatch; an un-staged bucket surfaces there as a missing-tarball failure.
    report = restore_archived_shards(stage_dir, bucket=bucket, dry_run=dry_run)
    report["source"] = source
    report["fetch_failed"] = fetch_failed
    # fold fetch misses into failed (deduped) so they are never lost.
    merged = list(report.get("failed", []))
    for name in fetch_failed:
        if name not in merged:
            merged.append(name)
    report["failed"] = merged
    return report


def _cli(argv):
    """Operator CLI: bounded full-store audit + cold-storage shard rollup.
    These reuse the same Ed25519/DSSE verification as the server, so they need a
    signer (public key) — build it before verifying."""
    global _signer, _public_key_b64
    cmd = argv[0]
    _signer = build_signer()
    _public_key_b64 = _signer.public_key_b64u if _signer else None
    if cmd == "verify-store":
        report = verify_store_offline()
        print(json.dumps(report, indent=2))
        return 0 if report["chain_ok"] else 1
    if cmd == "archive-shards":
        cold_dir = os.environ.get(
            "SZL_RECEIPT_COLD_DIR", os.path.join(STORE_PATH, "cold"))
        delete = "--delete" in argv[1:]
        for i, a in enumerate(argv[1:]):
            if a == "--cold-dir" and i + 1 < len(argv[1:]):
                cold_dir = argv[1:][i + 1]
        report = archive_sealed_shards(cold_dir, delete=delete)
        print(json.dumps(report, indent=2))
        return 1 if report.get("error") or report.get("skipped_failed_verify") else 0
    if cmd == "restore-shards":
        cold_dir = os.environ.get(
            "SZL_RECEIPT_COLD_DIR", os.path.join(STORE_PATH, "cold"))
        bucket = None
        dry_run = "--dry-run" in argv[1:]
        stage_dir = None
        rest = argv[1:]
        for i, a in enumerate(rest):
            if a == "--cold-dir" and i + 1 < len(rest):
                cold_dir = rest[i + 1]
            elif a == "--bucket" and i + 1 < len(rest):
                bucket = rest[i + 1]
            elif a == "--stage-dir" and i + 1 < len(rest):
                stage_dir = rest[i + 1]
        try:
            remote = _resolve_remote_source(rest)
        except ColdRemoteError as e:
            print(json.dumps({"error": str(e)}, indent=2))
            return 1
        if remote is None:
            # local cold-dir restore (unchanged path). --dry-run preview supported.
            report = restore_archived_shards(cold_dir, bucket=bucket,
                                             dry_run=dry_run)
        else:
            # off-box restore: stage from the remote, then verify+restore. A
            # temp staging dir is used (and cleaned up) unless --stage-dir is set.
            # --dry-run is threaded through to the staged restore.
            tmp = None
            if stage_dir is None:
                tmp = tempfile.mkdtemp(prefix="szl-cold-restore-")
                stage_dir = tmp
            try:
                report = restore_from_remote(remote, stage_dir, bucket=bucket,
                                             dry_run=dry_run)
            finally:
                if tmp is not None:
                    shutil.rmtree(tmp, ignore_errors=True)
        print(json.dumps(report, indent=2))
        return 1 if report.get("error") or report.get("failed") else 0
    print("usage: server.py [verify-store | "
          "archive-shards [--cold-dir DIR] [--delete] | "
          "restore-shards [--cold-dir DIR] [--bucket NAME] [--dry-run] "
          "[--from-offsite | --remote-local DIR | --remote-ssh USER@HOST:/PATH "
          "[--remote-ssh-key FILE] | --remote-rclone REMOTE:PATH | "
          "--remote-s3 s3://BUCKET/PATH [--remote-s3-endpoint URL]] "
          "[--remote-transport local|ssh|rclone|s3] [--stage-dir DIR]]",
          file=sys.stderr)
    return 2


if __name__ == "__main__":
    if len(sys.argv) > 1:
        sys.exit(_cli(sys.argv[1:]))
    boot()
    # Threaded server: a single-threaded HTTPServer serializes ALL requests, so a
    # sustained receipt-POST flood (each POST = Vault sign + file write) starves
    # the /healthz liveness probe past its timeout → the kubelet SIGKILLs the pod
    # in a restart loop even though signing is healthy. ThreadingHTTPServer gives
    # probes (and /pubkey) their own threads; chain integrity stays correct
    # because every chain mutation is serialized under _receipt_lock.
    server = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    server.daemon_threads = True
    log("info", f"SZL Receipts server listening on :{PORT} (threaded)")
    server.serve_forever()
