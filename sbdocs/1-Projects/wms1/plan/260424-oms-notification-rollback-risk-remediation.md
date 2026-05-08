---
title: "OMS Notification Rollback Risk — Cross-Service Remediation"
ticket: ""
ticket_url: ""
type: bug
priority: high
status: implemented
project: [wms1]
version: v1
requester: audit-driven
created: 2026-04-24
updated: 2026-04-25
deployed_env: dev
related:
  - 260424-runClubLine-transaction-boundary-hardening
  - 260422-changeReservedAmount-stale-object-state-fix
  - SBDEV-2095-large-bol-close-decoupling-and-perf
tags:
  - plan
  - bug
  - transactions
  - oms-notification
  - outbound
  - inbound
  - shipping
  - stock-update
  - concurrency
---

# OMS Notification Rollback Risk — Cross-Service Remediation

**Project:** v1/wms-api | **Version:** v1 | **Type:** Bug (transaction/OMS-notification correctness — program)
**Priority:** High (no single site is an active incident, but collectively they represent a systemic WMS↔OMS desync class)
**Status:** PLANNING (revision 2 — deep re-validation 2026-04-24)
**Date:** 2026-04-24
**Related:** `260424-runClubLine-transaction-boundary-hardening.md` (handles §3.1 of the source audit; F1-F7 implemented)

**Source audit re-validated against `develop` @ `f46cf06`:**
Original audit §3.2 – §4.4, plus this document's own deep-dive findings beyond the audit.

**Revision 2 changelog (2026-04-24):**
- **NEW SITE CLUSTER S11–S13 (10+ sites)** — `MessageService.sendStockChangeMessage` is invoked from 9 places across `StockunitService`, `UnitloadService`, `GoodsReceiptPositionService`. The audit completely missed `STOCK_UPDATE` egress.
- **NEW SITE S14** — `OrderMonitorViewService.reprintToteLabels` is a sibling of S6 with the same `cupsPrint` rollback gap.
- **Per-site upgrade for S1 (`cancelBatch`)** — recommend reusing `CustomerorderBatchRepository.findByIdForUpdate` (added by runClubLine F6) for concurrent-cancel race defense.
- **Pattern-level addition** — propose a reusable `OmsNotificationHelper.deferToCommit(...)` utility to DRY the afterCommit boilerplate across all sites; pattern proven by `OptimisticLockRetryTemplate`.
- **Outbox upgrade path concretized** — Phase 2a (FAILED-resender) is achievable with one new MessageStatus constant + Flyway migration + scheduled job. Phase 2b (full transactional outbox) sketched as separate plan.
- **S5 dead-code claim confirmed** — verified no `rapidPickingScan*`/`rapidPickingConnect*` references in `wms-web-ui`, `wms-mobile-ui`, or `oms` frontends.
- Rollout order rewritten to integrate the new sites and the helper utility.

**Revision 3 changelog (2026-04-25):**
- **Coordination with SBDEV-2095.** A separate ticket-driven plan ([SBDEV-2095](SBDEV-2095-large-bol-close-decoupling-and-perf.md)) targets the same `BillofladingService.closeBOL` site as **S3** here. To prevent two competing decoupling mechanisms in v1 (`@TransactionalEventListener` vs the helper proposed below), this plan **owns the OMS-decoupling for S3**; SBDEV-2095 narrows to closeBOL-specific concerns (`bolToClose` correctness, Phase 9 N+1 bulk finalize, IN-clause chunking, bulk carrier unlink) and ships **immediately after** rollout item 11.
- **Helper utility extended** — `OmsNotificationHelper.deferToCommit(...)` now accepts an optional `messagePersister` argument that delegates to a new `MessageService.createMessageInNewTransaction(...)` (`@Transactional(REQUIRES_NEW)`). Credit to SBDEV-2095's review for surfacing that the existing in-production `runClubLine:738-755` reference quietly drops `Message` rows when called post-commit (no active tx → `messageRepository.save` no-ops).
- **Rollout** — added item 12 covering Plan B-narrowed (SBDEV-2095) follow-on PR.

---

## 1. Problem Statement

Across **eight services and 18+ call sites**, an **OMS HTTP POST runs inside a Spring-managed transaction** that is not guaranteed to commit. When any code after the POST throws, OMS retains state WMS rolls back — a WMS↔OMS desync that surfaces as "OMS says shipped, WMS says not yet", duplicate OMS events on retry, or partial writes with no signal to operators.

The failure mode has three triggers (all confirmed in `develop`):

1. **Unchecked exceptions after the POST** — NPE, `OptimisticLockException`, `DataIntegrityViolationException`, `orElseThrow(BusinessException)` — roll back the TX but the OMS side has already committed.
2. **`@Transactional(rollbackFor = {BusinessException.class, FacadeException.class})` semantics** — a declared business exception after the POST still rolls back the TX.
3. **`javax.ws.rs.ProcessingException`** — RESTEasy read/connect timeout (15s/5s, configured in `HttpRestService.java:87-88`) is a `RuntimeException`, **not** an `IOException`, and therefore not caught by any of the `ManageOrderService` / `MessageService` / `AdviceService` / `BillofladingService` `catch (IOException)` blocks. It propagates as unchecked and rolls back.

`HttpRestService.post` (`src/main/java/net/aim_ai/wms/service/HttpRestService.java:40-59`) declares `throws IOException` only and **does not** throw on HTTP 4xx/5xx (it returns the status code in the response map). So OMS-side errors are recorded as `SENT` messages with a non-2xx code — no rollback risk — but any post-POST failure still commits OMS and reverts WMS.

This plan is the **sibling** to `260424-runClubLine-transaction-boundary-hardening.md`. That plan owns `CustomerorderBatchService.runClubLine` (audit §3.1) and already shipped F1-F7 as commit `f46cf06`. This plan owns all other sites — those in the original audit (§3.2 – §4.4) PLUS the `STOCK_UPDATE` cluster the audit missed (S11–S13) and the `reprintToteLabels` sibling (S14).

---

## 2. Scope & Severity (validated)

Re-validated line numbers against `develop @ f46cf06`. Original audit's S1-S10 augmented with deep-dive findings S11-S14 below.

### 2.1 Original audit sites (§3.2 – §4.4)

