---
title: "Runbook: Apply pending tenant Flyway scripts across UAT"
type: runbook
status: active
version: "wms2-api release branch"
scope: wms2-api v2 / UAT
owner: nam.park@siteboss.net
created: 2026-07-27
updated: 2026-07-27
last_verified: 2026-07-27
verified_by: nam.park@siteboss.net
alert: "UAT deploy prerequisite — schema behind release branch; 500s on replenishment monitor / lock report; 'column does not exist' after deploy"
severity: SEV3
escalation: "WMS backend owner before any --apply on a tenant that reports NEEDS-BASELINE"
related:
  - "[[wms2-tenant-routing-datasource-topology]]"
  - "[[wms2-landlord-vs-tenant-entity-map]]"
tags:
  - runbook
  - flyway
  - uat
  - multi-tenant
---

# Runbook: Apply pending tenant Flyway scripts across UAT

**Alert:** UAT deploy prerequisite | **Severity:** SEV3
**Scope:** every tenant DB in UAT | **Version:** wms2-api `release` branch
**Owner:** nam.park@siteboss.net | **Last verified:** 2026-07-27

> Run this **before** every UAT deploy of `wms2-api`. UAT runs the `release` branch, so
> the migration set in `db/migration/` on `release` is the target every tenant DB must reach.

---

## 1. When to Use This Runbook

- Before deploying a new `wms2-api:rc-*` image to UAT.
- After a new client DB is onboarded to UAT (it will not be in any hard-coded list — this
  procedure discovers it from the landlord).
- When a tenant reports a 500 whose cause is a missing column/view the entity expects.

**Do NOT use this runbook for:**
- The **landlord** schema. It is not Flyway-managed — see §7.
- Production. Same shape, different credentials and change control.
- A brand-new DB being provisioned from scratch — use `provision-fresh-v2-db.sh` instead.

---

## 2. Severity & Impact

| Aspect | Detail |
|---|---|
| User impact | Missing view/column → HTTP 500 on the affected screen. `ddl-auto=none` in prod profile, so the app **starts fine and fails at request time** — no startup crash to alert you. |
| Blast radius | Per tenant. One stale DB breaks only that warehouse. |
| Paging event? | No — planned pre-deploy step. |
| Reversibility | Views are `CREATE OR REPLACE` (reversible). `ALTER TABLE ADD COLUMN` is forward-only. |

---

## 3. Key Facts (read once)

- **The app does not run Flyway at runtime.** Migrations are an operator step. Nothing
  self-heals on deploy.
- **Two migration sets exist. Only one is in play here:**
  - `db/migration/` — `V2.2.x`, the live set. **This runbook applies these.**
  - `db/v1-to-v2-onboarding/schema/` — `V1.0.01`→`V2.1.17`, historical. **Never replay.**
    Already baked into `V2.2.00__base_v2_schema.sql`.
- **A v1→v2 migrated tenant lands at the `V2.2.00` watermark** and continues on `V2.2.01+`.
- **Tenant credentials live in the landlord** (`tenant_db_configuration.db_password`, plaintext),
  so discovery is fully automatable. Treat that table as a secret store.
- **`db_url` in the landlord is the *application's* view** (e.g. `uat.sbo.li:25060`). From a
  workstation you reach the same server through an SSH tunnel (e.g. `localhost:25062`).
  The host/port must be rewritten — the driver script does this via `--tenant-host/--tenant-port`.

---

## 4. Preconditions

```bash
flyway --version        # Flyway CLI on PATH (verified against 12.11.0)
psql --version
git -C <wms2-api> log -1 --oneline    # must be on release, up to date
```

```bash
cd <wms2-api>
git fetch origin release --tags
git checkout release && git pull
git tag --points-at HEAD    # e.g. v0.0.8 → matches image rc-0.0.8
```

Confirm the tag matches the image you are about to deploy. UAT images are tagged
`wms2-api:rc-<version>` where `<version>` is the semver tag on `release` HEAD with `v` stripped
(`.github/workflows/docker-image-uat.yml`). A mismatch means you are migrating to the wrong target.

Open the UAT tunnel (landlord and all tenants are reachable on the same host:port in UAT).

---

## 5. Standard Path — discover, report, apply

The driver script lives at
[`9-System/scripts/uat-apply-pending-tenant-flyway.sh`](../../9-System/scripts/uat-apply-pending-tenant-flyway.sh).

### 5.1 Report first (read-only, always safe)

```bash
export PGPASSWORD_LANDLORD='<wms_landlord password>'

sbdocs/9-System/scripts/uat-apply-pending-tenant-flyway.sh \
  --repo /path/to/wms2-api \
  --status
```

Defaults target UAT: landlord `localhost:25062/landlord`, tenants rewritten to `localhost:25062`.
Run from inside the environment? Add `--no-tenant-override` to use `db_url` verbatim.

**Exit codes:** `0` all current · `2` pending exist · `3` a tenant needs baselining · `1` error.

Per tenant it prints one of:

| State | Meaning | Action |
|---|---|---|
| `at X — no pending migrations` | current | none |
| `at X — N pending [list]` | behind | §5.2 |
| `no flyway_schema_history — NEEDS-BASELINE` | never stamped | §6 (**do not** `--apply`) |
| `validate FAILED (checksum drift)` | an applied script was edited | §8.1 |
| `N failed row(s)` | prior migrate died mid-run | §8.2 |

### 5.2 Apply

```bash
sbdocs/9-System/scripts/uat-apply-pending-tenant-flyway.sh \
  --repo /path/to/wms2-api \
  --apply
```

`--apply` only touches tenants that **already have** a history table. Tenants needing a baseline
are always skipped — that is a deliberate human decision (§6).

Scope to one tenant while investigating:

```bash
... --warehouse nywh --status
```

By default rows with `active = false` are skipped. Include them with `--include-inactive` —
worth doing periodically so a deactivated client is not stale when it is switched back on.

### 5.3 Verify

Re-run `--status`. Expect `all tenants at <highest>` and exit `0`.

---

## 6. Baseline Path — a tenant with no `flyway_schema_history`

A DB that got its schema via the psql onboarding pipeline has the right schema but no history
table, so Flyway sees an empty database and would try to replay `V2.2.00` (the full base dump)
onto a populated schema.

> **Why this is not automated.** `V2.2.03` is a bare `ALTER TABLE ... ADD COLUMN` with **no
> `IF NOT EXISTS`**. Stamp too low and `migrate` re-runs it and fails; stamp too high and a
> migration that was never applied is silently marked done. `V2.2.01`, `V2.2.02` (`CREATE OR
> REPLACE VIEW`) and `V2.2.04` (`INSERT ... WHERE NOT EXISTS`) are idempotent — `V2.2.03` is
> the one that makes a wrong guess expensive. Determine the watermark by inspection, per DB.

### 6.1 Probe the true watermark

Run against the tenant. Each row answers "is this migration's effect already present?"

```sql
SELECT 'V2.2.01', (count(*) FILTER (WHERE attname='section_name')>0
              AND count(*) FILTER (WHERE attname='ro_id')>0)::text
  FROM pg_attribute
 WHERE attrelid='public.replenishment_monitor_view'::regclass AND attnum>0 AND NOT attisdropped
UNION ALL
SELECT 'V2.2.02', (EXISTS(SELECT 1 FROM pg_views WHERE viewname='lock_overview_all_view')
              AND pg_get_viewdef('public.lock_overview_dto_view'::regclass,true) LIKE '%405%')::text
UNION ALL
SELECT 'V2.2.03', (count(*)=4)::text FROM information_schema.columns
 WHERE table_name='replenishorder' AND column_name LIKE 'moved\_%'
UNION ALL
SELECT 'V2.2.04', (count(*)=2)::text FROM los_sysprop
 WHERE syskey IN ('TRANSFER_LANE_PARTIAL_DEPLETION_ACTIVATED',
                  'REPLENISH_EXCLUDE_STAGING_TRANSFER_LANES_ACTIVATED');
```

Also confirm the DB really is a converted v2 tenant (expect `flag-based YES`):

```sql
SELECT CASE WHEN pg_get_viewdef('public.replenishment_monitor_view'::regclass,true)
              LIKE '%useforreplenish%' THEN 'flag-based YES' ELSE 'NO — investigate' END;
```

**Watermark = the highest version whose probe is `true`, with no `false` below it.**
All four `false` → watermark is `2.2.00`. A gap (e.g. `2.2.01 false`, `2.2.03 true`) is not a
clean watermark — stop and escalate.

> **Add a probe row whenever a new `V2.2.x` lands.** This table is the one part of the procedure
> that does not update itself.

### 6.2 Stamp, then migrate

```bash
PGPASSWORD_OWNER='<tenant password>' \
  <wms2-api>/src/main/resources/db/backfill-flyway-history.sh \
    --host localhost --port 25062 --dbname <tenant_db> --owner <tenant_user> \
    --up-to <watermark> --dry-run        # inspect first
```

Drop `--dry-run` to apply. Then re-run §5.1 — the tenant now reports as `pending` and §5.2 finishes it.

Notes:
- The script **refuses** if a history table already exists (use `--drop-existing` only to rebuild
  a known-bad one).
- Stamping `2.2.00` asserts the base-dump content is present without having literally run that
  file. That is the intended use for onboarded tenants.
- **Ignore the script's `--validate` verdict when anything is still pending.** It reports
  `[FATAL] checksums/scripts do not line up`, but Flyway's real message is
  `Detected resolved migration not applied to database` — a *pending* state, not drift.
  Confirm checksums separately:
  ```bash
  flyway -url=... -user=... -password=... \
    -locations=filesystem:<repo>/src/main/resources/db/migration \
    -ignoreMigrationPatterns='*:pending' validate
  ```

---

## 7. Landlord Scripts — NOT covered by this runbook

`db/landlord/L00x__*.sql` is **not Flyway-managed** and the landlord persistence unit runs
`ddl-auto=none`. Nothing applies these automatically — not the app, not §5.

