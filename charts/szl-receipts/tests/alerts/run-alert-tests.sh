#!/usr/bin/env bash
# Copyright 2026 SZL Holdings
# SPDX-License-Identifier: Apache-2.0
#
# Verifies the in-cluster deploy-receipt stall alarm two ways:
#   1. DRIFT GUARD — re-renders charts/szl-receipts/templates/prometheusrule.yaml
#      and asserts its `.spec.groups` matches tests/alerts/rules.rendered.yaml
#      (so the unit-test fixture can't silently drift from the shipped rule).
#   2. UNIT TESTS — runs `promtool test rules` to prove each alert fires under
#      its failure condition and stays silent while the sink is healthy.
#
# Requires: helm, promtool (Prometheus), and either yq or python3 for the diff.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART="$(cd "$HERE/../.." && pwd)"      # charts/szl-receipts
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "== 1. drift guard: rendered chart .spec.groups == rules.rendered.yaml groups =="
helm template szl-receipts "$CHART" \
  --namespace szl-receipts \
  --show-only templates/prometheusrule.yaml \
  > "$TMP/cr.yaml"

# Extract `.spec.groups` from the CR and the `groups:` doc from the fixture,
# normalise both through python3, and compare.
python3 - "$TMP/cr.yaml" "$HERE/rules.rendered.yaml" <<'PY'
import sys, yaml
cr = yaml.safe_load(open(sys.argv[1]))
fixture = yaml.safe_load(open(sys.argv[2]))
got = cr["spec"]["groups"]
want = fixture["groups"]
if got != want:
    print("DRIFT: rendered chart .spec.groups != tests/alerts/rules.rendered.yaml")
    print("--- rendered ---"); print(yaml.safe_dump(got, sort_keys=False))
    print("--- fixture  ---"); print(yaml.safe_dump(want, sort_keys=False))
    sys.exit(1)
print("OK: rule groups in sync")
PY

echo "== 2. promtool unit tests =="
cd "$HERE"
promtool test rules alerts_test.yaml

echo "ALL ALERT TESTS PASSED"
