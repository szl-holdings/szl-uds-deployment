# szl-box-sync-conflict-watch — auto-sync conflict / retained-stash alarm

Alerts when the box `szl-uds-deployment` auto-sync (`szl-box-sync` /
`szl-box-sync-pull.timer`) could **not** cleanly reconcile the shared tree with
`origin/main` and has left it in a **silent, half-merged state**.

## The problem it solves

`szl-box-sync-pull.timer` fast-forwards `/opt/szl/szl-uds-deployment` onto
`origin/main` every ~15 min. The reconcile (`szl-box-sync`'s `reset_in_line`) is
**non-destructive**: when a sibling has uncommitted **tracked** edits that *also*
changed on origin, the run still fast-forwards but the stash pop conflicts,
leaving:

* **UU (unmerged) paths** in the working tree, and
* the sibling's edit preserved in a **`szl-box-sync autostash <ts>`** stash.

No work is lost — but the state is **silent**. Nobody is told the tree is
conflict-marked and that a sibling's work is sitting in a stash. Across many
15-min cycles the stashes accumulate and the tree stays confusingly half-merged.
This watcher makes that loud.

## What it detects (any one → ALERT)

* one or more **unmerged (UU) paths** — `git ls-files -u`
* one or more **retained `szl-box-sync autostash` stash entries** —
  `git stash list` filtered to the autostash label (`STASH_MATCH`, default
  `szl-box-sync autostash`). Unrelated **manual** stashes are deliberately
  ignored so they never trip the alarm.

## What it never does

It is **read-only**. It never pops, drops, clears, resets, checks out, merges, or
`rm`s anything. Resolving the conflict and clearing the stash is a deliberate
human (or dedicated task) decision; this watcher only reports. The alert text
explicitly says **do not blind-drop** and points at `szl-box-sync status` /
`git status` / `git stash list`.

## Edge-triggered (no spam)

Alerts only on the healthy→conflict **edge** (transition de-dup via an md5
signature file), and once on **RECOVERED** when the tree is clean again. A
persisting conflict is logged, not re-paged, so it respects the
"recurring alerts = owner only" policy by construction.

## Files

```
box-scripts/
  sbin/szl-box-sync-conflict-watch                 # the alarm (read-only)
  systemd/szl-box-sync-conflict-watch.service      # oneshot: runs it (+ notifier env)
  systemd/szl-box-sync-conflict-watch.timer        # ~7 min after boot, then every 15 min
```

State / output (on the box):

```
/var/lib/szl-box-sync-conflict/status.json         # machine-readable last result
/var/lib/szl-box-sync-conflict/problem.sig         # edge-dedup signature
/var/log/szl-box-sync-conflict/szl-box-sync-conflict.log
```

## Notification channel

Real push notifications use the **same** notifier and credentials file as the
a11oy-uptime monitor: `/usr/local/sbin/a11oy-uptime-notify`, reading its channel
from `/etc/a11oy-uptime.env` (ntfy / Telegram / Slack-Discord webhook). The
notifier is fail-soft — with no channel configured the watcher still runs and the
edge is recorded in the log. See `dns-drift-check` / the a11oy-uptime README for
how to restore the channel.

## Reinstall (after a box rebuild / reimage)

Installed by `box-scripts/install.sh` (script + units + `systemctl enable --now`
the timer). It also runs once immediately. Manual equivalent:

```bash
sudo install -m 0755 sbin/szl-box-sync-conflict-watch /usr/local/sbin/szl-box-sync-conflict-watch
sudo install -m 0644 systemd/szl-box-sync-conflict-watch.service /etc/systemd/system/
sudo install -m 0644 systemd/szl-box-sync-conflict-watch.timer   /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now szl-box-sync-conflict-watch.timer
sudo /usr/local/sbin/szl-box-sync-conflict-watch
```

`szl-box-sync-pull.service` also carries an `ExecStartPost` hook that starts this
watcher right after every pull, so a conflict is surfaced on the same cycle that
created it.

## Verify

```bash
systemctl is-enabled szl-box-sync-conflict-watch.timer
sudo /usr/local/sbin/szl-box-sync-conflict-watch
cat /var/lib/szl-box-sync-conflict/status.json
```

## Tests

* `box-scripts/tests/watcher-edges.sh` drives this watcher's healthy→ALERT edge
  against a throwaway git repo with a real UU + a real `szl-box-sync autostash`
  stash, through a capture-stub notifier, and asserts it fires once and de-dups
  the second run.
* `scripts/szl-box-sync-conflict-watch-guard-checks.sh` (+ `.test.sh`) is the
  text/lint guard trio asserting the alarm's invariants stay intact.
