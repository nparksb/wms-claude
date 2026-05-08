# Receiving Error Analysis: "StockUnit not on UnitLoad anymore"

**Date:** 2026-03-12
**Last Updated:** 2026-03-13 (Fix 1 + Fix 2 + Fix 3 implemented, tests passing)
**Status:** Fixes 1-3 IMPLEMENTED — Fix 4 deferred for separate review
**Severity:** High — blocks user from deleting/adjusting received goods positions

---

## 1. Problem Statement

Users report that when attempting to delete a received goods receipt position (GoodsReceiptPosition) in the Inbound Receiver on the Web UI, the system returns the error:

> **"StockUnit not on UnitLoad anymore!"**

This prevents the user from correcting or removing received inventory. The same validation also blocks amount adjustment, not only deletion.

**Clarification:** The backend deletes a `Goodsreceiptposition` record, not the `Unitload` itself. The unitload may be cleaned up as a side effect if it becomes empty after the stockunit is removed.

---

## 2. Error Location

**Single source of the error:**

- **File:** `GoodsReceiptPositionService.java`
- **Method:** `checkAndGetGoodsReceiptPosition()` (private), at the `stockUnitList.contains(posStockUnit)` check

```java
Unitload unitLoad = unitloadRepository.findById(position.getUnitloadId()).get();
List<Stockunit> stockUnitList = stockunitRepository.findByUnitloadId(unitLoad.getId());
Stockunit posStockUnit = stockunitRepository.findById(position.getStockunitId()).get();
if (!stockUnitList.contains(posStockUnit)) {
    throw new BusinessException("StockUnit not on UnitLoad anymore!");
}
```

**Called by:**
- `GoodsReceiptPositionService.delete()` — via `POST /v3/goodsReceiptPosition/delete`
- `GoodsReceiptPositionService.adjust()` — via `POST /v3/goodsReceiptPosition/adjust`

**Controller:** `GoodsReceiptPositionController.java` — no `@Transactional` annotation.

---

## 3. Entity Relationship During Receiving

```
Advice (Inbound BOL)
  └── Adviceposition (SKU line items)
        └── Goodsreceiptposition (each received case)
              ├── unitloadId ──► Unitload (physical box)
              │                     ├── storagelocationId ──► Location
              │                     └── carrierunitloadId ──► Unitload (parent pallet, nullable)
              └── stockunitId ──► Stockunit (inventory record)
                                    └── unitloadId ──► Unitload (FK, NOT NULL at DB level)
```

**Key relationship:** Both `Goodsreceiptposition` and `Stockunit` reference a `Unitload`, but independently:
- `Goodsreceiptposition.unitloadId` — set once at creation time (`ReceivingService.java:509`), **never updated**
- `Stockunit.unitloadId` — mutable, changed by stock movement and nirvana logic

The error occurs when these two references diverge: the GRP still points to the original unitload, but the stockunit has been moved to a different unitload.

---

## 4. Root Cause Analysis

### 4.1 The `.contains()` Check Relies on Reference Equality (Active Bug)

`Stockunit` has **NO `equals()/hashCode()` override**. The `List.contains()` call uses `Object.equals()` (reference identity).

This means the check only works if Hibernate's first-level cache returns the **same Java object instance** for both:
- `stockunitRepository.findByUnitloadId(unitLoad.getId())` — JPQL query
- `stockunitRepository.findById(position.getStockunitId())` — ID lookup

**Environment-dependent behavior:**

| Environment | `open-in-view` | Persistence Context Scope | `.contains()` behavior |
|-------------|:---:|---|---|
| Base `application.properties` | Not set (Spring Boot default `true`) | HTTP request | Works via L1 cache — same instance returned |
| `application_dev.properties` | **Explicitly `false`** (line 4) | Per-transaction only | **BROKEN** — each repo call gets its own context, different instances returned |
| Production | Depends on deployed profile | Unknown | May or may not work |

