# szl-signing-health-check — alert when receipt signing stays down

A periodic systemd watcher on box `167.233.50.75` that fires a **real push
notification** when `szl-receipts` signing is down on the single-node
`uds-szl-demo` k3d cluster and **stays down past a grace window**.

It closes the loop the self-heal helpers leave open: `vault-auto-unseal`
re-unseals Vault after a restart, but if recovery *fails* (init.json
gone/misowned, unseal key mismatch, Vault wedged, receipts-server crashlooping,
or receipts booted unsigned) nothing actively told a human — it just logged into
the journal. This watcher makes that outage loud.

## What it checks (only when the cluster is up)
The k3d nodes are `--restart no`, so on a box where the cluster is intentionally
down the check is a **no-op exit 0, not an alert** (mirrors `vault-auto-unseal`).
When the cluster is up it flags a problem if EITHER:
1. **Vault sealed** — `vault status .sealed == true` in ns `vault` (auto-unseal
   did NOT recover it), or Vault status is unreadable.
2. **Receipts not signing** — no Ready `receipts-server` container in ns
   `szl-receipts` (crashloop / Pending / scaled-0), OR a Ready container whose
   `GET /pubkey` reports `signed != true` / is unreachable.

## Grace window (`THRESHOLD_SECS`, default 300s)
The live receipts pod flaps, and a normal Vault auto-unseal cycle takes ~1 min,
so a problem must persist `>= THRESHOLD_SECS` before it pages. Transition-dedup
then means **one page per sustained-outage edge** + one RECOVERED. Alerts go out
via the shared notifier `/usr/local/sbin/a11oy-uptime-notify` (ntfy / Telegram /
Slack-Discord webhook, channel in `/etc/a11oy-uptime.env`), wired through
`NOTIFY_CMD` in the unit — fail-soft, so it logs even before a channel is set.
SMS/email is intentionally NOT used (no Gmail/nodemailer transport; outbound TCP
465 is firewalled — see `sms-alerts-on-hetzner`).

## What / where
- `/usr/local/sbin/szl-signing-health-check` — the check (oneshot).
- `/etc/systemd/system/szl-signing-health-check.{service,timer}` — every 2 min,
  first run 3 min after boot.
- State: `/var/lib/szl-signing-health/{status.json,problem.sig,unhealthy_since}`.
- Log: `/var/log/szl-signing-health/szl-signing-health.log`.
- Canonical source: this `box-scripts/` dir; installed by `box-scripts/install.sh`.

## Install / test
- Install (idempotent): `sudo box-scripts/install.sh`.
- Force DOWN deterministically for a test (don't depend on the flappy live pod):
  `ALERT_PREFIX="[TEST-ignore] " STATE_DIR=/tmp/sh RX_CONTAINER=does-not-exist
  /usr/local/sbin/szl-signing-health-check` → "no Ready container" problem.
  Seed `echo $(($(date -u +%s)-600)) > /tmp/sh/unhealthy_since` to skip the grace
  window and exercise the ALERT path. Always use the `[TEST-ignore]` prefix + a
  throwaway `STATE_DIR` so you never dirty prod state or alarm the owner.

## Scope
This is the ALERT only. Fixing the receipts crashloop / signer recovery is a
separate concern — this watcher just makes a sustained outage loud and survives a
clean box rebuild via `install.sh`.
