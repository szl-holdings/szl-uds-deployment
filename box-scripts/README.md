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

---

# box-scripts (part 3) — deploy-receipt recording alarm (uds-szl-demo)

A third host-level guard on box `167.233.50.75` raises a **real alarm** when
signed deploy receipts stop being recorded, instead of letting a stalled receipt
chain go unnoticed until a manual log inspection. Like the scripts above it lives
ONLY at `/usr/local/sbin` + `/etc/systemd/system` on the box and is **not**
otherwise under version control, so restore it from here after a rebuild.

## The problem it solves

The Pepr admission controller (`pepr-szl`, ns `pepr-system`) signs a DSSE deploy
receipt for every Deployment/Job and POSTs it to the layer-2 receipts-server
(Deployment `szl-receipts-server`, ns `szl-receipts`). That POST is **fail-open**:
if the server is down or its Service is unresolvable, the deploy is still admitted
and the signed receipt is **silently dropped** — the chain stops advancing with no
notification. That exact failure took down receipt recording before and was only
caught by manual log inspection. This guard turns it into an edge-triggered push
alert.

## Files

```
sbin/
  receipt-chain-watch          # detect stalled/failing receipt recording, alert on the edge
systemd/
  receipt-chain-watch.service  # oneshot: runs receipt-chain-watch
  receipt-chain-watch.timer    # every 5 min: triggers receipt-chain-watch.service
```

## What it detects (any one → ALERT)

- **(c) sink unhealthy** — `szl-receipts-server` has 0 available replicas, OR its
  Service has no ready endpoints (nothing to POST to).
- **(a) dropped POSTs** — `pepr-szl` logged `Failed to POST receipt` / `ENOTFOUND`
  / `getaddrinfo` / `ECONNREFUSED` in the recent window.
- **(b) chain not advancing** — Pepr signed ≥1 receipt in the window but the
  server accepted **zero** (`Receipt accepted by server` absent) — signing works
  but nothing lands in the chain.

It is **edge-triggered**: it fires the notifier only on the healthy→problem edge
and once on RECOVERED, never every cycle (de-duped via `/var/lib/receipt-chain-watch/last_status`).
Every run still appends to `/var/log/receipt-chain-watch/receipt-chain-watch.log`
and writes `/var/lib/receipt-chain-watch/status.json`, so a broken notifier can
never hide a stall. A stopped cluster or a cluster without the receipts module is
a true no-op (no alarm).

## Companion: in-cluster Prometheus rule (survives this box going dark)

This host guard cannot catch its own host dying — if the box (or this systemd
timer) goes dark, the alarm dies silently with it. A companion **PrometheusRule**
ships in the chart at `charts/szl-receipts/templates/prometheusrule.yaml` (gated
`prometheusRule.enabled`, default on) so the cluster's own Prometheus +
Alertmanager fire the same deploy-receipt-stall alarm independently of this box.
It reuses the server-driven `/metrics` (Ed25519 at-rest scan) scraped via the UDS
Package `spec.monitor` ServiceMonitor, with three alerts:
`SZLReceiptsSinkDown` (up==0 5m), `SZLReceiptsSinkAbsent`
(absent(szl_chain_length) 10m), `SZLReceiptChainTampered` (szl_chain_valid==0 2m).
Unit-tested with promtool + a render drift guard under
`charts/szl-receipts/tests/alerts/` (`run-alert-tests.sh`). The two layers are
complementary: this box guard additionally watches pepr-log signals (dropped
POSTs / signed-but-not-accepted) that pepr does not export to Prometheus.

## Notification channel

It pipes the alert text on STDIN to `NOTIFY_CMD` (default the box's working push
channel `/usr/local/sbin/a11oy-uptime-notify` → ntfy/Telegram/webhook configured
in `/etc/a11oy-uptime.env`). This box has **no Gmail/nodemailer transport** and
outbound TCP 465 is firewalled, so SMS/email is not used here — the ntfy push IS
the existing alert path (see memory `sms-alerts-on-hetzner.md` /
`a11oy-uptime-channel-restore.md`).

## Reinstall

The top-level `./install.sh` installs and enables this guard along with the
others. To (re)install just this guard manually:

