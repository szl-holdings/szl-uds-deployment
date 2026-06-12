# Copyright 2026 SZL Holdings
# SPDX-License-Identifier: Apache-2.0
#
# szl-receipt-checkpoint-guard-checks.sh — guard the `szl-receipt-checkpoint` box
# job (the tamper-proof receipt-log checkpoint + regression re-verify) from
# silently regressing.
#
# WHY THIS EXISTS
# szl-receipt-checkpoint (box-scripts/sbin/szl-receipt-checkpoint) runs daily and
# copies the live receipt-log chain HEAD (chain_index + head hash) OFF the pod,
# onto a dedicated git branch the receipts-server pod cannot rewrite, then
# re-verifies the LIVE chain against that durable anchor and pages if the live
# chain ever falls BELOW the last checkpoint (truncation/rollback) or a
# checkpointed receipt's hash changed (tamper). Its value rests on fragile
# invariants that produce NO visible symptom when broken until a real rollback
# goes unalerted:
#   * it must SELF-VERIFY the live chain (verify_receipts.sh) before checkpointing
#     — never anchor a chain that doesn't verify;
#   * it must REGRESSION-CHECK the live chain against the durable anchor
#     (verify_receipts.sh with SZL_ANCHOR_FILE);
#   * it must be EDGE-triggered (read+write a last_status state file, both edge
#     guards, EXACTLY TWO notify calls) so it pages once per edge, never a storm;
#   * it must NO-OP (exit 0, no page) when the cluster is absent/unreachable or
#     the receipts module is not deployed;
#   * it must write a DISTINCT checkpoint filename on a DEDICATED branch and only
#     ADVANCE the anchor MONOTONICALLY (never lower it, never collide with the
#     in-repo receipt-baseline workstream);
#   * it must stay WIRED into install.sh (script + units copied, timer enabled,
#     env seeded) and documented in README.md (cadence + storage);
#   * verify_receipts.sh must still honor SZL_ANCHOR_FILE (the anchor primitive
#     the whole job depends on).
# This guard is a pure text/lint check (no cluster) that asserts each invariant.
#
# The check logic is extracted here so it can be UNIT TESTED:
# szl-receipt-checkpoint-guard-checks.test.sh feeds each check a deliberately
# BROKEN fixture and asserts the check FAILS (plus that the pristine repo PASSES).
#
# Usage:
#   szl-receipt-checkpoint-guard-checks.sh <check> [root]
#     check : chk1 .. chk9 | all
#     root  : repo root to check (default: current directory)

set -uo pipefail

err() { echo "::error file=$1::$2"; }

SBIN_REL="box-scripts/sbin/szl-receipt-checkpoint"
SERVICE_REL="box-scripts/systemd/szl-receipt-checkpoint.service"
TIMER_REL="box-scripts/systemd/szl-receipt-checkpoint.timer"
INSTALL_REL="box-scripts/install.sh"
README_REL="box-scripts/README.md"
VERIFY_REL="scripts/verify_receipts.sh"

# ── Check 1 ───────────────────────────────────────────────────────────────────
chk1() {
  local root="${1:-.}" F
  F="$root/$SBIN_REL"
  test -f "$F" || { err "$F" "REGRESSION — szl-receipt-checkpoint is MISSING. The tamper-proof checkpoint job is gone."; return 1; }
  local out
  if ! out="$(bash -n "$F" 2>&1)"; then
    err "$F" "REGRESSION — szl-receipt-checkpoint does not parse (bash -n failed)."
    echo "$out" | sed 's/^/       | /'
    return 1
  fi
  echo "OK: $F exists and parses clean (bash -n)"
}

# ── Check 2 ───────────────────────────────────────────────────────────────────
# Self-verifies the LIVE chain via verify_receipts.sh before checkpointing.
chk2() {
  local root="${1:-.}" F
  F="$root/$SBIN_REL"
  test -f "$F" || { err "$F" "missing — required for the szl-receipt-checkpoint guard"; return 1; }
  grep -Fq 'bash "$VERIFY_SH"' "$F" || {
    err "$F" "REGRESSION — szl-receipt-checkpoint no longer runs verify_receipts.sh on the live chain."
    return 1
  }
  grep -Fq 'refusing to checkpoint' "$F" || {
    err "$F" "REGRESSION — szl-receipt-checkpoint no longer REFUSES to checkpoint a chain that fails to verify."
    err "$F" "A failing/forged live chain could be anchored as a clean checkpoint."
    return 1
  }
  echo "OK: self-verifies the live chain before checkpointing"
}

