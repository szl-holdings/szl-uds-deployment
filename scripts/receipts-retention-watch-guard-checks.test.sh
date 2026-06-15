# Copyright 2026 SZL Holdings
# SPDX-License-Identifier: Apache-2.0
#
# receipts-retention-watch-guard-checks.test.sh — negative-fixture self-test for
# the receipts-retention-watch guard
# (scripts/receipts-retention-watch-guard-checks.sh).
#
# WHY THIS EXISTS
# The guard enforces the szl-receipts-retention-watch watchdog's invariants
# entirely with hand-written grep. If one of those checks breaks (a regex typo, a
# bad anchor) it can PASS VACUOUSLY — green while guarding nothing. This test
# feeds each check a deliberately-BROKEN fixture and asserts the check FAILS,
# plus asserts the pristine repo PASSES. A future edit that neuters a check is
# caught here in CI.
#
# It sources the EXACT script the workflow runs (so chk1..chk10 are the real
# functions) and runs them against fixtures built from the real source files.
#
# Usage: bash scripts/receipts-retention-watch-guard-checks.test.sh
# Exit 0 if every case behaves as expected, 1 otherwise.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
CHECKS="$HERE/receipts-retention-watch-guard-checks.sh"

# shellcheck source=/dev/null
source "$CHECKS"

PASS=0
FAIL=0
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

