<!-- Copyright 2026 SZL Holdings / SPDX-License-Identifier: Apache-2.0 -->

# Receipt Store Sharding + Retention Runbook — szl-receipts

**Scope:** keeping the `szl-receipts-server` on-disk receipt store from growing
without bound, while preserving end-to-end chain verifiability. Covers the
index-sharded store layout, the bounded full-store integrity audit, and the
cold-storage archival of sealed shards.

**Why this exists.** Every governance receipt is persisted as one JSON file under
`SZL_RECEIPT_STORE` (default `/data/receipts`). The original build wrote every
receipt as a flat file in that single directory. Past ~200k receipts a single
directory becomes expensive to list, and any "verify the whole store" pass had to
walk all of it at once. This runbook documents the sharding + archival policy that
caps per-directory size, keeps integrity scans bounded in memory, and lets old
receipts roll off to cold storage without breaking the hash chain.

> **Memory sizing is a separate, already-solved concern.** The server already
> boots in O(1) from a `.chain_head` pointer and keeps only the last
> `SZL_MAX_IN_MEMORY_RECEIPTS` (default 2000) receipts in RAM — see
> [the memory-sizing note in the server header]. This runbook is about the *disk*
> store, not RAM.

| Property | flat store (before) | sharded + archival (now) |
|---|---|---|
| Layout | every `.json` in one dir | new receipts under `shards/<bucket>/`, ≤ `SHARD_SIZE` per dir |
| Per-dir file count | unbounded (200k+) | bounded by `SHARD_SIZE` (default 10000) |
| Full-store verify | walked the whole store at once | bounded shard-by-shard, memory ∝ one bucket |
| /metrics chain length | risked re-walking the store | O(1) from in-memory `_persisted_count` |
| Old receipts | grow forever on the live PVC | sealed buckets roll off to cold storage (verify-gated) |

Source: [`services/szl-receipts-server/server.py`](../../services/szl-receipts-server/server.py).

---

## 1. Store layout

```
$SZL_RECEIPT_STORE/                 # default /data/receipts
├── .chain_head                     # O(1) head pointer {chain_index, hash, count}
├── <legacy>.json                   # pre-sharding flat files (still read + verified)
├── shards/
│   ├── 00000000/                   # chain_index 0 .. SHARD_SIZE-1
│   │   └── <receipt_id>.json
│   ├── 00000001/                   # chain_index SHARD_SIZE .. 2*SHARD_SIZE-1
│   │   └── ...
│   └── 000000NN/                   # the TAIL bucket (currently being written)
└── cold/                           # optional cold-storage target (configurable)
    ├── 00000000.tar.gz
    ├── 00000000.manifest.json
    └── archived.json               # append-only archival ledger
```

- A receipt for `chain_index` is written to
  `shards/<chain_index // SHARD_SIZE, zero-padded to 8>/<receipt_id>.json`.
- Buckets sort lexically in chain order (8-digit zero-pad), so "the tail bucket"
  is simply the highest-named bucket.
- Legacy flat files in the store root are still read and verified — sharding is
  **additive and backward compatible**. No migration of existing files is
  required; they remain a finite, frozen pre-sharding chunk.

### Configuration

| Env var | Default | Meaning |
|---|---|---|
| `SZL_RECEIPT_STORE` | `/data/receipts` | store root (PVC mount) |
| `SZL_RECEIPT_SHARD_SIZE` | `10000` | receipts per shard bucket; **`0` disables sharding** (flat/legacy writes) |
| `SZL_RECEIPT_COLD_DIR` | `<store>/cold` | default cold-storage target for `archive-shards` |
| `SZL_MAX_IN_MEMORY_RECEIPTS` | `2000` | in-RAM window (orthogonal; memory sizing) |

Sharding is **default-ON**. To keep the legacy flat behaviour (e.g. a tiny demo
store), set `SZL_RECEIPT_SHARD_SIZE=0`.

---

## 2. Bounded full-store integrity audit

The `/metrics` hot path reports chain length from the in-memory `_persisted_count`
(head-pointer count + appends), so a Prometheus scrape never re-walks the store.

For an on-demand **full** at-rest audit, run the operator CLI inside the pod (or
on any copy of the store):

```bash
# in the szl-receipts-server pod (or anywhere with the store + the public key)
python3 server.py verify-store
```

It verifies the ENTIRE store — legacy flat root + every shard bucket — but does so
**one group at a time**, carrying only the running `prev_hash` link across group
boundaries. Memory never scales with total chain length, only with a single
bucket (≤ `SHARD_SIZE`). For each receipt it checks:

