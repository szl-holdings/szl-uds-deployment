# Copyright 2026 SZL Holdings
# SPDX-License-Identifier: Apache-2.0
#
# prove-organs-guard-checks.test.sh — negative-fixture self-test for the
# prove-organs trigger guard (scripts/prove-organs-guard-checks.sh).
#
# WHY THIS EXISTS
# The guard enforces the automatic-release-proof triggers entirely with
# hand-written awk/grep over .github/workflows/prove-organs.yaml. If one of those
# checks breaks (a regex typo, a bad anchor) it can PASS VACUOUSLY — green while
# guarding nothing. This test feeds each check a deliberately-BROKEN fixture and
# asserts the check FAILS, plus asserts the pristine repo PASSES. A future edit
# that neuters a check is caught here in CI.
#
# It sources the EXACT script the workflow runs (so chk1..chk5 are the real
# functions) and runs them against fixtures built from the real source file.
#
# Usage: bash scripts/prove-organs-guard-checks.test.sh
# Exit 0 if every case behaves as expected, 1 otherwise.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
CHECKS="$HERE/prove-organs-guard-checks.sh"

# shellcheck source=/dev/null
source "$CHECKS"

PASS=0
FAIL=0
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

# Source files the guard inspects, relative to a repo root.
SRC_FILES=(
  ".github/workflows/prove-organs.yaml"
)
WF=".github/workflows/prove-organs.yaml"

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
expect_pass chk1 "$REPO_ROOT" "chk1 push tags v*/uds-v* present"
expect_pass chk2 "$REPO_ROOT" "chk2 schedule cron present"
expect_pass chk3 "$REPO_ROOT" "chk3 alert job present"
expect_pass chk4 "$REPO_ROOT" "chk4 alert if-condition intact"
expect_pass chk5 "$REPO_ROOT" "chk5 teardown always() present"

echo "== chk1 negatives =="
d="$(new_fixture)"; sed -i '/^[[:space:]]*- "uds-v\*"/d' "$d/$WF"
expect_fail chk1 "$d" "chk1 fails when the uds-v* tag pattern is removed"

d="$(new_fixture)"; sed -i '/^[[:space:]]*- "v\*"/d' "$d/$WF"
expect_fail chk1 "$d" "chk1 fails when the v* tag pattern is removed"

# Drop the whole push: trigger.
d="$(new_fixture)"
awk '
  /^  push:/ { inp=1; next }
  inp && /^  [^[:space:]]/ { inp=0 }
  inp { next }
  { print }
' "$REPO_ROOT/$WF" > "$d/$WF"
expect_fail chk1 "$d" "chk1 fails when the push: trigger is removed entirely"

echo "== chk2 negatives =="
d="$(new_fixture)"; sed -i '/^[[:space:]]*- cron:/d' "$d/$WF"
expect_fail chk2 "$d" "chk2 fails when the cron entry is removed"

# Drop the whole schedule: trigger.
d="$(new_fixture)"
awk '
  /^  schedule:/ { ins=1; next }
  ins && /^  [^[:space:]]/ { ins=0 }
  ins && /^[^[:space:]]/ { ins=0 }
  ins { next }
  { print }
' "$REPO_ROOT/$WF" > "$d/$WF"
expect_fail chk2 "$d" "chk2 fails when the schedule: trigger is removed entirely"

echo "== chk3 negatives =="
# Remove the alert job (it is the last job — drop from `  alert:` to EOF).
d="$(new_fixture)"
awk '
  /^  alert:/ { ina=1 }
  ina { next }
  { print }
' "$REPO_ROOT/$WF" > "$d/$WF"
expect_fail chk3 "$d" "chk3 fails when the alert job is removed"

echo "== chk4 negatives =="
d="$(new_fixture)"
sed -i "s/failure() && github.event_name != 'workflow_dispatch'/failure()/" "$d/$WF"
expect_fail chk4 "$d" "chk4 fails when the workflow_dispatch exclusion is dropped"

d="$(new_fixture)"
sed -i "s/failure() && //" "$d/$WF"
expect_fail chk4 "$d" "chk4 fails when the failure() gate is dropped"

echo "== chk5 negatives =="
# Only the teardown step uses always(); flip it to failure().
d="$(new_fixture)"; sed -i 's/if: always()/if: failure()/' "$d/$WF"
expect_fail chk5 "$d" "chk5 fails when teardown no longer runs with always()"

# Remove the teardown if: line entirely.
d="$(new_fixture)"; sed -i '/^[[:space:]]*if: always()/d' "$d/$WF"
expect_fail chk5 "$d" "chk5 fails when the teardown if: always() line is removed"

# Remove the whole teardown step.
d="$(new_fixture)"
awk '
  /^[[:space:]]*- name: Teardown throwaway cluster[[:space:]]*$/ { ins=1; next }
  ins && /^[[:space:]]*- / { ins=0 }
  ins && /^  [^[:space:]]/ { ins=0 }
  ins && /^[^[:space:]]/ { ins=0 }
  ins { next }
  { print }
' "$REPO_ROOT/$WF" > "$d/$WF"
expect_fail chk5 "$d" "chk5 fails when the teardown step is removed entirely"

echo ""
echo "==================================================================="
echo "prove-organs-guard self-test: $PASS passed, $FAIL failed"
echo "==================================================================="
[ "$FAIL" -eq 0 ]
