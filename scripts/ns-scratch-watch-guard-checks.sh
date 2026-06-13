# Copyright 2026 SZL Holdings
# SPDX-License-Identifier: Apache-2.0
#
# ns-scratch-watch-guard-checks.sh — guard the `szl-ns-scratch-watch` box guard
# (the untracked scratch-namespace alarm) from silently regressing.
#
# WHY THIS EXISTS
# `szl-ns-scratch-watch` (box-scripts/sbin/szl-ns-scratch-watch) is a periodic
# alarm: every ~10 min it wraps `szl-ns-scratch list-unlabeled` and pages the
# team the moment an UNKNOWN (unmanaged + unlabeled) scratch namespace appears on
# the uds-szl-demo cluster, so it gets labeled or removed while it is still
# obvious who made it — before a later cleanup mistakes it for live work (a
# mistake that once nearly destroyed active work). Its value depends on a few
# fragile invariants that are easy to break with a well-meaning refactor and that
# produce NO visible symptom until a real drift goes unalerted:
#   * it must still ASK the audit tool (`szl-ns-scratch list-unlabeled`);
#   * it must be EDGE-triggered (read + write a last_status state file) so it
#     pages exactly once on OK->problem and once on RECOVERED, never every cycle;
#   * it must NO-OP (exit 0, no page) when the cluster is absent/unreachable, or
#     a stopped k3d cluster turns into a paging storm;
#   * it must stay WIRED into install.sh (copied + timer enabled) and documented
#     in README.md, or a box rebuild silently ships without the alarm.
#
# The static checks (chk1..chk6) are a pure text/lint pass (no cluster). chk7/chk8
# go further and EXERCISE the real script through the SHARED alarm-guard harness
# (scripts/lib/alarm-guard-sandbox.sh): they build a hermetic sandbox (stub
# k3d/kubectl, a fake `szl-ns-scratch list-unlabeled`, a capturing notifier) and
# run the alarm against fixture scenarios, asserting the observed edge lifecycle
# and no-op safety. That harness is the same one ns-scratch-stale-watch-guard
# uses, so the two scratch-namespace alarms share one sandbox + runner.
#
# The check logic is extracted here (out of the workflow) so it can be UNIT
# TESTED: ns-scratch-watch-guard-checks.test.sh feeds each check a
# deliberately-BROKEN fixture and asserts the check FAILS (plus that the pristine
# repo PASSES). A future edit that neuters a check — making it pass vacuously,
# green while guarding nothing — is caught by that self-test, not in production.
#
# Usage:
#   ns-scratch-watch-guard-checks.sh <check> [root]
#     check : chk1 | chk2 | chk3 | chk4 | chk5 | chk6 | chk7 | chk8 | all
#     root  : repo root to check (default: current directory)
#
# Each check exits 0 when the invariant holds and non-zero (printing a GitHub
# ::error annotation) when it is regressed.

set -uo pipefail

# Shared hermetic sandbox + edge-lifecycle / no-op runners (defines err,
# _mk_sandbox, _run, _pages, _alarm_edge_lifecycle, _alarm_noop_safety).
# shellcheck source=scripts/lib/alarm-guard-sandbox.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/alarm-guard-sandbox.sh"

# Paths (relative to a repo root) of the files this guard inspects.
WATCH_REL="box-scripts/sbin/szl-ns-scratch-watch"
INSTALL_REL="box-scripts/install.sh"
README_REL="box-scripts/README.md"

# ── Check 1 ───────────────────────────────────────────────────────────────────
# The guard script exists and parses clean under `bash -n`. If it is missing or
# broken, the alarm cannot run at all.
chk1() {
  local root="${1:-.}"
  local F="$root/$WATCH_REL"
  test -f "$F" || {
    err "$F" "REGRESSION — szl-ns-scratch-watch is MISSING. The untracked scratch-namespace alarm is gone."
    return 1
  }
  local out
  if ! out="$(bash -n "$F" 2>&1)"; then
    err "$F" "REGRESSION — szl-ns-scratch-watch does not parse (bash -n failed)."
    echo "$out" | sed 's/^/       | /'
    return 1
  fi
  echo "OK: $F exists and parses clean (bash -n)"
}

