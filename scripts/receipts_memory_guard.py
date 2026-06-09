#!/usr/bin/env python3
# Copyright 2026 SZL Holdings
# SPDX-License-Identifier: Apache-2.0
#
# receipts_memory_guard.py — Regression guard that the szl-receipts-server boots
# and appends in BOUNDED memory against a LARGE on-disk receipt store.
#
# Why this exists
# ---------------
# The receipts server once held the ENTIRE receipt chain in RAM. As the chain
# grew to hundreds of thousands of receipts the boot rehydrate (and every
# /metrics scrape) loaded the whole store, the process blew past its 512Mi chart
# limit, and the kubelet OOM-killed it (exit 137) into a crashloop. The fix
# (commit 8c399d7) made boot O(1) memory: a tiny .chain_head pointer resumes the
# chain instantly, and only the most-recent MAX_IN_MEMORY receipts are kept in
# RAM; the full history stays on disk for offline verification.
#
# Nothing in CI proves that property holds, so a future refactor could silently
# reintroduce the "load the whole chain into _receipts" OOM. This guard seeds a
# large synthetic store and proves, on BOTH boot paths, that:
#
#   1. the in-memory receipt window is bounded   (len(_receipts) <= MAX_IN_MEMORY)
#   2. the chain index / persisted count are correct (no data loss)
#   3. peak RSS stays WELL under the 512Mi chart limit
#
# It exercises:
#   * the SLOW path  — legacy store with no head pointer → constant-memory
#                      streaming scan that rebuilds the bounded window;
#   * the FAST path  — head pointer present → O(1) resume, empty live window;
#   * the APPEND path — a real running server fast-boots against the large store,
#                      then POSTs a burst of receipts; the live window stays
#                      bounded and the chain length keeps growing correctly.
#
# The in-memory COUNT bound is the deterministic catch: a regression that loads
# the whole chain makes len(_receipts) == N >> MAX_IN_MEMORY and fails here
# regardless of the runner's memory. Peak RSS is the supporting "flat ceiling"
# proof.
#
# Tunables (env):
#   GUARD_RECEIPTS          synthetic store size            (default 20000)
#   GUARD_MAX_IN_MEMORY     SZL_MAX_IN_MEMORY_RECEIPTS      (default 2000)
#   GUARD_APPEND            receipts POSTed in append test  (default 500)
#   GUARD_RSS_CEILING_MIB   peak-RSS ceiling, MiB           (default 256)
#
# No cluster required. Run: python3 scripts/receipts_memory_guard.py

import base64
import importlib.util
import json
import os
import resource
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
SERVER_PATH = os.path.join(REPO, "services", "szl-receipts-server", "server.py")

# 512Mi is the chart's resources.limits.memory for the receipts container; the
# guard proves boot RSS stays a long way under it.
CHART_LIMIT_MIB = 512


def _load_server():
    """Import services/szl-receipts-server/server.py as a module. The module
    reads its config (STORE_PATH, MAX_IN_MEMORY, SHARD_SIZE) from the environment
    at import time, so callers MUST set the env BEFORE invoking this."""
    spec = importlib.util.spec_from_file_location("szl_receipts_server", SERVER_PATH)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def _peak_rss_mib():
    """Peak resident set size of THIS process so far, in MiB. ru_maxrss is in
    kilobytes on Linux."""
    return resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1024.0


