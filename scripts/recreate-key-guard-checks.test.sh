# Copyright 2026 SZL Holdings
# SPDX-License-Identifier: Apache-2.0
#
# recreate-key-guard-checks.test.sh — negative-fixture self-test for the
# recreate-full Vault signing-key guard (scripts/recreate-key-guard-checks.sh).
#
# WHY THIS EXISTS
# The guard enforces the signing-key preservation flow entirely with hand-written
# awk/grep. If one of those checks breaks (a regex typo, a bad anchor) it can
# PASS VACUOUSLY — green while guarding nothing. This test feeds each check a
# deliberately-BROKEN fixture and asserts the check FAILS, plus asserts the
# pristine repo PASSES. A future edit that neuters a check is caught here in CI.
#
# It sources the EXACT script the workflow runs (so chk1..chk4 are the real
# functions) and runs them against fixtures built from the real source files.
#
# Usage: bash scripts/recreate-key-guard-checks.test.sh
# Exit 0 if every case behaves as expected, 1 otherwise.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
CHECKS="$HERE/recreate-key-guard-checks.sh"

# shellcheck source=/dev/null
source "$CHECKS"

PASS=0
FAIL=0
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

# Source files the guard inspects, relative to a repo root.
SRC_FILES=(
  "tasks.yaml"
  "scripts/vault-keystore-backup.sh"
  "scripts/vault-keystore-restore.sh"
)

# new_fixture — build a fresh fixture tree (a faithful copy of the real source
# files) under a unique dir and echo its path.
new_fixture() {
  local dir
  dir="$(mktemp -d "$TMPROOT/fixture.XXXXXX")"
  local f
  for f in "${SRC_FILES[@]}"; do
    mkdir -p "$dir/$(dirname "$f")"
    cp "$REPO_ROOT/$f" "$dir/$f"
  done
  echo "$dir"
}

# expect_pass CHECK ROOT NAME — assert CHECK returns 0 on ROOT.
expect_pass() {
  local check="$1" root="$2" name="$3" out rc
  out="$("$check" "$root" 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ]; then
    echo "ok   PASS-expected: $name"
    PASS=$((PASS+1))
  else
    echo "FAIL PASS-expected but $check exited $rc: $name"
    echo "$out" | sed 's/^/       | /'
    FAIL=$((FAIL+1))
  fi
}

# expect_fail CHECK ROOT NAME — assert CHECK returns non-zero on ROOT.
expect_fail() {
  local check="$1" root="$2" name="$3" out rc
  out="$("$check" "$root" 2>&1)"; rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "ok   FAIL-expected: $name"
    PASS=$((PASS+1))
  else
    echo "FAIL FAIL-expected but $check exited 0: $name"
    echo "$out" | sed 's/^/       | /'
    FAIL=$((FAIL+1))
  fi
}

echo "== pristine repo: every check passes =="
expect_pass chk1 "$REPO_ROOT" "chk1 vars present + wired into recreate-full"
expect_pass chk2 "$REPO_ROOT" "chk2 keystore scripts exist + parse"
expect_pass chk3 "$REPO_ROOT" "chk3 backup before teardown, restore after re-apply"
expect_pass chk4 "$REPO_ROOT" "chk4 sentinel-aware status step present"

echo "== chk1 negatives =="
d="$(new_fixture)"; sed -i '/^  - name: PRESERVE_SIGNING_KEY$/d' "$d/tasks.yaml"
expect_fail chk1 "$d" "chk1 fails when PRESERVE_SIGNING_KEY variable is removed"

d="$(new_fixture)"; sed -i '/^  - name: VAULT_KEYSTORE_BACKUP_DIR$/d' "$d/tasks.yaml"
expect_fail chk1 "$d" "chk1 fails when VAULT_KEYSTORE_BACKUP_DIR variable is removed"

# Variable still declared at top, but every reference inside recreate-full is
# stripped (the flow is disconnected from the task).
d="$(new_fixture)"
awk '
  /^  - name: recreate-full$/ { inblk=1 }
  inblk && /^  - name: / && !/^  - name: recreate-full$/ { inblk=0 }
  inblk { gsub(/PRESERVE_SIGNING_KEY/, "DISABLED_FLAG") }
  { print }
' "$REPO_ROOT/tasks.yaml" > "$d/tasks.yaml"
expect_fail chk1 "$d" "chk1 fails when recreate-full stops referencing PRESERVE_SIGNING_KEY"

