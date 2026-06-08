<!-- Copyright 2026 SZL Holdings / SPDX-License-Identifier: Apache-2.0 -->

# Persistent Vault + Kubernetes-auth Runbook — szl-receipts Tier 2

**Scope:** operating the Tier-2 (`signing.backend: vault`) key custody for
`szl-receipts` on a **persistent** HashiCorp Vault, with the receipts pod
authenticating to Vault via **Kubernetes auth** (its short-lived pod
ServiceAccount token) instead of a static, long-lived Vault token.

**Why this exists.** The earlier demo ran `vault server -dev`: in-memory
storage, a fixed root token (`root`), auto-unsealed. That is fine for a smoke
test but it is **not custody** — a pod restart wipes the Transit key and the
signing chain silently regresses, and the receipts pod held a static
`szl-receipts-vault-token` Secret (a long-lived bearer credential in etcd).
This runbook moves both problems off the table:

| Property | `-dev` (before) | persistent + k8s-auth (now) |
|---|---|---|
| Storage | in-memory | **file backend on a PVC** — Transit key survives pod restart |
| Unseal | auto (none) | **real Shamir unseal**, key shares held off-cluster |
| Root token | fixed `root` | generated at `init`, stored off-cluster, revocable |
| Receipts→Vault auth | static token Secret | **Kubernetes auth**: pod SA JWT, ~20m TTL, auto-renewed |
| Static token Secret | required | **removed** |

Manifest: [`k8s/vault/vault-persistent.yaml`](../../k8s/vault/vault-persistent.yaml).
Setup script: [`scripts/setup-vault-transit.sh`](../../scripts/setup-vault-transit.sh).

---

## 1. Deploy persistent Vault

```bash
kubectl apply -f k8s/vault/vault-persistent.yaml
kubectl -n vault rollout status deploy/vault
```

The pod becomes **Ready while still sealed/uninitialised** — that is intentional
(the readiness probe maps the 501/503 health codes to 200) so the Service has
endpoints and you can reach Vault to initialise and unseal it. Signing **fails
closed** until you unseal.

## 2. Initialise (once, ever) and unseal

```bash
# 1/1 Shamir for the single-node demo. Production: -key-shares=5 -key-threshold=3
kubectl -n vault exec deploy/vault -- \
  vault operator init -key-shares=1 -key-threshold=1 -format=json > vault-init.json
chmod 600 vault-init.json
```

`vault-init.json` contains the **unseal key share(s)** and the **root token**.
These are the crown jewels:

- **Never** commit them to git. **Never** store them in a cluster Secret.
- Hold them in your org secrets manager / KMS / HSM / split among operators.
- On this box they live root-only at `/root/vault-init/` (chmod 600) — this is
  the demo custody boundary, *not* production-grade. See §6.

Unseal (required after every Vault start — see §4 for why):

```bash
UNSEAL=$(jq -r '.unseal_keys_b64[0]' vault-init.json)
kubectl -n vault exec deploy/vault -- vault operator unseal "$UNSEAL"
```

## 3. Configure Transit + Kubernetes auth

Run the setup script against the unsealed Vault with the **root token** (or any
token with sufficient policy). It enables the `transit` engine, creates the
`szl-receipts` Ed25519 key, writes the `szl-receipts-sign` policy, enables
**kubernetes** auth, configures `auth/kubernetes/config`, and binds a role to
the receipts ServiceAccount:

```bash
ROOT=$(jq -r '.root_token' vault-init.json)
export VAULT_ADDR=http://127.0.0.1:8200   # via `kubectl -n vault port-forward svc/vault 8200`
export VAULT_TOKEN="$ROOT"
scripts/setup-vault-transit.sh \
  --k8s-auth \
  --k8s-namespace szl-receipts-demo \
  --k8s-sa szl-receipts \
  --k8s-role szl-receipts
```

How the tokenless auth works: the script sets **only** `kubernetes_host` on
`auth/kubernetes/config`. With no `token_reviewer_jwt` and the default
`disable_local_ca_jwt=false`, Vault validates the receipts pod's SA JWT by
calling the TokenReview API **with its own pod SA token**. That is why
`vault-persistent.yaml` grants the Vault ServiceAccount the
`system:auth-delegator` ClusterRole. No reviewer JWT is minted or stored.

## 4. Point szl-receipts at Vault (no static token)

The chart already renders the correct env when `signing.backend=vault` and
`signing.vault.auth.method=kubernetes`, and it does **not** mount any token
Secret in that mode. Helm-managed installs:

```bash
helm upgrade szl-receipts charts/szl-receipts -n szl-receipts-demo --reuse-values \
  --set signing.backend=vault \
  --set signing.vault.address=http://vault.vault.svc.cluster.local:8200 \
  --set signing.vault.auth.method=kubernetes \
  --set signing.vault.auth.role=szl-receipts
```

For a kubectl-applied (non-Helm) live deployment, set the same env in-place:

```bash
kubectl -n szl-receipts-demo set env deploy/szl-receipts-server \
  SZL_SIGNING_BACKEND=vault \
  VAULT_ADDR=http://vault.vault.svc.cluster.local:8200 \
  SZL_VAULT_TRANSIT_MOUNT=transit \
  SZL_VAULT_TRANSIT_KEY=szl-receipts \
  SZL_VAULT_AUTH_METHOD=kubernetes \
  SZL_VAULT_K8S_ROLE=szl-receipts \
  SZL_VAULT_K8S_AUTH_MOUNT=kubernetes
# Delete any leftover static token Secret — it is no longer referenced:
kubectl -n szl-receipts-demo delete secret szl-receipts-vault-token --ignore-not-found
```

