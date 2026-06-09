#!/usr/bin/env python3
# Copyright 2026 SZL Holdings
# SPDX-License-Identifier: Apache-2.0
#
# image-pin-checks.py — the testable logic behind image-pin-guard.yml.
#
# The image-pin guard enforces three things:
#   1. every zarf package image is pinned by @sha256: digest (collect-pins),
#   2. each pinned digest resolves to a SINGLE-platform manifest, never a
#      multi-arch index / manifest list (classify-manifest — a multi-arch index
#      digest breaks `zarf package create`, the recurring receipts trap), and
#   3. `uds run start` actually routes through the `bundle` task
#      (start-routes-bundle).
#
# (1) and (3) were inline workflow Python and (2) was inline shell+jq. Inline
# guard logic can break silently and PASS VACUOUSLY (green while guarding
# nothing). Extracting the pure logic here lets image-pin-checks.test.py feed each
# check deliberately-broken fixtures and assert it FAILS. The crane fetch stays in
# the workflow; it pipes each manifest body to `classify-manifest` for the verdict.
#
# Usage:
#   image-pin-checks.py collect-pins        [--root DIR] [--out FILE]
#   image-pin-checks.py classify-manifest   <manifest.json>
#   image-pin-checks.py start-routes-bundle [--root DIR]
#
# Each subcommand exits 0 when its invariant holds and 1 (printing a GitHub
# ::error annotation) when it is regressed.

import argparse
import glob
import json
import os
import sys

try:
    import yaml
except ImportError:
    sys.stderr.write("ERROR: PyYAML is required (pip install pyyaml).\n")
    sys.exit(2)


def err(msg):
    print("::error::" + msg)
    return 1


# ── collect-pins ────────────────────────────────────────────────────────────────
# Walk zarf.yaml + packages/**/zarf.yaml and emit every @sha256:-pinned image.
# Exit 1 if NONE are found (a guard that scans zero pins would otherwise report
# success while protecting nothing).
def collect_pins(root, out=None):
    files = [os.path.join(root, "zarf.yaml")] + sorted(
        glob.glob(os.path.join(root, "packages", "**", "zarf.yaml"), recursive=True)
    )
    pins = []
    for path in files:
        if not os.path.isfile(path):
            print("skipping missing zarf package file: %s" % path)
            continue
        try:
            with open(path, "r", encoding="utf-8") as fh:
                doc = yaml.safe_load(fh)
        except yaml.YAMLError as e:
            return err("could not parse %s: %s" % (path, e))
        for comp in (doc or {}).get("components", []) or []:
            for img in comp.get("images", []) or []:
                if isinstance(img, str) and "@sha256:" in img:
                    pins.append((path, img))

    if not pins:
        return err(
            "no @sha256: image pins found under zarf.yaml / packages/**/zarf.yaml "
            "— either every image lost its digest pin or the scan path is wrong"
        )

    seen = set()
    unique = []
    for path, img in pins:
        print("%s: %s" % (path, img))
        if img not in seen:
            seen.add(img)
            unique.append(img)
    if out:
        with open(out, "w", encoding="utf-8") as fh:
            fh.write("\n".join(unique) + "\n")
    print("Collected %d unique @sha256: pin(s)." % len(unique))
    return 0


# ── classify-manifest ────────────────────────────────────────────────────────────
# Given a raw image manifest JSON (as fetched by `crane manifest`), fail if it is
# a multi-arch index / manifest list (by mediaType OR by the presence of a
# `manifests` array). A single-platform manifest passes.
def classify_manifest(path):
    with open(path, "r", encoding="utf-8") as fh:
        body = json.load(fh)
    mt = body.get("mediaType", "") or ""
    is_index = body.get("manifests") is not None
    fail = False
    if "image.index" in mt or "manifest.list" in mt:
        err("pinned to a multi-arch INDEX digest (mediaType=%s)" % mt)
        fail = True
    if is_index:
        err(
            "pinned digest resolves to a manifest list (.manifests[] present) — "
            "pin the single-platform child digest instead"
        )
        fail = True
    if fail:
        return 1
    print("OK: single-platform manifest (mediaType=%r)" % mt)
    return 0


# ── start-routes-bundle ──────────────────────────────────────────────────────────
# Assert tasks.yaml has a `bundle` task AND a `start` task whose actions route
# through `- task: bundle`. If `start` stops calling `bundle`, a fresh
# `uds run start` skips the build and deploys stale/absent artifacts.
def start_routes_bundle(root):
    path = os.path.join(root, "tasks.yaml")
    if not os.path.isfile(path):
        return err("missing required file: %s" % path)
    with open(path, "r", encoding="utf-8") as fh:
        doc = yaml.safe_load(fh)
    tasks = {
        t["name"]: t
        for t in (doc or {}).get("tasks", []) or []
        if isinstance(t, dict) and "name" in t
    }
    if "bundle" not in tasks:
        return err("no top-level task named 'bundle' in tasks.yaml")
    start = tasks.get("start")
    if not start:
        return err("no top-level task named 'start' in tasks.yaml")
    routes = any(
        isinstance(a, dict) and a.get("task") == "bundle"
        for a in start.get("actions", []) or []
    )
    if not routes:
        return err(
            "the 'start' task does not route through '- task: bundle' — a fresh "
            "`uds run start` would skip the build step"
        )
    print("OK: 'start' routes through the 'bundle' task")
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    sub = ap.add_subparsers(dest="cmd", required=True)

    p1 = sub.add_parser("collect-pins", help="emit every @sha256: image pin")
    p1.add_argument("--root", default=".", help="repo root (default: .)")
    p1.add_argument("--out", default=None, help="write unique pins to this file")

    p2 = sub.add_parser("classify-manifest", help="fail on a multi-arch index")
    p2.add_argument("manifest", help="path to a `crane manifest` JSON body")

    p3 = sub.add_parser("start-routes-bundle", help="check start -> bundle wiring")
    p3.add_argument("--root", default=".", help="repo root (default: .)")

    args = ap.parse_args()
    if args.cmd == "collect-pins":
        return collect_pins(args.root, args.out)
    if args.cmd == "classify-manifest":
        return classify_manifest(args.manifest)
    if args.cmd == "start-routes-bundle":
        return start_routes_bundle(args.root)
    ap.error("unknown command")


if __name__ == "__main__":
    sys.exit(main())
