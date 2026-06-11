# Copyright 2026 SZL Holdings
# SPDX-License-Identifier: Apache-2.0
#
# szl-receipts-cold-offsite-guard-checks.sh — guard the `szl-receipts-cold-offsite`
# box job (the daily OFFSITE mirror of the box cold receipt archive) from
# silently losing its safety properties.
#
# WHY THIS EXISTS
# `szl-receipts-cold-offsite` (box-scripts/sbin/szl-receipts-cold-offsite) runs
# daily and mirrors the box cold receipt archive (HOST_COLD_DIR, populated by
# szl-receipts-retention) to a SECOND location so the sealed receipt history
# survives loss of the box. Its value rests on a handful of fragile safety
# properties that produce NO visible symptom when a well-meaning refactor breaks
# them — until either a corrupt archive is mirrored, a bad upload is recorded as
# done, or the offsite copy silently stops happening:
#   * nothing configured (no OFFSITE_* destination) = no-op exit 0, no page
#     (SKIPPED_UNCONFIGURED) — an unconfigured box must not become a paging storm;
#   * an empty / absent cold dir = silent no-op (nothing to mirror);
#   * the LOCAL VERIFY GATE: a bucket whose on-box tarball sha256 != its manifest
#     `tarball_sha256` is NEVER mirrored offsite, and pages (corrupt at source);
#   * the OFFSITE VERIFY GATE: the per-bucket "done" marker is written ONLY AFTER
#     the offsite copy's sha256 matches the manifest (remote_sha256) — a mismatch
#     leaves NO marker (so it retries) and pages;
#   * the happy path mirrors a healthy bucket, verifies it offsite, writes the
#     marker, and is INCREMENTAL (a second run does not re-upload it);
#   * it stays WIRED into install.sh (script + units installed, timer enabled,
#     env stub seeded) and documented, or a box rebuild silently ships without
#     the offsite mirror running.
#
# Unlike pure text/lint guards, this one is BEHAVIOURAL: it actually RUNS the real
# offsite script using the `local` transport (OFFSITE_LOCAL_DIR -> a temp dir, so
# no network/object store is needed) over a fabricated HOST_COLD_DIR of fake
# buckets, with a capturing notifier, then asserts the observable outcome (exit
# code, whether it paged, the status file, whether the offsite file landed, and
# whether the incremental marker was written). That is the only way to prove the
# local + offsite verify gates and the incremental marker are actually wired into
# the control flow rather than merely present as text.
#
# The check logic is extracted here (out of the workflow) so it can be UNIT
# TESTED: szl-receipts-cold-offsite-guard-checks.test.sh feeds each behavioural
# check a deliberately-BROKEN copy of the script (a verify gate removed, the
# unconfigured no-op removed, the marker write removed, ...) and asserts the
# matching check FAILS, plus that the pristine repo PASSES.
#
# Usage:
#   szl-receipts-cold-offsite-guard-checks.sh <check> [root]
#     check : chk1 | chk2 | chk3 | chk4 | chk5 | chk6 | chk7 | chk8 | all
#     root  : repo root to check (default: current directory)
#
# Each check exits 0 when the invariant holds and non-zero (printing a GitHub
# ::error annotation) when it is regressed.

set -uo pipefail

err() { echo "::error::$*"; }

# Paths (relative to a repo root) of the files this guard inspects.
OFFSITE_REL="box-scripts/sbin/szl-receipts-cold-offsite"
INSTALL_REL="box-scripts/install.sh"
RUNBOOK_REL="docs/operations/RECEIPT_STORE_RETENTION_RUNBOOK.md"

# ── Scenario config (set per-check, read by _run) ─────────────────────────────
_reset_sc() {
  unset SC_CONFIGURE SC_HAVE_COLD SC_LOCAL_OK SC_OFFSITE_OK SC_PRESEED_MARKER 2>/dev/null || true
}

