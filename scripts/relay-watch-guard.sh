# Copyright 2026 SZL Holdings
# SPDX-License-Identifier: Apache-2.0
#
# relay-watch-guard.sh — drive the REAL szl-alert-relay-watch edge-alert watcher
# end-to-end against a stubbed relay and assert its alerting, de-dup, RECOVERED
# and status behaviour.
#
# WHY THIS EXISTS
# box-scripts/sbin/szl-alert-relay-watch pages the team when the szl-alert-relay
# service itself is down — the relay is the SINGLE delivery path that flattens CI
# receipt-failure Slack webhooks into clean ntfy pushes, so if it dies, ALL those
# alerts vanish silently ("who watches the watcher"). The watcher's value rides on
# behaviour that has NO visible symptom when broken until a real relay outage goes
# unpaged (or a persisting outage turns into a paging storm):
#   * EDGE alert: page once on OK->DOWN, never every cycle (signature de-dup);
#   * page once on RECOVERED and CLEAR the signature so a fresh outage re-alerts;
#   * a dead systemd unit (relay crashed) is paged even when the HTTP probe could
#     still answer cleanly;
#   * a healthy relay pages nothing and reports overall=OK.
# The existing scripts/szl-alert-relay-watch-guard-checks.sh is a STATIC text/lint
# check; this guard RUNS the real watcher end-to-end against a fake curl + fake
# systemctl (no real box, no root, never touches the live relay) and asserts the
# actual alert/de-dup/RECOVERED behaviour.
#
# Usage: bash scripts/relay-watch-guard.sh [path-to-watcher]
#   The negative-fixture self-test points it at deliberately-broken copies.
# Exit 0 if every assertion holds, 1 otherwise.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
SCRIPT="${1:-$REPO_ROOT/box-scripts/sbin/szl-alert-relay-watch}"

if [ ! -r "$SCRIPT" ]; then
  echo "FATAL szl-alert-relay-watch script not found/readable: $SCRIPT" >&2
  exit 1
fi

PASS=0; FAIL=0
ok()  { echo "ok   $*"; PASS=$((PASS+1)); }
bad() { echo "FAIL $*"; FAIL=$((FAIL+1)); }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
BIN="$T/bin"; CTRL="$T/ctrl"; STATE="$T/state"; LOGD="$T/log"
mkdir -p "$BIN" "$CTRL" "$STATE" "$LOGD"

# ---- stub the relay's two probes -------------------------------------------
# Fake curl: ignore every arg, print the HTTP code from the control dir to stdout
# (the watcher captures stdout via `-w '%{http_code}'`). Default 200 = healthy.
cat > "$BIN/curl" <<'STUB'
#!/usr/bin/env bash
cat "${STUB_CTRL}/http_code" 2>/dev/null || echo 200
exit 0
STUB
# Fake systemctl: answer `is-active <unit>` from the control dir. Default active.
cat > "$BIN/systemctl" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = "is-active" ]; then
  cat "${STUB_CTRL}/unit_state" 2>/dev/null || echo active
  exit 0
fi
exit 0
STUB
chmod +x "$BIN/curl" "$BIN/systemctl"

LOG="$LOGD/watch.log"
STATUS="$STATE/status.json"
SIG="$STATE/problem.sig"

