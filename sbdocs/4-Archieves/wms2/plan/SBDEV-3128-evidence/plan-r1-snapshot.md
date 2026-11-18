---
title: "Location-level default Min / Hysteresis / Max for Fixed Location Assignments"
ticket: "SBDEV-3128"
ticket_url: "https://app.clickup.com/t/868kxn4b5"
type: "feature"
priority: "high"
status: "draft — pending ralplan review"
project: ["wms2"]
version: "v2"
requester: "WineCo ST#1154 / ST#1505 (Michelle Cervone; Adam Petersen)"
created: "2026-11-01"
updated: "2026-11-01"
tier: "T3"
db_verified: "true — DEV dev_wh01_om1 2026-11-01; PRD pending (wsl-wineco-prd MCP unreachable)"
revision: "r1 (planner, ralplan round 1)"
base_commit: "1b421d08 (wms2-api origin/develop) · 912c786 (wms2-web-ui origin/develop)"
repos: ["v2/wms2-api (P1)", "v2/wms2-web-ui (P2)"]
related:
  - "[[SBDEV-3128-evidence/analysis]]"
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

**Ticket:** [SBDEV-3128](https://app.clickup.com/t/868kxn4b5) · `in development` · priority high · **Tier T3** — Flyway migration with a data backfill on every tenant, plus a new cross-screen write path.
**Repos:** `v2/wms2-api` (P1, one PR) → `v2/wms2-web-ui` (P2, one PR). Branch `feature/SBDEV-3128-location-default-fla-bounds` in both, off freshly-fetched `origin/develop`; PRs into `develop` only.
**Evidence base:** `SBDEV-3128-evidence/analysis.md` (file:line, DEV counts). This plan cites code at `1b421d08`; every snippet below was re-read with `git show origin/develop:<path>` on 2026-11-01 unless marked *(analysis)*.

---

## RALPLAN-DR summary

**Mode:** DELIBERATE (migration + backfill + new write path into replenishment inputs).

**Principles**
1. **Readers stay byte-identical.** Replenishment math reads `fix_location_assignment.{lower,middle,upper}bound` at 15 sites. None of them change.
2. **One invariant, every writer.** *inherited ⇒ triple = effective default (location ?? sysprop) at last write.* Create, move, reset, defaults-edit and clear all go through one resolver.
3. **Fail safe on ambiguity.** Unknown provenance = overridden (`DEFAULT false`). A wrong "inherited" tag would let a defaults edit overwrite hand tuning; a wrong "overridden" tag costs one click.
4. **Gate the new route explicitly.** `LocationController` is not in `FunctionGuardInterceptor.GUARDED`, so a handler without the annotation is silently open.
5. **Entity and migration ship together.** `ddl-auto=none` turns a missing column into 42703 on every Location/FLA read.

**Decision drivers (top 3):** (1) zero change to the 8 native-SQL + 7 Java replenishment readers; (2) the location must keep its capacity across FLA delete/re-create (5 auto-create callers); (3) the operator must see and reverse inheritance (ACs e, c, d).

**Options:** A write-through (chosen, D1) · B read-time COALESCE · C copy-at-creation only · D nullable FLA bounds — see §9.

---

## 0. Affected sites

**Method:** `git grep` G1–G8 on `origin/develop` *(analysis §0.1)*, re-run for G1/G4 on 2026-11-01. **Blind spots:** method references (`FixLocationAssignment::getUpperbound` — found by hand at `MobileReplenishService:451`), `select *`/`fla.*` wildcard readers (auto-include new columns; listed as R14), dynamically built UI URLs (none seen). oms-laravel-api read at local HEAD only: 0 relevant hits.

### 0.1 Readers — all UNCHANGED (write-through keeps the stored triple correct)

| # | Site | Quoted | Phase |
|---|---|---|---|
| R1 | `FixLocationAssignmentRepository:173` `REFILL_ELIGIBILITY_FROM_WHERE` | `" AND stockunit.amount < fla.lowerbound "` | — |
| R2 | `FixLocationAssignmentRepository:217-233` `getDetailView` | `"fla.lowerbound as minAmount, " "fla.middlebound as hysteresis, " "fla.upperbound as maxAmount, "` | P1 (additive columns) |
| R3 | `ReplenishorderRepository:243,249` | `"AND stockUnit.amount >= fixAssignment.upperbound "` | — |
| R4 | `ReplenishorderRepository:303,326` | `"AND fixAssignment.upperBound > su.amount "` | — |
| R5 | `ReplenishmentMonitorViewRepository:104,110` | `"f.upperbound AS fix_assignment_upperbound "` | — |
| R6 | `V2.2.43…flowbin_monitor_view:45-47` → `ViewDtoService:1432-1434`, `ReportService:263-265` | `COALESCE(round(f.lowerbound), (0)::numeric) AS lower_bound` | — |
| R7 | `ReplenishOrderJobService:183,185` | `BigDecimal middleBound = fixedLocationAssignment.getMiddlebound();` | — |
| R8 | `ReplenishmentOrderMaintenanceService:1002-1008` | `if (assignment != null && assignment.getUpperbound() != null) { return assignment.getUpperbound(); }` | — |
| R9 | `ReplenishGeneratorService:99,123` | `ass.getUpperbound().subtract(stockunitList.get(0).getAmount())` | — |
| R10 | `ViewDtoService:805-807` | `fla.getUpperbound().compareTo(BigDecimal.ZERO) > 0` | — |
| R11 | `ViewDtoService:1382-1387` | `result.getFix_assignment_upperbound()` | — |
| R12 | `MobileReplenishService:447-451` | `.map(FixLocationAssignment::getUpperbound)` | — |
| R13 | `MobileReplenishService:727` | `order.setAmountDestinationMax(fixOpt.orElseThrow().getUpperbound());` | — |
| R14 | `FixLocationAssignmentRepository:61,198` | `select * from fix_location_assignment f …` / `SELECT DISTINCT fla.*` | auto (new column materializes) |
| R15 | v1-to-v2 onboarding `V1.0.02`, `V1.2.04`, `V1.2.99*` | `coalesce(round(f.lowerbound), 0)` | — (not on boot/IT path) |

Sysprop-default readers: S1 `FixLocationAssignmentService:86-88` (**the seeding point**, P1) · S2 `ReplenishmentOrderMaintenanceService:1006-1008` · S3 `ReplenishOrderJob:759` (defaults to 100 → D-2) · S4 `ViewDtoService:708` (NPE if absent → D-1). S2–S4 unchanged.

### 0.2 Writers / FLA lifecycle

| # | Site | Quoted (re-read 2026-11-01) | Change | Phase |
|---|---|---|---|---|
| W1 | `FixLocationAssignmentService:83-107` create | `BigDecimal lowerBound = BigDecimal.valueOf(parseSyspropLong(…LOWER_BOUND_KEY, …VALUE));` | seed from locked location default, else sysprop; `boundsInherited=true` | P1 |
| W1c | 5 callers: `StockunitService:560` (`transferStock`), `MobileMoveUnitloadService:646` (`scanDestination`), `MobilePutAwayService:640` (`storeBoxOnLocation`), `MobileReplenishService:309,1109` (via `fulfillMultipleUnitLoadsTx`) | `fixLocationAssignmentService.createFixedLocationAssignment(destinationLocation, …)` | none. All 5 run under `@Transactional(value = "tenantTransactionManager", …)` (method: awk enclosing-method + 4 lines above; blind spot: a future self-invocation bypassing the proxy) | — |
| W2 | `:109-179` `move()` | `fixedLocationAssignment.setAssignedlocationId(destination.getId());` (`:167`) | if inherited, re-seed from destination's effective default before `:168` save | P1 |
| W3 | `:181-233` `adjust{Lower,Middle,Upper}Bound` (no `@Transactional`) | `fixedLocationAssignment.setLowerbound(BigDecimal.valueOf(newAmount));` | + `setBoundsInherited(false)` | P1 |
| W4 | Controller `POST /update` (Map) | `if (reqMap.get("lowerBound") != null) fla = …adjustLowerBound(…)` | inherits W3; no UI caller | — |
| W5 | Controller `/set{Upper,Middle,Lower}Bound` | `fixLocationAssignmentService.adjustUpperBound(id, value);` | inherits W3; UI `store/masterData/fixedLocation.js:137,157,177` | — |
| W6 | `:235-287` `delete()` | `fixLocationAssignmentRepository.deleteById(…)` | none — location default survives the delete (the point of the feature) | — |
| W7 | `:289-299` `changeActive` | `setActive(!oldValue)` | none | — |
| W8 | `demo-datasets/meridian/fixtures.sql:86-88` | column-listed INSERT `ON CONFLICT … SET lowerbound=EXCLUDED.lowerbound` | none — new column takes `DEFAULT false` | — |
| W9 | **NEW** `FixLocationAssignmentService.updateLocationBoundDefaults` / `resetBoundsToLocationDefault` | — | §3.3 | P1 |

### 0.3 Location create / update / serialize

| # | Site | Effect | Phase |
|---|---|---|---|
| L1 | `LocationService:66-91` `createLocation` | defaults NULL | — |
| L2 | `LocationController:64-82` `/create` → `createLocationFromRequest(@RequestBody Location)` — saves the bound entity | mass-assignment hole for new fields → `@JsonProperty(access = READ_ONLY)` | P1 |
| L3 | `LocationService:186-211` `updateLocation` | copies 13 named fields; ignores new ones | — |
| L4 | `LocationService:244+` `getLocationDetails` → `GET /v3/location/locationDetailsById/{id}` | + 3 nullable keys | P1 |
| L5 | `LocationRepository:278-290` `getDetailView` → `GET /v3/location/detailView` | + 3 nullable columns | P1 |
| L6 | `FileImportController:165-314` `POST /v3/import/locations` | NULL; out of scope | — |
| L7 | `UtilRestController:878-930` initDB | NULL | — |
| L8 | native `l.*` entity queries (e.g. `LocationRepository:304`) | auto | — |
| L9 | SDR `GET /api/location/**` (`LocationRepository:20` exported; POST/PUT/PATCH withdrawn `RestConfiguration:798-808,866-868`) | +3 read-only fields | — |
| L10 | **NEW** `LocationRepository.lockDefaultBoundsById` (native `FOR SHARE`) | must carry `@RestResource(exported = false)` — the repository is SDR-exported | P1 |

### 0.4 UI (wms2-web-ui @ 912c786)

| # | File | Quoted | Change | Phase |
|---|---|---|---|---|
| U1 | `components/masterData/location/fixedLocations/fixedLocation.vue:237-239`, menu `:110-125`, export `:159-160,379` | `{ text: 'Min Amount', value: 'minAmount' … }` | Inherited/Overridden chip column; default triple + source in details; "Use location default" menu item | P2 |
| U2 | `fixedLocations/updateBound.vue:63-70` | `dispatch('masterData/fixedLocation/setUpperBound', data)` | note "Saving marks this assignment Overridden" | P2 |
| U3 | `store/masterData/fixedLocation.js:55,135-195` | `$axios.post('/fixedAssignment/setUpperBound', {id, value})` | + `resetBoundsToDefault` action | P2 |
| U4 | `components/masterData/location/storageLocations/storageLocation.vue:92,223-231` | `<!-- … @click="showEditDialog(item)" v-if="isSuperAdmin" -->` | 3 default columns + flowbin-only "Set replenishment defaults" item + new dialog | P2 |
| U5 | `store/masterData/storageLocation.js:115-140` | `$put('/location/create')`, `$post('/location/update')` | do NOT reuse (dead, verb-inverted → D-6); add new `updateBoundDefaults` action | P2 |
| U6 | `components/reports/flowbinReport.vue:84-85` | `{{ item.lowerBound }} / …` | none | — |
| U7 | `util/appMenuList.js:87,89` | `fn: 'WEB_UI_VIEW_STORAGE_LOCATION'` / `'WEB_UI_VIEW_FIXED_ASSIGNMENT'` | none (gating source) | — |
| U8 | wms2-mobile-ui `OrderHeaderBlock.vue:106` | `/replenish/fixedLocationUpperBound/…` | none (reads FLA upper, kept correct by write-through) | — |

---

## 1. Problem Statement

WineCo (ST#1154, ST#1505): the 53-B06 roller lanes physically hold **48 bottles**, but their FLAs carried **36/60/84** (Min/Hysteresis/Max) — Max 84 is 75% over physical capacity, so replenishment over-pulls. Every FLA is seeded from the sysprop triple and nothing location-specific (`FixLocationAssignmentService:86-88`). Tuning lives on the FLA, so it dies with the FLA.

Quantified on DEV `dev_wh01_om1` (2026-11-01):
- **1307 / 1344** FLAs (97.2%) sit at the hardcoded sysprop triple 36/60/84 — never tuned.
- FLA ↔ location is **1:1**: UNIQUE `uk_qakwvmdhdymic54v3dgie46wa` on `assignedlocation_id` and UNIQUE on `itemdata_id`. The bounds follow the *assignment*, not the *location*.
- 5 auto-create call sites (W1c) re-create FLAs from sysprops after a delete or move, discarding any per-location tuning.
- `53-B06` (id 3223189, flowbin) has no FLA on DEV today; the next auto-create would get 36/60/84 again.

**Ticket ACs:** (a) storage locations optionally define Min/Hyst/Max defaults · (b) FLAs inherit them · (c) users override per FLA · (d) explicit override wins · (e) UI shows inherited vs overridden · (f) SKU-specific FLA behavior stays · (g) validation consistent with current rules · (h) existing assignments handled explicitly.

---

## 2. Current Architecture

- **Create** (W1): sysprop triple via `parseSyspropLong` → `syspropService.getSysvalue(key)` → `SyspropRepository:30` `"select sysvalue from los_sysprop where syskey = :syskey and workstation = 'DEFAULT' order by client_id LIMIT 1"`. Not the 4-tier cascade. Absent → `Long.parseLong(defaultValue)`; present → **`Long.parseLong(value)` with no trim** (`:301-307`) — a non-integer or space-padded value throws `NumberFormatException`, so no FLA can ever have been seeded from one.
- **Edit** (W3/W5): one bound per request; validation effectively `lower ≤ middle < upper`, on `double`, no non-negativity check; order-dependent (raise upper first). Errors return HTTP 200 `{errors}`.
- **Consumers** R1–R13: refill eligibility `amount < lowerbound`; job `amount >= middle` → skip, `required = upper − amount`; cancel/shortage on upper; monitors; mobile max.
- **Move** (W2): requires a flowbin destination — `:121` `if (!locationType.getSltname().equals(WmsConstants.STORAGE_LOCATION_TYPE_BOX_RESTRICTION_FLOWBIN)) { throw new BusinessException("Can't move fix assignment. Destination is not a flowbin!"); }` with `locationType` from `locationTypeRepository.findById(destination.getTypeId())`. Constant = `"flowbin"` (`WmsConstants:969`).
- **No storage-location edit is reachable from the UI** (U4 commented out; U5 undispatched and verb-inverted, pinned as §0.B in `Sbdev3017TrancheGateContextTest`).
- **Authz:** `FixLocationAssignmentController` class-level `@RequiresFunction(WEB_UI_VIEW_FIXED_ASSIGNMENT)` (pinned `Sbdev3017TrancheGateContextTest:157-163`). `LocationController` is method-level only (`:49,55,64,86,108,130`) and `grep -c 'LocationController.class' FunctionGuardInterceptor.java` = **0**.
- **Locking:** `Location`/`FixLocationAssignment` extend `AbstractBaseEntity` (`@Version`). `LocationRepository.findByIdForUpdate` = `@Lock(PESSIMISTIC_WRITE)`. SBDEV-3418 first-touch rule (`LocationRepository:26-46` javadoc): an out-of-band `location` UPDATE between an unlocked entity read and the lock upgrade raises `StaleObjectStateException`.
- **Replenishment trigger:** `ReplenishmentMaintenanceTrigger.requestForItem` runs `afterCompletion(STATUS_COMMITTED)` in `REQUIRES_NEW` when a transaction is active, else now (`:85-95`).
- **Flyway:** head `V2.2.44__parcel_monitor_view_manifest_location.sql`. `StartupFlywayMigrator` runs per tenant; one tenant's failure "never blocks the app or the other tenants" (`:53`). Its connection is **unbounded** — `tenantTransactionManager`'s `SET LOCAL lock_timeout` (SBDEV-3250, `LockTimeoutHibernateJpaDialect`) never applies to it (V2.2.26 header `:113-118`).

### 2.1 DB evidence (DEV `dev_wh01_om1`, 2026-11-01, `wms-dev-probe` q.sh, SELECT only)

| Query | Result |
|---|---|
| `select count(*) from fix_location_assignment` | 1344 (all active) |
| `… where not (lowerbound <= middlebound and middlebound < upperbound)` | 0 |
| `… where lowerbound=36 and middlebound=60 and upperbound=84` | **1307** |
| `… where not (lowerbound=36 and middlebound=60 and upperbound=84)` | **37** (28×12/24/36, 3×84/108/168, 6 singletons) |
| `select syskey, sysvalue, client_id, workstation from los_sysprop where syskey like 'FIX_LOCATION_ASSIGNMENT_DEFAULT_VALUE_%_BOUND'` | 36 / 60 / 84 at `client_id=0`, `DEFAULT` |
| `select indexname, indexdef from pg_indexes where tablename='fix_location_assignment'` | UNIQUE on `assignedlocation_id` and on `itemdata_id` |
| FLAs by location type | flowbin 2068 locations / 1344 FLAs; every other type 0 |
| `select count(*) from location` | 2,750 |
| `select max(version) from flyway_schema_history` | 2.2.44 (installed_rank 45) |
| M0 authz population (§7.4) | 44 hold STORAGE_LOCATION, 44 hold FIXED_ASSIGNMENT, 0 hold only one |
| FLA `created` by month | 2 (Aug), 3 (Jun), 3 (May) — creates are rare |

PRD: not measured (MCP `wsl-wineco-prd` connection timeout). Prereq #1/#7 re-run there before deploy.

---

## 3. Design

### 3.1 Migration `V2.2.45__location_default_fla_bounds.sql`

Version collision check is a prerequisite (§5.1 #1). Full text:

```sql
-- SBDEV-3128: optional per-location default Min/Hysteresis/Max for fixed location assignments.
-- Plan: sbdocs/1-Projects/wms2/plan/SBDEV-3128-location-default-fla-bounds.md
-- ⚠ THE NUMBERS IN THIS HEADER FREEZE ON FIRST APPLY (Flyway's CRC32 covers comments).
--
-- WHAT. location gains a nullable default triple (all-or-none, CHECKed). fix_location_assignment gains
-- bounds_inherited; true means "this row's triple equals its location's effective default and follows it".
-- The bound columns themselves are untouched; every replenishment reader keeps reading them.
--
-- WHY lock_timeout (FIRST migration in this repo to set it; V2.2.00's "SET lock_timeout = 0" is pg_dump
-- preamble, i.e. unbounded). Both ALTERs take ACCESS EXCLUSIVE. The Flyway connection is unbounded
-- (V2.2.26 header: tenantTransactionManager's SET LOCAL never reaches StartupFlywayMigrator). On a
-- rolling deploy, a replica still serving traffic can hold a lock on location; an unbounded wait then
-- queues EVERY later reader of location behind this ALTER (putaway, picking, replenishment all read it).
-- 10s bounds that. On timeout (SQLSTATE 55P03) the whole script rolls back (transactional DDL, no
-- history row), StartupFlywayMigrator counts the tenant as failed and boots the others, and the next
-- boot retries. Until then that tenant raises 42703 on Location/FLA reads -> restart the pod (runbook §8).
-- SET LOCAL scopes to this migration's transaction only.
--
-- LOCK ORDER location -> fix_location_assignment, the same order the application takes (§3.6), so the
-- migration cannot deadlock against a live transaction.
--
-- BACKFILL mirrors parseSyspropLong -> getSysvalue -> SyspropRepository.findSysvalueBySyskey exactly:
-- workstation='DEFAULT', client-blind, lowest client_id wins. A value Long.parseLong would reject
-- (non-integer, padded, absent) falls back to 36/60/84 -- Java would have thrown or used the same
-- fallback, so no FLA can have been seeded from it. FLAs seeded under an older sysprop value classify
-- as OVERRIDDEN: fail-safe (a defaults edit never overwrites them). DEV 2026-11-01: 1307 -> inherited,
-- 37 stay overridden. No CHECK on the FLA bound columns: PRD is unmeasured and a failing CHECK
-- freezes the tenant (V2.2.34 header).

SET LOCAL lock_timeout = '10s';

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
            OR (default_lowerbound  IS NOT NULL
                AND default_middlebound IS NOT NULL
                AND default_upperbound  IS NOT NULL
                AND default_lowerbound  >= 0
                AND default_lowerbound  <= default_middlebound
                AND default_middlebound <  default_upperbound));
    END IF;
END $$;

-- false = OVERRIDDEN = fail-safe for rows written by paths that never set it (raw SQL, fixtures).
ALTER TABLE public.fix_location_assignment
    ADD COLUMN IF NOT EXISTS bounds_inherited boolean NOT NULL DEFAULT false;

WITH d AS (
    SELECT
        COALESCE((SELECT CASE WHEN sysvalue ~ '^[+-]?[0-9]{1,18}$' THEN sysvalue::numeric END
                    FROM public.los_sysprop
                   WHERE syskey = 'FIX_LOCATION_ASSIGNMENT_DEFAULT_VALUE_LOWER_BOUND'
                     AND workstation = 'DEFAULT'
                   ORDER BY client_id
                   LIMIT 1), 36) AS lo,
        COALESCE((SELECT CASE WHEN sysvalue ~ '^[+-]?[0-9]{1,18}$' THEN sysvalue::numeric END
                    FROM public.los_sysprop
                   WHERE syskey = 'FIX_LOCATION_ASSIGNMENT_DEFAULT_VALUE_MIDDLE_BOUND'
                     AND workstation = 'DEFAULT'
                   ORDER BY client_id
                   LIMIT 1), 60) AS mi,
        COALESCE((SELECT CASE WHEN sysvalue ~ '^[+-]?[0-9]{1,18}$' THEN sysvalue::numeric END
                    FROM public.los_sysprop
                   WHERE syskey = 'FIX_LOCATION_ASSIGNMENT_DEFAULT_VALUE_UPPER_BOUND'
                     AND workstation = 'DEFAULT'
                   ORDER BY client_id
                   LIMIT 1), 84) AS up
)
UPDATE public.fix_location_assignment f
   SET bounds_inherited = true
  FROM d
 WHERE f.lowerbound  = d.lo
   AND f.middlebound = d.mi
   AND f.upperbound  = d.up
   AND f.bounds_inherited = false;
```

Notes:
- **Regex deviation from the analysis** (`'^\s*-?[0-9]+\s*$'` + `btrim`): `Long.parseLong` accepts a leading `+`, rejects whitespace, and overflows past 18-19 digits. The stricter pattern mirrors it, so a padded `' 36 '` → fallback 36, which is what Java would *not* have seeded (it threw). Either way the classification is fail-safe; the stricter one is exact. **Executor: confirm the three syskey string literals against `WmsConstants.SYSTEM_PROPERTY_FIX_LOCATION_ASSIGNMENT_DEFAULT_VALUE_{LOWER,MIDDLE,UPPER}_BOUND_KEY` before committing** (the IT in AC-2 pins them).
- Catalog-only cost: nullable and constant-default ADD COLUMN are metadata-only on PG ≥ 11. The CHECK validates over all-NULL rows (2,750 on DEV). The UPDATE touches ~1307 FLA rows.
- Assumes Flyway's default `group=false` (one transaction per migration). If grouped, `SET LOCAL` would also bound later migrations in the group — harmless.

### 3.2 Entities

```java
// Location.java (+ import com.fasterxml.jackson.annotation.JsonProperty)
@Column(name = "default_lowerbound", columnDefinition = "numeric(17,4)")
@JsonProperty(access = JsonProperty.Access.READ_ONLY)
private BigDecimal defaultLowerbound;          // + defaultMiddlebound, defaultUpperbound; all nullable, no initializer

// FixLocationAssignment.java
@Column(name = "bounds_inherited", nullable = false)
@JsonProperty(access = JsonProperty.Access.READ_ONLY)
private Boolean boundsInherited = Boolean.FALSE;
```

`READ_ONLY` closes the L2 mass-assignment (`/v3/location/create` saves the bound entity) and any future SDR re-exposure. The only writers are the service methods in §3.3. Getter/setter style follows each entity's existing fields.

### 3.3 Service (`FixLocationAssignmentService`)

Home: this service already injects `LocationService`, `LocationRepository`, `LocationTypeRepository`, `SyspropService`, `ReplenishmentMaintenanceTrigger` (ctor `:50-80`); putting the write-through in `LocationService` would create a constructor-injection cycle.

**The single invariant (I-1):** *for every FLA with `boundsInherited = true`, its (lower, middle, upper) = the effective default (location triple if non-null, else the sysprop triple) as of the last write to either the FLA or its location.* Sysprop edits are not written through (today's behavior; R-5).

```java
private record Bounds(BigDecimal lower, BigDecimal middle, BigDecimal upper) {}

/** Sysprop tier, exactly as create() reads it today (parseSyspropLong; NumberFormatException on garbage, unchanged). */
private Bounds systemDefaultBounds();

/** location triple if non-null else systemDefaultBounds(). Pure. */
private Bounds effectiveDefaultBounds(BigDecimal l, BigDecimal m, BigDecimal u);

/** Scalar native read under FOR SHARE (L10); materializes no Location entity -> no SBDEV-3418 upgrade. */
private Bounds lockAndResolveDefaultBounds(Long locationId);

private void applyInherited(FixLocationAssignment fla, Bounds b);   // sets triple + boundsInherited=true

/** Same check move() uses at :121, extracted so both call one helper. */
private void requireFlowbin(Location location, String message) throws BusinessException;

public FixLocationAssignment createFixedLocationAssignment(Location storageLocation, Itemdata itemData);
    // signature unchanged; replaces :86-88 with applyInherited(fla, lockAndResolveDefaultBounds(storageLocation.getId()))

@Transactional(value = "tenantTransactionManager", rollbackFor = {BusinessException.class, FacadeException.class})
public void move(Long fixedLocationAssignmentId, Long destinationId);
    // after :167 setAssignedlocationId: if TRUE.equals(boundsInherited) applyInherited(fla, lockAndResolveDefaultBounds(destination.getId()))
    // :121 check becomes requireFlowbin(destination, "Can't move fix assignment. Destination is not a flowbin!") — message unchanged

public FixLocationAssignment adjust{Lower,Middle,Upper}Bound(Long id, double newAmount);
    // + fla.setBoundsInherited(false) before save; validation untouched

@Transactional(value = "tenantTransactionManager", rollbackFor = {BusinessException.class, FacadeException.class})
public FixLocationAssignment resetBoundsToLocationDefault(Long fixedLocationAssignmentId) throws BusinessException;
    // findById orElseThrow EntityNotFoundException; applyInherited(fla, lockAndResolveDefaultBounds(fla.getAssignedlocationId()));
    // save; replenishmentMaintenanceTrigger.requestForItem(itemdataId)

@CacheEvict(value = "locations", allEntries = true)
@Transactional(value = "tenantTransactionManager", rollbackFor = {BusinessException.class, FacadeException.class})
public LocationBoundDefaultsResult updateLocationBoundDefaults(Long locationId, BigDecimal l, BigDecimal m, BigDecimal u)
        throws BusinessException;
```

`updateLocationBoundDefaults` steps, in order:
1. **Validate** (before any read): all three null (= clear) or all three non-null; when set, `l ≥ 0`, `l ≤ m`, `m < u` via `compareTo` (same relation as W3, plus non-negativity, matching the DB CHECK). Partial → `BusinessException("Min, Hysteresis and Max must all be set, or all be empty")`.
2. `Location loc = locationRepository.findByIdForUpdate(locationId).orElseThrow(EntityNotFoundException)`.
3. `requireFlowbin(loc, "Replenishment defaults can only be set on flowbin locations")` (D6; also for clear — see O-1).
4. Set the three fields; `locationRepository.save(loc)` (bumps `location.version` — D5).
5. `fixLocationAssignmentRepository.findByAssignedlocationId(locationId)` (≤ 1 row, UNIQUE). If present and `TRUE.equals(boundsInherited)`: `applyInherited(fla, effectiveDefaultBounds(l, m, u))`, save, `requestForItem(fla.getItemdataId())`. Overridden or absent → nothing.
6. Return `LocationBoundDefaultsResult(id, name, minAmount, hysteresis, maxAmount, inheritedAssignmentsUpdated ∈ {0,1})`.

Inactive FLAs are written through too (they reactivate with the right triple). Re-calling with the same triple is idempotent apart from the version bump.

**Adopted analysis recommendations** (§10.2): clear → inherited FLAs revert to sysprop (I-1); reset with no location default → sysprop; every `adjust*` flips to overridden, even when the value equals the default; write-through triggers `requestForItem` post-commit.

### 3.4 API

| Endpoint | Gate | Request | Response |
|---|---|---|---|
| **NEW** `POST /v3/location/updateBoundDefaults` (`LocationController`) | **method-level** `@RequiresFunction(WmsConstants.FunctionEnum.WEB_UI_VIEW_STORAGE_LOCATION)` — mandatory, the class is not GUARDED | `{id, minAmount, hysteresis, maxAmount}` — numbers, or all three `null` to clear | 200 `LocationBoundDefaultsResult` · 200 `{errors:[…]}` on `BusinessException`/not-flowbin/validation (house style, `LocationController:66-81`) |
| **NEW** `POST /v3/fixedAssignment/resetBoundsToDefault` | class-level `WEB_UI_VIEW_FIXED_ASSIGNMENT` | `{id}` | 200 `getMessageResponse(…, "Updated")` · 200 `{errors}` |
| `GET /v3/fixedAssignment/detailView` | unchanged | — | 9 keys + `boundsInherited`, `locationDefaultMinAmount`, `locationDefaultHysteresis`, `locationDefaultMaxAmount` (nullable, from `l.default_*`), `defaultSource` (`LOCATION`/`SYSTEM`), `defaultMinAmount/Hysteresis/MaxAmount` (effective) — additive |
| `GET /v3/location/detailView`, `/locationDetailsById/{id}` | unchanged | — | + `defaultMinAmount`, `defaultHysteresis`, `defaultMaxAmount` (nullable) |
| `/set*Bound`, `/update` | unchanged | same | same; side effect: flips to overridden |

POST for both: the UI and API verbs agree, and the §0.B inversion is not extended. Both paths get a `row(...)` in `Sbdev3017TrancheGateContextTest` (the FLA one inside the C1-C7 loop array). Number parsing in the new handler: `new BigDecimal(value.toString())`, not via `double`.

`FixLocationAssignmentDetailView` projection gains `getBoundsInherited()` and three `getLocationDefault*()`; `defaultSource` and the effective triple are computed once per request in `ViewDtoService:905` (sysprop read once, not per row).

### 3.5 Cache

- `locations` (per-replica Caffeine, max 2000, 5-min `expireAfterWrite`; `wms2-caching-strategy.md`) holds Location entities via `LocationService.getByName:100`. `updateLocationBoundDefaults` evicts `allEntries` on the serving replica only.
- **Correctness does not depend on the cache**: `lockAndResolveDefaultBounds` reads the row by id with a native query and never reads the passed-in entity, so a stale cached Location on another replica cannot seed an FLA. All 5 create callers resolve the destination with `locationRepository.findByName/findById`, none with `getByName` *(analysis §2.5)*.
- Residual: another replica's `getByName` can show stale `default_*` for ≤ 5 min. No reader of those fields goes through it. Accepted.
- `sysprops` (2-min TTL) unchanged. No new cache.

### 3.6 Locking & concurrency

**Order is Location → FLA everywhere** (migration included, §3.1):

| Path | Location lock | FLA lock |
|---|---|---|
| defaults edit | `findByIdForUpdate` (PESSIMISTIC_WRITE) | `@Version` on save |
| create | `FOR SHARE` scalar read (L10); callers typically already hold PESSIMISTIC_WRITE via `transferUnitLoadToLocation(…, ignoreLock=false)` *(analysis §2.6)* | insert |
| move | `FOR SHARE` scalar read on destination | `@Version` |
| reset | `FOR SHARE` scalar read | `@Version` |
| adjust* | none | `@Version` |

- **Create-vs-edit race (closed).** Without the lock: create reads the old default, the edit commits and finds no FLA, create commits a stale "inherited" FLA → I-1 broken. `FOR SHARE` conflicts with the edit's `FOR UPDATE`, so one waits for the other. It holds until commit only because all 5 callers are transactional (W1c). **Guard for future callers:** the unit test asserts nothing; the IT `create_blocksBehindDefaultsEdit` (§7.2) proves the serialization on real PG.
- **Residual: share→update upgrade deadlock.** If a create's caller takes `FOR SHARE` *before* its own PESSIMISTIC_WRITE on the same flowbin, two concurrent creates there could deadlock. PG detects it and aborts one (`40P01`, retryable), and the same pair already collides on UNIQUE `assignedlocation_id`. Accepted; **architect: confirm the lock order in the 5 callers** or switch the scalar read to `FOR NO KEY UPDATE`, if that is what Hibernate emits for PESSIMISTIC_WRITE.
- **D5 — version bump (accepted, documented).** `updateLocationBoundDefaults` saves the Location → `location.version++`. A concurrent putaway/replenish/move that read that flowbin's Location entity unlocked and then upgrades via `findByIdForUpdate` throws `StaleObjectStateException` (the SBDEV-3418 pattern). Today the only Location writers are master-data paths (`LocationService:89,148,175,208`, `FileImportController:314`, initDB); this adds an operator-frequency writer. Trigger needs: same flowbin, same moment as an operator's defaults edit. It fails loudly and the mobile flow is retryable. Documented in the method javadoc and in `wms2-replenishment-design.md` (docs step). Observability §7.6 O-3.
- `adjust*` stay non-transactional (D-4, pre-existing); their trigger runs inline.

### 3.7 UI (P2, wms2-web-ui)

**Storage Locations** (`storageLocation.vue`, `store/masterData/storageLocation.js`):
- 3 columns *Default Min / Default Hyst. / Default Max* (blank when null).
- Row menu "Set replenishment defaults", shown only when the row's location type is `flowbin` (D6).
- New `components/masterData/location/storageLocations/boundDefaultsDialog.vue`: three numeric fields; client-side `0 ≤ min ≤ hyst < max`; **Clear** button (sends three nulls); note "Updates the assigned SKU's bounds if it is set to Inherited". Server `{errors}` shown inline.
- New action `updateBoundDefaults({id, minAmount, hysteresis, maxAmount})` → `$axios.post('/location/updateBoundDefaults', …)`. The dead U5 actions are not touched.

**Fixed Locations** (`fixedLocation.vue`, `updateBound.vue`, `store/masterData/fixedLocation.js`):
- *Bounds* chip column: **Inherited** (from `boundsInherited`) / **Overridden**.
- Details: "Default: 24 / 36 / 48 (location)" or "(system)".
- Row menu "Use location default", enabled only when Overridden → action `resetBoundsToDefault({id})` → `$axios.post('/fixedAssignment/resetBoundsToDefault', {id})`, then reload.
- `updateBound.vue` note: "Saving marks this assignment Overridden; it will no longer follow its location's default."
- Export (U1 `:159-160,379`): add the *Bounds* column.

---

## 4. File Change Summary

| Repo | File | Change | Phase |
|---|---|---|---|
| api | `src/main/resources/db/migration/V2.2.45__location_default_fla_bounds.sql` | NEW (§3.1) | P1 |
| api | `model/Location.java` | +3 fields, READ_ONLY | P1 |
| api | `model/FixLocationAssignment.java` | +`boundsInherited`, READ_ONLY | P1 |
| api | `repo/jpa/LocationRepository.java` | + `lockDefaultBoundsById` (native FOR SHARE, `exported=false`); `getDetailView` +3 columns | P1 |
| api | `repo/projection/LocationDefaultBoundsView.java` | NEW 3-getter projection | P1 |
| api | `repo/jpa/FixLocationAssignmentRepository.java` | `getDetailView` + `fla.bounds_inherited`, `l.default_*` | P1 |
| api | `repo/projection/FixLocationAssignmentDetailView.java` | +4 getters | P1 |
| api | `repo/projection/LocationDetailView.java` (L5) and `LocationService.getLocationDetails` (L4) | +3 keys | P1 |
| api | `service/FixLocationAssignmentService.java` | §3.3 | P1 |
| api | `dto/LocationBoundDefaultsResult.java` | NEW record | P1 |
| api | `service/ViewDtoService.java` (~`:905`) | `defaultSource` + effective triple | P1 |
| api | `controller/LocationController.java` | + `updateBoundDefaults` handler | P1 |
| api | `controller/FixLocationAssignmentController.java` | + `resetBoundsToDefault` handler; fix stale `:22-24` comment (D-5 fold-in) | P1 |
| api | tests (§7.2) | NEW `LocationDefaultBoundsMigrationIT`; extend 6 existing classes | P1 |
| ui | `components/masterData/location/storageLocations/storageLocation.vue` | columns + flowbin-only menu item | P2 |
| ui | `components/masterData/location/storageLocations/boundDefaultsDialog.vue` | NEW | P2 |
| ui | `store/masterData/storageLocation.js` | + `updateBoundDefaults` | P2 |
| ui | `components/masterData/location/fixedLocations/fixedLocation.vue` | chip column, details, menu item, export | P2 |
| ui | `components/masterData/location/fixedLocations/updateBound.vue` | note | P2 |
| ui | `store/masterData/fixedLocation.js` | + `resetBoundsToDefault` | P2 |
| ui | `test/store/masterData/*.spec.js`, `test/components/masterData/location/*.spec.js` | NEW Jest specs (§7.2) | P2 |
| docs | `wms2-replenishment-design.md`, `wms2-sysprop-catalog.md`, `wms2-function-to-docs-map.md`, `wms2-rest-api-reference.md`, `wms2-entity-enumeration-report.md`, `wms2-caching-strategy.md` (if it lists writers) | docs-update step; D-7 fixed there | P1/P2 |

Paths under `src/main/java/net/aim_ai/wms/`. Projection/DTO package names: executor follows the neighbours of `FixLocationAssignmentDetailView`.

---

## 5. Prerequisites & Phased Implementation Plan

### 5.1 Prerequisites

| # | Prerequisite | Required value / action | Owner | Notes |
|---|---|---|---|---|
| 1 | **Database state / Flyway version** | Every tenant at 2.2.44. **V2.2.45 is free**: `git ls-tree origin/develop` lists V2.2.40–44 only; `git log --all --diff-filter=A -- 'V2.2.4[5-9]*' 'V2.2.5*'` = 0 — **local refs only**. Before commit: `git fetch --all` then `git branch -r --contains` sweep + `gh pr list --state open --search V2.2.45`, and check peer worktrees under `.claude/worktrees/wms2-api/*` for an uncommitted `V2.2.45__*` (migration README "Picking a version"). Re-check at merge time (`wms-merge` preflight). | executor | collision → renumber, never edit after apply |
| 2 | Feature flags / sysprops | N/A — no toggle; feature is inert until an operator sets a default. Reads the existing `FIX_LOCATION_ASSIGNMENT_DEFAULT_VALUE_*_BOUND` rows | — | |
| 3 | Config / env | N/A — no property changes | — | |
| 4 | **Deploy order** | P1 (api) deployed to an env **before** P2 (ui) merges there: P2 calls two new endpoints and reads new keys. P1 alone is safe with the old UI (all additive). | Nam | |
| 5 | **Data migration** | Backfill is inside V2.2.45 (§3.1). After deploy, **per tenant**: `select max(version) from flyway_schema_history` = 2.2.45; `select count(*) from information_schema.columns where table_name='location' and column_name like 'default_%'` = 3; `select bounds_inherited, count(*) from fix_location_assignment group by 1`. Watch the boot log for **42501 "must be owner of"** (`StartupFlywayMigrator.isOwnershipDrift`; V2.2.32 header — `IF NOT EXISTS` does not help a non-owner) and 55P03 lock timeouts. | Nam / executor | all 6 tenant DBs |
| 6 | External systems | N/A — no OMS/printer/Keycloak change; mobile reads FLA upper (unchanged) | — | |
| 7 | **Access / permissions** | No new function. **M0 on PRD**: users holding exactly one of `WEB_UI_VIEW_STORAGE_LOCATION` / `WEB_UI_VIEW_FIXED_ASSIGNMENT` (query §7.4). DEV = 0. If PRD > 0, the cross-screen write-through grants those users new effect → report to Nam before P1 ships to PRD. | executor | blocks the PRD rollout only |
| 8 | Monitoring | No new metric. Saved log queries §7.6 | — | |

### 5.2 Phases

**P1 — wms2-api (one PR; migration + entity must be one commit, `ddl-auto=none`)**

1. Run `wms-triage` block on the ticket; claim lease `.claude/scripts/ticket-lease.sh claim SBDEV-3128`; worktree `.claude/worktrees/wms2-api/SBDEV-3128` off fresh `origin/develop`. Prereq #1 sweep.
2. **TDD gate:** write the §7.2 P1 tests; confirm each fails for the right reason (missing column / missing method / assertion, not compile noise beyond the new symbols).
   *Accept:* red list recorded in the plan's Implementation Status.
3. Migration + entities + `LocationRepository.lockDefaultBoundsById` + projections.
   *Accept:* `LocationDefaultBoundsMigrationIT` green; full `mvn test` has no `ddl-auto=validate` failure.
4. Service (§3.3) + `ViewDtoService` keys.
   *Accept:* ServiceUnitTest + ServiceIT green; PIT on `FixLocationAssignmentService` shows no SURVIVED mutant on new lines (§7.3).
5. Controllers + gate pins + cache test.
   *Accept:* controller unit tests, `Sbdev3017TrancheGateContextTest`, `CacheEvictionOnWriteUnitTest` green; removing either `@RequiresFunction` turns the gate test red (mutation check).
6. Full `mvn verify` vs the known baseline; `code-reviewer` lane + `verifier` lane (independent, separate worktrees); fix every finding incl. Low; docs-update step (D-7); PR into `develop`.

**P2 — wms2-web-ui (one PR, after P1 is on dev)**

7. Worktree `.claude/worktrees/wms2-web-ui/SBDEV-3128` off fresh `origin/develop`. Jest specs first (§7.2 P2), red.
8. Storage Locations dialog + Fixed Locations chip/reset/note.
   *Accept:* `yarn test` green vs baseline; each new assertion mutation-checked by hand.
9. Manual Test Plan M1–M10 on DEV with `wms-dev-probe` + `snapshot.sh` restore proof; review lane; PR into `develop`; ClickUp `pr submitted`.

---

## 6. Backward Compatibility

| Surface | Before → After | Compatible? |
|---|---|---|
| `GET /v3/fixedAssignment/detailView` | 9 keys → 9 + 8 additive | yes |
| `/v3/fixedAssignment/update` (Map) | + flips to overridden | yes (no UI caller) |
| `/v3/fixedAssignment/set*Bound` | + flips to overridden | yes |
| `/v3/location/detailView`, `/locationDetailsById/{id}` | + 3 nullable keys | yes |
| `/v3/location/create` | defaults in JSON body now ignored (READ_ONLY) | yes — field did not exist |
| SDR `GET /api/location/**` | + 3 nullable read-only fields | yes |
| FLA SDR | not exported (`exported = false`, SBDEV-3183) | n/a |
| mobile `fixedLocationUpperBound` | reads FLA upper | yes |
| R1–R13 readers, flowbin/replenishment monitors | unchanged | yes |
| v1-to-v2 onboarding SQL | untouched, not on boot/IT path | yes |
| test/demo fixtures (column-listed INSERTs, 0 positional — G8) | new column → `DEFAULT false` (overridden, inert) | yes |
| test `ddl-auto=validate` | entity + migration in one commit | yes |
| old UI against new API | additive only | yes |
| new UI against old API | 404 on new endpoints | **no** → prereq #4 |

**What does NOT change:** the FLA bound columns and their NOT-NULL-ness; any replenishment reader (R1–R13) or the V2.2.43 view; the sysprop keys, values and their read tier; `adjust*` validation messages and order-dependence; `delete`/`changeActive`; `FIX_LOCATION_ASSIGNMENT_DELETE_WHEN_EMTPY` behavior; the `move()` not-a-flowbin message text; `LocationService.updateLocation`'s 13-field copy; `/v3/import/locations`; Keycloak / function grants; mobile UI. No hard capacity cap is enforced (D2).

---

## 7. Testing Strategy

### 7.1 Commands
- api: `mvn test -Dtest=<Class>` per class; `mvn verify` before PR (Testcontainers PG). PIT per §7.3.
- ui: `yarn test` (`"test": "jest"`).

### 7.2 Tests ↔ acceptance criteria

| AC | Ticket AC | Assertion | Test class · method |
|---|---|---|---|
| AC-1 | h | migrate to 2.2.44; seed FLAs 36/60/84, 12/24/36, and 36/60/90 with sysprop UPPER=`'90'` on a 2nd fresh DB; migrate → inherited exactly where equal to *that tenant's* triple | ★ `integration/schema/LocationDefaultBoundsMigrationIT` · `backfill_marksOnlyTenantDefaultTripleInherited`, `backfill_readsTenantSyspropNotHardcoded` |
| AC-2 | h | no sysprop rows → 36/60/84; `'abc'` and `' 36 '` → fallback; non-`DEFAULT` workstation ignored; lowest `client_id` wins | same · `backfill_fallbacks_*` (4 methods) |
| AC-3 | g | replay of the script body is a no-op; CHECK rejects (10,5,20), (10,NULL,20), (−1,0,1), (10,20,20); accepts all-NULL and (0,0,1) | same · `migration_isIdempotent`, `check_rejects_*`, `check_accepts_*` |
| AC-4 | a, b | create with location 24/36/48 → FLA 24/36/48, inherited; with null → sysprop, inherited | `unit/service/FixLocationAssignmentServiceUnitTest` `@Nested Create` · `seedsFromLocationDefault`, `seedsFromSyspropWhenLocationDefaultNull` |
| AC-5 | c, d | each `adjust*` sets inherited=false (3 assertions) | existing `@Nested Adjust*` (`:118,165,210`) · `+ marksOverridden` each |
| AC-6 | b, d | defaults edit: inherited FLA rewritten + `requestForItem` once; overridden untouched + `never()` trigger | ServiceUnitTest `@Nested UpdateLocationBoundDefaults` · `writesThroughInherited`, `leavesOverriddenUntouched`, `noFla_onlyLocationSaved`; `service/FixLocationAssignmentServiceIT` · `updateLocationBoundDefaults_writesThroughOnRealPg` |
| AC-7 | b | clear → inherited FLA = sysprop, still inherited; location fields null | ServiceUnitTest · `clear_revertsInheritedToSysprop` |
| AC-8 | g | (36,60,60), (61,60,84), (−1,0,1), partial-null → `BusinessException`; `verify(locationRepository, never()).save(any(Location.class))` and FLA repo `never().save(any())` (full varargs per memory trap) | ServiceUnitTest · `rejects_*` (parameterized) |
| AC-9 | c, d | reset → location triple (or sysprop when null), inherited=true, trigger once | ServiceUnitTest `@Nested Reset` · `resetToLocationDefault`, `resetToSyspropWhenNoLocationDefault` |
| AC-10 | b, d | move: inherited takes destination triple; overridden keeps its own | ServiceIT · `move_inheritedTakesDestinationDefault`, `move_overriddenKeepsOwnBounds` |
| AC-11 | — | both new paths gated; `updateBoundDefaults` with no function → 403 | `security/Sbdev3017TrancheGateContextTest` (2 rows) + `unit/controller/LocationControllerUnitTest` · `updateBoundDefaults_*`, `FixLocationAssignmentControllerUnitTest` · `resetBoundsToDefault_*` |
| AC-12 | — | `/location/create` JSON with `defaultLowerbound` etc. → saved entity has nulls; `boundsInherited` likewise READ_ONLY | `LocationControllerUnitTest` · `create_ignoresDefaultBoundFields` |
| AC-13 | — | `updateLocationBoundDefaults` evicts `locations` allEntries | `unit/config/CacheEvictionOnWriteUnitTest` · new row |
| AC-14 | e | DTO keys present, old 9 keys unchanged; `defaultSource` LOCATION/SYSTEM | `unit/service/ViewDtoServiceUnitTest` · `fixedAssignmentDetailView_*`; `unit/service/LocationServiceUnitTest` · `locationDetails_includesDefaults` |
| AC-15 | f | reader nets pass **unedited** | existing `RefillFixedLocationPredicateIntegrationTest`, `FlowbinMonitorViewPerFlowbinIT`, `ReplenishmentMonitorViewSchemaIT` |
| AC-16 | — | D6: non-flowbin location → `BusinessException`, nothing saved | ServiceUnitTest · `rejectsNonFlowbin` |
| AC-17 | — | create blocks behind an open defaults edit (two connections; second commits after first) | ServiceIT · `create_blocksBehindDefaultsEdit` |
| UI-1 | a | `updateBoundDefaults` posts `{id,minAmount,hysteresis,maxAmount}` to `/location/updateBoundDefaults`; Clear posts three nulls | `test/store/masterData/storageLocationBoundDefaults.spec.js` |
| UI-2 | g | dialog blocks submit for 60/36/84, −1/0/1, partial; allows 24/36/48 | `test/components/masterData/location/boundDefaultsDialog.spec.js` |
| UI-3 | — | menu item hidden for non-flowbin rows | same file |
| UI-4 | c | `resetBoundsToDefault` posts `{id}`; item disabled when Inherited | `test/store/masterData/fixedLocationResetBounds.spec.js`, `test/components/masterData/location/fixedLocationBoundsChip.spec.js` |
| UI-5 | e | chip renders Inherited/Overridden from `boundsInherited` | same |

### 7.3 Mutation checks (floor: every new assertion seen red)

- **PIT**, scoped: `mvn test-compile && mvn org.pitest:pitest-maven:mutationCoverage -DtargetClasses=net.aim_ai.wms.service.FixLocationAssignmentService -DtargetTests=net.aim_ai.wms.unit.service.FixLocationAssignmentServiceUnitTest` (pom `:545-562`). No SURVIVED on new lines; per memory, confirm a KILLED came from the intended assertion, not an incidental NPE.
- **SQL — by hand** (PIT cannot mutate SQL). Each mutant applied to the migration copy, IT run, red observed, reverted:

| Mutant | Targeted by |
|---|---|
| drop `ORDER BY client_id` (or `DESC`) | AC-2 `lowestClientIdWins` |
| drop `AND workstation = 'DEFAULT'` | AC-2 `nonDefaultWorkstationIgnored` |
| hardcode `36/60/84` instead of the subselects | AC-1 `readsTenantSyspropNotHardcoded` |
| swap MIDDLE ↔ UPPER syskey | AC-1 (36/60/90 row) |
| `<=` → `<` in `middlebound < upperbound` CHECK, or drop `>= 0` | AC-3 `check_rejects_*` / `check_accepts_(0,0,1)` |
| `DEFAULT false` → `DEFAULT true` | AC-1 overridden-row assertion |
| `FOR SHARE` removed from `lockDefaultBoundsById` | AC-17 |

- **Gate:** delete each new `@RequiresFunction` → AC-11 red.
- **Jest:** invert each validation comparison / flip the flowbin predicate → UI-2/UI-3 red.

### 7.4 Manual Test Plan (DEV `dev_wh01_om1`, `wms-dev-probe`; counts measured 2026-11-01)

| # | Scenario | Precondition query → count | Expected | P/F |
|---|---|---|---|---|
| M0 | authz population (repeat on PRD) | `with u as (select gu.userlist_id uid, f.name fn from mywms_group_mywms_user gu join mywms_group_mywms_role gr on gr.grouplist_id=gu.grouplist_id join mywms_role_mywms_function rf on rf.rolelist_id=gr.rolelist_id join mywms_function f on f.id=rf.functionlist_id where f.name in ('WEB_UI_VIEW_STORAGE_LOCATION','WEB_UI_VIEW_FIXED_ASSIGNMENT')) select count(distinct uid) filter (where fn='WEB_UI_VIEW_STORAGE_LOCATION'), count(distinct uid) filter (where fn='WEB_UI_VIEW_FIXED_ASSIGNMENT'), (select count(*) from (select uid from u group by uid having count(distinct fn)=1) x)` → 44 / 44 / 0 | PRD third value reported to Nam | |
| M1 | columns absent pre-deploy | `select count(*) from information_schema.columns where table_name='location' and column_name like 'default_%'` (+ FLA `bounds_%`) → 0, 0 | 3, 1 after deploy | |
| M2 | backfill inherited | `select count(*) from fix_location_assignment where lowerbound=36 and middlebound=60 and upperbound=84` → 1307 | `… where bounds_inherited` = 1307 | |
| M3 | backfill overridden | `… where not (lowerbound=36 and middlebound=60 and upperbound=84)` → 37 | `… where not bounds_inherited` = 37 | |
| M4 | set 24/36/48 on `00-A01` (FLA 21553351) → FLA follows, replen maintenance runs | inherited FLAs with no open replen (state<700) → ≥ 3 (00-A01, 00-A03, 00-A05) | FLA 24/36/48 inherited; UI chip Inherited | |
| M5 | set a default on overridden `22-A01` (12/24/36) → FLA unchanged; then "Use location default" → location triple | overridden list `order by l.name limit 5` → 22-A01, 25-A06, 25-C01, 25-C04, 26-A02 | 12/24/36 until reset, then default, Inherited | |
| M6 | clear M4 | — | back to 36/60/84, still Inherited | |
| M7 | delete an empty inherited FLA with a location default, re-create via putaway/replenish | inherited, no open replen, SU amount=0 and reserved=0 → 62 | new FLA = location triple, Inherited | |
| M8 | move inherited FLA to a flowbin with a default | empty flowbins with no FLA and no UL → 723 | destination triple | |
| M9 | invalid 60/36/84; non-flowbin location via API | — | `{errors}`, nothing persisted (`select version, default_lowerbound from location where id=…` unchanged) | |
| M10 | `snapshot.sh` restore proof for M4–M9 | — | diff empty | |

### 7.5 Horizontal Scalability (10)

| # | Concern | Verdict | Rationale |
|---|---|---|---|
| 1 | In-JVM state | **Yes** | `locations` evicted on serving replica only; correctness path bypasses it (§3.5) |
| 2 | Connection-pool math | No | one PK query per create; no new pool |
| 3 | Scheduled jobs | No | none added |
| 4 | Long transactions | No | ≤ 1 FLA per edit (UNIQUE); trigger is post-commit |
| 5 | Request affinity | No | stateless |
| 6 | Retry / idempotency | **Yes (benign)** | edit/reset idempotent; version conflict and 40P01 retryable |
| 7 | Tenant context | No | same tenant TM; trigger's REQUIRES_NEW carries tenant (existing); Flyway per tenant |
| 8 | Distributed lock correctness | **Yes** | PG row locks inside `tenantTransactionManager`; Location → FLA order; tenant `lock_timeout` applies to app paths |
| 9 | Cache invalidation | **Yes** | as row 1 |
| 10 | External notifications | No | no OMS/printer call |

### 7.6 v2 constraint checklist (8)

| # | Constraint | Verdict | Evidence |
|---|---|---|---|
| 1 | OSIV off | ✓ | new methods `@Transactional`; projections for views |
| 2 | Transaction manager | ✓ | `tenantTransactionManager` + `rollbackFor` on all new tx methods |
| 3 | readOnly reads | partial | `ViewDtoService:903` lacks readOnly today; out of scope |
| 4 | Caffeine invalidation | ✓ | allEntries evict (precedent `LocationService:186`) |
| 5 | Micrometer | n/a | master data; no new meter |
| 6 | Jakarta | ✓ | `jakarta.persistence` as in `FixLocationAssignment.java:5` |
| 7 | H2 test SQL | n/a | native SQL tested on Testcontainers PG only |
| 8 | Controller test base | ✓ | `BaseControllerUnitTest` + gate pin |

### 7.7 Expanded test plan (deliberate mode)

| Layer | Coverage |
|---|---|
| Unit | ServiceUnitTest (AC-4..9, 16), controller units (AC-11, 12), cache (AC-13), ViewDto/LocationService (AC-14); PIT |
| Integration | `LocationDefaultBoundsMigrationIT` (AC-1..3, fresh DB per test, `migrateTo(url, "2.2.44")` then `null`, `outOfOrder(true)` as in `BillofladingTransferIdNotNullIT:115-121`); ServiceIT (AC-6, 10, 17); reader nets unedited (AC-15); full `mvn verify` |
| E2E | Manual M0–M10 on DEV through the real UI + API, with snapshot restore |
| Observability | **O-1** boot log: `Flyway tenant … V2.2.45` success per tenant; any `55P03` / `42501` / `42703` within 24 h of deploy. **O-2** post-deploy SQL per tenant: `select bounds_inherited, count(*) from fix_location_assignment group by 1` vs the pre-deploy M2/M3 counts. **O-3** log search `StaleObjectStateException` with `Location` in the 7 days after P2 ships vs the 7 days before (D5). **O-4** `select count(*) from fix_location_assignment f join location l on l.id=f.assignedlocation_id where f.bounds_inherited and l.default_lowerbound is not null and (f.lowerbound, f.middlebound, f.upperbound) is distinct from (l.default_lowerbound, l.default_middlebound, l.default_upperbound)` = 0 (I-1 drift check; expect 0). |

### 7.8 Deliberately skipped
| What | Why |
|---|---|
| Cypress/browser e2e | not in wms2-web-ui; manual M-rows cover |
| sysprop-edit propagation test | not a feature (R-5) |
| PRD dry-run of the backfill | MCP down; O-2 measures it post-deploy; the backfill only sets a flag (no bound changes) |

### 7.9 Pre-mortem (3 scenarios)

| # | Failure 6 weeks out | Cause | Prevention in this plan |
|---|---|---|---|
| PM-1 | One tenant's replenishment UI 500s with `42703 column l1_0.default_lowerbound does not exist` | V2.2.45 failed there (55P03 lock timeout on a busy rolling deploy, or 42501 ownership drift) while the new jar booted | prereq #5 per-tenant check + O-1; runbook §8 (restart for 55P03; owner fix per V2.2.32 for 42501) |
| PM-2 | An operator's hand-tuned FLA gets overwritten when someone edits the location default | FLA wrongly classified inherited (backfill read the wrong sysprop tier, or a writer path set the triple without flipping the flag) | backfill mirrors `SyspropRepository:30` exactly + AC-1/AC-2 mutants; every writer enumerated (§0.2) and AC-5 covers all three adjust*; O-4 drift query |
| PM-3 | Mobile putaway into a flowbin fails intermittently with `StaleObjectStateException` | D5 version bump from a concurrent defaults edit | accepted; retryable; O-3 measures it; if it recurs, follow-up is the side table (§9 D) |

---

## 8. Rollout Plan

1. P1 PR merged to `develop` via `wms-merge` (Flyway collision re-checked at merge) → dev deploy.
2. Per-tenant verification on dev (prereq #5, O-1, O-2); M1–M3.
3. P2 PR merged → dev deploy; M4–M10 with snapshot restore; ClickUp ACs ticked.
4. QA / UAT / PRD promotion is DevOps (release + main are not ours). Before PRD: M0 on PRD (prereq #7), prereq #5 on all 6 tenant DBs, and P1 must reach each env before P2.
5. **Runbook:** 55P03 on V2.2.45 → restart the pod in a quiet window (Flyway retries; no history row was written). 42501 → fix ownership as in V2.2.32's header, then restart. **Rollback:** redeploying the previous jar after V2.2.45 applied is safe without a down-migration. The old entities do not map the new columns, `ddl-auto=none` does not validate, and the new columns are nullable or defaulted, so old INSERTs still succeed. Location defaults set in the meantime stay dormant. FLAs created by the old jar get `bounds_inherited=false` (overridden), which is the fail-safe value; re-tag them with "Use location default" after roll-forward.
6. Communicate to WineCo: set 53-B06 defaults to their measured capacity (e.g. 12/24/48 — their call); existing 53-B06 FLAs (if any on PRD) follow only if Inherited.

---

## 9. Alternatives Considered

| Option | Pros | Cons | Verdict |
|---|---|---|---|
| **A. Write-through + `bounds_inherited`** | readers unchanged (0 of 15 touched); 1 write per edit (UNIQUE); explicit flag answers AC-e | new flag must be kept right by every writer (I-1); location version bump (D5); sysprop edits not propagated | **chosen (D1)** |
| B. Read-time COALESCE (FLA bound NULL or flag → read location/sysprop) | single source of truth; sysprop edits propagate | **8 native SQL sites** (R1, R2, R3×2, R4×2, R5, R6 — R6 needs `CREATE OR REPLACE VIEW` with V2.2.43 grant/owner caveats) and **7 Java reader sites in 6 classes** (R7–R13); each needs a `los_sysprop` join; touches the mutation-sensitive `REFILL_ELIGIBILITY_FROM_WHERE` | rejected — blast radius on the hottest replenishment SQL |
| C. Copy-at-creation only | smallest change | fails ACs (b: edits don't propagate), (e: no display), (c: no reset) | rejected |
| D. Nullable FLA bounds (NULL = inherit) | no flag column | breaks NOT-NULL assumptions in R1–R13; is B in disguise | rejected |
| E. Side table `location_bound_default` (avoid D5 version bump) | no `location.version` bump, no SBDEV-3418 exposure | extra join for display; second home for location data; re-opens D1 | rejected now; the D5 escape hatch if O-3 shows real failures |
| F. Bulk JPQL UPDATE of location defaults (no version bump) | no D5 | Location has no `@DynamicUpdate` (only `OutboxMessage`), so any concurrent full-row save overwrites the defaults with stale nulls | rejected — silent data loss beats loud retry nowhere |

---

## 10. Open Questions / Resolved Decisions

### 10.1 Resolved (Nam, 2026-11-01 — not re-opened)
- **D1** Write-through: nullable `default_{lower,middle,upper}bound` on `location` + `fix_location_assignment.bounds_inherited boolean NOT NULL DEFAULT false`. Editing location defaults rewrites inherited FLAs; create/move seed from location default → sysprop (`getSysvalue` tier). All readers unchanged.
- **D2** The location value is a **default only**, not a hard cap. Capacity enforcement → separate proposal (§10.4).
- **D3** Backfill: FLA triple == tenant's `los_sysprop` default (`workstation='DEFAULT' ORDER BY client_id LIMIT 1`; non-integer/missing → 36/60/84) → inherited; else overridden.
- **D4** V2.2.45 uses `SET LOCAL lock_timeout = '10s'` — first in repo; justified in the header (§3.1).
- **D5** Accept + document the `location.version` bump → possible `StaleObjectStateException` on a concurrent putaway/replenish/move into the same flowbin.
- **D6** Defaults editor AND API restricted to FLOWBIN locations; API rejects others with `BusinessException`, reusing `move()`'s check (`:121`, `getSltname().equals(STORAGE_LOCATION_TYPE_BOX_RESTRICTION_FLOWBIN)`), extracted to `requireFlowbin`.

### 10.2 Resolved by this plan (adopted analysis recommendations; Nam may override at approval)
- Clear location default → inherited FLAs revert to sysprop (I-1).
- Reset with no location default → sysprop triple.
- Every `adjust*` flips to overridden, even when equal to the default (explicit, reversible; avoids comparing against a 2-min per-replica sysprop cache).
- Write-through, reset and move call `requestForItem` (post-commit when transactional).
- Create reads the location default with a scalar native `SELECT … FOR SHARE` (race closure, no entity → no SBDEV-3418 upgrade).
- `@JsonProperty(access = READ_ONLY)` on all four new entity fields.
- `POST /v3/location/updateBoundDefaults` with **method-level** `@RequiresFunction(WEB_UI_VIEW_STORAGE_LOCATION)`; `POST /v3/fixedAssignment/resetBoundsToDefault` under class-level `FIXED_ASSIGNMENT`; both pinned in `Sbdev3017TrancheGateContextTest`.
- Controller tests on `BaseControllerUnitTest`; migration IT modeled on `BillofladingTransferIdNotNullIT`.
- **New in this plan:** backfill regex `'^[+-]?[0-9]{1,18}$'` (mirrors `Long.parseLong`, which does not trim — `:306`) instead of the analysis's whitespace-tolerant form.
- **New:** inactive FLAs are written through.
- **New:** no verify script (§Verify script).

### 10.3 Open (non-blocking)
- **O-1** Clearing defaults on a location that is no longer a flowbin (retyped after defaults were set): D6 as written rejects it, leaving stale dormant defaults that a later create there would seed from (create paths do not check type). Recommend: allow **clear** on any type, reject **set** on non-flowbins. Blocks nothing; decide at plan approval.
- **O-2** Share→update deadlock residual (§3.6) — architect to confirm callers' lock order or pick `FOR NO KEY UPDATE`.

### 10.4 Follow-up proposal (not filed — T3, Nam confirms)
- **Capacity hard cap** (relates to SBDEV-1468; 0 sbdocs hits). *Evidence:* WineCo 53-B06 rollers hold 48, FLA max was 84; D2 makes the location value a default only, so an operator can still set FLA max > physical capacity. *Shape:* `location.capacity` (or reuse the default max) enforced in `adjust*`/create (`upper ≤ capacity`) and in putaway/replenish quantity checks (`MobileReplenishService:727` is the existing mobile max surface). *Blast radius:* every putaway/replenish quantity path + mobile UI messaging; T3. *Cost:* ~2-3 days + migration. Recommend after this ships and WineCo has used defaults for a few weeks.

### 10.5 Adjacent findings (from analysis §7)

| # | Finding | Tier | Destination |
|---|---|---|---|
| D-1 | `ViewDtoService:708` `new BigDecimal(syspropService.getSysvalue(…UPPER_BOUND_KEY))` → NPE → replenish-order list 500 if the row is absent | T0/T1 | comment on SBDEV-3128; **fold into P1** (ViewDtoService is touched; replace with the `parseSyspropLong`-style fallback) |
| D-2 | `ReplenishOrderJob:759` `getIntValue(…, 100)` vs `WmsConstants:1361 "84"` | T0 | comment on SBDEV-3128; not folded (file untouched; changes job behavior on tenants without the row — needs a DB check first) |
| D-3 | `/fixedAssignment/update` runs three non-transactional `adjust*`: partial writes, order-dependent validation; no UI caller | T1 | comment on SBDEV-3128 |
| D-4 | `adjust*`/`delete`/`changeActive` lack `@Transactional`; controller `delete` runs multi-step moves + `deleteById` with no tx | T1/T2 (needs DB evidence) | comment on SBDEV-3128 |
| D-5 | Stale comments: `FixLocationAssignmentController:22-24` ("SDR READS remain ungated") vs repo `exported = false`; `LocationController:62-63` C15/C16 "KEEPS its SDR write surface" vs `RestConfiguration:798-808,866-868` | T0 | **fold into P1** (both files touched) |
| D-6 | Dead verb-inverted actions `storageLocation.js:115-140`, `locationType.js:61-90` (known §0.B) | T0 | comment on SBDEV-3128; not folded (deleting them is out of scope; P2 adds a separate action) |
| D-7 | Doc drift: function-to-docs-map `:108,110` wrong endpoints; sysprop-catalog `:269-271` "fill %" (values are absolute quantities); replenishment-design `:337-339` default "0", `:15` omits lowerbound refill eligibility | T0 | fixed in the execution docs-update step |

---

## Verify script

**None.** Every AC is encodable in JUnit (AC-1..17, incl. SQL behavior via Testcontainers) or Jest (UI-1..5), which run in CI and can be mutation-checked. The one cross-file invariant (I-1) is behavioral and is covered by AC-4..10 plus the O-4 drift query; a grep-shaped script cannot see it.

---

## ADR

- **Decision:** Store optional per-location default bounds on `location`, tag each FLA with `bounds_inherited`, and write the effective default through to inherited FLAs on every create, move, reset and defaults edit. Replenishment readers keep reading the FLA columns.
- **Drivers:** zero change to 15 replenishment reader sites; the location keeps its capacity across FLA delete/re-create; the operator sees and reverses inheritance.
- **Alternatives considered:** read-time COALESCE (8 SQL + 7 Java sites); copy-at-creation (fails ACs b/c/e); nullable FLA bounds (B in disguise); side table (avoids D5, re-opens D1); version-less bulk UPDATE (silent overwrite).
- **Why chosen:** smallest blast radius that meets every AC; one invariant enforced at one resolver; fail-safe default for unknown provenance.
- **Consequences:** `location.version` bumps on defaults edits (D5, rare loud retryable failure); sysprop edits don't propagate (unchanged behavior, shown as "system" source in UI); every future FLA writer must maintain I-1 (O-4 detects drift); first migration with `lock_timeout` sets a precedent for ACCESS EXCLUSIVE DDL on hot tables.
- **Follow-ups:** capacity hard cap proposal (§10.4); D-2/D-3/D-4/D-6 on the ticket; side table if O-3 shows real D5 failures; O-1 decision.

---

## Completeness checklist

| # | Item | Status |
|---|---|---|
| 1 | §0 affected sites enumerated with grep method + blind spots | ✓ §0 |
| 2 | DB evidence with queries + counts | ✓ §2.1 (DEV); PRD no — MCP down, prereq #5/#7 |
| 3 | Migration SQL in full, idempotent, lock behavior stated | ✓ §3.1 |
| 4 | Every writer of the new state named and covered by a test | ✓ §0.2 + AC-4..10 |
| 5 | Authz for every new route + pin | ✓ §3.4, AC-11 |
| 6 | Cache + multi-replica analysis | ✓ §3.5, §7.5 |
| 7 | Locking order + concurrency risks | ✓ §3.6 |
| 8 | Backward compat + what does NOT change | ✓ §6 |
| 9 | Tests ↔ ACs with mutation targets | ✓ §7.2-7.3 |
| 10 | Manual plan with measured DEV counts | ✓ §7.4 |
| 11 | Rollout, runbook, rollback | ✓ §8 |

## 9.2 Recommended OMC composition

| Aspect | Value | Rationale |
|---|---|---|
| Tier | T3 | Flyway migration + backfill on 6 tenants; new cross-screen write into replenishment inputs |
| Pre-draft | analysis lane (done) | `SBDEV-3128-evidence/analysis.md` |
| Plan review | ralplan: architect → critic (one round) | T3 |
| Implementation | `wms-tdd-gate` → `wms-plan-executor` (ralph) per phase | two repos, sequential |
| Verification | the floor + `verifier` lane | no verify script |
| Code review | `code-reviewer`, 4 lanes at T3, separate worktrees | never self-approve |
| Commit | git directly, one commit per phase step where useful; migration+entity same commit | |
