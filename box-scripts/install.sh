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
#        szl-receipts-retention — daily verify-store + archive sealed shards off
#                               the live PVC (keeps the receipt store bounded;
#                               alerts on chain_ok=false / skipped buckets)
#        szl-receipts-cold-offsite — daily mirror of the box cold receipt archive
#                               OFFSITE (object bucket / 2nd host) so the sealed
#                               history survives box loss; sha256-verified against
#                               the bucket manifests, append-only, alerts on failure
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
install -m 0755 "$here/sbin/receipt-flood-watch"       /usr/local/sbin/receipt-flood-watch
install -m 0755 "$here/sbin/szl-receipts-retention"    /usr/local/sbin/szl-receipts-retention
install -m 0755 "$here/sbin/szl-receipts-cold-offsite" /usr/local/sbin/szl-receipts-cold-offsite
install -m 0755 "$here/sbin/szl-ns-scratch"            /usr/local/sbin/szl-ns-scratch
install -m 0755 "$here/sbin/szl-ns-scratch-watch"      /usr/local/sbin/szl-ns-scratch-watch
install -m 0755 "$here/sbin/szl-ns-scratch-stale-watch" /usr/local/sbin/szl-ns-scratch-stale-watch
install -m 0755 "$here/sbin/a11oy-uptime-check"        /usr/local/sbin/a11oy-uptime-check
install -m 0755 "$here/sbin/a11oy-uptime-notify"       /usr/local/sbin/a11oy-uptime-notify
install -m 0755 "$here/sbin/dns-drift-check"           /usr/local/sbin/dns-drift-check
install -m 0755 "$here/sbin/box-scripts-drift-check"     /usr/local/sbin/box-scripts-drift-check
install -m 0755 "$here/sbin/szl-alert-relay"           /usr/local/sbin/szl-alert-relay
install -m 0755 "$here/sbin/szl-alert-relay-watch"     /usr/local/sbin/szl-alert-relay-watch
install -m 0755 "$here/sbin/szl-signing-health-check"  /usr/local/sbin/szl-signing-health-check
install -m 0755 "$here/sbin/a11oy-signing-key-watch"   /usr/local/sbin/a11oy-signing-key-watch
install -m 0755 "$here/sbin/szl-receipts-orphan-watch" /usr/local/sbin/szl-receipts-orphan-watch
install -m 0755 "$here/sbin/vault-auto-unseal"          /usr/local/sbin/vault-auto-unseal
install -m 0755 "$here/sbin/vault-keystore-offbox-backup" /usr/local/sbin/vault-keystore-offbox-backup
install -m 0755 "$here/sbin/authelia-rotate-demo"      /usr/local/sbin/authelia-rotate-demo
install -m 0755 "$here/sbin/szl-receipt-checkpoint"     /usr/local/sbin/szl-receipt-checkpoint

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
install -m 0644 "$here/systemd/receipt-flood-watch.service" /etc/systemd/system/receipt-flood-watch.service
install -m 0644 "$here/systemd/receipt-flood-watch.timer"   /etc/systemd/system/receipt-flood-watch.timer
install -m 0644 "$here/systemd/receipt-flood-watch@.service" /etc/systemd/system/receipt-flood-watch@.service
install -m 0644 "$here/systemd/receipt-flood-watch@.timer"   /etc/systemd/system/receipt-flood-watch@.timer
install -m 0644 "$here/systemd/szl-receipts-retention.service" /etc/systemd/system/szl-receipts-retention.service
install -m 0644 "$here/systemd/szl-receipts-retention.timer"   /etc/systemd/system/szl-receipts-retention.timer
install -m 0644 "$here/systemd/szl-receipts-cold-offsite.service" /etc/systemd/system/szl-receipts-cold-offsite.service
install -m 0644 "$here/systemd/szl-receipts-cold-offsite.timer"   /etc/systemd/system/szl-receipts-cold-offsite.timer
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
install -m 0644 "$here/systemd/szl-alert-relay-watch.service"     /etc/systemd/system/szl-alert-relay-watch.service
install -m 0644 "$here/systemd/szl-alert-relay-watch.timer"       /etc/systemd/system/szl-alert-relay-watch.timer
install -m 0644 "$here/systemd/szl-signing-health-check.service"  /etc/systemd/system/szl-signing-health-check.service
install -m 0644 "$here/systemd/szl-signing-health-check.timer"    /etc/systemd/system/szl-signing-health-check.timer
install -m 0644 "$here/systemd/a11oy-signing-key-watch.service"   /etc/systemd/system/a11oy-signing-key-watch.service
install -m 0644 "$here/systemd/a11oy-signing-key-watch.timer"     /etc/systemd/system/a11oy-signing-key-watch.timer
install -m 0644 "$here/systemd/szl-receipts-orphan-watch.service" /etc/systemd/system/szl-receipts-orphan-watch.service
install -m 0644 "$here/systemd/szl-receipts-orphan-watch.timer"   /etc/systemd/system/szl-receipts-orphan-watch.timer
install -m 0644 "$here/systemd/vault-auto-unseal.service"   /etc/systemd/system/vault-auto-unseal.service
install -m 0644 "$here/systemd/vault-auto-unseal.timer"     /etc/systemd/system/vault-auto-unseal.timer
install -m 0644 "$here/systemd/vault-keystore-offbox-backup.service" /etc/systemd/system/vault-keystore-offbox-backup.service
install -m 0644 "$here/systemd/vault-keystore-offbox-backup.timer"   /etc/systemd/system/vault-keystore-offbox-backup.timer
install -m 0644 "$here/systemd/authelia-rotate-demo.service" /etc/systemd/system/authelia-rotate-demo.service
install -m 0644 "$here/systemd/authelia-rotate-demo.timer"   /etc/systemd/system/authelia-rotate-demo.timer
install -m 0644 "$here/systemd/szl-receipt-checkpoint.service" /etc/systemd/system/szl-receipt-checkpoint.service
install -m 0644 "$here/systemd/szl-receipt-checkpoint.timer"   /etc/systemd/system/szl-receipt-checkpoint.timer

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