# Source files the guard inspects, relative to a repo root.
SRC_FILES=(
  "box-scripts/sbin/szl-receipts-retention-watch"
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

WATCH="box-scripts/sbin/szl-receipts-retention-watch"
INSTALL="box-scripts/install.sh"
README="box-scripts/README.md"

echo "== pristine repo: every check passes =="
expect_pass chk1 "$REPO_ROOT" "chk1 watch script present + parses"
expect_pass chk2 "$REPO_ROOT" "chk2 introspects retention timer/service via systemctl show"
expect_pass chk3 "$REPO_ROOT" "chk3 alarms on timer not-active/enabled"
expect_pass chk4 "$REPO_ROOT" "chk4 alarms on staleness (MAX_AGE_SECS vs checked_at)"
expect_pass chk5 "$REPO_ROOT" "chk5 alarms on failed last run (Result != success)"
expect_pass chk6 "$REPO_ROOT" "chk6 edge-trigger state + 2 notify calls"
expect_pass chk7 "$REPO_ROOT" "chk7 fail-safe UNKNOWN no-op"
expect_pass chk8 "$REPO_ROOT" "chk8 read-only (never start/stop/restart)"
expect_pass chk9 "$REPO_ROOT" "chk9 wired into install.sh"
expect_pass chk10 "$REPO_ROOT" "chk10 documented in README.md"

echo "== chk1 negatives =="
d="$(new_fixture)"; rm -f "$d/$WATCH"
expect_fail chk1 "$d" "chk1 fails when the watch script is missing"

d="$(new_fixture)"; printf 'if [ \n' > "$d/$WATCH"
expect_fail chk1 "$d" "chk1 fails when the watch script has a syntax error"

echo "== chk2 negatives =="
d="$(new_fixture)"; sed -i 's#systemctl show#systemctl DISABLED#g' "$d/$WATCH"
expect_fail chk2 "$d" "chk2 fails when systemctl show is dropped"

d="$(new_fixture)"; sed -i 's#RETENTION_UNIT="${RETENTION_UNIT:-szl-receipts-retention}"#RETENTION_UNIT="${RETENTION_UNIT:-other}"#' "$d/$WATCH"
expect_fail chk2 "$d" "chk2 fails when RETENTION_UNIT default is changed away from szl-receipts-retention"

d="$(new_fixture)"; sed -i 's#RETENTION_TIMER#RT_GONE#g' "$d/$WATCH"
expect_fail chk2 "$d" "chk2 fails when the timer introspection variable is dropped"

d="$(new_fixture)"; sed -i 's#RETENTION_SERVICE#RS_GONE#g' "$d/$WATCH"
expect_fail chk2 "$d" "chk2 fails when the service introspection variable is dropped"

echo "== chk3 negatives =="
d="$(new_fixture)"; sed -i 's#ActiveState#ActiveSomethingElse#g' "$d/$WATCH"
expect_fail chk3 "$d" "chk3 fails when the timer ActiveState check is dropped"

d="$(new_fixture)"; sed -i 's#is-enabled#is-DISABLED#g' "$d/$WATCH"
expect_fail chk3 "$d" "chk3 fails when the is-enabled check is dropped"

d="$(new_fixture)"; sed -i 's#not-found#NOTGONE#g' "$d/$WATCH"
expect_fail chk3 "$d" "chk3 fails when the not-found (uninstalled) detection is dropped"

echo "== chk4 negatives =="
d="$(new_fixture)"; sed -i 's#MAX_AGE_SECS#MAX_AGE_GONE#g' "$d/$WATCH"
expect_fail chk4 "$d" "chk4 fails when MAX_AGE_SECS is removed"

d="$(new_fixture)"; sed -i 's#checked_at#checked_GONE#g' "$d/$WATCH"
expect_fail chk4 "$d" "chk4 fails when the status.json checked_at read is removed"

d="$(new_fixture)"; sed -i 's#-gt "$MAX_AGE_SECS"#-gt 999999999#g' "$d/$WATCH"
expect_fail chk4 "$d" "chk4 fails when the age-vs-MAX_AGE_SECS comparison is broken"

echo "== chk5 negatives =="
d="$(new_fixture)"; sed -i 's#Result#Rezult#g' "$d/$WATCH"
expect_fail chk5 "$d" "chk5 fails when the service Result read is dropped"

d="$(new_fixture)"; sed -i 's#ExecMainStatus#ExecGone#g' "$d/$WATCH"
expect_fail chk5 "$d" "chk5 fails when ExecMainStatus is dropped"

d="$(new_fixture)"; sed -i 's#!= "success"#== "x"#g' "$d/$WATCH"
expect_fail chk5 "$d" "chk5 fails when the non-success trigger is removed"

echo "== chk6 negatives =="
d="$(new_fixture)"; sed -i 's#prev="$(cat "$LAST_FILE" 2>/dev/null || echo OK)"#prev=OK#' "$d/$WATCH"
expect_fail chk6 "$d" "chk6 fails when the last_status read is removed"

d="$(new_fixture)"; sed -i 's#mv -f "$tmp" "$LAST_FILE" 2>/dev/null##g' "$d/$WATCH"
expect_fail chk6 "$d" "chk6 fails when the last_status persist is removed"

d="$(new_fixture)"; sed -i 's#if \[ "$prev" != "ALERT" \]; then#if true; then#' "$d/$WATCH"
expect_fail chk6 "$d" "chk6 fails when the OK->ALERT edge guard is removed"

# Remove the RECOVERED notify call -> count drops to 1 (not exactly 2).
d="$(new_fixture)"; sed -i '/notify "RECOVERED:/d' "$d/$WATCH"
expect_fail chk6 "$d" "chk6 fails when the RECOVERED notify call is removed"

# Add an unconditional extra notify -> count rises to 3 (alarm-storm risk).
d="$(new_fixture)"; sed -i 's#^exit 0#  notify "spurious extra page"\nexit 0#' "$d/$WATCH"
expect_fail chk6 "$d" "chk6 fails when an extra notify call is added"

echo "== chk7 negatives =="
d="$(new_fixture)"; sed -i 's#command -v systemctl#command -v NOPE#g' "$d/$WATCH"
expect_fail chk7 "$d" "chk7 fails when the missing-systemctl fail-safe is removed"

d="$(new_fixture)"; sed -i 's#write_status UNKNOWN#write_status OK#g' "$d/$WATCH"
expect_fail chk7 "$d" "chk7 fails when the UNKNOWN no-op state is removed"

echo "== chk8 negatives =="
# Inject an actual state-changing systemctl command.
d="$(new_fixture)"; sed -i 's#^exit 0#  systemctl restart szl-receipts-retention.timer\nexit 0#' "$d/$WATCH"
expect_fail chk8 "$d" "chk8 fails when a state-changing systemctl restart is added"

echo "== chk9 negatives =="
d="$(new_fixture)"; sed -i '\#install .*sbin/szl-receipts-retention-watch#d' "$d/$INSTALL"
expect_fail chk9 "$d" "chk9 fails when install.sh stops installing the script"

d="$(new_fixture)"; sed -i '/systemctl enable --now szl-receipts-retention-watch.timer/d' "$d/$INSTALL"
expect_fail chk9 "$d" "chk9 fails when install.sh stops enabling the timer"

echo "== chk10 negatives =="
d="$(new_fixture)"; sed -i 's#szl-receipts-retention-watch#szl-receipts-retention-RENAMED#g' "$d/$README"
expect_fail chk10 "$d" "chk10 fails when README no longer documents szl-receipts-retention-watch"

echo ""
echo "==================================================================="
echo "receipts-retention-watch-guard self-test: $PASS passed, $FAIL failed"
echo "==================================================================="
[ "$FAIL" -eq 0 ]
