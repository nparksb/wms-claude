---
title: "Location-level default Min / Hysteresis / Max for Fixed Location Assignments"
ticket: "SBDEV-3128"
ticket_url: "https://app.clickup.com/t/868kxn4b5"
type: "feature"
priority: "high"
status: "archived — on dev: #601 4643acf5 (P1), #193 f49105de (P2, SBDEV-3991); dev-tested 2026-11-02"
project: ["wms2"]
version: "v2"
requester: "WineCo ST#1154 / ST#1505 (Michelle Cervone; Adam Petersen)"
created: "2026-11-01"
updated: "2026-11-02"
tier: "T3"
db_verified: "true — DEV dev_wh01_om1 2026-11-01; WineCo PRD wsl-wineco-prd 2026-11-02 (analysis addendum); other 5 PRD tenants owed at rollout"
revision: "r4"
base_commit: "1b421d08 (wms2-api origin/develop; re-checked at 207db277 — the 2 newer commits touch only request-header config) · 912c786 (wms2-web-ui origin/develop)"
repos: ["v2/wms2-api (P1)", "v2/wms2-web-ui (P2)"]
related:
  - "[[SBDEV-3128-evidence/analysis]]"
  - "[[SBDEV-3128-evidence/reviews/r1-architect]]"
  - "[[SBDEV-3128-evidence/reviews/r1-critic]]"
  - "[[SBDEV-3017]]"
  - "[[SBDEV-3418]]"
  - "[[SBDEV-3952-flowbin-report-per-flowbin-replen]]"
  - "[[wms2-replenishment-design]]"
  - "[[wms2-sysprop-catalog]]"
  - "[[wms2-caching-strategy]]"
tags:
  - plan
---

# Location-level default Min / Hysteresis / Max for Fixed Location Assignments

