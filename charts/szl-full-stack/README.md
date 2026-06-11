# szl-full-stack Helm Chart — DEPRECATED

> **This chart is deprecated and must not be deployed.**
> It is retired in favour of the UDS bundle
> [`bundles/szl-full-stack/uds-bundle.yaml`](../../bundles/szl-full-stack/uds-bundle.yaml).

**Version:** 0.3.2 (deprecation release) — `deprecated: true` in `Chart.yaml`

---

## Why this chart was retired

This Helm umbrella chart was a second, parallel "full-stack" definition that
never matched reality:

- Its `Chart.yaml` dependencies pointed at an OCI Helm chart repo
  (`oci://ghcr.io/szl-holdings/charts`) that was **never published**, so
  `helm dependency build` could never resolve the organ sub-charts
  (`a11oy-runtime`, `sentra-gates`, `amaru-attestation`, `rosie-replay`).
- Its `values.yaml` pinned organ images at `uds-v0.3.1` — a tag that was
  **never built or pushed**. The published, cosign-signed organ images are
  `uds-v0.2.0` (with `a11oy` tag-pinned `uds-v0.3.0`).
- It carried Doctrine-v6 "STAGED / awaiting FA-001" language for components that
  the rest of the repo has since shipped via verified, digest-pinned packages.

Keeping it around only invited confusion and the risk of an accidental deploy of
non-existent images.

## What to use instead

The verified, working full-stack definition is the **UDS bundle**. Its organ
members are referenced by local path to `packages/<organ>/`, each of which wraps
a cosign-signed, digest-pinned organ image:

```bash
# Build and deploy the verified full-stack UDS bundle
uds create bundles/szl-full-stack
uds deploy szl-full-stack-bundle-<ver>.tar.zst --confirm
```

See [`bundles/szl-full-stack/uds-bundle.yaml`](../../bundles/szl-full-stack/uds-bundle.yaml)
and `STATUS.md` (sections *What's Live* and *What's Deprecated*).

> **Doctrine note:** the organ modules are published, cosign-signed and
> **individually deployable**. Neither this (retired) chart nor the UDS bundle
> claims all five organs boot together on a single cluster.

---

*charts/szl-full-stack/README.md — deprecated 2026-06-11*
