# Copyright 2026 SZL Holdings
# SPDX-License-Identifier: Apache-2.0
#
# receipts-orphan-watch-guard-checks.test.sh — negative-fixture self-test for the
# receipts-orphan-watch guard (scripts/receipts-orphan-watch-guard-checks.sh).
#
# WHY THIS EXISTS
# The guard enforces the szl-receipts-orphan-watch alarm's invariants entirely
# with hand-written grep. If one of those checks breaks (a regex typo, a bad
# anchor) it can PASS VACUOUSLY — green while guarding nothing. This test feeds
# each check a deliberately-BROKEN fixture and asserts the check FAILS, plus
# asserts the pristine repo PASSES. A future edit that neuters a check is caught
# here in CI.
#
# It sources the EXACT script the workflow runs (so chk1..chk9 are the real
# functions) and runs them against fixtures built from the real source files.
#
# Usage: bash scripts/receipts-orphan-watch-guard-checks.test.sh
# Exit 0 if every case behaves as expected, 1 otherwise.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
CHECKS="$HERE/receipts-orphan-watch-guard-checks.sh"

# shellcheck source=/dev/null
source "$CHECKS"

PASS=0
FAIL=0
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

# Source files the guard inspects, relative to a repo root.
SRC_FILES=(
  "box-scripts/sbin/szl-receipts-orphan-watch"
  "box-scripts/install.sh"
  "box-scripts/README.md"
)

# new_fixture — build a fresh fixture tree (a faithful copy of the real source
# files) under a unique dir and echo its path.
new_fixture() {
  local dir
  dir="$(mktemp -d "$TMPROOT/fixture.XXXXXX")"
  local f
  for f in "${SRC_FILES[@]}"; do
    mkdir -p "$dir/$(dirname "$f")"
    cp "$REPO_ROOT/$f" "$dir/$f"
  done
  echo "$dir"
}

# expect_pass CHECK ROOT NAME — assert CHECK returns 0 on ROOT.
expect_pass() {
  local check="$1" root="$2" name="$3" out rc
  out="$("$check" "$root" 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ]; then
    echo "ok   PASS-expected: $name"
    PASS=$((PASS+1))
  else
    echo "FAIL PASS-expected but $check exited $rc: $name"
    echo "$out" | sed 's/^/       | /'
    FAIL=$((FAIL+1))
  fi
}

# expect_fail CHECK ROOT NAME — assert CHECK returns non-zero on ROOT.
expect_fail() {
  local check="$1" root="$2" name="$3" out rc
  out="$("$check" "$root" 2>&1)"; rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "ok   FAIL-expected: $name"
    PASS=$((PASS+1))
  else
    echo "FAIL FAIL-expected but $check exited 0: $name"
    echo "$out" | sed 's/^/       | /'
    FAIL=$((FAIL+1))
  fi
}

WATCH="box-scripts/sbin/szl-receipts-orphan-watch"
INSTALL="box-scripts/install.sh"
README="box-scripts/README.md"

echo "== pristine repo: every check passes =="
expect_pass chk1 "$REPO_ROOT" "chk1 watch script present + parses"
expect_pass chk2 "$REPO_ROOT" "chk2 enumerates receipts-server namespaces"
expect_pass chk3 "$REPO_ROOT" "chk3 drops the canonical szl-receipts namespace"
expect_pass chk4 "$REPO_ROOT" "chk4 checks Helm/UDS/Istio ownership"
expect_pass chk5 "$REPO_ROOT" "chk5 edge-trigger state + 2 notify calls"
expect_pass chk6 "$REPO_ROOT" "chk6 never executes a delete command"
expect_pass chk7 "$REPO_ROOT" "chk7 cluster-absent/unreachable no-op"
expect_pass chk8 "$REPO_ROOT" "chk8 wired into install.sh"
expect_pass chk9 "$REPO_ROOT" "chk9 documented in README.md"

echo "== chk1 negatives =="
d="$(new_fixture)"; rm -f "$d/$WATCH"
expect_fail chk1 "$d" "chk1 fails when the watch script is missing"

d="$(new_fixture)"; printf 'if [ \n' > "$d/$WATCH"
expect_fail chk1 "$d" "chk1 fails when the watch script has a syntax error"

echo "== chk2 negatives =="
d="$(new_fixture)"; sed -i 's#get deploy -A#get cm -A#g' "$d/$WATCH"
expect_fail chk2 "$d" "chk2 fails when the deploy enumeration is dropped"

d="$(new_fixture)"; sed -i 's#\[ "$name" = "$DEPLOY_NAME" \]#[ false ]#' "$d/$WATCH"
expect_fail chk2 "$d" "chk2 fails when the name match is dropped"

