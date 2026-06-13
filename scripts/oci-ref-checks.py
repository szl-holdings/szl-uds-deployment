#!/usr/bin/env python3
# Copyright 2026 SZL Holdings
# SPDX-License-Identifier: Apache-2.0
#
# oci-ref-checks.py — the testable logic behind oci-ref-guard.yml.
#
# A deploy/publish command can point at an OCI package that was NEVER PUBLISHED
# (or was retired) and nothing catches it until a live run silently 403s/404s.
# Task #678 was exactly this: a stale
# `zarf package deploy oci://ghcr.io/szl-holdings/packages/szl-receipts:0.3.1`
# reference that 403s anonymously / 404s authenticated — found by hand, not CI.
# The repo already guards image-DIGEST pins (image-pin-checks /
# receipts-pin-drift) but nothing checks that the OCI package REFS in the
# deploy/publish surfaces actually resolve.
#
# This guard scans the deploy/publish surfaces (tasks.yaml, tasks/*.yaml,
# scripts/*) for LITERAL `oci://ghcr.io/szl-holdings/<repo>:<tag>` references and
# fails if a referenced tag does not resolve on GHCR. These literals are exactly
# what `zarf package deploy` / `zarf package pull` consume — e.g. the
# UPGRADE_BASELINE_REF default that `test-upgrade` deploys.
#
# WHY THE `oci://` LITERAL ANCHOR:
#   * `oci://ghcr.io/szl-holdings/<path>:<tag>` is precisely the string a Zarf/UDS
#     deploy or pull resolves at runtime, so matching it catches the #678 class
#     directly (whether it sits in a `deploy` cmd or a variable `default:` that a
#     `deploy "${VAR}"` consumes).
#   * A ref carrying a shell/zarf interpolation (`${...}`, `$(...)`, `###...###`)
#     is NOT a static literal — it cannot be resolved here — so it is SKIPPED
#     (reported, never failed). e.g. `uds pull "oci://${BUNDLE_REF}"`.
#   * A bare `oci://ghcr.io/szl-holdings/packages` with NO tag is a publish TARGET
#     base, not a deployable manifest, so it is SKIPPED.
#   * Non-szl-holdings refs (e.g. `oci://ghcr.io/zarf-dev/packages/init:vX`) are
#     out of scope (this guard owns OUR packages).
#
# RESOLUTION (matches the robustness lessons in image-pin-checks):
#   For each (repo, tag) we ask GHCR for the manifest. We try the ANONYMOUS pull
#   token first (the deploy surfaces are documented as anon-pullable), and only
#   fall back to the repo PAT to CLASSIFY a denied/absent result:
#     * 200 (anon)            -> OK  (anon-pullable, the desired state)
#     * 200 (PAT only)        -> OK, with a ::warning:: that it is published but
#                                NOT anon-pullable (a CI anon `deploy` would 403)
#     * 404 (best auth)       -> MISSING  -> FAIL (never published — the #678 bug)
#     * 401/403 (even w/ PAT) -> DENIED   -> FAIL (unreachable; a deploy would 403)
#     * network / 5xx / other -> OUTAGE   -> SKIP with ::warning:: (never a silent
#                                pass AND never a false red on a registry hiccup)
#
# The pure decision logic lives in classify_status() and verdict(), which take an
# already-resolved status (or an injected resolver), so oci-ref-checks.test.py can
# feed it the literal #678 shape and assert it FAILS — the guard cannot pass
# vacuously. Network I/O stays in resolve_ghcr() / the CLI.
#
# Usage:
#   oci-ref-checks.py extract  <repo_root>          # list the refs it would check
#   oci-ref-checks.py check    <repo_root>          # resolve every ref; exit 1 on
#                                                   #   any MISSING/DENIED ref
#
# Env: GHCR_TOKEN or GITHUB_TOKEN (optional) enables the PAT classification
# fallback. Without it, anon-undeterminable refs are reported UNVERIFIABLE, not
# failed.
#
# Exit: 0 = every resolvable ref is published; 1 = a ref does not resolve; 2 =
# usage/parse error.

