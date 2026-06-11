#!/usr/bin/env bash
# Copyright 2026 SZL Holdings
# SPDX-License-Identifier: Apache-2.0
#
# vault-keystore-restore.sh — restore a Vault file-store snapshot taken by
# scripts/vault-keystore-backup.sh into a FRESH (just-recreated) Vault, then
# unseal it with the matching Shamir shares, so the szl-receipts Transit signing
# key is the SAME one that existed before `k3d cluster delete` /
# `uds run recreate-full`. Receipts signed before the recreate keep verifying.
#
# This restores Vault's encrypted barrier (which the non-exportable Transit key
# lives inside) and the unseal shares that decrypt it. It deliberately does NOT
# re-run setup-vault-transit.sh: the Transit engine, the Ed25519 key AND the
# kubernetes-auth role all live inside the restored barrier, so they come back
# intact. The kubernetes-auth method keeps working across a cluster recreate
# because Vault validates pod SA JWTs against kubernetes_host
# (https://kubernetes.default.svc) using its own pod token at request time — it
# does not store the (now-changed) cluster CA.
#
# Companion backup: scripts/vault-keystore-backup.sh
# Runbook: docs/operations/VAULT_PERSISTENT_RUNBOOK.md (§ "Preserve signing
# across a cluster recreate").
#
# Usage:
#   scripts/vault-keystore-restore.sh \
#     [--namespace vault] [--deploy vault] \
#     [--backup /root/vault-keystore-backup/latest] \
#     [--transit-mount transit] [--transit-key szl-receipts] \
#     [--expect-pubkey <base64>] \
#     [--refresh-box-init [/root/vault-init/init.json]] \
#     [--force]
#
# --force          : restore even if the target Vault is already initialised
#                    (default refuses, to avoid clobbering a real Vault).
# --refresh-box-init : after a successful restore, copy the snapshot's shares to
#                    the box auto-unseal source (default /root/vault-init/init.json)
#                    so the vault-auto-unseal timer uses matching shares.
#
# Exit codes: 0 success (pubkey verified); 2 bad args; 1 any failure.
set -euo pipefail

