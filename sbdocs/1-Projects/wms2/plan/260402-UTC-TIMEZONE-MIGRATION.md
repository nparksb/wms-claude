# UTC Timezone Migration Plan

## Context

The WMS-API currently stores all timestamps in warehouse-local time (configured as `America/Los_Angeles`) using PostgreSQL `timestamp without time zone` columns. This creates fragile behavior around DST transitions, deployment environment differences, and multi-tenant operation where warehouses may be in different timezones.

### Four-Way Timezone Disagreement (Root Cause)

The system has **four independent timezone sources** that can silently disagree:

1. **PostgreSQL server** -- uses its `timezone` GUC (often UTC in cloud-hosted) for `current_date`/`current_timestamp` in views/queries
2. **Hibernate** -- configured with `hibernate.jdbc.time_zone=America/Los_Angeles`, controls how `LocalDateTime` is written to `timestamp without time zone` columns
3. **JVM** -- uses host OS default (NOT explicitly set), controls `LocalDate.now()`, `LocalDateTime.now()`, `new Date()`, `CronTrigger` scheduling
4. **Per-tenant sysprop** -- `"System Time Zone"` seeded as `"America / New_York (-05:00)"` but app properties say `America/Los_Angeles`. Only used by `OrderReleaseJob`

Since `LocalDateTime` carries no timezone info and `timestamp without time zone` carries no timezone info, the "correct" interpretation depends on which layer you ask. A misleading comment at `OrderReleaseJob.java:94` claims "all the date stored in the DB is UTC" but Hibernate is configured to treat values as `America/Los_Angeles`.

### Current State (Verified by Codebase Analysis)

**Backend (wms-api):**
- 61 JPA entities extending `AbstractBaseEntity` with `LocalDateTime created`/`modified` fields (~122 columns)
- 2 additional `LocalDateTime` business columns: `Goodsreceipt.receiptdate`, `InventoryRecord.timestamp`
- 4 `LocalDate` columns: `Customerorder.pickingdate`, `Billoflading.shipped`, `Advice.dayofdelivery`, `Advice.dayofdeliveryuntil`
- **88 `timestamp without time zone` DB columns, 4 `date` columns, zero `timestamptz`**
- 3 stored functions (`stock_history`, `transaction_detail`, `transaction_summary`) accept `timestamp without time zone` params
- 5 cron-triggered scheduled tasks with NO timezone parameter on `CronTrigger`
- 36+ `new ObjectMapper()` instances bypassing Spring timezone/date config (no `JavaTimeModule`)
- 2 thread-unsafe static `SimpleDateFormat` instances on singleton beans (`AdviceController.java:38`, `CustomerOrderBatchController.java:26`)
- 4 `YYYY` (week-year) bugs in `FileExportService.java` + 1 in `WmsConstants.java:1036`
- 8+ `LocalDate.now()` / `LocalDateTime.now()` calls without explicit timezone
- Entity field default `Billoflading.java:21`: `private LocalDate shipped = LocalDate.now()` (uses JVM TZ)
- `WebConfigurer.java:70` uses `TimeZone.getDefault()` instead of the configured `America/Los_Angeles`
- `StartApplication.java:44-48` creates a second `ObjectMapper` bean without `JavaTimeModule`
- Jackson serializes `LocalDateTime` as `"yyyy-MM-dd HH:mm:ss"` (no timezone indicator) via `WebConfigurer.java:36`

**Database (Flyway migrations):**
- 45 tables (44 via CREATE TABLE + 1 `message_archived` via CREATE TABLE AS)
- 88 `timestamp without time zone` columns (86 audit pairs + `goodsreceipt.receiptdate` + `inventory_record."timestamp"`)
- 4 `date` columns remain as-is
- 3 stored functions with `TIMESTAMP` / `timestamp without time zone` params and return types
- 12 views total; 3 use `current_date`: `order_monitor_view` (latest in V1.1.08), `replenishment_monitor_view` (V1.0.02)
- Seed data uses hardcoded timestamp strings like `'2021-07-12 10:36:29.727'` (no timezone indicator)
- Zero ALTER TABLE statements for timestamp columns in any migration to date

**Frontends (wms-web-ui, wms-mobile-ui):**
- Both use `@nuxtjs/moment` ^1.6.1 with moment-timezone
- wms-web-ui: `defaultTimezone: 'America/Los_Angeles'` in buildModules config (`nuxt.config.js:57-60`)
- wms-web-ui: conflicting `publicRuntimeConfig.moment.defaultTimezone: 'America/New_York'` (`nuxt.config.js:163-165`) -- **unused by module, dead config**
- wms-mobile-ui: NO `moment:` config block at module level -- **timezone support not activated**
- 70+ component-local date formatting methods (`getDate()`, `getTimeDate()`, `formatDate()`) -- **no centralized utility**
- Vuex stores perform **zero date transformation** -- API strings stored and displayed as-is
- Date pickers (`v-date-picker`) send `YYYY-MM-DD` format strings to API
- `this.$moment(value).format(...)` used everywhere; parses API strings without timezone as local time
- Hardcoded timezone label: `stockUnitRecord.vue:142` has `'Time Stamp (EST)'`
- Some components use unix timestamps (`timestamp * 1000`) for label data -- these are NOT affected by migration

### Goal

Store all timestamps in UTC, convert column types to `timestamptz`, and make all timezone handling explicit. Use the per-tenant `System Time Zone` sysprop for business date logic (e.g., "today's orders") and for frontend display conversion.

### API Date Format Decision

**Backend sends ISO-8601 UTC:** `"2026-02-10T22:30:00.000Z"`

The frontend receives the warehouse timezone string from the `System Time Zone` sysprop (already available via the system properties API) and converts UTC to warehouse-local time for display.

### Deployment Strategy

