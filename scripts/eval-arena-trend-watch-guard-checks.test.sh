#!/usr/bin/env bash
# Copyright 2026 SZL Holdings
# SPDX-License-Identifier: Apache-2.0
#
# Self-test (negative fixtures) for eval-arena-trend-watch-guard-checks.sh.
# Asserts the pristine repo PASSES every check, and that each check FAILS when
# ONLY its invariant is broken — so a neutered check can never rot into a vacuous
# green.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
CHECKS="$HERE/eval-arena-trend-watch-guard-checks.sh"

# shellcheck source=/dev/null
source "$CHECKS"

SRC_FILES=(
  "box-scripts/sbin/eval-arena-trend-watch"
  "box-scripts/sbin/eval-arena-trend-validate"
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

W="box-scripts/sbin/eval-arena-trend-watch"
V="box-scripts/sbin/eval-arena-trend-validate"

# chk1 — watcher missing
d="$(new_fixture)"; rm -f "$d/$W"
expect_fail chk1 "$d" "chk1 fails when eval-arena-trend-watch is missing"
rm -rf "$d"

# chk1 — bridge missing
d="$(new_fixture)"; rm -f "$d/$V"
expect_fail chk1 "$d" "chk1 fails when eval-arena-trend-validate is missing"
rm -rf "$d"

# chk1 — watcher does not parse
d="$(new_fixture)"; printf '\nif then fi\n' >> "$d/$W"
expect_fail chk1 "$d" "chk1 fails on a watcher syntax error (bash -n)"
rm -rf "$d"

# chk1 — bridge does not compile
d="$(new_fixture)"; printf '\n    def (\n' >> "$d/$V"
expect_fail chk1 "$d" "chk1 fails on a bridge syntax error (py_compile)"
rm -rf "$d"

# chk2 — stop reading the live history endpoint
d="$(new_fixture)"; sed -i 's#eval-arena/history#DISABLED#g' "$d/$W"
expect_fail chk2 "$d" "chk2 fails when it stops reading the live history endpoint"
rm -rf "$d"

# chk2 — drop the unreachable honest no-op
d="$(new_fixture)"; sed -i 's/SKIP eval-arena history unreachable/DISABLED/g' "$d/$W"
expect_fail chk2 "$d" "chk2 fails when the unreachable no-op is removed"
rm -rf "$d"

# chk3 — bridge stops importing the canonical validator
d="$(new_fixture)"; sed -i 's/from check_eval_arena_negative_control import/from DISABLED import/' "$d/$V"
expect_fail chk3 "$d" "chk3 fails when the bridge stops importing the canonical validator"
rm -rf "$d"

# chk3 — watcher stops invoking the bridge
d="$(new_fixture)"; sed -i 's/\$VALIDATE_CMD/DISABLED_CMD/g' "$d/$W"
expect_fail chk3 "$d" "chk3 fails when the watcher stops invoking the validator bridge"
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
d="$(new_fixture)"; sed -i 's/systemctl enable --now eval-arena-trend-watch.timer/# DISABLED/' "$d/box-scripts/install.sh"
expect_fail chk6 "$d" "chk6 fails when install.sh stops enabling the timer"
rm -rf "$d"

# chk7 — remove the README documentation
d="$(new_fixture)"; sed -i 's/trend strip/DISABLED strip/g' "$d/box-scripts/README.md"
expect_fail chk7 "$d" "chk7 fails when README.md drops the alarm's description"
rm -rf "$d"

echo
echo "== summary: $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
