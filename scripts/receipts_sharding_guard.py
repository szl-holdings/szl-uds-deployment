#!/usr/bin/env python3
# Copyright 2026 SZL Holdings
# SPDX-License-Identifier: Apache-2.0
#
# receipts_sharding_guard.py — Regression guard that the szl-receipts-server's
# index-SHARDING write path, the bounded `verify-store` audit, and the
# verify-gated `archive-shards` cold-storage rollup keep the receipt chain VALID
# and VERIFIABLE.
#
# Why this exists
# ---------------
# Receipts are written into index-sharded buckets (<store>/shards/<bucket>/,
# bucket = chain_index // SHARD_SIZE) so the store stays bounded as the chain
# grows. `server.py verify-store` audits the WHOLE on-disk store one bucket at a
# time, and `server.py archive-shards` rolls completed ("sealed") buckets — every
# bucket strictly below the TAIL the head currently writes into — off the live
# store into cold tarballs, but only AFTER each is re-verified. This whole path
# was validated once by a throwaway sandbox script (Task #512); nothing committed
# guards it, so a refactor could silently:
#   * write receipts into the wrong bucket (chain order / linkage breaks),
#   * seal the still-growing TAIL bucket (data loss of in-flight receipts),
#   * archive a bucket that FAILS verification (laundering a tampered shard),
#   * or turn `verify-store` into an always-pass audit (tamper goes unnoticed).
#
# This guard boots the REAL server with a real Ed25519 key and a deliberately
# small SZL_RECEIPT_SHARD_SIZE, POSTs N genuinely-SIGNED receipts so they span
# several buckets, then proves end-to-end:
#
#   PHASE A — sharding + archival happy path
#     1. the N signed receipts land across the expected shard buckets;
#     2. `verify-store` reports total==valid==N and chain_ok=true;
#     3. `archive-shards --delete` seals ONLY the buckets below the tail, leaves
#        the tail bucket on the live store, and writes a tarball + manifest +
#        ledger for each sealed bucket into cold storage;
#     4. the manifest CONTENT is real and verifiable, not just present: each
#        sealed bucket's count == SHARD_SIZE, first_prev_hash/last_hash are real
#        chain hashes, the lowest sealed bucket links back to GENESIS, consecutive
#        buckets stitch (last_hash == next first_prev_hash), and the last cold
#        bucket stitches into the LIVE tail's first receipt — so an auditor can
#        re-attach cold storage to the live chain;
#     5. post-archive `verify-store` over what remains live still passes.
#
#   PHASE A2 - COLD tarballs are still a verifiable chain segment
#     verify-store only audits what is LIVE; the whole point of archival is that a
#     sealed bucket can be re-attached to the chain LATER from cold storage. This
#     re-opens every <cold_dir>/<bucket>.tar.gz and proves, with NOTHING but the
#     public key + manifest:
#       * the manifest's tarball_sha256 matches the actual tarball bytes (no
#         silent corruption of the archive at rest);
#       * every receipt inside re-verifies its Ed25519/DSSE signature, its SHA-256
#         chain hash, and its intra-bucket prev_hash link - verified INDEPENDENTLY
#         of server.py (the cryptography lib here, not the server's own verifier,
#         so this cannot go hollow if the server's verifier regresses);
#       * the manifest's first_prev_hash/last_hash match what the real receipt
#         bytes say, and the cold segments stitch GENESIS -> bucket -> bucket ->
#         the surviving LIVE tail - an auditor can re-attach cold storage to disk;
#       * the offline verifier is not an always-pass: a flipped byte in a cold
#         receipt breaks both its signature and its chain hash.
#
#   PHASE B — verify-store actually catches tampering
#     A single flipped byte in one stored receipt flips chain_ok to false and
#     names the receipt (so "chain_ok=true" is not a hollow always-pass).
#
#   PHASE C — archival refuses to seal a bucket that fails verification
#     With one receipt in a SEALED (below-tail) bucket tampered, `archive-shards
#     --delete` lists that bucket under skipped_failed_verify, does NOT archive
#     it, and does NOT delete it from the live store (no laundering / no loss),
#     while the other clean sealed buckets still archive.
#
#   PHASE D — legacy flat-root additive read survives archival
#     Pre-sharding stores wrote receipts as flat files in the store ROOT. The
#     store iterator reads those legacy files IN ADDITION to the shard buckets.
#     With the oldest chunk moved into the flat root (as legacy files) and the
#     rest left sharded, the legacy root + shards verify as one continuous chain,
#     and after an `archive-shards --delete` run the legacy flat files are left
#     untouched AND are STILL enumerated/verified by `verify-store` — a refactor
#     that only ever walked shards/ would silently stop auditing them and fail.
#
# No cluster required. Run: python3 scripts/receipts_sharding_guard.py
#
# Tunables (env):
#   GUARD_SHARD_SIZE   receipts per shard bucket   (default 5)
#   GUARD_RECEIPTS     total signed receipts        (default 17 -> 3 sealed + tail)

import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
SERVER_PATH = os.path.join(REPO, "services", "szl-receipts-server", "server.py")


# ── small helpers ───────────────────────────────────────────────────────────────
def _assert(ok, msg):
    print(f"  {'ok  ' if ok else 'FAIL'} {msg}")
    return 0 if ok else 1


def _gen_key(path):
    subprocess.run(
        ["openssl", "genpkey", "-algorithm", "ED25519", "-out", path],
        check=True, capture_output=True,
    )


def _wait_health(port, tries=40):
    for _ in range(tries):
        try:
            with urllib.request.urlopen(
                    f"http://127.0.0.1:{port}/health", timeout=1) as r:
                if r.status == 200:
                    return True
        except Exception:
            time.sleep(0.5)
    return False


def _post_receipt(port, subject):
    body = json.dumps({"action": "deploy", "subject": subject,
                       "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ")}).encode()
    req = urllib.request.Request(
        f"http://127.0.0.1:{port}/receipt", data=body,
        headers={"Content-Type": "application/json"}, method="POST")
    with urllib.request.urlopen(req, timeout=15) as r:
        resp = json.loads(r.read().decode())
    if resp.get("valid") is not True:
        raise SystemExit(f"::error::server did not sign receipt {subject!r} "
                         f"(valid != true): {resp}")
    return resp


def _cli(store, key, shard_size, args, cold_dir=None):
    """Run `server.py <args>` as the operator CLI against `store`, returning
    (returncode, parsed_json_report). The CLI prints log lines then the report
    as indent=2 JSON last, so we parse the final balanced JSON object."""
    env = dict(os.environ)
    env.update({
        "SZL_RECEIPT_STORE": store,
        "SZL_ED25519_KEY_PATH": key,
        "SZL_RECEIPT_SHARD_SIZE": str(shard_size),
    })
    if cold_dir is not None:
        env["SZL_RECEIPT_COLD_DIR"] = cold_dir
    out = subprocess.run([sys.executable, SERVER_PATH, *args],
                         capture_output=True, text=True, env=env)
    report = _parse_trailing_json(out.stdout)
    if report is None:
        print(f"::error::CLI {' '.join(args)} produced no JSON report")
        print(out.stdout)
        print(out.stderr, file=sys.stderr)
        raise SystemExit(1)
    return out.returncode, report


