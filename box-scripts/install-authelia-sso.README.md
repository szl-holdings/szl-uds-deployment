# install-authelia-sso — per-user SSO for the /uds/ dashboard

`install-authelia-sso.sh` stands up **Authelia per-user SSO** in front of the UDS
dashboard at `https://a-11-oy.com/uds/`. It replaces the old shared nginx basic-auth
(single `stephen` user in `/etc/nginx/.htpasswd-uds`, now retired) with a real
per-user login portal.

## Why Authelia and not Keycloak
Real UDS Core Identity (Keycloak + authservice) cannot boot on this 2-vCPU box
(CPU requests already ~95% committed; the keycloak/authservice namespaces exist but
run zero workloads). Authelia is a single lightweight Go service that runs
**localhost-only** (`127.0.0.1:9091`), so it never touches 80/443 ownership and the
a-11-oy.com coexistence posture is preserved.

## Pieces
- Container `authelia` (`authelia/authelia:4.38`), `--restart unless-stopped`,
  bind `127.0.0.1:9091`, config dir `/opt/authelia` (mounted `/config`).
- Secrets in `/opt/authelia/secrets/{session,storage,jwt}` (chmod 600), generated
  by the installer with `openssl rand` and fed in via `AUTHELIA_*_FILE` env vars.
- Users in `/opt/authelia/users_database.yml` (argon2 hashes) — box-only, not in git.
- nginx: portal at `/authelia` (subpath), internal verify at
  `/internal/authelia/authz`, and `/uds/` gated with `auth_request`. Marker
  `AUTHELIA-SSO-PATCH` in `/etc/nginx/sites-available/a11oy`.

## Files in this dir
- `install-authelia-sso.sh` — the idempotent installer (run on the box).
- `authelia-configuration.yml` — the Authelia config TEMPLATE (no secrets); the
  installer writes this exact content to `/opt/authelia/configuration.yml`.
- `authelia-uds-nginx.snippet.conf` — the `AUTHELIA-SSO-PATCH` nginx location
  blocks to paste into the a-11-oy.com HTTPS server block.

## Rebuild from scratch (fresh box)
```bash
# 1. Stand up Authelia (idempotent; prints a generated stephen password on first run)
bash box-scripts/install-authelia-sso.sh

# 2. Add the nginx gate: paste the three blocks from
#    box-scripts/authelia-uds-nginx.snippet.conf into the HTTPS (:443) server block
#    of /etc/nginx/sites-available/a11oy, then:
nginx -t && systemctl reload nginx
```
The installer is idempotent: re-running it preserves existing secrets and users
(it only regenerates them when missing) and recreates the container.

## Add / change a user
```bash
docker run --rm authelia/authelia:4.38 authelia crypto hash generate argon2 --password 'NEWPW'
# paste the Digest into /opt/authelia/users_database.yml under the user's `password:`
docker restart authelia
```

## Traps
- **Keep `proxy_set_header Authorization "";`** in the `/uds/` block. It is required
  independent of SSO: Headlamp otherwise forwards nginx's auth header to the kube
  API, which 401s every cluster call. Authelia gating layers on top of this strip.
- Secrets, `users_database.yml`, `db.sqlite3`, and `notification.txt` are **box-only**
  and must never be committed — the installer regenerates the secrets and a fresh
  user on a clean box.

## Durable home
This script + template + nginx snippet + README are versioned in
`szl-holdings/szl-uds-deployment` under `box-scripts/` and installed on the box at
`/opt/authelia/`.
