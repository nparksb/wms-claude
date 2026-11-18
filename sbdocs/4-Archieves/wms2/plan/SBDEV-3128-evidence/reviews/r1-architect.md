# SBDEV-3128 r1 — Architect review (ralplan, deliberate mode)

> Saved by the main session from the lane's returned text (the lane had no Write tool). Content as returned.

**Snapshot:** `SBDEV-3128-evidence/plan-r1-snapshot.md` (r1). **Code:** wms2-api `origin/develop` @ `1b421d08`. **DB:** DEV `dev_wh01_om1` (PG 16.10, `server_version_num=160010`). **Settled, not argued:** D1–D6, and O-1 (clear is allowed on any location type; set requires flowbin).

**Verdict: SOUND-WITH-CHANGES.** The write-through + `bounds_inherited` design (D1) holds up. One High and three Mediums must be fixed before approval.

- **H-1:** create's `FOR SHARE` read rests on a false premise. None of the 5 callers lock the destination before create; they lock it afterwards. As written it adds a share-then-update deadlock on every create, and it breaks an existing H2 integration test. Decision: use a scalar JPQL read at `PESSIMISTIC_WRITE` (`FOR NO KEY UPDATE` on PG).
- **M-1:** the migration header makes two false statements, and Flyway freezes the header text on first apply: "first migration to set lock_timeout" (V2.2.40 already does), and "cannot deadlock against a live transaction".
- **M-2:** an Inherited assignment whose source is the system default drifts from the default shown on screen after a sysprop edit, and "Use location default" is disabled for exactly those rows.
- **M-3:** §7.6 wrongly says no H2 test reaches the new code. An H2 test does reach create.

## Summary

The chosen design is sound. Keeping the 15 replenishment readers untouched is the right driver, the backfill mirrors the Java sysprop read exactly, `SET LOCAL lock_timeout` does take effect, and the plan found every FLA writer. The concurrency design for create is the problem. The plan assumes "callers typically already hold PESSIMISTIC_WRITE" on the destination (§3.6, W1c, analysis §2.6). That is false for all 5 callers: each one locks the destination **after** `createFixedLocationAssignment` returns, inside `transferStockToUnitLoad`. So the native `FOR SHARE` read always becomes a share-then-update upgrade, which deadlocks two concurrent first creates on the same flowbin. It also cannot run on the H2 schema that an existing integration test drives through create. **Decision on O-2:** a scalar JPQL read at `LockModeType.PESSIMISTIC_WRITE` (rendered as `FOR NO KEY UPDATE` on PG and `FOR UPDATE` on H2). Do not use a native lock clause, and do not rely on the caller's lock.

## Analysis — load-bearing claims checked

### (a) Create lock: FOR SHARE vs FOR NO KEY UPDATE vs relying on the caller — DECIDED

Every caller creates the FLA first and locks the destination `Location` later in the same transaction:

| Caller (all `@Transactional(tenantTransactionManager)`, verified) | create | later dest-Location lock |
|---|---|---|
| `StockunitService.transferStock` (`:435-436`) | `:560` | `:575` `stockunitBusinessService.transferStockToUnitLoad(stockUnit, unitLoad, …)` |
| `MobilePutAwayService.storeBoxOnLocation` (`:582-583`) | `:640` | `:648` `transferStockToUnitLoad(sourceStockUnit, assignedUnitLoad, …)` |
| `MobileMoveUnitloadService.scanDestination` (`:355-356`) | `:646` | `transferStock(...)` → `:981` → `transferStockToUnitLoad` |
| `MobileReplenishService.fulfillMultipleUnitLoadsTx` (`:938`) via `assignDestinationForMultiUnitLoads` | `:1109` | the later finish step (`:309` path) → `transferStockToUnitLoad` |
| same, finish step | `:309` | same method, after |

