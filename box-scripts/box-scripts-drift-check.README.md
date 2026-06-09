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

## What it watches (self-maintaining — derived, not a fixed list)

The watch set is **derived from `box-scripts/install.sh`** — specifically the
`install -m … "$here/sbin/X" …` and `install -m … "$here/systemd/Y" …` mapping.
Every helper that `install.sh` actually installs is watched automatically, so
adding a new script/unit to `install.sh` covers it here with **no edit to this
script**. Each derived name `X` is compared:

| live path | committed copy |
|---|---|
| `/usr/local/sbin/X`            | `box-scripts/sbin/X`    |
| `/etc/systemd/system/Y`        | `box-scripts/systemd/Y` |

Lines that install into other trees (e.g. `/etc/nginx/...`) and `install -d`
directory lines are ignored (classified by the `"$here/sbin/"` / `"$here/systemd/"`
source prefix).

Knobs (all env-overridable):

- `WATCH_SBIN` / `WATCH_UNITS` — set explicitly (space-separated basenames) to
  **override** derivation entirely. Used by the isolated test recipe below. An
  explicit empty string watches nothing of that kind.
- `WATCH_EXCLUDE` — space-separated basenames to **drop** from the derived set
  (entries that legitimately have no committed copy / should not be watched).
- `INSTALL_SH` — path to the install script to parse (default
  `$BOX_SCRIPTS/install.sh`).
- If `install.sh` is unreadable / yields nothing, the original static set
  (`a11oy-uptime-check`, `a11oy-uptime-notify`, `dns-drift-check` + their units)
  is used as a fallback so the guard never silently watches nothing.

Files committed under `box-scripts/{sbin,systemd}/` but installed by a **different**
mechanism (e.g. `szl-box-sync*`, which has its own installer) are intentionally
**not** in `install.sh` and therefore out of this guard's scope.

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

## Test the derivation (no override, parse a stub install.sh)

Leave `WATCH_SBIN` / `WATCH_UNITS` UNSET so the watch set is derived from a stub
`install.sh`, and confirm only the `"$here/sbin|systemd/"` installs are picked up
(the `/etc/nginx` install + `install -d` line are ignored), `WATCH_EXCLUDE` drops
an entry, and `LIVE-MISSING` / `REPO-MISSING` still report:

```bash
T=$(mktemp -d)
mkdir -p "$T/repo/.git" "$T/repo/box-scripts/sbin" "$T/repo/box-scripts/systemd" \
         "$T/sbin" "$T/units" "$T/state" "$T/log"
cat > "$T/repo/box-scripts/install.sh" <<'EOF'
install -m 0755 "$here/sbin/foo"            /usr/local/sbin/foo
install -m 0755 "$here/sbin/bar"            /usr/local/sbin/bar
install -d -m 0755 /etc/nginx/snippets
install -m 0644 "$here/web.conf"            /etc/nginx/snippets/web.conf
install -m 0644 "$here/systemd/foo.timer"   /etc/systemd/system/foo.timer
EOF
for f in foo bar; do printf 'v1\n' > "$T/repo/box-scripts/sbin/$f"; cp "$T/repo/box-scripts/sbin/$f" "$T/sbin/$f"; done
printf '[Unit]\n' > "$T/repo/box-scripts/systemd/foo.timer"; cp "$T/repo/box-scripts/systemd/foo.timer" "$T/units/foo.timer"

derun() {
  REPO="$T/repo" BOX_SCRIPTS="$T/repo/box-scripts" SBIN_DIR="$T/sbin" UNIT_DIR="$T/units" \
  STATE_DIR="$T/state" LOG_DIR="$T/log" LOG="$T/log/x.log" STATUS="$T/state/status.json" \
  SIG_FILE="$T/state/problem.sig" NOTIFY_CMD=cat ALERT_PREFIX="[TEST-ignore] " "$@" \
  /usr/local/sbin/box-scripts-drift-check
}

derun                                 # OK — derives foo,bar (+foo.timer); web.conf ignored
grep -o '"name": "[^"]*"' "$T/state/status.json"   # foo, bar, foo.timer only
rm "$T/sbin/bar"                       # committed copy with no host counterpart
derun                                  # one DRIFT alert: script bar: LIVE-MISSING
WATCH_EXCLUDE="bar" derun              # RECOVERED — bar excluded, back to all-MATCH
rm -rf "$T"
```
