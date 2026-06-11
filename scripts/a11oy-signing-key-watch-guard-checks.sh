# Copyright 2026 SZL Holdings
# SPDX-License-Identifier: Apache-2.0
#
# a11oy-signing-key-watch-guard-checks.sh — guard the `a11oy-signing-key-watch`
# box guard (the a11oy persistent-signing-key proof) from silently regressing.
#
# WHY THIS EXISTS
# `a11oy-signing-key-watch` (box-scripts/sbin/a11oy-signing-key-watch) is a
# periodic proof: it RESTARTS the live a11oy pod and asserts the public
# receipt-signing key (served at /api/a11oy/v1/wow/cosign.pub) is byte-identical
# before and after, that a freshly signed receipt verifies against it, and that a
# receipt signed BEFORE the restart still verifies against the post-restart key.
# It pages the team the moment a11oy serves a DIFFERENT key — the silent
# ephemeral fallback that the persistent-key (BYOK Secret) fix was built to
# prevent. That regression is INVISIBLE in normal operation (a11oy keeps serving
# 200s and signing receipts, just with a key that resets on restart), so without
# this proof a dropped Secret mount goes unnoticed until an old receipt fails to
# verify. Its value depends on a few fragile invariants that are easy to break
# with a well-meaning refactor and produce NO visible symptom until a real
# regression goes unalerted:
#   * it must still capture a BASELINE — the public key AND a signed receipt —
#     BEFORE restarting;
#   * it must actually RESTART the pod (rollout restart) and WAIT (rollout status);
#   * it must compare the key across the restart (pub_match) and assert the
#     post-restart key_source is "persistent" (not a silent ephemeral fallback);
#   * it must CRYPTOGRAPHICALLY verify a receipt against the post-restart key
#     (ECDSA-P256-SHA256 over the DSSE PAE);
#   * it must be EDGE-triggered (read + write a last_status state file) so it
#     pages exactly once on OK->ALERT and once on RECOVERED, never every cycle;
#   * it must NO-OP (exit 0, no page) when the cluster is absent/unreachable, the
#     a11oy Deployment is absent, or no baseline is available, so a stopped
#     cluster never turns into a paging storm;
#   * it must stay WIRED into install.sh (copied + timer enabled) and documented
#     in README.md, or a box rebuild silently ships without the proof.
# This guard is a pure text/lint check (no cluster) that asserts each invariant.
#
# The check logic is extracted here (out of the workflow) so it can be UNIT
# TESTED: a11oy-signing-key-watch-guard-checks.test.sh feeds each check a
# deliberately-BROKEN fixture and asserts the check FAILS (plus that the pristine
# repo PASSES). A future edit that neuters a check — making it pass vacuously,
# green while guarding nothing — is caught by that self-test, not in production.
#
# Usage:
#   a11oy-signing-key-watch-guard-checks.sh <check> [root]
#     check : chk1 | chk2 | ... | chk9 | all
#     root  : repo root to check (default: current directory)
#
# Each check exits 0 when the invariant holds and non-zero (printing a GitHub
# ::error annotation) when it is regressed.

set -uo pipefail

# err FILE MESSAGE — emit a GitHub Actions error annotation.
err() { echo "::error file=$1::$2"; }

# Paths (relative to a repo root) of the files this guard inspects.
WATCH_REL="box-scripts/sbin/a11oy-signing-key-watch"
INSTALL_REL="box-scripts/install.sh"
README_REL="box-scripts/README.md"

# ── Check 1 ───────────────────────────────────────────────────────────────────
# The guard script exists and parses clean under `bash -n`. If it is missing or
# broken, the proof cannot run at all.
chk1() {
  local root="${1:-.}"
  local F="$root/$WATCH_REL"
  test -f "$F" || {
    err "$F" "REGRESSION — a11oy-signing-key-watch is MISSING. The a11oy persistent-signing-key proof is gone."
    return 1
  }
  local out
  if ! out="$(bash -n "$F" 2>&1)"; then
    err "$F" "REGRESSION — a11oy-signing-key-watch does not parse (bash -n failed)."
    echo "$out" | sed 's/^/       | /'
    return 1
  fi
  echo "OK: $F exists and parses clean (bash -n)"
}

