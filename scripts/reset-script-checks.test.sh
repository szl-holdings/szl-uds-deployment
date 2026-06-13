# Copyright 2026 SZL Holdings
# SPDX-License-Identifier: Apache-2.0
#
# reset-script-checks.test.sh — negative-fixture self-test for the reset-script
# shard-safety guard (scripts/reset-script-checks.sh).
#
# WHY THIS EXISTS
# The guard enforces that scripts/reset-receipt-chain.sh wipes AND counts the
# sharded layout, not just the flat store root. The checks are hand-written
# grep/awk — a regex slip could make a check PASS VACUOUSLY (green while guarding
# nothing). This test feeds each check a deliberately-BROKEN copy of the reset
# script and asserts the check FAILS, plus asserts the pristine copy PASSES. A
# future edit that neuters a check is caught here in CI.
#
# It sources and runs the EXACT functions the workflow runs, against fixtures
# built from the real reset script, so it tests the real guard.
#
# Usage: bash scripts/reset-script-checks.test.sh
# Exit 0 if every case behaves as expected, 1 otherwise.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
CHECKS="$HERE/reset-script-checks.sh"
SRC="$REPO_ROOT/scripts/reset-receipt-chain.sh"

# shellcheck source=/dev/null
source "$CHECKS"

PASS=0
FAIL=0
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

# new_fixture — copy the real reset script to a fresh temp file and echo its path.
new_fixture() {
  local f
  f="$(mktemp "$TMPROOT/reset.XXXXXX.sh")"
  cp "$SRC" "$f"
  echo "$f"
}

# expect_pass CHECK SCRIPT NAME — assert CHECK returns 0 on SCRIPT.
expect_pass() {
  local check="$1" script="$2" name="$3" out rc
  out="$("$check" "$script" 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ]; then
    echo "ok   PASS-expected: $name"
    PASS=$((PASS+1))
  else
    echo "FAIL PASS-expected but $check exited $rc: $name"
    echo "$out" | sed 's/^/       | /'
    FAIL=$((FAIL+1))
  fi
}

# expect_fail CHECK SCRIPT NAME — assert CHECK returns non-zero on SCRIPT.
expect_fail() {
  local check="$1" script="$2" name="$3" out rc
  out="$("$check" "$script" 2>&1)"; rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "ok   FAIL-expected: $name (exit $rc)"
    PASS=$((PASS+1))
  else
    echo "FAIL FAIL-expected but $check PASSED: $name"
    echo "$out" | sed 's/^/       | /'
    FAIL=$((FAIL+1))
  fi
}

echo "== The real reset script must PASS both checks =="
expect_pass wipe_shards     "$SRC" "wipe_shards on real reset-receipt-chain.sh"
expect_pass recursive_count "$SRC" "recursive_count on real reset-receipt-chain.sh"
expect_pass all             "$SRC" "all on real reset-receipt-chain.sh"

echo
echo "== Negative fixtures must FAIL the matching check =="

# --- Invariant 1: shard wipe removed (flat-only wipe) ---
F="$(new_fixture)"
sed -i 's#[[:space:]]*rm -rf \$STORE/shards;##' "$F"
expect_fail wipe_shards "$F" "wipe_shards: rm -rf \$STORE/shards removed"

# --- Invariant 1: whole wipe line reverted to flat-only ---
F="$(new_fixture)"
sed -i 's#sh -c "rm -f \$STORE/\*.json \$STORE/.chain_head; rm -rf \$STORE/shards; find \$STORE -type f | wc -l"#sh -c "rm -f \$STORE/*.json \$STORE/.chain_head"#' "$F"
expect_fail wipe_shards "$F" "wipe_shards: wipe reverted to flat \$STORE/*.json only"

# --- Invariant 2: count reverted to a flat-only ls ---
F="$(new_fixture)"
python3 - "$F" <<'PY'
import sys, re
p = sys.argv[1]
s = open(p).read()
s = s.replace(
    "sh -c \"find $STORE -type f -name '*.json' 2>/dev/null | wc -l\"",
    "sh -c \"ls $STORE/*.json 2>/dev/null | wc -l\"")
open(p, "w").write(s)
PY
expect_fail recursive_count "$F" "recursive_count: count_on_disk reverted to flat ls \$STORE/*.json"

# --- Invariant 2: -name '*.json' filter dropped from the recursive find ---
F="$(new_fixture)"
python3 - "$F" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
s = s.replace(
    "sh -c \"find $STORE -type f -name '*.json' 2>/dev/null | wc -l\"",
    "sh -c \"cat $STORE/count.txt 2>/dev/null\"")
open(p, "w").write(s)
PY
expect_fail recursive_count "$F" "recursive_count: recursive find ... -name '*.json' removed"

echo
echo "== Re-confirm the real script still PASSES (no fixture bleed) =="
expect_pass all "$SRC" "all on real reset-receipt-chain.sh (re-check)"

echo
echo "================================================="
echo "Self-test results: $PASS passed, $FAIL failed."
if [ "$FAIL" -ne 0 ]; then
  echo "::error::reset-script guard self-test FAILED — a check no longer behaves as expected."
  exit 1
fi
echo "reset-script guard self-test passed — every check fails on bad input and passes on good input."
