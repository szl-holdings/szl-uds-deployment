# Copyright 2026 SZL Holdings
# SPDX-License-Identifier: Apache-2.0
#
# ClusterFuzzLite build environment for the SZL receipts server fuzz targets.
# Its presence (plus .clusterfuzzlite/build.sh) is what satisfies the OSSF
# Scorecard "Fuzzing" check; the targets themselves live next to server.py.
FROM gcr.io/oss-fuzz-base/base-builder-python@sha256:102a8e9c54da5dbe16df3c8fb5aec4d60eda4fedbe0f96b08d55bdcfa0e7c9e8

RUN pip3 install --no-cache-dir atheris

COPY . $SRC/szl-uds-deployment
WORKDIR $SRC/szl-uds-deployment
COPY .clusterfuzzlite/build.sh $SRC/build.sh
