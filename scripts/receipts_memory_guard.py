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
#   3. peak RSS stays WELL under the chart's declared memory limit
#
# It exercises:
#   * the SLOW path  — legacy store with no head pointer → constant-memory
#                      streaming scan that rebuilds the bounded window;
#   * the FAST path  — head pointer present → O(1) resume, empty live window;
#   * the APPEND path — a real running server fast-boots against the large store,
#                      then POSTs a burst of receipts; the live window stays
#                      bounded and the chain length keeps growing correctly.
#   * the HIGH-INDEX FAST-RESUME path — a REAL server process boots against a
#                      .chain_head pointer that CLAIMS a ~300k-receipt chain while
#                      only a few recent tail files physically remain on disk
#                      (mirroring a long-lived store whose older shards were
#                      cold-archived). It proves the process reaches Ready via the
#                      "Rehydrated from head pointer" log line, resumes at the
#                      full claimed chain_index/length, keeps an EMPTY live window
#                      and bounded RSS, and crosses Ready WITHIN A TIME BUDGET —
#                      i.e. boot cost is independent of the (300k) chain length, so
#                      it would NOT have OOM'd / timed out under the old full-load.
#                      The chain_index==claimed assertion is the deterministic
#                      catch: a regression that scanned/loaded the chain would
#                      derive the index from the few on-disk files, never 300k.
#
# The in-memory COUNT bound is the deterministic catch: a regression that loads
# the whole chain makes len(_receipts) == N >> MAX_IN_MEMORY and fails here
# regardless of the runner's memory. Peak RSS is the supporting "flat ceiling"
# proof.
#
# The RSS ceiling is NOT a hardcoded constant: it is derived at runtime from the
# chart's declared receipts-server memory limit (server.resources.limits.memory
# in charts/szl-receipts/values.yaml) times GUARD_RSS_SAFETY_FRACTION. If the
# chart limit is lowered, the ceiling tightens automatically — the guard can
# never keep passing against a stale number. If the chart value can't be read the
# guard FAILS LOUD rather than silently falling back to a default.
#
# Tunables (env):
#   GUARD_RECEIPTS            synthetic store size              (default 20000)
#   GUARD_MAX_IN_MEMORY       SZL_MAX_IN_MEMORY_RECEIPTS        (default 2000)
#   GUARD_APPEND              receipts POSTed in append test    (default 500)
#   GUARD_RSS_SAFETY_FRACTION ceiling = chart limit * fraction  (default 0.5)
#   GUARD_RSS_CEILING_MIB     explicit MiB override (skips the derived default)
#
# No cluster required. Run: python3 scripts/receipts_memory_guard.py

import base64
import importlib.util
import json
import os
import re
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

# The chart whose resources.limits.memory is the production ceiling the guard
# proves boot/append RSS stays under. Parsed at runtime (see _read_chart_limit_mib).
CHART_VALUES = os.path.join(REPO, "charts", "szl-receipts", "values.yaml")

# ceiling = CHART_LIMIT_MIB * SAFETY_FRACTION (a margin below the hard limit, since
# the kubelet OOM-kills AT the limit; we want to catch creep well before that).
SAFETY_FRACTION = float(os.environ.get("GUARD_RSS_SAFETY_FRACTION", "0.5"))

# The chart's resources.limits.memory for the receipts container, in MiB. Read
# from the chart at runtime in main() (NOT at import — the seed/rehydrate child
# subprocesses don't need it, and a read failure must fail loud only in main).
CHART_LIMIT_MIB = None


def _die(msg):
    """Print a GitHub-annotated error and exit non-zero. Used for fail-loud
    conditions that must never degrade into a silent default."""
    print(f"::error::{msg}")
    raise SystemExit(1)


def _parse_mem_to_mib(value):
    """Convert a Kubernetes memory quantity (e.g. '512Mi', '1Gi', '536870912')
    to MiB as a float. Raises ValueError on anything unparseable."""
    s = str(value).strip().strip('"').strip("'")
    m = re.fullmatch(r"(\d+(?:\.\d+)?)\s*([EPTGMK]i?)?", s)
    if not m:
        raise ValueError(f"unparseable memory quantity {value!r}")
    num = float(m.group(1))
    unit = m.group(2) or ""
    factors = {
        "": 1.0 / (1024 * 1024),                      # bytes → MiB
        "Ki": 1.0 / 1024, "Mi": 1.0, "Gi": 1024.0,
        "Ti": 1024.0 ** 2, "Pi": 1024.0 ** 3, "Ei": 1024.0 ** 4,
        "K": 1000.0 / (1024 ** 2), "M": 1000.0 ** 2 / (1024 ** 2),
        "G": 1000.0 ** 3 / (1024 ** 2), "T": 1000.0 ** 4 / (1024 ** 2),
        "P": 1000.0 ** 5 / (1024 ** 2), "E": 1000.0 ** 6 / (1024 ** 2),
    }
    return num * factors[unit]


