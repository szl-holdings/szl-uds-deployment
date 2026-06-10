#!/usr/bin/env python3
# Copyright 2026 SZL Holdings
# SPDX-License-Identifier: Apache-2.0
#
# bundle-build-guard.py — Catch broken `uds` bundle builds before they ship.
#
# The one-command bundle build (`uds run bundle` in tasks.yaml) broke three
# separate ways while it was being made to work, and EVERY break only surfaced at
# build time (minutes into a `uds create`), never in review:
#
#   1. A new local-path package was added to a bundle (szl-a11oy) without a
#      matching `zarf package create` pre-build step in its build. uds-cli does
#      NOT build local `path:` packages for you — it expects the
#      packages/<x>/zarf-package-*.tar.zst tarball to already exist and errors
#      "no such file" if it is absent.
#   2. a11oy was built with `--flavor upstream` even though it has NO
#      flavor-gated component, so the flavor filter silently dropped its only
#      component and produced an empty/broken package.
#   3. (out of scope for a text guard) intermediate files overflowed a small
#      /tmp — handled by the BUILD_TMPDIR variable, not by this guard.
#
# This guard catches regression classes (1) and (2) with a pure file scan (no
# cluster, no zarf, no network). It validates EVERY shipped bundle against
# wherever that bundle's member packages are actually built:
#
#   • the receipts-only ROOT bundle (uds-bundle.yaml) is built by the `bundle`
#     task in tasks.yaml (pre-build steps + `uds create .`); and
#   • the FULL-ORGAN bundle (bundles/szl-uds-bundle/uds-bundle.yaml) is built by
#     the `for organ in ...; do zarf package create "packages/$organ"` loop in
#     .github/workflows/uds-bundle-publish.yml.
#
# Both are checked because a broken member/flavor in EITHER bundle would still
# ship. See DEFAULT_TARGETS below for the authoritative list. The two invariants:
#
#   A. Every LOCAL-PATH member of the bundle (a package entry with a `path:`)
#      has a corresponding `zarf package create <that path>` step in that
#      bundle's build (a tasks.yaml step, or an organ in the workflow build
#      loop). (catches break class 1)
#   B. Every `zarf package create` step in that build is consistent with the
#      target package's flavor gating:
#        - if the package has NO flavor-gated component (no component with
#          `only.flavor`) it must NOT be built with `--flavor`  (catches break
#          class 2: a stray --flavor that silently empties the package); and
#        - if the package HAS a flavor-gated component it MUST be built with
#          `--flavor` (the symmetric break: dropping --flavor silently excludes
#          the gated component — e.g. szl-receipts' only real server component).
#
# Member `path:` values are resolved relative to the directory containing the
# bundle file (the full-organ bundle uses ../../packages/<organ>), so they
# compare apples-to-apples with the root-relative `zarf package create` paths.
#
# Usage:
#   scripts/bundle-build-guard.py [--root DIR]          # check all DEFAULT_TARGETS
#   scripts/bundle-build-guard.py --root DIR \          # check one explicit target
#       --bundle uds-bundle.yaml \
#       --build-kind task --build-file tasks.yaml --build-task bundle
#   scripts/bundle-build-guard.py --root DIR \
#       --bundle bundles/szl-uds-bundle/uds-bundle.yaml \
#       --build-kind workflow-loop \
#       --build-file .github/workflows/uds-bundle-publish.yml
# Exit 0 = all invariants satisfied, exit 1 = a regression was found.
# The self-test scripts/bundle-build-guard.test.py feeds the guard deliberately
# broken fixtures (for BOTH build kinds) and asserts it FAILS, so a future edit
# that neuters a check (green while guarding nothing) is caught in CI.

import argparse
import itertools
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

CREATE_RE = re.compile(r"zarf\s+package\s+create\s+(\S+)")
VAR_RE = re.compile(r"\$\{(\w+)\}|\$(\w+)")

# Authoritative list of every shipped bundle and where its member packages are
# actually built. Adding a new bundle? Add it here so it is guarded too.
DEFAULT_TARGETS = [
    {
        "label": "receipts bundle (root)",
        "bundle": "uds-bundle.yaml",
        "build_kind": "task",
        "build_file": "tasks.yaml",
        "build_task": "bundle",
    },
    {
        "label": "full-organ bundle",
        "bundle": "bundles/szl-uds-bundle/uds-bundle.yaml",
        "build_kind": "workflow-loop",
        "build_file": ".github/workflows/uds-bundle-publish.yml",
        "build_task": None,
    },
]


def norm(path):
    """Normalize a package path for comparison (strip ./ and trailing /)."""
    p = path.strip().strip('"').strip("'")
    if p.startswith("./"):
        p = p[2:]
    return p.rstrip("/")


