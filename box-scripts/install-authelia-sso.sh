#!/usr/bin/env bash
# Reproducible installer for Authelia per-user SSO gating the /uds/ + /status/ pages.
# Idempotent: safe to re-run. Replaces the old shared nginx basic-auth.
# Real Keycloak (UDS Core Identity) can't fit this 2-vCPU box (CPU ~95% committed),
# so Authelia is the lightweight per-user SSO portal. Runs localhost-only (coexistence-safe).
#
# This is a TRUE one-command rebuild: it brings up the Authelia container with the
# FULL LIVE access posture (admin two_factor default + a group:guests one_factor
# exception, both scoped to ^/uds AND ^/status), seeds the stephen (admins) and demo
# (guests) accounts idempotently, then idempotently injects the three
# AUTHELIA-SSO-PATCH nginx location blocks (from authelia-uds-nginx.snippet.conf)
# into the a-11-oy.com HTTPS server block, validates and reloads nginx. No hand-paste step.
#
# Security posture reproduced (matches the live box exactly):
#   - default_policy: deny  -> anonymous is denied everywhere
#   - group:guests -> one_factor on ^/uds + ^/status (password-only read-only demo links)
#   - everyone else (e.g. group:admins) -> two_factor (TOTP) on ^/uds + ^/status
# Re-running is non-destructive: configuration.yml is rewritten identically and
# users_database.yml is only APPENDED to for users that are absent, so an existing
# box keeps its enrolled TOTP / rotated passwords (never a silent downgrade).
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SNIPPET="$SCRIPT_DIR/authelia-uds-nginx.snippet.conf"
NGINX_VHOST="${NGINX_VHOST:-/etc/nginx/sites-available/a11oy}"
IMG="authelia/authelia:4.38"
mkdir -p /opt/authelia/secrets
cd /opt/authelia

for s in session storage jwt; do
  [ -s "secrets/$s" ] || openssl rand -hex 48 > "secrets/$s"
