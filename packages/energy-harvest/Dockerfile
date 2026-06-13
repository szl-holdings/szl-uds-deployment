# Copyright 2026 SZL Holdings
# SPDX-License-Identifier: Apache-2.0
#
# Dockerfile — szl-energy-harvest
# =============================================================================
# Builds the wasted-energy harvest grid-signal service as a small, non-root,
# read-only-rootfs container. Byte-identical application source to the LIVE box
# service (/opt/szl/energy-harvest) and the GitHub-aligned platform copy
# (szl-holdings/platform apps/energy-harvest/). The service serves BOTH the
# self-contained tab (GET /) and the honest JSON API + /metrics.
#
# Doctrine v11: REAL public grid data under the honest "grid" source; joules stay
# SAMPLE; this signal NEVER sets sovereign:true; not one of the locked-8.
#
# Build (single-arch, provenance off so a @sha256 digest pin is create-safe):
#   docker buildx build --provenance=false -t \
#     ghcr.io/szl-holdings/energy-harvest:uds-v0.1.0 packages/energy-harvest
#
# NOTE: the image is NOT yet published to GHCR. Until it is built, pushed and
# cosign keyless-signed, this package is build-valid but its live deploy / bundle
# membership stays gated (FA-001 style — see uds-package.yaml image-status).

FROM python:3.12-slim AS base

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PORT=8080

WORKDIR /app

# Pinned to the exact versions verified live on the box.
RUN pip install --no-cache-dir "fastapi==0.136.3" "uvicorn==0.49.0"

# Application source (byte-identical to platform apps/energy-harvest/).
COPY app/engine.py app/server.py app/index.html /app/

# Non-root, unprivileged.
USER 65532:65532

EXPOSE 8080

# /healthz is the liveness/readiness target; /metrics is the Prometheus scrape.
ENTRYPOINT ["uvicorn", "server:app", "--host", "0.0.0.0", "--port", "8080"]
