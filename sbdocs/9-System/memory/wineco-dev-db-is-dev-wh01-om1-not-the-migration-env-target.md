---
name: wineco-dev-db-is-dev-wh01-om1-not-the-migration-env-target
description: "wms2-wineco-dev" = database dev_wh01_om1 on localhost:25060; migration.env.wineco points at the STALE wh01_om1_v2 copy, which answers every query with plausible wrong data
metadata:
  type: reference
---

**"`wms2-wineco-dev`" is the database `dev_wh01_om1`** (tunnel `localhost:25060`). `om1` is WineCo's tenant code — the same `om1` as the API's Keycloak client `om1-api`.

Three plausible-looking copies sit beside it on the same tunnel, and two of them answer every query rather than erroring:

| database | what it is | flyway | `location` rows |
|---|---|---|---|
| **`dev_wh01_om1`** | ✅ the live DEV tenant DB | current (V2.2.13 on 2026-08-11) | 2,739 |
| `wh01_om1_v2` | v1→v2 migration-era copy | **no `flyway_schema_history` at all** | 2,890 |
| `wh01_om1` | the v1 database | n/a | 2,766 |

⚠ **`migration.env.wineco` points at the WRONG one for anything except onboarding.** It is the v1→v2 toolkit's config, so `TENANT_DB_NAME=wh01_om1_v2`. Sourcing it to "check DEV" on 2026-08-12 reported `putaway_config_audit` MISSING and `itemdata.putawaylocation_id` NOT NULL — which reads as "the migration was never applied" when it had been applied the day before and was present in `dev_wh01_om1`. Credentials in that env file DO work against all three databases, so nothing fails; you just get confidently wrong answers.

The `dev_` prefix is the tell, and it is the same shape as [[wms2-dev-landlord-is-dev-landlord-not-landlord]]: the DEV object carries the prefix and a stale same-named sibling sits next to it. That note covers the landlord; this one covers the tenant DB.

**How to confirm you are on the right database — always do this first:**

```sql
select version, installed_on, success
from flyway_schema_history order by installed_rank desc limit 5;
```

A missing `flyway_schema_history` means you are on a psql-provisioned or migration-era copy, not the running DEV tenant (see [[sbdev-2801-runtime-flyway-default-on]] — such DBs are skipped by the startup migrator and never auto-baselined). Confirm by the history head, never by an env file.

**Also measured 2026-08-12, correcting a figure quoted five times in the SBDEV-2643 plan:** `select count(*) from location where name <> 'PutAwayLane'` on `dev_wh01_om1` returns **2,738** of 2,739 — i.e. 14 pages at `size=200`, not the plan's 2,564/13. The 2,564 figure matches none of the three copies and could not be reconstructed from any plausible predicate. Related: [[sbdev-2643-sku-default-putaway-location-ui]] if that note exists.
