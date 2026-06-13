Intentional FAIL fixture: a11oy organ image verified with the loose
--certificate-identity-regexp form (Task #892). The guard MUST flag this.

```bash
cosign verify-attestation --type slsaprovenance ghcr.io/szl-holdings/a11oy:uds-v0.2.0 \
  --certificate-identity-regexp 'https://github.com/szl-holdings/a11oy/.*' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
```
