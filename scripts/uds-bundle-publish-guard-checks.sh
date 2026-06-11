# Copyright 2026 SZL Holdings
# SPDX-License-Identifier: Apache-2.0
#
# uds-bundle-publish-guard-checks.sh — guard the flaky-registry safety net in
# .github/workflows/uds-bundle-publish.yml from being silently removed.
#
# WHY THIS EXISTS
# The customer hand-off deliverable (the 5-organ UDS bundle) is built by
# uds-bundle-publish.yml. Two layers protect that build from a transient GHCR CDN
# stall on a fat organ image layer (amaru's ~363MB single layer is the worst):
#
#   1. A "Pre-warm organ image layers" step runs scripts/prewarm-ghcr-blobs.sh
#      FIRST, resumably fetching every blob of each digest-pinned organ image into
#      the Zarf cache so `zarf package create` cache-hits and skips the fragile,
#      NON-resumable pull.
#   2. A `for attempt in 1 2 3` retry wrapper around `zarf package create` so any
#      not-pre-warmed pull that still hiccups is retried with backoff instead of
#      failing the whole release.
#
# A future edit to the workflow could silently drop the pre-warm step or the retry
# loop, and we'd only discover it the next time GHCR hiccups mid-release — i.e.
# at the worst possible moment. These checks fail CI the instant either layer is
# removed.
#
# The check logic is extracted here (out of the workflow) so it can be UNIT
# TESTED: uds-bundle-publish-guard-checks.test.sh feeds each check a
# deliberately-BROKEN fixture and asserts the check FAILS (plus that the pristine
# repo PASSES). A future edit that neuters a check — making it pass vacuously,
# green while guarding nothing — is caught by that self-test, not in production.
#
# It is a pure text/lint check — no cluster, no zarf, no images, no network.
#
# Usage:
#   uds-bundle-publish-guard-checks.sh <check> [root]
#     check : chk1 | chk2 | chk3 | all
#     root  : repo root to check (default: current directory)
#
# Each check exits 0 when the invariant holds and non-zero (printing a GitHub
# ::error annotation) when it is regressed.

set -uo pipefail

# err FILE MESSAGE — emit a GitHub Actions error annotation.
err() { echo "::error file=$1::$2"; }

WORKFLOW=".github/workflows/uds-bundle-publish.yml"
PREWARM="scripts/prewarm-ghcr-blobs.sh"

# ── Check 1 ───────────────────────────────────────────────────────────────────
# scripts/prewarm-ghcr-blobs.sh exists and parses clean under `bash -n`. This is
# the resumable pre-fetch helper the pre-warm step invokes; if it is missing or
# broken the first protection layer is gone.
chk1() {
  local root="${1:-.}"
  local F="$root/$PREWARM"
  test -f "$F" || {
    err "$F" "REGRESSION — prewarm-ghcr-blobs.sh is MISSING."
    err "$F" "Without it the bundle build loses its resumable GHCR pre-fetch; a transient CDN stall would fail the release."
    return 1
  }
  local out
  if ! out="$(bash -n "$F" 2>&1)"; then
    err "$F" "REGRESSION — prewarm-ghcr-blobs.sh does not parse (bash -n failed)."
    echo "$out" | sed 's/^/       | /'
    return 1
  fi
  echo "OK: $F exists and parses clean (bash -n)"
}

