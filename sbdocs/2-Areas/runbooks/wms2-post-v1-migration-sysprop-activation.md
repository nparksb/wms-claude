---
title: "WMS v2 — post-migration los_sysprop activation runbook"
type: runbook
audience: "DevOps (Joe) — executed per tenant database"
version: v2
owner: Nam Park
requester: "nam.park@siteboss.net"
created: 2026-09-10
updated: 2026-09-11
last_verified: 2026-09-11
verified_by: "Every SQL statement below checked against the actual schema and Flyway seeds on all 6 live v2 tenant DBs (1 PRD, 4 UAT, 1 DEV) via direct psql, 2026-09-10. 2026-09-11: full audit run against DEV (dev_wh01_om1) on build 1be9db0e — §5 passed 14/14 after activating the 4 keys still at seed value; §2.2 added for WEBSERVICE_TRANSFER_PICKING_NOTIFICATIONS_ACTIVATED, with its enable path exercised end-to-end (OMS answered processed:1 on both transfer types) and then reverted."
related:
  - ../../../3-Resources/data-dictionary/wms2-sysprop-catalog.md
  - ./wms2-apply-pending-tenant-flyway.md
  - ./wms2-unstick-held-outbox-aggregate.md
tags:
  - runbook
  - sysprop
  - migration
  - wms2
---

# WMS v2 — post-migration `los_sysprop` activation

**When to run:** after a WMS v1 → v2 database migration **and** the v2 code deploy, once per tenant
database.

**Who runs it:** DevOps, with a DBA-capable connection to the tenant DB (the app role that owns
`los_sysprop`, e.g. `wh01_hydra_v2_app`).

**Scope:** the tenant database only. Nothing here touches the landlord DB, Keycloak, or application
config.

> Every statement below was verified against the live schema and Flyway seeds on all six v2 tenant
> databases on 2026-09-10. Where this runbook differs from the original draft, the reason is stated
> inline — those are not stylistic edits.

---

## 0. Before you start

### 0.1 One database at a time

**Each tenant is a separate database.** Every `UPDATE` in this runbook is unqualified — it applies to
whatever database your session is connected to. Do **not** paste a multi-tenant block into one
session: the last statement wins and you will silently configure the wrong tenant.

Use this guard at the top of every session. It aborts if you are connected to the wrong database:

```sql
\set ON_ERROR_STOP on
DO $$
BEGIN
  IF current_database() <> :'expected_db' THEN
    RAISE EXCEPTION 'Wrong database: connected to %, expected %',
      current_database(), :'expected_db';
  END IF;
END $$;
```

Invoke as `psql "$DSN" -v expected_db=wh01_hydra_v2 -f step1.sql`.

### 0.2 Pre-flight checks

Run all four. Each has an expected answer; stop and escalate on any mismatch.

```sql
-- (1) Flyway must be at head with zero failures. If this is behind, the rows this
--     runbook expects may not exist yet — run wms2-apply-pending-tenant-flyway first.
SELECT max(version) AS head,
       count(*) FILTER (WHERE success = false) AS failed
  FROM flyway_schema_history;
-- expect: head = the deployed build's migration head, failed = 0

-- (2) The unique constraint the upsert in step 1 depends on.
SELECT conname, pg_get_constraintdef(oid)
  FROM pg_constraint
 WHERE conrelid = 'public.los_sysprop'::regclass AND contype = 'u';
-- expect: uk8tcoe23qui9q3ancbhx662iqb  UNIQUE (client_id, syskey, workstation)
-- verified present on all 6 live tenant DBs. Without it, step 1 fails with
-- 42P10 "no unique or exclusion constraint matching the ON CONFLICT specification".

-- (3) No unconfigured placeholders left from the base dump.
SELECT syskey, sysvalue FROM los_sysprop
 WHERE sysvalue LIKE '%CHANGE-ME-FOR-NEW-CLIENT%' ORDER BY syskey;
-- expect: 0 rows. Any row here must be fixed in step 3 before step 1 enables anything.

-- (4) The cron master gate. This is NOT in the activation script and is easy to miss.
SELECT sysvalue FROM los_sysprop
 WHERE syskey = 'NEW_CRON_JOB_ACTIVATED' AND client_id = 0 AND workstation = 'DEFAULT';
-- expect: 'true'
```

⚠ **Check (4) is the one that bites.** `NEW_CRON_JOB_ACTIVATED` is the master gate for **all six**
business cron jobs (order release, replenishment, pick timeout, stock-summary export, message
cleanup, stale-club-batch cleanup). A cutover that leaves it `false` or absent produces stock that is
searchable but not pickable, with no error anywhere. It is read with `Boolean.parseBoolean`, so an
absent row is `false`. All six live DBs are currently `true`; a freshly migrated one may not be.

