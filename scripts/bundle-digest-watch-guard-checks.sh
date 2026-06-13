# Copyright 2026 SZL Holdings
# SPDX-License-Identifier: Apache-2.0
#
# bundle-digest-watch-guard-checks.sh - guard the `bundle-digest-watch` box alarm
# (the stale-image-digest-in-a-local-tarball alarm) from silently regressing.
#
# WHY THIS EXISTS
# scripts/pin-receipts-image-digest.sh repins the SOURCE digest and the package is
# re-signed, but the local airgap tarballs already cut on the box
#   - uds-bundle-szl-receipts-bundle-<arch>-<ver>.tar.zst
#   - packages/szl-receipts/zarf-package-szl-receipts-<arch>-<ver>.tar.zst
# keep baking whatever digest was current when they were last built. A same-tag
# rebuild re-mints a new digest, so a stale tarball can sit on disk and ship the
# OLD image with NO visible symptom. bundle-digest-watch
# (box-scripts/sbin/bundle-digest-watch) runs periodically and pages the moment a
# built tarball stops carrying the source-pinned digest. Its value rests on a few
# fragile invariants that produce no symptom when broken until a stale tarball
# ships unflagged:
#   * it still extracts the SOURCE-pinned image digest from the szl-receipts zarf
#     manifest (the source of truth the tarball is compared against);
#   * it still inspects the BUILT tarballs by listing them (zstd -dc | tar -t) and
#     looking for that digest in both the bundle and the package tarball;
#   * it is EDGE-triggered (reads + writes a last_status state file) so it pages
#     exactly once on OK->ALERT and once on RECOVERED, never every cycle;
#   * it NO-OPs (exit 0, no page) when the source pin is unreadable or NO tarball
#     has been built yet (nothing to compare = nothing stale);
#   * it stays WIRED into install.sh (script + units copied, timer enabled) and
#     documented in README.md, or a box rebuild silently ships without the alarm.
# This guard is a pure text/lint check (no cluster, no tarball) asserting each.
#
# The check logic is extracted here (out of the workflow) so it can be UNIT
# TESTED: bundle-digest-watch-guard-checks.test.sh feeds each check a
# deliberately-BROKEN fixture and asserts the check FAILS (plus that the pristine
# repo PASSES). A future edit that neuters a check - green while guarding nothing
# - is caught by that self-test, not in production.
#
# Usage:
#   bundle-digest-watch-guard-checks.sh <check> [root]
#     check : chk1 | chk2 | chk3 | chk4 | chk5 | chk6 | chk7 | all
#     root  : repo root to check (default: current directory)

set -uo pipefail

err() { echo "::error file=$1::$2"; }

WATCH_REL="box-scripts/sbin/bundle-digest-watch"
INSTALL_REL="box-scripts/install.sh"
README_REL="box-scripts/README.md"

# Check 1 - the alarm script exists and parses clean under bash -n.
chk1() {
  local root="${1:-.}"; local F="$root/$WATCH_REL"
  test -f "$F" || { err "$F" "REGRESSION - bundle-digest-watch is MISSING. The stale-tarball-digest alarm is gone."; return 1; }
  bash -n "$F" 2>/dev/null || { err "$F" "REGRESSION - bundle-digest-watch does not parse (bash -n failed)."; return 1; }
  return 0
}

# Check 2 - extracts the SOURCE-pinned image digest from the szl-receipts zarf
# manifest (the source of truth the built tarball is measured against).
chk2() {
  local root="${1:-.}"; local F="$root/$WATCH_REL"; local rc=0
  test -f "$F" || { err "$F" "missing bundle-digest-watch"; return 1; }
  grep -q 'extract_pinned_digest' "$F" || { err "$F" "REGRESSION - no extract_pinned_digest: the source pin is no longer read."; rc=1; }
  grep -q 'packages/szl-receipts/zarf.yaml' "$F" || { err "$F" "REGRESSION - the source pin file (packages/szl-receipts/zarf.yaml) is no longer referenced."; rc=1; }
  grep -Eq 'sha256:\[0-9a-f\]\{64\}' "$F" || { err "$F" "REGRESSION - the 64-hex sha256 digest pattern is gone; the pin can no longer be parsed."; rc=1; }
  return $rc
}

