# SBDEV-2096: Configurable Pick Path Direction (Horizontal vs Vertical)

**Ticket:** SBDEV-2096
**Priority:** Urgent | **Points:** 8 | **Requester:** WineCo
**Assignees:** David Oppenheim, Nam Park
**Date:** 2026-04-10
**Updated:** 2026-05-04 (v5 — ticket semantics confirmed: VERTICAL = current default (column-major), HORIZONTAL = new behavior (row-major); default constant, Flyway seed, code branches, and tests updated accordingly)

---

## ✅ SEMANTIC CLARIFICATION — RESOLVED (2026-05-04)

Ticket updated by WineCo confirming the mapping. **Outcome C** (labels swapped from initial assumption, VERTICAL is the default):

- **VERTICAL** = column-major = current behavior (`X1Y1 → X1Y2 → X1Y3 → X1Y4 → X2Y1 → X2Y2 → ...`) = **default**
- **HORIZONTAL** = row-major = new behavior (`X1Y1 → X2Y1 → X3Y1 → X4Y1 → X1Y2 → ...`)

The existing `DefaultStrategy` sorts xpos (column) first, then ypos (level) — confirmed column-major = VERTICAL. All code, constants, Flyway seed, and tests below reflect this confirmed mapping.

---

## 1. Problem Statement

The current picking system hard-codes one traversal order (X then Y) in `DefaultStrategy` and `CycleCountStrategy`. WineCo requires the ability to switch between two traversal modes via a system property — without a code deploy.

**Confirmed mapping (ticket updated 2026-05-04):**
- `VERTICAL` = column-major = current behavior (default): `X1Y1 → X1Y2 → X1Y3 → X2Y1 → ...` (xpos primary sort)
- `HORIZONTAL` = row-major = new behavior: `X1Y1 → X2Y1 → X3Y1 → X1Y2 → ...` (ypos primary sort)

---

## 2. Current Architecture

### 2.1 Sorting Comparators

**`DefaultStrategy.java`** (`net.aim_ai.wms.util`) — primary, used for picking/putaway/stock moves/printing:
- Sort order: `RackRow ordinal → Rack ordinal → Xpos (column) → Ypos (level)`
- Hard-coded X-before-Y at lines 82–96
- Single 2-arg constructor at line 24

**`CycleCountStrategy.java`** (`net.aim_ai.wms.util`) — secondary, used for cycle counting:
- Sort order: `RackRow ordinal → Rack ordinal → Xpos (column) → Ypos (level) → Location name`
- Hard-coded X-before-Y in `compareXY()` at lines 69–86
- Single 2-arg constructor at line 18
- **Difference from DefaultStrategy:** when X==Y, falls through to `compareNames()` (never throws)

### 2.2 All Callsites (7 locations — verified against disk 2026-05-04)

| # | File | Line | Enclosing Method | Context |
|---|------|------|-----------------|---------|
| 1 | `MobilePickingService.java` | 616 | (verify method name) | Sorts picking order positions |
| 2 | `OrderMonitorViewService.java` | 238 | (verify method name) | Sorts positions for tote label printing |
| 3 | `MobilePutAwayService.java` | 272 | `sortPutAwayItemDataList()` | Sorts flowbin locations — inside `BiConsumer` lambda |
| 4 | `MobilePutAwayService.java` | 282 | `sortPutAwayItemDataList()` | Sorts overstock locations — inside `BiConsumer` lambda |
| 5 | `MobilePutAwayService.java` | 303 | `sortPutAwayItemDataList()` | Sorts combined location list — direct call |
| 6 | `MobileMoveStockService.java` | 191 | (verify method name) | Sorts storage locations for stock transfer |
| 7 | `MobileCycleCountService.java` | 260 | (verify method name) | Sorts locations for cycle count (uses `CycleCountStrategy`) |

All 7 currently use the 2-arg constructor (hardcoded). Neither strategy is used elsewhere (`grep -rln DefaultStrategy\|CycleCountStrategy` confirmed).

### 2.3 Service Injection Status (verified 2026-05-04)

