---
title: "Deferred cancel has no terminal path that works during picking"
ticket: "SBDEV-3363"
ticket_url: "https://app.clickup.com/t/868m5fefc"
type: "bugfix"
priority: "normal"
status: "implemented — all scope MERGED and on dev; Fix E CLOSED as not-required (the stranded orders are dev test data); ticket at on dev"
project: ["wms2"]
version: "v2"
requester: "Nam Park"
created: "2026-09-15"
updated: "2026-09-15"
db_verified: true
related:
  - "SBDEV-3332"
  - "SBDEV-3319"
  - "SBDEV-3316"
  - "SBDEV-3362"
  - "SBDEV-3313"
tags:
  - plan
  - cancellation
  - picking
---

# SBDEV-3363 — Deferred cancel has no terminal path that works during picking

**Ticket:** [SBDEV-3363](https://app.clickup.com/t/868m5fefc) · **Tier:** T3 · **Base:** `origin/develop` @ `9e294d4b`
**Worktree:** `.claude/worktrees/wms2-api/SBDEV-3363` on `bugfix/SBDEV-3363-deferred-cancel-terminal-path`
**Evidence:** `SBDEV-3363-evidence/` — `laneA-option4-tracer.md`, `laneB-option3-architect.md`, `laneC-band-sweep.md`, `laneD-mobile-m4.md`

> **Read this first.** Three of the ticket's premises were falsified during pre-investigation. This plan
> works from the corrected ones; §2.0 records what changed so a reviewer does not "fix" it back.

---

## 0. Affected sites (enumeration before drafting)

Derived by three spellings of the state constant (qualified `State.PACKED`, bare static-import `PACKED`,
numeric `650`) plus four predicate instruments — see `laneC-band-sweep.md` §"Derivation method" and
`laneB-option3-architect.md` §1.1 for each instrument's blind spots.

### 0.1 Group A — the CANCELED-band guards (AC-1)

| # | File · quoted anchor | Construct | Same root cause? | In scope? |
|---|---|---|---|---|
| A0 | `CustomerorderService.cancelOrder` · the two `for (CustomerorderPosition customerOrderPosition : coPositions)` loops | the caller that asks A1 and obeys A2 | **this is where the fix goes** | **yes** |
| A1 | `CustomerorderPositionService` · `canOrderPositionBeCancelled` entry, `if (customerOrderPosition.getState() >= WmsConstants.State.PACKED) {` → `return false;` | open-ended band, **the question** | yes — but **not modified**, see §3.1.1 | no |
| A2 | `CustomerorderPositionService` · `cancelOrderPosition` entry, same predicate → `throw new BusinessException("order position is beyond status PACKED. can not be cancelled anymore")` | open-ended band, **the action**; its work loop is bounded `< PACKED`, wider than `cancelOpenPickLines`' `< PICKED` | yes — but **not modified**, see §3.1.1 | no |
| A3 | `CustomerorderService.cancelOrder` · `position.getState() >= PACKED && position.getState() < WmsConstants.State.CANCELED` | half-open band | no — **already correct**, the precedent | no |
| A4 | `CustomerorderService.isShippedOrPastCancellationBoundary` · `getState() >= FINISHED && getState() != WmsConstants.State.CANCELED` | explicit exclusion | no — **already correct**, the precedent | no |
| A5 | `BillofladingService` · `"has already been transferred (state="` · `getState() != null && getState() >= WmsConstants.State.PACKED` | open-ended band | **no** — different question ("is this order terminal?", where CANCELED is correctly a yes; its own comment says so) | no |
| A6 | `CustomerorderService.cancelOrder` · RAPID block, `pickingPositions.get(0)` | newly-reachable `IndexOutOfBoundsException` | consequence of A1 | **yes** (one-line guard) |

### 0.2 Group B — completeness predicates gating `finishPickingOrder` (AC-5 half b)

Eleven sites enumerated in `laneB-option3-architect.md` §1.2. **None answers wrongly about a CANCELED
line** (`CANCELED = 800` is already `≥` every bound they test). They are in scope because of what they
*gate*, not what they answer — see §2.2.

| # | Site | In scope? |
|---|---|---|
| B1–B8 | `MobilePickingService` P-1…P-6, P-8 · `PickingorderBusinessService.confirmPick` P-7 (repository-derived, `countByPickingorderIdAndStateLessThan`) | **yes** — via the single shared helper of §3.2, not eight inline edits |
| B9 | `PickingorderBusinessService.finalizePickingOrderIfTerminal` | no — already cancel-aware; the reference shape |
| B10 | `CustomerorderPositionService.cancelOrderPosition` tail | no — already cancel-aware |
| B11 | `CustomerorderService.forceCancelOrder` · `allMatch(losPickingPosition -> …getState() >= WmsConstants.State.FINISHED)` | **no — declared out of scope**, see §10 finding F1 |

### 0.3 Group C — the trigger, the mobile signal, the log key

| # | Site | In scope? |
|---|---|---|
| C1 | `PickingorderBusinessService.isDemandCancelled` — re-admit `markedforcancellation` | **yes** (AC-5 half a) |
| C2 | `PickingorderBusinessService.assertPickNotCancelled` — its `LOG.warn` and the ⚠ comment above it become false when C1 lands | **yes** (sibling of C1) |
| C3 | `finishPickingOrder` G4 branch ⚠ comment — "Both halves move together, on SBDEV-3332" | **yes** (sibling of C1) |
| C4 | `CustomerorderService.cancelOrder` deferred-`else` ⚠ comment — the fullest statement of the old constraint | **yes** (sibling of C1) |
| C1b | `isDemandCancelled`'s **javadoc** — says *"TWO levels"* and lists two bullets while the body has **three** `return true` triggers; C1 makes it four | **yes** — state the chain (`pick line → CO position → CO → flag`), do not assert an integer |
| C5 | `wms2-mobile-ui` `store/picking.js` — the **filter**, `results.filter(position => position.pickStatus !== CANCELLED_PICK_STATUS)` | **yes** (M-4) |
| C5b | `wms2-mobile-ui` `store/picking.js` — the **landing rule** in `nextPickingPosition`, `…pickStatus !== 'Picked' && …pickStatus !== CANCELLED_PICK_STATUS` | **yes** — widen identically. Its own comment calls it *"defence in depth"*; leaving it narrow makes a row unreachable by scroll but still landable by hand |
| C5c | `wms2-mobile-ui` `components/picking/pick.vue` — `const status = this.currentPosition.pickStatus; if (status != 'Picked') return true` (`activePick()`) | **no** — third consumer of the field, but it is not a cancellation filter; listed so it is not re-found and filed |
| C6 | `MobilePickingService` — `map.put("pickStatus", WmsConstants.State.getCodeText(pos.getState()))` | **yes** (M-4, emit the answer) |
| C7 | `customerorder_cancellation_log` — no `pickingorder_position_id` | **yes** (AC-4) |
| C8 | `CancellationLogService.recordCancellation` — populate C7 | **yes** (AC-4) |

**C2–C4 are the sibling sweep for C1.** Four ⚠ comments across two files encode the SBDEV-3332 decision;
re-admitting the trigger without updating all four leaves the codebase asserting something false about
its own behaviour. That is how this area has already gone wrong three times.

---

## 1. Problem Statement

`CustomerorderService.cancelOrder` defers a cancel it cannot perform by setting
`markedforcancellation = true`. Two customer orders on `wms2-wineco-dev` have been neither cancelled nor
cancellable since **2026-02-06**:

| CO id | number | `co.state` | CO position | pick line | picking order | `mfc` | `pcs` |
|---|---|---|---|---|---|---|---|
| 28848660 | 051483-000001 | 200 ASSIGNED | 800 | 800 | 700 | true | false |
| 28857575 | 051488-000001 | 200 ASSIGNED | 800 | 800 | 700 | true | false |

Both directions are closed: `finishPickingOrder` throws `ORDER_ALREADY_FINISHED` (`700 >= FINISHED`), and
a second `cancelOrder` only re-sets the flag it already has.

**DB verification (floor item 1), run 2026-09-15.** Flag census across **all six** reachable v2 tenant DBs:
c1wh-shipitez-uat 16 · nywh-hydra-uat 1 · nywh-shipitez-uat 0 · **wms2-hydra PRD 0** · wms2-wineco-dev 59 ·
wsl-wineco-uat 69 = **145 flagged / 139 residue / 4 live / 2 stranded** — exact agreement with the census in
`cleanUpCancelledOrder`'s comment, two independent instruments. PRD's zero carries a positive control
(189 COs, all `markedforcancellation = false`), so it is a true zero. **No production exposure.**

Two facts that shrink the repair: **`amountpicked = 0.0000`** on both pick lines and **zero
`customerorder_cancellation_log` rows** for either order — so the repair moves no stock. Each stranded
picking order holds **exactly one** position, so it cannot disturb a co-tenant order.

---

## 2. Root Cause Analysis

### 2.0 What the ticket got wrong (do not revert these corrections)

| Ticket's premise | Status | Where |
|---|---|---|
| "Option 3 — make the eight `allFinished` predicates cancel-aware — is the only un-refuted option and the right place to start" | **Half false.** No Group-B predicate is broken by a CANCELED line. But they still must change, for a different reason (§2.2) | laneB §1.4, §3.2 |
| "AC-5 … only once that path exists", implying AC-5 depends on AC-1 | **False.** AC-5's precondition is discharged by Option 3 (a+b) alone. AC-1 and AC-5 serve **disjoint** populations | laneB §3.4 |
| implied: the fix is a one-predicate change | **False.** It is two sites; one site alone converts a silent strand into a rolled-back 400 | laneA §0, laneC |

### 2.1 Bug 1 — "already CANCELED" is treated as "beyond PACKED" (AC-1)

`PACKED = 650`, `CANCELED = 800`. The codebase states the rule correctly in **A3** and **A4** and breaks it
in **A1** and **A2**. A1 and A2 sit eight lines apart in `cancelOrder`'s execution: it applies A3, then
consults A1, then — on the true branch — calls A2 for every position.

`cleanUpCancelledOrder` sets every position to CANCELED anyway, so *"this position is already cancelled"*
can never be a reason to refuse cancelling the order.

**Why A1 alone is not a fix.** Relaxing A1 moves the order onto the `orderCanBeCancelled == true` branch —
which is **not** the `cleanUpCancelledOrder` branch (that one is on the `else` arm behind
`if (customerOrder.getPickingconfirmationsent())`, and `pcs = false` on both stranded orders). The true
branch loops `cancelOrderPosition`, which throws at **A2** on the first position at 800. `cancelOrder` is
`@Transactional(value = "tenantTransactionManager", rollbackFor = {BusinessException.class, FacadeException.class})`
and A2 joins it at `REQUIRED`, so the heal rolls back. **Net effect: still stranded, plus a misleading 400.**

**Blast radius.** Both helpers have one production caller each, both inside `cancelOrder`. Derived with four
instruments, each with its blind spot named:

1. the **method names** — one non-comment call site each;
2. the **type** `CustomerorderPositionService` — the instrument that would catch dispatch through a
   differently-named interface method. It is injected in exactly one class, `CustomerorderService`;
3. **`implements` / `extends`** on the class — neither, so no interface method of another name can route here;
4. **the controller package** — `git grep -ln "CustomerorderPositionService" -- src/main/.../controller`
   returns **nothing**. The one cancellation-flavoured controller, `mobile/OrderCancellationController`
   (`@RequestMapping("/v3/cancellation")`), injects only `CancellationReversalService`.

So **`cancelOrderPosition` has no HTTP route of its own** — relaxing A2 changes no API error contract, only
the behaviour of `cancelOrder`'s internal loop. Being a `@Service`, the class is not SDR-exported either.
No SpEL / reflection / resource-file references (positive control: the same resource-file grep returns 11
hits over `src/main`, so the instrument reaches).

Residual blind spot: a call assembled by string at runtime through AOP or a bean definition in XML/YAML —
not swept beyond the resource grep above.

**But a call graph is the wrong blast radius for a guard change.** The question that matters is *which orders
change branch*, and that is a **population**, not a set of call sites. Census of every order Fix A reroutes —
`co.state <> 800` owning at least one `customerorder_position.state = 800` — run 2026-09-15 on all six tenants:

| DB | rerouted orders | positive control (cancelled CO positions / owning orders) |
|---|---|---|
| **wms2-wineco-dev** | **3** | — |
| wms2-hydra (PRD) | 0 | 18 / 8 |
| c1wh-shipitez-uat | 0 | 3,504 / 1,006 |
| wsl-wineco-uat | 0 | 52,674 / 11,532 |
| nywh-hydra-uat | 0 | 128 / 81 |
| nywh-shipitez-uat | 0 | 29 / 6 |

Every zero carries a non-zero control, so all five are true zeros. On each of those five DBs, every order
owning a cancelled position is **itself** already at 800 — which is why they are invisible to this guard:
`isAlreadyCancelled` returns first.

| co_id | co_state | `mfc` | `pcs` | CO pos | pick line | `amountpicked` | PO |
|---|---|---|---|---|---|---|---|
| 28848660 | 200 | true | false | 800 | 800 | 0.0000 | 700 |
| 28857575 | 200 | true | false | 800 | 800 | 0.0000 | 700 |
| **585000351** | 200 | **false** | **true** | 800 | **600 PICKED** | **1.0000** | 700 |

**`585000351` is the row that decides the fix's shape** (§3.1.1). It is not stranded — it works today via
`cleanUpCancelledOrder` — and any design that reroutes it must leave its pick line at 600.

**The shape is common; only the order state hides it.** On wsl-wineco-uat, **3,023** pick lines sit at
`PICKED(600)` under a `CANCELED(800)` CO position (plus 13 at 700) — all under orders already at 800. One
re-sent OMS cancel against such an order *before* it reaches 800 and the population is no longer three.
`OrderRestController`'s `@PostMapping("/cancelPositions")` is a live producer of exactly this shape.

### 2.2 Bug 2 — nothing *calls* `finishPickingOrder` for a marked order (AC-5)

SBDEV-3319 already made `finishPickingOrder` **tolerant** of cancelled demand:

```java
if (pickingPosition.getState() < WmsConstants.State.PICKED
        && isDemandCancelled(pickingPosition, validationCoPosition, validationCustomerOrder)) {
    continue;
}
if (pickingPosition.getState() < WmsConstants.State.PICKED) {
    throw new BusinessException("Picking position " + pickingPosition.getNumber());
}
```

and it already dispatches the deferred cancel: `if (customerOrder.getMarkedforcancellation()) { cleanUpCancelledOrder(customerOrder); }`.

So the terminal path **exists** — it is simply unreachable, for two independent reasons:

1. **The trigger is disconnected.** SBDEV-3332 removed `markedforcancellation` from `isDemandCancelled`, so
   the `continue` above never fires for a marked order and the `throw` wins.
2. **Nothing calls the method.** The gates decide completeness as *"no line is below `PICKED`"* — typically
   `boolean allFinished = …noneMatch(p -> p.getState() < WmsConstants.State.PICKED);` → `if (state == PICKED)
   finishPickingOrder(...)`. A marked order's open lines are at 300/200 — genuinely `< PICKED` — so the gate is
   false and `finishPickingOrder` is never invoked.

   ⚠ **State the rule, derive the set — do not trust a count.** Three numbers for this set are already in
   circulation (laneB says eleven predicate sites, §0.2 lists eight in scope, an earlier §4 said seven), and
   they disagree because they answer different questions. The rule is: **every site that decides whether a
   picking order is complete and, on "yes", hands control to `finishPickingOrder`.** The shapes are not
   uniform — `noneMatch`/`anyMatch` expressions, hand-rolled accumulator loops, an accumulator-free
   early-return loop where *falling through* is the verdict, and one **repository-derived** predicate
   (`countByPickingorderIdAndStateLessThan`) that no stream grep finds. **Re-derive the set at the gate from
   the rule**, and record what each instrument missed.

**Hence Option 3 is irreducibly two changes, and each alone reproduces a known failure:**

- **(a) alone** → unpickable (`confirmPick` refuses) *and* unfinishable (no caller). **This is the third
  withdrawn attempt.**
- **(b) alone** → `finishPickingOrder` runs and throws `BusinessException("Picking position …")` on the
  first unpicked line.

### 2.3 Bug 3 — the mobile refresh sees one trigger of three (M-4)

`isDemandCancelled` has **three** triggers (pick line 800 · CO position 800 · CO 800). The mobile pick list
removes a row on **one**: `results.filter(position => position.pickStatus !== CANCELLED_PICK_STATUS)`, and
`pickStatus` is `WmsConstants.State.getCodeText(pos.getState())` over the **`PickingorderPosition`** only.

For triggers 2 and 3 the server rejects the pick with `PICK_CONFIRM_ORDER_CANCELLED`, SBDEV-3319's
rejection-path re-query faithfully returns the same row, and the operator retries forever.

**AC-5 makes it three-of-four.** Shipping (a) without M-4 **adds a new infinite-retry shape** rather than
merely failing to fix the old one. This is why AC-5 and M-4 ship together.

### 2.4 Bug 4 — the cancellation log has no per-pick-line key (AC-4)

`customerorder_cancellation_log` carries `customerorder_id`, `customerorder_position_id`, `pickingorder_id`
and **no `pickingorder_position_id`** (verified against the live dev DB). SBDEV-3332 closed the duplicate-row
defect at the *re-entry*; closing it at the *row* needs the column.

**The naive key is wrong**: on c1wh-shipitez-uat **41** CO positions own more than one pick line (39 own 2,
one owns 3, one owns 4) out of 264,239 — so `unique(customerorder_position_id)` would suppress a legitimate
second row.

---

## 3. Fix Design

### 3.1 Fix A — skip already-CANCELED positions in `cancelOrder`'s two loops (AC-1)

> **REVISED after adversarial review (critic C-1 / M-6).** An earlier draft relaxed the `>= PACKED` band in
> `canOrderPositionBeCancelled` **and** `cancelOrderPosition`. **That version was wrong and would have
> corrupted a live order.** The reasoning that produced it, and its refutation, are kept in §3.1.1 so the
> gate does not re-derive it.

`CustomerorderPositionService` is **not modified.** Both of `cancelOrder`'s loops over `coPositions` skip
positions that are already at `CANCELED`:

```java
  boolean orderCanBeCancelled = true;
  for (CustomerorderPosition customerOrderPosition : coPositions) {
+     // Already cancelled: it neither blocks the order cancel nor needs cancelling. SBDEV-3363.
+     if (customerOrderPosition.getState() == WmsConstants.State.CANCELED) { continue; }
      if (!customerorderPositionService.canOrderPositionBeCancelled(customerOrderPosition)) { … }
  }
  …
  for (CustomerorderPosition customerOrderPosition : coPositions) {
+     if (customerOrderPosition.getState() == WmsConstants.State.CANCELED) { continue; }
      customerorderPositionService.cancelOrderPosition(customerOrderPosition);
  }
```

**Invariant, stated once:** *an already-CANCELED position takes no part in the cancellation decision — it
neither blocks the cancel nor needs cancelling.* Both loops are the same sentence; a reviewer checking one
knows what the other must say.

⚠ **Do not reassign or filter `coPositions` itself.** The OMS outbox payload downstream is built from it and
needs **every** position, including the cancelled ones. Use `continue` in place, or a *separate* local.

⚠ **On the comparison itself.** `getState()` returns a boxed `Integer`; `WmsConstants.State.CANCELED` is an
`int`. Mixing them **unboxes the `Integer`**, so `position.getState() == WmsConstants.State.CANCELED` is a
numeric comparison and is correct at 800 — the `Integer`-cache trap that bites boxed-**vs**-boxed `==` does not
apply here. This is the file's established idiom (`finalizePickingOrderIfTerminal` writes
`p.getState() == WmsConstants.State.CANCELED`). The only real hazard is an **NPE if `getState()` is null**;
the column is `NOT NULL` in `V2.2.00__base_v2_schema.sql` and both loops already dereference it unguarded one
line later, so no new guard is warranted — but a hand-built test fixture that omits the state will NPE, which
is worth knowing at the gate.

