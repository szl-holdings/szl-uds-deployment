# Copyright 2026 SZL Holdings
# SPDX-License-Identifier: Apache-2.0
#
# ns-scratch-stale-watch-guard-checks.sh — guard the `szl-ns-scratch-stale-watch`
# box guard (the EXPIRED labeled scratch-namespace alarm) from silently
# regressing.
#
# WHY THIS EXISTS
# `szl-ns-scratch-stale-watch` (box-scripts/sbin/szl-ns-scratch-stale-watch) is a
# periodic alarm: every ~30 min it wraps `szl-ns-scratch list-stale` and pages the
# team when a LABELED scratch namespace on the uds-szl-demo cluster has outlived
# its declared `szl.io/ttl-days` expiry — the quiet failure its sibling
# (`szl-ns-scratch-watch`, the UNLABELED alarm) does not catch. These expired
# namespaces silently eat the 2-vCPU box's headroom. Its value depends on a few
# fragile behaviours that are easy to break with a well-meaning refactor and that
# produce NO visible symptom until a real expired namespace goes unalerted:
#   * an EXPIRED namespace present must page EXACTLY once (the OK->ALERT edge);
#   * while still expired it must DE-DUPE (page zero more times), never re-page;
#   * once cleaned up it must page RECOVERED exactly once, then stay quiet;
#   * cluster absent / unreachable / the scratch tool's "nothing to do" sentinel
#     must each be a true NO-OP (exit 0, no page) — a stopped k3d cluster must
#     never turn into a paging storm, and must never emit a FALSE recovered;
#   * it must NEVER auto-delete a namespace (cleanup confirms with the owner);
#   * it must stay WIRED into install.sh (copied + timer enabled) and documented
#     in README.md, or a box rebuild silently ships without the alarm.
#
# Unlike a pure text/lint guard, this one EXERCISES the real script: each
# behavioural check builds a hermetic sandbox (stub `k3d`/`kubectl`, a fake
# `szl-ns-scratch list-stale`, and a capturing notifier) and actually runs
# box-scripts/sbin/szl-ns-scratch-stale-watch against fixture scenarios, then
# asserts the observed behaviour. The static checks (exists/parses, wired,
# documented) mirror the sibling ns-scratch-watch-guard.
#
# The check logic is extracted here (out of the workflow) so it can be UNIT
# TESTED: ns-scratch-stale-watch-guard-checks.test.sh feeds each check a
# deliberately-BROKEN copy of the script and asserts the check FAILS (plus that
# the pristine repo PASSES). A future edit that neuters a check — making it pass
# vacuously, green while guarding nothing — is caught by that self-test, not in
# production.
#
# Usage:
#   ns-scratch-stale-watch-guard-checks.sh <check> [root]
#     check : chk1 | chk2 | chk3 | chk4 | chk5 | chk6 | chk7 | all
#     root  : repo root to check (default: current directory)
#
# Each check exits 0 when the invariant holds and non-zero (printing a GitHub
# ::error annotation) when it is regressed.

set -uo pipefail

# err FILE MESSAGE — emit a GitHub Actions error annotation.
err() { echo "::error file=$1::$2"; }

# Paths (relative to a repo root) of the files this guard inspects.
WATCH_REL="box-scripts/sbin/szl-ns-scratch-stale-watch"
INSTALL_REL="box-scripts/install.sh"
README_REL="box-scripts/README.md"

# ── Sandbox plumbing ──────────────────────────────────────────────────────────
# _mk_sandbox — build a hermetic dir with stub k3d/kubectl/notifier + a fake
# `szl-ns-scratch list-stale`, and echo its path. The real stale-watch script is
# run with PATH/SCRATCH_BIN/NOTIFY_CMD/STATE_DIR pointed here so NOTHING touches a
# real cluster or pages a real channel.
#
# Stub knobs (env, read by the stubs at run time):
#   K3D_RC     : exit code of `k3d kubeconfig write` (0 = cluster present)
#   READYZ_RC  : exit code of the kubectl `/readyz` probe (0 = reachable)
#   SCEN       : list-stale fixture — expired | none | nothing
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
# Fake `szl-ns-scratch`. Only list-stale is exercised. Line shape mirrors the
# real tool: "<ns>  age=Xd threshold=Yd owner=Z".
[ "$1" = "list-stale" ] || exit 0
case "${SCEN:-none}" in
  expired)
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