Maintenance window (brief downtime). Flyway converts data at startup before app serves requests. Frontend deployment immediately follows backend.

---

## Phase 1: Stabilize Current Behavior (Safety Net)

**Purpose:** Make all implicit timezone assumptions explicit BEFORE changing anything. This is a separate deployment that preserves current behavior but makes it deterministic.

### 1.1 Pin JVM Timezone Explicitly

**File:** `src/main/java/net/aim_ai/wms/StartApplication.java`

Add `@PostConstruct` to set JVM timezone to current value:
```java
@PostConstruct
public void init() {
    TimeZone.setDefault(TimeZone.getTimeZone("America/Los_Angeles"));
}
```
This ensures `LocalDate.now()`, `LocalDateTime.now()`, `new Date()`, `Calendar.getInstance()` all use LA time regardless of the host OS.

### 1.2 Fix CronTrigger Timezone

**File:** `src/main/java/net/aim_ai/wms/schedulejob/SchedulingConfiguration.java`

All 5 `CronTrigger` instances (lines ~151, 170, 189, 208, 225) need explicit timezone:
```java
new CronTrigger(cronjob, TimeZone.getTimeZone("America/Los_Angeles"))
```

### 1.3 Fix Thread-Unsafe Static SimpleDateFormat

**Files (confirmed thread-unsafe on singleton beans):**
- `src/main/java/net/aim_ai/wms/controller/AdviceController.java:38` -- `static final SimpleDateFormat`
- `src/main/java/net/aim_ai/wms/controller/CustomerOrderBatchController.java:26` -- `static final SimpleDateFormat`

Replace with `DateTimeFormatter` (thread-safe) or create new instances per request.

Also check and fix if applicable:
- `src/main/java/net/aim_ai/wms/controller/rest/AdviceRestController.java:62`
- `src/main/java/net/aim_ai/wms/service/NameTypeService.java:21`

### 1.4 Fix `YYYY` Week-Year Bug

**Files:**
- `src/main/java/net/aim_ai/wms/service/FileExportService.java` (lines 84, 152, 217, 285) -- Change `YYYY-MM-dd HH:mm:ss.SSS` to `yyyy-MM-dd HH:mm:ss.SSS`
- `src/main/java/net/aim_ai/wms/service/WmsConstants.java:1036` -- Change `SYSTEM_PROPERTY_EXPORT_DATE_FORMAT_DEFAULT_VALUE` from `"YYYY-MM-dd HH:mm:ss.SSS"` to `"yyyy-MM-dd HH:mm:ss.SSS"`

**Note:** `YYYY` in native SQL (`ClientRepository.java:54-55,64-65`, `PickingorderRepository.java:115`) is the correct PostgreSQL pattern -- do NOT change those.

### 1.5 Fix WebConfigurer Timezone Conflict

**File:** `src/main/java/net/aim_ai/wms/WebConfigurer.java:70`

Change `builder.timeZone(TimeZone.getDefault())` to `builder.timeZone(TimeZone.getTimeZone("America/Los_Angeles"))` to match the application.properties config explicitly.

### 1.6 Fix Entity Field Default

**File:** `src/main/java/net/aim_ai/wms/model/Billoflading.java:21`

Current: `private LocalDate shipped = LocalDate.now();`

This uses JVM default timezone. After Phase 1 JVM is pinned to LA, so this is safe. But note it for Phase 2 where it needs warehouse timezone.

### 1.7 Verify & Deploy Phase 1

- Run existing tests: `mvn test`
- Verify no behavioral change (this phase is behavior-preserving)
- Deploy to staging, smoke test scheduled jobs and API date responses

---

## Phase 2: Application Configuration Switch to UTC

**Purpose:** Change the application to read/write UTC timestamps. Combined with the Phase 3 Flyway migration in the SAME deployment so Flyway converts data before the app starts serving requests.

### 2.1 Update Application Properties

**Files:** `src/main/resources/application.properties` AND `src/main/resources/application_dev.properties`

```properties
spring.jpa.properties.hibernate.jdbc.time_zone=UTC
spring.jackson.time-zone=UTC
spring.jackson.deserialization.adjust-dates-to-context-time-zone=true  # keep as-is
```

### 2.2 Switch JVM Timezone to UTC

**File:** `src/main/java/net/aim_ai/wms/StartApplication.java`

Change the `@PostConstruct` from Phase 1:
```java
@PostConstruct
public void init() {
    TimeZone.setDefault(TimeZone.getTimeZone("UTC"));
}
```

### 2.3 Update WebConfigurer Jackson Configuration

**File:** `src/main/java/net/aim_ai/wms/WebConfigurer.java`

- Line 70: Change to `builder.timeZone(TimeZone.getTimeZone("UTC"))`
- Verify the `StdDateFormat` and `JavaTimeModule` configuration produces ISO-8601 UTC output
- Consider changing the `dateTimeFormat` at line 36 from `"yyyy-MM-dd HH:mm:ss"` to ISO-8601 format `"yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"`, or remove the custom serializer and let Jackson's `WRITE_DATES_AS_TIMESTAMPS=false` produce standard ISO-8601

### 2.4 Create Warehouse Timezone Utility

Create a shared utility that reads the per-tenant `System Time Zone` sysprop:

```java
// In a new utility class or add to an existing shared service
@Component
public class TimezoneService {
    private final SyspropRepository syspropRepository;

    public TimezoneService(SyspropRepository syspropRepository) {
        this.syspropRepository = syspropRepository;
    }

    /**
     * Returns the warehouse timezone for the current tenant.
     * Parses sysprop value like "America / New_York (-05:00)" to IANA timezone ID.
     */
    public ZoneId getWarehouseZoneId() {
        String tz = syspropRepository.findSysvalueBySyskey("System Time Zone");
        return ZoneId.of(parseTimezoneId(tz));
    }

    public LocalDate todayInWarehouse() {
        return LocalDate.now(getWarehouseZoneId());
    }

    private String parseTimezoneId(String syspropValue) {
        // "America / New_York (-05:00)" → "America/New_York"
        if (syspropValue == null) return "UTC";
        String stripped = syspropValue.replaceAll("\\s*\\(.*\\)\\s*$", "").trim();
        return stripped.replace(" / ", "/").replace(" ", "");
    }
}
```

