# SBDEV-3363 Fix A — Lane F code review

- **Worktree:** `/home/nampark/dev/wms-claude/.claude/worktrees/wms2-api/SBDEV-3363` (the only tree read)
- **Branch/commit:** `bugfix/SBDEV-3363-deferred-cancel-terminal-path` @ `2a80ed7f`, base `origin/develop` `9e294d4b`
- **Files under review:**
  - `src/main/java/net/aim_ai/wms/service/CustomerorderService.java`
  - `src/test/java/net/aim_ai/wms/integration/CancelOrderAlreadyCancelledPositionIntegrationTest.java`
- **Plan sections read:** §0.1, §2.1, §3.1, §3.1.1
- **Verdict:** the **fix is correct**. Every defect below is in a **comment or a test fixture**, not in the
  production logic. Two Mediums are factually wrong claims in the new comments; two are test fixtures that do
  not model what their javadoc says; one is a coverage gap on the new guard.

---

## Summary table

| # | Sev | Where | One line |
|---|-----|-------|----------|
| M1 | Medium | `CustomerorderService.java` (isEmpty guard comment) | "escapes … as a generic 500" — it is a **400** |
| M2 | Medium | `CustomerorderService.java` (isEmpty guard comment) | "an empty `pickingPositions` could not arrive here" — it **could**, pre-fix, via a different shape |
| M3 | Medium | test fixture 1 | fixture seeds `markedforcancellation = false`; the two live stranded orders carry **true** → the flag assertion is **vacuous** |
| M4 | Medium | test fixture 2 javadoc | describes the **pre-fix** route ("reaches `cleanUpCancelledOrder`"); post-fix it takes the true branch — contradicts the plan's own §3.1.1 |
| M5 | Medium | test class | the new `isEmpty()` guard has **zero** coverage — no fixture builds a RAPID_PICKING section |
| L1 | Low | `PickingorderBusinessService.java` ~line 644 | sibling comment's STRANDED bucket ("no terminal path in either direction") is made false by this commit |
| L2 | Low | `CustomerorderService.java` RAPID side-door | `coPositions.get(0)` stays unguarded and unordered, and can now be the CANCELED position |
| L3 | Low | test class | nothing asserts the OMS outbox row, the observable the whole ticket exists to produce |
| L4 | Low | `CustomerorderService.java` | comment header "guard the get(0)" is ambiguous about **which** `get(0)` |
| L5 | Low | test fixture 2 | `pickingconfirmationsent = true` is presented as load-bearing and is now inert |

---

## Clean verdicts on the claims I was asked to probe

These were probed and **hold**. Recording them explicitly.

### C1 — The boxed-`Integer` comparison is a genuine numeric comparison. VERIFIED by bytecode.

`CustomerorderPosition.getState()` returns `Integer` (`model/CustomerorderPosition.java:107`);
`WmsConstants.State.CANCELED` is `public static final int CANCELED = 800`. Disassembling the **compiled class
from this worktree** (`javap -c -p -cp target/classes net.aim_ai.wms.service.CustomerorderService`) at both new
sites gives the same three instructions:

```
255: invokevirtual #681  // CustomerorderPosition.getState:()Ljava/lang/Integer;
258: invokevirtual #223  // java/lang/Integer.intValue:()I
261: sipush        800
264: if_icmpne     270
```

`invokevirtual Integer.intValue` + `if_icmpne`, **not** `if_acmpne`. Binary numeric promotion applied; there is
no reference comparison and therefore no `Integer`-cache boundary at 127. Correct at 800 and at every value.

### C2 — The NPE risk on a null state is genuinely absent. VERIFIED two ways.

1. Schema: `V2.2.00__base_v2_schema.sql` declares `customerorder_position.state integer NOT NULL` (also
   `amount`, `itemdata_id` NOT NULL, which matters for the payload builder downstream).
2. Reachability: the pre-existing guard one screen earlier already unboxes the same getter for **every**
   element on the path to the new code —
   `coPositions.stream().anyMatch(position -> position.getState() >= PACKED && position.getState() < CANCELED)`.
   `anyMatch` short-circuits, but if it short-circuits it throws, so the only way to reach the new skip is
   having dereferenced every position. The skip adds no new NPE surface.

