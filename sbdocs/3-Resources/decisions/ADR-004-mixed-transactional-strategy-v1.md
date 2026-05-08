---
type: decision
status: accepted
date: 2022-01-01
system: wms1
---
# ADR-004: Mixed @Transactional Strategy in v1

## Status
Accepted

## Context
`wms-api` (v1) uses Spring's `@Transactional` annotation inconsistently across its service layer. There are three distinct patterns in production code, documented in `wms1-transaction-boundary-map.md`:

**Pattern A — Class-level `@Transactional` (4 services):**
Every public method participates in a transaction by default. The annotation varies from bare (`@Transactional`) to qualified (`@Transactional(rollbackFor = {BusinessException.class, FacadeException.class})`).

| Service | Annotation |
|---|---|
| `AdviceService` | `@Transactional(rollbackFor = {BusinessException.class, FacadeException.class})` |
| `CustomerorderService` | `@Transactional` (bare) |
| `CustomerorderBatchService` | `@Transactional` (bare, with one method override at `runClubLine`) |
| `BillofladingService` | `@Transactional` (bare) |
| `TransferOrderService` | `@Transactional` (bare) |

**Pattern B — Method-level `@Transactional` (many services):**
No class-level annotation. Each method that requires a transaction is annotated individually. Non-annotated methods in these services run without a transaction boundary. Examples: `PickingorderBusinessService`, `ReplenishorderService`, `StockunitBusinessService`, `UnitloadBusinessService`.

**Pattern C — No `@Transactional` at class or method level (several services):**
These services have no Spring-managed transaction boundary. Reads succeed because OSIV keeps the session open (see ADR-003). Writes succeed only if the caller already has an active transaction (propagation defaults to `REQUIRED`). If called outside a transaction, writes fail silently or throw a JPA exception.

| Service | Notes |
|---|---|
| `MessageService` (most methods) | `createMessage` has no annotation — caller must supply a TX. Only `createMessageInNewTransaction` has `REQUIRES_NEW` for use from afterCommit hooks. |
| `ManageOrderService` | No `@Transactional` found; called from inside caller transactions. |
| `HttpRestService` | External HTTP — no transaction appropriate. |
| `LosSyspropService` | Read-only lookups; no annotation. |

Additionally, `REQUIRES_NEW` appears in two contexts: (1) scheduled-job step isolation and (2) `MessageService.createMessageInNewTransaction` for writing from inside post-commit callbacks. Sequence number generation in `BasicService.getNextSequenceNumber()` has an inline retry loop (up to 100 attempts) using `REQUIRES_NEW` sub-transactions.

## Decision
The mixed strategy is accepted as the current state of v1. No wholesale refactor to a uniform strategy will be attempted. New service methods added to v1 must follow the pattern of the service they are added to.

## Rationale
The mixed strategy emerged organically as v1 grew. It was not planned:

1. **Class-level annotation** was applied to high-throughput transactional services (`CustomerorderBatchService`, `BillofladingService`) where every method manipulates persistent state. It reduces boilerplate but means even utility/query methods open a transaction.
2. **Method-level annotation** was applied where services mix read-only lookups with writes — annotating only the write paths avoids holding a transaction open during pure reads.
3. **No annotation** was applied to services that are always called from within an existing transaction (helper/utility pattern) or to services that perform no DB writes (`HttpRestService`, `LosSyspropService`). OSIV's open session makes reads in these services work without an annotation.
4. **Retrofitting** a uniform strategy (e.g., class-level `@Transactional(readOnly=true)` with write-method overrides) would require auditing every caller to ensure no `@Transactional(propagation=NOT_SUPPORTED)` or `REQUIRES_NEW` context breaks, a high-risk change for a stable production system.

## Consequences

**Active landmines:**

1. **Silent commit on checked exception.** Bare `@Transactional` services (`CustomerorderService`, `BillofladingService`, `TransferOrderService`) do NOT rollback on checked exceptions (`BusinessException`, `FacadeException`) unless those exceptions extend `RuntimeException`. If a domain checked exception propagates out, the transaction **commits** silently even though the operation failed. Any new method on these services that throws a checked exception must add `rollbackFor`.

2. **Silent OMS notification skip.** `OmsNotificationHelper.deferToCommit` checks `isSynchronizationActive()` before registering. A service method with no `@Transactional` (or called from a test context) will silently skip the OMS notification — no exception, no WARN log. WMS and OMS state diverge invisibly.

3. **OSIV dependency.** Pattern C services rely on OSIV for reads. This is invisible in v1 but breaks in v2 where OSIV is disabled (ADR-003). Any Pattern C service ported to v2 must have transaction boundaries added.

4. **Sequence number gaps.** `BasicService.getNextSequenceNumber()` uses `REQUIRES_NEW` sub-transactions. If the outer transaction rolls back, the sequence increment is already committed — gaps in entity numbers are permanent.

5. **Cross-service transaction fan-out.** `CustomerorderBatchService` (class-level `@Transactional`) calls `ReplenishorderService`, `StockunitBusinessService`, `UnitloadService`, and `ManageOrderService` — the widest cross-service fan-out in the codebase. All callees join the batch transaction (REQUIRED propagation), meaning any callee's unchecked exception rolls back the entire batch operation.

## Do NOT revisit unless
- A specific production incident is traced to a missing `rollbackFor` or a missing transaction boundary (not a theoretical risk, but an observed data integrity failure).
- The team migrates v1 service methods to v2, at which point each method must be individually audited for transaction correctness since v2 has OSIV disabled and a dual-transaction-manager setup.
- Spring Boot upgrades in v1 change default `@Transactional` semantics (extremely unlikely for a 2.x → 2.x patch).
