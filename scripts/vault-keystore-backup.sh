#!/usr/bin/env bash
# Copyright 2026 SZL Holdings
# SPDX-License-Identifier: Apache-2.0
#
# vault-keystore-backup.sh — snapshot the persistent Vault file-store (the
# encrypted barrier that holds the szl-receipts Transit signing key) together
# with its matching Shamir unseal shares, so that a `k3d cluster delete` /
# `uds run recreate-full` no longer silently rotates the receipt signing key.
#
# WHY a storage snapshot and NOT a key export: the Transit Ed25519 key is
# created non-exportable (exportable=false, allow_plaintext_backup=false) — there
# is no Vault API to read the private key out. The durable, honest way to
# preserve it is to back up Vault's own encrypted file storage (/vault/data)
# together with the unseal shares that decrypt it. Restoring both reproduces the
# IDENTICAL barrier => identical Transit key => receipts signed before the
# recreate still verify against the same public key.
#
# The snapshot is written OFF the cluster and OFF git: it contains the unseal
# shares + root token (init.json), so it is sensitive and never belongs in the
# repo. A `k3d cluster delete` wipes the in-cluster local-path PV but NOT the
# host filesystem, so a backup under /root/... outlives the cluster — that is
# exactly what lets the recreate restore the same key.
#
# Companion restore: scripts/vault-keystore-restore.sh
# Runbook: docs/operations/VAULT_PERSISTENT_RUNBOOK.md (§ "Preserve signing
# across a cluster recreate").
#
# Usage:
#   scripts/vault-keystore-backup.sh \
#     [--namespace vault] [--deploy vault] \
#     [--init-json /root/vault-init/init.json] \
#     [--backup-dir /root/vault-keystore-backup] \
#     [--transit-mount transit] [--transit-key szl-receipts] \
#     [--allow-missing-init]
#
# Exit codes: 0 success; 2 bad args; 3 no reachable Vault pod (nothing to back
# up — caller may treat this as a soft skip); 1 any other failure.
set -euo pipefail

NS="vault"
DEPLOY="vault"
INIT_JSON="/root/vault-init/init.json"
BACKUP_DIR="/root/vault-keystore-backup"
TRANSIT_MOUNT="transit"
TRANSIT_KEY="szl-receipts"
ALLOW_MISSING_INIT=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --namespace) NS="$2"; shift 2;;
    --deploy) DEPLOY="$2"; shift 2;;
    --init-json) INIT_JSON="$2"; shift 2;;
    --backup-dir) BACKUP_DIR="$2"; shift 2;;
    --transit-mount) TRANSIT_MOUNT="$2"; shift 2;;
    --transit-key) TRANSIT_KEY="$2"; shift 2;;
    --allow-missing-init) ALLOW_MISSING_INIT=1; shift;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done

command -v kubectl >/dev/null || { echo "ERROR: kubectl not found on PATH" >&2; exit 1; }

log() { echo "[vault-keystore-backup] $*"; }

# 1) Is there a reachable Vault pod to snapshot?
if ! kubectl -n "$NS" get deploy "$DEPLOY" >/dev/null 2>&1; then
  log "no '$DEPLOY' deployment in namespace '$NS' — nothing to back up."
  exit 3
fi
POD="$(kubectl -n "$NS" get pod -l app.kubernetes.io/name=vault \
        -o jsonpath='{.items[?(@.status.phase=="Running")].metadata.name}' 2>/dev/null \
        | awk '{print $1}')"
if [[ -z "${POD:-}" ]]; then
  log "no Running Vault pod in namespace '$NS' — nothing to back up."
  exit 3
fi
log "snapshotting Vault file-store from pod $NS/$POD"

# 2) Prepare the (sensitive) off-cluster backup destination.
TS="$(date -u +%Y%m%dT%H%M%SZ)"
DEST="$BACKUP_DIR/$TS"
mkdir -p "$DEST"
chmod 700 "$BACKUP_DIR" "$DEST"

TAR="$DEST/vault-data.tar.gz"

# 3) Snapshot /vault/data (the encrypted barrier). The cluster is expected to be
#    idle at this point (recreate-full's idle-check guarantees it), so a
#    tar-while-running of the small single-node file store is consistent enough.
kubectl -n "$NS" exec "$POD" -- tar czf - -C /vault data > "$TAR"
if [[ ! -s "$TAR" ]]; then
  echo "ERROR: produced an empty Vault data snapshot" >&2; exit 1
