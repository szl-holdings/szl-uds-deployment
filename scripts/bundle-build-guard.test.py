#!/usr/bin/env python3
# Copyright 2026 SZL Holdings
# SPDX-License-Identifier: Apache-2.0
#
# bundle-build-guard.test.py — Self-test for scripts/bundle-build-guard.py.
#
# Feeds the guard synthetic PRISTINE fixtures (asserts it PASSES) and a battery
# of deliberately BROKEN fixtures (asserts it FAILS, one per regression class).
# This is the safety net that catches a future edit which neuters a check —
# making the guard pass vacuously (green while guarding nothing). Run by the
# `self-test` job in .github/workflows/bundle-build-guard.yml.
#
# No cluster, no zarf, no network — pure filesystem fixtures in a temp dir.

import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
GUARD = os.path.join(HERE, "bundle-build-guard.py")

PASS = 0
FAILED = 0


def write(root, rel, text):
    path = os.path.join(root, rel)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(text)


def run_guard(root):
    proc = subprocess.run(
        [sys.executable, GUARD, "--root", root],
        capture_output=True,
        text=True,
    )
    return proc.returncode, proc.stdout + proc.stderr


def make_fixture(root, bundle_members, creates, gated):
    """Build a minimal fixture tree.

    bundle_members: list of (name, path) for uds-bundle.yaml local members.
    creates:        list of (path, has_flavor) for the bundle task.
    gated:          dict path -> bool (whether that package zarf.yaml is gated).
    """
    pkgs = [
        "  - name: init\n    repository: ghcr.io/zarf-dev/packages/init\n    ref: v0.77.0\n"
    ]
    for name, path in bundle_members:
        pkgs.append("  - name: %s\n    path: ./%s\n    ref: 0.4.0\n" % (name, path))
    write(
        root,
        "uds-bundle.yaml",
        "kind: UDSBundle\nmetadata:\n  name: t\n  version: 0.4.0\npackages:\n"
        + "".join(pkgs),
    )

    actions = []
    for path, has_flavor in creates:
        flavor = " --flavor upstream" if has_flavor else ""
        actions.append(
            "      - description: \"build %s\"\n        cmd: |\n"
            "          zarf package create %s%s --output %s --confirm --no-progress\n"
            % (path, path, flavor, path)
        )
    write(
        root,
        "tasks.yaml",
        "variables: []\ntasks:\n  - name: bundle\n    description: \"x\"\n    actions:\n"
        + "".join(actions),
    )

    for path, is_gated in gated.items():
        if is_gated:
            comp = (
                "  - name: server\n    required: true\n    only:\n      flavor: upstream\n"
            )
        else:
            comp = "  - name: app\n    required: true\n"
        write(
            root,
            os.path.join(path, "zarf.yaml"),
            "kind: ZarfPackageConfig\nmetadata:\n  name: %s\ncomponents:\n%s"
            % (os.path.basename(path), comp),
        )


def case(label, expect_pass, build):
    global PASS, FAILED
    with tempfile.TemporaryDirectory() as root:
        build(root)
        rc, out = run_guard(root)
        ok = (rc == 0) if expect_pass else (rc != 0)
        if ok:
            PASS += 1
            print("ok   - %s" % label)
        else:
            FAILED += 1
            print("FAIL - %s (rc=%d, expected %s)" % (
                label, rc, "pass" if expect_pass else "fail"))
            print("       guard output:\n" + "\n".join(
                "         " + ln for ln in out.splitlines()))


# ── PRISTINE: receipts (gated, with flavor) + a11oy (ungated, no flavor) ─────
case(
    "pristine: gated member built with --flavor + ungated build without --flavor",
    True,
    lambda root: make_fixture(
        root,
        bundle_members=[("szl-receipts", "packages/szl-receipts")],
        creates=[("packages/szl-receipts", True), ("packages/a11oy", False)],
        gated={"packages/szl-receipts": True, "packages/a11oy": False},
    ),
)

# ── BROKEN 1: member added to bundle but no pre-build step (break class 1) ────
case(
    "broken: bundle member with NO matching zarf package create step",
    False,
    lambda root: make_fixture(
        root,
        bundle_members=[
            ("szl-receipts", "packages/szl-receipts"),
            ("szl-a11oy", "packages/a11oy"),
        ],
        creates=[("packages/szl-receipts", True)],  # a11oy build step missing
        gated={"packages/szl-receipts": True, "packages/a11oy": False},
    ),
)

# ── BROKEN 2: ungated package built WITH --flavor (break class 2) ────────────
case(
    "broken: ungated package built WITH --flavor",
    False,
    lambda root: make_fixture(
        root,
        bundle_members=[("szl-receipts", "packages/szl-receipts")],
        creates=[("packages/szl-receipts", True), ("packages/a11oy", True)],
        gated={"packages/szl-receipts": True, "packages/a11oy": False},
    ),
)

# ── BROKEN 3: gated package built WITHOUT --flavor (symmetric break) ─────────
case(
    "broken: gated package built WITHOUT --flavor",
    False,
    lambda root: make_fixture(
        root,
        bundle_members=[("szl-receipts", "packages/szl-receipts")],
        creates=[("packages/szl-receipts", False)],
        gated={"packages/szl-receipts": True},
    ),
)

# ── BROKEN 4: build step references a package with no zarf.yaml ───────────────
def _missing_zarf(root):
    make_fixture(
        root,
        bundle_members=[("szl-receipts", "packages/szl-receipts")],
        creates=[("packages/szl-receipts", True), ("packages/ghost", False)],
        gated={"packages/szl-receipts": True},
    )


case("broken: build step for a package with no zarf.yaml", False, _missing_zarf)

print("\n%d passed, %d failed" % (PASS, FAILED))
sys.exit(1 if FAILED else 0)
