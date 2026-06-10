# Copyright 2026 SZL Holdings
# SPDX-License-Identifier: Apache-2.0
#
# recreate-key-guard-checks.sh — guard the `uds run recreate-full` Vault
# signing-key preservation from being silently removed.
#
# WHY THIS EXISTS
# `recreate-full` tears the k3d cluster down (dropping the Vault PV) and rebuilds
# it. The Vault PV holds the Ed25519 Transit signing key, so a naive recreate
# ROTATES that key and every previously-issued receipt signature stops verifying
# against the new /pubkey. To avoid that, recreate-full now:
#   1. snapshots the Vault file-store + unseal shares BEFORE teardown
#      (scripts/vault-keystore-backup.sh), gated on PRESERVE_SIGNING_KEY, and
#   2. restores that snapshot AFTER the persistent Vault is re-applied
#      (scripts/vault-keystore-restore.sh), reproducing the IDENTICAL key, and
#   3. reports the outcome from the /tmp/szl-vault-restore.ok sentinel the
#      restore writes (so the operator KNOWS whether the key was preserved).
#
# tasks.yaml is a large, frequently-edited shared file. A future refactor could
# quietly drop the PRESERVE_SIGNING_KEY var, delete the backup or restore step,
# reorder the backup AFTER teardown, or drop the sentinel-aware status step —
# silently reintroducing the key-rotation bug with NO error. This guard fails
# such a PR. It is a pure text/lint check — no cluster needed.
#
# The check logic is extracted here (out of the workflow) so it can be UNIT
# TESTED: recreate-key-guard-checks.test.sh feeds each check a deliberately-
# BROKEN fixture and asserts the check FAILS (plus that the pristine repo
# PASSES). A future edit that neuters a check — green while guarding nothing —
# is caught by that self-test, not in production.
#
# Usage:
#   recreate-key-guard-checks.sh <check> [root]
#     check : chk1 | chk2 | chk3 | chk4 | all
#     root  : repo root to check (default: current directory)
#
# Each check exits 0 when the invariant holds and non-zero (printing a GitHub
# ::error annotation) when it is regressed.

set -uo pipefail

# err FILE MESSAGE — emit a GitHub Actions error annotation.
err() { echo "::error file=$1::$2"; }

# extract_task FILE TASKNAME — print the YAML block of a top-level (2-space
# indented) uds task, from its `  - name: <task>` line up to (but excluding) the
# next sibling `  - name:` line. Used to scope ordering checks to one task.
extract_task() {
  awk -v t="$2" '
    $0 ~ ("^  - name: " t "$") { inblk=1; print; next }
    inblk && /^  - name: / { inblk=0 }
    inblk { print }
  ' "$1"
}

# ── Check 1 ───────────────────────────────────────────────────────────────────
# The PRESERVE_SIGNING_KEY and VAULT_KEYSTORE_BACKUP_DIR variables are declared
# AND PRESERVE_SIGNING_KEY is actually referenced inside the recreate-full task.
# These are the on/off switch and the snapshot location the preservation flow
# depends on; without them the backup/restore steps cannot gate or find data.
chk1() {
  local root="${1:-.}"
  local F="$root/tasks.yaml"
  test -f "$F" || { err "$F" "missing — required for the recreate-full key guard"; return 1; }

  grep -Eq '^  - name: PRESERVE_SIGNING_KEY$' "$F" || {
    err "$F" "REGRESSION — PRESERVE_SIGNING_KEY variable is gone."
    err "$F" "Without it recreate-full can no longer gate signing-key preservation; the key WILL rotate."
    return 1
  }
  grep -Eq '^  - name: VAULT_KEYSTORE_BACKUP_DIR$' "$F" || {
    err "$F" "REGRESSION — VAULT_KEYSTORE_BACKUP_DIR variable is gone."
    err "$F" "The backup/restore steps have nowhere to write/read the keystore snapshot."
    return 1
  }

  local blk
  blk="$(extract_task "$F" recreate-full)"
  if [ -z "$blk" ]; then
    err "$F" "REGRESSION — 'recreate-full' task not found in tasks.yaml."
    return 1
  fi
  if ! printf '%s\n' "$blk" | grep -q 'PRESERVE_SIGNING_KEY'; then
    err "$F" "REGRESSION — recreate-full no longer references PRESERVE_SIGNING_KEY."
    err "$F" "The signing-key preservation flow has been disconnected from the task."
    return 1
  fi
  echo "OK: PRESERVE_SIGNING_KEY + VAULT_KEYSTORE_BACKUP_DIR present and wired into recreate-full"
}

# ── Check 2 ───────────────────────────────────────────────────────────────────
# Both keystore helper scripts exist and parse clean (bash -n). These hold the
# real backup/restore logic; if either is missing or broken the preservation
# flow silently no-ops or aborts.
chk2() {
  local root="${1:-.}"
  local rc=0 f out
  for f in vault-keystore-backup.sh vault-keystore-restore.sh; do
    local F="$root/scripts/$f"
    if ! test -f "$F"; then
      err "$F" "REGRESSION — scripts/$f is MISSING; recreate-full cannot preserve the signing key."
      rc=1
      continue
    fi
    if ! out="$(bash -n "$F" 2>&1)"; then
      err "$F" "REGRESSION — scripts/$f does not parse (bash -n failed)."
      echo "$out" | sed 's/^/       | /'
      rc=1
    fi
  done
  [ "$rc" -eq 0 ] && echo "OK: vault-keystore-backup.sh + vault-keystore-restore.sh exist and parse clean"
  return "$rc"
}

