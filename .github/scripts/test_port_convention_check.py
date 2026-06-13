#!/usr/bin/env python3
# Copyright 2026 SZL Holdings
# SPDX-License-Identifier: Apache-2.0
"""
test_port_convention_check.py — negative-fixture self-test for the port-convention
guard (.github/scripts/port_convention_check.py).

WHY THIS EXISTS
The port-convention guard asserts every `spec.network.allow` rule (plus monitor /
expose targetPorts) names the destination workload's REAL listener port, derived
from the deployment manifests + the szl-receipts chart. But the checker is itself
just code: if a check is commented out, weakened, or made to pass vacuously,
NOTHING would catch that and CI would stay green while guarding nothing. This test
feeds the REAL checker deliberately-BROKEN fixtures and asserts it FAILS on each,
plus asserts it PASSES on a known-good fixture — mirroring the repo's other guard
self-tests (teardown-guard, organ-package-guard).

It invokes the EXACT script the workflow runs as a subprocess against each fixture
tree, so the assertion is end-to-end: real parsing, real exit code.

Usage: python3 .github/scripts/test_port_convention_check.py
Exit 0 if every case behaves as expected, 1 otherwise.
"""

import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
CHECKER = os.path.join(HERE, "port_convention_check.py")


def good_files():
    """A minimal but realistic two-organ + receipts fixture that the checker must
    PASS: a11oy listens on 7860, amaru on 8080, szl-receipts-server on 8080, and
    every allow/monitor port names the destination's real listener."""
    a11oy_dep = """apiVersion: apps/v1
kind: Deployment
metadata:
  name: a11oy
spec:
  template:
    metadata:
      labels:
        app: a11oy
    spec:
      containers:
        - name: a11oy
          ports:
            - name: http
              containerPort: 7860
"""
    amaru_dep = """apiVersion: apps/v1
kind: Deployment
metadata:
  name: amaru
spec:
  template:
    metadata:
      labels:
        app: amaru
    spec:
      containers:
        - name: amaru
          ports:
            - name: http
              containerPort: 8080
"""
    receipts_values = """server:
  name: szl-receipts-server
  port: 8080
"""
    a11oy_pkg = """apiVersion: uds.dev/v1alpha1
kind: Package
metadata:
  name: a11oy
spec:
  network:
    allow:
      - direction: Egress
        selector:
          app: a11oy
        remoteGenerated: KubeAPI
        description: "DNS"
      - direction: Egress
        selector:
          app: a11oy
        remoteSelector:
          app: amaru
        port: 8080
        description: "a11oy -> amaru"
      - direction: Egress
        selector:
          app: a11oy
        remoteSelector:
          app: szl-receipts-server
        port: 8080
        description: "a11oy -> receipts"
      - direction: Ingress
        selector:
          app: a11oy
        remoteSelector:
          app: amaru
        port: 7860
        description: "amaru -> a11oy"
  monitor:
    - selector:
        app: a11oy
      targetPort: 7860
      description: "a11oy metrics"
"""
    amaru_pkg = """apiVersion: uds.dev/v1alpha1
kind: Package
metadata:
  name: amaru
spec:
  network:
    allow:
      - direction: Egress
        selector:
          app: amaru
        remoteSelector:
          app: a11oy
        port: 7860
        description: "amaru -> a11oy"
      - direction: Ingress
        selector:
          app: amaru
        remoteSelector:
          app: a11oy
        port: 8080
        description: "a11oy -> amaru"
  monitor:
    - selector:
        app: amaru
      targetPort: 8080
      description: "amaru metrics"
"""
    return {
        "packages/a11oy/manifests/deployment.yaml": a11oy_dep,
        "packages/amaru/manifests/deployment.yaml": amaru_dep,
        "charts/szl-receipts/values.yaml": receipts_values,
        "packages/a11oy/uds-package.yaml": a11oy_pkg,
        "packages/amaru/uds-package.yaml": amaru_pkg,
    }


