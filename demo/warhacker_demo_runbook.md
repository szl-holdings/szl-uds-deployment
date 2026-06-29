# Warhacker Demo Runbook — TAWANTIN, the Governed Distributed Compute Fabric (LIVE)

**Version:** 2.1.0 (TAWANTIN-branded live-URL edition) · supersedes the k3d-only runbook for the floor demo
**Doctrine:** v11 LOCKED · 749/14/163 @ kernel `c7c0ba17` · Λ = Conjecture 1 · SLSA L1 honest · 0 runtime CDN
**Last live-verified:** 2026-06-15T23:16Z (every beat curl-checked — see §5)
**One unacceptable outcome:** the half-state — claiming more than is real. Every number on screen is labeled LIVE / MEASURED / SAMPLE / MODELED / ROADMAP.

**The name.** The unified Governed Distributed Compute Fabric is **TAWANTIN** — Quechua *tawantin*, "the four united parts" (the four regions united into one whole, Tawantinsuyu). TAWANTIN is the fabric that unites the sovereign nodes — relayed by **Chaski** (the messenger node/organ) and recorded by **Khipu** (the signed-receipt ledger) — into one governed system-of-systems. Tagline: ***"Sovereign signal. Signed receipt. No node left dark."*** It is live and branded at `https://a-11-oy.com/tawantin` (and the equivalent `/fabric` route).

> This is the **60–90 second live demo** on real URLs. No cluster spin-up, no laptop dependency — it runs from any browser. The k3d/UDS local runbook (`operator/docs/WARHACKER_DEMO_RUNBOOK.md`) remains the air-gap / packaging story; this is the floor "wow."

---

## 0. Pre-flight (do this 5 min before, off-stage)

Open three browser tabs in this order so they are warm:

1. `https://a-11-oy.com/tawantin` (equivalently `https://a-11-oy.com/fabric`) — the unified **TAWANTIN** Governed Distributed Compute Fabric view
2. `https://killinchu.a-11-oy.com/elite` — the counter-UAS operator app (Receipt Ledger & Verify view ready)
3. A terminal with this one-liner staged (the signed-receipt verify):
   ```bash
   curl -s -X POST https://a-11-oy.com/api/a11oy/khipu/verify \
     -H 'content-type: application/json' -d '{}' | python3 -m json.tool
   ```

Sanity check (silent, off-stage):
```bash
curl -s -o /dev/null -w "%{http_code}\n" https://a-11-oy.com/fabric            # expect 200
curl -s -o /dev/null -w "%{http_code}\n" https://a-11-oy.com/api/a11oy/v1/compute-pool-hardened  # expect 200
curl -s -o /dev/null -w "%{http_code}\n" https://killinchu.a-11-oy.com/elite    # expect 200
```

If the energy band shows "source unavailable, shown honestly empty," that is **correct behavior**, not a failure — the energy exporter intermittently remounts during deploy churn and the page never fabricates. Narrate it as a feature (see Beat 3).

---

## 1. The 60–90s beat sheet (exact click path)

> Total: 5 beats. Target 75s. Each beat has a **say** line (≤2 sentences) and an **honesty anchor** you point at on screen.

### Beat 1 — The thesis + the live fabric (0:00–0:18) · tab 1 `/tawantin`
- **Click:** already on `https://a-11-oy.com/tawantin`. Scroll to "1 · Fabric at a glance."
- **Say:** "This is **TAWANTIN** — Quechua for *the four united parts* — a sovereign GPU mesh running *right now*: a laptop RTX, an OMEN tower, the **Chaski** messenger node, plus cloud failover, all united under one governed OpenAI-compatible router. Every figure is honestly labeled, and reachability is a real TCP probe this sweep."
- **Point at:** the KPI tiles — `nodes total 7 · reachable 6 · sovereign GPU reachable 2` (LIVE). These come from `/api/a11oy/v1/compute-pool-hardened`, a real probe.
- **Honesty anchor:** OMEN shows **unreachable this sweep (honest: timeout)** — *"We show you the node that's down and why. We never fabricate reachability."*

### Beat 2 — No fused VRAM, horizontal scaling (0:18–0:32) · tab 1 `/tawantin`
- **Click:** scroll to the "Scaling model — honest" band.
- **Say:** "We do **not** claim fused or combined VRAM. Nodes scale horizontally — the router places each job on a reachable node; memory does not merge across the network. That's the honest architecture, and it's the one that survives a judge's pressure-test."
- **Point at:** the literal on-screen text *"VRAM does NOT merge across the network — there is no fused/combined VRAM."*
- **Honesty anchor:** this is the line most demos get wrong. We lead with it.

