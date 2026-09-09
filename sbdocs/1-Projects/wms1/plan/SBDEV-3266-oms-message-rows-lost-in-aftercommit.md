---
title: "SBDEV-3266 (v1) — WMS→OMS picking Message rows silently discarded from afterCommit callbacks"
ticket: "SBDEV-3266"
ticket_url: "https://app.clickup.com/t/868m2zj70"
type: "bugfix"
severity: "high"
priority: "high"
status: "implemented"
project: ["wms-api"]
version: "v1"
scope: "oms-notification"
owner: "Nam Park"
requester: "nam.park@siteboss.net"
created: "2026-09-08"
updated: "2026-09-08"
deployed_env: "dev"
pr_url: "https://github.com/SiteBossInc/wms-api/pull/207"
last_verified: "2026-09-08"
verified_by: "production DB queries (wms1-shipitez1, wms1-wineco) + code read + spring-tx/spring-orm 5.2.12 and hibernate-core 5.4.25 sources"
revision: 5
db_verified: true
db_verified_note: >
  Verified against BOTH v1 production tenants. Revision 2 incorporates an independent
  adversarial review (two passes) that invalidated revision 1's design section and
  corrected revision 2's cost argument; see §10.
related:
  - "[[260424-oms-notification-rollback-risk-remediation]]"
  - "[[260424-runClubLine-transaction-boundary-hardening]]"
  - "[[SBDEV-2095-large-bol-close-decoupling-and-perf]]"
tags:
  - plan
  - wms1
  - oms-notification
  - transactions
---

# SBDEV-3266 — WMS→OMS picking Message rows silently discarded from afterCommit callbacks

**Tier: T3.** Data integrity · two production tenants · six months · the fix changes the transaction
propagation of every outbound OMS notification, and the outward POSTs it governs are irreversible.

> **Revision 3 (2026-09-08).** Two independent review passes. The first invalidated revision 1's
> §3.2/§3.3/§5.2; the second found revision 2's replacement cost argument **backwards** and its
> catch-widening actively harmful. The diagnosis (§1, §2) has survived both passes unchanged and got
> *stronger* each time. §10 lists every correction so a reader of any earlier revision can diff.

---

## 1. Problem Statement

ShipItEz W1 reported order `121603967` (`009611-000002`, external `124554`) as `Picked` in WMS but
`Picking` in OMS. The reported symptom is the visible tip of a **six-month outage of the WMS→OMS
picking audit trail** on v1 production.

`MessageService.createServiceLog` carries **no** `@Transactional`. Called from inside a
`TransactionSynchronization.afterCommit()` callback, `messageRepository.save()` joins the
already-committed outer transaction as a *non-new participant*.
`AbstractPlatformTransactionManager.processCommit` skips `doCommit()` for a participant
(`status.isNewTransaction()` is false), so the write is never flushed and dies when
`cleanupAfterCompletion` closes the `EntityManager`. No exception. No log line.

Spring's own javadoc on `TransactionSynchronization.afterCommit()` describes this case and
prescribes the remedy: *"no commit following anymore … Use `PROPAGATION_REQUIRES_NEW`."*

**⚠️ Scope correction that governs the whole plan: the HTTP POST to OMS still fires.** This is an
audit-trail outage, not (necessarily) a delivery outage — see §2.3, including its carve-outs.
No backfill may be built on the premise that OMS was never told.

---

## 2. Root Cause Analysis

### 2.1 The mechanism (CONFIRMED against spring-tx / spring-orm 5.2.12.RELEASE sources)

`processCommit` runs `doCommit(status)` → `triggerAfterCommit(status)` → `triggerAfterCompletion(…)`
→ `cleanupAfterCompletion(status)` in a `finally`. So during `afterCommit()`:

- `EntityManagerHolder.transactionActive` is cleared **only** by `EntityManagerHolder.clear()`,
  called from `JpaTransactionManager.doCleanupAfterCompletion` — which has not run. So
  `isExistingTransaction()` is still `true`.
- `SimpleJpaRepository.save()` is `@Transactional` with default `REQUIRED`, so it **joins** rather
  than beginning a new transaction, and the participant's commit is a no-op.

### 2.2 Two observed cliffs, plus a third recovered by a payload-shape split

A process type survives only while it still has a producer that is **not** an afterCommit callback.
Measured last rows (`created >= 2026-01-01`), both tenants:

| process | shipitez last row | wineco last row |
|---|---|---|
| `…PICKING_TOTE_ASSIGNED` | 2026-03-04 09:16:07 | 2026-03-04 14:30:41 |
| `…PICKING_STARTED` | 2026-06-08 10:12:13 | 2026-06-30 09:01:16 |
| `…PICKING_FINISHED` | 2026-06-08 10:12:14 | 2026-06-30 09:01:17 |

STARTED and FINISHED die **in the same second** on each tenant, so production shows **two** directly
observable cliffs. The third is an inference from the payload-shape split below, not an observation.

| commit | deferred | first tag | tag date (`taggerdate`) | observed cliff |
|---|---|---|---|---|
| `9c78f1c` | TOTE_ASSIGNED (`MobilePickingService.processPick`) + PICKING_STARTED (`confirmPick`) | v1.26.15 | 2026-03-05 | 2026-03-04/05 |
| `0f8deca` | PICKING_FINISHED (`finishPickingOrder`) | v1.26.17 | 2026-03-05 | PICK_PACK gone by 2026-04 |
| `f46cf06` | the CLUB path, all three (`runClubLine`) | v1.26.38 | 2026-06-15 | 2026-06-30 |

