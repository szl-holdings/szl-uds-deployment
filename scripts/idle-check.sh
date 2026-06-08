#!/bin/sh
# Copyright 2026 SZL Holdings
# SPDX-License-Identifier: Apache-2.0
#
# scripts/idle-check.sh — Is the shared k3d demo cluster idle (safe to tear down)?
#
# WHY THIS EXISTS
# ---------------
# "All pods Running" is NOT the same as "idle". A Deployment can be mid-rollout
# while every pod still reads Running: the new ReplicaSet hash is starting its
# pod and the old ReplicaSet has not been reaped yet. This is exactly what bit
# task #228 — a grafana rollout (a fresh ReplicaSet hash + a transient
# kps-grafana-image-renderer pod from the dashboard-export work) was in flight,
# yet a naive `kubectl get pods` glance showed everything Running. A destructive
# `uds run teardown` in that window silently clobbers another task's work.
#
# THEREFORE: idleness MUST be judged by rollout state — ReplicaSet hash / age and
# Deployment rollout status — and by live deploy processes, NOT by pod phase
# alone. A cluster is treated as BUSY if ANY of the following hold:
#   * a pod is not Running-and-fully-Ready (Completed/Succeeded jobs excluded)
#   * a Deployment is mid-rollout (READY / UP-TO-DATE / AVAILABLE disagree)
#   * a ReplicaSet was created within IDLE_WINDOW_MINUTES (a fresh RS hash = a
#     recent rollout still settling — the signal a pod-phase check misses)
#   * a `zarf …deploy/create`, `uds deploy/run start/run bundle`, or
#     `helm install/upgrade` process is running
#
# EXIT CODES:  0 = idle (safe to tear down)   1 = busy / churn detected
# ENV:         CLUSTER_NAME           (default uds-szl-demo)
#              IDLE_WINDOW_MINUTES    (default 10)

CLUSTER_NAME="${CLUSTER_NAME:-uds-szl-demo}"
IDLE_WINDOW_MINUTES="${IDLE_WINDOW_MINUTES:-10}"
WINDOW_SECS=$(( IDLE_WINDOW_MINUTES * 60 ))
BUSY=0

note() { echo "  * $1"; }

# Parse an RFC3339 timestamp to epoch seconds (GNU date first, then BSD/macOS).
parse_ts() {
  d=$(date -u -d "$1" +%s 2>/dev/null) && { echo "$d"; return 0; }
  date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$1" +%s 2>/dev/null
}

# 0) No cluster => nothing in flight, safe to (no-op) tear down.
if command -v k3d >/dev/null 2>&1; then
  if ! k3d cluster list 2>/dev/null | awk 'NR>1{print $1}' | grep -qx "${CLUSTER_NAME}"; then
    echo "Cluster '${CLUSTER_NAME}' does not exist — nothing in flight."
    exit 0
  fi
fi

# Without kubectl we cannot prove the cluster is idle => fail safe (treat BUSY).
if ! command -v kubectl >/dev/null 2>&1; then
  echo "kubectl not found — cannot verify '${CLUSTER_NAME}' is idle; treating as BUSY."
  echo "Re-run teardown with --set FORCE=true to override."
  exit 1
fi

echo "Checking '${CLUSTER_NAME}' for in-flight activity (idle window: ${IDLE_WINDOW_MINUTES}m)..."

# 1) Pods that are not Running-and-fully-Ready (Completed/Succeeded jobs are fine).
NOT_READY=$(kubectl get pods -A --no-headers 2>/dev/null | awk '
  { ready=$3; status=$4 }
  status=="Completed" || status=="Succeeded" { next }
  status!="Running" { print "    " $1 "/" $2 " (" status ")"; next }
  { split(ready,a,"/"); if (a[1]!=a[2]) print "    " $1 "/" $2 " (" ready " ready)" }
')
if [ -n "$NOT_READY" ]; then
  BUSY=1
  note "Pods not Running-and-Ready:"
  echo "$NOT_READY"
fi

# 2) Deployments mid-rollout: READY (have/want), UP-TO-DATE and AVAILABLE must all
#    equal the desired count once a rollout has settled.
ROLLING=$(kubectl get deploy -A --no-headers 2>/dev/null | awk '
  { ns=$1; name=$2; ready=$3; uptodate=$4; avail=$5 }
  { split(ready,a,"/"); have=a[1]; want=a[2] }
  want=="" { next }
  (have!=want || uptodate!=want || avail!=want) {
    print "    " ns "/" name " (ready=" ready " up-to-date=" uptodate " available=" avail ")"
  }
')
if [ -n "$ROLLING" ]; then
  BUSY=1
  note "Deployments mid-rollout:"
  echo "$ROLLING"
fi

# 3) ReplicaSets created within the idle window = a fresh hash from a recent
#    rollout still settling (the churn a pod-phase glance cannot see).
NOW=$(date -u +%s)
RECENT_RS=$(kubectl get rs -A -o go-template='{{range .items}}{{.metadata.namespace}} {{.metadata.name}} {{.metadata.creationTimestamp}} {{.spec.replicas}}{{"\n"}}{{end}}' 2>/dev/null | while read -r ns name ts desired; do
  [ -z "$ts" ] && continue
  rsts=$(parse_ts "$ts") || continue
  [ -z "$rsts" ] && continue
  age=$(( NOW - rsts ))
  if [ "$age" -ge 0 ] && [ "$age" -lt "$WINDOW_SECS" ]; then
    echo "    $ns/$name (created ${age}s ago, desired=${desired})"
  fi
done)
if [ -n "$RECENT_RS" ]; then
  BUSY=1
  note "ReplicaSets created within ${IDLE_WINDOW_MINUTES}m (recent rollout):"
  echo "$RECENT_RS"
fi

# 4) Live deploy/build processes (excludes teardown + this check itself).
DEPLOYERS=$(ps -eo pid,args 2>/dev/null \
  | grep -E 'zarf (package )?(deploy|create|mirror)|uds (deploy|run start|run bundle)|helm (install|upgrade)' \
  | grep -v 'grep' | grep -v 'idle-check')
if [ -n "$DEPLOYERS" ]; then
  BUSY=1
  note "Active deploy/build processes:"
  echo "$DEPLOYERS" | sed 's/^/    /'
fi

if [ "$BUSY" -ne 0 ]; then
  echo ""
  echo "RESULT: BUSY — '${CLUSTER_NAME}' shows in-flight activity (see above)."
  exit 1
fi

echo "RESULT: IDLE — no in-flight activity detected on '${CLUSTER_NAME}'."
exit 0
