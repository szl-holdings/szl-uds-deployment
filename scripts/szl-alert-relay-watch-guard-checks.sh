# Copyright 2026 SZL Holdings
# SPDX-License-Identifier: Apache-2.0
#
# szl-alert-relay-watch-guard-checks.sh — guard the `szl-alert-relay-watch` box
# guard (the alert-relay watchdog) from silently regressing.
#
# WHY THIS EXISTS
# `szl-alert-relay-watch` (box-scripts/sbin/szl-alert-relay-watch) runs every
# ~5 min and pages the team if the szl-alert-relay service itself is down — the
# relay is the SINGLE delivery path that flattens CI receipt-failure Slack
# webhooks into clean ntfy pushes, so if it dies, ALL those alerts vanish
# silently ("who watches the watcher"). Its value rests on a few fragile
# invariants that produce NO visible symptom when broken until the relay dies
# unnoticed:
#   * it still probes /relay/health for HTTP 200;
#   * it still probes the systemd unit is-active;
#   * it is EDGE-triggered via a signature file so it pages exactly once when the
#     relay goes down and once on RECOVERED, never every cycle;
#   * it always writes a fresh status file + heartbeat STATE log (so the
#     monitor-liveness meta-monitor can watch IT) and the notifier is FAIL-SOFT;
#   * it stays WIRED into install.sh (copied + timer enabled) and documented in
#     its README, or a box rebuild silently ships without the watchdog.
# This guard is a pure text/lint check (no relay) that asserts each invariant.
#
# The check logic is extracted here (out of the workflow) so it can be UNIT
# TESTED: szl-alert-relay-watch-guard-checks.test.sh feeds each check a
# deliberately-BROKEN fixture and asserts the check FAILS (plus that the pristine
# repo PASSES). A future edit that neuters a check is caught by that self-test.
#
# Usage:
#   szl-alert-relay-watch-guard-checks.sh <check> [root]
#     check : chk1 .. chk7 | all
#     root  : repo root to check (default: current directory)

set -uo pipefail

err() { echo "::error file=$1::$2"; }

WATCH_REL="box-scripts/sbin/szl-alert-relay-watch"
INSTALL_REL="box-scripts/install.sh"
README_REL="box-scripts/szl-alert-relay.README.md"

# ── Check 1 ── exists and parses clean ────────────────────────────────────────
chk1() {
  local root="${1:-.}"
  local F="$root/$WATCH_REL"
  test -f "$F" || {
    err "$F" "REGRESSION — szl-alert-relay-watch is MISSING. The alert-relay watchdog is gone."
    return 1
  }
  local out
  if ! out="$(bash -n "$F" 2>&1)"; then
    err "$F" "REGRESSION — szl-alert-relay-watch does not parse (bash -n failed)."
    echo "$out" | sed 's/^/       | /'
    return 1
  fi
  echo "OK: $F exists and parses clean (bash -n)"
}

# ── Check 2 ── still probes /relay/health for HTTP 200 ────────────────────────
chk2() {
  local root="${1:-.}"
  local F="$root/$WATCH_REL"
  test -f "$F" || { err "$F" "missing — required for the szl-alert-relay-watch guard"; return 1; }

  grep -Fq '/relay/health' "$F" || {
    err "$F" "REGRESSION — no longer probes the relay's /relay/health endpoint."
    err "$F" "A dead relay HTTP listener (alerts silently dropped) would go unalerted."
    return 1
  }
  grep -Fq '"$http_code" = "200"' "$F" || {
    err "$F" "REGRESSION — no longer requires HTTP 200 from /relay/health; a 5xx relay could go unalerted."
    return 1
  }
  echo "OK: probes /relay/health for HTTP 200"
}

# ── Check 3 ── still probes the systemd unit is-active ────────────────────────
chk3() {
  local root="${1:-.}"
  local F="$root/$WATCH_REL"
  test -f "$F" || { err "$F" "missing — required for the szl-alert-relay-watch guard"; return 1; }

  grep -Fq 'is-active "$RELAY_UNIT"' "$F" || {
    err "$F" "REGRESSION — no longer checks the relay systemd unit is-active."
    err "$F" "A crashed/inactive relay service would go unalerted."
    return 1
  }
  grep -Fq '"$unit_state" = "active"' "$F" || {
    err "$F" "REGRESSION — no longer requires the relay unit state to be 'active'."
    return 1
  }
  echo "OK: probes the relay systemd unit is-active"
}

