// Copyright 2026 SZL Holdings
// SPDX-License-Identifier: Apache-2.0
//
// SZL Governance — Pepr module entry point.
//
// NOTICE: Uses the `pepr` npm package (Apache-2.0,
// https://github.com/defenseunicorns/pepr) and `kubernetes-fluent-client`
// (Apache-2.0). The capability code below is original SZL Holdings work
// (Apache-2.0). The structural pattern is inspired by Austin Abro's
// pepr-grafana-capability (no license asserted on that repo); NO code is copied
// from it — only the public Pepr API is followed.
//
// This module registers two admission capabilities that gate a11oy and killinchu
// workloads on the presence of a well-formed SZL YUYAY-gate DSSE receipt.

import { PeprModule } from "pepr";
// eslint-disable-next-line @typescript-eslint/no-var-requires
import cfg from "./package.json";
import { A11oyReceiptGate } from "./capabilities/a11oy-receipt-gate";
import { KillinchuReceiptGate } from "./capabilities/killinchu-receipt-gate";

/**
 * REAL (shipping): admission webhooks that validate that every non-system Pod
 * created/updated in the a11oy and killinchu namespaces carries a well-formed
 * `szl.io/receipt` annotation (the YUYAY-gate receipt). Missing/malformed ->
 * admission denied.
 *
 * ROADMAP (clearly labeled in each capability): full DSSE cryptographic
 * verification in-cluster against szl-receipts.
 */
new PeprModule(cfg, [A11oyReceiptGate, KillinchuReceiptGate]);
