#!/usr/bin/env python3
# Copyright 2026 SZL Holdings
# SPDX-License-Identifier: Apache-2.0
#
# image-pin-checks.py — the testable logic behind image-pin-guard.yml.
#
# The image-pin guard enforces four things:
#   1. every zarf package image AND every chart `image.digest` is pinned by
#      @sha256: digest and collected for resolution (collect-pins),
#   2. each pinned digest resolves to a SINGLE-platform manifest, never a
#      multi-arch index / manifest list (classify-manifest — a multi-arch index
#      digest breaks `zarf package create`, the recurring receipts trap),
#   3. `uds run start` actually routes through the `bundle` task
#      (start-routes-bundle), and
#   4. when a chart pins `image.digest`, the zarf package that wraps that chart
#      pins the BYTE-IDENTICAL digest in its `images:` list, so the deploy-time
#      Zarf agent image rewrite cannot drift (chart-zarf-digest-match).
#
# (1) and (3) were inline workflow Python and (2) was inline shell+jq. Inline
# guard logic can break silently and PASS VACUOUSLY (green while guarding
# nothing). Extracting the pure logic here lets image-pin-checks.test.py feed each
# check deliberately-broken fixtures and assert it FAILS. The crane fetch stays in
# the workflow; it pipes each manifest body to `classify-manifest` for the verdict.
#
# collect-pins walks zarf.yaml + packages/**/zarf.yaml AND charts/**/values.yaml.
# The zarf glob already covered packages/a11oy/zarf.yaml, but a chart's
# `image.digest` (e.g. charts/a11oy/values.yaml) was never resolved — a future
# a11oy digest pinned only in the chart could be a multi-arch OCI index and slip
# past CI. Collecting chart digests too sends them through the same crane +
# classify-manifest path, and chart-zarf-digest-match stops chart/zarf drift.
#
# Usage:
#   image-pin-checks.py collect-pins            [--root DIR] [--out FILE]
#   image-pin-checks.py classify-manifest       <manifest.json>
#   image-pin-checks.py start-routes-bundle     [--root DIR]
#   image-pin-checks.py chart-zarf-digest-match [--root DIR]
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


# ── image-ref helpers (shared) ──────────────────────────────────────────────────
def _normalize_digest(digest):
    """Return a bare 'sha256:...' digest, or '' if empty/None."""
    d = (digest or "").strip()
    return d


def _ref_repository(ref):
    """Strip any :tag and @digest, leaving registry/repo (the image name)."""
    name = ref.split("@", 1)[0]
    head, sep, last = name.rpartition("/")
    last = last.split(":", 1)[0]  # drop a :tag on the final path segment only
    return (head + "/" + last) if sep else last


def _ref_digest(ref):
    """Return the @sha256:... digest embedded in an image ref, or '' if none."""
    if "@" in ref:
        tail = ref.split("@", 1)[1]
        if tail.startswith("sha256:"):
            return tail
    return ""


def _iter_image_blocks(node, _path=()):
    """Yield every mapping that looks like a container-image block, i.e. has a
    string `repository` and a `digest` key (image: / server.image: / etc.).
    Walks the whole values tree so nested image blocks are covered too."""
    if isinstance(node, dict):
        if isinstance(node.get("repository"), str) and "digest" in node:
            yield node
        for k, v in node.items():
            for found in _iter_image_blocks(v, _path + (k,)):
                yield found
    elif isinstance(node, list):
        for item in node:
            for found in _iter_image_blocks(item, _path):
                yield found


def _chart_image_pins(root):
    """Walk charts/**/values.yaml and return (path, repository@digest) for every
    image block that pins a non-empty `image.digest`. These chart-side digests
    were never resolved before, so a multi-arch index pinned only in a chart could
    slip past the guard. Returns ('__error__', msg) on a YAML parse failure."""
    out = []
    for path in sorted(
        glob.glob(os.path.join(root, "charts", "**", "values.yaml"), recursive=True)
    ):
        try:
            with open(path, "r", encoding="utf-8") as fh:
                doc = yaml.safe_load(fh)
        except yaml.YAMLError as e:
            return [("__error__", "could not parse %s: %s" % (path, e))]
        for block in _iter_image_blocks(doc):
            repo = block.get("repository")
            digest = _normalize_digest(block.get("digest"))
            if repo and digest:
                out.append((path, "%s@%s" % (repo, digest)))
    return out