fi
# Sanity: the barrier core must be present, else this is not a real Vault store.
# (Read the listing into a variable first: `tar tzf | grep -q` trips the
# pipefail SIGPIPE trap — grep exits early, tar dies on SIGPIPE, pipefail then
# fails the whole pipeline even though the match succeeded.)
TAR_LISTING="$(tar tzf "$TAR")"
if ! grep -q '^data/core/' <<<"$TAR_LISTING"; then
  echo "ERROR: snapshot does not contain data/core/ — not a valid Vault store" >&2
  exit 1
fi
chmod 600 "$TAR"
TAR_SHA="$(sha256sum "$TAR" | awk '{print $1}')"
log "wrote $(du -h "$TAR" | awk '{print $1}') snapshot ($TAR_SHA)"

# 4) Capture the matching unseal shares + root token. WITHOUT these the snapshot
#    cannot be decrypted on restore, so by default a missing init.json is fatal.
if [[ -f "$INIT_JSON" ]]; then
  cp "$INIT_JSON" "$DEST/init.json"
  chmod 600 "$DEST/init.json"
  log "captured matching unseal shares from $INIT_JSON"
else
  if [[ "$ALLOW_MISSING_INIT" == "1" ]]; then
    log "WARNING: init.json '$INIT_JSON' not found — snapshot stored WITHOUT shares (NOT restorable on its own)."
  else
    echo "ERROR: init.json '$INIT_JSON' not found. The snapshot is useless without" >&2
    echo "       the unseal shares that decrypt it. Pass --init-json <path> or" >&2
    echo "       --allow-missing-init to override." >&2
    exit 1
  fi
fi

# 5) Record the public key the snapshot will reproduce, for restore-time
#    verification. Best-effort: needs the root token from init.json.
PUBKEY=""
KEY_VERSION=""
if [[ -f "$DEST/init.json" ]]; then
  RT="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("root_token",""))' "$DEST/init.json" 2>/dev/null || true)"
  if [[ -n "${RT:-}" ]]; then
    KJSON="$(kubectl -n "$NS" exec "$POD" -- sh -c \
      "VAULT_TOKEN=$RT vault read -format=json $TRANSIT_MOUNT/keys/$TRANSIT_KEY" 2>/dev/null || true)"
    if [[ -n "${KJSON:-}" ]]; then
      read -r PUBKEY KEY_VERSION < <(printf '%s' "$KJSON" | python3 -c '
import json,sys
d=json.load(sys.stdin)["data"]; keys=d.get("keys",{})
lv=str(d.get("latest_version", max((int(k) for k in keys), default="")))
print(keys.get(lv,{}).get("public_key",""), lv)
' 2>/dev/null || echo " ")
    fi
  fi
fi
if [[ -n "$PUBKEY" ]]; then
  printf '%s\n' "$PUBKEY" > "$DEST/pubkey.txt"
  log "recorded transit pubkey ($TRANSIT_MOUNT/$TRANSIT_KEY v$KEY_VERSION): $PUBKEY"
else
  log "WARNING: could not read transit pubkey for restore-time verification (continuing)."
fi

# 6) Manifest + 'latest' pointer.
cat > "$DEST/meta.json" <<EOF
{
  "timestamp": "$TS",
  "namespace": "$NS",
  "deploy": "$DEPLOY",
  "source_pod": "$POD",
  "transit_mount": "$TRANSIT_MOUNT",
  "transit_key": "$TRANSIT_KEY",
  "transit_key_version": "${KEY_VERSION}",
  "transit_pubkey": "${PUBKEY}",
  "tar": "vault-data.tar.gz",
  "tar_sha256": "$TAR_SHA",
  "has_init_json": $([[ -f "$DEST/init.json" ]] && echo true || echo false)
}
EOF
chmod 600 "$DEST/meta.json"
ln -sfn "$DEST" "$BACKUP_DIR/latest"

log "backup complete -> $DEST"
log "  (latest -> $(readlink -f "$BACKUP_DIR/latest"))"
echo "$DEST"