The server reads its SA JWT from
`/var/run/secrets/kubernetes.io/serviceaccount/token`, logs in at
`auth/kubernetes/login`, and **re-logs-in automatically** on a 401/403 (token
expiry). Expect `[vault] Transit signer ready (... auth=kubernetes)` in the log.

## 5. Verify (the proof that matters)

```bash
# (a) backend is vault and a public key is published
curl -s http://<receipts>/pubkey            # -> {"backend":"vault", "public_key_pem": "...", ...}

# (b) end-to-end signature verifies offline with the PUBLISHED key
scripts/verify_receipts_ed25519.py --url http://<receipts>   # PAE + Ed25519, PASS

# (c) restart survival
kubectl -n vault rollout restart deploy/vault
kubectl -n vault exec deploy/vault -- vault status   # Sealed: true
kubectl -n vault exec deploy/vault -- vault operator unseal "$UNSEAL"
kubectl -n vault exec deploy/vault -- \
  vault read -format=json transit/keys/szl-receipts   # key still present
curl -s http://<receipts>/pubkey            # same public key -> Transit key survived
```

Tamper check: flip one byte of the receipt payload and the PAE verify must
**FAIL** — the signature is over the canonical DSSEv1 PAE, not the raw body.

## 5b. Auto-unseal on this box (guarded local helper)

§2's unseal is a **manual** step: after every Vault start the pod is sealed and
signing fails closed until a human runs `vault operator unseal`. On the
unattended single-node `uds-szl-demo` box that means a reboot silently breaks
receipt signing. Real auto-unseal normally delegates the seal to a cloud KMS or
a second (Transit) Vault — neither exists on this 2-vCPU air-gapped node — so the
pragmatic option here is a **guarded local helper** that replays the unseal key
from the off-git `init.json` whenever Vault comes back sealed.

**What runs:** `/usr/local/sbin/vault-auto-unseal`, driven by
`vault-auto-unseal.timer` (`OnBootSec=45s`, then every `1min`). Source +
install + verify steps live in
[`box-scripts/vault-auto-unseal`](../../box-scripts/vault-auto-unseal) and its
[README](../../box-scripts/vault-auto-unseal.README.md). It mirrors the
`szl-core-rightsize` / `istiod-fit-strategy` self-heal pattern already on the
box.

The helper:

1. **Guards custody** — refuses unless `/root/vault-init/init.json` is root-only
   (`root:600`); a custody regression fails loud instead of leaking the key.
2. **No-ops when safe** — exits 0 if the cluster is down, Vault is absent, or
   Vault is already unsealed (no API writes, no log spam — safe on a 1-min timer).
   It never auto-*initialises* Vault (init stays a one-time human step).
3. **Unseals** — on `sealed=true initialized=true` it replays the unseal
   share(s) from `init.json` (piped over stdin, never on any command line) up to
   the recorded threshold, then re-checks the result.
4. **Re-establishes the receipts signer** — the receipts server inits its Vault
   signer only at boot, so a pod that started while Vault was sealed stays
   `signed=False` even after Vault unseals. After a successful unseal the helper
   reads the receipts `/pubkey` `signed` flag and, if it is not `True`, **deletes
   the receipts pod** so a fresh one re-inits against the now-unsealed Vault. A
   delete (not `kubectl rollout restart`) is used deliberately: a rolling surge
   cannot schedule a 2nd receipts pod on the 2-vCPU node (it goes Pending
   "Insufficient cpu"); deleting the single replica lets the Deployment recreate
   exactly one pod.

End result: within ~1 min of any Vault restart / box reboot, Vault is unsealed
and `szl-receipts` is signing again (`/pubkey` → `signed:true`, a fresh
`POST /receipt` → `valid:true`) with **no human intervention**.

> **Security caveat.** The unseal key now lives on the same host as Vault, which
> collapses the Shamir "key off the box" boundary on *this* node. That is an
> accepted demo / single-node convenience for unattended recovery — **not**
> production-grade. See §6 for the production posture (KMS / Transit auto-unseal
> so the key never sits next to the sealed data).

## 6. Production hardening (what this demo is NOT)

- **Auto-unseal.** File + Shamir means a human unseal after every restart.
  On this box that gap is closed by a *guarded local helper* (§5b) that replays
  the off-git unseal key — unattended recovery, but the key now sits next to the
  sealed data, so it is a single-node convenience, NOT production-grade. For
  production use **Integrated Storage (raft)** across ≥3 replicas with real
  **auto-unseal** (cloud KMS or a Transit auto-unseal Vault) so restarts are
  hands-off AND the key never sits next to the data. Then §2's manual unseal and
  §5b's local helper both disappear.
- **Unseal-key custody.** Split shares (e.g. 5/3) across operators/KMS; never
  store all shares together; rotate the root token (`vault token revoke`) after
  setup and operate with scoped tokens.
- **TLS.** This listener is `tls_disable = 1` (in-mesh). Terminate TLS at the
  listener or rely on the service mesh's mTLS; for an external Vault, enable the
  listener cert and set `signing.vault.caCertSecret`.
- **Audit.** Enable a Vault audit device (`vault audit enable file`).
