# Running the UDS demo environment on the laptop (test stand)

**Goal:** stand up a real, local UDS cluster on the laptop and run Stephen's
signed-receipts governance demo — the piece that proves his work is *connected to
UDS*. **CPU-only; no GPU required.**

This mirrors Stephen's own docs in the repo: `docs/INSTALL.md` and
`docs/WARHACKER_DEMO.md`. Nothing here is invented — it's his procedure, wrapped
so it's easy to run.

> 🟢 **READ FIRST (2026-06-07): the one-button `uds run start` is now REPAIRED.**
> A real UDS cluster + Stephen's receipts server were proven to boot/serve on a
> server Rosa controls, and the ~7 repo fixes are now baked into `tasks.yaml`, so
> `uds run install-deps && uds run start` drives the proven path directly (subject
> to the >2-vCPU ceiling for full Core — use the tower). The fixes were (broken `start` task,
> Pepr build flags, a removed UI component, the DU registry now needing auth →
> use `ghcr.io/defenseunicorns/packages/uds/core:1.5.0-upstream`, a bundle
> override key, `--skip-signature-validation`, and building the image locally).
> Two ceilings also apply: full Core needs **>2 vCPU** — that ceiling was hit on a
> small 2-core server; this laptop (NVIDIA RTX 5000, multi-core) and the tower both
> clear it. And stock Core's **two LoadBalancer gateways can't both run on single-node
> k3d** (this one applies to the laptop too, regardless of GPU) — reach the receipts
> server via `kubectl port-forward`. The exact recipe +
> live evidence is in **`UDS-LIVE-CLUSTER-PROVEN-2026-06-07.md`** — follow that for
> the cluster path; the steps below are the intended happy-path once those are applied.

---

## What it does
1. Creates a local Kubernetes cluster (k3d) named `uds-szl-demo`.
2. Deploys **real UDS Core** (Istio + Pepr + Keycloak + monitoring) — the same
   stack from Andrew's docs.
3. Builds + deploys Stephen's **szl-receipts** package (the Pepr admission
   webhook + DSSE receipt server). **This image is built locally**, so it does
   **not** need the registry image-publish step (FA-001).
4. *(Intended)* Every Deployment/Job that lands in the cluster gets a signed receipt via the Pepr admission policy. **Honest note:** this in-cluster *auto-receipt-on-deploy* path was **not yet exercised in testing.** What **was** proven (on Rosa's server, 2026-06-07) is the receipts **server running inside a real UDS cluster** and serving health/metrics; the receipt **crypto chain** (sign → verify → tamper-reject) is proven by the CPU-only `bash rehearse.sh`.

The drone module (`killinchu`) is **not** included here — it's still "staged"
until its image is published. That's expected and honest.

---

## Honest requirements & expectations
| Item | Need |
|------|------|
| OS | Windows 11 with **WSL2** (Ubuntu) — already set up on this laptop |
| Docker | **Docker Desktop** installed, running, with **WSL integration ON** |
| Memory | **~8 GB+ free RAM** allocated to Docker/WSL (UDS Core is heavy) |
| Disk | **~15 GB free** |
| Time | **15–25 min on the FIRST run** (downloads several GB). ~90 sec after that |
| Network | Open internet for the first run (pulls UDS Core images) |
| GPU | **Not needed** for the receipts proof. This laptop's **NVIDIA RTX 5000** can run the optional GPU LLM planner. |

> If the laptop has less than ~8 GB free RAM, UDS Core may fail to come up. In
> that case we test on a bigger machine first (ask Forge).

---

## Steps (run these in the WSL **Ubuntu** terminal)

**0. Make sure Docker Desktop is open and running** (whale icon in the system
tray), with Settings → Resources → WSL Integration enabled for Ubuntu.

**1. Install the tools + boot the cluster** — save `uds-laptop-bootstrap.sh`
into your home folder and run:
```bash
bash ~/uds-laptop-bootstrap.sh
```
This installs `k3d`, the `uds` CLI, `zarf`, and `cosign v2.4.1` (the version the
judges' command needs — NOT v3), then runs `uds run start`.

**2. Open the dashboard** (leave this running in its own terminal tab):
```bash
cd ~/szl-uds-deployment
uds run port-forward
```
Then open a browser to **http://localhost:8443** — you'll see an empty receipt
feed.

**3. Fire a workload and watch a receipt appear:** *(intended happy-path — the auto-receipt-on-deploy webhook path is not yet proven; see the honest note above)*
```bash
uds run demo:workload
```

**4. Verify the receipts cryptographically:**
> ⚠️ **Do NOT use `uds run demo:verify`.** It is the *legacy HMAC* verifier; the server signs **Ed25519**, so it marks every real receipt UNVERIFIED. Use the **Ed25519 offline verify** from the receipts demo (`bash rehearse.sh` / the §0–§2 verify in `REHEARSAL-CHECKLIST.md`).

**That's the whole proof:** a workload hit the cluster, UDS's Pepr layer
intercepted it, Stephen's policy signed a tamper-evident receipt, and it
verifies. That *is* the "connected to UDS" story Andrew asked for.

---

## If something breaks
Paste the error to Forge. Common ones:
- **`docker` not found / cannot connect** → Docker Desktop isn't running, or WSL
  integration is off.
- **Cluster won't start** → `k3d cluster delete uds-szl-demo && uds run start`
- **No receipts appear** →
  `kubectl logs -l app.kubernetes.io/name=pepr-admission -n pepr-system | grep szl`
- **Out of memory / pods stuck `Pending`** → not enough RAM for UDS Core; test on
  a larger machine.

## Tear down when done
```bash
uds run teardown
```
