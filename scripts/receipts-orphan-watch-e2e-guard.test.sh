# Copyright 2026 SZL Holdings
# SPDX-License-Identifier: Apache-2.0
#
# receipts-orphan-watch-e2e-guard.test.sh — negative-fixture self-test for the
# szl-receipts-orphan-watch e2e guard (scripts/receipts-orphan-watch-e2e-guard.sh).
#
# WHY THIS EXISTS
# The guard drives the REAL edge-alert watcher end-to-end and asserts it pages on
# the orphan edge, de-dups a persisting orphan, pages RECOVERED when it clears,
# and stays fail-safe (UNKNOWN, no page) when ownership can't be determined. If
# one of those assertions were silently broken the guard could PASS VACUOUSLY —
# green while proving nothing. This test applies deliberate REGRESSIONS to a copy
# of the real watcher (neuter notify / defeat de-dup / drop RECOVERED / drop the
# fail-safe) and asserts the guard FAILS on each, plus asserts the pristine
# script PASSES.
#
# Usage: bash scripts/receipts-orphan-watch-e2e-guard.test.sh
# Exit 0 if every case behaves as expected, 1 otherwise.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
GUARD="$HERE/receipts-orphan-watch-e2e-guard.sh"
REAL="$REPO_ROOT/box-scripts/sbin/szl-receipts-orphan-watch"

PASS=0; FAIL=0
TMPROOT="$(mktemp -d)"; trap 'rm -rf "$TMPROOT"' EXIT

broken_copy() {
  local expr="$1" f
  f="$(mktemp "$TMPROOT/orphan-watch.XXXXXX")"
  cp "$REAL" "$f"
  sed -i "$expr" "$f"
  if ! bash -n "$f" 2>/dev/null; then
    echo "FATAL mutation produced invalid bash: $expr" >&2
    return 1
  fi
  echo "$f"
}

expect_pass() {
  local script="$1" name="$2" rc
  bash "$GUARD" "$script" >/dev/null 2>&1; rc=$?
  if [ "$rc" -eq 0 ]; then echo "ok   PASS-expected: $name"; PASS=$((PASS+1))
  else echo "FAIL PASS-expected but guard exited $rc: $name"; FAIL=$((FAIL+1)); fi
}

expect_fail() {
  local script="$1" name="$2" rc
  bash "$GUARD" "$script" >/dev/null 2>&1; rc=$?
  if [ "$rc" -ne 0 ]; then echo "ok   FAIL-expected: $name"; PASS=$((PASS+1))
  else echo "FAIL FAIL-expected but guard exited 0: $name"; FAIL=$((FAIL+1)); fi
}

echo "== pristine watcher: the guard passes =="
expect_pass "$REAL" "pristine szl-receipts-orphan-watch"

echo "== regression: notify() neutered -> no orphan alert ever =="
b="$(broken_copy 's/^notify() {/notify() { return 0 # BROKEN/')" \
  && expect_fail "$b" "guard catches a watcher that never pages on the orphan edge"

echo "== regression: prev pinned to OK -> de-dup defeated, re-pages every cycle =="
b="$(broken_copy 's/^prev=.*/prev=OK/')" \
  && expect_fail "$b" "guard catches a watcher that re-pages on a persisting orphan"

echo "== regression: RECOVERED push dropped -> no recovery notice =="
b="$(broken_copy '/notify "RECOVERED:/d')" \
  && expect_fail "$b" "guard catches a watcher that never pages RECOVERED"

echo "== regression: fail-safe degraded path defeated -> probe error mis-handled =="
b="$(broken_copy 's/degraded=1/degraded=0/g')" \
  && expect_fail "$b" "guard catches a watcher that drops UNKNOWN on a probe error"

echo ""
echo "==================================================================="
echo "receipts-orphan-watch-e2e-guard self-test: $PASS passed, $FAIL failed"
echo "==================================================================="
[ "$FAIL" -eq 0 ]
