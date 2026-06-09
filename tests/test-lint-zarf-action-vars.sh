#!/usr/bin/env bash
# Copyright 2026 SZL Holdings
# SPDX-License-Identifier: Apache-2.0
#
# Self-test for scripts/lint-zarf-action-vars.py.
#
# Locks in the guard's own behavior against a curated set of fixtures so that a
# future refactor of the linter cannot silently:
#   - stop detecting ###ZARF_VAR_*### inside an action cmd (false negative), or
#   - start flagging a legitimate ###ZARF_VAR_*### in files/manifests/chart
#     values (false positive).
#
# Each fixture is passed to the linter EXPLICITLY (the linter only globs
# **/zarf.yaml when given no args), and the exit code is asserted. The fixtures
# are intentionally NOT named zarf.yaml so the repo-wide no-arg CI run never
# picks them up.
#
# Run locally:  bash tests/test-lint-zarf-action-vars.sh
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
script="$repo_root/scripts/lint-zarf-action-vars.py"
fixtures="$here/fixtures/zarf-action-vars"

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

# (a) violation — template form inside an action cmd, STRING form -> FAIL (exit 1)
expect 1 "string cmd with ###ZARF_VAR_FOO### is flagged" \
  "$fixtures/fail-string-cmd.yaml"

# (a) violation — template form inside an action cmd, LIST form -> FAIL (exit 1)
expect 1 "list cmd with ###ZARF_VAR_FOO### is flagged" \
  "$fixtures/fail-list-cmd.yaml"

# (b) legit — template form in files/manifests/chart values -> PASS (exit 0)
expect 0 "legit ###ZARF_VAR_*### outside action cmd is ignored" \
  "$fixtures/pass-legit-template.yaml"

# (c) clean zarf.yaml -> PASS (exit 0)
expect 0 "clean zarf.yaml passes" \
  "$fixtures/pass-clean.yaml"

# Combined run: a clean/legit set together still passes (no cross-file leakage).
expect 0 "legit + clean together pass" \
  "$fixtures/pass-legit-template.yaml" "$fixtures/pass-clean.yaml"

# Combined run: any violation in the set fails the whole run.
expect 1 "a violation mixed with clean files still fails" \
  "$fixtures/pass-clean.yaml" "$fixtures/fail-string-cmd.yaml"

if [ "$fail" -ne 0 ]; then
  echo
  echo "SELF-TEST FAILED: the zarf action var guard is not behaving as specified."
  echo "If you intentionally changed the linter, update the fixtures/expectations."
  exit 1
fi

echo
echo "SELF-TEST OK: guard flags action-cmd violations and ignores legit template uses."
