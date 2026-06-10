# Copyright 2026 SZL Holdings
# SPDX-License-Identifier: Apache-2.0
#
# receipt-flood-checks.sh — the szl-receipts receipt-flood-guard invariant
# checks, extracted so the awk/grep logic is unit-testable (see
# receipt-flood-checks.test.sh).
#
# The pepr `pepr-szl` MutatingWebhook (pepr/policies/szl-receipt-on-deploy.ts)
# mints an Ed25519/DSSE receipt on every Deployment and Job admission — CREATE
# *and* UPDATE. Two failure modes turn that into a runaway flood that overloads
# szl-receipts-server and balloons the chain (observed ~2-13 POSTs/sec, the
# chain grew to 205919 before a reset):
#   1. Status / server-side-apply churn re-fires UPDATE admission for objects
#      whose `.spec` is unchanged.
#   2. Reconcile / delete-recreate hot-loops re-fire UPDATE many times per
#      second with a *changing* spec for the same subject.
#
# The two-layer fix is a single gate, shouldEmitReceipt(subject, specHash),
# called by BOTH the Deployment and the Job handler:
#   - spec-change dedup: skip when the current specHash equals the last minted
#     hash for that subject (kills status/SSA churn);
#   - per-subject rate limit: at most one receipt per SZL_MIN_RECEIPT_INTERVAL_MS
#     (default 2000ms) per subject (caps reconcile/recreate storms).
#
# Nothing else stops a future edit (or a sibling on the shared box tree) from
# silently deleting that guard and reopening the flood. This script asserts the
# guard is still wired in. It is a pure grep/awk text check — no cluster needed.
#
# Why a script and not inline workflow steps: an inline awk/grep program can
# break silently (an indentation/regex slip makes a match find nothing and the
# step pass VACUOUSLY — green while guarding nothing). By extracting the logic
# here we can feed it deliberately-broken fixtures in CI and prove each check
# actually FAILS on bad input. The workflow calls this exact script, so the
# self-test exercises the real guard.
#
# Usage:
#   receipt-flood-checks.sh <check> [root]
#     check : inv1 | inv2 | inv3 | inv4 | all
#     root  : repo root to check (default: current directory)
#
# Each check exits 0 when the invariant holds and non-zero (printing a GitHub
# ::error annotation) when it is regressed.

set -uo pipefail

# The single guarded source file, relative to the repo root.
SRC_REL="pepr/policies/szl-receipt-on-deploy.ts"

# err FILE MESSAGE — emit a GitHub Actions error annotation.
err() { echo "::error file=$1::$2"; }

# ── Block extractors ──────────────────────────────────────────────────────────
# The policy has two admission handlers and one gate function. We slice each out
# by name so a check can assert the gate is wired into a SPECIFIC handler (not
# merely defined somewhere, or called in only one of the two).

# _deployment_block FILE — the When(a.Deployment)…(up to)…When(a.Job) handler.
_deployment_block() {
  awk '
    /When\(a\.Job\)/        { exit }      # next handler begins — stop
    /When\(a\.Deployment\)/ { cap=1 }
    cap                     { print }
  ' "$1"
}

# _job_block FILE — the When(a.Job)…EOF handler.
_job_block() {
  awk '
    /When\(a\.Job\)/ { cap=1 }
    cap              { print }
  ' "$1"
}

# _should_emit_fn FILE — the body of function shouldEmitReceipt(...) {…}, from
# its declaration to the first closing brace at column 0 (inclusive).
_should_emit_fn() {
  awk '
    /^function shouldEmitReceipt\(/ { cap=1 }
    cap                             { print }
    cap && /^}/                     { exit }
  ' "$1"
}

# ── Invariant 1 ───────────────────────────────────────────────────────────────
# The Deployment handler must gate on shouldEmitReceipt() and early-return when
# it says no. Without this, every Deployment UPDATE re-mints a receipt -> flood.
inv1() {
  local root="${1:-.}"
  local F="$root/$SRC_REL"
  test -f "$F" || { err "$F" "missing — the receipt-on-deploy policy is required"; return 1; }
  local B; B="$(_deployment_block "$F")"
  if [ -z "$B" ]; then
    err "$F" "REGRESSION — Deployment handler (When(a.Deployment)) not found."
    return 1
  fi
  if ! printf '%s\n' "$B" | grep -Eq 'if[[:space:]]*\([[:space:]]*!shouldEmitReceipt\(.*\)[[:space:]]*return'; then
    err "$F" "REGRESSION — Deployment handler no longer gates on shouldEmitReceipt()."
    err "$F" "Without 'if (!shouldEmitReceipt(...)) return' every Deployment UPDATE re-mints a receipt -> flood."
    printf '%s\n' "$B" | grep -nE 'shouldEmitReceipt' || echo "(no shouldEmitReceipt reference in the Deployment handler)"
    return 1
  fi
  echo "OK: Deployment handler gates on shouldEmitReceipt() and early-returns"
}

