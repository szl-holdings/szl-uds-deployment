#!/usr/bin/env python3
# Copyright 2026 SZL Holdings
# SPDX-License-Identifier: Apache-2.0
#
# lint-cosign-identity-pin.py — Keep cosign verify commands for published SZL
# artifacts pinned to an EXACT signer identity, so the loose
# --certificate-identity-regexp form can never slip back into the docs/scripts.
#
# Why this exists
# ---------------
# Several published SZL artifacts are signed keyless (Sigstore OIDC) by a KNOWN,
# exact signer workflow:
#   * the szl-receipts PACKAGE (zarf-package-sign.yml) and receipts-server IMAGE
#     (receipts-server-image.yml)                                  — Task #545
#   * the killinchu organ image (killinchu/ghcr-build-push.yml),
#     the szl-mesh UDS bundle (uds-bundles/uds-bundle-publish.yml),
#     the a11oy-bundle / killinchu-bundle canonical bundles
#     (uds-bundles/uds-canonical-bundles-publish.yml), and the szl-fleet-overlay
#     zarf package (szl-fleet-overlay/zarf-package-sign.yml)       — Task #680
# Their cosign verify commands were once written with
# `--certificate-identity-regexp`, which accepts a signature produced by that
# workflow on ANY ref OR ANY fork — a materially weaker check. They have since
# been pinned to an exact `--certificate-identity`. Nothing else stopped a future
# doc edit from re-introducing the loose form; this lint does.
#
# What it asserts
# ---------------
#   For every cosign verify command (in tracked .md / .sh files) that targets a
#   pinnable published artifact:
#     * it must NOT use --certificate-identity-regexp, and
#     * it MUST carry an exact --certificate-identity.
#   The exact identity is per-artifact (an image is signed per-tag, a package /
#   bundle per-branch), so the guard only requires that *an* exact identity is
#   present — never a specific ref string.
#
# Scope / intentional exemptions
#   * Only commands that reference one of the pinnable artifacts below are checked.
#     As of Task #892 the two SURVIVING organ images (a11oy, killinchu) ARE
#     pinnable — their §4.2 SLSA-attestation verifies now carry an exact
#     --certificate-identity and are enforced.
#   * The DELETED organs (amaru/sentra/yupana) have no live repo and therefore no
#     signer identity to pin, so they are documented as unverifiable/removed and
#     left out of scope (no token matches them). A purely templated `${organ}`
#     placeholder verify is likewise out of scope.
#   * The legacy key-pair path (`cosign verify --key ...`) is identity-less by
#     design and is always allowed.
#
# Usage
#   python3 scripts/lint-cosign-identity-pin.py            # globs tracked docs/scripts
#   python3 scripts/lint-cosign-identity-pin.py FILE...    # checks exactly those files
#
# Complements (does not duplicate): image-pin-guard.yml, zarf-action-var-guard.yml,
# teardown-guard.yml, clean-deploy-guard.yml.

import os
import re
import sys
import glob

# A cosign verify command targeting any of these tokens is in scope. These are the
# literal substrings that appear in the artifact ref or the signer identity of a
# pinnable verify command. Each token is chosen so it does NOT match the
# intentionally-loose multi-organ attestation loop (which uses the `${organ}`
# placeholder, e.g. `szl-holdings/${organ}:uds-v0.2.0`).
PINNED_ARTIFACT_TOKENS = (
    # --- szl-receipts (Task #545) ---
    "szl-receipts-server",       # the receipts-server image repo
    "packages/szl-receipts",     # the (retired) internal package repo
    "szl-receipts:",             # the published package ref, e.g. .../szl-receipts:0.4.0-upstream
    "receipts-server-image.yml", # the image signing workflow (keyless identity)
    "zarf-package-sign.yml",     # a package signing workflow (keyless identity; receipts + fleet-overlay)
    # --- other published artifacts with a KNOWN exact signer (Task #680) ---
    "szl-holdings/killinchu:",   # killinchu organ image  -> killinchu/ghcr-build-push.yml@main
    # --- surviving organ images now exact-pinned (Task #892) ---
    # a11oy organ image -> a11oy/ghcr-build-push.yml@main. The trailing ':' keeps
    # this from matching the a11oy-bundle ('a11oy-bundle:') or the deleted-organ
    # remnant in §4.2 (amaru/sentra/yupana, which carry no live signer identity).
    "szl-holdings/a11oy:",
    "szl-mesh:",                 # szl-mesh UDS bundle     -> uds-bundles/uds-bundle-publish.yml@main
    "a11oy-bundle:",             # a11oy canonical bundle  -> uds-bundles/uds-canonical-bundles-publish.yml@main
    "killinchu-bundle:",         # killinchu canon bundle  -> uds-bundles/uds-canonical-bundles-publish.yml@main
    "szl-fleet-overlay",         # fleet overlay zarf pkg  -> szl-fleet-overlay/zarf-package-sign.yml@main
)

