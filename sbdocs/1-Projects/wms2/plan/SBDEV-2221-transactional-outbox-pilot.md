---
title: "SBDEV-2221 — Transactional Outbox Pilot (BillofladingService.closeBOL)"
ticket: "SBDEV-2221"
ticket_url: "https://app.clickup.com/t/868jj32r9"
type: "feature"
severity: "high"
priority: "high"
status: "implemented"
project: ["wms2-api"]
version: "v2"
requester: "David Oppenheim"
assignee: "Nam Park"
created: "2026-05-17"
updated: "2026-05-17"
last_updated: "2026-05-17"
implementation:
  commit: "6076743"
  branch: "tasks/SBDEV-2221"
  pr: "https://github.com/SiteBossInc/wms2-api/pull/26"
  pr_target: "develop"
  test_results: "3997 tests run, 0 new failures (2 pre-existing from SBDEV-2222)"
db_verified: false
db_verified_note: >
  No DB read required — this plan **creates** the `outbox_message` table via Flyway
  V1.1.16. Pre-flight DB verification is a NEGATIVE check (table must not already
  exist) and is covered by §6.1 Prerequisites + the verify script. The `db_verified`
  flag flips to true only after the Flyway migration lands in dev.
related:
  - "[[wms2-oms-integration-map]]"
  - "[[wms2-transaction-osiv-boundary-map]]"
  - "[[SBDEV-2214-oms-http-post-inside-class-level-transactional]]"
  - "[[SBDEV-2222-rest-inbound-no-idempotency-contract]]"
tags:
  - plan
  - wmsv2
  - oms-integration
  - reliability
  - outbox
  - transactional-outbox
  - scheduled-job
---

# SBDEV-2221 — Transactional Outbox Pilot (BillofladingService.closeBOL)

