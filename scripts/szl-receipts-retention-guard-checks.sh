# Copyright 2026 SZL Holdings
# SPDX-License-Identifier: Apache-2.0
#
# szl-receipts-retention-guard-checks.sh — guard the `szl-receipts-retention`
# box job (the daily verify-store + archive-shards retention timer on
# uds-szl-demo) from silently losing its safety properties.
#
# WHY THIS EXISTS
# `szl-receipts-retention` (box-scripts/sbin/szl-receipts-retention) runs daily
# and keeps the live szl-receipts PVC bounded: it kubectl-execs `verify-store`
# (a bounded full-store integrity audit) then `archive-shards --delete` (which is
# itself per-bucket VERIFY-GATED) into the Ready receipts-server pod, OFFLOADS
# each freshly-sealed cold tarball off the live PVC, sha256-verifies it against
# the bucket manifest, and only THEN prunes the in-pod copy. Its value rests on
# a handful of fragile safety properties that produce NO visible symptom when a
# well-meaning refactor breaks them — until either a tampered chain goes
# unalerted or unverified data is pruned off the live store:
#   * cluster down / module absent / no Ready pod  = no-op exit 0 (never page —
#     a stopped cluster must not become a paging storm, and pod-down is already
#     receipt-chain-watch's job);
#   * a tampered chain (verify-store chain_ok=false) = ALERT  (the VERIFY GATE);
#   * a bucket that fails its per-bucket verification (skipped_failed_verify)
#     = ALERT, and is never archived/deleted;
#   * a BENIGN archive-shards no-op ("sharding disabled" / "no head pointer" on
#     an empty store) = logged, NEVER paged (no false alarms);
#   * the in-pod cold copy is PRUNED ONLY AFTER the off-box copy's sha256 matches
#     the bucket manifest (the PRUNE GATE) — a mismatch leaves the in-pod copy
#     and does NOT page;
#   * it stays WIRED into install.sh (script + units installed, timer enabled)
#     and documented, or a box rebuild silently ships without retention running.
#
# Unlike the pure text/lint guards, this one is BEHAVIOURAL: it actually RUNS the
# real retention script against a mocked `kubectl`/`k3d` (fake PATH bins that
# emit the JSON shapes the script parses) and a capturing notifier, then asserts
# the observable outcome (exit code, whether it paged, the status file, and
# whether it pruned). That is the only way to prove the verify gate and the
# prune gate are actually wired into the control flow rather than merely present
# as text.
#
# The check logic is extracted here (out of the workflow) so it can be UNIT
# TESTED: szl-receipts-retention-guard-checks.test.sh feeds each behavioural
# check a deliberately-BROKEN copy of the script (verify gate removed, prune gate
# removed, benign-error allow-list removed, ...) and asserts the matching check
# FAILS, plus that the pristine repo PASSES. A future edit that neuters a check
# — green while guarding nothing — is caught by that self-test, not in production.
#
# Usage:
#   szl-receipts-retention-guard-checks.sh <check> [root]
#     check : chk1 | chk2 | chk3 | chk4 | chk5 | chk6 | chk7 | chk8 | all
#     root  : repo root to check (default: current directory)
#
# Each check exits 0 when the invariant holds and non-zero (printing a GitHub
# ::error annotation) when it is regressed.

set -uo pipefail

# err MESSAGE — emit a GitHub Actions error annotation.
err() { echo "::error::$*"; }

# Paths (relative to a repo root) of the files this guard inspects.
RETENTION_REL="box-scripts/sbin/szl-receipts-retention"
INSTALL_REL="box-scripts/install.sh"
RUNBOOK_REL="docs/operations/RECEIPT_STORE_RETENTION_RUNBOOK.md"

# ── Scenario config (set per-check, read by _run) ─────────────────────────────
# Reset before every scenario so a previous check's settings never leak (bash
# keeps a `VAR=val func` assignment in scope after the function returns).
_reset_sc() {
  unset SC_CLUSTER_UP SC_CHAIN_OK SC_ARCHIVED SC_SKIPPED \
        SC_ARCHIVE_ERROR SC_SHA_MATCH 2>/dev/null || true
}

# _csv_to_jsonarr "a,b" -> ["a","b"]   (empty -> [])
_csv_to_jsonarr() {
  local csv="${1:-}" out="" IFS=','
  [ -z "$csv" ] && { echo "[]"; return; }
  local x first=1
  for x in $csv; do
    [ -z "$x" ] && continue
    if [ "$first" = 1 ]; then out="\"$x\""; first=0; else out="$out,\"$x\""; fi
  done
  echo "[$out]"
}

