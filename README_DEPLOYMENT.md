# SZL UDS Deployment — Operator Guide (killinchu + a11oy)

**szl-uds-deployment** · Built with Zarf + UDS Core + keyless Sigstore signing

This repo deploys the SZL flagships onto a UDS (Defense Unicorns) cluster:

| Flagship | What it is | Chart | Image |
|---|---|---|---|
| **a11oy** | Governed multi-model assistant + receipts console | `charts/a11oy` | `ghcr.io/szl-holdings/a11oy:uds-v0.2.0` |
| **killinchu** | Andean Drone Intelligence (Doctrine v11) | `charts/killinchu` | `ghcr.io/szl-holdings/killinchu:uds-v0.2.0` |

> **Note — "vessels" is retired.** The legacy `szl-vessels-demo` package
> (`zarf-package-szl-vessels-demo-*`, `svc/vessels-web`, ns `szl-vessels`) was
> **consolidated into killinchu**. There is no longer a vessels package, chart,
> namespace, or service. Any doc, script, or screenshot referencing
> `vessels-web` / `szl-vessels` / `zarf-package-szl-vessels-demo-amd64-0.3.1`
> is stale — substitute **killinchu** (ns `szl-killinchu`, `svc/szl-killinchu`).

---

## Live cluster facts (read this first)

The reference cluster (k3d `uds-szl-demo`) is small (2 vCPU) and runs the **Istio
ambient dataplane**, not sidecars. Both flagships are deployed accordingly:

- **Ambient mesh, no sidecar.** Namespaces carry `istio.io/dataplane-mode: ambient`.
  A sidecar (`istio-injection=enabled` or any `sidecar.istio.io/inject` annotation)
  is **rejected** by the `pepr-uds-core.pepr.dev` admission webhook and also fails to
  pull the proxy image offline. Do not add it.
- **Restricted PodSecurity.** Namespaces enforce `pod-security.kubernetes.io/enforce: restricted`.
  Pods run `runAsNonRoot`, `readOnlyRootFilesystem`, drop `ALL` caps.
- **Ports.** Both apps listen on container port **7860**. The Service exposes the
  mesh / NetworkPolicy-facing port **8080** and targets **7860**
  (`service.port: 8080`, `service.targetPort: 7860`).
- **Health.** killinchu readiness: `GET /api/killinchu/healthz` on :7860.

---

## Bumping the szl-receipts version (use the script, don't hand-edit)

The szl-receipts version lives in **three** files that must agree, or a fresh
clone installs the wrong thing and CI goes red (`version-coherence-guard.yml`
plus the image-digest / pin guards):

| File | Field(s) |
|---|---|
| `charts/szl-receipts/Chart.yaml` | `version` **and** `appVersion` |
| `charts/szl-receipts/values.yaml` | `server.image.tag` (`uds-v<version>`) **and** `server.image.digest` |
| `packages/szl-receipts/zarf.yaml` | the server image ref `ghcr.io/szl-holdings/szl-receipts-server:uds-v<version>@sha256:<digest>` |

A half-finished hand-edit once left the chart on `0.4.0` while the image tag /
zarf ref had already moved to `uds-v0.4.1`; the coherence guard only *catches*
that drift after the fact. Do not hand-edit these files. Instead:

```bash
# 1. Publish the new image first (separate step): push tag
#    receipts-server-v<version>  ->  receipts-server-image.yml builds + cosign-
#    signs ghcr.io/szl-holdings/szl-receipts-server:uds-v<version>.
# 2. Resolve the published linux/amd64 CHILD digest (never the multi-arch index).
# 3. Bump every version site in lockstep, in one command:
scripts/bump-receipts-version.sh <new-version> <new-digest>
#    e.g. scripts/bump-receipts-version.sh 0.4.2 sha256:758052db...
# 4. Review and commit:
git diff
```