# The szl-receipt-checkpoint job writes a TAMPER-EVIDENT checkpoint of the live
# receipt-log chain head to the dedicated `receipts-checkpoint` branch — a branch
# the receipts-server pod has NO token for (that is the point). The org GitHub
# token is a PRIVATE secret and is NEVER committed to git. Seed a commented-out
# stub if absent so the file exists and the operator knows where the token lives;
# never clobber a hand-filled one. Until a token is set the daily job still RUNS
# and VERIFIES the live chain every cycle (fail-soft) — it just cannot read or
# advance the durable anchor.
if [ ! -e /etc/szl-receipt-checkpoint.env ]; then
  cat > /etc/szl-receipt-checkpoint.env <<'EOF'
# szl-receipt-checkpoint config (PRIVATE - keep OUT of git).
# Org GitHub token (owner) used to read/advance the durable receipt-log
# checkpoint on the dedicated `receipts-checkpoint` branch. Until set, the daily
# checkpoint job verifies the live chain but cannot read/write the anchor.
#SZL_GITHUB_TOKEN=ghp_XXXXXXXXXXXXXXXXXXXX
# Optional overrides (defaults already target the live box):
#SZL_CHECKPOINT_REPO=szl-holdings/szl-uds-deployment
#SZL_CHECKPOINT_BRANCH=receipts-checkpoint
#SZL_CHECKPOINT_PATH=receipts/checkpoint.json
EOF
  chmod 600 /etc/szl-receipt-checkpoint.env
  echo "[install] seeded commented-out /etc/szl-receipt-checkpoint.env (checkpoint anchor read/write disabled until a token is set)"
fi


