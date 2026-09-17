# SBDEV-3363 Lane A — Option 4 blast radius, argued adversarially

- Base: `origin/develop` @ `9e294d4b7fa1a1ce41eca69a6987a5fffa0f2bcc` (the brief said HEAD `4847e978`; my `git rev-parse origin/develop` in `/home/nampark/dev/wms-claude/v2/wms2-api` returned `9e294d4b`. **Uncertainty: the brief's SHA and mine disagree.** Everything below is read from `9e294d4b`. If `4847e978` is a different fetch, re-run §1's greps before trusting the counts.)
- All reads via `git show origin/develop:<path>` / `git grep ... origin/develop`. Working tree ignored.

---

## 0. HEADLINE — Option 4 as scoped does not fix the stranded orders. It converts a silent strand into an HTTP 400.

**Confidence: HIGH.** This is the single most important finding in this lane and it falsifies the premise of the whole question.

The brief's established context says the true-branch "reaches `cleanUpCancelledOrder`". **It does not.** In `CustomerorderService.cancelOrder`, `cleanUpCancelledOrder` is on the **`else`** arm, and only under a further condition:

```java
} else {
    LOG.debug("cancelOrder: order can not be cancelled");
    if (customerOrder.getPickingconfirmationsent()) {
        cleanUpCancelledOrder(customerOrder);
    } else {
        customerOrder.setMarkedforcancellation(true);
```
(`src/main/java/net/aim_ai/wms/service/CustomerorderService.java`)

So Option 4 moves the two stranded orders **out** of the `cleanUpCancelledOrder` neighbourhood entirely and **into** the `orderCanBeCancelled == true` branch. That branch does this:

```java
LOG.debug("cancelOrder: cancelling order positions");
for (CustomerorderPosition customerOrderPosition : coPositions) {
    customerorderPositionService.cancelOrderPosition(customerOrderPosition);
}
```

And `cancelOrderPosition` opens with the **third copy of the same `>= PACKED` predicate**, which Option 4 does not touch:

```java
public void cancelOrderPosition(CustomerorderPosition customerOrderPosition) throws BusinessException, FacadeException {

    if (customerOrderPosition.getState() >= WmsConstants.State.PACKED) {
        throw new BusinessException("order position is beyond status PACKED. can not be cancelled anymore");
    }
```
(`src/main/java/net/aim_ai/wms/service/CustomerorderPositionService.java`)

The stranded orders' CO positions are all at `CANCELED(800)`, and `800 >= 650`. So on the very first iteration of that loop, `cancelOrderPosition` throws `BusinessException`. `cancelOrder` is `@Transactional(value = "tenantTransactionManager", rollbackFor = {BusinessException.class, FacadeException.class})` and `cancelOrderPosition` carries the same annotation with default `REQUIRED` propagation — so it joins the caller's transaction and the throw rolls the whole thing back.

**Net effect of Option 4 alone on orders 28848660 / 28857575:** the order is *still* not cancelled, *still* at state 200, and OMS now receives a 400 `WRONG_STATE` instead of a silent accept. Strictly worse for OMS's retry loop (it converts a silent no-op into a visible rejection — arguably better for observability, definitely not a fix).

> **There are THREE copies of the `>= PACKED` predicate over a CustomerorderPosition state, not two.** Derived by `git grep -n "getState() >= WmsConstants.State.PACKED\|getState() >= PACKED" origin/develop -- src/main`. Sites: `cancelOrder`'s inline guard 1 (half-open, `< CANCELED`), `canOrderPositionBeCancelled`'s entry guard (open-ended), `cancelOrderPosition`'s entry throw (open-ended). **Blind spot of that grep:** it matches only the literal receiver-free form `getState() >= ...`; a comparison written as `PACKED <= x.getState()`, via a local `int state` variable, or through a helper predicate would be missed. See §1.4 for the positive control.

**Therefore: any viable Option 4 must be a two-site change.** A one-site change to `canOrderPositionBeCancelled` is not a smaller blast radius, it is a broken one.

---
## 1. Call sites — "exactly one production call site" is CORRECT for this method name, but the framing is wrong

**Verdict: the brief's claim holds. Confidence: HIGH for Java call sites, MEDIUM for the HTTP surface.**

### 1.1 Method used, and what it misses

I ran three instruments, not one:

