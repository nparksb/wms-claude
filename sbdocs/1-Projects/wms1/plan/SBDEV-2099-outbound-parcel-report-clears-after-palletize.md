# SBDEV-2099: Outbound Parcel Report Clears Results After Palletizing with "Unpalletized" Filter

**Ticket:** SBDEV-2099
**Priority:** High | **Points:** 2 | **Type:** Bug
**Assignees:** Arden Latraca, Nam Park
**Date:** 2026-04-10
**Updated:** 2026-04-10 (v3 — definitive root cause: empty-string clientNumber)

---

## 1. Problem Statement

When using the "Unpalletized" filter in the outbound parcel report, palletizing selected parcels causes the entire table to go blank — even when unpalletized parcels still remain. The table should refresh and continue displaying remaining unpalletized parcels.

---

## 2. Root Cause Analysis (Definitive — v3)

### Previous investigations (v1, v2) were inconclusive

- **v1:** Identified missing sort/order params and pagination edge case → fixes applied, bug persisted.
- **v2:** Identified watcher feedback loop and missing `try/finally` → fixes applied, bug persisted.

### Definitive Root Cause: Empty-String `clientNumber` in Palletize Action

**Console log proof:**
```
urlPart:  ?page=0&size=10&keyword=&clientNumber=&parcelFilter=Unpalletized
searchReport returned {content: Array(0), totalElements: 0}
```

The API returns **zero results** because `clientNumber=` (empty string) is sent to the backend, and the JPQL query filters by `p.clientNumber = ''` — matching nothing.

### The Bug Chain (3 links)

#### Link 1: Store converts `null` to `''` (empty string)

**File:** `wms-web-ui/store/reports/outboundParcel.js:139`

```javascript
const clientNumber = context.state.shipperFilter || ''  // null → '' (BUG)
```

When no shipper is selected, `shipperFilter` is `null`. The `|| ''` fallback converts it to empty string.

#### Link 2: `searchReport` sends empty string to backend

**File:** `wms-web-ui/store/reports/outboundParcel.js:69-71`

```javascript
if (data.clientNumber != null && data.clientNumber !== 'All Shippers') {
  urlPart += '&clientNumber=' + data.clientNumber   // '' passes both checks!
}
```

Empty string `''` is **not null** and **not 'All Shippers'**, so `&clientNumber=` is appended to the URL.

#### Link 3: Backend JPQL treats empty string as a filter value (not "no filter")

**File:** `wms-api/src/main/java/net/aim_ai/wms/repo/jpa/ParcelMonitorViewRepository.java:37`

```sql
AND (p.clientNumber = ?2 OR ?2 IS NULL)
```

Empty string `''` is **NOT NULL** in JPQL/SQL, so the query evaluates `p.clientNumber = ''` — which matches **zero records** because all parcels have real client numbers, not empty strings.

### Why `updateTable()` Works But `palletize` Doesn't

| Call site | `clientNumber` value | Result |
|-----------|---------------------|--------|
| `updateTable()` (component line 401) | `this.shipper` → `null` (from computed) | `null != null` is `false` → param **not sent** → backend returns all clients ✓ |
| `palletize` action (store line 139) | `context.state.shipperFilter \|\| ''` → `''` | `'' != null` is `true` → param **sent as empty** → backend filters by `''` → 0 results ✗ |

### Compounding Issue: `parcelFilter` Also Falls Back to Empty String

**File:** `wms-web-ui/store/reports/outboundParcel.js:138`

```javascript
const parcelFilter = context.state.parcelFilter || ''  // could also be problematic
```

If `parcelFilter` is `null`, it becomes `''`. In the backend (`ViewDtoService.java:1271`):
```java
if (parcelFilter == null || "All".equals(parcelFilter)) {
```

Empty string `''` is not `null` and not `"All"`, so it falls through to the `else` (Unpalletized) branch. This happens to work by accident, but is fragile.

---

## 3. Architecture Overview

### Data Flow

```
outboundParcelReport.vue  →  store/outboundParcel.js  →  ReportController.java  →  ViewDtoService.java  →  ParcelMonitorViewRepository.java
     (component)                (Vuex store)               (REST endpoint)           (service layer)          (JPA queries)
```

