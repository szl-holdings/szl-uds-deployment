#!/usr/bin/env bash
#
# restore-fleet.sh — prove box-scripts/install.sh is a complete, idempotent,
# self-restoring installer for the box 167.233.50.75 host helpers:
#
#   Phase 1  Back up + WIPE every install.sh-managed sbin script and systemd
#            unit, re-run install.sh, then assert each managed file came back
#            with its declared mode AND every `enable --now` target is both
#            is-enabled=enabled and is-active=active.
#   Phase 2  Re-run install.sh and assert the private env files
#            (a11oy-uptime / szl-alert-relay / vault-keystore-offbox) are NOT
#            clobbered (md5 unchanged) — i.e. an existing channel survives.
#   Phase 3  Move each env file aside, re-run install.sh, and assert the stub is
#            re-seeded ONLY when absent (mode 600 + the expected template), then
#            restore the real file.
#   Phase 4  Verify every env file is byte-identical to how the test found it.
#
# The managed set, enable targets, modes, and env files are DERIVED from
# install.sh at runtime (never hardcoded) so this stays correct as box-scripts/
# grows. Exit non-zero on ANY missed assertion.
#
# This is a BOX integration test: it needs root + systemd and it mutates
# /usr/local/sbin + /etc/systemd/system, so it is gated behind CONFIRM=1 (or a
# --yes arg). Everything is backed up first and the EXIT trap re-instates any
# managed file left missing + the original env files, so an abort never leaves
# the fleet broken. It NEVER reaches the real alert channel: NOTIFY_CMD is
# pointed at a local capture stub for the whole run, so install.sh's
# post-install watcher sweep cannot page anyone.
#
#   sudo CONFIRM=1 ./restore-fleet.sh        # run it on the box
#   sudo STRICT=1 CONFIRM=1 ./restore-fleet.sh   # treat an unmet precondition as FAIL
#
# Exit: 0 = all assertions passed; 1 = an assertion failed; 77 = skipped
# (not root / no systemd / not confirmed; FAIL instead if STRICT=1).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOX="$(cd "$HERE/.." && pwd)"
INSTALL_SH="$BOX/install.sh"
SBIN_DIR="/usr/local/sbin"
UNIT_DIR="/etc/systemd/system"

skip() {
  if [ "${STRICT:-0}" = "1" ]; then echo "FAIL (STRICT): $*" >&2; exit 1; fi
  echo "SKIP: $*"; exit 77
}

# ---- preconditions ----------------------------------------------------------
[ -r "$INSTALL_SH" ]                  || skip "install.sh not found/readable at $INSTALL_SH"
[ "$(id -u)" -eq 0 ]                  || skip "must run as root (sudo) — this test wipes $SBIN_DIR + $UNIT_DIR"
command -v systemctl >/dev/null 2>&1  || skip "systemd (systemctl) not available"
case "${1:-}" in --yes) CONFIRM=1 ;; esac
[ "${CONFIRM:-0}" = "1" ]             || skip "destructive test; re-run as: sudo CONFIRM=1 $0"

checks=0; fails=0
ok()   { checks=$((checks+1)); printf '  ok   %s\n' "$1"; }
fail() { checks=$((checks+1)); fails=$((fails+1)); printf '  FAIL %s\n' "$1"; }
mode_of() { stat -c '%a' "$1" 2>/dev/null; }
md5_of()  { md5sum "$1" 2>/dev/null | awk '{print $1}'; }

# ---- derive the managed set + enable targets from install.sh ----------------
# Each managed file line is:  install -m <mode> "$here/<kind>/<f>" <dest>
#   $3 = mode, $NF = dest. We key on the SOURCE prefix so the nginx snippet,
#   `install -d` dirs, and the per-cluster env templates are excluded.
derive_install() { # kind: sbin | systemd
  grep -F "\"\$here/$1/" "$INSTALL_SH" \
    | grep -E '(^|[[:space:]])install[[:space:]]' \
    | awk '{print $3"|"$NF}'
}
mapfile -t SBIN_ENTRIES < <(derive_install sbin)
mapfile -t UNIT_ENTRIES < <(derive_install systemd)
[ "${#SBIN_ENTRIES[@]}" -gt 0 ] && ok "derived ${#SBIN_ENTRIES[@]} managed sbin scripts from install.sh" \
                                || fail "derived ZERO managed sbin scripts from install.sh"
[ "${#UNIT_ENTRIES[@]}" -gt 0 ] && ok "derived ${#UNIT_ENTRIES[@]} managed units from install.sh" \
                                || fail "derived ZERO managed units from install.sh"

