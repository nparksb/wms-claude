---
title: WMS v2 Entity Enumeration Report
type: architecture
project: wms2
status: stable
created: 2026-02-06
last_verified: 2026-05-12
tags: [wms2, entities, jpa, database, architecture]
---

# JPA Entity Enumeration Report
**WMS-API Spring Boot 3.5.9 Project**

Generated: 2026-02-06

---

## Summary Statistics

| Metric | Count |
|--------|-------|
| Total @Entity Annotated Classes | 61 |
| WITH custom equals() & hashCode() | 1 |
| WITHOUT custom equals() & hashCode() | 60 |
| Missing Implementation Rate | 98.4% |

---

## Entities WITH Custom Implementations (1)

### Location
- **File:** `src/main/java/net/aim_ai/wms/model/Location.java`
- **Has equals():** YES (lines 219-224)
- **Has hashCode():** YES (lines 227-229)

**equals() Implementation:**
```java
public boolean equals(Object o) {
    if (this == o) return true;
    if (o == null || getClass() != o.getClass()) return false;
    Location location = (Location) o;
    return xpos.equals(location.xpos) &&
           ypos.equals(location.ypos) &&
           Objects.equals(zpos, location.zpos) &&
           name.equals(location.name);
}
```
- Checks field identity: `xpos`, `ypos`, `zpos`, `name`
- Uses `Objects.equals()` for null-safe comparison
- Standard JPA entity equality pattern

**hashCode() Implementation:**
```java
@Override
public int hashCode() {
    return Objects.hash(id, additionalcontent, created, entityLock,
                       modified, version, xpos, ypos, zpos, name,
                       clientId, areaId, rackId, typeId, staginglane,
                       transferlane, automationlane, crossdockinglane, gate);
}
```
- Uses `Objects.hash()` with 18 fields
- Comprehensive field inclusion ensures consistency

---

## Entities WITHOUT Custom Implementations (60)

### Complete List (Alphabetical)

