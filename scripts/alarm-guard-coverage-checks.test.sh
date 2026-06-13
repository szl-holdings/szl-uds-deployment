#!/usr/bin/env bash
# Copyright 2026 SZL Holdings
# SPDX-License-Identifier: Apache-2.0
#
# alarm-guard-coverage-checks.test.sh — negative-fixture self-test for the alarm
# guard-coverage META-GUARD (scripts/alarm-guard-coverage-checks.sh).
#
# WHY THIS EXISTS
# The gate is hand-written bash. If the install.sh parser, the alarm-suffix
# filter, the prefix-stripping, or any guard-shape probe breaks, the check can
# PASS VACUOUSLY — green while enforcing nothing. This test sources the EXACT
# functions the workflow runs and asserts, against fixtures built from the real
# repo, that:
#   * the pristine repo PASSES (every installed alarm is guarded or allowlisted);
#   * the allowlist is actually consulted (emptying it makes the pristine repo
#     FAIL on a11oy-uptime-check — proves it is not a no-op);
#   * a brand-new alarm wired into install.sh with NO guard FAILS;
#   * that same new alarm is accepted once placed on the allowlist;
#   * removing a TEXT-trio file (receipt-chain-watch-guard.yml) FAILS;
#   * removing an E2E-trio file (box-scripts-drift-check-guard.test.sh) FAILS
#     (proves the E2E shape is recognised, not the TEXT one);
#   * removing a behavioural-selftest file (receipt-flood-watch-selftest.yml)
#     FAILS (proves the SELFTEST shape is what covers that alarm);
#   * removing a prefix-dropped guard (ns-scratch-watch-guard.yml) FAILS (proves
#     the szl-/a11oy- stem stripping is real);
#   * an install.sh with no alarm install lines FAILS (anti-vacuous enumerator).
#
# Usage: bash scripts/alarm-guard-coverage-checks.test.sh
# Exit 0 if every case behaves as expected, 1 otherwise.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
CHECK="$HERE/alarm-guard-coverage-checks.sh"

# shellcheck source=/dev/null
source "$CHECK"

PASS=0
FAIL=0
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

# new_fixture — a faithful copy of the repo surfaces the gate reads.
new_fixture() {
  local dir
  dir="$(mktemp -d "$TMPROOT/fixture.XXXXXX")"
  mkdir -p "$dir/box-scripts" "$dir/.github"
  cp -a "$REPO_ROOT/box-scripts/sbin"       "$dir/box-scripts/sbin"
  cp -a "$REPO_ROOT/box-scripts/install.sh" "$dir/box-scripts/install.sh"
  cp -a "$REPO_ROOT/scripts"                "$dir/scripts"
  cp -a "$REPO_ROOT/.github/workflows"      "$dir/.github/workflows"
  echo "$dir"
}

# run_cov ROOT [ALLOWLIST] — run the (sourced) check_coverage in a subshell.
# `env` cannot invoke a shell function, so allowlist overrides use a subshell-local
# assignment. Passing a 2nd arg (even "") SETS ALARM_GUARD_ALLOWLIST; omitting it
# leaves the var UNSET (production default).
run_cov() {
  if [ "$#" -ge 2 ]; then
    ( export ALARM_GUARD_ALLOWLIST="$2"; check_coverage "$1" )
  else
    ( check_coverage "$1" )
  fi
}

expect_pass() {
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then
    echo "ok   (pass) $desc"; PASS=$((PASS+1))
  else
    echo "FAIL (expected pass, got fail) $desc"; FAIL=$((FAIL+1))
  fi
}
expect_fail() {
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then
    echo "FAIL (expected fail, got pass) $desc"; FAIL=$((FAIL+1))
  else
    echo "ok   (fail) $desc"; PASS=$((PASS+1))
  fi
}

# 1) pristine repo passes.
expect_pass "pristine repo: every installed alarm guarded or allowlisted" \
  run_cov "$REPO_ROOT"

# 2) allowlist is consulted: emptied -> a11oy-uptime-check is exposed -> FAIL.
expect_fail "empty allowlist exposes a11oy-uptime-check (allowlist is not a no-op)" \
  run_cov "$REPO_ROOT" ""

# 3) new alarm wired into install.sh with no guard -> FAIL.
F3="$(new_fixture)"
printf '#!/bin/sh\necho hi\n' > "$F3/box-scripts/sbin/zz-demo-watch"
printf '\ninstall -m 0755 "$here/sbin/zz-demo-watch" /usr/local/sbin/zz-demo-watch\n' \
  >> "$F3/box-scripts/install.sh"
expect_fail "new install.sh alarm with no guard is rejected" \
  run_cov "$F3"

# 4) ...accepted once allowlisted.
expect_pass "new alarm accepted when placed on the allowlist" \
  run_cov "$F3" "$DEFAULT_ALLOWLIST zz-demo-watch"

# 5) remove a TEXT-trio file -> FAIL (receipt-chain-watch).
F5="$(new_fixture)"
rm -f "$F5/.github/workflows/receipt-chain-watch-guard.yml"
expect_fail "removing receipt-chain-watch-guard.yml (TEXT trio) is caught" \
  run_cov "$F5"

# 6) remove an E2E-trio file -> FAIL (box-scripts-drift-check).
F6="$(new_fixture)"
rm -f "$F6/scripts/box-scripts-drift-check-guard.test.sh"
expect_fail "removing box-scripts-drift-check-guard.test.sh (E2E trio) is caught" \
  run_cov "$F6"

# 7) remove a behavioural-selftest file -> FAIL (receipt-flood-watch).
F7="$(new_fixture)"
rm -f "$F7/.github/workflows/receipt-flood-watch-selftest.yml"
expect_fail "removing receipt-flood-watch-selftest.yml (SELFTEST shape) is caught" \
  run_cov "$F7"

# 8) remove a prefix-dropped guard -> FAIL (szl-ns-scratch-watch -> ns-scratch-watch).
F8="$(new_fixture)"
rm -f "$F8/.github/workflows/ns-scratch-watch-guard.yml"
expect_fail "removing ns-scratch-watch-guard.yml (prefix-dropped stem) is caught" \
  run_cov "$F8"

# 9) anti-vacuous: install.sh with no alarm install lines -> FAIL.
F9="$(new_fixture)"
printf 'here=.\ninstall -m 0755 "$here/sbin/a11oy-mode" /usr/local/sbin/a11oy-mode\n' \
  > "$F9/box-scripts/install.sh"
expect_fail "install.sh with zero alarm lines fails (anti-vacuous enumerator)" \
  run_cov "$F9"

echo "----"
echo "alarm-guard-coverage self-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
