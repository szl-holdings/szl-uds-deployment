# Copyright 2026 SZL Holdings
# SPDX-License-Identifier: Apache-2.0
#
# clean-deploy-checks.sh — the szl-receipts clean-deploy invariant checks,
# extracted verbatim from .github/workflows/clean-deploy-guard.yml so the
# awk/grep logic is unit-testable (see clean-deploy-checks.test.sh).
#
# The "clean from-scratch deploy" property of szl-receipts (a single
# `zarf package deploy` that comes up Ready + signed + rightsized with ZERO
# manual kubectl) lives in exactly five places. This script asserts each one
# still holds. It is a pure grep/awk text check — no cluster needed.
#
# Why a script and not inline workflow steps: the inline awk programs can break
# silently (an indentation/regex slip makes a `grep` match nothing and the step
# pass VACUOUSLY — green while guarding nothing). By extracting the logic here we
# can feed it deliberately-broken fixtures in CI and prove each check actually
# FAILS on bad input. The workflow calls this exact script, so the self-test
# exercises the real guard.
#
# Usage:
#   clean-deploy-checks.sh <check> [root]
#     check : inv1 | inv2 | inv3 | inv4 | inv5 | all
#     root  : repo root to check (default: current directory)
#
# Each check exits 0 when the invariant holds and non-zero (printing a GitHub
# ::error annotation) when it is regressed.

set -uo pipefail

# err FILE MESSAGE — emit a GitHub Actions error annotation.
err() { echo "::error file=$1::$2"; }

# ── Invariant 1 ───────────────────────────────────────────────────────────────
# charts/szl-key-init/values.yaml -> namespace: szl-receipts
inv1() {
  local root="${1:-.}"
  local F="$root/charts/szl-key-init/values.yaml"
  test -f "$F" || { err "$F" "missing — required for clean deploy"; return 1; }
  if ! grep -Eq '^[[:space:]]*namespace:[[:space:]]*szl-receipts[[:space:]]*$' "$F"; then
    err "$F" "REGRESSION — 'namespace: szl-receipts' not found."
    err "$F" "The Ed25519 Secret is namespace-local; if key-init lands it"
    err "$F" "anywhere but szl-receipts the server boots UNSIGNED (no error)."
    echo "----- current namespace lines -----"
    grep -nE '^[[:space:]]*namespace:' "$F" || echo "(none)"
    return 1
  fi
  echo "OK: $F sets namespace: szl-receipts"
}

# ── Invariant 2 ───────────────────────────────────────────────────────────────
# charts/szl-key-init/templates/keygen-job.yaml -> single --from-file=ed25519.pem=
# (NOT the old two-file key.priv / key.pub scheme)
inv2() {
  local root="${1:-.}"
  local F="$root/charts/szl-key-init/templates/keygen-job.yaml"
  test -f "$F" || { err "$F" "missing — required for clean deploy"; return 1; }
  # Must create the Secret with a single --from-file=ed25519.pem= entry,
  # matching the key file the receipts-server Deployment mounts.
  if ! grep -Eq -- '--from-file="?\$\{?KEY_FILE\}?=|--from-file="?ed25519\.pem=' "$F"; then
    err "$F" "REGRESSION — single --from-file=ed25519.pem= not found."
    err "$F" "The server mounts ed25519.pem; a wrong/extra key name = UNSIGNED server."
    grep -nE -- '--from-file' "$F" || echo "(no --from-file lines)"
    return 1
  fi
  # KEY_FILE must default to ed25519.pem (the name the server mounts).
  if ! grep -Eq 'KEY_FILE=.*default[[:space:]]+"ed25519\.pem"|KEY_FILE="ed25519\.pem"' "$F"; then
    err "$F" "REGRESSION — KEY_FILE no longer defaults to ed25519.pem."
    grep -nE 'KEY_FILE=' "$F" || echo "(no KEY_FILE assignment)"
    return 1
  fi
  # Reject the OLD two-file scheme outright.
  if grep -Eq -- '--from-file="?key\.priv|--from-file="?key\.pub|key\.priv=|key\.pub=' "$F"; then
    err "$F" "REGRESSION — old two-file key.priv/key.pub scheme detected."
    grep -nE 'key\.priv|key\.pub' "$F"
    return 1
  fi
  echo "OK: $F creates the Secret with a single ed25519.pem key file"
}

