# Copyright 2026 SZL Holdings
# SPDX-License-Identifier: Apache-2.0
#
# bundle-digest-recut-guard-checks.sh - guard the `bundle-digest-recut` box
# healer (the AUTO-re-cut-stale-airgap-tarball healer) from silently regressing.
#
# WHY THIS EXISTS
# bundle-digest-watch (box-scripts/sbin/bundle-digest-watch) ALARMS when a local
# airgap deploy tarball bakes a stale szl-receipts image digest;
# bundle-digest-recut (box-scripts/sbin/bundle-digest-recut) HEALS it by re-cutting
# the receipts package + UDS bundle so the new source-pinned digest is baked in,
# WITHOUT bumping metadata.version. Its value rests on a few fragile invariants
# that produce NO symptom when broken (a stale tarball just keeps shipping):
#   * it still extracts the SOURCE-pinned digest from the szl-receipts zarf manifest
#     (the source of truth it heals toward);
#   * it still performs the RECEIPTS-ONLY re-cut (zarf package create + uds create);
#   * it still VERIFIES the re-cut took (new digest present, old gone);
#   * it never bumps metadata.version (it asserts the version is UNCHANGED);
#   * it keeps its SAFETY gates (kill switch + report mode + disk pre-flight) so a
#     heavy `uds create` can never fill the box or run when held;
#   * it stays WIRED into install.sh (script + units copied, timer enabled) and
#     documented, or a box rebuild silently ships without the healer.
# This guard is a pure text/lint check (no cluster, no tarball) asserting each.
#
# The check logic is extracted here (out of the workflow) so it can be UNIT
# TESTED: bundle-digest-recut-guard-checks.test.sh feeds each check a
# deliberately-BROKEN fixture and asserts the check FAILS (plus that the pristine
# repo PASSES). A future edit that neuters a check - green while guarding nothing
# - is caught by that self-test, not in production.
#
# Usage:
#   bundle-digest-recut-guard-checks.sh <check> [root]
#     check : chk1 | chk2 | chk3 | chk4 | chk5 | chk6 | chk7 | chk8 | all
#     root  : repo root to check (default: current directory)

set -uo pipefail

err() { echo "::error file=$1::$2"; }

RECUT_REL="box-scripts/sbin/bundle-digest-recut"
INSTALL_REL="box-scripts/install.sh"
README_REL="box-scripts/README.md"
RECUT_README_REL="box-scripts/bundle-digest-recut.README.md"
SVC_REL="box-scripts/systemd/bundle-digest-recut.service"
TIMER_REL="box-scripts/systemd/bundle-digest-recut.timer"

# Check 1 - the healer script exists, parses clean (bash -n), and so do its units.
chk1() {
  local root="${1:-.}"; local F="$root/$RECUT_REL"; local rc=0
  test -f "$F" || { err "$F" "REGRESSION - bundle-digest-recut is MISSING. The auto-recut healer is gone."; return 1; }
  bash -n "$F" 2>/dev/null || { err "$F" "REGRESSION - bundle-digest-recut does not parse (bash -n failed)."; rc=1; }
  test -f "$root/$SVC_REL" || { err "$root/$SVC_REL" "REGRESSION - bundle-digest-recut.service unit is missing."; rc=1; }
  test -f "$root/$TIMER_REL" || { err "$root/$TIMER_REL" "REGRESSION - bundle-digest-recut.timer unit is missing."; rc=1; }
  return $rc
}

# Check 2 - extracts the SOURCE-pinned image digest from the szl-receipts zarf
# manifest (the source of truth it heals toward).
chk2() {
  local root="${1:-.}"; local F="$root/$RECUT_REL"; local rc=0
  test -f "$F" || { err "$F" "missing bundle-digest-recut"; return 1; }
  grep -q 'extract_pinned_digest' "$F" || { err "$F" "REGRESSION - no extract_pinned_digest: the source pin is no longer read."; rc=1; }
  grep -q 'packages/szl-receipts/zarf.yaml' "$F" || { err "$F" "REGRESSION - the source pin file (packages/szl-receipts/zarf.yaml) is no longer referenced."; rc=1; }
  grep -Eq 'sha256:\[0-9a-f\]\{64\}' "$F" || { err "$F" "REGRESSION - the 64-hex sha256 digest pattern is gone; the pin can no longer be parsed."; rc=1; }
  return $rc
}

# Check 3 - performs the RECEIPTS-ONLY re-cut (zarf package create + uds create).
chk3() {
  local root="${1:-.}"; local F="$root/$RECUT_REL"; local rc=0
  test -f "$F" || { err "$F" "missing bundle-digest-recut"; return 1; }
  grep -q 'zarf package create packages/szl-receipts' "$F" || { err "$F" "REGRESSION - the receipts zarf package re-cut step is gone."; rc=1; }
  grep -q -- '--flavor' "$F" || { err "$F" "REGRESSION - --flavor dropped: the receipts package would build the wrong (non-flavored) ref."; rc=1; }
  grep -Eq 'uds create \.' "$F" || { err "$F" "REGRESSION - the 'uds create .' bundle re-cut step is gone."; rc=1; }
  grep -q -- '--skip-signature-validation' "$F" || { err "$F" "REGRESSION - --skip-signature-validation dropped: uds create would reject the keyless-signed init/core."; rc=1; }
  return $rc
}

