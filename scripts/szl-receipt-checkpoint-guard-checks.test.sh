#!/usr/bin/env bash
# Copyright 2026 SZL Holdings
# SPDX-License-Identifier: Apache-2.0
#
# Self-test (negative fixtures) for szl-receipt-checkpoint-guard-checks.sh.
#
# A guard is only worth its green check if it actually FAILS when the thing it
# guards regresses. This harness:
#   1. asserts every check PASSES against the pristine repo, then
#   2. for each check, builds a fixture with ONLY that check's invariant broken
#      and asserts the check FAILS.
# If a future edit neuters a check (so it passes even on a broken fixture), this
# self-test goes red — the guard cannot rot into a vacuous green.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
CHECKS="$HERE/szl-receipt-checkpoint-guard-checks.sh"

# shellcheck source=/dev/null
source "$CHECKS"

SRC_FILES=(
  "box-scripts/sbin/szl-receipt-checkpoint"
  "box-scripts/systemd/szl-receipt-checkpoint.service"
  "box-scripts/systemd/szl-receipt-checkpoint.timer"
  "box-scripts/install.sh"
  "box-scripts/README.md"
  "scripts/verify_receipts.sh"
)

PASS=0
FAIL=0
ok()  { echo "  ok: $1"; PASS=$((PASS + 1)); }
bad() { echo "  NOT OK: $1"; FAIL=$((FAIL + 1)); }

new_fixture() {
  local d; d="$(mktemp -d)"
  local rel
  for rel in "${SRC_FILES[@]}"; do
    mkdir -p "$d/$(dirname "$rel")"
    cp "$REPO_ROOT/$rel" "$d/$rel"
  done
  echo "$d"
}

expect_pass() {
  local check="$1" root="$2" label="$3"
  if "$check" "$root" >/dev/null 2>&1; then ok "$label"; else bad "$label (expected PASS, got FAIL)"; fi
}
expect_fail() {
  local check="$1" root="$2" label="$3"
  if "$check" "$root" >/dev/null 2>&1; then bad "$label (expected FAIL, got PASS)"; else ok "$label"; fi
}

echo "== 1. pristine repo: every check PASSES =="
for c in chk1 chk2 chk3 chk4 chk5 chk6 chk7 chk8 chk9; do
  expect_pass "$c" "$REPO_ROOT" "$c passes on pristine repo"
done

echo "== 2. negative fixtures: each check FAILS when its invariant is broken =="

# chk1 — script missing
d="$(new_fixture)"; rm -f "$d/box-scripts/sbin/szl-receipt-checkpoint"
expect_fail chk1 "$d" "chk1 fails when szl-receipt-checkpoint is missing"
rm -rf "$d"

# chk1 — syntax error
d="$(new_fixture)"; printf '\nif then fi\n' >> "$d/box-scripts/sbin/szl-receipt-checkpoint"
expect_fail chk1 "$d" "chk1 fails on a syntax error (bash -n)"
rm -rf "$d"

# chk2 — drop the live self-verify refusal
d="$(new_fixture)"; sed -i 's/refusing to checkpoint/DISABLED/g' "$d/box-scripts/sbin/szl-receipt-checkpoint"
expect_fail chk2 "$d" "chk2 fails when the live self-verify refusal is removed"
rm -rf "$d"

# chk3 — drop the durable-anchor regression check
d="$(new_fixture)"; sed -i 's/regressed below durable checkpoint/DISABLED/g' "$d/box-scripts/sbin/szl-receipt-checkpoint"
expect_fail chk3 "$d" "chk3 fails when the durable-anchor regression check is removed"
rm -rf "$d"

# chk4 — break the edge-trigger (neuter the notify calls)
d="$(new_fixture)"; sed -i 's/^\([[:space:]]*\)notify "/\1DISABLED_notify "/' "$d/box-scripts/sbin/szl-receipt-checkpoint"
expect_fail chk4 "$d" "chk4 fails when the notify calls are removed (no per-edge paging)"
rm -rf "$d"

# chk5 — remove the cluster-unreachable no-op
d="$(new_fixture)"; sed -i '/readyz/s/exit 0/exit 9/' "$d/box-scripts/sbin/szl-receipt-checkpoint"
expect_fail chk5 "$d" "chk5 fails when the cluster-unreachable path stops no-oping"
rm -rf "$d"

# chk6 — collide the checkpoint filename with the baseline workstream
d="$(new_fixture)"; sed -i 's|receipts/checkpoint.json|receipts/baseline.json|g' "$d/box-scripts/sbin/szl-receipt-checkpoint"
expect_fail chk6 "$d" "chk6 fails when the distinct checkpoint filename is lost"
rm -rf "$d"

# chk6 — lose the monotonic advance guard
d="$(new_fixture)"; sed -i 's/-gt "\$ANCHOR_IDX"/-ge "\$ANCHOR_IDX"/' "$d/box-scripts/sbin/szl-receipt-checkpoint"
expect_fail chk6 "$d" "chk6 fails when the monotonic advance guard is weakened"
rm -rf "$d"

# chk7 — un-wire the timer enable from install.sh
d="$(new_fixture)"; sed -i 's/systemctl enable --now szl-receipt-checkpoint.timer/# DISABLED/' "$d/box-scripts/install.sh"
expect_fail chk7 "$d" "chk7 fails when install.sh stops enabling the timer"
rm -rf "$d"

# chk8 — remove the README documentation
d="$(new_fixture)"; sed -i 's|receipts/checkpoint.json|receipts/REDACTED|g' "$d/box-scripts/README.md"
expect_fail chk8 "$d" "chk8 fails when README.md drops the storage location"
rm -rf "$d"

# chk9 — strip SZL_ANCHOR_FILE support from verify_receipts.sh
d="$(new_fixture)"; sed -i 's/SZL_ANCHOR_FILE/DISABLED/g' "$d/scripts/verify_receipts.sh"
expect_fail chk9 "$d" "chk9 fails when verify_receipts.sh drops SZL_ANCHOR_FILE support"
rm -rf "$d"

echo
echo "== summary: $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
