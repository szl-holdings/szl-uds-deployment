# Receipts image verify (loose — must fail)

```bash
cosign verify ghcr.io/szl-holdings/szl-receipts-server:uds-v0.4.0 \
  --certificate-identity-regexp 'receipts-server-image.yml' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
```
