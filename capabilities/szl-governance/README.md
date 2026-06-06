# SZL Governance — Pepr Admission Capability

[<img alt="Made for UDS" src="https://raw.githubusercontent.com/defenseunicorns/uds-common/refs/heads/main/docs/assets/made-for-uds.svg" height="20px"/>](https://github.com/defenseunicorns/uds-core)

**SPDX-License-Identifier: Apache-2.0** · Copyright 2026 SZL Holdings

Built to mesh with [UDS Core](https://github.com/defenseunicorns/uds-core). **Not affiliated with, sponsored by, or endorsed by Defense Unicorns.**

---

## What this is

A [Pepr](https://github.com/defenseunicorns/pepr) (Apache-2.0) admission module that gates application workloads in the **a11oy** and **killinchu** namespaces on the presence of a well-formed SZL **YUYAY-gate DSSE receipt** annotation. Any non-system Pod that lacks a valid receipt is **denied admission** with a structured, actionable error.

This is an **original SZL Holdings work**. It uses only the public Pepr API and interoperates with UDS Core through standard UDS Package custom resources. It does **not** vendor or copy source from any AGPL-3.0 component (uds-core, uds-cli, uds-common, maru-runner).

## Receipt format (REAL — validated here)

```
szl.io/receipt: "v1:<64-hex-sha256-of-payload>:<base64url-dsse-signature>"
```

Regex (strict): `^v1:[0-9a-f]{64}:[A-Za-z0-9\-_=]{88,}$`

- `v1` — receipt format version
- `<sha256>` — lower-case hex digest of the canonicalised governed-action payload (the YUYAY gate output)
- `<base64url sig>` — the DSSE envelope signature, base64url, ≥ 88 chars

## REAL vs ROADMAP

| Capability | Status | Notes |
| --- | --- | --- |
| Presence + strict-format validation of `szl.io/receipt` on a11oy/killinchu Pods | **REAL** | No network call. Blocks unsigned/malformed workloads at admission. |
| Mutating webhook injects `szl.io/governance-gate`, `szl.io/receipt-present`, (killinchu) `szl.io/domain=maritime-drone-c2` labels | **REAL** | For Prometheus/Grafana + Loki audit dashboards. |
| Skip UDS-Core / Zarf / Pepr system pods (`app.kubernetes.io/managed-by`) | **REAL** | Governance applies only to application workloads. |
| Full DSSE **cryptographic** verification of the signature against `szl-receipts` | **ROADMAP (P1)** | Requires an in-cluster HTTPS call from the Pepr controller. Egress allow is pre-provisioned in `chart/templates/uds-package.yaml`; the verify hook is left commented in `szl-governance-common.ts`. |
| Conjunctive Λ-gate score threshold (P1–P6 must all pass) | **ROADMAP (P2)** | Λ = Conjecture 1 (not a theorem). |
| Append a row to the per-app append-only ledger on admission | **ROADMAP (P3)** | |

## Layout

```
capabilities/szl-governance/
├── package.json                         # Pepr module config (uuid szl-governance-001)
├── pepr.ts                              # PeprModule entry — registers both gates
├── tsconfig.json
├── capabilities/
│   ├── szl-governance-common.ts         # REAL receipt validator + helpers
│   ├── a11oy-receipt-gate.ts            # a11oy namespace gate
│   └── killinchu-receipt-gate.ts       # killinchu namespace gate (+ maritime-drone-c2 label)
├── chart/                              # UDS Package CR (egress + monitor) — interop only
│   ├── Chart.yaml
│   ├── values.yaml
│   └── templates/uds-package.yaml
├── zarf.yaml                           # air-gap package (module + UDS policy)
├── LICENSE                             # Apache-2.0
└── NOTICE                              # third-party attributions (Pepr, kubernetes-fluent-client)
```

## Build & deploy

```bash
# Format / lint (no cluster required)
npm run format:check

# Build the Pepr controller image + manifests into dist/
npm run build            # -> npx pepr build

# Package for air-gap UDS deploy
uds zarf package create capabilities/szl-governance --confirm

# Deploy onto a live UDS Core cluster
uds zarf package deploy zarf-package-szl-governance-*.tar.zst --confirm
```

> **Deploy-time verification only:** the admission webhook can only be exercised
> against a live cluster (k3d/UDS Core). The receipt validator unit logic is
> testable offline, but the actual deny/approve round-trip, the UDS Package CR
> reconcile, and the ROADMAP `szl-receipts` egress require the live Hetzner/tower
> environment. Flagged here per the "no bandaids" rule.

## License discipline

| Component | License | How we use it |
| --- | --- | --- |
| Pepr | Apache-2.0 | Public API only (`Capability`, `PeprModule`, `a`, `Log`) — embeddable with NOTICE |
| kubernetes-fluent-client | Apache-2.0 | Transitive Pepr dependency |
| uds-core (UDS Operator) | AGPL-3.0 | **Interoperate only** — we emit UDS Package CRs that target its public API; no source copied |

This capability is itself **Apache-2.0**.
