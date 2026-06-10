# szl-receipts-retention — automatic receipt-store archival on a schedule

A periodic systemd job on box `167.233.50.75` that keeps the `szl-receipts`
on-disk store **self-maintaining**: it runs the bounded integrity audit and the
cold-storage shard archival on a cadence, frees the live PVC, and fires a **real
push notification** if the chain fails to verify or a bucket can't be archived.

It closes the gap left by the sharding/archival work: the server already
**supports** `archive-shards --delete` and `verify-store`, but nothing ran them
automatically, so the live store grew until an operator ran the command by hand
(see `docs/operations/RECEIPT_STORE_RETENTION_RUNBOOK.md`). This guard wires that
manual procedure to a timer.

## What it does (only when the cluster is up)
The k3d nodes are `--restart no`, so on a box where the cluster is intentionally
down the run is a **no-op exit 0, not an alert** (mirrors `receipt-chain-watch` /
`szl-signing-health-check`). When the cluster is up it:

1. Finds a Ready `receipts-server` pod in ns `szl-receipts`.
2. `kubectl exec`s `python3 /app/server.py verify-store` — the bounded
   (memory ∝ one shard bucket) full-store audit. `chain_ok=false` ⇒ **ALERT**.
3. `kubectl exec`s `python3 /app/server.py archive-shards --cold-dir
   /data/receipts/cold --delete` — tar.gz + manifest each **sealed** shard bucket
   into the pod's cold dir, then deletes the live copies (the unbounded-growth
   source). The tool is per-bucket **verify-gated**: a bucket that fails
   verification is SKIPPED, never archived/deleted. Any skip / error ⇒ **ALERT**.
4. **Offloads** each freshly-archived cold tarball + manifest **off the live PVC**
   onto the box host disk `HOST_COLD_DIR` (default `/var/lib/szl-receipts-cold` —
   the "volume sized for full history"), binary-safe via `kubectl exec -- cat`
   (the slim image has no `tar`, which `kubectl cp` needs). Each offload is
   sha256-verified against the bucket manifest before the in-pod copy is pruned,
   so the live PVC is **truly bounded** while a full-history archive accumulates
   on the box. Set `PRUNE_AFTER_OFFLOAD=0` to keep both copies.

`verify-store` runs FIRST so chain health is an independent signal, but archival
ALWAYS runs afterward — it is itself per-bucket verify-gated, so one tampered
legacy bucket can never halt retention of the healthy ones (it is reported via
`skipped_failed_verify` and paged separately).

## Alerts (edge-triggered, de-duped)
One page per problem **edge** + one RECOVERED — never every cycle. Alert reasons:
- `verify-store` reports `chain_ok=false` (tamper).
- `archive-shards` returns a real `error` (benign no-ops — sharding disabled /
  empty store — are logged, not paged).
- `archive-shards` reports a non-empty `skipped_failed_verify` list.

Incomplete cold offloads (e.g. a sha256 mismatch or a failed in-pod prune) are
logged as `WARN` and **not paged** — chain integrity is unaffected and the next
run retries. Alerts go out via the shared notifier
`/usr/local/sbin/a11oy-uptime-notify` (ntfy / Telegram / Slack-Discord webhook,
channel in `/etc/a11oy-uptime.env`), wired through `NOTIFY_CMD` in the unit —
fail-soft, so it logs even before a channel is set. SMS/email is intentionally
NOT used (no Gmail/nodemailer transport; outbound TCP 465 firewalled).

## What / where
- `/usr/local/sbin/szl-receipts-retention` — the job (oneshot).
- `/etc/systemd/system/szl-receipts-retention.{service,timer}` — **daily**, first
  run 10 min after boot (`OnUnitActiveSec=1d`).
- Cold archive (full history): `/var/lib/szl-receipts-cold/` on the box.
- State: `/var/lib/szl-receipts-retention/<cluster>.{last_status,status.json,verify.json,archive.json}`.
- Log: `/var/log/szl-receipts-retention/<cluster>.log`.
- Canonical source: this `box-scripts/` dir; installed by `box-scripts/install.sh`.

## Tunables (env overrides)
`CLUSTER`, `KUBECONFIG_FILE`, `RNS`, `RX_SELECTOR`, `RX_CONTAINER`,
`POD_COLD_DIR`, `HOST_COLD_DIR`, `PRUNE_AFTER_OFFLOAD`, `SERVER_PY`,
`EXEC_TIMEOUT`, `KREQ_TIMEOUT`, `STATE_DIR`, `LOG_DIR`, `NOTIFY_CMD`,
`ALERT_PREFIX`.

## Install / test
- Install (idempotent): `sudo box-scripts/install.sh`.
- Dry, non-alarming smoke run against the live cluster (throwaway state, test
  prefix so the owner is never paged):
  `ALERT_PREFIX="[TEST-ignore] " STATE_DIR=/tmp/rr LOG_DIR=/tmp/rr \
   HOST_COLD_DIR=/tmp/rr/cold /usr/local/sbin/szl-receipts-retention`
  then inspect `/tmp/rr/uds-szl-demo.{status.json,verify.json,archive.json}` and
  `/tmp/rr/uds-szl-demo.log`. (On a store with no sealed buckets this archives
  nothing and stays OK — that is the expected steady state.)

## Scope
This is the **scheduled runner + alert** only. The archival/verification logic
lives in `server.py` (`archive-shards` / `verify-store`); this guard just runs it
on a cadence, ships cold tarballs off the live PVC, makes a broken chain loud, and
survives a clean box rebuild via `install.sh`.
