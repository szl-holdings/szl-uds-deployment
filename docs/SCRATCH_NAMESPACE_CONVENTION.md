# Scratch / ephemeral namespace convention (uds-szl-demo)

On box `167.233.50.75` (k3d cluster `uds-szl-demo`) people and agents regularly
hand-deploy ad-hoc copies of the receipts server (and other experiments) into
namespaces like `szl-receipts-demo`. These are **not** tracked by zarf, Helm, or
a UDS Package, so a later "remove the duplicate" cleanup has no reliable way to
tell genuine stale cruft apart from a teammate's live, in-progress dev scratch.

That ambiguity has already bitten us: a namespace described as a stale `0.3.1`
leftover had since been rebuilt into a same-day `0.4.0` dev scratch, so deleting
it would have destroyed active work to save ~50m of CPU. This convention exists
so that never happens silently.

## The labels

Whenever you create an ad-hoc / scratch namespace, stamp it with:

| Label                | Required | Meaning                                            |
|----------------------|----------|----------------------------------------------------|
| `szl.io/ephemeral`   | yes      | `true` — "this is disposable scratch, not managed" |
| `szl.io/owner`       | yes      | who made it (a person/agent a cleanup can ask)     |
| `szl.io/created`     | yes      | `YYYY-MM-DD` (UTC) it was created — for age-based GC|
| `szl.io/ttl-days`    | no       | intended lifetime in days; the audit flags expiry  |

Apply them by hand:

```bash
kubectl label ns szl-receipts-demo --overwrite \
  szl.io/ephemeral=true \
  szl.io/owner=rosa \
  szl.io/created=2026-06-08 \
  szl.io/ttl-days=7
```

…or, easier, with the helper (which fills in `owner`/`created` for you):

```bash
szl-ns-scratch label szl-receipts-demo --owner rosa --ttl-days 7
```

### Standard pattern: create + label in one breath

Always stamp a scratch namespace the moment you create it, so it can never slip
through as **UNKNOWN**. The standard one-liner is:

```bash
kubectl create ns szl-receipts-demo && szl-ns-scratch label szl-receipts-demo
```

The repo's deploy/scratch helpers already follow this pattern — they auto-stamp
the convention labels at `kubectl create namespace` time, so anything they create
shows up as **EPHEMERAL** in `szl-ns-scratch audit` with no extra step:

- `scripts/demo_workload.sh` stamps `szl-demo-workload`.
- the `uds run recreate-full` flow (`tasks.yaml`) stamps `szl-receipts-demo`.

Both prefer the `szl-ns-scratch label` helper and fall back to a direct
`kubectl label` (same labels) when the helper isn't on `PATH` (e.g. off-box).
If you hand-roll a new scratch flow, copy this pattern into it.

## The cleanup rule

A cleanup (human or agent) may only delete a namespace that is **either**:

1. labeled `szl.io/ephemeral=true` **and** past its TTL / age threshold, **or**
2. explicitly confirmed with its `szl.io/owner`.

It must **never** auto-delete an **UNKNOWN** namespace — one that is unlabeled
and has no managed owner. Unknown means "we don't know whose live work this is";
verify before touching it. Labels are a convenience, not proof, so before any
delete also re-derive live ownership signals (this is what the audit cross-checks
and what a careful operator should eyeball):

- **zarf:** `zarf package list` — is it part of a deployed package?
- **Helm:** `helm list -A` — is there a real release in the namespace? (A
  hand-applied scratch can carry `app.kubernetes.io/managed-by=Helm` *labels*
  with no release behind them — labels alone do not prove management.)
- **UDS:** `kubectl get packages.uds.dev -A` — is there a UDS Package?
- **Liveness:** image tag, ReplicaSet history (a manual multi-source image hunt
  = active dev), and the pod boot log (is it actually doing signed work, or an
  idle `emptyDir` dead-end with `chain_index=0`?).

The canonical receipts service lives in namespace `szl-receipts` (zarf package
`szl-receipts`); it is MANAGED and must be left alone.

## The helper: `szl-ns-scratch`

Installed at `/usr/local/sbin/szl-ns-scratch` (source: `box-scripts/sbin/`,
deployed by `box-scripts/install.sh`). Read-only except for `label`.

```bash
szl-ns-scratch audit            # classify every namespace (default)
szl-ns-scratch list-unlabeled   # unmanaged ns missing the ephemeral label (the risky set)
szl-ns-scratch list-stale [N]   # ephemeral ns older than N days (TTL-aware; default 14)
szl-ns-scratch label <ns> [--owner who] [--created YYYY-MM-DD] [--ttl-days N]
```

`audit` classifies each namespace as one of:

- **SYSTEM** — k8s built-ins + UDS Core / istio / zarf / vault / observability. Protected.
- **MANAGED** — a real Helm release, UDS Package, or zarf-managed ns. Protected.
- **EPHEMERAL** — labeled `szl.io/ephemeral=true`; shows owner / created / age and
  flags `EXPIRED` when age ≥ `ttl-days`. Safe to GC once expired.
- **UNKNOWN** — unlabeled **and** unmanaged. **Do not auto-delete** — find the owner.

A clean cluster has zero **UNKNOWN** rows. If one appears, that is the signal a
scratch namespace was created without following this convention — track down the
owner and either label it or remove it with their sign-off.

The cluster-absent case is a safe no-op: if `uds-szl-demo` is stopped (k3d nodes
are `--restart no`), the helper prints a notice and exits 0.
