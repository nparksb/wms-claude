---
title: "SBDEV-2690 — Replenish Create silent HTTP 200 when idempotency guard skips creation"
ticket: "SBDEV-2690"
ticket_url: "https://app.clickup.com/t/868kfamn0"
type: bugfix
priority: high
status: "archived 2026-08-20 — SHIPPED. wms2-api PR #89 (merge b3e1b806, fix f511a315) + wms2-web-ui PR #24, both merged. The frontmatter had said `approved` since implementation and was never flipped, so this plan misreported itself as unimplemented during the 2026-08-20 backlog triage. One OPS item survives it: cancel stale blocker REPL049787 (state 300, reserving 12 units since 2025-03) or the 409 fires forever for 23RHRSBTL -> 00-C02."
project: [wms2]
version: v2
requester: "Nam Park (nam.park@siteboss.net)"
created: 2026-07-22
updated: 2026-07-22
db_verified: true
related:
  - "[[260709-duplicate-replenishment-orders-concurrent-generation]]"
  - "[[wms2-replenish-order-creation]]"
  - "[[wms2-replenish-workflow]]"
  - "[[SBDEV-2610-move-unitload-false-reserved-block]]"
  - "[[wms-exception-taxonomy]]"
tags:
  - plan
  - wms2
  - replenishment
  - api-contract
---

# SBDEV-2690 — Replenish Create: silent HTTP 200 when idempotency guard skips creation

