#!/usr/bin/env bash
# Copyright 2026 SZL Holdings
# SPDX-License-Identifier: Apache-2.0
#
# bump-receipts-version.sh — one-command, can't-drift version bump for szl-receipts.
#
# WHY THIS EXISTS
# ---------------
# The szl-receipts version is written in SEVERAL places that must move in lockstep,
# or a fresh clone installs the wrong thing AND `main` goes red on multiple CI
# checks (version-coherence-guard.yml, the clean-deploy self-test, the image-pin
# guards). A routine repin once bumped only SOME of those references and left main
# red on four checks at once. This script PERFORMS the bump everywhere at once so
# that whole class of failure cannot recur. Run it instead of hand-editing files.
#
# SURFACES IT UPDATES (in lockstep)
# ---------------------------------
#   1. charts/szl-receipts/Chart.yaml    -> version AND appVersion
#   2. charts/szl-receipts/values.yaml   -> server.image.tag (uds-v<version>)
#                                           server.image.digest (the @sha256 pin)
#   3. packages/szl-receipts/zarf.yaml   -> the server image ref
#        ghcr.io/szl-holdings/szl-receipts-server:uds-v<version>@sha256:<digest>
#   4. zarf.yaml (repo root)             -> the SAME server image ref (kept
#        byte-identical to #3, exactly as scripts/pin-receipts-image-digest.sh does)
#   5. scripts/clean-deploy-checks.sh    -> the HARDCODED expected tag literal
#        asserted by inv4 (the clean-deploy self-test pins the tag independently of
#        the coherence guard — defense in depth — so it must be bumped too).
#
# The image.digest is updated in values.yaml AND both zarf.yaml files so they stay
# byte-identical (image-pin-guard's chart-zarf-digest-match subcommand asserts
# this); use the linux/amd64 CHILD digest of the freshly published image, never the
# multi-arch index digest.
#
# NOT TOUCHED (intentionally):
#   * scripts/clean-deploy-checks.test.sh is version-AGNOSTIC by design (its inv4
#     negative fixture downgrades whatever the current tag is), so a bump never
#     needs to edit the self-test.
#   * Historical / proof records: warhacker-deliverables/*.md, dated proof
#     artifacts, tests/fixtures/cosign-identity-pin/* — rewriting these would be
#     dishonest, so they are left as-is.
#
# USAGE
# -----
#   scripts/bump-receipts-version.sh [--dry-run] <new-version> <new-digest>
#   scripts/bump-receipts-version.sh --check
#
#     <new-version>  semantic version like 0.4.2 (no leading 'v' / 'uds-v').
#     <new-digest>   the linux/amd64 child digest of the newly published
#                    ghcr.io/szl-holdings/szl-receipts-server:uds-v<new-version>
#                    image, with or without the 'sha256:' prefix.
#     --dry-run      show the unified diff that WOULD be applied; write nothing.
#     --check        do not edit; verify the surfaces above already AGREE
#                    (tag + digest coherent) and exit non-zero if they do not,
#                    printing the exact command to fix it. Run this before pushing.
#
# Publishing the image is a SEPARATE step (push tag receipts-server-v<version> ->
# receipts-server-image.yml builds + cosign-signs the ghcr image). Resolve the
# published child digest, then run this script.
#
# After running, verify with:  scripts/bump-receipts-version.sh --check && git diff
set -euo pipefail

die() { echo "error: $*" >&2; exit 1; }

# ── Locate the repo root relative to this script (scripts/..) ─────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

CHART="$ROOT/charts/szl-receipts/Chart.yaml"
VALUES="$ROOT/charts/szl-receipts/values.yaml"
PKG_ZARF="$ROOT/packages/szl-receipts/zarf.yaml"
ROOT_ZARF="$ROOT/zarf.yaml"
CLEAN="$ROOT/scripts/clean-deploy-checks.sh"

REPO_IMG="ghcr.io/szl-holdings/szl-receipts-server"

usage() {
  sed -n '1,/^set -euo pipefail$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//; /^set -euo pipefail$/d'
}

# ── Readers (used by --check and to learn the OLD version before editing) ─────