# ── Check 3 ───────────────────────────────────────────────────────────────────
# Regression-checks the live chain against the durable anchor (SZL_ANCHOR_FILE).
chk3() {
  local root="${1:-.}" F
  F="$root/$SBIN_REL"
  test -f "$F" || { err "$F" "missing — required for the szl-receipt-checkpoint guard"; return 1; }
  grep -Fq 'SZL_ANCHOR_FILE="$ANCHOR_TMP"' "$F" || {
    err "$F" "REGRESSION — szl-receipt-checkpoint no longer re-verifies the live chain against the durable anchor."
    return 1
  }
  grep -Fq 'regressed below durable checkpoint' "$F" || {
    err "$F" "REGRESSION — szl-receipt-checkpoint lost the truncation/rollback alert reason."
    err "$F" "A live chain that fell below the last checkpoint would go unalerted."
    return 1
  }
  echo "OK: regression-checks the live chain against the durable anchor"
}

# ── Check 4 ───────────────────────────────────────────────────────────────────
# Edge-triggered: reads+writes last_status, both edge guards, exactly 2 notifies.
chk4() {
  local root="${1:-.}" F
  F="$root/$SBIN_REL"
  test -f "$F" || { err "$F" "missing — required for the szl-receipt-checkpoint guard"; return 1; }
  grep -Fq 'cat "$LAST_FILE"' "$F" || {
    err "$F" "REGRESSION — no longer READS the last_status state file; can't edge-trigger (would page every cycle)."
    return 1
  }
  grep -Fq '>"$LAST_FILE"' "$F" || {
    err "$F" "REGRESSION — no longer WRITES the last_status state file; can't de-dupe (would page every cycle)."
    return 1
  }
  grep -Fq '"$prev" != "ALERT"' "$F" || {
    err "$F" "REGRESSION — the OK->ALERT edge guard is gone; the alarm would re-page every cycle."
    return 1
  }
  grep -Fq '"$prev" = "ALERT"' "$F" || {
    err "$F" "REGRESSION — the ALERT->OK (RECOVERED) edge guard is gone; recovery would page every cycle or never."
    return 1
  }
  local n
  n="$(grep -Ec '^[[:space:]]+notify "' "$F")"
  if [ "$n" -ne 2 ]; then
    err "$F" "REGRESSION — expected EXACTLY 2 notify calls (OK->ALERT + RECOVERED) but found $n."
    return 1
  fi
  echo "OK: edge-triggered — reads+writes last_status, both edge guards, exactly 2 notify calls"
}

# ── Check 5 ───────────────────────────────────────────────────────────────────
# Cluster-absent / unreachable / receipts-module-absent all no-op (exit 0).
chk5() {
  local root="${1:-.}" F
  F="$root/$SBIN_REL"
  test -f "$F" || { err "$F" "missing — required for the szl-receipt-checkpoint guard"; return 1; }
  grep -E 'k3d kubeconfig write' "$F" | grep -Fq 'exit 0' || {
    err "$F" "REGRESSION — cluster-absent path no longer no-ops (k3d kubeconfig write resolve lost its 'exit 0')."
    return 1
  }
  grep -E 'readyz' "$F" | grep -Fq 'exit 0' || {
    err "$F" "REGRESSION — cluster-unreachable path no longer no-ops (readyz probe lost its 'exit 0')."
    return 1
  }
  grep -E 'get deploy "\$DEPLOY"' "$F" | grep -Fq 'exit 0' || {
    err "$F" "REGRESSION — receipts-module-absent path no longer no-ops (deploy presence check lost its 'exit 0')."
    return 1
  }
  echo "OK: cluster-absent / unreachable / receipts-module-absent paths all no-op (exit 0)"
}

