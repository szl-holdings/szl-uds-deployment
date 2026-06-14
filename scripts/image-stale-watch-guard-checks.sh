#!/usr/bin/env bash
# Copyright 2026 SZL Holdings
# SPDX-License-Identifier: Apache-2.0
#
# image-stale-watch-guard-checks.sh — guard the `szl-image-stale-watch` box
# alarm (the LIVE-IMAGE-BEHIND-origin/main alarm for a11oy + killinchu) from
# silently regressing.
#
# WHY THIS EXISTS
# `szl-image-stale-watch` (box-scripts/sbin/szl-image-stale-watch) is a periodic
# alarm: every ~15 min it runs `<svc>-rebuild --verify-only` for a11oy and
# killinchu and pages the team when a live container's image has fallen BEHIND
# published origin/main (already-merged code that was never rebuilt onto the
# box). Its value rests on a few fragile behaviours that produce NO visible
# symptom when broken until real drift goes un-alerted:
#   * drift first seen pages EXACTLY once (OK->ALERT edge);
#   * while still drifted it DE-DUPEs (never re-pages — no alert storm);
#   * once rebuilt it pages RECOVERED once, then stays quiet;
#   * a missing rebuild helper / a verify rc other than 0|5 (repo missing, fetch
#     failed, docker down) is a true NO-OP (exit 0, no page) and never a FALSE
#     recovered (the baseline survives a transient outage);
#   * it NEVER rebuilds — it only ever calls the helper with `--verify-only`
#     (a rebuild recreates the live container and must be an operator decision);
#   * the alert NAMES the repo and the lagging commit so the operator can act;
#   * it stays WIRED into install.sh (script + units copied, timer enabled) and
#     documented in README.md, or a box rebuild silently ships without the alarm.
#
# Unlike a pure text/lint guard, the behavioural checks EXERCISE the real script
# in a hermetic sandbox: a stub `<svc>-rebuild` (which records every argv and
# returns a scripted exit code) + a capturing notifier. The check logic is
# extracted here (out of the workflow) so it can be UNIT TESTED:
# image-stale-watch-guard-checks.test.sh feeds each check a deliberately-BROKEN
# copy of the script and asserts the check FAILS (plus that the pristine repo
# PASSES), so a future edit that neuters a check — green while guarding nothing —
# is caught by that self-test, not in production.
#
# Usage:
#   image-stale-watch-guard-checks.sh <check> [root]
#     check : chk1 | chk2 | chk3 | chk4 | chk5 | chk6 | chk7 | all
#     root  : repo root to check (default: current directory)
#
# Each check exits 0 when the invariant holds and non-zero (printing a GitHub
# ::error annotation) when it is regressed.

set -uo pipefail

# Paths (relative to a repo root) of the files this guard inspects.
WATCH_REL="box-scripts/sbin/szl-image-stale-watch"
INSTALL_REL="box-scripts/install.sh"
README_REL="box-scripts/README.md"

# err FILE MESSAGE — emit a GitHub Actions error annotation.
err() { echo "::error file=$1::$2"; }

# ── Hermetic sandbox ──────────────────────────────────────────────────────────
# _mk_sandbox -> echo a fresh dir containing:
#   sbin/a11oy-rebuild   stub: appends its argv to $d/rebuild-calls.log, then
#                        exits per the scenario in $d/scenario (drift=5/sync=0/
#                        error=3). Prints representative verify-only output.
#   notify               capturing notifier: each invocation appends stdin + an
#                        <<<ENDPAGE>>> sentinel to $d/pages (so pages are
#                        counted by sentinel, regardless of message newlines).
#   state/ , log/        isolated state + log dirs.
_mk_sandbox() {
  local d
  d="$(mktemp -d)"
  mkdir -p "$d/sbin" "$d/state" "$d/log"
  cat >"$d/sbin/a11oy-rebuild" <<'STUB'
#!/usr/bin/env bash
d="$(cd "$(dirname "$0")/.." && pwd)"
printf '%s\n' "$*" >>"$d/rebuild-calls.log"
sc="$(cat "$d/scenario" 2>/dev/null || echo sync)"
case "$sc" in
  drift)
    echo "[a11oy-rebuild] VERIFY FAIL [serve] serve.py (aaaa) != image:/app/serve.py (bbbb)"
    echo "[a11oy-rebuild] VERIFY SUMMARY: serve=FAIL"
    echo "[a11oy-rebuild] verify-only: FAIL"; exit 5 ;;
  sync)
    echo "[a11oy-rebuild] verify-only: PASS"; exit 0 ;;
  error)
    echo "[a11oy-rebuild] FATAL: git fetch failed" >&2; exit 3 ;;
  *) exit 0 ;;