**Ticket:** [SBDEV-3128](https://app.clickup.com/t/868kxn4b5) · `in development` · priority high · **Tier T3**: a Flyway migration with a data backfill on every tenant, plus a new write path that crosses screens.
**Repos:** `v2/wms2-api` (P1, one PR), then `v2/wms2-web-ui` (P2, one PR). Branch `feature/SBDEV-3128-location-default-fla-bounds` in both, cut from a freshly fetched `origin/develop`. PRs go into `develop` only.
**Evidence base:** `SBDEV-3128-evidence/analysis.md` (file:line references and DEV counts) and the r1 reviews. Code is cited at `1b421d08`. Every r2 citation was re-read on 2026-11-01 with `git show origin/develop:<path>`.

## RALPLAN-DR summary

**Mode:** DELIBERATE. The change adds a migration and a backfill, and a new write path into replenishment inputs.

**Principles**
1. **No reader's bound expression changes.** Replenishment math reads `fix_location_assignment.{lower,middle,upper}bound` at 15 sites; none of those expressions change (R2 only gains additive columns).
2. **One invariant for every writer (I-1).** *If an FLA is inherited, its triple equals the effective default (location default, else sysprop) as of the last write.* Create, move, reset, defaults edit and clear all resolve through one helper. Sysprop edits are the documented exception, and the UI shows the drift they cause (M-2).
3. **Fail safe on ambiguity.** Unknown provenance counts as overridden (`DEFAULT false`).
4. **Gate the new route explicitly.** `LocationController` is not in `FunctionGuardInterceptor.GUARDED`.
5. **A failed migration degrades only this feature (D8 + D9).** The four new columns are unmapped, so a tenant stuck at 2.2.44 keeps every `Location`/`FixLocationAssignment` entity read. Every native path that would touch them, **except the two admin lists (`getDetailView`)**, first runs a non-aborting `information_schema` probe (D9). When the probe is false, FLA create, `adjust*`, move and the location-details popup take the pre-SBDEV-3128 data path: no new column is read or written. The only differences from before are that `adjust*` is now `@Transactional` (trigger after commit) and each guarded call issues one extra SELECT, the probe; the defaults edit, clear and reset return `{errors}` "unavailable until V2.2.45 applies"; and **only the Storage Locations and Fixed Locations lists raise 42703** (§3.2 enumerates every native statement).

**Decision drivers (top 3):** (1) zero change to the 8 native-SQL and 7 Java replenishment readers; (2) the location keeps its capacity when an FLA is deleted and re-created (5 auto-create callers); (3) the operator can see inheritance and reverse it (ACs e, c, d).

**Options:** A (write-through) with G (unmapped columns) is chosen (D1 + D8). The alternatives are A with mapped columns, A with `insertable/updatable=false`, B read-time COALESCE, C copy-at-creation, D nullable FLA bounds and E a side table. See §9.

## 0. Affected sites

**Method:** `git grep` G1–G8 on `origin/develop` *(analysis §0.1)*, with G1/G4 re-run on 2026-11-01. The Architect's independent writer greps G-a to G-e (r1 review (g)) agree.
**Blind spots:** method references (found by hand: `MobileReplenishService:451`), reflection, raw `EntityManager.merge`, SQL outside `src/main`, DBA hand edits, and dirty-checked managed-entity writes (invisible to a `save(` grep; under D8 nothing in this feature makes a `Location` dirty, so this one no longer bears on the design).

### 0.1 Readers — all UNCHANGED (write-through keeps the stored triple correct)

| # | Site | Quoted | Phase |
|---|---|---|---|
| R1 | `FixLocationAssignmentRepository:173` `REFILL_ELIGIBILITY_FROM_WHERE` | `" AND stockunit.amount < fla.lowerbound "` | — |
| R2 | `FixLocationAssignmentRepository:217-233` `getDetailView` (native) | `"fla.lowerbound as minAmount, "` … `"order by l.name"` | P1 (+4 columns) |
| R3 | `ReplenishorderRepository:243,249` | `"AND stockUnit.amount >= fixAssignment.upperbound "` | — |
| R4 | `ReplenishorderRepository:303,326` | `"AND fixAssignment.upperBound > su.amount "` | — |
| R5 | `ReplenishmentMonitorViewRepository:104,110` | `"f.upperbound AS fix_assignment_upperbound "` | — |
| R6 | `V2.2.43…:45-47` → `ViewDtoService:1432-1434`, `ReportService:263-265` | `COALESCE(round(f.lowerbound), (0)::numeric) AS lower_bound` | — |
| R7–R13 | `ReplenishOrderJobService:183,185`; `ReplenishmentOrderMaintenanceService:1002-1008`; `ReplenishGeneratorService:99,123`; `ViewDtoService:805-807,1382-1387`; `MobileReplenishService:447-451,727` | entity getters `getUpperbound()` / `getMiddlebound()` | — (entity unchanged, so no 42703 on a failed tenant) |
| R14 | `FixLocationAssignmentRepository:61,200` | `select * from fix_location_assignment f …` / `SELECT DISTINCT fla.*` | — (Hibernate ignores the extra unmapped column; the statement names no new column) |
| R15 | v1-to-v2 onboarding `V1.0.02`, `V1.2.04`, `V1.2.99*` | `coalesce(round(f.lowerbound), 0)` | — (not on the boot or IT path) |

Sysprop-default readers:
- S1 `FixLocationAssignmentService:86-88` is the seeding point (P1).
- S2 `ReplenishmentOrderMaintenanceService:1006-1008` and S3 `ReplenishOrderJob:759` are unchanged.
- S4 `ViewDtoService:708` is the D-1 fold-in (AC-18).

### 0.2 Writers / FLA lifecycle

| # | Site | Quoted (re-read 2026-11-01) | Change | Phase |
|---|---|---|---|---|
| W1 | `FixLocationAssignmentService:83-107` create | `BigDecimal lowerBound = BigDecimal.valueOf(parseSyspropLong(…LOWER_BOUND_KEY, …VALUE));` | lock the location, read its default natively, seed from it; native `markInherited` after the insert | P1 |
| W1c | 5 callers (§3.6 table) | `fixLocationAssignmentService.createFixedLocationAssignment(destinationLocation, …)` | none. All are transactional, and all lock the destination **after** create returns, inside `transferStockToUnitLoad` (`StockunitBusinessService:349-350`) | — |
| W2 | `:109-179` `move()` | `fixedLocationAssignment.setAssignedlocationId(destination.getId());` (`:167`) | if the native flag read is true, re-seed the triple from the destination's effective default before the `:168` save | P1 |
| W3 | `:181-233` `adjust{Lower,Middle,Upper}Bound` | `fixedLocationAssignment.setLowerbound(BigDecimal.valueOf(newAmount));` | + `@Transactional`; version-checked native `markOverridden` before the save (skipped when the D9 probe is false) | P1 |
| W4/W5 | Controller `/update` (Map) and `/set{Upper,Middle,Lower}Bound` | `fixLocationAssignmentService.adjustUpperBound(id, value);` | inherit W3 | — |
| W6/W7 | `delete()` `:235-287`, `changeActive` `:289-299` | — | none. The location default survives the delete, which is the point of the feature | — |
| W8 | `demo-datasets/meridian/fixtures.sql:86-88` | INSERT with an explicit column list | none (`DEFAULT false`) | — |
| W9 | **NEW** `updateLocationBoundDefaults`, `resetBoundsToLocationDefault` | — | §3.3 | P1 |

### 0.3 Location surfaces

| # | Site | Effect | Phase |
|---|---|---|---|
| L2 | `LocationController:64-82` `/create` → `createLocationFromRequest(@RequestBody Location)` | none. `Location` has no default fields (D8), so Jackson has nothing to bind and mass assignment cannot happen | — |
| L3 | `LocationService:186-211` `updateLocation` (copies 13 named fields) | none. An entity save never writes unmapped columns | — |
| L4 | `LocationService:244+` `getLocationDetails` (entity-based) | + 3 keys from the native `findDefaultBoundsById`, only when the D9 probe is true (keys omitted otherwise) | P1 |
| L5 | `LocationRepository:278-291` `getDetailView` (native) → **`ViewDtoService.getLocationView:874-901`** (copies by name into a HashMap) | + 3 columns **and** + 3 `dto.put` (Critic M4) | P1 |
| L9 | SDR `GET /api/location/**` | none (unmapped) | — |
| L10 | **NEW** `LocationRepository` methods (§3.2) | `@RestResource(exported = false)` on each; the repository is SDR-exported | P1 |

### 0.4 UI (wms2-web-ui @ 912c786)

| # | File | Change | Phase |
|---|---|---|---|
| U1 | `components/masterData/location/fixedLocations/fixedLocation.vue` (headers `:237-239`, menu `:110-125`, export `:159-160,379`) | Bounds chip column, default line in details, reset menu item, export column | P2 |
| U2 | `fixedLocations/updateBound.vue:63-70` | note "Saving marks this assignment Overridden" | P2 |
| U2b | `fixedLocations/moveFixedLocation.vue` | note for Overridden rows (L-6) | P2 |
| U3 | `store/masterData/fixedLocation.js:55,135-195` | + `resetBoundsToDefault` | P2 |
| U4 | `components/masterData/location/storageLocations/storageLocation.vue:92,223-231` | 3 default columns; flowbin "Set…" item; non-flowbin "Clear…" item (D7) | P2 |
| U5 | `store/masterData/storageLocation.js:115-140` | add `updateBoundDefaults`. The dead, verb-inverted actions are left alone (D-6) | P2 |

## 1. Problem Statement

WineCo (ST#1154, ST#1505) says the 53-B06 roller lanes physically hold **48 bottles**, but their FLAs carried **36/60/84** (Min/Hysteresis/Max), so replenishment over-pulls. Every FLA is seeded from the sysprop triple (`FixLocationAssignmentService:86-88`), and its tuning lives on the FLA, so the tuning dies with the FLA.

On DEV `dev_wh01_om1` (2026-11-01): **1307 of 1344** FLAs sit at 36/60/84; the other 37 fall into 7 triples (28×12/24/36, 3×84/108/168, 2×1/1/6, 4 singletons). FLA to location is 1:1 (UNIQUE on `assignedlocation_id` and on `itemdata_id`). 5 auto-create sites re-seed from sysprops after a delete or a move. 53-B06 (id 3223189, flowbin) has no FLA today.

**Ticket ACs:** (a) storage locations can optionally define defaults · (b) FLAs inherit them · (c) users can override per FLA · (d) an explicit override wins · (e) the UI shows inherited vs overridden · (f) SKU-specific FLA behavior stays · (g) validation is consistent with current rules · (h) existing assignments are handled explicitly.

## 2. Current Architecture

- **Create** (W1) reads the sysprop triple via `parseSyspropLong` → `getSysvalue` → `SyspropRepository:30` (`… where syskey = :syskey and workstation = 'DEFAULT' order by client_id LIMIT 1`): absent → `Long.parseLong(defaultValue)`; present → `Long.parseLong(value)`, no trim (`:301-307`).
- **Edit** (W3/W5): one bound per request; `lower ≤ middle < upper` on `double`, no non-negativity check; errors are HTTP 200 `{errors}`; `adjust*` carry **no `@Transactional`**.
- **Move** (W2) requires a flowbin (`:121`, `getSltname().equals(STORAGE_LOCATION_TYPE_BOX_RESTRICTION_FLOWBIN)`, `"flowbin"` `WmsConstants:969`) and locks the destination at `:163` via `transferUnitLoadToLocation(…, false, …)` (`UnitloadBusinessService:243-246`).
- **No storage-location edit is reachable from the UI** (U4 commented out; U5 dead).
- **Authz:** `FixLocationAssignmentController` is class-level `@RequiresFunction(WEB_UI_VIEW_FIXED_ASSIGNMENT)`; `LocationController` is method-level only (`grep -c 'LocationController.class' FunctionGuardInterceptor.java` = 0). Grants resolve user → group → role → function (`RestConfiguration:111`); the direct `mywms_user_mywms_role` is 0 rows on DEV ("empty on every tenant checked 2026-08-21", `UserController:531`).
- **Locking:** `LockReads.forUpdate` (`:20-47`) locks a managed row with a scalar JPQL `select e.id … PESSIMISTIC_WRITE`, which renders `FOR NO KEY UPDATE` on PG (measured, `StockunitSkipLockedIT`) and `FOR UPDATE` on H2. `LocationRepository:127-129`: a locking query outside a transaction "throws TransactionRequiredException".
- **Unmapped-column precedent:** `V2.2.40:9-13`: "A timeout fails this migration on that tenant only; dispatch keeps working there, because OutboxMessage does not map the column (native SQL only)." followed by `SET LOCAL lock_timeout = '5s';`.
- **Flyway:** head `V2.2.44`; `StartupFlywayMigrator` uses one transaction per migration, and one tenant's failure never blocks the others (`:53`); its connection is outside `tenantTransactionManager`'s `lock_timeout` (V2.2.26 header).
- **Test schemas:** H2 builds tables from entities (`application-integration.properties:38,40` `create-drop`; `:51` Flyway off). PG ITs run real Flyway (`AppPostgresDBSetupExtension:93-99`) with `ddl-auto=validate`, which ignores unmapped columns.

### 2.1 DB evidence (DEV `dev_wh01_om1`, 2026-11-01, `wms-dev-probe` q.sh, SELECT only)

| Query | Result |
|---|---|
| `select count(*) from fix_location_assignment` | 1344 (all active) |
| `… where not (lowerbound <= middlebound and middlebound < upperbound)` | 0 |
| `… where lowerbound=36 and middlebound=60 and upperbound=84` | **1307** |
| `select count(*) triples, sum(n) from (select count(*) n … where not (36/60/84) group by 1,2,3)` | **7 triples / 37 FLAs** (28 + 3 + 2 + 4×1) |
| sysprops `FIX_LOCATION_ASSIGNMENT_DEFAULT_VALUE_%_BOUND` | 36 / 60 / 84 at `client_id=0`, `DEFAULT` |
| FLAs by location type | flowbin 2068 locations / 1344 FLAs; every other type 0 |
| `select version, success from flyway_schema_history where version in ('2.2.44','2.2.45')` | `2.2.44 \| t` only |
| `select count(*) from mywms_user_mywms_role` | 0 |
| M0 authz population (§7.4) | 44 / 44 / 0 |

PRD is unmeasured (MCP connection timeout). Prerequisites #5, #7 and #9 run there before the PRD rollout.

## 3. Design

### 3.1 Migration `V2.2.45__location_default_fla_bounds.sql`

```sql
-- SBDEV-3128: optional per-location default Min/Hysteresis/Max for fixed location assignments.
-- Plan: sbdocs/1-Projects/wms2/plan/SBDEV-3128-location-default-fla-bounds.md
--
-- WHAT. location gains a nullable default triple (all-or-none, CHECKed). fix_location_assignment gains
-- bounds_inherited; true = "this row's triple equals its location's effective default and follows it".
-- The bound columns are untouched; every replenishment reader keeps reading them.
--
-- UNMAPPED. Neither Location nor FixLocationAssignment maps these four columns; only native SQL reads or
-- writes them (V2.2.40 / OutboxMessage pattern). All four arrive in this one transaction, so the service
-- probes information_schema for bounds_inherited (a probe that cannot raise 42703) before touching any of
-- them, except in the two admin list queries. If this migration fails on a tenant: entity reads keep
-- working; FLA create, adjust, move and the location details popup read and write no new column (their
-- only differences from before SBDEV-3128: adjust is @Transactional, and each call runs the one extra
-- probe SELECT); the defaults edit, clear and reset return an error ("unavailable until V2.2.45
-- applies"); only the Storage Locations and Fixed Locations lists raise 42703.
--
-- lock_timeout: same pattern and value as V2.2.40. The three ALTERs (two on location, one on
-- fix_location_assignment) take ACCESS EXCLUSIVE, held until commit, and adding the CHECK also scans location.
-- The Flyway connection is outside tenantTransactionManager's lock_timeout (V2.2.26), so an unbounded wait would
-- queue every later reader of either table behind these ALTERs. SET LOCAL dies with this migration's transaction.
-- A deadlock against a live transaction that holds one of the two tables and requests the other is
-- possible; PostgreSQL aborts one side. If it aborts this migration, the outcome is the same as a timeout
-- (55P03): the script rolls back, no history row is written, the tenant stays on 2.2.44, and the next boot
-- retries.
--
-- BACKFILL follows parseSyspropLong -> SyspropRepository.findSysvalueBySyskey: workstation='DEFAULT',
-- client-blind, lowest client_id wins; an absent row, or a value that is not an optionally signed ASCII integer
-- of at most 18 digits, falls back to 36/60/84. That is narrower than Long.parseLong, which also accepts 19-digit
-- and non-ASCII digit values; FLAs seeded from such a value then classify OVERRIDDEN, the safe direction. The
-- regex guard also keeps a garbage value from failing the ::numeric cast (and with it this migration). FLAs
-- seeded under an older sysprop value classify as OVERRIDDEN (fail-safe).
-- No CHECK on the FLA bound columns: a failing CHECK freezes the tenant (V2.2.34 header).

SET LOCAL lock_timeout = '5s';

ALTER TABLE public.location
    ADD COLUMN IF NOT EXISTS default_lowerbound  numeric(17,4),
    ADD COLUMN IF NOT EXISTS default_middlebound numeric(17,4),
    ADD COLUMN IF NOT EXISTS default_upperbound  numeric(17,4);

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'ck_location_default_bounds'
                      AND conrelid = 'public.location'::regclass) THEN
        ALTER TABLE public.location ADD CONSTRAINT ck_location_default_bounds CHECK (
            (default_lowerbound IS NULL AND default_middlebound IS NULL AND default_upperbound IS NULL)
            OR (default_lowerbound  IS NOT NULL AND default_middlebound IS NOT NULL
                AND default_upperbound IS NOT NULL
                AND default_lowerbound >= 0
                AND default_lowerbound <= default_middlebound
                AND default_middlebound < default_upperbound));
    END IF;
END $$;

-- false = OVERRIDDEN = fail-safe for rows written by paths that never set it (old jar, raw SQL, fixtures).
ALTER TABLE public.fix_location_assignment
    ADD COLUMN IF NOT EXISTS bounds_inherited boolean NOT NULL DEFAULT false;

WITH d AS (
    SELECT
        COALESCE((SELECT CASE WHEN sysvalue ~ '^[+-]?[0-9]{1,18}$' THEN sysvalue::numeric END
                    FROM public.los_sysprop
                   WHERE syskey = 'FIX_LOCATION_ASSIGNMENT_DEFAULT_VALUE_LOWER_BOUND'
                     AND workstation = 'DEFAULT' ORDER BY client_id LIMIT 1), 36) AS lo,
        COALESCE((SELECT CASE WHEN sysvalue ~ '^[+-]?[0-9]{1,18}$' THEN sysvalue::numeric END
                    FROM public.los_sysprop
                   WHERE syskey = 'FIX_LOCATION_ASSIGNMENT_DEFAULT_VALUE_MIDDLE_BOUND'
                     AND workstation = 'DEFAULT' ORDER BY client_id LIMIT 1), 60) AS mi,
        COALESCE((SELECT CASE WHEN sysvalue ~ '^[+-]?[0-9]{1,18}$' THEN sysvalue::numeric END
                    FROM public.los_sysprop
                   WHERE syskey = 'FIX_LOCATION_ASSIGNMENT_DEFAULT_VALUE_UPPER_BOUND'
                     AND workstation = 'DEFAULT' ORDER BY client_id LIMIT 1), 84) AS up
)
UPDATE public.fix_location_assignment f
   SET bounds_inherited = true
  FROM d
 WHERE f.lowerbound = d.lo AND f.middlebound = d.mi AND f.upperbound = d.up
   AND f.bounds_inherited = false;
```

Notes:
- Syskey literals = `WmsConstants:1356-1361` (Architect (c) verified; AC-1 pins them).
- `5s` follows V2.2.40. D4 settled that a timeout is used, not its value, and nothing here argues for a longer one. Rollout happens in a low-traffic window (§8).
- The cost is metadata-only ADD COLUMNs (PG ≥ 11), a CHECK scan over 2,750 all-NULL rows, and about 1,307 FLA row updates.

### 3.2 Persistence — unmapped columns, native SQL only (D8)

**No entity change.** `Location.java` and `FixLocationAssignment.java` are untouched. All the new SQL lives in the two repositories, and every new method carries `@RestResource(exported = false)`. Every UPDATE is `@Modifying`.

| Repository method | SQL | Used by |
|---|---|---|
| `LocationRepository.lockById(id)` → `Optional<Long>` | JPQL `select l.id from Location l where l.id = :id` + `@Lock(PESSIMISTIC_WRITE)`: the `LockReads` scalar shape, no hand-written clause | create, move, reset, edit |
| **`LocationRepository.featureColumnsPresent()`** → `boolean` (D9) | native `select exists (select 1 from information_schema.columns where table_schema = current_schema() and table_name = 'fix_location_assignment' and column_name = 'bounds_inherited')` | every guarded path (§3.3) + `getLocationDetails` |
| `LocationRepository.findDefaultBoundsById(id)` → `Optional<LocationDefaultBoundsView>` | native `select default_lowerbound as minAmount, default_middlebound as hysteresis, default_upperbound as maxAmount from location where id = :id` | same + `getLocationDetails` |
| `LocationRepository.updateDefaultBounds(id, l, m, u)` → `int` | native `update location set default_lowerbound = :l, default_middlebound = :m, default_upperbound = :u where id = :id` (does not touch `version`) | edit |
| `LocationRepository.getDetailView` | + `l.default_lowerbound as defaultMinAmount, l.default_middlebound as defaultHysteresis, l.default_upperbound as defaultMaxAmount` | L5 |
| `FixLocationAssignmentRepository.findBoundsInheritedById(id)` → `Optional<Boolean>` | native `select bounds_inherited from fix_location_assignment where id = :id` | move |
| `…markInherited(id)` → `int` | `@Modifying(flushAutomatically = true)` native `update fix_location_assignment set bounds_inherited = true where id = :id` | create |
| `…markOverridden(id, version)` → `int` | `@Modifying(flushAutomatically = true)` native `… set bounds_inherited = false where id = :id and version = :version` | adjust* |
| `…resetBounds(id, locationId, l, m, u, now)` → `int` | native `… set lowerbound=:l, middlebound=:m, upperbound=:u, bounds_inherited = true, version = version + 1, modified = :now where id = :id and assignedlocation_id = :locationId` (L-1: a concurrent move makes it match 0 rows) | reset |
| `…writeThroughInherited(locationId, l, m, u, now)` → `int` | native `… set lowerbound=:l, middlebound=:m, upperbound=:u, version = version + 1, modified = :now where assignedlocation_id = :locationId and bounds_inherited` | edit |
| `…getDetailView` | + `fla.bounds_inherited as boundsInherited, l.default_lowerbound as locationDefaultMinAmount, l.default_middlebound as locationDefaultHysteresis, l.default_upperbound as locationDefaultMaxAmount` | R2 |

Why: **`version = version + 1`** on the two FLA triple writes keeps `@Version` loud (a concurrent `adjust*`/`move` that loaded the FLA earlier fails its save instead of silently reverting the write-through). **`:now`** is Java `LocalDateTime.now()`, the source `AuditingEntityListener` uses (`@EnableJpaAuditing` bare, `StartApplication:29`). **The `location` row's `version`/`modified` are deliberately untouched**: the defaults are not entity state, which is what makes D5 moot. **The predicated UPDATEs** (`and bounds_inherited`, `and version = :version`) settle the §3.6 races, because PG re-evaluates WHERE after a row-lock wait. **`flushAutomatically = true` is explicit intent, not load-bearing:** the FLA INSERT is deferred to flush (sequence ids), but Hibernate 6.6.39 already flushes before a native `executeUpdate` inside a transaction (`NativeQueryImpl.prepareForExecution` → `session.flush()` when there are no synchronized query spaces, FlushMode AUTO and JPA bootstrap; Critic r2 bytecode read, not run). The annotation keeps the ordering explicit and independent of FlushMode. What actually catches a mis-ordering is the guard: every flag write asserts `== 1`, else `IllegalStateException` (create) or `ObjectOptimisticLockingFailureException` (adjust, reset). **No `@Transactional` on any new repository method** (L-3): the transaction always comes from the service method, so the AC-5b mutant can see a missing one.

**D9 probe — placement and cost.** `featureColumnsPresent()` sits on `LocationRepository` because both `FixLocationAssignmentService` and `LocationService` already inject it. It runs **per call, with no cache**:
- it checks `bounds_inherited` only, because all four columns arrive in one transactional migration, so one present implies all;
- it uses `information_schema`, which never raises 42703, so it cannot abort the caller's transaction;
- **cost, measured on DEV** (`explain (analyze, buffers)`, 2026-11-01): 1.0 ms execution, 6 shared-buffer hits on the probe node, 11 ms planning on a cold statement. pgjdbc prepares server-side after its default `prepareThreshold` of 5, which should amortise the planning (default not re-measured here);
- **frequency:** FLA creates are rare (DEV `created` by month: 3 May, 3 Jun, 2 Aug; r1 §2.1), and `adjust*`, move, edit and reset run at operator speed. So about 1–12 ms on an already multi-statement putaway transaction is noise.

A cache was rejected. A memo of `true` would be safe, since columns never disappear, but it adds per-tenant in-JVM state to save milliseconds on rare calls. Not caching also means that once a stuck tenant migrates on a later boot, every replica sees it on the next call.

**H2:** Nam's exact query, run against H2 2.3.232 from `~/.m2` (`jdbc:h2:mem:t;MODE=PostgreSQL;DATABASE_TO_LOWER=TRUE`, the integration profile's flags at `:20,31`), returned `TRUE` for a present column, `FALSE` for an absent one, and `current_schema()` = `public`. The gate confirms the resolved H2 version with `mvn dependency:list | grep h2`.

`LocationDefaultBoundsView`, a new projection with 3 getters, sits next to `LocationDetailView`. `LocationDetailView` gains 3 getters, and `FixLocationAssignmentDetailView` gains 4.

### 3.3 Service (`FixLocationAssignmentService`)

**Home:** this service already injects `LocationRepository`, `LocationTypeRepository`, `SyspropService` and `ReplenishmentMaintenanceTrigger` (ctor `:50-80`). Putting the edit in `LocationService` would create an injection cycle.

```java
private record Bounds(BigDecimal lower, BigDecimal middle, BigDecimal upper) {}
private Bounds systemDefaultBounds();                         // parseSyspropLong x3, as today (NFE on garbage, unchanged)
private Bounds effectiveDefaultBounds(LocationDefaultBoundsView v);  // location triple if non-null, else systemDefaultBounds()
private Bounds lockAndResolveDefaultBounds(Long locationId);  // lockById(...).orElseThrow(EntityNotFound); findDefaultBoundsById; effective
private void requireFlowbin(Location location, String message) throws BusinessException;   // extracted from move() :121
```

| Method | Change |
|---|---|
| `createFixedLocationAssignment` (signature unchanged) | `boolean f = featureColumnsPresent()`. **If `f`:** `Bounds b = lockAndResolveDefaultBounds(storageLocation.getId())` replaces `:86-88`; unit load + FLA as today, seeded from `b`; `save`; then `markInherited(id) == 1`, else `IllegalStateException`. **If not `f`:** `b = systemDefaultBounds()`, today's data path (the only addition is the probe SELECT), with no `lockById`, no native read and no `markInherited`. |
| `move` (`@Transactional`, unchanged) | `:121` becomes `requireFlowbin(destination, "Can't move fix assignment. Destination is not a flowbin!")` (message unchanged). After `:167`: if `featureColumnsPresent() && findBoundsInheritedById(id).orElse(false)`, set the triple from `lockAndResolveDefaultBounds(destination.getId())` (re-entrant: `:163` already holds the destination). Save at `:168` as today. |
| `adjust{Lower,Middle,Upper}Bound` | + `@Transactional(value = "tenantTransactionManager", rollbackFor = {BusinessException.class, FacadeException.class})`, needed because a `@Modifying` query requires a transaction. After validation and before setting the bound, **only when `featureColumnsPresent()`**: `markOverridden(id, fla.getVersion()) == 1`, else throw `ObjectOptimisticLockingFailureException(FixLocationAssignment.class, id)`. Validation and messages are unchanged. Side effect: `requestForItem` now runs after commit, which is the trigger's documented transactional mode (`ReplenishmentMaintenanceTrigger:85-95`). |
| **NEW** `resetBoundsToLocationDefault(Long flaId)` `@Transactional(tenantTM, rollbackFor…)` | `requireFeatureColumns()` first. Then `fla = findById`, then `b = lockAndResolveDefaultBounds(fla.getAssignedlocationId())`, then `resetBounds(id, fla.getAssignedlocationId(), b, now) == 1`, else `ObjectOptimisticLockingFailureException` (moved or deleted concurrently, L-1), then `requestForItem(fla.getItemdataId())`. **Executor note (`@Version` safety): reset never saves or dirties the FLA entity.** The native write bumps `version`, so the managed copy is stale on purpose; any setter call on it would flush a stale-version UPDATE and fail. |
| **NEW** `updateLocationBoundDefaults(Long locationId, BigDecimal l, m, u)` `@Transactional(tenantTM, rollbackFor…)` → `LocationBoundDefaultsResult` | Steps below. **No `@CacheEvict`** (§3.5). |
| **NEW** private `requireFeatureColumns()` | `if (!locationRepository.featureColumnsPresent()) throw new BusinessException("Replenishment defaults are unavailable until database migration V2.2.45 applies on this tenant")`. Used by reset and by the defaults edit/clear (D9 decision below). |

**D9: edit, clear and reset on a tenant without the columns return `BusinessException`, not 42703.**
- **Why:** the probe already exists. The guard gives the operator the house-style `{errors}` (HTTP 200, `LocationController:66-81`) with an actionable message. Without the guard, the 42703 would surface differently per endpoint. On **reset**, `FixLocationAssignmentController` catches only `BusinessException` (`:83,107,130,162`), so the result is an HTTP 500. On the **edit/clear**, `LocationController`'s house idiom also catches `Exception` (`:76-78`), so the result is a 200 `{errors}` carrying the raw SQL message. The guard replaces both with one actionable message.
- **Cost:** one guard line per method and one unit assertion each.
- **Not guarded:** the two **lists** (`getDetailView`). Making them degrade would need a second query or a dynamic projection for a state that should last only until the next pod restart. Per Nam, they may fail; they are read-only, so the failure costs a screen, not data.

`updateLocationBoundDefaults` runs these steps in order (D6 + D7):
1. **Validate before any read.** All three null = clear; otherwise all three non-null, else `BusinessException("Min, Hysteresis and Max must all be set, or all be empty")`. When setting: `scale() ≤ 4` on each (L-7: `numeric(17,4)` rounding could turn `m < u` into `m = u` and trip the CHECK as a raw `DataIntegrityViolation`), `l ≥ 0`, `l ≤ m`, `m < u`, all via `compareTo`.
2. `requireFeatureColumns()` (D9), then `lockById(locationId).orElseThrow(EntityNotFoundException)`.
3. **Only when setting:** `requireFlowbin(locationRepository.findById(id)…, "Replenishment defaults can only be set on flowbin locations")`. **Clear is allowed on any location type (D7).**
4. `updateDefaultBounds(id, l, m, u)`.
5. `n = writeThroughInherited(id, effective(l, m, u), now)`, where the effective triple is `(l, m, u)`, or `systemDefaultBounds()` on clear. If `n == 1`, call `requestForItem(findByAssignedlocationId(id)…getItemdataId())`.
6. Return `LocationBoundDefaultsResult(id, minAmount, hysteresis, maxAmount, inheritedAssignmentsUpdated = n)`.

Inactive FLAs are written through too; overridden or absent FLAs are left alone. A write-through that hits an FLA whose replenishment order is in processing (state > PROCESSABLE) behaves **the same as `adjust*` today** (bounds change, post-commit maintenance runs): **accepted**. A sysprop that does not parse fails the write paths (create, move, reset, clear) exactly as create fails today; the **display** path tolerates it (§3.4, L-4). Adopted recommendations are listed in §10.2.

### 3.4 API

| Endpoint | Gate | Request | Response |
|---|---|---|---|
| **NEW** `POST /v3/location/updateBoundDefaults` (`LocationController`) | **method-level** `@RequiresFunction(WEB_UI_VIEW_STORAGE_LOCATION)`, mandatory | `{id, minAmount, hysteresis, maxAmount}`: numbers, or three `null`s to clear; parsed with `new BigDecimal(value.toString())` | 200 `LocationBoundDefaultsResult` · 200 `{errors}` (house style, `LocationController:66-81`) |
| **NEW** `POST /v3/fixedAssignment/resetBoundsToDefault` | class-level `WEB_UI_VIEW_FIXED_ASSIGNMENT` | `{id}` | 200 `getMessageResponse(…, "Updated")` · 200 `{errors}` |
| `GET /v3/fixedAssignment/detailView` | unchanged | — | + `boundsInherited`, `locationDefaultMinAmount/Hysteresis/MaxAmount` (nullable), `defaultSource` (`LOCATION` / `SYSTEM` / `SYSTEM_INVALID`), `defaultMinAmount/Hysteresis/MaxAmount` (effective; null when `SYSTEM_INVALID`), `boundsOutOfDate` |
| `GET /v3/location/detailView`, `/locationDetailsById/{id}` | unchanged | — | + `defaultMinAmount`, `defaultHysteresis`, `defaultMaxAmount` (nullable) |

- **`getFixedLocationAssignmentView`** (`ViewDtoService:903+`) reads the sysprop once per request in a try/catch: `NumberFormatException` → `defaultSource=SYSTEM_INVALID`, null system triple, view still renders (L-4). `boundsOutOfDate` = `boundsInherited` and (stored ≠ effective by `compareTo`, or `SYSTEM_INVALID` with no location default) (M-2). **`getLocationView`** gets 3 `dto.put`.
- **`LocationController`'s ctor gains `FixLocationAssignmentService`**; `LocationControllerUnitTest:38` (`new LocationController(keycloakService, 100, dtoViewService, locationService)`) changes with it (executor greps `new LocationController(` for others). Both new paths get a `Sbdev3017TrancheGateContextTest` row (the FLA one in the C1–C7 loop array).
- **Failures outside `{errors}` (implementation review CR L-6, SEC L2):** both new handlers return 200 `{errors}` only for a `BusinessException` or a non-numeric `id`. A concurrent move or delete during reset (`ObjectOptimisticLockingFailureException`) and a missing FLA or location (`EntityNotFoundException`) reach `RestExceptionHandler` as a 409 / 404 `ProblemDetail`, and any other failure as a 500, consistent with the sibling `/fixedAssignment/move`. The P2 UI treats any non-2xx as `false` and surfaces the `ProblemDetail`.
- **D-1 fold-in at `ViewDtoService:708`:** `String v = getSysvalue(…UPPER_BOUND_KEY); new BigDecimal(v == null || v.isBlank() ? …UPPER_BOUND_VALUE : v.trim())`. Values like `"84.5"` keep parsing (L-5); only null/blank changes.

### 3.5 Cache

- **No `@CacheEvict`.** The `locations` cache holds `Location` entities (`LocationService:100` `getByName`). Under D8 those entities carry no defaults, and the defaults edit changes neither a mapped column nor `version` on the row. So a cached `Location` stays identical to the database after an edit. Nothing that reads defaults goes through the cache: all such reads are the native methods in §3.2.
- **Moot under D8:** r1's Caffeine-vs-Redis hedge (Critic L3, Architect L-3). `CacheConfig:50-75` has a `redis` profile, and which profile runs in UAT/PRD cannot be derived from the repo (`wms2-caching-strategy.md:288`). Neither profile ever sees the new columns.

### 3.6 Locking & concurrency

All five create callers, read from source (Architect (a), Critic M2; the two `MobileReplenishService` arms were re-read for r2):

| Caller (transactional) | destination read before create | create | destination locked today |
|---|---|---|---|
| `StockunitService.transferStock` (`:435-436`) | `:543` `findByName` (unlocked) | `:560` | `:575` `transferStockToUnitLoad` → `StockunitBusinessService:349-350` `LockReads.forUpdate(…Location…)` |
| `MobilePutAwayService.storeBoxOnLocation` (`:582-583`) | `:600` `findByName` | `:640` | `:648` `transferStockToUnitLoad` |
| `MobileMoveUnitloadService.scanDestination` (`:355-356`) | `:458` `findByName` | `:646` | `transferStock` → `:981` → `transferStockToUnitLoad` |
| `MobileReplenishService.fulfillMultipleUnitLoadsTx` (`:938-939`) → `assignDestinationForMultiUnitLoads` | `:1080` `findByName` / `:1087` `findById` | `:1109` | after the SU locks at `:1002`, in the finish `:1025/:1042` → `:332` |
| same transaction, `finishReplenishmentOrderWithoutRefill` (`:223`) | `:235` `findByName` / `:252` `findById` | `:309` | `:332` `transferStockToUnitLoad` |

So **today no lock is held when create reads the defaults**; every caller locks the destination afterwards. In r2, create's first statement is `lockById`, so the destination lock moves a few statements earlier in all five. The later `LockReads.forUpdate` on that row is re-entrant: the managed branch issues a scalar lock plus a refresh, with no version-checked upgrade.

| Path | Location lock | FLA side |
|---|---|---|
| defaults edit | `lockById` | predicated native `writeThroughInherited` (`version+1`) |
| create | `lockById` (first statement) | INSERT + `markInherited` |
| move | already held since `:163`; `lockById` is re-entrant | entity save (`@Version`) |
| reset | `lockById` on the FLA's location | native `resetBounds` (`version+1`) |
| adjust* | none | `markOverridden(id, version)`, then entity save (`@Version`) |

**Races.** *Create vs edit:* serialized on the location row lock in either order. If the edit commits first, create reads the new default; if create commits first, the edit's `writeThroughInherited` starts after that commit and, under READ COMMITTED, sees the new FLA. **AC-17 asserts the resulting value in both orders.** *Edit vs adjust:* whichever UPDATE holds the FLA row first wins; the other's predicate (`and version = :v` / `and bounds_inherited`) is re-evaluated after the wait and matches 0 rows: loud for `adjust`, a correct no-op for the edit. *Edit vs move off the location:* `assignedlocation_id` is re-evaluated, so the moved FLA is untouched. *Reset vs move:* reset reads `assignedlocationId` before it locks, so `resetBounds` carries `and assignedlocation_id = :locationId`. A move that commits in between makes it match 0 rows, which raises OOLFE (L-1). *A future caller with no transaction:* `lockById` throws `TransactionRequiredException` (per `LocationRepository:127-129`, the repo's statement, not re-measured here), failing closed where a native `FOR SHARE` would have autocommitted and silently released the lock.

**Lock clause — two instruments disagree (resolved).** The Critic byte-grepped Hibernate 6.6.39's `PostgreSQLDialect.class`, found no `for no key update`, and inferred `FOR UPDATE`. `LockReads`' javadoc cites a **runtime measurement** (`StockunitSkipLockedIT`) of `FOR NO KEY UPDATE`. The measurement outranks the byte grep, because Hibernate 6 assembles lock clauses in its SQL AST translator. **The design is correct under either rendering:** create and edit take the *same* `lockById`, so they conflict either way, and AC-17 measures the serialization directly. O-2 is closed.

**Residual (Low, accepted):** taking the destination `Location` lock early runs ahead of `StockunitBusinessService:253-255`'s canonical order, in which Location is locked after the SU/UL. A deadlock partner would have to hold the source SU while it wants this specific flowbin, which has no FLA. Any path into such a flowbin goes through create, which now also locks the Location first. No such partner was found. If one exists, PG aborts one side with `40P01`.

### 3.7 UI (P2, wms2-web-ui)

**Storage Locations** (`storageLocation.vue`, `store/masterData/storageLocation.js`):
- Columns *Default Min / Default Hyst. / Default Max* (blank when null), from `getLocationView`'s new keys.
- **Flowbin rows:** "Set replenishment defaults" opens the new `boundDefaultsDialog.vue`: three numeric fields validated client-side as `0 ≤ min ≤ hyst < max` with ≤ 4 decimals, a **Clear** button, and the note "Updates the assigned SKU's bounds if it is set to Inherited".
- **Non-flowbin rows with non-null defaults (D7):** "Clear replenishment defaults" → confirm → posts three nulls.
- New action `updateBoundDefaults` → `$axios.post('/location/updateBoundDefaults', …)`, returning `true`/`false`; dialogs close only on `true` (SBDEV-3560 convention: `test/store/masterDataSaveResultSweep.spec.js`, `test/components/masterDataDialogRefusalSweep.spec.js`).

**Fixed Locations** (`fixedLocation.vue`, `updateBound.vue`, `moveFixedLocation.vue`, `store/masterData/fixedLocation.js`):
- **Bounds chip:** **Inherited** / **Inherited (out of date)** (when `boundsOutOfDate`) / **Overridden**. Details line: "Default: 24 / 36 / 48 (location)", "(system)", or "(system default invalid)".
- **Reset item:** enabled when Overridden **or** `boundsOutOfDate`; labelled **"Use location default"** when a location default exists, else **"Use default (system)"**; calls `resetBoundsToDefault({id})` (true/false), then reloads.
- **Notes:** `updateBound.vue`: "Saving marks this assignment Overridden; it will no longer follow its location's default." `moveFixedLocation.vue`, Overridden rows only (L-6, non-blocking): "This assignment is Overridden: its Min/Hyst/Max move with it unchanged. Use '…default' afterwards to adopt the destination's default."
- **Export:** add the *Bounds* column.

### 3.8 H2 test harness (consequence of D8)

**Problem:** `MobilePutawayServiceIntegrationTest` (`storeBoxOnLocation_putsWholePalletAway`, `:309`) and three more H2 tests (`MobilePickingServiceIntegrationTest`, `MobileReplenishServiceIntegrationTest`, `MobileTransferOrderServiceIntegrationTest`) reach create. All four extend `BaseIntegrationTest` (method: `git grep 'extends BaseIntegrationTest'` filtered on the create callers' names; blind spot: a test reaching create through a caller not named in the filter). H2 tables come only from `create-drop`, and no `schema*.sql`/`import*.sql` exists on either classpath (`git ls-tree`), so the unmapped columns would be missing.

**Fix:** a bean in `src/test/java/.../common/config/TestDatabaseConfig.java` (which `BaseIntegrationTest` `@Import`s):

```java
@Bean @DependsOn("tenantEntityManagerFactory")   // after create-drop built the tables
public Object sbdev3128UnmappedColumns(@Qualifier("landlordDataSource") DataSource ds) throws SQLException {
    // D8: these columns are read/written by native SQL only, so Hibernate never creates them.
    // ALTER TABLE location ADD COLUMN IF NOT EXISTS default_lowerbound numeric(17,4)  (x3)
    // ALTER TABLE fix_location_assignment ADD COLUMN IF NOT EXISTS bounds_inherited boolean DEFAULT false NOT NULL
}
```

**Why this seam:** the same class already runs raw DDL on `landlordDataSource` (`CREATE SEQUENCE IF NOT EXISTS seqentities`); landlord and tenant URLs are the same H2 DB (`application-integration.properties:20,31`); the tenant EMF bean is `tenantEntityManagerFactory` (`TenantDatabaseConfig` method name). **Rejected:** `hibernate.hbm2ddl.import_files` via `spring.jpa.properties` (the shared `EntityManagerFactoryBuilder`, `TenantDatabaseConfig:96-104`, hands it to **both** units on that one DB, so the landlord unit's run is order-dependent); `spring.sql.init` (the `@Primary` DataSource here is a Mockito mock, per the `TestDatabaseConfig` javadoc); a native read that tolerates a missing column (an error aborts the PG transaction). No resource file is added, so the "test/resources shadows main" trap (`application-postgres-integration.properties:34-37`) cannot apply. PG ITs need nothing (Flyway; `validate` ignores unmapped columns). **Gate check:** `git grep -l TestDatabaseConfig` shows every H2 base reaching this SQL imports it. **With D9 the bean is no longer load-bearing for the suite's green.** Without it, the probe is false on H2, the four tests take the legacy path, and they still pass. AC-20c therefore asserts `bounds_inherited = true` on the FLA created by `storeBoxOnLocation_putsWholePalletAway`; that assertion is what pins the bean and the H2 probe.

## 4. File Change Summary

Paths are under `src/main/java/net/aim_ai/wms/` unless they start with `src/test` or `src/main/resources`.

| Repo | File | Change | Phase |
|---|---|---|---|
| api | `src/main/resources/db/migration/V2.2.45__location_default_fla_bounds.sql` | NEW (§3.1) | P1 |
| api | `repo/jpa/LocationRepository.java` | + `lockById`, `findDefaultBoundsById`, `updateDefaultBounds`; `getDetailView` +3 columns | P1 |
| api | `repo/jpa/FixLocationAssignmentRepository.java` | + 5 methods (§3.2); `getDetailView` +4 columns | P1 |
| api | `repo/projection/LocationDefaultBoundsView.java` (NEW), `LocationDetailView`, `FixLocationAssignmentDetailView` | getters | P1 |
| api | `service/FixLocationAssignmentService.java` | §3.3 | P1 |
| api | `dto/LocationBoundDefaultsResult.java` | NEW record | P1 |
| api | `service/ViewDtoService.java` | `getLocationView` +3 put; `getFixedLocationAssignmentView` keys; `:708` D-1 | P1 |
| api | `service/LocationService.java` | `getLocationDetails` +3 keys | P1 |
| api | `controller/LocationController.java` | ctor + `updateBoundDefaults` | P1 |
| api | `controller/FixLocationAssignmentController.java` | + `resetBoundsToDefault`; stale `:22-24` comment (D-5) | P1 |
| api | `src/test/.../common/config/TestDatabaseConfig.java` | H2 bean (§3.8) | P1 |
| api | tests (§7.2) | NEW `LocationDefaultBoundsMigrationIT`; extend 7 existing classes | P1 |
| ui | `storageLocation.vue`, NEW `boundDefaultsDialog.vue`, `store/masterData/storageLocation.js` | §3.7 | P2 |
| ui | `fixedLocation.vue`, `updateBound.vue`, `moveFixedLocation.vue`, `store/masterData/fixedLocation.js` | §3.7 | P2 |
| ui | NEW specs + rows added to the two SBDEV-3560 sweep specs | §7.2 | P2 |
| docs | `wms2-replenishment-design.md`, `wms2-sysprop-catalog.md`, `wms2-function-to-docs-map.md`, `wms2-rest-api-reference.md`, `wms2-entity-enumeration-report.md` (note the unmapped columns) | docs-update step; D-7 fixed there | P1/P2 |

## 5. Prerequisites & Phased Implementation Plan

### 5.1 Prerequisites

| # | Prerequisite | Required value / action | Owner |
|---|---|---|---|
| 1 | **Flyway version** | V2.2.45 is free. `git ls-tree origin/develop` shows only V2.2.40–44. The Critic swept all 499 remote heads and the peer worktrees: 0 hits. Re-check at commit time (`git fetch --all`, `gh pr list --state open --search V2.2.45`, `.claude/worktrees/wms2-api/*`) and at merge time (`wms-merge` preflight). On a collision, renumber; never edit after apply. | executor |
| 2 | Feature flags / sysprops | N/A. There is no toggle: the feature stays inert until someone sets a default. | — |
| 3 | Config / env | N/A | — |
| 4 | **Deploy order** | P1 reaches an environment **before** P2 merges there (P2 calls two new endpoints). P1 alone is safe with the old UI. | Nam |
| 5 | **Post-deploy, per tenant, within minutes** | `select success from flyway_schema_history where version='2.2.45'` = `t`; `select count(*) from information_schema.columns where table_name in ('location','fix_location_assignment') and column_name in ('default_lowerbound','default_middlebound','default_upperbound','bounds_inherited')` = 4; `select bounds_inherited, count(*) from fix_location_assignment group by 1`. Boot log: 42501 (ownership drift, V2.2.32 header) and 55P03/40P01. | Nam / executor |
| 6 | External systems | N/A. No change to OMS, printers or Keycloak. Mobile reads the FLA upper bound, which is unchanged. | — |
| 7 | **Access** | Run M0 on PRD. If the third value is > 0, report it to Nam before P1 reaches PRD. | executor |
| 8 | Monitoring | No new metric; use the saved queries in §7.7. | — |
| 9 | **Sysprop sanity on PRD (L-4)** | `select syskey, sysvalue ~ '^[+-]?[0-9]{1,18}$' from los_sysprop where syskey like 'FIX_LOCATION_ASSIGNMENT_DEFAULT_VALUE_%_BOUND' and workstation='DEFAULT'`: every row `t`, or no rows. | executor |
| 10 | **Probe schema sanity, all 6 tenant DBs, before deploy (D9, r3 L-1)** | `select current_schema(), exists (select 1 from information_schema.columns where table_schema = current_schema() and table_name = 'fix_location_assignment' and column_name = 'version')` → `public \| t` on every tenant. DEV measured `public`, `search_path "$user", public`. If a tenant returns anything else (for example a schema named after its app role), the probe reads false there **permanently**: the feature switches itself off (edit/clear/reset say "unavailable until V2.2.45") while unqualified SQL still resolves to `public`. Stop and report to Nam before deploying | executor |

### 5.2 Phases

**P1 — wms2-api** · branch `feature/SBDEV-3128-location-default-fla-bounds` · **Risk: HIGH** (migration on 6 tenants + concurrency) · **Effort: ~2 days**
1. Triage block on the ticket; `ticket-lease.sh claim SBDEV-3128`; worktree `.claude/worktrees/wms2-api/SBDEV-3128` off a fresh `origin/develop`; prerequisite #1 sweep.
2. **TDD gate:** write the §7.2 P1 tests and confirm each is red for the right reason. *Accept:* the red list is recorded in Implementation Status.
3. Migration, repository methods and projections, plus the H2 bean. *Accept:* `LocationDefaultBoundsMigrationIT` green; the 4 H2 tests (§3.8) green; removing the H2 bean turns AC-20c red (the other 3 stay green via the D9 legacy path).
4. Service and `ViewDtoService`/`LocationService` keys. *Accept:* ServiceUnitTest + ServiceIT + ViewDtoServiceUnitTest green; PIT shows no SURVIVED mutant on new service lines (§7.3). The move re-seed now has unit tests, so this is satisfiable (Critic L4).
5. Controllers and gate pins. *Accept:* controller units + `Sbdev3017TrancheGateContextTest` green; gate mutants red (§7.3).
6. Full `mvn verify` against the known baseline; `code-reviewer` + `verifier` lanes in separate worktrees; fix every finding, including Lows; docs step; PR into `develop`.

**P2 — wms2-web-ui** · same branch name · **Risk: LOW** (additive UI; the API contract is fixed by P1) · **Effort: ~1 day**
7. Worktree off a fresh `origin/develop`; Jest specs first (red).
8. Storage Locations dialog and clear item; Fixed Locations chip, reset and notes. *Accept:* `yarn test` green against the baseline; each new assertion mutation-checked by hand.
9. Manual M0–M11 on DEV with `wms-dev-probe` + `snapshot.sh`; review lane; PR into `develop`; ClickUp `pr submitted`.

## 6. Backward Compatibility

| Surface | Before → After | Compatible? |
|---|---|---|
| `GET /v3/fixedAssignment/detailView` | 9 keys → 9 + 10 additive | yes |
| `/v3/fixedAssignment/update`, `/set*Bound` | + flips to overridden; now transactional; trigger runs post-commit | yes (same responses without contention) |
| `/set*Bound`, `/update` **under contention** | **new:** a concurrent defaults edit, reset or second adjust makes the loser throw `ObjectOptimisticLockingFailureException`, which reaches `RestEndpointExceptionHandler`/`RestExceptionHandler` as their optimistic-lock response. Today the last writer silently wins | contract addition (loud, retryable) |
| tenant stuck at 2.2.44 (D9) | create, adjust, move and the details popup read and write no new column (plus one probe SELECT; `adjust*` is `@Transactional`); edit/clear/reset return `{errors}`; the two lists 42703 | degraded, feature-only |
| `/v3/location/detailView`, `/locationDetailsById/{id}` | + 3 nullable keys | yes |
| `/v3/location/create`, `/update`, SDR `GET /api/location/**` | unchanged (unmapped columns are invisible to Jackson and to entity saves) | yes |
| `Location` / `FixLocationAssignment` entities | unchanged | yes |
| R1–R15 readers, monitors, V2.2.43 view | no reader's bound expression changes; R2 gains additive columns | yes |
| fixtures with explicit column lists (none positional, G8) | new column → `DEFAULT false` | yes |
| PG ITs (`validate`) / H2 ITs (`create-drop`) | ignore the columns / get them from the §3.8 bean | yes |
| old jar on the new schema (rollback) | columns are nullable or defaulted, so the old jar is unaffected; flag semantics need §8 step 6 | yes, with runbook |
| new UI on the old API | 404 on the new endpoints | **no** → prerequisite #4 |

**What does NOT change:** the FLA bound columns and their NOT NULL; every replenishment reader; the sysprop keys, values and read tier; `adjust*` validation messages and order-dependence; `delete`/`changeActive`; `move()`'s message text; `LocationService.updateLocation`; `/v3/import/locations`; grants; the mobile UI; the `location` row's `version`. No hard capacity cap is enforced (D2).

## 7. Testing Strategy

### 7.1 Commands
- api: `mvn test -Dtest=<Class>`, then `mvn verify` before the PR. PIT per §7.3.
- ui: `yarn test`.

### 7.2 Tests ↔ acceptance criteria

| AC | Ticket | Assertion | Test class · method |
|---|---|---|---|
| AC-1 | h | migrate to 2.2.44; seed FLAs 36/60/84, 12/24/36, and 36/60/90 with sysprop UPPER=`'90'` on a 2nd fresh DB; migrate → inherited exactly where the triple equals *that tenant's* sysprop triple | ★ `integration/schema/LocationDefaultBoundsMigrationIT` · `backfill_marksOnlyTenantDefaultTripleInherited`, `backfill_readsTenantSyspropNotHardcoded` |
| AC-2 | h | sysprop row absent → 36/60/84; non-`DEFAULT` workstation ignored; lowest `client_id` wins | same · `backfill_rowAbsent_fallsBack`, `backfill_nonDefaultWorkstationIgnored`, `backfill_lowestClientIdWins` |
| AC-3 | g | CHECK rejects (10,5,20), (10,NULL,20), (−1,0,1), (10,20,20); accepts all-NULL and (0,0,1) | same · `check_rejects_*`, `check_accepts_*` |
| AC-4 | a, b | probe true (stubbed): location 24/36/48 → FLA 24/36/48 + `markInherited`; location null → sysprop; `markInherited` = 0 → `IllegalStateException`; `lockById` called before `createUnitload` (`InOrder`) | `unit/service/FixLocationAssignmentServiceUnitTest` `@Nested Create` |
| AC-4b | a, b | on real PG, create leaves `bounds_inherited = true` (the INSERT reached the DB before `markInherited`) | `service/FixLocationAssignmentServiceIT` · `create_marksInheritedOnRealPg` |
| AC-5 | c, d | probe true: each `adjust*` calls `markOverridden(id, version)`; a 0 result → `ObjectOptimisticLockingFailureException` and no save | existing `@Nested Adjust*` (`:118,165,210`) · `+ marksOverridden`, `+ staleVersion_rejected` |
| AC-5b | c, d | PG: `markOverridden` with a stale version matches 0 rows; `adjust*` flips the flag on real PG. **`adjust_flipsFlagOnRealPg` carries a method-level `@Transactional(propagation = Propagation.NOT_SUPPORTED)`.** That annotation overrides the class-level `@Transactional("tenantTransactionManager")` inherited from `BasePostgresIntegrationTest:61`, which would otherwise supply a transaction and mask the "drop `@Transactional`" mutant. The test sits in a `@Nested class AdjustCommitted` whose fixture is seeded through committed writes (`TransactionTemplate` on `tenantTransactionManager`) and deleted explicitly in that class's `@AfterEach`. `markOverridden_staleVersion_noRow` calls the `@Modifying` method directly, needs a transaction, and stays in the transactional outer class | ServiceIT · `AdjustCommitted.adjust_flipsFlagOnRealPg`, `markOverridden_staleVersion_noRow` |

**L-2, the five existing unit tests that call create/adjust:** `FixLocationAssignmentServiceUnitTest:405`, `:963` (create) and `:129`, `:176`, `:221` (adjust happy paths). The Critic reasoned they go red by construction: an unstubbed `lockById` returns `Optional.empty()` → `EntityNotFoundException`, and `markInherited`/`markOverridden` return 0 → `IllegalStateException`/OOLFE. **Under D9 that no longer holds.** Mockito's default `false` for `featureColumnsPresent()` routes all five down the legacy path, so they stay green unedited and become the legacy-path regression net. The probe-true behaviour is covered by the new AC-4/AC-5 methods, which re-stub: `featureColumnsPresent()` → `true`; create: `lockById(anyLong())` → `Optional.of(id)`, `findDefaultBoundsById` → a view with the triple or nulls, `markInherited` → 1; adjust: `markOverridden(eq(id), any())` → 1. *Gate: confirm all five are green before any edit; if the class uses strict stubs, a red with `UnnecessaryStubbing` means a probe-true stub leaked into them.*
| AC-6 | b, d | edit: `writeThroughInherited` with the triple, trigger once when n=1, `never()` when n=0 | ServiceUnitTest `@Nested UpdateLocationBoundDefaults` · `writesThrough`, `noInheritedFla_noTrigger` |
| AC-6b | b, d | PG: inherited FLA rewritten (`version` +1); overridden FLA untouched (kills a dropped `and bounds_inherited`) | ServiceIT · `edit_writesThroughInheritedOnly` |
| AC-7 | b | clear → `writeThroughInherited` with the sysprop triple; `updateDefaultBounds` with nulls | ServiceUnitTest · `clear_revertsInheritedToSysprop` |
| AC-8 | g | (36,60,60), (61,60,84), (−1,0,1), partial-null, scale 5 (`24.00001`) → `BusinessException`; `never()` on `lockById`, `updateDefaultBounds`, `writeThroughInherited` (full varargs) | ServiceUnitTest · `rejects_*` (parameterized) |
| AC-9 | c, d | reset → `resetBounds(id, fla.getAssignedlocationId(), …)` with the location triple (or sysprop when null), trigger once; FLA entity never saved; `resetBounds` = 0 → `ObjectOptimisticLockingFailureException` | ServiceUnitTest `@Nested Reset` |
| AC-9b | c, d | PG: `resetBounds` with a stale `locationId` (FLA moved) matches 0 rows | ServiceIT · `resetBounds_afterMove_noRow` |
| AC-10 | b, d | move: inherited → triple = destination default; overridden → own triple kept; `findBoundsInheritedById` drives it | ServiceUnitTest `@Nested Move` · `inheritedReseeds`, `overriddenKeeps` + ServiceIT · `move_inheritedTakesDestinationDefault` |
| AC-11 | — | both new paths gated; no function → 403 | `security/Sbdev3017TrancheGateContextTest` (2 rows) + `LocationControllerUnitTest` · `updateBoundDefaults_*` + `FixLocationAssignmentControllerUnitTest` · `resetBoundsToDefault_*` |
| AC-14 | e | FLA view: old 9 keys unchanged; new keys; `defaultSource` LOCATION/SYSTEM; `boundsOutOfDate` true for inherited 36/60/84 when the sysprop is 30/50/70, false when equal (compare with `compareTo`: `24.0000` ≠ `24` under `equals`) | `unit/service/ViewDtoServiceUnitTest` · `fixedAssignmentView_*` |
| AC-14b | a | `getLocationView` carries the 3 default keys | ViewDtoServiceUnitTest · `locationView_includesDefaults` |
| AC-14c | a | `getLocationDetails` carries the 3 keys | `LocationServiceUnitTest` · `locationDetails_includesDefaults` |
| AC-15 | f | reader nets pass **unedited**: `RefillFixedLocationPredicateIntegrationTest`, `FlowbinMonitorViewPerFlowbinIT`, `ReplenishmentMonitorViewSchemaIT`, + the 4 H2 tests of §3.8 | existing (regression net, not new behavior) |
| AC-16a | — | D6: **set** on a non-flowbin → `BusinessException`, `never()` `updateDefaultBounds` | ServiceUnitTest · `rejectsSetOnNonFlowbin` |
| AC-16b | — | D7: **clear** on a non-flowbin → `updateDefaultBounds(nulls)` + write-through with sysprop | ServiceUnitTest · `allowsClearOnNonFlowbin` |
| AC-17 | b | two connections (harness modeled on `BusinessServiceLockRefreshStaleVersionIT`): **create-first** (create's tx paused after its lock until the edit has been seen blocked, then committed) and **edit-first**; after both commit, FLA triple **==** edited default (`compareTo`) **and** `bounds_inherited = true` | ServiceIT · `createThenEdit_flaHasEditedDefault`, `editThenCreate_flaHasEditedDefault` |
| AC-18 | — | D-1: sysprop UPPER absent → no NPE, upper 84; `" 84 "` → 84; `"84.5"` → 84.5 | ViewDtoServiceUnitTest · `replenishOrderViewByKeyword_absentUpperSysprop_fallsBackTo84`, `…_paddedAndDecimal_parse` |
| AC-19 | e | L-4: sysprop `'abc'` → view renders, `defaultSource=SYSTEM_INVALID`, effective triple null | ViewDtoServiceUnitTest · `fixedAssignmentView_invalidSysprop_rendersSystemInvalid` |
| AC-20 | — | D9, probe false: create seeds the sysprop triple with `never()` on `lockById`, `findDefaultBoundsById`, `markInherited`; `adjust*` saves with `never()` `markOverridden`; move `never()` `findBoundsInheritedById`; edit, clear and reset → `BusinessException("…unavailable until database migration V2.2.45…")` with `never()` on every write; `getLocationDetails` omits the 3 keys | ServiceUnitTest `@Nested FeatureColumnsAbsent`; `LocationServiceUnitTest` · `locationDetails_columnsAbsent_omitsKeys` |
| AC-20b | — | the probe SQL itself: false on a fresh DB migrated to 2.2.44, true after latest | `LocationDefaultBoundsMigrationIT` · `featureColumnsPresent_falseAt2244_trueAfter` |
| AC-20c | — | H2: the FLA created by `storeBoxOnLocation_putsWholePalletAway` has `bounds_inherited = true`, read **inside the test's own transaction** after `em.flush()` via `fixLocationAssignmentRepository.findBoundsInheritedById(fla.getId())` (tenant persistence unit). **Not** the H2 `JdbcTemplate`: it is built on `landlordDataSource` (`TestDatabaseConfig:43-45`), borrows a different pooled connection, and cannot see the uncommitted FLA of the rolled-back test transaction (`BaseIntegrationTest:32`). Without the bean the read fails with "column not found", so the pin holds. This proves the H2 probe and the §3.8 bean | `MobilePutawayServiceIntegrationTest` (+1 assertion) |
| UI-1 | a | `updateBoundDefaults` posts `{id,minAmount,hysteresis,maxAmount}`; Clear posts three nulls; returns true/false | `test/store/masterData/storageLocationBoundDefaults.spec.js` |
| UI-2 | g | dialog blocks 60/36/84, −1/0/1, partial, 5 decimals; allows 24/36/48 | `test/components/masterData/location/boundDefaultsDialog.spec.js` |
| UI-3 | — | "Set…" hidden on non-flowbin rows | `storageLocationMenu.spec.js` |
| UI-3b | — | D7: "Clear…" shown on non-flowbin rows only when defaults are non-null; posts three nulls | same |
| UI-4 | c | reset posts `{id}`; enabled when Overridden or out of date, disabled when Inherited and current; label "Use default (system)" when no location default | `fixedLocationResetBounds.spec.js`, `fixedLocationBoundsChip.spec.js` |
| UI-5 | e | chip renders Inherited / Inherited (out of date) / Overridden | same |
| UI-6 | — | SBDEV-3560: both new actions return false on `{errors}`; both dialogs stay open on false | rows added to `masterDataSaveResultSweep.spec.js`, `masterDataDialogRefusalSweep.spec.js` |
| UI-7 | — | L-6: move dialog shows the note only for Overridden rows | `moveFixedLocationNote.spec.js` |

### 7.3 Mutation checks (floor: every new assertion seen red)

- **PIT:** `mvn test-compile && mvn org.pitest:pitest-maven:mutationCoverage -DtargetClasses=net.aim_ai.wms.service.FixLocationAssignmentService -DtargetTests=net.aim_ai.wms.unit.service.FixLocationAssignmentServiceUnitTest`. No SURVIVED mutant on new lines. Confirm each KILLED came from the intended assertion, not an incidental NPE.
- **By hand** (SQL, annotations and harness; PIT cannot mutate them). Apply each mutant, run, see red, revert:

| Mutant | Expected red |
|---|---|
| drop `ORDER BY client_id` / `AND workstation = 'DEFAULT'` | AC-2 `lowestClientIdWins` / `nonDefaultWorkstationIgnored` |
| hardcode 36/60/84; swap MIDDLE↔UPPER syskey | AC-1 |
| CHECK `<` → `<=` on middle/upper; drop `>= 0` | AC-3 |
| `DEFAULT false` → `DEFAULT true` | AC-1 overridden-row assertion |
| remove `@Lock` from `lockById` (or skip the call in create) | AC-17 both orders: `expected (24,36,48) but was (36,60,84)` |
| call `markInherited` **before** `save` | AC-4b (`IllegalStateException` from the `== 1` guard). *Gate also runs "drop `flushAutomatically`" once and records it **green**, confirming empirically that it is an equivalent mutant under Hibernate 6.6.39 (M-1)* |
| drop `and assignedlocation_id = :locationId` in `resetBounds` | AC-9b |
| drop `@Transactional` on `adjustUpperBound` | AC-5b (`markOverridden` outside a transaction fails) |
| ignore the probe (hardcode `true`) | AC-20 (`lockById`/`markOverridden` invoked) |
| probe names the wrong column | AC-20b |
| drop `and bounds_inherited` in `writeThroughInherited` | AC-6b overridden-row assertion |
| drop `and version = :version` in `markOverridden` | AC-5b `staleVersion_noRow` |
| invert `updateLocationBoundDefaults`' null guard so `requireFlowbin` also runs on clear | AC-16b |
| delete the H2 bean | AC-20c (the other 3 H2 tests stay green via the D9 legacy path) |
| restore the raw `new BigDecimal(getSysvalue(…))` at `:708` | AC-18 |
| remove the try/catch on the view's sysprop read | AC-19 |

- **Gate:** delete `updateBoundDefaults`' method-level `@RequiresFunction` → AC-11 red. `resetBoundsToDefault` has no per-method annotation (L9); its mutant is dropping the class-level annotation in a scratch copy, which turns the new loop row red (alongside C1–C7), attributable by row name.
- **Jest:** invert each validation comparison; flip the flowbin predicate and the non-null predicate → UI-2/UI-3/UI-3b red; make an action return true on `{errors}` → UI-6 red.

### 7.4 Manual Test Plan (DEV `dev_wh01_om1`, `wms-dev-probe`; counts measured 2026-11-01)

`D` := `f.lowerbound=36 and f.middlebound=60 and f.upperbound=84`; `NOOPEN` := `not exists (select 1 from replenishorder r where r.itemdata_id=f.itemdata_id and r.state<700)`.

| # | Scenario | Precondition (one SQL each) → measured | Expected |
|---|---|---|---|
| M0 | authz population (repeat on PRD) | `with u as (select gu.userlist_id uid, f.name fn from mywms_group_mywms_user gu join mywms_group_mywms_role gr on gr.grouplist_id=gu.grouplist_id join mywms_role_mywms_function rf on rf.rolelist_id=gr.rolelist_id join mywms_function f on f.id=rf.functionlist_id where f.name in ('WEB_UI_VIEW_STORAGE_LOCATION','WEB_UI_VIEW_FIXED_ASSIGNMENT')) select count(distinct uid) filter (where fn='WEB_UI_VIEW_STORAGE_LOCATION'), count(distinct uid) filter (where fn='WEB_UI_VIEW_FIXED_ASSIGNMENT'), (select count(*) from (select uid from u group by uid having count(distinct fn)=1) x), (select count(*) from mywms_user_mywms_role) from u` → 44 / 44 / 0 / 0 | PRD: 3rd value reported to Nam; 4th > 0 means the direct path is in use → re-derive |
| M1 | columns absent before deploy | prereq #5 column query → 0 | 4 after deploy |
| M2 / M3 | backfill | `select count(*) from fix_location_assignment f where D` → 1307; `… where not (D)` → 37 | `… where bounds_inherited` = 1307; `not` = 37 |
| M4 | set 24/36/48 on `00-A01` → FLA follows | `select l.name, f.id from fix_location_assignment f join location l on l.id=f.assignedlocation_id where D and NOOPEN order by l.name limit 3` → 00-A01 (21553351), 00-A03, 00-A05 | FLA 24/36/48, chip Inherited, version +1 |
| M5 | default on overridden `22-A01` → unchanged; then reset | `select l.name from fix_location_assignment f join location l on l.id=f.assignedlocation_id where not (D) order by l.name limit 5` → 22-A01, 25-A06, 25-C01, 25-C04, 26-A02 | 12/24/36 until reset, then the default, Inherited |
| M6 | clear M4 | — | 36/60/84, still Inherited |
| M7 | delete an empty inherited FLA on a location with a default, re-create via putaway | `select count(*) from fix_location_assignment f where D and NOOPEN and not exists (select 1 from stockunit s where s.unitload_id=f.assignedunitload_id and (s.amount<>0 or s.reservedamount<>0))` → 62 | new FLA = location triple, Inherited |
| M8 | move an inherited FLA to a flowbin with a default | source: `select count(*) from fix_location_assignment f where D and not exists (select 1 from replenishorder r where r.itemdata_id=f.itemdata_id and r.state>300 and r.state<700) and (select count(*) from unitload u where u.storagelocation_id=f.assignedlocation_id)=1 and (select count(*) from stockunit s where s.unitload_id=f.assignedunitload_id)=1` → 1307; destination: `select count(*) from location l join location_type lt on lt.id=l.type_id where lt.sltname='flowbin' and not exists (select 1 from fix_location_assignment f where f.assignedlocation_id=l.id) and not exists (select 1 from unitload u where u.storagelocation_id=l.id)` → 723 | destination triple |
| M9 | invalid 60/36/84; **set** on a non-flowbin via API | — | `{errors}`; `select default_lowerbound, version from location where id=…` unchanged |
| M10 | D7: **clear** on a non-flowbin with defaults seeded by SQL inside the snapshot | `select count(*) from location l join location_type lt on lt.id=l.type_id where lt.sltname<>'flowbin'` → > 0 | UI "Clear…" visible; defaults null afterwards |
| M11 | `snapshot.sh` restore proof for M4–M10 | — | diff empty |

### 7.5 Horizontal Scalability (10)

| # | Concern | Verdict | Rationale |
|---|---|---|---|
| 1 | In-JVM state | No | no cache touched (§3.5) |
| 2 | Connection-pool math | No | +2 PK statements per create; no new pool |
| 3 | Scheduled jobs | No | none added |
| 4 | Long transactions | No | ≤ 1 FLA per edit (UNIQUE); trigger after commit |
| 5 | Request affinity | No | stateless |
| 6 | Retry / idempotency | Yes (benign) | edit/reset re-runnable; optimistic-lock and 40P01 failures are loud and retryable |
| 7 | Tenant context | No | same tenant TM; Flyway per tenant |
| 8 | Distributed lock correctness | Yes | PG row locks inside `tenantTransactionManager` (§3.6) |
| 9 | Cache invalidation | No | §3.5 |
| 10 | External notifications | No | — |

### 7.6 v2 constraint checklist (8)

| # | Constraint | Verdict | Evidence |
|---|---|---|---|
| 1 | OSIV off | ✓ | new write methods `@Transactional`; native projections for views |
| 2 | Transaction manager | ✓ | `tenantTransactionManager` + `rollbackFor` on all new or changed transactional methods |
| 3 | readOnly reads | partial | `ViewDtoService:903` lacks readOnly today; out of scope |
| 4 | Caffeine invalidation | N/A | §3.5: cached entities unaffected |
| 5 | Micrometer | n/a | master data |
| 6 | Jakarta | ✓ | `jakarta.persistence.LockModeType` |
| 7 | **H2 test SQL** | ✓ §3.8 | the 4 H2 tests reach create; native SQL is portable; the lock goes through JPQL; columns come from the bean |
| 8 | Controller test base | ✓ | `BaseControllerUnitTest` + gate pin |

### 7.7 Expanded test plan (deliberate mode)

| Layer | Coverage |
|---|---|
| Unit | ServiceUnitTest (AC-4..10, 16a/b, 20), controller units (AC-11), ViewDto/LocationService (AC-14, 14b, 14c, 18, 19); PIT |
| Integration | `LocationDefaultBoundsMigrationIT` (AC-1..3; fresh DB per test, `migrateTo("2.2.44")` then latest, as in `BillofladingTransferIdNotNullIT:115-121`); ServiceIT (AC-4b, 5b, 6b, 9b, 10, 17); probe on PG and H2 (AC-20b, 20c); H2 + PG reader nets unedited (AC-15); full `mvn verify` |
| E2E | Manual M0–M11 on DEV through the real UI and API, with snapshot restore |
| Observability | **O-1** boot log: V2.2.45 success per tenant; any `55P03` / `40P01` / `42501` / `42703` in the first hour. **O-2** per-tenant `select bounds_inherited, count(*) … group by 1` vs the pre-deploy M2/M3 counts. **O-3** log search for `ObjectOptimisticLockingFailureException` / `StaleObjectStateException` naming `FixLocationAssignment`, 7 days after P2 vs 7 days before (new `version+1` writers). **O-4** I-1 drift, both tiers: `with d as (<§3.1 CTE>) select count(*) from fix_location_assignment f join location l on l.id=f.assignedlocation_id cross join d where f.bounds_inherited and (f.lowerbound,f.middlebound,f.upperbound) is distinct from (coalesce(l.default_lowerbound,d.lo), coalesce(l.default_middlebound,d.mi), coalesce(l.default_upperbound,d.up))`. Expect 0, or exactly the UI's "out of date" rows after a sysprop edit. **O-4 detects drift, not an overwrite that already happened** (after an overwrite the row equals the default again). Its predicate covers only inherited rows. The PM-1 window rows (inserted after the migration committed, still at the default triple but `bounds_inherited = false`) are expected; find them with the same join filtered on `not f.bounds_inherited` and triple **equal** to the effective default, and fix them with a reset. |

### 7.8 Deliberately skipped

| What | Why |
|---|---|
| Cypress / browser e2e | not in wms2-web-ui; the manual M-rows cover it |
| sysprop-edit propagation | not a feature (R-5); surfaced as "out of date" (M-2) |
| garbage-sysprop backfill tests (`'abc'`, `' 36 '`) | Critic over-engineering. The regex guard stays (a cast error would fail the migration); prerequisite #9 measures PRD |
| replaying the migration body | Flyway never replays an applied script |
| PRD dry-run of the backfill | MCP down; O-2 measures it; the backfill sets only a flag |

### 7.9 Pre-mortem (3 scenarios)

| # | Failure 6 weeks out | Cause | Prevention in this plan |
|---|---|---|---|
| PM-1 | On one tenant, the Storage Locations and Fixed Locations lists return 42703, and the defaults edit/clear/reset return "unavailable until V2.2.45 applies" | V2.2.45 failed there (55P03/40P01 on a busy deploy, or 42501) | D8 + D9: entity reads keep working, and create (putaway / move-unitload / replenish into a flowbin with no FLA), `adjust*`, move and the details popup take the probe-false legacy path (AC-20). FLAs created before the migration commits get `DEFAULT false` and are classified by the backfill when it lands. **FLAs inserted *after* it commits by a transaction that did not see it stay `DEFAULT false` (Overridden) permanently.** Such a transaction is either a pre-3128 pod during a rolling deploy, or a probe-false transaction that had not yet locked a row. This is the safe direction: edits don't propagate, nothing is overwritten. O-4 can surface them, and a reset fixes them. Low-traffic window; prerequisite #5 within minutes; O-1; runbook §8 |
| PM-2 | An operator's hand-tuned FLA is overwritten by a location-default edit | FLA wrongly inherited: backfill tier wrong, a writer that does not flip the flag, **or old-jar `adjust*` during a rollback** | backfill mirrors `SyspropRepository:30` + AC-1/2 mutants; every writer enumerated (§0.2) and AC-5/5b; §8 step 6 roll-forward re-classification; O-4 for drift (it cannot see a completed overwrite) |
| PM-3 | New flowbin FLAs silently land as Overridden, so defaults edits never reach them | `markInherited` matched 0 rows (INSERT not yet in the DB, e.g. a reordering or FlushMode change), or the probe wrongly false | the `== 1` guard makes the first case loud; AC-4b on real PG + mutant "markInherited before save"; AC-20b/20c pin the probe on PG and H2 |

## 8. Rollout Plan

1. Merge the P1 PR to `develop` via `wms-merge` (Flyway collision re-checked), then deploy to dev **in a low-traffic window**.
2. Within minutes, on every tenant: prerequisite #5, O-1, O-2, M1–M3.
3. Merge P2, deploy to dev, run M4–M11 with snapshot restore, tick the ClickUp ACs.
4. QA/UAT/PRD promotion belongs to DevOps. Before PRD: M0 (prerequisite #7), prerequisite #9, prerequisite #5 on all 6 tenant DBs; P1 reaches each environment before P2; low-traffic window.
5. **Runbook.** 55P03/40P01 on V2.2.45 → restart the pod in a quiet window (Flyway retries; no history row was written). 42501 → fix ownership as in V2.2.32, then restart. Until then only this feature fails on that tenant (PM-1).
6. **Rollback / roll-forward.** Redeploying the previous jar is safe without a down-migration (the old entities never map the columns). While it runs the flag is not maintained: its creates get `false` (fail-safe), but its `adjust*` and `move` leave `true` on rows whose triple changed (unsafe). **At roll-forward, per tenant, before reopening the screens** (fail-safe, same rule as the backfill):
     ```sql
     WITH d AS (<the §3.1 CTE, verbatim>)
     UPDATE fix_location_assignment f SET bounds_inherited = false
       FROM location l, d
      WHERE l.id = f.assignedlocation_id AND f.bounds_inherited
        AND (f.lowerbound, f.middlebound, f.upperbound) IS DISTINCT FROM
            (COALESCE(l.default_lowerbound, d.lo), COALESCE(l.default_middlebound, d.mi), COALESCE(l.default_upperbound, d.up));
     ```
     Then O-4 = 0. Operators re-adopt defaults with the reset item.
7. Tell WineCo: set the 53-B06 defaults to their measured capacity (for example 12/24/48; the values are their call). Existing FLAs follow only if they are Inherited.

## 9. Alternatives Considered

| Option | Pros | Cons | Verdict |
|---|---|---|---|
| **A. Write-through + `bounds_inherited`** | no reader's bound expression changes (0 of 15); ≤ 1 FLA write per edit; an explicit flag answers AC-e | the flag must be kept right by every writer (I-1); sysprop edits do not propagate (shown as "out of date") | **chosen (D1)** |
| **A+G. Columns unmapped, native SQL only** (Critic M7) | a failed migration degrades only this feature, not every Location/FLA read (V2.2.40 precedent); with the D9 probe, only the two admin lists fail; no `location.version` bump (D5 moot); no mass-assignment, READ_ONLY or Redis-serializer concern; entity saves can never clobber the defaults | nine new repository methods (eight native including the D9 probe, plus the JPQL `lockById`) and two extended native `getDetailView`s; the H2 harness needs a bean (§3.8); `adjust*` needs `@Transactional`; flag writes need an `== 1` guard; nothing in the compiler ties the SQL column names to anything (ITs pin them) | **chosen (D8)** |
| A-mapped (r1's design) | type-checked entity fields; `validate` checks the columns | a failed V2.2.45 becomes 42703 on **every** Location/FLA read on that tenant (putaway, picking, the replenishment job); the edit bumps `location.version`, which needed D5; needs `@JsonProperty(READ_ONLY)` for `/location/create`; Redis-serializer interaction | rejected by D8 |
| A-mapped `insertable=false, updatable=false` (Architect synthesis) | no clobbering, no version bump | the 42703 blast radius is unchanged, which is the deciding risk | rejected; D8 goes one step further |
| B. Read-time COALESCE | single source of truth; sysprop edits propagate | 8 native SQL sites (R6 needs `CREATE OR REPLACE VIEW`) and 7 Java readers; touches the mutation-sensitive `REFILL_ELIGIBILITY_FROM_WHERE` | rejected: blast radius on the hottest SQL |
| C. Copy at creation only | smallest change | fails ACs b, c, e | rejected |
| D. Nullable FLA bounds | no flag | breaks NOT NULL assumptions in R1–R13; B in disguise | rejected |
| E. Side table `location_bound_default` | no `location` ALTER | extra join; a second home for location data; G already removes the D5 motive | rejected |

## 10. Open Questions / Resolved Decisions

### 10.1 Resolved (Nam — not re-opened)
- **D1** Write-through: nullable `default_{lower,middle,upper}bound` on `location`, plus `fix_location_assignment.bounds_inherited boolean NOT NULL DEFAULT false`. Readers are unchanged.
- **D2** The location value is a default only, not a cap (proposal §10.4).
- **D3** Backfill: an FLA triple equal to the tenant's sysprop default (`workstation='DEFAULT' ORDER BY client_id LIMIT 1`; missing or non-integer → 36/60/84) is inherited; everything else is overridden.
- **D4** V2.2.45 bounds its locks with `SET LOCAL lock_timeout`. Value: **5s**, following the precedent at `V2.2.40:13`. *(r1 wrongly called this the first such migration.)*
- **D5** *(moot under D8)* r1 accepted a `location.version` bump on defaults edits. Under D8 the edit writes the defaults with a native UPDATE that leaves `version` alone, so no `StaleObjectStateException` can come from it. The Architect's L-1 had already shown the flowbin put-away/move/replenish paths lock via `LockReads` (refresh, not a version-checked upgrade). The remaining canary is O-3, re-aimed at the new FLA `version+1` writers.
- **D6** Setting defaults is restricted to FLOWBIN locations in both the editor and the API, using `move()`'s check, extracted to `requireFlowbin`.
- **D7** (2026-11-01; settles O-1) **Setting** defaults requires a flowbin. **Clearing** is allowed on any location type, and clearing writes inherited FLAs back to the sysprop default. This drives the order in §3.3: validate, lock, then `requireFlowbin` only when the values are non-null. It also drives AC-16a/b and UI-3b.
- **D8** (2026-11-01) The default columns and `bounds_inherited` are **unmapped**: only native SQL reads or writes them (`@RestResource(exported=false)` / `@Modifying`), plus the two native detail views. This follows the V2.2.40/OutboxMessage pattern. Rationale: with D4's timeout, a 55P03 leaves a tenant running the new jar on the old schema, and mapped columns would turn that into 42703 on every entity read there.
  - The same reasoning applies to `bounds_inherited`, because the replenishment job and the mobile paths read FLA entities.
  - No blocker was found. Its costs are `@Transactional` on `adjust*`, the H2 bean, and the `== 1` guards.
- **D9** (2026-11-01; settles Critic r2 M-2) **Adopt the non-aborting probe.** Before touching any new column, the service runs `select exists (select 1 from information_schema.columns where table_schema = current_schema() and table_name = 'fix_location_assignment' and column_name = 'bounds_inherited')`, per call (§3.2).
  - **Probe false:** create seeds from sysprop exactly as today, with no `lockById`, no native read and no `markInherited`; `adjust*` skips `markOverridden`; move skips the re-seed; the details popup omits the keys.
  - **Edit, clear and reset** return `BusinessException` "unavailable until V2.2.45 applies" (planner's choice, justified in §3.3).
  - **The two admin lists** may fail with 42703.

### 10.2 Resolved by this plan (Nam may override at approval)
- Clear → inherited FLAs revert to the sysprop default. Reset with no location default → sysprop default. Every `adjust*` flips to overridden, even when the value is equal.
- Write-through, reset and move call `requestForItem`, after commit.
- The create lock is the JPQL scalar `lockById` at `PESSIMISTIC_WRITE`, followed by a plain native read under that lock. Never a hand-written `FOR SHARE`/`FOR NO KEY UPDATE` (§3.6).
- FLA triple writes from native SQL bump `version` (§3.2).
- `boundsOutOfDate` and the reset item's enablement and labels (M-2). `SYSTEM_INVALID` on the display path (L-4). Reject `scale() > 4` (L-7). Move-dialog note (L-6).
- POST endpoints and gates as in §3.4, pinned in `Sbdev3017TrancheGateContextTest`.
- Inactive FLAs are written through. No verify script.

### 10.3 Open (non-blocking)
- None. O-1 is closed by D7 and O-2 by §3.6.

### 10.4 Follow-up proposal (not filed — T3, Nam confirms)
- **Capacity hard cap** (relates to SBDEV-1468). *Evidence:* the 53-B06 lanes hold 48 while the FLA max was 84, and D2 keeps the location value a default. *Shape:* `location.capacity` enforced in `adjust*`/create and in the putaway/replenish quantity checks (`MobileReplenishService:727`). *Blast radius:* every putaway/replenish quantity path, plus mobile messaging. *Cost:* about 2–3 days plus a migration. Do it after WineCo has used the defaults for a few weeks.

### 10.5 Adjacent findings (from analysis §7)

| # | Finding | Tier | Destination |
|---|---|---|---|
| D-1 | `ViewDtoService:708` NPE when the UPPER sysprop is absent | T0 | **folded into P1**, AC-18 |
| D-2 | `ReplenishOrderJob:759` `getIntValue(…, 100)` vs `"84"` | T0 | **Proposed P50** (moved from the ticket comment at archival) |
| D-3 | `/fixedAssignment/update` runs three separate `adjust*` (each now in its own transaction; still partial on a mid-way failure) | T1 | **Proposed P51** |
| D-4 | `delete`/`changeActive` lack `@Transactional` (`adjust*` gains it here, as required by D8) | T1/T2 | **Proposed P52** |
| D-5 | stale comments `FixLocationAssignmentController:22-24`, `LocationController:62-63` | T0 | **folded into P1** |
| D-6 | dead verb-inverted actions `storageLocation.js:115-140`, `locationType.js:61-90` | T0 | **Proposed P53** |
| D-7 | doc drift (function map `:108,110`; sysprop catalog `:269-271`; replenishment design `:15,337-339`) | T0 | docs step |

## Verify script

**None.** Every AC can be expressed in JUnit (including the SQL, via Testcontainers) or in Jest, and each one is mutation-checked. I-1 is behavioural, so it is covered by AC-4..10 and AC-17, plus O-4 in production.

## ADR

- **Decision:** store optional per-location default bounds in **unmapped** `location` columns and tag each FLA with an **unmapped** `bounds_inherited`. Only native SQL touches either, and only after a non-aborting `information_schema` probe confirms the columns exist (D9). Write the effective default through to inherited FLAs on create, move, reset and defaults edit. Replenishment readers keep reading the FLA columns.
- **Drivers:** zero change to 15 replenishment reader sites; the location keeps its capacity across FLA delete and re-create; the operator can see and reverse inheritance; a failed migration must not take down the core flows on a tenant.
- **Alternatives considered:** mapped columns (42703 blast radius, version bump); mapped with `insertable/updatable=false` (same blast radius); read-time COALESCE (8 SQL + 7 Java sites); copy at creation (fails b/c/e); nullable FLA bounds; side table.
- **Why chosen:** the smallest blast radius that meets every AC, both at runtime (no reader's bound expression changes) and at migration failure (D9: the core flows take the legacy path; only the two admin lists fail). One invariant, enforced by one resolver plus predicated native UPDATEs. Fail-safe default.
- **Consequences:** nine new repository methods (eight native including the D9 probe, plus the JPQL `lockById`) and two extended native `getDetailView`s, with no compiler link to the columns (ITs pin them); one ~1–12 ms probe per guarded call (D9); `adjust*` becomes transactional, so its trigger runs after commit; an H2 harness bean; FLA `version` bumps from native writes (O-3 canary); sysprop edits do not propagate and show as "out of date"; every future FLA writer must maintain I-1 (O-4 detects drift, not overwrites); rollback needs the roll-forward re-classification (§8); `lock_timeout` follows V2.2.40's 5s.
- **Follow-ups:** the capacity cap proposal (§10.4); D-2/D-3/D-4/D-6 on the ticket; Redis/Caffeine profile per environment is no longer needed by this plan.

## Completeness checklist (wms-feature-plan SKILL.md)

| # | Concern | Considered? |
|---|---|---|
| 1 | All callsites enumerated | ✓ §0.1–0.4 (method and blind spots in §0), each row covered by §3 or marked "—" with a reason |
| 2 | Adjacent shapes | ✓ §3.3 `requireFlowbin` shared with `move()`; the `ViewDtoService:708` sysprop read (D-1, AC-18); `getLocationView` copy-by-name (AC-14b); other auto-seeders: none besides W1c (§0.2) |
| 3 | Backward compatibility | ✓ §6 including "What does NOT change" |
| 4 | Concurrency | ✓ §3.6 (five callers' real lock order, races, residual); AC-17, AC-5b, AC-6b |
| 5 | Multi-tenant | ✓ §7.5; Flyway per tenant (§3.1, prerequisite #5); backfill reads each tenant's own sysprop (AC-1) |
| 6 | Error handling | ✓ §3.4 `{errors}` house style; `BusinessException` / `EntityNotFoundException` / optimistic-lock / `IllegalStateException` paths in §3.2–3.3; `SYSTEM_INVALID` (AC-19) |
| 7 | DB verified | ✓ §2.1, §7.4 (DEV, q.sh); PRD no — MCP down, gated by prerequisites #5/#7/#9 |
| 7 | Observability | ✓ §7.7 O-1..O-4 (log searches + SQL); no new metric or alert (master-data, operator-frequency) |
| 8 | Rollout / migration | ✓ §3.1, §5.1, §8 (deploy order, runbook, rollback + roll-forward SQL) |
| 9 | Test coverage | ✓ §7.2 (named classes and methods), §7.3 mutants, §7.4 manual; no performance target claimed |
| 10 | Cross-version (v1↔v2) | N/A — v1 is reference-only (no client since 2026-10-02) |
| 11 | Alternatives considered | ✓ §9 (8 options, each with a rejection reason) |

## §R Revision log r1 → r2

| Finding | Disposition |
|---|---|
| Arch H-1 (create lock: wrong premise, mode, mechanism) | fixed §3.6 (callers table), §3.2 `lockById` JPQL `PESSIMISTIC_WRITE`, W1c, §10.2, §7.3 mutant |
| Arch M-1 / Critic M3 (header: "first lock_timeout", "cannot deadlock") | fixed §3.1 header (V2.2.40 precedent, 5s, accurate deadlock sentence), D4, ADR; §8 low-traffic window + minutes |
| Arch M-2 (Inherited goes stale after a sysprop edit) | fixed §3.4 `boundsOutOfDate`, §3.7 chip/enablement/label, AC-14, UI-4/5; O-4 widened |
| Arch M-3 (H2 row not N/A) | fixed §3.8, §7.6 #7; `@ColumnDefault` suggestion moot under D8 (unmapped) and replaced by the H2 bean |
| Arch L-1 (D5 overstated) | moot under D8; D5 rewritten |
| Arch L-2 (option F reasoning) / Critic M7 (unmapped option missing) / Arch synthesis (`insertable/updatable=false`) | fixed §9: A+G chosen per D8; both mapped variants rejected for the real reason (42703 blast radius) |
| Arch L-3 / Critic L3 (READ_ONLY vs redis serializer; Caffeine stated as fact) | moot under D8; hedge kept in §3.5 |
| Arch L-4 (sysprop parse reaches new surfaces) | fixed §3.4 `SYSTEM_INVALID`, AC-19, prerequisite #9 |
| Arch L-5 (`:708` fold-in) | fixed §3.4, AC-18 |
| Arch L-6 (moving an Overridden FLA) | fixed §3.7 move note, UI-7 |
| Arch L-7 (precision) | fixed §3.3 step 1 `scale() ≤ 4`, AC-8, UI-2; `compareTo` in AC-14/17 |
| Arch T-1 / T-2 tensions | T-1 → M-2 handling; T-2 → L-6 note |
| Critic M1 (AC-17 shape, not value) | fixed AC-17 (value, both orders, mutant expected red) |
| Critic M2 (§3.6 facts; O-2) | fixed §3.6 from the five callers (both `MobileReplenishService` arms re-read); O-2 closed. The "Hibernate emits FOR UPDATE" premise is **rejected** (two instruments, §3.6); the design is correct either way |
| Critic M4 (`getLocationView` unwired) | fixed §0.3 L5, §4, AC-14b |
| Critic M5 (O-1 not propagated) | fixed via D7: §3.3 order, AC-16a/b, §3.7, UI-3b, mutant |
| Critic M6 (rollback `adjust*`; O-4 blind spots) | fixed §8 step 6 roll-forward SQL, O-4 COALESCE, PM-2 note |
| Critic M8 (D-1 without an AC) | fixed AC-18 + mutant |
| Critic M9 (checklist, Risk/Effort) | fixed: skill rows verbatim (including its duplicated #7); Risk + Effort per phase |
| Critic L1 (M0 SQL) | fixed (`from u`; 4th value counts the direct user→role path, 0 on DEV; resolver is group-based, `RestConfiguration:111`) |
| Critic L2 (text `max(version)`) | fixed prerequisite #5 `success where version='2.2.45'` |
| Critic L4 (PIT unsatisfiable for move) | fixed: AC-10 unit tests for move |
| Critic L5 (manual preconditions as prose) | fixed §7.4, one SQL each including the move source side (re-measured: source 1307, destination 723) |
| Critic L6 (R14 line; singleton count) | R14 → `:200` fixed. Singletons **partly rejected**: DEV re-measured 7 triples / 37 = 28+3+2+**4** singletons, not 5 (§1, §2.1) |
| Critic L7 (UI refusal) | fixed UI-6 |
| Critic L8 (`LocationController` ctor) | fixed §3.4, §4 |
| Critic L9 (gate mutant for class-level) | fixed §7.3 |
| Critic L10 (blind spot on "only master-data writers") | moot under D8 (no Location write); blind spot recorded in §0 |
| Critic OE: AC-2 garbage cases | tests dropped (§7.8); **regex guard kept** — without it a garbage sysprop fails the `::numeric` cast and freezes the tenant's migration |
| Critic OE: AC-3 idempotency · AC-12 FLA READ_ONLY half · 8 additive keys | AC-3 idempotency dropped; AC-12 removed entirely (moot under D8: no entity fields to bind), and AC-13 (cache evict) with the `@CacheEvict`; the 8 (now 10) keys kept (Critic: acceptable) |
| Critic OE: length / trim §0 "— none" | fixed: §0 rows merged, section rules and bullet lists compacted (line count in the final report) |
| Critic missing: write-through on an in-processing replenishment | fixed §3.3: "same as `adjust*`, accepted" |
| Critic open Qs: `MobileReplenishService` arms · Redis vs Caffeine per env · two-connection harness | arms answered §3.6 (lock after create); Redis/Caffeine moot under D8; no harness in `FixLocationAssignmentServiceIT`, so AC-17 is modeled on `BusinessServiceLockRefreshStaleVersionIT` |

### r2 → r3 (Critic delta `reviews/r2-critic-delta.md` + Nam D9)

| Finding | Disposition |
|---|---|
| Δ M-1 (the "drop `flushAutomatically`" mutant is equivalent under Hibernate 6.6.39) | fixed: §3.2 rationale reworded (explicit intent; the `== 1` guard is load-bearing); §7.3 mutant replaced by "`markInherited` before `save` / `FlushMode.COMMIT`" → AC-4b; gate records the old mutant as green; PM-3 prevention rewritten |
| Δ M-2 (D8 failure surface omits `adjust*`, understates auto-create; frozen header) | fixed via **D9**: probe `featureColumnsPresent()` (§3.2) guards create, `adjust*`, move and `getLocationDetails`; edit/clear/reset → `BusinessException` (§3.3, justified); Principle 5, header failure list, PM-1 and §6 now state the true residual: only the two admin lists 42703; AC-20/20b/20c + 2 mutants; per-call cost measured on DEV, H2 query run on 2.3.232 |
| Δ L-1 (reset vs move) | fixed: `resetBounds … and assignedlocation_id = :locationId`, `== 1` else OOLFE; AC-9 assertion, AC-9b, mutant |
| Δ L-2 (5 existing unit tests red by construction) | listed in §7.2 with the re-stubbing. **Premise partly superseded by D9:** Mockito's default `false` probe routes all five down the legacy path, so they stay green unedited; the re-stubbing moves to the new probe-true AC-4/AC-5 methods |
| Δ L-3 (nothing pins `@Transactional`) | fixed: mutant "drop `@Transactional` on `adjustUpperBound`" → AC-5b, which runs without an ambient test tx; §3.2 "no `@Transactional` on new repository methods" |
| Δ L-4 ("readers unchanged" vs R2 +columns) | fixed: Principle 1, §6, §9 A, ADR now say "no reader's bound expression changes" |
| Δ missing: reset never saves the FLA entity | fixed: executor note in §3.3 reset row |
| Δ missing: new optimistic-lock response on `/set*Bound` | fixed: §6 row "under contention" |
| Δ §B, §C, §E, §F, §G (verified, no finding) | no change; §3.8 bean is now pinned by AC-20c, because under D9 it no longer breaks the H2 suite when absent |

### r3 → r4 (Critic verify `reviews/r3-critic-verify.md`)

| Finding | Disposition |
|---|---|
| V M-1 (AC-5b cannot be transaction-free in a class inheriting `BasePostgresIntegrationTest:61`) | fixed AC-5b: **method-level** `@Transactional(propagation = NOT_SUPPORTED)` on `adjust_flipsFlagOnRealPg`, inside `@Nested AdjustCommitted` with committed `TransactionTemplate` seeding and an `@AfterEach` cleanup; the reason is stated; `markOverridden_staleVersion_noRow` stays transactional |
| V M-2 (AC-20c's JdbcTemplate cannot see the uncommitted FLA) | fixed AC-20c: `em.flush()`, then `findBoundsInheritedById` inside the test transaction (tenant persistence unit); the JdbcTemplate is explicitly ruled out (`TestDatabaseConfig:43-45`) |
| V L-1 (`current_schema()` off DEV) | fixed: prerequisite #10, per-tenant `public \| t`. Optional per-tenant WARN log **rejected**: it needs a per-tenant "already warned" set (in-JVM state, against D9's no-cache choice), and prerequisite #10 plus the user-facing "unavailable until V2.2.45" message already make the condition visible |
| V L-2 ("as before SBDEV-3128" overclaims) | fixed: Principle 5, the frozen header and the §3.3 create row now name the residual differences (`adjust*` `@Transactional`, one probe SELECT); "read and write no new column" |
| V L-3 (Principle 5 self-contradiction) | fixed: "except the two admin lists (`getDetailView`)" in Principle 5 and the header |
| V L-4 ("HTTP 500" half right) | fixed §3.3 D9 rationale: reset 500 (`FixLocationAssignmentController:83,107,130,162`), edit/clear 200 `{errors}` with raw SQL (`LocationController:76-78`) |
| V L-5 (stale residue) | fixed: §9 A+G drops "need `flushAutomatically`"; count reconciled in §9 and the ADR to **nine** new repository methods (eight native incl. the probe, plus JPQL `lockById`) + two extended `getDetailView`s, counted from the §3.2 table (r3 ADR said ten, §9 "about 9"); the `FlushMode.COMMIT` alternative mutant deleted |
| V L-6 (post-commit insert window) | fixed: PM-1 and O-4 note that rows inserted after the migration commits by a transaction that did not see it (old pod, probe-false tx) stay Overridden: safe direction; O-4 companion query; a reset fixes them |
| Critic ambiguity risks (3) | resolved by D7, §3.6, and §3.7 labels |

## 9.2 Recommended OMC composition

T3 · ralplan architect → critic (r3 delta) · `wms-tdd-gate` → `wms-plan-executor` per phase, the two repos in sequence · the floor + a `verifier` lane, no verify script · `code-reviewer` ×4 lanes in separate worktrees · migration + repository methods + H2 bean in **one commit** (AC-20c pins the bean).

## §11 Implementation Status (P1 — wms2-api)

**PR:** https://github.com/SiteBossInc/wms2-api/pull/601 → `develop` · branch `feature/SBDEV-3128-location-default-fla-bounds` · base `8171c80a` · ClickUp `pr submitted` (2026-11-02)

| Commit | What |
|---|---|
| `31263d28` | Implementation (V2.2.45, unmapped columns + native SQL, probe, write-through, two endpoints, view keys, H2 bean, D-1, D-5) |
| `7fb22890` | Mirrored `backfill_lowestClientIdWins` (the original survived the drop-`ORDER BY` mutant); validation boundary rows; `requestForItem` verifies |
| `ff4cff9b` | Review round 1: Number-only input + `< 10^13`, narrowed catch, `id` type checks, shared `SyspropService.parseLongOrDefault`, V2.2.45 header wording (comments only), AC-18 merge, AC-14 values, IT cleanup |
| `747b9a39` | 4-decimal values below 0.001 (Double `5.0E-4`) accepted; AC-14 fixture defaults differ from the row |
| `8d82e014` | Fifth-decimal test asserts the invariant (value + scale > 4) |

**Results:** full unit suite @ `747b9a39` 9506 / 0 F / 0 E / 1 skip (develop baseline 9424/0/0/1); all 188 failsafe IT classes @ `ff4cff9b` 1186 / 0 F / 0 E / 23 pre-existing skips; hand mutants in `SBDEV-3128-evidence/mutation-results.md` (all kill except the predicted-equivalent `flushAutomatically`); PIT `FixLocationAssignmentService` — 0 survivors on changed lines. No verify script (every AC is JUnit).

**Reviews** (`SBDEV-3128-evidence/reviews/impl-*.md`): verifier PASS; code review r1–r4 (0 High/Medium, all Lows fixed, tip `8d82e014` reviewed, 0 findings); security APPROVE (4 Lows fixed).

**Deviations from r4:** D-1 removes the dead read instead of a fallback (Nam 2026-11-02); `LocationBoundDefaultsResult` lives in `json/` (no `dto` package); `backfill_nonIntegerSysprop_fallsBack` added; sibling `LocationController` handlers keep `catch (Exception)` (pre-existing, out of scope).

**Landmines found:** a single test cannot pin an `ORDER BY ... LIMIT 1` — PG's scan returned the expected row first; use a mirrored pair. Editing an unmerged migration's comments changes its Flyway checksum and breaks a reused Testcontainers DB (already in memory).

**Not done (by design):** merge, `on dev`, P2 (wms2-web-ui), archive. Worktree kept at `.claude/worktrees/wms2-api/SBDEV-3128` for review feedback.

**Merge (2026-11-02):** #601 merged to `develop` as `4643acf5` (pinned head `8d82e014`, base `53bf025b`); no conflicts, no resolution commits. PR CI `test` (`mvn clean verify -Pci`) green on the graded head; develop push run 41406044623 test+build success; dev serves `develop-4643acf5` (drift false). DEV tenant: V2.2.45 `success=t` 07:51, 4 columns, backfill 1307 inherited / 37 overridden, `current_schema()` public. 24 doc markers flipped. ClickUp `on dev`; UI AC struck → **SBDEV-3991** (P2, wms2-web-ui).

**Dev test (2026-11-02, `develop-4643acf5`, via API — P2 UI is SBDEV-3991):** M1–M6, M8, M9 (7 refusals, each naming its guard, nothing written), M10 ✅; 0.0005 control ✅; M7 ⏸ (delete + re-create not snapshot-restorable; covered by tests); D9 ⏸ (not reproducible on a migrated tenant). Restore proof: all 4 snapshots `restored`. Side effects: FLA versions bumped, 2 stockrecord rows from the M8 moves, 0 outbox, 0 replens. **Finding:** `location.version` did not move on default edits (native UPDATE), so the D5 race does not occur in practice. Next: `archive-plan` after SBDEV-3991, or now for P1 at Nam's call.

## §12 Implementation Status (P2 — wms2-web-ui, SBDEV-3991)

**PR:** https://github.com/SiteBossInc/wms2-web-ui/pull/193 → `develop` · branch `feature/SBDEV-3991-bound-defaults-ui` · base `912c786` · worktree `.claude/worktrees/wms2-web-ui/SBDEV-3991` · ClickUp `pr submitted` (2026-11-02). Tier T2 (triage comment on SBDEV-3991).

| Commit | What |
|---|---|
| `25a7643` | TDD gate: 53 failing specs (UI-1…UI-7), stub `util/boundDefaults.js` + `boundDefaultsDialog.vue` |
| `e61ff93` | Implementation: Storage Locations columns + Set/Clear (D7), `boundDefaultsDialog.vue`, Fixed Locations chip / default line / reset / export column, updateBound + move notes (L-6), store actions `updateBoundDefaults` / `resetBoundsToDefault` (true/false), export `unitLoad` fix, SBDEV-2907 wmsHelpers.js comment |
| `e61f9ab` | Review r1: confirmDialog `detail` prop (F1 Medium), export column order, double-submit guards, reset confirm, 15-significant-digit cap |
| `9432c12` | Review r2: reset disabled under SYSTEM_INVALID (N1 Medium — the r1 refutation of F8 was wrong), digit-check order, template source pins |
| `5a0afa4` | Review r3: robust reset-item pin, shared `hasValidDefault` |
| `f632497` | Review r4: SYSTEM_INVALID check pinned on its own; comments |

**Results:** full Jest 149/149 suites, 2740/2740 (baseline 2660 + gate failures only; Node 18, 4-package overlay). 80 new tests in `test/util/boundDefaults.spec.js`, `test/store/masterData/boundDefaultsActions.spec.js`, `test/components/masterData/location/boundDefaultsUi.spec.js`. Hand mutation harness (PIT cannot reach Jest): 63/63 live mutants killed, 3 retired after later rounds rewrote their targets. SFC templates compile. ⚠ wms2-web-ui CI runs no Jest.

**Reviews** (`SBDEV-3128-evidence/reviews/p2-impl-*`): conformance PASS (U1–U5, UI-1…UI-7 VERIFIED); code review r1–r5, every Medium/Low fixed, r5 APPROVE at tip `f632497`. 4 inline notes posted on #193.

**Deviations from §3.7:** rules extracted to `util/boundDefaults.js`; 3 spec files instead of 6, no rows in the SBDEV-3560 sweep specs; reset asks for confirmation; reset disabled under SYSTEM_INVALID; Clear in the dialog only when the location has defaults.

**Landmines:** `SyspropService.parseLongOrDefault` falls back only on an ABSENT sysprop and throws on an unparseable one; the name misleads. Storage Locations Clear under such a sysprop is a server 500 the UI cannot predict → proposals-register **P48** (deferred; DEV and WineCo PRD parse).

**Not done (by design):** merge, `on dev`, the manual DEV test (PR body has the steps), archive.

**Merge (2026-11-02):** #193 merged to `develop` as `f49105de` via `merge-one.sh --no-pr-check` (pinned head `f6324974`, graded base `912c7864`; develop had not moved since the branch was cut, so no merge-up and no conflict resolution). Grade: full Jest on that head over that base, 149/149 suites, 2740/0. Push run 41457310324 (Docker Image CI) success; `post-merge-verify.sh` ALL PROVEN. Dev deploy verified by hand (no web-ui probe): the served `wsl-wineco.wms.dev.sbo.li` bundle (entry `4aba421.js`, last-modified 13:59:28Z) contains a unique string from each changed file: "Set replenishment defaults", "Clear replenishment defaults", "Updates the assigned SKU", "marks this assignment Overridden", "move with it unchanged", "Use location default", "Bounds reset to default", "too many digits". Pre-existing control strings ("Storage Location Details", "This will download the selected") are also present. Single merge, so no `:develop` tag race. 0 pending-merge markers. ClickUp SBDEV-3991 `on dev`. Next: the manual DEV test (PR body, 8 steps), then `archive-plan`.


**Dev test P2 (2026-11-02, UI `f49105de`, headless browser as the dev test user, `wms-dev-probe` snapshots):** steps 1–7 from #193 ✅ plus a control (an existing confirmDialog caller keeps its download text). Step 3's first try hit another session's wms2-api redeploy (502); the UI failed safely (toast, confirm stayed open, nothing written) and the retry passed. Restore proof: all 3 snapshots `restored` (4 location, 3 FLA, 29 replen rows; `38-A08` put back to 84/108/168 overridden by a guarded SQL update). Side effects: FLA `modified`/`version` moved on 3 rows; 0 replens; 0 stockrecords. Results on SBDEV-3991. Next: `archive-plan`.

## Archive note (2026-11-02)

> Archived after both phases were merged, deployed to dev and dev-tested (P1 via API, P2 via the real UI).
> No verify script existed (every AC is JUnit/Jest), so none was retired.
> Implementation worktrees removed 2026-11-02: wms2-api/SBDEV-3128, wms2-web-ui/SBDEV-3991.
> Findings dispositions: capacity cap → P46; D-1, D-5 fixed in #601; D-7 fixed in the P1 docs pass; D-2 → P50, D-3 → P51, D-4 → P52, D-6 → P53; unparseable-sysprop 500 → P48; M7 and D9 not run on dev (covered by unit tests / IT, not snapshot-restorable); per-tenant PRD prerequisites #5/#9/#10 for the 5 non-WineCo tenants: owner = whoever promotes to PRD (devops, with Nam).

