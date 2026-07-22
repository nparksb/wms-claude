---
title: "Log Whole-Unit-Load Relocations in Stock-Unit History (Move Fixed Location + Move Stock) — v2 PORT"
ticket: ""
ticket_url: ""
pr: "https://github.com/SiteBossInc/wms2-api/pull/49"
type: bug
priority: medium
status: archived
project:
  - wms2-api
version: v2
requester: "v1→v2 sync sweep 2026-06-25 (Lane B)"
created: 2026-06-24
updated: "2026-07-15"
db_verified: false
v1_source_plan: "[[260624-stock-unit-history-on-unitload-relocation]] (v1/wms-api)"
v1_commits:
  - "c46688e (base: recordRelocation + STOCK_RELOCATED)"
  - "8767fd3 (specific NoSuchElement msgs + null-amount guard)"
  - "b39b44d (SBDEV-2488: amount = moved qty, not ZERO)"
related:
  - "[[260624-stock-unit-history-on-unitload-relocation]]"
tags:
  - plan
  - stock-history
  - move-stock
  - v2-port
---

# Log Whole-Unit-Load Relocations in Stock-Unit History — v2 Port (wms2-api)

**V1 Source Plan:** `sbdocs/1-Projects/wms1/plan/260624-stock-unit-history-on-unitload-relocation.md` (implemented in v1, PR #178 + SBDEV-2488 PR #181).
**V2 Target:** `v2/wms2-api` (Java 21, Spring Boot 3.5, dual transaction managers, multi-replica).
**Status:** PENDING APPROVAL (ralplan consensus). **Priority:** medium.

> Scope mirrors v1 exactly: logs the **two operator whole-UL relocation paths** — Move Fixed Location (`CODE_MOVE_FIX_ASSIGNMENT`) and Move Stock whole-UL branch (`CODE_MANUAL_TRANSFER`). Does **not** cover any mobile Move-Unitload path or system moves (shipping/putaway/BOL). The relocation row carries the **moved quantity** in `amount` (SBDEV-2488 final semantics), which the stock-unit-history UI surfaces as "Moved".

> `db_verified: false` — code-provable port (a new `Stockrecord` write at two named call sites). Empirical close-out: one Move Fixed Location on a v2 tenant, then confirm a `stockrecord` row `type='STOCK_RELOCATED'` with `amount = amountstock`. No schema change; `STOCK_RELOCATED` is a new value in the free-text `stockrecord.type` column.

---

## 2. Summary

| Metric | Count |
|--------|------:|
| v1 fixes to port (F-A…F-D) | 4 |
| Already correct in v2 | 0 |
| Confirmed still needed in v2 | 4 |
| NEW v2-only issues discovered | 1 blocking (NEW-1) + 1 mechanical (NEW-2); NEW-3 informational, NEW-4 cleared |

**Architectural divergences affecting the port:**
- **Dual transaction managers** — every tenant `@Transactional` must specify `value = "tenantTransactionManager"`. **NEW-1: `FixLocationAssignmentService.move()` currently has NO `@Transactional` at all** → the relocation write (and the UL move) would run on the `@Primary` landlord TM in auto-commit. Adding the tenant TM is part of F-C and gated in Phase 0.
- **Constructor injection** (final fields) — `StockrecordService` must be added to the constructors of `FixLocationAssignmentService` and `StockunitService` (NEW-2). It is **not** needed as a new field inside `StockrecordService` itself (all deps already injected).
- **`recordTransferStockUnit` model method differs from v1** — v2's `recordTransferStockUnit` sets `amount = BigDecimal.ZERO` (`:272`); the new `recordRelocation` must set `amount = stockunit.getAmount()` and must **not** clone the ZERO.
- **Report-safety verified identical to v1** — `transaction_detail` (WHERE allow-list) and `transaction_summary` (sum-of-CASE, no catch-all) exclude `STOCK_RELOCATED`/`MOVE_FIX_ASSIGNMENT`/`MANUAL_TRANSFER` regardless of amount, so the non-zero `amount` is report-safe.

---

## 3. V1 → V2 Applicability Analysis

| V1 Fix | Description | V2 Verdict | Rationale (v2 file:line) |
|--------|-------------|------------|--------------------------|
| F-A | Add `STOCK_RELOCATED` to `StockRecordType` | **Needed** | `WmsConstants.java:184-196` (String constants); `STOCK_RELOCATED` absent. Insert after `:195`. |
| F-B | `StockrecordService.recordRelocation(...)` | **Needed** | `StockrecordService.java` — method absent; model `recordTransferStockUnit` at `:265-303`; all deps already constructor-injected `:34-49`. Override `amount` to `stockunit.getAmount()` (NOT the `:272` ZERO). |
| F-C | Call `recordRelocation` in `FixLocationAssignmentService.move()` | **Needed (CRITICAL — pairs with NEW-1)** | `move()` `:103-173`; transfer call `:156`; `oldLocation` `:106`; `stockunitList` `:147`; size>1 hard-throw `:151-153`. Inject `StockrecordService` (constructor `:45-73`). **Add tenant `@Transactional` (NEW-1).** |
| F-D | Call `recordRelocation` in `StockunitService.transferStock()` whole-UL branch | **Needed** | `transferStock` `@Transactional(tenantTransactionManager…)` `:144-145` (already correct); whole-UL branch `:200-210`, gate `:206`; transfer call `:208`; `ulLocation` `:203`. Inject `StockrecordService` (constructor `:70-118`). |

---

## 4. V2-Specific Adaptation Notes

1. **Transaction manager:** `FixLocationAssignmentService.move()` gains `@Transactional(value = "tenantTransactionManager", rollbackFor = {BusinessException.class, FacadeException.class})` (NEW-1). `StockunitService.transferStock()` already has it.
2. **Constructor injection:** add `StockrecordService` as a `final` constructor parameter to `FixLocationAssignmentService` and `StockunitService` (NEW-2). Do not use `@Autowired` field injection. No constructor change inside `StockrecordService`.
3. **`Optional` handling:** `recordRelocation` lookups use `.orElseThrow(() -> new EntityNotFoundException(...))` (v2 idiom; matches the surrounding methods).
4. **Amount semantics:** `rec.setAmount(stockunit.getAmount())` (moved qty) — NOT `BigDecimal.ZERO`. Add a code comment: report-safety is provided by the `(activitycode,type)` allow-list, not by zeroing amount, so a maintainer does not re-zero it.
5. **SLF4J parameterized logging** for the zero-amount skip (`LOG.debug`).
6. **Entity equality:** N/A — relocation logging compares no entities.
7. **Jakarta namespace:** no `javax`→`jakarta` swaps needed in the touched files (no such imports present); `EntityNotFoundException` is the v2 `net.aim_ai.wms.exceptions` type already used in `StockrecordService`.

---

## 5. Changes by File

### 5.0 Prerequisites (§5.1)

| # | Prerequisite | Value / action | Notes |
|---|---|---|---|
| 1 | DB state | **N/A** — no schema change; `STOCK_RELOCATED` is a new value in the existing `stockrecord.type` text column. | No Flyway migration. |
| 2 | Feature flags / sysprops | **N/A** — unconditional for the two operator paths. | |
| 3 | Config / env | **N/A** for prod. ITs: Testcontainers Postgres (real Flyway functions). | |
| 4 | Deploy-order deps (oms-laravel-api / omsv2-UI) | **N/A** — no OMS notification / outbox / API contract change. | Relocation row is internal audit only. |
| 5 | Data migration | **N/A** — additive going forward; no backfill. | |
| 6 | UI label | **RESOLVED — not applicable (investigated 2026-06-25).** `wms2-web-ui` `components/reports/stockUnitRecord.vue` renders the "Type" column as the **raw `item.type` string** (no item slot, no label map) — and so does v1/wms-web-ui. There is **no `STOCK_*` label map** in either UI; every type (`STOCK_CREATED`, `STOCK_TRANSFERRED`, …) shows as its raw constant. So `STOCK_RELOCATED` displays as `"STOCK_RELOCATED"` — consistent with all other types, not blank/broken. **Nothing to add.** A friendly-label formatter (e.g. "Relocated") would be a *new* enhancement covering all types and would diverge from v1 — explicitly out of scope for parity. | |

### 5.1 `WmsConstants.java` (F-A)

| V1 Fix | V2 Line | Status | Action | Priority |
|--------|---------|--------|--------|----------|
| F-A | `:195` (after `STOCK_RESERVED_CHANGED`) | Confirmed missing | Add constant | P1 |

```java
public static final String STOCK_RESERVED_CHANGED = "STOCK_RESERVED_CHANGED";
public static final String STOCK_RELOCATED = "STOCK_RELOCATED";   // NEW (v1 F-A)
```

### 5.2 `StockrecordService.java` (F-B)

| V1 Fix | V2 Line | Status | Action | Priority |
|--------|---------|--------|--------|----------|
| F-B | new method after `:303` | Confirmed missing | Add `recordRelocation` | P1 |

**Fix (v2-specific)** — model on `recordTransferStockUnit` (`:265-303`); all deps already injected (`:34-49`):

```java
public void recordRelocation(Stockunit stockunit, Location fromLocation, Location toLocation,
                             String activityCode, String orderNumber, String comment) {
    if (stockunit.getAmount() == null || BigDecimal.ZERO.compareTo(stockunit.getAmount()) >= 0) {
        LOG.debug("Do not record zero amount relocation");
        return;
    }
    Stockrecord rec = new Stockrecord();
    // NOTE (v2 divergence from v1): do NOT call setId/getNextId. v2's StockrecordRepository has no
    // getNextId(), and the model writer recordTransferStockUnit (:265-303) never sets the id — JPA
    // generates it on save(). Cloning the v1 manual-id idiom would fail to compile.
    rec.setOperator(SecurityContextUtils.getUserName());
    // A whole-UL relocation moves the entire stock unit, so the moved transaction amount equals the
    // stock unit's amount (UI "Moved" column reads amount; SBDEV-2488). Report-safety is NOT provided
    // by zeroing this amount: transaction_detail / transaction_summary select/sum only on an explicit
    // (activitycode, type) allow-list, and (MOVE_FIX_ASSIGNMENT|MANUAL_TRANSFER, STOCK_RELOCATED)
    // matches none -> excluded from every total/detail line regardless of amount. Do not re-zero.
    rec.setAmount(stockunit.getAmount());
    rec.setAmountstock(stockunit.getAmount());
    rec.setClientId(stockunit.getClientId());

    rec.setFromstockunitidentity(String.valueOf(stockunit.getId()));
    rec.setTostockunitidentity(String.valueOf(stockunit.getId()));

    Unitload unitload = unitloadRepository.findById(stockunit.getUnitloadId())
        .orElseThrow(() -> new EntityNotFoundException("Unitload not found: " + stockunit.getUnitloadId()));
    rec.setFromunitload(unitload.getLabelid());
    rec.setTounitload(unitload.getLabelid());

    rec.setFromstoragelocation(fromLocation.getName());
    rec.setTostoragelocation(toLocation.getName());

    Itemdata itemdata = itemdataRepository.findById(stockunit.getItemdataId())
        .orElseThrow(() -> new EntityNotFoundException("Itemdata not found: " + stockunit.getItemdataId()));
    rec.setItemdata(itemdata.getItemNr());
    rec.setScale(itemdata.getScale());

    rec.setType(WmsConstants.StockRecordType.STOCK_RELOCATED);
    rec.setActivitycode(activityCode);
    rec.setOrdernumber(orderNumber);
    rec.setAdditionalcontent(comment);

    UnitloadType unitloadType = unitloadTypeRepository.findById(unitload.getTypeId())
        .orElseThrow(() -> new EntityNotFoundException("UnitloadType not found: " + unitload.getTypeId()));
    rec.setUnitloadtype(unitloadType.getName());
    rec.setEntityLock(0);

    stockrecordRepository.save(rec);
}
```
**Why:** mirrors the v1 final state (post b39b44d). `EntityNotFoundException` (v2) replaces v1's `NoSuchElementException`. Exact getter names (`getItemNr`/`getScale`/`getLabelid`/`getTypeId`/`getName`) to be confirmed against v2 entities at implementation (they match the v1 entity API and v2 `recordTransferStockUnit` usage).

### 5.3 `FixLocationAssignmentService.java` (F-C + NEW-1)

| V1 Fix | V2 Line | Status | Action | Priority |
|--------|---------|--------|--------|----------|
| NEW-1 | `:103` (method) | Missing annotation | Add tenant `@Transactional` | **P0** |
| F-C | constructor `:45-73`; after `:156` | Confirmed missing | Inject `StockrecordService`; per-su `recordRelocation` | P1 |

- **NEW-1 (P0):** annotate `move(...)` with `@Transactional(value = "tenantTransactionManager", rollbackFor = {BusinessException.class, FacadeException.class})`. **This is an intentional atomicity change**, not a no-op: today `move()` runs with no tx (the nested `transferUnitLoadToLocation` at `:156` is itself `@Transactional`, `UnitloadBusinessService:107`, so it commits independently; the surrounding `unitloadRepository.save`/FLA save run in auto-commit). After the change all of `move()`'s tenant writes — including the relocation row — commit or roll back together. `move()` does only repo reads/saves + `triggerReplenishmentMaintenance` (no HTTP/printer/outbox/@Async, architect-verified), so widening the tx is safe.
- Add `StockrecordService stockrecordService` to the constructor (final field).
- **v2 ordering (differs from v1):** in v2 `move()` the transfer happens **first** at `:156`, then the UL is re-read and **relabelled to `destination.getName()`** at `:157-159`, then the FLA is saved at `:161`. Insert the relocation loop **after `:161`** (end of the write sequence, inside the new tx). `oldLocation` is captured at `:106` **before** the transfer, and `destination` at `:111`, so passing them explicitly guarantees from!=to even though the UL has been relabelled:
```java
for (Stockunit su : stockunitList) {                 // size==1 by the :151-153 guard
    stockrecordService.recordRelocation(su, oldLocation, destination,
        WmsConstants.CODE_MOVE_FIX_ASSIGNMENT, null, null);
}
```

### 5.4 `StockunitService.java` (F-D)

| V1 Fix | V2 Line | Status | Action | Priority |
|--------|---------|--------|--------|----------|
| F-D | constructor `:70-118`; after `:208` (before the `:210` re-read) | Confirmed missing | Inject `StockrecordService`; `recordRelocation` in whole-UL branch | P1 |

- Add `StockrecordService stockrecordService` to the constructor (final field).
- In the whole-UL branch (`:200-210`, gate `:206`), after the `transferUnitLoadToLocation(...)` call at `:208`:
```java
stockrecordService.recordRelocation(stockUnit, ulLocation, destinationLocation,
    WmsConstants.CODE_MANUAL_TRANSFER, null, comment);
```
`ulLocation` (`:203`) captured before the move; `destinationLocation` is the target. `transferStock` is already `@Transactional(tenantTransactionManager…)` (`:144-145`).

---

## 6. NEW Issues Summary

| NEW-# | Issue | File:Line | Severity | Description |
|-------|-------|-----------|----------|-------------|
| NEW-1 | `FixLocationAssignmentService.move()` has **no `@Transactional`** | `FixLocationAssignmentService.java:103` (none); class `:15-16` (none) | **High** | Without the tenant TM, the relocation write + the UL move run on the `@Primary` landlord TM in auto-commit — no rollback if a later step throws. Fix in Phase 0 (P0). |
| NEW-2 | `StockrecordService` not injected into the two call-site classes | `FixLocationAssignmentService.java:45-73`; `StockunitService.java:70-118` | Low | Pure constructor-injection addition; matches existing `final`-field pattern. |
| NEW-3 | `transaction_detail` exists as two overloads post-migration (timestamptz V1.2.05 + timestamp-without-tz V2.1.07) | `V1.2.05:111`, `V2.1.07:9`, `StockrecordRepository.java:25-29` | Informational | Both share the identical allow-list → STOCK_RELOCATED excluded either way. Relevant only so the IT author knows both exist in the Testcontainers DB. |
| NEW-4 | Async / horizontal-scaling concern | call sites `:103-173` / `:200-210` | None (cleared) | Both call sites synchronous on the request thread; no `@Async`/`parallelStream`. Multi-replica safe. |

---

## 7. Implementation Priority

- **Phase 0 (P0, blocking):** NEW-1 — add tenant `@Transactional` to `FixLocationAssignmentService.move()`. Without it, F-C's write is non-transactional.
- **Phase 1 (P1):** F-A constant → F-B `recordRelocation` → constructor injection (NEW-2) → F-C loop + F-D call.
- **Phase 2:** tests (unit + report-exclusion IT).
- **Phase 3 (verification commands):**
  - `mvn clean compile` (Java 21 via SDKMAN; confirms constructor-injection wiring, NEW-2).
  - `mvn test -Dtest=StockrecordServiceUnitTest,FixLocationAssignmentServiceUnitTest,StockunitServiceUnitTest`
  - `mvn verify -Dit.test=ClientRepositoryIntegrationTest,FixLocationAssignmentServiceIT` (Testcontainers Postgres — real Flyway functions; no `api.version` flag, that's a v1-only incantation).
  - **AC-8 IT note:** bind the date params with a type that resolves deterministically to one `transaction_detail`/`transaction_summary` overload (NEW-3: two overloads coexist post-migration) to avoid a Postgres `function ... is not unique` error.
  - **Scope-guard (AC-4) parity:** port the v1 verify-script's NEGATIVE static check (assert `UnitloadBusinessService` / `processTransfer` does **not** reference `recordRelocation`) into a v2 verify-script under `sbdocs/9-System/scripts/`, rather than relying on "by inspection".
  - Code review. Update §11 Implementation Status (v2 SHA, test counts).
- **Open question (low risk, out of AC-7 path):** `move()` now runs in a tenant tx and calls `triggerReplenishmentMaintenance` (`:172`, after the relocation write) inside an exception-swallowing try/catch. If `replenishmentOrderMaintenanceService.recalculateForItem` is itself `@Transactional` and throws, confirm a marked-rollback-only inner tx cannot surface as `UnexpectedRollbackException` at commit. Does not affect AC-7 (which forces a `BusinessException` directly).

### Horizontal Scalability Validation

| # | Concern | Verdict | Evidence |
|---|---------|---------|----------|
| 1 | In-JVM state | N/A | No static/in-memory state added. |
| 2 | Connection pool math | N/A | One extra INSERT inside the existing tenant tx; no new pool usage. |
| 3 | Scheduled jobs | N/A | No `@Scheduled` touched. |
| 4 | Long transactions | N/A | Single-row insert within an already-bounded request tx. |
| 5 | Request affinity | N/A | No session/sticky state. |
| 6 | Retry / idempotency | N/A | Relocation is part of the operator move tx; rolls back with it. No outbox/OMS. |
| 7 | Tenant context | **Yes (safe)** | Write runs on the request thread; `TenantContext` + `SecurityContextUtils.getUserName()` resolve there. No async hand-off (NEW-4). |
| 8 | Distributed lock | N/A | No advisory lock involved. |
| 9 | Cache invalidation | N/A | `stockrecord` is not cached. |
| 10 | External notifications | N/A | No OMS/printer/webhook. |

---

## 8. Testing Plan

**Unit (extend existing scaffolds — do NOT create parallel files):**

| Test class | Method | Asserts | AC |
|------------|--------|---------|-----|
| `StockrecordServiceUnitTest` | `recordRelocation_writesStockRelocatedWithCorrectFieldMapping` | type=STOCK_RELOCATED, from/to su identity=su.id, fromunitload==tounitload, from/to location names, activitycode/ordernumber/additionalcontent, itemdata/scale, unitloadtype, entityLock=0 | AC-1/2 |
| `StockrecordServiceUnitTest` | `recordRelocation_amountAndAmountstockEqualStockunitAmount` | `amount == amountstock == stockunit.getAmount()` | AC-5 |
| `StockrecordServiceUnitTest` | `recordRelocation_zeroOrNullAmountSkipped` | null and `<=0` → `save` never called | AC-6 |
| `StockrecordServiceUnitTest` | `recordRelocation_operatorFromSecurityContext` | operator = SecurityContext username | AC-1/2 |
| `FixLocationAssignmentServiceUnitTest` | `move_recordsRelocation_withOldLocationCapturedPreMove` | `recordRelocation(su, oldLocation, destination, MOVE_FIX_ASSIGNMENT, …)` invoked after transfer; from != to | AC-1 |
| `StockunitServiceUnitTest` | `transferStock_wholeUL_recordsRelocation` | relocation recorded in size()==1 whole-UL branch (MANUAL_TRANSFER) | AC-2 |
| `StockunitServiceUnitTest` | `transferStock_split_noRelocation` | split/to-different-UL branch records STOCK_TRANSFERRED and **no** STOCK_RELOCATED (no double-logging) | AC-3 |

**Integration (Testcontainers Postgres — real Flyway functions):**

| Test class | Method | Asserts | AC |
|------------|--------|---------|-----|
| `ClientRepositoryIntegrationTest` (extend, near `:288-298`) | `stockRelocated_excludedFromTransactionDetailAndSummary` | Seed a `STOCK_RELOCATED` row **via `recordRelocation`** (non-zero amount, activitycode=MANUAL_TRANSFER, in-window) → no `transaction_detail` line; 0 contribution to every `transaction_summary` total | AC-8 |
| `FixLocationAssignmentServiceIT` (new or extend) | `move_rollsBackRelocationRow_onBusinessExceptionAfterWrite` | Force a `BusinessException` after the relocation write inside `move()` → no `STOCK_RELOCATED` row persists (proves tenant tx is effective, NEW-1/AC-7) | AC-7 |
| `FixLocationAssignmentServiceIT` | `move_writesRelocation_fromNotEqualTo` | After a real `move()`, the `STOCK_RELOCATED` row has `fromstoragelocation != tostoragelocation` (both non-null) | AC-9 |

> If a Testcontainers IT for the rollback (AC-7) proves impractical to trigger deterministically, fall back to a Spring `@SpringBootTest` slice asserting the proxy carries the `tenantTransactionManager` advisor on `move()`; record the substitution in the Test Plan. Prefer the real rollback IT.

**Scope-guard (AC-4):** assert (unit or by inspection) that the system `processTransfer` path / `UnitloadBusinessService` does not call `recordRelocation`.

**Manual test plan:**

| Scenario | Environment | Steps | Expected | Pass/Fail |
|---|---|---|---|---|
| Move Fixed Location logs relocation | v2 staging (a tenant) | FLA w/ 1 UL/1 SU → Move Fixed Location to empty location → open SU stock-unit history | New row STOCK_RELOCATED, from=old, to=dest, "Moved"=SU amount, operator=me | |
| Move Stock whole-UL logs relocation | v2 staging | Whole-UL Move Stock (full amount, no FLA, single SU) → SU history | New row STOCK_RELOCATED, activity MANUAL_TRANSFER, comment carried | |
| Split still TRANSFERRED only | v2 staging | Partial Move Stock to a different container | STOCK_TRANSFERRED row; no STOCK_RELOCATED | |
| Report not skewed | v2 staging DB | Run inventory transaction report over a window with a relocation | Totals unchanged; no relocation detail line | |

### Acceptance Criteria

| AC | Statement |
|----|-----------|
| AC-1 | Move Fixed Location → one `STOCK_RELOCATED` (from!=to non-null, fromunitload==tounitload, activitycode=MOVE_FIX_ASSIGNMENT, `amount == stockunit amount`). |
| AC-2 | Move Stock whole-UL branch → same shape, activitycode=MANUAL_TRANSFER. |
| AC-3 | Split / to-different-UL move still logs `STOCK_TRANSFERRED` and **no** `STOCK_RELOCATED`. |
| AC-4 | System whole-UL move via `processTransfer` writes **no** `STOCK_RELOCATED` (scope guard). |
| AC-5 | `recordRelocation` row has `amount == amountstock == stockunit.getAmount()`. |
| AC-6 | null / `<=0` amount → `recordRelocation` writes nothing. |
| AC-7 | **Effect, not just annotation:** `FixLocationAssignmentService.move()` is wrapped in the tenant tx — a `BusinessException` thrown after the relocation write inside `move()` rolls the `STOCK_RELOCATED` row back (no orphan audit row). The annotation string `@Transactional(value="tenantTransactionManager", rollbackFor={BusinessException.class, FacadeException.class})` is necessary but the IT asserts the rollback behavior so a bare `@Transactional` (wrong TM) fails the gate. |
| AC-8 | A `STOCK_RELOCATED` row with a **non-zero** amount, seeded **via the real `recordRelocation` writer** (not a hand-built row), contributes 0 to all `transaction_summary` totals and produces no `transaction_detail` line (Testcontainers IT). Seeding through the writer means the test breaks if the writer's `(activitycode,type)` ever drifts out of the excluded set. |
| AC-9 | After a real `move()`, the written `STOCK_RELOCATED` row has `fromstoragelocation != tostoragelocation` (both non-null) despite v2 relabelling the UL post-transfer — proves `oldLocation` is captured pre-move. |

---

## 9. Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| Wrong transaction manager on `move()` (bare `@Transactional` or none) | Medium | High | NEW-1 P0: explicit `tenantTransactionManager`; AC-7 asserts it. |
| Relocation skews inventory reports | Low | High | Verified allow-list exclusion (V2.1.07/V1.2.05); locked by AC-8 IT with a non-zero amount. |
| Double-logging (path both transfers + relocates) | Low | Medium | `recordRelocation` only in the two whole-UL operator branches; AC-3 asserts no overlap. |
| Circular DI from new constructor dep | Low | Medium | `StockrecordService` has no dependency on `FixLocationAssignmentService`/`StockunitService`; one-directional. Verify on `mvn clean compile` + context load. |
| Old location captured after the move (from==to) | Low | High | Both sites read the old `Location` before `transferUnitLoadToLocation` (`:106`/`:203`); AC-1 asserts from!=to. |
| UI renders unknown `STOCK_RELOCATED` label raw/blank | Medium | Low | Server change additive; flag for wms2-web-ui label map (§5.0-#6). |
| Wrong v2 getter/exception names | Low | Low | Confirm against v2 entities at implementation; `EntityNotFoundException` already used in `StockrecordService`. |

---

## 10. ADR

- **Decision:** Port the v1 relocation-logging feature to v2 verbatim in behavior, with `amount = stockunit.getAmount()` (SBDEV-2488 final semantics), adding the missing tenant `@Transactional` on `move()` (NEW-1).
- **Drivers:** v1↔v2 audit-trail parity; v1 plan §10-#3 designates this port; report-safety already verified in v2.
- **Alternatives considered:** (A) mirror v1 with non-zero amount + rely on allow-list [CHOSEN]; (B) write `amount=0` like v2's `recordTransferStockUnit` — rejected: loses the moved-qty in the audit row, defeats SBDEV-2488; (C) log inside `processTransfer` — rejected (v1 Option B): floods history with system moves.
- **Why chosen:** lowest blast radius, faithful to v1, report-safe by the verified allow-list, locked by an IT seeding a non-zero amount.
- **Consequences:** one extra INSERT per operator whole-UL move inside the existing tenant tx; `move()` becomes transactional (NEW-1) — an improvement.
- **Follow-ups:** wms2-web-ui `STOCK_RELOCATED` label map (separate UI task); mobile Move-Unitload path remains out of scope (matches v1).

---

## 11. Implementation Status

**Implemented 2026-06-25** (v1→v2 sync sweep, Lane B) on branch `port/SBDEV-2488-relocation-stock-history` (off `develop`), commit **`7f82adb`**, **[PR #49](https://github.com/SiteBossInc/wms2-api/pull/49)** → `develop`. Status: `implemented` (pending merge + IT verification per SBDEV-2217).

Ports v1 `c46688e` + `8767fd3` + `b39b44d`. Consensus: ralplan (Planner → Architect SOUND-WITH-NITS → Critic APPROVE); TDD-gate run (4 unit fail-first → green after implementation).

| Item | Status | Notes |
|------|--------|-------|
| F-A `WmsConstants.STOCK_RELOCATED` | ✅ done | After `STOCK_RESERVED_CHANGED`. |
| F-B `StockrecordService.recordRelocation` | ✅ done | `StockrecordService.java:305-364`; `amount = stockunit.getAmount()` (NOT zero); no `setId` (JPA-generated); two-arg `EntityNotFoundException("Entity", id)` matching the file idiom; report-safety code comment present. |
| F-C `FixLocationAssignmentService` (+NEW-1) | ✅ done | `@Transactional(tenantTransactionManager, rollbackFor={BusinessException,FacadeException})` on `move()` (`:108`); per-su `recordRelocation` loop after FLA save (`:171-172`). |
| F-D `StockunitService` whole-UL branch | ✅ done | `recordRelocation(stockUnit, ulLocation, destinationLocation, CODE_MANUAL_TRANSFER, null, comment)` (`:215-216`); method already tenant-transactional. |
| Unit tests | ✅ **126/126 pass** | `StockrecordServiceUnitTest` 23, `FixLocationAssignmentServiceUnitTest` 36, `StockunitServiceUnitTest` 67. Covers AC-1/2/3/5/6. |
| `mvn clean compile` | ✅ BUILD SUCCESS | Constructor-injection wiring OK; no DI cycle. |
| Integration tests (AC-7/8/9) | ⏸ **written, `@Disabled`** | `FixLocationAssignmentServiceIT` (rollback AC-7, from!=to AC-9), `ClientRepositoryIntegrationTest` AC-8 report-exclusion. **Blocked by SBDEV-2217** (v2 Testcontainers Postgres lane cannot boot repo-wide — `outbox_message` Flyway-profile gap + landlord datasource). Enable + verify once SBDEV-2217 lands. |
| AC-4 scope guard | ⬜ follow-up | Recommend a v2 verify-script static check (`UnitloadBusinessService`/`processTransfer` must not reference `recordRelocation`), parity with v1. |

**Deferred / follow-up:** (1) **SBDEV-2217** — fix v2 IT harness, then enable AC-7/8/9 ITs (they encode the rollback + report-exclusion + from!=to contracts; currently unverified in CI). (2) wms2-web-ui `STOCK_RELOCATED` label map (§5.0-#6). (3) AC-4 verify-script. (4) Open question: `triggerReplenishmentMaintenance` inside the now-widened `move()` tx (low risk, out of AC-7 path).
