# Copyright 2026 SZL Holdings
# SPDX-License-Identifier: Apache-2.0
#
# file-key-custody-checks.test.sh — negative-fixture self-test for the File
# (SealedSecret) Key-Custody Gate's pass/fail logic (scripts/file-key-custody-checks.sh).
#
# WHY THIS EXISTS
# The gate (.github/workflows/file-key-custody-gate.yml) only runs at release time
# and against a live cluster, so a weakened assertion (tolerate a missing
# SealedSecret CR, accept the unsigned fallback, allow backend!=file, ignore an
# unmaterialised key Secret) would pass vacuously and ship unnoticed. This test
# feeds each check a GOOD fixture (must PASS) and the BAD fixtures the gate is meant
# to reject (each must FAIL), with no cluster — pure string/JSON fixtures. It runs
# on every PR + push to main.
#
# It sources the EXACT script the gate runs, so the functions under test are the
# real ones. It also asserts the gate workflow is still WIRED to every subcommand,
# so the logic can't be un-extracted back inline (and re-weakened) unnoticed.
#
# Usage: bash scripts/file-key-custody-checks.test.sh
# Exit 0 if every case behaves as expected, 1 otherwise.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
CHECKS="$HERE/file-key-custody-checks.sh"
GATE="$REPO_ROOT/.github/workflows/file-key-custody-gate.yml"

# shellcheck source=/dev/null
source "$CHECKS"

PASS=0
FAIL=0

# expect_pass FN FIXTURE NAME — assert FN returns 0 on FIXTURE (read via stdin).
expect_pass() {
  local fn="$1" fixture="$2" name="$3" out rc
  out="$(printf '%s' "$fixture" | "$fn" 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ]; then
    echo "ok   PASS-expected: $name"
    PASS=$((PASS+1))
  else
    echo "FAIL PASS-expected but $fn exited $rc: $name"
    echo "$out" | sed 's/^/       | /'
    FAIL=$((FAIL+1))
  fi
}

# expect_fail FN FIXTURE NAME — assert FN returns non-zero on FIXTURE.
expect_fail() {
  local fn="$1" fixture="$2" name="$3" out rc
  out="$(printf '%s' "$fixture" | "$fn" 2>&1)"; rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "ok   FAIL-expected: $name"
    PASS=$((PASS+1))
  else
    echo "FAIL FAIL-expected but $fn exited 0: $name"
    echo "$out" | sed 's/^/       | /'
    FAIL=$((FAIL+1))
  fi
}

echo "== sealed-secret (encrypted-at-rest SealedSecret CR deployed) =="
expect_pass sealed_secret 'sealedsecret.bitnami.com/szl-receipts-ed25519' \
  "present SealedSecret passes"
# BAD case: no SealedSecret CR -> Tier-1 custody not actually shipped.
expect_fail sealed_secret '' \
  "absent SealedSecret fails (custody CR not deployed)"
expect_fail sealed_secret '
' \
  "whitespace-only output fails"

echo "== key-secret (decrypted Ed25519 Secret materialised by the controller) =="
expect_pass key_secret 'secret/szl-receipts-ed25519' \
  "materialised key Secret passes"
# BAD case: the sealed-secrets controller never produced the Secret.
expect_fail key_secret '' \
  "absent key Secret fails (SealedSecret round-trip did not complete)"

echo "== signer-log (file key loaded, not the unsigned fallback) =="
expect_pass signer_log \
  '[boot] starting
[file] Ed25519 signing key loaded; keyid=szl-receipts-ed25519-2026 pub=abcd' \
  "key loaded passes"
expect_pass signer_log \
  'Ed25519 key not found at /run/secrets/szl-receipts/ed25519.pem; running unsigned
[file] Ed25519 signing key loaded; keyid=szl-receipts-ed25519-2026 pub=abcd' \
  "transient unsigned at boot then load passes (latest state loaded)"
# BAD case: unsigned fallback is the most recent state.
expect_fail signer_log \
  '[file] Ed25519 signing key loaded; keyid=szl-receipts-ed25519-2026 pub=abcd
Ed25519 key not found at /run/secrets/szl-receipts/ed25519.pem; running unsigned' \
  "loaded then later unsigned fails (latest state UNSIGNED)"
# BAD case: no file-key load line at all.
expect_fail signer_log \
  '[boot] starting
[boot] serving on :8080' \
  "no file signer line at all fails"

echo "== pubkey (signed + backend=file) =="
expect_pass pubkey '{"signed":true,"backend":"file","pubkey":"MCowBQ"}' \
  "signed=true backend=file passes"
# BAD case: backend is not file (e.g. an accidentally-vault deploy).
expect_fail pubkey '{"signed":true,"backend":"vault","pubkey":"MCowBQ"}' \
  "backend=vault fails (wrong backend for the file gate)"
expect_fail pubkey '{"signed":false,"backend":"file"}' \
  "signed=false fails (unsigned fallback)"

echo "== receipt (issued receipt verifies) =="
expect_pass receipt '{"valid":true,"index":1}' \
  "valid=true passes"
expect_fail receipt '{"valid":false}' \
  "valid=false fails"

echo "== gate wiring (the gate must still call every protected subcommand) =="
check_wiring() {
  local sub="$1"
  if grep -qE "file-key-custody-checks\.sh ${sub}\b" "$GATE"; then
    echo "ok   wiring: gate calls file-key-custody-checks.sh $sub"
    PASS=$((PASS+1))
  else
    echo "FAIL wiring: gate no longer calls file-key-custody-checks.sh $sub"
    echo "       | (the gate's pass/fail logic was un-extracted from the tested script)"
    FAIL=$((FAIL+1))
  fi
}
if [ -f "$GATE" ]; then
  for sub in sealed-secret key-secret signer-log pubkey receipt; do
    check_wiring "$sub"
  done
else
  echo "FAIL wiring: gate workflow not found at $GATE"
  FAIL=$((FAIL+1))
fi

echo ""
echo "==================================================================="
echo "file-key-custody self-test: $PASS passed, $FAIL failed"
echo "==================================================================="
[ "$FAIL" -eq 0 ]
