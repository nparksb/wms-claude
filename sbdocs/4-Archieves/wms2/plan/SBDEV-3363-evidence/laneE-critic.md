# SBDEV-3363 lane E — adversarial critic (consensus round)

**Reviewed:** `SBDEV-3363-deferred-cancel-terminal-path.md` (draft, 2026-09-15) against
`wms2-api` `origin/develop` @ `9e294d4b7fa1a1ce41eca69a6987a5fffa0f2bcc` and `wms2-mobile-ui`
`origin/develop`. All code quoted via `git show origin/develop:<path>`; no working tree was read.
Live DB probes run 2026-09-15 against all six reachable v2 tenants.

---

## Verdict

**Do not send this plan to the TDD gate as written.** Fix A, exactly as specified in §3.1, will
**corrupt a live order on `wms2-wineco-dev` that the plan itself names by id in §8.1** — CO
`585000351`. The plan spotted the reroute and drew the wrong conclusion from it: it treated
"this order takes a different arm today" as a *test-coverage* note rather than as a *defect the
fix introduces*. Everything downstream of that (the §3.1 filter-vs-guard argument, the §9 risk row
that calls the hazard "pre-existing, zero instances", the §8.2 mutation table) is built on the same
blind spot.

The plan's factual core is otherwise unusually good. Seventeen load-bearing claims were re-derived; **thirteen
held exactly**, and the four that failed are listed first below (§"Clean verdicts", below). The defect is not sloppiness; it is that the
blast-radius analysis asked *"who calls these two methods?"* and never asked *"which orders change
branch?"*.

Severity counts: **2 Critical · 2 High · 7 Medium · 5 Low** (one High withdrawn — the plan
fixed it mid-review; see H-3).

---

## CRITICAL

### C-1 — Fix A flips a PICKED pick line carrying `amountpicked = 1.0` to CANCELED, on a live order the plan names

**Claim being attacked.** §3.1: *"Behaviour of relaxed A2 on the stranded shape — traced, it is a
near-no-op. Its work body is gated on `if (pickingPosition.getState() < WmsConstants.State.PACKED)`,
which a line at 800 never enters … **So A2 needs no early return.**"* — and §9's risk row:
*"MIXED order … **Pre-existing** (`< PACKED` vs `< PICKED` divergence), zero instances on all six
tenants. Out of scope — F1."*

**Both are false.** The trace is correct *only for a pick line at 800*. It was taken from laneC,
which traced the stranded pair and nothing else, and the plan generalised it into a statement about
the guard. The plan then, in §8.1, correctly identifies a third order that Fix A reroutes —
and describes it as *"takes a different arm today that works"* without noticing that Fix A moves it
**off** that working arm onto one whose bound is wrong for it.

**Measured, 2026-09-15.** The complete estate-wide population of orders Fix A reroutes — orders with
`co.state <> 800` owning at least one `customerorder_position.state = 800` — is **three rows, all on
`wms2-wineco-dev`**:

| co_id | co_state | mfc | pcs | cop_state | pp_state | amountpicked | picktounitload_id | po_state |
|---|---|---|---|---|---|---|---|---|
| 28848660 | 200 | true | false | 800 | **800** | 0.0000 | NULL | 700 |
| 28857575 | 200 | true | false | 800 | **800** | 0.0000 | NULL | 700 |
| **585000351** | 200 | false | **true** | 800 | **600 PICKED** | **1.0000** | **585000950** | 700 |

Zero on `wms2-hydra` PRD, `c1wh-shipitez-uat`, `nywh-hydra-uat`, `nywh-shipitez-uat`,
`wsl-wineco-uat`. Each zero carries a positive control (PRD: 18 cancelled positions over 8 orders,
all 8 themselves at 800; c1wh UAT: 3,504 / 1,006, all at 800; wsl UAT: 52,674 / 11,532, all at 800),
so these are true zeros, not a broken instrument.

**Trace of Fix A on `585000351`, step by step against `origin/develop`:**

1. `cancelOrder` — `isAlreadyCancelled` false (co 200); club block N/A; `isShippedOrPastCancellationBoundary`
   false; `isPackedOrPalletized` false; the A3 precedent
   `anyMatch(position.getState() >= PACKED && position.getState() < CANCELED)` is false (the only
   position is at 800).
2. `canOrderPositionBeCancelled(cop @ 800)` **with the §3.1 conjunct**: entry guard
   `800 >= 650 && 800 < 800` → false, passes. Regular-picking arm:
   `pickingOrder.getState() (700) >= 650 && 700 < 700` → false;
   `pickingPosition.getState() (600) >= 650` → false. → **returns `true`.**
   *Today it returns `false`, and the order takes the `else` branch → `pcs == true` →
   `cleanUpCancelledOrder`, which works.*
