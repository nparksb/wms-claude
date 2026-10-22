---
ticket: SBDEV-3363
lane: B — Option 3 architecture / predicate-site enumeration
author: arch-option3 (subagent)
date: 2026-09-15
base: v2/wms2-api @ origin/develop
status: complete
---

# Lane B — Option 3: predicate sites, `isDemandCancelled` exposure, AC-5 gating, AC-4 migration

## 0. Base-revision correction (read this first)

The task brief names `origin/develop` HEAD as **`4847e978`**. That is **stale**. Measured:

```
$ git rev-parse origin/develop
9e294d4b7fa1a1ce41eca69a6987a5fffa0f2bcc
$ git merge-base --is-ancestor 4847e978 origin/develop  -> true
```

`4847e978` ("Merge pull request #361 from ...SBDEV-3332-deferred-cancel-flag-lifecycle") is now **5 commits
behind** the tip. The five newer commits are all SBDEV-2778 (returns / auto-receive):
`17577cb8`, `c5a471d7`, `dbdf3436`, `a6a353fc`, `9e294d4b`.

**Every claim in this report is derived from `9e294d4b`**, via `git show origin/develop:<path>`, never the
working tree (which sits on `bugfix/SBDEV-3295-tenant-schema-conformance`).

I checked whether the 5-commit drift touches anything in scope: `git diff --name-only 4847e978 origin/develop`
is confined to the returns/auto-receive surface — see §6 for the exact list. None of the picking predicate
sites moved.

---

## 1. Re-derived predicate-site list (task item 1)

### 1.1 Derivation method, and its blind spots

I did **not** grep for a single pattern. Completeness words below are scoped to the union of four
instruments, each with a stated blind spot:

| # | Instrument | Command | Blind spot |
|---|---|---|---|
| **A** | Stream quantifiers | `git grep -nE 'allMatch\|noneMatch\|anyMatch' origin/develop -- 'src/main/**/*.java'` | misses hand-rolled loops, misses `filter().count()`, misses repository-derived predicates |
| **B** | Boolean-accumulator **name** heuristic | `git grep -nE 'boolean\s+(all\|any\|none\|every\|is\|has)[A-Za-z]*\s*='` | **misses accumulator-free early-return loops** (it did — see site P-8, found only by reading), and misses any accumulator named outside that vocabulary |
| **C** | State-comparison **census** (second instrument, per repo rule) | `git grep -nE 'getState\(\)\s*(<\|>\|<=\|>=\|==\|!=)\|State\.(PICKED\|FINISHED\|PACKED\|PALLETIZED\|CANCELED\|PENDING\|STARTED\|PROCESSABLE\|ASSIGNED)'`, then `uniq -c` by file to rank | ranks files, does not classify sites; I then read the top files in full |
| **D** | Repository-derived predicates | `git grep -nE 'countBy[A-Za-z]*State\|existsBy[A-Za-z]*State\|StateLessThan\|StateGreaterThan\|AndState'` | misses `@Query` JPQL/native predicates whose method name does not encode the state |

Instrument C's census put `MobilePickingService` (68 hits) and `PickingorderBusinessService` (61) an order of
magnitude above everything else, and `CustomerorderService` (36) / `CustomerorderPositionService` (17) next.
I read those four files' relevant regions end-to-end rather than trusting the greps.

**Positive control for the zero-results claims.** Instrument A is not a false zero: it returns 34 hits across
src/main, including non-picking ones (`MobilePutAwayService:449`, `BillofladingPositionService:54`). Instrument
D is not a false zero: it returns ~60 hits, of which exactly one
(`PickingorderPositionRepository:125 countByPickingorderIdAndStateLessThan`) is a pick-line completeness
predicate. Instrument B is not a false zero: 40+ hits. `grep` here is ugrep, but all four instruments are
`git grep`, which is unaffected by the binary-skip trap.

**Residual blind spot I cannot close by grep:** a predicate expressed in SQL inside an `@Query`, or one
expressed in the two UIs. Not swept. Also not swept: `src/test`.

### 1.2 The sites

Constants: ASSIGNED=200 · PROCESSABLE=300 · STARTED=500 · PENDING=550 · **PICKED=600** · PACKED=650 ·
PALLETIZED=670 · **FINISHED=700** · **CANCELED=800**.

**The single most important structural fact, and it inverts the premise of the old site list:**
almost every one of these predicates is written as `state < PICKED` (or `>= FINISHED`), **not** `== PICKED`.
Because **CANCELED is 800**, a cancelled line is *already* counted as "not open" / "terminal" by the
ordering. These predicates are **not** broken by a CANCELED line. What is broken is what happens *after*
they answer "complete" — the handoff into `finishPickingOrder`.

Sites below are grouped by what they actually are. Line numbers are as of `9e294d4b` and **will drift** —
the quoted snippet is the identifier.

#### Group 1 — pick-line completeness predicates (the "allFinished" family)

