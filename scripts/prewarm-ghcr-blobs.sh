#!/usr/bin/env bash
# Copyright 2026 SZL Holdings
# SPDX-License-Identifier: Apache-2.0
#
# prewarm-ghcr-blobs.sh — resumably pre-fetch a GHCR image's blobs into the Zarf
# image cache so that `zarf package create` never has to perform a fragile,
# NON-resumable image pull over the GHCR CDN.
#
# Why this exists
# ---------------
# During the full 5-organ bundle build, amaru's single ~363MB image layer
# repeatedly stalled / EOF'd on GHCR CDN pulls. Both `zarf` and `docker` image
# pulls are non-resumable (a stall restarts the transfer from byte 0), so a
# transient CDN hiccup on one fat layer would fail `zarf package create` for the
# whole organ. A clean CI runner hits the same wall.
#
# This script fetches each blob of an image (manifest + config + layers) with a
# resumable `curl -C -` loop, retrying with exponential backoff and a FRESH GHCR
# token per attempt, and writes them content-addressably into the Zarf image
# cache OCI layout (`<cache>/images/blobs/sha256/<hex>`). When zarf then runs
# `package create`, it finds every blob already present by digest and skips the
# network pull entirely.
#
# Behaviour is best-effort and idempotent: a blob already present with the
# correct sha256 is left untouched; a truncated/partial blob is resumed; a
# corrupt full-size blob is discarded and re-fetched. The script is safe to run
# repeatedly. If a blob ultimately cannot be fetched it exits non-zero so the
# caller can decide whether to fail or let zarf attempt its own pull.
#
# Usage:
#   scripts/prewarm-ghcr-blobs.sh <image-ref> [<image-ref> ...]
#
#   <image-ref> e.g.  ghcr.io/szl-holdings/amaru:uds-v0.2.0@sha256:53301e26...
#                     ghcr.io/szl-holdings/rosie@sha256:1984a15f...
#                     ghcr.io/szl-holdings/a11oy:uds-v0.3.0   (tag only)
#
# Environment:
#   ZARF_CACHE              Zarf cache dir (default: ~/.zarf-cache). The blobs
#                          are written under "$ZARF_CACHE/images/blobs/sha256".
#   GHCR_BEARER            Optional GitHub token used to obtain a scoped pull
#                          token (needed for private GHCR packages). When unset,
#                          an anonymous pull token is requested (public images).
#   PREWARM_RETRIES        Max attempts per blob (default: 6).
#   PREWARM_MAX_TIME       Per-attempt curl --max-time seconds (default: 1800).
#   PREWARM_CONNECT_TIMEOUT  curl --connect-timeout seconds (default: 30).
#
# This script is source-safe: sourcing it defines the functions without running
# main(), which the companion self-test (tests/test-prewarm-ghcr-blobs.sh) relies
# on to exercise the pure helpers offline.

set -uo pipefail

ZARF_CACHE="${ZARF_CACHE:-$HOME/.zarf-cache}"
PREWARM_RETRIES="${PREWARM_RETRIES:-6}"
PREWARM_MAX_TIME="${PREWARM_MAX_TIME:-1800}"
PREWARM_CONNECT_TIMEOUT="${PREWARM_CONNECT_TIMEOUT:-30}"

REGISTRY_HOST="ghcr.io"
MANIFEST_ACCEPT="application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.v2+json,application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json"

log() { echo "[prewarm] $*"; }
warn() { echo "[prewarm] WARNING: $*" >&2; }
err() { echo "[prewarm] ERROR: $*" >&2; }

# parse_ref <image-ref>
# Echoes "<repo>|<reference>" where repo is the path after the registry host
# (e.g. szl-holdings/amaru) and reference is the digest if one is present in the
# ref, otherwise the tag (defaulting to "latest"). A digest is always preferred
# over a tag when both are given (`repo:tag@sha256:...`).
parse_ref() {
  local ref="$1"
  ref="${ref#${REGISTRY_HOST}/}"
  local repo reference digest tagpart
  if [[ "$ref" == *"@"* ]]; then
    digest="${ref##*@}"
    repo="${ref%@*}"
    repo="${repo%%:*}"      # drop any :tag preceding the digest
    reference="$digest"
  else
    if [[ "$ref" == *":"* ]]; then
      tagpart="${ref##*:}"
      repo="${ref%:*}"
      reference="$tagpart"
    else
      repo="$ref"
      reference="latest"
    fi
  fi
  echo "${repo}|${reference}"
}

