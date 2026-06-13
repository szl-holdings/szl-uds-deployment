# Copyright 2026 SZL Holdings
# SPDX-License-Identifier: Apache-2.0
#
# box-scripts-drift-check-guard.sh — drive the REAL box-scripts-drift-check
# watcher end-to-end against a throwaway tree and assert BOTH its detection-only
# path and its opt-in SELF_HEAL=1 auto-repair path still behave correctly.
#
# WHY THIS EXISTS
# box-scripts/sbin/box-scripts-drift-check is the alarm that catches the box's
# host-level helper scripts/units (under /usr/local/sbin + /etc/systemd/system)
# drifting away from their committed copies in box-scripts/. It has two paths:
#   * DETECTION-ONLY (default): edge-triggered alert on the healthy->drift edge,
#     de-duped so a persisting drift never spams, RECOVERED when it clears.
#   * SELF_HEAL=1 (opt-in, Task #529): on the drift edge it re-installs each
#     drifted host file from its committed copy, runs daemon-reload if a unit
#     changed, pushes REPAIRED, and leaves an un-healable REPO-MISSING file
#     untouched.
# Both paths produce NO visible symptom when broken until a real drift goes
# unalerted or un-repaired. The only proof so far was a manual throwaway-tree
# recipe in box-scripts-drift-check.README.md. This guard lifts that recipe into
# CI: it RUNS the real script (no cluster, no root) and asserts the actual
# behaviour, so a future edit cannot silently neuter detection or self-heal.
#
# Usage: bash scripts/box-scripts-drift-check-guard.sh [path-to-drift-check]
#   Defaults to the committed box-scripts/sbin/box-scripts-drift-check. The
#   negative-fixture self-test (box-scripts-drift-check-guard.test.sh) points it
#   at deliberately-broken copies to prove these assertions actually bite.
# Exit 0 if every assertion holds, 1 otherwise.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
SCRIPT="${1:-$REPO_ROOT/box-scripts/sbin/box-scripts-drift-check}"

if [ ! -r "$SCRIPT" ]; then
  echo "FATAL drift-check script not found/readable: $SCRIPT" >&2
  exit 1
fi

PASS=0
FAIL=0
ok()   { echo "ok   $*"; PASS=$((PASS+1)); }
bad()  { echo "FAIL $*"; FAIL=$((FAIL+1)); }

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

# ---- throwaway tree (lifted from the README test recipe) --------------------
mkdir -p "$T/repo/.git" "$T/repo/box-scripts/sbin" "$T/repo/box-scripts/systemd" \
         "$T/sbin" "$T/units" "$T/state" "$T/log"

# Committed copies (the source of truth) + matching host copies.
printf 'echo committed v1\n'              > "$T/repo/box-scripts/sbin/demo-script"
printf '[Unit]\nDescription=demo v1\n'    > "$T/repo/box-scripts/systemd/demo.service"
cp "$T/repo/box-scripts/sbin/demo-script"     "$T/sbin/demo-script"
cp "$T/repo/box-scripts/systemd/demo.service" "$T/units/demo.service"

LOG="$T/log/x.log"
STATUS="$T/state/status.json"

# run [extra env...] — drive the real watcher with every path pointed at the
# throwaway tree. The log is truncated first so each run's pushes are isolated
# (NOTIFY_CMD=cat sends every push() into the log). DAEMON_RELOAD_CMD is stubbed
# so a unit re-install can be observed without systemd. WATCH_SBIN / WATCH_UNITS
# are overridable per phase via the environment of the caller.
run() {
  : > "$LOG"
  env \
    REPO="$T/repo" BOX_SCRIPTS="$T/repo/box-scripts" \
    SBIN_DIR="$T/sbin" UNIT_DIR="$T/units" \
    STATE_DIR="$T/state" LOG_DIR="$T/log" LOG="$LOG" STATUS="$STATUS" \
    SIG_FILE="$T/state/problem.sig" \
    HEAL_TS_FILE="$T/state/heal-last.ts" HEAL_RESULT_FILE="$T/state/heal-last.txt" \
    WATCH_SBIN="${WATCH_SBIN-demo-script}" WATCH_UNITS="${WATCH_UNITS-demo.service}" \
    ALERT_PREFIX="[TEST-ignore] " NOTIFY_CMD=cat \
    DAEMON_RELOAD_CMD="echo [daemon-reload-stub]" \
    "$@" \
    bash "$SCRIPT"
}

# Distinctive push markers — these strings appear ONLY as the argument to push()
# (which pipes into NOTIFY_CMD=cat -> the log), never as a bare log() line.
pushed()      { grep -q "box-scripts-drift $1" "$LOG"; }
status_is()   { grep -q "\"overall\": \"$1\"" "$STATUS"; }

echo "== Phase A: clean baseline (detection-only) =="
run
if status_is OK;            then ok "A1 baseline overall=OK"; else bad "A1 baseline not OK"; fi
if ! pushed DRIFT;          then ok "A2 baseline fires no DRIFT push"; else bad "A2 baseline pushed DRIFT"; fi

echo "== Phase B: a host file is hand-edited -> one DRIFT alert (host UNCHANGED) =="
printf 'echo HAND-EDITED\n' > "$T/sbin/demo-script"
run
if pushed DRIFT;            then ok "B1 drift edge fires a DRIFT push"; else bad "B1 no DRIFT push on the drift edge"; fi
if status_is DRIFT;         then ok "B2 status.json overall=DRIFT"; else bad "B2 status.json not DRIFT"; fi
if grep -q 'HAND-EDITED' "$T/sbin/demo-script"; then
  ok "B3 detection-only LEAVES the host file untouched"
