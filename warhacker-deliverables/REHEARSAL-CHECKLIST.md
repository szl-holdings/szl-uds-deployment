# Warhacker 2026 — Rehearsal Checklist & Run Sheet (Stephen)

**Event:** Warhacker, San Diego — June 16–19, 2026
**Audience:** Andrew Greene (Defense Unicorns co-founder) + adjacent DU technical staff
**Your machine:** Lenovo Yoga, Win 11 + WSL2 (Ubuntu), Docker Desktop — this is **Mode J (laptop k3d)**, the default when DU gives you no cluster access.
**Golden rule:** every claim cites evidence; nothing is "ready" without an HTTP 200 or a `PASS`. No mocks framed as live.

---

## 0. The one command — your safety net (use this if anything is shaky)

The **signed-receipt-chain + tamper proof** is fully real and CPU-only. Its cryptographic core (steps 2–5 below) needs **only `openssl`** — **no Kubernetes, no GPU, no cosign, no founder-staged image** — so it runs on the laptop, the tower, or any box. If a live UDS cluster happens to be reachable, the same script *also* posts the receipts into the real in-cluster receipts server (step 6) as bonus evidence; if not, it skips that step and the offline proof still passes. Proven green on Rosa's server on 2026-06-07 (all 6 steps).

```bash
cd ~/szl-uds-deployment    # on Rosa's server this path is /opt/szl/szl-uds-deployment
bash rehearse.sh
```

**Expect the last two lines:**
```
RESULT: PASS — Ed25519 receipt chain verifies offline; tamper rejected.
         (3 recorded verdicts signed & chained; 1 byte flipped -> rejected.)
```

If you can run that one command, you have a complete, honest, verifiable demo. Everything below is upside.

---

## 1. Pre-flight (run 30+ minutes before the room)

```bash
# Docker engine up?
docker version | grep -A1 Server

# Repo present?
cd ~/szl-uds-deployment && git log --oneline -1

# Tools (for the optional full-cluster path)
for t in docker k3d zarf uds kubectl jq curl openssl python3; do command -v $t || echo "MISSING $t"; done

# Cosign pinned to v2.4.1 (see §4 — v3.x breaks the verify flags)
cosign version 2>/dev/null | grep -i gitversion || echo "cosign not installed (only needed for image-signature talking point)"
```

WSL memory: confirm `~/.wslconfig` has `memory=24GB` (per `warhacker/HARDWARE_RECOMMENDATIONS_2026-05-30.md`) so the optional k3d cluster doesn't OOM.

---

## 2. The core demo, step-by-step (what `rehearse.sh` actually does — narrate each beat)

The script runs these six steps in order. Steps 2–5 are the cryptographic core (openssl only); steps 1 and 6 are live-cluster bonus and skip cleanly if no cluster is reachable.

| Step | What the script does | What to say |
|---|---|---|
| 1. Live cluster | `kubectl get pods -n szl-receipts` shows `szl-receipts-server … 2/2 Running` (or prints a clean "no cluster, running offline proof" line) | "Here's the real receipts server running in a UDS cluster — not a mock. (If no cluster, the offline proof below stands alone.)" |
| 2. Mint key | `openssl genpkey -algorithm ed25519` → ephemeral signing key; prints its sha256 fingerprint | "It signs with Ed25519. In production this key is the SealedSecret `szl-receipts-ed25519`; here it's minted on the spot so it runs anywhere, offline." |
| 3. Sign recorded verdicts | 3 drone decisions — uav-1 ALLOW, uav-2 ALLOW, uav-3 **DENY (G7 geofence)** — these are the scenario's *recorded* verdicts (no live gate engine runs here); each is written as a receipt, Ed25519-signed, hash-chained to the previous (`prev_hash`) | "A drone planner *scenario* proposes three commands; in the scenario the geofence denies the restricted-airspace one. Each recorded verdict becomes a signed, chained receipt. (I'm not running the live gate engine in this step — that's the governance logic; this step proves the *provenance* of the verdicts.)" |
| 4. **Offline verify** | For each receipt: `openssl pkeyutl -verify` with the **public key only**, plus a `prev_hash` chain check → `sig OK, chain OK` ×3 | "A verifier using only the public key, with no network, confirms all three signatures and that the chain is intact." |
| 5. **Tamper proof** | Flips one byte in receipt #3 (`altitude_m` 120→121), re-verifies → Ed25519 **rejects** it; payload hash changes | "An attacker edits the record — verification rejects it on cue, and the hash change breaks every later link in the chain." |
| 6. Live intake (bonus) | Port-forwards the in-cluster server and POSTs all three receipts; the server's `szl_receipts_total` counter rises | "And the real in-cluster server ingests them — watch the counter move. (Its server-side 'valid' counter uses the cluster's own key, not this demo key — said plainly.)" |