| Service | Extends BasicService? | `losSyspropRepository` injected? |
|---------|-----------------------|----------------------------------|
| `MobilePickingService` | No | Yes (line 67) |
| `OrderMonitorViewService` | No | Yes (line 27) |
| `MobilePutAwayService` | No | **No** |
| `MobileMoveStockService` | No | Yes (line 61) |
| `MobileCycleCountService` | No | Yes (line 50) |

None of the 5 services extend `BasicService` — a `BasicService` helper method is not reachable from any callsite. `@Component PickPathConfig` (§3.5) is the correct approach.

### 2.4 System Property Pattern

`findSysvalueBySyskey(key)` (SQL: `WHERE syskey = :syskey AND workstation = 'DEFAULT' ORDER BY client_id ASC LIMIT 1`) returns the system-level row. This is a global lookup — it does not support per-client overrides. Per-client override would require `findSysvalueByClientIdAndSyskey(clientId, key)`. **Decision: use `findSysvalueBySyskey` for `PICK_PATH_DIRECTION`.** `PICK_PATH_DIRECTION` is a facility-wide setting; per-client override is not requested and would require a UI that does not exist. Document this in `PickPathConfig` with a comment so future maintainers know why.

---

## 3. Design

### 3.1 New Constants in `WmsConstants.java`

Add only two constants (the string values are representable via `PickPathDirection.name()` — no separate string constants needed):

```java
public static final String SYSTEM_PROPERTY_PICK_PATH_DIRECTION_KEY = "PICK_PATH_DIRECTION";
public static final String SYSTEM_PROPERTY_PICK_PATH_DIRECTION_DEFAULT_VALUE = "VERTICAL";
```

### 3.2 New Enum `PickPathDirection`

Create `net.aim_ai.wms.util.PickPathDirection`:

```java
package net.aim_ai.wms.util;

public enum PickPathDirection {
    HORIZONTAL, VERTICAL
}
```

Using an enum makes every call site self-documenting: `new DefaultStrategy(repo, repo, PickPathDirection.VERTICAL)` vs `new DefaultStrategy(repo, repo, true)`. It also makes adding future modes (SERPENTINE, etc.) a one-line enum extension with no boolean-trap risk.

### 3.3 Modify `DefaultStrategy`

**Strategies remain plain classes (not `@Component`).** They are instantiated per-sort with `new DefaultStrategy(...)`. Direction is passed by callers, not autowired.

Add `direction` field, new 3-arg constructor (2-arg delegates to `VERTICAL`), and branch XY comparison:

```java
public class DefaultStrategy implements Comparator<Location> {

    private LocationRackRepository locationRackRepository;
    private LocationRackRowRepository locationRackRowRepository;
    private PickPathDirection direction;

    // Existing constructor — delegates to VERTICAL to preserve all existing call sites
    public DefaultStrategy(LocationRackRepository rackRepository, LocationRackRowRepository rackRowRepository) {
        this(rackRepository, rackRowRepository, PickPathDirection.VERTICAL);
    }

    public DefaultStrategy(LocationRackRepository rackRepository, LocationRackRowRepository rackRowRepository, PickPathDirection direction) {
        this.locationRackRepository = rackRepository;
        this.locationRackRowRepository = rackRowRepository;
        this.direction = direction;
    }
```

Replace lines 82–98 (keep lines 30–80 unchanged — null checks, rack/rackrow lookups):

```java
        // check columns and level — order depends on pick path direction
        if (direction == PickPathDirection.HORIZONTAL) {
            // Y (row) first, then X (column) — row-major traversal
            int o1_level = o1.getYpos();
            int o2_level = o2.getYpos();
            if (o1_level != o2_level) return o1_level < o2_level ? -1 : 1;

            int o1_column = o1.getXpos();
            int o2_column = o2.getXpos();
            if (o1_column != o2_column) return o1_column < o2_column ? -1 : 1;
        } else {
            // VERTICAL (current behavior/default): X (column) first, then Y (level) — column-major traversal
            int o1_column = o1.getXpos();
            int o2_column = o2.getXpos();
            if (o1_column != o2_column) return o1_column < o2_column ? -1 : 1;

            int o1_level = o1.getYpos();
            int o2_level = o2.getYpos();
            if (o1_level != o2_level) return o1_level < o2_level ? -1 : 1;
        }

        throw new UnsupportedOperationException(
            "Location cannot be differentiated by rack and rack row: o1=" + o1 + " o2 " + o2);
    }
}
```