The file's own idiom for a position-level state is bare, no null guard —
`if (orderPosition.getState() == WmsConstants.State.CANCELED)` and
`if (owner.getState() == WmsConstants.State.CANCELED) continue;` in this same class. The new code matches it.
(`cleanUpCancelledOrder` in `PickingorderBusinessService` *does* null-guard, but that is a **Customerorder**
passed by test-constructed instances, and its own comment says so.)

### C3 — The skip is correct in both loops, and there is no path where a CANCELED position should still be processed.

- **Guard loop.** `canOrderPositionBeCancelled` opens `if (state >= PACKED) return false;`
  (`CustomerorderPositionService.java:61`). 800 ≥ 650, so a CANCELED position was an unconditional blocker.
  Skipping it is the only answer that is *true*: it neither blocks nor needs cancelling.
- **Cancel loop.** `cancelOrderPosition` opens
  `if (state >= PACKED) throw new BusinessException("order position is beyond status PACKED. can not be cancelled anymore");`
  (`:120-122`). With `rollbackFor = {BusinessException.class, FacadeException.class}` on `cancelOrder`, that
  throw rolls the whole cancel back. The comment's claim about this is exact.
- **Consistency with the pre-existing hard block.** The `anyMatch` above already excludes 800 by writing
  `state >= PACKED && state < WmsConstants.State.CANCELED`. The two skips make the rest of the method agree
  with a band the method had already carved out. No other band in `cancelOrder` treats 800 as blocking.
- **No state above 800** exists in `WmsConstants.State`, so `== CANCELED` and `>= CANCELED` are the same set
  here; `==` is the stricter and better choice.

### C4 — The brace/indent restructuring is semantically correct. VERIFIED mechanically.

Comment- and whitespace-normalized diff of the whole method between `origin/develop` and HEAD:

```
31a32,34 >  if(customerOrderPosition.getState()==WmsConstants.State.CANCELED){ continue; }
47a51    >  if(!pickingPositions.isEmpty()){
69a74    >  }
71a77,79 >  if(customerOrderPosition.getState()==WmsConstants.State.CANCELED){ continue; }
```

Four added lines, zero moved, zero deleted. Nothing entered or left any other scope. The closing-brace run is
`}` ×4 in the order pickingtote-if → STARTED-if → isEmpty-if → section-if, which is the correct nesting.

### C5 — `coPositions` is correctly left unfiltered for the OMS payload.

The plan (§3.1) says *"Do not reassign or filter `coPositions` itself. The OMS outbox payload downstream is
built from it and needs every position."* The implementation uses `continue` in place, so the
`coPositions.stream().map(...)` payload builder further down still sees all positions. `externalid`, `amount`,
`index` and `itemdata_id` are all NOT NULL and are not cleared by `cancelOrderPosition`, so including a
CANCELED position in the payload cannot NPE. The single outbox message per order is protected by
`idempotencyKey = CANCELLED_IDEMPOTENCY_KEY_PREFIX + customerOrder.getId()`, so newly reaching this branch
cannot produce a duplicate.

### C6 — No missed sibling call sites.

`grep -rn "cancelOrderPosition\|canOrderPositionBeCancelled" src/main/java` outside
`CustomerorderPositionService` returns **exactly one** live call site of each, both inside `cancelOrder`, both
patched. Every other hit is a comment or javadoc reference. Specifically checked and found not to need the skip:

- `forceCancelOrder` — has its own position loop but does **not** call `cancelOrderPosition`, and sets
  `CANCELED` unconditionally (idempotent on an already-CANCELED position, no throw). Also dead: its only caller
  enters under `isPackedOrPalletized()`, so its `state < PACKED` arm is unreachable.
- `PickingorderBusinessService.cleanUpCancelledOrder` / `cancelOpenPickLines` — iterate positions but call
  neither helper; `cancelOpenPickLines` already carries its own `state == CANCELED → continue` on the **pick
  line**.
- `CancellationReversalService:297` — a comment reference only.

### C7 — Comment quotations against the code they cite.