# ── Check 2 ───────────────────────────────────────────────────────────────────
# It still captures a BASELINE before restarting: the public key (cosign.pub) and
# a pre-restart signed receipt (govern), stored as PUB1 / RECEIPT_PRE. Dropping
# either means there is nothing to compare the post-restart key against — the
# proof would pass vacuously.
chk2() {
  local root="${1:-.}"
  local F="$root/$WATCH_REL"
  test -f "$F" || { err "$F" "missing — required for the a11oy-signing-key-watch guard"; return 1; }

  grep -Fq 'cosign.pub' "$F" || {
    err "$F" "REGRESSION — a11oy-signing-key-watch no longer fetches the public key (/cosign.pub)."
    err "$F" "Without the public key it cannot tell whether the signing key changed across a restart."
    return 1
  }
  grep -Fq '/govern' "$F" || {
    err "$F" "REGRESSION — a11oy-signing-key-watch no longer requests a signed receipt (/govern)."
    return 1
  }
  grep -Fq 'PUB1=' "$F" || {
    err "$F" "REGRESSION — a11oy-signing-key-watch no longer captures the BASELINE public key (PUB1)."
    return 1
  }
  grep -Fq 'RECEIPT_PRE=' "$F" || {
    err "$F" "REGRESSION — a11oy-signing-key-watch no longer captures a pre-restart signed receipt (RECEIPT_PRE)."
    err "$F" "It could no longer prove a receipt signed BEFORE a restart still verifies afterwards."
    return 1
  }
  echo "OK: captures the baseline (PUB1 + RECEIPT_PRE) before restarting"
}

# ── Check 3 ───────────────────────────────────────────────────────────────────
# It actually RESTARTS the a11oy pod and WAITS for the rollout to settle. Without
# the restart there is no "across a restart" to prove; without the wait it would
# probe a half-rolled deployment.
chk3() {
  local root="${1:-.}"
  local F="$root/$WATCH_REL"
  test -f "$F" || { err "$F" "missing — required for the a11oy-signing-key-watch guard"; return 1; }

  grep -Eq 'rollout restart deployment' "$F" || {
    err "$F" "REGRESSION — a11oy-signing-key-watch no longer RESTARTS the a11oy pod (rollout restart deployment)."
    err "$F" "Without forcing a restart there is no 'across a restart' for it to prove."
    return 1
  }
  grep -Eq 'rollout status deployment' "$F" || {
    err "$F" "REGRESSION — a11oy-signing-key-watch no longer WAITS for the rollout (rollout status deployment)."
    err "$F" "It would probe a half-rolled deployment and produce a flaky result."
    return 1
  }
  echo "OK: restarts the a11oy pod and waits for the rollout"
}

# ── Check 4 ───────────────────────────────────────────────────────────────────
# It still detects a CHANGED key and the silent EPHEMERAL fallback: it compares
# the key across the restart (pub_match) and asserts the post-restart key_source
# is "persistent". Dropping either lets a key reset slip through unalerted.
chk4() {
  local root="${1:-.}"
  local F="$root/$WATCH_REL"
  test -f "$F" || { err "$F" "missing — required for the a11oy-signing-key-watch guard"; return 1; }

  grep -Fq 'pub_match' "$F" || {
    err "$F" "REGRESSION — a11oy-signing-key-watch no longer compares the key across the restart (pub_match)."
    err "$F" "A key that CHANGES on restart (ephemeral fallback) would go unalerted."
    return 1
  }
  grep -Fq 'key_source' "$F" || {
    err "$F" "REGRESSION — a11oy-signing-key-watch no longer inspects the receipt key_source."
    return 1
  }
  grep -Fq '"persistent"' "$F" || {
    err "$F" "REGRESSION — a11oy-signing-key-watch no longer asserts key_source == 'persistent'."
    err "$F" "A silent ephemeral-key fallback (no Secret mounted) would go unalerted."
    return 1
  }
  grep -Fiq 'CHANGED across' "$F" || {
    err "$F" "REGRESSION — a11oy-signing-key-watch lost the 'key CHANGED across the restart' alert reason."
    return 1
  }
  echo "OK: detects a changed key (pub_match) + a silent ephemeral fallback (key_source != persistent)"
}