# `enable --now` targets: the unindented literal lines, PLUS the templated
# receipt-{chain,flood}-watch@<cluster> instances expanded with the same default
# cluster list install.sh uses (RECEIPT_WATCH_EXTRA_CLUSTERS, default uds-tenant).
mapfile -t ENABLE_TARGETS < <(grep -E '^systemctl enable --now ' "$INSTALL_SH" | awk '{print $4}' | tr -d '"')
clusters="${RECEIPT_WATCH_EXTRA_CLUSTERS:-uds-tenant}"
for tmpl in receipt-chain-watch receipt-flood-watch; do
  if grep -qF "enable --now \"$tmpl@\${c}.timer\"" "$INSTALL_SH"; then
    for c in $clusters; do [ -n "$c" ] && ENABLE_TARGETS+=("$tmpl@${c}.timer"); done
  fi
done
[ "${#ENABLE_TARGETS[@]}" -gt 0 ] && ok "derived ${#ENABLE_TARGETS[@]} enable --now targets from install.sh" \
                                  || fail "derived ZERO enable --now targets from install.sh"

ENV_FILES=(/etc/a11oy-uptime.env /etc/szl-alert-relay.env /etc/vault-keystore-offbox.env)

# ---- back everything up + arm the restore trap ------------------------------
BACKUP="$(mktemp -d)"; WORK="$(mktemp -d)"
mkdir -p "$BACKUP/sbin" "$BACKUP/units" "$BACKUP/env"
declare -A ENV_EXISTED
for e in "${ENV_FILES[@]}"; do
  if [ -e "$e" ]; then ENV_EXISTED["$e"]=1; cp -p "$e" "$BACKUP/env/$(basename "$e")"; else ENV_EXISTED["$e"]=0; fi
done
for entry in "${SBIN_ENTRIES[@]}"; do d="${entry#*|}"; [ -e "$d" ] && cp -p "$d" "$BACKUP/sbin/$(basename "$d")"; done
for entry in "${UNIT_ENTRIES[@]}"; do d="${entry#*|}"; [ -e "$d" ] && cp -p "$d" "$BACKUP/units/$(basename "$d")"; done

restore_from_backup() {
  local entry d b
  for entry in "${SBIN_ENTRIES[@]}";  do d="${entry#*|}"; b="$BACKUP/sbin/$(basename "$d")";
    [ -e "$d" ] || { [ -e "$b" ] && install -m "${entry%%|*}" "$b" "$d"; }; done
  for entry in "${UNIT_ENTRIES[@]}"; do d="${entry#*|}"; b="$BACKUP/units/$(basename "$d")";
    [ -e "$d" ] || { [ -e "$b" ] && install -m "${entry%%|*}" "$b" "$d"; }; done
  for e in "${ENV_FILES[@]}"; do b="$BACKUP/env/$(basename "$e")";
    [ "${ENV_EXISTED[$e]}" = "1" ] && [ -e "$b" ] && cp -p "$b" "$e"; done
  systemctl daemon-reload 2>/dev/null || true
}
cleanup() { restore_from_backup; rm -rf "$BACKUP" "$WORK"; }
trap cleanup EXIT

# ---- pin NOTIFY_CMD to a capture stub so nothing reaches the real channel ----
CAPTURE="$WORK/notify.capture"; : > "$CAPTURE"
CAPTURE_STUB="$WORK/capture-notify"
cat > "$CAPTURE_STUB" <<EOF
#!/usr/bin/env bash
cat >> "$CAPTURE"
EOF
chmod +x "$CAPTURE_STUB"
export NOTIFY_CMD="$CAPTURE_STUB" ALERT_PREFIX="[TEST-ignore] "

run_install() { ( cd "$BOX" && bash "$INSTALL_SH" ) >"$WORK/install.out" 2>&1; }

# ============================================================================
echo "== Phase 1: wipe managed sbin+units, re-run install.sh, assert full restore =="
for entry in "${SBIN_ENTRIES[@]}"; do rm -f "${entry#*|}"; done
for entry in "${UNIT_ENTRIES[@]}"; do rm -f "${entry#*|}"; done
wiped=0
for entry in "${SBIN_ENTRIES[@]}"; do [ -e "${entry#*|}" ] || wiped=$((wiped+1)); done
[ "$wiped" -gt 0 ] && ok "wiped $wiped managed sbin file(s) before reinstall" \
                   || fail "wipe step removed nothing (managed paths wrong?)"

