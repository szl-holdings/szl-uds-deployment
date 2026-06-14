# Copyright 2026 SZL Holdings
# SPDX-License-Identifier: Apache-2.0
#
# test-upgrade-guard-checks.sh — keep the `test-upgrade` task honest so it can
# never silently skip its published baseline again.
#
# WHY THIS EXISTS
# Task #484 fixed the `test-upgrade` task: it used to deploy the prior published
# release with a NON-FATAL fallback (`zarf package deploy ... || echo "WARN ...
# skipping"`), so whenever the OCI tag was momentarily absent the baseline
# deployed NOTHING, the next deploy became a fresh install (not an upgrade), and
# the whole "we proved an upgrade works" test went HOLLOW — green while proving
# nothing. The fix made the baseline deploy FATAL and added a post-upgrade proof
# that the szl-receipts helm release advanced to >=2 revisions (a real upgrade,
# not a fresh install).
#
# Nothing static guards that fix, so a future refactor of tasks.yaml could
# quietly re-introduce the `|| echo ... skipping` fallback, or drop the
# helm-revision proof, and the test would go hollow again with no failure. This
# guard turns either regression into a seconds-long, cluster-free CI failure.
#
# The check logic is extracted here (out of the workflow) so it can be UNIT
# TESTED: test-upgrade-guard-checks.test.sh feeds each check a deliberately-BROKEN
# fixture and asserts the check FAILS (plus that the pristine repo PASSES). A
# future edit that neuters a check — making it pass vacuously, green while
# guarding nothing — is caught by that self-test, not in production.
#
# It is a pure text/lint check — no cluster needed.
#
# Usage:
#   test-upgrade-guard-checks.sh <check> [root]
#     check : chk1 | chk2 | all
#     root  : repo root to check (default: current directory)
#
# Each check exits 0 when the invariant holds and non-zero (printing a GitHub
# ::error annotation) when it is regressed.

set -uo pipefail

# err FILE MESSAGE — emit a GitHub Actions error annotation.
err() { echo "::error file=$1::$2"; }

# extract_task FILE TASKNAME — print the YAML block of a top-level (2-space
# indented) uds task, from its `  - name: <task>` line up to (but excluding) the
# next sibling `  - name:` line. Used to scope checks to one task.
extract_task() {
  awk -v t="$2" '
    $0 ~ ("^  - name: " t "$") { inblk=1; print; next }
    inblk && /^  - name: / { inblk=0 }
    inblk { print }
  ' "$1"
}

# extract_step REGEX — read a task block on stdin and print the single action
# step (from one `      - description:` line up to the next, or end-of-block)
# whose body contains a line matching REGEX. Prints the FIRST matching step only.
# Used to scope a check to one action within a task.
extract_step() {
  awk -v re="$1" '
    /^      - description:/ {
      if (matched) { for (i = 0; i < n; i++) print buf[i]; exit }
      n = 0; matched = 0; buf[n++] = $0; next
    }
    { buf[n++] = $0 }
    $0 ~ re { matched = 1 }
    END { if (matched) for (i = 0; i < n; i++) print buf[i] }
  '
}

# strip_comments — drop whole-line shell comments (a line whose first non-space
# character is `#`) from stdin. The Task #484 fix intentionally documents the OLD
# `|| echo ... skipping` anti-pattern in a code comment; that comment is NOT
# executable and must not trip the fatal-fallback scan.
strip_comments() { grep -vE '^[[:space:]]*#' || true; }