With `open-in-view=false` and no `@Transactional` wrapping the method, each repository call runs in its own mini-transaction with its own persistence context. The two `Stockunit` objects are **different Java instances**, so `.contains()` **always returns false** — producing a false positive error even when the stockunit IS on the unitload.

**Bottom line:** ID-based comparison is the only correct approach regardless of environment configuration.

### 4.2 No Transaction Boundary on Delete/Adjust Flow (Primary Issue)

The entire delete/adjust chain has **NO `@Transactional` annotation**:

| Layer | Class | Has @Transactional? |
|-------|-------|:---:|
| Controller | `GoodsReceiptPositionController` | NO |
| Service | `GoodsReceiptPositionService.delete()` | NO |
| Service | `GoodsReceiptPositionService.adjust()` | NO |
| Service | `GoodsReceiptPositionService.checkAndGetGoodsReceiptPosition()` | NO |
| Service | `GoodsReceiptPositionService.deletePosition()` | NO |
| Service | `StockunitBusinessService.sendStockUnitToNirvana()` | NO |

**Impact:** Each `repository.save()`, `repository.findById()`, and `repository.delete()` executes in its own auto-commit transaction (Spring Data JPA default). This means:

1. **Validation and action are not atomic:** Between `checkAndGetGoodsReceiptPosition()` passing validation and `deletePosition()` executing, a concurrent request could move the stockunit.

2. **Partial failure leaves inconsistent state:** `deletePosition()` performs 3 operations in sequence:
   - `sendStockUnitToNirvana(stockUnit)` — moves stockunit to nirvana unitload
   - `sendToNirvana(unitLoad)` — sends empty unitload to nirvana (conditional)
   - `goodsreceiptpositionRepository.delete(position)` — deletes GRP record

   If step 3 fails after steps 1-2 succeed, the stockunit and unitload are in nirvana but the GRP record still exists, pointing to a now-moved stockunit — causing the "not on UnitLoad anymore" error on any subsequent attempt.

**Critical rollback caveat:** Both `BusinessException` and `FacadeException` are **checked exceptions** (`extends Exception`). Spring's default `@Transactional` only rolls back for **unchecked** exceptions (`RuntimeException`). A plain `@Transactional` annotation will **not** guarantee rollback when these exceptions are thrown. The correct form is:
```java
@Transactional(rollbackFor = {BusinessException.class, FacadeException.class})
```

### 4.3 Concurrent Operations Move Stock Before Delete

Many backend flows can move a stockunit away from the original goods-in unitload before a later delete/adjust attempt. The **direct mutation sites** for `Stockunit.unitloadId` are concentrated in `StockunitBusinessService`:

| Method | What It Does |
|--------|-------------|
| `createStockUnit()` | Sets `unitloadId` on new stockunit |
| `transferStockToUnitLoad()` | Moves stockunit to a different unitload |
| `sendStockUnitToNirvana()` | Moves stockunit to nirvana unitload |
| `StockunitService.create()` | Sets `unitloadId` on new stockunit |

These shared methods are called by many higher-level services: putaway, stock transfer, unitload move, replenishment, transfer orders, picking, cycle count, BOL/shipping, fix-location deletion, and manual unitload deletion.

**Scenario:** User receives inventory, stock is on the goods-in unitload. A mobile user does putaway (calls `transferStockToUnitLoad` or moves the unitload to storage). The web UI user then tries to delete the GRP — but the stockunit has been moved → error.

### 4.4 Web UI State Management (Independent UX Issue)

**File:** `wms-web-ui/store/receiving/inboundNotices.js`

```javascript
async deleteGoodsReceiptPosition(context, data) {
    context.commit('setGoodsReceiptPositions', [])  // Clears list BEFORE API call
    const results = await this.$axios.$post('/goodsReceiptPosition/delete', data)
    // ...
    context.dispatch('getGoodsReceiptPositions', {...})  // Re-fetches after
}
```

