# Receipt-chain-watch — second-cluster (uds-tenant) real teardown drill

**Purpose.** Close the deferred literal end-to-end verification of the
`receipt-chain-watch` alarm on a **second** cluster (`uds-tenant`). The
parameterized harness is already verified-ready (proven equivalent on
`uds-szl-demo`), but the literal teardown on a real second cluster could never be
run because `uds-tenant` does not exist and the box (`167.233.50.75`, 2 vCPU /
7.6Gi, ~1.5Gi available even with the 4G swapfile) cannot host a second UDS Core
without OOMing prod. Run this the day a real `uds-tenant` cluster exists.

**Scope / safety.** Reversible. It scales the tenant's receipts sink to 0 then
restores it. It uses the **real** `@uds-tenant` systemd instance, real state
files, and the real ntfy channel, so this fires a genuine (non-test) alert —
expected. It must **not** touch the primary `uds-szl-demo` dedup state; Step 5
asserts that.

---

## Prerequisites (all must hold, else STOP — this test cannot run yet)

1. `uds-tenant` is a real, reachable cluster (external/multi-node, or a local
   k3d cluster named `uds-tenant`).
2. `szl-receipts` (`szl-receipts-server`) is deployed there and the receipt chain
   is advancing (pepr-szl signing + server accepting).
3. You have its kubeconfig on the box.

Quick check (replace the kubeconfig path):

```bash
KCFG=/root/.kube/uds-tenant.config
KUBECONFIG="$KCFG" kubectl get --raw=/readyz && echo READYZ_OK
KUBECONFIG="$KCFG" kubectl -n szl-receipts get deploy szl-receipts-server
KUBECONFIG="$KCFG" kubectl -n pepr-system  get deploy pepr-szl
```

If `/readyz` fails or either deployment is absent, the alarm correctly treats the
cluster as a no-op (`UNKNOWN`) — there is nothing to test yet. **Stop here.**

---

## Step 1 — wire the kubeconfig and confirm baseline OK

```bash
# Point the @uds-tenant instance at the real kubeconfig.
sed -i 's,^#\?KUBECONFIG_FILE=.*,KUBECONFIG_FILE=/root/.kube/uds-tenant.config,' \
  /etc/receipt-chain-watch/uds-tenant.env
grep KUBECONFIG_FILE /etc/receipt-chain-watch/uds-tenant.env

# Reset the edge state to a known-good baseline, then run the real instance once.
echo OK > /var/lib/receipt-chain-watch/uds-tenant.last_status
systemctl start receipt-chain-watch@uds-tenant.service
cat /var/lib/receipt-chain-watch/uds-tenant.status.json   # expect overall":"OK"
tail -n 3 /var/log/receipt-chain-watch/uds-tenant.log     # expect STATE OK
```

**Pass:** `status.json` overall `OK`, reason "receipts chain recording".

## Step 2 — teardown → expect OK→ALERT + real ntfy

```bash
KCFG=/root/.kube/uds-tenant.config
# Record original replica count so it can be restored.
ORIG=$(KUBECONFIG="$KCFG" kubectl -n szl-receipts get deploy szl-receipts-server \
        -o jsonpath='{.spec.replicas}'); echo "orig replicas=$ORIG"

KUBECONFIG="$KCFG" kubectl -n szl-receipts scale deploy szl-receipts-server --replicas=0
KUBECONFIG="$KCFG" kubectl -n szl-receipts rollout status deploy szl-receipts-server --timeout=60s || true

systemctl start receipt-chain-watch@uds-tenant.service
cat /var/lib/receipt-chain-watch/uds-tenant.status.json   # expect overall":"ALERT"
cat /var/lib/receipt-chain-watch/uds-tenant.last_status   # expect ALERT
tail -n 5 /var/log/receipt-chain-watch/uds-tenant.log     # expect EDGE OK->ALERT notified + ntfy delivered
```

**Pass:** `status.json` `ALERT`, `last_status` `ALERT`, log shows
`EDGE OK->ALERT notified`, and a real ntfy lands on the a11oy-uptime channel.

## Step 3 — re-run while down → expect DEDUP (no re-notify)

```bash
systemctl start receipt-chain-watch@uds-tenant.service
tail -n 3 /var/log/receipt-chain-watch/uds-tenant.log     # expect DEDUP still ALERT — no re-notify
```

**Pass:** log shows `DEDUP still ALERT — no re-notify` (no second ntfy).

## Step 4 — restore → expect ALERT→OK RECOVERED

```bash
KCFG=/root/.kube/uds-tenant.config
KUBECONFIG="$KCFG" kubectl -n szl-receipts scale deploy szl-receipts-server --replicas="${ORIG:-1}"
KUBECONFIG="$KCFG" kubectl -n szl-receipts rollout status deploy szl-receipts-server --timeout=120s

# A narrow SINCE proves the recovery edge immediately (same script, real state
# files + real notifier) without waiting for the default 8m window to clear.
CLUSTER=uds-tenant KUBECONFIG_FILE="$KCFG" SINCE=30s \
  /usr/local/sbin/receipt-chain-watch
cat /var/lib/receipt-chain-watch/uds-tenant.status.json   # expect overall":"OK"
tail -n 4 /var/log/receipt-chain-watch/uds-tenant.log     # expect EDGE ALERT->OK recovered, notified
```

**Pass:** `status.json` `OK`, log shows `EDGE ALERT->OK recovered, notified`, and
a real RECOVERED ntfy lands.

## Step 5 — isolation: primary uds-szl-demo dedup untouched

Capture the primary state BEFORE Step 1 and compare AFTER Step 4:

```bash
# BEFORE (run before Step 1):
sha256sum /var/lib/receipt-chain-watch/uds-szl-demo.last_status \
          /var/lib/receipt-chain-watch/uds-szl-demo.status.json > /tmp/primary.before
# AFTER (run after Step 4):
sha256sum /var/lib/receipt-chain-watch/uds-szl-demo.last_status \
          /var/lib/receipt-chain-watch/uds-szl-demo.status.json > /tmp/primary.after
diff /tmp/primary.before /tmp/primary.after && echo "ISOLATION OK (primary unchanged)"
```

> Note: the primary `.status.json` is rewritten every 5 min by its own timer, so
> `checked_at`/content will differ if its timer ran during the drill — that is
> expected and harmless. The invariant that matters is `uds-szl-demo.last_status`
> stays `OK` (no spurious edge). Verify that explicitly:

```bash
cat /var/lib/receipt-chain-watch/uds-szl-demo.last_status   # must remain OK
```

**Pass:** `uds-szl-demo.last_status` is still `OK` and the primary never fired an
edge during the drill.

---

## Verdict

All five steps pass ⇒ the second-cluster receipt alarm is verified end-to-end on
a real `uds-tenant`. Record the result (date + run output) in
`.agents/memory/receipt-chain-watch.md`, replacing the "verified-ready / literal
teardown still blocked" notes with "literally verified on uds-tenant YYYY-MM-DD".

If any step fails, the alarm — not the drill — needs attention; inspect
`/var/log/receipt-chain-watch/uds-tenant.log` and the pepr-szl / receipts-server
logs on the tenant cluster.
