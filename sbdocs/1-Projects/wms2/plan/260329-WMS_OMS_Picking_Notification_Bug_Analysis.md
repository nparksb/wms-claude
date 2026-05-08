# WMS→OMS Picking Notification Bug Analysis

**Date:** 2026-03-29
**Status:** Analyzed — Ready for Review & Implementation
**Priority:** Critical
**Symptom:** WMS sends picking notifications to OMS but OMS order status doesn't change

---

## Root Cause: CRITICAL Bug in WMS `ManageOrderService`

### `catch (IOException)` is Dead Code — HTTP Errors Are Uncaught

`HttpRestService.post()` was refactored from JAX-RS (threw `IOException`) to Spring `RestClient.exchange()` (throws `RestClientException`, a `RuntimeException`). But all 6 callers in `ManageOrderService` still catch only `IOException` — which is **never thrown**.

**Impact:** Any HTTP failure (OMS returns 4xx/5xx, connection refused, timeout) throws an uncaught `RestClientException` that:
- In `afterCommit` callbacks: caught by outer `catch (Exception e)` — logged but **no `Message` record with FAILED status** is created
- In direct calls: propagates up and may roll back the transaction
- **Zero visibility** into failures — no database record, just a log line

**Files:** `ManageOrderService.java` lines 111, 166, 225, 274, 349, 399

**Fix:** Change `catch (IOException e)` → `catch (Exception e)` at all 6 locations.

---

## Additional Bugs Found

### WMS Side

| # | Bug | Severity | File:Line | Fix |
|---|-----|----------|-----------|-----|
| 1 | `catch (IOException)` is dead code — HTTP errors uncaught | 🔴 CRITICAL | `ManageOrderService.java:111,166,225,274,349,399` | **DONE** — Changed all 7x to `catch (Exception e)` |
| 2 | `app.production` flag gates ALL notifications — if `false`, nothing is sent | ~~🔴 CRITICAL~~ → ✅ CONFIRMED OK | `PickingorderBusinessService.java:246,488` | Verified: `app.production=true` in application.properties |
| 3 | `afterCommit` callbacks don't persist FAILED Message on error | ✅ RESOLVED | `PickingorderBusinessService.java:263,497` | Fix #1 (catch Exception) + Fix B (@Transactional REQUIRES_NEW on createServiceLog) + Fix D (verbose logging) + Fix E (null-URL guard) |

### OMS Side

| # | Bug | Severity | File:Line | Fix |
|---|-----|----------|-----------|-----|
| 4 | `assignedToteID` missing tenant DB connection config | 🔴 CRITICAL | `LegacyWmsController.php:783` | Add `Config::set('database.connections.tenant.database', ...)` + `DB::purge('tenant')` |
| 5 | Legacy routes not covered by `shouldRenderJsonWhen` | 🟡 HIGH | `bootstrap/app.php:77` | Add `$request->is('services/*')` to condition |
| 6 | No auth middleware on WMS callback routes | 🟡 HIGH (security) | `bootstrap/app.php:23` | Add Basic Auth validation middleware |
| 7 | `finishedPicking` requires `batch_label` match — may fail if WMS batch ID doesn't match OMS batch_criteria | 🟡 MEDIUM | `LegacyWmsController.php:1452` | Verify data sync between WMS `batchid` and OMS `batch_label` |

---

## The Complete Notification Chain

```
Mobile Pick Action
  → MobilePickingService.processPick()
    → PickingorderBusinessService.confirmPick()
      → if last pick for order → order.setState(PICKED)
      → afterCommit → manageOrderService.customerOrderPicked(order)
        → ManageOrderService builds OrderBatchDto JSON
        → HttpRestService.post(omsUrl, json)
          → POST /services/call/finishedPicking (Basic Auth + x-tenant header)
            → OMS LegacyWmsController.finishedPicking()
              → Sets parcel_status = 25
```

### All 4 Notification Points

| WMS Event | ManageOrderService Method | OMS Endpoint | OMS Sets Status |
|-----------|--------------------------|-------------|-----------------|
| Tote assigned | `customerOrderToteAssigned` | `POST /services/call/assignedToteID` | Updates `ul_code` |
| Released for picking | `customerOrderReleaseForPicking` | `POST /services/call/readytopick` | `parcel_status = 23` |
| Picking started | `customerOrderPickingStarted` | `POST /services/call/picking` | `parcel_status = 24` |
| Picking finished | `customerOrderPicked` | `POST /services/call/finishedPicking` | `parcel_status = 25` |

---

## Implementation Plan

### Phase 1: WMS Fixes (Critical — immediate)

| Step | Action | File | Effort |
|------|--------|------|--------|
| 1 | Change 7x `catch (IOException e)` → `catch (Exception e)` | `ManageOrderService.java` | **DONE** |
| 2 | ~~Verify `app.production=true`~~ | ✅ Confirmed `true` | **DONE** |
| 3 | ~~Add FAILED Message persistence~~ | Resolved by Fix #1 | **DONE** |

### WMS Implementation Status (2026-03-29)

**Fix applied:** Changed all 7 `catch (IOException e)` blocks to `catch (Exception e)` in `ManageOrderService.java`. Also removed unused `import java.io.IOException`.

**282 unit tests pass, 0 failures.**

This fix ensures:
- HTTP failures (RestClientException) are now caught instead of propagating uncaught
- FAILED Message records are created in the `message` table with status "503"
- Service Log page will show both successful and failed OMS notifications
- `afterCommit` callbacks benefit automatically since ManageOrderService handles its own error logging

### Phase 2: OMS Fixes (Critical — immediate)

| Step | Action | File | Effort |
|------|--------|------|--------|
| 4 | Add tenant DB config to `assignedToteID` | `LegacyWmsController.php:783` | Small |
| 5 | Fix `shouldRenderJsonWhen` to cover `services/*` | `bootstrap/app.php:77` | Small |
| 6 | Add Basic Auth middleware to legacy routes | New middleware | Medium |
| 7 | Verify `batch_id` ↔ `batch_label` data sync | Data check | None |

---

## Diagnostic Steps

To confirm the root cause immediately:

1. **Check WMS logs** for `RestClientException` or `OMS picked callback failed`:
   ```
   grep -i "RestClientException\|callback failed\|Message was not sent" wms.log
   ```

2. **Check WMS `message` table** for notification records:
   ```sql
   SELECT * FROM message WHERE process_type LIKE '%PICKING%' ORDER BY created DESC LIMIT 20;
   ```
   If no records exist, the notifications are either not being sent or failing silently.

3. **Check `app.production` property**:
   ```
   grep "app.production" application.properties
   ```

4. **Test OMS endpoint directly**:
   ```bash
   curl -X POST https://oms-url/services/call/finishedPicking \
     -H "Content-Type: application/json" \
     -H "X-Tenant: tenant_id" \
     -u "username:password" \
     -d '{"batch_id":"TEST","facility_code":"WH01","positions":[{"unique_id":"TEST-001","tote_label":"T-001"}]}'
   ```
