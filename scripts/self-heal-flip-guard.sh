# Copyright 2026 SZL Holdings
# SPDX-License-Identifier: Apache-2.0
#
# self-heal-flip-guard.sh — drive the REAL box-scripts/install.sh "one-flip
# switch" drop-in reconcile block end-to-end against a throwaway dir and assert
# every SELF_HEAL value behaves correctly, idempotently and without side effects.
#
# WHY THIS EXISTS
# box-scripts/install.sh contains a one-flip opt-in that writes/removes a systemd
# drop-in (10-self-heal.conf) for the box-scripts-drift-check watcher:
#     SELF_HEAL=1 sudo box-scripts/install.sh   # enable  -> write the drop-in
#     SELF_HEAL=0 sudo box-scripts/install.sh   # disable -> remove the drop-in
#     sudo box-scripts/install.sh               # unset   -> leave it untouched
# The reconcile logic lives ONLY in install.sh and was only ever verified by a
# manual on-box smoke run. install.sh as a whole cannot run in CI (it needs root
# + systemd + a real box), so the reconcile block is wrapped in
# SELF_HEAL_RECONCILE_BEGIN/END sentinels and drives only off the SELF_HEAL /
# WATCH_SBIN / WATCH_UNITS / SELFHEAL_DROPIN_DIR environment. This guard slices
# that block out of install.sh and runs it (no root, no systemd) against a
# throwaway SELFHEAL_DROPIN_DIR, asserting the actual on-disk result for every
# value, so a future edit cannot silently neuter or de-idempotent the switch.
#
# Behaviour asserted (matches box-scripts/install.sh + the watcher unit comment):
#   * 1 | true | yes | on  -> drop-in PRESENT, contains Environment=SELF_HEAL=1
#   * 0 | false | no | off -> drop-in ABSENT
#   * unset                -> state left UNTOUCHED (present stays, absent stays)
#   * any other value      -> WARN, state left UNCHANGED
#   * re-running the same value is IDEMPOTENT (byte-identical result, no churn)
#   * WATCH_SBIN / WATCH_UNITS, when set on enable, are written into the drop-in
#
# Usage: bash scripts/self-heal-flip-guard.sh [path-to-install.sh]
#   Defaults to the committed box-scripts/install.sh. The negative-fixture
#   self-test (self-heal-flip-guard.test.sh) points it at deliberately-broken
#   copies to prove these assertions actually bite.
# Exit 0 if every assertion holds, 1 otherwise.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
INSTALL_SH="${1:-$REPO_ROOT/box-scripts/install.sh}"

if [ ! -r "$INSTALL_SH" ]; then
  echo "FATAL install.sh not found/readable: $INSTALL_SH" >&2
  exit 1
fi

PASS=0
FAIL=0
ok()  { echo "ok   $*"; PASS=$((PASS+1)); }
bad() { echo "FAIL $*"; FAIL=$((FAIL+1)); }

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

# ---- slice the reconcile block out of install.sh ---------------------------
# Everything between the SELF_HEAL_RECONCILE_BEGIN/END sentinels is, by contract,
# self-contained and driven only off the environment. If the block is removed
# (e.g. a botched refactor) the slice is empty, the enable phase never writes a
# drop-in, and the very first assertion fails — which is exactly what the
# negative-fixture self-test checks.
SNIPPET="$T/reconcile.sh"
awk '/SELF_HEAL_RECONCILE_BEGIN/{f=1} f{print} /SELF_HEAL_RECONCILE_END/{f=0}' \
  "$INSTALL_SH" > "$SNIPPET"

if ! bash -n "$SNIPPET" 2>/dev/null; then
  echo "FATAL sliced reconcile block is not valid bash (mutation typo?)" >&2
  # Do not exit 0 — an unparseable / empty slice must be a guard FAILURE.
  exit 1
fi

DROPDIR="$T/box-scripts-drift-check.service.d"
DROPIN="$DROPDIR/10-self-heal.conf"
LOG="$T/run.log"

# flip MODE [extra env...] — run the sliced block once with SELFHEAL_DROPIN_DIR
# pointed at the throwaway dir. MODE="UNSET" runs with SELF_HEAL unset; any other
# MODE sets SELF_HEAL to that literal value. Output (incl. WARN on stderr) lands
# in $LOG.
flip() {
  local mode="$1"; shift
  : > "$LOG"
  if [ "$mode" = "UNSET" ]; then
    env -u SELF_HEAL -u WATCH_SBIN -u WATCH_UNITS \
      SELFHEAL_DROPIN_DIR="$DROPDIR" "$@" bash "$SNIPPET" >"$LOG" 2>&1
  else
    env -u WATCH_SBIN -u WATCH_UNITS SELF_HEAL="$mode" \
      SELFHEAL_DROPIN_DIR="$DROPDIR" "$@" bash "$SNIPPET" >"$LOG" 2>&1
  fi
}

