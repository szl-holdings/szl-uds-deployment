<!-- Copyright 2026 SZL Holdings / SPDX-License-Identifier: Apache-2.0 -->

# vault-auto-unseal — guarded local auto-unseal for the szl-receipts Vault

Closes the manual-unseal gap left by persistent Vault (file storage + real
Shamir seal): after any Vault restart / box reboot the pod comes back **Sealed**
and, until someone runs `vault operator unseal`, `szl-receipts` signing fails
closed. On the unattended single-node `uds-szl-demo` box this means signing
silently breaks. This helper re-unseals Vault and re-establishes the receipts
signer automatically, with no human in the loop.

## What it does

1. **Guards custody** — refuses to run unless `/root/vault-init/init.json`
   exists and is root-only (`root:600`). A custody regression fails loud.
2. **No-ops when safe** — resolves the k3d kubeconfig; if the cluster is down or
   Vault is absent it exits 0. If Vault is already unsealed it is a true no-op.
3. **Auto-unseals** — when Vault reports `sealed=true initialized=true`, it
   replays the unseal key share(s) from `init.json` (piped over stdin, never on
   any command line) up to the recorded threshold, then re-checks the result.
4. **Re-inits receipts** — the receipts server initialises its Vault Transit
   signer only at boot, so a pod that booted while Vault was sealed stays
   `signed=False` forever. After a successful unseal the helper checks the
   receipts `/pubkey` `signed` flag and, if it is not `True`, deletes the
   receipts pod (a delete, not a rolling restart — a surge can't schedule on the
   2-vCPU node) so a fresh pod re-inits against the now-unsealed Vault.

It never auto-*initialises* Vault (that is a one-time human step) and never
copies, logs, or persists the unseal key.

## Install (box 167.233.50.75)

```bash
install -m 0755 box-scripts/vault-auto-unseal            /usr/local/sbin/vault-auto-unseal
install -m 0644 box-scripts/vault-auto-unseal.service    /etc/systemd/system/vault-auto-unseal.service
install -m 0644 box-scripts/vault-auto-unseal.timer      /etc/systemd/system/vault-auto-unseal.timer
systemctl daemon-reload
systemctl enable --now vault-auto-unseal.timer
```

The timer fires `OnBootSec=45s` and then every `1min`, so a sealed Vault is
detected and recovered within ~1 minute — the runbook's recovery target.

## Verify

```bash
# Simulate a restart and watch it recover hands-off:
kubectl -n vault rollout restart deploy/vault           # comes back Sealed
/usr/local/sbin/vault-auto-unseal                        # unseals + re-inits receipts
# Proof signing resumed:
RPOD=$(kubectl -n szl-receipts-demo get pods -l app.kubernetes.io/name=szl-receipts-server -o jsonpath='{.items[0].metadata.name}')
kubectl -n szl-receipts-demo exec $RPOD -- python3 -c \
  'import json,urllib.request as u;print(json.load(u.urlopen("http://127.0.0.1:8080/pubkey")).get("signed"))'   # -> True
```

## Security posture (read this)

The unseal key lives on the same host as Vault, so on **this single node** the
Shamir "key held off the box" boundary is collapsed for the sake of unattended
recovery. This is a demo / single-node convenience, **not** production-grade.
Production must use real auto-unseal (cloud KMS or a Transit auto-unseal Vault)
so the key never sits next to the sealed data — see
`docs/operations/VAULT_PERSISTENT_RUNBOOK.md` §6.