def _strip_inline(rest):
    """Return the scalar value from the right-hand side of a `key: value` line,
    honoring quotes and dropping an unquoted inline `# comment`."""
    rest = rest.strip()
    if not rest:
        return ""
    if rest[0] in "\"'":
        q = rest[0]
        end = rest.find(q, 1)
        return rest[1:end] if end != -1 else rest[1:]
    return rest.split("#", 1)[0].strip()


def _yaml_scalar_at(path, target_keys):
    """Return the scalar string at a nested key path in a simple YAML file using
    an indentation stack. Returns None if the path is absent. Stdlib-only — the
    memory-guard CI job installs no PyYAML, and the values we need (a single
    nested scalar) don't warrant the dependency."""
    key_re = re.compile(r"^(\s*)([A-Za-z0-9_.\-]+):\s*(.*)$")
    stack = []  # list of (indent, key)
    with open(path) as f:
        for raw in f:
            line = raw.rstrip("\n")
            stripped = line.strip()
            if not stripped or stripped.startswith("#"):
                continue
            m = key_re.match(line)
            if not m:
                continue  # list items / continuations — never on our scalar path
            indent, key, rest = len(m.group(1)), m.group(2), m.group(3)
            while stack and stack[-1][0] >= indent:
                stack.pop()
            stack.append((indent, key))
            if [k for _, k in stack] == target_keys:
                value = _strip_inline(rest)
                return value if value != "" else None
    return None


def _read_chart_limit_mib():
    """Derive the production memory ceiling from the chart's declared
    receipts-server memory limit (server.resources.limits.memory). FAILS LOUD on
    any problem — missing file, missing key, or unparseable quantity — and never
    returns a silent default, so the guard can't keep passing against a stale
    number if the chart limit is lowered or the chart moves."""
    if not os.path.exists(CHART_VALUES):
        _die(f"chart values not found at {CHART_VALUES}; cannot derive the RSS "
             f"ceiling from the receipts-server memory limit")
    raw = _yaml_scalar_at(CHART_VALUES,
                          ["server", "resources", "limits", "memory"])
    if raw is None:
        _die(f"could not find server.resources.limits.memory in {CHART_VALUES}; "
             f"refusing to fall back to a hardcoded ceiling")
    try:
        mib = _parse_mem_to_mib(raw)
    except ValueError as exc:
        _die(f"chart memory limit unreadable ({exc}) in {CHART_VALUES}")
    if mib <= 0:
        _die(f"chart memory limit parsed to {mib} MiB in {CHART_VALUES}")
    return mib


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


# ── child: seed a SMALL tail + a head pointer claiming a HUGE chain ─────────────
def _seed_high_index_child(store, high_index, real_files):
    """Simulate a server that has persisted ~`high_index` receipts (e.g. 300k)
    WITHOUT writing 300k files. Writes only `real_files` faithful TAIL receipts —
    the most-recent ones, chain indices high_index-real_files .. high_index-1, in
    their natural shard buckets — plus a .chain_head pointer that CLAIMS
    chain_index == high_index and count == high_index.

    This mirrors a real long-lived store whose older shards have been
    cold-archived/offloaded (the documented `archive-shards` path) so only recent
    receipts remain on the hot volume while the head pointer still records the
    full chain length. A correct server fast-resumes from the pointer at
    high_index in O(1) time and memory; a regression that scans/loads the chain
    would derive chain_index from the few files on disk (~real_files, never
    high_index) and fail the guard."""
    os.environ["SZL_RECEIPT_STORE"] = store
    server = _load_server()

    base = 1_700_000_000
    start = max(0, high_index - real_files)
    prev_hash = server.GENESIS
    tail_hash = server.GENESIS
    for i in range(start, high_index):
        created = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(base + i))
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
        tail_hash = record["chain"]["hash"]
        dest = server._store_path_for(rid, i)
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        with open(dest, "w") as f:
            json.dump(record, f)
    # The pointer CLAIMS the FULL chain length even though only `real_files`
    # receipts physically remain (older shards cold-archived). count == high_index.
    server._write_head_pointer(high_index, tail_hash, count=high_index)
    print(json.dumps({"seeded_files": high_index - start,
                      "claimed_index": high_index, "claimed_count": high_index}))


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
                   f"(well under the {CHART_LIMIT_MIB:g}Mi chart limit)"):
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
        # This guard measures the BOUNDED-MEMORY property under an append burst,
        # not the production anti-flood ingest limiter. The server's default
        # token bucket (SZL_INGEST_RATE_LIMIT=1.0/sec, burst 60) would shed this
        # synthetic full-speed burst with HTTP 429 well before append_n POSTs
        # land, which is correct production behavior but orthogonal to (and would
        # mask) the memory bound under test. Disable the limiter for THIS test
        # server only so every POST is accepted and the live window / chain
        # growth can be asserted; the production default is unchanged.
        "SZL_INGEST_RATE_LIMIT": "0",
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
                f"(well under the {CHART_LIMIT_MIB:g}Mi chart limit)"):
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


