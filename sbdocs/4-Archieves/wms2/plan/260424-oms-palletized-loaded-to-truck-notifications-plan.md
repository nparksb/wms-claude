# Plan: OMS V2 Notifications for Palletized & Loaded-to-Truck Events

## Context

WMS currently notifies OMS about picking events (`finishedPicking`) and shipping events (`finishedShipping`), but there is a gap: OMS is never notified when a parcel is palletized or when a pallet is loaded onto a truck. This means OMS cannot track the intermediate fulfillment stages between picking and shipping.

This plan adds two new OMS V2 REST calls from WMS:
1. `POST /services/call/palletized` — when parcels are palletized
2. `POST /services/call/loadedToTruck` — when a pallet is loaded to a truck

It also adds a new `LOADED_TO_TRUCK` (680) customer order state and updates the Open Pick Pack Parcels screen to display it.

**Scope:** WMS-side only. OMS endpoint handlers will be implemented separately.

---

## Key Findings from Analysis

### Order-Parcel Relationship
- **WMS:** 1 order = 1 parcel (`Customerorder.parcel_id` → `Unitload.id`)
- **OMS:** 1 order = N parcels (`Order hasMany Parcels`)
- Notification per parcel in WMS = notification per order

### Palletization Entry Points (4 code paths)
| Entry Point | Trigger | Orders per Call |
|-------------|---------|-----------------|
| `MobilePalletizingService.scanPallet()` | Mobile scan | 1 |
| `MobilePalletizingService.scanParcelBulk()` | Mobile bulk scan | 1 |
| `ParcelMonitorViewService.palletise()` | Web UI | N (batch) |
| `ParcelMonitorViewService.palletiseAndTruckLoad()` | Web UI combined | N (batch) |

### Truck Loading Entry Points (2 code paths)
| Entry Point | Trigger | Orders per Call |
|-------------|---------|-----------------|
| `MobileTruckLoadingService.scanGate()` | Mobile scan at gate | N (all parcels on pallet) |
| `ParcelMonitorViewService.palletiseAndTruckLoad()` | Web UI combined | N (batch) |

### Existing Notification Pattern (to reuse)
From `ManageOrderService.customerOrderPicked()` (line 277):
1. Build `OrderBatchDto` with list of `OrderDto` positions
2. Get URL from `syspropRepository.findSysvalueBySyskey(KEY)`
3. POST via `httpRestService.post(url, payload)`
4. Record `Message` via `messageService.createMessage(...)` with status SENT/FAILED

### Parcel Monitor View
- SQL view: `co.state > 600 AND co.state < 700` — a new state 680 falls within this range automatically
- Open Pick Pack screen currently uses upper bound `PALLETIZED(670)` — needs updating to `LOADED_TO_TRUCK(680)`

---

## Suggested JSON Payloads

### POST /services/call/palletized
Reuses `OrderBatchDto` wrapper. Adds `pallet_label` to `OrderDto`.
```json
{
  "facility_code": "WH01",
  "batch_id": "BATCH-001",
  "positions": [
    {
      "unique_id": "EXT-ORDER-001",
      "parcel_external_number": "PARCEL-001",
      "pallet_label": "PLT-001"
    },
    {
      "unique_id": "EXT-ORDER-002",
      "parcel_external_number": "PARCEL-002",
      "pallet_label": "PLT-001"
    }
  ]
}
```

### POST /services/call/loadedToTruck
Reuses `OrderBatchDto` wrapper. Adds `bol_number` at batch level.
```json
{
  "facility_code": "WH01",
  "batch_id": "BATCH-001",
  "bol_number": "BOL-001",
  "positions": [
    {
      "unique_id": "EXT-ORDER-001",
      "parcel_external_number": "PARCEL-001",
      "pallet_label": "PLT-001"
    }
  ]
}
```

---

## Implementation Plan

### Change 1 — Add `LOADED_TO_TRUCK` state constant

**File:** `src/main/java/net/aim_ai/wms/service/WmsConstants.java`

