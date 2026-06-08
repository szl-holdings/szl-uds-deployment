# box-scripts — a11oy.net ⇄ UDS demo cluster port coexistence (box 167.233.50.75)

Reference copies of the host-level scripts and systemd units that keep the
**public a11oy.net site** (nginx on host ports 80/443) and the **UDS k3d demo
cluster** `uds-szl-demo` from fighting over ports 80/443 on the single box
`167.233.50.75`.

These live on the box at `/usr/local/sbin` and `/etc/systemd/system`, which are
**not** under version control. If the box is ever rebuilt or reimaged, restore
them from this directory (see "Reinstall" below) so the public site and the
cluster keep coexisting.

## The problem they solve

The k3d serverlb container (`k3d-uds-szl-demo-serverlb`) publishes host ports
`80` and `443` by default. nginx (which serves a11oy.net / www / killinchu /
elite) also needs `80`/`443`. They used to be mutually exclusive — only one
could run. The fix makes them **coexist**: nginx owns host `80`/`443`, and the
serverlb is kept off them (it still publishes the kube-API on a dynamic host
port → `6443`, plus `8443`), so the cluster keeps running and is reached via
`kubectl port-forward`.

## Files

```
sbin/
  a11oy-mode                  # mode manager: coexist | ensure | public | status
  a11oy-serverlb-deconflict   # idempotent helper: rebind serverlb off host 80/443
  a11oy-port-guard            # periodic safety net (called by the timer below)
systemd/
  a11oy-coexist.service       # boot oneshot: runs `a11oy-mode ensure`
  a11oy-port-guard.service    # oneshot: runs a11oy-port-guard
  a11oy-port-guard.timer      # every 2 min: triggers a11oy-port-guard.service
```

- `a11oy-mode` is the operator entry point:
  - `a11oy-mode coexist` — bring up BOTH (start cluster if down, then nginx).
  - `a11oy-mode ensure` — boot-safe: nginx up on 80/443 + deconflict serverlb.
  - `a11oy-mode public` — public site only (frees 80/443; leaves cluster as-is).
  - `a11oy-mode status` — read-only: show what is currently serving.
- `a11oy-serverlb-deconflict` recreates the serverlb publishing every port
  EXCEPT host 80/443 (preserving the kube-API port + confd). No-op if already
  clear or absent.
- `a11oy-coexist.service` settles the boot posture: nginx owns 80/443, cluster
  stays down (k3d containers are `--restart=no`), public site up by default.
- `a11oy-port-guard.{service,timer}` is the during-session safety net: if a raw
  `k3d cluster start` re-grabs 80/443 (or nginx goes down), the timer recovers
  within ~2 min by calling `a11oy-mode ensure`.

## Reinstall (after a box rebuild / reimage)

From this directory on the box:

```bash
sudo ./install.sh
```

Or manually:

```bash
sudo install -m 0755 sbin/a11oy-mode                /usr/local/sbin/a11oy-mode
sudo install -m 0755 sbin/a11oy-serverlb-deconflict /usr/local/sbin/a11oy-serverlb-deconflict
sudo install -m 0755 sbin/a11oy-port-guard          /usr/local/sbin/a11oy-port-guard

sudo install -m 0644 systemd/a11oy-coexist.service     /etc/systemd/system/a11oy-coexist.service
sudo install -m 0644 systemd/a11oy-port-guard.service  /etc/systemd/system/a11oy-port-guard.service
sudo install -m 0644 systemd/a11oy-port-guard.timer    /etc/systemd/system/a11oy-port-guard.timer

sudo systemctl daemon-reload
sudo systemctl enable --now a11oy-coexist.service
sudo systemctl enable --now a11oy-port-guard.timer
```

## Verify

```bash
a11oy-mode status                 # nginx ACTIVE, serverlb clear of 80/443
systemctl is-enabled a11oy-coexist.service a11oy-port-guard.timer
curl -s -o /dev/null -w '%{http_code}\n' https://a11oy.net/   # expect 200
```

## Notes / assumptions

