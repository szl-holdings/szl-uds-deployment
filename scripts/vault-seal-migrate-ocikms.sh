#!/usr/bin/env bash
# Copyright 2026 SZL Holdings
# SPDX-License-Identifier: Apache-2.0
#
# vault-seal-migrate-ocikms.sh — migrate the persistent szl-receipts Vault on the
# uds-szl-demo k3d cluster (box 167.233.50.75) from a 1/1 Shamir seal to OCI KMS
# AUTO-UNSEAL, with ZERO loss of the Transit signing key (Task #625).
#
# WHAT THIS DOES (and why it is safe)
#   Changing the seal only re-wraps Vault's barrier MASTER key. The Transit
#   signing key (transit/keys/szl-receipts) lives inside the barrier and is
#   untouched, so the receipts public key is preserved across the migration.
#   This script proves that by snapshotting the receipts /pubkey BEFORE and
#   asserting it is byte-identical AFTER. It also takes a full Vault keystore
#   backup first (scripts/vault-keystore-backup.sh) as a break-glass safety net.
#
# AFTER A SUCCESSFUL MIGRATION
#   * Vault auto-unseals on every restart via OCI KMS — no human unseal, no
#     on-box unseal key.
#   * The old Shamir key becomes a RECOVERY key. Keep ONE copy OFF the box
#     (break-glass) and delete the on-box /root/vault-init* copies.
#   * box-scripts/sbin/vault-auto-unseal detects seal type != shamir and
#     self-retires (no-op); remove its timer when convenient (runbook §6a).
#
# PREREQUISITES (provided by Stephen from a free OCI account — see runbook §6a):
#   OCI_KEY_ID, OCI_CRYPTO_ENDPOINT, OCI_MGMT_ENDPOINT  (the seal stanza values)
#   OCI_CONFIG_FILE, OCI_API_KEY_PEM                    (paths to the API-key
#                                                        config + private key)
# Run on the box with KUBECONFIG pointing at uds-szl-demo.
set -euo pipefail

NS_VAULT="vault"
DEPLOY="vault"
NS_RX="szl-receipts"
RX_SELECTOR="app=szl-receipts-server"
INIT_JSON="${INIT_JSON:-/root/vault-init/init.json}"
SECRET_NAME="vault-ocikms"

die() { echo "FATAL: $*" >&2; exit 1; }
log() { echo "[seal-migrate] $*"; }

for v in OCI_KEY_ID OCI_CRYPTO_ENDPOINT OCI_MGMT_ENDPOINT OCI_CONFIG_FILE OCI_API_KEY_PEM; do
  [ -n "${!v:-}" ] || die "env $v is required (see runbook §6a)."
done
[ -f "$OCI_CONFIG_FILE" ] || die "OCI_CONFIG_FILE '$OCI_CONFIG_FILE' not found."
[ -f "$OCI_API_KEY_PEM" ] || die "OCI_API_KEY_PEM '$OCI_API_KEY_PEM' not found."
command -v kubectl >/dev/null || die "kubectl not found."

kx() { kubectl -n "$NS_VAULT" "$@"; }
vault_in_pod() { kx exec "deploy/$DEPLOY" -- sh -c "VAULT_ADDR=http://127.0.0.1:8200 $*"; }

seal_type() { vault_in_pod 'vault status -format=json' 2>/dev/null \
  | python3 -c 'import sys,json;print(json.load(sys.stdin).get("type",""))' 2>/dev/null; }

rx_pubkey() {
  local rpod
  rpod="$(kubectl -n "$NS_RX" get pods -l "$RX_SELECTOR" \
    --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
  [ -n "$rpod" ] || { echo ""; return 0; }
  kubectl -n "$NS_RX" exec "$rpod" -- python3 -c \
    'import json,urllib.request;d=json.load(urllib.request.urlopen("http://127.0.0.1:8080/pubkey",timeout=8));print(d.get("public_key") or d.get("pubkey") or "")' 2>/dev/null || echo ""
}