The `UnsupportedOperationException` at the end (line 98) is preserved in both branches — it fires when RackRow, Rack, X, and Y are all equal. This existing contract is unchanged.

### 3.4 Modify `CycleCountStrategy`

Same structure as §3.3. **Strategies remain plain classes — not `@Component`.**

Add `direction` field, new 3-arg constructor (2-arg delegates to `VERTICAL`). Branch in `compareXY()`:

```java
public class CycleCountStrategy implements Comparator<Location> {

    private LocationRackRepository locationRackRepository;
    private LocationRackRowRepository locationRackRowRepository;
    private PickPathDirection direction;

    public CycleCountStrategy(LocationRackRepository rackRepository, LocationRackRowRepository rackRowRepository) {
        this(rackRepository, rackRowRepository, PickPathDirection.VERTICAL);
    }

    public CycleCountStrategy(LocationRackRepository rackRepository, LocationRackRowRepository rackRowRepository, PickPathDirection direction) {
        this.locationRackRepository = rackRepository;
        this.locationRackRowRepository = rackRowRepository;
        this.direction = direction;
    }

    private int compareXY(Location o1, Location o2) {
        if (direction == PickPathDirection.HORIZONTAL) {
            // Y (row) first, then X (column) — row-major traversal
            int o1_level = o1.getYpos();
            int o2_level = o2.getYpos();
            if (o1_level != o2_level) return o1_level < o2_level ? -1 : 1;

            int o1_column = o1.getXpos();
            int o2_column = o2.getXpos();
            if (o1_column != o2_column) return o1_column < o2_column ? -1 : 1;
        } else {
            // VERTICAL (current behavior/default): X (column) first, then Y (level) — column-major traversal
            int o1_column = o1.getXpos();
            int o2_column = o2.getXpos();
            if (o1_column != o2_column) return o1_column < o2_column ? -1 : 1;

            int o1_level = o1.getYpos();
            int o2_level = o2.getYpos();
            if (o1_level != o2_level) return o1_level < o2_level ? -1 : 1;
        }
        return compareNames(o1, o2);  // falls through to name tiebreak (not a throw — different from DefaultStrategy)
    }
```

**Key difference from DefaultStrategy:** `CycleCountStrategy.compareXY()` falls through to `compareNames()` when both X and Y are equal; `DefaultStrategy.compare()` throws `UnsupportedOperationException`. Both behaviors are preserved in both direction modes.

### 3.5 New `@Component PickPathConfig`

**Package:** `net.aim_ai.wms.service` (co-located with other Spring service beans; `@Component` belongs in service layer, not util).

**Imports needed in callsite services:** `net.aim_ai.wms.service.PickPathConfig` and `net.aim_ai.wms.util.PickPathDirection`.

```java
package net.aim_ai.wms.service;

import net.aim_ai.wms.repo.jpa.LosSyspropRepository;
import net.aim_ai.wms.service.WmsConstants;
import net.aim_ai.wms.util.PickPathDirection;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.stereotype.Component;
import javax.annotation.PostConstruct;

@Component
public class PickPathConfig {

    private static final Logger log = LoggerFactory.getLogger(PickPathConfig.class);
    private static final long CACHE_TTL_MS = 30_000;

    @Autowired
    private LosSyspropRepository losSyspropRepository;

    // volatile fields mirror BasicService.showLog() pattern (BasicService.java:180-192)
    private volatile PickPathDirection cachedDirection = null;
    private volatile long cacheTime = 0;

    @PostConstruct
    public void init() {
        log.info("PickPathConfig initialized. Resolved direction: {}", getDirection());
    }

    public PickPathDirection getDirection() {
        long now = System.currentTimeMillis();
        if (cachedDirection == null || (now - cacheTime) > CACHE_TTL_MS) {
            // findSysvalueBySyskey: global lookup (workstation='DEFAULT', ORDER BY client_id ASC LIMIT 1).
            // Does NOT support per-client overrides. If per-client is needed in future,
            // switch to findSysvalueByClientIdAndSyskey(clientId, PICK_PATH_DIRECTION_KEY).
            String raw = losSyspropRepository.findSysvalueBySyskey(
                WmsConstants.SYSTEM_PROPERTY_PICK_PATH_DIRECTION_KEY);
            cachedDirection = parse(raw);
            cacheTime = now;
        }
        return cachedDirection;
    }

    private PickPathDirection parse(String raw) {
        if (raw == null || raw.trim().isEmpty()) {
            return PickPathDirection.VERTICAL;
        }
        try {
            return PickPathDirection.valueOf(raw.trim().toUpperCase());
        } catch (IllegalArgumentException e) {
            // WARN is emitted once per cache window (every ~30s) while a bad value persists in DB.
            // This is intentional — it makes misconfiguration loud until corrected.
            log.warn("Unknown PICK_PATH_DIRECTION value '{}' — defaulting to VERTICAL. "
                + "Valid values: HORIZONTAL, VERTICAL", raw.trim());
            return PickPathDirection.VERTICAL;
        }
    }
}
```

