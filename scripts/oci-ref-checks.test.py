#!/usr/bin/env python3
# Copyright 2026 SZL Holdings
# SPDX-License-Identifier: Apache-2.0
#
# oci-ref-checks.test.py — negative-fixture self-test for the OCI-ref guard's pure
# core (extract_refs / classify_status / verdict).
#
# A guard is only trustworthy if it still FAILS on bad input. This self-test:
#   * proves extract_refs() finds the literal #678 stale ref and SKIPS
#     interpolated / tagless / non-szl-holdings refs,
#   * proves classify_status() returns the right verdict for every GHCR status
#     shape (200 anon / 200 PAT-only / 404 / 403 / outage / unknown),
#   * proves verdict() FAILS on a ref an injected resolver reports as 404
#     (the literal Task #678 `packages/szl-receipts:0.3.1` shape) and PASSES on a
#     ref reported 200 — so oci-ref-guard.yml runs it as a gating job and a
#     neutered check turns CI red here, not in production.
#
# Pure: imports the core directly and injects a deterministic fake resolver — no
# network, no GHCR.

import importlib.util
import os
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
_SPEC = importlib.util.spec_from_file_location(
    "oci_ref_checks", os.path.join(_HERE, "oci-ref-checks.py")
)
_MOD = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(_MOD)
extract_refs = _MOD.extract_refs
classify_status = _MOD.classify_status
verdict = _MOD.verdict


_FAILS = 0


def check(cond, msg):
    global _FAILS
    if cond:
        print("  ok: " + msg)
    else:
        print("  FAIL: " + msg)
        _FAILS += 1


def fake_resolver(table):
    """Build a resolver(repo,tag) -> (anon, pat, pat_tried) from a dict keyed by
    (repo, tag)."""
    def _r(repo, tag):
        return table[(repo, tag)]
    return _r


def main():
    # ── extract_refs: the literal #678 stale ref IS found ─────────────────────
    stale = (
        '      - description: "Deploy the published baseline"\n'
        '        cmd: |\n'
        '          zarf package deploy oci://ghcr.io/szl-holdings/packages/szl-receipts:0.3.1 --confirm\n'
    )
    refs = extract_refs(stale)
    check(
        any(r["repo"] == "szl-holdings/packages/szl-receipts" and r["tag"] == "0.3.1" for r in refs),
        "the literal Task #678 deploy ref is extracted",
    )

    # ── extract_refs: the current good default IS found ───────────────────────
    good_default = '  - name: UPGRADE_BASELINE_REF\n    default: "oci://ghcr.io/szl-holdings/szl-receipts:0.4.0-upstream"\n'
    refs = extract_refs(good_default)
    check(
        any(r["repo"] == "szl-holdings/szl-receipts" and r["tag"] == "0.4.0-upstream" for r in refs),
        "the UPGRADE_BASELINE_REF default literal is extracted",
    )

    # ── extract_refs: interpolated refs are SKIPPED (cannot resolve statically) ─
    interp = (
        '          uds pull "oci://${BUNDLE_REF}"\n'
        '          zarf package deploy "oci://ghcr.io/szl-holdings/szl-receipts:${VERSION}-upstream"\n'
        '          ( cd "$RT" && zarf package pull "oci://$OCI_REF" )\n'
    )
    check(extract_refs(interp) == [], "interpolated oci:// refs are skipped, not mis-resolved")

    # ── extract_refs: tagless + non-szl-holdings refs are SKIPPED ─────────────
    others = (
        '          OCI_REPO="oci://ghcr.io/szl-holdings/packages"\n'        # no tag
        '          zarf package pull "oci://ghcr.io/zarf-dev/packages/init:v0.77.0"\n'  # other org
    )
    check(extract_refs(others) == [], "tagless szl-holdings base + non-szl-holdings refs are skipped")

    # ── classify_status: every status shape maps to the right verdict ─────────
    check(classify_status(200)[0] == "OK", "anon 200 -> OK")
    check(classify_status(403, 200, True)[0] == "OK_PRIVATE", "anon 403 + PAT 200 -> OK_PRIVATE")
    check(classify_status(403, 404, True)[0] == "MISSING", "anon 403 + PAT 404 -> MISSING (the #678 shape)")
    check(classify_status(404)[0] == "MISSING", "anon 404 (no PAT) -> MISSING")
    check(classify_status(403, 403, True)[0] == "DENIED", "anon 403 + PAT 403 -> DENIED")
    check(classify_status(403)[0] == "UNVERIFIABLE", "anon 403, no PAT -> UNVERIFIABLE (not a false fail)")
    check(classify_status("OUTAGE")[0] == "OUTAGE", "anon OUTAGE -> OUTAGE (skip, not fail)")

    # ── verdict: a 404 ref FAILS, a 200 ref PASSES (the gating proof) ─────────
    refs = [
        {"repo": "szl-holdings/packages/szl-receipts", "tag": "0.3.1", "ref": "oci://ghcr.io/szl-holdings/packages/szl-receipts:0.3.1", "sources": ["tasks.yaml"]},
        {"repo": "szl-holdings/szl-receipts", "tag": "0.4.0-upstream", "ref": "oci://ghcr.io/szl-holdings/szl-receipts:0.4.0-upstream", "sources": ["tasks.yaml"]},
    ]
    table = {
        ("szl-holdings/packages/szl-receipts", "0.3.1"): (403, 404, True),   # the #678 ref: never published
        ("szl-holdings/szl-receipts", "0.4.0-upstream"): (200, None, False),  # the real published ref
    }
    failures, warnings, oks = verdict(refs, fake_resolver(table))
    check(
        len(failures) == 1 and "packages/szl-receipts:0.3.1" in failures[0],
        "verdict FAILS on the never-published #678 ref",
    )
    check(
        any("szl-receipts:0.4.0-upstream" in o for o in oks),
        "verdict PASSES the genuinely-published ref",
    )

    # ── verdict: an outage NEVER fails the build (no false red) ───────────────
    out_refs = [{"repo": "szl-holdings/szl-receipts", "tag": "x", "ref": "oci://ghcr.io/szl-holdings/szl-receipts:x", "sources": ["tasks.yaml"]}]
    f, w, _ = verdict(out_refs, fake_resolver({("szl-holdings/szl-receipts", "x"): ("OUTAGE", None, False)}))
    check(f == [] and len(w) == 1, "a registry OUTAGE is a warning, never a failure")

    # ── verdict: a private-but-published ref passes (with a warning) ──────────
    priv = [{"repo": "szl-holdings/szl-receipts", "tag": "p", "ref": "oci://ghcr.io/szl-holdings/szl-receipts:p", "sources": ["tasks.yaml"]}]
    f, w, oks = verdict(priv, fake_resolver({("szl-holdings/szl-receipts", "p"): (403, 200, True)}))
    check(f == [] and len(w) == 1 and len(oks) == 1, "a private-but-published ref passes with a warning")

    print()
    if _FAILS:
        print("SELF-TEST FAILED: %d assertion(s) failed." % _FAILS)
        return 1
    print("SELF-TEST PASSED: extract_refs finds the #678 literal & skips "
          "interpolated/tagless refs; verdict() fails a never-published ref and "
          "passes a published one.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