# ── Check 6 ───────────────────────────────────────────────────────────────────
# Distinct checkpoint filename + dedicated branch + MONOTONIC advance.
chk6() {
  local root="${1:-.}" F
  F="$root/$SBIN_REL"
  test -f "$F" || { err "$F" "missing — required for the szl-receipt-checkpoint guard"; return 1; }
  grep -Fq 'receipts/checkpoint.json' "$F" || {
    err "$F" "REGRESSION — the DISTINCT checkpoint filename (receipts/checkpoint.json) is gone."
    err "$F" "The checkpoint must be separate from the in-repo receipt-baseline workstream."
    return 1
  }
  grep -Fq 'receipts-checkpoint' "$F" || {
    err "$F" "REGRESSION — the DEDICATED, pod-unwritable branch (receipts-checkpoint) is gone."
    return 1
  }
  grep -Fq -- '-gt "$ANCHOR_IDX"' "$F" || {
    err "$F" "REGRESSION — the MONOTONIC advance guard ('-gt \$ANCHOR_IDX') is gone; the anchor could be lowered."
    return 1
  }
  echo "OK: distinct checkpoint.json on a dedicated branch, advanced monotonically"
}

# ── Check 7 ───────────────────────────────────────────────────────────────────
# Wired into install.sh: script + .service + .timer copied, timer enabled, env seeded.
chk7() {
  local root="${1:-.}" F
  F="$root/$INSTALL_REL"
  test -f "$F" || { err "$F" "missing — required for the szl-receipt-checkpoint guard"; return 1; }
  grep -Eq 'install .*sbin/szl-receipt-checkpoint' "$F" || {
    err "$F" "REGRESSION — install.sh no longer installs sbin/szl-receipt-checkpoint."
    return 1
  }
  grep -Fq 'szl-receipt-checkpoint.service' "$F" || {
    err "$F" "REGRESSION — install.sh no longer installs szl-receipt-checkpoint.service."
    return 1
  }
  grep -Fq 'szl-receipt-checkpoint.timer' "$F" || {
    err "$F" "REGRESSION — install.sh no longer installs szl-receipt-checkpoint.timer."
    return 1
  }
  grep -Eq 'systemctl enable --now szl-receipt-checkpoint\.timer' "$F" || {
    err "$F" "REGRESSION — install.sh no longer ENABLES szl-receipt-checkpoint.timer; the job wouldn't run after a rebuild."
    return 1
  }
  grep -Fq '/etc/szl-receipt-checkpoint.env' "$F" || {
    err "$F" "REGRESSION — install.sh no longer seeds the root-only token env file (/etc/szl-receipt-checkpoint.env)."
    return 1
  }
  echo "OK: install.sh installs the script + units, enables the timer, seeds the env file"
}

# ── Check 8 ───────────────────────────────────────────────────────────────────
# Documented in README.md with cadence + storage location.
chk8() {
  local root="${1:-.}" F
  F="$root/$README_REL"
  test -f "$F" || { err "$F" "missing — required for the szl-receipt-checkpoint guard"; return 1; }
  grep -Fq 'szl-receipt-checkpoint' "$F" || {
    err "$F" "REGRESSION — README.md no longer documents szl-receipt-checkpoint."
    return 1
  }
  grep -Fq 'receipts/checkpoint.json' "$F" || {
    err "$F" "REGRESSION — README.md no longer documents the durable storage location (receipts/checkpoint.json)."
    return 1
  }
  grep -Fiq 'daily' "$F" || {
    err "$F" "REGRESSION — README.md no longer documents the checkpoint cadence (daily)."
    return 1
  }
  echo "OK: README.md documents the checkpoint job, its cadence and storage"
}

# ── Check 9 ───────────────────────────────────────────────────────────────────
# verify_receipts.sh still honors SZL_ANCHOR_FILE (the anchor primitive).
chk9() {
  local root="${1:-.}" F
  F="$root/$VERIFY_REL"
  test -f "$F" || { err "$F" "missing — required for the szl-receipt-checkpoint guard"; return 1; }
  grep -Fq 'SZL_ANCHOR_FILE' "$F" || {
    err "$F" "REGRESSION — verify_receipts.sh no longer honors SZL_ANCHOR_FILE; the durable-checkpoint regression check is gone."
    return 1
  }
  grep -Fq 'TRUNCATION/ROLLBACK' "$F" || {
    err "$F" "REGRESSION — verify_receipts.sh lost the truncation/rollback detection used by the anchor check."
    return 1
  }
  echo "OK: verify_receipts.sh still honors SZL_ANCHOR_FILE (anchor regression primitive intact)"
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
      for c in chk1 chk2 chk3 chk4 chk5 chk6 chk7 chk8 chk9; do "$c" "$ROOT" || rc=1; done
      exit "$rc"
      ;;
    *) echo "unknown check: $CHECK (want chk1..chk9|all)" >&2; exit 2 ;;
  esac
fi
