#!/usr/bin/env bash
#
# install.sh — reinstall the box 167.233.50.75 host-level helper scripts and
# systemd units that are NOT otherwise under version control. Covers:
#   1. a11oy.net <-> UDS cluster port-coexistence (Task #179)
#   2. the 2-vCPU headroom self-heal guards for the uds-szl-demo cluster:
#        szl-core-rightsize   — pin UDS-core HA components to single-replica
#        istiod-fit-strategy  — keep istiod rollout/HPA fitting on 2 vCPU
#        receipt-chain-watch  — alarm when signed deploy receipts stop recording
#                               (primary uds-szl-demo + templated
#                               receipt-chain-watch@<cluster> for extra clusters)
#   3. the a11oy.net public-site alerting watchers:
#        a11oy-uptime-check   — probe a11oy.net uptime, alert on the outage edge
#        a11oy-uptime-notify  — shared push notifier (ntfy/Telegram/webhook)
#        dns-drift-check      — alert if a11oy.net DNS stops pointing at the box
#        box-scripts-drift-check — alert if a host sbin/unit drifts from its committed box-scripts/ copy
#   4. szl-ns-scratch — scratch-namespace cleanup-safety tool (on-demand
#        operator helper, see docs/SCRATCH_NAMESPACE_CONVENTION.md), plus
#        szl-ns-scratch-watch — periodic guard that alerts when an untracked
#        (unlabeled + unmanaged) scratch namespace appears on uds-szl-demo
#        szl-ns-scratch-stale-watch — periodic guard that alerts when a LABELED
#        scratch namespace outlives its declared expiry (szl.io/ttl-days)
#
# Run as root from this directory:  sudo ./install.sh
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "must run as root: sudo ./install.sh" >&2; exit 1; }

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "[install] copying scripts to /usr/local/sbin ..."
install -m 0755 "$here/sbin/a11oy-mode"                /usr/local/sbin/a11oy-mode
install -m 0755 "$here/sbin/a11oy-serverlb-deconflict" /usr/local/sbin/a11oy-serverlb-deconflict
install -m 0755 "$here/sbin/a11oy-port-guard"          /usr/local/sbin/a11oy-port-guard
install -m 0755 "$here/sbin/szl-core-rightsize"        /usr/local/sbin/szl-core-rightsize
install -m 0755 "$here/sbin/istiod-fit-strategy"       /usr/local/sbin/istiod-fit-strategy
install -m 0755 "$here/sbin/receipt-chain-watch"       /usr/local/sbin/receipt-chain-watch
install -m 0755 "$here/sbin/szl-ns-scratch"            /usr/local/sbin/szl-ns-scratch
install -m 0755 "$here/sbin/szl-ns-scratch-watch"      /usr/local/sbin/szl-ns-scratch-watch
install -m 0755 "$here/sbin/szl-ns-scratch-stale-watch" /usr/local/sbin/szl-ns-scratch-stale-watch
install -m 0755 "$here/sbin/a11oy-uptime-check"        /usr/local/sbin/a11oy-uptime-check
install -m 0755 "$here/sbin/a11oy-uptime-notify"       /usr/local/sbin/a11oy-uptime-notify
install -m 0755 "$here/sbin/dns-drift-check"           /usr/local/sbin/dns-drift-check
install -m 0755 "$here/sbin/box-scripts-drift-check"     /usr/local/sbin/box-scripts-drift-check
install -m 0755 "$here/sbin/szl-alert-relay"           /usr/local/sbin/szl-alert-relay

