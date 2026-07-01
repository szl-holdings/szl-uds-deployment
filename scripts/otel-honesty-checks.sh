# Copyright 2026 SZL Holdings
# SPDX-License-Identifier: Apache-2.0
#
# otel-honesty-checks.sh — keep the szl-receipts tracing setting from silently
# lying about a capability it doesn't have.
#
# BACKGROUND
# charts/szl-receipts/values.yaml once shipped `otel.enabled: true` with a
# confident "KEEP enabled: true" comment while NOTHING collected the spans:
# there is no opentelemetry-collector deployed, so the OTLP/gRPC exporter just
# retried-and-dropped forever. The chart read "tracing ON" but did nothing — a
# trap. It was flipped back to `false` to make config match reality, but there
# is no guard stopping the same drift from creeping back.
#
# THE INVARIANT
# `charts/szl-receipts/values.yaml` may only set `otel.enabled: true` when the
# repo also contains evidence that an OTLP collector actually exists to receive
# the spans — i.e. a real collector manifest, not just the client-side endpoint
# string the server points at. If tracing is advertised ON with no collector in
# the repo, this check FAILS the build so the chart never again claims a
# capability it can't deliver.
#
# "Collector evidence" is deliberately narrow so the client-side endpoint
# reference (values.yaml `otel.endpoint`, which merely NAMES a collector) never
# counts as proof one is deployed. It is one of:
#   * a Kubernetes/OTel-operator manifest with `kind: OpenTelemetryCollector`, or
#   * a workload manifest running a collector image
#     (image: ...opentelemetry-collector... / ...otel/opentelemetry-collector...
#      / ...otelcol...).
#
# Why a script and not inline workflow steps: the awk/grep logic can break
# silently (a regex slip makes a match miss and the step pass VACUOUSLY — green
# while guarding nothing). Extracting it here lets the self-test
# (otel-honesty-checks.test.sh) feed it deliberately-broken fixtures and prove
# it actually FAILS on the bad state.
#
# Usage:
#   otel-honesty-checks.sh <check> [root]
#     check : otel_honest | all
#     root  : repo root to check (default: current directory)
#
# Exits 0 when the invariant holds, non-zero (printing a GitHub ::error
# annotation) when it is violated.

set -uo pipefail

# err FILE MESSAGE — emit a GitHub Actions error annotation.
err() { echo "::error file=$1::$2"; }

VALUES_REL="charts/szl-receipts/values.yaml"

# otel_enabled_value ROOT — echo the boolean under the top-level `otel:` block's
# `enabled:` key ("true"/"false"), or empty if the block/key is absent. Only the
# top-level `otel:` block is inspected (other blocks also have an `enabled:`
# key), and only up to the next top-level (column-0) key.
otel_enabled_value() {
  local file="$1"
  awk '
    # Enter the otel block on a column-0 "otel:" line.
    /^otel:[[:space:]]*(#.*)?$/ { inblock=1; next }
    # Any other column-0, non-comment line ends the block.
    inblock && /^[^[:space:]#]/ { inblock=0 }
    # First indented enabled: inside the block wins.
    inblock && /^[[:space:]]+enabled:[[:space:]]*/ {
      line=$0
      sub(/^[[:space:]]+enabled:[[:space:]]*/, "", line)
      sub(/[[:space:]]*(#.*)?$/, "", line)
      gsub(/"/, "", line)
      print line
      exit
    }
  ' "$file"
}

# has_collector_evidence ROOT — return 0 if the repo contains a real collector
# manifest (see header). Excludes this guard's own files/fixtures so their
# example strings never count as evidence.
has_collector_evidence() {
  local root="$1"
  local matches
  matches="$(grep -rIlE \
    'kind:[[:space:]]*OpenTelemetryCollector|image:[[:space:]]*"?[^"[:space:]]*(opentelemetry-collector|otel/opentelemetry-collector|otelcol)' \
    "$root" 2>/dev/null \
    | grep -vE '(^|/)scripts/otel-honesty-checks\.(sh|test\.sh)$' \
    | grep -vE '(^|/)\.github/workflows/otel-honesty-guard\.yml$' \
    | grep -vE '(^|/)scripts/fixtures/' \
    || true)"
  [ -n "$matches" ]
}

# ── The honesty invariant ─────────────────────────────────────────────────────
otel_honest() {
  local root="${1:-.}"
  local F="$root/$VALUES_REL"
  test -f "$F" || { err "$F" "missing — cannot verify the otel honesty invariant"; return 1; }

  local enabled
  enabled="$(otel_enabled_value "$F")"

  if [ -z "$enabled" ]; then
    err "$F" "could not find the otel.enabled key — the honesty guard cannot verify it."
    err "$F" "Expected a top-level 'otel:' block with an 'enabled:' key."
    return 1
  fi

  if [ "$enabled" = "false" ]; then
    echo "OK: $F sets otel.enabled: false — no tracing claim to back up."
    return 0
  fi

  if [ "$enabled" != "true" ]; then
    err "$F" "otel.enabled has an unexpected value '$enabled' (want true/false)."
    return 1
  fi

  # enabled == true — demand real collector evidence in the repo.
  if has_collector_evidence "$root"; then
    echo "OK: otel.enabled: true and a collector manifest is present in the repo."
    return 0
  fi

  err "$F" "DISHONEST TRACING — otel.enabled: true but NO collector manifest exists in the repo."
  err "$F" "The OTLP exporter would ship spans to a dead endpoint (retry-and-drop forever);"
  err "$F" "nothing collects them, so the chart advertises tracing it cannot deliver."
  err "$F" "Fix: either set otel.enabled: false, OR add a real collector"
  err "$F" "(kind: OpenTelemetryCollector, or a workload running a collector image) so the"
  err "$F" "spans have somewhere to go."
  return 1
}

# ── Dispatch ──────────────────────────────────────────────────────────────────
main() {
  local check="${1:-all}"
  local root="${2:-.}"
  case "$check" in
    otel_honest) otel_honest "$root" ;;
    all)         otel_honest "$root" ;;
    *) echo "::error::unknown check '$check' (want: otel_honest | all)"; exit 2 ;;
  esac
}

# Only run main when executed, not when sourced (the self-test sources this file).
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
