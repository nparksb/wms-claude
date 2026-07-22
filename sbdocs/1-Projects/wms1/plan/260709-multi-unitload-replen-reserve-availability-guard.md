---
title: "Multi-Unit-Load Replenishment — Reject Already-Reserved Unit Loads Up Front (Availability Guard, Not Gross-Stock Guard)"
ticket: ""
ticket_url: ""
type: bugfix
priority: high
status: implemented
project: [wms1]
version: v1
requester: "Nam Park"
created: 2026-07-09
updated: 2026-07-09
db_verified: true
related:
  - "[[wms1-multi-unitload-replenish]]"
  - "[[wms1-replenish-workflow]]"
  - "[[wms1-replenish-order-creation]]"
  - "[[wms1-stockunit-design]]"
  - "[[SBDEV-2512-partitionallowed-split-pick-overstock-guard]]"
tags:
  - plan
  - replenishment
  - multi-unitload
  - reservation
  - data-integrity
---

# Multi-Unit-Load Replenishment — Reject Already-Reserved Unit Loads Up Front (Availability Guard, Not Gross-Stock Guard)

**Ticket:** _(untracked — WineCo tester report)_
**Project:** wms1 | **Version:** v1/wms-api | **Type:** bugfix
**Priority:** High
**Status:** 📝 Draft (pending review)
**Date:** 2026-07-09

> **What the tester saw.** On mobile multi-unit-load replenishment, selecting **TWO** unit loads (ULs) to fulfill one replenishment request fails with a `FacadeException` `CANNOT_RESERVE_MORE_THAN_AVAILABLE`, rendered as **"Cannot reserve more than available (0.0000)"**. The per-UL entry gate accepted a UL whose stock was already fully reserved by a *different* open replenishment, so the reservation write downstream threw. The operator has no way to know the UL was unusable until the whole request blows up.

---

## 0. Affected sites (enumeration before drafting)

Enumerated via `grep -rn` over `src/main/java` for `fulfillMultipleUnitLoads`, `validateUnitLoadEntry`, `applyExplicitSourceToOrder`, `createOrderFromTemplate`, `reserveExplicitStockForOrder`, `changeReservedAmount`, `getAvailableamount`, `getStockunitId`; confirmed against the code and against `sbdocs/3-Resources/workflows/wms1-multi-unitload-replenish.md`.

| # | File:line | Construct | On the reserve path for multi-UL? | Root-cause locus? | In scope this plan? |
|---|-----------|-----------|-----------------------------------|-------------------|----------------------|
| 1 | `service/mobile/MobileReplenishService.java:869-893` | `validateUnitLoadEntry` — per-UL entry gate. **@889-890** checks **GROSS** stock: `matching.getAmount().compareTo(dto.getQty()) < 0` → `throw FacadeException("MsgTooMuchRequested")`. Never inspects reservation. | Yes — the up-front gate for **every** UL (loop @753-762) | **YES (root cause)** | **YES — EDITED** |
| 2 | `service/mobile/MobileReplenishService.java:732-794` | `fulfillMultipleUnitLoads` — entry point. Validation loop **@753-762** runs `validateUnitLoadEntry` for **ALL** ULs **before** any reservation (first reserve is @772). First UL → `applyExplicitSourceToOrder` @772; remaining ULs → `createOrderFromTemplate` @778-785. | Yes (orchestrator) | No — no logic change; it already validates all instructions up front (this is *why* the single guard in row 1 suffices) | No — context only |
| 3 | `service/mobile/MobileReplenishService.java:895-924` | `applyExplicitSourceToOrder` — **first UL only**. @900-912 releases the **template order's own current source** reservation (negates the old stock's *entire* `reservedamount`, `zeroIfNegative=true`) **before** re-reserving @923. | Yes (first UL reserve) | No — but it defines the **self-source edge case** the guard must tolerate (see §5) | No — no change; drives the self-source add-back in row 1 |
| 4 | `service/ReplenishGeneratorService.java:172-215` | `createOrderFromTemplate` — remaining ULs (i≥1). Reserves via `reserveExplicitStockForOrder` @211. Does **not** release any prior reservation. | Yes (remaining ULs reserve) | No — covered transitively: all ULs are validated at row 2's loop before this ever runs | No — no guard needed here (see §5 decision) |
| 5 | `service/ReplenishGeneratorService.java:164-170` | `reserveExplicitStockForOrder` → `changeReservedAmount(stock, amount, zeroIfNegative=false, ...)` | Yes (both paths funnel here) | No — additive reservation writer; correctly refuses over-reserve | No — no change |
| 6 | `service/StockunitBusinessService.java:363-400` | `changeReservedAmount` — **@382-383** `if (stock.getAmount().compareTo(newReservedAmount) < 0) throw FacadeException("CANNOT_RESERVE_MORE_THAN_AVAILABLE", String.valueOf(stock.getAvailableamount()))`. `newReserved = oldReserved + amount`; additive + non-forgiving. **This is where the (0.0000) surfaces.** | Yes (the throw site) | No — correctly guards the invariant; the bug is that a bad UL reaches it | No — no change (correct as-is; the fix moves rejection **earlier**) |
| 7 | `model/Stockunit.java:113-116` | `getAvailableamount()` `@Transient` = `amount.subtract(reservedamount)` | n/a | No — the availability primitive the fix will use | No — no change (consumed by the fix) |
| 8 | Self-source edge case | A selected UL whose stock **is** the template order's current source (`stock.getId() == template.getStockunitId()`). It is legitimately reserved **by this template** and **will** be released by row 3 before reserve. A naive `getAvailableamount() < qty` guard would **wrongly reject** it. | Yes — must NOT be rejected | Design concern (not a file) | **YES — handled in the row-1 fix (add-back)** |
| 9 | `service/mobile/MobileMoveUnitloadService.java:166-203` | `checkReservedStock` — SBDEV-2492 stopped cancelling open replens when a reserved UL is moved (comment @175). | No (move path, not multi-UL replenish) | No — **amplifier**, not root cause (see §3) | No — **do NOT revert** |
| 10 | `src/main/resources/messages_en_US.properties:203` | `MsgTooMuchRequested=So much amount is not available` — the current (misleading) message the gross gate throws. | n/a | No | **YES — add a clearer key** `MsgUnitLoadStockAlreadyReserved` (row 1 throws it) |

