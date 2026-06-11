#!/usr/bin/env bash
#
# install-repo-sync-fleet.sh — extend the szl-box-sync fork-prevention guard to
# EVERY szl-holdings clone on the box, not just szl-uds-deployment.
#
#   sudo bash box-scripts/install-repo-sync-fleet.sh            # guard + verify (FF clean/behind clones in line)
#   ROOT=/opt/szl sudo bash box-scripts/install-repo-sync-fleet.sh
#   NO_FF=1 sudo bash box-scripts/install-repo-sync-fleet.sh    # only guard + verify, never fast-forward
#
# Background: the box working trees under /opt/szl/* are all clones of
# github.com/szl-holdings/* repos shared by unattended helpers and agents. The
# same "two copies drift into parallel histories" fork that hit szl-uds-deployment
# can recur for any of them once an agent commits on a stale clone. This installs
# the SAME pre-commit stale-tip guard (read-only fetch, refuses a commit that
# would fork) into each github clone so the whole box is consistently fork-proof.
#
# For each covered repo it:
#   1. installs the pre-commit guard into <repo>/.git/hooks/pre-commit
#   2. (unless NO_FF=1) fast-forwards the clone onto origin/main when it is
#      strictly BEHIND, the tree is clean, and it holds NO unique committed work
#      (the only safe, lossless case) so `verify` can pass
#   3. runs `szl-box-sync verify` (HEAD == ls-remote origin main)
#
# It NEVER force-resets a diverged/dirty tree or a clone holding unique work —
# those are reported for a human. Idempotent and fail-soft per repo.
#
# Deliberately STANDALONE (does not touch box-scripts/install.sh) so its delta is
# isolated to new files and lands on origin/main with a clean cherry-pick.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$HERE/sbin/szl-box-sync"
HOOKSRC="$HERE/hooks/pre-commit"
SBIN_DIR="${SBIN_DIR:-/usr/local/sbin}"
SHARE_DIR="${SHARE_DIR:-/usr/local/share/szl-box-sync}"
ROOT="${ROOT:-/opt/szl}"
NO_FF="${NO_FF:-0}"

# install-repo-sync.sh lays box-scripts/sbin + hooks next to it; tolerate being
# run from box-scripts/ where sbin/ and hooks/ are siblings.
[ -r "$SRC" ]     || SRC="$HERE/../sbin/szl-box-sync"
[ -r "$HOOKSRC" ] || HOOKSRC="$HERE/../hooks/pre-commit"
[ -r "$SRC" ]     || { echo "[fleet] missing szl-box-sync source near $HERE" >&2; exit 1; }
[ -r "$HOOKSRC" ] || { echo "[fleet] missing pre-commit hook source near $HERE" >&2; exit 1; }

# 1. command + a SHARED hook copy so `szl-box-sync install-hook` resolves the
#    hook source for clones that do not ship box-scripts/ themselves.
install -m 0755 "$SRC" "$SBIN_DIR/szl-box-sync"
echo "[fleet] installed $SBIN_DIR/szl-box-sync"
install -d "$SHARE_DIR"
install -m 0755 "$HOOKSRC" "$SHARE_DIR/pre-commit"
echo "[fleet] installed shared hook $SHARE_DIR/pre-commit"

BOXSYNC="$SBIN_DIR/szl-box-sync"

is_github_szl() {
  local url; url=$(git -C "$1" config --get remote.origin.url 2>/dev/null || true)
  case "$url" in *github.com[:/]szl-holdings/*) return 0 ;; *) return 1 ;; esac
}

guarded=0 ffd=0 verified=0 skipped=0 failed=0
declare -a NEED_ATTENTION=()

for d in "$ROOT"/*/; do
  d="${d%/}"
  [ -d "$d/.git" ] || continue
  name="$(basename "$d")"
  # skip throwaway / scratch clones (e.g. _t357_freshclone) and non-github (HF) trees
  case "$name" in _*|*.tmp|*-freshclone) echo "[fleet] skip $name (scratch clone)"; skipped=$((skipped+1)); continue ;; esac
  if ! is_github_szl "$d"; then
    echo "[fleet] skip $name (not a github.com/szl-holdings clone)"; skipped=$((skipped+1)); continue
  fi

  echo "[fleet] === $name ==="
  if SZL_BOX_SYNC_REPO="$d" "$BOXSYNC" install-hook 2>&1 | sed 's/^/[fleet]   /'; then
    guarded=$((guarded+1))
  else
    echo "[fleet]   WARN could not install guard for $name"; failed=$((failed+1)); NEED_ATTENTION+=("$name: guard-install-failed"); continue
  fi

  # read-only fetch to learn the true relation (public repo, no token)
  timeout 40 git -c safe.directory="$d" -C "$d" fetch -q origin main 2>/dev/null || \
    { echo "[fleet]   WARN fetch failed for $name (offline?) — skipping ff/verify"; NEED_ATTENTION+=("$name: fetch-failed"); continue; }
  h=$(git -C "$d" rev-parse HEAD 2>/dev/null)
  r=$(git -C "$d" rev-parse origin/main 2>/dev/null)
  dirty=$([ -n "$(git -C "$d" status --porcelain 2>/dev/null)" ] && echo 1 || echo 0)
  uniq=$(git -C "$d" cherry origin/main HEAD 2>/dev/null | grep -c '^+')

  if [ "$h" = "$r" ]; then
    rel=EQUAL
  elif git -C "$d" merge-base --is-ancestor "$h" "$r" 2>/dev/null; then
    rel=BEHIND
  elif git -C "$d" merge-base --is-ancestor "$r" "$h" 2>/dev/null; then
    rel=AHEAD
  else
    rel=DIVERGED
  fi

  if [ "$rel" = BEHIND ] && [ "$dirty" = 0 ] && [ "$uniq" = 0 ] && [ "$NO_FF" != 1 ]; then
    echo "[fleet]   BEHIND + clean + no unique work — fast-forwarding in line"
    if SZL_BOX_SYNC_REPO="$d" "$BOXSYNC" pull 2>&1 | sed 's/^/[fleet]   /'; then
      ffd=$((ffd+1))
    else
      echo "[fleet]   WARN fast-forward failed for $name"; NEED_ATTENTION+=("$name: ff-failed")
    fi
  elif [ "$rel" != EQUAL ]; then
    echo "[fleet]   NOT auto-reconciling ($rel, dirty=$dirty, unique=$uniq) — needs a human"
    NEED_ATTENTION+=("$name: $rel dirty=$dirty unique=$uniq")
  fi

  if SZL_BOX_SYNC_REPO="$d" "$BOXSYNC" verify >/dev/null 2>&1; then
    echo "[fleet]   verify: OK (HEAD == ls-remote origin main)"; verified=$((verified+1))
  else
    echo "[fleet]   verify: MISMATCH (not in line with origin/main)"; NEED_ATTENTION+=("$name: verify-mismatch")
  fi
done

echo
echo "[fleet] summary: guarded=$guarded fast-forwarded=$ffd verified=$verified skipped=$skipped failed=$failed"
if [ "${#NEED_ATTENTION[@]}" -gt 0 ]; then
  echo "[fleet] needs a human (NOT auto-changed):"
  for x in "${NEED_ATTENTION[@]}"; do echo "[fleet]   - $x"; done
fi
echo "[fleet] done. Re-check any time:  for d in $ROOT/*/; do SZL_BOX_SYNC_REPO=\"\${d%/}\" szl-box-sync verify; done"
