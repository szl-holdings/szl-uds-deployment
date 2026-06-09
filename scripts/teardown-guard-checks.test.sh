# Copyright 2026 SZL Holdings
# SPDX-License-Identifier: Apache-2.0
#
# teardown-guard-checks.test.sh — negative-fixture self-test for the teardown
# guard (scripts/teardown-guard-checks.sh).
#
# WHY THIS EXISTS
# The guard enforces the teardown safety net entirely with hand-written
# awk/grep. If one of those checks breaks (a regex typo, a bad anchor) it can
# PASS VACUOUSLY — green while guarding nothing. This test feeds each check a
# deliberately-BROKEN fixture and asserts the check FAILS, plus asserts the
# pristine repo PASSES. A future edit that neuters a check is caught here in CI.
#
# It sources the EXACT script the workflow runs (so chk1..chk3 are the real
# functions) and runs them against fixtures built from the real source files.
#
# Usage: bash scripts/teardown-guard-checks.test.sh
# Exit 0 if every case behaves as expected, 1 otherwise.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
CHECKS="$HERE/teardown-guard-checks.sh"

# shellcheck source=/dev/null
source "$CHECKS"

PASS=0
FAIL=0
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

# Source files the guard inspects, relative to a repo root.
SRC_FILES=(
  "tasks.yaml"
  "scripts/idle-check.sh"
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
expect_pass chk1 "$REPO_ROOT" "chk1 idle-check.sh present + parses"
expect_pass chk2 "$REPO_ROOT" "chk2 teardown gates before delete"
expect_pass chk3 "$REPO_ROOT" "chk3 idle-check task + vars present"

echo "== chk1 negatives =="
d="$(new_fixture)"; rm -f "$d/scripts/idle-check.sh"
expect_fail chk1 "$d" "chk1 fails when idle-check.sh is missing"

d="$(new_fixture)"; printf 'if [ \n' > "$d/scripts/idle-check.sh"
expect_fail chk1 "$d" "chk1 fails when idle-check.sh has a syntax error"

echo "== chk2 negatives =="
# Drop the idle-check.sh invocation from the teardown gate (simulated by renaming
# the helper reference everywhere) -> teardown no longer calls the gate.
d="$(new_fixture)"; sed -i 's#idle-check\.sh#idle-DISABLED.sh#g' "$d/tasks.yaml"
expect_fail chk2 "$d" "chk2 fails when teardown drops the idle-check.sh call"

# Synthetic tasks.yaml where 'k3d cluster delete' runs BEFORE the safety gate.
d="$(new_fixture)"
cat > "$d/tasks.yaml" <<'YAML'
variables:
  - name: FORCE
    default: "false"
  - name: IDLE_WINDOW_MINUTES
    default: "10"
tasks:
  - name: idle-check
    actions:
      - cmd: sh ./scripts/idle-check.sh
  - name: teardown
    actions:
      - description: "Delete first (WRONG ORDER)"
        cmd: |
          k3d cluster delete "${CLUSTER_NAME}"
      - description: "Gate runs too late"
        cmd: |
          if [ "${FORCE}" != "true" ]; then sh ./scripts/idle-check.sh; fi
  - name: next-task
    actions:
      - cmd: true
YAML
expect_fail chk2 "$d" "chk2 fails when k3d cluster delete precedes the gate"

# Teardown task removed entirely.
d="$(new_fixture)"
awk '
  /^  - name: teardown$/ { inblk=1; next }
  inblk && /^  - name: / { inblk=0 }
  inblk { next }
  { print }
' "$REPO_ROOT/tasks.yaml" > "$d/tasks.yaml"
expect_fail chk2 "$d" "chk2 fails when the teardown task is gone"

echo "== chk3 negatives =="
d="$(new_fixture)"; sed -i '/^  - name: FORCE$/d' "$d/tasks.yaml"
expect_fail chk3 "$d" "chk3 fails when FORCE variable is removed"

d="$(new_fixture)"; sed -i '/^  - name: IDLE_WINDOW_MINUTES$/d' "$d/tasks.yaml"
expect_fail chk3 "$d" "chk3 fails when IDLE_WINDOW_MINUTES variable is removed"

d="$(new_fixture)"; sed -i 's/^  - name: idle-check$/  - name: idlecheck-renamed/' "$d/tasks.yaml"
expect_fail chk3 "$d" "chk3 fails when the idle-check task is renamed away"

echo ""
echo "==================================================================="
echo "teardown-guard self-test: $PASS passed, $FAIL failed"
echo "==================================================================="
[ "$FAIL" -eq 0 ]