The lock itself is taken at `StockunitBusinessService:349-350`:
```java
Location destinationLocation = LockReads.forUpdate(entityManager, Location.class, destinationLocationId, locationRepository::findByIdForUpdate)
```
`LockReads` javadoc (`:41`) says this renders `FOR NO KEY UPDATE` on PostgreSQL. The replenish transaction confirms the order: "Destination first, holding only the order lock" (`MobileReplenishService` ~`:964`), then the SU locks, then the finish.

What follows:
- **Relying on the caller's lock does not close the race.** No lock is held at the moment create reads the defaults.
- **`FOR SHARE` gives every create the pattern SHARE → later NO KEY UPDATE on the same row.** Two concurrent first creates on one flowbin both take SHARE, then each waits for the other to upgrade, so one is aborted with `40P01` after `deadlock_timeout` (1s on DEV). Today the same pair queues and the loser gets `23505` on `UNIQUE(assignedlocation_id)`. Upgrading against the defaults edit's waiting `FOR NO KEY UPDATE` does not deadlock: PG skips the tuple lock when the transaction already holds a weaker lock on the row. I am reasoning from PG's `heap_lock_tuple`, not from a test.
- **`FOR NO KEY UPDATE` dominates `FOR SHARE`.**
  - It conflicts with the edit's `findByIdForUpdate` exactly as SHARE does, so the race is closed equally well.
  - It is the same mode the caller takes later, so there is no upgrade and no deadlock.
  - Its wait profile is identical: `git grep "FOR SHARE"` finds no other SHARE holder in `src/main`, and `FOR KEY SHARE` (FK inserts from `createUnitload` and the FLA insert) is compatible with both modes.
  - It moves the existing destination lock a few statements earlier, nothing more.
- **Use JPQL with `@Lock(PESSIMISTIC_WRITE)`, not native SQL.** The reason is portability, the rule `LockReads:41-45` already states: "Hand-writing either clause is wrong on one of them — H2 rejects the first". `MobilePutawayServiceIntegrationTest` runs on H2 (`BaseIntegrationTest`, `application-integration.properties:31,38` `jdbc:h2…`, `ddl-auto=create-drop`) and reaches create through `storeBoxOnLocation_putsWholePalletAway` (`:309`, comment `:172-173`). As far as I know H2 2.x only accepts `FOR UPDATE`; the executor should confirm by running that test.
- **JPQL also fails closed for a future caller with no transaction.** The repo documents that a `@Lock` query outside a transaction throws `TransactionRequiredException` (`LocationRepository:~130`, the comment above `getAvailableTransferLanes`). A native `FOR SHARE` instead autocommits and silently releases the lock, which reopens the race. This replaces the plan's "Guard for future callers" paragraph.
- **Residual (Low, same for every lock mode):** taking the destination Location lock early, before the SU/UL locks, inverts the canonical order "Pickingorder BEFORE Stockunit/Unitload/Location" (`StockunitBusinessService:253-255`). A deadlock partner would need to hold the source SU and want this specific empty, unassigned flowbin. I found no such path. Accept it and document it.

### (b) `move()` re-seed under I-1 — correct

The re-seed sits after `:167` `setAssignedlocationId(destination.getId())`. By then `transferUnitLoadToLocation(unitload, destination, false, …)` (`:163`) already holds the destination at `FOR NO KEY UPDATE` (`UnitloadBusinessService:243-246`, `if (!ignoreLock) … LockReads.forUpdate(...)`), so the scalar lock read is re-entrant and returns committed state.
- Inherited assignments take the destination's effective default, which is exactly what I-1 requires.
- Overridden assignments keep their values.
- The `requestForItem` at `:178` already covers the bounds change.
- The `:121` flowbin guard and D6 agree: defaults can only exist on flowbins.

There is one product consequence, below as tension T-2 and L-6.

### (c) Backfill CTE vs `getSysvalue` + `parseSyspropLong` — exact for every realistic value

