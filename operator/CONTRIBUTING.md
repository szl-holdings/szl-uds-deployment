# Contributing to szl-fleet-overlay

Thank you for your interest in contributing. This document covers the process and
requirements for submitting changes.

---

## Developer Certificate of Origin (DCO)

**DCO is required on every commit.** By signing off, you certify that you authored the
change and have the right to contribute it under the Apache-2.0 license.

Add the following trailers to every commit message:

```
Signed-off-by: Your Name <your.email@example.com>
```

Example commit:

```
feat: add namespace-level NetworkPolicy for szl-amaru

Adds explicit egress NetworkPolicy allowing szl-amaru to reach
the peat-mesh QUIC endpoint on port 4001.

Signed-off-by: Your Name <your.email@example.com>
```

Commits missing the `Signed-off-by` trailer will be blocked by the DCO check CI workflow
(`.github/workflows/dco.yml`).

To sign off automatically with `git commit`:

```bash
git commit -s -m "your message"
```

---

## Doctrine Constraints (MUST follow)

Before submitting any change, verify:

- Doctrine v11 LOCKED 749/14/163 — kernel commit `c7c0ba17` — **never** change these values
- Λ = Conjecture 1 — **never** elevate to theorem in any doc or comment
- SLSA L1 honest — **never** claim L2 or L3
- Section 889 = exactly 5 vendors — do not add or remove from the prohibited vendor list
- No Iron Bank, FedRAMP, CMMC, SWFT, or Mission Owner references anywhere

Violations of these constraints will block merge regardless of other review status.

---

## Pull Request Process

1. Fork the repo and create a feature branch.
2. Make changes with DCO-signed commits.
3. Open a PR against `main`.
4. The DCO bot and CI (yamllint + helm lint + zarf dev lint) must pass.
5. One maintainer review required for merge.

---

## Code Style

- YAML: 2-space indentation, no trailing whitespace, newline at EOF.
- Helm templates: follow the existing `_helpers.tpl` pattern — all Package CRs rendered
  via the `szl-fleet.package` named template.
- Do not duplicate Package CR content between `configs/packages/` and `chart/templates/`.
  The Helm templates call the shared helper; they do not copy-paste the CR spec.

---

## Maintainers

- SZL Holdings Engineering — eng@szlholdings.ai
