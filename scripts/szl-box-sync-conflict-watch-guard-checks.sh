# Copyright 2026 SZL Holdings
# SPDX-License-Identifier: Apache-2.0
#
# szl-box-sync-conflict-watch-guard-checks.sh — guard the
# `szl-box-sync-conflict-watch` box alarm from silently regressing.
#
# WHY THIS EXISTS
# `szl-box-sync-conflict-watch` (box-scripts/sbin/szl-box-sync-conflict-watch)
# runs every ~15 min (and right after each szl-box-sync-pull) and pages when the
# box auto-sync could NOT cleanly reconcile /opt/szl/szl-uds-deployment with
# origin/main — i.e. it left UU (unmerged) paths and/or a retained
# `szl-box-sync autostash` stash. That state is otherwise SILENT (no work lost,
# but the tree is half-merged and a sibling's edits sit in a stash). The alarm's
# value rests on a few fragile invariants that produce NO visible symptom when
# broken until a real half-merge goes unalerted:
#   * it still detects UU paths via `git ls-files -u`;
#   * it still detects retained stashes, matched to the EXACT autostash label
#     szl-box-sync writes (so unrelated MANUAL stashes never false-page, and a
#     real sync stash is never missed);
#   * it is EDGE-triggered via a signature file (exactly one page per distinct
#     conflict, one on RECOVERED, never every cycle);
#   * it always writes a fresh status file + heartbeat STATE log and the notifier
#     is FAIL-SOFT;
#   * it NEVER mutates the tree (no pop/drop/clear/reset/checkout/merge/rm) —
#     auto-resolving would destroy a sibling's preserved work;
#   * it stays WIRED into install.sh (copied + timer enabled) and documented in
#     README.md, or a box rebuild silently ships without the alarm.
# This guard is a pure text/lint check (no git, no box) that asserts each one.
#
# The check logic is extracted here (out of the workflow) so it can be UNIT
# TESTED: szl-box-sync-conflict-watch-guard-checks.test.sh feeds each check a
# deliberately-BROKEN fixture and asserts the check FAILS (plus that the pristine
# repo PASSES). A future edit that neuters a check is caught by that self-test.
#
# Usage:
#   szl-box-sync-conflict-watch-guard-checks.sh <check> [root]
#     check : chk1 .. chk8 | all
#     root  : repo root to check (default: current directory)

set -uo pipefail

err() { echo "::error file=$1::$2"; }

WATCH_REL="box-scripts/sbin/szl-box-sync-conflict-watch"
INSTALL_REL="box-scripts/install.sh"
README_REL="box-scripts/README.md"

# ── Check 1 ── exists and parses clean ────────────────────────────────────────
chk1() {
  local root="${1:-.}"
  local F="$root/$WATCH_REL"
  test -f "$F" || {
    err "$F" "REGRESSION — szl-box-sync-conflict-watch is MISSING. The box auto-sync conflict alarm is gone."
    return 1
  }
  local out
  if ! out="$(bash -n "$F" 2>&1)"; then
    err "$F" "REGRESSION — szl-box-sync-conflict-watch does not parse (bash -n failed)."
    echo "$out" | sed 's/^/       | /'
    return 1
  fi
  echo "OK: $F exists and parses clean (bash -n)"
}

# ── Check 2 ── still detects UU (unmerged) paths ──────────────────────────────
chk2() {
  local root="${1:-.}"
  local F="$root/$WATCH_REL"
  test -f "$F" || { err "$F" "missing — required for the szl-box-sync-conflict-watch guard"; return 1; }

  grep -Fq 'ls-files -u' "$F" || {
    err "$F" "REGRESSION — no longer detects unmerged (UU) paths via 'git ls-files -u'; a half-merged tree could go unalerted."
    return 1
  }
  grep -Fq 'unmerged_count' "$F" || {
    err "$F" "REGRESSION — the unmerged-path count is gone; the UU detection can no longer drive an alert."
    return 1
  }
  echo "OK: detects unmerged (UU) paths via git ls-files -u"
}

# ── Check 3 ── still detects the szl-box-sync autostash (exact label only) ─────
chk3() {
  local root="${1:-.}"
  local F="$root/$WATCH_REL"
  test -f "$F" || { err "$F" "missing — required for the szl-box-sync-conflict-watch guard"; return 1; }

  grep -Fq 'stash list' "$F" || {
    err "$F" "REGRESSION — no longer reads 'git stash list'; a retained sync stash could go unalerted."
    return 1
  }
  grep -Fq 'szl-box-sync autostash' "$F" || {
    err "$F" "REGRESSION — the EXACT autostash label ('szl-box-sync autostash') is gone."
    err "$F" "Matching the precise label is what keeps the alarm from false-paging on unrelated MANUAL stashes while still catching real sync stashes."
    return 1
  }
  grep -Fq 'STASH_MATCH' "$F" || {
    err "$F" "REGRESSION — the STASH_MATCH filter is gone; the stash detection no longer scopes to the sync's own autostash."
    return 1
  }
  echo "OK: detects retained 'szl-box-sync autostash' stashes (exact label, manual stashes ignored)"
}

