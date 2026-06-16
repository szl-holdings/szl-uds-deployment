<!-- SPDX-License-Identifier: Apache-2.0 -->
# UDS_DEPLOY_RUNBOOK.md — SZL flagships on Defense Unicorns UDS Core

> **Trademark notice.** SZL Holdings' use of "UDS" references Defense Unicorns' Unified Defense Stack (USPTO Serial 99831122). SZL Holdings is not affiliated with Defense Unicorns. SZL contributions to the UDS ecosystem are made through upstream PRs. See: https://defenseunicorns.com/uds

Runnable command sequence to stand up `a11oy` + `killinchu` (and the other organ
packages) on a **UDS Core** cluster, sign/verify the Zarf packages, apply the
cosign `ClusterImagePolicy`, deploy the `szl-mesh` bundle, and gather live
compliance evidence with Lula/OSCAL. Mirrors `RESEARCH_R2_ANVAKA_UDS.md` Section B.4.

## What is RUNNABLE vs SIMULATED (be honest)

| Step | On a real connected build box + cluster | In this CI / sandbox (no cluster, egress-limited) |
|---|---|---|
| `uds deploy k3d-core-slim-dev` | **RUNNABLE** (needs Docker/Lima + k3d ≥ v5.7.1 + UDS CLI ≥ v0.27) | **SIMULATED** — no container runtime / cluster here |
| `zarf package create` | **RUNNABLE** | **SIMULATED** — needs Zarf + image pulls |
| `zarf package sign` / `verify` | **RUNNABLE** | **SIMULATED** — signing needs the key/OIDC + Rekor |
| `uds create` (bundle) | **RUNNABLE** | **SIMULATED** — needs UDS CLI + package tarballs |
| `kubectl apply` ClusterImagePolicy | **RUNNABLE** | **SIMULATED** — no kube-apiserver here |
| `uds deploy` bundle | **RUNNABLE** | **SIMULATED** |
| `kubectl get packages` | **RUNNABLE** | **SIMULATED** |
| `lula validate` | **RUNNABLE — but only meaningful against a LIVE cluster** (queries return nothing offline) | **SIMULATED** |

> We do **not** run a real Kubernetes cluster from CI; the OSCAL component
> PASS/FAIL is only earned on a live cluster. This runbook is the exact sequence a
> dev/founder runs on the connected build box.

---

## 0. Prereqs (connected build box)
```bash
# k3d >= v5.7.1, UDS CLI >= v0.20.0 (we target >= v0.27), Zarf >= v0.77.0,
# a running container runtime (Docker Desktop / Lima), cosign installed.
uds version && zarf version && k3d version && cosign version
```

## 1. Stand up a dev UDS Core cluster (k3d-core-slim-dev = Istio + Keycloak + Pepr)
```bash
uds deploy k3d-core-slim-dev:0.41.0 --confirm        # slim dev; or k3d-core-demo for full core
```

## 2. (one-time) cosign keys — RECONCILED & HONEST
```bash
# Canonical signing is KEYLESS (GitHub OIDC -> Fulcio + Rekor). Both a11oy and
# killinchu .github/workflows/cosign.yml run `cosign sign --yes` keyless and
# self-verify with --certificate-identity-regexp + --certificate-oidc-issuer.
# No COSIGN_PRIVATE_KEY secret is provisioned, so KEYLESS is what actually runs.
#
# The committed ECDSA-P256 cosign.pub is the OPTIONAL/LEGACY key-pair path
# (effective only if an operator later provisions COSIGN_PRIVATE_KEY).
# zarf tools gen-key   # -> cosign.key + cosign.pub  (only for the optional keyed path)
```

## 3. Build each organ Zarf package (image + chart + SBOM + attestations)
```bash
cd a11oy/deploy           && zarf package create . --confirm
cd ../../killinchu/deploy && zarf package create . --confirm
#   (repeat for sentra / amaru / yupana deploy dirs)
```

## 4. Sign + verify each Zarf package (offline-verifiable)
```bash
# Keyless (authoritative) — verify against the workflow identity + OIDC issuer:
zarf package verify zarf-package-a11oy-amd64-uds-v0.3.1-rc.1.tar.zst \
  --certificate-identity      "https://github.com/szl-holdings/a11oy/.github/workflows/release.yml@refs/heads/main" \
  --certificate-oidc-issuer   "https://token.actions.githubusercontent.com"

# Optional keyed path (only if the keyed pair is enabled):
#   zarf package sign  zarf-package-a11oy-amd64-uds-v0.3.1-rc.1.tar.zst --key cosign.key
#   zarf package verify ...                                            --key cosign.pub
```

