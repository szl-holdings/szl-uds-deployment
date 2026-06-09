# szl-alert-relay — clean-text alert relay (Slack-format webhook → ntfy)

## Problem
Several GitHub Actions alert steps POST a **Slack incoming-webhook** body to
whatever the `SLACK_WEBHOOK_URL` secret points at:
- `szl-holdings/a11oy` `.github/workflows/rekor-recheck.yml` — `{"text": "..."}`
- `szl-holdings/a11oy` `.github/workflows/release-receipt-verify.yml` —
  `{"text": "..."}` (shares a11oy's one repo-level secret with rekor-recheck)
- `szl-holdings/platform` `.github/workflows/post-deploy-smoke.yml` — a richer
  `{"text": ..., "attachments": [{ "fields": [...], "footer": ... }]}` shape

The team's only watched push channel is the **ntfy** topic in
`/etc/a11oy-uptime.env` on box `167.233.50.75`. ntfy *accepts* that JSON and
returns **HTTP 200** (so the workflow's 2xx gate passes), but it does **not**
understand the Slack schema — it renders the raw JSON wrapper as the message
body. The page is readable but ugly, which is bad for an urgent alert.

## What this does
A tiny loopback HTTP service (`/usr/local/sbin/szl-alert-relay`, pure stdlib
Python 3) sits **behind the existing nginx**. It accepts the Slack-format POST
and **flattens** it into one plain-text block — `.text` plus, for the richer
attachments shape, each `attachments[]` title/text, its `fields[]` rendered as
`Title: value` lines, and its `footer`. Then it cleans the text (per-line
de-indent, Slack emoji shortcodes → unicode e.g. `:rotating_light:` → 🚨, strips
`*bold*` markers, unwraps `<url|label>` links → `label (url)`, drops ``` ```
fences), and republishes it as a **clean plain-text** message through the shared
notifier
`/usr/local/sbin/a11oy-uptime-notify` — which already reads `NTFY_URL` from
`/etc/a11oy-uptime.env`. So the alert lands on the **same watched topic**, now
as clean text.

## Endpoint contract
- `POST /relay/ntfy/<RELAY_TOKEN>` — body `{"text": "..."}` →
  `200` republished OK · `502` notifier failed · `400` bad/missing `.text` ·
  `404` wrong/absent token (the token is never echoed) · `503` token unset.
- `GET  /relay/health` → `200 ok` (no token; for nginx / smoke tests).

Publicly reachable at **`https://a11oy.net/relay/ntfy/<RELAY_TOKEN>`** via the
nginx snippet below. Safe to expose: a wrong token returns 404.

## Config (`/etc/szl-alert-relay.env`, PRIVATE — not in git)
```
RELAY_TOKEN=<unguessable>        # REQUIRED; must match the URL path segment
RELAY_PORT=9099                  # loopback listen port (default 9099)
NOTIFY_CMD=/usr/local/sbin/a11oy-uptime-notify
NOTIFY_TITLE=Rekor receipt re-check
NTFY_PRIORITY=high
```
Real environment variables override the file. The systemd unit references this
file as an **optional** `EnvironmentFile=-` so a fresh box still starts the unit
(POSTs return 503 until `RELAY_TOKEN` is set), mirroring the `a11oy-uptime.env`
pattern.

## Install / reinstall (survives a box rebuild)
`box-scripts/install.sh` (run as root) installs the script + systemd unit,
copies the nginx snippet to `/etc/nginx/snippets/szl-alert-relay.conf`,
idempotently wires `include /etc/nginx/snippets/szl-alert-relay.conf;` into the
`a11oy.net` 443 server block just before `location /`, validates with
`nginx -t`, reloads, and `enable --now`s `szl-alert-relay.service`. It seeds a
commented-out `/etc/szl-alert-relay.env` stub (never clobbering a real one) and
prints a reminder to set `RELAY_TOKEN` if it is still empty.

> ⚠️ nginx loads **every** file in `sites-enabled/` — before any reload,
> relocate stray `*.bak`/`*.orig`/`*.emergency` out of that dir or `nginx -t`
> will fail on a duplicate `default_server` and it will look like this change
> broke nginx (it didn't). install.sh checks for this.

## The other half: the GitHub secret(s)
Point every `SLACK_WEBHOOK_URL` secret that feeds a CI alert at
`https://a11oy.net/relay/ntfy/<RELAY_TOKEN>`. The workflows' existing POSTs then
arrive here and page cleanly — **no workflow change is needed**. Current wiring:
- `szl-holdings/a11oy` — one **repo-level** secret, shared by both
  `rekor-recheck.yml` and `release-receipt-verify.yml` (Actions secrets are
  repo-scoped, so repointing it once covers both workflows).
- `szl-holdings/platform` — `post-deploy-smoke.yml` binds `environment:
  production`, so its secret lives in the **`production` environment** secrets,
  not at repo level. Set `SLACK_WEBHOOK_URL` there.

> Secrets need a libsodium sealed box (no `gh` CLI on the box). Do the encrypt
> + PUT so the `RELAY_TOKEN` never lands in a log: read it on-box from
> `/etc/szl-alert-relay.env`, seal it against the secret's public key, and PUT
> only the encrypted blob. Org-owner `SZL_GITHUB_TOKEN` can write the secret.

## Test the failure path without a real failure
POST the workflow's exact payload (prefixed `[TEST-ignore]`) to the relay and
confirm a clean page on the topic:
```
curl -sS -o /dev/null -w '%{http_code}\n' -X POST \
  -H 'Content-Type: application/json' \
  --data '{"text":":rotating_light: *Rekor receipt re-check FAILED* — [TEST-ignore] example\n*Counts:* checked=3 verified=2 failed=1"}' \
  https://a11oy.net/relay/ntfy/<RELAY_TOKEN>
```
Expect `200` and a clean, de-JSON'd, de-indented page (🚨, no `*`, no
`{"text":}` wrapper) on the team's ntfy topic.

## Watch the relay itself — `szl-alert-relay-watch`
The relay is now the **single path** that turns CI receipt-failure alerts into
clean pages. If the relay service or its nginx `/relay/` location dies, the
workflow's POST fails and the alert is **silently undelivered** — a "nothing
watches the watcher" gap. `szl-alert-relay-watch` (`sbin/szl-alert-relay-watch`
+ `systemd/szl-alert-relay-watch.{service,timer}`) closes it, joining the same
alerting family as the DNS-drift / a11oy-uptime / box-scripts watchers.

Every 5 minutes (and ~4 min after boot) it checks two things:

1. **HTTP** — `GET https://a11oy.net/relay/health` must return `200` (proves
   *both* nginx's `/relay/` location and the loopback relay are serving).
2. **UNIT** — `systemctl is-active szl-alert-relay.service` must be `active`
   (catches a crash-looped/stopped service). If `systemctl` is unavailable the
   unit check is skipped fail-soft (the HTTP probe still covers a dead relay).

A failure of **either** is a problem worth paging. It is **edge-triggered**:
it alerts once on the healthy→down EDGE (md5-signature de-dup, so a persisting
outage does not spam), logs/pushes **RECOVERED** when both checks pass again,
and is **fail-soft** (a missing notifier never hides the edge — it is always in
the log + status file). The push goes through the SAME notifier the other
watchers use (`/usr/local/sbin/a11oy-uptime-notify` → the shared ntfy topic in
`/etc/a11oy-uptime.env`), wired via `NOTIFY_CMD` in the unit. Outputs:

```
log    -> /var/log/szl-alert-relay-watch/szl-alert-relay-watch.log
status -> /var/lib/szl-alert-relay-watch/status.json   # fresh "checked_at" every run
```

Because the status file carries a fresh `checked_at`, this watcher is itself
coverable by the `monitor-liveness` meta-monitor — add
`szl-alert-relay-watch|/var/lib/szl-alert-relay-watch/status.json|900` to its
`WATCHERS` to watch the watcher of the watcher.

`box-scripts/install.sh` installs the script + units and `enable --now`s the
timer, so it survives a box rebuild like every other guard here.

### Test the down/recovered path locally (no real outage, no real alert)
Point the probes at stubs and a throwaway state dir, prefix `[TEST-ignore]`:
```
# simulate DOWN: health returns 503 + unit "inactive"
printf '#!/bin/sh\necho 503\n' > /tmp/fake-curl && chmod +x /tmp/fake-curl
printf '#!/bin/sh\n[ "$1" = is-active ] && echo inactive\n' > /tmp/fake-systemctl && chmod +x /tmp/fake-systemctl
sudo CURL_BIN=/tmp/fake-curl SYSTEMCTL_BIN=/tmp/fake-systemctl \
  STATE_DIR=/tmp/relaywatch LOG=/tmp/relaywatch/log STATUS=/tmp/relaywatch/status.json \
  ALERT_PREFIX='[TEST-ignore] ' NOTIFY_CMD=/usr/local/sbin/a11oy-uptime-notify \
  /usr/local/sbin/szl-alert-relay-watch
# -> ALERT once; cat /tmp/relaywatch/status.json shows overall DOWN
# now simulate RECOVERED: health 200 + unit active -> pushes RECOVERED once
```