# _run TARGET SANDBOX SCEN [K3D_RC] [READYZ_RC] — run the real stale-watch script
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

# ── Check 1 ───────────────────────────────────────────────────────────────────
# The guard script exists and parses clean under `bash -n`. If it is missing or
# broken, the alarm cannot run at all.
chk1() {
  local root="${1:-.}"
  local F="$root/$WATCH_REL"
  test -f "$F" || {
    err "$F" "REGRESSION — szl-ns-scratch-stale-watch is MISSING. The expired scratch-namespace alarm is gone."
    return 1
  }
  local out
  if ! out="$(bash -n "$F" 2>&1)"; then
    err "$F" "REGRESSION — szl-ns-scratch-stale-watch does not parse (bash -n failed)."
    echo "$out" | sed 's/^/       | /'
    return 1
  fi
  echo "OK: $F exists and parses clean (bash -n)"
}

# ── Check 2 ───────────────────────────────────────────────────────────────────
# It still shells out to the audit tool with `list-stale` — the only source of
# the expired/past-TTL namespace set. Without this the alarm has nothing to judge.
chk2() {
  local root="${1:-.}"
  local F="$root/$WATCH_REL"
  test -f "$F" || { err "$F" "missing — required for the ns-scratch-stale-watch guard"; return 1; }

  grep -Fq 'list-stale' "$F" || {
    err "$F" "REGRESSION — szl-ns-scratch-stale-watch no longer invokes 'szl-ns-scratch list-stale'."
    err "$F" "It has no source for the EXPIRED (past-TTL) labeled scratch-namespace set to alarm on."
    return 1
  }
  # The list-stale call must run against the audit binary (SCRATCH_BIN), not be a
  # stray comment/log mention.
  grep -Eq '"\$SCRATCH_BIN"[[:space:]]+list-stale' "$F" || {
    err "$F" "REGRESSION — 'list-stale' is no longer executed via \$SCRATCH_BIN (the szl-ns-scratch tool)."
    return 1
  }
  echo "OK: szl-ns-scratch-stale-watch shells out to \$SCRATCH_BIN list-stale"
}

