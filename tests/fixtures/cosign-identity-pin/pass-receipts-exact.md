```bash
cosign verify ghcr.io/szl-holdings/szl-receipts:0.4.0-upstream \
  --certificate-identity "https://github.com/szl-holdings/szl-uds-deployment/.github/workflows/zarf-package-sign.yml@refs/heads/main" \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com

cosign verify ghcr.io/szl-holdings/szl-receipts-server:uds-v0.4.0 \
  --certificate-identity "https://github.com/szl-holdings/szl-uds-deployment/.github/workflows/receipts-server-image.yml@refs/tags/receipts-server-v0.4.0" \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
```