# ── Check 5 ───────────────────────────────────────────────────────────────────
# It still CRYPTOGRAPHICALLY verifies a receipt against the post-restart key:
# ECDSA-P256 + SHA256 over the DSSE PAE, loading the served PEM public key.
# Replacing real verification with a status-string check would let a forged or
# unverifiable receipt pass.
chk5() {
  local root="${1:-.}"
  local F="$root/$WATCH_REL"
  test -f "$F" || { err "$F" "missing — required for the a11oy-signing-key-watch guard"; return 1; }

  grep -Fq 'ec.ECDSA' "$F" || {
    err "$F" "REGRESSION — a11oy-signing-key-watch no longer verifies with ECDSA (ec.ECDSA)."
    err "$F" "It would no longer cryptographically prove a receipt verifies against the served key."
    return 1
  }
  grep -Fq 'hashes.SHA256' "$F" || {
    err "$F" "REGRESSION — a11oy-signing-key-watch no longer uses SHA256 in the signature verification."
    return 1
  }
  grep -Fq 'DSSEv1' "$F" || {
    err "$F" "REGRESSION — a11oy-signing-key-watch no longer builds the DSSE PAE (DSSEv1) it verifies over."
    return 1
  }
  grep -Fq 'load_pem_public_key' "$F" || {
    err "$F" "REGRESSION — a11oy-signing-key-watch no longer loads the served PEM public key for verification."
    return 1
  }
  echo "OK: cryptographically verifies a receipt (ECDSA-P256-SHA256 over the DSSE PAE)"
}

# ── Check 6 ───────────────────────────────────────────────────────────────────
# Edge-triggering is intact: it READS the previous state (cat "$LAST_FILE"),
# WRITES the new state back, gates the ALERT page on the OK->ALERT edge ("$prev"
# != "ALERT") and the RECOVERED page on the ALERT->OK edge ("$prev" = "ALERT"),
# and makes EXACTLY TWO notify calls (one per edge) so it never pages every cycle.
chk6() {
  local root="${1:-.}"
  local F="$root/$WATCH_REL"
  test -f "$F" || { err "$F" "missing — required for the a11oy-signing-key-watch guard"; return 1; }

  grep -Fq 'cat "$LAST_FILE"' "$F" || {
    err "$F" "REGRESSION — a11oy-signing-key-watch no longer READS the last_status state file; it would page every cycle."
    return 1
  }
  grep -Fq '>"$LAST_FILE"' "$F" || {
    err "$F" "REGRESSION — a11oy-signing-key-watch no longer WRITES the last_status state file; it can't de-dupe."
    return 1
  }
  grep -Fq '"$prev" != "ALERT"' "$F" || {
    err "$F" "REGRESSION — the OK->ALERT edge guard ('\$prev' != 'ALERT') is gone; the alarm would re-page every cycle."
    return 1
  }
  grep -Fq '"$prev" = "ALERT"' "$F" || {
    err "$F" "REGRESSION — the ALERT->OK (RECOVERED) edge guard ('\$prev' = 'ALERT') is gone; recovery would page every cycle or never."
    return 1
  }
  # Count actual notify CALLS (indented invocations), not the notify() definition.
  local n
  n="$(grep -Ec '^[[:space:]]+notify "' "$F")"
  if [ "$n" -ne 2 ]; then
    err "$F" "REGRESSION — expected EXACTLY 2 notify calls (one OK->ALERT, one RECOVERED) but found $n."
    return 1
  fi
  echo "OK: edge-triggered — reads+writes last_status, both edge guards present, exactly 2 notify calls"
}

