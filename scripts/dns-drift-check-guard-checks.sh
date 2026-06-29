# Copyright 2026 SZL Holdings
# SPDX-License-Identifier: Apache-2.0
#
# dns-drift-check-guard-checks.sh — guard the `dns-drift-check` box guard (the
# a-11-oy.com public-DNS drift alarm) from silently regressing.
#
# WHY THIS EXISTS
# `dns-drift-check` (box-scripts/sbin/dns-drift-check) runs every ~15 min and
# pages the team if a-11-oy.com's public DNS drifts off the box — a missing/wrong A
# record on the apex/www/killinchu/elite hosts, a lost SPF "-all", or a lost
# DMARC "p=reject". EasyWP silently grabbed the apex once; this alarm catches that
# class of takeover before users notice. Its value rests on a few fragile
# invariants that produce NO visible symptom when broken until a real drift goes
# unalerted:
#   * it still queries a PUBLIC resolver (dig @8.8.8.8) — never the box's own
#     resolver, which would mask external drift;
#   * it still checks the A records, the SPF "-all", and the DMARC "p=reject";
#   * it is EDGE-triggered via a signature file so it pages exactly once per
#     distinct drift and once on RECOVERED, never every cycle;
#   * it always writes a fresh status file + heartbeat STATE log (so the
#     monitor-liveness meta-monitor can watch it) and the notifier is FAIL-SOFT;
#   * it stays WIRED into install.sh (copied + timer enabled) and documented in
#     README.md, or a box rebuild silently ships without the alarm.
# This guard is a pure text/lint check (no DNS) that asserts each invariant.
#
# The check logic is extracted here (out of the workflow) so it can be UNIT
# TESTED: dns-drift-check-guard-checks.test.sh feeds each check a
# deliberately-BROKEN fixture and asserts the check FAILS (plus that the pristine
# repo PASSES). A future edit that neuters a check is caught by that self-test.
#
# Usage:
#   dns-drift-check-guard-checks.sh <check> [root]
#     check : chk1 .. chk7 | all
#     root  : repo root to check (default: current directory)

set -uo pipefail

err() { echo "::error file=$1::$2"; }

WATCH_REL="box-scripts/sbin/dns-drift-check"
INSTALL_REL="box-scripts/install.sh"
README_REL="box-scripts/README.md"

# ── Check 1 ── exists and parses clean ────────────────────────────────────────
chk1() {
  local root="${1:-.}"
  local F="$root/$WATCH_REL"
  test -f "$F" || {
    err "$F" "REGRESSION — dns-drift-check is MISSING. The a-11-oy.com DNS-drift alarm is gone."
    return 1
  }
  local out
  if ! out="$(bash -n "$F" 2>&1)"; then
    err "$F" "REGRESSION — dns-drift-check does not parse (bash -n failed)."
    echo "$out" | sed 's/^/       | /'
    return 1
  fi
  echo "OK: $F exists and parses clean (bash -n)"
}

# ── Check 2 ── still queries a PUBLIC resolver ────────────────────────────────
chk2() {
  local root="${1:-.}"
  local F="$root/$WATCH_REL"
  test -f "$F" || { err "$F" "missing — required for the dns-drift-check guard"; return 1; }

  grep -Fq 'dig_one' "$F" || {
    err "$F" "REGRESSION — the dig_one resolver helper is gone; DNS is no longer being queried."
    return 1
  }
  grep -Fq '@"$RESOLVER"' "$F" || {
    err "$F" "REGRESSION — no longer queries an EXPLICIT public resolver (@\$RESOLVER)."
    err "$F" "Falling back to the box's own resolver would MASK external DNS drift."
    return 1
  }
  grep -Eq 'RESOLVER:-8\.8\.8\.8' "$F" || {
    err "$F" "REGRESSION — the public resolver default (8.8.8.8) is gone."
    return 1
  }
  echo "OK: queries an explicit PUBLIC resolver (dig @\$RESOLVER, default 8.8.8.8)"
}