- `SyspropService.getSysvalue:333-336` only adds the `sysprops` cache; there is no other tier. It calls `SyspropRepository:30`: `select sysvalue from los_sysprop where syskey = :syskey and workstation = 'DEFAULT' order by client_id LIMIT 1`. The CTE copies the predicate, the ordering (NULLs last in both) and `LIMIT 1`.
- `parseSyspropLong` (`FixLocationAssignmentService:301-307`): null falls back to the default, otherwise `Long.parseLong(value)` with no trim.
- The syskey literals match `WmsConstants:1356-1361` (`FIX_LOCATION_ASSIGNMENT_DEFAULT_VALUE_{LOWER,MIDDLE,UPPER}_BOUND` = `36`/`60`/`84`).
- Differences, both harmless because any value that fails either way could never have seeded an FLA:
  - 19-digit values in Long range pass Java but fail the regex and fall back.
  - Non-ASCII Unicode digits pass `Long.parseLong` but fail `[0-9]`.
- DEV re-run: 3 rows, `client_id=0`, `DEFAULT`, values 36/60/84; 1307 of 1344 FLAs match, 0 inactive. `CASE WHEN … THEN sysvalue::numeric END` evaluates its branches in order, so the cast never sees garbage.

### (d) `SET LOCAL lock_timeout` inside Flyway's transaction — takes effect

`StartupFlywayMigrator.tenantConfiguration:131-139` sets only `dataSource`, `outOfOrder` and `baselineOnMigrate(false)`. There is no `mixed`, `group` or `executeInTransaction(false)`, so on PG each migration runs in its own transaction and `SET LOCAL` covers it. There is already a precedent: **`V2.2.40:13` `SET LOCAL lock_timeout = '5s';`**, with the header "StartupFlywayMigrator runs each migration in its default transaction … so SET LOCAL is in scope". That makes the plan's "FIRST migration in this repo to set it" false (M-1).

### (e) `@JsonProperty(READ_ONLY)` against `/v3/location/create` — works, with one caveat

- `LocationController:64-82` binds `@RequestBody Location` through Jackson, and `LocationService.createLocationFromRequest:157-178` saves that object (`:175`). READ_ONLY drops the new fields on input, which closes the mass-assignment hole.
- `/update` (`:86-104`) goes to `updateLocation:186-211`, which copies 13 named fields, so the defaults are neither touched nor clobbered.
- SDR: collection POST is withdrawn (`RestConfiguration:798-808`, `Location.class` in `MUST_STAY_WRITABLE_COLLECTION_CREATE_WITHDRAWN`) and item PUT/PATCH is withdrawn (`:866-868`). GET still serializes READ_ONLY fields.
- `git grep convertValue|readValue|treeToValue|BeanUtils.copyProperties` finds nothing touching Location or FLA.
- AC-12 is valid because `BaseControllerUnitTest` drives MockMvc, so Jackson really is in the path.
- **Caveat:** `CacheConfig:50-75` has a `@Profile("redis")` cache manager that serializes cached `Location`s with `GenericJackson2JsonRedisSerializer`. Jackson applies READ_ONLY there too, so cached Locations would come back with null defaults. Whether the `redis` profile runs anywhere cannot be determined from the repo (`wms2-caching-strategy.md:288`). See L-3.

### (f) `@CacheEvict("locations", allEntries=true)` on `FixLocationAssignmentService.updateLocationBoundDefaults` — correct

- The cache name matches `CacheConfig:38` and `LocationService:100` (`getByName`, key `tenant:name`). `allEntries` follows the precedent at `LocationService:156,186`.
- Self-invocation is not an issue: the only caller is `LocationController`, through the proxy.
- Minor: `SimpleCacheManager` is not transaction-aware, so the evict runs before commit and a concurrent `getByName` on that replica can re-cache the old row for up to 5 minutes. The precedent behaves the same, and §3.5 correctly routes no defaults reader through this cache. Not a finding.

### (g) Independent writer enumeration — no missed FLA writer

