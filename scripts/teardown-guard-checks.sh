# Copyright 2026 SZL Holdings
# SPDX-License-Identifier: Apache-2.0
#
# teardown-guard-checks.sh — guard the `uds run teardown` in-flight activity
# safety check from being silently removed.
#
# WHY THIS EXISTS
# The shared k3d demo cluster (uds-szl-demo) is driven by MULTIPLE task agents at
# once. A blind `uds run teardown` would wipe a sibling's in-flight deploy, so the
# teardown task REFUSES to destroy the cluster unless it is idle (judged by
# scripts/idle-check.sh) or `--set FORCE=true` is passed. That safety net lives in
# exactly two files — `tasks.yaml` (the wiring) and `scripts/idle-check.sh` (the
# logic). A sibling refactor of tasks.yaml could silently drop the guard call, the
# FORCE/IDLE_WINDOW_MINUTES variables, or the helper script, re-opening the exact
# "naive teardown clobbers in-flight work" hole this fixed.
#
# The check logic is extracted here (out of the workflow) so it can be UNIT
# TESTED: teardown-guard-checks.test.sh feeds each check a deliberately-BROKEN
# fixture and asserts the check FAILS (plus that the pristine repo PASSES). A
# future edit that neuters a check — making it pass vacuously, green while
# guarding nothing — is caught by that self-test, not in production.
#
# It is a pure text/lint check — no cluster needed.
#
# Usage:
#   teardown-guard-checks.sh <check> [root]
#     check : chk1 | chk2 | chk3 | all
#     root  : repo root to check (default: current directory)
#
# Each check exits 0 when the invariant holds and non-zero (printing a GitHub
# ::error annotation) when it is regressed.

set -uo pipefail

# err FILE MESSAGE — emit a GitHub Actions error annotation.
err() { echo "::error file=$1::$2"; }

# extract_task FILE TASKNAME — print the YAML block of a top-level (2-space
# indented) uds task, from its `  - name: <task>` line up to (but excluding) the
# next sibling `  - name:` line. Used to scope ordering checks to one task.
extract_task() {
  awk -v t="$2" '
    $0 ~ ("^  - name: " t "$") { inblk=1; print; next }
    inblk && /^  - name: / { inblk=0 }
    inblk { print }
  ' "$1"
}

# ── Check 1 ───────────────────────────────────────────────────────────────────
# scripts/idle-check.sh exists and parses clean under `sh -n`. This is the helper
# that decides whether the cluster is idle; if it is missing or broken the
# teardown guard cannot judge safety.
chk1() {
  local root="${1:-.}"
  local F="$root/scripts/idle-check.sh"
  test -f "$F" || {
    err "$F" "REGRESSION — idle-check.sh is MISSING."
    err "$F" "Without it the teardown guard has nothing to judge cluster idleness with."
    return 1
  }
  local out
  if ! out="$(sh -n "$F" 2>&1)"; then
    err "$F" "REGRESSION — idle-check.sh does not parse (sh -n failed)."
    echo "$out" | sed 's/^/       | /'
    return 1
  fi
  echo "OK: $F exists and parses clean (sh -n)"
}

# ── Check 2 ───────────────────────────────────────────────────────────────────
# The `teardown` task in tasks.yaml invokes idle-check.sh AND references FORCE
# BEFORE the `k3d cluster delete` action. Order matters: the safety gate must run
# before the destructive delete, never after.
chk2() {
  local root="${1:-.}"
  local F="$root/tasks.yaml"
  test -f "$F" || { err "$F" "missing — required for the teardown guard"; return 1; }

  local blk
  blk="$(extract_task "$F" teardown)"
  if [ -z "$blk" ]; then
    err "$F" "REGRESSION — 'teardown' task not found in tasks.yaml."
    return 1
  fi

  local l_idle l_force l_delete
  l_idle="$(printf '%s\n' "$blk"   | grep -n 'idle-check\.sh'    | head -1 | cut -d: -f1)"
  l_force="$(printf '%s\n' "$blk"  | grep -n 'FORCE'            | head -1 | cut -d: -f1)"
  l_delete="$(printf '%s\n' "$blk" | grep -n 'k3d cluster delete' | head -1 | cut -d: -f1)"

  if [ -z "$l_delete" ]; then
    err "$F" "REGRESSION — teardown task has no 'k3d cluster delete' action."
    return 1
  fi
  if [ -z "$l_idle" ]; then
    err "$F" "REGRESSION — teardown task no longer invokes scripts/idle-check.sh."
    err "$F" "A blind teardown would wipe a sibling task agent's in-flight deploy."
    return 1
  fi
  if [ -z "$l_force" ]; then
    err "$F" "REGRESSION — teardown task no longer references the FORCE override."
    return 1
  fi
  if [ "$l_idle" -ge "$l_delete" ] || [ "$l_force" -ge "$l_delete" ]; then
    err "$F" "REGRESSION — the idle-check / FORCE gate must come BEFORE 'k3d cluster delete'."
    err "$F" "Found: idle-check@$l_idle force@$l_force delete@$l_delete (within the teardown task)."
    return 1
  fi
  echo "OK: teardown gates on idle-check.sh + FORCE before deleting the cluster"
}

# ── Check 3 ───────────────────────────────────────────────────────────────────
# The standalone `idle-check` task and the FORCE / IDLE_WINDOW_MINUTES variables
# are all still declared. These are the operator-facing inspector and the two
# knobs the guard depends on.
chk3() {
  local root="${1:-.}"
  local F="$root/tasks.yaml"
  test -f "$F" || { err "$F" "missing — required for the teardown guard"; return 1; }

  grep -Eq '^  - name: idle-check$' "$F" || {
    err "$F" "REGRESSION — standalone 'idle-check' task is gone (uds run idle-check)."
    return 1
  }
  grep -Eq '^  - name: FORCE$' "$F" || {
    err "$F" "REGRESSION — FORCE variable is gone; teardown can no longer be overridden."
    return 1
  }
  grep -Eq '^  - name: IDLE_WINDOW_MINUTES$' "$F" || {
    err "$F" "REGRESSION — IDLE_WINDOW_MINUTES variable is gone; idle window is untunable."
    return 1
  }
  echo "OK: idle-check task + FORCE + IDLE_WINDOW_MINUTES variables all present"
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
    all)
      rc=0
      chk1 "$ROOT" || rc=1
      chk2 "$ROOT" || rc=1
      chk3 "$ROOT" || rc=1
      exit "$rc"
      ;;
    *) echo "unknown check: $CHECK (want chk1|chk2|chk3|all)" >&2; exit 2 ;;
  esac
fi
