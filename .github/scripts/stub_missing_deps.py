#!/usr/bin/env python3
# Copyright 2026 SZL Holdings
# SPDX-License-Identifier: Apache-2.0
#
# stub_missing_deps.py — make an umbrella chart render-testable in CI.
#
# Helm refuses to `helm template` / `helm lint` a chart while ANY declared
# dependency (even a disabled one) is missing from <chart>/charts/. Some umbrella
# charts here (e.g. szl-full-stack) declare subcharts that are STAGED — their
# container images / OCI charts have not been published yet (FA-001). That leaves
# the umbrella's OWN templates completely un-render-tested.
#
# This helper drops a minimal placeholder subchart in <chart>/charts/<dep> for
# every declared dependency that is not already vendored, so the umbrella's own
# templates DO get render-tested with default values. It is a no-op for leaf
# charts (no `dependencies:` block). Placeholder charts ship no templates, so an
# enabled stub renders nothing — the guard only validates the parent chart.
#
# Idempotent: an already-vendored dependency (real or previously-stubbed) is left
# untouched. The placeholder version is a constant valid semver; helm does not
# enforce the parent's version constraint against a vendored subchart.
import os
import sys

try:
    import yaml
except ImportError:
    sys.exit("::error::PyYAML not installed (pip install pyyaml)")

STUB_VERSION = "0.0.0"


def main() -> int:
    if len(sys.argv) != 2:
        sys.exit("usage: stub_missing_deps.py <chart-dir>")
    chart_dir = sys.argv[1].rstrip("/")
    chart_yaml = os.path.join(chart_dir, "Chart.yaml")
    if not os.path.isfile(chart_yaml):
        sys.exit(f"::error::{chart_yaml} not found")

    with open(chart_yaml) as fh:
        meta = yaml.safe_load(fh) or {}
    deps = meta.get("dependencies") or []
    if not deps:
        print(f"{chart_dir}: no dependencies — nothing to stub")
        return 0

    charts_subdir = os.path.join(chart_dir, "charts")
    for dep in deps:
        name = dep.get("name")
        if not name:
            continue
        target = os.path.join(charts_subdir, name)
        if os.path.isdir(target) or os.path.isfile(target + ".tgz"):
            print(f"{chart_dir}: dependency '{name}' already vendored — leaving it")
            continue
        os.makedirs(os.path.join(target, "templates"), exist_ok=True)
        with open(os.path.join(target, "Chart.yaml"), "w") as fh:
            fh.write(
                "apiVersion: v2\n"
                f"name: {name}\n"
                "description: CI render-test stub for a staged/unpublished dependency\n"
                "type: application\n"
                f'version: "{STUB_VERSION}"\n'
                f'appVersion: "{STUB_VERSION}"\n'
            )
        print(f"{chart_dir}: stubbed staged dependency '{name}' (no templates)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
