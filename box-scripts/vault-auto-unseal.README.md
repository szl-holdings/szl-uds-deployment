<!-- Copyright 2026 SZL Holdings / SPDX-License-Identifier: Apache-2.0 -->

# vault-auto-unseal — guarded local auto-unseal + key/PVC-mismatch alarm

Closes the manual-unseal gap left by persistent Vault (file storage + a real 1/1
Shamir seal): after any Vault restart / box reboot the pod comes back **Sealed**
and, until someone runs `vault operator unseal`, `szl-receipts` signing fails
closed. On the unattended single-node `uds-szl-demo` box (167.233.50.75) this
means signing silently breaks. This helper re-unseals Vault automatically, with
no human in the loop — **and pages a human the moment auto-unseal *cannot*
recover signing**, instead of silently retrying a bad key forever.

## Canonical unseal-key location (read this)

There is exactly **one** canonical unseal-key file, and the helper reads only it:

```
/root/vault-init/init.json          # root:600 — the unseal key share(s) for the LIVE vault-data PVC
```

A legacy duplicate `/root/vault-init.json` also exists on this box and is kept in
sync by convention, but the helper deliberately ignores it so there is a single
source of truth. **If the `vault-data` PVC is ever re-created / re-initialised,
both copies must be refreshed from the new `vault operator init` output** — a
stale `init.json` from a previous PVC will no longer unseal the live Vault.

That exact failure happened once (a stale key replayed silently and signing
stopped with nobody notified). The helper now defends against a recurrence — see
*Key/PVC-mismatch alarm* below.

## What it does

1. **Guards custody** — refuses to run unless `/root/vault-init/init.json`
   exists and is root-only (`root:600`). A custody regression fails loud.
2. **No-ops when safe** — resolves the k3d kubeconfig; if the cluster is down or
   Vault is absent it exits 0. If Vault is already unsealed it is a true no-op.
3. **Auto-unseals** — when Vault reports `sealed=true initialized=true`, it
   replays the unseal key share(s) from `init.json` (piped over stdin, never on
   any command line) up to the recorded threshold, then re-checks the result.
4. **Verifies + alarms (Key/PVC-mismatch alarm)** — it does **not** assume the
   key worked. After replaying it re-reads the seal status:
   - unsealed → success (and a RECOVERED page if a mismatch was previously open);
   - still sealed → it distinguishes a *transient* exec blip (Vault unreadable /
     pod mid-restart → retried next tick, no page) from a *genuine* mismatch.
     Only when Vault is still **reachable and sealed after replaying the full
     threshold twice** does it conclude the key does **not** match the live PVC.
     Then it **pages ntfy `a11oy-uptime-notify`** (edge-deduped — one page per
     outage, plus a RECOVERED page when the key works again), logging a one-way
     SHA-256 *fingerprint* of the key (never the key itself).
5. **Observes receipts (read-only)** — after a successful unseal it polls the
   receipts `/pubkey` `signed` flag and logs the outcome. The receipts server
   re-establishes its Vault signer on its own (background watchdog), so the
   helper never deletes or restarts the receipts pod.

It never auto-*initialises* Vault (that is a one-time human step) and never
copies, logs, or persists the unseal key. Paging dedup state lives in
`/var/lib/vault-auto-unseal/` (override via `STATE_DIR` for testing).

## Install (box 167.233.50.75)

Installed by `box-scripts/install.sh`, or directly:

```bash
install -m 0755 box-scripts/sbin/vault-auto-unseal          /usr/local/sbin/vault-auto-unseal
install -m 0644 box-scripts/systemd/vault-auto-unseal.service /etc/systemd/system/vault-auto-unseal.service
install -m 0644 box-scripts/systemd/vault-auto-unseal.timer   /etc/systemd/system/vault-auto-unseal.timer
systemctl daemon-reload
systemctl enable --now vault-auto-unseal.timer
```

The timer fires `OnBootSec=45s` and then every `1min`, so a sealed Vault is
detected and recovered within ~1 minute — the runbook's recovery target. The
push channel comes from `/etc/a11oy-uptime.env` (same as the other watchers); if
it is unset the mismatch alarm logs instead of paging.

## Verify

```bash
# Normal recovery (hands-off): recreate the vault pod so it comes back Sealed.
kubectl -n vault delete pod -l app.kubernetes.io/name=vault     # comes back Sealed
/usr/local/sbin/vault-auto-unseal                               # unseals; receipts self-heals
kubectl -n vault exec deploy/vault -- sh -c 'VAULT_ADDR=http://127.0.0.1:8200 vault status' # Sealed: false

# Mismatch alarm (SAFE test — stop the timer first so it can't unseal with the
# real key, point INIT_JSON at a same-length WRONG key, use a throwaway STATE_DIR
# and a test ALERT_PREFIX). With Vault sealed it must page + write a sig + exit 1,
# a second run must DEDUP, and a run with the real key must unseal + send
# RECOVERED + clear the sig. Always re-`systemctl start vault-auto-unseal.timer`.
```

## Security posture (read this)

The unseal key lives on the same host as Vault, so on **this single node** the
Shamir "key held off the box" boundary is collapsed for the sake of unattended
recovery. This is a demo / single-node convenience, **not** production-grade.
Production must use real auto-unseal (cloud KMS or a Transit auto-unseal Vault)
so the key never sits next to the sealed data — see
`docs/operations/VAULT_PERSISTENT_RUNBOOK.md` §5b and §6.