### 2.5 Fix Business Logic That Needs Warehouse Timezone

After switching to UTC, any logic that needs "today in the warehouse timezone" must explicitly use the `TimezoneService`.

**Already correct (uses sysprop):**
- `OrderReleaseJob.java:94-102` -- reads `System Time Zone`, sets on `SimpleDateFormat`
- Fix the misleading comment at line 94 that says "all the date stored in the DB is UTC"

**Must be updated to use warehouse timezone:**

| File | Line | Current Code | Fix |
|------|------|-------------|-----|
| `OrderRestController.java` | 421 | `pickingDate.isAfter(LocalDate.now())` | Use `timezoneService.todayInWarehouse()` |
| `OrderRestController.java` | 429 | `customerOrder.setPickingdate(LocalDate.now())` | Use `timezoneService.todayInWarehouse()` |
| `ReleaseOrderJobService.java` | 110 | `order.getPickingdate().isAfter(LocalDate.now())` | Use `timezoneService.todayInWarehouse()` |
| `CustomerorderService.java` | 221 | `LocalDate today = LocalDate.now()` | Use `timezoneService.todayInWarehouse()` |
| `BillofladingService.java` | 644 | `billOfLading.setShipped(LocalDate.now())` | Use `timezoneService.todayInWarehouse()` |
| `Billoflading.java` | 21 | `private LocalDate shipped = LocalDate.now()` | Remove default; set explicitly in service code using warehouse TZ |
| `ReleaseExpiredPickingOrdersFromUserJob.java` | 84 | `LocalDateTime.now()` | OK -- timeout comparison, UTC is correct |
| `CleanUpOldMessageJobService.java` | 31 | `cal.setTime(new Date())` | OK -- cleanup threshold is relative, UTC is fine |
| `StockSummaryExportJob.java` | 108 | `LocalDateTime.now()` | OK -- export timestamp, UTC is correct |
| `MobileReplenishService.java` | 519, 566 | `new Date()` | OK -- timing measurement only |
| `ReplenishOrderJob.java` | 255, 293 | `new Date()` for picking date filter | Needs warehouse timezone for date comparison |

### 2.6 Set PostgreSQL Session Timezone Per-Tenant Connection (Recommended)

**Purpose:** Make `current_date` and `current_timestamp` in native SQL queries and views use the warehouse's local timezone automatically.

**Implementation:** Add to the tenant DataSource initialization (in `TenantDynamicRoutingDataSource` or connection pool `initSQL`):
```sql
SET timezone = '<warehouse_timezone_from_sysprop>';
```

Since each tenant has its own `System Time Zone` sysprop, the session timezone is set per-tenant when the connection is acquired.

**This makes the following transparent (no query changes needed):**
- `order_monitor_view` -- uses `current_date` in 6+ places for picking date comparisons
- `replenishment_monitor_view` -- uses `current_date` for picking date
- `MessageRepository.java:47,55` -- uses `current_date` for message cleanup
- All views that ORDER BY or filter on timestamp columns

**Files affected:**
- `src/main/java/net/aim_ai/wms/landlord/config/TenantDynamicRoutingDataSource.java` -- add connection init hook
- Or configure via HikariCP `connectionInitSql` per-tenant pool

### 2.7 Fix `new ObjectMapper()` Instances (Recommended)

36+ locations create `new ObjectMapper()` bypassing Spring config. After migration with JVM set to UTC, the bare ObjectMapper will use UTC by default BUT will NOT have `JavaTimeModule` registered, so `LocalDateTime`/`LocalDate` fields will serialize as numeric arrays instead of strings.

**Critical files (handle date-containing DTOs via ObjectMapper):**

| File | Instance Count | Priority |
|------|----------------|----------|
| `OrderRestController.java` | 10 | HIGH |
| `AdviceRestController.java` | 6 | HIGH |
| `TransactionReportRestController.java` | 4 | HIGH |
| `SkuRestController.java` | 4 | HIGH |
| `ManageOrderService.java` | 7 | HIGH |
| `BillofladingService.java` | 1 (static `MAPPER`) | HIGH -- static, no JavaTimeModule |
| `AdviceService.java` | 3 | MEDIUM |
| `CustomerorderBatchService.java` | 1 | MEDIUM |
| `CustomerorderService.java` | 1 | MEDIUM |
| `StockSummaryExportJob.java` | 1 | MEDIUM |
| `CycleCountController.java` | 1 | LOW |
| `DashboardController.java` | 1 | LOW |
| `CustomerOrderController.java` | 1 | LOW |
| `ItemDataController.java` | 1 | LOW |
| `MessageDummyController.java` | 1 | LOW |
| `UtilRestController.java` | 1 | LOW |
| `MessageService.java` | 1 | LOW |
| `SecurityConfiguration.java` | 1 (JWT only) | SKIP |

**Fix:** Inject the Spring-managed `ObjectMapper` bean, or create a shared static instance with `JavaTimeModule` and UTC timezone configured.

### 2.8 Fix `StartApplication.java` Repository Populator

**File:** `src/main/java/net/aim_ai/wms/StartApplication.java:44-48`

The `repositoryPopulator()` method creates a second `ObjectMapper` bean without `JavaTimeModule`. If this bean is ever injected by name instead of the `@Primary` one, date handling breaks. Fix by using the Spring-managed ObjectMapper or adding `JavaTimeModule`.

---