Grep strings run on `origin/develop`:
- G-a `setLowerbound|setMiddlebound|setUpperbound|setBoundsInherited` in `src/main`: only `FixLocationAssignmentService:98-100,192,210,228`.
- G-b native `(update|insert into|delete from) fix_location_assignment`: only `demo-datasets/meridian/fixtures.sql:86`.
- G-c native `(update|insert into) location`: 0 in `src/main/java`.
- G-d `fixLocationAssignmentRepository.save*` and `new FixLocationAssignment()`: only the service (`:93,102,168,193,211,229,295`).
- G-e `@Modifying` in both repositories: 0.
- `setAssignedlocationId`: `:94` and `:167` only.
- `locationRepository.save`: `LocationService:89` (new), `:148` (`createSystemStorageLocation`, private and never called), `:175` (new from request), `:208` (fresh `findById` copy), `FileImportController:314` (always `new Location()`, no upsert), `UtilRestController:878-930` (initDB: fresh managed entities, retypes gates, staging lanes and the users area).
- Controllers: only `FixLocationAssignmentController` touches FLA (`:76-82,106,129,148,161,184,207`), all through the service.

Blind spots: method references, reflection, raw `EntityManager.merge`, SQL outside `src/main` (onboarding SQL is R15), and DBA hand edits.

### (h) `ViewDtoService:708` fold-in — safe only as a null/blank fallback

`:708` reads `BigDecimal upperBound = new BigDecimal(syspropService.getSysvalue(…UPPER_BOUND_KEY));`. Today a value like `"84.5"` parses there. Switching to `Long.parseLong` (what "parseSyspropLong-style" literally means) would turn it into a 500 on the replenish-order list. Only the null case should change (L-5).

## Root Cause (of the High)

The analysis inferred lock order from `transferUnitLoadToLocation(…, ignoreLock=false)`. That is the **move** path. None of the 5 **create** paths uses it before create: they drain stock into the FLA's virtual unit load through `transferStockToUnitLoad`, which locks the destination last. The §3.6 table, §10.2, L10, AC-17 and the mutation table all inherit that wrong premise.

## Findings

### High

**H-1 — Create's lock read: wrong premise, wrong mode, wrong mechanism.**
- Evidence: plan §3.6, "callers typically already hold PESSIMISTIC_WRITE via `transferUnitLoadToLocation(…, ignoreLock=false)`"; contradicted by the caller table in (a). `LockReads:41-45`: "Hand-writing either clause is wrong on one of them — H2 rejects the first". `MobilePutawayServiceIntegrationTest:309` runs on H2 through create.
- Fix:
  - Replace L10 with a JPQL scalar `@Query("select l.defaultLowerbound as lower, l.defaultMiddlebound as middle, l.defaultUpperbound as upper from Location l where l.id = :id") @Lock(LockModeType.PESSIMISTIC_WRITE) @RestResource(exported = false)`, or the `LockReads`-style `entityManager.createQuery(...).setLockMode(PESSIMISTIC_WRITE)`.
  - Rewrite §3.6 rows "create", "move" and "reset", and §10.2 bullet 5, to say `FOR NO KEY UPDATE`.
  - Delete the "share→update residual" paragraph and replace it with the Low lock-order inversion residual from (a).
  - Change the mutation-table row to "lock mode removed → AC-17 red".
  - Add to §7.6 #7 that the H2 suite (`MobilePutawayServiceIntegrationTest`) must stay green.
  - Change W1c's note to "callers lock the destination AFTER create (`StockunitBusinessService:350`)".

### Medium

**M-1 — The migration header carries two false statements, and Flyway's checksum freezes them on first apply.**
- Evidence: plan §3.1 says "FIRST migration in this repo to set it", against `V2.2.40:13` `SET LOCAL lock_timeout = '5s';`. It also says "LOCK ORDER location -> fix_location_assignment, the same order the application takes … cannot deadlock against a live transaction". That is false: the migration takes **table-level** ACCESS EXCLUSIVE locks, and any live transaction that has read `fix_location_assignment` (AccessShare, e.g. the replenishment job reads FLAs first) and then reads `location` deadlocks against it. PG aborts one of the two. If it aborts the migration, that tenant runs the new jar on the old schema, and every Location read fails with `42703` (PM-1) until a restart.
- Fix:
  - Header: cite V2.2.40 as precedent, and replace the deadlock sentence with "a deadlock against a live reader is possible; PG aborts one side; if it is this migration, same outcome as 55P03 (no history row, tenant stale, retry on next boot)".
  - §8: deploy P1 to each environment in a low-traffic window, and verify prerequisite #5 within minutes, not 24 hours.
  - Keep 10s, or align with V2.2.40's 5s.
  - Correct D4's "first in repo" wording in the ADR (fact only; D4 itself stands).

