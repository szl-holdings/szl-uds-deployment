# Copyright 2026 SZL Holdings
# SPDX-License-Identifier: Apache-2.0
#
# ns-scratch-stale-watch-guard-checks.test.sh — negative-fixture self-test for the
# ns-scratch-stale-watch guard (scripts/ns-scratch-stale-watch-guard-checks.sh).
#
# WHY THIS EXISTS
# The guard enforces the szl-ns-scratch-stale-watch alarm's behaviour by actually
# RUNNING the script in a hermetic sandbox and by hand-written grep. If one of
# those checks breaks (a regex typo, a bad sandbox, an assertion that never
# fires) it can PASS VACUOUSLY — green while guarding nothing. This test feeds
# each check a deliberately-BROKEN copy of the script and asserts the check
# FAILS, plus asserts the pristine repo PASSES. A future edit that neuters a
# check is caught here in CI.
#
# It sources the EXACT script the workflow runs (so chk1..chk7 are the real
# functions) and runs them against fixtures built from the real source files.
#
# Usage: bash scripts/ns-scratch-stale-watch-guard-checks.test.sh
# Exit 0 if every case behaves as expected, 1 otherwise.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
CHECKS="$HERE/ns-scratch-stale-watch-guard-checks.sh"

# shellcheck source=/dev/null
source "$CHECKS"

PASS=0
FAIL=0
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

# Source files the guard inspects, relative to a repo root.
SRC_FILES=(
  "box-scripts/sbin/szl-ns-scratch-stale-watch"
  "box-scripts/install.sh"
  "box-scripts/README.md"
)

# new_fixture — build a fresh fixture tree (a faithful copy of the real source
# files) under a unique dir and echo its path.
new_fixture() {
  local dir
  dir="$(mktemp -d "$TMPROOT/fixture.XXXXXX")"
  local f
  for f in "${SRC_FILES[@]}"; do
    mkdir -p "$dir/$(dirname "$f")"
    cp "$REPO_ROOT/$f" "$dir/$f"
  done
  echo "$dir"
}

# expect_pass CHECK ROOT NAME — assert CHECK returns 0 on ROOT.
expect_pass() {
  local check="$1" root="$2" name="$3" out rc
  out="$("$check" "$root" 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ]; then
    echo "ok   PASS-expected: $name"
    PASS=$((PASS+1))
  else
    echo "FAIL PASS-expected but $check exited $rc: $name"
    echo "$out" | sed 's/^/       | /'
    FAIL=$((FAIL+1))
  fi
}

# expect_fail CHECK ROOT NAME — assert CHECK returns non-zero on ROOT.
expect_fail() {
  local check="$1" root="$2" name="$3" out rc
  out="$("$check" "$root" 2>&1)"; rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "ok   FAIL-expected: $name"
    PASS=$((PASS+1))
  else
    echo "FAIL FAIL-expected but $check exited 0: $name"
    echo "$out" | sed 's/^/       | /'
    FAIL=$((FAIL+1))
  fi
}

WATCH="box-scripts/sbin/szl-ns-scratch-stale-watch"
INSTALL="box-scripts/install.sh"
README="box-scripts/README.md"

echo "== pristine repo: every check passes =="
expect_pass chk1 "$REPO_ROOT" "chk1 watch script present + parses"
expect_pass chk2 "$REPO_ROOT" "chk2 shells out to list-stale"
expect_pass chk3 "$REPO_ROOT" "chk3 edge lifecycle (alert/dedupe/recovered/steady)"
expect_pass chk4 "$REPO_ROOT" "chk4 cluster-absent/unreachable/scratch no-op"
expect_pass chk5 "$REPO_ROOT" "chk5 never auto-deletes"
expect_pass chk6 "$REPO_ROOT" "chk6 wired into install.sh"
expect_pass chk7 "$REPO_ROOT" "chk7 documented in README.md"

echo "== chk1 negatives =="
d="$(new_fixture)"; rm -f "$d/$WATCH"
expect_fail chk1 "$d" "chk1 fails when the watch script is missing"

d="$(new_fixture)"; printf 'if [ \n' > "$d/$WATCH"
expect_fail chk1 "$d" "chk1 fails when the watch script has a syntax error"

echo "== chk2 negatives =="
d="$(new_fixture)"; sed -i 's#list-stale#list-DISABLED#g' "$d/$WATCH"
expect_fail chk2 "$d" "chk2 fails when the list-stale call is dropped"

