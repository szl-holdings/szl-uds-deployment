# Honest role mapping — internal codenames → user-facing names

**SPDX-License-Identifier: Apache-2.0 · Copyright 2026 SZL Holdings**

The internal codenames below appear in this repo only as **signed-artifact-coupled
identifiers** — Helm chart names, Kubernetes resource/namespace names, UDS Package CR
names, Zarf component names, and OTEL span namespaces — each wired to a **published,
cosign-signed** OCI image (`ghcr.io/szl-holdings/{amaru,rosie,sentra}:uds-v0.2.0`, every
one carrying a `.sig` signature and `.att` SLSA attestation in GHCR, with digests locked
into `zarf.yaml` / `uds-bundle.yaml` / `ClusterImagePolicy`). Renaming them in place would
desync the deployed identity from its signature/attestation — a provenance break worse
than the codename. They are therefore retained for verification integrity and are **not
user-facing product names**.

| Internal codename (signed-coupled) | User-facing role     | Function                                                        |
|------------------------------------|----------------------|-----------------------------------------------------------------|
| `amaru`                            | **Provenance Anchor**| Convergent data-sync; KL-drift-bounded replication + hash-chained proof receipts. |
| `rosie`                            | **Operator**         | Operator / replay control surface for governed actions.         |
| `sentra`                           | **Policy**           | Policy / receipt-gate enforcement.                              |

Quechua organ names (YUYAY / YAWAR / YACHAY / MUSQUY / AMARU-shell) are **not** banned.

**Migration:** the codenames are removed by cutting a new versioned release
(`uds-v0.3.0`) under honest directory/resource names, building + `cosign sign` +
`cosign attest` the new images, re-signing the new Zarf packages, and deprecating the
immutable v0.2.0 set (kept published so existing receipts/attestations stay verifiable).
Until that signing-capable release, **user-visible** surfaces (docs, site, dashboards)
use the honest roles above; only signed/coupled identifiers retain the codename.
