# Copyright 2026 SZL Holdings
# SPDX-License-Identifier: Apache-2.0
#
# OCI KMS auto-unseal seal stanza for the persistent szl-receipts Vault
# (Task #625). This moves the box Vault off the on-box Shamir unseal key so the
# unseal secret no longer sits next to the sealed data in /root/vault-init.
#
# WHY OCI KMS
#   * It is the ONE genuinely-free, real cloud KMS: Oracle Cloud "Always Free"
#     includes the OCI Vault/KMS service (Virtual Vault, 20 key versions,
#     $0/key, $0 API calls, no time limit).
#   * HashiCorp Vault COMMUNITY (OSS) edition supports `seal "ocikms"`
#     auto-unseal on ALL versions. Only seal-WRAPPING of individual secrets
#     requires Enterprise — we do NOT need that; we only need auto-unseal.
#   * Verified against Vault 1.18.5 (the version running on this box).
#
# HOW TO USE
#   1. Stephen creates a free OCI account, then in the OCI console:
#        - Identity & Security -> Vault -> create a Vault (default virtual vault
#          is free) -> create a Master Encryption Key (AES, 256-bit, software or
#          HSM-protected). Copy the KEY OCID.
#        - From the key's vault, copy the CRYPTO (data-plane) endpoint and the
#          MANAGEMENT (control-plane) endpoint.
#        - Identity -> Users -> your user -> API Keys -> Add API Key (let OCI
#          generate the keypair, or upload one). Download the PRIVATE KEY (.pem)
#          and note the FINGERPRINT, your USER OCID, TENANCY OCID, and REGION.
#   2. Fill the four seal values below (key_id + two endpoints + auth flag) into
#      the live vault.hcl ConfigMap (k8s/vault/vault-persistent.yaml), and mount
#      the OCI API-key credential into the pod as a Secret (see the migration
#      script scripts/vault-seal-migrate-ocikms.sh and runbook §6a).
#   3. Run scripts/vault-seal-migrate-ocikms.sh to migrate shamir -> ocikms with
#      NO loss of the Transit signing key (it backs up the keystore first and
#      verifies the receipts pubkey is unchanged), then remove the on-box
#      init.json.
#
# The actual key_id / endpoints below are PLACEHOLDERS copied from the official
# HashiCorp docs — replace them with the values from Stephen's OCI account.

seal "ocikms" {
  key_id              = "ocid1.key.oc1.<region>.<vault-prefix>.<key-suffix>"
  crypto_endpoint     = "https://<vault-prefix>-crypto.kms.<region>.oraclecloud.com"
  management_endpoint = "https://<vault-prefix>-management.kms.<region>.oraclecloud.com"
  auth_type_api_key   = "true"
}

# API-key authentication is supplied to the Vault process via the standard OCI
# SDK config file. The migration script mounts a Secret containing:
#   /home/vault/.oci/config        (tenancy/user OCID, fingerprint, region,
#                                    key_file=/home/vault/.oci/oci_api_key.pem)
#   /home/vault/.oci/oci_api_key.pem  (the downloaded API private key, 0600)
# and sets  env OCI_CLI_CONFIG_FILE / OCI_CONFIG_FILE = /home/vault/.oci/config
# so Vault's OCI client picks it up. (auth_type_api_key=true selects API-key
# auth over instance-principal, which is not available off-OCI.)
