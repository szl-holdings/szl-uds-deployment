# Copyright 2026 SZL Holdings
# SPDX-License-Identifier: Apache-2.0
#
# uds-bundle-publish-guard-checks.test.sh — negative-fixture self-test for the
# uds-bundle-publish guard (scripts/uds-bundle-publish-guard-checks.sh).
#
# WHY THIS EXISTS
# The guard enforces the flaky-registry safety net (pre-warm step + zarf retry
# loop) entirely with hand-written grep. If one of those checks breaks (a regex
# typo, a bad anchor) it can PASS VACUOUSLY — green while guarding nothing. This
# test feeds each check a deliberately-BROKEN fixture and asserts the check
# FAILS, plus asserts the pristine repo PASSES. A future edit that neuters a
# check is caught here in CI.
#
# It sources the EXACT script the workflow runs (so chk1..chk3 are the real
# functions) and runs them against fixtures built from the real source files.
#
# Usage: bash scripts/uds-bundle-publish-guard-checks.test.sh
# Exit 0 if every case behaves as expected, 1 otherwise.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
CHECKS="$HERE/uds-bundle-publish-guard-checks.sh"

# shellcheck source=/dev/null
source "$CHECKS"

PASS=0
FAIL=0
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

# Source files the guard inspects, relative to a repo root.
SRC_FILES=(
  ".github/workflows/uds-bundle-publish.yml"
  "scripts/prewarm-ghcr-blobs.sh"
)

# new_fixture — build a fresh fixture tree (a faithful copy of the real source
# files) under a unique dir and echo its path.
new_fixture() {
  local dir
  dir="$(mktemp -d "$TMPROOT/fixture.XXXXXX")"
  local f
  for f in "${SRC_FILES[@]}"; do
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
    echo "ok   FAIL-expected: $name"
    PASS=$((PASS+1))
  else
    echo "FAIL FAIL-expected but $check exited 0: $name"
    echo "$out" | sed 's/^/       | /'
    FAIL=$((FAIL+1))
  fi
}

WF=".github/workflows/uds-bundle-publish.yml"

echo "== pristine repo: every check passes =="
expect_pass chk1 "$REPO_ROOT" "chk1 prewarm-ghcr-blobs.sh present + parses"
expect_pass chk2 "$REPO_ROOT" "chk2 pre-warm step present + invokes the helper"
expect_pass chk3 "$REPO_ROOT" "chk3 zarf package create wrapped in retry loop"

echo "== chk1 negatives =="
d="$(new_fixture)"; rm -f "$d/scripts/prewarm-ghcr-blobs.sh"
expect_fail chk1 "$d" "chk1 fails when prewarm-ghcr-blobs.sh is missing"

d="$(new_fixture)"; printf 'if [ \n' > "$d/scripts/prewarm-ghcr-blobs.sh"
expect_fail chk1 "$d" "chk1 fails when prewarm-ghcr-blobs.sh has a syntax error"

echo "== chk2 negatives =="
# Remove the pre-warm STEP entirely (its `- name:` line) -> step is gone.
d="$(new_fixture)"; sed -i '/^[[:space:]]*-[[:space:]]*name:.*Pre-warm organ image layers/d' "$d/$WF"
expect_fail chk2 "$d" "chk2 fails when the 'Pre-warm organ image layers' step is removed"

# Keep the step name but drop the actual invocation of the helper -> step in name
# only (the chmod line must NOT be enough to satisfy the check).
d="$(new_fixture)"
sed -i '/^[[:space:]]*\(\.\/\)\?scripts\/prewarm-ghcr-blobs\.sh[[:space:]"]/d' "$d/$WF"
expect_fail chk2 "$d" "chk2 fails when the prewarm-ghcr-blobs.sh invocation is dropped"

echo "== chk3 negatives =="
# Remove the retry loop header -> bare zarf package create with no retry.
d="$(new_fixture)"; sed -i '/^[[:space:]]*for attempt in 1 2 3/d' "$d/$WF"
expect_fail chk3 "$d" "chk3 fails when the 'for attempt in 1 2 3' loop header is removed"

# Remove the success-break -> loop with no break is not a real retry wrapper.
d="$(new_fixture)"; sed -i '/^[[:space:]]*\[ "${RC}" -eq 0 \] && break/d' "$d/$WF"
expect_fail chk3 "$d" "chk3 fails when the success-break is removed"

# Remove the executed zarf package create command -> nothing to wrap.
d="$(new_fixture)"; sed -i '/^[[:space:]]*zarf package create/d' "$d/$WF"
expect_fail chk3 "$d" "chk3 fails when the zarf package create command is gone"

echo ""
echo "==================================================================="
echo "uds-bundle-publish-guard self-test: $PASS passed, $FAIL failed"
echo "==================================================================="
[ "$FAIL" -eq 0 ]
