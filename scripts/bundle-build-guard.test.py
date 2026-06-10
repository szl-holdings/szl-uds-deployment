#!/usr/bin/env python3
# Copyright 2026 SZL Holdings
# SPDX-License-Identifier: Apache-2.0
#
# bundle-build-guard.test.py — Self-test for scripts/bundle-build-guard.py.
#
# Feeds the guard synthetic PRISTINE fixtures (asserts it PASSES) and a battery
# of deliberately BROKEN fixtures (asserts it FAILS, one per regression class),
# for BOTH supported build sources:
#   • a tasks.yaml task (the receipts-only ROOT bundle); and
#   • a `for organ in ...; do zarf package create` workflow loop (the FULL-ORGAN
#     bundle, whose members live at ../../packages/<organ> relative to the bundle).
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


def run_guard(root, extra):
    proc = subprocess.run(
        [sys.executable, GUARD, "--root", root] + extra,
        capture_output=True,
        text=True,
    )
    return proc.returncode, proc.stdout + proc.stderr


def write_zarf(root, path, is_gated):
    if is_gated:
        comp = "  - name: server\n    required: true\n    only:\n      flavor: upstream\n"
    else:
        comp = "  - name: app\n    required: true\n"
    write(
        root,
        os.path.join(path, "zarf.yaml"),
        "kind: ZarfPackageConfig\nmetadata:\n  name: %s\ncomponents:\n%s"
        % (os.path.basename(path), comp),
    )