3. True branch → `cancelOrderPosition(cop @ 800)` with the same conjunct. Entry guard passes;
   validation loop passes. Work loop:

   ```java
   for (PickingorderPosition pickingPosition : pickingPositions) {
       if (pickingPosition.getState() < WmsConstants.State.PACKED) {     // 600 < 650  →  TRUE
           ...
           cancellationLogService.recordCancellation(...);
           if (pickingPosition.getPickfromstockunitId() != null) { ... } // null — skipped
           pickingPosition.setState(WmsConstants.State.CANCELED);        // 600 → 800
           pickingPosition.setPickfromstockunitId(null);
   ```
   `CustomerorderPositionService.java`, `cancelOrderPosition`.
4. Then, in the same block, `allTerminal` is now true and `allCanceled` is true, so
   `pickingOrder.setState(allCanceled ? CANCELED : FINISHED)` **demotes PO `585000650` from
   FINISHED(700) to CANCELED(800)**.

Step 3 is exactly the outcome `cancelOpenPickLines` exists to prevent, in the words of its own
javadoc:

> **`Bounded to {@code state < PICKED}.`** A PICKED line's stock is already in the tote —
> `pickfromstockunit_id` is null by then, the source reservation having been consumed — and
> **flipping it to CANCELED would make the tote's contents unattributable.**

`585000700` matches that fingerprint precisely: state 600, `pickfromstockunit_id` NULL,
`amountpicked = 1.0000`, `picktounitload_id = 585000950`. Fix A routes it into the one cancellation
path in the codebase that uses `< PACKED` instead of `< PICKED`.

This is also not a frozen population. `OrderRestController` exposes
`@PostMapping(value = "/cancelPositions", …) public ResponseEntity<Object> cancelPositions(…)`, a
position-level cancel that is the natural producer of "order open, some positions CANCELED".
The shape itself is common — on `wsl-wineco-uat`, **3,023 pick lines sit at PICKED(600) under a
CANCELED(800) CO position** (plus 13 at 700). They are invisible to Fix A today only because their
orders are already at 800 and `isAlreadyCancelled` returns first. One re-sent OMS cancel against an
order in that shape before it reaches 800 and the damage repeats.

**What to change.**
- Delete the §3.1 sentence *"So A2 needs no early return"* and the §9 "pre-existing / zero instances"
  row; both are disproved by `585000351`.
- Do not adopt the two-guard edit as specified. See M-6 / §"Priority 2" for the shape I recommend
  instead (skip already-CANCELED positions in both of `cancelOrder`'s loops, leaving
  `CustomerorderPositionService` untouched), which is the only option surveyed that leaves
  `585000351`'s pick line at 600.
- Whatever shape is chosen, add an acceptance test that pins **`pp.state` stays 600 and
  `po.state` stays 700** for the `585000351` fixture. That assertion is the one that separates a
  correct fix from this one, and no test in §8 currently makes it.

---

### C-2 — Fix D's unique index converts a bookkeeping duplicate into a rolled-back cancellation, contradicting `recordCancellation`'s stated design

**Claim being attacked.** §3.4: the partial unique index on `pickingorder_position_id`, justified by
*"No backfill risk: 24 rows estate-wide … **zero** duplicates on any key."*

`CancellationLogService.recordCancellation` is explicit that a failure here must never abort the
caller:

> ```java
> // Fail open: a row that cannot be resolved is still recorded with reversalRequired = true,
> // so the reversal is never lost. Throwing here would abort the cancellation itself — this
> // method is Propagation.MANDATORY and runs inside the caller's cancel transaction — which
> // would trade a bookkeeping gap for a failure of the primary operation.
> ```

A `UNIQUE` index does exactly what that comment forbids. `recordCancellation` ends
`return logRepository.save(log);` with no dedup, no `ON CONFLICT`, no existence check; the method is
`@Transactional(propagation = Propagation.MANDATORY)`, so a `DataIntegrityViolationException` at
flush rolls back the **caller's** cancel transaction. The plan adds the constraint and never mentions
that it inverts the fail-open contract three files away.

And the duplicate path is documented as *reachable*, in `cleanUpCancelledOrder`'s own header:

> *"Re-running the body re-enters `cancelOpenPickLines`, whose `recordCancellation` call sits ABOVE
> its `state < PICKED` bound while the flip to CANCELED sits BELOW it — so a line at or above PICKED
> is logged and never made terminal, and every subsequent pass logs it again…"*