# ── high-index fast-resume: real server boots against a ~300k head pointer ──────
def _check_fast_resume_high_index(store, high_index, ceiling, budget_secs):
    """Boot a REAL server process against a store whose .chain_head claims
    `high_index` (~300k) receipts while only a few tail files physically remain,
    and prove the process reaches Ready FAST and FLAT:
      * the boot log shows the "Rehydrated from head pointer" (fast/O(1)) path;
      * /metrics resumes at the FULL claimed chain_index and chain_length
        (a scan/load of the on-disk files could never yield `high_index`);
      * the live in-memory window starts EMPTY (no history loaded);
      * the process reaches /healthz within a wall-clock time budget — boot cost
        is independent of the claimed chain length;
      * server peak RSS stays under the chart-derived ceiling.
    No signing key needed — the server boots unsigned and this path never POSTs."""
    print(f"\n== HIGH-INDEX FAST RESUME (real server boots against a .chain_head "
          f"claiming {high_index} receipts) ==")
    port = 8138
    env = dict(os.environ)
    env.update({"SZL_RECEIPT_STORE": store, "SZL_PORT": str(port)})
    workdir = tempfile.mkdtemp(prefix="szl-fast-resume-")
    logpath = os.path.join(workdir, "server.log")
    logf = open(logpath, "w")
    fails = 0
    proc = None
    try:
        t0 = time.time()
        proc = subprocess.Popen([sys.executable, SERVER_PATH], env=env,
                                stdout=logf, stderr=subprocess.STDOUT)
        healthy = _wait_health(port)
        boot_secs = time.time() - t0
        logf.flush()
        log_text = open(logpath).read()
        if not healthy:
            print("::error::receipts server never became healthy on the "
                  "high-index store")
            print(log_text)
            return 1

        window = _get_json(port, "/receipts")
        metrics = _get_text(port, "/metrics")
        chain_index = chain_len = None
        for line in metrics.splitlines():
            if line.startswith("szl_chain_index "):
                chain_index = int(line.split()[1])
            elif line.startswith("szl_chain_length "):
                chain_len = int(line.split()[1])
        hwm = _vmhwm_mib(proc.pid)

        print(f"  boot -> ready = {boot_secs:.2f}s (budget {budget_secs:g}s)")
        print(f"  szl_chain_index = {chain_index}  szl_chain_length = {chain_len}  "
              f"(claimed {high_index})")
        print(f"  /receipts window = {len(window)}   server VmHWM = {hwm} MiB")

        if not _assert("Rehydrated from head pointer" in log_text,
                       "boot took the FAST 'Rehydrated from head pointer' path "
                       "(O(1) resume, no store scan)"):
            fails += 1
            for ln in log_text.splitlines():
                if "Rehydrated" in ln:
                    print(f"      boot log says: {ln}")
        if not _assert(chain_index == high_index,
                       f"chain_index resumed from the pointer ({chain_index} == "
                       f"{high_index}) — a scan/load of the on-disk files could "
                       f"never yield {high_index}"):
            fails += 1
        if not _assert(chain_len == high_index,
                       f"chain_length reflects the full claimed history "
                       f"({chain_len} == {high_index})"):
            fails += 1
        if not _assert(len(window) == 0,
                       "live window starts EMPTY (O(1) resume; no history loaded "
                       "into RAM)"):
            fails += 1
        if not _assert(boot_secs <= budget_secs,
                       f"reached Ready within the time budget ({boot_secs:.2f}s "
                       f"<= {budget_secs:g}s) — boot cost is independent of the "
                       f"{high_index}-receipt chain length"):
            fails += 1
        if hwm is not None and not _assert(
                hwm <= ceiling,
                f"server peak RSS {hwm} MiB <= {ceiling} MiB ceiling "
                f"(well under the {CHART_LIMIT_MIB:g}Mi chart limit)"):
            fails += 1
    finally:
        if proc is not None:
            proc.terminate()
            try:
                proc.wait(timeout=10)
            except Exception:
                proc.kill()
        logf.close()
        shutil.rmtree(workdir, ignore_errors=True)
    return fails


