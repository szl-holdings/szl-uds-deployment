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
