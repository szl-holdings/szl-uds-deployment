# szl-alert-relay — clean-text alert relay (Slack-format webhook → ntfy)

## Problem
GitHub Actions alert steps (notably `szl-holdings/a11oy`
`.github/workflows/rekor-recheck.yml`, step *"Alert the team directly on
re-check failure"*) POST a **Slack incoming-webhook** body
`{"text": "..."}` to whatever the `SLACK_WEBHOOK_URL` secret points at. The
team's only watched push channel is the **ntfy** topic in
`/etc/a11oy-uptime.env` on box `167.233.50.75`. ntfy *accepts* that JSON and
returns **HTTP 200** (so the workflow's 2xx gate passes), but it does **not**
understand the Slack schema — it renders the raw `{"text": ...}` JSON wrapper
as the message body. The page is readable but ugly, which is bad for an urgent
alert.

## What this does
A tiny loopback HTTP service (`/usr/local/sbin/szl-alert-relay`, pure stdlib
Python 3) sits **behind the existing nginx**. It accepts the Slack-format POST,
extracts `.text`, cleans it (per-line de-indent, Slack emoji shortcodes →
unicode e.g. `:rotating_light:` → 🚨, strips `*bold*` markers), and republishes
it as a **clean plain-text** message through the shared notifier
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

## The other half: the GitHub secret
Point `SLACK_WEBHOOK_URL` on `szl-holdings/a11oy` at
`https://a11oy.net/relay/ntfy/<RELAY_TOKEN>`. The workflow's existing
`{"text": ...}` POST then arrives here and pages cleanly. No workflow change is
needed.

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