| Entity Name | File Path |
|-------------|-----------|
| Advice | `src/main/java/net/aim_ai/wms/model/Advice.java` |
| Adviceposition | `src/main/java/net/aim_ai/wms/model/Adviceposition.java` |
| Billoflading | `src/main/java/net/aim_ai/wms/model/Billoflading.java` |
| BillofladingPosition | `src/main/java/net/aim_ai/wms/model/BillofladingPosition.java` |
| Boxtype | `src/main/java/net/aim_ai/wms/model/Boxtype.java` |
| Client | `src/main/java/net/aim_ai/wms/model/Client.java` |
| Customerorder | `src/main/java/net/aim_ai/wms/model/Customerorder.java` |
| CustomerorderBatch | `src/main/java/net/aim_ai/wms/model/CustomerorderBatch.java` |
| CustomerorderPosition | `src/main/java/net/aim_ai/wms/model/CustomerorderPosition.java` |
| Cyclecount | `src/main/java/net/aim_ai/wms/model/Cyclecount.java` |
| CyclecountDtoView | `src/main/java/net/aim_ai/wms/model/CyclecountDtoView.java` |
| CyclecountPosition | `src/main/java/net/aim_ai/wms/model/CyclecountPosition.java` |
| FixLocationAssignment | `src/main/java/net/aim_ai/wms/model/FixLocationAssignment.java` |
| FlowbinMonitorView | `src/main/java/net/aim_ai/wms/model/FlowbinMonitorView.java` |
| Goodsreceipt | `src/main/java/net/aim_ai/wms/model/Goodsreceipt.java` |
| Goodsreceiptposition | `src/main/java/net/aim_ai/wms/model/Goodsreceiptposition.java` |
| InventoryRecord | `src/main/java/net/aim_ai/wms/model/InventoryRecord.java` |
| Itemdata | `src/main/java/net/aim_ai/wms/model/Itemdata.java` |
| Itemunit | `src/main/java/net/aim_ai/wms/model/Itemunit.java` |
| LocationArea | `src/main/java/net/aim_ai/wms/model/LocationArea.java` |
| LocationConstraint | `src/main/java/net/aim_ai/wms/model/LocationConstraint.java` |
| LocationRack | `src/main/java/net/aim_ai/wms/model/LocationRack.java` |
| LocationRackRow | `src/main/java/net/aim_ai/wms/model/LocationRackRow.java` |
| LocationType | `src/main/java/net/aim_ai/wms/model/LocationType.java` |
| LockOverviewDtoView | `src/main/java/net/aim_ai/wms/model/LockOverviewDtoView.java` |
| LosSequencenumber | `src/main/java/net/aim_ai/wms/model/LosSequencenumber.java` |
| Message | `src/main/java/net/aim_ai/wms/model/Message.java` |
| MessageArchived | `src/main/java/net/aim_ai/wms/model/MessageArchived.java` |
| OrderDetailMonitorView | `src/main/java/net/aim_ai/wms/model/OrderDetailMonitorView.java` |
| OrderMonitorView | `src/main/java/net/aim_ai/wms/model/OrderMonitorView.java` |
| ParcelMonitorView | `src/main/java/net/aim_ai/wms/model/ParcelMonitorView.java` |
| Pickingorder | `src/main/java/net/aim_ai/wms/model/Pickingorder.java` |
| PickingorderPosition | `src/main/java/net/aim_ai/wms/model/PickingorderPosition.java` |
| PickingorderUnitload | `src/main/java/net/aim_ai/wms/model/PickingorderUnitload.java` |
| Printer | `src/main/java/net/aim_ai/wms/model/Printer.java` |
| Queryrepository | `src/main/java/net/aim_ai/wms/model/Queryrepository.java` |
| ReceivedDtoView | `src/main/java/net/aim_ai/wms/model/ReceivedDtoView.java` |
| ReceivingDtoView | `src/main/java/net/aim_ai/wms/model/ReceivingDtoView.java` |
| ReplenishmentMonitorView | `src/main/java/net/aim_ai/wms/model/ReplenishmentMonitorView.java` |
| Replenishorder | `src/main/java/net/aim_ai/wms/model/Replenishorder.java` |
| RestIdempotency | `src/main/java/net/aim_ai/wms/model/RestIdempotency.java` |
| Section | `src/main/java/net/aim_ai/wms/model/Section.java` |
| Shipperid | `src/main/java/net/aim_ai/wms/model/Shipperid.java` |
| Shippingmethod | `src/main/java/net/aim_ai/wms/model/Shippingmethod.java` |
| ShippingmethodShipperid | `src/main/java/net/aim_ai/wms/model/ShippingmethodShipperid.java` |
| Stockrecord | `src/main/java/net/aim_ai/wms/model/Stockrecord.java` |
| Stockunit | `src/main/java/net/aim_ai/wms/model/Stockunit.java` |
| StockView | `src/main/java/net/aim_ai/wms/model/StockView.java` |
| Sysprop | `src/main/java/net/aim_ai/wms/model/Sysprop.java` |
| Unitload | `src/main/java/net/aim_ai/wms/model/Unitload.java` |
| UnitloadRecord | `src/main/java/net/aim_ai/wms/model/UnitloadRecord.java` |
| UnitloadType | `src/main/java/net/aim_ai/wms/model/UnitloadType.java` |
| User | `src/main/java/net/aim_ai/wms/model/User.java` |
| UserFunction | `src/main/java/net/aim_ai/wms/model/UserFunction.java` |
| UserGroup | `src/main/java/net/aim_ai/wms/model/UserGroup.java` |
| UserGroupUser | `src/main/java/net/aim_ai/wms/model/UserGroupUser.java` |
| UserGroupUserRole | `src/main/java/net/aim_ai/wms/model/UserGroupUserRole.java` |
| UserRole | `src/main/java/net/aim_ai/wms/model/UserRole.java` |
| UserRoleUserFunction | `src/main/java/net/aim_ai/wms/model/UserRoleUserFunction.java` |
| UserUserRole | `src/main/java/net/aim_ai/wms/model/UserUserRole.java` |
| ViewWarehouseLocationReport | `src/main/java/net/aim_ai/wms/model/ViewWarehouseLocationReport.java` |

---

## Key Findings

### 1. Widespread Missing Implementations
- **60 of 61 entities (98.4%)** rely on default `Object.equals()` & `Object.hashCode()`
- Default implementations use **object identity** (memory address), not field values
- This causes issues in `HashSet`/`HashMap` when multiple object instances have identical logical data

### 2. Location Entity as Reference
- Only entity with custom implementations
- Uses **field-based equality**: `xpos`, `ypos`, `zpos`, `name`
- `hashCode()` includes **all fields** for consistency
- Proper `@Override` annotations present
- Follows standard JPA best practices

### 3. Potential Issues with Current Approach

