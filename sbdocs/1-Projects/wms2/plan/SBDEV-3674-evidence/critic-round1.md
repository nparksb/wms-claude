# SBDEV-3674 — adversarial review, round 1

**Lane:** critic. **Mode:** escalated to ADVERSARIAL after the first two confirmed defects (§2.1's
site classification and §2.2's attribution) turned out to be the same error repeated in three
documents — a pattern, not an isolated slip.

**Scope:** `/home/nampark/dev/wms-claude/sbdocs/1-Projects/wms2/plan/SBDEV-3674-service-log-rows-lost-proxy-bypass.md`,
its three evidence lanes, and the v1 sibling's round-3 §4 correction.
**Instruments:** `git show`/`git grep` on `v2/wms2-api` `origin/develop` @ `ce454c68`; the
`spring-data-jpa` **3.5.7** sources jar from `~/.m2`; read-only SQL on `nywh-hydra-prd`,
`nywh-hydra-uat`, `wsl-wineco-uat`. No worktree, no `mvn`.

**Verdict: REVISE.** The mechanism is right, Fix A is the right mechanism, and §2.5 survives a
second instrument. Five load-bearing claims do not survive, four of them in the sections that carry
the acceptance criteria.

---

## Pre-commitment (written before detailed investigation)

Predicted: (1) §2.2 over-attributes the 402 to one process type; (2) §2.5's single-instrument library
claim is the weak point; (3) the Fix A/B ordering constraint is already-broken, not a new risk;
(4) at least one AC is green on the unfixed tree; (5) a completeness word with no derivation.

Outcome: (1) **confirmed, and worse than predicted**; (2) **wrong — §2.5 is correct, I confirmed it
against the library source**; (3) **confirmed**; (4) **confirmed, two of them**; (5) **confirmed**.
Not predicted, and the largest finding: §2.1 misclassifies a call site, and that single error
propagates into §4, §8, §9 and the v1 sibling.

---

# A. Confirmed defects in the plan

## HIGH-1 — §2.1 puts the `urlPath == null` site inside `afterCommit`. It is not. Four sections rest on this.

> "**Inside an `afterCommit()` callback** | **4** (`OmsNotificationService.doSend` ×3 + the inline
> `urlPath == null` site)"  — §2.1

`OmsNotificationService.sendAfterCommit` on `origin/develop`:

```java
public void sendAfterCommit(String urlPath, String payload, String processType) {
    if (urlPath == null) {
        LOG.warn("OMS URL not configured for processType={}. Creating FAILED message.", processType);
        try {
            messageService.createMessage( ... WmsConstants.MessageStatus.FAILED, "503", null);
        } catch (...) { ... }
        return;
    }

    if (TransactionSynchronizationManager.isSynchronizationActive()
            && TransactionSynchronizationManager.isActualTransactionActive()) {
```

The `urlPath == null` block **returns before the branch**. It runs **inline, in whatever transaction
the caller holds** — which is exactly what `callsite-enumeration.md` §6.1 row 9 says
(`Encl. tx` = "**caller's tx**"), and the plan contradicts its own source document. The correct
split of 39 is **34 none / 2 caller's tx / 3 afterCommit**, not 34/1/4.

Four downstream statements are false as a result:

1. > "**Zero of the 39 sites sit inside a lock-holding transaction**, derived structurally: the
   > `afterCommit` branch runs post-commit with row locks released, and the else-branch fires only
   > when no transaction is active." — §4 (repeated as §9 row 8 "**No, verified**")

   The stated derivation enumerates two branches and the inline site is in neither. A concrete
   counterexample exists: `MobilePickingService.processPick` is
   `@Transactional(value = "tenantTransactionManager", rollbackFor = {BusinessException.class, FacadeException.class})`
   and its *first* act is `pickingorderRepository.findByIdForUpdate(pickingOrderId)` — a
   `PESSIMISTIC_WRITE` held for the whole method — and it then calls
   `manageOrderService.customerOrderToteAssigned(...)` → `omsNotificationService.sendAfterCommit(...)`.
   If that sysprop were unset, site #9 fires inline **inside a lock-holding transaction on the mobile
   picking hot path.**

   *The verdict survives; the derivation does not.* I checked Hydra PRD: all 17
   `WEBSERVICE_ORDER_BATCH*` / `WEBSERVICE_STOCK*` sysprops are populated, so the inline branch is
   dormant there today, and the inner `REQUIRES_NEW` would touch only `message` +
   `los_sequencenumber`, disjoint from `pickingorder`. So: no deadlock, but "zero sites inside a
   lock-holding transaction" is false and must not be the reason given.