esac
STUB
  chmod +x "$d/sbin/a11oy-rebuild"
  cat >"$d/notify" <<'NTFY'
#!/usr/bin/env bash
{ cat; printf '\n<<<ENDPAGE>>>\n'; } >>"$PAGES_FILE"
NTFY
  chmod +x "$d/notify"
  echo "$d"
}

# _run WATCH SANDBOX — run the real alarm against the sandbox, single service
# "a11oy", capturing pages. Echoes nothing; sets global LAST_RC.
_run() {
  local F="$1" d="$2"
  TARGETS="a11oy" \
  REBUILD_DIR="$d/sbin" \
  A11OY_REPO_DIR="$d/repo-absent" \
  A11OY_BRANCH="main" \
  STATE_DIR="$d/state" \
  LOG_DIR="$d/log" \
  NOTIFY_CMD="$d/notify" \
  PAGES_FILE="$d/pages" \
  bash "$F" >/dev/null 2>&1
  LAST_RC=$?
}

# _pages SANDBOX -> number of pages captured so far.
_pages() { grep -c '<<<ENDPAGE>>>' "$1/pages" 2>/dev/null || echo 0; }

# _set_scenario SANDBOX drift|sync|error
_set_scenario() { printf '%s' "$2" >"$1/scenario"; }

# ── Check 1 ───────────────────────────────────────────────────────────────────
# The alarm script exists and parses clean under `bash -n`.
chk1() {
  local root="${1:-.}"; local F="$root/$WATCH_REL" out
  test -f "$F" || { err "$F" "REGRESSION — szl-image-stale-watch is MISSING. The live-image-staleness alarm is gone."; return 1; }
  if ! out="$(bash -n "$F" 2>&1)"; then
    err "$F" "REGRESSION — szl-image-stale-watch does not parse (bash -n failed)."
    echo "$out" | sed 's/^/       | /'
    return 1
  fi
  echo "OK: $F exists and parses clean (bash -n)"
}

# ── Check 2 ───────────────────────────────────────────────────────────────────
# It determines staleness by running the rebuild helper with --verify-only — the
# only source of the in-sync/drift verdict. Without this the alarm has nothing to
# judge.
chk2() {
  local root="${1:-.}"; local F="$root/$WATCH_REL"
  test -f "$F" || { err "$F" "missing — required for the image-stale-watch guard"; return 1; }
  grep -Eq '"\$bin"[[:space:]]+--verify-only' "$F" || {
    err "$F" "REGRESSION — szl-image-stale-watch no longer runs the rebuild helper with --verify-only; it has no source for the in-sync/drift verdict."
    return 1
  }
  echo "OK: szl-image-stale-watch runs \$bin --verify-only for its verdict"
}

