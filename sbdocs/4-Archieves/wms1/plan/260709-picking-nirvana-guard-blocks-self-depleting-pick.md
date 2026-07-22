---
title: "Picking nirvana pick-line guard blocks a legitimate self-depleting pick (confirmPick nulls the completing line's pickfromstockunit_id too late)"
ticket: ""
ticket_url: ""
type: bugfix
priority: high
status: archived
project: [wms1]
version: v1
requester: "Nam Park"
created: 2026-07-09
updated: "2026-07-15"
db_verified: true
related:
  - "[[SBDEV-2512-partitionallowed-split-pick-overstock-guard]]"
  - "[[wms1-picking-workflow]]"
  - "[[wms1-stockunit-design]]"
  - "[[wms1-transaction-boundary-map]]"
tags:
  - plan
  - picking
  - stockunit
  - nirvana
  - SBDEV-2481
---

# Picking nirvana pick-line guard blocks a legitimate self-depleting pick

**Project:** wms1 | **Version:** v1 | **Type:** bugfix
**Priority:** high
**Status:** implemented (Architect + Critic + code-review APPROVE, 2026-07-09 — see §10)
**Date:** 2026-07-09
**DB-verified:** yes (live incident PICK227210 on `wms1-wineco-dev`)

> **Section order note.** This plan uses the §0..§10 layout requested for this
> defect (affected-site enumeration first, then problem → root cause → regression
> → architecture → fix → files → steps → tests → risks → status). The frontmatter
> follows `sbdocs/9-System/templates/wms-plan-template.md`.

---

## §0. Affected Sites Enumeration

The only file that changes is **`PickingorderBusinessService.confirmPick`**. The
send-to-nirvana guard in `StockunitBusinessService` is documented here as *context*
(it is the code that throws) but is **not** modified — the fix corrects the caller's
FK-nulling order so the guard sees the correct world.

Enumeration was produced by grepping every caller of the four symbols in the failure
chain and classifying each as in- or out-of-scope.

### Fix locus (IN SCOPE)

| Site | File:line | Role | Change |
|------|-----------|------|--------|
| confirmPick | `service/PickingorderBusinessService.java:306,308` | Nulls the completing pick line's `pickfromstockunit_id` **after** the transfer | **Move the null + save to before the transfer call at :290** |

### Guard site (CONTEXT — documented, NOT changed)

| Site | File:line | Role |
|------|-----------|------|
| sendStockUnitToNirvana guard | `service/StockunitBusinessService.java:323-324` | SBDEV-2481 guard: throws `ACTIVE_PICK_MESSAGE` if ANY pick line still references the stock unit being sent to nirvana |
| transferStockToUnitLoad branch B | `service/StockunitBusinessService.java:262-286` | Depletes source, then at :276-277 calls `sendStockUnitToNirvana` when `fixLocationAssignment == null && sourceAmount == 0` |

### Callers of `sendStockUnitToNirvana` (OUT OF SCOPE — none changed)