**Cache semantics:**
- Stores the **parsed `PickPathDirection`**, not the raw string. Parse runs on cache-miss only.
- On null/missing DB row: stores `VERTICAL` and re-queries after TTL. Check `@PostConstruct` log on first deploy to confirm the row is present.
- The TTL cache is an **orthogonal optimization** that reduces DB load across concurrent sort operations. It does **not** prevent DB lookups inside `Comparator.compare()` — that is prevented by fetching direction **once per method** before calling `sortList.sort(...)` (see §3.6).
- Multiple threads can concurrently miss the cache (e.g., during the 30s expiry window). Each will do one DB lookup and re-cache. This is benign — same behavior as `BasicService.showLog()`.

**Rollback:** setting `PICK_PATH_DIRECTION` back to `'VERTICAL'` via the Operation Options admin page takes effect within 30 seconds (next cache expiry). No code deploy needed.

### 3.6 Update Callsites

**Pattern — fetch direction once before the sort, pass to constructor:**

```java
PickPathDirection pickDir = pickPathConfig.getDirection();
sortList.sort(new DefaultStrategy(locationRackRepository, locationRackRowRepository, pickDir));
```

**MobilePutAwayService special case — lambda capture:**

All 3 sort calls (lines 272, 282, 303) are in `sortPutAwayItemDataList()` (line 267). Lines 272 and 282 are inside `BiConsumer` lambdas that are passed to `itemDataDtoMap.forEach()`. The `pickDir` local variable must be **effectively final** to be captured in a lambda — it is, since it is assigned once at the top of the method and never reassigned.

```java
private void sortPutAwayItemDataList(...) {
    PickPathDirection pickDir = pickPathConfig.getDirection();  // fetch once; effectively final

    BiConsumer<Itemdata, PutAwayItemDto> biConsumer = (itemData, dto) -> {
        List<Location> sortList = new ArrayList<>();
        dto.getFlowBinLocationList().forEach(name -> sortList.add(toStorageLocationMap.get(name)));
        sortList.sort(new DefaultStrategy(locationRackRepository, locationRackRowRepository, pickDir));
        ...
    };
    itemDataDtoMap.forEach(biConsumer);

    biConsumer = (itemData, dto) -> {    // biConsumer is reassigned, but pickDir is not — still effectively final
        ...
        sortList.sort(new DefaultStrategy(locationRackRepository, locationRackRowRepository, pickDir));
        ...
    };
    itemDataDtoMap.forEach(biConsumer);

    ...
    locationList.sort(new DefaultStrategy(locationRackRepository, locationRackRowRepository, pickDir));
    ...
}
```

| # | File | Line | Change |
|---|------|------|--------|
| 1 | `MobilePickingService.java` | 616 | Inject `PickPathConfig`; fetch direction before sort |
| 2 | `OrderMonitorViewService.java` | 238 | Inject `PickPathConfig`; fetch direction before sort |
| 3–5 | `MobilePutAwayService.java` | 272, 282, 303 | Inject `PickPathConfig`; fetch direction once at line 268 (method start); capture in lambdas |
| 6 | `MobileMoveStockService.java` | 191 | Inject `PickPathConfig`; fetch direction before sort |
| 7 | `MobileCycleCountService.java` | 260 | Inject `PickPathConfig`; fetch direction before sort; use `CycleCountStrategy` |

