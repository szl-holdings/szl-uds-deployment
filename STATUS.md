# STATUS.md

**Updated:** 2026-06-09
**Doctrine v11 — 749 / 14 / 163 — replay hash c7c0ba17**

---

## What's Live

- Repository active and maintained under Apache-2.0 license
- **All five organ module images published & signed** — `a11oy`,
  `killinchu`, `amaru`, `sentra` and `rosie` are in org GHCR
  (`ghcr.io/szl-holdings/{a11oy,killinchu,amaru,sentra,rosie}:uds-v0.2.0`),
  each built single-arch (`provenance: false`, plain `manifest.v2` — no OCI
  index) and keyless cosign-signed (Fulcio/Rekor) with an SLSA provenance
  attestation. For every organ, `cosign verify` and
  `cosign verify-attestation --type slsaprovenance` pass on a clean-env pull
  (legacy `.sig`/`.att` tag scheme that the box's cosign v2.4.1 reads). The
  Zarf packages (`packages/{a11oy,killinchu,amaru,sentra,rosie}/`) pin these
  signed digests (single-arch, `image-pin-guard`-safe).
  **Honest scope:** this proves each module image is published, signed, and
  individually deployable — it does **not** claim "all five modules boot
  together." The organs still deploy as **separate workloads**; cross-organ
  in-cluster mTLS is v0.5.0 roadmap.
- **Full-mesh / multi-organ bundle uses only verified images** — the
  multi-organ UDS bundle `bundles/szl-full-stack/uds-bundle.yaml` now references
  its organ members (`a11oy`, `sentra`, `amaru`, `rosie`) by LOCAL path to
  `packages/<organ>/`, which pin the cosign-signed organ images above
  (amaru/sentra/rosie at `uds-v0.2.0@sha256:…`; a11oy tag-pinned `uds-v0.3.0`
  by design). The earlier broken `repository: ghcr.io/szl-holdings/<organ>` +
  `ref: uds-v0.3.1` placeholders (an image-repo coordinate, never a published
  Zarf package) are gone, so the full-mesh path pulls **only verified images**.
  `cosign verify` and `cosign verify-attestation --type slsaprovenance` pass for
  each pinned organ digest. This does **not** change the doctrine above: the
  organs remain published, signed and **individually deployable** — the bundle
  does **not** claim all five boot together.

## What's Experimental

- Components noted as experimental in individual module documentation

## What's Deprecated

- **`charts/szl-full-stack/` Helm umbrella chart** — retired in favour of the
  UDS bundle `bundles/szl-full-stack/uds-bundle.yaml`. The chart was a duplicate
  Doctrine-v6 "STAGED" full-stack definition that depended on an OCI Helm chart
  repo (`oci://ghcr.io/szl-holdings/charts`) that was never published and pinned
  organ images at `uds-v0.3.1` that were never built (the published, signed organ
  images are `uds-v0.2.0`, with `a11oy` at `uds-v0.3.0`). It is now marked
  `deprecated: true` in `Chart.yaml`, all sub-components are disabled, and its
  README/NOTES point to the verified UDS bundle. The bundle remains the only
  verified full-stack path; no `uds-v0.3.1` organ image is claimed deployable.
- **`vessels`** (maritime sibling of killinchu) — preserved as reference, killinchu is the primary defense flagship
- **`szl-constellation`** — replaced by the `anatomy-3d` 3D viewer

---

*Co-Authored-By: Perplexity Computer Agent*
*Doctrine v11 — 749/14/163 — c7c0ba17*
