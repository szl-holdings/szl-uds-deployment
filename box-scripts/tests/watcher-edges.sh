#!/usr/bin/env bash
#
# watcher-edges.sh — drive every box watcher's healthy->ALERT edge through a
# capture-stub NOTIFY_CMD and assert each one actually fired, then assert it
# DE-DUPES the persisting problem on a second run. It NEVER touches the real
# notification channel (ntfy/Telegram/webhook): NOTIFY_CMD is pointed at a local
# capture file for every run.
#
# It is fully self-contained and CI-safe (no root, no real cluster, no network
# dependency for the assertion outcome):
#   * the drift fixture repo for box-scripts-drift-check is BUILT INLINE;
#   * the cluster-bound watchers get past their cluster-up gate via PATH stubs
#     for k3d + kubectl, and a stub szl-ns-scratch / forced sink-missing state.
#
# The watchers under test are the committed copies in box-scripts/sbin (NOT the
# host's /usr/local/sbin), so this verifies the source of truth.
#
# Exit: 0 = every watcher fired its edge AND de-duped; non-zero = any miss.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SBIN="$(cd "$HERE/../sbin" && pwd)"
ORIG_PATH="$PATH"
PREFIX="[TEST-ignore] "

WORK="$(mktemp -d)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

# Each watcher is exercised inside its own ( ... ) subshell, so counter variables
# incremented there would be LOST when the subshell exits (a failed assertion
# would silently vanish and the script would wrongly report PASS). Record every
# assertion as a line in a shared file instead, then count from it in the parent.
RESULTS="$WORK/results"; : > "$RESULTS"
ok()   { printf 'ok\n'   >> "$RESULTS"; printf '  ok   %s\n' "$1"; }
fail() { printf 'fail\n' >> "$RESULTS"; printf '  FAIL %s\n' "$1"; }

# ---- capture-stub notifier: records the alert (stdin) for assertion ----------
CAPTURE_STUB="$WORK/capture-notify"
cat > "$CAPTURE_STUB" <<'EOF'
#!/usr/bin/env bash
# TEST notifier — never reaches a real channel. Appends the alert to CAPTURE_FILE.
cat >> "${CAPTURE_FILE:?CAPTURE_FILE must be set by the test}"
EOF
chmod +x "$CAPTURE_STUB"

# ---- PATH stubs for the cluster-bound watchers ------------------------------
STUBS="$WORK/stubs"; mkdir -p "$STUBS"
FAKE_KC="$WORK/fake.kubeconfig"; : > "$FAKE_KC"
cat > "$STUBS/k3d" <<EOF
#!/usr/bin/env bash
# stub: 'k3d kubeconfig write <cluster>' -> print a (dummy) kubeconfig path.
echo "$FAKE_KC"
EOF
cat > "$STUBS/kubectl" <<'EOF'
#!/usr/bin/env bash
# stub: answer only what the watchers probe; force the receipts sink "missing".
args="$*"
case "$args" in
  *"--raw=/readyz"*)                  exit 0 ;;  # cluster reachable
  *"get deploy pepr-szl"*)            exit 0 ;;  # receipts module present
  *"get deploy szl-receipts-server"*) exit 1 ;;  # sink MISSING -> forces a reason
  *)                                  exit 0 ;;  # logs/endpoints: empty success
esac
EOF
chmod +x "$STUBS/k3d" "$STUBS/kubectl"

# ---- stub szl-ns-scratch audit tool -----------------------------------------
SCRATCH_STUB="$WORK/szl-ns-scratch-stub"
cat > "$SCRATCH_STUB" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  list-unlabeled) echo "szl-fake-untracked-ns" ;;
  list-stale)     echo "szl-fake-stale-ns age=99d threshold=14d owner=test" ;;
esac
exit 0
EOF
chmod +x "$SCRATCH_STUB"

# assert_edge NAME SCRIPT
#   run 1 (synthetic problem, prev=OK)  -> MUST capture an ALERT with our prefix
#   run 2 (same problem still present)  -> MUST be de-duped (no new capture)
# The forcing env (incl. STATE_DIR + CAPTURE_FILE) is exported by the caller.
assert_edge() {
  local name="$1" script="$2"
  : > "$CAPTURE_FILE"
  bash "$script" >/dev/null 2>&1 || true
  if [ -s "$CAPTURE_FILE" ] && grep -qF "$PREFIX" "$CAPTURE_FILE"; then
    ok "$name fired OK->ALERT edge to the stub notifier"
  else
    fail "$name did NOT fire the expected ALERT (capture empty / missing test prefix)"
  fi
  : > "$CAPTURE_FILE"
  bash "$script" >/dev/null 2>&1 || true
  if [ -s "$CAPTURE_FILE" ]; then
    fail "$name re-notified on a PERSISTING problem (edge de-dup broken)"
  else
    ok "$name de-duped the persisting problem (no re-notify)"
  fi
}

# Per-watcher fresh state dir so prev-state == OK and the edge fires.
mkstate() { local d="$WORK/state/$1"; mkdir -p "$d/log"; printf '%s' "$d"; }

echo "== driving 6 watcher OK->ALERT edges via a capture stub (no real channel) =="

