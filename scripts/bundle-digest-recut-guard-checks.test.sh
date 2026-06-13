#!/usr/bin/env bash
# Copyright 2026 SZL Holdings
# SPDX-License-Identifier: Apache-2.0
#
# Self-test (negative fixtures) for bundle-digest-recut-guard-checks.sh.
#
# A guard is only worth its green check if it actually FAILS when the thing it
# guards regresses. This harness:
#   1. asserts every check PASSES against the pristine repo, then
#   2. for each check, builds a fixture with ONLY that check's invariant broken
#      and asserts the check FAILS.
# If a future edit neuters a check (so it passes even on a broken fixture), this
# self-test goes red - the guard cannot rot into a vacuous green.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
CHECKS="$HERE/bundle-digest-recut-guard-checks.sh"

# shellcheck source=/dev/null
source "$CHECKS"

SRC_FILES=(
  "box-scripts/sbin/bundle-digest-recut"
  "box-scripts/systemd/bundle-digest-recut.service"
  "box-scripts/systemd/bundle-digest-recut.timer"
  "box-scripts/install.sh"
  "box-scripts/README.md"
  "box-scripts/bundle-digest-recut.README.md"
)

PASS=0
FAIL=0
ok()   { echo "  ok: $1"; PASS=$((PASS + 1)); }
bad()  { echo "  NOT OK: $1"; FAIL=$((FAIL + 1)); }

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
expect_pass chk1 "$REPO_ROOT" "chk1 passes on pristine repo"
expect_pass chk2 "$REPO_ROOT" "chk2 passes on pristine repo"
expect_pass chk3 "$REPO_ROOT" "chk3 passes on pristine repo"
expect_pass chk4 "$REPO_ROOT" "chk4 passes on pristine repo"
expect_pass chk5 "$REPO_ROOT" "chk5 passes on pristine repo"
expect_pass chk6 "$REPO_ROOT" "chk6 passes on pristine repo"
expect_pass chk7 "$REPO_ROOT" "chk7 passes on pristine repo"
expect_pass chk8 "$REPO_ROOT" "chk8 passes on pristine repo"

echo "== 2. negative fixtures: each check FAILS when its invariant is broken =="

# chk1 - healer script missing
d="$(new_fixture)"; rm -f "$d/box-scripts/sbin/bundle-digest-recut"
expect_fail chk1 "$d" "chk1 fails when bundle-digest-recut is missing"
rm -rf "$d"

# chk1 - healer script does not parse
d="$(new_fixture)"; printf '\nif then fi\n' >> "$d/box-scripts/sbin/bundle-digest-recut"
expect_fail chk1 "$d" "chk1 fails on a syntax error (bash -n)"
rm -rf "$d"

# chk2 - drop the source-pin extraction
d="$(new_fixture)"; sed -i 's/extract_pinned_digest/DISABLED_extract/g' "$d/box-scripts/sbin/bundle-digest-recut"
expect_fail chk2 "$d" "chk2 fails when the source-pin extraction is removed"
rm -rf "$d"

# chk3 - drop the receipts-only re-cut
d="$(new_fixture)"; sed -i 's/uds create \./DISABLED_create/g' "$d/box-scripts/sbin/bundle-digest-recut"
expect_fail chk3 "$d" "chk3 fails when the 'uds create .' re-cut step is removed"
rm -rf "$d"

# chk4 - drop the post-recut verification
d="$(new_fixture)"; sed -i 's/tarball_has_digest/DISABLED_has/g' "$d/box-scripts/sbin/bundle-digest-recut"
expect_fail chk4 "$d" "chk4 fails when the post-recut verification is removed"
rm -rf "$d"

# chk5 - drop the metadata.version-unchanged invariant
d="$(new_fixture)"; sed -i 's/version_fingerprint/DISABLED_vfp/g' "$d/box-scripts/sbin/bundle-digest-recut"
expect_fail chk5 "$d" "chk5 fails when the metadata.version-unchanged guard is removed"
rm -rf "$d"

# chk6 - drop the disk pre-flight safety gate
d="$(new_fixture)"; sed -i 's/MIN_FREE_GB/DISABLED_MIN/g' "$d/box-scripts/sbin/bundle-digest-recut"
expect_fail chk6 "$d" "chk6 fails when the MIN_FREE_GB disk pre-flight is removed"
rm -rf "$d"

# chk7 - un-wire the timer enable from install.sh
d="$(new_fixture)"; sed -i 's/systemctl enable --now bundle-digest-recut.timer/# DISABLED/' "$d/box-scripts/install.sh"
expect_fail chk7 "$d" "chk7 fails when install.sh stops enabling the timer"
rm -rf "$d"

# chk8 - remove the README documentation
d="$(new_fixture)"; sed -i 's/bundle-digest-recut/DISABLED/g' "$d/box-scripts/README.md"
expect_fail chk8 "$d" "chk8 fails when README.md drops the healer's description"
rm -rf "$d"

echo
echo "== summary: $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