**M-2 — "Inherited" with source SYSTEM silently goes stale after a sysprop edit, and the reset that would fix it is disabled.**
- Evidence: §3.3 "Sysprop edits are not written through (R-5)"; §3.4 computes `defaultSource` and the effective triple from the **current** sysprop at `ViewDtoService:905`; §3.7 "Use location default", "enabled only when Overridden"; O-4 checks only `l.default_lowerbound is not null` rows.
- After a sysprop change from 36/60/84 to 30/50/70, the screen shows chip *Inherited*, bounds 36/60/84, "Default: 30/50/70 (system)", and no way to resync. That fails AC (e), "UI shows inherited vs overridden", in a way an operator can see.
- Fix:
  - Enable "Use location default" whenever the stored triple differs from the effective default, not only when Overridden.
  - Render the chip as "Inherited (out of date)" when they differ.
  - Widen O-4 to `COALESCE(l.default_*, sysprop)`.

**M-3 — §7.6 #7 "H2 test SQL: n/a" is wrong.**
- Evidence: `application-integration.properties:31,38` (`jdbc:h2…`, `ddl-auto=create-drop`). `MobilePutawayServiceIntegrationTest extends BaseIntegrationTest` and drives create.
- Fix: H-1's JPQL lock fixes the lock clause. Also add `@ColumnDefault("false")` (or `columnDefinition = "boolean NOT NULL DEFAULT false"`) to `boundsInherited`, so the H2 schema matches PG for any SQL fixture that leaves the column out. The 10 current SQL-inserting tests I checked look PG-backed, so today this is defensive.

### Low

- **L-1 — D5's risk description is overstated.**
  - `StockunitBusinessService:350` and `UnitloadBusinessService:245` take the destination through `LockReads.forUpdate`. On a managed entity that does a scalar lock plus `refresh` instead of a version-checked upgrade (`LockReads:20-47`), so a concurrent defaults edit does **not** raise `StaleObjectStateException` on the flowbin put-away, move or replenish paths.
  - The remaining direct `findByIdForUpdate` users are `UnitloadService:188` (damaged location) and `MobileTruckLoadingWriteService:582` (gate), and neither is a flowbin.
  - Fix: reword §3.6 D5, PM-3 and the planned javadoc to say this. Keep O-3 as a canary.
- **L-2 — Option F's rejection reasoning is incomplete.** §9 F: "Location has no `@DynamicUpdate` … any concurrent full-row save overwrites the defaults". That holds only while the columns are `updatable`. With `@Column(insertable=false, updatable=false)` an entity save never writes them. See the synthesis; Nam decides, since it changes D5's premise.
- **L-3 — READ_ONLY interacts with the `redis` cache profile** (`CacheConfig:50-75`): cached Locations lose their defaults. No reader is affected today. Fix: name this in §3.5. Optionally, also null the three fields explicitly in `createLocationFromRequest` (3 lines), so the protection does not depend on Jackson.
- **L-4 — The sysprop parse error now reaches new surfaces.** `systemDefaultBounds()` "NumberFormatException on garbage, unchanged" (§3.3) is now also called from the Fixed Locations view (`ViewDtoService:905`; that screen reads no sysprops today), from `move` of an inherited FLA, from reset and from clear. Fix: on the display path, catch the error and render `defaultSource=SYSTEM_INVALID` with a null triple; add a PRD prerequisite that `sysvalue ~ '^[+-]?[0-9]{1,18}$'` holds for all three keys.
- **L-5 — `ViewDtoService:708` fold-in:** keep `new BigDecimal(value.trim())` for non-null values and fall back to `"84"` only on null or blank. Add a unit test for "row absent → no NPE" and mutation-check it.
- **L-6 — `move` of an Overridden FLA keeps bounds tuned for the old bin's capacity**, against the premise of the ticket (the 53-B06 roller lanes physically hold 48). Fix: when the destination's effective default differs, add a non-blocking warning to the move response or the UI note. No behavior change.
- **L-7 — Precision.** Inputs with more than 4 decimal places pass Java's `m < u` check, then round in `numeric(17,4)` to `m = u`, so the CHECK fails and returns a raw DataIntegrityViolation in `{errors}`. Fix: in step 1, reject `scale() > 4` (or `setScale(4, UNNECESSARY)`). Tests should compare with `compareTo`, because `24.0000` does not `equals` `24`.

