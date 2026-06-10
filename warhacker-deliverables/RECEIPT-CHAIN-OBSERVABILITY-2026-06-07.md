# Receipt Chain Observability — Prometheus metrics + Grafana dashboard (Task #129)

**Date:** 2026-06-07
**Repo:** `szl-holdings/szl-uds-deployment`
**Cluster:** `uds-szl-demo` (k3d, single node, on `167.233.50.75`)

## Goal

Make the receipt chain visible in UDS Core's native Prometheus + Grafana:
real server-driven metrics, a ServiceMonitor Core discovers, and a Grafana
dashboard auto-imported via Core's sidecar mechanism — then move it with a
**real** deny and a **real** tamper. Tamper proof on the **Ed25519** path, not
the HMAC `demo:verify`.

## What changed (durable, in source)

1. **`services/szl-receipts-server/server.py`** — real, server-driven `/metrics`
   (marker `# SZL-METRICS-129`). No synthetic series. On every scrape the server
   runs an at-rest chain integrity scan and exports:
   - `szl_receipts_total` (counter) — receipts received
   - `szl_receipts_valid_total` (counter) — verified at append time
   - `szl_receipts_allow_total` / `szl_receipts_deny_total` (counters) — real
     governance verdicts read from each receipt payload (`verdict` field)
   - `szl_receipts_tamper_total` (counter) — persisted receipts found
     tampered/invalid at rest (counted once per id, monotonic)
   - `szl_chain_index` (gauge) — chain head pointer
   - `szl_chain_length` (gauge) — receipts persisted
   - `szl_chain_valid` (gauge) — 1 intact / 0 tamper detected
   The integrity scan re-verifies each receipt's **Ed25519** signature over the
   canonical DSSE PAE, its stored hash, and the `prev_hash` linkage.

2. **`charts/szl-receipts/templates/service.yaml`** — added a bare
   `app: szl-receipts-server` label so the UDS-operator-generated ServiceMonitor
   (Package `spec.monitor` selector `app: szl-receipts-server`) actually matches
   the Service. Previously the Service only carried `app.kubernetes.io/*` labels,
   so the operator's monitor selected nothing.

3. **`charts/szl-receipts/templates/grafana-dashboard.yaml`** (new) +
   **`charts/szl-receipts/dashboards/szl-receipts.json`** (new) — a ConfigMap
   labeled `grafana_dashboard: "1"` so UDS Core's Grafana **sidecar**
   auto-imports the dashboard (no manual import, no Grafana API). Panels: chain
   integrity (INTACT/TAMPERED), chain length, total receipts, tamper events,
   chain growth over time, ALLOW vs DENY verdicts, chain-valid over time, tamper
   over time. Gated on `.Values.dashboard.grafana.enabled` (default on).

4. **`charts/szl-receipts/values.yaml`** — new `dashboard.grafana` block
   (`enabled`, `folder`, `sidecarLabel`, `namespace`).

5. **Removed `charts/szl-receipts/templates/servicemonitor.yaml`** — it
   duplicated the UDS-native Package `spec.monitor` (the operator already
   generates a ServiceMonitor) and documented metric names the server never
   exports. Consolidated to the single operator-managed monitor.

6. **`charts/szl-receipts/Chart.yaml`** — `version 0.4.0 → 0.5.0`,
   `appVersion 0.2.0 → 0.3.0`.

## Live proof — metrics move on a real deny + real tamper

Ran the **patched** server standalone with a real ephemeral Ed25519 key
(`SZL_SIGNING_BACKEND=file`), drove 3 real verdicts, then tampered a stored
receipt on disk.

```
POST uav-1 ALLOW (permitted-sf-bay alt 80)   -> chain_index 0
POST uav-2 ALLOW (permitted-sf-bay alt 95)   -> chain_index 1
POST uav-3 DENY  (R-2508 alt 120, G7 geofence) -> chain_index 2

/metrics BEFORE tamper:
  szl_receipts_total        3
  szl_receipts_allow_total  2
  szl_receipts_deny_total   1      <- real DENY moved the counter
  szl_receipts_tamper_total 0
  szl_chain_index           3
  szl_chain_length          3
  szl_chain_valid           1      <- chain intact

REAL TAMPER: altitude_m 95 -> 96 inside uav-2's signed payload on disk

/metrics AFTER tamper:
  szl_chain_valid           0      <- flipped to TAMPERED
  szl_receipts_tamper_total 1      <- tamper counter moved
```

**Independent offline Ed25519 verification** (no server, no HMAC) of the stored
receipts after the tamper:

```
  8cbf680feef6.. TAMPERED-REJECTED   <- the edited receipt
  99bc72252c7e.. VALID
  bd23950b1b6c.. VALID
offline Ed25519 verify: 2 valid, 1 rejected
```

The tamper is caught by the Ed25519 signature failing over the canonical DSSE
PAE — exactly the path an offline auditor uses. HMAC `demo:verify` is not
involved.

## Live cluster wiring (discovery proven)

After a chart re-deploy, the namespace shows the native-UDS monitor path wired:

```
package.uds.dev/szl-receipts  Ready  MONITORS=["szl-receipts-szl-receipts-prometheus-metrics"]
Package spec.monitor: selector {app: szl-receipts-server}, portName http, path /metrics, targetPort 8080
service/szl-receipts-server   labels include app=szl-receipts-server   (selector now matches)
pod/szl-receipts-server-...   2/2 Running
```

The UDS operator generates the ServiceMonitor from the Package `spec.monitor`,
and with the new Service label the monitor's selector matches the Service —
discovery is correctly wired.

## Honest ceiling — what could NOT be shown live here

- **UDS Core's Prometheus and Grafana are not running on this box.** Core 1.5.0
  deployed only `prometheus-operator-crds` (the CRDs); the full
  kube-prometheus-stack (Prometheus server + Grafana) is not up. The box is
  2 vCPU / ~7.6 GB and already runs two k3d clusters, so the monitoring stack
  cannot be brought up here.
- Therefore the "target shows **UP** in Prometheus" and "dashboard renders in
  Grafana" steps cannot be demonstrated on this box. They are wired correctly
  (ServiceMonitor generated + selector matches the Service; dashboard ConfigMap
  carries the sidecar label and validates server-side via
  `kubectl apply --dry-run=server`) and will activate as soon as the chart is
  deployed onto a cluster running Core's monitoring stack (the rehearsal
  laptop / a larger node).
- The running cluster currently serves a **pre-built** package, so the live
  ServiceMonitor set still includes leftover/duplicate monitors from the older
  chart. The duplicate-removal + Service-label fix land on the next package
  rebuild from source.
- The image must be **rebuilt** (`Dockerfile` `COPY server.py`) for the new
  metrics to ship in the deployed pod — that's the deploy/build task, not this
  one.

## Validation performed

- `python3 -m py_compile server.py` — OK
- `python3 -m json.tool dashboards/szl-receipts.json` — valid JSON
- Dashboard ConfigMap `kubectl apply --dry-run=server` — accepted by the live API
- Live standalone metrics proof (above) — deny + Ed25519 tamper both move the series