# Check 4 - VERIFIES the re-cut took: new digest present AND old digest gone in
# the rebuilt tarballs.
chk4() {
  local root="${1:-.}"; local F="$root/$RECUT_REL"; local rc=0
  test -f "$F" || { err "$F" "missing bundle-digest-recut"; return 1; }
  grep -q 'tarball_has_digest' "$F" || { err "$F" "REGRESSION - tarball_has_digest gone: the re-cut is no longer verified against the built tarballs."; rc=1; }
  grep -q 'zstd -dc' "$F" || { err "$F" "REGRESSION - zstd -dc gone: the .tar.zst tarball can no longer be read for verification."; rc=1; }
  grep -q 'old_digest' "$F" || { err "$F" "REGRESSION - old_digest gone: the 'old digest is gone' half of verification is no longer checked."; rc=1; }
  grep -Eq 'VERIFY-FAIL|verify_fail' "$F" || { err "$F" "REGRESSION - the post-recut verification-failure path is gone; a no-op re-cut would report success."; rc=1; }
  return $rc
}

# Check 5 - never bumps metadata.version (asserts the version is UNCHANGED).
chk5() {
  local root="${1:-.}"; local F="$root/$RECUT_REL"; local rc=0
  test -f "$F" || { err "$F" "missing bundle-digest-recut"; return 1; }
  grep -q 'version_fingerprint' "$F" || { err "$F" "REGRESSION - version_fingerprint gone: a re-cut that bumps metadata.version is no longer caught."; rc=1; }
  grep -Eq 'ver_before' "$F" || { err "$F" "REGRESSION - the before/after metadata.version comparison is gone."; rc=1; }
  grep -Eq 'metadata.version (CHANGED|UNCHANGED|unchanged)' "$F" || { err "$F" "REGRESSION - the metadata.version-unchanged invariant message/guard is gone."; rc=1; }
  return $rc
}

# Check 6 - keeps its SAFETY gates: kill switch + report mode + disk pre-flight.
chk6() {
  local root="${1:-.}"; local F="$root/$RECUT_REL"; local rc=0
  test -f "$F" || { err "$F" "missing bundle-digest-recut"; return 1; }
  grep -q 'BUNDLE_RECUT_ENABLED' "$F" || { err "$F" "REGRESSION - the BUNDLE_RECUT_ENABLED kill switch is gone."; rc=1; }
  grep -q 'KILL_FILE' "$F" || { err "$F" "REGRESSION - the KILL_FILE kill switch is gone."; rc=1; }
  grep -q 'RECUT_MODE' "$F" || { err "$F" "REGRESSION - the RECUT_MODE (apply|report) gate is gone."; rc=1; }
  grep -q 'MIN_FREE_GB' "$F" || { err "$F" "REGRESSION - the MIN_FREE_GB disk pre-flight is gone; a re-cut could fill the box."; rc=1; }
  grep -q 'flock' "$F" || { err "$F" "REGRESSION - the flock single-flight lock is gone; concurrent re-cuts could collide."; rc=1; }
  return $rc
}

# Check 7 - wired into install.sh (script + both units copied, timer enabled).
chk7() {
  local root="${1:-.}"; local F="$root/$INSTALL_REL"; local rc=0
  test -f "$F" || { err "$F" "missing install.sh"; return 1; }
  grep -Eq 'install -m 0755 "\$here/sbin/bundle-digest-recut"' "$F" || { err "$F" "REGRESSION - install.sh no longer copies the bundle-digest-recut sbin script."; rc=1; }
  grep -q 'systemd/bundle-digest-recut.service' "$F" || { err "$F" "REGRESSION - install.sh no longer installs bundle-digest-recut.service."; rc=1; }
  grep -q 'systemd/bundle-digest-recut.timer' "$F" || { err "$F" "REGRESSION - install.sh no longer installs bundle-digest-recut.timer."; rc=1; }
  grep -q 'systemctl enable --now bundle-digest-recut.timer' "$F" || { err "$F" "REGRESSION - install.sh no longer enables bundle-digest-recut.timer; the healer never runs."; rc=1; }
  return $rc
}

# Check 8 - documented (its own README + a mention in box-scripts/README.md).
chk8() {
  local root="${1:-.}"; local rc=0
  test -f "$root/$RECUT_README_REL" || { err "$root/$RECUT_README_REL" "REGRESSION - the bundle-digest-recut.README.md procedure doc is missing."; rc=1; }
  test -f "$root/$README_REL" || { err "$root/$README_REL" "missing README.md"; return 1; }
  grep -q 'bundle-digest-recut' "$root/$README_REL" || { err "$root/$README_REL" "REGRESSION - README.md no longer documents the bundle-digest-recut healer."; rc=1; }
  return $rc
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
case "${1:-all}" in
  chk1) chk1 "${2:-.}" ;;
  chk2) chk2 "${2:-.}" ;;
  chk3) chk3 "${2:-.}" ;;
  chk4) chk4 "${2:-.}" ;;
  chk5) chk5 "${2:-.}" ;;
  chk6) chk6 "${2:-.}" ;;
  chk7) chk7 "${2:-.}" ;;
  chk8) chk8 "${2:-.}" ;;
  all)
    rc=0
    for c in chk1 chk2 chk3 chk4 chk5 chk6 chk7 chk8; do "$c" "${2:-.}" || rc=1; done
    exit $rc
    ;;
  *) echo "unknown check: $1" >&2; exit 2 ;;
esac
fi
