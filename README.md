# szl-uds-deployment

[![GHAS Code Security](https://img.shields.io/badge/GHAS-Code_Security-2DA44E.svg?style=flat-square&logo=github)](https://github.com/szl-holdings/szl-uds-deployment/security/code-scanning)
[![Secret Protection](https://img.shields.io/badge/GHAS-Secret_Protection-2DA44E.svg?style=flat-square&logo=github)](https://github.com/szl-holdings/szl-uds-deployment/security/secret-scanning)
[![SLSA L1 · L2 roadmap](https://img.shields.io/badge/SLSA-L1_%E2%86%92_L2_roadmap-0B1F3A.svg?style=flat-square)](https://slsa.dev/spec/v1.0/levels)

**SZL Governance Receipts — UDS Running Deployment**

DSSE-wrapped audit receipts emitted from live Kubernetes workloads on a UDS infrastructure stack (k3d + uds-cli + Pepr policies).

Built for [Warhacker 2026](https://warhacker.io), June 16-20, San Diego.

---

## What This Is

A UDS add-on that attaches cryptographic governance receipts to every Kubernetes Deployment and Job admitted to the cluster. The Pepr admission controller intercepts each workload API call, generates a DSSE-wrapped HMAC-SHA-256 receipt, posts it to an in-cluster receipt server, and annotates the resource with the receipt ID.

**This is NOT:**
- A replacement for uds-core security policies
- A certified DoD package (Phase 2 intent)
- A modification of uds-core (zero AGPL entanglement — network-only coupling)
- Production-hardened (demo-grade; see Phase 2 roadmap in ARCHITECTURE.md)

---

## Quick Start

```bash
# Prerequisites: Docker, k3d, uds CLI, zarf CLI
# See docs/INSTALL.md for one-liner installs

uds run start           # bootstrap k3d + deploy bundle (~90 seconds)
uds run demo:workload   # apply sample workload → receipt appears in feed
uds run demo:verify     # verify receipt chain from cluster
```

Dashboard: `http://localhost:8443` (after `uds run port-forward`)

---

## Repository Structure

```
szl-uds-deployment/
├── zarf.yaml                      # Zarf package definition
├── uds-bundle.yaml                # UDS bundle manifest
├── tasks.yaml                     # uds-cli task runner
├── tasks/
│   └── demo.yaml                  # demo sub-tasks
├── manifests/
│   └── namespace.yaml             # szl-receipts namespace
├── charts/
│   └── szl-receipts/              # Helm chart: receipt server + dashboard
│       ├── Chart.yaml
│       ├── values.yaml
│       └── templates/
│           ├── deployment.yaml    # MCP receipts server + nginx sidecar
│           ├── service.yaml       # ClusterIP + ServiceAccount + HMAC secret
│           ├── ingress.yaml       # UDS Package CR + ServiceMonitor
│           └── configmap.yaml     # Server Python source + dashboard HTML
├── pepr/                          # Pepr policy module
│   ├── package.json
│   ├── tsconfig.json
│   ├── pepr.ts                    # Module entry point
│   └── policies/
│       └── szl-receipt-on-deploy.ts  # Emit DSSE receipt on Deployment/Job
├── ui/
│   └── dashboard.yaml             # Standalone NGINX dashboard manifest
├── scripts/
│   ├── demo_workload.sh           # Interactive demo workload script
│   ├── demo_workload.yaml         # K8s manifests for demo workload
│   └── verify_receipts.sh         # Post-demo receipt chain verification
└── docs/
    ├── WARHACKER_DEMO.md          # 5-minute talk track (live cluster edition)
    ├── INSTALL.md                  # One-page install + deploy guide
    └── ARCHITECTURE.md            # Cluster diagram + AGPL compliance rationale
```

---

## License

Apache-2.0 — designed to be contributable to the Defense Unicorns ecosystem.

See [LICENSE](LICENSE) for full text.

---

## Contact

Stephen Paul Lutar JR — stephen@szlholdings.com  
[SZL Holdings](https://szlholdings.com)