# ── Check 3 ───────────────────────────────────────────────────────────────────
# Edge lifecycle (BEHAVIOURAL): drive the real script through the four
# transitions in ONE persistent sandbox and assert each one:
#   A  expired present, fresh state   -> ALERT, page EXACTLY once
#   B  still expired (prev ALERT)     -> DE-DUPE, zero pages
#   C  none present (prev ALERT)      -> RECOVERED, page exactly once
#   D  none present (prev OK)         -> steady, zero pages
chk3() {
  local root="${1:-.}"
  local F="$root/$WATCH_REL"
  test -f "$F" || { err "$F" "missing — required for the ns-scratch-stale-watch guard"; return 1; }

  local d cap n; d="$(_mk_sandbox)"; cap="$d/notify.cap"

  # A — expired present, fresh state.
  : >"$cap"
  _run "$F" "$d" expired
  [ "$RUN_RC" -eq 0 ] || { err "$F" "REGRESSION — run errored (rc=$RUN_RC) when an expired scratch namespace was present."; rm -rf "$d"; return 1; }
  n="$(_pages "$cap")"
  [ "$n" -eq 1 ] || { err "$F" "REGRESSION — an expired scratch namespace must page EXACTLY once on the OK->ALERT edge (got $n)."; rm -rf "$d"; return 1; }
  grep -Fq 'PAST their declared expiry' "$cap" || { err "$F" "REGRESSION — the ALERT page lost its 'PAST their declared expiry' body."; rm -rf "$d"; return 1; }
  grep -q '"overall":"ALERT"' "$d/state/status.json" 2>/dev/null || { err "$F" "REGRESSION — status.json is not ALERT while an expired namespace is present."; rm -rf "$d"; return 1; }
  [ "$(cat "$d/state/last_status" 2>/dev/null)" = "ALERT" ] || { err "$F" "REGRESSION — last_status not persisted as ALERT (de-dupe state lost)."; rm -rf "$d"; return 1; }

  # B — still expired (prev ALERT): must de-dupe.
  : >"$cap"
  _run "$F" "$d" expired
  n="$(_pages "$cap")"
  [ "$n" -eq 0 ] || { err "$F" "REGRESSION — de-dupe broken: re-paged while still expired (got $n, want 0). This is the alert-storm failure."; rm -rf "$d"; return 1; }

  # C — none present (prev ALERT): RECOVERED once.
  : >"$cap"
  _run "$F" "$d" none
  n="$(_pages "$cap")"
  [ "$n" -eq 1 ] || { err "$F" "REGRESSION — recovery (all expired cleaned up) must page EXACTLY once (got $n)."; rm -rf "$d"; return 1; }
  grep -Fq 'RECOVERED' "$cap" || { err "$F" "REGRESSION — the recovery page lost its 'RECOVERED' marker."; rm -rf "$d"; return 1; }
  grep -q '"overall":"OK"' "$d/state/status.json" 2>/dev/null || { err "$F" "REGRESSION — status.json is not OK after recovery."; rm -rf "$d"; return 1; }

  # D — none present (prev OK): steady, silent.
  : >"$cap"
  _run "$F" "$d" none
  n="$(_pages "$cap")"
  [ "$n" -eq 0 ] || { err "$F" "REGRESSION — a steady-OK cycle must not page (got $n)."; rm -rf "$d"; return 1; }

  rm -rf "$d"
  echo "OK: edge lifecycle — expired->ALERT(1), still-expired de-dupe(0), recovered(1), steady-OK(0)"
}

# ── Check 4 ───────────────────────────────────────────────────────────────────
# No-op safety (BEHAVIOURAL): a down/unreachable cluster, or the scratch tool's
# "nothing to do" sentinel, must each exit 0 with NO page — and must never emit a
# FALSE recovered (so prev=ALERT survives a transient outage).
chk4() {
  local root="${1:-.}"
  local F="$root/$WATCH_REL"
  test -f "$F" || { err "$F" "missing — required for the ns-scratch-stale-watch guard"; return 1; }

  local d
  # cluster absent (k3d kubeconfig write fails).
  d="$(_mk_sandbox)"; echo ALERT >"$d/state/last_status"
  _run "$F" "$d" expired 1 0
  [ "$RUN_RC" -eq 0 ] || { err "$F" "REGRESSION — cluster-absent must NO-OP (exit 0); got rc=$RUN_RC. A stopped k3d cluster would now error/page."; rm -rf "$d"; return 1; }
  [ "$(_pages "$d/notify.cap")" -eq 0 ] || { err "$F" "REGRESSION — cluster-absent paged (got a page); a powered-down demo cluster must be silent."; rm -rf "$d"; return 1; }
  [ "$(cat "$d/state/last_status" 2>/dev/null)" = "ALERT" ] || { err "$F" "REGRESSION — cluster-absent flipped last_status (a transient outage would later mask a real ALERT or fake a RECOVERED)."; rm -rf "$d"; return 1; }
  rm -rf "$d"

  # cluster unreachable (readyz probe fails).
  d="$(_mk_sandbox)"; echo ALERT >"$d/state/last_status"
  _run "$F" "$d" expired 0 1
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

  echo "OK: cluster-absent / unreachable / scratch no-op all exit 0, never page, never false-recover"
}

