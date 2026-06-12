# Contracting Readiness — operator-supplied org facts (secure env vars)

The Contracting Readiness panel on **a11oy** (`/api/a11oy/v1/contracting`) and
**killinchu** (`/api/killinchu/v1/contracting`) reads the org's own federal
registration facts from **container environment variables only**. Nothing about
the organization is ever fabricated: a fact is shown as `confirmed` **only** when
an operator has supplied it; otherwise it stays `needs_founder_input` /
`needs_founder_action` (an honest unknown is the correct answer).

## How values are supplied (never committed to git)

Values live in a **root-only** file on the box, `/etc/szl-contracting.env`
(`chmod 600`), which is passed to the container via `docker run --env-file`.
The `a11oy-rebuild` / `killinchu-rebuild` scripts inject it automatically
(marker `contracting-env-file-patch`); an absent file is a no-op.

```sh
# /etc/szl-contracting.env  (root:root 600 — DO NOT commit; box-local only)
SZL_CONTRACTING_LEGAL_FORM=LLC
SZL_CONTRACTING_FORPROFIT_US=yes
# ...fill the rest as the company obtains them...
```

Override the file path per service with `A11OY_ENV_FILE` / `KILLINCHU_ENV_FILE`.

## Supported variable names (canonical)

| Env var | Panel fact |
|---|---|
| `SZL_CONTRACTING_UEI` | SAM.gov Unique Entity ID (12-char) |
| `SZL_CONTRACTING_CAGE` | CAGE / NCAGE code |
| `SZL_CONTRACTING_SAM_STATUS` | SAM registration status (Active / Submitted / Expired) |
| `SZL_CONTRACTING_SAM_EXPIRES` | SAM registration expiration (YYYY-MM-DD) |
| `SZL_CONTRACTING_SBC_CONTROL_ID` | SBA Small Business profile / control ID |
| `SZL_CONTRACTING_EMPLOYEES` | Employee headcount (incl. affiliates) |
| `SZL_CONTRACTING_US_OWNERSHIP_PCT` | % U.S.-citizen ownership / control |
| `SZL_CONTRACTING_LEGAL_FORM` | Eligible legal form (LLC / C-Corp / ...) |
| `SZL_CONTRACTING_FORPROFIT_US` | For-profit with U.S. place of business (yes/no) |

EIN / TIN is **deliberately not accepted** here.

### Legacy aliases (a11oy serve.py inline route)

For backward compatibility the a11oy route also reads these if the canonical
name is unset (canonical wins): `A11OY_ORG_UEI`, `A11OY_ORG_CAGE`,
`A11OY_ORG_HEADCOUNT`, `A11OY_ORG_OWNERSHIP`, `A11OY_ORG_LEGAL_NAME`.

The canonical `SZL_CONTRACTING_*` names are the env-var → `confirmed` mapping in
`szl_contracting.py` (`_ORG` / `_ORG_ENV`) used by killinchu and by a11oy's
inline route alike.

> **Note:** only **4 of the 9** canonical vars have a paired legacy alias
> (`UEI`, `CAGE`, `EMPLOYEES`←`HEADCOUNT`, `US_OWNERSHIP_PCT`←`OWNERSHIP`).
> `A11OY_ORG_LEGAL_NAME` is a standalone legacy name with no canonical pair, and
> the remaining canonical vars (`SAM_STATUS`, `SAM_EXPIRES`, `SBC_CONTROL_ID`,
> `LEGAL_FORM`, `FORPROFIT_US`) have no alias. In every alias tuple the canonical
> name is listed **first**, so a value set under the canonical var always wins.

## CI guard against silent reverts

`.github/workflows/contracting-env-guard.yml` (no cluster required) protects this
contract from regressing on either surface. It runs `scripts/contracting-env-checks.py`,
which asserts that **both** surfaces — the a11oy `serve.py` inline `_ct_org` route
and the canonical `szl_contracting.py` module — still:

- read **all 9** canonical `SZL_CONTRACTING_*` vars,
- (a11oy) read the **5 legacy aliases** with the canonical name listed first, and
- map a **present** value → `confirmed` and an **absent** value →
  `needs_founder_input`.

Because the two surfaces live in separate repos (`szl-holdings/a11oy` and
`szl-holdings/killinchu`), a push here cannot observe a regression there, so the
guard checks both repos out and also runs on a **weekly schedule** to catch
cross-repo drift. `scripts/contracting-env-checks.test.py` is a self-test with
negative fixtures (renamed var, dropped alias, reversed alias pair, ungated
`confirmed`, lost present→confirmed mapping, removed honest default) that gates
the checker before it runs against the live surfaces.
