#!/usr/bin/env sh
# Copyright 2026 SZL Holdings
# SPDX-License-Identifier: Apache-2.0
#
# Negative-fixture self-test for check-no-committed-subcharts.sh.
#
# The guard is a one-line `git ls-files 'charts/*/charts/*'` check, but a future
# edit (a wrong pathspec, a dropped `exit 1`) could neuter it so it passes
# vacuously — green while guarding nothing. This builds throwaway git repos and
# asserts the guard FAILS on a committed snapshot and PASSES on a clean tree, so
# a regressed checker turns CI red here. Mirrors scripts/chart-guard-checks.test.py.
set -eu

here="$(cd "$(dirname "$0")" && pwd)"
script="$here/check-no-committed-subcharts.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mkrepo() {
  d="$1"
  mkdir -p "$d"
  git -C "$d" init -q
  git -C "$d" config user.email "selftest@szl.local"
  git -C "$d" config user.name "selftest"
}

fail() { echo "SELF-TEST FAIL: $1"; exit 1; }

# ── Fixture A: clean tree with only a legit leaf chart -> guard must PASS ──────
# charts/szl-receipts/Chart.yaml has no second `charts/` segment, so it must NOT
# match charts/*/charts/* (proves the guard has no false positive on real charts).
clean="$tmp/clean"
mkrepo "$clean"
mkdir -p "$clean/charts/szl-receipts/templates"
printf 'apiVersion: v2\nname: szl-receipts\nversion: 0.0.0\n' > "$clean/charts/szl-receipts/Chart.yaml"
printf '{}\n' > "$clean/charts/szl-receipts/templates/cm.yaml"
git -C "$clean" add -A
git -C "$clean" commit -q -m "clean leaf chart"
if sh "$script" "$clean" >/dev/null 2>&1; then
  echo "PASS: clean tree (leaf chart only) accepted"
else
  fail "guard wrongly REJECTED a clean tree that has no committed subchart snapshot"
fi

# ── Fixture B: committed nested umbrella snapshot -> guard must FAIL ───────────
# Simulates a snapshot that bypassed .gitignore (git add -f) at a deeply nested
# path, proving the pathspec's `*` spans `/`.
dirty="$tmp/dirty"
mkrepo "$dirty"
mkdir -p "$dirty/charts/szl-full-stack/charts/szl-receipts/templates"
printf 'apiVersion: v2\nname: szl-full-stack\nversion: 0.0.0\n' > "$dirty/charts/szl-full-stack/Chart.yaml"
printf 'apiVersion: v2\nname: szl-receipts\nversion: 0.0.0\n' > "$dirty/charts/szl-full-stack/charts/szl-receipts/Chart.yaml"
printf '{}\n' > "$dirty/charts/szl-full-stack/charts/szl-receipts/templates/cm.yaml"
git -C "$dirty" add -A -f
git -C "$dirty" commit -q -m "umbrella with committed subchart snapshot"
if sh "$script" "$dirty" >/dev/null 2>&1; then
  fail "committed subchart snapshot slipped past the guard (guard did not exit non-zero)"
else
  echo "PASS: committed subchart snapshot correctly rejected"
fi

echo "All no-committed-subcharts self-tests passed."
