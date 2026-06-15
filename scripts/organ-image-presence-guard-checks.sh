# Copyright 2026 SZL Holdings
# SPDX-License-Identifier: Apache-2.0
#
# organ-image-presence-guard-checks.sh — guard the RETIRED-ORGAN image-presence
# PAGER from being silently widened (so it spams contributors / pages on green)
# or narrowed (so a real image disappearance never pages anyone).
#
# WHY THIS EXISTS
# organ-image-presence-guard.yml runs the retired-organ image probe on every PR
# AND on a daily schedule, but it only PAGES the team (POSTs to the shared
# szl-alert-relay -> ntfy webhook) on the UNATTENDED scheduled run when it
# actually finds a missing image. That selectivity rests entirely on one `if:`:
#
#     if: always() && github.event_name == 'schedule' && steps.check.outputs.missing == '1'
#
# Drop `github.event_name == 'schedule'` and every contributor gets paged on every
# PR. Drop `steps.check.outputs.missing == '1'` and the team gets paged on green
# runs. Drop `always()` and a prior step's failure stops the alert from ever
# firing. None of those mistakes turns the Actions tab red on its own. This guard
# makes such an edit fail loudly in CI. It mirrors organ-pin-drift-guard-checks.sh.
#
# It also asserts the surrounding contract the alert depends on: the probe step
# runs with `set +e` (so a non-zero probe doesn't abort the job before the
# alert/gate can act) and still exports missing/images to $GITHUB_OUTPUT, and a
# FINAL gate step re-fails the run on a missing image INDEPENDENT of the alert (on
# every event, not just the schedule) so a vanished image can never land green.
#
# Pure text/lint — no cluster, no registry, no images. Unit-tested by
# organ-image-presence-guard-checks.test.sh (negative fixtures of the workflow).
#
# Usage:
#   organ-image-presence-guard-checks.sh <check> [root]
#     check : chk1 | chk2 | chk3 | chk4 | chk5 | all
#     root  : repo root to check (default: current directory)

set -uo pipefail

WF=".github/workflows/organ-image-presence-guard.yml"

err() { echo "::error file=$1::$2"; }

# extract_step FILE NAME_PATTERN — print one job step block (its `      - name:`
# line up to but excluding the next sibling `      - name:`).
extract_step() {
  awk -v pat="$2" '
    $0 ~ ("^      - name: .*" pat) { if (inblk) { exit } inblk=1; print; next }
    inblk && /^      - name: / { exit }
    inblk { print }
  ' "$1"
}

alert_if_line() {
  local root="${1:-.}"
  extract_step "$root/$WF" "Alert the team" | grep -E '^        if:' | head -1
}

chk1() {  # alert step keeps always()
  local root="${1:-.}"; local F="$root/$WF"
  test -f "$F" || { err "$F" "missing — required for the retired-organ image-presence pager guard"; return 1; }
  local ifl; ifl="$(alert_if_line "$root")"
  if [ -z "$ifl" ]; then err "$F" "REGRESSION — could not find the alert step's 'if:' condition."; return 1; fi
  if ! printf '%s' "$ifl" | grep -qF 'always()'; then
    err "$F" "REGRESSION — alert step no longer guards on always()."
    err "$F" "An earlier step's failure would skip the alert, silencing a real scheduled-run image disappearance."
    return 1
  fi
  echo "OK: alert step 'if:' keeps always()"
}

chk2() {  # alert step keeps github.event_name == 'schedule'
  local root="${1:-.}"; local F="$root/$WF"
  test -f "$F" || { err "$F" "missing — required for the retired-organ image-presence pager guard"; return 1; }
  local ifl; ifl="$(alert_if_line "$root")"
  if [ -z "$ifl" ]; then err "$F" "REGRESSION — could not find the alert step's 'if:' condition."; return 1; fi
  if ! printf '%s' "$ifl" | grep -qF "github.event_name == 'schedule'"; then
    err "$F" "REGRESSION — alert step no longer restricted to the scheduled run."
    err "$F" "It would page the team on every PR; contributors already see the red check."
    return 1
  fi
  echo "OK: alert step 'if:' keeps github.event_name == 'schedule'"
}

