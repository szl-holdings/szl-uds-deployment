# eval-arena-trend-watch — live recorded-run honesty alarm

`eval-arena-trend-watch` is the near-real-time companion to the CI guard
`scripts/check_eval_arena_negative_control.py --recorded` (in the `a11oy` repo).

## The problem it solves

The a11oy console renders a **trend strip** from the RECORDED eval-arena run
history served live at `/api/a11oy/v1/eval-arena/history`. The CI guard already
refuses to let the newest recorded run go silently all-green — it requires the
run to keep **a passing example AND a policy-rejected negative control** (a
`pass=false`, `overall<0.85`, non-empty `policy_signals` scenario). But CI only
runs on a push/schedule. A recorded run that degrades **between** CI runs paints
a falsely-green strip until the next workflow trigger.

This box-side timer closes that window. Every ~15 minutes it reads the newest
recorded run from the **live** endpoint and runs the **same** `validate_run()`
the CI guard uses, pushing an edge-deduped a11oy-uptime ntfy alert the moment the
trend degrades.

## How it stays one source of truth

`eval-arena-trend-watch` never re-implements the contract. It shells out to the
bridge `eval-arena-trend-validate`, which imports `validate_run()`,
`_normalize_recorded_run()` and `_pick_latest_recorded()` directly from the
canonical `check_eval_arena_negative_control.py` (path overridable via
`A11OY_SCRIPTS_DIR`, default `/opt/szl/a11oy/scripts`). The validator and the
live alarm can never drift.

## Honest no-op

It pages only on a genuine degradation, never on "I could not look":

- endpoint unreachable / non-2xx / empty body → log `SKIP`, no alert, signature untouched;
- recorded history empty (`runs: []`) → log `SKIP`, no alert, signature untouched;
- validator unavailable / payload unparsable → log `SKIP`, no alert, signature untouched.

It never fabricates a run.

## Edge-triggered + RECOVERED

Same contract as `a11oy-uptime-check` / `dns-drift-check`: it alerts once on the
healthy→degraded edge (md5 signature of the problem set), logs a persisting
problem quietly, and pushes once on `RECOVERED` when the newest recorded run is
healthy again — clearing the signature so a fresh degradation re-alerts. It
always writes an atomic status file + heartbeat `STATE` log so the
monitor-liveness meta-monitor can watch it, and the notifier is fail-soft.

## Files

```
sbin/
  eval-arena-trend-watch            # the watcher (curls the live history, edge-deduped alert)
  eval-arena-trend-validate         # bridge: reuses the canonical validate_run()
systemd/
  eval-arena-trend-watch.service    # oneshot: runs eval-arena-trend-watch (+ notifier env)
  eval-arena-trend-watch.timer      # ~4 min after boot, then every 15 min
```

It shares the push channel (`/etc/a11oy-uptime.env`) and the shared notifier
`a11oy-uptime-notify` with the other a11oy-uptime watchers.

## Reinstall

The top-level `./install.sh` installs and enables this watcher with the others.
To (re)install just this manually:

```bash
sudo install -m 0755 sbin/eval-arena-trend-watch    /usr/local/sbin/eval-arena-trend-watch
sudo install -m 0755 sbin/eval-arena-trend-validate /usr/local/sbin/eval-arena-trend-validate
sudo install -m 0644 systemd/eval-arena-trend-watch.service /etc/systemd/system/
sudo install -m 0644 systemd/eval-arena-trend-watch.timer   /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now eval-arena-trend-watch.timer
```

## Verify

```bash
systemctl is-enabled eval-arena-trend-watch.timer
# Healthy live run -> exit 0, no alert:
/usr/local/sbin/eval-arena-trend-watch
# Force a degraded edge (safe, reversible) and confirm the push fires:
printf '%s' '{"count":1,"runs":[{"run_id":"x","scenarios":[{"scenario":"a","overall":0.97,"pass":true,"policy_signals":[]}]}]}' > /tmp/degraded.json
HISTORY_FILE=/tmp/degraded.json ALERT_PREFIX="[TEST-ignore] " \
  NOTIFY_CMD=/usr/local/sbin/a11oy-uptime-notify NOTIFY_TITLE="eval-arena trend" \
  /usr/local/sbin/eval-arena-trend-watch
rm -f /var/lib/a11oy-uptime/eval-arena-trend.sig   # clear the test edge afterwards
```
