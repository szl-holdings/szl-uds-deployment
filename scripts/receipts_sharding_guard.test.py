#!/usr/bin/env python3
# Copyright 2026 SZL Holdings
# SPDX-License-Identifier: Apache-2.0
#
# receipts_sharding_guard.test.py — Negative-fixture self-test for the COLD-ARCHIVE
# verifier in scripts/receipts_sharding_guard.py (verify_cold_archive, the PHASE A2
# offline re-verification of cold-archived receipt tarballs).
#
# Why this exists (the org "guard trio" pattern)
# ----------------------------------------------
# verify_cold_archive re-opens every <cold>/<bucket>.tar.gz and proves, with
# nothing but the public key + the sidecar manifest, that each sealed bucket is
# STILL a verifiable chain segment: the manifest tarball_sha256 matches the real
# bytes, every receipt's Ed25519/DSSE signature + SHA-256 chain hash + intra-bucket
# prev_hash link re-verify, the manifest first_prev_hash/last_hash match the real
# receipt bytes, and the cold segments stitch GENESIS -> bucket -> live tail.
#
# The full sharding guard (receipts-sharding-guard job) only ever feeds it a CLEAN
# archive, so a future refactor could quietly loosen the verifier to an always-pass
# and the happy-path job would stay green. This self-test closes that hole: it
# builds a REAL cold archive (via the guard's own server-seed + archive-shards
# helpers — genuinely signed receipts, real tarballs + manifests) and then feeds
# verify_cold_archive four crafted-bad archives, each isolating ONE failure mode,
# asserting it returns non-zero every time, while the untouched clean archive
# returns 0.
#
# The four crafted-bad fixtures (each isolates ONE failure mode):
#   1. flipped receipt byte    — a payload byte flipped inside a tarball (the tar is
#        repacked and its manifest tarball_sha256 fixed up, so ONLY the per-receipt
#        signature/chain-hash re-verification fails, not the sha256-at-rest check).
#   2. wrong tarball_sha256     — the manifest's tarball_sha256 is corrupted; the
#        bytes + receipts are untouched, so ONLY the corruption-at-rest check fails.
#   3. broken intra-bucket link — a receipt's chain.prev_hash (NOT its signed
#        envelope) is rewritten + the tar repacked/sha-fixed, so signature + chain
#        hash still verify and ONLY the intra-bucket prev_hash link breaks.
#   4. mismatched stitch        — the manifest's last_hash boundary is corrupted; the
#        tarball bytes + receipts are intact, so ONLY the manifest-boundary-vs-bytes
#        stitch check fails.
#
# Run by the `receipts-sharding-guard` job in .github/workflows/test.yaml, ahead of
# the full guard. Needs cryptography + openssl (same as the full guard); no cluster.

import importlib.util
import os
import shutil
import sys
import tarfile
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
GUARD = os.path.join(HERE, "receipts_sharding_guard.py")

PASS = 0
FAILED = 0


def _load_guard():
    spec = importlib.util.spec_from_file_location("szl_shard_guard", GUARD)
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


# ── fixture helpers (mutate a copy of a real cold archive in ONE isolated way) ────
def _copy_cold(src, dst):
    shutil.copytree(src, dst)
    return dst


def _repack_bucket(G, cold, bucket, recs):
    """Re-write `recs` back into <cold>/<bucket>.tar.gz with the server's arcname
    layout (receipts under <bucket>/*.json) and re-sync the manifest's
    tarball_sha256 to the NEW bytes — so a content mutation inside the tarball is
    NOT masked by (and does not trip) the separate sha256-at-rest check."""
    staging = tempfile.mkdtemp(prefix="szl-repack-")
    try:
        bdir = os.path.join(staging, bucket)
        os.makedirs(bdir)
        for i, rec in enumerate(recs):
            ci = rec.get("chain", {}).get("chain_index", i)
            with open(os.path.join(bdir, f"{ci:020d}.json"), "w") as f:
                import json
                json.dump(rec, f)
        tar_path = os.path.join(cold, f"{bucket}.tar.gz")
        with tarfile.open(tar_path, "w:gz") as tar:
            tar.add(bdir, arcname=bucket)
    finally:
        shutil.rmtree(staging, ignore_errors=True)
    # keep the corruption-at-rest check satisfied; isolate the tested failure.
    _set_manifest(G, cold, bucket, tarball_sha256=G._sha256_file(tar_path))


def _set_manifest(G, cold, bucket, **fields):
    import json
    p = os.path.join(cold, f"{bucket}.manifest.json")
    mf = G._read_json(p)
    mf.update(fields)
    with open(p, "w") as f:
        json.dump(mf, f, indent=2)


