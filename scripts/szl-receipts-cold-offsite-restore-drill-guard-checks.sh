# Copyright 2026 SZL Holdings
# SPDX-License-Identifier: Apache-2.0
#
# szl-receipts-cold-offsite-restore-drill-guard-checks.sh — guard the
# `szl-receipts-cold-offsite-restore-drill` box job (the periodic RESTORE drill
# that proves the OFFSITE cold receipt backup can actually be restored) from
# silently losing its safety properties.
#
# WHY THIS EXISTS
# `szl-receipts-cold-offsite` mirrors each sealed cold bucket OFFSITE and
# sha256-verifies the upload AT WRITE TIME; `szl-receipts-cold-archive-audit`
# re-verifies the ON-BOX cold tarballs offline. Neither ever exercises the
# RESTORE path. `szl-receipts-cold-offsite-restore-drill`
# (box-scripts/sbin/szl-receipts-cold-offsite-restore-drill) closes that gap: it
# periodically DOWNLOADS one mirrored bucket back from the offsite destination,
# sha256-verifies the download against its manifest, and unpacks it into a
# well-formed shard — so the first time anyone learns the offsite copy is
# unrestorable is NOT the day the box is gone. Its value rests on a handful of
# fragile safety properties that produce NO visible symptom when a well-meaning
# refactor breaks them — until the day a restore is actually needed:
#   * nothing configured (no OFFSITE_* destination) = no-op exit 0, no page
#     (SKIPPED_UNCONFIGURED) — an unconfigured box must not become a paging storm;
#   * nothing mirrored offsite yet (no buckets) = silent no-op (nothing to drill);
#   * the SHA256 GATE: a downloaded tarball whose sha256 != its downloaded
#     manifest `tarball_sha256` is a corrupt/truncated offsite copy that would NOT
#     restore — it pages an ALERT;
#   * the WELL-FORMED GATE: a downloaded tarball that does not unpack into a
#     well-formed receipt shard (top-level `<bucket>/` of parseable `*.json`
#     receipts each carrying a `chain` object, matching the manifest `count`) is a
#     backup that would not restore — it pages an ALERT;
#   * the happy path downloads + sha-verifies + restores a healthy bucket SILENTLY
#     (status OK, no page);
#   * alerts are EDGE-TRIGGERED + de-duped — a persistent failure pages ONCE, not
#     every cycle, and emits a RECOVERED on the healthy edge;
#   * it stays WIRED into install.sh (script + units installed, timer enabled) and
#     documented, or a box rebuild silently ships without the restore drill running.
#
# Unlike pure text/lint guards, this one is BEHAVIOURAL: it actually RUNS the real
# drill using the `local` transport (OFFSITE_LOCAL_DIR -> a temp dir, so no
# network/object store is needed) over a fabricated offsite bucket, with a
# capturing notifier, then asserts the observable outcome (exit code, whether it
# paged, the status file). That is the only way to prove the sha256 + well-formed
# gates and the edge-dedup are actually wired into the control flow rather than
# merely present as text.
#
# The check logic is extracted here (out of the workflow) so it can be UNIT
# TESTED: szl-receipts-cold-offsite-restore-drill-guard-checks.test.sh feeds each
# behavioural check a deliberately-BROKEN copy of the script (a gate removed, a
# no-op removed, the dedup removed, ...) and asserts the matching check FAILS,
# plus that the pristine repo PASSES.
#
# Usage:
#   szl-receipts-cold-offsite-restore-drill-guard-checks.sh <check> [root]
#     check : chk1 | chk2 | chk3 | chk4 | chk5 | chk6 | chk7 | chk8 | chk9 | all
#     root  : repo root to check (default: current directory)
#
# Each check exits 0 when the invariant holds and non-zero (printing a GitHub
# ::error annotation) when it is regressed.

set -uo pipefail

err() { echo "::error::$*"; }

# Paths (relative to a repo root) of the files this guard inspects.
DRILL_REL="box-scripts/sbin/szl-receipts-cold-offsite-restore-drill"
INSTALL_REL="box-scripts/install.sh"
RUNBOOK_REL="docs/operations/RECEIPT_STORE_RETENTION_RUNBOOK.md"

# ── Scenario config (set per-check, read by _run) ─────────────────────────────
_reset_sc() {
  unset SC_CONFIGURE SC_HAVE_BUCKET SC_SHA_OK SC_WELLFORMED SC_PERSIST 2>/dev/null || true
}