- the Ed25519 DSSE signature against the published public key (`GET /pubkey`),
- the stored `chain.hash` recomputed from the receipt body,
- the `prev_hash` linkage in `chain_index` order.

Output (JSON) reports `groups`, `total`, `valid`, `chain_ok`, and per-class
counters `bad_sig` / `bad_hash` / `bad_link` plus a `tampered_sample`. Exit code
is `0` when `chain_ok` is true, `1` on any tamper — wire it into CI or a cron probe.

> The CLI builds the signer the same way the server does, so it needs the same
> signing-key material available (`backend=file`: the Ed25519 PEM at
> `SZL_ED25519_KEY_PATH`; `backend=vault`: Vault reachable). It only uses the
> **public** key to verify.

---

## 3. Archiving sealed shards to cold storage

A bucket is **sealed** once it is strictly below the tail bucket — no further
receipts will ever land in it. Sealed buckets can be rolled off the live PVC:

```bash
# dry rollup: tar+manifest sealed buckets into cold storage, keep live copies
python3 server.py archive-shards --cold-dir /data/receipts/cold

# rollup AND delete the live copies of successfully sealed buckets
python3 server.py archive-shards --cold-dir /data/receipts/cold --delete
```

For each sealed bucket the tool:

1. **Verifies** the bucket (same checks as `verify-store`). A bucket that fails
   verification is **SKIPPED** — never archived, never deleted — and reported
   under `skipped_failed_verify`.
2. tar.gz's it to `<cold-dir>/<bucket>.tar.gz`.
3. Writes a sidecar `<cold-dir>/<bucket>.manifest.json` recording `count`,
   `first_prev_hash`, `last_hash`, `tarball_sha256`, and `archived_at`, and
   appends the manifest to the append-only `<cold-dir>/archived.json` ledger.
4. Only with `--delete` removes the live bucket directory.

### Chain verifiability is preserved

- The **tail bucket is never archived** — only fully sealed buckets below it.
- Archival is **verify-gated**: an unverified bucket stays in place.
- The manifest's `first_prev_hash` + `last_hash` let an auditor stitch a
  cold-archived bucket back into the live chain (rehydrate the tarball, then
  `verify-store` end-to-end).
- The **head-pointer count remains the authoritative chain length** — archived
  receipts still count, so deleting their live copies does not regress the
  `/metrics` gauge or the chain index.

Cold storage can be any path: a second PVC, an object-storage gateway mount, or a
host path that a backup job ships off-box. The tool only writes files; shipping
the tarballs offsite is an operator/backup-job concern.

---

## 4. Recommended rollout + PVC sizing

1. **Ship the new image** (separate deploy task): the sharding write path,
   bounded `verify-store`, and `archive-shards` CLI all live in `server.py`. No
   chart value is required to turn sharding on (default `SHARD_SIZE=10000`).
2. **Existing flat files keep working** — they are read/verified in place. There
   is no in-place migration step; new receipts simply start landing in
   `shards/00000000/` (and roll over every `SHARD_SIZE`).
3. **Size the PVC** for the live working set you intend to keep hot. With
   periodic `archive-shards --delete`, the live store stays ≈
   `(unarchived buckets) × SHARD_SIZE × avg_receipt_bytes`. Run the archival on a
   schedule (CronJob / systemd timer) that matches your retention target, and
   keep `cold/` on a volume sized for full history (or ship it offsite).
4. **Verify after each archival**: `verify-store` over the remaining live store
   must still report `chain_ok: true`.

> **Do not** reset or bulk-delete the existing store as part of enabling
> sharding — sealing/archival is the supported way to shrink the live store, and
> a separate task owns any one-time history reset.

---

## 5. Quick reference

```bash
# bounded full-store audit (exit 0 = chain_ok)
python3 server.py verify-store

# archive sealed buckets (keep live copies)
python3 server.py archive-shards --cold-dir /data/receipts/cold

# archive sealed buckets and free the live PVC
python3 server.py archive-shards --cold-dir /data/receipts/cold --delete

# disable sharding (legacy flat writes)
export SZL_RECEIPT_SHARD_SIZE=0
```

See also: [`VAULT_PERSISTENT_RUNBOOK.md`](./VAULT_PERSISTENT_RUNBOOK.md) for key
custody, and the `server.py` module header for the full HTTP surface and DSSE
signing details.
