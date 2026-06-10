Intentional PASS fixture: the szl-fleet-overlay zarf package verify-blob with an
EXACT --certificate-identity (Task #680). The guard MUST allow this.

```bash
cosign verify-blob \
  --certificate-identity "https://github.com/szl-holdings/szl-fleet-overlay/.github/workflows/zarf-package-sign.yml@refs/heads/main" \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --bundle zarf-package-szl-fleet-overlay-amd64-0.1.0.tar.zst.sigstore.json \
  zarf-package-szl-fleet-overlay-amd64-0.1.0.tar.zst
```
