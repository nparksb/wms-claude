---
title: "SBDEV-2238 — Transactional Outbox Phase-2 (cancelOrder / cancelBatch / acceptHubAndSpokeAdvice / closeAdvice / acceptTransferAdvice)"
ticket: "SBDEV-2238"
ticket_url: "https://app.clickup.com/t/SBDEV-2238"
type: "feature"
severity: "high"
priority: "high"
status: "archived"
project: ["wms2-api"]
version: "v2"
requester: "David Oppenheim"
assignee: "Nam Park"
created: "2026-05-19"
updated: "2026-05-19"
last_updated: "2026-05-19"
pr: "https://github.com/SiteBossInc/wms2-api/pull/28"
db_verified: "N/A"
db_verified_note: "No schema changes — outbox_message table already created by SBDEV-2221 V2.1.11"
related:
  - "[[SBDEV-2221-transactional-outbox-pilot]]"
  - "[[SBDEV-2238-4.1-bol-closeBOL-outbox-migration]]"
  - "[[wms2-oms-integration-map]]"
  - "[[wms2-transaction-osiv-boundary-map]]"
tags:
  - plan
  - wmsv2
  - oms-integration
  - reliability
  - outbox
  - transactional-outbox
---

# SBDEV-2238 — Transactional Outbox Phase-2 (5 Remaining Service Call Sites)

