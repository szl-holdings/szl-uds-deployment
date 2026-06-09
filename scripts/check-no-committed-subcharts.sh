#!/usr/bin/env sh
# Copyright 2026 SZL Holdings
# SPDX-License-Identifier: Apache-2.0
#
# check-no-committed-subcharts.sh — fail if a generated umbrella subchart
# snapshot is tracked in git.
#
# .github/scripts/stub_missing_deps.py writes CI-ephemeral vendored/stub
# subcharts into charts/<umbrella>/charts/ at render time, and .gitignore
# (charts/*/charts/) keeps them out of git. But .gitignore only blocks an
# accidental `git add` — a `git add -f`, or a branch whose tree was committed
# before the ignore rule existed, would still carry a stale snapshot. Once
# committed, Helm treats that snapshot as the source of truth and the umbrella
# silently drifts. This is the hard guard .gitignore can't be.
#
# Usage: check-no-committed-subcharts.sh [repo-dir]   (default: .)
# Exit 0 when nothing matching charts/*/charts/* is tracked, 1 otherwise.
set -eu

dir="${1:-.}"

# `git ls-files` only lists TRACKED files, so render-time (gitignored) snapshots
# never appear here — it sees exactly what is committed. The pathspec's `*`
# matches `/` in git, so this also catches deeply nested snapshot files such as
# charts/<umbrella>/charts/<dep>/templates/foo.yaml.
tracked="$(git -C "$dir" ls-files 'charts/*/charts/*')"

if [ -n "$tracked" ]; then
  echo "::error::A generated umbrella subchart snapshot is tracked in git. These are written by .github/scripts/stub_missing_deps.py at render time and MUST NOT be committed — Helm would then treat the snapshot as the source of truth and the umbrella would drift / go stale. Remove it with 'git rm -r --cached <path>' and rely on the .gitignore rule 'charts/*/charts/'. Offending paths:"
  echo "$tracked" | while IFS= read -r p; do
    echo "::error file=${p}::committed generated subchart snapshot (matched 'charts/*/charts/*')"
  done
  exit 1
fi

echo "OK: no generated umbrella subchart snapshot is tracked under charts/*/charts/*"