done
chmod 600 secrets/*

docker pull "$IMG" >/dev/null

# --- users: seed stephen (admins) + demo (guests) idempotently ---
# Each user is added only when ABSENT, so re-running never reverts an existing
# users_database.yml (enrolled TOTP / rotated passwords are preserved). Generated
# initial passwords are written to a root-only file (chmod 600); they are NEVER
# echoed to stdout/logs and NEVER committed to git.
CREDS_FILE="/opt/authelia/.initial-credentials"
if [ ! -s users_database.yml ]; then
  echo "users:" > users_database.yml
  chmod 600 users_database.yml
fi

seed_user() {
  # $1=username  $2=displayname  $3=email  $4=group
  local user="$1" dn="$2" email="$3" group="$4"
  if grep -qE "^[[:space:]]+${user}:[[:space:]]*$" users_database.yml; then
    echo "user '${user}' already present in users_database.yml — preserved (no revert)."
    return 0
  fi
  local pw h
  pw="$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | cut -c1-18)"
  h="$(docker run --rm "$IMG" authelia crypto hash generate argon2 --password "$pw" 2>/dev/null | sed -n 's/^Digest: //p')"
  if [ -z "$h" ]; then
    echo "ERROR: failed to generate argon2 hash for user '${user}'" >&2
    return 1
  fi
  cat >> users_database.yml <<EOF
  ${user}:
    disabled: false
    displayname: "${dn}"
    password: "${h}"
    email: ${email}
    groups: [${group}]
EOF
  ( umask 077; printf '%s\t%s\n' "$user" "$pw" >> "$CREDS_FILE" )
  chmod 600 "$CREDS_FILE" 2>/dev/null || true
  echo "seeded user '${user}' (group ${group}); initial password written to ${CREDS_FILE} (chmod 600, not in git/logs)."
}

seed_user stephen "Stephen Lutar"          stephen@a11oy.net admins
seed_user demo    "a11oy Demo (read-only)" demo@a11oy.net    guests
chmod 600 users_database.yml

cat > configuration.yml <<'EOF'
theme: dark
server:
  address: 'tcp://0.0.0.0:9091/authelia'
log:
  level: info
totp:
  issuer: a-11-oy.com
authentication_backend:
  password_reset:
    disable: true
  file:
    path: /config/users_database.yml
    password:
      algorithm: argon2
access_control:
  default_policy: deny
  rules:
    - domain: 'a-11-oy.com'
      subject: 'group:guests'
      resources:
        - '^/uds(/.*)?$'
        - '^/status(/.*)?$'
      policy: one_factor
    - domain: 'a-11-oy.com'
      resources:
        - '^/uds(/.*)?$'
        - '^/status(/.*)?$'
      policy: two_factor
session:
  cookies:
    - name: authelia_session
      domain: 'a-11-oy.com'
      authelia_url: 'https://a-11-oy.com/authelia'
      expiration: '12 hours'
      inactivity: '1 hour'
regulation:
  max_retries: 5
  find_time: '2 minutes'
  ban_time: '5 minutes'
storage:
  local:
    path: /config/db.sqlite3
notifier:
  filesystem:
    filename: /config/notification.txt
EOF
chmod 600 configuration.yml

docker rm -f authelia >/dev/null 2>&1 || true
docker run -d --name authelia --restart unless-stopped \
  -p 127.0.0.1:9091:9091 -v /opt/authelia:/config \
  -e AUTHELIA_SESSION_SECRET_FILE=/config/secrets/session \
  -e AUTHELIA_STORAGE_ENCRYPTION_KEY_FILE=/config/secrets/storage \
  -e AUTHELIA_IDENTITY_VALIDATION_RESET_PASSWORD_JWT_SECRET_FILE=/config/secrets/jwt \
  "$IMG" >/dev/null
sleep 6
curl -fsS http://127.0.0.1:9091/authelia/api/health && echo " authelia healthy"

# --- nginx: idempotently inject the AUTHELIA-SSO-PATCH location blocks ---
# Marker-guarded so re-running is a safe no-op. Backs up the vhost, injects the
# snippet's location blocks into the HTTPS (listen 443) server block, then runs
# `nginx -t`; on failure it restores the backup and fails loud so nginx is never
# left in a broken state.
inject_nginx() {
  if [ ! -f "$NGINX_VHOST" ]; then
    echo "WARN: nginx vhost $NGINX_VHOST not found — skipping nginx injection."
    echo "      (Run the a-11-oy.com site installer to create the vhost first, then re-run this script.)"
    return 0
  fi
  if grep -q 'AUTHELIA-SSO-PATCH' "$NGINX_VHOST"; then
    echo "nginx: AUTHELIA-SSO-PATCH already present in $NGINX_VHOST — no-op."
    return 0
  fi
  if [ ! -s "$SNIPPET" ]; then
    echo "ERROR: nginx snippet not found at $SNIPPET" >&2
    return 1
  fi
  local bak="$NGINX_VHOST.pre-authelia.$(date +%s).bak"
  cp -a "$NGINX_VHOST" "$bak"
  if ! python3 - "$NGINX_VHOST" "$SNIPPET" <<'PYEOF'
import re, sys
vhost_path, snippet_path = sys.argv[1], sys.argv[2]
src = open(vhost_path).read()
lines = open(snippet_path).read().splitlines()
# Drop ONLY the leading column-0 comment/blank header paragraph; keep everything
# after it — including the indented `# AUTHELIA-SSO-PATCH ...` marker comments that
# the re-run guard greps for.
i = 0
while i < len(lines) and (lines[i].startswith('#') or lines[i].strip() == ''):
    i += 1
body = "\n".join(lines[i:]).strip("\n")
n = len(src)
pos = 0
while True:
    m = re.search(r'\bserver\s*\{', src[pos:])
    if not m:
        break
    open_brace = pos + m.end() - 1   # index of the '{'
    depth, j = 0, open_brace
    while j < n:
        if src[j] == '{':
            depth += 1
        elif src[j] == '}':
            depth -= 1
            if depth == 0:
                break
        j += 1
    block = src[open_brace:j + 1]
    if re.search(r'listen[^;]*\b443\b', block):
        insert_at = open_brace + 1
        new_src = src[:insert_at] + "\n" + body + "\n" + src[insert_at:]
        open(vhost_path, 'w').write(new_src)
        sys.exit(0)
    pos = j + 1
sys.stderr.write("no HTTPS (listen 443) server block found\n")
sys.exit(2)
PYEOF
  then
    echo "ERROR: could not inject AUTHELIA-SSO-PATCH into $NGINX_VHOST. Backup: $bak" >&2
    return 1
  fi
  if nginx -t 2>/dev/null; then
    systemctl reload nginx
    echo "nginx: AUTHELIA-SSO-PATCH injected into $NGINX_VHOST and nginx reloaded."
  else
    echo "ERROR: nginx -t failed after injection — restoring backup $bak" >&2
    cp -a "$bak" "$NGINX_VHOST"
    nginx -t
    return 1
  fi
}
inject_nginx

echo "DONE: Authelia SSO is up. /uds/ + /status/ are gated (admin 2FA, guest one-factor, anon denied). Visit https://a-11-oy.com/uds/"
