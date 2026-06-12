# Copyright 2026 SZL Holdings
# SPDX-License-Identifier: Apache-2.0
#
# istiod-fit-strategy-e2e-guard.test.sh — negative-fixture self-test for the
# istiod-fit-strategy e2e guard (scripts/istiod-fit-strategy-e2e-guard.sh).
#
# WHY THIS EXISTS
# The guard drives the REAL self-heal watcher end-to-end and asserts it patches a
# drifted istiod rolling-update strategy, patches a drifted istiod HPA, and is a
# no-op once both are conformant. If one of those assertions were silently broken
# the guard could PASS VACUOUSLY — green while proving nothing. This test applies
# deliberate REGRESSIONS to a copy of the real istiod-fit-strategy (never patch
# the strategy / never patch the HPA / patch the strategy even when conformant)
# and asserts the guard FAILS on each, plus asserts the pristine script PASSES.
#
# Usage: bash scripts/istiod-fit-strategy-e2e-guard.test.sh
# Exit 0 if every case behaves as expected, 1 otherwise.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
GUARD="$HERE/istiod-fit-strategy-e2e-guard.sh"
REAL="$REPO_ROOT/box-scripts/sbin/istiod-fit-strategy"

PASS=0; FAIL=0
TMPROOT="$(mktemp -d)"; trap 'rm -rf "$TMPROOT"' EXIT

broken_copy() {
  local expr="$1" f
  f="$(mktemp "$TMPROOT/istiod-fit.XXXXXX")"
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
expect_pass "$REAL" "pristine istiod-fit-strategy"

echo "== regression: strategy patch downgraded to a get -> surge drift never fixed =="
b="$(broken_copy 's/patch deploy/get deploy/g')" \
  && expect_fail "$b" "guard catches a watcher that never patches the istiod strategy"

echo "== regression: HPA patch downgraded to a get -> HPA scale-up never clamped =="
b="$(broken_copy 's/patch hpa/get hpa/g')" \
  && expect_fail "$b" "guard catches a watcher that never patches the istiod HPA"

echo "== regression: surge check always true -> strategy patched even when conformant =="
b="$(broken_copy 's/"$SURGE" != "0"/-n "x"/')" \
  && expect_fail "$b" "guard catches a watcher that patches an already-conformant strategy"

echo ""
echo "==================================================================="
echo "istiod-fit-strategy-e2e-guard self-test: $PASS passed, $FAIL failed"
echo "==================================================================="
[ "$FAIL" -eq 0 ]
