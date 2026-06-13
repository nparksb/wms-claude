# SBDEV-2096 (V2): Configurable Pick Path Direction (Horizontal vs Vertical)

**Ticket:** SBDEV-2096
**Priority:** Urgent | **Points:** 8 | **Requester:** WineCo
**Assignees:** David Oppenheim, Nam Park
**Date:** 2026-04-11
**V1 Status:** Implemented on `develop` (commit `665cd8c`)
**V2 Status:** Implemented — commit `0459169b` (direct to `develop`, 2026-05-06); startup fix `711e4dee`. No separate PR (direct-to-develop). Status: archived 2026-05-21.

---

## 1. V1 → V2 Applicability Analysis

The V1 implementation added a `PICK_PATH_DIRECTION` system property and parameterized both `DefaultStrategy` and `CycleCountStrategy` with a `PickPathDirection` enum via a dedicated `PickPathConfig @Component` (30s TTL cache). V2 has the same location sorting infrastructure plus one V2-only addition: `InMemoryLocationComparator` — a pre-fetching optimization used by `MobilePickingService`.

### V2 Differences from V1

| Aspect | V1 (as implemented) | V2 (current state) | Impact |
|--------|----|----|--------|
| `PickPathDirection` enum | `net.aim_ai.wms.util.PickPathDirection` (`HORIZONTAL`, `VERTICAL`) | **Does not exist** | **Must create** |
| `PickPathConfig` | `@Component` in `service/`, 30s TTL volatile cache, reads via `LosSyspropRepository` | **Does not exist** | **Must create — use `SyspropService.getSysvalue()` directly; no local TTL cache needed (SyspropService `@Cacheable` already provides per-tenant caching)** |
| `DefaultStrategy` | 3-arg constructor taking `PickPathDirection`; all 5 callsites wired | 2-arg constructor only; hardcoded X-first | **Needs porting** |
| `CycleCountStrategy` | 3-arg constructor taking `PickPathDirection`; `MobileCycleCountService` wired | 2-arg constructor only; not parameterized | **Needs porting** |
| `InMemoryLocationComparator` | **Does not exist** | V2-only class, used by `MobilePickingService` at line 736 | **NEW — needs direction support using `PickPathDirection`** |
| Callsite scope | All 7 callsites wired | 0 callsites wired | **All 7 must be wired** |
| System property access | `LosSyspropRepository.findSysvalueBySyskey()` | `SyspropService.getSysvalue()` (V2 convention) | Use `SyspropService` in `PickPathConfig` |
| Migration numbering | `V2.1.04` | Latest is `V2.1.08` | New migration: `V2.1.09` |
| Default value | `VERTICAL` (X-first = current behavior) | N/A | Seed `VERTICAL` — no behavior change |
| `WmsConstants` | `SYSTEM_PROPERTY_PICK_PATH_DIRECTION_KEY` (only; no string mirrors for enum values) | **Does not exist** | **Must add** |
| Test coverage | `PickPathConfigUnitTest`, `DefaultStrategyUnitTest`, `CycleCountStrategyUnitTest`, HORIZONTAL tests in 5 service tests | `CycleCountStrategyUnitTest` only (direction-unaware) | **Must add PickPathConfig, DefaultStrategy, InMemoryLocationComparator, and service-level tests** |

### What Needs Porting (6 items)

