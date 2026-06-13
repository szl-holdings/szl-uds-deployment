# Copyright 2026 SZL Holdings
# SPDX-License-Identifier: Apache-2.0
#
# vault-key-custody-checks.test.sh — negative-fixture self-test for the Vault
# Key-Custody Gate's pass/fail logic (scripts/vault-key-custody-checks.sh).
#
# WHY THIS EXISTS
# The gate (.github/workflows/vault-key-custody-gate.yml) only runs at release
# time and against a live cluster, so a weakened assertion (drop the
# auth=kubernetes requirement, flip exportable!=false, accept backend!=vault,
# tolerate the unsigned fallback, allow the signing-key Secret) would pass
# vacuously and ship unnoticed. This test feeds each check a GOOD fixture (must
# PASS) and the BAD fixtures the gate is meant to reject (each must FAIL), with no
# cluster — pure string/JSON fixtures. It runs on every PR + push to main.
#
# It sources the EXACT script the gate runs, so the functions under test are the
# real ones. It also asserts the gate workflow is still WIRED to every subcommand,
# so the logic can't be un-extracted back inline (and re-weakened) unnoticed.
#
# Usage: bash scripts/vault-key-custody-checks.test.sh
# Exit 0 if every case behaves as expected, 1 otherwise.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
CHECKS="$HERE/vault-key-custody-checks.sh"
GATE="$REPO_ROOT/.github/workflows/vault-key-custody-gate.yml"

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

echo "== transit-key (Vault Transit key custody) =="
expect_pass transit_key '{"data":{"exportable":false,"type":"ed25519"}}' \
  "non-exportable ed25519 key passes"
# BAD case from the task: exportable=true.
expect_fail transit_key '{"data":{"exportable":true,"type":"ed25519"}}' \
  "exportable=true fails (private key could leave Vault)"
expect_fail transit_key '{"data":{"exportable":false,"type":"rsa-2048"}}' \
  "non-ed25519 key type fails"
expect_fail transit_key '{"data":{"type":"ed25519"}}' \
  "missing exportable field fails (null != false)"

echo "== signer-log (Vault signing engaged, not the unsigned fallback) =="
expect_pass signer_log \
  '[boot] starting
[vault] Transit signer ready; addr=http://vault.vault:8200 key=transit/szl-receipts keyid=abcd auth=kubernetes pub=MCowBQ' \
  "ready via auth=kubernetes passes"
expect_pass signer_log \
  '[vault] running unsigned (Vault unreachable), will retry
[vault] Transit signer ready; addr=http://vault.vault:8200 key=transit/szl-receipts keyid=abcd auth=kubernetes pub=MCowBQ' \
  "transient unsigned at boot then recovery passes (latest state ready)"
# BAD case from the task: auth=token (static token would defeat Tier-2 custody).
expect_fail signer_log \
  '[vault] Transit signer ready; addr=http://vault.vault:8200 key=transit/szl-receipts keyid=abcd auth=token pub=MCowBQ' \
  "auth=token fails (not Kubernetes ServiceAccount auth)"
# BAD case from the task: unsigned fallback is the most recent state.
expect_fail signer_log \
  '[vault] Transit signer ready; addr=http://vault.vault:8200 key=transit/szl-receipts keyid=abcd auth=kubernetes pub=MCowBQ
[vault] running unsigned (Vault became unreachable)' \
  "ready then later unsigned fails (latest state UNSIGNED)"
expect_fail signer_log \
  '[boot] starting
[boot] serving on :8080' \
  "no Vault signer line at all fails"

echo "== no-key-secret (no Ed25519 signing-key Secret in the cluster) =="
expect_pass no_key_secret '' \
  "absent Secret (empty kubectl output) passes"
expect_pass no_key_secret '
' \
  "whitespace-only kubectl output passes"
# BAD case from the task: the szl-receipts-ed25519 Secret is present.
expect_fail no_key_secret 'secret/szl-receipts-ed25519' \
  "present szl-receipts-ed25519 Secret fails"

echo "== pubkey (signed + backend=vault) =="
expect_pass pubkey '{"signed":true,"backend":"vault","pubkey":"MCowBQ"}' \
  "signed=true backend=vault passes"
# BAD case from the task: backend is not vault.
expect_fail pubkey '{"signed":true,"backend":"file","pubkey":"MCowBQ"}' \
  "backend=file fails (silent downgrade)"
expect_fail pubkey '{"signed":false,"backend":"vault"}' \
  "signed=false fails (unsigned fallback)"

echo "== receipt (issued receipt verifies) =="
expect_pass receipt '{"valid":true,"index":1}' \
  "valid=true passes"
expect_fail receipt '{"valid":false}' \
  "valid=false fails"

echo "== gate wiring (the gate must still call every protected subcommand) =="
check_wiring() {
  local sub="$1"
  if grep -qE "vault-key-custody-checks\.sh ${sub}\b" "$GATE"; then
    echo "ok   wiring: gate calls vault-key-custody-checks.sh $sub"
    PASS=$((PASS+1))
  else
    echo "FAIL wiring: gate no longer calls vault-key-custody-checks.sh $sub"
    echo "       | (the gate's pass/fail logic was un-extracted from the tested script)"
    FAIL=$((FAIL+1))
  fi
}
if [ -f "$GATE" ]; then
  for sub in transit-key signer-log no-key-secret pubkey receipt; do
    check_wiring "$sub"
  done
else
  echo "FAIL wiring: gate workflow not found at $GATE"
  FAIL=$((FAIL+1))
fi

echo ""
echo "==================================================================="
echo "vault-key-custody self-test: $PASS passed, $FAIL failed"
echo "==================================================================="
[ "$FAIL" -eq 0 ]
