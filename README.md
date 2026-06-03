<div align="center">

# ⚙️ szl-uds-deployment

**uds deploy**

[![DOI](https://zenodo.org/badge/DOI/10.5281/zenodo.20434276.svg)](https://doi.org/10.5281/zenodo.20434276) [![ORCID](https://img.shields.io/badge/ORCID-0009--0001--0110--4173-a6ce39?style=flat-square&logo=orcid&logoColor=white)](https://orcid.org/0009-0001-0110-4173) [![Doctrine v11 LOCKED](https://img.shields.io/badge/Doctrine-v11_LOCKED-d4a444?style=flat-square)](https://github.com/szl-holdings/lutar-lean) [![SLSA](https://img.shields.io/badge/SLSA-L1_honest-22c55e?style=flat-square)](https://slsa.dev/spec/v1.0/levels)

[Hugging Face](https://huggingface.co/SZLHOLDINGS) · [Demo](https://szlholdings-readme.static.hf.space/) · [GitHub Org](https://github.com/szl-holdings)

`receipts.in ≡ receipts.out`

</div>

---
> **STAGED-ADVISORY (2026-05-30 — Doctrine v11 LOCKED 749/14/163):** UDS catalog-grade delivery is BLOCKED pending:
> 1. **Founder action:** Push `ghcr.io/szl-holdings/vessels:0.3.1` to GHCR (requires org GHCR auth chain — cannot be done by agent)
> 2. **Signed assets:** Attach `vessels-uds-0.3.1.tar.zst` + `.sig` + `.sha256` + `vessels-uds-dev.pub` to vessels release `uds-v0.3.1-vessels` (vessels uses `-vessels` suffix for UDS git tags; no bare `uds-v0.3.1` tag exists on vessels)
> 3. **CI gate:** `scripts/verify_signed_assets.sh` must pass green before any PR may claim catalog-grade
>
> Current state: vessels `uds-v0.3.0` has **zero binary release assets**. `uds-v0.3.1` bare tag does not exist on vessels; vessels UDS tags use the `-vessels` suffix (`uds-v0.3.1-vessels` through `uds-v0.3.4-vessels` exist as git tags without GitHub releases).
> Catalog readiness scorecard: [SZLHOLDINGS/uds-governance-receipts — UDS_CATALOG_READINESS_2026-05-30.md](https://huggingface.co/datasets/SZLHOLDINGS/uds-governance-receipts/blob/main/UDS_CATALOG_READINESS_2026-05-30.md)

# szl-uds-deployment

[![GHAS Code Security](https://img.shields.io/badge/GHAS-Code_Security-2DA44E.svg?style=flat-square&logo=github)](https://github.com/szl-holdings/szl-uds-deployment/security/code-scanning)
[![Secret Protection](https://img.shields.io/badge/GHAS-Secret_Protection-2DA44E.svg?style=flat-square&logo=github)](https://github.com/szl-holdings/szl-uds-deployment/security/secret-scanning)
[![SLSA L1 · L2 roadmap](https://img.shields.io/badge/SLSA-L1_%E2%86%92_L2_roadmap-0B1F3A.svg?style=flat-square)](https://slsa.dev/spec/v1.0/levels)

**SZL Governance Receipts — UDS Running Deployment**

DSSE-wrapped audit receipts emitted from live Kubernetes workloads on a UDS infrastructure stack (k3d + uds-cli + Pepr policies).

Built for [Warhacker 2026](https://warhacker.io), June 16-20, San Diego.

---

## What This Is

A UDS add-on that attaches cryptographic governance receipts to every Kubernetes Deployment and Job admitted to the cluster. The Pepr admission controller intercepts each workload API call, generates a DSSE-wrapped HMAC-SHA-256 receipt, posts it to an in-cluster receipt server, and annotates the resource with the receipt ID.

**This is NOT:**
- A replacement for uds-core security policies
- A certified DoD package (Phase 2 intent)
- A modification of uds-core (zero AGPL entanglement — network-only coupling)
- Production-hardened (demo-grade; see Phase 2 roadmap in ARCHITECTURE.md)

---

## Quick Start

```bash
# Prerequisites: Docker, k3d, uds CLI, zarf CLI
# See docs/INSTALL.md for one-liner installs

uds run start           # bootstrap k3d + deploy bundle (~90 seconds)
uds run demo:workload   # apply sample workload → receipt appears in feed
uds run demo:verify     # verify receipt chain from cluster
```

Dashboard: `http://localhost:8443` (after `uds run port-forward`)

---

## Repository Structure

```
szl-uds-deployment/
├── zarf.yaml                      # Zarf package definition
├── uds-bundle.yaml                # UDS bundle manifest
├── tasks.yaml                     # uds-cli task runner
├── tasks/
│   └── demo.yaml                  # demo sub-tasks
├── manifests/
│   └── namespace.yaml             # szl-receipts namespace
├── charts/
│   └── szl-receipts/              # Helm chart: receipt server + dashboard
│       ├── Chart.yaml
│       ├── values.yaml
│       └── templates/
│           ├── deployment.yaml    # MCP receipts server + nginx sidecar
│           ├── service.yaml       # ClusterIP + ServiceAccount + HMAC secret
│           ├── ingress.yaml       # UDS Package CR + ServiceMonitor
│           └── configmap.yaml     # Server Python source + dashboard HTML
├── pepr/                          # Pepr policy module
│   ├── package.json
│   ├── tsconfig.json
│   ├── pepr.ts                    # Module entry point
│   └── policies/
│       └── szl-receipt-on-deploy.ts  # Emit DSSE receipt on Deployment/Job
├── ui/
│   └── dashboard.yaml             # Standalone NGINX dashboard manifest
├── scripts/
│   ├── demo_workload.sh           # Interactive demo workload script
│   ├── demo_workload.yaml         # K8s manifests for demo workload
│   └── verify_receipts.sh         # Post-demo receipt chain verification
└── docs/
    ├── WARHACKER_DEMO.md          # 5-minute talk track (live cluster edition)
    ├── INSTALL.md                  # One-page install + deploy guide
    └── ARCHITECTURE.md            # Cluster diagram + AGPL compliance rationale
```

---

## License

Apache-2.0 — designed to be contributable to the Defense Unicorns ecosystem.

See [LICENSE](LICENSE) for full text.

---

## Contact

Stephen Paul Lutar JR — stephen@szlholdings.com  
[SZL Holdings](https://szlholdings.com)

## Optional Components

The following components are marked `required: false` in `zarf.yaml` and are **skipped on default install**:

- **`szl-receipts-pepr-policy`** — requires building the Pepr policy first:
  ```bash
  cd pepr && pnpm install && pnpm build
  # Produces dist/pepr/ which is imported by zarf.yaml
  ```
  To deploy with Pepr: `zarf package deploy <pkg> --components=szl-receipts-namespace,szl-receipts-server,szl-receipts-pepr-policy`

- **`szl-ui-dashboard`** — requires the `ui/chart` Helm chart directory (Phase 2 deliverable).
  To deploy once available: `zarf package deploy <pkg> --components=szl-receipts-namespace,szl-receipts-server,szl-ui-dashboard`

The default deploy (all `required: true` components only) installs namespace + server.

---

## Pre-Deploy: Ed25519 Receipt Signing Key (Required — Founder Action FA-KEY-001)

> **P0 Gap (Warhacker June 9):** Pepr emits unsigned receipts (`UNSIGNED-NO-KEY-CONFIGURED`)
> until the Ed25519 signing key is provisioned. This MUST be done BEFORE deploying
> `szl-uds-deployment`.

The Pepr admission module (`pepr/policies/szl-receipt-on-deploy.ts`) signs DSSE receipts
with an Ed25519 private key. The key is loaded from the `szl-receipts-ed25519` Kubernetes
Secret in the `pepr-system` namespace.

### Step 1: Generate the Ed25519 keypair

```bash
bash scripts/generate-receipt-key.sh > /tmp/szl-receipt-key.yaml
```

### Step 2: Apply the Secret (before `uds deploy`)

```bash
# Direct apply (cluster must be running)
kubectl apply -f /tmp/szl-receipt-key.yaml

# Shred after apply — never commit the private key
shred -u /tmp/szl-receipt-key.yaml  # or: rm -P /tmp/szl-receipt-key.yaml
```

### Step 3: Mount the key into Pepr pods

After `uds deploy` provisions the Pepr pods, apply the Kustomize patch to mount
the Secret:

```bash
kubectl apply -k kustomize/overlays/pepr-key-mount/
```

> **Note:** Pepr regenerates its Deployment spec on re-deploy. Re-apply this
> kustomize overlay after any `npx pepr deploy` or `uds deploy` operation.

### Step 4: Verify key is active

```bash
kubectl logs -n pepr-system -l app=pepr-admission -f | grep -E "HMAC|Ed25519|UNSIGNED"
# Expected: "[szl] Ed25519 key loaded from mounted Secret (production mode)"
# Expected: "[szl] Receipt signed with Ed25519 (production mode)"
# NOT expected: "UNSIGNED-NO-KEY-CONFIGURED"
```

### GitOps path (SealedSecret)

For GitOps workflows, use Bitnami sealed-secrets to encrypt and commit the key:

```bash
bash scripts/generate-receipt-key.sh | \
  kubeseal --namespace pepr-system \
  > k8s/secrets/szl-receipts-ed25519.sealedsecret.yaml
git add k8s/secrets/szl-receipts-ed25519.sealedsecret.yaml
git commit -m "feat: add sealed Ed25519 receipt signing key"
```

**References:**
- `k8s/secrets/szl-receipts-ed25519.yaml` — placeholder Secret spec with instructions
- `scripts/generate-receipt-key.sh` — key generation script
- `kustomize/overlays/pepr-key-mount/` — Kustomize patch to mount key into Pepr pods
- `docs/CRYPTO_KEY_HANDLING.md` — key custody policy
- `docs/KEY_CUSTODY_RUNBOOK.md` — operational runbook

