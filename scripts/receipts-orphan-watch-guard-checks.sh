# Copyright 2026 SZL Holdings
# SPDX-License-Identifier: Apache-2.0
#
# receipts-orphan-watch-guard-checks.sh — guard the `szl-receipts-orphan-watch`
# box guard (the orphaned receipts-server alarm) from silently regressing.
#
# WHY THIS EXISTS
# `szl-receipts-orphan-watch` (box-scripts/sbin/szl-receipts-orphan-watch) is a
# periodic alarm: every ~10 min it lists every namespace on the uds-szl-demo
# cluster running a receipts-server Deployment, drops the canonical
# `szl-receipts`, and pages the team the moment a namespace running such a
# workload is owned by NOTHING (no Helm release, no UDS Package, no
# VirtualService) — an ORPHAN that signs nothing, holds no durable data, and just
# burns CPU on the 2-vCPU node (Task #283). Its value depends on a few fragile
# invariants that are easy to break with a well-meaning refactor and that produce
# NO visible symptom until a real orphan goes unalerted:
#   * it must still ENUMERATE receipts-server namespaces (`kubectl get deploy -A`
#     matched by name == szl-receipts-server OR an image matching IMAGE_MATCH);
#   * it must DROP the canonical `szl-receipts` namespace so the real server is
#     never flagged;
#   * it must check ALL THREE ownership signals (Helm / UDS Package / Istio
#     VirtualService) before calling a namespace an orphan;
#   * it must be EDGE-triggered (read + write a last_status state file) so it
#     pages exactly once on OK->problem and once on RECOVERED, never every cycle;
#   * it must NEVER delete anything (deletion of a teammate's live scratch stays
#     a human call) — it only logs + pages;
#   * it must NO-OP (exit 0, no page) when the cluster is absent/unreachable, or
#     a stopped k3d cluster turns into a paging storm;
#   * it must stay WIRED into install.sh (copied + timer enabled) and documented
#     in README.md, or a box rebuild silently ships without the alarm.
# This guard is a pure text/lint check (no cluster) that asserts each invariant.
#
# The check logic is extracted here (out of the workflow) so it can be UNIT
# TESTED: receipts-orphan-watch-guard-checks.test.sh feeds each check a
# deliberately-BROKEN fixture and asserts the check FAILS (plus that the pristine
# repo PASSES). A future edit that neuters a check — making it pass vacuously,
# green while guarding nothing — is caught by that self-test, not in production.
#
# Usage:
#   receipts-orphan-watch-guard-checks.sh <check> [root]
#     check : chk1 | chk2 | chk3 | chk4 | chk5 | chk6 | chk7 | chk8 | chk9 | all
#     root  : repo root to check (default: current directory)
#
# Each check exits 0 when the invariant holds and non-zero (printing a GitHub
# ::error annotation) when it is regressed.

set -uo pipefail

# err FILE MESSAGE — emit a GitHub Actions error annotation.
err() { echo "::error file=$1::$2"; }

# Paths (relative to a repo root) of the files this guard inspects.
WATCH_REL="box-scripts/sbin/szl-receipts-orphan-watch"
INSTALL_REL="box-scripts/install.sh"
README_REL="box-scripts/README.md"

# ── Check 1 ───────────────────────────────────────────────────────────────────
# The guard script exists and parses clean under `bash -n`. If it is missing or
# broken, the alarm cannot run at all.
chk1() {
  local root="${1:-.}"
  local F="$root/$WATCH_REL"
  test -f "$F" || {
    err "$F" "REGRESSION — szl-receipts-orphan-watch is MISSING. The orphaned receipts-server alarm is gone."
    return 1
  }
  local out
  if ! out="$(bash -n "$F" 2>&1)"; then
    err "$F" "REGRESSION — szl-receipts-orphan-watch does not parse (bash -n failed)."
    echo "$out" | sed 's/^/       | /'
    return 1
  fi
  echo "OK: $F exists and parses clean (bash -n)"
}