# blob_path <digest>
# Echoes the absolute cache path for a sha256:<hex> (or bare <hex>) digest.
blob_path() {
  local digest="$1"
  local hex="${digest#sha256:}"
  echo "${ZARF_CACHE}/images/blobs/sha256/${hex}"
}

# sha256_hex <file>  -> echoes the hex sha256 of the file (empty on missing file)
sha256_hex() {
  local f="$1"
  [ -f "$f" ] || { echo ""; return 0; }
  sha256sum "$f" 2>/dev/null | awk '{print $1}'
}

# is_cached <digest>  -> exit 0 if the blob already exists with the right sha256
is_cached() {
  local digest="$1"
  local hex="${digest#sha256:}"
  local dest; dest="$(blob_path "$digest")"
  [ -f "$dest" ] || return 1
  [ "$(sha256_hex "$dest")" = "$hex" ]
}

# fetch_token <repo>  -> echoes a GHCR bearer token scoped to pull <repo>
fetch_token() {
  local repo="$1"
  local url="https://${REGISTRY_HOST}/token?service=${REGISTRY_HOST}&scope=repository:${repo}:pull"
  local resp
  if [ -n "${GHCR_BEARER:-}" ]; then
    resp="$(curl -fsSL -u "x-access-token:${GHCR_BEARER}" "$url" 2>/dev/null)" || return 1
  else
    resp="$(curl -fsSL "$url" 2>/dev/null)" || return 1
  fi
  printf '%s' "$resp" | python3 -c 'import sys,json
try:
    d=json.load(sys.stdin)
    print(d.get("token") or d.get("access_token") or "")
except Exception:
    print("")'
}

# download_blob <repo> <digest> <size>
# Resumably downloads a single blob into the cache with retry/backoff and a fresh
# token per attempt. <size> may be empty (manifest blobs have no a-priori size).
# Returns 0 on a verified blob, 1 if all attempts are exhausted.
download_blob() {
  local repo="$1" digest="$2" size="${3:-}"
  local hex="${digest#sha256:}"
  local dest; dest="$(blob_path "$digest")"
  mkdir -p "$(dirname "$dest")"

  if is_cached "$digest"; then
    log "cache hit ${digest} ($(stat -c%s "$dest" 2>/dev/null || echo '?') B)"
    return 0
  fi

  local attempt=0 tok cur
  while [ "$attempt" -lt "$PREWARM_RETRIES" ]; do
    attempt=$((attempt + 1))
    tok="$(fetch_token "$repo")"
    if [ -z "$tok" ]; then
      warn "token fetch failed for ${repo} (attempt ${attempt}/${PREWARM_RETRIES})"
      sleep $(( attempt * 5 ))
      continue
    fi
    log "fetch ${digest} attempt ${attempt}/${PREWARM_RETRIES} (resumable)"
    curl -sL -C - \
      --connect-timeout "$PREWARM_CONNECT_TIMEOUT" \
      --max-time "$PREWARM_MAX_TIME" \
      -H "Authorization: Bearer ${tok}" \
      "https://${REGISTRY_HOST}/v2/${repo}/blobs/${digest}" \
      -o "$dest" || true

    if is_cached "$digest"; then
      log "verified ${digest} ($(stat -c%s "$dest" 2>/dev/null || echo '?') B)"
      return 0
    fi

    cur="$(stat -c%s "$dest" 2>/dev/null || echo 0)"
    if [ -n "$size" ] && [ "$cur" -ge "$size" ]; then
      # Reached/exceeded the expected size but sha mismatched -> corrupt; discard
      # so the next attempt restarts cleanly instead of trying to resume garbage.
      warn "corrupt full blob ${digest} (got ${cur}B want ${size}B); discarding"
      rm -f "$dest"
    else
      log "partial ${digest} (${cur}B); will resume"
    fi
    sleep $(( attempt * 5 ))
  done

  err "exhausted ${PREWARM_RETRIES} attempts for ${digest}"
  return 1
}