| # | Site | File | POST line | Post-POST work | Severity | Rec. Fix |
|---|---|---|---|---|---|---|
| S1 | `CustomerorderBatchService.cancelBatch` | `service/CustomerorderBatchService.java` | 233 | Full cancel/teardown pipeline (lines 256-322): release reservations, state→CANCELED across orders/positions/picking orders/unitloads, dozens of saves | **HIGH** | afterCommit + F6-style `findByIdForUpdate` (see §2.5) |
| S2 | `CustomerorderService.cancelOrder` | `service/CustomerorderService.java` | 696 | Only `messageService.createMessage` after POST; all state changes are pre-POST | **MEDIUM** (downgrade — see §2.2) | afterCommit (Template 1) |
| S3 | `BillofladingService.closeBOL` | `service/BillofladingService.java` | 584 | "Phase 9 — Batch finalization" (lines 609-620): re-fetch each batch, flip FINISHED, save; commit-time flush of prior 8 phases | **HIGH** | afterCommit (Template 1) |
| S4a | `ReleaseOrderJobService.releaseOrder` — `ORDER_ON_HOLD` branch 1 | `service/job/ReleaseOrderJobService.java` | 189 | Immediate return | **LOW** | leave (or Template 1 for symmetry) |
| S4b | `ReleaseOrderJobService.releaseOrder` — `ORDER_ON_HOLD` branch 2 | same | 441 | Immediate return | **LOW** | leave |
| S4c | `ReleaseOrderJobService.releaseOrder` — `ORDER_BATCH_PICKING_RELEASED` | same | 551 | `LOG.info` + return; commit-time flush of many preceding saves (lines 463-547) | **MEDIUM** | afterCommit (Template 1) |
| S5 | `MobilePickingService.rapidPickingConnectPackageAndType` | `service/mobile/MobilePickingService.java` | 837 | Updates every `PickingorderPosition.picktounitloadId` (840-843), sets `pickingOrder.state = STARTED` (846-847); **no `@Transactional`** | **HIGH (but dead code — confirmed)** | DELETE (see §2.3) |
| S6 | `OrderMonitorViewService.printToteLabels` | `service/OrderMonitorViewService.java` | 184 | None after POST, but **no `@Transactional`** — all prior saves (lines 143-181) are auto-committed | **HIGH — partial-write variant** | Wrap in `@Transactional` + afterCommit (Template 2) |
| S7 | `AdviceService.acceptHubAndSpokeAdvice` | `service/AdviceService.java` | 237 | None — POST is near the end, but class has no `@Transactional`; prior mutations auto-commit | **MEDIUM — partial-write variant** | Class-level `@Transactional(rollbackFor=...)` + afterCommit (Template 2) |
| S8 | `AdviceService.close` | same | 345 | None after POST | **LOW — partial-write variant** | Same as S7 (bundle) |
| S9 | `AdviceService.acceptTransferAdvice` | same | 432 | None after POST | **LOW — partial-write variant** | Same as S7 (bundle) |
| S10 | `PickingorderBusinessService.finishPickingOrder` fallback branch | `service/PickingorderBusinessService.java` | 168 | `unitloadBusinessService.transferUnitLoadToLocation` + saves (lines 192-196) | **MEDIUM — narrow branch** | LOG.error upgrade (see §2.4) |

### 2.2 NEW deep-dive findings (S11–S14)

The audit focused on `manageOrderService.*` and `httpRestService.post` direct calls. It missed two whole egress paths:

#### S11 — `StockunitService.*` STOCK_UPDATE cluster

`StockunitService` has **method-level `@Transactional`** on multiple operator-driven flows; each calls `messageService.sendStockChangeMessage(...)` near the end of the method. `MessageService.sendStockChangeMessage` (`MessageService.java:91-130`) does the same `httpRestService.post` + `createMessage(...)` pattern that `ManageOrderService` does — and inherits the same `IOException`-only catch block. `ProcessingException` propagates and rolls back.

| Sub | Site | POST line | TX scope | Post-POST work | Severity |
|-----|------|-----------|----------|----------------|----------|
| S11a | `StockunitService.transferStock` | 218 (inside `else if` "moved to damaged location" branch) | method `@Transactional` (line 105) | Lines 219-258: continue main loop, `cupsPrint` (255), `triggerReplenishmentMaintenance` (258) | **HIGH** |
| S11b | `StockunitService.setLockOnHold` | 314 | method `@Transactional` (line 261) | LOG.debug + return; commit-flush risk | **MEDIUM** |
| S11c | `StockunitService.setLockDamaged` | 371 | method `@Transactional` (line 320) | LOG.debug + return; commit-flush risk | **MEDIUM** |
| S11d | `StockunitService.adjustAmount` | 412 | method `@Transactional` (line 379) | LOG.debug + return; commit-flush risk | **MEDIUM** |
| S11e | `StockunitService.removeLock` | 468 (then 472 in second branch) | method `@Transactional` (line 448) | Branch terminates after POST; commit-flush risk | **MEDIUM** |

**Process type affected:** `WmsConstants.MessageProcessType.STOCK_UPDATE`. These notifications drive OMS's allocation engine (which OMS uses to size new orders against on-hand stock). A WMS rollback after a STOCK_UPDATE means OMS's available-stock view is stale — symptoms are over-allocation followed by mid-pick "insufficient stock" errors.

#### S12 — `UnitloadService.delete*` cluster

`UnitloadService` has **no `@Transactional`** at class or method level for the delete paths, so individual `unitloadRepository.save(...)`/`stockunitRepository.save(...)` calls auto-commit. `sendStockChangeMessage` fires at the end.

| Sub | Site | POST line | TX scope | Post-POST work | Severity |
|-----|------|-----------|----------|----------------|----------|
| S12a | `UnitloadService.deleteUnitLoadRecursive` | 301 | NONE (auto-commit per repo call) | `if (notifyCRM)` branch returns | **MEDIUM — partial-write variant** |
| S12b | `UnitloadService.deleteUnitLoad` | 335 | NONE | `if (notifyCRM)` branch returns | **MEDIUM — partial-write variant** |

These are partial-write risks, not rollback-after-notify per se. Operator-visible state (deleted unitload/stockunit rows) commits before the OMS POST regardless of POST outcome.

#### S13 — `GoodsReceiptPositionService.*` cluster

`GoodsReceiptPositionService.adjust` (line 64, `@Transactional(rollbackFor = ...)`) and `.delete` (line 102, same annotation) call `sendStockChangeMessage` near the end of their bodies (lines 94 and 174). Same shape as S11 — rollback-after-notify on commit-flush of preceding saves.

| Sub | Site | POST line | TX scope | Post-POST work | Severity |
|-----|------|-----------|----------|----------------|----------|
| S13a | `GoodsReceiptPositionService.adjust` | 94 | method `@Transactional(rollbackFor)` (line 63) | Loop continues with subsequent positions | **MEDIUM** |
| S13b | `GoodsReceiptPositionService.delete` | 174 | method `@Transactional(rollbackFor)` (line 101) | Method end; commit-flush risk | **MEDIUM** |

#### S14 — `OrderMonitorViewService.reprintToteLabels` — S6 sibling

`OrderMonitorViewService.reprintToteLabels` at line 326 is essentially the same shape as S6's `printToteLabels` but skipped by the audit. No `@Transactional`. `mywmsUserRepository.save(operator)` at line 333 auto-commits the printer preference; the only later side effect is `printService.cupsPrint` at line 352 (no OMS POST). Mild partial-write inconsistency: if cupsPrint fails after the printer preference saves, the user has a "default printer" they never confirmed.

**Severity: LOW — partial-write of operator-preference only.** Worth wrapping in `@Transactional` for consistency, but lower priority than the OMS-notification sites.

### 2.3 Sites the audit flagged as safe — re-validation confirms

