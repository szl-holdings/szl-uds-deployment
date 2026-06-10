#!/usr/bin/env bash
# Copyright 2026 SZL Holdings
# SPDX-License-Identifier: Apache-2.0
#
# Self-test for scripts/prewarm-ghcr-blobs.sh.
#
# The pre-warm script's value is entirely in its pure, offline helpers:
#   - parse_ref:   correctly split a GHCR ref into repo + (digest-preferred) ref
#   - blob_path:   map a digest to the Zarf OCI-layout cache path
#   - sha256_hex:  hash a file
#   - is_cached:   treat a blob as cached ONLY when present AND sha256-correct
#                  (the whole point — a truncated/corrupt blob must NOT count as
#                  cached, or the build would consume a broken layer)
#
# This test sources the script (which is source-safe and does not run main on
# source) and asserts those helpers. No network is required.
#
# Run locally:  bash tests/test-prewarm-ghcr-blobs.sh
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
script="$repo_root/scripts/prewarm-ghcr-blobs.sh"

if [ ! -f "$script" ]; then
  echo "FATAL: pre-warm script not found at $script"
  exit 2
fi

# Sandbox the cache so the test never touches a real ~/.zarf-cache.
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export ZARF_CACHE="$tmp/zarf-cache"

# shellcheck disable=SC1090
source "$script"

fail=0

eq() {
  local desc="$1" want="$2" got="$3"
  if [ "$got" = "$want" ]; then
    echo "PASS: $desc"
  else
    echo "FAIL: $desc"
    echo "    want: $want"
    echo "    got:  $got"
    fail=1
  fi
}

ok() {
  local desc="$1"; shift
  if "$@"; then echo "PASS: $desc"; else echo "FAIL: $desc"; fail=1; fi
}

not_ok() {
  local desc="$1"; shift
  if "$@"; then echo "FAIL: $desc (expected non-zero)"; fail=1; else echo "PASS: $desc"; fi
}

# ── parse_ref ────────────────────────────────────────────────────────────────
# tag + digest -> digest wins
eq "parse_ref prefers digest over tag" \
  "szl-holdings/amaru|sha256:53301e26" \
  "$(parse_ref 'ghcr.io/szl-holdings/amaru:uds-v0.2.0@sha256:53301e26')"

# digest only
eq "parse_ref digest-only" \
  "szl-holdings/rosie|sha256:1984a15f" \
  "$(parse_ref 'ghcr.io/szl-holdings/rosie@sha256:1984a15f')"

# tag only
eq "parse_ref tag-only" \
  "szl-holdings/a11oy|uds-v0.3.0" \
  "$(parse_ref 'ghcr.io/szl-holdings/a11oy:uds-v0.3.0')"

# no tag, no digest -> latest
eq "parse_ref bare repo defaults to latest" \
  "szl-holdings/sentra|latest" \
  "$(parse_ref 'ghcr.io/szl-holdings/sentra')"

# ── blob_path ────────────────────────────────────────────────────────────────
eq "blob_path maps digest into OCI-layout cache" \
  "${ZARF_CACHE}/images/blobs/sha256/deadbeef" \
  "$(blob_path 'sha256:deadbeef')"

eq "blob_path accepts a bare hex too" \
  "${ZARF_CACHE}/images/blobs/sha256/cafef00d" \
  "$(blob_path 'cafef00d')"

# ── sha256_hex + is_cached ───────────────────────────────────────────────────
content="hello-szl-organ-layer"
real_hex="$(printf '%s' "$content" | sha256sum | awk '{print $1}')"
dest="$(blob_path "sha256:${real_hex}")"
mkdir -p "$(dirname "$dest")"
printf '%s' "$content" > "$dest"

eq "sha256_hex hashes a present file" "$real_hex" "$(sha256_hex "$dest")"
eq "sha256_hex empty for missing file" "" "$(sha256_hex "$tmp/nope")"

ok "is_cached true when blob present and sha matches" is_cached "sha256:${real_hex}"

# A blob whose digest does NOT match its contents must NOT be considered cached.
wrong="sha256:0000000000000000000000000000000000000000000000000000000000000000"
wrong_dest="$(blob_path "$wrong")"
printf '%s' "$content" > "$wrong_dest"   # contents != claimed digest
not_ok "is_cached false on sha mismatch (corrupt/truncated blob)" is_cached "$wrong"

# Missing blob is not cached.
not_ok "is_cached false when blob absent" is_cached "sha256:abcabcabc"

# ── main usage guard ─────────────────────────────────────────────────────────
( main ); rc=$?
eq "main with no args returns usage exit 2" "2" "$rc"

if [ "$fail" -ne 0 ]; then
  echo
  echo "SELF-TEST FAILED: prewarm-ghcr-blobs helpers are not behaving as specified."
  exit 1
fi

echo
echo "SELF-TEST OK: ref parsing, cache pathing and sha-verified caching all hold."
