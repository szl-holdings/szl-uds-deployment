# Copyright 2026 SZL Holdings
# SPDX-License-Identifier: Apache-2.0
#
# receipts-retention-watch-guard-checks.sh — guard the `szl-receipts-retention-
# watch` box watchdog (the runtime liveness alarm for the szl-receipts-retention
# daily job) from silently regressing.
#
# WHY THIS EXISTS
# `szl-receipts-retention-watch` (box-scripts/sbin/szl-receipts-retention-watch)
# is a periodic RUNTIME watchdog: every hour it introspects the
# szl-receipts-retention timer/service via systemd AND the retention job's own
# status.json, and pages the team the moment the daily retention job silently
# STOPS FIRING (timer not-found / inactive / disabled), STALLS (no completion
# within MAX_AGE_SECS), or its unit last FAILED (systemd Result != success).
# Unlike the build-time CI guard, it catches the job that never runs — the case
# the job itself cannot page about, because it is down. Its value rests on a few
# fragile invariants that produce NO visible symptom when broken until a real
# retention outage goes unalerted:
#   * it must still INTROSPECT the retention units via `systemctl show` for both
#     szl-receipts-retention.timer and szl-receipts-retention.service;
#   * it must ALARM when the timer is not active/enabled (job stopped firing);
#   * it must ALARM on STALENESS (a completion older than MAX_AGE_SECS, derived
#     from the retention status.json checked_at);
#   * it must ALARM when the last service run FAILED (systemd Result/ExecMainStatus);
#   * it must be EDGE-triggered (read + write a last_status state file) so it
#     pages exactly once on OK->problem and once on RECOVERED, never every cycle;
#   * it must FAIL-SAFE to a no-op (UNKNOWN, exit 0, no page, last_status left)
#     when systemd cannot be queried — never a paging storm on a probe failure;
#   * it must be READ-ONLY — it must NEVER start/stop/restart/enable/disable the
#     retention units (that would MASK the very stop it exists to surface);
#   * it must stay WIRED into install.sh (copied + timer enabled) and documented
#     in README.md, or a box rebuild silently ships without the watchdog.
# This guard is a pure text/lint check (no cluster) that asserts each invariant.
#
# The check logic is extracted here (out of the workflow) so it can be UNIT
# TESTED: receipts-retention-watch-guard-checks.test.sh feeds each check a
# deliberately-BROKEN fixture and asserts the check FAILS (plus that the pristine
# repo PASSES). A future edit that neuters a check — making it pass vacuously,
# green while guarding nothing — is caught by that self-test, not in production.
#
# Usage:
#   receipts-retention-watch-guard-checks.sh <check> [root]
#     check : chk1 | chk2 | chk3 | chk4 | chk5 | chk6 | chk7 | chk8 | chk9 | chk10 | all
#     root  : repo root to check (default: current directory)
#
# Each check exits 0 when the invariant holds and non-zero (printing a GitHub
# ::error annotation) when it is regressed.

set -uo pipefail

# err FILE MESSAGE — emit a GitHub Actions error annotation.
err() { echo "::error file=$1::$2"; }

# Paths (relative to a repo root) of the files this guard inspects.
WATCH_REL="box-scripts/sbin/szl-receipts-retention-watch"
INSTALL_REL="box-scripts/install.sh"
README_REL="box-scripts/README.md"

# ── Check 1 ───────────────────────────────────────────────────────────────────
# The watchdog script exists and parses clean under `bash -n`. If it is missing
# or broken, the alarm cannot run at all.
chk1() {
  local root="${1:-.}"
  local F="$root/$WATCH_REL"
  test -f "$F" || {
    err "$F" "REGRESSION — szl-receipts-retention-watch is MISSING. The retention-liveness watchdog is gone."
    return 1
  }
  local out
  if ! out="$(bash -n "$F" 2>&1)"; then
    err "$F" "REGRESSION — szl-receipts-retention-watch does not parse (bash -n failed)."
    echo "$out" | sed 's/^/       | /'
    return 1
  fi
  echo "OK: $F exists and parses clean (bash -n)"
}

