<!-- Copyright 2026 SZL Holdings. SPDX-License-Identifier: Apache-2.0 -->
# vault-keystore-offbox-backup — durable off-box copy of the receipt signing key

## What & why

`scripts/vault-keystore-backup.sh` snapshots the Vault barrier (`/vault/data`)
plus its matching Shamir unseal shares (`/root/vault-init/init.json`) under
`/root/vault-keystore-backup/<ts>` so the szl-receipts Transit signing key
survives a `k3d cluster delete` / `uds run recreate-full`. But that snapshot
lives **only host-local**: if box `167.233.50.75`'s disk dies, the snapshot — and
with it the signing key and **every receipt's verifiability** — is gone for good.

`vault-keystore-offbox-backup` closes that single-point-of-failure. On a schedule
it takes the latest snapshot, **encrypts it on the box**, and ships the ciphertext
to **durable off-box storage** with retention/rotation.

## Security model (read before configuring)

The snapshot contains the unseal share(s) + root token **and** the encrypted
barrier — i.e. everything needed to *use* the signing key. So:

- The plaintext tar is built in a root-only `0700` temp dir and **shredded** the
  moment the ciphertext exists. **Only the `*.tar.gz.gpg` ciphertext ever leaves
  the box.**
- Prefer **asymmetric** GPG (`OFFBOX_GPG_RECIPIENT`): the box holds only the
  recipient *public* key; the *private* key lives off-box with the operator, so a
  box compromise cannot decrypt past off-box copies. A symmetric passphrase
  (`OFFBOX_GPG_PASSPHRASE_FILE`) is supported as a fallback.
- The destination must **still be treated as secret** — no plaintext, no shared
  bucket. Encryption is defence in depth, not licence to use a public bucket.

## Config — `/etc/vault-keystore-offbox.env` (PRIVATE, not in git)

`box-scripts/install.sh` seeds a commented-out stub. Set **one** encryption
method and **one** destination, then the weekly timer starts shipping. Until both
are set the job is a safe **log-only no-op** (never pages).

```sh
# --- encryption (pick one) ---
OFFBOX_GPG_RECIPIENT=ABCDEF0123456789        # pubkey already in root's gpg keyring
# OFFBOX_GPG_PASSPHRASE_FILE=/root/vault-keystore-offbox.pass   # root:600 fallback

# --- destination (pick one; transport auto-detected, or force OFFBOX_TRANSPORT) ---
OFFBOX_SSH_TARGET=backup@second-host:/srv/szl/vault-keystore   # ssh/scp to a 2nd host
OFFBOX_SSH_KEY=/root/.ssh/offbox_backup
# OFFBOX_LOCAL_DIR=/mnt/offbox/vault-keystore                  # a mounted 2nd volume
# OFFBOX_RCLONE_REMOTE=offbox:szl/vault-keystore               # any rclone remote
# OFFBOX_S3_URI=s3://my-bucket/szl/vault-keystore              # S3-compatible store
# OFFBOX_S3_ENDPOINT=https://...                               # non-AWS S3 endpoint

# --- retention (keep newest N off-box copies; older pruned) ---
OFFBOX_KEEP=14
```

Importing the recipient public key on the box (asymmetric, recommended):
```sh
gpg --import /root/offbox-restore-pubkey.asc     # the PUBLIC half only
gpg --list-keys                                  # copy the key id into OFFBOX_GPG_RECIPIENT
```

## Install / schedule

Installed and enabled by `box-scripts/install.sh`:
- `/usr/local/sbin/vault-keystore-offbox-backup`
- `vault-keystore-offbox-backup.{service,timer}` (weekly, `Persistent=true`).

Run once by hand: `sudo systemctl start vault-keystore-offbox-backup.service`
then `journalctl -u vault-keystore-offbox-backup --no-pager -n 50`.
Last-run state: `/var/lib/vault-keystore-offbox/status.json`.

## Alerting

Mirrors the other box watchers: edge-triggered + de-duped via
`/var/lib/vault-keystore-offbox/state`, pages ntfy `a11oy-uptime-notify` on the
healthy→fail edge and once on RECOVERED. A **configured** push that fails is an
ALERT (the off-box copy is now stale); an **unconfigured** job never pages.

## Restore (box is gone)

See `docs/operations/VAULT_PERSISTENT_RUNBOOK.md` § 7 "Recover the signing key
from the off-box copy" — pull the newest `vault-keystore-*.tar.gz.gpg`, verify
its `.sha256`, decrypt with the off-box private key (or passphrase), unpack to
`/root/vault-keystore-backup/<ts>`, then run `scripts/vault-keystore-restore.sh`.