# Check 3 - inspects the BUILT tarballs by listing them and looking for the digest
# in BOTH the bundle and the package tarball.
chk3() {
  local root="${1:-.}"; local F="$root/$WATCH_REL"; local rc=0
  test -f "$F" || { err "$F" "missing bundle-digest-watch"; return 1; }
  grep -q 'tarball_has_digest' "$F" || { err "$F" "REGRESSION - tarball_has_digest gone: built tarballs are no longer inspected."; rc=1; }
  grep -q 'zstd -dc' "$F" || { err "$F" "REGRESSION - zstd -dc gone: the .tar.zst tarball can no longer be read."; rc=1; }
  grep -q 'tar -t' "$F" || { err "$F" "REGRESSION - tar -t gone: the tarball listing is no longer scanned for the digest."; rc=1; }
  grep -q 'uds-bundle-szl-receipts-bundle' "$F" || { err "$F" "REGRESSION - the bundle tarball glob is no longer watched."; rc=1; }
  grep -q 'zarf-package-szl-receipts' "$F" || { err "$F" "REGRESSION - the package tarball glob is no longer watched."; rc=1; }
  return $rc
}

# Check 4 - edge-triggered: reads + writes the last_status state file and makes
# EXACTLY TWO notify calls (one OK->ALERT, one RECOVERED).
chk4() {
  local root="${1:-.}"; local F="$root/$WATCH_REL"; local rc=0
  test -f "$F" || { err "$F" "missing bundle-digest-watch"; return 1; }
  grep -q 'cat "\$LAST_FILE"' "$F" || { err "$F" "REGRESSION - last_status state file is no longer READ; de-dup is broken (re-pages every cycle)."; rc=1; }
  grep -Eq '>"\$LAST_FILE"' "$F" || { err "$F" "REGRESSION - last_status state file is no longer WRITTEN; de-dup is broken."; rc=1; }
  local n; n="$(grep -cE '^[[:space:]]*notify "' "$F")"
  if [ "$n" -ne 2 ]; then
    err "$F" "REGRESSION - expected EXACTLY 2 notify call sites (OK->ALERT + RECOVERED), found $n. Edge-triggered paging is broken."
    rc=1
  fi
  return $rc
}

# Check 5 - no-op (exit 0, UNKNOWN) when the source pin is unreadable or NO
# tarball has been built (nothing to compare = nothing stale).
chk5() {
  local root="${1:-.}"; local F="$root/$WATCH_REL"; local rc=0
  test -f "$F" || { err "$F" "missing bundle-digest-watch"; return 1; }
  local n; n="$(grep -cE 'write_status UNKNOWN' "$F")"
  if [ "$n" -lt 2 ]; then
    err "$F" "REGRESSION - expected >=2 UNKNOWN no-op paths (pin-unreadable + no-tarball), found $n. A missing pin/tarball may now page falsely."
    rc=1
  fi
  grep -q 'no built tarball present' "$F" || { err "$F" "REGRESSION - the no-tarball-built no-op path is gone."; rc=1; }
  return $rc
}

# Check 6 - wired into install.sh (script + both units copied, timer enabled).
chk6() {
  local root="${1:-.}"; local F="$root/$INSTALL_REL"; local rc=0
  test -f "$F" || { err "$F" "missing install.sh"; return 1; }
  grep -Eq 'install -m 0755 "\$here/sbin/bundle-digest-watch"' "$F" || { err "$F" "REGRESSION - install.sh no longer copies the bundle-digest-watch sbin script."; rc=1; }
  grep -q 'systemd/bundle-digest-watch.service' "$F" || { err "$F" "REGRESSION - install.sh no longer installs bundle-digest-watch.service."; rc=1; }
  grep -q 'systemd/bundle-digest-watch.timer' "$F" || { err "$F" "REGRESSION - install.sh no longer installs bundle-digest-watch.timer."; rc=1; }
  grep -q 'systemctl enable --now bundle-digest-watch.timer' "$F" || { err "$F" "REGRESSION - install.sh no longer enables bundle-digest-watch.timer; the alarm never runs."; rc=1; }
  return $rc
}

# Check 7 - documented in README.md.
chk7() {
  local root="${1:-.}"; local F="$root/$README_REL"
  test -f "$F" || { err "$F" "missing README.md"; return 1; }
  grep -q 'bundle-digest-watch' "$F" || { err "$F" "REGRESSION - README.md no longer documents the bundle-digest-watch alarm."; return 1; }
  return 0
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
  all)
    rc=0
    for c in chk1 chk2 chk3 chk4 chk5 chk6 chk7; do "$c" "${2:-.}" || rc=1; done
    exit $rc
    ;;
  *) echo "unknown check: $1" >&2; exit 2 ;;
esac
fi
