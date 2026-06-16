<!-- Copyright 2026 SZL Holdings · SPDX-License-Identifier: Apache-2.0 -->

# TAWANTIN — the governed distributed compute fabric, unified

**TAWANTIN** (Quechua *tawantin*, "the four united regions" — Tawantinsuyu) is the
**unified fabric** UDS bundle. It composes SZL's governed-compute-fabric story —
the a11oy sovereign GPU-mesh router, the energy-per-successful-goal signal, and the
Khipu signed-receipt chain — into **one airgap-deployable, cosign-signable** OCI
bundle.

```text
uds deploy oci://ghcr.io/szl-holdings/tawantin-bundle:0.1.0 --confirm
```

This is the bundle that closes the Warhacker **deployability** gap: the live
demo (a11oy.net + killinchu) is reachable today, and TAWANTIN is the UDS Core
package that makes that fabric *mission-ready out of the box* (Zarf-portable,
airgap-deployable, cosign-signable).

---

## What it composes

| Member | Source | Status | Role in the fabric |
| --- | --- | --- | --- |
| `szl-a11oy` | `packages/a11oy` (path build) | **LIVE / digest-pinned** | The sovereign GPU-mesh governed router (RTX 5050 + OMEN RTX 4060 Ti + chaski + cloud-NIM failover under one governed OpenAI-compatible router). |
| `szl-energy-harvest` | `packages/energy-harvest` (path build) | **VALIDATED / image-gated** | The energy-per-successful-goal signal (joules SAMPLE here; MEASURED on-box is the a11oy organ's job). |
| `szl-tawantin` | `packages/tawantin` (path build) | **VALIDATED / image-gated** | The fabric-overview surface + governed UDS Package CR that unifies the story (a11oy mesh + energy + Khipu receipts). |

**Honest status (Doctrine v11 §10 — "no 'ready' without HTTP 200"):** the a11oy
member is live and digest-pinned; the energy + tawantin members are *build-valid*
but their workload images are **GATED** (the `images:` lists in their `zarf.yaml`
are intentionally commented out) until those images are published + cosign
keyless-signed on GHCR. We do **not** pin a fabricated digest. This bundle is
**SCHEMA-VALID** and every member is **build-valid**; it does **not** claim all
three members co-boot on one cluster, and the published OCI artifact is **not**
cosign-signed yet (founder FA-001 step below).

---

## Doctrine (Doctrine v11 — HARD GATES, never weakened)

- locked = **EXACTLY 8** {F1,F4,F7,F11,F12,F18,F19,F22} @ kernel **c7c0ba17**.
- **Λ = Conjecture 1** (never an unconditional theorem; conditional Theorem U is
  fine). **Khipu BFT = Conjecture 2.**
- **SLSA L1 honest · L2 attested (organ images) · L3 roadmap** — never bare
  L3/FedRAMP/IronBank/CMMC/ATO.
- trust never 100%; **tamper-EVIDENT** not tamper-proof; **effectors SIMULATED**
  human-on-loop; 0 runtime CDN.
- **NEVER fused/combined VRAM** — nodes scale horizontally (placement +
  load-balance); memory does **not** merge across the network.
- **Orbital/space = ROADMAP**, clearly labeled. The terrestrial governed mesh is
  the proven core; we do **not** run satellites.
- Never commit a key.

---

## Build + validate (no founder step — anyone with the CLIs)

Pre-build the flavor-gated a11oy member, then create the bundle. (The energy +
tawantin members are gated on their images; `uds create` will only bake their
workloads once those images are published + their `images:` lists are
uncommented + digest-pinned — until then the bundle validates structurally.)

```bash
# 1. Pre-build the flavor-gated a11oy member (-> ...-0.1.0-upstream.tar.zst).
uds zarf package create ../../packages/a11oy -f zarf.yaml \
  --set VERSION=0.1.0 --set DOMAIN=uds.dev -a amd64 --flavor upstream --confirm

# 2. Lint the members (no cluster needed).
uds zarf dev lint ../../packages/tawantin
uds zarf dev lint ../../packages/energy-harvest

# 3. Create the bundle (gated on the energy/tawantin images until published).
uds create . --confirm -a amd64
```

---

## FOUNDER-GATED step — the ONE thing remaining (FA-001 key, NEVER committed/faked)

Publishing **and** cosign-signing the `tawantin-bundle:0.1.0` OCI artifact is the
single remaining founder-held step. The FA-001 signing key is **founder-only** and
is **never committed or faked** (`.gitignore` blocks `*.key` / `*.pem`; if you ever
see a private key staged, abort the commit). Run once, locally, with the founder's
`cosign` CLI authenticated to GitHub via `gh`:

```bash
# (A) Publish the bundle artifact to GHCR.
uds publish tawantin-bundle-amd64-0.1.0.tar.zst oci://ghcr.io/szl-holdings

# (B) FOUNDER-ONLY — cosign-sign the published bundle artifact with FA-001.
#     Keyless (Sigstore OIDC) is the canonical path — no key file is committed.
cosign sign ghcr.io/szl-holdings/tawantin-bundle:0.1.0 --yes
```

### Verify the signed bundle (no key file — keyless)

After (B), verify with an **exact** signer identity (never the loose
`--certificate-identity-regexp` form):

```bash
cosign verify ghcr.io/szl-holdings/tawantin-bundle:0.1.0 \
  --certificate-identity "https://github.com/szl-holdings/szl-uds-deployment/.github/workflows/zarf-package-sign.yml@refs/heads/main" \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
```

> The published bundle digest is recorded at sign time; record it in the release
> notes so verifiers can pin it. Until step (B) runs, `cosign verify` on the
> bundle artifact **will fail** — that is the honest, expected posture.

---

## Additive + guard-compatible

This bundle is **purely additive** — it adds `bundles/tawantin/` and
`packages/tawantin/` and touches **no** existing bundle or package. It is
compatible with the repo guards:

- **uds-bundle-publish-guard** — fires only when `uds-bundle-publish.yml` /
  `prewarm-ghcr-blobs.sh` / its checks are edited; TAWANTIN touches none of them.
- **zarf-action-var-guard** — globs every `**/zarf.yaml`; `packages/tawantin/zarf.yaml`
  uses only a `wait` action (no `cmd:` block), so it carries **zero**
  `###ZARF_VAR_*###` template forms inside any action command.
- **cosign-identity-pin-guard** — the only pinned-artifact reference here
  (`zarf-package-sign.yml`) is documented with an **exact** `--certificate-identity`,
  not the loose regexp form.

References: sibling bundles `../szl-warhacker/`, `../a11oy/`, `../energy/`.
