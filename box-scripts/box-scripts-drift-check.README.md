# box-scripts-drift-check — keep host helper scripts in sync with the repo

The box (167.233.50.75) runs host-level helper scripts under `/usr/local/sbin`
and their systemd units under `/etc/systemd/system`. Their canonical copies are
committed in this repo under `box-scripts/sbin/` and `box-scripts/systemd/`, but
the host paths live **outside any git checkout**, so a hand-edit on the box can
silently diverge from the committed copy. The `BOX-SYNC` rule only protects the
git working tree, not these host files.

`box-scripts-drift-check` byte-compares each watched live file against its
committed `box-scripts/` copy and **alerts on drift** so the repo copy stays the
real source of truth. By default it only reports — it never auto-reinstalls.
An opt-in self-heal mode (`SELF_HEAL=1`, default off) can additionally restore a
drifted host file from its committed copy on the drift edge (see below).

## What it watches (default)

| live path | committed copy |
|---|---|
| `/usr/local/sbin/a11oy-uptime-check`  | `box-scripts/sbin/a11oy-uptime-check` |
| `/usr/local/sbin/a11oy-uptime-notify` | `box-scripts/sbin/a11oy-uptime-notify` |
| `/usr/local/sbin/dns-drift-check`     | `box-scripts/sbin/dns-drift-check` |
| `/etc/systemd/system/a11oy-uptime-check.service` | `box-scripts/systemd/a11oy-uptime-check.service` |
| `/etc/systemd/system/a11oy-uptime-check.timer`   | `box-scripts/systemd/a11oy-uptime-check.timer` |
| `/etc/systemd/system/dns-drift-check.service`    | `box-scripts/systemd/dns-drift-check.service` |
| `/etc/systemd/system/dns-drift-check.timer`      | `box-scripts/systemd/dns-drift-check.timer` |

Override the set with `WATCH_SBIN` / `WATCH_UNITS` (space-separated basenames).

Per-file status: `MATCH`, `DRIFT` (both exist but differ), `LIVE-MISSING`
(committed copy exists, host file gone), `REPO-MISSING` (host file exists,
committed copy gone).

## Alerting

Edge-triggered: one push on the healthy→drift edge (de-duped via an md5
signature of the drift set), `RECOVERED` when all match again. Reuses the shared
`a11oy-uptime-notify` channel (ntfy / Telegram / webhook) via `NOTIFY_CMD` +
`EnvironmentFile=-/etc/a11oy-uptime.env`, exactly like the dns-drift and
repo-drift watchers. No SMS/email (TCP 465 firewalled). Log-friendly:
`/var/log/box-scripts-drift/box-scripts-drift.log` + machine-readable
`/var/lib/box-scripts-drift/status.json`.

## Self-heal (opt-in, OFF by default)

With `SELF_HEAL=1` the watcher, on the **healthy→drift edge**, re-installs each
drifted host file from its committed `box-scripts/` copy (`install -m`, scripts
`0755` / units `0644`) and — if any **unit** was re-installed — runs
`systemctl daemon-reload`. It then pushes a **REPAIRED** notification (distinct
from the `RECOVERED` that fires when a drift simply clears on its own) and
records the outcome in `status.json` (`self_heal.last_result`) +
`/var/lib/box-scripts-drift/heal-last.txt`. The drift edge alert still fires
(it reads "auto-repairing now…") so the human still sees the event.

- It is **OFF by default** because a host edit may be a deliberate hot-fix that
  should be **back-ported to the repo**, not clobbered. Turn it on only when the
  committed copy is the unambiguous source of truth (e.g. add `Environment=SELF_HEAL=1`
  to `box-scripts/systemd/box-scripts-drift-check.service`).
- A drift whose committed source is **gone** (`REPO-MISSING` / `BOTH-MISSING`)
  cannot be restored and is reported as **un-healable** — the host file is left
  untouched.
- A drift that is still present after a heal (an un-healable file, or `install`
  repeatedly failing) is retried at most once every `HEAL_RETRY_SECS`
  (default 3600s) so it never loops.
- With `SELF_HEAL=0` (the default) the detection + alert + edge/de-dup behaviour
  is exactly the original report-only path.

## Install / restore

Installed by `box-scripts/install.sh` (idempotent). The timer runs every 15 min
after a 6-min boot delay.

## Reconciling a reported drift

- If the **live edit is intended**: copy the host file back into `box-scripts/`
  and commit it (the repo copy must follow the source of truth).
- If the **repo copy is correct**: re-run `sudo box-scripts/install.sh` to push
  the committed copy back onto the host (or enable `SELF_HEAL=1` so the watcher
  auto-restores it on the next drift edge).

## Test (no real alert, no root)

Point every path at a throwaway tree and stub the notifier. Detection-only:

```bash
T=$(mktemp -d)
mkdir -p "$T/repo/.git" "$T/repo/box-scripts/sbin" "$T/repo/box-scripts/systemd" \
         "$T/sbin" "$T/units" "$T/state" "$T/log"
printf 'echo committed v1\n'                 > "$T/repo/box-scripts/sbin/demo-script"
printf '[Unit]\nDescription=demo v1\n'        > "$T/repo/box-scripts/systemd/demo.service"
cp "$T/repo/box-scripts/sbin/demo-script"      "$T/sbin/demo-script"
cp "$T/repo/box-scripts/systemd/demo.service"  "$T/units/demo.service"

run() {
  REPO="$T/repo" BOX_SCRIPTS="$T/repo/box-scripts" SBIN_DIR="$T/sbin" UNIT_DIR="$T/units" \
  STATE_DIR="$T/state" LOG_DIR="$T/log" LOG="$T/log/x.log" STATUS="$T/state/status.json" \
  SIG_FILE="$T/state/problem.sig" HEAL_TS_FILE="$T/state/heal-last.ts" \
  HEAL_RESULT_FILE="$T/state/heal-last.txt" \
  WATCH_SBIN="demo-script" WATCH_UNITS="demo.service" \
  ALERT_PREFIX="[TEST-ignore] " NOTIFY_CMD=cat DAEMON_RELOAD_CMD="echo [daemon-reload-stub]" \
  "$@" /usr/local/sbin/box-scripts-drift-check
}

run                                   # OK
printf 'echo HAND-EDITED\n' > "$T/sbin/demo-script"
run                                   # one DRIFT alert (host file UNCHANGED)
run                                   # (persisting) — no repeat push
```

Self-heal (add `SELF_HEAL=1`):

```bash
run SELF_HEAL=1                        # DRIFT alert + REPAIRED push; host file restored to "committed v1"
cat "$T/sbin/demo-script"             # -> echo committed v1
run SELF_HEAL=1                        # RECOVERED (drift cleared)
rm -rf "$T"
```
