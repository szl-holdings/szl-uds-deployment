# Security Policy

## Trust Tier

**Trust Tier 1** — SZL Holdings is committed to coordinated, responsible disclosure for all SZL Holdings repositories.

## Reporting a Vulnerability

Please report security vulnerabilities to: **security@szlholdings.com**

**Alternate channel:** [Open a private security advisory](https://github.com/szl-holdings/.github/security/advisories/new) on GitHub.

Please include:

- A clear description of the issue and its potential impact.
- Steps to reproduce, including any proof-of-concept code, requests, or payloads.
- The affected version, commit SHA, or environment.
- Your name and contact details for follow-up and credit (optional).

## Disclosure Process

We commit to:
- Acknowledging your report within **72 hours**
- Providing an initial assessment within **7 days**
- Disclosing the resolution within **90 days** of report (industry-standard coordinated-disclosure window)

We ask that you give us a reasonable opportunity to investigate and patch before public disclosure. We do not pursue legal action against good-faith security research.

## Supported Versions

| Version | Supported |
|---------|-----------|
| Current main | ✅ |
| Tagged releases (last 90 days) | ✅ |
| Older tagged releases | Best effort |

## Scope

This policy covers all software published under `szl-holdings/*`. For the upstream Defense Unicorns ecosystem we contribute to (Iron Bank, UDS, Pepr, Zarf), please follow their respective security policies.

In scope:

- Source code, container images, and infrastructure-as-code in this repository.
- Authentication, authorization, data handling, and cryptographic implementations.
- Supply-chain risks affecting build artifacts produced from this repository.

Out of scope:

- Third-party dependencies (please report upstream).
- Social engineering, physical attacks, or denial-of-service against shared infrastructure.
- Findings that require physical access to a user's device.

## Governance

Vulnerability disclosures are governed by SZL Doctrine v7:

- No fake security claims; positive status must be verifiable.
- `STAGED-ADVISORY` label for gates not yet machine-checked.
- DSSE receipts on every governance decision.

Source: https://github.com/szl-holdings/.github

## Hall of Thanks

Researchers who responsibly disclose vulnerabilities will be acknowledged here.