NS="vault"
DEPLOY="vault"
BACKUP="/root/vault-keystore-backup/latest"
TRANSIT_MOUNT="transit"
TRANSIT_KEY="szl-receipts"
EXPECT_PUBKEY=""
FORCE=0
REFRESH_BOX_INIT=0
BOX_INIT_DEST="/root/vault-init/init.json"
SENTINEL="/tmp/szl-vault-restore.ok"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --namespace) NS="$2"; shift 2;;
    --deploy) DEPLOY="$2"; shift 2;;
    --backup) BACKUP="$2"; shift 2;;
    --transit-mount) TRANSIT_MOUNT="$2"; shift 2;;
    --transit-key) TRANSIT_KEY="$2"; shift 2;;
    --expect-pubkey) EXPECT_PUBKEY="$2"; shift 2;;
    --force) FORCE=1; shift;;
    --refresh-box-init)
      REFRESH_BOX_INIT=1
      if [[ $# -ge 2 && "${2:0:2}" != "--" ]]; then BOX_INIT_DEST="$2"; shift 2; else shift; fi;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done

command -v kubectl >/dev/null || { echo "ERROR: kubectl not found on PATH" >&2; exit 1; }
log() { echo "[vault-keystore-restore] $*"; }

rm -f "$SENTINEL" 2>/dev/null || true

# 1) Validate the backup bundle.
BDIR="$(readlink -f "$BACKUP" 2>/dev/null || echo "$BACKUP")"
TAR="$BDIR/vault-data.tar.gz"
INIT="$BDIR/init.json"
META="$BDIR/meta.json"
[[ -d "$BDIR" ]]  || { echo "ERROR: backup dir not found: $BACKUP" >&2; exit 1; }
[[ -s "$TAR" ]]   || { echo "ERROR: snapshot missing: $TAR" >&2; exit 1; }
[[ -s "$INIT" ]]  || { echo "ERROR: unseal shares missing: $INIT (cannot decrypt the barrier)" >&2; exit 1; }
log "restoring from $BDIR"

# Verify the snapshot integrity against the manifest if present.
if [[ -s "$META" ]]; then
  WANT_SHA="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("tar_sha256",""))' "$META" 2>/dev/null || true)"
  if [[ -n "$WANT_SHA" ]]; then
    GOT_SHA="$(sha256sum "$TAR" | awk '{print $1}')"
    [[ "$WANT_SHA" == "$GOT_SHA" ]] || { echo "ERROR: snapshot sha256 mismatch (corrupt backup)" >&2; exit 1; }
    log "snapshot integrity OK ($GOT_SHA)"
  fi
  if [[ -z "$EXPECT_PUBKEY" ]]; then
    EXPECT_PUBKEY="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("transit_pubkey",""))' "$META" 2>/dev/null || true)"
  fi
fi
[[ -z "$EXPECT_PUBKEY" && -s "$BDIR/pubkey.txt" ]] && EXPECT_PUBKEY="$(head -1 "$BDIR/pubkey.txt")"

# 2) Wait for a Running Vault pod.
log "waiting for a Running Vault pod in ns '$NS'..."
for _ in $(seq 1 60); do
  POD="$(kubectl -n "$NS" get pod -l app.kubernetes.io/name=vault \
          -o jsonpath='{.items[?(@.status.phase=="Running")].metadata.name}' 2>/dev/null | awk '{print $1}')"
  [[ -n "${POD:-}" ]] && break
  sleep 3
done
[[ -n "${POD:-}" ]] || { echo "ERROR: no Running Vault pod in ns '$NS'" >&2; exit 1; }
log "target pod: $NS/$POD"

# 3) Refuse to clobber an already-initialised Vault unless --force.
INITIALIZED="$(kubectl -n "$NS" exec "$POD" -- sh -c \
  'vault status -format=json 2>/dev/null || true' | \
  python3 -c 'import json,sys
try: print(str(json.load(sys.stdin).get("initialized")).lower())
except Exception: print("unknown")' 2>/dev/null || echo unknown)"
log "target Vault initialized=$INITIALIZED"
if [[ "$INITIALIZED" == "true" && "$FORCE" != "1" ]]; then
  echo "ERROR: target Vault is already initialised. Refusing to overwrite its" >&2
  echo "       storage (would destroy a live signing key). Pass --force only if" >&2
  echo "       you are certain this Vault should be replaced by the snapshot." >&2
  exit 1
fi

# 4) Restore the encrypted file-store over the fresh PVC, then restart Vault so
#    it loads the restored barrier from disk.
log "extracting snapshot into $NS/$POD:/vault/data ..."
kubectl -n "$NS" exec -i "$POD" -- sh -c \
  'rm -rf /vault/data/* /vault/data/.[!.]* 2>/dev/null; tar xzf - --no-same-owner -C /vault' < "$TAR"
log "restarting Vault to load restored storage ..."
kubectl -n "$NS" rollout restart deploy/"$DEPLOY"
kubectl -n "$NS" rollout status deploy/"$DEPLOY" --timeout=120s

# new pod after restart
for _ in $(seq 1 60); do
  POD="$(kubectl -n "$NS" get pod -l app.kubernetes.io/name=vault \
          -o jsonpath='{.items[?(@.status.phase=="Running")].metadata.name}' 2>/dev/null | awk '{print $1}')"
  [[ -n "${POD:-}" ]] && break
  sleep 3
done
[[ -n "${POD:-}" ]] || { echo "ERROR: Vault pod did not come back after restart" >&2; exit 1; }

# 5) Confirm the restored store reads as initialised + sealed, then unseal with
#    the snapshot's shares.
for _ in $(seq 1 40); do
  ST="$(kubectl -n "$NS" exec "$POD" -- sh -c 'vault status -format=json 2>/dev/null || true')"
  INIT2="$(printf '%s' "$ST" | python3 -c 'import json,sys
try: print(str(json.load(sys.stdin).get("initialized")).lower())
except Exception: print("unknown")' 2>/dev/null || echo unknown)"
  [[ "$INIT2" == "true" ]] && break
  sleep 3
done
[[ "$INIT2" == "true" ]] || { echo "ERROR: restored Vault does not read as initialised" >&2; exit 1; }
log "restored Vault reads initialized=true (barrier restored)"

mapfile -t SHARES < <(python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
for k in d.get("unseal_keys_b64") or d.get("keys_base64") or []:
    print(k)
' "$INIT")
[[ "${#SHARES[@]}" -gt 0 ]] || { echo "ERROR: no unseal shares in $INIT" >&2; exit 1; }
log "unsealing with ${#SHARES[@]} share(s) ..."
for K in "${SHARES[@]}"; do
  printf '%s\n' "$K" | kubectl -n "$NS" exec -i "$POD" -- sh -c 'read KEY; vault operator unseal "$KEY" >/dev/null'
done
SEALED="$(kubectl -n "$NS" exec "$POD" -- sh -c 'vault status -format=json 2>/dev/null || true' | \
  python3 -c 'import json,sys
try: print(str(json.load(sys.stdin).get("sealed")).lower())
except Exception: print("unknown")' 2>/dev/null || echo unknown)"
[[ "$SEALED" == "false" ]] || { echo "ERROR: Vault still sealed after replaying shares" >&2; exit 1; }
log "Vault unsealed."

# 6) Verify the restored Transit key reproduces the expected public key.
RT="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("root_token",""))' "$INIT" 2>/dev/null || true)"
GOT_PUBKEY=""
if [[ -n "${RT:-}" ]]; then
  GOT_PUBKEY="$(kubectl -n "$NS" exec "$POD" -- sh -c \
    "VAULT_TOKEN=$RT vault read -format=json $TRANSIT_MOUNT/keys/$TRANSIT_KEY" 2>/dev/null | \
    python3 -c '
import json,sys
d=json.load(sys.stdin)["data"]; keys=d.get("keys",{})
lv=str(d.get("latest_version", max((int(k) for k in keys), default="")))
print(keys.get(lv,{}).get("public_key",""))
' 2>/dev/null || true)"
fi

if [[ -n "$GOT_PUBKEY" ]]; then
  log "restored transit pubkey: $GOT_PUBKEY"
  if [[ -n "$EXPECT_PUBKEY" ]]; then
    if [[ "$GOT_PUBKEY" == "$EXPECT_PUBKEY" ]]; then
      log "PASS: restored signing key matches the pre-recreate pubkey — old receipts still verify."
    else
      echo "ERROR: restored pubkey ($GOT_PUBKEY) != expected ($EXPECT_PUBKEY) — signing key was NOT preserved." >&2
      exit 1
    fi
  else
    log "WARNING: no expected pubkey recorded; cannot assert a match (key restored, unverified)."
  fi
else
  log "WARNING: could not read restored transit pubkey to verify the match (continuing)."
fi

# 7) Optionally point the box auto-unseal helper at the restored shares.
if [[ "$REFRESH_BOX_INIT" == "1" ]]; then
  if [[ -d "$(dirname "$BOX_INIT_DEST")" ]]; then
    cp "$INIT" "$BOX_INIT_DEST"; chmod 600 "$BOX_INIT_DEST"
    log "refreshed box auto-unseal shares: $BOX_INIT_DEST"
  else
    log "WARNING: --refresh-box-init set but $(dirname "$BOX_INIT_DEST") missing — skipped."
  fi
fi

printf '%s\n' "${GOT_PUBKEY:-$EXPECT_PUBKEY}" > "$SENTINEL" 2>/dev/null || true
log "restore complete."
