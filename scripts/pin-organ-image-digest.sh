# Copyright 2026 SZL Holdings
# SPDX-License-Identifier: Apache-2.0
#
# pin-organ-image-digest.sh — resolve the published a11oy / killinchu organ image
# digest for its pinned tag and pin it everywhere, so a rebuild never leaves the
# deployment files on a stale, hand-hunted @sha256 digest again.
#
# WHY THIS EXISTS
# ---------------
# The organ tags ghcr.io/szl-holdings/{a11oy,killinchu}:uds-vX.Y.Z are RE-PUSHED
# with a brand-new digest every time the app is rebuilt. The deployment files pin
# a specific @sha256 digest (so a re-pushed/mutated tag cannot change what runs),
# which means after any rebuild those pins silently go STALE: the deployed image
# no longer matches the tag's current contents. sibling guards already exist for
# the receipts-server image (pin-receipts-image-digest.sh); this is the organ
# equivalent so a re-pin is ONE command, not manual digest hunting, and the
# scheduled organ-pin-drift-guard can detect the drift automatically.
#
# WHAT IT PINS (per organ, discovered dynamically by the @sha256 pattern)
# ----------------------------------------------------------------------
#   * every  ghcr.io/szl-holdings/<organ>:<tag>@sha256:<digest>  ref in
#       packages/<organ>/zarf.yaml, packages/<organ>/zarf-mesh-ready.yaml,
#       packages/<organ>/manifests/*.yaml  (images: lists + manifest image: refs)
#   * the chart  image.digest: "sha256:<digest>"  scalar in
#       charts/<organ>/values.yaml  (a11oy only today; killinchu is tag-only)
#
# All organ pins use the SAME linux/amd64 CHILD manifest digest (organs are built
# single-arch; the chart digest comment in charts/a11oy/values.yaml is explicit
# that this is the amd64 child, NOT the OCI index). So one resolved digest per
# organ is pinned byte-identically across all files. If the tag is published as a
# multi-arch index, the linux/amd64 child is selected (the same digest zarf can
# consume); a single-arch manifest is used as-is.
#
# Usage:
#   scripts/pin-organ-image-digest.sh [--organ a11oy|killinchu] [--tag <tag>] \
#       [--check] [--root DIR] [--digest sha256:<hex>]
#
#   --organ <name>  organ to act on (a11oy|killinchu). Omit to act on BOTH
#                   (the default for --check; required for a re-pin).
#   --tag <tag>     image tag to resolve (default: the tag already pinned in the
#                   organ's deployment files).
#   --check         do not edit files; exit non-zero if any pinned digest differs
#                   from the published image, printing the exact fix command.
#   --root DIR      repo root to operate on (default: this script's repo root).
#   --digest D      use digest D as the "published" digest INSTEAD of resolving it
#                   live from GHCR. For OFFLINE self-tests only — never used in CI.
#
# Requires (live mode): docker buildx (imagetools), jq. Pure registry inspection
# — no cluster, airgap-friendly (only talks to the image registry).

set -euo pipefail

REGISTRY_BASE="ghcr.io/szl-holdings"
ALL_ORGANS="a11oy killinchu"

ORGAN=""
TAG=""
CHECK=0
ROOT=""
DIGEST_OVERRIDE=""

err() { echo "::error::$*" >&2; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --organ) ORGAN="${2:-}"; shift 2 ;;
    --tag) TAG="${2:-}"; shift 2 ;;
    --check) CHECK=1; shift ;;
    --root) ROOT="${2:-}"; shift 2 ;;
    --digest) DIGEST_OVERRIDE="${2:-}"; shift 2 ;;
    -h|--help) sed -n '1,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) err "unknown argument: $1"; exit 2 ;;
  esac
done

# Operate from the repo root so the relative paths below resolve regardless of cwd.
if [ -z "$ROOT" ]; then
  ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fi
cd "$ROOT"

# Validate --organ when given.
if [ -n "$ORGAN" ]; then
  case " $ALL_ORGANS " in
    *" $ORGAN "*) : ;;
    *) err "unknown organ: $ORGAN (want one of: $ALL_ORGANS)"; exit 2 ;;
  esac