if run_install; then ok "install.sh re-run exited 0"; else fail "install.sh re-run FAILED (see install.out below)"; sed 's/^/    | /' "$WORK/install.out" >&2; fi
systemctl daemon-reload 2>/dev/null || true

assert_restored() { # array-name expected-mode label
  local -n entries="$1"; local label="$3"
  local entry m d am want
  for entry in "${entries[@]}"; do
    m="${entry%%|*}"; d="${entry#*|}"; want="${m#0}"
    if [ -e "$d" ]; then
      am="$(mode_of "$d")"
      if [ "$am" = "$want" ] || [ "$am" = "$m" ]; then ok "$label restored: $(basename "$d") (mode $am)";
      else fail "$label $(basename "$d") restored but mode $am != expected $m"; fi
    else
      fail "$label NOT restored: $d"
    fi
  done
}
assert_restored SBIN_ENTRIES 0755 "sbin"
assert_restored UNIT_ENTRIES 0644 "unit"

for u in "${ENABLE_TARGETS[@]}"; do
  en="$(systemctl is-enabled "$u" 2>/dev/null)"
  ac="$(systemctl is-active  "$u" 2>/dev/null)"
  [ "$en" = "enabled" ] && ok "$u is-enabled=enabled" || fail "$u is-enabled=$en (expected enabled)"
  [ "$ac" = "active"  ] && ok "$u is-active=active"   || fail "$u is-active=$ac (expected active)"
done

# ============================================================================
echo "== Phase 2: env stubs unchanged on re-run (an existing channel is never clobbered) =="
declare -A MD5_BEFORE
for e in "${ENV_FILES[@]}"; do [ -e "$e" ] && MD5_BEFORE["$e"]="$(md5_of "$e")"; done
if run_install; then ok "install.sh second re-run exited 0 (idempotent)"; else fail "install.sh second re-run FAILED"; fi
for e in "${ENV_FILES[@]}"; do
  [ -n "${MD5_BEFORE[$e]:-}" ] || continue
  after="$(md5_of "$e")"
  [ "$after" = "${MD5_BEFORE[$e]}" ] && ok "$(basename "$e") md5 unchanged on re-run" \
                                     || fail "$(basename "$e") CHANGED on re-run (clobbered)"
done

# ============================================================================
echo "== Phase 3: env stub seeded ONLY when absent =="
for e in "${ENV_FILES[@]}"; do
  base="$(basename "$e")"; aside="$WORK/aside.$base"; had=0
  [ -e "$e" ] && { had=1; mv "$e" "$aside"; }
  run_install >/dev/null 2>&1 || true
  if [ -e "$e" ]; then
    perm="$(mode_of "$e")"
    [ "$perm" = "600" ] && ok "seeded $base mode 600 when absent" || fail "seeded $base but mode $perm != 600"
    case "$base" in
      a11oy-uptime.env)          grep -q 'log-only'        "$e" && ok "$base stub = commented log-only template"      || fail "$base seeded but missing expected template marker" ;;
      szl-alert-relay.env)       grep -q '^RELAY_TOKEN='   "$e" && ok "$base stub seeded a RELAY_TOKEN"               || fail "$base seeded but missing RELAY_TOKEN" ;;
      vault-keystore-offbox.env) grep -q 'log-only no-op'  "$e" && ok "$base stub = commented no-op template"         || fail "$base seeded but missing expected template marker" ;;
    esac
  else
    fail "$base was NOT seeded when absent"
  fi
  [ "$had" = 1 ] && { mv -f "$aside" "$e"; ok "restored real $base after seed test"; }
done

# ============================================================================
echo "== Phase 4: every env file left byte-identical to how the test found it =="
for e in "${ENV_FILES[@]}"; do
  if [ "${ENV_EXISTED[$e]}" = "1" ]; then
    [ "$(md5_of "$e")" = "$(md5_of "$BACKUP/env/$(basename "$e")")" ] \
      && ok "$(basename "$e") matches original" || fail "$(basename "$e") NOT restored to original"
  fi
done

# ---- summary ----------------------------------------------------------------
echo
[ -s "$CAPTURE" ] && echo "note: install.sh's watcher sweep produced $(wc -l <"$CAPTURE") line(s) — captured locally, real channel untouched."
echo "restore-fleet: $checks checks, $fails failure(s)."
if [ "$fails" -eq 0 ]; then echo "RESULT: PASS"; exit 0; else echo "RESULT: FAIL"; exit 1; fi