# _run ROOT — run the real restore-drill script (local transport) over a
# fabricated offsite dir and set globals:
#   H_RC      exit code
#   H_PAGES   number of pages emitted (0 = silent)
#   H_TEXT    concatenated page text
#   H_STATUS  overall field from the status JSON (OK|ALERT|UNKNOWN|?)
#
# Scenario inputs (defaults in parens):
#   SC_CONFIGURE  (1)   0 => no OFFSITE_* destination set (unconfigured)
#   SC_HAVE_BUCKET(1)   0 => the offsite dir has no mirrored buckets
#   SC_SHA_OK     (1)   0 => manifest tarball_sha256 != the tarball (corrupt copy)
#   SC_WELLFORMED (1)   0 => receipts in the tarball lack a `chain` (malformed)
#   SC_PERSIST    ("")  a dir to reuse as work (state survives across calls) for
#                       edge-dedup; when empty a fresh temp dir is used + removed.
_run() {
  local root="${1:-.}"
  local F="$root/$DRILL_REL"
  local persist="${SC_PERSIST:-}"
  local work
  if [ -n "$persist" ]; then work="$persist"; else work="$(mktemp -d)"; fi
  local mbin="$work/bin"; mkdir -p "$mbin"
  local offsite="$work/offsite"; mkdir -p "$offsite"
  local statedir="$work/state"; mkdir -p "$statedir"
  local pages="$work/pages"; : >"$pages"
  local bucket="00000001"

  # Build a fake offsite bucket: a REAL .tar.gz containing `<bucket>/*.json`
  # receipts (the same layout szl-receipts-retention seals — `tar.add(bdir,
  # arcname=bucket)`), plus a manifest whose tarball_sha256 + count match — unless
  # a scenario deliberately breaks the sha (SC_SHA_OK=0) or the shape
  # (SC_WELLFORMED=0). Rebuilt every call so edge-dedup runs see a fresh copy.
  rm -f "$offsite"/*.tar.gz "$offsite"/*.manifest.json 2>/dev/null || true
  if [ "${SC_HAVE_BUCKET:-1}" = "1" ]; then
    local stage="$work/stage"; rm -rf "$stage"; mkdir -p "$stage/$bucket"
    local i
    for i in 1 2 3; do
      if [ "${SC_WELLFORMED:-1}" = "0" ]; then
        # Malformed: a receipt with NO `chain` object (sha + count still valid,
        # so it passes the sha gate and is caught ONLY by the well-formed gate).
        printf '{"not_a_chain": %d}\n' "$i" >"$stage/$bucket/$i.json"
      else
        printf '{"chain": {"chain_index": %d, "hash": "h%d"}}\n' "$i" "$i" >"$stage/$bucket/$i.json"
      fi
    done
    tar -czf "$offsite/$bucket.tar.gz" -C "$stage" "$bucket"
    local realsha; realsha="$(sha256sum "$offsite/$bucket.tar.gz" | awk '{print $1}')"
    local mansha="$realsha"
    [ "${SC_SHA_OK:-1}" = "0" ] && mansha="0000000000000000000000000000000000000000000000000000000000000000"
    printf '{"tarball_sha256": "%s", "count": 3, "last_hash": "deadbeef", "archived_at": "2026-06-01T00:00:00Z"}\n' \
      "$mansha" >"$offsite/$bucket.manifest.json"
  fi

  # Capturing notifier — record each page (stdin) so we can count edges.
  cat >"$mbin/notify" <<KEOF
#!/usr/bin/env bash
cat >>"${pages}"
printf '\n---PAGE-END---\n' >>"${pages}"
KEOF
  chmod +x "$mbin/notify"

  local localdir=""
  [ "${SC_CONFIGURE:-1}" = "1" ] && localdir="$offsite"

  env OFFSITE_LOCAL_DIR="$localdir" \
    STATE_DIR="$statedir" LOG_DIR="$work/log" \
    NOTIFY_CMD="$mbin/notify" ALERT_PREFIX="[TEST] " \
    PATH="$PATH" \
    bash "$F" >"$work/stdout" 2>&1
  H_RC=$?

  H_PAGES="$(grep -c '^---PAGE-END---$' "$pages" 2>/dev/null || true)"; H_PAGES="${H_PAGES:-0}"
  H_TEXT="$(cat "$pages" 2>/dev/null || true)"
  H_STATUS="$(sed -n 's/.*"overall":"\([^"]*\)".*/\1/p' "$statedir/status.json" 2>/dev/null || true)"
  H_STATUS="${H_STATUS:-?}"

  [ -z "$persist" ] && rm -rf "$work"
}

# ── Check 1 ───────────────────────────────────────────────────────────────────
# The drill script exists and parses clean (bash -n). If it is missing or broken
# the periodic restore drill cannot run at all.
chk1() {
  local root="${1:-.}"
  local F="$root/$DRILL_REL"
  test -f "$F" || {
    err "REGRESSION ($F) — szl-receipts-cold-offsite-restore-drill is MISSING. The offsite restore drill is gone."
    return 1
  }
  local out
  if ! out="$(bash -n "$F" 2>&1)"; then
    err "REGRESSION ($F) — szl-receipts-cold-offsite-restore-drill does not parse (bash -n failed)."
    echo "$out" | sed 's/^/       | /'
    return 1
  fi
  echo "OK: $F exists and parses clean (bash -n)"
}