Talk-track detail for the cluster version lives in the repo at `docs/WARHACKER_DEMO.md` (5-minute script).

---

## 3. Optional: the full live-cluster path (`uds run start`) — and its known failure point

> 🟢 **UPDATE 2026-06-07 — the live-cluster path now PROVEN to deploy + serve, and the one-button task is now REPAIRED.** On a server Rosa controls, a real UDS Core booted and Stephen's receipts server came up `2/2 Running` and served HTTP 200, using a **locally-built image (no GHCR / FA-001 needed)** plus a set of repo fixes — and those fixes are now **baked into `tasks.yaml`**, so `uds run start` (and `uds deploy <bundle>`) drive the proven path directly. The old "stops at the Zarf build" / "wrong bundle name" notes below are superseded. Two hard ceilings still apply (full Core needs **>2 vCPU** — the tower, not a 2-vCPU box; stock Core's **two LoadBalancer gateways can't both run on single-node k3d** — reach receipts via the **admin** gateway `receipts.admin.uds.dev` or `kubectl port-forward`, not the tenant gateway). **Full recipe + evidence: `UDS-LIVE-CLUSTER-PROVEN-2026-06-07.md`.**

This is the more impressive "running deployment" Andrew asked for. The repo's one-button `uds run start` is now **repaired** (correct bundle name, `--skip-signature-validation`, modular `packages/szl-receipts` path, lockstep image tag), and the **path is proven** to deploy a real cluster and serve the receipts server (on Rosa's server, 2026-06-07). On **this laptop** a full from-scratch run is **not yet reproduced** — but the task now drives the proven path, so `uds run install-deps && uds run start` should bring it up (subject to the >2-vCPU ceiling for full Core).

```bash
cd ~/szl-uds-deployment
uds run start    # ~90s: k3d cluster + Zarf init + uds-core slim-dev + szl-receipts
```

**What deploys today (per `bundles/szl-warhacker/README.md`, verified 2026-05-30):**
1. Zarf init `:v0.77.0` ✅
2. uds-core slim-dev `0.34.0-slim-dev` ✅ (Istio + Pepr + Keycloak-lite + Prometheus)
3. szl-receipts (Pepr admission webhook + DSSE receipt server) ✅ Apache-2.0

> ℹ️ The ✅ marks mean the component is **available upstream** — *not* that a cluster is running **on this laptop**. The cluster path **was proven on Rosa's server** (modular recipe, 2026-06-07) but has **not been reproduced on this laptop yet**. The §0 container demo is your guaranteed proof; the cluster path is upside once you apply the recipe.

**What one-button `uds run start` now does (it used to fail):** the `start` task previously built the monolithic root `zarf.yaml` (which needs `dist/pepr`) and then deployed the **wrong bundle name**, so it couldn't complete. It is now **repaired in `tasks.yaml`** — it uses the **modular** `packages/szl-receipts` + root `uds-bundle.yaml` via `uds create`, deploys the **correct** bundle name with **`--skip-signature-validation`**, and builds the receipts image locally at the **lockstep `uds-v0.4.0`** tag — which means **FA-001/GHCR publish is NOT required** for the receipts cluster demo (that was the old assumption). The Pepr admission webhook is **OFF by default** (`--set WITH_PEPR=true` to add it). Full recipe: `UDS-LIVE-CLUSTER-PROVEN-2026-06-07.md`. The §0 container demo remains the reliable floor.

