---
title: "SBDEV-2961 — Order release silently drops orders whose client has no Section"
ticket: "SBDEV-2961"
ticket_url: "https://app.clickup.com/t/868krfj4n"
type: bugfix
priority: medium
status: implemented
gate_waiver: "ralplan Critic sign-off was NEVER run — skipped twice on explicit user instruction (2026-08-14). Two independent lanes (oh-my-claudecode:critic, :architect) reviewed r1 and r2 instead; critic returned APPROVE WITH CHANGES on r2 and all findings were applied in r3. r3 itself is unreviewed. wms-plan-executor Phase 0 gate 1 was waived by the user, not satisfied."
project: [wms2]
version: v2
requester: nam.park@siteboss.net
reviewers: "architect-2961 (design, A–G), critic-2961 (plan, 10 claims)"
created: 2026-08-14
updated: 2026-08-14
db_verified: true
revision: "r3 — implemented 2026-08-14 (api 4f578ac, web-ui 1bc8018), local commits, not pushed. Second review round applied. r1 wrote from inside a readOnly tx (silent no-op); r2's Fix E rationale was false and its CAS window too wide."
related:
  - "../../../3-Resources/reports/260814-hydra-uat-three-flow-qa-triage.md"
  - "[[wms2-state-machine-catalog]]"
  - "[[wms2-scheduled-jobs-catalog]]"
  - "[[wms2-transaction-osiv-boundary-map]]"
  - "[[wms2-picking-workflow]]"
tags:
  - plan
  - bugfix
  - wms2
  - order-release
  - observability
  - state-machine
---

# SBDEV-2961 — Order release silently drops orders whose client has no Section

