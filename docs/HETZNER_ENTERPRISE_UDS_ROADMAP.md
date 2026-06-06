# HETZNER ENTERPRISE BUILD ROADMAP — UDS + Zarf, End-to-End

**SZL Holdings · Execute Today**

> Copyright 2026 SZL Holdings · SPDX-License-Identifier: Apache-2.0 · Doctrine v11 LOCKED 749/14/163 @ c7c0ba17 · Λ = Conjecture 1 (NEVER a theorem) · SLSA L1 honest / L2 on organ images — bundle-level attestation NOT earned (cosign signature is the bundle provenance) · NOT L3 · NOT Iron Bank · No FedRAMP/CMMC · Section 889 = exactly 5 vendors (Huawei, ZTE, Hytera, Hikvision, Dahua) · Signed-off-by: Stephen P. Lutar Jr. <stephenlutar2@gmail.com>

**For:** Stephen P. Lutar Jr. (Founder/CEO), SZL Holdings
**Goal:** go from **nothing** → **a Hetzner-hosted, governed UDS environment running a11oy + killinchu on UDS Core**, by copy-paste, with an air-gap variant and a GitHub-handoff path.
**Status of facts in this doc:** every OCI digest below was re-probed **HTTP 200 on GHCR on 2026-06-06** (anonymous token + manifest HEAD). The three SZL bundle digests are pinned and real. Anything that must be re-checked at deploy time is labelled **`verify before deploy`**. No fabricated IPs, tokens, or digests.

> **Honesty doctrine (kept throughout — this is the credibility):** SLSA **Build L2 on the 5 organ images** (cosign `.sig` + `.att` = `slsa.dev/provenance/v0.2`). **Bundle-level SLSA attestation is NOT earned** (CI `GITHUB_TOKEN` lacks `attestations:write`) — the cosign **signature** is the bundle's provenance. **NOT L3, NOT Iron Bank, no FedRAMP/CMMC.** Λ = **Conjecture 1**, never a theorem. Cross-organ in-cluster mTLS mesh wiring is reconciled by the UDS Operator from the Package CRs; the organs still deploy as **separate workloads**. Say all of this out loud.

---

## ⚡ FASTEST 30-MINUTE HAPPY PATH (TL;DR — start here)

This is the **recommended easiest/best path**. Opinionated on purpose.

```bash
# 0) PROVISION — one Hetzner CCX cloud server (8 vCPU / 32 GB / Ubuntu 24.04). ~3 min.
hcloud server create --name szl-uds --type ccx33 --image ubuntu-24.04 \
  --location nbg1 --ssh-key szl-laptop

# SSH in, then:
ssh root@<SERVER_IP>          # IP from: hcloud server ip szl-uds

# 1) TOOLING + cluster prereqs (~8 min)
apt-get update && apt-get install -y curl jq git ca-certificates openssl
sysctl -w fs.inotify.max_user_instances=8192 && sysctl -w fs.inotify.max_user_watches=524288

# 2) k3s single node — the easiest viable Kubernetes (~2 min)
curl -sfL https://get.k3s.io | sh -s - --write-kubeconfig-mode 644 --disable traefik
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
kubectl wait --for=condition=Ready nodes --all --timeout=120s

# 3) uds-cli (vendors Zarf) (~1 min)
UDS_VERSION="v0.32.0"
curl -sLo /usr/local/bin/uds "https://github.com/defenseunicorns/uds-cli/releases/download/${UDS_VERSION}/uds-cli_${UDS_VERSION}_Linux_amd64"
chmod +x /usr/local/bin/uds
uds version && uds zarf version       # uds v0.32.0 · zarf v0.77.0 (vendored)

# 4) UDS Core — the secure baseline (Istio+Keycloak+Pepr+Prometheus/Grafana...) (~10 min)
uds deploy oci://ghcr.io/defenseunicorns/packages/uds/core:1.5.0-upstream --confirm   # verify before deploy

# 5) OUR governed stack — the full 5-organ mesh (current, signed, all-in-one) (~6 min)
uds deploy oci://ghcr.io/szl-holdings/szl-mesh:0.4.0 --confirm
#   digest sha256:7f5fce3238ce3d255b322340bbe18cad1eb656e677065a2757637337300cac7f  (verified 200)

# 6) VERIFY
kubectl get packages -A
for ns in szl-a11oy szl-sentra szl-amaru szl-rosie szl-killinchu; do
  kubectl wait --for=condition=Available deploy --all -n "$ns" --timeout=180s && echo "$ns OK"; done
```

**Why this path:** k3s single-node is the lowest-friction conformant Kubernetes; UDS Core installs cleanly on it; `szl-mesh:0.4.0` is the **maintained, signed, all-5-organs fallback** (the standalone `a11oy-bundle:0.5.0` is published+signed but **STALE** — see §4). Air-gap, GPU, SSO/TLS, and multi-node are all add-ons to this same spine (§6–§9).

---

## QUICK MAP

| Phase | What | Section | Time |
|---|---|---|---|
| Topology decision | single CCX node k3s vs cluster (+ where the GPU lives) | §1 | read |
| Hetzner provision | account, server type, network, firewall, OS, SSH, cloud-init | §2 | ~10 min |
| Base platform | k3s, storage, ingress, cert-manager | §3 | ~10 min |
| UDS | what UDS is, uds-cli, `uds deploy` Core, our bundles, Package CR, bundle composition | §4 | ~15 min |
| Zarf | what Zarf is, `zarf init`, zarf.yaml schema, create/deploy, air-gap mirroring, find-images | §5 | reference |
| Full runbook | provision → k3s → core → mesh → a11oy/killinchu (+ air-gap variant) | §6 | ~30 min |
| GPU | NVIDIA on k3s for model workloads | §7 | ~10 min |
| Day-2 | backups, upgrades+re-pin, monitoring, secrets, SSO, TLS | §8 | ongoing |
| GitHub easy-pass | clone order, repos, publish workflows | §9 | — |
| Checklist + troubleshooting | the gotchas | §10 | — |

---

## 1. EXECUTIVE SUMMARY + RECOMMENDED EASIEST/BEST PATH

**The decision in one line:** Start on **one Hetzner CCX dedicated-vCPU cloud server (`ccx33`: 8 vCPU / 32 GB / 240 GB NVMe), Ubuntu 24.04, single-node k3s**. Do **not** start with a multi-node cluster, and do **not** rent a GPU server yet.