**Fix locus = row 1 only** (`validateUnitLoadEntry`), plus a new message key (row 10). Rows 2-7 are the surrounding reserve path (unchanged); rows 8 is the edge case the row-1 fix must handle; row 9 is documented as the amplifier and explicitly left alone.

---

## 1. Problem Statement

Mobile multi-unit-load replenishment lets an operator satisfy one replenishment request by pulling from **several** source unit loads. The tester selected **two** ULs; the request failed with:

```
FacadeException: CANNOT_RESERVE_MORE_THAN_AVAILABLE
→ rendered: "Cannot reserve more than available (0.0000)"
```

thrown at `StockunitBusinessService.changeReservedAmount` (`StockunitBusinessService.java:382-383`):

```java
if (stockUnit.getAmount().compareTo(newReservedAmount) < 0) {
    throw new FacadeException("CANNOT_RESERVE_MORE_THAN_AVAILABLE",
        String.valueOf(stockUnit.getAvailableamount()));   // getAvailableamount() = amount − reservedamount = 0.0000
}
```

**Expected:** a UL whose stock is already reserved (available < requested) is rejected **at entry** with a clear message, so the operator can pick a different UL. The request must not proceed to the reservation write and then explode.

**Actual:** the per-UL entry gate `validateUnitLoadEntry` (`MobileReplenishService.java:889-890`) checks **gross** stock (`matching.getAmount() < dto.getQty()`), not **availability**. A fully-reserved UL (available `0.0000`, gross ≥ qty) passes the gate, and the downstream `changeReservedAmount` (which computes `newReserved = existingReserved + qty` and refuses when `amount < newReserved`) throws.

### DB verification (wms1-wineco-dev, `db_verified: true`)

The reserved-source condition that trips the gate is the **normal design state**, not corruption:

```sql
-- Open replen orders (state 300) whose source pallet is ENTIRELY reserved (available = 0)
SELECT count(*) AS fully_reserved,
       (SELECT count(*) FROM replenishorder WHERE state = 300) AS total_open
FROM   replenishorder ro
JOIN   stockunit su ON su.id = ro.stockunit_id
WHERE  ro.state = 300
  AND  su.reservedamount = su.amount;      -- available = amount − reservedamount = 0.0000
-- 559 fully_reserved  /  602 total_open   (≈93%)
```

**Interpretation:** 559 of 602 open replenishments reserve their **entire** source pallet — "source already reserved" is by design (each open replen holds its source). No duplicate or over-reservation exists; the bug is purely that `validateUnitLoadEntry` reads gross instead of available, so it hands an already-committed UL to the additive reserve path. The defect is **data-independent** — it reproduces whenever a selected UL's available (not gross) stock is below the requested qty.

_(Confirming queries may be re-run via `mcp__wms1-wineco-dev__execute_sql`; retry once if the first call drops after idle.)_

---

## 2. Root Cause Analysis

### The gross-vs-available mismatch

`validateUnitLoadEntry` (`MobileReplenishService.java:869-893`) resolves the UL, finds the stock unit matching the template's `itemdataId`, then gates on **gross amount**:

```java
// MobileReplenishService.java:889-890
if (matching.getAmount().compareTo(dto.getQty()) < 0) {   // GROSS, not available
    throw new FacadeException("MsgTooMuchRequested");
}
```

`Stockunit.getAmount()` is the total on the pallet; it ignores `reservedamount`. A pallet with `amount=48, reservedamount=48` (available `0.0000`) still passes for any `qty ≤ 48`.

The reserve path is **additive and non-forgiving**. Both the first UL (`applyExplicitSourceToOrder` → `reserveExplicitStockForOrder`, `ReplenishGeneratorService.java:164-169`) and the remaining ULs (`createOrderFromTemplate` @211) call:

```java
// StockunitBusinessService.changeReservedAmount, :378-384
BigDecimal newReservedAmount = oldReservedAmount.add(amount);      // additive
if (stockUnit.getAmount().compareTo(newReservedAmount) < 0) {      // amount < existingReserved + qty
    throw new FacadeException("CANNOT_RESERVE_MORE_THAN_AVAILABLE",
        String.valueOf(stockUnit.getAvailableamount()));           // 0.0000
}
```

So for a fully-reserved UL: `newReserved = 48 + qty > 48 = amount` → throw. The `(0.0000)` in the message is exactly `getAvailableamount()` = `amount − reservedamount`.

### Why "another open replen already holds it" is invisible to the gate

Per the DB evidence, the selected UL's stock is typically reserved by a **different** open replenishment order. `validateUnitLoadEntry` never reads `reservedamount`, so it cannot see that the UL is already spoken for. Only the **template order's own** source reservation is ever released — and only inside `applyExplicitSourceToOrder` (`MobileReplenishService.java:900-912`), for the first UL. A reservation held by any *other* order on the selected UL is never released. This plan does **not** add cross-order release/re-point (see §10); it rejects the UL up front so the operator picks a free one.

### Why the single guard in `validateUnitLoadEntry` is sufficient

`fulfillMultipleUnitLoads` validates **all** instructions before **any** reservation:

```java
// MobileReplenishService.java:753-762  — validation loop (ALL ULs)
for (MultiReplenishUnitLoadDto dto : request.getUnitLoads()) {
    ...
    instructions.add(validateUnitLoadEntry(template, dto));   // no mutation
}
// :772  — FIRST reservation happens only after the loop completes
applyExplicitSourceToOrder(template, first.stock, ...);
```