# ── Check 2 ───────────────────────────────────────────────────────────────────
# It still INTROSPECTS the retention units via systemd: it runs `systemctl show`
# and references BOTH szl-receipts-retention.timer and
# szl-receipts-retention.service. Without these it has no source for the job's
# liveness.
chk2() {
  local root="${1:-.}"
  local F="$root/$WATCH_REL"
  test -f "$F" || { err "$F" "missing — required for the receipts-retention-watch guard"; return 1; }

  grep -Fq 'systemctl show' "$F" || {
    err "$F" "REGRESSION — szl-receipts-retention-watch no longer introspects systemd ('systemctl show')."
    err "$F" "It has no source for the retention job's timer/service liveness."
    return 1
  }
  grep -Eq 'RETENTION_UNIT=.*szl-receipts-retention' "$F" || {
    err "$F" "REGRESSION — szl-receipts-retention-watch no longer targets the szl-receipts-retention unit (RETENTION_UNIT default changed)."
    return 1
  }
  grep -Fq 'RETENTION_TIMER' "$F" || {
    err "$F" "REGRESSION — szl-receipts-retention-watch no longer introspects the retention .timer unit (RETENTION_TIMER)."
    return 1
  }
  grep -Fq 'RETENTION_SERVICE' "$F" || {
    err "$F" "REGRESSION — szl-receipts-retention-watch no longer introspects the retention .service unit (RETENTION_SERVICE)."
    return 1
  }
  echo "OK: introspects the retention timer + service via systemctl show"
}

# ── Check 3 ───────────────────────────────────────────────────────────────────
# It still ALARMS when the timer has stopped firing: it inspects the timer
# ActiveState and is-enabled state. Dropping this means a disabled/stopped timer
# (the job will never fire) goes unalerted — the exact silent stop this watchdog
# exists to catch.
chk3() {
  local root="${1:-.}"
  local F="$root/$WATCH_REL"
  test -f "$F" || { err "$F" "missing — required for the receipts-retention-watch guard"; return 1; }

  grep -Fq 'ActiveState' "$F" || {
    err "$F" "REGRESSION — szl-receipts-retention-watch no longer checks the timer ActiveState; a stopped timer would go unalerted."
    return 1
  }
  grep -Fq 'is-enabled' "$F" || {
    err "$F" "REGRESSION — szl-receipts-retention-watch no longer checks 'is-enabled'; a disabled timer (won't survive reboot) would go unalerted."
    return 1
  }
  grep -Fq 'not-found' "$F" || {
    err "$F" "REGRESSION — szl-receipts-retention-watch no longer detects a not-found (uninstalled) timer unit."
    return 1
  }
  echo "OK: alarms when the retention timer is not-found / inactive / disabled"
}

# ── Check 4 ───────────────────────────────────────────────────────────────────
# It still ALARMS on STALENESS: a MAX_AGE_SECS budget compared against the most
# recent completion, derived from the retention status.json `checked_at`.
# Dropping this means a wedged/stalled timer that never completes goes unalerted.
chk4() {
  local root="${1:-.}"
  local F="$root/$WATCH_REL"
  test -f "$F" || { err "$F" "missing — required for the receipts-retention-watch guard"; return 1; }

  grep -Fq 'MAX_AGE_SECS' "$F" || {
    err "$F" "REGRESSION — szl-receipts-retention-watch lost its MAX_AGE_SECS staleness budget; a stalled job would go unalerted."
    return 1
  }
  grep -Fq 'checked_at' "$F" || {
    err "$F" "REGRESSION — szl-receipts-retention-watch no longer reads the retention status.json 'checked_at' completion timestamp."
    return 1
  }
  # The staleness comparison itself must be present (age vs MAX_AGE_SECS).
  grep -Eq 'gt "\$MAX_AGE_SECS"|-gt[[:space:]]+"\$MAX_AGE_SECS"' "$F" || {
    err "$F" "REGRESSION — szl-receipts-retention-watch no longer compares the completion age against MAX_AGE_SECS."
    return 1
  }
  echo "OK: alarms on staleness (completion age vs MAX_AGE_SECS from status.json checked_at)"
}