#### 3.1.1 Why NOT the two-guard band fix (the rejected earlier design)

Relaxing the band in `cancelOrderPosition` lets an already-CANCELED **position** through to that method's work
loop — which is bounded `if (pickingPosition.getState() < WmsConstants.State.PACKED)`, i.e. **`< 650`**, not
`< PICKED`. A pick line at `PICKED(600)` under that position therefore **enters** the body and is flipped to
`CANCELED`, and the tail then demotes its picking order.

That is precisely the outcome `cancelOpenPickLines` exists to prevent, per its own javadoc: *"Bounded to
`state < PICKED`. A PICKED line's stock is already in the tote … and flipping it to CANCELED would make the
tote's contents unattributable."* `cancelOrderPosition` is the one cancellation path in the codebase using the
wider bound.

**This is not hypothetical.** Order `585000351` on wms2-wineco-dev — the third order in §2.1's census — has
exactly that shape: CO position `800`, pick line `600` with `amountpicked = 1.0000`, picking order `700`. The
two-guard version flips its line to `800` and demotes the picking order to `800`. It works today.

The earlier draft argued the two guard edits were "independently correct". **They are not**:
`canOrderPositionBeCancelled(position @ CANCELED)` returning `true` is not a truth — a cancelled position
*cannot* be cancelled — it is an answer that happens to route the **order**-level decision correctly while
instructing the **position**-level caller to go and cancel something already cancelled. The caller obeys, and
that obedience is the defect above. The filter never asks the question, so it never gets the wrong answer.

**Accepted behaviour delta, stated rather than buried.** Under Fix A, `585000351` moves from the
`cleanUpCancelledOrder` arm to the true branch and therefore **loses the `customerorder_cancellation_log` row**
that `cancelOpenPickLines` writes for a `>= PICKED` line. For this row the loss is immaterial — its
`picktounitload_id (585000950)` is at state `800` with `unitload_id = NULL` and **0** stock units, so
`resolvePicktoStockunitId` yields null and `completeReversal` refuses such a row anyway. **But the general
case is not immaterial**, and nothing today produces it: see §10 Q4, which is Nam's call, not the gate's.

**Fix A6 — one-line guard on the newly-reachable RAPID `get(0)`:**

```java
- CustomerorderPosition customerOrderPosition = coPositions.get(0);
- List<PickingorderPosition> pickingPositions = pickingorderPositionRepository.findByCustomerorderpositionId(...);
- Pickingorder pickingOrder = pickingorderRepository.findById(pickingPositions.get(0).getPickingorderId())...
+ // guard: an order whose first position is already CANCELED reaches here only since SBDEV-3363
+ if (!pickingPositions.isEmpty()) { ... }
```

Dead on all six tenants today (both RAPID_PICKING sections carry 0 orders; PRD has no such section), but
`sectionpickingtype` is **data** — one row edit re-arms it with no deploy.

### 3.2 Fix B — one demand-aware completeness helper, not eight inline edits (AC-5)

**(a)** Re-admit the trigger in `isDemandCancelled`, and update **C2–C4**'s ⚠ comments plus
`assertPickNotCancelled`'s `LOG.warn` in the same edit — that log currently omits the flag on the stated
grounds that it "can never be the reason this line was reached", which Fix B makes false.

**(b)** Add one method on `PickingorderBusinessService` owning the chain load and the predicate:

```java
/** True when every pick line on this order is either finished or has cancelled demand. */
public boolean isPickingOrderComplete(Long pickingOrderId) { … }
```

and replace the eight Group-B expressions with a call to it.

**Why one method.** Inlining demand-awareness eight times means **eight new two-level bulk fetches, one a
`findByIdForUpdate` row lock**, on hot mobile paths including `processPick` — a performance and
lock-ordering change, not a refactor. And the repo has already paid the duplication cost on this exact axis:
B9/B10/B11 are three hand-copies of one settle rule and **B11 never got the SBDEV-1921 fix**.