### Backend

| File | Role |
|------|------|
| `ReportController.java:365-384` | `/v3/report/parcelMonitorView` endpoint — `clientNumber` is `required=false` |
| `ViewDtoService.java:1268-1319` | Routes to query based on parcelFilter; passes `clientNumber` to repo |
| `ParcelMonitorViewRepository.java:25-38` | JPQL queries with `(p.clientNumber = ?2 OR ?2 IS NULL)` |
| `BillOfLadingController.java:314-351` | `/v3/billOfLading/palletize` — returns `{field, message}` on success |

### Frontend

| File | Role |
|------|------|
| `components/reports/outboundParcelReport.vue` | Main report component — `updateTable()` correctly passes `null` |
| `store/reports/outboundParcel.js` | Vuex store — `palletize` action incorrectly passes `''` |
| `components/reports/popups/palletizeOutboundParcel.vue` | Palletization dialog |

---

## 4. Fix Design

### Fix A: Stop Converting `null` to `''` in Palletize Action (Primary — Root Cause)

**Confidence: 99%** — Console logs directly prove this is the cause.

**File:** `wms-web-ui/store/reports/outboundParcel.js:137-140`

```javascript
// Before (sends '' which matches zero records):
const search = context.state.list?.search || ''
const parcelFilter = context.state.parcelFilter || ''
const clientNumber = context.state.shipperFilter || ''

// After (sends null which skips the clientNumber filter):
const search = context.state.list?.search || ''
const parcelFilter = context.state.parcelFilter || 'All'
const clientNumber = context.state.shipperFilter || null
```

**Why this works:** When `clientNumber` is `null`, the `searchReport` action's check `data.clientNumber != null` is `false`, so `&clientNumber=` is never appended. The backend receives no `clientNumber` param, treats it as `null`, and the JPQL `?2 IS NULL` clause kicks in — returning all clients.

The `parcelFilter` fallback is also corrected from `''` to `'All'` for robustness, matching the backend's expected values.

### Fix B: Add Empty-String Guard in `searchReport` (Defense in Depth)

**Confidence: 95%**

**File:** `wms-web-ui/store/reports/outboundParcel.js:69-71`

```javascript
// Before:
if (data.clientNumber != null && data.clientNumber !== 'All Shippers') {
  urlPart += '&clientNumber=' + data.clientNumber
}

// After (also reject empty string):
if (data.clientNumber != null && data.clientNumber !== '' && data.clientNumber !== 'All Shippers') {
  urlPart += '&clientNumber=' + data.clientNumber
}
```

This prevents any future caller from accidentally sending an empty `clientNumber`.

### Fix C: Backend Defense — Handle Empty String in JPQL (Defense in Depth)

**Confidence: 90%**

**File:** `wms-api/src/main/java/net/aim_ai/wms/repo/jpa/ParcelMonitorViewRepository.java`

All three JPQL queries use `(p.clientNumber = ?2 OR ?2 IS NULL)`. Add empty-string handling:

```sql
-- Before:
AND (p.clientNumber = ?2 OR ?2 IS NULL)

-- After:
AND (p.clientNumber = ?2 OR ?2 IS NULL OR ?2 = '')
```

Apply to all three query methods: `findByKeyword`, `findByKeywordAndParcelPalletized`, `findByKeywordAndParcelUnpalletized`.

**Note:** The native SQL query `findByClientOffsetAndLimit` already handles this correctly with `COALESCE`.

### Fix D: Keep Previous Watcher + Guard Fixes (Already Applied — Still Valuable)

The watcher loop fix (Fix 1 from v2) and `try/finally` guard (Fix 2 from v2) remain applied and are still valuable as defensive improvements, even though they weren't the primary cause of this specific blank-table symptom.

### Fix E: Keep Sort State + Page Reset (Already Applied — Still Valuable)

Sort state persistence and page-1 reset from v1 remain applied.

---

## 5. File Change Summary