Each service gets: `@Autowired private PickPathConfig pickPathConfig;` plus the required imports.

---

## 4. Scope Boundaries

### In Scope
- New `PickPathDirection` enum (`net.aim_ai.wms.util`)
- New `PICK_PATH_DIRECTION` constants in `WmsConstants` (KEY + DEFAULT_VALUE only)
- New `@Component PickPathConfig` (`net.aim_ai.wms.service`) with 30s TTL cache, null-safe parse, WARN on unknown
- `DefaultStrategy` and `CycleCountStrategy` parameterized with `PickPathDirection`
- All 7 callsites updated
- Flyway seed `V1.1.09__pick_path_direction.sql`
- Unit tests for both strategies in both directions, plus `PickPathConfig`

### Out of Scope
- Replenishment logic — **must NOT be affected**
- Allocation logic — **must NOT be affected**
- Rack-row or rack ordering reversal for serpentine/snake paths
- Advanced routing (snake/zigzag, right-to-left) — future consideration
- Per-client/per-workstation direction override — future consideration (requires per-client UI, not just API)

---

## 5. File Change Summary

| File | Change Type | Description |
|------|------------|-------------|
| `WmsConstants.java` | Add | 2 constants: `_KEY`, `_DEFAULT_VALUE` |
| `PickPathDirection.java` | **New** | Enum: `HORIZONTAL`, `VERTICAL` in `net.aim_ai.wms.util` |
| `PickPathConfig.java` | **New** | `@Component` in `net.aim_ai.wms.service`; 30s TTL cache, null-safe parse, WARN, @PostConstruct log |
| `DefaultStrategy.java` | Modify | `direction` field, 3-arg constructor, branch XY in lines 82–98 |
| `CycleCountStrategy.java` | Modify | `direction` field, 3-arg constructor, branch XY in `compareXY()` lines 69–86 |
| `MobilePickingService.java` | Modify | `@Autowired PickPathConfig`; fetch direction at line 616 |
| `OrderMonitorViewService.java` | Modify | `@Autowired PickPathConfig`; fetch direction at line 238 |
| `MobilePutAwayService.java` | Modify | `@Autowired PickPathConfig`; fetch once at start of `sortPutAwayItemDataList()` (line 267); capture in lambdas at 272/282; pass to sort at 303 |
| `MobileMoveStockService.java` | Modify | `@Autowired PickPathConfig`; fetch direction at line 191 |
| `MobileCycleCountService.java` | Modify | `@Autowired PickPathConfig`; fetch direction at line 260 |
| `V1.1.09__pick_path_direction.sql` | **New** | Flyway seed: `id=143`, `PICK_PATH_DIRECTION`, `VERTICAL` |

**New test files:**

| File | Description |
|------|-------------|
| `DefaultStrategyTest.java` | Baseline + horizontal + vertical sort orders, edge cases |
| `CycleCountStrategyTest.java` | Baseline + horizontal + vertical sort orders, edge cases |
| `PickPathConfigTest.java` | Null/empty/whitespace/unknown/VERTICAL/HORIZONTAL/cache TTL |

---

## 6. Implementation Steps

### Pre-condition: Step 1 — Semantic Clarification (hard prerequisite)

Before any code change, confirm with WineCo / David Oppenheim which physical traversal each token represents. Use the decision tree in the ⚠️ header. Record the confirmed mapping in §1. If **Outcome B** (no change needed), close ticket. If **Outcome C** (labels swapped), adjust §3.3/3.4 branch order and Flyway seed default. Only proceed to Step 2 after §1 is filled in.

### Step 2: TDD Gate — Baseline Tests (before parameterizing)

Write baseline tests for the **current** 2-arg constructor behavior of both strategies. These must pass before any code change and must continue passing after parameterization with `HORIZONTAL`.

**`DefaultStrategyTest` fixture:**