| Caller | File:line | Activity code | In scope? | Rationale |
|--------|-----------|---------------|-----------|-----------|
| transferStockToUnitLoad (self) | `StockunitBusinessService.java:277` | passthrough (caller's code) | No | The guard itself is not touched; behavior preserved. |
| FixLocationAssignmentService | `FixLocationAssignmentService.java:264` | `CODE_DELETE_FIX_ASSIGNMENT` | No | External fix-assignment delete — guard SHOULD block if a pick line is live. |
| UnitloadService | `UnitloadService.java:329` | `CODE_MANUAL_REMOVAL` | No | Manual removal — guard SHOULD block. |
| GoodsReceiptPositionService | `GoodsReceiptPositionService.java:161` | `STOCK_REMOVED` | No | Receiving reversal — guard SHOULD block. |
| MobileCycleCountService | `MobileCycleCountService.java:211,439` | `CODE_CYCLE_COUNT` | No | Cycle-count zeroing — guard SHOULD block. |

### Callers of `transferStockToUnitLoad` (OUT OF SCOPE — none changed)

25 call-sites across `MobileMoveUnitloadService`, `MobileTransferOrderService` (×3),
`CustomerorderBatchService` (×3, `CODE_PACKAGING_CLUB` activity code), `MobileReplenishService`,
`MobilePutAwayService`, `StockunitService` (×7), `CustomerorderService`,
`BillofladingService`, `MobileMoveStockService` (×3), and `PickingorderBusinessService:290`.
Only the `PickingorderBusinessService:290` path is on the failing chain; none of the
others null a pick-line FK around the call, so the ordering fix is confined to `confirmPick`.

#### Representative affected-path inventory — reachability to the `:323` nirvana guard (context only, NOT in scope)

Every caller below can, in principle, reach `sendStockUnitToNirvana:323` on full
depletion of a source stock unit that a `PickingorderPosition` still references — the
guard fires from `transferStockToUnitLoad`'s branch-B path (`fixLocationAssignment ==
null && sourceAmount == 0`, :276-277) independent of which higher-level workflow called
it. **Multiple unit loads is the common trigger** in practice (single-UL flows rarely
land on exact depletion of a shared, still-referenced unit). None of these are changed
by this plan; only `PickingorderBusinessService.confirmPick` (Fix A) ships now.

| Caller | File:line | Activity code |
|--------|-----------|----------------|
| confirmPick | `PickingorderBusinessService.java:290` | `CODE_PICKING` (**fix locus — Fix A ships**) |
| finishReplenishmentOrderInternal | `MobileReplenishService.java:473` | `CODE_REPLENISHMENT` (reaches guard in principle; the reported replen failure `RR19CHGM` was a **different** issue — #193 availability rejection, not this guard — see §1 "Related report — RESOLVED") |
| Put-away (flowbin) | `MobilePutAwayService.java:463` | `CODE_PUT_AWAY` |
| Manual split / damaged (×7) | `StockunitService.java:135,139,177,213,219,231,388` | `CODE_MANUAL_SPLIT` / `CODE_DAMAGED` |
| Manual move stock (×3) | `MobileMoveStockService.java:272,328,333` | `CODE_MANUAL_SPLIT` |
| Transfer-order fulfillment (×3) | `MobileTransferOrderService.java:322,328,333` | `CODE_MANUAL_SPLIT` |
| Packaging | `CustomerorderService.java:471` | `CODE_PACKAGING` |
| Packaging — club batch (×3) | `CustomerorderBatchService.java:666,679,684` | `CODE_PACKAGING_CLUB` |
| BOL parcel processing | `BillofladingService.java:992` | (BOL close activity code) |

> Note: `removeUnitLoadIfEmpty` only gates the *subsequent* empty-unit-load cleanup
> (`unitloadBusinessService.sendToNirvana`, :279-284) — the stock-unit-level guard at
> `:323` fires independent of that flag, from the `fixLocationAssignment == null &&
> sourceAmount == 0` branch alone. This inventory is therefore representative, not an
> exhaustive proof of reachability; the full 25-site caller list is above.

### Callers of `confirmPick` (CONTEXT)

| Caller | File:line | In scope? |
|--------|-----------|-----------|
| MobilePickingService.processPick | `MobilePickingService.java:483` | No (caller unchanged; the fix is inside confirmPick) |
| MobilePickingService (batch confirm) | `MobilePickingService.java:985` | No |

### Callers of `findByPickfromstockunitId` (CONTEXT — the guard reads this)

`PickLineRealignmentService:78,91,114` (realign paths), `StockunitBusinessService:323`
(the guard), `MobileInfoService:373` (read-only info). None changed; the fix ensures
the guard's query no longer returns the line that `confirmPick` is completing.

**§0 in-scope row count: 1** (`confirmPick`, one ordering move of two statements).

---

## §1. Problem Statement

During multi-pick (fragmented) picking, confirming the pick that **fully depletes its
own source stock unit** fails with HTTP 500 carrying the message:

> "This stock is currently tied to active picking work. Please wait till picking is
> complete before moving this stock or changing its fixed assignment."

(`PickLineRealignmentService.ACTIVE_PICK_MESSAGE`, thrown as a `BusinessException`;
`RestExceptionHandler` surfaces it to the mobile client.)

The paradox: the operator *is* the one completing the pick, yet the system reports the
stock as tied to active picking work and refuses the confirmation. A partial pick
against the same order (one that does NOT zero its source) succeeds; only the depleting
pick throws.

### DB-verified incident: PICK227210 (`wms1-wineco-dev`)

Picking order id **27149025**, stuck pick line **757052**. This is a regular
**PICK_PACK** batch (customerorder_batch **27149021**, batch number **051676**,
`type = PICK_PACK`), customerorder **27149022** (`051676-000001`) — **NOT** a club run.
("Club01" below is only the *name* of the source physical location, not the order type.)

- Customer-order position (cop) **27149023**: amount 3, `partitionallowed = false`.
  **Fragmented 2+1 across two unit loads** by a non-overstock release path into two pick lines:
  - **757051** — amount 2, from UL317399 — already **PICKED** (state 600, `pickfromstockunit_id` nulled).
  - **757052** — amount 1, from UL317400 — stuck at **state 300** (PROCESSABLE).
- Pickingorder 27149025 is in state **500 (STARTED)**.
- Source stock unit **27148499**: amount 1, reservedamount 1, location **Club01**
  (location id 225748), itemdata 589066931.
- **No** `fix_location_assignment` row for location 225748.

Released **2026-07-09 ~08:47** while SBDEV-2512 was **ON**, yet the non-partitionable
position was fragmented (not single-picked and not held) — which proves it did **not**
pass through SBDEV-2512's overstock phase-3 guard. So SBDEV-2512 is confirmed not the
trigger, and is not even the release branch that created this 2+1 structure (see §10
Open Questions).

Because 757052 still references stock unit 27148499 (its `pickfromstockunit_id`), the
depleting pick can never complete: the guard sees a live pick line on the very unit
being emptied and throws. The pick line is wedged.

> The diagnostic SQL used to establish these facts is in **Appendix A**.

### Related report — RESOLVED as a DIFFERENT, non-bug behavior (multi-UL replenishment)

The tester separately reported a multi-UL **replenishment** failure and described it as "the
same error." **DB verification (2026-07-09) shows it is NOT this bug** — it is a *different*,
similar-sounding message. Attempt `RR19CHGM` (source `64-XJ03`, dest `19-B05`) selected
ULs **UL286408** (stock 917146634) and **UL286409** (stock 917146635), each **fully reserved
(available 0)** as the committed source of another open replen (**REPL051911**, **REPL051914**,
both state 300). The verbatim message was **"Unit load stock is already reserved (0.0000
available). Choose a different unit load."** — i.e. `MsgUnitLoadStockAlreadyReserved` from the
SBDEV replen availability guard (plan `260709-multi-unitload-replen-reserve-availability-guard`,
PR #193), **working as designed**, NOT `ACTIVE_PICK_MESSAGE`.

Decisive discriminator: **none** of the involved source/destination stock units (917146634,
917146635, 20895259, dest 925708777) has any `PickingorderPosition` referencing it
(`findByPickfromstockunit_id` empty), so the `sendStockUnitToNirvana:323` guard **cannot** be
the source of the replen message. The two failures are unrelated:
- **Picking** (`PICK227210`) — the real `ACTIVE_PICK_MESSAGE` bug this plan fixes.
- **Replenishment** (`RR19CHGM`) — #193 correctly refusing a UL already reserved by another
  open replen. Remediation is operational (select an unreserved UL, or clear REPL051911/051914),
  not a code fix. Any change here would be a *policy* decision on #193, out of scope for this plan.

This plan is therefore correctly scoped to the **picking** entry path only; `confirmPick`'s
Fix A is the complete fix for the confirmed defect. (Note: other `transferStockToUnitLoad`
callers in the §0 inventory could *in principle* reach the same guard if they ever deplete a
pick-referenced source, but none is a reported incident and none is in scope here.)

---

## §2. Root Cause

The failing chain (all line numbers verified against the working tree on 2026-07-09):

```
PickingController POST /v3/picking/processPick        controller/mobile/PickingController.java:281
  → MobilePickingService.processPick(...)             service/mobile/MobilePickingService.java:483
    → PickingorderBusinessService.confirmPick(...)    service/PickingorderBusinessService.java:223
```

Inside `confirmPick`:

1. **:275** `changeReservedAmount(stockUnit, -amount, true, CODE_PICKING, ...)`
   releases the reservation on 27148499 (reservedamount 1 → 0).
2. **:290** `transferStockToUnitLoad(stockUnit, puUnitLoad, amountPicked,
   CODE_PICKING, ..., ignoreLock=true, removeUnitLoadIfEmpty=true)`.
   Inside `transferStockToUnitLoad` (`StockunitBusinessService`):
   - **:224-225** `fixLocationAssignment = findByAssignedlocationId(sourceLocation.getId()).orElse(null)`
     → **null** for Club01 (no fla row).
   - The destination tote already holds the SKU (deposited by 757051), so
     `destinationStockUnit != null` → the code takes **branch B** at **:262**.
   - **:270-271** the source stock unit is decremented to amount 0.
   - **:276** `if (fixLocationAssignment == null && sourceAmount == 0)` → **true**
     → **:277** `sendStockUnitToNirvana(sourceStockunit, CODE_PICKING, ...)`.
   - Inside `sendStockUnitToNirvana`:
     - **:299** reservation check passes (reservedamount already 0).
     - **:323-324** the SBDEV-2481 pick-line guard:
       `if (!pickingorderPositionRepository.findByPickfromstockunitId(su.getId()).isEmpty()) throw new BusinessException(ACTIVE_PICK_MESSAGE);`
       → line **757052 STILL references** stock unit 27148499 → **throws**.
3. **:306** `pickingPosition.setPickfromstockunitId(null)` + **:308** save — this is
   where the completing line would be detached from the stock unit, but it runs
   **after** the transfer that already threw. Too late.

**Root defect:** `confirmPick` nulls the completing pick line's `pickfromstockunit_id`
*after* `transferStockToUnitLoad` (line 306 vs. the transfer at 290). When the transfer
depletes the source and sends it to nirvana, the SBDEV-2481 guard queries
`findByPickfromstockunitId` and finds the line currently being completed still pointing
at the unit — so it treats a legitimate self-depleting pick as an external move that
would orphan a pick line, and blocks it.

The guard's genuine purpose — preventing an *external* move / nirvana that would strand
some *other* pick line — is correct and must be preserved. The bug is purely the caller's
statement ordering: the completing line must be detached before the transfer runs.

---

## §3. Regression Chain

| When | Change | Effect |
|------|--------|--------|
| pre-existing | `confirmPick` nulls `pickfromstockunit_id` after the transfer (original checkin ordering) | Latent — harmless until something read the FK mid-transfer. |
| 2026-06-24 | **commit `7c47a2b`** `fix(picking): realign/block stale pick lines on stock & unit-load moves (SBDEV-2481)` — added the `sendStockUnitToNirvana` guard at `StockunitBusinessService:323-324` | Guard now reads `findByPickfromstockunitId` mid-transfer; the latent ordering bug becomes an active 500 for self-depleting picks. |

**SBDEV-2512 is explicitly NOT the trigger for this incident.** SBDEV-2512
(`partitionallowed=false` overstock release) governs the *overstock-release* fragmentation
path and its `ENFORCE_PARTITIONALLOWED` kill-switch. PICK227210 was released on
**2026-07-09 ~08:47 while SBDEV-2512 was ON**, yet its non-partitionable position (cop
27149023) was fragmented 2+1 across two unit loads — proving it did **not** pass through
SBDEV-2512's overstock phase-3 guard (which would have single-picked or held it). The
2+1 structure was created by a **different, non-overstock release branch** in a
PICK_PACK order. So SBDEV-2512 is neither the trigger for the 500 nor the path that
created the fragmentation, and its kill-switch does **not** fix this defect. (Why a
non-partitionable position was fragmented at all is a *separate* potential gap — see §10
Open Questions — not the bug this plan fixes.)

That said, any shared-unit scenario — including SBDEV-2512's overstock case — can reach
the **same guard**: whenever a pick fully depletes a source unit that another
(already-completed) pick line also drew from, the guard fires unless the completing
line's FK is nulled first. The fix in this plan is guard/ordering-side and therefore
closes **both** the fragmented-position self-deplete case seen here *and* any shared-unit
overstock case. (See §10 Open Questions for the deploy-timing caveat.)

---

## §4. Architecture Overview

### Failure flow (current, buggy ordering)

```
confirmPick(pickingPosition 757052, tote, amount=1)
  :275  changeReservedAmount(SU 27148499, -1)      reserved 1 → 0
  :290  transferStockToUnitLoad(SU 27148499 → tote, 1, ignoreLock, removeIfEmpty)
          :224  fla = findByAssignedlocationId(Club01) → null
          :262  destinationStockUnit != null  → BRANCH B
          :270  source amount 1 → 0
          :276  fla==null && amount==0  → true
          :277  sendStockUnitToNirvana(SU 27148499)
                  :299  reserved==0  → OK
                  :323  findByPickfromstockunitId(27148499) = [757052]  ← STILL SET
                  :324  throw BusinessException(ACTIVE_PICK_MESSAGE)     ← 500
  :306  pickingPosition.setPickfromstockunitId(null)   ← NEVER REACHED
```

### Fixed flow (Fix A — null the FK before the transfer)

```
confirmPick(pickingPosition 757052, tote, amount=1)
  :275  changeReservedAmount(SU 27148499, -1)      reserved 1 → 0
  NEW   pickingPosition.setPickfromstockunitId(null); save()   ← detach completing line
  :290  transferStockToUnitLoad(SU 27148499 → tote, 1, ...)
          ... :277  sendStockUnitToNirvana(SU 27148499)
                  :323  findByPickfromstockunitId(27148499) = []   ← EMPTY → guard passes
  :306  (state/amountpicked/picktounitload/operator still set here; FK already null)
```

Guard purpose preserved: any *other* pick line still referencing the unit keeps
`findByPickfromstockunitId` non-empty → external moves still block.

### Key files

| File | Symbol | Line(s) | Role |
|------|--------|---------|------|
| `controller/mobile/PickingController.java` | `processPick` | 281 | REST entry `/v3/picking/processPick` |
| `service/mobile/MobilePickingService.java` | `processPick` → `confirmPick` | 483 | Orchestrates a single pick confirmation |
| `service/PickingorderBusinessService.java` | `confirmPick` | 223-308 | **FIX LOCUS** — statement ordering |
| `service/StockunitBusinessService.java` | `transferStockToUnitLoad` | 132-290 | Depletes source, branch B, calls nirvana |
| `service/StockunitBusinessService.java` | `sendStockUnitToNirvana` | 298-331 | **Guard site** (:323-324) — not changed |
| `service/PickLineRealignmentService.java` | `ACTIVE_PICK_MESSAGE` | 46-48 | Message constant |
| `repo/jpa/PickingorderPositionRepository.java` | `findByPickfromstockunitId` | 22-23 | Query the guard uses |

---

## §5. Fix Design

### Fix A — recommended (minimal, ordering-only)

In `PickingorderBusinessService.confirmPick`, move
`pickingPosition.setPickfromstockunitId(null)` **and its save** so the completing pick
line is detached from its source stock unit **before** `transferStockToUnitLoad` runs.

**Before** (`PickingorderBusinessService.java`, current):

```java
        Unitload puUnitLoad = unitloadRepository.findById(pickingUnitLoad.getUnitloadId())
            .orElseThrow(() -> new BusinessException("Unit load not found: " + pickingUnitLoad.getUnitloadId()));
        Stockunit pickToStock = stockunitBusinessService.transferStockToUnitLoad(stockUnit, puUnitLoad, amountPicked, WmsConstants.CODE_PICKING, pickingPosition.getNumber(), null, true, true);   // :290

        // ... pallet-empty handling, pickToStock lock/save ...

        pickingPosition.setState(WmsConstants.State.PICKED);
        pickingPosition.setPicktounitloadId(pickingUnitLoad.getId());
        pickingPosition.setAmountpicked(amountPicked);
        pickingPosition.setPickfromstockunitId(null);   // :306  ← too late
        pickingPosition.setPickedbyoperatorId(user.getId());
        pickingorderPositionRepository.save(pickingPosition);   // :308
```

**After** (Fix A):

```java
        Unitload puUnitLoad = unitloadRepository.findById(pickingUnitLoad.getUnitloadId())
            .orElseThrow(() -> new BusinessException("Unit load not found: " + pickingUnitLoad.getUnitloadId()));

        // SBDEV-2481 interaction fix: detach THIS pick line from its source stock unit
        // BEFORE the transfer. transferStockToUnitLoad may deplete the source and call
        // sendStockUnitToNirvana, whose guard (StockunitBusinessService:323) throws
        // ACTIVE_PICK_MESSAGE if ANY pick line still references the unit. The line we
        // are completing must not count against that guard; OTHER pick lines still do.
        // confirmPick is @Transactional(rollbackFor={BusinessException,FacadeException}),
        // so if the transfer throws, this null is rolled back with the rest of the tx.
        // Plain save() (these repos extend PagingAndSortingRepository, NOT JpaRepository —
        // saveAndFlush is unavailable and unused anywhere in the codebase). The detach
        // reaches the DB before the in-transfer guard SELECT because Hibernate's default
        // FlushMode.AUTO auto-flushes the pending pickingorder_position update before the
        // guard's findByPickfromstockunitId query on the same table runs.
        //
        // Capture the MANAGED instance returned by save() and drive all later mutations
        // through it. On the rapid-picking path pickingPosition arrives DETACHED (deserialized
        // from the request body, never re-read), so the transfer's autoflush bumps the managed
        // row's @Version; re-saving the stale detached copy afterward would throw
        // ObjectOptimisticLockingFailureException (the same mode MobilePickingService:466-469
        // already defends processPick against). pickingPosition itself is NOT reassigned — it
        // stays effectively final for the orElseThrow lambdas after this point.
        pickingPosition.setPickfromstockunitId(null);
        PickingorderPosition managedPickLine = pickingorderPositionRepository.save(pickingPosition);

        Stockunit pickToStock = stockunitBusinessService.transferStockToUnitLoad(stockUnit, puUnitLoad, amountPicked, WmsConstants.CODE_PICKING, pickingPosition.getNumber(), null, true, true);

        // ... pallet-empty handling, pickToStock lock/save (unchanged) ...

        managedPickLine.setState(WmsConstants.State.PICKED);
        managedPickLine.setPicktounitloadId(pickingUnitLoad.getId());
        managedPickLine.setAmountpicked(amountPicked);
        managedPickLine.setPickedbyoperatorId(user.getId());
        pickingorderPositionRepository.save(managedPickLine);
```

**Why this is safe:**

- `transferStockToUnitLoad` operates on the **`Stockunit`** (`stockUnit` local var) and
  the destination `Unitload` — it never reads `pickingPosition.getPickfromstockunitId()`.
  Nulling the position FK first does not change any input to the transfer.
- The local `stockUnit` reference (bound at :268/:275) is retained and passed to the
  transfer, so detaching the position does not lose the pointer.
- `pickingPosition.getNumber()` (passed as `orderNumber` to the transfer) is unchanged
  by the null.
- `confirmPick` is `@Transactional(rollbackFor = {BusinessException.class,
  FacadeException.class})`. If `transferStockToUnitLoad` throws for any *other* reason
  (e.g. mixed-stock, lock), the early null-and-save is rolled back — no orphaned line.
- Guard purpose intact: only the *completing* line's FK is cleared early. Any sibling
  line still referencing the same unit keeps the guard non-empty, so external
  moves/nirvana still block.
- Covers BOTH incident shapes: by the time a depleting pick runs, sibling lines drawing
  from the same unit are already picked (FK nulled) or are the current line (now nulled
  first), so the guard sees an empty list for a legitimate completion.
- **Branch B is the only guard-reachable path from `confirmPick`.** `confirmPick` always
  passes `CODE_PICKING`, which `PickLineActivityCodeClassifier` classifies as
  `PASS_THROUGH` (`:65`), so `transferStockToUnitLoad`'s branch A never calls
  `realignForMovedStockUnit` and never reaches the guard for picking. The guard is hit
  only via branch B's `sendStockUnitToNirvana` (`:277`), which Fix A's early detach
  clears. So the single-point fix is complete for all `confirmPick` paths.
- **Insertion point precision:** the null+save must go *after* `stockUnit` is loaded from
  the FK (`:268`, then rebound at `:275`) and *before* the transfer (`:290`) — i.e.
  strictly between `:288` and `:290`. Placing it before `:268` would break `stockUnit`
  loading.

### Fix B — alternative (rejected unless Fix A has a hole)

Thread `pickingPosition.getId()` (or the stock-unit-to-exclude) into
`sendStockUnitToNirvana` so its guard excludes the line being completed:

```java
if (!pickingorderPositionRepository
        .findByPickfromstockunitId(stockUnit.getId())
        .stream().anyMatch(pp -> !pp.getId().equals(excludePickLineId))) { ... }
```

Rejected as the primary approach because it requires a **signature change** propagated
through `transferStockToUnitLoad` (which has 25 call-sites) down into
`sendStockUnitToNirvana`, plus a new overload or a nullable "exclude" parameter on a
shared low-level method. Higher blast radius for no additional correctness over Fix A.
Keep as fallback only if a reviewer finds a case where nulling the FK early breaks a
downstream read (none found in this analysis).

### Durable cross-path fix — NOT needed (replen manifestation resolved as a different issue)

A **guard-side generalization** — excluding the pick line(s) legitimately being
consumed by the current operation, threaded as a parameter through
`transferStockToUnitLoad → sendStockUnitToNirvana` — would widen Fix B's shape to every
caller in the affected-path inventory (§0, ~25 call sites). **It is NOT needed for the
confirmed scope.** The only reported non-picking manifestation (the multi-UL replen
`RR19CHGM`) was DB-verified to be a *different* behavior — #193's `MsgUnitLoadStockAlreadyReserved`
availability rejection, not this guard (§1 "Related report — RESOLVED"). No other caller in
the inventory has a reported incident. So `confirmPick` Fix A is the complete fix for the
confirmed defect; the guard-side generalization is recorded only as a *possible* future
hardening if another entry path is ever shown to hit the guard on a self-consumed line —
not part of this plan.

Separately: **Option C — narrow the guard to only block ACTIVE pick lines** (owning
order state ≥ `STARTED`, matching `PickLineRealignmentService.assertNoActivePickFor`'s
semantics) — is **insufficient for the picking case** and is not a substitute for Fix A.
PICK227210's own pickingorder (27149025) is already in state **500 (STARTED)** at the
moment the guard fires, so narrowing the guard to "ACTIVE only" would still see the
completing line as active and still block it. Option C does not fix this incident.

---

## §6. File Change Summary

| File | Change | Lines |
|------|--------|-------|
| `src/main/java/net/aim_ai/wms/service/PickingorderBusinessService.java` | Move `setPickfromstockunitId(null)` + save from after the transfer (:306/:308) to immediately before the `transferStockToUnitLoad` call (:290); add explanatory comment | ~ +6 / -1 net |

No repository, entity, migration, controller, or config changes.

---

## §7. Implementation Steps

1. Edit `PickingorderBusinessService.confirmPick`: insert
   `pickingPosition.setPickfromstockunitId(null); pickingorderPositionRepository.save(pickingPosition);`
   (do **not** reassign `pickingPosition` from `save()` — it is referenced in later
   `orElseThrow` lambdas so it must stay effectively final; the pre-existing post-transfer
   save of the same instance is also non-reassigning)
   **strictly between `:288` and the `transferStockToUnitLoad` call at `:290`** (after
   `stockUnit` is loaded from the FK at `:268`/rebound at `:275`), with the explanatory
   comment from §5. Plain `save` (the repo extends `PagingAndSortingRepository`, so
   `saveAndFlush` is unavailable); Hibernate `FlushMode.AUTO` flushes the detach before the
   in-transfer guard query on `pickingorder_position`.
2. Remove the now-redundant `pickingPosition.setPickfromstockunitId(null)` from the
   post-transfer block (formerly :306). Keep the remaining
   `setState`/`setPicktounitloadId`/`setAmountpicked`/`setPickedbyoperatorId` + save.
3. Add unit tests (§8).
4. `mvn test -Dtest=PickingorderBusinessServiceUnitTest`.
5. `mvn clean package -DskipTests -Dmaven.javadoc.skip=true` (compile sanity).
6. Run `bash sbdocs/9-System/scripts/verify-260709-picking-nirvana-guard-blocks-self-depleting-pick.sh`.

### §7.1 Prerequisites

| # | Prerequisite | Required value / action | Notes |
|---|---|---|---|
| 1 | Database state | **N/A** | Pure code-ordering fix; no schema/seed/Flyway change. |
| 2 | Feature flags / system properties | **N/A** | `ENFORCE_PARTITIONALLOWED` (SBDEV-2512) is **unrelated** and must NOT be relied on to fix this. |
| 3 | Config / env | **N/A** | No properties change. |
| 4 | Deploy-order | **N/A** | wms-api only; no cross-service ordering. |
| 5 | Data migration | See §10 — already-stuck parcels (e.g. PICK227210) may need a one-off `pickfromstockunit_id` handling; open question. |
| 6 | External systems | **N/A** | |
| 7 | Access / permissions | **N/A** | |
| 8 | Monitoring | Optional: watch for `ACTIVE_PICK_MESSAGE` 500s during `/v3/picking/processPick` after deploy. |

---

## §8. Testing Plan

### Unit — `PickingorderBusinessServiceUnitTest` (Mockito 3.3.3, no `mockStatic`)

Set the authenticated user via `SecurityContextHolder` directly (per CLAUDE.md; there is
already a pattern in this test class). Compare entities by ID, not `.equals()`.

| Test method | What it asserts |
|-------------|-----------------|
| `confirmPick_selfDepletingPick_nullsFkBeforeNirvanaGuard_succeeds` | Arrange a pick line whose source stock unit will be fully depleted (destination tote already holds the SKU, no fla). Use an `InOrder` (or a `doAnswer` on `transferStockToUnitLoad` that asserts `pickingorderPositionRepository.save(...)` with a null `pickfromstockunitId` was already invoked) to prove the FK is nulled **before** the transfer. Assert `confirmPick` returns normally and does **NOT** throw `ACTIVE_PICK_MESSAGE`. |
| `confirmPick_transferThrows_rollsBackEarlyNull` (optional) | Stub `transferStockToUnitLoad` to throw `BusinessException`; assert `confirmPick` propagates it (rollback is container-managed — the test documents that the early null is inside the tx boundary). |
| Guard-preservation test in `StockunitBusinessServiceUnitTest` | `sendStockUnitToNirvana` with a stock unit that STILL has an OTHER active pick line (`findByPickfromstockunitId` returns a non-empty list) throws `BusinessException(ACTIVE_PICK_MESSAGE)`. Proves the ordering fix does not weaken the guard for external moves. |

Ordering assertion approach (Mockito 3.3.3) — **use a `doAnswer` call-time snapshot as the
primary assertion.** `PickingorderPosition` mutates in place and Mockito holds the
reference, not a copy, so an `argThat(pp -> pp.getPickfromstockunitId() == null)` matches
the *end* state (both saves end null) — it proves call *ordering* but not that the FK was
null *at the moment the transfer ran*. Snapshot it instead:
```java
final Long[] fkAtTransfer = new Long[1];
doAnswer(inv -> { fkAtTransfer[0] = pickingPosition.getPickfromstockunitId(); return pickToStock; })
    .when(stockunitBusinessService).transferStockToUnitLoad(any(), any(), any(), any(), any(), any(), anyBoolean(), anyBoolean());
// ... call confirmPick ...
assertThat(fkAtTransfer[0]).isNull();   // FK was already detached when the transfer ran
```
Keep an `InOrder` (saveAndFlush → transfer) as a secondary check.

**Coverage boundary (disclose in the DONE report):** the `confirmPick` unit test proves
the *ordering / call-time detach* only — `transferStockToUnitLoad` is mocked, so it does
NOT exercise the real nirvana guard end-to-end. The end-to-end "guard passes when the FK
is nulled first, still blocks an OTHER line" behavior is proven by (a) the separate
`StockunitBusinessServiceUnitTest` guard-preservation test and (b) the §8 manual staging
scenario. The full `@SpringBootTest` IT is `@Disabled` (SBDEV-2384). The manual Pass/Fail
rows below MUST be filled before any DONE claim.

### Integration tests

`@Disabled` per the known v1 IT harness blocker (SBDEV-2384 — `ro_id` view drift blocks
all `@SpringBootTest` context loads). Add a `TODO(SBDEV-2384)` on any new IT.

### Manual test plan

| Scenario | Environment | Steps | Expected Result | Pass/Fail |
|---|---|---|---|---|
| Reproduce PICK227210 shape | staging | In a PICK_PACK batch, arrange a cop of amount N fragmented across ≥2 stock units (2+1), where the 2nd pick line fully depletes a 1-unit source, the SKU is already in the tote from line 1, and the source location has no fix-location-assignment. Confirm line 1 (partial), then confirm the depleting line 2. | Both picks confirm; no `ACTIVE_PICK_MESSAGE`; source stock unit sent to nirvana; pick line reaches state 600. | |
| Partial pick regression | staging | Confirm a pick whose source is NOT zeroed. | Succeeds as before. | |
| External move still blocked | staging | With a live (state<600) pick line on stock unit X, attempt a manual move/removal of X (e.g. MoveStock / delete-fix-assignment). | Blocked with `ACTIVE_PICK_MESSAGE` (guard preserved). | |
| SQL sanity — no newly-stuck parcels | staging DB | Run Appendix B query after a picking session. | Empty result. | |

### Test execution (fill in after running)

| Command | Result | Pass / Fail / Skipped |
|---------|--------|-----------------------|
| `mvn test -Dtest=PickingorderBusinessServiceUnitTest` | | |
| `mvn test -Dtest=StockunitBusinessServiceUnitTest` | | |

---

## §9. Risks & Mitigations

| Risk | Likelihood | Mitigation |
|------|-----------|------------|
| Nulling the FK early loses the stock-unit pointer needed by the transfer | Low | Transfer uses the `stockUnit` local (bound :268/:275), not the position FK. Verified in §5. |
| Some downstream code between :290 and :306 reads `pickingPosition.getPickfromstockunitId()` | Low | The block between the transfer and :306 only sets fields / handles pallet-empty; no read of the FK. Confirm during implementation. |
| Guard weakened for external moves | Low | Only the completing line's FK is cleared; sibling lines keep the guard non-empty. Covered by the guard-preservation unit test. |
| Early save bumps optimistic version and the later save merges a STALE detached copy → `ObjectOptimisticLockingFailureException` (500) | **Medium (caught in code review)** | Real on the rapid-picking path, where `pickingPosition` arrives DETACHED (deserialized from the request body, never re-read): the transfer's autoflush bumps the managed `@Version`, so re-saving the stale detached param throws. **Fix:** capture the managed instance — `PickingorderPosition managedPickLine = save(pickingPosition)` — and drive the post-transfer setters + second save through `managedPickLine`. `pickingPosition` is left unreassigned (effectively final for the later lambdas). Mirrors the existing `MobilePickingService:466-469` defense for `processPick`. |

### §9 Acceptance

Machine-checkable acceptance is encoded in
`sbdocs/9-System/scripts/verify-260709-picking-nirvana-guard-blocks-self-depleting-pick.sh`:
- **POSITIVE:** `setPickfromstockunitId(null)` appears **before** the
  `transferStockToUnitLoad` call in `confirmPick`.
- **NEGATIVE:** the old post-transfer `setPickfromstockunitId(null)` (appearing after the
  transfer) is gone.
- `mvn_test_passes PickingorderBusinessServiceUnitTest`.

A "DONE" claim with any FAIL line is not accepted.

### 9.2 Recommended OMC composition

| Aspect | Value | Rationale |
|---|---|---|
| Size class | Trivial | 1 file, one ordering move of two statements. |
| Pre-draft step | none | Root cause DB-verified. |
| Plan-review step | Architect + Critic — DONE (both APPROVE 2026-07-09) | Confirmed no downstream FK read between :290 and :306; see §10 Review log. |
| Implementation shape | executor | Single mechanical edit + tests. |
| Verification step | verify-script + verifier | Mandatory. |
| Code-review step | none | Trivial. |
| Commit step | git directly | Single logical commit. |

---

## §10. Implementation Status

**Status: IMPLEMENTED** (Architect + Critic + post-implementation code-review all APPROVE, 2026-07-09). PR: https://github.com/SiteBossInc/wms-api/pull/196 -> develop, commit 573eff5.

### Review log

- **2026-07-09 — Architect (read-only): DESIGN SOUND.** Verified against the working tree:
  the ordering bug is real (FK nulled at `:306`, after the transfer at `:290`); nothing in
  the `:290→:306` window reads the FK; `confirmPick` and `transferStockToUnitLoad` share
  one transaction (`transferStockToUnitLoad` joins via REQUIRED; `sendStockUnitToNirvana`
  non-tx) so atomicity holds; branch B is the only guard-reachable path from `confirmPick`
  (`CODE_PICKING` is PASS_THROUGH → branch A realign never runs); guard not weakened for
  concurrent external moves (early null invisible until commit under READ COMMITTED; owning
  order already locked at `:254`). 3 low-severity refinements — all folded in below.
- **2026-07-09 — Critic (read-only): APPROVE.** Zero CRITICAL/MAJOR, no MUST-FIX. Every
  load-bearing claim (line numbers, `@Transactional(rollbackFor=…)` at `:222`, guard,
  branch-B flow, `:299` reservation check throws a *different* message so a reported
  `ACTIVE_PICK_MESSAGE` uniquely identifies the `:323` guard, sibling-caller enumeration =
  cancellation paths, Fix B / Option C rejections) verified against source. 5 NICE-TO-HAVEs
  — all folded in below.
- **2026-07-09 — Author: refinements applied** (all non-blocking): (1) documented the
  flush dependency — the early detach uses plain `save` (these repos extend
  `PagingAndSortingRepository`, so `saveAndFlush` is unavailable and unused codebase-wide);
  correctness relies on Hibernate's default `FlushMode.AUTO` auto-flushing the pending
  detach before the guard's `findByPickfromstockunitId` SELECT on the same table
  [the Critic's `saveAndFlush` suggestion was infeasible for this repo type — mechanism
  corrected, dependency still documented]; (2) §8 makes the `doAnswer` call-time
  snapshot the primary ordering assertion (an `argThat` proves ordering only, not the FK's
  value *at transfer time*) + discloses the unit-test coverage boundary; (3) documented that
  branch B is the sole guard-reachable path for `CODE_PICKING`; (4) §7 pins the insertion
  point strictly between `:288` and `:290`; (5) open-question 2 now states stuck parcels
  auto-recover (failed tx rolled back → reservation intact → re-drive `processPick`), SQL
  only on drift.
- **2026-07-09 — Code review (post-implementation): REQUEST CHANGES -> resolved.** 1 HIGH:
  the added second `save()` on a non-reassigned `@Version` `pickingPosition` would throw
  `ObjectOptimisticLockingFailureException` on the rapid-picking path (detached entity; the
  transfer autoflush bumps the managed version). **Fixed** by capturing the managed instance
  (`managedPickLine = save(...)`) and routing the post-transfer setters + second save through
  it (`pickingPosition` stays unreassigned for the lambdas); mirrors the existing
  `MobilePickingService:466-469` defense for `processPick`. 1 MEDIUM: the unit test mocks the
  repo so it can't catch the optimistic-lock mode and v1 ITs are blocked (SBDEV-2384) — the fix
  removes the mechanism by construction; a real persistence test is a documented follow-up. LOWs:
  dropped an unnecessary `lenient()`; sibling cancellation-path nullers noted out-of-scope.
  Positives confirmed: ordering fix correct, FlushMode.AUTO reasoning sound, atomicity + guard
  integrity hold, the `doAnswer` snapshot is a genuine regression gate.

### Resolved decisions

- Fix locus is `confirmPick` ordering, NOT the guard. (Guard is correct; caller's order is wrong.)
- Fix A (move the null before the transfer) chosen over Fix B (thread an exclude-id
  through the transfer) — smaller blast radius, no shared-method signature change.
- SBDEV-2512 and `ENFORCE_PARTITIONALLOWED` are unrelated to this incident and do not
  fix it; PICK227210 was released while SBDEV-2512 was ON yet was still fragmented, so it
  did not traverse SBDEV-2512's overstock guard at all.
- The fix closes both the fragmented-position self-deplete case seen here and any
  shared-unit overstock case (both reach the same guard).

### Open questions

1. **[RESOLVED 2026-07-09] Replenishment manifestation — NOT this bug.** The multi-UL
   replen `RR19CHGM` was DB-verified (§1 "Related report — RESOLVED"): it selected ULs
   already reserved by other open replens (REPL051911/051914, available 0) and was refused
   by #193's `MsgUnitLoadStockAlreadyReserved` — verbatim "Unit load stock is already
   reserved (0.0000 available). Choose a different unit load." None of the involved stock
   units has a referencing pick line, so it cannot be the `sendStockUnitToNirvana:323` guard.
   No cross-path generalization is needed; `confirmPick` Fix A is the complete fix for the
   confirmed picking defect.
2. **Already-stuck parcels (e.g. PICK227210) — expected to auto-recover.** The failed
   `confirmPick` ran in a single `@Transactional(rollbackFor=…)` boundary, so the throw
   rolled the whole attempt back: the source unit's reservation is intact and the pick
   line is unchanged (not half-transferred). Re-driving `processPick` after the fix
   deploys should therefore complete the pick with no manual SQL. Fall back to a per-parcel
   `pickfromstockunit_id` remediation ONLY if the Appendix B enumeration shows actual
   reservation/state drift (e.g. a reservation left dangling by an unrelated path). Run
   Appendix B before deploy to confirm the set is clean.
3. **Deploy timing.** The guard code (commit `7c47a2b`) is dated **2026-06-24**. A
   report that picking "worked this morning" only fits if the tester's environment first
   deployed that batch **today** (deploy lag). Unresolved — flag, not blocking. Confirm
   when `7c47a2b` actually reached the tester's env.
4. **(SEPARATE gap — NOT scoped in this plan.)** Why was a `partitionallowed = false`
   position (cop 27149023) fragmented 2+1 across two unit loads in a **PICK_PACK** order
   at release time (~08:47) **despite SBDEV-2512 being ON**? SBDEV-2512's overstock
   phase-3 guard enforces hold-or-single-pick for non-partitionable positions, so this
   release must have gone through a **different release branch** (e.g. fixed-assignment
   or regular multi-source) that fragments without consulting `partitionallowed`.
   Identify that branch and decide whether SBDEV-2512's guard should extend to it. This
   is a distinct potential defect surfaced by the same incident data — it does not affect
   the guard/ordering fix in this plan and must be triaged as its own ticket.

---

## Appendix A — Diagnostic SQL: confirm a given PICK######

Given a picking-order number (e.g. `PICK227210`), list its pick lines grouped by source
stock unit, with the source amount/reservation and whether a fix-location-assignment
exists — this reproduces the incident fingerprint.

```sql
-- (a) Fingerprint a specific picking order.
-- Chain: pickingorder_position → pickingorder (state)
--        → stockunit (source amount/reserved/location)
--        → customerorder_position (partitionallowed) via cop.order_id
WITH po AS (
    SELECT id, number, state
    FROM pickingorder
    WHERE number = :pick_number          -- e.g. 'PICK227210'
)
SELECT
    po.number                         AS pick_number,
    po.state                          AS pickingorder_state,       -- expect 500 (STARTED)
    pop.id                            AS pick_line_id,
    pop.state                         AS pick_line_state,          -- 600 done / 300 stuck
    pop.amount                        AS pick_line_amount,
    pop.pickfromstockunit_id          AS source_stockunit_id,
    su.amount                         AS su_amount,
    su.reservedamount                 AS su_reserved,
    su.unitload_id                    AS su_unitload_id,
    su.itemdata_id                    AS su_itemdata_id,
    cop.id                            AS cop_id,
    cop.partitionallowed              AS cop_partitionallowed,
    loc.id                            AS source_location_id,
    loc.name                          AS source_location_name,
    fla.id                            AS fix_location_assignment_id  -- NULL == no fla (guard-relevant)
FROM po
JOIN pickingorder_position pop        ON pop.pickingorder_id = po.id
LEFT JOIN stockunit su                ON su.id = pop.pickfromstockunit_id
LEFT JOIN unitload ul                 ON ul.id = su.unitload_id
LEFT JOIN location loc                ON loc.id = ul.storagelocation_id
LEFT JOIN fix_location_assignment fla ON fla.assignedlocation_id = loc.id
LEFT JOIN customerorder_position cop  ON cop.id = pop.customerorderposition_id
ORDER BY pop.pickfromstockunit_id, pop.id;
```

---

## Appendix B — Diagnostic SQL: enumerate currently-stuck parcels

Find pick lines wedged by this defect: state 300 (PROCESSABLE) whose owning picking order
is 500 (STARTED), whose source stock unit's amount equals the pick line's amount (so the
pick would fully deplete it → nirvana → guard fires), and whose source location has **no**
`fix_location_assignment` (the `fla == null` branch that routes to nirvana).

```sql
-- (b) Enumerate parcels currently stuck by the nirvana-guard ordering bug.
SELECT
    po.number                  AS pick_number,
    po.id                      AS pickingorder_id,
    pop.id                     AS pick_line_id,
    pop.amount                 AS pick_line_amount,
    pop.pickfromstockunit_id   AS source_stockunit_id,
    su.amount                  AS su_amount,
    su.reservedamount          AS su_reserved,
    loc.id                     AS source_location_id,
    loc.name                   AS source_location_name
FROM pickingorder_position pop
JOIN pickingorder po           ON po.id = pop.pickingorder_id
JOIN stockunit su              ON su.id = pop.pickfromstockunit_id
JOIN unitload ul               ON ul.id = su.unitload_id
JOIN location loc              ON loc.id = ul.storagelocation_id
WHERE pop.state = 300                         -- PROCESSABLE (stuck)
  AND po.state  = 500                         -- STARTED
  AND su.amount = pop.amount                  -- pick would fully deplete the source
  AND NOT EXISTS (
        SELECT 1 FROM fix_location_assignment fla
        WHERE fla.assignedlocation_id = loc.id  -- no fla → routes to nirvana
      )
ORDER BY po.number, pop.id;
```

> Column names (`storagelocation_id`, `pickfromstockunit_id`, `customerorderposition_id`,
> `assignedlocation_id`, `partitionallowed`) follow the entity FK-field conventions in
> `net.aim_ai.wms.model`; verify against the target tenant schema before running
> (native, unvalidated).
