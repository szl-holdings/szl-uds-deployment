#!/usr/bin/env python3
# Copyright 2026 SZL Holdings
# SPDX-License-Identifier: Apache-2.0
"""
port_convention_check.py — catch mismatched service ports across the organ packages.

WHY THIS EXISTS
Task #638 fixed real port skew in this repo: four organs' egress rules pointed at
a11oy on port 8080, but a11oy actually listens on 7860. The UDS operator turns
every `spec.network.allow` rule into a NetworkPolicy whose port is the
*destination* workload's port, so a wrong port silently blackholes mesh traffic
with no error and no failed deploy — exactly the kind of regression a one-off
hand audit cannot keep out. This guard makes the convention self-policing.

THE CONVENTION (memory: szl-uds-organ-ports.md)
In every `spec.network.allow` rule, `port` == the *destination* workload's real
listener port:
  * Egress rule (A -> B): port == B's listener port (remoteSelector's app).
  * Ingress rule (to A from B): port == A's listener port (the package's own app).
`monitor.targetPort` and `expose.targetPort` == the package's own listener port.

REAL LISTENER PORTS ARE DERIVED, NOT TYPED FROM COMMENTS
The port table is built from each organ's `packages/<organ>/manifests/deployment.yaml`
`containerPort` and the szl-receipts chart's `server.port`
(`charts/szl-receipts/values.yaml`) — so it stays self-updating as the real
workloads change. A small STATIC_LISTENERS map covers destinations that have no
in-repo deployment manifest (vessels, keycloak); if such an app later gains a
manifest, the derived value must AGREE with the static one or the guard fails
(keeping the static map honest).

SCOPE
Only the canonical `packages/*/uds-package.yaml` files are checked, matching the
task brief. The experimental `uds-package-mesh-ready.yaml` variants wire a
different infra topology (keycloak 8443, postgres 5432, loki 3100, ...) and are
intentionally out of scope.

Usage: port_convention_check.py [repo_root]   (defaults to ".")
Exits non-zero (printing ::error:: lines) on any mismatch.
"""

import glob
import os
import sys

import yaml


# Destinations referenced by allow rules that have NO in-repo deployment manifest
# to derive a port from. Kept tiny and explicit; cross-checked against any derived
# value so it can never silently go stale.
STATIC_LISTENERS = {
    "vessels": 8080,    # packages/vessels has no manifests/deployment.yaml in-repo
    "keycloak": 8080,   # UDS-managed (not an SZL organ); 8080 http listener
}


def _load_yaml(path):
    with open(path) as fh:
        return yaml.safe_load(fh)


def _container_ports(doc):
    """Every containerPort declared by a Deployment's pod containers."""
    ports = []
    spec = (((doc or {}).get("spec") or {}).get("template") or {}).get("spec") or {}
    for c in (spec.get("containers") or []):
        for p in (c.get("ports") or []):
            cp = p.get("containerPort")
            if isinstance(cp, int):
                ports.append(cp)
    return ports


def _pod_app_label(doc):
    labels = ((((doc or {}).get("spec") or {}).get("template") or {}).get("metadata") or {}).get("labels") or {}
    return labels.get("app")


def build_listener_table(root, err):
    """app-label -> real listener port, derived from deployment manifests + the
    szl-receipts chart. STATIC_LISTENERS fills in the manifest-less destinations
    and is cross-checked against anything derived."""
    derived = {}

    for dep in sorted(glob.glob(os.path.join(root, "packages", "*", "manifests", "deployment.yaml"))):
        for doc in yaml.safe_load_all(open(dep)):
            if not isinstance(doc, dict) or doc.get("kind") != "Deployment":
                continue
            app = _pod_app_label(doc)
            ports = _container_ports(doc)
            if not app or not ports:
                continue
            distinct = sorted(set(ports))
            if len(distinct) > 1:
                err(f"{os.path.relpath(dep, root)}: app '{app}' declares multiple "
                    f"containerPorts {distinct}; the listener port is ambiguous.")
                continue
            port = distinct[0]
            if app in derived and derived[app] != port:
                err(f"app '{app}' has conflicting derived listener ports "
                    f"{derived[app]} vs {port}.")
            derived[app] = port

    # szl-receipts-server listener comes from the chart values, not a manifest.
    chart_values = os.path.join(root, "charts", "szl-receipts", "values.yaml")
    if os.path.isfile(chart_values):
        v = _load_yaml(chart_values) or {}
        srv = v.get("server") or {}
        name, port = srv.get("name"), srv.get("port")
        if isinstance(name, str) and isinstance(port, int):
            if name in derived and derived[name] != port:
                err(f"app '{name}' chart server.port {port} conflicts with derived "
                    f"{derived[name]}.")
            derived[name] = port

    # Merge in the manifest-less statics, cross-checking any derived value.
    table = dict(derived)
    for app, port in STATIC_LISTENERS.items():
        if app in derived and derived[app] != port:
            err(f"STATIC_LISTENERS['{app}']={port} is stale: a deployment manifest "
                f"now derives {derived[app]}. Update STATIC_LISTENERS (or remove it "
                f"if the manifest is now canonical).")
        table.setdefault(app, port)
    return table


