# Copyright 2026 SZL Holdings
# SPDX-License-Identifier: Apache-2.0
#
# box-scripts-drift-check-guard.test.sh — negative-fixture self-test for the
# box-scripts-drift-check guard (scripts/box-scripts-drift-check-guard.sh).
#
# WHY THIS EXISTS
# The guard drives the REAL watcher end-to-end and asserts its detection-only
# and SELF_HEAL=1 behaviour. If one of those assertions were silently broken it
# could PASS VACUOUSLY — green while proving nothing. This test takes the real
# box-scripts-drift-check, applies a series of deliberate REGRESSIONS to a copy
# (neuter push, drop self-heal, kill de-dup, drop RECOVERED), and asserts the
# guard FAILS on each — plus asserts the pristine script PASSES. A future edit
# that neuters one of the guard's assertions is therefore caught here in CI.
#
# Usage: bash scripts/box-scripts-drift-check-guard.test.sh
# Exit 0 if every case behaves as expected, 1 otherwise.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
GUARD="$HERE/box-scripts-drift-check-guard.sh"
REAL="$REPO_ROOT/box-scripts/sbin/box-scripts-drift-check"

PASS=0
FAIL=0
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

# broken_copy "sed expr" -> echo path to a copy of the real script with the
# regression applied. The copy must still parse (bash -n) or the mutation was
# a typo, not a meaningful negative fixture.
broken_copy() {
  local expr="$1" f
  f="$(mktemp "$TMPROOT/drift-check.XXXXXX")"
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
expect_pass "$REAL" "pristine box-scripts-drift-check"

echo "== regression: push() neutered -> no DRIFT alert ever =="
b="$(broken_copy 's/^push() {/push() { return 0 # BROKEN/')" \
  && expect_fail "$b" "guard catches a watcher that never pushes an alert"

echo "== regression: self-heal call removed -> no REPAIRED, host not restored =="
b="$(broken_copy 's/  attempt_heal || true/  : # BROKEN no heal/')" \
  && expect_fail "$b" "guard catches self-heal that never repairs"

echo "== regression: de-dup defeated -> persisting drift re-pushes every cycle =="
b="$(broken_copy 's/^prev_sig="".*/prev_sig=""/')" \
  && expect_fail "$b" "guard catches a watcher that re-alerts on persisting drift"

echo "== regression: RECOVERED push dropped -> no recovery notice =="
b="$(broken_copy '/push "box-scripts-drift RECOVERED:/d')" \
  && expect_fail "$b" "guard catches a watcher that never pushes RECOVERED"

echo ""
echo "==================================================================="
echo "box-scripts-drift-check-guard self-test: $PASS passed, $FAIL failed"
echo "==================================================================="
[ "$FAIL" -eq 0 ]