1. `git grep -n "canOrderPositionBeCancelled" origin/develop -- src/main` → **one** non-comment call: `CustomerorderService.java:805`, `if (!customerorderPositionService.canOrderPositionBeCancelled(customerOrderPosition)) {`. (Two other hits are the declaration itself and a `LOG.debug` string; one more is a *comment* in `PickingorderBusinessService` — see §1.3.)
2. `git grep -n "CustomerorderPositionService\|customerorderPositionService" origin/develop -- src/main` — the **type**, not the method name. This is the instrument that would catch a call made through a differently-named interface method or an injected supertype. Result: the type is injected in exactly one place, `CustomerorderService` (field `private final CustomerorderPositionService customerorderPositionService;`, constructor param, two uses: `canOrderPositionBeCancelled` at :805 and `cancelOrderPosition` at :853). Every other hit in `src/main` is a javadoc/comment mention in `CancellationReversalService`, `PickingorderBusinessService`, `StockunitService`, `MobilePickingService`.
3. `git grep -nE "PreAuthorize|PostAuthorize|@Value\(\"#\{|getMethod\(|getDeclaredMethod\(|Class\.forName"` over both files → **zero hits**. No SpEL, no reflection.

**Blind spots I can name:**

- **Interface/supertype dispatch: ruled OUT, not merely unsearched.** `public class CustomerorderPositionService {` — the declaration has no `implements` and no `extends`. So there is no interface method of a different name that could route here. This is the check that a literal-name grep alone does not make, and it passes.
- **Spring Data REST: structurally impossible here.** SDR exports `@RepositoryRestResource` *repositories*, not `@Service` beans. `CustomerorderPositionService` is `@Service`, so no HTTP route reaches it. (Contrast the real SDR exposure noted in `cleanUpCancelledOrder`'s own comment: `CustomerorderRepository` *is* `@RepositoryRestResource(path = "customerorder")`, which is a writer of `markedforcancellation` over `PATCH /v3/customerorder/{id}` — that is a blind spot for *that* field, and it is **not** one for this method.)
- **Untested blind spot — still open:** a Spring `@Async`/event listener or an AOP advice naming the method by string. My instrument #3 covers `Class.forName`/`getDeclaredMethod`/SpEL literals; it does not cover a method named in a `.properties`/`.yml` or an XML bean file. I grepped `src/main/resources` and `src/test/resources` for the method name: **zero hits**. Positive control for that scan: the same grep over `src/main` returns 11 hits, so the pattern and the path syntax work — the zero is a true zero, not a broken instrument.
- **`cancelOrderPosition` is the *second* consumer of the same predicate and the grep for `canOrderPositionBeCancelled` cannot see it.** This is the miss that matters (§0), and it is the answer to "what does a literal method-name grep miss": not a hidden *caller*, a hidden *duplicate of the rule*.

### 1.2 The src/test sweep — how many tests pin `>= PACKED`, and would any go red?

**Answer: exactly one test pins the helper's entry guard, and it would NOT go red. Zero tests go red from Option 4's helper change. Confidence: HIGH.**

`CustomerorderPositionServiceUnitTest` is the only class that exercises the **real** helper. Its `>= PACKED` pin is:

```java
@DisplayName("should return false when position is packed or beyond")
void shouldReturnFalseWhenPositionPackedOrBeyond() throws ... {
    testPosition.setState(WmsConstants.State.PACKED);
    ...
    assertThat(result).isFalse();
}
```

The fixture is `PACKED(650)`. Under Option 4 the predicate becomes `650 >= 650 && 650 < 800` → still `true` → still returns `false`. **Green.** The DisplayName says "or beyond" but no fixture in the class ever sets a state above `PACKED` for this assertion — the "or beyond" half is **vacuous**. That is the single most important coverage fact in this lane: *the behaviour Option 4 changes is asserted by nothing.*

The sibling pin on the second site is the same shape:
```java
@DisplayName("should throw exception when position is packed or beyond")
void shouldThrowExceptionWhenPositionPackedOrBeyond() ... {
    testPosition.setState(WmsConstants.State.PACKED);
```
Also `PACKED`, also vacuous above 650, also stays green.

`CustomerorderServiceUnitTest` has **20** `when(customerorderPositionService.canOrderPositionBeCancelled(position)).thenReturn(...)` stubs (count from `git grep -c`), but the collaborator is declared

```java
@Mock
private CustomerorderPositionService customerorderPositionService;
```

so **every one of those 20 is insensitive to the helper's body.** They will not go red, and — more to the point — they cannot go red, which means the existing `CustomerorderService` suite provides **zero** protection for this change. Derived by reading the `@Mock` declaration; blind spot: if a test used `@Spy` or `Mockito.CALLS_REAL_METHODS` it would be sensitive — I checked, neither appears on this field.

**Implication for the TDD gate:** the failing test must be new, and it must live in `CustomerorderPositionServiceUnitTest` (real helper) plus an end-to-end one that uses a **real** `CustomerorderPositionService`, because a mocked one cannot observe the §0 throw at all. Mutation-check it by setting the fixture to `CANCELED(800)` on the *pre-fix* file and confirming red.

### 1.3 Contrary evidence I went looking for and DID find — the bug is already documented in-tree

`PickingorderBusinessService.cleanUpCancelledOrder` carries a comment that describes SBDEV-3363's exact two orders, written before this ticket:

```
//   · flagged, state < 800, picking order >= FINISHED          -> STRANDED (2): every CO
//     position already CANCELED, so canOrderPositionBeCancelled is false at `>= PACKED` and
//     cancel #2 only re-sets the flag, while finishPickingOrder throws. No terminal path in
//     either direction. This is the hazard CustomerorderService's deferred branch documents
//     as theoretical — it has materialised twice, on wms2-wineco-dev, stuck since 2026-02-06.
```

This corroborates the diagnosis independently of my own trace, and it also **confirms §0 from the other direction**: the author who wrote that comment placed the strand in `cleanUpCancelledOrder`'s census as a row that `cleanUpCancelledOrder` *cannot* drain, not as a row it would drain if the guard were relaxed.

---

## 2. What else changes — the question's premise corrected, then answered both ways

The brief asks me to "walk `cancelOrder` forward from the `orderCanBeCancelled == true` branch … It reaches `cleanUpCancelledOrder`." **It does not** (§0). I answer for the branch it actually reaches, then for `cleanUpCancelledOrder` separately, since that is the path the affected orders take *today*.

### 2.1 The branch Option 4 actually routes them into (`orderCanBeCancelled == true`)

Walking it for an order whose CO positions are all `CANCELED(800)`, **assuming both `>= PACKED` sites are fixed** (otherwise it throws at the first position and nothing below runs):

| Step | Behaviour for an all-CANCELED order | Verdict |
|---|---|---|
| `clientRepository.findById` + section lookup | ordinary reads | safe |
| RAPID block (`section…RAPID_PICKING && state == ASSIGNED && historytote != null`) | not entered on any measured tenant — see §4 | safe, but see §4's IOOBE |
| `for (…) cancelOrderPosition(pos)` | **entry throw unless fixed.** Once fixed: the inner loop is `if (pickingPosition.getState() < WmsConstants.State.PACKED)`, and CANCELED lines are 800, so the body is **skipped entirely** — no `recordCancellation`, no `changeReservedAmount`, no `pickfromstockunitId` deref. Tail `setState(CANCELED)` is an idempotent re-write. | **No double-cancel, no duplicate log row, no stock movement** |
| tote teardown (`if (customerOrder.getPickingtoteId() != null)`) | `pickingtote_id` is NULL on all three affected orders (measured) → block skipped whole | safe |
| `setState(CANCELED)`, `setMarkedforcancellation(false)`, transferlane clear, `save` | the intended outcome | **this is the fix** |
| `finalizeBatchIfComplete` | `findById(batchId).orElse(null)` → null-safe; `orders.isEmpty()` → early return; then `allMatch(state >= FINISHED)` gated. Pure read-then-conditional-write, no throw path. | safe |
| outbox `ORDER_BATCH_CANCELLED_FROM_WMS` | key `CANCELLED_IDEMPOTENCY_KEY_PREFIX + id`. **Measured:** `SELECT … FROM outbox_message WHERE aggregate_id IN (28848660,28857575,585000351)` returns **zero rows** on wms2-wineco-dev. The key is free; the UNIQUE constraint cannot fire. | safe **for these three orders** |

**Answering the brief's four specific questions, for this branch:**
- *Does it double-cancel anything?* **No.** Confidence HIGH — `cancelOrderPosition`'s pick-line loop is bounded `< PACKED`, which excludes 800.
- *Does `cancelOpenPickLines` write a duplicate `customerorder_cancellation_log` row (the FP2-B H-1 defect)?* **`cancelOpenPickLines` is not on this branch at all** — it is only called from `cleanUpCancelledOrder`. The FP2-B H-1 defect **cannot recur here**, and the structural reason is worth stating because it is the opposite of the deferred path: in `cancelOrderPosition` the `recordCancellation` call sits **inside** the `state < PACKED` guard, whereas in `cancelOpenPickLines` it sits **above** the `state < PICKED` bound. That placement difference is exactly what makes one re-entrant-safe and the other not.
- *Does it move stock for a line with `amountpicked = 0` and `pickfromstockunitId` already null?* **No** — it never enters the body for a CANCELED line, so it never reaches the `if (pickingPosition.getPickfromstockunitId() != null)` test.
- *Does `finalizeBatchIfComplete` behave / is the idempotency key safe?* Yes and yes, per the table.

### 2.2 The path they take today (`cleanUpCancelledOrder`) — and the regression Option 4 creates on it

**This is the strongest measured finding in the lane and it is a reason to be careful, not a reason to stop.**

The census of the newly-reachable input class (orders at `state < 800` carrying ≥1 CO position at 800) across all four reachable v2 tenant DBs, run 2026-09-15:

| DB | newly-reachable orders | shape |
|---|---|---|
| wms2-wineco-dev | **3** | all ALL-CANCELLED, all `co_state = 200` |
| wms2-hydra (PRD) | 0 | — |
| c1wh-shipitez-uat | 0 | — |
| wsl-wineco-uat | 0 | — |

**Positive control for the three zeros** (required — a broken instrument and a true zero look identical): the same tables on those DBs are *not* empty. `customerorder_position` rows at state 800: hydra 18 (8 distinct orders), c1wh-shipitez-uat 3504 (1006 orders), wsl-wineco-uat 52674 (11532 orders). Grouping those orders by `customerorder.state` returns **exactly one bucket, `co_state = 800`, on all three** — i.e. a cancelled position occurs only under an already-cancelled order. The zeros are true zeros.

The three wineco-dev orders:

| id | number | co_state | mfc | pcs | pos states | pick-line states | picking-order states | pickingtote_id | canc-log rows |
|---|---|---|---|---|---|---|---|---|---|
| 28848660 | 051483-000001 | 200 | **true** | false | 800 | 800 | 700 | NULL | 0 |
| 28857575 | 051488-000001 | 200 | **true** | false | 800 | 800 | 700 | NULL | 0 |
| **585000351** | 024277-000001 | 200 | false | **true** | 800 | **600** | 700 | NULL | 0 |

The first two are SBDEV-3363's stranded pair. **The third is new and it is a regression risk.** Because `pickingconfirmationsent = true`, order 585000351 takes the `cleanUpCancelledOrder` arm *today*, and that arm **works for it**: `cleanUpCancelledOrder`'s entry guard is `if (customerOrder.getState() != null && customerOrder.getState() == WmsConstants.State.CANCELED)` — the order is at 200, so it proceeds, sets CANCELED, cancels positions, and emits the outbox. It is not stranded; it is simply un-retried.

**Option 4 reroutes it to the true branch, where it hits the §0 throw.** So a naive Option 4 converts one currently-cancellable order into a permanently-400ing one. Any acceptance criterion for this ticket must cover `pickingconfirmationsent = true` as well as `false`, or it will grade the fix on two of the three affected rows.

**Secondary loss, and I checked how bad it is:** 585000351's pick line is at `PICKED(600)`. Today `cleanUpCancelledOrder` -> `cancelOpenPickLines` writes it a `recordCancellation` row (`reversal_required = state >= PICKED` -> true). Under the caller-side filter recommended in §5, the position is skipped and that row is never written. I measured whether the loss matters: the line has `pickfromstockunit_id = NULL`, and its `picktounitload_id` points at a `pickingorder_unitload` already at state 800 with `unitload_id = NULL` and **0 stock units on it**. Per `cleanUpCancelledOrder`'s own SBDEV-3316 comment, `resolvePicktoStockunitId` can only make the hop to the stock "while the link is still populated" — it is not — so the row would carry `picktostockunit_id = NULL`, and `completeReversal` "now refuses such a row". **The lost row would be un-actionable.** Cost: cosmetic. Confidence MEDIUM (I verified the link state directly; I did not read `completeReversal`).

---

## 3. The MIXED case — dug hardest, and the honest answer is that it is unreachable in the field

**Verdict: MIXED is a real logical hazard and a measured non-event. Confidence HIGH on the measurement, MEDIUM on the reasoning about the worst input.**

The measurement above is the answer to "is the MIXED case the real risk": across all four reachable v2 tenant DBs there are **zero** MIXED orders — zero orders at `state < 800` with both a CANCELED position and an open one. Every one of the 12,546 orders carrying a cancelled position across the estate is itself already at 800. The three newly-reachable orders are all ALL-CANCELLED (`pos_open = 0`).

Blind spot of that measurement, stated plainly: it is a **point-in-time census, not a proof of unreachability**. A MIXED order is produced by `cancelOrderPosition` being called on one position of a multi-position order — which is a live, exported operation — so the shape is *constructible* even though nothing is sitting in it right now. It is also a census of four DBs; the tenant list in `cleanUpCancelledOrder`'s own comment names **six** ("c1wh-shipitez-uat · nywh-hydra-uat · nywh-shipitez-uat · wms2-hydra PRD · wms2-wineco-dev · wsl-wineco-uat"), and I queried four. **nywh-hydra-uat and nywh-shipitez-uat were not probed.** That is the same 4-of-6 sampling error that comment records as having under-counted a previous census by 8.5x. Treat my zeros as covering four of six.

**The worst input I can construct**, and what happens to it after a correct two-site Option 4:

> Order O at `ASSIGNED(200)`, positions P1 = `CANCELED(800)` (already cancelled individually, its pick lines at 800) and P2 = `PICKED(600)` with its pick line at 600, `pickfromstockunit_id` NULL (consumed at pick), stock physically in the tote, picking order at `FINISHED(700)`.

- Guard 1: `anyMatch(state >= 650 && state < 800)` — P1 is 800, P2 is 600. **Neither matches; guard 1 already passes this order today.** The brief is right that guard 1 lets such an order through; it is guard 2 that stops it.
- Guard 2 after Option 4: P1 no longer blocks. P2 → `600 < 650`, so no early return; its pick line at 600 and picking order at 700 clear both `[650,700)` tests → **true**. Order proceeds.
- `cancelOrderPosition(P2)`: `600 < 650` passes the entry throw. Inner loop: `600 < 650` → **enters**. Writes `recordCancellation` with `reversal_required = true`. `pickfromstockunitId` is NULL → no unreserve. Flips the line to CANCELED and finalizes the picking order.
- **The hazard:** the goods for P2 are in the tote, and the line that attributed them is now CANCELED. This is precisely the condition `cancelOpenPickLines`'s javadoc refuses to create — *"A PICKED line's stock is already in the tote … and flipping it to CANCELED would make the tote's contents unattributable"*, which is why that method is *"Bounded to `state < PICKED`"*. **`cancelOrderPosition` has no such bound** — its bound is `< PACKED`, which includes PICKED(600).
- Mitigation that exists: the true branch's SBDEV-3339 tote teardown (`sendToClearing` + clearing `entityLock`) runs afterwards and sends the tote to clearing, which is the designed disposition.

**Is this Option 4's fault?** **No — and this is the key distinction.** An order with *no* cancelled positions and a PICKED one already reaches `cancelOrderPosition` today. The `< PACKED` vs `< PICKED` divergence between the two cancellation loops is **pre-existing** and independent of this ticket. What Option 4 newly admits is only the class "orders containing ≥1 position at CANCELED". So the MIXED case does not *create* the divergence; it widens the door to it by one input class — an input class with zero members on four of six tenants.

**Recommendation for the plan:** do not try to fix the `< PACKED`/`< PICKED` divergence inside SBDEV-3363. Note it, propose it separately (it is its own ticket and plausibly its own tier), and scope this ticket to the CANCELED-position question. Widening scope to the PICKED question is how a T2 becomes a T3.

---

## 4. The RAPID_PICKING arm — a real new throw path, measured dead

**Verdict: Option 4 does make two new throws reachable in the RAPID arm, and both are unreachable in the field today. Confidence HIGH on the code path, HIGH on the measurement, MEDIUM on durability.**

The brief is right that `canOrderPositionBeCancelled`'s early return sits **above** the RAPID/regular split:

```java
if (customerOrderPosition.getState() >= WmsConstants.State.PACKED) {
    return false;
}
List<PickingorderPosition> poPositions = pickingorderPositionRepository.findByCustomerorderpositionId(...);
...
if (section != null && section.getSectionpickingtype().equals(WmsConstants.SectionPickingType.RAPID_PICKING) && ...) {
```

so relaxing it lets a CANCELED position reach both arms.

**Does the RAPID loop throw?** It can:
```java
Pickingorder pickingOrder = pickingorderRepository.findById(pickingPosition.getPickingorderId()).orElseThrow(() -> new EntityNotFoundException("PickingOrder", pickingPosition.getPickingorderId()));
```
`EntityNotFoundException` is a `RuntimeException`, not a `BusinessException` — so it escapes `OrderRestController` as a generic error rather than the `WRONG_STATE` 400 that OMS is built to handle. **But this same `orElseThrow` is in the regular arm too**, on the identical line, so it is not RAPID-specific.

**Does it return a different answer than intended?** For the stranded shape (pick line 800, picking order 700): `pickingOrderState < STARTED`? no. `== STARTED`? no. `< FINISHED`? `700 < 700` false → loop falls through → **returns true**, same as the regular arm. No divergence for this input.

**The genuinely new risk is in `cancelOrder`'s own RAPID block, not the helper's:**
```java
CustomerorderPosition customerOrderPosition = coPositions.get(0);
List<PickingorderPosition> pickingPositions = pickingorderPositionRepository.findByCustomerorderpositionId(customerOrderPosition.getId());
Pickingorder pickingOrder = pickingorderRepository.findById(pickingPositions.get(0).getPickingorderId())...
```
`pickingPositions.get(0)` on an empty list is an **`IndexOutOfBoundsException`**. Newly reachable, because an order with a CANCELED first position never got past guard 2 before. Gated on `section RAPID_PICKING && customerOrder.getState() == ASSIGNED && customerOrder.getHistorytote() != null` — and note order 585000351 satisfies **two of those three** (`state = 200 = ASSIGNED`, `historytote = 'T-0000'`).

**Measured exposure:** `sectionpickingtype` across the four DBs — hydra PRD: 2 sections, both `TOTES_ON_CART`, **no RAPID_PICKING section exists**; c1wh-shipitez-uat: 2, both `TOTES_ON_CART`; wms2-wineco-dev: 14 `TOTES_ON_CART` + 1 `RAPID_PICKING` (`test_section`); wsl-wineco-uat: 26 `TOTES_ON_CART` + 1 `RAPID_PICKING` (`test_section`). Both RAPID sections carry **0 customer orders** (`orders_total = 0` via `client.section_id`). All three affected orders sit on `test_section_cart`, `TOTES_ON_CART`.

So: **the RAPID arm is dead across all four measured tenants, and the section type does not exist at all on production.** Blind spots: the two unprobed tenants (§3), and the fact that a section's `sectionpickingtype` is data — an operator flipping `test_section` to live, or a client being re-pointed, re-arms this without a code change. Cheap insurance: a `pickingPositions.isEmpty()` guard, one line, no behaviour change on any live shape.

---

## 5. Placement — recommendation

Three candidates:

**A. Relax the helper's guard (`&& state < CANCELED` in `canOrderPositionBeCancelled`).** Rejected as stated. It is not one site — §0 shows it must be paired with `cancelOrderPosition`'s entry throw or the fix throws a 400 instead of cancelling. And it leaves the codebase asserting two contradictory things about the same predicate in the same class, eight lines apart: "a CANCELED position does not block cancellation" and "a CANCELED position cannot be cancelled." That contradiction *is* the bug; option A relocates it rather than removing it.

**B. `continue` in the caller loop (the prior art's FP2-A H-1 form).** Better — it keeps the helper's contract intact. But `cancelOrder` has **two** loops over `coPositions` (the guard loop at `if (!customerorderPositionService.canOrderPositionBeCancelled(...))` and the cancel loop at `customerorderPositionService.cancelOrderPosition(...)`), and a `continue` in one without the other reproduces the §0 throw exactly. Two edits that must stay in sync is the same failure mode one tier down.

**C. Filter once in the caller, drive both loops off the filtered list. — RECOMMENDED.**

Derive a single local from `coPositions` holding the positions that are *not* already CANCELED, and use it for both the `canOrderPositionBeCancelled` loop and the `cancelOrderPosition` loop.

Why this one:

- **It is one edit point, so the two loops cannot drift.** This ticket exists because one predicate was copied to three places and two of them disagree; a fix whose correctness depends on two edits staying in sync is the wrong shape of fix for this particular bug.
- **It states the right invariant, and states it once:** *an already-CANCELED position takes no part in the cancellation decision — it neither blocks the cancel nor needs cancelling.* That is a single sentence covering both directions. Option A can only express half of it (the blocking half) and has to express the other half separately in another method.
- **It leaves both helpers' contracts true and unweakened.** `canOrderPositionBeCancelled` and `cancelOrderPosition` go on meaning "a position at or beyond PACKED is past the point of cancellation" — which is correct, and which other callers (present or future) can keep relying on. The conceptual error being corrected is not in those helpers; it is that `CANCELED(800)` was ever placed *above* `PACKED` on a scale that models pipeline progress. CANCELED is not further along the pipeline, it is **off** it. A caller-side filter says that in the one place that knows it.
- **Smaller blast radius than A by construction**: A changes a `public` method's return value for an input class; C changes only which elements one method iterates.

Two implementation traps for whoever writes it, both concrete:

1. **Do not reassign `coPositions`.** The OMS outbox payload is built from it further down (`coPositions.stream().map(position -> { … opDto.setUniqueId(position.getExternalid()); … })`), and OMS expects **every** position of the order, not just the cancellable ones. The filter must be a separate local. Reassigning is the obvious shortcut and it silently truncates the cancel notification.
2. **Guard the RAPID block's `pickingPositions.get(0)`** (§4) — one line, currently dead, newly reachable.

And one acceptance-criteria requirement that falls out of §2.2: **grade the fix on all three wineco-dev orders, not two.** 28848660 and 28857575 (`pcs = false`) and 585000351 (`pcs = true`) take different arms today, and a fix validated only on the stranded pair will not notice that it rerouted the third off a working path.

---

## Ranked hypotheses

| # | Hypothesis | Confidence | Evidence FOR | Evidence AGAINST |
|---|---|---|---|---|
| 1 | **Option 4 confined to `canOrderPositionBeCancelled` does not fix the bug; it throws a `BusinessException` from `cancelOrderPosition` and rolls back.** | **HIGH** | Three copies of the predicate found by a named grep; `cancelOrderPosition`'s entry throw is open-ended; the true branch calls it for every position; `rollbackFor` covers `BusinessException` | None found. The only way out is if the true branch skipped CANCELED positions — it does not |
| 2 | The true branch does **not** reach `cleanUpCancelledOrder`; that method is on the `else` arm under `pickingconfirmationsent` | **HIGH** | Quoted control flow | None |
| 3 | The newly-reachable input class is 3 orders on one dev DB and empty on the other three probed tenants | **HIGH** (for 4 of 6 tenants) | Census + positive control showing the instrument reaches 12,546 orders with cancelled positions | Two tenants unprobed; the shape is constructible via single-position cancel even where it is currently absent |
| 4 | Option 4 regresses order 585000351 from a working `cleanUpCancelledOrder` path to a 400 | **HIGH** | `pcs = true`, `co_state = 200` ≠ 800 so the entry guard passes; measured | Depends on hypothesis 1; a two-site fix removes the 400 but still reroutes the order |
| 5 | The MIXED case is a genuine hazard but adds no *new* defect — the `< PACKED`/`< PICKED` divergence is pre-existing | **MEDIUM** | Orders with a PICKED position and no CANCELED one already reach `cancelOrderPosition` today | I did not trace every producer of a MIXED order; "pre-existing" rests on that reasoning, not on a census of the divergence's victims |
| 6 | The RAPID arm is dead across all four probed tenants; the new `IndexOutOfBoundsException` is theoretical | **MEDIUM-HIGH** | 0 orders in either RAPID section; no RAPID section on PRD at all | `sectionpickingtype` is data, not code — it can be flipped without a deploy |
| 7 | Zero existing tests go red; the behaviour Option 4 changes is asserted by nothing | **HIGH** | The one pin uses a `PACKED(650)` fixture that stays false under the new predicate; the 20 caller-side stubs are on a `@Mock` | A test I did not read could construct a CANCELED position indirectly — I grepped the method name across all of `src/test`, which would catch any direct call |

## What I could not determine

- Whether `4847e978` (the brief's SHA) differs from `9e294d4b` (what I read).
- nywh-hydra-uat and nywh-shipitez-uat were not probed; every "zero" above covers four of six tenants.
- Whether `completeReversal` in fact refuses a `picktostockunit_id = NULL` row — I took that from `cleanUpCancelledOrder`'s comment, not from reading the method.
- Whether any *OMS-side* behaviour depends on receiving `WRONG_STATE` for these orders today. Option 4 changes what OMS gets back; I traced only the WMS side.

---

# ADDENDUM — main session, 2026-09-15. Two of lane A's four open items, closed.

Appended by the orchestrating session, not by the tracer lane. Both items were listed above under
*"What I could not determine"*.

## 1. The base-revision disagreement — RESOLVED, and it changes nothing

The brief's `4847e978` and lane A's `9e294d4b` are **both real**: `origin/develop` advanced *during*
this session, from the SBDEV-3332 merge (PR #361) to the SBDEV-2778 merge (PR #358). `4847e978` is an
ancestor of `9e294d4b`. Crucially, the three files this ticket depends on are **byte-identical across
the two commits** — compared by blob SHA, not by re-reading:

| file | `4847e978` vs `9e294d4b` |
|---|---|
| `CustomerorderService.java` | IDENTICAL |
| `CustomerorderPositionService.java` | IDENTICAL |
| `PickingorderBusinessService.java` | IDENTICAL |

So every quotation and count in this report holds at both revisions. The ticket worktree is branched
off `9e294d4b`.

## 2. The 4-of-6 tenant gap — CLOSED. The census is now 6 of 6, and lane A's zeros survive.

Lane A flagged that `nywh-hydra-uat` and `nywh-shipitez-uat` were unprobed, and correctly noted that
the same 4-of-6 sampling error once under-counted a census by 8.5x. Both are now probed with the
identical query and a positive control:

| DB | newly-reachable orders | control: cancelled CO positions | control: orders owning one |
|---|---|---|---|
| wms2-wineco-dev | **3** | — | — |
| wms2-hydra (PRD) | 0 | 18 | 8 |
| c1wh-shipitez-uat | 0 | 3,504 | 1,006 |
| wsl-wineco-uat | 0 | 52,674 | 11,532 |
| **nywh-hydra-uat** | **0** | **128** | **81** |
| **nywh-shipitez-uat** | **0** | **29** | **6** |

Both new controls are healthy and non-zero, so both new zeros are true zeros. **The newly-reachable
input class is 3 orders estate-wide, all on wms2-wineco-dev, and none on production.**

## 3. Lane A's third order is CONFIRMED — and it is the finding that matters most here

Independently re-measured on wms2-wineco-dev:

| id | number | co_state | mfc | pcs | pos | cancelled | open | pick-line states | historytote |
|---|---|---|---|---|---|---|---|---|---|
| 28848660 | 051483-000001 | 200 | **true** | false | 1 | 1 | 0 | 800 | NULL |
| 28857575 | 051488-000001 | 200 | **true** | false | 1 | 1 | 0 | 800 | NULL |
| 585000351 | 024277-000001 | 200 | **false** | **true** | 1 | 1 | 0 | **600** | 'T-0000' |

**Why the main session's own census missed 585000351, and why that is the methodological lesson:** the
session filtered on `markedforcancellation IS TRUE`, because the ticket frames the problem around the
flag. Order 585000351 **carries no flag** — it is reachable through the same guard by a different arm.
Lane A filtered on the *structural* condition instead (`co.state <> 800 AND EXISTS (a CO position at
800)`), which is the condition the guard actually tests, and found an order the flag-shaped filter
could not see.

**The blast radius of a change is defined by the predicate you are changing, not by the symptom that
led you to it.** Filtering by the symptom under-reports it. This is the same class of error as
counting roles instead of users.

Also note 585000351 satisfies **two of the three** conditions on `cancelOrder`'s RAPID block
(`state == ASSIGNED`, `historytote != null`); only its section type (`TOTES_ON_CART`) keeps it out.
That is the margin behind lane A's §4 `pickingPositions.get(0)` IOOBE, and it is one data edit wide.

## 4. Still open from lane A's list

- Whether `completeReversal` actually refuses a `picktostockunit_id = NULL` row (taken from a comment,
  not from reading the method).
- Whether any OMS-side behaviour depends on receiving `WRONG_STATE` for these orders today.

Both belong in the plan's §10 Open Questions.