⚠️ **Tag date ≠ deploy date, and this repo cannot derive deploy dates.** Five club runs produced
rows on wineco *after* v1.26.38 was tagged (06-15 ×4, 06-16 ×8, 06-24 ×2, 06-25 ×2, 06-30 ×2), so
the deploy lags the tag by ≥15 days. Treat tag dates as lower bounds.

**Cliff 1 is a cliff, not a lull — this is the strongest single piece of evidence in the document.**
shipitez, orders with `historytote IS NOT NULL` vs `TOTE_ASSIGNED` messages, by day:

| day | orders given a tote | TOTE_ASSIGNED msgs |
|---|---|---|
| 2026-03-03 | 22 | 28 |
| 2026-03-04 | 14 | 15 (last 09:16) |
| 2026-03-05 | 21 | **0** |
| 2026-03-06 | 327 | **0** |
| 2026-03-11 | 435 | **0** |

Business volume rose ~20× while the message stream went to zero.

**The producer split explains the middle date.** `TOTE_ASSIGNED` died first and alone because
`processPick` was its only live producer (`OrderMonitorViewService.printToteLabels` and the
confirmed-dead `rapidPickingConnectPackageAndType` are the other two). STARTED/FINISHED ran three
more months on **club volume only** — `runClubLine` still called them directly until v1.26.38.
Classifying `ORDER_BATCH_PICKING_FINISHED` on shipitez by whether the payload carries a `C1-` tote
label: Feb 2148/6, Mar 139/13, Apr **0**/5, May **0**/8, Jun **0**/2.

⚠️ **The classifier is tenant-specific.** `C1-` is shipitez's tote-label pattern (a per-tenant
sysprop); on wineco it classifies nothing as PICK_PACK. The wineco totals nonetheless reconcile with
the club-share reading exactly (Jan 907 total / 12 club; Apr 71 total / 71 club).

### 2.3 Proof that the POST still fires

`BasicService.generateMessageNumber` → `SequenceTransactionService.getNextSequenceNumber` is
`@Transactional(REQUIRES_NEW)`, so the counter commits independently of the discarded work.
`"WEBSERVICE_MESSAGE"` appears **once** in `src/main` (in `createServiceLog`), so that method is the
only burner of the series. The retry loop in `BasicService` does not burn: on
`ObjectOptimisticLockingFailureException` the inner transaction rolls back before committing.

```sql
SELECT date_trunc('month', created) AS mon, count(*) AS rows_present,
       (max(number::bigint) - min(number::bigint) + 1) - count(*) AS numbers_burned
FROM message GROUP BY 1 ORDER BY 1;   -- wms1-shipitez1
```

| period | numbers burned |
|---|---|
| **2022-07 → 2026-02 (51 months)** | **0–14 per month; zero in 40 of them** |
| **2026-03** | **14 562** |
| 2026-04 → 09 | 5 205 / 4 418 / 2 606 / 1 050 / 1 734 / 626 |

March's 14 562 ≈ 3× that month's order volume (three notifications per order) against a **four-year**
clean baseline.

**Carve-outs — the inference is strong, not airtight:**

1. `createMessage` runs after `httpRestService.post` returns on the SENT path, but the
   `catch (IOException e)` branch is reachable **before** the POST via `writeValueAsString`, and it
   burns a number too. A Jackson failure on these DTOs is presumably negligible, but a burn does not
   *strictly* prove the POST fired.
2. Any transaction that calls `createMessage` and then rolls back also burns a number with no row —
   a mechanism unrelated to afterCommit. The 51-month baseline rules it out as the March **cause**.
3. Cleanup deletes: `CleanUpOldMessageJobService` runs `archiveMessages` and then, **independently**,
   `deleteMessages`. So an empty `message_archived` is *consistent* with the archive INSERT failing
   while the DELETE proceeded — revision 1's "archived is empty, therefore not archival" reasoning
   was invalid. What actually rules cleanup out is the **shape**: cleanup deletes oldest-first
   (`created < refDate`), whereas the burn is concentrated in the newest months and the oldest
   months are clean.

Also: `messageRepository.getNextId()` burns the **shared** `seqentities` sequence on every lost row.
Do not use `seqentities` gaps as an instrument for anything.

### 2.4 Compounding defects

- `catch (IOException e)` is dead code around every `httpRestService` call — RESTEasy throws
  unchecked `ProcessingException`. **14** such blocks (heuristic: first `catch` within 45 lines of
  each of 18 live call sites; `StockSummaryExportJob` may make it 15). Exactly one —
  `MessageService.resendMessage` — is fully unreachable, its `try` containing no serialization.
  Note `BolClosedEventListener` and `AdminActionController` already use `catch (Exception e)`.