1. **`PickPathDirection` enum** — Create identical to V1: `HORIZONTAL` (Y-first) and `VERTICAL` (X-first, default)
2. **`PickPathConfig` @Component** — Create without local TTL cache; call `SyspropService.getSysvalue()` directly (per-tenant caching is provided by SyspropService's `@Cacheable`)
3. **`DefaultStrategy`** — Add `PickPathDirection` field + 3-arg constructor + direction-aware XY comparison (same as V1)
4. **`CycleCountStrategy`** — Same pattern as DefaultStrategy (same as V1)
5. **`InMemoryLocationComparator`** — Add `PickPathDirection` field + 3-arg constructor + direction-aware XY comparison (V2-only, parallel to DefaultStrategy)
6. **All 7 callsite wirings** — Inject `PickPathConfig`, fetch direction once per method, pass to strategy/comparator constructor
7. **Constants + migration** — `WmsConstants` constants + `V2.1.09` Flyway migration seeding `VERTICAL`

### What Does NOT Need Porting

- Non-picking architectural differences — V2's tenant transaction manager, `@Transactional` annotations, etc. are unchanged by this feature
- `InMemoryLocationComparator` data wiring — Only the comparator's XY logic changes; the existing Map pre-fetching pattern stays unchanged

---

## 2. Current Architecture

### Location Sorting Comparators

| Comparator | Used By | Data Source | V2 File |
|-----------|---------|-------------|---------|
| `DefaultStrategy` | Putaway (3×), Stock Move (1×), Tote Label Printing (1×) | Repository calls per comparison | `util/DefaultStrategy.java` |
| `InMemoryLocationComparator` | Mobile Picking (1×) | Pre-fetched Maps (bulk loaded) | `util/InMemoryLocationComparator.java` |
| `CycleCountStrategy` | Cycle Count (1×) | Repository calls per comparison | `util/CycleCountStrategy.java` |

### All Callsites (7 locations)

| # | File | Line | Comparator | Context | Wired in V1? |
|---|------|------|-----------|---------|-------------------|
| 1 | `MobilePickingService.java` | 736 | `InMemoryLocationComparator` | Sorts picking positions for mobile display | Yes |
| 2 | `OrderMonitorViewService.java` | 258 | `DefaultStrategy` | Sorts positions for tote label printing | Yes |
| 3 | `MobilePutAwayService.java` | 297 | `DefaultStrategy` | Sorts flowbin locations for putaway | Yes |
| 4 | `MobilePutAwayService.java` | 307 | `DefaultStrategy` | Sorts overstock locations for putaway | Yes |
| 5 | `MobilePutAwayService.java` | 328 | `DefaultStrategy` | Sorts combined location list for putaway | Yes |
| 6 | `MobileMoveStockService.java` | 200 | `DefaultStrategy` | Sorts storage locations for stock transfer | Yes |
| 7 | `MobileCycleCountService.java` | 275 | `CycleCountStrategy` | Sorts locations for cycle count | Yes |

All 7 callsites receive the direction flag from `pickPathConfig.getDirection()`.

### `PickPathDirection` Semantics

| Value | XY Behaviour | Warehouse Traversal |
|-------|-------------|-------------------|
| `VERTICAL` (default) | X-first, then Y | Column-major: walk up each column before moving to next |
| `HORIZONTAL` | Y-first, then X | Row-major: walk across each level before moving to next level |

---

## 3. Fix Design

### Fix 0: Create `PickPathDirection` Enum

**File:** `src/main/java/net/aim_ai/wms/util/PickPathDirection.java`

```java
package net.aim_ai.wms.util;

public enum PickPathDirection {
    HORIZONTAL,
    VERTICAL
}
```

### Fix 1: Create `PickPathConfig` @Component

**File:** `src/main/java/net/aim_ai/wms/service/PickPathConfig.java`

```java
@Component
public class PickPathConfig {

    private static final Logger log = LoggerFactory.getLogger(PickPathConfig.class);

    @Autowired
    private SyspropService syspropService;

    @PostConstruct
    public void init() {
        log.info("PickPathConfig initialized — direction: {}", getDirection());
    }

    public PickPathDirection getDirection() {
        return parse(syspropService.getSysvalue(WmsConstants.SYSTEM_PROPERTY_PICK_PATH_DIRECTION_KEY));
    }

    private PickPathDirection parse(String raw) {
        if (raw == null || raw.trim().isEmpty()) return PickPathDirection.VERTICAL;
        try {
            return PickPathDirection.valueOf(raw.trim().toUpperCase());
        } catch (IllegalArgumentException e) {
            log.warn("Unknown PICK_PATH_DIRECTION value '{}' — defaulting to VERTICAL.", raw.trim());
            return PickPathDirection.VERTICAL;
        }
    }
}
```

**V2 note:** No local TTL cache — `SyspropService.getSysvalue()` is `@Cacheable` with a per-tenant key (`facilityCode + ':' + syskey`), so it already provides efficient, tenant-scoped caching. Adding a process-level TTL on top would introduce cross-tenant bleed (all tenants on the same replica sharing one `volatile` field). The `@PostConstruct init()` logs the resolved direction at startup for diagnostics. The `parse()` method uses `PickPathDirection.valueOf()` with a WARN on unknown values — same semantics as V1, but without the silent `equalsIgnoreCase` approach.

### Fix 2: Add Direction Support to `DefaultStrategy`

**File:** `src/main/java/net/aim_ai/wms/util/DefaultStrategy.java`

```java
// Add field:
private PickPathDirection direction;

// Backward-compatible constructor (delegates to VERTICAL):
public DefaultStrategy(LocationRackRepository rackRepository, LocationRackRowRepository rackRowRepository) {
    this(rackRepository, rackRowRepository, PickPathDirection.VERTICAL);
}

// New 3-arg constructor:
public DefaultStrategy(LocationRackRepository rackRepository, LocationRackRowRepository rackRowRepository, PickPathDirection direction) {
    this.locationRackRepository = rackRepository;
    this.locationRackRowRepository = rackRowRepository;
    this.direction = direction;
}
```

Replace the existing hardcoded XY comparison block with:

```java
if (direction == PickPathDirection.HORIZONTAL) {
    int o1_level = o1.getYpos();
    int o2_level = o2.getYpos();
    if (o1_level != o2_level) return o1_level < o2_level ? -1 : 1;

    int o1_column = o1.getXpos();
    int o2_column = o2.getXpos();
    if (o1_column != o2_column) return o1_column < o2_column ? -1 : 1;
} else {
    int o1_column = o1.getXpos();
    int o2_column = o2.getXpos();
    if (o1_column != o2_column) return o1_column < o2_column ? -1 : 1;

    int o1_level = o1.getYpos();
    int o2_level = o2.getYpos();
    if (o1_level != o2_level) return o1_level < o2_level ? -1 : 1;
}
```

### Fix 3: Add Direction Support to `CycleCountStrategy`

**File:** `src/main/java/net/aim_ai/wms/util/CycleCountStrategy.java`

Same pattern as Fix 2 — add `PickPathDirection direction` field, 3-arg constructor delegating default to `VERTICAL`, and identical direction-aware XY comparison block. The only V2 difference: `CycleCountStrategy` falls through to `compareNames()` for equal X+Y instead of throwing `UnsupportedOperationException`.

### Fix 4: Add Direction Support to `InMemoryLocationComparator` (V2-ONLY)

**File:** `src/main/java/net/aim_ai/wms/util/InMemoryLocationComparator.java`

```java
// Add field:
private final PickPathDirection direction;

// Backward-compatible constructor (delegates to VERTICAL):
public InMemoryLocationComparator(Map<Long, LocationRack> rackMap, Map<Long, LocationRackRow> rackRowMap) {
    this(rackMap, rackRowMap, PickPathDirection.VERTICAL);
}

// New 3-arg constructor:
public InMemoryLocationComparator(Map<Long, LocationRack> rackMap, Map<Long, LocationRackRow> rackRowMap, PickPathDirection direction) {
    this.rackMap = rackMap;
    this.rackRowMap = rackRowMap;
    this.direction = direction;
}
```

Replace the existing hardcoded XY comparison block with the same direction-aware block as Fix 2.

Also update the class Javadoc (currently reads `"rack row ordinal → rack ordinal → column (xpos) → level (ypos)"`) to:

```
Replicates the sorting logic of {@link DefaultStrategy}: rack row ordinal → rack ordinal →
(column → level for VERTICAL, level → column for HORIZONTAL).
```

### Fix 5: Add System Property Constants

**File:** `src/main/java/net/aim_ai/wms/service/WmsConstants.java`

Add after existing `SYSTEM_PROPERTY_*` constants:

```java
// Pick Path Direction (SBDEV-2096) — valid values: HORIZONTAL, VERTICAL
public static final String SYSTEM_PROPERTY_PICK_PATH_DIRECTION_KEY = "PICK_PATH_DIRECTION";
```

**Only `_KEY` is needed.** `PickPathConfig.parse()` uses `PickPathDirection.valueOf()` to resolve any valid enum name, so no separate string constants for `HORIZONTAL`/`VERTICAL`/`DEFAULT_VALUE` are required. Adding string-constant mirrors for enum members creates drift risk (the constants and the enum diverge silently). Default is `VERTICAL` (X-first = current hardcoded behavior — no behavior change on existing deployments).

### Fix 6: Wire All 7 Callsites

Each affected service gets `@Autowired private PickPathConfig pickPathConfig;` injected, and each callsite becomes:

```java
PickPathDirection pickDir = pickPathConfig.getDirection();  // fetch once per method
```

#### 6a: `MobilePickingService.java` (line 736)

```java
// Before:
InMemoryLocationComparator comparator = new InMemoryLocationComparator(rackMap, rackRowMap);

// After:
PickPathDirection pickDir = pickPathConfig.getDirection();
InMemoryLocationComparator comparator = new InMemoryLocationComparator(rackMap, rackRowMap, pickDir);
```

`SyspropService` is already injected — `PickPathConfig` replaces direct sysprop reads for this concern.

#### 6b: `OrderMonitorViewService.java` (line 258)

```java
// Before:
DefaultStrategy ds = new DefaultStrategy(locationRackRepository, locationRackRowRepository);

// After:
PickPathDirection pickDir = pickPathConfig.getDirection();
DefaultStrategy ds = new DefaultStrategy(locationRackRepository, locationRackRowRepository, pickDir);
```

#### 6c–6e: `MobilePutAwayService.java` (lines 297, 307, 328)

All 3 callsites inside `sortPutAwayItemDataList()` — fetch direction once at the top of the method:

```java
private void sortPutAwayItemDataList(...) {
    final PickPathDirection pickDir = pickPathConfig.getDirection();  // fetch once; captured by BiConsumer lambdas
    // ... existing BiConsumer lambdas use pickDir for each new DefaultStrategy(...) call ...
}
```

> **Lambda capture note:** Declare `pickDir` as `final` (or rely on effective-finality by never reassigning it). The two BiConsumers at lines ~294 and ~304 capture `pickDir` — if it were reassigned after capture, the compile would fail. Being explicit with `final` prevents a future developer from accidentally assigning to it mid-method and hitting a confusing compiler error.

#### 6f: `MobileMoveStockService.java` (line 200)

```java
// Before:
resultList.sort(new DefaultStrategy(locationRackRepository, locationRackRowRepository));

// After:
PickPathDirection pickDir = pickPathConfig.getDirection();
resultList.sort(new DefaultStrategy(locationRackRepository, locationRackRowRepository, pickDir));
```

#### 6g: `MobileCycleCountService.java` (line 275)

```java
// Before:
resultList.sort(new CycleCountStrategy(locationRackRepository, locationRackRowRepository));

// After:
PickPathDirection pickDir = pickPathConfig.getDirection();
resultList.sort(new CycleCountStrategy(locationRackRepository, locationRackRowRepository, pickDir));
```

### Fix 7: Flyway Migration

**File:** `src/main/resources/db/migration/V2.1.09__add_pick_path_direction_sysprop.sql`

```sql
-- SBDEV-2096: Add configurable pick path direction system property
-- ID 145 continues the sequence established by V2.1.08 (ids 142/143/144).
-- VERTICAL = X-first (column-major, current default behavior — no disruption to existing deployments)
-- HORIZONTAL = Y-first (row-major, new optional behavior for WineCo)
INSERT INTO los_sysprop (id, groupname, syskey, sysvalue, description, additionalcontent,
                         client_id, version, hidden, workstation, entity_lock, created, modified)
VALUES (145, 'Operation Options', 'PICK_PATH_DIRECTION', 'VERTICAL',
        'Pick Path Direction',
        'Controls whether picking, putaway, stock moves, and cycle counts traverse locations by row (HORIZONTAL) or column (VERTICAL). Valid values: HORIZONTAL, VERTICAL.',
        0, 0, FALSE, 'DEFAULT', 0, NOW(), NOW())
ON CONFLICT (client_id, syskey, workstation) DO NOTHING;
```

> **Migration notes:**
> - `V2.1.08` (`stale_club_batch_cleanup_sysprops`) is the current latest (ids 142/143/144). This migration uses id 145.
> - `ON CONFLICT (client_id, syskey, workstation) DO NOTHING` matches the actual unique constraint `uk8tcoe23qui9q3ancbhx662iqb` and makes the migration idempotent (safe to re-run and safe if the row already exists from a prior dev-environment deployment).
> - `groupname = 'Operation Options'` matches the v1 migration and the WMS admin UI grouping for operational settings. V2.1.08 used `'Backend'` for infrastructure-level sysprops — pick path direction is operator-facing, so `'Operation Options'` is correct here.
> - **Rollback:** `DELETE FROM los_sysprop WHERE syskey = 'PICK_PATH_DIRECTION' AND client_id = 0;` — Flyway does not auto-rollback; run manually if needed.
> - Verify no conflicting migration was added before implementing.

---

## 4. File Change Summary

| File | Change Type | Description |
|------|------------|-------------|
| `util/PickPathDirection.java` | **New** | Enum: `HORIZONTAL`, `VERTICAL` |
| `service/PickPathConfig.java` | **New** | `@Component`; delegates to `SyspropService` directly (no local cache); `parse()` with WARN; `@PostConstruct` log |
| `service/WmsConstants.java` | Modify | Add 1 constant: `SYSTEM_PROPERTY_PICK_PATH_DIRECTION_KEY` |
| `util/DefaultStrategy.java` | Modify | Add `PickPathDirection` field, 3-arg constructor, direction-aware XY comparison |
| `util/CycleCountStrategy.java` | Modify | Same pattern as DefaultStrategy |
| `util/InMemoryLocationComparator.java` | Modify | Same pattern as DefaultStrategy (V2-only); update class Javadoc to reflect direction-aware sort order |
| `service/mobile/MobilePickingService.java` | Modify | Inject `PickPathConfig`; pass direction to `InMemoryLocationComparator` (line 736) |
| `service/OrderMonitorViewService.java` | Modify | Inject `PickPathConfig`; pass direction to `DefaultStrategy` (line 258) |
| `service/mobile/MobilePutAwayService.java` | Modify | Inject `PickPathConfig`; pass direction at all 3 callsites (lines 297, 307, 328) |
| `service/mobile/MobileMoveStockService.java` | Modify | Inject `PickPathConfig`; pass direction at callsite (line 200) |
| `service/mobile/MobileCycleCountService.java` | Modify | Inject `PickPathConfig`; pass direction to `CycleCountStrategy` (line 275) |
| `db/migration/V2.1.09__add_pick_path_direction_sysprop.sql` | **New** | Seeds `PICK_PATH_DIRECTION = 'VERTICAL'` (id=145); `ON CONFLICT (client_id, syskey, workstation) DO NOTHING` |

**New test files:**

| File | Description |
|------|-------------|
| `unit/service/PickPathConfigUnitTest.java` | Parse semantics (null/empty/case/whitespace/unknown→VERTICAL), WARN log, delegation-per-call contract |
| `unit/util/DefaultStrategyUnitTest.java` | VERTICAL/HORIZONTAL full sort order, same-X/Y edge cases, rack precedence, null handling |
| Updates to `unit/util/CycleCountStrategyUnitTest.java` | Add HORIZONTAL direction tests (currently tests 2-arg only) |
| Updates to `unit/util/InMemoryLocationComparatorUnitTest.java` | Add HORIZONTAL direction tests |
| HORIZONTAL tests in 5 service unit tests | `@Mock PickPathConfig pickPathConfig` + `HORIZONTAL` sort-order assertions in MobilePickingService, OrderMonitorViewService, MobilePutAwayService, MobileMoveStockService, MobileCycleCountService tests |

---

## 5. Implementation Steps

### Step 1: Create `PickPathDirection` Enum
- New file `util/PickPathDirection.java` — `HORIZONTAL`, `VERTICAL`

### Step 2: Add System Property Constants
- Add 1 constant to `WmsConstants.java`: `SYSTEM_PROPERTY_PICK_PATH_DIRECTION_KEY`

### Step 3: Modify `DefaultStrategy`
- Add `PickPathDirection direction` field
- Add 3-arg constructor (keep 2-arg delegating to VERTICAL)
- Replace hardcoded XY comparison with direction-aware block

### Step 4: Modify `CycleCountStrategy`
- Same pattern as Step 3 — add field, 3-arg constructor, direction-aware XY block

### Step 5: Modify `InMemoryLocationComparator` (V2-only)
- Same pattern as Step 3

### Step 6: Create `PickPathConfig` @Component
- New file `service/PickPathConfig.java`
- No local cache — call `SyspropService.getSysvalue(SYSTEM_PROPERTY_PICK_PATH_DIRECTION_KEY)` directly
- `parse()` method using `PickPathDirection.valueOf()` with WARN log on unknown values; null/empty → VERTICAL
- `@PostConstruct init()` logs resolved direction at startup

### Step 7: Wire All 7 Callsites
- Add `@Autowired private PickPathConfig pickPathConfig;` to each affected service
- Fetch `pickDir` once per method, pass to strategy/comparator constructor

### Step 8: Create Flyway Migration
- `V2.1.09__add_pick_path_direction_sysprop.sql` — INSERT `PICK_PATH_DIRECTION = 'VERTICAL'` (id=145, `ON CONFLICT (client_id, syskey, workstation) DO NOTHING`)

### Step 9: Write Unit Tests
- `PickPathConfigUnitTest` — parse semantics, WARN log, delegation-per-call contract (no TTL cache tests)
- `DefaultStrategyUnitTest` — direction-specific sort order, edge cases
- Add HORIZONTAL tests to `CycleCountStrategyUnitTest`
- Add HORIZONTAL tests to `InMemoryLocationComparatorUnitTest`
- Add `@Mock PickPathConfig pickPathConfig` + HORIZONTAL direction tests to all 5 affected service unit tests

### Step 10: Build & Verify
- `mvn clean package -DskipTests` — verify compilation
- `mvn test` — verify no regressions

---

## 6. Test Plan

### `PickPathConfigUnitTest` (new)

> **Note:** No TTL cache tests — per-tenant caching is delegated entirely to `SyspropService`'s `@Cacheable`. Tests focus on parse semantics and the delegation contract.

| # | Test Name | Description |
|---|-----------|-------------|
| 1 | `getDirection_nullSysvalue_returnsVertical` | `getSysvalue()` returns null → returns VERTICAL |
| 2 | `getDirection_emptySysvalue_returnsVertical` | `""` or `"  "` → returns VERTICAL |
| 3 | `getDirection_verticalSysvalue_returnsVertical` | `"VERTICAL"` → returns VERTICAL |
| 4 | `getDirection_horizontalSysvalue_returnsHorizontal` | `"HORIZONTAL"` → returns HORIZONTAL |
| 5 | `getDirection_lowercaseSysvalue_returnsHorizontal` | Case-insensitive: `"horizontal"` → HORIZONTAL |
| 6 | `getDirection_whitespaceWrapped_trimsAndReturnsHorizontal` | `"  HORIZONTAL  "` → HORIZONTAL (trims before valueOf) |
| 7 | `getDirection_unknownSysvalue_logsWarnAndReturnsVertical` | Unrecognized value (e.g. `"DIAGONAL"`) → WARN logged; returns VERTICAL |
| 8 | `getDirection_delegatesToSyspropService_calledEachTime` | Two `getDirection()` calls → `getSysvalue()` called twice (no local caching) |

### `DefaultStrategyUnitTest` (new)

| # | Test Name | Description |
|---|-----------|-------------|
| 1 | `twoArgConstructor_sortsVertical_xFirstByDefault` | Default constructor = VERTICAL = X-first |
| 2 | `vertical_fullSortOrder_sortsXThenY` | 4-location grid: VERTICAL order |
| 3 | `horizontal_fullSortOrder_sortsYThenX` | 4-location grid: HORIZONTAL order |
| 4 | `vertical_sameX_sortsByY` | Equal X → compare Y |
| 5 | `horizontal_sameY_sortsByX` | Equal Y → compare X |
| 6 | `compare_identicalXY_vertical_throwsUnsupportedOperation` | VERTICAL: same rack ordinal, same X, same Y → throws |
| 7 | `compare_identicalXY_horizontal_throwsUnsupportedOperation` | HORIZONTAL: same rack ordinal, same X, same Y → throws (direction-invariant: the trailing throw fires regardless of direction) |
| 8 | `compare_singleLocation_noComparison` | Single-element list → no exception |
| 9 | `compare_nullRackId_bothNull_returnsZero` | Both rackId null → 0 |
| 10 | `compare_nullRackId_oneNull_nullComesLast` | Null rackId sorts last |
| 11 | `compare_rackOrdinalPrecedence_overridesXY` | Different rack ordinals → ordinal wins over X/Y |

### Updates to `CycleCountStrategyUnitTest`

Add direction-specific tests:

| # | Test Name | Description |
|---|-----------|-------------|
| + | `twoArgConstructor_defaultsToVerticalXFirst` | 2-arg constructor → VERTICAL behavior (backward-compat regression) |
| + | `getLocationList_horizontalDirection_sortsLocationsRowFirst` | Wired via `MobileCycleCountService.getLocationList()`: locA(x=1,y=2) vs locB(x=2,y=1), HORIZONTAL → locB first |

### Updates to `InMemoryLocationComparatorUnitTest`

Add direction-specific tests:

| # | Test Name | Description |
|---|-----------|-------------|
| + | `twoArgConstructor_defaultsToVerticalXFirst` | Default constructor = VERTICAL behavior (regression) |
| + | `threeArgConstructor_horizontal_sortsYFirst` | HORIZONTAL → Y-first on 2-location comparison |
| + | `threeArgConstructor_vertical_sortsXFirst` | VERTICAL → X-first on 2-location comparison |
| + | `horizontal_fullGrid_rowMajorOrder` | 4-location grid: HORIZONTAL order matches DefaultStrategy |

### Service-Level HORIZONTAL Tests (add to each service unit test)

Add `@Mock private PickPathConfig pickPathConfig;` to all 5 service test files, plus one `@Test` per service:

| Service | Test Method | Verifies |
|---------|------------|---------|
| `MobilePickingServiceUnitTest` | `getPickingOrderPositionsInfo_horizontalDirection_sortsPositionsRowFirst` | 2 positions → locB(y=1) sorted before locA(y=2); `verify(pickPathConfig).getDirection()` |
| `OrderMonitorViewServiceUnitTest` | `generateToteLabel_horizontalDirection_sortsLocationsRowFirst` | Sort order reflects HORIZONTAL; `verify(pickPathConfig).getDirection()` |
| `MobilePutAwayServiceUnitTest` | `calculatePutAwayList_horizontalDirection_sortsFlowbinsByRowFirst` | flowBinLocationList: locB(y=1) before locA(y=2) |
| `MobileMoveStockServiceUnitTest` | `selectStockUnit_horizontalDirection_sortsLocationsRowFirst` | locationList: OVERSTOCK-B(y=1) before OVERSTOCK-A(y=2) |
| `MobileCycleCountServiceUnitTest` | `getLocationList_horizontalDirection_sortsLocationsRowFirst` | locB(y=1) at index 0 |

### Regression Tests

- [ ] All existing comparator tests still pass (backward compatibility via 2-arg constructor)
- [ ] `MobilePickingService` tests still pass
- [ ] `OrderMonitorViewService` tests still pass
- [ ] `MobilePutAway` / `MobileMoveStock` / `MobileCycleCount` tests still pass
- [ ] Full suite: `mvn test` — 0 failures

---

## 7. Multi-Replica Safety Analysis

`PickPathConfig` has no local cache — it delegates directly to `SyspropService.getSysvalue()` on every call. `SyspropService` is `@Cacheable` with a per-tenant key (`facilityCode + ':' + syskey`), so:

- **No cross-tenant bleed**: each tenant gets its own cached value; a direction change for tenant A does not affect tenant B.
- **Cross-replica consistency**: after an admin updates the sysprop, the Spring cache on each replica is evicted via `@CacheEvict` on `SyspropService.createSystemProperty()`. Replicas that have not yet received the eviction event will serve the stale value until their next cache miss. This is the same staleness window as any other sysprop in the system — not specific to this feature.
- **No shared mutable state**: all comparator instances are created per-request. The feature is unconditionally safe for multi-replica deployment.

---

## 8. Risks & Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| Migration ID conflict | Medium | `V2.1.09` follows `V2.1.08`. Verify no conflicting migration exists before running |
| `InMemoryLocationComparator` diverges from `DefaultStrategy` | Medium | Both have identical XY logic. Direction tests on both classes catch divergence |
| `SyspropService.getSysvalue()` caching | Low | `@Cacheable` is per-tenant (facility-code scoped key) — no cross-tenant bleed. `@CacheEvict` fires on `createSystemProperty()`, so cache invalidation is automatic on admin updates |
| `CycleCountStrategyUnitTest` existing tests | Low | Existing tests use 2-arg constructor → still VERTICAL behavior → all pass unchanged |
| `@Transactional` on `PickPathConfig` | N/A | `PickPathConfig` has no transactions — read-only sysprop access via `SyspropService` |

---

## 9. Recommendations

### 9.1 Unify Comparator Duplication (Future)

`DefaultStrategy`, `CycleCountStrategy`, and `InMemoryLocationComparator` share nearly identical XY comparison logic. Consider extracting to a shared abstract base or utility method to prevent divergence. Optional — do as a follow-up refactor.

### 9.2 Admin UI Toggle (Future)

The sysprop is togglable via the admin API. A dedicated UI control in the admin settings page would improve usability for WineCo. Frontend change (wms2-web-ui) — out of scope here.
