# cosign signing key (CI / demo)

Fixes UDS deploy stall **Gap 2** — the cosign signing key was flagged `staged`
/ not provisioned. This directory wires the deploy/CI image-signing path to a
**properly generated** cosign key-pair (ECDSA P-256, the same scheme the live
`szlholdings-cosign` signer uses for receipts).

## What lives here

| File | Committed? | Notes |
| --- | --- | --- |
| `cosign.pub` | **YES** | The public verification key. ECDSA P-256. Safe to commit. |
| `cosign.key` | **NEVER** | Encrypted private key. Lives ONLY as a GitHub Actions secret. `.gitignore` blocks it. |

The private key for `cosign.pub` here was generated with
`cosign generate-key-pair` and verified to sign+verify a blob (`Verified OK`).
**It is intentionally not in the repo.** Image signing in CI reads it from the
`COSIGN_PRIVATE_KEY` repo secret (see `.github/workflows/receipts-server-image.yml`).

## Founder step — ONE command to enable key-pair image signing

The image **publishes and is signed today** without this step — the
`receipts-server-image.yml` workflow falls back to **keyless OIDC** signing
(no secret needed), so `cosign verify --certificate-identity-regexp=...` works
out of the box.

To switch to the committed `cosign.pub` key-pair instead of keyless, the founder
runs once (locally, with the `cosign` CLI authenticated to GitHub via `gh`):

```bash
# Generate the key-pair and push the private half + password as repo secrets.
# (Choose any strong COSIGN_PASSWORD; it protects the encrypted private key.)
export COSIGN_PASSWORD='<strong-password>'
cosign generate-key-pair                       # writes cosign.key + cosign.pub
gh secret set COSIGN_PRIVATE_KEY  --repo szl-holdings/szl-uds-deployment < cosign.key
gh secret set COSIGN_PASSWORD     --repo szl-holdings/szl-uds-deployment --body "$COSIGN_PASSWORD"
# Commit the new cosign.pub here (replacing this one) so verifiers use the matching key:
cp cosign.pub cosign/cosign.pub && git add cosign/cosign.pub && git commit -m 'chore(cosign): rotate CI signing pubkey'
```

After that, every `receipts-server-image.yml` run signs the pushed image with the
key-pair and self-verifies with `cosign verify --key cosign/cosign.pub`.

## Core demo signing (no founder step)

The **signed-receipt-chain + tamper-evident proof** core demo does NOT depend on
this cosign key. It uses the receipts server's own in-image **Ed25519** signer
(`services/szl-receipts-server/server.py`), so it is demoable today. See
`../warhacker-demo` `scripts/core_demo.sh`.

## Never commit a private key

`.gitignore` in this directory blocks `cosign.key` / `*.key` / `*.pem`. If you
ever see a private key staged, abort the commit.
