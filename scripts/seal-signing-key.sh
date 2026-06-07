#!/usr/bin/env bash
# Copyright 2026 SZL Holdings
# SPDX-License-Identifier: Apache-2.0
#
# seal-signing-key.sh — Tier 1 key custody: turn an Ed25519 private key into a
# committable SealedSecret ciphertext for the szl-receipts chart.
#
# It runs `kubeseal` against the in-cluster sealed-secrets controller and prints
# the encrypted blob you paste into values: signing.sealedSecret.encryptedKey.
# The ciphertext is decryptable ONLY by that cluster's controller, so it is safe
# to commit to git. The plaintext key never goes near the chart or the repo.
#
# Requirements: kubeseal + kubectl on PATH; sealed-secrets controller installed
# in the cluster; an Ed25519 PEM private key.
#
# Usage:
#   # generate a fresh key (or supply your own PEM with --key):
#   openssl genpkey -algorithm ed25519 -out ed25519.pem
#
#   scripts/seal-signing-key.sh \
#     --key ed25519.pem \
#     --namespace szl-receipts \
#     --secret-name szl-receipts-ed25519 \
#     [--scope strict|namespace-wide|cluster-wide] \
#     [--controller-name sealed-secrets --controller-namespace sealed-secrets]
#
# Then in values.yaml:
#   signing:
#     backend: file
#     sealedSecret:
#       enabled: true
#       scope: strict
#       encryptedKey: "<the AgB... blob printed by this script>"
#
# IMPORTANT: shred the local plaintext key afterwards — the cluster (via the
# sealed Secret) is the source of truth:
#   shred -u ed25519.pem
set -euo pipefail

KEYFILE="ed25519.pem"
NS="szl-receipts"
SECRET_NAME="szl-receipts-ed25519"
KEY_INSIDE="ed25519.pem"
SCOPE="strict"
CTRL_NAME="sealed-secrets"
CTRL_NS="sealed-secrets"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --key) KEYFILE="$2"; shift 2;;
    --namespace) NS="$2"; shift 2;;
    --secret-name) SECRET_NAME="$2"; shift 2;;
    --key-inside) KEY_INSIDE="$2"; shift 2;;
    --scope) SCOPE="$2"; shift 2;;
    --controller-name) CTRL_NAME="$2"; shift 2;;
    --controller-namespace) CTRL_NS="$2"; shift 2;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done

command -v kubeseal >/dev/null || { echo "ERROR: kubeseal not found on PATH" >&2; exit 1; }
command -v kubectl  >/dev/null || { echo "ERROR: kubectl not found on PATH"  >&2; exit 1; }
[[ -f "$KEYFILE" ]] || { echo "ERROR: key file not found: $KEYFILE" >&2; exit 1; }

# Sanity: confirm it really is an Ed25519 private key.
if command -v openssl >/dev/null; then
  if ! openssl pkey -in "$KEYFILE" -noout -text 2>/dev/null | grep -qi ed25519; then
    echo "ERROR: $KEYFILE does not look like an Ed25519 private key" >&2
    exit 1
  fi
fi

SCOPE_FLAG=""
case "$SCOPE" in
  strict) SCOPE_FLAG="--scope strict";;
  namespace-wide) SCOPE_FLAG="--scope namespace-wide";;
  cluster-wide) SCOPE_FLAG="--scope cluster-wide";;
  *) echo "ERROR: invalid --scope $SCOPE" >&2; exit 2;;
esac

echo "==> Building a temporary Secret and sealing the ${KEY_INSIDE} entry..." >&2

# Build a raw Secret in memory and pipe it through kubeseal. --raw would also
# work but the full-Secret path lets kubeseal apply scope consistently.
TMP_JSON="$(kubectl create secret generic "$SECRET_NAME" \
  --namespace "$NS" \
  --from-file="${KEY_INSIDE}=${KEYFILE}" \
  --dry-run=client -o json)"

SEALED="$(printf '%s' "$TMP_JSON" | kubeseal \
  --controller-name "$CTRL_NAME" \
  --controller-namespace "$CTRL_NS" \
  $SCOPE_FLAG \
  -o json)"

CIPHERTEXT="$(printf '%s' "$SEALED" | \
  (command -v jq >/dev/null && jq -r ".spec.encryptedData[\"${KEY_INSIDE}\"]" \
    || python3 -c "import sys,json;print(json.load(sys.stdin)['spec']['encryptedData']['${KEY_INSIDE}'])"))"

if [[ -z "$CIPHERTEXT" || "$CIPHERTEXT" == "null" ]]; then
  echo "ERROR: kubeseal produced no ciphertext" >&2
  exit 1
fi

cat >&2 <<EOF

==> Sealed OK (scope=${SCOPE}). Paste this into values.yaml:

signing:
  backend: file
  sealedSecret:
    enabled: true
    scope: ${SCOPE}
    encryptedKey: >-
EOF
# Print the ciphertext on stdout so it can be captured/redirected cleanly.
echo "$CIPHERTEXT"

cat >&2 <<EOF

==> Remember to destroy the local plaintext key:
    shred -u ${KEYFILE}    # or: rm -P ${KEYFILE}
EOF