**Visibility falls out of this.** `MobilePickingService` is in a different package but already injects
`pickingorderBusinessService`, so it calls the new **public** method and never needs `isDemandCancelled` —
which therefore stays **package-private**, matching its already-package-private siblings
`assertPickNotCancelled` and `cancelOpenPickLines`.

**Optional hygiene — the write-ordering trap (finding F2, §10). NOT mandatory; an earlier draft said it was,
on a justification that is provably wrong (critic H-2).** Inside `finishPickingOrder`, `orderState` is computed
from the lines, then `cleanUpCancelledOrder` → `finalizePickingOrderIfTerminal` **writes**
`pickingOrder.setState(...)`, then `pickingOrder.setState(orderState)` **overwrites it**. The overwrite is
real; the **divergence is not**, and Fix B does not create one:

- `orderState` is `FINISHED` iff some line satisfied `state >= PICKED && state != CANCELED`; else it keeps its
  `CANCELED` seed.
- `finalizePickingOrderIfTerminal` writes `FINISHED` iff `allMatch(state >= FINISHED)` and not all are
  `CANCELED` — i.e. some line is at exactly `700`.
- The only mutation between them is `cancelOpenPickLines`, which moves lines from `< PICKED` to `CANCELED`.

`finalize = CANCELED` with `orderState = FINISHED` would need a line that was `>= 600, != 800` to become 800 —
impossible, the flip is bounded `< 600`. `finalize = FINISHED` with `orderState = CANCELED` would need a line
at 700, which already satisfies `>= PICKED && != CANCELED` and so would have set `orderState = FINISHED`. Both
directions are unreachable. **Fix B makes the path hot, not the divergence possible** — it does not touch
`cancelOpenPickLines`' `< PICKED` bound.

So: worth doing as hygiene (a computed-then-overwritten value becomes a live trap the moment anyone widens
that bound — which SBDEV-3316's reversal work is near), but **no test can grade it today**, so it carries no
mutation row and must not be presented as required. If the gate is tight on budget, drop it.

### 3.3 Fix C — emit the answer, not the inputs (M-4)

Add a `demandCancelled` boolean to the mobile pick-list payload (C6), computed by the **same**
`isDemandCancelled` the pick guard uses, and key the mobile filter on it (C5).

⚠ **Widen the filter; do not replace it.** The obvious edit — swapping the `pickStatus` test for the new
field — is a regression whenever the UI runs ahead of the API:

```js
// WRONG: with an old API, demandCancelled is undefined, so cancelled pick lines
//        (pickStatus === 'Cancelled') stop being filtered — the exact SBDEV-3319 symptom, restored.
const livePositions = results.filter(p => !p.demandCancelled)

// RIGHT: degrades safely in BOTH directions.
//   old API  -> demandCancelled undefined -> falls back to today's pickStatus behaviour
//   new API  -> catches all triggers, pickStatus included
const livePositions = results.filter(
    p => p.pickStatus !== CANCELLED_PICK_STATUS && !p.demandCancelled)
```

`nextPickingPosition` tests the same string and must be widened identically — it is the landing rule to the
filter's display rule, and leaving one narrow makes a row unreachable by scroll but still landable by hand.

Rejected alternative: widening the client's test to read CO-position and CO state re-derives the server's
predicate in JavaScript, where it drifts the first time a trigger is added — which is precisely how the
current one-of-three mismatch arose.

### 3.4 Fix D — `pickingorder_position_id` column + partial index (AC-4)

> **REVISED after adversarial review (critic C-2).** The unique index is **split out of this ticket.** Ship
> the column now; the constraint only after `recordCancellation` is made idempotent.

Flyway **`V2.2.31`** (highest existing is `V2.2.30`; all 285 remote refs swept — **re-run the collision check
immediately before merge**, a branch pushed later can still claim it).

```sql
ALTER TABLE customerorder_cancellation_log ADD COLUMN IF NOT EXISTS pickingorder_position_id bigint;
CREATE INDEX IF NOT EXISTS idx_cancel_log_pickingorder_position
    ON customerorder_cancellation_log (pickingorder_position_id)
    WHERE pickingorder_position_id IS NOT NULL;
```

**Nullable, deliberately.** Historical rows cannot be backfilled — the pick line is not recoverable from the
row — so a `NOT NULL` column would need a fabricated value. The partial predicate exempts legacy rows.
**Precedent exists in this very table**: `idx_cancel_log_reversal_pending` is already partial.

#### Why the index is NOT `UNIQUE` in this ticket

A `UNIQUE` constraint here would invert a contract `CancellationLogService` states explicitly:

> *"Fail open: a row that cannot be resolved is still recorded … Throwing here would abort the cancellation
> itself — this method is `Propagation.MANDATORY` and runs inside the caller's cancel transaction — which
> would trade a bookkeeping gap for a failure of the primary operation."*

`recordCancellation` ends `return logRepository.save(log);` with no dedup, no existence check and no
`ON CONFLICT`. Under `MANDATORY` propagation a `DataIntegrityViolationException` at flush rolls back **the
caller's cancel**. So the constraint would convert a duplicate *bookkeeping row* — the exact thing the comment
says must never abort the cancel — into a failed cancellation. And the duplicate path is documented as
reachable in `cleanUpCancelledOrder`'s own header (a line logged above the `< PICKED` bound but never flipped
is re-logged on every pass).

Second exposure: a cancellation that is **reversed** and whose line is later re-cancelled needs a legitimate
second row for the same `pickingorder_position_id`. The plan has not traced SBDEV-3316's reversal surface far
enough to rule that out.

**And the evidence for "safe" is too thin for a schema constraint**: "zero duplicates" over **24 rows**
(dev 8 · PRD 16 · four UATs 0) cannot distinguish *impossible* from *has not happened yet*, and the zero
carries no positive control.

**Sequence, then:** (1) this ticket ships the column + plain partial index and populates it; (2) a follow-up
makes `recordCancellation` idempotent on `pickingorder_position_id` — look up and skip/update rather than
insert; (3) only then does the index become `UNIQUE`. Steps 2–3 are **proposed, not filed** (§10 F4).

#### When step 3 lands, the key is `pickingorder_position_id` ALONE — not a composite

An architect lane recommended `UNIQUE (customerorder_position_id, pickingorder_position_id)`, reasoning that
a CO position legitimately splits across two pick lines. **The premise is right and the conclusion does not
follow.** `pickingorder_position.customerorderposition_id` is a single column, so a pick line has exactly one
CO position — `pickingorder_position_id → customerorder_position_id` is a function, and the first column is
functionally dependent on the second.

Consequences of getting this wrong, both bad:
- the composite **adds nothing** for the split case — two pick lines under one CO position already differ in
  `pickingorder_position_id`, so a single-column unique index permits both rows, which is the desired
  behaviour;
- the composite is **strictly weaker** — it would permit the same `pickingorder_position_id` to appear twice
  under two different `customerorder_position_id` values, i.e. exactly the duplicate the constraint exists to
  forbid.

The ticket's original warning was against `UNIQUE (customerorder_position_id)` **alone**, which is indeed
wrong (41 CO positions own more than one pick line on c1wh-shipitez-uat). The remedy is to key on the pick
line, not to append the CO position to the key.

`CancellationLogService.recordCancellation` populates it (C8); `pickingPosition` is dereferenced
unconditionally at `boolean reversalRequired = (pickingPosition.getState() >= WmsConstants.State.PICKED);`,
so the value is always available.

### 3.5 Fix E — repair the two stranded orders (AC-6)

⚠ **Neither code fix self-heals them.** Fix A makes a *re-sent* cancel succeed; nothing re-sends one
spontaneously. Fix B cannot reach them at all (`finishPickingOrder` throws `ORDER_ALREADY_FINISHED` at 700
before any predicate is read).

**Preferred: replay the cancel through the API** once Fix A is on dev, so the repair runs the same code path
the fix creates — which makes it a live test of the fix rather than a parallel SQL story. Falls back to a
runbook `UPDATE` only if the OMS resend is not available. Either way the OMS notification must be emitted;
the idempotency key `CANCELLED_IDEMPOTENCY_KEY_PREFIX + id` is **free** for both orders (measured: zero
`outbox_message` rows for either aggregate).

Runbook to author at `sbdocs/2-Areas/runbooks/sbdev-3363-stranded-cancel-repair.md`.

---

## 4. File Change Summary

| File | Change | Covers |
|---|---|---|
| `service/CustomerorderService.java` | `continue` on an already-CANCELED position in **both** `coPositions` loops; RAPID `isEmpty()` guard; ⚠ comment C4 | **A0**, A6, C4 |
| ~~`service/CustomerorderPositionService.java`~~ | **not modified** — see §3.1.1 | — |
| `service/PickingorderBusinessService.java` | trigger; javadoc C1b; new completeness helper; `LOG.warn` + ⚠ comments; (optional) write-order hygiene | C1, C1b–C3, B, F2 |
| `service/mobile/MobilePickingService.java` | completeness call-sites → helper; `demandCancelled` in the pick-list payload | B, C6 |
| `service/CancellationLogService.java` | populate the new column | C8 |
| `db/migration/V2.2.31__*.sql` | column + **non-unique** partial index | C7 |
| `wms2-mobile-ui/store/picking.js` | widen **both** the filter and `nextPickingPosition` | C5, C5b |
| `test/.../unit/service/CustomerorderPositionServiceUnitTest.java` | narrow two `@DisplayName`s that Fix-A-adjacent behaviour makes misleading, and add an 800 case to each | M-3 |
| `sbdocs/2-Areas/runbooks/sbdev-3363-*.md` | repair runbook | E |

⚠ **`CustomerorderPositionServiceUnitTest`'s two pins say "packed **or beyond**" while testing only
`PACKED(650)`.** They stay green through this ticket either way, but the names assert something the codebase
does not check. Narrow them to the `[650,800)` band and add a sibling case at 800 pinning the answer Fix A
depends on — otherwise the next reader takes "or beyond" as covered when it never was.

---

## 5. Implementation Steps

### 5.1 Prerequisites

| Item | Status |
|---|---|
| DB state | ✅ verified 2026-09-15, all six tenants; PRD unexposed |
| Flyway version | ⚠ `V2.2.31` claimed — **re-verify at merge time** |
| Feature flags / sysprops | N/A — no new gate; AC-5 is behavioural |
| Deploy order | **API before mobile UI.** The mobile filter reads `demandCancelled`; if the UI ships first the field is absent and `undefined !== true` keeps every row — the current behaviour, so it degrades safely rather than breaking |
| Mobile baseline | ✅ **discharged 2026-09-15.** `ef1dc76` sits on `origin/develop` self-marked *"NOT VERIFIED … The green tests it carries are not a verdict"*, so it was re-run rather than trusted: worktree off `origin/develop` @ `ab1e2ae` → **`Test Suites: 32 passed, 32 total · Tests: 395 passed, 395 total`**. Green. Compare failures against this |
| Data migration | Fix E only; no bulk backfill |
| External systems | OMS receives the cancel notification for 2 orders (Fix E) |

### 5.2 Order

1. **Fix A + A6** — the two `continue`s in `cancelOrder`, the RAPID `isEmpty()` guard, and the AC-1
   fixtures (§8.1, **H2 lane** — not Testcontainers; see §8.1's GATE OUTCOME block, which supersedes an
   earlier draft of this line). `CustomerorderPositionService` is untouched. Independently shippable.
2. **Fix D** — migration (column + non-unique partial index) + `recordCancellation`. Independent of the rest.
3. **Fix B** — the trigger, the C1b javadoc, the completeness helper, the ⚠ comments, and — only if budget
   allows — the F2 write-order hygiene. Largest and riskiest.
4. **Fix C** — mobile (**both** the filter and `nextPickingPosition`), in the same PR as Fix B or immediately
   after it; **never before**.
5. **Fix E** — repair, after Fix A reaches dev.

**Steps 1 and 2 are independent of 3–4 and of each other**, so if the ticket has to be split under budget,
split it there: step 1 alone closes **AC-1** and **unblocks** AC-6 (which is Fix E, step 5 — the code fix does
not replay the cancel for the two existing rows), and it is the half with field evidence behind it.

---

## 6. Horizontal Scalability Validation