### 0.3 Cache behaviour — read this before you plan the window

`SyspropService.getSysvalue` is `@Cacheable("sysprops")`. Raw SQL bypasses the application's cache
eviction, so a flip made this way is **not** immediately visible:

- default (Caffeine) — up to **~2 minutes per replica**
- `redis` profile — immediate and cross-replica

**Preferred order: run this runbook before the app is serving traffic, or roll the pods afterwards.**
Do not report a flag as "enabled" until one of those has happened.

---

## 1. Activate the v2-only functions

Idempotent upsert: inserts the row if the tenant lacks it, corrects the value if it differs, no-ops if
already right.

### 1.1 What changed from the draft, and why

Four corrections, all load-bearing:

| # | Change | Why |
|---|---|---|
| 1 | **`OUTBOX_REJECT_ON_ERROR_STATUS_ACTIVATED` removed** | It has **zero consumers** in `origin/develop` — the only files mentioning it are its own two migrations. Setting it `true` does nothing today, and becomes **live enforcement** the moment SBDEV-2736 Phase 2 deploys, with nobody reviewing. `V2.2.05`'s header says explicitly: do not enable before the retryability classification is done. Leave it `false`. |
| 2 | **`TRANSFER_DESTINATION_ELIGIBILITY_ENABLED` moved to §2 (hold)** | `V2.2.17` ships it `false` as **shadow mode** on purpose. Measured on `wms2-wineco-dev`, enforcing would refuse **411,862 unit loads** (395,984 carrying stock). On a freshly migrated tenant the lock states are inherited from v1 and unmeasured. Enabling at cutover risks refusing legitimate Move Stock on day one. |
| 3 | **`groupname` corrected per key** | The draft filed everything under `Operation Options`. Flyway seeds several of these under `Backend`, and `PRINT_CASE_LABEL` under `System Settings`. This only matters when the INSERT branch fires — but it already has: `wsl-wineco-uat`'s `WEBSERVICE_ORDER_BATCH_UPDATE_PICKING_DATE_ACTIVATED` sits under `Operation Options` today because the draft created it before `V2.2.24` landed, and `V2.2.24`'s `WHERE NOT EXISTS` then skipped it. The row is misfiled in the admin UI permanently until corrected. |
| 4 | **Two `WEBSERVICE_*_ACTIVATED` gates now have a hard pre-check** | See §1.2. Enabling either with a wrong or missing URL enqueues outbox messages that cannot be delivered. |

The draft's comment `-- same seven keys` described 12 keys. Corrected to 10 below.

### 1.2 Required pre-check for the two OMS notification gates

`WEBSERVICE_ORDER_BATCH_UPDATE_PRIORITY_ACTIVATED` and `..._UPDATE_PICKING_DATE_ACTIVATED` each
require **(a)** a correct URL in their paired URL key and **(b)** the OMS endpoint deployed. Assert
(a) before step 1 — replace `api-oms.uat.sbo.li` with the host for your environment:

```sql
SELECT syskey, sysvalue,
       CASE WHEN sysvalue LIKE 'https://api-oms.uat.sbo.li/%' THEN 'OK' ELSE '*** WRONG HOST ***' END
  FROM los_sysprop
 WHERE syskey IN ('WEBSERVICE_ORDER_BATCH_UPDATE_PRIORITY',
                  'WEBSERVICE_ORDER_BATCH_UPDATE_PICKING_DATE')
 ORDER BY syskey;
-- expect: 2 rows, both OK. Fix via step 4 before enabling. Confirm (b) with the OMS team.
```

This is not hypothetical — see §7, finding B.

### 1.3 The script

