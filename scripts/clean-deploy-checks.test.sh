# Copyright 2026 SZL Holdings
# SPDX-License-Identifier: Apache-2.0
#
# clean-deploy-checks.test.sh — negative-fixture self-test for the clean-deploy
# guard (scripts/clean-deploy-checks.sh).
#
# WHY THIS EXISTS
# The guard enforces the five szl-receipts clean-deploy invariants entirely with
# hand-written awk/grep. If one of those programs breaks (an indentation slip, a
# regex typo) the check can PASS VACUOUSLY — green while guarding nothing. We
# already shipped a guard that checked the wrong thing for two commits. This test
# feeds each check a deliberately-BROKEN copy of its source file and asserts the
# check FAILS, plus asserts the pristine ("good") copies PASS. A future edit that
# neuters a check is caught here in CI.
#
# It runs the EXACT script the workflow runs (sourced as functions), against
# fixtures built from the real source files, so it tests the real guard.
#
# Usage: bash scripts/clean-deploy-checks.test.sh
# Exit 0 if every case behaves as expected, 1 otherwise.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
CHECKS="$HERE/clean-deploy-checks.sh"

# Source the checks so we can call inv1..inv5 directly. Sourcing (not exec)
# guarantees the self-test exercises the same functions the workflow calls.
# shellcheck source=/dev/null
source "$CHECKS"

PASS=0
FAIL=0
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

# Source files the guard inspects, relative to a repo root.
SRC_FILES=(
  "charts/szl-key-init/values.yaml"
  "charts/szl-key-init/templates/keygen-job.yaml"
  "manifests/key-init-exemption.yaml"
  "packages/szl-receipts/zarf.yaml"
)

# new_fixture — build a fresh fixture tree (a faithful copy of the four real
# source files) under a unique dir and echo its path.
new_fixture() {
  local dir
  dir="$(mktemp -d "$TMPROOT/fixture.XXXXXX")"
  local f
  for f in "${SRC_FILES[@]}"; do
    mkdir -p "$dir/$(dirname "$f")"
    cp "$REPO_ROOT/$f" "$dir/$f"
  done
  echo "$dir"
}

# expect_pass CHECK ROOT NAME — assert CHECK returns 0 on ROOT.
expect_pass() {
  local check="$1" root="$2" name="$3" out rc
  out="$("$check" "$root" 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ]; then
    echo "ok   PASS-expected: $name"
    PASS=$((PASS+1))
  else
    echo "FAIL PASS-expected but $check exited $rc: $name"
    echo "$out" | sed 's/^/       | /'
    FAIL=$((FAIL+1))
  fi
}

# expect_fail CHECK ROOT NAME — assert CHECK returns non-zero on ROOT.
expect_fail() {
  local check="$1" root="$2" name="$3" out rc
  out="$("$check" "$root" 2>&1)"; rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "ok   FAIL-expected: $name (exit $rc)"
    PASS=$((PASS+1))
  else
    echo "FAIL FAIL-expected but $check PASSED: $name"
    echo "$out" | sed 's/^/       | /'
    FAIL=$((FAIL+1))
  fi
}

# reorder_components NAMES_FILE_IN OUT DESIRED... — reorder the top-level
# components in a zarf.yaml. Top-level component items start with exactly two
# spaces + "- name:"; nested manifest names are indented deeper and travel with
# their block. DESIRED is the new ordered list of component names.
reorder_components() {
  local in="$1" out="$2"; shift 2
  python3 - "$in" "$out" "$@" <<'PY'
import sys, re
inp, outp = sys.argv[1], sys.argv[2]
desired = sys.argv[3:]
lines = open(inp).read().splitlines(keepends=True)
# find the components: line (top-level, column 0)
start = next(i for i,l in enumerate(lines) if re.match(r'^components:\s*$', l))
head = lines[:start+1]
rest = lines[start+1:]
# end of components block = first column-0 non-comment line, else EOF
end = len(rest)
for i,l in enumerate(rest):
    if re.match(r'^[^\s#]', l):
        end = i
        break
body, tail = rest[:end], rest[end:]
# split body into blocks at "  - name: X" (exactly two leading spaces)
blocks = {}
order = []
cur_name = None
buf = []
def flush():
    if cur_name is not None:
        blocks[cur_name] = buf[:]
        order.append(cur_name)
for l in body:
    m = re.match(r'^  - name:\s*(\S+)\s*$', l)
    if m:
        flush()
        cur_name = m.group(1)
        buf = [l]
    else:
        buf.append(l)
flush()
# rebuild in desired order; any name not listed keeps original relative order after
new_order = [n for n in desired if n in blocks] + [n for n in order if n not in desired]
new_body = []
for n in new_order:
    new_body.extend(blocks[n])
open(outp, 'w').write(''.join(head) + ''.join(new_body) + ''.join(tail))
PY
}

VAL="charts/szl-key-init/values.yaml"
KEYGEN="charts/szl-key-init/templates/keygen-job.yaml"
EXEMPT="manifests/key-init-exemption.yaml"
ZARF="packages/szl-receipts/zarf.yaml"

echo "== Good fixtures must PASS each check =="
GOOD="$(new_fixture)"
expect_pass inv1 "$GOOD" "inv1 on good values.yaml"
expect_pass inv2 "$GOOD" "inv2 on good keygen-job.yaml"
expect_pass inv3 "$GOOD" "inv3 on good key-init-exemption.yaml"
expect_pass inv4 "$GOOD" "inv4 on good zarf.yaml"
expect_pass inv5 "$GOOD" "inv5 on good zarf.yaml"

echo
echo "== Negative fixtures must FAIL the matching check =="