# _run ROOT — run the real retention script in a mocked cluster and set globals:
#   H_RC      exit code
#   H_PAGES   number of pages emitted (0 = silent)
#   H_TEXT    concatenated page text
#   H_PRUNED  number of in-pod prune (rm) calls the script made
#   H_STATUS  overall field from the status JSON (OK|ALERT|UNKNOWN|?)
#
# Scenario inputs (defaults in parens):
#   SC_CLUSTER_UP   (1)     0 => k3d reports the cluster absent
#   SC_CHAIN_OK     (true)  false => verify-store reports a tampered chain
#   SC_ARCHIVED     ("")    csv of buckets archive-shards reports archived
#   SC_SKIPPED      ("")    csv of buckets that failed per-bucket verification
#   SC_ARCHIVE_ERROR("")    archive-shards {"error": ...} string
#   SC_SHA_MATCH    (1)     0 => offloaded tarball sha256 != manifest (mismatch)
_run() {
  local root="${1:-.}"
  local F="$root/$RETENTION_REL"
  local work; work="$(mktemp -d)"
  local mbin="$work/bin"; mkdir -p "$mbin"
  local kc="$work/kubeconfig"; : >"$kc"
  local pages="$work/pages"; : >"$pages"
  local prune="$work/prune"; : >"$prune"

  # Deterministic cold tarball bytes + their real sha256; the manifest carries
  # either the matching sha (verified offload) or a wrong one (mismatch).
  local tarc="SZL-FAKE-COLD-TARBALL"
  local realsha; realsha="$(printf '%s' "$tarc" | sha256sum | awk '{print $1}')"
  local mansha
  if [ "${SC_SHA_MATCH:-1}" = "1" ]; then
    mansha="$realsha"
  else
    mansha="0000000000000000000000000000000000000000000000000000000000000000"
  fi

  # Build the verify-store + archive-shards JSON the mock will emit.
  local verify_json
  if [ "${SC_CHAIN_OK:-true}" = "true" ]; then
    verify_json='{"chain_ok": true, "total": 42, "bad_sig": 0, "bad_hash": 0, "bad_link": 0, "tampered_sample": []}'
  else
    verify_json='{"chain_ok": false, "total": 42, "bad_sig": 1, "bad_hash": 0, "bad_link": 0, "tampered_sample": ["r123"]}'
  fi
  local arch_arr skip_arr errf
  arch_arr="$(_csv_to_jsonarr "${SC_ARCHIVED:-}")"
  skip_arr="$(_csv_to_jsonarr "${SC_SKIPPED:-}")"
  if [ -n "${SC_ARCHIVE_ERROR:-}" ]; then errf="\"${SC_ARCHIVE_ERROR}\""; else errf="null"; fi
  local archive_json="{\"archived\": $arch_arr, \"skipped_failed_verify\": $skip_arr, \"error\": $errf}"

  # Mock kubectl — dispatch on the (whole) arg string. Order matters: the prune
  # `rm` call also contains .tar.gz/.manifest.json, so match it first.
  cat >"$mbin/kubectl" <<KEOF
#!/usr/bin/env bash
args="\$*"
case "\$args" in
  *"--raw=/readyz"*) echo ok; exit 0 ;;
  *"get deploy szl-receipts-server"*) exit 0 ;;
  *"get pods"*) printf '%s' '{"items":[{"metadata":{"name":"szl-receipts-server-xyz"},"status":{"containerStatuses":[{"name":"receipts-server","ready":true}]}}]}'; exit 0 ;;
  *"verify-store"*) printf '%s' '${verify_json}'; exit 0 ;;
  *"archive-shards"*) printf '%s' '${archive_json}'; exit 0 ;;
  *" rm "*) echo "PRUNE \$args" >>"${prune}"; exit 0 ;;
  *".manifest.json"*) printf '%s' '{"tarball_sha256": "${mansha}"}'; exit 0 ;;
  *".tar.gz"*) printf '%s' '${tarc}'; exit 0 ;;
  *"archived.json"*) printf '%s' '{}'; exit 0 ;;
  *) exit 0 ;;
esac
KEOF
  chmod +x "$mbin/kubectl"

  # Mock k3d — only `kubeconfig write` is used; fail when the cluster is "absent".
  cat >"$mbin/k3d" <<KEOF
#!/usr/bin/env bash
if [ "${SC_CLUSTER_UP:-1}" = "1" ]; then echo "${kc}"; exit 0; else exit 1; fi
KEOF
  chmod +x "$mbin/k3d"

  # Capturing notifier — record each page (stdin) so we can count edges.
  cat >"$mbin/notify" <<KEOF
