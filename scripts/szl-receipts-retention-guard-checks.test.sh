#!/usr/bin/env bash
# Copyright 2026 SZL Holdings
# SPDX-License-Identifier: Apache-2.0
#
# Self-test (negative fixtures) for szl-receipts-retention-guard-checks.sh.
#
# A guard is only worth its green check if it actually FAILS when the thing it
# guards regresses. This harness:
#   1. asserts every check PASSES against the pristine repo, then
#   2. for each behavioural check, builds a fixture with ONLY that check's
#      invariant broken (verify gate removed, prune gate removed, benign-error
#      allow-list removed, ...) and asserts the check FAILS.
# If a future edit neuters a check (so it passes even on a broken fixture), this
# self-test goes red — the guard cannot rot into a vacuous green.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
CHECKS="$HERE/szl-receipts-retention-guard-checks.sh"

# Source the checks so we can call chkN directly against a fixture root.
# shellcheck source=/dev/null
source "$CHECKS"

# Files the guard inspects (relative to a repo root).
SRC_FILES=(
  "box-scripts/sbin/szl-receipts-retention"
  "box-scripts/install.sh"
  "docs/operations/RECEIPT_STORE_RETENTION_RUNBOOK.md"
)

PASS=0
FAIL=0
ok()  { echo "  ok: $1"; PASS=$((PASS + 1)); }
bad() { echo "  NOT OK: $1"; FAIL=$((FAIL + 1)); }

# new_fixture — copy the pristine source files into a fresh temp repo root and
# echo the root path. Each test mutates its own copy.
new_fixture() {
  local d; d="$(mktemp -d)"
  local rel
  for rel in "${SRC_FILES[@]}"; do
    mkdir -p "$d/$(dirname "$rel")"
    cp "$REPO_ROOT/$rel" "$d/$rel"
  done
  echo "$d"
}

SCRIPT_REL="box-scripts/sbin/szl-receipts-retention"
INSTALL_REL_T="box-scripts/install.sh"
RUNBOOK_REL_T="docs/operations/RECEIPT_STORE_RETENTION_RUNBOOK.md"

# expect_pass CHECK ROOT LABEL
expect_pass() {
  local check="$1" root="$2" label="$3"
  if "$check" "$root" >/dev/null 2>&1; then ok "$label"; else bad "$label (expected PASS, got FAIL)"; fi
}
# expect_fail CHECK ROOT LABEL
expect_fail() {
  local check="$1" root="$2" label="$3"
  if "$check" "$root" >/dev/null 2>&1; then bad "$label (expected FAIL, got PASS)"; else ok "$label"; fi
}

echo "== 1. pristine repo: every check PASSES =="
expect_pass chk1 "$REPO_ROOT" "chk1 passes on pristine repo"
expect_pass chk2 "$REPO_ROOT" "chk2 passes on pristine repo"
expect_pass chk3 "$REPO_ROOT" "chk3 passes on pristine repo"
expect_pass chk4 "$REPO_ROOT" "chk4 passes on pristine repo"
expect_pass chk5 "$REPO_ROOT" "chk5 passes on pristine repo"
expect_pass chk6 "$REPO_ROOT" "chk6 passes on pristine repo"
expect_pass chk7 "$REPO_ROOT" "chk7 passes on pristine repo"
expect_pass chk8 "$REPO_ROOT" "chk8 passes on pristine repo"

echo "== 2. negative fixtures: each check FAILS when its invariant is broken =="

# chk1 — script missing
d="$(new_fixture)"; rm -f "$d/$SCRIPT_REL"
expect_fail chk1 "$d" "chk1 fails when szl-receipts-retention is missing"
rm -rf "$d"

# chk1 — script does not parse
d="$(new_fixture)"; printf '\nif then fi\n' >> "$d/$SCRIPT_REL"
expect_fail chk1 "$d" "chk1 fails on a syntax error (bash -n)"
rm -rf "$d"

# chk2 — remove the cluster-absent no-op (turn the exit 0 into a non-no-op)
d="$(new_fixture)"
sed -i 's/write_status UNKNOWN "cluster absent"; exit 0/write_status UNKNOWN "cluster absent"; exit 7/' "$d/$SCRIPT_REL"
expect_fail chk2 "$d" "chk2 fails when the cluster-absent path stops no-oping"
rm -rf "$d"

# chk3 — remove the VERIFY GATE (chain_ok=false no longer adds a reason -> no page)
d="$(new_fixture)"
sed -i 's/add_reason "verify-store FAILED/log "verify-store FAILED/' "$d/$SCRIPT_REL"
expect_fail chk3 "$d" "chk3 fails when the verify gate (chain_ok=false ALERT) is removed"
rm -rf "$d"

# chk4 — remove the skipped-bucket gate (skipped no longer adds a reason -> no page)
d="$(new_fixture)"
sed -i 's/add_reason "archive-shards SKIPPED/log "archive-shards SKIPPED/' "$d/$SCRIPT_REL"
expect_fail chk4 "$d" "chk4 fails when the skipped-bucket ALERT is removed"
rm -rf "$d"

# chk5 — break the benign-error allow-list so a benign no-op now pages
d="$(new_fixture)"
sed -i 's/"sharding disabled"/"NEVERMATCH_BENIGN_1"/; s/"no head pointer"/"NEVERMATCH_BENIGN_2"/' "$d/$SCRIPT_REL"
expect_fail chk5 "$d" "chk5 fails when a benign archive-shards no-op starts paging"
rm -rf "$d"

# chk6 — remove the PRUNE GATE (prune without the sha256 match -> mismatch prunes)
d="$(new_fixture)"
sed -i 's/\[ "\$want" = "\$got" \]/[ "\$want" = "\$want" ]/' "$d/$SCRIPT_REL"
expect_fail chk6 "$d" "chk6 fails when the prune gate (sha256-verify before prune) is removed"
rm -rf "$d"

# chk7 — un-wire the timer enable from install.sh
d="$(new_fixture)"
sed -i 's/systemctl enable --now szl-receipts-retention.timer/# DISABLED/' "$d/$INSTALL_REL_T"
expect_fail chk7 "$d" "chk7 fails when install.sh stops enabling the timer"
rm -rf "$d"

# chk8 — remove the retention runbook
d="$(new_fixture)"; rm -f "$d/$RUNBOOK_REL_T"
expect_fail chk8 "$d" "chk8 fails when the retention runbook is missing"
rm -rf "$d"

echo
echo "== summary: $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