# ── Check 4 ── edge-triggered via the signature file (exactly two pushes) ─────
chk4() {
  local root="${1:-.}"
  local F="$root/$WATCH_REL"
  test -f "$F" || { err "$F" "missing — required for the szl-box-sync-conflict-watch guard"; return 1; }

  grep -Fq 'cat "$SIG_FILE"' "$F" || {
    err "$F" "REGRESSION — no longer READS the problem signature file; can't de-dupe a persisting conflict."
    return 1
  }
  grep -Fq '>"$SIG_FILE"' "$F" || {
    err "$F" "REGRESSION — no longer WRITES the problem signature file; can't de-dupe a persisting conflict."
    return 1
  }
  grep -Fq 'rm -f "$SIG_FILE"' "$F" || {
    err "$F" "REGRESSION — no longer CLEARS the signature on recovery; a fresh conflict wouldn't re-alert."
    return 1
  }
  grep -Fq '"$cur_sig" = "$prev_sig"' "$F" || {
    err "$F" "REGRESSION — the persisting-conflict de-dup comparison is gone; the alarm would re-page every cycle."
    return 1
  }
  grep -Fq '[ -n "$prev_sig" ]' "$F" || {
    err "$F" "REGRESSION — the RECOVERED edge guard ('\$prev_sig' non-empty) is gone."
    return 1
  }
  local n
  n="$(grep -Ec '^[[:space:]]+push "' "$F")"
  if [ "$n" -ne 2 ]; then
    err "$F" "REGRESSION — expected EXACTLY 2 push calls (one CONFLICT, one RECOVERED) but found $n."
    return 1
  fi
  echo "OK: edge-triggered via signature file (reads/writes/clears, de-dup + RECOVERED guard, exactly 2 pushes)"
}

# ── Check 5 ── always writes status + heartbeat; notifier fail-soft ───────────
chk5() {
  local root="${1:-.}"
  local F="$root/$WATCH_REL"
  test -f "$F" || { err "$F" "missing — required for the szl-box-sync-conflict-watch guard"; return 1; }

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

# ── Check 6 ── NEVER mutates the tree (read-only; never auto-resolves) ────────
chk6() {
  local root="${1:-.}"
  local F="$root/$WATCH_REL"
  test -f "$F" || { err "$F" "missing — required for the szl-box-sync-conflict-watch guard"; return 1; }

  # The whole point is to REPORT, never auto-resolve: auto-popping/dropping a
  # stash or resetting the tree would destroy a sibling's preserved work. Assert
  # the watcher's CODE contains none of the mutating git commands. The alarm's
  # own detection only ever uses the read-only `git ls-files -u` and
  # `git stash list` plus the human-facing `git status` in its alert text. We
  # strip comment-only lines first so the header's prose description of the
  # failure mode (which names "stash pop" etc. to explain what the watcher is
  # FOR) is not mistaken for a command the watcher RUNS.
  local code pat
  code="$(grep -vE '^[[:space:]]*#' "$F")"
  for pat in \
    'stash pop' 'stash drop' 'stash clear' 'stash apply' \
    'reset --hard' 'reset --merge' 'checkout --' 'git rm ' 'git merge' ; do
    if printf '%s\n' "$code" | grep -Fq -- "$pat"; then
      err "$F" "REGRESSION — watcher appears to MUTATE the tree ('$pat'). It must be READ-ONLY: auto-resolving would destroy a sibling's preserved work."
      return 1
    fi
  done
  echo "OK: read-only — never pops/drops/clears/resets/checks-out/merges/rm (no auto-resolve)"
}

# ── Check 7 ── wired into install.sh ──────────────────────────────────────────
chk7() {
  local root="${1:-.}"
  local F="$root/$INSTALL_REL"
  test -f "$F" || { err "$F" "missing — required for the szl-box-sync-conflict-watch guard"; return 1; }

  grep -Eq 'install .*sbin/szl-box-sync-conflict-watch' "$F" || {
    err "$F" "REGRESSION — install.sh no longer installs sbin/szl-box-sync-conflict-watch."
    return 1
  }
  grep -Fq 'szl-box-sync-conflict-watch.service' "$F" || {
    err "$F" "REGRESSION — install.sh no longer installs szl-box-sync-conflict-watch.service."
    return 1
  }
  grep -Fq 'szl-box-sync-conflict-watch.timer' "$F" || {
    err "$F" "REGRESSION — install.sh no longer installs szl-box-sync-conflict-watch.timer."
    return 1
  }
  grep -Eq 'systemctl enable --now szl-box-sync-conflict-watch\.timer' "$F" || {
    err "$F" "REGRESSION — install.sh no longer ENABLES szl-box-sync-conflict-watch.timer; the alarm wouldn't run after a rebuild."
    return 1
  }
  echo "OK: install.sh installs the script + units and enables the timer"
}

# ── Check 8 ── documented in README.md ────────────────────────────────────────
chk8() {
  local root="${1:-.}"
  local F="$root/$README_REL"
  test -f "$F" || { err "$F" "missing — required for the szl-box-sync-conflict-watch guard"; return 1; }

  grep -Fq 'szl-box-sync-conflict-watch' "$F" || {
    err "$F" "REGRESSION — README.md no longer documents szl-box-sync-conflict-watch."
    return 1
  }
  grep -Fiq 'autostash' "$F" || {
    err "$F" "REGRESSION — README.md lost the 'autostash'/retained-stash description of this alarm."
    return 1
  }
  echo "OK: README.md documents the box auto-sync conflict alarm"
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
    chk8) chk8 "$ROOT" ;;
    all)
      rc=0
      for c in chk1 chk2 chk3 chk4 chk5 chk6 chk7 chk8; do "$c" "$ROOT" || rc=1; done
      exit "$rc"
      ;;
    *) echo "unknown check: $CHECK (want chk1..chk8|all)" >&2; exit 2 ;;
  esac
fi