- `PickingorderBusinessService.confirmPick:344-350` — already afterCommit ✅
- `PickingorderBusinessService.finishPickingOrder:150-164` (primary branch) — already afterCommit ✅
- `MobilePickingService.processPick:438-450` — already afterCommit ✅
- `MessageService.resendMessage:132-167` — admin-only replay; no TX envelope; **safe ✅** (and now also the basis for the Phase 2a auto-resender — see §3.9)
- `StockSummaryExportJob.java:106` — periodic stock export POST; scheduled job, no containing TX; safe ✅
- `ItemDataController.java:102` — admin SKU push to OMS; controller-level (no `@Transactional`); partial-write risk only; not in this plan's scope (admin tooling)
- `AdminActionController.java:127` — read-only `GET`; safe ✅
- `MessageDummyController.java:42` — developer-only; safe ✅
- `BillofladingService.getFacilities:1169` — read-only `GET`; safe ✅
- `BillofladingService:792` — commented-out POST; dead code (could be deleted for hygiene)

### 2.4 S2 (`cancelOrder`) severity downgrade — unchanged from rev 1

The audit rates this HIGH but self-describes post-POST work as "just `messageService.createMessage` and the `IOException` catch variant. No material state changes after the POST". Re-validated: line 696 is the POST, lines 698-723 are the Message-row bookkeeping only.

**Conclusion:** **MEDIUM**, not HIGH. The full cancellation pipeline already ran and saved before the POST; the only rollback trigger is a Message-insert failure, which is rare. Still worth moving to afterCommit for consistency; not a pre-release blocker.

### 2.5 S5 dead-code — confirmed across all frontends

Original claim: `rapidPickingConnectPackageAndType` / `rapidPickingScanPackageAndType` are dead because the only controller invocation at `controller/mobile/PickingController.java:90` is commented out.

Re-validation: `grep -rln "rapidPickingScan\|rapidPickingConnect" wms-web-ui wms-mobile-ui oms` returns **zero matches**. The sibling frontend repos have no API client code calling either. **Dead-code claim verified.** Safe to delete the methods + associated unit tests.

### 2.6 S10 (`finishPickingOrder` fallback) — unchanged from rev 1

`PickingorderBusinessService.finishPickingOrder` lines 150-164 already use `afterCommit` under the primary branch; the synchronous fallback at line 168 fires **only** when `TransactionSynchronizationManager.isSynchronizationActive()` returns false. All three callers (`finishPicking` in `MobilePickingService:189`, `266`, `318`) are themselves `@Transactional`, so the fallback should never fire in production.

**Recommended action:** change the fallback from silent synchronous fallback to a loud `LOG.error` + still-synchronous call (preserve current semantics), so we detect any caller-graph change. No afterCommit needed on this branch because the "no active TX" case has no rollback to worry about.

### 2.7 S1 (`cancelBatch`) concurrent-cancel race (NEW analysis post-runClubLine F6)