def main():
    G = _load_guard()

    # A wrong-but-well-formed 64-hex value, for corrupting hash fields without
    # tripping any "is this even a hash?" shape check.
    BOGUS_HEX = "ba5eba11" * 8

    # ── Build a REAL, multi-bucket cold archive via the guard's own machinery ─────
    # Small numbers (shard_size=2, n=5) → sealed buckets 00000000 + 00000001 and a
    # 1-receipt tail bucket 00000002 — two sealed buckets is enough to exercise the
    # GENESIS-link, bucket->bucket stitch, and last->tail stitch.
    shard_size, n = 2, 5
    work = tempfile.mkdtemp(prefix="szl-shard-guard-selftest-")
    try:
        key = os.path.join(work, "ed25519.pem")
        G._gen_key(key)
        store = os.path.join(work, "store")
        os.makedirs(store)
        G._seed_signed_store(store, key, shard_size, n, port=8151)

        last_index = n - 1
        tail_bucket = f"{last_index // shard_size:08d}"
        sealed = sorted({f"{i // shard_size:08d}" for i in range(n)} - {tail_bucket})
        assert len(sealed) >= 2, "self-test needs >=2 sealed buckets"

        cold0 = os.path.join(work, "cold")
        rc, rep = G._cli(store, key, shard_size,
                         ["archive-shards", "--delete"], cold_dir=cold0)
        assert rc == 0 and sorted(rep.get("archived", [])) == sealed, \
            f"self-test setup: archive-shards did not seal the expected buckets: {rep}"

        pub = G._public_key_raw_from_pem(key)
        tail_first_prev = (G._receipts_in_bucket(store, tail_bucket)[0]
                           .get("chain", {}).get("prev_hash"))

        # ── (0) the CLEAN archive verifies (0 failures) — the positive control ────
        print("\n== clean cold archive verifies (positive control) ==")
        clean = _copy_cold(cold0, os.path.join(work, "cold_clean"))
        ok("clean cold archive: verify_cold_archive returns 0 (no failures)",
           G.verify_cold_archive(clean, sealed, pub, tail_first_prev) == 0)

        # ── (1) flipped receipt byte → per-receipt sig/chain-hash re-verify fails ──
        print("\n== fixture 1: flipped receipt byte inside a cold tarball ==")
        c1 = _copy_cold(cold0, os.path.join(work, "cold_flip"))
        b = sealed[0]
        recs, tmp = G._extract_cold_bucket(os.path.join(c1, f"{b}.tar.gz"), b)
        try:
            import base64
            raw = bytearray(base64.b64decode(recs[0]["envelope"]["payload"]))
            raw[0] ^= 0x01
            recs[0]["envelope"]["payload"] = base64.b64encode(bytes(raw)).decode()
        finally:
            shutil.rmtree(tmp, ignore_errors=True)
        _repack_bucket(G, c1, b, recs)   # repack + fix sha256 → isolate to sig/hash
        ok("flipped receipt byte: verify_cold_archive returns non-zero",
           G.verify_cold_archive(c1, sealed, pub, tail_first_prev) > 0)

        # ── (2) wrong manifest tarball_sha256 → corruption-at-rest check fails ─────
        print("\n== fixture 2: wrong manifest tarball_sha256 ==")
        c2 = _copy_cold(cold0, os.path.join(work, "cold_sha"))
        _set_manifest(G, c2, sealed[0], tarball_sha256=BOGUS_HEX)
        ok("wrong tarball_sha256: verify_cold_archive returns non-zero",
           G.verify_cold_archive(c2, sealed, pub, tail_first_prev) > 0)

        # ── (3) broken intra-bucket prev_hash link (envelope/sig untouched) ───────
        print("\n== fixture 3: broken intra-bucket prev_hash link ==")
        c3 = _copy_cold(cold0, os.path.join(work, "cold_link"))
        recs, tmp = G._extract_cold_bucket(os.path.join(c3, f"{b}.tar.gz"), b)
        try:
            # rewrite the SECOND receipt's chain.prev_hash only (NOT its signed
            # envelope) → signature + chain hash still verify, only the link breaks.
            recs[1]["chain"]["prev_hash"] = BOGUS_HEX
        finally:
            shutil.rmtree(tmp, ignore_errors=True)
        _repack_bucket(G, c3, b, recs)
        ok("broken intra-bucket link: verify_cold_archive returns non-zero",
           G.verify_cold_archive(c3, sealed, pub, tail_first_prev) > 0)

        # ── (4) mismatched manifest stitch boundary (last_hash) ───────────────────
        print("\n== fixture 4: mismatched manifest first_prev_hash/last_hash ==")
        c4 = _copy_cold(cold0, os.path.join(work, "cold_stitch"))
        # corrupt the lowest sealed bucket's recorded last_hash: the tarball bytes +
        # receipts are intact, so ONLY the manifest-boundary-vs-bytes check fails.
        _set_manifest(G, c4, sealed[0], last_hash=BOGUS_HEX)
        ok("mismatched stitch boundary: verify_cold_archive returns non-zero",
           G.verify_cold_archive(c4, sealed, pub, tail_first_prev) > 0)
    finally:
        shutil.rmtree(work, ignore_errors=True)

    print("\n%d passed, %d failed" % (PASS, FAILED))
    if FAILED:
        print("::error::receipts_sharding_guard cold-archive verifier self-test "
              "FAILED — the offline cold verifier did not reject a crafted-bad "
              "archive (or rejected a clean one). The negative path may be broken "
              "(always-pass verifier?).")
        return 1
    print("Cold-archive verifier self-test PASSED: verify_cold_archive rejects a "
          "flipped receipt byte, a wrong manifest tarball_sha256, a broken "
          "intra-bucket prev_hash link, and a mismatched manifest stitch boundary, "
          "while accepting a clean archive.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