# ── child: seed a large faithful store ──────────────────────────────────────────
def _seed_child(store, count):
    """Write `count` faithful receipt files into `store` using the server's own
    sharding + hashing helpers (so the on-disk layout — shard buckets, file
    count, record shape — exactly matches what the server writes). NO head
    pointer is written, so a subsequent boot is forced down the SLOW scan path
    (the legacy-store-upgrade case). created_at increases monotonically so the
    'most recent MAX_IN_MEMORY' window is deterministic."""
    os.environ["SZL_RECEIPT_STORE"] = store
    server = _load_server()

    base = 1_700_000_000  # fixed epoch base; +i seconds keeps created_at ordered
    prev_hash = server.GENESIS
    for i in range(count):
        created = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(base + i))
        # A realistically-sized DSSE-shaped envelope (a few hundred bytes) so the
        # slow scan does real json.load work per file, not toy records.
        payload = base64.b64encode(
            json.dumps({"action": "deploy", "subject": f"synthetic-{i}",
                        "ts": created, "pad": "x" * 160}).encode()
        ).decode()
        envelope = {
            "payloadType": "application/vnd.szl.receipt+json",
            "payload": payload,
            "signatures": [{"keyid": "synthetic", "sig": base64.b64encode(
                (b"s" * 64)).decode()}],
        }
        record = {
            "id": "",
            "created_at": created,
            "timestamp": created,
            "valid": True,
            "envelope": envelope,
            "chain": {"prev_hash": prev_hash, "chain_index": i},
        }
        rid = server.hashlib.sha256(
            json.dumps(envelope, sort_keys=True, separators=(",", ":")).encode()
        ).hexdigest()
        record["id"] = rid
        record["chain"]["hash"] = server._receipt_hash(record)
        prev_hash = record["chain"]["hash"]
        dest = server._store_path_for(rid, i)
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        with open(dest, "w") as f:
            json.dump(record, f)
    print(json.dumps({"seeded": count}))


# ── child: rehydrate once and report bounded-memory metrics ─────────────────────
def _rehydrate_child(store):
    """Boot-equivalent: import the server (which reads the store path from env),
    run _rehydrate(), and emit the post-boot chain state plus this process's peak
    RSS as JSON. Run in its own process so the RSS reading is the clean cost of
    booting against the store — not polluted by the orchestrator."""
    os.environ["SZL_RECEIPT_STORE"] = store
    server = _load_server()
    chain_index = server._rehydrate()
    print(json.dumps({
        "receipts_in_mem": len(server._receipts),
        "chain_index": chain_index,
        "persisted_count": server._persisted_count,
        "max_in_memory": server.MAX_IN_MEMORY,
        "peak_rss_mib": round(_peak_rss_mib(), 1),
        "head_pointer_present": os.path.exists(server.HEAD_FILE),
    }))


# ── orchestrator helpers ────────────────────────────────────────────────────────
def _run_child(mode, store, env_extra=None):
    env = dict(os.environ)
    if env_extra:
        env.update(env_extra)
    out = subprocess.run(
        [sys.executable, os.path.abspath(__file__), mode, store],
        capture_output=True, text=True, env=env,
    )
    if out.returncode != 0:
        print(f"::error::child '{mode}' failed (rc={out.returncode})")
        print(out.stdout)
        print(out.stderr, file=sys.stderr)
        raise SystemExit(1)
    # The child may log to stdout before the JSON; take the last JSON line.
    last = [ln for ln in out.stdout.strip().splitlines() if ln.strip().startswith("{")]
    if not last:
        print(f"::error::child '{mode}' produced no JSON result")
        print(out.stdout)
        raise SystemExit(1)
    return json.loads(last[-1])


def _assert(ok, msg):
    print(f"  {'ok  ' if ok else 'FAIL'} {msg}")
    return ok


def _check_boot(label, m, n, max_in_mem, ceiling, expect_empty_window):
    print(f"\n== {label} ==")
    print(f"  metrics: {m}")
    fails = 0
    if not _assert(m["max_in_memory"] == max_in_mem,
                   f"MAX_IN_MEMORY respected the env ({m['max_in_memory']} == {max_in_mem})"):
        fails += 1
    if not _assert(m["receipts_in_mem"] <= max_in_mem,
                   f"in-memory window bounded ({m['receipts_in_mem']} <= {max_in_mem}) "
                   f"— a whole-chain load would be {n}"):
        fails += 1
    if expect_empty_window and not _assert(
            m["receipts_in_mem"] == 0,
            "fast path starts with an EMPTY live window (O(1) resume)"):
        fails += 1
    if not _assert(m["chain_index"] == n,
                   f"chain_index correct ({m['chain_index']} == {n}) — no data loss"):
        fails += 1
    if not _assert(m["persisted_count"] == n,
                   f"persisted_count correct ({m['persisted_count']} == {n})"):
        fails += 1
    if not _assert(m["peak_rss_mib"] <= ceiling,
                   f"peak RSS {m['peak_rss_mib']} MiB <= {ceiling} MiB ceiling "
                   f"(well under the {CHART_LIMIT_MIB}Mi chart limit)"):
        fails += 1
    return fails