def resolve_member_path(bundle_rel, member_path):
    """Resolve a bundle member `path:` to a repo-root-relative package path.

    Member paths are relative to the directory containing the bundle file, so
    the full-organ bundle's `../../packages/a11oy` resolves to `packages/a11oy`.
    """
    bundle_dir = os.path.dirname(bundle_rel)
    joined = os.path.normpath(os.path.join(bundle_dir, member_path.strip()))
    return norm(joined.replace(os.sep, "/"))


def load_yaml(path):
    with open(path, "r", encoding="utf-8") as fh:
        return yaml.safe_load(fh)


def local_members(bundle, bundle_rel):
    """Return [(name, root_relative_path)] for every package with a local path."""
    out = []
    for pkg in (bundle or {}).get("packages", []) or []:
        if isinstance(pkg, dict) and pkg.get("path"):
            out.append(
                (pkg.get("name", "<unnamed>"),
                 resolve_member_path(bundle_rel, pkg["path"]))
            )
    return out


def task_creates(tasks_path, task_name):
    """Return ([(normalized_path, has_flavor)], errors) for each
    `zarf package create` invocation in the named task's actions."""
    tasks = load_yaml(tasks_path)
    creates = []
    for task in (tasks or {}).get("tasks", []) or []:
        if task.get("name") != task_name:
            continue
        for action in task.get("actions", []) or []:
            cmd = action.get("cmd", "") or ""
            m = CREATE_RE.search(cmd)
            if m:
                creates.append((norm(m.group(1)), "--flavor" in cmd))
    return creates, []


def _join_continued(lines, idx):
    """Join a shell command at lines[idx] with its backslash-continued lines."""
    parts = [lines[idx]]
    j = idx
    while parts[-1].rstrip().endswith("\\") and j + 1 < len(lines):
        j += 1
        parts.append(lines[j])
    return " ".join(p.rstrip().rstrip("\\").strip() for p in parts)


def workflow_loop_creates(workflow_path):
    """Return ([(normalized_path, has_flavor)], errors) for each
    `zarf package create` command in a workflow file, expanding any enclosing
    `for VAR in items; do` loop so each member build is resolved statically.

    Only bare command invocations (a line that, after indentation, STARTS with
    `zarf package create`) are treated as real builds — comment and `echo`
    mentions of the command are ignored. If a build path references a loop
    variable with no resolvable `for ... in ...; do`, that is reported as an
    error (fail loud) rather than silently skipped, so the guard can never pass
    vacuously."""
    with open(workflow_path, "r", encoding="utf-8") as fh:
        text = fh.read()

    # Map loop variable -> items, scanning every `for VAR in a b c; do`.
    loops = {}
    for m in re.finditer(r"for\s+(\w+)\s+in\s+(.+?);\s*do", text):
        loops[m.group(1)] = m.group(2).split()

    lines = text.splitlines()
    creates = []
    errors = []
    for idx, line in enumerate(lines):
        if not line.strip().startswith("zarf package create"):
            continue
        cmd = _join_continued(lines, idx)
        m = CREATE_RE.search(cmd)
        if not m:
            continue
        raw = norm(m.group(1))
        has_flavor = "--flavor" in cmd
        var_names = [a or b for a, b in VAR_RE.findall(raw)]
        if not var_names:
            creates.append((raw, has_flavor))
            continue
        distinct = list(dict.fromkeys(var_names))
        unknown = [v for v in distinct if v not in loops]
        if unknown:
            errors.append(
                "%s: `zarf package create %s` references loop variable(s) %s "
                "with no enclosing `for ... in ...; do` this guard can resolve; "
                "the bundle build cannot be verified statically."
                % (workflow_path, raw, ", ".join(sorted(set(unknown))))
            )
            continue
        for combo in itertools.product(*[loops[v] for v in distinct]):
            sub = raw
            for v, val in zip(distinct, combo):
                sub = sub.replace("${%s}" % v, val).replace("$%s" % v, val)
            creates.append((norm(sub), has_flavor))
    return creates, errors


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