# _run ROOT — run the real offsite script (local transport) over a fabricated
# cold dir and set globals:
#   H_RC       exit code
#   H_PAGES    number of pages emitted (0 = silent)
#   H_TEXT     concatenated page text
#   H_STATUS   overall field from the status JSON (OK|ALERT|UNKNOWN|?)
#   H_LANDED   1 if the bucket tarball landed in the offsite dir, else 0
#   H_MARKED   1 if the per-bucket sync marker was written, else 0
#
# Scenario inputs (defaults in parens):
#   SC_CONFIGURE     (1)     0 => no OFFSITE_* destination set (unconfigured)
#   SC_HAVE_COLD     (1)     0 => the cold dir has no sealed buckets
#   SC_LOCAL_OK      (1)     0 => the on-box tarball sha != manifest (local corrupt)
#   SC_OFFSITE_OK    (1)     0 => the offsite copy is corrupted after upload
#   SC_PRESEED_MARKER(0)     1 => pre-write the marker (simulate already-synced)
_run() {
  local root="${1:-.}"
  local F="$root/$OFFSITE_REL"
  local work; work="$(mktemp -d)"
  local mbin="$work/bin"; mkdir -p "$mbin"
  local cold="$work/cold"; mkdir -p "$cold"
  local offsite="$work/offsite"
  local pages="$work/pages"; : >"$pages"
  local bucket="00000001"

  # Build a fake sealed bucket: a tarball + a manifest whose tarball_sha256
  # matches (or, for SC_LOCAL_OK=0, deliberately does not match) the tarball.
  if [ "${SC_HAVE_COLD:-1}" = "1" ]; then
    printf 'SZL-FAKE-COLD-TARBALL-%s' "$bucket" >"$cold/$bucket.tar.gz"
    local realsha; realsha="$(sha256sum "$cold/$bucket.tar.gz" | awk '{print $1}')"
    local mansha="$realsha"
    [ "${SC_LOCAL_OK:-1}" = "0" ] && mansha="0000000000000000000000000000000000000000000000000000000000000000"
    printf '{"tarball_sha256": "%s", "count": 3, "last_hash": "deadbeef", "archived_at": "2026-06-01T00:00:00Z"}\n' \
      "$mansha" >"$cold/$bucket.manifest.json"
    printf '{"buckets": ["%s"]}\n' "$bucket" >"$cold/archived.json"
  fi

  # `sha256sum` wrapper that, when SC_OFFSITE_OK=0, corrupts the OFFSITE copy
  # right before it is hashed back — so remote_sha256 returns a non-matching
  # digest (an upload that arrived corrupt). The on-box read is left untouched.
  # Resolve the REAL sha256sum now (before $mbin is on PATH) so the wrapper can
  # delegate to it without recursing.
  local real_sha; real_sha="$(command -v sha256sum)"
  cat >"$mbin/sha256sum" <<SEOF
#!/usr/bin/env bash
if [ "${SC_OFFSITE_OK:-1}" = "0" ]; then
  for a in "\$@"; do
    case "\$a" in
      "$offsite/"*) printf 'CORRUPTED-OFFSITE' >"\$a" 2>/dev/null ;;
    esac
  done
fi
exec "$real_sha" "\$@"
SEOF
  chmod +x "$mbin/sha256sum"

  # Capturing notifier — record each page (stdin) so we can count edges.
  cat >"$mbin/notify" <<KEOF
