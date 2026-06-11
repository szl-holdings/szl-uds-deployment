#!/usr/bin/env bash
# Copyright 2026 SZL Holdings
# SPDX-License-Identifier: Apache-2.0
#
# receipt-flood-watch-selftest.sh — prove the receipt-flood-watch box alarm
# (box-scripts/sbin/receipt-flood-watch) ACTUALLY FIRES on a flood and behaves
# correctly on every edge, by DRIVING the real script with a stubbed
# kubectl/k3d/metrics source. No cluster, no network — pure local fixtures.
#
# WHY a behavioural self-test (vs the text/lint guard pattern the sibling box
# alarms use): the value of receipt-flood-watch is its RATE/EDGE MATH —
# delta/min computation, the reset=>rate-0 guard, the baseline-only first run,
# the cluster-absent no-op, and the EXACTLY-ONE-notify-per-edge de-dup. A grep
# guard can confirm a line still exists; only running the script proves the math
# still produces the right ALERT/OK/UNKNOWN verdict. README's drill recipe was
# the only thing exercising this, and a drill is not CI. This self-test makes a
# future refactor that silently neuters the rate computation a red CI run.
#
# It feeds the script:
#   * a stub `kubectl` that answers /readyz, the deploy presence check, the pod
#     listing, and `exec ... /metrics` (emitting a controllable szl_chain_length
#     gauge via $STUB_CHAIN);
#   * a stub `k3d` that fails (to simulate an absent cluster);
#   * a stub notifier that counts how many times it is invoked.
# and seeds the per-cluster SAMPLE_FILE to control the prior sample/timestamp so
# the rate is deterministic without waiting MIN_INTERVAL_SECS of wall-clock.
#
# Scenarios asserted:
#   1. baseline-only on first run (no prior sample) -> OK, sample recorded, no page
#   2. ALERT when delta/min >= FLOOD_PER_MIN
#   3. OK when delta/min <  FLOOD_PER_MIN
#   4. rate 0 on a chain reset (count drops) -> OK (never a negative/false alarm)
#   5. no-op when the cluster is absent (exit 0, UNKNOWN, no sample, no page)
#   6. EXACTLY ONE notify on each edge (OK->ALERT once, dedup while ALERT,
#      RECOVERED once, silent while OK)
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$HERE/..}"
SCRIPT="$REPO_ROOT/box-scripts/sbin/receipt-flood-watch"

PASS=0; FAIL=0
ok()   { printf '  ok   %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL+1)); }

[ -f "$SCRIPT" ] || { echo "::error::missing $SCRIPT"; exit 1; }
bash -n "$SCRIPT" || { echo "::error::$SCRIPT does not parse"; exit 1; }

# ---- Stub toolchain (kubectl / k3d / notifier) ------------------------------
STUBBIN="$(mktemp -d)"
trap 'rm -rf "$STUBBIN"' EXIT

cat >"$STUBBIN/kubectl" <<'KEOF'
#!/usr/bin/env bash
# Minimal kubectl stub. Reads $STUB_CHAIN for the metrics gauge and $STUB_PODS
# for the pod listing JSON. Order matters: match the most specific first.
all="$*"
case "$all" in
  *"--raw=/readyz"*)
    exit 0 ;;                                   # cluster reachable
  *" exec "*)
    printf '# HELP szl_chain_length total receipts in the chain\n'
    printf '# TYPE szl_chain_length gauge\n'
    printf 'szl_chain_length %s\n' "${STUB_CHAIN:-0}"
    exit 0 ;;
  *"get pods"*)
    printf '%s\n' "${STUB_PODS:-}"
    exit 0 ;;
  *"get deploy szl-receipts-server"*)
    exit 0 ;;                                   # receipts module present
  *)
    exit 0 ;;
esac
KEOF
chmod +x "$STUBBIN/kubectl"

# k3d stub: always FAILS, so an unset KUBECONFIG_FILE simulates an absent cluster.
cat >"$STUBBIN/k3d" <<'K3EOF'
#!/usr/bin/env bash
exit 1
K3EOF
chmod +x "$STUBBIN/k3d"

# notifier stub: drain stdin, append one line per invocation to $NOTIFY_COUNTER.
cat >"$STUBBIN/notify-stub" <<'NEOF'
#!/usr/bin/env bash
cat >/dev/null 2>&1
echo 1 >> "$NOTIFY_COUNTER"
NEOF
chmod +x "$STUBBIN/notify-stub"

READY_POD='{"items":[{"metadata":{"name":"szl-receipts-server-test"},"status":{"containerStatuses":[{"name":"receipts-server","ready":true}]}}]}'

