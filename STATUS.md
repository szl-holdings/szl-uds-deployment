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

## What's Experimental

- Components noted as experimental in individual module documentation

## What's Deprecated

- **`vessels`** (maritime sibling of killinchu) — preserved as reference, killinchu is the primary defense flagship
- **`szl-constellation`** — replaced by the `anatomy-3d` 3D viewer

---

*Co-Authored-By: Perplexity Computer Agent*
*Doctrine v11 — 749/14/163 — c7c0ba17*