present() { [ -f "$DROPIN" ]; }
absent()  { [ ! -e "$DROPIN" ]; }
clean()   { rm -rf "$DROPDIR"; }

echo "== Phase A: every ENABLE alias writes the drop-in with SELF_HEAL=1 =="
for v in 1 true yes on; do
  clean
  flip "$v"
  if present; then ok "A:$v writes the drop-in"; else bad "A:$v did NOT write the drop-in"; fi
  if grep -q '^Environment=SELF_HEAL=1$' "$DROPIN" 2>/dev/null; then
    ok "A:$v drop-in carries Environment=SELF_HEAL=1"
  else
    bad "A:$v drop-in missing Environment=SELF_HEAL=1"
  fi
done

echo "== Phase B: every DISABLE alias removes the drop-in =="
for v in 0 false no off; do
  clean
  flip 1                       # enable first so there is something to remove
  present || bad "B:$v setup failed (enable did not create drop-in)"
  flip "$v"
  if absent; then ok "B:$v removes the drop-in"; else bad "B:$v did NOT remove the drop-in"; fi
done

echo "== Phase B2: DISABLE from a clean state is a quiet no-op =="
clean
flip 0
if absent; then ok "B2 disable-from-clean leaves no drop-in"; else bad "B2 disable-from-clean created a drop-in"; fi
if grep -q 'already OFF' "$LOG"; then ok "B2 reports 'already OFF'"; else bad "B2 did not report 'already OFF'"; fi

echo "== Phase C: UNSET leaves the current state UNTOUCHED =="
clean
flip 1                         # enabled state
before="$(cat "$DROPIN")"
flip UNSET
if present && [ "$(cat "$DROPIN")" = "$before" ]; then
  ok "C1 unset leaves an ENABLED drop-in present + byte-identical"
else
  bad "C1 unset mutated/removed an enabled drop-in"
fi
if grep -q 'left untouched' "$LOG"; then ok "C1 reports the enabled drop-in left untouched"; else bad "C1 missing 'left untouched' notice"; fi
clean
flip UNSET                     # from absent
if absent; then ok "C2 unset leaves an absent drop-in absent"; else bad "C2 unset created a drop-in from nothing"; fi

echo "== Phase D: an UNRECOGNISED value warns and changes nothing =="
clean
flip 1
before="$(cat "$DROPIN")"
flip maybe
if present && [ "$(cat "$DROPIN")" = "$before" ]; then
  ok "D1 unrecognised value leaves an enabled drop-in unchanged"
else
  bad "D1 unrecognised value mutated/removed the enabled drop-in"
fi
if grep -qi 'ignoring unrecognized' "$LOG"; then ok "D1 emits the WARN line"; else bad "D1 did not WARN on the unrecognised value"; fi
clean
flip maybe                     # from absent
if absent; then ok "D2 unrecognised value does not create a drop-in"; else bad "D2 unrecognised value created a drop-in"; fi

echo "== Phase E: re-running the same value is IDEMPOTENT =="
clean
flip 1
e1="$(cat "$DROPIN")"
flip 1
e2="$(cat "$DROPIN")"
if [ "$e1" = "$e2" ]; then ok "E1 enabling twice is byte-identical"; else bad "E1 second enable changed the drop-in (not idempotent)"; fi
if grep -q 'already ENABLED' "$LOG"; then ok "E1 second enable reports 'already ENABLED (drop-in unchanged)'"; else bad "E1 second enable did not report it was unchanged"; fi
flip 0
flip 0
if absent; then ok "E2 disabling twice stays absent"; else bad "E2 second disable resurrected the drop-in"; fi
if grep -q 'already OFF' "$LOG"; then ok "E2 second disable reports 'already OFF'"; else bad "E2 second disable did not report 'already OFF'"; fi

echo "== Phase F: WATCH_SBIN / WATCH_UNITS are written into the drop-in =="
clean
flip 1 WATCH_SBIN="dns-drift-check" WATCH_UNITS="dns-drift-check.service"
if grep -q '^Environment=WATCH_SBIN=dns-drift-check$' "$DROPIN" 2>/dev/null; then
  ok "F1 WATCH_SBIN scoped into the drop-in"
else
  bad "F1 WATCH_SBIN not written into the drop-in"
fi
if grep -q '^Environment=WATCH_UNITS=dns-drift-check.service$' "$DROPIN" 2>/dev/null; then
  ok "F2 WATCH_UNITS scoped into the drop-in"
else
  bad "F2 WATCH_UNITS not written into the drop-in"
fi

echo ""
echo "==================================================================="
echo "self-heal one-flip guard: $PASS passed, $FAIL failed"
echo "==================================================================="
[ "$FAIL" -eq 0 ]