- `PickingorderBusinessService` sets `pickingconfirmationsent = true` *inside* the transaction
  before the deferred call, so it is `true` for every affected order. Two readers
  (`CustomerorderService`'s cancellation-strategy branch, and an order-details display echo); no
  retry consumer anywhere.

### Affected Locations

**5 `registerSynchronization` sites** (`git grep -n "registerSynchronization" -- src/main`):

| # | File | Enclosing method | Guarded by `isSynchronizationActive()`? | Callback writes to DB? |
|---|---|---|---|---|
| A1 | `CustomerorderBatchService` | `runClubLine` | yes, with synchronous `else` | **yes — lost** (3 OMS calls) |
| A2 | `PickingorderBusinessService` | `finishPickingOrder` | yes, with synchronous `else` | **yes — lost** |
| A3 | `PickingorderBusinessService` | `confirmPick` | **no** | **yes — lost** |
| A4 | `MobilePickingService` | `processPick` | **no** | **yes — lost** |
| — | `MobileReplenishService` | `scheduleRefillAfterCommit` | yes | safe (`REQUIRES_NEW`) |
| — | `BolClosedEventListener` | `@TransactionalEventListener(AFTER_COMMIT)` | n/a | safe (`createMessageInNewTransaction`) |

`BolClosedEventListener` is the control that isolates the cause: same `triggerAfterCommit` phase,
still writing `ORDER_BATCH_SHIPPED` rows on **both** tenants as of 2026-09-04. **The phase is not
the problem; the propagation is.**

---

## 3. Design / Proposed Fix

### 3.1 The `MessageService` call graph (get this right or the fix is inert)

```
external callers ──► createMessage(…)                    [no @Transactional]        50 call sites
                 ──► createMessageInNewTransaction(…)     [@Transactional REQUIRES_NEW]  2 call sites
                                    │
                    (in-class, proxy BYPASSED)
                                    ▼
                          createServiceLog(…)             [no @Transactional]        0 external callers
                                    ▼
                          messageRepository.save(m)       [@Transactional REQUIRED]
```

`sendStockChangeMessage` and `resendMessage` call `createMessage(…)` **unqualified from inside
`MessageService`** — 4 in-class calls whose proxy is bypassed. Census: 59 grep lines − 2 declarations
− 3 commented = **54 live call sites = 50 external + 4 in-class**.

### 3.2 Options considered

| # | Option | Verdict |
|---|---|---|
| 1 | `@Transactional(REQUIRES_NEW)` on `createServiceLog` | **Inert.** It has 0 external callers — all 3 call sites are self-invocations from `createMessage`×2 and `createMessageInNewTransaction`. Spring's proxy is bypassed, so the annotation is never honoured. It does not work; it is not a hazard either. |
| 2 | `@Transactional(REQUIRES_NEW)` on `createMessage` | Works — all **50** external callers would genuinely get it (`MessageService` implements no interface, so CGLIB proxies it; both overloads carry the annotation). Rejected on **blast radius** (50 sites vs 10, including every controller export path — `OrderRestController` ×10, `AdviceRestController` ×6, `SkuRestController` ×4, `TransactionReportRestController` ×4, plus `AdviceService` ×6 and `StockSummaryExportJob` ×2) and on **semantics**: it would make it impossible for *any* message row anywhere to roll back with its business transaction, which §3.3(2) justifies only for paths where a POST demonstrably happened. Not rejected for the 4 in-class sites being exempt — that is repairable in three lines and would make the choice look contingent. |
| 3 | **Route `ManageOrderService`'s 10 `createMessage` calls to `createMessageInNewTransaction`** | **Chosen.** See §3.3. |
| 4 | Give only the deferred path its own route (flag / second method pair) | Rejected: adds a parameter whose correct value the caller cannot reliably know, to avoid a cost §3.3 shows is acceptable. |

> Revision 1 rejected option 1 on the grounds that `createServiceLog`'s "~40 callers" would each take
> a second concurrent connection. That mechanism **cannot fire** — there are no such callers. The
> conclusion (don't blanket-apply) stands; the stated reason was wrong and is retracted.

### 3.3 Chosen fix, and its real blast radius

Switch the 10 `createMessage` calls inside `ManageOrderService`'s five notification methods
(`customerOrderOnHold`, `customerOrderReleaseForPicking`, `customerOrderToteAssigned`,
`customerOrderPickingStarted`, `customerOrderPicked` — SENT path + FAILED path each) to
`createMessageInNewTransaction`. That method already exists, is already `REQUIRES_NEW`, and is
already proven in production by `BolClosedEventListener`.

**This is not confined to the four afterCommit callbacks, and the plan says so.** Those five methods
have **6 deferred call sites** (A1×3, A2, A3, A4) and **9 non-deferred ones**:

| caller | sites | context |
|---|---|---|
| `CustomerorderBatchService` | 3 | `runClubLine`'s synchronous fallback — inside the TX |
| `PickingorderBusinessService` | 1 | `finishPickingOrder`'s synchronous fallback — inside the TX |
| `OrderMonitorViewService` | 1 | `printToteLabels` |
| `MobilePickingService` | 1 | `rapidPickingConnectPackageAndType` (confirmed dead) |
| `ReleaseOrderJobService` | 3 | scheduled job paths |

*(Review reported 8; the enumeration above lists 9. Method: literal-name grep excluding
`ManageOrderService.java`, minus one javadoc mention in `AdminActionController`. Blind spot: a
reflective or lambda-captured reference would be missed; none seen.)*

**Two consequences. Only 3 of the 9 are actually affected:**

1. **Six of the nine have no live transaction to suspend, so REQUIRES_NEW simply becomes their only
   transaction — net one connection, exactly as today.**

   | caller | sites | live transaction there? |
   |---|---|---|
   | `CustomerorderBatchService` | 3 | **No** — the `else` of `if (isSynchronizationActive())`, so by construction it runs only when no Spring transaction exists. Dead in production anyway: the class carries a class-level `@Transactional` (its own comment says the branch should not fire). |
   | `PickingorderBusinessService` | 1 | **No** — same `else`-of-`isSynchronizationActive()` construction. |
   | `OrderMonitorViewService` | 1 | **No** — `printToteLabels` has no method annotation, `OrderMonitorViewService` has **zero** `@Transactional` in the whole file, and its caller `DashboardController` has none either. |
   | `MobilePickingService` | 1 | **No, and dead** — `rapidPickingConnectPackageAndType`'s only caller chain terminates in a **commented-out** block in `controller/mobile/PickingController`. |
   | `ReleaseOrderJobService` | 3 | **Yes** — all three sit inside `releaseOrder`, annotated `@Transactional(propagation = REQUIRES_NEW, rollbackFor = {BusinessException.class, FacadeException.class})`. |

   So **3 of 9** take a second concurrent connection, and all three execute in a **scheduled job, off
   the request path**. That is a real bound, and it means this design does not depend on the measured
   pool size at all.

   ⚠️ Revisions 1–2 argued these paths were safe *because* they already pin a connection across the
   5 s + 15 s POST, so a millisecond INSERT is "marginal". **That reasoning is backwards and is
   retracted.** Pool exhaustion counts simultaneously-held *slots*, not elapsed milliseconds —
   precisely because those paths pin a connection for up to 20 s, they are when all slots are most
   likely occupied, which is exactly the instant a second acquisition blocks for the full
   `connectionTimeout` and throws. The change is cheap in time and expensive in slots, and slots are
   what ran out in March.

   ⚠️ **Corrected arithmetic (review finding M6).** An earlier draft said "N before, up to 2N inside
   the suspend window". That missed a suspend that was already there: `createServiceLog` →
   `BasicService.generateMessageNumber` → `SequenceTransactionService.getNextSequenceNumber`, which is
   itself `@Transactional(REQUIRES_NEW)`. So on the three `ReleaseOrderJobService` sites the real depth
   is outer `releaseOrder` [REQUIRES_NEW] → `createMessageInNewTransaction` [REQUIRES_NEW] →
   `getNextSequenceNumber` [REQUIRES_NEW] = **three** concurrent connections, where it was **two**
   before. The pre/post delta is still **+1 per site**, which is what the conclusion rests on, so the
   conclusion survives — but the baseline was wrong by one. No new lock-ordering hazard: the sequence
   hop uses optimistic locking with a retry loop, not row locks, so this is not the
   REQUIRES_NEW-inside-a-lock-holder deadlock shape.

2. **A row will now survive a rollback of the business transaction — on `ReleaseOrderJobService`'s 3
   sites only.** For the other six there is no transaction, so there is no rollback and nothing
   changes; stating it for all nine would imply a behaviour change that will not occur. Where it does
   apply the semantics are intended: the POST really happened, so the record should outlive the
   rollback — a durable record of exactly the rollback-after-notify desync that
   `260424-oms-notification-rollback-risk-remediation` exists to address. **Carve-out:** a **FAILED**
   row can also now survive a rollback on a path where the POST did *not* fire (§2.3 carve-out 1,
   `writeValueAsString` throwing before the POST). Not a correctness problem — a FAILED row asserts
   nothing about delivery — but do not describe the surviving row as proof the POST happened.

**In the deferred case the connection count is net one, not two** — and this is the documented
default path, not a hope: `LogicalConnectionManagedImpl.afterTransaction()` releases the physical
connection for any release mode ≠ `ON_CLOSE`, and it runs inside `EntityTransaction.commit()`, i.e.
inside Spring's `doCommit`, **before** `triggerAfterCommit`. Suspending mid-callback is also safe:
`triggerAfterCommit` iterates the *copy* returned by `getSynchronizations()`, and
`suspend()`/`resume()` are no-ops on `TransactionSynchronizationAdapter`, so remaining callbacks are
neither dropped nor double-invoked.

**Do NOT extend this change to:**
- `MessageService.sendStockChangeMessage` or `resendMessage` — their `createMessage` calls are
  in-class, so renaming them changes nothing. Fixing those needs self-injection,
  `AopContext.currentProxy()`, or moving the caller out of `MessageService`. Out of scope.
- `resendMessage` additionally mutates and re-`save()`s the returned `Message`, which would be
  **detached** once the inner transaction commits.

### 3.4 Also in scope: make the failure path reachable

`catch (IOException e)` → `catch (Exception e)` at the five `ManageOrderService` notification
methods, recording the exception class in the FAILED row. Without this the fix produces `SENT` rows
only and stays blind to the transport failures it exists to surface.

⚠️ **Narrow the `try` first, or the widening does harm.** In all five methods the success-path
`createMessage(… SENT …)` sits **inside** the `try`. Widening the catch without restructuring means:

- if the **SENT write itself throws**, the catch fires and records a **FAILED** row instead —
  masking exactly the failure class this ticket exists to surface, and burning a second
  `WEBSERVICE_MESSAGE` number, so a regression in this very fix would be logged as a transport error;
- it newly swallows `BusinessException`, which these methods declare and which the anonymous-user
  `orElseThrow` in `createServiceLog` raises;
- it newly swallows the latent NPE where `unitloadRepository.findById(…).orElse(null)` is immediately
  dereferenced for `getLabelid()`.

So: scope the `try` to `findSysvalueBySyskey` → `writeValueAsString` → `post`, and move the SENT
write **after** it. Only then does `catch (Exception e)` mean what this section wants.

⚠️ **The widening changes what propagates — resolved by re-throwing (review H1). IMPLEMENTED.**

Pre-fix, `catch (IOException)` caught nothing RESTEasy throws, so a `ProcessingException` propagated;
but it *did* catch and swallow `IOException` / `JsonProcessingException`. Widening to
`catch (Exception)` would have swallowed everything, turning the **9 synchronous** call sites from
fail-loud to fail-silent — including `ReleaseOrderJobService`, which saves the order `ASSIGNED` and
the batch `STARTED` eight lines before the POST.

**Resolution: record the FAILED row, then re-throw.** No caller-supplied flag is needed because the
call sites self-discriminate — verified mechanically, it is a perfect binary:

| | count | wrapper | effect of the re-throw |
|---|---|---|---|
| **deferred** callbacks | 6 | all `catch (Exception e) { LOG.error }` | absorbed — behaviour unchanged |
| **synchronous** callers | 9 | none | propagates — caller fails loudly, transaction rolls back |

**15 call sites across 5 classes.** (Earlier drafts said "eight in four classes" and "twelve"; both
were wrong — the miss was `PickingorderBusinessService`'s `finishPickingOrder` else-fallback, which
is live via `AdminActionController.finishStuckPickingOrder` and `CustomerorderService`.)

The audit row is written under `REQUIRES_NEW`, so it **commits independently and survives the
caller's rollback** — row and loud failure are not in tension, which is why this beats swallowing.

⚠️ **This is not a zero-delta change; do not describe it as one.** The two branches land on opposite
sides of `OrderReleaseJob`'s catch list (`OptimisticLockException | OptimisticLockingFailureException
| FacadeException | BusinessException`):

- `ProcessingException` — unchecked, rethrown as-is, matches none of those → **aborts the release
  pass**, exactly as pre-ticket. Delta zero. ✔
- `IOException` / `JsonProcessingException` — checked, wrapped in `BusinessException` → **caught,
  logged, pass continues to the next order** with this one rolled back. Pre-ticket it was swallowed
  and the order was released-and-committed with OMS never told. **This is an intended improvement**,
  not an accident, and it is the reason to keep the checked wrap rather than throw unchecked.

Pinned by `OmsNotificationAfterCommitIT` T3 (synchronous propagates) and T3c (deferred absorbs, row
survives), plus rail `R1c` (every `manageOrderService.*` call inside a callback body is enclosed in
`catch (Exception ...)` — the structural fact no integration test can establish, since a test
supplying its own try/catch proves nothing about production).

---

## 4. V1/V2 Applicability

v2 already has `@Transactional(value = "tenantTransactionManager", propagation = REQUIRES_NEW)` on
its `createServiceLog` and retired the afterCommit dispatchers for a transactional outbox under
SBDEV-2381. **Nothing here ports forward.**

v2 carries the same *class* of bug by a different mechanism — filed separately as **SBDEV-3267**.

---

## 5. Prerequisites & Implementation Plan

### 5.1 Prerequisites

1. **Establish the production HikariCP pool size from the running container**, not from the repo.
   `application.properties` says `maximumPoolSize=5` / `connectionTimeout=20000`, but the same file
   pins a **dev** datasource URL (`dev.sbo.li`), the Dockerfile sets
   `SPRING_PROFILES_ACTIVE=wineco`, and **no `application-wineco.properties` has ever existed on any
   ref** — so production config comes from outside the jar and the in-repo 5 is a dev default. The
   pool plan `9c78f1c` shipped says the pool "maxes out at **25**" with a **30 s** timeout, matching
   neither in-repo value — but that figure is **unsourced and internally suspect**: it cites no log
   line, metric or measurement; 30 s is exactly HikariCP's *default* `connectionTimeout` (which this
   repo overrides to 20 000); and "25" recurs ten lines later with an unrelated referent ("all 25
   `@Transactional` annotations"), so a conflation is at least as plausible as a measurement.
   **Honest position: the deployed pool size is unknown.** The in-repo 5 is a dev-profile value and
   the cited 25 / 30 s is not evidence. Read the real number off `/actuator` or the container env.
   Note §3.3(1) no longer depends on the answer, so this is **not a blocker** for implementation —
   it sizes T4's concurrency run, nothing else.
2. ~~**Decide whether v1 ShipItEz W1 is worth fixing at all.**~~ **ANSWERED 2026-09-08 (Nam): fix
   both v1 and v2, v1 first.** Not a blocker.

### 5.2 Implementation Checklist

1. Write the failing IT (§6 T1) with the harness pinned per O4, and confirm it fails **as a missing
   row**, not an exception.
2. Confirm the positive control (§6 T2) is green **before any fix**.
3. **In `ManageOrderService`**, switch the 10 `createMessage(` calls in the five notification
   methods to `createMessageInNewTransaction(`. *(Revision 1 said "switch A1–A4's `createMessage`
   calls" — A1–A4 contain none; they call `manageOrderService.customerOrder*`.)*
4. Narrow those five methods' `try` to sysprop→serialize→post, move the SENT write after it, then
   broaden the catch to `Exception` and record the exception class (§3.4 — order matters).
5. Add the §3.5 rail with its depth statement and non-vacuity guard.
6. Run T4 as confirmation.
7. Full suite compared against the known baseline — which failures, not whether it passed.

---

## 6. Test Plan

| # | Test | Pre-fix | Post-fix |
|---|---|---|---|
| T1 | IT: `@Transactional` service method registers an afterCommit that reaches `createMessage`; commit; assert the row exists **by id** | **RED (no row)** | GREEN |
| T2 | **Positive control** — same shape via `createMessageInNewTransaction` | GREEN | GREEN |
| T3 | POST throws `ProcessingException` inside the callback → assert a **FAILED** row naming the exception class | RED | GREEN |
| T4 | **Confirmation** (not a gate) — concurrency at the *measured* pool size; no `SQLTransientConnectionException`, p99 unchanged | n/a | pass |
| T5 | Rollback: business tx rolls back → callback never fires → no row, no POST | GREEN | GREEN |

**⚠️ T1's harness must be pinned against OSIV or it goes false-green.** `spring.jpa.open-in-view` is
unset (Boot default `true`). If the IT drives the code through MockMvc or a real request,
`OpenEntityManagerInViewInterceptor` binds an EntityManager for the request, `doBegin` reuses it,
`doCleanupAfterCompletion` explicitly does **not** close it, and the queued row sits in a still-open
persistence context that **any later transaction in the same request will flush**. The same defect
then looks present or absent depending on how the test invokes the code. So: call the service
directly with no OSIV, and read the row back on a connection other than the one under test.

`createServiceLog` assigns its own id, so `save()` is a `merge` (extra SELECT — don't assert query
counts) and the pre-fix RED arrives as *no row*. A red arriving any other way is a harness failure,
not a kill.

**Mutation check (mandatory).** Revert step 3 and confirm T1 goes red **naming the missing message
row**; repeat for T3 by narrowing the catch back to `IOException`.

**Deliberately skipped:** nothing asserts OMS actually received the POST — there is no OMS-side read
and `v1/oms` (ZF2) is not in the checkout.

---

## 7. Notes & Risks

| Risk | Mitigation |
|---|---|
| Production pool size unknown | §5.1 prerequisite 1. T4 sizes to the measured number. |
| 3 callers (all in a scheduled job) gain a second short-lived connection | Accepted, §3.3 (1). The other 6 have no transaction to suspend, so the design does not depend on the pool size. |
| Rows now survive a business rollback on `ReleaseOrderJobService`'s 3 paths | Intended, §3.3 (2), with the FAILED-row carve-out. Flag in the PR. |
| §3.5 rail passes vacuously at one hop, or goes red on green code | §3.5 mandates the first-boundary form plus a non-vacuity guard on the callbacks scanned. |
| `createServiceLog`'s anonymous-user `orElseThrow` | **Confirmed clear:** the `mywms_user` `anonymous` row exists on both tenants (`id=1`), and `WmsConstants.USER_ANONYMOUS` and `SecurityContextUtils.ANONYMOUS` are both `"anonymous"`. They live in different classes and can drift, so keep the check in the suite. |
| `createMessageInNewTransaction` has no `rollbackFor` | `BusinessException` is checked, so Spring commits rather than rolls back. Harmless here; the codebase convention is otherwise and a reviewer will ask. |
| ~~Synchronous call sites change from fail-loud to fail-silent~~ | **CLOSED** — neutralised by the §3.4 re-throw (Nam approved 2026-09-08). Residual, intended: a checked failure now skips one order instead of releasing it uncommunicated. `ReleaseOrderJobService`'s third site is the one where committed state diverges from OMS. Flag in the PR body; the FAILED-resender follow-up is what closes it. |
| Reviewers assume "0 message rows" ⇒ "OMS never told" | §1 and §2.3 state the correction twice, deliberately. |

**Do not trust `260424-oms-notification-rollback-risk-remediation.md`.** `status: implemented` with a
§11 manifest naming `OmsNotificationHelper.java` and `OmsNotificationProgramIT.java`; neither exists
on any ref (`git log --all -S` for both symbols returns nothing; `--diff-filter=A` never adds them).
Blind spot: local clone refs only. It would not have fixed this anyway — its S10 row gives the
picking path only a `LOG.error` upgrade.

---

## 8. Backfill — do not

```sql
-- wms1-shipitez1
SELECT count(*) AS total,
       count(*) FILTER (WHERE state >= 700)                                  AS shipped,
       count(*) FILTER (WHERE state BETWEEN 600 AND 699)                     AS still_in_600s,
       count(*) FILTER (WHERE state BETWEEN 600 AND 699
                          AND pickingtote_id IS NULL)                        AS no_tote_left
FROM customerorder
WHERE created >= '2026-03-05' AND historytote IS NOT NULL;
```

At time of writing: **14 249** total, **14 124** already past state 700, **125** still in the 600s,
of which **124 have `pickingtote_id IS NULL`** — nulled at the PACKED transition. For those,
`customerOrderPicked` sources `toteLabel` from `pickingtoteId` (never `historytote`, for non-CLUB),
so `NON_NULL` drops the field and OMS rejects with *"has no UL Code"*. `historytote` still holds
every label but no v1 code path reads it for PICK_PACK.

The state-600 count is a moving target and has already dropped as the incident orders were
remediated. **Re-run the query; do not cite these numbers.**

Re-announcing status 25 to a parcel OMS has already QA'd is a **backward** transition into a system
where carrier-label generation is real money. Fix only what is still at state 600.

**Unresolved blocker:** `v1/oms` (ZF2) is absent from the checkout and is what serves shipitez, so
OMS-side idempotency is unverified. That is the question that decides bulk safety.

---

## 9. Acceptance

No verify script — T3's script is opt-in and every assertion here belongs in JUnit. T1–T5 are the
acceptance criteria.

The floor applies unchanged: one DB query confirming the symptom (§2.3, done) · one failing test
first, failing for the right reason (T1, harness pinned per §6) · mutation-check every new assertion
· one independent review, never self-approve · full suite compared against the known baseline.

---

## 11. Implementation Status

**Implemented 2026-09-08. PR: https://github.com/SiteBossInc/wms-api/pull/207 — MERGED to `develop` 2026-09-08 21:39 UTC, merge commit `2406e00`.**
Branch `bugfix/SBDEV-3266-oms-message-rows-aftercommit`, worktree
`.claude/worktrees/wms-api/SBDEV-3266`, off `origin/develop` @ `a0e859a`.

| SHA | What |
|---|---|
| `9c429a8` | TDD gate — T1/T2/T3/T5 |
| `0ea3933` | §3.3 + §3.4 — 10 audit writes to `createMessageInNewTransaction`; try narrowed, catch widened |
| `e3a9a4f` | review pass 1 — 6 Medium + 9 Low |
| `a63ac6b` | landed M1/M4/L1, destroyed from `e3a9a4f` by a `git checkout --` in the author's own mutation script |
| `ae05843` | §3.4 H1 — re-throw after recording the FAILED row |

### Files

| File | Change |
|---|---|
| `service/ManageOrderService.java` | the fix — 5 methods restructured |
| `service/OmsNotificationAfterCommitIT.java` | new — 6 tests (T1, T2, T3, T3b, T3c, T5) |
| `unit/service/OmsAfterCommitPropagationRailTest.java` | new — 4 tests (R1a/R1b, R1c, R2, R3) |
| `unit/service/ManageOrderServiceUnitTest.java` | 6 collaborator sites + 2 failure-path tests updated; 1 added (M4 pin) |

### Results

- Targeted **28/28**. Full suite **1788 / 0 fail / 19 err / 1 skip** against a pre-edit baseline of
  **1783 / 0 fail / 19 err / 1 skip** — +5 tests, **failure set identical** (`ClientRepositoryH2Test` 8,
  `LocationRepositoryH2Test` 8, `FixLocationAssignmentServiceUnitTest` 2, `StockunitServiceUnitTest` 1).
- **Mutations 13/13 killed**, each attributable. M1 (log reorder) adds no assertion, so nothing to check.
- Conformance verifier **PASS 7/7**, independently re-run. Three code-review passes, all findings fixed.

### Deliberately not done

- **T4 (pool concurrency) — NOT RUN.** Needs the production HikariCP size read off the running
  container (§5.1 prerequisite 1). Downgraded to a confirmation in revision 3 because §3.3(1) stopped
  depending on the number.
- `verify-docs` not run.
- L9 (an OMS 4xx/5xx still records `SENT`) proposed on the ticket as a follow-up, not implemented.

### Landmines the plan did not predict

1. **The v1 IT lane was never broken.** Five ITs carry `@Disabled("SBDEV-2384 … ro_id view drift")`;
   `ro_id` landed in V1.26.30 and the real blocker is a `BeanDefinitionOverrideException` from
   `unit/repo/RepositoryH2TestConfiguration`, with a one-property workaround already used by two
   other ITs. `ReplenishmentMonitorViewRepositoryIT` runs 14 green in 26s. Re-enabling the five is
   worth its own ticket.
2. **`git checkout --` in a mutation script silently ate three uncommitted fixes**, and every signal
   stayed green because none of them alters a test outcome. Commit before mutating; restore from
   `/tmp`.
3. **Concurrent Maven in one worktree** (review agents building while the suite ran) produced a wall
   of false `NoClassDefFoundError` reds.
4. **A count was wrong three times** (five → eight → twelve → **15 sites / 5 classes**) before being
   settled by enumeration.

---

## 10. Revision changelog

### Revision 5 — H1 resolved by re-throw; three false claims corrected

**H1 neutralised, not accepted.** Nam approved re-throwing after the FAILED write. The first review
pass said this needed a caller-supplied flag; it does not — the call sites self-discriminate, and a
mechanical enumeration confirms a perfect binary (6 deferred, all wrapped; 9 synchronous, none).

**Three counts were wrong and are corrected to 15 sites / 5 classes**: "eight in four classes" (the
reviewer's, copied here unchecked) and "twelve" (mine) both missed
`PickingorderBusinessService.finishPickingOrder`'s live else-fallback.

**"No behaviour change" was false** and was asserted in a commit subject and five code comments.
`ProcessingException` is delta-zero, but checked exceptions were genuinely swallowed pre-ticket and
now throw — landing on the opposite side of `OrderReleaseJob`'s catch list. Documented above.

**A vacuous assertion was found in the test written to pin H1's deferred half** (T3c asserted nothing
escaped, but supplied its own catch). Replaced by rail R1c.


### Revision 4 — second review pass + a recovered data loss

**Three fixes were silently missing from the tree.** M1 (log-before-write), M4 (honest failure code)
and L1 (dead import) were applied, compiled and tested — then destroyed by `git checkout --` inside
the author's own M9/M10 mutation script, because they were still uncommitted. Nothing downstream
noticed: none of the three alters a test outcome, so 25/25 green, the 1786/19 full suite and the
commit were all correct readings of a tree that had lost the work. Caught by the second review pass
diffing the commit against its own message. Landed in `a63ac6b`. **Process change: commit before
mutating, and restore from `/tmp`, never `git checkout`.**

**M4 was also wrong on its own terms.** It tested `e instanceof IOException` to decide 503 — but
`JsonProcessingException extends IOException` and `writeValueAsString` sits inside the try, so a
serialization failure that never reached the gateway would still have been stamped 503, the exact
misattribution M4 exists to remove. Now decided by position: `(payload != null) ? "503" : "500"`,
with a test pinning the 500 path (mutation-checked; nothing covered it before).

**§3.4's H1 count corrected**: eight synchronous sites in four classes, not five.

**Settled, not changed:** `@SpyBean MessageService` does not weaken T2 — Spring's `SpyPostProcessor`
is `PriorityOrdered` above the AOP post-processors, so the transaction proxy wraps the spy and
`REQUIRES_NEW` is genuinely exercised; a flipped ordering would turn T2 red, not green. Holds only
while `MessageService` implements no interface.


### Revision 3 — second review pass

**§3.3(1) rewritten; its central cost argument was backwards.** Revision 2 claimed all 9 non-deferred
callers suspend a live transaction, and accepted that because they "already pin a connection across
the POST, so it is marginal". Both halves were wrong. **Six of the nine have no live transaction at
all** — four are `else`-of-`isSynchronizationActive()` branches, `printToteLabels` runs in a class
with zero `@Transactional`, and `rapidPickingConnectPackageAndType` is dead — so only
`ReleaseOrderJobService`'s 3 sites take a second connection, and they run in a scheduled job off the
request path. And the "marginal" reasoning conflated hold *duration* with pool *occupancy*: long
holds are precisely when all slots are full, so a second acquisition there is worse, not cheaper.
The corrected argument is stronger and removes the design's dependence on the pool size.

**§3.3(2)** is vacuous for the same six (no transaction ⇒ no rollback); now scoped to the 3, with a
carve-out that a FAILED row can survive a rollback on a path where the POST never fired.

**§3.4 reordered — the widening as specified would have masked the fix's own failures.** The SENT
write sits *inside* the `try`, so `catch (Exception)` would record a failing SENT write as a FAILED
row (burning a second number), and would newly swallow `BusinessException` and a latent NPE. Narrow
the `try` first.

**§3.5 reworded to a first-boundary rule** — the "reaches a non-REQUIRES_NEW write" form goes **red
on correct code**, because the post-fix path still ends in unannotated `createServiceLog` → REQUIRED
`save`. The hardcoded "≥3 frames" is dropped.

**Counts.** `createMessage` is **50 external + 4 in-class = 54 live**, not "54 external" (§3.1, §3.2).
Option 2's rejection moved from "non-uniform" (repairable in three lines, so not decisive) to blast
radius + semantics. Removed "STOCK_UPDATE — the largest group": it is 2 116 rows on shipitez against
12 934 for PICKING_RELEASED. §5.1 no longer claims the deployed pool was "likeliest" 25 — that figure
is unsourced, 30 s is HikariCP's default, and "25" recurs with an unrelated referent. Anonymous-user
risk closed (verified on both tenants). The 9-vs-8 caller count settled at **9**.

### Revision 2 changelog

Corrections from the independent review (`.claude/worktrees/_reports/sbdev-3266-review.md`):

**Design — the whole section was rewritten.** §3.2's rejection of the one-line fix cited a mechanism
that cannot fire (`createServiceLog` has 0 external callers, so the annotation is inert, not
dangerous). §3.3 claimed "only the four A1–A4 callbacks change" — the real blast radius is 9
non-deferred in-transaction callers, which have the very property §3.2 used to reject the
alternative; now stated and justified rather than denied. The `sendStockChangeMessage` step was
inert (in-class self-invocation) and is removed. §5.2 step 3 was not executable and now names the
right 10 sites. T4 downgraded from gate to confirmation (net-one-connection is the documented path).

**Facts.** Pool size is **unestablished for production**, not 5 (§5.1). Burn baseline is **51
months**, not four (§2.3). v1.26.15's `taggerdate` is 2026-03-05, not 03-04, and tag ≠ deploy — cliff
3 has ≥15 days of rows after its tag (§2.2). "Exactly three cliffs" → two observed plus a shape
inference. The `C1-` classifier is tenant-specific. The `message_archived`-is-empty argument was
invalid and is replaced by the oldest-first shape argument (§2.3). `catch (IOException)` count 13 →
**14**. Unguarded `registerSynchronization` sites 1 → **2** (A3 as well as A4).
`pickingconfirmationsent` readers 1 → **2**.

**Additions.** §2.3 carve-outs (FAILED path, rollback, cleanup). §3.1 call-graph diagram. §6's OSIV
harness pin and the `merge`-not-`persist` note. §3.5's ≥3-frame depth requirement. §8's inlined
query. §7 rows for the anonymous-user throw, `rollbackFor`, and the detached return value.

**Unchanged and independently confirmed:** §2.1 mechanism against spring-tx/spring-orm sources; the
burn inference; the producer split explaining cliff 2; the phantom-file finding; §2.4's dead-code
and x-tenant claims.
