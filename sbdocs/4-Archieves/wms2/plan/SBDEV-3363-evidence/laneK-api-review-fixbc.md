# Lane K — API code review, SBDEV-3363 Fix B (AC-5) + server half of Fix C (M-4)

- **Subject:** worktree `/home/nampark/dev/wms-claude/.claude/worktrees/wms2-api/SBDEV-3363-ac5`,
  branch `bugfix/SBDEV-3363-deferred-cancel-terminal-path-ac5`, commit `af403931`, base `4bef7e77`.
- **Diff:** `PickingorderBusinessService.java` (+187/-36ish), `MobilePickingService.java` (+58),
  `DeferredCancelTerminalPathIntegrationTest.java` (new, +320), `MobilePickingServiceUnitTest.java` (+15).
- **Reviewed against:** plan §0.2, §0.3, §2.2, §3.2, §3.3, §6, §7 and `laneB-option3-architect.md` §1.2.
- **Verdict:** the design is right and the two halves genuinely do move together, but **one in-scope
  site from the plan's own enumeration was not converted (H-1)**, and several comments in the diff
  assert things the code does not do. 1 High, 4 Medium, 8 Low.

---

## H-1 (High) — P-8 `rapidPickingScanSource` is in the plan's scope table and was not converted

Plan §0.2 scopes **"B1–B8 | `MobilePickingService` P-1…P-6, P-8 · `PickingorderBusinessService.confirmPick`
P-7"**. The diff converts P-1, P-2, P-4, P-5, P-6 and P-7. **P-8 is untouched.**

`MobilePickingService.rapidPickingScanSource` still carries the raw loop:

```java
pickingOrder = pickingorderBusinessService.confirmPick(pickingPosition, pickingorderUnitload, …);

PickingHighPositionInfoDto dto = new PickingHighPositionInfoDto();
for (PickingorderPosition pp : pickingorderPositionRepository.findByPickingorderId(pickingOrder.getId())) {
    if (pp.getState() < WmsConstants.State.PICKED) {
        …
        dto.setPickCompleted(false);
        return dto;
    }
}
```

`grep -rn "isPickingOrderComplete" src/main/` returns five `MobilePickingService` hits; none is in
`rapidPickingScanSource`.

**Why this is functional, not cosmetic.** On a RAPID_PICKING section, with the trigger restored:

1. `confirmPick` → `assertPickNotCancelled` → `isDemandCancelled` now returns true on
   `markedforcancellation`, so the scan throws
   `FacadeException(PICK_CONFIRM_ORDER_CANCELLED)` and the transaction rolls back.
2. If any pickable line remains (multi-CO picking order), the loop above still reports the
   demand-cancelled open lines as outstanding — `pickCompleted=false` — and hands the operator one of
   them, which step 1 then refuses. That is the "operator retries forever" loop M-4 exists to kill,
   reproduced on the path M-4's payload never reaches (rapid picking reads
   `PickingHighPositionInfoDto`, not `getPickingOrderPositionsInfo`'s map, so the new
   `demandCancelled` field is invisible there).
3. `resumePickingOrderIfExists` cannot rescue it — it early-returns for RAPID_PICKING
   (`case WmsConstants.SectionPickingType.RAPID_PICKING: … return null;`) **before** reaching its
   converted gate.

The escape hatches are real, so this is High and not Critical: `releasePickingOrder(PickingorderPosition)`
clears the operator hold, and the next claim runs `finalizePickingOrderForStart` (P-5, converted),
which does settle the order. But the in-flow behaviour for the operator holding the order is a hard
exception with no in-flow resolution — narrower than, but the same shape as, the SBDEV-3332 strand the
plan says must not be reintroduced.

**Recommend:** route P-8 through `isPickingOrderComplete`. The loop needs restructuring (it both decides
completeness and picks the next line), so the minimal form is a pre-test:

