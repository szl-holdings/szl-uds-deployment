# Copyright 2026 SZL Holdings
# SPDX-License-Identifier: Apache-2.0
#
# receipt-flood-checks.test.sh — negative-fixture self-test for the receipt-flood
# guard (scripts/receipt-flood-checks.sh).
#
# WHY THIS EXISTS
# The guard enforces the two-layer receipt-flood guard entirely with hand-written
# awk/grep. If one of those programs breaks (an indentation slip, a regex typo)
# the check can PASS VACUOUSLY — green while guarding nothing. This test feeds
# each check a deliberately-BROKEN copy of pepr/policies/szl-receipt-on-deploy.ts
# and asserts the check FAILS, plus asserts the pristine ("good") copy PASSES. A
# future edit that neuters a check is caught here in CI.
#
# It runs the EXACT script the workflow runs (sourced as functions), against
# fixtures built from the real source file, so it tests the real guard.
#
# Usage: bash scripts/receipt-flood-checks.test.sh
# Exit 0 if every case behaves as expected, 1 otherwise.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
CHECKS="$HERE/receipt-flood-checks.sh"

# Source the checks so we can call inv1..inv4 directly. Sourcing (not exec)
# guarantees the self-test exercises the same functions the workflow calls.
# shellcheck source=/dev/null
source "$CHECKS"

PASS=0
FAIL=0
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

# The single source file the guard inspects, relative to a repo root.
SRC="pepr/policies/szl-receipt-on-deploy.ts"

# new_fixture — build a fresh fixture tree (a faithful copy of the real source
# file) under a unique dir and echo its path.
new_fixture() {
  local dir
  dir="$(mktemp -d "$TMPROOT/fixture.XXXXXX")"
  mkdir -p "$dir/$(dirname "$SRC")"
  cp "$REPO_ROOT/$SRC" "$dir/$SRC"
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

# del_nth_match FILE REGEX N — delete the Nth (1-based) line matching REGEX.
del_nth_match() {
  python3 - "$1" "$2" "$3" <<'PY'
import sys, re
p, pat, n = sys.argv[1], sys.argv[2], int(sys.argv[3])
lines = open(p).read().splitlines(keepends=True)
seen = 0
out = []
for l in lines:
    if re.search(pat, l):
        seen += 1
        if seen == n:
            continue
    out.append(l)
open(p, 'w').write(''.join(out))
PY
}

echo "== Good fixture must PASS each check =="
GOOD="$(new_fixture)"
expect_pass inv1 "$GOOD" "inv1 on good policy (Deployment handler gated)"
expect_pass inv2 "$GOOD" "inv2 on good policy (Job handler gated)"
expect_pass inv3 "$GOOD" "inv3 on good policy (spec-change dedup)"
expect_pass inv4 "$GOOD" "inv4 on good policy (per-subject rate limit)"

echo
echo "== Negative fixtures must FAIL the matching check =="

# --- Invariant 1: Deployment handler loses its gate (delete the 1st gate line) ---
F="$(new_fixture)"
del_nth_match "$F/$SRC" 'if \(!shouldEmitReceipt\(' 1
expect_fail inv1 "$F" "inv1: Deployment handler gate removed"
# Sanity: removing only the Deployment gate must NOT fool inv2 (Job still gated).
expect_pass inv2 "$F" "inv2 still passes when only the Deployment gate is removed"

# --- Invariant 2: Job handler loses its gate (delete the 2nd gate line) ---
F="$(new_fixture)"
del_nth_match "$F/$SRC" 'if \(!shouldEmitReceipt\(' 2
expect_fail inv2 "$F" "inv2: Job handler gate removed"
# Sanity: removing only the Job gate must NOT fool inv1 (Deployment still gated).
expect_pass inv1 "$F" "inv1 still passes when only the Job gate is removed"

# --- Invariant 3: spec-change dedup comparison removed ---
F="$(new_fixture)"
sed -i 's/_lastSpecHash\.get(subject) === specHash/false/' "$F/$SRC"
expect_fail inv3 "$F" "inv3: unchanged-spec skip removed"

# --- Invariant 3: dedup map never records the minted spec hash ---
F="$(new_fixture)"
sed -i '/_lastSpecHash\.set(subject, specHash)/d' "$F/$SRC"
expect_fail inv3 "$F" "inv3: minted spec hash no longer recorded"

# --- Invariant 4: SZL_MIN_RECEIPT_INTERVAL_MS env knob removed ---
F="$(new_fixture)"
sed -i 's/process\.env\.SZL_MIN_RECEIPT_INTERVAL_MS/process.env.SZL_DISABLED_KNOB/' "$F/$SRC"
expect_fail inv4 "$F" "inv4: rate-limit env knob removed"

# --- Invariant 4: per-subject throttle comparison removed ---
F="$(new_fixture)"
sed -i 's/now - last < MIN_RECEIPT_INTERVAL_MS/false/' "$F/$SRC"
expect_fail inv4 "$F" "inv4: throttle comparison removed"

# --- Whole gate function deleted — inv1..inv4 must all fail ---
F="$(new_fixture)"
python3 - "$F/$SRC" <<'PY'
import sys, re
p = sys.argv[1]
src = open(p).read().splitlines(keepends=True)
out = []
skip = False
for l in src:
    if re.match(r'^function shouldEmitReceipt\(', l):
        skip = True
    if not skip:
        out.append(l)
    if skip and re.match(r'^}', l):
        skip = False
# also drop the two call sites so the handlers reference an undefined fn
out = [l for l in out if not re.search(r'shouldEmitReceipt\(', l)]
open(p, 'w').write(''.join(out))
PY
expect_fail inv1 "$F" "inv1: whole gate removed"
expect_fail inv2 "$F" "inv2: whole gate removed"
expect_fail inv3 "$F" "inv3: whole gate removed"
expect_fail inv4 "$F" "inv4: whole gate removed"

# --- Missing source file — every check must fail loudly, never vacuously pass ---
F="$(new_fixture)"
rm -f "$F/$SRC"
expect_fail inv1 "$F" "inv1: policy file missing"
expect_fail inv2 "$F" "inv2: policy file missing"
expect_fail inv3 "$F" "inv3: policy file missing"
expect_fail inv4 "$F" "inv4: policy file missing"

echo
echo "== Re-confirm the good fixture still PASSES (no fixture bleed) =="
GOOD2="$(new_fixture)"
expect_pass all "$GOOD2" "all invariants on a good policy"

echo
echo "================================================="
echo "Self-test results: $PASS passed, $FAIL failed."
if [ "$FAIL" -ne 0 ]; then
  echo "::error::receipt-flood guard self-test FAILED — a check no longer behaves as expected."
  exit 1
fi
echo "receipt-flood guard self-test passed — every check fails on bad input and passes on good input."
