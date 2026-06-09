#!/usr/bin/env python3
# Copyright 2026 SZL Holdings
# SPDX-License-Identifier: Apache-2.0
#
# deploy-entry-checks.py — the testable logic behind deploy-entry-guard.yml.
#
# A Zarf component in uds/zarf.yaml can be SILENTLY, INTERNALLY INCONSISTENT in a
# way that only surfaces at deploy time as a multi-minute timeout. Task #507
# fixed exactly such an entry: the a11oy component installed its chart into
# namespace `szl-vessels` while the chart templates hardcode `szl-a11oy`, and its
# readiness wait targeted a DaemonSet `a11oy-policy-agent` that the chart never
# creates (the chart deploys a Deployment named `a11oy`). Nothing caught it —
# `zarf package create` happily builds it; only a live `deploy` reveals the
# never-satisfiable wait. The other components (vessels, uds-mesh, pepr) can
# drift the same way.
#
# This guard statically asserts two internal-consistency properties of every
# component in uds/zarf.yaml, with NO live cluster:
#
#   1. NAMESPACE AGREEMENT — for every chart whose `localPath` resolves to a real
#      local chart, the namespace the chart's templates actually render into
#      (every rendered resource's metadata.namespace, driven by .Values.namespace)
#      must equal the namespace the component DECLARES for that chart in
#      uds/zarf.yaml. A chart that renders into szl-a11oy while the component says
#      szl-vessels is the #507 bug.
#
#   2. WAIT-TARGET REALITY — every `actions.onDeploy.{before,after}[].wait.cluster`
#      target (kind + name + namespace) must correspond to a resource the
#      component's own resolvable chart/manifests ACTUALLY create. A wait on a
#      DaemonSet the chart never renders can never go Ready.
#
# CONSERVATIVE BY DESIGN — to never go red on the pre-existing demo gaps in
# uds/zarf.yaml (charts/manifests that are not vendored locally, e.g. vessels,
# uds-mesh, pepr-webhook), the guard only FAILS on a *provable* contradiction
# against a resolvable source:
#   * Namespace agreement is checked only for charts that resolve to a real dir.
#   * A namespaced wait target is enforced only when the component has a resolved
#     source (chart or manifest group) that targets that same namespace; if
#     nothing resolvable touches that namespace the target is UNVERIFIABLE and is
#     reported (not failed).
#   * Cluster-scoped wait targets (no namespace — e.g. a `condition: exists` wait
#     on a MutatingWebhookConfiguration that a controller creates at runtime) are
#     never failed; a match is noted, a miss is reported as UNVERIFIABLE.
# This is enough to catch the entire #507 class (a resolvable chart contradicting
# its own component) while staying green on the parts of the file that legitimately
# reference not-yet-vendored sources.
#
# The bespoke matching logic lives in validate(), a pure function over already
# structured inputs, so deploy-entry-checks.test.py can feed it deliberately
# broken fixtures (the #507 namespace/DaemonSet bug) and assert it FAILS — i.e.
# the guard cannot silently pass vacuously. `helm template` stays in the CLI /
# workflow (a well-tested external tool); validate() never shells out.
#
# Usage:
#   deploy-entry-checks.py check <repo_root>
#
# Exits 0 when every component is internally consistent, 1 (printing GitHub
# ::error annotations) on any contradiction, 2 on a usage/parse error.

import argparse
import os
import subprocess
import sys

try:
    import yaml
except ImportError:
    sys.stderr.write("ERROR: PyYAML is required (pip install pyyaml).\n")
    sys.exit(2)


ZARF_PATH = os.path.join("uds", "zarf.yaml")


def err(msg):
    print("::error::" + msg)


def note(msg):
    print("note: " + msg)


# ── resource extraction helpers ──────────────────────────────────────────────
def _resources_from_docs(docs):
    """Reduce a list of parsed YAML docs to {kind,name,namespace} triples."""
    out = []
    for d in docs:
        if not isinstance(d, dict):
            continue
        kind = d.get("kind")
        meta = d.get("metadata") or {}
        name = meta.get("name") if isinstance(meta, dict) else None
        if not kind or not name:
            continue
        ns = meta.get("namespace") if isinstance(meta, dict) else None
        out.append({"kind": kind, "name": name, "namespace": ns})
    return out


