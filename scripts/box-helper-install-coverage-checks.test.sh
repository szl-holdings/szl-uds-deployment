# Copyright 2026 SZL Holdings
# SPDX-License-Identifier: Apache-2.0
#
# box-helper-install-coverage-checks.test.sh — negative-fixture self-test for the
# box-helper install-coverage gate (scripts/box-helper-install-coverage-checks.sh).
#
# WHY THIS EXISTS
# The gate is hand-written grep/awk. If the install.sh parser breaks (a quoting
# slip, a regex typo) the check can PASS VACUOUSLY — green while guarding nothing.
# This test exercises the EXACT functions the workflow runs (sourced) against
# fixtures built from the real repo and asserts:
#   * the pristine repo PASSES (every committed file is wired or allowlisted);
#   * a bare new sbin script with no install line FAILS;
#   * the same script becomes covered once an install line is added;
#   * a bare new systemd unit with no install line FAILS;
#   * the allowlist is actually consulted (emptying it makes the pristine repo
#     FAIL on the own-installed szl-box-sync* family — proves it is not a no-op);
#   * a new file IS accepted when added to the allowlist.
#
# Usage: bash scripts/box-helper-install-coverage-checks.test.sh
# Exit 0 if every case behaves as expected, 1 otherwise.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
CHECK="$HERE/box-helper-install-coverage-checks.sh"

# shellcheck source=/dev/null
source "$CHECK"

PASS=0
FAIL=0
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

# new_fixture — a faithful copy of the real box-scripts/ under a fresh root.
new_fixture() {
  local dir
  dir="$(mktemp -d "$TMPROOT/fixture.XXXXXX")"
  mkdir -p "$dir/box-scripts"
  cp -a "$REPO_ROOT/box-scripts/sbin"       "$dir/box-scripts/sbin"
  cp -a "$REPO_ROOT/box-scripts/systemd"    "$dir/box-scripts/systemd"
  cp -a "$REPO_ROOT/box-scripts/install.sh" "$dir/box-scripts/install.sh"
  echo "$dir"
}

# run_cov ROOT [ALLOWLIST] — run the (sourced) check_coverage function in a
# subshell. `env` cannot invoke a shell function, so allowlist overrides are
# applied with a subshell-local assignment. Passing a 2nd arg (even "") SETS
# BOX_HELPER_ALLOWLIST; omitting it leaves the var UNSET (production default).
run_cov() {
  if [ "$#" -ge 2 ]; then
    ( export BOX_HELPER_ALLOWLIST="$2"; check_coverage "$1" )
  else
    ( check_coverage "$1" )
  fi
}

# expect_pass / expect_fail DESC -- CMD...
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
expect_pass "pristine repo: every file wired or allowlisted" \
  run_cov "$REPO_ROOT"

# 2) bare new sbin script, no install line, not allowlisted -> FAIL.
F2="$(new_fixture)"
printf '#!/bin/sh\necho hi\n' > "$F2/box-scripts/sbin/zz-unwired-watch"
expect_fail "bare new sbin script (no install line) is rejected" \
  run_cov "$F2"

# 3) ...and is accepted once an install line is added.
printf '\ninstall -m 0755 "$here/sbin/zz-unwired-watch" /usr/local/sbin/zz-unwired-watch\n' \
  >> "$F2/box-scripts/install.sh"
expect_pass "new sbin script with an install -m line is accepted" \
  run_cov "$F2"

# 4) bare new systemd unit, no install line -> FAIL.
F4="$(new_fixture)"
printf '[Unit]\nDescription=unwired\n' > "$F4/box-scripts/systemd/zz-unwired-watch.timer"
expect_fail "bare new systemd unit (no install line) is rejected" \
  run_cov "$F4"

# 5) the allowlist is actually consulted: with it emptied, the pristine repo must
#    FAIL because the own-installed szl-box-sync* family is not in install.sh.
expect_fail "empty allowlist exposes szl-box-sync* (allowlist is not a no-op)" \
  run_cov "$REPO_ROOT" ""

# 6) a new file IS accepted when placed on the allowlist.
F6="$(new_fixture)"
printf '#!/bin/sh\n' > "$F6/box-scripts/sbin/zz-own-installer-tool"
expect_pass "new file on the allowlist is accepted" \
  run_cov "$F6" "$DEFAULT_ALLOWLIST zz-own-installer-tool"

echo "----"
echo "box-helper-install-coverage self-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
