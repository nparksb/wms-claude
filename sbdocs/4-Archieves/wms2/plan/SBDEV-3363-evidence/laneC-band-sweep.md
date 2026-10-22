# SBDEV-3363 lane C — the CANCELED-band sweep (main session, 2026-09-15)

## Claim

**"Already CANCELED" is not "beyond PACKED".** Every guard that means *"this position/order is past
the point where cancelling is still possible"* must exclude `CANCELED(800)`. The v2 codebase states
this rule correctly in two places and breaks it in two — all four within `CustomerorderService` /
`CustomerorderPositionService`.

Constants: `PACKED=650`, `PALLETIZED=670`, `FINISHED=700`, `CANCELED=800`.

## Derivation method and its blind spots

`git grep -n "State.PACKED\|>= PACKED\|> PACKED\|< PACKED\|== PACKED" origin/develop -- src/main`,
then a per-hit source read to classify the *semantic* of each guard.

Blind spots, stated because the table below is offered as closed over `src/main`:
- matches the literal token `PACKED`, so it is blind to a guard written with the numeric literal.
  **This blind spot is real, not theoretical: `git grep -n "\b650\b" origin/develop -- src/main`
  finds four state comparisons the `PACKED` grep never saw** — `"WHEN co.state = 650 THEN 1"`, four
  times in `OrderMonitorViewRepository`'s native SQL. They are **equality** tests inside reporting
  `CASE` expressions, not cancellation guards, so they are not siblings of this defect; but the
  instrument missed them, and a `>= 650` in a repository query would have been missed the same way.
  Re-checked specifically for that shape: no `>= 650` / `> 650` exists in any repository query on
  `origin/develop`. *Positive control for the numeric sweep:* the same grep for `\b800\b` returns the
  JPQL/native `c.state != 800` guards in `CustomerorderRepository`, `CustomerorderPositionRepository`
  and `CustomerorderBatchRepository`, so the numeric instrument does find state predicates when they
  exist.
- **JPQL and native queries write states as numeric literals, never as `WmsConstants.State.*`.** Any
  future sweep of a state boundary in this codebase must run both spellings; one alone is a false
  zero waiting to happen.
- **A third spelling: the static import.** `CustomerorderService` carries
  `import static net.aim_ai.wms.service.WmsConstants.State.PACKED;`, so row 2 below is written
  `position.getState() >= PACKED` — **bare**. A sweep for the qualified `State.PACKED` does not
  find it, and I confirmed this the hard way: re-running the narrower `git grep -n "State.PACKED"`
  against the newer develop HEAD returned rows 1, 3 and 4 but **silently dropped row 2**, the very
  precedent the argument rests on. So the constant has *three* spellings in this codebase — qualified,
  bare-via-static-import, and numeric — and a single-spelling sweep is a false negative in each
  direction.

## Tree the sweep was taken against

