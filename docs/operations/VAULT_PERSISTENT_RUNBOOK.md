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

## 0. Reproducible deploy from the chart (committed — no hand-patching)

> **Read this first.** The Tier-2 vault posture is fully committed; you do **not**
> hand-edit the live Deployment. Two committed artifacts make a from-scratch
> deploy land on `backend=vault` with the correct env, ServiceAccount and Vault
> egress, with **zero** `kubectl set env` / `helm --set`:
>
> - **[`charts/szl-receipts/values-vault.yaml`](../../charts/szl-receipts/values-vault.yaml)**
>   — the committed overlay that flips the chart to `signing.backend=vault` +
>   kubernetes-auth and opens the Vault egress NetworkPolicy / UDS Package rule.
> - **`packages/szl-receipts` zarf component `szl-vault-persistent`**
>   (`required: false`) — deploys persistent Vault + the `vault` namespace as part
>   of the package instead of an ad-hoc `kubectl apply`.
>
> The default `values.yaml` stays `backend=file` on purpose (the airgap
> clean-deploy demo); nothing here changes a default deploy.

End-to-end, from scratch:

```bash
# (a) Persistent Vault via the OPT-IN zarf component (creates ns `vault` first):
zarf package deploy <szl-receipts-package> --components szl-vault-persistent --confirm
#     ...or, outside a packaged flow, the same manifests directly:
#     kubectl apply -f manifests/vault-namespace.yaml -f k8s/vault/vault-persistent.yaml

# (b) One-time init + unseal + transit/k8s-auth bootstrap  -> see sections 2-3.

# (c) Deploy the receipts chart WITH the committed vault overlay (no --set / set env):
helm upgrade --install szl-receipts charts/szl-receipts -n szl-receipts-demo \
  -f charts/szl-receipts/values.yaml \
  -f charts/szl-receipts/values-vault.yaml
```

Confirm the render is reproducible before deploying:

```bash
helm template t charts/szl-receipts -f charts/szl-receipts/values.yaml \
  -f charts/szl-receipts/values-vault.yaml \
  | grep -E 'SZL_SIGNING_BACKEND|VAULT_ADDR|SZL_VAULT_|serviceAccountName: szl-receipts'
# -> backend=vault + all 7 vault env vars + the szl-receipts ServiceAccount.
```

Sections 1-6 below document each step (Vault infra, init/unseal, transit/k8s-auth,
pointing the chart at Vault, verification, production hardening).

## 1. Deploy persistent Vault

Preferred (packaged, reproducible) path is the `szl-vault-persistent` zarf
component (§0), which applies `manifests/vault-namespace.yaml` then
`k8s/vault/vault-persistent.yaml`. The equivalent direct apply:

```bash
kubectl apply -f manifests/vault-namespace.yaml
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

**Committed path (do this).** Deploy the chart with the committed
[`values-vault.yaml`](../../charts/szl-receipts/values-vault.yaml) overlay. It
renders `backend=vault`, the 7 vault/k8s-auth env vars, the `szl-receipts`
ServiceAccount and the Vault egress rule, and mounts **no** token Secret — a
from-scratch deploy needs no further patching:

```bash
helm upgrade --install szl-receipts charts/szl-receipts -n szl-receipts-demo \
  -f charts/szl-receipts/values.yaml \
  -f charts/szl-receipts/values-vault.yaml
```

<details>
<summary>Legacy one-off paths (avoid — not reproducible)</summary>

These predate `values-vault.yaml` and are kept only for adopting a pre-existing
release. Prefer the overlay above; do not introduce new hand-patching.

```bash
# Helm --set (use --reuse-values only when adopting an existing release):
helm upgrade szl-receipts charts/szl-receipts -n szl-receipts-demo --reuse-values \
  --set signing.backend=vault \
  --set signing.vault.address=http://vault.vault.svc.cluster.local:8200 \
  --set signing.vault.auth.method=kubernetes \
  --set signing.vault.auth.role=szl-receipts

# kubectl set env on a kubectl-applied (non-Helm) live Deployment:
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

</details>

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

## 5b. Hands-off auto-unseal helper + canonical unseal-key location

§2 leaves a gap on the unattended single-node box: every Vault restart / reboot
re-seals Vault and signing fails closed until a human unseals it. Until real
auto-unseal (§6) lands, the box runs a **guarded local helper** that closes the
gap and — critically — **alarms when it cannot**.

**Source / install:** `box-scripts/sbin/vault-auto-unseal` +
`box-scripts/systemd/vault-auto-unseal.{service,timer}`, installed by
`box-scripts/install.sh`. The timer fires `OnBootSec=45s` then every `1min`, so a
sealed Vault recovers within ~1 min. The helper is a true no-op when Vault is
already unsealed.

**The single canonical unseal-key file** (this is the one place to look/refresh):

```
/root/vault-init/init.json          # root:600 — unseal share(s) for the LIVE vault-data PVC
```

A legacy duplicate `/root/vault-init.json` exists and is kept in sync by
convention, but the helper reads **only** `/root/vault-init/init.json` so there
is a single source of truth. **If the `vault-data` PVC is ever re-created or
re-initialised, refresh both copies from the new `vault operator init` output.**
A stale `init.json` (carried over from a previous PVC) will not unseal the live
Vault, and that exact mistake once stopped signing silently.

