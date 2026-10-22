---
title: "SBDEV-3674 (v2) — MessageService.createMessage self-invokes createServiceLog; service-log rows lost on the afterCommit path"
ticket: "SBDEV-3674"
ticket_url: "https://app.clickup.com/t/868medkdd"
type: "bugfix"
severity: "high"
priority: "normal"
status: "on dev"
project: ["wms2-api"]
version: "v2"
scope: "oms-notification"
owner: "Nam Park"
requester: "nam.park@siteboss.net"
created: "2026-10-07"
updated: "2026-10-07"
revision: 2
last_verified: "2026-10-07"
verified_by: "Hydra PRD + hydra-uat + wineco-uat DB queries; code read of origin/develop @ ce454c68; three independent analysis lanes"
db_verified: true
db_verified_note: >
  Measured on 3 databases. One Phase-0 conclusion was retracted mid-analysis after two lanes
  falsified it; the retraction and its evidence are in §2.4. The three PRD tenant DBs other than
  Hydra were unreachable this session (connection timeout) — see §10 O-2.
related:
  - "[[SBDEV-3266-oms-message-rows-lost-in-aftercommit]]"
  - "[[SBDEV-2736-outbox-dispatcher-status-blind-rejection]]"
tags: [plan, wms2, oms-notification, transactions]
---

# SBDEV-3674 — service-log rows lost on the afterCommit path

**Tier: T3.** Data integrity of the `message` audit trail · transaction-propagation change · measured
loss on production · root cause was genuinely unknown at filing and two hypotheses were wrong.

Evidence lanes: `SBDEV-3674-evidence/{tracer-advice-import-row-loss,callsite-enumeration,architect-fix-shape}.md`.

---

## 1. Problem Statement

`MessageService.createMessage` (both overloads) calls `createServiceLog(...)` unqualified on `this`.
Spring `@Transactional` is proxy-based, so the
`@Transactional(value = "tenantTransactionManager", propagation = Propagation.REQUIRES_NEW)` on
`createServiceLog` is **inert on 37 of the 39 external call sites and on both internal ones** — the 2 exceptions being
the sites that call `createServiceLog` directly from another bean, where the proxy does apply.

Operator-visible symptom: entries are missing from the **Service Log** admin page for notifications
OMS actually received. On Hydra PRD only **28** `STOCK_UPDATE` rows exist for the whole life of the
tenant.

### 1.1 DB verification (floor item 1)

The sequence is the instrument. `MessageService` — the line
`m.setNumber(basicService.generateMessageNumber(WmsConstants.EntityPrefixes.EMPTY_PREFIX, "WEBSERVICE_MESSAGE"));`
— is the **only** consumer of `WEBSERVICE_MESSAGE` in `src/main` (derived by `git grep` on both
`WEBSERVICE_MESSAGE` and `generateMessageNumber`; blind to a reflective or SQL-literal consumer).
It resolves to `SequenceTransactionService.getNextSequenceNumber`, which is `REQUIRES_NEW` on a
**separate bean**, so *its* proxy fires and the number commits alone. Every lost row leaves a
permanent gap.

```sql
SELECT s.sequencenumber AS issued, (SELECT count(*) FROM message) AS rows,
       (SELECT count(*) FROM message_archived) AS archived
FROM los_sequencenumber s WHERE s.classname = 'WEBSERVICE_MESSAGE';
```

⚠ **Rates must be computed over the v2 era only.** Both UAT `message` tables carry **migrated v1
history** — `min(created)` is 2021-08-25 on hydra-uat and 2019-02-07 on wineco-uat — and a whole-table
rate dilutes the defect across years in which it did not exist. Burns by year are a clean **step
function at each v2 cutover**, which is itself the strongest evidence the defect is v2-specific:

**Rate = burned / issued**, where issued = surviving rows + burned. That is the fraction of
*attempted* service-log writes that were lost, and it is the denominator every figure below uses.

| env | era | surviving rows | burned | issued | **lost** |
|---|---|---|---|---|---|
| **Hydra PRD** (nywh) | all v2 (go-live 2026-07-12) | 3,001 | 402 | 3,403 | **11.8%** |
| Hydra UAT | pre-cutover (v1) | 63,847 | **3** | 63,850 | **0.005%** |
| **Hydra UAT** | post-cutover (v2) | 3,353 | 1,612 | 4,965 | **32.5%** |
| WineCo UAT | pre-cutover (v1) | 1,726,477 | **250** | 1,726,727 | **0.01%** |
| **WineCo UAT** | post-cutover (v2) | 64,245 | 42,285 | 106,530 | **39.7%** |

Cutover boundary taken as **2026-03-06** (hydra-uat) and **2026-03-05** (wineco-uat) — the day the
sustained burn starts; before it, Jan–Feb 2026 carry thousands of rows and zero burns. ⚠ **The exact
boundary moves the rate by ~1.5pp**: an independent lane cutting to the second (2026-03-06 19:46:57 /
2026-03-05 17:25:19) got 31.9% and 38.3%. The spread is definitional, not a disagreement about the
data; the conclusion — roughly a third of attempts lost — is stable across both.
An earlier revision of this plan quoted 2.35% and 2.32% for the two UAT environments, computed over
the whole table; those were understated ~10× and made PRD look like the worst tenant when it is the
best. **The positive control below is real and could not have caught this** — it tests that the
sequence and the table are one series, not that the rows share an era.

