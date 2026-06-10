Intentional PASS fixture: killinchu organ image verified with an EXACT
--certificate-identity (Task #680). The guard MUST allow this.

```bash
cosign verify ghcr.io/szl-holdings/killinchu:uds-v0.2.0 \
  --certificate-identity 'https://github.com/szl-holdings/killinchu/.github/workflows/ghcr-build-push.yml@refs/heads/main' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
```
