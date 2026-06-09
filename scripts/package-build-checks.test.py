#!/usr/bin/env python3
# Copyright 2026 SZL Holdings
# SPDX-License-Identifier: Apache-2.0
#
# package-build-checks.test.py — Self-test for scripts/package-build-checks.py.
#
# Feeds the guard synthetic PRISTINE fixtures (asserts it PASSES) and a battery of
# deliberately BROKEN fixtures (asserts it FAILS, one per regression class). This
# is the safety net that catches a future edit which neuters a check — making the
# guard pass vacuously (green while guarding nothing). Run by the `self-test` job
# in .github/workflows/package-build-guard.yml.
#
# No cluster, no zarf, no helm, no network — pure filesystem fixtures in a temp
# dir, so the assertion logic is exercised without building anything.

import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
GUARD = os.path.join(HERE, "package-build-checks.py")

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


# ── rendered-keygen fixtures ────────────────────────────────────────────────────
def rendered_job(namespace="szl-receipts", script=None):
    if script is None:
        script = (
            "set -e\n"
            'NAMESPACE="szl-receipts"\n'
            'KEY_FILE="ed25519.pem"\n'
            'SECRET_NAME="szl-receipts-ed25519"\n'
            'kubectl create secret generic "$SECRET_NAME" '
            '--from-file="${KEY_FILE}=/tmp/$KEY_FILE" -n "$NAMESPACE"\n'
        )
    indented = "".join("              " + ln for ln in script.splitlines(keepends=True))
    return (
        "apiVersion: batch/v1\n"
        "kind: Job\n"
        "metadata:\n"
        "  name: szl-key-init\n"
        "  namespace: %s\n"
        "spec:\n"
        "  template:\n"
        "    spec:\n"
        "      containers:\n"
        "        - name: keygen\n"
        "          image: bitnami/kubectl\n"
        "          args:\n"
        "            - |\n"
        "%s" % (namespace, indented)
    )


with tempfile.TemporaryDirectory() as root:
    # PRISTINE
    p = write(root, "good-rendered.yaml", rendered_job())
    rc, _ = run("rendered-keygen", p)
    case("rendered-keygen: pristine Job passes", True, rc)

    # BROKEN: Job missing
    p = write(root, "no-job.yaml", "kind: ConfigMap\nmetadata:\n  name: x\n")
    rc, _ = run("rendered-keygen", p)
    case("rendered-keygen: missing szl-key-init Job fails", False, rc)

    # BROKEN: wrong namespace on the Job object
    p = write(root, "wrong-ns.yaml", rendered_job(namespace="pepr-system"))
    rc, _ = run("rendered-keygen", p)
    case("rendered-keygen: Job namespace != szl-receipts fails", False, rc)

    # BROKEN: rendered NAMESPACE value drifted
    bad = (
        "set -e\n"
        'NAMESPACE="pepr-system"\n'
        'KEY_FILE="ed25519.pem"\n'
        'SECRET_NAME="szl-receipts-ed25519"\n'
        'kubectl create secret generic "$SECRET_NAME" '
        '--from-file="${KEY_FILE}=/tmp/x" -n "$NAMESPACE"\n'
    )
    p = write(root, "ns-drift.yaml", rendered_job(script=bad))
    rc, _ = run("rendered-keygen", p)
    case("rendered-keygen: rendered NAMESPACE drift fails", False, rc)

    # BROKEN: KEY_FILE no longer ed25519.pem
    bad = (
        "set -e\n"
        'NAMESPACE="szl-receipts"\n'
        'KEY_FILE="signing.pem"\n'
        'SECRET_NAME="szl-receipts-ed25519"\n'
        'kubectl create secret generic "$SECRET_NAME" '
        '--from-file="${KEY_FILE}=/tmp/x" -n "$NAMESPACE"\n'
    )
    p = write(root, "keyfile-drift.yaml", rendered_job(script=bad))
    rc, _ = run("rendered-keygen", p)
    case("rendered-keygen: KEY_FILE drift fails", False, rc)

    # BROKEN: old two-file key.priv/key.pub scheme
    bad = (
        "set -e\n"
        'NAMESPACE="szl-receipts"\n'
        'KEY_FILE="ed25519.pem"\n'
        'SECRET_NAME="szl-receipts-ed25519"\n'
        'kubectl create secret generic "$SECRET_NAME" '
        "--from-file=key.priv=/tmp/p --from-file=key.pub=/tmp/q -n \"$NAMESPACE\"\n"
    )
    p = write(root, "twofile.yaml", rendered_job(script=bad))
    rc, _ = run("rendered-keygen", p)
    case("rendered-keygen: two-file key.priv/key.pub scheme fails", False, rc)