```java
List<PickingorderPosition> poPositions = pickingorderPositionRepository.findByPickingorderId(pickingOrder.getId());
if (!pickingorderBusinessService.isPickingOrderComplete(poPositions)) {
    for (PickingorderPosition pp : poPositions) { … }   // hand out the next OPEN, non-cancelled line
}
```
and the inner loop must skip demand-cancelled lines too, otherwise it hands out a line that
`confirmPick` will refuse.

**Secondary consequence:** the new javadoc on `isPickingOrderComplete` cites this exact method as a
caller (see L-3). It is not one.

---

## M-1 (Medium) — `confirmPick` pays 3 extra queries on every non-final pick, and the comment claims the opposite

`PickingorderBusinessService.confirmPick`:

```java
// The count is kept as a cheap pre-test: when it is zero the order is complete by the old
// rule too and isPickingOrderComplete's fast path would return true without loading anything,
// so this short-circuit costs one query and saves a method call. When it is NON-zero the
// helper decides, and only then is the CO chain loaded.
long unpickedCount = pickingorderPositionRepository.countByPickingorderIdAndStateLessThan(…, PICKED);
boolean complete = unpickedCount == 0 || isPickingOrderComplete(pickingOrder.getId());
```

Java `||` short-circuits, so the helper runs **iff `unpickedCount > 0`** — which is every pick except
the last one in the order. Per non-final confirm:

| | before | after |
|---|---|---|
| last pick of an order | 1 query (`count`) | 1 query |
| **every other pick** | 1 query | **4 queries** — `count`, `findByPickingorderId`, `findAllById(copIds)`, `findAllById(coIds)` |

On a 30-line order that is 87 extra round-trips, on the single stock-moving choke point for **both**
pick paths (`processPick` and `rapidPickingScanSource`). The comment's framing — "this short-circuit
costs one query and saves a method call" — describes the rare branch as if it were the common one.
`unpickedCount` has no other use in the method, so the count query is now pure overhead in the
common case.

Answering the brief's question 6 directly: **the short-circuit is logically sound** —
`unpickedCount == 0` (a SQL count of `state < PICKED`, auto-flushed because the query space
intersects the dirty `pickingorder_position`) strictly implies `isPickingOrderComplete`'s fast path
would return true. It is redundant, not wrong. The cost is the issue.

**Recommend** (pick one, both acceptable):
- keep the shape, correct the comment to state the real cost, and say it was accepted; **or**
- replace the count with one repository query that counts open lines whose demand is *not*
  cancelled (join `customerorder_position` / `customerorder`, exclude `state = 800` at all three
  levels and `markedforcancellation = true`). One query, strictly cheaper than today's `count`.
  Trade-off: it re-expresses `isDemandCancelled` in JPQL, which is the duplication §3.2 exists to
  avoid — so this is a judgement call, not a defect fix.

---

## M-2 (Medium) — a `@GetMapping` can now cancel a customer order and emit an OMS message

`PickingController`:

```java
@GetMapping(path= "/pickingOrderPositionsInfo/{id}", produces = "application/json")
public ResponseEntity<Object> pickingOrderPositionsInfo(@PathVariable("id") Long id, …)
```

`MobilePickingService.getPickingOrderPositionsInfo`:

```java
if (pickingOrder.getState() < WmsConstants.State.STARTED)
     startPickingOrder(pickingOrder, user);
```

`startPickingOrder` is P-4, now demand-aware. For a marked order sitting below `STARTED`, its gate
returns true, it sets `PICKED`, and calls `finishPickingOrder` → the `markedforcancellation` dispatch →
`cleanUpCancelledOrder` → pick lines cancelled, CO → `CANCELED`, and an
`ORDER_BATCH_CANCELLED_FROM_WMS` outbox row enqueued. Before this change P-4's gate could not be true
with open lines, so opening the pick list could not do any of that.

Two sub-problems:

1. **The return value is discarded.** `startPickingOrder` returns `null` precisely when it finished
   the order; `getPickingOrderPositionsInfo` ignores that and carries on building a pick list for an
   order it has just cancelled. The operator gets a screen of 800-state rows (all now flagged
   `demandCancelled = true`) instead of an "order cancelled" response.