| File | Change | Priority | Status |
|------|--------|----------|--------|
| `wms-web-ui/store/reports/outboundParcel.js:139` | **Fix A:** `\|\| ''` → `\|\| null` for clientNumber; `\|\| ''` → `\|\| 'All'` for parcelFilter | **Critical** | TODO |
| `wms-web-ui/store/reports/outboundParcel.js:69` | **Fix B:** Add `!== ''` check in searchReport | High | TODO |
| `wms-api/.../ParcelMonitorViewRepository.java` | **Fix C:** Add `OR ?2 = ''` to 3 JPQL queries | Medium | TODO |
| `wms-web-ui/components/reports/outboundParcelReport.vue` | **Fix D:** Watcher loop + try/finally | Already applied | Done |
| `wms-web-ui/store/reports/outboundParcel.js` | **Fix E:** Sort state + page reset | Already applied | Done |

---

## 6. Implementation Steps

### Step 1: Fix `palletize` action null fallbacks (Fix A — Root Cause)
- Change `context.state.shipperFilter || ''` → `context.state.shipperFilter || null`
- Change `context.state.parcelFilter || ''` → `context.state.parcelFilter || 'All'`

### Step 2: Add empty-string guard in `searchReport` (Fix B — Defense)
- Add `data.clientNumber !== ''` to the existing `if` check

### Step 3: Fix backend JPQL queries (Fix C — Defense)
- Add `OR ?2 = ''` to all three `ParcelMonitorViewRepository` query methods

### Step 4: Verify all previously applied fixes remain in place (Fix D & E)

### Step 5: Manual verification
- No shipper selected + "Unpalletized" filter → palletize → remaining parcels visible
- Shipper selected + "Unpalletized" filter → palletize → remaining parcels visible
- Check console: `urlPart` should NOT contain `clientNumber=&` or `clientNumber=`
- Check console: `searchReport returned` should have `content` with items

---

## 7. Testing Plan

### Manual Tests
- [ ] No shipper + "Unpalletized" filter: palletize subset → remaining unpalletized parcels visible
- [ ] With shipper + "Unpalletized" filter: palletize subset → remaining parcels for that shipper visible
- [ ] No shipper + "All" filter: palletize → table refreshes correctly
- [ ] Sort by column, then palletize → sort order preserved after refresh
- [ ] Palletize all parcels on current page → table resets to page 1
- [ ] Search keyword + filter + palletize → all filters preserved after refresh
- [ ] Console: verify `urlPart` does NOT contain `clientNumber=&` when no shipper selected

### Regression Tests
- [ ] Sorting works (click column headers)
- [ ] Filtering works (All / Palletized / Unpalletized)
- [ ] Shipper filter works — selecting a shipper correctly filters results
- [ ] Shipper filter "All Shippers" shows all results
- [ ] Keyword search works
- [ ] Pagination works (change page, items per page)
- [ ] Export still works
- [ ] Parcel detail view still works

---

## 8. Risks & Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| `parcelFilter` fallback `'All'` may not match store default | Low | Store state initializes `parcelFilter: 'All'` — the fallback only applies if state is somehow null, and `'All'` matches the backend's expected value |
| Backend `OR ?2 = ''` may have JPQL parsing issues | Low | Standard JPQL string comparison; can be tested with `mvn test` |
| Other callers of `searchReport` may also pass empty `clientNumber` | Low | Fix B guards `searchReport` itself, catching all callers |

---

## 9. Investigation History

| Version | Date | Hypothesis | Outcome |
|---------|------|-----------|---------|
| v1 | 2026-04-10 | Missing sort/order params + pagination edge case | Fixes applied but insufficient — bug persisted |
| v2 | 2026-04-10 | Watcher feedback loop + loading flag crash | Fixes applied (valuable defensively) but bug persisted |
| **v3** | **2026-04-10** | **Empty-string `clientNumber` in palletize action** | **Confirmed via console logs — backend returns 0 results because JPQL matches `clientNumber = ''`** |

### Key Lesson

The console log `urlPart: ?page=0&size=10&keyword=&clientNumber=&parcelFilter=Unpalletized` with `searchReport returned {content: Array(0)}` proved the root cause was a **data issue** (wrong parameter value), not a **structural issue** (watcher loops, loading flags). Always check the actual API request/response before investigating component reactivity.
