Intentional PASS fixture: the templated per-organ SLSA attestation loop. `${organ}`
spans 5 separate repos (3 of which — amaru/sentra/rosie — have since been deleted),
each image signed by its OWN repo's workflow, so there is no single exact
--certificate-identity to pin. The per-repo prefix regexp is intentional and the
guard MUST leave it alone (out of scope).

```bash
for organ in a11oy sentra amaru rosie killinchu; do
  cosign verify-attestation --type slsaprovenance \
    "ghcr.io/szl-holdings/${organ}:uds-v0.2.0" \
    --certificate-identity-regexp "https://github.com/szl-holdings/${organ}/" \
    --certificate-oidc-issuer "https://token.actions.githubusercontent.com"
done
```
