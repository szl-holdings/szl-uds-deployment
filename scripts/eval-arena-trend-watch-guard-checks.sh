# Copyright 2026 SZL Holdings
# SPDX-License-Identifier: Apache-2.0
#
# eval-arena-trend-watch-guard-checks.sh — guard the `eval-arena-trend-watch` box
# alarm (the near-real-time eval-arena recorded-run honesty alarm) from silently
# regressing.
#
# WHY THIS EXISTS
# `eval-arena-trend-watch` (box-scripts/sbin/eval-arena-trend-watch) runs every
# ~15 min and pages the team if the NEWEST recorded eval-arena run — the one the
# console trend strip is drawn from, served live at
# /api/a11oy/v1/eval-arena/history — degrades (loses its passing example, or loses
# its policy-rejected negative control) so the strip would go silently all-green.
# Its value rests on a few fragile invariants that produce NO visible symptom when
# broken until a real degradation goes unalerted:
#   * it reads the LIVE history endpoint and HONESTLY NO-OPS on an unreachable
#     endpoint / empty history (never pages on "I could not look", never fabricates);
#   * it REUSES the canonical validate_run() via the eval-arena-trend-validate
#     bridge — never re-implementing the contract, so the live alarm and the CI
#     guard can never drift;
#   * it is EDGE-triggered via a signature file so it pages exactly once per
#     distinct degradation and once on RECOVERED, never every cycle;
#   * it always writes a fresh status file + heartbeat STATE log (so the
#     monitor-liveness meta-monitor can watch it) and the notifier is FAIL-SOFT;
#   * it stays WIRED into install.sh (script + bridge + units copied, timer
#     enabled) and documented in README.md, or a box rebuild silently ships
#     without the alarm.
# This guard is a pure text/lint check (no network) that asserts each invariant.
#
# The check logic is extracted here (out of the workflow) so it can be UNIT
# TESTED: eval-arena-trend-watch-guard-checks.test.sh feeds each check a
# deliberately-BROKEN fixture and asserts the check FAILS (plus that the pristine
# repo PASSES). A future edit that neuters a check is caught by that self-test.
#
# Usage:
#   eval-arena-trend-watch-guard-checks.sh <check> [root]
#     check : chk1 .. chk7 | all
#     root  : repo root to check (default: current directory)

set -uo pipefail

err() { echo "::error file=$1::$2"; }

WATCH_REL="box-scripts/sbin/eval-arena-trend-watch"
VALIDATE_REL="box-scripts/sbin/eval-arena-trend-validate"
INSTALL_REL="box-scripts/install.sh"
README_REL="box-scripts/README.md"

# ── Check 1 ── watcher + bridge exist and parse clean ─────────────────────────
chk1() {
  local root="${1:-.}"
  local F="$root/$WATCH_REL" V="$root/$VALIDATE_REL"
  test -f "$F" || {
    err "$F" "REGRESSION — eval-arena-trend-watch is MISSING. The live eval-arena trend honesty alarm is gone."
    return 1
  }
  test -f "$V" || {
    err "$V" "REGRESSION — eval-arena-trend-validate (the canonical-validator bridge) is MISSING."
    return 1
  }
  local out
  if ! out="$(bash -n "$F" 2>&1)"; then
    err "$F" "REGRESSION — eval-arena-trend-watch does not parse (bash -n failed)."
    echo "$out" | sed 's/^/       | /'
    return 1
  fi
  if ! out="$(python3 -m py_compile "$V" 2>&1)"; then
    err "$V" "REGRESSION — eval-arena-trend-validate does not compile (python -m py_compile failed)."
    echo "$out" | sed 's/^/       | /'
    return 1
  fi
  echo "OK: $F + $V exist and parse clean"
}

