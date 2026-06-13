# Copyright 2026 SZL Holdings
# SPDX-License-Identifier: Apache-2.0
#
# box-fallback-superset-checks.test.sh — negative-fixture self-test for the
# fallback-superset gate (scripts/box-fallback-superset-checks.sh).
#
# WHY THIS EXISTS
# The gate is hand-written grep/awk: it parses install.sh AND parses the
# multi-line FALLBACK_SBIN / FALLBACK_UNITS assignments out of
# box-scripts/sbin/box-scripts-drift-check. If either parser breaks (a quoting
# slip, a regex typo, a botched line-continuation walk) the check can PASS
# VACUOUSLY — green while guarding nothing. This test exercises the EXACT
# functions the workflow runs (sourced) against fixtures built from the real
# repo and asserts:
#   * the pristine repo PASSES (both fallback lists cover install.sh);
#   * dropping an installed sbin name from FALLBACK_SBIN FAILS;
#   * re-adding that name to FALLBACK_SBIN PASSES again;
#   * dropping an installed unit from FALLBACK_UNITS FAILS;
#   * the allowlist is actually consulted: an install line for an allowlisted
#     own-installer name (szl-box-sync) that is NOT in the fallback PASSES with
#     the default allowlist but FAILS once the allowlist is emptied — proving the
#     skip is real and not a vacuous pass.
#
# Usage: bash scripts/box-fallback-superset-checks.test.sh
# Exit 0 if every case behaves as expected, 1 otherwise.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
CHECK="$HERE/box-fallback-superset-checks.sh"

# shellcheck source=/dev/null
source "$CHECK"

PASS=0
FAIL=0
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

DRIFT_REL="box-scripts/sbin/box-scripts-drift-check"

# new_fixture — a faithful copy of install.sh + the drift-check script under a
# fresh root (only the files the gate reads).
new_fixture() {
  local dir
  dir="$(mktemp -d "$TMPROOT/fixture.XXXXXX")"
  mkdir -p "$dir/box-scripts/sbin"
  cp -a "$REPO_ROOT/box-scripts/install.sh" "$dir/box-scripts/install.sh"
  cp -a "$REPO_ROOT/$DRIFT_REL"             "$dir/$DRIFT_REL"
  echo "$dir"
}

# run_chk ROOT [ALLOWLIST] — run the (sourced) check_superset in a subshell.
# Passing a 2nd arg (even "") SETS BOX_FALLBACK_ALLOWLIST; omitting it leaves the
# var UNSET (production default).
run_chk() {
  if [ "$#" -ge 2 ]; then
    ( export BOX_FALLBACK_ALLOWLIST="$2"; check_superset "$1" )
  else
    ( check_superset "$1" )
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
expect_pass "pristine repo: fallback lists cover install.sh" \
  run_chk "$REPO_ROOT"

# 2) drop an installed sbin name from FALLBACK_SBIN -> FAIL.
#    'a11oy-mode' is installed by install.sh and listed in FALLBACK_SBIN; it does
#    not appear as a substring of any unit name, so the deletion is surgical.
F2="$(new_fixture)"
sed -i 's/a11oy-mode //' "$F2/$DRIFT_REL"
expect_fail "installed sbin name dropped from FALLBACK_SBIN is rejected" \
  run_chk "$F2"

# 3) ...and re-adding it to FALLBACK_SBIN passes again.
sed -i 's/FALLBACK_SBIN="/FALLBACK_SBIN="a11oy-mode /' "$F2/$DRIFT_REL"
expect_pass "re-added sbin name in FALLBACK_SBIN is accepted" \
  run_chk "$F2"

# 4) drop an installed unit from FALLBACK_UNITS -> FAIL.
#    'box-scripts-drift-check.timer' is installed and listed; the `.timer`
#    qualifier keeps the deletion from touching the matching .service.
F4="$(new_fixture)"
sed -i 's/box-scripts-drift-check\.timer //' "$F4/$DRIFT_REL"
expect_fail "installed unit dropped from FALLBACK_UNITS is rejected" \
  run_chk "$F4"

# 5) the allowlist is actually consulted. Add an install line for the
#    own-installer name szl-box-sync (NOT in the fallback): with the default
#    allowlist it is skipped (PASS); with the allowlist emptied it is now
#    required and missing (FAIL) — proving the skip is real, not vacuous.
F5="$(new_fixture)"
printf '\ninstall -m 0755 "$here/sbin/szl-box-sync" /usr/local/sbin/szl-box-sync\n' \
  >> "$F5/box-scripts/install.sh"
expect_pass "allowlisted own-installer name absent from fallback is skipped" \
  run_chk "$F5"
expect_fail "empty allowlist requires even the own-installer name" \
  run_chk "$F5" ""

echo "----"
echo "box-fallback-superset self-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
