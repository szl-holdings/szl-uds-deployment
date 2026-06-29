# szl-deploy-hook — token-gated remote-deploy webhook for a-11-oy.com

`szl-deploy-hook` lets an authorised caller publish a new a-11-oy.com build over
the existing public HTTPS front door — by triggering the SAME on-box
`a11oy-rebuild` that a human would run at an SSH prompt — and then poll its
status. It closes the "publishing a-11-oy.com always needs a human at the box"
gap **without putting a plaintext key on the wire and without widening what can
run on the box.**

It is a deliberate sibling of [`szl-alert-relay`](szl-alert-relay.README.md):
same loopback-behind-nginx shape, same unguessable-token-in-the-path contract,
same "503 until the token is set · 404 on a wrong token · never echo the token"
rules. The only differences are that it runs `a11oy-rebuild` instead of a
notifier, and — because a rebuild is multi-minute — a trigger returns `202`
immediately with a `run_id` and the caller polls a status endpoint.

## The problem it solves
`a-11-oy.com` is a self-hosted Docker container on box `167.233.50.75`. The only
way to publish a new build is to run `sudo a11oy-rebuild` ON the box (pull
`szl-holdings/a11oy` `main`, rebuild the image, recreate the container,
self-verify byte-for-byte vs `origin/main`). There was **no remote trigger and
no auto-rebuild timer**, so every publish required a human at an interactive SSH
session. This hook makes the publish step remotely triggerable by a holder of
one unguessable token, while keeping the rebuild itself unchanged and on-box.

## Endpoint contract
The token may be supplied **either** as the `X-Deploy-Token` request header
(preferred — the HTTPS-credential vault injects it and the path stays clean)
**or** as a single unguessable path segment (handy for manual `curl`). The
header takes precedence. It is compared in constant time (`hmac.compare_digest`)
and **never** written to a response, a log, or run metadata. A wrong/absent
token is a flat `404`.

- `POST /deploy/rebuild` (header token) **or** `POST /deploy/rebuild/<DEPLOY_TOKEN>`
  → `202 {"status":"started","run_id":…}`
  Starts `a11oy-rebuild` detached, logging to
  `/root/a11oy-build-backups/rebuild-<run_id>.log` (beside manual-run logs).
  **Single-flight:** if a rebuild is already running it returns
  `409 {"error":"rebuild already in progress","run_id":…}` — never two
  concurrent rebuilds fighting over the `a11oy` container name.
  Optional JSON body `{"verify_only": true}` runs `a11oy-rebuild --verify-only`
  (read-only check of the running image vs `origin/main`).
- `GET /deploy/status` (header token) **or** `GET /deploy/status/<DEPLOY_TOKEN>`
  → `200` status of the most recent run.
- `GET /deploy/status/<run_id>` (header token) **or**
  `GET /deploy/status/<DEPLOY_TOKEN>/<run_id>` → `200` status of a specific run.
- `GET /deploy/health` → `200 "ok"` (no token; for nginx / smoke tests).

Status payload:
```json
{
  "state": "running|ok|failed|none",
  "run_id": "20260623-161500-ab12cd",
  "verify_only": false,
  "git_sha": "7e6bd447…",        // read from the LIVE container after the run
  "exit_code": 0,
  "started_at": 1750000000,
  "finished_at": 1750000300,
  "log_tail": ["…last 40 log lines…"]
}
```
`git_sha` is read from the live container (`GET
https://a-11-oy.com/api/a11oy/v1/version`) **after** the run, so the caller can
confirm the intended HEAD actually went live — not merely that the script
exited 0. **"the half-state — claiming more than is real — is the only
unacceptable outcome."**

Publicly reachable at **`https://a-11-oy.com/deploy/rebuild/<DEPLOY_TOKEN>`** and
**`https://a-11-oy.com/deploy/status/<DEPLOY_TOKEN>`** via the nginx snippet below.

## Why it is safe to expose
- **Token gate.** The token is the only authentication; it lives only in
  `/etc/szl-deploy-hook.env` (root:600) and in the caller's secret store. A
  wrong token never gets past `404`, and the token is never echoed anywhere.
- **No command injection — fixed argv, no shell.** The hook execs a FIXED
  absolute binary (`DEPLOY_CMD`, default `/usr/local/sbin/a11oy-rebuild`) with
  `shell=False` and a fixed argv. The request body cannot inject a command, a
  path, or a free-form flag. The ONLY request-controlled choice is the boolean
  `verify_only`, which maps to the one documented read-only flag.
- **No new privileges granted to the caller.** The caller can only do what
  `a11oy-rebuild` already does (pull published `main`, rebuild, verify). They
  cannot run arbitrary code, read secrets, or reach the shell.
- **Single-flight lock.** An `O_CREAT|O_EXCL` lock holding the live `run_id`
  prevents concurrent rebuilds; a stale lock whose run has finished self-heals.

## Why it runs as root (and the hardening that remains)
`a11oy-rebuild` drives docker (build + recreate the container) and writes build
logs under `/root/a11oy-build-backups`, so the unit runs as root and **cannot**
use the relay's `ProtectSystem=full` / `ProtectHome`. The unit still keeps the
hardening that does not break docker: `PrivateTmp`, `ProtectKernelTunables`,
`ProtectControlGroups`, and a `ReadWritePaths` allow-list
(`/var/lib/szl-deploy-hook`, `/root/a11oy-build-backups`, `/opt/szl`).
`NoNewPrivileges` stays OFF because `a11oy-rebuild` may re-exec via sudo/docker.