#!/usr/bin/env bash
cat >>"${pages}"
printf '\n---PAGE-END---\n' >>"${pages}"
KEOF
  chmod +x "$mbin/notify"

  # Optionally pre-seed the marker to simulate an already-synced bucket.
  local statedir="$work/state"
  if [ "${SC_PRESEED_MARKER:-0}" = "1" ]; then
    mkdir -p "$statedir/synced"; : >"$statedir/synced/$bucket"
  fi

  local localdir_env=()
  if [ "${SC_CONFIGURE:-1}" = "1" ]; then
    localdir_env=(OFFSITE_LOCAL_DIR="$offsite")
  fi

  env "${localdir_env[@]}" \
    HOST_COLD_DIR="$cold" STATE_DIR="$statedir" LOG_DIR="$work/log" \
    NOTIFY_CMD="$mbin/notify" ALERT_PREFIX="[TEST] " \
    PATH="$mbin:$PATH" \
    bash "$F" >"$work/stdout" 2>&1
  H_RC=$?

  H_PAGES="$(grep -c '^---PAGE-END---$' "$pages" 2>/dev/null || true)"; H_PAGES="${H_PAGES:-0}"
  H_TEXT="$(cat "$pages" 2>/dev/null || true)"
  H_STATUS="$(sed -n 's/.*"overall":"\([^"]*\)".*/\1/p' "$statedir/status.json" 2>/dev/null || true)"
  H_STATUS="${H_STATUS:-?}"
  if [ -f "$offsite/$bucket.tar.gz" ]; then H_LANDED=1; else H_LANDED=0; fi
  if [ -f "$statedir/synced/$bucket" ]; then H_MARKED=1; else H_MARKED=0; fi

  rm -rf "$work"
}

# ── Check 1 ───────────────────────────────────────────────────────────────────
# The offsite script exists and parses clean (bash -n). If it is missing or
# broken the daily job cannot run at all.
chk1() {
  local root="${1:-.}"
  local F="$root/$OFFSITE_REL"
  test -f "$F" || {
    err "REGRESSION ($F) — szl-receipts-cold-offsite is MISSING. The offsite receipt mirror is gone."
    return 1
  }
  local out
  if ! out="$(bash -n "$F" 2>&1)"; then
    err "REGRESSION ($F) — szl-receipts-cold-offsite does not parse (bash -n failed)."
    echo "$out" | sed 's/^/       | /'
    return 1
  fi
  echo "OK: $F exists and parses clean (bash -n)"
}

# ── Check 2 ───────────────────────────────────────────────────────────────────
# Unconfigured = true no-op: exit 0, no page, status not ALERT, nothing mirrored.
# An unconfigured box must never page (SKIPPED_UNCONFIGURED).
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
# An empty / absent cold dir is a silent no-op: nothing to mirror, no page.
chk3() {
  local root="${1:-.}"
  _reset_sc; SC_HAVE_COLD=0; _run "$root"
  if [ "${H_RC}" -ne 0 ]; then
    err "REGRESSION — empty-cold-dir run did NOT no-op (exit $H_RC, want 0)."
    return 1
  fi
  if [ "${H_PAGES}" -ne 0 ]; then
    err "REGRESSION — empty-cold-dir run PAGED ($H_PAGES). Nothing-to-mirror must be a silent no-op."
    return 1
  fi
  echo "OK: empty/absent cold dir is a silent no-op (nothing to mirror)"
}

# ── Check 4 ───────────────────────────────────────────────────────────────────
# THE LOCAL VERIFY GATE: a bucket whose on-box tarball sha256 != its manifest
# tarball_sha256 is NEVER mirrored offsite, and pages an ALERT.
chk4() {
  local root="${1:-.}"
  _reset_sc; SC_LOCAL_OK=0; _run "$root"
  if [ "${H_LANDED}" -ne 0 ]; then
    err "REGRESSION — LOCAL VERIFY GATE GONE: a locally-corrupt bucket (tarball sha != manifest) was STILL mirrored offsite. Corruption would propagate."
    return 1
  fi
  if [ "${H_PAGES}" -lt 1 ]; then
    err "REGRESSION — a locally-corrupt bucket did NOT page. A bad on-box archive would go unalerted."
    return 1
  fi
  if [ "${H_STATUS}" != "ALERT" ]; then
    err "REGRESSION — a local sha mismatch did not set status ALERT (got '$H_STATUS')."
    return 1
  fi
  echo "OK: local verify gate intact — a locally-corrupt bucket is NOT mirrored and pages an ALERT"
}

# ── Check 5 ───────────────────────────────────────────────────────────────────
# THE OFFSITE VERIFY GATE: when the offsite copy fails its sha256 (remote_sha256
# != manifest), the per-bucket marker is NOT written (so it retries) and it
# pages an ALERT.
chk5() {
  local root="${1:-.}"
  _reset_sc; SC_OFFSITE_OK=0; _run "$root"
  if [ "${H_MARKED}" -ne 0 ]; then
    err "REGRESSION — OFFSITE VERIFY GATE GONE: a bucket whose offsite copy FAILED sha256 was still marked done. A corrupt upload would never retry."
    return 1
  fi
  if [ "${H_PAGES}" -lt 1 ]; then
    err "REGRESSION — an offsite sha256 mismatch did NOT page. A corrupt offsite copy would go unalerted."
    return 1
  fi
  if [ "${H_STATUS}" != "ALERT" ]; then
    err "REGRESSION — an offsite sha mismatch did not set status ALERT (got '$H_STATUS')."
    return 1
  fi
  echo "OK: offsite verify gate intact — an offsite sha256 mismatch leaves no marker and pages an ALERT"
}

# ── Check 6 ───────────────────────────────────────────────────────────────────
# THE HAPPY PATH + INCREMENTAL: a healthy bucket is mirrored offsite, verified,
# and its marker written (no page). A second run with the marker present does NOT
# re-upload (incremental) and stays OK.
chk6() {
  local root="${1:-.}"
  # (a) first run mirrors + verifies + marks, no page
  _reset_sc; _run "$root"
  if [ "${H_LANDED}" -ne 1 ]; then
    err "REGRESSION — a healthy bucket was NOT mirrored offsite ($H_LANDED). The offsite copy never happens."
    return 1
  fi
  if [ "${H_MARKED}" -ne 1 ]; then
    err "REGRESSION — a verified offsite mirror did NOT write its sync marker ($H_MARKED). Every run would re-upload."
    return 1
  fi
  if [ "${H_PAGES}" -ne 0 ]; then
    err "REGRESSION — a healthy offsite mirror PAGED ($H_PAGES); the happy path must be silent."
    return 1
  fi
  if [ "${H_STATUS}" != "OK" ]; then
    err "REGRESSION — a healthy offsite mirror did not set status OK (got '$H_STATUS')."
    return 1
  fi
  # (b) second run: marker already present -> incremental skip, nothing re-landed
  _reset_sc; SC_PRESEED_MARKER=1; _run "$root"
  if [ "${H_LANDED}" -ne 0 ]; then
    err "REGRESSION — INCREMENTAL GATE GONE: an already-synced bucket (marker present) was RE-UPLOADED ($H_LANDED). Sealed buckets must not re-transfer."
    return 1
  fi
  if [ "${H_PAGES}" -ne 0 ]; then
    err "REGRESSION — an already-synced run PAGED ($H_PAGES); it should be a silent no-op."
    return 1
  fi
  echo "OK: happy path mirrors+verifies+marks (silent), and is incremental (already-synced bucket is not re-uploaded)"
}

# ── Check 7 ───────────────────────────────────────────────────────────────────
# Still wired into install.sh: the sbin script + the .service and .timer units
# are installed, the env stub is seeded, and the timer is enabled. Otherwise a
# box rebuild ships without the offsite mirror running.
chk7() {
  local root="${1:-.}"
  local F="$root/$INSTALL_REL"
  test -f "$F" || { err "REGRESSION ($F) — install.sh missing; cannot verify the offsite mirror is wired."; return 1; }

  grep -Eq 'install .*sbin/szl-receipts-cold-offsite' "$F" || {
    err "REGRESSION ($F) — install.sh no longer installs sbin/szl-receipts-cold-offsite."
    return 1
  }
  grep -Fq 'szl-receipts-cold-offsite.service' "$F" || {
    err "REGRESSION ($F) — install.sh no longer installs szl-receipts-cold-offsite.service."
    return 1
  }
  grep -Fq 'szl-receipts-cold-offsite.timer' "$F" || {
    err "REGRESSION ($F) — install.sh no longer installs szl-receipts-cold-offsite.timer."
    return 1
  }
  grep -Fq '/etc/szl-receipts-cold-offsite.env' "$F" || {
    err "REGRESSION ($F) — install.sh no longer seeds the /etc/szl-receipts-cold-offsite.env stub."
    return 1
  }
  grep -Eq 'systemctl enable --now szl-receipts-cold-offsite\.timer' "$F" || {
    err "REGRESSION ($F) — install.sh no longer ENABLES szl-receipts-cold-offsite.timer; the mirror wouldn't run after a rebuild."
    return 1
  }
  echo "OK: install.sh installs the script + units, seeds the env stub, and enables the timer"
}

# ── Check 8 ───────────────────────────────────────────────────────────────────
# Still documented: the retention runbook names the offsite mirror job, and
# install.sh's banner names it too. An operator rebuilding the box must be able to
# find out the job exists and what it does.
chk8() {
  local root="${1:-.}"
  local R="$root/$RUNBOOK_REL"
  test -f "$R" || { err "REGRESSION ($R) — the receipt-store retention runbook is MISSING."; return 1; }
  grep -Fq 'szl-receipts-cold-offsite' "$R" || {
    err "REGRESSION ($R) — the runbook no longer documents the szl-receipts-cold-offsite job."
    return 1
  }
  local F="$root/$INSTALL_REL"
  test -f "$F" || { err "REGRESSION ($F) — install.sh missing."; return 1; }
  grep -Fq 'szl-receipts-cold-offsite' "$F" || {
    err "REGRESSION ($F) — install.sh banner no longer names szl-receipts-cold-offsite."
    return 1
  }
  echo "OK: runbook documents szl-receipts-cold-offsite; install.sh names the job"
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
