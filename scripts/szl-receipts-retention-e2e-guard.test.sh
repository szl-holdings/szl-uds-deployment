# Copyright 2026 SZL Holdings
# SPDX-License-Identifier: Apache-2.0
#
# szl-receipts-retention-e2e-guard.test.sh — negative-fixture self-test for
# scripts/szl-receipts-retention-e2e-guard.sh.
#
# A guard that never fails is worthless: it would stay green while the behaviour
# it claims to protect silently rots. This self-test proves the e2e guard has
# TEETH by pointing it (via SERVER_SRC) at deliberately-BROKEN copies of
# server.py and asserting the guard FAILS on each, plus asserting the pristine
# repo PASSES. It runs as the `self-test` job the guard workflow depends on, so a
# future edit that neuters the e2e guard (passing vacuously) is caught before the
# guard can wave a real regression through.
#
# The two breakages map 1:1 to the task's required negative cases:
#   broken-1  the TAIL-bucket protection is removed (`if name >= tail_bucket:`
#             never triggers) ⇒ archive deletes the tail bucket ⇒ the guard's
#             "TAIL bucket survives" assertion must fail.   ["deletes the tail bucket"]
#   broken-2  the per-bucket VERIFY gate is removed (`_verify_bucket` always
#             returns ok=True) ⇒ a tampered sealed bucket is archived+deleted and
#             never paged ⇒ the guard's "tampered bucket not deleted / pages"
#             assertions must fail.            ["archives without verifying"]

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
GUARD="$HERE/szl-receipts-retention-e2e-guard.sh"
SERVER="$REPO_ROOT/services/szl-receipts-server/server.py"

fail() { echo "SELF-TEST FAIL: $*" >&2; exit 1; }

[ -r "$GUARD" ]  || fail "guard script not found: $GUARD"
[ -r "$SERVER" ] || fail "server.py not found: $SERVER"
python3 -c 'import cryptography' >/dev/null 2>&1 \
  || fail "python3 'cryptography' required (pip install cryptography)"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

# mutate IN OUT EXPR — copy server.py to OUT applying the python rewrite EXPR
# (EXPR transforms the file text held in variable `s`). Aborts if a breakage is
# a no-op (so a future server.py refactor that moves the guarded line can't make
# the self-test silently fixture-nothing).
mutate() {
  local out="$1" expr="$2"
  IN="$SERVER" OUT="$out" python3 - "$expr" <<'PYEOF'
import os, sys
expr = sys.argv[1]
s = open(os.environ["IN"]).read()
orig = s
ns = {"s": s}
exec("s = " + expr, ns)
s = ns["s"]
if s == orig:
    sys.stderr.write("mutation was a no-op: %s\n" % expr); sys.exit(2)
open(os.environ["OUT"], "w").write(s)
PYEOF
}

# broken-1: tail guard removed
B1="$T/server_no_tail_guard.py"
mutate "$B1" 's.replace("        if name >= tail_bucket:\n", "        if False:  # tail guard removed (negative fixture)\n")' \
  || fail "could not build broken-1 (tail guard removed) — has the tail guard line changed?"

# broken-2: per-bucket verify gate removed (always returns ok=True)
B2="$T/server_no_verify_gate.py"
mutate "$B2" 's.replace("def _verify_bucket(paths):\n", "def _verify_bucket(paths):\n    return (True, len(paths), \"GENESIS\", None)  # verify gate removed (negative fixture)\n")' \
  || fail "could not build broken-2 (verify gate removed) — has _verify_bucket changed?"

# Both broken copies must still be importable Python.
python3 -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" "$B1" || fail "broken-1 is not valid Python"
python3 -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" "$B2" || fail "broken-2 is not valid Python"

echo "== self-test 1/3: pristine server.py — the guard must PASS =="
if bash "$GUARD" >"$T/pristine.out" 2>&1; then
  echo "ok   pristine repo passes the e2e guard"
else
  sed 's/^/   | /' "$T/pristine.out" >&2
  fail "the e2e guard FAILED on the pristine repo (should pass)"
fi

echo "== self-test 2/3: tail guard removed — the guard must FAIL =="
if SERVER_SRC="$B1" bash "$GUARD" >"$T/b1.out" 2>&1; then
  sed 's/^/   | /' "$T/b1.out" >&2
  fail "the e2e guard PASSED with the tail-bucket guard removed (it must fail loudly)"
else
  grep -q 'FAIL .*TAIL bucket' "$T/b1.out" \
    || fail "broken-1 failed for the WRONG reason (expected a TAIL-bucket assertion failure)"
  echo "ok   the e2e guard fails loudly when the tail bucket gets deleted"
fi

echo "== self-test 3/3: verify gate removed — the guard must FAIL =="
if SERVER_SRC="$B2" bash "$GUARD" >"$T/b2.out" 2>&1; then
  sed 's/^/   | /' "$T/b2.out" >&2
  fail "the e2e guard PASSED with the per-bucket verify gate removed (it must fail loudly)"
else
  grep -qE 'FAIL .*(archived without verifying|did NOT page|want ALERT)' "$T/b2.out" \
    || fail "broken-2 failed for the WRONG reason (expected a tampered-bucket assertion failure)"
  echo "ok   the e2e guard fails loudly when a bucket is archived without verifying"
fi

echo ""
echo "szl-receipts-retention e2e guard self-test: all negative fixtures caught, pristine passes."
