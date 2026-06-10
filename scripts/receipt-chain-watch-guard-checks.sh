# Copyright 2026 SZL Holdings
# SPDX-License-Identifier: Apache-2.0
#
# receipt-chain-watch-guard-checks.sh — guard the `receipt-chain-watch` box guard
# (the stalled signed-deploy-receipt alarm) from silently regressing.
#
# WHY THIS EXISTS
# `receipt-chain-watch` (box-scripts/sbin/receipt-chain-watch) is a periodic
# alarm: every ~5 min it inspects the uds-szl-demo cluster and pages the team the
# moment signed deploy receipts STOP being recorded — the receipts-server sink is
# unhealthy, the Pepr controller logged dropped POSTs, or signing is happening
# but nothing lands in the chain. That POST is FAIL-OPEN, so without this alarm a
# stalled chain is invisible until a manual log inspection. Its value depends on
# a few fragile invariants that are easy to break with a well-meaning refactor and
# that produce NO visible symptom until a real stall goes unalerted:
#   * it must still detect SINK health (receipts-server available replicas +
#     Service endpoints) — the thing the chain POSTs to;
#   * it must still scan the PEPR LOG window for dropped POSTs and the
#     chain-not-advancing signal (signed but zero accepted);
#   * it must be EDGE-triggered (read + write a last_status state file) so it
#     pages exactly once on OK->ALERT and once on RECOVERED, never every cycle;
#   * it must NO-OP (exit 0, no page) when the cluster is absent/unreachable or
#     the receipts module is not deployed, or a stopped cluster turns into a
#     paging storm;
#   * it must stay WIRED into install.sh (copied + timer enabled) and documented
#     in README.md, or a box rebuild silently ships without the alarm.
# This guard is a pure text/lint check (no cluster) that asserts each invariant.
#
# The check logic is extracted here (out of the workflow) so it can be UNIT
# TESTED: receipt-chain-watch-guard-checks.test.sh feeds each check a
# deliberately-BROKEN fixture and asserts the check FAILS (plus that the pristine
# repo PASSES). A future edit that neuters a check — making it pass vacuously,
# green while guarding nothing — is caught by that self-test, not in production.
#
# Usage:
#   receipt-chain-watch-guard-checks.sh <check> [root]
#     check : chk1 | chk2 | chk3 | chk4 | chk5 | chk6 | chk7 | all
#     root  : repo root to check (default: current directory)
#
# Each check exits 0 when the invariant holds and non-zero (printing a GitHub
# ::error annotation) when it is regressed.

set -uo pipefail

# err FILE MESSAGE — emit a GitHub Actions error annotation.
err() { echo "::error file=$1::$2"; }

# Paths (relative to a repo root) of the files this guard inspects.
WATCH_REL="box-scripts/sbin/receipt-chain-watch"
INSTALL_REL="box-scripts/install.sh"
README_REL="box-scripts/README.md"

# ── Check 1 ───────────────────────────────────────────────────────────────────
# The guard script exists and parses clean under `bash -n`. If it is missing or
# broken, the alarm cannot run at all.
chk1() {
  local root="${1:-.}"
  local F="$root/$WATCH_REL"
  test -f "$F" || {
    err "$F" "REGRESSION — receipt-chain-watch is MISSING. The stalled-receipt-chain alarm is gone."
    return 1
  }
  local out
  if ! out="$(bash -n "$F" 2>&1)"; then
    err "$F" "REGRESSION — receipt-chain-watch does not parse (bash -n failed)."
    echo "$out" | sed 's/^/       | /'
    return 1
  fi
  echo "OK: $F exists and parses clean (bash -n)"
}

# ── Check 2 ───────────────────────────────────────────────────────────────────
# It still detects SINK health: the receipts-server has at least one available
# replica AND its Service has ready endpoints (something to POST to). Dropping
# either probe means a dead sink could go unalerted.
chk2() {
  local root="${1:-.}"
  local F="$root/$WATCH_REL"
  test -f "$F" || { err "$F" "missing — required for the receipt-chain-watch guard"; return 1; }

  grep -Fq 'availableReplicas' "$F" || {
    err "$F" "REGRESSION — receipt-chain-watch no longer checks receipts-server availableReplicas."
    err "$F" "A receipts-server with 0 Running pods (no sink to POST to) would go unalerted."
    return 1
  }
  grep -Fq 'get endpoints' "$F" || {
    err "$F" "REGRESSION — receipt-chain-watch no longer checks the receipts-server Service endpoints."
    err "$F" "A Service with no ready endpoints (nothing to POST to) would go unalerted."
    return 1
  }
  echo "OK: detects sink health (availableReplicas + Service endpoints)"
}

