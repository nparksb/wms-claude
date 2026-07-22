---
title: "SBDEV-2512 — Honor partitionallowed=false in Overstock Release: Hold-or-Single-Pick Instead of Fragmenting a Non-Partitionable Position Across Stock Units"
ticket: "SBDEV-2512"
ticket_url: "https://app.clickup.com/t/SBDEV-2512"
type: bugfix
priority: high
status: archived
status_detail: "REINSTATED 2026-07-09. History: implemented 2026-07-08 (b9655bf → PR #191) → reverted 2026-07-09 (PR #192, team no longer needed it) → REINSTATED 2026-07-09 by team request (cherry-pick of b9655bf → PR #194 into develop; mvn clean compile clean, ReleaseOrderJobServiceUnitTest 33/33 green on top of current develop). Reached develop only (not release/main)."
project: [wms1]
version: v1
requester: "Nam Park"
created: 2026-07-08
updated: "2026-07-15"
db_verified: true
related:
  - "[[SBDEV-2096-configurable-pick-path-direction]]"
  - "[[SBDEV-2099-outbound-parcel-report-clears-after-palletize]]"
  - "[[wms1-picking-workflow]]"
  - "[[wms1-state-machine-catalog]]"
tags:
  - plan
  - picking
  - release-order
  - overstock
  - data-integrity
---

# SBDEV-2512 — Honor partitionallowed=false in Overstock Release: Hold-or-Single-Pick Instead of Fragmenting a Non-Partitionable Position Across Stock Units