# ── Check 3 ───────────────────────────────────────────────────────────────────
# Edge lifecycle (BEHAVIOURAL) in ONE persistent sandbox:
#   A  drift, fresh state    -> ALERT, page EXACTLY once, names repo + commit
#   B  still drift (prev A)  -> DE-DUPE, zero pages
#   C  in sync (prev ALERT)  -> RECOVERED, page exactly once
#   D  in sync (prev OK)     -> steady, zero pages
chk3() {
  local root="${1:-.}"; local F="$root/$WATCH_REL" d before after page
  test -f "$F" || { err "$F" "missing — required for the image-stale-watch guard"; return 1; }
  d="$(_mk_sandbox)"

  # A: drift -> ALERT(1)
  _set_scenario "$d" drift
  _run "$F" "$d"
  [ "$LAST_RC" -eq 0 ] || { err "$F" "REGRESSION — alarm exited $LAST_RC (want 0) on a drift run."; rm -rf "$d"; return 1; }
  [ "$(_pages "$d")" -eq 1 ] || { err "$F" "REGRESSION — first drift did not page EXACTLY once (got $(_pages "$d"))."; rm -rf "$d"; return 1; }
  [ "$(cat "$d/state/last_status.a11oy" 2>/dev/null)" = "ALERT" ] || { err "$F" "REGRESSION — drift did not persist last_status=ALERT (de-dupe baseline lost)."; rm -rf "$d"; return 1; }
  # the page must NAME the repo + the lagging commit (the core requirement).
  page="$(cat "$d/pages")"
  printf '%s' "$page" | grep -Eq 'BEHIND .*origin/main' || { err "$F" "REGRESSION — the ALERT does not say the image is BEHIND origin/main."; rm -rf "$d"; return 1; }
  printf '%s' "$page" | grep -Fq 'repo=a11oy' || { err "$F" "REGRESSION — the ALERT does not name the repo."; rm -rf "$d"; return 1; }
  printf '%s' "$page" | grep -Fq 'running=' || { err "$F" "REGRESSION — the ALERT does not name the lagging commit (running=/published= fields)."; rm -rf "$d"; return 1; }

  # B: still drift -> de-dupe (0 more)
  before="$(_pages "$d")"
  _run "$F" "$d"
  after="$(_pages "$d")"
  [ "$after" -eq "$before" ] || { err "$F" "REGRESSION — a STILL-drifted service re-paged (de-dupe broken): $before -> $after."; rm -rf "$d"; return 1; }

  # C: in sync -> RECOVERED(1)
  _set_scenario "$d" sync
  before="$(_pages "$d")"
  _run "$F" "$d"
  after="$(_pages "$d")"
  [ "$after" -eq "$((before+1))" ] || { err "$F" "REGRESSION — recovery did not page exactly once: $before -> $after."; rm -rf "$d"; return 1; }
  [ "$(cat "$d/state/last_status.a11oy" 2>/dev/null)" = "OK" ] || { err "$F" "REGRESSION — recovery did not reset last_status=OK."; rm -rf "$d"; return 1; }

  # D: steady in sync -> 0 more
  before="$(_pages "$d")"
  _run "$F" "$d"
  after="$(_pages "$d")"
  [ "$after" -eq "$before" ] || { err "$F" "REGRESSION — a steady in-sync service paged: $before -> $after."; rm -rf "$d"; return 1; }

  rm -rf "$d"
  echo "OK: edge lifecycle — drift->ALERT(1, named), still-drift de-dupe(0), recovered(1), steady(0)"
}

# ── Check 4 ───────────────────────────────────────────────────────────────────
# No-op safety (BEHAVIOURAL): a missing rebuild helper, and a verify rc other
# than 0|5, must each exit 0 with NO page — and must NEVER emit a FALSE recovered
# (so a prev=ALERT baseline survives a transient outage).
chk4() {
  local root="${1:-.}"; local F="$root/$WATCH_REL" d
  test -f "$F" || { err "$F" "missing — required for the image-stale-watch guard"; return 1; }

  # 4a. helper absent -> no-op, no page, no baseline written.
  d="$(_mk_sandbox)"; rm -f "$d/sbin/a11oy-rebuild"
  _run "$F" "$d"
  [ "$LAST_RC" -eq 0 ] || { err "$F" "REGRESSION — missing rebuild helper did not exit 0 (got $LAST_RC)."; rm -rf "$d"; return 1; }
  [ "$(_pages "$d")" -eq 0 ] || { err "$F" "REGRESSION — missing rebuild helper paged (should be a silent no-op)."; rm -rf "$d"; return 1; }
  [ ! -f "$d/state/last_status.a11oy" ] || { err "$F" "REGRESSION — missing rebuild helper wrote a baseline (should leave state untouched)."; rm -rf "$d"; return 1; }
  rm -rf "$d"

  # 4b. verify rc=3 (error), prev=ALERT -> no page, baseline stays ALERT.
  d="$(_mk_sandbox)"; mkdir -p "$d/state"; echo ALERT >"$d/state/last_status.a11oy"
  _set_scenario "$d" error
  _run "$F" "$d"
  [ "$LAST_RC" -eq 0 ] || { err "$F" "REGRESSION — a verify error (rc=3) did not exit 0 (got $LAST_RC)."; rm -rf "$d"; return 1; }
  [ "$(_pages "$d")" -eq 0 ] || { err "$F" "REGRESSION — a verify error paged (should be fail-soft no-op)."; rm -rf "$d"; return 1; }
  [ "$(cat "$d/state/last_status.a11oy" 2>/dev/null)" = "ALERT" ] || { err "$F" "REGRESSION — a verify error FALSE-recovered (flipped the ALERT baseline)."; rm -rf "$d"; return 1; }
  rm -rf "$d"
  echo "OK: helper-absent / verify-error each exit 0, never page, never false-recover"
}