#!/usr/bin/env bash
cat >>"${pages}"
printf '\n---PAGE-END---\n' >>"${pages}"
KEOF
  chmod +x "$mbin/notify"

  CLUSTER=testcl KUBECONFIG_FILE="" \
    STATE_DIR="$work/state" LOG_DIR="$work/log" HOST_COLD_DIR="$work/cold" \
    NOTIFY_CMD="$mbin/notify" ALERT_PREFIX="[TEST] " \
    PATH="$mbin:$PATH" \
    bash "$F" >"$work/stdout" 2>&1
  H_RC=$?

  H_PAGES="$(grep -c '^---PAGE-END---$' "$pages" 2>/dev/null || true)"; H_PAGES="${H_PAGES:-0}"
  H_PRUNED="$(grep -c '^PRUNE ' "$prune" 2>/dev/null || true)"; H_PRUNED="${H_PRUNED:-0}"
  H_TEXT="$(cat "$pages" 2>/dev/null || true)"
  H_STATUS="$(sed -n 's/.*"overall":"\([^"]*\)".*/\1/p' "$work/state/testcl.status.json" 2>/dev/null || true)"
  H_STATUS="${H_STATUS:-?}"

  rm -rf "$work"
}

# ── Check 1 ───────────────────────────────────────────────────────────────────
# The retention script exists and parses clean (bash -n). If it is missing or
# broken the daily job cannot run at all.
chk1() {
  local root="${1:-.}"
  local F="$root/$RETENTION_REL"
  test -f "$F" || {
    err "REGRESSION ($F) — szl-receipts-retention is MISSING. The receipt-store retention job is gone."
    return 1
  }
  local out
  if ! out="$(bash -n "$F" 2>&1)"; then
    err "REGRESSION ($F) — szl-receipts-retention does not parse (bash -n failed)."
    echo "$out" | sed 's/^/       | /'
    return 1
  fi
  echo "OK: $F exists and parses clean (bash -n)"
}

# ── Check 2 ───────────────────────────────────────────────────────────────────
# Cluster absent = true no-op: exit 0, no page, status not ALERT. A stopped k3d
# cluster must never become a paging storm.
chk2() {
  local root="${1:-.}"
  _reset_sc; SC_CLUSTER_UP=0; _run "$root"
  if [ "${H_RC}" -ne 0 ]; then
    err "REGRESSION — cluster-down run did NOT no-op (exit $H_RC, want 0). A stopped cluster would now error/page."
    return 1
  fi
  if [ "${H_PAGES}" -ne 0 ]; then
    err "REGRESSION — cluster-down run PAGED ($H_PAGES). A stopped cluster must be a silent no-op (receipt-chain-watch owns pod-down)."
    return 1
  fi
  echo "OK: cluster-down is a silent no-op (exit 0, no page)"
}

# ── Check 3 ───────────────────────────────────────────────────────────────────
# THE VERIFY GATE: a tampered chain (verify-store chain_ok=false) raises an
# ALERT page. If this is dropped, store corruption goes unnoticed.
chk3() {
  local root="${1:-.}"
  _reset_sc; SC_CHAIN_OK=false; _run "$root"
  if [ "${H_PAGES}" -lt 1 ]; then
    err "REGRESSION — VERIFY GATE GONE: verify-store chain_ok=false did NOT page. A tampered receipt chain would go unalerted."
    return 1
  fi
  if [ "${H_STATUS}" != "ALERT" ]; then
    err "REGRESSION — chain_ok=false did not set status ALERT (got '$H_STATUS')."
    return 1
  fi
  case "$H_TEXT" in
    *chain_ok=false*) : ;;
    *) err "REGRESSION — the chain_ok=false page lost its 'chain_ok=false' reason text."; return 1 ;;
  esac
  echo "OK: verify gate intact — chain_ok=false pages an ALERT"
}

# ── Check 4 ───────────────────────────────────────────────────────────────────
# Per-bucket verify gate: a bucket in skipped_failed_verify (one that failed its
# own verification, so it was never archived/deleted) raises an ALERT.
chk4() {
  local root="${1:-.}"
  _reset_sc; SC_SKIPPED="2026-06-01"; _run "$root"
  if [ "${H_PAGES}" -lt 1 ]; then
    err "REGRESSION — skipped-bucket gate GONE: a skipped_failed_verify bucket did NOT page. A bucket that fails verification would go unalerted."
    return 1
  fi
  if [ "${H_STATUS}" != "ALERT" ]; then
    err "REGRESSION — skipped_failed_verify did not set status ALERT (got '$H_STATUS')."
    return 1
  fi
  case "$H_TEXT" in
    *SKIPPED*) : ;;
    *) err "REGRESSION — the skipped-bucket page lost its 'SKIPPED' reason text."; return 1 ;;
  esac
  echo "OK: per-bucket verify gate intact — a skipped_failed_verify bucket pages an ALERT"
}