They are a **deploy gate**: `L001__add_active_flag.sql` (SBDEV-2727) adds `active NOT NULL
DEFAULT true` to `tenant_discovery` and `tenant_db_configuration`. Deploying a JAR that reads
`active` against a landlord without the column loads an **empty tenant config cache and rejects
every tenant** — fail-silent-open, no crash to alert on.

Check before each deploy:

```sql
SELECT table_name, column_name, is_nullable, column_default
  FROM information_schema.columns
 WHERE table_name IN ('tenant_discovery','tenant_db_configuration') AND column_name='active';
```

Two rows, `NOT NULL`, default `true` → satisfied. Apply manually if absent:

```bash
psql -h localhost -p 25062 -U wms_landlord -d landlord \
  -v ON_ERROR_STOP=1 -f <wms2-api>/src/main/resources/db/landlord/L001__add_active_flag.sql
```

Idempotent (`ADD COLUMN IF NOT EXISTS`), backfills existing rows to active, safe to run early.

**Never flip `active` in only one table** — partial flips split-brain: discovery-only ⇒ new logins
404 while existing sessions keep routing; db-config-only ⇒ API blocked but the login page still
resolves. Flip both in one transaction (see the script's header for the exact statements).

> The UAT landlord DB is named **`landlord`** — there is no `landlord_uat`.

---

## 8. Failure Modes

### 8.1 `validate FAILED — checksum drift`

An already-applied migration file was edited. **Do not migrate.** Either restore the file to the
committed version (correct fix — never edit an applied migration; add a new one), or, if the edit
is intentional and the DB already reflects it, realign:

```bash
flyway -url=... -user=... -password=... -locations=filesystem:<migration_dir> repair
```

The driver script refuses to migrate a tenant in this state and exits non-zero.

### 8.2 `N failed row(s) in flyway_schema_history`

A previous `migrate` died mid-run; that tenant is **partially migrated**. Inspect, fix the
underlying cause, then `flyway repair` to clear the failed row, then re-run §5.2.

```sql
SELECT installed_rank, version, script, success, installed_on
  FROM flyway_schema_history WHERE NOT success;
```

### 8.3 `migrate` fails partway across the fleet

Migrations are per-tenant and independent — already-migrated tenants are unaffected. Fix the
failing tenant and re-run; the script skips tenants already current.

### 8.4 Seed migration fails on a duplicate key

Seed migrations allocate IDs from `nextval('seqentities')`, which all entities share. On migrated
DBs the sequence can lag behind live IDs. Check before escalating:

```sql
SELECT (SELECT last_value FROM public.seqentities) AS seq,
       (SELECT max(id) FROM los_sysprop)           AS max_sysprop_id;
```

`seq > max_sysprop_id` → allocating into free space, not the cause. If the sequence is *below*
the max, it is marching through occupied ID space — escalate; do not blindly bump it.

### 8.5 Timestamps in `flyway_schema_history` look out of order

Cosmetic. Backfilled rows are stamped with DB-side `now()` (UTC); rows written by the Flyway CLI
use JVM-local time. Flyway orders by `installed_rank`, so `validate` is unaffected. Do not read
`installed_on` as a timeline on a DB that was ever backfilled.

---

## 9. Post-Run Checklist

- [ ] `--status` reports `all tenants at <highest>`, exit `0`
- [ ] Landlord `active` column check (§7) passes
- [ ] Release-branch tag matches the image tag being deployed
- [ ] Any new client DB discovered this run is recorded in the deploy notes
- [ ] If a new `V2.2.x` shipped, the §6.1 probe table has a row for it
- [ ] Bump `last_verified` in this file's frontmatter

---

## 10. Verification Notes

Procedure and script verified 2026-07-27 against UAT (4 tenants: `wh01_hydra_v2`,
`wh01_om1_v2`, `wh01_shipitez_v2`, `wh02_shipitez_v2`, all reaching `2.2.04`) and against a
disposable Postgres 16 fixture that exercised every branch: pending→applied (DDL confirmed
landed), already-current, no-history→skipped, inactive-excluded, and checksum-drift→refused.

Known limits:
- The §6.1 probe table is **manual** — it needs a new row per future `V2.2.x`.
- `--apply` deliberately cannot baseline. That is a design choice (§6), not a gap.
- Script assumes one Postgres reachable host:port for all UAT tenants (true today: all four
  share `uat.sbo.li:25060`). Split hosts would need per-tenant overrides.

---

## 11. Related

- [`uat-apply-pending-tenant-flyway.sh`](../../9-System/scripts/uat-apply-pending-tenant-flyway.sh) — driver
- `<wms2-api>/src/main/resources/db/migration/README.md` — migration-set rules, base-dump refresh
- `<wms2-api>/src/main/resources/db/v1-to-v2-onboarding/README.md` — onboarding watermark
- `<wms2-api>/src/main/resources/db/backfill-flyway-history.sh` — baseline tool
- [[wms2-tenant-routing-datasource-topology]] — how the landlord drives tenant routing