def check_package(path, root, listeners, err):
    """Assert every allow rule / monitor / expose port matches the destination's
    real listener port for one uds-package.yaml."""
    rel = os.path.relpath(path, root)
    doc = _load_yaml(path)
    if not isinstance(doc, dict):
        err(f"{rel}: not a YAML mapping.")
        return
    net = (doc.get("spec") or {}).get("network") or {}

    def listener_of(app, where):
        if app not in listeners:
            err(f"{rel} {where}: destination app '{app}' has no known listener "
                f"port. Add packages/{app}/manifests/deployment.yaml (with a "
                f"containerPort) or extend STATIC_LISTENERS in the checker so the "
                f"port table stays complete.")
            return None
        return listeners[app]

    # ── allow rules ──────────────────────────────────────────────────────────
    for i, rule in enumerate(net.get("allow") or []):
        if not isinstance(rule, dict):
            continue
        port = rule.get("port")
        if port is None:
            continue  # e.g. remoteGenerated KubeAPI/DNS rules carry no port
        direction = rule.get("direction")
        desc = rule.get("description", "")
        tag = f"allow[{i}] ({direction}: {desc})"
        if direction == "Egress":
            dest = (rule.get("remoteSelector") or {}).get("app")
            if not dest:
                # Egress with an explicit port but no remoteSelector.app (e.g.
                # remoteGenerated to an external CIDR) — nothing to resolve.
                continue
            expected = listener_of(dest, tag)
        elif direction == "Ingress":
            own = (rule.get("selector") or {}).get("app")
            if not own:
                err(f"{rel} {tag}: Ingress rule has no selector.app to resolve the "
                    f"destination (own) listener port.")
                continue
            expected = listener_of(own, tag)
        else:
            err(f"{rel} {tag}: unknown allow direction '{direction}'.")
            continue
        if expected is not None and port != expected:
            who = (rule.get("remoteSelector") or {}).get("app") if direction == "Egress" \
                else (rule.get("selector") or {}).get("app")
            err(f"{rel} {tag}: port {port} != destination '{who}' listener "
                f"{expected}. The UDS operator keys the generated NetworkPolicy on "
                f"the destination port; a mismatch silently blackholes mesh traffic.")

    # ── expose[].targetPort == own listener ──────────────────────────────────
    for i, exp in enumerate(net.get("expose") or []):
        if not isinstance(exp, dict):
            continue
        tp = exp.get("targetPort")
        if tp is None:
            continue
        own = (exp.get("selector") or {}).get("app")
        expected = listener_of(own, f"expose[{i}]") if own else None
        if expected is not None and tp != expected:
            err(f"{rel} expose[{i}]: targetPort {tp} != '{own}' listener "
                f"{expected}.")

    # ── monitor[].targetPort == own listener ─────────────────────────────────
    for i, mon in enumerate(doc.get("spec", {}).get("monitor") or []):
        if not isinstance(mon, dict):
            continue
        tp = mon.get("targetPort")
        if tp is None:
            continue
        own = (mon.get("selector") or {}).get("app")
        expected = listener_of(own, f"monitor[{i}]") if own else None
        if expected is not None and tp != expected:
            err(f"{rel} monitor[{i}]: targetPort {tp} != '{own}' listener "
                f"{expected}.")


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else "."
    errors = []

    def err(msg):
        errors.append(msg)
        print(f"::error::{msg}")

    listeners = build_listener_table(root, err)
    if listeners:
        print("Derived listener ports: " +
              ", ".join(f"{a}={p}" for a, p in sorted(listeners.items())))

    pkgs = sorted(glob.glob(os.path.join(root, "packages", "*", "uds-package.yaml")))
    if not pkgs:
        err("no packages/*/uds-package.yaml files found — nothing to check.")
    for pkg in pkgs:
        check_package(pkg, root, listeners, err)

    if errors:
        print(f"\n{len(errors)} port-convention check(s) FAILED")
        return 1
    print(f"\nAll port-convention checks passed across {len(pkgs)} package(s).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