# ── Invariant 2 ───────────────────────────────────────────────────────────────
# The Job handler must ALSO gate on shouldEmitReceipt(). The flood was driven by
# Deployment churn, but Jobs share the same signer and chain; an ungated Job
# handler reopens the same flood from CronJob/controller re-creates.
inv2() {
  local root="${1:-.}"
  local F="$root/$SRC_REL"
  test -f "$F" || { err "$F" "missing — the receipt-on-deploy policy is required"; return 1; }
  local B; B="$(_job_block "$F")"
  if [ -z "$B" ]; then
    err "$F" "REGRESSION — Job handler (When(a.Job)) not found."
    return 1
  fi
  if ! printf '%s\n' "$B" | grep -Eq 'if[[:space:]]*\([[:space:]]*!shouldEmitReceipt\(.*\)[[:space:]]*return'; then
    err "$F" "REGRESSION — Job handler no longer gates on shouldEmitReceipt()."
    err "$F" "Without 'if (!shouldEmitReceipt(...)) return' every Job UPDATE re-mints a receipt -> flood."
    printf '%s\n' "$B" | grep -nE 'shouldEmitReceipt' || echo "(no shouldEmitReceipt reference in the Job handler)"
    return 1
  fi
  echo "OK: Job handler gates on shouldEmitReceipt() and early-returns"
}

# ── Invariant 3 ───────────────────────────────────────────────────────────────
# Layer 1 of the gate: spec-change dedup. shouldEmitReceipt() must skip when the
# current specHash equals the last minted hash for the subject, AND record the
# new spec hash on a real mint (or the dedup map never populates and the skip is
# dead). This kills status / server-side-apply churn.
inv3() {
  local root="${1:-.}"
  local F="$root/$SRC_REL"
  test -f "$F" || { err "$F" "missing — the receipt-on-deploy policy is required"; return 1; }
  local FN; FN="$(_should_emit_fn "$F")"
  if [ -z "$FN" ]; then
    err "$F" "REGRESSION — function shouldEmitReceipt() not found."
    err "$F" "It is the single gate both handlers call; without it the flood guard is gone."
    return 1
  fi
  if ! printf '%s\n' "$FN" | grep -Eq '_lastSpecHash\.get\(subject\)[[:space:]]*===[[:space:]]*specHash'; then
    err "$F" "REGRESSION — spec-change dedup removed from shouldEmitReceipt()."
    err "$F" "Without the unchanged-spec skip, status/SSA churn re-mints receipts -> flood."
    return 1
  fi
  if ! printf '%s\n' "$FN" | grep -Eq '_lastSpecHash\.set\(subject,[[:space:]]*specHash\)'; then
    err "$F" "REGRESSION — shouldEmitReceipt() no longer records the minted spec hash."
    err "$F" "If the dedup map never populates, the unchanged-spec skip can never fire."
    return 1
  fi
  echo "OK: shouldEmitReceipt() keeps the spec-change dedup (skip-on-unchanged + record-on-mint)"
}

# ── Invariant 4 ───────────────────────────────────────────────────────────────
# Layer 2 of the gate: per-subject rate limit. The SZL_MIN_RECEIPT_INTERVAL_MS
# env knob must still feed MIN_RECEIPT_INTERVAL_MS, and shouldEmitReceipt() must
# throttle (skip) a subject seen again within that window. This caps
# reconcile/recreate storms even when the spec genuinely changes.
inv4() {
  local root="${1:-.}"
  local F="$root/$SRC_REL"
  test -f "$F" || { err "$F" "missing — the receipt-on-deploy policy is required"; return 1; }
  # 4a. The env knob must still drive the interval constant.
  if ! grep -Eq 'MIN_RECEIPT_INTERVAL_MS[[:space:]]*=.*process\.env\.SZL_MIN_RECEIPT_INTERVAL_MS' "$F"; then
    err "$F" "REGRESSION — SZL_MIN_RECEIPT_INTERVAL_MS rate-limit knob removed."
    err "$F" "Without it bursts of genuine spec changes (reconcile/recreate loops) flood the signer."
    grep -nE 'MIN_RECEIPT_INTERVAL_MS' "$F" || echo "(no MIN_RECEIPT_INTERVAL_MS reference)"
    return 1
  fi
  # 4b. The function must actually throttle on that interval.
  local FN; FN="$(_should_emit_fn "$F")"
  if [ -z "$FN" ]; then
    err "$F" "REGRESSION — function shouldEmitReceipt() not found (cannot rate-limit)."
    return 1
  fi
  if ! printf '%s\n' "$FN" | grep -Eq 'now[[:space:]]*-[[:space:]]*last[[:space:]]*<[[:space:]]*MIN_RECEIPT_INTERVAL_MS'; then
    err "$F" "REGRESSION — per-subject rate limit removed from shouldEmitReceipt()."
    err "$F" "Without the '(now - last) < MIN_RECEIPT_INTERVAL_MS' throttle, a hot-loop floods the signer."
    return 1
  fi
  echo "OK: shouldEmitReceipt() keeps the per-subject rate limit (SZL_MIN_RECEIPT_INTERVAL_MS)"
}

# all [root] — run every invariant; exit non-zero if ANY fail (run all so every
# regression is reported in one pass).
all() {
  local root="${1:-.}"
  local rc=0
  inv1 "$root" || rc=1
  inv2 "$root" || rc=1
  inv3 "$root" || rc=1
  inv4 "$root" || rc=1
  if [ "$rc" -eq 0 ]; then
    echo "All four szl-receipts receipt-flood invariants are intact."
  fi
  return "$rc"
}

main() {
  local check="${1:-all}"
  local root="${2:-.}"
  case "$check" in
    inv1) inv1 "$root" ;;
    inv2) inv2 "$root" ;;
    inv3) inv3 "$root" ;;
    inv4) inv4 "$root" ;;
    all)  all  "$root" ;;
    *)
      echo "usage: $0 {inv1|inv2|inv3|inv4|all} [root]" >&2
      return 2
      ;;
  esac
}

# Only run main when executed directly, so the test harness can `source` this
# file and call the inv* functions without triggering a run.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