```sql
-- STEP 1 — activate v2-only functions. Idempotent; safe to re-run.
-- Descriptions must stay under 255 chars: los_sysprop.description is varchar(255) and
-- Postgres raises 22001 (it does not truncate).
BEGIN;

WITH forced(syskey, sysvalue, groupname, descr) AS (VALUES
    -- 1A. UNIVERSAL — correct for every v1 -> v2 migration
    ('API_TIMESTAMP_FORMAT', 'ISO8601_UTC', 'Backend',
     'v2 serialises all API timestamps as ISO-8601 UTC.'),

    -- 1B. PER-CLIENT — confirm with Nam before reusing on a new tenant
    ('PRINT_CASE_LABEL', 'true', 'System Settings',
     'Enables case-label printing.'),
    ('TRANSFER_LANE_PARTIAL_DEPLETION_ACTIVATED', 'true', 'Operation Options',
     'SBDEV-1762: run transfer consumes only the order''s required SKUs/qty from the lane.'),
    ('REPLENISH_EXCLUDE_STAGING_TRANSFER_LANES_ACTIVATED', 'true', 'Operation Options',
     'SBDEV-1666: staging and transfer lanes are never selected as a replenishment source.'),
    ('OUTBOX_STUCK_AGGREGATE_METRIC_ACTIVATED', 'true', 'Operation Options',
     'SBDEV-2381: dispatcher samples held-aggregate stats and emits the stuck-aggregate gauge.'),
    ('RETURN_ADVICE_AUTO_RECEIVE_ACTIVATED', 'true', 'Operation Options',
     'SBDEV-2778: a type=RETURN advice is received and closed at creation time.'),
    ('REPLENISH_ALLOW_NON_FLOWBIN_DESTINATIONS', 'true', 'Operation Options',
     'SBDEV-2854: replenishment destination need not be a flowbin; area useforpicking decides.'),
    ('ADJUSTMENT_ALERT_POLL_ACTIVATED', 'true', 'Operation Options',
     'SBDEV-2658: serves inventory-adjustment rows to the web-UI bell/toast poller.'),
    ('WEBSERVICE_ORDER_BATCH_UPDATE_PRIORITY_ACTIVATED', 'true', 'Backend',
     'SBDEV-2573: WMS enqueues an outbox notification to OMS on every priority change.'),
    ('WEBSERVICE_ORDER_BATCH_UPDATE_PICKING_DATE_ACTIVATED', 'true', 'Backend',
     'SBDEV-3273: WMS enqueues an outbox notification to OMS on every picking-date change.')
)
-- (a) create any row this tenant lacks
INSERT INTO public.los_sysprop
    (id, version, entity_lock, hidden, syskey, sysvalue,
     workstation, client_id, groupname, description, created, modified)
SELECT nextval('public.seqentities'), 0, 0, false, f.syskey, f.sysvalue,
       'DEFAULT', 0, f.groupname, f.descr, now(), now()
  FROM forced f
ON CONFLICT (client_id, syskey, workstation) DO NOTHING;

-- (b) correct the value on rows that already existed. Same 10 keys, single source of truth.
UPDATE public.los_sysprop s
   SET sysvalue = f.sysvalue, modified = now()
  FROM (VALUES
    ('API_TIMESTAMP_FORMAT', 'ISO8601_UTC'),
    ('PRINT_CASE_LABEL', 'true'),
    ('TRANSFER_LANE_PARTIAL_DEPLETION_ACTIVATED', 'true'),
    ('REPLENISH_EXCLUDE_STAGING_TRANSFER_LANES_ACTIVATED', 'true'),
    ('OUTBOX_STUCK_AGGREGATE_METRIC_ACTIVATED', 'true'),
    ('RETURN_ADVICE_AUTO_RECEIVE_ACTIVATED', 'true'),
    ('REPLENISH_ALLOW_NON_FLOWBIN_DESTINATIONS', 'true'),
    ('ADJUSTMENT_ALERT_POLL_ACTIVATED', 'true'),
    ('WEBSERVICE_ORDER_BATCH_UPDATE_PRIORITY_ACTIVATED', 'true'),
    ('WEBSERVICE_ORDER_BATCH_UPDATE_PICKING_DATE_ACTIVATED', 'true')
  ) AS f(syskey, sysvalue)
 WHERE s.syskey = f.syskey AND s.client_id = 0 AND s.workstation = 'DEFAULT'
   AND s.sysvalue IS DISTINCT FROM f.sysvalue;

COMMIT;
```

> `ADJUSTMENT_ALERT_POLL_ACTIVATED = true` additionally requires the wms2-web-ui adjustment poller to
> be deployed. Harmless if it is not — the endpoint simply serves rows nobody asks for.

---

## 2. Deliberately held OFF — do not enable at cutover

Leave these at their seeded values. Each needs a measurement first, and the decision is **Nam's, not
DevOps'**.

| Key | Seeded | Why held | What retires the hold |
|---|---|---|---|
| `TRANSFER_DESTINATION_ELIGIBILITY_ENABLED` | `false` | Shadow mode. Enforcing refuses any Move Stock destination whose `unitload.entity_lock` is not `0` (`NOT_LOCKED`) or which sits at the `Shipped` location. **Measured 2026-09-10: that is 93–98% of all unit loads on every UAT tenant.** | Run one full operating cycle, then count `SBDEV-2994 shadow: would have refused` WARN lines in the app log. Flip to `true` only where the count is **zero**. |
| `OUTBOX_REJECT_ON_ERROR_STATUS_ACTIVATED` | `false` | Zero code consumers today; becomes live enforcement on a future deploy. Enforcing against the current rejection rate would wedge outbox aggregates that then need manual clearing. | SBDEV-2736 Phase 2 ships **and** the retryability classification is done. |
| `WMS2_SDR_READ_GUARD_MODE` | `OFF` | Authorization gate; advancing it can start denying reads. Also **not writable through the API by design** — SQL is the only path. | `SHADOW` first, watch the `wms2.authz.sdr.would_deny` metric, then `ENFORCE_RULED`. Any unrecognised value silently means `OFF`. |
| `WEBSERVICE_TRANSFER_PICKING_NOTIFICATIONS_ACTIVATED` | **(no row at all)** | SBDEV-3311 ships dark. Enables the two transfer-run picking notifications to OMS. ⚠ **No migration seeds this key** — it is absent on every tenant, and `Boolean.parseBoolean(null)` is `false`, so absent *is* the OFF state. Enabling is an `INSERT`, not an `UPDATE`. | Both original blockers are now **discharged** (see §2.2). What remains is a per-tenant decision plus the URL pre-check — not a measurement. |

