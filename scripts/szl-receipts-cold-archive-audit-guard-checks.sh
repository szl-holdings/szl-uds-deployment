# Copyright 2026 SZL Holdings
# SPDX-License-Identifier: Apache-2.0
#
# szl-receipts-cold-archive-audit-guard-checks.sh — guard the
# `szl-receipts-cold-archive-audit` box job (the periodic OFFLINE re-verification
# of the box REAL cold receipt archive) from silently losing its safety
# properties.
#
# WHY THIS EXISTS
# szl-receipts-cold-archive-audit (box-scripts/sbin/szl-receipts-cold-archive-audit)
# runs daily and re-verifies the aged-out cold receipt tarballs in HOST_COLD_DIR
# OFFLINE (public key only) so a corrupt cold bucket is caught long before anyone
# needs to re-attach cold storage to the chain. Its value rests on a handful of
# fragile CONTROL-FLOW properties that produce NO visible symptom when a
# well-meaning refactor breaks them:
#   * an empty / absent cold dir is a silent no-op (no cold history yet = nothing
#     to audit, must never page);
#   * no public key available (cluster down on the very first run, nothing cached,
#     no env override) is a silent no-op UNKNOWN — we cannot prove pass OR fail
#     without the key, so we must NEVER cry wolf;
#   * a real verify failure pages an ALERT, is edge-deduped (it must not re-page
#     every run while it stays failing), and emits a RECOVERED on the clean edge;
#   * the audit is an OFF-BOX / OFFLINE auditor: it re-verifies the cold tarballs
#     with the PUBLIC KEY ONLY and must NOT silently start depending on the live
#     store (it must never pass `--tail-first-prev` to verify-cold);
#   * it stays WIRED into install.sh (script + units installed, timer enabled,
#     first-run kicked) and documented, or a box rebuild silently ships without
#     the cold-archive audit running.
#
# The CRYPTOGRAPHIC correctness of verify-cold itself (does a tampered receipt /
# bad sha256 / broken stitch actually fail?) is unit-guarded separately by
# receipts_sharding_guard's own test against crafted-bad archives; THIS guard
# proves the alarm's control flow around it is wired correctly.
#
# Unlike pure text/lint guards, this one is BEHAVIOURAL: it actually RUNS the real
# audit script over a fabricated HOST_COLD_DIR of fake sealed buckets, with a
# STUBBED verifier (GUARD_PY -> a tiny python that prints canned verify-cold
# output + exit code and records its argv) and an explicit PUBKEY_HEX (so no
# cluster is needed), with a capturing notifier, then asserts the observable
# outcome (exit code, whether it paged, the status file, and the verifier argv).
# That is the only way to prove the no-op gates, the edge-dedup, the
# RECOVERED edge, and the public-key-only contract are actually wired into the
# control flow rather than merely present as text.
#
# The check logic is extracted here (out of the workflow) so it can be UNIT
# TESTED: szl-receipts-cold-archive-audit-guard-checks.test.sh feeds each check a
# deliberately-BROKEN copy of the script and asserts the matching check FAILS,
# plus that the pristine repo PASSES.
#
# Usage:
#   szl-receipts-cold-archive-audit-guard-checks.sh <check> [root]
#     check : chk1 | chk2 | ... | chk9 | all
#     root  : repo root to check (default: current directory)
#
# Each check exits 0 when the invariant holds and non-zero (printing a GitHub
# ::error annotation) when it is regressed.

set -uo pipefail

err() { echo "::error::$*"; }

# Paths (relative to a repo root) of the files this guard inspects.
AUDIT_REL="box-scripts/sbin/szl-receipts-cold-archive-audit"
INSTALL_REL="box-scripts/install.sh"
RUNBOOK_REL="docs/operations/RECEIPT_STORE_RETENTION_RUNBOOK.md"

# ── Scenario config (set per-check, read by _run) ─────────────────────────────
_reset_sc() {
  unset SC_HAVE_COLD SC_VERIFY SC_NO_KEY SC_REUSE 2>/dev/null || true
}