**Key/PVC-mismatch alarm.** The helper does not assume its replay worked. After
replaying the threshold share(s) it re-reads the seal status and verifies the key
actually unsealed *this* Vault. It separates a transient blip (Vault unreadable /
pod mid-restart → retried next tick) from a genuine mismatch (Vault still
reachable + sealed after replaying the full threshold **twice**). On a confirmed
mismatch it pages **ntfy `a11oy-uptime-notify`** (edge-deduped, with a RECOVERED
page once the key works again), logging only a one-way SHA-256 *fingerprint* of
the key — never the key. So a stale key can no longer fail closed in silence.

**Recovery when you get a mismatch page:** the canonical key no longer matches
the live PVC. Confirm the live PVC's identity, check for a stale `init.json`
(and the `/root/vault-init.json` duplicate / any `*.stale-*.bak`), and restore
the correct `vault operator init` output to `/root/vault-init/init.json`
(`chown root && chmod 600`). Only run `vault operator init` again if the PVC is
genuinely new (that destroys the old Transit key + receipt chain — see §6).

This remains a demo/single-node convenience: the key sits next to the sealed
data. Once the box is migrated to OCI KMS auto-unseal (§6a) this helper detects
seal type != shamir and **self-retires** (true no-op), and its timer + the
on-box init.json can be removed.

## 6. Production hardening (what this demo is NOT)

- **Auto-unseal.** File + Shamir means a human unseal after every restart.
  This box now has a FREE real auto-unseal path -- **OCI KMS** (see §6a) --
  which removes the on-box unseal key entirely. For HA also use **Integrated
  Storage (raft)** across ≥3 replicas. Then §2's manual unseal disappears.
- **Unseal-key custody.** Split shares (e.g. 5/3) across operators/KMS; never
  store all shares together; rotate the root token (`vault token revoke`) after
  setup and operate with scoped tokens.
- **TLS.** This listener is `tls_disable = 1` (in-mesh). Terminate TLS at the
  listener or rely on the service mesh's mTLS; for an external Vault, enable the
  listener cert and set `signing.vault.caCertSecret`.
- **Audit.** Enable a Vault audit device (`vault audit enable file`).


## 6a. Free real auto-unseal via OCI KMS (Task #625)

