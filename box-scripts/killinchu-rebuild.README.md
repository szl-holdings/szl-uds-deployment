# killinchu-rebuild — drift-free rebuilds of killinchu.a-11-oy.com

`killinchu-rebuild` rebuilds the **killinchu.a-11-oy.com** Docker image from the
**published GitHub source of truth** (`szl-holdings/killinchu`, branch `main`) and
recreates the running container. It is the killinchu twin of `a11oy-rebuild` and
exists to stop the live image from silently drifting away from what is published.

## The problem it solves
The box build tree `/opt/szl/killinchu` is routinely **behind** GitHub `main` (a
stale remote-tracking ref plus hand-patched working-tree files — it was **23
commits behind** during task #430). Historically rebuilds were done by hand
(`git ... && docker build -t killinchu:local .`) straight from that drifting tree,
so the running killinchu image could be built from stale/degraded source. This
wrapper guarantees every rebuild starts from a clean checkout of origin/main, so
the running container always reflects what is published.

## What it does (idempotent)
1. `git fetch origin main`
2. Snapshots any uncommitted working-tree drift to
   `/root/killinchu-build-backups/uncommitted-<ts>.patch` (never silently lost)
3. `git reset --hard origin/main` + `git clean -fd` → a clean published checkout
4. **HF-Space overlay** (safety net) — copies in any Dockerfile `COPY` source
   missing from the GitHub checkout from a cached anonymous clone of the published
   Hugging Face Space (`szlholdings/killinchu`, LFS-skip). As of 2026-06-08 GitHub
   `main` is a **complete** build source (every COPY exists in main), so this is a
   logged no-op; if a source were ever absent from BOTH it **fails loudly** rather
   than shipping a degraded image — identical behaviour to `a11oy-rebuild`.
5. `docker build -t killinchu:local .`
6. **md5-guards** the baked key feature modules against `origin/main` BEFORE
   recreating the container (refuses to deploy a drifted image):
   `szl_evidence_research.py`, `killinchu_backend.py`, `killinchu_elite_console.py`,
   `killinchu_osint.py`, `szl_readiness.py`, `killinchu_cannonico.py`, `serve.py`
   (Dockerfile `WORKDIR /app`, so repo `<p>` → image `/app/<p>`).
7. Recreates the `killinchu` container:
   `docker run -d --name killinchu --restart unless-stopped -p 127.0.0.1:7862:7860 killinchu:local`
8. **Verifies live endpoints** on the recreated container:
   `/healthz` → 200 (hard gate) and `/api/killinchu/v1/evidence/research` → 200
   (soft, informational).

## Why endpoint verify instead of a front-door file pair
`a11oy-rebuild` md5-compares a front-door HTML file pair (`pages/console.html`,
`console/index.html`). killinchu has **no** such `pages/` front-door — its surface
is `/healthz` + the `/api/killinchu/*` API and the `/elite` console — so the
verification here is module md5-guards (drift detection) plus a live endpoint probe
(it actually serves). The a11oy front-door check is a11oy-specific and would print
a spurious FAIL for killinchu.

## Usage
```bash
sudo killinchu-rebuild              # full clean rebuild + recreate + verify
sudo killinchu-rebuild --verify-only   # only check the running image + container vs origin/main
```
Run the (multi-minute) build in the background so an SSH timeout cannot cut it:
```bash
nohup killinchu-rebuild > /root/killinchu-build-backups/rebuild-$(date +%Y%m%d-%H%M%S).log 2>&1 &
```

## Notes / traps
- **Do NOT** hand-patch `/opt/szl/killinchu` and `docker build` directly — that is
  the drift this wrapper removes. Land app changes in `szl-holdings/killinchu`
  `main` first (signed GraphQL `createCommitOnBranch`), then run `killinchu-rebuild`.
- The box has **no DATABASE_URL**, so `killinchu_backend.py` runs on its intended
  **durable SQLite** fallback (`db.durable=true`, `postgres_first=true`) — that is
  not a failure; `/healthz` still returns 200.
- Overrides (env): `KILLINCHU_REPO_DIR KILLINCHU_BRANCH KILLINCHU_IMAGE
  KILLINCHU_CONTAINER KILLINCHU_PORT_BIND KILLINCHU_HEALTH_HOSTPORT
  KILLINCHU_HF_SPACE_URL KILLINCHU_HF_CACHE_DIR`.

## Durable home
This script + README are versioned in `szl-holdings/szl-uds-deployment` under
`box-scripts/` (next to `a11oy-rebuild`) and installed on the box at
`/usr/local/sbin/killinchu-rebuild`.