# ── Check 3 ───────────────────────────────────────────────────────────────────
# It still scans the PEPR LOG window for the two stall signals: dropped receipt
# POSTs ("Failed to POST receipt") and chain-not-advancing (Pepr signed >=1 but
# the server accepted 0). Both rely on the exact log markers below.
chk3() {
  local root="${1:-.}"
  local F="$root/$WATCH_REL"
  test -f "$F" || { err "$F" "missing — required for the receipt-chain-watch guard"; return 1; }

  grep -Fq 'Failed to POST receipt' "$F" || {
    err "$F" "REGRESSION — receipt-chain-watch no longer scans for 'Failed to POST receipt' in the Pepr log."
    err "$F" "Dropped receipt POSTs (the fail-open silent-drop) would go unalerted."
    return 1
  }
  grep -Fq 'Receipt signed with Ed25519' "$F" || {
    err "$F" "REGRESSION — receipt-chain-watch no longer counts signed receipts ('Receipt signed with Ed25519')."
    err "$F" "It can't tell signing-active-but-chain-stalled from a quiet cluster."
    return 1
  }
  grep -Fq 'Receipt accepted by server' "$F" || {
    err "$F" "REGRESSION — receipt-chain-watch no longer counts accepted receipts ('Receipt accepted by server')."
    err "$F" "It can't detect 'signed >=1 but accepted 0' — the chain-not-advancing stall."
    return 1
  }
  echo "OK: scans the Pepr log for dropped POSTs + chain-not-advancing"
}

# ── Check 4 ───────────────────────────────────────────────────────────────────
# Edge-triggering is intact: it READS the previous state (cat "$LAST_FILE"),
# WRITES the new state back, gates the ALERT page on the OK->ALERT edge ("$prev"
# != "ALERT") and the RECOVERED page on the ALERT->OK edge ("$prev" = "ALERT"),
# and makes EXACTLY TWO notify() calls (one per edge) so it never pages every
# cycle.
chk4() {
  local root="${1:-.}"
  local F="$root/$WATCH_REL"
  test -f "$F" || { err "$F" "missing — required for the receipt-chain-watch guard"; return 1; }

  grep -Fq 'cat "$LAST_FILE"' "$F" || {
    err "$F" "REGRESSION — receipt-chain-watch no longer READS the last_status state file."
    err "$F" "Without the previous state it can't edge-trigger and would page every single cycle."
    return 1
  }
  grep -Fq '>"$LAST_FILE"' "$F" || {
    err "$F" "REGRESSION — receipt-chain-watch no longer WRITES the last_status state file."
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

# ── Check 5 ───────────────────────────────────────────────────────────────────
# Cluster-absent / unreachable / receipts-module-absent is a true no-op: the
# kubeconfig-resolve line, the readiness probe, and the pepr-szl presence check
# each fall back to `exit 0` (no page). A stopped k3d cluster (or a cluster
# without the receipts module) must never turn into a paging storm.
chk5() {
  local root="${1:-.}"
  local F="$root/$WATCH_REL"
  test -f "$F" || { err "$F" "missing — required for the receipt-chain-watch guard"; return 1; }

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
  # An absent receipts module (pepr-szl deploy missing) must also no-op.
  grep -A1 -E 'get deploy "\$PDEPLOY"' "$F" | grep -Fq 'exit 0' || {
    err "$F" "REGRESSION — receipts-module-absent path no longer no-ops (pepr-szl presence check lost its 'exit 0' fallback)."
    err "$F" "A cluster without the receipts module would now page falsely."
    return 1
  }
  echo "OK: cluster-absent / unreachable / receipts-module-absent paths all no-op (exit 0)"
}

# ── Check 6 ───────────────────────────────────────────────────────────────────
# Still wired into install.sh: the sbin script + the .service and .timer units
# are copied, and the timer is enabled. Otherwise a box rebuild ships without the
# alarm running.
chk6() {
  local root="${1:-.}"
  local F="$root/$INSTALL_REL"
  test -f "$F" || { err "$F" "missing — required for the receipt-chain-watch guard"; return 1; }

  grep -Eq 'install .*sbin/receipt-chain-watch' "$F" || {
    err "$F" "REGRESSION — install.sh no longer installs sbin/receipt-chain-watch."
    return 1
  }
  grep -Fq 'receipt-chain-watch.service' "$F" || {
    err "$F" "REGRESSION — install.sh no longer installs receipt-chain-watch.service."
    return 1
  }
  grep -Fq 'receipt-chain-watch.timer' "$F" || {
    err "$F" "REGRESSION — install.sh no longer installs receipt-chain-watch.timer."
    return 1
  }
  grep -Eq 'systemctl enable --now receipt-chain-watch\.timer' "$F" || {
    err "$F" "REGRESSION — install.sh no longer ENABLES receipt-chain-watch.timer; the alarm wouldn't run after a rebuild."
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
  test -f "$F" || { err "$F" "missing — required for the receipt-chain-watch guard"; return 1; }

  grep -Fq 'receipt-chain-watch' "$F" || {
    err "$F" "REGRESSION — README.md no longer documents receipt-chain-watch."
    return 1
  }
  grep -Fiq 'signed deploy receipts' "$F" || {
    err "$F" "REGRESSION — README.md lost the 'signed deploy receipts' section describing this alarm."
    return 1
  }
  echo "OK: README.md documents the receipt-chain-watch stalled-receipt alarm"
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
