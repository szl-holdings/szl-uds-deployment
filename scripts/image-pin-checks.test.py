#!/usr/bin/env python3
# Copyright 2026 SZL Holdings
# SPDX-License-Identifier: Apache-2.0
#
# image-pin-checks.test.py — Self-test for scripts/image-pin-checks.py.
#
# Feeds each check synthetic PRISTINE fixtures (asserts PASS) and deliberately
# BROKEN fixtures (asserts FAIL), one per regression class. Catches a future edit
# that neuters a check (green while guarding nothing). Run by the `self-test` job
# in .github/workflows/image-pin-guard.yml. No crane, no network — pure fixtures.

import json
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
GUARD = os.path.join(HERE, "image-pin-checks.py")

PASS = 0
FAILED = 0


def write(root, rel, text):
    path = os.path.join(root, rel)
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(text)
    return path


def run(*args):
    proc = subprocess.run(
        [sys.executable, GUARD, *args], capture_output=True, text=True
    )
    return proc.returncode, proc.stdout + proc.stderr


def case(label, expect_pass, rc):
    global PASS, FAILED
    ok = (rc == 0) if expect_pass else (rc != 0)
    if ok:
        PASS += 1
        print("ok   - %s" % label)
    else:
        FAILED += 1
        print(
            "FAIL - %s (rc=%d, expected %s)"
            % (label, rc, "pass" if expect_pass else "fail")
        )


DIGEST = "@sha256:" + "b" * 64


def zarf(images):
    comps = ""
    for i, img in enumerate(images):
        comps += "  - name: c%d\n    images:\n      - %s\n" % (i, img)
    if not images:
        comps = "  - name: empty\n"
    return "kind: ZarfPackageConfig\nmetadata:\n  name: t\ncomponents:\n" + comps


# ── collect-pins ────────────────────────────────────────────────────────────────
with tempfile.TemporaryDirectory() as root:
    write(root, "zarf.yaml", zarf(["ghcr.io/szl-holdings/app:v1" + DIGEST]))
    write(
        root,
        "packages/szl-receipts/zarf.yaml",
        zarf(["ghcr.io/szl-holdings/szl-receipts-server:uds-v0.4.0" + DIGEST]),
    )
    rc, _ = run("collect-pins", "--root", root)
    case("collect-pins: pins present passes", True, rc)

with tempfile.TemporaryDirectory() as root:
    write(root, "zarf.yaml", zarf(["ghcr.io/szl-holdings/app:v1"]))  # no @sha256
    rc, _ = run("collect-pins", "--root", root)
    case("collect-pins: no @sha256 pins fails", False, rc)


# ── classify-manifest ────────────────────────────────────────────────────────────
with tempfile.TemporaryDirectory() as root:
    single = write(
        root,
        "single.json",
        json.dumps(
            {
                "mediaType": "application/vnd.oci.image.manifest.v1+json",
                "config": {},
                "layers": [],
            }
        ),
    )
    rc, _ = run("classify-manifest", single)
    case("classify-manifest: single-platform manifest passes", True, rc)

    oci_index = write(
        root,
        "ociindex.json",
        json.dumps(
            {
                "mediaType": "application/vnd.oci.image.index.v1+json",
                "manifests": [{"digest": "sha256:1"}, {"digest": "sha256:2"}],
            }
        ),
    )
    rc, _ = run("classify-manifest", oci_index)
    case("classify-manifest: OCI image.index fails", False, rc)

    docker_list = write(
        root,
        "dockerlist.json",
        json.dumps(
            {
                "mediaType": "application/vnd.docker.distribution.manifest.list.v2+json",
                "manifests": [{"digest": "sha256:1"}],
            }
        ),
    )
    rc, _ = run("classify-manifest", docker_list)
    case("classify-manifest: docker manifest.list fails", False, rc)

    # mediaType omitted but a manifests[] array is present -> still an index
    sneaky = write(
        root,
        "sneaky.json",
        json.dumps({"manifests": [{"digest": "sha256:1"}]}),
    )
    rc, _ = run("classify-manifest", sneaky)
    case("classify-manifest: .manifests[] with no mediaType fails", False, rc)


# ── start-routes-bundle ──────────────────────────────────────────────────────────
GOOD_TASKS = (
    "tasks:\n"
    "  - name: bundle\n"
    "    actions:\n"
    "      - cmd: echo build\n"
    "  - name: start\n"
    "    actions:\n"
    "      - task: bundle\n"
    "      - cmd: echo deploy\n"
)

with tempfile.TemporaryDirectory() as root:
    write(root, "tasks.yaml", GOOD_TASKS)
    rc, _ = run("start-routes-bundle", "--root", root)
    case("start-routes-bundle: start -> bundle passes", True, rc)

with tempfile.TemporaryDirectory() as root:
    write(
        root,
        "tasks.yaml",
        "tasks:\n  - name: start\n    actions:\n      - task: bundle\n",
    )
    rc, _ = run("start-routes-bundle", "--root", root)
    case("start-routes-bundle: missing 'bundle' task fails", False, rc)

with tempfile.TemporaryDirectory() as root:
    write(
        root,
        "tasks.yaml",
        "tasks:\n  - name: bundle\n    actions:\n      - cmd: echo build\n",
    )
    rc, _ = run("start-routes-bundle", "--root", root)
    case("start-routes-bundle: missing 'start' task fails", False, rc)

with tempfile.TemporaryDirectory() as root:
    write(
        root,
        "tasks.yaml",
        "tasks:\n"
        "  - name: bundle\n"
        "    actions:\n"
        "      - cmd: echo build\n"
        "  - name: start\n"
        "    actions:\n"
        "      - cmd: echo deploy-only\n",
    )
    rc, _ = run("start-routes-bundle", "--root", root)
    case("start-routes-bundle: start that skips bundle fails", False, rc)


print("\n%d passed, %d failed" % (PASS, FAILED))
if FAILED:
    print(
        "::error::image-pin guard self-test FAILED — a check no longer behaves "
        "as expected."
    )
sys.exit(1 if FAILED else 0)