else
  bad "B3 detection-only altered the host file (should not without SELF_HEAL)"
fi

echo "== Phase C: persisting drift -> de-duped, no repeat push =="
run
if ! pushed DRIFT;          then ok "C1 persisting drift does NOT re-push (de-dup)"; else bad "C1 persisting drift re-pushed (de-dup broken)"; fi

echo "== Phase D: host file restored by hand -> RECOVERED =="
cp "$T/repo/box-scripts/sbin/demo-script" "$T/sbin/demo-script"
run
if pushed RECOVERED;        then ok "D1 clearing the drift fires RECOVERED"; else bad "D1 no RECOVERED push when drift cleared"; fi
if status_is OK;            then ok "D2 status.json back to overall=OK"; else bad "D2 status.json not OK after recovery"; fi

echo "== Phase E: SELF_HEAL=1 one-cycle grace -> first edge ALERTS but does NOT restore =="
# With the default grace, a brand-new drift edge must only alert; the host file
# is left alone so a genuine local hot-fix can be back-ported before the
# committed copy clobbers it.
printf 'echo HAND-EDITED again\n'           > "$T/sbin/demo-script"
printf '[Unit]\nDescription=HAND-EDITED\n'  > "$T/units/demo.service"
run SELF_HEAL=1
if pushed DRIFT;            then ok "E1 self-heal still fires the DRIFT edge alert"; else bad "E1 self-heal swallowed the DRIFT edge alert"; fi
if ! pushed REPAIRED;       then ok "E2 grace does NOT repair on the first drift edge"; else bad "E2 self-heal repaired on the first edge despite grace"; fi
if grep -q 'HAND-EDITED again' "$T/sbin/demo-script"; then
  ok "E3 grace leaves the drifted host SCRIPT untouched on the first edge"
else
  bad "E3 grace restored the host script on the first edge (should defer one cycle)"
fi

echo "== Phase E2: SELF_HEAL=1 next cycle (drift persists) -> repairs script AND unit =="
run SELF_HEAL=1
if pushed REPAIRED;         then ok "E4 self-heal fires a REPAIRED push on the next cycle"; else bad "E4 self-heal did NOT push REPAIRED after the grace cycle"; fi
if cmp -s "$T/sbin/demo-script" "$T/repo/box-scripts/sbin/demo-script"; then
  ok "E5 self-heal restored the drifted SCRIPT from its committed copy"
else
  bad "E5 self-heal did NOT restore the drifted script"
fi
if cmp -s "$T/units/demo.service" "$T/repo/box-scripts/systemd/demo.service"; then
  ok "E6 self-heal restored the drifted UNIT from its committed copy"
else
  bad "E6 self-heal did NOT restore the drifted unit"
fi
if grep -q 'daemon-reload-stub' "$LOG"; then
  ok "E7 self-heal ran daemon-reload after re-installing a unit"
else
  bad "E7 self-heal did NOT run daemon-reload after a unit changed"
fi

echo "== Phase F: next cycle after self-heal -> RECOVERED =="
run SELF_HEAL=1
if pushed RECOVERED;        then ok "F1 self-heal cycle clears to RECOVERED"; else bad "F1 no RECOVERED after self-heal repaired the drift"; fi
if status_is OK;            then ok "F2 status.json OK after self-heal"; else bad "F2 status.json not OK after self-heal"; fi

echo "== Phase F2: HEAL_GRACE=0 heals on the FIRST edge (opt out of the grace) =="
printf 'echo HAND-EDITED thrice\n' > "$T/sbin/demo-script"
run SELF_HEAL=1 HEAL_GRACE=0
if pushed REPAIRED;         then ok "F2a HEAL_GRACE=0 repairs on the first edge"; else bad "F2a HEAL_GRACE=0 did NOT repair on the first edge"; fi
if cmp -s "$T/sbin/demo-script" "$T/repo/box-scripts/sbin/demo-script"; then
  ok "F2b HEAL_GRACE=0 restored the SCRIPT in a single run"
else
  bad "F2b HEAL_GRACE=0 did NOT restore the script in a single run"
fi
run SELF_HEAL=1            # clear back to a clean baseline for the next phase
if status_is OK;            then ok "F2c status.json OK after the HEAL_GRACE=0 heal"; else bad "F2c status.json not OK after HEAL_GRACE=0 heal"; fi

echo "== Phase G: SELF_HEAL=1 leaves an un-healable REPO-MISSING host file untouched =="
# A host file with NO committed copy cannot be restored — it must be left as-is.
printf 'echo orphan host edit\n' > "$T/sbin/orphan-script"
ORPHAN_BEFORE="$(cat "$T/sbin/orphan-script")"
WATCH_SBIN="orphan-script" WATCH_UNITS="" run SELF_HEAL=1
if status_is DRIFT;         then ok "G1 REPO-MISSING is reported as a drift"; else bad "G1 REPO-MISSING not flagged as drift"; fi
if [ -e "$T/sbin/orphan-script" ] && [ "$(cat "$T/sbin/orphan-script")" = "$ORPHAN_BEFORE" ]; then
  ok "G2 self-heal left the un-healable REPO-MISSING host file untouched"
else
  bad "G2 self-heal mutated/removed the un-healable REPO-MISSING host file"
fi
if grep -qi 'un-healable' "$LOG" || grep -q 'REPO-MISSING' "$STATUS"; then
  ok "G3 self-heal reports the un-healable file (no committed source)"
else
  bad "G3 self-heal did NOT report the un-healable file"
fi

echo ""
echo "==================================================================="
echo "box-scripts-drift-check guard: $PASS passed, $FAIL failed"
echo "==================================================================="
[ "$FAIL" -eq 0 ]
