# Copyright 2026 SZL Holdings
# SPDX-License-Identifier: Apache-2.0
#
# relay-watch-guard.test.sh — negative-fixture self-test for the
# szl-alert-relay-watch e2e guard (scripts/relay-watch-guard.sh).
#
# WHY THIS EXISTS
# The guard drives the REAL alert-relay watcher end-to-end and asserts it pages on
# the down edge, de-dups a persisting outage, pages RECOVERED when the relay comes
# back AND clears its signature, and pages on a crashed systemd unit. If one of
# those assertions were silently broken the guard could PASS VACUOUSLY — green
# while proving nothing. This test applies deliberate REGRESSIONS to a copy of the
# real watcher (neuter the pager / defeat de-dup / drop RECOVERED / never clear the
# signature) and asserts the guard FAILS on each, plus asserts the pristine script
# PASSES.
#
# Usage: bash scripts/relay-watch-guard.test.sh
# Exit 0 if every case behaves as expected, 1 otherwise.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
GUARD="$HERE/relay-watch-guard.sh"
REAL="$REPO_ROOT/box-scripts/sbin/szl-alert-relay-watch"

PASS=0; FAIL=0
TMPROOT="$(mktemp -d)"; trap 'rm -rf "$TMPROOT"' EXIT

broken_copy() {
  local expr="$1" f
  f="$(mktemp "$TMPROOT/relay-watch.XXXXXX")"
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
expect_pass "$REAL" "pristine szl-alert-relay-watch"

echo "== regression: push() neutered -> never pages on the down edge =="
b="$(broken_copy 's/^push() {/push() { return 0 # BROKEN/')" \
  && expect_fail "$b" "guard catches a watcher that never pages on the down edge"

echo "== regression: de-dup compare defeated -> re-pages every cycle =="
b="$(broken_copy 's/if \[ "\$cur_sig" = "\$prev_sig" \]; then/if false; then # BROKEN/')" \
  && expect_fail "$b" "guard catches a watcher that re-pages on a persisting outage"

echo "== regression: RECOVERED push dropped -> no recovery notice =="
b="$(broken_copy '/push "a11oy.net alert-relay RECOVERED:/d')" \
  && expect_fail "$b" "guard catches a watcher that never pages RECOVERED"

echo "== regression: signature never cleared on recovery -> recovery re-pages =="
b="$(broken_copy '/rm -f "\$SIG_FILE"/d')" \
  && expect_fail "$b" "guard catches a watcher that never clears the signature on recovery"

echo "== regression: systemd unit probe ignored -> a dead relay unit unpaged =="
b="$(broken_copy 's/unit_ok=0/unit_ok=1 # BROKEN/')" \
  && expect_fail "$b" "guard catches a watcher that never flags a dead relay unit"

echo ""
echo "==================================================================="
echo "relay-watch-guard self-test: $PASS passed, $FAIL failed"
echo "==================================================================="
[ "$FAIL" -eq 0 ]