# ── Check 5 ───────────────────────────────────────────────────────────────────
# It NEVER rebuilds. The ONLY invocation of the rebuild helper must carry
# --verify-only. Asserted statically (positive grep) AND behaviourally (across an
# alert+recovery run, EVERY recorded argv contained --verify-only, none bare).
chk5() {
  local root="${1:-.}"; local F="$root/$WATCH_REL" d bare
  test -f "$F" || { err "$F" "missing — required for the image-stale-watch guard"; return 1; }

  grep -Eq '"\$bin"[[:space:]]+--verify-only' "$F" || {
    err "$F" "REGRESSION — no '\$bin --verify-only' invocation found; the alarm may rebuild (recreate the live container) instead of verifying."
    return 1
  }

  d="$(_mk_sandbox)"
  _set_scenario "$d" drift; _run "$F" "$d"
  _set_scenario "$d" sync;  _run "$F" "$d"
  if [ ! -s "$d/rebuild-calls.log" ]; then
    err "$F" "REGRESSION — the rebuild helper was never invoked (cannot prove it only verifies)."
    rm -rf "$d"; return 1
  fi
  # any recorded invocation lacking --verify-only is a (would-be) real rebuild.
  bare="$(grep -vc -- '--verify-only' "$d/rebuild-calls.log")"
  if [ "$bare" -ne 0 ]; then
    err "$F" "REGRESSION — $bare rebuild-helper invocation(s) ran WITHOUT --verify-only (a real rebuild). This watcher must only verify."
    rm -rf "$d"; return 1
  fi
  rm -rf "$d"
  echo "OK: never rebuilds (every rebuild-helper call carried --verify-only, statically + at runtime)"
}

# ── Check 6 ───────────────────────────────────────────────────────────────────
# Still wired into install.sh: the sbin script + the .service and .timer units
# are copied, and the timer is enabled. Otherwise a box rebuild ships without it.
chk6() {
  local root="${1:-.}"; local F="$root/$INSTALL_REL"
  test -f "$F" || { err "$F" "missing — required for the image-stale-watch guard"; return 1; }
  grep -Eq 'install .*sbin/szl-image-stale-watch' "$F" || { err "$F" "REGRESSION — install.sh no longer installs sbin/szl-image-stale-watch."; return 1; }
  grep -Fq 'szl-image-stale-watch.service' "$F" || { err "$F" "REGRESSION — install.sh no longer installs szl-image-stale-watch.service."; return 1; }
  grep -Fq 'szl-image-stale-watch.timer' "$F" || { err "$F" "REGRESSION — install.sh no longer installs szl-image-stale-watch.timer."; return 1; }
  grep -Eq 'systemctl enable --now szl-image-stale-watch\.timer' "$F" || { err "$F" "REGRESSION — install.sh no longer ENABLES szl-image-stale-watch.timer; the alarm wouldn't run after a rebuild."; return 1; }
  echo "OK: install.sh installs the script + units and enables the timer"
}

# ── Check 7 ───────────────────────────────────────────────────────────────────
# Still documented in README.md so an operator restoring the box knows the alarm
# exists and how to verify it.
chk7() {
  local root="${1:-.}"; local F="$root/$README_REL"
  test -f "$F" || { err "$F" "missing — required for the image-stale-watch guard"; return 1; }
  grep -Fq 'szl-image-stale-watch' "$F" || { err "$F" "REGRESSION — README.md no longer documents szl-image-stale-watch."; return 1; }
  grep -Fiq 'live image staleness' "$F" || { err "$F" "REGRESSION — README.md lost the 'live image staleness' section describing this alarm."; return 1; }
  echo "OK: README.md documents the szl-image-stale-watch live image staleness alarm"
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