fi

# A re-pin must target exactly one organ (and not use the offline override).
if [ "$CHECK" -eq 0 ]; then
  if [ -z "$ORGAN" ]; then
    err "a re-pin needs --organ <a11oy|killinchu> (only --check may default to both)"
    exit 2
  fi
fi

CHART_VALUES_FOR() { echo "charts/$1/values.yaml"; }

# ref_pin_files ORGAN — files holding a ghcr.io/szl-holdings/<organ>:<tag>@sha256:
# ref (images: lists + manifest image: refs). Discovered by the @sha256 pattern so
# a newly-added pin is covered automatically. Tag-only refs and comments (no
# @sha256) are intentionally NOT matched.
ref_pin_files() {
  local organ="$1"
  grep -rlE "${REGISTRY_BASE}/${organ}:[^@[:space:]\"]+@sha256:[0-9a-f]{64}" \
    --include="*.yaml" --include="*.yml" . 2>/dev/null | sort -u || true
}

# infer_tag ORGAN — the tag currently pinned in the organ's deployment files, or
# empty if none are pinned (must NOT abort under set -e/pipefail on no-match).
infer_tag() {
  local organ="$1" hit
  hit="$(grep -rhoE "${REGISTRY_BASE}/${organ}:[^@[:space:]\"]+@sha256:[0-9a-f]{64}" \
    --include="*.yaml" --include="*.yml" . 2>/dev/null | head -n1 || true)"
  printf '%s' "$hit" | sed -E "s#.*/${organ}:##; s#@sha256:.*##"
}

# chart_digest_file ORGAN — the chart values.yaml IF it pins an image.digest for
# this organ's repository, else empty.
chart_digest_file() {
  local organ="$1" vf
  vf="$(CHART_VALUES_FOR "$organ")"
  [ -f "$vf" ] || { echo ""; return 0; }
  if grep -qE "^[[:space:]]*repository:[[:space:]]*${REGISTRY_BASE}/${organ}([[:space:]\"]|$)" "$vf" \
     && grep -qE '^[[:space:]]*digest:[[:space:]]*"?sha256:[0-9a-f]{64}' "$vf"; then
    echo "$vf"
  else
    echo ""
  fi
}

# resolve_digest REF — the linux/amd64 child manifest digest (or the manifest
# itself when single-arch). Honors --digest for offline self-tests.
resolve_digest() {
  local ref="$1" raw d
  if [ -n "$DIGEST_OVERRIDE" ]; then
    printf '%s' "$DIGEST_OVERRIDE"
    return 0
  fi
  command -v jq >/dev/null 2>&1 || { err "jq is required"; return 2; }
  command -v docker >/dev/null 2>&1 || { err "docker (buildx imagetools) is required"; return 2; }
  raw="$(docker buildx imagetools inspect "$ref" --raw)" || { err "could not inspect $ref"; return 1; }
  if printf '%s' "$raw" | jq -e '.manifests' >/dev/null 2>&1; then
    d="$(printf '%s' "$raw" | jq -r '
      .manifests[]
      | select(.platform.os == "linux" and .platform.architecture == "amd64")
      | .digest' | head -n1)"
    [ -n "$d" ] && [ "$d" != "null" ] || { err "no linux/amd64 child manifest in index $ref"; return 1; }
  else
    d="$(docker buildx imagetools inspect "$ref" --format '{{.Manifest.Digest}}')"
  fi
  case "$d" in
    sha256:*) printf '%s' "$d" ;;
    *) err "could not resolve digest for $ref"; return 1 ;;
  esac
}