### Ruled out (checked, no finding)

- The backfill mirror (c).
- `SET LOCAL` scope (d).
- READ_ONLY on `/create` and `/update`, and SDR GET (e).
- Cache name, key and self-invocation (f).
- FLA writer completeness (g).
- `LocationController` absent from `GUARDED` (`FunctionGuardInterceptor:119`): the method-level gate is mandatory, as the plan says.
- `ReplenishmentMaintenanceCallSiteArchTest` `ALLOWED` is unaffected, because new code goes through the trigger.
- The edit-vs-reset and edit-vs-adjust races end in `@Version` failures, which are loud and safe.
- No `V2.2.45` exists on any local remote ref or in any `.claude/worktrees/wms2-api/*` (local refs only; still fetch at commit).
- FLA bound columns are `numeric(17,4) NOT NULL` on DEV, matching the plan.
- Location `getDetailView` already returns `lt.sltname` (`LocationRepository:279-291`), so the UI flowbin filter works.
- Not re-verified: the wms2-web-ui P2 rows (U1–U8).

## Recommendations (prioritized)

1. H-1: switch to a JPQL `PESSIMISTIC_WRITE` scalar read and rewrite §3.6, L10, W1c, §10.2 and §7.3. Small effort; removes a deterministic upgrade pattern and an H2 break.
2. M-1: correct the migration header before first commit, and add the low-traffic deploy window. Small effort; the header is permanent once applied.
3. M-2: resync when stored differs from effective, widen O-4. Small–medium effort; makes AC (e) true.
4. M-3: add `@ColumnDefault("false")` and the H2 note. Trivial.
5. The Lows, all in the same pass (house rule).

## Trade-offs

| Option for create's lock | Pros | Cons |
|---|---|---|
| Native `FOR SHARE` (plan) | weakest lock | upgrades to NO KEY UPDATE in every caller, so two concurrent creates deadlock; H2 rejects it; outside a transaction it silently releases |
| Rely on caller's lock | zero cost | no lock exists when create reads, so the race stays open |
| **JPQL `PESSIMISTIC_WRITE` (chosen)** | no upgrade; portable across H2 and PG; throws `TransactionRequiredException` outside a transaction | takes the destination lock a few statements earlier; same Low lock-order inversion as `FOR SHARE` |

## Consensus Addendum

- **Antithesis (steelman):** Write-through turns `fix_location_assignment.{lower,middle,upper}bound` into a cache with several writers, plus a flag that no database constraint can verify. I-1 spans two tables and a sysprop, so every future writer has to know about it, and so do fixtures, onboarding SQL and DBA hand edits; when one doesn't, the result is a silent mislabel, not an error (O-4 only detects it after the fact). The flag already means two things: it follows location edits but not sysprop edits (M-2). And mapping the defaults on `Location`, the most-read entity, means a failed V2.2.45 on one tenant becomes `42703` on every Location read for that tenant (PM-1), not just a broken feature. It also adds a version-bumping operator writer (D5). Read-time resolution, or a side table, keeps one source of truth and limits a failure to the feature.
- **Tradeoff tension:**
  - **T-1:** readers stay byte-identical (the D1 driver) versus a provenance flag that cannot be fully truthful about the system tier unless sysprop edits are also written through, which would be a new mass-write path on the sysprop endpoint.
  - **T-2:** AC (f), "SKU-specific behavior stays", versus the ticket's premise that bounds belong to physical capacity. An Overridden FLA that moves keeps bounds tuned for the wrong bin.
