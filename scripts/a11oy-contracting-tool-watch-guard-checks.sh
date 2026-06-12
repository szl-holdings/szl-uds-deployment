# Copyright 2026 SZL Holdings
# SPDX-License-Identifier: Apache-2.0
#
# a11oy-contracting-tool-watch-guard-checks.sh -- guard the
# `a11oy-contracting-tool-watch` box watcher (the "a flagship tool module dropped
# out of an app rebuild" proof) from silently regressing.
#
# WHY THIS EXISTS
# `a11oy-contracting-tool-watch` (box-scripts/sbin/a11oy-contracting-tool-watch)
# is a periodic proof that catches the exact failure that once shipped unnoticed:
# a cold rebuild baked an EMPTY szl_contracting.py (md5
# d41d8cd98f00b204e9800998ecf8427e) into a flagship image while the served
# endpoint kept returning 200. An endpoint probe alone CANNOT catch it -- the real
# catch is comparing the md5 of the module baked into <name>:local against the
# committed origin/main source and refusing the empty-file md5. Its value depends
# on a few fragile invariants that produce NO visible symptom when broken:
#   * it must probe BOTH flagship endpoints (a11oy + killinchu) for 200 + a valid
#     envelope (top-level `areas` list + `summary` object);
#   * it must extract the module md5 BAKED INTO the image (docker run cat | md5sum)
#     and gate that leg on docker being present + the image existing;
#   * it must REFUSE the empty-file md5 (EMPTY_MD5 = d41d8cd9...);
#   * it must COMPARE the image md5 against the committed origin/main source;
#   * it must be EDGE-triggered (read + write a last_status state file, both edge
#     guards, exactly two notify calls) so it pages once on OK->ALERT and once on
#     RECOVERED, never every cycle;
#   * it must NO-OP (skip the leg, no page) when docker is absent, an image is
#     not built, or the endpoint is merely unreachable, so a mid-rebuild box
#     never turns into a paging storm;
#   * it must stay WIRED into install.sh (copied + timer enabled) and documented
#     in README.md, or a box rebuild silently ships without the proof.
# This guard is a pure text/lint check (no cluster, no docker) that asserts each
# invariant.
#
# The check logic is extracted here (out of the workflow) so it can be UNIT
# TESTED: a11oy-contracting-tool-watch-guard-checks.test.sh feeds each check a
# deliberately-BROKEN fixture and asserts the check FAILS (plus that the pristine
# repo PASSES). A future edit that neuters a check -- green while guarding
# nothing -- is caught by that self-test, not in production.
#
# Usage:
#   a11oy-contracting-tool-watch-guard-checks.sh <check> [root]
#     check : chk1 | chk2 | ... | chk9 | all
#     root  : repo root to check (default: current directory)
#
# Each check exits 0 when the invariant holds and non-zero (printing a GitHub
# ::error annotation) when it is regressed.

set -uo pipefail

err() { echo "::error file=$1::$2"; }

WATCH_REL="box-scripts/sbin/a11oy-contracting-tool-watch"
INSTALL_REL="box-scripts/install.sh"
README_REL="box-scripts/README.md"

# ── Check 1 ───────────────────────────────────────────────────────────────────
# The watcher exists and parses clean under `bash -n`.
chk1() {
  local root="${1:-.}"
  local F="$root/$WATCH_REL"
  test -f "$F" || {
    err "$F" "REGRESSION -- a11oy-contracting-tool-watch is MISSING. The tool-drop proof is gone."
    return 1
  }
  local out
  if ! out="$(bash -n "$F" 2>&1)"; then
    err "$F" "REGRESSION -- a11oy-contracting-tool-watch does not parse (bash -n failed)."
    echo "$out" | sed 's/^/       | /'
    return 1
  fi
  echo "OK: $F exists and parses clean (bash -n)"
}

# ── Check 2 ───────────────────────────────────────────────────────────────────
# It probes BOTH flagship endpoints for 200 + a valid JSON envelope (top-level
# `areas` list + `summary` object). Dropping a target or the envelope check would
# let an endpoint regression slip through.
chk2() {
  local root="${1:-.}"
  local F="$root/$WATCH_REL"
  test -f "$F" || { err "$F" "missing -- required for the a11oy-contracting-tool-watch guard"; return 1; }

  grep -Fq 'a11oy.net/api/a11oy/v1/contracting' "$F" || {
    err "$F" "REGRESSION -- no longer probes the a11oy contracting endpoint."
    return 1
  }
  grep -Fq 'killinchu.a11oy.net/api/killinchu/v1/contracting' "$F" || {
    err "$F" "REGRESSION -- no longer probes the killinchu contracting endpoint."
    return 1
  }
  grep -Fq '"areas"' "$F" || {
    err "$F" "REGRESSION -- no longer validates the top-level \"areas\" list in the envelope."
    return 1
  }
  grep -Fq '"summary"' "$F" || {
    err "$F" "REGRESSION -- no longer validates the top-level \"summary\" object in the envelope."
    return 1
  }
  echo "OK: probes both flagship endpoints for 200 + a valid areas[]/summary{} envelope"
}

