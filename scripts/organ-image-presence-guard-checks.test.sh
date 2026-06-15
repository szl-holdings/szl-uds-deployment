# Copyright 2026 SZL Holdings
# SPDX-License-Identifier: Apache-2.0
#
# organ-image-presence-guard-checks.test.sh — negative-fixture self-test for the
# RETIRED-ORGAN image-presence PAGER guard (organ-image-presence-guard-checks.sh).
#
# WHY THIS EXISTS
# The guard enforces the pager's selectivity entirely with hand-written awk/grep.
# If one of those checks breaks (a regex typo, a bad anchor) it can PASS VACUOUSLY
# — green while guarding nothing. This test feeds each check a deliberately-BROKEN
# copy of organ-image-presence-guard.yml and asserts the check FAILS, plus asserts
# the pristine repo PASSES. Mirrors organ-pin-drift-guard-checks.test.sh.
#
# Usage: bash scripts/organ-image-presence-guard-checks.test.sh
# Exit 0 if every case behaves as expected, 1 otherwise.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
CHECKS="$HERE/organ-image-presence-guard-checks.sh"

# shellcheck source=/dev/null
source "$CHECKS"

PASS=0
FAIL=0
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

WF=".github/workflows/organ-image-presence-guard.yml"

new_fixture() {
  local dir
  dir="$(mktemp -d "$TMPROOT/fixture.XXXXXX")"
  mkdir -p "$dir/$(dirname "$WF")"
  cp "$REPO_ROOT/$WF" "$dir/$WF"
  echo "$dir"
}

expect_pass() {
  local check="$1" root="$2" name="$3" out rc
  out="$("$check" "$root" 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ]; then echo "ok   PASS-expected: $name"; PASS=$((PASS+1));
  else echo "FAIL PASS-expected but $check exited $rc: $name"; echo "$out" | sed 's/^/       | /'; FAIL=$((FAIL+1)); fi
}

expect_fail() {
  local check="$1" root="$2" name="$3" out rc
  out="$("$check" "$root" 2>&1)"; rc=$?
  if [ "$rc" -ne 0 ]; then echo "ok   FAIL-expected: $name"; PASS=$((PASS+1));
  else echo "FAIL FAIL-expected but $check exited 0: $name"; echo "$out" | sed 's/^/       | /'; FAIL=$((FAIL+1)); fi
}

echo "== pristine repo: every check passes =="
expect_pass chk1 "$REPO_ROOT" "chk1 alert keeps always()"
expect_pass chk2 "$REPO_ROOT" "chk2 alert keeps event_name == schedule"
expect_pass chk3 "$REPO_ROOT" "chk3 alert keeps missing == 1"
expect_pass chk4 "$REPO_ROOT" "chk4 probe step set +e + exports"
expect_pass chk5 "$REPO_ROOT" "chk5 final gate re-fails on missing"

echo "== chk1 negatives (alert no longer always()) =="
d="$(new_fixture)"; sed -i "s/always() && //" "$d/$WF"
expect_fail chk1 "$d" "chk1 fails when always() is dropped from the alert if"
expect_pass chk2 "$d" "chk2 still passes after only always() removed"
expect_pass chk3 "$d" "chk3 still passes after only always() removed"

echo "== chk2 negatives (alert no longer schedule-only -> would spam PRs) =="
d="$(new_fixture)"; sed -i "s/github.event_name == 'schedule' && //" "$d/$WF"
expect_fail chk2 "$d" "chk2 fails when the schedule restriction is dropped"
expect_pass chk1 "$d" "chk1 still passes after only schedule removed"
expect_pass chk3 "$d" "chk3 still passes after only schedule removed"

echo "== chk3 negatives (alert no longer missing-gated -> would page on green) =="
d="$(new_fixture)"; sed -i "s/ && steps.check.outputs.missing == '1'//" "$d/$WF"
expect_fail chk3 "$d" "chk3 fails when the missing==1 gate is dropped"
expect_pass chk1 "$d" "chk1 still passes after only missing gate removed"
expect_pass chk2 "$d" "chk2 still passes after only missing gate removed"

echo "== chk4 negatives (probe step contract) =="
d="$(new_fixture)"; sed -i "/[[:space:]]set +e$/d" "$d/$WF"
expect_fail chk4 "$d" "chk4 fails when 'set +e' is removed from the probe step"

d="$(new_fixture)"; sed -i '/echo "missing=1"/d; /echo "missing=0"/d' "$d/$WF"
expect_fail chk4 "$d" "chk4 fails when the missing output export is removed"

d="$(new_fixture)"; sed -i '/echo "images<<EOF"/d' "$d/$WF"
expect_fail chk4 "$d" "chk4 fails when the images output export is removed"

echo "== chk5 negatives (final gate) =="
d="$(new_fixture)"
awk '/^      - name: Fail the run/{drop=1} drop{next} {print}' "$REPO_ROOT/$WF" > "$d/$WF"
expect_fail chk5 "$d" "chk5 fails when the final gate step is removed"

d="$(new_fixture)"
sed -i "s/^        if: always()$/        if: \${{ always() \&\& github.event_name == 'schedule' }}/" "$d/$WF"
expect_fail chk5 "$d" "chk5 fails when the gate is restricted to the schedule"
expect_pass chk1 "$d" "chk1 still passes after only the gate is altered"

d="$(new_fixture)"
awk '/^      - name: Fail the run/{ing=1} ing && /exit 1/{sub(/exit 1/,"echo would-not-fail")} {print}' "$REPO_ROOT/$WF" > "$d/$WF"
expect_fail chk5 "$d" "chk5 fails when the gate no longer exits non-zero"

echo ""
echo "==================================================================="
echo "organ-image-presence-guard self-test: $PASS passed, $FAIL failed"
echo "==================================================================="
[ "$FAIL" -eq 0 ]
