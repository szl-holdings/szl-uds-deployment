# Copyright 2026 SZL Holdings
# SPDX-License-Identifier: Apache-2.0
#
# probe-organ-image-present.sh — Warn EARLY (and unambiguously) if a RETIRED
# organ's only surviving artifact — its pre-deletion GHCR container image — ever
# disappears or is privatized.
#
# WHY THIS EXISTS
# ---------------
# The amaru, sentra, and yupana GitHub source repos are DELETED (404). Their only
# surviving build artifacts are the container images already published+signed on
# GHCR before deletion:
#     ghcr.io/szl-holdings/{amaru,sentra,yupana}@<the @sha256 pin in zarf.yaml>
# Those three images are PUBLIC, pullable and cosign-signed today, so a failing
# `prove-organs` leg for one of them means a REAL deploy regression worth fixing.
#
# BUT if GHCR ever garbage-collects, deletes, or privatizes one of these images,
# `prove-organs` would also go red — and that red is trivially MISREAD as a code /
# deploy regression, sending someone chasing a deployment bug that does not exist.
# Because the source repos are gone, a vanished image is UNRECOVERABLE and is a
# fundamentally different (and worse) event than a deploy regression.
#
# This probe makes the distinction unambiguous. For each retired organ it:
#   * reads the digest pin straight from packages/<organ>/zarf.yaml (source of
#     truth — the same @sha256 prove-organs deploys),
#   * HEADs the digest-pinned image manifest on GHCR, and
#   * HEADs the matching cosign signature tag (sha256-<hex>.sig),
# then emits a distinct, greppable verdict:
#     "IMAGE MISSING / PRIVATE: ..."   (manifest gone / 401 / 403)
#     "SIGNATURE MISSING: ..."         (image present, cosign .sig gone)
#     "OK: <organ> ..."                (both present)
# and exits non-zero on any disappearance. A red from THIS check can never be
# confused with a prove-organs deploy regression — it says, in words, that the
# artifact itself vanished.
#
# Pure registry inspection (anonymous GHCR bearer token, with an optional PAT via
# GHCR_BEARER for the org actor) — no cluster, no docker, no jq. Talks only to the
# image registry, exactly like the re-pin / pre-warm tooling.
#
# Usage:
#   scripts/probe-organ-image-present.sh [--organ amaru|sentra|yupana] [--root DIR]
#
#   --organ <name>  probe ONE retired organ. Omit to probe all three.
#   --root DIR      repo root to read the pins from (default: this repo).
#
# Environment:
#   GHCR_BEARER     optional GitHub token; when set, a repo-scoped pull token is
#                   requested with it (org actor) instead of an anonymous token.
#                   The retired organ images are public, so anonymous works too.
#   PROBE_CONNECT_TIMEOUT   curl --connect-timeout seconds (default: 20).
#   PROBE_MAX_TIME          curl --max-time seconds per request (default: 30).
#
# This script is source-safe: sourcing it defines the functions WITHOUT running
# main(), which the companion self-test (probe-organ-image-present.test.sh) relies
# on to exercise the pure logic offline by overriding ghcr_status().

set -uo pipefail

REGISTRY_HOST="ghcr.io"
REGISTRY_BASE="szl-holdings"
# The three RETIRED organs whose source repos are deleted (404). a11oy/killinchu
# are intentionally excluded: they are actively rebuilt, their source lives, and
# their pin drift is already covered by organ-pin-drift-guard.
RETIRED_ORGANS="amaru sentra yupana"

PROBE_CONNECT_TIMEOUT="${PROBE_CONNECT_TIMEOUT:-20}"
PROBE_MAX_TIME="${PROBE_MAX_TIME:-30}"

MANIFEST_ACCEPT="application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.v2+json,application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json"

log()  { echo "[organ-image-probe] $*"; }
warn() { echo "[organ-image-probe] WARNING: $*" >&2; }
err()  { echo "[organ-image-probe] ERROR: $*" >&2; }

