---
title: "SBDEV-2001: Empty pallets picked clean are misrouted to Nirwana instead of EmptyPallets (v2)"
ticket: "SBDEV-2001"
ticket_url: "https://app.clickup.com/t/868hv0ug3"
type: bugfix
priority: high
status: archived
archived: 2026-07-20
project: [wms2]
version: v2
requester: Brent Campbell
created: 2026-07-19
updated: 2026-07-19
db_verified: true
related:
  - "[[260506-sbdev-1581-empty-pallet-cleanup-investigation]]"
  - "[[wms2-move-stock-unitload-workflow]]"
  - "[[wms2-state-machine-catalog]]"
tags:
  - plan
  - pallets
  - nirvana
  - emptypallets
  - unitload-lifecycle
---

# SBDEV-2001: Empty pallets picked clean are misrouted to Nirwana instead of EmptyPallets (v2)

> **Archived 2026-07-20** — implemented and merged via wms2-api PR [#81](https://github.com/SiteBossInc/wms2-api/pull/81) (→ develop).
> Acceptance script retained at `sbdocs/9-System/scripts/verify-SBDEV-2001-empty-pallet-misrouted-to-nirvana.sh`.

**Ticket:** [SBDEV-2001](https://app.clickup.com/t/868hv0ug3)
**Project:** wms2 | **Version:** v2 | **Type:** bugfix
**Priority:** High
**Status:** draft (pending review)
**Date:** 2026-07-19

> **Scope:** v2/wms2-api only, misrouting fix only. The nightly empty-pallet cleanup **sweep** (SBDEV-1581) is intentionally **out of scope** — see §8.

---

## 0. Affected sites (enumeration before drafting)

> **Scope note (revised after ralplan Architect+Critic review, 2026-07-19):** the fix rewrites the
> *retire-on-empty* branch **inside the shared method** `StockunitBusinessService.transferStockToUnitLoad`,
> so it changes behavior for **every caller passing `removeUnitLoadIfEmpty=true`**, not a hand-picked few.
> The user chose the **Universal** scope (see §10): *any container emptied because its contents were
> moved out* is relocated type-aware (Pallet/Cart→EmptyPallets, Tote→EmptyTotes, else→Nirwana). The
> enumeration below therefore uses **two lenses**: (0.A) the shared-method depletion callers, and
> (0.B) the literal `sendToNirvana` callsites.

### 0.A — Callers of `transferStockToUnitLoad(..., removeUnitLoadIfEmpty=true)` (all relocate via Fix B)

Enumerated via `grep -rn "transferStockToUnitLoad(" src/main/java`. These **18** callsites (grouped by caller below) hit the edited
depletion branch when their source UL ends empty. All are **contents-moved-out depletion** → in-scope, intended to relocate.

| # | Caller | Activity code | In-scope (relocate)? |
|---|--------|---------------|----------------------|
| 1 | `StockunitService.java:170,174,204,237,254` | `CODE_MANUAL_SPLIT` | YES |
| 2 | `StockunitService.java:243,396` | `CODE_DAMAGED` | YES |
| 3 | `MobileMoveStockService.java:277,335,340` | `CODE_MANUAL_SPLIT` | YES |
| 4 | `MobileTransferOrderService.java:397,403,408` | `CODE_MANUAL_SPLIT` | YES |
| 5 | `MobileReplenishService.java:498` | replenishment | YES |
| 6 | `MobilePutAwayService.java:489` | `CODE_PUT_AWAY` | YES |
| 7 | `PickingorderBusinessService.java:552` | `CODE_PICKING` | YES |
| 8 | `ClubLineOrderProcessor.java:197` | `CODE_PACKAGING_CLUB` | YES (club packaging) |
| 9 | `BillofladingService.java:809` (`combineStock`) | `CODE_TRANSFER_BUILD_TRUCK` | YES (club truck-build) |
| — | `CustomerorderService.java:544` | `CODE_PACKAGING` | **N/A — passes `removeUnitLoadIfEmpty=false`** |
| — | `MobileMoveUnitloadService.java:382` | `CODE_TRANSFER` | **N/A — passes `removeUnitLoadIfEmpty=false`** |

Fix B (editing lines 366/386 inside the shared method) is the single change that reroutes all of 0.A. No per-caller edits required.

### 0.B — Literal `sendToNirvana(...)` callsites

Enumerated via `grep -rn "\.sendToNirvana(" src/main/java`.

| # | File:line | Construct | Classification | In-scope? |
|---|-----------|-----------|----------------|-----------|
| 1 | `StockunitBusinessService.java:366` | full-move branch, source UL empty | Depletion (shared method) | **YES — Fix B** |
| 2 | `StockunitBusinessService.java:386` | partial-move branch drains to zero | Depletion (shared method) | **YES — Fix B** |
| 3 | `PickingorderBusinessService.java:559` | picking **carrier** pallet emptied (separate from :552 source) | Depletion | **YES — Fix C** |
| 4 | `BillofladingService.java:779` (`combineStock`) | retires *already-empty* transfer-lane siblings | Depletion (see §3 Fix D) | **YES — Fix D** |
| 5 | `GoodsReceiptPositionService.java:171` | receipt position removal (stock **removed**, not moved) | Deliberate delete | no |
| 6 | `MobileMoveUnitloadService.java:413` | operator explicitly scanned UL to Nirwana | Deliberate delete | no |
| 7 | `FixLocationAssignmentService.java:267` | fix-assignment teardown | Deliberate delete | no |
| 8 | `UnitloadService.java:383` | explicit manual removal | Deliberate delete | no |
| 9 | `MobileCycleCountService.java:229,444` | count-to-zero retire | Deliberate delete | no |
| 10 | `CustomerorderService.java:576,743` | picking-**tote** disposal after pack / cancel | Deliberate delete | no (see §8) |

`sendStockUnitToNirvana(...)` callsites operate on **stock units**, not containers — out of scope by construction.

**Decision (user, 2026-07-19):** **Universal** reroute. 0.A (all 15 shared-method depletion callers) + 0.B rows 1–4 relocate type-aware. 0.B rows 5–10 (deliberate delete) keep `sendToNirvana` unchanged. See §10.

---

## 1. Problem Statement

**User-visible symptom (SBDEV-2001):** When a pallet is picked clean (its last stock/child unit load is moved off), the empty pallet should end up in the **`EmptyPallets`** location so it can be reused. Instead, some empty pallets wind up in **`Nirwana`** ("To Delete") — removed from circulation, with their label destroyed — even though nothing asked to delete them.

**DB verification (`wms2-wineco-dev`, 2026-07-19) — `db_verified: true`:**

```sql
SELECT l.name AS location, ult.name AS ul_type, COUNT(*) AS ul_count,
       COUNT(*) FILTER (WHERE su.cnt IS NULL AND ch.cnt IS NULL) AS empty,
       COUNT(*) FILTER (WHERE u.labelid LIKE '%-X-%') AS mangled_label
FROM unitload u
JOIN location l       ON l.id  = u.storagelocation_id
JOIN unitload_type ult ON ult.id = u.type_id
LEFT JOIN (SELECT unitload_id, COUNT(*) cnt FROM stockunit GROUP BY unitload_id) su ON su.unitload_id = u.id
LEFT JOIN (SELECT carrierunitload_id, COUNT(*) cnt FROM unitload GROUP BY carrierunitload_id) ch ON ch.carrierunitload_id = u.id
WHERE l.name IN ('Nirwana','EmptyPallets','EmptyTotes')
GROUP BY l.name, ult.name ORDER BY l.name, ul_type;
```

| location | ul_type | ul_count | empty | mangled_label |
|---|---|---|---|---|
| EmptyPallets | Pallet | 43 | 43 | 0 |
| EmptyTotes | Tote | 246 | 246 | 1 |
| **Nirwana** | **Pallet** | **19** | **19** | **19** |
| Nirwana | Tote | 665 | 665 | 665 |
| Nirwana | Case | 297904 | 297904 | 297904 |
| Nirwana | PickLocation | 22048 | 22048 | 22048 |

**19 `Pallet` unit loads are sitting in `Nirwana`, all empty, all with mangled `-X-` labels** — the exact defect. (`Case`/`PickLocation` in Nirwana are expected retirements; out of scope.)

**Reproduction (functional):** overstock pallet with a single stock unit → replenish/pick its last stock to a pick location → the now-empty pallet lands in `Nirwana` with `entity_lock = GOING_TO_DELETE` and label `…-X-<id>`, instead of `EmptyPallets` with its label intact.

---

## 2. Root Cause Analysis

### Bug 1: type-blind retire on depletion

When a source container becomes empty **because its contents were moved out**, the depletion callsites call `UnitloadBusinessService.sendToNirvana(...)` with **no unit-load-type check**.

`UnitloadBusinessService.java:318-347`:

```java
public void sendToNirvana(Unitload unitload, String activityCode, String orderNumber, String comment) ... {
    ensureInitialized();
    if (!stockunitRepository.findByUnitloadId(unitload.getId()).isEmpty())      throw new BusinessException("... has stock!");
    if (!unitloadRepository.findByCarrierunitloadId(unitload.getId()).isEmpty()) throw new BusinessException("... is carrier!");
    if (nirvanaUnitload.getId().equals(unitload.getId()))                        throw new BusinessException("Can not delete " + unitload.getId());
    if (nirvanaLocation.getId().equals(unitload.getStoragelocationId())) { LOG.warn("... already on {}", nirvanaLocation); return; }

    transferUnitLoadToLocation(unitload, nirvanaLocation, true, activityCode, orderNumber, comment);   // (a) move to Nirwana
    Unitload unitloadUpdated = unitloadRepository.findById(unitload.getId()).orElseThrow(...);
    unitloadUpdated.setEntityLock(BusinessObjectLockState.GOING_TO_DELETE);                             // (b) mark To-Delete
    unitloadUpdated.setLabelid(unitload.getLabelid() + "-X-" + unitload.getId());                       // (c) destroy label
    unitloadRepository.save(unitloadUpdated);
}
```

`sendToNirvana` is a **retire** operation: it moves the UL to `Nirwana`, sets `GOING_TO_DELETE`, and mangles the label (so the physical barcode can never be re-scanned to the old UL). That is correct for a *deliberate delete* — but the depletion callsites invoke it purely because a container was left empty after a move. Because the primary depletion callsite lives **inside the shared method** `transferStockToUnitLoad` (SUB:365-366, 385-386), every one of its 18 `removeUnitLoadIfEmpty=true` callsites (§0.A — pick, replenish, split, putaway, transfer-order, club packaging, club truck-build) inherits this retire-on-empty. A pallet or cart that just needs to go back into the empty-container pool is instead permanently retired, across every one of those flows.

There is **no `Pallet → EmptyPallets` branch anywhere in the live path.** The only type-aware routing lives in `MobileMoveUnitloadService.transferStock()` (lines 398-408: Pallet/Cart→EmptyPallets, Tote→EmptyTotes, else→Nirwana), but that method is annotated `// TODO remove this method entirely` (line 371) and *throws* for an already-empty pallet (line 388), so it does not cover gradual pick/replenish depletion.

**Why it triggers unevenly ("some pallets"):** only depletion that ends with `sourceStockunitList.isEmpty() && sourceUnitLoadList.isEmpty()` (StockunitBusinessService:365,385) or an emptied picking carrier (PickingorderBusinessService:558) hits the retire call. Pallets emptied through paths that never reach these lines (or that error earlier) stay put — which is why operators see it intermittently.

---

## 3. Fix Design

### Fix A — new `relocateEmptiedContainer(...)` on `UnitloadBusinessService`

Introduce a single type-aware relocation entry point so **all** depletion callers share one decision, and the retire vs relocate semantics are explicit at the boundary.

**New method (`UnitloadBusinessService`, adjacent to `sendToNirvana`):**

```java
/**
 * Relocate a container that became empty because its contents were MOVED out (pick / replenish
 * depletion). Reusable containers go back to their empty pool with label + lock intact:
 *   Pallet, Cart -> EmptyPallets
 *   Tote         -> EmptyTotes
 *   anything else -> sendToNirvana (retire; preserves today's behavior for non-reusable types)
 * Contrast with sendToNirvana(), which is the DELETE path (To-Delete lock + label mangle).
 */
public void relocateEmptiedContainer(Unitload unitload, String activityCode, String orderNumber, String comment)
        throws FacadeException, BusinessException {
    ensureInitialized();
    // Same emptiness guards as sendToNirvana — never relocate a container that still holds anything.
    if (!stockunitRepository.findByUnitloadId(unitload.getId()).isEmpty())
        throw new BusinessException("Can not relocate. unitLoad=" + unitload.getId() + " has stock!");
    if (!unitloadRepository.findByCarrierunitloadId(unitload.getId()).isEmpty())
        throw new BusinessException("Can not relocate. unitLoad=" + unitload.getId() + " is carrier!");

    UnitloadType type = unitloadTypeRepository.findById(unitload.getTypeId())
        .orElseThrow(() -> new EntityNotFoundException("UnitLoadType", unitload.getTypeId()));

    final String targetLocationName;
    switch (type.getName()) {
        case WmsConstants.UNIT_LOAD_TYPE_PALLET:
        case WmsConstants.UNIT_LOAD_TYPE_CART:
            targetLocationName = WmsConstants.STORAGE_LOCATION_EMPTY_PALLETS;
            break;
        case WmsConstants.UNIT_LOAD_TYPE_TOTE:
            targetLocationName = WmsConstants.STORAGE_LOCATION_EMPTY_TOTES;
            break;
        default:
            // Non-reusable container (Box / PickLocation / Package / Default) — retire as before.
            sendToNirvana(unitload, activityCode, orderNumber, comment);
            return;
    }

    Location target = locationRepository.findByName(targetLocationName)
        .orElseThrow(() -> new EntityNotFoundException("Location not found by name: " + targetLocationName));

    if (target.getId().equals(unitload.getStoragelocationId())) {   // idempotent
        LOG.warn("unitLoad={} already on {}", unitload.getId(), targetLocationName);
        return;
    }
    // Relocate ONLY — no GOING_TO_DELETE, no label mangle. Container keeps its identity for reuse.
    // Record with a dedicated relocation activity code (NOT the caller's retire code) — see D2.
    transferUnitLoadToLocation(unitload, target, true, WmsConstants.CODE_CONTAINER_RELOCATED_EMPTYPOOL, orderNumber, comment);

    // D1: reusability is the ticket's goal — an emptied container must land FREE, not carrying a
    // residual pick/reserve lock. sendToNirvana used to overwrite the lock (to GOING_TO_DELETE);
    // the relocate path must explicitly clear it to NOT_LOCKED.
    Unitload relocated = unitloadRepository.findById(unitload.getId())
        .orElseThrow(() -> new EntityNotFoundException("UnitLoad", unitload.getId()));
    // entityLock is a nullable Integer — compare null-safely (Integer.equals), never `!= int` (auto-unbox NPE).
    if (!Integer.valueOf(WmsConstants.BusinessObjectLockState.NOT_LOCKED).equals(relocated.getEntityLock())) {
        relocated.setEntityLock(WmsConstants.BusinessObjectLockState.NOT_LOCKED);
        unitloadRepository.save(relocated);
    }
}
```

> **Activity code (D2 resolved):** the relocate branch records `CODE_CONTAINER_RELOCATED_EMPTYPOOL`, a
> **new** `WmsConstants` code, so `unitload_record` no longer mislabels EmptyPallets moves as
> `SEND_TO_NIRWANA`. A TDD-gate stub `StockRecordType.STOCK_RELOCATED` already exists at
> `WmsConstants.java:196` (labeled "implement per plan (F-A)"); implementation must reconcile the two —
> use the existing stub if it is the intended activity-code constant, otherwise add the `CODE_*` above
> and wire the stub to it. The `default:` (retire) branch still passes the **caller's** code through to
> `sendToNirvana`, preserving today's provenance for deliberate deletes.

**Why this and not alternatives:**
- **Not** making `sendToNirvana` itself type-aware — `sendToNirvana` is called by 9 deliberate-delete sites (§0 rows 4-12) that *must* keep retiring. Overloading its meaning would silently change cycle-count / receiving / manual-removal behavior (explicitly out of scope per §10).
- **Not** reviving `MobileMoveUnitloadService.transferStock()` — it is marked for removal and couples relocation to a stock-move it no longer performs.
- Centralizing the emptiness check + type switch in one method means the picking carrier path and both stock-move branches converge on identical, testable behavior.

### Fix B — repoint the two `StockunitBusinessService` depletion branches

`StockunitBusinessService.java:365-367` and `:385-387`:

```java
// Before (both branches):
if (removeUnitLoadIfEmpty && sourceStockunitList.isEmpty() && sourceUnitLoadList.isEmpty()) {
    unitloadBusinessService.sendToNirvana(sourceUnitload, WmsConstants.CODE_SEND_TO_NIRVANA, orderNumber, comment);
}
// After:
if (removeUnitLoadIfEmpty && sourceStockunitList.isEmpty() && sourceUnitLoadList.isEmpty()) {
    unitloadBusinessService.relocateEmptiedContainer(sourceUnitload, WmsConstants.CODE_SEND_TO_NIRVANA, orderNumber, comment);
}
```

Leave the SBDEV-2481 pick-line realignment logic (same method, lines 349-358) untouched — it runs before this block and is unaffected.

### Fix C — repoint the picking-carrier branch

`PickingorderBusinessService.java:558-559`:

```java
// Before:
if (pallet != null && unitloaList.isEmpty()) {
    unitloadBusinessService.sendToNirvana(pallet, WmsConstants.CODE_PICKING_CARRIER_EMPTY, pickingPosition.getNumber(), null);
}
// After:
if (pallet != null && unitloaList.isEmpty()) {
    unitloadBusinessService.relocateEmptiedContainer(pallet, WmsConstants.CODE_PICKING_CARRIER_EMPTY, pickingPosition.getNumber(), null);
}
```

### Fix D — `BillofladingService.combineStock` sibling consistency

`combineStock` (`:794-819`) disposes transfer-lane containers two ways: a **leaf with stock** is drained via `transferStockToUnitLoad(..., removeUnitLoadIfEmpty=true)` at `:809` (so after Fix B it relocates), while an **already-empty leaf or a drained parent carrier** is collected into `emptyUnitLoadList` and retired at `:779`. Without Fix D, two emptied siblings in the *same* truck-build would split between EmptyPallets (`:809` path) and Nirwana (`:779` path) by structural accident.

`BillofladingService.java:778-780`:

```java
// Before:
for (Unitload unitLoad : emptyUnitLoadList) {
    unitloadBusinessService.sendToNirvana(unitLoad, WmsConstants.CODE_SEND_TO_NIRVANA, null, null);
}
// After — same type-aware relocation as the drained-leaf path, so siblings are consistent:
for (Unitload unitLoad : emptyUnitLoadList) {
    unitloadBusinessService.relocateEmptiedContainer(unitLoad, WmsConstants.CODE_TRANSFER_BUILD_TRUCK, null, null);
}
```

Reusable containers (Pallet/Cart/Tote) go to their empty pool; any non-reusable type still retires via the method's `default:` delegation to `sendToNirvana`. This is the only literal `sendToNirvana` callsite promoted into scope; the other deliberate-delete callsites (§0.B rows 5-10) are untouched.

**Activity-code decision (D2 resolved):** the relocate outcome records the dedicated `CODE_CONTAINER_RELOCATED_EMPTYPOOL` (set inside `relocateEmptiedContainer`, see Fix A), not the caller's retire code — so EmptyPallets moves are no longer labeled `SEND_TO_NIRWANA` in `unitload_record`. Caller codes are still forwarded to the `default:` retire delegation for non-reusable types.

---

## 4. Architecture Overview

```
Pick / Replenish / Move stock
        │
        ▼
StockunitBusinessService.transferStockToUnitLoad(..., removeUnitLoadIfEmpty=true)
        │  source UL now empty (no stock, no children)?
        ▼
   [Fix B]  relocateEmptiedContainer(sourceUnitload, ...)  ─┐
                                                            │
Pick confirm (carrier pallet emptied)                       │
        │                                                   │
        ▼                                                   ▼
PickingorderBusinessService.confirmPick(...) ──[Fix C]──▶ UnitloadBusinessService.relocateEmptiedContainer(...)
                                                            │  type?
                                     Pallet/Cart ───────────┼──▶ transferUnitLoadToLocation(EmptyPallets)  (label + lock intact)
                                     Tote ──────────────────┼──▶ transferUnitLoadToLocation(EmptyTotes)
                                     other ─────────────────┴──▶ sendToNirvana(...)  (retire: To-Delete + label mangle)
```

**Key files:**

| File | Lines | Role |
|------|-------|------|
| `service/UnitloadBusinessService.java` | new method near 318-347; reuse `transferUnitLoadToLocation` (119), `sendToNirvana` (318) | **Fix A** — new `relocateEmptiedContainer` (type-aware; clears lock; dedicated activity code) |
| `service/StockunitBusinessService.java` | 366, 386 | **Fix B** — repoint the shared-method depletion branch (propagates to all 18 §0.A callsites) |
| `service/PickingorderBusinessService.java` | 559 | **Fix C** — repoint carrier-empty branch |
| `service/BillofladingService.java` | 778-780 | **Fix D** — `combineStock` sibling consistency (relocate `emptyUnitLoadList`) |
| `service/WmsConstants.java` | add `CODE_CONTAINER_RELOCATED_EMPTYPOOL`; reconcile `STOCK_RELOCATED` stub (196); reuse `_PALLET`/`_CART`/`_TOTE`/`_EMPTY_PALLETS`/`_EMPTY_TOTES`/`NOT_LOCKED` | new activity code + existing constants |

---

## 5. Prerequisites & Implementation Plan

### 5.1 Prerequisites

| # | Prerequisite | Required value / action | Owner | Notes |
|---|---|---|---|---|
| 1 | **Database state** | `location` rows `EmptyPallets` and `EmptyTotes` exist in every tenant DB | DBA | Confirmed present on wineco-dev (43 + 246 rows). Add a preflight check per tenant before rollout; `relocateEmptiedContainer` throws `EntityNotFoundException` if a tenant lacks the location. |
| 2 | **Feature flags / system properties** | N/A | — | No sysprop gate; behavior change is unconditional by design (matches ticket intent). |
| 3 | **Config / env changes** | N/A | — | Pure service-logic change. |
| 4 | **Deploy-order dependencies** | None | — | No API/DTO/contract change; no coordinated UI/OMS deploy. |
| 5 | **Data migration (existing misrouted pallets)** | Optional one-off backfill of the 19+ already-in-Nirwana pallets | DBA + eng | The 19 pallets already have mangled labels + `GOING_TO_DELETE`; recovering them is a **separate** decision (see §8). This plan fixes forward only. |
| 6 | **External systems** | N/A | — | No OMS/printer/keycloak interaction. |
| 7 | **Access / permissions** | N/A | — | No new endpoint/authority. |
| 8 | **Monitoring / alerts** | Optional: alert if `Nirwana`+`Pallet`+empty count grows after deploy | eng | Query in §1 is the probe; a post-deploy delta of ~0 new Pallet-in-Nirwana confirms the fix. |

### 5.2 Implementation Checklist

- [ ] Add `CODE_CONTAINER_RELOCATED_EMPTYPOOL` to `WmsConstants`; reconcile the `STOCK_RELOCATED` stub (line 196).
- [ ] Add `relocateEmptiedContainer(...)` to `UnitloadBusinessService` (Fix A) — type switch, lock-clear (D1), dedicated code (D2). `unitloadTypeRepository` + `locationRepository` already injected (:35,:43).
- [ ] Repoint the shared-method depletion branch `StockunitBusinessService.java:366` and `:386` (Fix B) — this propagates to all 18 §0.A callsites.
- [ ] Repoint `PickingorderBusinessService.java:559` carrier branch (Fix C).
- [ ] Repoint `BillofladingService.java:779` `emptyUnitLoadList` loop (Fix D).
- [ ] Unit tests for Fix A (all type branches + guards + idempotency + lock-cleared + code recorded).
- [ ] Unit tests for the highest-risk §0.A indirect callers: `ClubLineOrderProcessor` (packaging), `BillofladingService.combineStock` (truck-build, leaf+parent same destination), `StockunitService` split, `MobileReplenishService`, `MobilePutAwayService`.
- [ ] `mvn test -Dtest=UnitloadBusinessServiceUnitTest,StockunitBusinessServiceUnitTest,PickingorderBusinessServiceUnitTest,BillofladingServiceUnitTest,ClubLineOrderProcessorUnitTest,StockunitServiceUnitTest`
- [ ] `mvn clean compile` + `mvn verify` (Testcontainers) green.
- [ ] `bash sbdocs/9-System/scripts/verify-SBDEV-2001-empty-pallet-misrouted-to-nirvana.sh` → `0 fail`.
- [ ] Code review + update §9 Implementation Status.

---

## 6. Test Plan

### Test scenarios

| Scenario | Steps | Expected Result |
|----------|-------|-----------------|
| Emptied Pallet | move last stock off a Pallet UL via `transferStockToUnitLoad(removeUnitLoadIfEmpty=true)` | UL now on `EmptyPallets`; `entity_lock` NOT `GOING_TO_DELETE`; label unchanged |
| Emptied Cart | same, Cart type | UL on `EmptyPallets`, label intact |
| Emptied Tote | same, Tote type | UL on `EmptyTotes`, label intact |
| Emptied Box/other | same, Box type | UL retired to `Nirwana` (delegates to `sendToNirvana`): `GOING_TO_DELETE` + `-X-` label |
| Picking carrier emptied | confirm the pick that removes a carrier pallet's last child | carrier Pallet on `EmptyPallets`, not Nirwana |
| Guard: still has stock | call with a UL that still has a stock unit | `BusinessException`, no move |
| Guard: still a carrier | call with a UL that still has children | `BusinessException`, no move |
| Idempotent | call on a Pallet already at `EmptyPallets` | no-op, warn log, no exception |

### New / updated tests

| Test class | Test method | What it asserts |
|------------|-------------|-----------------|
| `UnitloadBusinessServiceUnitTest` | `relocateEmptiedContainer_pallet_goesToEmptyPallets_labelIntact` | target=EmptyPallets, no GOING_TO_DELETE, label unchanged |
| `UnitloadBusinessServiceUnitTest` | `relocateEmptiedContainer_cart_goesToEmptyPallets` | Cart → EmptyPallets |
| `UnitloadBusinessServiceUnitTest` | `relocateEmptiedContainer_tote_goesToEmptyTotes` | Tote → EmptyTotes |
| `UnitloadBusinessServiceUnitTest` | `relocateEmptiedContainer_box_delegatesToSendToNirvana` | verify(sendToNirvana) / Nirwana + mangle |
| `UnitloadBusinessServiceUnitTest` | `relocateEmptiedContainer_withStock_throws` / `_withChildren_throws` | guards |
| `UnitloadBusinessServiceUnitTest` | `relocateEmptiedContainer_alreadyAtTarget_isNoop` | idempotency |
| `UnitloadBusinessServiceUnitTest` | `relocateEmptiedContainer_clearsResidualLock` | **D1** — a container arriving with a non-`NOT_LOCKED` lock is saved back `NOT_LOCKED` |
| `UnitloadBusinessServiceUnitTest` | `relocateEmptiedContainer_recordsRelocationActivityCode` | **D2** — `transferUnitLoadToLocation` called with `CODE_CONTAINER_RELOCATED_EMPTYPOOL`, not `SEND_TO_NIRWANA` |
| `StockunitBusinessServiceUnitTest` | `transferStockToUnitLoad_emptiedSource_relocatesNotRetires` | both shared-method branches call `relocateEmptiedContainer`, not `sendToNirvana` |
| `PickingorderBusinessServiceUnitTest` | `confirmPick_emptiedCarrierPallet_relocatesToEmptyPallets` | carrier path calls `relocateEmptiedContainer` |
| `BillofladingServiceUnitTest` | `combineStock_emptiedSiblings_allRelocate_sameDestination` | **C2** — leaf (`:809`) and parent/already-empty (`:779`) siblings both relocate; no Nirwana/EmptyPallets split |
| `ClubLineOrderProcessorUnitTest` | `clubPackaging_emptiedSourcePallet_relocatesToEmptyPallets` | §0.A row 8 — club packaging depletion relocates |
| `StockunitServiceUnitTest` | `split_emptiedSourcePallet_relocatesToEmptyPallets` | §0.A row 1 — manual-split depletion relocates |

### Manual test plan

| Scenario | Environment | Steps | Expected Result | Pass/Fail |
|---|---|---|---|---|
| Pick-clean a pallet (mobile) | staging | Pick the last stock unit off an overstock pallet | Pallet appears in `EmptyPallets`, scannable by original label | |
| Replenish-empty a pallet | staging | Replenish the last stock from a bulk pallet | Pallet → `EmptyPallets`, not To-Delete | |
| Cycle-count to zero still retires | staging | Count a pallet to zero via mobile cycle count | Pallet → `Nirwana` (unchanged — out-of-scope path) | |
| SQL sanity | staging DB | run the §1 query after exercising the above | `Nirwana`+`Pallet`+empty count does NOT increase; `EmptyPallets` count increases | |

### Test execution (fill in after running)

| Command | Result | Pass / Fail / Skipped |
|---------|--------|------------------------|
| `mvn test -Dtest=UnitloadBusinessServiceUnitTest,StockunitBusinessServiceUnitTest,PickingorderBusinessServiceUnitTest` | | |
| `mvn verify` | | |

### Deliberately-skipped coverage

| What | Why |
|------|-----|
| Testcontainers IT | v2 IT harness broken (TODO SBDEV-2217); assert behavior via unit tests + Mockito `verify` on the collaborator. Gate on `mvn clean compile` + targeted unit tests. |

---

## 7. Horizontal Scalability Validation (v2 — MANDATORY)

| # | Concern | Verdict | Mitigation / rationale |
|---|---|---|---|
| 1 | In-JVM state | **No** | No new cache/static/ThreadLocal; method is stateless. |
| 2 | Connection pool math | **No** | Same query count profile as `sendToNirvana` (2 emptiness lookups + type + location + transfer); no new per-request connections or longer holds. |
| 3 | Scheduled jobs | **No** | No cron added (the SBDEV-1581 sweep is explicitly deferred). |
| 4 | Long transactions | **No** | Runs inside the caller's existing tenant transaction, same boundary as today's `sendToNirvana`. |
| 5 | Request affinity | **No** | Stateless; no session/replica assumption. |
| 6 | Retry / idempotency | **Yes** | The "already at target" short-circuit makes re-execution a no-op; a retry after mid-op crash re-reads state and either relocates once or no-ops. |
| 7 | Tenant context | **No** | Synchronous within the caller's request/job thread; no async boundary introduced. |
| 8 | Distributed lock correctness | **No** | No new locks; `transferUnitLoadToLocation(..., ignoreLock=true, ...)` matches the current retire path. Emptiness guards run under the caller's tx. |
| 9 | Cache invalidation | **No** | `Unitload`/`Location` writes go through the same repository save path as today; no cached-entity write pattern changes. |
| 10 | External notifications | **No** | No OMS/printer/message send. |

### Evidence (Yes rows)

| # | What was verified | Reference |
|---|---|---|
| 6 | Idempotent short-circuit when `target.getId().equals(unitload.getStoragelocationId())` | Fix A method body |

### v2-only constraint checklist

| # | Constraint | Verdict | Where addressed |
|---|---|---|---|
| 1 | OSIV disabled | **Yes** | All repo calls in `relocateEmptiedContainer` execute inside the caller's `@Transactional` boundary (StockunitBusinessService / PickingorderBusinessService already open one), same as `sendToNirvana` today. No lazy access outside a tx. |
| 2 | Transaction manager | **Yes/N/A** | No new `@Transactional` added; method inherits caller's `tenantTransactionManager` tx. Confirm no caller invokes it outside a tenant tx during review. |
| 3 | `@Transactional(readOnly=true)` | N/A | Write path; not read-only. |
| 4 | Caffeine cache invalidation | N/A | `Unitload`/`Location` are not written through a `@Cacheable`-managed write here (same as existing `sendToNirvana`). |
| 5 | Jakarta namespace | **Yes** | New code uses existing `jakarta.*`-based repositories/entities; no `javax.*` imports. |
| 6 | H2-compatible test SQL | **Yes** | Unit tests mock repositories (no native SQL); no H2/PG dialect risk. |
| 7 | `BaseControllerTest` for controller changes | N/A | No controller/endpoint change. |
| 8 | Micrometer metrics | N/A | Reuses existing paths; optional post-deploy DB probe (§5.1 #8) instead of a new metric. |

---

## 8. Notes

- **`combineStock` (club truck-build) is in scope via Fix D.** The Architect/Critic review found the depletion callsite at `BillofladingService:809` (inside `combineStock`) was being masked by the literal `sendToNirvana` at `:779`. Fix D routes both through `relocateEmptiedContainer` so emptied siblings on one transfer lane share a destination. Club containers that are non-reusable types still retire via the method's `default:` delegation.
- **Complementary follow-up — SBDEV-1581 nightly sweep (out of scope here).** This plan fixes the *misrouting* at the depletion callsites. Pallets that become empty through paths that never reach these callsites still need the nightly `EmptyPalletCleanupJob` described in the concluded investigation `[[260506-sbdev-1581-empty-pallet-cleanup-investigation]]`. Track separately; that job can reuse `relocateEmptiedContainer` once this lands.
- **Existing misrouted pallets (19 on wineco-dev).** Already retired with `GOING_TO_DELETE` + `-X-` labels. Whether to backfill them to `EmptyPallets` (and restore labels) is a **data-repair decision for ops**, not a code fix — flagged in §5.1 #5. Recommend deciding after the forward fix ships.
- **v1 counterpart.** Ticket is tagged wmsv1 + wmsv2 but the user scoped this plan to **v2 only**. A paired v1 plan (`SBDEV-2001-*` under `wms1/plan/`) can be produced later via `wms-v2-migrate`/`wms-bugfix-plan` if desired; the v1 code shape differs (`MobileTransferService` baseline routing exists but is likewise incomplete).

---

## 9. Acceptance & Implementation

### 9.1 Acceptance script

`sbdocs/9-System/scripts/verify-SBDEV-2001-empty-pallet-misrouted-to-nirvana.sh`:
- **Fix A** — new method + Pallet/Cart→EmptyPallets + Tote→EmptyTotes + default→sendToNirvana; **no** GOING_TO_DELETE/label-mangle in the relocate branch (A7); **clears lock to NOT_LOCKED** (A8, D1); records **CODE_CONTAINER_RELOCATED_EMPTYPOOL** (A9) with the constant declared (A10, D2).
- **Fix B/C/D** — shared method (2 relocate calls, 0 sendToNirvana), carrier repoint, and `combineStock` `emptyUnitLoadList` relocate; BillofladingService no longer calls `sendToNirvana` (D2 check).
- **Guards** — the deliberate-delete callsites (GoodsReceipt, FixLocation, Unitload, CycleCount, Customerorder, MobileMoveUnitload) STILL call `sendToNirvana`. *(BillofladingService intentionally dropped from the guard set — now in-scope via Fix D.)*
- **Tests** — runs UnitloadBusinessService / StockunitBusinessService / PickingorderBusinessService / BillofladingService / ClubLineOrderProcessor unit tests.

Final acceptance: `Result: N pass, 0 fail`. Note the grep guards cannot see indirect behavior flips at the `transferStockToUnitLoad` level — that is covered by the **unit tests** on `combineStock`, `ClubLineOrderProcessor`, and `StockunitService` split (§6), which are the authoritative check for the Universal-scope callers.

### 9.2 Recommended OMC composition

| Aspect | Value | Rationale |
|---|---|---|
| Size class | **Standard** | 1 new method + 3 callsite repoints in one subsystem. |
| Pre-draft step | none | analysis + DB verification already done this session. |
| Plan-review step | **critic** | Standard tier — this ralplan run supplies it. |
| Implementation shape | **executor** | Small, cohesive; verify script is the exit gate. |
| Verification step | verify-script + verifier | mandatory. |
| Code-review step | code-reviewer (light) | behavior change in a picking/replenish hot path warrants one pass. |
| Commit step | git directly | single logical commit. |

---

## 10. Open Questions / Resolved Decisions

**Resolved (user, 2026-07-19):**
- **D-scope:** **Universal** — every container emptied because its contents were *moved out* relocates type-aware. Mechanically this is the shared-method edit (Fix B) covering all 18 §0.A callsites, plus Fix C (carrier) and Fix D (combineStock consistency). Only the deliberate-delete literal callsites (§0.B rows 5-10) keep `sendToNirvana`. *(Superseded the initial "3 depletion callsites only" framing after the Architect/Critic review revealed Fix B edits a shared method — see §0 scope note.)*
- **D-types:** Pallet + Cart → `EmptyPallets`; Tote → `EmptyTotes`; everything else → `Nirwana` (retire).
- **D-sweep:** SBDEV-1581 nightly job kept **separate** (§8).

**Resolved during ralplan review (2026-07-19):**
- **D1 — entity lock (Critic M1).** `relocateEmptiedContainer` **clears the lock to `NOT_LOCKED`** on relocate (Fix A). Rationale: `sendToNirvana` used to overwrite the lock to `GOING_TO_DELETE`; a relocated container carrying a residual pick/reserve lock would not be truly reusable, defeating the ticket's goal.
- **D2 — activity code (Critic M2).** Introduce `CODE_CONTAINER_RELOCATED_EMPTYPOOL` and record it on the relocate branch (Fix A); reconcile with the existing `STOCK_RELOCATED` stub at `WmsConstants.java:196`. Deliberate-delete provenance (caller code → `sendToNirvana`) is unchanged.

**Open for implementer (low risk):**
- Confirm at implementation time that `STOCK_RELOCATED` (WmsConstants:196) is the intended activity-code constant vs a `StockRecordType`; wire accordingly.

---

## 11. Implementation Status

**Implemented 2026-07-19 (v2/wms2-api, uncommitted — pending commit/PR).** Consensus-planned (ralplan: Planner→Architect→Critic, APPROVE on iteration 2), TDD-gated (13 tests, red baseline confirmed), implemented, and independently verified (verifier: PASS, high confidence, 0 blockers).

**Code changes (`src/main`, 6 files):**
- `UnitloadBusinessService.java` — Fix A: `relocateEmptiedContainer(...)` (type switch Pallet/Cart→EmptyPallets, Tote→EmptyTotes, default→`sendToNirvana`; emptiness guards; idempotency; D1 null-safe lock-clear to `NOT_LOCKED`; D2 records `CODE_CONTAINER_RELOCATED_EMPTYPOOL`).
- `StockunitBusinessService.java:366,386` — Fix B (both depletion branches repointed).
- `PickingorderBusinessService.java:559` — Fix C (carrier repoint).
- `BillofladingService.java:779` — Fix D (`combineStock` `emptyUnitLoadList` sibling consistency).
- `WmsConstants.java:878` — new `CODE_CONTAINER_RELOCATED_EMPTYPOOL`.
- `PickLineActivityCodeClassifier.java` — added `CODE_CONTAINER_RELOCATED_EMPTYPOOL` to `PASS_THROUGH_CODES` (verifier fast-follow: silences per-relocation fail-open WARN on the hot path; behaviorally identical).

**Tests (`src/test`, 4 classes):** 13 SBDEV-2001 unit tests added — `UnitloadBusinessServiceUnitTest` (9: type branches, guards, idempotency, D1, D2), `StockunitBusinessServiceUnitTest` (2), `PickingorderBusinessServiceUnitTest` (1), `BillofladingServiceUnitTest` (1). Two pre-existing tests that asserted the *old* Nirwana behavior (`PickingorderBusinessServiceUnitTest.shouldSendEmptyPalletToNirvana`, `BillofladingServiceUnitTest.handlesEmptyUnitloadsOnTransferLane`) were updated to the new relocate behavior. Club-packaging and manual-split relocation are covered by the `StockunitBusinessService` shared-method branch tests (unit-infeasible standalone — the decision is internal to the mocked collaborator).

**Results:**
- `mvn clean compile` → BUILD SUCCESS.
- `mvn test -Dtest=UnitloadBusinessServiceUnitTest,StockunitBusinessServiceUnitTest,PickingorderBusinessServiceUnitTest,BillofladingServiceUnitTest,ClubLineOrderProcessorUnitTest,StockunitServiceUnitTest` → **268 run, 0 fail, 0 error**.
- `verify-SBDEV-2001-empty-pallet-misrouted-to-nirvana.sh` → **`Result: 28 pass, 0 fail, 0 skip`**.
- `mvn verify` (Testcontainers ITs) NOT run — v2 IT harness broken (TODO SBDEV-2217), per §6.

**Code review (code-reviewer, 2026-07-19):** 0 CRITICAL, 0 HIGH, 4 MEDIUM, 5 LOW. All 4 MEDIUMs fixed:
- **M1+M2 (BillofladingService:779):** Fix D now passes `CODE_SEND_TO_NIRVANA` (not `CODE_TRANSFER_BUILD_TRUCK`) — restores correct retire provenance for non-reusable siblings (symmetric with Fix B) and silences the classifier fail-open WARN on the retire path. Test assertion updated.
- **M3 (type-name multi-tenant risk):** `relocateEmptiedContainer` now WARNs when a UL falls into `default:` with a type name that is not a recognized non-reusable type (`KNOWN_NON_REUSABLE_TYPE_NAMES`) — makes silent misrouting observable if a tenant's `unitload_type` seed deviates from `WmsConstants`.
- **M4 (atomicity):** added `@Transactional(value="tenantTransactionManager", rollbackFor={BusinessException,FacadeException})` to `relocateEmptiedContainer` so the relocate + lock-clear writes are atomic even for a future caller outside an open tenant tx.
- LOWs (test method rename, `atLeastOnce()` tightening) left as-is; the combineStock-parent Open Question is covered by the §6 staging manual test.
Post-fix: `mvn clean compile` SUCCESS; targeted tests **274 run, 0 fail**; verify script **`28 pass, 0 fail`**.

**Follow-ups:** SBDEV-1581 nightly sweep (separate); ops decision on backfilling the ~19 already-mangled Nirwana pallets (§5.1 #5); confirm `STOCK_RELOCATED` (WmsConstants:196) StockRecordType wiring if used.
