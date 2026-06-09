# Copyright 2026 SZL Holdings
# SPDX-License-Identifier: Apache-2.0
#
# ns-scratch-watch-guard-checks.test.sh — negative-fixture self-test for the
# ns-scratch-watch guard (scripts/ns-scratch-watch-guard-checks.sh).
#
# WHY THIS EXISTS
# The guard enforces the szl-ns-scratch-watch alarm's invariants entirely with
# hand-written grep. If one of those checks breaks (a regex typo, a bad anchor)
# it can PASS VACUOUSLY — green while guarding nothing. This test feeds each
# check a deliberately-BROKEN fixture and asserts the check FAILS, plus asserts
# the pristine repo PASSES. A future edit that neuters a check is caught here in
# CI.
#
# It sources the EXACT script the workflow runs (so chk1..chk6 are the real
# functions) and runs them against fixtures built from the real source files.
#
# Usage: bash scripts/ns-scratch-watch-guard-checks.test.sh
# Exit 0 if every case behaves as expected, 1 otherwise.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
CHECKS="$HERE/ns-scratch-watch-guard-checks.sh"

# shellcheck source=/dev/null
source "$CHECKS"

PASS=0
FAIL=0
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

# Source files the guard inspects, relative to a repo root.
SRC_FILES=(
  "box-scripts/sbin/szl-ns-scratch-watch"
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

WATCH="box-scripts/sbin/szl-ns-scratch-watch"
INSTALL="box-scripts/install.sh"
README="box-scripts/README.md"

echo "== pristine repo: every check passes =="
expect_pass chk1 "$REPO_ROOT" "chk1 watch script present + parses"
expect_pass chk2 "$REPO_ROOT" "chk2 shells out to list-unlabeled"
expect_pass chk3 "$REPO_ROOT" "chk3 edge-trigger state + 2 notify calls"
expect_pass chk4 "$REPO_ROOT" "chk4 cluster-absent/unreachable no-op"
expect_pass chk5 "$REPO_ROOT" "chk5 wired into install.sh"
expect_pass chk6 "$REPO_ROOT" "chk6 documented in README.md"

echo "== chk1 negatives =="
d="$(new_fixture)"; rm -f "$d/$WATCH"
expect_fail chk1 "$d" "chk1 fails when the watch script is missing"

d="$(new_fixture)"; printf 'if [ \n' > "$d/$WATCH"
expect_fail chk1 "$d" "chk1 fails when the watch script has a syntax error"

echo "== chk2 negatives =="
d="$(new_fixture)"; sed -i 's#list-unlabeled#list-DISABLED#g' "$d/$WATCH"
expect_fail chk2 "$d" "chk2 fails when the list-unlabeled call is dropped"

# list-unlabeled left only as a trailing comment, never executed via $SCRATCH_BIN.
d="$(new_fixture)"; sed -i 's|"$SCRATCH_BIN" list-unlabeled|"$SCRATCH_BIN" audit # was list-unlabeled|' "$d/$WATCH"
expect_fail chk2 "$d" "chk2 fails when list-unlabeled is no longer executed via \$SCRATCH_BIN"

echo "== chk3 negatives =="
d="$(new_fixture)"; sed -i 's#prev="$(cat "$LAST_FILE" 2>/dev/null || echo OK)"#prev=OK#' "$d/$WATCH"
expect_fail chk3 "$d" "chk3 fails when the last_status read is removed"

d="$(new_fixture)"; sed -i 's#echo ALERT >"$LAST_FILE" 2>/dev/null##; s#echo OK >"$LAST_FILE" 2>/dev/null##' "$d/$WATCH"
expect_fail chk3 "$d" "chk3 fails when the last_status writes are removed"

d="$(new_fixture)"; sed -i 's#if \[ "$prev" != "ALERT" \]; then#if true; then#' "$d/$WATCH"
expect_fail chk3 "$d" "chk3 fails when the OK->ALERT edge guard is removed"

# Remove one notify call -> count drops to 1 (not exactly 2).
d="$(new_fixture)"; sed -i '/notify "RECOVERED:/d' "$d/$WATCH"
expect_fail chk3 "$d" "chk3 fails when the RECOVERED notify call is removed"

# Add an unconditional extra notify -> count rises to 3 (alarm-storm risk).
d="$(new_fixture)"; sed -i 's#^exit 0#  notify "spurious extra page"\nexit 0#' "$d/$WATCH"
expect_fail chk3 "$d" "chk3 fails when an extra notify call is added"

echo "== chk4 negatives =="
# Drop the exit-0 fallback on the kubeconfig-resolve line.
d="$(new_fixture)"
sed -i 's#|| { log "INFO cluster .\$CLUSTER. absent — skip"; write_status UNKNOWN "cluster absent"; exit 0; }##' "$d/$WATCH"
expect_fail chk4 "$d" "chk4 fails when cluster-absent no longer no-ops (exit 0 removed)"

# Drop the exit-0 fallback on the readyz reachability probe.
d="$(new_fixture)"
sed -i '/--raw=.\/readyz/,/exit 0; }/ s#exit 0;##' "$d/$WATCH"
expect_fail chk4 "$d" "chk4 fails when cluster-unreachable no longer no-ops (readyz exit 0 removed)"

echo "== chk5 negatives =="
d="$(new_fixture)"; sed -i '\#install .*sbin/szl-ns-scratch-watch#d' "$d/$INSTALL"
expect_fail chk5 "$d" "chk5 fails when install.sh stops installing the script"

d="$(new_fixture)"; sed -i '/systemctl enable --now szl-ns-scratch-watch.timer/d' "$d/$INSTALL"
expect_fail chk5 "$d" "chk5 fails when install.sh stops enabling the timer"

echo "== chk6 negatives =="
d="$(new_fixture)"; sed -i 's#szl-ns-scratch-watch#szl-ns-scratch-RENAMED#g' "$d/$README"
expect_fail chk6 "$d" "chk6 fails when README no longer documents szl-ns-scratch-watch"

echo ""
echo "==================================================================="
echo "ns-scratch-watch-guard self-test: $PASS passed, $FAIL failed"
echo "==================================================================="
[ "$FAIL" -eq 0 ]
