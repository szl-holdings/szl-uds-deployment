#!/usr/bin/env bash
# Copyright 2026 SZL Holdings
# SPDX-License-Identifier: Apache-2.0
#
# alarm-guard-coverage-checks.sh — META-GUARD. Assert that every box watcher /
# alarm shipped by box-scripts/install.sh carries its own guard trio (a CI
# workflow + a check/driver script + a self-test), OR is on the explicit
# guard-exempt allowlist.
#
# WHY THIS EXISTS
# Each box alarm (box-scripts/sbin/<name>-watch, <name>-check) is the thing that
# pages a human when a real failure mode appears (a stalled receipt chain, a
# receipt flood, an orphaned receipts-server, an untracked scratch namespace, a
# DNS drift, a sealed signing path...). An alarm that silently regresses — its
# edge-fire math broken, its notifier dropped, its install line removed — fails
# OPEN: the failure it was meant to catch now goes unalerted, and nothing tells
# you. The sibling per-alarm guards close that hole one alarm at a time. But
# NOTHING stops a NEW alarm from being added with no guard at all — the most
# dangerous gap of all, because the new alarm looks protected (it has a timer,
# it runs) while its correctness is never checked. This meta-guard is the gate
# that catches THAT: add an alarm, you must add its guard (or justify an
# exemption inline), or this CI check goes red.
#
# WHAT COUNTS AS AN ALARM (the enumerated set)
# The same install.sh-derived set box-scripts-drift-check and
# box-helper-install-coverage already use: sbin scripts that install.sh actually
# installs via an `install -m "$here/sbin/NAME" ...` line — filtered to those
# whose basename ends in an alarm suffix (-watch / -check / -monitor / -alarm).
# Scoping to the install.sh set means a new alarm is forced through TWO gates:
# box-helper-install-coverage requires it to be wired into install.sh, and THIS
# guard then requires that wired alarm to have a guard trio.
#
# WHAT COUNTS AS COVERAGE (any one shape, per stem)
# The repo's per-alarm guards use three honest shapes; this gate accepts all
# three. For a stem S (the alarm name, or the alarm name minus its `szl-` or
# `a11oy-` prefix — several guards drop that prefix, e.g. szl-ns-scratch-watch ->
# ns-scratch-watch-guard, szl-receipts-orphan-watch -> receipts-orphan-watch-guard):
#   TEXT trio      scripts/S-guard-checks.sh + scripts/S-guard-checks.test.sh
#                  + .github/workflows/S-guard.yml          (grep/lint invariants)
#   E2E  trio      scripts/S-guard.sh        + scripts/S-guard.test.sh
#                  + .github/workflows/S-guard.yml          (box-scripts-drift-check)
#   SELFTEST       scripts/S-selftest.sh     + .github/workflows/S-selftest.yml
#                  (a behavioural driver that RUNS the real alarm with stubbed
#                   inputs — its own proof; receipt-flood-watch / -throttle-watch)
#
# This is a pure text check — no cluster, no root. The self-test
# (alarm-guard-coverage-checks.test.sh) feeds it broken fixtures to prove each
# branch actually fails, so the gate can never pass vacuously.
#
# Usage:
#   alarm-guard-coverage-checks.sh [root]   (root default: current dir)
# Exit 0 when every alarm is guarded or allowlisted; non-zero (with ::error
# annotations) on any uncovered alarm.
#
# The allowlist is overridable via ALARM_GUARD_ALLOWLIST (space-separated
# basenames) FOR THE SELF-TEST ONLY; production runs use the default below.

set -uo pipefail

# Box alarms that intentionally ship WITHOUT a per-alarm guard trio in THIS repo
# (same convention as box-helper-install-coverage's own-installer allowlist):
#   a11oy-uptime-check
#     -> NOT a cluster receipt/namespace alarm. It is the external HTTPS uptime
#        probe of the a11oy-uptime alerting subsystem (its own notifier
#        a11oy-uptime-notify, its status.json board, and an off-box env-backup
#        restore drill cover it as a unit). It is guarded as part of that
#        subsystem, not by the cluster-alarm trio convention this gate enforces.
#   eval-arena-trend-watch
#     -> FULLY guarded in-repo by its TEXT guard scripts
#        scripts/eval-arena-trend-watch-guard-checks.sh + .test.sh (both green),
#        which assert every invariant of the alarm. Its CI workflow
#        .github/workflows/eval-arena-trend-watch-guard.yml is authored and ready
#        but could NOT be committed by the GitHub token used to ship this change
#        (the token lacks the `workflow` scope GitHub requires to add/modify any
#        .github/workflows/ file). Run the guard locally with:
#          bash scripts/eval-arena-trend-watch-guard-checks.test.sh && \
#          bash scripts/eval-arena-trend-watch-guard-checks.sh .
#        REMOVE this entry and commit the workflow file once a workflow-scoped
#        token is available (tracked as a follow-up).
DEFAULT_ALLOWLIST="a11oy-uptime-check eval-arena-trend-watch"

# err FILE MESSAGE — emit a GitHub Actions error annotation.
err() { echo "::error file=$1::$2"; }

