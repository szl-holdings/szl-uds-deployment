#!/usr/bin/env python3
# Copyright 2026 SZL Holdings
# SPDX-License-Identifier: Apache-2.0
#
# package-build-checks.py — the testable assertions behind package-build-guard.yml.
#
# The package build guard renders the szl-key-init chart and builds the
# szl-receipts zarf package, then asserts properties on the resulting artifacts:
#   - the RENDERED keygen Job lands the Ed25519 Secret in ns szl-receipts with
#     key file ed25519.pem (a templating slip could land it elsewhere -> the
#     server boots UNSIGNED with no error), and
#   - the BUILT package keeps the RequireNonRootUser exemption ordered BEFORE the
#     keygen Job and still pins the receipts-server image tag declared in source.
#
# Those assertions used to live as inline Python inside the workflow. Inline
# workflow Python can break silently (a `.get` that always returns None, an
# index check that never trips) and PASS VACUOUSLY — green while guarding
# nothing. Extracting them here lets package-build-checks.test.py feed each check
# deliberately-broken fixtures and assert it FAILS, so a future edit that neuters
# a check is caught in CI. The workflow calls this exact script, so the self-test
# exercises the real guard.
#
# Usage:
#   package-build-checks.py rendered-keygen <rendered-key-init.yaml>
#   package-build-checks.py built-package   <built-zarf.yaml> <source-zarf.yaml>
#
# Each subcommand exits 0 when the property holds and 1 (printing a GitHub
# ::error annotation) when it is regressed.

import argparse
import re
import sys

try:
    import yaml
except ImportError:
    sys.stderr.write("ERROR: PyYAML is required (pip install pyyaml).\n")
    sys.exit(2)


def err(msg):
    print("::error::" + msg)
    return 1


def _load_all(path):
    with open(path, "r", encoding="utf-8") as fh:
        return [d for d in yaml.safe_load_all(fh) if d]


# ── rendered-keygen ────────────────────────────────────────────────────────────
# Assert the rendered szl-key-init Job creates Secret szl-receipts-ed25519
# (single key file ed25519.pem) in namespace szl-receipts. This checks the
# RENDERED values (not the values.yaml source the grep guard reads), so it catches
# a template that ignores .Values.namespace or hardcodes a different ns/key while
# values.yaml still reads right.
def rendered_keygen(path):
    docs = _load_all(path)
    jobs = [
        d
        for d in docs
        if d.get("kind") == "Job"
        and d.get("metadata", {}).get("name") == "szl-key-init"
    ]
    if not jobs:
        return err("keygen Job 'szl-key-init' not found in rendered output")
    job = jobs[0]

    # (a) The Job object itself must render into ns szl-receipts. A Secret is
    #     namespace-local; if key-init runs anywhere else the server cannot mount
    #     the key and boots UNSIGNED with no error.
    ns = job.get("metadata", {}).get("namespace")
    if ns != "szl-receipts":
        return err(
            "rendered keygen Job namespace is '%s', expected 'szl-receipts'" % ns
        )

    containers = (
        job.get("spec", {})
        .get("template", {})
        .get("spec", {})
        .get("containers", [])
    )
    keygen = [c for c in containers if c.get("name") == "keygen"]
    if not keygen:
        return err("keygen container not found in rendered Job")
    args = keygen[0].get("args") or []
    if not args or not isinstance(args[0], str) or not args[0].strip():
        return err("keygen container has no inline shell script in args[0]")
    script = args[0]

    # (b) The rendered script must resolve to the szl-receipts namespace, the
    #     ed25519.pem key file, and the szl-receipts-ed25519 Secret name the
    #     receipts-server Deployment mounts.
    required = {
        'NAMESPACE="szl-receipts"': "namespace did not render to szl-receipts",
        'KEY_FILE="ed25519.pem"': "key file did not render to ed25519.pem",
        'SECRET_NAME="szl-receipts-ed25519"': "secret name did not render to szl-receipts-ed25519",
    }
    for needle, why in required.items():
        if needle not in script:
            return err(
                "rendered keygen script: %s (missing %r)" % (why, needle)
            )

    # (c) The Secret must be created from a single ed25519.pem file (reject a
    #     stray hardcoded ns / two-file scheme).
    if '--from-file="${KEY_FILE}=' not in script:
        return err(
            'keygen script no longer creates the Secret from a single '
            '--from-file="${KEY_FILE}=" entry'
        )
    if "key.priv" in script or "key.pub" in script:
        return err(
            "keygen script reintroduced the old two-file key.priv/key.pub scheme"
        )

    print(
        "OK: rendered keygen Job creates Secret szl-receipts-ed25519 "
        "(ed25519.pem) in ns szl-receipts"
    )
    return 0


