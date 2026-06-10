Intentional PASS fixture: an a11oy canonical UDS bundle verified with an EXACT
--certificate-identity (Task #680). The guard MUST allow this.

```bash
cosign verify ghcr.io/szl-holdings/a11oy-bundle:0.5.0 \
  --certificate-identity='https://github.com/szl-holdings/uds-bundles/.github/workflows/uds-canonical-bundles-publish.yml@refs/heads/main' \
  --certificate-oidc-issuer="https://token.actions.githubusercontent.com"
```
