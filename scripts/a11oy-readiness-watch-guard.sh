#!/usr/bin/env bash
# Copyright 2026 SZL Holdings
# SPDX-License-Identifier: Apache-2.0
#
# a11oy-readiness-watch-guard.sh — drive the REAL a11oy-readiness-watch alarm
# end-to-end against a throwaway state dir and a stubbed verify result, and
# assert every behaviour that matters when the a11oy Operational Readiness page
# stops loading through the secure gateway:
#
#   * healthy (verify exit 0)        -> NO page, status overall=OK
#   * failure edge (verify exit 1)   -> exactly ONE ALERT push, carrying the
#                                       FAIL text from the verify output
#   * persisting failure (same sig)  -> de-duped, no repeat push
#   * RECOVERED (verify exit 0 again) -> one RECOVERED push, sig cleared
#   * grace window (THRESHOLD high)   -> a fresh failure logs (pending), NO page
#   * cluster down (verify exit 99)   -> NO-OP, NO page (never a false alert)
#
# It RUNS the real watcher (box-scripts/sbin/a11oy-readiness-watch) via its
# overridable env seams (STATE_DIR/LOG_DIR/THRESHOLD_SECS, NOTIFY_CMD=cat,
# ALERT_PREFIX, VERIFY_CMD) — no cluster, no root, no k3d. The negative-fixture
# self-test (a11oy-readiness-watch-guard.test.sh) points it at deliberately
# broken copies to prove these assertions actually bite.
#
# Usage: bash scripts/a11oy-readiness-watch-guard.sh [path-to-watcher]
# Exit 0 if every assertion holds, 1 otherwise.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
WATCH="${1:-$REPO_ROOT/box-scripts/sbin/a11oy-readiness-watch}"

if [ ! -r "$WATCH" ]; then
  echo "FATAL watcher not found/readable: $WATCH" >&2
  exit 1
fi

PASS=0
FAIL=0
ok()  { echo "ok   $*"; PASS=$((PASS+1)); }
bad() { echo "FAIL $*"; FAIL=$((FAIL+1)); }

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
STATE="$T/state"
LOGD="$T/log"
LOG="$LOGD/a11oy-readiness-watch.log"
mkdir -p "$STATE" "$LOGD"

# Stubbed verify outputs.
FAIL_OUT='printf "  PASS  authservice is Ready\n  FAIL  Keycloak not Ready\n  FAIL  Readiness endpoint returned 503 through admin gateway\nSUMMARY: pass=6 fail=2 warn=0\n"; exit 1'
OK_OUT='printf "  PASS  Keycloak is Ready\n  PASS  Readiness endpoint 200 through admin gateway\nSUMMARY: pass=8 fail=0 warn=1\n"; exit 0'
DOWN_OUT='echo "cluster absent"; exit 99'

# run VERIFY_CMD THRESHOLD -> run the real watcher once; alert lines (ALERT/
# RECOVERED, prefixed) land in the log via NOTIFY_CMD=cat.
run() {
  local vcmd="$1" thr="$2"
  STATE_DIR="$STATE" LOG_DIR="$LOGD" LOG="$LOG" \
  THRESHOLD_SECS="$thr" NOTIFY_CMD=cat ALERT_PREFIX="[TEST-ignore] " \
  VERIFY_CMD="$vcmd" bash "$WATCH" >/dev/null 2>&1
}

# Count pushed lines of a given kind currently in the log. The notifier is
# `cat`, so a real push appears as a "[TEST-ignore] <KIND> ..." line; heartbeat
# STATE/(pending)/(persisting) log lines are NOT pushed, so they never match.
count_push() { grep -c "\[TEST-ignore\] $1" "$LOG" 2>/dev/null || true; }

reset_log() { : > "$LOG"; }

# Watcher must parse.
bash -n "$WATCH" || { echo "FATAL watcher does not parse" >&2; exit 1; }