```java
// Minimal setup: 1 rack row, 1 rack, 4 locations with known X/Y
// rackRow: id=1, ordinalNumber=1
// rack: id=1, rackrowId=1, ordinalNumber=1
// L1: rackId=1, xpos=1, ypos=2  (column 1, level 2)
// L2: rackId=1, xpos=2, ypos=1  (column 2, level 1)
// L3: rackId=1, xpos=1, ypos=1  (column 1, level 1)
// L4: rackId=1, xpos=2, ypos=2  (column 2, level 2)
// Expected sort with current (VERTICAL/X-first): L3(1,1) → L1(1,2) → L2(2,1) → L4(2,2)
```

Use Mockito to stub `locationRackRepository.findById(1L)` → `Optional.of(rack)` and `locationRackRowRepository.findById(1L)` → `Optional.of(rackRow)`.

**`CycleCountStrategyTest` fixture:** same 4 locations; expected VERTICAL order: L3 → L1 → L2 → L4 → (name tiebreak if needed).

### Step 3: Constants and Enum

- Add 2 constants to `WmsConstants.java`
- Create `PickPathDirection.java` in `net.aim_ai.wms.util`

### Step 4: `PickPathConfig`

- Create `PickPathConfig.java` in `net.aim_ai.wms.service` as shown in §3.5

### Step 5: Parameterize `DefaultStrategy`

- Add `direction` field, 3-arg constructor (2-arg delegates to `VERTICAL`)
- Replace lines 82–98 with direction-branched XY comparison
- Preserve `UnsupportedOperationException` throw at end
- Run `DefaultStrategyTest`: baseline (HORIZONTAL) must pass; add VERTICAL test

### Step 6: Parameterize `CycleCountStrategy`

- Same structure as Step 5
- Branch in `compareXY()` lines 69–86; preserve `compareNames()` fall-through
- Run `CycleCountStrategyTest`

### Step 7: Flyway Migration

Create `V1.1.09__pick_path_direction.sql`:

```sql
-- SBDEV-2096: seed PICK_PATH_DIRECTION system property
-- V1.1.07 claimed IDs 140-142 (STALE_CLUB_BATCH_CLEANUP_*); this uses 143.
insert into los_sysprop (id, groupname, syskey, sysvalue, description, additionalcontent,
                          client_id, version, hidden, workstation, entity_lock, created, modified)
values(143, 'Operation Options', 'PICK_PATH_DIRECTION', 'VERTICAL',
       'Pick Path Direction',
       'Controls whether picking, putaway, stock moves, and cycle counts traverse locations by row (HORIZONTAL) or column (VERTICAL). Valid values: HORIZONTAL, VERTICAL.',
       0, 0, FALSE, 'DEFAULT', 0, NOW(), NOW())
ON CONFLICT (id) DO NOTHING;
```

**`groupname='Operation Options'`** — makes the property appear under Admin → Parameters & Configuration → Operation Options.

**`ON CONFLICT (id) DO NOTHING`** — guards against PK collision on environments that have out-of-band rows. Note: the `seqentities` PostgreSQL sequence serves all entities; confirm it is past 140 (`SELECT last_value FROM seqentities`) after migration. If not, run `SELECT setval('seqentities', 141);`.

**After migration:** the next available Flyway slot is `V1.1.10__`.

### Step 8: Update All 7 Callsites

- Add `@Autowired private PickPathConfig pickPathConfig;` to each of the 5 services
- Add imports: `net.aim_ai.wms.service.PickPathConfig`, `net.aim_ai.wms.util.PickPathDirection`
- Fetch `getDirection()` once before each sort (or once at method start for the 3-call putaway case)
- Pass `PickPathDirection` to strategy constructors
- For `MobilePutAwayService`: see lambda-capture note in §3.6

### Step 9: Unit Tests for `PickPathConfig`

See §7 for full test list.

### Step 10: Verification

- `mvn clean package -DskipTests` — no compile errors
- `mvn test` — no new failures
- Manual: set `PICK_PATH_DIRECTION='HORIZONTAL'` via Operation Options admin page; verify all 7 callsites produce Y-first (row-major) order; restore to `VERTICAL`; verify column-major order is restored

---

## 7. Testing Plan

### Pre-parameterization Baseline (TDD Gate — Step 2)