# ── Check 2 ───────────────────────────────────────────────────────────────────
# uds-bundle-publish.yml still has the "Pre-warm organ image layers" step AND
# that step invokes scripts/prewarm-ghcr-blobs.sh. Either the step name being
# gone or the invocation being gone means the pre-warm protection was dropped.
chk2() {
  local root="${1:-.}"
  local F="$root/$WORKFLOW"
  test -f "$F" || { err "$F" "missing — required for the uds-bundle-publish guard"; return 1; }

  # The step name (a `- name:` line, not a comment) introducing the pre-warm step.
  grep -Eq '^[[:space:]]*-[[:space:]]*name:.*Pre-warm organ image layers' "$F" || {
    err "$F" "REGRESSION — the 'Pre-warm organ image layers' step was removed from uds-bundle-publish.yml."
    err "$F" "That step resumably warms the Zarf cache so a flaky GHCR pull can't fail the release build."
    return 1
  }

  # The actual invocation of the pre-warm helper (an executed command line, not a
  # comment) — the `chmod +x` line alone does not count.
  grep -Eq '^[[:space:]]*(\./)?scripts/prewarm-ghcr-blobs\.sh[[:space:]"]' "$F" || {
    err "$F" "REGRESSION — uds-bundle-publish.yml no longer invokes scripts/prewarm-ghcr-blobs.sh."
    err "$F" "The pre-warm step exists in name only; the resumable pre-fetch is not actually run."
    return 1
  }
  echo "OK: pre-warm step present and invokes scripts/prewarm-ghcr-blobs.sh"
}

# ── Check 3 ───────────────────────────────────────────────────────────────────
# uds-bundle-publish.yml still wraps `zarf package create` in a
# `for attempt in 1 2 3` retry loop that breaks on success. Order matters: the
# loop header must come BEFORE the command, and a `break` must come AFTER it, or
# it is not a real retry wrapper.
chk3() {
  local root="${1:-.}"
  local F="$root/$WORKFLOW"
  test -f "$F" || { err "$F" "missing — required for the uds-bundle-publish guard"; return 1; }

  local l_for l_zarf l_break
  l_for="$(grep -nE '^[[:space:]]*for attempt in 1 2 3' "$F"        | head -1 | cut -d: -f1)"
  # Match the executed command (leading whitespace then the command), NOT the
  # several comment lines that mention "zarf package create".
  l_zarf="$(grep -nE '^[[:space:]]*zarf package create' "$F"        | head -1 | cut -d: -f1)"
  l_break="$(grep -nE '^[[:space:]]*\[ "\$\{RC\}" -eq 0 \] && break' "$F" | head -1 | cut -d: -f1)"

  if [ -z "$l_zarf" ]; then
    err "$F" "REGRESSION — no executed 'zarf package create' command found in uds-bundle-publish.yml."
    return 1
  fi
  if [ -z "$l_for" ]; then
    err "$F" "REGRESSION — the 'for attempt in 1 2 3' retry wrapper around 'zarf package create' is gone."
    err "$F" "zarf image pulls are non-resumable; without the retry a single transient GHCR stall fails the release build."
    return 1
  fi
  if [ -z "$l_break" ]; then
    err "$F" "REGRESSION — the retry loop no longer breaks on success ([ \"\${RC}\" -eq 0 ] && break)."
    err "$F" "A retry loop with no success-break is not a real retry wrapper."
    return 1
  fi
  if [ "$l_for" -ge "$l_zarf" ] || [ "$l_zarf" -ge "$l_break" ]; then
    err "$F" "REGRESSION — retry structure is wrong: expected for-loop < zarf package create < success-break."
    err "$F" "Found: for@$l_for zarf@$l_zarf break@$l_break."
    return 1
  fi
  echo "OK: zarf package create is wrapped in a 'for attempt in 1 2 3' retry loop that breaks on success"
}

# ── Dispatch ──────────────────────────────────────────────────────────────────
# When sourced (BASH_SOURCE != $0) define the functions and return so the
# self-test can call them directly. When executed, run the requested check.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  CHECK="${1:-all}"
  ROOT="${2:-.}"
  case "$CHECK" in
    chk1) chk1 "$ROOT" ;;
    chk2) chk2 "$ROOT" ;;
    chk3) chk3 "$ROOT" ;;
    all)
      rc=0
      chk1 "$ROOT" || rc=1
      chk2 "$ROOT" || rc=1
      chk3 "$ROOT" || rc=1
      exit "$rc"
      ;;
    *) echo "unknown check: $CHECK (want chk1|chk2|chk3|all)" >&2; exit 2 ;;
  esac
fi
