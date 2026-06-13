# Copyright 2026 SZL Holdings
# SPDX-License-Identifier: Apache-2.0
#
# ns-scratch-stale-watch-guard-checks.sh — guard the `szl-ns-scratch-stale-watch`
# box guard (the EXPIRED labeled scratch-namespace alarm) from silently
# regressing.
#
# WHY THIS EXISTS
# `szl-ns-scratch-stale-watch` (box-scripts/sbin/szl-ns-scratch-stale-watch) is a
# periodic alarm: every ~30 min it wraps `szl-ns-scratch list-stale` and pages the
# team when a LABELED scratch namespace on the uds-szl-demo cluster has outlived
# its declared `szl.io/ttl-days` expiry — the quiet failure its sibling
# (`szl-ns-scratch-watch`, the UNLABELED alarm) does not catch. These expired
# namespaces silently eat the 2-vCPU box's headroom. Its value depends on a few
# fragile behaviours that are easy to break with a well-meaning refactor and that
# produce NO visible symptom until a real expired namespace goes unalerted:
#   * an EXPIRED namespace present must page EXACTLY once (the OK->ALERT edge);
#   * while still expired it must DE-DUPE (page zero more times), never re-page;
#   * once cleaned up it must page RECOVERED exactly once, then stay quiet;
#   * cluster absent / unreachable / the scratch tool's "nothing to do" sentinel
#     must each be a true NO-OP (exit 0, no page) — a stopped k3d cluster must
#     never turn into a paging storm, and must never emit a FALSE recovered;
#   * it must NEVER auto-delete a namespace (cleanup confirms with the owner);
#   * it must stay WIRED into install.sh (copied + timer enabled) and documented
#     in README.md, or a box rebuild silently ships without the alarm.
#
# Unlike a pure text/lint guard, this one EXERCISES the real script: each
# behavioural check builds a hermetic sandbox (stub `k3d`/`kubectl`, a fake
# `szl-ns-scratch list-stale`, and a capturing notifier) and actually runs
# box-scripts/sbin/szl-ns-scratch-stale-watch against fixture scenarios, then
# asserts the observed behaviour. That sandbox plus the edge-lifecycle / no-op
# runners are SHARED across the scratch-namespace alarm guards in
# scripts/lib/alarm-guard-sandbox.sh (sourced below). The static checks
# (exists/parses, wired, documented) mirror the sibling ns-scratch-watch-guard.
#
# The check logic is extracted here (out of the workflow) so it can be UNIT
# TESTED: ns-scratch-stale-watch-guard-checks.test.sh feeds each check a
# deliberately-BROKEN copy of the script and asserts the check FAILS (plus that
# the pristine repo PASSES). A future edit that neuters a check — making it pass
# vacuously, green while guarding nothing — is caught by that self-test, not in
# production.
#
# Usage:
#   ns-scratch-stale-watch-guard-checks.sh <check> [root]
#     check : chk1 | chk2 | chk3 | chk4 | chk5 | chk6 | chk7 | all
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
WATCH_REL="box-scripts/sbin/szl-ns-scratch-stale-watch"
INSTALL_REL="box-scripts/install.sh"
README_REL="box-scripts/README.md"

# ── Check 1 ───────────────────────────────────────────────────────────────────
# The guard script exists and parses clean under `bash -n`. If it is missing or
# broken, the alarm cannot run at all.
chk1() {
  local root="${1:-.}"
  local F="$root/$WATCH_REL"
  test -f "$F" || {
    err "$F" "REGRESSION — szl-ns-scratch-stale-watch is MISSING. The expired scratch-namespace alarm is gone."
    return 1
  }
  local out
  if ! out="$(bash -n "$F" 2>&1)"; then
    err "$F" "REGRESSION — szl-ns-scratch-stale-watch does not parse (bash -n failed)."
    echo "$out" | sed 's/^/       | /'
    return 1
  fi
  echo "OK: $F exists and parses clean (bash -n)"
}

# ── Check 2 ───────────────────────────────────────────────────────────────────
# It still shells out to the audit tool with `list-stale` — the only source of
# the expired/past-TTL namespace set. Without this the alarm has nothing to judge.
chk2() {
  local root="${1:-.}"
  local F="$root/$WATCH_REL"
  test -f "$F" || { err "$F" "missing — required for the ns-scratch-stale-watch guard"; return 1; }

  grep -Fq 'list-stale' "$F" || {
    err "$F" "REGRESSION — szl-ns-scratch-stale-watch no longer invokes 'szl-ns-scratch list-stale'."
    err "$F" "It has no source for the EXPIRED (past-TTL) labeled scratch-namespace set to alarm on."
    return 1
  }
  # The list-stale call must run against the audit binary (SCRATCH_BIN), not be a
  # stray comment/log mention.
  grep -Eq '"\$SCRATCH_BIN"[[:space:]]+list-stale' "$F" || {
    err "$F" "REGRESSION — 'list-stale' is no longer executed via \$SCRATCH_BIN (the szl-ns-scratch tool)."
    return 1
  }
  echo "OK: szl-ns-scratch-stale-watch shells out to \$SCRATCH_BIN list-stale"
}

