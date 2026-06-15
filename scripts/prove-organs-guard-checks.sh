# Copyright 2026 SZL Holdings
# SPDX-License-Identifier: Apache-2.0
#
# prove-organs-guard-checks.sh — guard the automatic release-proof workflow
# (.github/workflows/prove-organs.yaml) from silently losing its triggers.
#
# WHY THIS EXISTS
# prove-organs re-proves that EVERY organ still deploys individually onto a clean
# UDS substrate. It earns its keep only because it runs AUTOMATICALLY: on every
# release tag (v* / uds-v*), nightly (schedule), and pages the team (the `alert`
# job) when an automatic run fails. Each leg also ALWAYS tears down its throwaway
# k3d cluster. A future edit to the workflow could quietly drop the push:tags
# trigger, the nightly cron, the alert job (or weaken its condition), or the
# teardown's always() — and releases would silently stop being proven, or
# clusters would leak, with nobody noticing. This guard fails LOUD if any of
# those triggers/jobs/conditions regress.
#
# The check logic is extracted here (out of the workflow) so it can be UNIT
# TESTED: prove-organs-guard-checks.test.sh feeds each check a deliberately-BROKEN
# fixture and asserts the check FAILS (plus that the pristine repo PASSES). A
# future edit that neuters a check — making it pass vacuously, green while
# guarding nothing — is caught by that self-test, not in production.
#
# It is a pure text/lint check — no cluster needed.
#
# Usage:
#   prove-organs-guard-checks.sh <check> [root]
#     check : chk1 | chk2 | chk3 | chk4 | chk5 | all
#     root  : repo root to check (default: current directory)
#
# Each check exits 0 when the invariant holds and non-zero (printing a GitHub
# ::error annotation) when it is regressed.

set -uo pipefail

WF_REL=".github/workflows/prove-organs.yaml"

# err FILE MESSAGE — emit a GitHub Actions error annotation.
err() { echo "::error file=$1::$2"; }

# extract_on_block FILE KEY — print the block of one second-level (2-space) key
# under the top-level `on:` mapping (e.g. push, schedule), from its `  KEY:` line
# up to the next 2-space sibling key (or the end of the on: mapping).
extract_on_block() {
  awk -v k="$2" '
    $0 ~ /^on:/ { ino=1; next }
    ino && /^[^[:space:]]/ { ino=0 }
    ino==0 { next }
    $0 ~ ("^  " k ":") { inb=1; print; next }
    inb && /^  [^[:space:]]/ { inb=0 }
    inb { print }
  ' "$1"
}

# extract_job FILE JOB — print the block of one job (a 2-space key under `jobs:`),
# from its `  JOB:` line up to the next 2-space sibling key (or end of jobs:).
extract_job() {
  awk -v k="$2" '
    $0 ~ /^jobs:/ { inj=1; next }
    inj && /^[^[:space:]]/ { inj=0 }
    inj==0 { next }
    $0 ~ ("^  " k ":") { inb=1; print; next }
    inb && /^  [^[:space:]]/ { inb=0 }
    inb { print }
  ' "$1"
}

# extract_teardown_step FILE — print the "Teardown throwaway cluster" step block,
# from its `- name:` line up to the next step / job / top-level boundary.
extract_teardown_step() {
  awk '
    /^[[:space:]]*- name: Teardown throwaway cluster[[:space:]]*$/ { ins=1; print; next }
    ins && /^[[:space:]]*- / { ins=0 }
    ins && /^  [^[:space:]]/ { ins=0 }
    ins && /^[^[:space:]]/ { ins=0 }
    ins { print }
  ' "$1"
}

# ── Check 1 ───────────────────────────────────────────────────────────────────
# The `push:` trigger filters on `tags:` and includes BOTH release-tag patterns
# (v* and uds-v*). Without these, tagging a release would no longer re-prove that
# every organ is still individually deployable.
chk1() {
  local root="${1:-.}"
  local F="$root/$WF_REL"
  test -f "$F" || { err "$F" "missing — required for the prove-organs trigger guard"; return 1; }
  local blk; blk="$(extract_on_block "$F" push)"
  if [ -z "$blk" ]; then
    err "$F" "REGRESSION — the prove-organs workflow no longer has a 'push:' trigger."
    err "$F" "Release tags would stop re-proving that every organ is individually deployable."
    return 1
  fi
  if ! printf '%s\n' "$blk" | grep -Eq '^[[:space:]]*tags:'; then
    err "$F" "REGRESSION — the 'push:' trigger no longer filters on 'tags:'."
    return 1
  fi
  printf '%s\n' "$blk" | grep -Eq "^[[:space:]]*-[[:space:]]*['\"]?v\*['\"]?[[:space:]]*\$" || {
    err "$F" "REGRESSION — the push tags no longer include the 'v*' release-tag pattern."
    return 1
  }
  printf '%s\n' "$blk" | grep -Eq "^[[:space:]]*-[[:space:]]*['\"]?uds-v\*['\"]?[[:space:]]*\$" || {
    err "$F" "REGRESSION — the push tags no longer include the 'uds-v*' release-tag pattern."
    return 1
  }
  echo "OK: prove-organs runs on push of v* and uds-v* tags"
}