Add to `State` class (after `PALLETIZED = 670`, before `FINISHED = 700`):
```java
/**
 * The parcel is loaded to a truck.
 */
public static final int LOADED_TO_TRUCK = 680;
```

Add case to `State.getCodeText()` (after PALLETIZED case):
```java
case LOADED_TO_TRUCK:
    return "Loaded to Truck";
```

### Change 2 — Add new system property URL constants

**File:** `src/main/java/net/aim_ai/wms/service/WmsConstants.java`

Add after `SYSTEM_PROPERTY_WEBSERVICE_ORDER_BATCH_SHIPPED` constants (line ~883). Follow existing `ORDER_BATCH_*` naming convention:
```java
public static final String SYSTEM_PROPERTY_WEBSERVICE_ORDER_BATCH_PALLETIZED_URL_KEY = "WEBSERVICE_ORDER_BATCH_PALLETIZED";
public static final String SYSTEM_PROPERTY_WEBSERVICE_ORDER_BATCH_PALLETIZED_URL_DEFAULT_VALUE = "https://oms-XXXXX.siteboss.net/services/call/palletized";
public static final String SYSTEM_PROPERTY_WEBSERVICE_ORDER_BATCH_LOADED_TO_TRUCK_URL_KEY = "WEBSERVICE_ORDER_BATCH_LOADED_TO_TRUCK";
public static final String SYSTEM_PROPERTY_WEBSERVICE_ORDER_BATCH_LOADED_TO_TRUCK_URL_DEFAULT_VALUE = "https://oms-XXXXX.siteboss.net/services/call/loadedToTruck";
```

### Change 3 — Add new MessageProcessType constants

**File:** `src/main/java/net/aim_ai/wms/service/WmsConstants.java`

Add to `MessageProcessType` class (after `ORDER_BATCH_SHIPPED`). Follow existing `ORDER_BATCH_*` naming convention:
```java
public static final String ORDER_BATCH_PALLETIZED = "ORDER_BATCH_PALLETIZED";
public static final String ORDER_BATCH_LOADED_TO_TRUCK = "ORDER_BATCH_LOADED_TO_TRUCK";
```

### Change 4 — Add `pallet_label` field to OrderDto

**File:** `src/main/java/net/aim_ai/wms/json/OrderDto.java`

Add field + explicit getter/setter (no Lombok in this class):
```java
@JsonProperty("pallet_label")
private String palletLabel;

public String getPalletLabel() { return palletLabel; }
public void setPalletLabel(String palletLabel) { this.palletLabel = palletLabel; }
```

### Change 5 — Add `bol_number` field to OrderBatchDto

**File:** `src/main/java/net/aim_ai/wms/json/OrderBatchDto.java`

Add field + explicit getter/setter (no Lombok in this class):
```java
@JsonProperty("bol_number")
private String bolNumber;

public String getBolNumber() { return bolNumber; }
public void setBolNumber(String bolNumber) { this.bolNumber = bolNumber; }
```

Also update `toString()` to include the new field (append `bolNumber` to the existing `toString()` method).

### Change 6 — Create notification methods in ManageOrderService

**File:** `src/main/java/net/aim_ai/wms/service/ManageOrderService.java`

Add two new methods following the `customerOrderPicked()` pattern exactly. **Critical:** use `ObjectMapper` with `setSerializationInclusion(JsonInclude.Include.NON_NULL)` before serializing. Wrap HTTP call + message recording in `try { ... } catch (IOException e) { ... }` — log SENT on success, FAILED on error, matching the existing pattern.

**Dependencies:** `UnitloadRepository` is already injected — no constructor change needed.

#### `customerOrderPalletized(List<Customerorder> orders, Unitload pallet)`
1. Build `OrderBatchDto` via existing `createOrderBatch(orders.get(0))`
2. For each order:
   - Create `OrderDto` via `addOrderToOrderBatch(order, batchDto)`
   - Set `orderDto.setParcelExternalNumber(parcelLabel)` — look up from `unitloadRepository.findById(order.getParcelId())`
   - Set `orderDto.setPalletLabel(pallet.getLabelid())`
