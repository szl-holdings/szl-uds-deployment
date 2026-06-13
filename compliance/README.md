<!-- Copyright 2026 SZL Holdings — SPDX-License-Identifier: Apache-2.0 -->

# Compliance — OSCAL component-definitions (lula-validatable)

This directory holds machine-checkable [OSCAL](https://pages.nist.gov/OSCAL/) (NIST SP 800-53
Rev 5) component-definitions, validated with the [lula1](https://github.com/defenseunicorns-labs/lula1)
engine (Apache-2.0). Each control implementation is labelled **REAL** (a live Kubernetes
resource query + Rego evaluation) or **ROADMAP** (requires additional infrastructure).

> **Deploy-time only.** `lula validate` must run against a **live UDS Core cluster** — the
> Kubernetes resource queries return nothing offline. The OSCAL documents + Rego are validated
> here for structure/syntax; the PASS/FAIL control verdicts are earned only on the live cluster.

## Components

| File | Capability | Controls (NIST SP 800-53 Rev 5) |
|------|-----------|----------------------------------|
| `oscal-component-a11oy.yaml` | a11oy governance gate | governance / receipt controls |
| `oscal-component-killinchu.yaml` | killinchu maritime-drone-C2 substrate | SI-7, AC-7, AU-9, AU-3, SA-17 |
| `oscal-component-sda.yaml` | **killinchu SDA / Domain Awareness** (`szl-sda`, clean-room anomaly/SDA) | CM-7, AC-6, AU-10, SC-7, SI-7, SA-15 |

### `oscal-component-sda.yaml` (new, `uds-v0.4.0`)

Expresses the controls for the clean-room anomaly / Space-Domain-Awareness capability
(`szl-sda`, engine image `ghcr.io/szl-holdings/khipu-sda-core`). Three components:

1. **Hardened workload** — restricted Pod Security Admission + least-privilege securityContext
   (`runAsNonRoot`, no privilege escalation, read-only rootfs, all caps dropped). Controls CM-7, AC-6.
2. **Receipt-egress gate (Λ-gate, fail-closed)** — every detection is bound to a signed DSSE
   receipt before egress; default-deny NetworkPolicy restricts ingress to the mesh. Controls AU-10, SC-7.
3. **Image provenance gate (cosign + SLSA)** — sigstore policy-controller opt-in; SLSA L1 honest /
   L2 build-attestation present / L2-verified+L3 roadmap. Controls SI-7, SA-15.

**Honesty:** Λ = Conjecture 1 (advisory, not a theorem). No signature or image digest is
fabricated — the SDA image digest is populated only after the founder-gated Forge build signs
`uds-v0.4.0` (FA-001). Attribution: `szl-sda` is a clean-room build inspired by the publicly
described 4-function SDA framing of True Anomaly's "Mosaic"; SZL Holdings is **not affiliated**
with True Anomaly. The `alibi-detect` library is deliberately excluded (BSL 1.1).

## Run

```bash
lula validate -f compliance/oscal-component-a11oy.yaml
lula validate -f compliance/oscal-component-killinchu.yaml
lula validate -f compliance/oscal-component-sda.yaml
```

Canonical UDS ecosystem version: **`uds-v0.4.0`** (see `/VERSION`,
`scripts/check_version_doctrine.sh`). Forward-only — signed artifacts are never renamed.