# ── built-package ──────────────────────────────────────────────────────────────
# Assert the BUILT package keeps szl-key-init-exemption ordered BEFORE
# szl-key-init (so the root keygen pod is admitted rather than DENIED -> UNSIGNED
# server) and still pins the receipts-server image at the tag declared in the
# source package definition (read at run time so version bumps don't break this).
def built_package(built_path, source_path):
    docs = _load_all(built_path)
    pkg = next(
        (d for d in docs if d.get("kind") == "ZarfPackageConfig"),
        docs[0] if docs else None,
    )
    if not pkg:
        return err("could not parse built package definition")
    names = [c.get("name") for c in pkg.get("components", [])]
    if "szl-key-init-exemption" not in names:
        return err(
            "built package dropped the szl-key-init-exemption component "
            "(root keygen pod would be DENIED -> UNSIGNED server)"
        )
    if "szl-key-init" not in names:
        return err("built package dropped the szl-key-init keygen component")
    if names.index("szl-key-init-exemption") >= names.index("szl-key-init"):
        return err(
            "szl-key-init-exemption must come BEFORE szl-key-init; "
            "component order is %s" % names
        )
    blob = yaml.safe_dump(pkg)

    # Expected receipts-server tag is read from the SOURCE package definition
    # (kept in lockstep by scripts/pin-receipts-image-digest.sh), so this guard
    # tracks version bumps instead of hard-coding a release tag.
    srcdocs = _load_all(source_path)
    srcpkg = next(
        (d for d in srcdocs if d.get("kind") == "ZarfPackageConfig"), None
    )
    srcimgs = [
        img
        for c in (srcpkg or {}).get("components", [])
        for img in (c.get("images") or [])
    ]
    ref = next((i for i in srcimgs if "szl-receipts-server" in i), None)
    if not ref:
        return err(
            "source packages/szl-receipts/zarf.yaml has no "
            "szl-receipts-server image pin"
        )
    m = re.search(r"szl-receipts-server:([^@\s]+)@sha256:", ref)
    if not m:
        return err("source receipts-server pin is not tag@digest form: %s" % ref)
    tag = m.group(1)
    if "ghcr.io/szl-holdings/szl-receipts-server:%s" % tag not in blob:
        return err("built package no longer pins szl-receipts-server:%s" % tag)

    print(
        "OK: built package keeps szl-key-init-exemption before szl-key-init "
        "and pins %s" % tag
    )
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    sub = ap.add_subparsers(dest="cmd", required=True)

    p1 = sub.add_parser("rendered-keygen", help="check rendered key-init Job")
    p1.add_argument("rendered", help="path to rendered szl-key-init output")

    p2 = sub.add_parser("built-package", help="check built zarf package structure")
    p2.add_argument("built", help="zarf.yaml extracted from the built package")
    p2.add_argument("source", help="source packages/szl-receipts/zarf.yaml")

    args = ap.parse_args()
    if args.cmd == "rendered-keygen":
        return rendered_keygen(args.rendered)
    if args.cmd == "built-package":
        return built_package(args.built, args.source)
    ap.error("unknown command")


if __name__ == "__main__":
    sys.exit(main())