A line logged-but-not-flipped is skipped on re-entry only by the `state == CANCELED → continue`
test, which by construction it fails. Today a method-entry guard is the sole thing standing between
that and a second row. After Fix D, the second row is a 500 on the cancel instead.

Second exposure: SBDEV-3316's reversal surface. A cancellation that is **reversed** and whose line is
later re-cancelled needs a second legitimate log row for the same `pickingorder_position_id`. The
index makes that impossible, and the failure mode is an aborted cancel rather than a rejected insert.
The plan does not consider re-cancellation at all.

**On the evidence offered:** "zero duplicates on any key" over **24 rows** (dev 8 · PRD 16 · four
UATs 0) cannot distinguish *impossible* from *has not happened yet*, and no positive control is
offered for that zero. This is the plan's weakest zero-claim and it is load-bearing for a schema
constraint.

**What to change.** Either (a) make `recordCancellation` idempotent first — look up by
`pickingorder_position_id` and skip/update rather than insert, so the constraint can never surface as
an exception; or (b) ship the **column** now and the **unique index** as a separate follow-up once
(a) exists; or (c) make it a non-unique index and enforce uniqueness in the service. Do not ship an
insert-only writer behind a unique constraint inside a `MANDATORY` transaction.

---

## HIGH

### H-1 — §2.1's "blast radius" answers the wrong question

§2.1's *Blast radius* paragraph was strengthened during this review and is now genuinely rigorous:
four named instruments, each with its blind spot, a residual-blind-spot line, a positive control on
the resource grep, and the useful new conclusion that *"`cancelOrderPosition` has no HTTP route of
its own — relaxing A2 changes no API error contract."* I re-derived all four and they hold.

**And all four answer the same question — the wrong one.** Every instrument asks *"can something
else call these methods?"* None asks *"which orders now take a different branch?"* — and the second
question is where the defect lives. A guard relaxation's blast radius is a **population**, not a call
graph. Strengthening the call-graph sweep from two instruments to four makes the section more
convincing without moving it any closer to C-1; if anything the added rigour makes the gap harder to
notice, because §11 row 1 ("All call sites enumerated ✓") now looks comprehensively discharged.