- **Synthesis (within D1):** keep `default_*` on `location`, but map them `@Column(insertable = false, updatable = false)`.
  - Read them with the H-1 JPQL lock query.
  - Write them in `updateLocationBoundDefaults` with a JPQL bulk `update Location l set l.defaultLowerbound = …` under the same `FOR NO KEY UPDATE`, without loading the entity; check the type with a scalar query.
  - Entity saves (`updateLocation`, initDB, a Redis-deserialized Location) can never clobber the defaults, so READ_ONLY stops being load-bearing.
  - The version bump disappears, so D5 becomes moot.
  - Cost: one bulk-update query, and the rule "never load the Location entity in that method". It does not reduce the `42703` blast radius; only leaving the columns unmapped would, and that breaks the H2 `create-drop` harness.
  - Nam to choose. It changes D5's premise but not D1.
- **Principle violations (deliberate mode):**
  - Principle 2, "one invariant, every writer": partially violated by R-5 (the sysprop tier is outside the invariant, yet the UI labels those rows Inherited). Medium; that is M-2.
  - The fail-safe principle holds: the backfill and `DEFAULT false` are correct.
  - The plan's own §0 rule that every claim is re-read: violated by W1c's lock-order claim, carried over from the analysis without checking. High; that is H-1.

## References

- `src/main/java/net/aim_ai/wms/service/FixLocationAssignmentService.java:83-107,109-179,301-307`: create, move, `parseSyspropLong`
- `src/main/java/net/aim_ai/wms/service/StockunitBusinessService.java:253-255,349-350`: canonical lock order; destination Location locked last
- `src/main/java/net/aim_ai/wms/service/UnitloadBusinessService.java:243-246`: move path destination lock
- `src/main/java/net/aim_ai/wms/service/LockReads.java:20-47`: `FOR NO KEY UPDATE` rendering, H2 incompatibility, refresh-not-upgrade
- `src/main/java/net/aim_ai/wms/service/StockunitService.java:435-436,560,575`
- `src/main/java/net/aim_ai/wms/service/mobile/MobilePutAwayService.java:582-583,640,648`
- `src/main/java/net/aim_ai/wms/service/mobile/MobileMoveUnitloadService.java:355-356,646,981`
- `src/main/java/net/aim_ai/wms/service/mobile/MobileReplenishService.java:309,938,1109`
- `src/main/java/net/aim_ai/wms/repo/jpa/LocationRepository.java:26-46,122-125,278-291`
- `src/main/java/net/aim_ai/wms/repo/jpa/SyspropRepository.java:30`; `service/SyspropService.java:333-336`; `service/WmsConstants.java:1356-1361`
- `src/main/java/net/aim_ai/wms/landlord/service/StartupFlywayMigrator.java:131-139`; `src/main/resources/db/migration/V2.2.40__bol_shipped_chunk_size_and_outbox_message_link.sql:4-13`
- `src/main/java/net/aim_ai/wms/controller/LocationController.java:64-104`; `service/LocationService.java:100,157-211`; `RestConfiguration.java:798-808,866-868`
- `src/main/java/net/aim_ai/wms/config/CacheConfig.java:33-75`
- `src/main/java/net/aim_ai/wms/service/ViewDtoService.java:708,903-925`
- `src/test/resources/application-integration.properties:31,38,51`; `src/test/java/net/aim_ai/wms/integration/service/mobile/MobilePutawayServiceIntegrationTest.java:172-173,309`

**Verdict: SOUND-WITH-CHANGES.**