## Phase 3: Database Data Migration (Same Deployment as Phase 2)

**Purpose:** Convert all existing timestamp data from warehouse-local time to UTC and change column types to `timestamptz`. This Flyway migration runs at app startup BEFORE the app serves requests.

### 3.1 Create Flyway Migration Script

**File:** `src/main/resources/db/migration/V1.2.01__utc_timezone_migration.sql`

```sql
-- ============================================================
-- UTC Timezone Migration
-- Converts all 'timestamp without time zone' columns to 'timestamptz'
-- ============================================================

-- Step 1: Set session timezone so PostgreSQL interprets existing values correctly.
-- When converting 'timestamp without time zone' → 'timestamptz', PostgreSQL
-- interprets existing values in the session timezone. By setting it to the
-- warehouse's local timezone, PostgreSQL correctly converts:
--   '2026-01-15 14:00:00' (LA wall clock) → '2026-01-15 22:00:00+00' (UTC)
-- DST is handled automatically based on each specific date.
--
-- IMPORTANT: For multi-tenant deployments where databases store data in
-- DIFFERENT local timezones, this migration must be run per-database with
-- the correct SET timezone for each warehouse's timezone.
SET timezone = 'America/Los_Angeles';

-- Step 2: Convert all timestamp columns to timestamptz
-- 45 tables, 88 columns total

-- Audit columns (created/modified) on all 45 tables:
ALTER TABLE advice ALTER COLUMN created TYPE timestamptz;
ALTER TABLE advice ALTER COLUMN modified TYPE timestamptz;
ALTER TABLE adviceposition ALTER COLUMN created TYPE timestamptz;
ALTER TABLE adviceposition ALTER COLUMN modified TYPE timestamptz;
ALTER TABLE billoflading ALTER COLUMN created TYPE timestamptz;
ALTER TABLE billoflading ALTER COLUMN modified TYPE timestamptz;
ALTER TABLE billoflading_position ALTER COLUMN created TYPE timestamptz;
ALTER TABLE billoflading_position ALTER COLUMN modified TYPE timestamptz;
ALTER TABLE boxtype ALTER COLUMN created TYPE timestamptz;
ALTER TABLE boxtype ALTER COLUMN modified TYPE timestamptz;
ALTER TABLE client ALTER COLUMN created TYPE timestamptz;
ALTER TABLE client ALTER COLUMN modified TYPE timestamptz;
ALTER TABLE customerorder ALTER COLUMN created TYPE timestamptz;
ALTER TABLE customerorder ALTER COLUMN modified TYPE timestamptz;
ALTER TABLE customerorder_batch ALTER COLUMN created TYPE timestamptz;
ALTER TABLE customerorder_batch ALTER COLUMN modified TYPE timestamptz;
ALTER TABLE customerorder_position ALTER COLUMN created TYPE timestamptz;
ALTER TABLE customerorder_position ALTER COLUMN modified TYPE timestamptz;
ALTER TABLE cyclecount ALTER COLUMN created TYPE timestamptz;
ALTER TABLE cyclecount ALTER COLUMN modified TYPE timestamptz;
ALTER TABLE cyclecount_position ALTER COLUMN created TYPE timestamptz;
ALTER TABLE cyclecount_position ALTER COLUMN modified TYPE timestamptz;
ALTER TABLE fix_location_assignment ALTER COLUMN created TYPE timestamptz;
ALTER TABLE fix_location_assignment ALTER COLUMN modified TYPE timestamptz;
ALTER TABLE goodsreceipt ALTER COLUMN created TYPE timestamptz;
ALTER TABLE goodsreceipt ALTER COLUMN modified TYPE timestamptz;
ALTER TABLE goodsreceiptposition ALTER COLUMN created TYPE timestamptz;
ALTER TABLE goodsreceiptposition ALTER COLUMN modified TYPE timestamptz;
ALTER TABLE inventory_record ALTER COLUMN created TYPE timestamptz;
ALTER TABLE inventory_record ALTER COLUMN modified TYPE timestamptz;
ALTER TABLE itemdata ALTER COLUMN created TYPE timestamptz;
ALTER TABLE itemdata ALTER COLUMN modified TYPE timestamptz;
ALTER TABLE itemunit ALTER COLUMN created TYPE timestamptz;
ALTER TABLE itemunit ALTER COLUMN modified TYPE timestamptz;
ALTER TABLE location ALTER COLUMN created TYPE timestamptz;
ALTER TABLE location ALTER COLUMN modified TYPE timestamptz;
ALTER TABLE location_area ALTER COLUMN created TYPE timestamptz;
ALTER TABLE location_area ALTER COLUMN modified TYPE timestamptz;
ALTER TABLE location_constraint ALTER COLUMN created TYPE timestamptz;
ALTER TABLE location_constraint ALTER COLUMN modified TYPE timestamptz;
ALTER TABLE location_rack ALTER COLUMN created TYPE timestamptz;
ALTER TABLE location_rack ALTER COLUMN modified TYPE timestamptz;
ALTER TABLE location_rack_row ALTER COLUMN created TYPE timestamptz;
ALTER TABLE location_rack_row ALTER COLUMN modified TYPE timestamptz;
ALTER TABLE location_type ALTER COLUMN created TYPE timestamptz;
ALTER TABLE location_type ALTER COLUMN modified TYPE timestamptz;
ALTER TABLE los_sysprop ALTER COLUMN created TYPE timestamptz;
ALTER TABLE los_sysprop ALTER COLUMN modified TYPE timestamptz;
ALTER TABLE message ALTER COLUMN created TYPE timestamptz;
ALTER TABLE message ALTER COLUMN modified TYPE timestamptz;
ALTER TABLE message_archived ALTER COLUMN created TYPE timestamptz;
ALTER TABLE message_archived ALTER COLUMN modified TYPE timestamptz;
ALTER TABLE mywms_function ALTER COLUMN created TYPE timestamptz;
ALTER TABLE mywms_function ALTER COLUMN modified TYPE timestamptz;
ALTER TABLE mywms_group ALTER COLUMN created TYPE timestamptz;
ALTER TABLE mywms_group ALTER COLUMN modified TYPE timestamptz;
ALTER TABLE mywms_role ALTER COLUMN created TYPE timestamptz;
ALTER TABLE mywms_role ALTER COLUMN modified TYPE timestamptz;
ALTER TABLE mywms_user ALTER COLUMN created TYPE timestamptz;
ALTER TABLE mywms_user ALTER COLUMN modified TYPE timestamptz;
ALTER TABLE pickingorder ALTER COLUMN created TYPE timestamptz;
ALTER TABLE pickingorder ALTER COLUMN modified TYPE timestamptz;
ALTER TABLE pickingorder_position ALTER COLUMN created TYPE timestamptz;
ALTER TABLE pickingorder_position ALTER COLUMN modified TYPE timestamptz;
ALTER TABLE pickingorder_unitload ALTER COLUMN created TYPE timestamptz;
ALTER TABLE pickingorder_unitload ALTER COLUMN modified TYPE timestamptz;
ALTER TABLE printer ALTER COLUMN created TYPE timestamptz;
ALTER TABLE printer ALTER COLUMN modified TYPE timestamptz;
ALTER TABLE queryrepository ALTER COLUMN created TYPE timestamptz;
ALTER TABLE queryrepository ALTER COLUMN modified TYPE timestamptz;
ALTER TABLE replenishorder ALTER COLUMN created TYPE timestamptz;
ALTER TABLE replenishorder ALTER COLUMN modified TYPE timestamptz;
ALTER TABLE section ALTER COLUMN created TYPE timestamptz;
ALTER TABLE section ALTER COLUMN modified TYPE timestamptz;
ALTER TABLE shipperid ALTER COLUMN created TYPE timestamptz;
ALTER TABLE shipperid ALTER COLUMN modified TYPE timestamptz;
ALTER TABLE shippingmethod ALTER COLUMN created TYPE timestamptz;
ALTER TABLE shippingmethod ALTER COLUMN modified TYPE timestamptz;
ALTER TABLE stockrecord ALTER COLUMN created TYPE timestamptz;
ALTER TABLE stockrecord ALTER COLUMN modified TYPE timestamptz;
ALTER TABLE stockunit ALTER COLUMN created TYPE timestamptz;
ALTER TABLE stockunit ALTER COLUMN modified TYPE timestamptz;
ALTER TABLE unitload ALTER COLUMN created TYPE timestamptz;
ALTER TABLE unitload ALTER COLUMN modified TYPE timestamptz;
ALTER TABLE unitload_record ALTER COLUMN created TYPE timestamptz;
ALTER TABLE unitload_record ALTER COLUMN modified TYPE timestamptz;
ALTER TABLE unitload_type ALTER COLUMN created TYPE timestamptz;
ALTER TABLE unitload_type ALTER COLUMN modified TYPE timestamptz;

-- Business-specific timestamp columns:
ALTER TABLE goodsreceipt ALTER COLUMN receiptdate TYPE timestamptz;
ALTER TABLE inventory_record ALTER COLUMN "timestamp" TYPE timestamptz;

-- Step 3: Reset session timezone to UTC
SET timezone = 'UTC';
```

