# Copyright 2026 SZL Holdings
# SPDX-License-Identifier: Apache-2.0
#
# bundle-signer-identity-drift-guard-checks.sh — keep the cosign signer identity
# that the bundle-install PROOF expects in lockstep with the PUBLISH workflow's
# actual file path + trigger refs.
#
# WHY THIS EXISTS
# The prove-bundle proof (tasks/prove-bundle.yaml driven by
# .github/workflows/prove-bundle-install.yml) verifies the PUBLISHED bundle's
# keyless cosign signature against an EXACT signer identity:
#
#     https://github.com/szl-holdings/szl-uds-deployment/<WORKFLOW>@<REF>
#
# Both moving parts are HARD-CODED on the prove side:
#   * <WORKFLOW> — the publish workflow file path (.github/workflows/uds-bundle-publish.yml)
#   * <REF>      — the git ref the publish run signed on. Today the bundle is
#                  DISPATCH-published, so it is signed on refs/heads/main (no
#                  uds-v* git tag is cut); the harness ALSO tries a refs/tags/<tag>
#                  identity so a future tag-published bundle still verifies.
#
# A keyless cosign cert-identity is derived by Fulcio from the OIDC token's
# job_workflow_ref at SIGN time — i.e. from the ACTUAL publish workflow file path
# and the ACTUAL ref it ran on. So if someone later:
#   * renames / moves the publish workflow file, OR
#   * changes the publish trigger (tag vs main),
# the REAL signer identity shifts, but the hard-coded prove-side strings do NOT —
# and the only symptom is a confusing `cosign verify` FAIL deep inside the proof.
#
# These checks turn that confusing red into a clear, early one: they assert (pure
# text/lint — no cluster, no cosign, no network) that the publish workflow's path
# + trigger reality still matches what the prove side hard-codes, and fail loud
# with a "update both in lockstep" message the instant they drift.
#
# The check logic lives here (out of the workflow) so it can be UNIT TESTED:
# bundle-signer-identity-drift-guard-checks.test.sh feeds each check a
# deliberately-BROKEN fixture and asserts the check FAILS (plus that the pristine
# repo PASSES). A future edit that neuters a check — green while guarding nothing
# — is caught by that self-test.
#
# Usage:
#   bundle-signer-identity-drift-guard-checks.sh <check> [root]
#     check : chk1 | chk2 | chk3 | all
#     root  : repo root to check (default: current directory)
#
# Each check exits 0 when the invariant holds and non-zero (printing a GitHub
# ::error annotation) when it is regressed.
#
# Complements (does not duplicate):
#   - cosign-identity-pin-guard.yml  (no loose --certificate-identity-regexp in
#     docs/scripts for the szl-receipts / killinchu / canonical-bundle artifacts)
#   - uds-bundle-publish-guard.yml   (flaky-registry pre-warm + zarf retry net)
#   - bundle-provenance-attestation-guard.yml (anonymous verify-attestation gate)

set -uo pipefail

# err FILE MESSAGE — emit a GitHub Actions error annotation.
err() { echo "::error file=$1::$2"; }

REPO_SLUG="szl-holdings/szl-uds-deployment"
ISSUER="https://token.actions.githubusercontent.com"
PUBLISH_WF=".github/workflows/uds-bundle-publish.yml"
PROVE_WF=".github/workflows/prove-bundle-install.yml"
PROVE_TASK="tasks/prove-bundle.yaml"