# ── append path: real running server + POST burst ───────────────────────────────
def _wait_health(port, tries=40):
    for _ in range(tries):
        try:
            with urllib.request.urlopen(f"http://127.0.0.1:{port}/health", timeout=1) as r:
                if r.status == 200:
                    return True
        except Exception:
            time.sleep(0.5)
    return False


def _get_json(port, path):
    with urllib.request.urlopen(f"http://127.0.0.1:{port}{path}", timeout=10) as r:
        return json.loads(r.read().decode())


def _get_text(port, path):
    with urllib.request.urlopen(f"http://127.0.0.1:{port}{path}", timeout=10) as r:
        return r.read().decode()


def _vmhwm_mib(pid):
    """Peak RSS (VmHWM) of a running process from /proc, in MiB."""
    try:
        with open(f"/proc/{pid}/status") as f:
            for line in f:
                if line.startswith("VmHWM:"):
                    return int(line.split()[1]) / 1024.0
    except Exception:
        pass
    return None


def _check_append(store, n, append_n, max_in_mem, ceiling):
    print(f"\n== APPEND path (real server fast-boots against {n} receipts, "
          f"POSTs {append_n}) ==")
    keydir = tempfile.mkdtemp(prefix="szl-key-")
    keypath = os.path.join(keydir, "ed25519.pem")
    subprocess.run(["openssl", "genpkey", "-algorithm", "ED25519", "-out", keypath],
                   check=True, capture_output=True)
    port = 8137
    env = dict(os.environ)
    env.update({
        "SZL_RECEIPT_STORE": store,
        "SZL_ED25519_KEY_PATH": keypath,
        "SZL_PORT": str(port),
        "SZL_MAX_IN_MEMORY_RECEIPTS": str(max_in_mem),
    })
    logf = open(os.path.join(keydir, "server.log"), "w")
    proc = subprocess.Popen([sys.executable, SERVER_PATH], env=env,
                            stdout=logf, stderr=subprocess.STDOUT)
    fails = 0
    try:
        if not _wait_health(port):
            print("::error::receipts server never became healthy")
            logf.flush()
            print(open(os.path.join(keydir, "server.log")).read())
            return 1

        for i in range(append_n):
            body = json.dumps({"action": "deploy", "subject": f"append-{i}",
                               "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ")}).encode()
            req = urllib.request.Request(
                f"http://127.0.0.1:{port}/receipt", data=body,
                headers={"Content-Type": "application/json"}, method="POST")
            with urllib.request.urlopen(req, timeout=10) as r:
                if r.status != 200:
                    print(f"::error::POST /receipt returned {r.status}")
                    return 1

        receipts = _get_json(port, "/receipts")
        metrics = _get_text(port, "/metrics")
        chain_len = chain_index = None
        for line in metrics.splitlines():
            if line.startswith("szl_chain_length "):
                chain_len = int(line.split()[1])
            elif line.startswith("szl_chain_index "):
                chain_index = int(line.split()[1])

        expected_total = n + append_n
        print(f"  /receipts in-memory window = {len(receipts)}")
        print(f"  szl_chain_length = {chain_len}  szl_chain_index = {chain_index}  "
              f"(expected {expected_total})")
        hwm = _vmhwm_mib(proc.pid)
        print(f"  server VmHWM = {hwm} MiB")

        if not _assert(len(receipts) <= max_in_mem,
                       f"live window stays bounded after {append_n} appends "
                       f"({len(receipts)} <= {max_in_mem})"):
            fails += 1
        if not _assert(chain_len == expected_total,
                       f"chain length grew correctly ({chain_len} == {expected_total})"):
            fails += 1
        if not _assert(chain_index == expected_total,
                       f"chain index advanced correctly ({chain_index} == {expected_total})"):
            fails += 1
        if hwm is not None and not _assert(
                hwm <= ceiling,
                f"server peak RSS {hwm} MiB <= {ceiling} MiB ceiling "
                f"(well under the {CHART_LIMIT_MIB}Mi chart limit)"):
            fails += 1
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=10)
        except Exception:
            proc.kill()
        logf.close()
        shutil.rmtree(keydir, ignore_errors=True)
    return fails