### 2.1 Sizing `TRANSFER_DESTINATION_ELIGIBILITY_ENABLED` before you flip it

The refusable population is large **by design** and that alone is not a reason to hold. `entity_lock`
on `unitload` carries `BusinessObjectLockState` codes, and in real inherited data the common values are
`405` = `SHIPPED` and `2` = `GOING_TO_DELETE` — both states you *want* refused as a destination. Only
`0` = `NOT_LOCKED` is acceptable. The same distribution exists on the v1 databases, so this is migrated
history, not a v2 artefact.

Measured 2026-09-10, refusable unit loads (`entity_lock <> 0` OR location `Shipped`):

| Tenant | Refusable / total | Carrying stock | Enforcing? |
|---|---|---|---|
| `wh01_om1_v2` (wineco/wsl) | 855,839 / 870,840 (98.3%) | 469,580 | **true** ⚠ |
| `wh01_shipitez_v2` (shipitez/c1wh) | 123,315 / 125,512 (98.2%) | 106,009 | **true** ⚠ |
| `wh01_hydra_v2` (hydra/nywh) | 13,733 / 14,302 (96.0%) | 9,403 | **true** ⚠ |
| `wh02_shipitez_v2` (shipitez/nywh) | 1,611 / 1,727 (93.3%) | 1,398 | false |

**So the number that decides the flip is not this population — it is whether any live workflow
actually targets one of these as a destination.** That is precisely what the shadow WARN counts, and
it is the measurement you lose by enforcing early: enforcement replaces the WARN with a refusal, so
the log no longer tells you whether the refusal was harmless. Count first, flip second.

```sql
-- the population, per tenant (safe, read-only)
SELECT count(*) AS refusable,
       (SELECT count(*) FROM unitload) AS total,
       count(*) FILTER (WHERE EXISTS (SELECT 1 FROM stockunit su WHERE su.unitload_id = u.id)) AS with_stock
  FROM unitload u
  LEFT JOIN location l ON l.id = u.storagelocation_id
 WHERE u.entity_lock <> 0 OR l.name = 'Shipped';
```

---

### 2.2 `WEBSERVICE_TRANSFER_PICKING_NOTIFICATIONS_ACTIVATED` — added 2026-09-11

**Why this key is not in §1.** It postdates this runbook: the runbook was written 2026-09-10 and
SBDEV-3311 merged at 21:20 UTC that evening. A tenant cut over with the §1 script gets a fully green
§5 verification while this feature is silently off — which is exactly the failure shape §4.3 warns
about, one layer up. That gap is why it is documented here.

**What it switches on.** Exactly one call site — `BillofladingService.transferOrder` (the
`/v3/transfers/runTransfer/{id}` handler). With it on, completing a transfer run enqueues two outbox
messages per order:

| process type | endpoint sysprop | OMS path |
|---|---|---|
| `ORDER_BATCH_PICKING_RELEASED` | `WEBSERVICE_ORDER_BATCH_RELEASED_FOR_PICKING` | `/services/call/readytopick` |
| `ORDER_BATCH_PICKING_STARTED` | `WEBSERVICE_ORDER_BATCH_PICKING` | `/services/call/picking` |

Without it, a transfer order's whole OMS lifecycle is `ORDER_BATCH_IMPORT → ORDER_BATCH_SHIPPED` with
nothing in between — measured at up to 26 hours of silence on WineCo prd across 588 finished transfer
batches. It applies to **both** `TRANSFER_OFFSITE` and `TRANSFER_INTRACOMPANY`.

⚠ **It does NOT enable the transfer *completion* callback.** `finishTransfer` contains no
notification code of any kind (verified on the deployed build), so no flag can switch that on. OMS
still learns nothing when an intra-company transfer completes. Different defect, tracked on
SBDEV-3268 / the SBDEV-3311 description.

**Both original hold reasons are discharged** — the constant's javadoc named two pre-enablement
blockers, and both were closed on dev 2026-09-11 (build `1be9db0e`, tenant `dev_wh01_om1`):