# ── Check 7 ───────────────────────────────────────────────────────────────────
# Cluster-absent / unreachable / a11oy-absent / no-baseline is a true no-op: the
# kubeconfig-resolve, the readiness probe, the a11oy Deployment presence check,
# and the baseline-unavailable path each fall back to `exit 0` (no page). A
# stopped cluster (or one without a11oy) must never turn into a paging storm.
chk7() {
  local root="${1:-.}"
  local F="$root/$WATCH_REL"
  test -f "$F" || { err "$F" "missing — required for the a11oy-signing-key-watch guard"; return 1; }

  grep -A1 -E 'k3d kubeconfig write' "$F" | grep -Fq 'exit 0' || {
    err "$F" "REGRESSION — cluster-absent path no longer no-ops (k3d kubeconfig write resolve lost its 'exit 0' fallback)."
    return 1
  }
  grep -A1 -E 'readyz' "$F" | grep -Fq 'exit 0' || {
    err "$F" "REGRESSION — cluster-unreachable path no longer no-ops (readyz probe lost its 'exit 0' fallback)."
    return 1
  }
  grep -A1 -E 'get deploy "\$DEPLOY"' "$F" | grep -Fq 'exit 0' || {
    err "$F" "REGRESSION — a11oy-absent path no longer no-ops (a11oy Deployment presence check lost its 'exit 0' fallback)."
    return 1
  }
  grep -E 'baseline unavailable' "$F" | grep -Fq 'exit 0' || {
    err "$F" "REGRESSION — the no-baseline path no longer no-ops; a not-yet-serving a11oy would page falsely."
    return 1
  }
  echo "OK: cluster-absent / unreachable / a11oy-absent / no-baseline paths all no-op (exit 0)"
}

# ── Check 8 ───────────────────────────────────────────────────────────────────
# Still wired into install.sh: the sbin script + the .service and .timer units
# are copied, and the timer is enabled. Otherwise a box rebuild ships without the
# proof running.
chk8() {
  local root="${1:-.}"
  local F="$root/$INSTALL_REL"
  test -f "$F" || { err "$F" "missing — required for the a11oy-signing-key-watch guard"; return 1; }

  grep -Eq 'install .*sbin/a11oy-signing-key-watch' "$F" || {
    err "$F" "REGRESSION — install.sh no longer installs sbin/a11oy-signing-key-watch."
    return 1
  }
  grep -Fq 'a11oy-signing-key-watch.service' "$F" || {
    err "$F" "REGRESSION — install.sh no longer installs a11oy-signing-key-watch.service."
    return 1
  }
  grep -Fq 'a11oy-signing-key-watch.timer' "$F" || {
    err "$F" "REGRESSION — install.sh no longer installs a11oy-signing-key-watch.timer."
    return 1
  }
  grep -Eq 'systemctl enable --now a11oy-signing-key-watch\.timer' "$F" || {
    err "$F" "REGRESSION — install.sh no longer ENABLES a11oy-signing-key-watch.timer; the proof wouldn't run after a rebuild."
    return 1
  }
  echo "OK: install.sh installs the script + units and enables the timer"
}

# ── Check 9 ───────────────────────────────────────────────────────────────────
# Still documented in README.md so an operator restoring the box after a wipe
# knows the proof exists and how to verify it.
chk9() {
  local root="${1:-.}"
  local F="$root/$README_REL"
  test -f "$F" || { err "$F" "missing — required for the a11oy-signing-key-watch guard"; return 1; }

  grep -Fq 'a11oy-signing-key-watch' "$F" || {
    err "$F" "REGRESSION — README.md no longer documents a11oy-signing-key-watch."
    return 1
  }
  grep -Fiq 'signing key across' "$F" || {
    err "$F" "REGRESSION — README.md lost the 'signing key across (a) restart' section describing this proof."
    return 1
  }
  echo "OK: README.md documents the a11oy-signing-key-watch persistent-signing-key proof"
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
    chk4) chk4 "$ROOT" ;;
    chk5) chk5 "$ROOT" ;;
    chk6) chk6 "$ROOT" ;;
    chk7) chk7 "$ROOT" ;;
    chk8) chk8 "$ROOT" ;;
    chk9) chk9 "$ROOT" ;;
    all)
      rc=0
      chk1 "$ROOT" || rc=1
      chk2 "$ROOT" || rc=1
      chk3 "$ROOT" || rc=1
      chk4 "$ROOT" || rc=1
      chk5 "$ROOT" || rc=1
      chk6 "$ROOT" || rc=1
      chk7 "$ROOT" || rc=1
      chk8 "$ROOT" || rc=1
      chk9 "$ROOT" || rc=1
      exit "$rc"
      ;;
    *) echo "unknown check: $CHECK (want chk1..chk9|all)" >&2; exit 2 ;;
  esac
fi
