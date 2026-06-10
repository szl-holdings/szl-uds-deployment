# Copyright 2026 SZL Holdings
# SPDX-License-Identifier: Apache-2.0
#
# receipt-ingest-checks.test.sh — negative-fixture self-test for the server-side
# ingest-rate-limit guard (scripts/receipt-ingest-checks.sh).
#
# WHY THIS EXISTS
# The guard enforces the receipts server's anti-flood ingest cap entirely with
# hand-written awk/grep. If one of those programs breaks (a regex typo, an awk
# slip) the check can PASS VACUOUSLY — green while guarding nothing. This test
# feeds each check a deliberately-BROKEN copy of the guarded files and asserts the
# check FAILS, plus asserts the pristine ("good") copy PASSES. A future edit that
# neuters a check is caught here in CI.
#
# It runs the EXACT script the workflow runs (sourced as functions), against
# fixtures built from the real source files, so it tests the real guard.
#
# Usage: bash scripts/receipt-ingest-checks.test.sh
# Exit 0 if every case behaves as expected, 1 otherwise.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
CHECKS="$HERE/receipt-ingest-checks.sh"

# shellcheck source=/dev/null
source "$CHECKS"

PASS=0
FAIL=0
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

# The files the guard inspects, relative to a repo root.
SRV="services/szl-receipts-server/server.py"
VALUES="charts/szl-receipts/values.yaml"
DEPLOY="charts/szl-receipts/templates/deployment.yaml"

# new_fixture — build a fresh fixture tree (faithful copies of the real guarded
# files) under a unique dir and echo its path.
new_fixture() {
  local dir f
  dir="$(mktemp -d "$TMPROOT/fixture.XXXXXX")"
  for f in "$SRV" "$VALUES" "$DEPLOY"; do
    mkdir -p "$dir/$(dirname "$f")"
    cp "$REPO_ROOT/$f" "$dir/$f"
  done
  echo "$dir"
}

# expect_pass CHECK ROOT NAME — assert CHECK returns 0 on ROOT.
expect_pass() {
  local check="$1" root="$2" name="$3" out rc
  out="$("$check" "$root" 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ]; then
    echo "ok   PASS-expected: $name"
    PASS=$((PASS+1))
  else
    echo "FAIL PASS-expected but $check exited $rc: $name"
    echo "$out" | sed 's/^/       | /'
    FAIL=$((FAIL+1))
  fi
}

# expect_fail CHECK ROOT NAME — assert CHECK returns non-zero on ROOT.
expect_fail() {
  local check="$1" root="$2" name="$3" out rc
  out="$("$check" "$root" 2>&1)"; rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "ok   FAIL-expected: $name (exit $rc)"
    PASS=$((PASS+1))
  else
    echo "FAIL FAIL-expected but $check PASSED: $name"
    echo "$out" | sed 's/^/       | /'
    FAIL=$((FAIL+1))
  fi
}

echo "== Good fixture must PASS each check =="
GOOD="$(new_fixture)"
expect_pass inv1 "$GOOD" "inv1 on good source (env-driven token bucket)"
expect_pass inv2 "$GOOD" "inv2 on good source (429 shed before signing)"
expect_pass inv3 "$GOOD" "inv3 on good source (throttled counter + metric)"
expect_pass inv4 "$GOOD" "inv4 on good source (chart wiring)"

echo
echo "== Negative fixtures must FAIL the matching check =="

# --- Invariant 1: rate-limit env knob removed ---
F="$(new_fixture)"
sed -i 's/os.environ.get("SZL_INGEST_RATE_LIMIT", "1.0")/"1.0"/' "$F/$SRV"
expect_fail inv1 "$F" "inv1: SZL_INGEST_RATE_LIMIT env knob removed"

# --- Invariant 1: burst env knob removed ---
F="$(new_fixture)"
sed -i 's/os.environ.get("SZL_INGEST_BURST", "60")/"60"/' "$F/$SRV"
expect_fail inv1 "$F" "inv1: SZL_INGEST_BURST env knob removed"

