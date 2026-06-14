#!/usr/bin/env bash
# Copyright 2026 SZL Holdings
# SPDX-License-Identifier: Apache-2.0
#
# a11oy-readiness-watch-guard.test.sh — negative-fixture self-test for the
# a11oy-readiness-watch guard (scripts/a11oy-readiness-watch-guard.sh).
#
# WHY THIS EXISTS
# The guard drives the REAL watcher end-to-end and asserts its alert / de-dup /
# RECOVERED / grace-window / cluster-down-no-op behaviour. If one of those
# assertions were silently broken the guard could PASS VACUOUSLY — green while
# proving nothing. This test takes the real a11oy-readiness-watch, applies a
# series of deliberate REGRESSIONS to a copy (neuter push, defeat de-dup, drop
# RECOVERED, drop the grace window, drop the cluster-down no-op), and asserts the
# guard FAILS on each — plus asserts the pristine watcher PASSES. A future edit
# that neuters one of the guard's assertions is therefore caught here in CI.
#
# Usage: bash scripts/a11oy-readiness-watch-guard.test.sh
# Exit 0 if every case behaves as expected, 1 otherwise.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
GUARD="$HERE/a11oy-readiness-watch-guard.sh"
REAL="$REPO_ROOT/box-scripts/sbin/a11oy-readiness-watch"

PASS=0
FAIL=0
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

# broken_copy "sed expr" -> path to a copy of the real watcher with the
# regression applied. The copy must still parse (bash -n) or the mutation was a
# typo, not a meaningful negative fixture.
broken_copy() {
  local expr="$1" f
  f="$(mktemp "$TMPROOT/watch.XXXXXX")"
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
expect_pass "$REAL" "pristine a11oy-readiness-watch"

echo "== regression: push() neutered -> no ALERT ever =="
b="$(broken_copy 's/^push() {/push() { return 0 # BROKEN/')" \
  && expect_fail "$b" "guard catches a watcher that never pushes an alert"

echo "== regression: de-dup defeated -> persisting failure re-pages every cycle =="
b="$(broken_copy 's/^prev_sig="".*/prev_sig=""/')" \
  && expect_fail "$b" "guard catches a watcher that re-alerts on persisting failure"

echo "== regression: RECOVERED push dropped -> no recovery notice =="
b="$(broken_copy '/a11oy Operational Readiness RECOVERED on/d')" \
  && expect_fail "$b" "guard catches a watcher that never pushes RECOVERED"

echo "== regression: grace window removed -> a fresh failure pages immediately =="
b="$(broken_copy 's/if \[ "\$elapsed" -lt "\$THRESHOLD_SECS" \]; then/if false; then/')" \
  && expect_fail "$b" "guard catches a watcher that ignores the grace window"

echo "== regression: cluster-down no-op removed -> false page when cluster is down =="
b="$(broken_copy 's/if \[ "\$rc" -eq 99 \]; then/if false; then/')" \
  && expect_fail "$b" "guard catches a watcher that pages on a cluster-down no-op"

echo ""
echo "==================================================================="
echo "a11oy-readiness-watch-guard self-test: $PASS passed, $FAIL failed"
echo "==================================================================="
[ "$FAIL" -eq 0 ]
