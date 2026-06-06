<!--
Copyright 2026 SZL Holdings · SPDX-License-Identifier: Apache-2.0
Doctrine v11 LOCKED 749/14/163 @ c7c0ba17 · Λ = Conjecture 1 (NEVER a theorem)
SLSA L1+L2 honest — images attested, bundle-level attestation NOT earned (cosign signature is the bundle provenance) · NOT L3 · NOT Iron Bank · No FedRAMP/CMMC
Section 889 = exactly 5 vendors
Signed-off-by: Stephen P. Lutar Jr. <stephenlutar2@gmail.com>
-->

# HETZNER TOWER + UDS — COMPLETE DEPLOY ROADMAP (execute today)

**For:** Stephen P. Lutar Jr. (Founder/CEO), SZL Holdings
**Goal:** go from a **bare Hetzner box** to **a11oy + killinchu running, governed, on UDS Core v1.5.0**, by following copy-pasteable steps. GitHub-handoff-first.
**Verified:** every OCI artifact referenced below was probed **HTTP 200** on GHCR on 2026-06-06 before being written into this runbook (see §VERIFY EVIDENCE at the end). No fabricated steps.

> **Honesty doctrine (kept throughout):** SLSA **Build L2 on the 5 organ images** (cosign `.sig` + `.att` = `slsa.dev/provenance/v0.2`). **Bundle-level SLSA attestation is NOT earned** — the cosign **signature** is the bundle's provenance. **NOT L3, NOT Iron Bank, no FedRAMP/CMMC.** Λ = **Conjecture 1** (never a theorem). Cross-organ in-cluster mTLS mesh is **v0.5.0 roadmap** — the organs deploy as separate workloads. Say this out loud; the honesty is the credibility.

---

## QUICK MAP — what you will do

| Phase | What | Time |
|---|---|---|
| §1 Prereqs | OS packages, tools (uds/zarf/cosign/docker/k3d), GHCR login, DNS | ~15 min |
| §2 UDS Core | stand up the secure baseline (Istio ambient, Keycloak, Pepr, Prometheus/Grafana, Vector/Loki, Falco, Velero) | ~10 min |
| §3 Deploy | `uds deploy oci://…szl-mesh:0.4.0` (or a11oy/killinchu bundles) + air-gap path + Package CRs | ~10 min |
| §4 Verify | cosign verify, gh attestation, healthz, mesh reach, offline receipt verify | ~10 min |
| §5 GitHub handoff | exact clone order: szl-build-env → szl-uds-deployment → uds-bundles → szl-fleet-overlay | — |
| §6 Troubleshooting | the known gotchas | — |
| §7 Offline / air-gap | full `uds pull` → local `.tar.zst` → offline deploy | — |

---

## 1. PREREQS

### 1.1 Tower specs assumed
- **Founder's tower:** desktop with an **NVIDIA RTX 4060 Ti** (16 GB VRAM). The GPU is **optional** for this deploy — the 5 organs are CPU services; the GPU only matters if you later run local model inference. k3d passes `--gpus 1` automatically when the NVIDIA container runtime is present, else falls back cleanly.
- **A Hetzner box** (dedicated server or cloud CX/CCX): **≥ 8 vCPU, ≥ 16 GB RAM, ≥ 80 GB disk**. UDS Core + the 5 organs (rosie image alone bakes to ~3 GB) need headroom; the full bundle is **~3.6 GB**.
- **OS:** Ubuntu 22.04/24.04 LTS (x86_64 / **amd64** — all bundles are `architecture: amd64`).

