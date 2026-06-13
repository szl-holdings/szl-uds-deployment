# Receipt Chain Reset Runbook

Reset the in-cluster `szl-receipts` chain to a small, valid, hash-chained
baseline so the receipts server boots to `2/2` fast and stays well under its
512Mi memory limit. Use this when the on-PVC chain has grown large enough to
slow boot/rehydration or threaten the memory budget.

- **Cluster:** `uds-szl-demo` (k3d) — and the on-site **tower** (see below)
- **Namespace:** `szl-receipts`
- **Deployment:** `szl-receipts-server` (container `receipts-server`, port 8080)
- **Store (PVC):** `szl-receipts-server-store` (RWO, mounted at `/data/receipts`)
- **Script:** `scripts/reset-receipt-chain.sh`

## What it does

1. Reads the current chain size from the live pod (informational). Counts both
   the legacy flat-root receipts and the sharded layout (see "Sharding" below).
2. Wipes `*.json`, `.chain_head`, **and** the `shards/` tree from
   `/data/receipts` on the PVC.
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
`SEED`, `TIMEOUT`, `KCONTEXT`. Defaults match the live demo cluster
(`SELECTOR=app.kubernetes.io/name=szl-receipts-server`). Set `KCONTEXT` to drive
a non-current cluster without `kubectl config use-context`.

## Sharding (why the wipe clears `shards/` too)

The receipts server writes new receipts under `<store>/shards/<bucket>/` once the
chain grows past `SZL_RECEIPT_SHARD_SIZE` (default `10000`); below that, or with
an image that predates sharding, receipts sit flat at the store root. A *bloated*
chain — the exact reason you'd run a reset — is therefore almost always sharded.
The script counts (`find … -name '*.json'`) and wipes (`rm -rf $STORE/shards`)
both layouts, so it lands the same empty store regardless of size. An older copy
of the script only touched `$STORE/*.json` and would silently leave the sharded
bulk of the chain behind — re-pull `scripts/reset-receipt-chain.sh` if yours
predates this note.

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
  the new pod stays `Pending` (volume in use) and the old one never drains. On a
  multi-node cluster the surge pod can also land on a node that cannot attach the
  RWO volume — same deadlock. Deleting the single pod is node-agnostic.
- **The server is the signer.** Always seed via `POST /receipt`, never by
  writing JSON files directly — direct files would be unsigned and break the
  chain on the next verify. (Do NOT use `operator/scripts/seed-receipts.py`;
  that is an unrelated HMAC-placeholder JSONL seeder.)
- **Transient alerts.** `receipt-chain-watch` / PrometheusRule `SinkDown` may
  fire a single ntfy alert during the brief downtime; both are edge-triggered
  and auto-recover.

## Repeat on the tower

The **tower** is the on-site Warhacker event machine (multi-core, RTX-class). It
is NOT remotely reachable from the demo box or the build environment — its
cluster only exists when the operator brings it up on site, so the live tower run
is a hands-on step. The procedure itself is identical; before running, confirm
the tower's names match the defaults and target the tower's kube-context.

1. Point at the tower's cluster (either switch context or pass `KCONTEXT`):

   ```bash
   kubectl config get-contexts                 # find the tower context name
   export KCONTEXT=<tower-context>             # script appends --context to all calls
   ```

2. Confirm the tower's deployment name, namespace, container, and selector
   (adjust the `NS`/`DEPLOY`/`CONTAINER`/`SELECTOR` env vars if any differ):

   ```bash
   kubectl --context "$KCONTEXT" -n szl-receipts get deploy
   kubectl --context "$KCONTEXT" -n szl-receipts get pods --show-labels
   kubectl --context "$KCONTEXT" -n szl-receipts get deploy szl-receipts-server \
     -o jsonpath='{.spec.template.spec.containers[*].name}{"\n"}'
   ```

3. Dry-run, then perform the reset, then run the durability check:

   ```bash
   KCONTEXT="$KCONTEXT" bash scripts/reset-receipt-chain.sh          # dry-run
   KCONTEXT="$KCONTEXT" bash scripts/reset-receipt-chain.sh --yes    # reset
   # durability: delete pod, confirm rehydration logs (commands above, add --context)
   ```

If the tower runs a sharding-enabled image with a large chain, the wipe clears
`$STORE/shards/` as well (see "Sharding"). On a multi-node tower the pod-delete
step is what keeps the RWO PVC from deadlocking the rollout.

### Status

- **Proven on `uds-szl-demo`** (k3d, the demo box). Re-verified live **2026-06-13**:
  dry-run → `--yes` → durability (pod-delete + rehydrate). Wiped a 6-receipt chain
  (flat root **plus** a `shards/00000000` bucket — confirming the shard-aware wipe
  clears both layouts) → rebooted to genesis → seeded 3 server-signed receipts:
  `szl_chain_length=3`, `szl_chain_valid=1`, `/pubkey signed=True`
  (`keyid=szl-receipts-ed25519-2026`), `/healthz ok`. Pod-delete then rehydrated
  from the head pointer: `chain_index=3 persisted=3 rehydrated=3 backend=file
  signed=True`.
- **Tower:** still **pending on-site execution**. The tower is the physical on-site
  Warhacker event machine — it has no remote kubeconfig and is not a tailnet peer,
  so it is unreachable from the demo box / build environment. A live tower run is a
  hands-on operator step and is **not fabricated here** (honesty doctrine). The
  script is parameterized (`KCONTEXT` + the `NS`/`DEPLOY`/… vars) and shard-correct,
  so it carries over to the tower without code changes: run the discovery commands
  above to confirm NS/DEPLOY/CONTAINER/SELECTOR, then
  `KCONTEXT=<tower-context> bash scripts/reset-receipt-chain.sh` (dry-run) → `--yes`
  → the durability check.
