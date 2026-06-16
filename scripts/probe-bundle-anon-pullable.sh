# Copyright 2026 SZL Holdings
# SPDX-License-Identifier: Apache-2.0
#
# probe-bundle-anon-pullable.sh — Fail LOUDLY (with a distinct, greppable
# verdict) if the PUBLIC one-command install bundle ever stops being
# *anonymously* pullable from GHCR.
#
# WHY THIS EXISTS
# ---------------
# `oci://ghcr.io/szl-holdings/szl-uds-bundle:uds-v0.2.0` (and the current
# `uds-v0.3.0`) is documented as the one-command UDS install:
#     uds deploy oci://ghcr.io/szl-holdings/szl-uds-bundle:uds-v0.2.0 --confirm
# That command, and the documented `cosign verify` / `gh attestation verify`
# story, all rely on the bundle manifest AND its cosign signature (.sig) AND its
# SBOM attestation (.att) being pullable WITH NO CREDENTIALS.
#
# GHCR package visibility can be silently flipped back to private from the web UI
# — there is no REST API to read/set it — which would make the documented
# anonymous `uds pull` / `uds deploy` 401/403 with NO warning. Existing prior art
# does not catch this:
#   * scripts/oci-ref-checks.py resolves deploy/publish refs but FALLS BACK to a
#     repo PAT, so it stays green for a published-but-now-PRIVATE ref (it even
#     classifies that as OK_PRIVATE). That is the opposite of what we need here.
#   * scripts/probe-organ-image-present.sh checks the RETIRED-organ images and
#     accepts an org PAT (GHCR_BEARER) too.
# This probe is deliberately different: it asserts *anonymous* pullability
# specifically. It uses ONLY an anonymous GHCR pull token (no Authorization
# credential is ever sent) and there is NO PAT fallback — so a privatized bundle
# turns this red, which is the whole point.
#
# WHAT IT CHECKS
# For each configured bundle tag it:
#   * requests an ANONYMOUS GHCR pull token (no -u / no Authorization),
#   * HEADs the bundle manifest by tag  -> must be 200,
#   * resolves the manifest digest (Docker-Content-Digest), then HEADs the
#     cosign signature   tag sha256-<hex>.sig  -> must be 200,
#     cosign attestation tag sha256-<hex>.att  -> must be 200,
# all anonymously, and emits a distinct, greppable verdict on any non-200:
#     "BUNDLE NOT ANON-PULLABLE: ..."        (manifest gone / 401 / 403 / 404)
#     "SIGNATURE NOT ANON-PULLABLE: ..."     (.sig gone / privatized)
#     "ATTESTATION NOT ANON-PULLABLE: ..."   (.att gone / privatized)
#     "BUNDLE PROBE INCONCLUSIVE: ..."       (HTTP 000 — loud-not-silent)
# It exits non-zero on any disappearance/privatization.
#
# Pure registry inspection (anonymous GHCR bearer token only) — no cluster, no
# docker, no jq. Talks only to the image registry.
#
# Usage:
#   scripts/probe-bundle-anon-pullable.sh [--ref uds-vX.Y.Z] [--repo R]
#
#   --ref <tag>   probe ONE bundle tag. Repeatable. Omit to probe every tag in
#                 BUNDLE_REFS (the documented install refs).
#   --repo <R>    GHCR repo path (default: szl-holdings/szl-uds-bundle).
#
# Environment:
#   BUNDLE_REFS             space-separated default tags to probe
#                           (default: "uds-v0.2.0 uds-v0.3.0").
#   PROBE_CONNECT_TIMEOUT   curl --connect-timeout seconds (default: 20).
#   PROBE_MAX_TIME          curl --max-time seconds per request (default: 30).
#
# NOTE: NO token env var is consulted. This probe is anonymous BY DESIGN; adding
# a PAT fallback would defeat its purpose (it would stay green on a privatized
# package). The companion self-test asserts a privatized/404 ref FAILS.
#
# This script is source-safe: sourcing it defines the functions WITHOUT running
# main(), which the companion self-test (probe-bundle-anon-pullable.test.sh)
# relies on to exercise the pure logic offline by overriding anon_ghcr_status()
# and anon_ghcr_digest().

set -uo pipefail

REGISTRY_HOST="ghcr.io"
DEFAULT_REPO="szl-holdings/szl-uds-bundle"

