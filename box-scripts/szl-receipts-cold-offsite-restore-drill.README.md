# szl-receipts-cold-offsite-restore-drill — prove the OFFSITE backup can be RESTORED

A periodic systemd job on box `167.233.50.75` that **restores** one mirrored
cold receipt bucket back from the offsite destination and proves it is usable —
turning the offsite copy from a *hope* into a *tested backup*.

## Why it exists

[`szl-receipts-cold-offsite`](szl-receipts-cold-offsite.README.md) mirrors each
sealed cold bucket (`<bucket>.tar.gz` + `<bucket>.manifest.json`) off the box and
sha256-verifies the upload **at write time**.
[`szl-receipts-cold-archive-audit`](../docs/operations/RECEIPT_STORE_RETENTION_RUNBOOK.md)
re-verifies the **on-box** cold tarballs offline. But nothing ever exercises the
**restore path** — pulling a bucket back *down* and confirming it still unpacks.
An untested backup is a hope: offsite credentials can rot, a remote can silently
start returning truncated/empty objects, a lifecycle rule can expire objects, or
the bucket can become unreadable, and the upload-time mirror (which only writes
*up*) would never notice. The first time anyone discovers the offsite copy cannot
be restored must not be the day the box is gone. This drill closes that gap.

## What it does (one bucket per run, read-only against offsite)

1. Resolves the **same** offsite destination as `szl-receipts-cold-offsite`
   (the `OFFSITE_*` vars from `/etc/szl-receipts-cold-offsite.env`). Unconfigured
   ⇒ `SKIPPED_UNCONFIGURED` no-op, exit 0, **no page**.
2. **Lists** the offsite destination for `<bucket>.manifest.json` objects. None
   yet (nothing mirrored) ⇒ silent no-op, exit 0, no page.
3. Picks **one** bucket to drill (`DRILL_BUCKET` override, else the most recent —
   buckets are zero-padded numeric, so the lexically-highest name is newest).
4. **Downloads** that bucket's `<bucket>.tar.gz` + `<bucket>.manifest.json` from
   offsite into a throwaway scratch dir — the actual restore.
5. **SHA256 gate:** the downloaded tarball's sha256 must equal the downloaded
   manifest's `tarball_sha256`. A mismatch = the offsite copy is corrupt /
   truncated and would not restore ⇒ **ALERT**.
6. **Well-formed gate:** extracts the tarball and confirms it restores into a
   well-formed receipt shard — a top-level `<bucket>/` dir of `*.json` receipts,
   each parseable JSON carrying a `chain` object, and (when the manifest records
   a `count`) exactly that many receipts ⇒ **ALERT** otherwise.
7. Removes the scratch dir. It **never** writes to offsite, the on-box cold
   archive, or the live store — it only reads.

This is deliberately a **structural** restore proof (download + sha256 + unpack
+ shard well-formedness), not a cryptographic re-verification. The per-receipt
Ed25519/DSSE signature + hash-linkage + stitch re-verify is owned by
`szl-receipts-cold-archive-audit` (public key only); this drill stays fully
self-contained with nothing but the offsite credentials, so it keeps proving the
backup is **restorable** even with the cluster down. The two are complementary:
the audit proves the cold bytes are still a valid chain; this drill proves those
bytes can actually be fetched back.

## Transports

Identical to `szl-receipts-cold-offsite` (it reads back the same destination):
`OFFSITE_SSH_TARGET` (ssh/scp), `OFFSITE_LOCAL_DIR` (a mounted volume / 2nd disk),
`OFFSITE_RCLONE_REMOTE` (any rclone remote — S3/B2/GCS/...), or `OFFSITE_S3_URI`
(`aws s3`). Force with `OFFSITE_TRANSPORT=ssh|local|rclone|s3`.

## Alerts (edge-triggered, de-duped)

One page per problem **edge** + one RECOVERED — never every cycle. Alert reasons:
- the bucket's manifest or tarball cannot be **downloaded** (backup unreadable);
- the restored tarball **fails its manifest sha256** (corrupt / truncated);
- the restored tarball **does not unpack into a well-formed shard** (cannot open,
  empty, wrong receipt count, or non-receipt JSON).

Unconfigured (no `OFFSITE_*` destination) or nothing mirrored yet is a **silent
no-op**, never a page. Alerts go out via the shared
`/usr/local/sbin/a11oy-uptime-notify` (ntfy / Telegram / webhook, channel in
`/etc/a11oy-uptime.env`), fail-soft.

## What / where

- `/usr/local/sbin/szl-receipts-cold-offsite-restore-drill` — the job (oneshot).
- `/etc/systemd/system/szl-receipts-cold-offsite-restore-drill.{service,timer}` —
  **weekly**, first run 50 min after boot (after `szl-receipts-cold-offsite`).
- `/etc/szl-receipts-cold-offsite.env` — the **shared** offsite destination
  (same file the mirror uses; the drill is a no-op until it is set).
- State: `/var/lib/szl-receipts-cold-offsite-restore-drill/{last_status,status.json}`.
- Log: `/var/log/szl-receipts-cold-offsite-restore-drill/restore-drill.log`.
- Canonical source: this `box-scripts/` dir; installed by `box-scripts/install.sh`.

## Tunables (env overrides)

`DRILL_BUCKET` (pin which bucket to drill; default = newest), the `OFFSITE_*`
vars, `STATE_DIR`, `LOG_DIR`, `NOTIFY_CMD`, `ALERT_PREFIX`.

## Install / test

- Install (idempotent): `sudo box-scripts/install.sh`.
- Dry, non-alarming smoke run against a throwaway local "offsite" dir (seed it
  with one fake bucket first), no real destination needed:
  ```bash
  off=$(mktemp -d); b=00000001
  printf 'SZL-FAKE' > "$off/$b.tar.gz"; mkdir -p /tmp/rd/$b
  # (a real bucket would carry <bucket>/*.json receipts inside the tarball)
  sha=$(sha256sum "$off/$b.tar.gz" | awk '{print $1}')
  printf '{"tarball_sha256":"%s","count":0}\n' "$sha" > "$off/$b.manifest.json"
  ALERT_PREFIX="[TEST-ignore] " STATE_DIR=/tmp/rd LOG_DIR=/tmp/rd \
    OFFSITE_LOCAL_DIR="$off" /usr/local/sbin/szl-receipts-cold-offsite-restore-drill
  cat /tmp/rd/status.json
  ```
- The behavioural guard (`scripts/szl-receipts-cold-offsite-restore-drill-guard-checks.sh`
  + its `.test.sh`) proves the no-op gates, the sha256 + well-formed gates, the
  happy path, and edge-dedup stay wired.

## Scope

This is the **scheduled restore drill + alert** only. It consumes what
`szl-receipts-cold-offsite` mirrors and proves it can be pulled back and unpacked.
A box rebuild re-installs and re-enables it via `install.sh`; restoring
`/etc/szl-receipts-cold-offsite.env` is the only manual step before the drill
resumes.
