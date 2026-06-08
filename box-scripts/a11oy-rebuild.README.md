# a11oy-rebuild — drift-free rebuilds of a11oy.net

`a11oy-rebuild` rebuilds the **a11oy.net** Docker image from the **published GitHub
source of truth** (`szl-holdings/a11oy`, branch `main`) and recreates the running
container. It exists to stop the live image from silently drifting away from what
is published.

## The problem it solves
The box build tree `/opt/szl/a11oy` is routinely **behind** GitHub `main` (a stale
remote-tracking ref plus hand-patched working-tree files). Historically the Docker
image was built straight from that drifting tree, so the running a11oy.net image
could diverge from the published source — a future rebuild could re-introduce
content already removed on `main`, or drop content already added there.

## What it does (idempotent)
1. `git fetch origin main`
2. Snapshots any uncommitted working-tree drift to
   `/root/a11oy-build-backups/uncommitted-<ts>.patch` (never silently lost)
3. `git reset --hard origin/main` + `git clean -fd` → a clean published checkout
4. **HF-Space overlay** — the Dockerfile `COPY`s ~19 feature files that live only
   on the published Hugging Face Space (`szlholdings/a11oy`), never back-ported to
   GitHub. The helper refreshes a cached anonymous clone of the Space
   (`/opt/szl/hf-a11oy`, LFS-skip) and copies in exactly the COPY sources missing
   from the GitHub checkout. If any source is absent from BOTH GitHub and the HF
   Space it **fails loudly** rather than shipping a degraded image.
5. `docker build -t a11oy:local .`
6. Recreates the `a11oy` container:
   `docker run -d --name a11oy --restart unless-stopped -p 127.0.0.1:7861:7860 a11oy:local`
7. **Verifies** the front-door files baked into the image match `origin/main`
   byte-for-byte (md5): `pages/console.html` → `/app/pages/console.html`,
   `console/index.html` → `/app/static/index.html`.

## Why two published sources
GitHub `main` holds the authoritative **code + front-door** (`pages/`, `console/`).
The HF Space holds ~19 **feature modules** (`szl_b2_secdata.py`, `a11oy_live_feeds.py`,
`szl_governance_gateway.py`, `static-vendor/*.min.js`, `live_snapshots/`, …) that
were pushed straight to the Space and never committed to GitHub — genuine 3-way
drift. Both are *published* (the Space is public), so building from GitHub main +
the HF Space overlay is still "always use the published source, never hand-patch."

## Usage
```bash
sudo a11oy-rebuild            # full clean rebuild + recreate + verify
sudo a11oy-rebuild --verify-only   # only check running image vs origin/main
```
Run it in the background for the (multi-minute) build:
```bash
nohup a11oy-rebuild > /root/a11oy-build-backups/rebuild-$(date +%Y%m%d-%H%M%S).log 2>&1 &
```

## Notes / traps
- **Do NOT** hand-patch `/opt/szl/a11oy` and `docker build` directly — that is the
  drift this wrapper removes. Land app changes in `szl-holdings/a11oy` `main`
  first, then run `a11oy-rebuild`.
- A non-fatal `llama-cpp-python` wheel **ERROR** during the build is expected (the
  optional local-LLM tier). The build still succeeds — only a non-zero build exit
  code is a real failure.
- As of 2026-06-08 a fresh clone of `main` is a **complete** build source: every
  Dockerfile `COPY` source exists in `main` (no Hugging Face overlay needed). The
  older "GitHub main is incomplete, overlay HF-only files" note is obsolete.
- The console SPA assets (`console/assets/**`) are real committed content, **not**
  Git-LFS, so `git reset --hard` materializes them correctly with no LFS smudge.

## Durable home
This script + README are versioned in `szl-holdings/szl-uds-deployment` under
`box-scripts/` and installed on the box at `/usr/local/sbin/a11oy-rebuild`.