# The documented one-command-install bundle tags. uds-v0.2.0 is the ref this task
# made public + documented in bundles/szl-uds-bundle/uds-bundle.yaml; uds-v0.3.0
# is the current runbook ref (UDS_DEPLOY_RUNBOOK.md / prove-* tasks). Both are
# anonymously pullable and carry a cosign .sig AND an SBOM .att today. Override
# via the BUNDLE_REFS env or --ref to track the published install ref over time.
BUNDLE_REFS="${BUNDLE_REFS:-uds-v0.2.0 uds-v0.3.0}"

PROBE_CONNECT_TIMEOUT="${PROBE_CONNECT_TIMEOUT:-20}"
PROBE_MAX_TIME="${PROBE_MAX_TIME:-30}"

MANIFEST_ACCEPT="application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.v2+json,application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json"

log()  { echo "[bundle-anon-probe] $*"; }
warn() { echo "[bundle-anon-probe] WARNING: $*" >&2; }
err()  { echo "[bundle-anon-probe] ERROR: $*" >&2; }

# anon_token <repo> — echo a GHCR bearer token scoped to pull <repo>, requested
# ANONYMOUSLY (no credentials). For a PUBLIC package this token grants pull; for
# a PRIVATE package the anonymous token lacks the pull grant, so the subsequent
# manifest HEAD returns 401/403 — which is exactly the regression we want to
# catch. Echoes empty on failure.
anon_token() {
  local repo="$1"
  local url="https://${REGISTRY_HOST}/token?service=${REGISTRY_HOST}&scope=repository:${repo}:pull"
  local resp
  resp="$(curl -fsSL --connect-timeout "$PROBE_CONNECT_TIMEOUT" --max-time "$PROBE_MAX_TIME" \
    "$url" 2>/dev/null)" || resp=""
  printf '%s' "$resp" | python3 -c 'import sys,json
try:
    d=json.load(sys.stdin); print(d.get("token") or d.get("access_token") or "")
except Exception:
    print("")'
}

# anon_ghcr_status <repo> <reference> — echo the HTTP status code for an
# ANONYMOUS HEAD of the manifest <reference> (a tag or a digest) under <repo>.
# "000" means the request could not be made at all (network/token failure).
# Overridden by the offline self-test to simulate registry states.
anon_ghcr_status() {
  local repo="$1" reference="$2"
  local tok; tok="$(anon_token "$repo")"
  local code
  code="$(curl -sI -o /dev/null -w '%{http_code}' \
            --connect-timeout "$PROBE_CONNECT_TIMEOUT" --max-time "$PROBE_MAX_TIME" \
            ${tok:+-H "Authorization: Bearer ${tok}"} \
            -H "Accept: ${MANIFEST_ACCEPT}" \
            "https://${REGISTRY_HOST}/v2/${repo}/manifests/${reference}" 2>/dev/null || echo 000)"
  printf '%s' "$code"
}

# anon_ghcr_digest <repo> <reference> — echo the sha256:<hex> the registry
# resolves <reference> to (the Docker-Content-Digest header), ANONYMOUSLY. Echoes
# empty if it cannot be read. Overridden by the offline self-test.
anon_ghcr_digest() {
  local repo="$1" reference="$2"
  local tok; tok="$(anon_token "$repo")"
  curl -sI \
    --connect-timeout "$PROBE_CONNECT_TIMEOUT" --max-time "$PROBE_MAX_TIME" \
    ${tok:+-H "Authorization: Bearer ${tok}"} \
    -H "Accept: ${MANIFEST_ACCEPT}" \
    "https://${REGISTRY_HOST}/v2/${repo}/manifests/${reference}" 2>/dev/null \
    | tr -d '\r' | awk -F': ' 'tolower($1)=="docker-content-digest"{print $2; exit}'
}