# The off-box Vault-keystore backup (vault-keystore-offbox-backup) ships an
# ENCRYPTED copy of the signing-key keystore (barrier + unseal shares) to durable
# storage off this box. Its config is a PRIVATE secret (encryption recipient +
# destination) and is NEVER committed to git. Seed a commented-out stub so the
# job installs as a SAFE log-only no-op until an operator fills it in. The unit
# loads it as an OPTIONAL EnvironmentFile (leading "-").
if [ ! -e /etc/vault-keystore-offbox.env ]; then
  cat > /etc/vault-keystore-offbox.env <<'EOF'
# vault-keystore off-box backup config (PRIVATE - keep OUT of git).
# Set ONE encryption method AND ONE destination, then the weekly timer ships an
# encrypted copy off the box. Until both are set this job is a log-only no-op.
#
# --- encryption (pick one) ---
# Asymmetric (recommended): the box holds only the recipient PUBLIC key; the
# private key lives OFF-BOX with the operator for restore.
#OFFBOX_GPG_RECIPIENT=YOUR_PUBKEY_ID
# Symmetric fallback (root:600 passphrase file):
#OFFBOX_GPG_PASSPHRASE_FILE=/root/vault-keystore-offbox.pass
#
# --- destination (pick one; transport auto-detected, or force OFFBOX_TRANSPORT) ---
#OFFBOX_SSH_TARGET=backup@second-host:/srv/szl/vault-keystore
#OFFBOX_SSH_KEY=/root/.ssh/offbox_backup
#OFFBOX_LOCAL_DIR=/mnt/offbox/vault-keystore
#OFFBOX_RCLONE_REMOTE=offbox:szl/vault-keystore
#OFFBOX_S3_URI=s3://my-bucket/szl/vault-keystore
#OFFBOX_S3_ENDPOINT=
#
# --- retention (keep newest N off-box copies) ---
#OFFBOX_KEEP=14
EOF
  chmod 600 /etc/vault-keystore-offbox.env
  echo "[install] seeded commented-out /etc/vault-keystore-offbox.env (off-box keystore backup log-only until configured)"
fi


# The offsite receipt-cold mirror (szl-receipts-cold-offsite) replicates the box
# cold receipt archive to a SECOND location so the sealed history survives box
# loss. Its destination is a PRIVATE config (an object bucket / 2nd host) and is
# NEVER committed to git. Seed a commented-out stub so the job installs as a SAFE
# no-op (SKIPPED_UNCONFIGURED) until an operator fills it in. The unit loads it as
# an OPTIONAL EnvironmentFile (leading "-"). Receipts are signed integrity
# records (not secrets) so the mirror is PLAINTEXT — the manifest tarball_sha256
# stays verifiable against the offsite object.
if [ ! -e /etc/szl-receipts-cold-offsite.env ]; then
  cat > /etc/szl-receipts-cold-offsite.env <<'EOF'
# szl-receipts cold-archive OFFSITE mirror config (PRIVATE - keep OUT of git).
# Set exactly ONE destination, then the daily timer mirrors the box cold archive
# (/var/lib/szl-receipts-cold) offsite. Until one is set this job is a no-op.
#
# --- destination (pick one; transport auto-detected, or force OFFSITE_TRANSPORT) ---
#OFFSITE_SSH_TARGET=backup@second-host:/srv/szl/receipts-cold
#OFFSITE_SSH_KEY=/root/.ssh/offsite_backup
#OFFSITE_LOCAL_DIR=/mnt/offsite/receipts-cold
#OFFSITE_RCLONE_REMOTE=offsite:szl/receipts-cold
#OFFSITE_S3_URI=s3://my-bucket/szl/receipts-cold
#OFFSITE_S3_ENDPOINT=
#
# --- optional: force the transport (ssh|local|rclone|s3) ---
#OFFSITE_TRANSPORT=
EOF
  chmod 600 /etc/szl-receipts-cold-offsite.env
  echo "[install] seeded commented-out /etc/szl-receipts-cold-offsite.env (offsite mirror log-only until a destination is set)"
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
install -d -m 0755 /etc/receipt-flood-watch
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
  # Companion flood watcher for the same extra cluster.
  floodf="/etc/receipt-flood-watch/${c}.env"
  if [ ! -e "$floodf" ]; then
    if [ -f "$here/etc/receipt-flood-watch/${c}.env" ]; then
      install -m 0644 "$here/etc/receipt-flood-watch/${c}.env" "$floodf"
    else
      printf '# receipt-flood-watch tunables for cluster %s (see box-scripts/README.md).\n#KUBECONFIG_FILE=\n#RNS=szl-receipts\n#RX_SELECTOR=app.kubernetes.io/name=szl-receipts-server\n#RX_CONTAINER=receipts-server\n#METRICS_PORT=8080\n#FLOOD_PER_MIN=120\n#MIN_INTERVAL_SECS=60\n' "$c" > "$floodf"
      chmod 0644 "$floodf"
    fi
    echo "[install] seeded $floodf"
  fi