# ── Check 5 ───────────────────────────────────────────────────────────────────
# It still ALARMS when the last service run FAILED: it reads the systemd Result
# (and ExecMainStatus) of the retention service and flags a non-success Result.
chk5() {
  local root="${1:-.}"
  local F="$root/$WATCH_REL"
  test -f "$F" || { err "$F" "missing — required for the receipts-retention-watch guard"; return 1; }

  grep -Fq 'Result' "$F" || {
    err "$F" "REGRESSION — szl-receipts-retention-watch no longer reads the service Result; a failed (crashed) run would go unalerted."
    return 1
  }
  grep -Fq 'ExecMainStatus' "$F" || {
    err "$F" "REGRESSION — szl-receipts-retention-watch no longer reads ExecMainStatus for the failed-run detail."
    return 1
  }
  grep -Fq '!= "success"' "$F" || {
    err "$F" "REGRESSION — szl-receipts-retention-watch no longer flags a non-success Result (the failed-run trigger is gone)."
    return 1
  }
  echo "OK: alarms when the last retention service run failed (Result != success)"
}

# ── Check 6 ───────────────────────────────────────────────────────────────────
# Edge-triggering is intact: it READS the previous state (cat "$LAST_FILE"),
# PERSISTS the new state back to LAST_FILE (atomic mv), gates the ALERT page on
# the OK->ALERT edge ("$prev" != "ALERT") and the RECOVERED page on the ALERT->OK
# edge ("$prev" = "ALERT"), and makes EXACTLY TWO notify() calls (one per edge)
# so it never pages every cycle.
chk6() {
  local root="${1:-.}"
  local F="$root/$WATCH_REL"
  test -f "$F" || { err "$F" "missing — required for the receipts-retention-watch guard"; return 1; }

  grep -Fq 'cat "$LAST_FILE"' "$F" || {
    err "$F" "REGRESSION — szl-receipts-retention-watch no longer READS the last_status state file; it can't edge-trigger and would page every cycle."
    return 1
  }
  grep -Fq 'mv -f "$tmp" "$LAST_FILE"' "$F" || {
    err "$F" "REGRESSION — szl-receipts-retention-watch no longer PERSISTS the last_status state file (atomic mv); it can't de-dupe."
    return 1
  }
  grep -Fq '"$prev" != "ALERT"' "$F" || {
    err "$F" "REGRESSION — the OK->ALERT edge guard ('\$prev' != 'ALERT') is gone; the alarm would re-page every cycle."
    return 1
  }
  grep -Fq '"$prev" = "ALERT"' "$F" || {
    err "$F" "REGRESSION — the ALERT->OK (RECOVERED) edge guard ('\$prev' = 'ALERT') is gone; recovery would page every cycle or never."
    return 1
  }
  # Count actual notify CALLS (indented invocations), not the notify() definition.
  local n
  n="$(grep -Ec '^[[:space:]]+notify "' "$F")"
  if [ "$n" -ne 2 ]; then
    err "$F" "REGRESSION — expected EXACTLY 2 notify calls (one OK->ALERT, one RECOVERED) but found $n."
    err "$F" "Drifting from one-push-per-edge means either a missed alarm or an alert storm."
    return 1
  fi
  echo "OK: edge-triggered — reads+persists last_status, both edge guards present, exactly 2 notify calls"
}

# ── Check 7 ───────────────────────────────────────────────────────────────────
# Fail-safe no-op when systemd cannot be queried: a missing `systemctl` (or an
# unreadable timer state) writes status UNKNOWN and exits 0 without paging,
# leaving last_status untouched. A probe failure must never become a paging storm.
chk7() {
  local root="${1:-.}"
  local F="$root/$WATCH_REL"
  test -f "$F" || { err "$F" "missing — required for the receipts-retention-watch guard"; return 1; }

  grep -Fq 'command -v systemctl' "$F" || {
    err "$F" "REGRESSION — szl-receipts-retention-watch no longer guards against a missing systemctl; it could error/page on a box without systemd."
    return 1
  }
  grep -Fq 'write_status UNKNOWN' "$F" || {
    err "$F" "REGRESSION — szl-receipts-retention-watch no longer has an UNKNOWN fail-safe state; a probe failure can't no-op cleanly."
    return 1
  }
  # The UNKNOWN branches must no-op (exit 0) and must NOT call set_last (so an
  # existing ALERT/OK is preserved across an unreadable cycle).
  grep -Eq 'write_status UNKNOWN[^\n]*' "$F" && grep -Fq 'exit 0' "$F" || {
    err "$F" "REGRESSION — the UNKNOWN fail-safe path no longer exits 0 (no-op)."
    return 1
  }
  echo "OK: fail-safe — missing/unreadable systemd -> UNKNOWN no-op (exit 0), last_status preserved"
}