**Date columns that remain as `date` (NO conversion needed):**
- `advice.dayofdelivery` -- `date`
- `advice.dayofdeliveryuntil` -- `date`
- `billoflading.shipped` -- `date`
- `customerorder.pickingdate` -- `date`

These are timezone-agnostic by nature. The business logic determines which "date" using the warehouse timezone.

### 3.2 Update Stored Functions

**File:** `src/main/resources/db/migration/V1.2.02__utc_update_functions.sql`

Recreate the 3 stored functions with `timestamptz` parameter and return types. Order matters: `stock_history` is called by the other two, so it must be altered first.

```sql
-- stock_history: 1 input param (TIMESTAMP → timestamptz)
-- Body uses: WHERE sr.created > $1, WHERE bp.created > $1
-- Since columns are now timestamptz, param type must match.

-- transaction_detail: 2 timestamp params + 1 timestamp return column
-- Signature: (client_number VARCHAR, sku VARCHAR, startdate_in timestamptz, enddate_in timestamptz)
-- Returns: transaction_date timestamptz
-- Body uses: bp.modified BETWEEN $3 AND $4, sr.modified BETWEEN $3 AND $4, etc.

-- transaction_summary: 2 timestamp params (NO sku param)
-- Signature: (client_number VARCHAR, startdate_in timestamptz, enddate_in timestamptz)
-- Body uses: bp.modified BETWEEN $2 AND $3, calls stock_history($2), stock_history($3)
```

Full function definitions should be copied from `V1.1.04__wms_functions.sql` with all `timestamp without time zone` replaced by `timestamptz`.

### 3.3 Update Views

If using the recommended per-tenant session timezone approach (Phase 2.6), views work correctly as-is because `current_date` will reflect the tenant's timezone.

**Views that use `current_date` (verified):**
- `order_monitor_view` (latest definition in `V1.1.08__update_dashboard_summary_view.sql:3`) -- uses `current_date` on lines 14, 18, 22, 58, 62, 66
- `replenishment_monitor_view` (original in `V1.0.02__wms_views.sql:376`) -- uses `current_date` on line 421

**If NOT using per-tenant session timezone**, these views must be recreated with explicit timezone conversion:
```sql
-- Replace: co.pickingDate <= current_date
-- With:    co.pickingDate <= (now() AT TIME ZONE 'America/Los_Angeles')::date
```

### 3.4 System Time Zone Sysprop

