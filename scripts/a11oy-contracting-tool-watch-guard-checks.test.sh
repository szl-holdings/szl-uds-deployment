#!/usr/bin/env bash
# Copyright 2026 SZL Holdings
# SPDX-License-Identifier: Apache-2.0
#
# Self-test (negative fixtures) for a11oy-contracting-tool-watch-guard-checks.sh.
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
CHECKS="$HERE/a11oy-contracting-tool-watch-guard-checks.sh"

# Source the checks so we can call chkN directly against a fixture root.
# shellcheck source=/dev/null
source "$CHECKS"

# Files the guard inspects (relative to a repo root).
SRC_FILES=(
  "box-scripts/sbin/a11oy-contracting-tool-watch"
  "box-scripts/install.sh"
  "box-scripts/README.md"
)

PASS=0
FAIL=0
ok()   { echo "  ok: $1"; PASS=$((PASS + 1)); }
bad()  { echo "  NOT OK: $1"; FAIL=$((FAIL + 1)); }

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
expect_pass chk9 "$REPO_ROOT" "chk9 passes on pristine repo"

echo "== 2. negative fixtures: each check FAILS when its invariant is broken =="

# chk1 — script missing
d="$(new_fixture)"; rm -f "$d/box-scripts/sbin/a11oy-contracting-tool-watch"
expect_fail chk1 "$d" "chk1 fails when a11oy-contracting-tool-watch is missing"
rm -rf "$d"

# chk1 — script does not parse
d="$(new_fixture)"; printf '\nif then fi\n' >> "$d/box-scripts/sbin/a11oy-contracting-tool-watch"
expect_fail chk1 "$d" "chk1 fails on a syntax error (bash -n)"
rm -rf "$d"

# chk2 — drop the a11oy endpoint probe
d="$(new_fixture)"; sed -i 's|a-11-oy.com/api/a11oy/v1/contracting|DISABLED/contracting|g' "$d/box-scripts/sbin/a11oy-contracting-tool-watch"
expect_fail chk2 "$d" "chk2 fails when a flagship endpoint is no longer probed"
rm -rf "$d"

# chk2 — drop the envelope validation (areas list)
d="$(new_fixture)"; sed -i 's/"areas"/"DISABLED_areas"/g' "$d/box-scripts/sbin/a11oy-contracting-tool-watch"
expect_fail chk2 "$d" "chk2 fails when the areas[] envelope check is removed"
rm -rf "$d"

# chk3 — drop the baked-image read
d="$(new_fixture)"; sed -i 's/docker run --rm --entrypoint cat/docker run DISABLED cat/g' "$d/box-scripts/sbin/a11oy-contracting-tool-watch"
expect_fail chk3 "$d" "chk3 fails when the baked-image module read is removed"
rm -rf "$d"

# chk4 — drop the empty-file md5 refusal
d="$(new_fixture)"; sed -i 's/EMPTY_MD5=/EMPTY_DISABLED=/g' "$d/box-scripts/sbin/a11oy-contracting-tool-watch"
expect_fail chk4 "$d" "chk4 fails when the empty-file md5 refusal is removed"
rm -rf "$d"

# chk5 — drop the committed-source comparison
d="$(new_fixture)"; sed -i 's|origin/main:|DISABLED:|g' "$d/box-scripts/sbin/a11oy-contracting-tool-watch"
expect_fail chk5 "$d" "chk5 fails when the origin/main comparison is removed"
rm -rf "$d"

# chk6 — break the edge-trigger (remove the notify calls)
d="$(new_fixture)"; sed -i 's/^\([[:space:]]*\)notify "/\1DISABLED_notify "/' "$d/box-scripts/sbin/a11oy-contracting-tool-watch"
expect_fail chk6 "$d" "chk6 fails when the notify calls are removed (no per-edge paging)"
rm -rf "$d"

# chk7 — remove the image-absent no-op marker
d="$(new_fixture)"; sed -i 's/skipping integrity leg/DISABLED leg/g' "$d/box-scripts/sbin/a11oy-contracting-tool-watch"
expect_fail chk7 "$d" "chk7 fails when the image-absent no-op is removed (mid-rebuild would page)"
rm -rf "$d"

# chk8 — un-wire the timer enable from install.sh
d="$(new_fixture)"; sed -i 's/systemctl enable --now a11oy-contracting-tool-watch.timer/# DISABLED/' "$d/box-scripts/install.sh"
expect_fail chk8 "$d" "chk8 fails when install.sh stops enabling the timer"
rm -rf "$d"

# chk9 — remove the README documentation
d="$(new_fixture)"; sed -i 's/a11oy-contracting-tool-watch/DISABLED/g' "$d/box-scripts/README.md"
expect_fail chk9 "$d" "chk9 fails when README.md drops the proof's description"
rm -rf "$d"

echo
echo "== summary: $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