3. Serialize with `ObjectMapper` (NON_NULL inclusion)
4. Get URL from `syspropRepository.findSysvalueBySyskey(SYSTEM_PROPERTY_WEBSERVICE_ORDER_BATCH_PALLETIZED_URL_KEY)`
5. POST via `httpRestService.post(url, payload)`
6. Record `Message` with `MessageProcessType.ORDER_BATCH_PALLETIZED`

#### `customerOrderLoadedToTruck(List<Customerorder> orders, Unitload pallet, Billoflading bol)`
1. Build `OrderBatchDto` via `createOrderBatch(orders.get(0))`
2. Set `batchDto.setBolNumber(bol.getNumber())`
3. For each order:
   - Create `OrderDto` via `addOrderToOrderBatch(order, batchDto)`
   - Set `parcelExternalNumber` and `palletLabel`
4. Serialize with `ObjectMapper` (NON_NULL inclusion)
5. Get URL from `syspropRepository.findSysvalueBySyskey(SYSTEM_PROPERTY_WEBSERVICE_ORDER_BATCH_LOADED_TO_TRUCK_URL_KEY)`
6. POST via `httpRestService.post(url, payload)`
7. Record `Message` with `MessageProcessType.ORDER_BATCH_LOADED_TO_TRUCK`

### Change 7 — Wire palletized notifications into 4 palletization entry points

**Important:** Guard all notification calls with a state check to prevent duplicate notifications if a parcel is re-palletized or enters multiple code paths. Only notify for orders that actually transitioned to PALLETIZED state.

#### 7a. `MobilePalletizingService.scanPallet()` (line ~218)
After `unitloadBusinessService.transferUnitLoadToCarrier()` succeeds:
```java
// Only notify if order actually transitioned (state was set to PALLETIZED above)
manageOrderService.customerOrderPalletized(Collections.singletonList(order), pallet);
```
Inject `ManageOrderService` into `MobilePalletizingService` constructor.

#### 7b. `MobilePalletizingService.scanParcelBulk()` (line ~348)
After `transferUnitLoadToCarrier()` succeeds:
```java
manageOrderService.customerOrderPalletized(Collections.singletonList(order), pallet);
```

#### 7c. `ParcelMonitorViewService.palletise()` (line ~176)
After the loop completes (all parcels palletized), call once with the full list:
```java
manageOrderService.customerOrderPalletized(customerOrderList, pallet);
```
Inject `ManageOrderService` into `ParcelMonitorViewService` constructor.

#### 7d. `ParcelMonitorViewService.palletiseAndTruckLoad()` (line ~282)
After palletization loop completes, before truck loading logic.
**Note:** This method may be dead code — no controller was found calling it. Implement for completeness, but verify it is reachable before testing.
Only notify for orders that were actually palletized in this call (filter by orders whose state was < PALLETIZED before the loop):
```java
// Filter to only orders that transitioned during this call
List<Customerorder> newlyPalletized = customerOrderList.stream()
    .filter(o -> o.getState() == WmsConstants.State.PALLETIZED)
    .collect(Collectors.toList());
if (!newlyPalletized.isEmpty()) {
    manageOrderService.customerOrderPalletized(newlyPalletized, pallet);
}
```

### Change 8 — Wire loaded-to-truck notifications + set LOADED_TO_TRUCK state

#### 8a. `MobileTruckLoadingService.scanGate()` (line ~287)
After BOL positions are created for all parcels:
1. Set order state to LOADED_TO_TRUCK for each order:
   ```java
   for (Customerorder order : customerOrderList) {
       if (order.getState() < WmsConstants.State.LOADED_TO_TRUCK) {
           order.setState(WmsConstants.State.LOADED_TO_TRUCK);
           customerorderRepository.save(order);
       }
   }
   ```