done

# --- box-scripts-drift self-heal opt-in (one-flip switch) -------------------
# Self-heal is OFF by default: a drifted host file may be a deliberate hot-fix
# to back-port to the repo, not clobber. Flip it on for THIS box by re-running
# with SELF_HEAL=1; optionally scope it to a tight set of files whose committed
# copy is the unambiguous source of truth via WATCH_SBIN / WATCH_UNITS:
#     SELF_HEAL=1 sudo ./install.sh
#     SELF_HEAL=1 WATCH_SBIN="dns-drift-check" \
#       WATCH_UNITS="dns-drift-check.service" sudo ./install.sh
#     SELF_HEAL=0 sudo ./install.sh      # turn it back off (removes the drop-in)
# The flag rides a systemd drop-in so the watched unit file itself is never
# edited on the host (editing it would make box-scripts-drift-check.service
# drift from its own committed copy and the watcher would alert on itself).
# A plain re-install with SELF_HEAL unset leaves the current state untouched.
selfheal_dropin_dir="/etc/systemd/system/box-scripts-drift-check.service.d"
selfheal_dropin="$selfheal_dropin_dir/10-self-heal.conf"
case "${SELF_HEAL:-}" in
  1|true|yes|on)
    install -d -m 0755 "$selfheal_dropin_dir"
    selfheal_tmp="$(mktemp)"
    {
      echo "# Managed by box-scripts/install.sh (SELF_HEAL=1). Do not edit by hand."
      echo "# Remove with: SELF_HEAL=0 sudo box-scripts/install.sh"
      echo "[Service]"
      echo "Environment=SELF_HEAL=1"
      [ -n "${WATCH_SBIN+set}" ]  && echo "Environment=WATCH_SBIN=${WATCH_SBIN}"
      [ -n "${WATCH_UNITS+set}" ] && echo "Environment=WATCH_UNITS=${WATCH_UNITS}"
    } > "$selfheal_tmp"
    if cmp -s "$selfheal_tmp" "$selfheal_dropin" 2>/dev/null; then
      echo "[install] box-scripts-drift self-heal already ENABLED (drop-in unchanged)"
    else
      install -m 0644 "$selfheal_tmp" "$selfheal_dropin"
      echo "[install] box-scripts-drift self-heal ENABLED -> $selfheal_dropin"
    fi
    rm -f "$selfheal_tmp"
    ;;
  0|false|no|off)
    if [ -f "$selfheal_dropin" ]; then
      rm -f "$selfheal_dropin"
      rmdir "$selfheal_dropin_dir" 2>/dev/null || true
      echo "[install] box-scripts-drift self-heal DISABLED (removed drop-in)"
    else
      echo "[install] box-scripts-drift self-heal already OFF (no drop-in)"
    fi
    ;;
  "")
    if [ -f "$selfheal_dropin" ]; then
      echo "[install] box-scripts-drift self-heal: ON (existing drop-in left untouched; SELF_HEAL=0 to disable)"
    else
      echo "[install] box-scripts-drift self-heal: OFF (default; SELF_HEAL=1 to enable)"
    fi
    ;;
  *)
    echo "[install] WARN ignoring unrecognized SELF_HEAL='${SELF_HEAL}' (use 1/0); leaving drop-in untouched" >&2
    ;;