def check_target(root, target):
    """Validate invariants A and B for one bundle target.

    Returns (errors, summary) where summary is (members, creates) or None when a
    required file is missing."""
    errors = []
    bundle_rel = target["bundle"]
    build_file_rel = target["build_file"]
    build_kind = target["build_kind"]
    build_task = target.get("build_task")

    bundle_path = os.path.join(root, bundle_rel)
    build_path = os.path.join(root, build_file_rel)
    for required in (bundle_path, build_path):
        if not os.path.isfile(required):
            errors.append("missing required file: %s" % required)
    if errors:
        return errors, None

    bundle = load_yaml(bundle_path)
    members = local_members(bundle, bundle_rel)

    if build_kind == "task":
        creates, cerr = task_creates(build_path, build_task)
        build_loc = "the '%s' task of %s" % (build_task, build_file_rel)
    elif build_kind == "workflow-loop":
        creates, cerr = workflow_loop_creates(build_path)
        build_loc = "the organ build loop in %s" % build_file_rel
    else:
        return ["unknown build_kind %r for %s" % (build_kind, bundle_rel)], None
    errors.extend(cerr)

    create_paths = {p for p, _ in creates}

    # ── Invariant A: every local-path member has a pre-build step ────────────
    for name, path in members:
        if path not in create_paths:
            if build_kind == "task":
                fix = (
                    "add a pre-build step:\n"
                    "         - description: \"Pre-build the %s Zarf package\"\n"
                    "           cmd: |\n"
                    "             zarf package create %s --output %s --confirm --no-progress\n"
                    "       (add --flavor <flavor> ONLY if %s/zarf.yaml has a "
                    "flavor-gated component)." % (name, path, path, path)
                )
            else:
                fix = (
                    "add '%s' to the `for ... in ...; do` organ list that runs "
                    "`zarf package create \"packages/$organ\"` in %s, or the "
                    "bundle build will fail \"no such file\" for this member."
                    % (os.path.basename(path), build_file_rel)
                )
            errors.append(
                "%s: local-path member '%s' (path: %s) has NO matching "
                "`zarf package create %s` step in %s.\n"
                "       uds-cli will NOT build a local `path:` package for you — "
                "%s" % (bundle_rel, name, path, path, build_loc, fix)
            )

    # ── Invariant B: --flavor matches the package's flavor gating ────────────
    for path, has_flavor in creates:
        zarf_path = os.path.join(root, path, "zarf.yaml")
        gated = has_flavor_gated_component(zarf_path)
        if gated is None:
            errors.append(
                "%s: %s builds '%s' but %s does not exist."
                % (bundle_rel, build_loc, path, zarf_path)
            )
            continue
        if has_flavor and not gated:
            errors.append(
                "%s: %s builds '%s' WITH `--flavor`, but %s/zarf.yaml has NO "
                "flavor-gated component (no component with `only.flavor`).\n"
                "       A `--flavor` filter on a package with no flavor-gated "
                "components silently drops components and produces a broken "
                "package. Remove `--flavor` from the `zarf package create %s` "
                "step." % (bundle_rel, build_loc, path, path, path)
            )
        if gated and not has_flavor:
            errors.append(
                "%s: %s builds '%s' WITHOUT `--flavor`, but %s/zarf.yaml HAS a "
                "flavor-gated component (a component with `only.flavor`).\n"
                "       Building without `--flavor` silently EXCLUDES that gated "
                "component from the package. Add `--flavor <flavor>` to the "
                "`zarf package create %s` step."
                % (bundle_rel, build_loc, path, path, path)
            )

    return errors, (members, creates)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--root", default=".", help="repo root (default: .)")
    ap.add_argument("--bundle", help="check ONE explicit bundle (relative to root)")
    ap.add_argument(
        "--build-kind", choices=["task", "workflow-loop"],
        help="build source kind for --bundle"
    )
    ap.add_argument("--build-file", help="build source file for --bundle")
    ap.add_argument(
        "--build-task", help="tasks.yaml task name (for --build-kind task)"
    )
    args = ap.parse_args()
    root = args.root

    if args.bundle:
        if not args.build_kind or not args.build_file:
            ap.error("--bundle requires --build-kind and --build-file")
        if args.build_kind == "task" and not args.build_task:
            ap.error("--build-kind task requires --build-task")
        targets = [{
            "label": args.bundle,
            "bundle": args.bundle,
            "build_kind": args.build_kind,
            "build_file": args.build_file,
            "build_task": args.build_task,
        }]
    else:
        targets = DEFAULT_TARGETS

    all_errors = []
    summaries = []
    for target in targets:
        errors, summary = check_target(root, target)
        if errors:
            all_errors.append((target, errors))
        else:
            summaries.append((target, summary))

    if all_errors:
        total = sum(len(e) for _, e in all_errors)
        print("Bundle Build Guard: FAILED — %d problem(s) found.\n" % total)
        for target, errors in all_errors:
            for e in errors:
                print("FAIL [%s]: %s\n" % (target["label"], e))
        return 1

    print("Bundle Build Guard: OK — %d bundle target(s) consistent." % len(summaries))
    for target, summary in summaries:
        members, creates = summary
        print(
            "  [%s] %s\n"
            "    members:  %s\n"
            "    builds:   %s"
            % (
                target["label"],
                target["bundle"],
                ", ".join("%s(%s)" % (n, p) for n, p in members) or "(none)",
                ", ".join(
                    "%s[%s]" % (p, "flavor" if f else "no-flavor")
                    for p, f in creates
                ) or "(none)",
            )
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