# ── Check 2 ───────────────────────────────────────────────────────────────────
# It still shells out to the audit tool with `list-unlabeled` — the only source
# of the UNKNOWN/risky namespace set. Without this the alarm has nothing to judge.
chk2() {
  local root="${1:-.}"
  local F="$root/$WATCH_REL"
  test -f "$F" || { err "$F" "missing — required for the ns-scratch-watch guard"; return 1; }

  grep -Fq 'list-unlabeled' "$F" || {
    err "$F" "REGRESSION — szl-ns-scratch-watch no longer invokes 'szl-ns-scratch list-unlabeled'."
    err "$F" "It has no source for the UNKNOWN (unmanaged + unlabeled) scratch-namespace set to alarm on."
    return 1
  }
  # The list-unlabeled call must run against the audit binary (SCRATCH_BIN), not
  # be a stray comment/log mention.
  grep -Eq '"\$SCRATCH_BIN"[[:space:]]+list-unlabeled' "$F" || {
    err "$F" "REGRESSION — 'list-unlabeled' is no longer executed via \$SCRATCH_BIN (the szl-ns-scratch tool)."
    return 1
  }
  echo "OK: szl-ns-scratch-watch shells out to \$SCRATCH_BIN list-unlabeled"
}

# ── Check 3 ───────────────────────────────────────────────────────────────────
# Edge-triggering is intact: it READS the previous state from LAST_FILE, WRITES
# the new state back, gates the ALERT page on the OK->ALERT edge ("$prev" !=
# "ALERT") and the RECOVERED page on the ALERT->OK edge ("$prev" = "ALERT"), and
# makes EXACTLY TWO notify() calls (one per edge) so it never pages every cycle.
chk3() {
  local root="${1:-.}"
  local F="$root/$WATCH_REL"
  test -f "$F" || { err "$F" "missing — required for the ns-scratch-watch guard"; return 1; }

  grep -Fq 'cat "$LAST_FILE"' "$F" || {
    err "$F" "REGRESSION — szl-ns-scratch-watch no longer READS the last_status state file."
    err "$F" "Without the previous state it can't edge-trigger and would page every single cycle."
    return 1
  }
  grep -Fq '>"$LAST_FILE"' "$F" || {
    err "$F" "REGRESSION — szl-ns-scratch-watch no longer WRITES the last_status state file."
    err "$F" "Without persisting state it can't de-dupe and would page every single cycle."
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
  echo "OK: edge-triggered — reads+writes last_status, both edge guards present, exactly 2 notify calls"
}

# ── Check 4 ───────────────────────────────────────────────────────────────────
# Cluster-absent / unreachable is a true no-op: the kubeconfig-resolve line and
# the readiness probe each fall back to `exit 0` (no page) when the cluster is
# down. A stopped k3d cluster must never turn into a paging storm.
chk4() {
  local root="${1:-.}"
  local F="$root/$WATCH_REL"
  test -f "$F" || { err "$F" "missing — required for the ns-scratch-watch guard"; return 1; }

  # The kubeconfig resolve must short-circuit to `exit 0` on failure. The fallback
  # may sit on the same line or the next continuation line, so scan a 1-line window.
  grep -A1 -E 'k3d kubeconfig write' "$F" | grep -Fq 'exit 0' || {
    err "$F" "REGRESSION — cluster-absent path no longer no-ops (k3d kubeconfig write resolve lost its 'exit 0' fallback)."
    err "$F" "A stopped/absent cluster would now error or page instead of being a silent no-op."
    return 1
  }
  # The readiness probe must also no-op (cluster present but not reachable).
  grep -A1 -E 'readyz' "$F" | grep -Fq 'exit 0' || {
    err "$F" "REGRESSION — cluster-unreachable path no longer no-ops (readyz probe lost its 'exit 0' fallback)."
    return 1
  }
  echo "OK: cluster-absent and cluster-unreachable paths both no-op (exit 0)"
}

# ── Check 5 ───────────────────────────────────────────────────────────────────
# Still wired into install.sh: the sbin script + the .service and .timer units
# are copied, and the timer is enabled. Otherwise a box rebuild ships without the
# alarm running.
chk5() {
  local root="${1:-.}"
  local F="$root/$INSTALL_REL"
  test -f "$F" || { err "$F" "missing — required for the ns-scratch-watch guard"; return 1; }

  grep -Eq 'install .*sbin/szl-ns-scratch-watch' "$F" || {
    err "$F" "REGRESSION — install.sh no longer installs sbin/szl-ns-scratch-watch."
    return 1
  }
  grep -Fq 'szl-ns-scratch-watch.service' "$F" || {
    err "$F" "REGRESSION — install.sh no longer installs szl-ns-scratch-watch.service."
    return 1
  }
  grep -Fq 'szl-ns-scratch-watch.timer' "$F" || {
    err "$F" "REGRESSION — install.sh no longer installs szl-ns-scratch-watch.timer."
    return 1
  }
  grep -Eq 'systemctl enable --now szl-ns-scratch-watch\.timer' "$F" || {
    err "$F" "REGRESSION — install.sh no longer ENABLES szl-ns-scratch-watch.timer; the alarm wouldn't run after a rebuild."
    return 1
  }
  echo "OK: install.sh installs the script + units and enables the timer"
}

# ── Check 6 ───────────────────────────────────────────────────────────────────
# Still documented in README.md so an operator restoring the box after a wipe
# knows the alarm exists and how to verify it.
chk6() {
  local root="${1:-.}"
  local F="$root/$README_REL"
  test -f "$F" || { err "$F" "missing — required for the ns-scratch-watch guard"; return 1; }

  grep -Fq 'szl-ns-scratch-watch' "$F" || {
    err "$F" "REGRESSION — README.md no longer documents szl-ns-scratch-watch."
    return 1
  }
  grep -Fiq 'scratch-namespace alarm' "$F" || {
    err "$F" "REGRESSION — README.md lost the 'scratch-namespace alarm' section describing this guard."
    return 1
  }
  echo "OK: README.md documents the szl-ns-scratch-watch scratch-namespace alarm"
}

# ── Check 7 ───────────────────────────────────────────────────────────────────
# Edge lifecycle (BEHAVIOURAL): drive the real script through the four
# transitions in ONE persistent sandbox and assert each one:
#   A  unlabeled present, fresh state -> ALERT, page EXACTLY once
#   B  still present (prev ALERT)     -> DE-DUPE, zero pages
#   C  none present (prev ALERT)      -> RECOVERED, page exactly once
#   D  none present (prev OK)         -> steady, zero pages
# The transition driver is shared (scripts/lib/alarm-guard-sandbox.sh); this
# check pins the ns-scratch-watch ALERT body marker. It complements chk3 (which
# proves the edge wiring is PRESENT in source) by proving it actually BEHAVES.
chk7() {
  local root="${1:-.}"
  local F="$root/$WATCH_REL"
  test -f "$F" || { err "$F" "missing — required for the ns-scratch-watch guard"; return 1; }

  _alarm_edge_lifecycle "$F" 'untracked scratch namespace' || return 1
  echo "OK: edge lifecycle — unlabeled->ALERT(1), still-present de-dupe(0), recovered(1), steady-OK(0)"
}

# ── Check 8 ───────────────────────────────────────────────────────────────────
# No-op safety (BEHAVIOURAL): a down/unreachable cluster, or the scratch tool's
# "nothing to do" sentinel, must each exit 0 with NO page — and must never emit a
# FALSE recovered (so prev=ALERT survives a transient outage). The driver is
# shared (scripts/lib/alarm-guard-sandbox.sh).
chk8() {
  local root="${1:-.}"
  local F="$root/$WATCH_REL"
  test -f "$F" || { err "$F" "missing — required for the ns-scratch-watch guard"; return 1; }

  _alarm_noop_safety "$F" || return 1
  echo "OK: cluster-absent / unreachable / scratch no-op all exit 0, never page, never false-recover"
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
      exit "$rc"
      ;;
    *) echo "unknown check: $CHECK (want chk1|chk2|chk3|chk4|chk5|chk6|chk7|chk8|all)" >&2; exit 2 ;;
  esac
fi