# ── Check 3 ───────────────────────────────────────────────────────────────────
# It extracts the module md5 BAKED INTO the image (docker run cat | md5sum) and
# gates that leg on the image existing (docker image inspect). Replacing the
# baked-image read with anything else would stop catching a dropped module.
chk3() {
  local root="${1:-.}"
  local F="$root/$WATCH_REL"
  test -f "$F" || { err "$F" "missing -- required for the a11oy-contracting-tool-watch guard"; return 1; }

  grep -Fq 'docker run --rm --entrypoint cat' "$F" || {
    err "$F" "REGRESSION -- no longer reads the module BAKED INTO the image (docker run --rm --entrypoint cat)."
    return 1
  }
  grep -Fq 'md5sum' "$F" || {
    err "$F" "REGRESSION -- no longer md5s the baked module (md5sum)."
    return 1
  }
  grep -Fq 'docker image inspect' "$F" || {
    err "$F" "REGRESSION -- no longer gates the integrity leg on the image existing (docker image inspect)."
    return 1
  }
  echo "OK: extracts the md5 of the module baked into the image (docker run cat | md5sum), image-gated"
}

# ── Check 4 ───────────────────────────────────────────────────────────────────
# It REFUSES the empty-file md5 outright -- the exact regression that shipped
# (an empty szl_contracting.py md5s to d41d8cd9...). Losing this makes the proof
# blind to the original incident.
chk4() {
  local root="${1:-.}"
  local F="$root/$WATCH_REL"
  test -f "$F" || { err "$F" "missing -- required for the a11oy-contracting-tool-watch guard"; return 1; }

  grep -Fq 'EMPTY_MD5=' "$F" || {
    err "$F" "REGRESSION -- the EMPTY_MD5 constant is gone; the watcher no longer refuses an empty module."
    return 1
  }
  grep -Fq 'd41d8cd98f00b204e9800998ecf8427e' "$F" || {
    err "$F" "REGRESSION -- the empty-file md5 (d41d8cd98f00b204e9800998ecf8427e) is gone; an empty/missing module would pass."
    return 1
  }
  echo "OK: refuses the empty-file md5 (d41d8cd98f00b204e9800998ecf8427e)"
}

# ── Check 5 ───────────────────────────────────────────────────────────────────
# It COMPARES the baked-image md5 against the committed origin/main source. A
# stale/divergent module baked at rebuild time (non-empty but wrong) is only
# caught by this comparison.
chk5() {
  local root="${1:-.}"
  local F="$root/$WATCH_REL"
  test -f "$F" || { err "$F" "missing -- required for the a11oy-contracting-tool-watch guard"; return 1; }

  grep -Fq 'git -C' "$F" || {
    err "$F" "REGRESSION -- no longer reads the committed source from the repo (git -C)."
    return 1
  }
  grep -Fq 'origin/main:' "$F" || {
    err "$F" "REGRESSION -- no longer compares against committed origin/main (origin/main:<file>)."
    return 1
  }
  echo "OK: compares the baked-image md5 against committed origin/main source"
}

# ── Check 6 ───────────────────────────────────────────────────────────────────
# Edge-triggering is intact: reads + writes the last_status state file, gates the
# ALERT page on the OK->ALERT edge and the RECOVERED page on the ALERT->OK edge,
# and makes EXACTLY TWO notify calls (one per edge).
chk6() {
  local root="${1:-.}"
  local F="$root/$WATCH_REL"
  test -f "$F" || { err "$F" "missing -- required for the a11oy-contracting-tool-watch guard"; return 1; }

  grep -Fq 'cat "$LAST_FILE"' "$F" || {
    err "$F" "REGRESSION -- no longer READS the last_status state file; it would page every cycle."
    return 1
  }
  grep -Fq '>"$LAST_FILE"' "$F" || {
    err "$F" "REGRESSION -- no longer WRITES the last_status state file; it can't de-dupe."
    return 1
  }
  grep -Fq '"$prev" != "ALERT"' "$F" || {
    err "$F" "REGRESSION -- the OK->ALERT edge guard ('\$prev' != 'ALERT') is gone; the alarm would re-page every cycle."
    return 1
  }
  grep -Fq '"$prev" = "ALERT"' "$F" || {
    err "$F" "REGRESSION -- the ALERT->OK (RECOVERED) edge guard ('\$prev' = 'ALERT') is gone."
    return 1
  }
  local n
  n="$(grep -Ec '^[[:space:]]+notify "' "$F")"
  if [ "$n" -ne 2 ]; then
    err "$F" "REGRESSION -- expected EXACTLY 2 notify calls (one OK->ALERT, one RECOVERED) but found $n."
    return 1
  fi
  echo "OK: edge-triggered -- reads+writes last_status, both edge guards present, exactly 2 notify calls"
}