```bash
sudo install -m 0755 sbin/receipt-chain-watch /usr/local/sbin/receipt-chain-watch
sudo install -m 0644 systemd/receipt-chain-watch.service /etc/systemd/system/
sudo install -m 0644 systemd/receipt-chain-watch.timer   /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now receipt-chain-watch.timer
```

## Verify

```bash
systemctl is-enabled receipt-chain-watch.timer
/usr/local/sbin/receipt-chain-watch && cat /var/lib/receipt-chain-watch/status.json
# Force an alert (safe, reversible): scale the sink to 0, run with a test prefix,
# confirm the push fires, then restore.
kubectl -n szl-receipts scale deploy szl-receipts-server --replicas=0 && sleep 12
ALERT_PREFIX="[TEST-ignore] " /usr/local/sbin/receipt-chain-watch
kubectl -n szl-receipts scale deploy szl-receipts-server --replicas=1
```

---

# box-scripts (part 4) — a11oy.net public-site alerting watchers

The final pair of host-level watchers on box `167.233.50.75` alert when the
**public a11oy.net site** goes down or when its **DNS stops pointing at the
box**. Together with the shared notifier below they make sure an outage or a
registrar/DNS change is pushed to Stephen instead of being noticed by accident.
Like the scripts above they live ONLY at `/usr/local/sbin` +
`/etc/systemd/system` on the box and are **not** otherwise under version control
(longer-form monorepo copies also exist under `deploy/hetzner/a11oy-uptime/` and
`deploy/hetzner/dns-drift/`), so restore them from here after a rebuild.

## Files

```
sbin/
  a11oy-uptime-check          # probe a11oy.net uptime, alert on the outage edge
  a11oy-uptime-notify         # shared push notifier (ntfy / Telegram / webhook)
  dns-drift-check             # alert if a11oy.net DNS drifts off the box
systemd/
  a11oy-uptime-check.service  # oneshot: runs a11oy-uptime-check (+ notifier env)
  a11oy-uptime-check.timer    # ~3 min after boot, then every 5 min
  dns-drift-check.service     # oneshot: runs dns-drift-check (+ notifier env)
  dns-drift-check.timer       # ~4 min after boot, then every 15 min
```

- **`a11oy-uptime-check`** — probes the public a11oy.net endpoints and also
  watches for port-guard interventions; alerts on the healthy→down edge and once
  on RECOVERED (edge-triggered + de-duped), never every cycle.
