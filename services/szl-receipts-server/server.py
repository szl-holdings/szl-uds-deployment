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
import json
import time
import base64
import hashlib
import threading
import urllib.request
import urllib.error
from http.server import HTTPServer, BaseHTTPRequestHandler
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
_chain_head    = GENESIS   # hash of the most recent receipt, or GENESIS
_chain_index   = 0         # next chain index to assign
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

    @property
    def available(self) -> bool:
        return self.public_key_raw is not None

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
    if _signer is not None and _signer.available:
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


def _rehydrate():
    """Walk STORE_PATH, load every *.json receipt, order by created_at, and
    rebuild the in-memory list and chain head/index. Logs the count.

    Chain pointers are reconstructed by reading each receipt's chain.prev_hash;
    the chain head is set to the hash of the last (most recent) receipt."""
    global _receipts, _chain_head, _chain_index
    loaded = []
    try:
        names = [n for n in os.listdir(STORE_PATH) if n.endswith(".json")]
    except FileNotFoundError:
        names = []
    for name in names:
        path = os.path.join(STORE_PATH, name)
        try:
            with open(path, "r") as f:
                rec = json.load(f)
            loaded.append(rec)
        except Exception as e:
            log("warn", f"skipping unreadable receipt {name}: {e}")

    # Order by created_at (ISO-8601 sorts lexicographically), then chain_index
    # as a tie-breaker for receipts created within the same second.
    def _key(r):
        return (
            r.get("created_at", ""),
            r.get("chain", {}).get("chain_index", 0),
        )
    loaded.sort(key=_key)

    with _receipt_lock:
        _receipts = loaded
        if loaded:
            last = loaded[-1]
            _chain_head = last.get("chain", {}).get("hash") or _receipt_hash(last)
            _chain_index = last.get("chain", {}).get("chain_index", len(loaded) - 1) + 1
        else:
            _chain_head = GENESIS
            _chain_index = 0
    log("info", f"Rehydrated {len(loaded)} receipt(s) from {STORE_PATH}; "
                 f"chain_index={_chain_index} head={_chain_head[:12]}…")
    return len(loaded)


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
    key — the same check an offline auditor runs. No HMAC, no synthetic pass."""
    loaded = []
    try:
        names = [n for n in os.listdir(STORE_PATH) if n.endswith(".json")]
    except FileNotFoundError:
        names = []
    for name in names:
        try:
            with open(os.path.join(STORE_PATH, name), "r") as f:
                loaded.append(json.load(f))
        except Exception:
            continue

    def _key(r):
        return (r.get("chain", {}).get("chain_index", 0), r.get("created_at", ""))
    loaded.sort(key=_key)

    chain_ok = True
    valid_count = 0
    newly = []
    expected_prev = GENESIS
    for rec in loaded:
        chain = rec.get("chain", {}) or {}
        rid = rec.get("id", "")
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
    return chain_ok, len(loaded), valid_count, newly


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
            if _signer is not None and _signer.available:
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
        global _counter_total, _counter_valid, _counter_deny, _counter_allow
        global _chain_head, _chain_index
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
            _chain_head = record["chain"]["hash"]
            _chain_index = chain_index + 1
            try:
                with open(f"{STORE_PATH}/{receipt_id}.json", "w") as f:
                    json.dump(record, f)
            except Exception as e:
                log("warn", f"Could not persist receipt: {e}")

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


def boot():
    """Startup hook: build the signer, init tracer, rehydrate chain, emit span."""
    global _signer, _public_key_b64
    _signer = build_signer()
    _public_key_b64 = _signer.public_key_b64u if _signer else None
    _init_tracer()
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


if __name__ == "__main__":
    boot()
    server = HTTPServer(("0.0.0.0", PORT), Handler)
    log("info", f"SZL Receipts server listening on :{PORT}")
    server.serve_forever()
