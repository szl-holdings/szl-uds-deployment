#!/usr/bin/env python3
# Copyright 2026 SZL Holdings
# SPDX-License-Identifier: Apache-2.0
#
# a11oy-signing-key-checks.test.py — Self-test for scripts/a11oy-signing-key-checks.py.
#
# Feeds each check synthetic PRISTINE fixtures (asserts PASS) and deliberately
# BROKEN fixtures (asserts FAIL), one per regression class — exactly the four
# failure modes that silently forced a11oy onto an ephemeral signing key:
#   keyinit-ecdsa     : keygen drifts back to Ed25519 / wrong filenames / no key.
#   secret-name-match : the mounted Secret name drifts from the provisioned one.
#   zarf-agent-ignore : the label is hard-coded on (or never wired) regardless of
#                       the flag.
#   udspackage-gated  : the Package renders even when udsPackage.enabled is false.
#   no-istio-annotation : a sidecar.istio.io/inject annotation creeps back onto the
#                       key-init Job (uds-core rejects the Job -> ephemeral key).
#
# Catches a future edit that neuters a check (green while guarding nothing). Run
# by the `self-test` job in .github/workflows/a11oy-signing-key-guard.yml. No
# helm, no cluster — pure fixtures.

import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
GUARD = os.path.join(HERE, "a11oy-signing-key-checks.py")

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


def case(label, expect_pass, rc, out=""):
    global PASS, FAILED
    ok = (rc == 0) if expect_pass else (rc != 0)
    if ok:
        PASS += 1
        print("ok   - %s" % label)
    else:
        FAILED += 1
        print("FAIL - %s (rc=%s)\n%s" % (label, rc, out))


# ── fixtures ──────────────────────────────────────────────────────────────────
GOOD_KEYGEN_SCRIPT = (
    "import base64\n"
    "from cryptography.hazmat.primitives.asymmetric import ec\n"
    "priv = ec.generate_private_key(ec.SECP256R1())\n"
    'data = {"ecdsa-p256.key": "x", "ecdsa-p256.pem": "y"}\n'
)


def keyinit_doc(script, key_secret="szl-a11oy-receipts-ecdsa-p256",
                pod_annotations=None):
    pod_meta = ""
    if pod_annotations:
        pod_meta = (
            "    metadata:\n      annotations:\n"
            + "".join("        %s: %s\n" % (k, v)
                      for k, v in pod_annotations.items())
        )
    return (
        "apiVersion: batch/v1\n"
        "kind: Job\n"
        "metadata:\n  name: a11oy-receipt-key-init\n"
        "spec:\n  template:\n" + pod_meta + "    spec:\n      containers:\n"
        "        - name: keygen\n"
        "          env:\n"
        "            - name: KEY_SECRET\n"
        "              value: %s\n"
        "          args:\n            - |\n" % key_secret
        + "".join("              " + ln + "\n" for ln in script.splitlines())
    )


def deployment_doc(secret_name="szl-a11oy-receipts-ecdsa-p256", zarf=False):
    label = "        zarf.dev/agent: ignore\n" if zarf else ""
    return (
        "apiVersion: apps/v1\n"
        "kind: Deployment\n"
        "metadata:\n  name: a11oy\n"
        "spec:\n  template:\n    metadata:\n      labels:\n"
        "        app: a11oy\n" + label +
        "    spec:\n      containers:\n        - name: a11oy\n"
        "      volumes:\n"
        "        - name: receipt-key\n"
        "          secret:\n            secretName: %s\n" % secret_name
    )


PACKAGE_DOC = (
    "apiVersion: uds.dev/v1alpha1\n"
    "kind: Package\n"
    "metadata:\n  name: a11oy\n"
)