- **`dns-drift-check`** — queries a PUBLIC resolver (`dig @8.8.8.8`, never the
  box's own) for the apex/www/killinchu/elite A records (== `167.233.50.75`),
  the apex SPF `v=spf1 -all`, and `_dmarc` `p=reject`. Edge-triggered + de-duped
  the same way. (Trap baked into the script: a `grep` whose needle starts with
  `-`, such as the SPF `-all`, must use `grep -e "$pat"` or it is parsed as
  options and falsely reports drift.) A one-command DNS restore lives separately
  at `/opt/dns/dns-drift-reapply.sh` on the box.
- **`a11oy-uptime-notify`** — the single shared push notifier used by BOTH
  watchers above AND by `receipt-chain-watch` (part 3). It is curl-only and
  reads its channel (ntfy / Telegram / Slack-Discord webhook) from
  `/etc/a11oy-uptime.env`. It is fail-soft: with no channel configured it just
  exits and the alert is still logged.

## The push channel (`/etc/a11oy-uptime.env`)

The alert channel is a **private secret** (an ntfy topic, a Telegram token,
etc.) and is deliberately **not** kept in this public repo. The units reference
it as an OPTIONAL `EnvironmentFile=-/etc/a11oy-uptime.env`, so the watchers run
in **log-only** mode until the channel is restored. `install.sh` seeds a
commented-out stub at `/etc/a11oy-uptime.env` if the file is absent (never
clobbering a hand-filled one) so the path exists and the operator knows where
the channel lives. To actually restore the live channel after a wipe, use the
richer installer that supports pulling a saved env or discrete vars:

```bash
# from deploy/hetzner/a11oy-uptime/ (monorepo), with the saved secret env:
sudo VERIFY_PUSH=1 A11OY_UPTIME_ENV_SRC=/root/a11oy-uptime.env.secret bash install.sh
# or set a discrete channel, e.g. NTFY_URL=https://ntfy.sh/a11oy-uptime-XXXX
```

## Reinstall

The top-level `./install.sh` installs and enables these watchers along with the
others. To (re)install just these manually:

```bash
sudo install -m 0755 sbin/a11oy-uptime-check  /usr/local/sbin/a11oy-uptime-check
sudo install -m 0755 sbin/a11oy-uptime-notify /usr/local/sbin/a11oy-uptime-notify
sudo install -m 0755 sbin/dns-drift-check     /usr/local/sbin/dns-drift-check
sudo install -m 0644 systemd/a11oy-uptime-check.service /etc/systemd/system/
sudo install -m 0644 systemd/a11oy-uptime-check.timer   /etc/systemd/system/
sudo install -m 0644 systemd/dns-drift-check.service    /etc/systemd/system/
sudo install -m 0644 systemd/dns-drift-check.timer      /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now a11oy-uptime-check.timer dns-drift-check.timer
```

## Verify

```bash
systemctl is-enabled a11oy-uptime-check.timer dns-drift-check.timer
# Force a DNS-drift edge (safe, reversible) and confirm the push fires:
EXPECT_IP=10.0.0.1 ALERT_PREFIX="[TEST-ignore] " \
  NOTIFY_CMD=/usr/local/sbin/a11oy-uptime-notify NOTIFY_TITLE="a11oy.net DNS" \
  /usr/local/sbin/dns-drift-check
rm -f /var/lib/dns-drift/problem.sig    # clear the test edge afterwards
```

## Notes

- Background + rationale lives in the monorepo memory notes
  `dns-drift-watcher.md` and `a11oy-uptime-channel-restore.md`, and in the
  fuller monorepo copies under `deploy/hetzner/a11oy-uptime/` /
  `deploy/hetzner/dns-drift/` (which also carry the logrotate config and an
  `a11oy-uptime.env.example`).
- SMS/email is intentionally NOT used on this box: it has no Gmail/nodemailer
  transport and outbound TCP 465 is firewalled, so ntfy push IS the alert path.

---

# box-scripts (part 5) — scratch-namespace cleanup safety (uds-szl-demo)

`szl-ns-scratch` makes hand-deployed scratch namespaces on the `uds-szl-demo`
k3d cluster safe to clean up. People/agents hand-deploy ad-hoc copies of the
receipts server (and other experiments) into namespaces like `szl-receipts-demo`
that are **not** tracked by zarf, Helm, or a UDS Package — so a later "remove the
duplicate" cleanup cannot tell stale cruft apart from a teammate's live work. A
namespace once described as a stale `0.3.1` leftover had since been rebuilt into
a same-day `0.4.0` dev scratch; deleting it would have destroyed active work.

The fix is a labelling **convention** plus a helper to apply and audit it. Full
write-up: [`docs/SCRATCH_NAMESPACE_CONVENTION.md`](../docs/SCRATCH_NAMESPACE_CONVENTION.md).

## The convention

Every ad-hoc / scratch namespace carries, at creation time:

```
szl.io/ephemeral=true          # disposable scratch, not managed
szl.io/owner=<who>             # someone a cleanup can ask first
szl.io/created=<YYYY-MM-DD>    # UTC; for age-based GC
szl.io/ttl-days=<N>           # optional intended lifetime
```

Cleanup rule: only delete a namespace that is EITHER labeled
`szl.io/ephemeral=true` AND past its TTL/age, OR explicitly confirmed with its
owner. NEVER auto-delete an **UNKNOWN** (unlabeled + unmanaged) namespace.

## Files

```
sbin/
  szl-ns-scratch              # audit | list-unlabeled | list-stale | label
```

`szl-ns-scratch` itself has no systemd unit — it is an on-demand operator tool,
run at cleanup time. Its companion **`szl-ns-scratch-watch`** (part 6 below) is
the periodic guard that wraps `szl-ns-scratch list-unlabeled` and pushes an alert
the moment an untracked scratch namespace appears.

## Usage

```bash
szl-ns-scratch audit            # classify every ns: SYSTEM | MANAGED | EPHEMERAL | UNKNOWN
szl-ns-scratch list-unlabeled   # unmanaged ns missing the ephemeral label (the risky set)
szl-ns-scratch list-stale [N]   # ephemeral ns older than N days (TTL-aware; default 14)
szl-ns-scratch label <ns> --owner rosa --ttl-days 7   # stamp the convention onto <ns>
```

`audit` cross-checks live ownership (`helm list`, `kubectl get packages.uds.dev`,
zarf-managed label) rather than trusting the `managed-by=Helm` label alone — a
hand-applied scratch can wear that label with no release behind it. A clean
cluster shows zero **UNKNOWN** rows.

## Reinstall

The top-level `./install.sh` installs this helper along with the others. Manually:

```bash
sudo install -m 0755 sbin/szl-ns-scratch /usr/local/sbin/szl-ns-scratch
```

## Verify

```bash
szl-ns-scratch audit
# Round-trip a throwaway ns (safe, reversible):
kubectl create ns szl-scratch-selftest
szl-ns-scratch label szl-scratch-selftest --owner selftest --created 2000-01-01 --ttl-days 1
szl-ns-scratch list-stale          # szl-scratch-selftest should appear as expired
kubectl delete ns szl-scratch-selftest
```

---

# box-scripts (part 6) — untracked scratch-namespace alarm (uds-szl-demo)

`szl-ns-scratch` (part 5) is only useful if someone runs it. `szl-ns-scratch-watch`
turns its audit into a **periodic guard**: it wraps `szl-ns-scratch list-unlabeled`
and pushes an alert the moment an **untracked** scratch namespace (unmanaged +
missing the `szl.io/ephemeral` label = the UNKNOWN/risky set) appears on the
`uds-szl-demo` cluster — so it gets labeled or removed while it's still obvious
who made it and why, before a later cleanup can't tell it apart from live work.
Like the scripts above it lives ONLY at `/usr/local/sbin` + `/etc/systemd/system`
on the box and is **not** otherwise under version control, so restore it from
here after a rebuild.

## Files

```
sbin/
  szl-ns-scratch-watch          # alert on the edge when an UNKNOWN scratch ns appears
systemd/
  szl-ns-scratch-watch.service  # oneshot: runs szl-ns-scratch-watch
  szl-ns-scratch-watch.timer    # ~4 min after boot, then every 10 min
```

It is **edge-triggered**: it fires the notifier only on the healthy→problem edge
(a new UNKNOWN namespace appears) and once on RECOVERED (all UNKNOWN namespaces
have been labeled per the convention or removed), never every cycle (de-duped via
`/var/lib/szl-ns-scratch-watch/last_status`). Every run still appends to
`/var/log/szl-ns-scratch-watch/szl-ns-scratch-watch.log` and writes
`/var/lib/szl-ns-scratch-watch/status.json`, so a broken notifier can never hide
a drift. A stopped/unreachable cluster (k3d nodes are `--restart no`) is a true
no-op (no alarm). It reuses the same shared push channel as the other guards
(`/usr/local/sbin/a11oy-uptime-notify` → ntfy/Telegram/webhook in
`/etc/a11oy-uptime.env`).

## Reinstall

The top-level `./install.sh` installs and enables this guard along with the
others. To (re)install just this guard manually:

```bash
sudo install -m 0755 sbin/szl-ns-scratch-watch /usr/local/sbin/szl-ns-scratch-watch
sudo install -m 0644 systemd/szl-ns-scratch-watch.service /etc/systemd/system/
sudo install -m 0644 systemd/szl-ns-scratch-watch.timer   /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now szl-ns-scratch-watch.timer
```

## Verify

```bash
systemctl is-enabled szl-ns-scratch-watch.timer
/usr/local/sbin/szl-ns-scratch-watch && cat /var/lib/szl-ns-scratch-watch/status.json
# Force an alert (safe, reversible) into an ISOLATED state dir + a capture
# notifier so the team channel isn't paged and the real state isn't disturbed:
kubectl create ns szl-scratch-selftest
STATE_DIR=/tmp/nsw/state LOG_DIR=/tmp/nsw/log NOTIFY_CMD=/bin/cat \
  ALERT_PREFIX="[TEST-ignore] " /usr/local/sbin/szl-ns-scratch-watch   # -> ALERT
szl-ns-scratch label szl-scratch-selftest --owner selftest --ttl-days 1
STATE_DIR=/tmp/nsw/state LOG_DIR=/tmp/nsw/log NOTIFY_CMD=/bin/cat \
  /usr/local/sbin/szl-ns-scratch-watch                                 # -> RECOVERED
kubectl delete ns szl-scratch-selftest; rm -rf /tmp/nsw
```


---

# box-scripts (part 7) — orphaned receipts-server alarm (uds-szl-demo)

On the 2-vCPU box a hand-made scratch namespace (e.g. `szl-receipts-demo`) keeps
reappearing after every cluster rebuild. It runs a `szl-receipts-server` workload
but is owned by **nothing** — no Helm release, no zarf package, no UDS Package, no
VirtualService — so it signs nothing, holds no durable data, and just burns CPU on
an already-loaded node. Finding it used to be a manual hunt (Task #283).

**`szl-receipts-orphan-watch`** turns that hunt into a periodic guard. Every
10 min it lists every namespace running a receipts-server Deployment (matched by
name `szl-receipts-server` **or** a container image matching `receipts-server`),
drops the canonical `szl-receipts`, and flags any remaining namespace that is
**not** owned by any of:

- **Helm** — the Deployment carries `app.kubernetes.io/managed-by=Helm` or a
  `meta.helm.sh/release-name` annotation, or `helm list -A` shows a release in
  that namespace. (zarf and UDS deploy *through* Helm here, so this is also the
  `zarf package list` / UDS-Package ownership signal.)
- **UDS** — a `packages.uds.dev` CR exists in the namespace.
- **Istio** — a `VirtualService` exists in the namespace.

Anything left is an **orphan** → one push via `/usr/local/sbin/a11oy-uptime-notify`.
It **never deletes** (an orphan is sometimes a teammate's live scratch — deletion
stays a human call); it only logs + alerts.

Edge-triggered + de-duped via `/var/lib/szl-receipts-orphan-watch/last_status`:
one push on the healthy→orphan edge, one on RECOVERED, never every cycle. Always
writes `/var/lib/szl-receipts-orphan-watch/status.json` + appends
`/var/log/szl-receipts-orphan-watch/szl-receipts-orphan-watch.log`. Cluster
stopped/unreachable = a true no-op (no false alarm). Mirrors the
`receipt-chain-watch` / `szl-ns-scratch-watch` guard pattern.

## Reinstall

The top-level `./install.sh` installs + enables this guard. Manually:

```bash
sudo install -m 0755 sbin/szl-receipts-orphan-watch /usr/local/sbin/szl-receipts-orphan-watch
sudo install -m 0644 systemd/szl-receipts-orphan-watch.service /etc/systemd/system/
sudo install -m 0644 systemd/szl-receipts-orphan-watch.timer   /etc/systemd/system/
sudo systemctl daemon-reload && sudo systemctl enable --now szl-receipts-orphan-watch.timer
```

## Verify (safe, reversible — isolated state + captured notifier)

```bash
rm -rf /tmp/rospan; mkdir -p /tmp/rospan/state /tmp/rospan/log
RUN(){ STATE_DIR=/tmp/rospan/state LOG_DIR=/tmp/rospan/log NOTIFY_CMD=/bin/cat \
       ALERT_PREFIX="[TEST] " /usr/local/sbin/szl-receipts-orphan-watch; }
RUN                                              # baseline -> OK, no push
kubectl create ns szl-receipts-selftest
kubectl -n szl-receipts-selftest create deploy receipts-dupe \
  --image=127.0.0.1:31999/szl-receipts-server:v0.4.0-src --replicas=0
RUN                                              # -> ALERT, one [TEST] push
RUN                                              # -> DEDUP, no push
kubectl delete ns szl-receipts-selftest
RUN                                              # -> RECOVERED, one [TEST] push
rm -rf /tmp/rospan
```