# --- Invariant 1: wrong namespace ---
F="$(new_fixture)"
sed -i 's/^namespace:[[:space:]]*szl-receipts/namespace: pepr-system/' "$F/$VAL"
expect_fail inv1 "$F" "inv1: namespace flipped to pepr-system"

# --- Invariant 1: namespace line removed entirely ---
F="$(new_fixture)"
sed -i '/^namespace:[[:space:]]*szl-receipts/d' "$F/$VAL"
expect_fail inv1 "$F" "inv1: namespace line deleted"

# --- Invariant 2: old two-file key.priv/key.pub scheme ---
F="$(new_fixture)"
sed -i 's#--from-file="${KEY_FILE}=/tmp/priv.pem"#--from-file=key.priv=/tmp/priv.pem --from-file=key.pub=/tmp/pub.pem#' "$F/$KEYGEN"
sed -i 's#KEY_FILE="{{ .Values.keyFile | default "ed25519.pem" }}"#KEY_FILE="key.priv"#' "$F/$KEYGEN"
expect_fail inv2 "$F" "inv2: reverted to two-file key.priv/key.pub"

# --- Invariant 2: KEY_FILE no longer defaults to ed25519.pem ---
F="$(new_fixture)"
sed -i 's/default "ed25519.pem"/default "signing.pem"/' "$F/$KEYGEN"
expect_fail inv2 "$F" "inv2: KEY_FILE default changed to signing.pem"

# --- Invariant 3: exemption manifest missing ---
F="$(new_fixture)"
rm -f "$F/$EXEMPT"
expect_fail inv3 "$F" "inv3: exemption manifest deleted"

# --- Invariant 3: wrong kind ---
F="$(new_fixture)"
sed -i 's/^kind:[[:space:]]*Exemption/kind: Policy/' "$F/$EXEMPT"
expect_fail inv3 "$F" "inv3: kind changed from Exemption"

# --- Invariant 3: RequireNonRootUser policy dropped ---
F="$(new_fixture)"
sed -i '/RequireNonRootUser/d' "$F/$EXEMPT"
expect_fail inv3 "$F" "inv3: RequireNonRootUser policy removed"

# --- Invariant 4: exemption ordered AFTER key-init ---
F="$(new_fixture)"
reorder_components "$F/$ZARF" "$F/$ZARF.tmp" \
  szl-core-rightsize szl-receipts-namespace szl-key-init szl-key-init-exemption
mv "$F/$ZARF.tmp" "$F/$ZARF"
expect_fail inv4 "$F" "inv4: exemption reordered after key-init"

# --- Invariant 4: server image tag downgraded ---
F="$(new_fixture)"
sed -i 's#szl-receipts-server:uds-v0.4.0#szl-receipts-server:uds-v0.3.1#g' "$F/$ZARF"
expect_fail inv4 "$F" "inv4: image tag downgraded to uds-v0.3.1"

# --- Invariant 5: SMALL_SERVER_RIGHTSIZE variable removed ---
F="$(new_fixture)"
python3 - "$F/$ZARF" <<'PY'
import sys, re
p = sys.argv[1]
lines = open(p).read().splitlines(keepends=True)
out = []
skip = False
for l in lines:
    if re.match(r'^  - name:\s*SMALL_SERVER_RIGHTSIZE\s*$', l):
        skip = True
        continue
    if skip and re.match(r'^  - name:', l):   # next variable
        skip = False
    if skip and re.match(r'^[^\s#]', l):       # left variables block
        skip = False
    if not skip:
        out.append(l)
open(p, 'w').write(''.join(out))
PY
expect_fail inv5 "$F" "inv5: SMALL_SERVER_RIGHTSIZE variable removed"

# --- Invariant 5: SMALL_SERVER_RIGHTSIZE default flipped to false ---
F="$(new_fixture)"
python3 - "$F/$ZARF" <<'PY'
import sys, re
p = sys.argv[1]
lines = open(p).read().splitlines(keepends=True)
seen = False
for i, l in enumerate(lines):
    if re.match(r'^  - name:\s*SMALL_SERVER_RIGHTSIZE\s*$', l):
        seen = True
    elif seen and re.match(r'^    default:\s*"?true"?\s*$', l):
        lines[i] = '    default: "false"\n'
        break
open(p, 'w').write(''.join(lines))
PY
expect_fail inv5 "$F" "inv5: SMALL_SERVER_RIGHTSIZE default flipped to false"

# --- Invariant 5: szl-core-rightsize not first ---
F="$(new_fixture)"
reorder_components "$F/$ZARF" "$F/$ZARF.tmp" \
  szl-key-init-exemption szl-core-rightsize
mv "$F/$ZARF.tmp" "$F/$ZARF"
expect_fail inv5 "$F" "inv5: szl-core-rightsize no longer first component"

# --- Invariant 5: rightsize action stops targeting zarf/agent-hook ---
F="$(new_fixture)"
sed -i 's#zarf/agent-hook#zarf/other-hook#g' "$F/$ZARF"
expect_fail inv5 "$F" "inv5: rightsize no longer pins zarf/agent-hook"

echo
echo "== Re-confirm the good fixtures still PASS (no fixture bleed) =="
GOOD2="$(new_fixture)"
expect_pass all "$GOOD2" "all invariants on good fixtures"

echo
echo "================================================="
echo "Self-test results: $PASS passed, $FAIL failed."
if [ "$FAIL" -ne 0 ]; then
  echo "::error::clean-deploy guard self-test FAILED — a check no longer behaves as expected."
  exit 1
fi
echo "clean-deploy guard self-test passed — every check fails on bad input and passes on good input."
