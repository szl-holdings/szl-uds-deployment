```bash
cosign verify ghcr.io/szl-holdings/killinchu:uds-v0.2.0 \
  --certificate-identity-regexp 'https://github.com/szl-holdings/killinchu/.*' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
```