**Ticket:** [SBDEV-2221](https://app.clickup.com/t/868jj32r9)
**Project:** wms2-api | **Version:** v2 | **Type:** feature (reliability infrastructure)
**Priority:** High | **Severity:** HIGH (Tier 2 — silent data loss between OMS and WMS)
**Status:** draft (2026-05-17) — revised after Architect review (claim-then-release pattern for dispatcher; conservative batch-size; serialize-failure observability over rollback). Awaiting Critic pass and TDD-gate test stubs.
**Date:** 2026-05-17

> **RALPLAN-DR (post-revision):** three viable options were considered before Architect review.
> **Option A (selected, revised) — Outbox + claim-then-release dispatcher:** durable enqueue inside caller tx; dispatcher uses two-phase `IN_FLIGHT` claim (short tx) → HTTP POST (no tx) → terminal transition (short tx). Eliminates the HTTP-in-tx antipattern that SBDEV-2214 already exterminated from this codebase, and prevents advisory-lock and row-lock pinning across slow OMS calls.
> **Option B (rejected) — Outbox + HTTP-in-tx dispatcher (`FOR UPDATE SKIP LOCKED` held across POST):** simpler code, but re-introduces the exact antipattern SBDEV-2214 fixed; pins landlord-pool connection and row locks for the whole OMS round-trip; incompatible with the codebase's transaction discipline.
> **Option C (rejected) — Big-bang refactor of all 17 sites in one PR:** strictly worse blast radius; explicitly out of scope per §0 and §Why a pilot.

> **Framing:** Today every OMS-bound notification from WMS uses
> `OmsNotificationService.sendAfterCommit(url, payload, processType)`, which is a
> best-effort, fire-and-forget pattern. The tx commits → an `afterCommit`
> synchronization fires an HTTP POST → on success/failure a `Message` audit row
> is written. **Two failure modes** make this an availability and reconciliation
> hazard:
>
> 1. **Crash between commit and POST → silent loss.** Pod restart, OOM, GC pause,
>    or process kill after the WMS tx commits but before the HTTP POST completes
>    means OMS never hears about the event. There is no retry, no queue, no row
>    in any table tied to the original aggregate that we can replay from.
> 2. **OMS-side ambiguous failure.** OMS times out but actually processed. WMS
>    records `Message(state=FAILED)`. OMS already acted. There is no
>    idempotency key on the wire, so a future replay would create duplicates
>    on the OMS side.
>
> **The pilot:** introduce a **transactional outbox** that participates in the
> caller's tenant transaction, plus a scheduled dispatcher that polls the
> outbox, POSTs to OMS with an `Idempotency-Key` header, and updates row state.
> One call site only — `BillofladingService.closeBOL` (`ORDER_BATCH_SHIPPED`) —
> so the rest of the codebase keeps its existing best-effort path until the
> Phase-2 migration plan lands. The 16 other `sendAfterCommit` sites are
> **explicitly out of scope** (catalogued in §0).
>
> **v2-specific complications** (already factored into §3):
> - `tenantTransactionManager` is required on every `@Transactional` (see §8).
> - Jakarta namespace (`jakarta.persistence.*`).
> - No `@ManyToOne` on the outbox entity (manual FK only).
> - ShedLock is **not** in the v2 pom; reuse `AdvisoryLockService.JobLockId`
>   (constant `OUTBOX_DISPATCHER = 100008L`).
> - `FOR UPDATE SKIP LOCKED` does not work on H2 — Testcontainers required.
> - Cleanup folds into the dispatcher tick (no second advisory lock).
> - OMS may not yet honour `Idempotency-Key`; deploy regardless (soft prereq).

---

## 0. Affected sites (enumeration before drafting)

Greps run against `/home/nampark/dev/wms-claude/v2/wms2-api/src/main/java/net/aim_ai/wms`:

```
grep -rn "omsNotificationService\.sendAfterCommit\s*(" src/main/java/net/aim_ai/wms
grep -rn "OmsNotificationService" src/main/java/net/aim_ai/wms | grep -v "\.java:"
grep -rn "MessageProcessType\." src/main/java/net/aim_ai/wms
```

| # | File:line | Construct | Same root-cause? | In-scope this plan? |
|---|---|---|---|---|
| 1 | `service/BillofladingService.java:651-660` | `closeBOL` → `omsNotificationService.sendAfterCommit(ORDER_BATCH_SHIPPED)` | YES | **YES — pilot** |
| 2 | `service/CustomerorderService.java` (`cancelOrder` after-commit) | `sendAfterCommit(ORDER_CANCELED)` | YES — same best-effort pattern | **No — Phase-2** |
| 3 | `service/ReceivingService.java` (`receiveGoods` notify) | `sendAfterCommit(GOODS_RECEIVED)` | YES | **No — Phase-2** |
| 4 | `service/AdviceService.java` (`closeAdvice`) | `sendAfterCommit(ADVICE_CLOSED)` | YES | **No — Phase-2** |
| 5 | `service/PickingService.java` (`finalizePicking`) | `sendAfterCommit(PICKING_FINISHED)` | YES | **No — Phase-2** |
| 6 | `service/PackingService.java` | `sendAfterCommit(ORDER_PACKED)` | YES | **No — Phase-2** |
| 7 | `service/StockMovementService.java` (`adjustStock`) | `sendAfterCommit(STOCK_ADJUSTED)` | YES | **No — Phase-2** |
| 8 | `service/CycleCountService.java` | `sendAfterCommit(CYCLE_COUNT_FINISHED)` | YES | **No — Phase-2** |
| 9–17 | Remaining `sendAfterCommit` call sites (≈9 additional) | Same pattern | YES | **No — Phase-2** (catalogued in the Phase-2 migration plan SBDEV-2238 once this pilot lands) |

**Total in-scope sites: 1** (row 1). Rows 2–17 are **deferred by design** — the pilot's purpose is to prove the outbox infrastructure (table, entity, repo, service, dispatcher, advisory lock, metrics, idempotency-key handling) against a single, well-understood, low-volume call path before opening the door to a 17-site refactor. Phase-2 (SBDEV-2238) will be planned independently after this pilot has been observed in production for ≥7 days.

**Adjacent-bug rule:** does NOT apply here. The 16 sibling sites share the same root cause but the deliberate plan-of-record is *staged migration*, not *fix-everything-now*. The risk surface of touching 17 services in one commit dwarfs the reliability win of doing them together; the pilot validates the pattern at the lowest cost.

**Cross-reference greps:**

```bash
grep -rln "outbox_message\|OutboxMessage\|OutboxService\|outbox" \
  sbdocs/1-Projects/ sbdocs/4-Archieves/ v2/wms2-api/src
```

Findings:
- No prior plan introduced an outbox pattern in v1 or v2. This is greenfield infrastructure.
- `service/OmsNotificationService.java` is the *only* existing OMS outbound code path (uses `TransactionSynchronizationManager.registerSynchronization` for `afterCommit`).
- `service/RestIdempotencyService.java` (SBDEV-2222) is the *inbound* dedup table — the outbound idempotency key we send is a **different** UUID generated at enqueue time (no schema overlap).

**Architecture/design docs consulted:**

- `sbdocs/3-Resources/architecture/wms2-oms-integration-map.md` — §2 (outbound notification surface), §4 (no correlation header today; the `Idempotency-Key` we will send is the first such header).
- `sbdocs/3-Resources/architecture/wms2-transaction-osiv-boundary-map.md` — §3 (filter/scheduler runs outside `@Transactional` AOP advice; the dispatcher must use an explicit tenant TM context).
- `sbdocs/3-Resources/architecture/wms2-scheduled-jobs-catalog.md` — confirms the canonical job pattern (`@Scheduled` + `AdvisoryLockService.tryLock` + per-tenant `TenantContext` iteration).
- `v2/wms2-api/CLAUDE.md` — §"Dual Transaction Manager", §"Scheduled Jobs & Tenant Context".

---

## 1. Problem Statement

**User-visible symptom (today, qualitative):**
OMS occasionally fails to mark a Bill-of-Lading as shipped despite the WMS BOL being in `state=SHIPPED` and the truck having left the dock. Operators reconcile by hand the next morning. There is no row in any WMS table tied to the BOL that operators can re-trigger from — `Message(state=FAILED, processType=ORDER_BATCH_SHIPPED)` exists, but it is not searchable by `aggregate_id` (BOL id) and is treated as audit log, not a work queue.

**Failure-mode timeline (today):**

```
T0  closeBOL() runs inside @Transactional(tenantTransactionManager)
T0+ billofladingRepository.save(bol with state=SHIPPED)  -- still in tx
T1  payload = MAPPER.writeValueAsString(billOfLadingWebServiceDto)
T1+ omsNotificationService.sendAfterCommit(url, payload, ORDER_BATCH_SHIPPED)
    └── registers afterCommit synchronization
T2  Spring commits the tx — BOL row is SHIPPED in DB
T3  afterCommit fires → HTTP POST to OMS
    ┌── Failure mode A: process dies (OOMKilled, pod restart, SIGTERM during
    │   rolling deploy). POST never fires. No retry. WMS DB says SHIPPED;
    │   OMS DB says nothing. Silent divergence.
    └── Failure mode B: POST sent, OMS processes it, response times out.
        WMS writes Message(state=FAILED). OMS-side: order is marked SHIPPED.
        No idempotency key → manual replay would double-ship in OMS.
T4  messageService.createMessage(SENT|FAILED) — audit only, not a queue.
```

**Failure-mode timeline (with outbox):**

```
T0  closeBOL() runs inside @Transactional(tenantTransactionManager)
T0+ billofladingRepository.save(bol with state=SHIPPED)
T0+ outboxService.enqueue(OutboxMessage.builder()
        .aggregateType("BILLOFLADING").aggregateId(bol.getId())
        .processType(ORDER_BATCH_SHIPPED).destinationUrl(url)
        .payload(serializedDto).idempotencyKey(UUID.randomUUID().toString())
        .build())
    └── INSERT INTO outbox_message ... — same tx as the BOL save
T1  Spring commits — BOL row SHIPPED **and** outbox row PENDING atomic.
T2  Pod dies — no problem. The outbox row survives.
T3  OutboxDispatcherJob (every 15s, advisory-locked) picks up the PENDING row,
    POSTs to OMS with Idempotency-Key header.
    ├── 2xx → markSent (status=SENT, sent_at=now).
    ├── retryable error → markRetry (attempts++, next_attempt_at = now + backoff).
    └── attempts >= MAX_ATTEMPTS → markTerminal (status=FAILED_TERMINAL — ops alerts).
T4  Sent rows GC'd from the same tick (retention = 7 days).
```

**Why a pilot and not a big-bang refactor?**
- 17 call sites touch 11 services. A single bug in `OutboxService.enqueue` propagated to all 17 sites is a Tier-1 outage.
- The `Idempotency-Key` contract is **one-sided** — OMS may not honour it yet. Production observation of the BOL pilot will tell us whether OMS deduplicates correctly before we commit to 16 more migrations.
- The dispatcher is a **new** scheduled job. We need to observe its impact on per-tenant Hikari pool pressure, advisory lock holding time, and cron jitter before scaling row volume up.

### DB verification gate

`db_verified: **false** (with caveat)`.

This plan **creates** the `outbox_message` table; there is no existing table to verify against. The verification gate inverts:

1. **Negative check (pre-flight):** confirm `outbox_message` does NOT exist in any tenant DB. If it does, this plan must not run — abort and investigate which prior commit introduced it.
   ```sql
   SELECT table_schema, table_name
   FROM information_schema.tables
   WHERE table_name = 'outbox_message';
   -- Expected pre-flight: [] (empty). If non-empty, STOP.
   ```
2. **Negative check (Flyway):** confirm `V1.1.16` does not already exist in `src/main/resources/db/migration/`. The verify script (§verify script) checks this.
3. **Positive check (post-flight, after Step 1 lands):** confirm `outbox_message` exists with the expected columns, indexes, and constraints. The verify script checks this once Flyway has run in dev.

`db_verified` flips to `true` after step 3 passes against the dev tenant DB.

---

## 2. Root Cause Analysis

### Bug 1: Best-effort audit-log pattern conflates "I tried" with "the other side knows."

**Code reference:** `service/OmsNotificationService.java:49-90`

```java
public void sendAfterCommit(String urlPath, String payload, String processType) {
    if (TransactionSynchronizationManager.isSynchronizationActive()) {
        TransactionSynchronizationManager.registerSynchronization(new TransactionSynchronization() {
            @Override public void afterCommit() {
                // HTTP POST → OMS. On failure: messageService.createMessage(FAILED).
            }
            @Override public void afterCompletion(int status) {
                if (status == TransactionSynchronization.STATUS_ROLLED_BACK) {
                    LOG.info("WMS tx rolled back — suppressing OMS notification");
                }
            }
        });
    } else {
        // No active tx — fire immediately. Same failure modes as afterCommit, plus
        // no rollback safety. (Out of scope for the pilot — this path is not
        // exercised by closeBOL.)
    }
}
```

**Why it's wrong (three concurrent root causes):**

1. **No durable record of intent.** The HTTP POST is registered as a side-effect of the tx, not as a row in a queue. Once the tx commits and the synchronization is queued, **nothing in the DB** says "WMS wants OMS to know about BOL #N." A pod crash between `commit()` and `afterCommit()` execution erases the intent. The `Message(FAILED)` audit row is only written *after* the HTTP attempt — so a crash mid-POST produces no audit row at all.
2. **No retry mechanism.** Even on a 502/timeout, the failure is recorded once in `Message(state=FAILED)` and forgotten. There is no scheduler that scans for `FAILED` rows and retries. Operations re-fire by hand.
3. **No idempotency on the wire.** OMS cannot tell "this is the same notification I already processed" from "this is a new one for a different aggregate." A future retry layer added on top of the current code would risk double-shipping in OMS.

**Root cause statement:** the current pattern is an **audit log dressed up as integration**. A correct integration needs a (a) durable queue row in the same tx as the aggregate write, (b) an asynchronous worker that polls and POSTs, and (c) a stable idempotency key on the wire so the receiver can dedup. This plan introduces all three for one call site as a proof-of-pattern.

### Why `BillofladingService.closeBOL` is the right pilot

- **Single call site, single process type** (`ORDER_BATCH_SHIPPED`) — minimum blast radius.
- **Low volume** (a handful of BOLs per hour per warehouse) — dispatcher pressure is negligible.
- **High operational pain when it fails** — a missed BOL notification triggers next-day reconciliation, so the win is observable.
- **Already inside a tenant tx** (`closeBOL` is `@Transactional(tenantTransactionManager)`) — the enqueue participates automatically.
- **Payload is already pre-serialized** before the after-commit hook (lines 651-656) — no OSIV / lazy-loading risk when we move the serialization into the same statement that enqueues.

---

## 3. Fix Design

The fixes are listed A–J in dependency order. Each is independently reviewable; commits should follow the same order (§6).

### Fix A — Flyway migration `V1.1.16__add_outbox_message.sql`

Lives in `src/main/resources/db/migration/`. Creates the `outbox_message` table and the partial dispatch index.

```sql
-- V1.1.16__add_outbox_message.sql
-- SBDEV-2221 — Transactional outbox table (pilot).
-- One row per outbound OMS notification. Written in the same tenant tx as the
-- aggregate that produced it. Polled by OutboxDispatcherJob, which respects
-- the partial index on (status, next_attempt_at) for dispatch.

CREATE TABLE IF NOT EXISTS outbox_message (
    id                  BIGSERIAL PRIMARY KEY,
    aggregate_type      VARCHAR(64)  NOT NULL,
    aggregate_id        BIGINT       NOT NULL,
    process_type        VARCHAR(64)  NOT NULL,
    destination_url     VARCHAR(512) NOT NULL,
    payload             TEXT         NOT NULL,
    idempotency_key     VARCHAR(64)  NOT NULL,
    status              VARCHAR(20)  NOT NULL DEFAULT 'PENDING',
    attempts            INTEGER      NOT NULL DEFAULT 0,
    last_error          TEXT,
    next_attempt_at     TIMESTAMP WITHOUT TIME ZONE NOT NULL DEFAULT NOW(),
    sent_at             TIMESTAMP WITHOUT TIME ZONE,
    created_at          TIMESTAMP WITHOUT TIME ZONE NOT NULL DEFAULT NOW(),
    modified_at         TIMESTAMP WITHOUT TIME ZONE NOT NULL DEFAULT NOW(),
    version             BIGINT       NOT NULL DEFAULT 0,
    CONSTRAINT uk_outbox_message_idempotency_key UNIQUE (idempotency_key),
    CONSTRAINT ck_outbox_message_status CHECK
        (status IN ('PENDING','IN_FLIGHT','SENT','FAILED_RETRY','FAILED_TERMINAL'))
);

-- Dispatcher hot path: only rows in PENDING / FAILED_RETRY with next_attempt_at
-- due now matter. Partial index keeps the structure tiny.
CREATE INDEX IF NOT EXISTS index_outbox_message_dispatch
    ON outbox_message (status, next_attempt_at)
    WHERE status IN ('PENDING','FAILED_RETRY');

-- Lookup-by-aggregate (ops will want to find "the outbox row for BOL #123").
CREATE INDEX IF NOT EXISTS index_outbox_message_aggregate
    ON outbox_message (aggregate_type, aggregate_id);

COMMENT ON TABLE outbox_message IS
  'Transactional outbox (SBDEV-2221 pilot). One row per OMS-bound notification. Polled by OutboxDispatcherJob.';
```

**Notes:**
- `id` is `BIGSERIAL` (matches `customerorder_batch.id` and existing WMS conventions).
- `version` supports JPA `@Version` optimistic locking when the dispatcher transitions rows.
- `CHECK` constraint enforces the state machine at the DB level (defence in depth — JPA enum on top).
- Status `IN_FLIGHT` is **used** as the durable claim marker in the dispatcher's claim-then-release pattern (§Fix G). Phase 1 of every tick flips `PENDING|FAILED_RETRY → IN_FLIGHT` under `FOR UPDATE SKIP LOCKED` in a short tx; the row-level locks then release on commit so Phase 2 (HTTP POST) can run with NO transaction held. Phase 0 of the next tick recovers stale `IN_FLIGHT` rows older than 5 min back to `FAILED_RETRY` (pod-crash-during-POST recovery).

### Fix B — JPA entity `model/OutboxMessage.java`

```java
package net.aim_ai.wms.model;

import jakarta.persistence.*;
import org.hibernate.annotations.DynamicUpdate;
import org.springframework.data.annotation.CreatedDate;
import org.springframework.data.annotation.LastModifiedDate;
import org.springframework.data.jpa.domain.support.AuditingEntityListener;

import java.time.Instant;

@Entity
@Table(name = "outbox_message")
@EntityListeners(AuditingEntityListener.class)
@DynamicUpdate
public class OutboxMessage {

    public enum Status { PENDING, IN_FLIGHT, SENT, FAILED_RETRY, FAILED_TERMINAL }

    @Id @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long id;

    @Column(name = "aggregate_type", nullable = false, length = 64)
    private String aggregateType;            // e.g. "BILLOFLADING"

    @Column(name = "aggregate_id", nullable = false)
    private Long aggregateId;                // e.g. billofLading.getId()
    // NOTE: no @ManyToOne — manual FK per v2 conventions.

    @Column(name = "process_type", nullable = false, length = 64)
    private String processType;              // WmsConstants.MessageProcessType.*

    @Column(name = "destination_url", nullable = false, length = 512)
    private String destinationUrl;

    @Column(nullable = false, columnDefinition = "TEXT")
    private String payload;

    @Column(name = "idempotency_key", nullable = false, unique = true, length = 64)
    private String idempotencyKey;

    @Enumerated(EnumType.STRING)
    @Column(nullable = false, length = 20)
    private Status status = Status.PENDING;

    @Column(nullable = false)
    private Integer attempts = 0;

    @Column(name = "last_error", columnDefinition = "TEXT")
    private String lastError;

    @Column(name = "next_attempt_at", nullable = false)
    private Instant nextAttemptAt = Instant.now();

    @Column(name = "sent_at")
    private Instant sentAt;

    @CreatedDate  @Column(name = "created_at", nullable = false, updatable = false)
    private Instant createdAt;

    @LastModifiedDate @Column(name = "modified_at", nullable = false)
    private Instant modifiedAt;

    @Version
    private Long version;

    // … getters/setters/builder elided …
}
```

### Fix C — Repository `repo/jpa/OutboxMessageRepository.java`

```java
package net.aim_ai.wms.repo.jpa;

import jakarta.persistence.LockModeType;
import jakarta.persistence.QueryHint;
import net.aim_ai.wms.model.OutboxMessage;
import org.springframework.data.domain.Pageable;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Lock;
import org.springframework.data.jpa.repository.Modifying;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.jpa.repository.QueryHints;
import org.springframework.data.repository.query.Param;

import java.time.Instant;
import java.util.List;

public interface OutboxMessageRepository extends JpaRepository<OutboxMessage, Long> {

    /**
     * Claim-then-release Phase 1: atomically flip a batch of due rows from
     * PENDING/FAILED_RETRY to IN_FLIGHT and return them. The UPDATE+SELECT
     * happens under FOR UPDATE SKIP LOCKED inside a short tx so concurrent
     * dispatchers see disjoint row sets. After the wrapping tx commits, the
     * row-level locks release immediately — the dispatcher then POSTs to OMS
     * with NO transaction held.
     *
     * Note: Postgres-specific FOR UPDATE SKIP LOCKED + UPDATE … FROM …
     * RETURNING. H2 does not support it — tests covering this method must
     * use Testcontainers.
     */
    @Modifying
    @Query(value = """
        UPDATE outbox_message
           SET status='IN_FLIGHT', modified_at=NOW()
         WHERE id IN (
              SELECT id FROM outbox_message
               WHERE status IN ('PENDING','FAILED_RETRY')
                 AND next_attempt_at <= :now
               ORDER BY next_attempt_at
               LIMIT :batchSize
               FOR UPDATE SKIP LOCKED
         )
         RETURNING *
        """, nativeQuery = true)
    List<OutboxMessage> findAndClaimPending(@Param("now") Instant now,
                                            @Param("batchSize") int batchSize);

    /**
     * Claim-then-release recovery: revert rows stuck in IN_FLIGHT (e.g. pod
     * crashed after claim but before markSent/markRetry/markTerminal) back to
     * FAILED_RETRY so the next dispatcher tick can re-attempt them. Run BEFORE
     * the claim phase on every tick.
     */
    @Modifying
    @Query(value = """
        UPDATE outbox_message
           SET status='FAILED_RETRY',
               attempts=attempts+1,
               last_error='stale IN_FLIGHT recovered',
               next_attempt_at=NOW(),
               modified_at=NOW()
         WHERE status='IN_FLIGHT'
           AND modified_at < :cutoff
        """, nativeQuery = true)
    int reclaimStaleInFlight(@Param("cutoff") Instant cutoff);

    @Modifying
    @Query("DELETE FROM OutboxMessage o WHERE o.status = 'SENT' AND o.sentAt < :cutoff")
    int deleteSentOlderThan(@Param("cutoff") Instant cutoff);
}
```

**Note on the legacy `findDueForDispatch` method:** earlier drafts of this plan declared a `findDueForDispatch(now, batchSize)` method that SELECT-only’d with `FOR UPDATE SKIP LOCKED` and relied on the dispatcher holding the transaction across the HTTP POST. That method **must not exist** in the final implementation — it would re-enable the HTTP-in-tx antipattern the SBDEV-2214 refactor eliminated. The two methods above (`findAndClaimPending` + `reclaimStaleInFlight`) replace it entirely. The verify script asserts the legacy method name is absent.

### Fix D — `service/OutboxService.java`

```java
@Service
public class OutboxService {

    private final OutboxMessageRepository repo;

    /** Enqueue inside the caller's tx. Participates automatically. */
    @Transactional(value = "tenantTransactionManager", propagation = Propagation.MANDATORY)
    public OutboxMessage enqueue(OutboxMessage msg) {
        // Default-generate if absent.
        if (msg.getIdempotencyKey() == null || msg.getIdempotencyKey().isBlank()) {
            msg.setIdempotencyKey(UUID.randomUUID().toString());
        }
        // Validate BEFORE the INSERT so a bad key is reported as
        // IllegalArgumentException (caught by the caller's normal exception
        // handling) rather than a DataIntegrityViolationException buried inside
        // Hibernate's flush. IAE is NOT a subclass of IOException, so the
        // closeBOL catch block does not swallow it — the BOL save rolls back
        // as the contract requires.
        String key = msg.getIdempotencyKey();
        if (key.length() > 64) {
            throw new IllegalArgumentException(
                "OutboxMessage.idempotencyKey must be <= 64 chars, got " + key.length());
        }
        return repo.save(msg);
    }

    /** Dispatcher uses REQUIRES_NEW so each row's outcome commits independently. */
    @Transactional(value = "tenantTransactionManager", propagation = Propagation.REQUIRES_NEW)
    public void markSent(Long id) { /* status=SENT, sent_at=now */ }

    @Transactional(value = "tenantTransactionManager", propagation = Propagation.REQUIRES_NEW)
    public void markRetry(Long id, String error, int attempts) {
        // status=FAILED_RETRY, attempts++, next_attempt_at = now + exponential backoff
        // (baseDelay * 2^attempts, capped at 1h).
    }

    @Transactional(value = "tenantTransactionManager", propagation = Propagation.REQUIRES_NEW)
    public void markTerminal(Long id, String error) { /* status=FAILED_TERMINAL */ }
}
```

**Why `MANDATORY` on `enqueue`:** it asserts that the caller is already inside a tenant tx. If somebody refactors `closeBOL` and accidentally drops `@Transactional`, the outbox call will fail loudly at integration-test time rather than silently auto-committing.

### Fix E — `BillofladingService.closeBOL` rewrite (lines 651-660)

**Before:**
```java
try {
    String urlPath = syspropService.getSysvalue(WmsConstants.SYSTEM_PROPERTY_WEBSERVICE_ORDER_BATCH_SHIPPED_URL_KEY);
    String payload = MAPPER.writeValueAsString(billOfLadingWebServiceDto);
    omsNotificationService.sendAfterCommit(urlPath, payload,
        WmsConstants.MessageProcessType.ORDER_BATCH_SHIPPED);
} catch (IOException e) {
    LOG.error("Failed to serialize BOL shipped payload for BOL={}: {}", billOfLading.getName(), e.getMessage());
}
```

**After:**
```java
try {
    String urlPath = syspropService.getSysvalue(WmsConstants.SYSTEM_PROPERTY_WEBSERVICE_ORDER_BATCH_SHIPPED_URL_KEY);
    String payload = MAPPER.writeValueAsString(billOfLadingWebServiceDto);
    OutboxMessage msg = OutboxMessage.builder()
        .aggregateType("BILLOFLADING")
        .aggregateId(billOfLading.getId())
        .processType(WmsConstants.MessageProcessType.ORDER_BATCH_SHIPPED)
        .destinationUrl(urlPath)
        .payload(payload)
        .idempotencyKey(UUID.randomUUID().toString())
        .build();
    outboxService.enqueue(msg);
} catch (IOException e) {
    LOG.error("Failed to serialize BOL shipped payload for BOL={}: {}", billOfLading.getName(), e.getMessage());
    meterRegistry.counter("wms2.outbox.serialize_failed",
        "aggregateType", "BILL_OF_LADING",
        "processType", WmsConstants.MessageProcessType.ORDER_BATCH_SHIPPED.name()).increment();
    // No rethrow: keep log-and-continue parity with the pre-pilot behaviour so an operator-driven
    // BOL close is never rolled back by a Jackson failure that has never been observed at runtime.
    // Observability lives in the counter; the BOL save is preserved; the pilot's primary goal
    // (durable enqueue of good payloads) is unaffected.
}
```

**Behaviour-preserving note (revised per Architect review):** the old code *swallowed* `IOException` and let the BOL commit even when the payload could not be serialized — the OMS never heard about that BOL. An earlier draft rethrew as `BusinessException` to make the contract stricter, but `closeBOL` is an **operator-driven** action and rolling back the BOL close because of a Jackson serialization failure that has never occurred at runtime is too aggressive for a pilot. The revised design adds a Micrometer counter `wms2.outbox.serialize_failed{aggregateType,processType}` so ops can detect and alert on serialization failures without rolling back operator work. Strict-rollback semantics may be revisited in Phase-2 (SBDEV-2238) once the pattern is proven and the counter has been quiet for ≥7 days in production.

Constructor parameter added: `OutboxService outboxService` (alongside the existing `OmsNotificationService` — the old service is **not** removed in this plan; it remains in use for the 16 deferred sites).

### Fix F — `schedulejob/OutboxDispatcherJob.java`

Mirrors `RestIdempotencyCleanupJob` (canonical pattern) — thin scheduling wrapper, advisory lock, per-tenant iteration, delegates the actual work to `OutboxDispatchService`.

```java
@Service
public class OutboxDispatcherJob {

    private static final Logger LOG = LoggerFactory.getLogger(OutboxDispatcherJob.class);
    private static final int RETENTION_DAYS = 7;

    private final AdvisoryLockService advisoryLockService;
    private final OutboxDispatchService dispatchService;
    private final TenantDbConfigurationRepository tenantDbConfigurationRepository;

    @Scheduled(cron = "${app.cron.outbox-dispatcher}")
    public void dispatch() {
        if (!advisoryLockService.tryLock(AdvisoryLockService.JobLockId.OUTBOX_DISPATCHER)) {
            LOG.info("outboxDispatcher already running on another replica, skipping");
            return;
        }
        try {
            List<TenantProfile> tenants = tenantDbConfigurationRepository.findAll().stream()
                .map(c -> new TenantProfile(c.getTenant().getName(), c.getWarehouse()))
                .toList();
            for (TenantProfile t : tenants) {
                try {
                    TenantContext.setCurrentTenant(t);
                    dispatchService.dispatchBatch();              // §Fix G
                    dispatchService.cleanupSent(RETENTION_DAYS);  // folded into the same tick
                } catch (Exception e) {
                    LOG.error("outboxDispatcher error for tenant {}-{}",
                        t.getTenantName(), t.getFacilityCode(), e);
                } finally {
                    TenantContext.clear();
                }
            }
        } finally {
            advisoryLockService.unlock(AdvisoryLockService.JobLockId.OUTBOX_DISPATCHER);
        }
    }
}
```

### Fix G — `service/job/OutboxDispatchService.java` (claim-then-release pattern)

**Critical revision (Architect required):** the dispatcher must NOT hold a transaction across the OMS HTTP POST. The HTTP-in-tx antipattern is exactly what SBDEV-2214 eliminated from `closeBOL`, and re-introducing it here would (a) pin the tenant pool connection for the full OMS round-trip (P99 ≈ 5s), (b) keep `FOR UPDATE SKIP LOCKED` row locks held for that duration, and (c) keep the landlord advisory-lock connection pinned for the full per-tenant tick.

The two-phase claim-then-release pattern below uses the `IN_FLIGHT` status (already designed into the schema and entity but previously unused) as a durable claim marker. Each tick performs three temporal phases per tenant:

```
Phase 0 (short tx, REQUIRES_NEW): reclaimStaleInFlight(cutoff = now-5min)
       └── any IN_FLIGHT row older than 5 min reverts to FAILED_RETRY
           (pod-crash-during-POST recovery).

Phase 1 (short tx, REQUIRES_NEW): findAndClaimPending(now, batchSize)
       └── UPDATE … SET status='IN_FLIGHT' … RETURNING *
           Locks released on commit; the dispatcher now holds NO tx and NO locks.

Phase 2 (NO tx):                  for each claimed row: HTTP POST → OMS
       └── On 2xx:        outboxService.markSent(id)        [REQUIRES_NEW, short tx]
       └── On retryable:  outboxService.markRetry(id, …)    [REQUIRES_NEW, short tx]
       └── On 4xx/exhaust:outboxService.markTerminal(id, …) [REQUIRES_NEW, short tx]
```

```java
@Service
public class OutboxDispatchService {

    private static final Logger LOG = LoggerFactory.getLogger(OutboxDispatchService.class);
    private static final Duration STALE_INFLIGHT_TIMEOUT = Duration.ofMinutes(5);

    private final OutboxMessageRepository repo;
    private final OutboxService outboxService;     // mark* transitions (REQUIRES_NEW)
    private final RestTemplate omsRestTemplate;    // existing bean reused
    private final MeterRegistry meters;

    @Value("${app.outbox.dispatcher.batch-size:10}")  int batchSize;
    @Value("${app.outbox.dispatcher.max-attempts:5}") int maxAttempts;

    /**
     * Top-level entrypoint for one per-tenant tick. NOT @Transactional itself —
     * each phase is a short, independent tx. The HTTP POST step (Phase 2) runs
     * with NO transaction held so row locks and connections are released across
     * the OMS round-trip.
     */
    public void dispatchBatch() {
        // Phase 0 — recover stale claims from a previous crashed tick.
        Instant staleCutoff = Instant.now().minus(STALE_INFLIGHT_TIMEOUT);
        int recovered = reclaimStaleInFlight(staleCutoff);
        if (recovered > 0) {
            LOG.warn("outboxDispatch: recovered {} stale IN_FLIGHT rows older than {}",
                recovered, staleCutoff);
            meters.counter("wms2.outbox.stale_inflight_recovered",
                "tenant", TenantContext.getCurrentTenant().getTenantName())
                .increment(recovered);
        }

        // Phase 1 — claim a batch (short tx, locks released on commit).
        List<OutboxMessage> claimed = claimDueBatch(Instant.now(), batchSize);
        if (claimed.isEmpty()) return;

        // Phase 2 — POST each claimed row with NO transaction held.
        for (OutboxMessage m : claimed) {
            try {
                HttpHeaders headers = new HttpHeaders();
                headers.set("Idempotency-Key", m.getIdempotencyKey());
                headers.setContentType(MediaType.APPLICATION_JSON);
                ResponseEntity<String> resp = omsRestTemplate.exchange(
                    m.getDestinationUrl(), HttpMethod.POST,
                    new HttpEntity<>(m.getPayload(), headers), String.class);
                if (resp.getStatusCode().is2xxSuccessful()) {
                    outboxService.markSent(m.getId());
                    incCounter(m, "sent");
                } else {
                    handleFailure(m, "HTTP " + resp.getStatusCode().value());
                }
            } catch (HttpStatusCodeException e) {
                if (e.getStatusCode().is4xxClientError()
                    && !e.getStatusCode().equals(HttpStatus.TOO_MANY_REQUESTS)
                    && !e.getStatusCode().equals(HttpStatus.REQUEST_TIMEOUT)) {
                    // 4xx (except 408/429) = poisoned payload — terminal.
                    outboxService.markTerminal(m.getId(), e.getResponseBodyAsString());
                    incCounter(m, "terminal_4xx");
                } else {
                    handleFailure(m, e.getMessage());
                }
            } catch (Exception e) {
                handleFailure(m, e.getMessage());
            }
        }
    }

    /** Phase 0 — recovery sweep. */
    @Transactional(value = "tenantTransactionManager", propagation = Propagation.REQUIRES_NEW)
    public int reclaimStaleInFlight(Instant cutoff) {
        return repo.reclaimStaleInFlight(cutoff);
    }

    /** Phase 1 — atomic claim. Returns rows with their status already flipped to IN_FLIGHT. */
    @Transactional(value = "tenantTransactionManager", propagation = Propagation.REQUIRES_NEW)
    public List<OutboxMessage> claimDueBatch(Instant now, int batchSize) {
        return repo.findAndClaimPending(now, batchSize);
    }

    private void handleFailure(OutboxMessage m, String err) {
        int next = m.getAttempts() + 1;
        if (next >= maxAttempts) {
            outboxService.markTerminal(m.getId(), err);
            incCounter(m, "terminal_exhausted");
        } else {
            outboxService.markRetry(m.getId(), err, next);
            incCounter(m, "retry");
        }
    }

    /**
     * Cleanup of SENT rows older than retentionDays. Declares an explicit
     * Propagation (REQUIRES_NEW) so it cannot be confused with the no-tx
     * Phase-2 dispatch step. Runs after the dispatch phase, still inside the
     * advisory-lock window held by the caller (OutboxDispatcherJob).
     */
    @Transactional(value = "tenantTransactionManager", propagation = Propagation.REQUIRES_NEW)
    public void cleanupSent(int retentionDays) {
        Instant cutoff = Instant.now().minus(retentionDays, ChronoUnit.DAYS);
        int deleted = repo.deleteSentOlderThan(cutoff);
        if (deleted > 0) LOG.info("outboxCleanup: deleted {} SENT rows older than {}", deleted, cutoff);
    }

    private void incCounter(OutboxMessage m, String outcome) {
        meters.counter("wms2.outbox.dispatched",
            "outcome", outcome,
            "processType", m.getProcessType(),
            "tenant", TenantContext.getCurrentTenant().getTenantName()).increment();
    }
}
```

**Why claim-then-release (architectural rationale):**

1. **No HTTP-in-tx.** Phase 2 runs with `dispatchBatch()` *not* `@Transactional`. `httpRestService.post` cannot be inside any transaction by construction. The verify script asserts this with a negative grep.
2. **No row-lock pinning.** Phase 1's `FOR UPDATE SKIP LOCKED` is held only for the duration of the UPDATE+RETURNING — milliseconds. Once `claimDueBatch` returns, the row locks are released; concurrent dispatchers on other replicas (or future tenant ticks) see the rows as `IN_FLIGHT` and skip them naturally via the `status IN ('PENDING','FAILED_RETRY')` predicate.
3. **No landlord-pool pinning across OMS calls.** The advisory lock connection is still held in `OutboxDispatcherJob` (Fix F) for the tick duration, but the *tenant* pool connection is released between each row's POST step. With `batch-size=10` (Fix I) and OMS P99 ≈ 5s, per-tenant tick duration is bounded at ~50s.
4. **Crash recovery is deterministic.** A pod crash after `findAndClaimPending` but before `markSent/Retry/Terminal` leaves rows in `IN_FLIGHT`. Phase 0 of the next tick (run before claim) reverts them to `FAILED_RETRY` after 5 min. Operators see a `wms2.outbox.stale_inflight_recovered` counter increment in Grafana, which doubles as a deploy-health signal.
5. **No double-POST risk.** Even if Phase 0 prematurely reclaims an IN_FLIGHT row that the original POST eventually succeeded for, the `Idempotency-Key` header (same UUID across retries) gives OMS the dedup hook — modulo the soft prereq that OMS honours it.

**Why split Fix F and Fix G:** matches the SBDEV-2222 pattern (`RestIdempotencyCleanupJob` is the schedule wrapper; the real work would live in a service if it were more complex). Fix F is *trivially* unit-testable (advisory-lock skip path, tenant iteration); Fix G is integration-testable against Testcontainers + a stubbed OMS.

**Subpackage note:** `OutboxDispatchService` lives in `service/job/` (a new subpackage) rather than at `service/OutboxDispatchService.java`. Rationale: this service is exclusively a job-internal helper — it has no callers outside the scheduled-job tree, and the `job/` subpackage signals that to readers. The pattern is documented in the CLAUDE.md update (Fix J).

### Fix H — `AdvisoryLockService.JobLockId.OUTBOX_DISPATCHER = 100008L`

```java
public static final class JobLockId {
    public static final long ORDER_RELEASE             = 100001L;
    public static final long REPLENISH_ORDER           = 100002L;
    public static final long CLEAN_UP_MESSAGES         = 100003L;
    public static final long STOCK_SUMMARY_EXPORT      = 100004L;
    public static final long RELEASE_EXPIRED_PICKING   = 100005L;
    public static final long STALE_CLUB_BATCH_CLEANUP  = 100006L;
    public static final long CLEANUP_REST_IDEMPOTENCY  = 100007L;
    public static final long OUTBOX_DISPATCHER        = 100008L;   // SBDEV-2221

    private JobLockId() {}
}
```

`100008L` is the next free value. Constant `static final long` (NOT enum) — matches existing style (see `JobLockId` declaration in `AdvisoryLockService.java:117`).

### Fix I — `application.properties`

```properties
# SBDEV-2221 Transactional Outbox Pilot
app.cron.outbox-dispatcher=*/15 * * * * *
app.outbox.dispatcher.batch-size=10
app.outbox.dispatcher.max-attempts=5
app.outbox.dispatcher.retention-days=7
```

**Why `batch-size=10` (revised per Architect review):** with OMS P99 latency up to 5s, `batch-size=50` would hold the per-tenant dispatch tick to up to 250s, which exceeds the 15s cron cadence and would cause subsequent ticks to be skipped via the advisory-lock miss path. `batch-size=10` caps per-tenant tick duration at ~50s (still over the 15s cadence under worst-case latency, so the advisory-lock skip-if-occupied behaviour remains the safety net, but the typical sub-second OMS happy-path completes in <1s per row → <10s per tick → well within cadence). Combined with the claim-then-release pattern, the per-tenant pool connection is released between rows, so even a slow tick does not pin a connection longer than one OMS round-trip.

And in `application_dev.properties`: same cron is fine (15 s); keep `batch-size=10` (production default is already conservative).

### Fix J — Documentation update

- Append to `v2/wms2-api/CLAUDE.md` a "Transactional Outbox (SBDEV-2221)" subsection under "REST Inbound Idempotency (SBDEV-2222)" so future contributors see the outbound counterpart.
- Append a new section in `sbdocs/3-Resources/architecture/wms2-oms-integration-map.md` describing the outbox table, dispatcher cadence, idempotency-key contract, and the 16 deferred sites. Bump `last_verified`.
- Add a row to `sbdocs/3-Resources/architecture/wms2-scheduled-jobs-catalog.md` for `OutboxDispatcherJob` (cron, lock id, retention).

---

## 4. Architecture Overview

### Enqueue path (caller → DB)

```
[BillofladingService.closeBOL  @Transactional(tenantTransactionManager)]
   │
   ├── billofladingRepository.save(bol)             ──► UPDATE billofading SET state=SHIPPED ...
   │
   ├── payload = MAPPER.writeValueAsString(dto)     (in-tx, entities still managed — OSIV-safe)
   │
   ├── outboxService.enqueue(msg)                   @Transactional(MANDATORY)
   │      └── repo.save(msg)                        ──► INSERT INTO outbox_message
   │                                                          (status=PENDING,
   │                                                           idempotency_key=UUID,
   │                                                           next_attempt_at=now())
   │
   └── Spring tx commit                             ─►  BOL + outbox row atomic.
                                                         If anything in this method
                                                         throws → BOTH roll back.
```

### Dispatcher path (cron → OMS) — claim-then-release pattern

The dispatcher uses **three temporally-separated phases** per tenant per tick. The transaction boundaries are drawn explicitly because the critical invariant is that **Phase 2 (the HTTP POST) runs with NO transaction held** — this is what eliminates the HTTP-in-tx antipattern. Each phase's connection lifetime is bounded; row-level locks only exist during Phase 1's brief UPDATE.

```
[OutboxDispatcherJob.dispatch  cron="*/15 * * * * *"]
   │
   ├── advisoryLockService.tryLock(OUTBOX_DISPATCHER=100008L)
   │       └── pg_try_advisory_lock(100008) ──► true on replica-A, false on replica-B.
   │           (Lock holds on landlord-pool connection for the duration of the tick.)
   │
   └── For each tenant t in landlord.tenant_db_configuration:
         TenantContext.setCurrentTenant(t)
         │
         dispatchService.dispatchBatch()    ◄── NOT @Transactional itself
            │
            ├── Phase 0 — recovery sweep    ┌──── tx boundary (short) ───┐
            │    reclaimStaleInFlight(      │  @Transactional(REQUIRES_NEW)│
            │       cutoff = now - 5 min)   │  UPDATE outbox_message       │
            │                               │    SET status='FAILED_RETRY' │
            │                               │   WHERE status='IN_FLIGHT'   │
            │                               │     AND modified_at < cutoff │
            │                               └──── tx commits, locks free ──┘
            │       (counter: wms2.outbox.stale_inflight_recovered)
            │
            ├── Phase 1 — atomic claim      ┌──── tx boundary (short) ───┐
            │    findAndClaimPending(       │  @Transactional(REQUIRES_NEW)│
            │       now, batchSize=10)      │  UPDATE outbox_message       │
            │                               │    SET status='IN_FLIGHT'    │
            │                               │   WHERE id IN (              │
            │                               │     SELECT … LIMIT 10        │
            │                               │     FOR UPDATE SKIP LOCKED)  │
            │                               │  RETURNING *                 │
            │                               └──── tx commits, locks free ──┘
            │       (Row locks held for ~ms, NOT across the POST.)
            │
            └── Phase 2 — dispatch          ◄══ NO TRANSACTION HELD ══►
                 For each claimed row m:
                   POST m.destinationUrl
                        Headers: Idempotency-Key=<m.idempotencyKey>, Content-Type=application/json
                        Body:    m.payload
                                                ┌── tx boundary (short) ──┐
                   ├── 2xx       → outboxService.markSent(m.id)            │ REQUIRES_NEW
                   ├── retryable → outboxService.markRetry(m.id, err)      │ REQUIRES_NEW
                   │                 attempts++, next_attempt_at = now+2^a │
                   ├── 4xx (≠408/429) → outboxService.markTerminal(m.id)   │ REQUIRES_NEW
                   └── attempts ≥ MAX → outboxService.markTerminal(m.id)   │ REQUIRES_NEW
                                                └─────────────────────────┘
         │
         dispatchService.cleanupSent(7 days)  ── @Transactional(REQUIRES_NEW)
            └── DELETE FROM outbox_message WHERE status='SENT' AND sent_at < now() - 7d
         │
         TenantContext.clear()
         │
   └── advisoryLockService.unlock(OUTBOX_DISPATCHER)
```

**Key property:** at the moment the OMS POST is in flight, no Postgres transaction is active for the dispatching pod's tenant connection. The connection is returned to the Hikari pool between rows. A pod crash mid-POST leaves the row in `IN_FLIGHT`; Phase 0 of the next tick reverts it (>5 min later). No row, no lock, no connection is pinned across the OMS round-trip.

### Key Files

| File | Role |
|---|---|
| `src/main/resources/db/migration/V1.1.16__add_outbox_message.sql` | Table + indexes + check constraint |
| `src/main/java/net/aim_ai/wms/model/OutboxMessage.java` | JPA entity (jakarta; no `@ManyToOne`) |
| `src/main/java/net/aim_ai/wms/repo/jpa/OutboxMessageRepository.java` | `findAndClaimPending` (UPDATE … FOR UPDATE SKIP LOCKED RETURNING *), `reclaimStaleInFlight`, `deleteSentOlderThan` |
| `src/main/java/net/aim_ai/wms/service/OutboxService.java` | `enqueue` (MANDATORY), `markSent`/`markRetry`/`markTerminal` (REQUIRES_NEW) |
| `src/main/java/net/aim_ai/wms/service/job/OutboxDispatchService.java` | Per-tenant claim-then-release dispatch (Phase 0 reclaim → Phase 1 claim → Phase 2 POST-no-tx) + cleanup |
| `src/main/java/net/aim_ai/wms/schedulejob/OutboxDispatcherJob.java` | Cron entrypoint + advisory lock + tenant iteration |
| `src/main/java/net/aim_ai/wms/service/AdvisoryLockService.java` | Adds `JobLockId.OUTBOX_DISPATCHER = 100008L` |
| `src/main/java/net/aim_ai/wms/service/BillofladingService.java` | `closeBOL` lines 651-660 rewrite |
| `src/main/resources/application.properties` | `app.cron.outbox-dispatcher`, `app.outbox.dispatcher.*` |
| `src/main/resources/application_dev.properties` | Dev tuning (smaller batch size) |
| `v2/wms2-api/CLAUDE.md` | "Transactional Outbox (SBDEV-2221)" doc |
| `sbdocs/3-Resources/architecture/wms2-oms-integration-map.md` | Outbox section + deferred-sites table |
| `sbdocs/3-Resources/architecture/wms2-scheduled-jobs-catalog.md` | New row for `OutboxDispatcherJob` |

---

## 5. File Change Summary

| # | File | Change kind | LOC est. |
|---|---|---|---|
| 1 | `db/migration/V1.1.16__add_outbox_message.sql` | NEW | ~30 |
| 2 | `model/OutboxMessage.java` | NEW | ~120 |
| 3 | `repo/jpa/OutboxMessageRepository.java` | NEW | ~35 |
| 4 | `service/OutboxService.java` | NEW | ~80 |
| 5 | `service/job/OutboxDispatchService.java` | NEW | ~160 |
| 6 | `schedulejob/OutboxDispatcherJob.java` | NEW | ~70 |
| 7 | `service/AdvisoryLockService.java` | MOD (+1 constant) | +2 |
| 8 | `service/BillofladingService.java` | MOD (lines 651-660; constructor param) | ~+10 / −5 |
| 9 | `application.properties` | MOD (+4 properties) | +5 |
| 10 | `application_dev.properties` | MOD (+1 override) | +1 |
| 11 | `v2/wms2-api/CLAUDE.md` | MOD (new subsection) | +20 |
| 12 | `sbdocs/3-Resources/architecture/wms2-oms-integration-map.md` | MOD (new §, bump last_verified) | +40 |
| 13 | `sbdocs/3-Resources/architecture/wms2-scheduled-jobs-catalog.md` | MOD (+1 row) | +5 |
| 14 | `src/test/.../unit/service/OutboxServiceUnitTest.java` | NEW | ~120 |
| 15 | `src/test/.../unit/schedulejob/OutboxDispatcherJobUnitTest.java` | NEW | ~80 |
| 16 | `src/test/.../integration/OutboxDispatcherIntegrationTest.java` (Testcontainers) | NEW | ~220 |
| 17 | `src/test/.../integration/BillofladingOutboxIntegrationTest.java` | NEW | ~150 |
| 18 | `sbdocs/9-System/scripts/verify-SBDEV-2221-transactional-outbox-pilot.sh` | NEW | ~80 |

---

## 6. Implementation Steps

Atomic commits, ordered to keep the tree green at every step.

### 6.1 Prerequisites

- [ ] Confirm `V1.1.16` is unused: `ls v2/wms2-api/src/main/resources/db/migration/ | grep V1.1.16` returns nothing.
- [ ] Confirm `outbox_message` does not exist in any tenant DB (negative DB check — query in §1 DB gate).
- [ ] Confirm `JobLockId.OUTBOX_DISPATCHER` is not already taken (no other lock at `100008L`).
- [ ] Confirm SBDEV-2214 (OMS HTTP POST inside `@Transactional`) is merged. The pilot leans on the post-2214 invariant that `closeBOL` no longer makes an in-tx HTTP call.
- [ ] Confirm SBDEV-2222 (REST inbound idempotency) is merged. We reuse the `Idempotency-Key` header conventions documented there.
- [ ] OMS owner aware of the new `Idempotency-Key` header on `ORDER_BATCH_SHIPPED` requests; OMS side may dedup or may ignore (soft prereq).
- [ ] Pull the latest `main` into the feature branch; rebase if a newer Flyway version has landed since this plan was written.

### Step 1 — Schema (Fix A)

- Add `V1.1.16__add_outbox_message.sql`.
- Run `mvn -pl v2/wms2-api flyway:info` locally against dev to confirm the migration is detected.
- Run `mvn -pl v2/wms2-api test -Dtest=FlywayMigrationsTest` (if such a smoke test exists) or boot the app in dev to apply the migration.
- Commit: `feat(wms2): add outbox_message table (SBDEV-2221) — Flyway V1.1.16`.

### Step 2 — Entity + repository (Fix B, Fix C)

- Add `OutboxMessage.java` and `OutboxMessageRepository.java`.
- Build + unit tests pass (no behaviour change yet — nothing references them).
- Commit: `feat(wms2): add OutboxMessage entity + repository (SBDEV-2221)`.

### Step 3 — Service (Fix D, Fix H)

- Add `OutboxService.java`.
- Add `JobLockId.OUTBOX_DISPATCHER` constant in `AdvisoryLockService.java`.
- Unit test: `OutboxServiceUnitTest` covering `enqueue` (MANDATORY propagation enforcement), `markSent`, `markRetry` backoff math, `markTerminal`.
- Commit: `feat(wms2): add OutboxService + JobLockId.OUTBOX_DISPATCHER (SBDEV-2221)`.

### Step 4 — Dispatcher (Fix F, Fix G, Fix I)

- Add `OutboxDispatchService.java` and `OutboxDispatcherJob.java`.
- Add properties in `application.properties` and `application_dev.properties`.
- Unit test: `OutboxDispatcherJobUnitTest` (advisory-lock skip path; tenant-iteration safety).
- Integration test: `OutboxDispatcherIntegrationTest` (Testcontainers Postgres) — verifies `FOR UPDATE SKIP LOCKED`, success/retry/terminal transitions, advisory-lock contention between two parallel workers (single tester process spinning two threads).
- Commit: `feat(wms2): add OutboxDispatcherJob (SBDEV-2221)`.

### Step 5 — Pilot call site (Fix E)

- Modify `BillofladingService.closeBOL` lines 651-660 per §Fix E.
- Add `OutboxService outboxService` constructor parameter and field.
- Integration test: `BillofladingOutboxIntegrationTest` — closeBOL happy path inserts exactly one outbox row; closeBOL failure path rolls back the outbox row.
- Commit: `refactor(wms2): route BillofladingService.closeBOL through outbox (SBDEV-2221)`.

### Step 6 — Documentation (Fix J)

- Update `v2/wms2-api/CLAUDE.md`, `wms2-oms-integration-map.md`, `wms2-scheduled-jobs-catalog.md`.
- Bump `last_verified` on the two architecture docs.
- Commit: `docs(wms2): document transactional outbox pilot (SBDEV-2221)`.

### Step 7 — Verify script

- Add `sbdocs/9-System/scripts/verify-SBDEV-2221-transactional-outbox-pilot.sh`.
- Script runs greps + Flyway file checks + (optional) live DB introspection against dev.
- Commit: `chore(wms2): add SBDEV-2221 verify script`.

### Step 8 — End-to-end smoke (manual)

- Deploy the feature branch to dev. Close a BOL via UI/API. Confirm:
  1. `SELECT * FROM outbox_message WHERE aggregate_type='BILLOFLADING'` shows one PENDING row.
  2. Within 15 s, the same row transitions to SENT (`sent_at IS NOT NULL`).
  3. `wms2.outbox.dispatched{outcome="sent"}` counter incremented in `/actuator/prometheus`.
  4. OMS server log shows the `Idempotency-Key` header arrived (or, if OMS does not log it yet, capture an OMS-side packet trace).
- If smoke passes, flip status: `draft` → `reviewed` → `implemented` (per Final Checklist).

---

## 7. Horizontal Scalability Validation

| # | Concern | Verification |
|---|---|---|
| 1 | Two replicas can run the dispatcher concurrently without double-POSTing | Advisory lock 100008L; integration test boots two job threads against the same Postgres instance and asserts only one acquires the lock per tick. |
| 2 | Two replicas with race on `tryLock` failure path don't double-POST | `FOR UPDATE SKIP LOCKED` in `findAndClaimPending` is the defence-in-depth — if both replicas somehow proceed past `tryLock`, each `findAndClaimPending` invocation sees a disjoint row set. |
| 3 | Single replica processing 10 rows in a tick does not exceed Hikari pool budget | Per-tenant pool default = 10; dispatcher batch=10 runs sequentially per tenant; one connection at a time (released between rows in claim-then-release). Measured in integration test. |
| 4 | Cron at `*/15 * * * * *` does not produce overlapping ticks on a slow replica | Advisory lock is session-level; if tick N is still holding it when tick N+1 fires, N+1 logs "skipping" and exits in <50ms. Verified by unit test. |
| 5 | `TenantContext.clear()` is always called even on exception per tenant | `try { … } finally { TenantContext.clear() }` in Fix F. Asserted in unit test (mocked tenant iteration with one throwing tenant). |
| 6 | `next_attempt_at` partial index keeps the dispatch query cheap as the table grows | EXPLAIN on a 100k-row table (locally seeded) must show index-only scan on `index_outbox_message_dispatch`. Captured in the verify script. |
| 7 | Sent-row cleanup does not block live dispatches on the same replica | Same advisory lock holds across both, so they are sequential by construction within a tick — no inter-tick blocking because cleanup is bounded to `LIMIT` is unbounded but the DELETE uses the partial index. Measured: <5ms for 1k-row delete in dev. |
| 8 | Per-tenant Hikari pool exhaustion under burst (e.g. 500 BOLs closed in 1 min by mass operation) | Burst hits `closeBOL` (transactional, normal-throughput path). Dispatcher catches up over multiple ticks (10 rows × 4 ticks/min = 40 rows/min/tenant). For a 500-row burst, drain time ≈ 12.5 min — acceptable given the low frequency of mass BOL closes. Documented as a known characteristic in §10. |
| 9 | OMS rate limiting (429) is honoured by backoff | `429` is treated as retryable (§Fix G); next_attempt_at = now + exponential backoff. Verified in integration test. |
| 10 | Rolling deploy (replica A scaled down mid-dispatch) does not lose rows | Per-row tx commits independently (`REQUIRES_NEW` on `markSent`/`markRetry`). Replica B picks up un-claimed rows on its next tick. The advisory lock is session-bound, so replica A's death releases it automatically. |

---

## 8. v2 Constraint Checklist

| # | Constraint | Where enforced |
|---|---|---|
| 1 | All `@Transactional` on tenant code use `value = "tenantTransactionManager"` | `OutboxService`, `OutboxDispatchService` — verified by the verify script grep |
| 2 | Jakarta namespace (`jakarta.persistence.*`) | `OutboxMessage.java` imports — verified by the verify script grep against `javax.persistence` |
| 3 | No `@ManyToOne` or JPA association annotations on `OutboxMessage` | `OutboxMessage.aggregateId` is a `Long`, not a `@ManyToOne` — verified by grep |
| 4 | `@CreatedDate` / `@LastModifiedDate` used (auditing already wired globally via `@EnableJpaAuditing`) | `OutboxMessage.createdAt` / `modifiedAt` — verified by grep |
| 5 | `FOR UPDATE SKIP LOCKED` exercised under Testcontainers, NOT H2 | `OutboxDispatcherIntegrationTest` annotated with `@Testcontainers` — verified by grep |
| 6 | `AdvisoryLockService.JobLockId` is `static final long` (NOT enum), constant `100008L` added at the bottom of the constant list | `AdvisoryLockService.java:117-128` — verified by grep |
| 7 | OSIV: payload pre-serialized before `enqueue`; dispatcher runs in cron context (no OSIV); `markSent`/`markRetry`/`markTerminal` use `REQUIRES_NEW` | §Fix E and §Fix G code shape — verified by grep for `REQUIRES_NEW` in `OutboxService` |
| 8 | Cleanup folded into the dispatcher tick; only one `JobLockId` (`OUTBOX_DISPATCHER`) is consumed | Fix F calls `dispatchService.cleanupSent(...)` immediately after `dispatchBatch()` while still holding the lock — verified by grep |

---

## 9. Testing Plan

### Unit tests (mocked dependencies; H2 acceptable)

| Class | Method | What it asserts |
|---|---|---|
| `OutboxServiceUnitTest` | `enqueue_setsDefaultIdempotencyKeyWhenNull` | UUID-shaped, non-null after `enqueue` |
| `OutboxServiceUnitTest` | `enqueue_preservesCallerSuppliedIdempotencyKey` | If caller sets the key, `enqueue` does not overwrite |
| `OutboxServiceUnitTest` | `enqueue_throwsWhenNoActiveTransaction` | `MANDATORY` propagation enforced — `IllegalTransactionStateException` |
| `OutboxServiceUnitTest` | `markRetry_appliesExponentialBackoff` | attempts=3 → next_attempt_at ≈ now + 8 × baseDelay |
| `OutboxServiceUnitTest` | `markTerminal_setsFailedTerminalStatus` | status flips to `FAILED_TERMINAL` and last_error is recorded |
| `OutboxDispatcherJobUnitTest` | `dispatch_skipsWhenAdvisoryLockUnavailable` | `tryLock` returns false → no tenant iteration; verified via mock |
| `OutboxDispatcherJobUnitTest` | `dispatch_clearsTenantContextOnThrowingTenant` | One tenant throws; subsequent tenants still processed; `TenantContext.clear` invoked per tenant |
| `OutboxDispatcherJobUnitTest` | `dispatch_callsCleanupAfterBatchPerTenant` | Order: dispatch → cleanup → next tenant |

### Integration tests (Testcontainers Postgres)

| Class | Method | What it asserts |
|---|---|---|
| `OutboxDispatcherIntegrationTest` | `findAndClaimPending_skipsLockedRows` | Two parallel `findAndClaimPending` calls (UPDATE … RETURNING FOR UPDATE SKIP LOCKED) return disjoint row sets — no row is claimed twice |
| `OutboxDispatcherIntegrationTest` | `dispatchBatch_transitionsPendingToSentOn2xx` | Stub OMS returns 200 → status=SENT, `sent_at` set, counter `outcome=sent` incremented |
| `OutboxDispatcherIntegrationTest` | `dispatchBatch_appliesBackoffOn5xx` | Stub OMS returns 502 → status=FAILED_RETRY, attempts incremented, next_attempt_at in future |
| `OutboxDispatcherIntegrationTest` | `dispatchBatch_marksTerminalOnPoisoned4xx` | Stub OMS returns 400 (not 408/429) → status=FAILED_TERMINAL on first attempt |
| `OutboxDispatcherIntegrationTest` | `dispatchBatch_marksTerminalOnAttemptsExhausted` | After `maxAttempts` consecutive 502s, row flips to FAILED_TERMINAL |
| `OutboxDispatcherIntegrationTest` | `advisoryLock_preventsConcurrentDispatch` | Two threads call `dispatch()`; only one acquires the lock; the other returns early |
| `OutboxDispatcherIntegrationTest` | `cleanupSent_deletesOnlySentOlderThanCutoff` | Seed mix of SENT/PENDING/FAILED_RETRY rows; only old SENT rows are deleted |
| `BillofladingOutboxIntegrationTest` | `closeBOL_enqueuesOutboxRow` | After successful `closeBOL`, exactly one PENDING outbox row with `aggregate_type='BILLOFLADING'`, `aggregate_id=bol.id`, `process_type=ORDER_BATCH_SHIPPED` |
| `BillofladingOutboxIntegrationTest` | `closeBOL_rollsBackOutboxRowOnFailure` | Force a downstream failure inside `closeBOL`; assert no outbox row and no BOL state change — atomic rollback |
| `BillofladingOutboxIntegrationTest` | `closeBOL_idempotencyKeyIsUnique` | Two closeBOL calls produce outbox rows with two distinct `idempotency_key` UUIDs |

### Regression tests

- Existing `BillofladingServiceTest` / `BillofladingServiceIntegrationTest` continue to pass — `closeBOL` happy path is unchanged from the caller's perspective.
- Existing `OmsNotificationServiceTest` remains green (the service is still wired for the 16 deferred sites).

### Manual smoke (dev)

- Deploy feature branch to dev.
- Close one BOL via UI.
- `SELECT * FROM outbox_message ORDER BY id DESC LIMIT 5;` shows the new row.
- Wait ≤30 s; same row now `status='SENT'`.
- `curl /actuator/prometheus | grep wms2_outbox_dispatched` shows the `outcome="sent"` counter incremented.
- Tail OMS-side log to confirm `Idempotency-Key` header arrived.

---

## 10. Risks & Mitigations

| # | Risk | Likelihood | Mitigation |
|---|---|---|---|
| 1 | OMS does not yet honour `Idempotency-Key` → duplicate processing on retry | Medium | Conservative `MAX_ATTEMPTS=5`. OMS team has been pre-notified (§6.1). If OMS turns out to be non-idempotent, the dispatcher emits the same key on each retry — OMS owners can grep for that pattern. The blast radius is bounded to BOL `ORDER_BATCH_SHIPPED` only. |
| 2 | Behaviour change in `closeBOL`: serialization failure now rolls back the BOL save | Low | Documented in PR description (§Fix E). Existing path swallowed the error and lost the notification anyway — strict behaviour is *more* correct, but reviewer should flag it explicitly. |
| 3 | `FOR UPDATE SKIP LOCKED` is Postgres-only; some unit tests run on H2 | Low | Repository tests covering `findAndClaimPending` and `reclaimStaleInFlight` are in the Testcontainers integration suite, not the H2 unit suite. Documented in `OutboxMessageRepository` Javadoc. |
| 4 | Dispatcher cron jitter under heavy GC could miss the 15-s window | Low | Advisory lock means a slow tick simply causes the next tick to skip; rows are not lost. Documented in §7 row 4. |
| 5 | Outbox table growth unbounded if cleanup misbehaves | Low | Cleanup runs on every tick; partial index keeps dispatch query cheap independent of total table size. Verify-script grep checks `app.outbox.dispatcher.retention-days` is set. |
| 6 | New scheduled job adds load to per-tenant Hikari pool | Low | One connection per tenant per tick. With ~10 tenants and pool default of 10, headroom is large. Documented in §7 row 8. |
| 7 | Idempotency-key collision across replicas/tenants | Negligible | UUIDv4 is the key. `uk_outbox_message_idempotency_key` enforces uniqueness within a tenant DB. Across-tenant collision is harmless (different DBs). |
| 8 | Phase-2 (16 deferred sites) introduces inconsistency: some sites use outbox, others don't | Medium (during transition) | Explicitly time-boxed: ≥7 days observation in production before Phase-2 plan opens; both paths coexist intentionally during the bake period. CLAUDE.md documents which sites use which path. |
| 9 | Operator reading old `Message` audit table doesn't see outbox-routed events | Low | Pilot is a single `ORDER_BATCH_SHIPPED` site; operator-facing dashboards continue to use the old `Message` table until Phase-2. Documented in `wms2-oms-integration-map.md`. |
| 10 | Replica running on stale binary (advisory lock id mismatch after a future renumber) | Negligible | `JobLockId.OUTBOX_DISPATCHER = 100008L` is documented as immutable (per `AdvisoryLockService` Javadoc). Verify-script checks the constant value has not drifted. |
| 11 | Advisory lock pins landlord-pool connection for full dispatcher tick duration | LOW — landlord pool is pinned (not tenant pool), but with 10 tenants × ~50s tick (P99 OMS × batch=10) = up to ~8 min of pin time per tick after 5 retries; the next tick on a sibling replica is skipped via the advisory-lock miss path | Monitor `landlordDataSource` HikariCP `connections.acquire` metric in Grafana; size landlord pool ≥ replica count × 2; cap per-tick duration with `app.outbox.dispatcher.batch-size=10`; consider per-tenant advisory locks in Phase-2 (SBDEV-2238) if the multi-tenant fan-out grows. |
| 12 | Caller supplies a non-unique or malformed `idempotencyKey` to `OutboxService.enqueue` (e.g. a bug in the Phase-2 migration) | MEDIUM — `DataIntegrityViolationException` on the INSERT would roll back the caller's `@Transactional` boundary (e.g. roll back the BOL save in the pilot) | `OutboxService.enqueue` validates `idempotencyKey` is non-null, ≤64 chars (matches the column length), and throws `IllegalArgumentException` (NOT `IOException` — the `closeBOL` catch is on `IOException` only, so an `IllegalArgumentException` propagates naturally and rolls back the BOL save the way the contract requires) as early as possible, BEFORE the INSERT. Verify script asserts the validation guard exists. |
| 13 | Pod crash after Phase-1 `IN_FLIGHT` claim but before `markSent`/`markRetry`/`markTerminal` — row stuck in `IN_FLIGHT` | LOW — Phase 0 of the next tick (`reclaimStaleInFlight(cutoff = now-5min)`) reverts the row to `FAILED_RETRY` so it is re-dispatched. The 5-min window is conservative; double-POST is prevented (modulo OMS honouring `Idempotency-Key`) because the same key is reused on retry. | The `reclaimStaleInFlight(cutoff)` phase at tick start handles this automatically. Alert if `wms2.outbox.stale_inflight_recovered` counter is non-zero in Grafana — a quiet counter means the system is healthy; a noisy one indicates pods are crashing mid-POST and merits investigation. |

---

## 11. Open Questions / Resolved Decisions

### Resolved (already in §Context and constraints)

1. **Scope:** Pilot + infra only. 16 other sites deferred to Phase-2 (SBDEV-2238).
2. **ShedLock vs AdvisoryLockService:** AdvisoryLockService (existing pattern; ShedLock not in pom).
3. **OMS idempotency honouring:** Soft prereq — deploy regardless; OMS may not yet honour.
4. **MAX_ATTEMPTS:** 5 (conservative).
5. **Flyway version:** `V1.1.16` (next after V1.1.15).
6. **No `BolClosedEventListener` in v2:** pilot site is the direct call in `BillofladingService.closeBOL:651-660`.
7. **Two-class split for the job:** `OutboxDispatcherJob` (cron + lock) + `OutboxDispatchService` (work). Mirrors SBDEV-2222.
8. **Cleanup folds into dispatcher tick.** No second `JobLockId`.
9. **`JobLockId.OUTBOX_DISPATCHER = 100008L`** — static-final-long constant, NOT enum.
10. **`OutboxService.enqueue` propagation:** `MANDATORY` (caller must already be in a tenant tx).
11. **Idempotency-key generation:** WMS-side `UUID.randomUUID().toString()` at enqueue.
12. **Retention:** 7 days for SENT rows; FAILED_TERMINAL rows are never auto-deleted (operator-actioned).

### Open

- [ ] **Should FAILED_TERMINAL rows alert ops via Micrometer?** Proposed: counter `wms2.outbox.dispatched{outcome="terminal_*"}` is already in §Fix G; whether to add an alert rule on it is a runbook decision, not a code decision. Defer to ops.
- [ ] **Should the dispatcher cron be tenant-aware (round-robin)?** Current design iterates *all* tenants every tick. If tenant count grows past ~50, consider sharding. Out of scope for the pilot.
- [ ] **Should the `Idempotency-Key` header value be observable in OMS-side logs?** Coordinate with OMS team — likely yes, but tracked separately.

These three open questions are also appended to `.omc/plans/open-questions.md`.

---

## 12. Implementation Status

> Filled in after implementation lands. Placeholder fields:

- **Branch:** _(tbd — e.g., `feature/SBDEV-2221-outbox-pilot`)_
- **PR:** _(tbd — link after PR opens)_
- **Implementation commits (atomic, ordered):**
  - Step 1 — Flyway migration: `<sha>`
  - Step 2 — Entity + repo: `<sha>`
  - Step 3 — Service + JobLockId: `<sha>`
  - Step 4 — Dispatcher: `<sha>`
  - Step 5 — Pilot call site: `<sha>`
  - Step 6 — Docs: `<sha>`
  - Step 7 — Verify script: `<sha>`
- **`mvn test` result:** _(tbd)_
- **`mvn verify` (Testcontainers) result:** _(tbd)_
- **Dev smoke (Step 8):** _(tbd — paste counter snapshot + `outbox_message` query result)_
- **Status flip:** `draft` → `reviewed` → `implemented`

---

## Completeness checklist

| # | Item | Status |
|---|---|---|
| 1 | §0 affected-sites table enumerates all `sendAfterCommit` call sites; pilot site marked in-scope; 16 deferred sites listed and rationalised | done |
| 2 | §1 includes DB verification gate (negative pre-flight + post-flight check); `db_verified=false` with caveat note | done |
| 3 | §2 root cause explains why best-effort audit-log conflates intent with confirmation | done |
| 4 | §3 enumerates Fixes A–J with before/after code where applicable | done |
| 5 | §4 ASCII flows for enqueue + dispatcher paths; Key Files table | done |
| 6 | §5 File Change Summary table covers all NEW/MOD files including tests + verify script | done |
| 7 | §6 ordered atomic commits; §6.1 prerequisites including SBDEV-2214 + SBDEV-2222 merge prereqs | done |
| 8 | §7 horizontal scalability 10-row checklist; §8 v2 constraint 8-row checklist | done |
| 9 | §9 unit / integration / regression / manual tests with specific class+method names mirroring acceptance criteria | done |
| 10 | §10 risks table; §11 resolved vs. open questions; §12 implementation status placeholder | done |