**Ticket:** [SBDEV-2690](https://app.clickup.com/t/868kfamn0)
**Project:** wms2 | **Version:** v2 (`wms2-api`, Java 21 / Spring Boot 3.5.9) | **Type:** bugfix (API contract / UX)
**Priority:** high
**Status:** Approved — reviewed & signed off by Architect + Critic (2026-07-22); all APPROVE-WITH-CHANGES items applied (see §12 Review Log)
**Date:** 2026-07-22

> **Follow-up to the "Graceful Handling" half of** [[260709-duplicate-replenishment-orders-concurrent-generation]] (commit `a6b8d6bf`, 2026-02-16). That work added an idempotency guard to `ReplenishGeneratorService.calculateOrder()` that **silently returns `null`** when a pending order already exists for the same item + destination. The admin "Create Replenishment Request" path (`ReplenishorderService.create` → `ReplenishOrderController.create`) relays that `null` and returns **HTTP 200 with an empty body** — so the operator sees "success" while nothing was persisted. This plan makes the skip **observable at the API boundary** (HTTP 409 + a message naming the blocking order). The idempotency guard itself is correct and stays intact.

> **🚦 Scope note:** this plan changes the API response **only on the idempotency-skip path**. The stale order `REPL049787` (PROCESSABLE since 2025-03-10, holding a 12-unit reservation) that triggered the incident is handled as **ops data cleanup**, not code — see §5.1 and §9. Why stale PROCESSABLE replenish orders accumulate is flagged for a **separate investigation**, not designed here.

---

## 0. Affected sites (enumeration before drafting)

Enumerated via `grep -rn "calculateOrder" src/main/java` and `grep -rn "\.create(" ...ReplenishOrder...`.

| # | File:line | Construct | Same root-cause? | In-scope this plan? |
|---|-----------|-----------|------------------|----------------------|
| 1 | `service/ReplenishorderService.java:89-91` | `create()` — `if (order == null) return null;` (admin path) | **yes — the bug** | **yes** (Fix C) |
| 2 | `controller/ReplenishOrderController.java:240-260` | `create()` — returns `ResponseEntity.ok(repOrder)` with `repOrder == null` | **yes — the bug surface** | **yes** (Fix D) |
| 3 | `service/ReplenishGeneratorService.java:129-140` | idempotency guard — inline loop, `return null` | source of the null | **yes** (Fix B — extract, behavior unchanged) |
| 4 | `service/mobile/MobileReplenishService.java:592-595` | mobile `requestReplenish` — `calculateOrder(...)` then `if (order == null) return null;` | same null contract, **different surface** | **no** — mobile intentionally returns null → device shows "nothing to replenish"; out of scope, verified unaffected |
| 5 | `service/ReplenishGeneratorService.java:80` | `refillFixedLocations` loop — return value **ignored**, wrapped in `try/catch(FacadeException)` | consumes null harmlessly | **no** — no behavior change (calculateOrder still returns null) |
| 6 | `service/ReplenishGeneratorService.java:104` | `refillSingleFixedLocation` — return value **ignored** | consumes null harmlessly | **no** — unaffected |
| 7 | `service/job/ReplenishOrderJobService.java:97` | `generateReplenishmentForItemDataWithoutFixedAssignment` — return **ignored** | consumes null harmlessly | **no** — unaffected |
| 8 | `service/job/ReplenishOrderJobService.java:193` | `generateReplenishmentForItemDataWithFixedAssignment` — return **ignored** | consumes null harmlessly | **no** — unaffected |

**Key architectural invariant:** `calculateOrder()`'s `null` contract must NOT change — 5 of 6 call sites (rows 4-8) rely on `null` meaning "skip, no order today." The fix therefore lives entirely in the **admin `create` path** (rows 1-2), which reinterprets that `null` as a client-facing 409. Row 3 is a pure refactor (extract the predicate so the `create` path can name the blocking order) with identical runtime behavior.

---

## 1. Problem Statement

**User-visible symptom (reported 2026-07-22, WineCo tenant, v2):**
On **Internal Ops → Replenishment**, operator clicked **Create Replenishment Request** with:

- Pickable Location = `00-C02`
- Qty Requested = `6`
- Priority = `Medium`

The UI reported the request **succeeded**. Searching the SKU `23RHRSBTL` afterward returned **no new replenishment order**. The order was never persisted.

**Reproduction:**
1. Ensure a pending (state `< 700 FINISHED`) replenish order already exists for the item assigned to the pickable location, with the same destination.
2. POST `/v3/replenishOrder/create` with that pickable location (frontend resolves item from its fixed-location assignment).
3. Observe: HTTP **200**, empty body, **no new `replenishorder` row**.

### DB verification (mandatory gate — `db_verified: true`)

Run live against `wms2-wineco-dev` (MCP `mcp__wms2-wineco-dev__execute_sql`) on 2026-07-22:

**a. Pickable location `00-C02` and its fixed assignment resolve to SKU `23RHRSBTL`:**
```sql
SELECT id, name, area_id, client_id FROM location WHERE name = '00-C02';
-- → id=63802, area_id=51553, client_id=0

SELECT id, item_nr, client_id FROM itemdata WHERE item_nr = '23RHRSBTL';
-- → id=853882310, client_id=55750

SELECT id, active, upperbound, assignedlocation_id, itemdata_id
FROM fix_location_assignment WHERE assignedlocation_id = 63802;
-- → id=854948222, active=true, upperbound=84, itemdata_id=853882310  ✅ 00-C02 ⇒ 23RHRSBTL
```

**b. A pending order already blocks this item + destination (the guard's match):**
```sql
SELECT id, number, state, destination_id, itemdata_id, created, modified
FROM replenishorder WHERE id = 20881633;
-- → number=REPL049787, state=300 (PROCESSABLE), destination_id=63802,
--    itemdata_id=853882310, created=2025-03-10, modified=2025-12-08

SELECT state, count(*) FROM replenishorder WHERE itemdata_id = 853882310 GROUP BY state;
-- → state 300: 1  (REPL049787 — the blocker)
--   state 800: 5  (CANCELED — 800 > 700, do NOT match the guard)
```

State constants (`service/WmsConstants.java`): `PROCESSABLE=300`, `FINISHED=700`, `CANCELED=800`. The guard queries `findByStateLessThanAndItemdataId(FINISHED /*700*/, itemDataId)` → returns REPL049787 (`300 < 700`), same destination `63802` → **guard fires, `calculateOrder` returns `null`**. This is the exact data condition that reproduces the silent success. Confirmed at the DB level.

---

## 2. Root Cause Analysis

### Bug 1 — `calculateOrder` returns `null` on idempotency skip; callers on the admin path treat `null` as success

**`service/ReplenishGeneratorService.java:129-140`** (the guard, added `a6b8d6bf`):
```java
// Idempotency: skip if a pending replenish order already exists for same item + destination
List<Replenishorder> existingOrders = replenishorderRepository.findByStateLessThanAndItemdataId(
    WmsConstants.State.FINISHED, itemDataId);
for (Replenishorder existing : existingOrders) {
    boolean sameDestination = (destinationId == null && existing.getDestinationId() == null)
        || (destinationId != null && destinationId.equals(existing.getDestinationId()));
    if (sameDestination) {
        LOG.debug("Skipping: pending replenish order {} already exists ...", existing.getNumber(), ...);
        return null;   // ← correct for jobs/mobile; ambiguous for the admin create path
    }
}
```
`null` here is a **legitimate "no-op today"** signal for the scheduled job and mobile paths (rows 4-8 in §0). The defect is that the admin create path does not distinguish it from a real result.

**`service/ReplenishorderService.java:88-91`** (relays `null`):
```java
Replenishorder order = replenishGeneratorService.calculateOrder(item.getId(), mOrder.getAmountRequested(), loc.getId(), mOrder.getPriority());
if (order == null) {
    return null;      // ← swallows the skip, returns null to the controller
}
return order;
```

**`controller/ReplenishOrderController.java:240-260`** (turns `null` into HTTP 200):
```java
Replenishorder repOrder = null;
try {
    repOrder = replenishorderService.create(order);
} catch (BusinessException e) { errors.add(getErrorMessage("Business Error", e.getLocalizedMessage())); }
  catch (FacadeException e)   { errors.add(getErrorMessage("Runtime Error",  e.getLocalizedMessage())); }

if (errors.size() == 0){
    return ResponseEntity.ok(repOrder);   // ← repOrder == null → HTTP 200, empty body
} else { ... }
```
No exception is thrown on the skip, so `errors` is empty and the method returns `ResponseEntity.ok(null)`. The frontend interprets **200** as success. **This is the whole bug: a silent, unobservable no-op presented as success.**

**Why the operator's post-search found nothing:** the new order was never created (correctly — the guard blocked it). The pre-existing blocker `REPL049787` *is* an open order (state `300 < PALLETIZED 670`) and the open-tab query (`ReplenishorderRepository.getOpenViewByKeyword`) matches on `i.item_nr`, so it should appear on the **Open** tab when searching `23RHRSBTL`; a "found nothing" result means the operator was on the **Closed** tab (filters `state ≥ FINISHED`, excluding 300) or had a client/section filter applied. This is a UI-search nuance, not part of the fix.

**Not a transaction/OSIV bug.** `create` is correctly `@Transactional(value = "tenantTransactionManager", ...)` and `calculateOrder` is `REQUIRES_NEW`. The guard's `return null` performs no writes, so there is nothing to roll back — the failure is purely in the response contract, not in persistence.

---

## 3. The Regression Chain

| Commit | Date | Author | Effect |
|--------|------|--------|--------|
| `a6b8d6bf` | 2026-02-16 | Nam Park | "fix phase 3 concurrency issues: … replenish idempotency" — **added** the guard in `calculateOrder` that returns `null` on a duplicate. Prevented duplicate orders (correct) but introduced the silent-200 side effect on the admin path. |
| v2 port `98732de` / PR #70 → `c8f3f74` | 2026-07-12 | — | "Duplicate Replenishment Orders — Index-Backed + Graceful Handling" ([[260709-duplicate-replenishment-orders-concurrent-generation]]) consolidated the guard. The "graceful handling" covered the **job** path (log + continue); the **admin create** path's response contract was never updated. |

This plan closes the gap the "graceful handling" work left open on the synchronous (admin) surface. It does **not** revert or weaken the guard.

---

## 4. Architecture Overview

```
POST /v3/replenishOrder/create  (super-admin / inventory-manager)
        │  ReplenishMobileOrderDto { clientNumber, itemNumber(=23RHRSBTL, resolved by FE from 00-C02),
        │                            destinationLocationName(=00-C02), amountRequested(=6), priority(=Medium) }
        ▼
ReplenishOrderController.create()                         controller/ReplenishOrderController.java:240
        │  try { replenishorderService.create(order) }
        ▼
ReplenishorderService.create()   @Transactional(tenantTransactionManager)   service/ReplenishorderService.java:83
        │  calculateOrder(item, amount, destination, prio)
        ▼
ReplenishGeneratorService.calculateOrder()  @Transactional(REQUIRES_NEW)     service/ReplenishGeneratorService.java:119
        │  ── idempotency guard (line 129-140) ── pending order for item+dest? ──► return null  ◄── the skip
        │  else … build + save Replenishorder, reserve stock ──► return order
        ▼
   null  ─────────────────────────────►  create() returns null  ──►  controller returns HTTP 200 (empty)  ◄── BUG
```

**Key files**

| File | Lines | Role |
|------|-------|------|
| `controller/ReplenishOrderController.java` | 240-260 | `create` endpoint; local try/catch → `ResponseEntity`. **Fix D** (new catch → 409). |
| `service/ReplenishorderService.java` | 83-92 | admin `create`; relays generator result. **Fix C** (throw on null). |
| `service/ReplenishGeneratorService.java` | 119-199 | `calculateOrder`; guard at 129-140. **Fix B** (extract predicate; null contract unchanged). |
| `exceptions/RestExceptionHandler.java` | 118-159 | maps `BusinessException`→422, optimistic/pessimistic lock→409 via `ProblemDetail`. **Reference only** — not modified (see §3 alt in Fix D). |
| `exceptions/BusinessException.java` / `FacadeException.java` | — | both `extends Exception` (checked). New exception modeled on these. |

---

## 5. Fix Design

Design goal: make the idempotency skip **observable at the admin API boundary** with the exact body shape already produced by this controller's error path, without altering `calculateOrder`'s `null` contract.

### Fix A — New exception `DuplicateReplenishmentException`

New file `exceptions/DuplicateReplenishmentException.java`. Checked (`extends Exception`), mirroring `BusinessException`/`FacadeException`. **Deliberately does NOT extend `BusinessException`.**

> **Why a distinct type (accurate framing).** If it extended `BusinessException`, the controller's existing `catch (BusinessException)` would catch it and return **HTTP 200 with a populated `{errors:[…]}` body** — a *visible* error (the same shape the no-stock `FacadeException` path already returns), **not** the silent empty-200 that is this bug. So extending `BusinessException` would not "reintroduce the bug"; it would just keep an error at HTTP 200. We choose a distinct type + **409** for **correct HTTP semantics** (a duplicate is a conflict, not a success) and better **retry/idempotency** behavior for API consumers — see Fix D and §9. The verify script still asserts it does not extend `BusinessException`, because reaching a 409 requires escaping that local catch.

```java
package net.aim_ai.wms.exceptions;

/** Thrown when a replenishment create request is skipped because a pending
 *  replenish order already exists for the same item + destination (idempotency guard). */
public class DuplicateReplenishmentException extends Exception {
    private final String existingOrderNumber;   // may be null if the blocker vanished between check and re-read

    public DuplicateReplenishmentException(String itemNr, String destinationName, String existingOrderNumber) {
        super(existingOrderNumber != null
            ? String.format("A pending replenishment already exists for item %s at %s: %s",
                            itemNr, destinationName, existingOrderNumber)
            // TOCTOU: blocker finished between the guard read and this re-read — do not assert it still
            // exists; the request may now succeed on retry.
            : String.format("Replenishment for item %s at %s was not created due to a concurrent pending order. Please retry.",
                            itemNr, destinationName));
        this.existingOrderNumber = existingOrderNumber;
    }

    public String getExistingOrderNumber() { return existingOrderNumber; }
}
```

### Fix B — Extract the idempotency predicate (behavior-preserving refactor)

**`service/ReplenishGeneratorService.java`** — extract lines 129-140 into a reusable, public lookup so the create path can name the blocking order without duplicating the predicate.

**Before** (inline in `calculateOrder`):
```java
List<Replenishorder> existingOrders = replenishorderRepository.findByStateLessThanAndItemdataId(
    WmsConstants.State.FINISHED, itemDataId);
for (Replenishorder existing : existingOrders) {
    boolean sameDestination = (destinationId == null && existing.getDestinationId() == null)
        || (destinationId != null && destinationId.equals(existing.getDestinationId()));
    if (sameDestination) {
        LOG.debug("Skipping: pending replenish order {} already exists ...", existing.getNumber(), ...);
        return null;
    }
}
```
**After:**
```java
Optional<Replenishorder> blocking = findBlockingPendingOrder(itemDataId, destinationId);
if (blocking.isPresent()) {
    LOG.debug("Skipping: pending replenish order {} already exists for itemData={} destination={}",
              blocking.get().getNumber(), itemData.getItemNr(), destinationId);
    return null;                                   // ← unchanged contract for jobs/mobile
}
```
```java
/** Returns the first pending (state &lt; FINISHED) replenish order for this item + destination, if any.
 *  Used by calculateOrder's idempotency guard and by the admin create path to name the blocker. */
public Optional<Replenishorder> findBlockingPendingOrder(Long itemDataId, Long destinationId) {
    return replenishorderRepository.findByStateLessThanAndItemdataId(WmsConstants.State.FINISHED, itemDataId)
        .stream()
        .filter(e -> (destinationId == null && e.getDestinationId() == null)
                  || (destinationId != null && destinationId.equals(e.getDestinationId())))
        .findFirst();
}
```
**Why:** identical runtime behavior for every existing caller (still returns `null` on a match), zero risk to the job/mobile/refill paths, and a single source of truth for the predicate.

### Fix C — `ReplenishorderService.create` throws instead of returning null

**`service/ReplenishorderService.java:83-92`**

**Before:**
```java
@Transactional(value = "tenantTransactionManager", rollbackFor = {BusinessException.class, FacadeException.class})
public Replenishorder create(ReplenishMobileOrderDto mOrder) throws FacadeException, BusinessException {
    Client client = clientService.getByNumber(mOrder.getClientNumber());
    Itemdata item = itemdataService.findByClientIdAndItemNr(client.getId(), mOrder.getItemNumber())
        .orElseThrow(() -> new EntityNotFoundException("ItemData not found by clientIdAndItemNr: " + client.getId()));
    Location loc = locationService.getByName(mOrder.getDestinationLocationName());

    Replenishorder order = replenishGeneratorService.calculateOrder(item.getId(), mOrder.getAmountRequested(), loc.getId(), mOrder.getPriority());
    if (order == null) {
        return null;
    }
    return order;
}
```
**After:**
```java
@Transactional(value = "tenantTransactionManager", rollbackFor = {BusinessException.class, FacadeException.class, DuplicateReplenishmentException.class})
public Replenishorder create(ReplenishMobileOrderDto mOrder)
        throws FacadeException, BusinessException, DuplicateReplenishmentException {
    Client client = clientService.getByNumber(mOrder.getClientNumber());
    Itemdata item = itemdataService.findByClientIdAndItemNr(client.getId(), mOrder.getItemNumber())
        .orElseThrow(() -> new EntityNotFoundException("ItemData not found by clientIdAndItemNr: " + client.getId()));
    Location loc = locationService.getByName(mOrder.getDestinationLocationName());

    Replenishorder order = replenishGeneratorService.calculateOrder(item.getId(), mOrder.getAmountRequested(), loc.getId(), mOrder.getPriority());
    if (order == null) {
        // Idempotency guard skipped creation — name the blocking order so the operator sees why.
        String blockingNumber = replenishGeneratorService
            .findBlockingPendingOrder(item.getId(), loc.getId())
            .map(Replenishorder::getNumber)
            .orElse(null);
        throw new DuplicateReplenishmentException(item.getItemNr(), loc.getName(), blockingNumber);
    }
    return order;
}
```
Added `DuplicateReplenishmentException` to `rollbackFor` for symmetry (there is nothing to roll back on this path, but it keeps the annotation honest if future writes are added before the guard check).

### Fix D — `ReplenishOrderController.create` returns HTTP 409

**`controller/ReplenishOrderController.java:240-260`** — add a dedicated catch that returns **409** with the **same `{errors:[…]}` body shape** the controller already emits (chosen so the frontend's existing error parser keeps working; see §9).

**After:**
```java
@PostMapping(path = "/create", produces = "application/json")
public ResponseEntity<Object> create(@RequestBody ReplenishMobileOrderDto order, @AuthenticationPrincipal Principal principal)
        throws WebserviceBusinessExceptionClientSide {
    List<Map<String, String>> errors = new ArrayList<>();
    Map<String, Object> errorMap = new HashMap<>();

    Replenishorder repOrder = null;
    try {
        repOrder = replenishorderService.create(order);
    } catch (DuplicateReplenishmentException e) {
        errors.add(getErrorMessage("Duplicate replenishment", e.getLocalizedMessage()));
        errorMap.put("errors", errors);
        return ResponseEntity.status(HttpStatus.CONFLICT).body(errorMap);   // ← 409, not silent 200
    } catch (BusinessException e) {
        errors.add(getErrorMessage("Business Error", e.getLocalizedMessage()));
    } catch (FacadeException e) {
        errors.add(getErrorMessage("Runtime Error", e.getLocalizedMessage()));
    }

    if (errors.size() == 0) {
        return ResponseEntity.ok(repOrder);
    } else {
        errorMap.put("errors", errors);
        return ResponseEntity.ok(errorMap);
    }
}
```
Add `import org.springframework.http.HttpStatus;` if not already present.

`getErrorMessage(...)` emits `{field, message}`, so the 409 body is `{errors:[{field:"Duplicate replenishment", message:"A pending replenishment already exists … REPL049787"}]}`.

**Alternative considered & rejected:** route `DuplicateReplenishmentException` through `RestExceptionHandler` as a `ProblemDetail` 409. Note this would actually be **consistent with the sibling 409 handlers** for optimistic/pessimistic lock conflicts (`RestExceptionHandler.java:144-159`), which is a real point in its favor. Rejected on a narrower ground: it returns a **`ProblemDetail`** body, whereas this endpoint's frontend parser already consumes the `{errors:[…]}` shape (proven by the no-stock `FacadeException` path, which returns 200 + `{errors:[…]}`). Reusing `{errors:[…]}` means a not-yet-updated frontend that parses `errors[]` degrades gracefully. This endpoint is **not** internally uniform today (Business/Facade errors return 200+`{errors}`; this 409 is its first non-2xx) — so the justification is *body-shape reuse for the existing FE parser*, not "uniformity." If the team later standardizes all replenish errors on `ProblemDetail`, revisit.

> **Compile-safety of the checked exception.** `ReplenishorderService.create` has **exactly one caller** — `ReplenishOrderController.create` (`ReplenishOrderController.java:247`); no other service that injects `ReplenishorderService` calls `.create`. So adding `DuplicateReplenishmentException` to the `throws` clause (Fix C) forces a change at only this one site (the new catch here), with no hidden compile breakage.

---

## 6. File Change Summary

| File | Change Type | Description |
|------|-------------|-------------|
| `exceptions/DuplicateReplenishmentException.java` | **New** | Checked exception carrying `existingOrderNumber` + formatted message. |
| `service/ReplenishGeneratorService.java` | Modify | Extract `findBlockingPendingOrder(...)`; `calculateOrder` calls it (null contract unchanged). |
| `service/ReplenishorderService.java` | Modify | `create` throws `DuplicateReplenishmentException` on the skip instead of returning null; add to `throws` + `rollbackFor`. |
| `controller/ReplenishOrderController.java` | Modify | New `catch (DuplicateReplenishmentException)` → `409 CONFLICT` with `{errors:[…]}` body. |
| `src/test/.../unit/service/ReplenishGeneratorServiceUnitTest.java` | Modify | Assert `findBlockingPendingOrder` + regression: `calculateOrder` still returns null on a match. |
| `src/test/.../unit/service/ReplenishorderServiceUnitTest.java` | Modify | Assert `create` throws `DuplicateReplenishmentException` (with number) on skip; returns order on success. |
| `src/test/.../unit/controller/ReplenishOrderControllerUnitTest.java` | Modify | Assert POST `/create` → 409 + errors body when service throws; 200 on success (regression). |

---

## 7. Implementation Steps

### 5.1 Prerequisites

| Concern | Applies? | Detail |
|---|---|---|
| DB state | **Yes (ops, out of code scope)** | Stale blocker `REPL049787` (state 300, reserving 12 units since 2025-03) still blocks new requests for `23RHRSBTL`→`00-C02`. After this fix deploys, the operator will get a 409 naming it — but they still can't create until it is resolved. **Cancel/finish REPL049787** (state→800) via ops, or triage why it never completed. Track separately. |
| Frontend coordination | **Done — companion PR** | Confirmed the page is `wms2-web-ui` (Nuxt), action `createReplenishOrder` in `store/internalOps/replenishments.js`. Companion PR [wms2-web-ui#24](https://github.com/SiteBossInc/wms2-web-ui/pull/24) renders the 409 `errors[].message` (shared `apiErrorMessage` helper across all 13 replenish actions). Full detail in §11. Land with / after the API PR (#89); UI degrades gracefully if it ships first. |
| Feature flags / sysprops | No | None. |
| DB migration | No | No schema change; reuses existing `findByStateLessThanAndItemdataId`. |
| Deploy order | **Yes** | Ship API first (409 is strictly more informative than the current silent 200); FE handling can follow. A FE that doesn't yet special-case 409 will show its generic error — still better than a false success. |
| External systems | No | No OMS/outbox interaction on this path. |

### Ordered steps (each atomically committable)

1. **Add `DuplicateReplenishmentException`** (Fix A). Compile.
2. **Extract `findBlockingPendingOrder`** in `ReplenishGeneratorService` and route `calculateOrder`'s guard through it (Fix B). Run `ReplenishGeneratorServiceUnitTest` — must stay green (behavior unchanged).
3. **Throw from `ReplenishorderService.create`** on the skip (Fix C). Update `throws` + `rollbackFor`.
4. **Add the 409 catch** in `ReplenishOrderController.create` (Fix D) + `HttpStatus` import.
5. **Tests** (§8) — service + controller. Run `mvn test -Dtest=ReplenishGeneratorServiceUnitTest,ReplenishorderServiceUnitTest,ReplenishOrderControllerUnitTest`.
6. **Run the verify script with tests** — `RUN_MVN=1 bash sbdocs/9-System/scripts/verify-SBDEV-2690-replenish-create-silent-success-on-idempotency-skip.sh` → must be `0 fail` (RUN_MVN=1 is required so the three unit tests actually execute; see §9b).
7. **`mvn verify`** (full suite incl. Testcontainers) before the branch leaves.

---

## 8. Testing Plan

### Unit

- **`ReplenishGeneratorServiceUnitTest`**
  - `findBlockingPendingOrder_returnsPendingOrder_whenSameItemAndDestination()` — repo returns a state-300 order with matching `destinationId` → `Optional` present with that order.
  - `findBlockingPendingOrder_empty_whenDestinationDiffers()` — matching item, different destination → empty.
  - `calculateOrder_stillReturnsNull_whenBlockingOrderExists()` — **regression**: guard behavior unchanged (protects rows 4-8).
- **`ReplenishorderServiceUnitTest`**
  - `create_throwsDuplicateReplenishment_whenGuardSkips()` — mock `calculateOrder` → null, `findBlockingPendingOrder` → `Optional.of(order#REPL049787)`; assert `DuplicateReplenishmentException` thrown and `getExistingOrderNumber()="REPL049787"` and message contains it.
  - `create_throwsWithNullNumber_whenBlockerVanished()` — `calculateOrder` → null, `findBlockingPendingOrder` → empty; exception thrown, `existingOrderNumber == null`, message has no number.
  - `create_returnsOrder_onSuccess()` — **regression**: non-null order relayed unchanged.
- **`ReplenishOrderControllerUnitTest`** (extends `BaseControllerUnitTest` — the existing class it already extends; there is no `BaseControllerTest`)
  - `create_returns409_whenDuplicate()` — service stubbed to throw `DuplicateReplenishmentException("23RHRSBTL","00-C02","REPL049787")`; MockMvc `POST /v3/replenishOrder/create` → status 409, JSON `$.errors[0].message` contains `REPL049787`.
  - `create_returns200_onSuccess()` — **regression**: service returns an order → 200 with the order body.

Mockito is modern in v2 (no v1 `mockStatic` restriction); all mocks are instance-level.

### Integration

- Not strictly required — no new SQL, no new repository method (reuses `findByStateLessThanAndItemdataId`, already covered by `ReplenishorderRepositoryIntegrationTest`). If a Testcontainers end-to-end is desired, extend an existing replenish IT to POST `/create` twice against a seeded pending order and assert the second call → 409. (Optional; unit + controller coverage is sufficient for this contract change.)

### Regression

- `mvn test -Dtest=ReplenishGeneratorServiceUnitTest,ReplenishOrderJobServiceUnitTest,MobileReplenishServiceUnitTest` — confirm job + mobile paths unaffected by the Fix B extraction.

### Manual test plan

| Scenario | Environment | Steps | Expected Result | Pass/Fail |
|---|---|---|---|---|
| Duplicate blocked, observable | dev (wms2-wineco-dev) | With REPL049787 still pending, Internal Ops → Create Replenishment Request for `00-C02`, qty 6 | HTTP **409**; UI shows a message naming `REPL049787`; **no new row** in `replenishorder` | |
| Happy path after cleanup | dev | Cancel REPL049787 (state→800), retry the create | HTTP **200**; new `replenishorder` row (state 300) for item 853882310, dest 63802; searchable by `23RHRSBTL` on Open tab | |
| No stock still errors as before | dev | Create for an item+destination with no unlocked replenishable stock (no pending order) | HTTP 200 with `{errors:[{field:"Runtime Error", message:…}]}` (unchanged `FacadeException` path; `getErrorMessage` emits keys `field`+`message`, not `title`) | |
| Job/mobile unaffected | dev | Trigger `ReplenishOrderJob` and a mobile `/v3/replenish/requestAmount` for an item with a pending order | Job logs skip + continues; mobile returns "nothing to replenish" (null DTO) — no 409, no exception | |

---

## 9. Risks & Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| Frontend not handling 409 shows a generic error toast | Medium — operator sees an error instead of a friendly message, but no longer a false success | Ship the paired FE change to render `errors[].message`; API-first deploy is safe because 409+message strictly improves on silent 200. §5.1. |
| `DuplicateReplenishmentException` accidentally extends `BusinessException` | High — would be swallowed by the existing catch → back to HTTP 200 (bug reintroduced) | Explicit `extends Exception`; verify script asserts it does NOT extend BusinessException; controller catch ordering irrelevant (distinct type). |
| Changing `calculateOrder`'s null contract | High — would break scheduled job / mobile / refill (rows 4-8) | Fix B is a **behavior-preserving extraction**; `calculateOrder` still returns null on a match. Regression tests in §8 guard this. |
| TOCTOU: blocker finishes between `calculateOrder` (returns null) and `findBlockingPendingOrder` re-read | Low — rare; message would omit the order number | Handled: `existingOrderNumber == null` produces a valid "already exists" message without a number; still a correct 409. |
| Response body shape (`{errors:[…]}` vs `ProblemDetail`) inconsistency across the API | Low | Deliberately reuses this endpoint's existing `{errors:[…]}` shape; alternative documented in Fix D for a future standardization pass. |
| Stale REPL049787 remains after deploy | Medium — operator still can't create until it's cleared | Out of scope by decision; §5.1 ops cleanup + flagged for a separate "stale PROCESSABLE replenish" investigation. |

### Horizontal Scalability Validation (mandatory for v2)

| # | Concern | Verdict | Evidence |
|---|---------|---------|----------|
| 1 | In-JVM state | **No** | No new static/ThreadLocal/Caffeine/map state; only a stateless lookup + throw. |
| 2 | Connection pool math | **No** | Adds one extra SELECT (`findBlockingPendingOrder`) only on the already-failing skip path, inside the existing `create` tx. No new connection. |
| 3 | Scheduled jobs | **N/A** | No `@Scheduled` change. |
| 4 | Long transactions | **No** | No external I/O added; `create` tx unchanged in span. |
| 5 | Request affinity | **N/A** | Stateless request/response. |
| 6 | Retry / idempotency | **Yes (improves)** | A client retry of a create that already succeeded now deterministically returns 409 (order exists) instead of a silent 200 — safer under replay. `IdempotencyFilter` does not cover `/replenishment/**` (only `/rest/**`), so this is the meaningful idempotency signal for this endpoint. |
| 7 | Tenant context | **No** | Runs in HTTP request scope; `tenantTransactionManager` unchanged. |
| 8 | Distributed lock correctness | **N/A** | No lock added; guard is a read + throw. |
| 9 | Cache invalidation | **No** | `replenishorder` is not in `CacheConfig` (confirmed in [[SBDEV-2610-move-unitload-false-reserved-block]]) — no `@CacheEvict` needed. |
| 10 | External notifications | **N/A** | No OMS/outbox send on this path. |

### v2-only constraint checklist

| # | Constraint | Verdict | Evidence |
|---|---|---|---|
| 1 | OSIV disabled | **No lazy risk** | `findBlockingPendingOrder` reads scalar fields (`getNumber`, `getDestinationId`) inside `create`'s tx; no lazy association traversal outside a tx. |
| 2 | Transaction manager | **Satisfied** | `create` already uses `@Transactional(value="tenantTransactionManager", …)`; unchanged. |
| 3 | `readOnly=true` | **N/A** | `create` is a write path. |
| 4 | Caffeine cache invalidation | **N/A** | `replenishorder` not cached (row 9 above). |
| 5 | Jakarta namespace | **Satisfied** | New exception uses no `javax.*`; no ports from v1. |
| 6 | H2-compatible test SQL | **N/A** | No new SQL; unit tests mock the repository. |
| 7 | `BaseControllerUnitTest` for controller changes | **Satisfied** | New controller test lives in the existing `ReplenishOrderControllerUnitTest`, which already extends `BaseControllerUnitTest` (`src/test/.../common/base/BaseControllerUnitTest.java`). Note: there is **no** class named `BaseControllerTest`. |
| 8 | Micrometer metrics | **Optional** | Could add a `wms2.replenish.create.duplicate` counter in the controller catch; deferred as a nice-to-have, not required for the fix. |

### Completeness checklist

| # | Concern | Considered? |
|---|---|---|
| 0 | DB verified | ✓ §1 — `execute_sql` on wms2-wineco-dev proved REPL049787 (state 300) blocks item 853882310 + dest 63802; `db_verified: true`. |
| 1 | All callsites enumerated | ✓ §0 — 8 sites; rows 1-3 in-scope, 4-8 excluded with rationale. |
| 2 | Adjacent bugs | ✓ §0 rows 4-8 — mobile has the same null contract but a **correct** surface (returns null → "nothing to replenish"); no fix needed. |
| 3 | Backward compatibility | ✓ §9 — response contract changes only on the skip path (200→409, body `null`→`{errors:[…]}`); success + other-error paths unchanged. FE coordination flagged. |
| 4 | Concurrency | ✓ §9 rows 2,6 + TOCTOU risk — guard unchanged; re-read tolerates a vanished blocker. |
| 5 | Multi-tenant | ✓ §9 v2-checklist #2 — tenant TM unchanged; per-tenant DB. |
| 6 | Error handling | ✓ Fix C/D — new throw has a dedicated 409 handler in the controller. |
| 7 | Observability | ✓ existing `LOG.debug` in the guard names the order; optional Micrometer counter (v2-checklist #8). |
| 8 | Rollback / migration | ✓ §5.1 — no migration, no flag; ops cleanup of REPL049787 tracked separately. |
| 9 | Test coverage | ✓ §8 — service + controller unit tests, regression for job/mobile. |
| 10 | Cross-version (v1↔v2) | no — v1/wms-api has its own replenish create path and the idempotency guard was a v2 concurrency fix; a v1 counterpart is out of scope unless v1 exhibits the same silent-200 (not observed). |

---

## 9b. Acceptance

**Final acceptance = `RUN_MVN=1 bash sbdocs/9-System/scripts/verify-SBDEV-2690-replenish-create-silent-success-on-idempotency-skip.sh` reports `Result: N pass, 0 fail`.** `RUN_MVN=1` is **required** at the final gate — without it the three `mvn_test_passes` checks skip. The script asserts:
- **positive** — the new exception exists; `findBlockingPendingOrder` extracted; `create` throws + declares `DuplicateReplenishmentException`; controller catches it and returns `HttpStatus.CONFLICT`; `HttpStatus` imported;
- **negative** — `create` no longer has the silent `if (order == null) { return null; }`; the new exception does NOT extend `BusinessException`;
- **test presence (static, always-on floor)** — the new test methods exist in the three test classes (closes the "code shaped right, tests never written" false-pass);
- **test execution (`RUN_MVN=1`)** — `ReplenishGeneratorServiceUnitTest`, `ReplenishorderServiceUnitTest`, `ReplenishOrderControllerUnitTest` pass.

---

## 10. Implementation Status

**Implemented 2026-07-22** on branch `bugfix/SBDEV-2690-replenish-create-silent-success` (off `develop`), commit **`f511a315`**.

- **Fix A** — `exceptions/DuplicateReplenishmentException.java` (new, checked, not a `BusinessException`).
- **Fix B** — `ReplenishGeneratorService.findBlockingPendingOrder(...)` extracted; `calculateOrder` guard delegates to it (null contract preserved). Stale `calculateOrder` Javadoc corrected (code-review LOW).
- **Fix C** — `ReplenishorderService.create()` throws `DuplicateReplenishmentException` (naming the blocker; retry message on TOCTOU); added to `throws` + `rollbackFor`.
- **Fix D** — `ReplenishOrderController.create()` catches it → HTTP 409 with `{errors:[…]}` body; `HttpStatus` imported.

**Tests added (7):** `ReplenishGeneratorServiceUnitTest` (`findBlockingPendingOrder_returnsMatch_andSkipsNonMatch`, `calculateOrder_stillReturnsNull_whenBlockingOrderExists`); `ReplenishorderServiceUnitTest.Create` (`create_throwsDuplicateReplenishment_whenGuardSkips`, `create_throwsWithRetryMessage_whenBlockerVanished`, `create_returnsOrder_onSuccess`); `ReplenishOrderControllerUnitTest.CreateDuplicateHandling` (`create_returns409_whenDuplicate`, `create_returns200_onSuccess`).

**Verification:**
- `mvn test` on the three classes → `Tests run: 109, Failures: 0, Errors: 0, Skipped: 0` — BUILD SUCCESS.
- `RUN_MVN=1 bash sbdocs/9-System/scripts/verify-SBDEV-2690-…sh` → **`Result: 19 pass, 0 fail, 0 skip`**.
- Code-review (code-reviewer agent): **APPROVE** — 0 CRITICAL/HIGH/MEDIUM; 3 LOW (1 applied: Javadoc; 2 deferred: i18n message, duplicate read — both deliberate/acceptable) + 1 out-of-scope concurrency note (non-atomic guard → separate ticket).

**TDD-gate note:** endpoint corrected to `/v3/replenishOrder/create` (class `@RequestMapping("/v3/replenishOrder")`), not `/replenishment/create`.

---

## 11. Frontend companion (wms2-web-ui) — required to display the 409 message

**Repo:** `v2/wms2-web-ui` (Nuxt 2 / Vue 2). **PR:** [wms2-web-ui#24](https://github.com/SiteBossInc/wms2-web-ui/pull/24) → `develop`.

### Why it's needed (verified in code, not assumed)
The Internal Ops → Replenishment page is `components/internalOps/replenishment/open/createReplenishmentRequest.vue`, backed by the Vuex action `createReplenishOrder` in `store/internalOps/replenishments.js`. That action (and all 12 sibling actions) used a single generic catch:

```js
} catch (error) {
  this.$toast.error('Error: Request failed due to a network or server issue. Please retry.')
}
```

- `@nuxtjs/axios` rejects on any 4xx, and `plugins/axios.js`'s `onError` just re-rejects (no extraction). So the API fix's **HTTP 409** throws straight into this catch → the operator sees the **generic** text, never the actionable `A pending replenishment already exists: REPL049787` (which sits in `error.response.data.errors[0].message`).
- Pre-API-fix, the empty `200` body was falsy → the `else` branch fired `this.$toast.success('Replenish order created')` — **this is the frontend half of the original false-success bug.**

So the API PR (#89) alone removes the false success (409 → an error toast), but the *specific, useful* message requires this FE change.

### Change
- Add a module-level `apiErrorMessage(error)` helper: returns `error?.response?.data?.errors?.[0]?.message`, falling back to the existing generic string for genuine transport/500 errors with no structured body.
- Apply it to **all 13 catch blocks** in `store/internalOps/replenishments.js` (create, update, updateStockUnit, cancel, getStockUnits*, searches, …) — uniform fix, closes the message-quality gap for every replenish action, not just create.

### Tests
`test/store/internalOps/replenishments.spec.js` (3, green): (1) 409 → toasts the backend `errors[0].message`, no success toast / no list refresh; (2) network error → generic fallback; (3) success → `Replenish order created` + `searchOpenRequests` dispatch (regression). `npx jest` on the file: **3 pass**; ESLint 0 errors on the changed file.

### Deploy
Land with / after the API PR (#89). UI degrades gracefully if it ships first — behavior unchanged until the backend starts returning 409, then the specific message appears automatically.

---

## 12. Review Log

Two independent read-only review passes on 2026-07-22; both verified claims against live `wms2-api` source. Both returned **APPROVE WITH CHANGES** — no correctness blockers; the fix design (A–D) was confirmed sound, the §0 enumeration complete, the null-contract preservation correct, and `create`'s single-caller compile-safety independently verified.

| # | Reviewer | Finding | Severity | Resolution |
|---|----------|---------|----------|------------|
| 1 | Critic | Verify-script behavior tests were opt-in (`RUN_MVN=0` default) → `0 fail` reachable with zero test execution; nothing asserted the *new* tests exist | Major | Added always-on static `T-SRC1/2/3` presence checks; §9b + §7 step 6 now mandate `RUN_MVN=1` at final acceptance |
| 2 | Critic | Plan cited `BaseControllerTest` (does not exist) | Minor | Corrected to `BaseControllerUnitTest` in §8 and v2-checklist #7 |
| 3 | Critic | §8 manual scenario-3 body used key `title`; `getErrorMessage` emits `field`+`message` | Minor | Corrected to `{field:"Runtime Error", message:…}`; also clarified 409 body shape in Fix D |
| 4 | Critic | `create`'s single-caller compile-safety not stated | Nit | Added note in Fix D |
| 5 | Architect | Fix A / §9 overstated that extending `BusinessException` would "reintroduce the bug" (it yields a *visible* 200+`{errors}`, not the silent empty-200) | Should | Reframed Fix A: distinct type + 409 chosen for correct HTTP semantics + retry cleanliness, not to avoid reintroducing the bug |
| 6 | Architect | Fix D rejection rationale inaccurate ("uniformity"); endpoint is not uniform, and a ProblemDetail 409 would match sibling lock handlers | Should | Rewrote Fix D rationale to the honest ground (reuse `{errors:[…]}` shape the FE parser consumes); acknowledged the 409-ProblemDetail counter-precedent |
| 7 | Architect | Vanished-blocker (TOCTOU) message falsely asserts an order "exists" | Minor | Softened the `existingOrderNumber == null` message to retry-friendly wording |
| 8 | Architect + Critic | Frontend 409-handling should be a hard gate, with a fallback if it lags | Should | §5.1 frontend row upgraded to a tracked companion PR + documented graceful degradation (409 reuses `{errors:[…]}`, so an un-updated FE still shows an error, never a false success) |

**Not actioned (accepted as-is):**
- Skeptic/antithesis option B (throw `BusinessException` → 200+`{errors}`, zero FE change): rejected in favor of correct 409 semantics per the locked scope decision; tradeoff now documented in Fix A.
- Mobile `requestReplenish` "nothing to replenish" on the same null contract is a milder instance of the same confusion — deliberately out of scope (§0 row 4).
- Guard line-number drift (plan cites 129-140; actual 127-138) — within tolerance, not corrected.