**Why single-node k3s on one CCX box (not a cluster, not a GPU server):**
- **UDS Core + the 5 organs need headroom.** The full `szl-mesh` bundle is ~3.6 GB of images (rosie alone bakes ~2.9 GB), and UDS Core runs Istio (ambient), Keycloak, Pepr, Prometheus/Grafana, Vector→Loki, Falco, Velero. A single `ccx33` clears the **≥8 vCPU / ≥16 GB / ≥80 GB** floor with margin; `ccx43` (16 vCPU / 64 GB) is the comfortable upgrade.
- **CCX (dedicated vCPU) over shared CX** so Istio/Keycloak/Prometheus aren't throttled by noisy neighbours. CCX is the [Hetzner dedicated-vCPU line](https://www.hetzner.com/cloud/general-purpose) (`ccx13/23/33/43/...`).
- **k3s single-node is the easiest conformant Kubernetes.** One `curl | sh`, no etcd quorum to manage, full UDS Core compatibility. You can promote it to an HA cluster later by adding server/agent nodes on a Hetzner **private network** — the UDS layer above doesn't change.
- **The GPU lives on your tower, not Hetzner (for now).** Hetzner's **cloud** servers have **no GPU**; GPUs are only on [Hetzner dedicated GPU root servers](https://www.hetzner.com/dedicated-rootserver/matrix-gpu/) (RTX 4000/5000-class, monthly, with setup) — overkill to start. The 5 organs are **CPU services**; the GPU only matters for **local model inference** (some a11oy /code + rosie capabilities). **Best path:** run the governed control plane on the Hetzner CCX box, and attach your **RTX 4060 Ti tower as a GPU worker node** (join it to the k3s cluster over WireGuard/Tailscale) only when you actually need GPU inference (§7). This is cheaper and keeps the GPU where it already is.

**Topology summary (recommended → future):**

| Stage | Topology | Use when |
|---|---|---|
| **Now (recommended)** | 1× Hetzner `ccx33` CCX, single-node k3s, UDS Core + `szl-mesh:0.4.0` | stand up + demo + iterate today |
| Add GPU | + RTX 4060 Ti tower joined as a k3s **agent (GPU) node** over a private overlay | local model inference for a11oy/rosie |
| Scale out | 3× CCX server nodes (HA k3s embedded etcd) + N agents, Hetzner private network + LB | production HA |
| Air-gap | one CCX (or on-prem) node, `uds pull` → USB `.tar.zst` → offline `uds deploy` | sovereign / disconnected (§6.2) |

**What you get at the end of §6:** UDS Core healthy; a11oy (governance/command platform, port 8080), sentra (security gate, 8080), amaru (reasoning/memory, 8080), rosie (operator console, 7860), killinchu (counter-UAS field node, 7860) running as UDS-governed Packages — each with Istio routing, default-deny + explicit NetworkPolicies, Keycloak SSO, and Prometheus monitors, reconciled by the UDS Operator.

---

## 2. HETZNER SETUP

