// Copyright 2026 SZL Holdings
// SPDX-License-Identifier: Apache-2.0
//
// NOTICE: Uses pepr (Apache-2.0). Pattern inspired by AustinAbro321/
// pepr-grafana-capability (no license asserted; code NOT copied — only the
// public Pepr API pattern is followed). Original SZL Holdings work.

import { Capability, a, Log } from "pepr";
import {
  validateReceiptAnnotation,
  isSystemManaged,
} from "./szl-governance-common";

const RECEIPT_ANNOTATION = "szl.io/receipt";

/**
 * A11oyReceiptGate — Pepr Validating + Mutating webhook for the a11oy namespace.
 *
 * REAL (shipping): validates that every non-system Pod created/updated in the
 * a11oy namespace carries a well-formed SZL YUYAY-gate receipt annotation.
 * Missing/malformed -> admission DENIED with a structured, actionable error.
 *
 * ROADMAP P1: full DSSE cryptographic verification via szl-receipts.
 * ROADMAP P2: conjunctive Lambda-gate score threshold (P1-P6 must all pass).
 * ROADMAP P3: append a row to the a11oy ledger on successful admission.
 */
export const A11oyReceiptGate = new Capability({
  name: "a11oy-receipt-gate",
  description:
    "Validates the SZL YUYAY-gate receipt annotation on all Pods in the a11oy " +
    "namespace. Denies admission if the receipt is absent or malformed. " +
    "REAL: format check. ROADMAP: full DSSE verify + ledger append.",
  namespaces: ["a11oy"],
});

const { When } = A11oyReceiptGate;

// ── Validate on Pod create/update ──────────────────────────────────────────
When(a.Pod)
  .IsCreatedOrUpdated()
  .InNamespace("a11oy")
  .Validate((request) => {
    const pod = request.Raw;
    const podName = pod.metadata?.name || "<pending>";
    const annotations = pod.metadata?.annotations;
    const labels = pod.metadata?.labels;

    Log.info(`[a11oy-receipt-gate] Validating Pod: ${podName}`);

    // Skip UDS Core / Zarf / Pepr system-managed pods.
    if (isSystemManaged(labels)) {
      Log.info(
        `[a11oy-receipt-gate] Skipping system pod ${podName} ` +
          `(managed-by=${labels?.["app.kubernetes.io/managed-by"]})`,
      );
      return request.Approve();
    }

    const result = validateReceiptAnnotation(annotations, RECEIPT_ANNOTATION);

    if (!result.valid) {
      Log.warn(
        `[a11oy-receipt-gate] DENIED: Pod ${podName} — ${result.reason}`,
      );
      return request.Deny(
        `SZL Governance Gate (a11oy): ${result.reason}. ` +
          `Annotate the Pod with ${RECEIPT_ANNOTATION}=v1:<sha256>:<dsse-sig> ` +
          `before deployment. See ` +
          `https://github.com/szl-holdings/szl-uds-deployment/blob/main/capabilities/szl-governance/README.md`,
      );
    }

    Log.info(`[a11oy-receipt-gate] APPROVED: Pod ${podName} — receipt valid.`);
    return request.Approve();
  });

// ── Mutate on Pod create/update — inject governance audit labels ───────────
// Adds labels so Prometheus/Grafana + Loki can track gate outcomes.
When(a.Pod)
  .IsCreatedOrUpdated()
  .InNamespace("a11oy")
  .Mutate((request) => {
    const annotations = request.Raw.metadata?.annotations || {};
    const hasReceipt = !!annotations[RECEIPT_ANNOTATION];

    request.SetLabel("szl.io/governance-gate", "a11oy-receipt-gate");
    request.SetLabel("szl.io/receipt-present", hasReceipt ? "true" : "false");
    request.SetAnnotation(
      "szl.io/governance-checked-at",
      new Date().toISOString(),
    );
  });