2. > "Pool delta is **+1 slot at one site**, removed entirely by Fix C" — §4 (also §8 row 3, §9 row 2)

   Site #9 is a **second** `REQUIRES_NEW`-inside-a-live-transaction site after Fix A, and Fix C does
   **not** touch it. On the picking path the outer tx + `createServiceLog` + `getNextSequenceNumber`
   is a 3-deep stack against a 5-slot tenant pool.

3. > "exactly one such site exists (#37)" — §8 risk row 4 ("Rows that *should* roll back now persist")

   Site #9's FAILED row also changes from "rolls back with the caller" to "survives". The
   enumeration lane argues that is *desirable* (ATTEMPT — a standing misconfiguration must not be
   hidden by a business rollback), so this is a behaviour change the plan should claim, not one it
   should miss.

4. No acceptance criterion covers site #9 at all.

**Corrected wording for §2.1:**

| case | sites | what happens | row |
|---|---|---|---|
| No enclosing transaction | 34 of 39 | `save`'s `REQUIRED` opens one and commits | survives |
| Inside a live transaction | **2** — `OrderBatchCreationService.createAll` (#37) and `OmsNotificationService`'s inline `urlPath == null` site (#9), which runs **before** the branch | the insert joins it | rolls back with it |
| Inside an `afterCommit()` callback | **3** — `OmsNotificationService.doSend` ×3 | … | silently lost |

Add to §4: *"Two sites sit inside a live transaction; one of them (#9) can be reached from
`MobilePickingService.processPick`, which holds `findByIdForUpdate(pickingOrderId)` for its whole
body. There is still no lock-order inversion — the inner transaction touches only `message` and
`los_sequencenumber`, which no outer caller locks — but the derivation is table disjointness, not
the absence of lock-holding callers."*

---

## HIGH-2 — §2.2's attribution does not survive a re-run. 24% of the burn is on days with zero receiving, and there is no dose-response.

> "### 2.2 What the measured 402 are … 518 of the tenant's 522 receipt positions fall inside a burn
> interval, against controls averaging **2.5× longer** — the duration confound runs the wrong way."

I reproduced the plan's table exactly (`nywh-hydra-prd`, full table, no sampling): BURN 360 intervals
/ 402 burned / 518 `goodsreceiptposition` / 2 totes; control 2,**640** intervals / 2 grpos / 265
totes; avg 1,083.8 s vs 2,688.8 s. The arithmetic is right. **The inference is not.**

**(a) 138 of the 402 burns are in intervals containing zero receipt activity.**

```sql
-- burn intervals only, split by whether any goodsreceiptposition falls inside
has_receipt_activity | intervals | burned | grpos
false                |       130 |    138 |     0
true                 |       230 |    264 |   518
```

So at most **264 of 402 (66%)** are co-located with receiving at all. The remaining 138 sit in the
picking lane — 80 between consecutive `ORDER_BATCH_PICKING_STARTED` rows, 29 between
`PICKING_RELEASED → PICKING_STARTED`.

**(b) There is no dose-response — which is what distinguishes the two burners the lead asked about.**

```sql
-- burn intervals, burned count vs receipt positions inside
burned | intervals | avg_grpos | min_grp | max_grp
     1 |       334 |      0.67 |       0 |      10
     2 |        16 |      1.50 |       0 |       2
     3 |         6 |     42.00 |       3 |     210
     4 |         2 |      4.00 |       4 |       4
     5 |         2 |      5.00 |       0 |      10
```

**334 of 360 burn intervals burn exactly one number and average 0.67 receipt positions. One interval
contains 210 receipt positions and burned 3.** If each receiving-driven `sendStockChangeMessage` lost
a row, 518 positions would burn far more than 402 and the 210-position interval would burn ~210. The
"518 of 522" statistic is **containment of a dense event stream by a sparse set of wide intervals** —
exactly the confound the lead suspected. It measures that receiving is bursty and that burn intervals
are the wide ones, not that receiving caused the burns.

**(c) The association is nevertheless real — at day granularity, which is the instrument the plan
should have used.**

```sql
receiving_day | days | burned | grpos | burns_per_day
false         |   69 |     98 |     0 |          1.42
true          |   17 |    304 |   522 |         17.88
```

A **12.6× rate ratio**, immune to interval geometry. That is strong, auditable support for "receiving
is a major burner" — and it simultaneously shows **98 burns (24%) happen on days with no receiving at
all**, so receiving cannot be the whole 402.

**Why the mechanism still holds:** `sendStockChangeMessage` has **17 call sites** on `origin/develop`,
only 3 of which are receiving (`GoodsReceiptPositionService` ×2, `ReceivingService` ×1). The other 14
are `StockunitService` ×6, `UnitloadService` ×2, `MobileMoveUnitloadService` ×2,
`MobileCycleCountService` ×2 — i.e. picking and stock-movement. So picking-lane burns are *consistent*
with `STOCK_UPDATE` too. The plan's conclusion is probably right; its stated evidence does not reach it.

**Corrected wording for §2.2:**

> "**What the measured 402 most likely are.** `STOCK_UPDATE` is the only producer with 17 call sites
> spanning receiving, picking and stock movement, and it is a single deferral, so it burns.
> Day-level rate ratio (the instrument least sensitive to interval geometry): **17 receiving days
> burned 304 numbers (17.9/day); 69 non-receiving days burned 98 (1.42/day) — 12.6×.**
> **Limits, both material:** (i) 98 burns (24%) occur on days with no receiving, so receiving
> explains at most 76%; (ii) there is **no dose-response** — 334 of 360 burn intervals burn exactly
> one number and average 0.67 receipt positions, while one interval holding 210 positions burned 3 —
> so the per-interval '518 of 522' figure establishes co-location of a dense stream with wide
> intervals, not causation. A burned number carries no timestamp and no process type; SQL cannot
> label it. Direct confirmation is AC-2."

Delete "518 of the tenant's 522 receipt positions fall inside a burn interval, against controls
averaging 2.5× longer — the duration confound runs the wrong way." It is true and it does not support
the claim it is placed under.

---

## HIGH-3 — "a burned number is positive evidence the notification WAS delivered" is false. Three copies.

> "**So a burned number is positive evidence the notification WAS delivered and only the audit record
> was lost**" — §2.3
> "A burned number proves only that *some* notification was delivered and unlogged." — §7
> "a burned number is positive evidence the notification was delivered and only the audit record was
> lost" — v1 `SBDEV-3266` §4, added in the round-3 correction

`doSend` burns a number on **all three** of its exits, two of which are failures:

```java
} else {
    LOG.error("OMS notification NOT DELIVERED for processType={}: HTTP {} from {} - {}", ...);
    messageService.createMessage(..., WmsConstants.MessageStatus.FAILED, code, answer);
    incrementFailureCounter(processType);
}
} catch (Exception e) {
    try { messageService.createMessage(..., WmsConstants.MessageStatus.FAILED, "503", null); }
```

A non-2xx means OMS received and refused it. A transport exception means **nothing was delivered at
all**. Both reach `createMessage` and burn a number. The repo already knows this — the enumeration
lane's §10.3 carries the carve-out verbatim: *"a FAILED row can survive on a path where the POST did
not fire … **do not describe a surviving row as proof the POST happened**"* — and the plan then
describes a *burned* number exactly that way.

This is the one finding here that is operationally unsafe rather than merely wrong: it tells an
operator reading a gap "delivered, audit only — do not resend" when the correct reading may be
"transport failed, nothing arrived."

**Corrected wording (apply to all three copies):**

> "A burned number is evidence that the deferred callback **ran and reached `createMessage`** — i.e.
> that a POST was attempted. It says nothing about the outcome: `doSend` burns a number on its SENT
> path, its non-2xx FAILED path and its transport-exception FAILED path alike. What it does
> discriminate is the **double** deferral, which never reaches `createMessage` at all: a zero-row
> process type with **no** burn means the callback never ran and nothing was ever sent."

The rest of §2.3 — that a double deferral burns nothing and therefore the 267 `TOTE_ASSIGNED` must
not be added to the 402 — is **sound**, and I could not break it.

---

## HIGH-4 — AC-5 cannot pass under the fix set as written.

> "**AC-5** | `createMessage(...).getId() != null` — confirms §2.5 step 2 by test rather than by inference."
> "Set the fields **before** the row is written — pass `resent`/`redeliverId` into `createServiceLog`,
> **or** have it return the managed instance from `save`" — §3 Fix B

`createServiceLog` ends:

```java
    messageRepository.save(m);

    LOG.debug("end with created message={}", m);
    return m;
}
```

`save()` returns the merged **copy**; `m` is the merge *source* and is never managed and never gets an
id — in every propagation scenario, before or after Fix A. **Fix A does not touch AC-5 at all**, and
Fix B's first option (`pass resent/redeliverId into createServiceLog`) leaves `return m` intact, so
AC-5 stays red. Only the second option fixes it, and the plan offers them as equivalent alternatives.

The same gap leaves §2.5's second confirmed consequence unfixed:
> "**Two log lines can only print `null`** — `ItemDataController` and `StockSummaryExportJob`"

**Corrected wording for Fix B:** make the return value the non-optional half.

> "`createServiceLog` must `return messageRepository.save(m);` — the managed instance — not the merge
> source. That is what AC-5 grades and what makes `LOG.error(..., message.getId())` printable at the
> two sites in §2.5. *Separately*, pass `resent`/`redeliverId` into `createServiceLog` and delete the
> second `save` at both `resendMessage` sites."

**Also missing from §3: the one-line alternative.** `m.setVersion(1);` is what makes
`isNew()` false. Deleting it makes `save()` take the `persist` branch, which populates `m.id`
in place, removes the merge entirely, and fixes AC-5, AC-6 and the two null log lines at once. It is
a behaviour change for anything reading `version` on a fresh row (Hibernate seeds 0, not 1), so it may
be the wrong call — but a plan this detailed should say why it was rejected rather than not mention it.

---

## HIGH-5 — §1.1's UAT and WineCo rows measure **migrated v1 history**. The real v2-era loss rates are ~22% and ~38%, not 2.35% and 2.32%.

> "| Hydra UAT | 68,821 | 67,204 | 0 | 1,617 — 2.35% |"
> "| WineCo UAT | 1,833,316 | 1,790,774 numeric | 0 | 42,542 — 2.32% |"
> "**Positive control:** `max(numeric number)` equals the sequence high-water exactly on all three,
> so the sequence and the table are one series and the arithmetic is sound."

The positive control is real and it does not test the thing that is wrong. `message` on both UAT
tenants predates v2 entirely:

| env | `min(created)` | rows before 2026 | total |
|---|---|---|---|
| Hydra PRD | 2026-07-12 | **0** | 3,001 |
| Hydra UAT | **2021-08-25** | **61,551** | 67,204 |
| WineCo UAT | **2019-02-07** | **1,697,025** | 1,790,776 |

Both UAT `message` tables are migrated v1 datasets. Burns by year make the split unambiguous:

```
Hydra UAT:   2021:0  2022:3  2023:0  2024:0  2025:0  |  2026: 1,612
WineCo UAT:  2019:0  2020:20 2021:43 2022:69 2023:64 2024:52 2025:2 | 2026: 42,285
WineCo UAT by month: … 2025-12:0, 2026-01:0, 2026-02:0, 2026-03: 11,618 ← v2 cutover
```

A clean step function at each tenant's v2 cutover. The denominators in §1.1 are 5- and 7-year v1 row
counts; the numerators are almost entirely v2-era.

**Corrected table:**

| env | v2-era rows | v2-era burns | **loss** | note |
|---|---|---|---|---|
| Hydra PRD (nywh) | 3,001 | 402 | **11.8%** | v2-only table, go-live 2026-07-12 |
| Hydra UAT | ~5,650 (2026) | 1,612 | **~22%** | 61,551 pre-2026 rows are migrated v1; v1 years burned **3 total** |
| WineCo UAT | ~68,100 (Mar–Oct 2026) | 42,285 | **~38%** | 1.70M pre-2026 rows are migrated v1; v1 years burned **250 total** |

Three consequences the plan should carry:

- The headline understates the defect by 10–16× on two of three environments, and makes PRD look like
  the worst tenant when it is the best.
- The v1-era rows burn essentially nothing (3 and 250 over 5–7 years). That is independent evidence
  that **v1 did not have this defect at this magnitude**, which is worth stating in the v1 sibling.
- `db_verified_note` says "Measured on 3 databases" without saying that two of the three carry a
  different system's history. Add it.

**Two smaller holes in the same arithmetic, both biasing *downward*:**
- §2.5's duplicate inserts put **2 rows on 1 number**, so each resend hides one lost row. Visible in
  the data: the control row of the interval table is not 0 burned, it is **−2** (two intervals with
  `n − pn − 1 = −1`). Independent confirmation of the duplicate defect; also a small understatement.
- WineCo has non-sequence `number` values (`MSG-MANUAL-CANCEL-059610-000052`), which inflate `rows`.
  The plan's "1,790,774 numeric" notices the symptom without drawing the conclusion: `issued − rows`
  requires *every row consumes exactly one number*, and two mechanisms break it.

---

# B. Medium

## MED-1 — The Fix A/B ordering constraint is cosmetic. The double-insert is already deterministic today.

> "**Fix A makes this worse if B is not done first or together.** Once `createMessage` is proxied, the
> row commits in its own transaction and the returned entity is *definitely* detached — so
> `setResent`/`setRedeliverId` are lost or re-inserted, **deterministically rather than incidentally**."
> — §3 Fix B; repeated as §8 risk row 1.

`createServiceLog` returns `m`, the merge *source*, which is unmanaged with a null id **in every
propagation scenario** (HIGH-4). `resendMessage` holds no transaction either way, so the second
`save(failed)` opens its own `REQUIRED` transaction before and after Fix A, re-merges a transient
entity, and inserts a second row. **Fix A changes nothing on this path.**

The plan says so itself two sections earlier — *"Hydra PRD: **2 of 2** resends produced a phantom
twin"* — and I confirmed it:

```
id=177449 number=0000002137 resent=false redeliver_id=NULL
id=177450 number=0000002137 resent=true  redeliver_id=157067
id=177451 number=0000002138 resent=false redeliver_id=NULL
id=177452 number=0000002138 resent=true  redeliver_id=97881
```

`message` carries only `message_pkey` on `id` — **no index of any kind on `number`** — so nothing
stops it.

**Corrected wording:** *"Fix B is independent of Fix A, not ordered before it: `createServiceLog`
returns an unmanaged, id-less instance regardless of propagation, so the double insert is already
deterministic on `origin/develop` (2 of 2 on PRD). Fix A neither causes nor worsens it. Do B because
it is a live data-integrity defect, not because A would trigger it."* Delete §8 risk row 1 or restate
it as a present-tense defect.

## MED-2 — "the only delete path" is not derived and a second path exists in code.

> "`MessageCleanupBatchService` → `MessageRepository.deleteMessages` is the only delete path." — §1.1

`MessageRepository` is `@RepositoryRestResource(collectionResourceRel = "message", path = "message")`
on `PagingAndSortingRepository<Message, Long>, CrudRepository<Message, Long>`, with `exported = false`
only on four **query methods** (lines 72, 90, 100, 115) — never at class level. `RestConfiguration`
disables `WRITE_VERBS` only `forDomainType(...)` on `User`, `UserRole`, `UserGroup`,
`UserGroupUser`, `UserGroupUserRole`, `UserRoleUserFunction`, `UserFunction` — **`Message` is not
among them.** So `DELETE /v3/message/{id}` is published.

Per the standing "advertised capability ≠ exploitable" rule I did **not** test whether that DELETE
actually succeeds — it may be stopped by the function guard. But a completeness word with no stated
derivation, contradicted by the code, cannot stand, and a deletion by that route would *inflate* the
402.

**Corrected wording:** *"`MessageCleanupBatchService` → `MessageRepository.deleteMessages` is the only
delete path **in `src/main` service code** (derived by `git grep` on `deleteMessages`, `deleteById`
and `DELETE FROM message`). `MessageRepository` is additionally SDR-exported with no write filter in
`RestConfiguration`, so `DELETE /v3/message/{id}` exists; whether it is reachable past
`FunctionGuardInterceptor` was not tested. Deletion is excluded empirically instead: `message_archived`
is empty and `min(number)` is 3 on prd with history back to go-live."*

## MED-3 — AC-2 can pass green on the unfixed tree.

> "**AC-2** | A `sendStockChangeMessage` call from a `@Transactional` method persists exactly one
> `STOCK_UPDATE` row, and the `WEBSERVICE_MESSAGE` sequence advances by exactly one."

If the test does not seed `WEBSERVICE_STOCK_UPDATE` in `los_sysprop`, `urlPath` is null and
`sendAfterCommit` takes the **inline** branch (HIGH-1) — which writes a `STOCK_UPDATE` / `FAILED` row
that joins the caller's transaction and **commits with it**. One row, sequence +1: AC-2 green, on the
unfixed tree, while the deferred path it is meant to grade never executes.

**Fix:** AC-2 must additionally assert `status = SENT` and `statuscodeanswer = "200"` against a
stubbed `HttpRestService`, and assert the sysprop is non-null in an arrange-phase precondition. Add a
fourth fixture trap to §6: *"seed `WEBSERVICE_STOCK_UPDATE`; without it `sendAfterCommit` short-
circuits on the inline `urlPath == null` branch, which persists a row on the unfixed tree."*

## MED-4 — AC-4 is already green on the unfixed tree.

> "**AC-4** | Fix C: when `createAll` throws, **no** `ORDER_BATCH_IMPORT` / `RECEIVED` row exists, and
> the FAILED row does. The OUTCOME exception."

That is today's behaviour, as the plan states twice (§2.1 case 2; `callsite-enumeration.md` §6.2 row
20: *"today the FAILED row survives while its RECEIVED sibling does not"*). AC-4 is a regression guard
against Fix A pinning the row — valuable, but it cannot go red first, so `wms-tdd-gate` cannot write
it as a failing test, and it does not grade Fix C.