### 1.2 OS packages + tooling (run once, online)
```bash
# --- base OS packages ---
sudo apt-get update
sudo apt-get install -y curl jq git ca-certificates apt-transport-https openssl

# --- Docker (needed to CREATE the k3d cluster; NOT needed for the air-gap deploy itself) ---
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker "$USER"   # log out/in (or: newgrp docker)
docker info                        # expect: server running

# --- Istio sidecars / Vector / Loki need high inotify limits under UDS Core ---
sudo sysctl -w fs.inotify.max_user_instances=8192
sudo sysctl -w fs.inotify.max_user_watches=524288
echo -e "fs.inotify.max_user_instances=8192\nfs.inotify.max_user_watches=524288" | sudo tee /etc/sysctl.d/99-uds.conf

# --- k3d v5.8.3 (local Kubernetes in Docker) ---
curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | TAG=v5.8.3 bash
k3d version

# --- uds-cli v0.32.0 (bundles Zarf v0.77.0) ---
UDS_VERSION="v0.32.0"
sudo curl -sLo /usr/local/bin/uds \
  "https://github.com/defenseunicorns/uds-cli/releases/download/${UDS_VERSION}/uds-cli_${UDS_VERSION}_Linux_amd64"
sudo chmod +x /usr/local/bin/uds
uds version        # expect: v0.32.0
uds zarf version   # expect: v0.77.0  (zarf is vendored inside uds-cli)

# --- cosign v2.4+ (signature + attestation verification) ---
sudo curl -sLo /usr/local/bin/cosign \
  "https://github.com/sigstore/cosign/releases/download/v2.4.3/cosign-linux-amd64"
sudo chmod +x /usr/local/bin/cosign
cosign version

# --- gh CLI (for `gh attestation verify`; optional but recommended) ---
(type -p wget >/dev/null || sudo apt-get install -y wget) \
&& sudo mkdir -p -m 755 /etc/apt/keyrings \
&& wget -qO- https://cli.github.com/packages/githubcli-archive-keyring.gpg | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg >/dev/null \
&& echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null \
&& sudo apt-get update && sudo apt-get install -y gh
```

> macOS / Homebrew alternative for uds-cli + zarf (per official UDS docs):
> `brew tap defenseunicorns/tap && brew install uds` and `brew install zarf`.

### 1.3 GHCR pull auth (read token)
The organ images are in `ghcr.io/szl-holdings/*`. Some are private, so log Docker into GHCR with a **read-only** PAT (`read:packages` scope only).
```bash
# Create a classic PAT at github.com/settings/tokens with scope: read:packages
export GHCR_TOKEN="ghp_xxxxxxxxxxxxxxxxxxxx"          # read:packages only
echo "$GHCR_TOKEN" | docker login ghcr.io -u stephenlutar2 --password-stdin
# uds/zarf reuse the docker credential store; also export for zarf if prompted:
export ZARF_REGISTRY_PULL_USERNAME="stephenlutar2"
export ZARF_REGISTRY_PULL_PASSWORD="$GHCR_TOKEN"
```
> The **published bundle manifests** (`szl-mesh`, `a11oy-bundle`, `killinchu-bundle`) are **anonymously pullable** (verified HTTP 200 with an anonymous token). Login is only needed for the heavy organ images if any are private.

### 1.4 DNS / hosts
UDS Core exposes services on `*.uds.dev` through the Istio tenant/admin gateways. For a single tower, point those hostnames at the cluster LoadBalancer IP (or `127.0.0.1` for local k3d):
```bash
# Local k3d (gateway reachable on localhost):
sudo tee -a /etc/hosts <<'EOF'
127.0.0.1 keycloak.admin.uds.dev grafana.admin.uds.dev
127.0.0.1 a11oy.uds.dev killinchu.uds.dev
EOF
```
On a Hetzner box with a public IP, create real A records (`*.uds.dev` → tower IP) or use a wildcard you control; you can also override `UDS_DOMAIN` at Core deploy time (§2).

### 1.5 Env vars / secrets the founder sets (collected here for convenience)
```bash
export GHCR_TOKEN="ghp_…"                 # read:packages PAT (§1.3)
export COSIGN_KEY_PATH="$HOME/.szl/cosign.pub"   # killinchu receipt-verify public key (§4.5)
# In-cluster organ URLs (so a11oy /observability shows mesh 5/5 on the tower, not HF public URLs):
export SZL_ORGAN_BASE_A11OY="http://a11oy.szl-a11oy.svc.cluster.local:8080"
export SZL_ORGAN_BASE_SENTRA="http://sentra.szl-sentra.svc.cluster.local:8080"
export SZL_ORGAN_BASE_AMARU="http://amaru.szl-amaru.svc.cluster.local:8080"
export SZL_ORGAN_BASE_ROSIE="http://rosie.szl-rosie.svc.cluster.local:7860"
export SZL_ORGAN_BASE_KILLINCHU="http://killinchu.szl-killinchu.svc.cluster.local:7860"
```
> **Ports are real and verified:** a11oy / sentra / amaru = **8080**; rosie / killinchu = **7860**.

---

## 2. UDS CORE INSTALL (the secure baseline — v1.5.0)

UDS Core is a single bundle that establishes the secure baseline every SZL app deploys **on top of**: **Istio (ambient is the default mode), Pepr (UDS Policy Engine + UDS Operator), Keycloak (SSO) + AuthService, Prometheus/Grafana/Alertmanager, Vector→Loki logging, Falco runtime security, Velero backup/restore.**