| Claim in the new comment | Verified against | Holds? |
|---|---|---|
| `canOrderPositionBeCancelled` refuses at a `state >= PACKED` entry guard | `CustomerorderPositionService.java:61-63` | ✅ |
| `cancelOrderPosition` throws `"order position is beyond status PACKED"` | `:120-122`, message matches verbatim | ✅ |
| `cancelOrderPosition`'s work body is gated `state < PACKED` | `:141` `if (pickingPosition.getState() < WmsConstants.State.PACKED)` | ✅ |
| …which is **wider** than `cancelOpenPickLines`' `< PICKED` | `PICKED = 600`, `PACKED = 650`; `PickingorderBusinessService.java:546` `if (pickingPosition.getState() < WmsConstants.State.PICKED)` | ✅ |
| a PICKED line "would be flipped to CANCELED and its picking order demoted" | `:151` `setState(CANCELED)`, `:155-162` the `allTerminal`/`allCanceled` tail | ✅ |
| `cancelOpenPickLines`' javadoc says *"flipping it to CANCELED would make the tote's contents unattributable"* | `PickingorderBusinessService.java:526-529`, quoted verbatim | ✅ |
| `finishPickingOrder` throws `ORDER_ALREADY_FINISHED` at a picking order past FINISHED | corroborated by the sibling comment at `:632-635` and by the two orders' `pickingorder.state = 700` | ✅ |
| CANCELED(800) ≥ PACKED(650) | `WmsConstants.State` lines 108, 128 | ✅ |
| `rollbackFor = BusinessException` on `cancelOrder` | method annotation at `:756` | ✅ |

### C8 — The DB claims in the comments and test javadoc. ALL FOUR VERIFIED, exactly.

| Claim | Query result | Holds? |
|---|---|---|
| CO 28848660 / 28857575 stranded on wms2-wineco-dev | both `state=200`, `pickingconfirmationsent=false`, `markedforcancellation=true`, position `800`, pick line `800`, picking order `700` | ✅ (but see **M3**) |
| CO 585000351: "CO position 800, pick line 600 with amountpicked = 1.0000, picking order 700" | `pos_state=800`, `pl_state=600`, `amountpicked=1.0000`, `po_state=700`, `pickingconfirmationsent=true` | ✅ exact |
| "3,023 pick lines sit at PICKED under a CANCELED CO position on wsl-wineco-uat" | `SELECT count(*) … pop.state=600 AND cop.state=800` → **3023** | ✅ exact |
| "production has no such [RAPID_PICKING] section at all" | wms2-hydra PRD: 2 sections, both `TOTES_ON_CART` | ✅ |
| "both RAPID_PICKING sections carry zero orders" | wms2-wineco-dev: one RAPID section `test_section` (5 clients, **0** orders); the other tenant not re-checked | ✅ where checked |

### C9 — The tests do run, and they pass.

⚠ Worth stating because it is easy to miss: `**/*IntegrationTest.java` is **excluded from surefire** and
**included in failsafe** (`pom.xml`). The "6,629 unit tests pass" figure therefore does **not** include these
three. They are in the failsafe lane, and `target/failsafe-reports/` in this worktree records
`Tests run: 3, Failures: 0, Errors: 0, Skipped: 0` for
`CancelOrderAlreadyCancelledPositionIntegrationTest`, with all three method names present. Since fixtures 1 and
3 fail on pre-fix code, that report is necessarily from a post-fix run.

*I did not run Maven myself:* a `mvn -B -ntp clean verify` was live in this shared worktree during the review
(pid 1103693), and a second concurrent build in one worktree is the known false-red generator. Where I wanted a
mutant (M3, M5) I argue it statically below and name the probe for whoever has the tree to themselves.

---

## Findings

### M1 — Medium · comment asserts a 500; the endpoint returns a 400

`src/main/java/net/aim_ai/wms/service/CustomerorderService.java`, the new RAPID guard comment:

> "An empty list would now be an IndexOutOfBoundsException — a RuntimeException that escapes
> OrderRestController as a **generic 500** rather than the WRONG_STATE 400 OMS handles."

Traced: an `IndexOutOfBoundsException` out of `cancelOrder` is caught by the per-order
`catch (Exception e)` in `OrderRestController.cancelPositions`, which does
`throw new WebserviceBusinessExceptionClientSide(WmsConstants.GENERIC_ERROR, e);`. That is a **checked**
exception, caught by the method's own outer handler, which ends:

```java
        } catch (WebserviceBusinessExceptionClientSide e) {
            …
            return ResponseEntity.badRequest().body(e.getErrorMap());
        }
```

So it is **400**, via the same exit as the WRONG_STATE arm — not a 500. No advice class handles
`WebserviceBusinessExceptionClientSide`, and it never reaches `RestEndpointExceptionHandler`'s
`@ExceptionHandler(Exception.class)` 500 arm, because the controller catches it first.

The guard is still right; only the stated consequence is wrong. The two **real** differences are worth putting
in the comment instead, because they are what OMS actually sees: the body carries `GENERIC_ERROR` rather than
`WRONG_STATE`, and unlike the `ToteTeardownException` arm (which `continue`s) this one **rethrows and aborts the
whole batch**, so every not-yet-processed order in the same call goes uncancelled.

**Suggested rewrite:** *"…would be an IndexOutOfBoundsException. `OrderRestController.cancelPositions` catches
it in its `catch (Exception e)` arm and rethrows it as `GENERIC_ERROR`, which still leaves as a 400 — but as
`GENERIC_ERROR` rather than the `WRONG_STATE` OMS handles, and unlike the `ToteTeardownException` arm it aborts
the remainder of the batch instead of containing to this order."*

### M2 — Medium · "could not arrive here" is disprovable, and it misattributes a pre-existing bug to this commit

Same comment block:

> "This side-door is **newly reachable** for an order whose FIRST position is already CANCELED: before the skip
> above, such an order never got past the guard loop, so **an empty `pickingPositions` could not arrive here**."

The first clause is true. The second is not. `canOrderPositionBeCancelled` returns **true** for a position with
no pick lines at all:

```java
        List<PickingorderPosition> poPositions = pickingorderPositionRepository.findByCustomerorderpositionId(customerOrderPosition.getId());
        if (poPositions.isEmpty()) {
            return true;
        }
```

So on `origin/develop`, a RAPID_PICKING order at `ASSIGNED` with `historytote != null` whose **first** position
simply has no pick lines (no CANCELED position involved anywhere) reaches
`pickingPositions.get(0).getPickingorderId()` with an empty list and throws `IndexOutOfBoundsException` today.
The guard fixes a **pre-existing** latent bug as well as the newly-reachable one.

This matters beyond pedantry: the comment is the record of why the guard exists, and as written it invites a
future reader to conclude the guard can be dropped if Fix A is ever reverted. State the invariant instead —
*`pickingPositions` can be empty whenever the first CO position has no pick lines, which `canOrderPositionBeCancelled`
has always permitted; SBDEV-3363 adds a second way in (a CANCELED first position).*

### M3 — Medium · fixture 1 does not reproduce the shape it names, and its second assertion is vacuous

`src/test/java/net/aim_ai/wms/integration/CancelOrderAlreadyCancelledPositionIntegrationTest.java`, fixture 1,
whose javadoc says *"The exact shape of the two stranded orders."*

The two live orders carry `markedforcancellation = **true**` (that is what "stranded after cancel #1" means —
verified on wms2-wineco-dev, both rows). The fixture seeds it **false**:

```java
    private Customerorder newOrder(String number, int state, boolean pickingConfirmationSent) {
        …
        order.setMarkedforcancellation(false);
```

Two consequences:

1. **The assertion is vacuous.** `assertThat(reloaded.getMarkedforcancellation()).as("the deferred-cancel flag
   is spent once the cancel completes").isFalse()` starts from `false` and nothing on the post-fix success
   branch ever sets it `true`. It passes whether or not
   `customerOrder.setMarkedforcancellation(false)` (the SBDEV-3332 line at the tail of the true branch) is
   present. Deleting that line is a surviving mutant, and this assertion is the only thing pointed at it.
2. **The fixture models cancel #1, not cancel #2.** The repair path for the two stranded orders is a *second*
   OMS cancel arriving at an order that already carries the flag. That is the scenario AC-1 is about, and it is
   not the one under test.