1. *"Whether an OMS `parcel` row resolves from a transfer CO's `unique_id` at all"* — the javadoc said
   this needed an OMS database or one real round trip. **It resolves.** Both endpoints answered
   `{"Status":"Success","processed":1,"total":1}` on both transfer types. `processed:1` is the
   load-bearing field, **not** the HTTP 200 — these endpoints return through
   `legacyVerdictResponse()`, which answers 200 with the errors in the body, so a 200 alone (and
   therefore `SENT` in `outbox_message`) proves nothing.
2. *A double `runTransfer` colliding on `uk_outbox_message_idempotency_key`* — closed by the
   entry-state guard shipped in the same PR, verified refusing a second run.

So enabling this is now a decision, not a research task. It remains per tenant and OFF by default.

#### Pre-check, then enable

```sql
-- (1) BOTH endpoint URLs must be present and on THIS environment's OMS host.
--     A blank URL does not fail — the code logs a warning and SKIPS that one notification,
--     so a half-configured tenant sends half the messages and looks healthy.
--     Substitute the host for your environment (dev/uat/prd) — see §8.
SELECT syskey, sysvalue,
       CASE WHEN sysvalue LIKE 'https://api-oms.uat.sbo.li/%' THEN 'OK' ELSE '*** WRONG HOST ***' END
  FROM los_sysprop
 WHERE syskey IN ('WEBSERVICE_ORDER_BATCH_RELEASED_FOR_PICKING',
                  'WEBSERVICE_ORDER_BATCH_PICKING')
   AND client_id = 0 AND workstation = 'DEFAULT'
 ORDER BY syskey;
-- expect: 2 rows, both OK. Fix via §4.2 before enabling.

-- (2) Enable. INSERT, not UPDATE — no migration seeds this key.
--     Idempotent: re-running corrects the value if the row already exists.
INSERT INTO public.los_sysprop
    (id, version, entity_lock, hidden, syskey, sysvalue,
     workstation, client_id, groupname, description, created, modified)
SELECT nextval('public.seqentities'), 0, 0, false,
       'WEBSERVICE_TRANSFER_PICKING_NOTIFICATIONS_ACTIVATED', 'true',
       'DEFAULT', 0, 'Backend',
       'SBDEV-3311: transfer run emits readyToPick + picking notifications to OMS.', now(), now()
ON CONFLICT (client_id, syskey, workstation)
DO UPDATE SET sysvalue = 'true', modified = now()
        WHERE los_sysprop.sysvalue IS DISTINCT FROM 'true';
```

Only the literal `'true'` (any casing) enables it. `'1'`, `'yes'`, or `'true '` with a trailing space
all parse as `false`, silently. Then wait out the cache or roll the pods (§0.3).

**To roll back:** `DELETE FROM los_sysprop WHERE syskey =
'WEBSERVICE_TRANSFER_PICKING_NOTIFICATIONS_ACTIVATED';` — returning it to absent is the correct OFF
state, and the §6 pre-image will not restore a row that never existed when the pre-image was taken.

## 3. Mark the v1-only keys

These 13 keys are read **only** by `UtilRestController`, which is annotated `@Service` — not
`@RestController` — so its `@RequestMapping` methods do not route. Verified on `origin/develop`:
**nothing in v2 consumes any of them.** Stamping them is safe and makes the dead config obvious in
the admin UI.

```sql
-- STEP 3 — stamp v1-only keys. Idempotent.
BEGIN;
UPDATE public.los_sysprop
   SET sysvalue = 'VERSION-1.0-ONLY', modified = now()
 WHERE syskey IN (
        'KEYCLOAK_API_USER',
        'KEYCLOAK_APP_GROUP_NAME',
        'KEYCLOAK_CLIENT',
        'KEYCLOAK_LOGOUT_URL',
        'KEYCLOAK_OMS_USER_GROUP',
        'KEYCLOAK_OMS_USER_PREFERRED_SCHEMA',
        'KEYCLOAK_REALM',
        'KEYCLOAK_SERVER_URL',
        'MOBILE_UI_REDIRECT_URL',
        'OLD_CRON_JOB_ACTIVATED',
        'WEB_UI_REDIRECT_URL',
        'WMS_INSTANCE_NAME',
        'WMS_LOGIN_SECRET')
   AND sysvalue IS DISTINCT FROM 'VERSION-1.0-ONLY';
COMMIT;
```

Two notes:

- v2 gets its Keycloak configuration **per tenant from the landlord DB** (`tenant_auth_configuration`),
  never from these tenant sysprops. That is why stamping them cannot break authentication.
- `OLD_CRON_JOB_ACTIVATED` is the one key here whose name suggests it still matters. It does not — its
  only reader is the same non-routing controller. `'VERSION-1.0-ONLY'` also happens to parse as
  `false` under `Boolean.parseBoolean`, so the stamp is safe either way. Do **not** confuse it with
  `NEW_CRON_JOB_ACTIVATED`, which must stay `true` (§0.2 check 4).