### 2.1 Account / project / API token
1. Create a [Hetzner Cloud](https://www.hetzner.com/cloud) account → **new Project** (e.g. `szl-prod`).
2. In the project: **Security → API Tokens → Generate** (Read & Write). Copy it — shown once.
3. Install the `hcloud` CLI on your laptop and authenticate:
```bash
# macOS: brew install hcloud   |   Linux: download from github.com/hetznercloud/cli/releases
export HCLOUD_TOKEN="<your-hetzner-api-token>"        # verify before deploy (do not commit)
hcloud context create szl                              # paste token when prompted (stores it)
hcloud server-type list | grep -E 'ccx|cx'             # see available types/prices
```

### 2.2 Recommended server type(s)
| Need | Type | Specs | Notes |
|---|---|---|---|
| **Recommended start** | `ccx33` | 8 dedicated vCPU / 32 GB / 240 GB NVMe | clears UDS Core + 5 organs with margin |
| Comfortable | `ccx43` | 16 vCPU / 64 GB / 360 GB | room for GPU-less model serving + headroom |
| Budget floor | `ccx23` | 4 vCPU / 16 GB | meets minimum; tight with full mesh |
| GPU (later, optional) | Hetzner **dedicated GPU root server** | RTX 4000/5000-class | order via [GPU matrix](https://www.hetzner.com/dedicated-rootserver/matrix-gpu/); monthly + setup. Prefer your own tower first. |

> Cloud servers have **no GPU**. For GPU you either use your **tower** (recommended, §7) or rent a **dedicated** GPU root server.

### 2.3 SSH key, private network, firewall, floating IP (hcloud CLI — real commands)
```bash
# --- SSH key (upload your laptop's public key) ---
hcloud ssh-key create --name szl-laptop --public-key-from-file ~/.ssh/id_ed25519.pub

# --- private network (for future HA / GPU worker join; 10.0.0.0/16) ---
hcloud network create --name szl-net --ip-range 10.0.0.0/16
hcloud network add-subnet szl-net --network-zone eu-central --type cloud --ip-range 10.0.1.0/24

# --- firewall: allow SSH (lock to your IP!), HTTP/HTTPS; deny the rest by default ---
hcloud firewall create --name szl-fw
hcloud firewall add-rule szl-fw --direction in --protocol tcp --port 22  --source-ips <YOUR_IP>/32   # verify before deploy
hcloud firewall add-rule szl-fw --direction in --protocol tcp --port 80  --source-ips 0.0.0.0/0 --source-ips ::/0
hcloud firewall add-rule szl-fw --direction in --protocol tcp --port 443 --source-ips 0.0.0.0/0 --source-ips ::/0
# k3s API (6443) and the k3s node-join port (only from the private net, if you scale out):
hcloud firewall add-rule szl-fw --direction in --protocol tcp --port 6443 --source-ips 10.0.0.0/16

# --- create the server (attach key + net + firewall + cloud-init) ---
hcloud server create --name szl-uds --type ccx33 --image ubuntu-24.04 \
  --location nbg1 --ssh-key szl-laptop --network szl-net \
  --firewall szl-fw --user-data-from-file cloud-init.yaml

hcloud server ip szl-uds                      # → public IPv4 you SSH to

# --- (optional) floating IP so the public IP survives server rebuilds ---
hcloud floating-ip create --type ipv4 --home-location nbg1 --name szl-fip
hcloud floating-ip assign szl-fip szl-uds
# then add it on the server NIC (Hetzner shows the exact `ip addr add` command on assign)
```

### 2.4 OS choice
- **Ubuntu 24.04 LTS (amd64)** — recommended. All SZL bundles are `architecture: amd64`; Ubuntu has the smoothest NVIDIA + k3s path.
- Rocky Linux 9 is fine if you prefer RHEL-family (use `dnf` equivalents); UDS Core supports it. Stick with Ubuntu for the fastest path.

### 2.5 SSH hardening + sample cloud-init (`cloud-init.yaml`)
Save this next to where you run `hcloud server create` (it disables password/root SSH login, creates a sudo user, sets inotify limits, installs base packages):
```yaml
#cloud-config
users:
  - name: szl
    groups: [sudo]
    shell: /bin/bash
    sudo: ["ALL=(ALL) NOPASSWD:ALL"]
    ssh_authorized_keys:
      - ssh-ed25519 AAAA...your-public-key...    # verify before deploy (paste your real key)
ssh_pwauth: false
disable_root: true
package_update: true
package_upgrade: true
packages: [curl, jq, git, ca-certificates, openssl, ufw]
write_files:
  - path: /etc/sysctl.d/99-uds.conf
    content: |
      fs.inotify.max_user_instances=8192
      fs.inotify.max_user_watches=524288
  - path: /etc/ssh/sshd_config.d/99-hardening.conf
    content: |
      PermitRootLogin no
      PasswordAuthentication no
      KbdInteractiveAuthentication no
      X11Forwarding no
runcmd:
  - sysctl --system
  - systemctl restart ssh
  - ufw default deny incoming && ufw allow 22/tcp && ufw allow 80/tcp && ufw allow 443/tcp && ufw --force enable
```
> Rely on the **Hetzner firewall** (§2.3) as the primary boundary; `ufw` is defence-in-depth. After boot, SSH as `szl@<IP>` (not root).

---

## 3. BASE PLATFORM (k3s, storage, ingress, cert-manager)

### 3.1 Install k3s — single node (easiest, do this first)
```bash
# On the Hetzner box. Disable Traefik so Istio (from UDS Core) owns ingress.
curl -sfL https://get.k3s.io | sh -s - --write-kubeconfig-mode 644 --disable traefik --disable servicelb
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
echo 'export KUBECONFIG=/etc/rancher/k3s/k3s.yaml' >> ~/.bashrc
kubectl get nodes -o wide
kubectl wait --for=condition=Ready nodes --all --timeout=120s
```
> k3s ships a `local-path` StorageClass and a kubelet that UDS Core targets directly. We disable Traefik + servicelb because **UDS Core brings its own Istio gateways**; if you keep them they'll fight over ports 80/443.

**Scale-out later (optional HA):** first server with `--cluster-init`, then more servers join with `K3S_TOKEN` (from `/var/lib/rancher/k3s/server/node-token`) and agents with `K3S_URL=https://10.0.1.x:6443`. Use the **private network** (`10.0.0.0/16`) for the join, not the public IP.

### 3.2 Storage
- **Default (easiest): `local-path`** — already installed by k3s, `ReadWriteOnce`, perfect for single-node. The Zarf in-cluster registry (§5) and Prometheus/Loki PVCs use it fine.
- **Longhorn (only when you go multi-node / want replicated `ReadWriteMany`):**
```bash
kubectl apply -f https://raw.githubusercontent.com/longhorn/longhorn/v1.7.2/deploy/longhorn.yaml   # verify version before deploy
kubectl -n longhorn-system get pods
kubectl patch storageclass longhorn -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
```
Longhorn needs `open-iscsi` on each node (`apt-get install -y open-iscsi`). On a single node, **skip it** — `local-path` is simpler and faster.

### 3.3 Ingress
**Do not install nginx/Traefik.** UDS Core deploys **Istio** with a **tenant gateway** (apps) and an **admin gateway** (Keycloak/Grafana). Your apps are exposed via the UDS `Package` CR `spec.network.expose` (§4.5), which creates the Istio VirtualService/Gateway entries automatically. That's the whole ingress story under UDS.

### 3.4 cert-manager / TLS
- **Easiest for a demo:** UDS Core can run with its bundled gateway TLS (self-signed or a cert you pass at deploy via `--set`). Browsers will warn on self-signed — fine for internal demo.
- **Real TLS (recommended for a public Hetzner box):** install cert-manager and use Let's Encrypt for your `*.uds.dev`-equivalent domain (a domain you control), then reference the issued secret on the Istio gateway:
```bash
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.16.2/cert-manager.yaml  # verify version
# Create a ClusterIssuer (ACME/Let's Encrypt) + Certificate for *.<your-domain>; mount the secret on the Istio gateway.
```
> DNS: point a wildcard `*.<your-domain>` A record at the server's public (or floating) IP, then pass `--set DOMAIN=<your-domain>` to the UDS Core deploy (§4.3). For a quick local/no-DNS test, add hostnames to `/etc/hosts` (see §10).

---

## 4. UDS — SPEC + INSTALL

### 4.1 What UDS is
**UDS = Unicorn Delivery Service** (Defense Unicorns). It is the secure-by-default application platform that sits on top of any conformant Kubernetes ([uds.defenseunicorns.com](https://uds.defenseunicorns.com/)). Two parts matter here:

- **UDS Core** ([github.com/defenseunicorns/uds-core](https://github.com/defenseunicorns/uds-core)) — a single bundle that establishes the secure baseline every app deploys **on top of**:
  - **Istio** (ambient is the current default mode) — service mesh, mTLS, ingress gateways.
  - **Pepr** — the runtime that hosts the **UDS Operator** + **UDS Policy Engine** (admission policies, default-deny networking).
  - **Keycloak** + **AuthService** — SSO / OIDC for every app.
  - **Prometheus / Grafana / Alertmanager** — metrics + dashboards.
  - **Vector → Loki** — log shipping + storage.
  - **Falco** — runtime security (NeuVector is **no longer** managed by Core).
  - **Velero** — backup/restore.
- **`uds` CLI (uds-cli)** ([github.com/defenseunicorns/uds-cli](https://github.com/defenseunicorns/uds-cli)) — the tool that deploys UDS bundles and **vendors Zarf** inside it (`uds zarf ...`). UDS **bundles** are OCI artifacts composed of one or more **Zarf packages**.
- **UDS `Package` CRD** (`uds.dev/v1alpha1`) — you declare `expose` / `allow` / `sso` / `monitor`; the **UDS Operator reconciles** those into Istio VirtualServices, NetworkPolicies, Keycloak clients, and Prometheus ServiceMonitors. This is what turns a plain workload into a *governed* app.

### 4.2 Install the `uds` CLI
```bash
UDS_VERSION="v0.32.0"
sudo curl -sLo /usr/local/bin/uds \
  "https://github.com/defenseunicorns/uds-cli/releases/download/${UDS_VERSION}/uds-cli_${UDS_VERSION}_Linux_amd64"
sudo chmod +x /usr/local/bin/uds
uds version        # v0.32.0
uds zarf version   # v0.77.0  (Zarf is vendored inside uds-cli — no separate install needed)
```
> macOS: `brew tap defenseunicorns/tap && brew install uds`.

### 4.3 Deploy UDS Core (the secure baseline)
```bash
# Recommended: pin UDS Core v1.5.0 (upstream flavor) onto YOUR k3s cluster.
# NOTE: the Core package tag has NO leading 'v'.  verify before deploy (re-probe GHCR / uds-core releases).
uds deploy oci://ghcr.io/defenseunicorns/packages/uds/core:1.5.0-upstream --confirm

# Public box with real DNS? Override the domain:
# uds deploy oci://ghcr.io/defenseunicorns/packages/uds/core:1.5.0-upstream --set DOMAIN=<your-domain> --confirm

# DoD / Iron Bank flavor (amd64-only, registry1) — roadmap, NOT used by us:
# uds deploy oci://ghcr.io/defenseunicorns/packages/uds/core:1.5.0-registry1 --confirm
```
Confirm baseline health:
```bash
kubectl get pods -n istio-system    # ztunnel + istiod Running (ambient)
kubectl get pods -n keycloak        # keycloak Running
kubectl get pods -n pepr-system     # pepr-uds-core (Operator + Policy Engine) Running
kubectl get pods -n monitoring      # prometheus, grafana, alertmanager
kubectl get pods -A | grep -E 'vector|loki|falco|velero'
```
> UDS Core **latest = v1.5.0**, published 2026-05-27 ([uds-core releases](https://github.com/defenseunicorns/uds-core/releases)). Re-confirm the current tag before deploy.

### 4.4 Deploy OUR bundles — VERIFIED digests (HTTP 200, 2026-06-06)

| Bundle | OCI ref | Manifest digest | Composition | Status |
|---|---|---|---|---|
| **Full 5-organ mesh** (RECOMMENDED) | `oci://ghcr.io/szl-holdings/szl-mesh:0.4.0` (=`v0.4.0`=`latest`) | `sha256:7f5fce3238ce3d255b322340bbe18cad1eb656e677065a2757637337300cac7f` | a11oy+sentra+amaru+rosie+killinchu | **PUBLISHED + signed — current, maintained fallback** |
| **Platform** (a11oy.uds) | `oci://ghcr.io/szl-holdings/a11oy-bundle:0.5.0` (=`latest`) | `sha256:d801f8e461dfd519b5f8593322e75b89a1e66d4da9f6d72d0937c8ff2de64b51` | a11oy + sentra/amaru/rosie backends | **PUBLISHED + signed — but STALE pin (see note)** |
| **Field node** (killinchu.uds) | `oci://ghcr.io/szl-holdings/killinchu-bundle:0.5.0` (=`latest`) | `sha256:e59921332c37408fb5a62b270eeeafb1f1ab44aebb350f18662c37aa2c67426f` | killinchu + sentra/amaru backends | **PUBLISHED + signed + current** |

```bash
# RECOMMENDED for the tower/CCX demo — full 5-organ mesh (current, signed, all-in-one):
uds deploy oci://ghcr.io/szl-holdings/szl-mesh:0.4.0 --confirm

# OR the two consolidated product bundles:
uds deploy oci://ghcr.io/szl-holdings/a11oy-bundle:0.5.0 --confirm       # platform
uds deploy oci://ghcr.io/szl-holdings/killinchu-bundle:0.5.0 --confirm   # field node
```
You'll see, per organ: `Pushing N images to the zarf registry … Component <organ> successfully deployed`, ending `✔ deployed` for a11oy → sentra → amaru → rosie → killinchu.

> **⚠️ a11oy-bundle re-pin status (HONEST):** `a11oy-bundle:0.5.0` (`d801f8e4…`) was built against an **older a11oy organ image**; the a11oy image was rebuilt afterward, so the published a11oy-bundle is **STALE**. **Two safe options:** (1) use **`szl-mesh:0.4.0`** (composes all 5 organs; maintained), or (2) have the UDS squad **re-pin** a11oy-bundle (re-run the `uds-canonical-bundles-publish.yml` `workflow_dispatch` with `bundle=a11oy`) and deploy the **new** digest (must be ≠ `d801f8e4…`; re-verify per §6.3). `killinchu-bundle` does **not** need a re-pin.

**GHCR pull auth (only if any organ image is private):**
```bash
export GHCR_TOKEN="ghp_xxx"                 # read:packages scope only — verify before deploy
echo "$GHCR_TOKEN" | docker login ghcr.io -u stephenlutar2 --password-stdin
export ZARF_REGISTRY_PULL_USERNAME="stephenlutar2"
export ZARF_REGISTRY_PULL_PASSWORD="$GHCR_TOKEN"
```
> The three published bundle manifests are **anonymously pullable** (verified). Login is only needed for heavy organ images if private.

### 4.5 The UDS `Package` CR — what turns a Zarf package into a governed UDS app
The Package CR ships **inside each per-organ Zarf package** (`manifests/uds-package.yaml`), so it applies automatically during `uds deploy`. This is the **real, current** CR for szl-a11oy (from `szl-holdings/uds-bundles`, `bundles/szl-a11oy/manifests/uds-package.yaml`):

```yaml
apiVersion: uds.dev/v1alpha1
kind: Package
metadata:
  name: szl-a11oy
  namespace: szl-a11oy
  annotations:
    szl.io/doctrine-version: "v11"
    szl.io/doctrine-pin: "749/14/163"
    szl.io/kernel-commit: "c7c0ba17"
    szl.io/slsa-level: "L1"
spec:
  network:
    expose:                                  # → Istio VirtualService on the tenant gateway
      - host: a11oy
        service: a11oy
        port: 8080
        gateway: tenant
        selector: { app: szl-a11oy }
    allow:                                   # → UDS-managed NetworkPolicy on top of default-deny
      - direction: Egress
        description: "Keycloak OIDC token endpoint"
        remoteNamespace: keycloak
        remoteSelector: { app.kubernetes.io/name: keycloak }
        port: 8443
        remoteProtocol: TLS
      - direction: Egress
        description: "SZL receipts server (DSSE audit sink)"
        remoteNamespace: szl-receipts
        remoteSelector: { app.kubernetes.io/name: szl-receipts-server }
        port: 8080
      - direction: Ingress
        description: "IntraNamespace (Istio + health probes)"
        remoteGenerated: IntraNamespace
  sso:                                       # → Keycloak OIDC client, group-gated to /szl-operators
    - clientId: uds-szl-a11oy
      name: "SZL A11oy"
      protocol: openid-connect
      redirectUris: ["https://a11oy.uds.dev/*"]
      webOrigins: ["https://a11oy.uds.dev"]
      standardFlowEnabled: true
      enableAuthserviceSelector: { app: szl-a11oy }
      groups: { anyOf: ["/szl-operators"] }
      secretConfig:
        name: szl-a11oy-oidc-secret
        template: |
          OIDC_CLIENT_ID: "{{ .clientId }}"
          OIDC_CLIENT_SECRET: "{{ .secret }}"
          OIDC_ISSUER: "https://sso.uds.dev/realms/uds"
  monitor:                                   # → Prometheus ServiceMonitor
    - description: "szl-a11oy Prometheus metrics"
      portName: http-metrics
      targetPort: 9090
      selector: { app: szl-a11oy }
      path: /metrics
      kind: ServiceMonitor
```
**Killinchu** is identical in shape but `port: 7860` (and a counter-UAS health path). To apply/re-apply CRs stand-alone (e.g. deploying a flagship independently of the full mesh), use the canonical CRs in **szl-fleet-overlay**:
```bash
git clone https://github.com/szl-holdings/szl-fleet-overlay.git && cd szl-fleet-overlay
kubectl apply -f uds-packages/            # a11oy, sentra, amaru, rosie, killinchu
kubectl get packages -A                   # UDS Operator reconciles each
kubectl describe package szl-a11oy -n szl-a11oy   # see expose/allow/sso/monitor reconciled
```

### 4.6 Bundle composition (`uds-bundle.yaml`)
A UDS bundle is `kind: UDSBundle` that **composes Zarf packages**. This is the **real** top-level `szl-mesh` meta-bundle (from `szl-holdings/uds-bundles/uds-bundle.yaml`, abridged):
```yaml
kind: UDSBundle
metadata:
  name: szl-mesh
  description: "SZL Holdings governed-AI substrate — 5 flagship organs"
  version: "0.4.0"
  architecture: amd64
  authors: "Stephen P. Lutar Jr. <stephenlutar2@gmail.com>"
packages:
  - name: szl-a11oy
    path: bundles/szl-a11oy        # local Zarf package dir (governance + agentic /code)
    ref: "0.2.0"
  - name: szl-sentra
    path: bundles/szl-sentra       # security gate
    ref: "0.2.0"
  - name: szl-amaru
    path: bundles/szl-amaru        # reasoning / memory cortex
    ref: "0.2.0"
  - name: szl-rosie
    path: bundles/szl-rosie        # operator console (ask-&-act)
    ref: "0.2.0"
  - name: szl-killinchu
    path: bundles/szl-killinchu    # counter-UAS field node
    ref: "0.2.0"
```
The **product bundles** (`bundles/a11oy/uds-bundle.yaml`, `bundles/killinchu/uds-bundle.yaml`) compose the same per-organ Zarf packages into a single air-gap-deployable product. Packages can also be referenced by `oci://` ref instead of `path:` for fully remote composition.

---

## 5. ZARF — SPEC + AIR-GAP

### 5.1 What Zarf is
**Zarf** ([zarf.dev](https://zarf.dev/), [docs.zarf.dev](https://docs.zarf.dev/)) is the air-gapped Kubernetes packaging + delivery tool that UDS uses **under the hood**. It bakes everything an app needs — **container images, Helm charts, raw manifests, files, and run-time actions** — into one declarative **Zarf package** (`.tar.zst`) that can be deployed into a cluster **with no internet** ([github.com/zarf-dev/zarf](https://github.com/zarf-dev/zarf)). `uds-cli` vendors Zarf, so `uds zarf <cmd>` == `zarf <cmd>`.

### 5.2 `zarf init` — the init package + in-cluster registry
`zarf init` bootstraps the cluster for air-gap by deploying the **init package** ([docs.zarf.dev/ref/init-package](https://docs.zarf.dev/ref/init-package/)):
- **`zarf-injector`** — a tiny statically-compiled Rust binary injected as a configmap to reassemble the `registry:3` image with no pull.
- **`zarf-seed-registry`** → **`zarf-registry`** — stands up the **long-lived in-cluster OCI registry** (NodePort by default; `proxy` mode available for IPv6/NFTables).
- **`zarf-agent`** — a mutating webhook that **rewrites every PodSpec image** to point at the in-cluster Zarf registry (and rewrites Flux/ArgoCD sources to the local Git server). *This is the magic that makes air-gap work without editing your manifests.*
- Optional components: `git-server` (Gitea), and even `k3s` itself.
```bash
zarf tools download-init                 # fetch the matching init package first
zarf init --confirm                      # nodeport registry by default
# with options:  zarf init --components git-server --registry-mode proxy --confirm
```
> **You do NOT need to run `zarf init` manually for the UDS path** — `uds deploy` of a bundle drives Zarf and initializes the in-cluster registry as part of the deploy. Use raw `zarf init` only when building/deploying standalone Zarf packages outside a UDS bundle.

### 5.3 `zarf.yaml` schema
A Zarf package is `kind: ZarfPackageConfig` with `metadata` + ordered `components`. Each component may carry:
- **`charts`** — Helm charts (`localPath` or `url`/`oci`), namespace, version, `valuesFiles`.
- **`images`** — container images baked into the package (the core of air-gap).
- **`manifests`** — raw K8s YAML files/URLs applied at deploy.
- **`files`** — arbitrary files staged onto the host/cluster (SBOMs, configs).
- **`actions`** — shell hooks at `onCreate` / `onDeploy` (before/after) for glue logic.

This is the **real, current** `zarf.yaml` for our a11oy organ (`bundles/szl-a11oy/zarf.yaml`, abridged):
```yaml
kind: ZarfPackageConfig
metadata:
  name: szl-a11oy
  version: 0.2.0
  description: "SZL a11oy — Governance + policy overlay + agentic /code"
  architecture: amd64
  authors: "Yachay <yachay@szlholdings.dev>"
  source: "https://github.com/szl-holdings/a11oy"
  yolo: false                              # air-gap: bake everything, pull nothing at deploy
components:
  - name: a11oy-runtime
    required: true
    charts:
      - name: a11oy
        namespace: szl-a11oy
        localPath: ./chart
        version: 0.2.0
        valuesFiles: [./chart/values.yaml]
    images:
      - "ghcr.io/szl-holdings/a11oy:uds-v0.2.0"     # baked into the .tar.zst
    manifests:
      - name: a11oy-pepr-policies
        namespace: szl-a11oy
        files:
          - ./policies/namespace-isolation.yaml
          - ./policies/dsse-receipt-egress.yaml
          - ./policies/section889-denylist.yaml
          - ./policies/lambda-gate.vap.yaml
          - ./policies/cosign-image-policy.yaml
  - name: szl-a11oy-uds-package             # the UDS Package CR (§4.5) — registers with the Operator
    required: true
    manifests:
      - name: szl-a11oy-uds-package
        namespace: szl-a11oy
        files: [./manifests/uds-package.yaml]
  - name: a11oy-sbom-attest
    required: false
    files:
      - source: ./sbom/a11oy.spdx.json
        target: ./sbom/a11oy.spdx.json
```

### 5.4 `zarf package create` / `deploy` / `dev find-images`
```bash
# Build a package from a directory containing zarf.yaml (pulls + bakes images/charts):
uds zarf package create bundles/szl-a11oy/ --confirm
#   -> zarf-package-szl-a11oy-amd64-0.2.0.tar.zst

# Deploy a built package directly (without a UDS bundle):
uds zarf package deploy zarf-package-szl-a11oy-amd64-0.2.0.tar.zst --confirm

# Discover which images a chart/manifests reference (so you can list them under `images:`):
uds zarf dev find-images bundles/szl-a11oy/
```

### 5.5 Registry mirroring for air-gap
For a true air-gap, the in-cluster Zarf registry (from `zarf init` / `uds deploy`) holds all images. To **mirror to your own registry** instead, init against an external registry:
```bash
zarf init --registry-url registry.internal.szl:5000 \
  --registry-push-username push --registry-push-password '***' --confirm    # verify before deploy
```
You can also `zarf tools registry copy` images between registries (this is exactly how the `uds-canonical-bundles-publish.yml` workflow stages bundles via `bundles-staging` then copies to the `*-bundle` repos).

### 5.6 How UDS bundles use Zarf under the hood
`uds deploy oci://…/szl-mesh:0.4.0` → uds-cli pulls the **UDSBundle** → for each composed **Zarf package** it runs the Zarf deploy flow → Zarf pushes the **baked images** into the in-cluster registry and the **zarf-agent rewrites pod image refs** → Helm charts + manifests (including the UDS `Package` CRs) apply → the **UDS Operator** reconciles Istio/NetworkPolicy/Keycloak/Prometheus. That chain is why an offline `.tar.zst` deploys with **zero internet**.

---

## 6. DEPLOY OUR STACK ON HETZNER — END-TO-END RUNBOOK

### 6.1 ONLINE path (recommended for first stand-up)
```bash
# === A) PROVISION (laptop) ===
export HCLOUD_TOKEN="<token>"; hcloud context use szl                       # verify before deploy
hcloud server create --name szl-uds --type ccx33 --image ubuntu-24.04 \
  --location nbg1 --ssh-key szl-laptop --network szl-net --firewall szl-fw \
  --user-data-from-file cloud-init.yaml
IP=$(hcloud server ip szl-uds); echo "$IP"
ssh szl@"$IP"

# === B) BASE PLATFORM (on the box) ===
curl -sfL https://get.k3s.io | sudo sh -s - --write-kubeconfig-mode 644 --disable traefik --disable servicelb
sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube-config && sudo chown $USER ~/.kube-config
export KUBECONFIG=~/.kube-config
kubectl wait --for=condition=Ready nodes --all --timeout=120s

# === C) uds-cli ===
UDS_VERSION="v0.32.0"
sudo curl -sLo /usr/local/bin/uds "https://github.com/defenseunicorns/uds-cli/releases/download/${UDS_VERSION}/uds-cli_${UDS_VERSION}_Linux_amd64"
sudo chmod +x /usr/local/bin/uds && uds version && uds zarf version

# === D) UDS CORE (secure baseline) ===
uds deploy oci://ghcr.io/defenseunicorns/packages/uds/core:1.5.0-upstream --confirm   # verify before deploy
kubectl get pods -n pepr-system -n keycloak -n istio-system -n monitoring

# === E) OUR MESH BUNDLE ===
uds deploy oci://ghcr.io/szl-holdings/szl-mesh:0.4.0 --confirm
#   digest sha256:7f5fce3238ce3d255b322340bbe18cad1eb656e677065a2757637337300cac7f

# === F) (alt) the two product bundles instead of the full mesh ===
# uds deploy oci://ghcr.io/szl-holdings/killinchu-bundle:0.5.0 --confirm     # current
# uds deploy oci://ghcr.io/szl-holdings/a11oy-bundle:0.5.0 --confirm         # STALE — prefer szl-mesh (§4.4)

# === G) VERIFY ===
kubectl get packages -A
for ns in szl-a11oy szl-sentra szl-amaru szl-rosie szl-killinchu; do
  kubectl wait --for=condition=Available deploy --all -n "$ns" --timeout=180s && echo "$ns OK"; done
# health ports: a11oy/sentra/amaru=8080, rosie/killinchu=7860
kubectl port-forward -n szl-a11oy     svc/a11oy     8080:8080 & sleep 2; curl -fsS http://localhost:8080/api/health
kubectl port-forward -n szl-killinchu svc/killinchu 7860:7860 & sleep 2; curl -fsS http://localhost:7860/api/killinchu/healthz
# supply-chain verify (bundle signature is the provenance — no bundle SLSA attestation):
cosign verify ghcr.io/szl-holdings/szl-mesh:0.4.0 \
  --certificate-identity-regexp="^https://github.com/szl-holdings/" \
  --certificate-oidc-issuer="https://token.actions.githubusercontent.com"
```

### 6.2 AIR-GAPPED variant
```bash
# --- ONLINE prep (do once, before going offline) ---
docker pull rancher/k3s:v1.31.5-k3s1                     # node image (or your UDS-Core-aligned tag)
uds pull oci://ghcr.io/szl-holdings/szl-mesh:0.4.0       # → uds-bundle-szl-mesh-amd64-0.4.0.tar.zst (~3.6 GB)
cp uds-bundle-szl-mesh-amd64-0.4.0.tar.zst /media/usb/
# also stage: uds-cli binary, k3s install script, (optional) cosign + a pre-cached Rekor bundle

# --- OFFLINE on the air-gapped box (no internet) ---
curl -sfL https://get.k3s.io | sudo INSTALL_K3S_SKIP_DOWNLOAD=true sh -s - --disable traefik   # k3s pre-staged
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
uds deploy oci://ghcr.io/defenseunicorns/packages/uds/core:1.5.0-upstream --confirm  # use a pre-pulled Core tarball offline
uds deploy /media/usb/uds-bundle-szl-mesh-amd64-0.4.0.tar.zst --confirm    # pulls NOTHING from the internet
```
| Deploy-time dependency | Baked into the tarball? | Network at deploy? |
|---|:---:|:---:|
| All 5 organ images | ✅ (`zarf package create`, CI) | NO |
| Helm charts (`localPath`) | ✅ | NO |
| UDS Package CRs + Pepr policies | ✅ | NO |
| SBOM / attestations | ✅ | NO |
> Zarf pushes baked images into the in-cluster registry and rewrites pod refs — that's why deploy needs no internet. Only `cosign verify` (reads Rekor) touches the network; skip or pre-cache it in true air-gap.

### 6.3 If the UDS squad re-pins a11oy-bundle
After a `uds-canonical-bundles-publish.yml` re-run with `bundle=a11oy`, **verify the new digest before deploying**:
```bash
TOKEN=$(curl -s "https://ghcr.io/token?scope=repository:szl-holdings/a11oy-bundle:pull" | jq -r .token)
curl -sI -H "Authorization: Bearer $TOKEN" \
  -H "Accept: application/vnd.oci.image.manifest.v1+json" \
  https://ghcr.io/v2/szl-holdings/a11oy-bundle/manifests/0.5.0 | grep -i docker-content-digest
# must differ from d801f8e4… ; then cosign verify, then uds deploy
```

---

## 7. GPU — expose the RTX 4060 Ti to k3s for model workloads

The 5 organs are CPU services; the GPU only matters for **local model inference** (a11oy `/code` agentic model serving, rosie model-backed responses). Attach the GPU on the node that has it (your **tower** joined as a k3s agent, or a Hetzner dedicated GPU server). Steps (Ubuntu, per [k3s advanced docs](https://docs.k3s.io/advanced)):
```bash
# 1) NVIDIA driver + container toolkit on the GPU node
distribution=$(. /etc/os-release; echo $ID$VERSION_ID)
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
  sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
  sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
sudo apt-get update && sudo apt-get install -y nvidia-driver-535-server nvidia-container-toolkit   # verify driver version
sudo nvidia-ctk runtime configure --runtime=containerd

# 2) (re)install/restart k3s — it auto-detects the nvidia runtime
curl -sfL https://get.k3s.io | sh -    # or: sudo systemctl restart k3s
grep nvidia /var/lib/rancher/k3s/agent/etc/containerd/config.toml   # confirm nvidia runtime found

# 3) RuntimeClass + device plugin
cat <<'EOF' | kubectl apply -f -
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata: { name: nvidia }
handler: nvidia
EOF
kubectl apply -f https://raw.githubusercontent.com/NVIDIA/k8s-device-plugin/v0.14.5/deployments/static/nvidia-device-plugin.yml  # verify version

# 4) verify the GPU is schedulable
kubectl describe node | grep -A2 nvidia.com/gpu     # expect Capacity/Allocatable: nvidia.com/gpu: 1
```
GPU-using pods then set `runtimeClassName: nvidia` and `resources.limits.nvidia.com/gpu: 1`.
> **Which a11oy capabilities can use it:** the agentic `/code` model-serving and rosie's model-backed answers benefit from the GPU; governance/policy, sentra, amaru, killinchu counter-UAS decisioning are CPU. On the **RTX 4060 Ti (16 GB VRAM)** you can serve a quantized 7B–14B class model — size the model to VRAM. The tower joins the Hetzner cluster as a GPU **agent** over a private overlay (WireGuard/Tailscale); keep the control plane on the CCX box.

---

## 8. DAY-2 OPERATIONS

- **Backups (Velero, shipped in Core):** schedule cluster + PV backups to S3-compatible object storage (Hetzner Object Storage or any S3). `velero backup create szl-$(date +%F) --include-namespaces szl-a11oy,szl-sentra,szl-amaru,szl-rosie,szl-killinchu`. Test a restore quarterly. Also back up `/var/lib/rancher/k3s/server/db` (k3s etcd snapshot: `k3s etcd-snapshot save`).
- **Upgrades (bump bundle versions + re-pin digests):** edit `uds-bundle.yaml` `ref:`/version, run `uds-canonical-bundles-publish.yml`, **re-verify the new digest** (§6.3), then `uds deploy oci://…:<newver>`. Always pin by version AND record the digest. Upgrade UDS Core by deploying the next `core:<ver>-upstream`.
- **Monitoring (UDS Prometheus/Grafana):** dashboards via the admin gateway (`grafana.admin.<domain>`). Each organ's `Package.spec.monitor` creates a ServiceMonitor; confirm targets are UP in Prometheus. Alertmanager routes to your channel.
- **Secrets:** the **receipt signing key** is auto-generated **in-cluster** by szl-uds-deployment's `szl-key-init` Helm pre-install hook (Ed25519 in `pepr-system`) — **zero founder action**, BYOK supported, SZL never sees it. For app secrets, prefer Keycloak-issued OIDC secrets (generated by the `sso` block) and Kubernetes Secrets sealed via your chosen sealing tool; do **not** commit secrets.
- **SSO via Keycloak:** admin console at `keycloak.admin.<domain>`. Create the `/szl-operators` group, add operators, assign to the `uds-szl-a11oy` / killinchu clients (provisioned by the `Package.spec.sso` block). Group membership gates app access.
- **TLS:** use cert-manager + Let's Encrypt for the Istio gateways (§3.4); rotate before expiry (cert-manager auto-renews). Keep node clock within ~5 min (NTP) so cosign/Rekor timestamps verify.
- **Observability:** Vector→Loki for logs, Falco for runtime security events; correlate via traceparent across organs.

---

## 9. EASY-PASS FROM GITHUB — clone + run mapping

Clone in **this order**. Every repo below is real in the `szl-holdings` org.

| # | Repo | Clone | Provides | Key workflows (real) |
|---|---|---|---|---|
| 1 | **szl-build-env** (private) | `git clone https://github.com/szl-holdings/szl-build-env.git` | One-command local tower bootstrap: `make up` (kind + Istio ambient + OTEL/Jaeger + 5 organs + cosign gate); `make verify`/`make trace`/`make down`. | — |
| 2 | **szl-uds-deployment** (private) | `git clone https://github.com/szl-holdings/szl-uds-deployment.git` | The live reference deploy target + task runner: `uds run start` (k3d + receipts bundle), `uds run demo:workload`, `uds run demo:verify`, `uds run teardown`. Carries `zarf.yaml`, `uds-bundle.yaml`, `tasks.yaml`, the Pepr governance-receipt policy, and `docs/` (INSTALL, AIRGAP, ARCHITECTURE, KEYCLOAK_SSO, OPERATOR_QUICKSTART, **and this doc**). | `uds-bundle-publish.yml`, `uds-package-release.yml`, `zarf-package-sign.yml`, `cosign.yml`, `sbom.yml`, `trivy.yml`, `scorecard.yml`, `verify-signed-assets.yml`, `doctrine.yml` |
| 3 | **uds-bundles** (public) | `git clone https://github.com/szl-holdings/uds-bundles.git` | The bundle SOURCE: `bundles/szl-<organ>/` Zarf packages, `bundles/a11oy/` + `bundles/killinchu/` UDSBundle manifests, root `uds-bundle.yaml` (szl-mesh), `crds/`, `mesh/`, `DEPLOY.md`. Built on UDS Core v1.5.0, Zarf ≥ v0.77.0, uds-cli v0.32.0. | **`uds-canonical-bundles-publish.yml`** (re-pin/re-publish a bundle via `workflow_dispatch`), `uds-bundle-publish.yml`, `zarf-bundle-build.yml`, `cosign.yml`, `cosign-bootstrap.yml`, `sbom.yml`, `trivy.yml` |
| 4 | **szl-fleet-overlay** (public) | `git clone https://github.com/szl-holdings/szl-fleet-overlay.git` | UDS Operator entry point + Helm chart: stand-alone `uds-packages/{a11oy,sentra,amaru,rosie,killinchu}.yaml`, `chart/` (dev/staging/prod values), Zarf air-gap variant. | — |

**Bare-box → running, today:**
```bash
git clone https://github.com/szl-holdings/szl-build-env.git && cd szl-build-env
echo "$GHCR_TOKEN" | docker login ghcr.io -u stephenlutar2 --password-stdin   # verify before deploy
make up && make verify && cd ..                  # validate the box can boot the stack
uds deploy oci://ghcr.io/defenseunicorns/packages/uds/core:1.5.0-upstream --confirm   # §4.3
uds deploy oci://ghcr.io/szl-holdings/szl-mesh:0.4.0 --confirm                          # §4.4
git clone https://github.com/szl-holdings/szl-fleet-overlay.git
kubectl apply -f szl-fleet-overlay/uds-packages/                                        # optional stand-alone CRs
```
**Re-pin a bundle (the publish workflow):** in `uds-bundles`, run **`uds-canonical-bundles-publish.yml`** via `workflow_dispatch` with input `bundle=a11oy` (or `killinchu`). It builds per-organ Zarf packages, `uds create`s the bundle, publishes to a token-writable `bundles-staging` namespace, then `zarf tools registry copy` to `ghcr.io/szl-holdings/<name>-bundle:<ver>` + `:latest`, then cosign-signs (keyless Fulcio+Rekor). Re-verify the new digest before deploy (§6.3).

---

## 10. CHECKLIST + TROUBLESHOOTING

### Pre-flight checklist
- [ ] Hetzner project + API token (`HCLOUD_TOKEN`) created — *verify before deploy*
- [ ] SSH key uploaded; firewall locks port 22 to your IP
- [ ] `ccx33` (or larger) provisioned with `cloud-init.yaml`; inotify limits applied
- [ ] k3s single-node Ready; Traefik/servicelb disabled
- [ ] `uds` v0.32.0 + vendored `zarf` v0.77.0 present
- [ ] UDS Core v1.5.0 deployed; pepr/keycloak/istio/monitoring pods Running — *verify Core tag*
- [ ] `szl-mesh:0.4.0` digest re-probed 200 (`7f5fce32…`); deployed; 5 namespaces Available
- [ ] `cosign verify` PASS on the bundle (signature = provenance; **no** bundle SLSA attestation)
- [ ] (if used) a11oy-bundle re-pinned + new digest verified (≠ `d801f8e4…`)
- [ ] DNS/TLS set for a public box; SSO group `/szl-operators` populated

### Troubleshooting
| Symptom | Cause | Fix |
|---|---|---|
| `ImagePullBackOff` on organ pods | GHCR token missing/expired or image private | `echo "$GHCR_TOKEN" \| docker login ghcr.io …` (`read:packages`); `kubectl describe pod -n szl-<organ>` |
| Istio VirtualService → 503, no metrics | sidecar-vs-ambient selector mismatch | Package CR selectors `app: szl-<organ>`; ports a11oy/sentra/amaru=8080, rosie/killinchu=7860; re-apply from `szl-fleet-overlay/uds-packages/` |
| Package CR stuck `Pending` | Istio not ready yet | wait for `ztunnel`/`istiod` Running in `istio-system`, then it reconciles |
| SSO redirect loop | Keycloak client not registered | re-run `uds deploy` (re-syncs `sso` CRs); confirm group `/szl-operators` |
| `zarf init` hangs / "requires a zarf-init package" | init seed not fetched | `zarf tools download-init` **before** `zarf init --confirm` (usually unnecessary on the UDS path) |
| `cosign verify` fails on bundle | wrong identity/issuer flags or NTP skew | use §6.1 flags exactly; keep clock within ~5 min (Rekor) |
| Port 80/443 conflict | Traefik/servicelb still running | reinstall k3s with `--disable traefik --disable servicelb` (Istio owns ingress) |
| GPU not schedulable | runtime not detected / plugin missing | `grep nvidia …/config.toml`; restart k3s; apply RuntimeClass + device plugin (§7) |
| a11oy-bundle out of date | STALE pin (`d801f8e4…`) | use `szl-mesh:0.4.0`, or re-pin a11oy-bundle and deploy the new digest (§6.3) |

**No-DNS quick test (local/SSH-tunnel):** add to `/etc/hosts` and tunnel the Istio gateway, or use the per-service `kubectl port-forward` calls in §6.1.

**Honesty reminders (do NOT overclaim):**
- **SLSA L1 honest / L2 on the organ images** (`cosign verify-attestation` PASS) — **bundle-level attestation NOT earned**; cosign **signature** is the bundle provenance. **No L3, no Iron Bank, no FedRAMP/CMMC.**
- **Λ = Conjecture 1**, never a theorem. Doctrine v11 LOCKED 749/14/163 @ c7c0ba17. Section 889 = exactly 5 vendors.
- Receipts are **real DSSE** when the key is present, **honest UNSIGNED** otherwise — never fabricated green.

---

## VERIFY EVIDENCE (re-probed 2026-06-06; anonymous GHCR token + manifest HEAD)

| Artifact | Ref | HTTP | Digest |
|---|---|---|---|
| Full mesh bundle | `szl-mesh:0.4.0` (=`v0.4.0`,`latest`) | **200** | `sha256:7f5fce3238ce3d255b322340bbe18cad1eb656e677065a2757637337300cac7f` |
| Platform bundle | `a11oy-bundle:0.5.0` (=`latest`) | **200** | `sha256:d801f8e461dfd519b5f8593322e75b89a1e66d4da9f6d72d0937c8ff2de64b51` (**STALE pin**) |
| Field bundle | `killinchu-bundle:0.5.0` (=`latest`) | **200** | `sha256:e59921332c37408fb5a62b270eeeafb1f1ab44aebb350f18662c37aa2c67426f` |
| Organ image a11oy | `a11oy:uds-v0.2.0` | **200** | `sha256:e2ef6184b94397d279753dd7b84addb74677a5921c425eee6637d9d098a80171` (newer than the a11oy-bundle pin → re-pin needed) |
| Organ image sentra | `sentra:uds-v0.2.0` | **200** | `sha256:60a0efc14366ba392bfe3f3cd4196863fe148bb87a17428be6a57f0a05ac3639` |
| Organ image amaru | `amaru:uds-v0.2.0` | **200** | `sha256:53301e26adcde49e73df28d8c3b790f2496da9d495307fe8587ffa7452b289ff` |
| Organ image rosie | `rosie:uds-v0.2.0` | **200** | `sha256:1984a15f53c2e1b91c7dafaa0ed5df9148d57e3e86eb73db879c2b0443302848` |
| Organ image killinchu | `killinchu:uds-v0.2.0` | **200** | `sha256:e0fb6c3aeaddadfbabc3ca7c5f29ef7b3ba31370b5ffb816e12495d5f29ca548` |
| UDS Core | `defenseunicorns/packages/uds/core:1.5.0-upstream` | **200** | (Defense Unicorns) — *verify tag before deploy* |

**Sources:** UDS docs — [uds.defenseunicorns.com](https://uds.defenseunicorns.com/), [uds-core](https://github.com/defenseunicorns/uds-core), [uds-cli](https://github.com/defenseunicorns/uds-cli). Zarf — [zarf.dev](https://zarf.dev/), [docs.zarf.dev init package](https://docs.zarf.dev/ref/init-package/), [zarf-dev/zarf](https://github.com/zarf-dev/zarf). Hetzner — [Cloud general-purpose/CCX](https://www.hetzner.com/cloud/general-purpose), [dedicated GPU matrix](https://www.hetzner.com/dedicated-rootserver/matrix-gpu/), [Cloud API](https://docs.hetzner.cloud/reference/cloud), [floating IPs](https://docs.hetzner.com/cloud/floating-ips/getting-started/adding-a-floating-ip/). k3s GPU — [k3s advanced docs](https://docs.k3s.io/advanced). SLSA — [slsa.dev levels](https://slsa.dev/spec/v1.0/levels). Internal ground truth: `team/HETZNER_UDS_ROADMAP.md`, `team/BUNDLE_BUILD_REPORT.md`, `team/UDS_MESH_ALIGN_REPORT.md`, `team/WARHACKER_UDS_READINESS.md`; live repos szl-build-env / szl-uds-deployment / uds-bundles / szl-fleet-overlay and the real `uds-bundle.yaml` / `zarf.yaml` / `uds-package.yaml` they carry (GitHub API).

---

*Doctrine v11 LOCKED 749/14/163 @ c7c0ba17 · Λ = Conjecture 1 (NEVER a theorem) · SLSA L1 honest / L2 on organ images — bundle-level attestation NOT earned (cosign signature is the bundle provenance), NOT L3, NOT Iron Bank, no FedRAMP/CMMC · Section 889 = exactly 5 vendors · Apache-2.0*
*Signed-off-by: Stephen P. Lutar Jr. <stephenlutar2@gmail.com>*
*Co-Authored-By: Perplexity Computer Agent <agent@perplexity.ai>*