# --certificate-identity-regexp (loose) vs --certificate-identity (exact).
REGEXP_RE = re.compile(r"--certificate-identity-regexp")
# exact = --certificate-identity NOT immediately followed by "-regexp" (i.e. next
# char is '=' or whitespace).
EXACT_RE = re.compile(r"--certificate-identity(?=[=\s])")
# legacy key-pair path: --key <file> / --key=<file>
KEY_RE = re.compile(r"--key(?=[=\s])")

# Directories never scanned in glob (no-arg) mode.
SKIP_DIR_PARTS = ("/.git/", "/node_modules/", "/tests/fixtures/")


def logical_cosign_commands(text):
    """Yield (line_no, command_text) for each cosign verify invocation, joining
    backslash-continued lines so a multi-line fenced command is one logical unit."""
    lines = text.splitlines()
    n = len(lines)
    i = 0
    while i < n:
        line = lines[i]
        if "cosign verify" in line:
            start = i
            buf = [line]
            while buf[-1].rstrip().endswith("\\") and i + 1 < n:
                i += 1
                buf.append(lines[i])
            yield (start + 1, "\n".join(buf))
        i += 1


def check_command(cmd):
    """Return a violation reason string, or None if the command is fine."""
    if not any(tok in cmd for tok in PINNED_ARTIFACT_TOKENS):
        return None  # not a pinnable artifact -> out of scope
    if KEY_RE.search(cmd):
        return None  # legacy key-pair path is identity-less by design -> allowed
    if REGEXP_RE.search(cmd):
        return ("uses the loose --certificate-identity-regexp form for a "
                "pinnable published artifact; pin an exact --certificate-identity")
    if not EXACT_RE.search(cmd):
        return ("verifies a pinnable published artifact without an exact "
                "--certificate-identity (and is not the --key legacy path)")
    return None


def iter_target_files(argv):
    if argv:
        return list(argv)
    out = []
    for pattern in ("**/*.md", "**/*.sh"):
        for p in glob.glob(pattern, recursive=True):
            full = "/" + p.replace(os.sep, "/")
            if any(part in full for part in SKIP_DIR_PARTS):
                continue
            out.append(p)
    return sorted(set(out))


def main(argv):
    explicit = bool(argv)
    files = iter_target_files(argv)
    violations = []
    pinnable_cmds = 0
    for path in files:
        try:
            with open(path, "r", encoding="utf-8", errors="replace") as fh:
                text = fh.read()
        except (IsADirectoryError, FileNotFoundError):
            continue
        for line_no, cmd in logical_cosign_commands(text):
            if any(tok in cmd for tok in PINNED_ARTIFACT_TOKENS) and not KEY_RE.search(cmd):
                pinnable_cmds += 1
            reason = check_command(cmd)
            if reason:
                first = cmd.splitlines()[0].strip()
                violations.append((path, line_no, reason, first))

    for path, line_no, reason, first in violations:
        print(f"::error file={path},line={line_no}::{path}:{line_no}: {reason}")
        print(f"    {first}")

    if violations:
        print(f"\nFAIL: {len(violations)} loose/missing-identity cosign verify "
              f"command(s) for pinnable published artifacts.")
        return 1

    # In glob (CI) mode the guard must actually be covering something, or it is a
    # vacuous always-pass. Explicit single-file self-test runs are exempt.
    if not explicit and pinnable_cmds == 0:
        print("FAIL: no cosign verify command for a pinnable published artifact was "
              "found — the guard would be vacuous. Did the docs move?")
        return 1

    if explicit:
        print(f"OK: checked {len(files)} file(s); no loose pinnable-artifact identity verifies.")
    else:
        print(f"OK: {pinnable_cmds} pinnable-artifact cosign verify command(s) all use an "
              f"exact --certificate-identity (or the allowed --key path).")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