esac

echo "[install] reloading systemd + enabling units ..."
systemctl daemon-reload
systemctl enable --now a11oy-coexist.service
systemctl enable --now a11oy-port-guard.timer
systemctl enable --now szl-core-rightsize.timer
systemctl enable --now istiod-fit-strategy.timer
systemctl enable --now receipt-chain-watch.timer
systemctl enable --now receipt-flood-watch.timer
for c in "${receipt_extra_clusters[@]}"; do
  [ -n "$c" ] || continue
  systemctl enable --now "receipt-chain-watch@${c}.timer"
  systemctl enable --now "receipt-flood-watch@${c}.timer"
done
systemctl enable --now szl-receipts-retention.timer
systemctl enable --now szl-receipts-cold-offsite.timer
systemctl enable --now szl-ns-scratch-watch.timer
systemctl enable --now szl-ns-scratch-stale-watch.timer
systemctl enable --now a11oy-uptime-check.timer
systemctl enable --now dns-drift-check.timer
systemctl enable --now box-scripts-drift-check.timer
systemctl enable --now vault-auto-unseal.timer
systemctl enable --now vault-keystore-offbox-backup.timer
systemctl enable --now authelia-rotate-demo.timer
systemctl enable --now szl-alert-relay.service
systemctl enable --now szl-alert-relay-watch.timer
systemctl enable --now szl-signing-health-check.timer
systemctl enable --now a11oy-signing-key-watch.timer
systemctl enable --now szl-receipts-orphan-watch.timer
systemctl enable --now szl-receipt-checkpoint.timer

# Bring the cluster guards into a conformant state right now (idempotent no-ops
# if the cluster is down or already conformant).
[ -x /usr/local/sbin/szl-core-rightsize ]  && /usr/local/sbin/szl-core-rightsize  || true
[ -x /usr/local/sbin/istiod-fit-strategy ] && /usr/local/sbin/istiod-fit-strategy || true
[ -x /usr/local/sbin/receipt-chain-watch ]  && /usr/local/sbin/receipt-chain-watch   || true
[ -x /usr/local/sbin/receipt-flood-watch ]  && /usr/local/sbin/receipt-flood-watch   || true
for c in "${receipt_extra_clusters[@]}"; do
  [ -n "$c" ] || continue
  systemctl start "receipt-chain-watch@${c}.service" || true
  systemctl start "receipt-flood-watch@${c}.service" || true
done
# Run retention once now (idempotent no-op if the cluster is down or nothing is
# sealed to archive).
[ -x /usr/local/sbin/szl-receipts-retention ] && /usr/local/sbin/szl-receipts-retention || true
# Mirror the cold archive offsite once now (idempotent no-op if unconfigured or
# there is nothing new to mirror).
[ -x /usr/local/sbin/szl-receipts-cold-offsite ] && /usr/local/sbin/szl-receipts-cold-offsite || true
[ -x /usr/local/sbin/szl-ns-scratch-watch ] && /usr/local/sbin/szl-ns-scratch-watch  || true
[ -x /usr/local/sbin/szl-ns-scratch-stale-watch ] && /usr/local/sbin/szl-ns-scratch-stale-watch || true
# Alert-only watchers (idempotent: cluster/endpoint down = no-op, no false page).
[ -x /usr/local/sbin/szl-alert-relay-watch ] && /usr/local/sbin/szl-alert-relay-watch || true
[ -x /usr/local/sbin/szl-signing-health-check ] && /usr/local/sbin/szl-signing-health-check || true
[ -x /usr/local/sbin/szl-receipts-orphan-watch ] && /usr/local/sbin/szl-receipts-orphan-watch || true

echo "[install] done. current status:"
a11oy-mode status || true