import argparse
import json
import os
import re
import sys
import urllib.error
import urllib.request

# Surfaces a deploy/publish ref can live in. Files are relative to repo_root.
SCAN_GLOBS = (
    ("tasks.yaml",),
    ("tasks",),     # directory: every *.yaml under it
    ("scripts",),   # directory: every regular file under it
)

# A literal szl-holdings OCI package ref WITH a tag, constrained to the OCI
# distribution grammar so prose punctuation (a trailing `)`/`.` in a comment) and
# `<placeholder>` example refs do NOT match. repo path = lowercase-ish path
# segments; tag = `[A-Za-z0-9_][A-Za-z0-9._-]*` per the OCI tag spec. Shell/zarf
# interpolation is filtered out separately (is_literal_ref).
REF_RE = re.compile(
    r"oci://ghcr\.io/szl-holdings/(?P<repo_tail>[A-Za-z0-9][A-Za-z0-9._/-]*)"
    r":(?P<tag>[A-Za-z0-9_][A-Za-z0-9._-]*)"
)

# This guard's own implementation + self-test necessarily embed example/fixture
# refs (docstrings, the literal #678 shape, etc.); they are NOT deploy surfaces,
# so they are excluded from the live scan. The self-test exercises them directly.
SELF_EXCLUDE = {
    os.path.join("scripts", "oci-ref-checks.py"),
    os.path.join("scripts", "oci-ref-checks.test.py"),
}

GHCR_ACCEPT = ",".join(
    (
        "application/vnd.oci.image.manifest.v1+json",
        "application/vnd.oci.image.index.v1+json",
        "application/vnd.docker.distribution.manifest.v2+json",
        "application/vnd.docker.distribution.manifest.list.v2+json",
    )
)


def err(msg):
    print("::error::" + msg)


def warn(msg):
    print("::warning::" + msg)


def note(msg):
    print("note: " + msg)


# ── extraction (pure over text) ──────────────────────────────────────────────
def is_literal_ref(ref):
    """A ref is statically resolvable only if it has no shell/zarf interpolation."""
    return not any(tok in ref for tok in ("${", "$(", "$", "###", "{{"))


def extract_refs(text):
    """Return a list of {repo, tag, ref} for every LITERAL szl-holdings oci:// ref
    carrying a tag. Interpolated refs are dropped (caller can report them).

    Pure: takes text, returns structured refs — no I/O.
    """
    out = []
    for m in REF_RE.finditer(text):
        repo_tail = m.group("repo_tail")
        tag = m.group("tag")
        full = m.group(0)
        # Skip interpolated refs (repo path or tag built from a variable).
        if not is_literal_ref(full):
            continue
        repo = "szl-holdings/" + repo_tail
        out.append({"repo": repo, "tag": tag, "ref": "oci://ghcr.io/%s:%s" % (repo, tag)})
    return out


def collect_refs(repo_root):
    """Scan the deploy/publish surfaces under repo_root. Returns (refs, skipped):
    refs = deduped list of {repo,tag,ref,sources:[file...]}, skipped = human notes
    about interpolated/tagless refs we could not statically resolve.
    """
    files = []
    for spec in SCAN_GLOBS:
        path = os.path.join(repo_root, spec[0])
        if os.path.isfile(path):
            files.append(path)
        elif os.path.isdir(path):
            for root, dirs, names in os.walk(path):
                dirs[:] = [d for d in dirs if d != "__pycache__"]
                for n in names:
                    fp = os.path.join(root, n)
                    if spec[0] == "tasks" and not n.endswith((".yaml", ".yml")):
                        continue
                    if n.endswith((".pyc", ".pyo")):
                        continue
                    files.append(fp)

    by_key = {}
    skipped = []
    for fp in sorted(set(files)):
        if os.path.relpath(fp, repo_root) in SELF_EXCLUDE:
            continue
        try:
            with open(fp, "r", encoding="utf-8", errors="replace") as fh:
                text = fh.read()
        except OSError:
            continue
        rel = os.path.relpath(fp, repo_root)
        for r in extract_refs(text):
            key = (r["repo"], r["tag"])
            entry = by_key.setdefault(
                key, {"repo": r["repo"], "tag": r["tag"], "ref": r["ref"], "sources": []}
            )
            if rel not in entry["sources"]:
                entry["sources"].append(rel)
        # Note interpolated szl-holdings refs so a maintainer knows they're unchecked.
        for m in REF_RE.finditer(text):
            if not is_literal_ref(m.group(0)):
                skipped.append("%s: %s (interpolated — not statically resolvable)" % (rel, m.group(0)))
    return sorted(by_key.values(), key=lambda e: (e["repo"], e["tag"])), skipped


