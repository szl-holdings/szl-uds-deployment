# Security Policy

<!-- Doctrine: v11 LOCKED 749/14/163 | SLSA L1 honest | Section 889 = 5 vendors -->

## Honest Security Posture

This document is an honest disclosure of the security posture for `szl-fleet-overlay`.
We do not overclaim compliance levels.

---

## SLSA Level

**SLSA L1** — honest attestation only.

- Doctrine-pinned receipts (`receipts/checksums.txt` + cosign detached signature) provide
  integrity attestation for all config files at build time.
- We do **not** claim SLSA L2 or L3. No hermetic build environment, no SLSA provenance
  predicate, no Sigstore Fulcio certificate chain.
- Cosign signing key is operator-managed (not keyless).

---

## Doctrine Pin

```
Doctrine:     v11 LOCKED
Pin:          749/14/163
Kernel commit: c7c0ba17
Λ:            Conjecture 1 (NEVER theorem)
```

These values are locked in `receipts/doctrine-pin.yaml` and in every `Package` CR annotation.
**Never change these values without board sign-off.**

---

## Section 889 — Covered Telecommunications Equipment

This package explicitly excludes supply chain components from the following
Section 889-prohibited vendors (exactly 5):

1. Huawei Technologies Co.
2. ZTE Corporation
3. Hytera Communications Corporation
4. Hangzhou Hikvision Digital Technology Co. (Hikvision)
5. Dahua Technology Co. (Dahua)

No container images, SDKs, or libraries from these vendors are used in this chart or any
referenced workload.

---

## Excluded Frameworks

The following frameworks are **not** used or claimed in this package:

- Iron Bank / Platform One — not used
- FedRAMP — not claimed
- CMMC — not claimed
- SWFT — not used
- Mission Owner authorization — not present
- DoD identity / CAC — not required

---

## Known Gaps

- No DoD identity integration (CAC/PIV) in this overlay.
- No FIPS-validated crypto at the overlay level; depends on UDS Core for FIPS compliance
  if required by the deployment environment.
- Receipt cosign key management is operator responsibility. The public key (`cosign.pub`)
  must be pre-distributed to verifiers out-of-band.
- `checksums.txt.sig` is a placeholder stub at initial publish; operators must regenerate
  with their own cosign key before production deployment.

---

## Reporting Vulnerabilities

To report a security vulnerability, email **security@szlholdings.ai** with subject
`[szl-fleet-overlay] VULN REPORT`. Do not open a public GitHub issue for security findings.

We aim to acknowledge reports within 5 business days and resolve critical findings
within 30 days.

---

## Version Support

Only the latest tagged release of `szl-fleet-overlay` is supported for security fixes.
