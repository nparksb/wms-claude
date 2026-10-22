# Lane J — CONFORMANCE review, SBDEV-3363 Fix B (AC-5) + Fix C (M-4)

**Question:** does the committed code implement what the plan designed — all of it, and nothing the plan excluded?
Not code quality (lane K), not adversarial (lane M).

**Date:** 2026-09-16 · **Reviewer:** lane J

## Evidence base — everything below was re-derived in-worktree, nothing taken on report

| repo | worktree | branch | commit | base |
|---|---|---|---|---|
| wms2-api | `/home/nampark/dev/wms-claude/.claude/worktrees/wms2-api/SBDEV-3363-ac5` | `bugfix/SBDEV-3363-deferred-cancel-terminal-path-ac5` | `af403931` | `4bef7e77` |
| wms2-mobile-ui | `/home/nampark/dev/wms-claude/.claude/worktrees/wms2-mobile-ui/SBDEV-3363-m4` | `bugfix/SBDEV-3363-m4-demand-cancelled` | `1e3d979` | `ab1e2ae` |

`git diff --name-only origin/develop...HEAD` (API) returns exactly four paths:
`PickingorderBusinessService.java`, `service/mobile/MobilePickingService.java`,
`integration/DeferredCancelTerminalPathIntegrationTest.java`, `unit/service/mobile/MobilePickingServiceUnitTest.java`.
**`CustomerorderService.java` is not among them** — that matters for C4 below.

---

## VERDICT: **FAIL** (one material MISSING gate, one MISSING sibling-sweep item, one false in-code claim)

The two halves of Fix B are both present and correct, the mobile half is correct and genuinely
mutation-graded, and the cross-repo field name matches. But the gate set was derived from a **narrower
rule than the plan states**, and that narrowing silently drops the one gate the plan singled out by name
as the shape every instrument misses.

---

## 1. Independently-derived gate set

### Method

I did **not** start from the plan's list or the commit's list. Three instruments, run in the API worktree:

1. **Promotion instrument** — `grep -rn "setState(WmsConstants.State.PICKED)\|setState(State.PICKED)\|setState(600)" src/main/java`.
   11 hits; filtered to the ones whose receiver is a `Pickingorder` (the rest set `Customerorder`,
   `CustomerorderPosition`, `PickingorderUnitload`, `PickingorderPosition`).
2. **Consumer instrument** — `grep -rn "finishPickingOrder" src/main/java`, then read the guard
   immediately above **every** call site. This is the instrument that finds gates which do not
   themselves write `PICKED` (a gate can hand control on by falling through a loop).
3. **Predicate instrument** — `grep -rn "State.PICKED" src/main/java | grep -E "<|>|noneMatch|anyMatch|allMatch|LessThan|GreaterThan"`,
   then read each hit in context. This is the one that catches the repository-derived
   `countByPickingorderIdAndStateLessThan` and the hand-rolled loops.

Cross-checking the three against each other is what produced the finding: instrument 1 alone gives six,
instrument 2 gives ten call sites, and only reading instrument 2's guards exposes the eleventh gate.

### Result — 10 `finishPickingOrder` call sites, 8 real completeness gates, **6 made demand-aware**

| gate | site | shape before | now |
|---|---|---|---|
| G-P1 | `PickingorderBusinessService.confirmPick` (`countByPickingorderIdAndStateLessThan(...) == 0`) | repository-derived | ✅ `unpickedCount == 0 \|\| isPickingOrderComplete(id)` |
| G-P2 | `MobilePickingService.resumePickingOrderIfExists` | `noneMatch(state < PICKED)` | ✅ helper |
| G-P3 | `MobilePickingService.releasePickingOrder` | `noneMatch(state < PICKED)` | ✅ helper |
| G-P4 | `MobilePickingService.startPickingOrder` | hand-rolled accumulator + `break` | ✅ helper |
| G-P5 | `MobilePickingService.finalizePickingOrderForStart` | `noneMatch(state < PICKED)` | ✅ helper |
| G-P6 | `MobilePickingService.releaseRegularPickingOrder` Case 2 `allPicked` | `noneMatch(state < PICKED)` | ✅ helper |
| **P-8** | **`MobilePickingService.rapidPickingScanSource`** | **accumulator-free early-return loop** | ❌ **UNCHANGED, no exclusion stated** |
| P-3 | `MobilePickingService.releasePickingOrder` `hasFinishedPicks`/`hasOpenPicks` | hand-rolled pair | ❌ unchanged, no exclusion stated (see §1.3 — benign) |