# ── Check 2 ───────────────────────────────────────────────────────────────────
# Unconfigured = true no-op: exit 0, no page, status not ALERT. An unconfigured
# box must never page (SKIPPED_UNCONFIGURED).
chk2() {
  local root="${1:-.}"
  _reset_sc; SC_CONFIGURE=0; _run "$root"
  if [ "${H_RC}" -ne 0 ]; then
    err "REGRESSION — unconfigured run did NOT no-op (exit $H_RC, want 0)."
    return 1
  fi
  if [ "${H_PAGES}" -ne 0 ]; then
    err "REGRESSION — unconfigured run PAGED ($H_PAGES). No OFFSITE_* destination must be a silent no-op."
    return 1
  fi
  if [ "${H_STATUS}" = "ALERT" ]; then
    err "REGRESSION — unconfigured run set status ALERT (should be a SKIPPED_UNCONFIGURED no-op)."
    return 1
  fi
  echo "OK: unconfigured is a silent no-op (exit 0, no page, SKIPPED_UNCONFIGURED)"
}

# ── Check 3 ───────────────────────────────────────────────────────────────────
# Nothing mirrored offsite yet (no buckets) is a silent no-op: nothing to drill,
# no page.
chk3() {
  local root="${1:-.}"
  _reset_sc; SC_HAVE_BUCKET=0; _run "$root"
  if [ "${H_RC}" -ne 0 ]; then
    err "REGRESSION — no-buckets run did NOT no-op (exit $H_RC, want 0)."
    return 1
  fi
  if [ "${H_PAGES}" -ne 0 ]; then
    err "REGRESSION — no-buckets run PAGED ($H_PAGES). Nothing-to-restore must be a silent no-op."
    return 1
  fi
  if [ "${H_STATUS}" = "ALERT" ]; then
    err "REGRESSION — no-buckets run set status ALERT (should be a silent no-op)."
    return 1
  fi
  echo "OK: nothing mirrored offsite yet is a silent no-op (nothing to drill)"
}

# ── Check 4 ───────────────────────────────────────────────────────────────────
# THE SHA256 GATE: a downloaded tarball whose sha256 != its manifest
# tarball_sha256 is a corrupt/truncated offsite copy — it pages an ALERT (and
# does NOT report a healthy restore).
chk4() {
  local root="${1:-.}"
  _reset_sc; SC_SHA_OK=0; _run "$root"
  if [ "${H_PAGES}" -lt 1 ]; then
    err "REGRESSION — SHA256 GATE GONE: a downloaded tarball that FAILS its manifest sha256 did NOT page. A corrupt offsite copy would be reported restorable."
    return 1
  fi
  if [ "${H_STATUS}" != "ALERT" ]; then
    err "REGRESSION — an offsite sha256 mismatch did not set status ALERT (got '$H_STATUS')."
    return 1
  fi
  echo "OK: sha256 gate intact — a corrupt/truncated offsite copy pages an ALERT"
}

# ── Check 5 ───────────────────────────────────────────────────────────────────
# THE WELL-FORMED GATE: a downloaded tarball that passes its sha256 but does NOT
# unpack into a well-formed receipt shard (receipts missing their `chain`) pages
# an ALERT — a backup that would not restore must be caught.
chk5() {
  local root="${1:-.}"
  _reset_sc; SC_WELLFORMED=0; _run "$root"
  if [ "${H_PAGES}" -lt 1 ]; then
    err "REGRESSION — WELL-FORMED GATE GONE: a tarball that unpacks into MALFORMED receipts did NOT page. An unrestorable backup would be reported healthy."
    return 1
  fi
  if [ "${H_STATUS}" != "ALERT" ]; then
    err "REGRESSION — a malformed restored shard did not set status ALERT (got '$H_STATUS')."
    return 1
  fi
  echo "OK: well-formed gate intact — a tarball that does not restore into a valid shard pages an ALERT"
}

# ── Check 6 ───────────────────────────────────────────────────────────────────
# THE HAPPY PATH: a healthy bucket is downloaded, sha-verified, and restored into
# a well-formed shard SILENTLY (status OK, no page).
chk6() {
  local root="${1:-.}"
  _reset_sc; _run "$root"
  if [ "${H_PAGES}" -ne 0 ]; then
    err "REGRESSION — a healthy restore drill PAGED ($H_PAGES); the happy path must be silent. Text: $H_TEXT"
    return 1
  fi
  if [ "${H_STATUS}" != "OK" ]; then
    err "REGRESSION — a healthy restore drill did not set status OK (got '$H_STATUS'). A restorable backup must verify clean."
    return 1
  fi
  echo "OK: happy path downloads + sha-verifies + restores a well-formed shard (silent, status OK)"
}

