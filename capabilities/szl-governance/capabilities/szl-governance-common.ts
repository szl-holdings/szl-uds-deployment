// Copyright 2026 SZL Holdings
// SPDX-License-Identifier: Apache-2.0
//
// Shared validators for the SZL governance Pepr capability.
// Original SZL Holdings work. Uses only the `pepr` Apache-2.0 API (Log).

import { Log } from "pepr";

/**
 * SZL YUYAY-gate DSSE Receipt annotation format (REAL — validated here):
 *
 *   szl.io/receipt: "v1:<64-hex-sha256-of-payload>:<base64url-dsse-signature>"
 *
 *   - "v1"                 : receipt format version (RECEIPT_FORMAT_VERSION)
 *   - <sha256>             : lower-case hex digest of the canonicalised
 *                            governed-action payload (the YUYAY gate output)
 *   - <base64url-dsse-sig> : the DSSE envelope signature, base64url, >= 88 chars
 *                            (Ed25519 sig is 64 bytes -> 86 b64url chars; we
 *                            require >= 88 to allow padding/longer schemes)
 *
 * REAL  : presence + strict-format regex check (no network call). This blocks
 *         unsigned / malformed workloads from running in a governed namespace.
 * ROADMAP (P1): full DSSE cryptographic verification of the signature against
 *         the szl-receipts service public key (requires an in-cluster HTTP call
 *         from the Pepr controller + a NetworkPolicy egress allow). The hook is
 *         left in place below, commented and clearly marked.
 */

// REAL: strict format regex. v1:<sha256hex>:<base64url sig, >=88 chars>
export const RECEIPT_REGEX = /^v1:[0-9a-f]{64}:[A-Za-z0-9\-_=]{88,}$/;

export interface ReceiptValidationResult {
  valid: boolean;
  reason?: string;
}

/**
 * Validate the SZL YUYAY-gate receipt annotation (REAL — format only).
 * Full DSSE cryptographic verification is ROADMAP (see note above).
 */
export function validateReceiptAnnotation(
  annotations: Record<string, string> | undefined,
  annotationKey: string,
): ReceiptValidationResult {
  if (!annotations) {
    return {
      valid: false,
      reason: `No annotations present; missing required ${annotationKey}`,
    };
  }

  const receipt = annotations[annotationKey];
  if (!receipt) {
    return {
      valid: false,
      reason:
        `Missing required annotation: ${annotationKey}. ` +
        `All a11oy/killinchu workloads must carry a valid SZL YUYAY-gate receipt.`,
    };
  }

  if (!RECEIPT_REGEX.test(receipt)) {
    return {
      valid: false,
      reason:
        `Malformed receipt annotation ${annotationKey}: ` +
        `expected format v1:<sha256hex>:<base64url-sig>. ` +
        `Got: "${receipt.substring(0, 40)}..."`,
    };
  }

  Log.info(
    `[szl-governance] Receipt annotation present and well-formed: ${annotationKey}`,
  );

  // ── ROADMAP P1: full DSSE cryptographic verify against szl-receipts ────────
  // const verified = await verifySzlDsseReceipt(receipt, RECEIPTS_SERVICE_URL);
  // if (!verified) {
  //   return { valid: false, reason: "DSSE signature verification failed" };
  // }

  return { valid: true };
}

/**
 * Parse a well-formed receipt into its three fields. Returns undefined if the
 * receipt does not match the REAL format. Useful for ROADMAP verification and
 * for emitting structured audit logs.
 */
export interface ParsedReceipt {
  version: string;
  payloadSha256: string;
  dsseSignature: string;
}

export function parseReceipt(receipt: string): ParsedReceipt | undefined {
  if (!RECEIPT_REGEX.test(receipt)) {
    return undefined;
  }
  const [version, payloadSha256, dsseSignature] = receipt.split(":");
  return { version, payloadSha256, dsseSignature };
}

/**
 * Check whether a namespace is subject to SZL governance. Governance applies
 * when the namespace carries the label szl.io/governance=enabled (the UDS
 * Package CR / namespace manifest sets this).
 */
export function isGovernedNamespace(
  labels: Record<string, string> | undefined,
): boolean {
  return labels?.["szl.io/governance"] === "enabled";
}

/**
 * UDS-Core / Zarf / Pepr system workloads are admitted without a receipt —
 * they are not governed application workloads. Centralised here so both gates
 * use identical skip logic.
 */
export function isSystemManaged(
  labels: Record<string, string> | undefined,
): boolean {
  const managedBy = labels?.["app.kubernetes.io/managed-by"];
  return managedBy === "zarf" || managedBy === "pepr";
}