**Fix:** keep AC-4 and label it *regression guard, green before and after*, then add the half that
grades Fix C: *"AC-4b — on a **successful** `createAll`, exactly one `ORDER_BATCH_IMPORT` / `RECEIVED`
row exists and it is written by `OrderRestController.create()` after `createAll` returns (pinned by
asserting the row survives a rollback injected into the controller after the call)."*

## MED-5 — the afterCommit + real-`REQUIRES_NEW` precedent has never produced a row in production.

> "the strongest holder, `closeBOL`, **already** calls `createServiceLog` from `afterCommit` for
> exactly this reason" — §4 (and `architect-fix-shape.md`: *"already `REQUIRES_NEW`, already in
> production"*)

Hydra PRD:
```sql
process                      | status  | count
PENDING_REVERSAL_RECONCILE   | CREATED |     5
```
`PENDING_REVERSAL_SHIPPED` — site #39, the *only* site that is both inside `afterCommit` and reached
through the proxy — has **zero rows, ever**. Site #38 (5 rows) is not in a transaction at all, so it
proves nothing about the afterCommit case.

The mechanism is still right (`REQUIRES_NEW` suspends the completing transaction, opens a fresh one,
commits, resumes), and AC-1 is the correct place to settle it. But the plan should not cite this as a
production proof it does not have.

