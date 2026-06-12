# Copyright 2026 SZL Holdings
# SPDX-License-Identifier: Apache-2.0
#
# szl-core-rightsize-e2e-guard.sh — drive the REAL szl-core-rightsize self-heal
# watcher end-to-end against a fake cluster and assert its repair behaviour.
#
# WHY THIS EXISTS
# box-scripts/sbin/szl-core-rightsize keeps the shared UDS-core admission
# components single-replica + no-surge on the 2-vCPU uds-szl-demo node so a core
# redeploy never strands szl-receipts in Pending. It is a SELF-HEALING patcher:
#   * on the drift edge it `kubectl patch`es each target Deployment back to
#     replicas=1 (+ maxSurge=0/maxUnavailable=1 for RollingUpdate targets);
#   * it is a TRUE no-op once every target already conforms (no API writes);
#   * it skips a target that is absent (e.g. zarf/agent-hook before zarf install);
#   * it no-ops entirely when the cluster is absent or unreachable.
# All four behaviours produce NO visible symptom when broken until a real core
# redeploy quietly strands a pod — the only prior coverage was a static grep.
# This guard RUNS the real script against fake k3d/kubectl (no cluster, no root,
# host untouched) and asserts it patches exactly what it should and nothing else.
#
# Usage: bash scripts/szl-core-rightsize-e2e-guard.sh [path-to-szl-core-rightsize]
#   The negative-fixture self-test points it at deliberately-broken copies.
# Exit 0 if every assertion holds, 1 otherwise.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
SCRIPT="${1:-$REPO_ROOT/box-scripts/sbin/szl-core-rightsize}"
# shellcheck source=scripts/lib/box-watch-stubs.sh
. "$HERE/lib/box-watch-stubs.sh"

if [ ! -r "$SCRIPT" ]; then
  echo "FATAL szl-core-rightsize script not found/readable: $SCRIPT" >&2
  exit 1
fi

PASS=0; FAIL=0
ok()  { echo "ok   $*"; PASS=$((PASS+1)); }
bad() { echo "FAIL $*"; FAIL=$((FAIL+1)); }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
BIN="$T/bin"; CTRL="$T/ctrl"
mkdir -p "$BIN" "$CTRL"
make_k8s_stubs "$BIN"

# run — drive the real watcher with the fake cluster on PATH. The patches ledger
# is truncated first so each phase's patches are isolated.
run() {
  : > "$CTRL/patches"
  env PATH="$BIN:$PATH" STUB_CTRL="$CTRL" bash "$SCRIPT" >/dev/null 2>&1
}
patched()     { grep -q "$1" "$CTRL/patches"; }
patch_count() { local c; c="$(grep -c . "$CTRL/patches" 2>/dev/null)"; echo "${c:-0}"; }

# Reset all control files to "no targets exist" + reachable cluster.
reset_ctrl() {
  rm -f "$CTRL"/* 2>/dev/null
  : > "$CTRL/kubeconfig"
  echo 0 > "$CTRL/readyz_rc"
}

# Declare a target deploy present with given replicas / strategy type / surge.
mk_deploy() { # ns name replicas stype surge
  : > "$CTRL/deploy_$1_$2_present"
  printf '%s' "$3" > "$CTRL/deploy_$1_$2_replicas"
  printf '%s' "$4" > "$CTRL/deploy_$1_$2_stype"
  printf '%s' "$5" > "$CTRL/deploy_$1_$2_surge"
}

echo "== Phase A: cluster absent -> no patch at all =="
reset_ctrl; : > "$CTRL/k3d_absent"
run
if [ "$(patch_count)" -eq 0 ]; then ok "A1 cluster-absent is a no-op (no patch)"; else bad "A1 patched with cluster absent"; fi

echo "== Phase B: cluster reachable, no targets present -> no patch =="
reset_ctrl
run
if [ "$(patch_count)" -eq 0 ]; then ok "B1 no targets present -> no patch"; else bad "B1 patched a non-existent target"; fi

echo "== Phase C: a RollingUpdate target drifted (replicas=2, surge=25%) -> patched =="
reset_ctrl
mk_deploy pepr-system pepr-uds-core 2 RollingUpdate 25%
run
if patched "pepr-system/.*pepr-uds-core"; then ok "C1 drifted RollingUpdate target is patched"; else bad "C1 drifted target NOT patched"; fi

echo "== Phase D: every target already conformant (replicas=1, surge=0) -> no patch =="
reset_ctrl
mk_deploy pepr-system pepr-uds-core 1 RollingUpdate 0
mk_deploy pepr-system pepr-szl       1 RollingUpdate 0
run
if [ "$(patch_count)" -eq 0 ]; then ok "D1 conformant targets -> idempotent no-op"; else bad "D1 patched an already-conformant target"; fi

echo "== Phase E: Recreate-strategy target =="
reset_ctrl
mk_deploy zarf agent-hook 2 Recreate ""
run
if patched "zarf/.*agent-hook"; then ok "E1 Recreate target with replicas=2 is pinned to 1"; else bad "E1 over-replica Recreate target NOT patched"; fi
reset_ctrl
mk_deploy zarf agent-hook 1 Recreate ""
run
if [ "$(patch_count)" -eq 0 ]; then ok "E2 Recreate target already at replicas=1 -> no patch"; else bad "E2 patched a conformant Recreate target"; fi

echo "== Phase F: an absent target among present ones is skipped (not patched) =="
reset_ctrl
# pepr-uds-core conformant; pepr-szl drifted; agent-hook absent.
mk_deploy pepr-system pepr-uds-core 1 RollingUpdate 0
mk_deploy pepr-system pepr-szl       2 RollingUpdate 25%
run
if patched "pepr-system/.*pepr-szl"; then ok "F1 the drifted present target is patched"; else bad "F1 drifted present target NOT patched"; fi
if ! patched "zarf/.*agent-hook"; then ok "F2 the absent target is skipped (not patched)"; else bad "F2 patched an absent target"; fi

echo ""
echo "==================================================================="
echo "szl-core-rightsize e2e guard: $PASS passed, $FAIL failed"
echo "==================================================================="
[ "$FAIL" -eq 0 ]
