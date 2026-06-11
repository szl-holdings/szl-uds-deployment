# SZL UDS Deployment — Install Guide

**One-page setup. Target time: 90 seconds on a laptop with Docker running.**

---

## Prerequisites

| Tool | Version | Install |
|------|---------|---------|
| Docker | 24+ | https://docs.docker.com/get-docker/ |
| k3d | 5.6+ | https://k3d.io/v5.6.0/#installation |
| uds CLI | 0.19+ | https://github.com/defenseunicorns/uds-cli/releases |
| zarf CLI | 0.43+ | https://github.com/zarf-dev/zarf/releases |
| Defense Unicorns registry account | (free) | https://registry.defenseunicorns.com — see "UDS Core registry login" below |

> **Required before `uds run start` / `uds run bundle`.** The bundle pulls UDS Core
> from `registry.defenseunicorns.com/public/core:1.5.0-upstream`. That registry is
> **not anonymous** — it answers `WWW-Authenticate: Basic` and an unauthenticated
> pull returns `401` (`uds create` then fails with
> `GET .../core/manifests/1.5.0-upstream: basic credential not found`). A **free**
> Defense Unicorns registry account is an environment prerequisite, the same way
> Docker/k3d/uds/zarf are. See **UDS Core registry login** below.

**Quick install (macOS/Linux):**

```bash
# k3d
curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash

# uds CLI
curl -fsSL https://github.com/defenseunicorns/uds-cli/releases/download/v0.32.0/uds-cli_v0.32.0_Linux_amd64 \
  -o /usr/local/bin/uds && chmod +x /usr/local/bin/uds

# zarf CLI
curl -fsSL https://github.com/zarf-dev/zarf/releases/download/v0.77.0/zarf_v0.77.0_Linux_amd64 \
  -o /usr/local/bin/zarf && chmod +x /usr/local/bin/zarf
```

Or let the tasks handle it:

```bash
uds run install-deps
```

---

## UDS Core registry login (required)

The bundle pulls UDS Core from `registry.defenseunicorns.com/public/core`, which
requires a **free** Defense Unicorns registry account (HTTP Basic auth — there is
no anonymous pull). Do this **once per build box**, before `uds run start` or
`uds run bundle`:

1. Create a free account at https://registry.defenseunicorns.com (use the
   "Sign in / Sign up" flow). Generate a CLI / robot token if the registry offers
   one; otherwise use your account username + password.
2. Log the build box in. Either tool works (both write `~/.docker/config.json`,
   which `zarf`/`uds` read):

   ```bash
   # via zarf (recommended — same credential store uds uses)
   echo "$DU_REGISTRY_TOKEN" | zarf tools registry login registry.defenseunicorns.com \
     -u "$DU_REGISTRY_USERNAME" --password-stdin

   # …or via docker
   echo "$DU_REGISTRY_TOKEN" | docker login registry.defenseunicorns.com \
     -u "$DU_REGISTRY_USERNAME" --password-stdin
   ```

3. Verify the credential resolves the core manifest:

   ```bash
   zarf tools registry digest registry.defenseunicorns.com/public/core:1.5.0-upstream
   # prints a sha256:… digest on success; a 401 means the login did not take
   ```

> Without this login, `uds run start` / `uds run bundle` fail at the `uds create`
> step with `... core/manifests/1.5.0-upstream: basic credential not found`. This
> is an environment prerequisite, not a repo defect — the bundle ref is correct.

---

## Deploy

```bash
# Clone the repo
git clone https://github.com/szl-holdings/szl-uds-deployment.git
cd szl-uds-deployment

# One-time: log in to the Defense Unicorns registry (see section above)
# zarf tools registry login registry.defenseunicorns.com -u <user> --password-stdin

# Bootstrap + deploy everything (k3d cluster + uds-core + szl-receipts)
uds run start
```

This runs in approximately 90 seconds and:

1. Creates a k3d cluster named `uds-szl-demo`
2. Builds the `szl-receipts` Zarf package (images bundled, air-gap ready)
3. Creates the UDS bundle
4. Deploys: `uds-k3d-dev` → `zarf-init` → `uds-core-slim-dev` → `szl-receipts`
5. Registers the Pepr admission webhook

---

## Access the Dashboard

```bash
# Port-forward the receipts server
uds run port-forward
# Dashboard: http://localhost:8443

# Or directly:
kubectl port-forward svc/szl-receipts-server 8443:8443 -n szl-receipts
```

If running with UDS ingress on a machine with `/etc/hosts` entries:

```
127.0.0.1 szl.uds.dev
```

Then open: `https://szl.uds.dev`

---

## Demo Commands

```bash
# Spin up a sample agentic workload (triggers receipt emission)
uds run demo:workload

# Post-demo: verify the receipt chain pulled from the cluster
uds run demo:verify

# Reset — delete demo workload namespace
uds run demo:reset

# Tear down the entire cluster
uds run teardown
```

---

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `SZL_HMAC_KEY` | (demo key) | Base64-encoded HMAC-SHA-256 signing key |
| `SZL_RECEIPTS_URL` | `http://szl-receipts-server.szl-receipts.svc:8443/receipt` | In-cluster receipts endpoint |
| `SZL_RECEIPT_FAIL_OPEN` | `true` | If `false`, admission blocked when receipts server unreachable |
| `SZL_LOG_LEVEL` | `info` | Log verbosity (`debug`, `info`, `warn`, `error`) |

Override at deploy time:

```bash
uds run start -- --set RECEIPT_HMAC_KEY=$(echo -n "your-production-key" | base64)
```

---

## Air-Gap Notes

The Zarf package bundles all container images. To deploy in an air-gapped environment:

```bash
# On a connected machine: build and push to a registry
zarf package create . --confirm
zarf package publish szl-receipts-0.1.0-*.tar.zst oci://your-internal-registry/szl

# On air-gapped machine: pull from internal registry
uds deploy oci://your-internal-registry/szl/szl-receipts:0.1.0 --confirm
```

---

## Troubleshooting

**Cluster won't start:**
```bash
k3d cluster delete uds-szl-demo && uds run start
```

**Receipts not appearing in dashboard:**
```bash
# Check Pepr webhook is registered
kubectl get mutatingwebhookconfigurations | grep pepr

# Check Pepr logs
kubectl logs -l app.kubernetes.io/name=pepr-admission -n pepr-system | grep szl

# Check receipts server
kubectl logs -l app.kubernetes.io/name=szl-receipts-server -n szl-receipts
```

**Port 8443 already in use:**
```bash
lsof -ti:8443 | xargs kill -9
kubectl port-forward svc/szl-receipts-server 8443:8443 -n szl-receipts
```

---

*Apache-2.0 | https://szlholdings.com | stephen@szlholdings.com*