The plan has no census of that population anywhere. C-1 supplies it (3 orders, 1 damaged). §2.1
should carry it, with the derivation and the positive controls, and §11 row 1 ("All call sites
enumerated ✓") should not be read as covering it.

### H-2 — F2 is pulled into scope on a hazard that cannot occur; the stated justification is wrong

§3.2 declares the `finishPickingOrder` write-ordering fix **mandatory**: *"`orderState` is computed
from the lines, then `cleanUpCancelledOrder` → `finalizePickingOrderIfTerminal` **writes**
`pickingOrder.setState(...)`, then `pickingOrder.setState(orderState)` **overwrites it from the stale
view**. Harmless today only because `cancelOpenPickLines` is bounded to `< PICKED`. **Fix B makes the
middle step hot.** … Leaving the ordering as-is while making step 2 hot would manufacture this
ticket's own stranded shape in new code."*

The overwrite is real. The **divergence is not**, before or after Fix B — the two values provably
coincide, and Fix B does not change the bound the plan says makes it harmless.

Proof. Both quantities range over `{CANCELED, FINISHED}` only.
- `orderState` is `FINISHED` iff some line satisfied `state >= PICKED && state != CANCELED` in the
  validation loop; otherwise it keeps its `CANCELED` seed.
- `finalizePickingOrderIfTerminal` writes `FINISHED` iff `allMatch(state >= FINISHED)` and
  `!allMatch(state == CANCELED)` — i.e. some line is at exactly FINISHED(700).
- The only mutation between the two is `cancelOpenPickLines`, which moves lines **from `< PICKED` to
  CANCELED** and nothing else.

`finalize = CANCELED` while `orderState = FINISHED` would require a line that was `>= 600, != 800` to
have become 800 — impossible, the flip is bounded to `< 600`. `finalize = FINISHED` while
`orderState = CANCELED` requires a line at 700, which satisfies `>= PICKED && != CANCELED` and so
would already have set `orderState = FINISHED`. Both directions are unreachable.

**Fix B(a) re-admits `markedforcancellation` as an `isDemandCancelled` trigger and Fix B(b) makes
callers invoke `finishPickingOrder`. Neither touches `cancelOpenPickLines`' `< PICKED` bound.** So
"Fix B makes the middle step hot" makes the *path* hot without making the *divergence* possible.

**This is scope creep dressed as prudence** — which is exactly what the plan accuses the alternatives
of. The change is cheap and defensible as hygiene (a computed-then-overwritten value is a latent
trap the moment anyone widens that bound), but it must not be sold as **mandatory**, and the
sentence *"would manufacture this ticket's own stranded shape in new code"* should be deleted or
replaced with an honest "latent; becomes real if the `< PICKED` bound ever widens".

If it is kept, it needs its own mutation check — and there isn't one that can pass, because no test
can distinguish the two orderings today. A change no test can grade does not belong in a T3 fix that
already carries a Critical.

### H-3 — WITHDRAWN (plan revised mid-review)

My original H-3 was that §0.3 C5 named only `store/picking.js:469` and dropped laneD's warning about
`nextPickingPosition` (`store/picking.js:134`). **The plan's §3.3 now carries it**, and goes further
than I would have: it widens rather than replaces the test
(`p.pickStatus !== CANCELLED_PICK_STATUS && !p.demandCancelled`) so the filter degrades safely in
*both* deploy directions, and states that `nextPickingPosition` must be widened identically. That is
the correct call and it is better than the replace-the-key shape I was going to recommend — an
API-behind-UI deploy under a pure replacement would have restored the exact SBDEV-3319 symptom.

A residue of the edit remains and is now filed as **M-7** below.

---

## MEDIUM

### M-1 — §8.2 mutation row 3 is vacuous: the stated assertion cannot kill the stated mutant

| Assertion | Mutant | Expected kill |
|---|---|---|
| A2 band upper bound | `< CANCELED` → `<= CANCELED` | *"a `[650,800)` position must still be refused"* |

Guard after the fix: `state >= 650 && state < 800 → throw`. Mutate to `state <= 800`:
- for `state ∈ [650, 800)` — original throws, mutant throws. **Identical.**
- for `state == 800` — original passes, mutant throws. The only observable difference.

So a test asserting *"a `[650,800)` position is still refused"* is green under both, and PIT will
report the mutant SURVIVED while the plan's table records it as covered. The mutant is in fact killed
by the **same** test as row 2 (the end-to-end cancel on the 800 fixture), making row 3 redundant
rather than additional.

The assertion the plan clearly *wants* — that the lower bound did not move — is killed by a different
mutant, `>= PACKED` → `> PACKED`, which the table does not list. Replace row 3 with that one.

This matters beyond bookkeeping: rows 2 and 3 are the plan's stated defence against the "one-site
fix looks like a fix" failure mode, and one of the two is inert.

### M-2 — the plan drops laneD's finding that `isDemandCancelled`'s javadoc is *already* wrong

LaneD: *"⚠ **Its javadoc is wrong and this ticket should fix it.** The javadoc opens 'TWO levels, and
they are not redundant' and then lists two bullets … omitting the `coPosition` check that sits in the
body between them. The body has three. … **State the rule, not the count.**"*

Verified verbatim on `origin/develop`:
```java
 * <p>TWO levels, and they are not redundant — each is reachable without the other:
 * <ul>
 *   <li>picking position only — …</li>
 *   <li>customer order state only — …</li>
 * </ul>
```
while the body has three `return true` triggers.

§0.3's sibling sweep lists C1–C4 and this is none of them. C1 is *"re-admit `markedforcancellation`"*
— which will make the count **four** while the javadoc says two. Shipping AC-5 without touching this
javadoc leaves a comment that is wrong by two, in the method the whole ticket turns on, in a file
whose own comments record this sentence having drifted twice before.

Add it to §0.3 as C1b, and follow laneD's instruction: state the chain (`pick line → CO position →
CO → flag`), do not assert an integer.

### M-3 — the two existing guard pins keep `@DisplayName`s that Fix A makes false

```java
@DisplayName("should return false when position is packed or beyond")
void shouldReturnFalseWhenPositionPackedOrBeyond() { testPosition.setState(WmsConstants.State.PACKED); … }

@DisplayName("should throw exception when position is packed or beyond")
void shouldThrowExceptionWhenPositionPackedOrBeyond() { testPosition.setState(WmsConstants.State.PACKED); … }
```
`CustomerorderPositionServiceUnitTest`. The plan correctly identifies both as vacuous (§8.1 — a clean
verdict, see below) but then leaves them alone. After Fix A, "**or beyond**" is false: 800 is beyond
PACKED and is no longer refused. By the plan's own C2–C4 rule — *"leaves the codebase asserting
something false about its own behaviour"* — these two names must be narrowed to
`whenPositionInPackedBand` / `[650,800)`, and each should gain a sibling case at 800 asserting the
new answer.

### M-4 — the AC-1 test as specified has no host, and the plan does not say where it goes

§8.1: *"The acceptance test must exercise `cancelOrder` with a **real** `CustomerorderPositionService`
against the stranded shape."* Correct requirement (see Clean verdicts). But
`CustomerorderServiceUnitTest` is built as:

```java
@Mock private CustomerorderPositionService customerorderPositionService;
…
@InjectMocks private CustomerorderService customerorderService;
```

with ~30 `@Mock` collaborators. A real `CustomerorderPositionService` cannot coexist with
`@InjectMocks` — it needs either a hand-built `new CustomerorderService(…)` with all ~30 arguments,
or a `@Spy` on a hand-built `new CustomerorderPositionService(…)` with its 9 repositories, or a
full-context lane. The plan mandates the shape and never names the mechanism, so the gate will
discover the obstacle and is likely to take the cheap exit — which is the direct unit test the plan
just ruled out.

Given C-1, the right answer is almost certainly the **Testcontainers lane**: the assertions that
matter (`pp.state` stays 600, `po.state` stays 700, exactly one `customerorder_cancellation_log` row)
are DB-state assertions on a three-entity fixture. §8.3 sends Testcontainers only at the migration.
Name the lane and the fixture in §8.1.

### M-5 — §6 row 8 leaves lock ordering as a preference, not a decision

*"the helper may load `Customerorder` via `findByIdForUpdate`. **Preserve the Customerorder →
Pickingorder → Stockunit order**; prefer a non-locking read in the helper…"*

"May" and "prefer" are not implementable. This matters concretely: `confirmPick` takes
`customerorderRepository.findByIdForUpdate` **then** `pickingorderRepository.findByIdForUpdate`, and
at least one Group-B site runs its completeness predicate *after* `confirmPick` returns, i.e. while
the Pickingorder lock is already held — `MobilePickingService` `rapidPickingScanSource`:
`pickingOrder = pickingorderBusinessService.confirmPick(pickingPosition, pickingorderUnitload, …);`
followed four lines later by the `for (… ) { if (pickingPosition.getState() < WmsConstants.State.PICKED) …`
loop that decides completeness, then `if (pickingOrder.getState() == WmsConstants.State.PICKED)
{ finishPickingOrder(…) }`. A helper that then takes a Customerorder lock is a
Pickingorder→Customerorder acquisition, the inversion `cancelOpenPickLines`' javadoc spends two
paragraphs establishing must not exist. Decide it in the plan: **the helper must use non-locking
reads**, and add an ArchUnit-style or ordering assertion pinning that, in the style of the existing
`InOrder` pins in `PickingorderBusinessServiceUnitTest`.

### M-6 — §3.1's "independently correct" argument is wrong on the merits

§3.1 rejects the tracer's caller-side filter with: *"each guard above is **independently correct**
after the change. Neither depends on the other to state the truth; omitting one is a missed sibling,
not a broken invariant."*

Ask the question the prompt asks: **what does `canOrderPositionBeCancelled(position @ CANCELED)`
mean, and is `true` the right answer?** It means *"can this position be cancelled?"* A position
already at CANCELED cannot be cancelled — there is nothing left to cancel. `true` is not a truth
being stated; it is a lie that happens to route the *order-level* decision correctly while telling
the *position-level* caller to go and cancel something that is already cancelled. The caller obeys —
and that obedience is C-1.

So the plan's own criterion refutes it: after the edit, guard A1 is **not** independently correct.
It is correct only in conjunction with A2 being relaxed too, and even then only for positions whose
pick lines happen to be at 800 rather than 600. The "two independently correct edits beat two
mutually dependent `continue`s" argument is a rationalisation, not a derivation — and independence is
worth nothing when one of the two independently-correct edits is independently *wrong*.

(The plan **is** right about one half of this: see the Clean verdict on `coPositions` below.)

### M-7 — §3.3's widening instruction has no row in the file-change summary and no test

§3.3 now says *"`nextPickingPosition` tests the same string and must be widened identically."*
Three other sections were not updated to match:

- §0.3 **C5** still describes the scope as the single expression
  `results.filter(position => position.pickStatus !== CANCELLED_PICK_STATUS)`;
- §4 still has one mobile row: `wms2-mobile-ui/store/picking.js` → *"filter on `demandCancelled`"*;
- §8.3 still pins one Jest case: *"a row whose `demandCancelled` is true but whose `pickStatus` is
  not `'Cancelled'` must disappear"* — a **display-rule** assertion only.

So the landing rule is mandated in prose and graded nowhere. Given the plan's own reason for widening
it (*"leaving one narrow makes a row unreachable by scroll but still landable by hand"*), the missing
test is the one that would catch exactly that. Add a second Jest case driving
`nextPickingPosition` over a list whose only non-`'Picked'` row carries `demandCancelled: true`, and
assert `currentPosition` does **not** land on it; and update C5 and §4 so the gate sees two edits.

Worth pinning both directions in that test, since §3.3's whole point is two-way degradation: a row
with `pickStatus === 'Cancelled'` and `demandCancelled === undefined` (old API) must still be skipped.

---

## LOW

### L-1 — `@Transactional(readOnly = true)` on the helper is inert
§7 row 3: *"`isPickingOrderComplete` is a read; mark it so."* Every caller invokes it from inside an
existing read-write tenant transaction; with default `REQUIRED` propagation the participating
transaction keeps the outer `readOnly` flag. The annotation documents intent and changes nothing.
Fine to add — do not record it in §7 as a satisfied constraint, and do not write a test asserting it
(cf. the known trap that transactional tests are blind to `propagation`/`readOnly`).

### L-2 — the A6 guard swaps an exception for a silent skip, and misses the adjacent `get(0)`
§3.1's A6 sketch wraps the RAPID block in `if (!pickingPositions.isEmpty()) { … }`. Two notes:
(a) that converts an `IndexOutOfBoundsException` into a silent skip of the tote/unitload teardown —
correct for an empty list, but say so, because "guard the `get(0)`" reads as bounds-checking when it
is a behaviour choice; (b) the line immediately above, `CustomerorderPosition customerOrderPosition =
coPositions.get(0);`, is unguarded against an empty `coPositions` and is not mentioned. That one is
genuinely pre-existing, but it is in the hunk being edited.

### L-3 — `components/picking/pick.vue:345` reads `pickStatus` and tests only `'Picked'`
```js
const status = this.currentPosition.pickStatus
if (status != 'Picked') return true
```
`activePick()`. It is not a cancellation filter, so it is not broken by C5 — but it is the third
client-side consumer of the field the plan is deprecating as a cancellation signal, and neither the
plan nor laneD lists it. Worth one line in §0.3 stating explicitly that it is *out* of scope and why.

### L-4 — claim-discipline flags (completeness words without a named method or blind spot)
Each of these uses *every / only / all / no / exactly / none* and does not name its derivation or its
blind spot at the point of use:
- §1 *"Each stranded picking order holds **exactly one** position"* — true (verified), method unstated.
- §2.2 *"**All eight** Group-B gates have the shape …"* — the shape is not uniform: `MobilePickingService`
  has four `noneMatch`/`anyMatch` sites (`:242`, `:266`, `:398`, `:737`) plus at least three
  hand-rolled `for` loops that decide the same thing by early return (`:341–348`, `:1121–1127`,
  `:1352–1357`) — the last two are "find the next unpicked line" loops where *falling through* is the
  completeness verdict, a shape no `noneMatch`/`allMatch` grep finds. §4 says *"7 predicate
  call-sites"*; §0.2 says P-1…P-6, P-8; laneB says eleven. Three numbers, one rule. State the rule ("every site that decides whether a picking order
  is complete") and derive the set in the gate, per the repo's own standing instruction three files
  away (*"State the rule, not the enumeration"*).
- §3.4 *"**zero** duplicates on any key"* over 24 rows — no positive control. See C-2.
- §3.5 *"the idempotency key … is **free** for both orders (measured: zero `outbox_message` rows for
  either aggregate)"* — a zero with no positive control that the query finds rows when they exist.
- §9 *"zero instances on all six tenants"* — **disproved**; see C-1.
- §2.3 / §0.3 *"`isDemandCancelled` has **three** triggers"* — true today, and the plan is about to
  make it four; see M-2.

### L-5 — §8's baseline supersedes an older recorded one; say so in the plan
§8 reports `surefire 6629/0/0/1`, `failsafe 409/0/0/31`, **BUILD SUCCESS**, now joined by mobile Jest
32 suites / 395 tests green. The standing baseline note for this repo still records *26 red / 132
skipped* with `mvn verify` aborting before the IT lane. The plan's method — capture on the ticket
worktree at the base SHA, via the same `mvn -B -ntp clean verify` CI runs — is the right one and
supersedes the older note; both lanes measured green is the stronger evidence. **No finding against
the plan**; the ask is one sentence in §8 recording that the older baseline is superseded, so the gate
does not "reconcile" it back, and a matching note that the mobile baseline was re-measured against
fresh `origin/develop` (which discharges §5.1's `ef1dc76` caveat — mark that row ✅ rather than ⚠).

---

## Clean verdicts — probed claims that held

Stated explicitly because a passing probe is a result.

**The four that failed**, for contrast: §3.1 *"A2 … near-no-op … needs no early return"* (C-1);
§9 *"zero instances on all six tenants"* (C-1); §8.2 row 3's expected kill (M-1); §2.2 *"All eight
Group-B gates have the shape …"* (L-4). Everything else below held.

1. **`cancelOrder`'s true branch calls `cancelOrderPosition` for every position, and A2 throws at
   800.** Confirmed: `for (CustomerorderPosition customerOrderPosition : coPositions) {
   customerorderPositionService.cancelOrderPosition(customerOrderPosition); }` sits unconditionally on
   the `orderCanBeCancelled` arm, and `cancelOrder` is
   `@Transactional(value = "tenantTransactionManager", rollbackFor = {BusinessException.class, FacadeException.class})`,
   so the A1-only fix does roll the heal back. **LaneC's central finding is correct and the plan
   inherits it correctly.**
2. **Exactly one production caller each.** `git grep` over `origin/develop -- src/`:
   `canOrderPositionBeCancelled` → one non-test, non-comment call site (`CustomerorderService.java:805`);
   `cancelOrderPosition` → one (`CustomerorderService.java:853`). All other `src/main` hits are
   javadoc/comment text. The class declares no `implements`/`extends`. Holds.
3. **No Group-B completeness predicate answers wrongly about a CANCELED(800) line.** Every one tests
   `state < PICKED(600)` (four `noneMatch`, the `countByPickingorderIdAndStateLessThan(…, PICKED)` in
   `confirmPick`, the hand-rolled loops); 800 clears all of them. The plan's §0.2 correction of the
   ticket's premise is right, and its reason for changing them anyway ("because of what they *gate*")
   is the right reason.
4. **`isDemandCancelled` has exactly three triggers**, in the order the plan states (pick line, CO
   position, CO). Confirmed by reading the body. (Its *javadoc* says two — M-2.)
5. **The mobile filter keys only on the pick line's own state.** `store/picking.js:469`
   `results.filter(position => position.pickStatus !== CANCELLED_PICK_STATUS)`, and
   `MobilePickingService` emits `map.put("pickStatus", WmsConstants.State.getCodeText(pos.getState()))`
   over the `PickingorderPosition`. Holds. (A second consumer exists — H-3.)
6. **The existing pins are vacuous.** `shouldReturnFalseWhenPositionPackedOrBeyond` and
   `shouldThrowExceptionWhenPositionPackedOrBeyond` both set `State.PACKED` exactly and never exceed
   it → both stay green through Fix A. And `CustomerorderServiceUnitTest` stubs
   `canOrderPositionBeCancelled` on a plain `@Mock` (no `@Spy`, no `CALLS_REAL_METHODS`), so it cannot
   observe the helper body. I counted the stubs: **20**, exactly as §8.1 claims.
7. **"Do not touch `coPositions` — the OMS payload needs every position."** Correct and load-bearing:
   the outbox payload is built as `coPositions.stream().map(position -> { … opDto.setUniqueId(position.getExternalid()); … })`
   after the cancel loop. A naive filter of that list *would* truncate the OMS cancel payload. This is
   the strongest argument in §3.1 and it survives — it rules out the *naive* filter, though not the
   `continue`-in-both-loops shape, which leaves the list intact.
8. **Flyway `V2.2.31` is free.** Highest on `origin/develop` is `V2.2.30__outbox_message_lane.sql`;
   sweeping every `refs/remotes/origin/*` ref yields nothing above `V2.2.30`. The plan's instruction
   to re-run the sweep immediately before merge is correct and should be kept.
9. **PRD is unexposed.** 189 customer orders, 18 cancelled positions across 8 orders, all 8 at state
   800 → zero re-route population, zero stranded. True zero with a positive control.
10. **§2.1's four revised blast-radius instruments** (added mid-review) — all four re-derived and all
    four hold: one non-comment call site per method; `CustomerorderPositionService` injected in exactly
    one class (`private final CustomerorderPositionService customerorderPositionService;` in
    `CustomerorderService`); no `implements`/`extends` on the class; and no controller references it,
    so **`cancelOrderPosition` has no HTTP route** and relaxing A2 changes no API error contract. The
    residual-blind-spot line (runtime string/AOP/XML dispatch, unswept) is the honest caveat. Good
    work — the limitation is what the instruments are *pointed at*, not their rigour (H-1).
11. **§3.3's two-way-degradation filter** (added mid-review) is correct and is a better answer than
    the replace-the-key shape: with an API-behind-UI deploy, `!p.demandCancelled` alone would leave
    `demandCancelled === undefined` truthy-negative for a genuinely cancelled line and restore the
    SBDEV-3319 symptom. The conjunction `p.pickStatus !== CANCELLED_PICK_STATUS && !p.demandCancelled`
    degrades safely in both directions. Verified against `store/picking.js:469` on
    `wms2-mobile-ui origin/develop`.

---

## Direct answers to the five questions

**1 · Is any factual claim wrong?** Yes — two, both load-bearing:
- §3.1 *"A2 … is a near-no-op … So A2 needs no early return"* — false for a pick line at PICKED(600),
  which is the third order the plan itself names (**C-1**).
- §9 *"MIXED order … pre-existing … zero instances on all six tenants"* — false; there is one
  instance, `585000351`, on `wms2-wineco-dev` (**C-1**). Separately, §8.2 row 3's expected kill is
  unachievable (**M-1**), and §2.2's "all eight Group-B gates have the shape …" is not uniform (**L-4**).
  The remaining nine probed claims held (above).

**2 · Does §3.1's decision survive scrutiny?** No. Its *evidence* is half right — the `coPositions`
trap is real and does kill the naive filter (Clean verdict 7). Its *reasoning* is a rationalisation:
"independently correct" is asserted, not derived, and is false, because
`canOrderPositionBeCancelled(position @ CANCELED) == true` is the wrong answer to the question that
method asks, and acting on it is the mechanism of C-1 (**M-6**). Neither surveyed option is right.
**My recommendation is a third shape** — skip already-CANCELED positions in *both* of `cancelOrder`'s
loops (`if (position.getState() == WmsConstants.State.CANCELED) continue;`), leaving `coPositions`
un-filtered for the payload and leaving `CustomerorderPositionService` **untouched**. That encodes the
actual invariant — *an already-terminal position neither blocks the order cancel nor needs cancelling
again* — keeps `canOrderPositionBeCancelled` answering truthfully about positions that still need
cancelling, preserves the OMS payload, and is the only option that leaves `585000351`'s PICKED line at
600. The plan's objection (two `continue`s are mutually dependent) is true and is not a problem: the
end-to-end `cancelOrder` test §8.1 already mandates covers both, and mutation rows 1 and 2 kill both
independently.
*Caveat to weigh before adopting:* under the `continue` shape, `585000351` gets **no**
`recordCancellation` row from this path, where `cleanUpCancelledOrder` writes one today with
`reversal_required = true`. Decide deliberately whether that row should be preserved (e.g. by logging
the skipped position explicitly) rather than losing it as a side effect.

**3 · Is the AC-1 test adequate?** The plan's *diagnosis* is right and verified (Clean verdict 6): a
direct unit test does pass on a one-site fix, so end-to-end is genuinely required. The *specification*
is incomplete in three ways: it names no host and the obvious host cannot accommodate it (**M-4**); it
asserts nothing about the pick line, which is the assertion that would have caught C-1; and one of its
five mutation rows cannot kill its mutant (**M-1**). Rows 1, 2 and 4 do produce attributable kills (an
assertion failure on `co.state`, a `BusinessException` with a matched message, and an assertion on the
finish path). Row 5's expected kill is stated backwards — inverting the demand-aware arm makes
`finishPickingOrder` fire **too early** and throw `BusinessException("Picking position …")`, not "not
called"; restate it so the grader knows what red to expect. The plan's own rule — *"A red arriving as
`NoSuchMethodException` or an NPE in setup is not a kill"* — is good and should stay.

**4 · Is the scope line in the right place?** No. **F2 is in and should be out, or at least
downgraded** (**H-2**): the hazard it fixes is unreachable, the justification for calling it mandatory
is wrong, and no test can grade it. **F1 out is right** (`forceCancelOrder`'s `allMatch(>= FINISHED)`
sits in a branch the code documents as unreachable; leave it as a finding). **F3 out is right** (a
self-healing sweep is genuinely a separate ticket, correctly *proposed not filed* per T3 policy).
What is missing from scope is not another finding — it is C-1 and C-2, both of which are regressions
the plan's own changes introduce and therefore cannot be deferred.

**5 · What does the plan miss?** C-1 (the damaged live order), C-2 (unique index vs a fail-open
`MANDATORY` writer), H-1 (population blast radius), M-2 (the already-wrong javadoc laneD flagged and
the plan dropped), M-3 (two `@DisplayName`s the fix falsifies), M-4 (no host for the mandated test),
M-5 (lock ordering undecided), M-7 (the widening instruction is ungraded), plus the Lows. Deploy order
is now handled **well** — §3.3's two-way-degradation filter is better than what I was going to
recommend, and §5.1's UI-before-API reasoning is correct. Nothing in §6/§7 is wrong beyond L-1 and
M-5.

---

*Lane E, 2026-09-15. All DB figures measured this date; all code quoted from
`wms2-api` `origin/develop@9e294d4b` and `wms2-mobile-ui` `origin/develop`.*