# ── collect-pins ────────────────────────────────────────────────────────────────
# Walk zarf.yaml + packages/**/zarf.yaml AND charts/**/values.yaml and emit every
# @sha256:-pinned image (zarf images: + chart image.digest). Exit 1 if NONE are
# found (a guard that scans zero pins would otherwise report success while
# protecting nothing).
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

    # Chart-side digest pins (e.g. charts/a11oy/values.yaml image.digest).
    chart_pins = _chart_image_pins(root)
    if chart_pins and chart_pins[0][0] == "__error__":
        return err(chart_pins[0][1])
    pins.extend(chart_pins)

    if not pins:
        return err(
            "no @sha256: image pins found under zarf.yaml / packages/**/zarf.yaml "
            "/ charts/**/values.yaml — either every image lost its digest pin or "
            "the scan path is wrong"
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


# ── chart-zarf-digest-match ───────────────────────────────────────────────────────
# For every chart values.yaml image block that pins a non-empty `image.digest`,
# find the zarf package that wraps that chart (via a component chart `localPath`)
# and assert its `images:` list pins the BYTE-IDENTICAL digest for the same
# repository. If they drift — chart pins digest X, zarf pins Y (or tag-only) — the
# deploy-time Zarf agent rewrite cannot match the baked image (airgap
# ImagePullBackOff). Conservative: a chart with no zarf wrapper, or a wrapper that
# does not reference that repository at all, is SKIPPED (cannot prove a
# contradiction); only a real digest mismatch fails.
def chart_zarf_digest_match(root):
    # repo -> (digest, values_path) for every chart image block that pins a digest,
    # keyed by the chart directory so we can join on the zarf localPath.
    chart_pins = {}  # chart_dir -> {repo: (digest, values_path)}
    for vf in sorted(
        glob.glob(os.path.join(root, "charts", "**", "values.yaml"), recursive=True)
    ):
        try:
            with open(vf, "r", encoding="utf-8") as fh:
                doc = yaml.safe_load(fh)
        except yaml.YAMLError as e:
            return err("could not parse %s: %s" % (vf, e))
        chart_dir = os.path.normpath(os.path.dirname(vf))
        for block in _iter_image_blocks(doc):
            repo = block.get("repository")
            digest = _normalize_digest(block.get("digest"))
            if repo and digest:
                chart_pins.setdefault(chart_dir, {})[repo] = (digest, vf)

    if not chart_pins:
        print("OK: no chart pins an image.digest — nothing to reconcile")
        return 0

    zarf_files = [os.path.join(root, "zarf.yaml")] + sorted(
        glob.glob(os.path.join(root, "packages", "**", "zarf.yaml"), recursive=True)
    )

    fail = False
    checked = 0
    for zpath in zarf_files:
        if not os.path.isfile(zpath):
            continue
        try:
            with open(zpath, "r", encoding="utf-8") as fh:
                zdoc = yaml.safe_load(fh)
        except yaml.YAMLError as e:
            return err("could not parse %s: %s" % (zpath, e))
        zdir = os.path.dirname(zpath)
        for comp in (zdoc or {}).get("components", []) or []:
            # repo -> digest ("" if tag-only) from this component's images: list
            zarf_repo_digest = {}
            for img in comp.get("images", []) or []:
                if isinstance(img, str):
                    zarf_repo_digest.setdefault(_ref_repository(img), _ref_digest(img))
            for ch in comp.get("charts", []) or []:
                lp = ch.get("localPath")
                if not lp:
                    continue
                cdir = os.path.normpath(os.path.join(zdir, lp))
                pins = chart_pins.get(cdir)
                if not pins:
                    continue
                for repo, (cdigest, vf) in pins.items():
                    if repo not in zarf_repo_digest:
                        # zarf does not bake this repo at all -> cannot reconcile
                        # (chart may use a side image not vendored into this pkg).
                        continue
                    zdigest = zarf_repo_digest[repo]
                    checked += 1
                    if zdigest == "":
                        err(
                            "%s pins image.digest %s for %s but %s lists it "
                            "TAG-ONLY (no @sha256:) — the chart-rendered digest "
                            "will not match the baked image (airgap rewrite "
                            "breaks). Pin the same digest in the zarf images: list."
                            % (vf, cdigest, repo, zpath)
                        )
                        fail = True
                    elif zdigest != cdigest:
                        err(
                            "digest DRIFT for %s: chart %s pins %s but zarf %s "
                            "pins %s. They must byte-match or the Zarf agent "
                            "rewrite deploys the wrong image."
                            % (repo, vf, cdigest, zpath, zdigest)
                        )
                        fail = True
                    else:
                        print(
                            "OK: %s == %s for %s (chart %s / zarf %s)"
                            % (cdigest, zdigest, repo, vf, zpath)
                        )

    if fail:
        return 1
    if checked == 0:
        # Charts pin digests but none is baked by a wrapping zarf package — the
        # classify pass (collect-pins) still covers them; nothing to reconcile.
        print(
            "OK: chart digest(s) present but none is baked by a wrapping zarf "
            "package — no chart/zarf pair to reconcile"
        )
        return 0
    print("OK: all %d chart/zarf digest pair(s) byte-match" % checked)
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

    p4 = sub.add_parser(
        "chart-zarf-digest-match",
        help="chart image.digest must byte-match the wrapping zarf images: digest",
    )
    p4.add_argument("--root", default=".", help="repo root (default: .)")

    args = ap.parse_args()
    if args.cmd == "collect-pins":
        return collect_pins(args.root, args.out)
    if args.cmd == "classify-manifest":
        return classify_manifest(args.manifest)
    if args.cmd == "start-routes-bundle":
        return start_routes_bundle(args.root)
    if args.cmd == "chart-zarf-digest-match":
        return chart_zarf_digest_match(args.root)
    ap.error("unknown command")


if __name__ == "__main__":
    sys.exit(main())
