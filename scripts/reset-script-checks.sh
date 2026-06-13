# Copyright 2026 SZL Holdings
# SPDX-License-Identifier: Apache-2.0
#
# reset-script-checks.sh — static invariant checks for the receipt-chain reset
# script (scripts/reset-receipt-chain.sh), extracted so the grep/awk logic is
# unit-testable (see reset-script-checks.test.sh).
#
# WHY THIS EXISTS
# The reset previously only wiped the flat store root ($STORE/*.json) and counted
# it with a flat `ls`. Once a chain grows past SZL_RECEIPT_SHARD_SIZE (default
# 10000) the server moves receipts into $STORE/shards/<bucket>/*.json — exactly
# the large/bloated case a reset is for. A flat-only wipe would silently leave
# the bulk of the chain behind, and a flat-only count would under-report it.
# That was fixed (shard-aware wipe + recursive count), but the fix had no guard.
# A future edit could quietly revert it. These checks fail loudly if it does.
#
# This is a pure text check — no cluster needed. The companion self-test
# (reset-script-checks.test.sh) feeds it deliberately-broken copies of the reset
# script and asserts each check FAILS, so a neutered check can't pass vacuously.
#
# Usage:
#   reset-script-checks.sh <check> [script]
#     check  : wipe_shards | recursive_count | all
#     script : path to the reset script
#              (default: scripts/reset-receipt-chain.sh under the repo root)
#
# Each check exits 0 when the invariant holds and non-zero (printing a GitHub
# ::error annotation) when it is regressed.

set -uo pipefail

# err FILE MESSAGE — emit a GitHub Actions error annotation.
err() { echo "::error file=$1::$2"; }

# default_script — locate scripts/reset-receipt-chain.sh relative to this file.
default_script() {
  local here
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  echo "$here/reset-receipt-chain.sh"
}

# count_block FILE — print the body of the count_on_disk() function so the
# recursive-count check inspects ONLY the "current chain" counter, not the
# post-wipe `find ... | wc -l` sanity print or the verify block.
count_block() {
  awk '
    /^count_on_disk\(\)[[:space:]]*\{/ { cap=1; print; next }
    cap { print }
    cap && /^\}/ { exit }
  ' "$1"
}

# ── Invariant 1 ───────────────────────────────────────────────────────────────
# The destructive wipe must delete the sharded layout, not just the flat root.
# It must contain `rm -rf $STORE/shards` (the server stores a large chain under
# $STORE/shards/<bucket>/), and must NOT have reverted to a flat-only wipe that
# only removes $STORE/*.json.
wipe_shards() {
  local F="${1:-$(default_script)}"
  test -f "$F" || { err "$F" "missing — required reset script"; return 1; }
  if ! grep -Eq 'rm[[:space:]]+-rf[[:space:]]+"?\$\{?STORE\}?"?/shards' "$F"; then
    err "$F" "REGRESSION — the wipe no longer removes \$STORE/shards."
    err "$F" "A large chain lives under \$STORE/shards/<bucket>/*.json; a flat-only"
    err "$F" "wipe (rm \$STORE/*.json) would SILENTLY leave the bulk of it behind."
    echo "----- current rm lines -----"
    grep -nE 'rm[[:space:]]+-[rf]' "$F" || echo "(none)"
    return 1
  fi
  echo "OK: $F wipes the sharded layout (rm -rf \$STORE/shards)"
}

# ── Invariant 2 ───────────────────────────────────────────────────────────────
# The "current chain" counter (count_on_disk) must count recursively across both
# the flat root and the shard buckets — i.e. `find $STORE ... -name '*.json'`,
# NOT a flat `ls $STORE/*.json | wc -l` that misses the shards.
recursive_count() {
  local F="${1:-$(default_script)}"
  test -f "$F" || { err "$F" "missing — required reset script"; return 1; }
  local BLOCK
  BLOCK="$(count_block "$F")"
  if [ -z "$BLOCK" ]; then
    err "$F" "REGRESSION — count_on_disk() function not found."
    return 1
  fi
  # Reject a flat-only `ls $STORE/*.json` counter outright.
  if printf '%s\n' "$BLOCK" | grep -Eq 'ls[[:space:]]+"?\$\{?STORE\}?"?/\*\.json'; then
    err "$F" "REGRESSION — count_on_disk reverted to a flat-only ls \$STORE/*.json."
    err "$F" "That misses receipts under \$STORE/shards/ and under-reports a large chain."
    printf '%s\n' "$BLOCK" | sed 's/^/       | /'
    return 1
  fi
  # Require a recursive find with a *.json name filter.
  if ! printf '%s\n' "$BLOCK" | grep -Eq "find[[:space:]]+\"?\\\$\\{?STORE\\}?\"?.*-name[[:space:]]+'?\\*\\.json'?"; then
    err "$F" "REGRESSION — count_on_disk no longer uses a recursive find ... -name '*.json'."
    err "$F" "Without it a large (sharded) chain is under-counted (or counted as 0)."
    printf '%s\n' "$BLOCK" | sed 's/^/       | /'
    return 1
  fi
  echo "OK: $F counts recursively (find \$STORE ... -name '*.json')"
}

# all [script] — run every check; exit non-zero if ANY fail (run all so every
# regression is reported in one pass).
all() {
  local F="${1:-$(default_script)}"
  local rc=0
  wipe_shards "$F"     || rc=1
  recursive_count "$F" || rc=1
  if [ "$rc" -eq 0 ]; then
    echo "Both reset-script shard-safety invariants are intact."
  fi
  return "$rc"
}

main() {
  local check="${1:-all}"
  local script="${2:-}"
  case "$check" in
    wipe_shards)     wipe_shards "$script" ;;
    recursive_count) recursive_count "$script" ;;
    all)             all "$script" ;;
    *)
      echo "usage: $0 {wipe_shards|recursive_count|all} [script]" >&2
      return 2
      ;;
  esac
}

# Only run main when executed directly so the test harness can `source` this
# file and call the check functions without triggering a run.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