If you do get the cluster up, the chain query is `uds run demo:prove`.

> ⚠️ **Do NOT demo `uds run demo:scenario` on stage — it is broken as written.** `uds run` executes task actions under `sh` (dash), but the scenario script uses bash syntax (`[[`, `${VAR^^}`), so it dies immediately with `sh: [[: not found` / `Bad substitution`. It also signs receipts with a different HMAC key than `demo:verify` checks. `bash rehearse.sh` is the working, internally-consistent replacement — use it instead.

> ⚠️ **Do NOT run `uds run demo:verify` on stage.** It is the *legacy HMAC-SHA-256* verifier (see §5). The running server signs **Ed25519** (the PR-4 upgrade), so `demo:verify` marks every real receipt UNVERIFIED. Use the Ed25519 offline verify from §0/§2 instead.

---

## 4. cosign — pin v2.4.1, and be honest about what verifies

```bash
# Pin cosign v2.4.1 — v3.x changed verify flags and breaks the commands below.
COSIGN_VER=v2.4.1
curl -sSL "https://github.com/sigstore/cosign/releases/download/${COSIGN_VER}/cosign-linux-amd64" -o /tmp/cosign
sudo install /tmp/cosign /usr/local/bin/cosign
cosign version | grep -i gitversion     # expect: v2.4.1
```

**What each verification actually does today — say the honest version:**

| Command | Status today | Honest line |
|---|---|---|
| Receipt-chain Ed25519 verify (§0/§2) | ✅ **GREEN** | "This verifies, offline, with only the public key. Here's the tamper proof." |
| `cosign verify --key cosign/cosign.pub <image>` | ⚠️ image is **FA-001 gated** (not pushed) | "Image signing is wired (keyless OIDC by default); the image publish is a founder step (FA-001)." |
| `cosign verify` on the **UDS bundle** | ❌ **FAILS today** | "The bundle isn't cosign-signed yet — Phase 2, org key U5. I won't claim it is." (per `bundles/szl-warhacker/README.md`) |

Note: `cosign/cosign.pub` in the repo is ECDSA P-256 and is the **image** verification key — it is *not* the receipt signing key (that's the in-image Ed25519 `keyid=szl-receipts-ed25519-2026`). Keep these straight if asked.

---

## 5. Known gaps to disclose proactively (own them before a red-teamer finds them)

- **Ed25519 vs HMAC script drift.** Server signs Ed25519/DSSE; `scripts/verify_receipts.sh` (`uds run demo:verify`), the Pepr policy, and the talk-track annotation example (`szl-dev-hmac-sha256-2026`) still describe the legacy HMAC mode. `dsse_scheme_regression_test.py` only tests the HMAC pair, so a green test ≠ a working server verify. **Use the Ed25519 offline verify.**
- **FA-001 — five modules do not boot together.** Only `vessels` has a signed package (and even that is gated on the GHCR image push). `amaru`, `a11oy`, `sentra`, `rosie` publish SBOM JSON only — no image, no Zarf package → `ImagePullBackOff` if attempted. **Never claim five modules boot together.**
- **Module / "organ" count (the 5-vs-8 gap).** The UDS bundle topology defines **5 modules**. If any slide cites "8 organs," reconcile it before stage — the *deployable* substrate is 5 modules, of which 1 (vessels) has a signed image. State the deployable reality.
- **Bundle is ~small / not the full stack.** The honest framing: szl-receipts is the real, shippable Apache-2.0 add-on; the rest is staged target topology.
- **GPU.** Not needed for the governance/receipt proof. GPU only drives the LLM planner (`qwen2.5:7b`), which has a deterministic stub fallback. The crypto + gate logic is CPU-only and complete. *(Note: Stephen's laptop has an **NVIDIA RTX 5000**, so it can run the optional GPU planner too — the planner isn't tower-only.)*

---

## 6. Failure recovery cheat-sheet

| Symptom | Fix |
|---|---|
| `rehearse.sh: No such file or directory` | You're not in the repo root. `cd ~/szl-uds-deployment` (on Rosa's server: `cd /opt/szl/szl-uds-deployment`) first. |
| `openssl: command not found` | `sudo apt-get install -y openssl` — it's the only hard dependency of the crypto core. |
| Step 1 / step 6 say "no cluster" | That's fine — those are the bonus live-cluster steps. The `RESULT: PASS` from steps 4–5 is the real proof and stands alone. |
| Port 8080 busy (step 6) | Harmless — step 6 is bonus. Kill the stray forward: `pkill -f "port-forward svc/szl-receipts-server"`, then re-run. |
| `uds run start` stalls / pod `Pending Insufficient cpu` | Full stock Core does not fit 2 vCPU — use a multi-core box (the tower). On a small box, fall back to `bash rehearse.sh`. |
| Everything is on fire | `bash rehearse.sh` — the self-contained CPU demo is your safety net. |