## Config (`/etc/szl-deploy-hook.env`, PRIVATE — not in git)
```
DEPLOY_TOKEN=<unguessable>     # REQUIRED; must match the URL path segment
DEPLOY_PORT=9110               # loopback listen port (default 9110)
DEPLOY_CMD=/usr/local/sbin/a11oy-rebuild
VERSION_URL=https://a-11-oy.com/api/a11oy/v1/version
STATE_DIR=/var/lib/szl-deploy-hook
LOG_DIR=/root/a11oy-build-backups
```
Real environment variables override the file. The systemd unit references this
file as an **optional** `EnvironmentFile=-`, so a fresh box still starts the
unit (requests return `503` until `DEPLOY_TOKEN` is set), mirroring the
`szl-alert-relay.env` pattern. `install.sh` seeds it with a freshly generated
token if absent and never clobbers a hand-filled one.

## Install / reinstall (survives a box rebuild)
`box-scripts/install.sh` (run as root) installs the script + systemd unit,
seeds `/etc/szl-deploy-hook.env` with a fresh `DEPLOY_TOKEN` if missing, copies
the nginx snippet to `/etc/nginx/snippets/szl-deploy-hook.conf`, idempotently
wires `include /etc/nginx/snippets/szl-deploy-hook.conf;` into the `a-11-oy.com`
443 server block just before `location /`, validates with `nginx -t`, reloads,
and `enable --now`s `szl-deploy-hook.service`.

> ⚠️ nginx loads **every** file in `sites-enabled/` — relocate stray
> `*.bak`/`*.orig`/`*.emergency` out of that dir before a reload or `nginx -t`
> fails on a duplicate `default_server` and it looks like this change broke
> nginx (it didn't). `install.sh` already handles this.

## Usage (over HTTPS, from anywhere with the token)
```bash
# Trigger a full publish (pull main, rebuild, recreate, verify):
curl -fsS -X POST https://a-11-oy.com/deploy/rebuild/<DEPLOY_TOKEN>
# -> {"status":"started","run_id":"20260623-161500-ab12cd","verify_only":false}

# Poll until done, then confirm the intended HEAD is live:
curl -fsS https://a-11-oy.com/deploy/status/<DEPLOY_TOKEN> | jq '{state,git_sha,exit_code}'
# -> {"state":"ok","git_sha":"7e6bd447…","exit_code":0}

# Read-only drift check (no rebuild):
curl -fsS -X POST https://a-11-oy.com/deploy/rebuild/<DEPLOY_TOKEN> \
  -H 'Content-Type: application/json' -d '{"verify_only": true}'
```

## How Computer (the agent) calls it without a plaintext key
Register `DEPLOY_TOKEN` once in the secure HTTPS-credential vault for host
`a-11-oy.com` as a **custom header** named `X-Deploy-Token`, then the agent calls
the clean endpoints with `api_credentials=['custom-cred:a-11-oy.com']` — the proxy
injects the `X-Deploy-Token` header on every request to `a-11-oy.com`, so the
token never appears in the agent's transcript, the URL, or any log. The proxy
handles HTTPS only, which is exactly this webhook's transport. Example:
```bash
curl -fsS -X POST https://a-11-oy.com/deploy/rebuild           # header injected by proxy
curl -fsS https://a-11-oy.com/deploy/status | jq '{state,git_sha,exit_code}'
```

## Drift coverage
This script, its unit, snippet, and README are versioned here under
`box-scripts/` and installed on the box at
`/usr/local/sbin/szl-deploy-hook` + `/etc/systemd/system/szl-deploy-hook.service`
+ `/etc/nginx/snippets/szl-deploy-hook.conf`. `box-scripts-drift-check` alerts
if any installed host copy drifts from its committed copy here, like every other
guard in this directory.

## Test the gate locally (no real rebuild)
Point `DEPLOY_CMD` at a stub and use a throwaway state dir:
```bash
printf '#!/bin/sh\necho "[stub] would rebuild"; sleep 1\n' > /tmp/fake-rebuild
chmod +x /tmp/fake-rebuild
DEPLOY_TOKEN=testtoken DEPLOY_PORT=9110 DEPLOY_CMD=/tmp/fake-rebuild \
  STATE_DIR=/tmp/dh-state LOG_DIR=/tmp/dh-state \
  VERSION_URL=https://a-11-oy.com/api/a11oy/v1/version \
  /usr/local/sbin/szl-deploy-hook &
sleep 1
curl -s localhost:9110/deploy/health                                  # -> ok
curl -s -o /dev/null -w '%{http_code}\n' localhost:9110/deploy/rebuild/wrong   # -> 404
curl -s -X POST localhost:9110/deploy/rebuild/testtoken               # -> 202 + run_id
sleep 2
curl -s localhost:9110/deploy/status/testtoken                        # -> state:"ok"
```

## Durable home
Versioned in `szl-holdings/szl-uds-deployment` under `box-scripts/` and
installed on box `167.233.50.75` by `box-scripts/install.sh`.
