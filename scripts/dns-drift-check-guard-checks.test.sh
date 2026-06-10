#!/usr/bin/env bash
# Copyright 2026 SZL Holdings
# SPDX-License-Identifier: Apache-2.0
#
# Self-test (negative fixtures) for dns-drift-check-guard-checks.sh.
# Asserts the pristine repo PASSES every check, and that each check FAILS when
# ONLY its invariant is broken — so a neutered check can never rot into a vacuous
# green.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
CHECKS="$HERE/dns-drift-check-guard-checks.sh"

# shellcheck source=/dev/null
source "$CHECKS"

SRC_FILES=(
  "box-scripts/sbin/dns-drift-check"
  "box-scripts/install.sh"
  "box-scripts/README.md"
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

expect_pass() { local c="$1" r="$2" l="$3"; if "$c" "$r" >/dev/null 2>&1; then ok "$l"; else bad "$l (expected PASS, got FAIL)"; fi; }
expect_fail() { local c="$1" r="$2" l="$3"; if "$c" "$r" >/dev/null 2>&1; then bad "$l (expected FAIL, got PASS)"; else ok "$l"; fi; }

echo "== 1. pristine repo: every check PASSES =="
for c in chk1 chk2 chk3 chk4 chk5 chk6 chk7; do
  expect_pass "$c" "$REPO_ROOT" "$c passes on pristine repo"
done

echo "== 2. negative fixtures: each check FAILS when its invariant is broken =="

W="box-scripts/sbin/dns-drift-check"

# chk1 — script missing
d="$(new_fixture)"; rm -f "$d/$W"
expect_fail chk1 "$d" "chk1 fails when dns-drift-check is missing"
rm -rf "$d"

# chk1 — does not parse
d="$(new_fixture)"; printf '\nif then fi\n' >> "$d/$W"
expect_fail chk1 "$d" "chk1 fails on a syntax error (bash -n)"
rm -rf "$d"

# chk2 — stop querying an explicit public resolver
d="$(new_fixture)"; sed -i 's/@"\$RESOLVER"/DISABLED/g' "$d/$W"
expect_fail chk2 "$d" "chk2 fails when it stops using an explicit public resolver"
rm -rf "$d"

# chk3 — drop the SPF/DMARC checks
d="$(new_fixture)"; sed -i 's/EXPECT_SPF_ALL/DISABLED_SPF/g; s/EXPECT_DMARC/DISABLED_DMARC/g' "$d/$W"
expect_fail chk3 "$d" "chk3 fails when the SPF/DMARC checks are removed"
rm -rf "$d"

# chk4 — break the edge-trigger (remove the push calls)
d="$(new_fixture)"; sed -i 's/^\([[:space:]]*\)push "/\1DISABLED_push "/' "$d/$W"
expect_fail chk4 "$d" "chk4 fails when the push calls are removed"
rm -rf "$d"

# chk5 — stop writing the status file (blinds monitor-liveness)
d="$(new_fixture)"; sed -i 's/>"\$STATUS.tmp" && mv "\$STATUS.tmp" "\$STATUS"/>"\$STATUS.DISABLED"/' "$d/$W"
expect_fail chk5 "$d" "chk5 fails when the status file is no longer written atomically"
rm -rf "$d"

# chk6 — un-wire the timer enable from install.sh
d="$(new_fixture)"; sed -i 's/systemctl enable --now dns-drift-check.timer/# DISABLED/' "$d/box-scripts/install.sh"
expect_fail chk6 "$d" "chk6 fails when install.sh stops enabling the timer"
rm -rf "$d"

# chk7 — remove the README documentation
d="$(new_fixture)"; sed -i 's/PUBLIC resolver/DISABLED resolver/g' "$d/box-scripts/README.md"
expect_fail chk7 "$d" "chk7 fails when README.md drops the alarm's description"
rm -rf "$d"

echo
echo "== summary: $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
