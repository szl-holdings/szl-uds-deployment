# Copyright 2026 SZL Holdings
# SPDX-License-Identifier: Apache-2.0
#
# pin-drift-guard-checks.sh — guard the receipts pin-drift PAGER from being
# silently widened so it spams contributors or pages on green runs.
#
# WHY THIS EXISTS
# receipts-pin-drift-guard.yml runs the receipts-server digest drift check on
# every PR AND on a daily schedule, but it only PAGES the team (POSTs to the
# shared szl-alert-relay -> ntfy webhook) on the UNATTENDED scheduled run when it
# actually finds drift. That selectivity rests entirely on one `if:` expression:
#
#     if: always() && github.event_name == 'schedule' && steps.check.outputs.drift == '1'
#
# Drop `github.event_name == 'schedule'` and every contributor gets paged on
# every PR. Drop `steps.check.outputs.drift == '1'` and the team gets paged on
# green runs. Drop `always()` and a prior step's failure stops the alert from ever
# firing. None of those mistakes turns the Actions tab red on its own — they were
# only ever caught by a human reading the YAML. This guard makes a future edit
# that widens (or breaks) the trigger fail loudly in CI instead.
#
# It also asserts the surrounding contract the alert depends on: the drift check
# step runs with `set +e` (so a non-zero check doesn't abort the job before the
# alert/gate can act) and still exports drift/tag/fix_cmd to $GITHUB_OUTPUT, and a
# FINAL gate step re-fails the run on drift INDEPENDENT of the alert (on every
# event, not just the schedule) so a stale pin can never land green.
#
# The check logic is extracted here (out of the workflow) so it can be UNIT
# TESTED: pin-drift-guard-checks.test.sh feeds each check a deliberately-BROKEN
# copy of the workflow and asserts the check FAILS (plus that the pristine repo
# PASSES). A future edit that neuters a check — making it pass vacuously, green
# while guarding nothing — is caught by that self-test, not in production.
#
# It is a pure text/lint check — no cluster, no zarf, no images.
#
# Usage:
#   pin-drift-guard-checks.sh <check> [root]
#     check : chk1 | chk2 | chk3 | chk4 | chk5 | all
#     root  : repo root to check (default: current directory)
#
# Each check exits 0 when the invariant holds and non-zero (printing a GitHub
# ::error annotation) when it is regressed.

set -uo pipefail

# The workflow this guard protects, relative to the repo root.
WF=".github/workflows/receipts-pin-drift-guard.yml"

# err FILE MESSAGE — emit a GitHub Actions error annotation.
err() { echo "::error file=$1::$2"; }

# extract_step FILE NAME_PATTERN — print the YAML block of a single job step,
# from its `      - name: ...<pattern>` line up to (but excluding) the next
# sibling `      - name:` line. Steps sit at 6-space indent under `    steps:`.
# Used to scope each assertion to ONE step so removing a condition from that
# step's `if:` line is detected even though other steps share the same tokens
# (e.g. the final gate also uses `always()`).
extract_step() {
  awk -v pat="$2" '
    $0 ~ ("^      - name: .*" pat) { if (inblk) { exit } inblk=1; print; next }
    inblk && /^      - name: / { exit }
    inblk { print }
  ' "$1"
}

# alert_if_line ROOT — print the alert step's single `if:` line, or empty.
alert_if_line() {
  local root="${1:-.}"
  extract_step "$root/$WF" "Alert the team" | grep -E '^        if:' | head -1
}

# ── Check 1 ───────────────────────────────────────────────────────────────────
# The alert step's `if:` keeps `always()`. Without it, a failure in an earlier
# step (e.g. the GHCR login) would skip the alert, so a real scheduled-run drift
# would never page anyone — the exact silent miss this alert exists to prevent.
chk1() {
  local root="${1:-.}"
  local F="$root/$WF"
  test -f "$F" || { err "$F" "missing — required for the pin-drift pager guard"; return 1; }
  local ifl
  ifl="$(alert_if_line "$root")"
  if [ -z "$ifl" ]; then
    err "$F" "REGRESSION — could not find the alert step's 'if:' condition."
    return 1
  fi
  if ! printf '%s' "$ifl" | grep -qF 'always()'; then
    err "$F" "REGRESSION — alert step no longer guards on always()."
    err "$F" "An earlier step's failure would skip the alert, silencing real scheduled-run drift."
    return 1
  fi
  echo "OK: alert step 'if:' keeps always()"
}