# ── built-package fixtures ──────────────────────────────────────────────────────
DIGEST = "@sha256:" + "a" * 64


def built_pkg(components):
    out = "kind: ZarfPackageConfig\nmetadata:\n  name: szl-receipts\ncomponents:\n"
    for c in components:
        out += "  - name: %s\n" % c["name"]
        if c.get("image"):
            out += "    images:\n      - %s\n" % c["image"]
    return out


SERVER_IMG = "ghcr.io/szl-holdings/szl-receipts-server:uds-v0.4.0" + DIGEST
SOURCE = built_pkg(
    [
        {"name": "szl-core-rightsize"},
        {"name": "szl-key-init-exemption"},
        {"name": "szl-key-init"},
        {"name": "szl-receipts-server", "image": SERVER_IMG},
    ]
)

with tempfile.TemporaryDirectory() as root:
    src = write(root, "source-zarf.yaml", SOURCE)

    # PRISTINE built package
    b = write(root, "good-built.yaml", SOURCE)
    rc, _ = run("built-package", b, src)
    case("built-package: pristine package passes", True, rc)

    # BROKEN: exemption dropped
    b = write(
        root,
        "no-exempt.yaml",
        built_pkg(
            [
                {"name": "szl-core-rightsize"},
                {"name": "szl-key-init"},
                {"name": "szl-receipts-server", "image": SERVER_IMG},
            ]
        ),
    )
    rc, _ = run("built-package", b, src)
    case("built-package: missing exemption component fails", False, rc)

    # BROKEN: exemption ordered AFTER key-init
    b = write(
        root,
        "reordered.yaml",
        built_pkg(
            [
                {"name": "szl-core-rightsize"},
                {"name": "szl-key-init"},
                {"name": "szl-key-init-exemption"},
                {"name": "szl-receipts-server", "image": SERVER_IMG},
            ]
        ),
    )
    rc, _ = run("built-package", b, src)
    case("built-package: exemption after key-init fails", False, rc)

    # BROKEN: built image tag drifted from the source tag
    b = write(
        root,
        "tag-drift.yaml",
        built_pkg(
            [
                {"name": "szl-core-rightsize"},
                {"name": "szl-key-init-exemption"},
                {"name": "szl-key-init"},
                {
                    "name": "szl-receipts-server",
                    "image": "ghcr.io/szl-holdings/szl-receipts-server:uds-v0.3.1"
                    + DIGEST,
                },
            ]
        ),
    )
    rc, _ = run("built-package", b, src)
    case("built-package: built tag != source tag fails", False, rc)

    # BROKEN: source has no receipts-server pin at all (guard would pass vacuously)
    src_nopin = write(
        root,
        "source-nopin.yaml",
        built_pkg(
            [
                {"name": "szl-key-init-exemption"},
                {"name": "szl-key-init"},
            ]
        ),
    )
    rc, _ = run("built-package", b, src_nopin)
    case("built-package: source missing server pin fails", False, rc)

    # BROKEN: source pin not in tag@digest form
    src_badpin = write(
        root,
        "source-badpin.yaml",
        built_pkg(
            [
                {"name": "szl-key-init-exemption"},
                {"name": "szl-key-init"},
                {
                    "name": "szl-receipts-server",
                    "image": "ghcr.io/szl-holdings/szl-receipts-server:uds-v0.4.0",
                },
            ]
        ),
    )
    rc, _ = run("built-package", b, src_badpin)
    case("built-package: source pin not tag@digest fails", False, rc)


print("\n%d passed, %d failed" % (PASS, FAILED))
if FAILED:
    print(
        "::error::package-build guard self-test FAILED — a check no longer "
        "behaves as expected."
    )
sys.exit(1 if FAILED else 0)
