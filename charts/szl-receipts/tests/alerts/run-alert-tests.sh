#!/usr/bin/env bash
# Copyright 2026 SZL Holdings
# SPDX-License-Identifier: Apache-2.0
#
# Verifies the in-cluster deploy-receipt stall alarm three ways:
#   1. DRIFT GUARD — re-renders charts/szl-receipts/templates/prometheusrule.yaml
#      and asserts its `.spec.groups` matches tests/alerts/rules.rendered.yaml
#      (so the unit-test fixture can't silently drift from the shipped rule).
#   2. COVERAGE GUARD — asserts every alert in the rule has at least one promtool
#      test case that proves it FIRES, so a brand-new alert can't ship untested
#      while CI stays green (the drift guard + promtool alone don't catch this).
#   3. UNIT TESTS — runs `promtool test rules` to prove each alert fires under
#      its failure condition and stays silent while the sink is healthy.
#
# Requires: helm, promtool (Prometheus), and python3 (diff + coverage guard).
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

echo "== 2. coverage guard: every alert in the rule has a firing test case =="
# promtool only runs the test cases it is given — it never flags an alert that
# has NO test. A new alert added to the rule (with rules.rendered.yaml updated
# so the drift guard passes) would otherwise ship untested while CI is green.
python3 "$HERE/check-alert-coverage.py" "$HERE/rules.rendered.yaml" "$HERE/alerts_test.yaml"

echo "== 3. promtool unit tests =="
cd "$HERE"
promtool test rules alerts_test.yaml

echo "ALL ALERT TESTS PASSED"
