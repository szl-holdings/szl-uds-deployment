# bundle-digest-recut — auto re-cut stale local airgap deploy tarballs

`bundle-digest-recut` is the **healer** for the gap that
[`bundle-digest-watch`](bundle-digest-watch.README.md) only **alarms** on. It
runs on box `167.233.50.75` and, when a locally-built airgap deploy tarball is
found baking a **stale** `szl-receipts` image digest, it re-cuts the receipts
package + UDS bundle so the new source-pinned digest is baked into the
deployable artifact — then verifies the re-cut took.

## The gap it closes

`scripts/pin-receipts-image-digest.sh` repins the **source** digest
(`packages/szl-receipts/zarf.yaml`, `charts/szl-receipts/values.yaml`, …) and CI
re-cuts + re-signs the **published** OCI zarf package. But the box's **local**
airgap tarballs

- `uds-bundle-szl-receipts-bundle-<arch>-<ver>.tar.zst`
- `packages/szl-receipts/zarf-package-szl-receipts-<arch>-<ver>.tar.zst`

keep baking whatever digest was current when they were last built. A same-tag
image rebuild re-mints a **new** digest, so a stale tarball can sit on disk and a
later `uds deploy <tarball>` ships the **old** image with no visible symptom.
`bundle-digest-watch` turns that drift into a push alert but still leaves a human
to run `uds run bundle`. This healer closes the loop automatically.

It does **not** bump `metadata.version`: the receipts image tag is independent of
the bundle/package version (a repin keeps the bundle at `0.4.0`). The healer
asserts the version is unchanged across the re-cut and **fails** if it moved.

## What each cycle does

1. Extract the source-pinned digest from `packages/szl-receipts/zarf.yaml`.
2. List every built target tarball and check it carries that digest
   (`zstd -dc | tar -t | grep`).
3. **All carry it** → no-op (emits a `RECOVERED` page if it had been alerting).
4. **Any stale** → subject to the safety gates below, run the **receipts-only**
   re-cut — the exact `uds run bundle` receipts steps **minus** the a11oy
   pre-build (a11oy is *not* a member of `szl-receipts-bundle`):

   ```
   zarf package create packages/szl-receipts --flavor upstream \
     --output packages/szl-receipts --tmpdir .uds-build-tmp --confirm --no-progress
   uds create . --skip-signature-validation --confirm --no-progress --tmpdir .uds-build-tmp
   ```

5. **Verify**: each rebuilt tarball now contains the **new** pinned digest, the
   pre-recut **old** digest is gone, and `metadata.version` is unchanged.

## Safety (box safe-healer doctrine)

| Gate | Effect |
| --- | --- |
| `RECUT_MODE=report` | Detect + page the manual re-cut command; never build. |
| `BUNDLE_RECUT_ENABLED=0` | Kill switch (env); behaves like report mode. |
| `KILL_FILE` present (`/etc/bundle-digest-recut.disabled`) | Kill switch (file). |
| `MIN_FREE_GB` (default 12) | Disk pre-flight: **refuse** to build (and page) when free disk on the repo filesystem is below the threshold, so a heavy `uds create` can never fill the box. |
| `flock` (`/var/lock/bundle-digest-recut.lock`) | Never two re-cuts at once / overlap a manual build. |

Every run appends to an ndjson ledger (`/var/lib/bundle-digest-recut/recut-ledger.ndjson`),
writes `status.json`, and logs to `/var/log/bundle-digest-recut/`. Paging is
edge-triggered (`last_status`): a recurring `BLOCKED`/`DISABLED`/`FAILED` pages
once, while a successful `HEALED` always pages once (it is a real change).

`bundle-digest-recut` is a **companion to**, not a replacement for,
`bundle-digest-watch`: if the healer is disabled or blocked, the watch keeps
paging so the drift is never silent.

## Schedule / files

- `bundle-digest-recut.timer` → `OnBootSec=20min` (a few minutes after the watch),
  then `OnUnitActiveSec=6h`.
- Script: `/usr/local/sbin/bundle-digest-recut`
- Units: `/etc/systemd/system/bundle-digest-recut.{service,timer}`
- State: `/var/lib/bundle-digest-recut/`  Logs: `/var/log/bundle-digest-recut/`

## Run it by hand

```bash
# Heal now (apply mode):
/usr/local/sbin/bundle-digest-recut

# Detect only, never build:
RECUT_MODE=report /usr/local/sbin/bundle-digest-recut

# Inspect state:
cat /var/lib/bundle-digest-recut/status.json
tail /var/lib/bundle-digest-recut/recut-ledger.ndjson
```

## Guard

`scripts/bundle-digest-recut-guard-checks.sh` (self-tested by
`…-guard-checks.test.sh`, run in CI by
`.github/workflows/bundle-digest-recut-guard.yml`) asserts the healer keeps its
source-pin read, the receipts-only re-cut, the post-recut verification, the
metadata.version-unchanged invariant, the safety gates, install.sh wiring, and
this documentation — so it cannot silently rot into a no-op.