# _run ROOT — run the real audit script (stubbed verifier, explicit pubkey) over
# a fabricated cold dir and set globals:
#   H_RC      exit code
#   H_PAGES   number of pages emitted (0 = silent)
#   H_TEXT    concatenated page text
#   H_STATUS  overall field from the status JSON (OK|ALERT|UNKNOWN|?)
#   H_ARGV    the argv the stub verifier was invoked with ("" if never called)
#
# Scenario inputs (defaults in parens):
#   SC_HAVE_COLD (1)  0 => the cold dir has no sealed buckets
#   SC_VERIFY  (pass) pass|fail => what the stubbed verify-cold reports
#   SC_NO_KEY    (0)  1 => provide NO public key (no env, no cache) + an absent
#                         cluster, to exercise the UNKNOWN no-op
#   SC_REUSE     ()   when set to a dir, reuse it as the work dir across calls
#                     (persists state + the pages file) to test edge-dedup /
#                     RECOVERED; the caller is responsible for rm -rf'ing it.
_run() {
  local root="${1:-.}"
  local F="$root/$AUDIT_REL"
  local work; if [ -n "${SC_REUSE:-}" ]; then work="$SC_REUSE"; mkdir -p "$work"; else work="$(mktemp -d)"; fi
  local mbin="$work/bin"; mkdir -p "$mbin"
  local cold="$work/cold"; mkdir -p "$cold"
  local statedir="$work/state"
  local pages="$work/pages"; [ -f "$pages" ] || : >"$pages"
  local argvf="$work/argv"
  local bucket="00000001"

  # A fake sealed bucket: a tarball + a manifest. Content is irrelevant — the
  # STUB verifier decides pass/fail; we only need the pair to exist so the script
  # enumerates a bucket to audit.
  if [ "${SC_HAVE_COLD:-1}" = "1" ]; then
    printf 'SZL-FAKE-COLD-TARBALL-%s' "$bucket" >"$cold/$bucket.tar.gz"
    printf '{"tarball_sha256":"deadbeef","count":3,"last_hash":"deadbeef"}\n' >"$cold/$bucket.manifest.json"
    printf '{"buckets":["%s"]}\n' "$bucket" >"$cold/archived.json"
  fi

  # Stub verifier: records argv, then prints canned verify-cold output + exit code
  # per SC_VERIFY. Runnable by python3 the same way the real guard is invoked
  # (`python3 GUARD_PY verify-cold <dir> --pubkey-hex <hex>`).
  cat >"$work/stub_verify.py" <<PYEOF
import os, sys
open(os.environ["STUB_ARGV_FILE"], "w").write("\\0".join(sys.argv[1:]))
mode = os.environ.get("SC_VERIFY", "pass")
b = "00000001"
if mode == "fail":
    print("verify-cold: 1 sealed bucket(s):", "['%s']" % b)
    print("  ok   cold tarball[%s] sha256 matches its manifest" % b)
    print("  FAIL cold bucket[%s]: receipt Ed25519/DSSE signature did not re-verify offline" % b)
    print("::error::verify-cold FAILED: 1 check(s) did not verify")
    sys.exit(1)
print("verify-cold: 1 sealed bucket(s):", "['%s']" % b)
print("  ok   cold tarball[%s] sha256 matches its manifest" % b)
print("  ok   cold bucket[%s] every receipt re-verifies offline" % b)
print("verify-cold PASSED")
sys.exit(0)
PYEOF

  # Capturing notifier — record each page (stdin) so we can count edges.
  cat >"$mbin/notify" <<KEOF
#!/usr/bin/env bash
cat >>"${pages}"
printf '\n---PAGE-END---\n' >>"${pages}"
KEOF
  chmod +x "$mbin/notify"

  local keyenv=()
  if [ "${SC_NO_KEY:-0}" = "1" ]; then
    # No env key, point the cache somewhere empty + an absent cluster so the
    # live-pod lookup cannot succeed -> exercises the UNKNOWN no-op.
    keyenv=(PUBKEY_HEX="" CLUSTER="definitely-no-such-cluster-xyz" KUBECONFIG_FILE="$work/no-such-kubeconfig")
  else
    keyenv=(PUBKEY_HEX="229b6a0abab8787467834b17c7a68e3010309f323665806af7321281878ef419")
  fi

  env "${keyenv[@]}" \
    HOST_COLD_DIR="$cold" STATE_DIR="$statedir" LOG_DIR="$work/log" \
    GUARD_PY="$work/stub_verify.py" STUB_ARGV_FILE="$argvf" SC_VERIFY="${SC_VERIFY:-pass}" \
    NOTIFY_CMD="$mbin/notify" ALERT_PREFIX="[TEST] " \
    PATH="$mbin:$PATH" \
    bash "$F" >"$work/stdout" 2>&1
  H_RC=$?

  H_PAGES="$(grep -c '^---PAGE-END---$' "$pages" 2>/dev/null || true)"; H_PAGES="${H_PAGES:-0}"
  H_TEXT="$(cat "$pages" 2>/dev/null || true)"
  H_STATUS="$(sed -n 's/.*"overall":"\([^"]*\)".*/\1/p' "$statedir/status.json" 2>/dev/null || true)"
  H_STATUS="${H_STATUS:-?}"
  H_ARGV="$( [ -f "$argvf" ] && tr '\0' ' ' <"$argvf" 2>/dev/null || true )"

  [ -n "${SC_REUSE:-}" ] || rm -rf "$work"
}

# ── Check 1 ───────────────────────────────────────────────────────────────────
# The audit script exists and parses clean (bash -n). If it is missing or broken
# the daily job cannot run at all.
chk1() {
  local root="${1:-.}"
  local F="$root/$AUDIT_REL"
  test -f "$F" || {
    err "REGRESSION ($F) — szl-receipts-cold-archive-audit is MISSING. The cold-archive audit is gone."
    return 1
  }
  local out
  if ! out="$(bash -n "$F" 2>&1)"; then
    err "REGRESSION ($F) — szl-receipts-cold-archive-audit does not parse (bash -n failed)."
    echo "$out" | sed 's/^/       | /'
    return 1
  fi
  echo "OK: $F exists and parses clean (bash -n)"
}

# ── Check 2 ───────────────────────────────────────────────────────────────────
# An empty / absent cold dir is a silent no-op: nothing to audit, exit 0, no page,
# status not ALERT.
chk2() {
  local root="${1:-.}"
  _reset_sc; SC_HAVE_COLD=0; _run "$root"
  if [ "${H_RC}" -ne 0 ]; then
    err "REGRESSION — empty-cold-dir run did NOT no-op (exit $H_RC, want 0)."
    return 1
  fi
  if [ "${H_PAGES}" -ne 0 ]; then
    err "REGRESSION — empty-cold-dir run PAGED ($H_PAGES). Nothing-to-audit must be a silent no-op."
    return 1
  fi
  if [ "${H_STATUS}" = "ALERT" ]; then
    err "REGRESSION — empty-cold-dir run set status ALERT (should be a no-op)."
    return 1
  fi
  echo "OK: empty/absent cold dir is a silent no-op (exit 0, no page)"
}

# ── Check 3 ───────────────────────────────────────────────────────────────────
# No public key available (no env, no cache, absent cluster) is a silent no-op
# UNKNOWN: exit 0, NO page. We cannot prove pass OR fail without the key.
chk3() {
  local root="${1:-.}"
  _reset_sc; SC_NO_KEY=1; _run "$root"
  if [ "${H_RC}" -ne 0 ]; then
    err "REGRESSION — no-public-key run did NOT no-op (exit $H_RC, want 0)."
    return 1
  fi
  if [ "${H_PAGES}" -ne 0 ]; then
    err "REGRESSION — no-public-key run PAGED ($H_PAGES). Cannot prove pass/fail without a key => must be a silent no-op."
    return 1
  fi
  if [ "${H_STATUS}" = "ALERT" ]; then
    err "REGRESSION — no-public-key run set status ALERT (should be UNKNOWN no-op, got '$H_STATUS')."
    return 1
  fi
  echo "OK: no public key available is a silent no-op UNKNOWN (exit 0, no page)"
}

# ── Check 4 ───────────────────────────────────────────────────────────────────
# A real verify FAILURE pages an ALERT, sets status ALERT, and names the failing
# bucket in the page.
chk4() {
  local root="${1:-.}"
  _reset_sc; SC_VERIFY=fail; _run "$root"
  if [ "${H_PAGES}" -lt 1 ]; then
    err "REGRESSION — a failing cold-archive verify did NOT page. A corrupt cold bucket would go unalerted."
    return 1
  fi
  if [ "${H_STATUS}" != "ALERT" ]; then
    err "REGRESSION — a failing verify did not set status ALERT (got '$H_STATUS')."
    return 1
  fi
  case "$H_TEXT" in
    *00000001*) : ;;
    *) err "REGRESSION — the ALERT page does not name the failing bucket (00000001)."; return 1 ;;
  esac
  echo "OK: a failing cold-archive verify pages an ALERT and names the failing bucket"
}

