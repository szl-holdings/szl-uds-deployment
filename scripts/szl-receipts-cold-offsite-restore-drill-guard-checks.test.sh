# Copyright 2026 SZL Holdings
# SPDX-License-Identifier: Apache-2.0
#
# szl-receipts-cold-offsite-restore-drill-guard-checks.test.sh — negative-fixture
# self-test for scripts/szl-receipts-cold-offsite-restore-drill-guard-checks.sh.
#
# A guard is only worth running if it actually FAILS on a regression. This feeds
# each check a deliberately-BROKEN copy of the repo (one safety property neutered
# per fixture via a surgical sed) and asserts the matching check FAILS, then
# asserts the PRISTINE repo PASSES every check. If a future edit silently neuters
# a check so it can no longer detect its regression, THIS test goes red.
#
# It runs as the `self-test` job in szl-receipts-cold-offsite-restore-drill-guard.yml,
# gating the real guard job.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
CHECKS="$HERE/szl-receipts-cold-offsite-restore-drill-guard-checks.sh"

DRILL_REL="box-scripts/sbin/szl-receipts-cold-offsite-restore-drill"
INSTALL_REL="box-scripts/install.sh"
RUNBOOK_REL="docs/operations/RECEIPT_STORE_RETENTION_RUNBOOK.md"

pass=0; fail=0
ok()   { echo "  PASS: $1"; pass=$((pass+1)); }
bad()  { echo "  FAIL: $1"; fail=$((fail+1)); }

# Build a full working copy of the repo files the guard reads, into a temp root.
make_fixture() {
  local dir; dir="$(mktemp -d)"
  mkdir -p "$dir/box-scripts/sbin" "$dir/box-scripts" "$dir/docs/operations"
  cp "$REPO_ROOT/$DRILL_REL" "$dir/$DRILL_REL"
  cp "$REPO_ROOT/$INSTALL_REL" "$dir/$INSTALL_REL"
  cp "$REPO_ROOT/$RUNBOOK_REL" "$dir/$RUNBOOK_REL"
  chmod +x "$dir/$DRILL_REL" 2>/dev/null || true
  echo "$dir"
}

# expect_fail CHECK DESC MUTATE_FN — apply MUTATE_FN to a fresh fixture, run
# CHECK against it, and require a NON-ZERO exit (the check caught the regression).
expect_fail() {
  local check="$1" desc="$2" mutate="$3"
  local dir; dir="$(make_fixture)"
  "$mutate" "$dir"
  if bash "$CHECKS" "$check" "$dir" >/dev/null 2>&1; then
    bad "$check should FAIL when $desc, but it PASSED"
  else
    ok "$check correctly FAILS when $desc"
  fi
  rm -rf "$dir"
}

# ── Mutations (each breaks exactly one invariant) ─────────────────────────────

# chk1: drill script gone entirely.
m_remove_script() { rm -f "$1/$DRILL_REL"; }

# chk2: break the SKIPPED_UNCONFIGURED no-op — make the unconfigured branch exit
# non-zero instead of a clean 0.
m_break_unconfigured() {
  sed -i '/SKIPPED_UNCONFIGURED: no offsite destination set/{n;s/exit 0/exit 9/}' "$1/$DRILL_REL"
}

# chk3: break the nothing-to-restore no-op — make the no-buckets branch exit
# non-zero.
m_break_nobuckets_noop() {
  sed -i '/no offsite buckets to restore yet (nothing mirrored)/{n;n;n;s/exit 0/exit 7/}' "$1/$DRILL_REL"
}

# chk4: remove the SHA256 GATE — make the sha comparison always-satisfied, so a
# corrupt/truncated offsite copy is accepted as restorable.
m_break_sha_gate() {
  sed -i 's/\[ "\$want" != "\$got" \]/[ "\$want" = "\$got" ]/' "$1/$DRILL_REL"
}

# chk5: remove the WELL-FORMED GATE — make the extraction/shape check always
# succeed, so a malformed restore is reported healthy.
m_break_wellformed_gate() {
  sed -i 's|if wf="\$(assert_well_formed_shard.*then|if wf="bypassed"; then|' "$1/$DRILL_REL"
}

# chk7: remove the EDGE-DEDUP — make the ALERT branch always notify, so a
# persistent failure re-pages every cycle.
m_break_dedup() {
  sed -i 's/if \[ "\$prev" != "ALERT" \]; then/if true; then/' "$1/$DRILL_REL"
}

# chk8: un-wire the timer enable in install.sh.
m_break_install_enable() {
  sed -i 's/systemctl enable --now szl-receipts-cold-offsite-restore-drill\.timer/# UNWIRED for test/' "$1/$INSTALL_REL"
}

# chk9: remove the runbook's mention of the job.
m_break_runbook() {
  sed -i 's/szl-receipts-cold-offsite-restore-drill/REMOVED-DRILL-NAME/g' "$1/$RUNBOOK_REL"
}

echo "== Negative fixtures (each check must FAIL on its regression) =="
expect_fail chk1 "the drill script is missing"                       m_remove_script
expect_fail chk2 "the unconfigured no-op is broken"                  m_break_unconfigured
expect_fail chk3 "the nothing-to-restore no-op is broken"           m_break_nobuckets_noop
expect_fail chk4 "the SHA256 gate is removed"                        m_break_sha_gate
expect_fail chk5 "the WELL-FORMED gate is removed"                   m_break_wellformed_gate
expect_fail chk7 "the edge-dedup is removed"                         m_break_dedup
expect_fail chk8 "install.sh no longer enables the timer"            m_break_install_enable
expect_fail chk9 "the runbook no longer documents the job"           m_break_runbook

echo "== Pristine repo (every check must PASS) =="
for c in chk1 chk2 chk3 chk4 chk5 chk6 chk7 chk8 chk9; do
  if bash "$CHECKS" "$c" "$REPO_ROOT" >/dev/null 2>&1; then
    ok "$c passes on the pristine repo"
  else
    bad "$c FAILED on the pristine repo (should pass)"
    bash "$CHECKS" "$c" "$REPO_ROOT" 2>&1 | sed 's/^/      | /'
  fi
done

echo
echo "self-test summary: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
echo "ALL SELF-TESTS PASSED"