`origin/develop` moved during this session, from `4847e978` (merge of SBDEV-3332, PR #361) to
`9e294d4b` (merge of SBDEV-2778, PR #358). `4847e978` is an ancestor of `9e294d4b`, and the three
files this analysis depends on are **byte-identical across the two** — verified by comparing blob
SHAs, not by re-reading:

```
git rev-parse 4847e978:src/main/java/.../CustomerorderService.java
git rev-parse 9e294d4b:src/main/java/.../CustomerorderService.java   # same SHA
```

`CustomerorderService`, `CustomerorderPositionService` and `PickingorderBusinessService` all match.
Every quotation below therefore holds at both commits; the ticket worktree is branched off
`9e294d4b`.
- `src/main` only. Test-side pins are lane A's.
- classification of *semantic* is a judgement call, not a mechanical result. Each row carries its
  evidence so the judgement can be disputed.

## The four CO-state / CO-position-state guards

| # | Site | Guard (quoted) | Excludes CANCELED? | Verdict |
|---|---|---|---|---|
| 1 | `CustomerorderService.isShippedOrPastCancellationBoundary` | `customerOrder.getState() >= WmsConstants.State.FINISHED` `&& customerOrder.getState() != WmsConstants.State.CANCELED` | **yes** | correct — precedent |
| 2 | `CustomerorderService.cancelOrder`, inline | `position.getState() >= PACKED && position.getState() < WmsConstants.State.CANCELED` | **yes** | correct — precedent |
| 3 | `CustomerorderPositionService.canOrderPositionBeCancelled` | `if (customerOrderPosition.getState() >= WmsConstants.State.PACKED) { return false; }` | **no** | **DEFECT** — the predicate |
| 4 | `CustomerorderPositionService.cancelOrderPosition` | `if (customerOrderPosition.getState() >= WmsConstants.State.PACKED) { throw new BusinessException("order position is beyond status PACKED. can not be cancelled anymore"); }` | **no** | **DEFECT** — the action |

Rows 1 and 2 are the same rule, written twice, correctly. Rows 3 and 4 are the same rule, written
twice, wrongly. Rows 2 and 3 sit **eight lines apart in one method's execution** — `cancelOrder`
applies row 2 and then immediately consults row 3.

## Why fixing row 3 alone is WRONG — and would look like a fix

This is the finding that matters, and it contradicts the one-conjunct shape the ticket comment
proposed before the sweep.

`cancelOrder`'s happy path does not merely mark the order. It loops:

```java
LOG.debug("cancelOrder: cancelling order positions");
for (CustomerorderPosition customerOrderPosition : coPositions) {
    customerorderPositionService.cancelOrderPosition(customerOrderPosition);
}
```

So relaxing **row 3** flips a stranded order out of the deferred branch and into the happy path — where
**row 4 throws on the first position**, because that position is exactly the CANCELED(800) one that
row 3 just stopped objecting to. `cancelOrder` is `@Transactional(value = "tenantTransactionManager",
rollbackFor = {BusinessException.class, FacadeException.class})`, so the whole heal rolls back.

**Net effect of the single-conjunct fix: the two stranded orders stop being silently stuck and start
returning a misleading `BusinessException` instead.** Strictly worse than today, because it converts a
quiet data problem into a loud wrong error message.

Rows 3 and 4 must move together. That is the invariant, not the instance.

## What row 4 does once its guard is relaxed — traced for the stranded shape

`cancelOrderPosition(cop @ 800)` with the `&& < CANCELED` conjunct added, for CO 28848660
(pick line `800`, picking order `700`, `pickfromstockunit_id` null, `amountpicked = 0`):

1. Entry guard — `800 >= 650 && 800 < 800` → false. No throw.
2. Validation loop — `pickingOrder.getState() (700) >= 650 && < 700` → false;
   `pickingPosition.getState() (800) >= 650 && < 700` → false. No throw.
3. Work loop — `if (pickingPosition.getState() < WmsConstants.State.PACKED)` → `800 < 650` is false,
   so the **entire body is skipped**: no `recordCancellation` row, no `changeReservedAmount`, no
   `setState`, no `finalizePickingOrderIfTerminal`.
4. Tail — `customerOrderPosition.setState(WmsConstants.State.CANCELED)` on a position already at 800:
   a redundant write.

So for the stranded shape row 4 is a **near-no-op**: it writes no log row, moves no stock, and touches
no picking order. Its only effect is a redundant `CANCELED` re-write and the `@Version` bump that
`save()` on a managed entity implies. **It therefore does not need an early return** — the band
conjunct alone is sufficient and is the smaller diff. (This also disposes of the prior art's FP2-B H-1
duplicate-cancellation-log worry *for this path specifically*: the row is written inside the
`state < PACKED` body, which a CANCELED line never enters. It says nothing about the mixed case.)

## One lookalike, deliberately NOT in scope

`BillofladingService`, `"has already been transferred (state="` — `customerOrder.getState() != null &&
customerOrder.getState() >= WmsConstants.State.PACKED`. Open-ended, and **correctly so**. Its own
comment says why: *"It also closes a second hole — those 22 CANCELED orders could be run."* Its
question is *"is this order terminal?"*, where CANCELED is a yes. Ours is *"is it too late to
cancel?"*, where CANCELED is a no. Same literal, opposite correct answer. Leave it alone.

## Live-state facts behind the trace

Measured on `wms2-wineco-dev`, 2026-09-15:
- Section `11700009` is `TOTES_ON_CART`, **not** `RAPID_PICKING` — so both stranded orders take the
  regular arm of `canOrderPositionBeCancelled`, and the RAPID side-door in `cancelOrder` is skipped
  (it also requires `historytote != null`, and both are null).
- `pickingtote_id` is null on both, so `cancelOrder`'s tote-teardown blocks are skipped.
- Each stranded picking order holds **exactly one** position, so the repair cannot disturb a co-tenant
  order sharing the PO.

## Consequence for the plan

The AC-1 fix is **two conjuncts, one invariant**, not one conjunct:

```java
// CustomerorderPositionService.canOrderPositionBeCancelled
- if (customerOrderPosition.getState() >= WmsConstants.State.PACKED) {
+ if (customerOrderPosition.getState() >= WmsConstants.State.PACKED
+         && customerOrderPosition.getState() < WmsConstants.State.CANCELED) {

// CustomerorderPositionService.cancelOrderPosition
- if (customerOrderPosition.getState() >= WmsConstants.State.PACKED) {
+ if (customerOrderPosition.getState() >= WmsConstants.State.PACKED
+         && customerOrderPosition.getState() < WmsConstants.State.CANCELED) {
```

A test that only exercises the predicate will pass on the broken pair. **The acceptance test must run
`cancelOrder` end to end against the stranded shape**, not call `canOrderPositionBeCancelled` directly
— that is the mutation-check that distinguishes the two-site fix from the one-site one.