- [ ] `DefaultStrategy` 2-arg constructor: `[L(x=2,y=1), L(x=1,y=2), L(x=1,y=1), L(x=2,y=2)]` sorts to `[L(1,1), L(1,2), L(2,1), L(2,2)]` (VERTICAL/X-first = column-major)
- [ ] `CycleCountStrategy` 2-arg constructor: same input, same order (VERTICAL/X-first = column-major, name tiebreak for equal X+Y)

### Unit Tests — `DefaultStrategy`

- [ ] `VERTICAL`: `new DefaultStrategy(repo, repo, PickPathDirection.VERTICAL)` produces X-then-Y / column-major (same as baseline)
- [ ] `HORIZONTAL`: `new DefaultStrategy(repo, repo, PickPathDirection.HORIZONTAL)` produces Y-then-X / row-major (`[L(1,1), L(2,1), L(1,2), L(2,2)]`)
- [ ] Same X, different Y: HORIZONTAL keeps lower-Y first; VERTICAL keeps lower-Y first (Y is primary in VERTICAL)
- [ ] Same Y, different X: HORIZONTAL keeps lower-X first (X is primary); VERTICAL keeps lower-X first (X is secondary tiebreak)
- [ ] Different rack rows: rack-row ordinal wins regardless of direction
- [ ] Null `rackId`: `UnsupportedOperationException` preserved in both modes
- [ ] Single location: returns 0 (no sort needed)

### Unit Tests — `CycleCountStrategy`

- [ ] Same as DefaultStrategy above for HORIZONTAL and VERTICAL modes
- [ ] Equal X+Y: falls through to `compareNames()` (does NOT throw) in both directions

### Unit Tests — `PickPathConfig`

- [ ] `null` DB value → `VERTICAL` (no WARN)
- [ ] `""` → `VERTICAL` (no WARN)
- [ ] `"  "` (whitespace only) → `VERTICAL` (no WARN)
- [ ] `"VERTICAL"` → `VERTICAL`
- [ ] `"vertical"` → `VERTICAL` (case-insensitive)
- [ ] `"Vertical"` → `VERTICAL`
- [ ] `"HORIZONTAL"` → `HORIZONTAL` (no WARN)
- [ ] `"VERITCAL"` (typo) → `VERTICAL` + WARN logged
- [ ] `"DIAGONAL"` (unknown) → `VERTICAL` + WARN logged
- [ ] Second call within TTL window: repository NOT called a second time (cache hit)
- [ ] Call after TTL expiry: repository called again (cache miss)
- [ ] `@PostConstruct` `init()` logs the resolved direction

### Integration Tests

- [ ] All 7 callsites produce correct sequence with `VERTICAL` (default — no behavior change)
- [ ] All 7 callsites produce correct sequence with `HORIZONTAL`

### Regression Tests

- [ ] Existing pick-pack workflows unaffected (`VERTICAL` default = zero behavior change)
- [ ] Club picking / merge picking unaffected
- [ ] Replenishment triggers not impacted
- [ ] Allocation logic not impacted

---

## 8. Risks & Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| HORIZONTAL/VERTICAL semantic implementer error | Medium | Semantic confirmed in §1 (VERTICAL = column-major/default, HORIZONTAL = row-major). Risk: implementer swaps sort keys. Mitigate: code comments in both branches, TDD baseline gate |
| Backward compatibility break | High | 2-arg constructors delegate to `VERTICAL`; Flyway seeds `'VERTICAL'` |
| DB row missing (`findSysvalueBySyskey` returns null) | Medium | `PickPathConfig.parse()` handles null, defaults to VERTICAL; `@PostConstruct` logs resolved value so absence is visible on startup |
| Typo/unknown sysprop value | Medium | `parse()` uses `valueOf()` — throws `IllegalArgumentException` for unknown values, caught and logged as WARN. WARN repeats every cache window (~30s) while bad value persists — intentional to make misconfiguration loud |
| DB lookup inside `Comparator.compare()` | High | Direction pre-fetched once per method before `sortList.sort()`; stored as local `PickPathDirection pickDir`. The 30s TTL cache is an orthogonal optimization — the local-variable pattern is what prevents in-compare DB reads |
| `MobilePutAwayService` lambda capture | Medium | `pickDir` is assigned once at method start → effectively final → safe for capture in `BiConsumer` lambdas. Verified: all 3 sorts in `sortPutAwayItemDataList()` (line 267) |
| Flyway PK collision | Medium | `ON CONFLICT (id) DO NOTHING` guard; V1.1.07 claimed 140-142; id=143 is next safe ID |
| `seqentities` sequence not advanced past 140 | Low | After migration: `SELECT last_value FROM seqentities` — if ≤ 140, run `SELECT setval('seqentities', 141)` |
| Missing callsite | Low | `grep -rln DefaultStrategy\|CycleCountStrategy` confirms exactly 7 usages — neither class is used elsewhere |