2. **It is a GET.** The mobile axios layer retries; a retry hits
   `finishPickingOrder`'s `state >= FINISHED → FacadeException("ORDER_ALREADY_FINISHED")`, surfacing a
   spurious error rather than double-cancelling (`cleanUpCancelledOrder` has its own already-cancelled
   no-op guard), so the failure mode is an error message, not corruption.

The method was already write-shaped (`findByIdForUpdate`, a state promotion), so this is not a new
class of behaviour — but the blast radius of that write grew from "promote to STARTED" to "cancel the
customer order and notify OMS", with no test.

**Recommend:** capture the result and return early / throw when `startPickingOrder` returns null.

---

## M-3 (Medium) — `demandCancelled` is emitted for PICKED lines too, which the plan's UI filter will hide

`getPickingOrderPositionsInfo` builds `poPositions` as **every** line of the order (there is no
`state < PICKED` filter on the map-building loop; the only such filter is on `stockunitIds`, for the
sort chain). `findDemandCancelledPickLineIds` is called on that full list, and
`isDemandCancelled` tests the **customer order**, not the line — so on a marked order **every** row
gets `demandCancelled = true`, including lines already at `PICKED(600)`.

Plan §3.3's filter is `p => p.pickStatus !== CANCELLED_PICK_STATUS && !p.demandCancelled`. Today
`pickStatus !== 'Cancelled'` keeps picked rows visible; after this change they vanish. For a marked
order the list goes fully empty.

That may well be the intent (nothing left to do on a cancelled order), and the field name is
literally accurate — but §3.3 does not discuss it, and it is a behaviour change to already-picked
rows that no AC covers. Flagging for the mobile lane to confirm, and for the plan to state the
intent. If the intent is "rows the operator can still act on", the server should scope the set to
`state < PICKED`; if the intent is "this line's demand is cancelled" (the current name and javadoc),
leave it and document that the list empties.

---

## M-4 (Medium) — the new logic has no direct tests, and a comment claims tests that do not exist

`grep -rl "isPickingOrderComplete\|findDemandCancelledPickLineIds\|demandCancelled" src/test/` returns
exactly one file: `MobilePickingServiceUnitTest.java`, and its only three hits are
`when(pickingorderBusinessService.isPickingOrderComplete(anyList())).thenReturn(true)` — stubs added
to keep pre-existing tests green.

So, untested in this diff:

- `isPickingOrderComplete` (both overloads) — no direct test of the predicate.
- `findDemandCancelledPickLineIds` — no test at all; none of the four `isDemandCancelled` triggers,
  the null-`customerorderpositionId` path, or the missing-CO-position path is exercised through it.
- The `demandCancelled` map entry (the whole server half of Fix C / M-4) — **zero coverage**. Rename
  the key, drop the `map.put`, or invert the boolean and nothing goes red.
- **P-7, `confirmPick`'s gate** — the plan calls this "the commonest completion path". Mutating
  `unpickedCount == 0 || isPickingOrderComplete(…)` back to `unpickedCount == 0` survives.
- P-1, P-4, P-5, P-6 — the IT drives only P-2 (`releasePickingOrder(Pickingorder)`).

And the comment added to the unit test asserts:

> "the predicate itself is covered by its own tests and by `DeferredCancelTerminalPathIntegrationTest`."

The first half is false — there are no such tests. Per this repo's stated claim discipline, that
sentence should either become true or be deleted.

The IT itself is good work: it drives the real service, seeds the fixture idempotently for a
non-transactional base, asserts the outbox row, and carries a proper negative case
(`…shouldNotCancelOrder_whenNotMarkedAndLineStillOpen`). The gap is breadth, not quality. Minimum
addition: one IT that reaches `confirmPick`'s gate (needs a multi-CO picking order: one CO live, one
marked — picking the live CO's last line is the only way to reach the gate, since
`assertPickNotCancelled` refuses every line of a single-CO marked order before the gate is reached),
and one assertion on the `demandCancelled` key.

---

## Low findings

**L-1 — `@Transactional` on `isPickingOrderComplete(Long)` is inert.** Its only call site is
`confirmPick`, in the same bean:

