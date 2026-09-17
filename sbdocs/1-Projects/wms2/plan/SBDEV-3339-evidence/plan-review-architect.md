---
title: "SBDEV-3339 — architect review of the bug-fix plan"
ticket: "SBDEV-3339"
reviewer: "architect lane (arch-review-3339)"
subject: "./../SBDEV-3339-cancelorder-picking-tote-teardown.md (336 lines, frozen)"
graded_against: "origin/develop @ 221caed1"
created: "2026-09-14"
verdict: "ITERATE"
---

# Architect review — SBDEV-3339

**Verdict: ITERATE.** Three blocking items (A-1, A-2, A-3). The diagnosis is right, the fix is in the
right place, and the evidence discipline is better than anything else I have graded in this vault —
so this review is almost entirely disagreements, per the brief.

Every claim below was derived with `git show origin/develop:<path>` / `git grep … origin/develop`.
The local checkout was not read.

---

## A-1 (BLOCKING) — Fix 1 copies half of `cleanUpCancelledOrder`. The missing half is what keeps a tote's `pickingorder_unitload` row unique, and Fix 1 is the change that makes the duplicate reachable.

This is the finding. Everything else on this page is secondary.

`cleanUpCancelledOrder` does **two** things to free a tote, not one. The plan's §2 comparison table
and §5.1 Fix-1 snippet both stop after the first:

```java
// PickingorderBusinessService.cleanUpCancelledOrder — block 1 (the plan copies this)
tote = unitloadRepository.findById(customerOrder.getPickingtoteId()).orElseThrow(...);
unitloadBusinessService.sendToClearing(tote, WmsConstants.CODE_TRANSFER, null, customerOrder.getNumber());
List<Stockunit> stockUnits = stockunitRepository.findByUnitloadId(tote.getId());
stockUnits.forEach(su -> su.setEntityLock(WmsConstants.BusinessObjectLockState.NOT_LOCKED));
stockunitRepository.saveAll(stockUnits);
customerOrder.setHistorytote(tote.getLabelid());
customerOrder.setPickingtoteId(null);
```

```java
// … block 2, at the bottom of the same method (the plan does NOT copy this)
PickingorderUnitload pickingUnitLoad = pickingorderUnitloadService.getByLabel(tote.getLabelid());
if (pickingUnitLoad != null) {
    pickingUnitLoad.setHistorytote(tote.getLabelid());
    pickingUnitLoad.setUnitloadId(null);
    pickingUnitLoad.setState(WmsConstants.State.CANCELED);
    pickingorderUnitloadRepository.save(pickingUnitLoad);
}
```