| # | Concern | Verdict |
|---|---|---|
| 1 | In-JVM state | **No** — no new cache/static/ThreadLocal |
| 2 | Connection-pool math | **Yes** — Fix B's helper adds a two-level fetch per completeness check on mobile paths. Centralising it in one method keeps the count at *one* such load per check rather than eight; measure before/after on `processPick` |
| 3 | Scheduled jobs | **No** — none added. See §10 F3 |
| 4 | Long transactions | **No** — no external I/O added inside a tx |
| 5 | Request affinity | **No** |
| 6 | Retry / idempotency | **Yes** — Fix E's OMS notification is idempotency-keyed; key measured free |
| 7 | Tenant context | **No** — no `@Async` |
| 8 | Distributed lock correctness | **Yes — decided, not a preference: the completeness helper MUST use non-locking reads.** At least one caller runs it while a `Pickingorder` lock is already held — `MobilePickingService.rapidPickingScanSource` calls `confirmPick` (which takes `customerorderRepository.findByIdForUpdate` **then** `pickingorderRepository.findByIdForUpdate`) and *then* evaluates completeness. A helper taking a `Customerorder` lock there is a Pickingorder→Customerorder acquisition — the inversion `cancelOpenPickLines`' javadoc spends two paragraphs forbidding. Pin the acquisition order with an `InOrder` assertion, in the style of the existing pins in `PickingorderBusinessServiceUnitTest` |
| 9 | Cache invalidation | **No** — no `@Cacheable` entity written |
| 10 | External notifications | **Yes** — via `outboxService.enqueue`, already commit-atomic |

---

## 7. v2 Constraint Checklist

| # | Constraint | Verdict |
|---|---|---|
| 1 | OSIV disabled | **Yes** — helper runs inside the caller's tx; no lazy access outside |
| 2 | `tenantTransactionManager` | **Yes** — all touched methods already declare it; new helper must too |
| 3 | `readOnly = true` | **Add it, but it is inert — do not record it as a satisfied control.** Every caller invokes the helper from inside an existing read-write tenant transaction; at default `REQUIRED` propagation the participating transaction keeps the **outer** flag. It documents intent and changes nothing. Do not write a test asserting it — transactional tests are blind to `propagation`/`readOnly` |
| 4 | Caffeine eviction | **N/A** — no cached type written |
| 5 | Jakarta namespace | **N/A** — no ported code |
| 6 | H2-compatible test SQL | **Yes** — `CREATE INDEX … WHERE` is a **partial** index and H2 does not support the predicate, so the migration must be exercised in the **Testcontainers** lane, not H2 |
| 7 | `BaseControllerTest` | **N/A** — no endpoint signature change (C6 adds a payload field; assert it in the existing mobile service test) |
| 8 | Micrometer | **No** new metric. See §10 F3 |

---

## 8. Testing Plan

**Baseline (floor item 5), captured on the ticket worktree at `9e294d4b` before any change**, via the same
`mvn -B -ntp clean verify` that CI runs:

| lane | result |
|---|---|
| surefire (unit) | `Tests run: 6629, Failures: 0, Errors: 0, Skipped: 1` |
| failsafe (IT) | `Tests run: 409, Failures: 0, Errors: 0, Skipped: 31` |
| build | **BUILD SUCCESS**, 08:50 min |

**Both lanes are green — compare failures against this, never totals** (totals move with every merge). The
log carries 19 lines matching `ERROR`/`FAIL`; all 19 were checked and are **test output from deliberately
exercised failure paths** (`ReturnAdviceAutoReceiveService` PARTIAL FAILURE, `StartupFlywayMigrator`
enumeration, `TenantHealthController` rejection bodies), not test failures. Do not read that count as a
red baseline.

### 8.1 The AC-1 test must drive `cancelOrder` end to end

The existing pins are **vacuous**: `shouldReturnFalseWhenPositionPackedOrBeyond` and its throwing sibling both
use a `PACKED(650)` fixture and never exceed it, so both stay green through Fix A; and
`CustomerorderServiceUnitTest`'s 20 `canOrderPositionBeCancelled` stubs sit on a `@Mock` (no `@Spy`, no
`CALLS_REAL_METHODS`) and cannot observe the helper's body at all.

**Therefore a unit test calling `canOrderPositionBeCancelled` directly cannot grade this fix at all** — Fix A
does not modify that method. The acceptance test must exercise **`cancelOrder` end to end with a real
`CustomerorderPositionService`** against all three fixtures.

**Lane and mechanism, named so the gate does not take the cheap exit.** `CustomerorderServiceUnitTest` is
`@InjectMocks` over ~30 `@Mock` collaborators, including `@Mock private CustomerorderPositionService`. A real
collaborator cannot coexist with that without hand-building the constructor.

> **GATE OUTCOME — the lane is H2, not Testcontainers.** An earlier draft said Testcontainers. Nothing in
> these assertions depends on PostgreSQL semantics: no native SQL, no partial index, no advisory lock — just
> entity state through real repositories inside a real Spring context, which is exactly what
> `BaseRollbackIntegrationTest` gives, and it matches the direct sibling
> `CancelOrderRollbackIntegrationTest`. Written as
> `integration/CancelOrderAlreadyCancelledPositionIntegrationTest`. **Only Fix D's migration needs the
> container lane.**

| fixture | assert after `cancelOrder` |
|---|---|
| stranded (`28848660` shape: cop 800, line 800, PO 700, `pcs=false`) | `co.state = 800`; `markedforcancellation = false`; one `ORDER_BATCH_CANCELLED_FROM_WMS` outbox row |
| **`585000351` shape** (cop 800, line **600**, `amountpicked=1`, PO 700, `pcs=true`) | **`pop.state` stays `600`** and **`po.state` stays `700`** |
| mixed (cop 800 + cop 200 open) | the open position is still cancelled; the cancelled one is untouched |

**The second row is the one that separates a correct fix from the rejected two-guard design** (§3.1.1) — and
that is now **measured, not argued**. Running the three fixtures against a working tree carrying the rejected
two-guard change:

| fixture | vs. the rejected design |
|---|---|
| 1 stranded | **passes** |
| 3 mixed | **passes** |
| **2 regression pin** | **FAILS** — `expected: 600` (line flipped to 800), diagnostic *"a PICKED line's stock is already in the tote; flipping it to CANCELED makes the tote's contents unattributable"* |

So the wrong fix is green on two of three, and fixture 2 is the only thing that catches it. The kill is
**attributable** — the message names the thing broken, not an NPE or a missing method.

⚠ **Fixture gap the mutation check caught, recorded because it would otherwise reappear.** The fixtures
originally used a placeholder `itemdataId = 1L`. The **pre-fix** path never reaches the OMS payload builder,
so all three tests failed on their real assertions and the placeholder looked fine. Under the mutant — i.e.
on any tree where the fix works — `cancelOrder`'s success branch calls
`itemdataService.getById(position.getItemdataId())` and every test died with
`EntityNotFoundException: ItemData not found with id: 1`, which is a red but **not a kill**. The fixture now
seeds a real `Itemdata` (with `handlingunitId`, `@NotNull` on the entity). **Without the mutation check this
would have surfaced as three mystery errors the moment the implementation landed.**

### 8.2 Mutation checks (floor item 3) — PIT, scoped

**Rows 1–3 are MEASURED, not predicted** — run 2026-09-15 against the implemented fix.

| # | Assertion | Mutant | Outcome |
|---|---|---|---|
| 1 | Fix A skip, guard loop | delete that `continue` | ✅ **KILLED** — fixtures 1 and 3 red, `expected: 800 but was: 200`, each diagnostic naming its criterion |
| 2 | Fix A skip, **cancel** loop | delete that `continue` | ✅ **KILLED** — all three error with `BusinessException: order position is beyond status PACKED. can not be cancelled anymore`. Attributable: that message *is* `cancelOrderPosition`'s entry guard, the exact throw the skip exists to avoid |
| 3 | the whole two-site design | apply the **rejected** band relaxation in `CustomerorderPositionService` | ✅ **KILLED by fixture 2 only** — fixtures 1 and 3 pass; fixture 2 red with `expected: 600`. This is the discriminating row |
| 4 | C1 trigger | remove the flag conjunct from `isDemandCancelled` | marked-order finish test red — *pending, Fix B* |
| 5 | B helper | invert the demand-aware arm | `finishPickingOrder` not called — *pending, Fix B* |

⚠ **Row 2's prediction was wrong and is corrected above.** An earlier draft expected *"`585000351`:
`pop.state` becomes 800"*. That is the outcome of the **rejected two-guard** mutant (row 3), not of deleting
the cancel-loop skip: with `CustomerorderPositionService` left intact, `cancelOrderPosition` **throws** on a
CANCELED position rather than flipping its pick line. Both are kills; the diagnostics differ, and only row 3
discriminates.

An earlier draft also carried a row pairing the mutant `< CANCELED → <= CANCELED` with the assertion *"a
`[650,800)` position must still be refused"*. That pairing is **vacuous** — both original and mutant throw
across `[650,800)` and differ only at 800, which that assertion never exercises — and it is gone along with
the design it graded.

A red arriving as `NoSuchMethodException` or an NPE in setup is **not a kill**.

### 8.2.1 Review-pass mutants — also measured

The Phase 3b review found two assertions that were **vacuous as first written**. Both were repaired and the
repair verified by the mutant that previously survived:

| Assertion | Mutant | Outcome |
|---|---|---|
| fixture 1's `markedforcancellation` is false after the cancel | delete SBDEV-3332's `customerOrder.setMarkedforcancellation(false)` on the success branch | ✅ **KILLED** — `Expecting value to be false but was true`. **Survived before the fixture was reseeded to `markedforcancellation = true`**: it started false and nothing on that branch sets it true, so the assertion restated the fixture |
| fixture 4's RAPID `isEmpty()` guard | neutralise the guard | ✅ **KILLED** — `IndexOutOfBoundsException: Index 0 out of bounds for length 0`. **Survived the entire suite before fixture 4 existed**, because every other fixture builds a `Client` with no `sectionId`, so `section` is null and the RAPID block never runs |

### 8.3 Other lanes

- **Testcontainers** for `V2.2.31` — assert the column exists and that `recordCancellation` populates it. **Do
  not** assert that a duplicate is rejected: the index ships non-unique (§3.4), and an assertion written for the
  `UNIQUE` version would pin a constraint this ticket deliberately does not add.
- **Jest** for C5 — a row whose `demandCancelled` is true but whose `pickStatus` is **not** `'Cancelled'` must
  disappear. That is exactly the case today's filter misses. Pin the **old** API shape too (`demandCancelled`
  absent, `pickStatus === 'Cancelled'` → still filtered), which is the deploy-order safety property.
- **Jest** for C5b — the same two cases against **`nextPickingPosition`**, not just the filter. A row removed
  from the list but still landable by `nextPosition`/`previousPosition` is the hole the filter alone leaves.
- **Manual:** cancel an order mid-pick on the handheld and confirm the row leaves the list and the order reaches
  CANCELED without an operator retry loop.

---

## 9. Risks & Mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| **A `PICKED(600)` line under a cancelled position gets flipped to CANCELED** — tote contents unattributable, picking order demoted | **The defect the rejected two-guard design introduced.** Live on `585000351`; the shape has 3,036 instances on wsl UAT held back only by `isAlreadyCancelled` | Fix A never calls `cancelOrderPosition` for an already-CANCELED position (§3.1). Pinned by §8.1 fixture 2 and §8.2 mutation row 2 |
| Fix A's skip added to one loop only | Guard loop only → still stranded. Cancel loop only → the flip above | §8.2 rows 1 **and** 2 — one per loop, deliberately |
| Fix B (a) without (b) | The third withdrawn attempt | Ship as one change; §8.2 row 5 |
| Mobile filter **replaced** rather than widened | Old API → `demandCancelled` undefined → cancelled lines stop being filtered; restores the SBDEV-3319 hole | §3.3's two-conjunct form; §5.1 deploy order |
| `nextPickingPosition` left narrow while the filter widens | Row unreachable by scroll but still landable by hand — the defence-in-depth layer silently stops covering triggers 2–4 | C5b; §8.3 pins the landing rule as well as the filter |
| Flyway `V2.2.31` collision | Migration fails on boot | Re-run the sweep at merge |
| A `UNIQUE` index on an insert-only writer inside `MANDATORY` | A duplicate bookkeeping row aborts the **cancel** | Index ships **non-unique**; uniqueness deferred until `recordCancellation` is idempotent (§3.4, F4) |
| `585000351` loses its cancellation-log row | Immaterial for this row (pick-to unitload already dead, 0 stock) — **not** immaterial in general | Stated, not buried: §3.1 and §10 Q4. Nam's call |