def main():
    global CHART_LIMIT_MIB
    # Derive the production ceiling from the chart (fails loud on any problem) so
    # the guard tracks the real limit instead of a stale hardcoded number.
    CHART_LIMIT_MIB = round(_read_chart_limit_mib(), 1)

    n = int(os.environ.get("GUARD_RECEIPTS", "20000"))
    max_in_mem = int(os.environ.get("GUARD_MAX_IN_MEMORY", "2000"))
    append_n = int(os.environ.get("GUARD_APPEND", "500"))

    # Default ceiling = chart limit * safety fraction; an explicit override is
    # still honored for ad-hoc runs but is never the silent default.
    override = os.environ.get("GUARD_RSS_CEILING_MIB")
    if override not in (None, ""):
        ceiling = float(override)
        ceiling_src = "GUARD_RSS_CEILING_MIB override"
    else:
        ceiling = round(CHART_LIMIT_MIB * SAFETY_FRACTION, 1)
        ceiling_src = (f"chart limit {CHART_LIMIT_MIB:g}Mi x "
                       f"{SAFETY_FRACTION:g} safety fraction")

    if max_in_mem >= n:
        print(f"::error::test misconfigured: GUARD_MAX_IN_MEMORY ({max_in_mem}) "
              f"must be < GUARD_RECEIPTS ({n}) for the bound to mean anything")
        return 1
    if ceiling <= 0:
        print(f"::error::derived RSS ceiling {ceiling} MiB is not positive")
        return 1
    if ceiling >= CHART_LIMIT_MIB:
        print(f"::error::ceiling {ceiling} MiB is not 'well under' the "
              f"{CHART_LIMIT_MIB:g}Mi chart limit")
        return 1

    print(f"Receipts memory guard: store={n} receipts, MAX_IN_MEMORY={max_in_mem}, "
          f"append={append_n}, RSS ceiling={ceiling} MiB ({ceiling_src}; "
          f"chart limit {CHART_LIMIT_MIB:g}Mi from {os.path.relpath(CHART_VALUES, REPO)})")

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

    # HIGH-INDEX FAST-RESUME path — a REAL server boots against a .chain_head
    # claiming a ~300k-receipt chain while only a few tail files remain on disk
    # (cold-archived history), and must reach Ready via the fast head-pointer
    # path at the FULL claimed index, with an empty window, bounded RSS, and
    # within a wall-clock time budget. This is the direct large-history boot
    # proof: it would have OOM'd / been slow under the old whole-chain load, and
    # the chain_index==claimed assertion deterministically catches any regression
    # back to a scan (which could only ever derive the small on-disk file count).
    high_index = int(os.environ.get("GUARD_HIGH_INDEX", "300000"))
    high_files = int(os.environ.get("GUARD_HIGH_INDEX_FILES", "50"))
    budget_secs = float(os.environ.get("GUARD_FAST_BOOT_BUDGET_SECS", "20"))
    if high_files >= high_index:
        print(f"::error::test misconfigured: GUARD_HIGH_INDEX_FILES ({high_files}) "
              f"must be < GUARD_HIGH_INDEX ({high_index}) so the pointer claims "
              f"more than the files on disk")
        return 1
    high_store = tempfile.mkdtemp(prefix="szl-mem-guard-hi-")
    try:
        t0 = time.time()
        seeded_hi = _run_child("seed_high", high_store,
                               {"GUARD_HIGH_INDEX": str(high_index),
                                "GUARD_HIGH_INDEX_FILES": str(high_files)})
        print(f"\nSeeded {seeded_hi['seeded_files']} tail receipt file(s) + a "
              f".chain_head claiming {seeded_hi['claimed_index']} receipts in "
              f"{time.time() - t0:.1f}s into {high_store}")
        total_fail += _check_fast_resume_high_index(
            high_store, high_index, ceiling, budget_secs)
    finally:
        shutil.rmtree(high_store, ignore_errors=True)

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
    if len(sys.argv) >= 3 and sys.argv[1] == "seed_high":
        _seed_high_index_child(
            sys.argv[2],
            int(os.environ.get("GUARD_HIGH_INDEX", "300000")),
            int(os.environ.get("GUARD_HIGH_INDEX_FILES", "50")),
        )
        sys.exit(0)
    sys.exit(main())
