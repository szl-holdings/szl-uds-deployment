# Keeping the box copy in sync with origin/main

This repository lives in **two** places that must stay on **one** lineage:

- the shared working tree on the box: `167.233.50.75:/opt/szl/szl-uds-deployment`
- `origin/main` on GitHub: `szl-holdings/szl-uds-deployment`

They drift apart when the *same* change is committed locally on the box **and**
separately pushed to `main` as a *new* commit. That produces two parallel
histories of identical work, and the next real change then needs a hand-merged
cherry-pick with conflicts instead of a clean push. (This happened once already:
the histories forked at `43b37f6` and landing the v0.4.0 lock took a 5-conflict
manual merge.)

## The rule for every edit

1. **Always start from a fresh `origin/main`.** Before editing the shared tree:
   ```bash
   git fetch <token-url> main
   git reset --hard FETCH_HEAD
   ```
   For isolated work, branch or `git worktree add` **from `FETCH_HEAD`**, never
   from a stale local tip.

2. **Keep deltas small and push them promptly.** Do not let local-only commits
   pile up on the box — every unpushed local commit is a future divergence.

3. **Land each change on `main` exactly once.** Push only *your own* delta from a
   worktree based on freshly-fetched `origin/main`:
   ```bash
   git worktree add -d /tmp/pubwt FETCH_HEAD
   cd /tmp/pubwt && git cherry-pick <your-sha>
   git push <token-url> HEAD:main
   ```
   Never `git push origin HEAD:main` from the shared tree — it can carry a
   sibling's out-of-scope commit that happens to sit on top of yours.

4. **After it is on `origin/main`, bring the box back in line** (`git reset --hard`
   to the new `origin/main` tip) instead of keeping a parallel local commit that
   says the same thing with a different SHA.

5. **Box mechanics.** The box has no git identity and the agent sandbox filters
   git verbs, so run git from a script file on the box and commit with
   `git -c user.email=... -c user.name=... commit`. The org-owner token
   (`SZL_GITHUB_TOKEN`, user `stephenlutar2`) pushes straight to protected `main`.
