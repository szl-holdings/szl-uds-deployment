#!/usr/bin/env python3
# Copyright 2026 SZL Holdings
# SPDX-License-Identifier: Apache-2.0
"""
organ_package_check.py — packaging-shape guard for one SZL organ.

Generalizes a11oy-package-guard.yml to the OTHER four organs that ride the
full-organ bundle bundles/szl-uds-bundle/uds-bundle.yaml: sentra, amaru,
killinchu, yupana. None of the existing CI guards protect their packaging shape:
  * image-pin-guard.yml only scans the root zarf.yaml + packages/szl-receipts.
  * chart-guard.yml lint/templates every chart but never checks how
    packages/<organ>/zarf.yaml is wrapped, nor bundle membership, nor image
    parity between the zarf-baked ref and the workload that actually deploys.

REALITY (origin/main): unlike a11oy — which was upgraded to a CHART-based package
(packages/a11oy/zarf.yaml -> charts/a11oy, tag-only uds-v0.3.0) — these four
organs are still MANIFESTS-based and @sha256: digest-pinned at uds-v0.2.0
(packages/<organ>/zarf.yaml -> manifests/*.yaml). This guard locks that canonical
shape so it cannot silently change unreviewed, mirroring how a11oy-package-guard
locks a11oy's chart-based shape. Converting an organ to chart-based is a
deliberate packaging upgrade and must update this guard (give it the chart-based
checks the way a11oy got its own guard).

For the named organ it asserts, cluster-free:

  1. packages/<organ>/zarf.yaml is MANIFESTS-based: at least one component carries
     `manifests:`, and NO component renders charts/<organ> via charts[].localPath
     (a silent flip to chart-based fails loud).
  2. The organ workload image (ghcr.io/szl-holdings/<organ>) is byte-identical
     everywhere it is declared — zarf metadata.image, the component images: list,
     and every workload manifest's container image — and stays @sha256: pinned. A
     drift between any of these breaks the Zarf deploy-time agent image rewrite /
     airgap pull; an unpinned tag is mutable under the deploy.
  3. bundles/szl-uds-bundle/uds-bundle.yaml still registers szl-<organ> pointing
     at packages/<organ>.

Usage: organ_package_check.py <organ>
Exits non-zero (printing ::error:: lines) on any failure; runs from the repo root.
"""

import os
import sys
import yaml


def _walk_images(node):
    """Recursively collect every `image:` string value in a parsed manifest doc."""
    out = []
    if isinstance(node, dict):
        for k, v in node.items():
            if k == "image" and isinstance(v, str):
                out.append(v)
            else:
                out.extend(_walk_images(v))
    elif isinstance(node, list):
        for item in node:
            out.extend(_walk_images(item))
    return out


