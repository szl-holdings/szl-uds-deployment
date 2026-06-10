# Copyright 2026 SZL Holdings
# SPDX-License-Identifier: Apache-2.0
#
# receipt-ingest-checks.sh — the szl-receipts SERVER-SIDE ingest-rate-limit
# invariant checks, extracted so the awk/grep logic is unit-testable (see
# receipt-ingest-checks.test.sh).
#
# This is the SECOND, independent layer of the receipt-flood defense. The first
# layer lives in the pepr webhook (pepr/policies/szl-receipt-on-deploy.ts, guarded
# by receipt-flood-guard.yml). The pepr POST path is fail-OPEN, so if that layer
# is ever bypassed, disabled, or a non-pepr emitter starts looping, the only thing
# left between a runaway loop and an OOM/CPU-starved 2-vCPU box (chain observed
# past 267k, repeated OOMKills) is the chain authority's OWN token-bucket cap on
# POST /receipt in services/szl-receipts-server/server.py:
#   - _ingest_allowed() refills SZL_INGEST_RATE_LIMIT tokens/sec up to
#     SZL_INGEST_BURST and consumes one per accepted receipt;
#   - POST /receipt sheds with HTTP 429 (BEFORE signing/appending) when the bucket
#     is empty, so a flood costs ~nothing and can neither balloon the chain nor
#     OOM the box;
#   - shed requests bump szl_receipts_throttled_total so the shedding is visible.
#
# Nothing else stops a future edit (or a sibling on the shared box tree) from
# silently deleting that cap and reopening the flood. This script asserts the cap
# is still wired in — server code AND its Helm wiring. Pure grep/awk, no cluster.
#
# Why a script and not inline workflow steps: an inline awk/grep program can break
# silently (a regex slip makes a match find nothing and the step pass VACUOUSLY —
# green while guarding nothing). By extracting the logic here we can feed it
# deliberately-broken fixtures in CI and prove each check actually FAILS on bad
# input. The workflow calls this exact script, so the self-test exercises the real
# guard.
#
# Usage:
#   receipt-ingest-checks.sh <check> [root]
#     check : inv1 | inv2 | inv3 | inv4 | all
#     root  : repo root to check (default: current directory)
#
# Each check exits 0 when the invariant holds and non-zero (printing a GitHub
# ::error annotation) when it is regressed.

set -uo pipefail

# The guarded files, relative to the repo root.
SRV_REL="services/szl-receipts-server/server.py"
VALUES_REL="charts/szl-receipts/values.yaml"
DEPLOY_REL="charts/szl-receipts/templates/deployment.yaml"

# err FILE MESSAGE — emit a GitHub Actions error annotation.
err() { echo "::error file=$1::$2"; }

# ── Block extractors ──────────────────────────────────────────────────────────