# run — drive the real watcher. STATE persists across runs (so edge/de-dup work);
# the LOG is truncated each run so each cycle's pushes are isolated. NOTIFY_CMD=cat
# routes every push() into the LOG, distinguished from log() lines by ALERT_PREFIX
# which only push() prepends — so a real PAGE is detectable separately from the
# always-present heartbeat/STATE log lines.
run() {
  : > "$LOG"
  env PATH="$BIN:$PATH" STUB_CTRL="$CTRL" \
    CURL_BIN=curl SYSTEMCTL_BIN=systemctl \
    HEALTH_URL="https://relay.test/relay/health" RELAY_UNIT="szl-alert-relay.service" \
    STATE_DIR="$STATE" LOG_DIR="$LOGD" LOG="$LOG" STATUS="$STATUS" SIG_FILE="$SIG" \
    NOTIFY_CMD=cat ALERT_PREFIX="[TEST-ignore] " \
    bash "$SCRIPT" >/dev/null 2>&1
}
paged_down()      { grep -q '\[TEST-ignore\] .*ALERT-RELAY DOWN' "$LOG"; }
paged_recovered() { grep -q '\[TEST-ignore\] .*alert-relay RECOVERED' "$LOG"; }
status_is()       { grep -q "\"overall\": \"$1\"" "$STATUS"; }
alerting_is()     { grep -q "\"alerting\": $1" "$STATUS"; }

set_health() { printf '%s' "$1" > "$CTRL/http_code"; }
set_unit()   { printf '%s' "$1" > "$CTRL/unit_state"; }
healthy()    { set_health 200; set_unit active; }
fresh_state(){ rm -f "$SIG" "$STATUS" 2>/dev/null; }

echo "== Phase A: healthy relay -> overall=OK, no page =="
fresh_state; healthy
run
if status_is OK;        then ok "A1 healthy relay -> overall=OK"; else bad "A1 status not OK"; fi
if alerting_is false;   then ok "A2 status alerting=false"; else bad "A2 alerting not false"; fi
if ! paged_down && ! paged_recovered; then ok "A3 healthy relay pages nothing"; else bad "A3 paged on a healthy relay"; fi
if [ ! -f "$SIG" ];     then ok "A4 no signature file written when healthy"; else bad "A4 signature written on a healthy run"; fi

echo "== Phase B: relay /relay/health 503 -> ALERT page on the edge =="
healthy; set_health 503
run
if paged_down;          then ok "B1 down edge fires exactly one ALERT page"; else bad "B1 no ALERT on the down edge"; fi
if status_is DOWN;      then ok "B2 status.json overall=DOWN"; else bad "B2 status not DOWN"; fi
if alerting_is true;    then ok "B3 status alerting=true"; else bad "B3 alerting not true"; fi
if [ -f "$SIG" ];       then ok "B4 signature file written (de-dup latch)"; else bad "B4 no signature latched"; fi

echo "== Phase C: outage persists -> de-duped (no repeat page) =="
run
if ! paged_down;        then ok "C1 persisting outage does NOT re-page (edge de-dup)"; else bad "C1 re-paged on a persisting outage"; fi
if status_is DOWN;      then ok "C2 still overall=DOWN while down"; else bad "C2 status flipped off DOWN while still down"; fi

echo "== Phase D: relay recovers -> RECOVERED page once, signature cleared =="
healthy
run
if paged_recovered;     then ok "D1 recovery fires a RECOVERED page"; else bad "D1 no RECOVERED page on recovery"; fi
if status_is OK;        then ok "D2 status back to OK"; else bad "D2 status not OK after recovery"; fi
if [ ! -f "$SIG" ];     then ok "D3 signature cleared on recovery"; else bad "D3 signature not cleared after recovery"; fi

echo "== Phase E: healthy again after recovery -> recovery is de-duped too =="
run
if ! paged_recovered && ! paged_down; then ok "E1 second healthy run pages nothing (recovery de-duped)"; else bad "E1 re-paged after recovery (signature not cleared)"; fi

echo "== Phase F: relay HTTP ok but systemd unit dead -> ALERT page =="
fresh_state; set_health 200; set_unit failed
run
if paged_down;          then ok "F1 a crashed relay unit pages even when HTTP answers"; else bad "F1 no ALERT for a dead relay unit"; fi
if status_is DOWN;      then ok "F2 dead-unit -> overall=DOWN"; else bad "F2 status not DOWN for a dead unit"; fi

echo ""
echo "==================================================================="
echo "szl-alert-relay-watch e2e guard: $PASS passed, $FAIL failed"
echo "==================================================================="
[ "$FAIL" -eq 0 ]