echo "[install] copying systemd units to /etc/systemd/system ..."
install -m 0644 "$here/systemd/a11oy-coexist.service"        /etc/systemd/system/a11oy-coexist.service
install -m 0644 "$here/systemd/a11oy-port-guard.service"     /etc/systemd/system/a11oy-port-guard.service
install -m 0644 "$here/systemd/a11oy-port-guard.timer"       /etc/systemd/system/a11oy-port-guard.timer
install -m 0644 "$here/systemd/szl-core-rightsize.service"   /etc/systemd/system/szl-core-rightsize.service
install -m 0644 "$here/systemd/szl-core-rightsize.timer"     /etc/systemd/system/szl-core-rightsize.timer
install -m 0644 "$here/systemd/istiod-fit-strategy.service"  /etc/systemd/system/istiod-fit-strategy.service
install -m 0644 "$here/systemd/istiod-fit-strategy.timer"    /etc/systemd/system/istiod-fit-strategy.timer
install -m 0644 "$here/systemd/receipt-chain-watch.service" /etc/systemd/system/receipt-chain-watch.service
install -m 0644 "$here/systemd/receipt-chain-watch.timer"   /etc/systemd/system/receipt-chain-watch.timer
install -m 0644 "$here/systemd/receipt-chain-watch@.service" /etc/systemd/system/receipt-chain-watch@.service
install -m 0644 "$here/systemd/receipt-chain-watch@.timer"   /etc/systemd/system/receipt-chain-watch@.timer
install -m 0644 "$here/systemd/szl-ns-scratch-watch.service" /etc/systemd/system/szl-ns-scratch-watch.service
install -m 0644 "$here/systemd/szl-ns-scratch-watch.timer"   /etc/systemd/system/szl-ns-scratch-watch.timer
install -m 0644 "$here/systemd/szl-ns-scratch-stale-watch.service" /etc/systemd/system/szl-ns-scratch-stale-watch.service
install -m 0644 "$here/systemd/szl-ns-scratch-stale-watch.timer"   /etc/systemd/system/szl-ns-scratch-stale-watch.timer
install -m 0644 "$here/systemd/a11oy-uptime-check.service"  /etc/systemd/system/a11oy-uptime-check.service
install -m 0644 "$here/systemd/a11oy-uptime-check.timer"    /etc/systemd/system/a11oy-uptime-check.timer
install -m 0644 "$here/systemd/dns-drift-check.service"     /etc/systemd/system/dns-drift-check.service
install -m 0644 "$here/systemd/dns-drift-check.timer"       /etc/systemd/system/dns-drift-check.timer
install -m 0644 "$here/systemd/box-scripts-drift-check.service" /etc/systemd/system/box-scripts-drift-check.service
install -m 0644 "$here/systemd/box-scripts-drift-check.timer"   /etc/systemd/system/box-scripts-drift-check.timer
install -m 0644 "$here/systemd/szl-alert-relay.service"      /etc/systemd/system/szl-alert-relay.service

# The uptime/DNS watchers read their push-notification channel from
# /etc/a11oy-uptime.env. That channel is a PRIVATE secret (an ntfy topic, etc.)
# and is deliberately NOT kept in this public repo. The units reference it as an
# OPTIONAL EnvironmentFile (the leading "-"), so the watchers run in log-only
# mode until the channel is restored. Seed a commented-out stub if absent so the
# file exists and the operator knows where the channel lives; never clobber a
# hand-filled one. To actually restore the channel after a wipe, see
# deploy/hetzner/a11oy-uptime/install.sh (A11OY_UPTIME_ENV_SRC=... or NTFY_URL=...).
if [ ! -e /etc/a11oy-uptime.env ]; then
  cat > /etc/a11oy-uptime.env <<'EOF'
# a11oy.net alert push channel (PRIVATE — keep out of git).
# Restore the real channel via deploy/hetzner/a11oy-uptime/install.sh, e.g.
#   sudo A11OY_UPTIME_ENV_SRC=/root/a11oy-uptime.env.secret bash install.sh
# or set one of the discrete channels below. Until then alerts are log-only.
#NTFY_URL=https://ntfy.sh/a11oy-uptime-XXXXXXXX
#NTFY_TOKEN=
#NTFY_PRIORITY=high
#TELEGRAM_BOT_TOKEN=
#TELEGRAM_CHAT_ID=
#WEBHOOK_URL=
#WEBHOOK_KIND=slack
EOF
  chmod 600 /etc/a11oy-uptime.env
  echo "[install] seeded commented-out /etc/a11oy-uptime.env (alerts log-only until a channel is set)"
fi

# szl-alert-relay config (RELAY_TOKEN). PRIVATE — not in git. Seed a stub with a
# freshly generated token if absent (never clobber a hand-filled one). The relay
# refuses POSTs with 503 until RELAY_TOKEN is non-empty.
if [ ! -e /etc/szl-alert-relay.env ]; then
  gen_tok="$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n' 2>/dev/null || true)"
  cat > /etc/szl-alert-relay.env <<EOF
# szl-alert-relay config (PRIVATE — keep out of git).
# The public webhook URL is https://a11oy.net/relay/ntfy/<RELAY_TOKEN> — point
# the szl-holdings/a11oy SLACK_WEBHOOK_URL secret at it. See
# box-scripts/szl-alert-relay.README.md.
RELAY_TOKEN=${gen_tok}
RELAY_PORT=9099
NOTIFY_CMD=/usr/local/sbin/a11oy-uptime-notify
NOTIFY_TITLE=Rekor receipt re-check
NTFY_PRIORITY=high
EOF
  chmod 600 /etc/szl-alert-relay.env
  echo "[install] seeded /etc/szl-alert-relay.env with a fresh RELAY_TOKEN"
fi

