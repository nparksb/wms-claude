---
title: WMS v2 Entity Enumeration Report
type: architecture
project: wms2
status: stable
created: 2026-02-06
last_verified: 2026-11-11
tags: [wms2, entities, jpa, database, architecture]
---

# JPA Entity Enumeration Report
**WMS-API Spring Boot 3.5.9 Project**

Generated: 2026-02-06 · Re-verified 2026-11-11 (wms2-api `df30fa62`)

---

## Summary Statistics

Derived 2026-11-11 against wms2-api `origin/develop` @ `df30fa62` (`grep -rE '^@Entity\b' src/main/java`; the anchor `\b` matters — a bare `^@Entity` also matches `@EntityListeners` and over-counts by one, `AbstractBaseEntity`).

| Metric | Count |
|--------|-------|
| Total `@Entity` classes (`src/main/java`) | 73 |
| — tenant (`net.aim_ai.wms.model`, persistence unit `tenant`) | 69 |
| — landlord (`net.aim_ai.wms.landlord.model`, persistence unit `landlord`) | 4 |
| Tenant entities extending `AbstractBaseEntity` (inherit id-based `equals()` + class-constant `hashCode()`) | 44 |
| Tenant entities NOT extending it that declare their own `equals()` + `hashCode()` | 19 |
| Tenant entities with NO `equals()`/`hashCode()` at all (inherited or own) | 6 |
| Landlord entities with no `equals()`/`hashCode()` | 4 |
| Tenant entities with some `equals()` (inherited or own) | 63 of 69 (91.3%) |

**Re-derive, do not quote:** `grep -rlE '^@Entity\b' src/main/java/net/aim_ai/wms/model | wc -l` → 69; same over `landlord/model` → 4. Second instrument: `grep -rlE 'extends AbstractBaseEntity' src/main/java | wc -l` → 44. The six tenant entities with no `equals()`/`hashCode()` are `ClubRunJob`, `CustomerorderCancellationLog`, `ManualEntryOverride`, `OutboxMessage`, `PutawayConfigAudit`, `RestIdempotency` (all standalone append-only / log / queue tables that deliberately do not extend `AbstractBaseEntity`).

> **History (superseded 2026-11-11):** this report originally (2026-02-06) stated 62 entities with "1 WITH / 60 WITHOUT custom equals/hashCode, 96.8% missing". That was already false by 2026-03-13, when the *Entity equals/hashCode* item of the WMS API improvement plan (commit `4a670fce`) added id-based `equals()` and class-constant `hashCode()` to `AbstractBaseEntity`, inherited by every entity that extends it. Two earlier stale-totals banners (2026-07-15 SBDEV-2474, 2026-09-21 SBDEV-3410) were resolved by the full re-audit below and removed.

---

## Entities WITH Inherited / Custom Implementations

### AbstractBaseEntity (the reference pattern — 44 tenant entities inherit it)
- **File:** `src/main/java/net/aim_ai/wms/model/AbstractBaseEntity.java` (`@MappedSuperclass`, not itself an entity)
- **Has equals():** YES (line 76) · **Has hashCode():** YES (line 84)

```java
public boolean equals(Object o) {
    if (this == o) return true;
    if (!(o instanceof AbstractBaseEntity other)) return false;
    if (this.getClass() != other.getClass()) return false;
    return getId() != null && getId().equals(other.getId());
}

public int hashCode() {
    // Stable across the entity lifecycle: getId() changes from null→Long on persist ...
    return getClass().hashCode();
}
```
- Equality is **same class + non-null equal id**; a transient (id == null) instance equals only itself.
- `hashCode()` is a per-class constant so a `HashSet`/`HashMap` entry survives the null→Long id change at persist.

### Redundant re-declarations on subclasses
- `Location.java:164` re-declares `equals()` with the same id-based semantics (uses `instanceof Location`, no `getClass()` check) and does **not** declare `hashCode()` — it inherits the base's. The 2026-02 field-based `equals()` (`xpos/ypos/zpos/name`) and 18-field `hashCode()` this report previously showcased no longer exist.
- `Unitload.java:102`, `Itemdata.java:229`, `CustomerorderBatch.java:130` re-declare `hashCode()` identically to the base (`getClass().hashCode()`).

### Entities that do NOT extend AbstractBaseEntity but declare their own `equals()` + `hashCode()` (19)
`CyclecountDtoView`, `FlowbinMonitorView`, `LockOverviewAllDtoView`, `LockOverviewDtoView`, `LosSequencenumber`, `OrderDetailMonitorView`, `OrderMonitorView`, `ParcelMonitorView`, `ReceivedDtoView`, `ReceivingDtoView`, `ReplenishmentMonitorView`, `ShippingmethodShipperid`, `StockrecordView`, `StockView`, `UserGroupUser`, `UserGroupUserRole`, `UserRoleUserFunction`, `UserUserRole`, `ViewWarehouseLocationReport` (view entities and composite-key join entities).