The same digest is written to BOTH `values.yaml` and `zarf.yaml` so they stay
byte-identical (`image-pin-guard`'s `chart-zarf-digest-match` check). After the
script runs, `version-coherence-guard.yml` passes with no manual edits.

> **Forward-only.** Never rename an already-signed `uds-v*` tag — that breaks the
> cosign signature. Bump to a NEW version; see `scripts/check_version_doctrine.sh`.

---

## Prerequisites

| Tool | Minimum version |
|---|---|
| Docker | 24.0 |
| k3d | 5.6.0 |
| zarf | 0.77.0 |
| kubectl | 1.29 |
| helm | 3.14 |
| cosign | 2.4.x |
| jq | 1.7 |

```bash
for t in docker k3d zarf kubectl helm cosign jq curl; do
  command -v "$t" >/dev/null && echo "ok: $t" || echo "MISSING: $t"
done
```

**Disk**: ~4 GB free · **RAM**: 8 GB min (16 GB recommended).

### UDS Core registry login (required before `uds run start` / `uds run bundle`)

The UDS bundle pulls UDS Core from `registry.defenseunicorns.com/public/core:1.5.0-upstream`,
which is **not anonymous** (an unauthenticated pull returns `401`). Create a free
account at https://registry.defenseunicorns.com, then log the build box in once:

```bash
echo "$DU_REGISTRY_TOKEN" | zarf tools registry login registry.defenseunicorns.com \
  -u "$DU_REGISTRY_USERNAME" --password-stdin
```

---

## Option A — Canonical supply-chain deploy (UDS bundle)

The signed, reproducible path. The bundle's Zarf agent mirrors images into the
in-cluster registry and applies the UDS Package CRs (NetworkPolicies, mTLS,
monitors). See the available tasks:

```bash
uds run --list
uds run start        # create cluster + uds core + deploy the registered packages
```

Registered packages live under `packages/` and are wired into `uds-bundle.yaml`.
Deploy a single flagship package directly:

```bash
zarf package deploy zarf-package-a11oy-amd64-uds-v0.2.0.tar.zst --confirm
```

Verify an image signature (keyless cosign) before deploy:

```bash
cosign verify ghcr.io/szl-holdings/killinchu:uds-v0.2.0 \
  --certificate-identity 'https://github.com/szl-holdings/killinchu/.github/workflows/ghcr-build-push.yml@refs/heads/main' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
```

---

## Option B — Direct chart deploy onto the ambient box (validated)

When the full bundle build is too heavy for the box, deploy a flagship straight
from its chart. The chart already declares the ambient namespace + restricted PSA;
images pull directly from GHCR because you label the namespace `zarf.dev/agent: ignore`, which tells the Zarf agent to skip image-rewriting for this namespace. (Option B has no in-cluster image mirror; the canonical bundle path in Option A does the mirroring instead, so do **not** bake this label into the chart.)
The receipt-signing key-init hook is **off by default** (it needs root + kubectl,
which the restricted/ambient cluster forbids); the receipt key Secret is mounted
`optional: true`.

```bash
# 1) Pre-create the namespace so Helm can store its release secret, then let the
#    chart's own Namespace template reconcile the ambient + restricted labels.
kubectl create namespace szl-killinchu
kubectl label   namespace szl-killinchu app.kubernetes.io/managed-by=Helm --overwrite
kubectl label   namespace szl-killinchu zarf.dev/agent=ignore --overwrite  # Option B: pull images straight from GHCR
kubectl annotate namespace szl-killinchu \
  meta.helm.sh/release-name=killinchu \
  meta.helm.sh/release-namespace=szl-killinchu --overwrite

# 2) Install (skip hooks; key-init is gated off in values.yaml).
helm install killinchu charts/killinchu -n szl-killinchu --no-hooks

# 3) Wait + verify.
kubectl rollout status deploy/killinchu -n szl-killinchu --timeout=180s
kubectl get pods -n szl-killinchu      # expect 1/1 Running (single container)
```

a11oy follows the same shape from `charts/a11oy` (ns `szl-a11oy`, port 7860).

### Verify killinchu is serving

```bash
# In-pod health (kubelet runs this as the readiness probe):
POD=$(kubectl get pod -n szl-killinchu -l app=killinchu -o jsonpath='{.items[0].metadata.name}')
kubectl get pod -n szl-killinchu $POD \
  -o jsonpath='{range .status.conditions[*]}{.type}={.status} {end}{"\n"}'   # Ready=True
kubectl logs -n szl-killinchu $POD --tail=3   # "Andean Drone Intelligence on :7860 — Doctrine v11"
```

---

## Troubleshooting

### Pod is `0/2 Init:ErrImagePull` (istio proxyv2)
A **sidecar is being injected**. The ambient cluster has no proxy image to pull.
Remove the sidecar trigger: drop `istio-injection=enabled` from the namespace and
remove the `sidecar.istio.io/inject` annotation from the pod template. The shipped
charts already avoid both.

### `FailedCreate ... pepr-uds-core.pepr.dev denied the request: ... annotation sidecar.istio.io/inject`
The UDS webhook forbids the **mere presence** of that annotation in ambient mode —
true *or* false. It must be absent entirely (the charts do not set it).

### Pod `Running` but `0/1` (never Ready)
Port mismatch. The app listens on **7860**; an older chart probed **8080**.
Confirm `service.targetPort: 7860` and the readiness probe port is 7860.

### `helm uninstall` deleted the namespace
The Helm-owned Namespace template is removed on uninstall, which can race a
reinstall. Wait for `kubectl get ns szl-killinchu` to report NotFound, then redo
the Option B steps.

### key-init Job fails (`kubectl: not found` / PSA denied)
Leave `receiptKeyInit.enabled: false` (default) and install with `--no-hooks`.
The receipt key Secret is optional; signing falls back to an ephemeral key.

---

## Key file locations

| Path | Purpose |
|---|---|
| `charts/a11oy/` | Helm chart — a11oy flagship (ambient, port 7860) |
| `charts/killinchu/` | Helm chart — killinchu flagship (ambient, port 7860) |
| `charts/killinchu/values.yaml` | `service.port`/`service.targetPort`, `receiptKeyInit.enabled` |
| `packages/` | Zarf/UDS package manifests per flagship |
| `uds-bundle.yaml` | Aggregate UDS bundle (registered packages) |
| `tasks.yaml` | `uds run` tasks (`start`, `bundle`, `smoke`) |
| `pepr/` | Pepr admission controller (receipt-on-deploy webhook) |

---

## References

- [Defense Unicorns UDS Core](https://github.com/defenseunicorns/uds-core)
- [Zarf](https://github.com/zarf-dev/zarf) — keyless package signing
- [Sigstore keyless signing](https://docs.sigstore.dev/cosign/signing/keyless/)
- [Istio ambient mesh](https://istio.io/latest/docs/ambient/)
- [Pepr admission controller](https://docs.pepr.dev)
- [DSSE envelope spec](https://github.com/secure-systems-lab/dsse)

---

*Defense Unicorns, Pepr, and UDS are trademarks of Defense Unicorns Inc. This project is an independent add-on and is not affiliated with or endorsed by Defense Unicorns Inc.*