def _parse_trailing_json(text):
    """Parse the LAST top-level JSON object printed on stdout (the CLI emits log
    lines first, then json.dumps(report, indent=2))."""
    lines = text.splitlines()
    for i in range(len(lines)):
        if lines[i].strip() == "{":
            try:
                return json.loads("\n".join(lines[i:]))
            except json.JSONDecodeError:
                continue
    return None


def _tamper_receipt(path):
    """Flip one byte of a stored receipt's signed payload — breaking BOTH its
    Ed25519 signature (over the DSSE PAE of the payload) and its SHA-256
    hash-chain link, exactly like on-disk tampering under the store."""
    import base64
    with open(path) as f:
        rec = json.load(f)
    env = rec["envelope"]
    raw = bytearray(base64.b64decode(env["payload"]))
    raw[0] ^= 0x01
    env["payload"] = base64.b64encode(bytes(raw)).decode()
    with open(path, "w") as f:
        json.dump(rec, f)


def _bucket_dir(store, bucket):
    return os.path.join(store, "shards", bucket)


def _bucket_names(store):
    shards = os.path.join(store, "shards")
    try:
        return sorted(e.name for e in os.scandir(shards) if e.is_dir())
    except FileNotFoundError:
        return []


def _first_receipt_in(store, bucket):
    bdir = _bucket_dir(store, bucket)
    for e in sorted(os.scandir(bdir), key=lambda x: x.name):
        if e.is_file() and e.name.endswith(".json"):
            return e.path
    raise SystemExit(f"::error::no receipt file in bucket {bucket}")


# mirrors server.py GENESIS — the sentinel prev_hash at the root of the chain.
GENESIS = "GENESIS"


def _read_json(path):
    with open(path) as f:
        return json.load(f)


def _is_hex64(s):
    """A real SHA-256 chain hash is 64 lowercase hex chars (not GENESIS, not '')."""
    return isinstance(s, str) and len(s) == 64 and all(
        c in "0123456789abcdef" for c in s)


def _receipts_in_bucket(store, bucket):
    """Every receipt record in a LIVE shard bucket, sorted by chain_index."""
    recs = [_read_json(e.path) for e in os.scandir(_bucket_dir(store, bucket))
            if e.is_file() and e.name.endswith(".json")]
    recs.sort(key=lambda r: r.get("chain", {}).get("chain_index", 0))
    return recs


# ── cold-archive re-verification (offline, public-key only) ──────────────────────
# These mirror server.py's signing/chain scheme but are RE-IMPLEMENTED here rather
# than imported, so PHASE A2 verifies cold tarballs INDEPENDENTLY of the server's
# own verifier — the property under test is "a cold bucket is verifiable with just
# the public key", not "server.py agrees with itself".
_PAYLOAD_TYPE = "application/vnd.szl.receipt.v1+json"  # mirrors server.PAYLOAD_TYPE


def _public_key_raw_from_pem(key_path):
    """Derive the 32-byte raw Ed25519 PUBLIC key from the guard's private PEM.
    Cold re-verification uses ONLY the public key — exactly the posture an auditor
    has when re-attaching a cold bucket (the private key never leaves the signer)."""
    from cryptography.hazmat.primitives.serialization import (
        load_pem_private_key, Encoding, PublicFormat)
    with open(key_path, "rb") as f:
        priv = load_pem_private_key(f.read(), password=None)
    return priv.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)


def _dsse_pae(body, payload_type=_PAYLOAD_TYPE):
    """Canonical DSSEv1 PAE (mirrors server.dsse_pae)."""
    tb = payload_type.encode("utf-8")
    return b" ".join([b"DSSEv1", str(len(tb)).encode("ascii"), tb,
                      str(len(body)).encode("ascii"), body])


def _b64u_decode(s):
    import base64
    return base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))


def _verify_receipt_sig(rec, public_key_raw):
    """True iff the receipt's DSSE Ed25519 signature verifies over the canonical
    PAE of its payload, using ONLY the public key (mirrors server.verify_dsse)."""
    import base64
    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey
    from cryptography.exceptions import InvalidSignature
    env = rec.get("envelope", {}) or {}
    sigs = env.get("signatures", [])
    if not sigs:
        return False
    sig_b64u = sigs[0].get("sig", "")
    if not sig_b64u or sig_b64u.startswith("UNSIGNED"):
        return False
    body = base64.b64decode(env.get("payload", ""))
    pae = _dsse_pae(body, env.get("payloadType", _PAYLOAD_TYPE))
    try:
        Ed25519PublicKey.from_public_bytes(public_key_raw).verify(
            _b64u_decode(sig_b64u), pae)
        return True
    except InvalidSignature:
        return False
    except Exception:
        return False