# ── Check 2 ── reads the LIVE history endpoint + honest no-op ─────────────────
chk2() {
  local root="${1:-.}"
  local F="$root/$WATCH_REL"
  test -f "$F" || { err "$F" "missing — required for the eval-arena-trend-watch guard"; return 1; }

  grep -Fq 'eval-arena/history' "$F" || {
    err "$F" "REGRESSION — no longer reads the live /api/a11oy/v1/eval-arena/history endpoint (HISTORY_URL default gone)."
    return 1
  }
  grep -Fq 'SKIP eval-arena history unreachable' "$F" || {
    err "$F" "REGRESSION — the UNREACHABLE-endpoint honest no-op is gone; the alarm could page on 'I could not look' or go silent."
    return 1
  }
  grep -Fq 'no recorded run to validate' "$F" || {
    err "$F" "REGRESSION — the EMPTY-history honest no-op is gone; the alarm must soft-skip empty history, never fabricate a run."
    return 1
  }
  echo "OK: reads the live history endpoint and honestly no-ops on unreachable / empty history"
}

# ── Check 3 ── reuses the CANONICAL validate_run() via the bridge ─────────────
chk3() {
  local root="${1:-.}"
  local F="$root/$WATCH_REL" V="$root/$VALIDATE_REL"
  test -f "$F" || { err "$F" "missing — required for the eval-arena-trend-watch guard"; return 1; }
  test -f "$V" || { err "$V" "missing — required for the eval-arena-trend-watch guard"; return 1; }

  grep -Fq 'from check_eval_arena_negative_control import' "$V" || {
    err "$V" "REGRESSION — the bridge no longer imports the canonical validator; the live alarm could drift from the CI guard."
    return 1
  }
  grep -Fq 'validate_run' "$V" || {
    err "$V" "REGRESSION — the bridge no longer reuses validate_run(); the 'pass + policy-rejected fail' contract may be re-implemented and drift."
    return 1
  }
  grep -Fq '_normalize_recorded_run' "$V" || {
    err "$V" "REGRESSION — the bridge no longer normalizes the recorded run via _normalize_recorded_run()."
    return 1
  }
  grep -Fq '_pick_latest_recorded' "$V" || {
    err "$V" "REGRESSION — the bridge no longer selects the newest recorded run via _pick_latest_recorded()."
    return 1
  }
  grep -Fq '$VALIDATE_CMD' "$F" || {
    err "$F" "REGRESSION — the watcher no longer invokes the validator bridge (\$VALIDATE_CMD)."
    return 1
  }
  echo "OK: reuses the canonical validate_run()/_normalize_recorded_run()/_pick_latest_recorded() via the bridge"
}

# ── Check 4 ── edge-triggered via the signature file (exactly two pushes) ─────
chk4() {
  local root="${1:-.}"
  local F="$root/$WATCH_REL"
  test -f "$F" || { err "$F" "missing — required for the eval-arena-trend-watch guard"; return 1; }

  grep -Fq 'cat "$SIG_FILE"' "$F" || {
    err "$F" "REGRESSION — no longer READS the problem signature file; can't de-dupe a persisting degradation."
    return 1
  }
  grep -Fq '>"$SIG_FILE"' "$F" || {
    err "$F" "REGRESSION — no longer WRITES the problem signature file; can't de-dupe a persisting degradation."
    return 1
  }
  grep -Fq 'rm -f "$SIG_FILE"' "$F" || {
    err "$F" "REGRESSION — no longer CLEARS the signature on recovery; a fresh degradation wouldn't re-alert."
    return 1
  }
  grep -Fq '"$cur_sig" = "$prev_sig"' "$F" || {
    err "$F" "REGRESSION — the persisting-problem de-dup comparison is gone; the alarm would re-page every cycle."
    return 1
  }
  grep -Fq '[ -n "$prev_sig" ]' "$F" || {
    err "$F" "REGRESSION — the RECOVERED edge guard ('\$prev_sig' non-empty) is gone."
    return 1
  }
  local n
  n="$(grep -Ec '^[[:space:]]+push "' "$F")"
  if [ "$n" -ne 2 ]; then
    err "$F" "REGRESSION — expected EXACTLY 2 push calls (one DEGRADED, one RECOVERED) but found $n."
    return 1
  fi
  echo "OK: edge-triggered via signature file (reads/writes/clears, de-dup + RECOVERED guard, exactly 2 pushes)"
}