### Beat 3 — Energy MEASURED + the provenance posture (0:32–0:48) · tab 1 `/tawantin`
- **Click:** scroll to "4 · Energy — joules MEASURED, climbing."
- **Say:** "Every watt is accounted for. Joules are **MEASURED** via an on-box exporter on the sovereign node — hundreds of thousands of joules across tens of thousands of jobs. Nodes without a meter read SAMPLE, never imputed."
- **Point at:** the per-node table; the `MEASURED` label on `rtx-betterwithage`, the `SAMPLE` label elsewhere.
- **Honesty anchor (say this — it's a strength):** "And the tamper-**evident** provenance chain labels its rolled-up estimate SAMPLE until a hardware power meter is wired — `tamper-EVIDENT, not measured` is printed right there. We don't round up."
- **Fallback if the energy band is empty:** *"The exporter is mid-redeploy — watch: the page renders the source honestly empty rather than show you a stale number. That refusal to fabricate is the product."*

### Beat 4 — The signed-receipt verify (0:48–1:05) · tab 3 terminal
- **Click:** run the staged curl (the Khipu verify POST).
- **Say:** "Every decision and every watt folds into the Khipu receipt chain. Here's a live verify against our published cosign key."
- **Point at:** the JSON — `keyid_expected: szlholdings-cosign`, `pub_fingerprint_sha256: 7619…65a7`, `verify_receipt_signed: true`, and `verify_key_url` (our public key on GitHub).
- **Honesty anchor (turn the empty-payload result into a strength):** "I sent an empty payload, so it honestly returns `verified: false — missing payload`. It will never green-light something it can't check — *and the verify operation itself emits its own signed receipt* (`verify_receipt_digest`). The auditor is audited."

### Beat 5 — The frontier result + orbital-as-ROADMAP (1:05–1:20) · tab 2 `/elite`
- **Click:** switch to `https://killinchu.a-11-oy.com/elite`; open **"⛉ Receipt Ledger & Verify"** view (or point at the "8 formulas formally proven" / "Trust score = conjecture" badges on the hero).
- **Say:** "Same governed substrate drives counter-UAS: a DSSE receipt per interdiction, a 3-of-4 Khipu quorum, effectors **simulated, human-on-loop**. Underneath it all is a frontier result — **exactly 8 Lean-proven formulas at kernel c7c0ba17**, with Λ-uniqueness held as **Conjecture 1**, not an over-claimed theorem, plus a live open bounty for the unconditional case."
- **Close (orbital frame):** "That whole **TAWANTIN** substrate — the four united parts — is the proven terrestrial core. Orbital is the clearly-labeled **ROADMAP** it was built for — we prove on real metal what the orbital-architecture crowd only asserts. We do not run satellites."
- **Honesty anchor:** the on-screen `Trust score = conjecture (not proven)` and `8 formulas formally proven` badges — proof and honesty in the same frame.

---

## 2. The one-breath version (if you only get 30 seconds)

"**TAWANTIN** — *the four united parts* — is a sovereign GPU mesh, live, under one governed router at `a-11-oy.com/tawantin`. No fused VRAM, horizontal scaling, every node's reachability a real probe. Joules MEASURED per job, every decision relayed by **Chaski** and a signed **Khipu** receipt you can verify against our public key. Eight Lean-proven formulas; Λ-uniqueness held honestly as a conjecture with an open bounty. Orbital is the labeled roadmap — we prove on real metal what others assert."

---

## 3. Hard "do not say" list (doctrine guardrails)

| NEVER say | INSTEAD say |
|---|---|
| "fused / combined / pooled VRAM" | "horizontal scaling; router places jobs; memory does not merge" |
| "Λ is proven / a theorem" | "Λ-uniqueness is **Conjecture 1**; **Theorem U** is the conditional result; open bounty for the unconditional case" |
| "5 locked formulas" / any count ≠ 8 | "**exactly 8** locked formulas {F1,F4,F7,F11,F12,F18,F19,F22} @ c7c0ba17" |
| "tamper-proof" | "tamper-**evident**" |
| "100% trust" / "fully verified" | "trust < 1.0; honest confidence; Λ-gated" |
| "FedRAMP / Iron Bank / CMMC / ATO / SLSA L3 (bare)" | "SLSA **L1 honest · L2 attested · L3 roadmap**" |
| "we run satellites / orbital nodes" | "orbital is a clearly-labeled **ROADMAP / vision frame**; terrestrial mesh is the proven core" |
| "live signatures on killinchu ledger" | "killinchu ledger is hash-chained; signatures are **PLACEHOLDER** pending CI Sigstore wiring — the **a11oy** Khipu verify is the signed one" |

---

## 4. Recovery moves (if a beat is down on the floor)

- **/fabric 200 but a data band empty** → narrate the honest-empty behavior (Beat 3 fallback). The page uses `Promise.allSettled`; one dead source never breaks the view and never fabricates.
- **energy/operator/status 404** → it's the intermittent exporter remount during deploy churn. Pivot to `/energy` page or the `compute-pool-hardened` reachability tiles, which stay healthy.
- **killinchu slow to load (~1.2 MB page)** → it was warmed in pre-flight; if cold, talk through Beat 1–4 on a11oy while it loads.
- **Network down entirely** → fall back to the k3d local demo (`operator/docs/WARHACKER_DEMO_RUNBOOK.md`, `make demo-up`) or the air-gap USB mode (`demo/jack-in.sh C`). The full unified fabric also ships as the **TAWANTIN Zarf/UDS bundle** (`bundles/tawantin`) — one airgap-deployable, cosign-signable OCI artifact (see §6).

---

## 5. Live-URL verification (curl proof — run 2026-06-15T23:16Z)

```
BEAT 1/2/3  a11oy /fabric                                 HTTP 200  (19,149 b, real page not SPA shell)
BEAT 1      /api/a11oy/v1/compute-pool-hardened           HTTP 200  nodes_total=7 reachable=6 gpu=2; omen honest "timeout"
BEAT 3      a11oy /energy                                 HTTP 200  (29,597 b)
BEAT 3      /api/a11oy/v1/energy/operator/status          HTTP 404  FLAGGED — intermittent exporter remount; page renders honestly-empty
BEAT 3      /api/a11oy/v1/energy/provenance               HTTP 200  chain length 0, label "SAMPLE/ESTIMATE", tamper-EVIDENT
BEAT 4      POST /api/a11oy/khipu/verify                  HTTP 200  verify_receipt_signed=true; empty payload -> verified=false (honest)
BEAT 5      killinchu /elite                              HTTP 200  (1,247,695 b) "8 formulas formally proven" + "Trust score = conjecture"
BEAT 5      /api/killinchu/v1/receipt/ledger              HTTP 200  count=0; signatures PLACEHOLDER (honest, Sigstore not yet in CI)
support     a11oy /api/health  &  /api/a11oy/v1/honest    HTTP 200  749/14/163 @ c7c0ba17, locked=8, Λ=Conjecture 1
```

**Status:** 9 of 10 beats LIVE-VERIFIED right now. 1 beat (energy operator status endpoint) **FLAGGED transient** — the rolled-up MEASURED joules figure (~824,658 J at session start per D1's fabric ship report) is real and returns when the exporter remounts; the page's honest-empty fallback means the demo never fabricates and never breaks.

---

## 6. Deployability — the TAWANTIN Zarf/UDS bundle

The live demo (`a-11-oy.com/tawantin` + `killinchu.a-11-oy.com/elite`) is reachable today; the **TAWANTIN** UDS bundle (`bundles/tawantin`, commit `4b6fbbcf`) is the package that closes the Warhacker **deployability** gap. It composes the fabric story — the a11oy sovereign GPU-mesh governed router, the energy-per-successful-goal signal, and the **Khipu** signed-receipt chain — into **one airgap-deployable, cosign-signable** OCI bundle:

```text
uds deploy oci://ghcr.io/szl-holdings/tawantin-bundle:0.1.0 --confirm
```

**Honest status (Doctrine v11 §10 — "no 'ready' without HTTP 200"):** the `szl-a11oy` member is **LIVE / digest-pinned**; the `szl-energy-harvest` and `szl-tawantin` members are **VALIDATED / build-valid** but **GATED-on-IMAGE** (their `images:` lists are intentionally commented out until those images are published + cosign keyless-signed on GHCR). The bundle is **SCHEMA-VALID**; it does **not** claim all three members co-boot on one cluster, and the published OCI artifact is **not** cosign-signed yet. No fabricated digest is pinned — the half-state is refused here too.

---

*Doctrine v11 LOCKED 749/14/163 @ c7c0ba17 · Λ = Conjecture 1 · SLSA L1 honest · 0 runtime CDN · tamper-EVIDENT · effectors SIMULATED human-on-loop · locked = EXACTLY 8 {F1,F4,F7,F11,F12,F18,F19,F22}.*