# ── Check 1 ───────────────────────────────────────────────────────────────────
# The `test-upgrade` task still deploys the published baseline, and that deploy is
# FATAL — no non-fatal fallback (`|| echo`, `2>/dev/null ||`, `|| true`, ...) that
# would let an absent/failed baseline silently become a fresh install instead of
# an upgrade. This is the exact hole Task #484 closed.
chk1() {
  local root="${1:-.}"
  local F="$root/tasks.yaml"
  test -f "$F" || { err "$F" "missing — required for the test-upgrade guard"; return 1; }

  local blk
  blk="$(extract_task "$F" test-upgrade)"
  if [ -z "$blk" ]; then
    err "$F" "REGRESSION — 'test-upgrade' task not found in tasks.yaml."
    return 1
  fi

  local step
  step="$(printf '%s\n' "$blk" | extract_step 'zarf package deploy .*UPGRADE_BASELINE_REF')"
  if [ -z "$step" ]; then
    err "$F" "REGRESSION — test-upgrade no longer deploys the published baseline (UPGRADE_BASELINE_REF)."
    err "$F" "Without deploying a real prior release first, the next deploy is a fresh install, not an upgrade — a hollow test."
    return 1
  fi

  # Non-fatal fallback patterns that would let the baseline deploy fail/skip
  # without failing the task. Comments are stripped first so the documented
  # anti-pattern in the Task #484 note does not match.
  local nonfatal='(\|\|[[:space:]]*(echo|true|:|warn|continue|skip|exit[[:space:]]+0))|(2>/dev/null[[:space:]]*\|\|)'
  local hit
  hit="$(printf '%s\n' "$step" | strip_comments | grep -nE "$nonfatal" || true)"
  if [ -n "$hit" ]; then
    err "$F" "REGRESSION — the baseline deploy step has a NON-FATAL fallback; it must fail loudly (Task #484)."
    err "$F" "An absent/failed baseline would silently become a fresh install, making the upgrade test hollow."
    printf '%s\n' "$hit" | sed 's/^/       | /'
    return 1
  fi
  echo "OK: test-upgrade deploys the published baseline fatally (no silent skip)"
}

# ── Check 2 ───────────────────────────────────────────────────────────────────
# The post-upgrade proof step is intact: it counts the szl-receipts helm release
# revisions (Secrets labelled owner=helm,name=szl-receipts) and FAILS the task
# unless there are >=2 — i.e. the current build genuinely UPGRADED an existing
# release rather than fresh-installing it. Dropping or weakening this check
# (e.g. to `-lt 1`) would let the hollow behaviour pass again.
chk2() {
  local root="${1:-.}"
  local F="$root/tasks.yaml"
  test -f "$F" || { err "$F" "missing — required for the test-upgrade guard"; return 1; }

  local blk
  blk="$(extract_task "$F" test-upgrade)"
  if [ -z "$blk" ]; then
    err "$F" "REGRESSION — 'test-upgrade' task not found in tasks.yaml."
    return 1
  fi

  # The proof step is the one asserting the helm-revision count is at least 2.
  local step
  step="$(printf '%s\n' "$blk" | extract_step '[-]lt 2')"
  if [ -z "$step" ]; then
    err "$F" "REGRESSION — the post-upgrade helm-revision assertion (>=2 revisions) is MISSING or weakened."
    err "$F" "Without it, a fresh install (1 revision) would pass as if it were an upgrade."
    return 1
  fi

  if ! printf '%s\n' "$step" | grep -q 'owner=helm,name=szl-receipts'; then
    err "$F" "REGRESSION — the >=2 assertion no longer counts the szl-receipts helm release Secrets (owner=helm,name=szl-receipts)."
    return 1
  fi

  if ! printf '%s\n' "$step" | grep -Eq '(exit[[:space:]]+1|::error)'; then
    err "$F" "REGRESSION — the >=2 helm-revision check no longer FAILS the task; it must be fatal, not a warning."
    return 1
  fi
  echo "OK: test-upgrade proves a real upgrade (>=2 szl-receipts helm revisions, fatal)"
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
    all)
      rc=0
      chk1 "$ROOT" || rc=1
      chk2 "$ROOT" || rc=1
      exit "$rc"
      ;;
    *) echo "unknown check: $CHECK (want chk1|chk2|all)" >&2; exit 2 ;;
  esac
fi
