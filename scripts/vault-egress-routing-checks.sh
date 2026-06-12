#!/usr/bin/env bash
# Copyright 2026 SZL Holdings
# SPDX-License-Identifier: Apache-2.0
#
# vault-egress-routing-checks.sh — assert the rendered szl-receipts chart routes
# Vault Transit egress to the CORRECT destination, not merely that an egress rule
# exists by name.
#
# Why this exists
# ---------------
# The Vault-custody preset guard (test.yaml: "helm template — Vault custody preset
# guard") proves the env values are correct (Task #384) and that the egress
# resources exist by name. But a name-only egress check is a false sense of
# security: a future edit to charts/szl-receipts/values-vault.yaml that points the
# Vault egress at the wrong namespace selector or wrong port (e.g. not 8200) would
# still render the `szl-receipts-allow-egress-vault` NetworkPolicy and the
# `remoteNamespace: vault` UDS rule BY NAME and pass — yet the receipts pod could
# read Vault's env values but be network-blocked from actually reaching Vault at
# runtime. This script pins the rendered egress to the committed values-vault.yaml
# overlay (port 8200, remoteNamespace vault, app.kubernetes.io/name: vault
# remoteSelector) for BOTH the Kubernetes NetworkPolicy and the UDS Package allow
# rule, so a misroute fails loudly.
#
# This logic was extracted from the inline guard step so it can be both (a) called
# by the guard on the real render and (b) self-tested against deliberately
# misrouted renders (scripts/vault-egress-routing-checks.test.sh) — the same
# negative-fixture protection the other guards in this repo already have, ensuring
# the routing check itself can never silently regress into a no-op.
#
# Usage:
#   vault-egress-routing-checks.sh <rendered-chart.yaml> [port] [namespace] [selector]
# Defaults (the committed values-vault.yaml egress posture):
#   port=8200  namespace=vault  selector="app.kubernetes.io/name: vault"
#
# Exit code: 0 = correctly routed, 1 = misrouted / missing.

# Note: deliberately NOT `set -e` — individual grep misses must accumulate into a
# single non-zero exit, not abort on the first failed assertion.
set -uo pipefail

render="${1:?usage: vault-egress-routing-checks.sh <rendered-chart.yaml> [port] [namespace] [selector]}"
exp_port="${2:-8200}"
exp_ns="${3:-vault}"
exp_selector="${4:-app.kubernetes.io/name: vault}"

if [ ! -s "$render" ]; then
  echo "  FAIL render file '$render' is missing or empty" >&2
  exit 1
fi

fail=0
assert_in() {  # $1 = label, $2 = file, $3 = grep -E pattern
  if grep -qE -- "$3" "$2"; then
    echo "  ok   $1"
  else
    echo "  FAIL $1  (missing pattern: $3)"
    fail=1
  fi
}

# The egress resources must at least exist by name before routing can be checked.
assert_in "vault egress NetworkPolicy present" "$render" 'name: szl-receipts-allow-egress-vault'
assert_in "UDS Package vault egress rule present" "$render" 'remoteNamespace: vault'

# Scope the K8s NetworkPolicy asserts to the rendered
# szl-receipts-allow-egress-vault document (from its metadata name up to the next
# YAML separator) so a stray match elsewhere in the render — e.g. another policy's
# port — cannot mask a misroute.
np_block="$(mktemp)"
awk '
  inblk && /^---/ {exit}
  /name: szl-receipts-allow-egress-vault/{inblk=1}
  inblk {print}
' "$render" > "$np_block"
assert_in "vault NetworkPolicy remoteNamespace=${exp_ns}"            "$np_block" "kubernetes.io/metadata.name: ${exp_ns}\$"
assert_in "vault NetworkPolicy remoteSelector ${exp_selector}"       "$np_block" "${exp_selector}\$"
assert_in "vault NetworkPolicy port=${exp_port}"                     "$np_block" "port: ${exp_port}\$"

# Scope the UDS Package asserts to the Vault Transit allow rule (its description
# line is unique) so the OTel / Pepr allow rules can't satisfy these. The 7 lines
# preceding the description are the full egress entry
# (direction/selector/remoteNamespace/remoteSelector/port).
uds_block="$(mktemp)"
grep -B7 -- 'description: "Vault Transit' "$render" > "$uds_block"
assert_in "UDS Package vault egress remoteNamespace=${exp_ns}"       "$uds_block" "remoteNamespace: ${exp_ns}\$"
assert_in "UDS Package vault egress remoteSelector ${exp_selector}"  "$uds_block" "${exp_selector}\$"
assert_in "UDS Package vault egress port=${exp_port}"               "$uds_block" "port: ${exp_port}\$"

rm -f "$np_block" "$uds_block"

if [ "$fail" -ne 0 ]; then
  echo "Vault egress is MISROUTED or missing (see FAIL lines above)." >&2
  exit 1
fi
echo "Vault egress routing OK (port=${exp_port}, namespace=${exp_ns}, selector='${exp_selector}')"