**Ticket:** [SBDEV-2961](https://app.clickup.com/t/868krfj4n)
**Project:** wms2 | **Version:** v2 (`v2/wms2-api` + a 2-file `v2/wms2-web-ui` regression guard) | **Type:** bugfix
**Priority:** Medium — no data corruption, but an indefinite silent workflow stall
**Status:** r2 draft, review-mandated changes applied
**Date:** 2026-08-14 | **Branch:** `feature/SBDEV-2961-order-release-silent-section-exclusion`

## Revision history — read this before implementing

**r1 was REJECTED in review.** Its Fix B called `customerorderRepository.save()` from
`OrderReleaseJob.processOrderGroup`, which runs inside `ReleaseOrderJobService.streamOrderPositionsForEach`'s
`@Transactional(readOnly = true)` boundary (`:777-783`, via `stream.forEach(consumer)`). `SimpleJpaRepository.save`
is `REQUIRED`, so it **joins** that read-only transaction — flush mode MANUAL, the UPDATE discarded with no error.
And because `OrderReleaseJob:167-171` processes the **last** buffered group *after* the streaming call returns
(outside any transaction), the last order would stamp while every earlier one silently did not.

r1's mock-based unit tests and grep-based verify script would both have certified that build as working —
reproducing the exact class of failure this ticket exists to kill. The existing writer, `releaseOrder`, uses
`REQUIRES_NEW` (`:119-121`) **precisely** to escape this boundary; r1 dropped the one mechanism that makes it work.

r2 replaces the read-modify-write with a **single-statement CAS on a `REQUIRES_NEW` service method**. That removes
`OptimisticLockRetry`, the `Integer` unboxing question, and both new unchecked throw paths from the design.

| r2 change | Source |
|---|---|
| Fix B redesigned as CAS in `REQUIRES_NEW` | critic — High |
| Fix E added: `order_imported` dashboard bucket | architect — blocker |
| Pre-round guard at `:188` must exclude state 45 | critic — Med (self-heal only partly worked) |
| Metric split into transition + per-tick meters | architect — always-red alert |
| Guard reads the section of `co.client_id` | architect (conflict resolved — see §3.2.3) |
| Fix A2 rationale rewritten as hygiene | architect — premise factually false |
| 3 existing test classes must be fixed; `mvn test-compile` added | critic — High |
| `mvn_test_passes` was permanently red; helper bug | critic — High |

**r3 — second review round.** Architect: *mechanics sound, verdict "sound enough to write failing tests
against"*. Critic: **APPROVE WITH CHANGES**, 13 findings. Both reviewers independently flagged the same
performance defect, which is why it is treated as required rather than optional.

| r3 change | Source |
|---|---|
| CAS sets `co.modified` explicitly — bulk JPQL bypasses `AuditingEntityListener` | architect |
| CAS window narrowed from `state < 200` to an allow-list `IN (:raw, :futurePickingDate)` — the wide form relabels hold states 50/55-58 as 45 and destroys the stock diagnosis | critic |
| Guard short-circuits on `orderStatus == 45` before the CAS — otherwise a `REQUIRES_NEW` tx per section-less order **per tick** (~110/min), not per transition | **both, independently** |
| §3.5 Fix E demoted from "blocker" to hygiene — the `order_imported` bucket is **never rendered** by either UI | architect (retracting its own r1 finding) |
| §6.2 warm-map test respecified — `itemDataFixAssignmentMap` cannot be pre-warmed from a unit test; warm `itemDataAvailableAmountMap` and assert `times(2)` | critic |
| `@Version` trade-off rationale corrected — the racer is entity `save()` via `setPickingDate:227→274`, not another bulk update | critic |
| STRICT_STUBS trap on `OrderReleaseJobTest` (`BaseUnitTest.java:18`) — use `lenient().when(...)`, never class-level LENIENT | critic |
| `TransactionManagerArchTest.java:48-67` cited as a machine gate on §8.5 row 2 | critic |
| `updatableState`/`disableUpdate` are dead code — strengthens §0 row 16 | critic |
| §0 row 23 added: `FUTURE_PICKING_DATE` is a reachable inbound state for the guard | critic |
| `25006` note — dropping `REQUIRES_NEW` now fails loudly, not silently | architect |
| Script: comment-filtered `preceded_by`, bounded `followed_by` replacing the brace slice, `, Skipped: 0` on the Maven regex, `final long` tolerance | critic (3 false-greens) |
| Vacuous `verifyNoInteractions` test replaced | critic — Med |

---

## 0. Affected sites (enumeration)

| # | File:line | Construct | Same root cause? | In scope? |
|---|---|---|---|---|
| 1 | `repo/jpa/CustomerorderPositionRepository.java:88` | `AND sec.id is not null` in `streamOrderReleaseInfo` — the live release query | **yes — the defect** | **yes** (A1) |
| 2 | `repo/jpa/CustomerorderPositionRepository.java:62` | same predicate in `getOrderReleaseInfo`, `@RestResource`-exposed at `:43` | yes | **partial** (A2 — additive alias only, filter retained; §3.1) |
| 3 | `repo/projection/OrderReleaseInfoView.java:8-18` | shared projection, no section field | enabling | **yes** (A3) |
| 4 | `schedulejob/OrderReleaseJob.java:177-296` | `processOrderGroup` — no section branch | yes | **yes** (B) |
| 5 | `schedulejob/OrderReleaseJob.java:188` | `if (orderStatus > RAW)` pre-round gate | **consequence of B** | **yes** (B3 — §3.2.4) |
| 6 | `service/job/ReleaseOrderJobService.java` (new method) | no `REQUIRES_NEW` writer for state 45 | enabling | **yes** (B1) |
| 7 | `repo/jpa/CustomerorderRepository.java` (new method) | no CAS update for state 45 | enabling | **yes** (B1) |
| 8 | `schedulejob/JobMetrics.java:47-49` | `rowsProcessed` pattern; no skip counters | enabling | **yes** (C) |
| 9 | `repo/jpa/OrderMonitorViewRepository.java:24,109,198,284` | `order_imported` = `co.state = 0` **exactly**, ×4 | **consequence of B** | **yes** (E) |
| 10 | `db/migration/V2.2.00__base_v2_schema.sql:1702` | the same bucket inside `order_monitor_view`, HAL-reachable via `@RepositoryRestResource(path="orderMonitorView")` (`OrderMonitorViewRepository.java:15-16`, `RestConfiguration.java:40`) | consequence of B | **no** — decision 2026-08-14: Java queries only, divergence documented (§3.6, §5.1) |
| 11 | `unit/schedulejob/OrderReleaseJobTest.java:170,216,227,345,356` | 5 × `mock(OrderReleaseInfoView.class)` rows fed via `.accept(` → `getSectionId()` returns null → the new guard fires → `:200`/`:254`/`:333+` assertions fail | breaks on B | **yes** (T1) |
| 12 | `unit/schedulejob/OrderReleaseJobStreamingTest.java` | constructs the job but feeds **zero** rows | no | **no** — guard never fires; **no ctor change in r3** |
| 13 | `unit/schedulejob/OrderReleaseJobMetricsUnitTest.java` | same; also asserts meters individually, never an exhaustive set, so two new counters cannot break it | no | **no** |
| 13a | `unit/schedulejob/OrderReleaseJobUnitTest.java` | never constructs `OrderReleaseJob` | no | **no** — enumerated for completeness |
| 14 | `wms2-web-ui/components/outbound/pickPack/openParcels.vue:336-341` | `updatablePickingDate` omits `'No Section'` | consequence of B | **yes** (D) |
| 15 | `wms2-web-ui/components/outbound/pickPack/parcelDetails.vue:216-221` | same list, second copy | consequence of B | **yes** (D) |
| 16 | `wms2-web-ui/components/outbound/pickPack/openParcels.vue:329-333` | `updatableState` — omits `'Created'` today | no | **no** — genuinely unchanged, and for a stronger reason than "no behaviour change": `updatableState` is **dead code**. Its only caller is `disableUpdate` (`:323-328`), which appears nowhere in the template. **Do not** add `'No Section'` here to "complete" Fix D |
| 17 | `service/CustomerorderService.java:256` | `state > RAW && state < RESERVED` — false at 0, **true at 45** | consequence of B | **no** — benign and desirable: a picking-date change now resets 45 → `RAW`/`80`, which is the operator remedy Fix D re-enables (§3.4) |
| 18 | `service/job/ReleaseOrderJobService.java:604` | `orElseThrow("Section not configured…")` | yes — unreachable fallback | **no** — keep as defence-in-depth for any future caller bypassing B |
| 19 | `service/job/ReleaseOrderJobService.java:246`, `:581` | SBDEV-1656 healing reads | yes — dead reads | **no** — B makes them reachable for the first time (§8.2) |
| 20 | `service/WmsConstants.java:31`, `:134` | constant + `getCodeText` → `"No Section"` | yes | **no** — already correct |
| 21 | `wms2-web-ui/util/constantValues.js:112` | `{ name: 'No Section', code: 45 }` | — | **no** — already present; **must not be removed** (§8.3) |
| 22 | `v1/wms-api` `CustomerorderPositionRepository.java:61`, `ReleaseOrderJobService.java:189,461` | identical defect in v1 | **yes — identical** | **no** — v1 explicitly out of scope (§4) |
| 23 | `service/OrderBatchCreationService.java:167` (+ positions `:202`) | sets `FUTURE_PICKING_DATE (80)`; such an order enters the stream once its date arrives (80 < 200) | **inbound state the guard must handle** | **yes — covered** by the CAS allow-list (§3.2.2): 80 is markable, hold states 50/55-58 are not |

**Predicate sweep is complete and independently confirmed:** `sec.id is not null` occurs at exactly two places in
all of `v2/wms2-api/src/` (rows 1-2). Every other `section` join in the tree — `OrderMonitorViewRepository`,
`ReplenishorderRepository`, `ReplenishmentMonitorViewRepository`, `PickingorderRepository` — does **not** filter on
it, so stamped orders stay visible in range-keyed consumers (`CustomerOrderController.java:164`,
`ViewDtoService.java:276,318,374`). That visibility is the fix's whole premise; treat it as load-bearing.

---

## 1. Problem Statement

A Pick & Pack order whose client has `section_id = NULL` is never released and never generates a picking order.
It sits at `state = 0` (`RAW`) indefinitely with **no error, no state marker, and no log line** — visually
indistinguishable from an order that just arrived.

### 1.1 How it surfaced

Ibrar (QA), Hydra UAT, 2026-08-12: *"I created a Pick & Pack batch and received it under Outbound → Pick & Pack,
but the system is not generating the picking orders."* Triage:
[260814-hydra-uat-three-flow-qa-triage.md](../../../3-Resources/reports/260814-hydra-uat-three-flow-qa-triage.md) §1.

The investigation first chased a dead cron lane — the natural hypothesis, and wrong. **That misdirection is the
bug**: the defect emits no signal distinguishing it from any other cause.

### 1.2 DB verification (`db_verified: true`)

Read-only SQL against Hydra UAT `wh01_hydra_v2` (Flyway head `2.2.16`). The production query, run twice,
identical except line 88:

| Run | `001833-000001`, `001834-000001` returned? |
|---|---|
| Production query verbatim | **No** — 0 rows |
| Only `AND sec.id is not null` removed | **Yes** — both, `Alquimista Cellars`, `section_id = NULL` |

All other predicates pass: `state = 0 < 200`; `pickingdate` 2026-08-11/12 ≤ today; `type = 'PICK_PACK'`.

**Cron independently confirmed alive** — `StockSummaryExportJob` wrote `message` rows at `2026-08-14 00:03 UTC`;
section-having orders advance to state 50. Gating sysprops all on (`NEW_CRON_JOB_ACTIVATED`,
`ORDER_TIMER_ACTIVATED`, `ORDER_TIMER_HOUR/MINUTE = *`).

### 1.3 Blast radius

| Hydra UAT | Count |
|---|---|
| Clients | 138 |
| …`section_id = NULL` | **118** |
| …of those, with SKUs loaded | **110** |
| …ever had a batch / in last 180 d | 4 / 1 |

Backfill of the 118 is **[SBDEV-2963](https://app.clickup.com/t/868krfv18)** — independent, parallel-safe.

### 1.4 Reproduction

1. Client with `section_id IS NULL`. 2. `PUT /rest/order/create` a `PICK_PACK` batch, `pickingdate <= today`.
3. Wait one tick (1 min on UAT). 4. Order stays `state = 0`; no picking order, no log, no UI signal.

---

## 2. Root Cause Analysis

| # | File | Line | Description |
|---|---|---|---|
| 1 | `repo/jpa/CustomerorderPositionRepository.java` | 88 | `AND sec.id is not null` excludes the order from the release stream |
| 2 | `schedulejob/OrderReleaseJob.java` | 177-296 | `processOrderGroup` never sees the row → nothing stamps a state |
| 3 | `service/job/ReleaseOrderJobService.java` | 604 | the only "no section" error path — unreachable from the cron |
| 4 | `schedulejob/OrderReleaseJob.java` | 292-295 | that error, if raised, is swallowed behind a `showLog` gate |

### 2.1 Bug 1 — the release query filters the order out

`CustomerorderPositionRepository.java:70-90`, the query behind
`ReleaseOrderJobService.streamOrderPositionsForEach` (`:778-784`):

```java
" LEFT JOIN customerorder_batch cob ON co.orderbatch_id = cob.id " +
" LEFT JOIN client                  ON cob.client_id = client.id " +
" LEFT JOIN section sec             ON client.section_id = sec.id " +
" WHERE co.state < :state " +
" AND co.pickingdate <= CAST(:pickingDate AS date) " +
" AND cob.type = :orderBatchType " +
" AND sec.id is not null " +          // ← line 88
```

**Client-axis note (corrected in r2).** The chain joins **`cob.client_id`** (the *batch's* client), while
`releaseOrder` resolves the section it actually needs from **`co.client_id`** (`ReleaseOrderJobService.java:601`,
`order.getClientId()`). These are populated from two independent payload fields
(`OrderBatchCreationService.java:81` vs `:152`). r1 warned against "fixing" this; that warning was backwards —
see §3.2.3.

### 2.2 Bug 2 — nothing writes `CLIENT_HAS_NO_SECTION (45)`

`WmsConstants.java:31` defines it, `:134` renders it `"No Section"`. **No code path assigns it.** Every
reference is a read: `WmsConstants.java:31`/`:134`, and `ReleaseOrderJobService.java:246`/`:581` (healing
conditions). The state is structurally unreachable, so the order keeps the value it arrived with.

### 2.3 Bug 3 — the one error path is unreachable, and silent anyway

`ReleaseOrderJobService.java:601-604`:

```java
Section section = clientRepository.findById(orderClientId)
    .filter(client -> client.getSectionId() != null)
    .flatMap(client -> sectionRepository.findById(client.getSectionId()))
    .orElseThrow(() -> new BusinessException("Section not configured for order=" + orderNumber));
```

Unreachable (Bug 1 removes the row first), and silent even if reached — `OrderReleaseJob.java:292-295` catches
`BusinessException` and logs only under `basicService.showLog()`, which is `false` on UAT and prod.

The section is **genuinely required** (`pickingOrder.setSectionId(section.getId())`, `:607`). There is no
"release without a section" option, which is why the fix is *detection*, not *tolerance*.

### 2.4 Archaeology — designed, never implemented

`git log -S "CLIENT_HAS_NO_SECTION" -- src/main/java` returns exactly two commits:

| Commit | Date | What it did |
|---|---|---|
| `a685e07b` | — | `initial checkin` — constant arrives with **no writer** |
| `d6f28cbf` | 2025-10-28 | **SBDEV-1656** — *added* the healing reads at `:246`/`:581` |

SBDEV-1656's message: *"the state transition logic only checked for exact equality to RAW … which excluded orders
in FUTURE_PICKING_DATE (80) and CLIENT_HAS_NO_SECTION (45) states."* The author assumed 45 was reachable. It never
was, so that half of the commit has been dead code since it landed.

Two independent layers already model the state:
`wms2-state-machine-catalog.md:54` (*"Blocked — tenant has no section configured"*) and `:107`
(`CLIENT_HAS_NO_SECTION(45) ◄──── stuck`); and `wms2-web-ui/util/constantValues.js:112`.
Hence *become the writer*, not *delete the constant*.

---

## 3. Design / Proposed Fix

**Shape:** select these orders instead of filtering them out; branch **before** `releaseOrder`; transition the
state with a single atomic CAS in its own transaction; warn once; count every tick; skip.

### 3.1 Fix A — surface the section in the release query

**A1 — `streamOrderReleaseInfo` (`:70-90`):** add the alias, drop the filter, re-point the client join (§3.2.3).

```diff
-        "i.item_nr " +
+        "i.item_nr, " +
+        "sec.id AS sectionId " +
         "FROM customerorder_position cop " +
         …
-        " LEFT JOIN client                  ON cob.client_id = client.id " +
+        " LEFT JOIN client                  ON co.client_id = client.id " +
         " LEFT JOIN section sec             ON client.section_id = sec.id " +
         …
-        " AND sec.id is not null " +
         " ORDER BY co.prio DESC, co.created ASC, co.id ASC, cop.number ASC ", nativeQuery = true)
```

**`ORDER BY` must not change** — the `co.id ASC` tiebreaker is load-bearing for `OrderReleaseJob`'s
break-detection grouping (`:157-171`), as the comment at `:66-68` states.

**A2 — `getOrderReleaseInfo` (`:43-64`): add the alias, KEEP the filter, KEEP its `cob.client_id` join.**

r1 justified this as preventing a latent 500 on the `@RestResource`-exposed HAL endpoint. **That premise is
false.** Verified against the jars in review: `spring-data-jpa-3.5.7`
`AbstractJpaQuery.TupleConverter.TupleBackedMap.get()` catches `IllegalArgumentException` and **returns `null`**
for an unknown alias; `spring-data-commons-3.5.7` `MapAccessingMethodInterceptor.invoke()` is a plain
`map.get(...)`. So `getSectionId()` over the list query would simply return `null`.

A2 is therefore **hygiene, not a correctness requirement**: one additive column so the pair stays readable. Its
verify rows are **advisory, not mandatory** (§9.1). Two r1 claims corrected: the queries are **not** "structurally
parallel" — the list variant's `ORDER BY` at `:63` already lacks `co.id`, and **restoring parity there would be
wrong** — and the rejected sub-interface alternative was rejected for a reason that also does not exist.

The list variant has **no v2 Java caller** (only v1's `OrderReleaseJob.java:69`) and no UI caller;
`OrderReleaseJobStreamingTest` exists to assert it stays dead. **Deleting it is the better long-term move** but
removes public HAL surface — follow-up ticket, not this one. Its result set must not change.

**A3 — `OrderReleaseInfoView.java`:**

```diff
     String getItemNr();
+    /** section.id of the order's client; null ⇒ no Section configured (SBDEV-2961). */
+    Long getSectionId();
```

### 3.2 Fix B — CAS the state in its own transaction, warn once, count, skip

#### 3.2.1 Why r1's approach could not work

`processOrderGroup` executes **inside** `streamOrderPositionsForEach`'s `@Transactional(readOnly = true)`
boundary (`:777-783`, `stream.forEach(consumer)`; consumer supplied at `OrderReleaseJob:157-166`). A
`REQUIRED` repository write joins that transaction and is discarded unflushed. The tail group at
`OrderReleaseJob:167-171` runs *outside* it, so exactly one order per tick would have stamped — a partial
success perfectly shaped to fool a 2-row manual test.

**Any write on this path must be `REQUIRES_NEW`.** That is why `releaseOrder` is (`:119-121`).

Confirmed mechanics (reviewed against code, not assumed): `tenantTransactionManager` is a `JpaTransactionManager`
over `HibernateJpaVendorAdapter` (`TenantDatabaseConfig.java:47-51,75-79`), so `prepareConnection` defaults to
`true` and the outer read-only transaction really does call `Connection.setReadOnly(true)` on **its own**
connection alongside `FlushMode.MANUAL`. `REQUIRES_NEW` suspends that EntityManager *and* its `ConnectionHolder`
and opens a fresh one; the new definition has `isReadOnly() == false`, and there is **no read-only propagation at
pool or routing level** — `grep -rn "setReadOnly|isReadOnly()" src/main/java` returns zero hits, and
`createHikariPool` (`TenantDynamicRoutingDataSource.java:79-100`) sets no `readOnly` property.

**Silver lining worth knowing:** because bulk JPQL is immediate `executeUpdate()` SQL rather than a deferred
flush, r2 is *structurally* immune to the trap that killed r1. If a future implementer "simplifies" B2 by
dropping `REQUIRES_NEW`, PostgreSQL raises **`25006 cannot execute UPDATE in a read-only transaction`** — a
**loud** failure, not a silent one. It would still be destructive, though: the exception propagates into the
per-tenant `catch` at `OrderReleaseJob:108-111` and abandons the rest of that tenant's orders for the tick.
Loud beats silent; neither is acceptable. Keep `REQUIRES_NEW`.

#### 3.2.2 The design

**B1 — CAS repository method** (`repo/jpa/CustomerorderRepository.java`):

```java
@Modifying
@Query("UPDATE Customerorder co SET co.state = :noSection, co.modified = CURRENT_TIMESTAMP "
     + "WHERE co.id = :id AND co.state IN (:raw, :futurePickingDate)")
int markClientHasNoSection(@Param("id") long id,
                           @Param("noSection") int noSection,
                           @Param("raw") int raw,
                           @Param("futurePickingDate") int futurePickingDate);
```

Two details in that statement are load-bearing:

> ⚠ **LANDMINE, found by code review — `CURRENT_TIMESTAMP` here is only instant-correct because
> `customerorder.modified` is `timestamp **with** time zone`** (`V2.2.00:756`, confirmed against the live
> DB). Had the column been `timestamp without time zone`, the per-connection `SET timezone = '<warehouse>'`
> (`TenantDynamicRoutingDataSource:112`) would write **warehouse-local wall clock** while the auditing
> listener writes UTC — a silent −7h skew on the LA tenants, destroying exactly the forensic value this
> field is being set for. **Do not change the column type, and do not switch to `LOCALTIMESTAMP`.**

**`co.modified = CURRENT_TIMESTAMP` is not cosmetic.** `AbstractBaseEntity` carries
`@EntityListeners(AuditingEntityListener.class)` (`:16`) and `@LastModifiedDate private LocalDateTime modified`
(`:31-32`). Bulk JPQL **bypasses the auditing listener**, so without this the row would keep its pre-stamp
timestamp — leaving no per-row evidence of *when* an order was marked, which is exactly the breadcrumb manual
test §6.4 #6 and any later forensic query depend on.

**The state window is an explicit allow-list, not `< :assigned`.** An earlier draft used
`state < :assigned AND state <> :noSection`, which is too wide in both directions:

| State the order could be in | Under `< 200` | Under `IN (raw, futurePickingDate)` |
|---|---|---|
| `RAW (0)` | marked ✅ | marked ✅ |
| `FUTURE_PICKING_DATE (80)` — reachable via `OrderBatchCreationService.java:167`, enters the stream once the date arrives (80 < 200) | marked ✅ | marked ✅ |
| `RAW_ON_HOLD` / `55`-`58` — reachable if a section is **removed** from a client whose orders already carry a stock hold | **relabelled 45, destroying the stock-hold diagnosis** ❌ | left alone ✅ |
| `CLIENT_HAS_NO_SECTION (45)` | no-op via `<>` | no-op (not in the list) |

An order already in a hold state therefore **keeps its hold state** and is surfaced only by the per-tick counter,
not by a state change — deliberate, because overwriting `RAW_ON_HOLD (55)` with 45 would replace one true
diagnosis with another and lose the first. Positions of an 80-order stay at 80; `releaseOrder` heals
positions `> RAW` back to `RAW` once a section exists.

**B2 — `REQUIRES_NEW` service method** (`service/job/ReleaseOrderJobService.java` — already injects
`customerorderRepository`; a `@Transactional` on the *job* class is forbidden, §8.5 row 2):

```java
/** SBDEV-2961. Returns 1 on transition, 0 if already marked or no longer eligible. */
@Transactional(value = "tenantTransactionManager", propagation = Propagation.REQUIRES_NEW)
public int markClientHasNoSection(long orderId) {
    return customerorderRepository.markClientHasNoSection(
        orderId,
        WmsConstants.State.CLIENT_HAS_NO_SECTION,
        WmsConstants.State.RAW,
        WmsConstants.State.FUTURE_PICKING_DATE);
}
```

**B3 — the guard** in `processOrderGroup`, after the existing `orderStatus >= ASSIGNED` return (`:184-186`):

```java
if (order.get(0).getSectionId() == null) {
    jobMetrics.tenantOrdersSkippedNoSection(tenantName, 1);          // every tick — standing volume
    if (orderStatus != null && orderStatus == WmsConstants.State.CLIENT_HAS_NO_SECTION) {
        return;                                                      // already marked — see below
    }
    if (releaseOrderJobService.markClientHasNoSection(customerOrderId) == 1) {
        jobMetrics.tenantOrdersMarkedNoSection(tenantName, 1);       // transitions — the alert
        LOG.warn("order={} (id={}) not released: the client of its batch has no Section configured; "
               + "marked CLIENT_HAS_NO_SECTION({})", orderNumber, customerOrderId,
                 WmsConstants.State.CLIENT_HAS_NO_SECTION);
    }
    return;                                                          // MUST return — §3.2.5
}
```

**The `orderStatus == 45` short-circuit is a cost fix, not a semantic one** — both reviewers flagged it
independently. Without it the CAS is invoked for **every section-less order on every tick**, not once per
transition: a no-op `UPDATE` wrapped in a full suspend / acquire-connection / begin / commit / resume cycle,
once per minute per stalled order. At 110 candidate clients that is ~110 needless transactions a minute against
a tenant pool (default size 5, `TenantDynamicRoutingDataSource.java:86`) that is *already* holding the streaming
cursor's connection open for the whole tick.

Behaviour is identical: `orderStatus` comes from the cursor snapshot taken at stream open under READ COMMITTED,
so a snapshot of 45 means the CAS would have matched nothing and returned 0 anyway. The per-tick counter stays
**outside** the short-circuit so standing volume is still reported.

`tenantName` is threaded from `doCalculation`'s loop through `releaseOrders(...)` into `processOrderGroup`
rather than re-read from the `TenantContext` ThreadLocal.

Why CAS wins over read-modify-write:

- **Atomic** — `WHERE … state IN (:raw, :futurePickingDate)` *is* the transition-only guard. No lost-update window.
- Drops `OptimisticLockRetry`, the `Integer` unboxing question, and **both** new unchecked throw paths
  (`OptimisticLockRetryException`, `NoSuchElementException`) that would otherwise escape `processOrderGroup` into
  the per-tenant `catch` at `:108-111` and **abandon the rest of that tenant's orders for the tick**.
- `rows == 1` is an exact transition signal, so the WARN cannot double-fire.

**Accepted trade-off — right decision, and the earlier rationale for it was wrong.** Bulk JPQL does not bump
`@Version`, so a concurrent **entity-based** `save()` holding a snapshot taken before the CAS overwrites 45 with
no optimistic-lock conflict. An earlier draft framed the risk as "another bulk update", which is not it — the
realistic racer is `CustomerorderService.setPickingDate` (`findById:227` → `save:274`, one transaction), i.e.
precisely the operator action Fix D re-enables. The outcome is benign because a picking-date change is *supposed*
to reset the state, and the order is re-marked on the next tick.

**Do not "fix" this by adding `co.version = co.version + 1` to the CAS.** That converts a silently-lost
housekeeping stamp into an `ObjectOptimisticLockingFailureException` — a 500 — for the operator changing the date.

**Positions stay at `0`.** Order-only, matching the `RAW_ON_HOLD` precedent (`ReleaseOrderJobService.java:244-249`
writes only `order`) and diverging from `FUTURE_PICKING_DATE`, which syncs positions
(`OrderBatchCreationService.java:202`). Deliberate — stated so nobody "fixes" it.

#### 3.2.2a Existence proof that `REQUIRES_NEW` commits from this call site

r1's failure makes this worth proving from data rather than from configuration reading. **State
`RAW_ON_HOLD (50)` has exactly two writers in the entire codebase** — `ReleaseOrderJobService.java:247` and
`:582` — and both are **inside `releaseOrder`**, i.e. inside a `REQUIRES_NEW` method invoked from
`processOrderGroup` within `streamOrderPositionsForEach`'s `readOnly = true` transaction. Any order sitting at
state 50 in a live database is therefore a committed write from exactly the call path r2 uses:

| Database | Orders at state 50 | Write window (`modified`) |
|---|---|---|
| `wh01_hydra_v2` (UAT) | 4 | 2026-01-09 → 2026-02-03 |
| `wh01_om1_v2` (wineco UAT) | 12 | 2026-07-20 → **2026-08-04** |

16 rows across two tenants, the most recent ten days before this plan was written. `REQUIRES_NEW` demonstrably
suspends the read-only outer transaction, acquires a writable connection, and commits. **This is the mechanic
r1 lacked, and it is the reason B2's `propagation = REQUIRES_NEW` is not optional.**

#### 3.2.3 Client axis — resolved

The reviewers disagreed. Resolution: **the guard reads the section of `co.client_id`**, because that is the field
`releaseOrder:601` uses, so the guard predicts what `releaseOrder` will actually do rather than approximating it.
The `client`/`sec` join exists solely to serve the removed filter — nothing else in the SELECT touches it — so
re-pointing it is safe. Measured behaviour-preserving today: **0 divergences across 595,407 PICK_PACK orders on
all 6 reachable tenant DBs** (`wh01_hydra_v2` uat 8,556 + dev2 8,983 / `dev_wh01_om1` 227,603 / `wh01_om1_v2`
273,497 / `wh01_shipitez_v2` 76,099 / `wh02_shipitez_v2` 669). A2's list variant keeps `cob.client_id`.

#### 3.2.4 The pre-round gate must exclude state 45

Stamping 45 moves the order off the unconditional fast path. At `RAW`, `OrderReleaseJob:188`
(`orderStatus > RAW`) is false and `releaseOrder` is always called. At 45 it is **true**, so the order enters the
pre-round with its **positions still at `RAW`** — a combination the pre-round never anticipated (held orders
arrive with held positions). Two branches then `continue` instead of setting `process = true` —
`:217-227` (overstock, `available >= requested`, position `== RAW`) and `:259-278` (fix assignment,
`lastAvailable >= amount`, position `== RAW`) — and `:280-284` returns **without calling `releaseOrder`**.

Reachable whenever an earlier order in the same tick released the same SKU (which populates
`fixAssignmentID[2]`, `ReleaseOrderJobService.java:554`). A cold map releases fine — which is exactly why a naive
unit test passes on a broken branch.

```diff
-        if (orderStatus > RAW) {
+        if (orderStatus > RAW && orderStatus != WmsConstants.State.CLIENT_HAS_NO_SECTION) {
```

Requires the warm-map unit test in §6.2. ⚠ It must pre-warm **`itemDataAvailableAmountMap`**, not
`itemDataFixAssignmentMap` — the latter's `[1]`/`[2]` slots are written only inside the real `releaseOrder`,
which the test mocks away, so a unit test cannot warm it. See §6.2 for the workable shape.

#### 3.2.5 Why skip rather than let `releaseOrder` throw

The healing sites (`:243-253`, `:578-589`) are mutually-exclusive early-return branches; `:601-604` is reached
only when neither fires. Either way a section-less order reaching `releaseOrder` ends badly:

| Path | Outcome |
|---|---|
| Positions unsatisfiable | `:246` matches `state == CLIENT_HAS_NO_SECTION`, sets `RAW_ON_HOLD (50)`, calls `customerOrderOnHold` → **45 clobbered, stall mislabelled as a stock problem** |
| Positions satisfiable | Reaches `:604`, throws, rolls back, swallowed at `:292` → silent again |

The `return` in B3 is the entire guarantee. §9.1 asserts it explicitly, because an implementation that stamps and
then falls through would pass every other grep row.

### 3.3 Fix C — two meters, not one

```java
public void tenantOrdersSkippedNoSection(String tenant, long n) {   // every tick — dashboards
    registry.counter("wms2.cron." + jobSegment + ".orders_skipped_no_section", "tenant", tenant).increment(n);
}
public void tenantOrdersMarkedNoSection(String tenant, long n) {    // transitions — alert on this
    registry.counter("wms2.cron." + jobSegment + ".orders_marked_no_section", "tenant", tenant).increment(n);
}
```

Segment `order_release` (`JobMetricsConfiguration.java:21-23`). A single always-on counter would make
`increase(...[15m]) > 0` fire continuously from day one until SBDEV-2963 lands; an always-red alert gets muted,
defeating the purpose. **Alert on `orders_marked_no_section`; dashboard `orders_skipped_no_section`.**

### 3.4 Fix D — avoid the self-inflicted UI regression

`getCodeText(0) = "Created"` → `getCodeText(45) = "No Section"`, and the UI branches on that string:

| Site | Today | After B | Verdict |
|---|---|---|---|
| `openParcels.vue:329-333` `updatableState` | `'Created'` absent → disabled | absent → disabled | unchanged ✅ **do not touch** |
| `openParcels.vue:336-341` `updatablePickingDate` | `'Created'` present → **allowed** | absent → **blocked** | ⚠ regression |
| `parcelDetails.vue:216-221` | same | same | ⚠ regression |

Add `'No Section'` to the two `updatablePickingDate` lists only.

**This is the operator's only remedy, not cosmetics.** The backend already handles 45 on that path:
`CustomerorderService.setPickingDate:256` (`state > RAW && state < RESERVED`, true at 45) resets the order to
`RAW`/`80`. So changing the picking date is a *working* lever while SBDEV-2963 backfills sections — shipping the
API without Fix D removes it from exactly the orders that need it. Deploy order is insensitive (no API contract
dependency): **do not gate the API PR on the UI PR**, but do not close the ticket with only one merged.

No other UI site needs touching — `CLUB_INACTIVE_STATUSES`/`TRANSFER_INACTIVE_STATUSES` already list
`'No Section'` (`constantValues.js:64,88`, inert since club/transfer can never reach 45), `openParcels` has no
status-filter list, and `isPriorityInactive` is numeric.

### 3.5 Fix E — the Order Monitor dashboard bucket

**Fix E is hygiene, not a regression fix. Read this before "restoring" anything.**

`order_imported` is `co.state = 0` **exactly** (plus `pickingdate <= today`, which stalled orders satisfy), so
after Fix B a stamped order leaves that bucket. An earlier draft called this a blocker — *"the homepage tile
would silently lose exactly the orders this ticket exists to surface"*. **That was wrong, and it was wrong in the
same way A2's rationale was wrong: a change justified by a consequence that does not exist.**

The bucket is **never rendered**. `ViewDtoService` maps it to DTO keys `orderCreated` (`:1111`, `:1177`) and
`orderImported` (`:1143`, `:1210`), and **neither key appears anywhere** in `wms2-web-ui` or `wms2-mobile-ui` —
no `value:` binding, no header text, no store reference. Verified by sweep over both repos' `components/`,
`pages/` and `store/`. A state-0 order reaches the dashboard only through `orderTotal` (`order_sum`,
`state < 700`), and a state-45 order still does.

So Fix B breaks no visible tile and Fix E restores none. It is kept because it is four lines that make the SQL
honest for any future consumer, and because leaving a bucket named "imported" silently excluding a live
pre-release state is a trap for the next reader. **Its verify rows are advisory.** If someone actually wants
dashboard visibility for these orders, that requires *rendering* a bucket in two UIs and belongs in its own ticket.

Worth recording in §1 as well: the Order Monitor has **always** been individually blind to these orders, which is
part of why this bug survived as long as it did.

Widen in all **four** native queries (`OrderMonitorViewRepository.java:24,109,198,284`):

```diff
-        "            WHEN co.state = 0 AND co.pickingdate <= 'now' \\:\\:text \\:\\:date THEN 1 " +
+        "            WHEN co.state IN (0, 45) AND co.pickingdate <= 'now' \\:\\:text \\:\\:date THEN 1 " +
```

Note the four copies differ in whitespace around `\:\:text \:\:date` — match each exactly.

**The DB view is deliberately NOT changed** (decision 2026-08-14). `order_monitor_view` carries the same bucket
at `V2.2.00__base_v2_schema.sql:1702` and is HAL-reachable via `@RepositoryRestResource(path="orderMonitorView")`
(`OrderMonitorViewRepository.java:15-16`, `RestConfiguration.java:40`), so this leaves a **documented
divergence**: `/v3/orderMonitorView` keeps the old bucket. Rationale — the four Java queries are what the
dashboard reads (`ViewDtoService.java:1101,1131,1167,1197` ← `DashboardController.java:47,53`), no UI caller of
the plain HAL resource was found by either reviewer, and a `CREATE OR REPLACE VIEW` migration pulls in the
tenant-object-ownership landmine that silently froze prd `hydra/nywh` at `V2.2.06` — a failure mode that never
aborts boot. Column list is unchanged either way, so there is no `ddl-auto` risk.

**Scope of the accepted divergence is wider than one line.** The stale `state = 0` bucket lives not only at
`V2.2.00__base_v2_schema.sql:1702` but also in `db/v1-to-v2-onboarding/schema/` (`V1.0.02`, `V1.1.01`, `V1.2.04`,
`V2.1.03`) and the UTC rollback script — and the IT harness builds its schema from that onboarding chain. There
is still effectively one live view per database, so the decision stands, but the divergence surface is "every
future fresh DB and every IT schema", not a single migration line. Record it so a later reader does not think
one `CREATE OR REPLACE VIEW` closes it.

**Pre-existing, out of scope, worth knowing:** `OrderMonitorViewRepository.java:187` is
`AND (sec.name = :sectionName OR sec.name IS NULL)`, so a section-less order matches **every** section filter
rather than none. It dents the visibility story but is not introduced here.

### 3.6 File change summary

| File | Repo | Change | Fix |
|---|---|---|---|
| `repo/jpa/CustomerorderPositionRepository.java` | api | modify | A1 (alias, drop filter, re-point join), A2 (alias only) |
| `repo/projection/OrderReleaseInfoView.java` | api | modify | A3 |
| `repo/jpa/CustomerorderRepository.java` | api | modify | B1 CAS method |
| `service/job/ReleaseOrderJobService.java` | api | modify | B2 `REQUIRES_NEW` method |
| `schedulejob/OrderReleaseJob.java` | api | modify | B3 guard + `:188` gate + `tenantName` threading |
| `schedulejob/JobMetrics.java` | api | modify | C — two counters |
| `repo/jpa/OrderMonitorViewRepository.java` | api | modify | E — 4 queries |
| `unit/schedulejob/OrderReleaseJobTest.java` | api | **fix** | T1 — stub `getSectionId()` non-null on all 5 row mocks. **No ctor change** (see §5.2 step 10) |
| ~~`OrderReleaseJobStreamingTest.java`~~ | api | **no change** | feeds no rows → guard never fires; no ctor change |
| ~~`OrderReleaseJobMetricsUnitTest.java`~~ | api | **no change** | same |
| `unit/schedulejob/OrderReleaseJobSectionGuardTest.java` | api | **new** | §6.2 |
| `integration/…/OrderReleaseSectionQueryIT.java` | api | **new (@Disabled)** | §6.3 |
| `components/outbound/pickPack/openParcels.vue` | web-ui | modify | D |
| `components/outbound/pickPack/parcelDetails.vue` | web-ui | modify | D |
| `wms2-state-machine-catalog.md` | sbdocs | modify | 45 becomes reachable; cite the writer |

---

## 4. V1/V2 Applicability

**v1 has the identical defect and is explicitly OUT OF SCOPE** (user decision, 2026-08-14).

| Site | v1 | v2 |
|---|---|---|
| `AND sec.id is not null` | `CustomerorderPositionRepository.java:61` | `:62`, `:88` |
| `CLIENT_HAS_NO_SECTION` read-only | `ReleaseOrderJobService.java:189`, `:461` | `:246`, `:581` |

**Recorded consequence:** the live v1 fleet stays exposed with nothing tracking it. If that changes, the
counterpart plan reuses this base name under `sbdocs/1-Projects/wms1/plan/`.

**Do not port blindly:** v1 is `javax.persistence`, has no `tenantTransactionManager`, Mockito 3.3.3 (no
`mockStatic`), and **no `JobMetrics`** — Fix C has no home there as written.

---

## 5. Prerequisites & Implementation Plan

### 5.1 Prerequisites

| Concern | Required? | Detail |
|---|---|---|
| DB state | **No** | No schema change; `client.section_id` already nullable |
| Flyway migration | **No** | Confirmed: Fix E is Java-only by decision (§3.5). Do **not** allocate a `V2.2.x` |
| Feature flags / sysprops | **No** | Deliberately ungated — the change only adds a signal; a flag left off reproduces the bug |
| Config / env | **No** | — |
| Data migration | **No** | Backfill is SBDEV-2963, independent |
| Deploy order | **No** | api and web-ui deploy independently; Fix D is not gated by the API PR (§3.4) |
| External systems | **No** | No OMS contract change (§8.4 #4) |
| Access | Yes | Hydra UAT + tenant DB for §6.4 |
| Monitoring | **Yes — post-deploy** | Alert on `orders_marked_no_section` (§3.3), else the signal exists unwatched |

### 5.2 Implementation checklist

1. Branch off freshly-fetched `origin/develop`.
2. **Run the verify script; record the FAIL baseline** (non-zero expected).
3. A3 projection getter.
4. A1 + A2 query changes.
5. B1 CAS repository method.
6. C — both counters.
7. B2 `REQUIRES_NEW` service method.
8. B3 guard + `:188` gate + `tenantName` threading.
9. E — all four `order_imported` queries.
10. **T1 — fix `OrderReleaseJobTest` only.** Stub `getSectionId()` non-null on every
    `mock(OrderReleaseInfoView.class)` row (5 of them).
    ⚠ **Corrected at the TDD gate, 2026-08-14 — r2's "three test classes break at ctor arity" no longer
    applies.** r3's guard uses only `jobMetrics` and `releaseOrderJobService`, both **already** constructor
    parameters, and `customerorderRepository` lives inside `ReleaseOrderJobService`, which already injects it —
    so **B introduces no constructor change and nothing breaks at arity.** Measured in the worktree:
    `OrderReleaseJobTest` has 5 `mock(OrderReleaseInfoView.class)` rows and 5 `.accept(` feeds (**affected**);
    `OrderReleaseJobStreamingTest` and `OrderReleaseJobMetricsUnitTest` have **zero** of each, so the guard never
    fires in them (**unaffected**); `OrderReleaseJobUnitTest` never constructs the job (**unaffected**).
    ⚠ `OrderReleaseJobTest` extends `BaseServiceUnitTest` → `BaseUnitTest.java:18` is plain
    `@ExtendWith(MockitoExtension.class)`, i.e. **STRICT_STUBS** (unlike `OrderReleaseJobStreamingTest`, which
    declares LENIENT). Blanket stubbing is safe *today* only because all five row mocks stub
    `getCoState() = RAW` (`:173`, `:219`, `:230`, `:348`, `:359`) and therefore reach the guard. If a row mock
    ever does not, the class throws `UnnecessaryStubbingException`. **Fix that with `lenient().when(...)` on the
    individual stub — never by adding `@MockitoSettings(LENIENT)` to the class**, which would silently weaken
    every existing assertion in it. Note what the stubbing changes: those tests now prove "releases when a
    section is present" rather than "releases", which is correct — the section-less case moves to the new class.
11. **`mvn clean test-compile`** — *not* `compile`. `compile` builds main only and would miss every T1 break.
12. New unit tests (§6.2); `mvn test -Dtest=OrderReleaseJobSectionGuardTest`.
13. `mvn test -Dtest='OrderReleaseJob*'` — all four job test classes green.
14. `@Disabled` IT (§6.3) with `TODO(SBDEV-2217)`.
15. Fix D + Jest; `node_modules/.bin/jest`.
16. `mvn test` full suite. **Expect exactly 2 pre-existing failures on clean `develop`**
    (`OptionalSafetyArchTest`, `MobilePalletizingServiceTest`); confirm the count is unchanged and
    **revert the mutated tracked `archunit_store`**.
17. Re-run verify → `Result: N pass, 0 fail`.
18. Update `wms2-state-machine-catalog.md` (45 now reachable, writer cited).
19. Fill §6.5 and §9.2.

Steps 3-9 are one atomic commit; 10 belongs with it (same compilation unit); 15 is a separate commit in the other repo.

---

## 6. Test Plan

### 6.1 Strategy and its limit

Fix B's behaviour is unit-testable with mocks. **Fix A and Fix E are not** — a mocked repository returns whatever
the test says, and the four `order_imported` queries are native SQL with no bootable IT lane. That gap is why
§6.4 is mandatory, and why "0 fail" must never be read as "the queries are right".

### 6.2 New unit tests — `OrderReleaseJobSectionGuardTest`

> **WRITTEN AND BASELINED AT THE TDD GATE, 2026-08-14** —
> `.claude/worktrees/wms2-api/SBDEV-2961`, branch
> `feature/SBDEV-2961-order-release-silent-section-exclusion` off `origin/develop` `02dc7ca`.
> `mvn test -Dtest=OrderReleaseJobSectionGuardTest` → **`Tests run: 5, Failures: 4, Errors: 0, Skipped: 0`**.
>
> Method names follow the gate convention `<method>_should<Outcome>_when<Condition>`, so they differ from
> the shorthand in the table below. As built:
>
> | Method | Baseline | Encodes |
> |---|---|---|
> | `releaseOrders_shouldNotCallReleaseOrder_whenClientHasNoSection` | **FAIL** ✅ | §3.2.5 anti-clobber |
> | `releaseOrders_shouldMarkClientHasNoSection_whenClientHasNoSection` | **FAIL** ✅ | B3 calls the CAS |
> | `releaseOrders_shouldNotMarkAgain_whenOrderAlreadyAtClientHasNoSection` | **FAIL** ✅ | §3.2.2 short-circuit + still no release |
> | `releaseOrders_shouldReleaseNormally_whenSectionIsConfigured` | **PASS** (by design) | regression guard — the happy path must not break |
> | `releaseOrders_shouldStillRelease_whenOrderHealsFrom45AndFixMapIsWarm` | **FAIL** ✅ (`Wanted 2 times but was 1 time`) | **§3.2.4 — empirically confirms the pre-round defect** |
>
> **Counter assertions — deferred at the gate, ADDED during implementation (2026-08-14).** They could not be
> written at the gate because `JobMetrics` is constructed concretely, not mocked, so asserting the counters
> required Fix C to exist. Once it did, the conformance lane flagged the omission and they were added, bringing
> the class to **7 tests**:
>
> | Method | Asserts |
> |---|---|
> | `releaseOrders_shouldCountBothMeters_whenTransitioningToClientHasNoSection` | CAS stubbed to return 1 → **both** `orders_skipped_no_section` and `orders_marked_no_section` reach 1.0 |
> | `releaseOrders_shouldCountOnlySkipMeter_whenOrderAlreadyMarked` | already-45 row → skip meter 1.0, **marked meter stays 0.0** |
>
> These are what stop the two-meter split from being collapsed back into one. Both review lanes flagged
> independently that a single per-tick counter makes an `increase(...) > 0` alert fire continuously until
> SBDEV-2963 lands, and an always-red alert gets muted. Non-vacuous by construction: the test helper returns
> `0.0` for a meter that was never created, so deleting either counter call fails the assertion rather than
> passing silently. `mvn test -Dtest=OrderReleaseJobSectionGuardTest` → **`Tests run: 7, Failures: 0`**.
>
> **Two signature-only scaffolds** were added so the tests compile (gate rule 1 vs rule 3):
> `OrderReleaseInfoView.getSectionId()` (interface declaration, no behaviour) and
> `ReleaseOrderJobService.markClientHasNoSection(long)` (throws `UnsupportedOperationException`, Javadoc'd as
> scaffolding). **Both must be replaced by the real Fix A3 / B1+B2 implementation** — the verify rows
> `B2_requires_new`, `B2_propagation`, `B2_tenant_tm`, `B1_cas_*` all fail until then.

| Test | Asserts |
|---|---|
| `sectionNull_marksClientHasNoSection` | `releaseOrderJobService.markClientHasNoSection(coId)` invoked |
| `sectionNull_neverCallsReleaseOrder` | `verify(releaseOrderJobService, never()).releaseOrder(anyLong(), any(), any())` — **the §3.2.5 guarantee** |
| `sectionNull_incrementsSkipCounterEveryTick` | `tenantOrdersSkippedNoSection` invoked even when CAS returns 0 |
| `sectionNull_transitionOnly_warnsOnceViaRowCount` | CAS returns 1 → `tenantOrdersMarkedNoSection`; returns 0 → **not** invoked |
| `sectionPresent_releasesNormally` | non-null `sectionId` → `releaseOrder` called once, CAS never called |
| `sectionAssignedLater_coldMap_releases` | state 45, section now present, empty fix map → `releaseOrder` called |
| **`sectionAssignedLater_warmMap_stillReleases`** | **The §3.2.4 regression test — write it exactly this way or it passes both with and without the fix.** ⚠ It must warm **`itemDataAvailableAmountMap`**, *not* `itemDataFixAssignmentMap`: the latter's slots `[1]`/`[2]` are written only inside the **real** `releaseOrder` (`ReleaseOrderJobService.java:552-554`), which this test mocks away, so a unit test cannot pre-warm it without a `doAnswer` reaching into the argument array. Workable shape: stream **order A** (state `RAW`, item X, section present) → the mocked `releaseOrder` returns `Map.of(itemX, 999)`, which `OrderReleaseJob:291` folds into `itemDataAvailableAmountMap` → then **order B** at state 45, section present, same item X, no fix assignment, position `RAW`, amount 1. Old code takes `:217-226` `continue` → `process == false` → `:283 return` → `releaseOrder` called **once**; with the `:188` fix → **twice**. Assert `times(2)` |
| `sectionNull_doesNotReachOms` | `verify(releaseOrderJobService, never()).releaseOrder(...)` — see below |

**r1's `verifyNoInteractions(manageOrderService)` was vacuous** and is removed: `ManageOrderService` is not a
dependency of `OrderReleaseJob` (ctor `:49-63`); a mock wired to nothing can never be interacted with, so the
assertion could not fail — and r1's verify script grepped for that literal, pinning an unfailable test.
`releaseOrderJobService` is the only thing on this path that can reach OMS.

Existing classes to keep green: `OrderReleaseJobTest`, `OrderReleaseJobStreamingTest`,
`OrderReleaseJobMetricsUnitTest` (all need T1 fixes first).

### 6.3 Integration test — written, `@Disabled`

`OrderReleaseSectionQueryIT` — seed a `section_id = NULL` client + `PICK_PACK` batch; assert
`streamOrderReleaseInfo` **returns** the row with `sectionId == null`; seed a section-having client and assert
`sectionId` is populated. The only test that can prove Fix A.

Cannot run: the v2 Testcontainers lane cannot boot (`outbox_message` Flyway-profile gap + landlord datasource),
**SBDEV-2217**. Commit `@Disabled` with `TODO(SBDEV-2217)`; gate on unit tests + `mvn clean test-compile` + §6.4.

### 6.4 Manual test plan (MANDATORY)

| # | Scenario | Steps | Expected | P/F |
|---|---|---|---|---|
| 1 | Stall becomes visible — **use ≥ 3 stalled orders** | `PICK_PACK` batches for a `section_id IS NULL` client; wait 2 ticks | **Every** order at `state = 45`, not just one. Directly falsifies the r1 read-only-tx defect, which stamped only the last buffered group | |
| 2 | No log spam | leave at 45 for 10 ticks **without touching the picking date** | exactly **one** WARN per order; `orders_skipped_no_section` climbs each tick; `orders_marked_no_section` static. ⚠ Changing the picking date resets 45 → `RAW`/`80`, so the next tick legitimately re-marks and emits a **second** WARN plus a second `orders_marked_no_section` increment. That is correct — 45 is a diagnosis, not a resolution — so do not read it as spam, and do not "fix" the flapping by suppressing the re-mark | |
| 3 | **Self-heal, warm map** | assign `ZoneA`; ensure another order for the **same SKU** releases earlier in the same tick | picking order created, state ≥ 200 — the §3.2.4 path | |
| 4 | Happy path unchanged | `PICK_PACK` for `ZEROLINK` (53400) | releases as before; neither counter moves | |
| 5 | **Dashboard** | homepage Pick&Pack monitor | the 45 orders still counted in `order_imported` (Fix E) | |
| 6 | Fix D | open a 45 order in Pick & Pack | picking-date edit **enabled**; changing it resets the order to `Created`/`Future Picking Date`; no console error | |
| 7 | Existing stuck rows | `BATCH-20260812-001/002` after deploy | transition 0 → 45 unattended | |

### 6.5 Test execution (fill in after running)

| Command | Baseline (at gate) | Final (2026-08-14) |
|---|---|---|
| `verify-SBDEV-2961-…sh` (`PROJECT_ROOT`/`WEB_UI_ROOT` = both worktrees) | `10 pass, 31 fail, 5 skip`, exit 1 | **`44 pass, 0 fail, 2 skip`** ✅ |
| `mvn test -Dtest=OrderReleaseJobSectionGuardTest` | `5 run, 4 failures` | **`7 run, 0 failures`** ✅ (+2 counter tests added during implementation) |
| `mvn clean test-compile` | — | **BUILD SUCCESS** ✅ |
| `mvn test -Dtest='OrderReleaseJob*'` (4 classes) | — | **`24 run, 0 failures, 2 skipped`** ✅ |
| `mvn test` (full, API) | `5027 run, 6 failures` | **`5029 run, 2 failures`** ✅ — the 2 are `OptionalSafetyArchTest` + `MobilePalletizingServiceTest`, both pre-existing on clean `develop`; count unchanged |
| `jest` (web-ui) | 338 tests on clean `develop` | **`344 passed, 344 total`** ✅ (+6 new). `Test Suites: 2 failed` is the pre-existing `labelCsvUpload`/`zplPreview` module-resolution pair — **compare the tests count, not the suites count** |

Independently re-run by the `verifier` lane from scratch; every figure above reproduced exactly.

⚠️ **`archunit_store` was mutated by `mvn test` and reverted three times** during this work (it is tracked, and `mvn test` rewrites it). Confirm `git status` is clean of it before staging.

⚠️ **Concurrency note for anyone re-running these:** the review lanes have shell access to the same worktree. `OrderReleaseJob.java` was observed reverted at 15:59:59 and restored at 16:00:51 — a review lane ablation-testing the guard. A `mvn`/verify run landing inside such a window reports figures that describe a different tree. Re-confirm `git status` and the presence of the guard immediately before trusting any run.

The 10 pre-fix greens, so nobody miscounts them as progress: `A1_orderby_intact`,
`A2_list_filter_kept`, `A2_list_join_kept`, `D_statelist_intact` (must-not-regress guards);
`B1_cas_not_wide` (directional — cannot fail pre-fix); `A3_projection` (genuinely done — the gate's
signature scaffolding *is* Fix A3); and `T_guard_test_exists`, `T_never_releases`, `T_warm_map`,
`T_no_vacuous_oms` (the gate tests now exist).

### 6.6 Deliberately-skipped coverage

| Gap | Rationale |
|---|---|
| `OrderReleaseSectionQueryIT` `@Disabled` | SBDEV-2217. **Fix A has no automated proof**; §6.4 #1/#4 are the only evidence |
| Fix E has no automated test | Native SQL in 4 queries, same IT blocker. §6.4 #5 is the only evidence |
| `getOrderReleaseInfo` HAL response untested | No caller; A2 is an additive column. Covered by `test-compile` |
| `/v3/orderMonitorView` divergence | Accepted by decision (§3.5) |
| v1 | Out of scope (§4) |

---

## 7. Horizontal Scalability Validation (v2 — MANDATORY)

| # | Concern | Verdict | Note |
|---|---|---|---|
| 1 | New in-JVM state | **No** | Counters live in the shared `MeterRegistry` |
| 2 | Connection pool math | **No** — *after* the §3.2.2 short-circuit | Same stream + one extra column. The CAS opens a short `REQUIRES_NEW` tx **per transition**, which is only true because the guard short-circuits on `orderStatus == 45` before calling it. Without that short-circuit it is once per section-less order **per tick** (~110/min at current UAT data) against a pool of 5 already holding the streaming cursor — both reviewers flagged this independently |
| 3 | Scheduled jobs | **No** | No new job; `JobLockId.ORDER_RELEASE` (`:67`) unchanged |
| 4 | Long transactions | **No** | CAS is a single statement in its own tx. **r1 was wrong here** — it wrote inside the caller's read-only tx |
| 5 | Request affinity | **N/A** | Cron path |
| 6 | Retry / idempotency | **Yes** | CAS `WHERE state IN (:raw, :futurePickingDate)` is inherently idempotent — an already-marked order is outside the allow-list, so a duplicate tick returns 0 rows and emits no WARN. The guard also short-circuits before the CAS when the row snapshot already reads 45, so a repeat tick costs no transaction at all |
| 7 | Tenant context | **Yes** | `tenantName` threaded from `doCalculation:94` rather than re-read from the ThreadLocal |
| 8 | Distributed lock | **No** | Advisory lock is a landlord-datasource session-level `pg_try_advisory_lock` (`AdvisoryLockService.java:45,58-61`) covering the whole job across tenants and replicas → the CAS is single-writer from the job; only UI writers race it |
| 9 | Cache invalidation | **Yes** | `Customerorder` is not `@Cacheable`. The `clients` Caffeine cache (`CacheConfig.java:37`, 5-min TTL) is populated only by `ClientService.getByNumber`/`getSystemClient` (`:53`,`:100`); the release path uses the SQL join, so a section assigned via Admin takes effect next tick regardless. **Bulk JPQL bypasses the L1/entity cache** — fine, nothing else in the tick touches that order |
| 10 | External notifications | **Yes** | Deliberately none (§8.4 #4) |

---

## 8. Notes

### 8.1 Risks & mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| **Fix A + Fix E have no automated proof** (SBDEV-2217) | A wrong query ships unverified; worst case the filter removal regresses release for *all* orders | `sectionPresent_releasesNormally`; `mvn clean test-compile`; §6.4 #4 re-tests the happy path; #5 the dashboard; ITs committed `@Disabled` |
| Writes on this path silently no-op | **This killed r1** | All writes via `REQUIRES_NEW` (§3.2.1). §6.4 #1 uses ≥ 3 orders specifically to catch a partial stamp |
| Bulk JPQL bypasses `@Version` | A concurrent stale entity save could revert 45 → 0 | Tiny window, self-heals next tick; only other bulk update is unreachable at 45. Accepted, recorded |
| Removing the filter widens the stream | Section-less orders re-stream every tick forever | 4 → 6 rows on Hydra UAT today; bounded by the same state/date window and `fetchSize=500`. Growth is unbounded over time, gated only by SBDEV-2963 |
| Log spam | 110 candidate clients | Transition-only WARN driven by CAS row count; volume carried by the per-tick counter |
| Always-red alert | Alert gets muted, defeating the fix | Two meters (§3.3) |
| SBDEV-1656 branches go live | `45 → RAW_ON_HOLD` reachable for the first time | Intended (§8.2) |
| `/v3/orderMonitorView` diverges | HAL resource keeps the old bucket | Accepted by decision; documented in §3.5 and §6.6 |
| New status visible to operators | "No Section" appears in Pick & Pack | Already in `constantValues.js:112` and `getCodeText`; Fix D closes the behavioural gap |

### 8.2 SBDEV-1656 becomes live

Fix B makes 45 writable, so `:246`/`:581` become reachable for the first time since 2025-10-28. Path: order at 45
→ section assigned → next tick enters `releaseOrder` → positions unsatisfiable → `45 → RAW_ON_HOLD (50)` +
`customerOrderOnHold`. Exactly what SBDEV-1656 intended. Consequence to record: under the skip, a section-less
order that is *also* short on stock reports 45 only — the stock problem stays hidden until a section exists, and
the `customerOrderOnHold` that would have fired does not. Neither fires today either, so nothing regresses.

### 8.3 `getStateCode` cannot throw — verified

`util/commonUtility.js:24-27` does `CONSTANT.stateList.filter(...)` then **unguarded `code[0].code`** — a
`TypeError` for any unmapped status (unlike `getLockCodeText` below it, which length-guards).
`{ name: 'No Section', code: 45 }` **is** present at `util/constantValues.js:112`. Called from
`parcelDetails.vue:223` and three club components. **Do not remove that entry.**

### 8.4 Resolved decisions

| # | Question | Decision | Rationale |
|---|---|---|---|
| 1 | Scope: v1 too? | **v2 only** | User 2026-08-14. §4 records v1 stays exposed and untracked |
| 2 | How should it surface? | **Stamp 45 + WARN + metric** | User 2026-08-14. Three layers already model the state |
| 3 | Prevention upstream? | **Detection only** | User 2026-08-14. Backfill + client-save validation stay with SBDEV-2963 |
| 4 | Notify OMS on 45? | **No** | Both reviewers concur. `customerOrderOnHold` is the signal for `RAW_ON_HOLD` — a stock story OMS can act on; 45 is a WMS-side config fault OMS has never been told about and whose value its state map likely lacks, so emitting it is a contract change needing an OMS ticket. Also the wrong vehicle: a new WMS→OMS message belongs in `outboxService.enqueue` inside the same tenant tx. Nothing regresses by staying silent — nothing fires today |
| 5 | Sysprop gate? | **No** | Adds only a signal; a flag left off reproduces the bug |
| 6 | Fix D in scope? | **Yes — own commit/PR in wms2-web-ui** | Both reviewers concur. It is the operator's only remedy (§3.4), not cosmetics. Do not gate the API PR on it |
| 7 | Fix the `order_monitor_view` DB view? | **No — Java queries only, divergence documented** | User 2026-08-14. Keeps `§5.1` Flyway-free and avoids the tenant-ownership landmine (§3.5) |

### 8.5 v2-only constraint checklist

| # | Constraint | Verdict | Where |
|---|---|---|---|
| 1 | OSIV disabled | **N/A** | No lazy association; flat projection over native SQL |
| 2 | `tenantTransactionManager` | **Yes** | B2 names it explicitly with `REQUIRES_NEW`. **Never annotate `OrderReleaseJob`** — `landlordTransactionManager` is `@Primary`, so a bare `@Transactional` routes tenant writes to the landlord datasource. **Machine-enforced:** `TransactionManagerArchTest.java:48-67` fails the build if any `@Transactional` in the service package omits a named TM, so B2 cannot regress silently |
| 3 | `readOnly = true` on reads | **Yes** | `:777` already correct — and is precisely why B2 must be `REQUIRES_NEW` (§3.2.1) |
| 4 | Caffeine invalidation | **Yes** | §7 row 9 |
| 5 | Jakarta namespace | **N/A** | No new imports from v1 |
| 6 | H2-compatible test SQL | **Yes** | New SQL is one alias + an `IN` list; unit tests are mock-based |
| 7 | `BaseControllerTest` | **N/A** | No controller change |
| 8 | Micrometer | **Yes** | Fix C reuses `JobMetrics` |

### 8.6 Completeness checklist

| # | Concern | Considered? |
|---|---|---|
| 0 | **DB verified** | ✓ §1.2 differential re-run; §3.2.3 6-database client-axis sweep; `db_verified: true` |
| 1 | All callsites enumerated | ✓ §0 — 22 rows; predicate sweep independently confirmed complete |
| 2 | Adjacent bugs | ✓ §0 rows 2, 9-10 (dashboard), 17 (`setPickingDate`), 18-19 (dead reads), 22 (v1) |
| 3 | Backward compatibility | ✓ A2 additive; list variant's result set unchanged; no schema/API break. The visible change is a new *state value* on an existing field → §3.4, §3.5, §8.3 |
| 4 | Concurrency | ✓ §3.2.2 CAS is atomic and idempotent; §7 rows 6, 8; `@Version` bypass accepted and recorded |
| 5 | Multi-tenant | ✓ §7 row 7 — `tenantName` threaded, not ThreadLocal-read |
| 6 | Error handling | ✓ CAS removes both new unchecked throw paths that would have aborted a tenant's tick (§3.2.2). `:604` kept as defence |
| 7 | Observability | ✓ §3.3 two meters + alert target. This *is* the fix |
| 8 | Rollback / migration | ✓ §5.1 — no Flyway, no sysprop; revert is a plain code revert (stamped rows release once a section exists) |
| 9 | Test coverage | ✓ §6.2 (8 unit tests incl. the warm-map regression), §6.3, §6.4 (7 manual), §6.6 (gaps named) |
| 10 | Cross-version | ✓ §4 — **no**: v1 out of scope by explicit user decision |

---

## 9. Acceptance & Implementation

### 9.1 Acceptance script

`sbdocs/9-System/scripts/verify-SBDEV-2961-order-release-silent-section-exclusion.sh`

Run **before** any change (expect non-zero) and **after** (require `Result: N pass, 0 fail`). Paste that line
into the completion report.

r2 script corrections, all from review:

| Problem in r1 | Fix |
|---|---|
| `mvn_test_passes` used `mvn test -q`, which suppresses both `BUILD SUCCESS` and `Tests run:` (INFO) → **permanently red on a green build** → `0 fail` unattainable → implementer sets `SKIP_MVN=1`, deleting the only non-grep evidence | drop `-q`; require `BUILD SUCCESS` **and** `Tests run: [1-9]…Failures: 0, Errors: 0`, so it cannot pass vacuously on a class that does not exist either |
| `-DfailIfNoTests=false` is the wrong flag for surefire 3.2.5 | `-Dsurefire.failIfNoSpecifiedTests=false` |
| r1 reported "negative-tested 3 pass / 21 fail" — but 3+21 = 24 = **the grep rows only**; the Maven rows were never executed | r2 must be run **without** `SKIP_MVN` at least once |
| All six `B_*` rows resolved through `HELPER_END='orderRelease-noSection-'`; dropping `OptimisticLockRetry` (r2 does) would turn six rows red on a **correct** implementation | anchor the helper block on `^    \}` |
| `check_B_guard_present` never asserted the `return` — an implementation that stamps then falls through to `releaseOrder` passed every row, defeating §3.2.5 | dedicated `B_guard_returns` row |
| `T_no_oms_notification` pinned a vacuous test | assert `never()).releaseOrder` instead |
| `file_contains_exactly_n_times` with 0 matches yielded `count="0\n0"` (grep prints `0` **and** exits 1, so `\|\| echo 0` appended a second) → integer error → FAIL for a bogus reason | `count=$(grep -cE … ); [ $? -le 1 ]` style guard |
| No coverage of Fix E or the T1 test fixes | new `E_*` and `T1_*` rows |

Retained from r1 (proven correct in ablation): block-scoped containment for the two near-identical queries;
`file_not_contains` hardened with `[ -f "$2" ] \|\| return 1` because the stock template's version **fails open**
on a missing file.

### Which rows actually discriminate — measured, not assumed

An independent review lane reverted **Fix B in its entirety** against the finished implementation and re-ran
everything. This is the most useful measurement in the whole ticket, because it says which rows are evidence
and which are decoration:

| | |
|---|---|
| Verify script, guard fully reverted | **`32 pass, 12 fail, 2 skip`**, exit 1 |
| The 12 that went red | the 9 `B3_*` rows, `B4_preround_gate`, `M_guard_test`, `M_job_tests` |
| **The 32 that stayed GREEN** | every `A*`, `B1*`, `B2*`, `C*`, `D*`, `E*`, `T*` row — **plus `M_test_compile`** |
| Gate tests, guard fully reverted | **`7 run, 6 failures`** — the lone survivor is `shouldReleaseNormally_whenSectionIsConfigured`, exactly the regression guard §6.2 predicts passes pre-fix |

⚠ **Read this before trusting a green run.** With the behavioural core of the ticket *completely absent*, 32 of
44 rows still pass. They live in other files and are correct to pass — but they carry **no information about
Fix B**. Only the 10 `B3_*`/`B4_*` rows plus the 2 Maven rows discriminate, and **`M_test_compile` is not a
guard signal either** (`getSectionId()` and `markClientHasNoSection` sit in unablated files, so it compiles
fine without the guard). A future reader tempted to conclude "44/0, therefore Fix B works" should look at this
table instead.

Single-element ablations: dropping only `&& orderStatus != CLIENT_HAS_NO_SECTION` → **1 failure**, the warm-map
test alone, which is precisely why that test exists. Dropping only the `return` → 6 failures. Dropping only the
`orderStatus == 45` short-circuit → 6 failures.

Also measured: with Fix B fully reverted, `OrderReleaseJobTest` still passes **10/10**. It is green with *and*
without the fix, which is the demonstration — rather than the assertion — that the added `getSectionId()`
stubbing did not couple those pre-existing tests to this change.

**r3 baseline, measured on unfixed `develop` (2026-08-14) — `Result: 5 pass, 36 fail, 5 skip`, exit 1**
(grep rows; the Maven rows were separately proven under r2, below). Four of the five greens are
must-not-regress guards — `A1_orderby_intact`, `A2_list_filter_kept`, `A2_list_join_kept`,
`D_statelist_intact`. The fifth, `B1_cas_not_wide`, is a **directional guard that cannot fail pre-fix**
(there is no CAS yet to be wide); it only becomes meaningful once B1 exists. Stated so nobody counts it as
evidence of work done.

**r3 hardening, and the ablation tests that prove it discriminates.** Three r2 script rows were false-greens;
each fix was verified by building a deliberately-wrong shadow implementation rather than by inspection:

| Ablation | Result |
|---|---|
| A comment reading `// SBDEV-2961: REQUIRES_NEW is mandatory here` above an **un-annotated** method | `B2_requires_new`, `B2_propagation`, `B2_tenant_tm` all **FAIL** ✅ — the comment can no longer green the row labelled "r1's defect" |
| The same method **correctly annotated** (and declared `final long`) | all three **PASS** ✅ — goes green for the right reason |
| A guard that stamps and **falls through**, with a `return;` 20 lines below | `B3_guard_returns` **FAILS** while `B3_calls_cas` and `B3_warn` **PASS** ✅ — the script discriminates "stamped but did not return" from "stamped correctly". r2's brace-anchored slice would have matched the distant `return;` and passed |
| The correct guard | all five `B3_*` rows including both negatives **PASS** ✅ |

Also caught **by running this script rather than reading it**: an r3 row I had just added,
`B2_propagation`, passed on the unfixed build — `releaseOrder` already carries `Propagation.REQUIRES_NEW`
at `ReleaseOrderJobService.java:119`, so a file-wide `file_contains` proved nothing about the new method.
Changed to require **exactly 2** occurrences (pre-fix count is 1). That is the third consecutive revision in
which the negative test, not review of the prose, found the defect.

**r2 baseline, measured on unfixed `develop` (2026-08-14) — `Result: 6 pass, 35 fail, 2 skip`, exit 1.**
Run in full, **without** `SKIP_MVN`, which is what r1 failed to do. The Maven rows behaved exactly as the r2
redesign requires, closing the r1 defect empirically:

| Row | Result | Proves |
|---|---|---|
| `M_test_compile` | **PASS** | regression gate — will catch the T1 ctor breaks once Fix B lands |
| `M_guard_test` | **FAIL** | the class does not exist → 0 tests ran → fails instead of passing vacuously on `BUILD SUCCESS` (the hole `-Dsurefire.failIfNoSpecifiedTests=false` would otherwise open) |
| `M_job_tests` | **PASS** | **the decisive one** — r1's helper could never go green on a green build; r2's does |

The 6 greens are all must-not-regress guards, not completed work: `A1_orderby_intact`,
`A2_list_filter_kept`, `A2_list_join_kept`, `D_statelist_intact`, `M_test_compile`, `M_job_tests`.
`mvn test` mutates the tracked `archunit_store`; it was reverted and the tree confirmed clean.

### 9.2 Implementation status

**IMPLEMENTED 2026-08-14 — committed locally, not pushed.** Two repos, two branches, two commits.

| Repo | Branch | Commit | Contents |
|---|---|---|---|
| `wms2-api` | `feature/SBDEV-2961-order-release-silent-section-exclusion` (base `origin/develop` `02dc7ca`) | **`4f578ac`** | 10 files, +741/−14 — Fixes A1/A2/A3/B1/B2/B3/B4/C/E + T1 + the `@Disabled` IT |
| `wms2-web-ui` | `fix/SBDEV-2961-no-section-picking-date-editable` (base `origin/develop` `e5cdc29`) | **`1bc8018`** | 3 files, +71/−1 — Fix D + its ablation-proven spec |

**Merge order: `wms2-api` first.** The UI commit is a no-op until state 45 is reachable.

Worktrees (retained for review feedback): `.claude/worktrees/wms2-api/SBDEV-2961` and
`.claude/worktrees/wms2-web-ui/SBDEV-2961`.

#### Tests added / changed

| Class | Change |
|---|---|
| `OrderReleaseJobSectionGuardTest` | **new**, 7 tests — `…shouldNotCallReleaseOrder…`, `…shouldMarkClientHasNoSection…`, `…shouldNotMarkAgain…`, `…shouldReleaseNormally…` (regression guard), `…shouldStillRelease_whenOrderHealsFrom45AndFixMapIsWarm`, `…shouldCountBothMeters…`, `…shouldNotAdvanceMarkedMeter…` |
| `OrderReleaseSectionQueryIT` | **new**, `@Disabled` `TODO(SBDEV-2217)` — 4 tests covering Fix A, Fix E, and the `co.client_id` vs `cob.client_id` axis invariant |
| `OrderReleaseJobTest` | `getSectionId()` stubbed on all 5 row mocks via `lenient()` per stub |
| `pickPackNoSectionPickingDate.spec.js` | **new**, 6 tests (GATE + 2 GUARDS per predicate) |

#### Final measurements

| Command | Result |
|---|---|
| `mvn -o test -Dtest=OrderReleaseJobSectionGuardTest` | `Tests run: 7, Failures: 0` |
| `mvn -o test -Dtest='OrderReleaseJob*,TransactionManagerArchTest'` | `Tests run: 27, Failures: 0, Skipped: 2` |
| `mvn -o clean test-compile` | BUILD SUCCESS |
| `mvn -o test` (full) | `Tests run: 5029, Failures: 2` — the 2 pre-existing, unchanged |
| `jest` (web-ui) | `Tests: 344 passed, 344 total` (338 clean + 6) |
| **`verify-SBDEV-2961-…sh`** | **`Result: 44 pass, 0 fail, 2 skip`** |

#### Review outcome

`security-reviewer` CLEAN · `verifier` PASS (10/10 criteria, 23/23 §0 rows, all commands independently
re-run) · `code-reviewer` APPROVE — 3 Mediums raised and closed, one of which (**the IT's seeding SQL
could not execute**) was correctly re-opened after I first claimed it fixed.

#### Deliberately-skipped coverage

| Gap | Rationale |
|---|---|
| `OrderReleaseSectionQueryIT` `@Disabled` | SBDEV-2217. **Fix A and Fix E therefore have no automated proof at all** — §6.4 manual rows 1/4/5 are the only evidence and have **not** been run |
| §6.4 manual plan (7 rows) | Requires Hydra UAT; all P/F cells empty. Carried into the PR body as reviewer work |
| `/v3/orderMonitorView` divergence | Accepted by decision (§3.5) |
| v1 | Out of scope by user decision (§4); the live v1 fleet remains exposed, untracked |

#### Landmines found during implementation that the plan did not predict

1. **`replace_all` missed a third `processOrderGroup` call site** at a different indentation — the tail call that runs *outside* the stream transaction, i.e. the one r1's design would have written successfully. Grep call sites after any bulk edit.
2. **"Match the existing convention" was unsafe for the IT.** Every IT in that family is `@Disabled`, so none of their seeding SQL has ever executed; copying it propagated the same omissions. `los_sequencenumber` is `(classname, sequencenumber, version)` per-domain counters with no `seqentities` row — PK ids come from the Postgres **sequence** of that name.
3. **`CURRENT_TIMESTAMP` is only instant-correct because `modified` is `timestamptz`** — see the landmine box in §3.2.2.
4. **Two concurrent `mvn` runs on one worktree** produce a false failure: the second's `clean` deletes `target/` under the first. All three Maven rows red at once is a collision signature. Script now uses `-o`; run suites serially.
5. **A review lane's `git checkout --` on an unstaged file discarded Fix B entirely** (restored byte-identical). Shared worktrees and shell-capable review lanes do not mix; check `mtime` before concluding work was lost.
6. **Five false greens in this ticket's own verify script**, every one found by running or ablating it, two of them introduced by my own comment edits. The last: `B3_guard_returns` matched the short-circuit `return` instead of the guard-exit one. Fixed by anchoring on a two-anchor **code-only** block and requiring ≥2 returns. Positional assertions drift whenever the surrounding code moves.