**Corrected wording:** *"`BillofladingService` already writes from `afterCommit` through the proxy —
the structurally correct precedent, though `PENDING_REVERSAL_SHIPPED` has zero rows on Hydra PRD, so
the path is unexercised and AC-1 is the only evidence that `REQUIRES_NEW`-from-`afterCommit` commits."*

## MED-6 — v1 `SBDEV-3266` §4, round 3, introduced three new false claims — all sibling copies.

The lead asked specifically. Round 3 fixed the "37 in 12 files" count correctly. It introduced:

1. > "**Four** (`OmsNotificationService`'s **deferred path**) run inside an `afterCommit()` callback"

   Same error as HIGH-1, and stated more strongly than the v2 plan — it explicitly assigns all four
   to "the deferred path", which the source refutes.

2. > "so a burned number is positive evidence the notification was delivered and only the audit record
   > was lost"

   HIGH-3's third copy.

3. > "On Hydra PRD **the burns are goods-receipt-driven `STOCK_UPDATE` notifications**: 518 of the
   > tenant's 522 `goodsreceiptposition` rows fall inside an interval that burned a number"

   The v2 plan at least carries *"**Limit:** this establishes co-location, not identity"*. The v1
   copy **drops the hedge and states it as fact.** The sibling copy is strictly worse than the
   original — which is the failure mode the standing memory describes.