The seed data at `V1.0.04__wms_init_data.sql:144` has `'America / New_York (-05:00)'`. Each tenant's `System Time Zone` value must be verified and updated to match the actual warehouse location before migration. This is a per-tenant data update, not a Flyway migration.

**Important:** The sysprop value format `"America / New_York (-05:00)"` includes spaces and an offset. The `TimezoneService.parseTimezoneId()` method (Phase 2.4) must handle this parsing.

### 3.5 Migration Performance Considerations

`ALTER COLUMN ... TYPE timestamptz` on large tables acquires an `ACCESS EXCLUSIVE` lock and rewrites the table. For tables with millions of rows (e.g., `stockrecord`, `unitload_record`, `pickingorder_position`), this may take minutes.

**Mitigations:**
- Run during maintenance window (planned downtime)
- Back up all tenant databases before migration
- Consider splitting large tables into a separate migration if lock duration is unacceptable
- Flyway runs the migration in a single transaction; any failure rolls back everything

---

## Phase 4: Frontend Updates

**Purpose:** Ensure both frontends correctly display UTC timestamps from the API in the warehouse's local timezone.

### 4.1 API Response Format Change

After migration, Jackson serializes timestamps in UTC ISO-8601:
- **Before:** `"2026-02-10 14:30:00"` (LA time, no offset, format: `yyyy-MM-dd HH:mm:ss`)
- **After:** `"2026-02-10T22:30:00.000Z"` (UTC with Z suffix)

The frontends must convert UTC to warehouse-local time for display. The warehouse timezone string is available from the `System Time Zone` sysprop (already fetched via the system properties API endpoint).

### 4.2 Fix Frontend Timezone Configuration