def render_chart(chart_dir, helm_bin):
    """helm template a chart dir to {kind,name,namespace} resources.

    Raises RuntimeError on a render failure so the caller fails loudly rather
    than silently skipping a chart that should have been validated.
    """
    proc = subprocess.run(
        [helm_bin, "template", os.path.basename(chart_dir.rstrip("/")), chart_dir],
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        raise RuntimeError(
            "helm template failed for %s:\n%s" % (chart_dir, proc.stderr.strip())
        )
    docs = list(yaml.safe_load_all(proc.stdout))
    return _resources_from_docs(docs)


def parse_manifest(path):
    with open(path, "r", encoding="utf-8") as fh:
        docs = list(yaml.safe_load_all(fh))
    return _resources_from_docs(docs)


# ── the pure, testable core ──────────────────────────────────────────────────
def validate(components):
    """Validate structured component inputs. Pure — no I/O, no helm.

    `components` is a list of dicts:
      {
        "name": <component name>,
        "sources": [                      # resolvable charts + manifest groups
          {
            "kind": "chart" | "manifest",
            "label": <chart name or manifest group name>,
            "declared_namespace": <ns the component assigns this source>,
            "resources": [ {kind,name,namespace}, ... ],   # rendered/parsed
          }, ...
        ],
        "unresolved": [ <human label of a chart/manifest that did not resolve> ],
        "waits": [ {"phase","kind","name","namespace","condition","description"} ],
      }

    Returns (violations, notes) — both lists of strings. A non-empty
    `violations` means the build must fail.
    """
    violations = []
    notes = []

    for comp in components:
        cname = comp["name"]
        sources = comp.get("sources", [])

        # ── 1. namespace agreement (charts only) ──────────────────────────────
        for src in sources:
            if src["kind"] != "chart":
                continue
            declared = src["declared_namespace"]
            rendered_ns = sorted(
                {
                    r["namespace"]
                    for r in src["resources"]
                    if r.get("namespace")
                }
            )
            bad = [ns for ns in rendered_ns if ns != declared]
            if bad:
                violations.append(
                    "component '%s' chart '%s' is declared in namespace '%s' but its "
                    "templates render resources into %s — the chart would deploy into a "
                    "DIFFERENT namespace than the component installs it in (this is the "
                    "Task #507 a11oy bug). Align the component's chart namespace with "
                    "the chart's .Values.namespace."
                    % (cname, src["label"], declared, bad)
                )

        # Build the component's "things it actually creates" index.
        # namespaced_created: (kind,name,ns) for resources with an explicit ns,
        #   PLUS resources with no explicit ns are credited to their source's
        #   declared namespace (they inherit the helm release / manifest ns).
        # cluster_created: (kind,name) for resources with NO explicit namespace
        #   (cluster-scoped candidates).
        namespaced_created = set()
        cluster_created = set()
        source_namespaces = set()
        for src in sources:
            declared = src["declared_namespace"]
            if declared:
                source_namespaces.add(declared)
            for r in src["resources"]:
                if r.get("namespace"):
                    namespaced_created.add((r["kind"], r["name"], r["namespace"]))
                else:
                    if declared:
                        namespaced_created.add((r["kind"], r["name"], declared))
                    cluster_created.add((r["kind"], r["name"]))

        # ── 2. wait-target reality ────────────────────────────────────────────
        for w in comp.get("waits", []):
            tgt = "%s/%s" % (w["kind"], w["name"])
            desc = w.get("description") or ""
            if w.get("namespace"):
                ns = w["namespace"]
                if ns not in source_namespaces and not any(
                    r["namespace"] == ns
                    for s in sources
                    for r in s["resources"]
                ):
                    notes.append(
                        "component '%s' wait on %s in ns '%s' is UNVERIFIABLE — no "
                        "resolvable chart/manifest in this component targets that "
                        "namespace (%s)." % (cname, tgt, ns, desc or "no description")
                    )
                    continue
                if (w["kind"], w["name"], ns) in namespaced_created:
                    notes.append(
                        "component '%s' wait on %s in ns '%s' OK." % (cname, tgt, ns)
                    )
                else:
                    created = sorted(
                        "%s/%s" % (k, n)
                        for (k, n, q) in namespaced_created
                        if q == ns
                    )
                    violations.append(
                        "component '%s' waits for %s in namespace '%s' to become ready, "
                        "but its resolvable chart/manifests create no such resource in "
                        "that namespace — the wait can never succeed and the deploy will "
                        "TIME OUT (this is the Task #507 a11oy DaemonSet bug). Resources "
                        "actually created in '%s': %s"
                        % (cname, tgt, ns, ns, created or "(none)")
                    )
            else:
                # Cluster-scoped wait (no namespace). Never fail — these are often
                # created by a controller at runtime (e.g. Pepr's
                # MutatingWebhookConfiguration, condition: exists).
                if (w["kind"], w["name"]) in cluster_created:
                    notes.append(
                        "component '%s' cluster-scoped wait on %s OK." % (cname, tgt)
                    )
                else:
                    notes.append(
                        "component '%s' cluster-scoped wait on %s is UNVERIFIABLE — not "
                        "rendered by this component's resolvable sources (likely created "
                        "at runtime by a controller). %s"
                        % (cname, tgt, desc or "")
                    )

        for u in comp.get("unresolved", []):
            notes.append(
                "component '%s' references '%s' which does not resolve to a local "
                "chart/manifest — skipped (cannot statically verify)." % (cname, u)
            )

    return violations, notes


# ── CLI: build structured inputs from the repo, then validate() ──────────────
def _resolve(rel, bases):
    for b in bases:
        cand = os.path.join(b, rel)
        if os.path.exists(cand):
            return cand
    return None


def _iter_waits(component):
    actions = component.get("actions") or {}
    on_deploy = actions.get("onDeploy") or {}
    for phase in ("before", "after"):
        for act in on_deploy.get(phase) or []:
            wait = (act or {}).get("wait") or {}
            cluster = wait.get("cluster")
            if not cluster:
                continue
            yield {
                "phase": phase,
                "kind": cluster.get("kind"),
                "name": cluster.get("name"),
                "namespace": cluster.get("namespace"),
                "condition": cluster.get("condition"),
                "description": act.get("description"),
            }


def build_components(repo_root, helm_bin):
    zarf_file = os.path.join(repo_root, ZARF_PATH)
    if not os.path.exists(zarf_file):
        raise RuntimeError("not found: %s" % zarf_file)
    with open(zarf_file, "r", encoding="utf-8") as fh:
        zarf = yaml.safe_load(fh)

    uds_dir = os.path.dirname(zarf_file)
    # localPath / manifest files are relative to the zarf.yaml dir (uds/); also
    # try the repo root, since the local charts live at <repo>/charts/*.
    bases = [uds_dir, repo_root]

    out = []
    for comp in zarf.get("components") or []:
        entry = {
            "name": comp.get("name"),
            "sources": [],
            "unresolved": [],
            "waits": list(_iter_waits(comp)),
        }

        for chart in comp.get("charts") or []:
            label = chart.get("name")
            declared = chart.get("namespace")
            local_path = chart.get("localPath")
            chart_dir = _resolve(local_path, bases) if local_path else None
            if chart_dir and os.path.isdir(chart_dir):
                entry["sources"].append(
                    {
                        "kind": "chart",
                        "label": label,
                        "declared_namespace": declared,
                        "resources": render_chart(chart_dir, helm_bin),
                    }
                )
            else:
                entry["unresolved"].append("chart '%s' (localPath %s)" % (label, local_path))

        for man in comp.get("manifests") or []:
            label = man.get("name")
            declared = man.get("namespace")
            resources = []
            any_resolved = False
            for f in man.get("files") or []:
                fpath = _resolve(f, bases)
                if fpath and os.path.isfile(fpath):
                    any_resolved = True
                    resources.extend(parse_manifest(fpath))
                else:
                    entry["unresolved"].append("manifest file '%s'" % f)
            if any_resolved:
                entry["sources"].append(
                    {
                        "kind": "manifest",
                        "label": label,
                        "declared_namespace": declared,
                        "resources": resources,
                    }
                )

        out.append(entry)
    return out


def cmd_check(args):
    helm_bin = os.environ.get("HELM_BIN", "helm")
    try:
        components = build_components(args.repo_root, helm_bin)
    except RuntimeError as e:
        err(str(e))
        return 2

    violations, notes = validate(components)
    for n in notes:
        note(n)
    if violations:
        for v in violations:
            err(v)
        print(
            "\nFAIL: %d internally-inconsistent deploy entr%s in %s."
            % (len(violations), "y" if len(violations) == 1 else "ies", ZARF_PATH)
        )
        return 1
    print(
        "OK: every component in %s is internally consistent "
        "(chart namespaces agree; every verifiable wait targets a real resource)."
        % ZARF_PATH
    )
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="cmd", required=True)
    p_check = sub.add_parser("check", help="validate uds/zarf.yaml components")
    p_check.add_argument("repo_root", help="path to the repo root")
    p_check.set_defaults(func=cmd_check)
    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