# ── Check 2 ───────────────────────────────────────────────────────────────────
# The alert step's `if:` keeps `github.event_name == 'schedule'`. Without it the
# pager fires on PR runs too, spamming every contributor (who already sees the
# red check) on the shared szl-alert-relay -> ntfy channel.
chk2() {
  local root="${1:-.}"
  local F="$root/$WF"
  test -f "$F" || { err "$F" "missing — required for the pin-drift pager guard"; return 1; }
  local ifl
  ifl="$(alert_if_line "$root")"
  if [ -z "$ifl" ]; then
    err "$F" "REGRESSION — could not find the alert step's 'if:' condition."
    return 1
  fi
  if ! printf '%s' "$ifl" | grep -qF "github.event_name == 'schedule'"; then
    err "$F" "REGRESSION — alert step no longer restricted to the scheduled run."
    err "$F" "It would page the team on every PR; contributors already see the red check."
    return 1
  fi
  echo "OK: alert step 'if:' keeps github.event_name == 'schedule'"
}

# ── Check 3 ───────────────────────────────────────────────────────────────────
# The alert step's `if:` keeps `steps.check.outputs.drift == '1'`. Without it the
# pager fires on GREEN scheduled runs (no drift), training the team to ignore it.
chk3() {
  local root="${1:-.}"
  local F="$root/$WF"
  test -f "$F" || { err "$F" "missing — required for the pin-drift pager guard"; return 1; }
  local ifl
  ifl="$(alert_if_line "$root")"
  if [ -z "$ifl" ]; then
    err "$F" "REGRESSION — could not find the alert step's 'if:' condition."
    return 1
  fi
  if ! printf '%s' "$ifl" | grep -qF "steps.check.outputs.drift == '1'"; then
    err "$F" "REGRESSION — alert step no longer gated on drift == '1'."
    err "$F" "It would page the team on green scheduled runs, training them to ignore it."
    return 1
  fi
  echo "OK: alert step 'if:' keeps steps.check.outputs.drift == '1'"
}

# ── Check 4 ───────────────────────────────────────────────────────────────────
# The drift-check step runs with `set +e` (so a non-zero check does NOT abort the
# job before the alert/gate can act on it) and still exports drift, tag and
# fix_cmd to $GITHUB_OUTPUT — the outputs the alert and the final gate both read.
chk4() {
  local root="${1:-.}"
  local F="$root/$WF"
  test -f "$F" || { err "$F" "missing — required for the pin-drift pager guard"; return 1; }
  local blk
  blk="$(extract_step "$F" "Check committed pins")"
  if [ -z "$blk" ]; then
    err "$F" "REGRESSION — drift-check step ('Check committed pins...') not found."
    return 1
  fi
  if ! printf '%s\n' "$blk" | grep -qE '(^|[[:space:]])set \+e([[:space:]]|$)'; then
    err "$F" "REGRESSION — drift-check step no longer runs with 'set +e'."
    err "$F" "A non-zero check would abort the job before the alert/gate can act."
    return 1
  fi
  local key missing=0
  for key in drift tag fix_cmd; do
    if ! printf '%s\n' "$blk" | grep -qE "${key}=.*>> \"\\\$GITHUB_OUTPUT\""; then
      err "$F" "REGRESSION — drift-check step no longer exports '${key}' to \$GITHUB_OUTPUT."
      missing=1
    fi
  done
  [ "$missing" -eq 0 ] || return 1
  echo "OK: drift-check step uses set +e and exports drift/tag/fix_cmd"
}

# ── Check 5 ───────────────────────────────────────────────────────────────────
# A FINAL gate step re-fails the run on drift INDEPENDENT of the alert: it must
# run on every event (always(), NOT restricted to the schedule) and `exit 1` when
# drift == "1". This is what keeps a stale pin from landing green on a PR even
# though the PR never pages anyone.
chk5() {
  local root="${1:-.}"
  local F="$root/$WF"
  test -f "$F" || { err "$F" "missing — required for the pin-drift pager guard"; return 1; }
  local blk
  blk="$(extract_step "$F" "Fail the run")"
  if [ -z "$blk" ]; then
    err "$F" "REGRESSION — final gate step ('Fail the run...') not found."
    err "$F" "Nothing re-fails the run on drift; a stale pin could land green."
    return 1
  fi
  local ifl
  ifl="$(printf '%s\n' "$blk" | grep -E '^        if:' | head -1)"
  if ! printf '%s' "$ifl" | grep -qF 'always()'; then
    err "$F" "REGRESSION — final gate step is not guarded on always()."
    err "$F" "It would be skipped after a failing earlier step, letting drift land green."
    return 1
  fi
  if printf '%s' "$ifl" | grep -qF 'github.event_name'; then
    err "$F" "REGRESSION — final gate step now depends on the event type."
    err "$F" "The gate must fail on drift for EVERY event (PRs included), independent of the alert."
    return 1
  fi
  if ! printf '%s\n' "$blk" | grep -qF 'steps.check.outputs.drift'; then
    err "$F" "REGRESSION — final gate step no longer reads the drift output."
    return 1
  fi
  if ! printf '%s\n' "$blk" | grep -qE '(^|[[:space:]])exit 1([[:space:]]|$)'; then
    err "$F" "REGRESSION — final gate step no longer fails the run (no 'exit 1')."
    return 1
  fi
  echo "OK: final gate re-fails on drift, independent of the alert, on every event"
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
