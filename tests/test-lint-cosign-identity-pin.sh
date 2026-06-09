#!/usr/bin/env bash
# Copyright 2026 SZL Holdings
# SPDX-License-Identifier: Apache-2.0
#
# Self-test for scripts/lint-cosign-identity-pin.py.
#
# Locks in the guard's behavior against curated fixtures so a future refactor of
# the linter cannot silently:
#   - stop detecting --certificate-identity-regexp on a receipts verify (false
#     negative), or
#   - start flagging a legit non-receipts regexp / the --key legacy path / prose
#     (false positive).
#
# Each fixture is passed to the linter EXPLICITLY (the linter only globs the repo
# when given no args), and the exit code is asserted. The fixtures are isolated
# under tests/fixtures/ so the repo-wide no-arg CI run never picks them up.
#
# Run locally:  bash tests/test-lint-cosign-identity-pin.sh
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
script="$repo_root/scripts/lint-cosign-identity-pin.py"
fixtures="$here/fixtures/cosign-identity-pin"

if [ ! -f "$script" ]; then
  echo "FATAL: linter not found at $script"
  exit 2
fi

fail=0

# expect <want-exit-code> <description> <file...>
expect() {
  local want="$1"; shift
  local desc="$1"; shift
  local out rc
  out="$(python3 "$script" "$@" 2>&1)"
  rc=$?
  if [ "$rc" -ne "$want" ]; then
    echo "FAIL: $desc — expected exit $want, got $rc"
    echo "$out" | sed 's/^/    /'
    fail=1
  else
    echo "PASS: $desc (exit $rc)"
  fi
}

# violations -> FAIL (exit 1)
expect 1 "receipts image verify with loose regexp is flagged" \
  "$fixtures/fail-receipts-image-regexp.md"
expect 1 "receipts package verify (single line) with loose regexp is flagged" \
  "$fixtures/fail-receipts-package-regexp.md"
expect 1 "receipts verify with no exact identity (and no --key) is flagged" \
  "$fixtures/fail-receipts-no-identity.md"

# legit -> PASS (exit 0)
expect 0 "receipts verify with exact --certificate-identity passes" \
  "$fixtures/pass-receipts-exact.md"
expect 0 "legacy --key receipts verify (identity-less by design) passes" \
  "$fixtures/pass-receipts-key.md"
expect 0 "loose regexp for a NON-receipts artifact is ignored" \
  "$fixtures/pass-other-regexp.md"
expect 0 "prose mention of the loose flag (no artifact) is ignored" \
  "$fixtures/pass-prose.md"

# combined runs
expect 0 "all legit fixtures together pass" \
  "$fixtures/pass-receipts-exact.md" "$fixtures/pass-receipts-key.md" \
  "$fixtures/pass-other-regexp.md" "$fixtures/pass-prose.md"
expect 1 "a violation mixed with legit files still fails the run" \
  "$fixtures/pass-receipts-exact.md" "$fixtures/fail-receipts-image-regexp.md"

if [ "$fail" -ne 0 ]; then
  echo
  echo "SELF-TEST FAILED: the cosign identity pin guard is not behaving as specified."
  echo "If you intentionally changed the linter, update the fixtures/expectations."
  exit 1
fi

echo
echo "SELF-TEST OK: guard flags loose/missing receipts identities and ignores legit uses."