def _chain_hash(rec):
    """SHA-256 over the canonical signed envelope — the chain link value
    (mirrors server._receipt_hash)."""
    import hashlib
    canonical = json.dumps(rec["envelope"], sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(canonical.encode("utf-8")).hexdigest()


def _sha256_file(path):
    import hashlib
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def _stream_out(src, dst, chunk=1 << 16):
    """Copy a file as a raw BYTE STREAM, stdlib-only, NEVER shelling out to a
    `tar` binary nor repacking via tarfile. This mirrors EXACTLY how the box
    retention job (box-scripts/sbin/szl-receipts-retention) lifts a cold tarball
    OFF the receipts PVC: the slim receipts-server image has no `tar`, so
    `kubectl cp` cannot be used and the script streams the bytes with
    `kubectl exec -- cat <pod-path> > <host-path>`. Returns the dst path."""
    with open(src, "rb") as fi, open(dst, "wb") as fo:
        for blk in iter(lambda: fi.read(chunk), b""):
            fo.write(blk)
    return dst


def _extract_cold_bucket(tar_path, bucket):
    """Extract a cold tarball into a fresh temp dir and return (records sorted by
    chain_index, temp_dir). The server tars the bucket as `tar.add(bdir,
    arcname=bucket)`, so receipts live under `<bucket>/*.json` inside the tarball."""
    import tarfile
    tmp = tempfile.mkdtemp(prefix="szl-cold-extract-")
    with tarfile.open(tar_path, "r:gz") as tar:
        tar.extractall(tmp)
    bdir = os.path.join(tmp, bucket)
    recs = [_read_json(e.path) for e in os.scandir(bdir)
            if e.is_file() and e.name.endswith(".json")]
    recs.sort(key=lambda r: r.get("chain", {}).get("chain_index", 0))
    return recs, tmp


def verify_cold_archive(cold, sealed_buckets, pub_key_raw, tail_first_prev=None):
    """Offline re-verification of cold-archived tarballs — PHASE A2's core check
    extracted as a STANDALONE, self-testable unit (see
    scripts/receipts_sharding_guard.test.py).

    Re-opens every <cold>/<bucket>.tar.gz with NOTHING but the public key + the
    sidecar <bucket>.manifest.json and proves each sealed bucket is STILL a
    verifiable chain segment:
      (1) the manifest's tarball_sha256 matches the actual tarball bytes (no silent
          corruption of the archive at rest);
      (2) every receipt inside re-verifies its Ed25519/DSSE signature, its SHA-256
          chain hash, and its intra-bucket prev_hash link — verified INDEPENDENTLY
          of server.py (the cryptography lib here, not the server's own verifier);
      (3) the manifest's first_prev_hash/last_hash match what the REAL receipt bytes
          say (not merely self-consistent metadata);
      (4) the byte-derived cold segments stitch GENESIS -> bucket -> bucket -> the
          surviving live tail (tail_first_prev), so an auditor can re-attach cold
          storage to disk. tail_first_prev is OPTIONAL: when None (e.g. an auditor
          verifying an off-box backup copy with no live store on hand) the GENESIS
          + inter-bucket stitches still run and the live-tail re-attachment is
          HONESTLY reported as unchecked rather than faked.

    Returns the number of FAILED checks (0 == a clean, verifiable cold archive).
    Manifests are read FROM DISK here (not passed in) so a self-test can mutate a
    crafted-bad archive and watch this return non-zero — the guard-trio property
    that a refactor cannot quietly loosen this verifier to an always-pass.
    """
    fails = 0
    cold_segments = {}   # bucket -> (first_prev_hash, last_hash) from REAL bytes
    for b in sealed_buckets:
        tar_path = os.path.join(cold, f"{b}.tar.gz")
        mf = _read_json(os.path.join(cold, f"{b}.manifest.json"))
        # (1) no silent corruption: manifest tarball_sha256 == actual bytes.
        fails += _assert(_sha256_file(tar_path) == mf.get("tarball_sha256"),
                         f"cold tarball[{b}] sha256 matches its manifest "
                         f"(no silent corruption at rest)")
        # (2) re-open the tarball and re-verify every receipt inside it.
        recs, tmp = _extract_cold_bucket(tar_path, b)
        try:
            fails += _assert(len(recs) == mf.get("count"),
                             f"cold bucket[{b}] holds count receipts "
                             f"({len(recs)} == {mf.get('count')})")
            seg_ok = bool(recs)
            expected_prev = (recs[0].get("chain", {}).get("prev_hash")
                             if recs else None)
            first_prev = expected_prev
            last_hash = None
            for rec in recs:
                chain = rec.get("chain", {}) or {}
                sig_ok = _verify_receipt_sig(rec, pub_key_raw)
                hash_ok = (_chain_hash(rec) == chain.get("hash"))
                link_ok = (chain.get("prev_hash") == expected_prev)
                seg_ok = seg_ok and sig_ok and hash_ok and link_ok
                expected_prev = chain.get("hash")
                last_hash = chain.get("hash") or last_hash
            fails += _assert(seg_ok,
                             f"cold bucket[{b}]: every receipt's Ed25519/DSSE "
                             f"signature + chain hash + intra-bucket link "
                             f"re-verify offline")
            # (3) the manifest boundary hashes match the REAL receipt bytes,
            #     not just self-consistent metadata.
            fails += _assert(first_prev == mf.get("first_prev_hash"),
                             f"cold bucket[{b}] first receipt prev_hash == "
                             f"manifest first_prev_hash")
            fails += _assert(last_hash == mf.get("last_hash"),
                             f"cold bucket[{b}] last receipt hash == "
                             f"manifest last_hash")
            cold_segments[b] = (first_prev, last_hash)
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    # (4) the re-verified cold segments stitch into ONE chain from GENESIS up to
    #     the surviving LIVE tail — using hashes read from the TARBALL bytes, so an
    #     auditor can re-attach cold storage to what is still on disk.
    if cold_segments and len(cold_segments) == len(sealed_buckets):
        fails += _assert(cold_segments[sealed_buckets[0]][0] == GENESIS,
                         "lowest cold bucket re-attaches to GENESIS (from bytes)")
        for i in range(len(sealed_buckets) - 1):
            cur, nxt = sealed_buckets[i], sealed_buckets[i + 1]
            fails += _assert(cold_segments[cur][1] == cold_segments[nxt][0],
                             f"cold segments stitch: {cur}.last_hash == "
                             f"{nxt}.first_prev_hash (from tarball bytes)")
        if tail_first_prev is None:
            # Operator/auditor mode: no live tail on hand (e.g. re-verifying an
            # off-box backup copy). The final re-attachment to the surviving live
            # store is HONESTLY reported as unchecked rather than faked — every
            # other check above still ran and fails loud on any tampering.
            print("  -- cold->live-tail re-attachment UNCHECKED "
                  "(no tail_first_prev supplied)")
        else:
            fails += _assert(
                cold_segments[sealed_buckets[-1]][1] == tail_first_prev,
                "highest cold bucket's last_hash == live tail's first prev_hash "
                "(cold re-attaches to the surviving live store)")
    else:
        # An unreadable/missing cold segment is itself a verification FAILURE —
        # never let an incomplete segment set silently skip the GENESIS->tail
        # stitch proof (that would be an always-pass hole).
        fails += _assert(False,
                         f"all {len(sealed_buckets)} cold segments were readable "
                         f"for the GENESIS->tail stitch proof "
                         f"(got {len(cold_segments)})")
    return fails


# ── operator CLI: re-verify a cold-archive directory offline (public key only) ────
# Thin wrapper around verify_cold_archive so an operator/auditor can point it at ANY
# cold-archive directory (e.g. an off-box backup copy, or the live box's archive
# dir) and prove every sealed tarball still re-verifies with nothing but the public
# key — turning the CI-only verifier into a shippable, read-only audit command. It
# NEVER restores/unpacks into a live store; it only reads + verifies.
def _derive_sealed_buckets(cold):
    """Sealed buckets = every <name>.manifest.json that also has a <name>.tar.gz
    (the archived.json ledger has no tarball, so it is naturally excluded)."""
    import glob
    out = []
    for p in sorted(glob.glob(os.path.join(cold, "*.manifest.json"))):
        name = os.path.basename(p)[:-len(".manifest.json")]
        if os.path.exists(os.path.join(cold, f"{name}.tar.gz")):
            out.append(name)
    return sorted(out)


def _load_pubkey_raw(pubkey_path=None, pubkey_hex=None):
    """Raw 32-byte Ed25519 public key from either a 64-hex string or a PEM file
    (the PEM may be the public key OR a private key — only its public half is used)."""
    if pubkey_hex:
        raw = bytes.fromhex(pubkey_hex.strip())
        if len(raw) != 32:
            raise SystemExit("::error::--pubkey-hex must be 32 bytes (64 hex chars)")
        return raw
    from cryptography.hazmat.primitives.serialization import (
        load_pem_public_key, load_pem_private_key, Encoding, PublicFormat)
    with open(pubkey_path, "rb") as f:
        data = f.read()
    try:
        pub = load_pem_public_key(data)
    except Exception:
        pub = load_pem_private_key(data, password=None).public_key()
    return pub.public_bytes(Encoding.Raw, PublicFormat.Raw)


def _cli_verify_cold(argv):
    import argparse
    ap = argparse.ArgumentParser(
        prog="receipts_sharding_guard.py verify-cold",
        description="Offline, public-key-only re-verification of a cold-archive "
                    "directory of sealed receipt tarballs (+ sidecar manifests). "
                    "Read-only; exits non-zero if ANY sealed bucket fails to "
                    "re-verify. Does NOT restore into a live store.")
    ap.add_argument("cold_dir",
                    help="directory holding <bucket>.tar.gz + <bucket>.manifest.json "
                         "(e.g. an off-box backup copy of cold storage)")
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--pubkey", help="path to the Ed25519 PEM (public OR private key)")
    g.add_argument("--pubkey-hex",
                   help="raw 32-byte Ed25519 public key as 64 hex chars")
    ap.add_argument("--tail-first-prev", default=None, metavar="HEX",
                    help="the live store tail's first-receipt prev_hash. When given, "
                         "also proves the cold segments re-attach to the surviving "
                         "live store. Omit to verify cold integrity + GENESIS/"
                         "inter-bucket stitch only (re-attachment reported UNCHECKED).")
    args = ap.parse_args(argv)

    cold = args.cold_dir
    if not os.path.isdir(cold):
        print(f"::error::cold dir not found: {cold}")
        return 1
    sealed = _derive_sealed_buckets(cold)
    if not sealed:
        print(f"::error::no <bucket>.tar.gz + <bucket>.manifest.json pairs found "
              f"in {cold}")
        return 1
    pub = _load_pubkey_raw(args.pubkey, args.pubkey_hex)
    tail = args.tail_first_prev
    print(f"verify-cold: {len(sealed)} sealed bucket(s) under {cold}: {sealed}")
    if tail is None:
        print("verify-cold: NOTE — no --tail-first-prev given; re-attachment to the "
              "live tail is UNCHECKED (cold integrity + GENESIS/inter-bucket stitch "
              "are still fully verified).")
    fails = verify_cold_archive(cold, sealed, pub, tail)
    if fails:
        print(f"::error::verify-cold FAILED: {fails} check(s) did not verify in {cold}")
        return 1
    tail_note = (" and re-attaches to the live tail." if tail else
                 " (live-tail re-attachment not checked).")
    print(f"verify-cold PASSED: every sealed bucket under {cold} re-verifies offline "
          f"with the public key alone" + tail_note)
    return 0


# ── build a real, signed, multi-bucket store via the running server ───────────────
def _seed_signed_store(store, key, shard_size, n, port=8138):
    env = dict(os.environ)
    env.update({
        "SZL_RECEIPT_STORE": store,
        "SZL_ED25519_KEY_PATH": key,
        "SZL_RECEIPT_SHARD_SIZE": str(shard_size),
        "SZL_PORT": str(port),
        # Disable the production anti-flood ingest limiter for THIS test server
        # only: its default token bucket (1/sec) would 429 the synthetic burst
        # long before N receipts land. Orthogonal to the sharding property under
        # test; the production default is unchanged.
        "SZL_INGEST_RATE_LIMIT": "0",
    })
    logpath = os.path.join(os.path.dirname(key), "seed-server.log")
    logf = open(logpath, "w")
    proc = subprocess.Popen([sys.executable, SERVER_PATH], env=env,
                            stdout=logf, stderr=subprocess.STDOUT)
    try:
        if not _wait_health(port):
            logf.flush()
            print(open(logpath).read())
            raise SystemExit("::error::receipts server never became healthy")
        # A server that boots unsigned would accept receipts but never sign them;
        # _post_receipt already hard-fails on valid != true, but assert the key
        # path produced a signing server explicitly for a clearer message.
        with urllib.request.urlopen(f"http://127.0.0.1:{port}/pubkey",
                                    timeout=10) as r:
            pk = json.loads(r.read().decode())
        if not pk.get("signed") or not pk.get("public_key_b64u"):
            logf.flush()
            print(open(logpath).read())
            raise SystemExit("::error::seed server booted UNSIGNED — cannot sign "
                             "receipts for the sharding guard")
        for i in range(n):
            _post_receipt(port, f"shard-guard-{i}")
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=10)
        except Exception:
            proc.kill()
        logf.close()


