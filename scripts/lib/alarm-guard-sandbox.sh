# Copyright 2026 SZL Holdings
# SPDX-License-Identifier: Apache-2.0
#
# alarm-guard-sandbox.sh — shared hermetic sandbox + edge-lifecycle runner sourced
# by the scratch-namespace box-alarm guard-checks
# (scripts/ns-scratch-*-watch-guard-checks.sh).
#
# WHY THIS EXISTS
# The szl-ns-scratch alarms (szl-ns-scratch-watch / szl-ns-scratch-stale-watch)
# are near-identical edge-triggered watchers: each wraps a `szl-ns-scratch list-*`
# audit subcommand, pages the team once on the OK->ALERT edge, de-dupes while the
# problem persists, pages RECOVERED once when it clears, and treats a stopped/
# unreachable cluster (or the tool's "nothing to do" sentinel) as a true no-op.
# Their guards prove that behaviour by EXERCISING the real script in a hermetic
# sandbox — stub k3d/kubectl, a fake `szl-ns-scratch`, and a capturing notifier —
# rather than by grep alone.
#
# That sandbox and the four-transition edge lifecycle were originally inlined in
# ns-scratch-stale-watch-guard-checks.sh. Extracting them here means every alarm
# guard shares ONE harness: the builder + stubs + edge/no-op runners live in a
# single place (so a fix or a fixture-shape change happens once), and adding
# behavioural coverage to the next alarm guard costs two function calls instead of
# a copy-pasted sandbox.
#
# The fake `szl-ns-scratch` answers ANY `list-*` subcommand from the SCEN env knob
# (its line shape is a superset that both the stale `list-stale` parser, which
# keeps the age/threshold/owner detail, and the unlabeled `list-unlabeled` parser,
# which keeps only the leading namespace name, accept), so a single sandbox drives
# both alarms.
#
# Public surface (functions defined on source):
#   err FILE MSG                          GitHub Actions ::error annotation
#   _mk_sandbox                           build a hermetic dir, echo its path
#   _run TARGET DIR SCEN [K3D_RC] [READYZ_RC]
#                                         run the alarm in the sandbox; sets RUN_RC
#   _pages FILE                           number of pages captured
#   _alarm_edge_lifecycle TARGET ALERT_MARKER
#                                         drive OK->ALERT(1) / de-dupe(0) /
#                                         RECOVERED(1) / steady-OK(0); 0 if intact
#   _alarm_noop_safety TARGET             drive cluster-absent / unreachable /
#                                         scratch no-op; 0 if all are silent no-ops
#                                         that never false-recover

# err FILE MESSAGE — emit a GitHub Actions error annotation.
err() { echo "::error file=$1::$2"; }

# ── Sandbox plumbing ──────────────────────────────────────────────────────────
# _mk_sandbox — build a hermetic dir with stub k3d/kubectl/notifier + a fake
# `szl-ns-scratch`, and echo its path. The real alarm is run with
# PATH/SCRATCH_BIN/NOTIFY_CMD/STATE_DIR pointed here so NOTHING touches a real
# cluster or pages a real channel.
#
# Stub knobs (env, read by the stubs at run time):
#   K3D_RC     : exit code of `k3d kubeconfig write` (0 = cluster present)
#   READYZ_RC  : exit code of the kubectl `/readyz` probe (0 = reachable)
#   SCEN       : list-* fixture — problem | expired | none | nothing
#                (problem and expired are aliases: both emit the flagged set)
_mk_sandbox() {
  local d; d="$(mktemp -d)"
  mkdir -p "$d/bin" "$d/state" "$d/log"

  cat >"$d/bin/k3d" <<'EOS'
#!/usr/bin/env bash
# k3d kubeconfig write <cluster> -> print a kubeconfig path (or fail if absent).
[ "${K3D_RC:-0}" -ne 0 ] && exit "${K3D_RC}"
echo "${FAKE_KC:-/dev/null}"
EOS

  cat >"$d/bin/kubectl" <<'EOS'
#!/usr/bin/env bash
# Record every invocation (so the guard can prove no destructive call is made),
# then answer only the readiness probe.
echo "$*" >>"${KUBECTL_LOG:-/dev/null}"
case " $* " in
  *" --raw=/readyz "*|*"--raw=/readyz"*) exit "${READYZ_RC:-0}" ;;
