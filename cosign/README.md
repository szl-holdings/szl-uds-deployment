# cosign signing keys — RETIRED legacy material

> **Canonical signing is KEYLESS (no key file).** Both the receipts **image**
> (`.github/workflows/receipts-server-image.yml`) and the published **package**
> (`.github/workflows/zarf-package-sign.yml`) are signed keyless via GitHub OIDC
> (Sigstore Fulcio + Rekor). Verifiers need **no committed key** — they use
> `--certificate-identity-regexp` + `--certificate-oidc-issuer`. The two public
> keys in this directory are **retired legacy material**: they relate to older
> artifacts only and are **not** a verification path for any current release.

## Authoritative artifact

The single authoritative receipts package is the keyless one:
`ghcr.io/szl-holdings/szl-receipts:0.4.0-upstream` (public, repo-linked, signed
keyless in CI). Verify it with the keyless command below — **no key file**.

## Retirement decision — internal `packages/szl-receipts` (0.3.1-upstream)

The earlier internal package
`ghcr.io/szl-holdings/packages/szl-receipts:0.3.1-upstream` was an off-CI artifact
built and published from the box and signed with an **ephemeral key-pair whose
private half is gone**. It is **RETIRED**: it is not authoritative, it is not a
verification path for any release, and nothing further will ever be signed with
its key.

**Decision (org owner):** the internal package is **kept as a frozen historical
record — NOT deleted.** Rationale:
- It is already `internal` visibility on GHCR (not publicly pullable), so it does
  not create public confusion about which artifact is authoritative.
- It backs a published, Rekor-logged supply-chain deliverable
  (`warhacker-deliverables/SIGNED-SBOMED-PACKAGE-PUBLISH-2026-06-07.md`); deleting
  it would make that documented round-trip non-reproducible and weaken the
  provenance record.
- Deletion is an irreversible one-shot; keeping the artifact frozen costs nothing.

The confusion the retirement guards against is resolved by docs (this file and the
deliverable) marking 0.4.0-upstream keyless as the **sole** authoritative artifact
and 0.3.1 as retired — not by destroying the historical artifact.

## Retired / legacy files in this directory

| File | Status | What it relates to |
| --- | --- | --- |
| `szl-receipts-package.pub` | **RETIRED** | Public half of the ephemeral box key-pair that signed the **retired internal artifact `ghcr.io/szl-holdings/packages/szl-receipts:0.3.1-upstream` only**. Its private half is gone. Kept solely so the frozen historical artifact remains independently checkable; it is **not** a verification path for any current release. **Current packages are keyless.** |
| `cosign.pub` | **LEGACY / OPTIONAL** | The optional image key-pair. Only used if `COSIGN_PRIVATE_KEY` (+ `COSIGN_PASSWORD`) repo secrets are provisioned; they are not, so the image is signed keyless. |
| `cosign.key` | **NEVER committed** | Encrypted private key. `.gitignore` blocks it. |

## Verify the current (keyless) artifacts — no key file

```bash
# Published package (OCI)
cosign verify ghcr.io/szl-holdings/szl-receipts:0.4.0-upstream \
  --certificate-identity "https://github.com/szl-holdings/szl-uds-deployment/.github/workflows/zarf-package-sign.yml@refs/heads/main" \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com

# Receipts image
cosign verify ghcr.io/szl-holdings/szl-receipts-server:uds-v0.4.0 \
  --certificate-identity-regexp 'receipts-server-image.yml' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
```

## (Optional, legacy) image key-pair details

The optional key-pair path below is retained for operators who specifically want
key-pair (not keyless) image signing. It is **not** required and **not** the
default.

The private key for `cosign.pub` here was generated with
`cosign generate-key-pair` and verified to sign+verify a blob (`Verified OK`).
**It is intentionally not in the repo.** Image signing in CI reads it from the
`COSIGN_PRIVATE_KEY` repo secret (see `.github/workflows/receipts-server-image.yml`).

## (Legacy) Founder step — enable key-pair image signing

You do **not** need this. Both the image and the package are signed **keyless**
today (no secret needed), so `cosign verify --certificate-identity-regexp=...`
works out of the box.

This is retained only if an operator deliberately wants the committed `cosign.pub`
key-pair instead of keyless image signing. Run once (locally, with the `cosign`
CLI authenticated to GitHub via `gh`):

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
