# AGENTS.md

## Cursor Cloud specific instructions

### Product overview

Single-repo **SZL Governance Receipts** UDS add-on: Pepr admission policy emits DSSE HMAC receipts to an in-cluster Python receipts server + nginx dashboard. Primary workflow is Kubernetes-based (`uds run start`), not a local Node/Python app server.

### Services (see `docs/INSTALL.md` and `tasks.yaml`)

| Service | How to run |
|---------|------------|
| Full stack (k3d + UDS bundle) | `uds run start` (~90s on a laptop with working Docker/cgroups) |
| Demo workload | `uds run demo:workload` (needs cluster) |
| Receipt verification | `uds run demo:verify` |
| Dashboard (cluster) | `uds run port-forward` → http://localhost:8443 |
| Teardown | `uds run teardown` |

### Cloud VM caveats (Docker-in-Docker)

- **Docker daemon**: If `docker info` fails, start dockerd manually (this environment uses `fuse-overlayfs` + `iptables-legacy`). Ensure `/var/run/docker.sock` is usable (`sudo chmod 666 /var/run/docker.sock` if not in the `docker` group).
- **k3d / k3s**: Nested VMs often hit `failed to find memory cgroup (v2)` and k3s never becomes ready. Full `uds run start` may not complete here even when Docker runs. Validate Pepr/Helm/receipts server locally instead (below).
- **CLI install URLs**: `uds run install-deps` and `docs/INSTALL.md` use legacy asset names. Current releases use:
  - `uds-cli_v0.32.0_Linux_amd64` (not `uds-cli_linux_amd64`)
  - `zarf_v0.77.0_Linux_amd64` (not `zarf_linux_amd64`)
- **kubectl**: Not bundled with the repo; install from https://dl.k8s.io/ or use `k3d kubeconfig merge`.

### Pepr policy (`pepr/`)

```bash
cd pepr
npm ci --legacy-peer-deps
# Pepr CLI pulls optional deps at runtime; if `npx pepr build` fails on missing modules:
(cd node_modules/pepr && npm install --include=dev)
npm run build
```

`npm run test` (`npx pepr validate`) may error with "too many arguments" on some Pepr versions; **`npm run build`** is the reliable check. Output goes to `pepr/dist/`; copy to repo root for Zarf: `mkdir -p dist && cp -a pepr/dist dist/pepr`.

TypeScript in `package.json` is `^6.x` while Pepr 1.2.0 expects TS 5.8.x — use `--legacy-peer-deps`.

### Helm

```bash
helm lint charts/szl-receipts
```

### Local receipts server (no cluster)

The canonical server is `services/szl-receipts-server/server.py` (Ed25519 over the
canonical DSSE PAE — NOT HMAC). Generate a key and run it directly:

```bash
openssl genpkey -algorithm ED25519 -out /tmp/ed25519.pem
export SZL_ED25519_KEY_PATH=/tmp/ed25519.pem
export SZL_PORT=8443
export SZL_RECEIPT_STORE=/tmp/receipts
python3 services/szl-receipts-server/server.py &
curl -sf http://localhost:8443/health
# POST a receipt and confirm the server's self-verify reports valid:true
curl -sf -X POST http://localhost:8443/receipt -d '{"subject":"demo/x","specHash":"abc"}'
# Independently verify the chain offline with the PUBLIC key only:
SZL_RECEIPTS_URL=http://localhost:8443 bash scripts/verify_receipts.sh
```

### Zarf package create

Requires `dist/pepr` from Pepr build (`cd pepr && npm run build`). Pepr emits a Zarf component named `pepr-<uuid>`; with the Pepr `uuid` set to `szl-receipt-policy` (see `pepr/package.json`) the built component is `pepr-szl-receipt-policy`, and `zarf.yaml` now imports that exact name. (Previously the import used the bare `szl-receipt-policy`, which made `zarf package create` fail with "no compatible component named szl-receipt-policy".)

```bash
zarf package create . -f upstream --set DOMAIN=uds.dev --confirm
```

### Lint / test summary

| Check | Command |
|-------|---------|
| Helm | `helm lint charts/szl-receipts` |
| Pepr build | `cd pepr && npm run build` |
| Pepr validate | `cd pepr && npm run test` (may fail on CLI version) |
| E2E | `uds run start && uds run demo:workload && uds run demo:verify` (needs working k3d) |
