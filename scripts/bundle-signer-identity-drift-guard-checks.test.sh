# Copyright 2026 SZL Holdings
# SPDX-License-Identifier: Apache-2.0
#
# bundle-signer-identity-drift-guard-checks.test.sh — negative-fixture self-test
# for the bundle signer-identity drift guard
# (scripts/bundle-signer-identity-drift-guard-checks.sh).
#
# WHY THIS EXISTS
# The guard enforces "the cosign signer identity the prove-bundle proof expects
# stays in lockstep with the publish workflow's path + trigger refs" entirely
# with hand-written grep/awk. If one of those checks breaks (a regex typo, a bad
# anchor) it can PASS VACUOUSLY — green while guarding nothing. This test feeds
# each check a deliberately-BROKEN fixture and asserts the check FAILS, plus
# asserts the pristine repo PASSES. A future edit that neuters a check is caught
# here in CI.
#
# It sources the EXACT script the workflow runs (so chk1..chk3 are the real
# functions) and runs them against fixtures built from the real source files.
#
# Usage: bash scripts/bundle-signer-identity-drift-guard-checks.test.sh
# Exit 0 if every case behaves as expected, 1 otherwise.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
CHECKS="$HERE/bundle-signer-identity-drift-guard-checks.sh"

# shellcheck source=/dev/null
source "$CHECKS"

PASS=0
FAIL=0
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

PUB=".github/workflows/uds-bundle-publish.yml"
PWF=".github/workflows/prove-bundle-install.yml"
TASK="tasks/prove-bundle.yaml"

# Source files the guard inspects, relative to a repo root.
SRC_FILES=(
  "$PUB"
  "$PWF"
  "$TASK"
)

# new_fixture — build a fresh fixture tree (a faithful copy of the real source
# files) under a unique dir and echo its path.
new_fixture() {
  local dir
  dir="$(mktemp -d "$TMPROOT/fixture.XXXXXX")"
  local f
  for f in "${SRC_FILES[@]}"; do
    mkdir -p "$dir/$(dirname "$f")"
    # Portable byte copy (avoids cp/copy_file_range edge cases on some overlay/
    # FUSE mounts); the guard only reads file CONTENT, mode is irrelevant.
    cat "$REPO_ROOT/$f" > "$dir/$f"
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

echo "== pristine repo: every check passes =="
expect_pass chk1 "$REPO_ROOT" "chk1 publish-workflow path is consistent + exists"
expect_pass chk2 "$REPO_ROOT" "chk2 publish trigger reality covered by prove identities"
expect_pass chk3 "$REPO_ROOT" "chk3 prove side uses exact identities + GitHub OIDC issuer"

echo "== chk1 negatives =="
# Rename the publish workflow file but DON'T update the prove-side references ->
# the path both sides pin no longer exists.
d="$(new_fixture)"; mv "$d/$PUB" "$d/.github/workflows/uds-bundle-ship.yml"
expect_fail chk1 "$d" "chk1 fails when the publish workflow is renamed without updating the prove identities"

# Prove side disagrees with itself: task pins uds-bundle-publish.yml, install WF=
# points at a different file.
d="$(new_fixture)"
sed -i 's#WF="\.github/workflows/uds-bundle-publish\.yml"#WF=".github/workflows/uds-bundle-other.yml"#' "$d/$PWF"
expect_fail chk1 "$d" "chk1 fails when CERT_IDENTITY and WF= disagree on the publish-workflow path"

# CERT_IDENTITY default no longer a this-repo publish-workflow identity.
d="$(new_fixture)"
sed -i 's#default: "https://github.com/szl-holdings/szl-uds-deployment/\.github/workflows/uds-bundle-publish\.yml@refs/heads/main"#default: "https://example.com/not/an/identity"#' "$d/$TASK"
expect_fail chk1 "$d" "chk1 fails when CERT_IDENTITY default is not a repo publish-workflow identity"

echo "== chk2 negatives =="
# Publish loses BOTH main-publishable triggers (no workflow_dispatch, tag-only) ->
# the @refs/heads/main default identity is now stale.
d="$(new_fixture)"
python3 - "$d/$PUB" <<'PY'
import sys, re
p = sys.argv[1]
s = open(p).read()
s = s.replace("""on:
  workflow_dispatch:
    inputs:
      tag:
        description: 'Bundle OCI tag (e.g. uds-v0.3.0)'
        required: true
        default: 'uds-v0.3.0'
  push:
    tags:
      - 'uds-v*'
""", """on:
  push:
    tags:
      - 'uds-v*'
""")
open(p, "w").write(s)
PY
expect_fail chk2 "$d" "chk2 fails when publish can no longer sign on refs/heads/main"

# Prove harness drops the ID_TAG identity while publish still has the tag trigger.
d="$(new_fixture)"
sed -i '/ID_TAG="https:\/\/github.com\/\${ORG}\/szl-uds-deployment\/\${WF}@refs\/tags\/\${TAG}"/d' "$d/$PWF"
expect_fail chk2 "$d" "chk2 fails when publish has a tag trigger but the harness drops the tag identity"

# Prove harness drops the ID_MAIN identity while publish still signs on main.
d="$(new_fixture)"
sed -i '/ID_MAIN="https:\/\/github.com\/\${ORG}\/szl-uds-deployment\/\${WF}@refs\/heads\/main"/d' "$d/$PWF"
expect_fail chk2 "$d" "chk2 fails when publish signs on main but the harness drops the main identity"

echo "== chk3 negatives =="
# Loose regexp identity slips into the proof.
d="$(new_fixture)"
sed -i 's/--certificate-identity=/--certificate-identity-regexp=/' "$d/$TASK"
expect_fail chk3 "$d" "chk3 fails when a loose --certificate-identity-regexp is used"

# Wrong OIDC issuer.
d="$(new_fixture)"
sed -i 's#default: "https://token.actions.githubusercontent.com"#default: "https://evil.example.com"#' "$d/$TASK"
expect_fail chk3 "$d" "chk3 fails when CERT_ISSUER is not the GitHub OIDC issuer"

# Wildcard in a pinned identity.
d="$(new_fixture)"
sed -i 's#uds-bundle-publish\.yml@refs/heads/main"#uds-bundle-publish.yml@refs/heads/*"#' "$d/$TASK"
expect_fail chk3 "$d" "chk3 fails when a pinned identity contains a '*' wildcard"

echo ""
echo "==================================================================="
echo "bundle-signer-identity-drift-guard self-test: $PASS passed, $FAIL failed"
echo "==================================================================="
[ "$FAIL" -eq 0 ]