# extract_default FILE VARNAME — echo the single-line `default:` value of a uds
# tasks.yaml `- name: <VARNAME>` variable (quotes stripped). Exact var match, so
# CERT_IDENTITY does NOT also match CERT_IDENTITY_FALLBACK.
extract_default() {
  awk -v var="$2" '
    $0 ~ "^[[:space:]]*-[[:space:]]*name:[[:space:]]*"var"[[:space:]]*$" { f=1; next }
    f && /^[[:space:]]*-[[:space:]]*name:/ { f=0 }
    f && /^[[:space:]]*default:/ {
      line=$0
      sub(/^[[:space:]]*default:[[:space:]]*/, "", line)
      gsub(/"/, "", line)
      print line
      exit
    }
  ' "$1"
}

# wf_path_from_identity URL — strip the github.com/<repo>/ prefix and the @<ref>
# suffix from a keyless cert-identity, leaving the workflow file path.
wf_path_from_identity() {
  printf '%s\n' "$1" \
    | sed -E "s#^https://github.com/${REPO_SLUG}/##; s#@refs/.*\$##"
}

# ── Check 1 ───────────────────────────────────────────────────────────────────
# Workflow-path lockstep + existence. The publish-workflow path embedded in the
# prove-side identities must (a) be identical across all the places that hard-code
# it, (b) match the publish workflow's OWN self-identity strings, and (c) point at
# a file that actually EXISTS. A rename/move of the publish workflow that isn't
# mirrored on the prove side trips this (the referenced file is gone).
chk1() {
  local root="${1:-.}"
  local TASK="$root/$PROVE_TASK" PWF="$root/$PROVE_WF" PUB="$root/$PUBLISH_WF"
  local f
  for f in "$TASK" "$PWF"; do
    test -f "$f" || { err "$f" "missing — required for the bundle-signer-identity drift guard"; return 1; }
  done

  # Path the prove TASK's CERT_IDENTITY default pins.
  local task_id task_path
  task_id="$(extract_default "$TASK" CERT_IDENTITY)"
  case "$task_id" in
    https://github.com/${REPO_SLUG}/.github/workflows/*.yml@refs/*) : ;;
    *)
      err "$TASK" "REGRESSION — CERT_IDENTITY default is not a '${REPO_SLUG}/.github/workflows/<wf>.yml@refs/...' identity: '${task_id}'"
      err "$TASK" "The bundle signer is THIS repo's publish workflow; keep CERT_IDENTITY pinned to its exact keyless identity."
      return 1 ;;
  esac
  task_path="$(wf_path_from_identity "$task_id")"

  # Path the prove WORKFLOW hard-codes via WF="...".
  local install_path
  install_path="$(grep -oE 'WF="[^"]+"' "$PWF" | head -1 | sed -E 's/^WF="//; s/"$//')"
  if [ -z "$install_path" ]; then
    err "$PWF" "REGRESSION — could not find the WF=\"...\" publish-workflow path literal used to build the signer identity."
    return 1
  fi

  if [ "$task_path" != "$install_path" ]; then
    err "$TASK" "REGRESSION — publish-workflow path drift: ${PROVE_TASK} pins '${task_path}' but ${PROVE_WF} builds the identity from '${install_path}'."
    err "$PWF" "Update BOTH the CERT_IDENTITY default and the WF=\"...\" literal in lockstep when the publish workflow moves/renames."
    return 1
  fi

  # The path both sides agree on must be a file that exists.
  if [ ! -f "$root/$task_path" ]; then
    err "$TASK" "REGRESSION — the prove side expects the bundle signer to be '${task_path}', but that workflow file does NOT exist."
    err "$TASK" "If the publish workflow was renamed/moved, update CERT_IDENTITY (tasks/prove-bundle.yaml) AND WF=\"...\" (prove-bundle-install.yml) to the new path in lockstep."
    return 1
  fi

  # The agreed path must be the publish workflow, and the publish workflow's OWN
  # self-identity strings (CERT_IDENTITY=/BUILDER_ID=) must reference it too.
  if [ "$task_path" != "$PUBLISH_WF" ]; then
    err "$TASK" "REGRESSION — prove side pins '${task_path}' but the bundle publish workflow is '${PUBLISH_WF}'."
    return 1
  fi
  test -f "$PUB" || { err "$PUB" "missing — the bundle publish workflow expected by the prove side is gone"; return 1; }
  local pub_self
  pub_self="$(grep -oE '\.github/workflows/[A-Za-z0-9._-]+\.yml@\$\{GITHUB_REF\}' "$PUB" | sed -E 's/@\$\{GITHUB_REF\}$//' | sort -u)"
  if [ -z "$pub_self" ]; then
    err "$PUB" "REGRESSION — publish workflow no longer documents its own keyless identity (CERT_IDENTITY=/BUILDER_ID= .github/workflows/<wf>.yml@\${GITHUB_REF})."
    return 1
  fi
  local p
  while IFS= read -r p; do
    [ -z "$p" ] && continue
    if [ "$p" != "$task_path" ]; then
      err "$PUB" "REGRESSION — publish workflow's self-identity references '${p}' but the prove side expects '${task_path}'. Keep them in lockstep."
      return 1
    fi
  done <<EOF
$pub_self
EOF

  echo "OK: publish-workflow path '${task_path}' is consistent across ${PROVE_TASK}, ${PROVE_WF}, ${PUBLISH_WF} and the file exists."
}

# ── Check 2 ───────────────────────────────────────────────────────────────────
# Trigger (tag vs main) coverage. The publish workflow's `on:` triggers decide
# which refs it can produce a signature on. Whatever ref classes it can sign on,
# the prove side must have an EXACT identity that covers them — and the ref the
# task DEFAULTS to must still be one the publish workflow can actually sign on.
chk2() {
  local root="${1:-.}"
  local TASK="$root/$PROVE_TASK" PWF="$root/$PROVE_WF" PUB="$root/$PUBLISH_WF"
  local f
  for f in "$TASK" "$PWF" "$PUB"; do
    test -f "$f" || { err "$f" "missing — required for the bundle-signer-identity drift guard"; return 1; }
  done

  # Isolate the publish workflow `on:` block (top-level `on:` -> next top-level key).
  local ON
  ON="$(awk '/^on:[[:space:]]*$/{f=1;next} f && /^[A-Za-z][A-Za-z0-9_-]*:/{f=0} f{print}' "$PUB")"
  if [ -z "$ON" ]; then
    err "$PUB" "REGRESSION — could not parse the publish workflow 'on:' triggers."
    return 1
  fi

  local has_dispatch=0 has_tag_push=0 bad_branch=0
  printf '%s\n' "$ON" | grep -qE '^[[:space:]]*workflow_dispatch:' && has_dispatch=1
  # push: tags: including a uds-v* / v* pattern -> tag-publishable.
  if printf '%s\n' "$ON" | grep -qE '^[[:space:]]*tags:' \
     && printf '%s\n' "$ON" | grep -qE "['\"]?(uds-v|v)\*['\"]?"; then
    has_tag_push=1
  fi
  # A push: branches: list other than main would add an UNCOVERED signing ref.
  if printf '%s\n' "$ON" | grep -qE '^[[:space:]]*branches:'; then
    if printf '%s\n' "$ON" | grep -E '^[[:space:]]*-[[:space:]]' | grep -qvE "['\"]?main['\"]?[[:space:]]*$"; then
      bad_branch=1
    fi
  fi

  # main-publishable = workflow_dispatch (runs on the default branch = main) or a
  # push to the main branch.
  local main_pub=0
  [ "$has_dispatch" -eq 1 ] && main_pub=1
  if printf '%s\n' "$ON" | grep -qE '^[[:space:]]*branches:' \
     && printf '%s\n' "$ON" | grep -E '^[[:space:]]*-[[:space:]]' | grep -qE "['\"]?main['\"]?[[:space:]]*$"; then
    main_pub=1
  fi

  # Prove-side coverage facts.
  local task_id has_id_main has_id_tag
  task_id="$(extract_default "$TASK" CERT_IDENTITY)"
  has_id_main="$(grep -cE 'ID_MAIN="[^"]*@refs/heads/main"' "$PWF")"
  has_id_tag="$(grep -cE 'ID_TAG="[^"]*@refs/tags/' "$PWF")"

  local rc=0

  if [ "$bad_branch" -eq 1 ]; then
    err "$PUB" "REGRESSION — publish workflow can run (and sign) on a push branch other than 'main', but the prove side only covers refs/heads/main + refs/tags/."
    err "$PWF" "Add an EXACT identity for the new branch ref to prove-bundle-install.yml + tasks/prove-bundle.yaml in lockstep."
    rc=1
  fi

  # The publish workflow MUST still be able to sign on refs/heads/main, because
  # tasks/prove-bundle.yaml DEFAULTS CERT_IDENTITY to the @refs/heads/main form
  # (the live dispatch-published reality).
  if [ "$main_pub" -ne 1 ]; then
    err "$PUB" "REGRESSION — publish workflow can no longer sign on refs/heads/main (workflow_dispatch / push-to-main removed)."
    err "$TASK" "But CERT_IDENTITY still DEFAULTS to the @refs/heads/main form. Update the publish trigger and the prove identities (tag vs main) in lockstep."
    rc=1
  else
    case "$task_id" in
      *@refs/heads/main) : ;;
      *)
        err "$TASK" "REGRESSION — publish workflow signs on refs/heads/main but CERT_IDENTITY default no longer ends with '@refs/heads/main': '${task_id}'."
        rc=1 ;;
    esac
    if [ "${has_id_main:-0}" -eq 0 ]; then
      err "$PWF" "REGRESSION — publish workflow signs on refs/heads/main but prove-bundle-install.yml no longer builds the ID_MAIN=\"...@refs/heads/main\" identity."
      rc=1
    fi
  fi

  # If the publish workflow can sign on a uds-v* tag, the harness MUST build the
  # @refs/tags/ identity (so a tag-published bundle still verifies).
  if [ "$has_tag_push" -eq 1 ] && [ "${has_id_tag:-0}" -eq 0 ]; then
    err "$PWF" "REGRESSION — publish workflow can sign on a uds-v* tag but prove-bundle-install.yml no longer builds the ID_TAG=\"...@refs/tags/...\" identity."
    err "$PUB" "A tag-published bundle would then fail cosign verify. Restore the tag identity or drop the tag trigger in lockstep."
    rc=1
  fi

  if [ "$rc" -eq 0 ]; then
    echo "OK: publish trigger reality (main_pub=${main_pub}, tag_push=${has_tag_push}) is covered by the prove-side identities (id_main=${has_id_main}, id_tag=${has_id_tag})."
  fi
  return "$rc"
}

# ── Check 3 ───────────────────────────────────────────────────────────────────
# Exact-identity + issuer hygiene. The whole proof rests on STRICT identity
# matching: a loose --certificate-identity-regexp or a wildcarded identity would
# accept a signature from the wrong workflow/ref/fork, and a wrong OIDC issuer
# would accept the wrong CA. Keep the prove side exact.
chk3() {
  local root="${1:-.}"
  local TASK="$root/$PROVE_TASK" PWF="$root/$PROVE_WF"
  local f
  for f in "$TASK" "$PWF"; do
    test -f "$f" || { err "$f" "missing — required for the bundle-signer-identity drift guard"; return 1; }
  done
  local rc=0

  # No loose regexp identity anywhere in the proof.
  if grep -qE -- '--certificate-identity-regexp' "$TASK" "$PWF"; then
    err "$TASK" "REGRESSION — the bundle-install proof uses the loose --certificate-identity-regexp form."
    err "$PWF" "Pin EXACT --certificate-identity values only; a regexp accepts the wrong workflow/ref/fork."
    rc=1
  fi

  # The prove task must use the exact --certificate-identity= form.
  if ! grep -qE -- '--certificate-identity=' "$TASK"; then
    err "$TASK" "REGRESSION — prove-bundle.yaml no longer cosign-verifies with an exact --certificate-identity= value."
    rc=1
  fi

  # No wildcard in the pinned identities.
  local v id
  for v in CERT_IDENTITY PROV_IDENTITY; do
    id="$(extract_default "$TASK" "$v")"
    case "$id" in
      *\**)
        err "$TASK" "REGRESSION — ${v} default contains a '*' wildcard ('${id}'); identities must be exact."
        rc=1 ;;
    esac
  done

  # Issuer must be the GitHub Actions OIDC issuer.
  local issuer
  issuer="$(extract_default "$TASK" CERT_ISSUER)"
  if [ "$issuer" != "$ISSUER" ]; then
    err "$TASK" "REGRESSION — CERT_ISSUER default is '${issuer}', expected the GitHub Actions OIDC issuer '${ISSUER}'."
    rc=1
  fi

  if [ "$rc" -eq 0 ]; then
    echo "OK: prove side uses exact (non-regexp, non-wildcard) identities verified against the GitHub OIDC issuer."
  fi
  return "$rc"
}

# ── Dispatch ──────────────────────────────────────────────────────────────────
# When sourced (BASH_SOURCE != $0) define the functions and return so the
# self-test can call them directly. When executed, run the requested check.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  CHECK="${1:-all}"
  ROOT="${2:-.}"
  case "$CHECK" in
    chk1) chk1 "$ROOT" ;;
    chk2) chk2 "$ROOT" ;;
    chk3) chk3 "$ROOT" ;;
    all)
      rc=0
      chk1 "$ROOT" || rc=1
      chk2 "$ROOT" || rc=1
      chk3 "$ROOT" || rc=1
      exit "$rc"
      ;;
    *) echo "unknown check: $CHECK (want chk1|chk2|chk3|all)" >&2; exit 2 ;;
  esac
fi