**Ticket:** [SBDEV-2512](https://app.clickup.com/t/SBDEV-2512) (WineCo)
**Project:** wms1 | **Version:** v1/wms-api | **Type:** bugfix
**Priority:** High
**Status:** ✅ **IMPLEMENTED (reinstated)** — 2026-07-09. Lifecycle: implemented 2026-07-08 (`b9655bf` → PR [#191](https://github.com/SiteBossInc/wms-api/pull/191)) → reverted 2026-07-09 (PR [#192](https://github.com/SiteBossInc/wms-api/pull/192), team said no longer needed) → **REINSTATED 2026-07-09 by team request** (cherry-pick of `b9655bf` → PR [#194](https://github.com/SiteBossInc/wms-api/pull/194) into `develop`). See §10.

> **✅ REINSTATED 2026-07-09 (PR #194).** After the #192 revert, the team asked for this behavior back. The original commit `b9655bf` was cherry-picked onto current `develop` (clean, no conflicts): `mvn clean compile` clean, `ReleaseOrderJobServiceUnitTest` 33/33 green. `ENFORCE_PARTITIONALLOWED` (default ON), the `reserveSingleCoveringUnit` phase-2 hold ledger, and the phase-3 single-pick branch are all back. Kill-switch `sysvalue=false` disables it without redeploy.
**Date:** 2026-07-08

> **Rev-3 note (2nd ITERATE fix — C-3).** Rev-2's Fix B `throw` was **reachable**: two non-partitionable positions with the *same* itemdataId both pass phase-2's existence check (phase-2 reads one pre-phase-3 DB snapshot with no intra-order same-SKU decrement), then in phase-3 the first position reserves the covering unit and the second re-queries → no single covering unit → `covering==null` → `throw` → `REQUIRES_NEW` rollback that **re-throws every cron run = permanently stuck order** (strictly worse than today's fragment-and-ship). Rev-3 makes **Fix A cumulative** across same-itemdataId positions within the order (a per-SKU per-unit net ledger, decremented on each admission), so a multi-position same-SKU order that can't single-pick all positions is **HELD in phase-2** instead. Fix B's `throw` is reframed as a TRUE failsafe for the residual inter-order concurrency race only.

> **Rev-2 note (1st ITERATE fix).** A *single* phase-2 existence guard does not stop fragmentation: `getStockUnitsByItemDataId` orders by **gross** `amount DESC` but coverage is **net** (`amount − reservedamount`), so a covering unit can exist yet phase-3's greedy pass still splits. Fix is two-part: **Fix A** holds; **Fix B** single-picks. Both gate on a **LosSysprop kill-switch** (default ON).

> **What the client saw.** Parcel `061130-000002` (BF173533) arrived in tote `T-0155` as the *same order line "repeated" three times* — 9, then 2, then 1 — and the operator picked loose bottles instead of a single 12-count case. Sibling parcel `061130-000001` pulled cleanly as ONE 12-count case, prompting "why did one pick as a case and the other as three picks?"

---

## 0. Affected sites (enumeration before drafting)

Enumerated via `grep -rn` over `src/main/java` for `getPartitionallowed` / `setPartitionallowed` / `partitionallowed`, `createPickingPosition`, `getStockUnitsByItemDataId`, `getStockUnitAvailable`, `pickFromOverstock`, `findSysvalueBySyskey`; confirmed against the code + WineCo prod DB (schema `public`).

| # | File:line | Construct | Same root-cause (splits a non-partitionable position)? | In-scope this plan? |
|---|-----------|-----------|------------------|----------------------|
| 1 | `service/job/ReleaseOrderJobService.java:487-538` | overstock phase-3 creation loop; first pass exact-match `== 0` @495, then greedy second pass @513-537 (`createPickingPosition` partial @522 / remainder @530) consuming **net** avail in **gross-DESC** candidate order until `missing==0`; **never checks `partitionallowed`**; pre-existing `RuntimeException` @542 on unsatisfiable | **YES (root cause vector; BF173533)** | **YES — EDITED (Fix B)** |
| 2 | `service/job/ReleaseOrderJobService.java:205-420` phase-2 classification; accept branch adds to `pickFromOverstock` @245 on **AGGREGATE** availability (`getStockUnitAvailable` @226, INPUT map @223, OUTPUT map @249) | **YES — necessary hold gate** (cumulative per-SKU guard immediately before line 245) | **YES — EDITED (Fix A)** |
| 3 | `service/job/ReleaseOrderJobService.java:470-485` fixed-assignment single full-amount pick (`createPickingPosition` @477) — why sibling `061130-000001` was clean | No (single source, one full pick by construction) | No — correct by construction |
| 4 | `service/PickingorderPositionService.java:50` `createPickingPosition` — shared amount-agnostic creator | No — the caller decides the amount; Fix B calls it once with `missing` | No |
| 5 | `service/PickingorderPositionService.java:78-159` `fixPickingPosition` — already enforces a single unit `>=` full amount | No — already correct (the behavior Fix B brings to phase-3 overstock) | No |
| 6 | `service/mobile/MobilePickingService.java:225/366/461/848`, `service/mobile/MobileInfoService.java:100/273` | update-only saves / read-only lookups of `partitionallowed` | No | No |
| 7 | `controller/rest/OrderRestController.java:460` `setPartitionallowed(false)` — the **sole writer**; hard-codes `false` for all imported positions (no `true` path exists in v1 today) | No — source of the flag value; explains 100% blast radius (see kill-switch, §9) | No |
| 8 | Replenish job; club-line / manual release routes | route through the same `releaseOrder` phase-2/phase-3 | No / covered transitively by Fix A + Fix B | No |
| 9 | `repo/jpa/StockunitRepository.java:82-93` `getStockUnitsByItemDataId` — `@Query ... ORDER BY stockUnit.amount DESC` (**gross**, not net) + `amount > reservedamount` filter | Contributing (the sort/coverage mismatch is why phase-2-alone is insufficient; the filter is why a phase-3 re-query sees prior reservations) | No — not edited; documented in §2/§5 |

Rows 1–2 are the fix loci (**both edited**: Fix A @245, Fix B @487-538). Row 9 explains the gross-vs-net divergence and the phase-3 re-query visibility (C-3). Rows 3–8 excluded with rationale; row 7 explains the flag is universally `false` (100% cron blast radius → kill-switch).

---

## 1. Problem Statement

**Ticket (SBDEV-2512, WineCo):** on BF173533, order parcel `061130-000002` was released as **three** picking positions into a single tote — 9 + 2 + 1 = 12 — instead of one 12-count pick. The operator saw the same order/tote line "repeat" three times and picked loose bottles rather than a full case. The sibling parcel `061130-000001` on the same order batch pulled cleanly as ONE 12-count case.

**Expected:** a position flagged non-partitionable (`partitionallowed = false`) must be filled from a **single stock unit** covering the full amount, or else **held** (never fragmented). Only a partitionable position may be split across sources.

**Actual:** the overstock release path splits any position across as many stock units as it takes to satisfy aggregate demand, regardless of `partitionallowed`.

### DB verification (WineCo prod, schema `public`, `db_verified: true`)

```sql
-- Order batch + orders (BF173533)
SELECT id, state FROM customerorder WHERE orderbatch_id = 33786802 ORDER BY id;
-- 33786803 (parcel 061130-000001), 33786805 (parcel 061130-000002); orderbatch 33786802
```

```sql
-- The two sibling positions: both partitionallowed = false, both amount 12
SELECT id, customerorder_id, amount, partitionallowed
FROM   customerorder_position
WHERE  id IN (33786804, 33786806);
--  33786804 | 33786803 | 12 | f   (sibling 061130-000001 → 1 clean pick)
--  33786806 | 33786805 | 12 | f   (parcel  061130-000002 → 3 fragmented picks)
```

```sql
-- The fragmentation: 3 picking positions created for cop 33786806 (9 / 2 / 1) vs 1 for cop 33786804
SELECT id, pickingorder_id, customerorder_position_id, amount, stockunit_id
FROM   pickingorder_position
WHERE  customerorder_position_id IN (33786804, 33786806)
ORDER  BY customerorder_position_id, id;
--  927808 | ... | 33786806 |  9 | (UL350579)
--  927809 | ... | 33786806 |  2 | (UL351049)
--  927810 | ... | 33786806 |  1 | (UL351048)
--  (cop 33786804 → single position from UL350577 = 12)
```

Picking order `PICK272768` (pickingorder id `33786968`) carried the three fragments into tote `T-0155`. Both orders now sit at state `600` (PICKED); `PICK272768` reached `700` (FINISHED), advanced `2026-07-02 09:08` by hand. **The hand-finish / stuck-closure is a SEPARATE ticket and out of scope here.** WineCo hit this on `2026-07-01` when SKU `2500904` stock dropped below a single-case unit across its pickable faces; because `partitionallowed` is `false` for ALL positions today (§0 row 7), EVERY multi-source overstock pick fragments — this parcel was simply the first with no full-case unit available. Note BF173533 itself was two *separate* customerorders (one position each), not one order with two same-SKU positions — see the C-3 exposure query in §9/§10.

---

## 2. Root Cause Analysis

### Bug 1 — `releaseOrder` overstock path fragments a non-partitionable position because `partitionallowed` is never read, AND phase-3 splits by net-avail in gross-sorted order

`CustomerorderPosition.getPartitionallowed()` (`CustomerorderPosition.java:162`) has **ZERO read call-sites** in the release/picking hot path — it is only written, hard-coded `false` at `OrderRestController.java:460` (§0 row 7). `ReleaseOrderJobService.releaseOrder` is `@Transactional` (`REQUIRES_NEW`, `rollbackFor = {BusinessException, FacadeException}` @72) with a pessimistic order lock (`findByIdForUpdate` @80). Two phases collaborate:

- **Phase 2 — classification (`~205-420`).** A position is accepted into `pickFromOverstock` @245 on **AGGREGATE** availability: `getStockUnitAvailable(...)` returns `[total, reserved]` and the branch checks `total − reserved >= amount` (@226). Phase-2 reads one pre-phase-3 DB snapshot (INPUT map @223, recompute @226, distinct OUTPUT map @249) and does **not** decrement for prior same-order same-SKU admissions. This proves *enough total inventory exists across all units* — not that any single unit covers the amount, and not that a *second* same-SKU position can still find its own single unit.

- **Phase 3 — creation (`487-538`).** For each accepted position it iterates `stockunitRepository.getStockUnitsByItemDataId(itemdataId)` and:
  1. **First pass (@495)** looks for a unit whose **net** avail (`amount − reservedamount`) `== missing` exactly. Partial mitigation only, not the fix.
  2. **Second pass (@513-537)** greedily consumes each candidate's net avail — partial @522, remainder @530 — until `missing == 0`. It **never checks `partitionallowed`**. `@542` throws a `RuntimeException` if still unsatisfied.

**Why a phase-2 existence guard alone is INSUFFICIENT (verified).** `getStockUnitsByItemDataId` (`StockunitRepository.java:82-93`) is `ORDER BY stockUnit.amount DESC` (**gross**); coverage is **net**. So an existence check can pass while phase-3's gross-ordered greedy pass fragments:

> **Divergence example (single position):** required = 12. `U_A` amount 25 / reserved 20 → net 5, sorts **first** (gross 25). `U_B` amount 18 / reserved 0 → net 18, sorts **second**. A phase-2 existence guard sees `U_B` covers → admits. Phase-3 first pass (`net == 12`) matches nothing; second pass takes `U_A`(5) then `U_B`(7) → **TWO picks**. Still fragmented.

**Why a *non-cumulative* phase-2 guard is ALSO insufficient (C-3, verified).** Phase-2 evaluates each position against the same pre-phase-3 snapshot with no intra-order same-SKU decrement, so two non-partitionable positions of the *same* itemdataId both pass an existence/coverage check. In phase-3, position 1 reserves the covering unit (`changeReservedAmount` @269 → Hibernate auto-flush), and position 2's re-query (`amount > reservedamount` filter, §0 row 9) no longer sees a single covering unit → `covering==null` → `throw` → rollback that re-throws every cron run = **permanently stuck order**.

> **C-3 example:** SKU units `U`(net 18) + `V`(net 6); two non-partitionable positions of 12 each. Original code releases (P1 = 12 from `U`, P2 fragments 6 + 6). A non-cumulative Fix B *throws*. The fix must instead HOLD in phase-2 when the order's own same-SKU positions can't each secure a distinct single covering unit.

The phase-2 guard (cumulative, Fix A) and the phase-3 selection (Fix B) use the **same predicate** (`net >= required`), so once phase-2 simulates the reservations, "phase-2 admitted all same-SKU positions" ⇒ "phase-3 finds a single unit for each" — for the single-order path.

**CLAUDE.md context applied:** compare by ID not `.equals()`; no JPA associations (manual FK repo calls); `partitionallowed` is a nullable Boolean → `Boolean.TRUE.equals(...)` for null-safety.

---

## 3. (Regression Chain)

**No regression.** `git log --oneline` on `ReleaseOrderJobService.java` shows the overstock split has behaved this way since the initial commit `a685e07b` — phase-3 never consulted `partitionallowed`. The defect is *latent-since-inception*, visible only when a SKU's stock drops below a single full-amount unit across pickable faces (WineCo, `2026-07-01`). No commit table applies.

---

## 4. Architecture Overview

```
OMS import → OrderRestController.importOrders  controller/rest/OrderRestController.java:460
  └─ setPartitionallowed(false)   ← SOLE writer; every position is non-partitionable in v1 today (§0 row 7)

ReleaseOrderJob (scheduled) / club-line / manual release
  └─ ReleaseOrderJobService.releaseOrder()      service/job/ReleaseOrderJobService.java
       @Transactional(REQUIRES_NEW, rollbackFor={BusinessException,FacadeException}) :72
       order locked via findByIdForUpdate :80
       ★ read kill-switch once: enforcePartitionGuard = LosSysprop(ENFORCE_PARTITIONALLOWED) != "false"  (default ON)
       ★ per-order per-SKU net ledger: Map<Long,List<BigDecimal>> remainingNetByItemData   (Fix A cumulative)
       │
       ├─ PHASE 2  classification :205-420
       │    ├─ fixed-assignment branch → single full pick (:470-485)  ← sibling clean path (§0 row 3)
       │    ├─ overstock accept branch (AGGREGATE getStockUnitAvailable :226):
       │    │     ★ Fix A: guard BEFORE pickFromOverstock.add(position) :245
       │    │         if enforcePartitionGuard && !partitionallowed
       │    │              && !reserveSingleCoveringUnit(remainingNetByItemData, itemdataId, amount):
       │    │             LOG.info(held...); position.setState(55); save; containsUnsatisfiedPosition=true; continue
       │    │         (reserveSingleCoveringUnit seeds the SKU's per-unit net list on first use and
       │    │          DECREMENTS the chosen unit — so a 2nd same-SKU position can't double-book it)
       │    │     pickFromOverstock.add(position) :245
       │    └─ ... other branches (:260 uses hold state 56)
       │
       ├─ hold gate :437   if (containsUnsatisfiedPosition && order.state ∈ {RAW,FUTURE_PICKING_DATE,CLIENT_HAS_NO_SECTION})
       │                    → order.setState(RAW_ON_HOLD=50) :440 → manageOrderService.customerOrderOnHold :442 → return
       │
       └─ PHASE 3  creation :487-538   (only reached when NOT held)
            getStockUnitsByItemDataId  (ORDER BY amount DESC = GROSS; filter amount>reservedamount)
            ★ Fix B: if enforcePartitionGuard && !partitionallowed:
                 pick FIRST live candidate with (amount - reservedamount) >= missing   ← SAME predicate as Fix A
                 createPickingPosition(missing, that unit) exactly once; setState ASSIGNED; continue
                 (covering==null ⇒ throw BusinessException — UNREACHABLE for the single-order path after
                  cumulative Fix A; retained as a TRUE failsafe for the inter-order race, mirroring the
                  pre-existing RuntimeException @542)
            else (partitionable): existing first pass (==) @495 + greedy second pass @513-537  ← UNCHANGED
```

**Key Files**

| File | Lines | Role |
|------|-------|------|
| `service/job/ReleaseOrderJobService.java` | 205-420 (phase 2), 437-446 (hold gate), 487-538 (phase 3) | **Fix A** cumulative guard @~245 + per-order net ledger + **Fix B** single-pick branch @487-538; new private `reserveSingleCoveringUnit`; kill-switch read at method entry |
| `repo/jpa/StockunitRepository.java` | 82-93 | `getStockUnitsByItemDataId` — `ORDER BY amount DESC` (**gross**) + `amount > reservedamount` filter; the sort/coverage mismatch and the re-query visibility behind C-3 (no change) |
| `model/CustomerorderPosition.java` | 162 | `getPartitionallowed()` — read for the first time in the release path (both fixes) |
| `service/PickingorderPositionService.java` | 50, 78-159 | `createPickingPosition` (called once by Fix B); `fixPickingPosition` already single-unit-safe |
| `repo/jpa/LosSyspropRepository.java` | 40 | `findSysvalueBySyskey(String)` — kill-switch read (pattern from `CleanUpOldMessageJobService`) |
| `service/StockunitBusinessService.java` | `getStockUnitAvailable`, `changeReservedAmount` | aggregate `[total, reserved]` (phase 2); reservation write (both phases) |
| `controller/rest/OrderRestController.java` | 460 | `setPartitionallowed(false)` — sole writer (context, no change) |

---

## 5. Fix Design

Both fixes gate on a single kill-switch read at the top of `releaseOrder`:

```java
boolean enforcePartitionGuard = !"false".equalsIgnoreCase(
    losSyspropRepository.findSysvalueBySyskey(WmsConstants.SYSTEM_PROPERTY_ENFORCE_PARTITIONALLOWED_KEY));
// default ON: null/absent row or any value other than "false" ⇒ enforce (§7.1 row 2, §9 rollback lever)
```

### Fix A — phase-2 CUMULATIVE guard: hold when a non-partitionable position cannot secure its OWN single covering unit given prior same-order same-SKU admissions

Seed a per-order ledger once before the phase-2 classification loop:

```java
Map<Long, List<BigDecimal>> remainingNetByItemData = new HashMap<>();
```

In the overstock accept branch, immediately **before** `pickFromOverstock.add(position)` at line 245:

**Before:**
```java
// aggregate availability already proven above (getStockUnitAvailable, :226)
pickFromOverstock.add(position);
```

**After:**
```java
if (enforcePartitionGuard
        && !Boolean.TRUE.equals(position.getPartitionallowed())
        && !reserveSingleCoveringUnit(remainingNetByItemData, position.getItemdataId(), position.getAmount())) {
    // SBDEV-2512 Fix A: no single unit can cover this non-partitionable position AFTER prior
    // same-order same-SKU admissions → hold the order, don't fragment (and don't let phase-3 throw).
    LOG.info("SBDEV-2512 held: no single unit covers non-partitionable position id=" + position.getId()
        + " itemdataId=" + position.getItemdataId() + " amount=" + position.getAmount()
        + " order=" + order.getNumber());
    position.setState(WmsConstants.State.RAW_ON_HOLD_NOT_ENOUGH_STOCK_ON_LOCATION); // 55
    customerorderPositionRepository.save(position);
    containsUnsatisfiedPosition = true;
    continue;
}
pickFromOverstock.add(position);
```

**New private helper** — a per-order *simulation* of the single-unit reservation Fix B will perform in phase-3. It lazily seeds each SKU's per-unit **net** list (in the same gross-DESC candidate order) and **decrements the chosen unit** so a second same-SKU position cannot double-book it. The per-unit predicate (`remaining >= required`) is **identical** to Fix B's selection predicate, so *admission ⇒ phase-3 can single-pick* for the single-order path.

```java
/** Per-order simulation of Fix B: can a SINGLE stock unit still cover `required` for this SKU
 *  after prior same-order admissions? Seeds the SKU's per-unit net list on first use (gross-DESC
 *  candidate order) and decrements the first covering unit on success. */
private boolean reserveSingleCoveringUnit(Map<Long, List<BigDecimal>> ledger,
                                          Long itemdataId, java.math.BigDecimal required) {
    List<java.math.BigDecimal> remaining = ledger.computeIfAbsent(itemdataId, id -> {
        List<java.math.BigDecimal> nets = new java.util.ArrayList<>();
        for (Stockunit su : stockunitRepository.getStockUnitsByItemDataId(id)) {
            nets.add(su.getAmount().subtract(su.getReservedamount()));
        }
        return nets;
    });
    for (int i = 0; i < remaining.size(); i++) {
        if (remaining.get(i).compareTo(required) >= 0) {          // FIRST covering unit (deterministic)
            remaining.set(i, remaining.get(i).subtract(required)); // simulate reserving it for this position
            return true;
        }
    }
    return false;
}
```

Setting `containsUnsatisfiedPosition = true` reaches the EXISTING hold gate at line 437 (flips the order to `RAW_ON_HOLD` (50) only when its state ∈ {`RAW`, `FUTURE_PICKING_DATE`, `CLIENT_HAS_NO_SECTION`}, then `customerOrderOnHold` @442 → `return`), which runs **before** `pickingOrderService.create()` (~463) — **zero picking positions / reservations** for the held order, no rollback needed. The whole order holds if *any* of its non-partitionable positions can't secure a single unit (including the multi-position same-SKU case), so no partial release.

### Fix B — phase-3: for a non-partitionable position, create exactly ONE pick from a single covering unit

At the top of the per-position phase-3 loop body (`487-538`), branch on the flag and short-circuit the two fragmenting passes.

**Before (per `orderPosition`):**
```java
for (CustomerorderPosition orderPosition : pickFromOverstock) {
    List<Stockunit> stockUnitCandidates = stockunitRepository.getStockUnitsByItemDataId(orderPosition.getItemdataId());
    BigDecimal missing = orderPosition.getAmount();
    // first pass: exact net == missing (@495) ... ; second pass: greedy net consumption (@513-537) — FRAGMENTS
}
```

**After:**
```java
for (CustomerorderPosition orderPosition : pickFromOverstock) {
    List<Stockunit> stockUnitCandidates = stockunitRepository.getStockUnitsByItemDataId(orderPosition.getItemdataId());
    BigDecimal missing = orderPosition.getAmount();

    if (enforcePartitionGuard && !Boolean.TRUE.equals(orderPosition.getPartitionallowed())) {
        // SBDEV-2512 Fix B: non-partitionable → single covering unit, exactly one pick; never fragment.
        Stockunit covering = null;
        for (Stockunit su : stockUnitCandidates) {                       // same DESC(gross) order, live net
            if (su.getAmount().subtract(su.getReservedamount()).compareTo(missing) >= 0) { // SAME predicate as Fix A
                covering = su;                                           // FIRST covering candidate (deterministic)
                break;
            }
        }
        if (covering == null) {
            // Unreachable for the single-order path after the cumulative Fix A check. Retained as a TRUE
            // failsafe for the residual INTER-ORDER race (another order's release reserves the unit between
            // this order's phase-2 and phase-3) — the same exposure the pre-existing RuntimeException @542 has.
            // rollbackFor on the REQUIRES_NEW tx unwinds any prior picks in THIS release cleanly.
            throw new BusinessException("SBDEV-2512: no single stock unit covers non-partitionable position "
                + orderPosition.getId());
        }
        PickingorderPosition pickingPosition =
            pickingorderPositionService.createPickingPosition(missing, covering, orderPosition, pickingOrder);
        stockunitBusinessService.changeReservedAmount(covering, missing, false,
            WmsConstants.CODE_CREATE_PICK_POSITION, pickingPosition.getNumber(), null);
        orderPosition.setState(WmsConstants.State.ASSIGNED);
        customerorderPositionRepository.save(orderPosition);
        continue;                                                        // skip first/second fragmenting passes
    }

    // ... existing first pass (==) @495 + greedy second pass @513-537 — UNCHANGED for partitionable positions ...
}
```

**Candidate selection:** the **FIRST** covering candidate in the existing gross-DESC order — simplest and deterministic. Smallest-covering (best inventory hygiene) is noted but **not shipped** (no correctness benefit for this ticket).

**S-4 — failsafe message render.** `new BusinessException("SBDEV-2512: …")` binds to `BusinessException(String message)` (`BusinessException.java:37`), which routes through `resolveMessage(locale, "placeholder", message)` and surfaces mangled as `"placeholder, 'SBDEV-2512: …'"`. Because this `throw` is a near-unreachable failsafe (single-order path can't hit it; only the rare inter-order race can), a literal is acceptable — we deliberately do **not** add a `messages_en_US.properties` key (keeps the diff to one file). The verify script's B2 check greps a stable substring (`SBDEV-2512: no single stock unit covers`) of this literal; if the literal is reworded, update B2.

### Resulting behavior matrix (kill-switch ON)

| Position state | Before (today) | After (Fix A + Fix B) |
|---|---|---|
| `partitionallowed=false`, no single unit's net covers amount | fragmented (BF173533) | order **held** (position 55, order 50); no picks — **Fix A** |
| `partitionallowed=false`, single unit covers (incl. gross-DESC divergence) | may still fragment | exactly **ONE** pick — **Fix B** |
| `partitionallowed=false`, **two same-SKU positions**, coverages mutually exclusive (C-3) | releases (P1 single, P2 fragments) | order **held** in phase-2 — **cumulative Fix A** (no `throw`) |
| `partitionallowed=true` | split | **unchanged** — both fixes short-circuit on the flag |
| kill-switch OFF (`sysvalue=false`) | — | today's behavior returns for ALL positions (no redeploy) |

### Rejected alternatives
- **Phase-2-only existence guard (rev 1):** provably insufficient — gross-DESC vs net divergence lets phase-3 still fragment (AC-5).
- **Non-cumulative two-part fix (rev 2):** Fix B's `throw` is **reachable** for multi-position same-SKU orders → permanently stuck order (AC-6). Rev-3's cumulative Fix A closes it.

---

## 6. File Change Summary

| File | Change Type | Description |
|------|-------------|-------------|
| `service/job/ReleaseOrderJobService.java` | edit (kill-switch + cumulative Fix A + Fix B + helper) | Read `enforcePartitionGuard` at entry; per-order `remainingNetByItemData` ledger; **Fix A** cumulative hold guard @~245 (reads `getPartitionallowed()`, mandatory `LOG.info`); **Fix B** single-pick branch @487-538 (reads `getPartitionallowed()`, one `createPickingPosition`, failsafe `throw`); new `reserveSingleCoveringUnit(Map, Long, BigDecimal)`; inject `LosSyspropRepository` if absent |
| `service/WmsConstants.java` | edit (add constant) | `SYSTEM_PROPERTY_ENFORCE_PARTITIONALLOWED_KEY` (sysprop syskey) |
| `src/test/java/.../ReleaseOrderJobServiceTest.java` | edit (add tests) | AC-1..AC-6 unit tests (§8) — Mockito 3.3.3, no `mockStatic` |
| `sbdocs/9-System/scripts/verify-SBDEV-2512-partitionallowed-split-pick-overstock-guard.sh` | new | Machine-checkable acceptance (phase-2 + phase-3 + `mvn` behavior gate) |

No DB schema/DDL change; no new message-properties key (S-4). One **data prerequisite**: seed the `LosSysprop` row (default on) — §7.1.

---

## 7. Implementation Steps

### 7.1 Prerequisites

| # | Prerequisite | Applies? | Detail |
|---|---|---|---|
| 1 | **Database state** (schema version, Flyway baseline) | **N/A** | No schema/DDL/Flyway change. `customerorder_position.partitionallowed` already exists and is `NOT NULL`. |
| 2 | **Feature flags / system properties** | **YES (new)** | Seed a `LosSysprop` row: syskey = `SYSTEM_PROPERTY_ENFORCE_PARTITIONALLOWED_KEY`, sysvalue = `true`. Read via `LosSyspropRepository.findSysvalueBySyskey`. **Default ON:** absent/null row also enforces (`!"false".equalsIgnoreCase(...)`), so safe before seeding; `sysvalue=false` disables both fixes without redeploy (§9 rollback lever). |
| 3 | **Config / env changes** | **N/A** | None beyond the sysprop row (row 2). |
| 4 | **Deploy-order dependencies** | **N/A** | Single wms-api JAR; no OMS/UI coordination. |
| 5 | **Data migration** | **N/A** | No data mutated; behavior is data-independent code logic. |
| 6 | **External systems** | **N/A** | None. |
| 7 | **Access / permissions** | **N/A** | No endpoint/authority change. |
| 8 | **Monitoring / alerts** | **YES (mandatory)** | The Fix A hold `LOG.info` (itemdataId/SKU, required amount, position id, order id, "held: no single unit covers non-partitionable position") is **mandatory** — the guard runs on a 100%-blast-radius prod cron, so ops must see held events and correlate a hold spike with the deploy. |

**Summary:** one config prerequisite (seed the kill-switch sysprop, default on) and mandatory hold telemetry; no DB/Flyway/migration/deploy-order dependency.

### 7.2 Steps (each independently committable)

1. Add `SYSTEM_PROPERTY_ENFORCE_PARTITIONALLOWED_KEY` to `WmsConstants`; inject `LosSyspropRepository` into `ReleaseOrderJobService` (if absent) and read `enforcePartitionGuard` once at method entry. Compile.
2. Add the per-order `remainingNetByItemData` ledger and the private `reserveSingleCoveringUnit(Map, Long, BigDecimal)` helper. Compile.
3. **Fix A** — insert the cumulative phase-2 hold guard before `pickFromOverstock.add(position)` @~245, including the **mandatory** `LOG.info`. Compile.
4. **Fix B** — insert the phase-3 non-partitionable single-pick branch at the top of the `487-538` loop body (with the failsafe `throw`). Compile.
5. Add AC-1..AC-6 unit tests (§8) to `ReleaseOrderJobServiceTest`; run `mvn test -Dtest=ReleaseOrderJobServiceTest`.
6. Seed the kill-switch sysprop row on each target tenant (default `true`).
7. Run `bash sbdocs/9-System/scripts/verify-SBDEV-2512-partitionallowed-split-pick-overstock-guard.sh` → `Result: N pass, 0 fail`.

---

## 8. Testing Plan

### Unit (test class `ReleaseOrderJobServiceTest` — Mockito 3.3.3, **no `mockStatic`**; repositories/services are injected mocks)

Driven by stubbing `stockunitRepository.getStockUnitsByItemDataId(...)` (the candidate list — input to both the ledger and phase-3) plus `getStockUnitAvailable`. Stub `losSyspropRepository.findSysvalueBySyskey(...)` → `"true"` for the enforce cases. For AC-6, the phase-3 re-query stub must reflect the reservation the first position makes (return the second candidate list with the covering unit's net reduced) so the test exercises the real inter-position visibility — but with cumulative Fix A the order is held in phase-2 and phase-3 is never reached.

1. **AC-1 (core negative — BF173533 hold; Fix A):** `partitionallowed=false`, candidates net `{9, 2, 1}`, amount `12` → position state `55`, order state `50`, `customerOrderOnHold(...)` once, `verify(pickingorderPositionService, never()).createPickingPosition(...)`.
2. **AC-2 (single exact unit; Fix B):** `partitionallowed=false`, one candidate net `= 12` → exactly ONE `createPickingPosition(12)`, position `ASSIGNED (200)`, no hold.
3. **AC-3 (partitionable unchanged):** `partitionallowed=true`, candidates net `{9, 2, 1}` → THREE `createPickingPosition(9, 2, 1)`.
4. **AC-4 (single surplus unit; Fix B):** `partitionallowed=false`, one candidate net `= 20` → exactly ONE `createPickingPosition(12)`, no hold.
5. **AC-5 (gross-vs-net divergence; Fix B pins rev-1 hole):** `partitionallowed=false`, candidates gross-DESC `[U_A amount25/reserved20 (net5), U_B amount18/reserved0 (net18)]`, amount `12` → EXACTLY ONE `createPickingPosition(12)` from `U_B`, `never()` any partial/second pick. **Fails a phase-2-only fix; passes only with Fix B.**
6. **AC-6 (C-3 regression pin — cumulative Fix A):** ONE order with **TWO** non-partitionable positions of the **same itemdataId**, coverages mutually exclusive — candidates `U`(net 18) + `V`(net 6), two positions of `12` each → assert the whole order is **HELD in phase-2** (position state `55`, order state `50`), `verify(pickingorderPositionService, never()).createPickingPosition(...)`, and **NO exception thrown**. **Must FAIL against rev-2 (Fix B throws) and PASS after the cumulative Fix A** (change #1). This is the C-3 regression pin.

**Mock/setup notes:**
- **S-1 (order state seed):** AC-1/AC-6 orders must be seeded in `RAW` (or `FUTURE_PICKING_DATE` / `CLIENT_HAS_NO_SECTION`) — the hold gate @437-439 only flips to `50` for those states.
- Stub: `customerorderRepository.findByIdForUpdate`; `customerorderPositionRepository` (`findByOrderId` returns both positions for AC-6, `save`); `itemdataRepository`; `stockunitRepository.getStockUnitAvailable` (`[total, reserved]`) + `getStockUnitsByItemDataId` (candidate list = ledger + phase-3 input); `pickingOrderService.create`; `pickingorderPositionService.createPickingPosition`; `stockunitBusinessService.changeReservedAmount`; `manageOrderService`; `losSyspropRepository.findSysvalueBySyskey`; `basicService.showLog()` → `false`.

### Integration (Testcontainers)

**Blocked / gated `@Disabled`** by **SBDEV-2384** (`ro_id` view drift — all v1 `@SpringBootTest` ITs fail at context load). If proposed, mark `@Disabled` with `// TODO(SBDEV-2384): re-enable once ro_id view drift is fixed`. Acceptance meanwhile = `mvn clean compile` + the 6 unit tests + manual smoke.

### Regression

- `mvn clean compile`; `mvn test -Dtest=ReleaseOrderJobServiceTest`.
- Confirm partitionable / fixed-assignment paths untouched (AC-3).
- **S-2 note:** the phase-3 first-pass exact-match (`net == missing` @495) is only a partial mitigation — not the fix.

### Manual test plan

| # | Scenario | Environment | Steps | Expected Result | Pass/Fail |
|---|---|---|---|---|---|
| M1 | **Incident vector held** (Fix A) | staging | SKU where no single unit's net covers a non-partitionable amount (12 across 9/2/1); run release | Order **HOLD** (50), position `55`; **no** picks | |
| M2 | Single-unit clean pick (Fix B) | staging | Same SKU but one unit's net = 12 | ONE pick for 12; no hold | |
| M3 | **Divergence single-pick** (AC-5) | staging | Units net5(gross25) + net18(gross18); amount 12 | ONE pick of 12 from the net-18 unit | |
| M4 | **Same-SKU two-position hold** (AC-6/C-3) | staging | One order, two non-partitionable positions of 12; units net18 + net6 | Order **HELD** in phase-2; **no** picks; **no** stuck/throw loop | |
| M5 | Partitionable still splits | staging | `partitionallowed=true`, units 9/2/1 | THREE picks (9/2/1) — unchanged | |
| M6 | **Kill-switch OFF** | staging DB | Set sysprop `sysvalue=false`; rerun M1 | Today's behavior returns (fragments) — no redeploy | |
| M7 | SQL sanity after M1 | staging DB | `SELECT count(*) FROM pickingorder_position WHERE customerorder_position_id = <held cop>;` | `0` | |

### Test execution (fill in after running)

| Command | Result | Pass / Fail / Skipped |
|---------|--------|------------------------|
| `mvn test -Dtest=ReleaseOrderJobServiceTest` | | |
| `mvn clean compile` | | |
| `bash sbdocs/9-System/scripts/verify-SBDEV-2512-...sh` | | |

---

## 9. Risks & Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| **Always-on prod cron, 100% blast radius** — `partitionallowed=false` for ALL positions (§0 row 7) | behavior change ships to every overstock release on a scheduled cron; naive rollback = redeploy | **LosSysprop kill-switch (default ON)** — `sysvalue=false` restores today's behavior for all positions with **no redeploy** (§7.1 row 2). Primary rollback lever. |
| Guard holds orders that previously released (as fragmented picks) | some orders now HOLD instead of picking loose bottles | **Intended** — fragmenting a non-partitionable case is the bug. Ops sees the mandatory `LOG.info` (state 55) and replenishes a full unit; kill-switch is the escape hatch. |
| **Cumulative Fix A over-holds multi-position same-SKU orders** | an order with 2+ same-SKU non-partitionable positions that can't each single-pick is held | **Measured zero present-day exposure** (§10): **0 of 479,265** WineCo orders have >1 position for the same itemdataId (their model = one position per parcel/SKU). Cumulative Fix A is defensive insurance with no mass-hold risk today. Kill-switch covers the tail. |
| **Concurrency — inter-order race on Fix B's `throw`** | two orders releasing concurrently: order B reserves the covering unit between order A's phase-2 and phase-3 → A's phase-3 `covering==null` → `throw` → A's `REQUIRES_NEW` rolls back and retries next cron | This is the **same exposure the pre-existing `RuntimeException` @542 already has** — not introduced here; the order is picked up on the next cron with fresh stock. The order lock (`findByIdForUpdate` @80) serializes same-order releases; cross-order stock contention is inherent to the overstock model. Documented, not expanded. |
| Guard/phase-3 predicate drift | Fix A admits a position Fix B then can't single-pick | Fix A's ledger simulation and Fix B's live selection use the **identical** per-unit predicate `(amount − reservedamount) >= required` and the same first-covering rule; AC-2/AC-4/AC-5/AC-6 pin it. For the single-order path the `throw` is **unreachable by construction**; for the inter-order race it fails safe (rollback + retry). |
| Null `partitionallowed` | wrong branch / NPE | `Boolean.TRUE.equals(...)` is null-safe; column is `NOT NULL` (§7.1 row 1). |
| Verify script over-claim (phase-2-only or non-cumulative fix "passes") | a weaker fix could grep-pass | Script requires `getPartitionallowed()` read **≥2×** (phase-2 + phase-3), the sysprop key, the `reserveSingleCoveringUnit` helper, AND `mvn_test_passes ReleaseOrderJobServiceTest` (incl. **AC-5** + **AC-6**) — shape alone cannot all-pass. |

**Horizontal scalability (v2):** **N/A — v1-only plan.** v2/wms2-api has its own release path and multi-replica considerations; evaluate a v2 counterpart separately.

---

## 10. Implementation Status

**Reinstated 2026-07-09 (PR [#194](https://github.com/SiteBossInc/wms-api/pull/194)).** After the #192 revert, the team requested this behavior again. `b9655bf` was cherry-picked onto current `develop` (no conflicts); `mvn clean compile` clean and `ReleaseOrderJobServiceUnitTest` **33/33** green. sbdocs artifacts restored to match: this plan (status → implemented), `wms1-sysprop-catalog.md` (`ENFORCE_PARTITIONALLOWED` row + log, 91→92), `wms1-picking-workflow.md` (§4 note + log), and the verify script. Lifecycle: #191 (implement) → #192 (revert) → #194 (reinstate).

**Implemented 2026-07-08.**

- **Branch / commit / PR:** `fix/SBDEV-2512-partitionallowed-split-pick` @ `b9655bf` → PR [#191](https://github.com/SiteBossInc/wms-api/pull/191) into `develop`.
- **Code changes (v1/wms-api):**
  - `service/WmsConstants.java` — added `SYSTEM_PROPERTY_ENFORCE_PARTITIONALLOWED_KEY = "ENFORCE_PARTITIONALLOWED"`.
  - `service/job/ReleaseOrderJobService.java` — injected `LosSyspropRepository`; read `enforcePartitionGuard` once before phase 2 (default ON via `!"false".equalsIgnoreCase(findSysvalueBySyskey(...))`); per-order `remainingNetByItemData` ledger; **Fix A** cumulative phase-2 hold guard before `pickFromOverstock.add` (mandatory `LOG.info`); **Fix B** phase-3 single-covering-unit branch with failsafe `throw`; new private `reserveSingleCoveringUnit(...)`.
- **Tests:** `ReleaseOrderJobServiceUnitTest` — added AC-1..AC-6 (per §8); adjusted 3 pre-existing tests (`...multipleStockUnits_splitsPicking`, `...notEnoughStock_throwsException`, `...ThrowBusinessException_when*` × marked `partitionallowed=true`) + `@Mock LosSyspropRepository` + relaxed the hold-save verify to `atLeastOnce()` (mutable-argument pitfall). **`Tests run: 33, Failures: 0, Errors: 0`** (`mvn -o test -Dtest=ReleaseOrderJobServiceUnitTest`, Java 8). `mvn clean compile` clean.
- **Verify script:** `bash sbdocs/9-System/scripts/verify-SBDEV-2512-...sh` → **`Result: 12 pass, 0 fail, 0 skip`** (incl. the mvn behavioral gate running AC-5 + AC-6). Two stale checks in the script were corrected during impl: helper name `hasSingleUnitCovering` → `reserveSingleCoveringUnit` (A4), and test class `ReleaseOrderJobServiceTest` → `ReleaseOrderJobServiceUnitTest` (T1).
- **Review lane:** Planner → Architect (conditional-approve, C-3) → Critic (APPROVE) → `code-reviewer` (APPROVE, 0 Critical/High/Medium; 4 LOW pre-existing/intentional) → deslop (whitespace only) → post-deslop regression green.
- **Integration tests:** remain `@Disabled` (SBDEV-2384 `ro_id` view drift); acceptance rests on unit tests + `mvn clean compile` + manual smoke per §8.
- **Docs updated (sbdocs, not in git):** `data-dictionary/wms1-sysprop-catalog.md` (+`ENFORCE_PARTITIONALLOWED`, 91→92, log, `last_verified` 2026-07-08); `workflows/wms1-picking-workflow.md` (§4 SBDEV-2512 note, log, `last_verified` 2026-07-08). `wms1-state-machine-catalog.md` state 55 already documented (new trigger only — not re-dated).

### C-3 exposure (measured, WineCo prod, `db_verified: true`)

```sql
SELECT count(*) FROM (
  SELECT order_id, itemdata_id
  FROM   customerorder_position
  GROUP  BY order_id, itemdata_id
  HAVING count(*) > 1
) t;
-- 0   (of 479,265 orders)
```

**Zero present-day exposure** for the single-order multi-position-same-SKU path: WineCo's model creates one position per parcel/SKU, and BF173533 itself was two *separate* customerorders (one position each). The cumulative phase-2 hold (change #1) is therefore **defensive insurance with no mass-hold risk today**; the retained Fix B `throw` covers only the residual inter-order concurrency race (same exposure as the pre-existing `RuntimeException` @542).

### Resolved Decisions
- **Behavior (user choice):** a non-partitionable position that can't be filled from a single unit (including under prior same-order same-SKU admissions) → order **held** (state 55 → 50), not fragmented, not hard-errored. **LosSysprop kill-switch (default ON)** is the ops escape hatch.
- **Cumulative Fix A (rev 3, C-3):** phase-2 simulates the single-unit reservation per SKU across the order so Fix B's `throw` is unreachable for the single-order path. Zero WineCo exposure today (above), but it prevents the permanently-stuck-order failure mode structurally.
- **Two-part fix (rev 2):** phase-2 hold (Fix A) is necessary but insufficient (gross-DESC/net divergence); phase-3 single-pick (Fix B) required.
- **Candidate selection:** FIRST covering candidate in gross-DESC order (deterministic); smallest-covering noted, not shipped.
- **Failsafe message (S-4):** keep the literal `BusinessException` message despite the `"placeholder, '…'"` mangled render; do **not** add a message-properties key (keeps the diff to one file); verify B2 greps a stable substring.
- **State constant:** `RAW_ON_HOLD_NOT_ENOUGH_STOCK_ON_LOCATION` (55), preferred over the adjacent `56`.

### Implementer notes (non-blocking residuals from Critic APPROVE — resolve during TDD/implementation)
- **AC-6 stub mechanics (Mockito 3.3.3):** with cumulative Fix A the order is held in phase-2, so phase-3 is never reached and `getStockUnitsByItemDataId` is queried once. The §8 note's "reduced second candidate list" stub is therefore unused in rev-3 — wrap it in `lenient()` (or omit it) to avoid `UnnecessaryStubbingException`. `changeReservedAmount` is a no-op mock, so if any test *does* reach phase-3, stub `getStockUnitsByItemDataId` with consecutive returns to reflect the reservation.
- **`findSysvalueBySyskey` return type:** the kill-switch snippet assumes a bare nullable `String`. Confirm at implement time; if it returns `Optional<String>`, adapt with `.orElse(null)` before `!"false".equalsIgnoreCase(...)`.

### Open Questions
- **S-3 (pre-existing assumption, out of scope):** is `Stockunit.getAvailableamount()` (used @411 in the fixed-assignment branch) equivalent to `amount − reservedamount` (phase-3 + helper) under all lock/reservation states? Fix A/Fix B use `amount − reservedamount` to match phase-3 exactly; a divergence would be a separate latent issue in the fixed-assignment branch (§0 row 3).
- **v1↔v2:** confirm whether v2's release path has the same gross-DESC/net split gap and the same-SKU multi-position exposure; pair a v2 plan if so.

---

## Completeness checklist (Layer 2)

| # | Concern | Considered? |
|---|---|---|
| 0 | **DB verified** | ✓ §1 — fragmentation (9/2/1 → T-0155, PICK272768) + both siblings `partitionallowed=false`; §10 — C-3 exposure query (0 of 479,265); `db_verified: true`. |
| 1 | **All callsites enumerated** | ✓ §0 rows 1–9; **both** fix loci EDITED (Fix A @245 cumulative, Fix B @487-538); rows 3–9 excluded/documented. |
| 2 | **Adjacent bugs** | ✓ §0 — `fixPickingPosition` (row 5) already single-unit-safe; row 9 (gross-DESC sort + re-query filter) documented as the divergence + C-3 cause; S-3 flags a possible `getAvailableamount()` mismatch (out of scope). |
| 3 | **Backward compatibility** | ✓ §5 matrix — partitionable + single-unit paths unchanged; only fragment/throw-a-non-partitionable changes (to hold or single-pick). No API/DTO/schema/error-shape change. |
| 4 | **Concurrency** | ✓ §2 + §9 — order lock (`findByIdForUpdate` @80) in `REQUIRES_NEW`; cumulative Fix A prevents the single-order same-SKU stuck-throw (C-3); the residual inter-order race fails safe (rollback + retry, same as pre-existing `RuntimeException` @542). AC-6 pins the single-order path. |
| 5 | **Multi-tenant** | ✓ no — tenant-scoped repo calls in the routed datasource; sysprop is per-tenant (`LosSysprop`); no cross-tenant query. |
| 6 | **Error handling** | ✓ §5 — Fix A uses state-set + `continue` (existing hold gate); Fix B's `throw` is a failsafe (unreachable single-order; safe rollback inter-order); S-4 documents the message render. |
| 7 | **Observability** | ✓ **mandatory** §7.1 row 8 / step 3 — Fix A hold `LOG.info` (itemdataId/SKU, amount, position id, order id, reason). |
| 8 | **Rollback / migration** | ✓ §9 — **LosSysprop kill-switch (default ON)** reverts without redeploy; no Flyway/backfill; seed one sysprop row (§7.1 row 2). |
| 9 | **Test coverage** | ✓ §8 — AC-1..AC-6 (AC-5 divergence, AC-6 C-3 cumulative-hold) in `ReleaseOrderJobServiceTest` + manual M1–M7; IT gated `@Disabled` TODO(SBDEV-2384). |
| 10 | **Cross-version (v1↔v2)** | ✓ no — v1-only; v2 release path evaluated separately (§10 open question, §9 scalability N/A). |

**v2 Horizontal Scalability Validation:** N/A — v1-only plan (v2 release path evaluated separately).
**v2-only constraint checklist:** N/A — v1-only plan (no jakarta / tenantTransactionManager / Caffeine / H2 concerns apply).

---

## Acceptance

Machine-checkable script: `sbdocs/9-System/scripts/verify-SBDEV-2512-partitionallowed-split-pick-overstock-guard.sh`
Run: `bash sbdocs/9-System/scripts/verify-SBDEV-2512-partitionallowed-split-pick-overstock-guard.sh` — acceptance = `Result: N pass, 0 fail`.

The script encodes all three fixes so a weaker implementation cannot pass: the `reserveSingleCoveringUnit` cumulative helper present and querying `getStockUnitsByItemDataId`; the guard combines `getPartitionallowed` + `reserveSingleCoveringUnit` and sets state 55 (Fix A); `getPartitionallowed()` read **≥2×** (phase-2 + phase-3) proving Fix B is in the loop; the `SYSTEM_PROPERTY_ENFORCE_PARTITIONALLOWED_KEY` kill-switch wired; and `mvn test -Dtest=ReleaseOrderJobServiceTest` (including **AC-5** divergence and **AC-6** C-3 cumulative-hold) passes as the behavioral gate.