def write_fixture(root, files):
    for rel, content in files.items():
        path = os.path.join(root, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as fh:
            fh.write(content)


def run_checker(root):
    proc = subprocess.run(
        [sys.executable, CHECKER, root],
        capture_output=True,
        text=True,
    )
    return proc.returncode, proc.stdout + proc.stderr


PASS = 0
FAIL = 0


def expect(name, mutate, want_fail):
    global PASS, FAIL
    files = good_files()
    if mutate is not None:
        mutate(files)
    with tempfile.TemporaryDirectory() as root:
        write_fixture(root, files)
        rc, out = run_checker(root)
    failed = rc != 0
    if failed == want_fail:
        verb = "FAIL-expected" if want_fail else "PASS-expected"
        print(f"ok   {verb}: {name}")
        PASS += 1
    else:
        verb = "FAIL" if want_fail else "PASS"
        print(f"FAIL {verb}-expected but checker exited {rc}: {name}")
        for line in out.splitlines():
            print(f"       | {line}")
        FAIL += 1


# ── known-good fixture: the checker must PASS ────────────────────────────────
expect("known-good consistent ports passes", None, want_fail=False)


# ── negative fixtures: the checker must FAIL on each ─────────────────────────
def egress_port_wrong(files):
    # The exact Task #638 regression: an egress rule -> a11oy on 8080 (a11oy is 7860).
    files["packages/amaru/uds-package.yaml"] = files[
        "packages/amaru/uds-package.yaml"
    ].replace(
        "          app: a11oy\n        port: 7860\n        description: \"amaru -> a11oy\"",
        "          app: a11oy\n        port: 8080\n        description: \"amaru -> a11oy\"",
    )


expect("egress port != destination listener is rejected", egress_port_wrong, want_fail=True)


def ingress_port_wrong(files):
    # amaru's own listener is 8080; claim 7860 on the a11oy -> amaru ingress.
    files["packages/amaru/uds-package.yaml"] = files[
        "packages/amaru/uds-package.yaml"
    ].replace(
        "          app: a11oy\n        port: 8080\n        description: \"a11oy -> amaru\"",
        "          app: a11oy\n        port: 7860\n        description: \"a11oy -> amaru\"",
    )


expect("ingress port != own listener is rejected", ingress_port_wrong, want_fail=True)


def monitor_targetport_wrong(files):
    files["packages/a11oy/uds-package.yaml"] = files[
        "packages/a11oy/uds-package.yaml"
    ].replace(
        "      targetPort: 7860\n      description: \"a11oy metrics\"",
        "      targetPort: 8080\n      description: \"a11oy metrics\"",
    )


expect("monitor.targetPort != own listener is rejected", monitor_targetport_wrong, want_fail=True)


def unknown_destination(files):
    # An egress to an app with no manifest and not in STATIC_LISTENERS must fail
    # loud so the port table cannot silently go incomplete.
    files["packages/a11oy/uds-package.yaml"] = files[
        "packages/a11oy/uds-package.yaml"
    ].replace(
        "      - direction: Ingress\n        selector:\n          app: a11oy\n",
        "      - direction: Egress\n        selector:\n          app: a11oy\n"
        "        remoteSelector:\n          app: ghost\n        port: 9999\n"
        "        description: \"a11oy -> ghost\"\n"
        "      - direction: Ingress\n        selector:\n          app: a11oy\n",
    )


expect("egress to an unknown destination app is rejected", unknown_destination, want_fail=True)


def stale_static_listener(files):
    # Give vessels a real manifest whose containerPort (9090) contradicts
    # STATIC_LISTENERS['vessels']=8080 -> the static map is stale, must fail.
    files["packages/vessels/manifests/deployment.yaml"] = """apiVersion: apps/v1
kind: Deployment
metadata:
  name: vessels
spec:
  template:
    metadata:
      labels:
        app: vessels
    spec:
      containers:
        - name: vessels
          ports:
            - name: http
              containerPort: 9090
"""


expect("stale STATIC_LISTENERS vs derived manifest is rejected", stale_static_listener, want_fail=True)


print()
print("=" * 67)
print(f"port-convention-guard self-test: {PASS} passed, {FAIL} failed")
print("=" * 67)
sys.exit(0 if FAIL == 0 else 1)
