#!/usr/bin/env bash
# Reproducible installer for Authelia per-user SSO gating the /uds/ dashboard.
# Idempotent: safe to re-run. Replaces the old shared nginx basic-auth on /uds/.
# Real Keycloak (UDS Core Identity) can't fit this 2-vCPU box (CPU ~95% committed),
# so Authelia is the lightweight per-user SSO portal. Runs localhost-only (coexistence-safe).
#
# This is a TRUE one-command rebuild: it brings up the Authelia container AND
# idempotently injects the three AUTHELIA-SSO-PATCH nginx location blocks
# (from authelia-uds-nginx.snippet.conf) into the a11oy.net HTTPS server block,
# then validates and reloads nginx. No hand-paste step.
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

if [ ! -s users_database.yml ]; then
  PW="$(openssl rand -base64 15 | tr -d '/+=' | cut -c1-18)"
  echo "GENERATED stephen password: $PW   (change via 'authelia crypto hash generate argon2')"
  H="$(docker run --rm "$IMG" authelia crypto hash generate argon2 --password "$PW" 2>/dev/null | sed -n 's/^Digest: //p')"
  cat > users_database.yml <<EOF
users:
  stephen:
    disabled: false
    displayname: "Stephen Lutar"
    password: "$H"
    email: stephen@a11oy.net
    groups: [admins]
EOF
  chmod 600 users_database.yml
fi

cat > configuration.yml <<'EOF'
theme: dark
server:
  address: 'tcp://0.0.0.0:9091/authelia'
log:
  level: info
totp:
  issuer: a11oy.net
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
    - domain: 'a11oy.net'
      resources: ['^/uds(/.*)?$']
      policy: one_factor
session:
  cookies:
    - name: authelia_session
      domain: 'a11oy.net'
      authelia_url: 'https://a11oy.net/authelia'
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
    echo "      (Run the a11oy.net site installer to create the vhost first, then re-run this script.)"
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

echo "DONE: Authelia SSO is up and /uds/ is gated. Visit https://a11oy.net/uds/"