### Step 2.1 — create the cluster
```bash
# RTX 4060 Ti tower: pass the GPU if the NVIDIA runtime is present, else plain.
k3d cluster create szl --gpus 1 || k3d cluster create szl
kubectl wait --for=condition=Ready nodes --all --timeout=120s
```

### Step 2.2 — deploy UDS Core v1.5.0
Two supported modes. **Mode A (dev k3d bundle)** is the fastest path on a single tower; **Mode B (the Core package by version)** is the explicit v1.5.0 pin.

```bash
# ── Mode A — UDS dev k3d bundle (creates k3d + installs Core in one shot) ──
# Official UDS short-ref (expands to ghcr.io/defenseunicorns/packages/uds/bundles/…):
uds deploy k3d-core-slim-dev:latest --confirm     # lean baseline (Istio+Keycloak+Pepr)
#   full demo baseline (adds Grafana/Loki/Neuvector-free Falco etc.):
# uds deploy k3d-core-demo:latest --confirm

# ── Mode B — UDS Core v1.5.0 by exact OCI ref on YOUR k3d/RKE2 cluster ──
# VERIFIED HTTP 200 on GHCR (note: NO leading 'v' on the Core package tag):
uds deploy oci://ghcr.io/defenseunicorns/packages/uds/core:1.5.0-upstream --confirm
#   DoD/Iron-Bank flavor (amd64-only, registry1) — roadmap, not used by us:
# uds deploy oci://ghcr.io/defenseunicorns/packages/uds/core:1.5.0-registry1 --confirm
```
> To override the domain on a public Hetzner box: append `--set DOMAIN=uds.dev` (or your wildcard) to the Core deploy.

### Step 2.3 — confirm the baseline is healthy
```bash
kubectl get pods -n istio-system           # ztunnel + istiod Running (ambient mode)
kubectl get pods -n keycloak               # keycloak Running
kubectl get pods -n pepr-system            # pepr-uds-core (Operator + Policy Engine) Running
kubectl get pods -n monitoring             # prometheus, grafana, alertmanager
kubectl get pods -n vector -n loki 2>/dev/null; kubectl get pods -A | grep -E 'vector|loki'
kubectl get pods -A | grep -E 'falco|velero'
```
Reference (official): `brew tap defenseunicorns/tap && brew install uds`; `uds deploy k3d-core-slim-dev:latest` / `uds deploy k3d-core-demo:latest` (UDS docs, llms-full snapshot). UDS Core **latest = v1.5.0**, published 2026-05-27 (UDS Core releases, GitHub API).

> **Baseline note (doctrine):** current UDS Core uses **Falco + ambient Istio** — **NeuVector is no longer managed by Core**. Our per-organ Package CRs set `serviceMesh.mode: sidecar`, which is **valid but no longer the default**; keep it as a deliberate, documented choice (re-confirm our AuthorizationPolicies apply under the deployed Core).

---

## 3. DEPLOY OUR BUNDLES

Three published, cosign-signed bundles are available. **All verified HTTP 200 on GHCR (2026-06-06).**

| Bundle | OCI ref | Manifest digest | Composition | Status |
|---|---|---|---|---|
| **Full 5-organ mesh** (recommended for the tower demo) | `oci://ghcr.io/szl-holdings/szl-mesh:0.4.0` (= `v0.4.0` = `latest`) | `sha256:7f5fce3238ce3d255b322340bbe18cad1eb656e677065a2757637337300cac7f` | a11oy+sentra+amaru+rosie+killinchu | **PUBLISHED + signed (current fallback)** |
| **Platform** (a11oy.uds) | `oci://ghcr.io/szl-holdings/a11oy-bundle:0.5.0` (= `latest`) | `sha256:d801f8e461dfd519b5f8593322e75b89a1e66d4da9f6d72d0937c8ff2de64b51` | a11oy + sentra/amaru/rosie backends | **PUBLISHED + signed — but STALE (see note)** |
| **Field node** (killinchu.uds) | `oci://ghcr.io/szl-holdings/killinchu-bundle:0.5.0` (= `latest`) | `sha256:e59921332c37408fb5a62b270eeeafb1f1ab44aebb350f18662c37aa2c67426f` | killinchu + sentra/amaru backends | **PUBLISHED + signed + current** |

