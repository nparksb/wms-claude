---
name: never-build-a-libpq-url-by-concatenating-a-credential
description: "libpq splits userinfo at the FIRST @, so a password containing @ silently redirects the host — it broke check-tenant-migration-drift.sh for all 4 UAT tenants and misreported them as needing a Flyway backfill"
metadata: 
  node_type: memory
  type: reference
  originSessionId: 97e6a0ad-0f09-4189-9d41-ce3c1c2f26cf
  modified: 2026-09-10T15:28:31.358Z
---

**Every wms2 UAT tenant DB password contains a literal `@`** (`wh03Om1@sb`, `wh04Om1@sb`,
`wh05Om1@sb`, `wh01Om1@sb`, from landlord `tenant_db_configuration`). PRD hydra's does not.

**libpq splits userinfo at the FIRST `@`, not the last.** So
`postgresql://wh01_om1:wh01Om1@sb@uat.sbo.li:25060/wh01_om1_v2` resolves the host to **`sb@uat.sbo.li`**
— which is a real, resolvable name (45.79.190.49) — and fails with `Connection refused`. Measured
2026-09-10.

**This is why the failure is dangerous rather than merely annoying: it fails as a *network* error, so
any script that treats "cannot connect" as a diagnosis reports the wrong thing confidently.**
`src/main/resources/db/check-tenant-migration-drift.sh --from-landlord` built exactly that URL by SQL
concatenation, and its failure path reports an unreachable DB as
*"NO HISTORY — a psql-provisioned DB; repair with `backfill-flyway-history.sh`"* + exit 1. So it told
the operator that **all four UAT tenants needed a Flyway-history backfill they did not need** — a
pointer at a repair tool that writes. All four in fact had full history at 2.2.25. Fixed under
SBDEV-3295 by percent-encoding user and password in the SQL (encode `%` FIRST, then `@ : / ? #` and
space; do **not** touch `[`/`]` — those are only special in the *host* part and stripping them would
alter the credential).

**Rules:**
- **Prefer `PGPASSWORD` + `-h/-p/-U/-d` over a URL.** Fields pass separately and no escaping exists to
  get wrong. This is what `verify-tenant-schema-conformance.sh --from-landlord` does.
- Only build a URL when the interface demands one, and then percent-encode.
- Never do the encoding with `CREATE FUNCTION` — these scripts must need no write privilege anywhere.
- When a connection-shaped check reports a *diagnosis* ("no history", "not provisioned"), make it
  distinguish **could not connect** from **connected and found nothing**. Collapsing those is how a
  credential bug becomes a schema verdict.

Once fixed, the same script surfaced something real that the bug had hidden: **`wh02_shipitez_v2`
applied V2.2.11 out of order** (2026-08-17, after a higher version) under
`app.flyway.out-of-order=true`. Its schema is nonetheless clean per
[[wms2-tenant-schema-fingerprint-vs-db-migration]], so the two checks are complementary — that one
compares applied **version sets**, this one compares **column shape**.

Related: [[wms2-tenant-schema-fingerprint-vs-db-migration]], [[verify-script-traps]],
[[a-zero-scan-needs-a-positive-control]].