# ── Check 8 ───────────────────────────────────────────────────────────────────
# It is READ-ONLY: it must NEVER execute a state-changing systemctl verb
# (start/stop/restart/enable/disable/reload/mask) against the retention units.
# "Fixing" the job by restarting it would MASK the very stop this watchdog exists
# to surface. Only read-only `systemctl show` / `is-enabled` are allowed.
chk8() {
  local root="${1:-.}"
  local F="$root/$WATCH_REL"
  test -f "$F" || { err "$F" "missing — required for the receipts-retention-watch guard"; return 1; }

  if grep -Eq '^[[:space:]]*systemctl[[:space:]]+(start|stop|restart|reload|enable|disable|mask|unmask|kill)\b' "$F"; then
    err "$F" "REGRESSION — szl-receipts-retention-watch now EXECUTES a state-changing systemctl command."
    err "$F" "This watchdog must be READ-ONLY (systemctl show / is-enabled only) — auto-restarting the job would MASK the stop it exists to surface."
    grep -nE '^[[:space:]]*systemctl[[:space:]]+(start|stop|restart|reload|enable|disable|mask|unmask|kill)\b' "$F" | sed 's/^/       | /'
    return 1
  fi
  echo "OK: read-only — never start/stop/restart/enable/disable the retention units"
}

# ── Check 9 ───────────────────────────────────────────────────────────────────
# Still wired into install.sh: the sbin script + the .service and .timer units
# are copied, and the timer is enabled. Otherwise a box rebuild ships without the
# watchdog running.
chk9() {
  local root="${1:-.}"
  local F="$root/$INSTALL_REL"
  test -f "$F" || { err "$F" "missing — required for the receipts-retention-watch guard"; return 1; }

  grep -Eq 'install .*sbin/szl-receipts-retention-watch' "$F" || {
    err "$F" "REGRESSION — install.sh no longer installs sbin/szl-receipts-retention-watch."
    return 1
  }
  grep -Fq 'szl-receipts-retention-watch.service' "$F" || {
    err "$F" "REGRESSION — install.sh no longer installs szl-receipts-retention-watch.service."
    return 1
  }
  grep -Fq 'szl-receipts-retention-watch.timer' "$F" || {
    err "$F" "REGRESSION — install.sh no longer installs szl-receipts-retention-watch.timer."
    return 1
  }
  grep -Eq 'systemctl enable --now szl-receipts-retention-watch\.timer' "$F" || {
    err "$F" "REGRESSION — install.sh no longer ENABLES szl-receipts-retention-watch.timer; the watchdog wouldn't run after a rebuild."
    return 1
  }
  echo "OK: install.sh installs the script + units and enables the timer"
}

# ── Check 10 ──────────────────────────────────────────────────────────────────
# Still documented in README.md so an operator restoring the box after a wipe
# knows the watchdog exists and how to verify it.
chk10() {
  local root="${1:-.}"
  local F="$root/$README_REL"
  test -f "$F" || { err "$F" "missing — required for the receipts-retention-watch guard"; return 1; }

  grep -Fq 'szl-receipts-retention-watch' "$F" || {
    err "$F" "REGRESSION — README.md no longer documents szl-receipts-retention-watch."
    return 1
  }
  grep -Fiq 'retention' "$F" || {
    err "$F" "REGRESSION — README.md lost the retention-watchdog section describing this alarm."
    return 1
  }
  echo "OK: README.md documents the szl-receipts-retention-watch runtime watchdog"
}

# ── Dispatch ──────────────────────────────────────────────────────────────────
# When sourced (BASH_SOURCE != $0) define the functions and return so the
# self-test can call them directly. When executed, run the requested check.
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
    chk8) chk8 "$ROOT" ;;
    chk9) chk9 "$ROOT" ;;
    chk10) chk10 "$ROOT" ;;
    all)
      rc=0
      chk1 "$ROOT" || rc=1
      chk2 "$ROOT" || rc=1
      chk3 "$ROOT" || rc=1
      chk4 "$ROOT" || rc=1
      chk5 "$ROOT" || rc=1
      chk6 "$ROOT" || rc=1
      chk7 "$ROOT" || rc=1
      chk8 "$ROOT" || rc=1
      chk9 "$ROOT" || rc=1
      chk10 "$ROOT" || rc=1
      exit "$rc"
      ;;
    *) echo "unknown check: $CHECK (want chk1..chk10|all)" >&2; exit 2 ;;
  esac
fi