# ── Check 2 ───────────────────────────────────────────────────────────────────
# It still ENUMERATES receipts-server namespaces: lists Deployments cluster-wide
# (`kubectl get deploy -A`) and selects a candidate when the Deployment name ==
# $DEPLOY_NAME OR a container image matches $IMAGE_MATCH. Without this it has no
# source for the set of namespaces to judge.
chk2() {
  local root="${1:-.}"
  local F="$root/$WATCH_REL"
  test -f "$F" || { err "$F" "missing — required for the receipts-orphan-watch guard"; return 1; }

  grep -Fq 'get deploy -A' "$F" || {
    err "$F" "REGRESSION — szl-receipts-orphan-watch no longer enumerates Deployments cluster-wide ('kubectl get deploy -A')."
    err "$F" "It has no source for the set of receipts-server namespaces to judge."
    return 1
  }
  grep -Fq '[ "$name" = "$DEPLOY_NAME" ]' "$F" || {
    err "$F" "REGRESSION — szl-receipts-orphan-watch no longer matches receipts-server Deployments by name (\$DEPLOY_NAME)."
    return 1
  }
  grep -Fq 'grep -q "$IMAGE_MATCH"' "$F" || {
    err "$F" "REGRESSION — szl-receipts-orphan-watch no longer matches receipts-server Deployments by image (\$IMAGE_MATCH)."
    err "$F" "A renamed copy / local v0.4.0-src build would slip past undetected."
    return 1
  }
  echo "OK: enumerates receipts-server namespaces (get deploy -A, matched by name or image)"
}

# ── Check 3 ───────────────────────────────────────────────────────────────────
# It still DROPS the canonical `szl-receipts` namespace so the real, owned server
# is never flagged as an orphan. Requires both the default CANONICAL_NS value and
# the skip in the candidate loop.
chk3() {
  local root="${1:-.}"
  local F="$root/$WATCH_REL"
  test -f "$F" || { err "$F" "missing — required for the receipts-orphan-watch guard"; return 1; }

  grep -Eq 'CANONICAL_NS=.*szl-receipts' "$F" || {
    err "$F" "REGRESSION — the canonical namespace default ('szl-receipts') is gone from CANONICAL_NS."
    return 1
  }
  grep -Fq '[ "$ns" = "$CANONICAL_NS" ] && continue' "$F" || {
    err "$F" "REGRESSION — szl-receipts-orphan-watch no longer SKIPS the canonical namespace (\$CANONICAL_NS)."
    err "$F" "The real, Helm/UDS-owned receipts server would be flagged as an orphan and page falsely."
    return 1
  }
  echo "OK: drops the canonical 'szl-receipts' namespace before flagging"
}

# ── Check 4 ───────────────────────────────────────────────────────────────────
# It still checks ALL THREE ownership signals before calling a namespace an
# orphan: Helm (`helm list -A` / managed-by / meta.helm.sh), UDS Package
# (packages.uds.dev), and Istio VirtualService
# (virtualservices.networking.istio.io). Dropping any one would flag a tracked
# namespace as orphaned and page falsely.
chk4() {
  local root="${1:-.}"
  local F="$root/$WATCH_REL"
  test -f "$F" || { err "$F" "missing — required for the receipts-orphan-watch guard"; return 1; }

  grep -Fq 'helm list -A' "$F" || {
    err "$F" "REGRESSION — szl-receipts-orphan-watch no longer checks Helm ownership ('helm list -A')."
    err "$F" "Helm-owned (incl. zarf/UDS-deployed) namespaces could be flagged as orphans."
    return 1
  }
  grep -Fq 'packages.uds.dev' "$F" || {
    err "$F" "REGRESSION — szl-receipts-orphan-watch no longer checks UDS Package ownership (packages.uds.dev)."
    return 1
  }
  grep -Fq 'virtualservices.networking.istio.io' "$F" || {
    err "$F" "REGRESSION — szl-receipts-orphan-watch no longer checks Istio VirtualService ownership."
    return 1
  }
  echo "OK: checks all three ownership signals (Helm / UDS Package / Istio VirtualService)"
}

