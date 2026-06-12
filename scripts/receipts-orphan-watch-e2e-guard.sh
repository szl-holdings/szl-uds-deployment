# Copyright 2026 SZL Holdings
# SPDX-License-Identifier: Apache-2.0
#
# receipts-orphan-watch-e2e-guard.sh — drive the REAL szl-receipts-orphan-watch
# edge-alert watcher end-to-end against a fake cluster and assert its alerting,
# de-dup, RECOVERED and fail-safe behaviour.
#
# WHY THIS EXISTS
# box-scripts/sbin/szl-receipts-orphan-watch pages the team when a namespace runs
# a receipts-server Deployment owned by NOTHING (no Helm release, no UDS Package,
# no Istio VirtualService) — an orphan that signs nothing and burns CPU on the
# 2-vCPU node (Task #283). Its value rides on behaviour that has NO visible
# symptom when broken until a real orphan goes unalerted (or a stopped cluster
# turns into a paging storm):
#   * EDGE alert: page once on OK->ALERT, never every cycle (de-dup), page once
#     on RECOVERED when the orphan clears;
#   * ownership: a Helm-owned receipts-server namespace must NOT be flagged;
#   * FAIL-SAFE: cluster absent/unreachable OR an ownership probe erroring =
#     status UNKNOWN, no page, last_status left untouched (never a false alarm).
# The existing receipts-orphan-watch-guard-checks.sh is a static text check; this
# guard RUNS the real watcher end-to-end against fake k3d/kubectl/helm (no
# cluster, no root, never deletes anything) and asserts the actual behaviour.
#
# Usage: bash scripts/receipts-orphan-watch-e2e-guard.sh [path-to-watcher]
#   The negative-fixture self-test points it at deliberately-broken copies.
# Exit 0 if every assertion holds, 1 otherwise.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
SCRIPT="${1:-$REPO_ROOT/box-scripts/sbin/szl-receipts-orphan-watch}"
# shellcheck source=scripts/lib/box-watch-stubs.sh
. "$HERE/lib/box-watch-stubs.sh"

if [ ! -r "$SCRIPT" ]; then
  echo "FATAL szl-receipts-orphan-watch script not found/readable: $SCRIPT" >&2
  exit 1
fi

PASS=0; FAIL=0
ok()  { echo "ok   $*"; PASS=$((PASS+1)); }
bad() { echo "FAIL $*"; FAIL=$((FAIL+1)); }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
BIN="$T/bin"; CTRL="$T/ctrl"; STATE="$T/state"; LOGD="$T/log"
mkdir -p "$BIN" "$CTRL" "$STATE" "$LOGD"
make_k8s_stubs "$BIN"

LOG="$LOGD/watch.log"
STATUS="$STATE/status.json"
LASTF="$STATE/last_status"

# run — drive the real watcher. STATE persists across runs (so edge/de-dup work);
# the LOG is truncated each run so each cycle's pushes are isolated. NOTIFY_CMD=cat
# routes every notify() into the log, distinguished from log() lines by the
# ALERT_PREFIX which only notify() prepends.
run() {
  : > "$LOG"
  env PATH="$BIN:$PATH" STUB_CTRL="$CTRL" \
    STATE_DIR="$STATE" LOG_DIR="$LOGD" LOG="$LOG" STATUS="$STATUS" \
    LAST_FILE="$LASTF" LOCK="$STATE/lock" \
    NOTIFY_CMD=cat ALERT_PREFIX="[TEST-ignore] " \
    bash "$SCRIPT" >/dev/null 2>&1
}
notified_alert()     { grep -q '\[TEST-ignore\] ALERT:' "$LOG"; }
notified_recovered() { grep -q '\[TEST-ignore\] RECOVERED:' "$LOG"; }
status_is()          { grep -q "\"overall\":\"$1\"" "$STATUS"; }

# A receipts-server deploy row (TSV: ns name images managedby relname) as emitted
# by the watcher's `kubectl get deploy -A -o jsonpath`.
row() { printf '%s\t%s\t%s \t%s\t%s\n' "$1" "$2" "$3" "$4" "$5"; }

