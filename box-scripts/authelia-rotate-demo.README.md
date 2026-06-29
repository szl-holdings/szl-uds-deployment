# authelia-rotate-demo — rotate the public read-only demo login

Box `167.233.50.75`. The a-11-oy.com Authelia SSO has a password-only, read-only
`demo` account (group `guests`) meant to be shared publicly (e.g. a LinkedIn
link) so anyone can try the live UDS dashboard at https://a-11-oy.com/uds/ and the
status page at https://a-11-oy.com/status/. A publicly posted password will
eventually be scraped/abused, so it must be cheap to rotate.

## One command

```bash
authelia-rotate-demo                 # generate a random password and rotate
authelia-rotate-demo 'my-chosen-pw'  # rotate to a specific password
authelia-rotate-demo --print         # print the current demo password
```

What a rotation does, end to end:
1. Generates a human-shareable password (`demo-xxxx-xxxx-xxxx`, unambiguous
   alphabet) — or uses the one you pass as `$1`.
2. argon2-hashes it with the `authelia/authelia:4.38` image.
3. Swaps **only** user `demo`'s `password:` line in
   `/opt/authelia/users_database.yml` (timestamped `.bak` first; aborts without
   touching the file if the user count would change).
4. Restarts the `authelia` container so the file backend reloads.
5. Verifies the NEW password authenticates (HTTP 200) and the OLD one no longer
   does (HTTP 401) via the firstfactor API. Localhost calls send
   `Host`/`X-Forwarded-*` for `a-11-oy.com` so Authelia's session-cookie domain
   matches the request URL — otherwise 1FA fails with "no configured session
   cookie domain matches ...".
6. Records the new password to `/opt/authelia/demo-password.txt` (root-only,
   chmod 600). Retrieve later with `authelia-rotate-demo --print`. The password
   is never committed to git and never sent over the push channel.

## Scheduled rotation (so a leaked password self-expires)

`authelia-rotate-demo.timer` runs the rotation **monthly**. On each rotation the
owner is pinged via `a11oy-uptime-notify` (the push contains NO password) to
fetch the new one and update any shared link.

```bash
systemctl list-timers authelia-rotate-demo.timer   # next run
systemctl disable --now authelia-rotate-demo.timer # stop scheduled rotation
```

## Reinstall (after box rebuild)

```bash
cd /opt/szl/szl-uds-deployment/box-scripts && sudo ./install.sh
```

installs the script to `/usr/local/sbin/authelia-rotate-demo` and the
service/timer to `/etc/systemd/system/`, and enables the monthly timer.

## Env overrides (defaults shown)

`AUTHELIA_DIR=/opt/authelia`, `USERS_DB=$AUTHELIA_DIR/users_database.yml`,
`PW_FILE=$AUTHELIA_DIR/demo-password.txt`, `AUTHELIA_IMAGE=authelia/authelia:4.38`,
`AUTHELIA_CONTAINER=authelia`, `VERIFY_DOMAIN=a-11-oy.com`.
