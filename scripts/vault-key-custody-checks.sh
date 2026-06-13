# Copyright 2026 SZL Holdings
# SPDX-License-Identifier: Apache-2.0
#
# vault-key-custody-checks.sh — the pure pass/fail logic of the Vault Key-Custody
# Gate (.github/workflows/vault-key-custody-gate.yml), extracted out of the
# workflow so it can be UNIT TESTED with synthetic fixtures and no cluster.
#
# WHY THIS EXISTS
# The gate proves szl-receipts Tier-2 (HashiCorp Vault Transit) signing-key
# custody, live, on a throwaway k3d cluster at release time. Its security value
# is entirely in a handful of bash assertions — the Transit key is
# non-exportable, the server signs via Kubernetes (ServiceAccount) auth and not a
# static token, it is NOT in the silent unsigned fallback, /pubkey reports
# backend=vault, and there is no Ed25519 signing-key Secret in the cluster. If
# someone weakened one of those assertions (dropped the auth=kubernetes
# requirement, flipped exportable!=false to ==, etc.) nothing would catch it: the
# gate only runs on release and a neutered check passes vacuously.
#
# So the gate now CALLS these subcommands for every pass/fail decision (the live
# data capture — vault read / kubectl / curl — stays in the workflow), giving the
# logic ONE source of truth. scripts/vault-key-custody-checks.test.sh feeds each
# subcommand a deliberately-BROKEN fixture and asserts it FAILS (plus that a GOOD
# fixture PASSES), so a future edit that neuters a check is caught in CI on every
# PR — not silently at the next release.
#
# It is pure string/JSON logic — no cluster needed. `jq` must be on PATH (it is on
# the GitHub ubuntu runners the gate already relies on).
#
# Usage:
#   vault-key-custody-checks.sh <check>
#     check : transit-key | signer-log | no-key-secret | pubkey | receipt
#   The fixture is read from STDIN.
#
# Each check exits 0 when the invariant holds and non-zero (printing the SAME
# GitHub ::error annotation the gate relies on) when it is violated.

set -uo pipefail

# transit-key — STDIN is the JSON from `vault read -format=json
# transit/keys/szl-receipts`. Assert the Transit signing key is NON-EXPORTABLE
# (private key can never leave Vault) and is an ed25519 key.
transit_key() {
  local key_json exportable key_type
  key_json="$(cat)"
  exportable="$(printf '%s' "$key_json" | jq -r '.data.exportable')"
  key_type="$(printf '%s' "$key_json" | jq -r '.data.type')"
  echo "transit/keys/szl-receipts: type=$key_type exportable=$exportable"
  if [ "$exportable" != "false" ]; then
    echo "::error::Vault Transit signing key is exportable=$exportable (custody violation)"
    return 1
  fi
  if [ "$key_type" != "ed25519" ]; then
    echo "::error::Vault Transit signing key type=$key_type (expected ed25519)"
    return 1
  fi
  echo "OK: Transit key is ed25519 and non-exportable"
}

# signer-log — STDIN is the receipts-server log. Assert (a) the server engaged
# Vault Transit via Kubernetes ServiceAccount auth (the exact success line emitted
# by VaultTransitSigner._init(): "[vault] Transit signer ready; ... auth=kubernetes
# ..."), requiring auth=kubernetes so a static token Secret (which would defeat
# Tier-2 custody) does not satisfy the gate; and (b) the MOST RECENT signer-state
# line is "ready", not the silent "running unsigned" fallback. The server
# self-heals (recheck loop re-runs _init), so a transient unsigned line at boot
# followed by recovery is fine — only the latest state is judged.
signer_log() {
  local logs signer_state
  logs="$(cat)"
  if ! printf '%s' "$logs" | grep -qiE '\[vault\] Transit signer ready;.*auth=kubernetes'; then
    echo "::error::No '[vault] Transit signer ready; ... auth=kubernetes' line in server logs"
    echo "::error::Server did not engage Vault Transit via Kubernetes ServiceAccount auth"
    return 1
  fi
  signer_state="$(printf '%s' "$logs" \
    | grep -iE '\[vault\] Transit signer ready|running unsigned' | tail -n1 || true)"
  if [ -z "$signer_state" ]; then
    echo "::error::No Vault signer-state line found in server logs at all"
    return 1
  fi
  if printf '%s' "$signer_state" | grep -qi 'running unsigned'; then
    echo "::error::Server's most recent signer state is UNSIGNED — Vault signing did not engage / did not recover"
    echo "last signer-state line: $signer_state"
    return 1
  fi
  echo "OK: server signing via Vault Transit (auth=kubernetes), latest state ready"
}

# no-key-secret — STDIN is the output of `kubectl get secret szl-receipts-ed25519
# -o name` (empty when the Secret is absent). Assert NO Ed25519 signing-key Secret
# exists in the cluster: with Tier-2 custody the key lives in Vault, never a Secret.
no_key_secret() {
  local present
  present="$(cat)"
  if [ -n "$(printf '%s' "$present" | tr -d '[:space:]')" ]; then
    echo "::error::Unexpected signing-key Secret szl-receipts-ed25519 present — custody is supposed to live in Vault"
    return 1
  fi
  echo "OK: no szl-receipts-ed25519 Secret in the cluster"
}

# pubkey — STDIN is the GET /pubkey JSON. Assert signed==true AND backend==vault.
# The server self-heals to an unsigned state if Vault is unreachable, so this
# catches a silent file/unsigned downgrade.
pubkey() {
  local body signed backend
  body="$(cat)"
  signed="$(printf '%s' "$body" | jq -r '.signed')"
  backend="$(printf '%s' "$body" | jq -r '.backend')"
  if [ "$signed" != "true" ]; then
    echo "::error::/pubkey reports signed=$signed (expected true)"
    return 1
  fi
  if [ "$backend" != "vault" ]; then
    echo "::error::/pubkey reports backend=$backend (expected vault — silent file/unsigned downgrade)"
    return 1
  fi
  echo "OK: /pubkey reports signed=true backend=vault"
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
    transit-key)   transit_key ;;
    signer-log)    signer_log ;;
    no-key-secret) no_key_secret ;;
    pubkey)        pubkey ;;
    receipt)       receipt ;;
    *) echo "::error::unknown check: '$CHECK' (want transit-key|signer-log|no-key-secret|pubkey|receipt)" >&2; exit 2 ;;
  esac
fi