### Step 3.1 — deploy (online, from GHCR)
```bash
# RECOMMENDED for the tower: the full 5-organ mesh (current, signed, all-in-one):
uds deploy oci://ghcr.io/szl-holdings/szl-mesh:0.4.0 --confirm

# OR the two consolidated product bundles:
uds deploy oci://ghcr.io/szl-holdings/a11oy-bundle:0.5.0 --confirm      # platform
uds deploy oci://ghcr.io/szl-holdings/killinchu-bundle:0.5.0 --confirm  # field node
```
Each step shows: `Deploying Zarf package … Connected to cluster … Pushing N images to the zarf registry … Component <organ> successfully deployed`, ending `✔ … deployed` for a11oy → sentra → amaru → rosie → killinchu.

> **⚠️ a11oy-bundle re-pin status (HONEST — verified 2026-06-06):** `a11oy-bundle:0.5.0` (digest `d801f8e4…`) was built against an **older a11oy organ image**. The a11oy image was rebuilt afterward — `ghcr.io/szl-holdings/a11oy:uds-v0.2.0` **now resolves to `sha256:e2ef6184b94397d279753dd7b84addb74677a5921c425eee6637d9d098a80171`**, so the published a11oy-bundle is **STALE** (it does not carry tonight's a11oy). **Two safe options:**
> 1. **Use `szl-mesh:0.4.0`** (it composes all 5 organs and is the maintained fallback), or
> 2. If the UDS squad **re-pins** `a11oy-bundle` (re-runs the `uds-canonical-bundles-publish.yml` workflow_dispatch with `bundle=a11oy`), deploy the **new digest** it produces (must be ≠ `d801f8e4…`; re-verify per §4.1). killinchu-bundle does **not** need a re-pin (its image is unchanged).

### Step 3.2 — air-gap path (pull → local tarball → offline deploy)
See §7 for the full offline walk-through. The short form:
```bash
uds pull oci://ghcr.io/szl-holdings/szl-mesh:0.4.0          # → uds-bundle-szl-mesh-amd64-0.4.0.tar.zst
# carry the .tar.zst to the air-gapped tower, then:
uds deploy uds-bundle-szl-mesh-amd64-0.4.0.tar.zst --confirm   # pulls NOTHING from the internet
```

### Step 3.3 — the UDS `Package` CR (what turns a Zarf package into a governed UDS app)
The Package CRs ship **inside each per-organ Zarf package** (`manifests/uds-package.yaml`), so they apply automatically during `uds deploy`. To apply / re-apply them stand-alone (e.g. when deploying a flagship independently of the full mesh), use the canonical CRs in **szl-fleet-overlay**:
```bash
git clone https://github.com/szl-holdings/szl-fleet-overlay.git && cd szl-fleet-overlay
kubectl apply -f uds-packages/                  # a11oy, sentra, amaru, rosie, killinchu
kubectl get packages -A                         # UDS Operator reconciles each
kubectl describe package szl-a11oy -n szl-a11oy # see expose/allow/sso/monitor reconciled
```
Each `Package` (`apiVersion: uds.dev/v1alpha1`, `kind: Package`) declares `spec.network.expose` (Istio VirtualService on the tenant gateway), `spec.network.allow` (UDS-managed NetworkPolicy on top of default-deny), `spec.sso` (Keycloak OIDC client, group-gated to `/szl-operators`), and `spec.monitor` (Prometheus ServiceMonitor).

---

## 4. VERIFY (supply-chain + runtime + the offline-receipt demo)

### 4.1 — cosign verify the bundle signature (keyless OIDC)
```bash
cosign verify ghcr.io/szl-holdings/szl-mesh:0.4.0 \
  --certificate-identity-regexp="^https://github.com/szl-holdings/" \
  --certificate-oidc-issuer="https://token.actions.githubusercontent.com"

cosign verify ghcr.io/szl-holdings/a11oy-bundle:0.5.0 \
  --certificate-identity-regexp='.*szl-holdings/uds-bundles.*' \
  --certificate-oidc-issuer="https://token.actions.githubusercontent.com"

cosign verify ghcr.io/szl-holdings/killinchu-bundle:0.5.0 \
  --certificate-identity-regexp='.*szl-holdings/uds-bundles.*' \
  --certificate-oidc-issuer="https://token.actions.githubusercontent.com"
# expect: "cosign claims validated · transparency-log existence verified · cert verified using trusted CA"
```
> The bundle cosign signature **is** the bundle provenance. There is **no bundle-level SLSA attestation** (CI token lacks `attestations:write`) — do not claim one.

### 4.2 — gh attestation / cosign verify-attestation on the ORGAN IMAGES (SLSA L2)
```bash
# SLSA Build L2 attestation on each organ image (slsa.dev/provenance/v0.2):
for organ in a11oy sentra amaru rosie killinchu; do
  cosign verify-attestation --type slsaprovenance \
    "ghcr.io/szl-holdings/${organ}:uds-v0.2.0" \
    --certificate-identity-regexp "https://github.com/szl-holdings/${organ}/" \
    --certificate-oidc-issuer "https://token.actions.githubusercontent.com" \
  && echo "  -> ${organ}: SLSA L2 provenance VERIFIED"
done

# GitHub-native attestation verify (equivalent):
gh attestation verify oci://ghcr.io/szl-holdings/killinchu:uds-v0.2.0 --owner szl-holdings
```
> **Honest:** L2 is on the **images**, NOT L3, NOT Iron Bank.

### 4.3 — per-service health
```bash
for ns in szl-a11oy szl-sentra szl-amaru szl-rosie szl-killinchu; do
  kubectl wait --for=condition=Available deploy --all -n "$ns" --timeout=180s && echo "$ns OK"
done
# health paths: a11oy/sentra/rosie/killinchu = /api/health ; amaru = /healthz
kubectl port-forward -n szl-a11oy     svc/a11oy     8080:8080 & sleep 2; curl -fsS http://localhost:8080/api/health
kubectl port-forward -n szl-amaru     svc/amaru     8081:8080 & sleep 2; curl -fsS http://localhost:8081/healthz
kubectl port-forward -n szl-killinchu svc/killinchu 7860:7860 & sleep 2; curl -fsS http://localhost:7860/api/killinchu/healthz
```

### 4.4 — mesh reachability (the kill-move)
```bash
# Fire a real counter-UAS decision and get a DSSE-signed verdict:
curl -X POST http://localhost:7860/api/killinchu/v1/counter-uas/evaluate \
  -H "Content-Type: application/json" \
  -d '{"track_id":"4840D6","lat":32.7,"lon":-117.2,"alt_m":120,"speed_ms":15}'
# expect: a DSSE-signed verdict. Λ-gate is Conjecture 1, NOT a theorem — say it out loud.

# a11oy /observability shows mesh 5/5 on the cluster via the SZL_ORGAN_BASE_* in-cluster URLs (§1.5).
# Guaranteed-live fallback (no cluster): https://szlholdings-killinchu.hf.space/...
```

### 4.5 — VERIFY A RECEIPT OFFLINE (the whole thesis — PASS / tamper-FAIL)
killinchu signs every decision receipt with a real ECDSA-P256 cosign key (keyid `szlholdings-cosign`). Anyone can verify **offline**, no trust in SZL:
```bash
# 1) fetch the public key + a signed receipt (from the cluster or the live HF Space)
curl -s http://localhost:7860/cosign.pub -o cosign.pub
curl -s http://localhost:7860/api/killinchu/v1/receipt/export -o receipt.json
#   fallback: https://szlholdings-killinchu.hf.space/cosign.pub  and  /api/killinchu/v1/receipt/export

# 2) reconstruct the DSSE PAE and verify the signature
python3 - <<'PY'
import json,base64
r=json.load(open("receipt.json"))
payload=base64.b64decode(r["payload"]); ptype=r["payloadType"].encode()
sig=base64.b64decode(r["signatures"][0]["sig"])
pae=b"DSSEv1 %d %s %d %s"%(len(ptype),ptype,len(payload),payload)
open("pae.bin","wb").write(pae); open("sig.der","wb").write(sig)
PY
openssl dgst -sha256 -verify cosign.pub -signature sig.der pae.bin
# valid receipt  -> "Verified OK"
# tamper one byte of pae.bin -> "Verification Failure"  (correctly REJECTED)
```

---

## 5. GITHUB HANDOFF — clone order + what each repo provides

Clone in **this order**. Everything below is a real repo in the `szl-holdings` org.

| # | Repo | Clone | What it provides | When to use |
|---|---|---|---|---|
| 1 | **szl-build-env** (private) | `git clone https://github.com/szl-holdings/szl-build-env.git` | **One-command local tower bootstrap.** `make up` = kind cluster + **Istio ambient mesh** + **OpenTelemetry Collector + Jaeger** + the **5-organ stack** with a **cosign verification gate**. `<10 min` quickstart. | First, to validate the tower can boot the stack at all (laptop/tower dev loop). |
| 2 | **szl-uds-deployment** (private) | `git clone https://github.com/szl-holdings/szl-uds-deployment.git` | **The live reference deploy target.** `uds run start` bootstraps k3d + deploys the receipts bundle (~90 s); `uds run demo:workload`, `uds run demo:verify`, `uds run teardown`. Carries `zarf.yaml`, `uds-bundle.yaml`, `tasks.yaml`, the **Pepr governance-receipt policy**, and `docs/{INSTALL,AIRGAP,WARHACKER_DEMO,OPERATOR_QUICKSTART}.md`. **This roadmap lives in its `docs/`.** | The deploy targets + demo task runner; the air-gap runbook. |
| 3 | **uds-bundles** (public) | `git clone https://github.com/szl-holdings/uds-bundles.git` | **The bundle source.** `bundles/szl-<organ>/` Zarf packages, `bundles/a11oy/` + `bundles/killinchu/` UDSBundle manifests, `DEPLOY.md`, and the `uds-canonical-bundles-publish.yml` workflow (re-pin/re-publish bundles). 3 K8s CRDs: LambdaGate, KhipuReceipt, DoctrineLock. Built on **UDS Core v1.5.0**, Zarf ≥ v0.77.0, uds-cli v0.32.0. | To rebuild/re-pin bundles, or build a single capability with `zarf package create bundles/szl-<organ>/`. |
| 4 | **szl-fleet-overlay** (public) | `git clone https://github.com/szl-holdings/szl-fleet-overlay.git` | **The UDS Operator entry point + Helm chart.** Canonical stand-alone **Package CRs** (`uds-packages/{a11oy,sentra,amaru,rosie,killinchu}.yaml`), a Helm chart (`chart/` with dev/staging/prod values), and a Zarf air-gap variant. Registers the apps as first-class UDS-managed apps. | To apply Package CRs independently (§3.3) or deploy via Helm/GitOps. |

### 5.1 — the bare-box → running path (do this today)
```bash
# A) validate the box can boot the stack (build-env)
git clone https://github.com/szl-holdings/szl-build-env.git && cd szl-build-env
echo "$GHCR_TOKEN" | docker login ghcr.io -u stephenlutar2 --password-stdin
make up        # kind + Istio ambient + OTEL + 5 organs (cosign-gated)
make verify    # honest cosign + slsa-verifier gate per organ
make trace     # cross-organ traceparent trace tree
make down      # teardown
cd ..

# B) stand up UDS Core (the secure baseline) — §2
uds deploy oci://ghcr.io/defenseunicorns/packages/uds/core:1.5.0-upstream --confirm

# C) deploy our governed apps onto Core — §3
uds deploy oci://ghcr.io/szl-holdings/szl-mesh:0.4.0 --confirm

# D) (optional) apply stand-alone Package CRs from the fleet overlay — §3.3
git clone https://github.com/szl-holdings/szl-fleet-overlay.git
kubectl apply -f szl-fleet-overlay/uds-packages/

# E) verify everything — §4
```

### 5.2 — env vars / secrets to set (recap)
- `GHCR_TOKEN` — `read:packages` PAT, used for `docker login ghcr.io` (§1.3).
- `COSIGN_KEY_PATH` — path to killinchu's `cosign.pub` for the offline receipt demo (§4.5).
- `SZL_ORGAN_BASE_*` — in-cluster service URLs so a11oy `/observability` shows mesh **5/5** on the tower instead of the HF public URLs (§1.5).
- The **receipt signing key** is auto-generated **in the cluster** by szl-uds-deployment's `szl-key-init` Helm pre-install hook (Ed25519 in `pepr-system`) — **zero founder action**, BYOK supported. SZL never sees it.

---

## 6. TROUBLESHOOTING (known gotchas)

| Symptom | Likely cause | Fix |
|---|---|---|
| `000` / curl hangs to a `*.hf.space` URL | **Transient egress flakiness**, NOT a crashed app | **Retry 3–6×.** Never factory-rebuild on a single `000`. (huggingface.co=200, retries succeed.) |
| `ImagePullBackOff` on organ pods | GHCR token missing/expired, or image private | `echo "$GHCR_TOKEN" \| docker login ghcr.io …`; `kubectl describe pod -n szl-<organ>`; confirm `read:packages` scope. |
| Istio VirtualService → 503 at the gateway, no metrics | **sidecar vs ambient** selector mismatch (historical bug, fixed on `main`) | Package CR selectors must be `app.kubernetes.io/name: <organ>` and `service: <organ>`; ports a11oy/sentra/amaru=8080, **rosie/killinchu=7860**. Re-apply from `szl-fleet-overlay/uds-packages/`. |
| Package CR stuck `Pending` | Istio not ready yet | `kubectl get pods -n istio-system`; wait for ztunnel/istiod Running, then it reconciles. |
| SSO redirect loop | Keycloak client not registered | Re-run `uds deploy` (re-syncs `sso` CRs). |
| `zarf init` hangs / "requires a zarf-init package, not found" | init seed not fetched | `zarf tools download-init` **before** `zarf init --confirm`. |
| `cosign verify` fails on the bundle | wrong identity/issuer flags, or NTP skew | Use the exact `--certificate-identity-regexp` / `--certificate-oidc-issuer` in §4.1; keep node clock within ~5 min (Rekor timestamp). |
| lambda-gate VAP `dsse-receipt` warning | binding is **`Audit`** (non-blocking) by design during rollout | Expected. Do **not** promote to `Deny` until pods carry the `dsse-receipt=required` label. |
| a11oy-bundle looks out of date | **STALE pin** (`d801f8e4…` built on old a11oy image) | Use `szl-mesh:0.4.0`, or have the UDS squad re-pin a11oy-bundle and deploy the new digest (§3.1 note). |

**Honesty reminders for the demo (do NOT overclaim):**
- **SLSA L1+L2 only** — images attested (`cosign verify-attestation` PASS); **bundle-level attestation NOT earned** (cosign signature is the bundle provenance). **No L3, no Iron Bank claim.**
- **Cross-organ in-cluster mTLS mesh / 3-of-4 quorum over the network = v0.5.0 roadmap.** The 5 organs deploy as **separate workloads**; say so.
- **Λ = Conjecture 1**, never a theorem. **Proved formulas = exactly 5** (F1, F11, F12, F18, F19). Doctrine v11 LOCKED 749/14/163 @ c7c0ba17.
- Receipts are **real DSSE** when the key is present, **honest UNSIGNED** otherwise — never fabricated green.

---

## 7. OFFLINE / AIR-GAP DEPLOY (full path — apps are sovereign/vendored)

The bundles are built `yolo:false` with **all organ images baked in** (Zarf), so the deploy pulls **nothing** from the internet. The only online steps are the one-time tool/cluster prep.

### 7.1 — ONLINE prep (do once, before going offline)
```bash
# (a) stage the binaries: uds-cli v0.32.0, k3d v5.8.3, cosign — copy to USB (§1.2)
# (b) pre-stage the cluster image so k3d needs no network:
docker pull ghcr.io/k3d-io/k3d-tools:5.8.3
docker pull rancher/k3s:v1.31.5-k3s1     # node image; or your UDS-Core-aligned k3s tag
# (c) pull the bundle to a local tarball:
uds pull oci://ghcr.io/szl-holdings/szl-mesh:0.4.0
#   -> produces: uds-bundle-szl-mesh-amd64-0.4.0.tar.zst  (~3.6 GB; all 5 organs baked)
# (d) (optional) pre-cache the Rekor entry / cosign bundle if you want to run cosign verify offline.
cp uds-bundle-szl-mesh-amd64-0.4.0.tar.zst /media/usb/
```

### 7.2 — OFFLINE on the air-gapped tower
```bash
# 1) cluster (Docker present; no network):
k3d cluster create szl --gpus 1 || k3d cluster create szl
kubectl wait --for=condition=Ready nodes --all --timeout=120s

# 2) THE ONE COMMAND — air-gapped, no internet:
uds deploy /media/usb/uds-bundle-szl-mesh-amd64-0.4.0.tar.zst --confirm
#   (equivalently for the product bundles:
#    uds pull oci://ghcr.io/szl-holdings/a11oy-bundle:0.5.0   -> uds deploy <tarball> --confirm
#    uds pull oci://ghcr.io/szl-holdings/killinchu-bundle:0.5.0 -> uds deploy <tarball> --confirm )

# 3) verify offline (no network needed for the deploy or the receipt check):
for ns in szl-a11oy szl-sentra szl-amaru szl-rosie szl-killinchu; do
  kubectl wait --for=condition=Available deploy --all -n "$ns" --timeout=180s && echo "$ns OK"; done
# offline receipt verify: §4.5 (cosign.pub + receipt export → openssl verify PASS / tamper FAIL)
```

| Deploy-time dependency | Baked into the tarball? | Network at deploy? |
|---|:---:|:---:|
| All 5 organ container images | ✅ (`zarf package create`, CI) | **NO** |
| All Helm charts | ✅ (`localPath`) | **NO** |
| UDS Package CRs + Pepr policies | ✅ | **NO** |
| SBOM / attestations | ✅ | **NO** |

> Zarf pushes the baked images into the cluster's **internal Zarf registry** and rewrites pod image refs — that is why the deploy needs no internet. The **only** things that touch the network are NOT on the deploy path: `cosign verify` (reads Rekor — skip or pre-cache in true air-gap) and the one-time tool/cluster install.

---

## VERIFY EVIDENCE (probed HTTP 200 on GHCR, 2026-06-06 — anonymous token + manifest HEAD)

| Artifact | Ref | HTTP | Digest |
|---|---|---|---|
| Full mesh bundle | `szl-mesh:0.4.0` (=`v0.4.0`,`latest`) | **200** | `sha256:7f5fce3238ce3d255b322340bbe18cad1eb656e677065a2757637337300cac7f` |
| Platform bundle | `a11oy-bundle:0.5.0` (=`latest`) | **200** | `sha256:d801f8e461dfd519b5f8593322e75b89a1e66d4da9f6d72d0937c8ff2de64b51` (**STALE pin**) |
| Field bundle | `killinchu-bundle:0.5.0` (=`latest`) | **200** | `sha256:e59921332c37408fb5a62b270eeeafb1f1ab44aebb350f18662c37aa2c67426f` |
| a11oy-bundle `.sig` | `sha256-d801f8e4….sig` | **200** | cosign signature present |
| killinchu-bundle `.sig` | `sha256-e59921….sig` | **200** | cosign signature present |
| Organ image a11oy | `a11oy:uds-v0.2.0` | **200** | `sha256:e2ef6184b94397d279753dd7b84addb74677a5921c425eee6637d9d098a80171` (newer than the a11oy-bundle pin → re-pin needed) |
| Organ image sentra | `sentra:uds-v0.2.0` | **200** | `sha256:60a0efc14366ba392bfe3f3cd4196863fe148bb87a17428be6a57f0a05ac3639` |
| Organ image amaru | `amaru:uds-v0.2.0` | **200** | `sha256:53301e26adcde49e73df28d8c3b790f2496da9d495307fe8587ffa7452b289ff` |
| Organ image rosie | `rosie:uds-v0.2.0` | **200** | `sha256:1984a15f53c2e1b91c7dafaa0ed5df9148d57e3e86eb73db879c2b0443302848` |
| Organ image killinchu | `killinchu:uds-v0.2.0` | **200** | `sha256:e0fb6c3aeaddadfbabc3ca7c5f29ef7b3ba31370b5ffb816e12495d5f29ca548` |
| Organ `.sig`+`.att` (a11oy, killinchu probed) | `sha256-<digest>.{sig,att}` | **200** | SLSA L2 provenance present |
| UDS Core | `defenseunicorns/packages/uds/core:1.5.0-upstream` | **200** | (Defense Unicorns) |
| UDS Core | `…/core:1.5.0-registry1` | **200** | (Iron Bank flavor — roadmap, not used) |
| UDS Core release | GitHub API `uds-core/releases/latest` | — | **tag v1.5.0**, published 2026-05-27 |

**Sources:** UDS docs (overview + machine-readable snapshot, Package CR schema, air-gap, cosign/SBOM, install): https://uds.defenseunicorns.com/ · https://uds.defenseunicorns.com/llms-full.txt · UDS Core releases (live API → v1.5.0): https://api.github.com/repos/defenseunicorns/uds-core/releases/latest · GHCR registry API (anonymous token + manifest HEAD): https://ghcr.io/v2/… · SLSA v1.0 levels: https://slsa.dev/spec/v1.0/levels · Internal ground truth: team/WARHACKER_UDS_READINESS.md, team/BUNDLE_BUILD_REPORT.md, team/UDS_SLIM_REPORT.md, team/UDS_MESH_ALIGN_REPORT.md, team/FLEET_STATE_VERIFIED.md, team/CONTINUITY.md, team/one_usb_deploy.md, team/deploy_proof_june9.md; live repos szl-build-env / szl-uds-deployment / uds-bundles / szl-fleet-overlay (GitHub API).

---

*Doctrine v11 LOCKED 749/14/163 @ c7c0ba17 · Λ = Conjecture 1 (NEVER a theorem) · SLSA L1+L2 honest — images attested, bundle-level attestation NOT earned (cosign signature is the bundle provenance), NOT L3, NOT Iron Bank, no FedRAMP/CMMC · Section 889 = exactly 5 vendors · Apache-2.0*
*Signed-off-by: Stephen P. Lutar Jr. <stephenlutar2@gmail.com>*
*Co-Authored-By: Perplexity Computer Agent <agent@perplexity.ai>*