# ── Check 5 ───────────────────────────────────────────────────────────────────
# EDGE-DEDUP: while the verify stays failing, the job pages ONLY on the OK->ALERT
# edge — a second consecutive failing run does NOT re-page.
chk5() {
  local root="${1:-.}"
  local w; w="$(mktemp -d)"
  _reset_sc; SC_VERIFY=fail; SC_REUSE="$w"; _run "$root"   # run 1: should page
  _reset_sc; SC_VERIFY=fail; SC_REUSE="$w"; _run "$root"   # run 2: should NOT re-page
  local pages="$H_PAGES"
  rm -rf "$w"
  if [ "${pages}" -ne 1 ]; then
    err "REGRESSION — EDGE-DEDUP GONE: two consecutive failing runs paged ${pages} times (want exactly 1). A persistent failure would re-page every run (paging storm)."
    return 1
  fi
  echo "OK: edge-dedup intact — a persistent failure pages exactly once, not every run"
}

# ── Check 6 ───────────────────────────────────────────────────────────────────
# RECOVERED edge: a passing run AFTER a failing run pages a RECOVERED; and the
# steady-state happy path (a clean run with no prior ALERT) is silent + OK.
chk6() {
  local root="${1:-.}"
  # (a) recovered edge: fail then pass, same state -> exactly 2 pages, 2nd recovered
  local w; w="$(mktemp -d)"
  _reset_sc; SC_VERIFY=fail; SC_REUSE="$w"; _run "$root"
  _reset_sc; SC_VERIFY=pass; SC_REUSE="$w"; _run "$root"
  local pages="$H_PAGES" text="$H_TEXT" status="$H_STATUS"
  rm -rf "$w"
  if [ "${pages}" -ne 2 ]; then
    err "REGRESSION — RECOVERED edge missing: fail-then-pass paged ${pages} times (want 2: the ALERT then the RECOVERED)."
    return 1
  fi
  case "$text" in
    *RECOVERED*) : ;;
    *) err "REGRESSION — the recovery did not emit a RECOVERED page."; return 1 ;;
  esac
  if [ "$status" != "OK" ]; then
    err "REGRESSION — after recovery the status is not OK (got '$status')."
    return 1
  fi
  # (b) steady-state happy path: a single clean run with no prior state is silent
  _reset_sc; SC_VERIFY=pass; _run "$root"
  if [ "${H_PAGES}" -ne 0 ]; then
    err "REGRESSION — a healthy cold-archive audit PAGED ($H_PAGES); the happy path must be silent."
    return 1
  fi
  if [ "${H_STATUS}" != "OK" ]; then
    err "REGRESSION — a healthy cold-archive audit did not set status OK (got '$H_STATUS')."
    return 1
  fi
  echo "OK: recovery pages a RECOVERED and returns to OK; the steady-state happy path is silent"
}

