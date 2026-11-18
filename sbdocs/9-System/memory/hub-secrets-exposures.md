---
name: hub-secrets-exposures
description: Credentials committed or logged across repos, and exposure findings. Hub: one line per member memory
metadata:
  type: reference
---

Hub for **Committed secrets & exposures**. Moved out of MEMORY.md on 2026-10-28 to keep the index under its load limit; each line links the member memory (newest last).

- [Plaintext Keycloak passwords logged at DEBUG](wms2-plaintext-keycloak-passwords-logged-at-debug.md) — UserController:242/:301 log the raw body
- [SBDEV-3175 landlord DB password committed LIVE](wms2-landlord-db-password-committed-live.md) — cleartext in git since 2025-12-28, never rotated;
- [SBDEV-3181 OMS API credential identical on ALL SIX tenant DBs](wms2-oms-api-credential-identical-dev-and-prd.md) — dev value IS prd's; FILED High;
- [SBDEV-3194 registry credential in 25 workflows](sbdev-3194-registry-credential-in-25-workflows.md) — ONE write credential, 7 repos, since 2024-12-20; repos are PRIVATE; rotation mandatory
- [Never build a libpq URL by concatenating a credential](never-build-a-libpq-url-by-concatenating-a-credential.md) — libpq splits userinfo at the FIRST `@`; all 4 UAT passwords contain one
- [PROPOSED T3: oms-laravel-api committed env secrets](oms-laravel-api-committed-env-secrets.md) — 3 tracked .env files; one DB password covers dev+uat
- [PRD public schema CREATE to PUBLIC](wms2-prd-public-schema-create-granted-to-public.md)
- [Never print process command lines](never-print-process-command-lines.md) — pgrep -fl / ps aux printed MCP connection strings with passwords; find peers by cwd or count
- [[prd-landlord-role-has-createrole-pg14]]: PRD wms2_landlord_app has CREATEDB+CREATEROLE on PG14; rotation since 3175 unconfirmed (2026-11-09)