**Deletion excluded empirically.** `MessageCleanupBatchService` → `MessageRepository.deleteMessages`
is the only delete path **in `src/main` service code** (derived by `git grep` on `deleteMessages`,
`deleteById` and `DELETE FROM message`). `MessageRepository` is additionally SDR-exported and
`Message` is **not** in `RestConfiguration`'s write-disable list, so `DELETE /v3/message/{id}` is
published; whether it is reachable past the function guard was not tested, and a deletion by that
route would *inflate* the burn. The exclusion therefore rests on evidence, not on enumerating paths:
`message_archived` is empty, `min(number)` is 1 (3 on prd), and history reaches the first row ever
written on all three.
**Positive control:** `max(numeric number)` equals the sequence high-water exactly on all three, so
the sequence and the table are one series and the arithmetic is sound.

---

## 2. Root Cause Analysis

### 2.1 Three outcomes, not one

Every invocation burns a number. What happens to the **row** depends entirely on the caller:

| case | sites | what happens | row |
|---|---|---|---|
| **No enclosing transaction** | **33 of 39** | `SimpleJpaRepository.save`'s own `REQUIRED` opens one and commits | **survives** — correct by accident |
| **Inside `afterCommit`, reached THROUGH THE PROXY** | **1** — `BillofladingService`'s direct `createServiceLog` call, the only one inside a callback | the real `REQUIRES_NEW` suspends the completing transaction and commits its own | **survives — correct on purpose.** This is the state Fix A makes true everywhere, and what AC-1 grades |
| **Inside a live transaction** | **2** — `OrderBatchCreationService.createAll`, and `OmsNotificationService`'s inline `urlPath == null` site, which `return`s **before** the deferral branch and so runs in whatever transaction the caller holds | the insert joins it | **rolls back with it** |
| **Inside an `afterCommit()` callback** | **3** (`OmsNotificationService.doSend` ×3) | `processCommit` runs `triggerAfterCommit()` **before** `cleanupAfterCompletion()`, so a transaction is still bound. A `REQUIRED` save *participates* in one that has already committed: `isNewTransaction()` false so nothing commits, `isNewSynchronization()` false so nothing flushes, EntityManager closed at cleanup | **silently lost — no row, no exception** |

Case 3 is the repo's own stated model, in `BillofladingService`'s javadoc: *"a REQUIRED write from
afterCommit would join the finished transaction and be lost"*. It explains a loss rate with **no**
corresponding error rate, which is why it survived four years.

### 2.2 What the measured 402 are

`MessageService.sendStockChangeMessage` → `StockChangeNotificationService.sendAfterCommit` →
`OmsNotificationService.sendAfterCommit`. The middle service serializes **synchronously** and calls
through directly — it is not itself a callback — so this is a **single** deferral: the callback runs,
the POST fires, the number is allocated, only the row is discarded.

**Attribution — at DAY granularity, which is the resolution the evidence actually supports.**

| | days | burns | burns/day |
|---|---|---|---|
| days with receiving activity | 17 | 304 | **17.9** |
| days with none | 69 | 98 | **1.42** |

A **12.6×** ratio. That is the defensible instrument.

⚠ **An earlier revision used a per-interval test and over-claimed from it.** It reported "518 of 522
receipt positions fall inside a burn interval" and concluded the 402 *are* goods-receipt
`STOCK_UPDATE`. Two re-runs break that:

- **138 of 402 burns (34.3%), in 130 of 360 burn intervals, occur in intervals containing zero
  receipt activity.** Receiving explains at most ~66%.
- **There is no dose-response.** 334 of 360 burn intervals burn exactly 1 and average **0.67** receipt
  positions, while a single interval containing **210** positions burned **3**. If each stock change
  burned a number, burn count would scale with receipt volume. It does not.

"518 of 522" measured *containment of a dense, clustered stream by wide intervals* — nearly every
receipt falls in some interval, which says little about which interval burned.

**So: receiving-driven `STOCK_UPDATE` is the leading contributor and at most ~66% of the burn; the
remaining third is unattributed.** A burned number carries no timestamp and no process type, so SQL
cannot label it. Direct confirmation is AC-2; the residual is O-5.

### 2.3 ⚠ The scope boundary with SBDEV-3267 — only the burn reveals it

| | what happens | OMS receives it? | number | row | ticket |
|---|---|---|---|---|---|
| **Double** deferral — a synchronization registered from *inside* `afterCommit` lands in the list `triggerAfterCommit` is already iterating and is discarded unseen | nothing runs | **No — real data loss** | **not burned** | none | **SBDEV-3267** (fixed on develop) |
| **Single** deferral — §2.2 | callback runs | **Yes** | **burned** | none | **SBDEV-3674** |

`MobilePickingService` documents the first in `src/main`: *"no POST, no message row, no metric …
which is why Hydra prd has 0 ORDER_BATCH_PICKING_TOTE_ASSIGNED rows despite 139 of 148 orders
carrying a historytote."*

**So a burned number means `createMessage` was reached and its row was lost; a zero-row process type
with no burn means the callback never ran at all.** Nothing else in the schema separates those.

⚠ **A burn does NOT mean the notification was delivered**, and an earlier revision of this plan said
it did, in three places. `doSend` burns a number on **all three** of its exits — including
`catch (Exception e)`, where the POST threw and nothing reached OMS, and the non-2xx arm, where OMS
refused it. Telling an operator "a burn means it was delivered, do not resend" would be wrong in
exactly the cases where resending is the right action. The honest reading: *a burn proves the attempt
reached `createMessage`; it says nothing about the outcome, which is what the lost row would have
recorded.*

