#!/usr/bin/env python3
# Copyright 2026 SZL Holdings
# SPDX-License-Identifier: Apache-2.0
#
# receipts_memory_guard.test.py — Self-test for the chart-derived RSS ceiling in
# scripts/receipts_memory_guard.py.
#
# The full guard seeds a 20k-receipt store and is run by the
# `receipts-memory-guard` job. This self-test covers, fast and with no seeding,
# the property added so the guard stays honest if the chart's memory limit
# changes: the RSS ceiling is DERIVED from charts/szl-receipts/values.yaml
# (server.resources.limits.memory) with a safety margin, and if that value can't
# be read the guard FAILS LOUD instead of silently using a default.
#
# Catches a future edit that re-hardcodes the ceiling or makes a missing/broken
# chart value pass silently. Run by the `receipts-memory-guard` job in
# .github/workflows/test.yaml. No cluster, no cryptography, no PyYAML.

import importlib.util
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
GUARD = os.path.join(HERE, "receipts_memory_guard.py")

PASS = 0
FAILED = 0


def _load_guard():
    spec = importlib.util.spec_from_file_location("szl_mem_guard", GUARD)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def ok(label, cond):
    global PASS, FAILED
    if cond:
        PASS += 1
        print("ok   - %s" % label)
    else:
        FAILED += 1
        print("FAIL - %s" % label)


def expect_die(label, fn):
    """The guard's fail-loud helpers raise SystemExit (non-zero)."""
    try:
        fn()
    except SystemExit as exc:
        ok(label, (exc.code or 0) != 0)
    except BaseException as exc:  # noqa: BLE001 - any other exception is a fail
        ok(label + " (raised %r, expected SystemExit)" % exc, False)
    else:
        ok(label + " (did not fail)", False)


# ── unit: memory-quantity parsing ───────────────────────────────────────────────
def test_parse_mem():
    g = _load_guard()
    cases = {
        "512Mi": 512.0, "1Gi": 1024.0, "256Mi": 256.0,
        '"512Mi"': 512.0,            # quoted, as the chart writes it
        "536870912": 512.0,          # bytes
        "1024Ki": 1.0,
    }
    for raw, want in cases.items():
        got = round(g._parse_mem_to_mib(raw), 3)
        ok("parse %s -> %g MiB" % (raw, want), got == want)

    for bad in ("", "abc", "512MB", "Mi", "-5Mi"):
        try:
            g._parse_mem_to_mib(bad)
        except ValueError:
            ok("parse rejects %r" % bad, True)
        else:
            ok("parse rejects %r" % bad, False)


# ── unit: indentation-stack scalar lookup ───────────────────────────────────────
def test_yaml_lookup():
    g = _load_guard()
    root = tempfile.mkdtemp()
    try:
        path = os.path.join(root, "values.yaml")
        with open(path, "w") as fh:
            fh.write(
                "global:\n  domain: uds.dev\n"
                "server:\n"
                "  name: szl-receipts-server\n"
                "  resources:\n"
                "    requests:\n"
                "      memory: \"256Mi\"\n"
                "    limits:\n"
                "      cpu: \"500m\"   # inline comment\n"
                "      memory: \"512Mi\"\n"
            )
        ok("lookup nested scalar",
           g._yaml_scalar_at(path, ["server", "resources", "limits", "memory"]) == "512Mi")
        ok("lookup honors sibling branch",
           g._yaml_scalar_at(path, ["server", "resources", "requests", "memory"]) == "256Mi")
        ok("lookup absent path -> None",
           g._yaml_scalar_at(path, ["server", "resources", "limits", "nope"]) is None)
        ok("lookup wrong root -> None",
           g._yaml_scalar_at(path, ["nope", "memory"]) is None)
    finally:
        shutil.rmtree(root, ignore_errors=True)


# ── unit: fail-loud derivation ──────────────────────────────────────────────────
def test_read_chart_limit():
    g = _load_guard()
    root = tempfile.mkdtemp()
    try:
        good = os.path.join(root, "good.yaml")
        with open(good, "w") as fh:
            fh.write("server:\n  resources:\n    limits:\n      memory: \"512Mi\"\n")
        g.CHART_VALUES = good
        ok("valid chart -> 512.0 MiB", g._read_chart_limit_mib() == 512.0)

        missing_key = os.path.join(root, "nolimit.yaml")
        with open(missing_key, "w") as fh:
            fh.write("server:\n  resources:\n    requests:\n      memory: \"256Mi\"\n")
        g.CHART_VALUES = missing_key
        expect_die("missing memory limit fails loud", g._read_chart_limit_mib)

        bad_val = os.path.join(root, "bad.yaml")
        with open(bad_val, "w") as fh:
            fh.write("server:\n  resources:\n    limits:\n      memory: \"banana\"\n")
        g.CHART_VALUES = bad_val
        expect_die("unparseable memory fails loud", g._read_chart_limit_mib)

        g.CHART_VALUES = os.path.join(root, "does-not-exist.yaml")
        expect_die("missing chart file fails loud", g._read_chart_limit_mib)
    finally:
        shutil.rmtree(root, ignore_errors=True)


# ── integration: real script entrypoint fails loud on a broken chart ────────────
def _run_in_temp_repo(memory_line):
    """Copy the guard into a throwaway REPO with a (possibly broken) chart and
    run it. Because the chart is read BEFORE any 20k seeding, a fail-loud path
    exits fast. memory_line=None omits the chart file entirely."""
    repo = tempfile.mkdtemp()
    try:
        os.makedirs(os.path.join(repo, "scripts"))
        shutil.copy(GUARD, os.path.join(repo, "scripts", "receipts_memory_guard.py"))
        if memory_line is not None:
            cdir = os.path.join(repo, "charts", "szl-receipts")
            os.makedirs(cdir)
            with open(os.path.join(cdir, "values.yaml"), "w") as fh:
                fh.write("server:\n  resources:\n    limits:\n" + memory_line)
        proc = subprocess.run(
            [sys.executable, os.path.join(repo, "scripts", "receipts_memory_guard.py")],
            capture_output=True, text=True, timeout=60,
        )
        return proc.returncode, proc.stdout + proc.stderr
    finally:
        shutil.rmtree(repo, ignore_errors=True)


def test_entrypoint_fail_loud():
    rc, out = _run_in_temp_repo(None)
    ok("entrypoint: no chart file -> non-zero exit", rc != 0)
    ok("entrypoint: no chart file -> explains why", "chart values not found" in out)

    rc, out = _run_in_temp_repo("      cpu: \"500m\"\n")  # limits present, no memory
    ok("entrypoint: missing memory key -> non-zero exit", rc != 0)
    ok("entrypoint: missing memory key -> explains why",
       "could not find server.resources.limits.memory" in out)

    rc, out = _run_in_temp_repo("      memory: \"banana\"\n")
    ok("entrypoint: unparseable memory -> non-zero exit", rc != 0)


def main():
    test_parse_mem()
    test_yaml_lookup()
    test_read_chart_limit()
    test_entrypoint_fail_loud()
    print("\n%d passed, %d failed" % (PASS, FAILED))
    return 1 if FAILED else 0


if __name__ == "__main__":
    sys.exit(main())
