# Copyright 2026 SZL Holdings
# SPDX-License-Identifier: Apache-2.0
#
# istiod-fit-strategy-e2e-guard.sh — drive the REAL istiod-fit-strategy self-heal
# watcher end-to-end against a fake cluster and assert its repair behaviour.
#
# WHY THIS EXISTS
# box-scripts/sbin/istiod-fit-strategy keeps istiod fittable on the 2-vCPU
# uds-szl-demo node so a control-plane upgrade or an autoscale event never strands
# a permanently Pending istiod. It is a SELF-HEALING patcher with two independent
# repairs:
#   * rolling-update strategy: if istiod's maxSurge != 0, patch it to
#     maxSurge=0/maxUnavailable=1 so the single-replica istiod terminates-then-
#     recreates within the node's CPU headroom;
#   * HPA scale-up: if the istiod HPA maxReplicas != 1, clamp min/max to 1 so the
#     autoscaler can never request a 2nd istiod the node can't fit.
# Each repair is idempotent (no API write once conformant) and skipped if its
# target is absent; the whole script no-ops when the cluster is absent. None of
# this has a visible symptom when broken until a real upgrade hangs. This guard
# RUNS the real script against fake k3d/kubectl (no cluster, no root) and asserts
# it patches exactly what it should and nothing else.
#
# Usage: bash scripts/istiod-fit-strategy-e2e-guard.sh [path-to-istiod-fit-strategy]
#   The negative-fixture self-test points it at deliberately-broken copies.
# Exit 0 if every assertion holds, 1 otherwise.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
SCRIPT="${1:-$REPO_ROOT/box-scripts/sbin/istiod-fit-strategy}"
# shellcheck source=scripts/lib/box-watch-stubs.sh
. "$HERE/lib/box-watch-stubs.sh"

if [ ! -r "$SCRIPT" ]; then
  echo "FATAL istiod-fit-strategy script not found/readable: $SCRIPT" >&2
  exit 1
fi

PASS=0; FAIL=0
ok()  { echo "ok   $*"; PASS=$((PASS+1)); }
bad() { echo "FAIL $*"; FAIL=$((FAIL+1)); }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
BIN="$T/bin"; CTRL="$T/ctrl"
mkdir -p "$BIN" "$CTRL"
make_k8s_stubs "$BIN"

run() {
  : > "$CTRL/patches"
  env PATH="$BIN:$PATH" STUB_CTRL="$CTRL" bash "$SCRIPT" >/dev/null 2>&1
}
patched_res()    { grep -q "$1" "$CTRL/patches"; }
patch_count()    { local c; c="$(grep -c . "$CTRL/patches" 2>/dev/null)"; echo "${c:-0}"; }

reset_ctrl() {
  rm -f "$CTRL"/* 2>/dev/null
  : > "$CTRL/kubeconfig"
  echo 0 > "$CTRL/readyz_rc"
}

echo "== Phase A: cluster absent -> no patch at all =="
reset_ctrl; : > "$CTRL/k3d_absent"
run
if [ "$(patch_count)" -eq 0 ]; then ok "A1 cluster-absent is a no-op"; else bad "A1 patched with cluster absent"; fi

echo "== Phase B: drifted istiod (surge=100%) + drifted HPA (maxReplicas=5) -> both patched =="
reset_ctrl
: > "$CTRL/deploy_istio-system_istiod_present"; printf '100%%' > "$CTRL/deploy_istio-system_istiod_surge"
: > "$CTRL/hpa_istio-system_istiod_present";    printf '5'     > "$CTRL/hpa_istio-system_istiod_maxr"
run
if patched_res "istio-system/deploy/istiod"; then ok "B1 drifted istiod strategy is patched"; else bad "B1 drifted istiod strategy NOT patched"; fi
if patched_res "istio-system/hpa/istiod"; then ok "B2 drifted istiod HPA is patched"; else bad "B2 drifted istiod HPA NOT patched"; fi

echo "== Phase C: already conformant (surge=0, maxReplicas=1) -> no patch =="
reset_ctrl
: > "$CTRL/deploy_istio-system_istiod_present"; printf '0' > "$CTRL/deploy_istio-system_istiod_surge"
: > "$CTRL/hpa_istio-system_istiod_present";    printf '1' > "$CTRL/hpa_istio-system_istiod_maxr"
run
if [ "$(patch_count)" -eq 0 ]; then ok "C1 conformant strategy+HPA -> idempotent no-op"; else bad "C1 patched an already-conformant target"; fi

echo "== Phase D: only the strategy drifted; HPA conformant -> deploy patched, HPA not =="
reset_ctrl
: > "$CTRL/deploy_istio-system_istiod_present"; printf '25%%' > "$CTRL/deploy_istio-system_istiod_surge"
: > "$CTRL/hpa_istio-system_istiod_present";    printf '1'    > "$CTRL/hpa_istio-system_istiod_maxr"
run
if patched_res "istio-system/deploy/istiod"; then ok "D1 drifted strategy patched"; else bad "D1 drifted strategy NOT patched"; fi
if ! patched_res "istio-system/hpa/istiod"; then ok "D2 conformant HPA left untouched"; else bad "D2 patched a conformant HPA"; fi

echo "== Phase E: targets absent -> nothing patched (no spurious writes) =="
reset_ctrl
run
if [ "$(patch_count)" -eq 0 ]; then ok "E1 absent deploy+HPA -> no patch"; else bad "E1 patched an absent target"; fi

echo ""
echo "==================================================================="
echo "istiod-fit-strategy e2e guard: $PASS passed, $FAIL failed"
echo "==================================================================="
[ "$FAIL" -eq 0 ]
