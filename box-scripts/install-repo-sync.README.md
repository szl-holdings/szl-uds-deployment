# box-sync — keep the box copy on one lineage with origin/main

The shared box working tree `167.233.50.75:/opt/szl/szl-uds-deployment` and
`origin/main` (`szl-holdings/szl-uds-deployment`) must stay on **one** lineage.
They have forked before: the *same* change gets committed locally on the box
**and** separately pushed to `main` as a *new* SHA, producing two parallel
histories of identical work. The root `BOX-SYNC.md` wrote the manual rule; this
helper **automates** it so nobody has to remember the recipe.

## Pieces

| File | Role |
|------|------|
| `sbin/szl-box-sync` | one-command `status` / `pull` / `push` / `verify` / `install-hook` |
| `hooks/pre-commit` | refuses a commit when the box base is stale (BEHIND/DIVERGED) |
| `install-repo-sync.sh` | installs the command + the hook (optional safe-pull timer) |
| `systemd/szl-box-sync-pull.{service,timer}` | conservative auto fast-forward |

## Install

```bash
sudo bash box-scripts/install-repo-sync.sh           # command + pre-commit hook
ENABLE_TIMER=1 sudo bash box-scripts/install-repo-sync.sh   # + safe auto-pull timer
```

## Daily use

- **Before editing / committing** the box is held to a fresh tip automatically:
  the `pre-commit` hook does a read-only `git fetch origin main` (the repo is
  public, no token needed) and **refuses** the commit if the box is BEHIND or
  DIVERGED, telling you to run `szl-box-sync pull` first. Bypass once with
  `SZL_BOX_SYNC_SKIP=1 git commit ...`.
- **Catch up:** `szl-box-sync pull` — fast-forwards when behind, resets when the
  box diverged but holds no unique committed work, refuses (without `--force`)
  when there is real unpushed work. Uncommitted tracked edits are stashed and
  re-applied; untracked files are left alone.
- **Ship a change in one command:** `szl-box-sync push -m "msg" [paths...]` —
  stages the delta, commits it, isolates that single commit onto freshly-fetched
  `origin/main` in a throwaway worktree, cherry-picks + pushes it, then resets
  the box back in line. This is the documented worktree-cherry-pick-push pattern
  wrapped up, so the box never keeps a parallel local SHA. Needs the org-owner
  push token (see below).
- **Verify one lineage:** `szl-box-sync verify` — exits 0 only when
  `git rev-parse HEAD` equals `git ls-remote origin main`.

## Push token

Read-only operations (`status`, `pull`, the hook's fetch) need **no** token —
the repo is public. Only `push` needs the org-owner token, resolved from the
first available of:

1. `$SZL_GITHUB_TOKEN`
2. `$SZL_GITHUB_TOKEN_FILE` (path to a file containing the token)
3. `/root/.szl-github-token`, `/etc/szl-github-token`, `/opt/szl/.szl-github-token`

The token is never printed or written by the script, and is scrubbed from git
output. It is **not** persisted on the box by this installer — supply it at push
time. The org-owner token bypasses `main` branch protection (verified signatures
+ PR + status checks), so the push lands directly.

## Why this is safe to automate

The `pull` command never pushes and never discards **unique** committed work
without `--force`; it only fast-forwards or resets a box that holds duplicates
already on `origin/main`. That is why the optional timer (which runs `pull`) is
safe to leave unattended. Pushing always isolates your delta in a throwaway
worktree built on the fresh remote tip, so a sibling commit sitting on top of
the box tip is never carried along.

This is the active counterpart to the `repo-drift` watcher
(`deploy/hetzner/repo-drift/`), which only *alerts* on an uncommitted tree —
box-sync actually keeps the committed lineage single.