esac
exit 0
EOS

  cat >"$d/bin/notify-stub" <<'EOS'
#!/usr/bin/env bash
# Capture one page per call. The trailing sentinel lets the guard count pages.
{ cat; printf '\n__NOTIFY_END__\n'; } >>"${NOTIFY_CAPTURE:-/dev/null}"
EOS

  cat >"$d/scratch" <<'EOS'
#!/usr/bin/env bash
# Fake `szl-ns-scratch`. Answers any list-* audit subcommand (list-stale,
# list-unlabeled, ...). The line shape is a superset both alarm parsers accept:
# the stale parser keeps the "age=Xd threshold=Yd owner=Z" detail, the unlabeled
# parser strips to the leading namespace name.
case "$1" in list-*) ;; *) exit 0 ;; esac
case "${SCEN:-none}" in
  problem|expired)
    printf '%s\n' \
      "szl-foo  age=20d threshold=14d owner=rosa" \
      "szl-bar  age=30d threshold=14d owner=joe" ;;
  none) : ;;
  nothing) echo "[szl-ns-scratch] cluster 'uds-szl-demo' not present; nothing to do." >&2 ;;
esac
exit 0
EOS

  chmod +x "$d/bin/k3d" "$d/bin/kubectl" "$d/bin/notify-stub" "$d/scratch"
  : >"$d/notify.cap"
  : >"$d/kubectl.log"
  echo "$d"
}

# _run TARGET SANDBOX SCEN [K3D_RC] [READYZ_RC] — run the real alarm script
# against the sandbox. State persists in the sandbox across calls so edge
# transitions can be exercised. Sets global RUN_RC.
_run() {
  local target="$1" d="$2" scen="$3" k3drc="${4:-0}" readyzrc="${5:-0}"
  PATH="$d/bin:$PATH" \
  SCEN="$scen" K3D_RC="$k3drc" READYZ_RC="$readyzrc" FAKE_KC=/dev/null \
  SCRATCH_BIN="$d/scratch" \
  NOTIFY_CMD="$d/bin/notify-stub" NOTIFY_CAPTURE="$d/notify.cap" \
  KUBECTL_LOG="$d/kubectl.log" \
  STATE_DIR="$d/state" LOG_DIR="$d/log" \
    bash "$target"
  RUN_RC=$?
}

# _pages FILE — number of pages captured.
_pages() { grep -c '__NOTIFY_END__' "$1" 2>/dev/null || true; }

# ── Reusable behavioural runners ──────────────────────────────────────────────
# _alarm_edge_lifecycle TARGET ALERT_MARKER — drive the real alarm through the
# four edge transitions in ONE persistent sandbox and assert each:
#   A  flagged present, fresh state  -> ALERT, page EXACTLY once (body has MARKER)
#   B  still flagged (prev ALERT)    -> DE-DUPE, zero pages
#   C  none present (prev ALERT)     -> RECOVERED, page exactly once
#   D  none present (prev OK)        -> steady, zero pages
# Returns 0 when intact, non-zero (with an ::error) when any transition regresses.
_alarm_edge_lifecycle() {
  local F="$1" alert_marker="$2"
  local d cap n; d="$(_mk_sandbox)"; cap="$d/notify.cap"

  # A — flagged present, fresh state.
  : >"$cap"
  _run "$F" "$d" problem
  [ "$RUN_RC" -eq 0 ] || { err "$F" "REGRESSION — run errored (rc=$RUN_RC) when a flagged scratch namespace was present."; rm -rf "$d"; return 1; }
  n="$(_pages "$cap")"
  [ "$n" -eq 1 ] || { err "$F" "REGRESSION — a flagged scratch namespace must page EXACTLY once on the OK->ALERT edge (got $n)."; rm -rf "$d"; return 1; }
  grep -Fq "$alert_marker" "$cap" || { err "$F" "REGRESSION — the ALERT page lost its '$alert_marker' body."; rm -rf "$d"; return 1; }
  grep -q '"overall":"ALERT"' "$d/state/status.json" 2>/dev/null || { err "$F" "REGRESSION — status.json is not ALERT while a flagged namespace is present."; rm -rf "$d"; return 1; }
  [ "$(cat "$d/state/last_status" 2>/dev/null)" = "ALERT" ] || { err "$F" "REGRESSION — last_status not persisted as ALERT (de-dupe state lost)."; rm -rf "$d"; return 1; }

  # B — still flagged (prev ALERT): must de-dupe.
  : >"$cap"
  _run "$F" "$d" problem
  n="$(_pages "$cap")"
  [ "$n" -eq 0 ] || { err "$F" "REGRESSION — de-dupe broken: re-paged while still flagged (got $n, want 0). This is the alert-storm failure."; rm -rf "$d"; return 1; }

  # C — none present (prev ALERT): RECOVERED once.
  : >"$cap"
  _run "$F" "$d" none
  n="$(_pages "$cap")"
  [ "$n" -eq 1 ] || { err "$F" "REGRESSION — recovery (all flagged cleared) must page EXACTLY once (got $n)."; rm -rf "$d"; return 1; }
  grep -Fq 'RECOVERED' "$cap" || { err "$F" "REGRESSION — the recovery page lost its 'RECOVERED' marker."; rm -rf "$d"; return 1; }
  grep -q '"overall":"OK"' "$d/state/status.json" 2>/dev/null || { err "$F" "REGRESSION — status.json is not OK after recovery."; rm -rf "$d"; return 1; }

  # D — none present (prev OK): steady, silent.
  : >"$cap"
  _run "$F" "$d" none
  n="$(_pages "$cap")"
  [ "$n" -eq 0 ] || { err "$F" "REGRESSION — a steady-OK cycle must not page (got $n)."; rm -rf "$d"; return 1; }

  rm -rf "$d"
  return 0
}

