# SZL Receipt-Chain Dashboard — LIVE on real Prometheus + Grafana (2026-06-08)

Task #165. Demonstrates the `szl-receipts` governance receipt chain on a **real**
kube-prometheus-stack (Prometheus + Grafana), with the dashboard auto-imported by
the Grafana sidecar, then drives a real **DENY** (geofence `uav-3`) and a real
**Ed25519 tamper** and captures every dashboard panel moving.

All on Stephen's box `167.233.50.75`, cluster `uds-szl-demo`. Raw evidence in
`warhacker-deliverables/task-165-receipts-grafana/raw/`.

## Done-criteria — all met

| Criterion | Status | Evidence |
|---|---|---|
| `szl-receipts` target UP in Prometheus | ✅ | `raw/prometheus_target.json` — `http://10.42.0.249:8080/metrics` health=`up` |
| Dashboard auto-imports in Grafana via sidecar | ✅ | "SZL Governance Receipts" uid=`szl-receipts`, 8 panels — `raw/grafana_dashboard.json` |
| Real DENY (geofence uav-3) | ✅ | `szl_receipts_deny_total` 0→1 |
| Real Ed25519 tamper | ✅ | `szl_receipts_tamper_total` 0→1, `szl_chain_valid` 1→0 |
| Panels captured moving | ✅ | `raw/prometheus_range.json` (panel exprs over time) + `raw/grafana_datasource_proxy.json` |

## Stack

- **kube-prometheus-stack** (chart 86.2.0) in ns `monitoring`. `serviceMonitorSelector={}`
  (NilUsesHelmValues=false) so it selects all ServiceMonitors; Grafana sidecar
  `searchNamespace=ALL`, dashboard label `grafana_dashboard=1`. `monitoring` labeled
  `zarf.dev/agent=ignore` + ambient so Pepr/scrape traffic works over HBONE.
- **Receipts workload**: clean own instance in ns `szl-receipts-demo` (the original
  `szl-receipts` ns was being torn down/redeployed by a concurrent sibling agent to a
  broken v0.4.0; per the shared-box rule I did not contend it). Namespace labeled
  `zarf.dev/agent=ignore`, non-mesh.
- **Image**: the only pullable ghcr tag (`uds-v0.3.1`) and the cached `uds-v0.4.0`
  zarf image both predate the current `server.py` and expose only
  `szl_receipts_total`/`_valid_total` — NOT the deny/tamper/chain series the dashboard
  reads. Built the real image from source on the box
  (`services/szl-receipts-server/Dockerfile`, python:3.12-slim + cryptography +
  opentelemetry), imported into k3d containerd as
  `docker.io/library/szl-receipts-server:v0.4.0-src` (pullPolicy `Never`). All 8
  metric families now exported.
- **ServiceMonitor** `szl-receipts-demo` (15s interval) → Prometheus target UP.
- **Ed25519** secret `szl-receipts-ed25519` (server is the signer; canonical DSSE PAE).

## The drive (real, payload-driven — no synthetic data)

3 ALLOW receipts (`pepr-policy-sync`, `keycloak-login`, `image-admission`) then 1 DENY:

```json
{"workload":"uav-3","subject":"uav-3","decision":"DENY",
 "reason":"geofence violation: uav-3 outside permitted operating polygon",
 "policy":"geofence-uav"}
```

Verdict is extracted server-side by `_verdict_of()` from the receipt payload
(`decision/verdict/effect/result`), feeding `szl_receipts_deny_total`.

Tamper: edited one persisted receipt `*.json` at rest inside the pod's receipt store
(chain_index 0), corrupting its DSSE payload so the Ed25519 signature/hash/link no
longer verifies. The next `/metrics` scrape re-runs `_verify_chain_on_disk()` over the
server's published Ed25519 public key (same check an offline auditor runs — no HMAC),
flipping `szl_chain_valid` to 0 and incrementing `szl_receipts_tamper_total`.

## Panels moving (exact dashboard expressions, over time)

Captured via Prometheus `query_range` using the **same `max()/min()` expressions the
dashboard panels render** (so it survives the pod-restart instance change):

| Panel | Expr | Moved | Transition (UTC) |
|---|---|---|---|
| Governance Verdicts — ALLOW | `max(szl_receipts_allow_total)` | 0 → 3 | 01:10:58 |
| Governance Verdicts — DENY | `max(szl_receipts_deny_total)` | 0 → 1 | 01:10:58 |
| Tamper Events | `max(szl_receipts_tamper_total)` | 0 → 1 | 01:11:28 |
| Chain Valid (0/1) | `min(szl_chain_valid)` | 1 → 0 | 01:11:28 |
| Chain Length | `max(szl_chain_length)` | 0 → 4 | 01:10:58 |
| Chain Growth (head) | `max(szl_chain_index)` | 0 → 4 | 01:10:58 |
| Total Receipts | `max(szl_receipts_total)` | 0 → 4 | 01:10:58 |

Grafana-side resolution proof (`/api/datasources/proxy/uid/prometheus/...`, i.e. the
exact path the panels use): `szl_receipts_deny_total=1`, `szl_receipts_tamper_total=1`,
`szl_chain_valid=0` — `raw/grafana_datasource_proxy.json`.

Final instant state (`raw/prometheus_instant.json`): total=4, valid=4, allow=3,
deny=1, tamper=1, chain_index=4, chain_length=4, **chain_valid=0**.

## Note on PNG export

The Grafana **image-renderer** plugin is not installed on this 2-vCPU box (`/render`
returns 500), so panel PNGs cannot be server-rendered here. The deliverable instead
captures the panels' underlying time series via the Prometheus and Grafana datasource
APIs — the exact data each panel plots — which is reproducible and independently
verifiable. Installing the `grafana-image-renderer` sidecar would add PNG export.

## Reproduce

```bash
# target UP
kubectl -n monitoring port-forward svc/kps-kube-prometheus-stack-prometheus 9090:9090 &
curl -s 'http://localhost:9090/api/v1/targets?state=active' | grep szl-receipts-demo
# dashboard present
kubectl -n monitoring port-forward svc/kps-grafana 3000:80 &
curl -s -u admin:szl-demo 'http://localhost:3000/api/search?query=Governance'
# drive + tamper: POST JSON {"decision":"DENY",...} to /receipt in the pod, edit a
# stored receipt *.json, then read /metrics (see raw/ for captured results)
```