```java
boolean complete = unpickedCount == 0 || isPickingOrderComplete(pickingOrder.getId());
```

Self-invocation bypasses the Spring proxy, so
`@Transactional(value = "tenantTransactionManager", readOnly = true)` does nothing at any call site
that exists today. This is exactly the shape `cancelOpenPickLines`' own javadoc, 400 lines above,
declares against:

> "Deliberately NOT `@Transactional`: `cleanUpCancelledOrder` calls it by self-invocation, which
> bypasses the Spring proxy and would make the annotation inert and misleading."

Functionally harmless — `confirmPick` is `@Transactional(value = "tenantTransactionManager", …)`, so
the reads run on the correct manager inside the caller's transaction, and the landlord-`@Primary`
trap is not triggered anywhere in this diff (every annotation added names `tenantTransactionManager`
explicitly, and every `MobilePickingService` entry point is itself
`@Transactional(value = "tenantTransactionManager", …)`). **Recommend:** drop the annotation and say
why, matching the sibling.

**L-2 — the overload pair is annotated inconsistently.** `isPickingOrderComplete(Long)` and
`findDemandCancelledPickLineIds(List)` carry `@Transactional(tenantTransactionManager, readOnly)`;
`isPickingOrderComplete(List)` — the one all five external `MobilePickingService` gates call — carries
none. Today every caller is inside a tenant transaction, so it is correct. But it is the most exposed
of the three and the only one without a declared boundary; if it is ever called outside a transaction
the two `findAllById` calls run as two independent repository-level transactions and the answer is a
non-atomic read. Either annotate it or state the precondition in its javadoc.

**L-3 — the lock-ordering javadoc's cited caller is not a caller.** The javadoc says:

> "At least one caller evaluates completeness while already holding a Pickingorder lock —
> `MobilePickingService.rapidPickingScanSource` calls `confirmPick` … and then decides completeness"

`rapidPickingScanSource` does not call `isPickingOrderComplete` (H-1). **The conclusion is
nevertheless right, and the real instance is stronger:** `confirmPick` itself calls the helper at its
tail, holding `pickingorderRepository.findByIdForUpdate(…)` taken ~150 lines earlier, plus
`customerorderRepository.findByIdForUpdate(…)` on the current line's CO. A picking order can span
several customer orders (`finishPickingOrder` loops `Map<Long, Customerorder> processedOrders` over
"each unique customer order"), so a locking read inside the helper would take `FOR UPDATE` on *other*
lines' customer orders while already holding the Pickingorder lock — a Pickingorder-before-Customerorder
acquisition against the order `cancelOpenPickLines` documents:

> "**Lock order: Customerorder → Pickingorder → Stockunit**, matching both siblings … and
> `confirmPick` (Customerorder then Pickingorder then the stock debit)."

So: **non-locking is the correct choice**; rewrite the citation to name `confirmPick`.

*Related observation, pre-existing and out of scope:* `rapidPickingScanSource` opens with
`pickingorderRepository.findByIdForUpdate(pickingPosition.getPickingorderId())` and *then* calls
`confirmPick`, which takes the Customerorder lock — a live PO-before-CO inversion on that path today,
independent of this ticket. `processPick` carries an explicit comment acknowledging the same
inversion and pointing at the `PickingController` retry layer as the mitigation;
`rapidPickingScanSource` carries no such note. Worth a ticket, not a change here.