---

**Bottom line:** lead with `bash rehearse.sh` (proven, honest, verifiable). Offer the live cluster only after applying the modular recipe in `UDS-LIVE-CLUSTER-PROVEN-2026-06-07.md` (Pepr build + ~7 repo fixes) — that path is proven on Rosa's server; **FA-001/GHCR is NOT required** for the receipts cluster demo. Disclose the gaps in §5 yourself — owning them is the whole credibility play with this audience.

---

## 7. Which machine to bring + exactly what the full UDS demo needs

**Both machines are GPU-capable. Bring the tower as the event machine; the laptop is a strong backup that can also run the full demo.**
- **Laptop (Lenovo Yoga, NVIDIA RTX 5000):** runs the §0 gold receipts demo — guaranteed; that's your floor. Because it has a real GPU **and** a multi-core CPU, it can also run the **optional GPU LLM planner** and is very likely to **clear the ">2 vCPU" ceiling** that the small 2-core server hit — so the full UDS cluster boot can be attempted here too (apply the recipe first).
- **Tower (RTX 4060 Ti):** the **event machine**, and still the best choice for the full UDS cluster boot (modules coming up together) plus the GPU AI-planner — once the build/publish blockers below are cleared. It can also run the gold demo.
- *(One caveat applies to **both** regardless of GPU: stock Core's two LoadBalancer gateways can't both run on single-node k3d — reach the receipts server via `kubectl port-forward`, not the tenant gateway.)*
- **Do this:** verify `bash rehearse.sh` runs **green on the tower** before the event — don't assume it carries over from the laptop.

**Is there a website / URL to view it?** **No.** This is a **command-line demo that runs on Stephen's own machine** — there is no public web page for Rosa or a judge to browse. The `*.uds.dev` hostnames in the code are *internal cluster* names for when it's deployed, not live public sites. To "see it," Stephen runs the command and shows the screen (or screen-shares).

**What the full UDS boot needs in order to work (honest list — proven on Rosa's server 2026-06-07; reproduce on the tower):**
1. Tools installed: docker 24+, k3d 5.6+, zarf 0.77+, uds CLI, kubectl 1.29+, **cosign v2.4.1** (not v3), jq, curl.
2. **Apply the ~7 repo fixes** in `UDS-LIVE-CLUSTER-PROVEN-2026-06-07.md` (Pepr build → `dist/pepr`; modular package path; remove the missing UI component; repoint Core to the public `ghcr.io` mirror; bundle override key; `--skip-signature-validation`; build the image locally). **Do NOT use one-button `uds run start`** — it deploys the wrong bundle name.
3. **Use a multi-core machine.** Full stock Core (Keycloak/Prometheus/tenant gateway) does **not** fit 2 vCPU — the **tower** is the right machine. Also reach the receipts server via `kubectl port-forward` (stock Core's two LoadBalancer gateways can't both run on single-node k3d).
4. *(For a second live module — drone planner)* **FA-001**: publish the **killinchu** image to GHCR + build its signed Zarf package. This is needed only for the *killinchu module*, **not** for the receipts cluster demo (which uses a locally-built image).

> The receipts cluster demo is proven and does **not** need FA-001. The §0 gold demo needs none of this and stays your floor.
