#!/usr/bin/env python3
# Copyright 2026 SZL Holdings
# SPDX-License-Identifier: Apache-2.0
"""
test_organ_package_check.py — negative-fixture self-test for the organ packaging
guard (.github/scripts/organ_package_check.py).

WHY THIS EXISTS
The organ guard protects four deployable organs (sentra, amaru, killinchu, rosie)
from packaging regressions — a silent flip to chart-based, a dropped bundle
membership, an image-ref drift, or a dropped @sha256: digest pin. But the checker
is itself just code: if one of its checks is commented out, weakened, or made to
pass vacuously, NOTHING would catch that and CI would stay green while guarding
nothing. This test feeds the REAL checker deliberately-BROKEN package fixtures and
asserts it FAILS on each, plus asserts it PASSES on a known-good fixture — so a
future edit that neuters a check is caught here in CI, mirroring the repo's other
guard self-tests (e.g. teardown-guard).

It invokes the EXACT script the workflow runs (.github/scripts/organ_package_check.py)
as a subprocess against each fixture tree, so the assertion is end-to-end: the real
parsing, the real exit code.

Usage: python3 .github/scripts/test_organ_package_check.py
Exit 0 if every case behaves as expected, 1 otherwise.
"""

import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
CHECKER = os.path.join(HERE, "organ_package_check.py")

ORGAN = "sentra"
DIGEST = "sha256:" + ("a" * 64)
DIGEST2 = "sha256:" + ("b" * 64)
PINNED = f"ghcr.io/szl-holdings/{ORGAN}:uds-v0.2.0@{DIGEST}"


def good_files():
    """Return {relpath: content} for a known-good manifests-based organ package."""
    zarf = f"""kind: ZarfPackageConfig
metadata:
  name: szl-{ORGAN}
  image: {PINNED}
components:
  - name: {ORGAN}
    required: true
    images:
      - {PINNED}
    manifests:
      - name: {ORGAN}-workload
        files:
          - manifests/deployment.yaml
"""
    deployment = f"""apiVersion: apps/v1
kind: Deployment
metadata:
  name: {ORGAN}
spec:
  template:
    spec:
      containers:
        - name: {ORGAN}
          image: {PINNED}
"""
    bundle = f"""kind: UDSBundle
metadata:
  name: szl-uds-bundle
packages:
  - name: szl-{ORGAN}
    path: ../../packages/{ORGAN}
    ref: uds-v0.2.0
"""
    return {
        f"packages/{ORGAN}/zarf.yaml": zarf,
        f"packages/{ORGAN}/manifests/deployment.yaml": deployment,
        "bundles/szl-uds-bundle/uds-bundle.yaml": bundle,
    }


def write_fixture(root, files):
    for rel, content in files.items():
        path = os.path.join(root, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as fh:
            fh.write(content)


def run_checker(root):
    proc = subprocess.run(
        [sys.executable, CHECKER, ORGAN],
        cwd=root,
        capture_output=True,
        text=True,
    )
    return proc.returncode, proc.stdout + proc.stderr


PASS = 0
FAIL = 0


def expect(name, mutate, want_fail):
    """Build a fresh good fixture, apply `mutate(files)`, run the checker, and
    assert it failed (want_fail=True) or passed (want_fail=False)."""
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
expect("known-good manifests-based package passes", None, want_fail=False)


# ── negative fixtures: the checker must FAIL on each ─────────────────────────
def flip_to_chart(files):
    # Add a charts[].localPath ../../charts/<organ> so the package silently
    # renders the chart (a flip from manifests-based to chart-based).
    z = files[f"packages/{ORGAN}/zarf.yaml"]
    z = z.replace(
        f"  - name: {ORGAN}\n    required: true\n",
        f"  - name: {ORGAN}\n    required: true\n"
        f"    charts:\n"
        f"      - name: {ORGAN}\n"
        f"        localPath: ../../charts/{ORGAN}\n"
        f"        version: 0.1.0\n"
        f"        namespace: {ORGAN}\n",
    )
    files[f"packages/{ORGAN}/zarf.yaml"] = z


expect("flip-to-chart (charts[].localPath) is rejected", flip_to_chart, want_fail=True)


def image_digest_drift(files):
    # Make the workload manifest's image digest differ from the zarf-declared one.
    drifted = PINNED.replace(DIGEST, DIGEST2)
    files[f"packages/{ORGAN}/manifests/deployment.yaml"] = files[
        f"packages/{ORGAN}/manifests/deployment.yaml"
    ].replace(PINNED, drifted)


expect("image digest drift across declaration sites is rejected", image_digest_drift, want_fail=True)


def drop_digest_pin(files):
    # Replace the @sha256: pinned ref with a mutable tag-only ref everywhere.
    tag_only = f"ghcr.io/szl-holdings/{ORGAN}:uds-v0.2.0"
    for rel in list(files):
        files[rel] = files[rel].replace(PINNED, tag_only)


expect("dropped @sha256: digest pin is rejected", drop_digest_pin, want_fail=True)


def drop_from_bundle(files):
    # Remove the szl-<organ> entry from the full-organ bundle.
    files["bundles/szl-uds-bundle/uds-bundle.yaml"] = """kind: UDSBundle
metadata:
  name: szl-uds-bundle
packages: []
"""


expect("dropped from the full-organ bundle is rejected", drop_from_bundle, want_fail=True)


print()
print("=" * 67)
print(f"organ-package-guard self-test: {PASS} passed, {FAIL} failed")
print("=" * 67)
sys.exit(0 if FAIL == 0 else 1)
