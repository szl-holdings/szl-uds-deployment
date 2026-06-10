# Copyright 2026 SZL Holdings
# SPDX-License-Identifier: Apache-2.0
#
# szl-signing-health-check-guard-checks.sh — guard the `szl-signing-health-check`
# box guard (the receipt-signing-down alarm) from silently regressing.
#
# WHY THIS EXISTS
# `szl-signing-health-check` (box-scripts/sbin/szl-signing-health-check) runs
# every ~2 min and pages a human when szl-receipts SIGNING is down on the
# uds-szl-demo cluster — Vault is SEALED (auto-unseal didn't recover), or the
# receipts-server is crashlooping / Pending / booted unsigned (/pubkey reports
# signed!=true). The self-heal helpers only log into the journal; this watcher is
# the only thing that actively pages. Its value rests on a few fragile invariants
# that produce NO visible symptom when broken until a real signing outage goes
# unalerted:
#   * it still checks VAULT seal status (vault status -format=json -> .sealed);
#   * it still checks receipts SIGNING (GET /pubkey reports signed=true);
#   * it still enforces the GRACE WINDOW (a problem must persist >= THRESHOLD_SECS
#     before paging) so a normal ~1-min auto-unseal cycle never alerts;
#   * it is EDGE-triggered via a signature file so it pages exactly once per
#     distinct outage and once on RECOVERED, never every cycle;
#   * it NO-OPs (exit 0, no page) when the cluster is absent/unreachable;
#   * it stays WIRED into install.sh (copied + timer enabled) and documented in
#     its README, or a box rebuild silently ships without the alarm.
# This guard is a pure text/lint check (no cluster) that asserts each invariant.
#
# The check logic is extracted here (out of the workflow) so it can be UNIT
# TESTED: szl-signing-health-check-guard-checks.test.sh feeds each check a
# deliberately-BROKEN fixture and asserts the check FAILS (plus that the pristine
# repo PASSES). A future edit that neuters a check is caught by that self-test.
#
# Usage:
#   szl-signing-health-check-guard-checks.sh <check> [root]
#     check : chk1 .. chk8 | all
#     root  : repo root to check (default: current directory)

set -uo pipefail

err() { echo "::error file=$1::$2"; }

WATCH_REL="box-scripts/sbin/szl-signing-health-check"
INSTALL_REL="box-scripts/install.sh"
README_REL="box-scripts/szl-signing-health-check.README.md"

# ── Check 1 ── exists and parses clean ────────────────────────────────────────
chk1() {
  local root="${1:-.}"
  local F="$root/$WATCH_REL"
  test -f "$F" || {
    err "$F" "REGRESSION — szl-signing-health-check is MISSING. The receipt-signing-down alarm is gone."
    return 1
  }
  local out
  if ! out="$(bash -n "$F" 2>&1)"; then
    err "$F" "REGRESSION — szl-signing-health-check does not parse (bash -n failed)."
    echo "$out" | sed 's/^/       | /'
    return 1
  fi
  echo "OK: $F exists and parses clean (bash -n)"
}

# ── Check 2 ── still checks Vault seal status ─────────────────────────────────
chk2() {
  local root="${1:-.}"
  local F="$root/$WATCH_REL"
  test -f "$F" || { err "$F" "missing — required for the szl-signing-health-check guard"; return 1; }

  grep -Fq 'vault status -format=json' "$F" || {
    err "$F" "REGRESSION — no longer queries Vault seal status (vault status -format=json)."
    err "$F" "A SEALED Vault (signing dead) could go unalerted."
    return 1
  }
  grep -Fq '"$sealed" = "True"' "$F" || {
    err "$F" "REGRESSION — no longer pages on a SEALED Vault ('\$sealed' = 'True' branch gone)."
    return 1
  }
  echo "OK: checks Vault seal status and pages when SEALED"
}

# ── Check 3 ── still checks receipts signing via /pubkey ──────────────────────
chk3() {
  local root="${1:-.}"
  local F="$root/$WATCH_REL"
  test -f "$F" || { err "$F" "missing — required for the szl-signing-health-check guard"; return 1; }

  grep -Fq '/pubkey' "$F" || {
    err "$F" "REGRESSION — no longer probes the receipts-server /pubkey endpoint."
    err "$F" "A server that booted UNSIGNED would go unalerted."
    return 1
  }
  grep -Fq '"$signed" = "True"' "$F" || {
    err "$F" "REGRESSION — no longer verifies /pubkey reports signed=True; unsigned receipts could go unalerted."
    return 1
  }
  echo "OK: probes /pubkey and verifies signed=True"
}