# ── Invariant 3 ───────────────────────────────────────────────────────────────
# manifests/key-init-exemption.yaml -> a UDS Exemption scoped to
# RequireNonRootUser, matcher ^szl-key-init.* in ns szl-receipts
inv3() {
  local root="${1:-.}"
  local F="$root/manifests/key-init-exemption.yaml"
  test -f "$F" || {
    err "$F" "REGRESSION — exemption manifest is MISSING."
    err "$F" "Without it pepr-uds-core DENIES the root keygen pod -> UNSIGNED server."
    return 1
  }
  grep -Eq '^kind:[[:space:]]*Exemption[[:space:]]*$' "$F" \
    || { err "$F" "REGRESSION — not a 'kind: Exemption'."; return 1; }
  grep -Eq 'RequireNonRootUser' "$F" \
    || { err "$F" "REGRESSION — RequireNonRootUser policy not exempted."; return 1; }
  grep -Eq 'namespace:[[:space:]]*szl-receipts' "$F" \
    || { err "$F" "REGRESSION — matcher not scoped to ns szl-receipts."; return 1; }
  grep -Eq 'name:[[:space:]]*"?\^szl-key-init' "$F" \
    || { err "$F" "REGRESSION — matcher name not '^szl-key-init.*'."; return 1; }
  echo "OK: $F is a UDS Exemption (RequireNonRootUser, ^szl-key-init.* in ns szl-receipts)"
}