# Top-level appVersion scalar from Chart.yaml (unquoted).
read_chart_appversion() {
  grep -E '^appVersion:' "$CHART" | head -1 \
    | sed -E 's/^appVersion:[[:space:]]*//; s/^"(.*)"$/\1/; s/^'\''(.*)'\''$/\1/; s/[[:space:]]*$//'
}
# Top-level version scalar from Chart.yaml (unquoted).
read_chart_version() {
  grep -E '^version:' "$CHART" | head -1 \
    | sed -E 's/^version:[[:space:]]*//; s/^"(.*)"$/\1/; s/^'\''(.*)'\''$/\1/; s/[[:space:]]*$//'
}
# server.image.tag from values.yaml (top-level server: block only, never the nginx ui block).
read_values_tag() {
  awk '
    /^server:[[:space:]]*$/ { in_s=1; next }
    in_s && /^[^[:space:]#]/ { exit }
    in_s {
      if ($0 ~ /^[[:space:]]+image:[[:space:]]*$/) { match($0,/^[[:space:]]*/); ii=RLENGTH; in_i=1; next }
      if (in_i) {
        if ($0 ~ /^[[:space:]]*$/) next
        match($0,/^[[:space:]]*/); if (RLENGTH<=ii) { in_i=0 }
        else if ($0 ~ /^[[:space:]]+tag:/) { line=$0; sub(/^[[:space:]]+tag:[[:space:]]*/,"",line); gsub(/"/,"",line); print line; exit }
      }
    }' "$VALUES"
}
# server.image.digest from values.yaml (same scoping as the tag).
read_values_digest() {
  awk '
    /^server:[[:space:]]*$/ { in_s=1; next }
    in_s && /^[^[:space:]#]/ { exit }
    in_s {
      if ($0 ~ /^[[:space:]]+image:[[:space:]]*$/) { match($0,/^[[:space:]]*/); ii=RLENGTH; in_i=1; next }
      if (in_i) {
        if ($0 ~ /^[[:space:]]*$/) next
        match($0,/^[[:space:]]*/); if (RLENGTH<=ii) { in_i=0 }
        else if ($0 ~ /^[[:space:]]+digest:/) { line=$0; sub(/^[[:space:]]+digest:[[:space:]]*/,"",line); gsub(/"/,"",line); print line; exit }
      }
    }' "$VALUES"
}
# Tag of the szl-receipts-server image ref in a zarf file.
read_zarf_tag() {
  grep -oE "${REPO_IMG}:uds-v[0-9]+\.[0-9]+\.[0-9]+" "$1" | head -1 | sed -E "s#.*:##"
}
# Digest of the szl-receipts-server image ref in a zarf file.
read_zarf_digest() {
  grep -oE "${REPO_IMG}:[^@[:space:]]+@sha256:[0-9a-f]{64}" "$1" | head -1 | sed -E 's/.*@//'
}
# The hardcoded expected tag asserted by clean-deploy-checks.sh inv4. The literal
# lives inside a grep -E regex with backslash-escaped dots; strip backslashes first.
read_clean_tag() {
  sed 's/\\//g' "$CLEAN" | grep -oE "${REPO_IMG}:uds-v[0-9]+\.[0-9]+\.[0-9]+" | head -1 | sed -E "s#.*:##"
}

# ── Argument parsing ─────────────────────────────────────────────────────────
MODE="apply"
ARGS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --check)   MODE="check"; shift ;;
    --dry-run) MODE="dry-run"; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; while [ "$#" -gt 0 ]; do ARGS+=("$1"); shift; done ;;
    -*) die "unknown flag: $1" ;;
    *)  ARGS+=("$1"); shift ;;
  esac
done

for f in "$CHART" "$VALUES" "$PKG_ZARF" "$ROOT_ZARF" "$CLEAN"; do
  [ -f "$f" ] || die "missing required file: $f"
done

# ── --check: verify the surfaces already agree, then exit ────────────────────
if [ "$MODE" = "check" ]; then
  [ "${#ARGS[@]}" -eq 0 ] || die "--check takes no positional arguments"

  v="$(read_chart_version)";     av="$(read_chart_appversion)"
  vtag="$(read_values_tag)";     vdig="$(read_values_digest)"
  ptag="$(read_zarf_tag "$PKG_ZARF")";   pdig="$(read_zarf_digest "$PKG_ZARF")"
  rtag="$(read_zarf_tag "$ROOT_ZARF")";  rdig="$(read_zarf_digest "$ROOT_ZARF")"
  ctag="$(read_clean_tag)"

  [ -n "$av" ] || die "could not read Chart.yaml appVersion"
  expected_tag="uds-v${av}"

  rc=0
  problem() { echo "  MISMATCH: $*" >&2; rc=1; }

  echo "szl-receipts version coherence check"
  echo "  Chart.yaml      version=${v:-<none>}  appVersion=${av:-<none>}"
  echo "  expected tag    ${expected_tag}"
  echo "  values.yaml     tag=${vtag:-<none>}  digest=${vdig:-<none>}"
  echo "  packages/zarf   tag=${ptag:-<none>}  digest=${pdig:-<none>}"
  echo "  root zarf.yaml  tag=${rtag:-<none>}  digest=${rdig:-<none>}"
  echo "  clean-deploy    tag=${ctag:-<none>}  (hardcoded inv4 literal)"

  [ "$v"  = "$av" ]            || problem "Chart.yaml version ('$v') != appVersion ('$av')"
  [ "$vtag" = "$expected_tag" ] || problem "values.yaml server.image.tag ('$vtag') != '$expected_tag'"
  [ "$ptag" = "$expected_tag" ] || problem "packages/szl-receipts/zarf.yaml tag ('$ptag') != '$expected_tag'"
  [ "$rtag" = "$expected_tag" ] || problem "zarf.yaml (root) tag ('$rtag') != '$expected_tag'"
  [ "$ctag" = "$expected_tag" ] || problem "scripts/clean-deploy-checks.sh hardcoded tag ('$ctag') != '$expected_tag'"

  # Digests must be identical across the three image-ref sites.
  [ -n "$vdig" ] || problem "values.yaml server.image.digest is empty"
  [ "$vdig" = "$pdig" ] || problem "values.yaml digest ('$vdig') != packages/zarf digest ('$pdig')"
  [ "$vdig" = "$rdig" ] || problem "values.yaml digest ('$vdig') != root zarf digest ('$rdig')"

  if [ "$rc" -eq 0 ]; then
    echo "OK: all szl-receipts version surfaces agree on ${expected_tag} @ ${vdig}."
  else
    echo "::error::szl-receipts version surfaces DISAGREE." >&2
    echo "Fix with: scripts/bump-receipts-version.sh ${av} ${vdig:-<digest>}" >&2
  fi
  exit "$rc"
fi

# ── apply / dry-run: need <new-version> <new-digest> ─────────────────────────
[ "${#ARGS[@]}" -eq 2 ] || die "usage: $(basename "$0") [--dry-run] <new-version> <new-digest>
  e.g. $(basename "$0") 0.4.2 sha256:758052db66fd6257e4ac6b9834918df25dc819097beb387062b9e54e6cd8f0f4
       $(basename "$0") --check"

VERSION="${ARGS[0]}"
DIGEST_ARG="${ARGS[1]}"

# new-version: bare semver, no leading v/uds-v (those are derived).
echo "$VERSION" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$' \
  || die "new-version '$VERSION' must be a bare semver like 0.4.2 (no leading 'v' or 'uds-v')."

# new-digest: accept with or without sha256: prefix; require 64 lowercase hex.
HEX="${DIGEST_ARG#sha256:}"
echo "$HEX" | grep -qE '^[0-9a-f]{64}$' \
  || die "new-digest '$DIGEST_ARG' must be a sha256 digest (64 hex chars, optional 'sha256:' prefix)."

TAG="uds-v${VERSION}"
DIGEST="sha256:${HEX}"
REF="${REPO_IMG}:${TAG}@${DIGEST}"

# Learn the OLD version (from Chart.yaml) so we can bump the hardcoded literal in
# clean-deploy-checks.sh by find/replace.
OLD="$(read_chart_appversion)"
[ -n "$OLD" ] || die "could not read current appVersion from $CHART"

echo "Bumping szl-receipts: ${OLD} -> ${VERSION}  (tag=${TAG}, digest=${DIGEST})"

# ── Edit functions (operate on real file paths) ──────────────────────────────
edit_chart() {
  local tmp; tmp="$(mktemp)"
  sed -E \
    -e "s/^version:.*/version: ${VERSION}/" \
    -e "s/^appVersion:.*/appVersion: \"${VERSION}\"/" \
    "$CHART" > "$tmp" && mv "$tmp" "$CHART"
}

edit_values() {
  local tmp; tmp="$(mktemp)"
  awk -v newtag="$TAG" -v newdigest="$DIGEST" '
  {
    line=$0
    if (line ~ /^server:[[:space:]]*$/) { in_s=1; in_img=0; print; next }
    if (in_s && line ~ /^[^[:space:]#]/) { in_s=0; in_img=0 }
    if (in_s) {
      if (line ~ /^[[:space:]]+image:[[:space:]]*$/) { match(line,/^[[:space:]]*/); img_indent=RLENGTH; in_img=1; print; next }
      if (in_img) {
        if (line ~ /^[[:space:]]*$/) { print; next }
        match(line,/^[[:space:]]*/); ind=RLENGTH
        if (ind <= img_indent) { in_img=0 }
        else {
          pad=substr(line,1,RLENGTH)
          if (line ~ /^[[:space:]]+tag:/)    { print pad "tag: \"" newtag "\"";       tagdone=1; next }
          if (line ~ /^[[:space:]]+digest:/) { print pad "digest: \"" newdigest "\""; digdone=1; next }
        }
      }
    }
    print
  }
  END {
    if (!tagdone) { print "BUMP_ERR: server.image.tag not found" > "/dev/stderr"; exit 3 }
    if (!digdone) { print "BUMP_ERR: server.image.digest not found" > "/dev/stderr"; exit 3 }
  }' "$VALUES" > "$tmp" || die "failed to update $VALUES (server image tag/digest not found)"
  mv "$tmp" "$VALUES"
}

# Rewrite the szl-receipts-server image ref (tag@digest) in a zarf file.
edit_zarf() {
  local file="$1" tmp; tmp="$(mktemp)"
  sed -E "s#(${REPO_IMG}:)[^@[:space:]]+@sha256:[0-9a-f]{64}#\1${TAG}@${DIGEST}#g" "$file" > "$tmp" && mv "$tmp" "$file"
  grep -Fq "$REF" "$file" || die "failed to update $file — expected image ref not present after edit:
  $REF"
}

# Bump the hardcoded expected tag literal in clean-deploy-checks.sh. The literal
# appears both as a backslash-escaped regex (uds-v0\.4\.1, inside grep -E '...') and
# as plain prose in comments/messages (uds-v0.4.1). Replace both forms verbatim.
edit_clean() {
  python3 - "$CLEAN" "$OLD" "$VERSION" <<'PY' || die "failed to bump hardcoded tag in clean-deploy-checks.sh"
import sys
path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(path).read()
old_esc, new_esc = "uds-v" + old.replace(".", r"\."), "uds-v" + new.replace(".", r"\.")
old_plain, new_plain = "uds-v" + old, "uds-v" + new
n_esc = s.count(old_esc)
s = s.replace(old_esc, new_esc)          # backslash-escaped regex form (the load-bearing grep)
n_plain = s.count(old_plain)
s = s.replace(old_plain, new_plain)      # plain prose in comments / error messages
open(path, "w").write(s)
if n_esc == 0:
    sys.stderr.write("BUMP_ERR: escaped grep literal '%s' not found in %s\n" % (old_esc, path)); sys.exit(3)
print("  clean-deploy-checks.sh: bumped %d regex + %d prose occurrence(s)" % (n_esc, n_plain))
PY
}

apply_all() {
  edit_chart
  edit_values
  edit_zarf "$PKG_ZARF"
  edit_zarf "$ROOT_ZARF"
  edit_clean
}

if [ "$MODE" = "dry-run" ]; then
  echo "DRY RUN — no files will be written. Proposed changes:"
  FILES=("$CHART" "$VALUES" "$PKG_ZARF" "$ROOT_ZARF" "$CLEAN")
  declare -A BAK
  for f in "${FILES[@]}"; do BAK["$f"]="$(mktemp)"; cp "$f" "${BAK[$f]}"; done
  restore() { for f in "${FILES[@]}"; do cp "${BAK[$f]}" "$f"; rm -f "${BAK[$f]}"; done; }
  trap restore EXIT
  apply_all >/dev/null
  for f in "${FILES[@]}"; do
    if ! diff -q "${BAK[$f]}" "$f" >/dev/null 2>&1; then
      echo "----- ${f#$ROOT/} -----"
      diff -u "${BAK[$f]}" "$f" | sed "1,2d" || true
    fi
  done
  echo "(dry run) re-run without --dry-run to apply, then: scripts/bump-receipts-version.sh --check"
  exit 0
fi

# ── apply ────────────────────────────────────────────────────────────────────
apply_all

echo "OK. Updated in lockstep:"
echo "  ${CHART#$ROOT/}            (version + appVersion = ${VERSION})"
echo "  ${VALUES#$ROOT/}     (server.image.tag = ${TAG}, digest = ${DIGEST})"
echo "  ${PKG_ZARF#$ROOT/}   (image ref = ${REF})"
echo "  ${ROOT_ZARF#$ROOT/}                       (image ref = ${REF})"
echo "  ${CLEAN#$ROOT/}   (hardcoded inv4 tag = ${TAG})"
echo
echo "Verifying coherence..."
bash "${BASH_SOURCE[0]}" --check
echo
echo "Next: review 'git diff', then commit. CI (version-coherence-guard + clean-deploy self-test) passes with no manual edits."
