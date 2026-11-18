---
ticket: SBDEV-3128
lane: analysis (T3 feature plan, read-only)
date: 2026-11-01
api_base: v2/wms2-api origin/develop @ 1b421d08 (git show / git grep; main checkout untouched)
ui_base: v2/wms2-web-ui origin/develop @ 912c786 (fetched 2026-11-01; origin/HEAD = main @ 43ea96a, ancestor of develop)
db: dev_wh01_om1 via wms-dev-probe q.sh (SELECT only). Flyway head 2.2.44, installed_rank 45.
note: written by the main session from the lane's returned text (the harness refused the subagent's Write)
---

# SBDEV-3128 — Location-level default Min / Hysteresis / Max for Fixed Location Assignments — ANALYSIS

## TL;DR
1. **FLA is 1:1 with location.** `fix_location_assignment` has UNIQUE indexes on `assignedlocation_id` (`uk_qakwvmdhdymic54v3dgie46wa`) and on `itemdata_id` (DEV `pg_indexes`). So write-through updates **at most one row** per location-default edit. The real value of the feature is that the location keeps its capacity when an FLA is deleted and re-created (5 auto-create call sites, all seeding from sysprops today) or moved.
2. **One creation chokepoint.** `FixLocationAssignmentService.createFixedLocationAssignment` has 5 callers (StockunitService:560, MobileMoveUnitloadService:646, MobilePutAwayService:640, MobileReplenishService:309 and :1109). There are no raw SQL inserts in `src/main`.
3. **The storage-location edit UI does not exist.**
   - `storageLocation.vue:92` has the edit button commented out.
   - `createStorageLocation`/`updateStorageLocation` in `store/masterData/storageLocation.js` are never dispatched.
   - Their verbs are inverted against the API (`$post('/location/update')` vs `@PutMapping`; already pinned as §0.B in `Sbdev3017TrancheGateContextTest:172`).
   - The location-default editor must be built new.
4. **The sysprop tier the service reads is NOT the 4-tier cascade.** `parseSyspropLong` → `getSysvalue` → `select sysvalue from los_sysprop where syskey = :syskey and workstation = 'DEFAULT' order by client_id LIMIT 1` (`SyspropRepository:30`). The backfill must replicate exactly that.
5. **Biggest non-data risk: `@Version` on Location** (SBDEV-3418 first-touch rule). Every default edit bumps `location.version`. A concurrent transaction that loaded the Location unlocked and then upgrades it via `findByIdForUpdate` (putaway, replenish or move into that flowbin) throws `StaleObjectStateException`.
6. **DEV census:**
   - 1344 FLAs, all active; 0 violate `lower<=middle<upper`.
   - 1307 equal the sysprop triple 36/60/84 and become inherited after backfill.
   - 37 are overridden: 28×12/24/36, 3×84/108/168, and 6 singletons.
   - Sysprop rows are 36/60/84 at `client_id=0`, `DEFAULT`.

## §0 Affected-sites enumeration

### 0.1 Grep strings (origin/develop, src/main unless stated)
| # | Command | Purpose | Blind spots |
|---|---|---|---|
| G1 | `git grep -n -i -E "lowerbound\|middlebound\|upperbound"` | all bound readers and writers (Java + SQL) | Misses `fla.*`/`select *` wildcard readers and method refs. Those are covered by G2/G3 and the manual find of `MobileReplenishService:451` |
| G2 | `git grep -n -E "get(Lower\|Middle\|Upper)bound\(\)"` minus the model and service | Java getter readers | method refs |
| G3 | awk scan of `nativeQuery = true` methods returning `Location`/`FixLocationAssignment`, plus `getFlowBinHavingNoFixedAssignment` | native queries that would break on new entity columns | Crude parser (20 Location-typed, 6 FLA-typed signatures). Every native entity query found uses `l.*`/`lo.*`/`loc.*`/`fla.*`/`select *`, so all are safe |
| G4 | `git grep -n -E "new FixLocationAssignment\(\|createFixedLocationAssignment\(\|fixLocationAssignmentService\.(move\|delete\|changeActive\|adjust)\|[Ff]ixLocationAssignmentRepository\.(save\|delete\|saveAll)\|setAssignedlocationId\(\|insert into fix_location_assignment\|update fix_location_assignment\|delete from fix_location_assignment"` | FLA create, move, delete | `@Modifying` JPQL (none) |
| G5 | `locationRepository.save(`, `@RequestBody Location`, `LocationService` methods, `LocationUploadDto`, `git ls-tree \| grep location` | Location create, update, serialize | implicit Jackson serialization |
| G6 | `RestConfiguration` `forDomainType(Location\|FixLocation`, `@RepositoryRestResource` | SDR write exposure | none |
| G7 | UI grep: bounds + `minAmount\|hysteresis\|maxAmount` + `location/update\|create\|…StorageLocation` | UI sites | dynamically built URLs (none seen) |
| G8 | `INTO (public.)?(fix_location_assignment\|location)` in src/test and demo-datasets | positional INSERTs | 0 positional found. `V2.2.00:2460 INSERT INTO public.location VALUES` runs before V2.2.45 |

