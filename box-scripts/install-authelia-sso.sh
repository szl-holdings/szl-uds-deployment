#!/usr/bin/env bash
# Reproducible installer for Authelia per-user SSO gating the /uds/ dashboard.
# Idempotent: safe to re-run. Replaces the old shared nginx basic-auth on /uds/.
# Real Keycloak (UDS Core Identity) can't fit this 2-vCPU box (CPU ~95% committed),
# so Authelia is the lightweight per-user SSO portal. Runs localhost-only (coexistence-safe).
set -e
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
echo "NOTE: nginx /uds/ block must use auth_request -> /internal/authelia/authz (marker AUTHELIA-SSO-PATCH in /etc/nginx/sites-available/a11oy)."