**L-4 — `readOnly = true` never takes effect at any call site in this diff.** Answering the brief's
question 3: `PROPAGATION_REQUIRED` joins the caller's transaction, and Spring applies `readOnly` only
when it *starts* one; with `validateExistingTransaction` at its default `false` there is no mismatch
exception either. So on the `findDemandCancelledPickLineIds` call from `getPickingOrderPositionsInfo`
(a read-write tenant transaction) the flag is silently ignored — no failure, no Hibernate
`FlushMode.MANUAL`, no benefit. It is a promise the code never keeps; harmless, but it will mislead
the next reader into thinking these reads cannot flush (they can, and do — `findAllById` on
`customerorder_position` auto-flushes a dirty `CustomerorderPosition` in `confirmPick`'s transaction).

**L-5 — a null state is treated as settled, which is the unsafe direction.**

```java
.filter(p -> p.getState() != null && p.getState() < WmsConstants.State.PICKED)
```

A line with a null state falls out of `open` and the order can be reported complete. The old code
(`noneMatch(p -> p.getState() < PICKED)`) would have NPE'd. `pickingorder_position.state` is
`integer NOT NULL` (`V2.2.00__base_v2_schema.sql`) and the entity field defaults to
`WmsConstants.State.RAW`, so this is unreachable today — but if it ever becomes live it silently
promotes an order and calls `finishPickingOrder`. The safe spelling is
`p.getState() == null || p.getState() < PICKED` (null ⇒ open ⇒ not complete).

**L-6 — the completeness test relies on id uniqueness rather than stating the invariant.**

```java
return findDemandCancelledPickLineIds(open).size() == open.size();
```

`cancelled` is a `Set<Long>` keyed on `p.getId()`. Duplicate ids, or two lines with a null id, collapse
the set and flip the answer to `false`. `findByPickingorderId` cannot produce either, so this is not a
live defect — but the invariant-shaped form costs nothing and does not depend on the caller:

```java
Set<Long> openIds = open.stream().map(PickingorderPosition::getId).collect(Collectors.toSet());
return findDemandCancelledPickLineIds(open).containsAll(openIds);
```

**L-7 — sibling sweep for the `save()`-without-reassign fix: one same-shape site, safe for a reason
worth writing down.** I swept every `pickingorderRepository.save(` in both changed files. The fixed
shape — mutate → `save()` → hand the *original* to `finishPickingOrder` — recurs exactly once, in
`releaseRegularPickingOrder` Case 2:

```java
pickingOrder.setState(WmsConstants.State.PICKED);
pickingorderRepository.save(pickingOrder);
…
pickingorderBusinessService.finishPickingOrder(pickingOrder);
```

It is **safe**, but only because `pickingOrder` there came from
`pickingorderRepository.findById(pickingOrderId)` inside the method's own
`@Transactional(tenantTransactionManager)` boundary, so it is *managed* and `save()` returns the same
instance. `releasePickingOrder`'s `pickingOrder` is a **method parameter** loaded by the controller
outside any transaction — detached — which is why only that one broke. Every other site is either
already reassigned (`resumePickingOrderIfExists` tail, `startPickingOrder` tail,
`claimPickingOrderAtomically`, `finalizePickingOrderForStart`, `confirmPick`) or does not reuse the
argument afterwards. **Recommend** one sentence on the Case 2 site saying it is safe *because the
entity is managed here* — otherwise the next reader either "fixes" it redundantly or, worse, changes
how `pickingOrder` is loaded and silently reintroduces the bug. The fix comment itself states a rule
("save() on a DETACHED entity…") without saying how to tell the two apart.

**L-8 — API widening: three new public methods, and the contracts are honoured.** Answering the
brief's question 9. `isPickingOrderComplete(List)`'s contract is "EVERY line of ONE picking order";
all five `MobilePickingService` call sites pass `pickingorderPositionRepository.findByPickingorderId(...)`
unfiltered — honoured. `findDemandCancelledPickLineIds`' contract is "any set of pick lines" — the
`getPickingOrderPositionsInfo` call passes the full order and the internal call passes the `open`
subset, both within contract. `isDemandCancelled` correctly stayed `private`. The widening is
therefore justified by the package boundary (`…service` vs `…service.mobile`), as §3.2 argued.
One nit: `isPickingOrderComplete(Long)` is public but has exactly one caller, a self-call — it could
be private (see L-1), which would also make the annotation question moot.

**L-9 — boxed-value comparison: clean.** `WmsConstants.State.PICKED/CANCELED/FINISHED` are
`public static final int`, so every `Integer state == State.CANCELED` / `state < State.PICKED` in the
new code unboxes rather than comparing references. `Set<Long>.contains(pos.getId())` and the
`Map<Long,…>` lookups use `equals`. No instance of the under-128 trap was introduced.
`Boolean.TRUE.equals(customerOrder.getMarkedforcancellation())` is null-safe (and the column is
`boolean DEFAULT false NOT NULL`, so it cannot be null anyway).

**L-10 — concurrency: stale non-locking reads are benign, but the double-finish window widened.**
Answering the brief's question 1, second half. Under READ_COMMITTED the helper only ever sees
committed CO rows, so the two stale outcomes are:
- *stale "not cancelled"* → gate says incomplete → nothing happens, the next operator action
  re-evaluates. Self-healing.
- *"cancelled" read just before another transaction un-marks the flag* → we promote and call
  `finishPickingOrder` → `cleanUpCancelledOrder`, which opens with an already-cancelled no-op guard.
  Safe.

The residual risk is not staleness but **absence of a Pickingorder lock at five of the six gates**:
only `confirmPick` holds `findByIdForUpdate` on the picking order; `resumePickingOrderIfExists`,
`releasePickingOrder`, `startPickingOrder`, `finalizePickingOrderForStart` and
`releaseRegularPickingOrder` all use plain `findById`. Two concurrent calls can both decide "complete"
and both call `finishPickingOrder`; the second gets
`FacadeException("ORDER_ALREADY_FINISHED")` or an `ObjectOptimisticLockingFailureException`, both of
which `PickingController` already catches and renders. Pre-existing shape — but the "complete" verdict
is now reachable in states where it previously was not, so the window is genuinely wider. No change
requested; noting it so it is not discovered as a regression later.

---

## Claims in the diff that I checked and found TRUE

- `finishPickingOrder`'s G4 branch does tolerate an unpicked demand-cancelled line
  (`if (pickingPosition.getState() < PICKED && isDemandCancelled(...)) { continue; }`), and the
  `if (customerOrder.getMarkedforcancellation()) { cleanUpCancelledOrder(customerOrder); }` dispatch
  does follow it. The terminal path the comments describe is real.
- The detached-`save()` explanation is mechanically accurate: `SimpleJpaRepository.save` on a
  non-new entity is `em.merge`, the detached argument keeps its old `@Version`, and re-merging it
  after an intervening auto-flush raises `ObjectOptimisticLockingFailureException`.
- `isDemandCancelled`'s revised javadoc now states the chain instead of a count, and the four triggers
  in the body match the four bullets. C1, C1b, C2 and C3 of plan §0.3 are all done.
- `releaseRegularPickingOrder`'s "`anyPicked` is deliberately left raw" note is correct: it selects
  Case 3 vs Case 4, and a cancelled line is not evidence that picking happened.
- The staged-cost claim on `isPickingOrderComplete` itself is true — the fast path loads nothing.
  (What is misstated is which branch is common *in `confirmPick`*; see M-1.)
- No caller invokes these helpers inside a loop; the two `findAllById` calls are genuinely bulk.
  No N+1 introduced.

## Plan-scope items NOT in this diff (flagging, not judging — they may belong to sibling branches)

- **C4** (plan §0.3): the ⚠ comment in `CustomerorderService.cancelOrder`'s deferred-`else`, called
  "the fullest statement of the old constraint". `CustomerorderService.java` is not in this diff.
  It is one of the four comments §0.3 designates as C1's sibling sweep.
- **P-8**: see H-1.

---

## Suggested disposition

| # | Severity | Must fix before merge? |
|---|---|---|
| H-1 `rapidPickingScanSource` not converted | High | **Yes** |
| M-1 `confirmPick` query cost + wrong comment | Medium | Comment yes; cost = decision |
| M-2 GET can cancel an order; null return ignored | Medium | **Yes** (the ignored null return, at minimum) |
| M-3 `demandCancelled` true for PICKED rows | Medium | Decide + document |
| M-4 no tests for the new logic; false coverage claim | Medium | **Yes** |
| L-1…L-10 | Low | Yes — repo policy is Lows get fixed in the same pass |
| C4 comment sweep | — | Confirm which branch owns it |