# ── Check 7 ───────────────────────────────────────────────────────────────────
# OFF-BOX / OFFLINE auditor contract: verify-cold is invoked with the PUBLIC KEY
# ONLY (--pubkey-hex) and MUST NOT be passed --tail-first-prev — the audit must
# never silently start depending on the live store to re-verify cold history.
chk7() {
  local root="${1:-.}"
  _reset_sc; SC_VERIFY=pass; _run "$root"
  case "$H_ARGV" in
    *--pubkey-hex*) : ;;
    *) err "REGRESSION — verify-cold was NOT invoked with --pubkey-hex (argv: $H_ARGV)."; return 1 ;;
  esac
  case "$H_ARGV" in
    *--tail-first-prev*)
      err "REGRESSION — verify-cold was invoked with --tail-first-prev. The cold-archive audit must stay an OFFLINE/off-box auditor (public key only), not depend on the live store."
      return 1 ;;
  esac
  case "$H_ARGV" in
    *verify-cold*) : ;;
    *) err "REGRESSION — the verifier was not invoked with the verify-cold subcommand (argv: $H_ARGV)."; return 1 ;;
  esac
  echo "OK: verify-cold is invoked public-key-only (--pubkey-hex, no --tail-first-prev)"
}

# ── Check 8 ───────────────────────────────────────────────────────────────────
# Still wired into install.sh: the sbin script + the .service and .timer units are
# installed, the timer is enabled, and a first run is kicked. Otherwise a box
# rebuild ships without the cold-archive audit running.
chk8() {
  local root="${1:-.}"
  local F="$root/$INSTALL_REL"
  test -f "$F" || { err "REGRESSION ($F) — install.sh missing; cannot verify the cold-archive audit is wired."; return 1; }

  grep -Eq 'install .*sbin/szl-receipts-cold-archive-audit' "$F" || {
    err "REGRESSION ($F) — install.sh no longer installs sbin/szl-receipts-cold-archive-audit."
    return 1
  }
  grep -Fq 'szl-receipts-cold-archive-audit.service' "$F" || {
    err "REGRESSION ($F) — install.sh no longer installs szl-receipts-cold-archive-audit.service."
    return 1
  }
  grep -Fq 'szl-receipts-cold-archive-audit.timer' "$F" || {
    err "REGRESSION ($F) — install.sh no longer installs szl-receipts-cold-archive-audit.timer."
    return 1
  }
  grep -Eq 'systemctl enable --now szl-receipts-cold-archive-audit\.timer' "$F" || {
    err "REGRESSION ($F) — install.sh no longer ENABLES szl-receipts-cold-archive-audit.timer; the audit wouldn't run after a rebuild."
    return 1
  }
  grep -Eq '/usr/local/sbin/szl-receipts-cold-archive-audit \]' "$F" || {
    err "REGRESSION ($F) — install.sh no longer kicks a first run of szl-receipts-cold-archive-audit."
    return 1
  }
  echo "OK: install.sh installs the script + units, enables the timer, and kicks a first run"
}

# ── Check 9 ───────────────────────────────────────────────────────────────────
# Still documented: the retention runbook names the cold-archive audit job, and
# install.sh's banner names it too. An operator rebuilding the box must be able to
# find out the job exists and what it does.
chk9() {
  local root="${1:-.}"
  local R="$root/$RUNBOOK_REL"
  test -f "$R" || { err "REGRESSION ($R) — the receipt-store retention runbook is MISSING."; return 1; }
  grep -Fq 'szl-receipts-cold-archive-audit' "$R" || {
    err "REGRESSION ($R) — the runbook no longer documents the szl-receipts-cold-archive-audit job."
    return 1
  }
  local F="$root/$INSTALL_REL"
  test -f "$F" || { err "REGRESSION ($F) — install.sh missing."; return 1; }
  grep -Fq 'szl-receipts-cold-archive-audit' "$F" || {
    err "REGRESSION ($F) — install.sh banner no longer names szl-receipts-cold-archive-audit."
    return 1
  }
  echo "OK: runbook documents szl-receipts-cold-archive-audit; install.sh names the job"
}

# ── Dispatch ──────────────────────────────────────────────────────────────────
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
