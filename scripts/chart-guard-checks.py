#!/usr/bin/env python3
# Copyright 2026 SZL Holdings
# SPDX-License-Identifier: Apache-2.0
#
# chart-guard-checks.py — the testable logic behind chart-guard.yml.
#
# The chart guard renders the receipt-deploy charts and then asserts three
# properties on the rendered output:
#   1. extract-keygen      — the szl-key-init Job carries an inline keygen script
#                            in args[0] (and writes it out for sh -n / shellcheck),
#   2. keygen-invariants   — that keygen script is fail-loud (set -e + a fail()
#                            helper) and creates the Secret from a single
#                            ed25519.pem file (never the old key.priv/key.pub
#                            two-file scheme), and
#   3. requirekey-optional — signing.requireKey=true renders the ed25519-key
#                            Secret mount with optional:false (pod refuses to
#                            start unsigned) and requireKey=false renders
#                            optional:true.
#
# These were inline workflow Python/grep steps that could break silently and PASS
# VACUOUSLY (green while guarding nothing). Extracting them here lets
# chart-guard-checks.test.py feed each check deliberately-broken fixtures and
# assert it FAILS. `helm template`, `sh -n` and `shellcheck` stay in the workflow
# (they are well-tested external tools); this script holds the bespoke logic.
#
# Usage:
#   chart-guard-checks.py extract-keygen      <rendered-key-init.yaml> <out.sh>
#   chart-guard-checks.py keygen-invariants   <keygen.sh>
#   chart-guard-checks.py requirekey-optional <req-true.yaml> <req-false.yaml>
#
# Each subcommand exits 0 when its property holds and 1 (printing a GitHub
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


# ── extract-keygen ───────────────────────────────────────────────────────────────
def extract_keygen(rendered, out):
    docs = _load_all(rendered)
    jobs = [
        d
        for d in docs
        if d.get("kind") == "Job"
        and d.get("metadata", {}).get("name") == "szl-key-init"
    ]
    if not jobs:
        return err("keygen Job 'szl-key-init' not found in rendered output")
    containers = (
        jobs[0].get("spec", {})
        .get("template", {})
        .get("spec", {})
        .get("containers", [])
    )
    keygen = [c for c in containers if c.get("name") == "keygen"]
    if not keygen:
        return err("keygen container not found in szl-key-init Job")
    args = keygen[0].get("args") or []
    if not args or not isinstance(args[0], str) or not args[0].strip():
        return err("keygen container has no inline shell script in args[0]")
    with open(out, "w", encoding="utf-8") as fh:
        fh.write(args[0])
    print("Extracted keygen script (%d lines)" % args[0].count("\n"))
    return 0


# ── keygen-invariants ────────────────────────────────────────────────────────────
def keygen_invariants(path):
    with open(path, "r", encoding="utf-8") as fh:
        s = fh.read()
    # Must fail loud: set -e (abort on error) + a fail() helper.
    if not re.search(r"set -[a-z]*e", s):
        return err("keygen script lost 'set -e' (would exit 0 with no Secret)")
    if not re.search(r"(?m)^[ \t]*fail\(\)", s):
        return err("keygen script lost its fail() helper")
    # Must create the Secret with a single ed25519.pem key file; reject the old
    # two-file scheme.
    if "--from-file=" not in s:
        return err("keygen script no longer creates the Secret (no --from-file)")
    if re.search(r"key\.priv|key\.pub", s):
        return err("keygen script uses the old two-file key.priv/key.pub scheme")
    print(
        "OK: keygen script is fail-loud and uses a single ed25519.pem key file"
    )
    return 0


# ── requirekey-optional ──────────────────────────────────────────────────────────
def _optional(path):
    docs = _load_all(path)
    deps = [d for d in docs if d.get("kind") == "Deployment"]
    if not deps:
        raise ValueError("no Deployment rendered in %s" % path)
    vols = (
        deps[0].get("spec", {})
        .get("template", {})
        .get("spec", {})
        .get("volumes", [])
    )
    ek = [v for v in vols if v.get("name") == "ed25519-key"]
    if not ek:
        raise ValueError("ed25519-key volume not found in %s" % path)
    return ek[0]["secret"]["optional"]


def requirekey_optional(req_true, req_false):
    try:
        t = _optional(req_true)
        f = _optional(req_false)
    except (ValueError, KeyError) as e:
        return err(str(e))
    print("requireKey=true  -> optional: %s" % t)
    print("requireKey=false -> optional: %s" % f)
    if t is not False:
        return err(
            "signing.requireKey=true must render optional:false "
            "(pod must refuse to start without the signing key)"
        )
    if f is not True:
        return err(
            "signing.requireKey=false must render optional:true "
            "(legacy unsigned demo mode)"
        )
    print("OK: requireKey correctly drives the Secret mount optional flag")
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    sub = ap.add_subparsers(dest="cmd", required=True)

    p1 = sub.add_parser("extract-keygen", help="extract keygen script from Job")
    p1.add_argument("rendered", help="rendered szl-key-init output")
    p1.add_argument("out", help="write the extracted keygen script here")

    p2 = sub.add_parser("keygen-invariants", help="fail-loud + single-key checks")
    p2.add_argument("keygen", help="path to the extracted keygen script")

    p3 = sub.add_parser(
        "requirekey-optional", help="check requireKey drives the optional flag"
    )
    p3.add_argument("req_true", help="render with signing.requireKey=true")
    p3.add_argument("req_false", help="render with signing.requireKey=false")

    args = ap.parse_args()
    if args.cmd == "extract-keygen":
        return extract_keygen(args.rendered, args.out)
    if args.cmd == "keygen-invariants":
        return keygen_invariants(args.keygen)
    if args.cmd == "requirekey-optional":
        return requirekey_optional(args.req_true, args.req_false)
    ap.error("unknown command")


if __name__ == "__main__":
    sys.exit(main())
