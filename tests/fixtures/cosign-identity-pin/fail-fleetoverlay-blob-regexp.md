Intentional FAIL fixture: the szl-fleet-overlay zarf package verify-blob written
with the loose --certificate-identity-regexp form (Task #680). The guard MUST
flag this.

```bash
cosign verify-blob \
  --certificate-identity-regexp "https://github.com/szl-holdings/szl-fleet-overlay/.github/workflows/.*" \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --bundle zarf-package-szl-fleet-overlay-amd64-0.1.0.tar.zst.sigstore.json \
  zarf-package-szl-fleet-overlay-amd64-0.1.0.tar.zst
```