### 0.2 Readers (all UNCHANGED under write-through)
| # | Site | Quoted | In scope |
|---|---|---|---|
| R1 | `FixLocationAssignmentRepository:173` (`REFILL_ELIGIBILITY_FROM_WHERE`) | `" AND stockunit.amount < fla.lowerbound "` | no change |
| R2 | `FixLocationAssignmentRepository:222-224` `getDetailView` | `"fla.lowerbound as minAmount, " "fla.middlebound as hysteresis, " "fla.upperbound as maxAmount, "` | additive SELECT columns (flag + location defaults), P2 |
| R3 | `ReplenishorderRepository:243,249` | `"AND stockUnit.amount >= fixAssignment.upperbound "` | no change |
| R4 | `ReplenishorderRepository:303,326` | `"AND fixAssignment.upperBound > su.amount "` | no change |
| R5 | `ReplenishmentMonitorViewRepository:104,110` | `"f.upperbound AS fix_assignment_upperbound "` | no change |
| R6 | `V2.2.43…flowbin_monitor_view:45-47` → `FlowbinMonitorView @Column(name="lower_bound")` → `ViewDtoService:1432-1434`, `ReportService:263-265` | `COALESCE(round(f.lowerbound), (0)::numeric) AS lower_bound` | no change |
| R7 | `ReplenishOrderJobService:183,185` | `BigDecimal middleBound = fixedLocationAssignment.getMiddlebound();` | no change |
| R8 | `ReplenishmentOrderMaintenanceService:1002-1008` | `if (assignment != null && assignment.getUpperbound() != null) { return assignment.getUpperbound(); }` | no change |
| R9 | `ReplenishGeneratorService:99,123` | `ass.getUpperbound().subtract(stockunitList.get(0).getAmount())` | no change |
| R10 | `ViewDtoService:805-807` | `fla.getUpperbound().compareTo(BigDecimal.ZERO) > 0` | no change |
| R11 | `ViewDtoService:1382-1387` | `result.getFix_assignment_upperbound()` | no change |
| R12 | `MobileReplenishService:447-451` | `.map(FixLocationAssignment::getUpperbound)` (G1/G2 miss) | no change |
| R13 | `MobileReplenishService:727` | `order.setAmountDestinationMax(fixOpt.orElseThrow().getUpperbound());` | no change |
| R14 | `FixLocationAssignmentRepository:61,198` | `select * from fix_location_assignment f …` / `SELECT DISTINCT fla.*` | auto-includes the new column |
| R15 | v1-to-v2-onboarding `V1.0.02`, `V1.2.04`, `V1.2.99*` | `coalesce(round(f.lowerbound), 0)` | not on the boot/IT path (migration README:139, 217-223) |

**Sysprop default readers:**
- S1 `FixLocationAssignmentService:86-88` `parseSyspropLong(…LOWER_BOUND_KEY, …VALUE)`. This is **the seeding point**.
- S2 `ReplenishmentOrderMaintenanceService:1006-1008` `getSysvalue` + `parseLong(…, "84")`.
- S3 `ReplenishOrderJob:759` `getIntValue(…UPPER_BOUND_KEY, 100)`. **Defaults to 100.**
- S4 `ViewDtoService:708` `new BigDecimal(syspropService.getSysvalue(…))`. **NPE if the row is absent.**

### 0.3 Writers / FLA lifecycle
| # | Site | Quoted | Change | Phase |
|---|---|---|---|---|
| W1 | `FixLocationAssignmentService:83-107` create | `fixedLocationAssignment.setLowerbound(lowerBound); … requestForItem(itemData.getId());` | seed from location default, else sysprop; `boundsInherited=true` | P1 |
| W1c | 5 callers (list in TL;DR 2) | `fixLocationAssignmentService.createFixedLocationAssignment(destinationLocation, …)` | none | — |
| W2 | `:109-179` `move()` @Transactional(tenantTransactionManager) | `fixedLocationAssignment.setAssignedlocationId(destination.getId());` | if inherited, re-seed from destination | P1 |
| W3 | `:181-233` `adjust{Lower,Middle,Upper}Bound` (no @Transactional) | `fixedLocationAssignment.setLowerbound(BigDecimal.valueOf(newAmount));` | set `boundsInherited=false` | P1 |
| W4 | Controller `:65-94` `POST /update` (Map) | `if (reqMap.get("lowerBound") != null) fla = …adjustLowerBound(…)` | inherits W3. **No UI caller** | — |
| W5 | Controller `:152-219` `/set{Upper,Middle,Lower}Bound` | `fixLocationAssignmentService.adjustUpperBound(id, value);` | inherits W3. UI: `store/masterData/fixedLocation.js:137,157,177` | — |
| W6 | `:235-287` `delete()`; callers are `/delete/{id}` and `ReplenishOrderJobService:87` (delete-when-empty) | `fixLocationAssignmentRepository.deleteById(…)` | none. The location default survives the delete | — |
| W7 | `:289-299` `changeActive` | `setActive(!oldValue)` | none | — |
| W8 | `demo-datasets/meridian/fixtures.sql:86-88` | column-listed INSERT, `ON CONFLICT … SET lowerbound=EXCLUDED.lowerbound` | the new column takes its DEFAULT | — |