The workflow doc confirms this ordering: *"All validations run before any `applyExplicitSourceToOrder` or `createOrderFromTemplate` calls"* (`wms1-multi-unitload-replenish.md:258`). Therefore a correct availability check in `validateUnitLoadEntry` blocks the bad request **before** any reservation is written, for both the first-UL path and the ad-hoc-order path. No second guard is needed in `createOrderFromTemplate` / `reserveExplicitStockForOrder`.

**CLAUDE.md rules applied:** compare entities by ID (`template.getStockunitId().equals(matching.getId())`, both `Long`) — never `Stockunit.equals()`; `getAvailableamount()` and reserved fields are `BigDecimal` (use `compareTo`); no JPA associations touched; the guard adds no static calls (Mockito 3.3.3 friendly).

---

## 3. Regression Chain / Context

**Root cause is latent-since-inception in the multi-UL feature.** `git log` shows `validateUnitLoadEntry` and the whole multi-UL entry path arrived in commit **`1519c85e`** — *"Implement multi-unit load replenishment functionality with DTOs and service methods"* (~8 months old). The gross-vs-available gate has been wrong since that first commit; it is not a recent regression of a previously-correct check.

**SBDEV-2492 is an amplifier, NOT the root cause.** SBDEV-2492 changed `MobileMoveUnitloadService.checkReservedStock` (`MobileMoveUnitloadService.java:166-203`, comment @175) so that moving a unit load with reserved stock **no longer cancels** the active replenishment against it:

```java
// MobileMoveUnitloadService.java:175  (SBDEV-2492)
// SBDEV-2492: a valid active replen against this reserved stock is no longer [cancelled on move]
```

Before SBDEV-2492, moving a reserved UL released (cancelled) its replen reservation, shrinking the pool of "reserved-yet-still-selectable" ULs. After SBDEV-2492, those reservations survive moves, so **more** ULs are simultaneously reserved-by-another-order and offered for selection — enlarging the population that hits the gross-vs-available bug. **Do NOT revert SBDEV-2492**; it is intentional. This plan fixes the *actual* defect (the gross gate) regardless of how large the amplified pool is.

---

## 4. Architecture Overview

```
Mobile UI  →  ReplenishController.multiUnitLoads            controller/mobile/ReplenishController.java:232
  └─ MobileReplenishService.fulfillMultipleUnitLoads()      service/mobile/MobileReplenishService.java:732
       @Transactional(rollbackFor={BusinessException, FacadeException})
       │
       ├─ VALIDATION LOOP  :753-762   (ALL unit loads, NO mutation)
       │    └─ validateUnitLoadEntry(template, dto)   :869-893   ★ FIX LOCUS
       │         · resolve UL + matching stock (itemdataId)
       │         · BEFORE:  if (matching.getAmount() < dto.getQty()) throw "MsgTooMuchRequested"   ← GROSS (bug)
       │         · AFTER :  effAvail = matching.getAvailableamount()
       │                    if (stock == template's own source) effAvail += template.getRequestedamount()   ← self-source add-back
       │                    if (effAvail < dto.getQty()) throw "MsgUnitLoadStockAlreadyReserved"            ← AVAILABILITY
       │
       ├─ FIRST unit load   :772
       │    └─ applyExplicitSourceToOrder(template, first.stock, ...)   :895-924
       │         · :900-912  release template's OWN current source reservation (negate entire reservedamount)
       │         · :923      reserveExplicitStockForOrder(template, stock, qty)
       │              └─ changeReservedAmount(stock, +qty, false, ...)   StockunitBusinessService.java:363
       │                   · :382-383  if (amount < oldReserved + qty) throw CANNOT_RESERVE_MORE_THAN_AVAILABLE (0.0000)
       │
       └─ REMAINING unit loads  :778-785   (i ≥ 1)
            └─ createOrderFromTemplate(template, stock, qty, destId, i)   ReplenishGeneratorService.java:172
                 · :211  reserveExplicitStockForOrder(order, stock, requestedAmount)
                      └─ changeReservedAmount(stock, +qty, false, ...)   (same throw site)
```

**Key Files**