# ── Check 5 ───────────────────────────────────────────────────────────────────
# A BENIGN archive-shards no-op ("sharding disabled" / "no head pointer" on an
# empty store) is logged, NEVER paged. Otherwise every empty-store cluster would
# raise a false alarm.
chk5() {
  local root="${1:-.}"
  _reset_sc; SC_ARCHIVE_ERROR="sharding disabled"; _run "$root"
  if [ "${H_PAGES}" -ne 0 ]; then
    err "REGRESSION — a BENIGN archive-shards no-op ('sharding disabled') PAGED ($H_PAGES). Empty-store clusters would false-alarm."
    return 1
  fi
  if [ "${H_STATUS}" = "ALERT" ]; then
    err "REGRESSION — a benign archive-shards no-op set status ALERT (should stay OK)."
    return 1
  fi
  echo "OK: benign archive-shards no-op is logged, not paged"
}

# ── Check 6 ───────────────────────────────────────────────────────────────────
# THE PRUNE GATE: the in-pod cold copy is pruned ONLY AFTER the off-box copy's
# sha256 matches the bucket manifest. A matching offload prunes; a MISMATCH must
# NOT prune (and must not page — it just leaves the in-pod copy for next run).
chk6() {
  local root="${1:-.}"
  # (a) verified offload -> prune happens
  _reset_sc; SC_ARCHIVED="2026-06-01"; SC_SHA_MATCH=1; _run "$root"
  if [ "${H_PRUNED}" -lt 1 ]; then
    err "REGRESSION — a sha256-VERIFIED offload did NOT prune the in-pod copy ($H_PRUNED). Retention would never reclaim the live PVC."
    return 1
  fi
  # (b) sha mismatch -> NO prune, NO page (data safety: never delete unverified)
  _reset_sc; SC_ARCHIVED="2026-06-01"; SC_SHA_MATCH=0; _run "$root"
  if [ "${H_PRUNED}" -ne 0 ]; then
    err "REGRESSION — PRUNE GATE GONE: a sha256 MISMATCH still pruned the in-pod copy ($H_PRUNED). Unverified data would be deleted off the live store."
    return 1
  fi
  if [ "${H_PAGES}" -ne 0 ]; then
    err "REGRESSION — a sha256 mismatch PAGED ($H_PAGES); an incomplete offload should be logged + retried, not paged."
    return 1
  fi
  echo "OK: prune gate intact — prune only after a sha256-verified offload (mismatch keeps the in-pod copy, no page)"
}

# ── Check 7 ───────────────────────────────────────────────────────────────────
# Still wired into install.sh: the sbin script + the .service and .timer units
# are installed and the timer is enabled. Otherwise a box rebuild ships without
# retention running.
chk7() {
  local root="${1:-.}"
  local F="$root/$INSTALL_REL"
  test -f "$F" || { err "REGRESSION ($F) — install.sh missing; cannot verify retention is wired."; return 1; }

  grep -Eq 'install .*sbin/szl-receipts-retention' "$F" || {
    err "REGRESSION ($F) — install.sh no longer installs sbin/szl-receipts-retention."
    return 1
  }
  grep -Fq 'szl-receipts-retention.service' "$F" || {
    err "REGRESSION ($F) — install.sh no longer installs szl-receipts-retention.service."
    return 1
  }
  grep -Fq 'szl-receipts-retention.timer' "$F" || {
    err "REGRESSION ($F) — install.sh no longer installs szl-receipts-retention.timer."
    return 1
  }
  grep -Eq 'systemctl enable --now szl-receipts-retention\.timer' "$F" || {
    err "REGRESSION ($F) — install.sh no longer ENABLES szl-receipts-retention.timer; retention wouldn't run after a rebuild."
    return 1
  }
  echo "OK: install.sh installs the script + units and enables the timer"
}

# ── Check 8 ───────────────────────────────────────────────────────────────────
# Still documented: the retention runbook exists and describes the verify-store +
# archive-shards procedure, and install.sh's banner names the job. An operator
# rebuilding the box must be able to find out the job exists and what it runs.
chk8() {
  local root="${1:-.}"
  local R="$root/$RUNBOOK_REL"
  test -f "$R" || { err "REGRESSION ($R) — the receipt-store retention runbook is MISSING."; return 1; }
  grep -Fq 'verify-store' "$R" || {
    err "REGRESSION ($R) — the runbook no longer documents 'verify-store'."
    return 1
  }
  grep -Fq 'archive-shards' "$R" || {
    err "REGRESSION ($R) — the runbook no longer documents 'archive-shards'."
    return 1
  }
  local F="$root/$INSTALL_REL"
  test -f "$F" || { err "REGRESSION ($F) — install.sh missing."; return 1; }
  grep -Fq 'szl-receipts-retention' "$F" || {
    err "REGRESSION ($F) — install.sh banner no longer names szl-receipts-retention."
    return 1
  }
  echo "OK: retention runbook documents verify-store + archive-shards; install.sh names the job"
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
      exit "$rc"
      ;;
    *) echo "unknown check: $CHECK (want chk1..chk8|all)" >&2; exit 2 ;;
  esac
fi
