<!--
Copyright 2026 SZL Holdings
SPDX-License-Identifier: Apache-2.0
-->
# bundle-digest-watch — stale bundle-digest alarm

Alarm for box `167.233.50.75` (`/opt/szl/szl-uds-deployment`) that catches a
**locally-built airgap deploy tarball baking a stale szl-receipts image digest** —
the gap left when `scripts/pin-receipts-image-digest.sh` repins the source digest
(and the package is re-signed) but the on-disk tarballs are not re-cut.

## Why

A same-tag image rebuild re-mints a new digest. The repin loop updates the
**source** pins; it does not touch the already-cut tarballs:

- `uds-bundle-szl-receipts-bundle-<arch>-<ver>.tar.zst`
- `packages/szl-receipts/zarf-package-szl-receipts-<arch>-<ver>.tar.zst`

Until they are re-cut they still carry the **old** digest, and an airgap deploy
ships the old image with no visible symptom.

## What it does

Each cycle:

1. Extracts the source-pinned digest via
   `grep -oE 'szl-receipts-server:...@sha256:<64hex>'` from
   `packages/szl-receipts/zarf.yaml`.
2. Lists every built tarball (`zstd -dc <tb> | tar -t`) and checks the pinned
   digest appears in the listing (zarf stores the image manifest blob as
   `blobs/sha256/<digest>`; `uds create` flattens it into the bundle too —
   verified both surfaces carry the hex).
3. ALERTs (push, edge-triggered) for any existing tarball that is missing the
   pinned digest, printing the re-cut command. RECOVERED once they all carry it.

No-op (exit 0, UNKNOWN) when the source pin is unreadable or no tarball has been
built yet — nothing to compare means nothing stale.

## Fix when it fires (re-cut)

```
cd /opt/szl/szl-uds-deployment && uds run bundle
```

Then re-run `/usr/local/sbin/bundle-digest-watch` to confirm RECOVERED.

## Env tunables

`REPO`, `SRC_ZARF`, `IMAGE_RE`, `TARBALL_GLOBS`, `STATE_DIR`, `LOG_DIR`,
`NOTIFY_CMD`, `ALERT_PREFIX` — all overridable; defaults watch the szl-receipts
bundle + package tarballs and push through `/usr/local/sbin/a11oy-uptime-notify`.

## State / logs

- `/var/lib/bundle-digest-watch/status.json` — last result.
- `/var/lib/bundle-digest-watch/last_status` — edge-trigger memory.
- `/var/log/bundle-digest-watch/bundle-digest-watch.log` — per-run log.

## Install / guard

Wired into `box-scripts/install.sh` (script + units copied, timer enabled, run
once). Kept honest by the CI guard trio
`scripts/bundle-digest-watch-guard-checks.sh` (+ `.test.sh`) and
`.github/workflows/bundle-digest-watch-guard.yml`.