**Inherited, correctly not separate gates** (they read a state another gate already set, so the fix
reaches them through G-P1): `MobilePickingService.processPick` (`if (pickingOrder.getState() == PICKED)`
after `confirmPick`) and `rapidPickScanPackageToVerify` (same shape).

**Correctly out of scope, with a stated reason:** `CustomerorderService.forceCancelOrder`
(`allMatch(state >= FINISHED)`) — plan §0.2 B11 / §10 F1, declared out of scope, branch documented dead.
`AdminActionController` force-finish — a manual recovery action with no completeness gate at all.

### 1.1 The measured count and what the disagreement is

**I measure 6 of 8 in-scope gates changed.** The commit says "six" and is internally consistent — but only
under the rule *it* states, which is **not** the plan's rule:

- commit `af403931`: *"derived from the RULE — **'promotes a Pickingorder to PICKED'**"*
- plan §2.2: *"The rule is: **every site that decides whether a picking order is complete and, on 'yes',
  hands control to `finishPickingOrder`**."*

P-8 does not write `PICKED` — `confirmPick` already did — so it is invisible to the commit's rule and
squarely inside the plan's. The substitution is not flagged anywhere. And the plan did not merely imply
P-8: §2.2 enumerates the shapes to expect and names *"an **accumulator-free early-return loop** where
**falling through** is the verdict"*, which is P-8 and only P-8 (laneB §Instrument B: *"misses
accumulator-free early-return loops (it did — see site P-8, found only by reading)"*).

### 1.2 P-8 — MISSING · the material finding

`MobilePickingService.rapidPickingScanSource`, immediately after its `confirmPick`:

```java
pickingOrder = pickingorderBusinessService.confirmPick(pickingPosition, pickingorderUnitload, ...);

PickingHighPositionInfoDto dto = new PickingHighPositionInfoDto();
for (PickingorderPosition pp : pickingorderPositionRepository.findByPickingorderId(pickingOrder.getId())) {
    if (pp.getState() < WmsConstants.State.PICKED) {
        dto.setPickingorderPosition(pp);
        dto.setPickCompleted(false);
        return dto;                      // <-- gate: control never reaches finishPickingOrder
    }
}

if (pickingOrder.getState() == WmsConstants.State.PICKED) {
    pickingOrder = pickingorderBusinessService.finishPickingOrder(pickingOrder);
    ...
}
```

Verified untouched: `git diff -U0 origin/develop...HEAD -- .../MobilePickingService.java` returns hunks at
242, 266, 270, 341, 398, 736, 902, 913 — **nothing above 1300**. No `SBDEV-3363` marker anywhere near it.

**Reachable consequence (traced by reading, not executed).** Take a multi-line RAPID picking order where
one CO position is cancelled while its pick line stays open — `isDemandCancelled` trigger 2, which was
already a trigger before this ticket. Operator picks the live line:

1. `confirmPick` succeeds for the live line;
2. G-P1 is now demand-aware → `unpickedCount == 1`, helper says complete → **PO promoted to `PICKED`**;
3. P-8's raw loop sees the cancelled line at 300 → early return, `pickCompleted = false`, DTO points the
   operator **at the demand-cancelled line**;
4. operator scans it → `assertPickNotCancelled` → `PICK_CONFIRM_ORDER_CANCELLED` → retry forever.

That is precisely the infinite-retry shape AC-5 + M-4 exist to remove, surviving on the rapid path — and
the PO is now parked at `PICKED`-but-not-`FINISHED`, a state it did **not** reach before the change
(previously G-P1 kept it below `PICKED`). Recovery exists but is not automatic: `releaseRegularPickingOrder`
is demand-aware and applies no section-picking-type check, so an operator release still finishes it.