# ── Invariant 4 ───────────────────────────────────────────────────────────────
# packages/szl-receipts/zarf.yaml -> szl-key-init-exemption is ordered BEFORE
# szl-key-init AND the server image tag is uds-v0.4.1
inv4() {
  local root="${1:-.}"
  local F="$root/packages/szl-receipts/zarf.yaml"
  test -f "$F" || { err "$F" "missing — required for clean deploy"; return 1; }
  # Extract the ORDERED list of top-level component names. The Exemption no
  # longer needs to be literally first (szl-core-rightsize precedes it now,
  # see Invariant 5), but it MUST still be admitted before the root keygen
  # Job runs — i.e. szl-key-init-exemption must come BEFORE szl-key-init.
  local COMPONENTS
  COMPONENTS="$(awk '
    /^components:[[:space:]]*$/ { in_c=1; next }
    in_c && /^[^[:space:]#]/   { exit }          # left the components block
    in_c && /^[[:space:]]*-[[:space:]]*name:/ {
      line=$0
      sub(/^[[:space:]]*-[[:space:]]*name:[[:space:]]*/, "", line)
      gsub(/[[:space:]"\x27]/, "", line)
      print line
    }
  ' "$F")"
  echo "Components in order:"; echo "$COMPONENTS" | nl
  local EX_POS KI_POS
  EX_POS="$(printf '%s\n' "$COMPONENTS" | grep -nx 'szl-key-init-exemption' | head -1 | cut -d: -f1 || true)"
  KI_POS="$(printf '%s\n' "$COMPONENTS" | grep -nx 'szl-key-init'           | head -1 | cut -d: -f1 || true)"
  if [ -z "$EX_POS" ]; then
    err "$F" "REGRESSION — szl-key-init-exemption component is MISSING."
    err "$F" "Without it pepr-uds-core DENIES the root keygen pod -> UNSIGNED server."
    return 1
  fi
  if [ -z "$KI_POS" ]; then
    err "$F" "REGRESSION — szl-key-init component is MISSING."
    return 1
  fi
  if [ "$EX_POS" -ge "$KI_POS" ]; then
    err "$F" "REGRESSION — szl-key-init-exemption (pos $EX_POS) must come BEFORE szl-key-init (pos $KI_POS)."
    err "$F" "If the Exemption is not admitted first, the root keygen pod is DENIED -> UNSIGNED server."
    return 1
  fi
  # The server image tag must be uds-v0.4.1 (chart tag & zarf images: list
  # must stay in lockstep, else ErrImagePull after a registry cold-restart).
  if ! grep -Eq 'ghcr\.io/szl-holdings/szl-receipts-server:uds-v0\.4\.1' "$F"; then
    err "$F" "REGRESSION — server image tag is not uds-v0.4.1."
    grep -nE 'szl-receipts-server:' "$F" || echo "(no szl-receipts-server image line)"
    return 1
  fi
  echo "OK: $F orders szl-key-init-exemption (pos $EX_POS) before szl-key-init (pos $KI_POS) and pins uds-v0.4.1"
}

# ── Invariant 5 ───────────────────────────────────────────────────────────────
# packages/szl-receipts/zarf.yaml -> szl-core-rightsize is the FIRST component
# with an onDeploy.before action that pins pepr-uds-core + zarf agent-hook to
# replicas=1, gated on the SMALL_SERVER_RIGHTSIZE var (default true)
inv5() {
  local root="${1:-.}"
  local F="$root/packages/szl-receipts/zarf.yaml"
  test -f "$F" || { err "$F" "missing — required for clean deploy"; return 1; }
  # 5a. The SMALL_SERVER_RIGHTSIZE variable must still exist, defaulting to
  #     "true" — turning it false opts an HA cluster out of the rightsize.
  if ! awk '
    /^variables:[[:space:]]*$/ { in_v=1; next }
    in_v && /^[^[:space:]#]/   { exit }          # left the variables block
    in_v && /^[[:space:]]*-[[:space:]]*name:[[:space:]]*SMALL_SERVER_RIGHTSIZE[[:space:]]*$/ { found=1 }
    in_v && found && /^[[:space:]]*default:[[:space:]]*"?true"?[[:space:]]*$/ { print "ok"; exit }
  ' "$F" | grep -q ok; then
    err "$F" "REGRESSION — variable SMALL_SERVER_RIGHTSIZE (default \"true\") not found."
    err "$F" "Without it a fresh deploy keeps the HA replica defaults and a ~2-vCPU node stalls in a CPU Pending storm."
    grep -nE 'SMALL_SERVER_RIGHTSIZE' "$F" || echo "(no SMALL_SERVER_RIGHTSIZE line)"
    return 1
  fi
  # 5b. szl-core-rightsize must be the FIRST component, so it frees CPU
  #     before the heavier szl-receipts workloads schedule.
  local FIRST_COMPONENT
  FIRST_COMPONENT="$(awk '
    /^components:[[:space:]]*$/ { in_c=1; next }
    in_c && /^[^[:space:]#]/   { exit }
    in_c && /^[[:space:]]*-[[:space:]]*name:/ {
      line=$0
      sub(/^[[:space:]]*-[[:space:]]*name:[[:space:]]*/, "", line)
      gsub(/[[:space:]"\x27]/, "", line)
      print line
      exit
    }
  ' "$F")"
  echo "First component: '${FIRST_COMPONENT}'"
  if [ "$FIRST_COMPONENT" != "szl-core-rightsize" ]; then
    err "$F" "REGRESSION — first component is '${FIRST_COMPONENT}', expected 'szl-core-rightsize'."
    err "$F" "The rightsize patch must run before the heavy receipts pods schedule, or a ~2-vCPU node stalls."
    return 1
  fi
  # 5c. The szl-core-rightsize component must carry an onDeploy.before action
  #     that pins BOTH pepr-system/pepr-uds-core and zarf/agent-hook to
  #     replicas=1, gated on SMALL_SERVER_RIGHTSIZE. Capture just that
  #     component's YAML block (up to the next top-level component).
  local BLOCK
  BLOCK="$(awk '
    $0 ~ /^[[:space:]]*-[[:space:]]*name:[[:space:]]*szl-core-rightsize[[:space:]]*$/ { cap=1; print; next }
    cap && /^[[:space:]]*-[[:space:]]*name:/ { exit }   # next component starts
    cap { print }
  ' "$F")"
  local rc=0
  check() {
    if ! printf '%s\n' "$BLOCK" | grep -Eq -- "$1"; then
      err "$F" "REGRESSION — szl-core-rightsize action: $2"
      rc=1
    fi
  }
  check 'onDeploy:'                  "no onDeploy actions block"
  check 'before:'                    "no onDeploy.before action"
  check 'SMALL_SERVER_RIGHTSIZE'     "no longer gated on SMALL_SERVER_RIGHTSIZE"
  check 'pepr-system/pepr-uds-core'  "no longer targets pepr-system/pepr-uds-core"
  check 'zarf/agent-hook'            "no longer targets zarf/agent-hook"
  check '"replicas":[[:space:]]*1'   "no longer patches replicas=1"
  [ "$rc" -eq 0 ] || return 1
  echo "OK: szl-core-rightsize is first, gated on SMALL_SERVER_RIGHTSIZE, pins pepr-uds-core + zarf agent-hook to replicas=1"
}

# all [root] — run every invariant; exit non-zero if ANY fail (running all so
# every regression is reported in one pass).
all() {
  local root="${1:-.}"
  local rc=0
  inv1 "$root" || rc=1
  inv2 "$root" || rc=1
  inv3 "$root" || rc=1
  inv4 "$root" || rc=1
  inv5 "$root" || rc=1
  if [ "$rc" -eq 0 ]; then
    echo "All five szl-receipts clean-deploy invariants are intact."
  fi
  return "$rc"
}

main() {
  local check="${1:-all}"
  local root="${2:-.}"
  case "$check" in
    inv1) inv1 "$root" ;;
    inv2) inv2 "$root" ;;
    inv3) inv3 "$root" ;;
    inv4) inv4 "$root" ;;
    inv5) inv5 "$root" ;;
    all)  all  "$root" ;;
    *)
      echo "usage: $0 {inv1|inv2|inv3|inv4|inv5|all} [root]" >&2
      return 2
      ;;
  esac
}

# Only run main when executed directly, so the test harness can `source` this
# file and call the inv* functions without triggering a run.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