This is a **UX/state-management issue**, not a direct cause of the backend error. It causes a confusing blank-table flash on delete and may show stale data after a failed delete. The active delete path is single-record (the `deleteMany`/`adjustMany` methods in `openNoticeReceiptTable.vue` are placeholder stubs that only log).

---

## 5. Full Flow Trace: How the Error Manifests

### Normal Flow
```
User clicks "Delete" on GRP in openNoticeReceiptTable.vue
  → deleteOpenNoticeReceipt.vue (confirmation dialog)
  → store/receiving/inboundNotices.js → deleteGoodsReceiptPosition()
  → POST /v3/goodsReceiptPosition/delete { ids: "123" }
  → GoodsReceiptPositionController.delete()
  → GoodsReceiptPositionService.delete()
  → checkAndGetGoodsReceiptPosition()
    → stockunitRepository.findByUnitloadId(unitLoad.getId())   ← stockunit NOT found here
    → stockunitRepository.findById(position.getStockunitId())  ← stockunit found here
    → list.contains(stockunit) == FALSE
    → throws "StockUnit not on UnitLoad anymore!"
  → Controller catches BusinessException → returns { errors: [{message: "..."}] }
  → UI shows toast error
```

### Why the stockunit is not found on the unitload
The stockunit's `unitloadId` was changed by one of:
- `sendStockUnitToNirvana()` — moved to nirvana unitload (prior delete or cycle count)
- `transferStockToUnitLoad()` — moved to a different unitload (putaway, pick, transfer, replenish)
- A prior failed delete that partially completed (moved stock to nirvana but didn't delete GRP)
- **In dev environment:** reference equality failure due to `open-in-view=false` (false positive — stock IS on the unitload but `.contains()` returns false)

---

## 6. Recommended Fixes

### Fix 1: Replace `.contains()` with ID-Based Comparison (Critical — implement first)

**Why:** Eliminates dependency on reference equality and Hibernate cache behavior. This is the correct way to compare entities that lack `equals()/hashCode()`. Works correctly regardless of `open-in-view` setting.

**File:** `GoodsReceiptPositionService.java` — `checkAndGetGoodsReceiptPosition()` method

**Before:**
```java
Unitload unitLoad = unitloadRepository.findById(position.getUnitloadId()).get();
List<Stockunit> stockUnitList = stockunitRepository.findByUnitloadId(unitLoad.getId());
Stockunit posStockUnit = stockunitRepository.findById(position.getStockunitId()).get();
if (!stockUnitList.contains(posStockUnit)) {
    throw new BusinessException("StockUnit not on UnitLoad anymore!");
}
```

**After:**
```java
Stockunit posStockUnit = stockunitRepository.findById(position.getStockunitId()).get();
if (!position.getUnitloadId().equals(posStockUnit.getUnitloadId())) {
    throw new BusinessException("StockUnit not on UnitLoad anymore!");
}
```

This is simpler, more efficient (1 query instead of 3), and immune to Hibernate cache behavior. It directly checks whether the stockunit's current unitloadId matches the GRP's unitloadId. The subsequent unitload/location/area validation should then load the unitload separately if still needed.

**Risk:** Low.

### Fix 2: Add `@Transactional` with `rollbackFor` to Delete/Adjust Flow (Critical)

**Why:** Ensures atomicity — validation and mutation happen in one transaction. Prevents partial failures from leaving orphaned GRP records.

**Critical:** Both `BusinessException` and `FacadeException` are **checked exceptions** (`extends Exception`). Plain `@Transactional` will NOT roll back for these — Spring's default only rolls back for unchecked exceptions. The annotation MUST include `rollbackFor`.

**File:** `GoodsReceiptPositionService.java`

```java
@Service
public class GoodsReceiptPositionService {

    @Transactional(rollbackFor = {BusinessException.class, FacadeException.class})
    public void delete(Goodsreceiptposition position, Principal principal) throws FacadeException, BusinessException {
        position = checkAndGetGoodsReceiptPosition(position);
        deletePosition(position, principal);
    }

    @Transactional(rollbackFor = {BusinessException.class, FacadeException.class})
    public void adjust(Goodsreceiptposition position, BigDecimal newAmount, Principal principal) throws FacadeException, BusinessException {
        position = checkAndGetGoodsReceiptPosition(position);
        // ... rest of method
    }
}
```

**Note:** The codebase already uses stronger transactional consistency elsewhere — `StockunitBusinessService.changeReservedAmount()` uses `findByIdForUpdate()` for pessimistic row locking (SBDEV-1710). This establishes precedent for transaction boundaries where needed.

**Risk:** Low to medium. Verify no callers depend on partial commits after checked exceptions.

### Fix 3: Handle Already-Deleted StockUnits Gracefully (Medium)

**Why:** If a prior partial delete moved the stockunit to nirvana but didn't delete the GRP, the user is stuck — they can't delete the GRP because the validation fails, but the GRP is orphaned.

**Current code note:** `StockunitBusinessService.sendStockUnitToNirvana()` already re-fetches the latest stockunit and returns early if it is already on the nirvana unitload (idempotent downstream). The remaining gap is **upstream** in `checkAndGetGoodsReceiptPosition()`, which throws before the delete flow can reach that idempotent helper.

**Important safeguard:** Do NOT blindly skip all validation. Only allow cleanup when the stockunit is already on nirvana / marked `GOING_TO_DELETE`. Stock that was moved to another **active** unitload should still be rejected — that represents a legitimate business-logic conflict that needs user attention.

**File:** `GoodsReceiptPositionService.java`

```java
private Goodsreceiptposition checkAndGetGoodsReceiptPosition(Goodsreceiptposition position) throws BusinessException {
    // ... existing advice state check ...

    Stockunit posStockUnit = stockunitRepository.findById(position.getStockunitId()).get();

    // If stockunit is already in nirvana (marked for deletion), allow the GRP cleanup
    if (posStockUnit.getEntityLock() == WmsConstants.BusinessObjectLockState.GOING_TO_DELETE) {
        return position;  // Skip further validation, just allow GRP deletion
    }

    // Normal validation: stockunit must still be on the original unitload
    if (!position.getUnitloadId().equals(posStockUnit.getUnitloadId())) {
        throw new BusinessException("StockUnit not on UnitLoad anymore!");
    }

    // Validate unitload is still in goods-in area
    Unitload unitLoad = unitloadRepository.findById(position.getUnitloadId()).get();
    Location location = locationRepository.findById(unitLoad.getStoragelocationId()).get();
    LocationArea area = locationAreaRepository.findById(location.getAreaId()).get();
    if (!area.getUseforgoodsin()) {
        throw new BusinessException("UnitLoad not in area for goods in anymore. found location=" + location);
    }

    return position;
}
```

And in `deletePosition()`, handle the already-in-nirvana case:

```java
private void deletePosition(Goodsreceiptposition position, Principal principal) throws FacadeException, BusinessException {
    Stockunit stockUnit = stockunitRepository.findById(position.getStockunitId()).get();

    boolean alreadyInNirvana = stockUnit.getEntityLock() == WmsConstants.BusinessObjectLockState.GOING_TO_DELETE;

    if (!alreadyInNirvana) {
        // Normal flow: send to nirvana, clean up unitload if empty
        Itemdata itemData = itemdataRepository.findById(stockUnit.getItemdataId()).get();
        int total = stockUnit.getAmount().negate().intValue();
        Adviceposition advicePosition = advicepositionRepository.findById(position.getAdvicepositionId()).get();
        String externalId = advicePosition.getExternalid();

        stockunitBusinessService.sendStockUnitToNirvana(stockUnit, WmsConstants.StockRecordType.STOCK_REMOVED, position.getNumber(), null);

        Unitload unitLoad = unitloadRepository.findById(position.getUnitloadId()).get();
        List<Stockunit> stockUnitList = stockunitRepository.findByUnitloadId(unitLoad.getId());
        List<Unitload> childrenUnitLoad = unitloadRepository.findByCarrierunitloadId(unitLoad.getId());
        if (stockUnitList.isEmpty() && childrenUnitLoad.isEmpty()) {
            unitloadBusinessService.sendToNirvana(unitLoad, WmsConstants.CODE_SEND_TO_NIRVANA, position.getNumber(), null);
        }

        // Send stock change message if configured
        String flag = losSyspropRepository.findSysvalueBySyskey(WmsConstants.SYSTEM_PROPERTY_INBOUND_UPDATE_STOCK_IMMEDIATELY_KEY);
        if (Boolean.parseBoolean(flag)) {
            List<StockChangeDto> list = new ArrayList<>();
            list.add(stockunitService.getStockChangeDTO(itemData, total, 0, 0, 0, 0, WmsConstants.CODE_RECEIVING_REGULAR + ": " + externalId));
            messageService.sendStockChangeMessage(list);
        }
    }

    // Always delete the GRP record (even if stockunit was already cleaned up)
    goodsreceiptpositionRepository.delete(position);
}
```

**Risk:** Medium. A too-broad bypass could let users delete GRPs whose stock was legitimately moved elsewhere.

### Fix 4: Add `@Transactional` to `ReceivingService.receiveGoods()` (Medium — separate review)

**Why:** The receiving loop creates multiple unitloads, stockunits, and GRPs. A partial failure mid-loop leaves orphaned entities that can later cause the "not on UnitLoad" error when the user tries to clean up.

**File:** `ReceivingService.java`

```java
@Transactional(rollbackFor = {BusinessException.class, FacadeException.class})
public void receiveGoods(...) throws BusinessException, FacadeException {
    // ... existing code ...
}
```

**Caution:** This method has external side effects:
- **Printing** (`printService.cupsPrint()` at the end) — a transactional rollback after successful printing would create a mismatch (labels printed but no DB records)
- **OMS messaging** (`messageService.sendStockChangeMessage()`) — same concern

These side effects should be audited. Consider moving printing and messaging to after the transaction commits (e.g., using `TransactionSynchronizationManager.registerSynchronization()` or an `@TransactionalEventListener`).

**Risk:** Medium. Requires side-effect audit.

---

## 7. Impact Assessment

| Fix | Risk | Effort | Impact |
|-----|------|--------|--------|
| Fix 1: ID-based comparison | Low | Small | Eliminates false-positive errors from reference equality and cache behavior |
| Fix 2: @Transactional with rollbackFor | Low-Medium | Small | Prevents partial failures and race conditions |
| Fix 3: Handle already-deleted stockunits | Medium | Medium | Unblocks users stuck with orphaned GRP records |
| Fix 4: @Transactional on receiveGoods | Medium | Medium | Prevents orphaned entities; requires side-effect audit |

**Recommended implementation order:** Fix 1 → Fix 2 → Fix 3 → Fix 4

Fix 1 is the simplest, lowest-risk, and most impactful — it eliminates an entire class of false positives and works correctly in all environments. Fix 2 prevents future data inconsistency. Fix 3 unblocks users already affected by orphaned GRPs. Fix 4 should be reviewed separately due to side-effect concerns.

---

## 8. Existing Data Cleanup

For any existing orphaned `Goodsreceiptposition` records, a **read-only diagnostic query** should be run first:

```sql
-- Step 1: Find ALL GRPs where stockunit is no longer on the referenced unitload
-- Classify by stock destination before taking action
SELECT grp.id, grp.number, grp.stockunit_id, grp.unitload_id,
       su.unitload_id AS current_unitload_id, su.entity_lock,
       ul.labelid AS current_unitload_label,
       loc.name AS current_location,
       la.useforstorage AS in_storage_area,
       CASE
           WHEN su.entity_lock = 2 THEN 'GOING_TO_DELETE - safe to cleanup GRP'
           WHEN ul.labelid = 'Nirwana' THEN 'ON_NIRVANA_UL - safe to cleanup GRP'
           ELSE 'MOVED_TO_ACTIVE_UL - investigate before cleanup'
       END AS classification
FROM goodsreceiptposition grp
JOIN stockunit su ON su.id = grp.stockunit_id
JOIN unitload ul ON ul.id = su.unitload_id
JOIN storagelocation loc ON loc.id = ul.storagelocation_id
JOIN locationarea la ON la.id = loc.area_id
WHERE su.unitload_id != grp.unitload_id
ORDER BY classification, grp.id;
```

**Cleanup guidelines:**
- **`GOING_TO_DELETE` / `ON_NIRVANA_UL`**: Stock is already removed. The GRP is orphaned and safe to delete.
- **`MOVED_TO_ACTIVE_UL`**: Stock was moved legitimately (putaway, transfer, etc.). Investigate business intent before deleting the GRP — this may indicate the GRP should be updated rather than deleted.

**Note:** `WHERE su.entity_lock = 2` corresponds to `WmsConstants.BusinessObjectLockState.GOING_TO_DELETE`.

---

## 9. Required Tests

When implementing the fixes, add focused tests for:

1. **Delete/adjust when stock remains on original unitload** — should succeed
2. **Delete when stock already moved to nirvana** (`GOING_TO_DELETE`) — should succeed (Fix 3)
3. **Delete when stock moved to another active unitload** — should fail with clear error
4. **Rollback behavior on checked exceptions inside delete/adjust** — verify `rollbackFor` works correctly; no partial data should persist on failure
5. **Adjust to zero amount** — triggers `deletePosition()` path via `adjust()`, should behave identically to delete

---

## Appendix A: Review History

| Date | Action |
|------|--------|
| 2026-03-12 | Initial analysis written |
| 2026-03-13 | Re-validated against current codebase — all issues confirmed present |
| 2026-03-13 | Review feedback incorporated (see `260424-receiving-stockunit-unitload-error-analysis-review.md`) |
| 2026-03-13 | Fix 1 + Fix 2 + Fix 3 implemented; 14 unit tests passing (4 new tests added) |

**Implementation summary:**
- `GoodsReceiptPositionService.java`: Added `@Transactional(rollbackFor = {BusinessException.class, FacadeException.class})` to `delete()` and `adjust()`; replaced `.contains()` with ID-based comparison; added nirvana bypass in `checkAndGetGoodsReceiptPosition()` and `deletePosition()`
- `GoodsReceiptPositionServiceUnitTest.java`: Updated existing tests for ID-based comparison; added 4 new tests: `delete_stockunitAlreadyInNirvana_deletesGrpWithoutSendingToNirvana`, `delete_stockunitMovedToActiveUnitload_throwsBusinessException`, `adjust_stockunitAlreadyInNirvana_deletesGrpWhenAdjustedToZero`, `delete_stockunitOnSameUnitloadIdComparison_succeedsWithDifferentObjectReferences`

**Key changes from review:**
- Corrected `open-in-view` assumption: dev config explicitly sets `false`, making the `.contains()` bug **actively broken** in dev, not just a latent risk
- Added `rollbackFor` requirement for `@Transactional` — both exception types are checked
- Rewritten section 4.3 (concurrent operations): clarified 4 direct mutation sites vs many indirect callers
- Moved UI race condition to independent UX issue (section 4.4), not a core RCA contributor
- Removed Fix 5 (batch delete transaction) — UI is primarily single-record delete; batch path is not fully wired
- Added side-effect audit caution for Fix 4 (`receiveGoods` printing/messaging)
- Enhanced data cleanup queries with classification and safety guidelines
- Added required test cases section
