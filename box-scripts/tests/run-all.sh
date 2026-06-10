#!/usr/bin/env bash
#
# run-all.sh — run every box-scripts self-test.
#   * watcher-edges.sh always runs (CI-safe: no root, no real cluster/channel).
#   * restore-fleet.sh runs the destructive install/restore proof only on the
#     box with root+systemd+CONFIRM=1 (else it self-skips with exit code 77,
#     which is NOT treated as a failure here). Pass --yes / extra args through.
#
# Exit non-zero if any test that actually ran reported a failure.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
rc=0

echo "############ watcher-edges.sh ############"
bash "$HERE/watcher-edges.sh"; w=$?
[ "$w" -ne 0 ] && rc=1

echo
echo "############ restore-fleet.sh ############"
bash "$HERE/restore-fleet.sh" "$@"; r=$?
case "$r" in
  0)  ;;
  77) echo "(restore-fleet skipped — run on the box as: sudo CONFIRM=1 box-scripts/tests/run-all.sh)" ;;
  *)  rc=1 ;;
esac

echo
[ "$rc" -eq 0 ] && echo "ALL TESTS PASSED" || echo "TESTS FAILED"
exit "$rc"