# derive_installed_set INSTALL_SH KIND -> newline-separated SOURCE basenames from
# the `install ... "$here/<KIND>/NAME" DEST` lines. Same logic (kept in lockstep)
# as box-scripts-drift-check's derive_install_set and box-helper-install-coverage.
derive_installed_set() {
  local install_sh="$1" kind="$2"
  [ -r "$install_sh" ] || return 0
  grep -F "\"\$here/$kind/" "$install_sh" 2>/dev/null \
    | grep -E '(^|[[:space:]])install([[:space:]]|$)' \
    | grep -oE "\"\\\$here/$kind/[^\"]+\"" \
    | sed -E 's#.*/##; s#"$##' \
    | awk 'NF && !seen[$0]++'
}

# derive_alarm_set INSTALL_SH -> installed sbin scripts whose basename ends in an
# alarm suffix (-watch / -check / -monitor / -alarm).
derive_alarm_set() {
  derive_installed_set "$1" sbin | grep -E -- '-(watch|check|monitor|alarm)$' || true
}

# stem_candidates ALARM -> the alarm name plus its szl-/a11oy--stripped forms
# (several guards drop that prefix in their filenames).
stem_candidates() {
  local w="$1"
  printf '%s\n' "$w"
  case "$w" in szl-*)   printf '%s\n' "${w#szl-}"   ;; esac
  case "$w" in a11oy-*) printf '%s\n' "${w#a11oy-}" ;; esac
}

# guard_shape_exists STEM ROOT -> 0 if STEM has a complete TEXT trio, E2E trio,
# or behavioural selftest.
guard_shape_exists() {
  local s="$1" root="$2"
  local sc="$root/scripts" wf="$root/.github/workflows"
  # TEXT trio
  [ -f "$sc/$s-guard-checks.sh" ] && [ -f "$sc/$s-guard-checks.test.sh" ] && [ -f "$wf/$s-guard.yml" ] && return 0
  # E2E trio (box-scripts-drift-check style: <stem>-guard.sh + .test.sh)
  [ -f "$sc/$s-guard.sh" ] && [ -f "$sc/$s-guard.test.sh" ] && [ -f "$wf/$s-guard.yml" ] && return 0
  # behavioural self-test that drives the real alarm
  [ -f "$sc/$s-selftest.sh" ] && [ -f "$wf/$s-selftest.yml" ] && return 0
  return 1
}

# is_covered ALARM ROOT -> 0 if ANY candidate stem has a guard shape.
is_covered() {
  local w="$1" root="$2" s
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    guard_shape_exists "$s" "$root" && return 0
  done < <(stem_candidates "$w")
  return 1
}

# check_coverage [root] — the gate. 0 if every alarm is guarded/allowlisted.
check_coverage() {
  local root="${1:-.}"
  local box="$root/box-scripts"
  local install_sh="$box/install.sh"
  local allowlist="${ALARM_GUARD_ALLOWLIST-$DEFAULT_ALLOWLIST}"

  test -d "$box" || { err "$box" "missing box-scripts/ directory"; return 1; }
  test -f "$install_sh" || { err "$install_sh" "missing box-scripts/install.sh"; return 1; }

  local alarms
  alarms="$(derive_alarm_set "$install_sh")"
  if [ -z "$alarms" ]; then
    err "$install_sh" "found ZERO box alarms (-watch/-check/-monitor/-alarm) installed by install.sh — the enumerator is broken and this gate would pass vacuously."
    return 1
  fi

  local rc=0 w
  while IFS= read -r w; do
    [ -n "$w" ] || continue
    case " $allowlist " in *" $w "*) continue ;; esac
    if is_covered "$w" "$root"; then continue; fi
    err "box-scripts/sbin/$w" "box alarm '$w' has NO guard trio: no TEXT trio (scripts/<stem>-guard-checks.sh + .test.sh + .github/workflows/<stem>-guard.yml), no E2E trio (scripts/<stem>-guard.sh + .test.sh + workflow), and no behavioural self-test (scripts/<stem>-selftest.sh + .github/workflows/<stem>-selftest.yml), for stem '$w' or its szl-/a11oy--stripped form."
    err "box-scripts/sbin/$w" "Add one of those guard shapes, OR add '$w' to DEFAULT_ALLOWLIST in scripts/alarm-guard-coverage-checks.sh with an inline reason if the alarm is intentionally guard-exempt."
    rc=1
  done <<EOF
$alarms
EOF

  # Stale-allowlist hygiene: an allowlist entry that is no longer an install.sh
  # alarm is dead weight (and could mask a future name collision) — warn, don't fail.
  local a
  for a in $allowlist; do
    printf '%s\n' "$alarms" | grep -qxF -- "$a" || \
      echo "::warning::alarm-guard allowlist entry '$a' is not a current install.sh alarm — remove the stale entry from DEFAULT_ALLOWLIST."
  done

  if [ "$rc" -eq 0 ]; then
    echo "OK: every install.sh-managed box alarm (-watch/-check) has a guard trio or is on the documented allowlist."
    echo "Alarms checked:"
    printf '  %s\n' $alarms
  fi
  return "$rc"
}

# Run only when executed directly; sourcing (the self-test) just loads functions.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  check_coverage "${1:-.}"
fi