The fix itself is fine for the real shape — I traced `markedforcancellation = true` through `cancelOrder` and it
changes no branch (`isAlreadyCancelled` keys on `state`, the club guard on the batch, `anyMatch` on positions;
the flag is only read in the `else` arm) — so this is a test defect, not a fix defect.

**Fix:** seed `markedforcancellation = true` in fixture 1 (parameterize `newOrder`, or set it on the returned
entity before the call). The assertion then becomes a real one. **Mutation probe for whoever has the tree
exclusively:** delete `customerOrder.setMarkedforcancellation(false);` at the tail of the true branch and rerun
— it must go red after the fixture change and is green before it.

### M4 — Medium · fixture 2's javadoc describes the pre-fix route, and contradicts the plan

Fixture 2's javadoc:

> "It is **not** stranded: with `pickingconfirmationsent = true` it **reaches `cleanUpCancelledOrder`**, whose
> `cancelOpenPickLines` is bounded to `state < PICKED` and therefore leaves the picked line alone."

That is `origin/develop` behaviour. **On this commit it is false.** The order's only position is CANCELED, the
new skip fires, `orderCanBeCancelled` stays `true`, and the method takes the success branch —
`cleanUpCancelledOrder` is never called, and `cancelOpenPickLines`' `< PICKED` bound is never exercised. What
protects the PICKED line post-fix is the **second** new `continue`, which stops `cancelOrderPosition` from being
called at all.

The plan says exactly this, in §3.1.1: *"Under Fix A, `585000351` moves from the `cleanUpCancelledOrder` arm to
the true branch and therefore loses the `customerorder_cancellation_log` row that `cancelOpenPickLines` writes."*
So the test javadoc and the plan disagree, and the plan is right.

The pin still **works** — under the rejected two-guard fix the order reaches `cancelOrderPosition`, whose
`< PACKED` body flips the 600 line — so this is not a weak-test report. It is a wrong-explanation report, and
this area is the one the ticket flags for repeated comment drift.

**Fix:** rewrite the javadoc to say what actually protects the line now (the skip), keep the sentence about
`cancelOpenPickLines`' bound as the description of the *rejected* fix's blast radius, and add the plan's own
sentence about the lost `customerorder_cancellation_log` row so the accepted delta is visible from the test.

### M5 — Medium · the new `isEmpty()` guard has no test coverage at all

Every fixture builds its `Client` with no `sectionId`:

```java
        Client client = new Client();
        client.setClNr("1");
        client.setName("IT-Client-3363");
```

so `client.getSectionId() == null` → `section` stays `null` → the whole
`if (section != null && …RAPID_PICKING…)` block is skipped in all three tests. Removing
`if (!pickingPositions.isEmpty()) { … }` is a mutant that **survives the entire suite**. The floor's
"mutation-check every new assertion" has nothing to act on here because no assertion reaches the guard.

Given the comment argues the block is re-armable by a single `section.sectionpickingtype` row edit with no
deploy, that argument applies to the test too. A fourth fixture is cheap: seed a `Section` with
`sectionpickingtype = RAPID_PICKING`, point the client at it, set `historytote` on an `ASSIGNED` order whose
first position has **no** `PickingorderPosition` rows, and assert the order still reaches `CANCELED` instead of
throwing. That single fixture covers **both** entry shapes named in M2.

### L1 — Low · this commit makes a sibling comment false

`src/main/java/net/aim_ai/wms/service/PickingorderBusinessService.java`, inside `cleanUpCancelledOrder`:

```java
        //   · flagged, state < 800, picking order >= FINISHED          -> STRANDED (2): every CO
        //     position already CANCELED, so canOrderPositionBeCancelled is false at `>= PACKED` and
        //     cancel #2 only re-sets the flag, while finishPickingOrder throws. No terminal path in
        //     either direction.
```

After Fix A, `canOrderPositionBeCancelled` is **never consulted** for a CANCELED position, cancel #2 does not
merely re-set the flag, and there *is* a terminal path. Leaving it is the same drift the ticket is cleaning up
elsewhere. One clause is enough: *"…was false at `>= PACKED` until SBDEV-3363 made `cancelOrder` skip
already-CANCELED positions; cancel #2 now completes."*