The single-node box originally kept the Shamir unseal key on-box in
`/root/vault-init/init.json`, next to the sealed data -- so a stolen disk/backup
carried both halves. This section moves the box to **real auto-unseal** using
**Oracle Cloud (OCI) KMS**, the one genuinely-free cloud KMS:

  * OCI "Always Free" includes the Vault/KMS service (default Virtual Vault,
    20 key versions, **$0/key, $0 API calls, no time limit**).
  * Vault **community** edition supports `seal "ocikms"` auto-unseal on all
    versions (verified on this box's Vault 1.18.5). Only seal-*wrapping* of
    individual secrets needs Enterprise -- we do not use that.
  * The unseal master key is wrapped by an OCI-held key the box never stores, so
    `init.json` can be deleted from the box.

**One-time OCI setup (free account):**
  1. Create a free OCI account (Always Free; signup needs a card but Always-Free
     resources are never charged).
  2. Identity & Security -> Vault -> create a Vault -> create a Master Encryption
     Key (AES, 256-bit). Copy the **key OCID** and the vault's **crypto** and
     **management** endpoints.
  3. Identity -> your User -> API Keys -> Add API Key (let OCI generate the
     keypair). Download the **private key (.pem)**; note the **fingerprint**,
     **user OCID**, **tenancy OCID**, and **region**.
  4. Build an OCI SDK config file with tenancy/user/fingerprint/region and
     `key_file=/home/vault/.oci/oci_api_key.pem`.

**Migrate (no signing-key loss):**
```
export OCI_KEY_ID=ocid1.key.oc1...
export OCI_CRYPTO_ENDPOINT=https://<prefix>-crypto.kms.<region>.oraclecloud.com
export OCI_MGMT_ENDPOINT=https://<prefix>-management.kms.<region>.oraclecloud.com
export OCI_CONFIG_FILE=/root/oci/config
export OCI_API_KEY_PEM=/root/oci/oci_api_key.pem
scripts/vault-seal-migrate-ocikms.sh
```
The script backs up the full Vault keystore first, mounts the OCI API key as the
`vault-ocikms` Secret, adds the `seal "ocikms"` stanza, runs
`vault operator unseal -migrate` (shamir -> ocikms), then **proves** Vault
auto-unseals across a restart AND that the szl-receipts public key is unchanged
(the Transit signing key lives inside the barrier and is not re-keyed by a seal
change). Seal stanza template: `k8s/vault/vault-seal-ocikms.example.hcl`.

**After migration:**
  * Keep ONE copy of the old Shamir key OFF the box (break-glass recovery key);
    `shred -u` the on-box `/root/vault-init*` copies.
  * `box-scripts/sbin/vault-auto-unseal` detects seal type `!= shamir` and
    self-retires (true no-op); `systemctl disable --now vault-auto-unseal.timer`.
  * Persist the seal stanza in `k8s/vault/vault-persistent.yaml` (keep the OCI
    API key only in the Secret, never in git).

**Sovereign alternative (also free):** run a small Vault on an OCI **Always Free
Ampere A1** VM with the Transit secrets engine and point this box's seal at it
(`seal "transit"`). That keeps the wrapping key under SZL control instead of
Oracle's, at the cost of maintaining a second Vault. Migration mechanics are
identical (`-migrate`); only the seal stanza differs.


## 7. Off-box disaster recovery — the box itself is gone (Task #670)

§4/§5 (`scripts/vault-keystore-backup.sh` + `vault-keystore-restore.sh`) make the
signing key survive a **cluster** recreate, but the snapshot lives only host-local
under `/root/vault-keystore-backup`. If box `167.233.50.75`'s **disk dies**, that
snapshot — and with it the szl-receipts Transit signing key and every receipt's
verifiability — is gone. This section adds a durable **off-box** copy.

### What runs
`box-scripts/sbin/vault-keystore-offbox-backup` + its
`vault-keystore-offbox-backup.{service,timer}` (weekly, `Persistent=true`),
installed/enabled by `box-scripts/install.sh`. Each run refreshes the local
snapshot, packages the latest one, **encrypts it on the box**, ships the
ciphertext off-box, and prunes to the newest `OFFBOX_KEEP` (default 14).

It alerts via ntfy `a11oy-uptime-notify` (edge-triggered) on a configured push
that fails. Until configured it is a safe log-only no-op (never pages). Last-run
state: `/var/lib/vault-keystore-offbox/status.json`. Full reference:
`box-scripts/vault-keystore-offbox-backup.README.md`.

### Security
The snapshot holds the unseal share(s) + root token **and** the encrypted
barrier, so:
- The plaintext tar is built in a root-only `0700` temp dir and **shredded** the
  instant the ciphertext exists. **Only the `*.tar.gz.gpg` ciphertext leaves the
  box.**
- Prefer **asymmetric** GPG (`OFFBOX_GPG_RECIPIENT`): the box holds only the
  recipient *public* key; the *private* key lives off-box, so a box compromise
  cannot decrypt past off-box copies.
- The destination is **still secret** — no plaintext, no shared/public bucket.

### Configure (`/etc/vault-keystore-offbox.env`, PRIVATE, not in git)
`install.sh` seeds a commented-out stub. Set one encryption method + one
destination (see the README for every transport). Asymmetric + a second host:
```sh
# on the box, import only the PUBLIC key whose PRIVATE half you keep off-box:
gpg --import /root/offbox-restore-pubkey.asc
gpg --list-keys                                  # -> OFFBOX_GPG_RECIPIENT
# /etc/vault-keystore-offbox.env:
#   OFFBOX_GPG_RECIPIENT=<key id>
#   OFFBOX_SSH_TARGET=backup@second-host:/srv/szl/vault-keystore
#   OFFBOX_SSH_KEY=/root/.ssh/offbox_backup
sudo systemctl start vault-keystore-offbox-backup.service     # first push now
journalctl -u vault-keystore-offbox-backup --no-pager -n 40
```

### Recover the signing key from the off-box copy (box is gone)
On the **new** box, after installing the toolchain + this repo:
```sh
# 1) Pull the NEWEST off-box artifact + its checksum (transport-specific), e.g.:
scp backup@second-host:/srv/szl/vault-keystore/'vault-keystore-*' ./   # or rclone/aws/local

# 2) Verify integrity, then DECRYPT with the OFF-BOX private key (or passphrase):
ART=$(ls -1t vault-keystore-*.tar.gz.gpg | head -1)
sha256sum -c "$ART.sha256"
gpg --output "${ART%.gpg}" --decrypt "$ART"        # asymmetric: prompts for the off-box private key
#   symmetric fallback: gpg --pinentry-mode loopback --passphrase-file <pass> -o "${ART%.gpg}" -d "$ART"

# 3) Unpack into the canonical local backup dir (the tar's top level is the <ts> snapshot):
mkdir -p /root/vault-keystore-backup
tar xzf "${ART%.gpg}" -C /root/vault-keystore-backup
TS=$(tar tzf "${ART%.gpg}" | head -1 | cut -d/ -f1)
ln -sfn "/root/vault-keystore-backup/$TS" /root/vault-keystore-backup/latest

# 4) Restore the barrier + unseal shares into a freshly-provisioned Vault PVC:
scripts/vault-keystore-restore.sh --backup-dir /root/vault-keystore-backup --from "$TS"
#   (restores /vault/data + /root/vault-init/init.json; the pubkey must match
#   the snapshot's pubkey.txt — that is the proof the signing key is recovered.)

# 5) Shred the decrypted plaintext immediately:
shred -u "${ART%.gpg}"
```
The restored Transit key reproduces the **same** szl-receipts public key, so the
entire historical receipt chain verifies again. Confirm with the receipts server
`/pubkey` endpoint vs `pubkey.txt` in the restored snapshot.