# ── Check 3 ───────────────────────────────────────────────────────────────────
# Edge lifecycle (BEHAVIOURAL): drive the real script through the four
# transitions in ONE persistent sandbox and assert each one:
#   A  expired present, fresh state   -> ALERT, page EXACTLY once
#   B  still expired (prev ALERT)     -> DE-DUPE, zero pages
#   C  none present (prev ALERT)      -> RECOVERED, page exactly once
#   D  none present (prev OK)         -> steady, zero pages
# The transition driver is shared (scripts/lib/alarm-guard-sandbox.sh); this
# check pins the stale-watch ALERT body marker.
chk3() {
  local root="${1:-.}"
  local F="$root/$WATCH_REL"
  test -f "$F" || { err "$F" "missing — required for the ns-scratch-stale-watch guard"; return 1; }

  _alarm_edge_lifecycle "$F" 'PAST their declared expiry' || return 1
  echo "OK: edge lifecycle — expired->ALERT(1), still-expired de-dupe(0), recovered(1), steady-OK(0)"
}

# ── Check 4 ───────────────────────────────────────────────────────────────────
# No-op safety (BEHAVIOURAL): a down/unreachable cluster, or the scratch tool's
# "nothing to do" sentinel, must each exit 0 with NO page — and must never emit a
# FALSE recovered (so prev=ALERT survives a transient outage). The driver is
# shared (scripts/lib/alarm-guard-sandbox.sh).
chk4() {
  local root="${1:-.}"
  local F="$root/$WATCH_REL"
  test -f "$F" || { err "$F" "missing — required for the ns-scratch-stale-watch guard"; return 1; }

  _alarm_noop_safety "$F" || return 1
  echo "OK: cluster-absent / unreachable / scratch no-op all exit 0, never page, never false-recover"
}

# ── Check 5 ───────────────────────────────────────────────────────────────────
# It NEVER auto-deletes. Per the scratch convention a cleanup must confirm with
# the owner first; this alarm only surfaces the expired set. Asserted both
# statically (no `kubectl delete` in the source) and behaviourally (no destructive
# call reaches the stub cluster during an alert run).
chk5() {
  local root="${1:-.}"
  local F="$root/$WATCH_REL"
  test -f "$F" || { err "$F" "missing — required for the ns-scratch-stale-watch guard"; return 1; }

  # Match an actual command invocation at line-start, NOT the operator-guidance
  # text inside the alert body (which legitimately quotes 'kubectl delete ns <ns>'
  # to tell a human how to clean up).
  if grep -Eq '^[[:space:]]*kubectl[[:space:]]+delete' "$F"; then
    err "$F" "REGRESSION — szl-ns-scratch-stale-watch now runs 'kubectl delete'. This guard must NEVER auto-delete a namespace; cleanup confirms with the owner."
    return 1
  fi

  local d; d="$(_mk_sandbox)"
  _run "$F" "$d" expired
  if grep -Eq '(^| )delete( |$)' "$d/kubectl.log"; then
    err "$F" "REGRESSION — a destructive 'delete' reached the cluster during an alert run."
    rm -rf "$d"; return 1
  fi
  rm -rf "$d"
  echo "OK: never auto-deletes (no 'kubectl delete' in source or at runtime)"
}

# ── Check 6 ───────────────────────────────────────────────────────────────────
# Still wired into install.sh: the sbin script + the .service and .timer units
# are copied, and the timer is enabled. Otherwise a box rebuild ships without the
# alarm running.
chk6() {
  local root="${1:-.}"
  local F="$root/$INSTALL_REL"
  test -f "$F" || { err "$F" "missing — required for the ns-scratch-stale-watch guard"; return 1; }

  grep -Eq 'install .*sbin/szl-ns-scratch-stale-watch' "$F" || {
    err "$F" "REGRESSION — install.sh no longer installs sbin/szl-ns-scratch-stale-watch."
    return 1
  }
  grep -Fq 'szl-ns-scratch-stale-watch.service' "$F" || {
    err "$F" "REGRESSION — install.sh no longer installs szl-ns-scratch-stale-watch.service."
    return 1
  }
  grep -Fq 'szl-ns-scratch-stale-watch.timer' "$F" || {
    err "$F" "REGRESSION — install.sh no longer installs szl-ns-scratch-stale-watch.timer."
    return 1
  }
  grep -Eq 'systemctl enable --now szl-ns-scratch-stale-watch\.timer' "$F" || {
    err "$F" "REGRESSION — install.sh no longer ENABLES szl-ns-scratch-stale-watch.timer; the alarm wouldn't run after a rebuild."
    return 1
  }
  echo "OK: install.sh installs the script + units and enables the timer"
}

# ── Check 7 ───────────────────────────────────────────────────────────────────
# Still documented in README.md so an operator restoring the box after a wipe
# knows the alarm exists and how to verify it.
chk7() {
  local root="${1:-.}"
  local F="$root/$README_REL"
  test -f "$F" || { err "$F" "missing — required for the ns-scratch-stale-watch guard"; return 1; }

  grep -Fq 'szl-ns-scratch-stale-watch' "$F" || {
    err "$F" "REGRESSION — README.md no longer documents szl-ns-scratch-stale-watch."
    return 1
  }
  grep -Fiq 'expired scratch-namespace alarm' "$F" || {
    err "$F" "REGRESSION — README.md lost the 'expired scratch-namespace alarm' section describing this guard."
    return 1
  }
  echo "OK: README.md documents the szl-ns-scratch-stale-watch expired scratch-namespace alarm"
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
    all)
      rc=0
      chk1 "$ROOT" || rc=1
      chk2 "$ROOT" || rc=1
      chk3 "$ROOT" || rc=1
      chk4 "$ROOT" || rc=1
      chk5 "$ROOT" || rc=1
      chk6 "$ROOT" || rc=1
      chk7 "$ROOT" || rc=1
      exit "$rc"
      ;;
    *) echo "unknown check: $CHECK (want chk1|chk2|chk3|chk4|chk5|chk6|chk7|all)" >&2; exit 2 ;;
  esac
fi