4. > "hydra-uat 1,617 / 68,821 (2.35%); wineco-uat 42,542 / 1,833,316 (2.32%)" and "with history back
   > to the first row ever written on all three"

   HIGH-5, propagated. Note the second clause is *true* and is precisely what makes the percentages
   wrong: the history reaching back to 2019/2021 is the v1 history.

All four need the same corrections applied in both documents in the same pass.

---

# C. Low

- **L1.** §1 says the annotation is "inert on **37 of 39 external call sites**"; §3 Fix A says "zero
  changes to the **37 external call sites**". 39 is the external total (37 `createMessage` + 2 direct
  `createServiceLog`). I reproduced 39 across 12 files exactly. Pick one and qualify it.
- **L2.** §10 O-4: "all **41** sites pass 8 arguments" — 41 includes the 2 direct `createServiceLog`
  calls, which cannot pass `createMessage`'s arguments. The population for an arity count is the 39
  `createMessage` sites (37 external + 2 internal).
- **L3.** §2.2's control row reads "0" burned; the real value is **−2**, from the two duplicate
  numbers. Worth keeping as a footnote — it is an independent sighting of §2.5 in the same query.
- **L4.** §2.2 says 2,639 control intervals; the query returns **2,640**.
- **L5.** §2.3's table labels SBDEV-3267 "(fixed on develop)" but then describes the double deferral
  in the present tense. `MobilePickingService` on `origin/develop` has already been converted to a
  direct call (*"SBDEV-3267: call directly — sendAfterCommit ALREADY defers to afterCommit"*), which
  makes `TOTE_ASSIGNED` a **single** deferral from now on — i.e. it migrates into SBDEV-3674's
  population the moment that fix deploys. Say so; otherwise the next reader re-derives the split
  against a tree where it no longer holds.