2. Send notification:
   ```java
   manageOrderService.customerOrderLoadedToTruck(customerOrderList, pallet, billOfLading);
   ```
Inject `ManageOrderService` into `MobileTruckLoadingService` constructor.

#### 8b. `ParcelMonitorViewService.palletiseAndTruckLoad()` (line ~343)
After truck loading logic completes:
1. Set order state to LOADED_TO_TRUCK for each order
2. Send notification:
   ```java
   manageOrderService.customerOrderLoadedToTruck(customerOrderList, pallet, billOfLading);
   ```

### Change 9 — Update Open Pick Pack screen upper bound

**File:** `src/main/java/net/aim_ai/wms/controller/CustomerOrderController.java`

Line 163 — change:
```java
return dtoViewService.getPickPackOrders(WmsConstants.State.RAW, WmsConstants.State.PALLETIZED, keyword, p);
```
to:
```java
return dtoViewService.getPickPackOrders(WmsConstants.State.RAW, WmsConstants.State.LOADED_TO_TRUCK, keyword, p);
```

### Change 10 — Add Flyway migration for system properties

**File:** `src/main/resources/db/migration/V2.1.02__add_palletized_loaded_to_truck_sysprops.sql`

```sql
insert into los_sysprop (id, groupname, syskey, sysvalue, description, additionalcontent, client_id, version, hidden, workstation, entity_lock, created, modified) values(140, 'Backend', 'WEBSERVICE_ORDER_BATCH_PALLETIZED', 'https://oms-XXXXX.siteboss.net/services/call/palletized', 'OMS endpoint for palletized notification', 'URL for OMS palletized service call.', 0, 0, FALSE, 'DEFAULT', 0, '2026-02-19 10:00:00.000', '2026-02-19 10:00:00.000');
insert into los_sysprop (id, groupname, syskey, sysvalue, description, additionalcontent, client_id, version, hidden, workstation, entity_lock, created, modified) values(141, 'Backend', 'WEBSERVICE_ORDER_BATCH_LOADED_TO_TRUCK', 'https://oms-XXXXX.siteboss.net/services/call/loadedToTruck', 'OMS endpoint for loaded-to-truck notification', 'URL for OMS loaded-to-truck service call.', 0, 0, FALSE, 'DEFAULT', 0, '2026-02-19 10:00:00.000', '2026-02-19 10:00:00.000');
```

**Note:** IDs 140/141 are the next sequential IDs after the last used ID (139 in `V1.1.03`). Verify no other branch has claimed these before merging.

---

## Files Modified Summary

| File | Change |
|------|--------|
| `WmsConstants.java` | Add `LOADED_TO_TRUCK=680` state, `getCodeText()` case, 2 URL constants, 2 MessageProcessType constants |
| `OrderDto.java` | Add `pallet_label` field + getter/setter |
| `OrderBatchDto.java` | Add `bol_number` field + getter/setter + update `toString()` |
| `ManageOrderService.java` | Add `customerOrderPalletized()` and `customerOrderLoadedToTruck()` methods |
| `MobilePalletizingService.java` | Inject `ManageOrderService`; call `customerOrderPalletized()` in `scanPallet()` and `scanParcelBulk()` |
| `ParcelMonitorViewService.java` | Inject `ManageOrderService`; call `customerOrderPalletized()` in `palletise()`, both notifications in `palletiseAndTruckLoad()` (with state guard) |
| `MobileTruckLoadingService.java` | Inject `ManageOrderService`; set LOADED_TO_TRUCK state + call `customerOrderLoadedToTruck()` in `scanGate()` |
| `CustomerOrderController.java` | Update Open Pick Pack upper bound to LOADED_TO_TRUCK |
| `V2.1.02__add_palletized_loaded_to_truck_sysprops.sql` (new) | Flyway migration for new sysprop entries (IDs 140, 141) |
| `V2.1.03__update_dashboard_summary_view.sql` (new) | Flyway migration to add `order_loaded_to_truck` column to dashboard summary view |

