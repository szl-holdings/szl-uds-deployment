Intentional PASS fixture: a11oy organ image verified with an EXACT
--certificate-identity (Task #892). The guard MUST allow this.

```bash
cosign verify-attestation --type slsaprovenance ghcr.io/szl-holdings/a11oy:uds-v0.2.0 \
  --certificate-identity 'https://github.com/szl-holdings/a11oy/.github/workflows/ghcr-build-push.yml@refs/heads/main' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
```