## 5. Build the mesh bundle with uds-cli (kind: UDSBundle)
```bash
cd uds-bundles && uds create . --confirm             # -> szl-mesh-v0.4.0 bundle tarball
```

## 6. Apply the cosign ClusterImagePolicy BEFORE deploy (fail-closed admission)
```bash
# Policies now carry the reconciled key + an ACTIVE keyless authority (no placeholder).
# Two authorities are OR'd: szl-keyless (LIVE) and szl-key (optional/legacy ECDSA-P256).
kubectl apply -f bundles/szl-a11oy/policies/cosign-image-policy.yaml
kubectl apply -f bundles/szl-killinchu/policies/cosign-image-policy.yaml
kubectl label namespace a11oy     policy.sigstore.dev/include=true --overwrite
kubectl label namespace killinchu policy.sigstore.dev/include=true --overwrite
```

### ⚠️ `mode: warn` -> `mode: enforce` switch (DRESS REHEARSAL REQUIRED)
The shipped policies are **`mode: warn`** during rollout. Do **not** silently
enforce. Flip to enforce only after a green dress rehearsal:

```bash
# (a) Deploy in warn mode and confirm NO violations are logged for legitimately
#     signed images (check policy-controller logs):
kubectl -n cosign-system logs deploy/policy-controller-webhook | grep -i "warn\|deny" || echo "no warnings"

# (b) Dry-run the enforce flip on a scratch namespace first:
sed 's/^  mode: warn.*/  mode: enforce/' bundles/szl-a11oy/policies/cosign-image-policy.yaml \
  | kubectl apply --dry-run=server -f -

# (c) Only if (a)+(b) are clean, flip for real (one organ at a time, watch rollouts):
sed -i 's/^  mode: warn.*/  mode: enforce/' bundles/szl-a11oy/policies/cosign-image-policy.yaml
kubectl apply -f bundles/szl-a11oy/policies/cosign-image-policy.yaml
#   repeat for killinchu after a11oy is observed healthy.
# Rollback: re-apply the warn version if any signed image is unexpectedly blocked.
```

## 7. Deploy the bundle onto the running UDS Core cluster
```bash
uds deploy szl-mesh-v0.4.0.tar.zst --confirm         # air-gap (USB) path
#   or OCI:  uds deploy oci://ghcr.io/szl-holdings/szl-mesh:v0.4.0 --confirm
```

## 8. Verify the UDS Operator reconciled our Package CRs
```bash
kubectl get packages -A                              # uds.dev/v1alpha1 Package -> Ready
kubectl get virtualservices,networkpolicies -n a11oy
kubectl get virtualservices,networkpolicies -n killinchu
```

## 9. Compliance evidence on the LIVE cluster (Lula / OSCAL)
```bash
lula validate -f compliance/oscal-component-a11oy.yaml
lula validate -f compliance/oscal-component-killinchu.yaml
lula validate -f compliance/oscal-component-sda.yaml
lula evaluate  ...                                   # track compliance over time
#   -> machine-readable OSCAL assessment-results.
#   Posture: SLSA L1+L2 attested ONLY where attest-build-provenance runs +
#   cosign verify-attestation succeeds; else L1 honest / L2 roadmap; L3 roadmap.
#   ATO-ALIGNED ROADMAP ONLY — never a real ATO. No FedRAMP / Iron Bank / CMMC
#   without "roadmap". Bundle-level SLSA provenance IS now earned: uds-bundle-publish.yml
#   (and uds-bundle-attest-existing.yml for already-published tags) runs
#   `cosign attest --type slsaprovenance` KEYLESS (Fulcio/Rekor OIDC — needs only
#   packages:write, NOT GitHub attestations:write) alongside the SBOM attestation;
#   prove-bundle/prove-coboot hard-gate on `cosign verify-attestation` for BOTH
#   (spdxjson + slsaprovenance, exact signer identity). The cosign signature plus
#   these two keyless attestations ARE the bundle provenance.
```

## 10. Reach the UIs (Istio ingress / Keycloak SSO)
```text
https://a11oy.uds.dev      (a11oy SSO via Keycloak client "a11oy")
https://killinchu.uds.dev  (killinchu SSO via Keycloak client "killinchu")
```


