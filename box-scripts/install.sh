#!/usr/bin/env bash
#
# install.sh — reinstall the box 167.233.50.75 host-level helper scripts and
# systemd units that are NOT otherwise under version control. Covers:
#   1. a11oy.net <-> UDS cluster port-coexistence (Task #179)
#   2. the 2-vCPU headroom self-heal guards for the uds-szl-demo cluster:
#        szl-core-rightsize   — pin UDS-core HA components to single-replica
#        istiod-fit-strategy  — keep istiod rollout/HPA fitting on 2 vCPU
#        receipt-chain-watch  — alarm when signed deploy receipts stop recording
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

echo "[install] reloading systemd + enabling units ..."
systemctl daemon-reload
systemctl enable --now a11oy-coexist.service
systemctl enable --now a11oy-port-guard.timer
systemctl enable --now szl-core-rightsize.timer
systemctl enable --now istiod-fit-strategy.timer
systemctl enable --now receipt-chain-watch.timer

# Bring the cluster guards into a conformant state right now (idempotent no-ops
# if the cluster is down or already conformant).
[ -x /usr/local/sbin/szl-core-rightsize ]  && /usr/local/sbin/szl-core-rightsize  || true
[ -x /usr/local/sbin/istiod-fit-strategy ] && /usr/local/sbin/istiod-fit-strategy || true
[ -x /usr/local/sbin/receipt-chain-watch ]  && /usr/local/sbin/receipt-chain-watch   || true

echo "[install] done. current status:"
a11oy-mode status || true
