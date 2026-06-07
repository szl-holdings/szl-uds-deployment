#!/usr/bin/env bash
# Copyright 2026 SZL Holdings
# SPDX-License-Identifier: Apache-2.0
#
# setup-vault-transit.sh — bootstrap HashiCorp Vault for szl-receipts Tier 2
# key custody (Ed25519 "signing as a service" via the Transit secrets engine).
#
# What this does (idempotent):
#   1. Enables the `transit` secrets engine (if not already enabled).
#   2. Creates a NON-EXPORTABLE Ed25519 key `szl-receipts` inside Vault. The
#      private key is generated and held by Vault and NEVER leaves it — there is
#      no API to export it. The receipts server only ever calls transit/sign.
#   3. Writes a Vault policy granting the receipts server exactly two rights:
#      sign with the key and read the key's PUBLIC material (for verification).
#   4. (Optional) Configures Kubernetes auth so the pod's ServiceAccount JWT can
#      log in to Vault and obtain a short-lived token bound to that policy.
#
# It does NOT write any private key to disk or to git. The only thing the chart
# needs afterwards is the Vault address + (for k8s auth) the role name.
#
# Requirements: a reachable Vault with VAULT_ADDR + VAULT_TOKEN exported, and
# the `vault` CLI on PATH.
#
# Usage:
#   export VAULT_ADDR=https://vault.example:8200
#   export VAULT_TOKEN=<admin-or-bootstrap-token>
#   scripts/setup-vault-transit.sh \
#     [--key szl-receipts] [--mount transit] \
#     [--k8s-auth] [--k8s-role szl-receipts] \
#     [--k8s-namespace szl-receipts] [--k8s-sa szl-receipts]
set -euo pipefail

KEY="szl-receipts"
MOUNT="transit"
POLICY="szl-receipts-sign"
DO_K8S=0
K8S_ROLE="szl-receipts"
K8S_NS="szl-receipts"
K8S_SA="szl-receipts"
K8S_AUTH_MOUNT="kubernetes"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --key) KEY="$2"; shift 2;;
    --mount) MOUNT="$2"; shift 2;;
    --policy) POLICY="$2"; shift 2;;
    --k8s-auth) DO_K8S=1; shift;;
    --k8s-role) K8S_ROLE="$2"; shift 2;;
    --k8s-namespace) K8S_NS="$2"; shift 2;;
    --k8s-sa) K8S_SA="$2"; shift 2;;
    --k8s-auth-mount) K8S_AUTH_MOUNT="$2"; shift 2;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done

command -v vault >/dev/null || { echo "ERROR: vault CLI not found on PATH" >&2; exit 1; }
: "${VAULT_ADDR:?export VAULT_ADDR first}"
: "${VAULT_TOKEN:?export VAULT_TOKEN first}"

echo "==> Vault: $VAULT_ADDR"
vault status >/dev/null 2>&1 || { echo "ERROR: cannot reach/auth Vault" >&2; exit 1; }

# 1) Transit engine
if ! vault secrets list -format=json | grep -q "\"${MOUNT}/\""; then
  echo "==> Enabling transit at ${MOUNT}/"
  vault secrets enable -path="${MOUNT}" transit
else
  echo "==> transit already enabled at ${MOUNT}/"
fi

# 2) Ed25519 key (non-exportable by default; allow_plaintext_backup off)
if ! vault read -format=json "${MOUNT}/keys/${KEY}" >/dev/null 2>&1; then
  echo "==> Creating Ed25519 key ${MOUNT}/${KEY} (non-exportable)"
  vault write -f "${MOUNT}/keys/${KEY}" type=ed25519
  # Hard-guarantee the private key can never be exported or backed up in clear.
  vault write "${MOUNT}/keys/${KEY}/config" \
    exportable=false allow_plaintext_backup=false deletion_allowed=false
else
  echo "==> Key ${MOUNT}/${KEY} already exists"
fi

echo "==> Public key (Ed25519, for offline verification / GET /pubkey cross-check):"
vault read -field=keys -format=json "${MOUNT}/keys/${KEY}" || true

# 3) Policy: sign + read public key only (NO export, NO key management)
echo "==> Writing policy ${POLICY}"
vault policy write "${POLICY}" - <<EOF
# szl-receipts: sign DSSE PAE with the Ed25519 transit key, and read its PUBLIC
# material for verification. No export, no key creation/rotation/deletion.
path "${MOUNT}/sign/${KEY}" {
  capabilities = ["update"]
}
path "${MOUNT}/keys/${KEY}" {
  capabilities = ["read"]
}
EOF

# 4) Optional Kubernetes auth role
if [[ "$DO_K8S" == "1" ]]; then
  if ! vault auth list -format=json | grep -q "\"${K8S_AUTH_MOUNT}/\""; then
    echo "==> Enabling kubernetes auth at ${K8S_AUTH_MOUNT}/"
    vault auth enable -path="${K8S_AUTH_MOUNT}" kubernetes
    echo "    NOTE: configure auth/${K8S_AUTH_MOUNT}/config (kubernetes_host, CA, "
    echo "    token reviewer JWT) for your cluster — see Vault k8s-auth docs."
  fi
  echo "==> Binding role ${K8S_ROLE} -> SA ${K8S_NS}/${K8S_SA} -> policy ${POLICY}"
  vault write "auth/${K8S_AUTH_MOUNT}/role/${K8S_ROLE}" \
    bound_service_account_names="${K8S_SA}" \
    bound_service_account_namespaces="${K8S_NS}" \
    policies="${POLICY}" \
    ttl=20m
fi

cat <<EOF

==> Done. Configure the chart with:
    signing:
      backend: vault
      vault:
        address: ${VAULT_ADDR}
        transitMount: ${MOUNT}
        transitKey: ${KEY}
        auth:
          method: kubernetes
          role: ${K8S_ROLE}
          mount: ${K8S_AUTH_MOUNT}

The Ed25519 private key now lives ONLY inside Vault. Reading a Kubernetes Secret
no longer yields the signing key. Verify a receipt offline with:
    scripts/verify_receipts_ed25519.py --url https://receipts.<domain>
EOF
