#!/usr/bin/env python3
# Copyright 2026 SZL Holdings
# SPDX-License-Identifier: Apache-2.0
#
# a11oy-signing-key-checks.py — the testable logic behind a11oy-signing-key-guard.yml.
#
# a11oy signs its release/decision receipts with an ECDSA P-256 (secp256r1) key it
# loads from a mounted Secret (a11oy_signing_key.py). Four independent things on
# the charts/a11oy side must ALL hold or a11oy silently falls back to a throwaway
# in-process key that changes on every restart (which breaks offline verification
# of every receipt it ever signed). Each was BROKEN on main at some point:
#
#   1. keyinit-ecdsa     — the receipt-key-init Job's keygen provisions an ECDSA
#                          P-256 (SECP256R1) Secret whose data keys are exactly
#                          ecdsa-p256.key + ecdsa-p256.pem (the loader's first
#                          candidate filenames) and NOT the old Ed25519 scheme
#                          (which produced a key a11oy could not load).
#   2. secret-name-match — the Secret the Deployment MOUNTS (values.receiptKeySecret
#                          -> receipt-key volume secretName) is exactly the Secret
#                          the key-init Job PROVISIONS (its KEY_SECRET env). A drift
#                          here mounts an empty/absent Secret -> ephemeral fallback.
#   3. zarf-agent-ignore — `zarf.dev/agent: ignore` is emitted on the workload pod
#                          template when .Values.zarfAgentIgnore is set, and absent
#                          when it is not (the local-image k3d path needs it; a bad
#                          wiring leaves it dangling and the dev image never loads).
#   4. udspackage-gated  — the uds.dev/v1alpha1 Package renders only when
#                          .Values.udsPackage.enabled (off the UDS-Core mesh the CRD
#                          is absent, so an always-on Package fails `helm install`).
#
# These mirror scripts/chart-guard-checks.py: the bespoke assertion logic lives
# here so a11oy-signing-key-checks.test.py can feed each check deliberately-broken
# fixtures and assert it FAILS (a future edit that neuters a check turns CI red).
# `helm template` stays in the workflow (a well-tested external tool); this script
# only inspects its rendered output.
#
# Usage:
#   a11oy-signing-key-checks.py keyinit-ecdsa     <rendered.yaml>
#   a11oy-signing-key-checks.py secret-name-match <rendered.yaml>
#   a11oy-signing-key-checks.py zarf-agent-ignore <render-on.yaml> <render-off.yaml>
#   a11oy-signing-key-checks.py udspackage-gated  <render-on.yaml> <render-off.yaml>
#
# Each subcommand exits 0 when its property holds and 1 (printing a GitHub
# ::error annotation) when it is regressed.

import argparse
import sys

try:
    import yaml
except ImportError:
    sys.stderr.write("ERROR: PyYAML is required (pip install pyyaml).\n")
    sys.exit(2)


def err(msg):
    print("::error::" + msg)
    return 1


def _load_all(path):
    with open(path, "r", encoding="utf-8") as fh:
        return [d for d in yaml.safe_load_all(fh) if d]


def _pod_template_labels(doc):
    """Pod-template labels of a workload doc ({} if none)."""
    return (
        ((doc.get("spec") or {}).get("template") or {}).get("metadata") or {}
    ).get("labels") or {}


def _containers(doc):
    return (
        ((doc.get("spec") or {}).get("template") or {}).get("spec") or {}
    ).get("containers") or []


def _keygen_job(docs):
    """The receipt-key-init Job (kind: Job with a container named 'keygen')."""
    for d in docs:
        if d.get("kind") != "Job":
            continue
        for c in _containers(d):
            if c.get("name") == "keygen":
                return d, c
    return None, None


# ── keyinit-ecdsa ─────────────────────────────────────────────────────────────
def keyinit_ecdsa(rendered):
    docs = _load_all(rendered)
    job, container = _keygen_job(docs)
    if job is None:
        return err(
            "no receipt-key-init Job with a 'keygen' container found in %s "
            "(receiptKeyInit.enabled must render the keygen Job)" % rendered
        )
    args = container.get("args") or []
    if not args or not isinstance(args[0], str) or not args[0].strip():
        return err("keygen container has no inline provisioner script in args[0]")
    script = args[0]

    # Must generate an ECDSA P-256 (secp256r1) keypair.
    if "SECP256R1" not in script:
        return err(
            "keygen script does not generate an ECDSA P-256 key "
            "(expected ec.generate_private_key(ec.SECP256R1())) — a11oy's loader "
            "rejects anything that is not secp256r1"
        )
    if "ec.generate_private_key" not in script:
        return err("keygen script does not call ec.generate_private_key()")

    # Secret data keys must be exactly the loader's filenames.
    for fname in ("ecdsa-p256.key", "ecdsa-p256.pem"):
        if fname not in script:
            return err(
                "keygen script does not write Secret data key '%s' "
                "(a11oy_signing_key.py loads this filename)" % fname
            )

    # The old Ed25519 scheme produced a key a11oy could not load — hard-fail if it
    # creeps back into the keygen.
    low = script.lower()
    for forbidden in ("ed25519", "ed448"):
        if forbidden in low:
            return err(
                "keygen script references '%s' — the receipt key MUST be ECDSA "
                "P-256, not %s (a11oy fell back to an ephemeral key the last time "
                "this regressed)" % (forbidden, forbidden)
            )

    print("OK: keyinit-ecdsa — keygen provisions ECDSA P-256 Secret "
          "(ecdsa-p256.key + ecdsa-p256.pem, no Ed25519)")
    return 0