# _ingest_fn FILE — the body of `def _ingest_allowed():` from its declaration to
# (but not including) the next top-level (column-0) statement.
_ingest_fn() {
  awk '
    /^def _ingest_allowed\(/ { cap=1; print; next }
    cap && /^[^[:space:]]/   { exit }      # next top-level statement — stop
    cap                      { print }
  ' "$1"
}

# _shed_block FILE — the POST /receipt shed branch, from `if not _ingest_allowed():`
# through the first `return` (inclusive).
_shed_block() {
  awk '
    /if not _ingest_allowed\(\):/ { cap=1 }
    cap                           { print }
    cap && /return/               { exit }
  ' "$1"
}

# ── Invariant 1 ───────────────────────────────────────────────────────────────
# The token-bucket limiter must exist and be driven by the two env knobs. Without
# the env-configured bucket there is no sustained-rate cap at the chain authority.
inv1() {
  local root="${1:-.}"
  local F="$root/$SRV_REL"
  test -f "$F" || { err "$F" "missing — the receipts server is required"; return 1; }
  # 1a. Both env knobs must still configure the bucket.
  if ! grep -Eq 'INGEST_RATE_LIMIT[[:space:]]*=.*os\.environ\.get\("SZL_INGEST_RATE_LIMIT"' "$F"; then
    err "$F" "REGRESSION — SZL_INGEST_RATE_LIMIT no longer configures the ingest limiter."
    grep -nE 'SZL_INGEST_RATE_LIMIT' "$F" || echo "(no SZL_INGEST_RATE_LIMIT reference)"
    return 1
  fi
  if ! grep -Eq 'INGEST_BURST[[:space:]]*=.*os\.environ\.get\("SZL_INGEST_BURST"' "$F"; then
    err "$F" "REGRESSION — SZL_INGEST_BURST no longer configures the ingest limiter."
    grep -nE 'SZL_INGEST_BURST' "$F" || echo "(no SZL_INGEST_BURST reference)"
    return 1
  fi
  # 1b. _ingest_allowed() must be a real token bucket: refill on the rate, and a
  #     shed path (return False) when the bucket is empty.
  local FN; FN="$(_ingest_fn "$F")"
  if [ -z "$FN" ]; then
    err "$F" "REGRESSION — function _ingest_allowed() not found; the ingest cap is gone."
    return 1
  fi
  if ! printf '%s\n' "$FN" | grep -Eq 'INGEST_RATE_LIMIT'; then
    err "$F" "REGRESSION — _ingest_allowed() no longer refills on INGEST_RATE_LIMIT."
    return 1
  fi
  if ! printf '%s\n' "$FN" | grep -Eq 'return False'; then
    err "$F" "REGRESSION — _ingest_allowed() has no shed path (return False when empty)."
    err "$F" "Without it the bucket can never deny, so the sustained-rate cap is dead."
    return 1
  fi
  echo "OK: _ingest_allowed() is an env-driven token bucket (SZL_INGEST_RATE_LIMIT/SZL_INGEST_BURST) with a shed path"
}

# ── Invariant 2 ───────────────────────────────────────────────────────────────
# POST /receipt must consult _ingest_allowed() and shed with HTTP 429 + return,
# and it must do so BEFORE signing the receipt — otherwise a flood still costs a
# signature and a chain append per request and can OOM the box.
inv2() {
  local root="${1:-.}"
  local F="$root/$SRV_REL"
  test -f "$F" || { err "$F" "missing — the receipts server is required"; return 1; }
  local B; B="$(_shed_block "$F")"
  if [ -z "$B" ]; then
    err "$F" "REGRESSION — POST /receipt no longer gates on _ingest_allowed()."
    err "$F" "Without 'if not _ingest_allowed(): ... 429 ... return' a flood is accepted unbounded."
    grep -nE '_ingest_allowed\(' "$F" || echo "(no _ingest_allowed() call site)"
    return 1
  fi
  if ! printf '%s\n' "$B" | grep -Eq '429'; then
    err "$F" "REGRESSION — the ingest shed branch no longer returns HTTP 429."
    return 1
  fi
  if ! printf '%s\n' "$B" | grep -Eq 'return'; then
    err "$F" "REGRESSION — the ingest shed branch no longer early-returns; the request would be processed anyway."
    return 1
  fi
  # Ordering: the shed must be checked BEFORE the receipt is signed.
  local shed_ln sign_ln
  shed_ln="$(grep -nE 'if not _ingest_allowed\(\):' "$F" | head -n1 | cut -d: -f1)"
  sign_ln="$(grep -nE 'envelope = sign_dsse\(' "$F" | head -n1 | cut -d: -f1)"
  if [ -z "$shed_ln" ] || [ -z "$sign_ln" ] || [ "$shed_ln" -ge "$sign_ln" ]; then
    err "$F" "REGRESSION — the ingest cap no longer runs BEFORE signing (shed line $shed_ln, first sign line $sign_ln)."
    err "$F" "A flood must be shed before it costs a signature + chain append, or it can still OOM the box."
    return 1
  fi
  echo "OK: POST /receipt sheds floods with HTTP 429 + return BEFORE signing"
}

# ── Invariant 3 ───────────────────────────────────────────────────────────────
# Shed requests must be observable: increment _counter_throttled on the shed path
# AND export szl_receipts_throttled_total in /metrics. Without it a silent cap can
# shed real traffic with no signal, and operators cannot alert on a flood.
inv3() {
  local root="${1:-.}"
  local F="$root/$SRV_REL"
  test -f "$F" || { err "$F" "missing — the receipts server is required"; return 1; }
  local B; B="$(_shed_block "$F")"
  if ! printf '%s\n' "$B" | grep -Eq '_counter_throttled[[:space:]]*\+=[[:space:]]*1'; then
    err "$F" "REGRESSION — the shed branch no longer increments _counter_throttled."
    err "$F" "Shedding would be invisible; operators could not see or alert on a flood."
    return 1
  fi
  if ! grep -Eq 'szl_receipts_throttled_total[[:space:]]+\{?_counter_throttled' "$F"; then
    err "$F" "REGRESSION — szl_receipts_throttled_total is no longer exported in /metrics."
    grep -nE 'szl_receipts_throttled_total' "$F" || echo "(no szl_receipts_throttled_total reference)"
    return 1
  fi
  echo "OK: shed path increments _counter_throttled and exports szl_receipts_throttled_total"
}

# ── Invariant 4 ───────────────────────────────────────────────────────────────
# The Helm wiring must keep the cap configurable and actually pass it to the pod:
# values.yaml exposes server.ingest.{rateLimit,burst}, and the Deployment wires
# them into SZL_INGEST_RATE_LIMIT / SZL_INGEST_BURST. Without the wiring the env
# knobs the server reads are never set from the chart.
inv4() {
  local root="${1:-.}"
  local V="$root/$VALUES_REL"
  local D="$root/$DEPLOY_REL"
  test -f "$V" || { err "$V" "missing — the szl-receipts chart values are required"; return 1; }
  test -f "$D" || { err "$D" "missing — the szl-receipts Deployment template is required"; return 1; }
  # 4a. values.yaml must expose the ingest block with both knobs.
  local IB
  IB="$(awk '/^[[:space:]]*ingest:[[:space:]]*$/ {cap=1; print; next} cap && /^[[:space:]]{0,2}[a-zA-Z]/ {exit} cap {print}' "$V")"
  if [ -z "$IB" ] || ! printf '%s\n' "$IB" | grep -Eq 'rateLimit:' || ! printf '%s\n' "$IB" | grep -Eq 'burst:'; then
    err "$V" "REGRESSION — server.ingest.{rateLimit,burst} removed from chart values."
    err "$V" "Without them the ingest cap is no longer configurable from the chart."
    return 1
  fi
  # 4b. The Deployment must wire both env vars from those values.
  if ! grep -Eq 'name:[[:space:]]*SZL_INGEST_RATE_LIMIT' "$D" \
     || ! grep -Eq '\.Values\.server\.ingest\.rateLimit' "$D"; then
    err "$D" "REGRESSION — SZL_INGEST_RATE_LIMIT no longer wired from .Values.server.ingest.rateLimit."
    return 1
  fi
  if ! grep -Eq 'name:[[:space:]]*SZL_INGEST_BURST' "$D" \
     || ! grep -Eq '\.Values\.server\.ingest\.burst' "$D"; then
    err "$D" "REGRESSION — SZL_INGEST_BURST no longer wired from .Values.server.ingest.burst."
    return 1
  fi
  echo "OK: chart exposes server.ingest.{rateLimit,burst} and the Deployment wires both into the pod env"
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
    echo "All four szl-receipts server-side ingest-rate-limit invariants are intact."
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
