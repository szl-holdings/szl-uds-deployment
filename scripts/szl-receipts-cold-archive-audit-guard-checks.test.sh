# Copyright 2026 SZL Holdings
# SPDX-License-Identifier: Apache-2.0
#
# szl-receipts-cold-archive-audit-guard-checks.test.sh — negative-fixture
# self-test for scripts/szl-receipts-cold-archive-audit-guard-checks.sh.
#
# A guard is only worth running if it actually FAILS on a regression. This feeds
# each check a deliberately-BROKEN copy of the repo (one safety property neutered
# per fixture via a surgical sed) and asserts the matching check FAILS, then
# asserts the PRISTINE repo PASSES every check. If a future edit silently neuters
# a check so it can no longer detect its regression, THIS test goes red.
#
# It runs as the `self-test` job in szl-receipts-cold-archive-audit-guard.yml,
# gating the real guard job.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
CHECKS="$HERE/szl-receipts-cold-archive-audit-guard-checks.sh"

AUDIT_REL="box-scripts/sbin/szl-receipts-cold-archive-audit"
INSTALL_REL="box-scripts/install.sh"
RUNBOOK_REL="docs/operations/RECEIPT_STORE_RETENTION_RUNBOOK.md"

pass=0; fail=0
ok()   { echo "  PASS: $1"; pass=$((pass+1)); }
bad()  { echo "  FAIL: $1"; fail=$((fail+1)); }

# Build a working copy of the repo files the guard reads, into a temp root.
make_fixture() {
  local dir; dir="$(mktemp -d)"
  mkdir -p "$dir/box-scripts/sbin" "$dir/box-scripts" "$dir/docs/operations"
  cp "$REPO_ROOT/$AUDIT_REL"   "$dir/$AUDIT_REL"
  cp "$REPO_ROOT/$INSTALL_REL" "$dir/$INSTALL_REL"
  cp "$REPO_ROOT/$RUNBOOK_REL" "$dir/$RUNBOOK_REL"
  chmod +x "$dir/$AUDIT_REL" 2>/dev/null || true
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

# chk1: script gone entirely.
m_remove_script() { rm -f "$1/$AUDIT_REL"; }

# chk2: break the empty-cold-dir no-op — make that branch exit non-zero.
m_break_empty_noop() {
  sed -i '/no sealed buckets/{n;n;n;s/exit 0/exit 8/}' "$1/$AUDIT_REL"
}

# chk3: break the no-public-key no-op — make that branch exit non-zero.
m_break_nokey_noop() {
  sed -i '/no public key available to verify cold buckets/{n;s/exit 0/exit 7/}' "$1/$AUDIT_REL"
}

# chk4: neuter the failure path — make the failure branch unreachable (the
# verifier rc is never 999), so a real failure takes the OK branch and never pages.
m_break_fail_detect() {
  sed -i 's/if \[ "\$vrc" -ne 0 \]; then/if [ "$vrc" -eq 999 ]; then/' "$1/$AUDIT_REL"
}

# chk5: remove the edge-dedup — always notify on ALERT regardless of prev.
m_break_dedup() {
  sed -i 's/if \[ "\$prev" != "ALERT" \]; then/if true; then/' "$1/$AUDIT_REL"
}

# chk6: remove the RECOVERED edge — drop the recovery notify.
m_break_recovered() {
  sed -i '/EDGE ALERT->OK recovered/d; s/if \[ "\$prev" = "ALERT" \]; then/if false; then/' "$1/$AUDIT_REL"
}

# chk7: break the offline contract — append --tail-first-prev to the verify-cold
# invocation (make it depend on the live store).
m_break_offline() {
  sed -i 's/--pubkey-hex "\$pubkey_hex" >"\$out"/--pubkey-hex "$pubkey_hex" --tail-first-prev deadbeef >"$out"/' "$1/$AUDIT_REL"
}

# chk8: un-wire the timer enable in install.sh.
m_break_install_enable() {
  sed -i 's/systemctl enable --now szl-receipts-cold-archive-audit\.timer/# UNWIRED for test/' "$1/$INSTALL_REL"
}

# chk9: remove the runbook's mention of the job.
m_break_runbook() {
  sed -i 's/szl-receipts-cold-archive-audit/REMOVED-AUDIT-NAME/g' "$1/$RUNBOOK_REL"
}

echo "== Negative fixtures (each check must FAIL on its regression) =="
expect_fail chk1 "the audit script is missing"                       m_remove_script
expect_fail chk2 "the empty-cold-dir no-op is broken"                m_break_empty_noop
expect_fail chk3 "the no-public-key no-op is broken"                 m_break_nokey_noop
expect_fail chk4 "the failure-detection path is neutered"            m_break_fail_detect
expect_fail chk5 "the edge-dedup is removed"                         m_break_dedup
expect_fail chk6 "the RECOVERED edge is removed"                     m_break_recovered
expect_fail chk7 "the offline (public-key-only) contract is broken"  m_break_offline
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
