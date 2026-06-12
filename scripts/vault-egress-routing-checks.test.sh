#!/usr/bin/env bash
# Copyright 2026 SZL Holdings
# SPDX-License-Identifier: Apache-2.0
#
# vault-egress-routing-checks.test.sh — negative-fixture self-test for
# scripts/vault-egress-routing-checks.sh.
#
# Proves the Vault egress routing guard ACTUALLY catches a misroute and cannot
# silently regress into a no-op. It renders the committed Vault-custody overlay
# (charts/szl-receipts/values-vault.yaml) and:
#   1. asserts a CORRECT render is ACCEPTED (exit 0), and
#   2. for each routing dimension (port, namespace, remoteSelector), renders a
#      deliberately misrouted chart via `helm --set` and asserts the guard
#      REJECTS it (exit non-zero).
# If the routing check were ever neutered into a no-op, the misroute cases would
# pass and this self-test would go red — the same protection the other guards in
# this repo carry (teardown-guard, zarf-action-var-guard, ...).
#
# Requires: helm (installed in the test.yaml lint job).
# Run from the repo root.

set -uo pipefail

chart=charts/szl-receipts
values=$chart/values.yaml
overlay=$chart/values-vault.yaml
check=scripts/vault-egress-routing-checks.sh

if ! command -v helm >/dev/null 2>&1; then
  echo "FATAL: helm is required to run this self-test" >&2
  exit 2
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

render() {  # extra helm --set args... -> writes render to $tmp/$1.yaml
  local name="$1"; shift
  helm template test-release "$chart/" -f "$values" -f "$overlay" "$@" > "$tmp/$name.yaml"
}

fail=0

# $1 = label, $2 = expected outcome (pass|fail), $3 = render file
expect() {
  local label="$1" want="$2" file="$3"
  if bash "$check" "$file" >/dev/null 2>&1; then
    got=pass
  else
    got=fail
  fi
  if [ "$got" = "$want" ]; then
    echo "  ok   [$want] $label"
  else
    echo "  SELF-TEST FAIL: $label — guard returned '$got', expected '$want'"
    echo "  ---- guard output ----"
    bash "$check" "$file" 2>&1 | sed 's/^/    /'
    echo "  ----------------------"
    fail=1
  fi
}

echo "== Vault egress routing guard self-test =="

# 1. The committed (correct) overlay must be ACCEPTED.
render correct
expect "correct committed overlay" pass "$tmp/correct.yaml"

# 2. Wrong port (e.g. 8201 instead of 8200) must be REJECTED.
render wrong-port --set signing.vault.egress.port=8201
expect "misrouted port 8201" fail "$tmp/wrong-port.yaml"

# 3. Wrong remoteNamespace (monitoring instead of vault) must be REJECTED.
render wrong-ns --set signing.vault.egress.remoteNamespace=monitoring
expect "misrouted namespace 'monitoring'" fail "$tmp/wrong-ns.yaml"

# 4. Wrong remoteSelector value must be REJECTED.
render wrong-selector --set 'signing.vault.egress.remoteSelector.app\.kubernetes\.io/name=monitoring'
expect "misrouted remoteSelector value" fail "$tmp/wrong-selector.yaml"

# 5. Combined port + namespace misroute (the canonical misroute) must be REJECTED.
render wrong-both --set signing.vault.egress.port=8201 --set signing.vault.egress.remoteNamespace=monitoring
expect "misrouted port + namespace" fail "$tmp/wrong-both.yaml"

if [ "$fail" -ne 0 ]; then
  echo "Vault egress routing guard SELF-TEST FAILED — the guard is not catching misroutes." >&2
  exit 1
fi
echo "Vault egress routing guard self-test PASSED (correct accepted, all misroutes rejected)."