# Install the nginx location snippet and idempotently wire it into the a11oy.net
# vhost just before `location / {`. nginx loads EVERY file in sites-enabled/, so
# relocate any stray backup out of the include glob before testing/reloading,
# else nginx -t fails on a duplicate default_server and it looks like this broke
# nginx (it didn't). See memory: nginx-sites-enabled-loads-everything.
install -d -m 0755 /etc/nginx/snippets
install -m 0644 "$here/szl-alert-relay-nginx.snippet.conf" /etc/nginx/snippets/szl-alert-relay.conf
vhost=/etc/nginx/sites-available/a11oy
if [ -f "$vhost" ]; then
  if ! grep -q 'snippets/szl-alert-relay.conf' "$vhost"; then
    # Insert the include before the FIRST `location / {` in the file.
    awk '
      !done && /^[[:space:]]*location[[:space:]]*\/[[:space:]]*\{/ {
        print "    include /etc/nginx/snippets/szl-alert-relay.conf;";
        print "";
        done=1
      }
      { print }
    ' "$vhost" > "${vhost}.relaywire.$$" && mv "${vhost}.relaywire.$$" "$vhost"
    echo "[install] wired szl-alert-relay include into $vhost"
  fi
  # Relocate stray non-config files out of sites-enabled before testing.
  for f in /etc/nginx/sites-enabled/*.bak* /etc/nginx/sites-enabled/*.orig \
           /etc/nginx/sites-enabled/*.emergency /etc/nginx/sites-enabled/*~; do
    [ -e "$f" ] || continue
    install -d -m 0755 /etc/nginx/backups-relay
    mv "$f" /etc/nginx/backups-relay/ && echo "[install] relocated stray $f out of sites-enabled"
  done
  if nginx -t 2>/dev/null; then
    systemctl reload nginx && echo "[install] nginx reloaded with relay location"
  else
    echo "[install] WARNING: nginx -t failed; NOT reloading. Inspect 'nginx -t'." >&2
  fi
else
  echo "[install] NOTE: $vhost not found; copy the snippet's location block into the a11oy 443 server block manually."
fi

# receipt-chain-watch additional clusters: the primary uds-szl-demo cluster is
# watched by the plain receipt-chain-watch.timer; every OTHER cluster on this box
# (e.g. the multi-node uds-tenant cluster) is watched by a TEMPLATED instance
# receipt-chain-watch@<cluster>.timer that runs the SAME guard with CLUSTER set
# to the systemd instance name. Per-cluster tunables (KUBECONFIG_FILE, namespaces,
# SINCE, ...) live in /etc/receipt-chain-watch/<cluster>.env. Override the set of
# extra clusters with RECEIPT_WATCH_EXTRA_CLUSTERS="a b c" ./install.sh.
install -d -m 0755 /etc/receipt-chain-watch
read -r -a receipt_extra_clusters <<< "${RECEIPT_WATCH_EXTRA_CLUSTERS:-uds-tenant}"
for c in "${receipt_extra_clusters[@]}"; do
  [ -n "$c" ] || continue
  envf="/etc/receipt-chain-watch/${c}.env"
  if [ ! -e "$envf" ]; then
    if [ -f "$here/etc/receipt-chain-watch/${c}.env" ]; then
      install -m 0644 "$here/etc/receipt-chain-watch/${c}.env" "$envf"
    else
      printf '# receipt-chain-watch tunables for cluster %s (see box-scripts/README.md).\n#KUBECONFIG_FILE=\n#RNS=szl-receipts\n#RDEPLOY=szl-receipts-server\n#PNS=pepr-system\n#PDEPLOY=pepr-szl\n#SINCE=8m\n' "$c" > "$envf"
      chmod 0644 "$envf"
    fi
    echo "[install] seeded $envf"
  fi
done

echo "[install] reloading systemd + enabling units ..."
systemctl daemon-reload
systemctl enable --now a11oy-coexist.service
systemctl enable --now a11oy-port-guard.timer
systemctl enable --now szl-core-rightsize.timer
systemctl enable --now istiod-fit-strategy.timer
systemctl enable --now receipt-chain-watch.timer
for c in "${receipt_extra_clusters[@]}"; do
  [ -n "$c" ] || continue
  systemctl enable --now "receipt-chain-watch@${c}.timer"
done
systemctl enable --now szl-ns-scratch-watch.timer
systemctl enable --now szl-ns-scratch-stale-watch.timer
systemctl enable --now a11oy-uptime-check.timer
systemctl enable --now dns-drift-check.timer
systemctl enable --now box-scripts-drift-check.timer
systemctl enable --now szl-alert-relay.service

# Bring the cluster guards into a conformant state right now (idempotent no-ops
# if the cluster is down or already conformant).
[ -x /usr/local/sbin/szl-core-rightsize ]  && /usr/local/sbin/szl-core-rightsize  || true
[ -x /usr/local/sbin/istiod-fit-strategy ] && /usr/local/sbin/istiod-fit-strategy || true
[ -x /usr/local/sbin/receipt-chain-watch ]  && /usr/local/sbin/receipt-chain-watch   || true
for c in "${receipt_extra_clusters[@]}"; do
  [ -n "$c" ] || continue
  systemctl start "receipt-chain-watch@${c}.service" || true
done
[ -x /usr/local/sbin/szl-ns-scratch-watch ] && /usr/local/sbin/szl-ns-scratch-watch  || true
[ -x /usr/local/sbin/szl-ns-scratch-stale-watch ] && /usr/local/sbin/szl-ns-scratch-stale-watch || true

echo "[install] done. current status:"
a11oy-mode status || true
