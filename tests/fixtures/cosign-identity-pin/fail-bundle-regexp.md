Intentional FAIL fixture: an a11oy canonical UDS bundle verified with the loose
--certificate-identity-regexp form (Task #680). The guard MUST flag this.

```bash
cosign verify ghcr.io/szl-holdings/a11oy-bundle:0.5.0 \
  --certificate-identity-regexp='.*szl-holdings/uds-bundles.*' \
  --certificate-oidc-issuer="https://token.actions.githubusercontent.com"
```