# ════════════════════════════════════════════════════════════════════════════
# Build source 1: a tasks.yaml task (the receipts-only ROOT bundle)
# ════════════════════════════════════════════════════════════════════════════
def make_task_fixture(root, bundle_members, creates, gated):
    """tasks.yaml-task build fixture (root bundle).

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
        write_zarf(root, path, is_gated)


def task_args():
    return [
        "--bundle", "uds-bundle.yaml",
        "--build-kind", "task",
        "--build-file", "tasks.yaml",
        "--build-task", "bundle",
    ]


# ════════════════════════════════════════════════════════════════════════════
# Build source 2: a workflow `for organ in ...; do` loop (the FULL-ORGAN bundle)
# ════════════════════════════════════════════════════════════════════════════
BUNDLE_REL = "bundles/szl-uds-bundle/uds-bundle.yaml"
WORKFLOW_REL = ".github/workflows/uds-bundle-publish.yml"


def make_workflow_fixture(root, organs, loop_organs, loop_flavor, gated,
                          extra_create=None):
    """workflow-loop build fixture (full-organ bundle).

    organs:      list of organ names → bundle members at ../../packages/<organ>.
    loop_organs: list of organ names in the `for organ in ...; do` build loop.
    loop_flavor: bool — whether the loop's `zarf package create` carries --flavor.
    gated:       dict organ -> bool (whether packages/<organ>/zarf.yaml is gated).
    extra_create: optional literal command line (e.g. an unresolvable ${ghost}).
    """
    pkgs = []
    for organ in organs:
        pkgs.append(
            "  - name: szl-%s\n    path: ../../packages/%s\n    ref: \"0.2.0\"\n"
            % (organ, organ)
        )
    write(
        root,
        BUNDLE_REL,
        "kind: UDSBundle\nmetadata:\n  name: szl-uds-bundle\n  version: \"0.2.0\"\n"
        "packages:\n" + "".join(pkgs),
    )

    flavor = " --flavor upstream" if loop_flavor else ""
    extra = ""
    if extra_create:
        extra = "          %s\n" % extra_create
    write(
        root,
        WORKFLOW_REL,
        "name: t\non: [push]\njobs:\n  build:\n    runs-on: ubuntu-latest\n"
        "    steps:\n      - name: build organs\n        run: |\n"
        "          for organ in %s; do\n"
        "            zarf package create \"packages/${organ}\"%s \\\n"
        "              --confirm \\\n"
        "              --output-directory \"packages/${organ}\"\n"
        "          done\n%s"
        % (" ".join(loop_organs), flavor, extra),
    )

    for organ, is_gated in gated.items():
        write_zarf(root, "packages/%s" % organ, is_gated)


def workflow_args():
    return [
        "--bundle", BUNDLE_REL,
        "--build-kind", "workflow-loop",
        "--build-file", WORKFLOW_REL,
    ]


# ════════════════════════════════════════════════════════════════════════════
def case(label, expect_pass, build, args):
    global PASS, FAILED
    with tempfile.TemporaryDirectory() as root:
        build(root)
        rc, out = run_guard(root, args)
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


# ── tasks.yaml-task build source (receipts ROOT bundle) ──────────────────────
case(
    "task: gated member built with --flavor + ungated build without --flavor",
    True,
    lambda root: make_task_fixture(
        root,
        bundle_members=[("szl-receipts", "packages/szl-receipts")],
        creates=[("packages/szl-receipts", True), ("packages/a11oy", False)],
        gated={"packages/szl-receipts": True, "packages/a11oy": False},
    ),
    task_args(),
)

case(
    "task broken: bundle member with NO matching zarf package create step",
    False,
    lambda root: make_task_fixture(
        root,
        bundle_members=[
            ("szl-receipts", "packages/szl-receipts"),
            ("szl-a11oy", "packages/a11oy"),
        ],
        creates=[("packages/szl-receipts", True)],  # a11oy build step missing
        gated={"packages/szl-receipts": True, "packages/a11oy": False},
    ),
    task_args(),
)

case(
    "task broken: ungated package built WITH --flavor",
    False,
    lambda root: make_task_fixture(
        root,
        bundle_members=[("szl-receipts", "packages/szl-receipts")],
        creates=[("packages/szl-receipts", True), ("packages/a11oy", True)],
        gated={"packages/szl-receipts": True, "packages/a11oy": False},
    ),
    task_args(),
)

case(
    "task broken: gated package built WITHOUT --flavor",
    False,
    lambda root: make_task_fixture(
        root,
        bundle_members=[("szl-receipts", "packages/szl-receipts")],
        creates=[("packages/szl-receipts", False)],
        gated={"packages/szl-receipts": True},
    ),
    task_args(),
)

case(
    "task broken: build step for a package with no zarf.yaml",
    False,
    lambda root: make_task_fixture(
        root,
        bundle_members=[("szl-receipts", "packages/szl-receipts")],
        creates=[("packages/szl-receipts", True), ("packages/ghost", False)],
        gated={"packages/szl-receipts": True},
    ),
    task_args(),
)

# ── workflow-loop build source (FULL-ORGAN bundle) ───────────────────────────
case(
    "workflow: ungated organs all built by the loop without --flavor",
    True,
    lambda root: make_workflow_fixture(
        root,
        organs=["a11oy", "sentra"],
        loop_organs=["a11oy", "sentra"],
        loop_flavor=False,
        gated={"a11oy": False, "sentra": False},
    ),
    workflow_args(),
)

case(
    "workflow broken: bundle member NOT in the build loop (no such file)",
    False,
    lambda root: make_workflow_fixture(
        root,
        organs=["a11oy", "sentra", "amaru"],  # amaru is a member
        loop_organs=["a11oy", "sentra"],      # but not built by the loop
        loop_flavor=False,
        gated={"a11oy": False, "sentra": False, "amaru": False},
    ),
    workflow_args(),
)

case(
    "workflow broken: ungated organs built WITH --flavor",
    False,
    lambda root: make_workflow_fixture(
        root,
        organs=["a11oy", "sentra"],
        loop_organs=["a11oy", "sentra"],
        loop_flavor=True,  # stray --flavor silently empties ungated packages
        gated={"a11oy": False, "sentra": False},
    ),
    workflow_args(),
)

case(
    "workflow broken: gated organ built WITHOUT --flavor",
    False,
    lambda root: make_workflow_fixture(
        root,
        organs=["a11oy", "sentra"],
        loop_organs=["a11oy", "sentra"],
        loop_flavor=False,
        gated={"a11oy": False, "sentra": True},  # sentra gated, loop has no flavor
    ),
    workflow_args(),
)

case(
    "workflow broken: loop builds an organ with no zarf.yaml",
    False,
    lambda root: make_workflow_fixture(
        root,
        organs=["a11oy"],
        loop_organs=["a11oy", "ghost"],  # ghost has no packages/ghost/zarf.yaml
        loop_flavor=False,
        gated={"a11oy": False},
    ),
    workflow_args(),
)

case(
    "workflow broken: build references an unresolvable loop variable",
    False,
    lambda root: make_workflow_fixture(
        root,
        organs=["a11oy"],
        loop_organs=["a11oy"],
        loop_flavor=False,
        gated={"a11oy": False},
        extra_create='zarf package create "packages/${ghostvar}" --confirm',
    ),
    workflow_args(),
)

print("\n%d passed, %d failed" % (PASS, FAILED))
sys.exit(1 if FAILED else 0)