echo "== chk2 negatives =="
d="$(new_fixture)"; rm -f "$d/scripts/vault-keystore-backup.sh"
expect_fail chk2 "$d" "chk2 fails when vault-keystore-backup.sh is missing"

d="$(new_fixture)"; rm -f "$d/scripts/vault-keystore-restore.sh"
expect_fail chk2 "$d" "chk2 fails when vault-keystore-restore.sh is missing"

d="$(new_fixture)"; printf 'if [ \n' > "$d/scripts/vault-keystore-restore.sh"
expect_fail chk2 "$d" "chk2 fails when a keystore script has a syntax error"

echo "== chk3 negatives =="
# Drop the backup step (rename its script reference everywhere).
d="$(new_fixture)"; sed -i 's#vault-keystore-backup\.sh#vault-keystore-DISABLED.sh#g' "$d/tasks.yaml"
expect_fail chk3 "$d" "chk3 fails when recreate-full drops the backup call"

# Drop the restore step.
d="$(new_fixture)"; sed -i 's#vault-keystore-restore\.sh#vault-keystore-DISABLED.sh#g' "$d/tasks.yaml"
expect_fail chk3 "$d" "chk3 fails when recreate-full drops the restore call"

# Synthetic recreate-full where the backup runs AFTER teardown (wrong order).
d="$(new_fixture)"
cat > "$d/tasks.yaml" <<'YAML'
variables:
  - name: PRESERVE_SIGNING_KEY
    default: "true"
  - name: VAULT_KEYSTORE_BACKUP_DIR
    default: "/root/vault-keystore-backup"
tasks:
  - name: recreate-full
    actions:
      - description: "Tear down the existing cluster"
        cmd: |
          k3d cluster delete "${CLUSTER_NAME}"
      - description: "Back up too late (WRONG ORDER)"
        cmd: |
          bash scripts/vault-keystore-backup.sh
      - description: "Re-apply the persistent Vault"
        cmd: |
          kubectl apply -f k8s/vault/vault-persistent.yaml
      - description: "Restore"
        cmd: |
          bash scripts/vault-keystore-restore.sh
  - name: next-task
    actions:
      - cmd: true
YAML
expect_fail chk3 "$d" "chk3 fails when backup runs after teardown"

# Synthetic recreate-full where the restore runs BEFORE re-applying Vault.
d="$(new_fixture)"
cat > "$d/tasks.yaml" <<'YAML'
variables:
  - name: PRESERVE_SIGNING_KEY
    default: "true"
  - name: VAULT_KEYSTORE_BACKUP_DIR
    default: "/root/vault-keystore-backup"
tasks:
  - name: recreate-full
    actions:
      - description: "Back up"
        cmd: |
          bash scripts/vault-keystore-backup.sh
      - description: "Tear down the existing cluster"
        cmd: |
          k3d cluster delete "${CLUSTER_NAME}"
      - description: "Restore too early (WRONG ORDER)"
        cmd: |
          bash scripts/vault-keystore-restore.sh
      - description: "Re-apply the persistent Vault"
        cmd: |
          kubectl apply -f k8s/vault/vault-persistent.yaml
  - name: next-task
    actions:
      - cmd: true
YAML
expect_fail chk3 "$d" "chk3 fails when restore runs before re-applying Vault"

echo "== chk4 negatives =="
# Strip the sentinel READ (the [ -f ... ] test) but leave the rm -f write.
d="$(new_fixture)"; sed -i 's#\[ -f /tmp/szl-vault-restore\.ok#[ -f /tmp/DISABLED-sentinel#' "$d/tasks.yaml"
expect_fail chk4 "$d" "chk4 fails when the sentinel-aware status read is removed"

# Synthetic recreate-full where the sentinel read runs BEFORE the restore.
d="$(new_fixture)"
cat > "$d/tasks.yaml" <<'YAML'
variables:
  - name: PRESERVE_SIGNING_KEY
    default: "true"
tasks:
  - name: recreate-full
    actions:
      - description: "Status read too early (WRONG ORDER)"
        cmd: |
          if [ -f /tmp/szl-vault-restore.ok ]; then echo preserved; fi
      - description: "Restore"
        cmd: |
          bash scripts/vault-keystore-restore.sh
  - name: next-task
    actions:
      - cmd: true
YAML
expect_fail chk4 "$d" "chk4 fails when the sentinel read precedes the restore"

echo ""
echo "==================================================================="
echo "recreate-key-guard self-test: $PASS passed, $FAIL failed"
echo "==================================================================="
[ "$FAIL" -eq 0 ]
