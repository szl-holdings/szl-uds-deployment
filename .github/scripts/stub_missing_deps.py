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
# For each declared dependency that is not already vendored, this helper does ONE
# of two things before the umbrella is rendered:
#
#   1. If a REAL local chart for that dependency exists in the same charts/ tree
#      (a sibling <charts-root>/<dep>/Chart.yaml), it is COPIED into
#      <chart>/charts/<dep>. This makes the umbrella render against the real
#      subchart, so the umbrella's `<dep>:` value overrides are validated against
#      the subchart's actual schema/templates — a bad override key can no longer
#      ship silently. (szl-full-stack's szl-receipts dependency is exactly this
#      case: charts/szl-receipts exists locally and is enabled by default.)
#
#   2. Otherwise (a genuinely staged/unpublished dependency, e.g. a11oy-runtime,
#      sentra-gates, amaru-attestation, rosie-replay), a minimal placeholder
#      subchart with no templates is written so the umbrella's own templates
#      still render. An enabled placeholder renders nothing.
#
# It is a no-op for leaf charts (no `dependencies:` block).
#
# Idempotent: an already-vendored dependency (real, copied, or previously-stubbed)
# is left untouched. The placeholder version is a constant valid semver; helm does
# not enforce the parent's version constraint against a vendored subchart (so a
# real local chart whose version differs from the umbrella's dependency pin is
# still accepted).
import os
import shutil
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
    # The charts/ tree this umbrella lives in, so we can find real sibling charts.
    charts_root = os.path.dirname(chart_dir) or "."
    umbrella_name = os.path.basename(chart_dir)
    for dep in deps:
        name = dep.get("name")
        if not name:
            continue
        target = os.path.join(charts_subdir, name)
        if os.path.isdir(target) or os.path.isfile(target + ".tgz"):
            print(f"{chart_dir}: dependency '{name}' already vendored — leaving it")
            continue
        # Prefer the REAL local chart if one exists as a sibling under charts/, so
        # the umbrella renders against it and its value overrides are validated.
        local_src = os.path.join(charts_root, name)
        if name != umbrella_name and os.path.isfile(
            os.path.join(local_src, "Chart.yaml")
        ):
            os.makedirs(charts_subdir, exist_ok=True)
            shutil.copytree(local_src, target)
            print(f"{chart_dir}: vendored REAL local chart '{name}' from {local_src}")
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
