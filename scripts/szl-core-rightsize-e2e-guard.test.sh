# Copyright 2026 SZL Holdings
# SPDX-License-Identifier: Apache-2.0
#
# szl-core-rightsize-e2e-guard.test.sh — negative-fixture self-test for the
# szl-core-rightsize e2e guard (scripts/szl-core-rightsize-e2e-guard.sh).
#
# WHY THIS EXISTS
# The guard drives the REAL self-heal watcher end-to-end and asserts it patches a
# drifted target, no-ops on a conformant one, and skips an absent one. If one of
# those assertions were silently broken the guard could PASS VACUOUSLY — green
# while proving nothing. This test applies deliberate REGRESSIONS to a copy of
# the real szl-core-rightsize (never patch on drift / always patch even when
# conformant / patch an absent target) and asserts the guard FAILS on each, plus
# asserts the pristine script PASSES. A future edit that neuters one of the
# guard's assertions is therefore caught here in CI.
#
# Usage: bash scripts/szl-core-rightsize-e2e-guard.test.sh
# Exit 0 if every case behaves as expected, 1 otherwise.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
GUARD="$HERE/szl-core-rightsize-e2e-guard.sh"
REAL="$REPO_ROOT/box-scripts/sbin/szl-core-rightsize"

PASS=0; FAIL=0
TMPROOT="$(mktemp -d)"; trap 'rm -rf "$TMPROOT"' EXIT

# broken_copy "sed expr" -> path to a copy of REAL with the regression applied.
# The copy must still parse (bash -n) or the mutation was a typo, not a fixture.
broken_copy() {
  local expr="$1" f
  f="$(mktemp "$TMPROOT/core-rightsize.XXXXXX")"
  cp "$REAL" "$f"
  sed -i "$expr" "$f"
  if ! bash -n "$f" 2>/dev/null; then
    echo "FATAL mutation produced invalid bash: $expr" >&2
    return 1
  fi
  echo "$f"
}

expect_pass() {  # script name
  local script="$1" name="$2" rc
  bash "$GUARD" "$script" >/dev/null 2>&1; rc=$?
  if [ "$rc" -eq 0 ]; then echo "ok   PASS-expected: $name"; PASS=$((PASS+1))
  else echo "FAIL PASS-expected but guard exited $rc: $name"; FAIL=$((FAIL+1)); fi
}

expect_fail() {  # script name
  local script="$1" name="$2" rc
  bash "$GUARD" "$script" >/dev/null 2>&1; rc=$?
  if [ "$rc" -ne 0 ]; then echo "ok   FAIL-expected: $name"; PASS=$((PASS+1))
  else echo "FAIL FAIL-expected but guard exited 0: $name"; FAIL=$((FAIL+1)); fi
}

echo "== pristine watcher: the guard passes =="
expect_pass "$REAL" "pristine szl-core-rightsize"

echo "== regression: kubectl patch downgraded to a get -> drift never repaired =="
b="$(broken_copy 's/patch deploy/get deploy/g')" \
  && expect_fail "$b" "guard catches a watcher that never patches a drifted target"

echo "== regression: reps_ok never set -> every target patched, even conformant =="
b="$(broken_copy 's/&& reps_ok=1/\&\& reps_ok=0/')" \
  && expect_fail "$b" "guard catches a watcher that patches an already-conformant target"

echo "== regression: absent-target skip defeated -> an absent target gets patched =="
b="$(broken_copy 's/|| continue/|| true/')" \
  && expect_fail "$b" "guard catches a watcher that patches a non-existent target"

echo ""
echo "==================================================================="
echo "szl-core-rightsize-e2e-guard self-test: $PASS passed, $FAIL failed"
echo "==================================================================="
[ "$FAIL" -eq 0 ]