**SDR (G6): there is no ungated write path.**
- `FixLocationAssignmentRepository:23` `@RepositoryRestResource(…, exported = false)` (SBDEV-3183), so the whole repo is off HTTP. The controller comment at `:22-24` ("SDR READS remain ungated") is stale (D-5).
- `LocationRepository:20` is exported, but `RestConfiguration:798-808` withdraws collection POST and `:866-868` withdraws item PUT and PATCH. Only GET and DELETE remain, so the new `default_*` columns are readable, not writable.
- `@RequestBody Location`:
  - `LocationController:66` `/create` → `createLocationFromRequest` **saves the bound entity**, a mass-assignment hole for the new fields.
  - `:88` `/update` → `updateLocation` copies 13 named fields, so the new fields are ignored.
  - Mitigation is in §2.2.

### 0.4 Location create, update and serialize sites
| # | Site | Effect | Phase |
|---|---|---|---|
| L1 | `LocationService:66-91` `createLocation` | defaults NULL | — |
| L2 | `LocationService:156-178` `createLocationFromRequest` (`@CacheEvict locations allEntries`) | mass-assignment → `READ_ONLY` | P1 |
| L3 | `LocationService:186-211` `updateLocation` | ignores the new fields; leave as is | — |
| L4 | `LocationService:244+` `getLocationDetails` → `GET /v3/location/locationDetailsById/{id}` | add 3 keys | P2 |
| L5 | `LocationRepository:278-290` `getDetailView` (`LocationDetailView`) → `GET /v3/location/detailView` | add 3 columns | P2 |
| L6 | `FileImportController:165-314` `POST /v3/import/locations` (`LocationUploadDto`, 14 fields) | NULL; out of scope | — |
| L7 | `UtilRestController:878-930` initDB | NULL | — |
| L8 | native `l.*` entity queries (G3), e.g. `LocationRepository:304` | auto | — |
| L10 | `StorageLocationExportView` | optional | — |

### 0.5 UI sites
| # | File | Quoted | Change |
|---|---|---|---|
| U1 | `components/masterData/location/fixedLocations/fixedLocation.vue:237-239`, menu `:110-125`, export `:159-160,379` | `{ text: 'Min Amount', value: 'minAmount' … }` | Inherited/Overridden column + "Use location default" menu item (P3) |
| U2 | `fixedLocations/updateBound.vue:63-70` | `dispatch('masterData/fixedLocation/setUpperBound', data)` | hint text only |
| U3 | `store/masterData/fixedLocation.js:55,135-195` | `$axios.post('/fixedAssignment/setUpperBound', {id, value})` | add `resetBoundsToDefault` |
| U4 | `components/masterData/location/storageLocations/storageLocation.vue:92,223-231` | `<!-- … @click="showEditDialog(item)" v-if="isSuperAdmin" -->` | new default columns + dialog |
| U5 | `store/masterData/storageLocation.js:115-140` | `$put('/location/create')`, `$post('/location/update')` | undispatched and verb-inverted; do not reuse |
| U6 | `components/reports/flowbinReport.vue:84-85` | `{{ item.lowerBound }} / …` | none |
| U7 | `util/appMenuList.js:87,89` | `fn: 'WEB_UI_VIEW_STORAGE_LOCATION'` / `'WEB_UI_VIEW_FIXED_ASSIGNMENT'` | gating source |
| U8 | wms2-mobile-ui `OrderHeaderBlock.vue:106` | `/replenish/fixedLocationUpperBound/…` | none |
| U9 | oms-laravel-api (local HEAD, not fetched) | 0 relevant hits | none |

## §1 Current architecture
- **Flow.** FLAs are created only by `createFixedLocationAssignment`, using the sysprop triple and nothing from the location. They are edited one bound per request (`/set*Bound`). Consumers are R1 (refill eligibility `amount < lowerbound`), R7 (job: `amount >= middle` → skip; `required = upper − amount`), R3/R4 (cancel and shortage), R5/R6 (monitors) and R12/R13 (mobile max). Tuning is lost on delete followed by implicit re-create. `FIX_LOCATION_ASSIGNMENT_DELETE_WHEN_EMTPY=false` on DEV (row 51682). DEV `53-B06` (id 3223189, flowbin) currently has no FLA.
- **Validation** (`:181-233`): effectively `lower ≤ middle < upper`. There is no non-negativity check, and comparisons are on `double`. DEV violators: 0/1344. Per-bound edits are order-dependent (raising everything requires upper first).
- **Endpoints:**
  - `GET /fixedAssignment/detailView` returns 9 keys, unpaged.
  - `POST /fixedAssignment/set*Bound {id,value}`. Errors come back as HTTP 200 `{errors}`.
  - Also `/move`, `DELETE /delete/{id}`, `GET /toggleActiveStatus/{id}`, `GET /getFlowBinHavingNoFixedAssignment`.
  - Storage locations: `GET /location/detailView`, `GET /location/locationDetailsById/{id}`, SDR `DELETE /location/{id}`, export.
  - **No location edit is reachable from the UI.**
