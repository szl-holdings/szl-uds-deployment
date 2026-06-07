# szl-receipts — UDS Core Keycloak SSO gating

Status: **wired & validated by construction; default OFF.** Live Keycloak login
must be exercised on the tower (see Ceiling).

## Goal

Make `szl-receipts` a UDS-identity citizen: the **human** UI/API is gated behind
UDS Core Keycloak (Authservice + Istio), while the in-cluster Pepr admission
webhook (`POST /receipt`) stays machine-to-machine and never depends on Keycloak.

## Why a two-workload split

UDS Core's authservice runs as an ambient Istio waypoint. Any pod selected by
`enableAuthserviceSelector` has every request — **including in-mesh,
pod-to-pod traffic** — intercepted and bounced to the Keycloak login flow.
If we put that selector on `szl-receipts-server`, the Pepr webhook's
`POST /receipt` would also get redirected to a browser login and the receipt
chain would break. So the chart splits the surface in two:

| Workload | Role | SSO off | SSO on |
|----------|------|---------|--------|
| `szl-receipts-server` | machine chain authority; serves the receipt API and accepts the Pepr webhook | ClusterIP, gateway-exposed | ClusterIP, **not** gateway-exposed, **never** authservice-selected |
| `szl-receipts-ui` (nginx reverse-proxy) | human-facing surface in front of the server API | not created | created, gateway-exposed, **authservice-selected** |

The Pepr webhook `allow` rule (ingress to `szl-receipts-server` :8080) is
**always present, in both states** — the machine path is independent of SSO.
When SSO is on, an additional `allow` lets the UI proxy read the server API
in-mesh.

## How to enable

In `charts/szl-receipts/values.yaml`:

```yaml
udsPackage:
  sso:
    enabled: true          # flips server→UI exposure + creates the UI proxy + emits the sso block
    name: "SZL Receipts"
    clientId: "szl-receipts"
    secretName: szl-receipts-sso
    groups: {}             # optional Keycloak group gating
```

When `enabled: true` the UDS Operator reads `spec.sso` from the Package CR and
auto-creates the Keycloak client + injects the authservice sidecar in front of
pods matching `app: szl-receipts-ui` only.

The browser FQDN follows the existing expose settings
(`udsPackage.expose.host` + `.gateway`). On the single-node demo the admin
gateway resolves to `receipts.admin.uds.dev`; `redirectUris` /
`webOrigins` are derived from that.

## Validation evidence (on box 167.233.50.75, cluster `uds-szl-demo`)

Tooling: `uds zarf tools helm` v4.2.0 (NOT `/usr/local/bin/helm`).

- `helm lint .` → 0 charts failed.
- `helm template` **SSO off** → 1 Package, exposes `szl-receipts-server`,
  1 Deployment, Pepr webhook allow present, no `sso` block, no UI workload.
  (Identical to the proven pre-change render — no regression.)
- `helm template` **SSO on** → 1 Package with `sso` block
  (`clientId: szl-receipts`, `standardFlowEnabled: true`,
  `redirectUris: https://receipts.admin.uds.dev/*`,
  `enableAuthserviceSelector → app: szl-receipts-ui`), exposes
  `szl-receipts-ui` only (server **not** browser-reachable), Pepr webhook allow
  **still present** + UI→server allow, 2 Deployments (server + UI proxy).
- `kubectl apply --dry-run=server` of the SSO-on Package CR →
  `package.uds.dev/szl-receipts configured (server dry run)` — the `sso`
  block is **schema-valid against the installed uds-core CRD (v1.5.0)**.

## Ceiling: live login not bootable on this box

This is the a11oy box: **2 vCPU / 7.6 GB, no GPU.** The `keycloak` and
`authservice` namespaces exist but have **zero workloads**, and the node is
already overcommitted (~2410m CPU requested vs 2000m capacity: istiod 500m,
Pepr ×5 = 1000m, a second istiod stuck Pending). Booting Keycloak + Postgres +
authservice on top of that is not feasible here. Therefore SSO is shipped
**gated and default-off**, validated by render + server-side CRD dry-run, and
the **live end-to-end browser login proof belongs on the tower** (a host with
CPU headroom to run UDS Core's identity stack). Flip `sso.enabled: true` there,
`uds zarf package deploy` / `helm upgrade`, and complete the login walk-through.

## Files

- `charts/szl-receipts/values.yaml` — `udsPackage.sso.*` + `ui.*`
- `charts/szl-receipts/templates/uds-package.yaml` — conditional `sso` block,
  conditional expose target, always-on Pepr allow, conditional UI→server allow
- `charts/szl-receipts/templates/ui.yaml` — gated nginx reverse-proxy
  (ConfigMap + Deployment + Service), restricted-PSS compliant
