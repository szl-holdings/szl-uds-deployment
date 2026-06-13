<!-- Copyright 2026 SZL Holdings · SPDX-License-Identifier: Apache-2.0 -->

# `packages/energy-harvest` — wasted-energy harvest grid signal

A small, read-only **UDS/Zarf** package for the wasted-energy harvest signal. It
reads three **public, no-key** grid feeds and reports when the grid is *wasting*
power (negative wholesale price / curtailed renewables) so already-wasted energy
can be soaked. It serves the self-contained tab (`GET /`), an honest JSON API,
`/healthz`, and a Prometheus `/metrics` scrape.

Same application source, three surfaces, byte-identical:

| Surface | Where |
| --- | --- |
| Live box service | `/opt/szl/energy-harvest` (systemd `szl-energy-harvest`, `:8082`), behind nginx `^~ /api/a11oy/v1/harvest/` + `^~ /energy/` on **a11oy.net** |
| GitHub-aligned source | `szl-holdings/platform` → `apps/energy-harvest/{engine.py,server.py,index.html}` |
| This UDS package | `app/{engine.py,server.py,index.html}` (built into the container by `./Dockerfile`) |

## Doctrine v11

- REAL public grid data under the honest **grid** source; a down feed is reported
  `unreachable` and simply does not drive the posture — never fabricated.
- **joules stay SAMPLE** until an on-box NVML meter.
- this signal **NEVER** sets `sovereign:true`.
- it is **NOT** one of the locked-8; **Λ = Conjecture 1**.
- no free-energy, no greenwashing.

## Layout

```
packages/energy-harvest/
├── Dockerfile              # python:3.12-slim, non-root, read-only rootfs, uvicorn :8080
├── app/                    # application source (byte-identical to platform apps/energy-harvest/)
│   ├── engine.py           #   3 no-key feeds + pure classifier (stdlib only)
│   ├── server.py           #   FastAPI: / , /healthz , /harvest , /posture , /fabric , /metrics
│   └── index.html          #   self-contained tab
├── manifests/
│   ├── namespace.yaml      # szl-energy-harvest ns: Istio ambient + PSA restricted
│   └── deployment.yaml     # Deployment + Service (non-root, RO-rootfs, /healthz probes)
├── uds-package.yaml        # UDS Operator Package CR: ambient mesh + egress to the 3 feeds + tenant expose + ServiceMonitor
└── zarf.yaml               # manifest-based Zarf package (image bake list gated until published)
```

## Image gating (FA-001 style)

`ghcr.io/szl-holdings/energy-harvest` is **not yet published**, so the `images:`
bake list in `zarf.yaml` is intentionally commented out (otherwise
`zarf package create` would try to pull a non-existent image). The package is
**build-valid** — manifests are internally consistent and pass the deploy-entry
consistency class — but it is deliberately **not live-deployed** (the 2-vCPU box
has no headroom). To go live:

1. build + push the image (`docker buildx build --provenance=false …`, see `Dockerfile`);
2. cosign keyless-sign it;
3. uncomment + **digest-pin** the `images:` entry in `zarf.yaml` and the same ref
   in `manifests/deployment.yaml` (linux/amd64 child digest);
4. only then add this package to a `UDSBundle` and deploy.

## External egress (the only egress, besides DNS/KubeAPI)

| Host | Feed | Key? |
| --- | --- | --- |
| `api.awattar.de` | aWATTar DE day-ahead wholesale price | none |
| `api.energy-charts.info` | energy-charts.info DE renewable share | none |
| `api.carbonintensity.org.uk` | UK National Grid carbon intensity | none |

This signal talks to **no other SZL module**.