| File | Lines | Role |
|------|-------|------|
| `service/mobile/MobileReplenishService.java` | 869-893 (`validateUnitLoadEntry`) | **FIX LOCUS** — replace gross gate with availability gate + self-source add-back; new throw `MsgUnitLoadStockAlreadyReserved` |
| `service/mobile/MobileReplenishService.java` | 732-794 (`fulfillMultipleUnitLoads`), 895-924 (`applyExplicitSourceToOrder`) | Orchestration + first-UL reservation transfer (context; validates-all-before-reserve @753-762; self-source release @900-912) |
| `service/ReplenishGeneratorService.java` | 164-170, 172-215 | `reserveExplicitStockForOrder`, `createOrderFromTemplate` — remaining-UL reserve (context, no change) |
| `service/StockunitBusinessService.java` | 363-400 | `changeReservedAmount` — additive reserve + `CANNOT_RESERVE_MORE_THAN_AVAILABLE` throw @382-383 (context, no change) |
| `model/Stockunit.java` | 113-116 | `getAvailableamount()` = `amount − reservedamount` (the fix's availability primitive) |
| `model/Replenishorder.java` | 140, 212 | `getRequestedamount()`, `getStockunitId()` — used for the self-source add-back |
| `src/main/resources/messages_en_US.properties` | +1 line | new key `MsgUnitLoadStockAlreadyReserved` |
| `service/mobile/MobileMoveUnitloadService.java` | 166-203 | SBDEV-2492 amplifier (context, **do NOT change**) |

---

## 5. Fix Design

### The fix: availability gate with self-source add-back in `validateUnitLoadEntry`

Replace the gross-stock check with an **availability** check. Because the check runs **before** `applyExplicitSourceToOrder` releases the template order's own source reservation (§2), it must credit back the template's own reservation on that stock — otherwise the legitimate "reuse my current source UL" case would be wrongly rejected (available `0` while the template itself holds it).

**Before (`MobileReplenishService.java:886-892`):**
```java
if (matching == null) {
    throw new FacadeException("MsgSourceStockNotFound");
}
if (matching.getAmount().compareTo(dto.getQty()) < 0) {
    throw new FacadeException("MsgTooMuchRequested");
}
return new MultiUnitLoadInstruction(dto, matching, unitload);
```

**After:**
```java
if (matching == null) {
    throw new FacadeException("MsgSourceStockNotFound");
}
// Validate AVAILABILITY (amount − reservedamount), not gross amount. A UL whose stock is already
// reserved by another open replenishment must be rejected here so the operator picks a different UL,
// instead of exploding downstream in changeReservedAmount with CANNOT_RESERVE_MORE_THAN_AVAILABLE (0.0000).
BigDecimal effectiveAvailable = matching.getAvailableamount();   // amount − reservedamount
// Self-source exception: if this UL's stock IS the template order's own current source, its reservation
// WILL be released by applyExplicitSourceToOrder before we reserve — so credit that back (compare by ID).
if (template.getStockunitId() != null
        && template.getStockunitId().equals(matching.getId())
        && template.getRequestedamount() != null) {
    effectiveAvailable = effectiveAvailable.add(template.getRequestedamount());
}
if (effectiveAvailable.compareTo(dto.getQty()) < 0) {
    throw new FacadeException("MsgUnitLoadStockAlreadyReserved", String.valueOf(effectiveAvailable));
}
return new MultiUnitLoadInstruction(dto, matching, unitload);
```

New message key (`messages_en_US.properties`):
```properties
MsgUnitLoadStockAlreadyReserved=Unit load stock is already reserved (%1$s available). Choose a different unit load.
```

**Self-source add-back — why `template.getRequestedamount()` and why it is safe.** Only **one** selected UL can ever be the template's own source (`stockunit_id` is a single FK; ULs are de-duplicated by `unitloadId` @758, and a stock unit belongs to exactly one UL), so the add-back applies to at most one instruction and cannot double-count. At runtime `applyExplicitSourceToOrder` @900-912 actually releases the old stock's **entire** `reservedamount` (`negate()`, `zeroIfNegative=true`), which is ≥ the template's own `requestedamount`. Using `requestedamount` is therefore the **conservative** credit — it never over-credits, so it never wrongly *accepts* a UL the reserve path would then reject.

> **Precise safety scope (review M-1/m-1).** The add-back is credited **only** so the *guard* does not false-reject the self-source UL; it is not the mechanism that keeps the *reserve* from throwing (see §5 "Does `createOrderFromTemplate` need its own guard?"). And "never wrongly rejects a valid self-source reuse" holds **except** for one over-release-dependent corner: if the self-source stock is co-reserved by the template *and another order* (`reservedamount > requestedamount`), the conservative credit yields `effectiveAvailable = amount − reservedamount + requestedamount < amount`, so the guard may reject a `qty` in `(effectiveAvailable, amount]` that the runtime would only have "succeeded" on by destroying the other order's reservation via the over-release quirk. That rejection is the **safe** direction (it refuses a silent data-loss reservation); the over-release itself is a separate pre-existing behavior — see §9 Risks and §10 Open Questions.

### Does the `createOrderFromTemplate` path need its own guard?

**No** — but the reason has two distinct parts that must not be conflated (review M-1):

1. **Guard side (all ULs):** every instruction passes through the `validateUnitLoadEntry` loop (`fulfillMultipleUnitLoads:753-762`) **before** the first reservation at :772 (confirmed by `wms1-multi-unitload-replenish.md:258`). The self-source add-back keys on `template.getStockunitId()`, so the guard does not false-reject the template's-own-source UL regardless of which position it is scanned in.
2. **Runtime side (why the reserve itself does not throw for a *later-position* self-source):** this is **not** the add-back's doing. It is because `applyExplicitSourceToOrder` @772 is always invoked with `order = template` and unconditionally releases `order.getStockunitId()`'s **entire** reservation @900-912 — i.e. the template's *old* source. Since "self-source" means the selected UL's stock **is** `template.getStockunitId()`, that stock's `reservedamount` is zeroed at :772 whether it was scanned first or later; only then does `createOrderFromTemplate` @211 re-reserve it against the now-zeroed amount. So the non-first self-source path survives because of the unconditional old-source release at :772, **not** because the guard credited it.

> **Load-bearing dependency (M-1):** part 2 relies on `applyExplicitSourceToOrder` releasing `order.getStockunitId()` (not `first.stock`). If a future refactor narrowed that release to only the first UL's stock, a later-position self-source would start throwing `CANNOT_RESERVE_MORE_THAN_AVAILABLE` again — reintroducing this bug. **AC-6** pins the behavior so that regression is caught.

The remaining-UL path (`createOrderFromTemplate`) never releases a prior reservation, so its non-self-source ULs are validated with the plain availability rule. A guard inside `createOrderFromTemplate` would be redundant and is deliberately omitted to keep the diff minimal and the choke point single.

### Resulting behavior matrix

| UL selected | Before (today) | After |
|---|---|---|
| Stock available ≥ qty (free UL) | passes → reserves OK | **unchanged** — passes |
| Stock reserved by **another** open replen (available < qty, gross ≥ qty) | passes gate → `CANNOT_RESERVE_MORE_THAN_AVAILABLE (0.0000)` downstream | **rejected at entry** with `MsgUnitLoadStockAlreadyReserved (<avail>)` — operator picks another UL |
| Stock IS the **template's own** current source (available `0`, held by this template) | passes (gross) then reserves OK after self-release | **still passes** — self-source add-back credits `requestedamount` (AC-4) |
| Gross stock < qty (genuinely too little total) | rejected `MsgTooMuchRequested` | rejected `MsgUnitLoadStockAlreadyReserved` (availability ≤ gross, so still rejected; message key changes) |

### Rejected alternatives
- **Cross-order release / re-point** (cancel the other replen's reservation and steal the UL): out of scope and dangerous — silently invalidates another operator's in-flight order. §10 records this as a resolved decision (reject up front instead).
- **Fix downstream in `changeReservedAmount`**: it is already correct (it *must* refuse over-reserve). Moving rejection earlier gives the operator an actionable message; the invariant guard stays as a failsafe.
- **Reuse `MsgTooMuchRequested`**: technically works but the message ("So much amount is not available") does not tell the operator the UL is *reserved* (fixable by choosing another UL). A dedicated key is clearer; noted as the fallback if adding a key is undesirable.

---

## 6. File Change Summary

| File | Change Type | Description |
|------|-------------|-------------|
| `service/mobile/MobileReplenishService.java` | edit (`validateUnitLoadEntry` @886-892) | Replace gross gate (`getAmount().compareTo(dto.getQty())`) with availability gate on `getAvailableamount()` + self-source add-back (`template.getStockunitId().equals(matching.getId())` → `+ template.getRequestedamount()`); throw new `MsgUnitLoadStockAlreadyReserved` with the effective-available amount |
| `src/main/resources/messages_en_US.properties` | edit (add key) | `MsgUnitLoadStockAlreadyReserved=Unit load stock is already reserved (%1$s available). Choose a different unit load.` |
| `src/test/java/net/aim_ai/wms/unit/service/mobile/MobileReplenishServiceUnitTest.java` | edit (add tests) | AC-1..AC-6 (§8) — Mockito 3.3.3, no `mockStatic` |
| `sbdocs/9-System/scripts/verify-260709-multi-unitload-replen-reserve-availability-guard.sh` | new | Machine-checkable acceptance (availability + self-source + gross-gone + `mvn` behavioral gate) |

No DB schema/DDL/Flyway change. No config/sysprop. Single-file production change (+ message + tests).

---

## 7. Implementation Steps

### 7.1 Prerequisites

| # | Prerequisite | Applies? | Detail |
|---|---|---|---|
| 1 | **Database state** (schema, Flyway baseline) | **N/A** | No schema/DDL/Flyway change. `stockunit.amount`/`reservedamount` already exist. |
| 2 | **Feature flags / system properties** | **N/A** | No sysprop toggle. Behavior change ships directly (it is a pure correctness fix; the old behavior is a defect, not a configurable mode). |
| 3 | **Config / env changes** | **N/A** | None. |
| 4 | **Deploy-order dependencies** | **N/A** | Single wms-api JAR. The new message key is server-rendered; no UI change required (the mobile UI already surfaces `FacadeException` messages from this endpoint). |
| 5 | **Data migration** | **N/A** | No data mutated; the fix is data-independent code logic. |
| 6 | **External systems** | **N/A** | None. |
| 7 | **Access / permissions** | **N/A** | No endpoint/authority change (`/v3/**` mobile replenish endpoint unchanged). |
| 8 | **Monitoring / alerts** | Optional | Optionally watch for a rise in `MsgUnitLoadStockAlreadyReserved` rejections after deploy — expected to replace the pre-fix `CANNOT_RESERVE_MORE_THAN_AVAILABLE` failures with a cleaner, earlier rejection. No new metric required. |

**Summary:** pure code-logic fix; no DB/Flyway/sysprop/deploy-order/migration dependency.

### 7.2 Steps (each independently committable)

1. Add `MsgUnitLoadStockAlreadyReserved` to `messages_en_US.properties`. `mvn clean compile`.
2. Edit `validateUnitLoadEntry` (@886-892): replace the gross check with the availability gate + self-source add-back; throw the new key. Compile.
3. Add AC-1..AC-6 unit tests (§8) to `MobileReplenishServiceUnitTest` (AC-6 is a two-UL request pinning the later-position self-source path); run `mvn test -Dtest=MobileReplenishServiceUnitTest`.
4. Run `bash sbdocs/9-System/scripts/verify-260709-multi-unitload-replen-reserve-availability-guard.sh` → `Result: N pass, 0 fail`.

---

## 8. Testing Plan

### Unit (test class `MobileReplenishServiceUnitTest` — Mockito 3.3.3, **no `mockStatic`**; repositories/services are injected mocks)

The `validateUnitLoadEntry` gate is driven by stubbing `unitloadRepository.findById(ulId)`, `stockunitRepository.findByUnitloadId(ulId)` (returns the matching stock), and the template's `itemdataId`/`stockunitId`/`requestedamount`. Existing helpers: `createStockunit(id, unitloadId, itemdataId, amount)` (defaults `reservedamount = ZERO` — call `setReservedamount(...)` to make a UL reserved) and `createReplenishorder(id, number, state, itemdataId, clientId)`. Tests can assert at the `validateUnitLoadEntry` boundary via `fulfillMultipleUnitLoads` (single-UL request is enough to exercise the gate) and verify `changeReservedAmount` is never reached on rejection.

| # | Test method | Setup | Asserts |
|---|---|---|---|
| **AC-1** | `validateUnitLoadEntry_reservedByAnotherOrder_rejectsWithReservedMessage` | matching stock `amount=48, reservedamount=48` (available `0`), `qty=12`, template's `stockunitId` ≠ this stock's id | throws `FacadeException` containing `MsgUnitLoadStockAlreadyReserved`; `verify(stockunitBusinessService, never()).changeReservedAmount(...)` **and** `verify(replenishGeneratorService, never()).createOrderFromTemplate(...)` (prove rejection precedes *both* reserve paths — m-3) |
| **AC-2** | `validateUnitLoadEntry_freeStock_passes` | matching stock `amount=48, reservedamount=0` (available `48`), `qty=12` | no throw; instruction built; happy-path reservation proceeds |
| **AC-3** | `validateUnitLoadEntry_partiallyReservedBelowQty_rejects` | `amount=48, reservedamount=40` (available `8`), `qty=12` | throws `MsgUnitLoadStockAlreadyReserved`; `verify(stockunitBusinessService, never()).changeReservedAmount(...)` **and** `verify(replenishGeneratorService, never()).createOrderFromTemplate(...)` (m-3) |
| **AC-4 (self-source, first/sole UL)** | `validateUnitLoadEntry_templateOwnSource_passesViaAddBack` | single-UL request; matching stock `amount=12, reservedamount=12` (available `0`); template `stockunitId = matching.getId()`, `requestedamount=12`; `qty=12` | **no throw** — effective available `0 + 12 = 12 ≥ 12`; instruction built (this is the self-source case a naive availability check would wrongly reject) |
| **AC-5 (self-source not enough even with add-back)** | `validateUnitLoadEntry_templateOwnSourceStillShort_rejects` | matching stock `amount=12, reservedamount=12`; template `stockunitId = matching.getId()`, `requestedamount=5`; `qty=12` | throws `MsgUnitLoadStockAlreadyReserved` — effective `0 + 5 = 5 < 12` (add-back credits only the template's own share, not another order's reservation) |
| **AC-6 (self-source in a *later* position — M-1 regression pin)** | `fulfillMultipleUnitLoads_selfSourceSecondUnitLoad_succeeds` | **two-UL** request: UL#1 = free stock (`amount=24, reservedamount=0`, `qty=12`); UL#2 = the template's own source (`amount=12, reservedamount=12`, available `0`), template `stockunitId = UL#2 stock id`, `requestedamount=12`, `qty=12` | **whole request succeeds, no `CANNOT_RESERVE_MORE_THAN_AVAILABLE`** — guard passes UL#2 via add-back, and the reserve survives because `applyExplicitSourceToOrder` @772 zeroes UL#2's reservation before `createOrderFromTemplate` re-reserves it. Pins the load-bearing :772 release (§5); would fail if that release were narrowed. |

**Mock/setup notes:**
- Stub the full `fulfillMultipleUnitLoads` prologue as the existing multi-UL tests do (`replenishorderRepository.findById`, destination resolution via `locationRepository`/`itemdataRepository`/`fixLocationAssignmentRepository`/`locationTypeRepository`/`unitloadRepository.findByStoragelocationId`), then the per-UL stubs (`unitloadRepository.findById`, `stockunitRepository.findByUnitloadId`). Reuse the pattern in `fulfillMultipleUnitLoads_DuplicateUnitLoadId_ThrowsBusinessException` (:738-776).
- For rejection tests, no reserve stubs are needed; assert **both** `changeReservedAmount` and `replenishGeneratorService.createOrderFromTemplate` are `never()` invoked to prove rejection happens **before** either reserve path (m-3).
- **Template setup (m-4):** `createReplenishorder(id, number, state, itemdataId, clientId)` does **not** set `stockunitId`/`requestedamount`. AC-4/AC-5/AC-6 must explicitly call `template.setStockunitId(...)` and `template.setRequestedamount(...)` — a null-source template skips the add-back branch and would not exercise the self-source path.
- **No `mockStatic`** — the gate uses only instance methods (`getAvailableamount`, `getAmount`, `getStockunitId`, `getRequestedamount`), so no static mocking is required.

### Integration (Testcontainers)

`MobileReplenishServiceIT.fulfillMultipleUnitLoads_success` already exercises the happy path. Any new `@SpringBootTest`/Testcontainers IT is **blocked / gated `@Disabled`** by **SBDEV-2384** (`ro_id` view drift — all v1 `@SpringBootTest` ITs fail at context load). If added, mark `@Disabled` with `// TODO(SBDEV-2384): re-enable once ro_id view drift is fixed`. Acceptance meanwhile = `mvn clean compile` + the 6 unit tests + manual smoke.

### Regression

- `mvn clean compile`; `mvn test -Dtest=MobileReplenishServiceUnitTest`.
- Confirm the existing multi-UL entry tests (`fulfillMultipleUnitLoads_*`, :671-776) still pass (the free-stock happy path is unchanged — AC-2 covers it).

### Manual test plan

| # | Scenario | Environment | Steps | Expected Result | Pass/Fail |
|---|---|---|---|---|---|
| M1 | **Reserved UL rejected** | staging | Multi-UL replenish; select a UL whose stock is fully reserved by another open replen (available 0) | Rejected at entry: "Unit load stock is already reserved (0.0000 available). Choose a different unit load." — **no** `CANNOT_RESERVE_MORE_THAN_AVAILABLE` | |
| M2 | **Two free ULs succeed** | staging | Select two ULs both with available ≥ their qty | Both fulfilled; two picks created; no error | |
| M3 | **Self-source reuse** | staging | Select the UL that is the template order's own current source | Succeeds (self-source add-back) — one clean pick | |
| M4 | **Mixed: one free, one reserved** | staging | Select one free UL + one reserved UL | Whole request rejected on the reserved UL (all validated before any reserve); **no** partial reservation left behind | |
| M5 | SQL sanity after M1 | staging DB | `SELECT reservedamount FROM stockunit WHERE id = <selected UL stock>;` before/after M1 | unchanged (rejection wrote nothing) | |

### Test execution (fill in after running)

| Command | Result | Pass / Fail / Skipped |
|---------|--------|------------------------|
| `mvn test -Dtest=MobileReplenishServiceUnitTest` | | |
| `mvn clean compile` | | |
| `bash sbdocs/9-System/scripts/verify-260709-multi-unitload-replen-reserve-availability-guard.sh` | | |

---

## 9. Risks & Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| Guard rejects ULs that previously "worked" | Some selections that used to *proceed then fail* now fail *earlier* | Intended — they always failed (`CANNOT_RESERVE_MORE_THAN_AVAILABLE`); the fix just fails cleanly and actionably at entry. Net operator experience improves. |
| **Self-source false reject** | Wrongly rejecting the template's own current source UL (available 0 because the template holds it) | Self-source add-back (`template.getStockunitId().equals(matching.getId())` → `+ requestedamount`); pinned by **AC-4**. Compare by ID (CLAUDE.md). |
| Self-source add-back over-credits | Wrongly *accepts* a UL the reserve path then rejects | Uses `requestedamount` (the template's own share) — `applyExplicitSourceToOrder` releases ≥ that (the entire `reservedamount`), so the add-back is conservative; AC-5 pins the short case. |
| **Accepted self-source silently leaks a co-reserving order's reservation (m-2)** | When an accepted self-source stock is co-reserved by the template **and another order**, `applyExplicitSourceToOrder:900-912` negates the **entire** `reservedamount`, destroying the other order's reservation — a *passing* run of the fixed feature can trigger it | **Pre-existing** behavior, not introduced here; likelihood low per DB evidence (559/602 orders hold one full pallet each, so one stockunit co-reserved by two orders is atypical). This fix's conservative `requestedamount` credit **reduces** exposure (it rejects rather than rides the over-release for `qty > effectiveAvailable`). Full remedy tracked in §10 Open Questions (scope `applyExplicitSourceToOrder`'s release to the template's own share). |
| `null` `partitionallowed`-style NPE on nullable fields | NPE on `getStockunitId()` / `getRequestedamount()` | Null-guarded (`!= null` before `.equals` / `.add`); a template with no source (`stockunitId == null`) simply skips the add-back and uses plain availability. |
| New message key not rendered by UI | Operator sees a raw key | The mobile UI already renders `FacadeException` messages from this endpoint (same path as `MsgTooMuchRequested` / `MsgSourceStockNotFound`); the new key is added to `messages_en_US.properties`, the same bundle those use. |
| Message-key drift breaks verify grep | Verify script false-fail | Verify greps a stable substring (`MsgUnitLoadStockAlreadyReserved`) of both the throw and the properties line; update together if reworded. |

**Horizontal scalability (v2):** **N/A — v1-only plan.** v2/wms2-api has its own replenishment path and multi-replica considerations; evaluate a v2 counterpart separately (§10 open question).

---

## 10. Implementation Status

**Status: IMPLEMENTED — 2026-07-09 (TDD-gated), on branch `fix/260709-multi-unitload-replen-availability` (off `develop`); NOT yet committed/PR'd — awaiting go-ahead.**

- **Implementation (2026-07-09, TDD gate → implement):**
  - **Fix:** `service/mobile/MobileReplenishService.java` `validateUnitLoadEntry` — replaced the gross gate (`getAmount().compareTo(dto.getQty())`) with an **availability** gate on `getAvailableamount()` (= amount − reservedamount) plus the **self-source add-back** (`template.getStockunitId().equals(matching.getId())` → `+ template.getRequestedamount()`); throws new `FacadeException("MsgUnitLoadStockAlreadyReserved", <available>)`. `messages_en_US.properties` — added the key.
  - **Tests (`MobileReplenishServiceUnitTest`):** AC-1/AC-3/AC-5 written test-first and confirmed RED for the right reason (AssertionError — gross gate let the reserved UL through; downstream `BusinessException`, not the new key); after the fix all green. AC-2/AC-4/AC-6 added as validation-acceptance guards (assert the request is NOT rejected by the availability gate; discriminate against a naive-availability-without-add-back mis-fix). **`Tests run: 87, Failures: 0, Errors: 0`** (Java 8).
  - **Altitude note:** `fulfillMultipleUnitLoads` has no success-path unit test in this suite (success path covered by `MobileReplenishServiceIT`, `@Disabled` per SBDEV-2384). AC-6's unit form pins validation-acceptance of a **later-position** self-source; the full runtime `:772`-release success remains the IT's job.
  - **Gates:** `mvn clean compile` clean (COMPILE_EXIT=0); verify script **`Result: 8 pass, 0 fail, 0 skip`** (G1/G1neg/G2a/G2b/G3a/G3b/G4a + T-MRS behavioral gate incl. AC-1..AC-6).
- **Review (2026-07-09, `critic`, code-grounded):** **APPROVE-WITH-CHANGES** (+ focused re-review CONFIRMED). Every file:line citation verified accurate against the live tree; root cause and single-choke-point confirmed; exception mapping confirmed (`FacadeException` → HTTP 422 via `RestExceptionHandler:137-147`, not 500); verify-script greps confirmed to have no false-passes. Must-fix items applied to this plan:
  - **M-1** — corrected the §5 rationale: the *guard* add-back prevents false-reject, but the *runtime* survival of a later-position self-source depends on `applyExplicitSourceToOrder`'s unconditional `order.getStockunitId()` release at :772 (not the add-back). Added **AC-6** (two-UL request, self-source in position 2) to pin that load-bearing release + a `G4` verify check.
  - **m-1** — softened the "never wrongly rejects a valid self-source reuse" claim to exclude the over-release-dependent corner (safe-direction rejection).
  - **m-3** — rejection ACs now also assert `verify(replenishGeneratorService, never()).createOrderFromTemplate(...)`.
  - **m-2** (recommended) — added the accepted-self-source over-release leak to §9 Risks (pre-existing, reduced by this fix, full remedy in Open Questions).
  - **m-4** (recommended) — noted AC-4/5/6 must set `stockunitId`/`requestedamount` on the template.
- **Branch / commit / PR:** branch `fix/260709-multi-unitload-replen-availability` (off `develop`); **uncommitted** working tree — commit + PR pending user go-ahead.
- **Code changes (v1/wms-api):** DONE — `service/mobile/MobileReplenishService.java` (`validateUnitLoadEntry` availability gate + self-source add-back); `messages_en_US.properties` (`MsgUnitLoadStockAlreadyReserved`).
- **Tests:** DONE — AC-1..AC-6 in `MobileReplenishServiceUnitTest`; `Tests run: 87, Failures: 0`.
- **Verify script:** DONE — `Result: 8 pass, 0 fail, 0 skip`.
- **Integration tests:** remain `@Disabled` (SBDEV-2384 `ro_id` view drift); acceptance rests on unit tests + `mvn clean compile` + manual smoke per §8.

### Resolved Decisions
- **Fix policy = REJECT UP FRONT.** `validateUnitLoadEntry` validates **availability** (`amount − reservedamount`), not gross. A UL reserved by another open replen is rejected with a clear message so the operator picks a different UL. **No cross-order release/re-point** — stealing another order's reservation is out of scope and unsafe.
- **Self-source handling.** A selected UL whose stock is the template order's own current source is legitimately reserved *by this template* and *will* be released before reserve, so the guard credits `template.getRequestedamount()` back into effective-available (add-back), keyed on `template.getStockunitId().equals(matching.getId())`. Pinned by AC-4/AC-5.
- **Single choke point.** All instructions are validated before any reservation (`fulfillMultipleUnitLoads:753-762`, doc-confirmed), so the fix lives only in `validateUnitLoadEntry`; no guard is added to `createOrderFromTemplate` / `reserveExplicitStockForOrder`.
- **SBDEV-2492 stays.** It is an amplifier (more reserved ULs survive moves), not the root cause; **not reverted**.
- **Scope = v1 only.** No v2 counterpart in this plan.
- **Clearer message key.** Add `MsgUnitLoadStockAlreadyReserved` rather than reuse `MsgTooMuchRequested`, so the operator understands the UL is *reserved* (choose another) vs genuinely *short*.

### Open Questions
- **`applyExplicitSourceToOrder` over-release (pre-existing, out of scope):** @900-912 negates the old stock's **entire** `reservedamount` (not just the template's `requestedamount`). If that stock were reserved by the template *and* another order, the release would over-free the other order's reservation. This is pre-existing behavior unrelated to this fix; the availability add-back deliberately uses the conservative `requestedamount`. Flag for a separate investigation if it proves real.
- **v1↔v2:** confirm whether v2's multi-UL replenish path (`wms2-multi-unitload-replenish.md`) has the same gross-vs-available gate and self-source concern; pair a v2 plan if so.

---

## Completeness checklist (Layer 2)

| # | Concern | Considered? |
|---|---|---|
| 0 | **DB verified** | ✓ §1 — 559/602 open replens fully reserve their source (available 0.0000) = normal design state; `db_verified: true`. Confirms the gross-vs-available gap is data-independent, not corruption. |
| 1 | **All callsites enumerated** | ✓ §0 rows 1-10; fix locus = row 1 (`validateUnitLoadEntry`) + row 10 (message); rows 2-9 documented/excluded with rationale (self-source edge = row 8, amplifier = row 9). |
| 2 | **Adjacent bugs** | ✓ §10 open question — `applyExplicitSourceToOrder` over-release of the whole `reservedamount` (pre-existing, out of scope); `changeReservedAmount` correct as-is. |
| 3 | **Backward compatibility** | ✓ §5 matrix — free-UL happy path unchanged; only the reserved-UL case moves from a late downstream throw to an early clear rejection. No API/DTO/schema change; new message key is additive. |
| 4 | **Concurrency** | ✓ §2/§3 — the reserved-source state is another open order's live reservation; the fix reads it via `getAvailableamount()` within the method's `@Transactional`. SBDEV-2492 enlarges the reserved pool but does not change correctness. No new lock. |
| 5 | **Multi-tenant** | ✓ no — all repo calls are tenant-scoped in the routed datasource; no cross-tenant query; message bundle is global. |
| 6 | **Error handling** | ✓ §5 — early `FacadeException("MsgUnitLoadStockAlreadyReserved", <avail>)`; rolls back cleanly via the method's `rollbackFor` (nothing reserved yet); downstream `CANNOT_RESERVE_MORE_THAN_AVAILABLE` retained as failsafe. |
| 7 | **Observability** | ✓ §7.1 row 8 — optional watch for the new rejection replacing the old 500-style reserve failure; no new metric mandated. |
| 8 | **Rollback / migration** | ✓ §7.1 — no Flyway/backfill; revert = redeploy prior JAR (pure code change; no sysprop toggle by decision). |
| 9 | **Test coverage** | ✓ §8 — AC-1..AC-6 (incl. AC-4 self-source, AC-5 self-source-short, AC-6 later-position self-source) in `MobileReplenishServiceUnitTest` + manual M1-M5; IT gated `@Disabled` TODO(SBDEV-2384). |
| 10 | **Cross-version (v1↔v2)** | ✓ no — v1-only; v2 multi-UL replenish path evaluated separately (§10 open question, §9 scalability N/A). |

**v2 Horizontal Scalability Validation:** N/A — v1-only plan (v2 replenish path evaluated separately).
**v2-only constraint checklist:** N/A — v1-only plan (no jakarta / tenantTransactionManager / Caffeine / H2 concerns apply).

---

## Acceptance

Machine-checkable script: `sbdocs/9-System/scripts/verify-260709-multi-unitload-replen-reserve-availability-guard.sh`
Run: `bash sbdocs/9-System/scripts/verify-260709-multi-unitload-replen-reserve-availability-guard.sh` — acceptance = `Result: N pass, 0 fail`.

The script encodes the fix so a weaker implementation cannot pass: `validateUnitLoadEntry` must use `getAvailableamount()` (availability), the self-source add-back term (`getStockunitId()` + `getRequestedamount()`) must be present, the old gross check (`getAmount().compareTo(dto.getQty())`) must be **gone**, the new message key must exist, and `mvn test -Dtest=MobileReplenishServiceUnitTest` (including AC-4 self-source, AC-5 self-source-short, and AC-6 later-position self-source) must pass as the behavioral gate.

### Recommended OMC composition (for implementation)

| Aspect | Value | Rationale |
|---|---|---|
| **Size class** | Standard | Single fix locus in one service + a message key + 5 tests; single subsystem. |
| **Pre-draft step** | none | Root cause already traced + DB-verified. |
| **Plan-review step** | critic | Standard+ — catch any gap in the self-source reasoning before coding. |
| **Implementation shape** | executor | One coherent change; verify script is the exit gate. |
| **Verification step** | verify-script + verifier | Mandatory. |
| **Code-review step** | code-reviewer | Small blast radius but touches a reservation gate — one review pass. |
| **Commit step** | git directly | Single logical commit. |