def main():
    n = int(os.environ.get("GUARD_RECEIPTS", "20000"))
    max_in_mem = int(os.environ.get("GUARD_MAX_IN_MEMORY", "2000"))
    append_n = int(os.environ.get("GUARD_APPEND", "500"))
    ceiling = float(os.environ.get("GUARD_RSS_CEILING_MIB", "256"))

    if max_in_mem >= n:
        print(f"::error::test misconfigured: GUARD_MAX_IN_MEMORY ({max_in_mem}) "
              f"must be < GUARD_RECEIPTS ({n}) for the bound to mean anything")
        return 1
    if ceiling >= CHART_LIMIT_MIB:
        print(f"::error::ceiling {ceiling} MiB is not 'well under' the "
              f"{CHART_LIMIT_MIB}Mi chart limit")
        return 1

    print(f"Receipts memory guard: store={n} receipts, MAX_IN_MEMORY={max_in_mem}, "
          f"append={append_n}, RSS ceiling={ceiling} MiB (chart limit {CHART_LIMIT_MIB}Mi)")

    store = tempfile.mkdtemp(prefix="szl-mem-guard-")
    env_max = {"SZL_MAX_IN_MEMORY_RECEIPTS": str(max_in_mem)}
    total_fail = 0
    try:
        t0 = time.time()
        seeded = _run_child("seed", store, env_max)
        print(f"\nSeeded {seeded['seeded']} receipts in {time.time() - t0:.1f}s "
              f"into {store}")

        # SLOW path — no head pointer yet (legacy store). The scan writes the
        # pointer as a side effect, setting up the fast path below.
        slow = _run_child("rehydrate", store, env_max)
        total_fail += _check_boot("SLOW path (streaming scan, no head pointer)",
                                  slow, n, max_in_mem, ceiling,
                                  expect_empty_window=False)
        if not slow["head_pointer_present"]:
            print("::error::slow scan did not persist the .chain_head pointer")
            total_fail += 1

        # FAST path — head pointer now present → O(1) resume.
        fast = _run_child("rehydrate", store, env_max)
        if not fast["head_pointer_present"]:
            print("::error::fast path expected a head pointer to be present")
            total_fail += 1
        total_fail += _check_boot("FAST path (O(1) head-pointer resume)",
                                  fast, n, max_in_mem, ceiling,
                                  expect_empty_window=True)

        # APPEND path — real server, fast-boots, takes a POST burst.
        total_fail += _check_append(store, n, append_n, max_in_mem, ceiling)
    finally:
        shutil.rmtree(store, ignore_errors=True)

    print()
    if total_fail:
        print(f"::error::receipts memory guard FAILED ({total_fail} assertion(s)). "
              f"Boot/append memory is no longer bounded — the OOM regression may "
              f"have returned.")
        return 1
    print("Receipts memory guard PASSED: boot + append memory stays bounded on "
          "the slow-scan, fast head-pointer, and append paths.")
    return 0


if __name__ == "__main__":
    if len(sys.argv) >= 3 and sys.argv[1] == "seed":
        _seed_child(sys.argv[2], int(os.environ.get("GUARD_RECEIPTS", "20000")))
        sys.exit(0)
    if len(sys.argv) >= 3 and sys.argv[1] == "rehydrate":
        _rehydrate_child(sys.argv[2])
        sys.exit(0)
    sys.exit(main())