# classify_anon <kind> <ref-desc> <code>
# Map an anonymous-HEAD HTTP code to a verdict line for component <kind> (one of
# BUNDLE / SIGNATURE / ATTESTATION). Prints the line; returns 0 if anon-pullable,
# non-zero on any disappearance/privatization. <ref-desc> is the human ref shown.
classify_anon() {
  local kind="$1" desc="$2" code="$3"
  case "$code" in
    200|203)
      return 0 ;;
    401|403)
      echo "${kind} NOT ANON-PULLABLE: ${desc} returned HTTP ${code} to an anonymous pull — the package was made PRIVATE / public pull access was revoked. The documented one-command \`uds deploy\` / \`uds pull\` (and anonymous \`cosign verify\`) would now FAIL with no credentials."
      return 1 ;;
    404|410)
      echo "${kind} NOT ANON-PULLABLE: ${desc} returned HTTP ${code} — it is gone from GHCR (deleted / garbage-collected / never published). The documented one-command anonymous install would now FAIL."
      return 1 ;;
    000)
      echo "${kind} PROBE INCONCLUSIVE: ${desc} could not be reached anonymously (network/token failure, HTTP 000). Treating as a regression to stay loud-not-silent; re-run to confirm."
      return 1 ;;
    *)
      echo "${kind} NOT ANON-PULLABLE: ${desc} returned unexpected HTTP ${code} to an anonymous pull. Treating as a regression of anonymous pullability."
      return 1 ;;
  esac
}

# probe_ref <repo> <tag> — probe one bundle tag: manifest + cosign .sig + .att,
# all ANONYMOUSLY. Prints OK on success or the distinct NOT-ANON-PULLABLE
# verdict(s) on failure. Returns 0 only if all three resolve anonymously.
probe_ref() {
  local repo="$1" tag="$2"
  local ref="${REGISTRY_HOST}/${repo}:${tag}"
  local rc=0

  local mcode; mcode="$(anon_ghcr_status "$repo" "$tag")"
  local mline
  if ! mline="$(classify_anon "BUNDLE" "bundle manifest ${ref}" "$mcode")"; then
    echo "$mline"
    # No anon manifest -> can't resolve a digest, and the .sig/.att HEADs would
    # just echo the same access failure. Report the manifest regression as the
    # authoritative verdict for this ref.
    return 1
  fi

  local digest; digest="$(anon_ghcr_digest "$repo" "$tag")"
  if [ -z "$digest" ]; then
    echo "BUNDLE PROBE INCONCLUSIVE: could not resolve the manifest digest for ${ref} anonymously (Docker-Content-Digest header missing) — cannot derive the cosign .sig/.att tags. Treating as a regression to stay loud-not-silent; re-run to confirm."
    return 1
  fi
  local hex="${digest#sha256:}"

  local scode; scode="$(anon_ghcr_status "$repo" "sha256-${hex}.sig")"
  local sline
  if ! sline="$(classify_anon "SIGNATURE" "cosign signature tag ${REGISTRY_HOST}/${repo}:sha256-${hex}.sig (for ${ref})" "$scode")"; then
    echo "$sline"
    rc=1
  fi

  local acode; acode="$(anon_ghcr_status "$repo" "sha256-${hex}.att")"
  local aline
  if ! aline="$(classify_anon "ATTESTATION" "SBOM attestation tag ${REGISTRY_HOST}/${repo}:sha256-${hex}.att (for ${ref})" "$acode")"; then
    echo "$aline"
    rc=1
  fi

  if [ "$rc" -eq 0 ]; then
    echo "OK: ${ref} manifest + cosign .sig + SBOM .att all anonymously pullable (digest ${digest})"
  fi
  return "$rc"
}

# main [--ref TAG]... [--repo R]
main() {
  local repo="$DEFAULT_REPO"
  local refs=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --ref)  refs="${refs} ${2:-}"; shift 2 ;;
      --repo) repo="${2:-}"; shift 2 ;;
      -h|--help)
        sed -n '2,45p' "${BASH_SOURCE[0]}"; return 0 ;;
      *) err "unknown argument: $1"; return 2 ;;
    esac
  done
  if [ -z "${refs// /}" ]; then
    refs="$BUNDLE_REFS"
  fi

  log "probing anonymous pullability of ${REGISTRY_HOST}/${repo} tags: ${refs}"
  local overall=0 t
  for t in $refs; do
    echo "::group::probe ${t}"
    if ! probe_ref "$repo" "$t"; then
      overall=1
    fi
    echo "::endgroup::"
  done

  if [ "$overall" -eq 0 ]; then
    log "all configured bundle tags + their cosign .sig/.att are anonymously pullable."
  else
    err "the public install bundle (or its cosign signature/attestation) is NO LONGER anonymously pullable — see the NOT ANON-PULLABLE line(s) above. The documented one-command \`uds deploy oci://...\` install is BROKEN for anonymous users."
  fi
  return "$overall"
}

# Only run main when executed directly (sourcing exposes the helpers for tests).
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
  exit $?
fi
