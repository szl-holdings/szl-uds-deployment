# SZL Holdings — Warhacker Outbrief (One-Pager)
## TAWANTIN — the Governed Distributed Compute Fabric

*"Sovereign signal. Signed receipt. No node left dark."*

**Doctrine v11 LOCKED · 749/14/163 @ kernel `c7c0ba17` · Λ = Conjecture 1 · SLSA L1 honest · 0 runtime CDN**
Live: **a11oy.net/tawantin** (≡ `a11oy.net/fabric`) · **killinchu.a11oy.net/elite** | Verified 2026-06-15

> **The name.** The unified fabric is **TAWANTIN** — Quechua *tawantin*, **"the four united parts"** (the four regions united into one whole, Tawantinsuyu). TAWANTIN unites the sovereign nodes — relayed by **Chaski** (the messenger node/organ) and recorded by **Khipu** (the signed-receipt ledger) — into one governed system-of-systems.

---

### The thesis (one sentence)

SZL's sovereign GPU mesh + energy-per-successful-goal (joules **MEASURED**) + Khipu signed-receipt chain + doctrine-locked governance = **the terrestrial, provable governance & energy-accounting fabric that distributed / edge / orbital compute system-of-systems will require** — **we prove on real metal what the orbital-architecture crowd only asserts.**

