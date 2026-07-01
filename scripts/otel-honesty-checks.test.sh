# Copyright 2026 SZL Holdings
# SPDX-License-Identifier: Apache-2.0
#
# otel-honesty-checks.test.sh — negative-fixture self-test for the otel honesty
# guard (scripts/otel-honesty-checks.sh).
#
# WHY THIS EXISTS
# The guard enforces "szl-receipts may only advertise tracing ON (otel.enabled:
# true) when a real collector manifest exists in the repo" entirely with
# awk/grep. If that logic breaks (a regex slip, an indentation miss) the check
# can PASS VACUOUSLY — green while guarding nothing — which is exactly the class
# of silent lie it's meant to catch. This test builds fixture repos and asserts:
#   * the pristine (honest) state PASSES, and
#   * the dishonest state (otel.enabled: true with no collector) actually FAILS.
# It sources the EXACT script the workflow runs, so it tests the real guard.
#
# Usage: bash scripts/otel-honesty-checks.test.sh
# Exit 0 if every case behaves as expected, 1 otherwise.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
CHECKS="$HERE/otel-honesty-checks.sh"

# Source the checks so we call otel_honest directly against the real functions.
# shellcheck source=/dev/null
source "$CHECKS"

PASS=0
FAIL=0
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

VALUES_REL="charts/szl-receipts/values.yaml"

# new_fixture — build a fresh fixture repo containing the real
# charts/szl-receipts/values.yaml, and echo its path. A collector manifest can
# be added per-case with add_collector.
new_fixture() {
  local dir
  dir="$(mktemp -d "$TMPROOT/fixture.XXXXXX")"
  mkdir -p "$dir/$(dirname "$VALUES_REL")"
  cp "$REPO_ROOT/$VALUES_REL" "$dir/$VALUES_REL"
  echo "$dir"
}

# set_otel_enabled DIR VALUE — flip otel.enabled in the fixture's values.yaml.
# Rewrites only the enabled: line inside the top-level otel: block.
set_otel_enabled() {
  local dir="$1" value="$2"
  python3 - "$dir/$VALUES_REL" "$value" <<'PY'
import sys, re
path, value = sys.argv[1], sys.argv[2]
lines = open(path).read().splitlines(keepends=True)
inblock = False
for i, l in enumerate(lines):
    if re.match(r'^otel:\s*(#.*)?$', l):
        inblock = True
        continue
    if inblock and re.match(r'^[^\s#]', l):
        inblock = False
    if inblock and re.match(r'^\s+enabled:', l):
        indent = re.match(r'^(\s+)enabled:', l).group(1)
        lines[i] = f"{indent}enabled: {value}\n"
        break
open(path, 'w').write(''.join(lines))
PY
}

# add_collector DIR — drop a real OpenTelemetryCollector manifest into the
# fixture so the "collector present" evidence path is exercised.
add_collector() {
  local dir="$1"
  mkdir -p "$dir/manifests"
  cat > "$dir/manifests/otel-collector.yaml" <<'YAML'
apiVersion: opentelemetry.io/v1beta1
kind: OpenTelemetryCollector
metadata:
  name: opentelemetry-collector
  namespace: monitoring
spec:
  mode: deployment
  config: |
    receivers:
      otlp:
        protocols:
          grpc:
            endpoint: 0.0.0.0:4317
YAML
}

# expect_pass ROOT NAME — assert otel_honest returns 0 on ROOT.
expect_pass() {
  local root="$1" name="$2" out rc
  out="$(otel_honest "$root" 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ]; then
    echo "ok   PASS-expected: $name"
    PASS=$((PASS+1))
  else
    echo "FAIL PASS-expected but otel_honest exited $rc: $name"
    echo "$out" | sed 's/^/       | /'
    FAIL=$((FAIL+1))
  fi
}

# expect_fail ROOT NAME — assert otel_honest returns non-zero on ROOT.
expect_fail() {
  local root="$1" name="$2" out rc
  out="$(otel_honest "$root" 2>&1)"; rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "ok   FAIL-expected: $name (exit $rc)"
    PASS=$((PASS+1))
  else
    echo "FAIL FAIL-expected but otel_honest PASSED: $name"
    echo "$out" | sed 's/^/       | /'
    FAIL=$((FAIL+1))
  fi
}

echo "== Honest states must PASS =="

# The real repo state: otel.enabled: false, no collector needed.
GOOD="$(new_fixture)"
expect_pass "$GOOD" "pristine values.yaml (otel.enabled: false)"

# Belt-and-braces: explicitly false still passes.
F="$(new_fixture)"; set_otel_enabled "$F" false
expect_pass "$F" "otel.enabled: false (explicit)"

# Honest ON: enabled: true WITH a real collector manifest present.
F="$(new_fixture)"; set_otel_enabled "$F" true; add_collector "$F"
expect_pass "$F" "otel.enabled: true WITH a collector manifest present"

echo
echo "== The dishonest state must FAIL (this is the core negative fixture) =="

# THE bug this guard exists for: tracing advertised ON, no collector in the repo.
F="$(new_fixture)"; set_otel_enabled "$F" true
expect_fail "$F" "otel.enabled: true and NO collector manifest (the silent lie)"

# Quoted "true" is the same dishonest state.
F="$(new_fixture)"; set_otel_enabled "$F" '"true"'
expect_fail "$F" 'otel.enabled: "true" (quoted) and no collector'

# Proof the endpoint STRING alone is not accepted as evidence: the pristine
# values.yaml already names a collector in otel.endpoint, yet enabled:true with
# only that reference must still FAIL.
F="$(new_fixture)"; set_otel_enabled "$F" true
if grep -q 'opentelemetry-collector' "$F/$VALUES_REL"; then
  expect_fail "$F" "endpoint string in values.yaml does NOT count as a collector"
else
  echo "FAIL setup: expected otel.endpoint to reference opentelemetry-collector"
  FAIL=$((FAIL+1))
fi

# Missing values.yaml must FAIL (can't verify => not silently green).
F="$(mktemp -d "$TMPROOT/empty.XXXXXX")"
expect_fail "$F" "values.yaml missing entirely"

echo
echo "================================================="
echo "Self-test results: $PASS passed, $FAIL failed."
if [ "$FAIL" -ne 0 ]; then
  echo "::error::otel honesty guard self-test FAILED — the check no longer behaves as expected."
  exit 1
fi
echo "otel honesty guard self-test passed — the dishonest state fails and honest states pass."
