# Lane M — adversarial critic, SBDEV-3363 Fix B (AC-5) + Fix C (M-4)

- **API subject**: `.claude/worktrees/wms2-api/SBDEV-3363-ac5` @ `af403931`, base `4bef7e77`
- **Mobile subject**: `.claude/worktrees/wms2-mobile-ui/SBDEV-3363-m4` @ `1e3d979`, base `ab1e2ae`
- **Plan**: `sbdocs/1-Projects/wms2/plan/SBDEV-3363-deferred-cancel-terminal-path.md`
- Lane date 2026-09-16. All line numbers are from the **worktrees**, not the stale main checkouts.

**Verdict: one BLOCKER (M-1), one High (M-2), two Medium, three Low. The blocker is the same
class of defect as the PICKED(600) finding that sank the earlier design: a code path the new
guard now refuses, which has no terminal route out.**

---

## M-1 — BLOCKER. `rapidPickingScanSource` is a seventh completeness gate. It was left raw, and the restored trigger turns rapid picking into the exact SBDEV-3332 strand.

### The site

`MobilePickingService.rapidPickingScanSource` (worktree `:1290`), unchanged by this commit:

```java
pickingOrder = pickingorderBusinessService.confirmPick(pickingPosition, pickingorderUnitload, pickingPosition.getAmount(), user);

PickingHighPositionInfoDto dto = new PickingHighPositionInfoDto();
for (PickingorderPosition pp : pickingorderPositionRepository.findByPickingorderId(pickingOrder.getId())) {
    if (pp.getState() < WmsConstants.State.PICKED) {          // :1382  ← raw, NOT demand-aware
        dto.setPickingorderPosition(pp);
        dto.setPickCompleted(false);
        return dto;                                            // ← "not complete" verdict
    }
}
if (pickingOrder.getState() == WmsConstants.State.PICKED) {
    pickingOrder = pickingorderBusinessService.finishPickingOrder(pickingOrder);   // :1391
    ...
}
```

This satisfies the plan's own rule verbatim (§2.2): *"every site that decides whether a picking
order is complete and, on 'yes', hands control to `finishPickingOrder`"* — falling through the loop
**is** the yes, and `finishPickingOrder` is two lines below. The plan even names its shape: *"an
accumulator-free early-return loop where falling through is the verdict"*.

### It is not an oversight of enumeration — the plan scoped it

`laneB-option3-architect.md` §1.2 catalogues it as **P-8**, annotated *"hand-rolled,
accumulator-free early return — instruments A **and** B both miss this"*. Plan §0.2 then puts
**B1–B8 = P-1…P-6, P-8 (MobilePickingService) + P-7 (`confirmPick`)** in scope, to be fixed *"via
the single shared helper of §3.2"*. That is **eight** sites.

The commit delivers **six**: `MobilePickingService` `:245`, `:272`, `:358`, `:411`, `:752` (P-1, P-2,
P-4, P-5, P-6) plus `confirmPick` `:1252` (P-7). **P-8 and P-3 are unimplemented.** (P-3 is benign —
see M-6.)

The commit message's claim — *"makes **every** gate that promotes a Pickingorder to PICKED
demand-aware"* and *"the gate set was derived from the RULE … one of the **six**"* — is therefore
false, and false against the plan's own enumeration rather than against some external standard.
The javadoc on `isPickingOrderComplete` repeats it: *"all **five** `MobilePickingService` gates"*.

The author was looking directly at P-8 while writing this: the non-locking justification in both
the commit message and the `isPickingOrderComplete` javadoc cites *"`rapidPickingScanSource`
evaluates completeness while already holding a Pickingorder lock"*. The site was read, reasoned
about, and then not changed.

### What it produces — this is a regression, not an incomplete fix

Two reachable shapes, both new to this commit:

**(a) The marked order's line sorts first.** `rapidPickingScanPackage` (`:1152`) hands back the
first `state < PICKED` line — also raw. The operator scans its source → `confirmPick` →
`assertPickNotCancelled` → `FacadeException(PICK_CONFIRM_ORDER_CANCELLED)`. The method is
`@Transactional(rollbackFor = {BusinessException.class, FacadeException.class})`, so everything
rolls back including `pickinginprogress`. Re-scanning the package returns the same line. The
operator cannot reach the *other* lines on the order at all. Note the `// TODO finish picking order
in case all picks where done` at `:1159`: nothing on this path finishes anything.