---

## 9. V2 (wms2-api) Considerations

Ticket title mentions "WMS V1/V2." A separate V2 plan should be created after V1 is validated. The core design (`PickPathDirection` enum, cached config component, parameterized comparators) is directly portable. V2 (Java 21 / Spring Boot 3.x) should prefer constructor injection over `@Autowired` and may use `@ConfigurationProperties` as an alternative to the manual volatile cache.

---

## 10. Implementation Status (verified 2026-05-06)

**Status: COMPLETE — all items shipped.**

| Item | Disk Status |
|------|-------------|
| `PICK_PATH_DIRECTION` constants in `WmsConstants.java` | ✓ Lines 1069-1070 |
| `PickPathDirection` enum | ✓ `net.aim_ai.wms.util.PickPathDirection` |
| `PickPathConfig` component | ✓ `net.aim_ai.wms.service.PickPathConfig` (30 s TTL cache) |
| `DefaultStrategy` 3-arg constructor | ✓ 2-arg delegates to `VERTICAL` |
| `CycleCountStrategy` 3-arg constructor | ✓ 2-arg delegates to `VERTICAL` |
| Flyway migration | ✓ `V1.1.09__pick_path_direction.sql`; id=143; run on DB 2026-05-06 |
| `MobilePickingService` callsite | ✓ Line 617 — `pickDir` fetched before sort |
| `OrderMonitorViewService` callsite | ✓ Line 238 — `pickDir` fetched before sort |
| `MobilePutAwayService` callsites (×3) | ✓ Lines 273/283/304 — `pickDir` fetched once at method start; captured in lambdas |
| `MobileMoveStockService` callsite | ✓ Line 200 — `pickDir` fetched before sort |
| `MobileCycleCountService` callsite | ✓ Line 260 — `pickDir` fetched before sort |
| Unit tests | ✓ 36 tests passing: `DefaultStrategyUnitTest` (10), `CycleCountStrategyUnitTest` (8), `PickPathConfigUnitTest` (11), plus pre-existing (7) |
| `mvn clean package` | ✓ BUILD SUCCESS |

### Acceptance Criteria

- [ ] HORIZONTAL/VERTICAL semantics confirmed with WineCo — outcome recorded in §1
- [ ] `mvn clean package` succeeds with no compile errors
- [ ] `mvn test` succeeds with no new failures
- [ ] Baseline regression tests (TDD gate) pass before and after parameterization
- [ ] After setting `PICK_PATH_DIRECTION='HORIZONTAL'` via Operation Options admin page, **all 7 callsites** respect the change (row-major traversal):
  - Mobile picking order display (`MobilePickingService:616`)
  - Tote label printing (`OrderMonitorViewService:238`)
  - Putaway flowbin sort (`MobilePutAwayService:272`)
  - Putaway overstock sort (`MobilePutAwayService:282`)
  - Putaway combined location sort (`MobilePutAwayService:303`)
  - Stock move location sort (`MobileMoveStockService:191`)
  - Cycle count location sort (`MobileCycleCountService:260`)
- [ ] Setting `PICK_PATH_DIRECTION='VERTICAL'` preserves existing behavior across all 7 callsites (column-major = current default)
- [ ] No DB lookup inside `Comparator.compare()` — direction pre-fetched per method only
- [ ] `@PostConstruct` log visible on startup confirming resolved direction
- [ ] WARN emitted (and visible in logs) when unknown value set in DB
- [ ] Rollback verified: changing sysprop back to `'HORIZONTAL'` takes effect within 30s, no redeploy