d="$(new_fixture)"; sed -i 's#grep -q "$IMAGE_MATCH"#grep -q "nomatch"#' "$d/$WATCH"
expect_fail chk2 "$d" "chk2 fails when the image match is dropped"

echo "== chk3 negatives =="
d="$(new_fixture)"; sed -i 's#CANONICAL_NS="${SZL_RECEIPTS_CANONICAL_NS:-szl-receipts}"#CANONICAL_NS="${SZL_RECEIPTS_CANONICAL_NS:-other}"#' "$d/$WATCH"
expect_fail chk3 "$d" "chk3 fails when the canonical default is changed away from szl-receipts"

d="$(new_fixture)"; sed -i 's#\[ "$ns" = "$CANONICAL_NS" \] && continue#:#' "$d/$WATCH"
expect_fail chk3 "$d" "chk3 fails when the canonical-namespace skip is removed"

echo "== chk4 negatives =="
d="$(new_fixture)"; sed -i 's#helm list -A#helm DISABLED#g' "$d/$WATCH"
expect_fail chk4 "$d" "chk4 fails when the Helm ownership check is dropped"

d="$(new_fixture)"; sed -i 's#packages.uds.dev#packages.DISABLED#g' "$d/$WATCH"
expect_fail chk4 "$d" "chk4 fails when the UDS Package ownership check is dropped"

d="$(new_fixture)"; sed -i 's#virtualservices.networking.istio.io#vs.DISABLED#g' "$d/$WATCH"
expect_fail chk4 "$d" "chk4 fails when the Istio VirtualService ownership check is dropped"

echo "== chk5 negatives =="
d="$(new_fixture)"; sed -i 's#prev="$(cat "$LAST_FILE" 2>/dev/null || echo OK)"#prev=OK#' "$d/$WATCH"
expect_fail chk5 "$d" "chk5 fails when the last_status read is removed"

d="$(new_fixture)"; sed -i 's#mv -f "$tmp" "$LAST_FILE" 2>/dev/null##' "$d/$WATCH"
expect_fail chk5 "$d" "chk5 fails when the last_status persist is removed"

d="$(new_fixture)"; sed -i 's#if \[ "$prev" != "ALERT" \]; then#if true; then#' "$d/$WATCH"
expect_fail chk5 "$d" "chk5 fails when the OK->ALERT edge guard is removed"

# Remove the RECOVERED notify call -> count drops to 1 (not exactly 2).
d="$(new_fixture)"; sed -i '/notify "RECOVERED:/d' "$d/$WATCH"
expect_fail chk5 "$d" "chk5 fails when the RECOVERED notify call is removed"

# Add an unconditional extra notify -> count rises to 3 (alarm-storm risk).
d="$(new_fixture)"; sed -i 's#^exit 0#  notify "spurious extra page"\nexit 0#' "$d/$WATCH"
expect_fail chk5 "$d" "chk5 fails when an extra notify call is added"

echo "== chk6 negatives =="
# Inject an actual executed delete command.
d="$(new_fixture)"; sed -i 's#^exit 0#  kubectl delete ns "$ns"\nexit 0#' "$d/$WATCH"
expect_fail chk6 "$d" "chk6 fails when an executed delete command is added"

echo "== chk7 negatives =="
# Drop the exit-0 fallback on the kubeconfig-resolve line.
d="$(new_fixture)"; sed -i 's#"cluster absent"; exit 0; }#"cluster absent"; }#' "$d/$WATCH"
expect_fail chk7 "$d" "chk7 fails when cluster-absent no longer no-ops (exit 0 removed)"

# Drop the exit-0 fallback on the readyz reachability probe.
d="$(new_fixture)"; sed -i 's#"cluster unreachable"; exit 0; }#"cluster unreachable"; }#' "$d/$WATCH"
expect_fail chk7 "$d" "chk7 fails when cluster-unreachable no longer no-ops (readyz exit 0 removed)"

echo "== chk8 negatives =="
d="$(new_fixture)"; sed -i '\#install .*sbin/szl-receipts-orphan-watch#d' "$d/$INSTALL"
expect_fail chk8 "$d" "chk8 fails when install.sh stops installing the script"

d="$(new_fixture)"; sed -i '/systemctl enable --now szl-receipts-orphan-watch.timer/d' "$d/$INSTALL"
expect_fail chk8 "$d" "chk8 fails when install.sh stops enabling the timer"

echo "== chk9 negatives =="
d="$(new_fixture)"; sed -i 's#szl-receipts-orphan-watch#szl-receipts-orphan-RENAMED#g' "$d/$README"
expect_fail chk9 "$d" "chk9 fails when README no longer documents szl-receipts-orphan-watch"

echo ""
echo "==================================================================="
echo "receipts-orphan-watch-guard self-test: $PASS passed, $FAIL failed"
echo "==================================================================="
[ "$FAIL" -eq 0 ]