# ── Check 4 ── still enforces the grace window before paging ──────────────────
chk4() {
  local root="${1:-.}"
  local F="$root/$WATCH_REL"
  test -f "$F" || { err "$F" "missing — required for the szl-signing-health-check guard"; return 1; }

  grep -Fq 'THRESHOLD_SECS' "$F" || {
    err "$F" "REGRESSION — the grace-window threshold (THRESHOLD_SECS) is gone."
    err "$F" "Every transient ~1-min Vault auto-unseal cycle would now page."
    return 1
  }
  grep -Fq '"$elapsed" -lt "$THRESHOLD_SECS"' "$F" || {
    err "$F" "REGRESSION — the grace-window comparison ('\$elapsed' -lt '\$THRESHOLD_SECS') is gone; brief blips would page."
    return 1
  }
  echo "OK: enforces the grace window (problem must persist >= THRESHOLD_SECS)"
}

# ── Check 5 ── edge-triggered via the signature file (exactly two pushes) ─────
chk5() {
  local root="${1:-.}"
  local F="$root/$WATCH_REL"
  test -f "$F" || { err "$F" "missing — required for the szl-signing-health-check guard"; return 1; }

  grep -Fq 'cat "$SIG_FILE"' "$F" || {
    err "$F" "REGRESSION — no longer READS the problem signature file; can't de-dupe a persisting outage."
    return 1
  }
  grep -Fq '>"$SIG_FILE"' "$F" || {
    err "$F" "REGRESSION — no longer WRITES the problem signature file; can't de-dupe a persisting outage."
    return 1
  }
  grep -Fq 'rm -f "$SIG_FILE"' "$F" || {
    err "$F" "REGRESSION — no longer CLEARS the signature on recovery; a fresh outage wouldn't re-alert."
    return 1
  }
  grep -Fq '"$cur_sig" = "$prev_sig"' "$F" || {
    err "$F" "REGRESSION — the persisting-outage de-dup comparison is gone; the alarm would re-page every cycle."
    return 1
  }
  grep -Fq '[ -n "$prev_sig" ]' "$F" || {
    err "$F" "REGRESSION — the RECOVERED edge guard ('\$prev_sig' non-empty) is gone; recovery would page spuriously."
    return 1
  }
  local n
  n="$(grep -Ec '^[[:space:]]+push "' "$F")"
  if [ "$n" -ne 2 ]; then
    err "$F" "REGRESSION — expected EXACTLY 2 push calls (one ALERT, one RECOVERED) but found $n."
    return 1
  fi
  echo "OK: edge-triggered via signature file (reads/writes/clears, de-dup + RECOVERED guard, exactly 2 pushes)"
}

# ── Check 6 ── cluster-absent / unreachable no-op ─────────────────────────────
chk6() {
  local root="${1:-.}"
  local F="$root/$WATCH_REL"
  test -f "$F" || { err "$F" "missing — required for the szl-signing-health-check guard"; return 1; }

  grep -A1 -E 'k3d kubeconfig write' "$F" | grep -Fq 'exit 0' || {
    err "$F" "REGRESSION — cluster-absent path no longer no-ops (k3d kubeconfig write resolve lost its 'exit 0' fallback)."
    return 1
  }
  grep -F 'unreachable (api down)' "$F" | grep -Fq 'exit 0' || {
    err "$F" "REGRESSION — cluster-unreachable path no longer no-ops (api-down branch lost its 'exit 0')."
    err "$F" "A stopped/absent cluster would now error or page instead of being a silent no-op."
    return 1
  }
  echo "OK: cluster-absent / unreachable paths both no-op (exit 0)"
}

# ── Check 7 ── wired into install.sh ──────────────────────────────────────────
chk7() {
  local root="${1:-.}"
  local F="$root/$INSTALL_REL"
  test -f "$F" || { err "$F" "missing — required for the szl-signing-health-check guard"; return 1; }

  grep -Eq 'install .*sbin/szl-signing-health-check' "$F" || {
    err "$F" "REGRESSION — install.sh no longer installs sbin/szl-signing-health-check."
    return 1
  }
  grep -Fq 'szl-signing-health-check.service' "$F" || {
    err "$F" "REGRESSION — install.sh no longer installs szl-signing-health-check.service."
    return 1
  }
  grep -Fq 'szl-signing-health-check.timer' "$F" || {
    err "$F" "REGRESSION — install.sh no longer installs szl-signing-health-check.timer."
    return 1
  }
  grep -Eq 'systemctl enable --now szl-signing-health-check\.timer' "$F" || {
    err "$F" "REGRESSION — install.sh no longer ENABLES szl-signing-health-check.timer; the alarm wouldn't run after a rebuild."
    return 1
  }
  echo "OK: install.sh installs the script + units and enables the timer"
}

# ── Check 8 ── documented in its README ───────────────────────────────────────
chk8() {
  local root="${1:-.}"
  local F="$root/$README_REL"
  test -f "$F" || { err "$F" "missing — required for the szl-signing-health-check guard"; return 1; }

  grep -Fq 'szl-signing-health-check' "$F" || {
    err "$F" "REGRESSION — the README no longer documents szl-signing-health-check."
    return 1
  }
  grep -Fiq 'receipt signing' "$F" || {
    err "$F" "REGRESSION — the README lost the 'receipt signing' description of this alarm."
    return 1
  }
  echo "OK: README documents the receipt-signing-down alarm"
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