# ── Check 5 ───────────────────────────────────────────────────────────────────
# Edge-triggering is intact: it READS the previous state (cat "$LAST_FILE"),
# PERSISTS the new state back to LAST_FILE (atomic mv), gates the ALERT page on
# the OK->ALERT edge ("$prev" != "ALERT") and the RECOVERED page on the ALERT->OK
# edge ("$prev" = "ALERT"), and makes EXACTLY TWO notify() calls (one per edge)
# so it never pages every cycle.
chk5() {
  local root="${1:-.}"
  local F="$root/$WATCH_REL"
  test -f "$F" || { err "$F" "missing — required for the receipts-orphan-watch guard"; return 1; }

  grep -Fq 'cat "$LAST_FILE"' "$F" || {
    err "$F" "REGRESSION — szl-receipts-orphan-watch no longer READS the last_status state file."
    err "$F" "Without the previous state it can't edge-trigger and would page every single cycle."
    return 1
  }
  grep -Fq 'mv -f "$tmp" "$LAST_FILE"' "$F" || {
    err "$F" "REGRESSION — szl-receipts-orphan-watch no longer PERSISTS the last_status state file (atomic mv)."
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
  echo "OK: edge-triggered — reads+persists last_status, both edge guards present, exactly 2 notify calls"
}

# ── Check 6 ───────────────────────────────────────────────────────────────────
# It NEVER deletes anything. An orphan is sometimes a teammate's live scratch, so
# removal stays a human call — the guard only logs + pages. Assert no executed
# kubectl/k3d/oc `delete` command (the alert message may MENTION
# 'kubectl delete ns <ns>' as advice, but that line starts with `notify`, not a
# command, so it is not matched).
chk6() {
  local root="${1:-.}"
  local F="$root/$WATCH_REL"
  test -f "$F" || { err "$F" "missing — required for the receipts-orphan-watch guard"; return 1; }

  if grep -Eq '^[[:space:]]*(kubectl|k3d|oc)[[:space:]].*\bdelete\b' "$F"; then
    err "$F" "REGRESSION — szl-receipts-orphan-watch now EXECUTES a delete command."
    err "$F" "This guard must never delete — an orphan can be a teammate's live scratch; deletion stays a human call."
    grep -nE '^[[:space:]]*(kubectl|k3d|oc)[[:space:]].*\bdelete\b' "$F" | sed 's/^/       | /'
    return 1
  fi
  echo "OK: never executes a delete command (logs + pages only)"
}

# ── Check 7 ───────────────────────────────────────────────────────────────────
# Cluster-absent / unreachable is a true no-op: the kubeconfig-resolve line and
# the readiness probe each fall back to `exit 0` (no page) when the cluster is
# down. A stopped k3d cluster must never turn into a paging storm.
chk7() {
  local root="${1:-.}"
  local F="$root/$WATCH_REL"
  test -f "$F" || { err "$F" "missing — required for the receipts-orphan-watch guard"; return 1; }

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

# ── Check 8 ───────────────────────────────────────────────────────────────────
# Still wired into install.sh: the sbin script + the .service and .timer units
# are copied, and the timer is enabled. Otherwise a box rebuild ships without the
# alarm running.
chk8() {
  local root="${1:-.}"
  local F="$root/$INSTALL_REL"
  test -f "$F" || { err "$F" "missing — required for the receipts-orphan-watch guard"; return 1; }

  grep -Eq 'install .*sbin/szl-receipts-orphan-watch' "$F" || {
    err "$F" "REGRESSION — install.sh no longer installs sbin/szl-receipts-orphan-watch."
    return 1
  }
  grep -Fq 'szl-receipts-orphan-watch.service' "$F" || {
    err "$F" "REGRESSION — install.sh no longer installs szl-receipts-orphan-watch.service."
    return 1
  }
  grep -Fq 'szl-receipts-orphan-watch.timer' "$F" || {
    err "$F" "REGRESSION — install.sh no longer installs szl-receipts-orphan-watch.timer."
    return 1
  }
  grep -Eq 'systemctl enable --now szl-receipts-orphan-watch\.timer' "$F" || {
    err "$F" "REGRESSION — install.sh no longer ENABLES szl-receipts-orphan-watch.timer; the alarm wouldn't run after a rebuild."
    return 1
  }
  echo "OK: install.sh installs the script + units and enables the timer"
}

# ── Check 9 ───────────────────────────────────────────────────────────────────
# Still documented in README.md so an operator restoring the box after a wipe
# knows the alarm exists and how to verify it.
chk9() {
  local root="${1:-.}"
  local F="$root/$README_REL"
  test -f "$F" || { err "$F" "missing — required for the receipts-orphan-watch guard"; return 1; }

  grep -Fq 'szl-receipts-orphan-watch' "$F" || {
    err "$F" "REGRESSION — README.md no longer documents szl-receipts-orphan-watch."
    return 1
  }
  grep -Fiq 'orphaned receipts-server' "$F" || {
    err "$F" "REGRESSION — README.md lost the 'orphaned receipts-server' section describing this guard."
    return 1
  }
  echo "OK: README.md documents the szl-receipts-orphan-watch orphaned receipts-server alarm"
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
      exit "$rc"
      ;;
    *) echo "unknown check: $CHECK (want chk1|chk2|chk3|chk4|chk5|chk6|chk7|chk8|chk9|all)" >&2; exit 2 ;;
  esac
fi