# ── Check 3 ───────────────────────────────────────────────────────────────────
# Inside recreate-full, ORDER is everything:
#   * the backup step (vault-keystore-backup.sh) must run BEFORE the teardown
#     ('k3d cluster delete') — once the cluster/PV is gone the key is too.
#   * the restore step (vault-keystore-restore.sh) must run AFTER the
#     'Re-apply the persistent Vault' step — there is no Vault to restore into
#     before it is re-applied.
chk3() {
  local root="${1:-.}"
  local F="$root/tasks.yaml"
  test -f "$F" || { err "$F" "missing — required for the recreate-full key guard"; return 1; }

  local blk
  blk="$(extract_task "$F" recreate-full)"
  if [ -z "$blk" ]; then
    err "$F" "REGRESSION — 'recreate-full' task not found in tasks.yaml."
    return 1
  fi

  local l_backup l_delete l_reapply l_restore
  l_backup="$(printf  '%s\n' "$blk" | grep -n 'vault-keystore-backup\.sh'   | head -1 | cut -d: -f1)"
  l_delete="$(printf  '%s\n' "$blk" | grep -n 'k3d cluster delete'          | head -1 | cut -d: -f1)"
  l_reapply="$(printf '%s\n' "$blk" | grep -n 'Re-apply the persistent Vault' | head -1 | cut -d: -f1)"
  l_restore="$(printf '%s\n' "$blk" | grep -n 'vault-keystore-restore\.sh'  | head -1 | cut -d: -f1)"

  if [ -z "$l_delete" ]; then
    err "$F" "REGRESSION — recreate-full has no 'k3d cluster delete' teardown action."
    return 1
  fi
  if [ -z "$l_reapply" ]; then
    err "$F" "REGRESSION — recreate-full lost the 'Re-apply the persistent Vault' step (restore anchor)."
    return 1
  fi
  if [ -z "$l_backup" ]; then
    err "$F" "REGRESSION — recreate-full no longer backs up the Vault keystore (vault-keystore-backup.sh)."
    err "$F" "Teardown will drop the Vault PV and the signing key will rotate — old receipts stop verifying."
    return 1
  fi
  if [ -z "$l_restore" ]; then
    err "$F" "REGRESSION — recreate-full no longer restores the Vault keystore (vault-keystore-restore.sh)."
    err "$F" "Without restore a fresh key is generated and old receipt signatures will not verify."
    return 1
  fi
  if [ "$l_backup" -ge "$l_delete" ]; then
    err "$F" "REGRESSION — the keystore BACKUP must run BEFORE 'k3d cluster delete' (it is at/after teardown)."
    err "$F" "Found: backup@$l_backup delete@$l_delete (within recreate-full)."
    return 1
  fi
  if [ "$l_restore" -le "$l_reapply" ]; then
    err "$F" "REGRESSION — the keystore RESTORE must run AFTER 'Re-apply the persistent Vault'."
    err "$F" "Found: re-apply@$l_reapply restore@$l_restore (within recreate-full)."
    return 1
  fi
  echo "OK: backup runs before teardown; restore runs after re-applying Vault"
}

# ── Check 4 ───────────────────────────────────────────────────────────────────
# The sentinel-aware status step is intact: the restore writes /tmp/szl-vault-
# restore.ok on success, and a later step READS it (a `[ -f ... ]` test) to tell
# the operator whether the key was preserved or a fresh re-init is needed. The
# read must come AFTER the restore step that produces the sentinel.
chk4() {
  local root="${1:-.}"
  local F="$root/tasks.yaml"
  test -f "$F" || { err "$F" "missing — required for the recreate-full key guard"; return 1; }

  local blk
  blk="$(extract_task "$F" recreate-full)"
  if [ -z "$blk" ]; then
    err "$F" "REGRESSION — 'recreate-full' task not found in tasks.yaml."
    return 1
  fi

  local l_restore l_status
  l_restore="$(printf '%s\n' "$blk" | grep -n 'vault-keystore-restore\.sh' | head -1 | cut -d: -f1)"
  # The sentinel READ is a shell file test on the sentinel path.
  l_status="$(printf '%s\n' "$blk" | grep -n '\[ -f /tmp/szl-vault-restore\.ok' | head -1 | cut -d: -f1)"

  if [ -z "$l_status" ]; then
    err "$F" "REGRESSION — recreate-full lost the sentinel-aware status step."
    err "$F" "No step reads '[ -f /tmp/szl-vault-restore.ok ]' to report whether the signing key was preserved."
    return 1
  fi
  if [ -n "$l_restore" ] && [ "$l_status" -le "$l_restore" ]; then
    err "$F" "REGRESSION — the sentinel status read must come AFTER the restore step that writes it."
    err "$F" "Found: restore@$l_restore status-read@$l_status (within recreate-full)."
    return 1
  fi
  echo "OK: sentinel-aware status step reads /tmp/szl-vault-restore.ok after restore"
}

# ── Dispatch ──────────────────────────────────────────────────────────────────
# When sourced (BASH_SOURCE != $0) define the functions and return so the
# self-test can call them directly. When executed, run the requested check.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  CHECK="${1:-all}"
  ROOT="${2:-.}"
  case "$CHECK" in
    chk1) chk1 "$ROOT" ;;
    chk2) chk2 "$ROOT" ;;
    chk3) chk3 "$ROOT" ;;
    chk4) chk4 "$ROOT" ;;
    all)
      rc=0
      chk1 "$ROOT" || rc=1
      chk2 "$ROOT" || rc=1
      chk3 "$ROOT" || rc=1
      chk4 "$ROOT" || rc=1
      exit "$rc"
      ;;
    *) echo "unknown check: $CHECK (want chk1|chk2|chk3|chk4|all)" >&2; exit 2 ;;
  esac
fi
