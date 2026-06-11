# szl-receipts-cold-offsite — mirror the cold receipt archive OFFSITE

A periodic systemd job on box `167.233.50.75` that mirrors the **cold receipt
archive** off the box so the sealed receipt history **survives loss of the box**.

It closes the last gap in the receipt-store retention chain. Today
`szl-receipts-retention` keeps the live PVC bounded by offloading each **sealed**
shard bucket onto the box host disk `HOST_COLD_DIR`
(default `/var/lib/szl-receipts-cold`): a `<bucket>.tar.gz` +
`<bucket>.manifest.json` (with `tarball_sha256`) per bucket, plus an append-only
`archived.json` ledger (see
[`docs/operations/RECEIPT_STORE_RETENTION_RUNBOOK.md`](../docs/operations/RECEIPT_STORE_RETENTION_RUNBOOK.md)).
That gives a full-history archive — but **only on the box**. This job copies that
archive to a second location so a box loss is not a history loss.

## What it does

1. Walks `HOST_COLD_DIR` for each sealed bucket (`<bucket>.manifest.json`).
2. **Incremental:** a bucket already mirrored + offsite-verified (a marker in
   `$SYNCED_DIR/<bucket>`) is skipped. Sealed buckets are immutable, so only NEW
   buckets transfer each run.
3. **Local verify gate:** before mirroring, the local `<bucket>.tar.gz` sha256
   must match the manifest `tarball_sha256`. A locally-corrupt archive is **never
   mirrored** — it is paged so the source is fixed, not propagated offsite.
4. Mirrors `<bucket>.tar.gz` + `<bucket>.manifest.json` to the offsite
   destination, **plaintext** — receipts are Ed25519/DSSE-signed integrity
   records, not secrets, so the offsite object stays verifiable against the
   manifest `tarball_sha256`.
5. **Offsite verify gate:** reads back the sha256 of the just-uploaded offsite
   copy (`remote_sha256`) and requires it to equal the manifest `tarball_sha256`.
   Only on a verified match is the `$SYNCED_DIR` marker written — a partial or
   corrupt upload retries next run instead of being recorded as done.
6. **Append-only:** the offsite mirror is never pruned here. Cold storage is the
   durable full-history copy; trimming is a separate deliberate operation.

## Transports (auto-detected from which `OFFSITE_*` var is set)

| set this | transport | mirror via |
| --- | --- | --- |
| `OFFSITE_SSH_TARGET` (`user@host:/path`) [+ `OFFSITE_SSH_KEY`] | `ssh` | `scp` to a 2nd host |
| `OFFSITE_LOCAL_DIR` (`/mnt/offsite/...`) | `local` | `cp` to a mounted volume / 2nd disk |
| `OFFSITE_RCLONE_REMOTE` (`remote:bucket/path`) | `rclone` | any rclone remote (S3/B2/GCS/...) |
| `OFFSITE_S3_URI` (`s3://bucket/path`) [+ `OFFSITE_S3_ENDPOINT`] | `s3` | `aws s3 cp` |

Force a transport with `OFFSITE_TRANSPORT=ssh|local|rclone|s3`. The most
self-contained choice is `local` (a separate disk or an NFS/object mount).

## Alerts (edge-triggered, de-duped)

One page per problem **edge** + one RECOVERED — never every cycle. Alert reasons:
- a bucket's **local** tarball fails its manifest sha256 (corrupt on box — not
  mirrored);
- an offsite transfer fails;
- the **offsite** copy fails its sha256 verification (`remote_sha256` ≠ manifest).

Unconfigured (no `OFFSITE_*` destination) or an empty cold dir is a **silent
no-op** (`SKIPPED_UNCONFIGURED` / nothing to mirror), never a page. Alerts go out
via the shared `/usr/local/sbin/a11oy-uptime-notify` (ntfy / Telegram / webhook,
channel in `/etc/a11oy-uptime.env`), fail-soft.

## What / where

- `/usr/local/sbin/szl-receipts-cold-offsite` — the job (oneshot).
- `/etc/systemd/system/szl-receipts-cold-offsite.{service,timer}` — **daily**,
  first run 40 min after boot (after `szl-receipts-retention`).
- `/etc/szl-receipts-cold-offsite.env` — PRIVATE offsite destination (seeded
  commented-out by `install.sh`; job is a no-op until set).
- Source cold archive: `/var/lib/szl-receipts-cold/` on the box.
- Sync markers: `/var/lib/szl-receipts-cold-offsite/synced/<bucket>`.
- State: `/var/lib/szl-receipts-cold-offsite/{last_status,status.json}`.
- Log: `/var/log/szl-receipts-cold-offsite/offsite.log`.
- Canonical source: this `box-scripts/` dir; installed by `box-scripts/install.sh`.

## Tunables (env overrides)

`HOST_COLD_DIR`, `OFFSITE_TRANSPORT`, `OFFSITE_SSH_TARGET`, `OFFSITE_SSH_KEY`,
`OFFSITE_LOCAL_DIR`, `OFFSITE_RCLONE_REMOTE`, `OFFSITE_S3_URI`,
`OFFSITE_S3_ENDPOINT`, `STATE_DIR`, `SYNCED_DIR`, `LOG_DIR`, `NOTIFY_CMD`,
`ALERT_PREFIX`.

## Install / test

- Install (idempotent): `sudo box-scripts/install.sh`.
- Dry, non-alarming smoke run to a throwaway local dir (no offsite needed):
  `ALERT_PREFIX="[TEST-ignore] " STATE_DIR=/tmp/co LOG_DIR=/tmp/co \
   OFFSITE_LOCAL_DIR=/tmp/co/offsite /usr/local/sbin/szl-receipts-cold-offsite`
  then inspect `/tmp/co/status.json`, `/tmp/co/offsite/`, and `/tmp/co/offsite.log`.

## Scope

This is the **scheduled offsite mirror + alert** only. It consumes the cold
archive that `szl-receipts-retention` produces on the box and replicates it
elsewhere, sha256-verifiable against the existing bucket manifests, append-only,
and survives a clean box rebuild via `install.sh`.
