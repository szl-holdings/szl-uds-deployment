# Copyright 2026 SZL Holdings
# SPDX-License-Identifier: Apache-2.0
#
# box-helper-install-coverage-checks.sh — assert every committed box helper file
# under box-scripts/{sbin,systemd}/ is EITHER wired into box-scripts/install.sh
# via an `install -m "$here/<kind>/NAME" ...` line, OR is on the explicit
# allowlist of files that ship through their OWN installer.
#
# WHY THIS EXISTS
# box-scripts/sbin/box-scripts-drift-check derives its WATCH SET at runtime by
# parsing install.sh (it only watches files install.sh actually installs). So a
# brand-new sbin script / systemd unit committed WITHOUT a matching `install -m`
# line is SILENTLY never installed and SILENTLY never watched for drift — the
# exact gap the runtime watcher closed for installed files but cannot close for
# files nobody wired up. This is the PR-time gate that catches that omission
# before it merges.
#
# It is a pure grep/awk text check — no cluster, no root. The install.sh parser
# below is kept in lockstep with derive_install_set() in
# box-scripts/sbin/box-scripts-drift-check so "wired/covered" means exactly the
# same thing at PR time and at runtime.
#
# Usage:
#   box-helper-install-coverage-checks.sh [root]   (root default: current dir)
# Exit 0 when every file is covered; non-zero (with ::error annotations) on a gap.
#
# The allowlist is overridable via BOX_HELPER_ALLOWLIST (space-separated
# basenames) FOR THE SELF-TEST ONLY; production runs use the default below.

set -uo pipefail

# Files committed under box-scripts/ that are installed by their OWN installer and
# are therefore intentionally absent from install.sh (and intentionally outside
# the install.sh-derived drift watch set):
#   szl-box-sync, szl-box-sync-pull.{service,timer}
#     -> shipped + enabled by box-scripts/install-repo-sync.sh (the repo-sync
#        family runs as its own isolated unit; see install-repo-sync.README.md).
DEFAULT_ALLOWLIST="szl-box-sync szl-box-sync-pull.service szl-box-sync-pull.timer"

# err FILE MESSAGE — emit a GitHub Actions error annotation.
err() { echo "::error file=$1::$2"; }

# derive_installed_set INSTALL_SH KIND -> newline-separated SOURCE basenames from
# the `install ... "$here/<KIND>/NAME" DEST` lines, classified by the install
# SOURCE prefix "$here/<kind>/" so `install -d`, /etc/nginx snippets, and seeded
# env stubs are ignored. Same logic as box-scripts-drift-check's
# derive_install_set, kept in lockstep so the gate and the watcher agree.
derive_installed_set() {
  local install_sh="$1" kind="$2"
  [ -r "$install_sh" ] || return 0
  grep -F "\"\$here/$kind/" "$install_sh" 2>/dev/null \
    | grep -E '(^|[[:space:]])install([[:space:]]|$)' \
    | grep -oE "\"\\\$here/$kind/[^\"]+\"" \
    | sed -E 's#.*/##; s#"$##' \
    | awk 'NF && !seen[$0]++'
}

# check_coverage [root] — the gate. 0 if every file is wired/allowlisted, else 1.
check_coverage() {
  local root="${1:-.}"
  local box="$root/box-scripts"
  local install_sh="$box/install.sh"
  local allowlist="${BOX_HELPER_ALLOWLIST-$DEFAULT_ALLOWLIST}"

  test -d "$box" || { err "$box" "missing box-scripts/ directory"; return 1; }
  test -f "$install_sh" || { err "$install_sh" "missing box-scripts/install.sh"; return 1; }

  local installed_sbin installed_units
  installed_sbin="$(derive_installed_set "$install_sh" sbin)"
  installed_units="$(derive_installed_set "$install_sh" systemd)"

  local rc=0 kind dir installed f base
  for kind in sbin systemd; do
    dir="$box/$kind"
    [ -d "$dir" ] || continue
    case "$kind" in
      sbin)    installed="$installed_sbin" ;;
      systemd) installed="$installed_units" ;;
    esac
    for f in "$dir"/*; do
      [ -f "$f" ] || continue
      base="$(basename "$f")"
      # Covered by an install.sh `install -m "$here/<kind>/<base>" ...` line?
      if printf '%s\n' "$installed" | grep -qxF -- "$base"; then
        continue
      fi
      # On the own-installer allowlist?
      case " $allowlist " in
        *" $base "*) continue ;;
      esac
      err "$f" "box-scripts/$kind/$base is committed but has NO matching 'install -m \"\$here/$kind/$base\" ...' line in box-scripts/install.sh and is not on the own-installer allowlist."
      err "$f" "It would be SILENTLY excluded from box-scripts-drift-check's watch set (that set is derived from install.sh). Add the install line to box-scripts/install.sh, or add '$base' to DEFAULT_ALLOWLIST in scripts/box-helper-install-coverage-checks.sh if it ships via its own installer."
      rc=1
    done
  done

  if [ "$rc" -eq 0 ]; then
    echo "OK: every box-scripts/{sbin,systemd}/ file is wired into install.sh or on the own-installer allowlist."
  fi
  return "$rc"
}

# Run only when executed directly; sourcing (the self-test) just loads functions.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  check_coverage "${1:-.}"
fi