The plan reads block 2 only as the SBDEV-3316 *diagnostic-link* concern ("preserve the SBDEV-3316
ordering pin at `:648`", §0 row 4) and therefore treats it as read-only sibling context. It is also —
independently — the **uniqueness maintenance** for a repository finder. `PickingorderUnitloadRepository`
says so in its own javadoc:

> *"Most recent picking assignment for a tote label, newest first. Totes are reused, so a label
> accumulates one row per pick it has served. `findByUnitloadLabelid` above returns `Optional` and
> **blows up with `IncorrectResultSizeDataAccessException` once a tote has been used twice** — this
> one is safe to call on a reused tote (SBDEV-2742)."*

And the unsafe finder's own SQL shows the mechanism:

```sql
select a.* from pickingorder_unitload a, unitload b
where a.unitload_id = b.id and b.labelid like :labelid
```

The join is on `a.unitload_id`. A row whose `unitload_id` is **null cannot join** and therefore
cannot make the result multi-valued. Nulling `unitload_id` is what keeps the `Optional` an `Optional`.

**Every path that frees a tote for reuse nulls it. Fix 1 would be the first that does not.**
*Deriving method:* `git grep -n "setUnitloadId(null)" origin/develop -- 'src/main'` plus a read of each
tote-releasing method on the `origin/develop` blob. The paths:

| path | frees the tote? | nulls `pickingorder_unitload.unitload_id`? |
|---|---|---|
| `CustomerorderService.packageOrder` (normal happy path) | yes | **yes** — `pickingUnitLoad.setUnitloadId(null); pickingUnitLoad.setState(WmsConstants.State.FINISHED);` |
| `PickingorderBusinessService.cleanUpCancelledOrder` | yes | **yes** — block 2 above |
| `CustomerorderService.forceCancelOrder` (`state < PACKED` arm) | yes | **no** — pre-existing gap, same shape |
| **Fix 1 as written** | yes | **no** |

*Positive control:* the same grep does find the two `setUnitloadId(null)` sites, so the instrument
reads what exists. *Blind spots:* a bulk/native `UPDATE pickingorder_unitload SET unitload_id = NULL`
would be invisible to it (the plan's own §12 records exactly this class of miss for
`BillofladingService`), and a Flyway/trigger write is invisible to any `src/main` grep.

**Why the row is live at the exact moment Fix 1 runs — from the plan's own citation.** The SBDEV-3316
comment the plan instructs the implementer to preserve measures it:

> *"Measured on Hydra PRD 2026-09-11: `pickingorder_unitload` rows at state 600 (PICKED) carry
> `unitload_id` 2 of 2; at state 700 (FINISHED) 0 of 153."*

The exposure window is precisely state 600. So at the instant Fix 1 fires, the `pickingorder_unitload`
row exists, is at 600, and points at the tote. `cancelOrderPosition` (which runs immediately before)
sets the *Pickingorder* terminal but never touches `pickingorder_unitload` — verified by reading the
method: it writes `pickingPosition`, `pickingOrder` and `customerOrderPosition` only.

**The consequence.** Today the bug is self-limiting: the tote is locked and still pointed at, so it
never re-enters circulation, so its label never accumulates a second joinable row. Fix 1 removes
exactly that limit — that is its purpose. On the **next** order to use tote `T-0002`,
`findByUnitloadLabelid('T-0002')` matches two rows and throws
`IncorrectResultSizeDataAccessException` at three live call sites:

- `CustomerorderService:614` — inside `packageOrder`. **This is the packing path.** A 500 when an
  operator packs an order, on a tote that looks fine.
- `PickingorderBusinessService:669` — `cleanUpCancelledOrder`, via `getByLabel`. Note `getByLabel`
  catches only `NoSuchElementException`, so the multi-row exception escapes.
- `MobileInfoService:352` — mobile tote lookup.

*Deriving method:* `git grep -n "getByLabel\|findByUnitloadLabelid" origin/develop -- 'src/main'`
→ the interface declaration plus exactly these three call sites. *Positive control:* the declaration
appears, so the grep reads the file. *Blind spots:* reflection/SpEL; and SDR export — ruled out here,
the repository carries `@RepositoryRestResource(… exported = false)` at type level, so the
`@RestResource(path = "findByUnitloadLabelid")` does not route.

This is the plan trading a stranded-stock defect for a delayed HTTP 500 on the packing path — a
failure that surfaces on a *different* order, days later, with no link back to the cancel. By the
plan's own severity framing that is arguably worse: the current defect at least leaves a diagnosable
row.

**Required change.** Add block 2 to Fix 1 (≈5 lines, `pickingorderUnitloadRepository` is **already**
a constructor-injected field of `CustomerorderService` — `private final PickingorderUnitloadRepository
pickingorderUnitloadRepository;` at `:90`, already used at `:614` and `:795`, so §11's
"constructor injection unchanged" survives). Three sub-decisions the plan must make explicitly, not
by copy:

1. **Terminal state** — `CANCELED` (matching `cleanUpCancelledOrder`), not `FINISHED`.
2. **Which finder** — `getByLabel` is itself the unsafe one. On a tenant that already has stranded
   totes (Hydra PRD has two, and the runbook in §5.1 prereq 4 does not null `unitload_id` — I grepped
   `free-63-units-t0002-t0007.md` for `pickingorder_unitload` and it appears only in a diagnostic
   `JOIN`, never in a write), `getByLabel` can *already* be multi-valued. Use
   `findLatestByUnitloadLabelid`, which exists for exactly this reason, or handle the multi-row case.
3. **Ordering** — `cleanUpCancelledOrder` keeps block 2 **below** `recordCancellation`, pinned by
   `PickingorderBusinessServiceUnitTest$Sbdev3316_CancellationLogOrdering`. In `cancelOrder` the
   equivalent `recordCancellation` calls happen inside `cancelOrderPosition`, i.e. in the loop that
   already ran. So placing block 2 after the loop satisfies the SBDEV-3316 pin. **State this in the
   plan and pin it with an `InOrder` assertion**, or the next person to "tidy" the placement
   reintroduces SBDEV-3316 on a third path.

**Add a prerequisite query** alongside §5.1's three: on each tenant,
`SELECT u.labelid, count(*) FROM pickingorder_unitload pu JOIN unitload u ON pu.unitload_id = u.id
GROUP BY u.labelid HAVING count(*) > 1;` — expect empty. If it is non-empty **before** this ships,
the duplicate hazard is already live and the ordering of the fix versus the runbook matters.

---

## A-2 (BLOCKING) — §3's discriminator is dead code on the only call path. The regression-chain story, the WineCo/Hydra contrast, and the §8 tenant-selection advice all rest on it.

§3 states:

> *"The discriminator is the first guard of `CustomerorderPositionService.canOrderPositionBeCancelled`
> — `if (customerOrderPosition.getState() >= WmsConstants.State.PACKED) { return false; }`. `false`
> ⇒ the **else** branch ⇒ `cleanUpCancelledOrder` ⇒ correct teardown."*

That guard cannot return `false` from `cancelOrder`. Thirteen lines earlier, `cancelOrder` has
already thrown for any such position:

```java
List<CustomerorderPosition> coPositions = customerorderPositionRepository.findByOrderId(customerOrder.getId());
if (coPositions.stream().anyMatch(position -> position.getState() >= PACKED && position.getState() < WmsConstants.State.CANCELED)) {
    throw new BusinessException("order contains position with status beyond PACKED. can not be cancelled anymore");
}
```

`PACKED = 650`, `CANCELED = 800` (`WmsConstants.State`). Any `customerorder_position` in [650, 800)
throws before `canOrderPositionBeCancelled` is ever called; anything below 650 passes the cited guard.
The guard is unreachable from here, and `cancelOrder:770` is its **only** caller in `src/main`.
*Deriving method:* `git grep -n "canOrderPositionBeCancelled" origin/develop -- 'src/main'` → the
declaration, nine `LOG.debug` string matches inside the method, and one call site
(`CustomerorderService:770`). *Positive control:* the declaration is in the output. *Blind spots:*
reflection/SpEL; and `src/test` callers, which **can** invoke it directly with a position at ≥ 650 and
watch the guard work — which is exactly what a dead guard looks like from a unit test.

The real discriminator, for regular (non-rapid) picking, is the **picking** order/position state:

```java
if (pickingOrder.getState() >= WmsConstants.State.PACKED && pickingOrder.getState() < WmsConstants.State.FINISHED) { return false; }
if (pickingPosition.getState() >= WmsConstants.State.PACKED && pickingPosition.getState() < WmsConstants.State.FINISHED) { return false; }
```

i.e. a `Pickingorder`/`PickingorderPosition` in **[650, 700)**. Three downstream corrections:

1. **The "dwell time at 600" model is wrong.** §3's table columns are labelled "positions at 600
   (exposed) / at 700", but neither value is the discriminator: at 700 the predicate
   `>= 650 && < 700` is **false**, which returns `true` → the *success* branch. Both 600 and 700 route
   to the defective branch.
2. **On Hydra PRD the else branch is unreachable, which makes the defect universal, not windowed.**
   The plan itself quotes the `src/main` comment measuring that band: *"a band holding ZERO rows on
   Hydra PRD: pickingorder is 166 rows (states 300/700/800) and pickingorder_position is 337
   (300/600/800). Neither has an entry in [650,700)."* If no row is ever in [650,700),
   `orderCanBeCancelled` is always `true` and **every** cancel with a live tote strands — not only
   those caught in a narrow window. "7 of 7" then reads as "7 of 7 cancels that had a tote", which is
   a larger claim and a better one. The plan is under-stating its own severity because of the wrong
   mechanism.
3. **§8's tenant advice inverts.** *"WineCo is a poor subject — its positions move to 700 almost
   immediately, so it essentially never enters the exposure window"* is derived from the wrong
   predicate. Under the real one, 700 is still in the exposure window; the thing that actually
   determines exposure is whether `pickingtote_id` is non-null at cancel time. Re-derive before
   choosing the manual-test tenant, or the manual test is run somewhere it cannot reproduce.

Also correct §4's flow diagram, which reproduces the same wrong branch condition.

**None of this changes the fix.** It changes the severity claim (upward), the blast-radius reasoning,
and where the manual test is run.

---

## A-3 (BLOCKING) — `CancelOrderRollbackIntegrationTest` does not pin what the plan says it pins, and Fix 3 — the riskiest change — is gated on it three separate times.

The plan leans on this class in §5.2 (*"That is correct and `CancelOrderRollbackIntegrationTest`
already pins it"*), in §9 risk row 2 (*"already pinned by `CancelOrderRollbackIntegrationTest`"*) and
in "Deliberately skipped" (*"confirm against `CancelOrderRollbackIntegrationTest`'s existing batch
coverage that a contained failure still leaves the failing order fully rolled back"*).

The test:

```java
@DisplayName("cancelOrder should not post to OMS when post-cancel cleanup throws (F5)")
void cancelOrder_shouldNotPostToOms_whenPostCancelCleanupThrows() {
    …
    order.setState(WmsConstants.State.FINISHED);
    assertThatThrownBy(() -> customerorderService.cancelOrder(order, true)).isInstanceOf(Exception.class);
    verify(httpRestService, never()).post(any(), any());
}
```

Four problems, in order of severity:

1. **It never reaches the code under discussion.** Setting the order to `FINISHED` trips
   `isShippedOrPastCancellationBoundary` at the top of `cancelOrder` — a *pre*-cancel guard. No state
   write, no position loop, no teardown, no outbox enqueue ever happens. The test's own comment
   concedes it: *"The exact throwing site doesn't matter for this assertion."* For SBDEV-2214's
   purpose that was fine. For "a post-cancel throw rolls back the `CANCELED` state **and** the outbox
   row" it is vacuous — nothing was written to roll back.
2. **The only assertion is a negative on a mock** — `verify(httpRestService, never()).post(...)`. It
   asserts nothing about `customerorder.state`, nothing about the outbox table. The plan's own §8
   doctrine ("a green suite proves nothing here", "an unstubbed **void** … is a no-op under either
   setting") was applied rigorously to the unit tests and not at all to the integration test it then
   relied on. That asymmetry is the finding.
3. **There is no "existing batch coverage" of `cancelPositions`.** The batch test in that class is
   `cancelBatch_shouldNotPostToOms_whenChildSaveThrows` — `CustomerorderBatchService.cancelBatch`, the
   dead method §5.4 proposes deleting. The §"Deliberately skipped" instruction is not executable as
   written, and if §5.4 is ever approved it retires one of the four tests in the class.
4. **It runs on H2** — `@ActiveProfiles("integration")` via `BaseRollbackIntegrationTest`, and the
   fixture comment says *"FK not enforced by H2 DDL, just satisfies @NotNull"*. Whatever it proves, it
   does not prove PostgreSQL rollback/locking behaviour.

**Required change.** Either (a) write the missing test — a post-cancel teardown throw (stub
`unitloadBusinessService.sendToClearing` to throw `BusinessException`) and assert the order is **still
at its pre-cancel state** and **no outbox row exists** after the call, plus a three-order
`cancelPositions` run asserting orders 1 and 3 committed `CANCELED` and order 2 is untouched — or
(b) strike all three citations and say plainly that the rollback shape Fix 3 depends on is untested.
Do not ship Fix 3 on a citation that does not hold. Note this test must **not** be `@Transactional`
at the method level or the rollback is unobservable; `wms2` repository tests commit rather than roll
back, so assert by re-reading by id, never `isEmpty()`.

---

## Question 1 — extract a shared method, or a third inline copy?

**Strongest case for extraction.** There are not three copies, there are **six partial ones**, and
they have drifted on six independent axes. Derived by reading each on the `origin/develop` blob:

| | lock clear | tote's own lock | order of `sendToClearing` vs clear | `GOING_TO_DELETE` guard | save shape | retires `pickingorder_unitload` |
|---|---|---|---|---|---|---|
| `forceCancelOrder` (`< PACKED`) | stock | **yes** | **clear first** | **yes** | per-unit `save` | **no** |
| `forceCancelOrder` (PACKED arm, parcel) | stock | yes (parcel) | clear first | no | per-unit `save` | n/a |
| `cleanUpCancelledOrder` | stock | no | **`sendToClearing` first** | no | `saveAll` | **yes** |
| `packageOrder` | n/a (transfers stock) | n/a | n/a | n/a | n/a | **yes** (`FINISHED`) |
| `cancelBatch` | **none** | no | — | no | — | no |
| **Fix 1 as planned** | stock | no | `sendToClearing` first | no | `saveAll` | **no** |

Fix 1 is a *fourth* distinct combination: it takes `cleanUpCancelledOrder`'s ordering and breadth but
lands in `CustomerorderService` next to `forceCancelOrder`, which does the opposite on two axes —
so the next reader of `CustomerorderService` sees two adjacent teardowns that disagree and no note
saying which is canonical. A `releasePickingTote(Customerorder)` would make all six decisions once,
turn AC-2's ordering from a property of one call site into a property of the method, and — decisively —
would have made A-1 structurally impossible: you cannot copy half of a method you are calling. The
plan's §5.3 already concedes that comment-enforced coupling is the enforcement mechanism (*"Any future
narrowing must narrow both paths together"*), which is the weakest form there is.

**Strongest case against.** (a) The canonical copy lives in `PickingorderBusinessService` and the
other two in `CustomerorderService`; the dependency runs `CustomerorderService →
PickingorderBusinessService` one-way (`private final PickingorderBusinessService
pickingorderBusinessService;` at `:98`, no `@Lazy`, no reverse reference), so extraction is possible —
but unifying means **choosing** on the two axes where `forceCancelOrder` deliberately differs (it
clears the tote's own lock and carries the `GOING_TO_DELETE` guard), i.e. a behaviour change on a path
§0 row 3 declares read-only. (b) `cleanUpCancelledOrder`'s block 2 is pinned below `recordCancellation`
by an `InOrder` test with a "hoisting this makes it fail, verified by hand-applying that exact mutant"
note; a naive extraction hoists it. (c) The safety net is three unit-test classes whose largest is
`@MockitoSettings(strictness = Strictness.LENIENT)` (verified at `CustomerorderServiceUnitTest:59`) —
a weaker net for a three-call-site refactor than for a fifteen-line insertion. (d) Three transaction
annotations with different `rollbackFor` sets would collapse into one.

**Which wins: inline, for this ticket.** The refactor's safety net is measurably worse than the
insertion's, and the plan is right that the blast radius of touching `forceCancelOrder` exceeds the
blast radius of the defect. But the plan should stop presenting the duplication as a neutral cost.
**The duplication cost is already realized, inside this very plan, as A-1.** Land Fix 1 + block 2
inline, and file the extraction as a named follow-up whose first acceptance criterion is a table like
the one above with every cell agreeing.

## Question 2 — steelman the antithesis

**Steelman 1 (layering): the teardown belongs in the picking domain, not the order domain.** The lock
is minted by `PickingorderBusinessService` on pick confirm (`pickToStock.setEntityLock(PICKED_FOR_GOODSOUT)`).
The tote's lifecycle is recorded in `pickingorder_unitload`, a picking-domain table. The one teardown
that is complete lives in `PickingorderBusinessService`. So Fix 1 pushes picking-domain knowledge —
lock states, tote lifecycle, the `pickingorder_unitload` contract — into `CustomerorderService` for the
third time. Under this reading, `cancelOrder`'s success branch should delegate
(`pickingorderBusinessService.releaseToteForCancelledOrder(customerOrder)`), not re-implement.

**Does it defeat the plan?** Not on scheduling — but it **predicted A-1**, which is strong evidence it
is right about the layering. The plan's framing, *"Shape and ordering copied from
`cleanUpCancelledOrder`"*, is precisely the failure mode this steelman names: copying a shape across a
domain boundary copies what you noticed and drops what you did not. So it defeats the *framing*, not
the *decision*. Fix the framing: say "a partial copy of `cleanUpCancelledOrder`, enumerated
block-by-block", with the table from Question 1 in the plan.

**Steelman 2 (physical truth): the fix makes the inventory record lie.** `sendToClearing` writes
`unitload.storagelocation_id = Clearing` for a tote that is physically still on a cart on the pick
path, and does it with `ignoreLock=true`, so nothing checks. After the fix, WMS asserts the goods are
at Clearing; nobody moved them. That is a different data-integrity defect, quieter than the one being
fixed, and the plan's own manual test grades it as a **pass** (*"tote's `unitload.storagelocation_id`
= Clearing"*).

**Does it defeat the plan?** No — both live siblings do the same thing, the manual runbook Nam already
ran does the same thing, and the alternative (leave stock locked forever) is worse. But it exposes a
**real omission**: §5.1's prerequisites cover DB seeding, tenant config, data migration, monitoring
and the OMS contract, and contain **no operator-facing item**. Somebody has to physically walk cancelled
totes to Clearing, and nothing in the plan or the ticket tells them. Add a prerequisite row: warehouse
ops notification + a line in the release note. This is the cheapest item on this page and the only one
that fails silently in the physical world.

**Steelman 3 (layer-up): fix `OPERATOR_REMOVABLE` instead.** §1 identifies the true reason this is a
stuck defect rather than an untidy one — `StockunitService.removeLock` refuses `PICKED_FOR_GOODSOUT`,
so there is no manual escape. One could argue the durable fix is the escape hatch, since new
lock-stranding paths will keep appearing. **This one does not survive:** widening
`OPERATOR_REMOVABLE` lets an operator unlock stock that is legitimately staged for goods-out, which is
a security-shaped change on a much hotter path. §0 row 8 and the §7 non-goals reject it correctly and
for the right reason. No change required.

## Question 3 — lock order and transaction shape

**The monotone `Batch ⊃ Pickingorder ⊃ Stockunit/Unitload` chain is not real as stated, and §5 points
1 and 2 cannot both be true at once.**

What `cancelOrder` actually acquires, read off the blobs:

- `clubRunCancellationBlockingState` → `customerorderBatchRepository.findByIdForUpdate(...)` — **Batch**, and only for a CLUB batch with a non-null `orderbatchId`. For a non-club order it takes nothing, so "Batch ⊃ …" has no Batch in it.
- the loop → `cancelOrderPosition` per position, each doing `pickingorderRepository.findByIdForUpdate(pickingPosition.getPickingorderId())` (**Pickingorder**) and then, when `pickfromstockunitId != null`, `stockunitRepository.findByIdForUpdate(pickingPosition.getPickfromstockunitId())` (**Stockunit**). The sequence is P,S,P,S… per position — monotone only if every position of the order belongs to one `Pickingorder`. The plan neither states nor verifies that assumption.
- the teardown → `sendToClearing(tote, CODE_TRANSFER, …)`. `CODE_TRANSFER` **is** in `BLOCK_REALIGN_CODES` (verified in `PickLineActivityCodeClassifier`), so the pre-walk runs and `lockOwningPickingorders` does `pickingorderRepository.findByIdForUpdate(pickingorderId)` — **Pickingorder, after the loop's Stockunit locks.**

So placing the teardown after the loop puts a Pickingorder acquisition *after* Stockunit acquisitions
— the exact inversion §5 point 1 claims the placement avoids. Reachable by a partially-picked order:
positions below 600 still carry `pickfromstockunit_id` (the loop locks their Stockunits), and the tote
exists because the *other* positions were picked.

But now the other side. `lockOwningPickingorders` resolves owners via
`pickingorderPositionRepository.findByPickfromstockunitId(stockUnitId)` over the **tote's** stock — and
the tote's stock is picked-*to* stock, which backs no pick line. Worse for the plan's argument,
`cancelOrderPosition` — which the placement guarantees has already run — executes
`pickingPosition.setPickfromstockunitId(null);` on every line of this order. So:

> **Either the pre-walk finds owning Pickingorders — and the placement inverts the lock order — or it
> finds none, and §5 point 2's entire rationale for ordering `sendToClearing` before the stock clear
> ("for lock order, not for a guard") is inoperative. Exactly one holds at a time. The plan asserts
> both.**

Two consequences for the plan text:

- §10 row 8's *"`sendToClearing`'s BLOCK_REALIGN pre-walk takes a pessimistic `Pickingorder` lock …
  chain stays `Batch ⊃ Pickingorder ⊃ Stockunit/Unitload`"* is a completeness claim with no deriving
  method, and on the common case the lock it names is never acquired. Rewrite it.
- The **production comment** in the Fix 1 snippet — *"`sendToClearing` FIRST keeps Pickingorder before
  Stockunit (plan §5 points 1-2)"* — states a mechanism that does not operate here. A wrong comment
  frozen into `CustomerorderService` next to a mutation-checked `InOrder` test is durable
  misinformation. Replace the reason with the true one: **match the canonical sibling's order so the
  two branches are diffable**, and note that the flush-time ordering, not the call order, is what a
  lock argument would have to reason about.

**AC-2 should stay** — pinning the ordering is cheap and right. Just stop justifying it with a lock
argument. *Blind spot I did not close:* `replenishmentOrderSourceSyncService.syncForMovedStockUnit` is
called per moved stock unit inside `processTransfer`'s BLOCK_REALIGN arm and I did not read it; §9's
risk row already names this and correctly calls it the highest-value remaining read. **Also not
named by the plan:** the same arm calls `pickLineRealignmentService.realignForMovedStockUnit(…)`,
which **writes** (`pp.setPickfromunitloadlabel(newUl.getLabelid()); pp.setPickfromlocationname(newLoc.getName());`).
Fix 1 therefore adds a pick-line *write* path to cancel, not just reads and a move. Add it to §12.

**Transaction shape is otherwise sound.** `spring.jpa.open-in-view=false`
(`src/main/resources/application.properties:85`; positive control — the surrounding `spring.jpa.*`
block is present in the same output, so the file was read), so each `cancelOrder` gets its own
persistence context and one order's rollback cannot poison the next — this is the single most
important fact underwriting Fix 3 and **the plan never states it**. Add it to §5.2; it is the reason
containment is safe, and if someone flips OSIV on later, Fix 3 becomes unsafe silently.

## Question 4 — Fix 3: does containment risk committing a half-cancelled order?

**No — and the plan's stated reason is not the load-bearing one.**

- **`rollbackFor` is not what saves you.** Spring's default rule already rolls back on any
  `RuntimeException` or `Error`; `rollbackFor = {BusinessException.class, FacadeException.class}`
  *adds* the two checked types. So an `IncorrectResultSizeDataAccessException` (A-1),
  `InvalidDataAccessApiUsageException`, or a bare NPE rolls back the failing order's transaction just
  as completely. The controller's `catch (Exception e)` sees an exception that has **already** caused
  its own rollback, because the `@Transactional` proxy boundary is crossed on the way out. Containment
  is safe against the "half-cancelled order" failure mode.
- **The real guarantee is OSIV=false**, per Question 3. Say so.
- **Scope the catch correctly.** `validateWarehouse`, the `batchId`/`positions` validation, the
  `findByBatchid` lookup and the `findByExternalNumber` lookup all throw
  `WebserviceBusinessExceptionClientSide` *before* `cancelOrder`. Those are request-shape errors and
  must keep aborting. §6's *"catch around the per-order `cancelOrder` call"* is the right scope —
  keep that wording; do not let it drift to a catch around the loop body.
- **`finalizeBatchIfComplete` is self-protecting.** Order 2 stays non-terminal, so a sibling's
  finalization cannot mark the batch complete over it. No change needed; worth one sentence so a
  reviewer does not have to re-derive it.
- **The `errors` map claim is correct.** `Map<String, String> errors = new HashMap<>();` is declared
  in `cancelPositions` and never read or written anywhere in the method.

**Two gaps the plan does not cover:**

1. **The service-log `message` row.** On the success exit, `cancelPositions` writes
   `messageService.createMessage(…, ORDER_BATCH_CANCELLED_FROM_PSD, "N/A", WmsConstants.MessageStatus.RECEIVED, Integer.toString(HttpStatus.OK.value()), null)`.
   Under Option B a batch with a failed order still takes that exit and still logs
   `RECEIVED` / `200`. **This is the exact table §1 used as its primary evidence** (*"8 `message` rows
   with `process = 'ORDER_BATCH_CANCELLED_FROM_PSD'`"*). Fix 3 silently changes what that row means and
   destroys the forensic trail the plan itself depended on. Decide explicitly: either write
   `MessageStatus.FAILED` / a partial-status code when `errors` is non-empty, or record the failed
   `unique_id` list in the payload. The ERROR log is not a substitute — §5.1 prereq 5 already
   concedes nothing scrapes Prometheus, and logs are not queryable five weeks later, which is exactly
   the horizon at which this ticket was diagnosed.
2. **The HTTP status.** §5.2 forbids a bare 200 but never names what to return. A 200-with-errors and a
   207/400 are materially different for an OMS client that branches on status before parsing. Prereq 6
   asks Nam/OMS for the *shape*; it must also ask for the *status*.

**AC-6 grades the wrong exception class.** It stubs `cancelOrder` to throw — but the plan's own §5.2
enumerates the new throw sources as `BusinessException`, `FacadeException` and `EntityNotFoundException`,
and A-1 adds an unchecked `DataAccessException`. The containment must hold for all four. Make AC-6
parameterised over at least one checked and one unchecked type; a `continue` that works for
`BusinessException` and not for a `RuntimeException` is a plausible implementation slip that a
single-type test cannot see.

## Question 5 — a tradeoff named as a tension, not resolved

**Operator authority versus branch symmetry (§5.3) — and the plan resolves it with a premise that is
false.**

§5.3 says:

> *"That is **already** the behaviour of the live deferred-cancel path (`cleanUpCancelledOrder`'s
> unfiltered `stockUnits.forEach(...)`), so this fix **introduces no new exposure**; it stops the two
> branches disagreeing."*

"Introduces no new exposure" is not true. Today the success branch clears **nothing**, so an
operator's `QUALITY_FAULT` (103) or `ON_HOLD` (104) on tote stock **survives** a success-branch cancel.
After the fix it does not. The set of cancels that silently release a quality hold strictly grows by
the size of the success branch — which, per A-2, is *every* cancel on Hydra PRD, not a narrow window.
The correct sentence is: *"this extends an existing exposure from one branch to both, deliberately,
because asymmetry is judged worse than the exposure."* That may well still be Nam's call — but it is a
different call than the one §5.3 presents, and per this repo's own claim discipline a completeness
word ("no new exposure") needs a deriving method, which it does not have.

The tension underneath, which I am **not** resolving: the plan adopts *branch symmetry* as the
governing value at the order level (§5.3: "the two branches of `cancelOrder` must leave identical
state") and *containment over atomicity* at the batch level (§5.2 Option B: let per-order outcomes
differ). Those pull opposite ways on the same endpoint in the same PR. And Fix 1 as written breaks
the symmetry principle itself, on `pickingorder_unitload` (A-1) — so the plan's stated principle is
already violated by the plan's own fix. Whichever way Nam resolves it, the two sections should be
made to argue from one principle, or the divergence should be recorded as deliberate the way §5.3
records the `CancellationReversalService` divergence.

## Question 6 — principle violations

1. **"State the invariant, not the omission" — applied to one invariant, missed on its neighbour.**
   §2 derives the `PICKED_FOR_GOODSOUT` invariant rigorously, with producers, a deriving method and a
   proven blind spot. It is a genuinely good piece of work. The same method applied to the *rest of*
   `cleanUpCancelledOrder` yields a second invariant of identical shape — *every path that frees a
   tote for reuse must null `pickingorder_unitload.unitload_id`* — which the plan does not state and
   Fix 1 violates (A-1). The failure was scoping the invariant search to the *symptom column*
   (`entity_lock`) rather than to the *sibling method*.
2. **Completeness words without a deriving method.** §5.3 "introduces no new exposure"; §10 row 8
   "chain stays `Batch ⊃ Pickingorder ⊃ Stockunit/Unitload`"; §5 point 2 "There is **no** `entity_lock`
   guard anywhere on that path" (this third one **does** carry a deriving method, a positive control
   and a named blind spot — it is the model the other two should follow).
3. **"A green test proves nothing" applied asymmetrically.** §8's two warning blocks are exemplary
   about the unit tests. The integration test the plan then leans on three times proves nothing, and
   was not subjected to the same reading (A-3).
4. **A dead guard cited as a live discriminator** (A-2) — the failure mode the repo's own doctrine
   calls "verify with a second instrument": the guard is real, its file is real, and only checking
   the *caller* reveals it is unreachable.

## Where the plan is right — briefly, then moving on

The defect is real and correctly localised. Fix 1's placement (after the loop, before `setState`) is
correct, and is correct for reasons the plan did not give: `cancelOrderPosition` nulls
`pickfromstockunit_id` before the teardown runs, which makes `assertNoActivePickFor` structurally
unreachable for this order's own lines — a stronger argument than §5 point 2's "measured 0". The
`pickingtoteId != null` guard is necessary (SBDEV-2102, and `findById(null)` throws
`IllegalArgumentException`). Fix 2's NPE is real and one line. The argument-transposition non-goal is
right. Not clearing the tote's own lock is right and well-evidenced. §5.4's "delete, don't fix"
reasoning on `cancelBatch` is right, as is refusing to absorb it. The withdrawal of the `T-0010`
attribution, and saying so in the plan rather than quietly dropping it, is the right instinct.
Declining the verify script is right. §12 is the most honest blind-spot list I have read in this
vault, and it caught the `BillofladingService` bulk-JPQL miss that the same class of grep produced in
A-1 — the plan had the right instrument and pointed it at one column instead of one method.

---

## Required changes for APPROVE

**Blocking:**
1. **A-1** — add the `pickingorder_unitload` retirement to Fix 1, with the finder choice, terminal
   state and `InOrder` ordering decided explicitly; add the duplicate-label prerequisite query; add a
   new acceptance criterion and its mutant; sequence against the §5.1 prereq-4 runbook, which does not
   null `unitload_id`.
2. **A-2** — re-derive §3's discriminator (and §4's diagram, and §8's tenant advice) from
   `canOrderPositionBeCancelled`'s *regular-picking* arm; state that the `>= PACKED` guard is
   unreachable from `cancelOrder`; restate the severity, which goes up.
3. **A-3** — either write the post-cancel rollback test (and a real three-order `cancelPositions`
   containment test) or strike all three `CancelOrderRollbackIntegrationTest` citations.

**Required, non-blocking-if-explicitly-deferred:**
4. Rewrite the §5 point 1 / point 2 / §10 row 8 lock-order rationale, and the production comment in
   the Fix 1 snippet, so the plan does not assert two claims that cannot both hold (Question 3).
5. Correct §5.3's "introduces no new exposure" (Question 5).
6. Decide the `ORDER_BATCH_CANCELLED_FROM_PSD` service-log status and the HTTP status under Option B;
   add both to prereq 6 (Question 4).
7. Add `spring.jpa.open-in-view=false` to §5.2 as the actual guarantee underwriting containment.
8. Parameterise AC-6 over a checked **and** an unchecked exception.
9. Add an operator/ops-notification prerequisite for the physical tote move (Question 2, steelman 2).
10. Add `pickLineRealignmentService.realignForMovedStockUnit`'s pick-line writes to §12.
11. Add the extraction follow-up ticket (Question 1), with the six-axis table as its first AC.