# run_flood: drives the real script against a state dir with our stubs on PATH.
# Required env (caller exports): STATE, NOTIFY_COUNTER, and any STUB_*/KUBECONFIG.
run_flood() {
  PATH="$STUBBIN:$PATH" \
  CLUSTER=test \
  STATE_DIR="$STATE" \
  LOG_DIR="$STATE/log" \
  NOTIFY_CMD="$STUBBIN/notify-stub" \
  ALERT_PREFIX="" \
  bash "$SCRIPT"
}

notify_count() { [ -r "$NOTIFY_COUNTER" ] && wc -l < "$NOTIFY_COUNTER" | tr -d ' ' || echo 0; }
status_file()  { echo "$STATE/test.status.json"; }
sample_file()  { echo "$STATE/test.sample"; }
last_file()    { echo "$STATE/test.last_status"; }
seed_sample()  { printf '%s %s\n' "$1" "$2" > "$(sample_file)"; }   # count ts

echo "== receipt-flood-watch behavioural self-test =="

# ---------------------------------------------------------------------------
# 1. Baseline-only on first run (no prior sample)
# ---------------------------------------------------------------------------
STATE="$(mktemp -d)"; NOTIFY_COUNTER="$STATE/notify.count"; export NOTIFY_COUNTER
mkdir -p "$STATE"
KUBECONFIG_FILE="$STATE/kubeconfig"; export KUBECONFIG_FILE; : > "$KUBECONFIG_FILE"
export STUB_PODS="$READY_POD" STUB_CHAIN=1000
rc=0; run_flood >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 0 ] && ok "baseline: exit 0" || bad "baseline: expected exit 0, got $rc"
grep -q '"overall":"OK"' "$(status_file)" && ok "baseline: status OK" || bad "baseline: status not OK"
grep -q 'baselined' "$(status_file)" && ok "baseline: reason says baselined" || bad "baseline: reason missing 'baselined'"
[ -r "$(sample_file)" ] && grep -q '^1000 ' "$(sample_file)" && ok "baseline: sample recorded" || bad "baseline: sample not recorded"
[ "$(notify_count)" -eq 0 ] && ok "baseline: no page" || bad "baseline: paged on first run"
rm -rf "$STATE"

# ---------------------------------------------------------------------------
# 2. ALERT when delta/min >= FLOOD_PER_MIN
#    seed prev=1000 @ now-120s, cur=1400 -> 400 over ~120s = ~200/min >= 120
# ---------------------------------------------------------------------------
STATE="$(mktemp -d)"; NOTIFY_COUNTER="$STATE/notify.count"; export NOTIFY_COUNTER
export KUBECONFIG_FILE="$STATE/kubeconfig"; : > "$KUBECONFIG_FILE"
export STUB_PODS="$READY_POD" STUB_CHAIN=1400
seed_sample 1000 "$(( $(date -u +%s) - 120 ))"
rc=0; run_flood >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 0 ] && ok "alert: exit 0" || bad "alert: expected exit 0, got $rc"
grep -q '"overall":"ALERT"' "$(status_file)" && ok "alert: status ALERT" || bad "alert: status not ALERT"
grep -q '>= 120/min' "$(status_file)" && ok "alert: reason cites threshold" || bad "alert: reason missing threshold"
[ "$(cat "$(last_file)")" = "ALERT" ] && ok "alert: edge state=ALERT" || bad "alert: edge state not ALERT"
[ "$(notify_count)" -eq 1 ] && ok "alert: paged exactly once" || bad "alert: notify count $(notify_count) != 1"
rm -rf "$STATE"

# ---------------------------------------------------------------------------
# 3. OK when delta/min < FLOOD_PER_MIN
#    seed prev=1000 @ now-120s, cur=1010 -> 10 over ~120s = ~5/min < 120
# ---------------------------------------------------------------------------
STATE="$(mktemp -d)"; NOTIFY_COUNTER="$STATE/notify.count"; export NOTIFY_COUNTER
export KUBECONFIG_FILE="$STATE/kubeconfig"; : > "$KUBECONFIG_FILE"
export STUB_PODS="$READY_POD" STUB_CHAIN=1010
seed_sample 1000 "$(( $(date -u +%s) - 120 ))"
rc=0; run_flood >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 0 ] && ok "below: exit 0" || bad "below: expected exit 0, got $rc"
grep -q '"overall":"OK"' "$(status_file)" && ok "below: status OK" || bad "below: status not OK"
grep -q '< 120/min' "$(status_file)" && ok "below: reason under threshold" || bad "below: reason not under threshold"
[ "$(cat "$(last_file)")" = "OK" ] && ok "below: edge state=OK" || bad "below: edge state not OK"
[ "$(notify_count)" -eq 0 ] && ok "below: no page" || bad "below: paged under threshold"
rm -rf "$STATE"