# ── Check 5 ── always writes status + heartbeat; notifier fail-soft ───────────
chk5() {
  local root="${1:-.}"
  local F="$root/$WATCH_REL"
  test -f "$F" || { err "$F" "missing — required for the eval-arena-trend-watch guard"; return 1; }

  grep -Fq '>"$STATUS.tmp" && mv "$STATUS.tmp" "$STATUS"' "$F" || {
    err "$F" "REGRESSION — no longer atomically writes the status file every run."
    err "$F" "The monitor-liveness meta-monitor watches this status file's checked_at — losing it blinds the watcher-of-watchers."
    return 1
  }
  grep -Fq 'log "STATE overall=' "$F" || {
    err "$F" "REGRESSION — the heartbeat STATE log line is gone; liveness/history would be lost."
    return 1
  }
  grep -Fq '[ -z "$NOTIFY_CMD" ] && return 0' "$F" || {
    err "$F" "REGRESSION — the notifier is no longer FAIL-SOFT; a missing channel could break the run instead of just logging."
    return 1
  }
  echo "OK: always writes status (atomic) + heartbeat STATE log; notifier fail-soft"
}

# ── Check 6 ── wired into install.sh ──────────────────────────────────────────
chk6() {
  local root="${1:-.}"
  local F="$root/$INSTALL_REL"
  test -f "$F" || { err "$F" "missing — required for the eval-arena-trend-watch guard"; return 1; }

  grep -Eq 'install .*sbin/eval-arena-trend-watch' "$F" || {
    err "$F" "REGRESSION — install.sh no longer installs sbin/eval-arena-trend-watch."
    return 1
  }
  grep -Eq 'install .*sbin/eval-arena-trend-validate' "$F" || {
    err "$F" "REGRESSION — install.sh no longer installs sbin/eval-arena-trend-validate (the validator bridge)."
    return 1
  }
  grep -Fq 'eval-arena-trend-watch.service' "$F" || {
    err "$F" "REGRESSION — install.sh no longer installs eval-arena-trend-watch.service."
    return 1
  }
  grep -Fq 'eval-arena-trend-watch.timer' "$F" || {
    err "$F" "REGRESSION — install.sh no longer installs eval-arena-trend-watch.timer."
    return 1
  }
  grep -Eq 'systemctl enable --now eval-arena-trend-watch\.timer' "$F" || {
    err "$F" "REGRESSION — install.sh no longer ENABLES eval-arena-trend-watch.timer; the alarm wouldn't run after a rebuild."
    return 1
  }
  echo "OK: install.sh installs the watcher + bridge + units and enables the timer"
}

# ── Check 7 ── documented in README.md ────────────────────────────────────────
chk7() {
  local root="${1:-.}"
  local F="$root/$README_REL"
  test -f "$F" || { err "$F" "missing — required for the eval-arena-trend-watch guard"; return 1; }

  grep -Fq 'eval-arena-trend-watch' "$F" || {
    err "$F" "REGRESSION — README.md no longer documents eval-arena-trend-watch."
    return 1
  }
  grep -Fiq 'trend strip' "$F" || {
    err "$F" "REGRESSION — README.md lost the 'trend strip' description of this alarm."
    return 1
  }
  echo "OK: README.md documents the eval-arena recorded-run trend honesty alarm"
}

# ── Dispatch ──────────────────────────────────────────────────────────────────
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
      for c in chk1 chk2 chk3 chk4 chk5 chk6 chk7; do "$c" "$ROOT" || rc=1; done
      exit "$rc"
      ;;
    *) echo "unknown check: $CHECK (want chk1..chk7|all)" >&2; exit 2 ;;
  esac
fi