# ── status classification (pure) ─────────────────────────────────────────────
# status codes we hand classify_status:
#   int HTTP code (200/401/403/404/5xx) or the sentinel "OUTAGE".
def classify_status(anon_code, pat_code=None, pat_tried=False):
    """Decide the verdict for one ref from its resolved HTTP status(es).

    anon_code : status from the anonymous pull attempt (int or "OUTAGE").
    pat_code  : status from the PAT fallback (int or "OUTAGE"), or None.
    pat_tried : whether a PAT was available and a fallback was attempted.

    Returns (verdict, detail) where verdict in
    {"OK", "OK_PRIVATE", "MISSING", "DENIED", "UNVERIFIABLE", "OUTAGE"}.
    Only MISSING and DENIED are failures.
    """
    if anon_code == 200:
        return "OK", "resolves anonymously (HTTP 200)"

    # Anon did not return 200. Prefer the PAT answer when we have one.
    if pat_tried and pat_code is not None and pat_code != "OUTAGE":
        if pat_code == 200:
            return (
                "OK_PRIVATE",
                "published but NOT anonymously pullable (anon=%s, PAT=200) — a CI "
                "anonymous `deploy` of this ref would be denied" % anon_code,
            )
        if pat_code == 404:
            return "MISSING", "does not exist on GHCR (PAT HTTP 404 — never published)"
        if pat_code in (401, 403):
            return "DENIED", "unreachable even with the repo token (PAT HTTP %s)" % pat_code
        return "UNVERIFIABLE", "unexpected GHCR status (anon=%s, PAT=%s)" % (anon_code, pat_code)

    # No usable PAT answer.
    if anon_code == 404:
        return "MISSING", "does not exist on GHCR (anon HTTP 404 — never published)"
    if anon_code in (401, 403):
        return (
            "UNVERIFIABLE",
            "anonymous access denied (HTTP %s) and no repo token available to "
            "classify whether it is private-but-published or missing" % anon_code,
        )
    if anon_code == "OUTAGE":
        return "OUTAGE", "GHCR unreachable (network/registry error)"
    return "UNVERIFIABLE", "unexpected GHCR status %s" % anon_code


def verdict(refs, resolver):
    """Resolve every ref via the injected resolver and split into failures/notes.

    resolver(repo, tag) -> (anon_code, pat_code, pat_tried)

    Returns (failures, warnings, oks) — all lists of strings. A non-empty
    `failures` means the guard must exit 1. Pure w.r.t. I/O (the resolver carries
    it), so the self-test can inject a deterministic fake.
    """
    failures, warnings, oks = [], [], []
    for r in refs:
        anon, pat, pat_tried = resolver(r["repo"], r["tag"])
        v, detail = classify_status(anon, pat, pat_tried)
        where = ", ".join(r.get("sources", [])) or "?"
        line = "%s [%s] — %s" % (r["ref"], where, detail)
        if v in ("MISSING", "DENIED"):
            failures.append(line)
        elif v == "OK":
            oks.append(line)
        elif v == "OK_PRIVATE":
            oks.append(line)
            warnings.append(line)
        else:  # UNVERIFIABLE / OUTAGE
            warnings.append(line)
    return failures, warnings, oks