# ---------------------------------------------------------------------------
# 4. rate 0 on a chain reset (count drops) -> OK, never a false alarm
#    seed prev=1000 @ now-120s, cur=5 (reset) -> delta negative -> rate 0.00
# ---------------------------------------------------------------------------
STATE="$(mktemp -d)"; NOTIFY_COUNTER="$STATE/notify.count"; export NOTIFY_COUNTER
export KUBECONFIG_FILE="$STATE/kubeconfig"; : > "$KUBECONFIG_FILE"
export STUB_PODS="$READY_POD" STUB_CHAIN=5
seed_sample 1000 "$(( $(date -u +%s) - 120 ))"
rc=0; run_flood >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 0 ] && ok "reset: exit 0" || bad "reset: expected exit 0, got $rc"
grep -q '"overall":"OK"' "$(status_file)" && ok "reset: status OK" || bad "reset: status not OK"
grep -q '0.00/min' "$(status_file)" && ok "reset: rate reported as 0.00/min" || bad "reset: rate not zeroed on reset"
[ "$(notify_count)" -eq 0 ] && ok "reset: no false page" || bad "reset: false alarm on reset"
rm -rf "$STATE"

# ---------------------------------------------------------------------------
# 5. no-op when the cluster is absent (k3d stub fails, no KUBECONFIG_FILE)
# ---------------------------------------------------------------------------
STATE="$(mktemp -d)"; NOTIFY_COUNTER="$STATE/notify.count"; export NOTIFY_COUNTER
export KUBECONFIG_FILE=""        # force the k3d resolve path -> stub fails
export STUB_PODS="$READY_POD" STUB_CHAIN=999999
rc=0; run_flood >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 0 ] && ok "absent: exit 0 (no-op)" || bad "absent: expected exit 0, got $rc"
grep -q '"overall":"UNKNOWN"' "$(status_file)" && ok "absent: status UNKNOWN" || bad "absent: status not UNKNOWN"
grep -q 'cluster absent' "$(status_file)" && ok "absent: reason 'cluster absent'" || bad "absent: reason wrong"
[ ! -e "$(sample_file)" ] && ok "absent: did not disturb the sample baseline" || bad "absent: wrote a sample on an absent cluster"
[ "$(notify_count)" -eq 0 ] && ok "absent: no page" || bad "absent: paged on an absent cluster"
rm -rf "$STATE"

# ---------------------------------------------------------------------------
# 6. EXACTLY ONE notify on each edge (persistent state + counter across runs)
#    OK->ALERT (page) -> still ALERT (dedup) -> RECOVERED (page) -> still OK (silent)
# ---------------------------------------------------------------------------
STATE="$(mktemp -d)"; NOTIFY_COUNTER="$STATE/notify.count"; export NOTIFY_COUNTER
export KUBECONFIG_FILE="$STATE/kubeconfig"; : > "$KUBECONFIG_FILE"
export STUB_PODS="$READY_POD"

# run1: OK->ALERT edge
export STUB_CHAIN=1400; seed_sample 1000 "$(( $(date -u +%s) - 120 ))"
run_flood >/dev/null 2>&1
c1="$(notify_count)"
# run2: still ALERT -> dedup, no new page
export STUB_CHAIN=1400; seed_sample 1000 "$(( $(date -u +%s) - 120 ))"
run_flood >/dev/null 2>&1
c2="$(notify_count)"
# run3: ALERT->OK edge (RECOVERED) -> page
export STUB_CHAIN=1010; seed_sample 1000 "$(( $(date -u +%s) - 120 ))"
run_flood >/dev/null 2>&1
c3="$(notify_count)"
# run4: still OK -> silent
export STUB_CHAIN=1010; seed_sample 1000 "$(( $(date -u +%s) - 120 ))"
run_flood >/dev/null 2>&1
c4="$(notify_count)"

[ "$c1" -eq 1 ] && ok "edge: OK->ALERT paged once"        || bad "edge: OK->ALERT count $c1 != 1"
[ "$c2" -eq 1 ] && ok "edge: held ALERT deduped (no re-page)" || bad "edge: ALERT re-paged ($c2 != 1)"
[ "$c3" -eq 2 ] && ok "edge: ALERT->OK (RECOVERED) paged once" || bad "edge: RECOVERED count $c3 != 2"
[ "$c4" -eq 2 ] && ok "edge: held OK stays silent"        || bad "edge: OK paged ($c4 != 2)"
rm -rf "$STATE"

echo "== summary: $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ] || exit 1