# ── Check 5 ───────────────────────────────────────────────────────────────────
# It NEVER auto-deletes. Per the scratch convention a cleanup must confirm with
# the owner first; this alarm only surfaces the expired set. Asserted both
# statically (no `kubectl delete` in the source) and behaviourally (no destructive
# call reaches the stub cluster during an alert run).
chk5() {
  local root="${1:-.}"
  local F="$root/$WATCH_REL"
  test -f "$F" || { err "$F" "missing — required for the ns-scratch-stale-watch guard"; return 1; }

  # Match an actual command invocation at line-start, NOT the operator-guidance
  # text inside the alert body (which legitimately quotes 'kubectl delete ns <ns>'
  # to tell a human how to clean up).
  if grep -Eq '^[[:space:]]*kubectl[[:space:]]+delete' "$F"; then
    err "$F" "REGRESSION — szl-ns-scratch-stale-watch now runs 'kubectl delete'. This guard must NEVER auto-delete a namespace; cleanup confirms with the owner."
    return 1
  fi

  local d; d="$(_mk_sandbox)"
  _run "$F" "$d" expired
  if grep -Eq '(^| )delete( |$)' "$d/kubectl.log"; then
    err "$F" "REGRESSION — a destructive 'delete' reached the cluster during an alert run."
    rm -rf "$d"; return 1
  fi
  rm -rf "$d"
  echo "OK: never auto-deletes (no 'kubectl delete' in source or at runtime)"
}

# ── Check 6 ───────────────────────────────────────────────────────────────────
# Still wired into install.sh: the sbin script + the .service and .timer units
# are copied, and the timer is enabled. Otherwise a box rebuild ships without the
# alarm running.
chk6() {
  local root="${1:-.}"
  local F="$root/$INSTALL_REL"
  test -f "$F" || { err "$F" "missing — required for the ns-scratch-stale-watch guard"; return 1; }

  grep -Eq 'install .*sbin/szl-ns-scratch-stale-watch' "$F" || {
    err "$F" "REGRESSION — install.sh no longer installs sbin/szl-ns-scratch-stale-watch."
    return 1
  }
  grep -Fq 'szl-ns-scratch-stale-watch.service' "$F" || {
    err "$F" "REGRESSION — install.sh no longer installs szl-ns-scratch-stale-watch.service."
    return 1
  }
  grep -Fq 'szl-ns-scratch-stale-watch.timer' "$F" || {
    err "$F" "REGRESSION — install.sh no longer installs szl-ns-scratch-stale-watch.timer."
    return 1
  }
  grep -Eq 'systemctl enable --now szl-ns-scratch-stale-watch\.timer' "$F" || {
    err "$F" "REGRESSION — install.sh no longer ENABLES szl-ns-scratch-stale-watch.timer; the alarm wouldn't run after a rebuild."
    return 1
  }
  echo "OK: install.sh installs the script + units and enables the timer"
}

# ── Check 7 ───────────────────────────────────────────────────────────────────
# Still documented in README.md so an operator restoring the box after a wipe
# knows the alarm exists and how to verify it.
chk7() {
  local root="${1:-.}"
  local F="$root/$README_REL"
  test -f "$F" || { err "$F" "missing — required for the ns-scratch-stale-watch guard"; return 1; }

  grep -Fq 'szl-ns-scratch-stale-watch' "$F" || {
    err "$F" "REGRESSION — README.md no longer documents szl-ns-scratch-stale-watch."
    return 1
  }
  grep -Fiq 'expired scratch-namespace alarm' "$F" || {
    err "$F" "REGRESSION — README.md lost the 'expired scratch-namespace alarm' section describing this guard."
    return 1
  }
  echo "OK: README.md documents the szl-ns-scratch-stale-watch expired scratch-namespace alarm"
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