# ── network resolution (impure; not exercised by the unit self-test) ─────────
def _ghcr_token(repo, basic_auth=None):
    url = "https://ghcr.io/token?scope=repository:%s:pull&service=ghcr.io" % repo
    req = urllib.request.Request(url)
    if basic_auth:
        import base64

        req.add_header("Authorization", "Basic " + base64.b64encode(basic_auth.encode()).decode())
    try:
        with urllib.request.urlopen(req, timeout=20) as resp:
            body = json.loads(resp.read().decode())
            return body.get("token") or body.get("access_token")
    except (urllib.error.URLError, json.JSONDecodeError, OSError):
        return None


def _manifest_status(repo, tag, token):
    url = "https://ghcr.io/v2/%s/manifests/%s" % (repo, tag)
    req = urllib.request.Request(url, method="HEAD")
    req.add_header("Accept", GHCR_ACCEPT)
    if token:
        req.add_header("Authorization", "Bearer " + token)
    try:
        with urllib.request.urlopen(req, timeout=20) as resp:
            return resp.getcode()
    except urllib.error.HTTPError as e:
        return e.code
    except (urllib.error.URLError, OSError):
        return "OUTAGE"


def resolve_ghcr(repo, tag):
    """Real resolver: anon first, then PAT (GHCR_TOKEN/GITHUB_TOKEN) to classify."""
    anon_tok = _ghcr_token(repo)  # public packages still hand out an anon token
    anon_code = _manifest_status(repo, tag, anon_tok)
    if anon_code == 200:
        return anon_code, None, False

    pat = os.environ.get("GHCR_TOKEN") or os.environ.get("GITHUB_TOKEN")
    if not pat:
        return anon_code, None, False
    pat_tok = _ghcr_token(repo, basic_auth="x:" + pat)
    pat_code = _manifest_status(repo, tag, pat_tok) if pat_tok else "OUTAGE"
    return anon_code, pat_code, True


# ── CLI ──────────────────────────────────────────────────────────────────────
def cmd_extract(args):
    refs, skipped = collect_refs(args.repo_root)
    for s in skipped:
        note(s)
    if not refs:
        print("No literal oci://ghcr.io/szl-holdings/<repo>:<tag> refs found in the "
              "deploy/publish surfaces (tasks.yaml, tasks/*.yaml, scripts/*).")
        return 0
    for r in refs:
        print("%s   <- %s" % (r["ref"], ", ".join(r["sources"])))
    return 0


def cmd_check(args):
    refs, skipped = collect_refs(args.repo_root)
    for s in skipped:
        note(s)
    if not refs:
        # Legitimately possible (all deploys are tarball-based). Not a vacuous
        # pass: the self-test + the workflow's live e2e prove the resolution path
        # actually fails on a missing ref.
        print("OK: no literal oci://ghcr.io/szl-holdings/<repo>:<tag> deploy/publish "
              "refs to verify.")
        return 0

    failures, warnings, oks = verdict(refs, resolve_ghcr)
    for o in oks:
        note("resolves: " + o)
    for w in warnings:
        warn(w)
    if failures:
        for f in failures:
            err("OCI deploy/publish ref does not resolve: " + f)
        print(
            "\nFAIL: %d unresolved OCI package ref(s) in the deploy/publish surfaces "
            "— a deploy/pull of these would 403/404 at runtime (the Task #678 class)."
            % len(failures)
        )
        return 1
    print(
        "OK: all %d literal szl-holdings OCI deploy/publish ref(s) resolve on GHCR."
        % len(refs)
    )
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="cmd", required=True)
    p_ex = sub.add_parser("extract", help="list the literal OCI refs that would be checked")
    p_ex.add_argument("repo_root", help="path to the repo root")
    p_ex.set_defaults(func=cmd_extract)
    p_ck = sub.add_parser("check", help="resolve every OCI ref on GHCR; fail on a missing one")
    p_ck.add_argument("repo_root", help="path to the repo root")
    p_ck.set_defaults(func=cmd_check)
    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
