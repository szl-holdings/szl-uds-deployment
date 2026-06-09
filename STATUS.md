# STATUS.md

**Updated:** 2026-06-09
**Doctrine v11 — 749 / 14 / 163 — replay hash c7c0ba17**

---

## What's Live

- Repository active and maintained under Apache-2.0 license
- **`a11oy` + `killinchu` module images published & signed** — both are in
  org GHCR (`ghcr.io/szl-holdings/{a11oy,killinchu}:uds-v0.2.0`), keyless
  cosign-signed (Fulcio/Rekor) with an SLSA provenance attestation. Both
  `cosign verify` and `cosign verify-attestation` pass on a clean-env pull.
  The Zarf packages (`packages/{a11oy,killinchu}/`) pin these signed digests
  (single-arch `manifest.v2`, `image-pin-guard`-safe).
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