# ── Check 7 ───────────────────────────────────────────────────────────────────
# Cluster/box-state no-op is intact: the integrity leg is gated on docker being
# present, an absent image SKIPS the integrity leg (no page), and an unreachable
# endpoint SKIPS the HTTP leg (no page). A mid-rebuild box must never page.
chk7() {
  local root="${1:-.}"
  local F="$root/$WATCH_REL"
  test -f "$F" || { err "$F" "missing -- required for the a11oy-contracting-tool-watch guard"; return 1; }

  grep -Fq 'command -v docker' "$F" || {
    err "$F" "REGRESSION -- the integrity leg is no longer gated on docker being present."
    return 1
  }
  grep -Fq 'skipping integrity leg' "$F" || {
    err "$F" "REGRESSION -- an absent image no longer SKIPS the integrity leg; a not-yet-built image would page falsely."
    return 1
  }
  grep -Fq 'skipping HTTP leg' "$F" || {
    err "$F" "REGRESSION -- an unreachable endpoint no longer SKIPS the HTTP leg; transient network would page falsely."
    return 1
  }
  echo "OK: docker-absent / image-absent / endpoint-unreachable all no-op (skip the leg, no page)"
}

# ── Check 8 ───────────────────────────────────────────────────────────────────
# Still wired into install.sh: the sbin script + the .service and .timer units
# are copied, and the timer is enabled. Otherwise a box rebuild ships without it.
chk8() {
  local root="${1:-.}"
  local F="$root/$INSTALL_REL"
  test -f "$F" || { err "$F" "missing -- required for the a11oy-contracting-tool-watch guard"; return 1; }

  grep -Eq 'install .*sbin/a11oy-contracting-tool-watch' "$F" || {
    err "$F" "REGRESSION -- install.sh no longer installs sbin/a11oy-contracting-tool-watch."
    return 1
  }
  grep -Fq 'a11oy-contracting-tool-watch.service' "$F" || {
    err "$F" "REGRESSION -- install.sh no longer installs a11oy-contracting-tool-watch.service."
    return 1
  }
  grep -Fq 'a11oy-contracting-tool-watch.timer' "$F" || {
    err "$F" "REGRESSION -- install.sh no longer installs a11oy-contracting-tool-watch.timer."
    return 1
  }
  grep -Eq 'systemctl enable --now a11oy-contracting-tool-watch\.timer' "$F" || {
    err "$F" "REGRESSION -- install.sh no longer ENABLES a11oy-contracting-tool-watch.timer; the proof wouldn't run after a rebuild."
    return 1
  }
  echo "OK: install.sh installs the script + units and enables the timer"
}

# ── Check 9 ───────────────────────────────────────────────────────────────────
# Still documented in README.md so an operator restoring the box knows the proof
# exists.
chk9() {
  local root="${1:-.}"
  local F="$root/$README_REL"
  test -f "$F" || { err "$F" "missing -- required for the a11oy-contracting-tool-watch guard"; return 1; }

  grep -Fq 'a11oy-contracting-tool-watch' "$F" || {
    err "$F" "REGRESSION -- README.md no longer documents a11oy-contracting-tool-watch."
    return 1
  }
  grep -Fiq 'contracting tool' "$F" || {
    err "$F" "REGRESSION -- README.md lost the 'contracting tool' drop-out proof section."
    return 1
  }
  echo "OK: README.md documents the a11oy-contracting-tool-watch proof"
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
    chk9) chk9 "$ROOT" ;;
    all)
      rc=0
      chk1 "$ROOT" || rc=1
      chk2 "$ROOT" || rc=1
      chk3 "$ROOT" || rc=1
      chk4 "$ROOT" || rc=1
      chk5 "$ROOT" || rc=1
      chk6 "$ROOT" || rc=1
      chk7 "$ROOT" || rc=1
      chk8 "$ROOT" || rc=1
      chk9 "$ROOT" || rc=1
      exit "$rc"
      ;;
    *) echo "unknown check: $CHECK (want chk1..chk9|all)" >&2; exit 2 ;;
  esac
fi
