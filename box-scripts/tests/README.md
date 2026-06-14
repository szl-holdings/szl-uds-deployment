# box-scripts self-tests

Self-verifying checks for the box `167.233.50.75` host helpers installed by
`box-scripts/install.sh`. Every assertion exits non-zero on failure, and **no
test ever reaches the real alert channel** — `NOTIFY_CMD` is pinned to a local
capture stub for every run.

Run everything:

```bash
box-scripts/tests/run-all.sh                 # CI-safe portion only (off-box)
sudo CONFIRM=1 box-scripts/tests/run-all.sh  # full proof, on the box
```

## `watcher-edges.sh` — CI-safe, no root/cluster/network

Drives all nine watchers' healthy→ALERT edge through a capture-stub `NOTIFY_CMD`
and asserts each one (a) fires exactly once on the OK→ALERT transition and
(b) de-dupes while the problem persists:

| watcher | how the edge is forced |
| --- | --- |
| `a11oy-uptime-check` | `HOSTS=nonexistent.invalid` → DOWN |
| `dns-drift-check` | `EXPECT_IP=10.255.255.254` → DRIFT |
| `box-scripts-drift-check` | inline fixture repo whose live copy differs from the committed one |
| `szl-ns-scratch-watch` | stub audit tool reports an untracked namespace |
| `szl-ns-scratch-stale-watch` | stub audit tool reports a past-TTL namespace |
| `receipt-chain-watch` | `kubectl` stub: pepr present, receipts sink missing |
| `a11oy-contracting-tool-watch` | stub `docker` yields an empty baked module |
| `eval-arena-trend-watch` | stub validator reports the newest run DEGRADED |
| `szl-box-sync-conflict-watch` | inline git repo left with a UU path + a retained `szl-box-sync autostash` stash |

Cluster-bound watchers get past their cluster-up gate via PATH stubs for `k3d`
and `kubectl`; the drift fixture (a tiny `.git` repo) is built inline. The
script tests the committed copies in `box-scripts/sbin`, so it verifies the
source of truth. Exit `0` = all 18 assertions passed, non-zero = any miss.

## `restore-fleet.sh` — destructive, needs root + systemd (run on the box)

Proves `install.sh` is a complete, idempotent, self-restoring installer. The
managed set, modes, enable targets, and env files are **derived from
`install.sh` at runtime** (never hardcoded), so the test stays correct as
`box-scripts/` grows.

- **Phase 1** — back up + wipe every managed sbin script and systemd unit,
  re-run `install.sh`, assert each file returns with its declared mode
  (sbin `0755`, units `0644`) and every `enable --now` target is both
  `is-enabled=enabled` and `is-active=active`.
- **Phase 2** — re-run `install.sh` and assert the private env files
  (`a11oy-uptime`, `szl-alert-relay`, `vault-keystore-offbox`) are not clobbered
  (md5 unchanged) — an existing channel survives.
- **Phase 3** — move each env file aside, re-run, assert the stub is re-seeded
  **only when absent** (mode `600` + the expected template), then restore the
  real file.
- **Phase 4** — assert every env file is byte-identical to how the test found it.

Everything is backed up first; an EXIT trap re-instates any managed file left
missing and the original env files, so an abort never leaves the fleet broken.

Gated behind `CONFIRM=1` (or `--yes`). Exit `0` = pass, `1` = a failed
assertion, `77` = skipped (not root / no systemd / not confirmed). Use
`STRICT=1` to turn a skipped precondition into a failure.
