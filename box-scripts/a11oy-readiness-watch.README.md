# a11oy-readiness-watch — scheduled secure-gateway Readiness alarm

Catches automatically if the **a11oy Operational Readiness** page stops loading
through the cluster's secure (admin Istio) gateway, or the supporting SSO login
services (**Keycloak + authservice**) go down, on the single-node
`uds-szl-demo` k3d cluster (box `167.233.50.75`) — instead of finding out during
a demo.

## What it runs

`box-scripts/sbin/a11oy-readiness-watch` runs ONLY the **read-only phases 0 + 1**
of `scripts/verify-a11oy-readiness-sso.sh`:

- **Phase 0 (preflight)** — Keycloak / authservice Ready, admin gateway has an
  address, the a11oy UDS Package is `phase=Ready`.
- **Phase 1 (construction proof)** — `/api/a11oy/v1/readiness` (and the console)
  return `200` through the admin gateway; the SSO-on chart render inserts the
  authservice gate in front of the same `app=a11oy` workload.

It is **read-only by construction**: `RUN_FULL_E2E` is deliberately never set, so
phase 2 (which would enable SSO + perform a live login) is **never reached** and
nothing in the cluster is enabled or mutated. The verify script's WARN
conditions (e.g. an Istio waypoint `PROGRAMMED=False`, or helm/chart
unavailable) do NOT fail it, so they never page — that waypoint fix is a separate
workstream.

## When it pages

A failure (Keycloak/authservice not Ready, the a11oy package not Ready, or the
Readiness endpoint/console not `200` through the admin gateway) raises a **real
push** via the SAME notifier + creds file the `a11oy-uptime` / `dns-drift` /
`szl-signing-health-check` monitors use (`/usr/local/sbin/a11oy-uptime-notify`,
`/etc/a11oy-uptime.env` → ntfy / Telegram / Slack-Discord webhook).

- **Grace window:** a failure must persist `>= THRESHOLD_SECS` (default `300`s)
  before it pages, so a brief blip during a redeploy never alerts.
- **De-dup:** alerts fire only on the (sustained-failure) **EDGE** and on
  **RECOVERED**; a persisting failure is de-duped (recurring alerts = the owner
  only) — same transition-de-dup as the sibling box monitors.
- **No-op when the cluster is down:** k3d nodes are `--restart no` on this box,
  so a rebooted box where the cluster is intentionally down is a NO-OP, not an
  alert.

## Schedule

`a11oy-readiness-watch.timer`: `OnBootSec=4min`, then `OnUnitActiveSec=10min`.

## State / logs

- `/var/lib/a11oy-readiness-watch/status.json` — last result (`overall`,
  `exit_code`, `fail_count`, `summary`, `alerting`).
- `/var/log/a11oy-readiness-watch/a11oy-readiness-watch.log` — heartbeat `STATE`
  every run + `ALERT` / `RECOVERED` edges.

## Test the edge without a real outage

Drive the watcher against a stubbed verify result + a `cat` notifier so the page
is visible but harmless:

```sh
STATE_DIR=$(mktemp -d) LOG_DIR=$(mktemp -d) THRESHOLD_SECS=0 \
  NOTIFY_CMD=cat ALERT_PREFIX="[TEST-ignore] " \
  VERIFY_CMD='printf "  FAIL  Keycloak not Ready\nSUMMARY: pass=7 fail=1 warn=0\n"; exit 1' \
  /usr/local/sbin/a11oy-readiness-watch
```

A `99` exit from `VERIFY_CMD` simulates the cluster-down NO-OP path (no page).

## Guard

The watcher is protected by an end-to-end guard trio (driven in CI, no cluster /
no root):

- `scripts/a11oy-readiness-watch-guard.sh` — drives the REAL watcher against a
  temp tree + stubbed `VERIFY_CMD`/`NOTIFY_CMD` and asserts: healthy = no page;
  failure edge = one ALERT (with the FAIL text); persisting = de-duped;
  RECOVERED when it clears; grace window holds; cluster-down (`99`) = no-op.
- `scripts/a11oy-readiness-watch-guard.test.sh` — negative-fixture self-test that
  applies deliberate regressions to a copy of the watcher and asserts the guard
  FAILS on each, so it can never pass vacuously.
- `.github/workflows/a11oy-readiness-watch-guard.yml` — runs both in CI.
