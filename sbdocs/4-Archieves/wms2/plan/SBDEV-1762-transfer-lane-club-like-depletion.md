---
title: "SBDEV-1762 (v2) — Make Transfer Lanes Function Like Club Lanes (selective partial depletion)"
ticket: "SBDEV-1762"
ticket_url: "https://app.clickup.com/t/SBDEV-1762"
type: feature
priority: medium
status: archived
project: [wms2]
version: v2
requester: ""
created: 2026-07-23
updated: 2026-07-23
db_verified: blocked
db_verified_rationale: "Both tenant DB MCPs (wsl-wineco-uat, wms2-hydra-uat) unreachable at authoring time — 'couldn't get a connection after 30.00 sec' on repeated retries from both a subagent and the main session. See §2 DB-Verification. Intended query is recorded verbatim; run before closing the evidence bar."
related:
  - "[[wms2-transfer-order-workflow]]"
  - "[[wms2-club-run-workflow]]"
tags:
  - plan
  - wms2
  - transfer-order
  - club-run
  - system-property-toggle
---

# SBDEV-1762 (v2) — Make Transfer Lanes Function Like Club Lanes

**Ticket:** [SBDEV-1762](https://app.clickup.com/t/SBDEV-1762)
**Project:** wms2 | **Version:** v2 (`wms2-api`, Java 21 / Spring Boot 3.5.9) | **Type:** feature (behavior toggle)
**Priority:** medium
**Status:** Draft — **v4: final concurrency posture (user-confirmed 2026-07-23) — ON path stays canonical SU-first-consistent (no cross-caller lock inversion) with `(UL-id, SU-id)` determinism; the v3 up-front lane-`Location` lock is REMOVED (it would invert the canonical order); the residual rare same-lane concurrent-transfer 40P01 is an accepted atomic-rollback fail-fast, deferred to a concurrency-hardening follow-up. Builds on v2 pivot to parameterized `combineStock` + reserved-adjusted availability.**
**Date:** 2026-07-23
**db_verified:** `blocked` — see §2.7.

> **One-line intent:** Give the Transfer-Order "run transfer" flow a per-tenant opt-in mode where it deplete-consumes **only the order's required SKUs and quantities** from the transfer lane — exactly the way Club Runs consume from club lanes — instead of the current all-or-nothing exact-match + sweep-everything behavior. Default OFF; OFF path is byte-identical to today.

---

## §0. Affected Sites

All paths relative to `v2/wms2-api/src/main/java/net/aim_ai/wms/` unless noted. Line numbers are as of authoring (develop head).

| # | file:line | Construct | In-scope? | Phase |
|---|-----------|-----------|-----------|-------|
| 1 | `service/BillofladingService.java:735-796` | `transferOrder(Long)` orchestrator | **Yes** — compute `needed`, sort lane ULs (ON), thread budget into `combineStock`, fail-loud assertion | Impl |
| 2 | `service/BillofladingService.java:798-824` | `combineStock(...)` recursive traversal | **Yes** — add `Map<Long,BigDecimal> needed` param; ON/OFF branch at the leaf | Impl |
| 3 | `service/BillofladingService.java:812-815` | leaf `transferStockToUnitLoad(…, su.getAmount(), …)` whole-SU move | **Yes** — ON: pass `min(needed, amount-reservedamount)` | Impl |
| 4 | `service/TransferOrderService.java:164-221` | `isEnoughStockOnTransferLane` (3 reject branches) | **Yes** — add `boolean partial` overload; ON = reserved-adjusted, drop "too much"+"foreign" | Impl |
| 5 | `controller/TransfersController.java:239-260` | `GET /runTransfer/{orderId}` endpoint | No change (contract preserved) | Verify |
| 6 | `controller/TransfersController.java:70,246` | legacy `transferOrder` controller method | No — confirm dead (OQ-5) | Verify |
| 7 | `service/StockunitBusinessService.java:188-393` | `transferStockToUnitLoad` split primitive (canonical SU→UL→Location lock order `:240-243`) | No change (already splits + locks) | Reuse |
| 8 | `service/WmsConstants.java` (~`:988-1090` `*_ACTIVATED_*` block) | new `SYSTEM_PROPERTY_…_KEY` + `…_DEFAULT_VALUE="false"` | **Yes** — add key | Impl |
| 9 | `service/SyspropService.java:289` (`getSysvalue`), `:53` (`@CacheEvict`) | `getSysvalue(key)` | Reuse | Reuse |
| 10 | `service/ClubLineOrderProcessor.java:98-217` | club selective-depletion model (reserved-adjusted `effectiveAvailable` `:174`) | Reference only | — |
| 11 | `test/…/BillofladingServiceUnitTest.java:1173-1907` | 5 existing `transferOrder` tests (incl. SBDEV-2001 emptied-sibling `:1846-1907`) | **Yes** — stay green (OFF) + add ON tests | Test |
| 12 | `test/…/TransferOrderServiceUnitTest.java:415-520` | `isEnoughStockOnTransferLane` tests | **Yes** — add ON-branch tests | Test |
| 13 | `test/…/TransfersControllerUnitTest.java:273-287` | controller delegation tests | Stay green | Test |
| 14 | `repository/UnitloadRepository.java:41` | `findByStoragelocationId` (**no OrderBy**) | **Yes (behavioral dependency)** — ON path must sort result by id | Impl |
| 15 | `repository/StockunitRepository.java:82-92` | `getAmountAvailable` (reserved-adjusted mirror) | Reference — defines ON gate semantics | — |

There are **18 callers** of `transferStockToUnitLoad`; **only site #3** changes its call. The other 17 are untouched (the primitive itself, #7, is unchanged). All lane-touching callers follow the canonical **source-SU → UL → Location** lock order (`StockunitBusinessService.java:240-243`); the ON path preserves it (§3.5).

---

## §1. Problem Statement

Transfer Orders today run through `BillofladingService.transferOrder(Long)`. The flow is **all-or-nothing exact match followed by sweep-everything**:

1. `isEnoughStockOnTransferLane` (`TransferOrderService.java:164-221`) demands the lane contents **exactly equal** the order. It rejects if:
   - any required SKU is **missing or under-quantity** → `"Not enough stock on transfer lane yet"` (`:188-196`);
   - any required SKU has **excess** on the lane → `"Too much stock for SKU=<n>"` (`:198-202`);
   - the lane holds **any foreign SKU** not on the order → `"Found SKUs in <lane> that are not supposed to be on order <clientordernumber>"` (`:205-217`).
   The sum it compares is **raw** `stockUnit.getAmount()` (`:178-181`) — no reserved subtraction.
2. Once it passes, `transferOrder` **sweeps every unit load** on the lane (`findByStoragelocationId` at `:766`) and, via recursive `combineStock` (`:798-824`), moves the **whole amount** of every stockunit (`transferStockToUnitLoad(su, parcel, su.getAmount(), …)` at `:812-815`) onto the truck parcel.

**Business pain:** operators cannot stage more than one order's worth of stock on a transfer lane, nor mix SKUs, nor tolerate a slightly-over count — the lane must be curated to the exact order before "run transfer" will fire, and then everything on it leaves. This differs from **Club Runs**, where `ClubLineOrderProcessor` (`:98-217`) consumes only the required SKU/quantity per position (against **reserved-adjusted** availability, `:174`) and leaves the remainder on the lane.

**Desired behavior (this ticket):** make transfer lanes behave like club lanes — consume only the order's required SKUs + quantities (reserved-adjusted), leave foreign SKUs and same-SKU excess in place — as a **per-tenant opt-in**, so tenants relying on the strict exact-match sweep are not silently changed.

### Explicit non-goals (USER-CONFIRMED scope boundary — see §10 Resolved #4)

- A **missing or under-quantity** (reserved-adjusted) required SKU **still blocks** with `"Not enough stock"`. No short-ship, no partial-fulfillment, no overship. (Future ticket.)
- **SBDEV-1666** (do not replenish *from* staging/transfer lanes) is a **separate ticket** and is **out of scope** here.
- **Concurrency-hardening** (global 40P01 deadlock-retry or reordering the shared primitive to Location-first) is deferred to a **separate follow-up ticket** (§10 Follow-up); this plan accepts the codebase's existing canonical-order + fail-fast posture.

---

## §2. Current Architecture

### 2.1 Endpoint → service entry

`controller/TransfersController.java:239-260` — `GET /v3/transfers/runTransfer/{orderId}`:
- Calls `billofladingService.transferOrder(orderId)`.
- Wraps `BusinessException` / `FacadeException` into a **HTTP 200** `{errors:[{...}]}` envelope (`:245-259`). The endpoint returns 200 even on business failure; the client inspects `errors`.
- A **legacy** `transferOrder` controller method also exists at `:70`/`:246`; believed dead (OQ-5).

### 2.2 Orchestrator — `BillofladingService.transferOrder(Long)` (`:735-796`)

`@Transactional(value = "tenantTransactionManager", rollbackFor = {BusinessException.class, FacadeException.class})` (**confirmed at `:735`**). `BillofladingService` already holds a `locationRepository` field (used for `locationRepository.findById` at `:741`).

```
:740  Customerorder co  = customerorderRepository.findById(orderId)…
:741  Location lane      = locationRepository.findById(<transfer lane id>)…
:742  String err = transferOrderService.isEnoughStockOnTransferLane(co);
:743-745  if (err != null) throw new BusinessException(err);      // gate
:750-751  syspropService.getSysvalue(<existing keys>)             // pallet/parcel naming, etc.
:758-762  Unitload pallet  = unitloadService.createUnitload(…);   // pallet UL at lane
          Unitload parcel  = unitloadService.createUnitload(…);   // parcel UL at lane
:766  List<Unitload> laneUls = unitloadRepository.findByStoragelocationId(lane.getId()); // SWEEP ALL (unordered)
:769-770  Fixedlocationassignment transferLaneFla = <pre-fetch lane FLA once>;
:773-775  for (Unitload ul : laneUls) combineStock(ul, parcel, co, transferLaneFla);
:778-784  for (Unitload emptied : emptyUnitLoadList)
              unitloadBusinessService.relocateEmptiedContainer(emptied, …CODE_SEND_TO_NIRVANA…);
:786-788  co.setState(PACKED); co.setParcelId(parcel.getId());
:790-793  batch.setState(ORDER_BATCH_CLUB_RUN_FINISHED); batch.setStaginglaneId(null);
```

### 2.3 Recursive traversal — `combineStock(...)` (`:798-824`)

```
:800-802  if (ul is PALLET or PARCEL type) return;                       // skip containers
:803,:820-822  recurse into child ULs (carriers)                         // preserves recursion
:805-ish  List<Stockunit> sus = stockunitRepository.findByUnitloadId(ul.getId());  // <-- authoritative leaf load
:806-809  if (sus is empty) emptyUnitLoadList.add(ul);                   // empty → relocate later
:812-815  else for (Stockunit su : sus)
              stockunitBusinessService.transferStockToUnitLoad(
                  su, parcel, su.getAmount(),                            // ← WHOLE amount (sweep)
                  CODE_TRANSFER_BUILD_TRUCK, co.getNumber(),
                  null, false, true, transferLaneFla);
```

> **Note (v2 Change 1):** the leaf stockunit list is obtained via `stockunitRepository.findByUnitloadId(ul.getId())` (around `:805`). `Unitload` is a **manual-FK entity with no `@OneToMany`** — `ul.getStockunits()` **does not exist**. The design reuses this exact repository fetch and never introduces `ul.getStockunits()`.

### 2.4 Gate — `TransferOrderService.isEnoughStockOnTransferLane(Customerorder)` (`:164-221`)

```
:167-169  require lane non-null
:174-181  Map<Long,BigDecimal> laneByItem = Σ lane stock by itemdataId  // RAW amount, no reserved subtraction
:185      for (CustomerorderPosition p : co.positions):
:188-191      if (!laneByItem.containsKey(itemId))          → "Not enough stock on transfer lane yet"
:193-196      if (laneByItem.get < required)                → "Not enough stock on transfer lane yet"
:198-202      if (laneByItem.get > required)                → "Too much stock for SKU=" + itemNr
:205-217  for each laneByItem key not in order             → "Found SKUs in <lane> … not supposed to be on order <clientordernumber>"
:220      return null;                                       // exact match
```

`TransferOrderService` constructor (`:51-75`) has **no `SyspropService` dependency** — relevant to the overload design in §3.3 (we keep the sysprop read in `transferOrder`, not here).

### 2.5 Split primitive — `StockunitBusinessService.transferStockToUnitLoad(...)` (9-arg, `:188-393`)

**Confirmed: already splits, already locks.** Key facts:
- Availability guard `:213-215` rejects **only** when `source.amount - reservedamount < requested`; a partial (`requested ≤ amount − reservedamount`) is accepted. **This is why the ON path must compute transfer against reserved-adjusted availability** (v2 Change 5).
- `:342` creates a zero-amount dest SU, then else-branch does `dest.amount += amount`; `:370-374` `source.amount -= amount` leaves the remainder on source.
- Full-amount **and** no-FLA path re-homes the whole SU via `setUnitloadId` (`:345-367`).
- Source zero-out cleanup only when `fla == null && source.amount == 0` (`:379-388`).
- **LANDMINE:** a lane **with** an FLA (which `transferOrder` pre-fetches and passes at `:769`/`:813`) leaves an emptied source SU as a **zero-amount row**, and the UL is **not** auto-relocated — this is exactly why today's flow has a **separate** `emptyUnitLoadList` relocation loop (`:778-784`). The design preserves this by reusing `combineStock`'s existing empty-UL bookkeeping (§3.4 and OQ-7).
- **Full pessimistic locking inside, in the canonical order:** source SU `findByIdForUpdate` (`:209`) + `refresh` (`:211`) FIRST, then source UL (`:245`), then source **Location** (`:249-250`), then dest UL (`:257`), dest SU (`:284`), dest location (`:290`). This **source-SU → UL → Location** order is documented and deliberate (`:240-243`, per **SBDEV-2481**). The lane `Location` row is locked AFTER the per-SU lock and held for the whole tx. **Every lane-touching caller (putaway, replenish, move, pick, club, transfer) follows this SU-first order** — the linchpin of the v4 concurrency posture (§3.5).

### 2.6 Club model to PARALLEL (not reuse wholesale)

`ClubLineOrderProcessor.java:98-217`: per position, iterate `List<StockSnapshot>`, transfer `min(effectiveAvailable, requiredAmount)` via the **same** `transferStockToUnitLoad` (`:190-203`), accumulate until `requiredAmount == 0`, and if leftover remains throw `BusinessException("Insufficient stock")` (`:206-210`). `effectiveAvailable` (`:174`) is **reserved-adjusted** — this confirms club semantics = reserved-adjusted, and the ON design mirrors it. The snapshot list comes from `CustomerorderBatchService.validateClubLine:654-668` → `stockValidation.stockMap()` (no explicit `ORDER BY`, ≈ id order). We **parallel** this `min(needed, available)` accumulation model; we do **not** reuse `runClubLine` (batch-scoped, different state machine — see §9 Alt-1). The club path is itself a multi-SU-on-lane path with the same residual multi-lock exposure the codebase already tolerates.

There is **no reusable lane FIFO/by-expiry selector**: `StockunitRepository.getStockUnitsByItemDataId/…ForUpdate` (`:128-156`) is picking-area only (`useforpicking='true'`, `amount DESC`), **not lane-scoped**, not reusable here.

### 2.7 DB-Verification — **BLOCKED**

**Status: BLOCKED — not fabricated.** Both `mcp__wsl-wineco-uat` and `mcp__wms2-hydra-uat` returned `"Connection attempt failed: couldn't get a connection after 30.00 sec"` on repeated retries from both a subagent and the main session at authoring time. Frontmatter `db_verified: blocked` reflects this.

**Intended verification query** (run per opting-in tenant when a DB MCP is reachable):

```sql
SELECT l.id  AS lane_id,
       l.name AS lane_name,
       la.name AS area_name,
       count(DISTINCT ul.id)          AS ul_count,
       count(su.id)                   AS su_count,
       count(DISTINCT su.itemdata_id) AS distinct_skus,
       count(DISTINCT su.client_id)   AS distinct_clients,
       sum(CASE WHEN su.amount > su.reservedamount THEN 1 ELSE 0 END) AS su_with_available
FROM location l
JOIN location_area la ON l.area_id = la.id
JOIN unitload ul      ON ul.storagelocation_id = l.id
LEFT JOIN stockunit su ON su.unitload_id = ul.id
WHERE la.name ILIKE '%transfer%' OR la.name ILIKE '%stag%'
   OR l.name  ILIKE '%transfer%' OR l.name  ILIKE '%stag%'
GROUP BY l.id, l.name, la.name
HAVING count(su.id) > 0
ORDER BY distinct_skus DESC, su_count DESC
LIMIT 25;
```

**What it establishes:** whether real transfer/staging lanes today already carry (a) multiple distinct SKUs, (b) multiple clients, and (c) reserved stock (`su_with_available` < `su_count`) — the pre-conditions that make selective + reserved-adjusted depletion valuable rather than cosmetic.

**Code-level schema confirmation** (independent of MCP): `StockunitRepository.getAmountAvailable` (`:82-92`) is the reserved-adjusted mirror — `SELECT sum(stockunit.amount - stockunit.reservedamount) … AND stockunit.amount > stockunit.reservedamount`, joining `stockunit.unitload_id → unitload.storagelocation_id → location.id`. So the ON gate semantics (§3.3) and the query's join path/columns are code-verified even though live counts are not yet collected.

---

## §3. Design

**Design decision (chosen):** thread a per-`itemdata` budget (`Map<Long,BigDecimal> needed`) through the **existing recursive `combineStock`** rather than adding a separate flat depletion method. This keeps ON and OFF on **one proven traversal** — preserving `combineStock`'s recursion into carrier child ULs (`:803`/`:820-822`) and its emptied-container / Nirvana bookkeeping — and eliminates by construction the "two enumeration envelopes must stay coupled" invariant and the recursion-gap risk that a parallel flat method would introduce. (Separate flat method rejected — see §9 Alt-5.) Concurrency safety comes from **staying consistent with the codebase's canonical source-SU → UL → Location lock order** plus `(UL-id, SU-id)` determinism (§3.5) — no new lock is introduced.

### 3.1 System-property toggle (`WmsConstants.java`, `*_ACTIVATED_*` block ~`:988-1090`)

```java
// SBDEV-1762 — Transfer lanes deplete like club lanes (selective partial), per-tenant opt-in.
public static final String SYSTEM_PROPERTY_TRANSFER_LANE_PARTIAL_DEPLETION_ACTIVATED_KEY   =
        "TRANSFER_LANE_PARTIAL_DEPLETION_ACTIVATED";
public static final String SYSTEM_PROPERTY_TRANSFER_LANE_PARTIAL_DEPLETION_ACTIVATED_DEFAULT_VALUE =
        "false";
```

**Read pattern** (matches `OrderReleaseJob.java:97`, `CleanUpOldMessagesJob.java:76`, `ReceivingService.java:507`), placed inside `transferOrder` right after `co`/`lane` load:

```java
boolean partial = Boolean.parseBoolean(
        syspropService.getSysvalue(
            WmsConstants.SYSTEM_PROPERTY_TRANSFER_LANE_PARTIAL_DEPLETION_ACTIVATED_KEY));
```

- `getSysvalue` (`SyspropService.java:289`) is a single **global-per-tenant** lookup. Each tenant is a separate DB, so the "global" `los_sysprop` row **is** the per-tenant opt-in. No 4-tier client/facility cascade is needed.
- `Boolean.parseBoolean(null) → false`, so an **absent row** yields default-OFF — correct and safe.
- Served from the existing sysprops Caffeine cache; eviction is `@CacheEvict("sysprops")` on `setSysvalue` (**`SyspropService.java:53`**).
- The sysprop is read **once per `transferOrder` call, at entry** — so flipping it OFF mid-flight is safe (see §8).

### 3.2 Toggle-scoped structure in `transferOrder` (`:735-796`)

```java
boolean partial = Boolean.parseBoolean(syspropService.getSysvalue(
        WmsConstants.SYSTEM_PROPERTY_TRANSFER_LANE_PARTIAL_DEPLETION_ACTIVATED_KEY));

String err = transferOrderService.isEnoughStockOnTransferLane(co, partial);   // overload, §3.3
if (err != null) throw new BusinessException(err);

// … unchanged pallet + parcel creation (:758-762) …

Fixedlocationassignment transferLaneFla = /* :769-770, unchanged */;
List<Unitload> laneUls = unitloadRepository.findByStoragelocationId(lane.getId());   // :766

Map<Long, BigDecimal> needed = null;
if (partial) {
    // Reserved-adjusted budget per required SKU, merged across positions.
    needed = new HashMap<>();
    for (CustomerorderPosition p : customerorderPositionRepository.findByOrderId(co.getId()))
        needed.merge(p.getItemdataId(), p.getAmount(), BigDecimal::add);

    // Deterministic global SU-acquisition order (UL-id, then SU-id) — ON PATH ONLY.
    // No up-front lane lock: the ON path stays canonical SU-first (§3.5).
    laneUls = laneUls.stream()
                     .sorted(Comparator.comparing(Unitload::getId))
                     .collect(Collectors.toList());
}
// OFF: laneUls stays in the exact unordered order returned by findByStoragelocationId (byte-identical).

for (Unitload ul : laneUls)
    combineStock(ul, parcel, co, transferLaneFla, needed);        // budget threaded (null when OFF)

// Fail-loud insurance (ON only): every required SKU must be fully satisfied.
if (partial)
    for (Map.Entry<Long, BigDecimal> e : needed.entrySet())
        if (e.getValue().signum() > 0)
            throw new BusinessException(
                "Transfer under-delivered for SKU itemdataId=" + e.getKey());

// … unchanged emptied-container relocation loop (:778-784) …
// … unchanged CO→PACKED+parcelId (:786-788), batch→ORDER_BATCH_CLUB_RUN_FINISHED + staginglaneId=null (:790-793) …
```

The ON block's first work is building `needed`, then sorting the lane ULs by id. **There is no up-front lane lock** (removed in v4 — §3.5 / §9 Alt-7). Everything outside the `partial` conditionals (pallet/parcel creation, emptied-UL relocation loop, CO state, batch state, `staginglaneId=null`) is shared and unchanged. The **only** OFF-visible difference is the new `needed` parameter on `combineStock`, which is `null` on OFF and drives the byte-identical branch (§3.4).

### 3.3 Gate overload — `isEnoughStockOnTransferLane(Customerorder, boolean partial)`

Add an overload in `TransferOrderService`; keep the existing single-arg method as the `!partial` delegate (no new `SyspropService` dependency; ctor `:51-75` stays as-is):

```java
public String isEnoughStockOnTransferLane(Customerorder co) {          // existing (:164)
    return isEnoughStockOnTransferLane(co, false);
}

public String isEnoughStockOnTransferLane(Customerorder co, boolean partial) {
    // require lane (:167-169)
    Map<Long, BigDecimal> laneByItem = new HashMap<>();
    for (Stockunit su : <lane stockunits, :174-181>) {
        BigDecimal contribution = partial
            ? su.getAmount().subtract(su.getReservedamount())   // ON: reserved-adjusted (v2 Change 5)
            : su.getAmount();                                   // OFF: raw amount (byte-identical)
        if (partial && contribution.signum() <= 0) continue;    // ON: skip fully-reserved SU (mirror getAmountAvailable AND clause)
        laneByItem.merge(su.getItemdataId(), contribution, BigDecimal::add);
    }

    for (CustomerorderPosition p : co.getPositions()) {                 // :185
        BigDecimal have = laneByItem.getOrDefault(itemId, BigDecimal.ZERO);
        if (have.signum() == 0 && !laneByItem.containsKey(itemId))
                                                      return NOT_ENOUGH;  // :188-191
        if (have.compareTo(required) < 0)             return NOT_ENOUGH;  // :193-196 (reserved-adjusted when ON)
        if (!partial && have.compareTo(required) > 0) return TOO_MUCH;    // :198-202 (OFF only)
    }
    if (!partial) {
        for (Long laneItem : laneByItem.keySet())                        // :205-217 (OFF only)
            if (!orderItems.contains(laneItem)) return FOUND_FOREIGN_SKUS;
    }
    return null;
}
```

**ON gate semantics = "gate passes ⇒ depletion succeeds":** because the ON gate sums `amount − reservedamount` (skipping SUs where `amount ≤ reservedamount`), mirroring `getAmountAvailable` (`:82-92`) and club `effectiveAvailable` (`:174`), a required SKU that is present in raw amount but **partly reserved below the required qty** correctly returns `NOT_ENOUGH` — it does **not** pass the gate and then throw inside `transferStockToUnitLoad`'s `amount − reservedamount` guard (`:213-215`). Excess and foreign SKUs still pass the ON gate and are left on the lane by depletion. OFF gate keeps raw-amount + "too much" + foreign rejects, byte-identical.

### 3.4 Parameterized `combineStock(..., Map<Long,BigDecimal> needed)` (`:798-824`)

Recursion, container skipping, and empty-UL bookkeeping are **unchanged**. The only edit is the leaf stockunit loop, which branches on whether a budget was supplied:

```java
private void combineStock(Unitload ul, Unitload parcel, Customerorder co,
                          Fixedlocationassignment transferLaneFla,
                          Map<Long, BigDecimal> needed) {          // NEW param; null == OFF
    if (isPalletOrParcel(ul)) return;                             // :800-802 unchanged

    for (Unitload child : childUnitloadsOf(ul))                   // :803 / :820-822 unchanged recursion
        combineStock(child, parcel, co, transferLaneFla, needed);

    List<Stockunit> sus = stockunitRepository.findByUnitloadId(ul.getId());   // :805 — same fetch (v2 Change 1)

    if (sus.isEmpty()) { emptyUnitLoadList.add(ul); return; }     // :806-809 unchanged

    if (needed == null) {
        // ── OFF: byte-identical to today (:812-815) ──
        for (Stockunit su : sus)
            stockunitBusinessService.transferStockToUnitLoad(
                su, parcel, su.getAmount(),
                CODE_TRANSFER_BUILD_TRUCK, co.getNumber(), null, false, true, transferLaneFla);
    } else {
        // ── ON: selective, reserved-adjusted, deterministic SU order ──
        List<Stockunit> ordered = sus.stream()
                .sorted(Comparator.comparing(Stockunit::getId))   // SU-id ascending (deterministic SU acquisition)
                .collect(Collectors.toList());
        for (Stockunit su : ordered) {
            Long item = su.getItemdataId();
            BigDecimal want = needed.getOrDefault(item, BigDecimal.ZERO);
            if (want.signum() <= 0) continue;                     // foreign OR already-satisfied → LEAVE on lane

            BigDecimal available = su.getAmount().subtract(su.getReservedamount());  // reserved-adjusted
            if (available.signum() <= 0) continue;                // fully reserved → skip

            BigDecimal transfer = want.min(available);            // min(needed, amount - reservedamount)
            stockunitBusinessService.transferStockToUnitLoad(
                su, parcel, transfer,
                CODE_TRANSFER_BUILD_TRUCK, co.getNumber(), null, false, true, transferLaneFla);
            needed.put(item, want.subtract(transfer));
        }
    }
    // NOTE: NO ON-specific emptyUnitLoadList handling. combineStock adds a UL to emptyUnitLoadList
    //       only when its stockunit list is empty. A UL left holding skipped foreign/excess SUs
    //       simply is not empty on this pass, so it is correctly NOT relocated. This is WHY reusing
    //       combineStock is cleaner: the emptied-UL logic is already correct for the ON case.
}
```

**Why the empty-UL bookkeeping needs no ON changes:** `combineStock` only ever adds a UL to `emptyUnitLoadList` when `findByUnitloadId(ul.getId())` returns empty (`:806-809`). Under ON, a UL that retains foreign SKUs or same-SKU excess still has stockunit rows, so it is never added and never relocated to Nirvana — exactly the desired "leave the remainder on the lane" behavior — **without any new envelope or coupling invariant.** (Lane-FLA edge: a fully-consumed SU is left as a zero-amount row per §2.5; `combineStock`'s emptiness test must treat that consistently with today's OFF behavior — OQ-7.)

**Precise definition:** `min(needed, su.amount)` throughout this plan means `min(needed, su.getAmount().subtract(su.getReservedamount()))`.

### 3.5 Concurrency — canonical SU-first lock order + `(UL-id, SU-id)` determinism (with an accepted residual)

The ON path acquires locks **only** through the shared `transferStockToUnitLoad` primitive, which locks in the canonical **source-SU → UL → Location** order (`StockunitBusinessService.java:240-243`, deliberate per **SBDEV-2481**). This yields the key correctness properties:

1. **No cross-caller lock-order inversion (the primary guarantee).** Every lane-touching operation in the codebase — putaway, replenish, move, pick, club, and now ON-mode transfer — acquires source-SU first, then UL, then Location. Because the ON path introduces **no new lock and does not reorder** the primitive, it **cannot** create a new transfer-vs-(putaway/replenish/move/pick/club) deadlock class. This is the decisive reason the v3 up-front lane-`Location` lock was removed: it would have inverted the canonical order and manufactured exactly such a cross-caller deadlock class (§9 Alt-7).
2. **Deterministic SU acquisition across concurrent ON runs.** The `(UL-id, SU-id)` global ordering — lane-UL sort in `transferOrder` (§3.2) + leaf-SU sort in `combineStock` (§3.4) — makes two concurrent ON runs walk the shared lane's SUs in the same order, so on the SUs they share they contend in a consistent sequence rather than inverting.

**RESIDUAL, ACCEPTED (USER-CONFIRMED 2026-07-23):** two ON-mode transfer runs draining the **same shared lane at the same instant**, where **each moves ≥2 SKUs and they share at least one higher-id SU**, can still deadlock (Postgres `40P01`). The cause is inherent to the shared primitive — `transferStockToUnitLoad` holds the lane `Location` lock (`:249-250`) across its per-SU moves, so run A can hold {SU-x, Location} while run B holds {SU-y} and waits for Location, then A waits for SU-y. `(UL-id, SU-id)` ordering narrows but does not fully eliminate this because the Location lock spans multiple per-SU acquisitions. **This is not introduced by this ticket** — it is the same rare multi-lock exposure the codebase already tolerates on every multi-SU-on-lane stock path (e.g. the club multi-SU path, §2.6), and it is **not worse** than that path.

**House convention (why this is acceptable):** wms2-api has **no deadlock/serialization-retry infrastructure**. The established convention for multi-lock stock paths is **canonical lock order + short pessimistic lock timeout + fail-fast**. On a `40P01`, the tenant transaction rolls back **atomically** (§3.6) — **no partial drain persists** — and the operator simply re-runs `runTransfer`. The ON path conforms to this convention exactly.

**Honest statement of guarantees:** cross-caller inversion is **eliminated**; the residual same-lane concurrent-transfer `40P01` is a **rare, atomic-rollback fail-fast**, not a corruption or partial-state risk. Making concurrent same-lane transfers fully clean (global 40P01 deadlock-retry, or reordering the primitive to Location-first for all 18 callers) is **out of scope** and **deferred to a concurrency-hardening follow-up ticket** (§10 Follow-up, §9 Alt-8).

### 3.6 Atomicity / data-safety guarantee (primary safety net for the residual race)

`transferOrder` is **confirmed** `@Transactional(value="tenantTransactionManager", rollbackFor={BusinessException.class, FacadeException.class})` (`BillofladingService.java:735`). The entire selective run — gate, every `transferStockToUnitLoad`, the fail-loud post-loop assertion (§3.2), CO/batch state changes — commits **atomically or not at all.** Any mid-loop throw rolls back the whole run: **no partial lane drain is ever persisted.** Critically, this is also the safety net for the accepted residual race: **on a `40P01` (CannotAcquireLockException) the whole tenant tx rolls back — no partial drain — and the operator re-runs.**

---

## §4. File Change Summary

| # | File | Change | Type |
|---|------|--------|------|
| 1 | `service/WmsConstants.java` (`*_ACTIVATED_*` block) | Add `SYSTEM_PROPERTY_TRANSFER_LANE_PARTIAL_DEPLETION_ACTIVATED_KEY` + `…_DEFAULT_VALUE="false"` | Add |
| 2 | `service/BillofladingService.java:735-796` | Read `partial`; build reserved-adjusted `needed`; sort lane ULs by id (ON only); thread `needed` into `combineStock`; add fail-loud post-loop assertion (ON). No new lock. | Modify |
| 3 | `service/BillofladingService.java:798-824` | Add `Map<Long,BigDecimal> needed` param to `combineStock`; ON/OFF leaf branch; sort leaf SUs by id (ON) | Modify |
| 4 | `service/TransferOrderService.java:164-221` | Add `isEnoughStockOnTransferLane(Customerorder, boolean)` overload; ON = reserved-adjusted sum + drop too-much/foreign; single-arg delegates `false` | Modify |
| 5 | `test/…/TransferOrderServiceUnitTest.java` | Add ON/OFF gate tests incl. reserved-adjusted (§7) | Test |
| 6 | `test/…/BillofladingServiceUnitTest.java` | Add ON tests incl. ascending-id-order InOrder test; keep 5 OFF tests green (§7) | Test |
| 7 | `sbdocs/9-System/scripts/verify-SBDEV-1762-transfer-lane-club-like-depletion.sh` | New acceptance script (§Acceptance) | Add |

**No changes:** `TransfersController.java` (contract preserved), `StockunitBusinessService.java` (primitive already splits + locks; canonical order preserved), the 17 other `transferStockToUnitLoad` callers, DB schema (no Flyway *schema* migration; **V2.2.04** is a data-only sysprop seed). **No new lock or repository method is added** (the v3 up-front `LocationRepository.findByIdForUpdate` call was removed).

---

## §5. Phased Implementation Plan

### §5.1 Prerequisites

| # | Prerequisite | Required value / action | Notes |
|---|---|---|---|
| 1 | **Database state** | No schema change (data-only seed). Flyway **V2.2.04** (`V2.2.04__seed_lane_behavior_sysprop_toggles.sql`, wms2-api PR #93) seeds the `los_sysprop` row `syskey='TRANSFER_LANE_PARTIAL_DEPLETION_ACTIVATED'` **default OFF** (`sysvalue='false'`) on freshly provisioned DBs; opting-in tenants flip it to `'true'`. Absent row = OFF. | V2.2.04 = data seed, **no DDL**. Existing tenants (running app does **not** invoke Flyway) are seeded by an operator running `flyway migrate` (or `psql`-applying `V2.2.04__seed_lane_behavior_sysprop_toggles.sql`) against the tenant DB. Per-tenant opt-in (`sysvalue='true'`) is a separate step via `configure-client-sysprops.sh` / `SyspropService.setSysvalue`. |
| 2 | **Feature flags / system properties** | Ship default OFF. Set the sysprop `true` only on tenants that requested club-like behavior. | Per-tenant opt-in (see #5). |
| 3 | **Config / env changes** | N/A — no `application.properties` / jasypt / keycloak change. | Pure toggle-in-DB. |
| 4 | **Deploy-order dependencies** | N/A — WMS-only; `runTransfer` contract unchanged so UI needs no redeploy. | — |
| 5 | **Data migration** | N/A — no backfill. Enablement is one `setSysvalue` per opting-in tenant (`operator/configure-client-sysprops.sh`). | Operational toggle, not a migration. |
| 6 | **External systems** | N/A — no OMS webhook / printer / keycloak interaction added; OMS callbacks unchanged. | — |
| 7 | **Access / permissions** | N/A — no new endpoint, role, or authority. | — |
| 8 | **Monitoring / alerts** | Optional: watch `runTransfer` `BusinessException` rate + any `40P01`/`CannotAcquireLockException` occurrences for opted-in tenants post-enable. No new metric required. | 40P01 expected rare (residual same-lane concurrent transfer, §3.5); feeds the follow-up hardening ticket. |

### §5.2 Implementation Checklist

- [ ] **P1 (Impl):** Add sysprop key + default in `WmsConstants.java`.
- [ ] **P1 (Impl):** Add reserved-adjusted `isEnoughStockOnTransferLane(Customerorder, boolean)` overload; single-arg delegates.
- [ ] **P1 (Impl):** In `transferOrder`: read `partial`; build reserved-adjusted `needed`; sort lane ULs by id (ON only); thread `needed`; add fail-loud post-loop assertion (ON). **No up-front lock.**
- [ ] **P1 (Impl):** Parameterize `combineStock` with `needed`; ON leaf branch reserved-adjusted + SU-id sort; OFF branch verbatim; reuse `findByUnitloadId` (no `getStockunits()`).
- [ ] **P2 (Test):** Add ~6 `TransferOrderServiceUnitTest` methods + ~7 `BillofladingServiceUnitTest` ON methods (incl. InOrder ordering test); confirm 5 OFF tests + controller tests stay green unmodified.
- [ ] **P2 (Verify):** `mvn clean compile` + targeted `mvn test -Dtest=BillofladingServiceUnitTest,TransferOrderServiceUnitTest,TransfersControllerUnitTest`.
- [ ] **P2 (Verify):** Run `verify-SBDEV-1762-transfer-lane-club-like-depletion.sh` → 0 FAIL.
- [ ] **P3 (Ops, per opting-in tenant):** run §2.7 query; then `setSysvalue(...true)` and run the Manual Test Plan (§7.3).

---

## §6. Backward Compatibility

| Aspect | OFF (default, all existing tenants) | ON (opt-in) |
|--------|-------------------------------------|-------------|
| Gate `isEnoughStockOnTransferLane` | 3 reject branches on **raw** amount (missing/under, too-much, foreign) — byte-identical | **Reserved-adjusted**; only missing/under-qty blocks |
| Lane UL order | unordered `findByStoragelocationId` sweep (as today) | sorted by `Unitload::getId` asc (deterministic SU acquisition) |
| Lock order | canonical SU→UL→Location (via primitive) | **same** canonical SU→UL→Location (no new lock) |
| Lane drain | `combineStock(needed=null)` → whole `su.getAmount()` | `combineStock(needed≠null)` → `min(needed, amount−reservedamount)` on required SKUs only |
| `combineStock` recursion / empty-UL bookkeeping | unchanged | unchanged (same method, same fetch) |
| Post-loop assertion | none | fail-loud under-delivery check |
| `runTransfer` HTTP contract | 200 + `{errors:[{...}]}` unchanged | identical |
| Pallet/parcel, CO→PACKED+parcelId, batch→FINISHED, staginglaneId=null | unchanged | unchanged |
| Emptied-container relocation | `relocateEmptiedContainer(...NIRVANA...)` | same (only fully-drained ULs qualify) |
| DB schema / Flyway | no schema change; **V2.2.04** data-only sysprop seed (default OFF) | no schema change |
| Existing tests | pass **unmodified** | new tests added |

### What Does NOT Change

- OFF-path behavior (guaranteed: `combineStock(needed=null)` reproduces `:812-815` verbatim; the lane-UL sort and post-loop assertion are ON-only).
- `GET /v3/transfers/runTransfer/{orderId}` contract and `{errors:[...]}` envelope (`TransfersController.java:245-259`).
- Pallet + parcel unit-load creation; CO / batch state cascade; `staginglaneId=null`.
- OMS callbacks.
- `entityLock` / optimistic-lock semantics.
- **Canonical `transferStockToUnitLoad` SU→UL→Location lock order (`:240-243`)** — unchanged; the ON path does not reorder or add locks; its 17 other callers are untouched.
- DB schema — no DDL change (Flyway **V2.2.04** is a data-only sysprop seed, not a schema migration).

**Data-safety guarantee:** whole run is one `tenantTransactionManager` tx with `rollbackFor={BusinessException,FacadeException}` (`:735`) — any mid-loop throw, including a `40P01`, rolls back atomically; no partial drain persists (§3.6).

---

## §7. Testing Strategy

### 7.1 Unit tests (named) — ~13 total

**`TransferOrderServiceUnitTest`** (add to `:415-520` cluster):
1. `isEnoughStockOnTransferLane_toggleOff_foreignSku_returnsFoundSkusMessage`
2. `isEnoughStockOnTransferLane_toggleOff_excess_returnsTooMuchStock`
3. `isEnoughStockOnTransferLane_toggleOn_foreignSkuPresent_returnsNull`
4. `isEnoughStockOnTransferLane_toggleOn_sameSkuExcess_returnsNull`
5. `isEnoughStockOnTransferLane_toggleOn_underQuantity_returnsNotEnough`
6. `isEnoughStockOnTransferLane_toggleOn_requiredSkuReserved_returnsNotEnough` (reserved-adjusted gate): SKU present with `amount ≥ needed` but `amount − reservedamount < needed` → "Not enough stock".

**`BillofladingServiceUnitTest`** (add to `:1173-1907` cluster; mock `SyspropService`, `StockunitBusinessService`, `CustomerorderPositionRepository`, `StockunitRepository.findByUnitloadId`, `UnitloadRepository.findByStoragelocationId`):
7. `transferOrder_toggleOff_exactMatch_sweepsAllUnitLoads` (regression — asserts `su.getAmount()` still moved, no sort applied)
8. `transferOrder_toggleOn_foreignSku_depletesOnlyOrderSkus_foreignStockRemains`
9. `transferOrder_toggleOn_sameSkuExcess_consumesExactQty_remainderStays`
10. `transferOrder_toggleOn_multiUlPerSku_accumulatesAcrossUnitLoadsFifo`
11. `transferOrder_toggleOn_insufficient_throwsNotEnough` (gate blocks before drain)
12. `transferOrder_toggleOn_drainsUnitLoadsInAscendingIdOrder` (determinism guard): mock `findByStoragelocationId` returning **shuffled** ULs (and multi-SU leaves); Mockito `InOrder` asserts `transferStockToUnitLoad` invoked in ascending `(UL-id, SU-id)` order.
13. `transferOrder_toggleOn_underDelivered_throwsUnderDelivered` (fail-loud): contrived leaf whose reserved-adjusted available cannot satisfy the budget after the gate → post-loop assertion throws `"Transfer under-delivered for SKU…"`.

**Testcontainers IT (author `@Disabled`, tagged `TODO(SBDEV-2217)`):**
- `transferOrder_toggleOn_concurrentSameLane_deadlockRollsBackAtomically` — documents the **residual** race: two sessions drain the same shared lane, each moving ≥2 SKUs sharing a higher-id SU; the primitive's Location-lock-across-per-SU-moves can produce a `40P01`. Asserts the **losing tx rolls back atomically (no partial drain)** and the operation is safely re-runnable — **NOT** "clean, no 40P01". A **cross-caller** IT (transfer vs putaway/replenish/move) is **NOT needed**: the ON path is SU-first-consistent with every other caller (§3.5), so it introduces no cross-caller inversion by construction. **The unit suite does NOT cover the true race** — this IT is the only real-race probe and is gated on the SBDEV-2217 harness fix; the concurrency-hardening follow-up ticket (§10) owns making it fully clean.

The 5 existing `transferOrder` tests (incl. SBDEV-2001 emptied-sibling `:1846-1907`) and controller tests (`TransfersControllerUnitTest.java:273-287`) stay green **unmodified**.

### 7.2 Integration tests

True-race verification requires Testcontainers. The v2 IT harness is broken (SBDEV-2217 — Testcontainers Postgres lane can't boot). **Gate on unit tests + `mvn clean compile`**; author the residual-race IT `@Disabled` with `TODO(SBDEV-2217)`. Strategy needs no new IT to ship: SU-first consistency is a static property of reusing the unmodified primitive, and the SU ordering is covered deterministically by unit test #12.

### 7.3 Manual Test Plan (MANDATORY)

| Scenario | Environment | Steps | Expected | Pass/Fail |
|----------|-------------|-------|----------|-----------|
| ON: foreign SKU on lane | staging (opted-in) | Stage order SKUs + one foreign SKU; `runTransfer/{orderId}` | 200, no `errors`; only order SKUs on truck; foreign SKU stays on lane | |
| ON: same-SKU excess | staging | Stage 12 of SKU-A, order needs 10; `runTransfer` | 200; 10 moved; 2 remain (positive-amount SU) | |
| ON: multi-UL accumulation | staging | SKU-A split 4+4+4 across 3 ULs, order needs 10; `runTransfer` | 10 consumed in ascending (UL-id, SU-id) order across ULs; 2 remain; fully-drained ULs → Nirvana | |
| ON: under-quantity blocks | staging | Stage 8 of SKU-A, order needs 10; `runTransfer` | 200 `errors:["Not enough stock on transfer lane yet"]`; nothing moved | |
| ON: required SKU present but partly reserved | staging | Stage 10 of SKU-A but 3 reserved (amount 10 ≥ needed 10, but amount−reserved 7 < 10); `runTransfer` | 200 `errors:["Not enough stock on transfer lane yet"]`; **nothing moved** (reserved-adjusted gate blocks) | |
| ON: two orders sharing one lane, run near-simultaneously (residual-race probe) | staging | Stage SKU-A+SKU-B (order1) and SKU-B+SKU-C (order2) sharing SKU-B on one lane; fire both `runTransfer` calls concurrently, repeat | Both succeed serialized in the common case; if a rare `40P01` occurs, the losing run rolls back atomically (no partial drain) and re-running it succeeds | |
| OFF regression | staging (default) | Exact-match lane; `runTransfer` | Byte-identical to today: sweeps all ULs, all relocated | |
| OFF regression: excess still blocks | staging (default) | Stage excess; `runTransfer` | `errors:["Too much stock for SKU=…"]` | |
| SQL sanity (lane reality) | staging DB | run §2.7 query | non-empty; confirms multi-SKU lanes + reserved rows exist | |

### 7.4 Horizontal Scalability Validation (v2 — MANDATORY)

| # | Concern | Does this change… | Verdict | Mitigation / rationale + evidence |
|---|---|---|---|---|
| 1 | In-JVM state | new Caffeine/`ConcurrentHashMap`/static/`ThreadLocal`? | **No** | `needed` is a method-local `HashMap` inside one tenant tx; no cross-request state. |
| 2 | Connection pool math | change per-request DB connection usage? | **No** | Same single tenant tx; `combineStock` traversal count unchanged. No new pools/tenants. |
| 3 | Scheduled jobs | add/modify `@Scheduled`/cron? | **No** | Request-scoped endpoint flow only. |
| 4 | Long transactions | hold a tx across many repo calls / external I/O? | **N/A (no worse)** | Loop bound = lane stockunit count, same as today's sweep; no external I/O in tx. |
| 5 | Request affinity | assume follow-up hits same replica? | **No** | Single synchronous request; no session/WebSocket/SSE. |
| 6 | Retry / idempotency | rely on single-execution that breaks on replica death + retry? | **No** | Whole run is one tenant tx (`:735`, §3.6); mid-run crash/40P01 rolls back — no partial commit; re-run re-evaluates gate + availability under lock. |
| 7 | Tenant context | use `TenantContext`/`ThreadLocal` across async boundaries? | **No** | Fully synchronous within `transferOrder`; no `@Async`/`CompletableFuture`. |
| 8 | Distributed lock correctness | add/rely on pessimistic/optimistic lock across replicas? | **Yes** | **PRIMARY: ON path preserves the canonical source-SU → UL → Location lock order** (via the unmodified `transferStockToUnitLoad`, `StockunitBusinessService.java:240-243`, per SBDEV-2481) — it adds no new lock and does not reorder, so it introduces **no cross-caller lock-order inversion** with putaway/replenish/move/pick/club. **DETERMINISM: global `(UL-id, SU-id)` ordering** (lane-UL sort in `transferOrder`, leaf-SU sort in `combineStock`) makes concurrent-ON SU acquisition deterministic. **RESIDUAL (accepted, user-confirmed):** two same-lane concurrent ON transfers each moving ≥2 SKUs sharing a higher-id SU can still `40P01` because the primitive holds the lane Location lock across per-SU moves (`:249-250`) — inherent to the shared primitive, no worse than the existing club multi-SU-on-lane path; wms2-api has **no deadlock-retry infra**, so the house convention (canonical order + short pessimistic timeout + fail-fast + atomic rollback, §3.6) applies. A global 40P01 retry / primitive Location-first reorder is deferred to a **concurrency-hardening follow-up ticket** (§10). All inside `@Transactional("tenantTransactionManager")` (`:735`). Guard: unit test #12 (SU order); SU-first consistency is static (unmodified primitive). |
| 9 | Cache invalidation | write to a cached entity? | **No (read-only cache use)** | Only reads the sysprops cache; toggle change propagates via existing `@CacheEvict("sysprops")` on `setSysvalue` (`SyspropService.java:53`). |
| 10 | External notifications | send HTTP/message to external system inside a tx? | **No** | No OMS/printer call added; existing callbacks fired as today. |

**Evidence (Yes rows):** #8 — ON path calls only the unmodified `transferStockToUnitLoad` (canonical SU→UL→Location, `StockunitBusinessService.java:240-243/:209/:245/:249-250`, `@Lock(PESSIMISTIC_WRITE)` per `StockunitRepository.findByIdForUpdate:32-35`, `UnitloadRepository.findByIdForUpdate:29-31`); `(UL-id, SU-id)` determinism sorts in `transferOrder` (lane-UL list) + `combineStock` (leaf SU list); reserved-adjusted re-check `:213-215`; atomic rollback `:735` / §3.6; deterministic guard = unit test #12; residual race + deferral documented §3.5 + §10 Follow-up.

### 7.5 v2 Constraint Checklist (MANDATORY)

| # | Constraint | Verdict | Evidence (file:line) |
|---|---|---|---|
| 1 | Dual transaction-manager: writes on `tenantTransactionManager` | **PASS** | `transferOrder` `@Transactional("tenantTransactionManager")` `BillofladingService.java:735`; `transferStockToUnitLoad` tenant-scoped `StockunitBusinessService.java:188` |
| 2 | `readOnly=true` on pure reads | **PASS (N/A)** | Gate overload runs inside the write tx; no separated read-only overload added. `TransferOrderService.java:164` |
| 3 | OSIV disabled — all lazy loads inside tx | **PASS** | All new loads (`findByOrderId`, `findByStoragelocationId`, `findByUnitloadId`) inside `transferOrder` tx `:735-796` |
| 4 | Jakarta namespace (not `javax`) | **PASS** | `jakarta.persistence.LockModeType.PESSIMISTIC_WRITE` per `StockunitRepository.java:32-35` |
| 5 | H2 vs Testcontainers coverage | **PASS w/ caveat** | Unit tests mock repositories/services (no DB); SU ordering guarded by InOrder test #12; SU-first consistency is static (unmodified primitive). Residual-race IT `@Disabled TODO(SBDEV-2217)`; `wms2-it-harness-broken-sbdev-2217` |
| 6 | No Flyway migration unless schema changes | **PASS (data-only migration added)** | No schema change / no DDL. Flyway **V2.2.04** added post-implementation as a **data-only** seed of the sysprop row default OFF (idempotent `INSERT ... WHERE NOT EXISTS`, `id` from `seqentities`); wms2-api PR #93. |
| 7 | Optimistic-lock retry / `entity_lock` respected | **PASS** | Primitive uses pessimistic `findByIdForUpdate` + `refresh` `StockunitBusinessService.java:209-211` in canonical order; no new lock or optimistic path |
| 8 | Multi-replica safety (no per-JVM assumption) | **PASS (with documented residual)** | All coordination is DB-level SELECT FOR UPDATE via the unmodified primitive; canonical SU-first order (no cross-caller inversion) + `(UL-id, SU-id)` determinism (§7.4 #8); residual same-lane 40P01 is atomic-rollback fail-fast, deferred (§10) |

---

## §8. Rollout Plan

1. **Ship default OFF.** Merge to `develop`; all tenants keep exact-match+sweep behavior (byte-identical). No coordinated UI/OMS deploy.
2. **Verify neutral rollout.** On staging, confirm OFF regression scenarios (§7.3) pass on a default tenant before any enablement.
3. **Per-tenant opt-in.** For each requesting tenant: run the §2.7 lane-reality query, then `setSysvalue('TRANSFER_LANE_PARTIAL_DEPLETION_ACTIVATED','true')` via `operator/configure-client-sysprops.sh`. The sysprops `@CacheEvict` makes the toggle effective without redeploy.
4. **Post-enable smoke.** Run the ON Manual Test Plan scenarios on the opted-in tenant (including the residual-race probe); watch `runTransfer` `BusinessException` rate and any `40P01`/`CannotAcquireLockException` (rare; feeds the follow-up hardening ticket).
5. **Rollback.** Set the sysprop back to `false` (or delete the row) — instant revert to exact-match+sweep, no deploy, no data cleanup. **Flipping the sysprop OFF mid-flight is safe because each `transferOrder` call re-reads the sysprop at entry (§3.1); there are no in-flight side effects, and any in-progress call completes atomically under its own tx (§3.6).**

---

## §9. Alternatives Considered

| # | Alternative | Decision | Rationale |
|---|-------------|----------|-----------|
| 1 | Reuse `ClubLineOrderProcessor`/`runClubLine` wholesale | **Rejected** | Club path is batch-scoped with its own state machine; transfer is single-order/lane-scoped. Reuse duplicates/entangles state transitions and broadens scope. Chose to **parallel** the club reserved-adjusted `min(needed,available)` model while reusing shared primitives. |
| 2 | Hard behavior change (no toggle) | **Rejected** | Silently changes behavior for tenants relying on strict exact-match+sweep. Chose `*_ACTIVATED` sysprop default-OFF. |
| 3 | Whole-UL-only move (no splitting) | **Rejected** | Cannot leave same-SKU excess without overship or block. Splitting required — and free (`transferStockToUnitLoad` already splits, `:342/:370-374`). |
| 4 | Concurrency: **whole-lane** `findByStoragelocationIdForUpdate` scan lock | **Rejected** | A FOR-UPDATE scan over **all** lane ULs — broad lock scope, needs a **new** repository query and a Testcontainers IT (blocked by SBDEV-2217). Also risks cross-caller inversion. Chose canonical-SU-first consistency instead. |
| 5 | Separate flat `depleteSelectively(...)` method (v1 draft) | **Rejected (design pivot)** | Would maintain a **second lane-enumeration envelope** parallel to `combineStock`, creating an implicit "both envelopes must stay coupled" invariant and a **recursion-gap risk** (would not recurse into carrier child ULs at `:803/:820-822`). Chose to **parameterize the existing recursive `combineStock`** — one proven traversal, correct empty-UL bookkeeping for free. |
| 6 | Raw-amount ON gate (no reserved subtraction) | **Rejected** | Gate could pass on raw amount, then `transferStockToUnitLoad`'s `amount−reservedamount` guard (`:213-215`) throws mid-loop. Reserved-adjusted gate (mirroring `getAmountAvailable:82-92` / club `effectiveAvailable:174`) makes "gate passes ⇒ depletion succeeds." |
| 7 | **Up-front lane-`Location` pessimistic lock** (`locationRepository.findByIdForUpdate(lane)` before the drain — the v3 proposal) | **Rejected (v4, user-confirmed)** | It would fix transfer-vs-transfer contention **but invert the canonical source-SU → UL → Location order** (`StockunitBusinessService.java:240-243`, SBDEV-2481): the transfer would take `Location` first while putaway/replenish/move/pick/club take SU first → a **new cross-caller `40P01` deadlock class**. wms2-api has **no retry infra** to absorb it. Chose instead to stay SU-first-consistent (no cross-caller inversion) and **document/defer the residual same-lane transfer-vs-transfer race** (§3.5, §10 Follow-up). |
| 8 | **Reorder `transferStockToUnitLoad` to Location-first for all 18 callers** (or add a global 40P01 deadlock-retry) | **Rejected for this ticket / deferred** | Would eliminate the residual same-lane race cleanly, but it is a **broad, high-regression change** touching every stock-move caller and needs its own design + review + IT coverage. Out of scope here; **deferred to the concurrency-hardening follow-up ticket** (§10 Follow-up). |

---

## §10. Open Questions / Resolved Decisions

### Resolved (design to these — verbatim + pivots)

1. **Depletion scope = FULL club-like (partial):** deplete only the order's required SKUs + quantities; leave foreign SKUs AND same-SKU excess on the lane. Requires passing a partial amount to `transferStockToUnitLoad` (already splits). *Resolved by DEFAULT (user declined to override recommendation).*
2. **Rollout = system-property toggle, default OFF (per-tenant opt-in).** OFF = today's exact-match + sweep-all, byte-identical. *Resolved by DEFAULT.*
3. **Concurrency = canonical SU-first lock order (consistent with all callers, no cross-caller inversion) + `(UL-id, SU-id)` global ordering for determinism.** The **up-front lane-`Location` lock is REJECTED** (it inverts the canonical order and creates a new transfer-vs-putaway/replenish/move `40P01` class; no retry infra exists to absorb it — §9 Alt-7). **Residual:** a rare same-lane concurrent-transfer `40P01` is **accepted as an atomic-rollback fail-fast** (house convention: canonical order + short pessimistic timeout + fail-fast; no retry infra; not worse than the existing club multi-SU path), and a global deadlock-retry / primitive Location-first reorder is **deferred to a separate concurrency-hardening follow-up ticket**. **USER-CONFIRMED 2026-07-23.**
4. **Scope boundary (USER-CONFIRMED explicitly):** missing/under-qty (reserved-adjusted) required SKU **STILL blocks** with "Not enough stock" — NO short/overship (future). **SBDEV-1666** (don't replenish FROM staging/transfer lanes) is **EXCLUDED** (separate ticket).
5. **Implementation shape (design pivot, Architect+Critic converged):** thread a `Map<Long,BigDecimal> needed` budget through the **existing recursive `combineStock`** (`needed==null` ⇒ OFF byte-identical; `needed≠null` ⇒ selective). A **separate flat `depleteSelectively` method is REJECTED** (§9 Alt-5). *Resolved by reviewer consensus 2026-07-23.*
6. **Availability semantics = reserved-adjusted (design pivot):** ON gate sums `amount − reservedamount` (skip fully-reserved SUs) and ON depletion uses `transfer = min(needed, amount − reservedamount)`, mirroring `getAmountAvailable:82-92` / club `effectiveAvailable:174`. OFF gate keeps raw amount. *Resolved by reviewer review 2026-07-23.*
7. **Deterministic ordering scope:** lane-UL sort and leaf-SU sort are applied **ON path only**; OFF stays the unordered sweep byte-identical. **No up-front lock on either path** (removed in v4). *Resolved 2026-07-23.*

### Open

1. **DB verification unrun** (both MCPs down at authoring). Run §2.7 query (or supply an operator result) before closing the evidence bar. *[db_verified: blocked]*
2. **Reserved-stock real-world prevalence is DB-unverified (assumption).** The reserved-adjusted design is correct regardless, but the §2.7 query should confirm how often transfer/staging lanes actually carry reserved stock (justifies the added complexity).
3. **FIFO-by-id default** — confirm ascending `stockunit.id` selection order is acceptable for consumption (it is also the determinism mechanism; by-expiry deferred to future — would require reconciling selection order with consumption preference).
4. **Lock strategy** — chosen = canonical SU-first + `(UL-id, SU-id)` determinism + accepted residual (Resolved-3). The retry-vs-reorder decision for making concurrent same-lane transfers fully clean is **owned by the concurrency-hardening follow-up ticket** (Follow-up below), not this plan.
5. **Reconcile lock timeout** — global `jakarta.persistence.lock.timeout` (ticket cites 5000ms) vs the 1000ms PO-lock timeout referenced at `transferStockToUnitLoad:200`. Confirm which governs the FOR-UPDATE waits (affects how fast the residual `40P01` fails and rolls back).
6. **Confirm legacy `TransfersController.transferOrder` (`:70`/`:246`) is dead** — if live, ensure it does not bypass the toggle read.
7. **Lane-FLA edge** — a fully-consumed SU is left as a zero-amount row + its UL is not auto-relocated by the primitive (matches OFF). Confirm `combineStock`'s emptiness test treats zero-amount SUs consistently with OFF so genuinely-drained ULs still relocate to Nirvana.

### Follow-up ticket (to file)

- **NEW — "Stock-move deadlock-retry hardening (global `40P01` retry OR `transferStockToUnitLoad` Location-first reorder)".** Scope: give wms2-api a house mechanism to make concurrent same-lane stock moves (transfer, club, replenish, move) fully clean — either a global serialization-failure/`40P01` retry wrapper around tenant-tx stock operations, or reordering the shared primitive to Location-first across all 18 callers (with full regression + Testcontainers IT coverage, gated on SBDEV-2217). This would let a future version of SBDEV-1762's ON path eliminate the residual same-lane concurrent-transfer race (§3.5). Referenced by §9 Alt-8, §7.4 #8, and Resolved-3.

---

## §Acceptance

**Machine-checkable script:** `sbdocs/9-System/scripts/verify-SBDEV-1762-transfer-lane-club-like-depletion.sh` (authored alongside this plan, before implementation).

**Required checks (positive + negative):**
- `check_wmsconstants_key_present` — POSITIVE: `SYSTEM_PROPERTY_TRANSFER_LANE_PARTIAL_DEPLETION_ACTIVATED_KEY` present; `…_DEFAULT_VALUE="false"`.
- `check_toggle_read_present` — POSITIVE: `Boolean.parseBoolean(syspropService.getSysvalue(...))` for the new key in `transferOrder`.
- `check_combinestock_budget_param` — POSITIVE: `combineStock` signature carries the `Map<Long, BigDecimal> needed` parameter.
- `check_off_branch_intact` — NEGATIVE-preserving: the `needed == null` branch still moves `su.getAmount()` via `transferStockToUnitLoad(...CODE_TRANSFER_BUILD_TRUCK...)`; `findByStoragelocationId` + `relocateEmptiedContainer` still present.
- `check_no_getstockunits` — NEGATIVE: assert **no** `getStockunits()` call introduced; ON leaf uses `stockunitRepository.findByUnitloadId(`.
- `check_no_upfront_location_lock` — NEGATIVE (v4): assert the ON path does **NOT** call `locationRepository.findByIdForUpdate` (proving the inverting up-front lock was not reintroduced; canonical SU-first order preserved).
- `check_lane_ul_sorted_on` — POSITIVE: `Comparator.comparing(Unitload::getId)` (or `sorted(` … `Unitload::getId`) in the ON region of `transferOrder`.
- `check_su_sorted_on` — POSITIVE: `Comparator.comparing(Stockunit::getId)` in `combineStock` ON leaf.
- `check_reserved_adjusted_gate` — POSITIVE: `getReservedamount` (or `amount - reservedamount` / `.subtract(su.getReservedamount())`) in the ON branch of the gate and the ON depletion leaf.
- `check_gate_overload` — POSITIVE: `isEnoughStockOnTransferLane(Customerorder, boolean)` overload exists; single-arg delegates with `false`.
- `check_gate_off_branches_guarded` — POSITIVE: "Too much" + foreign-SKU rejects gated behind `!partial`.
- `check_fail_loud_assertion` — POSITIVE: post-loop under-delivery assertion in the ON path throws `BusinessException` on any residual `needed > 0`.
- `check_primitive_untouched` — NEGATIVE: `StockunitBusinessService.transferStockToUnitLoad` signature and body unchanged (canonical lock order intact).
- Behavioral: `mvn test -Dtest=BillofladingServiceUnitTest,TransferOrderServiceUnitTest,TransfersControllerUnitTest` → 0 failures (~13 new + all existing green), including `transferOrder_toggleOn_drainsUnitLoadsInAscendingIdOrder` (InOrder) and `isEnoughStockOnTransferLane_toggleOn_requiredSkuReserved_returnsNotEnough`.

**Contract:** the implementing agent runs the script after each pass and pastes output into its report; the orchestrator re-runs it. A "DONE" claim with any FAIL line is not accepted. Gate on unit tests + `mvn clean compile` (v2 IT harness blocked by SBDEV-2217; residual-race IT `@Disabled TODO(SBDEV-2217)`).

**Recommended OMC composition:** Size class = **Standard** (4 code sites, single subsystem, toggle-guarded). Pre-draft = analyst+planner (this ralplan loop). Plan-review = **critic** + **architect** (this consensus pass). Implementation shape = **executor** (verify script comprehensive). Verification = verify-script + **verifier** (mandatory). Code-review = **code-reviewer** (recommended — concurrency posture is subtle). Commit = git directly (single logical commit).


> **Archived 2026-07-25.** Acceptance script retired to `sbdocs/4-Archieves/scripts/verify-SBDEV-1762-transfer-lane-club-like-depletion.sh`.