- Cluster name is hard-coded as `uds-szl-demo` and the serverlb container as
  `k3d-uds-szl-demo-serverlb` (matches Task #103's demo cluster).
- k3d image pinned to `ghcr.io/k3d-io/k3d-proxy:5.9.0` in the deconflict helper.
- These are host-level scripts; they assume `nginx`, `docker`, `k3d`, and
  `curl` are installed and that nginx vhosts for a11oy.net already exist.
- The `szl-core-rightsize` call in `a11oy-mode coexist` is best-effort
  (`[ -x ... ] && ... || true`) so its absence does not break coexistence.

---

# box-scripts (part 2) — 2-vCPU headroom self-heal guards (uds-szl-demo)

Two further host-level guards on box `167.233.50.75` keep the single-node k3d
cluster `uds-szl-demo` (only 2 allocatable CPU) from ever stranding pods in
**Pending**. Like the port-coexistence scripts above they live ONLY at
`/usr/local/sbin` + `/etc/systemd/system` on the box and are **not** otherwise
under version control, so restore them from here after a rebuild.

## Files

```
sbin/
  szl-core-rightsize          # pin UDS-core HA components to 1 replica + no-surge
  istiod-fit-strategy         # keep istiod rollout strategy + HPA fitting 2 vCPU
systemd/
  szl-core-rightsize.service  # oneshot: runs szl-core-rightsize
  szl-core-rightsize.timer    # every 2 min: triggers szl-core-rightsize.service
  istiod-fit-strategy.service # oneshot: runs istiod-fit-strategy
  istiod-fit-strategy.timer   # every 2 min: triggers istiod-fit-strategy.service
```

- **`szl-core-rightsize`** — the shared UDS-core admission components ship HA
  defaults that do not fit this node: `pepr-uds-core` (2 replicas, +200m) and
  `zarf/agent-hook` (2 replicas, +100m), plus a surge rollout strategy. On a
  ~90%-requested 2-CPU node those extra pods cannot schedule, which strands
  szl-receipts, the admin gateway, and `pepr-uds-core-watcher` (the pod that
  processes the Package finalizer AND creates the receipts admin-gateway
  VirtualService). The guard pins the four targets to a single replica with no
  surge. It is strategy-aware: `Recreate` deploys (`pepr-szl`,
  `pepr-uds-core-watcher`) get a replicas-only patch because surge fields are
  forbidden on `Recreate`; `RollingUpdate` deploys also get
  `maxSurge=0/maxUnavailable=1`. Also called at the end of `a11oy-mode coexist`.
- **`istiod-fit-strategy`** — istiod requests 500m and Istio's default pilot
  strategy (`maxSurge=100%`) brings up a transient SECOND istiod before killing
  the old one, so any rollout (including `zarf package deploy` of core) hangs on
  a Pending surge pod. The guard sets `maxSurge=0/maxUnavailable=1` so the single
  replica terminates-then-recreates within headroom, and clamps istiod's HPA to
  `maxReplicas=1` so the autoscaler can never request a 2nd istiod the node
  can't fit.

Both guards are idempotent — a true no-op (no API writes, no log spam) once the
cluster already conforms — and both no-op if the cluster is down (k3d nodes are
`--restart no`). A `helm upgrade` / `zarf package deploy` of UDS core resets
these postures back to the HA defaults, which is exactly why the 2-min timers
re-apply them.

## Reinstall

The top-level `./install.sh` installs and enables BOTH the port-coexistence
scripts and these two guards. To (re)install just these guards manually:

```bash
sudo install -m 0755 sbin/szl-core-rightsize  /usr/local/sbin/szl-core-rightsize
sudo install -m 0755 sbin/istiod-fit-strategy /usr/local/sbin/istiod-fit-strategy
sudo install -m 0644 systemd/szl-core-rightsize.service   /etc/systemd/system/
sudo install -m 0644 systemd/szl-core-rightsize.timer     /etc/systemd/system/
sudo install -m 0644 systemd/istiod-fit-strategy.service  /etc/systemd/system/
sudo install -m 0644 systemd/istiod-fit-strategy.timer    /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now szl-core-rightsize.timer istiod-fit-strategy.timer
```

## Verify

```bash
systemctl is-enabled szl-core-rightsize.timer istiod-fit-strategy.timer
kubectl -n istio-system get hpa istiod          # MAXPODS should be 1
kubectl -n pepr-system get deploy               # pepr-* / watcher all 1 replica
```

## Notes

- Background + rationale lives in the monorepo memory notes
  `szl-core-rightsize-guard.md` and `istiod-cpu-headroom-fix.md`.
- A chart-level pin of these values is a good belt-and-suspenders follow-up but
  only helps fresh deploys; the guards cover every drift path (cold restart,
  helm/zarf reset, manual edits).