# read_pin <organ> <root> — echo the sha256:<hex> digest pinned in
# packages/<organ>/zarf.yaml. The metadata `image:` line and the workload
# `images:` entry carry the SAME @sha256 digest; we read the first @sha256 we
# find. Echoes nothing (rc 1) if no pin is present.
read_pin() {
  local organ="$1" root="$2"
  local f="$root/packages/$organ/zarf.yaml"
  if [ ! -f "$f" ]; then
    err "pin file not found: $f"
    return 1
  fi
  local dig
  dig="$(grep -m1 -oE '@sha256:[0-9a-f]{64}' "$f" 2>/dev/null | sed 's/^@//' || true)"
  if [ -z "$dig" ]; then
    err "no @sha256 digest pin found in $f"
    return 1
  fi
  printf '%s' "$dig"
}

# fetch_token <repo> — echo a GHCR bearer token scoped to pull <repo>. Uses
# GHCR_BEARER (a GitHub token) when set, else an anonymous token (the retired
# organ packages are public). Echoes empty on failure.
fetch_token() {
  local repo="$1"
  local url="https://${REGISTRY_HOST}/token?service=${REGISTRY_HOST}&scope=repository:${repo}:pull"
  local resp
  if [ -n "${GHCR_BEARER:-}" ]; then
    resp="$(curl -fsSL --connect-timeout "$PROBE_CONNECT_TIMEOUT" --max-time "$PROBE_MAX_TIME" \
      -u "x-access-token:${GHCR_BEARER}" "$url" 2>/dev/null)" || resp=""
  else
    resp="$(curl -fsSL --connect-timeout "$PROBE_CONNECT_TIMEOUT" --max-time "$PROBE_MAX_TIME" \
      "$url" 2>/dev/null)" || resp=""
  fi
  printf '%s' "$resp" | python3 -c 'import sys,json
try:
    d=json.load(sys.stdin); print(d.get("token") or d.get("access_token") or "")
except Exception:
    print("")'
}

# ghcr_status <repo> <reference> — echo the HTTP status code for a HEAD of the
# manifest <reference> (a digest or a tag) under <repo>. "000" means the request
# could not be made at all (network/token failure). Overridden by the offline
# self-test to simulate registry states without touching the network.
ghcr_status() {
  local repo="$1" reference="$2"
  local tok; tok="$(fetch_token "$repo")"
  if [ -z "$tok" ]; then
    # Retry anonymously once in case a bad GHCR_BEARER poisoned the token fetch.
    local saved="${GHCR_BEARER:-}"; GHCR_BEARER=""
    tok="$(fetch_token "$repo")"; GHCR_BEARER="$saved"
  fi
  local code
  code="$(curl -sI -o /dev/null -w '%{http_code}' \
            --connect-timeout "$PROBE_CONNECT_TIMEOUT" --max-time "$PROBE_MAX_TIME" \
            ${tok:+-H "Authorization: Bearer ${tok}"} \
            -H "Accept: ${MANIFEST_ACCEPT}" \
            "https://${REGISTRY_HOST}/v2/${repo}/manifests/${reference}" 2>/dev/null || echo 000)"
  printf '%s' "$code"
}

# classify_image <organ> <repo> <digest> <code>
# Map a manifest HTTP code to a verdict line. Prints the line; returns 0 if the
# image is present, non-zero on any disappearance/privatization.
classify_image() {
  local organ="$1" repo="$2" digest="$3" code="$4"
  case "$code" in
    200|203)
      return 0 ;;
    404|410)
      echo "IMAGE MISSING / PRIVATE: ${organ} image ${REGISTRY_HOST}/${repo}@${digest} returned HTTP ${code} (garbage-collected or deleted from GHCR). The source repo is gone, so this artifact is UNRECOVERABLE. This is NOT a deploy regression."
      return 1 ;;
    401|403)
      echo "IMAGE MISSING / PRIVATE: ${organ} image ${REGISTRY_HOST}/${repo}@${digest} returned HTTP ${code} (the package was made private / pull access was revoked). This is NOT a deploy regression."
      return 1 ;;
    000)
      echo "IMAGE PROBE INCONCLUSIVE: ${organ} image ${REGISTRY_HOST}/${repo}@${digest} could not be reached (network/token failure, HTTP 000). Treating as a disappearance to stay loud-not-silent; re-run to confirm."
      return 1 ;;
    *)
      echo "IMAGE MISSING / PRIVATE: ${organ} image ${REGISTRY_HOST}/${repo}@${digest} returned unexpected HTTP ${code}. Treating as a disappearance. This is NOT a deploy regression."
      return 1 ;;
  esac
}

