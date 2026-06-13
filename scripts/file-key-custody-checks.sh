# Copyright 2026 SZL Holdings
# SPDX-License-Identifier: Apache-2.0
#
# file-key-custody-checks.sh — the pure pass/fail logic of the File (SealedSecret)
# Key-Custody Gate (.github/workflows/file-key-custody-gate.yml), extracted out of
# the workflow so it can be UNIT TESTED with synthetic fixtures and no cluster.
#
# WHY THIS EXISTS
# The gate proves szl-receipts Tier-1 (file backend, fed by a Bitnami SealedSecret)
# signing-key custody, live, on a throwaway k3d cluster at release time. Its
# security value is entirely in a handful of bash assertions — an encrypted-at-rest
# SealedSecret CR is deployed, the in-cluster controller materialised the decrypted
# Ed25519 Secret, the server loaded that file key and signs (NOT the silent unsigned
# fallback), and /pubkey reports signed=true backend=file. If someone weakened one
# of those assertions (tolerated a missing SealedSecret, accepted the unsigned
# fallback, flipped backend!=file to ==, etc.) nothing would catch it: the gate only
# runs on release and a neutered check passes vacuously.
#
# So the gate CALLS these subcommands for every pass/fail decision (the live data
# capture — kubectl / curl — stays in the workflow), giving the logic ONE source of
# truth. scripts/file-key-custody-checks.test.sh feeds each subcommand a
# deliberately-BROKEN fixture and asserts it FAILS (plus that a GOOD fixture PASSES),
# so a future edit that neuters a check is caught in CI on every PR — not silently
# at the next release.
#
# It is pure string/JSON logic — no cluster needed. `jq` must be on PATH (it is on
# the GitHub ubuntu runners the gate already relies on).
#
# Usage:
#   file-key-custody-checks.sh <check>
#     check : sealed-secret | key-secret | signer-log | pubkey | receipt
#   The fixture is read from STDIN.
#
# Each check exits 0 when the invariant holds and non-zero (printing the SAME
# GitHub ::error annotation the gate relies on) when it is violated.

set -uo pipefail

# sealed-secret — STDIN is the output of `kubectl get sealedsecret
# szl-receipts-ed25519 -o name` (empty when the CR is absent). Assert the
# encrypted-at-rest SealedSecret CR IS deployed: Tier-1 custody commits only the
# ciphertext to git, so the chart must render the SealedSecret (templates/
# sealedsecret.yaml), not a plaintext Secret manifest.
sealed_secret() {
  local present
  present="$(cat)"
  if [ -z "$(printf '%s' "$present" | tr -d '[:space:]')" ]; then
    echo "::error::No SealedSecret szl-receipts-ed25519 in the cluster — Tier-1 custody must ship the encrypted-at-rest CR, not a plaintext key"
    return 1
  fi
  echo "OK: SealedSecret szl-receipts-ed25519 present (encrypted key committed-safe)"
}

# key-secret — STDIN is the output of `kubectl get secret szl-receipts-ed25519
# -o name` (empty when absent). Assert the decrypted Ed25519 Secret EXISTS: this
# is the OPPOSITE of the Vault gate's no-key-secret check — for Tier-1 the key
# legitimately lives in a cluster Secret, materialised by the sealed-secrets
# controller from the committed ciphertext. Its presence proves the SealedSecret
# round-trip (ciphertext -> controller decrypt -> Secret) actually completed.
key_secret() {
  local present
  present="$(cat)"
  if [ -z "$(printf '%s' "$present" | tr -d '[:space:]')" ]; then
    echo "::error::Decrypted Secret szl-receipts-ed25519 absent — the sealed-secrets controller did not materialise the signing key"
    return 1
  fi
  echo "OK: signing-key Secret szl-receipts-ed25519 materialised from the SealedSecret"
}

# signer-log — STDIN is the receipts-server log. Assert (a) the server loaded the
# mounted Ed25519 file key (the exact success line emitted by FileSigner._load():
# "[file] Ed25519 signing key loaded; keyid=..."); and (b) the MOST RECENT
# signer-state line is the loaded key, not the silent "running unsigned" fallback.
# The server re-reads the PEM after boot (a SealedSecret controller may materialise
# the Secret late), so a transient unsigned line at boot followed by a successful
# load is fine — only the latest state is judged.
signer_log() {
  local logs signer_state
  logs="$(cat)"
  if ! printf '%s' "$logs" | grep -qiE '\[file\] Ed25519 signing key loaded'; then
    echo "::error::No '[file] Ed25519 signing key loaded' line in server logs"
    echo "::error::Server did not load the mounted Ed25519 file key (SealedSecret-materialised Secret)"
    return 1
  fi
  signer_state="$(printf '%s' "$logs" \
    | grep -iE '\[file\] Ed25519 signing key loaded|running unsigned' | tail -n1 || true)"
  if [ -z "$signer_state" ]; then
    echo "::error::No file signer-state line found in server logs at all"
    return 1
  fi
  if printf '%s' "$signer_state" | grep -qi 'running unsigned'; then
    echo "::error::Server's most recent signer state is UNSIGNED — file signing did not engage / did not recover"
    echo "last signer-state line: $signer_state"
    return 1
  fi
  echo "OK: server signing via the mounted Ed25519 file key, latest state loaded"
}

# pubkey — STDIN is the GET /pubkey JSON. Assert signed==true AND backend==file.
# The server self-heals to an unsigned state if the key is missing, so this catches
# a silent unsigned downgrade; backend==file confirms it is genuinely the Tier-1
# file backend (not, say, an accidentally-vault deploy).
pubkey() {
  local body signed backend
  body="$(cat)"
  signed="$(printf '%s' "$body" | jq -r '.signed')"
  backend="$(printf '%s' "$body" | jq -r '.backend')"
  if [ "$signed" != "true" ]; then
    echo "::error::/pubkey reports signed=$signed (expected true — silent unsigned downgrade)"
    return 1
  fi
  if [ "$backend" != "file" ]; then
    echo "::error::/pubkey reports backend=$backend (expected file)"
    return 1
  fi
  echo "OK: /pubkey reports signed=true backend=file"
}

# receipt — STDIN is the POST /receipt JSON. Assert the signed receipt verifies
# (valid==true) at issuance.
receipt() {
  local body valid
  body="$(cat)"
  valid="$(printf '%s' "$body" | jq -r '.valid')"
  if [ "$valid" != "true" ]; then
    echo "::error::POST /receipt returned valid=$valid (expected true)"
    return 1
  fi
  echo "OK: POST /receipt returned valid=true"
}

# ── Dispatch ──────────────────────────────────────────────────────────────────
# When sourced (BASH_SOURCE != $0) define the functions and return so the
# self-test can call them directly. When executed, run the requested check
# against STDIN.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  CHECK="${1:-}"
  case "$CHECK" in
    sealed-secret) sealed_secret ;;
    key-secret)    key_secret ;;
    signer-log)    signer_log ;;
    pubkey)        pubkey ;;
    receipt)       receipt ;;
    *) echo "::error::unknown check: '$CHECK' (want sealed-secret|key-secret|signer-log|pubkey|receipt)" >&2; exit 2 ;;
  esac
fi