**(b) The marked order's line sorts last.** The operator picks the final live line; `confirmPick`'s
new demand-aware gate (`:1252`) promotes the PO to PICKED. Control returns to the P-8 loop, which
finds the marked order's line at 200/300, sets `pickCompleted=false`, and **puts that line in the
DTO as the next pick**. The handheld directs the operator onto it; the scan is refused; repeat.

Before this commit both shapes terminated: the flag was not a trigger, `confirmPick` allowed the
pick, the PO completed, `finishPickingOrder` ran, and its `markedforcancellation` dispatch called
`cleanUpCancelledOrder`. Wasteful (goods picked then reversed) but **terminal**. After this commit
rapid picking is unpickable and — on path (a) — unfinishable. That is the precise failure
`CustomerorderService:1075-1085` documents as SBDEV-3332's reason for removing the trigger, and
which this commit asserts is discharged.

No automatic healer reaches it. `ReleaseExpiredPickingOrdersFromUserJob` only nulls `operator_id`,
and its query (`PickingorderRepository:111-118`) requires `po.pickinginprogress = false AND po.state
< :state` — on shape (b) the PO is already at PICKED, so it is excluded by state. The only escape is
an operator leaving rapid picking entirely and re-entering through a regular-picking endpoint.

The new integration test's own assertion message reads *"it must exist in REGULAR picking, **not
only RAPID**"* — which presumes rapid picking already had a terminal path. That presumption was
true on `origin/develop` and is made false by this commit.

### Exposure, measured (2026-09-16)

| tenant | COs | `markedforcancellation IS TRUE` | POs with marked CO + open line | section picking types |
|---|---|---|---|---|
| Hydra **PRD** (`wms2-hydra`) | 191 | **0** | 0 | — |
| Hydra UAT (`nywh-hydra-uat`) | 9,485 | 1 | 0 | — |
| ShipItEZ UAT (`nywh-shipitez-uat`) | 1,404 | 0 | 0 | `TOTES_ON_CART` |
| **WineCo UAT** (`wsl-wineco-uat`) | 481,182 | **69** | 0 | **`RAPID_PICKING`, `TOTES_ON_CART`** |

All 69 WineCo UAT marked orders are at `state=800` with the flag left set (stale post-cancel
residue); 68 of 69 reached picking through `TOTES_ON_CART`, 1 through a null section. Zero rows of
the live target shape (`marked=true AND state<>800`) exist anywhere today.

**Be honest about what that means both ways.** The live exposure of M-1 is currently zero — but so
is the live exposure of the fix. Both are rails for the same producer. The moment that producer
fires on a tenant with `RAPID_PICKING` sections (WineCo UAT has them), regular picking terminates
and rapid picking hard-blocks. The fix and the gap have identical trigger conditions, which is
exactly why they must not ship apart.

**Blast radius**: any picking order in a `RAPID_PICKING` section carrying a line whose CO is
`markedforcancellation`. Operator-visible hard stop; no automatic recovery.
**Would I block the merge? Yes.** The remedy is three lines: replace `:1382`'s raw loop with
`isPickingOrderComplete(poPositions)` (using the list it already loads), and make
`rapidPickingScanPackage:1152` skip lines in `findDemandCancelledPickLineIds`.

---

## M-2 — High. The planned deploy order (API first) is the unsafe one. The commit's own safety argument only covers UI-first.

The commit message: *"`pickStatus` is kept — the UI half widens rather than replaces, so it degrades
safely if the UI ships first."* That direction is correct and I verified it: `demandCancelled` absent
→ `undefined` → falsy → both widened predicates in `store/picking.js` (`:134-140`, `:479-481`) reduce
to their pre-change form exactly.

**The reverse direction — the one actually planned — is not safe, and nothing in the commit or the
plan says so.** With the new API and the old UI:

1. A marked order's lines are at 200/300, so `pickStatus` renders as `Reserved`/`Started`, not
   `Cancelled`. The old filter `results.filter(p => p.pickStatus !== CANCELLED_PICK_STATUS)` keeps
   every row.
2. The operator presses Pick → `MobilePickingService.processPick:481` →
   `assertPickNotCancelled` → `PICK_CONFIRM_ORDER_CANCELLED`.