# ── 1. healthy -> no page ────────────────────────────────────────────────────
reset_log
run "$OK_OUT" 0
if [ "$(count_push 'a11oy Operational Readiness')" = "0" ]; then
  ok "healthy run pages nobody"
else
  bad "healthy run pushed an alert (should be silent)"
fi
if grep -q '"overall": "OK"' "$STATE/status.json" 2>/dev/null; then
  ok "healthy run writes status overall=OK"
else
  bad "healthy run did not write overall=OK status"
fi

# ── 2. failure edge -> exactly one ALERT carrying the FAIL text ──────────────
reset_log
run "$FAIL_OUT" 0
n="$(count_push 'a11oy Operational Readiness DOWN')"
if [ "$n" = "1" ]; then ok "failure edge fires exactly one ALERT"
else bad "failure edge fired $n ALERTs (want 1)"; fi
if grep -q 'Keycloak not Ready' "$LOG" && grep -q 'Readiness endpoint returned 503' "$LOG"; then
  ok "ALERT message carries the verify FAIL text"
else
  bad "ALERT message is missing the verify FAIL text"
fi
if grep -q '"overall": "DOWN"' "$STATE/status.json" 2>/dev/null; then
  ok "failure run writes status overall=DOWN"
else
  bad "failure run did not write overall=DOWN status"
fi

# ── 3. persisting failure -> de-duped (no second page) ───────────────────────
reset_log
run "$FAIL_OUT" 0
if [ "$(count_push 'a11oy Operational Readiness DOWN')" = "0" ]; then
  ok "persisting identical failure is de-duped (no repeat page)"
else
  bad "persisting failure re-paged (de-dup broken)"
fi

# ── 4. RECOVERED -> one recovery page, sig cleared ───────────────────────────
reset_log
run "$OK_OUT" 0
if [ "$(count_push 'a11oy Operational Readiness RECOVERED')" = "1" ]; then
  ok "recovery after an alert fires exactly one RECOVERED page"
else
  bad "recovery did not fire a single RECOVERED page"
fi
# A second healthy run must NOT re-announce RECOVERED.
reset_log
run "$OK_OUT" 0
if [ "$(count_push 'a11oy Operational Readiness RECOVERED')" = "0" ]; then
  ok "RECOVERED is not re-announced once cleared"
else
  bad "RECOVERED re-announced on a steady-healthy run"
fi

# ── 5. grace window -> a fresh failure does NOT page yet ──────────────────────
rm -rf "$STATE"; mkdir -p "$STATE"   # fresh state (no prior unhealthy_since)
reset_log
run "$FAIL_OUT" 99999
if [ "$(count_push 'a11oy Operational Readiness DOWN')" = "0" ] \
   && grep -q '(pending ' "$LOG"; then
  ok "grace window holds a fresh failure (pending, no page)"
else
  bad "grace window did not suppress the first failure page"
fi

# ── 6. cluster down (verify exit 99) -> NO-OP, no page ───────────────────────
rm -rf "$STATE"; mkdir -p "$STATE"
reset_log
run "$DOWN_OUT" 0
if [ "$(count_push 'a11oy Operational Readiness')" = "0" ] \
   && grep -q 'no-op' "$LOG"; then
  ok "cluster-down (exit 99) is a no-op, never a false page"
else
  bad "cluster-down did not behave as a silent no-op"
fi
# And: cluster-down AFTER an alert must NOT emit a false RECOVERED.
reset_log
run "$FAIL_OUT" 0 >/dev/null 2>&1    # raise an alert first
reset_log
run "$DOWN_OUT" 0
if [ "$(count_push 'a11oy Operational Readiness RECOVERED')" = "0" ]; then
  ok "cluster-down after an alert does not emit a false RECOVERED"
else
  bad "cluster-down emitted a false RECOVERED"
fi

echo ""
echo "==================================================================="
echo "a11oy-readiness-watch-guard: $PASS passed, $FAIL failed"
echo "==================================================================="
[ "$FAIL" -eq 0 ]