---

## 10. Open Questions / Findings

**F1 — `forceCancelOrder` carries the third, un-migrated copy of the settle rule.** `git log -S'losPickingPosition'`
returns one commit, `a685e07b 2024-07-16 "initial checkin"` — never touched. Saved only by a downstream
`!= CANCELED` test. Sub-T3 → **stays on this ticket** as a finding; not fixed here (it is in a branch the code
documents as unreachable, and touching it widens a T3).

**F2 — the `finishPickingOrder` write-ordering trap.** In scope as **optional hygiene**, §3.2. An earlier draft
called it mandatory on the grounds that Fix B would make it live; that justification is disproved there (the
two written values provably coincide, and Fix B does not touch the bound that makes them coincide). No test can
grade it today, so it carries no mutation row. Drop it if the gate is tight.

**F4 — `recordCancellation` is not idempotent, which is why AC-4's index ships non-unique.** Closing that needs
a lookup-and-skip/update in `CancellationLogService` plus a follow-up migration promoting the index to
`UNIQUE`. Touches a `MANDATORY`-propagation writer on the cancel path and the SBDEV-3316 reversal surface →
**T3 → proposed, not filed.**

Three constraints the AC-4 review established that the follow-up must carry:

1. **A lookup alone is not sufficient.** The entity is `@GeneratedValue(IDENTITY)`, so the violation is
   synchronous at `save()`, and PostgreSQL aborts the whole transaction on any error (`25P02`) — a
   `try/catch` cannot rescue the caller's cancel. Lookup-then-insert is TOCTOU, so the concurrent arm
   needs a **SAVEPOINT** (`REQUIRES_NEW` / nested transaction) or **`ON CONFLICT DO NOTHING`**.
2. **The ordering has no rail.** `CancellationLogPickingorderPositionIdIT` pins `target = 2.2.31`, so a
   later migration promoting the index to `UNIQUE` would leave all three tests green. Step 2's ACs must
   name the rail that fires if step 3 lands first.
3. **The key is `pickingorder_position_id` alone**, not a composite — see §3.4.

**F5 — `CancellationLogEntryDto` does not expose the new column, and it is the surface that needs it.**
`CancellationReversalService.detail()` renders it to the mobile reversal screen. For the 41 measured CO
positions owning more than one pick line, two log rows now reach the operator with the same
`customerorderPositionId`, the same SKU and the same amount, and **nothing distinguishing them**.
Pre-existing and correctly out of AC-4's scope — but AC-4 is what makes it fixable. Sub-T3 → stays on this
ticket.

**F3 — nothing makes a marked order self-heal.** Fix B completes a marked order at the operator's *next*
interaction. An abandoned picking order stays marked indefinitely — better than today (the picking also stops)
but not self-healing. A scheduled sweep is the only thing that closes it. **T3 → proposed, not filed.**

**Q1 — RESOLVED 2026-09-15 by reading `CancellationReversalService.completeReversal`, not its comment.** It
first attempts a recovery hop for a null `picktostockunit_id` (added by SBDEV-3316, because pre-fix rows all
carried null), and if the value is *still* null it throws:
`new BusinessException("Reversal for position " + … + " … manual intervention required")`.

Consequence for `585000351`: its `picktounitload_id (585000950)` is at state `800` with `unitload_id = NULL`
and **0** stock units, so the recovery hop yields nothing and the row would throw. **So the log row Fix A
drops for that order is not merely un-actionable — it would actively fail a reversal attempt** (and the mobile
screen sends every position on the order, so one such row poisons the whole call). For this row, dropping it
is mildly *better* than keeping it. That does not generalise — see Q4.

**Q4 — should Fix A compensate for the cancellation-log row `585000351` loses?** Moving it from
`cleanUpCancelledOrder` to the true branch drops the `recordCancellation` row that `cancelOpenPickLines` writes
for a `>= PICKED` line. Per Q1, for **this** order the row would not merely be useless — it
would throw and block a reversal, so dropping it is a small improvement. **But that is an accident of the row
being old.** For a future order in the same shape **with a live tote**, the recovery hop succeeds, the row is
actionable, and dropping it silently loses a real reversal record.

Options: **(a)** accept and document — zero extra scope, correct for every row that exists today; **(b)** have
the true branch call `recordCancellation` for `>= PICKED` pick lines under an already-cancelled position
before skipping it, mirroring what `cancelOpenPickLines` does on the other arm.