- **L6 (over-specification that will rot).** §2.2's interval table, §4's "16 `@Lock` sites /
  `findByIdForUpdate` on 8 repositories", §3 Fix E's "flags **exactly 1 site today**", and the §1.1
  row counts are all point-in-time numbers that exist only because the document is detailed enough to
  be wrong about them. The two lock counts already disagree across the evidence lanes (15 / 16 / 17).
  Keep the invariants (Fix E's rule shape; "the inner transaction touches only `message` and
  `los_sequencenumber`") and move the counts into the evidence files with their query text.

---

# D. What is sound — stated once, not re-reviewed

- **§2.5 is correct, and it is no longer a single-instrument claim.** I confirmed step 2 against
  `spring-data-jpa-3.5.7-sources.jar` (Boot 3.5.9's managed line):
  ```java
  public boolean isNew(T entity) {
      if (versionAttribute.isEmpty()
              || versionAttribute.map(Attribute::getJavaType).map(Class::isPrimitive).orElse(false)) {
          return super.isNew(entity);
      }
      BeanWrapper wrapper = new DirectFieldAccessFallbackBeanWrapper(entity);
      return versionAttribute.map(it -> wrapper.getPropertyValue(it.getName()) == null).orElse(true);
  }
  ```
  `AbstractBaseEntity` declares `@Version private Integer version` (non-primitive), `createServiceLog`
  does `m.setVersion(1)` before `messageRepository.save(m)`, and `SimpleJpaRepository.save` is
  `isNew ? persist : merge`. Chain confirmed end to end. Cite the library version in §2.5 and the
  claim is closed. **Fix B and AC-5/AC-6 stand; the §5.2 ordering does not (MED-1).**
- **The lead's Hydra-UAT loose end dissolves.** The 3 UAT resends with no duplicate and `created IS
  NULL` are the **only 3 of 67,204 rows with a null `created`**, each has `version = 2`, a *distinct*
  number from its original, and dates of 2025-03-05 / 2025-07-31 / 2026-03-05 — all inside that
  table's **v1** era (HIGH-5). They are v1 `resendMessage` rows, not a v2 counterexample. §2.5 needs
  no amendment for them; §1.1 does.
- §2.4's retraction holds; I found nothing to add and nothing to re-open.
- Fix A's mechanism, its four `@Lazy @Autowired <Self> self` precedents
  (`CustomerorderBatchService:222`, `ReplenishGeneratorService:57`,
  `ReplenishmentOrderMaintenanceService:114`, `ReturnAdviceAutoReceiveService:143`), and the CGLIB
  reasoning all verify.
- Fix D's four comment citations all verify verbatim at the quoted text (S1/S2 `SkuRestController` ×2,
  S3 `OrderBatchCreationService:209`, S4 `BillofladingService:1675`). The S3 verdict (FALSE) is
  correct.
- `BaseRollbackIntegrationTest`, `NestedSendAfterCommitIT`, `HttpInTransactionArchTest` and
  `NestedCallSiteRailTest` all exist at the asserted paths. The harness choice is right and the three
  fixture traps are correct as far as they go (add MED-3's fourth).
- 39 external sites across 12 files reproduces exactly, per file.
- `4a91fe40` is real (`SBDEV-3325: resend reports an unsaved outcome…`, 2026-10-07) and did add a
  second create-mutate-save site in `resendMessage`'s FAILED branch. §2.6 is accurate.
- Tier **T3** is right. Nothing here argues for splitting scope.
- One alternative burner I **ruled out** so it is not re-derived: a `@NotNull` violation on
  `message.client_id` / `operator_id` between the sequence allocation and the flush. Hydra PRD has
  0 of 9 users with a null `client_id` and the anonymous user exists, so no site burns that way there.

---

# E. Could not verify either way

- Whether `DELETE /v3/message/{id}` is reachable past `FunctionGuardInterceptor` (MED-2). Needs a
  live request; not testable read-only.
- Fix E's "flags **exactly 1 site today**, with no allowlist". Requires running ArchUnit, which this
  lane cannot. The *refinement* that produces it (flag a self-invocation only where the calling method
  does not already supply the same attribute) is sound reasoning and `ReplenishGeneratorService`'s
  4-arg → 5-arg `REQUIRES_NEW` overload does exist as described.
- "Four comments in `src/main` … **zero** in `src/test`" — I confirmed the four; I did not re-run all
  five greps over `src/test`.
- §10 O-2 remains owed: `nywh-shipitez-prd`, `c1wh-shipitez-prd` and `wsl-wineco-prd` all failed to
  connect for me too (CONNECT_TIMEOUT, not access).
- Whether the 98 non-receiving-day burns (HIGH-2) are picking-path `STOCK_UPDATE`. Consistent with
  the 14 non-receiving `sendStockChangeMessage` call sites, not demonstrated. AC-2 does not settle it
  either; a DEBUG-level count of `"end with created message={}"` against committed rows over one
  window would.

---

# F. What would upgrade this to ACCEPT

1. §2.1's case table corrected to 34 / 2 / 3, and §4, §8 row 3/4 and §9 rows 2 and 8 rewritten off it.
2. §2.2 restated on the day-level rate ratio with both limits named; the "518 of 522" sentence deleted.
3. The "burned number = delivered" sentence replaced in all three copies.
4. Fix B rewritten so `createServiceLog` returns `save(m)` unconditionally; the `setVersion(1)`
   alternative named and rejected on the record.
5. §1.1 restated on v2-era denominators, with the v1-migration note in `db_verified_note`.
6. §5.2's ordering constraint withdrawn or restated as present-tense (MED-1).
7. AC-2 given the SENT/stubbed-POST assertions and the fourth fixture trap; AC-4 relabelled and
   AC-4b added; one AC added for site #9.
8. The v1 sibling corrected in the same pass, for all four items in MED-6.