### L2 — Low · `coPositions.get(0)` is still unguarded, unordered, and can now be the cancelled position

```java
                CustomerorderPosition customerOrderPosition = coPositions.get(0);
```

Three things, all pre-existing but all made more consequential by the new reachability:

1. **`coPositions` itself can be empty** — an order with zero positions passes the `anyMatch` and the guard loop
   vacuously and reaches this line. The new guard covers `pickingPositions`, not this.
2. **`findByOrderId` carries no `ORDER BY`**, so "first" is whatever the planner returns. Fine when the choice
   did not matter; it matters more now.
3. **`get(0)` is deliberately not filtered** (per the brief, a settled decision). The consequence worth writing
   down: on a mixed order whose first position is CANCELED, the side-door inspects the *cancelled* position's
   picking order rather than an open sibling's. If they differ, a `STARTED` picking order belonging to the open
   position is not demoted to `PROCESSABLE` and its pick-to unitloads are not cancelled. Partly mitigated —
   `cancelOrderPosition` still cancels the open line and settles the picking order via its `allTerminal` tail,
   and the SBDEV-3339 block after the loop still tears the tote down — so I am **not** proposing a change here,
   only that the deliberate `get(0)` comment record what it costs.

### L3 — Low · nothing asserts the OMS notification

The point of taking these orders terminal is that OMS learns about it. Reaching the outbox enqueue is also the
only reason the fixture needs a real `Itemdata` (its own comment says so). No test asserts the row. One line
after fixture 1's existing assertions —
`outbox_message` count `1` for `idempotencyKey = CANCELLED_IDEMPOTENCY_KEY_PREFIX + order.getId()` — pins the
payload builder, which is the largest stretch of newly-reachable code in this change.

### L4 — Low · "guard the get(0)" is ambiguous about which one

The comment opens `// SBDEV-3363 — guard the get(0).` and sits between `coPositions.get(0)` and
`pickingPositions.get(0)`, with the `coPositions.get(0)` line immediately above it. It guards
`pickingPositions`. Naming it — "guard the `pickingPositions.get(0)`" — costs a word and removes a reading in
which L2's unguarded `coPositions.get(0)` looks handled.

### L5 — Low · fixture 2's `pickingconfirmationsent = true` is now inert

`newOrder("ORD-3363-PICKED", ASSIGNED, **true**)` is the parameter the javadoc leans on ("with
`pickingconfirmationsent = true` it reaches `cleanUpCancelledOrder`"). Post-fix the flag is read only in the
`else` arm, which this fixture no longer takes, so the test behaves identically with `false`. Keep the `true`
(it matches live CO 585000351 — verified) but stop presenting it as the thing that routes the test; that
belongs with the M4 rewrite.

---

## Things explicitly checked and found NOT to be problems

- **`finalizeBatchIfComplete`** — takes `orderbatchId` and re-derives completeness from the DB; it never sees
  `coPositions` and is unaffected by the skip.
- **The `@Transactional(rollbackFor = {BusinessException, FacadeException})` boundary** — the skip *removes* the
  only new throw site (`cancelOrderPosition` on a CANCELED position) rather than adding one. The `isEmpty()`
  guard removes an unchecked throw. Neither narrows or widens the rollback set.
- **Idempotency / double-notify** — one outbox message per order by unique `idempotencyKey`; orders newly
  reaching the true branch have never been notified.
- **Fixture 3 (mixed order)** — traced end to end: the CANCELED position is skipped in both loops, the
  `PROCESSABLE` position goes through `cancelOrderPosition`, its pick line flips to CANCELED, and the
  `allTerminal`/`allCanceled` tail takes the `STARTED` picking order to `CANCELED`. Its two assertions are
  real (both fail pre-fix). It could additionally assert the picking order's settled state, but that is a
  nice-to-have, not a gap.
- **The `@BeforeEach @Transactional(value = "tenantTransactionManager")` seeding pattern** — inert as written
  (Spring's `TransactionalTestExecutionListener` keys on the *test* method, and the base class is deliberately
  non-transactional), but identical to the sibling `CancelOrderRollbackIntegrationTest`, and the saves commit
  through `SimpleJpaRepository` regardless. Matching the sibling is the right call; not reported as a defect.
