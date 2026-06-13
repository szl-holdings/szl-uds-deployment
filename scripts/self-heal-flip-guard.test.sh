# Copyright 2026 SZL Holdings
# SPDX-License-Identifier: Apache-2.0
#
# self-heal-flip-guard.test.sh — negative-fixture self-test for the self-heal
# one-flip guard (scripts/self-heal-flip-guard.sh).
#
# WHY THIS EXISTS
# The guard slices the SELF_HEAL drop-in reconcile block out of
# box-scripts/install.sh and asserts its enable/disable/unset/unrecognised +
# idempotency behaviour. If one of those assertions were silently broken the
# guard could PASS VACUOUSLY — green while proving nothing. This test takes the
# real install.sh, applies a series of deliberate REGRESSIONS to a copy (remove
# the whole reconcile block, neuter enable, neuter disable, break idempotency,
# mutate the unrecognised-value branch) and asserts the guard FAILS on each —
# plus asserts the pristine install.sh PASSES. A future edit that neuters one of
# the guard's assertions is therefore caught here in CI.
#
# Usage: bash scripts/self-heal-flip-guard.test.sh
# Exit 0 if every case behaves as expected, 1 otherwise.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
GUARD="$HERE/self-heal-flip-guard.sh"
REAL="$REPO_ROOT/box-scripts/install.sh"

PASS=0
FAIL=0
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

# broken_copy "sed expr" -> echo path to a copy of install.sh with the
# regression applied. The copy must still parse (bash -n) or the mutation was a
# typo, not a meaningful negative fixture.
broken_copy() {
  local expr="$1" f
  f="$(mktemp "$TMPROOT/install.XXXXXX.sh")"
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

echo "== pristine install.sh: the guard passes =="
expect_pass "$REAL" "pristine box-scripts/install.sh"

echo "== regression: the whole reconcile block is removed -> nothing flips =="
b="$(broken_copy '/SELF_HEAL_RECONCILE_BEGIN/,/SELF_HEAL_RECONCILE_END/d')" \
  && expect_fail "$b" "guard catches a removed reconcile block"

echo "== regression: enable never writes the drop-in =="
b="$(broken_copy 's|install -m 0644 "\$selfheal_tmp" "\$selfheal_dropin"|: # BROKEN no write|')" \
  && expect_fail "$b" "guard catches an enable path that never writes the drop-in"

echo "== regression: disable never removes the drop-in =="
b="$(broken_copy 's|rm -f "\$selfheal_dropin"|: # BROKEN no remove|')" \
  && expect_fail "$b" "guard catches a disable path that never removes the drop-in"

echo "== regression: idempotency broken (drop-in churns on every enable) =="
b="$(broken_copy 's|echo "\[Service\]"|echo "[Service]"; echo "# nonce $(date +%s%N)"|')" \
  && expect_fail "$b" "guard catches a non-idempotent enable"

echo "== regression: unrecognised value mutates state instead of leaving it =="
b="$(broken_copy 's|.*leaving drop-in untouched.*|    rm -rf "$selfheal_dropin_dir"|')" \
  && expect_fail "$b" "guard catches an unrecognised value that changes state"

echo ""
echo "==================================================================="
echo "self-heal one-flip guard self-test: $PASS passed, $FAIL failed"
echo "==================================================================="
[ "$FAIL" -eq 0 ]