# ── Check 4 ── edge-triggered via the signature file (exactly two pushes) ─────
chk4() {
  local root="${1:-.}"
  local F="$root/$WATCH_REL"
  test -f "$F" || { err "$F" "missing — required for the szl-alert-relay-watch guard"; return 1; }

  grep -Fq 'cat "$SIG_FILE"' "$F" || {
    err "$F" "REGRESSION — no longer READS the problem signature file; can't de-dupe a persisting outage."
    return 1
  }
  grep -Fq '>"$SIG_FILE"' "$F" || {
    err "$F" "REGRESSION — no longer WRITES the problem signature file; can't de-dupe a persisting outage."
    return 1
  }
  grep -Fq 'rm -f "$SIG_FILE"' "$F" || {
    err "$F" "REGRESSION — no longer CLEARS the signature on recovery; a fresh outage wouldn't re-alert."
    return 1
  }
  grep -Fq '"$cur_sig" = "$prev_sig"' "$F" || {
    err "$F" "REGRESSION — the persisting-outage de-dup comparison is gone; the alarm would re-page every cycle."
    return 1
  }
  grep -Fq '[ -n "$prev_sig" ]' "$F" || {
    err "$F" "REGRESSION — the RECOVERED edge guard ('\$prev_sig' non-empty) is gone."
    return 1
  }
  local n
  n="$(grep -Ec '^[[:space:]]+push "' "$F")"
  if [ "$n" -ne 2 ]; then
    err "$F" "REGRESSION — expected EXACTLY 2 push calls (one DOWN, one RECOVERED) but found $n."
    return 1
  fi
  echo "OK: edge-triggered via signature file (reads/writes/clears, de-dup + RECOVERED guard, exactly 2 pushes)"
}

# ── Check 5 ── always writes status + heartbeat; notifier fail-soft ───────────
chk5() {
  local root="${1:-.}"
  local F="$root/$WATCH_REL"
  test -f "$F" || { err "$F" "missing — required for the szl-alert-relay-watch guard"; return 1; }

  grep -Fq '>"$STATUS.tmp" && mv "$STATUS.tmp" "$STATUS"' "$F" || {
    err "$F" "REGRESSION — no longer atomically writes the status file every run."
    err "$F" "The monitor-liveness meta-monitor watches this status file's checked_at — losing it blinds the watcher-of-watchers."
    return 1
  }
  grep -Fq 'log "STATE overall=' "$F" || {
    err "$F" "REGRESSION — the heartbeat STATE log line is gone; liveness/history would be lost."
    return 1
  }
  grep -Fq '[ -z "$NOTIFY_CMD" ] && return 0' "$F" || {
    err "$F" "REGRESSION — the notifier is no longer FAIL-SOFT; a missing channel could break the run instead of just logging."
    return 1
  }
  echo "OK: always writes status (atomic) + heartbeat STATE log; notifier fail-soft"
}

# ── Check 6 ── wired into install.sh ──────────────────────────────────────────
chk6() {
  local root="${1:-.}"
  local F="$root/$INSTALL_REL"
  test -f "$F" || { err "$F" "missing — required for the szl-alert-relay-watch guard"; return 1; }

  grep -Eq 'install .*sbin/szl-alert-relay-watch' "$F" || {
    err "$F" "REGRESSION — install.sh no longer installs sbin/szl-alert-relay-watch."
    return 1
  }
  grep -Fq 'szl-alert-relay-watch.service' "$F" || {
    err "$F" "REGRESSION — install.sh no longer installs szl-alert-relay-watch.service."
    return 1
  }
  grep -Fq 'szl-alert-relay-watch.timer' "$F" || {
    err "$F" "REGRESSION — install.sh no longer installs szl-alert-relay-watch.timer."
    return 1
  }
  grep -Eq 'systemctl enable --now szl-alert-relay-watch\.timer' "$F" || {
    err "$F" "REGRESSION — install.sh no longer ENABLES szl-alert-relay-watch.timer; the watchdog wouldn't run after a rebuild."
    return 1
  }
  echo "OK: install.sh installs the script + units and enables the timer"
}

# ── Check 7 ── documented in its README ───────────────────────────────────────
chk7() {
  local root="${1:-.}"
  local F="$root/$README_REL"
  test -f "$F" || { err "$F" "missing — required for the szl-alert-relay-watch guard"; return 1; }

  grep -Fq 'szl-alert-relay-watch' "$F" || {
    err "$F" "REGRESSION — the README no longer documents szl-alert-relay-watch."
    return 1
  }
  grep -Fiq 'watch the relay' "$F" || {
    err "$F" "REGRESSION — the README lost the 'Watch the relay itself' section describing this watchdog."
    return 1
  }
  echo "OK: README documents the alert-relay watchdog"
}

# ── Dispatch ──────────────────────────────────────────────────────────────────
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  CHECK="${1:-all}"
  ROOT="${2:-.}"
  case "$CHECK" in
    chk1) chk1 "$ROOT" ;;
    chk2) chk2 "$ROOT" ;;
    chk3) chk3 "$ROOT" ;;
    chk4) chk4 "$ROOT" ;;
    chk5) chk5 "$ROOT" ;;
    chk6) chk6 "$ROOT" ;;
    chk7) chk7 "$ROOT" ;;
    all)
      rc=0
      for c in chk1 chk2 chk3 chk4 chk5 chk6 chk7; do "$c" "$ROOT" || rc=1; done
      exit "$rc"
      ;;
    *) echo "unknown check: $CHECK (want chk1..chk7|all)" >&2; exit 2 ;;
  esac
fi