# --- 0. Preconditions -------------------------------------------------------
kx get deploy "$DEPLOY" >/dev/null 2>&1 || die "deploy/$DEPLOY not found in ns/$NS_VAULT."
CUR="$(seal_type)"
log "current seal type: ${CUR:-unknown}"
if [ "$CUR" = "ocikms" ]; then
  log "Vault is ALREADY on OCI KMS auto-unseal — nothing to migrate. Exiting clean."
  exit 0
fi
[ "$CUR" = "shamir" ] || die "expected seal type 'shamir', got '${CUR:-unreachable}'. Aborting (will not migrate an unknown seal)."
[ -f "$INIT_JSON" ] || die "$INIT_JSON not found — need the Shamir unseal key to perform the -migrate unseal."

PUBKEY_BEFORE="$(rx_pubkey)"
log "receipts pubkey BEFORE: ${PUBKEY_BEFORE:-<receipts not reachable>}"

# --- 1. Safety net: full keystore backup ------------------------------------
if [ -x scripts/vault-keystore-backup.sh ]; then
  log "taking full Vault keystore backup (break-glass safety net)..."
  scripts/vault-keystore-backup.sh || die "keystore backup failed — refusing to migrate without a backup."
else
  log "WARN: scripts/vault-keystore-backup.sh not found/executable — proceeding WITHOUT an automated backup is NOT recommended."
  read -r -p "Type MIGRATE to continue without a keystore backup: " ans
  [ "$ans" = "MIGRATE" ] || die "aborted by operator (no backup)."
fi

# --- 2. Mount the OCI API-key credential as a Secret ------------------------
log "creating/updating Secret $SECRET_NAME (OCI API-key config + private key)..."
kx create secret generic "$SECRET_NAME" \
  --from-file=config="$OCI_CONFIG_FILE" \
  --from-file=oci_api_key.pem="$OCI_API_KEY_PEM" \
  --dry-run=client -o yaml | kx apply -f -

# --- 3. Add the ocikms seal stanza to the live vault.hcl ConfigMap ----------
log "patching vault-config ConfigMap with the ocikms seal stanza..."
CURRENT_HCL="$(kx get configmap vault-config -o jsonpath='{.data.vault\.hcl}')"
if printf '%s' "$CURRENT_HCL" | grep -q 'seal "ocikms"'; then
  log "ocikms seal stanza already present in ConfigMap — leaving as-is."
else
  NEW_HCL="$CURRENT_HCL

seal \"ocikms\" {
  key_id              = \"$OCI_KEY_ID\"
  crypto_endpoint     = \"$OCI_CRYPTO_ENDPOINT\"
  management_endpoint = \"$OCI_MGMT_ENDPOINT\"
  auth_type_api_key   = \"true\"
}
"
  kx create configmap vault-config --from-literal=vault.hcl="$NEW_HCL" \
    --dry-run=client -o yaml | kx apply -f -
fi

# --- 4. Mount the Secret + OCI env into the Deployment ----------------------
log "patching Deployment/$DEPLOY to mount the OCI credential + env..."
kx patch deploy "$DEPLOY" --type=json -p '[
  {"op":"add","path":"/spec/template/spec/volumes/-","value":{"name":"oci-creds","secret":{"secretName":"'"$SECRET_NAME"'","defaultMode":256}}},
  {"op":"add","path":"/spec/template/spec/containers/0/volumeMounts/-","value":{"name":"oci-creds","mountPath":"/home/vault/.oci","readOnly":true}},
  {"op":"add","path":"/spec/template/spec/containers/0/env/-","value":{"name":"OCI_CLI_CONFIG_FILE","value":"/home/vault/.oci/config"}},
  {"op":"add","path":"/spec/template/spec/containers/0/env/-","value":{"name":"OCI_CONFIG_FILE","value":"/home/vault/.oci/config"}}
]' 2>/dev/null || log "NOTE: env/volume may already be patched (idempotent) — continuing."

log "restarting Vault so it loads the new seal config (it will come up SEALED in migration mode)..."
kx rollout restart deploy/"$DEPLOY"
kx rollout status deploy/"$DEPLOY" --timeout=180s