# classify_sig <organ> <repo> <hex> <code>
# Map the cosign signature-tag HTTP code to a verdict line.
classify_sig() {
  local organ="$1" repo="$2" hex="$3" code="$4"
  case "$code" in
    200|203)
      return 0 ;;
    404|410)
      echo "SIGNATURE MISSING: ${organ} cosign signature tag ${REGISTRY_HOST}/${repo}:sha256-${hex}.sig returned HTTP ${code} — the image is present but its cosign signature has disappeared. cosign verification of this organ will now fail. This is NOT a deploy regression."
      return 1 ;;
    401|403)
      echo "SIGNATURE MISSING: ${organ} cosign signature tag ${REGISTRY_HOST}/${repo}:sha256-${hex}.sig returned HTTP ${code} (privatized / access revoked). This is NOT a deploy regression."
      return 1 ;;
    000)
      echo "SIGNATURE PROBE INCONCLUSIVE: ${organ} cosign signature tag ${REGISTRY_HOST}/${repo}:sha256-${hex}.sig could not be reached (HTTP 000). Treating as a disappearance to stay loud-not-silent; re-run to confirm."
      return 1 ;;
    *)
      echo "SIGNATURE MISSING: ${organ} cosign signature tag ${REGISTRY_HOST}/${repo}:sha256-${hex}.sig returned unexpected HTTP ${code}. Treating as a disappearance. This is NOT a deploy regression."
      return 1 ;;
  esac
}

# probe_organ <organ> <root> — probe one retired organ's image + cosign sig.
# Prints OK on success or the distinct MISSING verdict(s) on failure. Returns 0
# only if BOTH the image and its signature are present.
probe_organ() {
  local organ="$1" root="$2"
  local repo="${REGISTRY_BASE}/${organ}"
  local digest hex rc=0
  digest="$(read_pin "$organ" "$root")" || return 1
  hex="${digest#sha256:}"

  local mcode; mcode="$(ghcr_status "$repo" "$digest")"
  local mline
  if ! mline="$(classify_image "$organ" "$repo" "$digest" "$mcode")"; then
    echo "$mline"
    # The image is gone/private — the .sig probe would just echo the same access
    # failure, so report the image disappearance as the authoritative verdict.
    return 1
  fi

  local scode; scode="$(ghcr_status "$repo" "sha256-${hex}.sig")"
  local sline
  if ! sline="$(classify_sig "$organ" "$repo" "$hex" "$scode")"; then
    echo "$sline"
    rc=1
  fi

  if [ "$rc" -eq 0 ]; then
    echo "OK: ${organ} image + cosign signature present (${REGISTRY_HOST}/${repo}@${digest})"
  fi
  return "$rc"
}

# main [--organ X] [--root DIR]
main() {
  local organ="" root=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --organ) organ="${2:-}"; shift 2 ;;
      --root)  root="${2:-}"; shift 2 ;;
      -h|--help)
        sed -n '2,40p' "${BASH_SOURCE[0]}"; return 0 ;;
      *) err "unknown argument: $1"; return 2 ;;
    esac
  done
  if [ -z "$root" ]; then
    root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  fi

  local organs="$RETIRED_ORGANS"
  if [ -n "$organ" ]; then
    case " $RETIRED_ORGANS " in
      *" $organ "*) organs="$organ" ;;
      *) err "unknown retired organ: $organ (want one of: $RETIRED_ORGANS)"; return 2 ;;
    esac
  fi

  log "probing retired-organ images under ${REGISTRY_HOST}/${REGISTRY_BASE}: ${organs}"
  local overall=0 o
  for o in $organs; do
    echo "::group::probe ${o}"
    if ! probe_organ "$o" "$root"; then
      overall=1
    fi
    echo "::endgroup::"
  done

  if [ "$overall" -eq 0 ]; then
    log "all retired-organ images and cosign signatures are present."
  else
    err "one or more retired-organ images or signatures DISAPPEARED — see the IMAGE MISSING / SIGNATURE MISSING line(s) above. This is NOT a deploy regression."
  fi
  return "$overall"
}

# Only run main when executed directly (sourcing exposes the helpers for tests).
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
  exit $?
fi