**wms-web-ui (`nuxt.config.js`):**
- Keep buildModules-level config at lines 57-60 (this is the active one)
- **Remove** the conflicting `publicRuntimeConfig.moment` at lines 163-165 (it's unused by `@nuxtjs/moment` and contradicts with `America/New_York`)
- Change `defaultTimezone` to use a dynamic value from the warehouse timezone setting or remove the default entirely (since we'll use explicit `.tz()` calls)

**wms-mobile-ui (`nuxt.config.js`):**
- **Add** a `moment:` config block at the module level:
```javascript
moment: {
  timezone: true,
  // No defaultTimezone - we'll use explicit .tz() calls with warehouse timezone
},
```
- Remove the unused `publicRuntimeConfig.moment` at lines 122-125

### 4.3 Create Centralized Date Formatting Plugin

**File:** `plugins/dateFormatter.js` (same file for both projects)

```javascript
export default ({ app, store }, inject) => {
  // Get warehouse timezone from store (loaded from System Time Zone sysprop)
  const getWarehouseTz = () => {
    return store?.state?.system?.warehouseTimezone || 'America/Los_Angeles'
  }

  inject('formatDateTime', (value) => {
    if (!value) return ''
    return app.$moment(value).tz(getWarehouseTz()).format('MM/DD/YYYY h:mm:ss a')
  })

  inject('formatDate', (value) => {
    if (!value) return ''
    return app.$moment(value).tz(getWarehouseTz()).format('MM/DD/YYYY')
  })

  inject('formatDateShort', (value) => {
    if (!value) return ''
    return app.$moment(value).tz(getWarehouseTz()).format('MM/DD/YY')
  })

  inject('formatTimeOnly', (value) => {
    if (!value) return ''
    return app.$moment(value).tz(getWarehouseTz()).format('h:mm:ss a')
  })

  inject('formatDateTimeShort', (value) => {
    if (!value) return ''
    return app.$moment(value).tz(getWarehouseTz()).format('MM/DD/YY h:mm:ss a')
  })

  // For sending dates back to API (convert warehouse-local to UTC ISO string)
  inject('parseDateForApi', (value) => {
    if (!value) return null
    return app.$moment.tz(value, getWarehouseTz()).utc().toISOString()
  })

  // For date pickers (date-only, no timezone conversion needed)
  inject('formatDateForPicker', (value) => {
    if (!value) return null
    return app.$moment(value).format('YYYY-MM-DD')
  })
}
```

Register in `nuxt.config.js`:
```javascript
plugins: [
  // ... existing plugins
  '~/plugins/dateFormatter',
],
```

### 4.4 Refactor Component Date Methods

Replace all 70+ component-local `getDate()`, `getTimeDate()`, `formatDate()` methods with the centralized plugin calls.

**Pattern replacement:**

| Before (component method) | After (injected method) |
|---------------------------|------------------------|
| `this.$moment(value).format('MM/DD/YYYY h:mm:ss a')` | `this.$formatDateTime(value)` |
| `this.$moment(value).format('MM/DD/YYYY')` | `this.$formatDate(value)` |
| `this.$moment(value).format('MM/DD/YY h:mm:ss a')` | `this.$formatDateTimeShort(value)` |
| `this.$moment(value).format('MM/DD/YY')` | `this.$formatDateShort(value)` |
| `this.$moment(value).format('h:mm:ss a')` | `this.$formatTimeOnly(value)` |

**Key components to update (wms-web-ui, non-exhaustive):**
- `stockUnitRecord.vue` -- also fix hardcoded `'Time Stamp (EST)'` header
- `openTransfers.vue`, `closedTransfers.vue`
- `openNoticeDescription.vue`, `closedNoticeDescription.vue`
- `parcelDetails.vue`, `transferDetails.vue`
- `openParcels.vue`, `closedParcels.vue`
- `inventoryReport.vue`, `receivingReport.vue`
- `editRepleishmentRequest.vue` -- currently uses `'MM/DD/YYYY hh:mm a z'` (only component showing timezone label)
- All other components with `getDate()` or `getTimeDate()` methods

**Components that do NOT need changes:**
- Label components using unix timestamps (`lineParcelPickingLabel.vue:130`, `ulLabels.vue:128`, `outboundPalletLabel.vue:128`) -- these consume different API data
- `NotificationNav.vue:97` -- uses `$moment.unix(time).fromNow()` (relative time, unaffected)

### 4.5 Update Date Picker Round-Trip

Date pickers currently send `YYYY-MM-DD` format strings. Since `date` columns are NOT converted to `timestamptz`, the picker behavior is unchanged for pure date fields.

**However, `transferDetails.vue:164` sends `'YYYY-MM-DD h:mm:ss'` format** -- this must be updated if the API now expects ISO-8601 or UTC:
```javascript
// Before:
parseDate(date) { return this.$moment(date).format('YYYY-MM-DD h:mm:ss') }
// After:
parseDate(date) { return this.$formatDateForPicker(date) }
```

### 4.6 Load Warehouse Timezone in Vuex Store

Add the warehouse timezone to the system/settings Vuex store so it's available to the date formatter plugin:

```javascript
// In store (e.g., system.js or settings.js)
state: () => ({
  warehouseTimezone: 'America/Los_Angeles', // default fallback
}),
mutations: {
  SET_WAREHOUSE_TIMEZONE(state, tz) { state.warehouseTimezone = tz },
},
actions: {
  async loadSystemSettings({ commit }) {
    // ... existing system properties loading
    // Extract and set warehouse timezone
    const tzProp = systemProps.find(p => p.syskey === 'System Time Zone')
    if (tzProp) {
      const tz = parseTimezoneId(tzProp.sysvalue) // same parsing as backend
      commit('SET_WAREHOUSE_TIMEZONE', tz)
    }
  },
}
```

---

## Phase 5: Post-Migration Cleanup & Hardening

### 5.1 Fix JPA Auditing

The codebase has `@EnableJpaAuditing` on `StartApplication` and `AbstractBaseEntity` already has `@CreatedDate`/`@LastModifiedDate`. After migration to UTC:
- Verify that audit timestamps are populated in UTC
- `LocalDateTime` with `@CreatedDate` will use the JVM timezone (now UTC) -- correct behavior

### 5.2 Consider Migrating from `LocalDateTime` to `Instant`

Long-term, entities should use `java.time.Instant` instead of `LocalDateTime` for timestamp fields. `Instant` is inherently UTC and maps naturally to `timestamptz`. This is a large refactor (125+ fields across 61 entities) and can be done incrementally.

### 5.3 Consolidate Remaining `new ObjectMapper()` Instances

Any instances not fixed in Phase 2.7 should be consolidated. Create a shared `ObjectMapperFactory` or utility if injection is impractical in all locations.

### 5.4 Remove Dead Timezone Config

- Remove `AdviceRestController.java:62` static SimpleDateFormat if still present
- Remove commented-out `#user.timezone=America/New_York` from properties files
- Remove `OrderReleaseJob.java:94` misleading "DB is UTC" comment (replace with accurate description)

---

## Deployment Sequence

```
Deploy 1 (Phase 1): Stabilize - pin JVM TZ, fix CronTrigger, fix bugs
   |
   | Verify everything works identically to before
   | Run full test suite, smoke test API, verify scheduled jobs
   v
Deploy 2 (Phases 2+3): The Big Switch [MAINTENANCE WINDOW]
   |
   | 1. Back up all tenant databases
   | 2. Take maintenance window (stop serving requests)
   | 3. Deploy new backend code with:
   |    - UTC application properties
   |    - UTC JVM timezone
   |    - TimezoneService utility
   |    - Per-tenant session timezone on connections
   |    - Business logic fixes for warehouse TZ
   |    - Flyway migration V1.2.01 + V1.2.02
   | 4. App starts → Flyway converts all data → app serves UTC
   | 5. Smoke test API responses (verify UTC format)
   v
Deploy 3 (Phase 4): Frontend updates [IMMEDIATELY AFTER Deploy 2]
   |
   | Deploy updated wms-web-ui and wms-mobile-ui with:
   |    - Centralized date formatter plugin
   |    - Warehouse timezone from system settings
   |    - Refactored component date methods
   |    - Fixed timezone config inconsistencies
   v
Phase 5: Cleanup (ongoing, lower priority)
```

**Critical:** Deploy 2 and Deploy 3 should happen back-to-back. If only the backend is deployed, the frontends will misinterpret UTC timestamps as local time (all displayed times will be shifted by the warehouse's UTC offset).

---

## Files Modified Summary

### Phase 1 (Stabilize) -- 7 files
| File | Change |
|------|--------|
| `StartApplication.java` | Add `@PostConstruct` with `TimeZone.setDefault("America/Los_Angeles")` |
| `SchedulingConfiguration.java` | Add `TimeZone` param to 5 `CronTrigger` calls (lines 151, 170, 189, 208, 225) |
| `AdviceController.java:38` | Replace static `SimpleDateFormat` with `DateTimeFormatter` |
| `CustomerOrderBatchController.java:26` | Replace static `SimpleDateFormat` with `DateTimeFormatter` |
| `FileExportService.java` | Fix `YYYY` → `yyyy` (lines 84, 152, 217, 285) |
| `WmsConstants.java:1036` | Fix `YYYY` → `yyyy` in `SYSTEM_PROPERTY_EXPORT_DATE_FORMAT_DEFAULT_VALUE` |
| `WebConfigurer.java:70` | Change `TimeZone.getDefault()` → `TimeZone.getTimeZone("America/Los_Angeles")` |

### Phase 2 (App Config) -- 12+ files
| File | Change |
|------|--------|
| `application.properties` | Change timezone settings to UTC |
| `application_dev.properties` | Change timezone settings to UTC |
| `StartApplication.java` | Change `@PostConstruct` to UTC; fix `repositoryPopulator()` ObjectMapper |
| `WebConfigurer.java` | Explicit UTC timezone; update date format to ISO-8601 |
| New `TimezoneService.java` | Warehouse timezone utility |
| `OrderRestController.java:421,429` | Use `timezoneService.todayInWarehouse()` |
| `ReleaseOrderJobService.java:110` | Use `timezoneService.todayInWarehouse()` |
| `CustomerorderService.java:221` | Use `timezoneService.todayInWarehouse()` |
| `BillofladingService.java:644` | Use `timezoneService.todayInWarehouse()` |
| `Billoflading.java:21` | Remove `LocalDate.now()` field default |
| `ReplenishOrderJob.java:255,293` | Use warehouse timezone for date comparison |
| `TenantDynamicRoutingDataSource.java` | Add per-tenant session timezone on connection |
| 36+ files with `new ObjectMapper()` | Inject Spring-managed ObjectMapper (prioritized list in 2.7) |

### Phase 3 (Database) -- 2 new files
| File | Change |
|------|--------|
| `V1.2.01__utc_timezone_migration.sql` | NEW -- 90 ALTER COLUMN statements + session timezone setup |
| `V1.2.02__utc_update_functions.sql` | NEW -- recreate 3 stored functions with `timestamptz` |

### Phase 4 (Frontend) -- 70+ files across 2 projects
| Area | Change |
|------|--------|
| `wms-web-ui/nuxt.config.js` | Remove conflicting publicRuntimeConfig.moment; update moment config |
| `wms-mobile-ui/nuxt.config.js` | Add moment timezone config block |
| `plugins/dateFormatter.js` (both projects) | NEW -- centralized date formatting with warehouse TZ |
| Vuex store (both projects) | Load warehouse timezone from system settings |
| 70+ Vue components | Replace component-local date methods with `$formatDate()` etc. |
| `transferDetails.vue:164` | Fix `parseDate()` for API date format |
| `stockUnitRecord.vue:142` | Remove hardcoded `'Time Stamp (EST)'` |

---

## Verification Plan

### Phase 1
- `mvn test` -- all existing tests pass
- Compare API date responses before/after (should be identical)
- Verify scheduled jobs fire at correct times
- Test `FileExportService` export near year boundary (verify YYYY fix)

### Phase 2 + 3
- **Pre-deploy:** Back up all tenant databases
- **Post-deploy checks:**
  1. Query a known record: `SELECT created, created AT TIME ZONE 'America/Los_Angeles' FROM advice LIMIT 1` -- verify UTC stored, LA display correct
  2. Hit API endpoint that returns timestamps -- verify ISO-8601 UTC format (`"2026-02-10T22:30:00.000Z"`)
  3. Create a new record via API -- verify `created` is stored in UTC
  4. Test picking date logic around midnight warehouse time (the edge case where UTC date differs from local date)
  5. Run `OrderReleaseJob` manually -- verify it still uses warehouse timezone correctly
  6. Check `OrderMonitorView` queries -- verify `current_date` returns correct warehouse date (requires per-tenant session TZ)
  7. Run transaction report endpoints -- verify date range queries work with `timestamptz` function params
  8. Verify `MessageRepository` cleanup queries use correct `current_date`

### Phase 4
- Verify frontend displays dates in warehouse-local time (not UTC, not browser local)
- Test date pickers send correct values to API
- Cross-check created/modified timestamps: API returns UTC, frontend shows warehouse-local
- Test the midnight edge case: create a record at 11:30 PM warehouse time, verify it shows correct local date
- Verify `stockUnitRecord` table header no longer says `(EST)`

---

## Risk Mitigation

| Risk | Mitigation |
|------|-----------|
| Data corruption during migration | Full database backup before deploy; Flyway runs in transaction; test on staging first |
| Wrong timezone conversion (DST) | `SET timezone = 'America/Los_Angeles'` + `ALTER TYPE timestamptz` handles DST automatically per-date |
| Frontend breaking on new date format | Deploy frontend immediately after backend; centralized formatter makes it systematic |
| Scheduled jobs fire at wrong time | Phase 1 pins timezone explicitly; Phase 2 updates CronTrigger to read warehouse TZ from sysprop |
| Native queries return wrong "today" | Per-tenant session timezone (Phase 2.6) makes `current_date` transparent |
| Multi-tenant: different warehouses, different timezones | `System Time Zone` sysprop is per-tenant; session timezone set per-connection; `TimezoneService` reads per-tenant |
| Large table lock duration during ALTER | Run during maintenance window; monitor `stockrecord` and `unitload_record` specifically |
| `new ObjectMapper()` instances produce wrong format | Phase 2.7 fixes critical ones; JVM UTC default provides baseline safety |
| Frontend-backend deployment gap | Deploy both back-to-back in same release window; frontend timezone formatter gracefully handles both old and new formats via moment's auto-detection |

---

## Multi-Tenant Considerations

Since this is a multi-tenant system where each tenant may have a warehouse in a different timezone:

1. **Database migration (`V1.2.01`):** The `SET timezone` at the top must match the timezone that was used when data was originally written. If ALL tenants currently use `America/Los_Angeles` (the Hibernate config), then a single `SET timezone = 'America/Los_Angeles'` is correct for all tenant databases. If some tenants store data in different timezones, each tenant database needs its own migration with the correct `SET timezone`.

2. **Per-tenant session timezone:** After migration, each tenant's database connection should set `SET timezone = '<warehouse_tz>'` from that tenant's `System Time Zone` sysprop. This makes `current_date` in views and native queries correct for each warehouse.

3. **Frontend timezone:** Each tenant's frontend instance loads the `System Time Zone` from the API and uses it for display conversion. No hardcoded timezone in the frontend.

4. **New tenant onboarding:** New tenants should have their `System Time Zone` sysprop set correctly during tenant provisioning. The backend writes UTC regardless of the tenant's timezone.