`cancelBatch` at line 182 receives a `CustomerorderBatch` parameter passed from a controller layer (caller-graph: presumably `CustomerOrderBatchController` though the direct grep didn't surface it — likely Spring Data REST exposes it indirectly via `@RepositoryRestResource`). Like `runClubLine` pre-F6, it opens with **no pessimistic lock**. Two operators racing to cancel the same batch will both pass the state guard and both try to mutate the same orders/positions/unitloads. The optimistic-lock failure on the second commit triggers `ObjectOptimisticLockingFailureException` which **is not** wrapped by `OptimisticLockRetryTemplate` here (cancelBatch has no controller-level retry that we can find), so the second user just gets a 500.

**Recommendation:** apply the same F6 pattern — `customerorderBatchRepository.findByIdForUpdate(orderBatch.getId())` at the entry of `cancelBatch`, re-check state under the lock. The repo method is already added by the runClubLine plan; no new infrastructure needed. This makes cancelBatch symmetric with runClubLine.

---

## 3. Design / Proposed Fix

All fixes follow **one of three templates**. Pick the heaviest template that applies.

### Template 1 — `afterCommit` inside an existing `@Transactional` method

For sites S1, S2, S3, S4c, S11a-e, S13a-b. The method is already `@Transactional`; move the HTTP POST into a deferred callback.

Reference implementations (currently in production):
- `PickingorderBusinessService.finishPickingOrder:150-169` (with isSynchronizationActive guard)
- `CustomerorderBatchService.runClubLine:738-755` (post-F1, with three sequential POSTs)

Canonical form:

```java
final List<Customerorder> snapshot = new ArrayList<>(customerOrderList);  // or whatever payload
final String idForLog = entity.getId();
if (TransactionSynchronizationManager.isSynchronizationActive()) {
    TransactionSynchronizationManager.registerSynchronization(new TransactionSynchronizationAdapter() {
        @Override
        public void afterCommit() {
            try {
                manageOrderService.<omsMethod>(snapshot);
            } catch (Exception e) {
                LOG.error("OMS <omsMethod> callback failed for <entity-id> " + idForLog, e);
            }
        }
    });
} else {
    LOG.warn("<method>: no transaction synchronization active — falling back to synchronous OMS call");
    manageOrderService.<omsMethod>(snapshot);
}
```

Key properties:
- Callback fires only on commit; rollback silently drops the registration.
- `catch (Exception)` catches `ProcessingException` — the whole point.
- Captured args must be effectively final; snapshot lists with `new ArrayList<>(...)` before registration so mutation after commit doesn't affect the POST payload.
- The sync fallback is instrumentation — it logs at WARN so a caller-graph change shows up in monitoring.

### Template 2 — Add a `@Transactional` envelope + afterCommit

For sites S6, S7, S8, S9, S12a-b, S14. The method currently has no transaction boundary, so pre-POST writes auto-commit; the fix is two-part:
1. Add `@Transactional(rollbackFor = {BusinessException.class, FacadeException.class})` to the method (or class-level on `AdviceService`).
2. Then apply Template 1 to move the POST to `afterCommit`.

### Template 3 (NEW) — Reusable `OmsNotificationHelper.deferToCommit(...)` utility

The afterCommit boilerplate above is repeated **18+ times** across this plan. DRY it into a single utility, mirroring the pattern of `OptimisticLockRetryTemplate`.

#### 3.0.a — `MessageService.createMessageInNewTransaction(...)` (prerequisite, added by SBDEV-2095 review)

Before the helper can persist `Message` audit rows from inside an `afterCommit` callback, `MessageService` needs a `REQUIRES_NEW` variant. The current `createServiceLog(...)` (`MessageService.java:57-89`) calls `messageRepository.save(...)` which silently no-ops when there is no active transaction — exactly the situation inside an `afterCommit` callback. The existing in-production `runClubLine:738-755` reference is quietly losing some of these rows; this prerequisite closes that gap and unblocks Template 3.

Add to `service/MessageService.java`:

```java
@Transactional(propagation = Propagation.REQUIRES_NEW)
public Message createMessageInNewTransaction(String sender, String receiver, String message,
                                             String process, String destination, String status,
                                             String stateCode, String answer) throws BusinessException {
    return createServiceLog(sender, receiver, message, process, destination, status, stateCode, answer);
}
```

Existing callers of `createServiceLog` / `createMessage` are unchanged; only the helper (and any future post-commit caller) uses the REQUIRES_NEW variant.

#### 3.0.b — The helper itself

```java
// service/util/OmsNotificationHelper.java — NEW
public final class OmsNotificationHelper {
    private static final Logger LOG = LoggerFactory.getLogger(OmsNotificationHelper.class);

    private OmsNotificationHelper() { /* utility */ }

    @FunctionalInterface
    public interface OmsCall {
        void execute() throws Exception;
    }

    @FunctionalInterface
    public interface MessagePersister {
        // Called once after the OmsCall finishes (success path) or after it throws (failure path).
        // Implementations MUST use MessageService.createMessageInNewTransaction(...) so the audit
        // row commits even though the publishing transaction is already closed.
        void persist(boolean succeeded, String statusCode, String answer);
    }

    /**
     * Defer an OMS notification to TX afterCommit if a synchronization is active;
     * otherwise log WARN and execute synchronously. Catches Exception inside the
     * afterCommit callback so a single OMS failure cannot affect the already-committed
     * transaction or block subsequent registered callbacks.
     *
     * Reference: PickingorderBusinessService.finishPickingOrder:150-169 (in production).
     *
     * @param siteName        used in the WARN/ERROR log line for site attribution
     * @param entityIdForLog  identifier in the log line ("batch BATCH-001", "BOL #42", etc.)
     * @param call            the OMS notification to perform on commit
     * @param persister       optional Message-row persister (REQUIRES_NEW); pass null when the call
     *                        already records its own Message row
     */
    public static void deferToCommit(String siteName, String entityIdForLog,
                                     OmsCall call, MessagePersister persister) {
        if (TransactionSynchronizationManager.isSynchronizationActive()) {
            TransactionSynchronizationManager.registerSynchronization(new TransactionSynchronizationAdapter() {
                @Override
                public void afterCommit() {
                    invoke(siteName, entityIdForLog, call, persister, /*async*/ true);
                }
            });
        } else {
            LOG.warn("OMS notification " + siteName + " has no active TX synchronization for "
                + entityIdForLog + " — falling back to synchronous call");
            invoke(siteName, entityIdForLog, call, persister, /*async*/ false);
        }
    }

    /** Two-arg overload for sites that record their own Message row inside the OmsCall. */
    public static void deferToCommit(String siteName, String entityIdForLog, OmsCall call) {
        deferToCommit(siteName, entityIdForLog, call, null);
    }

    private static void invoke(String siteName, String entityIdForLog,
                               OmsCall call, MessagePersister persister, boolean async) {
        try {
            call.execute();
            if (persister != null) persister.persist(true, "200", null);
        } catch (Exception e) {
            LOG.error("OMS notification " + siteName + " callback failed for " + entityIdForLog, e);
            if (persister != null) {
                try { persister.persist(false, "503", null); }
                catch (Exception nested) {
                    LOG.error("Failed to persist FAILED Message audit row for " + siteName + " " +
                              entityIdForLog + " — manual reconciliation required", nested);
                }
            }
            if (!async) {
                throw e instanceof RuntimeException ? (RuntimeException) e : new RuntimeException(e);
            }
        }
    }
}
```

Each per-site fix becomes one of two shapes.

Two-arg form (call records its own Message row internally):

```java
final List<Customerorder> snapshot = new ArrayList<>(orders);
OmsNotificationHelper.deferToCommit("cancelBatch", "batch " + orderBatch.getBatchid(),
    () -> manageOrderService.customerOrderBatchCancelled(snapshot));
```

Four-arg form (caller wants helper-driven Message-row audit):

```java
final String payload = mapper.writeValueAsString(dto);
OmsNotificationHelper.deferToCommit(
    "closeBOL", "BOL " + bolId,
    () -> {
        Map<String,String> resp = httpRestService.post(urlPath, payload);
        // Message row written by persister below — keeps audit independent of POST exceptions.
    },
    (succeeded, code, answer) -> messageService.createMessageInNewTransaction(
        wmsInstanceName, omsInstanceName, payload,
        WmsConstants.MessageProcessType.ORDER_BATCH_SHIPPED, urlPath,
        succeeded ? WmsConstants.MessageStatus.SENT : WmsConstants.MessageStatus.FAILED,
        code, answer));
```

The four-arg form is what S3 (`closeBOL`) uses, replacing what SBDEV-2095 originally proposed as a standalone `BolClosedEvent` + `BolClosedEventListener`. Other sites that already have inline `messageService.createMessage(...)` calls inside their existing closures keep using the two-arg form — but should be migrated to the four-arg form (with `createMessageInNewTransaction`) over time, since today's pattern is the silent no-op described in §3.0.a.

**Why this matters:**
- Single point of behavior change — if Spring 5 deprecates `TransactionSynchronizationAdapter` (which it has in favor of `TransactionSynchronization` interface defaults), one file changes.
- Centralized observability hook — adding a Prometheus counter or structured log later only touches one method.
- Lower review burden per per-site PR — diff shows intent (defer this OMS call) instead of TX-machinery boilerplate.
- Easier for new contributors to copy the pattern correctly.
- The four-arg form fixes a latent silent-loss bug in the existing in-production sites once they're migrated.

### Per-site design detail

#### 3.1 S1 — `CustomerorderBatchService.cancelBatch` (HIGH, Template 1 + F6)

Two changes:

**(a) F6-style pessimistic batch lock** — first line of the method:

```java
public void cancelBatch(CustomerorderBatch staleBatch, Principal principal) throws BusinessException, FacadeException {
    // Acquire row-level lock to serialize concurrent cancels (mirrors runClubLine F6).
    CustomerorderBatch orderBatch = customerorderBatchRepository.findByIdForUpdate(staleBatch.getId())
        .orElseThrow(() -> new BusinessException("Order batch not found: " + staleBatch.getId()));
    LOG.debug("start for batch=" + orderBatch + " (row-locked)");

    // Re-check state under lock.
    if (orderBatch.getState() >= WmsConstants.State.FINISHED) {
        throw new BusinessException("Order batch is beyond status started. can not be cancelled anymore");
    }
    // ... rest of method unchanged ...
}
```

This eliminates the same race that runClubLine F6 closed. The repo method `findByIdForUpdate` was added by `260424-runClubLine-transaction-boundary-hardening.md` commit `f46cf06` — already in `develop`.

**(b) Move POST at line 233 to afterCommit** using `OmsNotificationHelper.deferToCommit(...)`. Register **after** line 322 (after all cancel/teardown work is queued in the TX).

**Sub-design — Message row stays inside the callback:** match the reference `finishPickingOrder` pattern. If TX rolls back, neither POST nor Message row write fires — correct outcome.

**Files changed:** `service/CustomerorderBatchService.java`, `service/util/OmsNotificationHelper.java` (new)

#### 3.2 S2 — `CustomerorderService.cancelOrder` (MEDIUM, Template 1)

Apply `OmsNotificationHelper.deferToCommit` at line 696. All state mutations are pre-POST; the only reason to defer is to cover the rare commit-time failure of the Message-insert or the pre-POST `customerorderRepository.save(customerOrder)` at line 651.

**Files changed:** `service/CustomerorderService.java`

#### 3.3 S3 — `BillofladingService.closeBOL` (HIGH, Template 1) — coordinated with SBDEV-2095

> **Coordination note:** This site is also the subject of **[SBDEV-2095](SBDEV-2095-large-bol-close-decoupling-and-perf.md)**. To avoid two competing decoupling mechanisms in v1, **this plan owns the OMS-decoupling for S3 using the helper from §3 Template 3**. SBDEV-2095 ships immediately after rollout item 11 (see §5) and delivers the closeBOL-specific items the helper does not address: the `bolToClose` `List<Long>` correctness fix, Phase 9 N+1 → bulk `finalizeBatchesByIds(...)` with NOT EXISTS, IN-clause chunking across Phase 5/6, and the per-pallet `save()` carrier-unlink in `UnitloadBusinessService.transferPalletTreesToLocation`.

Apply `OmsNotificationHelper.deferToCommit` at line 584 using the **four-arg form** (call + Message persister) — the existing inline `messageService.createMessage(...)` block at lines 586-606 currently runs inside the same transaction; once moved to afterCommit it must use `createMessageInNewTransaction(...)` per §3.0.a, which the helper's persister does for free.

```java
final BillOfLadingWebServiceDto dto = ...;                  // built in Phase 8 as today
final String payload = mapper.writeValueAsString(dto);
final String urlPath = losSyspropRepository.findSysvalueBySyskey(
    WmsConstants.SYSTEM_PROPERTY_WEBSERVICE_ORDER_BATCH_SHIPPED_URL_KEY);
final String wmsName = losSyspropService.getWmsInstanceName();
final String omsName = losSyspropService.getOmsInstanceName();

OmsNotificationHelper.deferToCommit(
    "closeBOL", "BOL " + billOfLading.getId(),
    () -> httpRestService.post(urlPath, payload),
    (succeeded, code, answer) -> messageService.createMessageInNewTransaction(
        wmsName, omsName, payload,
        WmsConstants.MessageProcessType.ORDER_BATCH_SHIPPED, urlPath,
        succeeded ? WmsConstants.MessageStatus.SENT : WmsConstants.MessageStatus.FAILED,
        code, answer));
```

Phase 9 batch-finalization at lines 609-620 stays inside the TX (and is later replaced by SBDEV-2095's bulk `finalizeBatchesByIds`). Most material of the HIGH sites because `closeBOL` triggers downstream shipment notices on the OMS side that cannot be undone by operators. **Note:** `BillofladingService` already uses `findByIdForUpdate` at entry (line 262), so no F6-style lock addition needed.

**Files changed:** `service/BillofladingService.java`

#### 3.4 S4c — `ReleaseOrderJobService.releaseOrder` line 551 (MEDIUM, Template 1)

`REQUIRES_NEW` TX per order; the POST at line 551 is the final statement, but the many preceding saves can fail at commit-time flush. Apply `OmsNotificationHelper.deferToCommit`. S4a (line 189) and S4b (line 441) are LOW and can be left alone, OR migrated for consistency at marginal cost. **Recommendation: migrate all three for consistency** — the cost is one helper call each.

**Files changed:** `service/job/ReleaseOrderJobService.java`

#### 3.5 S5 — delete the dead `rapidPicking*` pair

Remove `MobilePickingService.rapidPickingConnectPackageAndType` (line 780) and its sole caller `rapidPickingScanPackageAndType` (line 853). Update unit tests (`MobilePickingServiceUnitTest`) — delete the tests. Frontend re-validation confirmed no UI caller.

Optional cleanup: delete `controller/mobile/PickingController.java:80-110` (the already-commented-out `processRapidPickScanPackageType` endpoint) for clean history.

**Files changed:** `service/mobile/MobilePickingService.java`, `test/.../MobilePickingServiceUnitTest.java`, optionally `controller/mobile/PickingController.java`

#### 3.6 S6 — `OrderMonitorViewService.printToteLabels` (HIGH, Template 2)

Wrap `printToteLabels` in `@Transactional(rollbackFor = {BusinessException.class, FacadeException.class})`. Then defer **both** `printService.cupsPrint` and `manageOrderService.customerOrderToteAssigned` to `afterCommit` via `OmsNotificationHelper.deferToCommit`:

```java
final byte[] labelBytes = outputStream.toByteArray();
final List<Customerorder> snapshot = new ArrayList<>(customerOrderList);
final String printerAddress = printer.getAddress();
OmsNotificationHelper.deferToCommit("printToteLabels", "printer " + printerAddress, () -> {
    try { printService.cupsPrint(printerAddress, labelBytes); }
    catch (Exception e) { LOG.error("CUPS print failed for printer=" + printerAddress, e); }
    manageOrderService.customerOrderToteAssigned(snapshot);
});
```

If DB rolls back, neither print nor OMS notification fires — intended semantics.

**Files changed:** `service/OrderMonitorViewService.java`

#### 3.7 S7/S8/S9 — `AdviceService` trio (Template 2, bundled)

Annotate the class:

```java
@Service
@Transactional(rollbackFor = {BusinessException.class, FacadeException.class})
public class AdviceService { ... }
```

Then apply `OmsNotificationHelper.deferToCommit` to each POST at lines 237, 345, 432.

**Caller audit:** `AdviceRestController` (unauthenticated REST) is the primary caller; expects atomic semantics. Confirmed no other callers — the partial-write behavior was an accident of forgetting `@Transactional`, not a deliberate contract.

**Files changed:** `service/AdviceService.java`

#### 3.8 S10 — `PickingorderBusinessService.finishPickingOrder` fallback (MEDIUM, minimal change)

Replace silent fallback at line 165-169 with a loud `LOG.error`:

```java
} else {
    // Indicates a caller-graph change — all known callers are @Transactional and should
    // register a sync manager. Keep synchronous behavior but alert so monitoring catches it.
    LOG.error("finishPickingOrder invoked with no active TX synchronization — "
            + "OMS customerOrderPicked will fire synchronously for order " + customerOrder.getNumber());
    manageOrderService.customerOrderPicked(new ArrayList<>(Collections.singletonList(customerOrder)));
}
```

No afterCommit needed: if there's no TX, there's no rollback to race. Diagnostic-only change.

**Files changed:** `service/PickingorderBusinessService.java`

#### 3.9 S11 — `StockunitService` STOCK_UPDATE cluster (NEW, Template 1 ×5)

Apply `OmsNotificationHelper.deferToCommit` at:
- S11a: line 218 (`transferStock`, "moved to damaged" branch)
- S11b: line 314 (`setLockOnHold`)
- S11c: line 371 (`setLockDamaged`)
- S11d: line 412 (`adjustAmount`)
- S11e: lines 468 and 472 (`removeLock`, both branches)

All are method-level `@Transactional` — Template 1 applies cleanly. Each site is one helper call. Snapshot the `List<StockChangeDto>` before registration.

**Files changed:** `service/StockunitService.java`

#### 3.10 S12 — `UnitloadService.delete*` cluster (NEW, Template 2)

`UnitloadService` has no class-level `@Transactional`. The two delete methods (`deleteUnitLoad` at line 308, `deleteUnitLoadRecursive` at line 274) need `@Transactional(rollbackFor = ...)` first, then helper deferral of the POST.

**Caller audit pre-required:** `UnitloadService.delete*` is invoked from controllers (admin actions) and possibly batch jobs. Adding a TX envelope changes semantics — partial-write callers won't see intermediate state. Verify no caller relies on partial-write before merging.

**Files changed:** `service/UnitloadService.java`

#### 3.11 S13 — `GoodsReceiptPositionService` cluster (NEW, Template 1 ×2)

Apply `OmsNotificationHelper.deferToCommit` at:
- S13a: line 94 (`adjust`, in the per-position loop)
- S13b: line 174 (`delete`, near method end)

Both methods already `@Transactional(rollbackFor = ...)`. **Note for S13a**: the helper is called inside a `for` loop. Each iteration registers its own afterCommit callback. After commit, all callbacks fire in registration order — that's fine for an idempotent OMS interface, less so if order or batching matters. **Recommendation:** accumulate the `List<StockChangeDto>` across loop iterations and register **one** afterCommit callback at the end of the loop.

**Files changed:** `service/GoodsReceiptPositionService.java`

#### 3.12 S14 — `OrderMonitorViewService.reprintToteLabels` (LOW, Template 2)

Wrap in `@Transactional(rollbackFor = ...)`; move `printService.cupsPrint` at line 352 to afterCommit via the helper. Less material than S6 because there's no OMS POST here, but worth doing for consistency: if `mywmsUserRepository.save(operator)` at line 333 rolls back, the print should not fire (it would print labels for a state the user never confirmed).

**Files changed:** `service/OrderMonitorViewService.java`

---

### Affected Locations

| # | File | Line | Description |
|---|------|------|-------------|
| 1 | `service/CustomerorderBatchService.java` | 182, 233 | S1: F6 batch lock at entry; afterCommit at POST |
| 2 | `service/CustomerorderService.java` | 696 | S2: afterCommit at POST |
| 3 | `service/BillofladingService.java` | 584 | S3: afterCommit at POST |
| 4 | `service/job/ReleaseOrderJobService.java` | 189, 441, 551 | S4a/b/c: afterCommit (all three) |
| 5 | `service/mobile/MobilePickingService.java` | 780-870 | S5: DELETE methods + tests |
| 6 | `service/OrderMonitorViewService.java` | 89-187 | S6: `@Transactional` + afterCommit (cupsPrint + OMS POST) |
| 7 | `service/AdviceService.java` | 33 (class), 237, 345, 432 | S7-S9: class-level `@Transactional`; afterCommit on each POST |
| 8 | `service/PickingorderBusinessService.java` | 165-169 | S10: silent fallback → LOG.error |
| 9 | `service/StockunitService.java` | 218, 314, 371, 412, 468, 472 | S11: afterCommit at 6 POST sites |
| 10 | `service/UnitloadService.java` | 274, 308 (class header), 301, 335 | S12: `@Transactional` on delete methods; afterCommit at POSTs |
| 11 | `service/GoodsReceiptPositionService.java` | 94, 174 | S13: afterCommit (with loop-accumulator pattern for S13a) |
| 12 | `service/OrderMonitorViewService.java` | 326, 352 | S14: `@Transactional` + afterCommit |
| 13 | `service/util/OmsNotificationHelper.java` | NEW | Template 3: reusable deferToCommit utility |

---

## 4. V1/V2 Applicability

V1-only plan. `wms2-api` has its own evolution of these services; a sibling v2 plan should follow after the v1 changes ship, using the `wms-v2-migrate` skill to port site-by-site. The `OmsNotificationHelper` utility is the most port-relevant artifact — drop it into `wms2-api/service/util/` first.

---

## 5. Rollout Order

Re-stratified to introduce the helper first, then small/independent sites, then the high-risk structural changes:

1. **Helper utility (Template 3)** — add `OmsNotificationHelper` + a unit test (`deferToCommit_activeTx_registers`, `deferToCommit_noTx_executesSyncWithWarn`, `deferToCommit_callbackThrows_loggedAndSwallowed`). Pure addition; unblocks all subsequent PRs.
2. **S10** — single-line LOG.error upgrade. Lowest risk, one commit.
3. **S5 (delete)** — removes dead code. Frontend caller-audit complete.
4. **S4a/b/c bundle** — three afterCommit insertions in one job-service file.
5. **S11 cluster** — six `StockunitService` sites in one PR. Methods are independent operator-driven flows; same shape; review-friendly.
6. **S13 cluster** — `GoodsReceiptPositionService.adjust` (with loop-accumulator) + `.delete`.
7. **S2** — `cancelOrder` afterCommit.
8. **S7/S8/S9 bundle** — `AdviceService` trio with class-level annotation. Concurrency review required (callers must tolerate atomic semantics).
9. **S6 + S14** — `OrderMonitorViewService` print sites. Print behavior change is operator-visible; coordinate with ops.
10. **S12** — `UnitloadService.delete*`. Caller-audit required — adding `@Transactional` changes semantics.
11. **S1 + S3 together** — HIGH-severity, high-blast-radius cancel and BOL close. Single PR for symmetry. S1 also adds the F6 batch lock.
12. **SBDEV-2095 follow-on** — after item 11 lands and S3's afterCommit decoupling is verified in production, ship the closeBOL-specific work from [SBDEV-2095](SBDEV-2095-large-bol-close-decoupling-and-perf.md) in a small PR: (a) `bolToClose` correctness — `ConcurrentHashMap.newKeySet()` + try/finally drain + drop the inverted `contains/remove` branch; (b) Phase 9 → bulk `CustomerorderBatchRepository.finalizeBatchesByIds(...)` with NOT EXISTS guard; (c) IN-clause chunking helper applied to all Phase 5/6 bulk updates; (d) `UnitloadRepository.clearCarrierUnitloadByIds(...)` replacing the per-pallet `save()` loop in `UnitloadBusinessService.transferPalletTreesToLocation:316-320`.

**Parallel:** runClubLine F4 and F8 (deferred per that plan) can ship independently. Do not block on this plan.

---

## 6. Testing

### 6.1 Helper utility tests (NEW)

`OmsNotificationHelperTest` — pure unit tests, no Spring context:
- `deferToCommit_activeTx_registersSync_andFiresOnAfterCommit`
- `deferToCommit_noActiveTx_executesSyncImmediately_andLogsWarn`
- `deferToCommit_callbackThrows_inAfterCommit_isLoggedAndSwallowed`
- `deferToCommit_callbackThrows_inSyncFallback_propagatesToCaller`

Use `TransactionSynchronizationManager.initSynchronization()` / `clear()` per test.

### 6.2 Per-site tests

Each per-site PR adds two tests (happy-path-deferred, rollback-no-call) using the pattern from `runClubLine_omsCallsDeferredUntilAfterCommit` in `CustomerorderBatchServiceUnitTest`:

- **S1 `CustomerorderBatchServiceUnitTest`:**
  - `cancelBatch_acquiresBatchLockAtEntry`
  - `cancelBatch_omsCallDeferredUntilAfterCommit`
  - `cancelBatch_rollbackInTeardown_doesNotFireOms`
- **S2 `CustomerorderServiceUnitTest`:**
  - `cancelOrder_omsCallDeferredUntilAfterCommit`
  - `cancelOrder_rollback_noOmsCall`
- **S3 `BillofladingServiceUnitTest`:**
  - `closeBOL_omsCallDeferredUntilAfterCommit`
  - `closeBOL_phase9Rollback_noOmsCall`
- **S4 `ReleaseOrderJobServiceUnitTest`:**
  - `releaseOrder_omsHoldDeferred_branch1` / `_branch2`
  - `releaseOrder_omsReleaseDeferred`
  - `releaseOrder_rollback_noOmsCall`
- **S6 `OrderMonitorViewServiceUnitTest`:**
  - `printToteLabels_printAndOmsAfterCommit`
  - `printToteLabels_rollback_noPrintNoOms`
- **S7/S8/S9 `AdviceServiceUnitTest`:**
  - `acceptHubAndSpokeAdvice_rollback_noOmsCall`
  - `close_rollback_noOmsCall`
  - `acceptTransferAdvice_rollback_noOmsCall`
- **S10 `PickingorderBusinessServiceUnitTest`:**
  - `finishPickingOrder_noActiveTx_logsErrorAndStillCalls` (logger ArgumentCaptor)
- **S11 `StockunitServiceUnitTest`:**
  - 5 × `<method>_omsCallDeferredUntilAfterCommit` (per S11a-e)
  - 5 × `<method>_rollback_noOmsCall`
- **S12 `UnitloadServiceUnitTest`:**
  - `deleteUnitLoad_omsCallDeferredUntilAfterCommit`
  - `deleteUnitLoadRecursive_omsCallDeferredUntilAfterCommit`
  - 2 × rollback variants
- **S13 `GoodsReceiptPositionServiceUnitTest`:**
  - `adjust_loopAccumulator_singleAfterCommit` (verifies one callback per call, not per loop iteration)
  - `delete_omsCallDeferredUntilAfterCommit`
  - 2 × rollback variants
- **S14 `OrderMonitorViewServiceUnitTest`:**
  - `reprintToteLabels_cupsPrintDeferred_doesNotFireOnRollback`

### 6.3 Pattern integration test

Add `OmsNotificationProgramIT` (Testcontainers): exercise one site per template (S1 for Template 1, S6 for Template 2, S14 for Template 2 print-only) end-to-end with a real `@Transactional` boundary, mocked OMS via WireMock. Inject:
- A successful POST → verify Message row + entity state.
- A `ProcessingException` from WireMock 30s delay → verify TX commits, FAILED row written by S1's `messageService.createMessage` (or skipped, depending on design), nothing rolls back.
- A `BusinessException` thrown after the helper registers → verify TX rolls back, no POST traffic.

### 6.4 Regression

Run all touched service unit tests in CI. Confirm pre-existing baseline (3 unrelated failures from runClubLine plan §10) is unchanged.

---

## 7. Production-incident recovery checklist

```sql
-- For any WMS entity (batch, order, advice, BOL, stockunit) suspected of WMS↔OMS desync:
SELECT id, process, status, statuscodeanswer, created
FROM   message
WHERE  message LIKE '%<entity-number>%'
ORDER  BY created DESC
LIMIT  20;

-- For the new STOCK_UPDATE cluster, the message body contains the SKU not the entity:
SELECT id, process, status, statuscodeanswer, created, message
FROM   message
WHERE  process = 'STOCK_UPDATE'
   AND created >= now() - interval '1 hour'
ORDER  BY created DESC
LIMIT  50;
```

Interpret `status = 'SENT'` rows against the current WMS entity state:
- WMS state ≥ the state the OMS message implies → normal.
- WMS state < the state the OMS message implies → **rollback-after-notify occurred**. Do NOT retry the UI action. Reconcile manually with OMS.

After Phase 1 (this plan) ships, this combination should be impossible for non-crash failure. After Phase 2a (auto-resender, §3.13 below) ships, FAILED rows auto-resend.

---

## 8. Phase 2 — durable OMS delivery (the "once-for-all" upgrade)

The afterCommit fix closes the rollback-after-notify class but leaves two windows:
- **R1: OMS outage** — `FAILED` Message row, no auto-redelivery.
- **R2: JVM crash between commit and afterCommit invocation** — no Message row at all, silent loss.

Two phased upgrades close both:

### 3.13 Phase 2a — Scheduled FAILED-resender (closes R1)

Achievable with minimal changes (vs. rev 1's higher estimate):
- **Schema:** one Flyway migration adding `message.retries INTEGER DEFAULT 0` + index `(status, created)`.
- **Constants:** add `WmsConstants.MessageStatus.DLQ = "DLQ"` for terminal-after-N-retries.
- **Service:** new `MessageRetryJobService` that polls `message WHERE status='FAILED' AND retries<5 ORDER BY created LIMIT 100` every 60s and invokes existing `MessageService.resendMessage(...)` (already implemented at line 132).
- **Schedule:** new `MessageRetryJob` in `schedulejob/` using the existing `SchedulingConfigurer` pattern (cron from DB sysprop).

Estimated effort: 1-2 days. Cost: one migration, one new constant, one new job. **Recommend bundling with Phase 1 if possible**; otherwise ship as separate PR after Phase 1 verifies stable.

### 3.14 Phase 2b — Transactional outbox (closes R2)

Full structural fix. Scope as separate plan (`oms-notification-transactional-outbox.md`):
1. New schema field `message.idempotency_key` and `message.lifecycle ∈ {PENDING, IN_FLIGHT, SENT, FAILED, DLQ}`.
2. **All sites in this plan** stop calling `httpRestService.post` directly; instead enqueue a `PENDING` row via a new `OmsOutboxService.enqueue(process, payload, idempotencyKey, urlPath)`.
3. Inside the runClubLine and other transactional methods, the `enqueue` call replaces `manageOrderService.<oms-method>(snapshot)` in the afterCommit block — actually it can move BACK INTO the TX since it's now just a DB insert, eliminating the afterCommit callback entirely.
4. New `OmsOutboxDelivererJob` polls `PENDING` rows older than 5s, advances to `IN_FLIGHT`, POSTs, advances to `SENT` or back to `FAILED`.
5. OMS-side idempotency required — coordinate with OMS team.

Estimated effort: 1-2 weeks. **Recommend deferring to a separate plan** with explicit OMS-team sign-off on idempotency support.

---

## 9. Open questions

- **Phase 2a vs Phase 1 bundling:** if shipping Phase 2a soon after Phase 1, consider whether to bundle (one migration + one PR) or stage. Recommendation: bundle Phase 2a with the S1+S3 final PR (item 11 in the rollout) since Ops will most need auto-resend for those two HIGH sites.
- **`afterCommit` failure observability:** current design logs `ERROR` on callback failure; no metrics. Recommend Prometheus counter `oms_notification_aftercommit_failures_total{site}` once the WMS team has a sink. Out of scope for this plan, but `OmsNotificationHelper` is the single place to wire it.
- **S12 caller audit:** before adding `@Transactional` to `UnitloadService.delete*`, confirm no caller (admin tooling, batch jobs, REST proxies) depends on the auto-commit-per-save behavior. Most likely safe; verify.
- **S13a loop-accumulator semantics:** if `GoodsReceiptPositionService.adjust` processes a list of positions and one position throws in the middle, the accumulator should still send the partial list of successful changes — confirm with ops whether this is desired or whether all-or-nothing is preferred.
- **OMS-side idempotency for Phase 2b:** does OMS dedupe by idempotency key today? If not, the outbox at-least-once delivery may produce duplicate notifications on retry. Coordinate with OMS team before scoping Phase 2b.
- **`StockunitService.transferStock` line 218 site (S11a)** is an inner branch ("moved to damaged location"). Verify the message-payload list doesn't escape the loop scope when deferred — snapshot it explicitly.

---

## 10. References

- Sibling plan: `sbdocs/1-Projects/wms1/plan/260424-runClubLine-transaction-boundary-hardening.md` (F1-F7 implemented as `f46cf06`)
- Reference implementations of the afterCommit pattern (in production):
  - `PickingorderBusinessService.finishPickingOrder:150-164`
  - `PickingorderBusinessService.confirmPick:344-350`
  - `MobilePickingService.processPick:438-450`
  - `CustomerorderBatchService.runClubLine:738-755` (post-F1)
- Repository pattern for the F6 lock: `CustomerorderBatchRepository.findByIdForUpdate` (added by runClubLine F6, commit `f46cf06`).
- `HttpRestService.java:40,87-88` — timeout + exception surface validated.
- `OptimisticLockRetryTemplate.java:19-56` — pattern source for `OmsNotificationHelper` (functional-interface utility).
- `MessageService.resendMessage:132-167` — basis for Phase 2a auto-resender.
- `WmsConstants.MessageStatus:458-470` — only SENT and FAILED defined today; Phase 2a adds DLQ.
- Frontend dead-code re-validation: `grep -rln "rapidPickingScan|rapidPickingConnect" wms-web-ui wms-mobile-ui oms` returned 0 matches (2026-04-24).
- Follow-up plan (future): `oms-notification-transactional-outbox.md` — Phase 2b structural fix (not yet created).
- Coordinating ticket-driven plan: [SBDEV-2095-large-bol-close-decoupling-and-perf.md](SBDEV-2095-large-bol-close-decoupling-and-perf.md) — owns the closeBOL-specific items (`bolToClose`, Phase 9 bulk finalize, IN-clause chunking, bulk carrier unlink) that this plan's S3 does not address.

---

## 11. Implementation Status

**Implemented 2026-04-25. Baseline: 1638 tests (1 failure, 2 errors pre-existing in ViewDtoServiceUnitTest). Test gap closed 2026-04-25: 1647 tests (+29 unit tests, +1 IT class), same pre-existing failures, zero new failures.**

### New files

| File | Purpose |
|---|---|
| `service/util/OmsNotificationHelper.java` | Reusable afterCommit deferral utility (two-arg + four-arg forms) |
| `test/.../util/OmsNotificationHelperTest.java` | 6 pure-unit tests for the helper |

### Modified production files

| Site | File | Change |
|---|---|---|
| S1 | `CustomerorderBatchService.java` | Pessimistic lock at entry; OMS POST deferred to afterCommit |
| S2 | `CustomerorderService.java` | OMS POST deferred to afterCommit (cancellationFromWithinWMS path) |
| S3 | `BillofladingService.java` | OMS POST deferred to afterCommit; audit row via createMessageInNewTransaction |
| S4a/b/c | `ReleaseOrderJobService.java` | Three OMS POSTs deferred; snapshot with new ArrayList<>() |
| S5 | `MobilePickingService.java` | Dead methods removed |
| S6 | `OrderMonitorViewService.java` | @Transactional added; cupsPrint + customerOrderToteAssigned deferred |
| S7/S8/S9 | `AdviceService.java` | @Transactional(class-level) added; three OMS POSTs deferred with failure path |
| S10 | `PickingorderBusinessService.java` | Fallback else-branch logs ERROR instead of silent drop |
| S11a-e | `StockunitService.java` | Five sendStockChangeMessage calls deferred with snapshots |
| S12 | `UnitloadService.java` | @Transactional added to delete* methods; sendStockChangeMessage deferred |
| S13a/b | `GoodsReceiptPositionService.java` | Two sendStockChangeMessage calls deferred with snapshots |
| S14 | `OrderMonitorViewService.java` | @Transactional added to reprintToteLabels; cupsPrint deferred |
| — | `MessageService.java` | Added createMessageInNewTransaction (REQUIRES_NEW) |

### Modified test files

| File | New tests |
|---|---|
| `CustomerorderBatchServiceUnitTest.java` | cancelBatch_acquiresBatchLockAtEntry, cancelBatch_omsCallDeferredUntilAfterCommit, cancelBatch_rollbackInTeardown_doesNotFireOms; fixed 3 existing tests for findByIdForUpdate |
| `CustomerorderServiceUnitTest.java` | cancelOrder_omsCallDeferredUntilAfterCommit, cancelOrder_rollback_noOmsCall |
| `BillofladingServiceUnitTest.java` | closeBOL_omsCallDeferredUntilAfterCommit, closeBOL_phase9Rollback_noOmsCall; fixed createMessage→createMessageInNewTransaction in 1 existing test |
| `AdviceServiceUnitTest.java` | close_httpPostFails_createsFailedMessage updated to use TX sync; @AfterEach added; acceptHubAndSpokeAdvice_rollback_noOmsCall, close_rollback_noOmsCall, acceptTransferAdvice_rollback_noOmsCall (S7/S8/S9) |
| `MobilePickingServiceUnitTest.java` | 4 dead tests removed (rapidPickingConnect/rapidPickingScan) |
| `ReleaseOrderJobServiceUnitTest.java` | releaseOrder_omsHoldDeferred_branch1, releaseOrder_omsHoldDeferred_branch2, releaseOrder_omsReleaseDeferred, releaseOrder_rollback_noOmsCall (S4a/b/c) |
| `OrderMonitorViewServiceUnitTest.java` | printToteLabels_printAndOmsAfterCommit, printToteLabels_rollback_noPrintNoOms (S6); reprintToteLabels_cupsPrintDeferred_doesNotFireOnRollback (S14) |
| `PickingorderBusinessServiceUnitTest.java` | finishPickingOrder_noActiveTx_logsErrorAndStillCalls (S10) |
| `StockunitServiceUnitTest.java` | 10 tests: transferStock/setLockOnHold/setLockDamaged/adjustAmount/removeLock each with deferred + rollback variants (S11a-e) |
| `UnitloadServiceUnitTest.java` | deleteUnitLoad_omsCallDeferredUntilAfterCommit, deleteUnitLoad_rollback_noOmsCall, deleteUnitLoadRecursive_omsCallDeferredUntilAfterCommit, deleteUnitLoadRecursive_rollback_noOmsCall (S12) |
| `GoodsReceiptPositionServiceUnitTest.java` | adjust_loopAccumulator_singleAfterCommit, adjust_rollback_noOmsCall, delete_omsCallDeferredUntilAfterCommit, delete_rollback_noOmsCall (S13a/b) |

### New integration test file

| File | Purpose |
|---|---|
| `service/OmsNotificationProgramIT.java` | Spring-context IT: verifies deferToCommit fires on real TX commit, is suppressed on rollback, and swallows afterCommit exceptions — using `@MockBean` HttpRestService/ManageOrderService in place of WireMock (Docker required; runs via `mvn verify`) |

### Deferred (Phase 2 / optional)

- Phase 2a: Flyway migration, `WmsConstants.MessageStatus.DLQ`, `MessageRetryJobService`, `MessageRetryJob`
- `OmsNotificationProgramIT` full WireMock variant (§6.3) — blocked on adding `wiremock-jre8` dependency; current fallback IT covers real Spring TX boundary
