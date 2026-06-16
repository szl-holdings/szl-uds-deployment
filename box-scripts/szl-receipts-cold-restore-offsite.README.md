# szl-receipts-cold-restore-offsite — one-command off-box restore

An **on-demand** recovery tool on box `167.233.50.75` that restores the
`szl-receipts` store **from the offsite cold archive** after box loss — reading
the **same** `OFFSITE_*` configuration that
[`szl-receipts-cold-offsite`](szl-receipts-cold-offsite.README.md) mirrors **to**.

It closes the recovery half of the receipt-retention chain. Today:

- `szl-receipts-retention` keeps the live PVC bounded by sealing each shard
  bucket (`<bucket>.tar.gz` + `<bucket>.manifest.json` carrying `tarball_sha256`)
  into a cold dir.
- `szl-receipts-cold-offsite` mirrors that cold archive **off the box** (ssh /
  local mount / rclone / s3) so the sealed history survives box loss.
- `server.py restore-shards` can read **straight from that off-box copy** with
  the matching `--remote-local|--remote-ssh|--remote-rclone|--remote-s3` flags,
  staging each object and running the **unchanged** per-tarball gate
  (`tarball_sha256` + chain linkage) before unpacking — an off-box restore is
  verified exactly like a local one.

This wrapper turns the multi-step manual recovery (find the config, translate it
into flags, find a Ready pod, exec the CLI in it) into **one command**.

## What it does

1. Loads the offsite destination from `/etc/szl-receipts-cold-offsite.env` (the
   `EnvironmentFile` the mirror uses; override with `OFFSITE_ENV_FILE`).
2. Resolves the transport exactly like the mirror's `detect_transport`
   (`OFFSITE_TRANSPORT` override, else the single `OFFSITE_*` var that is set) and
   translates it into the matching verified `restore-shards --remote-*` flags.
3. Finds a **Ready** `receipts-server` pod in ns `szl-receipts` — the restore
   writes into the live store on the pod PVC, so it runs **in-pod** (like
   retention).
4. **Dry-run by default:** prints the resolved transport, the off-box source, the
   exact in-pod command, and the reachability prerequisite, then exits `0`
   **without touching the store**. Pass `--run` to execute the verified restore.

## Usage

```sh
# Dry-run: show exactly what would be restored, from where, with which command.
szl-receipts-cold-restore-offsite

# Actually restore every sealed bucket present off-box (verified per bucket).
szl-receipts-cold-restore-offsite --run

# Restore only specific buckets (repeatable).
szl-receipts-cold-restore-offsite --run --bucket 00000007 --bucket 00000008

# Non-default cluster.
szl-receipts-cold-restore-offsite --cluster some-cluster --run
```

## Reachability — the one prerequisite

The restore runs **inside the receipts pod**, so the off-box source must be
reachable **from that pod**, not just from the box:

| transport | what the pod needs |
|-----------|--------------------|
| `local`   | `OFFSITE_LOCAL_DIR` **mounted into** the pod at that same path |
| `ssh`     | the ssh key (`OFFSITE_SSH_KEY`) + network to the host |
| `rclone`  | the `rclone` binary + remote config |
| `s3`      | the `aws` cli + credentials |

`server.py` records each per-bucket fetch failure under `failed` (never a silent
skip), so an unreachable source surfaces as a **refused** restore, not data loss.

## Safety

- **Dry-run by default** — an irreversible recovery action is opt-in (`--run`).
- **No-op exit 0** (not an error) when the cluster is down or the receipts module
  is not deployed (mirrors `szl-receipts-retention`).
- **On-demand only** — no systemd timer/service; it must never run unattended.
- Per-bucket verification is unchanged: a corrupt or mismatched off-box tarball is
  **refused**, never partially applied.

Installed at `/usr/local/sbin/szl-receipts-cold-restore-offsite`. Versioned in
repo `box-scripts/`.