# list-stale left only as a trailing comment, never executed via $SCRATCH_BIN.
d="$(new_fixture)"; sed -i 's|"$SCRATCH_BIN" list-stale|"$SCRATCH_BIN" audit # was list-stale|' "$d/$WATCH"
expect_fail chk2 "$d" "chk2 fails when list-stale is no longer executed via \$SCRATCH_BIN"

echo "== chk3 negatives =="
# Remove the OK->ALERT de-dupe guard -> still-expired re-pages (storm).
d="$(new_fixture)"; sed -i 's#\[ "\$prev" != "ALERT" \]#true#' "$d/$WATCH"
expect_fail chk3 "$d" "chk3 fails when the de-dupe (OK->ALERT edge) guard is removed"

# Remove the ALERT notify call -> expired present pages zero times.
d="$(new_fixture)"; sed -i '/notify "ALERT: \$count scratch/d' "$d/$WATCH"
expect_fail chk3 "$d" "chk3 fails when the ALERT page is removed"

# Remove the RECOVERED notify call -> recovery pages zero times.
d="$(new_fixture)"; sed -i '/notify "RECOVERED:/d' "$d/$WATCH"
expect_fail chk3 "$d" "chk3 fails when the RECOVERED page is removed"

# Stop persisting last_status -> de-dupe state is lost, re-pages while expired.
d="$(new_fixture)"; sed -i 's#echo ALERT >"\$LAST_FILE" 2>/dev/null##; s#echo OK >"\$LAST_FILE" 2>/dev/null##' "$d/$WATCH"
expect_fail chk3 "$d" "chk3 fails when the last_status writes are removed"

echo "== chk4 negatives =="
# Cluster-absent path no longer no-ops (exit 0 -> exit 1).
d="$(new_fixture)"
sed -i 's#write_status UNKNOWN "cluster absent"; exit 0#write_status UNKNOWN "cluster absent"; exit 1#' "$d/$WATCH"
expect_fail chk4 "$d" "chk4 fails when cluster-absent no longer no-ops (exit 0 removed)"

# Cluster-unreachable path no longer no-ops.
d="$(new_fixture)"
sed -i 's#write_status UNKNOWN "cluster unreachable"; exit 0#write_status UNKNOWN "cluster unreachable"; exit 1#' "$d/$WATCH"
expect_fail chk4 "$d" "chk4 fails when cluster-unreachable no longer no-ops (exit 0 removed)"

# The "nothing to do" sentinel is no longer recognised -> an empty result during
# an outage is misread as RECOVERED (false page, last_status flipped).
d="$(new_fixture)"; sed -i "s#grep -q 'nothing to do'#grep -q 'ZZ_IMPOSSIBLE_SENTINEL_ZZ'#" "$d/$WATCH"
expect_fail chk4 "$d" "chk4 fails when the scratch-tool no-op sentinel is no longer honoured"

echo "== chk5 negatives =="
# Introduce an auto-delete -> guard must catch it (statically and at runtime).
d="$(new_fixture)"; sed -i 's#^exit 0#kubectl delete ns szl-foo >/dev/null 2>\&1 || true\nexit 0#' "$d/$WATCH"
expect_fail chk5 "$d" "chk5 fails when an auto 'kubectl delete' is introduced"

echo "== chk6 negatives =="
d="$(new_fixture)"; sed -i '\#install .*sbin/szl-ns-scratch-stale-watch#d' "$d/$INSTALL"
expect_fail chk6 "$d" "chk6 fails when install.sh stops installing the script"

d="$(new_fixture)"; sed -i '/systemctl enable --now szl-ns-scratch-stale-watch.timer/d' "$d/$INSTALL"
expect_fail chk6 "$d" "chk6 fails when install.sh stops enabling the timer"

echo "== chk7 negatives =="
d="$(new_fixture)"; sed -i 's#szl-ns-scratch-stale-watch#szl-ns-scratch-RENAMED#g' "$d/$README"
expect_fail chk7 "$d" "chk7 fails when README no longer documents szl-ns-scratch-stale-watch"

echo ""
echo "==================================================================="
echo "ns-scratch-stale-watch-guard self-test: $PASS passed, $FAIL failed"
echo "==================================================================="
[ "$FAIL" -eq 0 ]