# ---- 1. a11oy-uptime-check : unresolvable host -> DOWN -----------------------
(
  s="$(mkstate uptime)"
  export PATH="$ORIG_PATH"
  export HOSTS="nonexistent.invalid" CURL_TIMEOUT=3
  export STATE_DIR="$s" LOG_DIR="$s/log" LOG="$s/log/x.log" STATUS="$s/status.json"
  export SIG_FILE="$s/problem.sig" LASTRUN_FILE="$s/lastrun.epoch"
  export CAPTURE_FILE="$WORK/cap.uptime" NOTIFY_CMD="$CAPTURE_STUB" ALERT_PREFIX="$PREFIX"
  assert_edge "a11oy-uptime-check" "$SBIN/a11oy-uptime-check"
) || true

# ---- 2. dns-drift-check : impossible expected IP -> DRIFT --------------------
(
  s="$(mkstate dns)"
  export PATH="$ORIG_PATH"
  export EXPECT_IP="10.255.255.254" HOSTS="a11oy.net" RESOLVER="8.8.8.8" DIG_TIMEOUT=3
  export STATE_DIR="$s" LOG_DIR="$s/log" LOG="$s/log/x.log" STATUS="$s/status.json" SIG_FILE="$s/problem.sig"
  export CAPTURE_FILE="$WORK/cap.dns" NOTIFY_CMD="$CAPTURE_STUB" ALERT_PREFIX="$PREFIX"
  assert_edge "dns-drift-check" "$SBIN/dns-drift-check"
) || true

# ---- 3. box-scripts-drift-check : inline fixture, live edit differs from repo
(
  s="$(mkstate boxdrift)"
  repo="$WORK/fix/repo"; live="$WORK/fix/live-sbin"; units="$WORK/fix/live-units"
  mkdir -p "$repo/.git" "$repo/box-scripts/sbin" "$live" "$units"
  printf 'committed-v1\n' > "$repo/box-scripts/sbin/fixture-drift-demo"
  printf 'live-edited-v2\n' > "$live/fixture-drift-demo"   # differs -> DRIFT
  export PATH="$ORIG_PATH"
  export REPO="$repo" BOX_SCRIPTS="$repo/box-scripts" SBIN_DIR="$live" UNIT_DIR="$units"
  export WATCH_SBIN="fixture-drift-demo" WATCH_UNITS="" SELF_HEAL=0 INSTALL_SH=/dev/null
  export STATE_DIR="$s" LOG_DIR="$s/log" LOG="$s/log/x.log" STATUS="$s/status.json" SIG_FILE="$s/problem.sig"
  export CAPTURE_FILE="$WORK/cap.boxdrift" NOTIFY_CMD="$CAPTURE_STUB" ALERT_PREFIX="$PREFIX"
  assert_edge "box-scripts-drift-check" "$SBIN/box-scripts-drift-check"
) || true

# ---- 4. szl-ns-scratch-watch : stub reports an untracked namespace ----------
(
  s="$(mkstate nsscratch)"
  export PATH="$STUBS:$ORIG_PATH"
  export SCRATCH_BIN="$SCRATCH_STUB" SZL_NS_CLUSTER="uds-szl-demo"
  export STATE_DIR="$s" LOG_DIR="$s/log" LAST_FILE="$s/last_status" STATUS="$s/status.json" LOG="$s/log/x.log"
  export CAPTURE_FILE="$WORK/cap.nsscratch" NOTIFY_CMD="$CAPTURE_STUB" ALERT_PREFIX="$PREFIX"
  assert_edge "szl-ns-scratch-watch" "$SBIN/szl-ns-scratch-watch"
) || true

# ---- 5. szl-ns-scratch-stale-watch : stub reports a past-TTL namespace -------
(
  s="$(mkstate nsstale)"
  export PATH="$STUBS:$ORIG_PATH"
  export SCRATCH_BIN="$SCRATCH_STUB" SZL_NS_CLUSTER="uds-szl-demo"
  export STATE_DIR="$s" LOG_DIR="$s/log" LAST_FILE="$s/last_status" STATUS="$s/status.json" LOG="$s/log/x.log"
  export CAPTURE_FILE="$WORK/cap.nsstale" NOTIFY_CMD="$CAPTURE_STUB" ALERT_PREFIX="$PREFIX"
  assert_edge "szl-ns-scratch-stale-watch" "$SBIN/szl-ns-scratch-stale-watch"
) || true

# ---- 6. receipt-chain-watch : pepr present but receipts sink missing ---------
(
  s="$(mkstate chain)"
  export PATH="$STUBS:$ORIG_PATH"
  export CLUSTER="uds-szl-demo" KUBECONFIG_FILE=""
  export STATE_DIR="$s" LOG_DIR="$s/log" LAST_FILE="$s/last_status" STATUS="$s/status.json" LOG="$s/log/x.log"
  export CAPTURE_FILE="$WORK/cap.chain" NOTIFY_CMD="$CAPTURE_STUB" ALERT_PREFIX="$PREFIX"
  assert_edge "receipt-chain-watch" "$SBIN/receipt-chain-watch"
) || true

echo
checks=$(wc -l < "$RESULTS" | tr -d ' ')
fails=$(grep -cx fail "$RESULTS" || true)
# 6 watchers x 2 assertions (fire edge + de-dup) = 12. A short count means a
# subshell died before recording its result — treat that as a failure too.
EXPECTED=12
if [ "$checks" -ne "$EXPECTED" ]; then
  echo "  FAIL expected $EXPECTED assertions but only $checks ran (a watcher block aborted early)"
  fails=$((fails + (EXPECTED - checks)))
fi
echo "watcher-edges: $checks checks, $fails failure(s)."
if [ "$fails" -eq 0 ]; then echo "RESULT: PASS"; exit 0; else echo "RESULT: FAIL"; exit 1; fi
