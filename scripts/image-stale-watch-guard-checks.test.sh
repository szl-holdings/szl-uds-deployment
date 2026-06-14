#!/usr/bin/env bash
# Copyright 2026 SZL Holdings
# SPDX-License-Identifier: Apache-2.0
#
# image-stale-watch-guard-checks.test.sh — negative-fixture self-test for the
# image-stale-watch guard (scripts/image-stale-watch-guard-checks.sh).
#
# WHY THIS EXISTS
# The guard enforces the szl-image-stale-watch alarm's behaviour by actually
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
# Usage: bash scripts/image-stale-watch-guard-checks.test.sh
# Exit 0 if every case behaves as expected, 1 otherwise.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
CHECKS="$HERE/image-stale-watch-guard-checks.sh"

# shellcheck source=/dev/null
source "$CHECKS"

PASS=0
FAIL=0
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

# Source files the guard inspects, relative to a repo root.
SRC_FILES=(
  "box-scripts/sbin/szl-image-stale-watch"
  "box-scripts/install.sh"
  "box-scripts/README.md"
)

# new_fixture — build a fresh fixture tree (a faithful copy of the real source
# files) under a unique dir and echo its path.
new_fixture() {
  local dir f
  dir="$(mktemp -d "$TMPROOT/fixture.XXXXXX")"
  for f in "${SRC_FILES[@]}"; do
    mkdir -p "$dir/$(dirname "$f")"
    cp "$REPO_ROOT/$f" "$dir/$f"
  done
  echo "$dir"
}

expect_pass() {
  local check="$1" root="$2" name="$3" out rc
  out="$("$check" "$root" 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ]; then echo "ok   PASS-expected: $name"; PASS=$((PASS+1))
  else echo "FAIL PASS-expected but $check exited $rc: $name"; echo "$out" | sed 's/^/       | /'; FAIL=$((FAIL+1)); fi
}
expect_fail() {
  local check="$1" root="$2" name="$3" out rc
  out="$("$check" "$root" 2>&1)"; rc=$?
  if [ "$rc" -ne 0 ]; then echo "ok   FAIL-expected: $name"; PASS=$((PASS+1))
  else echo "FAIL FAIL-expected but $check exited 0: $name"; echo "$out" | sed 's/^/       | /'; FAIL=$((FAIL+1)); fi
}

WATCH="box-scripts/sbin/szl-image-stale-watch"
INSTALL="box-scripts/install.sh"
README="box-scripts/README.md"

echo "== pristine repo: every check passes =="
expect_pass chk1 "$REPO_ROOT" "chk1 watch script present + parses"
expect_pass chk2 "$REPO_ROOT" "chk2 runs \$bin --verify-only"
expect_pass chk3 "$REPO_ROOT" "chk3 edge lifecycle (alert/dedupe/recovered/steady)"
expect_pass chk4 "$REPO_ROOT" "chk4 helper-absent/verify-error no-op"
expect_pass chk5 "$REPO_ROOT" "chk5 never rebuilds"
expect_pass chk6 "$REPO_ROOT" "chk6 wired into install.sh"
expect_pass chk7 "$REPO_ROOT" "chk7 documented in README.md"

echo "== chk1 negatives =="
d="$(new_fixture)"; rm -f "$d/$WATCH"
expect_fail chk1 "$d" "chk1 fails when the watch script is missing"
d="$(new_fixture)"; printf 'if [ \n' > "$d/$WATCH"
expect_fail chk1 "$d" "chk1 fails when the watch script has a syntax error"

echo "== chk2 negatives =="
# Drop --verify-only from the invocation -> no verdict source.
d="$(new_fixture)"; sed -i 's#"\$bin" --verify-only#"\$bin"#' "$d/$WATCH"
expect_fail chk2 "$d" "chk2 fails when --verify-only is dropped from the invocation"

echo "== chk3 negatives =="
# Remove the OK->ALERT de-dupe guard -> still-drift re-pages (storm).
d="$(new_fixture)"; sed -i 's#\[ "\$prev" != "ALERT" \]#true#' "$d/$WATCH"
expect_fail chk3 "$d" "chk3 fails when the de-dupe (OK->ALERT edge) guard is removed"
# Remove the ALERT notify call -> drift pages zero times.
d="$(new_fixture)"; sed -i '/notify "ALERT: \$t live container/d' "$d/$WATCH"
expect_fail chk3 "$d" "chk3 fails when the ALERT page is removed"
# Remove the RECOVERED notify call -> recovery pages zero times.
d="$(new_fixture)"; sed -i '/notify "RECOVERED: \$t live container/d' "$d/$WATCH"
expect_fail chk3 "$d" "chk3 fails when the RECOVERED page is removed"
# Stop persisting last_status -> de-dupe state lost, re-pages while drifted.
d="$(new_fixture)"; sed -i 's#echo ALERT >"\$last_file" 2>/dev/null##; s#echo OK >"\$last_file" 2>/dev/null##' "$d/$WATCH"
expect_fail chk3 "$d" "chk3 fails when the last_status writes are removed"
# Strip the repo/commit naming from the ALERT -> page no longer names the lag.
d="$(new_fixture)"; sed -i 's#repo=\$t (\$repo) \$(describe_commits "\$repo" "\$branch")\.##' "$d/$WATCH"
expect_fail chk3 "$d" "chk3 fails when the ALERT stops naming the repo + lagging commit"

echo "== chk4 negatives =="
# helper-absent path no longer no-ops (force a page when bin missing).
d="$(new_fixture)"
sed -i 's#log "INFO \[\$t\] rebuild helper .* — skip (no-op)"#notify "spurious"#' "$d/$WATCH"
expect_fail chk4 "$d" "chk4 fails when a missing helper no longer no-ops silently"
# verify-error (rc not 0/5) is mis-handled as recovery -> false page / flip.
# Replace the fail-soft WARN line with a (bogus) recover-and-reset, so an error
# rc now pages RECOVERED and flips the ALERT baseline to OK.
d="$(new_fixture)"
sed -i 's#.*verify-only could not determine sync state.*#    if [ "$prev" = "ALERT" ]; then notify "RECOVERED bogus"; fi; echo OK >"$last_file" 2>/dev/null#' "$d/$WATCH"
expect_fail chk4 "$d" "chk4 fails when a verify error false-recovers"

echo "== chk5 negatives =="
# Drop --verify-only -> the helper would run a real rebuild.
d="$(new_fixture)"; sed -i 's#"\$bin" --verify-only#"\$bin"#' "$d/$WATCH"
expect_fail chk5 "$d" "chk5 fails when the helper is invoked without --verify-only (a real rebuild)"

echo "== chk6 negatives =="
d="$(new_fixture)"; sed -i '\#install .*sbin/szl-image-stale-watch#d' "$d/$INSTALL"
expect_fail chk6 "$d" "chk6 fails when install.sh stops installing the script"
d="$(new_fixture)"; sed -i '/systemctl enable --now szl-image-stale-watch.timer/d' "$d/$INSTALL"
expect_fail chk6 "$d" "chk6 fails when install.sh stops enabling the timer"

echo "== chk7 negatives =="
d="$(new_fixture)"; sed -i 's#szl-image-stale-watch#szl-image-RENAMED#g' "$d/$README"
expect_fail chk7 "$d" "chk7 fails when README no longer documents szl-image-stale-watch"

echo ""
echo "==================================================================="
echo "image-stale-watch-guard self-test: $PASS passed, $FAIL failed"
echo "==================================================================="
[ "$FAIL" -eq 0 ]
