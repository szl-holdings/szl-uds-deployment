#!/usr/bin/env python3
# Copyright 2026 SZL Holdings
# SPDX-License-Identifier: Apache-2.0
#
# deploy-entry-checks.test.py — negative-fixture self-test for the deploy-entry
# guard's pure core, validate().
#
# A guard is only trustworthy if it still FAILS on bad input. validate() could be
# edited to pass vacuously (green while guarding nothing). This self-test feeds it
# the exact Task #507 a11oy bug shapes and asserts it reports a violation, plus
# asserts the correct shapes pass — so deploy-entry-guard.yml runs it as a gating
# job and a neutered check turns CI red here, not in production.
#
# Pure: imports validate() directly and hands it structured inputs — no helm, no
# cluster, no zarf file.

import importlib.util
import os
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
_SPEC = importlib.util.spec_from_file_location(
    "deploy_entry_checks", os.path.join(_HERE, "deploy-entry-checks.py")
)
_MOD = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(_MOD)
validate = _MOD.validate


_FAILS = 0


def check(cond, msg):
    global _FAILS
    if cond:
        print("  ok: " + msg)
    else:
        print("  FAIL: " + msg)
        _FAILS += 1


def a11oy_chart_resources(ns):
    """The shape charts/a11oy renders into namespace `ns`."""
    return [
        {"kind": "Namespace", "name": ns, "namespace": None},
        {"kind": "ConfigMap", "name": "a11oy-doctrine", "namespace": ns},
        {"kind": "Service", "name": "szl-a11oy", "namespace": ns},
        {"kind": "Deployment", "name": "a11oy", "namespace": ns},
        {"kind": "Package", "name": "a11oy", "namespace": ns},
        {"kind": "PeerAuthentication", "name": "a11oy-strict-mtls", "namespace": ns},
    ]


def comp_a11oy(declared_ns, wait_kind, wait_name, wait_ns):
    """A component mirroring the a11oy entry: a resolvable chart that always
    renders into szl-a11oy, declared under `declared_ns`, with one wait."""
    return {
        "name": "a11oy",
        "sources": [
            {
                "kind": "chart",
                "label": "a11oy",
                "declared_namespace": declared_ns,
                # chart templates ALWAYS render into szl-a11oy regardless of how
                # the component declares it (the templates hardcode
                # .Values.namespace = szl-a11oy).
                "resources": a11oy_chart_resources("szl-a11oy"),
            }
        ],
        "unresolved": [],
        "waits": [
            {
                "phase": "after",
                "kind": wait_kind,
                "name": wait_name,
                "namespace": wait_ns,
                "condition": "Available",
                "description": "Wait for a11oy",
            }
        ],
    }


def main():
    # ── GOOD: post-#507-fix a11oy entry ──────────────────────────────────────
    good = comp_a11oy("szl-a11oy", "Deployment", "a11oy", "szl-a11oy")
    v, _ = validate([good])
    check(v == [], "fixed a11oy entry (ns szl-a11oy, wait Deployment a11oy) passes")

    # ── BAD 1: the #507 namespace mismatch (chart declared szl-vessels) ───────
    bad_ns = comp_a11oy("szl-vessels", "Deployment", "a11oy", "szl-vessels")
    v, _ = validate([bad_ns])
    check(
        any("render resources into" in x for x in v),
        "chart declared szl-vessels but rendering szl-a11oy is flagged (namespace)",
    )

    # ── BAD 2: the #507 wait on a DaemonSet the chart never creates ───────────
    bad_wait = comp_a11oy("szl-a11oy", "DaemonSet", "a11oy-policy-agent", "szl-a11oy")
    v, _ = validate([bad_wait])
    check(
        any("can never succeed" in x for x in v),
        "wait on DaemonSet a11oy-policy-agent (never created) is flagged (wait)",
    )

    # ── BAD 3: both at once (the literal pre-#507 entry) ──────────────────────
    bad_both = comp_a11oy("szl-vessels", "DaemonSet", "a11oy-policy-agent", "szl-vessels")
    v, _ = validate([bad_both])
    check(len(v) >= 1, "the literal pre-#507 entry (both bugs) is flagged")

    # ── UNVERIFIABLE: an unresolved chart never fails (vessels/uds-mesh) ──────
    unresolved = {
        "name": "vessels-web",
        "sources": [],
        "unresolved": ["chart 'vessels' (localPath charts/vessels)"],
        "waits": [
            {
                "phase": "after",
                "kind": "Deployment",
                "name": "vessels-web",
                "namespace": "szl-vessels",
                "condition": "Available",
                "description": "Wait for vessels-web",
            }
        ],
    }
    v, n = validate([unresolved])
    check(v == [], "a component whose chart does not resolve does NOT fail the build")
    check(
        any("UNVERIFIABLE" in x for x in n),
        "the unresolved wait is reported as UNVERIFIABLE (not silently dropped)",
    )

    # ── UNVERIFIABLE: cluster-scoped runtime wait (Pepr) never fails ──────────
    pepr = {
        "name": "szl-pepr-receipts",
        "sources": [],
        "unresolved": ["manifest file 'manifests/pepr-webhook.yaml'"],
        "waits": [
            {
                "phase": "after",
                "kind": "MutatingWebhookConfiguration",
                "name": "szl-governance-receipts",
                "namespace": None,
                "condition": "exists",
                "description": "Verify Pepr webhook is registered",
            }
        ],
    }
    v, _ = validate([pepr])
    check(v == [], "a cluster-scoped condition:exists wait never fails the build")

    # ── A correct cluster-scoped wait is recognised as a match ────────────────
    cluster_ok = {
        "name": "x",
        "sources": [
            {
                "kind": "chart",
                "label": "x",
                "declared_namespace": "x-ns",
                "resources": [
                    {"kind": "Namespace", "name": "x-ns", "namespace": None},
                    {"kind": "Deployment", "name": "x", "namespace": "x-ns"},
                ],
            }
        ],
        "unresolved": [],
        "waits": [
            {
                "phase": "after",
                "kind": "Namespace",
                "name": "x-ns",
                "namespace": None,
                "condition": "exists",
                "description": "ns exists",
            }
        ],
    }
    v, n = validate([cluster_ok])
    check(v == [], "a cluster-scoped wait on a resource the chart DOES create passes")
    check(any("cluster-scoped wait" in x and "OK" in x for x in n),
          "the matching cluster-scoped wait is noted as OK")

    print()
    if _FAILS:
        print("SELF-TEST FAILED: %d assertion(s) failed." % _FAILS)
        return 1
    print("SELF-TEST PASSED: validate() fails on the #507 bug shapes and "
          "passes on the fixed / unverifiable shapes.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