Two honest caveats, so this is not over-sold:
- For the **deferred-flag** trigger (trigger 4, AC-5's own headline shape) in a **single-CO** rapid order,
  P-8 is not reached: every line's demand is cancelled, so `confirmPick` refuses before the loop. P-8's
  exposure is triggers 1–3 plus multi-CO picking orders.
- M-4's client fix cannot mask this: the rapid screen consumes `PickingHighPositionInfoDto`, not the
  pick-list map, so it never sees `demandCancelled`. That boundary is plan-conformant (C6 names
  `getPickingOrderPositionsInfo`'s `map.put` specifically) but the plan never states it.

**What makes this a FAIL rather than a note:** the plan put P-8 in scope (§0.2 B1–B8), named its exact
shape (§2.2), and laneB found it by hand precisely because greps miss it. It is neither fixed nor
excluded-with-a-reason. Per the lane brief, that is "neither (a) nor (b)".

### 1.3 P-3 — MISSING but benign · report, do not block on it

`releasePickingOrder`'s `hasFinishedPicks`/`hasOpenPicks` pair is unchanged and uncommented. It is inside
plan §0.2's B1–B8 block, so strictly it is in scope. Two reasons it is not material:

- It does not gate `finishPickingOrder`; it gates the `FINISHED` / `PROCESSABLE` / `CANCELED` assignment
  at the tail. Under the plan's own rule it is out.
- The change makes it **less** reachable, not more: a marked order now satisfies the demand-aware
  `allFinished` at the top of the same method, is promoted to `PICKED`, and returns at
  `if (state == PICKED) { finishPickingOrder(...); return; }` before the loop.

The residual defect (`CANCELED(800) >= PICKED(600)` makes a cancelled line read as "something was picked")
is pre-existing, is laneB's P-3 "Yes, in principle / structurally unreachable" finding, and is unchanged.
**Finding: an in-scope site was dropped with no note.** Cost to close: one comment.

### 1.4 `anyPicked` — the deliberate exclusion. Right call, wrong reason.

The brief asked me to judge the rationale rather than report the exclusion. In-code:

> *"⚠ anyPicked is deliberately left as the raw state test. It selects between Case 3 ... and Case 4, and
> a cancelled line is not evidence that picking happened. Making it demand-aware would be wrong in the
> other direction."*

**The direction is correct and the code is not made worse** — an *open* line whose demand is cancelled
must not count as "picking happened", so widening `anyPicked` would wrongly keep orders out of Case 3.
Do not change it.

**But the reasoning does not engage the defect laneB actually recorded.** laneB P-6: *"**Yes** for
`anyPicked` — an all-cancelled PO has `anyPicked == true`, so it can never take Case 3's 'reset to pool'
arm."* That is about a line already at `CANCELED(800)`, which trivially satisfies `>= PICKED(600)` — a
*narrowing* problem, the opposite axis from the one the comment argues. So the comment reads as a
disposal of laneB's finding when it answers a different question. Both conclusions happen to land on
"leave it raw", so no code change follows; the comment should say *which* concern it is disposing of.
**PARTIAL** — exclusion correct, stated rationale mis-targeted.

### 1.5 Blind spots of my own method

- **Reflection / SpEL / SDR**: a state transition driven from outside Java source is invisible to all
  three instruments. `Pickingorder` is in `RestConfiguration.SDR_WRITE_WITHDRAWN`, so the SDR route is
  405 — but I took that from `Pickingorder.setOperatorId`'s javadoc, I did not re-verify the list.
- **`src/test` excluded** from my sweep; a test-only gate would not appear.
- **Numeric spelling**: I grepped `setState(600)` but not every arithmetic/indirect way to reach 600
  (e.g. a constant aliased through another field).
- **Native SQL / JPQL bulk updates** that set `state` without a Java setter. I did not sweep `@Query`
  strings for `pickingorder` updates.
- The P-8 consequence in §1.2 is a **read trace**, not an executed repro. I did not build the fixture.

---

## 2. Fix B — both halves present (the plan's "either alone reproduces a withdrawn attempt")

**VERIFIED.** Both are in the single commit `af403931`.

**(a) the trigger**, `PickingorderBusinessService.isDemandCancelled` — the SBDEV-3332 `⚠ NOT a trigger`
comment and its bare `return` are gone, replaced by:

```java
if (customerOrder.getState() != null && customerOrder.getState() == WmsConstants.State.CANCELED) {
    return true;
}
// SBDEV-3363 — the deferred cancel. ...
return Boolean.TRUE.equals(customerOrder.getMarkedforcancellation());
```

`Boolean.TRUE.equals(...)` is null-safe on a `Boolean` column — correct.

**(b) the gates** — six sites, §1 above.

Both land in one commit, which is what §3.2 / §2.2 require.

---

## 3. §8 acceptance criteria, one by one

| # | Criterion (plan §8) | Verdict | Evidence |
|---|---|---|---|
| 8.1-lane | AC-5 test is **H2 / `BaseRollbackIntegrationTest`**, not Testcontainers (the "GATE OUTCOME" block) | **VERIFIED** | `DeferredCancelTerminalPathIntegrationTest extends BaseRollbackIntegrationTest`; base is `@SpringBootTest @ActiveProfiles("integration")`, no container |
| 8.1-iso | private H2 DB names so `create-drop` cannot empty siblings' schemas | **VERIFIED** | `@TestPropertySource(properties = {"spring.datasource.url=jdbc:h2:mem:rollback_tenant_3363ac5;...", "landlord.datasource.jdbc-url=jdbc:h2:mem:rollback_landlord_3363ac5;..."})` |
| AC-5 positive | a marked order with an open line reaches terminal | **VERIFIED** | `releasePickingOrder_shouldCancelOrder_whenMarkedForCancellationAndLineStillOpen` — asserts `co.state == CANCELED`, `markedforcancellation == false`, **and** exactly one `ORDER_BATCH_CANCELLED_FROM_WMS` outbox row for that aggregate. All three of §8.1's stranded-fixture assertions |
| AC-5 over-reach | an UNMARKED order with an open line is still incomplete | **VERIFIED** | `releasePickingOrder_shouldNotCancelOrder_whenNotMarkedAndLineStillOpen`, asserts `isNotEqualTo(CANCELED)` |
| §8.2 row 4 | mutant: remove the flag conjunct from `isDemandCancelled` → red | **NOT RE-RUN** | claimed KILLED in plan §12. I did not re-run it — the brief forbids a full `verify` and another lane is building in this worktree (concurrent Maven in one worktree produces false reds). **Lane K or M should own this row.** |
| §8.2 row 5 | mutant: revert one demand-aware gate to raw `noneMatch` → red | **NOT RE-RUN** | same |
| §8.3 Jest C5 | `demandCancelled === true` + `pickStatus !== 'Cancelled'` → row disappears | **VERIFIED, mutation-graded by me** | see §4 |
| §8.3 Jest C5 back-compat | old API (`demandCancelled` absent, `pickStatus === 'Cancelled'`) → still filtered | **VERIFIED, mutation-graded by me** | see §4 |
| §8.3 Jest C5b | both cases against **`nextPickingPosition`**, not just the filter | **VERIFIED, mutation-graded by me** | see §4 |
| §8.3 M-4 server half | the API actually emits `demandCancelled` | **PARTIAL — no test** | the `map.put` is present (§5) but **nothing in `src/test` references `demandCancelled`**: `grep -rn "demandCancelled" src/test` → zero hits. The only `isPickingOrderComplete` hits in `src/test` are three Mockito **stubs** (`when(...).thenReturn(true)`), which pin nothing about the predicate. `findDemandCancelledPickLineIds` has no test at all. The cross-repo contract holds by inspection only |
| §8.3 Testcontainers V2.2.31 | Fix D | **N/A** | Fix D is a separate PR, out of this lane's scope |
| §8.3 Manual | handheld cancel mid-pick | **NOT DONE** | expected; not this lane's |

---

## 4. Fix C (M-4) — widen-not-replace, both sites, and the field name

### 4.1 Both sites widened, not replaced — **VERIFIED**

`store/picking.js`, the filter in `getPickingOrderPositionsInfo`:

```js
const livePositions = results.filter(position =>
  position.pickStatus !== CANCELLED_PICK_STATUS && !position.demandCancelled)
```

and the landing rule in `nextPickingPosition`:

```js
if (state.pickingOrderPositions[i].pickStatus !== 'Picked'
    && state.pickingOrderPositions[i].pickStatus !== CANCELLED_PICK_STATUS
    && !state.pickingOrderPositions[i].demandCancelled) {
```

Both keep the `pickStatus` conjunct and **add** `!demandCancelled` — exactly §3.3's "RIGHT" form, both
conjuncts, at both sites.

### 4.2 Field name — **VERIFIED, exact match**

- API, `MobilePickingService.getPickingOrderPositionsInfo`: `map.put("demandCancelled", demandCancelledIds.contains(pos.getId()));`
- UI, both sites: `position.demandCancelled` / `state.pickingOrderPositions[i].demandCancelled`

Byte-identical. Also checked that the map is built over the **unfiltered** `poPositions` (`for
(PickingorderPosition pos : poPositions)` at the render loop, where `poPositions` is
`findByPickingorderId(pickingOrderID)` possibly re-**ordered** but never subset), so **every** emitted row
carries the field — no row silently arrives without it.

### 4.3 I ran the client tests and mutation-checked them myself

`npx jest test/store/pickingDemandCancelled.spec.js` on `1e3d979`: **5 passed / 5 total**.

Two mutants applied by copying `store/picking.js` to the scratchpad, editing in place, and restoring from
the copy (no `git checkout`/`restore`/`stash` used; `git diff --stat HEAD -- store/picking.js` empty afterwards):

| mutant | result |
|---|---|
| **replace-not-widen** at **both** sites (drop the `pickStatus` conjunct) | **KILLED** — `2 failed, 3 passed`; the two failures are exactly the two "old API" back-compat tests, one per site |
| **drop `!demandCancelled`** at **both** sites (revert to old behaviour) | **KILLED** — `3 failed, 2 passed`; the two old-API tests stay **green**, which is precisely what they are for |

The kills separate cleanly per site and per direction. The deploy-order safety property (§5.1: UI may ship
first) is genuinely pinned, not merely asserted in a comment.

### 4.4 Sibling sweep on the client — accurate as written, but the §12 wording invites a misread

Plan §12 says *"this store has **no** `previousPickingPosition` mutation, so those two are the whole set."*
Literally true. But the store **does** have `nextPosition` and `previousPosition` (`store/picking.js:~100`,
`:112`) — plain index walkers with **no** cancellation test of any kind. They only walk
`state.pickingOrderPositions`, which the action has already filtered, so in the normal case a
demand-cancelled row is not in the array at all. The window `nextPickingPosition`'s own comment describes
("a cancel can land between load and tap") is therefore covered by `nextPickingPosition` but **not** by
`nextPosition`/`previousPosition`.

Pre-existing, unchanged by this commit, and outside the plan's C5/C5b scope — **not a MISSING**. But the
"whole set" phrasing rests on a mutation *name* rather than on the behaviour, and that is the kind of
sentence that later gets cited as coverage. `components/picking/pick.vue:345` (`activePick()`) is the
third `pickStatus` reader and is correctly excluded by plan §0.3 C5c.

---

## 5. Designed but not built / built but not designed

### 5.1 Designed, NOT built

| item | status |
|---|---|
| **C4** — `CustomerorderService.cancelOrder`'s deferred-`else` ⚠ comment (plan §0.3: *"the fullest statement of the old constraint"*, **yes**, sibling of C1) | **MISSING** |
| P-8 gate (§1.2) | **MISSING** |
| P-3 gate (§1.3) | **MISSING**, benign |
| F2 write-order hygiene | **not built — correctly.** §3.2 marks it explicitly optional and non-mandatory ("drop it if the gate is tight"). Conformant. |

**C4 in detail.** Plan §0.3 closes with: *"**C2–C4 are the sibling sweep for C1.** Four ⚠ comments across
**two files** encode the SBDEV-3332 decision; re-admitting the trigger without updating all four leaves the
codebase asserting something false about its own behaviour. That is how this area has already gone wrong
three times."*

Three of the four are in `PickingorderBusinessService` and **all three were updated** (the `finishPickingOrder`
G4 comment, `assertPickNotCancelled`'s `LOG.warn` + its comment, `isDemandCancelled`'s return-statement
comment, plus the C1b javadoc rewritten to state the chain rather than a count — all correct). The fourth is
in the second file, which this commit does not touch. It still reads, verbatim:

> `// ⚠ SBDEV-3332 — the flag on its own stops nothing, and it has NO TERMINAL PATH.`
> `// Its only consumer is PickingorderBusinessService.finishPickingOrder, which cannot`
> `// run until every line is already PICKED ...`
> `// Deliberately left as it was. ... the guard in`
> `// PickingorderBusinessService.isDemandCancelled does NOT treat this flag as`
> `// cancelled demand for the same reason ...`

All three claims are now **false**: the flag has a terminal path, `finishPickingOrder` is called for an
order with an open line, and `isDemandCancelled` **does** treat the flag as cancelled demand. This is the
single most load-bearing statement of the old constraint in the codebase, sitting at the exact site that
sets the flag — the first place a future reader lands. It is the failure mode §0.3 names in its own
last sentence.

Cost to close: one comment edit in `CustomerorderService.java`. It does pull a third file into the PR.

### 5.2 Built, NOT designed

| item | verdict |
|---|---|
| `findDemandCancelledPickLineIds(List)` — **public**, bulk, accepts *any* list | **acceptable.** §3.3 designs "a `demandCancelled` boolean ... computed by the **same** `isDemandCancelled`"; a bulk helper is the obvious N+1-free realisation. Its javadoc states the widened contract honestly |
| `isPickingOrderComplete` **two** overloads (`Long` / `List`) — plan §3.2 designs one, `(Long)` | **acceptable.** The `List` overload avoids a second query at the five gates that already loaded the lines. Contract (*"the caller must pass EVERY line of ONE picking order"*) is stated on the method |
| `unpickedCount == 0 \|\| isPickingOrderComplete(id)` in `confirmPick` — plan §3.2 says "**replace** the expressions with a call" | **acceptable, logically equivalent**, justified in-comment as a cheap pre-test. Note for lane K, not J: this is a self-invocation, so the `@Transactional(readOnly = true)` on the helper is bypassed (no proxy) — harmless (it joins the caller's tx, which is what is wanted) but the annotation is decorative on that path |
| `pickingOrder = pickingorderRepository.save(pickingOrder)` **reassignment** in `releasePickingOrder` (I-5) | **undesigned but necessary and correct.** Verified the siblings do not need it: G-P2/G-P4/G-P5 mutate a *managed* entity loaded in the same transaction and rely on dirty checking with no `save` at all; only `releasePickingOrder` receives a possibly-**detached** `Pickingorder` as a method parameter. Correctly scoped to the one site |
| three `when(pickingorderBusinessService.isPickingOrderComplete(anyList())).thenReturn(true)` stubs in `MobilePickingServiceUnitTest` | **acceptable** — each preserves its test's original subject and says so. But see §3: these are the *only* `src/test` references to the helper, so they are not coverage |

### 5.3 A false claim shipped in `src/main` javadoc — and in the commit message, and in plan §12

`isPickingOrderComplete`'s javadoc justifies the non-locking reads with:

> *"At least one caller evaluates completeness while already holding a Pickingorder lock —
> `MobilePickingService.rapidPickingScanSource` calls `confirmPick` ... and then decides completeness —
> so taking a Customerorder lock here would be a Pickingorder-before-Customerorder acquisition ..."*

**`rapidPickingScanSource` never calls either new helper.** It is P-8 — the gate that was left raw. The
cited witness does not exist.

**The design conclusion is still right**, via a different and genuinely existing path:
`getPickingOrderPositionsInfo` takes `pickingorderRepository.findByIdForUpdate(pickingOrderID)` and then
calls `findDemandCancelledPickLineIds(poPositions)` — a real Pickingorder lock held across the chain load.
So: **keep the non-locking design, fix the citation.** Same sentence appears verbatim in commit
`af403931`'s body and in plan §12.

This is also the sharpest evidence for §1.2: the author **looked directly at** `rapidPickingScanSource`,
reasoned about its lock behaviour, used it as the load-bearing justification for the whole non-locking
design — and did not make its gate demand-aware, nor note why not.

---

## 6. Summary of findings

| # | Finding | Severity | Cost to close |
|---|---|---|---|
| **J-1** | **P-8 `rapidPickingScanSource`'s early-return completeness loop is neither demand-aware nor excluded.** In the plan's in-scope set (§0.2 B1–B8), matches the plan's stated rule (§2.2) and the exact shape it names. The commit substituted a narrower rule ("promotes a Pickingorder to PICKED") which cannot see it, without flagging the substitution | **High** — blocks | one `isPickingOrderComplete` call + a test, **or** an explicit, reasoned exclusion in-code and in §12 |
| **J-2** | **C4 not updated** — `CustomerorderService.cancelOrder`'s deferred-`else` ⚠ comment still asserts "NO TERMINAL PATH", "cannot run until every line is already PICKED", and "`isDemandCancelled` does NOT treat this flag as cancelled demand". Three now-false claims at the site that sets the flag. The plan's §0.3 names this exact omission as the repeated failure mode | **High** — blocks | one comment edit (adds a third file to the PR) |
| **J-3** | **The non-locking justification cites a caller that does not exist** (`rapidPickingScanSource`) — in `src/main` javadoc, in the commit body, and in plan §12. Conclusion correct; witness wrong. Real witness is `getPickingOrderPositionsInfo` (`findByIdForUpdate` → `findDemandCancelledPickLineIds`) | **Medium** | swap the cited method in three places |
| **J-4** | **`demandCancelled` (C6) and `findDemandCancelledPickLineIds` have no API test.** `grep -rn "demandCancelled" src/test` → 0 hits. The cross-repo contract holds by inspection only; the three `isPickingOrderComplete` hits are stubs, not coverage | **Medium** | one assertion on `getPickingOrderPositionsInfo`'s map |
| **J-5** | **P-3 dropped silently.** In §0.2's in-scope block; out under the plan's own rule; made *less* reachable by the fix | **Low** | one comment |
| **J-6** | **`anyPicked`'s exclusion comment answers a different question than laneB's P-6 finding** (open-line direction vs. `CANCELED(800) >= PICKED(600)` narrowing). Conclusion "leave it raw" is right either way | **Low** | one sentence |
| **J-7** | plan §12's *"no `previousPickingPosition` mutation, so those two are the whole set"* is true by mutation **name** while `nextPosition`/`previousPosition` land unfiltered. Pre-existing, out of C5/C5b scope | **Low / note** | reword |

### What is solidly right — stated so the FAIL is not read as a verdict on the whole change

- Both halves of Fix B are in one commit; neither can ship alone. Trigger restored null-safely.
- Six of eight gates, including the repository-derived `confirmPick` gate no grep finds — that one was
  genuinely derived and it is the commonest completion path.
- Three of four ⚠ sibling comments updated, and the C1b javadoc correctly rewritten to **state the chain**
  instead of asserting a count (which is what the plan asked for, and it is a real improvement).
- The AC-5 IT carries both the positive and the over-reach case, asserts the outbox row, and has private
  H2 DB names.
- The mobile half widens at both sites, the field name matches exactly, every emitted row carries it, and
  I independently mutation-killed all four directions with clean per-site separation.
- The undesigned I-5 reassignment is correct and correctly scoped to the one site that needs it.