**DECIDED (Nam, 2026-09-15): (a) — accept and document.** Fix A skips already-CANCELED positions outright and
writes no log row for them. Rationale on record: correct for every row in the estate today, strictly better
for the one live instance (per Q1 the row would throw and poison the order's whole reversal call), and nothing
currently produces a live-tote instance of the shape. **Do not re-litigate this at the gate or in review.**
Revisit only if a live-tote instance appears — (b) would add a write to the cancel path and re-open the
duplicate-row question C-2 just closed.

**Q2 — does any OMS-side behaviour depend on what these orders send today?** ⚠ **ANSWERED 2026-09-16 — see §13.** Verdict: *conditionally safe, decided by one query nobody has run yet, and the safety it needs is NOT the safety the sysprops advertise.* The original note below is kept for the trail.

⚠ **Sharpened by the conformance lane, and it is the one open question INSIDE Fix A's blast radius.** The
effect of Fix A is not merely that the order reaches CANCELED — it is that the order now **emits an
`ORDER_BATCH_CANCELLED_FROM_WMS` outbox row where today it emits nothing at all** (the deferred branch sets a
flag and returns). Fixture 1 asserts exactly that row, so the behaviour change is pinned, not incidental.

**Why it is not a blocker for step 1:** the notification fires only when a cancel is actually *sent*, and the
affected population is 3 orders on `wms2-wineco-dev` with **zero on production**. So merging Fix A changes what
OMS receives for **no order anywhere** until someone replays a cancel — which is Fix E, a separate, deliberate
act. **Settle Q2 before Fix E, not before this merge.**

**Q3 — the 16 `nywh-hydra-uat` picking orders at 700 with all lines 800.** Their customer orders are all at
`CANCELED(800)` with no flag, so nothing is stuck; the producer is dead. **Out of scope**; tidy only if someone
wants the labels consistent.

---

## 11. Completeness Checklist

| # | Concern | Considered? |
|---|---|---|
| 0 | DB verified | ✓ §1 — six tenants, positive controls, `db_verified: true` |
| 1 | All call sites enumerated | ✓ §0 — three constant spellings + four predicate instruments. **And the affected _population_**, which a call-site sweep does not cover: §2.1's six-tenant census with a positive control per zero |
| 2 | Adjacent bugs | ✓ §0.1 A2 (`cancelOrderPosition`'s `< PACKED` work bound — the sibling that made the first design wrong), C1b, C2–C4, C5b, F1, F4 |
| 3 | Backward compatibility | ✓ §5.1 — additive payload field, nullable column; deploy order stated |
| 4 | Concurrency | ✓ §6 rows 2, 8; §3.2 write ordering |
| 5 | Multi-tenant | ✓ §1 — all six tenants; no cross-tenant query added |
| 6 | Error handling | ✓ §2.1 — A2's throw is narrowed, not removed; `[650,800)` still refused |
| 7 | Observability | ✓ §3.2 — `assertPickNotCancelled`'s `LOG.warn` gains the flag. No new metric (F3) |
| 8 | Rollback / migration | ✓ §3.4 — nullable + partial, no backfill, 24 rows estate-wide |
| 9 | Test coverage | ✓ §8 — incl. why the existing pins are vacuous |
| 10 | Cross-version v1↔v2 | **no** — v1 is reference-only; v2 is the only target |


---

## 12. Implementation Status

### Fix A (AC-1) — implemented, reviewed, **not pushed** (2026-09-15)

Worktree `.claude/worktrees/wms2-api/SBDEV-3363`, branch `bugfix/SBDEV-3363-deferred-cancel-terminal-path`,
off `origin/develop` `9e294d4b`.

| commit | what |
|---|---|
| `2a80ed7f` | the fix: a `continue` on an already-CANCELED position in both `cancelOrder` loops + the RAPID `isEmpty()` guard |
| `2879d898` | review fix pass — lane F's 5 Medium + 5 Low, lane G's 2 PARTIAL gaps |
| `e5ce8984` | re-review nits — lane H's 1 PARTIAL + 5 Low |

**`CustomerorderPositionService` is a 0-line diff**, confirmed by the conformance lane. The two mis-banded
guards there remain wrong and live; §3.1.1 says why, and the cancel-cascade doc's new §4.1 records it where a
future reader will meet it.

**Tests** — `src/test/java/net/aim_ai/wms/integration/CancelOrderAlreadyCancelledPositionIntegrationTest.java`,
five fixtures:

| # | method | role |
|---|---|---|
| 1 | `cancelOrder_shouldCancelOrder_whenEveryPositionAlreadyCancelled` | AC-1, the stranded shape |
| 2 | `cancelOrder_shouldNotFlipPickedPickLine_whenPositionAlreadyCancelled` | regression pin (CO 585000351) — green before **and** after; red only under the rejected design |
| 3 | `cancelOrder_shouldCancelOpenPosition_whenSiblingPositionAlreadyCancelled` | AC-1, mixed order |
| 4 | `cancelOrder_shouldNotThrow_whenRapidFirstPositionHasNoPickLines` | the A6 guard |
| 5 | `cancelOrder_shouldCancelUnitloads_whenRapidSideDoorRuns` | wiring pin for fixture 4 |

**Suite:** `mvn clean verify` → surefire `6629/0/0/1` (**identical to baseline**), failsafe `414/0/0/31`
(baseline `409` + these five), **BUILD SUCCESS**, 8m40s.

**Mutation checks — all measured, none predicted:**

| mutant | outcome |
|---|---|
| delete the guard-loop `continue` | KILLED — fixtures 1 and 3, `expected: 800 but was: 200` |
| delete the cancel-loop `continue` | KILLED — all three error with `BusinessException: order position is beyond status PACKED` |
| apply the **rejected** two-guard design | KILLED **by fixture 2 only** — `expected: 600`; 1 and 3 stay green |
| delete SBDEV-3332's flag clear | KILLED — *survived* until fixture 1 was reseeded `markedforcancellation = true` |
| neutralise the `isEmpty()` guard | KILLED — *survived the whole suite* until fixture 4 existed |
| break the RAPID section wiring | KILLED by fixture 5 — fixture 4 stays green, which is why 5 exists |

### Findings recorded during implementation

**I-1 — the RAPID side-door's demotion does not survive the cancel.** The block writes
`pickingOrder.setState(PROCESSABLE)`; `cancelOrder`'s position loop then calls `cancelOrderPosition`, whose
`allTerminal`/`allCanceled` tail re-settles the same picking order to `CANCELED(800)`. On an order owning all
of a picking order's lines the tote is never returned to the pool — the side-door's whole purpose. **Measured
by fixture 5**, which asserts `800` to record it. Pre-existing: both writes predate this ticket and no position
is CANCELED in that fixture, so the new skip never fires. Sub-T3 → stays on the ticket. No exposure: zero
orders in either RAPID section estate-wide, and production has no such section.

**I-2 — Testcontainers reuse makes the IT lane falsely red.** `v2/wms2-api/CLAUDE.md` instructs enabling
`testcontainers.reuse.enable=true`; doing so makes `ParcelMonitorViewServiceConcurrencyIT` fail on
`duplicate key … index_customerorder_externalnumber` on **every run after the first**. Accumulated rows, not a
code defect — it passes alone on a fresh container and this diff has zero references in it. Reuse turned back
off. Not a ticket; recorded so the next person does not spend the diagnosis again.

### Docs

`sbdocs/3-Resources/workflows/wms2-cancel-cascade-workflow.md` — new **§4.1** plus a changelog row in the
doc's own convention. `last_verified` deliberately not bumped (scope was §4.1 only).

### Still open on this ticket

Fix B (AC-5 / Option 3), Fix C (Mobile M-4), Fix D (AC-4 migration), Fix E (the two-row repair). Step 1 closes
**AC-1** and **unblocks** AC-6 — it does not close it.


### Fix D (AC-4) — submitted (2026-09-15)

Worktree `.claude/worktrees/wms2-api/SBDEV-3363-ac4`, branch
`bugfix/SBDEV-3363-cancellation-log-pickline-key`, commit `28a8a417` off `origin/develop` `9e294d4b`.
**PR https://github.com/SiteBossInc/wms2-api/pull/364** — independent of #362; either may merge first.

`V2.2.31` adds `pickingorder_position_id` (nullable) + a **partial, non-unique** index; the entity gains
the mapped field; `recordCancellation` populates it. Flyway version re-swept across all 286 remote refs
immediately before writing it.

**Tests:** `CancellationLogServiceUnitTest` (population) and `CancellationLogPickingorderPositionIdIT`
(Testcontainers — the index is partial, H2 cannot host it). Both mutation-checked: removing the
population line fails the first; dropping the `WHERE` clause fails the second. Each IT test asserts the
pre-fix **absence** first, so none is vacuous.

**Suite:** surefire `6630/0/0/1` (+1), failsafe `412/0/0/31` (+3), **BUILD SUCCESS**.

#### ⚠ I-3 — the deploy-safety claim I first made was FALSE, and the correction inverts the failure mode

The first draft of this commit argued that a stalled tenant would fail loudly at boot, because Hibernate
`ddl-auto=validate` rejects a missing mapped column. **Production runs `ddl-auto=none`**
(`application.properties:105`; `validate` is the commented-out line above it), and
`db/verify-tenant-schema-conformance.sh` already says so in its own header.

So there is **no boot-time schema check**. A tenant that misses `V2.2.31` boots healthy and fails on its
**first cancellation**: the INSERT names a column the table lacks → `42703` → transaction abort
(`25P02`) → and because `recordCancellation` is `MANDATORY`, **the caller's cancel rolls back**. That is
the same outcome the migration header refuses to accept for a `UNIQUE` index, reached by a different
door. Flyway failures never take the app down, and a tenant has frozen in production before (`V2.2.07`
on `wh01_hydra_v2`, 2026-08-05).

**Mitigation is a post-deploy verification, not boot:** run `db/verify-tenant-schema-conformance.sh` per
tenant; it derives its reference by replaying `db/migration`, so it picks up `V2.2.31` automatically and
reports `MISSING_COLUMN` as an ERROR. The estate was measured at `V2.2.30` / 0 failures on all six
tenants on 2026-09-15 — a snapshot, and silent about any tenant onboarded later.

The commit was amended before pushing, so the false claim never reached history.

#### I-4 — no FK, deliberately, and the consequence

`V2.2.28` added an FK to this same table, so the omission needed a stated reason:
`pickingorder_position` rows are genuinely deleted by
`CustomerorderService.checkAndCleanUpPickingOrderPositions` on a picking-date change, so an FK would
block that or need `ON DELETE SET NULL`. **The column can therefore dangle** — ids are never recycled so
the value stays unambiguous and the planned unique key is unaffected, but **anything joining on it must
outer join.**

### Fix B (AC-5) + Fix C (M-4) — implemented, review lanes running (2026-09-16)

Two worktrees, two commits, and **the API must merge first** (§5.1).

| repo | worktree | branch | commit | base |
|---|---|---|---|---|
| wms2-api | `.claude/worktrees/wms2-api/SBDEV-3363-ac5` | `bugfix/SBDEV-3363-deferred-cancel-terminal-path-ac5` | `af403931` | `4bef7e77` (= PR #364 merge) |
| wms2-mobile-ui | `.claude/worktrees/wms2-mobile-ui/SBDEV-3363-m4` | `bugfix/SBDEV-3363-m4-demand-cancelled` | `1e3d979` | `ab1e2ae` |

**Fix B is one commit, not two, on purpose.** The restored `markedforcancellation` trigger and the
demand-aware completeness gates each reproduce a *withdrawn* attempt on their own:

- the trigger alone is precisely what SBDEV-3332 removed and documented — the pick is refused AND
  nothing calls `finishPickingOrder`, so the order is unpickable and unfinishable;
- the gates alone promote nothing, because without the trigger an open line at 200/300 still counts as
  outstanding.

**The gate set was derived from the RULE** ("promotes a Pickingorder to PICKED"), not from a grep —
three counts (11 / 8 / 7) circulated on this ticket before anyone derived it. The derivation found
**six**, one of which is `confirmPick`'s repository-shaped
`countByPickingorderIdAndStateLessThan(...) == 0`. No stream-shaped grep finds that one, and it is the
gate that fires on the **last confirm**, i.e. the commonest completion path — leaving it raw would have
left the ordinary route blind.

| # | site | before |
|---|---|---|
| G-P1 | `PickingorderBusinessService.confirmPick` | `countByPickingorderIdAndStateLessThan(id, PICKED) == 0` |
| G-P2 | `MobilePickingService` (≈:239) | `noneMatch(state < PICKED)` |
| G-P3 | `MobilePickingService.releasePickingOrder` | `noneMatch(state < PICKED)` |
| G-P4 | `MobilePickingService` (≈:352) | hand-rolled early-return loop |
| G-P5 | `MobilePickingService` (≈:405) | `noneMatch(state < PICKED)` |
| G-P6 | `MobilePickingService` Case 2 `allPicked` | `noneMatch(state < PICKED)` |

`anyPicked` beside G-P6 is **deliberately left raw**: it selects Case 3 (return the order to the pool,
only when *nothing* was picked) and a cancelled line is not evidence that picking happened. Making it
demand-aware would be wrong in the other direction.

New helpers on `PickingorderBusinessService`: `isPickingOrderComplete(Long)` /
`isPickingOrderComplete(List<PickingorderPosition>)` and `findDemandCancelledPickLineIds(List)`. Reads
are **deliberately non-locking** (`findAllById`, never `findByIdForUpdate`) because
`rapidPickingScanSource` evaluates completeness while already holding a Pickingorder lock, so a
Customerorder lock here would invert the acquisition order `cancelOpenPickLines`' javadoc forbids.

**Fix C is two halves.** Server: the pick-list payload gains `demandCancelled`, the server's own
verdict from the same predicate the pick guard uses. Client: `store/picking.js` widens **both** sites
that decide a row is cancelled — the `getPickingOrderPositionsInfo` filter and the
`nextPickingPosition` landing rule. Swept for siblings: this store has **no** `previousPickingPosition`
mutation, so those two are the whole set. Both widen (`pickStatus !== 'Cancelled' && !demandCancelled`)
rather than replace, which is the deploy-order property — against an old API the field is absent,
`undefined` is falsy, and both sites behave exactly as they do today.

#### I-5 — a latent stale-save defect that only Fix B could reach

`MobilePickingService.releasePickingOrder` called `pickingorderRepository.save(pickingOrder)` and
discarded the result, then handed the **stale detached original** to `finishPickingOrder`, which saves
it again → `ObjectOptimisticLockingFailureException` on the Pickingorder. Fixed by reassigning. It was
unreachable before: the old gate never let a marked order with an open line get that far. Pre-existing,
sub-T3, and in the file this ticket is already editing → stays on this ticket.

#### Suite

| lane | baseline at `4bef7e77` | this branch (final) | delta |
|---|---|---|---|
| surefire | 6630 / 0 / 0 / 1 | 6644 / 0 / 0 / 1 | +14 — exactly the 14 tests the review pass added (8 + 4 + 2) |
| failsafe | 416 / 0 / 0 / 31 | 419 / 0 / 0 / 31 | +3, reconciled below |

The baseline is **not** a local re-run: it is the develop push CI run on this branch's exact base
commit — Actions run `35021686850`, `headSha 4bef7e77`, conclusion success. The +3 was reconciled
**per class**, not assumed: +2 is `DeferredCancelTerminalPathIntegrationTest`, and +1 is
`SequenceTransactionServiceConcurrencyIT`, which **CI excludes by name**
(`-Dfailsafe.excludes='**/SequenceTransactionServiceConcurrencyIT.java'`, visible in the run's command
line) and which runs locally. So the like-for-like comparison is 417 → 419. `BUILD SUCCESS`, 8m28s on the final run.

⚠ The first commit's suite (surefire `6630`, identical to baseline) was green **and the change had a
blocker in it**. A matching-the-baseline suite means "no regression the existing tests can see"; it
never meant the new code was covered. At that point `grep -rn "demandCancelled" src/test` returned
zero hits.

⚠ Worth recording for future baselines: **the CI command is not `mvn clean verify` bare.** It also
passes `-Dmaven.javadoc.skip=true -Dspringdoc.skip=true` and that one failsafe exclusion. A local
`clean verify` therefore runs strictly more than CI does, and quoting CI's totals as if they were the
local baseline is off by one test before anything is changed.

Mobile: 33 suites / 400 tests green (baseline 32 / 395; +1 suite / +5 tests are this commit's).

#### Mutation checks — measured

| mutant | outcome |
|---|---|
| remove `markedforcancellation` from `isDemandCancelled` | KILLED — the AC-5 test |
| revert one demand-aware gate to the raw `noneMatch` | KILLED — the AC-5 test |
| drop `demandCancelled` from the mobile **filter** | KILLED — the 2 filter tests only; landing tests stay green |
| drop `demandCancelled` from the mobile **landing rule** | KILLED — the 1 landing test only; filter tests stay green |
| either mobile mutant, against the two old-API back-compat tests | both stay GREEN — which is the point of those two |

The clean separation matters: it proves the two client sites are independently guarded rather than one
test covering both by accident.

#### Test fixture traps paid for on the way

`DeferredCancelTerminalPathIntegrationTest` gets **private H2 database names**
(`rollback_tenant_3363ac5` / `rollback_landlord_3363ac5`). `BaseRollbackIntegrationTest` pins two
*fixed* names with `ddl-auto=create-drop` shared by ~30 subclasses across *separate* Spring contexts,
so evicting any one context drops the schema out from under the others — the mechanism that reddened
PR #362 in CI while local was green. Recorded in full in the `wms2-baserollback-shared-h2-create-drop`
memory. Fixture gaps that only mutation-checking exposed: an Itemdata placeholder id, a `@NotNull`
`handlingunitId`, `@NotNull` Section `number`/`clientId`, and a missing Location — plus Location rows
accumulating across a non-transactional `@BeforeEach`, fixed by seeding idempotently via
`locationRepository.findByName(...).isEmpty()`.

#### Review lanes on Fix B + Fix C — and the blocker they found

Four independent lanes, all reports under `SBDEV-3363-evidence/`: `laneJ-conformance-fixbc.md`,
`laneK-api-review-fixbc.md`, `laneL-mobile-review-fixc.md`, `laneM-critic-fixbc.md`.

**Three of the four independently found the same blocker, and they were right.** The first cut of
Fix B converted **six** gates and claimed that was "every gate that promotes a Pickingorder to
PICKED". That rule is not the plan's rule. §2.2 says *"every site that decides whether a picking order
is complete and, on 'yes', hands control to `finishPickingOrder`"* — and §0.2 scopes **B1–B8, eight
sites**. The substitution silently dropped **P-8**, `MobilePickingService.rapidPickingScanSource`'s
accumulator-free early-return loop, where *falling through is the verdict* and `finishPickingOrder`
sits eleven lines below. No stream-shaped grep finds it, and the narrower rule cannot see it because
it promotes nothing.

⚠ **Leaving it raw was a REGRESSION, not an incomplete fix.** With `confirmPick`'s new gate promoting
a marked order to PICKED, that loop would find the order's unpickable line at 200/300, hand it back as
the next pick, and the handheld would steer the operator onto a scan `assertPickNotCancelled` refuses
— with the `rollbackFor` taking `pickinginprogress` with it, so the loop never breaks. Before Fix B
rapid picking terminated (wastefully: goods picked, then reversed). That is precisely the failure
SBDEV-3332 documented as its reason for removing the trigger, reintroduced by the fix that claims to
discharge it.

The lesson generalises and is the one to carry: **restating a rule in your own words is a silent
scope change.** The commit's "derived from the RULE, not a grep" was true of the derivation and false
of the rule it derived from.

| finding | lanes | disposition |
|---|---|---|
| **P-8 not converted** (blocker) | J-1, K-H-1, M-M-1 | **fixed** — demand-aware via the shared helper |
| `rapidPickingScanPackage`'s next-line selector hands back an unpickable line | M-M-1 | **fixed** — skips demand-cancelled lines |
| **C4 comment not updated** — the site that SETS the flag still asserted "NO TERMINAL PATH" | J-2, M-M-3 | **fixed** — plan §0.3 scoped it and the first pass missed it |
| `WmsConstants.PICK_CONFIRM_ORDER_CANCELLED` javadoc asserts the flag "cannot refuse a pick" | M-M-3 | **fixed** — it is the javadoc on the key the new refusal throws |
| `getPickingOrderSummaries`' SQL **mirror** of `isDemandCancelled` left stale | M-M-3 | **NOT changed — the lane's recommendation was wrong.** See the box below; the divergence is deliberate and load-bearing |
| `demandCancelled` emitted for already-PICKED lines, which the client then hides | K-M-3, M-M-5 | **fixed** — scoped to open lines; the field means *will never be picked*, and a picked line is not that |
| `startPickingOrder`'s null return discarded → a pick list built for an order just cancelled | K-M-2 | **fixed** — returns an empty list (a throw would roll the cancel back) |
| non-locking justification cited a witness that did not call the helper | J-3 | **fixed** — cites `getPickingOrderPositionsInfo` first, `rapidPickingScanSource` second |
| `confirmPick` comment described the rare branch as if it were the common one | K-M-1 | **fixed** — the real cost is 4 queries where there was 1, on every non-final pick; accepted, and why |
| five of six gates and the whole `demandCancelled` payload untested | J-4, K-M-4, M-M-4 | **fixed** — see below |
| the "five MobilePickingService gates" / "six" counts in javadoc | M-M-1 | **fixed** — replaced by the rule, which does not rot |

**⚠ RESIDUAL, deliberately not fixed, and it needs a decision.** Rapid picking still has no terminal
path when **every** open line is demand-cancelled — the ordinary shape there, since one parcel is
usually one customer order. The selector now skips those lines and falls through to
`throw new BusinessException("No picks left")`, which leaves the picking order open. It cannot be
finished inside that method's contract: it returns a `PickingorderPosition`, its caller dereferences
that with no null check, and every exit that would signal completion is a `BusinessException` the
caller's `rollbackFor` would use to roll the finish back. A terminal path needs the rapid endpoint to
carry a `pickCompleted` flag the way `rapidPickingScanSource`'s DTO already does — **a UI contract
change this ticket did not design.** Recorded in-code at both sites and in C4.

Exposure for both the residual and the fix is the same and is currently **zero**: `markedforcancellation
IS TRUE AND state <> 800` returns 0 rows on Hydra PRD, Hydra UAT, ShipItEZ UAT and WineCo UAT
(measured 2026-09-16). They are rails for the same producer, which is exactly why they must not ship
apart — and why the residual is worth a follow-up rather than a shrug.

#### ⚠ Deploy order — the plan had this BACKWARDS (M-2)

§5.1 says **API before mobile UI**, on the grounds that the UI degrades safely against an old API.
That argument is sound and was verified — but it is an argument for **UI-first**, and it says nothing
about the order actually planned.

**API-first with the old UI is the unsafe direction.** A marked order's lines sit at 200/300, so
`pickStatus` renders as a live state and the old filter keeps every row. The operator presses Pick,
the restored trigger refuses it, SBDEV-3319's rejection-path re-query faithfully returns the same row
— the filter cannot see `demandCancelled` — and the operator is parked back on an unpickable row.
That is verbatim the infinite-retry loop SBDEV-3319 opened H2 to fix, reintroduced on **regular**
picking for the duration of the window.

**Corrected guidance: deploy the UI first, or deploy both together.** The UI half is a no-op against
today's API (`undefined` is falsy at both sites), so shipping it early costs nothing and closes the
window before it opens. Zero live rows today makes the window theoretical right now; it stops being
theoretical the first time a deferred cancel fires.

#### Test coverage added in the review pass

Before it, `grep -rn "demandCancelled" src/test` returned **zero hits**, and the only references to
the new helpers were `thenReturn(true)` stubs that pin nothing.

| test | pins |
|---|---|
| `PickingorderBusinessServiceUnitTest.DemandAwareCompleteness` (8) | the predicate itself: the fast path, live demand, the deferred flag, the all-vs-any distinction, each of the four triggers independently, a broken chain read as LIVE, and both bulk-fetch argument sets |
| `MobilePickingServiceUnitTest.GetPickingOrderPositionsInfo` (+4) | `demandCancelled` true/false, open-line scoping, and the empty list when opening the pick list finished the order |
| `MobilePickingServiceUnitTest.RapidPickingDemandAwareCompleteness` (2) | **P-8** — the blocker, in both directions |

**PIT, scoped:** `isPickingOrderComplete` + `findDemandCancelledPickLineIds` + `isDemandCancelled` →
**31 mutants, 31 killed**. Two survived the first run and both were real gaps, closed by asserting the
**arguments** rather than the answer: a stub that answers `anySet()` returns the same list whatever it
is handed, so neither the null-`customerorderpositionId` guard nor the order-id collection step was
pinned. On `MobilePickingService`: the P-8 gate 3/3, the rapid selector 3/3, the `startPickingOrder`
null-check 1/1.

A third PIT survivor was **not** a missing test: a null-state guard on the new open-line filter is
unreachable, because the sort-chain filter above it already unboxes `getState()` on every row. The
dead branch was removed rather than tested for — adding the row NPEs, which is how it was found.

`map.put("demandCancelled", …)` generates **no PIT mutant at all**, so it was hand-mutated four ways —
remove, invert, rename the key, and pass all lines instead of open ones. All four killed, each with a
diagnostic naming the thing broken.

#### ⚠ One review recommendation was WRONG, and the suite is what caught it

Lane M's M-3 flagged `getPickingOrderSummaries`' SQL predicate as a stale mirror of
`isDemandCancelled` — the Java predicate honours `markedforcancellation` again, the SQL does not — and
recommended adding `AND co.markedforcancellation IS NOT TRUE`. The argument is clean and it is what I
did. **It is wrong, and adding it re-strands the order through a different door.**

The joins in that query are **INNER**, so a picking order composed solely of marked demand has zero
visible positions and **drops off the pick list entirely**. Every route that takes a marked order
terminal — opening it (`getPickingOrderPositionsInfo` → `startPickingOrder`), releasing it, or picking
its last live line — requires the operator to *select it from that list*. Hiding it removes the only
way to reach the terminal path AC-5 exists to build.

The term had existed before, was removed on purpose, and its removal fixed a **measured** regression:
WineCo UAT carried 69 marked orders across 37 picking orders, **16 of which had zero visible
positions** — unpickable *and* unfinishable. `PickingorderRepositoryIntegrationTest
.summariesDoNotExcludeMarkedForCancellation` exists precisely to red if anyone re-adds it. It did,
on the first full run after the change, with the assertion message stating the reason outright.

Three things worth keeping from this:

1. **"A mirror should mirror" is a plausible rule that is false here.** The divergence is intentional
   and asymmetric: the Java predicate decides *may this line be picked*, the SQL decides *may the
   operator SEE this order*. Those are different questions and a cancelled demand answers them
   differently.
2. **A review lane can be confidently wrong about a design.** Three lanes were right about the P-8
   blocker; one was wrong about this. Both were resolved the same way — by reading the code and
   running the suite, not by counting lanes.
3. The **accepted consequence** stands and is now documented in the repository javadoc: a marked order
   is listed with a live position count, and opening it cancels it and returns an empty pick list.
   That is the intended AC-5 flow, not a count bug.

#### Second sweep of the lane reports — four Low findings that the first fix pass left

Re-reading the three API lane reports end to end (rather than acting only on their blockers) surfaced
four more, all Low, all fixed. Recorded because the pattern is worth noticing: **the blockers were
loud and got fixed immediately; the Lows needed a deliberate second read.** That is the failure mode
the "address Low findings too" rule exists for.

| # | lanes | finding | disposition |
|---|---|---|---|
| 1 | K-L-1, K-L-4, M-M-7 | `@Transactional(readOnly = true)` on `isPickingOrderComplete(Long)` is **inert** — its only caller is `confirmPick`, in the same bean, so the proxy is bypassed and neither the propagation nor `readOnly` takes effect | **documented, not deleted.** It is correct that the reads join `confirmPick`'s read-write transaction (the predicate must see the caller's uncommitted pick). The annotation is kept for a future cross-bean caller, with an explicit warning not to read it as a guarantee — this repo has already measured a `NOT_SUPPORTED` mutant surviving a fully green suite for exactly this reason |
| 2 | K-L-3 | the non-locking justification cited callers, but the **structural** reason is stronger: a picking order can span several customer orders, so "lock the COs this PO's lines point at" is a data-dependent set, not one predictable acquisition | strengthened; `confirmPick` itself is now the first witness |
| 3 | K-L-7 | the sibling sweep for the `save()`-without-reassign fix found **one more site** with the same shape — `releaseRegularPickingOrder` Case 2 | **left as-is, with the reason written down.** It is safe because that method loads its entity from the repository inside its own transaction, so `save()` returns the same managed instance. `releasePickingOrder` takes its entity as a **parameter**, which can arrive detached — that is the whole difference. Now stated at the site so nobody copies the shape into a method that receives its entity as an argument |
| 4 | J-5, M-M-6 | **P-3** was in the plan's scoped B1–B8 set and was dropped silently | **excluded explicitly, in-code.** Its `hasFinishedPicks`/`hasOpenPicks` pair carries the same semantic falsehood, but the branch is structurally unreachable for the AC-5 shape: it is the reset path, it throws above on any line at exactly `PICKED`, and an all-demand-cancelled order has none. A silent omission and a reasoned exclusion look identical in a diff — which is precisely how P-8 got lost |

Two Lows were checked and need no change: **no boxed-comparison trap** was introduced (the state
constants are `int`, K-L-9), and `anyPicked`'s asymmetry is **inert** because Case 2 short-circuits and
returns before it is consulted (M-M-4) — the comment beside it is still worth keeping, since the two
sit together and look like they should match.

#### Fix B + Fix C — PRs submitted (2026-09-16)

| repo | branch | commits | PR |
|---|---|---|---|
| wms2-api | `bugfix/SBDEV-3363-deferred-cancel-terminal-path-ac5` | `af403931`, `546c9c3e`, `beac7472` | **https://github.com/SiteBossInc/wms2-api/pull/365** |
| wms2-mobile-ui | `bugfix/SBDEV-3363-m4-demand-cancelled` | `1e3d979`, `60d9290` | **https://github.com/SiteBossInc/wms2-mobile-ui/pull/69** |

⚠ **Merge mobile-ui#69 BEFORE api#365**, or both together — the reverse of what §5.1 says. The
reasoning is in the *Deploy order* box above and in both PR bodies. mobile-ui#69 is a no-op against
today's API, so shipping it early costs nothing.

**Still open on this ticket:** Fix E (replay the cancel for the two stranded orders; §10 Q2 on the
OMS-side behaviour needs settling first) and the rapid-picking residual recorded above, which needs a
`pickCompleted` flag on the rapid endpoint and therefore a product decision rather than a code review.

#### CI on both PRs — green, and the baseline reconciliation holds in both directions

| PR | check | result |
|---|---|---|
| wms2-api#365 | `test` | **pass**, 10m9s (`build` correctly `skipping` — the image job is push-only) |
| wms2-mobile-ui#69 | `layout` | **pass**, 1m32s |

wms2-api#365's CI lanes: surefire `6644/0/0/1` — **identical to the local run** — and failsafe
`418/0/0/31` against a local `419`. That difference of exactly 1 is
`SequenceTransactionServiceConcurrencyIT`, which CI excludes by name and which runs locally.

This closes the reconciliation from both ends. Predicted before the PR existed: CI develop baseline
`416` + 2 new tests = `418`; local-equivalent `417` + 2 = `419`. Both landed on the nose, which is what
makes "+3 versus the CI baseline" a *reconciled* delta rather than an unexplained one.

#### Fix B + Fix C — MERGED (2026-09-16), UI first

| order | repo | PR | merge commit |
|---|---|---|---|
| 1st | wms2-mobile-ui | [#69](https://github.com/SiteBossInc/wms2-mobile-ui/pull/69) | `5b1d3363` |
| 2nd | wms2-api | [#365](https://github.com/SiteBossInc/wms2-api/pull/365) | `e113467b` |

Merged in that order deliberately — the reverse of what §5.1 said. The UI half landed first and was a
no-op until the API half followed twelve seconds later, so the API-first window described in the
*Deploy order* box never opened.

Merging to `develop` **is a dev deploy**, so this is now live on dev. The API merge's own push run
gates the image build (`build` declares `needs: test`); a red run there means develop silently stops
deploying, which is the right direction to fail but is only visible in the Actions tab.

**AC-5 and Mobile M-4 are closed.** What remains on the ticket is **Fix E** (replay the cancel for the
two orders stranded since 2026-02-06 — §10 Q2 on the OMS-side behaviour must be settled first) and the
**rapid-picking residual** recorded above, which needs a `pickCompleted` flag on the rapid endpoint and
is therefore a product decision, not a code change this ticket can make.

---

## 13. Q2 — SETTLED (2026-09-16)

Two lanes: `SBDEV-3363-evidence/laneO-q2-wms-side.md` (sending side, measured by me) and
`laneN-oms-cancel-contract.md` (receiving side, traced in `oms-laravel-api`). Both claims below that
matter were independently re-verified against `origin/develop` before being written here.

### The answer in one line

**Replaying the cancel is safe *if and only if* the two orders' parcels are still pre-ship in OMS — and
nothing in either system checks that for you.**

### What is now known

**1. The message is ordinary, not exotic.** The worry was that Fix E makes these orders emit something
they never have. True, but `ORDER_BATCH_CANCELLED_FROM_WMS` is a message production OMS receives and
accepts routinely — Hydra PRD's outbox holds 3, all `SENT`, from 2026-09-10. A replay is a well-trodden
message arriving late. Each environment also points at its own OMS (dev→dev, UAT→UAT, prd→prd), so there
is no cross-environment hazard.

**2. ⚠ There is no kill switch, and two sysprops claim otherwise.**
`WEBSERVICE_ORDER_BATCH_CANCELLED_ACTIVATED = 'false'` on every tenant including **production**, and
**nothing reads it** — its only non-declaration reference is a commented-out line in
`UtilRestController`. `WEBSERVICE_BEHAVIOUR` (`send`/`discard`/`keep`) is dead the same way. Positive
control: the sibling `..._UPDATE_PICKING_DATE_ACTIVATED` and `..._UPDATE_PRIORITY_ACTIVATED` gates *are*
read at real call sites, so the instrument works. **Do not plan Fix E assuming the sysprop holds the
message back.**

**3. ⚠ The OMS handler is a flat, state-blind cancel.** `LegacyPositionCancelService` has **no**
terminal-state guard. Verified directly: every `parcel_status` / `qa_status` reference in it is either
the compare-and-set that gives it idempotency or the write itself. Its OMS-initiated sibling
`LegacyOrderCancelService` *does* carry one — `UNCANCELABLE_PARCEL_STATUSES = [4, 5, 11..18, 20, 21, 27,
28, 29]`. So a WMS-originated cancel can overwrite Shipped/Returned/Completed where an OMS-originated one
would refuse. **The asymmetry is the whole risk.**

**4. It is idempotent for the already-cancelled case.** Per-item CAS: if every item is already at 28, it
claims 0, no inventory moves, and it returns success. So the "no-op" outcome is genuinely harmless.

**5. The inventory credit is unscoped.** `returnInventoryToAvailable` filters on `product_id` alone — no
`facility_code`, no `client_id`, no `LEAST(…, quantity_on_hand)` clamp — while its OMS-initiated sibling
filters on facility and clamps. On a multi-facility tenant a replay over-credits every other facility.

**6. No age check exists anywhere on the path**, confirmed with a positive control. February is exactly
as cancellable as today — which is the hazard, not a comfort, because the seven-month gap is precisely
where the order may have changed state.

### The one thing that decides it — and it is BLOCKED

```sql
-- against the WineCo OMS tenant DB, per stuck order
SELECT p.parcel_id, p.parcel_status, p.ship_date, oip.qa_status, oip.product_id, oip.assigned_quantity
  FROM parcel p
  JOIN batch_criteria bc ON bc.batch_criteria_id = p.batch_criteria_id
  LEFT JOIN order_item_parcels oip ON oip.parcel_id = p.parcel_id
 WHERE bc.batch_label = '<customerorder_batch.batchid>'
   AND (p.parcel_id_str = '<customerorder.externalnumber>' OR p.parcel_id = '<customerorder.externalnumber>');
```

| result | replay outcome |
|---|---|
| no matching parcel | **no-op** — 200 with an error body, WMS marks SENT, nothing written |
| every `qa_status = 28` | **no-op** — CAS claims 0, no inventory movement |
| `qa_status ≠ 28` and parcel pre-ship | **the intended cancel** — this is the repair working |
| `qa_status ≠ 28` and parcel in `{4,5,11..18,20,21,27}` | **HARMFUL** — terminal state overwritten, no audit row, inventory credited for shipped goods. Repair out-of-band instead |

**I cannot run it.** The MCP roster on this machine carries WMS tenant and landlord databases only —
there is no OMS database connection. This is the single blocker on Fix E, and it is an access problem,
not an analysis one.

**Second open item — WHICH OMS answers, and it is still open.** The lane's summary reported this as
resolved (*"`OMS_TENANT_ID = wineco` → OMS v2 Laravel"*). **That inference does not hold and is not
recorded as settled here.** `OMS_TENANT_ID` is a value WMS *sends* — `HttpRestService.applyHeaders`
turns it into an `x-tenant` header — so it says what WMS believes about the tenant, nothing about which
*application* is listening. The lane's own report is properly hedged (*"I could not inspect the v1 Zend
OMS source at all"*); only the summary over-claimed.

What is actually established:

- the v2 Laravel route **does** exist — `routes/legacy-services.php` → `cancelPosition`;
- the `/services/call/` prefix is a **v1-compatibility shape**, and v2's file is literally named
  `legacy-services.php` — i.e. v2 reimplements v1's routes, so **both systems can plausibly serve this
  path on different hosts**. The route existing in v2 is therefore not evidence that v2 is the one
  answering;
- `/home/nampark/dev/wms-claude/v1/oms` **is absent from this machine**, so v1 cannot be inspected or
  ruled out.

⚠ **And the one piece of evidence that looked decisive cuts the other way.** v2 Laravel ships
`app/Multitenancy/HeaderTenantFinder.php`, which reads `$request->header('X-Tenant')` — *exactly* the
header WMS sends. But it is **not wired**: `config/multitenancy.php` sets
`'tenant_finder' => \App\Multitenancy\DomainTenantFinder::class`, and the only reference to
`HeaderTenantFinder` anywhere in the repo is its own class declaration. So v2 has a purpose-built
consumer for WMS's tenant header that nothing activates — **the third dead control in this one chain**,
after the two WMS sysprops. If v2 *is* the receiver, tenant resolution happens by domain and the
`x-tenant` header WMS carefully sets is ignored.

If WineCo dev still talks to the v1 Zend OMS, findings N-F1–N-F8 describe the wrong system and the
receiving side needs re-tracing. **One `curl` against the host, or one question to whoever owns that
deployment, settles it.**
Worth one `curl` against the host, or one question to whoever owns that deployment.

### Ask

1. **An OMS tenant DB connection** (or someone to run the query above for CO `28848660` and `28857575`).
2. **Confirmation of which OMS serves `api-oms.dev.sbo.li`** — v2 Laravel or v1 Zend. Not inferable from anything on this machine; see above for why the obvious inference fails.
3. If the tenant has more than one `product_inventory` row per implicated `product_id`, the replay
   over-credits the other facilities and the repair needs a manual correction afterwards.

With (1) and (2) answered, Fix E is a ten-minute job with a known outcome. Without them it is a guess,
and the harmful branch is unrecoverable without a manual inventory correction.

### Proposed, not filed — findings that stand regardless of the replay

| # | severity | finding |
|---|---|---|
| N-F1 | **High** | `LegacyPositionCancelService` has no terminal-state guard; its OMS-initiated sibling does. A WMS cancel can overwrite Shipped/Returned/Completed |
| N-F2 | **High** | `returnInventoryToAvailable` filters on `product_id` only — no facility, no client, no on-hand clamp, and never decrements `quantity_inv_allocated` |
| N-F4 | **High** | `/services/call/cancelPosition` carries `Route::middleware('api')` only — no auth. WMS sends Basic auth; nothing reads it |
| N-F3 | Medium | `updateBatchStatusIfAllParcelsCancelled` counts with `!= 28`, which is NULL-blind, so a NULL-status sibling parcel can trigger a premature batch cancel |
| O-F7 | Medium | the two inert WMS sysprops above — a dead switch is worse than no switch, because it is indistinguishable from a working one until someone relies on it |
| N-F5/F6/F8 | Low | no `parcel_status_history` row on cancel; the OpenAPI annotation says status 5 while the code writes 28; an unused import |

N-F1, N-F2 and N-F4 are in **OMS**, not WMS, and N-F4 is an unauthenticated write endpoint — they belong
to whoever owns `oms-laravel-api`, and none of them is this ticket's to fix.

---

## 14. Fix E — CLOSED as NOT REQUIRED (2026-09-16)

Full evidence: `SBDEV-3363-evidence/laneP-wineco-v1-reality-check.md`.

Nam clarified that **WineCo runs WMS v1 in production today** and moves to v2 in a few weeks. Checking
their real data inverted the premise this plan was built on.

**`customerorder.externalnumber` — the identity WMS sends OMS — reads `DaveTest20240205-05_1` and
`DaveTest20240207-02_1`.** Both are hand-made test orders created on `wms2-wineco-dev` in February while
somebody exercised the cancel flow. **In live v1 both are `FINISHED(700)` and shipped.** The order
*numbers* collide with real WineCo orders only because WMS mints `number` sequentially per tenant and dev
was seeded from a migration snapshot.

So: no customer was waiting; the rows are the **reproduction** of the defect rather than victims of it;
and replaying the cancel would be a **guaranteed no-op**, because that `externalnumber` matches no OMS
parcel. **§10 Q2 does not gate Fix E** — the decisive fact was available in WMS the whole time.

**Cutover inherits nothing dangerous**: zero stranded orders, 69 flag-residue rows at `state = 800`
(SBDEV-3332's runbook drains them), and no real `RAPID_PICKING` usage — WineCo's only such section is
named `test_section`, 29 picking orders, all FINISHED, newest 2022-03-13, against ~66,000 `TOTES_ON_CART`
picking orders.

### ⚠ The methodological lesson, which is the durable part

**An order number is not an identity.** Two censuses in this ticket — the flag census and the
stranded-shape census — *agreed with each other*, were *both correct about the data*, and both invited a
conclusion about the business that was wrong. Neither looked at `externalnumber`. The tell was one column
away for the entire ticket, and the agreement between two instruments was actively reassuring.

That is a sharper failure than the usual "two instruments disagree, and the disagreement is the finding":
here they agreed, and the *shared blind spot* was the finding. Generalised: **when a row's significance
depends on it representing something in another system, verify the cross-system identity field before
inferring impact** — agreement between instruments that share an assumption is not corroboration.