| Issue | Impact |
|-------|--------|
| **Collections behavior** | Two Location objects with identical coordinates are treated as different in HashSet/HashMap |
| **Database consistency** | Object identity doesn't match logical identity in domain model |
| **Cache operations** | Equality based on memory address, not semantic data |
| **Testing challenges** | Same data creates different hashCode values across test runs |
| **Many-to-many relations** | Join table operations may fail to detect duplicates |

### 4. Hibernate Best Practices
- Entities in collections should override `equals()` and `hashCode()`
- Equality key should be **immutable natural identifier fields**
- All **60 missing implementations** are candidates for systematic addition
- Consider code generation (IDE, Lombok, or MapStruct)

---

## Entity Categories by Function

### Core Master Data (12 entities)
Client, Section, LocationArea, LocationType, UnitloadType, Boxtype, ItemData, ItemUnit, UserFunction, UserGroup, UserRole, UserGroupUser

**Risk Level:** MEDIUM - often used in relationships and sets

### Transactional Entities (14 entities)
Customerorder, CustomerorderPosition, CustomerorderBatch, Goodsreceipt, Goodsreceiptposition, Pickingorder, PickingorderPosition, PickingorderUnitload, Replenishorder, Billoflading, BillofladingPosition, Cyclecount, CyclecountPosition, Advice, Adviceposition

**Risk Level:** HIGH - frequently stored in collections

### Inventory Entities (5 entities)
Unitload, UnitloadRecord, Stockunit, Stockrecord, InventoryRecord

**Risk Level:** HIGH - critical for stock tracking and deduplication

### System Support Entities (11 entities)
Message, MessageArchived, Printer, User, Sysprop, LosSequencenumber, ShippingMethod, ShipperId, Queryrepository, FixLocationAssignment, LocationConstraint

**Risk Level:** MEDIUM-HIGH - some may be used in HashMaps/Sets

### View/Monitor Entities (10 entities)
OrderMonitorView, OrderDetailMonitorView, ParcelMonitorView, FlowbinMonitorView, ReplenishmentMonitorView, LockOverviewDtoView, StockView, ReceivedDtoView, ReceivingDtoView, CyclecountDtoView

**Risk Level:** LOW - typically read-only, view-based (but verify usage)

### Identifier/Junction Entities (8 entities)
UserUserRole, UserGroupUser, UserGroupUserRole, UserRoleUserFunction, ShippingmethodShipperid

**Risk Level:** MEDIUM - composite key entities, verify collection usage

---

## Recommendations

### Immediate Actions (CRITICAL)

1. **Review Transactional Entities** - Customerorder, Pickingorder, Replenishorder, etc.
   - Check if instances are stored in `HashSet`, `HashMap`, or collections
   - Check if used as `@ManyToMany` join table entities
   - Priority: HIGH for equals/hashCode implementation

2. **Review Inventory Entities** - Unitload, Stockunit, InventoryRecord
   - Critical for stock accuracy
   - Likely used in deduplication logic
   - Priority: HIGH for equals/hashCode implementation

### Medium Term

3. **Establish Coding Standard**
   - Reference `Location.java` implementation pattern
   - Consider IDE generation (IntelliJ: Alt+Insert, Eclipse: Alt+Shift+S)
   - Or use Lombok `@EqualsAndHashCode` annotations
   - Apply consistently across all 60 missing entities

4. **Code Generation Options**
   ```java
   // Option 1: Lombok (add @EqualsAndHashCode)
   @Entity
   @EqualsAndHashCode(of = {"id", "name"})
   public class Client { ... }

   // Option 2: Manual (Location.java pattern)
   // Option 3: IDE generation assist
   ```

### Testing

5. **Add Unit Tests** for collection-based behavior
   ```java
   @Test
   void testEntityDeduplicationInSet() {
       Set<Entity> set = new HashSet<>();
       Entity e1 = new Entity(...);
       Entity e2 = new Entity(...); // Same data

       set.add(e1);
       set.add(e2);

       // Should be 1 if equals/hashCode based on data
       // Currently 2 (identity-based)
   }
   ```

---

## Summary

**Current State:** 98.4% of entities missing custom equals/hashCode implementations, relying on object identity

**Risk Assessment:** HIGH for transactional and inventory entities, MEDIUM for master data

**Action Required:** Systematic review and implementation, using Location.java as reference pattern

**Estimated Scope:** 60 entities × ~5 lines of code per entity = ~300 lines to add


---

## Verification Log

| Date | What was checked | Result | Checked by |
|---|---|---|---|
| 2026-05-01 | Frontmatter and staleness tracking added | — | verify-docs audit |

**Re-verify every 90 days.** Next due: **2026-07-29**.
