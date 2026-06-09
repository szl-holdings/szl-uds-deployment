#!/usr/bin/env bash
#
# install.sh — reinstall the box 167.233.50.75 host-level helper scripts and
# systemd units that are NOT otherwise under version control. Covers:
#   1. a11oy.net <-> UDS cluster port-coexistence (Task #179)
#   2. the 2-vCPU headroom self-heal guards for the uds-szl-demo cluster:
#        szl-core-rightsize   — pin UDS-core HA components to single-replica
#        istiod-fit-strategy  — keep istiod rollout/HPA fitting on 2 vCPU
#        receipt-chain-watch  — alarm when signed deploy receipts stop recording
#   3. the a11oy.net public-site alerting watchers:
#        a11oy-uptime-check   — probe a11oy.net uptime, alert on the outage edge
#        a11oy-uptime-notify  — shared push notifier (ntfy/Telegram/webhook)
#        dns-drift-check      — alert if a11oy.net DNS stops pointing at the box
#        box-scripts-drift-check — alert if a host sbin/unit drifts from its committed box-scripts/ copy
#   4. szl-ns-scratch — scratch-namespace cleanup-safety tool (no systemd unit;
#        on-demand operator helper, see docs/SCRATCH_NAMESPACE_CONVENTION.md)
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
install -m 0755 "$here/sbin/a11oy-uptime-check"        /usr/local/sbin/a11oy-uptime-check
install -m 0755 "$here/sbin/a11oy-uptime-notify"       /usr/local/sbin/a11oy-uptime-notify
install -m 0755 "$here/sbin/dns-drift-check"           /usr/local/sbin/dns-drift-check
install -m 0755 "$here/sbin/box-scripts-drift-check"     /usr/local/sbin/box-scripts-drift-check

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
install -m 0644 "$here/systemd/a11oy-uptime-check.service"  /etc/systemd/system/a11oy-uptime-check.service
install -m 0644 "$here/systemd/a11oy-uptime-check.timer"    /etc/systemd/system/a11oy-uptime-check.timer
install -m 0644 "$here/systemd/dns-drift-check.service"     /etc/systemd/system/dns-drift-check.service
install -m 0644 "$here/systemd/dns-drift-check.timer"       /etc/systemd/system/dns-drift-check.timer
install -m 0644 "$here/systemd/box-scripts-drift-check.service" /etc/systemd/system/box-scripts-drift-check.service
install -m 0644 "$here/systemd/box-scripts-drift-check.timer"   /etc/systemd/system/box-scripts-drift-check.timer

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

echo "[install] reloading systemd + enabling units ..."
systemctl daemon-reload
systemctl enable --now a11oy-coexist.service
systemctl enable --now a11oy-port-guard.timer
systemctl enable --now szl-core-rightsize.timer
systemctl enable --now istiod-fit-strategy.timer
systemctl enable --now receipt-chain-watch.timer
systemctl enable --now a11oy-uptime-check.timer
systemctl enable --now dns-drift-check.timer
systemctl enable --now box-scripts-drift-check.timer

# Bring the cluster guards into a conformant state right now (idempotent no-ops
# if the cluster is down or already conformant).
[ -x /usr/local/sbin/szl-core-rightsize ]  && /usr/local/sbin/szl-core-rightsize  || true
[ -x /usr/local/sbin/istiod-fit-strategy ] && /usr/local/sbin/istiod-fit-strategy || true
[ -x /usr/local/sbin/receipt-chain-watch ]  && /usr/local/sbin/receipt-chain-watch   || true

echo "[install] done. current status:"
a11oy-mode status || true