reset_cluster() {  # leaves STATE intact (edge/de-dup); resets the fake cluster
  rm -f "$CTRL"/* 2>/dev/null
  : > "$CTRL/kubeconfig"
  echo 0 > "$CTRL/readyz_rc"
}
fresh_state() { rm -f "$LASTF" "$STATUS" 2>/dev/null; }

echo "== Phase A: cluster absent -> UNKNOWN, no page, last_status untouched =="
fresh_state; reset_cluster; : > "$CTRL/k3d_absent"
echo ALERT > "$LASTF"                       # pretend a prior ALERT is latched
run
if status_is UNKNOWN;       then ok "A1 cluster-absent -> status UNKNOWN"; else bad "A1 status not UNKNOWN"; fi
if ! notified_alert && ! notified_recovered; then ok "A2 cluster-absent pages nothing"; else bad "A2 paged on absent cluster"; fi
if [ "$(cat "$LASTF")" = "ALERT" ]; then ok "A3 last_status left untouched"; else bad "A3 last_status was reset"; fi

echo "== Phase B: clean cluster (no receipts-server anywhere) -> OK, no page =="
fresh_state; reset_cluster
: > "$CTRL/deploy_rows"
run
if status_is OK;            then ok "B1 clean cluster -> OK"; else bad "B1 status not OK"; fi
if ! notified_alert;        then ok "B2 clean cluster fires no ALERT"; else bad "B2 ALERTed on a clean cluster"; fi

echo "== Phase C: an orphan appears -> ALERT page on the edge =="
reset_cluster
row stray-ns szl-receipts-server ghcr.io/szl/receipts-server:v1 "" "" > "$CTRL/deploy_rows"
: > "$CTRL/uds_stray-ns"; : > "$CTRL/vs_stray-ns"   # no UDS pkg, no VS
: > "$CTRL/helm_list"                                # helm reachable, owns nothing
run
if notified_alert;          then ok "C1 orphan edge fires an ALERT page"; else bad "C1 no ALERT on the orphan edge"; fi
if status_is ALERT;         then ok "C2 status.json overall=ALERT"; else bad "C2 status not ALERT"; fi

echo "== Phase D: orphan persists -> de-duped (no repeat page) =="
run
if ! notified_alert;        then ok "D1 persisting orphan does NOT re-page (de-dup)"; else bad "D1 re-paged on a persisting orphan"; fi

echo "== Phase E: orphan removed -> RECOVERED page =="
reset_cluster
: > "$CTRL/deploy_rows"
run
if notified_recovered;      then ok "E1 clearing the orphan fires RECOVERED"; else bad "E1 no RECOVERED page when orphan cleared"; fi
if status_is OK;            then ok "E2 status back to OK"; else bad "E2 status not OK after recovery"; fi

echo "== Phase F: a Helm-owned receipts-server namespace is NOT flagged =="
fresh_state; reset_cluster
row prod-ns szl-receipts-server ghcr.io/szl/receipts-server:v1 Helm "" > "$CTRL/deploy_rows"
: > "$CTRL/uds_prod-ns"; : > "$CTRL/vs_prod-ns"
: > "$CTRL/helm_list"
run
if status_is OK;            then ok "F1 Helm-owned receipts-server -> OK (not an orphan)"; else bad "F1 flagged a Helm-owned namespace"; fi
if ! notified_alert;        then ok "F2 no page for a Helm-owned namespace"; else bad "F2 paged on a tracked namespace"; fi

echo "== Phase G: an ownership probe ERRORS -> UNKNOWN, no false page, last untouched =="
fresh_state; reset_cluster
row maybe-ns szl-receipts-server ghcr.io/szl/receipts-server:v1 "" "" > "$CTRL/deploy_rows"
: > "$CTRL/helm_list"
: > "$CTRL/uds_maybe-ns_err"                          # UDS-package probe errors
echo OK > "$LASTF"
run
if status_is UNKNOWN;       then ok "G1 indeterminate ownership -> status UNKNOWN"; else bad "G1 status not UNKNOWN on probe error"; fi
if ! notified_alert;        then ok "G2 probe error pages nothing (fail-safe)"; else bad "G2 false ALERT on a probe error"; fi
if [ "$(cat "$LASTF")" = "OK" ]; then ok "G3 last_status left untouched on UNKNOWN"; else bad "G3 last_status mutated on UNKNOWN"; fi

echo ""
echo "==================================================================="
echo "szl-receipts-orphan-watch e2e guard: $PASS passed, $FAIL failed"
echo "==================================================================="
[ "$FAIL" -eq 0 ]
