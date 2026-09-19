---
name: oms-laravel-api-committed-env-secrets
description: "PROPOSED T3 — .env.dev, .env.uat and .env.testing are tracked in oms-laravel-api with live secrets, and one DB password covers dev+uat, tenant+landlord"
metadata: 
  node_type: memory
  type: project
  originSessionId: af2f3b06-4643-4758-bc47-1a6aa0e91020
  modified: 2026-09-15T15:40:33.147Z
---

**Found 2026-09-15 while standing up the OMS test environment. PROPOSED to Nam, not filed** (T3 =
propose, never file — see [[consolidate-tickets-dont-file-one-per-finding]]). Awaiting his decision.

`v2/oms-laravel-api` tracks **three** env files carrying non-empty, real-shaped secrets — `.env.dev`,
`.env.uat`, `.env.testing`. Only `.env` is in `.gitignore` (line 11); these three are not. In git
since **2025-06-03** (~15 months), 14 commits to `.env.testing` alone.

Secret reuse, by SHA-256 prefix of the value (hashes, so nothing is disclosed):

| key | .env.dev | .env.uat | .env.testing |
|---|---|---|---|
| `DB_PASSWORD` | bfabb965 | bfabb965 | bfabb965 |
| `LANDLORD_PASSWORD` | bfabb965 | bfabb965 | bfabb965 |
| `APP_KEY` | dce1717e | dce1717e | f50b8d71 |
| `KEYCLOAK_CLIENT_SECRET` | a7427727 | 7c9eddc7 | a7427727 |
| `REDIS_PASSWORD` | 74234e98 | 74234e98 | 74234e98 |

**One password opens dev AND uat, tenant AND landlord** — all four `DB_PASSWORD`/`LANDLORD_PASSWORD`
values are the same string. `APP_KEY` (Laravel's signing/encryption key) is shared dev↔uat. The
Keycloak client secret is shared dev↔testing. `.env.testing` also points `DB_DATABASE` at the real
`dev_om1_wineco` with user `kom_om1`, which is how the reuse was noticed.

Same class as [[wms2-landlord-db-password-committed-live]] (SBDEV-3175) and the same cross-environment
reuse pattern as [[wms2-oms-api-credential-identical-dev-and-prd]] (SBDEV-3181). The precedent from
both: **a credential in version control cannot be un-disclosed — rotation is the only remediation**,
and history-scrubbing is not a substitute. Repos are private, which limits but does not remove exposure.

**Do not read the shared prefixes as "probably placeholders".** They were checked: non-empty, and of
credible length (43-char Keycloak secret, 50-char `base64:` APP_KEY, 10-char DB passwords). The only
genuinely empty ones are `MONGODB_PASSWORD`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`,
`KEYCLOAK_REALM`.