Defense's winning fabric stories lead with the architecture, not the hardware, and prove on real metal before projecting the vision ([Anduril's Lattice as "the architectural spine," not a product](https://www.fedsavvystrategies.com/anduril-a-persistent-product-first-strategy/); [Shield AI anchoring roadmap to combat-proven firsts](https://shield.ai/hivemind/)). SZL occupies the layer none of them have built: the **governance-and-energy-accounting substrate** with a signed receipt for every decision and every watt.

---

### The three pillars — one narrative

**1 · TAWANTIN — Governed Distributed Compute Fabric** *(LIVE)*
**TAWANTIN** is a live sovereign GPU mesh — laptop RTX 5050, OMEN RTX 4060 Ti, the **chaski** (messenger) tailnet node, plus Groq / NVIDIA-NIM / HF cloud failover — united under **one governed OpenAI-compatible router** with honest provenance per answer. Reachability is a **real TCP probe** every sweep (`7 total · 6 reachable · 2 sovereign GPU` at verify; the down node shows its honest reason). **No fused / combined VRAM — nodes scale horizontally; memory does not merge across the network.**
→ `a11oy.net/tawantin` (≡ `a11oy.net/fabric`) · `GET /api/a11oy/v1/compute-pool-hardened`

**2 · Energy-vertical harness** *(MEASURED)*
Joules **MEASURED** per successful goal via an on-box exporter on the sovereign node (~824,658 J across ~23,369 jobs at session start, climbing); nodes without a meter read **SAMPLE**, never imputed. Signed receipts fold into the **Khipu** ledger; the chain is **tamper-EVIDENT, not tamper-proof**, and its rolled-up energy estimate is honestly labeled SAMPLE/ESTIMATE until a hardware power meter is wired. *"Every watt and every decision, measured and cryptographically receipted across a distributed mesh."*
→ `a11oy.net/energy` · `POST /api/a11oy/khipu/verify` (verify against published cosign key)

**3 · A frontier result** *(PROVEN core + honest conjecture)*
**Exactly 8** Lean-4 formulas are sorry-free, kernel-only, locked at `c7c0ba17`: **{F1, F4, F7, F11, F12, F18, F19, F22}** (deterministic replay, Khipu DAG acyclicity, Chaski FIFO, reciprocity conservation, Reed–Solomon parity, Bekenstein-additive budget, monotone emit). The locked count is *itself* a zero-axiom theorem, so it cannot silently grow. **Λ-aggregator uniqueness is Conjecture 1, NOT a closed theorem** — what *is* proven is the conditional **Theorem U** (axiom-free) plus a machine-checked counterexample (`maxAgg`) showing the unconditional claim is false as stated, with a **live open bounty** for the unconditional case.
→ `lutar-lean` (749/14/163, [DOI 10.5281/zenodo.20434308](https://doi.org/10.5281/zenodo.20434308)) · `GET /api/a11oy/v1/honest`

---

### Orbital framing — clearly labeled **ROADMAP**

The same governance primitives the terrestrial mesh proves on real metal — honest reachability, joules MEASURED per node, Λ-gated placement, signed-receipt provenance — are exactly what distributed / edge / **orbital** compute system-of-systems will require. **This is the vision frame, labeled ROADMAP. SZL does not operate satellites; nothing in the live mesh is orbital.** This is honest asymmetry, the move credible deep-tech teams use: claim the protocol position, prove the adjacent capability, label the rest ([TRL honesty guidance: "+1–2 is okay, more makes you less credible"](https://www.linkedin.com/posts/marcclange_i-have-looked-at-more-than-500-defense-activity-7366149366794932224-SMDs)).

---

### Honest proof points — with verify commands

| Claim | Label | Verify it live |
|---|---|---|
| Sovereign mesh, real reachability, no fused VRAM | **LIVE** | `curl -s https://a11oy.net/api/a11oy/v1/compute-pool-hardened` |
| Joules per goal | **MEASURED** (exporter) / **SAMPLE** (no meter) | `curl -s https://a11oy.net/api/a11oy/v1/energy/operator/status` |
| Energy provenance chain | **tamper-EVIDENT**, SAMPLE estimate | `curl -s https://a11oy.net/api/a11oy/v1/energy/provenance` |
| Signed Khipu verify (emits its own receipt) | **LIVE** | `curl -s -X POST https://a11oy.net/api/a11oy/khipu/verify -H 'content-type: application/json' -d '{}'` |
| Doctrine lock 749/14/163, locked=8, Λ=Conjecture 1 | **LIVE** | `curl -s https://a11oy.net/api/a11oy/v1/honest` |
| Counter-UAS, DSSE per interdiction, effectors SIMULATED human-on-loop | **LIVE app** | open `https://killinchu.a11oy.net/elite` → "Receipt Ledger & Verify" |
| 8 formulas formally proven; Λ conditional | **PROVEN / CONJECTURE** | `lutar-lean` repo + [DOI 10.5281/zenodo.20434308](https://doi.org/10.5281/zenodo.20434308) |
| SLSA posture | **L1 honest · L2 attested · L3 roadmap** | `gh attestation verify` / `cosign verify-attestation` (public cosign.pub) |

---

### Why this wins Warhacker

Warhacker measures success by **apps in mission environments**, not cleverness ([Defense Unicorns Warhacker](https://defenseunicorns.com/warhacker/)). SZL ships a **working live demo** (two production apps, real data, real signed verify), a **provenance chain** judges can verify against a public key, and direct **mission relevance** (counter-UAS with human-on-loop). The UDS-Core packaging gap is closed by the **TAWANTIN Zarf/UDS bundle** (`bundles/tawantin`, commit `4b6fbbcf`) — one airgap-deployable, cosign-signable OCI artifact (`uds deploy oci://ghcr.io/szl-holdings/tawantin-bundle:0.1.0 --confirm`) that composes the a11oy router + energy signal + Khipu receipt chain; the `szl-a11oy` member is **LIVE / digest-pinned**, the energy + tawantin members are **build-valid / GATED-on-IMAGE** (no fabricated digest pinned), plus the air-gap `demo/jack-in.sh` switch-over kit. Everything claimed is verifiable; **the half-state — claiming more than is real — is the one outcome we refuse.**

---
*SZL Holdings · **TAWANTIN** = the unified Governed Distributed Compute Fabric (Chaski = messenger · Khipu = ledger) · Apache-2.0 · tamper-EVIDENT · trust < 1.0 · 0 runtime CDN · Doctrine v11 LOCKED 749/14/163 @ c7c0ba17 · Λ = Conjecture 1 · locked = EXACTLY 8 {F1,F4,F7,F11,F12,F18,F19,F22}*