# --- Invariant 1: limiter never sheds (no return False) ---
F="$(new_fixture)"
sed -i 's/return False/return True/' "$F/$SRV"
expect_fail inv1 "$F" "inv1: _ingest_allowed() can never shed"

# --- Invariant 2: POST /receipt no longer consults the limiter ---
F="$(new_fixture)"
sed -i 's/if not _ingest_allowed():/if False:/' "$F/$SRV"
expect_fail inv2 "$F" "inv2: ingest gate call removed from POST /receipt"

# --- Invariant 2: shed no longer returns 429 ---
F="$(new_fixture)"
sed -i 's/self._send(429, "application\/json",/self._send(200, "application\/json",/' "$F/$SRV"
expect_fail inv2 "$F" "inv2: shed branch no longer returns 429"

# --- Invariant 2: cap moved AFTER signing (ordering broken) ---
F="$(new_fixture)"
python3 - "$F/$SRV" <<'PY'
import sys, re
p = sys.argv[1]
lines = open(p).read().splitlines(keepends=True)
# Move the ingest-gate block (from `if not _ingest_allowed():` to its `return`)
# to AFTER the first sign_dsse(...) line, so the shed runs post-signing.
start = next(i for i, l in enumerate(lines) if 'if not _ingest_allowed():' in l)
end = start
while 'return' not in lines[end]:
    end += 1
block = lines[start:end+1]
del lines[start:end+1]
sign = next(i for i, l in enumerate(lines) if 'envelope = sign_dsse(' in l)
lines[sign+1:sign+1] = block
open(p, 'w').write(''.join(lines))
PY
expect_fail inv2 "$F" "inv2: ingest cap moved after signing"

# --- Invariant 3: shed no longer increments the counter ---
F="$(new_fixture)"
sed -i '/_counter_throttled += 1/d' "$F/$SRV"
expect_fail inv3 "$F" "inv3: throttled counter no longer incremented"

# --- Invariant 3: metric no longer exported ---
F="$(new_fixture)"
sed -i '/szl_receipts_throttled_total {_counter_throttled}/d' "$F/$SRV"
expect_fail inv3 "$F" "inv3: szl_receipts_throttled_total not exported"

# --- Invariant 4: chart values lose the ingest block ---
F="$(new_fixture)"
sed -i '/rateLimit: "1.0"/d; /burst: "20"/d' "$F/$VALUES"
expect_fail inv4 "$F" "inv4: server.ingest.{rateLimit,burst} removed from values"

# --- Invariant 4: Deployment stops wiring the env var ---
F="$(new_fixture)"
sed -i 's/.Values.server.ingest.rateLimit/.Values.server.logLevel/' "$F/$DEPLOY"
expect_fail inv4 "$F" "inv4: SZL_INGEST_RATE_LIMIT no longer wired from values"

# --- Missing files — every check must fail loudly, never vacuously pass ---
F="$(new_fixture)"
rm -f "$F/$SRV"
expect_fail inv1 "$F" "inv1: server source missing"
expect_fail inv2 "$F" "inv2: server source missing"
expect_fail inv3 "$F" "inv3: server source missing"
F="$(new_fixture)"
rm -f "$F/$VALUES"
expect_fail inv4 "$F" "inv4: chart values missing"
F="$(new_fixture)"
rm -f "$F/$DEPLOY"
expect_fail inv4 "$F" "inv4: Deployment template missing"

echo
echo "== Re-confirm the good fixture still PASSES (no fixture bleed) =="
GOOD2="$(new_fixture)"
expect_pass all "$GOOD2" "all invariants on good source"

echo
echo "================================================="
echo "Self-test results: $PASS passed, $FAIL failed."
if [ "$FAIL" -ne 0 ]; then
  echo "::error::receipt-ingest guard self-test FAILED — a check no longer behaves as expected."
  exit 1
fi
echo "receipt-ingest guard self-test passed — every check fails on bad input and passes on good input."
