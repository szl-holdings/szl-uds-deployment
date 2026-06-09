#!/usr/bin/env python3
# Copyright 2026 SZL Holdings
# SPDX-License-Identifier: Apache-2.0
#
# chart-guard-checks.test.py — Self-test for scripts/chart-guard-checks.py.
#
# Feeds each check synthetic PRISTINE fixtures (asserts PASS) and deliberately
# BROKEN fixtures (asserts FAIL), one per regression class. Catches a future edit
# that neuters a check (green while guarding nothing). Run by the `self-test` job
# in .github/workflows/chart-guard.yml. No helm, no cluster — pure fixtures.

import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
GUARD = os.path.join(HERE, "chart-guard-checks.py")

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


GOOD_KEYGEN = (
    "set -e\n"
    "fail() { echo \"$1\" >&2; exit 1; }\n"
    'KEY_FILE="ed25519.pem"\n'
    'kubectl create secret generic szl-receipts-ed25519 '
    '--from-file="${KEY_FILE}=/tmp/$KEY_FILE" -n szl-receipts || fail "no secret"\n'
)


def rendered_job(script):
    indented = "".join(
        "              " + ln for ln in script.splitlines(keepends=True)
    )
    return (
        "apiVersion: batch/v1\n"
        "kind: Job\n"
        "metadata:\n"
        "  name: szl-key-init\n"
        "spec:\n"
        "  template:\n"
        "    spec:\n"
        "      containers:\n"
        "        - name: keygen\n"
        "          image: bitnami/kubectl\n"
        "          args:\n"
        "            - |\n"
        "%s" % indented
    )


def deployment(optional):
    return (
        "apiVersion: apps/v1\n"
        "kind: Deployment\n"
        "metadata:\n"
        "  name: szl-receipts-server\n"
        "spec:\n"
        "  template:\n"
        "    spec:\n"
        "      volumes:\n"
        "        - name: ed25519-key\n"
        "          secret:\n"
        "            secretName: szl-receipts-ed25519\n"
        "            optional: %s\n" % ("true" if optional else "false")
    )


# ── extract-keygen ───────────────────────────────────────────────────────────────
with tempfile.TemporaryDirectory() as root:
    r = write(root, "key-init.yaml", rendered_job(GOOD_KEYGEN))
    out = os.path.join(root, "keygen.sh")
    rc, _ = run("extract-keygen", r, out)
    ok = rc == 0 and os.path.isfile(out) and "set -e" in open(out).read()
    case("extract-keygen: pristine Job extracts script", True, 0 if ok else 1)

    r = write(root, "no-job.yaml", "kind: ConfigMap\nmetadata:\n  name: x\n")
    rc, _ = run("extract-keygen", r, os.path.join(root, "x.sh"))
    case("extract-keygen: missing Job fails", False, rc)

    r = write(
        root,
        "no-args.yaml",
        "kind: Job\nmetadata:\n  name: szl-key-init\n"
        "spec:\n  template:\n    spec:\n      containers:\n"
        "        - name: keygen\n          image: x\n",
    )
    rc, _ = run("extract-keygen", r, os.path.join(root, "y.sh"))
    case("extract-keygen: keygen container with no args fails", False, rc)


# ── keygen-invariants ────────────────────────────────────────────────────────────
with tempfile.TemporaryDirectory() as root:
    g = write(root, "good.sh", GOOD_KEYGEN)
    rc, _ = run("keygen-invariants", g)
    case("keygen-invariants: pristine script passes", True, rc)

    b = write(root, "no-sete.sh", GOOD_KEYGEN.replace("set -e\n", ""))
    rc, _ = run("keygen-invariants", b)
    case("keygen-invariants: missing 'set -e' fails", False, rc)

    b = write(
        root,
        "no-fail.sh",
        "set -e\n"
        'KEY_FILE="ed25519.pem"\n'
        'kubectl create secret generic s --from-file="${KEY_FILE}=/tmp/x"\n',
    )
    rc, _ = run("keygen-invariants", b)
    case("keygen-invariants: missing fail() helper fails", False, rc)

    b = write(
        root,
        "no-fromfile.sh",
        "set -e\nfail() { exit 1; }\necho no secret created\n",
    )
    rc, _ = run("keygen-invariants", b)
    case("keygen-invariants: no --from-file fails", False, rc)

    b = write(
        root,
        "twofile.sh",
        "set -e\nfail() { exit 1; }\n"
        "kubectl create secret generic s "
        "--from-file=key.priv=/tmp/p --from-file=key.pub=/tmp/q\n",
    )
    rc, _ = run("keygen-invariants", b)
    case("keygen-invariants: two-file key.priv/key.pub fails", False, rc)


# ── requirekey-optional ──────────────────────────────────────────────────────────
with tempfile.TemporaryDirectory() as root:
    t = write(root, "req-true.yaml", deployment(optional=False))
    f = write(root, "req-false.yaml", deployment(optional=True))
    rc, _ = run("requirekey-optional", t, f)
    case("requirekey-optional: true->optional:false, false->optional:true passes", True, rc)

    # BROKEN: requireKey=true rendered optional:true (server would boot unsigned)
    bt = write(root, "bad-true.yaml", deployment(optional=True))
    rc, _ = run("requirekey-optional", bt, f)
    case("requirekey-optional: requireKey=true with optional:true fails", False, rc)

    # BROKEN: requireKey=false rendered optional:false
    bf = write(root, "bad-false.yaml", deployment(optional=False))
    rc, _ = run("requirekey-optional", t, bf)
    case("requirekey-optional: requireKey=false with optional:false fails", False, rc)

    # BROKEN: ed25519-key volume missing entirely
    novol = write(
        root,
        "novol.yaml",
        "kind: Deployment\nmetadata:\n  name: s\n"
        "spec:\n  template:\n    spec:\n      volumes: []\n",
    )
    rc, _ = run("requirekey-optional", novol, f)
    case("requirekey-optional: missing ed25519-key volume fails", False, rc)


print("\n%d passed, %d failed" % (PASS, FAILED))
if FAILED:
    print(
        "::error::chart guard self-test FAILED — a check no longer behaves "
        "as expected."
    )
sys.exit(1 if FAILED else 0)