# prewarm_ref <image-ref>
# Resolves the manifest (following an index to its linux/amd64 child), then
# pre-warms the manifest blob, the config blob, and every layer blob.
prewarm_ref() {
  local ref="$1"
  local parsed repo reference
  parsed="$(parse_ref "$ref")"
  repo="${parsed%|*}"
  reference="${parsed#*|}"
  log "pre-warming ${REGISTRY_HOST}/${repo} @ ${reference}"

  local tok
  tok="$(fetch_token "$repo")"
  if [ -z "$tok" ]; then
    err "could not obtain pull token for ${repo}"
    return 1
  fi

  local manifest mtype
  manifest="$(curl -fsSL -H "Authorization: Bearer ${tok}" -H "Accept: ${MANIFEST_ACCEPT}" \
    "https://${REGISTRY_HOST}/v2/${repo}/manifests/${reference}" 2>/dev/null)"
  if [ -z "$manifest" ]; then
    err "could not fetch manifest ${repo}@${reference}"
    return 1
  fi

  mtype="$(printf '%s' "$manifest" | python3 -c 'import sys,json
try: print(json.load(sys.stdin).get("mediaType",""))
except Exception: print("")')"

  # If this is a multi-arch index, drill down to the linux/amd64 child manifest.
  if printf '%s' "$manifest" | python3 -c 'import sys,json
try: sys.exit(0 if "manifests" in json.load(sys.stdin) else 1)
except Exception: sys.exit(1)'; then
    local child
    child="$(printf '%s' "$manifest" | python3 -c 'import sys,json
d=json.load(sys.stdin)
amd=""
for m in d.get("manifests",[]):
    p=m.get("platform",{})
    if p.get("os")=="linux" and p.get("architecture")=="amd64":
        amd=m.get("digest",""); break
print(amd)')"
    if [ -z "$child" ]; then
      err "index ${repo}@${reference} has no linux/amd64 child"
      return 1
    fi
    log "index -> linux/amd64 child ${child}"
    # Store the index blob too (harmless), then descend.
    local idx_dest; idx_dest="$(blob_path "$reference")"
    if [[ "$reference" == sha256:* ]]; then
      mkdir -p "$(dirname "$idx_dest")"
      printf '%s' "$manifest" > "$idx_dest"
    fi
    reference="$child"
    manifest="$(curl -fsSL -H "Authorization: Bearer ${tok}" -H "Accept: ${MANIFEST_ACCEPT}" \
      "https://${REGISTRY_HOST}/v2/${repo}/manifests/${reference}" 2>/dev/null)"
    if [ -z "$manifest" ]; then
      err "could not fetch child manifest ${repo}@${reference}"
      return 1
    fi
  fi

  # Persist the (child) manifest blob itself into the cache when we know its
  # digest, so zarf finds it without a network round-trip.
  if [[ "$reference" == sha256:* ]]; then
    local man_dest; man_dest="$(blob_path "$reference")"
    mkdir -p "$(dirname "$man_dest")"
    printf '%s' "$manifest" > "$man_dest"
    if is_cached "$reference"; then
      log "stored manifest blob ${reference}"
    else
      # Manifest bytes may be canonicalized differently by the registry; this is
      # not fatal (zarf can re-fetch the small manifest), so just note it.
      warn "manifest blob digest mismatch for ${reference} (small re-fetch ok)"
      rm -f "$man_dest"
    fi
  fi

  # Enumerate config + layer blobs (digest<TAB>size per line).
  local blobs
  blobs="$(printf '%s' "$manifest" | python3 -c 'import sys,json
d=json.load(sys.stdin)
cfg=d.get("config")
if isinstance(cfg,dict) and cfg.get("digest"):
    print(cfg["digest"]+"\t"+str(cfg.get("size","")))
for l in d.get("layers",[]):
    if l.get("digest"):
        print(l["digest"]+"\t"+str(l.get("size","")))')"

  if [ -z "$blobs" ]; then
    err "manifest ${repo}@${reference} listed no blobs"
    return 1
  fi

  local rc=0 digest size
  while IFS=$'\t' read -r digest size; do
    [ -n "$digest" ] || continue
    if ! download_blob "$repo" "$digest" "$size"; then
      rc=1
    fi
  done <<< "$blobs"

  return "$rc"
}

main() {
  if [ "$#" -lt 1 ]; then
    err "usage: $0 <image-ref> [<image-ref> ...]"
    return 2
  fi
  mkdir -p "${ZARF_CACHE}/images/blobs/sha256"
  log "zarf cache: ${ZARF_CACHE}"
  local overall=0 ref
  for ref in "$@"; do
    if ! prewarm_ref "$ref"; then
      warn "pre-warm incomplete for ${ref}"
      overall=1
    fi
  done
  if [ "$overall" -eq 0 ]; then
    log "all blobs pre-warmed successfully"
  fi
  return "$overall"
}

# Only run main when executed directly (sourcing exposes the helpers for tests).
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
  exit $?
fi
