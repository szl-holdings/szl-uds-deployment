# Copyright 2026 SZL Holdings
# SPDX-License-Identifier: Apache-2.0
#
# test-upgrade-guard-checks.test.sh — negative-fixture self-test for the
# test-upgrade guard (scripts/test-upgrade-guard-checks.sh).
#
# WHY THIS EXISTS
# The guard enforces the test-upgrade honesty invariants entirely with
# hand-written awk/grep. If one of those checks breaks (a regex typo, a bad
# anchor) it can PASS VACUOUSLY — green while guarding nothing. This test feeds
# each check a deliberately-BROKEN fixture and asserts the check FAILS, plus
# asserts the pristine repo PASSES. A future edit that neuters a check is caught
# here in CI.
#
# It sources the EXACT script the workflow runs (so chk1/chk2 are the real
# functions) and runs them against fixtures built from the real tasks.yaml.
#
# Usage: bash scripts/test-upgrade-guard-checks.test.sh
# Exit 0 if every case behaves as expected, 1 otherwise.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
CHECKS="$HERE/test-upgrade-guard-checks.sh"

# shellcheck source=/dev/null
source "$CHECKS"

PASS=0
FAIL=0
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

# Source files the guard inspects, relative to a repo root.
SRC_FILES=(
  "tasks.yaml"
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
expect_pass chk1 "$REPO_ROOT" "chk1 baseline deploy present + fatal"
expect_pass chk2 "$REPO_ROOT" "chk2 post-upgrade >=2 helm-revision assertion present"

echo "== chk1 negatives =="
# Re-introduce the exact Task #484 anti-pattern: a non-fatal `|| echo ... skipping`
# fallback on the baseline deploy.
d="$(new_fixture)"
sed -i 's#\(zarf package deploy "\${UPGRADE_BASELINE_REF}" --confirm\)#\1 || echo "WARN: baseline tag absent; skipping"#' "$d/tasks.yaml"
expect_fail chk1 "$d" "chk1 fails when the baseline deploy has a || echo skip fallback"

# A `2>/dev/null || true` form of the same non-fatal escape.
d="$(new_fixture)"
sed -i 's#\(zarf package deploy "\${UPGRADE_BASELINE_REF}" --confirm\)#\1 2>/dev/null || true#' "$d/tasks.yaml"
expect_fail chk1 "$d" "chk1 fails when the baseline deploy is swallowed by 2>/dev/null || true"

# The baseline deploy step removed entirely (so the next deploy is a fresh
# install, not an upgrade).
d="$(new_fixture)"
awk '
  /^      - description: "Deploy the published baseline release/ { drop=1; next }
  drop && /^      - description:/ { drop=0 }
  drop { next }
  { print }
' "$REPO_ROOT/tasks.yaml" > "$d/tasks.yaml"
expect_fail chk1 "$d" "chk1 fails when the baseline deploy step is removed"

# Whole test-upgrade task gone.
d="$(new_fixture)"
awk '
  /^  - name: test-upgrade$/ { inblk=1; next }
  inblk && /^  - name: / { inblk=0 }
  inblk { next }
  { print }
' "$REPO_ROOT/tasks.yaml" > "$d/tasks.yaml"
expect_fail chk1 "$d" "chk1 fails when the test-upgrade task is gone"

echo "== chk2 negatives =="
# Weaken the helm-revision assertion from >=2 to >=1 (a fresh install would pass).
d="$(new_fixture)"
sed -i 's/-lt 2/-lt 1/g' "$d/tasks.yaml"
expect_fail chk2 "$d" "chk2 fails when the >=2 assertion is weakened to >=1"

# Synthetic test-upgrade task whose proof step keeps the -lt 2 threshold but
# counts the WRONG label (no owner=helm,name=szl-receipts) — proves nothing.
d="$(new_fixture)"
awk '
  /^  - name: test-upgrade$/ { inblk=1; print; print_synth(); next }
  inblk && /^  - name: / { inblk=0 }
  inblk { next }
  { print }
  function print_synth() {
    print "    description: \"synthetic\""
    print "    actions:"
    print "      - description: \"Prove upgrade\""
    print "        cmd: |"
    print "          REVS=$(zarf tools kubectl get secret -n szl-receipts -l app=other -o name | grep -c .)"
    print "          if [ \"${REVS}\" -lt 2 ]; then exit 1; fi"
  }
' "$REPO_ROOT/tasks.yaml" > "$d/tasks.yaml"
expect_fail chk2 "$d" "chk2 fails when the >=2 check counts the wrong label"

# Synthetic proof step that keeps the label + threshold but only WARNS instead of
# failing the task (no exit 1 / ::error).
d="$(new_fixture)"
awk '
  /^  - name: test-upgrade$/ { inblk=1; print; print_synth(); next }
  inblk && /^  - name: / { inblk=0 }
  inblk { next }
  { print }
  function print_synth() {
    print "    description: \"synthetic\""
    print "    actions:"
    print "      - description: \"Prove upgrade\""
    print "        cmd: |"
    print "          REVS=$(zarf tools kubectl get secret -n szl-receipts -l owner=helm,name=szl-receipts -o name | grep -c .)"
    print "          if [ \"${REVS}\" -lt 2 ]; then echo WARN only; fi"
  }
' "$REPO_ROOT/tasks.yaml" > "$d/tasks.yaml"
expect_fail chk2 "$d" "chk2 fails when the >=2 check only warns instead of failing"

echo
echo "== summary: $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
