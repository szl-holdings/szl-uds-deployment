# Copyright 2026 SZL Holdings
# SPDX-License-Identifier: Apache-2.0
#
# box-fallback-superset-checks.sh — assert the STATIC emergency fallback watch
# lists (FALLBACK_SBIN / FALLBACK_UNITS) in
# box-scripts/sbin/box-scripts-drift-check remain a SUPERSET of every sbin
# script / systemd unit box-scripts/install.sh installs (minus the own-installer
# allowlist, e.g. szl-box-sync*).
#
# WHY THIS EXISTS
# box-scripts-drift-check DERIVES its watch set from install.sh at runtime, but
# falls back to the STATIC FALLBACK_SBIN / FALLBACK_UNITS lists when install.sh
# is missing / unreadable so it never silently watches NOTHING in that degraded
# mode. That fallback only protects every self-heal helper if it actually lists
# them all. Nothing stops a future change from adding a new self-heal script to
# install.sh while forgetting the fallback, silently re-opening the exact gap
# this list was hardened to close (a new helper unwatched precisely when
# install.sh cannot be read). This is the PR-time gate that catches that: it
# FAILS LOUDLY with the missing name(s) if the fallback falls behind install.sh.
#
# Pure grep/awk text check — no cluster, no root. The install.sh parser is kept
# in lockstep with derive_install_set() in box-scripts-drift-check (and with
# scripts/box-helper-install-coverage-checks.sh) so "installed" means exactly the
# same thing everywhere.
#
# Usage:
#   box-fallback-superset-checks.sh [root]   (root default: current dir)
# Exit 0 when both fallback lists cover install.sh; non-zero (with ::error
# annotations) on a gap.
#
# The allowlist is overridable via BOX_FALLBACK_ALLOWLIST (space-separated
# basenames) FOR THE SELF-TEST ONLY; production runs use the default below.

set -uo pipefail

# Literal newline, used as the delimiter in the pure-shell exact-membership
# substring test below (avoids a SIGPIPE-racy `printf | grep -q` pipeline).
NL='
'

# Own-installer files that ship OUTSIDE install.sh (so they are expected neither
# in install.sh's derived set nor in the static fallback). Kept identical to the
# box-helper install-coverage gate's allowlist (szl-box-sync* family, shipped by
# box-scripts/install-repo-sync.sh).
DEFAULT_ALLOWLIST="szl-box-sync szl-box-sync-pull.service szl-box-sync-pull.timer"

# err FILE MESSAGE — emit a GitHub Actions error annotation.
err() { echo "::error file=$1::$2"; }

# derive_installed_set INSTALL_SH KIND -> newline-separated installed basenames
# from the `install ... "$here/<KIND>/NAME" DEST` lines, classified by the
# install SOURCE prefix "$here/<kind>/". Lockstep with derive_install_set() in
# box-scripts-drift-check and box-helper-install-coverage-checks.sh.
derive_installed_set() {
  local install_sh="$1" kind="$2"
  [ -r "$install_sh" ] || return 0
  grep -F "\"\$here/$kind/" "$install_sh" 2>/dev/null \
    | grep -E '(^|[[:space:]])install([[:space:]]|$)' \
    | grep -oE "\"\\\$here/$kind/[^\"]+\"" \
    | sed -E 's#.*/##; s#"$##' \
    | awk 'NF && !seen[$0]++'
}

# extract_fallback DRIFT_CHECK VAR -> newline-separated basenames pulled from the
# multi-line `VAR="a b \<newline> c d"` assignment (double-quoted, backslash
# line-continued) in the drift-check script. De-duplicated, order preserved.
extract_fallback() {
  local file="$1" var="$2"
  [ -r "$file" ] || return 0
  awk -v v="$var" '
    index($0, v "=") == 1 { grab = 1 }
    grab {
      line = $0
      sub(/\\[[:space:]]*$/, "", line)   # drop trailing line-continuation backslash
      printf "%s ", line
      if ($0 !~ /\\[[:space:]]*$/) { exit }  # last line of the assignment
    }
  ' "$file" \
    | sed -E "s/^$var=\"//; s/\"[[:space:]]*$//" \
    | tr '[:space:]' '\n' \
    | awk 'NF && !seen[$0]++'
}

# check_superset [root] — the gate. 0 if both fallback lists cover install.sh
# (minus the allowlist), else 1.
check_superset() {
  local root="${1:-.}"
  local box="$root/box-scripts"
  local install_sh="$box/install.sh"
  local drift="$box/sbin/box-scripts-drift-check"
  local allowlist="${BOX_FALLBACK_ALLOWLIST-$DEFAULT_ALLOWLIST}"

  test -f "$install_sh" || { err "$install_sh" "missing box-scripts/install.sh"; return 1; }
  test -f "$drift" || { err "$drift" "missing box-scripts/sbin/box-scripts-drift-check"; return 1; }

  local rc=0 kind var installed fallback name
  for kind in sbin systemd; do
    case "$kind" in
      sbin)    var="FALLBACK_SBIN" ;;
      systemd) var="FALLBACK_UNITS" ;;
    esac
    installed="$(derive_installed_set "$install_sh" "$kind")"
    fallback="$(extract_fallback "$drift" "$var")"

    if [ -z "$fallback" ]; then
      err "$drift" "$var is empty or could not be parsed in box-scripts/sbin/box-scripts-drift-check — the static emergency fallback would watch NOTHING of kind '$kind' when install.sh is unreadable."
      rc=1
      continue
    fi

    while IFS= read -r name; do
      [ -n "$name" ] || continue
      case " $allowlist " in
        *" $name "*) continue ;;
      esac
      # Exact-membership test, SIGPIPE-free. (A `printf | grep -q` pipeline
      # races under `set -o pipefail`: grep -q closes the pipe on first match,
      # printf takes SIGPIPE, pipefail propagates the non-zero, and the name is
      # spuriously reported missing — an intermittent false RED. A pure-shell
      # newline-bounded substring check is deterministic.)
      if ! case "$NL$fallback$NL" in *"$NL$name$NL"*) true ;; *) false ;; esac; then
        err "$drift" "install.sh installs box-scripts/$kind/$name but it is MISSING from $var. Add '$name' to $var in box-scripts/sbin/box-scripts-drift-check so the static emergency fallback still watches it when install.sh is unreadable (or, if it ships via its own installer, add it to DEFAULT_ALLOWLIST in scripts/box-fallback-superset-checks.sh)."
        rc=1
      fi
    done <<EOF
$installed
EOF
  done

  if [ "$rc" -eq 0 ]; then
    echo "OK: FALLBACK_SBIN and FALLBACK_UNITS are supersets of every install.sh-installed sbin script / systemd unit (minus the own-installer allowlist)."
  fi
  return "$rc"
}

# Run only when executed directly; sourcing (the self-test) just loads functions.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  check_superset "${1:-.}"
fi
