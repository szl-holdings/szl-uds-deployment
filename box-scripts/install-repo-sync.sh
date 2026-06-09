#!/usr/bin/env bash
#
# install-repo-sync.sh — install the box<->origin/main auto-sync helper for
# szl-holdings/szl-uds-deployment on Stephen's box (167.233.50.75).
#
#   sudo bash box-scripts/install-repo-sync.sh
#
# Installs two things, idempotently:
#   1. `szl-box-sync` -> /usr/local/sbin/szl-box-sync   (one-command pull/push/verify)
#   2. the pre-commit stale-tip guard into <repo>/.git/hooks/pre-commit
#
# Optionally enables a conservative timer that fast-forwards the box onto
# origin/main only when it is strictly BEHIND and the tree is clean (never on a
# diverged/dirty tree). Enable with:  ENABLE_TIMER=1 sudo bash ...
#
# Deliberately STANDALONE (does not touch box-scripts/install.sh) so its delta is
# isolated to new files and lands on origin/main with a clean cherry-pick.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$HERE/sbin/szl-box-sync"
HOOKSRC="$HERE/hooks/pre-commit"
SBIN_DIR="${SBIN_DIR:-/usr/local/sbin}"
UNIT_DIR="${UNIT_DIR:-/etc/systemd/system}"
REPO="${SZL_BOX_SYNC_REPO:-/opt/szl/szl-uds-deployment}"
ENABLE_TIMER="${ENABLE_TIMER:-0}"

[ -r "$SRC" ]     || { echo "[install] missing $SRC" >&2; exit 1; }
[ -r "$HOOKSRC" ] || { echo "[install] missing $HOOKSRC" >&2; exit 1; }

install -m 0755 "$SRC" "$SBIN_DIR/szl-box-sync"
echo "[install] installed $SBIN_DIR/szl-box-sync"

if [ -d "$REPO/.git" ]; then
  install -m 0755 "$HOOKSRC" "$REPO/.git/hooks/pre-commit"
  echo "[install] installed pre-commit guard at $REPO/.git/hooks/pre-commit"
else
  echo "[install] WARN repo not found at $REPO — skipped hook (set SZL_BOX_SYNC_REPO)"
fi

if [ "$ENABLE_TIMER" = "1" ]; then
  install -m 0644 "$HERE/systemd/szl-box-sync-pull.service" "$UNIT_DIR/szl-box-sync-pull.service"
  install -m 0644 "$HERE/systemd/szl-box-sync-pull.timer"   "$UNIT_DIR/szl-box-sync-pull.timer"
  systemctl daemon-reload
  systemctl enable --now szl-box-sync-pull.timer
  echo "[install] enabled szl-box-sync-pull.timer (safe fast-forward when behind+clean)"
else
  echo "[install] timer NOT enabled (re-run with ENABLE_TIMER=1 to enable safe auto-pull)"
fi

echo "[install] done. Try:  szl-box-sync status   /   szl-box-sync verify"