# ── Check 2 ───────────────────────────────────────────────────────────────────
# The `schedule:` trigger defines a cron entry so the doctrine is re-proven
# nightly between releases (a regression is caught within a day, not at tag time).
chk2() {
  local root="${1:-.}"
  local F="$root/$WF_REL"
  test -f "$F" || { err "$F" "missing — required for the prove-organs trigger guard"; return 1; }
  local blk; blk="$(extract_on_block "$F" schedule)"
  if [ -z "$blk" ]; then
    err "$F" "REGRESSION — the prove-organs workflow no longer has a 'schedule:' trigger."
    err "$F" "Nightly re-proving of 'individually deployable' between releases would stop."
    return 1
  fi
  printf '%s\n' "$blk" | grep -Eq "^[[:space:]]*-[[:space:]]*cron:[[:space:]]*['\"]?[0-9*]" || {
    err "$F" "REGRESSION — the 'schedule:' trigger no longer defines a cron entry."
    return 1
  }
  echo "OK: prove-organs runs on a nightly schedule (cron present)"
}

# ── Check 3 ───────────────────────────────────────────────────────────────────
# The `alert` job still exists. It is what turns an automatic-run failure into a
# loud page to the team CI alert channel (ntfy/Slack relay).
chk3() {
  local root="${1:-.}"
  local F="$root/$WF_REL"
  test -f "$F" || { err "$F" "missing — required for the prove-organs trigger guard"; return 1; }
  local blk; blk="$(extract_job "$F" alert)"
  if [ -z "$blk" ]; then
    err "$F" "REGRESSION — the 'alert' job is gone; automatic-run failures would no longer page the CI alert channel."
    return 1
  fi
  echo "OK: the 'alert' job is present"
}

# ── Check 4 ───────────────────────────────────────────────────────────────────
# The `alert` job's condition is intact: it pages ONLY when an AUTOMATIC run
# fails — `failure() && github.event_name != 'workflow_dispatch'`. Dropping
# failure() would page on success; dropping the workflow_dispatch exclusion would
# page the whole team for every manual run.
chk4() {
  local root="${1:-.}"
  local F="$root/$WF_REL"
  test -f "$F" || { err "$F" "missing — required for the prove-organs trigger guard"; return 1; }
  local blk; blk="$(extract_job "$F" alert)"
  if [ -z "$blk" ]; then
    err "$F" "REGRESSION — the 'alert' job is gone (cannot check its condition)."
    return 1
  fi
  local ifline
  ifline="$(printf '%s\n' "$blk" | grep -E '^[[:space:]]*if:' | head -1)"
  if [ -z "$ifline" ]; then
    err "$F" "REGRESSION — the 'alert' job lost its 'if:' condition; it would now page on EVERY run, including manual ones."
    return 1
  fi
  printf '%s\n' "$ifline" | grep -Eq 'failure\(\)' || {
    err "$F" "REGRESSION — the 'alert' job condition no longer gates on failure(); it would page even on success."
    return 1
  }
  printf '%s\n' "$ifline" | grep -Eq "github\.event_name[[:space:]]*!=[[:space:]]*['\"]workflow_dispatch['\"]" || {
    err "$F" "REGRESSION — the 'alert' job condition no longer excludes workflow_dispatch; manual runs would page the team."
    return 1
  }
  echo "OK: alert fires only on failure() of automatic (non-workflow_dispatch) runs"
}

# ── Check 5 ───────────────────────────────────────────────────────────────────
# The throwaway-cluster teardown step runs with `if: always()` so a failed (or
# cancelled) leg still tears its k3d cluster down instead of leaking it.
chk5() {
  local root="${1:-.}"
  local F="$root/$WF_REL"
  test -f "$F" || { err "$F" "missing — required for the prove-organs trigger guard"; return 1; }
  local blk; blk="$(extract_teardown_step "$F")"
  if [ -z "$blk" ]; then
    err "$F" "REGRESSION — the 'Teardown throwaway cluster' step is gone; throwaway k3d clusters would leak."
    return 1
  fi
  printf '%s\n' "$blk" | grep -Eq '^[[:space:]]*if:[[:space:]]*always\(\)' || {
    err "$F" "REGRESSION — the teardown step no longer runs with if: always(); a failed leg would leave its cluster running."
    return 1
  }
  echo "OK: the teardown step always() tears down its throwaway cluster"
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
    all)
      rc=0
      chk1 "$ROOT" || rc=1
      chk2 "$ROOT" || rc=1
      chk3 "$ROOT" || rc=1
      chk4 "$ROOT" || rc=1
      chk5 "$ROOT" || rc=1
      exit "$rc"
      ;;
    *) echo "unknown check: $CHECK (want chk1|chk2|chk3|chk4|chk5|all)" >&2; exit 2 ;;
  esac
fi