- **Authz:**
  - `FixLocationAssignmentController:31` is class-level `@RequiresFunction(WEB_UI_VIEW_FIXED_ASSIGNMENT)`, pinned in `Sbdev3017TrancheGateContextTest:157-163`.
  - `LocationController` is **method-level only** and not in `FunctionGuardInterceptor.GUARDED` (`:119-130`), so a new handler without the annotation is **silently ungated**.
  - Gate per screen (SBDEV-3017 §9.16 Option B): defaults edit → `WEB_UI_VIEW_STORAGE_LOCATION`; reset → `WEB_UI_VIEW_FIXED_ASSIGNMENT`.
  - DEV user population over group→role→function: 44 hold STORAGE_LOCATION, 44 hold FIXED_ASSIGNMENT, 0 hold only one. So the cross-screen write-through grants nobody new power on DEV. **PRD not measured** (MCP down); see M0.

## §2 Proposed design

### 2.1 `V2.2.45__location_default_fla_bounds.sql`
`origin/develop` ends at V2.2.44. `git log --all --diff-filter=A -- 'V2.2.4[5-9]*' 'V2.2.5*'` returns 0, but that only covers local refs. Check in-flight tickets per migration README "Picking a version".
```sql
ALTER TABLE public.location
    ADD COLUMN IF NOT EXISTS default_lowerbound  numeric(17,4),
    ADD COLUMN IF NOT EXISTS default_middlebound numeric(17,4),
    ADD COLUMN IF NOT EXISTS default_upperbound  numeric(17,4);
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'ck_location_default_bounds') THEN
    ALTER TABLE public.location ADD CONSTRAINT ck_location_default_bounds CHECK (
      (default_lowerbound IS NULL AND default_middlebound IS NULL AND default_upperbound IS NULL)
      OR (default_lowerbound IS NOT NULL AND default_middlebound IS NOT NULL AND default_upperbound IS NOT NULL
          AND default_lowerbound >= 0 AND default_lowerbound <= default_middlebound
          AND default_middlebound < default_upperbound));
  END IF;
END $$;
-- false = OVERRIDDEN = fail-safe for rows written by paths that do not set it (raw SQL, fixtures)
ALTER TABLE public.fix_location_assignment
    ADD COLUMN IF NOT EXISTS bounds_inherited boolean NOT NULL DEFAULT false;
-- mirrors parseSyspropLong -> getSysvalue -> SyspropRepository:30 exactly; missing/non-integer -> 36/60/84
WITH d AS (SELECT
  COALESCE((SELECT CASE WHEN sysvalue ~ '^\s*-?[0-9]+\s*$' THEN btrim(sysvalue)::numeric END FROM public.los_sysprop
            WHERE syskey='FIX_LOCATION_ASSIGNMENT_DEFAULT_VALUE_LOWER_BOUND' AND workstation='DEFAULT'
            ORDER BY client_id LIMIT 1), 36) lo,
  COALESCE((…MIDDLE_BOUND…), 60) mi, COALESCE((…UPPER_BOUND…), 84) up)
UPDATE public.fix_location_assignment f SET bounds_inherited = true FROM d
 WHERE f.lowerbound=d.lo AND f.middlebound=d.mi AND f.upperbound=d.up AND f.bounds_inherited=false;
```
- **Tier:** `getSysvalue` (`SyspropService:333-336`), not the `getStringDefault` 4-tier cascade (`:175-268`). The query is workstation-pinned, client-blind, lowest `client_id` wins. The sysprop catalog §2 states the same rule, and §11.3 shows one row per key at client 0 / DEFAULT on all 6 tenants (2026-09-10). Each tenant's own row is read, so per-tenant variance is handled.
- A non-integer value makes `Long.parseLong` throw in Java, so no FLA can have been seeded from it. Falling back to the hardcoded value is correct.
- **Historical drift:** FLAs seeded under an older sysprop value classify as overridden. That is fail-safe.
- **Locks:** the nullable and constant-default ADD COLUMNs are catalog-only on PG ≥ 11. The CHECK scans `location` (2,750 rows on DEV) under ACCESS EXCLUSIVE. That lock queues behind open transactions and then blocks all `location` reads. Consider `SET LOCAL lock_timeout='10s'`: a timeout fails the script and Flyway retries next boot with no history row. There is no repo precedent (0 hits in db/migration), so this is a **Nam decision**.
- **No CHECK on the FLA bound columns.** PRD data is unmeasured, and a failing CHECK freezes the tenant (V2.2.34 header).
- **42703:** `ddl-auto=none` (`application.properties:143`). A tenant that misses V2.2.45 boots green, then every Location/FLA read throws 42703. A tenant owned by another role stalls on 42501 despite `IF NOT EXISTS` (V2.2.32 header). The entity and migration must ship in one PR; verify per tenant.