---

## 4. Client-specific values — one block per database

⚠ **Run exactly one row of each table below, in the matching database.** The original draft listed
all four tenants as consecutive unqualified `UPDATE`s; pasted into one session the last line wins and
that tenant silently gets another tenant's mobile URL.

### 4.1 `MOBILE_UI_URL` — UAT

| Database | Command |
|---|---|
| `wh01_om1_v2` (wineco/wsl) | `UPDATE los_sysprop SET sysvalue='https://wsl-wineco.wms.uat.sbo.li/mobile', modified=now() WHERE syskey='MOBILE_UI_URL';` |
| `wh01_hydra_v2` (hydra/nywh) | `UPDATE los_sysprop SET sysvalue='https://nywh-hydra.wms.uat.sbo.li/mobile', modified=now() WHERE syskey='MOBILE_UI_URL';` |
| `wh01_shipitez_v2` (shipitez/c1wh) | `UPDATE los_sysprop SET sysvalue='https://c1wh-shipitez.wms.uat.sbo.li/mobile', modified=now() WHERE syskey='MOBILE_UI_URL';` |
| `wh02_shipitez_v2` (shipitez/nywh) | `UPDATE los_sysprop SET sysvalue='https://nywh-shipitez.wms.uat.sbo.li/mobile', modified=now() WHERE syskey='MOBILE_UI_URL';` |

### 4.2 OMS API host rewrite — UAT

```sql
-- Run the ONE line matching this database's previous OMS host.
UPDATE los_sysprop SET sysvalue = replace(sysvalue, 'https://api-oms.wineco.sbo.li/',   'https://api-oms.uat.sbo.li/'), modified = now() WHERE syskey LIKE 'WEBS%';
UPDATE los_sysprop SET sysvalue = replace(sysvalue, 'https://api-oms.hydra.sbo.li/',    'https://api-oms.uat.sbo.li/'), modified = now() WHERE syskey LIKE 'WEBS%';
UPDATE los_sysprop SET sysvalue = replace(sysvalue, 'https://api-oms.shipitez.sbo.li/', 'https://api-oms.uat.sbo.li/'), modified = now() WHERE syskey LIKE 'WEBS%';
```

`replace()` is a no-op on values that do not contain the search string, so running the wrong line here
is harmless — unlike §4.1. `LIKE 'WEBS%'` also matches non-URL keys (`WEBSERVICE_BEHAVIOUR`, the
`*_ACTIVATED` gates); `replace()` leaves those untouched.

### 4.3 ⚠ Re-run §4.2 after every deploy that adds a `WEBSERVICE_*` URL key

`V2.2.22` and `V2.2.24` **derive** their new OMS URL from the tenant's existing
`WEBSERVICE_ORDER_BATCH_CANCELLED` row at migration time. If that row still holds a pre-cutover host,
the newly seeded key inherits it — and a host rewrite that ran *before* the migration never saw the
new key.

This has already happened twice in production and UAT (§7). Make §4.2 the **last** step after any
Flyway advance, and then run the §5 verification.

---

## 5. Verification

Run in the same session, after §1–§4. Then restart the pods (or wait out the cache TTL, §0.3).