def main():
    if len(sys.argv) != 2:
        print("::error::usage: organ_package_check.py <organ>")
        return 2
    organ = sys.argv[1]

    ZARF = f"packages/{organ}/zarf.yaml"
    CHART_LP = f"charts/{organ}"
    BUNDLE = "bundles/szl-uds-bundle/uds-bundle.yaml"
    REPO = f"ghcr.io/szl-holdings/{organ}"
    BUNDLE_PKG = f"szl-{organ}"

    errors = []

    def err(msg):
        errors.append(msg)
        print(f"::error::{msg}")

    def norm(base_dir, rel):
        # Resolve a zarf localPath / manifest file / bundle path (relative to the
        # owning file's dir) to a repo-root-relative POSIX path for comparison.
        return os.path.normpath(os.path.join(base_dir, rel)).replace("\\", "/")

    for f in (ZARF, BUNDLE):
        if not os.path.isfile(f):
            print(f"::error::required file missing: {f}")
            return 1

    with open(ZARF) as fh:
        zpkg = yaml.safe_load(fh)
    zarf_dir = os.path.dirname(ZARF)
    components = zpkg.get("components") or []

    # ── 1. shape: manifests-based, not (silently) chart-based ────────────────
    chart_localpaths = []
    manifest_components = []
    for c in components:
        for ch in (c.get("charts") or []):
            lp = ch.get("localPath")
            if lp:
                chart_localpaths.append((c.get("name", "<unnamed>"), norm(zarf_dir, lp)))
        if c.get("manifests"):
            manifest_components.append(c.get("name", "<unnamed>"))

    want_chart = norm(".", CHART_LP)
    flipped = [n for (n, p) in chart_localpaths if p == want_chart]
    if flipped:
        err(
            f"{ZARF} now renders {CHART_LP} via charts[].localPath "
            f"(component(s) {flipped}). The four organs "
            f"(sentra/amaru/killinchu/yupana) are canonically MANIFESTS-based + "
            f"digest-pinned; only a11oy was upgraded to chart-based. Converting an "
            f"organ to chart-based is a deliberate packaging upgrade — give it the "
            f"chart-based checks (see a11oy-package-guard.yml) and update "
            f"organ-package-guard before landing."
        )
    if not manifest_components:
        err(
            f"{ZARF} has no manifests-based component — expected the {organ} "
            f"workload + operator to ship as manifests (manifests/*.yaml)."
        )
    else:
        print(f"OK: {ZARF} is manifests-based (components {manifest_components})")

    # ── 2. image parity across every declaration site + digest pin ───────────
    refs = set()
    sites = {}

    def add_ref(ref, where):
        refs.add(ref)
        sites.setdefault(ref, set()).add(where)

    md_img = (zpkg.get("metadata") or {}).get("image")
    if isinstance(md_img, str):
        if md_img.startswith(REPO):
            add_ref(md_img, "metadata.image")
    else:
        err(
            f"{ZARF} metadata.image is missing — the {organ} package must declare "
            f"its canonical image under metadata.image."
        )

    for c in components:
        for img in (c.get("images") or []):
            if img.startswith(REPO):
                add_ref(img, f"images[{c.get('name', '<unnamed>')}]")
        for m in (c.get("manifests") or []):
            for rel in (m.get("files") or []):
                mp = norm(zarf_dir, rel)
                if not os.path.isfile(mp):
                    continue
                with open(mp) as mfh:
                    for doc in yaml.safe_load_all(mfh):
                        for img in _walk_images(doc):
                            if img.startswith(REPO):
                                add_ref(img, f"manifest:{mp}")

    if not refs:
        err(f"no {REPO} image reference found anywhere in {ZARF} or its manifests.")
    elif len(refs) > 1:
        detail = "; ".join(f"{r} <- {sorted(sites[r])}" for r in sorted(refs))
        err(
            f"{organ} image DRIFT: {len(refs)} distinct {REPO} refs that must be "
            f"byte-identical: {detail}. The zarf metadata.image, the component "
            f"images: entry and the workload manifest image must all match or the "
            f"Zarf deploy-time agent rewrite / airgap pull breaks."
        )
    else:
        ref = next(iter(refs))
        if "@sha256:" not in ref:
            err(
                f"{organ} image '{ref}' is NOT digest-pinned. The four organs ship "
                f"with an @sha256: child digest (image-pin-guard does not scan them); "
                f"keep the digest pin so the tag can't be mutated under the deploy."
            )
        else:
            print(f"OK: {organ} image consistent + digest-pinned everywhere ({ref})")

    # ── 3. still a member of the full-organ bundle ───────────────────────────
    with open(BUNDLE) as bfh:
        bundle = yaml.safe_load(bfh)
    bundle_dir = os.path.dirname(BUNDLE)
    want_pkg_dir = norm(".", zarf_dir)
    entries = [p for p in (bundle.get("packages") or []) if p.get("name") == BUNDLE_PKG]
    if not entries:
        err(
            f"{BUNDLE} no longer registers '{BUNDLE_PKG}' — {organ} was dropped from "
            f"the full-organ bundle."
        )
    else:
        ep = entries[0].get("path", "")
        if not ep:
            err(f"{BUNDLE} {BUNDLE_PKG} entry has no 'path'.")
        elif norm(bundle_dir, ep) != want_pkg_dir:
            err(
                f"{BUNDLE} {BUNDLE_PKG} path '{ep}' resolves to "
                f"'{norm(bundle_dir, ep)}', expected '{want_pkg_dir}'."
            )
        else:
            print(f"OK: {BUNDLE} registers {BUNDLE_PKG} -> {want_pkg_dir}")

    if errors:
        print(f"\n{len(errors)} {organ} packaging check(s) FAILED")
        return 1
    print(f"\nAll {organ} packaging checks passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
