# Receipt Chain Reset Runbook

Reset the in-cluster `szl-receipts` chain to a small, valid, hash-chained
baseline so the receipts server boots to `2/2` fast and stays well under its
512Mi memory limit. Use this when the on-PVC chain has grown large enough to
slow boot/rehydration or threaten the memory budget.

- **Cluster:** `uds-szl-demo` (k3d)
- **Namespace:** `szl-receipts`
- **Deployment:** `szl-receipts-server` (container `receipts-server`, port 8080)
- **Store (PVC):** `szl-receipts-server-store` (RWO, mounted at `/data/receipts`)
- **Script:** `scripts/reset-receipt-chain.sh`

## What it does

1. Reads the current chain size from the live pod (informational).
2. Wipes `*.json` and `.chain_head` from `/data/receipts` on the PVC.
3. **Deletes the pod** (does NOT `kubectl rollout restart`). The deployment is
   `RollingUpdate` on an RWO PVC, so a surge update deadlocks — the new pod
   cannot mount the volume still held by the old one. A plain pod delete lets
   the ReplicaSet recreate a single pod that re-attaches the volume cleanly.
4. Waits for a new Ready pod, which boots to genesis (`chain_index=0`,
   `head=GENESIS`) because the store is empty.
5. Seeds N baseline receipts via `POST /receipt` — the server is the Ed25519
   signer, so each receipt is genuinely signed and hash-chained.
6. Verifies: `/healthz` ok, `/pubkey` signed, `szl_chain_length == N`,
   `szl_chain_valid == 1`.

## Run it

```bash
cd /opt/szl/szl-uds-deployment

# dry run (default) — prints the plan, changes nothing
bash scripts/reset-receipt-chain.sh

# perform the reset (default seed = 3 receipts)
bash scripts/reset-receipt-chain.sh --yes

# custom baseline size
SEED=5 bash scripts/reset-receipt-chain.sh --yes
```

Tunable env vars: `NS`, `DEPLOY`, `CONTAINER`, `SELECTOR`, `STORE`, `PORT`,
`SEED`, `TIMEOUT`. Defaults match the live demo cluster
(`SELECTOR=app.kubernetes.io/name=szl-receipts-server`).

## Verify durability (recommended)

The baseline must survive a pod restart (rehydrate from the PVC head pointer):

```bash
P=$(kubectl get pod -n szl-receipts \
  -l app.kubernetes.io/name=szl-receipts-server \
  -o jsonpath='{.items[0].metadata.name}')
kubectl delete pod -n szl-receipts "$P"
kubectl rollout status deploy/szl-receipts-server -n szl-receipts --timeout=120s

P2=$(kubectl get pod -n szl-receipts \
  -l app.kubernetes.io/name=szl-receipts-server \
  -o jsonpath='{.items[0].metadata.name}')
kubectl logs -n szl-receipts "$P2" -c receipts-server | grep -iE 'rehydr|boot complete'
# expect: Rehydrated from head pointer; chain_index=<N> ... persisted=<N>
#         SZL Receipts boot complete; rehydrated=<N> backend=file signed=True
```

## Gotchas / lessons learned

- **`kubectl exec` heredoc needs `-i`.** Feeding a script to `python3 -` over a
  heredoc silently does nothing without `-i` (stdin is not forwarded);
  `python3 -` reads empty stdin, exits 0, and the seed/verify steps pass
  *vacuously*. The script uses `kubectl exec -i ...` for both. If you adapt it,
  keep the `-i`.
- **Delete the pod; do not rollout-restart.** RWO PVC + RollingUpdate surge =
  the new pod stays `Pending` (volume in use) and the old one never drains.
- **The server is the signer.** Always seed via `POST /receipt`, never by
  writing JSON files directly — direct files would be unsigned and break the
  chain on the next verify. (Do NOT use `operator/scripts/seed-receipts.py`;
  that is an unrelated HMAC-placeholder JSONL seeder.)
- **Transient alerts.** `receipt-chain-watch` / PrometheusRule `SinkDown` may
  fire a single ntfy alert during the brief downtime; both are edge-triggered
  and auto-recover.

## Repeat on the tower

Same procedure. Confirm the selector/namespace match the tower's deployment
(adjust via the env vars above), then run the dry run, then `--yes`, then the
durability check.
