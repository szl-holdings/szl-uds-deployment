#!/bin/bash -eu
# Copyright 2026 SZL Holdings
# SPDX-License-Identifier: Apache-2.0
#
# ClusterFuzzLite / OSS-Fuzz build step for the SZL receipts server fuzz targets.
# Runs inside the base-builder-python image (see .clusterfuzzlite/Dockerfile),
# where $SRC is the checkout root and compile_python_fuzzer is on PATH.

# The fuzz targets exercise pure stdlib parsers, but install the runtime deps so
# `import server` resolves exactly as it does in production (the heavy crypto/OTel
# imports are lazy, so this is belt-and-suspenders).
pip3 install --no-cache-dir \
  -r "$SRC/szl-uds-deployment/services/szl-receipts-server/requirements.txt" || true

# fuzz_receipts.py sits next to server.py so `import server` is resolvable at
# PyInstaller analysis time.
compile_python_fuzzer \
  "$SRC/szl-uds-deployment/services/szl-receipts-server/fuzz_receipts.py"