def main():
    with tempfile.TemporaryDirectory() as d:
        # ── keyinit-ecdsa ──────────────────────────────────────────────────────
        good = write(d, "ki-good.yaml", keyinit_doc(GOOD_KEYGEN_SCRIPT))
        rc, out = run("keyinit-ecdsa", good)
        case("keyinit-ecdsa PASSES on ECDSA P-256 keygen", True, rc, out)

        # Drift back to Ed25519.
        ed = GOOD_KEYGEN_SCRIPT.replace(
            "ec.generate_private_key(ec.SECP256R1())",
            "Ed25519PrivateKey.generate()",
        ).replace("ecdsa-p256", "ed25519")
        bad = write(d, "ki-ed25519.yaml", keyinit_doc(ed))
        rc, out = run("keyinit-ecdsa", bad)
        case("keyinit-ecdsa FAILS when keygen reverts to Ed25519", False, rc, out)

        # Drift to RSA (also a key the P-256-only loader cannot use).
        rsa = GOOD_KEYGEN_SCRIPT.replace(
            "from cryptography.hazmat.primitives.asymmetric import ec",
            "from cryptography.hazmat.primitives.asymmetric import rsa",
        ).replace(
            "ec.generate_private_key(ec.SECP256R1())",
            "rsa.generate_private_key(public_exponent=65537, key_size=2048)",
        )
        bad = write(d, "ki-rsa.yaml", keyinit_doc(rsa))
        rc, out = run("keyinit-ecdsa", bad)
        case("keyinit-ecdsa FAILS when keygen uses RSA", False, rc, out)

        # Wrong Secret data filenames (loader can't find the key).
        wrongfn = GOOD_KEYGEN_SCRIPT.replace("ecdsa-p256.key", "tls.key")
        bad = write(d, "ki-fn.yaml", keyinit_doc(wrongfn))
        rc, out = run("keyinit-ecdsa", bad)
        case("keyinit-ecdsa FAILS on wrong Secret data filename", False, rc, out)

        # No keygen Job at all.
        bad = write(d, "ki-none.yaml", deployment_doc())
        rc, out = run("keyinit-ecdsa", bad)
        case("keyinit-ecdsa FAILS when key-init Job is absent", False, rc, out)

        # ── secret-name-match ──────────────────────────────────────────────────
        matched = write(
            d, "snm-good.yaml",
            keyinit_doc(GOOD_KEYGEN_SCRIPT) + "---\n" + deployment_doc())
        rc, out = run("secret-name-match", matched)
        case("secret-name-match PASSES when names align", True, rc, out)

        drift = write(
            d, "snm-drift.yaml",
            keyinit_doc(GOOD_KEYGEN_SCRIPT, key_secret="szl-a11oy-receipts-ed25519")
            + "---\n" + deployment_doc(secret_name="szl-a11oy-receipts-ecdsa-p256"))
        rc, out = run("secret-name-match", drift)
        case("secret-name-match FAILS on mount/provision name drift", False, rc, out)

        # ── zarf-agent-ignore ──────────────────────────────────────────────────
        on = write(d, "zai-on.yaml", deployment_doc(zarf=True))
        off = write(d, "zai-off.yaml", deployment_doc(zarf=False))
        rc, out = run("zarf-agent-ignore", on, off)
        case("zarf-agent-ignore PASSES (label tracks the flag)", True, rc, out)

        # Hard-coded on regardless of the flag (off render still has the label).
        rc, out = run("zarf-agent-ignore", on, on)
        case("zarf-agent-ignore FAILS when label is hard-coded on", False, rc, out)

        # Never wired (on render is missing the label).
        rc, out = run("zarf-agent-ignore", off, off)
        case("zarf-agent-ignore FAILS when flag emits no label", False, rc, out)

        # ── udspackage-gated ───────────────────────────────────────────────────
        pkg_on = write(d, "uds-on.yaml", deployment_doc() + "---\n" + PACKAGE_DOC)
        pkg_off = write(d, "uds-off.yaml", deployment_doc())
        rc, out = run("udspackage-gated", pkg_on, pkg_off)
        case("udspackage-gated PASSES when Package is gated", True, rc, out)

        # Package renders even with the gate "off".
        rc, out = run("udspackage-gated", pkg_on, pkg_on)
        case("udspackage-gated FAILS when Package ignores the gate", False, rc, out)

        # ── no-istio-annotation ────────────────────────────────────────────────
        # The actual bug: a sidecar.istio.io/inject annotation on the key-init Job
        # gets the Job rejected by uds-core's admission webhook (any value), so the
        # signing-key Secret is never provisioned and a11oy falls back to ephemeral.
        clean = write(d, "ni-clean.yaml", keyinit_doc(GOOD_KEYGEN_SCRIPT))
        rc, out = run("no-istio-annotation", clean)
        case("no-istio-annotation PASSES when no istio annotation present",
             True, rc, out)

        # The exact regression — sidecar.istio.io/inject: "false" (uds-core rejects
        # the annotation key regardless of value).
        inj_false = write(
            d, "ni-inject-false.yaml",
            keyinit_doc(GOOD_KEYGEN_SCRIPT,
                        pod_annotations={"sidecar.istio.io/inject": '"false"'}))
        rc, out = run("no-istio-annotation", inj_false)
        case("no-istio-annotation FAILS on sidecar.istio.io/inject=false",
             False, rc, out)

        # Same annotation with the opposite value is rejected just the same.
        inj_true = write(
            d, "ni-inject-true.yaml",
            keyinit_doc(GOOD_KEYGEN_SCRIPT,
                        pod_annotations={"sidecar.istio.io/inject": '"true"'}))
        rc, out = run("no-istio-annotation", inj_true)
        case("no-istio-annotation FAILS on sidecar.istio.io/inject=true",
             False, rc, out)

        # No keygen Job at all (the key-init Job must exist for a persistent key).
        rc, out = run("no-istio-annotation",
                      write(d, "ni-none.yaml", deployment_doc()))
        case("no-istio-annotation FAILS when key-init Job is absent",
             False, rc, out)

    print("\n%d passed, %d failed" % (PASS, FAILED))
    return 1 if FAILED else 0


if __name__ == "__main__":
    sys.exit(main())