**Ticket:** [SBDEV-2238](https://app.clickup.com/t/SBDEV-2238)
**Project:** wms2-api | **Version:** v2 | **Type:** feature (Phase-2 outbox migration sweep, second wave)
**Priority:** High | **Severity:** HIGH (Tier 2 — silent OMS notification loss for cancellation + advice flows)
**Status:** implemented (2026-05-19) — [PR #28](https://github.com/SiteBossInc/wms2-api/pull/28) open against `develop`; pending merge + manual smoke
**Date:** 2026-05-19

> **RALPLAN-DR:** Three options considered.
> **Option A (selected) — 3 PRs (one per service file):** constructor expansion + call-site rewrite + unit+integration tests per service. Clean reviewer diff; independently revertable per service.
> **Option B (rejected) — 5 PRs (one per call-site):** maximum granularity but `AdviceService` needs one constructor expansion for all 3 sites anyway, making 3 separate PRs for 3 Advice methods artificial splitting.
> **Option C (rejected) — single omnibus PR:** minimum CI runs but blast radius too high; one service failure blocks the other four.

> **Framing.** SBDEV-2221 built the transactional outbox infrastructure (table,
> entity, repo, service, dispatcher, advisory lock, metrics, idempotency keys).
> SBDEV-2238-4.1 migrated the **first** caller — `BillofladingService.closeBOL` —
> proving the pattern in production with one process type (`ORDER_BATCH_SHIPPED`).
>
> This plan migrates the **next five** `omsNotificationService.sendAfterCommit(...)`
> call sites in three services: `CustomerorderService.cancelOrder`,
> `CustomerorderBatchService.cancelBatch`, and three methods on
> `AdviceService` (`acceptHubAndSpokeAdvice`, `close`, `acceptTransferAdvice`).
> No new infrastructure — only call-site rewrites, constructor expansions, and tests.
>
> **Eleven additional `sendAfterCommit` callers remain deferred** (Phase-3); the
> migration deliberately spreads risk one wave at a time so each wave produces
> an isolated production observation window.

---

## 0. Affected Sites (enumeration before drafting)

Greps run against `/home/nampark/dev/wms-claude/v2/wms2-api/src/main/java/net/aim_ai/wms`:

```
grep -rn "omsNotificationService\.sendAfterCommit\s*(" src/main/java/net/aim_ai/wms
```

| # | File:line | Method | processType | aggregateType | aggregateId expr | In-scope this plan |
|---|-----------|--------|-------------|---------------|------------------|--------------------|
| 1 | `service/CustomerorderService.java:720` | `cancelOrder` | `ORDER_BATCH_CANCELLED_FROM_WMS` | `CUSTOMER_ORDER` | `customerOrder.getId()` | **YES (Fix A)** |
| 2 | `service/CustomerorderBatchService.java:269` | `cancelBatch` | `ORDER_BATCH_CANCELLED_FROM_WMS` | `CUSTOMER_ORDER_BATCH` | `orderBatch.getId()` | **YES (Fix B)** |
| 3 | `service/AdviceService.java:255` | `acceptHubAndSpokeAdvice` | `ADVICE_HUB_AND_SPOKE_RECEIVED` | `ADVICE` | `advice.getId()` | **YES (Fix C)** |
| 4 | `service/AdviceService.java:347` | `close` | `ADVICE_CLOSE` | `ADVICE` | `advice.getId()` | **YES (Fix D)** |
| 5 | `service/AdviceService.java:410` | `acceptTransferAdvice` | `ADVICE_ACCEPT_TRANSFER` | `ADVICE` | `advice.getId()` | **YES (Fix E)** |
| 6 | `service/BillofladingService.java:655` | `closeBOL` | `ORDER_BATCH_SHIPPED` | `BILLOFLADING` | `bol.getId()` | **NO — SBDEV-2238-4.1 (already merged via PR #27)** |
| 7-17 | 11 other callers (`ReceivingService`, `PickingService`, `PackingService`, `StockMovementService`, `CycleCountService`, etc.) | various | various | various | **NO — Phase-3, separate plan** |

**Migration progress.** Pilot (SBDEV-2238-4.1) = 1 site. This plan (Phase-2 wave 2) = 5 sites. Phase-3 (deferred) = 11 sites. Total of 17 inline `sendAfterCommit` callers in v2 → at completion zero will remain and `OmsNotificationService.sendAfterCommit` can be removed in a final cleanup plan.

**Double-enqueue audit — NO RISK.** `CustomerorderBatchService.cancelBatch` does **not** call `CustomerorderService.cancelOrder`; it inlines the cancellation logic itself. The two `ORDER_BATCH_CANCELLED_FROM_WMS` rows enqueued (one from each method) are emitted from **independent user actions** (single-order cancel vs batch cancel) and are disambiguated downstream by their distinct `aggregateType` values (`CUSTOMER_ORDER` vs `CUSTOMER_ORDER_BATCH`).

**Adjacent-bug rule:** does NOT apply. Rows 6 and 7-17 share the same defect family but are deferred by design.

**Cross-reference greps:**

```bash
grep -rln "outboxService\|OutboxMessage\|OutboxService" v2/wms2-api/src
grep -rn  "sendAfterCommit" v2/wms2-api/src/main/java/net/aim_ai/wms
```

---

## 1. Problem Statement

The five migration targets share the **same antipattern** that SBDEV-2221 §1 documents and that the SBDEV-2238-4.1 pilot proved out:

```java
omsNotificationService.sendAfterCommit(url, payload, ORDER_BATCH_CANCELLED_FROM_WMS);
```

`sendAfterCommit` registers a `TransactionSynchronization.afterCommit()` callback that issues an HTTP POST to OMS **outside the database transaction**. Three failure modes follow:

1. **No durable record of intent** — if the pod crashes between commit and the `afterCommit` callback firing, the database state has already advanced (order cancelled / advice closed) but OMS will never learn. There is no log table to recover from.
2. **No retry** — a transient 5xx from OMS, a connection reset, or a 30s timeout is swallowed silently. The next OMS reconciliation job will eventually correct state, but the latency window is hours.
3. **No idempotency key on the wire** — OMS cannot dedupe a manually-retried call. Operators who notice the missing OMS-side state today have no safe retry mechanism.

The five flows targeted here are clinically meaningful:

| Flow | Frequency (typical day, single mid-size tenant) | Operator pain when notification is lost |
|------|------|------|
| `cancelOrder` | 50-200 cancellations / day | OMS holds order in active state; warehouse declines new picks but OMS still allows allocation → reservation leak |
| `cancelBatch` | 1-10 batches / day | Whole batch (10-100 orders) shows live in OMS while WMS has cancelled them — magnified reservation leak |
| `acceptHubAndSpokeAdvice` | 5-30 / day | OMS does not see the received advice; downstream allocation refuses inventory that physically arrived |
| `close` (advice) | 5-30 / day | OMS still treats advice as open; reconciliation lag delays inventory availability |
| `acceptTransferAdvice` | 1-5 / day (transfer-enabled tenants only) | Inter-facility transfer appears stuck — neither source nor destination facility sees the correct state |

The SBDEV-2238-4.1 pilot (BOL `ORDER_BATCH_SHIPPED`) proved the outbox pattern in production with no rollback risk. Five additional process types now extend that durability guarantee.

---

## 2. Root Cause / Current Architecture

This plan inherits the root-cause analysis from SBDEV-2221 §2. The three root causes are identical for all five sites:

1. **`sendAfterCommit` registers a post-commit hook, not a row** — Spring's `TransactionSynchronizationManager` keeps the registration in JVM-local thread state. A pod crash between `COMMIT` and the callback firing destroys the intent.
2. **No retry / no backoff** — `OmsNotificationService.doSend()` swallows non-2xx as an `error` log and returns.
3. **No idempotency key on the OMS wire** — even a manual retry produces duplicate-effect requests.

**Why these five next.** The pilot validated infrastructure on `ORDER_BATCH_SHIPPED`. The two cancellation paths (`cancelOrder`, `cancelBatch`) are **frequent, operator-driven**, and have the worst silent-failure cost (reservation leaks for orders OMS believes are still active). The three advice paths (`acceptHubAndSpokeAdvice`, `close`, `acceptTransferAdvice`) are lower-frequency but drive **warehouse↔OMS advice-state reconciliation** — the receiving pipeline's primary integration surface. Migrating these five next concentrates the remaining Phase-2 sweep on the two highest-business-pain integration domains.

**Current transaction shape (all five methods).** Each method already carries:

```java
@Transactional(value = "tenantTransactionManager",
               rollbackFor = {BusinessException.class, FacadeException.class})
```

— so `OutboxService.enqueue(...)`'s `Propagation.MANDATORY` requirement is satisfied with no scope changes.

---

## 3. Fix Design

All five fixes share the same shape:

1. Replace `omsNotificationService.sendAfterCommit(url, payload, processType)` with `outboxService.enqueue(OutboxMessage.builder()...)`.
2. Hoist `new ObjectMapper()` to a `private static final ObjectMapper MAPPER = new ObjectMapper().setSerializationInclusion(JsonInclude.Include.NON_NULL);` to (a) avoid the per-call allocation, (b) normalize JSON shape across all 5 sites.
3. Replace the `catch (IOException)` block with counter + log + `throw new FacadeException(...)` — matching the merged pilot (`BillofladingService.closeBOL` on `develop`). This ensures a serialization failure rolls back the caller's transaction, preventing WMS state from advancing when OMS will never hear about it.
4. Add `OutboxService outboxService` and `MeterRegistry meterRegistry` to the service constructor.

Constructor expansions count: **three** (one per service file). Sites C+D+E share one expansion in `AdviceService`.

### Fix A — `CustomerorderService.cancelOrder` (line ~720)

**aggregateType:** `"CUSTOMER_ORDER"`
**aggregateId expression:** `customerOrder.getId()`
**processType:** `WmsConstants.MessageProcessType.ORDER_BATCH_CANCELLED_FROM_WMS`
**URL sysprop key:** `WmsConstants.SYSTEM_PROPERTY_WEBSERVICE_ORDER_BATCH_CANCELLED_URL_KEY`
**Serialized DTO type:** `OrderBatchDto` (the `orderBatchDto` local already in scope)

**Before (lines 717-724):**
```java
try {
    String urlPath = syspropService.getSysvalue(WmsConstants.SYSTEM_PROPERTY_WEBSERVICE_ORDER_BATCH_CANCELLED_URL_KEY);
    String payload = new ObjectMapper().writeValueAsString(orderBatchDto);
    omsNotificationService.sendAfterCommit(urlPath, payload,
        WmsConstants.MessageProcessType.ORDER_BATCH_CANCELLED_FROM_WMS);
} catch (IOException e) {
    LOG.error("Failed to serialize cancel order payload: {}", e.getMessage());
}
```

**After (matching merged pilot pattern from `BillofladingService.closeBOL`):**
```java
String payload;
try {
    payload = MAPPER.writeValueAsString(orderBatchDto);
} catch (IOException e) {
    meterRegistry.counter("wms2.outbox.serialize_failed",
            "aggregate_type", "CUSTOMER_ORDER",
            "process_type", WmsConstants.MessageProcessType.ORDER_BATCH_CANCELLED_FROM_WMS).increment();
    LOG.error("Failed to serialize cancel order payload for order={}", customerOrder.getId(), e);
    throw new FacadeException(
            "Failed to serialize cancel order payload for order=" + customerOrder.getId(), e);
}
String urlPath = syspropService.getSysvalue(
        WmsConstants.SYSTEM_PROPERTY_WEBSERVICE_ORDER_BATCH_CANCELLED_URL_KEY);
outboxService.enqueue(OutboxMessage.builder()
        .aggregateType("CUSTOMER_ORDER")
        .aggregateId(customerOrder.getId())
        .processType(WmsConstants.MessageProcessType.ORDER_BATCH_CANCELLED_FROM_WMS)
        .destinationUrl(urlPath)
        .payload(payload)
        .build());
```

Plus, at class-field scope:
```java
private static final ObjectMapper MAPPER =
    new ObjectMapper().setSerializationInclusion(JsonInclude.Include.NON_NULL);
```

**IOException rethrow rationale.** On serialization failure, `FacadeException` propagates up through the `@Transactional` boundary, rolling back both the `customer_order` state change and the outbox INSERT. This matches the merged `BillofladingService.closeBOL` policy: WMS must not advance business state when OMS will never hear about the transition. For operator-driven cancellations, this means the operator sees a 500 on a Jackson bug (rare), but the order remains in its pre-cancel state and can be retried safely.

**`idempotencyKey` field omitted.** The merged pilot does not call `.idempotencyKey(...)` on the builder — `OutboxService.enqueue` auto-generates the UUID. This plan matches that convention.

**NON_NULL normalization note.** Site #1 today uses a bare `new ObjectMapper()` (no NON_NULL serialization), inconsistent with the other four sites in this plan. The normalization is safe: OMS already accepts NON_NULL payloads for `ORDER_BATCH_CANCELLED_FROM_WMS` via site #2 (`cancelBatch`), which has been using `.setSerializationInclusion(JsonInclude.Include.NON_NULL)` since the v2 cut-over. Normalizing site #1 to NON_NULL eliminates a quiet schema-drift between the two emitters of the same process type.

### Fix B — `CustomerorderBatchService.cancelBatch` (line ~269)

**aggregateType:** `"CUSTOMER_ORDER_BATCH"`
**aggregateId expression:** `orderBatch.getId()`
**processType:** `WmsConstants.MessageProcessType.ORDER_BATCH_CANCELLED_FROM_WMS`
**URL sysprop key:** `WmsConstants.SYSTEM_PROPERTY_WEBSERVICE_ORDER_BATCH_CANCELLED_URL_KEY`
**Serialized DTO type:** `OrderBatchDto` (built from the batch)

Same before/after shape as Fix A (serialization in its own try-catch, rethrow `FacadeException` on failure, counter tag keys snake_case, no explicit `.idempotencyKey(...)`). Static `MAPPER` field added to `CustomerorderBatchService`. The bare-MAPPER-vs-NON_NULL drift does not apply here — this site already uses NON_NULL — so the only behavioural delta is the `outboxService.enqueue(...)` swap and the serialize-failed counter.

### Fix C — `AdviceService.acceptHubAndSpokeAdvice` (line ~255)

**aggregateType:** `"ADVICE"`
**aggregateId expression:** `advice.getId()`
**processType:** `WmsConstants.MessageProcessType.ADVICE_HUB_AND_SPOKE_RECEIVED`
**URL sysprop key:** `WmsConstants.SYSTEM_PROPERTY_WEBSERVICE_ACCEPT_HUB_AND_SPOKE_URL_KEY`
**Serialized DTO type:** `AdviceDto`

Same before/after shape as Fix A (serialization-only try-catch, rethrow `FacadeException`, snake_case counter tags, no explicit idempotencyKey). Shares the `AdviceService` constructor expansion with Fixes D and E.

### Fix D — `AdviceService.close` (line ~347)

**aggregateType:** `"ADVICE"`
**aggregateId expression:** `advice.getId()`
**processType:** `WmsConstants.MessageProcessType.ADVICE_CLOSE`
**URL sysprop key:** `WmsConstants.SYSTEM_PROPERTY_WEBSERVICE_CLOSE_ADVICE_URL_KEY`
**Serialized DTO type:** `AdviceDto`

### Fix E — `AdviceService.acceptTransferAdvice` (line ~410)

**aggregateType:** `"ADVICE"`
**aggregateId expression:** `advice.getId()`
**processType:** `WmsConstants.MessageProcessType.ADVICE_ACCEPT_TRANSFER`
**URL sysprop key:** `WmsConstants.SYSTEM_PROPERTY_WEBSERVICE_ACCEPT_TRANSFER_URL_KEY`
**Serialized DTO type:** `AcceptTransferDto` (carries only `transferId` — see §10 Risk #7 for ops-tracing note)

### Shared constructor expansion — `AdviceService`

```java
// Existing constructor (abbreviated):
public AdviceService(
        AdviceRepository adviceRepository,
        OmsNotificationService omsNotificationService,
        SyspropService syspropService,
        /* ... existing deps ... */) {
    /* ... */
}

// After:
public AdviceService(
        AdviceRepository adviceRepository,
        OmsNotificationService omsNotificationService,
        SyspropService syspropService,
        OutboxService outboxService,
        MeterRegistry meterRegistry,
        /* ... existing deps ... */) {
    this.outboxService = outboxService;
    this.meterRegistry = meterRegistry;
    /* ... */
}
```

`OmsNotificationService` is **kept injected** because the 11 deferred call sites still use it (Phase-3 will remove the dependency once all callers are migrated).

---

## 4. Architecture Overview

```
                 ┌─────────────────────────────────────────────┐
                 │   Tenant transaction (MANDATORY propagation) │
                 │                                             │
   cancelOrder   │  ── UPDATE customer_order SET status = ... │
   cancelBatch   │  ── UPDATE customer_order_batch SET ...    │
   acceptHub..   │  ── UPDATE advice SET ...                  │
   close         │  ── UPDATE advice SET ...                  │
   acceptXfer..  │  ── INSERT outbox_message  ◄── NEW         │
                 │                                             │
                 └────────────── COMMIT ──────────────────────┘
                                       │
                                       ▼
                          ┌────────────────────────────┐
                          │  OutboxDispatcherJob       │
                          │  (existing, SBDEV-2221)    │
                          │  ─ advisory lock           │
                          │  ─ claim-then-release      │
                          │  ─ tenant iteration        │
                          │  ─ per-tenant batch        │
                          │  ─ no process-type filter  │  ◄── KEY
                          └──────────┬─────────────────┘
                                     │
                                     ▼
                        POST {destinationUrl}
                        Idempotency-Key: {idempotencyKey}
                        Body: {payload}
                                     │
                                     ▼
                                   OMS
```

**Why the dispatcher needs zero changes.** `OutboxDispatcherJob` claims rows by status (`PENDING`) and `available_at <= now()` — there is **no process-type filter** in the claim query. The five new process types ride the existing dispatcher unchanged.

**Process-type → URL sysprop key matrix** (the dispatcher reads `destination_url` from the row; this table records where each row got that URL):

| processType (column = WmsConstants.MessageProcessType) | URL sysprop key (SYSTEM_PROPERTY_*_URL_KEY) | Caller |
|---|---|---|
| `ORDER_BATCH_CANCELLED_FROM_WMS` | `SYSTEM_PROPERTY_WEBSERVICE_ORDER_BATCH_CANCELLED_URL_KEY` | `cancelOrder`, `cancelBatch` (both — shared) |
| `ADVICE_HUB_AND_SPOKE_RECEIVED` | `SYSTEM_PROPERTY_WEBSERVICE_ACCEPT_HUB_AND_SPOKE_URL_KEY` | `acceptHubAndSpokeAdvice` |
| `ADVICE_CLOSE` | `SYSTEM_PROPERTY_WEBSERVICE_CLOSE_ADVICE_URL_KEY` | `close` |
| `ADVICE_ACCEPT_TRANSFER` | `SYSTEM_PROPERTY_WEBSERVICE_ACCEPT_TRANSFER_URL_KEY` | `acceptTransferAdvice` |
| `ORDER_BATCH_SHIPPED` (out-of-scope) | `SYSTEM_PROPERTY_WEBSERVICE_ORDER_BATCH_SHIPPED_URL_KEY` | `closeBOL` (SBDEV-2238-4.1, already merged) |

---

## 5. File Change Summary

| Type | Path | Reason |
|---|---|---|
| MOD | `v2/wms2-api/src/main/java/net/aim_ai/wms/service/CustomerorderService.java` | Fix A + static `MAPPER` + constructor expansion (`OutboxService`, `MeterRegistry`) |
| MOD | `v2/wms2-api/src/main/java/net/aim_ai/wms/service/CustomerorderBatchService.java` | Fix B + static `MAPPER` + constructor expansion |
| MOD | `v2/wms2-api/src/main/java/net/aim_ai/wms/service/AdviceService.java` | Fixes C+D+E + static `MAPPER` + single shared constructor expansion |
| MOD | `v2/wms2-api/src/test/java/net/aim_ai/wms/unit/service/CustomerorderServiceUnitTest.java` | 3 new test methods for Fix A |
| MOD | `v2/wms2-api/src/test/java/net/aim_ai/wms/unit/service/CustomerorderBatchServiceUnitTest.java` | 3 new test methods for Fix B |
| MOD | `v2/wms2-api/src/test/java/net/aim_ai/wms/unit/service/AdviceServiceUnitTest.java` | 9 new test methods (3 per fix × 3 fixes) |
| NEW | `v2/wms2-api/src/test/java/net/aim_ai/wms/integration/CustomerorderOutboxIntegrationTest.java` | Testcontainers integration coverage for Fix A |
| NEW | `v2/wms2-api/src/test/java/net/aim_ai/wms/integration/CustomerorderBatchOutboxIntegrationTest.java` | Testcontainers integration coverage for Fix B |
| NEW | `v2/wms2-api/src/test/java/net/aim_ai/wms/integration/AdviceOutboxIntegrationTest.java` | Testcontainers integration coverage for Fixes C+D+E (one file, three methods worth of test methods) |
| MOD | `sbdocs/3-Resources/architecture/wms2-oms-integration-map.md` | Update deferred-sites count (16→11), bump `last_verified` |
| NEW | `sbdocs/9-System/scripts/verify-SBDEV-2238-outbox-phase2-remaining-services.sh` | Static-verification harness for this plan |

**No SQL migration.** `outbox_message` table is already created by SBDEV-2221's `V2.1.11__add_outbox_message.sql`.

**No properties change.** `app.cron.outbox-dispatcher` and `app.outbox.dispatcher.*` are already defined.

---

## 6. Implementation Steps

### 6.1 Prerequisites (hard gates)

These gates are checked manually before Step 1 and re-verified by the verify script (`Section 0`).

0. **Branch base.** The working tree MUST be rooted on `develop` (where SBDEV-2221 and SBDEV-2238-4.1 landed). The repo's current working tree may be on `develop-arden` or another sync branch — that branch does **not** contain the outbox artifacts.
   ```bash
   git checkout develop && git pull origin develop
   # Verify commit 6076743b (SBDEV-2221) and 85c86d2f (SBDEV-2238-4.1) are in history:
   git log --oneline | grep -E "6076743|85c86d2"
   # Then create the feature branch:
   git checkout -b feature/SBDEV-2238-phase2-cancelorder   # (or -cancelbatch / -advice)
   ```
1. **SBDEV-2221 merged into `develop`.** `OutboxMessage`, `OutboxService`, `OutboxDispatcherJob`, `OutboxMessageRepository`, `V2.1.11__add_outbox_message.sql`, `JobLockId.OUTBOX_DISPATCHER = 100008L`, `application.properties` outbox keys — all present.
2. **SBDEV-2238-4.1 merged into `develop`.** `BillofladingService.closeBOL` calls `outboxService.enqueue(...)` and no longer calls `omsNotificationService.sendAfterCommit(..., ORDER_BATCH_SHIPPED)`.

If prerequisites 1 or 2 fail, the verify script exits non-zero before any Phase-2 work begins.

### Step 1 — Fix A: CustomerorderService.cancelOrder + unit tests
- Branch: `feature/SBDEV-2238-phase2-cancelorder`.
- Add `private static final ObjectMapper MAPPER = new ObjectMapper().setSerializationInclusion(JsonInclude.Include.NON_NULL);` to `CustomerorderService`.
- Expand constructor: `OutboxService outboxService`, `MeterRegistry meterRegistry`.
- Replace `omsNotificationService.sendAfterCommit(...)` block at line ~720 with `outboxService.enqueue(...)` + serialize-failed counter (see Fix A above).
- Add three unit test methods to `CustomerorderServiceUnitTest`:
    - `cancelOrder_enqueuesOutboxMessageWithExpectedFields`
    - `cancelOrder_doesNotCallSendAfterCommitForProcessType`
    - `cancelOrder_incrementsSerializeFailedCounterOnIOException`
- **Acceptance:** `mvn test -Dtest=CustomerorderServiceUnitTest` green; verify script Fix-A rows green.
- One commit.

### Step 2 — Fix B: CustomerorderBatchService.cancelBatch + unit tests
- Branch: `feature/SBDEV-2238-phase2-cancelbatch`.
- Add `private static final ObjectMapper MAPPER = ...` to `CustomerorderBatchService` (already has NON_NULL inline — hoist it).
- Expand constructor: `OutboxService outboxService`, `MeterRegistry meterRegistry`.
- Replace `omsNotificationService.sendAfterCommit(...)` block at line ~269 with `outboxService.enqueue(...)` + counter.
- Add three unit test methods to `CustomerorderBatchServiceUnitTest`:
    - `cancelBatch_enqueuesOutboxMessageWithExpectedFields`
    - `cancelBatch_doesNotCallSendAfterCommitForProcessType`
    - `cancelBatch_incrementsSerializeFailedCounterOnIOException`
- **Acceptance:** `mvn test -Dtest=CustomerorderBatchServiceUnitTest` green; verify script Fix-B rows green.
- One commit.

### Step 3 — Fixes C+D+E: AdviceService.acceptHubAndSpokeAdvice / close / acceptTransferAdvice + unit tests
- Branch: `feature/SBDEV-2238-phase2-advice`.
- Add `private static final ObjectMapper MAPPER = ...` to `AdviceService`.
- Single constructor expansion: `OutboxService outboxService`, `MeterRegistry meterRegistry`.
- Replace three `sendAfterCommit` blocks (lines ~255, ~347, ~410) with `outboxService.enqueue(...)` + counter — one block per method.
- Add nine unit test methods to `AdviceServiceUnitTest`:
    - `acceptHubAndSpokeAdvice_enqueuesOutboxMessageWithExpectedFields`
    - `acceptHubAndSpokeAdvice_doesNotCallSendAfterCommitForProcessType`
    - `acceptHubAndSpokeAdvice_incrementsSerializeFailedCounterOnIOException`
    - `close_enqueuesOutboxMessageWithExpectedFields`
    - `close_doesNotCallSendAfterCommitForProcessType`
    - `close_incrementsSerializeFailedCounterOnIOException`
    - `acceptTransferAdvice_enqueuesOutboxMessageWithExpectedFields`
    - `acceptTransferAdvice_doesNotCallSendAfterCommitForProcessType`
    - `acceptTransferAdvice_incrementsSerializeFailedCounterOnIOException`
- **Acceptance:** `mvn test -Dtest=AdviceServiceUnitTest` green; verify script Fix-C, D, E rows green.
- One commit.

### Step 4 — Integration tests (three Testcontainers classes)
- New file: `CustomerorderOutboxIntegrationTest.java` with three test methods (atomic enqueue / rollback / distinct keys).
- New file: `CustomerorderBatchOutboxIntegrationTest.java` with three test methods.
- New file: `AdviceOutboxIntegrationTest.java` with nine test methods (three per Fix C/D/E).
- All three must be annotated `@Testcontainers` (Postgres required for `FOR UPDATE SKIP LOCKED` semantics).
- **Acceptance:** `mvn verify -Dit.test=*OutboxIntegrationTest` green.
- One commit (can be folded into Step 3 PR if mergers prefer).

### Step 5 — Docs + verify script
- Update `sbdocs/3-Resources/architecture/wms2-oms-integration-map.md`:
    - Bump deferred-callers count from 16 to 11.
    - Mark these 5 callers as `outbox-migrated` in the integration map.
    - Update `last_verified: 2026-05-19`.
- Add `sbdocs/9-System/scripts/verify-SBDEV-2238-outbox-phase2-remaining-services.sh`.
- **Acceptance:** `bash sbdocs/9-System/scripts/verify-SBDEV-2238-outbox-phase2-remaining-services.sh` returns exit 0.
- One commit.

### Step 6 — End-to-end smoke (manual, post-merge to dev)
- Deploy branch to dev (or each of the 3 branches in turn).
- Trigger each operation against a dev tenant:
    1. Cancel a single order from the UI → verify a `CUSTOMER_ORDER` row in `outbox_message` transitions `PENDING → IN_FLIGHT → SENT` within 15s.
    2. Cancel an order batch → same shape, `CUSTOMER_ORDER_BATCH`.
    3. Accept a hub-and-spoke advice → `ADVICE` row, `ADVICE_HUB_AND_SPOKE_RECEIVED`.
    4. Close an advice → `ADVICE` row, `ADVICE_CLOSE`.
    5. Accept a transfer advice (transfer-enabled tenant) → `ADVICE` row, `ADVICE_ACCEPT_TRANSFER`.
- Capture OMS-side state for each and confirm reflection within 30s of the WMS commit.
- Pull `wms2.outbox.dispatched` counter by `processType` — expect the 5 new process types to appear with non-zero counts; pull `wms2.outbox.serialize_failed` — expect zero.

---

## 7. Horizontal Scalability Validation

10-row checklist — none of the 10 surface a new scaling concern.

| # | Concern | Status | Notes |
|---|---------|--------|-------|
| 1 | New scheduled job? | NO | Existing `OutboxDispatcherJob` (SBDEV-2221) drains rows; no new cron entry. |
| 2 | Dispatcher concurrency safety? | N/A here | Plan changes no dispatcher code. Existing advisory-lock-gated claim-then-release semantics are unchanged. |
| 3 | New cache / shared state? | NO | All state lives in `outbox_message` rows. |
| 4 | New async / executor path? | NO | `outboxService.enqueue(...)` is a synchronous `INSERT` within the caller's tenant transaction. |
| 5 | Per-tenant HikariCP pool pressure? | NEGLIGIBLE | Each call site adds **at most one** `INSERT` to a transaction that already exists. Average row size <2KB. Worst case: a 100-order batch cancellation still emits **one** `INSERT` (one outbox row for the whole batch, keyed by `orderBatch.getId()`). |
| 6 | New cross-tenant code path? | NO | All five fixes run inside the existing `tenantTransactionManager` boundary. |
| 7 | Idempotency-key collision risk? | NONE | UUIDv4 per call, 64-char column. ~1/2^61 collision probability at billion-row scale (negligible). |
| 8 | Outbox row growth rate? | BOUNDED | The five callers add ~60-280 rows / day / tenant. `app.outbox.dispatcher.retention-days` already prunes SENT rows. |
| 9 | Lock contention on `outbox_message`? | UNCHANGED | INSERT-only; no UPDATE in caller transaction. Dispatcher uses `FOR UPDATE SKIP LOCKED`. |
| 10 | New JVM in-memory state? | NONE | Static `MAPPER` is a singleton per service; threadsafe (Jackson's `ObjectMapper` is documented threadsafe after configuration). |

---

## 8. v2 Constraint Checklist

| # | Constraint | Status | Notes |
|---|------------|--------|-------|
| 1 | `jakarta.persistence.*` (not `javax.*`) | N/A | No new entities; `OutboxMessage` from SBDEV-2221 already on Jakarta. |
| 2 | No `@ManyToOne` / no JPA associations | N/A | No new entities; existing services already follow this rule. |
| 3 | `@Transactional` declares `value = "tenantTransactionManager"` | YES | All five methods already do; verify script asserts unchanged. |
| 4 | `OutboxService.enqueue` is `Propagation.MANDATORY` | YES | Inherited from SBDEV-2221. Each fix runs inside the caller's tenant transaction; calls outside that boundary throw `IllegalTransactionStateException`. |
| 5 | Use `MeterRegistry` (Micrometer 1.13 + Prometheus) | YES | `serialize_failed` counter follows the SBDEV-2238-4.1 pilot's naming. |
| 6 | Testcontainers Postgres for Postgres-specific tests | YES | The three new `*OutboxIntegrationTest` classes are `@Testcontainers`. |
| 7 | Static-final `ObjectMapper MAPPER = …` per service | YES | One per file; threadsafe after config. |
| 8 | No `mockStatic()` in unit tests | YES | All five fixes mock `OutboxService` / `MeterRegistry` / `SyspropService` through constructor; static-method mocking not required. |

---

## 9. Testing Plan

**30 named tests total** (15 unit + 15 integration).

### Unit tests — extend existing test classes; mock `OutboxService`, `MeterRegistry`, and `SyspropService`

`CustomerorderServiceUnitTest`:
- `cancelOrder_enqueuesOutboxMessageWithExpectedFields`
- `cancelOrder_doesNotCallSendAfterCommitForProcessType`
- `cancelOrder_incrementsSerializeFailedCounterOnIOException`

`CustomerorderBatchServiceUnitTest`:
- `cancelBatch_enqueuesOutboxMessageWithExpectedFields`
- `cancelBatch_doesNotCallSendAfterCommitForProcessType`
- `cancelBatch_incrementsSerializeFailedCounterOnIOException`

`AdviceServiceUnitTest`:
- `acceptHubAndSpokeAdvice_enqueuesOutboxMessageWithExpectedFields`
- `acceptHubAndSpokeAdvice_doesNotCallSendAfterCommitForProcessType`
- `acceptHubAndSpokeAdvice_incrementsSerializeFailedCounterOnIOException`
- `close_enqueuesOutboxMessageWithExpectedFields`
- `close_doesNotCallSendAfterCommitForProcessType`
- `close_incrementsSerializeFailedCounterOnIOException`
- `acceptTransferAdvice_enqueuesOutboxMessageWithExpectedFields`
- `acceptTransferAdvice_doesNotCallSendAfterCommitForProcessType`
- `acceptTransferAdvice_incrementsSerializeFailedCounterOnIOException`

Each `…_enqueuesOutboxMessageWithExpectedFields` asserts the `OutboxMessage` built and passed to `outboxService.enqueue(...)` has the right `aggregateType`, `aggregateId`, `processType`, `destinationUrl`, and non-null `payload`. `idempotencyKey` is **not** asserted on the captured builder argument — it is auto-generated by `OutboxService.enqueue` (the caller's builder does not set it). Distinctness of `idempotencyKey` is verified in the integration test `…_distinctIdempotencyKeysPerCall`.

Each `…_doesNotCallSendAfterCommitForProcessType` verifies `omsNotificationService.sendAfterCommit(...)` is **not** called with the migrated `processType` (other process types still legal — only the migrated one must be absent).

Each `…_incrementsSerializeFailedCounterOnIOException` injects a `MAPPER` that throws `IOException`, asserts the counter is incremented exactly once with the expected snake_case `aggregate_type` + `process_type` tags, and asserts that `FacadeException` is thrown (matching the merged pilot's rollback-on-serialization-failure policy). The counter must fire **before** the throw so it is recorded even when the transaction rolls back.

### Integration tests — Testcontainers Postgres

`CustomerorderOutboxIntegrationTest`:
- `cancelOrder_enqueuesOutboxRowAtomically` — start tx, call `cancelOrder(...)`, commit, assert one `outbox_message` row with `status=PENDING`, correct `aggregate_type='CUSTOMER_ORDER'`, correct `process_type`.
- `cancelOrder_rollsBackOutboxRowOnException` — force `customerOrder.getStatus(...)` validation to throw `BusinessException`, assert zero outbox rows after rollback.
- `cancelOrder_distinctIdempotencyKeysPerCall` — call `cancelOrder` twice (different orders), assert two outbox rows with different `idempotency_key` values.

`CustomerorderBatchOutboxIntegrationTest`:
- `cancelBatch_enqueuesOutboxRowAtomically`
- `cancelBatch_rollsBackOutboxRowOnException`
- `cancelBatch_distinctIdempotencyKeysPerCall`

`AdviceOutboxIntegrationTest`:
- `acceptHubAndSpokeAdvice_enqueuesOutboxRowAtomically`
- `acceptHubAndSpokeAdvice_rollsBackOutboxRowOnException`
- `acceptHubAndSpokeAdvice_distinctIdempotencyKeysPerCall`
- `close_enqueuesOutboxRowAtomically`
- `close_rollsBackOutboxRowOnException`
- `close_distinctIdempotencyKeysPerCall`
- `acceptTransferAdvice_enqueuesOutboxRowAtomically`
- `acceptTransferAdvice_rollsBackOutboxRowOnException`
- `acceptTransferAdvice_distinctIdempotencyKeysPerCall`

### Manual smoke (post-merge to dev)

See §6 Step 6. Five operations, five outbox-row-traceability checks, two metric checks.

---

## 10. Risks & Mitigations

1. **SBDEV-2221 not merged** — hard gate. Verify script Section 0 fails fast. Mitigation: do not start Step 1 until SBDEV-2221 is in `develop` AND the local source tree has `OutboxMessage.java` et al.
2. **NON_NULL normalization on Fix A** — low risk. OMS already accepts NON_NULL for `ORDER_BATCH_CANCELLED_FROM_WMS` via the v2 `cancelBatch` site. Mitigation: smoke-test step 6.1 hits both Fix A and Fix B paths against the same dev OMS instance.
3. **MeterRegistry injection into 3 large services** — low risk. Constructor expansion only; no field reorder needed. Mitigation: keep one parameter-add per service per commit; reviewer sees a minimal constructor diff.
4. **cancelOrder + cancelBatch both emit `ORDER_BATCH_CANCELLED_FROM_WMS`** — **not** a double-enqueue. The two callers are invoked by independent user actions (single-order cancel vs batch cancel). Their rows are disambiguated by `aggregateType` (`CUSTOMER_ORDER` vs `CUSTOMER_ORDER_BATCH`). Mitigation: integration test `cancelBatch_enqueuesOutboxRowAtomically` asserts exactly one row, of type `CUSTOMER_ORDER_BATCH` — proves no cascade fan-out.
5. **11 deferred `sendAfterCommit` callers remain best-effort** — known, deferred to Phase-3. Mitigation: docs update in Step 5 keeps the deferred-caller inventory accurate; `OmsNotificationService` is **not** removed by this plan.
6. **`IllegalArgumentException` from `OutboxService.enqueue` (e.g. idempotency-key too long)** — propagates as a runtime exception through `rollbackFor` default (Spring rolls back on `RuntimeException` regardless of `rollbackFor`). The caller's tenant transaction rolls back, no orphaned business state. Mitigation: unit test asserts a deliberately too-long `idempotencyKey` rolls back the whole `cancelOrder` call.
7. **`acceptTransferAdvice` aggregateId / payload-key asymmetry.** `aggregateId = advice.getId()` (WMS-local PK) but `AcceptTransferDto` serializes **only** `transferId` (the cross-system key). An operator tracing an OMS-side reconciliation alert by `transferId` cannot query `outbox_message WHERE aggregate_id = <transferId>` directly — they must join `outbox_message → advice ON aggregate_id = advice.id AND advice.transfer_id = '<transferId>'`. Mitigation: documented here. A structured tag (e.g. a `tags` JSON column on `outbox_message`) could improve traceability, but is deferred to Phase-3 scope.

---

## 11. Open Questions / Resolved Decisions

All five questions are resolved (no blockers).

| # | Question | Resolution |
|---|----------|------------|
| 1 | Scope: 5 sites in 1, 3, or 5 PRs? | **3 PRs** (one per service file) — see RALPLAN-DR option A. |
| 2 | `aggregateType` convention for the two `ORDER_BATCH_CANCELLED_FROM_WMS` callers? | **Distinct:** `CUSTOMER_ORDER` (Fix A) vs `CUSTOMER_ORDER_BATCH` (Fix B) — uses underscore-separated naming consistent with merged pilot (`BILL_OF_LADING`). Ops can grep `outbox_message WHERE aggregate_type = 'CUSTOMER_ORDER'` to find single-order cancels, `CUSTOMER_ORDER_BATCH` for batch cancels. |
| 3 | NON_NULL normalization on Fix A's bare `new ObjectMapper()`? | **Yes.** Eliminates schema-drift between the two emitters of the same process type. Safe — OMS already consumes NON_NULL for this type. |
| 4 | Add `MeterRegistry` to all 3 services? | **Yes.** The serialize-failed counter is operationally critical. |
| 5 | Remove `OmsNotificationService` injection? | **No.** 11 deferred call sites still use it. Removal happens in the final Phase-3 cleanup plan. |

---

## 12. Implementation Status

> _To be filled in at implementation time. Replace placeholders with real branch / commit / PR / test-result values, then flip `status: draft → implemented` in frontmatter._

| Step | Branch | Commit | PR | Tests | Status |
|------|--------|--------|----|----|--------|
| 1 — Fix A | `tasks/SBDEV-2238-phase2` | `b15522b` | [#28](https://github.com/SiteBossInc/wms2-api/pull/28) | `mvn test`: 259 tests, 0 failures | implemented |
| 2 — Fix B | `tasks/SBDEV-2238-phase2` | `b15522b` | [#28](https://github.com/SiteBossInc/wms2-api/pull/28) | `mvn test`: 259 tests, 0 failures | implemented |
| 3 — Fixes C+D+E | `tasks/SBDEV-2238-phase2` | `b15522b` | [#28](https://github.com/SiteBossInc/wms2-api/pull/28) | `mvn test`: 259 tests, 0 failures | implemented |
| 4 — Integration tests | (folded into steps 1–3) | `b15522b` | [#28](https://github.com/SiteBossInc/wms2-api/pull/28) | `mvn test`: 259 tests, 0 failures (includes 15 integration) | implemented |
| 5 — Docs + verify script | (sbdocs — filesystem) | n/a | n/a | `wms2-oms-integration-map.md` updated; `last_verified: 2026-05-19` | implemented |
| 6 — Smoke | dev deployment | n/a | n/a | Manual: 5 outbox rows SENT, 0 serialize_failed | pending (post-merge) |

---

## ADR — Architectural Decision Record

- **Decision.** Migrate five remaining `omsNotificationService.sendAfterCommit(...)` callers to `outboxService.enqueue(...)` in three PRs grouped by service file (`CustomerorderService`, `CustomerorderBatchService`, `AdviceService`). No new infrastructure; reuse SBDEV-2221's outbox + dispatcher and the SBDEV-2238-4.1 pilot pattern.
- **Drivers.**
    1. Silent OMS-notification loss on pod crash / OMS transient 5xx is unacceptable for cancellation and advice flows (reservation leaks, inventory-availability lag).
    2. The SBDEV-2238-4.1 pilot proved the outbox pattern works in production at one call site.
    3. Reviewer cognitive load is bounded when each PR touches one service file and adds tests for that file's call sites.
- **Alternatives considered.**
    - **Option B — 5 PRs (one per call-site):** rejected. `AdviceService` would still need its constructor expanded once, so splitting Fixes C/D/E across 3 PRs would either repeat the same constructor expansion 3× or leave the first PR carrying an unused dependency.
    - **Option C — single omnibus PR:** rejected. Blast radius too high; a failed integration test in one service blocks merge of the other four.
    - **Option D — defer all 5 to Phase-3 alongside the remaining 11:** rejected. The five highest-business-pain sites (cancellation + advice) deserve isolated dispatcher-observation windows before the long tail.
- **Why chosen.** Option A balances reviewable diff size with constructor-expansion overhead. Each PR is independently revertable; each merge produces a distinct production observation window for one service domain (order cancellation, batch cancellation, advice lifecycle).
- **Consequences.**
    - Positive: durability + retry + idempotency for 5 high-pain OMS-notification paths; per-process-type metrics via existing `wms2.outbox.dispatched` counter; clean dispatch through unchanged dispatcher.
    - Negative: 3 PR review cycles instead of 1; 11 deferred call sites still best-effort (Phase-3 responsibility).
    - Neutral: `OmsNotificationService` remains injected in all 3 services until Phase-3 removes the last caller.
- **Follow-ups.**
    1. Phase-3 plan to migrate the remaining 11 `sendAfterCommit` callers (`ReceivingService`, `PickingService`, `PackingService`, `StockMovementService`, `CycleCountService`, etc.).
    2. Phase-3 cleanup: delete `OmsNotificationService.sendAfterCommit(...)` once caller count reaches zero.
    3. Dashboard work (SBDEV-2238-4.5 already in flight): add panels for the 5 new `processType` values to the outbox dispatcher dashboard.
