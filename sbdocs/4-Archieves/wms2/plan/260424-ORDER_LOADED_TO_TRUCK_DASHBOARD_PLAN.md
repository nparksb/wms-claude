# Plan: Add `order_loaded_to_truck` Column to Pick Pack Monitor Dashboard

## Context

The Flyway migration `V1.1.08__update_dashboard_summary_view.sql` already adds an `order_loaded_to_truck` column to the `order_monitor_view` database view (counting orders with `state = 680`). However, this new column is **not yet propagated** through the backend Java layers or displayed in the frontend. This plan covers the full stack changes needed to surface the data.

---

## Backend Changes (wms-api)

### Change 1: Entity — `OrderMonitorView.java`

**File:** `src/main/java/net/aim_ai/wms/model/OrderMonitorView.java`

Add new field after `orderPalletised` (line 44):

```java
@Column(name = "order_loaded_to_truck")
private Long orderLoadedToTruck;
```

Add getter/setter after `setOrderPalletised()` (after line 180):

```java
public Long getOrderLoadedToTruck() {
    return orderLoadedToTruck;
}

public void setOrderLoadedToTruck(Long orderLoadedToTruck) {
    this.orderLoadedToTruck = orderLoadedToTruck;
}
```

### Change 2: Projection Interfaces (4 files)

Add `Object getOrderLoadedToTruck();` after `getOrderPalletised()` in each:

| File | Path |
|------|------|
| **OrderMonitorSummaryView** | `src/main/java/net/aim_ai/wms/repo/projection/OrderMonitorSummaryView.java` (after line 15) |
| **OrderMonitorBatchView** | `src/main/java/net/aim_ai/wms/repo/projection/OrderMonitorBatchView.java` (after line 16) |
| **OrderMonitorClientSummaryView** | `src/main/java/net/aim_ai/wms/repo/projection/OrderMonitorClientSummaryView.java` (after line 15) |
| **OrderMonitorClientBatchView** | `src/main/java/net/aim_ai/wms/repo/projection/OrderMonitorClientBatchView.java` (after line 17) |

### Change 3: Native Queries — `OrderMonitorViewRepository.java`

**File:** `src/main/java/net/aim_ai/wms/repo/jpa/OrderMonitorViewRepository.java`

All 4 native queries need a new CASE WHEN column added **after `order_palletised`** and **before `order_sum`**:

```sql
sum(CASE WHEN co.state = 680 THEN 1 ELSE 0 END) AS order_loaded_to_truck,
```

Queries to update:
1. **`getViewSummary()`** — after `order_palletised` (line 66), before `order_sum` (line 67)
2. **`getViewBySectionName()`** — after `order_palletised` (line 146), before `order_sum` (line 147)
3. **`getClientViewSummary()`** — after `order_palletised` (line 230), before `order_sum` (line 231)
4. **`getClientViewBySectionName()`** — after `order_palletised` (line 311), before `order_sum` (line 312)

### Change 4: Service — `ViewDtoService.java`

**File:** `src/main/java/net/aim_ai/wms/service/ViewDtoService.java`

Add `dto.put()` call in each of the 4 methods, after the palletized line:

| Method | After line | Key name | Note |
|--------|-----------|----------|------|
| `getOrderMonitorViewSummary()` | 1052 | `"orderLoadedToTruck"` | Summary endpoint uses camelCase keys |
| `getOrderMonitorViewBySectionName()` | 1083 | `"orderLoadedToTruck"` | Detail endpoint uses raw column names |
| `getOrderMonitorClientViewSummary()` | 1116 | `"orderLoadedToTruck"` | Summary endpoint |
| `getOrderMonitorClientViewBySectionName()` | 1148 | `"orderLoadedToTruck"` | Detail endpoint |

Example line to add:
```java
dto.put("orderLoadedToTruck", result.getOrderLoadedToTruck());
```

---

## Frontend Changes (wms-web-ui)

### Change 5: Zone View Table — `zoneViewTable.vue`

**File:** `../wms-web-ui/components/homepage/pickPackMonitor/tables/zoneViewTable.vue`

**5a. Main table header** — Add after `Palletized` header (after line 159):
```javascript
{
  text: 'Truck Loaded',
  align: 'start',
  sortable: true,
  value: 'orderLoadedToTruck',
  class: 'py-3',
},
```

**5b. Detail table header** — Add after `Palletized` header in `itemHeaders` (after line 245):
```javascript
{
  text: 'Truck Loaded',
  align: 'start',
  sortable: true,
  value: 'orderLoadedToTruck',
  class: 'grey lighten-2 py-3',
},
```

**5c. Main table template slot** — Add after `item.orderPalletized` template (after line 58):
```vue
<template #[`item.orderLoadedToTruck`]="{ item }">
  <div class="table-column-right-border">{{ item.orderLoadedToTruck }}</div>
</template>
```

**5d. Detail table template slot** — Add after `item.orderPalletised` template (after line 38):
```vue
<template #[`item.orderLoadedToTruck`]="{ item }">
  <div class="table-column-right-border">{{ item.orderLoadedToTruck }}</div>
</template>
```

**5e. Totals row** — Update `createOverallTotalParcels()`:
- Add variable: `let truckLoaded = 0;` (after line 382)
- Sum in loop: `truckLoaded += i.orderLoadedToTruck;` (after line 392)
- Add to values array: `[total, future, hold, released, assigned, picking, picked, packed, palletized, truckLoaded]` (line 405)

### Change 6: Shipper/Brand Table — `shipperBrandTable.vue`

**File:** `../wms-web-ui/components/homepage/pickPackMonitor/tables/shipperBrandTable.vue`

Identical pattern to Change 5 — same 5 sub-changes (6a-6e):

**6a. Main table header** — Add after `Palletized` header (after line 161)
**6b. Detail table header** — Add after `Palletized` header in `itemHeaders` (after line 247)
**6c. Main table template slot** — Add after `item.orderPalletized` template (after line 60)
**6d. Detail table template slot** — Add after `item.orderPalletised` template (after line 38)
**6e. Totals row** — Update `createOverallTotalParcels()` (same pattern as 5e)

---

## Summary of Files

| # | File | Project | Change |
|---|------|---------|--------|
| 1 | `model/OrderMonitorView.java` | wms-api | Add field + getter/setter |
| 2 | `repo/projection/OrderMonitorSummaryView.java` | wms-api | Add getter method |
| 3 | `repo/projection/OrderMonitorBatchView.java` | wms-api | Add getter method |
| 4 | `repo/projection/OrderMonitorClientSummaryView.java` | wms-api | Add getter method |
| 5 | `repo/projection/OrderMonitorClientBatchView.java` | wms-api | Add getter method |
| 6 | `repo/jpa/OrderMonitorViewRepository.java` | wms-api | Add CASE WHEN to 4 native queries |
| 7 | `service/ViewDtoService.java` | wms-api | Add dto.put() in 4 methods |
| 8 | `tables/zoneViewTable.vue` | wms-web-ui | Headers, template, totals |
| 9 | `tables/shipperBrandTable.vue` | wms-web-ui | Headers, template, totals |

## Verification

**Backend:**
- Run `mvn test` — all 3,276+ tests should pass
- No new tests needed (no new business logic; just passing through an existing view column)

**Frontend:**
- Run `npm run dev` in wms-web-ui
- Navigate to Dashboard > Pick Pack Monitor
- Verify "Truck Loaded" column appears to the right of "Palletized" in both Zone and Shipper/Brand views
- Verify the totals row includes the Truck Loaded sum
- Expand a row and verify "Truck Loaded" column appears in the detail table