```sql
-- (1) every activated flag, with a verdict column
SELECT s.syskey, s.sysvalue, s.groupname,
       CASE WHEN s.sysvalue = e.expected THEN 'OK' ELSE '*** MISMATCH ***' END AS verdict
  FROM los_sysprop s
  JOIN (VALUES
        ('API_TIMESTAMP_FORMAT','ISO8601_UTC'),
        ('PRINT_CASE_LABEL','true'),
        ('TRANSFER_LANE_PARTIAL_DEPLETION_ACTIVATED','true'),
        ('REPLENISH_EXCLUDE_STAGING_TRANSFER_LANES_ACTIVATED','true'),
        ('OUTBOX_STUCK_AGGREGATE_METRIC_ACTIVATED','true'),
        ('RETURN_ADVICE_AUTO_RECEIVE_ACTIVATED','true'),
        ('REPLENISH_ALLOW_NON_FLOWBIN_DESTINATIONS','true'),
        ('ADJUSTMENT_ALERT_POLL_ACTIVATED','true'),
        ('WEBSERVICE_ORDER_BATCH_UPDATE_PRIORITY_ACTIVATED','true'),
        ('WEBSERVICE_ORDER_BATCH_UPDATE_PICKING_DATE_ACTIVATED','true'),
        ('NEW_CRON_JOB_ACTIVATED','true'),
        ('TRANSFER_DESTINATION_ELIGIBILITY_ENABLED','false'),
        ('OUTBOX_REJECT_ON_ERROR_STATUS_ACTIVATED','false'),
        ('WMS2_SDR_READ_GUARD_MODE','OFF')
       ) AS e(syskey, expected) ON e.syskey = s.syskey
 WHERE s.client_id = 0 AND s.workstation = 'DEFAULT'
 ORDER BY verdict DESC, s.syskey;
-- expect: 14 rows, all OK. Fewer than 14 rows means Flyway is behind (§0.2 check 1).
--
-- ⚠ THIS INNER JOIN CANNOT DISTINGUISH "absent" FROM "not expected". A key with no row
-- simply vanishes from the result, and the only signal is a row COUNT you have to notice.
-- That is how a missing key reads as a clean pass. Prefer the LEFT JOIN form below, which
-- names the offender instead of making you count:
--
--   SELECT e.syskey, e.expected, COALESCE(s.sysvalue,'<ABSENT>') AS actual,
--          CASE WHEN s.syskey IS NULL      THEN '*** MISSING ***'
--               WHEN s.sysvalue = e.expected THEN 'OK'
--               ELSE '*** MISMATCH ***' END AS verdict
--     FROM (VALUES ...same list...) AS e(syskey, expected)
--     LEFT JOIN los_sysprop s
--            ON s.syskey = e.syskey AND s.client_id = 0 AND s.workstation = 'DEFAULT'
--    ORDER BY verdict, e.syskey;

-- (1b) The §2 hold keys that have NO seeded row. These are deliberately absent, so they
--      cannot appear in (1) — absence IS the correct state and must be asserted separately.
SELECT 'WEBSERVICE_TRANSFER_PICKING_NOTIFICATIONS_ACTIVATED' AS syskey,
       COALESCE((SELECT sysvalue FROM los_sysprop
                  WHERE syskey = 'WEBSERVICE_TRANSFER_PICKING_NOTIFICATIONS_ACTIVATED'
                    AND client_id = 0 AND workstation = 'DEFAULT'), '<ABSENT — OFF>') AS actual;
-- expect at cutover: '<ABSENT — OFF>'. 'true' means someone enabled SBDEV-3311's transfer
-- picking notifications on this tenant — intended only as a deliberate per-tenant decision
-- (§2.2), never as a side effect of a cutover.

-- (2) NO OMS URL may point at another environment. Substitute your env's host.
SELECT syskey, sysvalue FROM los_sysprop
 WHERE syskey LIKE 'WEBS%' AND sysvalue LIKE 'http%'
   AND sysvalue NOT LIKE 'https://api-oms.uat.sbo.li/%'
 ORDER BY syskey;
-- expect: 0 rows. Any row is a cross-environment callback — fix with §4.2, then re-run.

-- (3) mobile URL belongs to THIS tenant
SELECT current_database(), sysvalue FROM los_sysprop WHERE syskey = 'MOBILE_UI_URL';

-- (4) row hygiene: one row per key, system client, default workstation
SELECT syskey, count(*) FROM los_sysprop
 WHERE syskey IN ('MOBILE_UI_URL','NEW_CRON_JOB_ACTIVATED','ADJUSTMENT_ALERT_POLL_ACTIVATED')
 GROUP BY 1 HAVING count(*) > 1;
-- expect: 0 rows. A client- or workstation-scoped duplicate at a LOWER client_id
-- SHADOWS the row you just edited: the app reads
-- "... WHERE syskey = ? AND workstation = 'DEFAULT' ORDER BY client_id LIMIT 1".
```

---

## 6. Rollback

Every step is a value change on existing rows — no schema change, no data loss. Capture a pre-image
first and rollback is a single statement:

```sql
-- BEFORE step 1, in the same session:
CREATE TABLE IF NOT EXISTS los_sysprop_preimage_20260910 AS
  SELECT id, syskey, sysvalue, groupname, client_id, workstation FROM los_sysprop;

-- to roll back:
UPDATE los_sysprop s SET sysvalue = p.sysvalue, groupname = p.groupname, modified = now()
  FROM los_sysprop_preimage_20260910 p
 WHERE p.id = s.id AND s.sysvalue IS DISTINCT FROM p.sysvalue;
```

Rows *created* by step 1 have no pre-image row; delete them by `syskey` if you need a true revert.
Restart the pods afterwards, or wait out the cache TTL.

---

## 7. Open findings from the 2026-09-10 live audit

Two live misconfigurations, both the same root cause as §4.3. Neither is caused by this runbook;
both are fixed by it.

**Finding A — Hydra PRD has three OMS callbacks pointing at a UAT host.** In `wh01_hydra_v2` on
`:25061`, 14 of 17 `WEBS*` URLs are on `api-oms.sbo.li`; these three are not:

| Key | Current value on PRD |
|---|---|
| `WEBSERVICE_ORDER_BATCH_PALLETIZED` | `https://api-oms-uat.siteboss.net/services/call/palletized` |
| `WEBSERVICE_ORDER_BATCH_LOADED_TO_TRUCK` | `https://api-oms-uat.siteboss.net/services/call/loadedToTruck` |
| `WEBSERVICE_ORDER_BATCH_REVERSAL_COMPLETED` | `https://api-oms-uat.siteboss.net/services/call/batchReversalCompleted` |

All three are keys the v2 base dump seeds with the `CHANGE-ME-FOR-NEW-CLIENT` placeholder — they
arrived after Hydra's original host rewrite, so the rewrite never touched them. **Production WMS is
configured to POST palletized, loaded-to-truck and batch-reversal notifications to a UAT OMS.**
Needs Nam's call on the correct target before anyone edits PRD.

**Finding B — `wsl-wineco-uat` priority URL points at a non-UAT host, and the gate is now ON.**
Introduced by the 2026-09-10 UAT run of the draft script (Nam), which is the evidence behind §4.3.
`WEBSERVICE_ORDER_BATCH_UPDATE_PRIORITY` = `https://api-oms.wineco.sbo.li/services/call/updateBatchPriority`
while its 18 siblings are on `api-oms.uat.sbo.li`. `V2.2.22` derived it after the host rewrite had
run. `..._ACTIVATED` was set to `true` at 12:31 UTC on 2026-09-10, so UAT is now enabled to send
priority changes to that host. Outbox is currently empty — no messages lost yet. Fix with §4.2.

**Also observed:** `wsl-wineco-uat`'s `WEBSERVICE_ORDER_BATCH_UPDATE_PICKING_DATE_ACTIVATED` has
`groupname = 'Operation Options'` instead of `'Backend'` — the draft script created the row before
`V2.2.24` landed. Cosmetic (wrong admin tab), permanent until corrected, and the reason for §1.1
change 3.

### 7.1 UAT remediation — the draft script's 2026-09-10 run

The draft was run on **three of four** UAT tenants on 2026-09-10 (`wh01_om1_v2` 12:31 UTC,
`wh01_shipitez_v2` 13:07, `wh01_hydra_v2` 13:18). `wh02_shipitez_v2` was **not** run and is the clean
control — useful for A/B while the items below are open.

Three things that run left behind, and the exact fix for each:

```sql
-- (a) Both §2 hold keys were set to 'true' on those three tenants.
--     TRANSFER_DESTINATION_ELIGIBILITY_ENABLED is now ENFORCING with no shadow
--     measurement taken (§2.1). OUTBOX_REJECT_ON_ERROR_STATUS_ACTIVATED is inert
--     today but becomes live enforcement on a future deploy.
--     Nam's call: revert to shadow, or accept enforcement and stop counting.
UPDATE los_sysprop SET sysvalue = 'false', modified = now()
 WHERE syskey IN ('TRANSFER_DESTINATION_ELIGIBILITY_ENABLED',
                  'OUTBOX_REJECT_ON_ERROR_STATUS_ACTIVATED')
   AND client_id = 0 AND workstation = 'DEFAULT'
   AND sysvalue <> 'false';

-- (b) wh01_om1_v2 only — priority URL still on the pre-cutover host (§4.2).
UPDATE los_sysprop
   SET sysvalue = replace(sysvalue, 'https://api-oms.wineco.sbo.li/', 'https://api-oms.uat.sbo.li/'),
       modified = now()
 WHERE syskey LIKE 'WEBS%';

-- (c) wh01_om1_v2 only — misfiled groupname.
UPDATE los_sysprop SET groupname = 'Backend', modified = now()
 WHERE syskey = 'WEBSERVICE_ORDER_BATCH_UPDATE_PICKING_DATE_ACTIVATED'
   AND groupname <> 'Backend';
```

Restart the pods afterwards, or wait out the cache TTL (§0.3). Then run §5.

---

## 8. Reference

Full per-key detail — what each flag switches, its read semantics, per-tenant live values — is in
[`wms2-sysprop-catalog.md`](../../../3-Resources/data-dictionary/wms2-sysprop-catalog.md) §11.

Environment hosts as at 2026-09-10:

| Env | Port | OMS API host | Tenant DBs |
|---|---|---|---|
| PRD | 25061 | `api-oms.sbo.li` | `wh01_hydra_v2` (hydra/nywh — the only v2 PRD tenant) |
| UAT | 25062 | `api-oms.uat.sbo.li` | `wh01_om1_v2`, `wh01_hydra_v2`, `wh01_shipitez_v2`, `wh02_shipitez_v2` |
| DEV | 25060 | `api-oms.dev.sbo.li` | `dev_wh01_om1` |