def main():
    shard_size = int(os.environ.get("GUARD_SHARD_SIZE", "5"))
    n = int(os.environ.get("GUARD_RECEIPTS", "17"))
    if shard_size < 1:
        print("::error::GUARD_SHARD_SIZE must be >= 1")
        return 1
    # Need at least 2 sealed buckets + a partial tail to make the assertions
    # meaningful (sealed-vs-tail boundary, multiple buckets archived).
    if n <= 2 * shard_size:
        print(f"::error::test misconfigured: GUARD_RECEIPTS ({n}) must be > "
              f"2*GUARD_SHARD_SIZE ({2 * shard_size}) so several buckets seal "
              f"while a partial tail remains")
        return 1

    last_index = n - 1
    tail_bucket = f"{last_index // shard_size:08d}"
    sealed_expected = sorted({f"{i // shard_size:08d}" for i in range(n)}
                             - {tail_bucket})
    # The tail bucket is partially filled iff n is not a multiple of shard_size;
    # the misconfig guard above lets a full final bucket through too, but our
    # default (17 / 5) gives a 2-receipt tail.
    print(f"Receipts sharding guard: N={n} signed receipts, SHARD_SIZE={shard_size}\n"
          f"  expected sealed buckets={sealed_expected}  tail bucket={tail_bucket}")

    work = tempfile.mkdtemp(prefix="szl-shard-guard-")
    key = os.path.join(work, "ed25519.pem")
    _gen_key(key)
    store = os.path.join(work, "store")
    os.makedirs(store)

    fails = 0
    try:
        t0 = time.time()
        _seed_signed_store(store, key, shard_size, n)
        print(f"\nSeeded {n} signed receipts in {time.time() - t0:.1f}s")

        # The destructive phases each get an independent copy of the pristine,
        # freshly-signed store (the .chain_head head pointer is copied too, so
        # archive-shards knows the tail).
        store_a = store
        store_b = os.path.join(work, "store_b")
        store_c = os.path.join(work, "store_c")
        store_d = os.path.join(work, "store_d")
        store_e = os.path.join(work, "store_e")
        store_e2 = os.path.join(work, "store_e2")
        store_e3 = os.path.join(work, "store_e3")
        store_e4 = os.path.join(work, "store_e4")
        store_f = os.path.join(work, "store_f")
        shutil.copytree(store, store_b)
        shutil.copytree(store, store_c)
        shutil.copytree(store, store_d)
        shutil.copytree(store, store_e)
        shutil.copytree(store, store_e2)
        shutil.copytree(store, store_e3)
        shutil.copytree(store, store_e4)
        shutil.copytree(store, store_f)

        # ── PHASE A: sharding layout + verify-store + archive-shards ─────────────
        print("\n== PHASE A: sharding write path + verify-store + archive-shards ==")
        got_buckets = _bucket_names(store_a)
        all_expected = sorted(sealed_expected + [tail_bucket])
        fails += _assert(got_buckets == all_expected,
                         f"receipts sharded across the expected buckets "
                         f"({got_buckets} == {all_expected})")
        # tail bucket holds the partial remainder; sealed buckets are full.
        tail_count = len([e for e in os.scandir(_bucket_dir(store_a, tail_bucket))
                          if e.name.endswith(".json")])
        fails += _assert(tail_count == n - len(sealed_expected) * shard_size,
                         f"tail bucket holds the partial remainder "
                         f"({tail_count} receipts)")

        rc, rep = _cli(store_a, key, shard_size, ["verify-store"])
        print(f"  verify-store: total={rep['total']} valid={rep['valid']} "
              f"chain_ok={rep['chain_ok']} groups={rep['groups']}")
        fails += _assert(rc == 0, "verify-store CLI exit 0 on a clean store")
        fails += _assert(rep["total"] == n, f"verify-store saw all {n} receipts")
        fails += _assert(rep["valid"] == n, f"verify-store: all {n} valid")
        fails += _assert(rep["chain_ok"] is True, "verify-store: chain_ok=true")

        cold = os.path.join(work, "cold")
        rc, rep = _cli(store_a, key, shard_size,
                       ["archive-shards", "--delete"], cold_dir=cold)
        print(f"  archive-shards: archived={rep.get('archived')} "
              f"tail_bucket={rep.get('tail_bucket')} "
              f"skipped={rep.get('skipped_failed_verify')}")
        fails += _assert(rc == 0, "archive-shards CLI exit 0 (nothing skipped)")
        fails += _assert(sorted(rep.get("archived", [])) == sealed_expected,
                         f"archived ONLY the sealed buckets "
                         f"({sorted(rep.get('archived', []))} == {sealed_expected})")
        fails += _assert(rep.get("tail_bucket") == tail_bucket,
                         f"reported tail bucket is the head's bucket ({tail_bucket})")
        fails += _assert(rep.get("skipped_failed_verify") == [],
                         "no clean bucket was skipped")
        # tail preserved on the live store, sealed buckets removed.
        live_after = _bucket_names(store_a)
        fails += _assert(live_after == [tail_bucket],
                         f"only the tail bucket remains live after --delete "
                         f"({live_after} == [{tail_bucket!r}])")
        # cold storage carries a tarball + manifest per sealed bucket + ledger.
        for b in sealed_expected:
            fails += _assert(os.path.exists(os.path.join(cold, f"{b}.tar.gz")),
                             f"cold tarball present for sealed bucket {b}")
            fails += _assert(
                os.path.exists(os.path.join(cold, f"{b}.manifest.json")),
                f"cold manifest present for sealed bucket {b}")
        fails += _assert(os.path.exists(os.path.join(cold, "archived.json")),
                         "cold archived.json ledger written")

        # manifest CONTENT, not just presence: the boundary hashes a manifest
        # records (first_prev_hash / last_hash) are the ONLY thing that lets an
        # auditor re-stitch a cold-archived bucket back into the live chain. Prove
        # they are real hashes and that they actually link bucket→bucket→live-tail.
        manifests = {b: _read_json(os.path.join(cold, f"{b}.manifest.json"))
                     for b in sealed_expected}
        for b in sealed_expected:
            mf = manifests[b]
            fails += _assert(mf.get("count") == shard_size,
                             f"manifest[{b}] count == shard_size "
                             f"({mf.get('count')} == {shard_size})")
            fails += _assert(_is_hex64(mf.get("last_hash")),
                             f"manifest[{b}] last_hash is a real 64-hex chain hash "
                             f"({mf.get('last_hash')!r})")
            fp = mf.get("first_prev_hash")
            fails += _assert(_is_hex64(fp) or fp == GENESIS,
                             f"manifest[{b}] first_prev_hash is a real link "
                             f"({fp!r})")
        # the LOWEST sealed bucket links back to GENESIS (chain root)…
        fails += _assert(manifests[sealed_expected[0]].get("first_prev_hash") == GENESIS,
                         "lowest sealed bucket's manifest first_prev_hash == GENESIS")
        # …consecutive sealed buckets stitch (this bucket's last_hash is the next
        #   bucket's first_prev_hash)…
        for i in range(len(sealed_expected) - 1):
            cur, nxt = sealed_expected[i], sealed_expected[i + 1]
            fails += _assert(
                manifests[cur].get("last_hash") == manifests[nxt].get("first_prev_hash"),
                f"manifest chain stitches: {cur}.last_hash == {nxt}.first_prev_hash")
        # …and the LAST cold bucket stitches into the LIVE tail bucket's first
        #   receipt, so cold storage can be re-attached to what's still on disk.
        tail_first_prev = (_receipts_in_bucket(store_a, tail_bucket)[0]
                           .get("chain", {}).get("prev_hash"))
        fails += _assert(
            manifests[sealed_expected[-1]].get("last_hash") == tail_first_prev,
            "last cold bucket's last_hash == live tail's first prev_hash "
            "(cold↔live chain continuity preserved)")

        # post-archive verify-store over what remains live still passes.
        rc, rep = _cli(store_a, key, shard_size, ["verify-store"])
        print(f"  post-archive verify-store: total={rep['total']} "
              f"valid={rep['valid']} chain_ok={rep['chain_ok']}")
        fails += _assert(rc == 0 and rep["chain_ok"] is True,
                         "post-archive verify-store still passes over live receipts")
        fails += _assert(rep["valid"] == rep["total"] == tail_count,
                         f"post-archive live store = the tail bucket only "
                         f"({rep['total']} receipts)")

        # ── PHASE A2: COLD-archived tarballs re-verify offline + re-stitch ───────
        # verify-store above only audits the LIVE store. Re-open every cold tarball
        # and prove each sealed bucket is STILL a valid, verifiable chain segment on
        # its own — with nothing but the public key + manifest — and that the cold
        # segments re-stitch GENESIS -> ... -> the surviving live tail. Verification
        # is independent of server.py (cryptography lib here), so a regression in the
        # server's own verifier cannot make this pass hollowly.
        print("\n== PHASE A2: cold-archived tarballs re-verify offline + re-stitch ==")
        pub = _public_key_raw_from_pem(key)
        # The cold-archive verifier proper now lives in a standalone, self-testable
        # function (verify_cold_archive); a negative-fixture self-test
        # (scripts/receipts_sharding_guard.test.py) proves it FAILS on crafted-bad
        # archives so this happy-path call can't go hollow. Per-bucket count ==
        # shard_size is already asserted in PHASE A above.
        tail_first_prev = (_receipts_in_bucket(store_a, tail_bucket)[0]
                           .get("chain", {}).get("prev_hash"))
        fails += verify_cold_archive(cold, sealed_expected, pub, tail_first_prev)

        # (5) the offline cold verifier is NOT a hollow always-pass: a single
        #     flipped payload byte in a cold receipt must break BOTH its signature
        #     and its chain hash when re-verified here.
        recs0, tmp0 = _extract_cold_bucket(
            os.path.join(cold, f"{sealed_expected[0]}.tar.gz"), sealed_expected[0])
        try:
            import base64 as _b64
            victim = recs0[0]
            raw = bytearray(_b64.b64decode(victim["envelope"]["payload"]))
            raw[0] ^= 0x01
            victim["envelope"]["payload"] = _b64.b64encode(bytes(raw)).decode()
            fails += _assert(not _verify_receipt_sig(victim, pub),
                             "offline cold verifier REJECTS a flipped-byte receipt "
                             "(signature no longer verifies — not an always-pass)")
            fails += _assert(
                _chain_hash(victim) != victim.get("chain", {}).get("hash"),
                "flipping a cold receipt's payload breaks its chain hash too")
        finally:
            shutil.rmtree(tmp0, ignore_errors=True)

        # ── PHASE B: verify-store actually catches tampering ─────────────────────
        print("\n== PHASE B: a tampered receipt flips chain_ok to false ==")
        victim_bucket = sealed_expected[0]
        victim = _first_receipt_in(store_b, victim_bucket)
        _tamper_receipt(victim)
        rc, rep = _cli(store_b, key, shard_size, ["verify-store"])
        print(f"  verify-store(tampered): chain_ok={rep['chain_ok']} "
              f"bad_sig={rep['bad_sig']} bad_hash={rep['bad_hash']} "
              f"bad_link={rep['bad_link']} tampered_sample={rep['tampered_sample']}")
        fails += _assert(rep["chain_ok"] is False,
                         "verify-store flips chain_ok to false on a flipped byte")
        fails += _assert(rc == 1, "verify-store CLI exits non-zero on tamper")
        fails += _assert(len(rep["tampered_sample"]) >= 1,
                         "verify-store names the tampered receipt(s)")
        fails += _assert(rep["bad_sig"] >= 1 and rep["bad_hash"] >= 1,
                         "tamper breaks BOTH the signature and the stored hash")

        # ── PHASE C: archival refuses to seal a bucket that fails verification ───
        print("\n== PHASE C: archive-shards REFUSES to seal a failed bucket ==")
        bad_bucket = sealed_expected[0]
        good_buckets = sealed_expected[1:]
        _tamper_receipt(_first_receipt_in(store_c, bad_bucket))
        cold_c = os.path.join(work, "cold_c")
        rc, rep = _cli(store_c, key, shard_size,
                       ["archive-shards", "--delete"], cold_dir=cold_c)
        print(f"  archive-shards(tampered sealed bucket): "
              f"archived={rep.get('archived')} "
              f"skipped={rep.get('skipped_failed_verify')}")
        fails += _assert(bad_bucket in rep.get("skipped_failed_verify", []),
                         f"failed bucket {bad_bucket} listed under "
                         f"skipped_failed_verify")
        fails += _assert(bad_bucket not in rep.get("archived", []),
                         f"failed bucket {bad_bucket} was NOT archived")
        fails += _assert(rc == 1,
                         "archive-shards CLI exits non-zero when a bucket is skipped")
        # the failed bucket must survive on the live store (not deleted -> no loss
        # and no laundering of a tampered shard into cold storage).
        fails += _assert(os.path.isdir(_bucket_dir(store_c, bad_bucket)),
                         f"failed bucket {bad_bucket} still on the live store "
                         f"(not deleted)")
        fails += _assert(not os.path.exists(os.path.join(cold_c, f"{bad_bucket}.tar.gz")),
                         f"no cold tarball was written for the failed bucket "
                         f"{bad_bucket}")
        # the OTHER clean sealed buckets still archive normally.
        fails += _assert(sorted(rep.get("archived", [])) == good_buckets,
                         f"clean sealed buckets still archived "
                         f"({sorted(rep.get('archived', []))} == {good_buckets})")

        # ── PHASE D: legacy flat-root receipts are STILL READ after archival ─────
        # Pre-sharding stores wrote every receipt as a flat file in the store ROOT.
        # The store iterator reads those legacy flat files IN ADDITION to the shard
        # buckets; a refactor that only ever walked shards/ would silently stop
        # auditing the oldest receipts. Simulate the migration case: move the
        # OLDEST sealed bucket's receipts up into the flat root (as legacy files),
        # leave the rest sharded, and prove the additive read survives an archival
        # --delete run that sweeps the still-sharded sealed buckets to cold storage.
        print("\n== PHASE D: legacy flat-root additive read survives archival ==")
        legacy_bucket = sealed_expected[0]
        legacy_dir = _bucket_dir(store_d, legacy_bucket)
        legacy_files = [e.path for e in os.scandir(legacy_dir)
                        if e.is_file() and e.name.endswith(".json")]
        for p in legacy_files:
            shutil.move(p, os.path.join(store_d, os.path.basename(p)))
        os.rmdir(legacy_dir)
        legacy_count = len(legacy_files)
        # the legacy bucket is no longer a shard; the rest stay sealed below the tail.
        still_sealed = sealed_expected[1:]

        # additive read with shards present: legacy flat root + shard buckets verify
        # as ONE continuous chain.
        rc, rep = _cli(store_d, key, shard_size, ["verify-store"])
        print(f"  pre-archive verify-store (legacy root + shards): "
              f"total={rep['total']} valid={rep['valid']} chain_ok={rep['chain_ok']} "
              f"groups={rep['groups']}")
        fails += _assert(rc == 0 and rep["chain_ok"] is True,
                         "legacy flat-root + shards verify as one continuous chain")
        fails += _assert(rep["total"] == n and rep["valid"] == n,
                         f"all {n} receipts read across legacy root + shards "
                         f"(total={rep['total']} valid={rep['valid']})")

        cold_d = os.path.join(work, "cold_d")
        rc, rep = _cli(store_d, key, shard_size,
                       ["archive-shards", "--delete"], cold_dir=cold_d)
        print(f"  archive-shards: archived={rep.get('archived')} "
              f"skipped={rep.get('skipped_failed_verify')}")
        fails += _assert(sorted(rep.get("archived", [])) == still_sealed,
                         f"archival sealed only the shard buckets, not the flat root "
                         f"({sorted(rep.get('archived', []))} == {still_sealed})")
        fails += _assert(legacy_bucket not in rep.get("archived", []),
                         "legacy flat root was NOT swept into cold storage")

        # the legacy flat files are untouched on the live store after --delete…
        live_legacy = [e.name for e in os.scandir(store_d)
                       if e.is_file() and e.name.endswith(".json")]
        fails += _assert(len(live_legacy) == legacy_count,
                         f"legacy flat-root files survive archival --delete "
                         f"({len(live_legacy)} == {legacy_count})")
        # …and the store iterator STILL enumerates them: verify-store reads the
        #   flat-root receipts after archival. A regression that dropped legacy-root
        #   reads would report total == the tail count alone (the legacy chunk gone
        #   dark) and this fails loudly.
        rc, rep = _cli(store_d, key, shard_size, ["verify-store"])
        tail_only = n - len(sealed_expected) * shard_size
        print(f"  post-archive verify-store: total={rep['total']} valid={rep['valid']} "
              f"bad_sig={rep['bad_sig']} bad_hash={rep['bad_hash']} "
              f"bad_link={rep['bad_link']} chain_ok={rep['chain_ok']}")
        fails += _assert(rep["total"] == legacy_count + tail_only,
                         f"legacy flat-root receipts STILL read after archival "
                         f"(total {rep['total']} == {legacy_count} legacy + "
                         f"{tail_only} tail)")
        fails += _assert(rep["bad_sig"] == 0 and rep["bad_hash"] == 0,
                         "no surviving receipt corrupted/dropped by archival "
                         "(every read receipt's signature + hash still verify)")
        # Archiving the MIDDLE sealed buckets leaves a deliberate gap between the
        # legacy chunk and the tail, so exactly ONE cross-bucket link is dangling.
        # That single bad_link is expected and is NOT a read regression — the legacy
        # files themselves all still read and verify above.
        fails += _assert(rep["bad_link"] == 1,
                         f"only the one expected legacy↔tail boundary link dangles "
                         f"after archiving the middle buckets ({rep['bad_link']} == 1)")

        # ── PHASE E: archive --delete → restore-shards round-trip ────────────────
        # restore-shards is the committed inverse of archive-shards. It must verify
        # each cold tarball against its manifest (tarball_sha256 + chain linkage)
        # BEFORE unpacking it back under <store>/shards/<bucket>/, refuse on any
        # mismatch, and drop the cold ledger entry so a restored bucket is no longer
        # treated as archived. The headline guarantee: after a full archive --delete
        # then restore, verify-store sees the WHOLE reunited store as one valid chain.
        print("\n== PHASE E: archive --delete → restore-shards round-trip ==")
        tail_only = n - len(sealed_expected) * shard_size

        # E1: full round trip — archive every sealed bucket out (deleting it from the
        #     live store), then restore them all back and re-audit the reunited store.
        cold_e = os.path.join(work, "cold_e")
        rc, rep = _cli(store_e, key, shard_size,
                       ["archive-shards", "--delete"], cold_dir=cold_e)
        fails += _assert(sorted(rep.get("archived", [])) == sealed_expected,
                         f"E1 archive --delete swept every sealed bucket to cold "
                         f"({sorted(rep.get('archived', []))} == {sealed_expected})")
        fails += _assert(_bucket_names(store_e) == [tail_bucket],
                         f"E1 only the tail bucket remains live after archive --delete "
                         f"({_bucket_names(store_e)} == {[tail_bucket]})")
        rc, rep = _cli(store_e, key, shard_size,
                       ["restore-shards"], cold_dir=cold_e)
        print(f"  restore-shards (all): rc={rc} restored={rep.get('restored')} "
              f"failed={rep.get('failed')}")
        fails += _assert(rc == 0 and not rep.get("error"),
                         "E1 restore-shards (all) exits 0 with no error")
        fails += _assert(sorted(rep.get("restored", [])) == sealed_expected
                         and rep.get("failed") == [],
                         f"E1 every archived bucket restored, none failed "
                         f"(restored={sorted(rep.get('restored', []))}, "
                         f"failed={rep.get('failed')})")
        fails += _assert(_bucket_names(store_e) == sealed_expected + [tail_bucket],
                         f"E1 all buckets are live again under shards/ "
                         f"({_bucket_names(store_e)} == "
                         f"{sealed_expected + [tail_bucket]})")
        ledger_e = _read_json(os.path.join(cold_e, "archived.json")) or {}
        fails += _assert(ledger_e.get("archived") == [],
                         f"E1 cold ledger is emptied so restored buckets are no longer "
                         f"treated as archived (archived={ledger_e.get('archived')})")
        leftover_tars = [f for f in os.listdir(cold_e) if f.endswith(".tar.gz")]
        fails += _assert(leftover_tars == [],
                         f"E1 restored cold tarballs are removed ({leftover_tars})")
        rc, rep = _cli(store_e, key, shard_size, ["verify-store"])
        print(f"  reunited verify-store: total={rep['total']} valid={rep['valid']} "
              f"bad_sig={rep['bad_sig']} bad_hash={rep['bad_hash']} "
              f"bad_link={rep['bad_link']} chain_ok={rep['chain_ok']}")
        fails += _assert(rc == 0 and rep["chain_ok"] is True,
                         "E1 verify-store passes over the FULL reunited store")
        fails += _assert(rep["total"] == n and rep["valid"] == n,
                         f"E1 all {n} receipts present + valid after round trip "
                         f"(total={rep['total']} valid={rep['valid']})")

        # E2: a single named bucket can be restored; the others stay archived.
        cold_e2 = os.path.join(work, "cold_e2")
        _cli(store_e2, key, shard_size,
             ["archive-shards", "--delete"], cold_dir=cold_e2)
        one = sealed_expected[1]
        rc, rep = _cli(store_e2, key, shard_size,
                       ["restore-shards", "--bucket", one], cold_dir=cold_e2)
        print(f"  restore --bucket {one}: rc={rc} restored={rep.get('restored')}")
        fails += _assert(rc == 0 and rep.get("restored") == [one],
                         f"E2 restore --bucket restores only the named bucket "
                         f"(restored={rep.get('restored')})")
        fails += _assert(one in _bucket_names(store_e2),
                         f"E2 the named bucket is live again ({one})")
        ledger_e2 = _read_json(os.path.join(cold_e2, "archived.json")) or {}
        still_cold = sorted(e["bucket"] for e in ledger_e2.get("archived", []))
        fails += _assert(still_cold == [b for b in sealed_expected if b != one],
                         f"E2 the other buckets stay archived in the ledger "
                         f"({still_cold})")

        # E3: a corrupted cold tarball is REFUSED — sha256 mismatch must block the
        #     restore, leave the bucket out of the live store, and keep the ledger
        #     entry + tarball intact (no silent data loss).
        cold_e3 = os.path.join(work, "cold_e3")
        _cli(store_e3, key, shard_size,
             ["archive-shards", "--delete"], cold_dir=cold_e3)
        bad = sealed_expected[0]
        with open(os.path.join(cold_e3, f"{bad}.tar.gz"), "ab") as fh:
            fh.write(b"corrupting-trailer")
        rc, rep = _cli(store_e3, key, shard_size,
                       ["restore-shards", "--bucket", bad], cold_dir=cold_e3)
        print(f"  restore corrupt {bad}: rc={rc} restored={rep.get('restored')} "
              f"failed={rep.get('failed')}")
        fails += _assert(rc == 1 and rep.get("failed") == [bad]
                         and rep.get("restored") == [],
                         f"E3 a tarball_sha256 mismatch is refused "
                         f"(rc={rc} failed={rep.get('failed')})")
        fails += _assert(bad not in _bucket_names(store_e3),
                         f"E3 the corrupt bucket is NOT placed into the live store "
                         f"({_bucket_names(store_e3)})")
        ledger_e3 = _read_json(os.path.join(cold_e3, "archived.json")) or {}
        fails += _assert(
            any(e["bucket"] == bad for e in ledger_e3.get("archived", [])),
            "E3 the refused bucket's cold ledger entry is retained")
        fails += _assert(os.path.exists(os.path.join(cold_e3, f"{bad}.tar.gz")),
                         "E3 the refused (corrupt) cold tarball is NOT deleted")

        # E4: restore must REFUSE to clobber a bucket that is already live. Archive
        #     WITHOUT --delete so the bucket exists both live and in cold, then prove
        #     restore-shards declines rather than overwriting live receipts.
        cold_e4 = os.path.join(work, "cold_e4")
        _cli(store_e4, key, shard_size, ["archive-shards"], cold_dir=cold_e4)
        live_bucket = sealed_expected[0]
        rc, rep = _cli(store_e4, key, shard_size,
                       ["restore-shards", "--bucket", live_bucket], cold_dir=cold_e4)
        print(f"  restore onto live {live_bucket}: rc={rc} failed={rep.get('failed')}")
        fails += _assert(rc == 1 and rep.get("failed") == [live_bucket]
                         and rep.get("restored") == [],
                         f"E4 restore refuses to clobber an already-live bucket "
                         f"(rc={rc} failed={rep.get('failed')})")

        # ── PHASE F: cold-storage offload OFF the data volume round-trips ─────────
        # PHASE E proved archive→restore from the SAME cold dir, but the box
        # retention job (box-scripts/sbin/szl-receipts-retention) does more: after
        # archive-shards --delete, it lifts every cold tarball+manifest OFF the
        # receipts PVC onto a separate host volume, BYTE-STREAMED via
        # `kubectl exec -- cat` (the slim image has no `tar`, so `kubectl cp` is out),
        # sha256-verifies the streamed-out copy against the bucket manifest, and only
        # then prunes the in-pod copy so the live PVC stays bounded. NOTHING in CI
        # exercised that stream-out-then-prune-then-reimport path — exactly where the
        # retention job's real behaviour lives. Simulate it end to end with stdlib
        # only and prove the offloaded archive still round-trips to a verifiable
        # shard (bad_sig==0, bad_hash==0).
        print("\n== PHASE F: cold offload OFF the data volume (stream-out) round-trips ==")
        # cold_f = the in-pod cold dir on the receipts PVC; host_f = the off-PVC
        # full-history volume on the box. archive --delete first, so cold_f holds the
        # sealed tarballs+manifests+ledger and only the tail bucket is live.
        cold_f = os.path.join(work, "cold_f")          # on the "PVC"
        host_f = os.path.join(work, "host_cold_f")     # off the "PVC", on the "box"
        os.makedirs(host_f, exist_ok=True)
        rc, rep = _cli(store_f, key, shard_size,
                       ["archive-shards", "--delete"], cold_dir=cold_f)
        archived_f = sorted(rep.get("archived", []))
        fails += _assert(archived_f == sealed_expected,
                         f"F archive --delete swept every sealed bucket to cold "
                         f"({archived_f} == {sealed_expected})")
        fails += _assert(_bucket_names(store_f) == [tail_bucket],
                         f"F only the tail bucket remains live after archive --delete "
                         f"({_bucket_names(store_f)} == {[tail_bucket]})")

        # F1: stream every cold tarball+manifest OFF the PVC (stdlib bytes, no tar
        #     binary), sha256-verify the streamed-out copy against the manifest
        #     (the exact gate the retention job applies), then PRUNE the in-pod copy.
        for b in sealed_expected:
            pod_tar = os.path.join(cold_f, f"{b}.tar.gz")
            pod_man = os.path.join(cold_f, f"{b}.manifest.json")
            host_tar = _stream_out(pod_tar, os.path.join(host_f, f"{b}.tar.gz"))
            _stream_out(pod_man, os.path.join(host_f, f"{b}.manifest.json"))
            want = _read_json(os.path.join(host_f, f"{b}.manifest.json")) \
                .get("tarball_sha256")
            fails += _assert(_is_hex64(want),
                             f"F manifest[{b}] records a real tarball_sha256")
            fails += _assert(_sha256_file(host_tar) == want,
                             f"F streamed-out tarball[{b}] sha256 matches the manifest "
                             f"(byte-faithful offload off the PVC, no corruption)")
            # Prune the in-pod copy (PRUNE_AFTER_OFFLOAD=1) so the live PVC is bounded.
            os.remove(pod_tar)
            os.remove(pod_man)
        leftover_pod = [f for f in os.listdir(cold_f) if f.endswith(".tar.gz")]
        fails += _assert(leftover_pod == [],
                         f"F in-pod cold tarballs pruned after offload — PVC bounded "
                         f"({leftover_pod})")
        # With the in-pod copies gone, restore CANNOT proceed from the PVC: the
        # archive now lives ONLY on the off-PVC host volume (proves the offload, not
        # a mere second copy left on the PVC).
        rc, rep = _cli(store_f, key, shard_size, ["restore-shards"], cold_dir=cold_f)
        fails += _assert(rc == 1 and sorted(rep.get("failed", [])) == sealed_expected
                         and rep.get("restored") == [],
                         f"F restore from the emptied PVC cold dir fails (tarballs are "
                         f"offloaded to the host volume) "
                         f"(rc={rc} failed={sorted(rep.get('failed', []))})")

        # F2: re-import from the OFF-PVC host volume — stream the tarball+manifest
        #     back onto the PVC cold dir (again stdlib bytes, no tar binary), restore,
        #     and prove the offloaded archive round-trips to a verifiable shard.
        for b in sealed_expected:
            _stream_out(os.path.join(host_f, f"{b}.tar.gz"),
                        os.path.join(cold_f, f"{b}.tar.gz"))
            _stream_out(os.path.join(host_f, f"{b}.manifest.json"),
                        os.path.join(cold_f, f"{b}.manifest.json"))
        rc, rep = _cli(store_f, key, shard_size, ["restore-shards"], cold_dir=cold_f)
        print(f"  restore from re-imported off-PVC archive: rc={rc} "
              f"restored={rep.get('restored')} failed={rep.get('failed')}")
        fails += _assert(rc == 0 and sorted(rep.get("restored", [])) == sealed_expected
                         and rep.get("failed") == [],
                         f"F every offloaded bucket re-imports from the host volume "
                         f"(restored={sorted(rep.get('restored', []))}, "
                         f"failed={rep.get('failed')})")
        fails += _assert(_bucket_names(store_f) == sealed_expected + [tail_bucket],
                         f"F all buckets are live again under shards/ after re-import "
                         f"({_bucket_names(store_f)} == "
                         f"{sealed_expected + [tail_bucket]})")
        rc, rep = _cli(store_f, key, shard_size, ["verify-store"])
        print(f"  post-offload-roundtrip verify-store: total={rep['total']} "
              f"valid={rep['valid']} bad_sig={rep['bad_sig']} "
              f"bad_hash={rep['bad_hash']} chain_ok={rep['chain_ok']}")
        fails += _assert(rep["bad_sig"] == 0 and rep["bad_hash"] == 0,
                         f"F the offloaded-then-reimported store is verifiable "
                         f"(bad_sig={rep['bad_sig']} bad_hash={rep['bad_hash']})")
        fails += _assert(rc == 0 and rep["chain_ok"] is True
                         and rep["total"] == n and rep["valid"] == n,
                         f"F verify-store passes over the FULL store after the cold "
                         f"offload round trip (total={rep['total']} valid={rep['valid']} "
                         f"chain_ok={rep['chain_ok']})")
    finally:
        shutil.rmtree(work, ignore_errors=True)

    print()
    if fails:
        print(f"::error::receipts sharding guard FAILED ({fails} assertion(s)). "
              f"The shard write path, verify-store audit, or archive-shards rollup "
              f"no longer keeps the receipt chain valid/verifiable.")
        return 1
    print("Receipts sharding guard PASSED: receipts shard correctly, verify-store "
          "audits the whole store and catches tampering, and archive-shards seals "
          "only verified non-tail buckets while preserving the tail.")
    return 0


if __name__ == "__main__":
    # Default (no args) = run the full CI guard, so the receipts-sharding-guard
    # job's `python3 scripts/receipts_sharding_guard.py` invocation is unchanged.
    # `verify-cold` exposes the same offline verifier as an operator audit command.
    if len(sys.argv) > 1 and sys.argv[1] == "verify-cold":
        sys.exit(_cli_verify_cold(sys.argv[2:]))
    sys.exit(main())