# ── Check 7 ───────────────────────────────────────────────────────────────────
# EDGE-TRIGGERED + DE-DUPED: a persistent failure pages ONCE (not every cycle),
# and the healthy edge emits a RECOVERED. Uses a persistent work dir so the
# last_status state survives across runs.
chk7() {
  local root="${1:-.}"
  local pdir; pdir="$(mktemp -d)"

  # Run 1: corrupt offsite copy -> ALERT, should page (OK->ALERT edge).
  _reset_sc; SC_SHA_OK=0; SC_PERSIST="$pdir"; _run "$root"
  local p1="$H_PAGES"
  if [ "${p1}" -lt 1 ]; then
    err "REGRESSION — first failing run did not page; cannot evaluate edge-dedup."
    rm -rf "$pdir"; return 1
  fi

  # Run 2: still corrupt -> ALERT again, must NOT re-page (de-duped).
  _reset_sc; SC_SHA_OK=0; SC_PERSIST="$pdir"; _run "$root"
  if [ "${H_PAGES}" -ne 0 ]; then
    err "REGRESSION — EDGE-DEDUP GONE: a still-failing restore drill RE-PAGED ($H_PAGES) instead of staying quiet. A persistent failure would page every cycle."
    rm -rf "$pdir"; return 1
  fi

  # Run 3: healthy again -> must emit a RECOVERED on the ALERT->OK edge.
  _reset_sc; SC_PERSIST="$pdir"; _run "$root"
  if [ "${H_PAGES}" -lt 1 ]; then
    err "REGRESSION — RECOVERED edge GONE: returning to healthy did NOT emit a recovery page."
    rm -rf "$pdir"; return 1
  fi
  case "$H_TEXT" in
    *RECOVERED*) : ;;
    *) err "REGRESSION — the recovery page is not a RECOVERED notice (text: $H_TEXT)."; rm -rf "$pdir"; return 1 ;;
  esac

  rm -rf "$pdir"
  echo "OK: alerts are edge-triggered + de-duped (page once on failure, RECOVERED on the healthy edge)"
}

# ── Check 8 ───────────────────────────────────────────────────────────────────
# Still wired into install.sh: the sbin script + the .service and .timer units
# are installed and the timer is enabled. Otherwise a box rebuild ships without
# the restore drill running.
chk8() {
  local root="${1:-.}"
  local F="$root/$INSTALL_REL"
  test -f "$F" || { err "REGRESSION ($F) — install.sh missing; cannot verify the restore drill is wired."; return 1; }

  grep -Eq 'install .*sbin/szl-receipts-cold-offsite-restore-drill' "$F" || {
    err "REGRESSION ($F) — install.sh no longer installs sbin/szl-receipts-cold-offsite-restore-drill."
    return 1
  }
  grep -Fq 'szl-receipts-cold-offsite-restore-drill.service' "$F" || {
    err "REGRESSION ($F) — install.sh no longer installs szl-receipts-cold-offsite-restore-drill.service."
    return 1
  }
  grep -Fq 'szl-receipts-cold-offsite-restore-drill.timer' "$F" || {
    err "REGRESSION ($F) — install.sh no longer installs szl-receipts-cold-offsite-restore-drill.timer."
    return 1
  }
  grep -Eq 'systemctl enable --now szl-receipts-cold-offsite-restore-drill\.timer' "$F" || {
    err "REGRESSION ($F) — install.sh no longer ENABLES szl-receipts-cold-offsite-restore-drill.timer; the drill wouldn't run after a rebuild."
    return 1
  }
  echo "OK: install.sh installs the script + units and enables the timer"
}

# ── Check 9 ───────────────────────────────────────────────────────────────────
# Still documented: the retention runbook names the restore-drill job, and
# install.sh's banner names it too. An operator rebuilding the box must be able to
# find out the job exists and what it does.
chk9() {
  local root="${1:-.}"
  local R="$root/$RUNBOOK_REL"
  test -f "$R" || { err "REGRESSION ($R) — the receipt-store retention runbook is MISSING."; return 1; }
  grep -Fq 'szl-receipts-cold-offsite-restore-drill' "$R" || {
    err "REGRESSION ($R) — the runbook no longer documents the szl-receipts-cold-offsite-restore-drill job."
    return 1
  }
  local F="$root/$INSTALL_REL"
  test -f "$F" || { err "REGRESSION ($F) — install.sh missing."; return 1; }
  grep -Fq 'szl-receipts-cold-offsite-restore-drill' "$F" || {
    err "REGRESSION ($F) — install.sh banner no longer names szl-receipts-cold-offsite-restore-drill."
    return 1
  }
  echo "OK: runbook documents szl-receipts-cold-offsite-restore-drill; install.sh names the job"
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