| ID | File / method | Predicate (verbatim) | Decides | Does a CANCELED(800) line make it answer *wrongly*? |
|---|---|---|---|---|
| **P-1** | `MobilePickingService.resumePickingOrderIfExists` (~:242) | `boolean allFinished = poPositions.stream().noneMatch(p -> p.getState() < WmsConstants.State.PICKED);` | whether to promote PO to PICKED and call `finishPickingOrder` | **No.** 800 ≮ 600, so a cancelled line already counts as complete. |
| **P-2** | `MobilePickingService.releasePickingOrder(Pickingorder)` (~:266) | `boolean allFinished = poPositions.stream().noneMatch(pickingPosition -> pickingPosition.getState() < WmsConstants.State.PICKED);` | same | **No**, same reason. |
| **P-3** | `MobilePickingService.releasePickingOrder(Pickingorder)` (~:290-291, **hand-rolled**) | `boolean hasFinishedPicks = false; boolean hasOpenPicks = false;` … `if (pick.getState() >= WmsConstants.State.PICKED) { hasFinishedPicks = true; … continue; } hasOpenPicks = true;` | PO → FINISHED / PROCESSABLE / CANCELED | **Yes, in principle** — a cancelled line sets `hasFinishedPicks`, which is wrong *semantically* ("something was picked"). **But the branch is structurally unreachable for an all-cancelled order** — see §1.3. |
| **P-4** | `MobilePickingService.startPickingOrder` (~:341, **hand-rolled**) | `boolean allFinished = true; for (…) { if (pickingPosition.getState() < WmsConstants.State.PICKED) { allFinished = false; break; } }` | same as P-1 | **No.** |
| **P-5** | `MobilePickingService.finalizePickingOrderForStart` (~:398) | `boolean allFinished = poPositions.stream().noneMatch(p -> p.getState() < WmsConstants.State.PICKED);` | same as P-1 | **No.** |
| **P-6** | `MobilePickingService.releaseRegularPickingOrder` — "Case 2" (~:737-738) | `boolean allPicked = popList.stream().noneMatch(pop -> pop.getState() < WmsConstants.State.PICKED);`<br>`boolean anyPicked = popList.stream().anyMatch(pop -> pop.getState() >= WmsConstants.State.PICKED);` | Case 2 (finish) vs Case 3 (reset to pool) vs Case 4 (refuse) | **No** for `allPicked`. **Yes** for `anyPicked` — an all-cancelled PO has `anyPicked == true`, so it can never take Case 3's "reset to pool" arm. Benign today (Case 2 fires first). |
| **P-7** | `PickingorderBusinessService.confirmPick` tail (~:1098, **repository-derived — instrument A misses this entirely**) | `long unpickedCount = pickingorderPositionRepository.countByPickingorderIdAndStateLessThan(pickingOrder.getId(), WmsConstants.State.PICKED);`<br>`if (unpickedCount == 0 && pickingOrder.getState() < WmsConstants.State.PICKED) {` | promote PO to PICKED after the last confirm | **No.** |
| **P-8** | `MobilePickingService.rapidPickingScanSource` (~:1352, **hand-rolled, accumulator-free early return — instruments A *and* B both miss this**) | `for (PickingorderPosition pp : pickingorderPositionRepository.findByPickingorderId(pickingOrder.getId())) { if (pp.getState() < WmsConstants.State.PICKED) { … dto.setPickCompleted(false); return dto; } }` | whether rapid picking hands the operator another line or finishes | **No.** |
| **P-9** | `PickingorderBusinessService.finalizePickingOrderIfTerminal` (~:588, :591) | `if (!poPositions.stream().allMatch(p -> p.getState() >= WmsConstants.State.FINISHED)) { return; }`<br>`boolean allCanceled = poPositions.stream().allMatch(p -> p.getState() == WmsConstants.State.CANCELED);` | PO → CANCELED vs FINISHED | **No** — this one is *already* explicitly cancel-aware. It is the shape the others should be measured against. |
| **P-10** | `CustomerorderPositionService.cancelOrderPosition` tail (~:155, :157) | `boolean allTerminal = poPositions.stream().allMatch(p -> p.getState() >= WmsConstants.State.FINISHED);`<br>`boolean allCanceled = poPositions.stream().allMatch(p -> p.getState() == WmsConstants.State.CANCELED);` | same as P-9 (it is P-9's stated sibling) | **No** — also already cancel-aware. |
| **P-11** | `CustomerorderService.forceCancelOrder` (~:459) | `if (poPositions.stream().allMatch(losPickingPosition -> losPickingPosition.getState() >= WmsConstants.State.FINISHED)) { pickingOrder.setState(PICKED); pickingorderBusinessService.finishPickingOrder(pickingOrder); }` | settle the PO after a forced cancel | **Yes, latently** — this is the *un-migrated* copy of P-9/P-10's old shape. It is saved only by `finishPickingOrder`'s `!= CANCELED` test (§4). It also sits in a branch the code itself documents as unreachable (`state < PACKED` under a caller gated on `isPackedOrPalletized`). |

#### Group 2 — customer-order-position completeness predicates (a different unit — do not conflate)

| ID | File / method | Predicate (verbatim) | Note |
|---|---|---|---|
| **C-1** | `PickingorderBusinessService.finishPickingOrder` (~:277-278, **hand-rolled**) | `boolean allPositionsDone = true; boolean hasPendingPositions = false;` … `if (cop.getState() == WmsConstants.State.PENDING) { hasPendingPositions = true; } if (cop.getState() < WmsConstants.State.PENDING) { allPositionsDone = false; break; }` | promotes the **Customerorder** to PENDING/PICKED. A CANCELED(800) COP is `>= PENDING`, so it is counted as done — arguably right, definitely not obviously right. |
| **C-2** | `PickingorderBusinessService.confirmPick` (~:1058-1059, **hand-rolled**) | identical accumulator pair to C-1, over `findByOrderIdForUpdate` | same |
| **C-3** | `PickingorderBusinessService.confirmPick` (~:1012) | `boolean hasOpenPicks = poPositions.stream().anyMatch(pick -> pick.getState() < WmsConstants.State.PICKED);` | COP → STARTED vs PENDING on a short pick |
| **C-4** | `CustomerorderService.cancelOrder` (~:798) | `if (coPositions.stream().anyMatch(position -> position.getState() >= PACKED && position.getState() < WmsConstants.State.CANCELED))` | the **half-open** band guard; already excludes 800 by construction |

#### Group 3 — *not* pick-completeness, listed only so nobody re-finds them and files them
`CustomerorderBatchService:377/379/1190` (batch-of-**orders** finality, same `allFinal`/`allCanceled` shape,
correct), `CustomerorderService:337` (`hasPickingStarted`, SBDEV-1615), `MobilePutAwayService:449`,
`BillofladingPositionService:54`.

### 1.3 Reconciliation with the old 9-site list

The SBDEV-3319 "API H-1" list — `MobilePickingService` :247, :274, :355, :403, :602, :740, :1352, :1432 and
`CustomerorderService` :448 — is **not** on disk anywhere in `sbdocs/` (`grep -rln "SBDEV-3319" sbdocs/` returns
four files, none of which is a 3319 plan; positive control: the same grep for `SBDEV-3320` hits its evidence
dir). So I reconciled it against the code rather than against the original text.

**Confirmed, with drift (7 of 9).** Every one maps to a real construct, all shifted by 4-9 lines:

| old | now | what it actually is |
|---|---|---|
| :247 | **:242** | P-1 |
| :274 | **:266** | P-2 |
| :355 | **:341** | P-4 |
| :403 | **:398** | P-5 |
| :602 | **:592** *(`processPick`'s `if (pickingOrder.getState() == PICKED) { finishPickingOrder(...) }`)* | **not a predicate** — a `finishPickingOrder` call site |
| :740 | **:737/:738** | P-6 |
| :1352 | **:1352** *(unmoved)* | P-8 |
| :1432 | **~:1441** *(`rapidPickScanPackageToVerify`)* | **not a predicate** — reads `pickingOrder.getState()` only, never a line state |
| CO :448 | **:459** | P-11 |

**Corroboration that the drift is exactly this:** `releaseRegularPickingOrder`'s own in-code comment on
`origin/develop` still names the *old* numbers — `"This branch had the same missing-clear as five sibling call
sites in this file (:247, :274, :355, :403, :592)"` — i.e. the list is the **`finishPickingOrder` call-site**
list from SBDEV-3262, not a predicate list. Two of its nine entries (:602→:592 and :1432) are call sites with
no line-state predicate at all.

**Drifted: 9 of 9** (7 by a few lines, and :1432 also changed meaning).
**Confirmed as genuine predicate sites: 7 of 9.**
**Sites the old list MISSED — 5, and two of them are the ones that matter:**

1. **P-7** `confirmPick`'s `countByPickingorderIdAndStateLessThan` — a **repository-derived** predicate. Neither
   an `allMatch` grep nor a boolean-name grep can see it. It is the predicate that actually promotes a PO to
   PICKED on the last confirm, i.e. the one that *starts* every "is it complete" cascade.
2. **P-3** `releasePickingOrder`'s `hasFinishedPicks`/`hasOpenPicks` pair.
3. **P-9** `finalizePickingOrderIfTerminal` (new since 3319 — SBDEV-3319 itself added it).
4. **P-10** `CustomerorderPositionService.cancelOrderPosition`'s tail.
5. **C-1/C-2/C-3** the customer-order-position family in `PickingorderBusinessService` — a different unit, and
   the old list covered none of it.

### 1.4 The finding that should change the plan

**Not one predicate in Group 1 is broken by a CANCELED line in the way "Option 3" is framed.**

They are written as `state < PICKED` / `>= FINISHED`, and CANCELED is **800**, the top of the ladder. A cancelled
line is *already* "not open" to all of them. Derivation: I read every Group-1 predicate verbatim (table above)
and checked each against 800. Blind spot: I did not check the two Nuxt UIs, which hold their own copies of state
bands.

The two exceptions are both `anyMatch`-shaped, not `allMatch`-shaped, and neither is currently harmful:
- **P-6** `anyPicked` — an all-cancelled PO is falsely "partially picked"; masked because `allPicked` wins first.
- **P-3** `hasFinishedPicks` — same falsehood; **structurally unreachable** for an all-cancelled PO. Proof from
  the method's own control flow, in order: `allFinished` is computed; `if (allFinished && state <= PICKED)
  { setState(PICKED); }`; `if (state == PICKED) { finishPickingOrder(); return; }`; `if (state > PICKED)
  { return; }`. Reaching the `hasFinishedPicks` block therefore *requires* `allFinished == false`, i.e. at least
  one line strictly below 600 — which an all-800 order does not have.

**So the real defect is not the predicates. It is the handoff.** Every Group-1 predicate that answers "complete"
hands control to `finishPickingOrder`, and that method opens with

```java
if (pickingOrder.getState() >= WmsConstants.State.FINISHED) {
    LOG.warn("Order is already finished. => Cannot finish.");
    throw new FacadeException("ORDER_ALREADY_FINISHED");
}
```

and seeds `int orderState = WmsConstants.State.CANCELED;`, promoting to FINISHED only for a line that is
`>= PICKED && != CANCELED`. **Any "Option 3" that only rewrites the predicates changes nothing**, because the
predicates already say "complete". What has to change is `finishPickingOrder`'s *tolerance* — and SBDEV-3319
already changed exactly that, for two of the three cancellation levels (§2).

---

## 2. `isDemandCancelled` — what it is, what was removed, and how to expose it (task item 2)

`src/main/java/net/aim_ai/wms/service/PickingorderBusinessService.java` (~:851). Verbatim:

```java
    /**
     * True when the pick's demand is cancelled at ANY level of the chain.
     *
     * <p>TWO levels, and they are not redundant — each is reachable without the other:
     * <ul>
     *   <li>picking position only — {@code CustomerorderPositionService.cancelOrderPosition} cancels
     *       one line and leaves the order open (this is the shape live on Hydra PRD);</li>
     *   <li>customer order state only — {@code cleanUpCancelledOrder} used to cancel the order and its
     *       order positions while leaving the pick lines untouched.</li>
     * </ul>
     *
     * <p>A third level — the {@code markedforcancellation} flag — was a trigger here and was removed
     * when this ticket was split; see the note on the return statement and SBDEV-3332.
     */
    private static boolean isDemandCancelled(PickingorderPosition pickingPosition,
                                             CustomerorderPosition coPosition,
                                             Customerorder customerOrder) {
        if (pickingPosition != null && pickingPosition.getState() != null
                && pickingPosition.getState() == WmsConstants.State.CANCELED) {
            return true;
        }
        if (coPosition != null && coPosition.getState() != null
                && coPosition.getState() == WmsConstants.State.CANCELED) {
            return true;
        }
        if (customerOrder == null) {
            return false;
        }
        // ⚠ markedforcancellation is deliberately NOT a trigger — see SBDEV-3332. A deferred-cancel
        // order has no terminal path: its only consumer, finishPickingOrder, requires every line
        // already PICKED. Refusing the pick as well would leave the order unpickable AND
        // unfinishable — stranded rather than cancelled. Add this back only together with a
        // completion path that works in regular picking.
        return customerOrder.getState() != null && customerOrder.getState() == WmsConstants.State.CANCELED;
    }
```

### 2.1 What it triggers on today — exactly three tests, in this order

1. `pickingPosition.getState() == CANCELED` — the pick line itself.
2. `coPosition.getState() == CANCELED` — the customer-order line.
3. `customerOrder.getState() == CANCELED` — the order.

Each is null-tolerant on both the entity and the boxed `Integer`. A `null` link is "not cancelled" by design —
the sibling `assertPickNotCancelled` javadoc states why: *"a position with no customer-order position is
malformed data, and the existing `orElseThrow(EntityNotFound)` sites downstream are the right place to report
that — turning it into a cancellation message here would mislabel a different defect."*

**Derivation for "exactly three":** the whole method body is quoted above; there is nothing else in it. No blind
spot.

### 2.2 What SBDEV-3332 deliberately removed — do not silently reverse this

`markedforcancellation` was a **fourth** trigger and was taken out. There are **four** ⚠ comments across
two files that encode that decision, and they are mutually reinforcing; all four must be read together before
anyone puts it back:

1. **In `isDemandCancelled` itself** (quoted above): *"Add this back only together with a completion path that
   works in regular picking."*
2. **In `assertPickNotCancelled`**: `// markedforcancellation is deliberately NOT logged: it can never be the
   reason this line was reached (see isDemandCancelled), and printing it invites the conclusion that it can.`
   → **restoring the trigger makes that comment false**, and the `LOG.warn` immediately below it will then be
   under-reporting the actual reason a pick was refused. That log line needs the flag added in the same edit.
3. **In `finishPickingOrder`'s G4 branch**: `// ⚠ Deliberately NOT covering the deferred cancel
   (markedforcancellation): that flag has no terminal path, so the guard does not treat it as cancelled demand
   either. Both halves move together, on SBDEV-3332.` → the two halves are **one change**, not two.
4. **In `CustomerorderService.cancelOrder`'s deferred `else` arm**, the fullest statement, with the measurement:
   *"SBDEV-3319 tried to close that here, twice, and both attempts were withdrawn: cancelling the open lines
   takes the picking order terminal, which makes `finishPickingOrder` throw `ORDER_ALREADY_FINISHED` and removes
   the only remaining route to `cleanUpCancelledOrder`; and re-evaluating afterwards cannot fire in regular
   picking, because the only blocker cancelling lines could clear is a Pickingorder in [650,700) — a band
   holding ZERO rows on Hydra PRD."*

**Two withdrawn attempts are on record.** Anything Option 3 proposes has to say explicitly why it is not a third.

### 2.3 Exposure — recommendation: **make it package-private on `PickingorderBusinessService`. Do not move it, do not duplicate it.**

| Option | Verdict |
|---|---|
| **package-private** (`static boolean isDemandCancelled(...)`) | ✅ **Recommended.** |
| move to a helper/util class | ⚠ Defer. |
| duplicate the logic | ❌ **Reject.** |

Why package-private wins here, specifically:

- **The precedent already exists in this very file, for this very predicate.** `assertPickNotCancelled(pickingPosition, coPosition, customerOrder)` — the 3-arg overload — is *already* declared package-private (`void assertPickNotCancelled(` with no modifier), as is `cancelOpenPickLines(`. Widening `isDemandCancelled` the same way is the local idiom, not a new pattern.
- **It is `static` and pure** — three field reads, no repository, no transaction. Nothing about it needs a bean.
- **Every plausible Option 3 caller is in the same package or a subpackage-free service.** The Group-1 predicate sites live in `net.aim_ai.wms.service` (`CustomerorderService`, `CustomerorderPositionService`, `PickingorderBusinessService`) — same package, so package-private reaches them. The exception is `net.aim_ai.wms.service.mobile.MobilePickingService`, which is a **different package**. ⚠ **This is the one thing that can break the recommendation:** if Option 3 needs to call it from `MobilePickingService`, package-private is not enough and you need either `public` on the existing service (`MobilePickingService` already injects `pickingorderBusinessService`, so a public *instance-facing* wrapper is cheap) or a genuine helper. **Decide which files Option 3 actually edits before picking the modifier** — see §3, where my conclusion is that `MobilePickingService` should *not* need it.
- **A helper class is the right end state but the wrong first move.** There is currently exactly one implementation and it is 15 lines; extracting it now adds a file, a bean-or-static decision, and a test class for a predicate whose semantics are still being negotiated on this ticket. Revisit once the caller set is settled and spans packages.
- **Duplication is disqualified by this repo's own history.** `CancellationLogService.resolvePicktoStockunitId`'s javadoc states the rule after paying for it: *"Lives here, public, so `CancellationReversalService` can re-attempt the resolution at completion time from the same implementation. A second copy of this hop is exactly how the original defect would come back."* And §1.2 above already shows what duplication costs on this exact axis: P-9, P-10 and P-11 are three copies of one settle rule, and **P-11 never got the SBDEV-1921 fix** (§4).

**Testing note that comes with widening it:** `isDemandCancelled` is currently reachable from tests only through
`assertPickNotCancelled`/`confirmPick`/`finishPickingOrder`. Making it package-private makes it directly
callable from `net.aim_ai.wms.unit.service` — **but that is a different package** (`unit.service`, not
`service`), so a package-private method is **still not visible to the existing unit tests**. Check this before
promising direct unit coverage; the existing `PickingorderBusinessServiceUnitTest` lives at
`src/test/java/net/aim_ai/wms/unit/service/`. Either the test moves to the mirrored package or the method goes
public.

---

## 3. AC-5 gating — does Option 3 alone discharge the precondition? (task item 3)

**The ticket's reasoning is CORRECT, and it is correct for a slightly different mechanism than it states.**
Verified against the code below. **Verdict: Option 3 discharges the precondition — but only if it includes both
halves, and only for one identifiable population. It does NOT need Option 4.**

### 3.1 The strand, mechanically

Restoring `markedforcancellation` as an `isDemandCancelled` trigger has **two** effects, not one, because
`isDemandCancelled` has two consumers:

**Consumer 1 — `assertPickNotCancelled` → `confirmPick`.** The pick is refused with
`FacadeException(PICK_CONFIRM_ORDER_CANCELLED)`. Lines stay below PICKED forever. *This is the "unpickable" half.*

**Consumer 2 — `finishPickingOrder`'s validation loop.** This is the half the ⚠ comments understate:

```java
            if (pickingPosition.getState() < WmsConstants.State.PICKED
                    && isDemandCancelled(pickingPosition, validationCoPosition, validationCustomerOrder)) {
                continue;
            }
            if (pickingPosition.getState() < WmsConstants.State.PICKED) {
                throw new BusinessException("Picking position " + pickingPosition.getNumber());
            }
```

With the flag restored, an unpicked line on a marked order takes the `continue` instead of the `throw`. So
`finishPickingOrder` **stops being the thing that refuses to run**, and falls through to

```java
            if (customerOrder.getMarkedforcancellation()) {

                cleanUpCancelledOrder(customerOrder);
```

which cancels the open lines, sets the order CANCELED, and clears the flag. **That is a terminal path.** The ⚠
comment's claim that `finishPickingOrder` *"requires every line already PICKED"* was true before SBDEV-3319
added the G4 skip and is **no longer true for cancelled demand** — it stays true only because the flag is not
currently one of the triggers.

### 3.2 So why is it still stranded? Because nothing CALLS `finishPickingOrder`

This is the part that makes the predicate half of Option 3 load-bearing rather than cosmetic, and it is the
opposite of the framing in §1.4's first reading. All eight Group-1 call gates have the shape

```java
        boolean allFinished = poPositions.stream().noneMatch(p -> p.getState() < WmsConstants.State.PICKED);
        if (allFinished && pickingOrder.getState() <= WmsConstants.State.PICKED) {
            pickingOrder.setState(WmsConstants.State.PICKED);
        }
        if (pickingOrder.getState() == WmsConstants.State.PICKED) {
            pickingorderBusinessService.finishPickingOrder(pickingOrder);
```

A marked order's open lines are at PROCESSABLE(300)/ASSIGNED(200) — genuinely `< PICKED`. `allFinished` is
**false**, `finishPickingOrder` is never called, and the newly-tolerant validation loop never runs. The order is
unpickable (Consumer 1) and unfinishable (no caller). **Exactly the strand the ⚠ comments describe.**

**Therefore Option 3 is irreducibly two changes:**
- **(a)** `isDemandCancelled` gains the `markedforcancellation` trigger (makes `finishPickingOrder` tolerant);
- **(b)** the Group-1 predicates become demand-aware (makes something *call* it).

Ship (a) without (b) and you have built the third withdrawn attempt. Ship (b) without (a) and nothing changes at
all, because `finishPickingOrder` will then be called and immediately `throw new BusinessException("Picking
position …")` on the first unpicked line.

### 3.3 The cost of half (b), stated honestly — this is the number the plan needs

Every Group-1 predicate today operates on `List<PickingorderPosition>` **and nothing else**. Demand-awareness
needs the `PickingorderPosition → CustomerorderPosition → Customerorder` chain. `finishPickingOrder` already
pays for that chain with a bulk prefetch:

```java
        Map<Long, CustomerorderPosition> copMap = new HashMap<>();
        customerorderPositionRepository.findAllById(copIds).forEach(cop -> copMap.put(cop.getId(), cop));
        …
        for (Long coId : coOrderIds) {
            customerorderRepository.findByIdForUpdate(coId).ifPresent(co -> coMap.put(co.getId(), co));
        }
```

Replicating that at P-1..P-8 means **eight new two-level bulk fetches**, one of them (`findByIdForUpdate`) a
**row lock**, on hot mobile paths including `processPick`. That is a real performance and lock-ordering change,
not a refactor.

**Architectural recommendation: do not inline half (b) eight times.** Add ONE package-visible method on
`PickingorderBusinessService` — e.g. `boolean isPickingOrderComplete(Long pickingOrderId)` — that owns the chain
load and the predicate, and replace the eight `allFinished` expressions with a call to it. Rationale is the
repo's own, already-paid-for rule: P-9/P-10/P-11 are three hand-copies of one settle predicate and **P-11 was
missed** when the rule changed (§4.3). Eight copies of a demand-aware predicate will rot the same way. It also
resolves the §2.3 visibility question — `MobilePickingService` calls the new **public** method on the injected
`pickingorderBusinessService` and never needs `isDemandCancelled` itself, so `isDemandCancelled` can stay
package-private.

### 3.4 Which orders each option reaches — concretely

| Population | Reached by Option 3 (a+b)? | Reached by Option 4? |
|---|---|---|
| Marked order, picking order still `< FINISHED`, operator will touch it again (resume / start / release / next `processPick` / `releaseRegularPickingOrder`) | **Yes** — next interaction finishes it, `cleanUpCancelledOrder` runs, flag cleared, order CANCELED | No — the flag is never set for these under Option 4; they take the `orderCanBeCancelled` branch at cancel time instead |
| Marked order, picking order **already** `>= FINISHED(700)` | **No.** `finishPickingOrder` opens with `if (pickingOrder.getState() >= WmsConstants.State.FINISHED) { … throw new FacadeException("ORDER_ALREADY_FINISHED"); }`. No predicate change reaches past that guard. **These need a backfill** (`sbdocs/2-Areas/runbooks/sbdev-3332-markedforcancellation-residue-backfill.md` exists for exactly this) | No |
| Marked order whose picking order sat in `[650,700)` (the band SBDEV-3319 tried to use) | Irrelevant — **zero rows**, per the in-code measurement on Hydra PRD; I did not re-measure | — |
| Order blocked because a **CustomerorderPosition is `>= PACKED`** | **No**, and it does not need to be: those lines are already `>= PICKED`, so `finishPickingOrder` already tolerates them today | This is Option 4's actual territory — see lane A |

**Answer to the AC-5 question: Option 3 (a+b) alone discharges the "a terminal path exists" precondition.** It
does not require Option 4. The residual gap is *historical* rows (picking order already terminal), which is a
data problem with an existing runbook, not a code precondition. ⚠ One caveat I cannot discharge from code alone:
whether an operator reliably *does* touch every marked order again. If a marked order's picking order is simply
abandoned, Option 3 leaves it marked indefinitely — better than today (it also stops the picking) but not
self-healing. A scheduled sweep is the only thing that makes it self-healing, and that is out of scope here.

---

## 4. `finalizePickingOrderIfTerminal` and what actually wrote 700 (task item 4)

### 4.1 The method

```java
    private void finalizePickingOrderIfTerminal(Pickingorder pickingOrder) {
        List<PickingorderPosition> poPositions = pickingorderPositionRepository.findByPickingorderId(pickingOrder.getId());
        if (!poPositions.stream().allMatch(p -> p.getState() >= WmsConstants.State.FINISHED)) {
            return;
        }
        boolean allCanceled = poPositions.stream().allMatch(p -> p.getState() == WmsConstants.State.CANCELED);
        pickingOrder.setState(allCanceled ? WmsConstants.State.CANCELED : WmsConstants.State.FINISHED);
```

Correct: an all-cancelled picking order gets **800**. The brief's inference is sound — the stranded rows did not
come through here.

### 4.2 What did — measured, not inferred

I ran the shape query against the live tenant DBs.

**Hydra PRD** (`SELECT po.state, count(*) … WHERE NOT EXISTS (… pp.state <> 800)`): **2 rows, both at state 800.**
Correct shape. Positive control: `customerorder` has 189 rows, so the DB is populated and this is a true result,
not an empty connection.

**Hydra UAT**: **15 rows, ALL at state 700, none at 800.** The stranded shape, fifteen times.

The decisive measurement is the **write ordering**, `EXTRACT(EPOCH FROM (max(pp.modified) - po.modified))`:

| picking order | lines | po.modified − max(pp.modified) | lines with `amountpicked > 0` | lines with a tote |
|---|---|---|---|---|
| PICK000003 … PICK006372 (10 rows, 2021-2025) | 1-4 | **0.000 s** | 0 | 0 |
| PICK007898, PICK007867, PICK007869, PICK008707, PICK009113 (5 rows, 2025-10 → 2026-07) | 1-2 | **+0.003 to +0.022 s** (PO written *after* the lines) | 0 | 0 |

**The picking order's 700 was written in the SAME transaction, milliseconds after the lines went to 800.** That
falsifies the "finished first at 700 with a PICKED line, cancelled later" story outright: there is no second
write. And `amountpicked = 0` / `picktounitload_id IS NULL` on every line of all 15 says **nothing was ever
picked on any of them** — these orders were 100% cancelled, and 700 is simply the wrong terminal state.

### 4.3 The producer: the pre-SBDEV-1921 settle block in `cancelOrderPosition`

```
$ git log --format='%h %ci %s' -S'allCanceled' origin/develop -- .../CustomerorderPositionService.java
  b7acb52f 2026-09-11  SBDEV-3319 cancelled positions must stop picking
  27c2cc7e 2026-05-28  feat(cancellation): SBDEV-1921 order cancellation & reversal workflow (all phases)
```

At `27c2cc7e^` — i.e. the code as it stood before 2026-05-28 — `cancelOrderPosition`'s tail read:

```java
                List<PickingorderPosition> poPositions = pickingorderPositionRepository.findByPickingorderId(pickingOrder.getId());
                if (poPositions.stream().allMatch(losPickingPosition -> losPickingPosition.getState() >= WmsConstants.State.FINISHED)) {
                    pickingOrder.setState(WmsConstants.State.FINISHED);
                    pickingorderRepository.save(pickingOrder);
                }
```

`CANCELED(800) >= FINISHED(700)` → the guard passes for an all-cancelled order → **unconditional `setState(FINISHED)`**,
in the same transaction as the line cancellations. That is the observed shape, exactly, including the ordering.
SBDEV-1921 replaced it with the `allCanceled ? CANCELED : FINISHED` ternary, which is why Hydra PRD (whose 2
rows date from 2026-07-31 and 2026-08-03, on a post-1921 build) shows **800** and UAT shows **700**.

⚠ **Uncertainty, stated rather than papered over.** One UAT row (PICK009113, 2026-07-07) postdates the
2026-05-28 merge to `develop`. My explanation is that UAT was still running a pre-1921 build — deploys to UAT are
tag-driven and lag `develop`. **Supporting evidence, not proof:** `customerorder_cancellation_log` on UAT has
**0 rows, ever** (`min(created_at) IS NULL`), although the table exists; `recordCancellation` shipped in the same
SBDEV-1921 commit, so a post-1921 build cancelling a position would have written a row. **Why this is not proof:**
0 rows is equally consistent with "Flyway created the table on a recent deploy and nothing has cancelled since".
Settle it by reading `/api/public/version` on UAT against the July build history if the answer matters.

### 4.4 Is the producer still live? **No — and that is the answer to "does Option 3 change it".**

I enumerated **every** `src/main` write of a picking-order state:
`git grep -n 'pickingOrder.setState(\|pickingorder.setState(\|po.setState(' origin/develop -- 'src/main/**/*.java'`
→ 24 hits. **Blind spot:** a write through a differently-named local (e.g. `order.setState(...)` on a
`Pickingorder`) or a bulk `@Modifying` UPDATE. I cross-checked the second with instrument D (§1.1) — no
`@Modifying` update of `pickingorder.state` exists.

Of those 24, exactly **four** can write FINISHED(700):

| Site | Can it write 700 for an **all-cancelled** picking order? |
|---|---|
| `PickingorderBusinessService:592` (`finalizePickingOrderIfTerminal`) | **No** — `allCanceled` ternary picks 800. |
| `CustomerorderPositionService:158` | **No** — same ternary (fixed by SBDEV-1921). |
| `PickingorderBusinessService:402` (`pickingOrder.setState(orderState)`) | **No** — `orderState` seeds `CANCELED` and promotes only via `if (pickingPosition.getState() >= WmsConstants.State.PICKED && pickingPosition.getState() != WmsConstants.State.CANCELED)`. All-800 leaves it at 800. |
| `MobilePickingService:314` (`if (hasFinishedPicks) { if (!hasOpenPicks && …) pickingOrder.setState(WmsConstants.State.FINISHED); }`) | **No — structurally unreachable**, per the control-flow proof in §1.4: reaching that block requires `allFinished == false`, i.e. a line strictly below 600, which an all-cancelled order does not have. |

**So on current `develop` there is no live producer of the stranded shape, and Option 3 does not create one.**

### 4.5 …but there IS a latent ordering hazard Option 3 walks straight into. Flag this in the plan.

Inside `finishPickingOrder`, three things happen **in this order**:

1. `orderState` is computed from the lines **as they are now** (~:228);
2. `cleanUpCancelledOrder(customerOrder)` runs (~:270) → `cancelOpenPickLines` → `finalizePickingOrderIfTerminal`,
   which **writes `pickingOrder.setState(...)`** (~:592);
3. `pickingOrder.setState(orderState)` (~:402) — **overwrites step 2's write with the pre-cancellation value.**

Two settlers write the same field in one transaction; the later one wins and it is working from a stale view.
Today this is harmless only because of an accident of bounds: `cancelOpenPickLines` is bounded to
`state < PICKED`, so on the path where step 2 actually cancels something, at least one line was below 600, which
means `finalizePickingOrderIfTerminal`'s `allMatch(state >= FINISHED)` gate fails and it writes nothing.

**Option 3 makes step 2 fire far more often** (every marked order that now reaches `finishPickingOrder`). The
moment anyone widens `cancelOpenPickLines`' `< PICKED` bound — which the SBDEV-3316 reversal work touches — step
2 starts writing 800 and step 3 immediately overwrites it with 700, **manufacturing the exact stranded shape this
ticket is about, in new code, on the fixed branch.**

**Concretely, what Option 3 should do:** move step 3's write above step 2, or make step 3 re-read the lines, or
have step 3 defer to `finalizePickingOrderIfTerminal` rather than assigning `orderState` directly. Any of the
three; the current ordering must not survive a change that makes step 2 hot.

**To be fair to Option 3 as scoped:** with `cancelOpenPickLines`' bound left alone, I could not construct a case
where Option 3 manufactures the all-800@700 shape. A marked order with *all* lines unpicked leaves `orderState`
at its CANCELED seed → 800 (correct). A marked order with *some* lines picked ends at 700 with a mix of 600 and
800 lines — which is the right answer, because something genuinely was picked. **The risk is the coupling, not
today's behaviour.**

### 4.6 One un-migrated copy of the old rule is still on `develop`

`CustomerorderService.forceCancelOrder` still carries the pre-1921 shape:

```java
                if (poPositions.stream().allMatch(losPickingPosition -> losPickingPosition.getState() >= WmsConstants.State.FINISHED)) {
                    pickingOrder.setState(PICKED);
                    pickingorderBusinessService.finishPickingOrder(pickingOrder);
                }
```

`git log -S'losPickingPosition' -- CustomerorderService.java` returns **one** commit — `a685e07b 2024-07-16
"initial checkin the code"`. It has never been touched. It is saved from writing 700 only because
`finishPickingOrder`'s `!= CANCELED` test catches it downstream, and the branch it sits in is documented
in-code as unreachable. **Worth a line on the ticket** (sub-T3, so it belongs on the existing ticket per the
filing policy), not a fix in this plan: it is the third copy of a rule that has already been fixed twice, and it
is the one a future editor will copy from.


---

# ADDENDUM — main session, 2026-09-15. One correction and one confirmation.

Appended by the orchestrating session, not by the architect lane.

## CORRECTION to §4.2 — "the stranded shape, fifteen times" is NOT the stranded shape

Lane B's **measurement** is right and its **archaeology built on it is right**. Its *label* is wrong, and the
distinction matters because it changes the ticket's headline count.

Re-measured on `nywh-hydra-uat`, joining each all-cancelled picking order through to its customer order:

> 19 `(picking order, customer order)` pairs across 16 distinct picking orders — every one with
> **`co.state = 800`** and **`markedforcancellation = false`**.

**Every one of those customer orders is properly cancelled.** What is wrong is only the *picking order's* label:
`700` where `finalizePickingOrderIfTerminal`'s ternary would now write `800`.

**SBDEV-3363's strand is defined by the CUSTOMER ORDER failing to reach a terminal state** — `co.state = 200`,
flag still set, OMS never told. A picking order mislabelled `700` under a fully-cancelled order is a **cosmetic
residue of the pre-SBDEV-1921 bug**, not an order anybody is waiting on. Nothing is stuck; no customer is
un-refunded.

So: **the stranded count remains 2** (28848660, 28857575 — both on wms2-wineco-dev), plus the 1 adjacent
`pickingconfirmationsent = true` order lane A found (585000351). The 15/16 UAT rows are a **separate, benign,
already-fixed-at-the-producer** population and must not be folded into this ticket's headline.

**Where lane B's measurement IS load-bearing, and stays so:** as the dating evidence for §4.3. The
same-transaction write ordering (`po.modified − max(pp.modified)` between 0.000 s and +0.022 s) is exactly what
falsifies the "finished first, cancelled later" story and pins the producer to the pre-1921 unconditional
`setState(FINISHED)`. That argument is untouched by this correction.

**Consequence for the plan:** do **not** add the UAT rows to AC-6's repair scope. If they are worth tidying at
all it is a separate cosmetic backfill on a separate ticket, and the case for doing anything is weak — the
producer is already dead (§4.4) and nothing reads `pickingorder.state` for a cancelled order in a way that
distinguishes 700 from 800. Worth one line on the ticket, not a fix.

## CONFIRMATION of §2.3's open visibility question — there is a third option, and it is the cheap one

Lane B ends §2.3 with *"Either the test moves to the mirrored package or the method goes public."* There is a
third: **put the new test in the mirrored package and leave everything else alone.**

`src/test/java/net/aim_ai/wms/service/` already exists and holds **10+** classes in
`package net.aim_ai.wms.service;` — including `PickingorderBusinessServiceConcurrencyIT` (same class under test)
and, decisively, **`TimezoneServiceUnitTest`**, a plain unit test living in the mirrored package. So the
precedent for a *unit* test there is already set and needs no argument.

That means the §2.3 recommendation stands unweakened: **`isDemandCancelled` goes package-private, nothing moves,
nothing goes public**, and the new direct unit test is authored at
`src/test/java/net/aim_ai/wms/service/…`. Verified by `git ls-tree` on `origin/develop` plus reading each
candidate's `package` line — blind spot: none material, the package declaration is the whole test.
---

## 5. AC-4 — the Flyway migration (task item 5)

### 5.1 The column really is missing

Confirmed independently against **Hydra UAT** via `information_schema.columns` — 23 columns, and
`pickingorder_position_id` is **not** among them. The three id columns that exist are
`customerorder_id NOT NULL`, `customerorder_position_id NOT NULL`, `pickingorder_id NULL`. Matches the brief.

### 5.2 Next free version: **V2.2.31**

Swept **all 287 remote refs**, not a local listing:

```bash
git fetch --all --prune
for r in $(git for-each-ref --format='%(refname)' refs/remotes/); do
    git ls-tree -r --name-only $r -- src/main/resources/db/migration/ 2>/dev/null
done | sed 's#.*/##' | sort -u | grep -E '^V2\.2\.' | sort -V
```

Highest **anywhere**: `V2.2.30__outbox_message_lane.sql`. `origin/develop` carries it.
**`V2.2.31` is unclaimed on every remote ref as of this fetch.**

`origin/main` tops out at `V2.2.25`, so 26-30 are dev-only and not yet on production.

**Collision risk — real, and the sweep cannot close it.** Three separate reasons, in descending order of how
likely they are to bite:

1. **A branch pushed after this fetch.** A sweep is a snapshot; it cannot see a branch that does not exist yet.
   **Re-run the loop above immediately before merging, not when writing the plan.**
2. **The version space has already collided three times.** `V2.2.01`, `V2.2.02` and `V2.2.03` each exist under
   **two different filenames** across the remotes (`los_sequencenumber_init` vs
   `replenishment_monitor_view_add_section_and_ro_id`; `lock_report_exclude_shipped` vs the same view file;
   `lock_report_exclude_shipped` vs `replenishorder_finish_audit_snapshot`). This is not a hypothetical failure
   mode in this repo — it is a recurring one.
3. **Merging to `develop` runs Flyway on the dev tenants immediately** (it is a branch-push-driven deploy). A
   collision is not caught by a PR check; it is caught by a tenant silently stalling, exactly as
   `V2.2.28`'s own header documents for the FK case.

Branches ahead of `develop` that do not yet carry `V2.2.30` and could still add a migration:
`origin/bugfix/SBDEV-3314-non-2xx-recorded-as-sent` (top `V2.2.27`),
`origin/bugfix/SBDEV-3198-dprime-stale-club`, `origin/bugfix/SBDEV-3017-delete-legacy-setputawaylocation`,
plus the `claude/*` and `rc/*` release branches (which lag rather than lead). None claims 31 today.

### 5.3 Where the column gets populated — one method, `CancellationLogService.recordCancellation`

```java
        log.setCustomerorderId(customerOrder.getId());
        log.setCustomerorderPositionId(position.getId());
        log.setPickingorderId(pickingOrder != null ? pickingOrder.getId() : null);
```

One line to add: `log.setPickingorderPositionId(pickingPosition.getId());` (plus the field + `@Column` on
`net.aim_ai.wms.model.CustomerorderCancellationLog`).

### 5.4 Is `pickingorder_position_id` always non-null there? **Yes — and NOT NULL is safe. Two independent grounds.**

**Ground 1 — the parameter cannot be null without the method already having thrown.** The very first statement is

```java
        boolean reversalRequired = (pickingPosition.getState() >= WmsConstants.State.PICKED);
```

an unguarded dereference. A `null pickingPosition` NPEs on line one, today, before any column is written. So
there is no reachable path that writes a row with a null pick line. Contrast `pickingOrder`, which **is**
explicitly null-tolerant (`pickingOrder != null ? … : null`) — the asymmetry is deliberate and already in the code.

**Ground 2 — all three call sites iterate repository-loaded positions.** Derived by
`git grep -n 'recordCancellation(' origin/develop -- 'src/main/**/*.java'`:
- `PickingorderBusinessService.cancelOpenPickLines` — `for (PickingorderPosition pickingPosition : poPositions)` where `poPositions = pickingorderPositionRepository.findByCustomerorderpositionId(...)`
- `CustomerorderService.forceCancelOrder` — same iteration shape
- `CustomerorderPositionService.cancelOrderPosition` — same

Every one passes a **persisted, repository-loaded** entity, so `getId()` is non-null.
**Blind spot of that grep:** it is a literal method-name grep; a call through an interface or a differently-named
wrapper would be missed. `CancellationLogService` is a bare `@Service` class with no `implements`, so there is no
interface to dispatch through — the same check lane A ran for `CustomerorderPositionService`.

### 5.5 The unique index — get the tuple right, and it is not `(customerorder_position_id)`

**Measured cardinality on Hydra UAT:**

```sql
SELECT lines_per_cop, count(*) FROM (
  SELECT customerorderposition_id, count(*) AS lines_per_cop
  FROM pickingorder_position WHERE customerorderposition_id IS NOT NULL
  GROUP BY customerorderposition_id) t GROUP BY lines_per_cop;
-- 1 line  → 17,410 COPs
-- 2 lines →      7 COPs
```

**A customer-order position can be split across two pick lines.** So:

- ❌ `UNIQUE (customerorder_position_id)` — **wrong.** It would reject the legitimate split-pick shape.
- ✅ `UNIQUE (customerorder_position_id, pickingorder_position_id)` — one cancellation row per pick line, which
  is exactly the invariant `cleanUpCancelledOrder`'s own ⚠ comment says is currently unenforceable:
  *"`customerorder_cancellation_log` has no pick-line column, and SBDEV-3316's `completeReversal` moves stock per
  row filtered on `customerorder_position_id` alone, skipping only rows that already carry
  `reversal_completed_at`. Two rows therefore return `amount_picked` TWICE."* **The index is the structural half
  of that fix; the `completeReversal` filter is the other half and AC-4 should say so explicitly.**

⚠ **Repo-specific caveat:** the v2 migrations declare essentially no unique indexes — join-table uniqueness in
this schema is enforced out-of-band, not by the DB. This would be a departure from that (a good one), so expect
it to be the thing review argues about, and pre-empt it with the duplicate-row scenario above.

### 5.6 Backfill feasibility — measured on every tenant that has rows

| Tenant | log rows | distinct COPs | resolvable to ≥1 pick line | **ambiguous** (COP → >1 pick line) |
|---|---|---|---|---|
| Hydra PRD (`wh01_hydra_v2`) | 16 | 16 | 16 | **0** |
| WineCo DEV (`dev_wh01_om1`) | 8 | 8 | 8 | **0** |
| Hydra UAT | 0 | — | — | — (control: the table exists; `pickingorder_position` is populated) |

**Backfill is deterministic on every tenant that has data**, so `ADD COLUMN` → `UPDATE` → `SET NOT NULL` is safe
today. Resolution rule, which also disambiguates the split-pick case if it ever appears:

```sql
UPDATE public.customerorder_cancellation_log l
   SET pickingorder_position_id = pp.id
  FROM public.pickingorder_position pp
 WHERE pp.customerorderposition_id = l.customerorder_position_id
   AND (l.pickingorder_id IS NULL OR pp.pickingorder_id = l.pickingorder_id)
   AND l.pickingorder_position_id IS NULL;
```

⚠ **Blind spots, both of which V2.2.28's header hit and documented — copy its handling:**
1. I measured **three** tenant DBs (Hydra PRD, Hydra UAT, WineCo DEV). V2.2.28's header lists **six**; I did not
   reach ShipItEz c1wh/nywh UAT or WineCo wsl UAT from this lane. V2.2.28 measured all three at **0 rows**, so a
   `NOT NULL` backfill on them is trivially safe *if that is still true* — **re-measure before merging.**
2. No tenant onboarded after this measurement can have been checked. If a `SET NOT NULL` fails, the tenant
   **silently stalls at V2.2.30** while the app boots healthy (`StartupFlywayMigrator` does not abort the boot on
   a per-tenant failure). Put that sentence in the migration header, as V2.2.28 does.

**Safer alternative worth offering to Nam:** ship the column **nullable** with the unique index (Postgres unique
indexes ignore NULLs by default), backfill out of band, and add `SET NOT NULL` in a later migration. That
removes the stall risk entirely at the cost of one extra version. Given the row counts (16 and 8) the risk is
tiny either way, so this is a judgement call, not a recommendation.

---

## 6. Summary — what I would tell the plan author

1. **Re-derive from `9e294d4b`, not `4847e978`** (§0). The old 9-site list is **9-of-9 drifted**, 7 are genuine
   predicates, 2 were never predicates, and it **misses 5 sites** — including the repository-derived
   `countByPickingorderIdAndStateLessThan` that starts the whole cascade (§1.3).
2. **The premise "a CANCELED line makes the predicates answer wrongly" is false** for the `allMatch`/`noneMatch`
   family: CANCELED is 800, the top of the ladder, so those predicates already treat it as complete (§1.4). The
   two `anyMatch`-shaped exceptions are benign today, one of them provably unreachable.
3. **`isDemandCancelled`: make it package-private, don't move it, never duplicate it** (§2.3) — with the caveat
   that package-private does **not** reach `MobilePickingService` (different package) or the existing unit tests
   (`net.aim_ai.wms.unit.service`). §3.3's single-method design removes that need.
4. **Option 3 is irreducibly two changes** (§3.2). (a) alone re-creates the strand the ⚠ comments warn about —
   it would be the **third** withdrawn attempt. (b) alone changes nothing.
5. **Option 3 (a+b) DOES discharge AC-5's precondition without Option 4** (§3.4) — for marked orders whose
   picking order is still `< FINISHED`. Historical rows already at 700 are unreachable by any code change and
   need the existing residue runbook.
6. **Do not inline half (b) eight times** (§3.3). One demand-aware method on `PickingorderBusinessService`. The
   evidence that copies rot is in this ticket's own subject matter: the settle rule has three copies and
   `CustomerorderService.forceCancelOrder`'s was **never fixed** (§4.6).
7. **The 700-with-all-800-lines shape came from the pre-SBDEV-1921 unconditional `setState(FINISHED)`** in
   `cancelOrderPosition`, written in the same transaction as the cancellations — measured, not inferred, from
   15 UAT rows whose `po.modified − pp.modified` is 0 to +22 ms (§4.2-4.3). **No live producer remains, and
   Option 3 does not create one** (§4.4).
8. **But flag the ordering hazard at `finishPickingOrder` (§4.5):** `orderState` is computed *before*
   `cleanUpCancelledOrder` and applied *after* it, clobbering `finalizePickingOrderIfTerminal`'s write. Option 3
   makes that path hot. It is inert today only because of `cancelOpenPickLines`' `< PICKED` bound — a bound the
   SBDEV-3316 work is adjacent to.
9. **AC-4: next free version is `V2.2.31`** (swept all 287 remote refs), **re-sweep immediately before merge**
   (§5.2). `pickingorder_position_id` is **always non-null** at the single write site and `NOT NULL` is safe
   (§5.4). The unique index must be **`(customerorder_position_id, pickingorder_position_id)`** — a COP can
   legitimately split across two pick lines (7 such on UAT), so a single-column index is wrong (§5.5). Backfill
   is deterministic on all three tenants I measured; **three more remain unmeasured** (§5.6).
10. **Sub-T3 finding for the existing ticket, not a new one:** `CustomerorderService.forceCancelOrder` still
    carries the pre-SBDEV-1921 settle shape, untouched since the initial 2024 checkin (§4.6).

### Derivation methods and their blind spots, collected

| Claim class | Method | Blind spot |
|---|---|---|
| Predicate-site completeness | 4 instruments, §1.1 | `@Query` SQL predicates; the two Nuxt UIs; `src/test` |
| "No live producer of 700" | enumerate all 24 `setState` writes + instrument D for `@Modifying` | a write through a differently-named `Pickingorder` local |
| "V2.2.31 is free" | all 287 remote refs, post-`fetch --all` | a branch pushed after the fetch — unclosable, hence "re-sweep before merge" |
| "always non-null" | unguarded deref + 3 call sites + no-interface check | a caller added after this reading |
| Tenant measurements | live SQL, each zero paired with a positive control | 3 of 6 tenant DBs not reached from this lane |

## CORRECTION 2 to §5 — the AC-4 unique key is `pickingorder_position_id` ALONE

Lane B recommends `UNIQUE (customerorder_position_id, pickingorder_position_id)`, on the grounds that a CO
position legitimately splits across two pick lines. **The premise is correct; the conclusion does not follow.**

`pickingorder_position.customerorderposition_id` is a **single column**, so a pick line has exactly one CO
position. That makes `pickingorder_position_id → customerorder_position_id` a function, and the first column
of the proposed key **functionally dependent** on the second. So:

- For the split case the composite **adds nothing**: two pick lines under one CO position already differ in
  `pickingorder_position_id`, so a single-column unique index already permits both rows — which is the wanted
  behaviour, and the thing the ticket warned would be suppressed by `UNIQUE (customerorder_position_id)`.
- The composite is **strictly weaker**: it permits the same `pickingorder_position_id` under two different
  `customerorder_position_id` values — precisely the duplicate row the constraint exists to forbid.

The ticket's warning was against keying on `customerorder_position_id` **alone**. The remedy is to key on the
pick line, not to append the CO position to the key.

Immaterial for this ticket — the index ships **non-unique** (critic C-2: a `UNIQUE` constraint would invert
`recordCancellation`'s `MANDATORY`-propagation fail-open contract and turn a duplicate bookkeeping row into a
rolled-back cancel). It matters for the F4 follow-up that promotes it, which is where this correction is
aimed.