### Change 11 — Update dashboard summary view for LOADED_TO_TRUCK count

**File:** `src/main/resources/db/migration/V2.1.03__update_dashboard_summary_view.sql` (new)

The existing `dashboard_summary_view` (defined in `V1.1.01__wms_views.sql`) counts `order_palletised` as exactly `co.state = 670`. Orders at state 680 (LOADED_TO_TRUCK) would not appear in any dashboard bucket. Add a new `order_loaded_to_truck` column:

```sql
CREATE OR REPLACE VIEW dashboard_summary_view AS
-- Recreate the full view definition from V1.1.01, adding:
--   count(CASE WHEN co.state = 680 THEN 1 END) AS order_loaded_to_truck
-- after the existing order_palletised column.
-- Copy the full CREATE OR REPLACE VIEW statement from V1.1.01 and add the new column.
```

**Note:** The full view SQL must be copied from `V1.1.01__wms_views.sql` (line ~100-130) and modified — Flyway cannot ALTER a VIEW column. Check if any frontend (wms-web-ui) reads this view to determine if the new column needs frontend handling.

---

## Verification

1. **Build:** `mvn clean package -DskipTests` — must compile cleanly
2. **Existing tests:** `mvn test` — no regressions
3. **Manual flow test (palletized):**
   - Palletize a parcel via mobile or web UI
   - Verify `Message` record created with process=`ORDER_BATCH_PALLETIZED`
   - Verify JSON payload contains `facility_code`, `batch_id`, `unique_id`, `parcel_external_number`, `pallet_label`
4. **Manual flow test (loaded to truck):**
   - Load a pallet via mobile `scanGate` or web UI
   - Verify order state changed to `LOADED_TO_TRUCK` (680)
   - Verify `Message` record created with process=`ORDER_BATCH_LOADED_TO_TRUCK`
   - Verify JSON payload contains `bol_number`
5. **Open Pick Pack screen:**
   - Verify orders with `LOADED_TO_TRUCK` state appear on the screen
   - Verify status displays as "Loaded to Truck"
6. **Dashboard:**
   - Verify `order_loaded_to_truck` column appears in dashboard summary view
   - Verify count reflects orders at state 680
7. **Duplicate guard:**
   - Re-palletize an already-palletized parcel — verify no duplicate `ORDER_BATCH_PALLETIZED` message is created

---

## Review Notes (from architect review)

### Changes applied from review
1. **Naming convention aligned** — `ORDER_BATCH_PALLETIZED` / `ORDER_BATCH_LOADED_TO_TRUCK` (was `ORDER_PALLETIZED` / `ORDER_LOADED_TO_TRUCK`) to match existing `ORDER_BATCH_*` pattern
2. **Duplicate notification guard** — Added state check in `palletiseAndTruckLoad()` (Change 7d) to only notify for orders that actually transitioned
3. **Dashboard summary view** — Added Change 11 to create `order_loaded_to_truck` column (state 680 had no dashboard bucket)
4. **Explicit getter/setter** — OrderDto and OrderBatchDto use manual getters/setters (no Lombok)
5. **ObjectMapper config** — Explicitly noted `NON_NULL` serialization inclusion requirement in Change 6
6. **UnitloadRepository** — Confirmed already injected in ManageOrderService, no constructor change needed
7. **OrderBatchDto.toString()** — Must include new `bolNumber` field

### Known limitations (pre-existing, not introduced by this plan)
- **No idempotency** — If HTTP call succeeds but message recording fails, re-running could send duplicates to OMS. Same gap exists in `customerOrderPicked()`.
- **No WEBSERVICE_BEHAVIOUR check** — Constants exist (`SEND`/`DISCARD`/`KEEP`) but are not checked by any existing notification method. Consistent with current code.
- **`palletiseAndTruckLoad()` reachability** — No controller calls this method. May be dead code. Implemented for completeness; verify before testing.