# _alarm_noop_safety TARGET — a down/unreachable cluster, or the scratch tool's
# "nothing to do" sentinel, must each exit 0 with NO page — and must never emit a
# FALSE recovered (so prev=ALERT survives a transient outage).
# Returns 0 when all three are silent no-ops, non-zero (with an ::error) otherwise.
_alarm_noop_safety() {
  local F="$1"
  local d

  # cluster absent (k3d kubeconfig write fails).
  d="$(_mk_sandbox)"; echo ALERT >"$d/state/last_status"
  _run "$F" "$d" problem 1 0
  [ "$RUN_RC" -eq 0 ] || { err "$F" "REGRESSION — cluster-absent must NO-OP (exit 0); got rc=$RUN_RC. A stopped k3d cluster would now error/page."; rm -rf "$d"; return 1; }
  [ "$(_pages "$d/notify.cap")" -eq 0 ] || { err "$F" "REGRESSION — cluster-absent paged (got a page); a powered-down demo cluster must be silent."; rm -rf "$d"; return 1; }
  [ "$(cat "$d/state/last_status" 2>/dev/null)" = "ALERT" ] || { err "$F" "REGRESSION — cluster-absent flipped last_status (a transient outage would later mask a real ALERT or fake a RECOVERED)."; rm -rf "$d"; return 1; }
  rm -rf "$d"

  # cluster unreachable (readyz probe fails).
  d="$(_mk_sandbox)"; echo ALERT >"$d/state/last_status"
  _run "$F" "$d" problem 0 1
  [ "$RUN_RC" -eq 0 ] || { err "$F" "REGRESSION — cluster-unreachable must NO-OP (exit 0); got rc=$RUN_RC."; rm -rf "$d"; return 1; }
  [ "$(_pages "$d/notify.cap")" -eq 0 ] || { err "$F" "REGRESSION — cluster-unreachable paged."; rm -rf "$d"; return 1; }
  rm -rf "$d"

  # scratch tool "nothing to do" sentinel, with prev=ALERT: must NOT false-recover.
  d="$(_mk_sandbox)"; echo ALERT >"$d/state/last_status"
  _run "$F" "$d" nothing
  [ "$RUN_RC" -eq 0 ] || { err "$F" "REGRESSION — scratch-tool no-op must exit 0; got rc=$RUN_RC."; rm -rf "$d"; return 1; }
  [ "$(_pages "$d/notify.cap")" -eq 0 ] || { err "$F" "REGRESSION — scratch-tool no-op produced a (false) page; an empty result during an outage must not be read as RECOVERED."; rm -rf "$d"; return 1; }
  [ "$(cat "$d/state/last_status" 2>/dev/null)" = "ALERT" ] || { err "$F" "REGRESSION — scratch-tool no-op flipped last_status away from ALERT (would mask the later real RECOVERED edge)."; rm -rf "$d"; return 1; }
  rm -rf "$d"

  return 0
}