# --- 5. Migration unseal: shamir -> ocikms ----------------------------------
THRESHOLD="$(python3 -c 'import json;print(json.load(open("'"$INIT_JSON"'")).get("unseal_threshold",1))')"
log "running migration unseal ($THRESHOLD share(s), shamir -> ocikms)..."
i=0
while [ "$i" -lt "$THRESHOLD" ]; do
  KEY="$(python3 -c 'import json,sys;print(json.load(open("'"$INIT_JSON"'"))["unseal_keys_b64"]['"$i"'])')"
  printf '%s\n' "$KEY" | kx exec -i "deploy/$DEPLOY" -- \
    sh -c 'read K; VAULT_ADDR=http://127.0.0.1:8200 vault operator unseal -migrate "$K"'
  i=$((i+1))
done

# Some Vault versions need a final plain unseal after the migrate shares.
sleep 3
if [ "$(vault_in_pod 'vault status -format=json' | python3 -c 'import sys,json;print(json.load(sys.stdin).get("sealed"))')" = "True" ]; then
  log "still sealed after migrate shares — issuing a final unseal to complete migration..."
  KEY="$(python3 -c 'import json;print(json.load(open("'"$INIT_JSON"'"))["unseal_keys_b64"][0])')"
  printf '%s\n' "$KEY" | kx exec -i "deploy/$DEPLOY" -- \
    sh -c 'read K; VAULT_ADDR=http://127.0.0.1:8200 vault operator unseal -migrate "$K"' || true
fi

# --- 6. Verify auto-unseal + Transit key survival ---------------------------
NEW="$(seal_type)"
[ "$NEW" = "ocikms" ] || die "post-migration seal type is '$NEW', expected 'ocikms'. DO NOT delete init.json. Investigate."
log "seal type is now: $NEW  ✅"

log "proving auto-unseal across a restart (no human unseal)..."
kx rollout restart deploy/"$DEPLOY"
kx rollout status deploy/"$DEPLOY" --timeout=180s
sleep 5
SEALED_AFTER="$(vault_in_pod 'vault status -format=json' | python3 -c 'import sys,json;print(json.load(sys.stdin).get("sealed"))')"
[ "$SEALED_AFTER" = "False" ] || die "Vault did NOT auto-unseal after restart (sealed=$SEALED_AFTER). DO NOT delete init.json. Check OCI creds/endpoints."
log "Vault auto-unsealed after restart (sealed=false)  ✅"

# Give the receipts watchdog a moment to re-establish its signer, then compare.
for _ in 1 2 3 4 5 6; do
  PUBKEY_AFTER="$(rx_pubkey)"; [ -n "$PUBKEY_AFTER" ] && break; sleep 5
done
log "receipts pubkey AFTER:  ${PUBKEY_AFTER:-<receipts not reachable>}"
if [ -n "$PUBKEY_BEFORE" ] && [ -n "$PUBKEY_AFTER" ]; then
  [ "$PUBKEY_BEFORE" = "$PUBKEY_AFTER" ] || die "receipts PUBLIC KEY CHANGED across migration! Transit key not preserved. Restore from the keystore backup; DO NOT delete init.json."
  log "receipts public key UNCHANGED across migration — Transit signing key preserved  ✅"
else
  log "WARN: could not compare receipts pubkey (receipts unreachable before/after). Verify signing manually before removing init.json."
fi

cat <<EOF

================================================================================
 MIGRATION COMPLETE — Vault now auto-unseals via OCI KMS (free, off-box).
================================================================================
 Next (manual, deliberate) steps:
   1. Keep ONE copy of the Shamir/recovery key OFF the box (break-glass only).
   2. Remove the on-box unseal-key copies:
        shred -u /root/vault-init/init.json /root/vault-init.json \\
                 /root/vault-init/*.stale-*.bak 2>/dev/null
   3. The vault-auto-unseal helper now self-retires (seal type != shamir).
      Disable its timer when convenient:
        systemctl disable --now vault-auto-unseal.timer
   4. Commit the seal stanza into k8s/vault/vault-persistent.yaml so a future
      re-apply keeps auto-unseal (use vault-seal-ocikms.example.hcl as the
      template; keep the OCI API key only in the Secret, never in git).
 See docs/operations/VAULT_PERSISTENT_RUNBOOK.md §6a.
================================================================================
EOF