3. `store/picking.js:546-572` (SBDEV-3319's H2 fix) re-queries, then:
   ```js
   const rowStillThere = context.state.pickingOrderPositions.findIndex(p => p.id === rowBefore)
   if (rowBefore !== null && rowStillThere >= 0) { context.commit('setCurrentPosition', rowStillThere) }
   ```
   The row **is** still there — the old filter cannot see `demandCancelled` — so the operator is
   parked back on the same unpickable row.

That is verbatim the infinite-retry loop SBDEV-3319 opened H2 to fix, reintroduced for the
`markedforcancellation` trigger, on **regular** picking. It is self-inflicted by ordering, and it
disappears the moment the UI is deployed.

**Blast radius**: every regular-picking operator who touches a marked order during the window
between the API deploy and the UI deploy.
**Would I block the merge? No — but I would block the deploy plan.** Either flip the order to
UI-first (which the commit already argues is safe) or deploy them together. The plan's §5.2 and §12
should say this explicitly; right now they say the opposite.

---

## M-3 — Medium. Three `src/main` comments now assert the opposite of the code, and one is a query predicate, not prose.

Plan §0.3 scoped a four-comment sibling sweep (C2, C3, C4, C1b). C2, C3 and C1b landed. **C4 did
not**, and two further sites the sweep never enumerated are also now false.

| site | asserts | status |
|---|---|---|
| `CustomerorderService.java:1073-1086` (**C4**, in scope, not done) | *"the flag on its own stops nothing, and it has **NO TERMINAL PATH** … `isDemandCancelled` does **NOT** treat this flag as cancelled demand"* | false — and this is the site that **sets** the flag |
| `WmsConstants.java:1845-1847` (not enumerated) | `PICK_CONFIRM_ORDER_CANCELLED` javadoc: *"— NOT the `markedforcancellation` flag, **which cannot refuse a pick**; see SBDEV-3332"* | false — this is the javadoc on the very key the new refusal throws |
| `PickingorderRepository.java:186-188` (not enumerated) | *"The predicate mirrors `PickingorderBusinessService.isDemandCancelled`: the two levels … The deferred flag is deliberately not among them"* | **not just prose** — see below |

The third is the one that matters. `getPickingOrderSummaries` is the SQL mirror of `isDemandCancelled`
that drives the mobile pick-list counts (SBDEV-3319 H3). Its `WHERE` clause excludes cancelled work
at cop/co level but not the flag. After this commit the summary counts a marked order's lines as
pickable while `getPickingOrderPositionsInfo` returns them as `demandCancelled: true` and the UI
drops them — so the list screen says *"4 positions"* and the detail screen shows zero and toasts
*"All picking positions for this order have been cancelled."* A divergence between a predicate and
its SQL mirror is precisely the drift the M-4 javadoc says it exists to prevent.

**Blast radius**: operator-visible count mismatch; plus the standing hazard that the next person to
reason about the deferred cancel reads four separate `src/main` sites that state the pre-3363 rule.
**Would I block the merge? Yes for C4 and `WmsConstants` (they are one-line edits the plan already
scoped). The repository predicate can be a follow-up if the counts are judged acceptable — but say
so on the ticket rather than leaving the mirror silently out of sync.**

---

## M-4 — Medium. Five of the six new gates have no test. The mutation claim covers one.

`DeferredCancelTerminalPathIntegrationTest` has exactly two tests
(`:272`, `:306`), and both call `mobilePickingService.releasePickingOrder(pickingorder)` — **P-2 only**.

The commit states: *"Both halves independently mutation-killed: removing the flag trigger → red;
reverting **one gate** to the raw `noneMatch` → red."* Read precisely, that is true and it is also
the weakest possible version of the claim: the one gate with a test is the one that was mutated.
Reverting P-1, P-4, P-5, P-6 or P-7 to the raw predicate would leave the suite green, because
nothing drives the deferred-cancel path through `resumePickingOrderIfExists`,
`startPickingOrder`, `finalizePickingOrderForStart`, `releaseRegularPickingOrder` Case 2, or
`confirmPick`. The three `MobilePickingServiceUnitTest` additions are `when(...).thenReturn(true)`
stubs that preserve pre-existing subjects — they pin nothing about demand-awareness.

P-7 (`confirmPick`) is the gap I would close first: the commit itself calls it *"the gate that fires
on the LAST confirm, i.e. the commonest completion path"*, and it is the only one of the six whose
correctness depends on a flush ordering (see M-7).

**Blast radius**: five gates that can silently revert. **Would I block? No** — but the ticket should
record which gates are pinned and which are not, rather than leaving *"mutation-killed"* to read as
set-wide.

---

## M-5 — Medium (speculative, unmeasured). `findDemandCancelledPickLineIds` is applied to ALL lines; `isPickingOrderComplete` correctly restricts to open ones.

`isPickingOrderComplete` filters to `state < PICKED` before asking about demand — right. But M-4's
call at `MobilePickingService:926` passes the whole `poPositions` list, so an **already-PICKED** line
whose CO was later cancelled gets `demandCancelled: true` and the UI removes it from
`pickingOrderPositions` entirely.

A picked line under cancelled demand is not "work you cannot do" — it is work already done whose
goods are sitting in the tote awaiting reversal. Hiding it removes the only screen where the
operator would see it, and it changes the x/y progress denominator.

Measured on WineCo UAT: **3,036 lines across 583 picking orders** match `pop.state <> 800 AND
(cop.state = 800 OR co.state = 800)` — 3,023 at PICKED(600), 13 at FINISHED(700). (That 3,023 is the
same population as the earlier rejected design's finding.) **All 583 of those POs are at state 700**,
i.e. off the pick list, and zero POs below FINISHED would be fully hidden by the new filter. So the
live exposure today is **zero rows**.

I also re-ran the G4 comment's own control on the same tenant: `pop.state < 600 AND (cop.state = 800
OR co.state = 800)` → **0 rows**. That measurement still holds, so widening the *gates* for the
cop/co triggers is genuinely inert.

**Blast radius**: zero today; a misleading terminal message and a shifted progress count if a
partially-cancelled order ever sits on the live pick list.
**Would I block? No.** But `findDemandCancelledPickLineIds` at the M-4 call site should arguably be
scoped to `state < PICKED` for the same reason `isPickingOrderComplete` is — and if it should not,
say why, because the asymmetry between the two callers is currently undocumented.

---

## Claims I attacked and could not break — stated plainly so the lane is not read as uniformly negative

**The lock-ordering justification (brief item 3) survives, and is understated.** Verified:
`confirmPick` takes `customerorderRepository.findByIdForUpdate` (`:1055`) then
`pickingorderRepository.findByIdForUpdate` (`:1090`), and its gate at `:1252` runs holding both. So
`rapidPickingScanSource` → `confirmPick` → `isPickingOrderComplete` does evaluate completeness under
a Pickingorder lock. The *stronger* reason the commit does not give: a picking order spans multiple
customer orders (`finishPickingOrder`'s `processedOrders` map; `parcelCount = COUNT(DISTINCT co.id)`),
so the helper would need locks on COs other than the one `confirmPick` already holds — those would be
acquired Pickingorder-first, a genuine inversion. Non-locking is right.

**The inverse risk (non-locking read) produces nothing worse than a deferred promotion.** Worst
interleaving I could construct: T1 holds the PO lock, reads CO-A non-locking as *not* marked, decides
`complete=false`; T2 commits `markedforcancellation=true`. Result: the PO stays STARTED with an open
line. No double promotion, no lost cancel, no spurious notification — the next release/resume
re-evaluates and promotes. The reverse (read marked, then T2 un-marks via `AdviceService:248` /
`OrderBatchCreationService:138` / `CustomerorderService:455`) leaves the PO at PICKED with a genuinely
open line; `finishPickingOrder` then throws `BusinessException("Picking position …")` at the G4
fall-through and rolls back, and the line remains pickable because the guard no longer refuses it.
Self-healing. Speculative, unmeasured, Low.

**No false OMS notification (brief item 2 — the question you flagged as mattering most).** I traced
`finishPickingOrder` end to end. A marked CO takes the `cleanUpCancelledOrder` branch at `:271`,
which never reaches the `PICKING_FINISHED` enqueue. An unmarked CO with an open line cannot be
notified either: the enqueue requires `customerOrder.getState() >= PICKED`, and CO promotion at
`:288-300` requires every `CustomerorderPosition` to be `>= PENDING` — a CO position backing an
unpicked pick line is not. So **no order receives a notification implying work that was not done.**
The set of orders whose behaviour changes is exactly: picking orders **all** of whose open lines have
cancelled demand. Measured at 0 rows on all four tenants today.

**Stock and tote handling is right.** The tote-transfer loop at `:355` skips the cleaned-up CO (via
the `state == CANCELED` disjunct, as its own ⚠ comment warns), and `cleanUpCancelledOrder` sends the
tote to clearing (`sendToClearing`, `:697-704`) and cancels the CO positions. No tote is left in a
state the old path never produced. For an all-cancelled PO, `orderState` keeps its CANCELED seed and
the PO settles at 800; for a mixed PO the picked lines promote it to FINISHED(700). Both correct.

**The `anyPicked` asymmetry (brief item 6) is benign, and the comment defending it is accurate.**
Walking the decision table for an order where every line is demand-cancelled and none was picked:
`allPicked = isPickingOrderComplete(popList) = true` → **Case 2 fires first and returns** (`:759-792`),
so `anyPicked` is never consulted. The outcome is `finishPickingOrder` → `cleanUpCancelledOrder`,
which is the right one. Making `anyPicked` demand-aware would indeed be wrong in the other direction
(it would let Case 3 return a partly-picked order to the pool). `laneB` §1.2 reached the same
conclusion independently. No finding.

**The `releasePickingOrder` reassign fix is correct and Case 2 correctly does not need it.** In
`releasePickingOrder(Pickingorder)` the argument arrives from the controller **detached**, so
`save()` returns a different managed instance and the original keeps its stale `@Version` — the
reassign is necessary. In `releaseRegularPickingOrder` Case 2 the entity comes from
`findById` **inside** the transactional method, so it is managed and `save()` returns the same
instance. The asymmetry is right, not an oversight.

---

## M-6 — Low. P-3 was also scoped and also not implemented — but it is genuinely unreachable.

`releasePickingOrder`'s `hasFinishedPicks`/`hasOpenPicks` pair (`:304-338`) is inside plan §0.2's
B1–B8 and was left raw. It is unreachable for the shapes this ticket cares about: an all-cancelled
order takes the new `allFinished` → `finishPickingOrder` → `return` at `:287-290`, and a mixed order
with any line at exactly PICKED throws `"Finish already started picking order!"` at `:298-302` first.
Matches `laneB` §1.3's assessment. No action beyond noting that §0.2's in-scope count of 8 was
delivered as 6, of which one omission is harmless and one (M-1) is not.

## M-7 — Low. `@Transactional(readOnly = true)` on `isPickingOrderComplete(Long)` is inert **and** asserts the opposite of what `confirmPick` needs.

Its only caller is `confirmPick` in the same bean (`:1252`), so Spring's proxy is bypassed and the
annotation never applies — it has **zero** call sites where it could take effect. The sibling
`findDemandCancelledPickLineIds` is annotated too and *is* called across beans
(`MobilePickingService:927`), but every caller is already inside a read-write
`@Transactional(tenantTransactionManager)` method, and Spring does not downgrade a participating
transaction — so it is inert there as well.

"Inert" would be a non-finding. What makes it worth a line is that it is **actively misleading in the
one place it matters**: `readOnly = true` sets Hibernate's `FlushMode.MANUAL`, and `confirmPick`'s
gate is *correct only because the flush does happen* — the just-confirmed line must be visible to
`findByPickingorderId` inside the helper. A reader who trusts the annotation concludes the opposite.
Delete it from the `Long` overload, or inject self and mean it.

## M-8 — Low, pre-existing, out of scope. `rapidPickScanPackageToVerify:1467`

```java
Pickingorder pickingOrder = pickingorderRepository.findById(pickingPosition.getId())...
```

passes a `PickingorderPosition` id to a `Pickingorder` finder. Untouched by this commit and not its
problem — recorded only because it is the one path that would otherwise have rescued M-1 shape (b),
and it does not, because it inspects the wrong row. File separately if it is not already known.

---

## Recommendation

Do not merge on M-1. Fixing it is small — `rapidPickingScanSource:1382` becomes
`isPickingOrderComplete(poPositions)` over the list it already loads, and
`rapidPickingScanPackage:1152` skips ids in `findDemandCancelledPickLineIds` — and it restores the
commit's headline claim ("every gate") to being true. M-3's two scoped comment edits are one line
each. M-2 costs nothing but a sentence in the deploy plan, and flipping the order.

Everything else I attacked held up. The notification, stock/tote, `anyPicked`, lock-ordering and
detached-entity arguments are all sound, and the G4 0-row control re-measures as stated.
