# box-scripts-drift-check — keep host helper scripts in sync with the repo

The box (167.233.50.75) runs host-level helper scripts under `/usr/local/sbin`
and their systemd units under `/etc/systemd/system`. Their canonical copies are
committed in this repo under `box-scripts/sbin/` and `box-scripts/systemd/`, but
the host paths live **outside any git checkout**, so a hand-edit on the box can
silently diverge from the committed copy. The `BOX-SYNC` rule only protects the
git working tree, not these host files.

`box-scripts-drift-check` byte-compares each watched live file against its
committed `box-scripts/` copy and **alerts on drift** so the repo copy stays the
real source of truth. It only reports — it never auto-reinstalls.

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

## Install / restore

Installed by `box-scripts/install.sh` (idempotent). The timer runs every 15 min
after a 6-min boot delay.

## Reconciling a reported drift

- If the **live edit is intended**: copy the host file back into `box-scripts/`
  and commit it (the repo copy must follow the source of truth).
- If the **repo copy is correct**: re-run `sudo box-scripts/install.sh` to push
  the committed copy back onto the host.

## Test (no real alert)

```bash
sudo STATE_DIR=/tmp/bsd LOG_DIR=/tmp/bsd LOG=/tmp/bsd/x.log \
  STATUS=/tmp/bsd/status.json SIG_FILE=/tmp/bsd/problem.sig \
  WATCH_SBIN="a11oy-uptime-notify" WATCH_UNITS="" \
  BOX_SCRIPTS=/tmp/bsd-repo/box-scripts \
  ALERT_PREFIX="[TEST-ignore] " NOTIFY_CMD=cat \
  /usr/local/sbin/box-scripts-drift-check
```