chk3() {  # alert step keeps steps.check.outputs.missing == '1'
  local root="${1:-.}"; local F="$root/$WF"
  test -f "$F" || { err "$F" "missing — required for the retired-organ image-presence pager guard"; return 1; }
  local ifl; ifl="$(alert_if_line "$root")"
  if [ -z "$ifl" ]; then err "$F" "REGRESSION — could not find the alert step's 'if:' condition."; return 1; fi
  if ! printf '%s' "$ifl" | grep -qF "steps.check.outputs.missing == '1'"; then
    err "$F" "REGRESSION — alert step no longer gated on missing == '1'."
    err "$F" "It would page the team on green scheduled runs, training them to ignore it."
    return 1
  fi
  echo "OK: alert step 'if:' keeps steps.check.outputs.missing == '1'"
}

chk4() {  # probe step uses set +e and exports missing + images
  local root="${1:-.}"; local F="$root/$WF"
  test -f "$F" || { err "$F" "missing — required for the retired-organ image-presence pager guard"; return 1; }
  local blk; blk="$(extract_step "$F" "Probe retired-organ")"
  if [ -z "$blk" ]; then err "$F" "REGRESSION — probe step ('Probe retired-organ...') not found."; return 1; fi
  if ! printf '%s\n' "$blk" | grep -qE '(^|[[:space:]])set \+e([[:space:]]|$)'; then
    err "$F" "REGRESSION — probe step no longer runs with 'set +e'."
    err "$F" "A non-zero probe would abort the job before the alert/gate can act."
    return 1
  fi
  local missing=0
  # missing is a scalar export: `echo "missing=1" >> "$GITHUB_OUTPUT"`.
  if ! printf '%s\n' "$blk" | grep -qE "missing=.*>> \"\\\$GITHUB_OUTPUT\""; then
    err "$F" "REGRESSION — probe step no longer exports 'missing' to \$GITHUB_OUTPUT."
    missing=1
  fi
  # images is a multi-line heredoc export the alert reads to name each organ.
  if ! printf '%s\n' "$blk" | grep -qF 'images<<EOF'; then
    err "$F" "REGRESSION — probe step no longer exports the 'images' organ list to \$GITHUB_OUTPUT."
    missing=1
  fi
  [ "$missing" -eq 0 ] || return 1
  echo "OK: probe step uses set +e and exports missing/images"
}

chk5() {  # final gate re-fails on a missing image, independent of the alert, every event
  local root="${1:-.}"; local F="$root/$WF"
  test -f "$F" || { err "$F" "missing — required for the retired-organ image-presence pager guard"; return 1; }
  local blk; blk="$(extract_step "$F" "Fail the run")"
  if [ -z "$blk" ]; then
    err "$F" "REGRESSION — final gate step ('Fail the run...') not found."
    err "$F" "Nothing re-fails the run on a missing image; a disappearance could land green."
    return 1
  fi
  local ifl; ifl="$(printf '%s\n' "$blk" | grep -E '^        if:' | head -1)"
  if ! printf '%s' "$ifl" | grep -qF 'always()'; then
    err "$F" "REGRESSION — final gate step is not guarded on always()."
    err "$F" "It would be skipped after a failing earlier step, letting a disappearance land green."
    return 1
  fi
  if printf '%s' "$ifl" | grep -qF 'github.event_name'; then
    err "$F" "REGRESSION — final gate step now depends on the event type."
    err "$F" "The gate must fail on a missing image for EVERY event (PRs included), independent of the alert."
    return 1
  fi
  if ! printf '%s\n' "$blk" | grep -qF 'steps.check.outputs.missing'; then
    err "$F" "REGRESSION — final gate step no longer reads the missing output."
    return 1
  fi
  if ! printf '%s\n' "$blk" | grep -qE '(^|[[:space:]])exit 1([[:space:]]|$)'; then
    err "$F" "REGRESSION — final gate step no longer fails the run (no 'exit 1')."
    return 1
  fi
  echo "OK: final gate re-fails on a missing image, independent of the alert, on every event"
}

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