# ── Check 3 ── still checks A records + SPF -all + DMARC p=reject ─────────────
chk3() {
  local root="${1:-.}"
  local F="$root/$WATCH_REL"
  test -f "$F" || { err "$F" "missing — required for the dns-drift-check guard"; return 1; }

  grep -Fq 'grep -qx "$EXPECT_IP"' "$F" || {
    err "$F" "REGRESSION — no longer verifies the hosts A-resolve to \$EXPECT_IP (the box)."
    return 1
  }
  grep -Fq 'EXPECT_SPF_ALL' "$F" || {
    err "$F" "REGRESSION — no longer checks the SPF '-all' hard-fail; a lost SPF could go unalerted."
    return 1
  }
  grep -Fq 'EXPECT_DMARC' "$F" || {
    err "$F" "REGRESSION — no longer checks the DMARC 'p=reject'; a lost DMARC could go unalerted."
    return 1
  }
  echo "OK: checks A records + SPF -all + DMARC p=reject"
}

# ── Check 4 ── edge-triggered via the signature file (exactly two pushes) ─────
chk4() {
  local root="${1:-.}"
  local F="$root/$WATCH_REL"
  test -f "$F" || { err "$F" "missing — required for the dns-drift-check guard"; return 1; }

  grep -Fq 'cat "$SIG_FILE"' "$F" || {
    err "$F" "REGRESSION — no longer READS the problem signature file; can't de-dupe a persisting drift."
    return 1
  }
  grep -Fq '>"$SIG_FILE"' "$F" || {
    err "$F" "REGRESSION — no longer WRITES the problem signature file; can't de-dupe a persisting drift."
    return 1
  }
  grep -Fq 'rm -f "$SIG_FILE"' "$F" || {
    err "$F" "REGRESSION — no longer CLEARS the signature on recovery; a fresh drift wouldn't re-alert."
    return 1
  }
  grep -Fq '"$cur_sig" = "$prev_sig"' "$F" || {
    err "$F" "REGRESSION — the persisting-drift de-dup comparison is gone; the alarm would re-page every cycle."
    return 1
  }
  grep -Fq '[ -n "$prev_sig" ]' "$F" || {
    err "$F" "REGRESSION — the RECOVERED edge guard ('\$prev_sig' non-empty) is gone."
    return 1
  }
  local n
  n="$(grep -Ec '^[[:space:]]+push "' "$F")"
  if [ "$n" -ne 2 ]; then
    err "$F" "REGRESSION — expected EXACTLY 2 push calls (one DRIFT, one RECOVERED) but found $n."
    return 1
  fi
  echo "OK: edge-triggered via signature file (reads/writes/clears, de-dup + RECOVERED guard, exactly 2 pushes)"
}

# ── Check 5 ── always writes status + heartbeat; notifier fail-soft ───────────
chk5() {
  local root="${1:-.}"
  local F="$root/$WATCH_REL"
  test -f "$F" || { err "$F" "missing — required for the dns-drift-check guard"; return 1; }

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
  test -f "$F" || { err "$F" "missing — required for the dns-drift-check guard"; return 1; }

  grep -Eq 'install .*sbin/dns-drift-check' "$F" || {
    err "$F" "REGRESSION — install.sh no longer installs sbin/dns-drift-check."
    return 1
  }
  grep -Fq 'dns-drift-check.service' "$F" || {
    err "$F" "REGRESSION — install.sh no longer installs dns-drift-check.service."
    return 1
  }
  grep -Fq 'dns-drift-check.timer' "$F" || {
    err "$F" "REGRESSION — install.sh no longer installs dns-drift-check.timer."
    return 1
  }
  grep -Eq 'systemctl enable --now dns-drift-check\.timer' "$F" || {
    err "$F" "REGRESSION — install.sh no longer ENABLES dns-drift-check.timer; the alarm wouldn't run after a rebuild."
    return 1
  }
  echo "OK: install.sh installs the script + units and enables the timer"
}

# ── Check 7 ── documented in README.md ────────────────────────────────────────
chk7() {
  local root="${1:-.}"
  local F="$root/$README_REL"
  test -f "$F" || { err "$F" "missing — required for the dns-drift-check guard"; return 1; }

  grep -Fq 'dns-drift-check' "$F" || {
    err "$F" "REGRESSION — README.md no longer documents dns-drift-check."
    return 1
  }
  grep -Fiq 'public resolver' "$F" || {
    err "$F" "REGRESSION — README.md lost the 'public resolver' description of this alarm."
    return 1
  }
  echo "OK: README.md documents the a-11-oy.com DNS-drift alarm"
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