---

## Complete Tenant Entity List (69, alphabetical)

All in `net.aim_ai.wms.model` (flat package, no sub-packages). The 4 landlord entities live in `net.aim_ai.wms.landlord.model` — see [wms2-landlord-vs-tenant-entity-map.md](../data-dictionary/wms2-landlord-vs-tenant-entity-map.md) §2.

| Entity Name | File Path |
|-------------|-----------|
| Advice | `src/main/java/net/aim_ai/wms/model/Advice.java` |
| Adviceposition | `src/main/java/net/aim_ai/wms/model/Adviceposition.java` |
| Billoflading | `src/main/java/net/aim_ai/wms/model/Billoflading.java` |
| BillofladingPosition | `src/main/java/net/aim_ai/wms/model/BillofladingPosition.java` |
| Boxtype | `src/main/java/net/aim_ai/wms/model/Boxtype.java` |
| Client | `src/main/java/net/aim_ai/wms/model/Client.java` |
| ClubRunJob | `src/main/java/net/aim_ai/wms/model/ClubRunJob.java` — SBDEV-4007 club run job (`club_run_job`, V2.2.47). `@Immutable`, does not extend `AbstractBaseEntity`, no `equals()`/`hashCode()`; all writes are native SQL in `ClubRunJobRepository` |
| Customerorder | `src/main/java/net/aim_ai/wms/model/Customerorder.java` |
| CustomerorderBatch | `src/main/java/net/aim_ai/wms/model/CustomerorderBatch.java` |
| CustomerorderCancellationLog | `src/main/java/net/aim_ai/wms/model/CustomerorderCancellationLog.java` — standalone (`IDENTITY` id, not `AbstractBaseEntity`), no `equals()`/`hashCode()` |
| CustomerorderPosition | `src/main/java/net/aim_ai/wms/model/CustomerorderPosition.java` |
| Cyclecount | `src/main/java/net/aim_ai/wms/model/Cyclecount.java` |
| CyclecountDtoView | `src/main/java/net/aim_ai/wms/model/CyclecountDtoView.java` |
| CyclecountPosition | `src/main/java/net/aim_ai/wms/model/CyclecountPosition.java` |
| FixLocationAssignment | `src/main/java/net/aim_ai/wms/model/FixLocationAssignment.java` — ✓ merged(SBDEV-3128: #601 4643acf5, 2026-11-02): table also has `bounds_inherited` (V2.2.45), deliberately NOT mapped on the entity (SBDEV-3128 D8); `location` likewise gains three unmapped `default_*bound` columns |
| FlowbinMonitorView | `src/main/java/net/aim_ai/wms/model/FlowbinMonitorView.java` |
| Goodsreceipt | `src/main/java/net/aim_ai/wms/model/Goodsreceipt.java` |
| Goodsreceiptposition | `src/main/java/net/aim_ai/wms/model/Goodsreceiptposition.java` |
| InventoryRecord | `src/main/java/net/aim_ai/wms/model/InventoryRecord.java` |
| Itemdata | `src/main/java/net/aim_ai/wms/model/Itemdata.java` |
| Itemunit | `src/main/java/net/aim_ai/wms/model/Itemunit.java` |
| Location | `src/main/java/net/aim_ai/wms/model/Location.java` — inherits id-based `equals()`/`hashCode()`; re-declares `equals()` (`Location.java:164`) |
| LocationArea | `src/main/java/net/aim_ai/wms/model/LocationArea.java` |
| LocationConstraint | `src/main/java/net/aim_ai/wms/model/LocationConstraint.java` |
| LocationRack | `src/main/java/net/aim_ai/wms/model/LocationRack.java` |
| LocationRackRow | `src/main/java/net/aim_ai/wms/model/LocationRackRow.java` |
| LocationType | `src/main/java/net/aim_ai/wms/model/LocationType.java` |
| LockOverviewDtoView | `src/main/java/net/aim_ai/wms/model/LockOverviewDtoView.java` |
| LockOverviewAllDtoView | `src/main/java/net/aim_ai/wms/model/LockOverviewAllDtoView.java` |
| LosSequencenumber | `src/main/java/net/aim_ai/wms/model/LosSequencenumber.java` |
| ManualEntryOverride | `src/main/java/net/aim_ai/wms/model/ManualEntryOverride.java` — SBDEV-3132 `mobile_manual_entry_override` audit/throttle rows; standalone (`IDENTITY` id), no `equals()`/`hashCode()` |
| Message | `src/main/java/net/aim_ai/wms/model/Message.java` |
| MessageArchived | `src/main/java/net/aim_ai/wms/model/MessageArchived.java` |
| OrderDetailMonitorView | `src/main/java/net/aim_ai/wms/model/OrderDetailMonitorView.java` |
| OrderMonitorView | `src/main/java/net/aim_ai/wms/model/OrderMonitorView.java` |
| OutboxMessage | `src/main/java/net/aim_ai/wms/model/OutboxMessage.java` — SBDEV-2221 transactional outbox; `Status` inner enum (PENDING/IN_FLIGHT/SENT/FAILED_RETRY/FAILED_TERMINAL); `@Version Long version` (optimistic lock). Table column **`outbox_message.last_message_id`** (V2.2.40): nullable `bigint`, no default, **no FK** (the `message` rows it names are purged on their own schedule); id of the Service Log row of the row's latest dispatch attempt, written only for `ORDER_BATCH_SHIPPED` rows. It is **native-only and deliberately NOT mapped on the entity**: a tenant on which V2.2.40 failed must keep claiming and dispatching, and the claim's `RETURNING *` maps entity columns only (`OutboxMessageRepository.java:89-100`) ✓ merged(SBDEV-3672: wms2-api#526 f85789d4 + wms2-web-ui#176 98accaf9, 2026-10-22) |
| ParcelMonitorView | `src/main/java/net/aim_ai/wms/model/ParcelMonitorView.java` |
| Pickingorder | `src/main/java/net/aim_ai/wms/model/Pickingorder.java` |
| PickingorderPosition | `src/main/java/net/aim_ai/wms/model/PickingorderPosition.java` |
| PickingorderUnitload | `src/main/java/net/aim_ai/wms/model/PickingorderUnitload.java` |
| Printer | `src/main/java/net/aim_ai/wms/model/Printer.java` |
| PutawayConfigAudit | `src/main/java/net/aim_ai/wms/model/PutawayConfigAudit.java` — SBDEV-2732 `putaway_config_audit`; standalone (`IDENTITY` id), no `equals()`/`hashCode()` |
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
| StockrecordView | `src/main/java/net/aim_ai/wms/model/StockrecordView.java` |
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

### 1. Most entities inherit id-based equality
- **44 of 69 tenant entities** extend `AbstractBaseEntity` and inherit its id-based `equals()` and class-constant `hashCode()` (see above). Another **19** declare their own (view entities + composite-key join entities).
- **6 tenant entities** (`ClubRunJob`, `CustomerorderCancellationLog`, `ManualEntryOverride`, `OutboxMessage`, `PutawayConfigAudit`, `RestIdempotency`) and all **4 landlord entities** fall back to `Object` identity equality. ⚠ unverified 2026-11-11: no usage audit of those ten classes in `HashSet`/`HashMap` was performed; the six tenant ones are append-only log / queue / job rows, so collection use is not expected.

### 2. Properties of the inherited implementation
| Property | Consequence |
|---|---|
| `getClass()` equality, not `instanceof` | Hibernate proxies compare unequal to a loaded instance of the same row unless unproxied first |
| Transient (id == null) instances equal only themselves | Two un-persisted entities with identical data are distinct in a `Set` |
| `hashCode()` is one constant per class | Correct and stable across persist, but every instance of a class lands in one bucket — O(n) lookup in large `HashSet<Entity>` |

⚠ unverified 2026-11-11: the proxy consequence in the first row is inferred from the `getClass()` comparison at `AbstractBaseEntity.java:79`, not reproduced with a running Hibernate session.

### 3. Hibernate best practices (unchanged)
- Equality key should be **immutable natural or surrogate identifier fields**.
- `Location.java:164` and the `hashCode()` re-declarations on `Unitload`, `Itemdata`, `CustomerorderBatch` duplicate the base class behaviour and can be deleted without behaviour change (only `Location.equals()` differs, by omitting the `getClass()` check).
  - **Not a defect (triaged 2026-11-12, develop 3690a730).** The 2026-11-11 review called `Location.equals` "asymmetric under Hibernate proxies". That has it backwards. `instanceof` is the proxy-tolerant form; the base's `this.getClass() != other.getClass()` (`AbstractBaseEntity.java`) is what makes an entity unequal to its own proxy, and its `getClass().hashCode()` differs between the two. In practice the two `equals` behave identically for `Location`. Method: `git grep` found no subclass of `Location` (0 `extends Location`), no `getReference`/`getReferenceById`/`getOne` in src/main, and no JPA association pointing at it (the model's only associations are the EAGER `@ManyToMany` on `User`/`UserGroup`/`UserRole`). So no `Location` proxy is ever created. Blind spot: a future `getReferenceById(Location)` would make the base class, not `Location`, the side that misbehaves. No ticket filed.

---

## Entity Categories by Function (tenant, 69)

Every tenant entity appears in exactly one category (verified by set-equality against the `@Entity` enumeration).

### Core Master Data (12)
Client, Section, Location, LocationArea, LocationType, UnitloadType, Boxtype, Itemdata, Itemunit, UserFunction, UserGroup, UserRole

### Transactional Entities (17)
Customerorder, CustomerorderPosition, CustomerorderBatch, CustomerorderCancellationLog, ClubRunJob, Goodsreceipt, Goodsreceiptposition, Pickingorder, PickingorderPosition, PickingorderUnitload, Replenishorder, Billoflading, BillofladingPosition, Cyclecount, CyclecountPosition, Advice, Adviceposition

### Inventory Entities (5)
Unitload, UnitloadRecord, Stockunit, Stockrecord, InventoryRecord

### System Support Entities (17)
Message, MessageArchived, Printer, User, Sysprop, LosSequencenumber, Shippingmethod, Shipperid, Queryrepository, FixLocationAssignment, LocationConstraint, LocationRack, LocationRackRow, OutboxMessage, RestIdempotency, PutawayConfigAudit, ManualEntryOverride

### View/Monitor Entities (13)
OrderMonitorView, OrderDetailMonitorView, ParcelMonitorView, FlowbinMonitorView, ReplenishmentMonitorView, LockOverviewDtoView, LockOverviewAllDtoView, StockView, StockrecordView, ReceivedDtoView, ReceivingDtoView, CyclecountDtoView, ViewWarehouseLocationReport

All 13 are backed by a `CREATE VIEW` in `src/main/resources/db/migration/` (checked per view name). `ClubRunJob` is `@Immutable` but table-backed (`V2.2.47`), not a view.

### Identifier/Junction Entities (5)
UserUserRole, UserGroupUser, UserGroupUserRole, UserRoleUserFunction, ShippingmethodShipperid

(12 + 17 + 5 + 17 + 13 + 5 = 69.) Composite-key holders `UserUserRoleId`, `UserGroupUserId`, `UserGroupUserRoleId`, `UserRoleUserFunctionId`, `ShippingmethodShipperidId` are `@Embeddable`s, not entities.

---

## Recommendations

1. **Do not add field-based `equals()`/`hashCode()` to entities** — the codebase standard is `AbstractBaseEntity`'s id-based pair. New standalone (non-`AbstractBaseEntity`) entities such as the six above should be checked for collection use before shipping without one.
2. **Cleanup candidates** (optional, no behaviour change): the redundant re-declarations listed above.
3. **Tests**: any new entity extending `AbstractBaseEntity` inherits the contract; a collection-behaviour unit test is only needed for the ones that override it.

---

## Summary

**Current State (2026-11-11, `df30fa62`):** 73 `@Entity` classes (69 tenant + 4 landlord). 63 of 69 tenant entities have `equals()`/`hashCode()` (44 inherited from `AbstractBaseEntity`, 19 own); 6 tenant and 4 landlord entities rely on object identity.

**Risk Assessment:** LOW for the inherited id-based pair; the ten identity-equality entities are append-only / config rows. No action required beyond an optional cleanup.

## Verification Log

| Date | What was checked | Result | Checked by |
|---|---|---|---|
| 2026-05-01 | Frontmatter and staleness tracking added | — | verify-docs audit |
| 2026-10-16 | SBDEV-3672: `OutboxMessage` row gains the native-only `outbox_message.last_message_id` column note. Read at wms2-api `1866ab66`: `V2.2.40__bol_shipped_chunk_size_and_outbox_message_link.sql`, `OutboxMessageRepository.java:89-100`, `model/OutboxMessage.java` (no such field). Rest of report not re-verified. | Marked ✓ merged(SBDEV-3672: wms2-api#526 f85789d4 + wms2-web-ui#176 98accaf9, 2026-10-22) | SBDEV-3672 docs lane |
| 2026-11-11 | Full re-audit vs wms2-api `origin/develop` @ `df30fa62`: `@Entity` enumeration (73 = 69 tenant + 4 landlord; `^@Entity\b`, cross-checked: Python class scan, and `@Id`-bearing files in `model/` = 26 = 25 non-extending entities + `AbstractBaseEntity`, so 25 + 44 inheriting = 69), per-entity equals/hashCode scan, `extends AbstractBaseEntity` count (44), repository 1:1 coverage (69 tenant repos), view-entity `CREATE VIEW` reconcile against `db/migration`, `OutboxMessage`/`FixLocationAssignment` notes. Rewrote summary, equals/hashCode analysis (Location section replaced by `AbstractBaseEntity`), entity list (+5 rows), categories (now sum to 69), recommendations. Corrected `OutboxMessage` `@Version` type (`Long`, not `int`). | 62 → 69 tenant (+4 landlord); "1 WITH / 60 WITHOUT" thesis superseded (id-based equals in `AbstractBaseEntity` since 2026-03-13) | Claude (re-verify pass) |

**Re-verify every 90 days.** Next due: **2027-02-09**.