# ── check one organ ──────────────────────────────────────────────────────────
# Resolves the organ tag's CURRENT published digest and verifies every pinned
# occurrence (refs + chart scalar) matches it. Prints a STALE: summary line (the
# organ, tag and fix command) the workflow can parse. Returns 1 on drift.
check_organ() {
  local organ="$1" tag="$2" want ref files f rc=0 saw=0
  ref="${REGISTRY_BASE}/${organ}:${tag}"
  echo "Resolving published digest for ${ref}"
  want="$(resolve_digest "$ref")" || return 2
  echo "  published amd64 digest: ${want}"

  files="$(ref_pin_files "$organ")"
  for f in $files; do
    # every <organ>:<tag>@sha256:... occurrence in this file must equal want
    while IFS= read -r got; do
      [ -n "$got" ] || continue
      saw=1
      if [ "$got" != "$want" ]; then
        echo "::warning file=${f}::stale ${organ} digest ${got} (published is ${want})"
        rc=1
      fi
    done < <(grep -oE "${REGISTRY_BASE}/${organ}:${tag}@sha256:[0-9a-f]{64}" "$f" \
               | sed -E 's/.*@//')
  done

  # chart image.digest scalar (a11oy only today)
  local cf
  cf="$(chart_digest_file "$organ")"
  if [ -n "$cf" ]; then
    local cdig
    cdig="$(grep -oE '^[[:space:]]*digest:[[:space:]]*"?sha256:[0-9a-f]{64}' "$cf" \
             | head -n1 | grep -oE 'sha256:[0-9a-f]{64}')"
    saw=1
    if [ "$cdig" != "$want" ]; then
      echo "::warning file=${cf}::stale ${organ} chart image.digest ${cdig} (published is ${want})"
      rc=1
    fi
  fi

  if [ "$saw" -eq 0 ]; then
    err "no @sha256: pins found for ${organ} — either every pin lost its digest or the scan path is wrong"
    return 2
  fi

  if [ "$rc" -ne 0 ]; then
    echo "STALE: ${organ} ${tag} -> fix: scripts/pin-organ-image-digest.sh --organ ${organ}"
  else
    echo "OK: all ${organ} pins match the published ${ref}."
  fi
  return "$rc"
}

# ── re-pin one organ ─────────────────────────────────────────────────────────
repin_organ() {
  local organ="$1" tag="$2" want ref files f cf
  ref="${REGISTRY_BASE}/${organ}:${tag}"
  echo "Resolving published digest for ${ref}"
  want="$(resolve_digest "$ref")" || return 2
  echo "  published amd64 digest: ${want}"

  files="$(ref_pin_files "$organ")"
  for f in $files; do
    sed -E -i \
      "s#(${REGISTRY_BASE}/${organ}:${tag})@sha256:[0-9a-f]{64}#\1@${want}#g" \
      "$f"
    echo "  pinned refs in ${f}"
  done

  cf="$(chart_digest_file "$organ")"
  if [ -n "$cf" ]; then
    awk -v d="$want" -v repo="${REGISTRY_BASE}/${organ}" '
      $0 ~ ("repository:[[:space:]]*" repo "([[:space:]\"]|$)") { inblk=1 }
      inblk && /^[[:space:]]*digest:[[:space:]]*"?sha256:[0-9a-f]+/ {
        sub(/sha256:[0-9a-f]+/, d); inblk=0
      }
      { print }
    ' "$cf" > "${cf}.tmp" && mv "${cf}.tmp" "$cf"
    echo "  pinned chart image.digest in ${cf}"
  fi
  echo "Pinned ${organ}@${tag} -> ${want}"
}

# ── dispatch ─────────────────────────────────────────────────────────────────
organs="${ORGAN:-$ALL_ORGANS}"

if [ "$CHECK" -eq 1 ]; then
  rc=0
  for o in $organs; do
    t="$TAG"
    [ -n "$t" ] || t="$(infer_tag "$o")"
    if [ -z "$t" ]; then
      err "could not infer a pinned tag for ${o}; pass --tag"
      rc=2; continue
    fi
    check_organ "$o" "$t" || { c=$?; [ "$c" -gt "$rc" ] && rc=$c; }
  done
  if [ "$rc" -eq 1 ]; then
    echo "::warning::one or more organ pins are STALE vs the published image. Run the printed fix command(s) and commit."
  fi
  exit "$rc"
fi

# re-pin (single organ, validated above)
t="$TAG"
[ -n "$t" ] || t="$(infer_tag "$ORGAN")"
[ -n "$t" ] || { err "could not infer a pinned tag for ${ORGAN}; pass --tag"; exit 2; }
repin_organ "$ORGAN" "$t"