### 2.2 Entities
- `Location`: three `@Column(name="default_lowerbound", columnDefinition="numeric(17,4)") @JsonProperty(access = READ_ONLY) BigDecimal`, all nullable. READ_ONLY closes the L2 mass-assignment and any future SDR re-exposure.
- `FixLocationAssignment`: `@Column(name="bounds_inherited", nullable=false) @JsonProperty(access=READ_ONLY) Boolean boundsInherited = Boolean.FALSE`.

### 2.3 Service methods (in `FixLocationAssignmentService`)
They go here because this service already injects `LocationService` (ctor `:59`); the reverse would be a constructor-injection cycle.
```java
private BigDecimal[] resolveDefaultBounds(Long locationId)   // scalar native read ... FOR SHARE (2.6); location triple ?? sysprop
public FixLocationAssignment createFixedLocationAssignment(Location, Itemdata) // unchanged signature; inherited=true
@Transactional(tenantTM, rollbackFor=…) public void move(Long, Long)          // + re-seed if inherited
public FixLocationAssignment adjust{Lower,Middle,Upper}Bound(Long, double)    // + inherited=false
@Transactional(tenantTM, rollbackFor=…) public FixLocationAssignment resetBoundsToLocationDefault(Long flaId)
@CacheEvict(value="locations", allEntries=true) @Transactional(tenantTM, rollbackFor=…)
public Location updateLocationBoundDefaults(Long locationId, BigDecimal l, BigDecimal m, BigDecimal u)
  // all-or-none; 0<=l<=m<u; locationRepository.findByIdForUpdate (LocationRepository:122-125); save;
  // findByAssignedlocationId (≤1, UNIQUE); if inherited -> triple = resolveDefaultBounds, save, requestForItem
```
**Recommendations:**
- **Cleared location default:** inherited FLAs revert to the sysprop triple. That keeps one invariant shared by create, move, reset and clear: *inherited ⇒ triple = effective default (location ?? sysprop) at last write*.
- **Reset with no location default:** use the sysprop triple.
- **Sysprop edits:** not written through (today's behaviour). Show the default's source in the UI.
- **adjust\*:** always flips to overridden, even when the value equals the default. It is explicit and reversible, and comparing against a 2-min per-replica cached sysprop would be non-deterministic.
- **Replenishment trigger:** write-through calls `requestForItem`, as adjust and create do. It is post-commit (`ReplenishmentMaintenanceTrigger:51-53,88-93`). The adjust\* methods have no transaction, so their trigger runs inline (pre-existing).
- **Inactive FLAs** are written through too.
- **Capacity enforcement** is not designed. It would sit in create/adjust (upper ≤ capacity) and in the putaway/replenish quantity checks (`MobileReplenishService:727` is the existing mobile max surface). SBDEV-1468: 0 sbdocs hits.

### 2.4 API
| Endpoint | Gate | Payload |
|---|---|---|
| NEW `POST /v3/location/updateBoundDefaults` (LocationController) | **method-level `@RequiresFunction(WEB_UI_VIEW_STORAGE_LOCATION)`**, mandatory | `{id, minAmount, hysteresis, maxAmount}` (all numbers, or all null to clear) → Location or 200 `{errors}` |
| NEW `POST /v3/fixedAssignment/resetBoundsToDefault {id}` | class-level FIXED_ASSIGNMENT | message or `{errors}` |
| `GET /fixedAssignment/detailView` | — | + `boundsInherited`, `locationDefaultMinAmount/Hysteresis/MaxAmount`, `defaultSource` (LOCATION/SYSTEM), additive |
| `GET /location/detailView`, `locationDetailsById` | — | + 3 nullable keys |
| `/set*Bound`, `/update` | — | same shape; flips to overridden |

Use POST so the UI and API verbs agree; do not extend the §0.B inversion. Add both paths to `Sbdev3017TrancheGateContextTest`.

### 2.5 Cache
- **`locations`:** per-replica Caffeine, max 2000, 5-min `expireAfterWrite` (wms2-caching-strategy.md). It caches Location entities via `LocationService.getByName:100`.
  - `updateLocationBoundDefaults` evicts allEntries, which only clears the serving replica.
  - `resolveDefaultBounds` never reads the passed-in entity, so a stale cached entity cannot seed an FLA.
  - All 5 create callers use `locationRepository.findByName/findById` (checked in the 40 lines before each call); none uses `getByName`.
- **`sysprops`:** 2-min TTL, unchanged. No new cache.

### 2.6 Locking
- **Order is Location → FLA everywhere.**
  - Defaults edit: FOR UPDATE on the location, then FLA save with `@Version`.
  - Create: callers mostly hold PESSIMISTIC_WRITE on the destination via `transferUnitLoadToLocation(…, ignoreLock=false)` (`LocationRepository:29-32`).
  - Move: same lock on the destination.
  - Adjust and reset: FLA only (`AbstractBaseEntity:34-35 @Version`).
  - No inversion found.
- **Race: create vs edit.** Create reads the old default, the edit sees no FLA yet, and create commits a stale "inherited" FLA. Closed by a scalar native `SELECT default_* FROM location WHERE id=:id FOR SHARE`, which serializes against the edit's FOR UPDATE and materializes no entity (so no SBDEV-3418 upgrade). Cost: one PK row lock per create. Creates are rare: DEV FLA `created` by month shows 2 (Aug), 3 (Jun), 3 (May).
- **Version-bump risk** (`LocationRepository:26-46`): today's only Location writers are master-data paths (`LocationService:89,148,175,208`, `FileImportController:314`, initDB). This adds an operator-frequency writer, and the failure needs a putaway/replenish/move into that exact flowbin at the same moment.
  - (a) Accept and document. **Recommended**: it fails loudly and is retryable.
  - (b) Bulk JPQL UPDATE with no version bump. Not recommended: Location has no `@DynamicUpdate` (only `OutboxMessage` has it), so a concurrent save would overwrite the defaults.
  - (c) Side table. Would re-litigate decision 1.

### 2.7 UI
- **Fixed Locations:**
  - an Inherited/Overridden chip column;
  - the default triple and its source in the details panel;
  - a "Use location default" item, enabled only when overridden;
  - the set-bound dialog warns that saving marks the FLA overridden.
- **Storage Locations:**
  - 3 nullable columns and a "Set replenishment defaults" row-menu item;
  - a dialog with client-side `0 ≤ l ≤ m < u`, a Clear button, and an "updates N inherited FLA(s)" note (N ∈ {0,1}).
- **Which location types:** FLAs exist only on flowbins on DEV (flowbin 2068 locations / 1344 FLAs; every other type 0), and `move()` requires a flowbin (`:121`), but create paths do not check type. Recommend showing the dialog for all types and letting Nam narrow it.

## §3 Backward compatibility
| Surface | After | OK? |
|---|---|---|
| FLA detailView | 9 + 5 additive keys | yes |
| `/fixedAssignment/update` (Map) | + flips to overridden | yes; no UI caller |
| `/set*Bound` | + flips to overridden | yes |
| location detailView / details | additive | yes |
| SDR `GET /api/location/**` | +3 nullable fields, read-only | yes |
| FLA SDR | not exported | n/a |
| mobile `fixedLocationUpperBound` | FLA upper (kept correct by write-through) | yes |
| flowbin/replenishment views, R1–R5 | unchanged | yes |
| v1-to-v2 onboarding SQL | untouched, not on boot/IT path | yes |
| test/demo fixtures (9 column-listed, 0 positional) | DEFAULT false = overridden, inert | yes |
| test `ddl-auto=validate` | entity + migration in one commit | yes |

## §4 Alternatives
| Alternative | Rejected because |
|---|---|
| Read-time COALESCE | **8 native SQL sites** (R1, R2, R3×2, R4×2, R5, R6 view needing CREATE OR REPLACE with V2.2.43 grant/owner caveats) and **7 Java reader sites in 6 classes** (R7–R13). The sysprop needs a `los_sysprop` join in each query. Mutation-sensitive `REFILL_ELIGIBILITY_FROM_WHERE`. Nam chose write-through |
| Copy-at-creation only | Fails 3 ACs: edits don't propagate, no inherited/overridden display, no reset |
| Nullable FLA bounds (NULL = inherit) | Breaks NOT NULL assumptions; equivalent to read-time resolve |

## §5 Tests

### 5.1 Existing tests to build on
- `unit/service/FixLocationAssignmentServiceUnitTest` (992 lines, `BaseServiceUnitTest`, `@Nested Adjust*` at `:118,165,210`)
- `service/FixLocationAssignmentServiceIT` (`BasePostgresIntegrationTest`, `move_*` at `:121,174`)
- `unit/controller/FixLocationAssignmentControllerUnitTest`, `LocationControllerUnitTest` (`BaseControllerUnitTest`). ⚠ There is **no `BaseControllerTest`**; the bases are `BaseControllerUnitTest` and `BaseControllerIntegrationTest`.
- `security/Sbdev3017TrancheGateContextTest:157-178`
- Migration IT pattern: `integration/schema/BillofladingTransferIdNotNullIT` (`migrateTo(url, target)`, fresh DB per test, `outOfOrder(true)`). Siblings: `CancellationWaiveMigrationIT`, `ManualEntryOverrideMigrationIT`.
- `unit/config/CacheEvictionOnWriteUnitTest`
- Reader nets: `RefillFixedLocationPredicateIntegrationTest`, `FlowbinMonitorViewPerFlowbinIT`, `ReplenishmentMonitorViewSchemaIT`

### 5.2 Acceptance criteria
| AC | Assertion | Test |
|---|---|---|
| AC-1 | migrate to 2.2.44, seed FLAs 36/60/84 and 12/24/36 + sysprop UPPER=`'90'`, migrate to 2.2.45 → inherited only where equal to the tenant triple | ★ `LocationDefaultBoundsMigrationIT` |
| AC-2 | no rows → 36/60/84; `'abc'` → fallback; non-DEFAULT workstation ignored; lowest client_id wins (mutation: drop ORDER BY → red) | same |
| AC-3 | replay is a no-op; CHECK rejects (10,5,20), (10,NULL,20), (−1,0,1); accepts all-NULL | same |
| AC-4 | create with location 24/36/48 → FLA 24/36/48 and inherited; without → sysprop and inherited | ServiceUnitTest `@Nested Create` |
| AC-5 | each adjust\* sets inherited=false (3 assertions, each mutation-checked) | existing `@Nested Adjust*` |
| AC-6 | defaults edit: inherited FLA rewritten + `requestForItem` once; overridden untouched, no trigger | ★ `@Nested UpdateLocationBoundDefaults` + ServiceIT |
| AC-7 | clear → inherited FLA = sysprop | same |
| AC-8 | (36,60,60), (61,60,84), (−1,0,1) and partial-null → BusinessException, `never().save(any())` (full varargs) | same |
| AC-9 | reset → location or sysprop triple, inherited=true | same |
| AC-10 | move: inherited takes destination triple; overridden keeps its own | ServiceIT (real PG) |
| AC-11 | gates for both new paths | TrancheGate + controller unit tests |
| AC-12 | `/location/create` JSON with defaults → persisted NULL | LocationControllerUnitTest / Jackson |
| AC-13 | new method evicts `locations` allEntries | CacheEvictionOnWriteUnitTest |
| AC-14 | DTOs carry the new keys; old keys unchanged | controller / ViewDtoService unit |
| AC-15 | reader ITs pass unedited | existing |

### 5.3 Manual Test Plan (DEV; counts measured 2026-11-01)
| # | Step | Precondition SELECT | Count |
|---|---|---|---|
| M0 | authz population (repeat on PRD) | `with u as (select gu.userlist_id uid, f.name fn from mywms_group_mywms_user gu join mywms_group_mywms_role gr on gr.grouplist_id=gu.grouplist_id join mywms_role_mywms_function rf on rf.rolelist_id=gr.rolelist_id join mywms_function f on f.id=rf.functionlist_id where f.name in ('WEB_UI_VIEW_STORAGE_LOCATION','WEB_UI_VIEW_FIXED_ASSIGNMENT')) …` | 44/44/0/0 |
| M1 | columns absent pre-deploy | `select count(*) from information_schema.columns where table_name='location' and column_name like 'default_%'` (+ FLA `bounds_%`) | 0, 0 |
| M2 | backfill inherited | `select count(*) from fix_location_assignment where lowerbound=36 and middlebound=60 and upperbound=84` | 1307 |
| M3 | backfill overridden | `… where not (lowerbound=36 and middlebound=60 and upperbound=84)` | 37 |
| M4 | set 24/36/48 on `00-A01` (FLA 21553351) → inherited FLA follows | inherited FLAs with no open replen (state<700) | ≥3 (00-A01, 00-A03, 00-A05) |
| M5 | set a default on `22-A01` (12/24/36) → unchanged; then reset → location triple | M3 `order by l.name limit 5` | 22-A01, 25-A06, 25-C01, 25-C04, 26-A02 |
| M6 | clear M4 → back to 36/60/84, still inherited | — | — |
| M7 | delete an empty inherited FLA, re-create via putaway/replenish → gets the location triple | inherited, no open replen, SU amount=0 and reserved=0 | 62 |
| M8 | move inherited → destination triple | empty flowbins with no FLA and no UL | 723 |
| M9 | invalid 60/36/84 → error, nothing persisted | — | — |
| M10 | `snapshot.sh` restore proof for M4–M8 | — | — |

## §6 Checklists

**Horizontal scalability (10)**

| # | Concern | Verdict | Evidence |
|---|---|---|---|
| 1 | In-JVM state | **Yes** | `locations` cache, mitigated in §2.5 |
| 2 | Connection-pool math | No | one PK query per create |
| 3 | Scheduled jobs | No | — |
| 4 | Long transactions | No | ≤1 FLA per edit (UNIQUE) |
| 5 | Request affinity | No | — |
| 6 | Retry / idempotency | **Yes (benign)** | edit and reset are idempotent; version conflict is retryable |
| 7 | Tenant context | No | same tenant TM; Flyway per tenant |
| 8 | Distributed locks | **Yes** | PG row locks, Location → FLA order (§2.6) |
| 9 | Cache invalidation | **Yes** | as row 1 |
| 10 | External notifications | No | — |

**v2 constraints (8)**

| # | Constraint | Verdict | Evidence |
|---|---|---|---|
| 1 | OSIV | Yes | `open-in-view=false` (`:95`); new methods transactional; projections |
| 2 | Transaction manager | Yes | `tenantTransactionManager` + rollbackFor |
| 3 | readOnly reads | partial | `ViewDtoService:903` lacks readOnly today; optional |
| 4 | Caffeine invalidation | Yes | allEntries evict, precedent `LocationService:186` |
| 5 | Micrometer | No | master data |
| 6 | Jakarta | Yes | `FixLocationAssignment.java:5` |
| 7 | H2 test SQL | N/A | Mockito units + Testcontainers PG |
| 8 | Controller test base | Yes | `BaseControllerUnitTest` + gate pin |

## §7 Risks and adjacent defects

**Risks**
- R-1: 42703 on a tenant that missed V2.2.45.
- R-2: ACCESS EXCLUSIVE on `location`.
- R-3: StaleObjectState from the version bump.
- R-4: backfill classifies historically-seeded FLAs as overridden (fail-safe).
- R-5: sysprop edits are not propagated.
- R-6: flowbin report shows 0/0/0 for a flowbin with no FLA, not its location default (V2.2.43 LEFT JOIN).
- R-7: PRD authz population unmeasured.

**Adjacent defects (not fixed)**
- **D-1** `ViewDtoService:708` `new BigDecimal(syspropService.getSysvalue(…UPPER_BOUND_KEY))` → NPE, the replenish-order list returns 500 if the row is missing. **T0/T1.**
- **D-2** `ReplenishOrderJob:759` `getIntValue(…, 100)` vs `WmsConstants:1361 "84"`. **T0.**
- **D-3** `/fixedAssignment/update` runs three non-transactional adjust\* calls: partial writes, order-dependent validation; no UI caller. **T1.**
- **D-4** `adjust*`/`delete`/`changeActive` have no `@Transactional`. `delete` from the controller runs multi-step Nirvana moves + `deleteById` without its own transaction (the cron wraps it in REQUIRES_NEW, `ReplenishOrderJobService:80`). **T1/T2**, needs DB evidence before tiering.
- **D-5** Stale comments: `FixLocationAssignmentController:22-24` vs repo `exported=false`; `LocationController` C15/C16 "KEEPS its SDR write surface" vs `RestConfiguration:798-808,866-868`. **T0.**
- **D-6** UI dead, verb-inverted actions in `storageLocation.js:115-140` and `locationType.js:61-90` (known §0.B). **T0.**
- **D-7** Doc drift. **T0.**
  - function-to-docs-map `:108,110` lists the wrong endpoints (`/storageLocation/search/*`, `/fixLocationAssignment/*`).
  - sysprop-catalog `:269-271` says "fill %"; the values are absolute quantities.
  - replenishment-design `:337-339` says the default is 0.
  - replenishment-design `:15` omits lowerbound refill eligibility.

## §8 Docs consulted
- `architecture/wms2-function-to-docs-map.md` rows `:108,110,118,224,240`
- `data-dictionary/wms2-sysprop-catalog.md` §2 (`:69-115`), §6 (`:261-288`), §11.3 (`:677-700`)
- `design/wms2-replenishment-design.md` `:13-15`, `:337-339`, `:398-409`
- `architecture/wms2-caching-strategy.md` `:36-59`, `:173-184`
- wms2-api `db/migration/README.md` `:139,142-190,202-270`; headers of V2.2.13, V2.2.32, V2.2.34, V2.2.43
- memory `wms2-gate-a-route-on-its-screens-existing-function.md`
- SBDEV-1468: 0 sbdocs hits; ClickUp not consulted per brief

## Addendum 2026-11-02 — WineCo PRD (wsl-wineco-prd, read-only)
| Check | PRD |
|---|---|
| FLAs total / active | 1576 / 1576 |
| locations with >1 FLA | 0 (UNIQUE index; plan's 1:1 premise holds on PRD) |
| FLAs = 36/60/84 → inherited after backfill | 1529; overridden 47 (33×12/24/36, 8×84/120/168, 2×12/60/84, 2×168/336/504, 1×84/108/168, 1×12/32/36) |
| FLAs violating lower<=middle<upper | 0 |
| FLAs on non-flowbin locations | 0 |
| location rows | 2890 |
| current_schema() (D9 probe premise, prereq #10) | public |
| sysprop FIX_LOCATION_ASSIGNMENT_DEFAULT_VALUE_* (client 0, DEFAULT) | 36 / 60 / 84, clean integers (prereq #9) |
| flyway head | 2.2.40 (V2.2.41–44 still to ship ahead of V2.2.45) |
| M0 authz: STORAGE_LOCATION / FIXED_ASSIGNMENT / storage-only / fixed-only / direct user→role rows | 41 / 41 / 0 / 0 / 0 |
| 53-B06 | flowbin, FLA 36/60/84 → will be Inherited, so a location default of 48 propagates |
Other 5 tenants not measured (no per-tenant MCP); prereqs #5/#9/#10 still owed for them at rollout.
