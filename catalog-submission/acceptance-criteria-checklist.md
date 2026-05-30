# UDS Catalog Acceptance Criteria Checklist

**Status: [STAGED] NOT YET SUBMITTED**
**Last updated:** 2026-05-29
**Doctrine:** v6 (strict) — explicit checklist against public UDS docs, no fake claims

---

## Legend

- ✓ DONE — item is complete with verifiable evidence
- ◑ PARTIAL — item exists but incomplete
- ✗ MISSING — item does not exist
- [STAGED] — item is planned, awaiting prerequisite action

---

## Section A: Package Structure

Source: https://github.com/defenseunicorns/uds-common/blob/main/docs/uds-packages/guide.md

| # | Criterion | Status | Evidence / Notes |
|---|-----------|--------|-----------------|
| A1 | `zarf.yaml` exists in repo | ◑ PARTIAL | Exists in vessels (#50) and szl-uds-deployment; missing for a11oy, sentra, amaru, rosie |
| A2 | `uds-bundle.yaml` exists | ✓ DONE | `bundles/szl-full-stack/uds-bundle.yaml` (this PR); vessels has its own |
| A3 | `tasks.yaml` with `deploy`, `update`, `remove` tasks | ✓ DONE | `tasks.yaml` added in szl-uds-deployment#4 |
| A4 | UDS `Package` CR (`kind: Package`, `apiVersion: uds.dev/v1alpha1`) | ◑ PARTIAL | CR added in PR#4 for szl-receipts; not yet for a11oy/sentra/amaru/rosie |
| A5 | Package CR has `network.allow` blocks (ingress/egress) | ◑ PARTIAL | szl-receipts CR has network block; others not yet |
| A6 | Package CR has `monitor` block (ServiceMonitor) | ◑ PARTIAL | Added in PR#4 for szl-receipts only |
| A7 | Package CR has `sso` block (if applicable) | ✗ MISSING | SSO not configured for any component |
| A8 | Container images in public registry (GHCR) | ✗ MISSING | **[STAGED: FA-001 blocker]** No images pushed to `ghcr.io/szl-holdings/` |
| A9 | All images pullable at release time | ✗ MISSING | **[STAGED: FA-001 blocker]** Blocked on A8 |

---

## Section B: Security and Supply Chain

| # | Criterion | Status | Evidence / Notes |
|---|-----------|--------|-----------------|
| B1 | SBOM attached to release | ✓ DONE | `sbom.yml` CI workflow generates SBOM for all 6 repos |
| B2 | Cosign-signed release artifacts | ✗ MISSING | **[STAGED: FA-001 blocker]** No `.sig` files on any release; agent proxy cannot upload binaries |
| B3 | `sha256` checksums for all release assets | ◑ PARTIAL | sha256 documented in release body + HF mirror; not attached as `.sha256` file |
| B4 | Public key (`.pub`) attached to release | ✗ MISSING | **[STAGED: FA-001 blocker]** Pub key in release body as text; not as attached file |
| B5 | SLSA Build L3 provenance attestation | ✗ MISSING | **[STAGED]** `slsa.yml` workflow exists; attestation not yet generated |
| B6 | in-toto provenance | ✗ MISSING | **[STAGED]** Planned for v0.3.1 |
| B7 | Pod Security Standards enforce: restricted | ✓ DONE | PSS labels added in PR#4; namespace labels in Helm chart |
| B8 | NetworkPolicy for ingress/egress | ✓ DONE | Added in PR#4 and Helm chart |
| B9 | No privileged containers | ✓ DONE | PSS restricted enforced |

---

## Section C: Documentation

| # | Criterion | Status | Evidence / Notes |
|---|-----------|--------|-----------------|
| C1 | Operator quickstart | ✓ DONE | `docs/OPERATOR_QUICKSTART.md` (this PR) |
| C2 | Deployment prerequisites documented | ✓ DONE | OPERATOR_QUICKSTART.md §Prerequisites |
| C3 | Troubleshooting guide | ✓ DONE | OPERATOR_QUICKSTART.md §Troubleshooting (Top 10) |
| C4 | Air-gap deployment instructions | ✓ DONE | OPERATOR_QUICKSTART.md §Air-Gap Option |
| C5 | Configuration reference | ✓ DONE | Helm README.md §Configuration Reference |
| C6 | What the package is NOT (doctrine) | ✓ DONE | All release notes + README files have "What this is NOT" section |
| C7 | Gap map documenting catalog readiness | ✓ DONE | a11oy#94: `docs/UDS_FRONTIER_GAP_MAP.md` |

---

## Section D: CI / Testing

| # | Criterion | Status | Evidence / Notes |
|---|-----------|--------|-----------------|
| D1 | CI green on main (all repos) | ✓ DONE | GitHub Actions green for all 6 repos |
| D2 | Automated package deployment test | ◑ PARTIAL | `scripts/validate-operational.sh` in PR#4; not yet a full Ginkgo/Chainsaw test |
| D3 | Package-level integration test | ✗ MISSING | **[STAGED]** Full automated test suite pending engineering work |
| D4 | Tests run in CI on PR | ✓ DONE | `tests.yml` CI workflow |
| D5 | uds-mesh: 335 substrate tests passing | ✓ DONE | 70 pytest + 265 substrate per uds-mesh README |

---

## Section E: Catalog Process

| # | Criterion | Status | Evidence / Notes |
|---|-----------|--------|-----------------|
| E1 | DU catalog maintainer sponsor identified | ✗ MISSING | **[STAGED]** Andrew Greene endorsed Option-A (not catalog sponsor) |
| E2 | Catalog submission PR/issue opened | ✗ MISSING | **[STAGED]** Do NOT open until E1 + A8 + B2 resolved |
| E3 | Package listing in DU catalog registry | ✗ MISSING | Not submitted |
| E4 | DU catalog review completed | ✗ MISSING | Not applicable yet |
| E5 | Trademark/naming non-objection | ✗ MISSING | **[STAGED]** Counsel review post-Warhacker |

---

## Summary Scorecard

| Section | Done | Partial | Missing/Staged |
|---------|------|---------|----------------|
| A: Package Structure | 3 | 3 | 3 |
| B: Security / Supply Chain | 3 | 2 | 4 |
| C: Documentation | 7 | 0 | 0 |
| D: CI / Testing | 3 | 1 | 1 |
| E: Catalog Process | 0 | 0 | 5 |
| **TOTAL** | **16** | **6** | **13** |

**Catalog readiness: 16/35 criteria fully met. Submission not appropriate.**

---

## Critical Path to Submission

The following 5 items are hard blockers. Nothing else matters until these are done:

1. **[FA-001]** Founder pushes containers to GHCR for vessels, a11oy, sentra, amaru, rosie
2. **[FA-001]** Founder runs `cosign sign-blob` on all 5 tarballs and uploads 4-asset pattern to GitHub releases
3. **[Engineering]** `zarf package create` for all 5 components (requires containers in GHCR)
4. **[Engineering]** UDS Package CRs for all 5 components (requires in-cluster services)
5. **[Relationship]** Andrew Greene conversation about formal catalog sponsorship (post-Warhacker)

---

*Generated: 2026-05-29 | catalog-submission/acceptance-criteria-checklist.md | Doctrine v6 strict*
*STAGED: not submitted, awaiting (a) Andrew Greene sponsor approval, (b) container push, (c) cosign keys*
