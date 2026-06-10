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
#     4. post-archive `verify-store` over what remains live still passes.
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
        shutil.copytree(store, store_b)
        shutil.copytree(store, store_c)

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

        # post-archive verify-store over what remains live still passes.
        rc, rep = _cli(store_a, key, shard_size, ["verify-store"])
        print(f"  post-archive verify-store: total={rep['total']} "
              f"valid={rep['valid']} chain_ok={rep['chain_ok']}")
        fails += _assert(rc == 0 and rep["chain_ok"] is True,
                         "post-archive verify-store still passes over live receipts")
        fails += _assert(rep["valid"] == rep["total"] == tail_count,
                         f"post-archive live store = the tail bucket only "
                         f"({rep['total']} receipts)")

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
    sys.exit(main())