# ── secret-name-match ─────────────────────────────────────────────────────────
def _deployment_receipt_secret(docs):
    """secretName of the Deployment's receipt-key volume (None if absent)."""
    for d in docs:
        if d.get("kind") != "Deployment":
            continue
        vols = (
            ((d.get("spec") or {}).get("template") or {}).get("spec") or {}
        ).get("volumes") or []
        for v in vols:
            if v.get("name") == "receipt-key":
                return ((v.get("secret") or {}).get("secretName"))
    return None


def _keygen_key_secret_env(container):
    for e in container.get("env") or []:
        if e.get("name") == "KEY_SECRET":
            return e.get("value")
    return None


def secret_name_match(rendered):
    docs = _load_all(rendered)
    mounted = _deployment_receipt_secret(docs)
    if not mounted:
        return err(
            "Deployment has no receipt-key volume secretName in %s "
            "(a11oy mounts its signing key from this Secret)" % rendered
        )
    _, container = _keygen_job(docs)
    if container is None:
        return err(
            "no receipt-key-init keygen container found in %s — cannot confirm the "
            "mounted Secret is actually provisioned" % rendered
        )
    provisioned = _keygen_key_secret_env(container)
    if not provisioned:
        return err("keygen container has no KEY_SECRET env (Secret name to provision)")
    if mounted != provisioned:
        return err(
            "signing-key Secret name drift: Deployment mounts %r but key-init "
            "provisions %r — a11oy would mount an absent Secret and fall back to "
            "an ephemeral key" % (mounted, provisioned)
        )
    print("OK: secret-name-match — Deployment mounts and key-init provisions the "
          "same Secret (%r)" % mounted)
    return 0


# ── zarf-agent-ignore ─────────────────────────────────────────────────────────
LABEL = "zarf.dev/agent"


def _deployment(docs):
    for d in docs:
        if d.get("kind") == "Deployment":
            return d
    return None


def zarf_agent_ignore(render_on, render_off):
    on = _deployment(_load_all(render_on))
    off = _deployment(_load_all(render_off))
    if on is None or off is None:
        return err("could not find the a11oy Deployment in both rendered inputs")
    on_val = _pod_template_labels(on).get(LABEL)
    off_val = _pod_template_labels(off).get(LABEL)
    if on_val != "ignore":
        return err(
            "zarfAgentIgnore=true did not emit pod label '%s: ignore' on the "
            "Deployment (got %r) — the local-image path would be rewritten by the "
            "Zarf agent" % (LABEL, on_val)
        )
    if off_val is not None:
        return err(
            "zarfAgentIgnore unset still emitted pod label '%s: %s' on the "
            "Deployment — the flag must be wired to the value, not hard-coded"
            % (LABEL, off_val)
        )
    print("OK: zarf-agent-ignore — pod label '%s: ignore' present when "
          "zarfAgentIgnore set, absent when not" % LABEL)
    return 0


# ── udspackage-gated ──────────────────────────────────────────────────────────
def _has_uds_package(docs):
    for d in docs:
        if str(d.get("apiVersion", "")).startswith("uds.dev/") and \
                d.get("kind") == "Package":
            return True
    return False


def udspackage_gated(render_on, render_off):
    on = _has_uds_package(_load_all(render_on))
    off = _has_uds_package(_load_all(render_off))
    if not on:
        return err(
            "udsPackage.enabled=true did not render a uds.dev/v1alpha1 Package")
    if off:
        return err(
            "udsPackage.enabled=false still rendered a uds.dev/v1alpha1 Package — "
            "off the UDS-Core mesh the CRD is absent and `helm install` would fail")
    print("OK: udspackage-gated — uds.dev Package renders only when "
          "udsPackage.enabled")
    return 0


def main():
    p = argparse.ArgumentParser(description=__doc__)
    sub = p.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("keyinit-ecdsa")
    s.add_argument("rendered")
    s = sub.add_parser("secret-name-match")
    s.add_argument("rendered")
    s = sub.add_parser("zarf-agent-ignore")
    s.add_argument("render_on")
    s.add_argument("render_off")
    s = sub.add_parser("udspackage-gated")
    s.add_argument("render_on")
    s.add_argument("render_off")

    a = p.parse_args()
    if a.cmd == "keyinit-ecdsa":
        return keyinit_ecdsa(a.rendered)
    if a.cmd == "secret-name-match":
        return secret_name_match(a.rendered)
    if a.cmd == "zarf-agent-ignore":
        return zarf_agent_ignore(a.render_on, a.render_off)
    if a.cmd == "udspackage-gated":
        return udspackage_gated(a.render_on, a.render_off)
    return err("unknown subcommand")


if __name__ == "__main__":
    sys.exit(main())