## 11. One-liner — prove the bundle installs (publish + keyless-sign are the pending box step)
```bash
# Canonical (all five organs, isolated CI runners): cosign-verify the keyless
# signature, then cold k3d + UDS substrate + deploy each organ + in-cluster health 200:
gh workflow run prove-bundle-install.yml -f organ=all -f bundle_tag=uds-v0.3.0

# Local single-organ equivalent (the underlying task; connected dev/build box):
uds run prove-bundle --set ORGAN=a11oy \
  --set BUNDLE_REF=ghcr.io/szl-holdings/szl-uds-bundle:uds-v0.3.0
# Target published/signed/SBOMed evidence (ROADMAP — produced by Forge's box
# sign+publish; not yet live). The OCI ref/digest below is the TARGET example,
# not live evidence, until the box sign+publish step runs:
#   oci://ghcr.io/szl-holdings/szl-uds-bundle:uds-v0.3.0
#   @ sha256:e61c2f9880560ec71812f546b9bad09de4b9d58ad15b27968cb9cf23dd6a4f4a
```

## 11b. One-liner — prove the two consolidated organs CO-BOOT (a11oy + killinchu)
```bash
# Post-consolidation upgrade of §11: prove the TWO deployable organs BOOT
# TOGETHER on ONE clean cluster from the published, cosign-signed bundle, and
# each serves an in-cluster HTTP 200 (port-forward bypasses Istio STRICT mTLS;
# a meshless ClusterIP curl would be REJECTED):
gh workflow run prove-coboot.yml -f bundle_tag=uds-v0.3.0
# Local task equivalent (connected build box):
uds run prove-coboot --set BUNDLE_REF=ghcr.io/szl-holdings/szl-uds-bundle:uds-v0.3.0

# LIVE EVIDENCE (CI run 27592855545, 2026-06-16) — all GREEN:
#   cosign verify PASS (keyless Fulcio/Rekor; signer uds-bundle-publish.yml@refs/heads/main)
#   cosign verify-attestation PASS — SBOM (spdxjson) + SLSA provenance (slsaprovenance),
#     keyless, exact signer identity (HARD gate; a bogus identity is rejected)
#   a11oy + killinchu BOTH Available on ONE cluster (co-resident)
#   a11oy /healthz -> HTTP 200 ; killinchu /api/killinchu/healthz -> HTTP 200
#   AIRGAP AUDIT PASS — every a11oy+killinchu workload image (incl. init + Istio
#     sidecars) served from the in-cluster Zarf registry, digest-pinned, no external
#     pull (field airgap-installable; the build/substrate phase has network)
# Honest scope: proves co-residency of the TWO consolidated deployables ONLY;
# does NOT claim the legacy 5-organ fleet co-boots. Energy SAMPLE.
```

---

## Honest status labels (keep verbatim)
- **STAGED** — `szl-receipts` / `a11oy-runtime` packages are marked STAGED until the
  container images are pushed to `ghcr.io/szl-holdings/*:uds-v0.x` + signed (FA-001).
  Keep STAGED labels until the images are actually pushed.
- **Mesh interconnect** — cross-organ Istio AuthorizationPolicy / strict
  PeerAuthentication in `uds-mesh` is **roadmap v0.4.0** (per-organ Package-CR
  allow/expose already authored; full interconnect not yet live).
- **SLSA** — bundle carries keyless SBOM + SLSA-provenance attestations (cosign
  `--type slsaprovenance`, Fulcio/Rekor OIDC; no GitHub attestations:write needed);
  prove-bundle/prove-coboot hard-gate on `cosign verify-attestation` for both.
  L1+L2 earned at the bundle level; L3 roadmap.
- **Airgap-installable (field)** — prove-bundle/prove-coboot AIRGAP AUDIT asserts every
  workload image (incl. init + Istio sidecars) resolves to the in-cluster Zarf registry
  (no external pull) + is digest-pinned. Scope: the FIELD install is airgapped; the
  BUILD/substrate phase has network.
- **No real ATO** — ATO-aligned roadmap only.

## References
- UDS Core: https://github.com/defenseunicorns/uds-core
- UDS Package CR: https://uds.defenseunicorns.com/reference/configuration/uds-operator/package/
- UDS CLI: https://github.com/defenseunicorns/uds-cli
- Zarf package signing: https://docs.zarf.dev/ref/package-signing/
- Sigstore policy-controller: https://docs.sigstore.dev/policy-controller/overview/
- Lula (OSCAL): https://github.com/defenseunicorns/lula
- Cosign keyless: https://docs.sigstore.dev/cosign/signing/keyless/
