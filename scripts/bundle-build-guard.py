#!/usr/bin/env python3
# Copyright 2026 SZL Holdings
# SPDX-License-Identifier: Apache-2.0
#
# bundle-build-guard.py — Catch broken `uds run bundle` builds before they ship.
#
# The one-command bundle build (`uds run bundle` in tasks.yaml) broke three
# separate ways while it was being made to work, and EVERY break only surfaced at
# build time (minutes into a `uds create`), never in review:
#
#   1. A new local-path package was added to uds-bundle.yaml (szl-a11oy) without a
#      matching `zarf package create` pre-build step in the `bundle` task. uds-cli
#      does NOT build local `path:` packages for you — it expects the
#      packages/<x>/zarf-package-*.tar.zst tarball to already exist and errors
#      "no such file" if it is absent.
#   2. a11oy was built with `--flavor upstream` even though it has NO
#      flavor-gated component, so the flavor filter silently dropped its only
#      component and produced an empty/broken package.
#   3. (out of scope for a text guard) intermediate files overflowed a small
#      /tmp — handled by the BUILD_TMPDIR variable, not by this guard.
#
# This guard catches regression classes (1) and (2) with a pure file scan (no
# cluster, no zarf, no network) whenever someone edits uds-bundle.yaml, tasks.yaml
# or packages/**. The two invariants:
#
#   A. Every LOCAL-PATH member of uds-bundle.yaml (a package entry with a `path:`)
#      has a corresponding `zarf package create <that path>` step in the `bundle`
#      task. (catches break class 1)
#   B. Every `zarf package create` step in the `bundle` task is consistent with
#      the target package's flavor gating:
#        - if the package has NO flavor-gated component (no component with
#          `only.flavor`) it must NOT be built with `--flavor`  (catches break
#          class 2: a stray --flavor that silently empties the package); and
#        - if the package HAS a flavor-gated component it MUST be built with
#          `--flavor` (the symmetric break: dropping --flavor silently excludes
#          the gated component — e.g. szl-receipts' only real server component).
#
# Usage:
#   scripts/bundle-build-guard.py [--root DIR]
# Exit 0 = all invariants satisfied, exit 1 = a regression was found.
# The self-test scripts/bundle-build-guard.test.py feeds the guard deliberately
# broken fixtures and asserts it FAILS, so a future edit that neuters a check
# (green while guarding nothing) is caught in CI.

import argparse
import os
import re
import sys

try:
    import yaml
except ImportError:
    sys.stderr.write(
        "ERROR: PyYAML is required (pip install pyyaml).\n"
    )
    sys.exit(2)

BUNDLE_FILE = "uds-bundle.yaml"
TASKS_FILE = "tasks.yaml"
BUNDLE_TASK = "bundle"
CREATE_RE = re.compile(r"zarf\s+package\s+create\s+(\S+)")


def norm(path):
    """Normalize a package path for comparison (strip ./ and trailing /)."""
    p = path.strip()
    if p.startswith("./"):
        p = p[2:]
    return p.rstrip("/")


def load_yaml(path):
    with open(path, "r", encoding="utf-8") as fh:
        return yaml.safe_load(fh)


def local_members(bundle):
    """Return [(name, normalized_path)] for every package with a local path."""
    out = []
    for pkg in (bundle or {}).get("packages", []) or []:
        if isinstance(pkg, dict) and pkg.get("path"):
            out.append((pkg.get("name", "<unnamed>"), norm(pkg["path"])))
    return out


def bundle_creates(tasks):
    """Return [(normalized_path, has_flavor)] for each `zarf package create`
    invocation found in the `bundle` task's actions."""
    creates = []
    for task in (tasks or {}).get("tasks", []) or []:
        if task.get("name") != BUNDLE_TASK:
            continue
        for action in task.get("actions", []) or []:
            cmd = action.get("cmd", "") or ""
            m = CREATE_RE.search(cmd)
            if m:
                creates.append((norm(m.group(1)), "--flavor" in cmd))
    return creates