The 267 lost `TOTE_ASSIGNED` and the `ORDER_BATCH_ON_HOLD` zeros belong to SBDEV-3267 and **must not
be added to this ticket's 402**.

⚠ **This split is already moving.** SBDEV-3267's fix is on `origin/develop`: `MobilePickingService`
now calls `manageOrderService.customerOrderToteAssigned(...)` directly (*"SBDEV-3267: call directly —
sendAfterCommit ALREADY defers to afterCommit"*). That converts `TOTE_ASSIGNED` from a double to a
**single** deferral, so on deploy it stops being silent non-delivery and **migrates into this
ticket's population** — delivered, burned, unlogged. Do not re-derive the split against a tree where
it no longer holds.

### 2.4 Retracted during analysis — recorded so it is not re-derived

Phase 0 concluded that ~235 `ADVICE_IMPORT` rows were being lost, from *"all 237 advices carry a
non-null `externalid`, therefore all arrived over `PUT /rest/advice/create`"*. **Withdrawn.** Two
lanes broke it independently:

- **From the mechanism:** `AdviceRestController` has no `@Transactional` anywhere, and
  `open-in-view=false`, so there is no enclosing transaction and the row has nothing to roll back
  with. This ticket's mechanism cannot explain those 235.
- **From the data:** `externalid` has three writers, and `ReceivingService` writes
  `String.valueOf(System.currentTimeMillis())`. All 235 REGULAR advices carry a 13-digit `externalid`
  equal to their own `created` to within **0.9–27.8 ms** (235 of 235, single grouped aggregate). They
  were hand-keyed through *Create Inbound BOL*, never imported. The 2 RETURN advices carry
  `RETURN83031` / `RETURN83093` and are exactly the 2 with rows. `create()` ran twice and wrote a row
  both times.

The original burn attribution was also mis-located: it grouped gaps by the **following** row's
process only. By `(preceding, following)` pair, 330 of 402 sit between two consecutive rows of the
*same* type, and exactly one interval in the table touches an `ADVICE_IMPORT` row.

### 2.5 Second defect — `createServiceLog` returns an unmanaged, id-less entity

Independent of propagation, and the propagation fix does **not** subsume it:

1. `AbstractBaseEntity` declares `@Version private Integer version` — a wrapper.
2. Spring Data's `JpaMetamodelEntityInformation.isNew()` prefers a non-primitive version attribute
   over the id: version `null` → new.
3. `createServiceLog` sets `m.setVersion(1);` **before** saving → `isNew()` is **false**.
4. `save()` therefore calls `em.merge(m)` on an entity with a **null id**; merge of a transient
   instance persists a *copy*.
5. The copy is discarded — `messageRepository.save(m);` … `return m;`.

**Every caller gets back an entity whose `getId()` is `null`.** Confirmed consequences:

- **`resendMessage` double-inserts.** It mutates the id-less instance (`setResent`, `setRedeliverId`)
  and saves again → a second merge-of-transient → a second INSERT sharing the one allocated number.
  Hydra PRD: **2 of 2** resends produced a phantom twin carrying `resent = false` /
  `redeliver_id = null` — the shape of a *first-time* send. The operator's own replay tool
  manufactures evidence of a delivery that never independently happened, which is the same failure
  class SBDEV-3314/3325 were fixing on this method. It also means `message.number` is not unique.
- **Two log lines can only print `null`** — `ItemDataController` and `StockSummaryExportJob` both do
  `LOG.error("Message was not sent! messageId = {}", message.getId())` in their `catch (IOException)`
  paths.

Step 2 is **confirmed against the library source**, not inferred —
`spring-data-jpa-3.5.7` (the line Boot 3.5.9 manages), `JpaMetamodelEntityInformation.isNew`:
it defers to the id only when the version attribute is absent or primitive, and otherwise returns
`wrapper.getPropertyValue(versionAttribute.getName()) == null`. `AbstractBaseEntity`'s version is a
non-primitive `Integer`, and `SimpleJpaRepository.save` is `isNew ? persist : merge`. Chain closed
end to end. AC-5 pins it.

### 2.6 ⚠ `4a91fe40` (SBDEV-3325, 2026-10-07) widened the defect

The PR whose review lane filed this ticket added a **second** create-mutate-save site, in
`resendMessage`'s FAILED branch. It is on `develop` but not on PRD (0.0.37) or UAT (0.0.38), so it
can be corrected before it promotes.

---

## 3. Fix Design

### Fix A — route `createMessage` through the proxy by self-injection

```java
// MessageService
@Lazy @Autowired
private MessageService self;          // see the existing @Lazy stockChangeNotificationService field

public Message createMessage(...) throws BusinessException {
    return self.createServiceLog(...);
}
```

4 lines, one file, **zero** changes to the 37 external call sites.

**Why this and not the alternatives.** It is a four-times-established pattern *in this package* —
`CustomerorderBatchService`, `ReplenishGeneratorService`, `ReplenishmentOrderMaintenanceService` and
`ReturnAdviceAutoReceiveService` all hold a `@Lazy @Autowired <Self> self`, and
`ReplenishmentOrderMaintenanceService`'s carries *"**Do not remove:** without this field the sweep
path bypasses AOP"* — the same defect class, already fixed this way here. `MessageService` implements
no interface and `AopContext`/`exposeProxy`/`proxyTargetClass` appear nowhere in `src/main`, so CGLIB
applies and self-injection works.

Rejected: a new `ServiceLogWriter` bean (adds a bean to a class already in a `@Lazy`-broken cycle for
no behavioural gain); annotating `createMessage` directly (v1 §3.2 Option 2 — its *semantic* argument
transfers even though its blast-radius arithmetic does not, since 34 of 37 v2 sites are behaviourally
unaffected); making all 37 callers call `createServiceLog` (37 edits for the same result).

### Fix B — ⚠ WITHDRAWN: already implemented in flight on **PR #470**

**Do not implement this. It is done, reviewed and open as a PR**, and writing it again would conflict
in `MessageService.java`.

`SBDEV-3325-resend-double-row` → **[PR #470](https://github.com/SiteBossInc/wms2-api/pull/470)**,
*"SBDEV-3325 follow-up: a resend writes ONE service-log row (createServiceLog returned an id-less
Message)"*, commits `d324fc47` + `f82ec8c3`. **Open, not merged, not on `origin/develop`.** It:

- extracts a private `saveServiceLog(..., Long redeliverId)` that sets `resent`/`redeliver_id`
  **before** the insert, so a resend writes one linked row instead of a linked row plus an unlinked
  twin;
- changes `createServiceLog` to `return messageRepository.save(m)` — the managed instance — with a
  comment stating the same mechanism this plan derived independently in §2.5: *"version is set above,
  so Spring Data's isNew() says 'not new' and save() MERGES: the INSERT lands on a managed copy and m
  keeps id = null"*;
- adds a guard rejecting a resend of a row with no id, and pins the behaviour with
  `MessageServiceSingleRowIT`.

**Consequences for this plan:**

1. **PR #470 is a PREREQUISITE, not a sibling.** Fix A rewrites the same two `createMessage` overloads
   that #470 refactors underneath. Branch this ticket off #470's head, or rebase onto `develop` after
   it merges — do not branch off `develop` as it stands.
2. **AC-5 and AC-6 are already satisfied by #470** and become regression confirmations here rather
   than failing-first tests. The TDD gate must not try to write them red.
3. §2.5 stands and is now **independently corroborated** — two people derived the same `isNew()`/merge
   chain from opposite directions, which is the strongest evidence in this document.

### Fix C — `OrderBatchCreationService`: move the write, don't annotate it

Site #37 is the **only** OUTCOME row in the whole table (§4) and the only one inside a live
transaction. It writes `ORDER_BATCH_IMPORT` / `RECEIVED` / `statuscodeanswer = "204"` **inside**
`createAll` — a claim about an HTTP response not yet returned. If `createAll` throws, the controller
returns 400 and a durable row would assert a 204 that was never sent. `REQUIRES_NEW` here would make
a **false** row durable.

Move the write out of `createAll` and up into `OrderRestController.create()`, after it returns, next
to its existing FAILED sibling. That makes the pair symmetric (today the FAILED row survives and the
RECEIVED one does not), removes the only enclosing transaction in the table, and removes the only new
pool slot.

### Fix D — the four propagation comments (sibling sweep)

Four comments in `src/main` make a propagation claim about these methods; **zero** in `src/test`.
Derived by five greps (`does NOT fire`, `commits independently`, `REQUIRES_NEW` filtered to
service-log lines, `self-invo`, `proxy-based|through the proxy`); **blind spot** — a comment
describing the behaviour without naming propagation, the proxy, or either method name.

| | file | verdict | action |
|---|---|---|---|
| S1, S2 | `SkuRestController` ×2 | ✅ TRUE — *"so its @Transactional(REQUIRES_NEW) does NOT fire … The log persists here because no outer tx is active, NOT because REQUIRES_NEW provides isolation"* | **update** — after Fix A it now *does* fire; this is the canonical wording to converge on |
| S3 | `OrderBatchCreationService` | ❌ **FALSE** — *"REQUIRES_NEW commits independently of the outer tx"*, at the one site where the row genuinely rolls back | **delete with the code it describes** (Fix C) |
| S4 | `BillofladingService` javadoc | ✅ TRUE at that site, but *"`createServiceLog` is REQUIRES_NEW"* reads as a property of the method | **four-word qualifier**: *"…and reached here through the proxy…"* |

### Fix E — the regression rail

State the **invariant**, not the instance. Three forms measured; the choice is not obvious:

- *"reached **only** by self-invocation"* — flags 18 sites and **would miss this bug**, because
  `createServiceLog` has two external callers.
- **Chosen: a self-invocation where the calling method does not already supply the same propagation**
  — flags **exactly 1 site today: the bug**, with no allowlist.
  `ReplenishGeneratorService.calculateOrder` is a genuine second self-invocation that is benign
  because the outer overload carries the same `REQUIRES_NEW`; that case is what forces the refinement.

Blind spots that apply, stated in the rule's own javadoc: **constructors and field initializers**
(use `codeUnits()`, not `methods()`) and **method references** (`this::createServiceLog` is
invisible). Scope to `src/main` — a src-wide scan also picks up test classes. **Positive control on
the set SCANNED, not the set FOUND**, so a broken instrument cannot read as a clean pass.

---

## 4. Attempt vs outcome — the classification, for approval

**38 of 39 sites are ATTEMPT. One is OUTCOME.** Full per-site table with quoted snippets, enclosing
transaction, derivation and deadlock column: `SBDEV-3674-evidence/callsite-enumeration.md` §6.

**The rule, which outlives the enumeration:** *a `message` row records an interaction across the
WMS/OMS boundary — an inbound request that arrived, or an outbound POST that was made. Both are facts
about the outside world, and no rollback of WMS-internal state can un-make them.* The one exception is
a row that quotes a response code the request has not yet returned — which is exactly site #37.

> **The sentence needing Nam's yes:** *the RECEIVED row describes the response, so it belongs after the
> commit, not inside it.*

**Deadlock constraint: real in principle, empty in practice — but NOT for the reason an earlier
revision gave.** That revision claimed *"zero of the 39 sites sit inside a lock-holding transaction"*,
derived by enumerating the `afterCommit` and else branches — a derivation that omits the inline
`urlPath == null` site (§2.1), which **is** reached from lock-holding callers:
`MobilePickingService.processPick` is `@Transactional(tenantTransactionManager)` and its first act is
`pickingorderRepository.findByIdForUpdate(pickingOrderId)`, held for the whole method.

**The verdict survives on a different and stronger argument: table disjointness.** The inner
transaction touches only `message` and `los_sequencenumber`. No caller in the table locks either —
`message` FKs to `mywms_user` and `client`, and nothing in the one lock-holding path locks those. A
deadlock needs a cycle, and there is no shared row to form one. *(The site is also dormant on PRD
today: all relevant sysprops are populated, so `urlPath` is never null there — which is a
configuration fact, not a guarantee, and is exactly why the disjointness argument is the one to rely
on.)*

Pool delta is **+1 concurrent slot**, at `OrderBatchCreationService` (removed by Fix C) and at the
inline site (**not** removed by Fix C). Against a prd tenant pool of 5. Does not re-raise SBDEV-3198.
`flush`-first is cargo cult here — a flush acquires locks *earlier*, not later.

**On the precedent:** `BillofladingService` already writes from `afterCommit` **through the proxy**,
which is the structurally correct precedent — but `PENDING_REVERSAL_SHIPPED` has **zero rows ever** on
Hydra PRD, so that path is unexercised in production. It is a design precedent, not a production
proof; AC-1 is the only evidence that `REQUIRES_NEW`-from-`afterCommit` actually commits.

**The outbox does not subsume this.** It would eventually absorb the 4 `OmsNotificationService` sites
— the entire loss-bearing set — but **35 are structurally permanent** (28 inbound REST audit rows, 3
export-job rows, the outbox's own `writeServiceLog`, the import audit row, 2 WMS→ops notes). An
inbound record is not an outbound notification. Phase 3 is unscheduled; fix now, independently.

---

## 5. Implementation

### 5.1 Prerequisites

| | |
|---|---|
| DB state | none — no migration, no backfill (§7) |
| Feature flags / sysprops | none |
| Config / env | none |
| Deploy order | standalone |
| External systems | none — no change to what is POSTed to OMS |
| Branch | `bugfix/SBDEV-3674-service-log-proxy-bypass`, in a per-ticket worktree at `.claude/worktrees/wms2-api/SBDEV-3674`, based on `origin/develop` @ **`fc046edc`** |
| ~~Blocked by~~ | **CLEARED 2026-10-07** — [PR #470](https://github.com/SiteBossInc/wms2-api/pull/470) merged as `fc046edc`. Former Fix B is now on `develop`; `createServiceLog` returns the managed instance and `saveServiceLog(..., redeliverId)` exists. The two `createMessage` overloads still self-invoke, so Fix A's target is unchanged. |

### 5.2 Order

Fixes A and B are independent (§3 Fix B); either order works. B first is still convenient, because
AC-5/AC-6 are the cheapest to write and the quickest to go green.

1. ~~Fix B~~ — **done: merged to `develop` in PR #470 (`fc046edc`).**
2. Fix A — self-injection.
3. Fix C — move the `OrderBatchCreationService` write to the controller.
4. Fix D — the four comments.
5. Fix E — the ArchUnit rail.

---

## 6. Acceptance criteria

Harness: **`BaseRollbackIntegrationTest`**, not `BaseIntegrationTest`. The latter carries a
class-level `@Transactional("tenantTransactionManager")`, so service boundaries are not real and every
site would appear to be inside a transaction — it cannot grade this ticket. `BaseRollbackIntegrationTest`
*"intentionally omits @Transactional so that service @Transactional boundaries are real"*;
`NestedSendAfterCommitIT` and `MessageServiceSingleRowIT` already extend it.

⚠ **It is an H2 harness, not Testcontainers** — `@ActiveProfiles("integration")` with
`spring.jpa.hibernate.ddl-auto=create-drop` against `jdbc:h2:mem:rollback_tenant`. That is correct for
this ticket, because what is under test is Spring's *propagation* behaviour, which is engine-independent.
It also means the schema is generated from the mappings with **no seeded `los_sequencenumber` rows**, so
`BasicService` must be mocked (as `MessageServiceSingleRowIT` does) rather than seeded — superseding
fixture trap 1 for this harness. Anything needing PostgreSQL-only behaviour (`SET LOCAL lock_timeout`,
a real deadlock) would need the Testcontainers lane instead; nothing in these ACs does.

Three fixture traps, all already documented in-repo:
1. **Seed `los_sequencenumber` for `WEBSERVICE_MESSAGE` first** — `getNextSequenceNumber` creates a
   row without setting `@Version` and `classname` is the `@Id`, so Hibernate treats it as detached and
   the first use of any unseeded key fails. A test that skips this fails for the wrong reason and
   reads as a reproduction.
2. **Seed `mywms_user` (including the anonymous user) and `client`** — `message` has real FKs to both.
3. **Assert by primary key, never `isEmpty()`/`hasSize()`** — repository tests here commit rather than
   roll back, so a count assertion can pass on a sibling's residue.
4. **Seed the `WEBSERVICE_STOCK_UPDATE` sysprop.** Without it `sendAfterCommit` takes the inline
   `urlPath == null` branch, which persists a row on the unfixed tree — a false green (AC-2).

| # | Criterion |
|---|---|
| **AC-1** | A `createMessage` call from inside a `TransactionSynchronization.afterCommit()` callback **persists** its row. Fails today: no row, no exception. |
| **AC-2** | A `sendStockChangeMessage` call from a `@Transactional` method persists exactly one `STOCK_UPDATE` row **with `status = SENT` and `statuscodeanswer = "200"`** against a stubbed `HttpRestService`, and the `WEBSERVICE_MESSAGE` sequence advances by exactly one. ⚠ The status assertion is load-bearing: without a seeded `WEBSERVICE_STOCK_UPDATE` sysprop, `sendAfterCommit` short-circuits on the inline `urlPath == null` branch, which writes a `FAILED`/`"503"` row that commits with the test transaction — **AC-2 would pass green on the unfixed tree** while the deferred path it grades never runs. Assert the sysprop is non-null in the arrange phase. |
| **AC-3** | A `createMessage` call inside a caller transaction that then **rolls back** still persists its row (the ATTEMPT semantics of §4). |
| **AC-4** | Two halves, and ⚠ **only the first grades Fix C** — corrected 2026-10-07 after actually running the mutant. **(a) `ac4ReceivedRowIsWrittenAfterCreateAllReturns`** — on a successful import the controller writes `ORDER_BATCH_IMPORT` / `RECEIVED` / `"204"`. This is the grader: with Fix C reverted it fails *"Wanted but not invoked: messageService.createMessage"*, an attributable kill naming the missing write. **(b) `ac4NoReceivedRowWhenCreateAllThrows`** — a regression guard only. It **cannot** grade Fix C, because in a unit test `orderBatchCreationService` is a mock, so the real `createAll` never executes and never writes the row; the assertion passes whether or not Fix C exists. An earlier revision of this plan claimed AC-4 as a whole went "green → RED after Fix A → green after Fix C". That sequence assumed the real service ran. It does not. |
| ~~**AC-5**~~ | *Satisfied by PR #470 — regression confirmation only, cannot be written red.* `createMessage(...).getId() != null`. |
| ~~**AC-6**~~ | *Satisfied by PR #470 (`MessageServiceSingleRowIT`) — regression confirmation only.* One resend produces exactly one row, `resent = true`, non-null `redeliver_id`. |
| **AC-7** | The ArchUnit rail flags the pre-fix `MessageService` and passes after, with its positive control asserted on the set scanned. |
| **AC-9** | The second rollback-case site: `OmsNotificationService`'s inline `urlPath == null` branch, called from a `@Transactional` caller that then rolls back, must persist its `FAILED`/`"503"` row after Fix A. Classified ATTEMPT in §4 — "OMS URL not configured" is a standing misconfiguration and suppressing it because the business transaction failed hides it. Dormant on PRD today (all sysprops populated), so this is the one AC with no production symptom behind it; it exists because Fix A changes its behaviour and nothing else would notice. |
| **AC-8** | Full suite compared against the baseline measured fresh and adjacent in time — failures compared, never totals. |

**No verify script.** T3's script is opt-in and every assertion here belongs in JUnit. The one
cross-file invariant is Fix E, which is an ArchUnit rule — a test, not a grep row.

Mutation-check every new assertion with PIT scoped to the changed class, JDK 21 (JDK 25 silently
reports 0% and BUILD SUCCESS). The kill must be **attributable** — the failure message must name the
thing broken.

---

## 7. Backfill — do not

The lost rows are unrecoverable: a discarded insert leaves no process type, no payload, no timestamp.
A burned number proves only that `createMessage` was reached — **not** that anything was delivered
(§2.3): `doSend` burns on its transport-exception exit too, where the POST never completed. Synthesising rows
from the gaps would fabricate audit records — the exact failure mode §2.5 flags in `resendMessage`.
The gap itself is the honest record.

---

## 8. Risks

| risk | impact | mitigation |
|---|---|---|
| Fix A is written against `develop` and conflicts with PR #470 | wasted work, or a bad merge in `MessageService` | base the branch on #470's head (§5.1); Fix B is withdrawn from this plan entirely |
| `@Lazy` self-reference interacts with the existing `MessageService → StockChangeNotificationService → OmsNotificationService → MessageService` cycle | context fails to start | `@Lazy` on the self field, as the four precedents do; a context-load test is the gate — unit tests cannot see DI wiring |
| `REQUIRES_NEW` takes a second pool connection | pool pressure | +1 slot at one site, removed by Fix C; measured, does not re-raise SBDEV-3198 |
| **Fix A changes read VISIBILITY, not just commit timing** | the service-log write now runs in its own transaction and cannot see rows the caller has written but not yet committed | **Found during implementation, not predicted by the plan.** `createServiceLog` resolves the operator with `userRepository.findByName(...)` and copies its id and `clientId` onto the `Message`; both are `@NotNull`. If that user row is uncommitted, the insert fails at commit with `ConstraintViolationException` and the endpoint answers **500**. It surfaced immediately: three integration tests went red because `BaseIntegrationTest` is class-level `@Transactional` and seeds the anonymous user inside the rolled-back test transaction. Fixed in the tests (raw JDBC + explicit `commit()`, the device those files already use for `los_sequencenumber`), **not** in production code — production `mywms_user` rows are long committed. ⚠ Residual, narrow: any flow that creates a row and writes a service log for it **in the same transaction** would now log against invisible data. No such flow is known (user creation is its own endpoint), but it is a real behavioural change and is the first thing to check if a 500 appears on a service-logged path. |
| Rows that *should* roll back now persist | a false durable record | **two** such sites: `OrderBatchCreationService` (Fix C addresses it structurally; AC-4 pins the red-then-green sequence) and `OmsNotificationService`'s inline `urlPath == null` site, which Fix C does **not** touch — see AC-9 |

---

## 9. Horizontal scalability

| # | concern | verdict |
|---|---|---|
| 1 | In-JVM state | No — no new state |
| 2 | Connection pool math | **Yes** — +1 concurrent slot at two sites (`OrderBatchCreationService`, removed by Fix C; and the inline `urlPath == null` site, which Fix C does not touch), against a prd tenant pool of 5. §4. |
| 3 | Scheduled jobs | No |
| 4 | Long transactions | No — the new transaction is a single INSERT |
| 5 | Request affinity | No |
| 6 | Retry / idempotency | No — no change to delivery |
| 7 | Tenant context | No — same thread, `tenantTransactionManager` explicit |
| 8 | Distributed lock correctness | **No** — but by **table disjointness**, not by "zero sites inside a lock-holding transaction", which is false: the inline `urlPath == null` site is reached from `MobilePickingService.processPick` while it holds `findByIdForUpdate`. The inner transaction touches only `message` and `los_sequencenumber`; no caller locks either, so no cycle can form. §4 |
| 9 | Cache invalidation | No — `message` is not cached |
| 10 | External notifications | No — what is POSTed is unchanged; only whether the audit row survives |

---

## 10. Open questions

- **O-1 — RESOLVED 2026-10-07 (Nam): yes.** Fix C's framing is approved — *the RECEIVED row describes
  the response, so it belongs after the commit, not inside it.* `OrderBatchCreationService`'s write
  moves to `OrderRestController.create()` after `createAll` returns, beside its FAILED sibling; the
  false `// REQUIRES_NEW commits independently of the outer tx` comment is deleted with it. **AC-4**
  grades this, via its green → red → green sequence across steps 0 / Fix A / Fix C.
- **O-2 — owed before close.** `nywh-shipitez-prd`, `c1wh-shipitez-prd` and `wsl-wineco-prd` all
  failed to connect this session (timeout, not access). Run §1.1's query on each. If their REGULAR
  advices carry OMS-shaped reference ids with no `ADVICE_IMPORT` rows, the §2.4 retraction is local to
  Hydra and the import path is alive elsewhere.
- **O-3 — separate from this ticket, possibly larger.** Has `PUT /rest/advice/create` ever been called
  for a REGULAR advice on Hydra PRD? If OMS is configured to push inbound advices and they die
  upstream of the handler, 235 hand-keyed BOLs are compensating for a broken integration — invisible
  to this instrument, because a request rejected before the handler burns no number. Probe: log-grep
  `LOG.info("create called with {}", adviceList.size())`.
- **O-5 — the unattributed third of the burn.** Receiving-driven `STOCK_UPDATE` explains at most
  ~66% of the 402 (§2.2); 138 burns occur on intervals with no receipt activity, and 98 of 402 fall on
  days with no receiving at all. Candidates not yet separated: the other `sendAfterCommit` process
  types on transactional callers, the inline `urlPath == null` site, and rollback-path FAILED writes.
  AC-2 confirms the mechanism; it does not close the residual. Settling it needs runtime evidence —
  raise `MessageService` to DEBUG on one tenant and compare `"end with created message={}"`
  occurrences against committed rows over the same window, since `createServiceLog` logs that line
  *after* `save` returns and under the discard it returns normally.
- **O-4 — CLOSED for `src/main`, one check left.** The 6-argument `createMessage` overload
  (`…, String destination, String stateCode)`, which hard-codes `MessageStatus.CREATED`) has **zero
  callers in `src/main`**: all **39 `createMessage` call sites** pass 8 arguments (37 external + the 2 self-calls in
  `resendMessage`; the 2 direct `createServiceLog` sites are a different method and are not in this
  population). Derived by a
  comment-stripped, string-aware, balanced-paren arity scan over `git archive origin/develop src/main`
  — not a grep, because a `//` comment or a nested call inside the argument list miscounts commas.
  **Reconciled against the raw occurrence count**: 41 `createMessage(` occurrences = 37 external +
  2 self-calls in `resendMessage` + 2 declarations, which is the control that the scan saw everything.
  *(An earlier attempt reported 2 call sites because its regex used a `(?<![A-Za-z0-9_.])` lookbehind
  that excluded every `messageService.createMessage(` — and its positive control **passed anyway**,
  because the control graded the rows found rather than the set scanned. Recorded because that is the
  failure mode, not a hypothetical one.)*
  Remaining check before deleting it: 13 `src/test` files reference `createMessage`, mostly as Mockito
  stubs; confirm none stubs the 6-arg form. If dead, delete rather than fix it twice.

---

## 11. Implementation Status

**Implemented 2026-10-07**, worktree `.claude/worktrees/wms2-api/SBDEV-3674`, branch
`bugfix/SBDEV-3674-service-log-proxy-bypass`, based on `origin/develop` @ `fc046edc`.
**MERGED and ON DEV.** [PR #472](https://github.com/SiteBossInc/wms2-api/pull/472) → `develop` as
**`8a89f788`**. Push build 37691507068: `test` ✅ and `build` ✅ (both required — `build` carries
`needs: test`, so a red suite skips the image push and develop stops deploying silently). Deploy
verified live, not inferred: `GET /api/public/version` on dev returns
`develop-8a89f788872d09a86556e2480dc45b9461f8b6e9`.

⚠ **CI failed twice first, and neither failure was in the production change.** Both were 9 errors in
`AdviceOutboxIntegrationTest` — `Table "outbox_message" not found (this database is empty)` — caused
by the new IT forking a Spring context. 39 classes extend `BaseRollbackIntegrationTest` sharing one
`jdbc:h2:mem:rollback_tenant` with `ddl-auto=create-drop`, and the context cache is bounded: a new
context forces an eviction, and the **evicted** context's `create-drop` drops the shared schema under
a class that is still cached.

- `401c37e8` — original. Red.
- `d95559b5` — gave the IT its **own** database. **Red, identically** — and that is the measurement
  that mattered: isolation does not reduce the *number* of contexts, so the eviction caused in others
  is unchanged. The damage is the eviction, not the database.
- `6aa75585` — add **no** context: mock set made identical to `MessageServiceSingleRowIT`, and the
  `@TestConfiguration` probe replaced with `TransactionTemplate(tenantTransactionManager)` (the
  `MoveCronConcurrencyIT` device). **Green.**

**Local `clean verify` was green for all three**, including both failures — `outbox_message not found`
is 45x in each CI log and **0x in every local run**. Mechanism confirmed independently of the green:
`HikariPool … Start completed` 199 → 181, and CI wall-clock 17m → 12m51s. ⚠ Three other
context-creation markers return **0 in both** logs, so `0 == 0` reads as confirmation while measuring
nothing — see [[new-test-context-fork-breaks-an-unrelated-it]].

The five commits picked up by the rebase (SBDEV-3677) touch no file this change touches, and the full
suite was re-run on the rebased tree rather than inferred from that: unit **7,938**, IT **748**,
**0 failures both lanes** (the +2/+1 over the pre-rebase run is SBDEV-3677's own tests).

| fix | state |
|---|---|
| A — self-injection in `MessageService` | done; verified by `ServiceLogPropagationIT` **and** by the rail no longer flagging it |
| ~~B~~ | withdrawn — shipped in PR #470 (`fc046edc`) |
| C — move the RECEIVED write to `OrderRestController` | done; graded by AC-4 |
| D — the four propagation comments | done; `SkuRestController` ×2 updated (they became false in the *other* direction after Fix A), `OrderBatchCreationService`'s deleted with its code, `BillofladingService` qualified |
| E — `SelfInvokedTransactionalArchTest` | done, **fourth design** — see below |

### Tests

| | before | after |
|---|---|---|
| `ServiceLogPropagationIT` (AC-1,2,3,9 + control) | 5 run / **4 failed** | 5 run / **0 failed** |
| `OrderRestControllerUnitTest$CreateEndpoint` (AC-4 ×2 added) | 54 | **56 / 0 failed** |
| `SelfInvokedTransactionalArchTest` | — | 2 run / 0 failed (4 controls) |

### Three things the implementation found that the plan did not predict

1. **A second live instance of the defect.** `ReplenishGeneratorService.calculateOrder` (3-arg,
   unannotated) bare-calls the 4-arg `REQUIRES_NEW` overload. The plan asserted this site was benign
   "because the outer overload carries the same propagation" — it does not. **Not fixed here**
   (replenishment transaction semantics is T3 data integrity, and unlike the service-log write that
   path **does** hold `PESSIMISTIC_WRITE` locks, so §4's "deadlock constraint is empty in practice"
   argument does not transfer). Filed 2026-10-07 as **SBDEV-3684**
   (https://app.clickup.com/t/868meqfvd) and held in the rail's `knownPreExisting` set, asserted
   exactly so it cannot be forgotten.
2. **Fix A changes read visibility** — see the new risk row in §8. Three ITs went red; fixed in the
   fixtures, not in production code.
3. **The rail needed four designs**, each failure invisible to reading:
   - *bytecode* — could not distinguish `self.foo()` from `this.foo()`, so it flagged the **fix**;
   - *source, no propagation filter* — 16 harmless `REQUIRED` self-calls;
   - *source, with qualifier* — the walk-back read a **neighbouring** method's annotation and
     suppressed the real `ReplenishGeneratorService` finding, reporting `src/main` clean. Caught only
     because the baseline is asserted as an **exact set**; a "no new findings" assertion would have
     passed.
   It now carries positive, negative, harmless and false-negative controls, one per failure above.

### Floor — complete

| item | evidence |
|---|---|
| One DB query confirming the symptom | ✅ §1.1, three databases, deletion excluded, positive control |
| One failing test first, failing for the right reason | ✅ `ServiceLogPropagationIT` 5 run / 4 failed, `Errors: 0`, all four `AssertionError` with their own descriptions, control passing |
| Mutation-check every new assertion | ✅ the four gate assertions were red-before / green-after in that order; the rail carries positive, negative, harmless and false-negative controls; AC-4 killed by a Fix-C-reverted mutant with an attributable message. ⚠ That mutant also **disproved** the plan's claim about AC-4's second half — see §6 |
| One independent review, never self-approve | ✅ two rounds, 7 High + 11 Medium, every one applied and swept across four documents |
| Full suite vs known baseline | ✅ **both trees, same configuration, back to back.** Unit 7,932 → 7,936 (+4 = AC-4 ×2, rail ×2); IT 742 → 747 (+5 = `ServiceLogPropagationIT`). **0 failures both lanes both trees; failure-set delta empty.** Deltas account exactly for the additions, so no test was silently lost |