def has_flavor_gated_component(zarf_path):
    """True if the package's zarf.yaml has any component with only.flavor."""
    try:
        z = load_yaml(zarf_path)
    except FileNotFoundError:
        return None  # caller reports the missing file
    for comp in (z or {}).get("components", []) or []:
        only = comp.get("only") if isinstance(comp, dict) else None
        if isinstance(only, dict) and only.get("flavor"):
            return True
    return False


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--root", default=".", help="repo root (default: .)")
    args = ap.parse_args()
    root = args.root

    errors = []

    bundle_path = os.path.join(root, BUNDLE_FILE)
    tasks_path = os.path.join(root, TASKS_FILE)
    for required in (bundle_path, tasks_path):
        if not os.path.isfile(required):
            errors.append("missing required file: %s" % required)
    if errors:
        for e in errors:
            print("FAIL: " + e)
        return 1

    bundle = load_yaml(bundle_path)
    tasks = load_yaml(tasks_path)

    members = local_members(bundle)
    creates = bundle_creates(tasks)
    create_paths = {p for p, _ in creates}

    # ── Invariant A: every local-path member has a pre-build step ────────────
    for name, path in members:
        if path not in create_paths:
            errors.append(
                "uds-bundle.yaml local-path member '%s' (path: %s) has NO "
                "matching `zarf package create %s` step in the '%s' task of %s.\n"
                "       uds-cli will NOT build a local `path:` package for you — "
                "add a pre-build step:\n"
                "         - description: \"Pre-build the %s Zarf package\"\n"
                "           cmd: |\n"
                "             zarf package create %s --output %s --confirm --no-progress\n"
                "       (add --flavor <flavor> ONLY if %s/zarf.yaml has a "
                "flavor-gated component)."
                % (name, path, path, BUNDLE_TASK, TASKS_FILE, name, path, path,
                   path)
            )

    # ── Invariant B: --flavor matches the package's flavor gating ────────────
    for path, has_flavor in creates:
        zarf_path = os.path.join(root, path, "zarf.yaml")
        gated = has_flavor_gated_component(zarf_path)
        if gated is None:
            errors.append(
                "the '%s' task builds '%s' but %s does not exist."
                % (BUNDLE_TASK, path, zarf_path)
            )
            continue
        if has_flavor and not gated:
            errors.append(
                "the '%s' task builds '%s' WITH `--flavor`, but %s/zarf.yaml has "
                "NO flavor-gated component (no component with `only.flavor`).\n"
                "       A `--flavor` filter on a package with no flavor-gated "
                "components silently drops components and produces a broken "
                "package. Remove `--flavor` from the `zarf package create %s` "
                "step." % (BUNDLE_TASK, path, path, path)
            )
        if gated and not has_flavor:
            errors.append(
                "the '%s' task builds '%s' WITHOUT `--flavor`, but %s/zarf.yaml "
                "HAS a flavor-gated component (a component with `only.flavor`).\n"
                "       Building without `--flavor` silently EXCLUDES that gated "
                "component from the package. Add `--flavor <flavor>` to the "
                "`zarf package create %s` step." % (BUNDLE_TASK, path, path, path)
            )

    if errors:
        print("Bundle Build Guard: FAILED — %d problem(s) found.\n" % len(errors))
        for e in errors:
            print("FAIL: " + e + "\n")
        return 1

    print(
        "Bundle Build Guard: OK — %d local-path bundle member(s) and %d "
        "`zarf package create` step(s) are consistent.\n"
        "  members:  %s\n"
        "  builds:   %s"
        % (
            len(members),
            len(creates),
            ", ".join("%s(%s)" % (n, p) for n, p in members) or "(none)",
            ", ".join(
                "%s[%s]" % (p, "flavor" if f else "no-flavor") for p, f in creates
            )
            or "(none)",
        )
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
