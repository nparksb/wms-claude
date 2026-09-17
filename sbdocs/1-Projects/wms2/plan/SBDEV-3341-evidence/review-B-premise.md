# SBDEV-3341 — Review Lane B: adversarial review of the PREMISE

- **Lane:** B (premise / reasoning, not code style)
- **Reviewer worktree:** `/home/nampark/dev/wms-claude/.claude/worktrees/wms2-api/SBDEV-3341-reviewB`
- **Base:** `d80b5083` (merge of PR #354, SBDEV-3339), change applied as uncommitted edits
- **Date:** 2026-09-14
- **DB:** `mcp__wms2-hydra__execute_sql` → `wh01_hydra_v2` (the only v2 PRD tenant), read-only
- **Toolchain:** JDK 21.0.11-ms + Maven 3.9.15 from `~/.sdkman` (neither is on `PATH`; `mvn` alone fails with `No such file or directory`)

---

## VERDICT: **HOLDS WITH CORRECTIONS**

The central claim — that the missing source-lock guard in `transferUnitLoadToLocation` is a
**deliberate distinction and not a defect**, and that the fix therefore belongs in the caller — is
**correct, and I could not break it.** Every attack I ran either confirmed it or narrowed its
justification without touching the conclusion. The decision to put `assertWholeContainerSourceUnlocked`
in `StockunitService` rather than in the primitive is right, and the primitive should stay unguarded.

But the *argument* as written in the javadoc is stronger than the evidence supports in two places, and
one factual claim about the call-site enumeration is **wrong**, and one **completeness claim is
falsified by a caller the lane missed**. Corrections C1–C3 are substantive. C1 is the one I would fix
before merge.

Summary of what survived and what did not:

| # | Claim under attack | Result |
|---|---|---|
| 1 | The PRD ordering evidence (204/199/199) | **Reproduces exactly.** But it proves ordering, not lock state — see the gap below |
| 2 | Packaging never clears the lock | **TRUE** on the branch packaging actually takes. The argument does **not** collapse |
| 3 | "A symmetric source guard would refuse every truck load" | **OVERSTATED.** True for 1 of 3 guard shapes; **false for the other 2**, proven by experiment |
| 4 | `MobileMoveUnitloadService` ON_HOLD = policy-belongs-in-callers | **DEFENSIBLE**, with a caveat that cuts the other way |
| 5 | "24 call sites, 15 false / 9 true"; "the two that need one already have one" | **Count wrong (16/8)**; **"the two" is falsified — there is a third** |
| 6 | Claim discipline in javadoc + doc edit | Several completeness words unbacked; the doc edit itself is good |

---

## Attack 1 — Re-run the DB queries. Is `unitload_record` even the right table?

### What I ran

`unitload_record` has **no** `unitload_id` column — it keys the container by the `label` string
(`labelid`). The schema is `(id, additionalcontent, created, entity_lock, modified, version,
activitycode, fromlocation, label, operator, recordtype, tolocation, unitloadtype, client_id,
fromunitload, ordernumber, tounitload)`. It is written by `UnitloadRecordService.recordForTransferUnitLoad`,
called from `processTransfer` **once per node of the carrier tree**, so it is the right table and the
right grain.

```sql
SELECT activitycode, count(*) rows, count(DISTINCT label) labels, min(created)::date, max(created)::date
FROM unitload_record GROUP BY 1 ORDER BY 2 DESC;
```
→ `TRUCKLOADING: 204 rows / 199 labels, 2026-07-15 .. 2026-09-11`
→ `SHIPPING: 199 rows / 199 labels, 2026-07-15 .. 2026-09-11`

```sql
WITH tl AS (SELECT label, min(created) mn, max(created) mx FROM unitload_record WHERE activitycode='TRUCKLOADING' GROUP BY 1),
     sh AS (SELECT label, min(created) mn FROM unitload_record WHERE activitycode='SHIPPING' GROUP BY 1)
SELECT count(*) both_labels,
       count(*) FILTER (WHERE tl.mx < sh.mn) all_tl_strictly_before_ship,
       count(*) FILTER (WHERE tl.mn >= sh.mn) tl_at_or_after_ship
FROM tl JOIN sh USING (label);
```
→ `both_labels=199, all_tl_strictly_before_ship=199, tl_at_or_after_ship=0`

**Every number in the javadoc reproduces exactly**, including the 2026-09-11 latest date, and the
199/199 holds under the *strictest* reading (I compared `max(TRUCKLOADING)` against
`min(SHIPPING)`, not `min` against `min` — both give 199).

The null-lock census also reproduces exactly:

```sql
SELECT 'stockunit', entity_lock, count(*) FROM stockunit GROUP BY 2
UNION ALL SELECT 'unitload', entity_lock, count(*) FROM unitload GROUP BY 2
UNION ALL SELECT 'location', entity_lock, count(*) FROM location GROUP BY 2;
```
→ **zero nulls**; totals 804 stockunit / 831 unitload / 267 location, matching the javadoc's stated
positive control. `location` is **267/267 at lock 0** — no location on PRD is locked at all.

### The gap — and it is a real one

**"TRUCKLOADING strictly before SHIPPING" does NOT establish that the carried stock was locked at
move time.** It establishes only the ordering of two moves. `entity_lock` is **not historised**:

- `stockrecord.entity_lock` is **`0` on all 2689 rows** and `unitload_record.entity_lock` is **`0` on
  all 2854 rows** — both are the *audit row's own* lock column, hard-set to `0` at creation
  (`StockrecordService:245,296,340,393,442,502,532`; `UnitloadRecordService:59,104`). Neither records
  the moved entity's lock. There is **no table on PRD that can answer "what was the lock at time T"**.

So the lock value at truck-load time is reached by a **code inference**, not by measurement. The
inference is sound — I checked its two legs and both hold:

- The **only** writer of `Stockunit.entityLock = PICKED_FOR_GOODSOUT` in `src/main` is
  `PickingorderBusinessService:876` (`pickToStock.setEntityLock(...PICKED_FOR_GOODSOUT)`), plus the
  `CancellationReversalService:407` residue restore.
- The **only** writer of `SHIPPED` is the BOL-close bulk JPQL, `BillofladingService:673-677` and
  `:1599-1603` (`"UPDATE Stockunit s SET s.entityLock = :lock ..."`), which happens *after* the
  TRUCKLOADING row by the 199/199 ordering above.

**Correction C3 (Low):** the javadoc currently presents the ordering figure as if it settled the lock
state — *"199/199 had TRUCKLOADING strictly before SHIPPING — so at every one of them the carried
stock was still at PICKED_FOR_GOODSOUT."* The "so" is doing work the data cannot do. Say instead that
the data establishes the **ordering**, and that the lock value at that point follows from the two
writers above, and state plainly that lock state is not historised on this schema.

---

## Attack 2 — Is step 2 true? Does packaging really never clear the lock?

**YES. The argument does not collapse.** This was the attack most likely to be lethal and it fails.

`CustomerorderService.packageOrder:621`:

```java
for (Stockunit stockUnit : sus) {
    stockunitBusinessService.transferStockToUnitLoad(stockUnit, packageUnitLoad, stockUnit.getAmount(),
        WmsConstants.CODE_PACKAGING, customerOrder.getNumber(), null, true, false);
}
```

Note `amount == stockUnit.getAmount()` — the **full** amount. Tracing `transferStockToUnitLoad`'s
branch selection:

```java
if (destinationStockUnit == null && (sourceStockunit.getAmount().compareTo(amount) > 0 || fixLocationAssignment != null)) {
    ... destinationStockUnit = createStockUnit(...);   // creates with entityLock = NOT_LOCKED
}

if (destinationStockUnit == null) {
    sourceStockunit.setUnitloadId(destinationUnitload.getId());     // <-- FULL-MOVE branch
    destinationStockUnit = stockunitRepository.save(sourceStockunit);
    ...
} else {
    destinationStockUnit.setAmount(destinationStockUnit.getAmount().add(amount));  // <-- MERGE branch
    ...
}
```

Packaging moves the full amount into a freshly-created parcel, so `compareTo(amount) == 0` and
`destinationStockUnit == null` ⇒ **full-move branch**. That branch **re-points `unitload_id` on the
very same row** and never touches `entity_lock`. The lock survives the move intact. Step 2 is correct
and the chain holds.

### Two branches where it would NOT survive — worth knowing, neither reached by packaging

1. **Merge onto a `createStockUnit`-minted destination.** `StockunitBusinessService:133-134` sets
   `stockunit.setEntityLock(NOT_LOCKED)`. If the guard condition above fires
   (`amount` partial, **or** a `FixLocationAssignment` on the *source* location), the moved quantity
   lands on a **lock-0** row and the reservation is silently dropped. Packaging cannot reach this:
   amount is always full, and a picking tote's location does not carry an FLA.
2. **Merge onto a pre-existing same-SKU destination SU.** Reachable in packaging when two pick lines
   of the same SKU land in one parcel — but the destination row there was itself placed by an earlier
   iteration's full-move, so it already carries `PICKED_FOR_GOODSOUT`. Lock preserved either way.

Neither disturbs the conclusion. Flagging (1) only because it is a genuine lock-loss path in a
primitive the ticket's argument leans on, and nothing in the repo documents it.

---

## Attack 3 — Is the pallet the thing carrying locked stock? **This one lands.**

**The lane-lead's claim "a symmetric source guard under `!ignoreLock` would refuse every truck load"
is OVERSTATED. It is true for exactly one of three guard shapes, and provably false for the other two.**

### What truck loading actually moves

```sql
WITH tl AS (SELECT DISTINCT label FROM unitload_record WHERE activitycode='TRUCKLOADING')
SELECT ut.name ul_type, u.entity_lock, count(*) n,
       count(*) FILTER (WHERE EXISTS (SELECT 1 FROM unitload c WHERE c.carrierunitload_id=u.id)) is_carrier_now
FROM tl JOIN unitload u ON u.labelid=tl.label LEFT JOIN unitload_type ut ON ut.id=u.type_id
GROUP BY 1,2;
```
→ `Pallet / 405 / 37 / is_carrier=37` and `Package / 405 / 162 / is_carrier=0`

So the 199 TRUCKLOADING labels are **37 pallets** (the entry-method arguments) plus **162 parcels**
(their children, each recorded by `processTransfer`'s recursion). 37 + 162 = 199. ✓ The lane-lead's
description of the mechanism is right: the entry argument is the pallet, the stock lives on children.

### The pallet's own lock at truck-load time is ZERO

I enumerated **every** writer of a `Unitload.entityLock` in `src/main`:

- `UnitloadBusinessService:551` → `GOING_TO_DELETE` (2)
- `UnitloadBusinessService:637` → `NOT_LOCKED`
- `UnitloadService:209`, `:240` → `0`
- `CustomerorderService:473`, `:493` → `NOT_LOCKED`
- `BillofladingService:666`, `:1592` → bulk JPQL `"u.entityLock = :lock"` at **BOL close**, value
  `SHIPPED` (405) or `TRANSFER` (404)

**Nothing in `src/main` ever sets a `Unitload`'s lock to `PICKED_FOR_GOODSOUT`.** The pallets' current
`405` comes from BOL close, which the 199/199 ordering puts *after* truck loading. So at the moment
`transferUnitLoadToLocation(pallet, gate, false, TRUCKLOADING, ...)` runs, the pallet's own lock is `0`
and the source location's lock is `0` (267/267 locations are unlocked on PRD).

### Experiment: I added a narrow guard and ran the suite

Patched `transferUnitLoadToLocation` with a source guard on the UL's own lock **and** the source
location's lock under `!ignoreLock`, then ran `UnitloadBusinessServiceUnitTest`:

```
Tests run: 53, Failures: 0, Errors: 2
  ...SourceLockAsymmetry.transferUnitLoadToLocation_doesNotRefuse_whenSourceLocationIsLocked » Business Source location=LOC-001 is locked=104
  ...SourceLockAsymmetry.transferUnitLoadToLocation_doesNotRefuse_whenSourceUnitLoadIsLocked » Business Source unitLoad=UL-001 is locked=100
```

Only the two new pins fire. `neverReadsCarriedStock_onPassThroughMove` correctly does **not** —
the narrow guard never reads carried stock. (Patch reverted; `git diff --stat` is back to the
original 4 files / 331 insertions.)

### Quantified: which guard shapes break

| Guard shape placed at the entry method | Refuses truck loading? | Why |
|---|---|---|
| A. moved UL's own `entity_lock` | **NO** | pallet is at `0`; no code path ever mints `100` on a Unitload |
| B. source `Location.entity_lock` | **NO** | 267/267 PRD locations are at `0` |
| C. carried stock, recursively through `carrierunitload_id` | **YES — all 37** | the parcels' SUs are at `PICKED_FOR_GOODSOUT` |

`processTransfer` confirms shape C is the only one that even *could* see it — carried stock is read
**only** inside the `BLOCK_REALIGN` arm:

```java
if (PickLineActivityCodeClassifier.classify(activityCode, null) == Bucket.BLOCK_REALIGN) {
    for (Stockunit movedStockUnit : stockunitRepository.findByUnitloadId(unitload.getId())) { ... }
}
```

and `CODE_TRUCK_LOADING` is in `PASS_THROUGH_CODES`, so on a truck load the stock is never read at all.
A shape-C guard would have to *add* that query — which is exactly what the `never()` pin protects.

**Correction C2 (Medium).** Two things to fix:

1. The javadoc's *"A guard under `!ignoreLock` refuses all of them"* is true only for shape C. Say so:
   *"a guard that enumerates the carried stock through the carrier tree refuses all of them; a guard on
   the moved unit load's own lock or on the source location's lock would refuse none of them, because
   no `src/main` path mints a non-zero lock on a Unitload before BOL close (enumerated by grepping
   every `setEntityLock` and every `entityLock = :` JPQL in `src/main`; blind to native SQL and to
   direct DB edits)."*
2. The test `transferUnitLoadToLocation_doesNotRefuse_whenSourceUnitLoadIsLocked` sets
   `testUnitload.setEntityLock(PICKED_FOR_GOODSOUT)` — **a state no `src/main` path can produce and
   which has never existed on PRD.** Keeping the test is right (it pins shape A, and shape A is the
   most likely future "fix"), but its `@DisplayName` — *"truck loading relocates a pallet whose own
   lock is set"* — asserts something false about production. Rename to something like *"a source
   unit load carrying any lock is relocated, not refused"* and drop the truck-loading framing from
   that one test. The same correction applies to the doc-edit sentence, which says the absence of a
   guard on the UL's own lock and the source location's lock is justified *"because truck loading
   relocates pallets of PICKED_FOR_GOODSOUT stock"* — that `because` only licenses the carried-stock arm.

**This does not change the verdict.** Shape C is the shape a reviewer reaching for "symmetry with
`transferStockToUnitLoad`" would actually reach for (that primitive guards source SU + source UL +
source location, and the SU analogue here *is* the carried stock). The conclusion stands; only its
scope needs stating.

---

## Attack 4 — Is the `MobileMoveUnitloadService` counterfactual defensible?

**Defensible, with a caveat that cuts against the new guard.**

The checks are real and they are source-lock checks, sited in the caller immediately ahead of an
`ignoreLock=false` call (`MobileMoveUnitloadService:306-316`, mirrored at `:157-166`):

```java
if (sourceUnitLoad.getEntityLock() == WmsConstants.BusinessObjectLockState.ON_HOLD) {
    throw new BusinessException("Unit load is locked on hold!");
}
List<Stockunit> stockUnitList = stockunitRepository.findByUnitloadId(sourceUnitLoad.getId());
for (Stockunit stockUnit : stockUnitList) {
    if (stockUnit.getEntityLock() == WmsConstants.BusinessObjectLockState.ON_HOLD) {
        throw new BusinessException("Stock unit is locked on hold!");
    }
}
```

That is not an unrelated concern: `ON_HOLD` is minted by `StockunitService:533-534`, which relocates a
container to a hold location with `ignoreLock=true` and then stamps the stock. The check exists to stop
a mobile operator walking stock back off that hold. It reads the **source UL and its stock** — i.e. it
is precisely the "stricter source policy imposed by the caller" the lane-lead describes. The reading
is sound, and it is notable that this caller reaches for **shape A + shape C** and pointedly does not
try to push either into the primitive.

### The caveat — a sibling-consistency problem the ticket introduces

`MobileMoveUnitloadService` refuses **`ON_HOLD` only**, by equality. Elsewhere in the same file the
estate's policy is explicit that `QUALITY_FAULT` is *movable*:

```java
if (stockUnit.getEntityLock() != NOT_LOCKED && stockUnit.getEntityLock() != QUALITY_FAULT) {
    throw new BusinessException("Can't move! stock=" + ... + " already locked! ...");
}
```
(`MobileMoveUnitloadService:554-555`, again at `:591-592`)

The new `assertWholeContainerSourceUnlocked` refuses **any** non-zero lock. So after this change, web
Move Stock is **strictly stricter than mobile Move Unit Load** for the same conceptual action
(relocate a whole container): mobile permits `QUALITY_FAULT`, web now refuses it. That inconsistency
is new.

**Measured exposure: zero.** `QUALITY_FAULT`(103) and `ON_HOLD`(104) do **not occur on Hydra PRD** —
0 rows in `stockunit`, 0 in `unitload`, and 0 in `stockrecord` history. (Positive control for that
zero: the same census returns 439/30/7/328 for locks 0/2/100/405 in `stockunit`, so the instrument
works.) I would **not** block on this, but it belongs on the ticket: the choice to refuse
`QUALITY_FAULT` on the web whole-container route should be deliberate, not incidental.

Note also a constant that is easy to misread: **`entity_lock = 2` is `GOING_TO_DELETE`, not
`QUALITY_FAULT`.** The 180 unitloads and 30 stock units at `2` on PRD are nirvana-bound, not damaged.

---

## Attack 5 — The call-site enumeration. **Count is wrong, and a caller was missed.**

### The count

I re-derived it against **`origin/develop`** and against the worktree, excluding comments/javadoc and
the declaration itself. Both give **24 invocations** — the total is right. The split is not:

| | javadoc says | actual |
|---|---|---|
| `ignoreLock=false` | 15 | **16** |
| `ignoreLock=true` | 9 | **8** |

The 16 `false`: `FixLocationAssignmentService:165`, `ReceivingService:552`, `StockunitService:371`
(`:320` on develop), `ParcelMonitorViewService:410`, `MobileTruckLoadingService:246`,
`MobileTransferOrderService:392`, `MobilePickingService:544`, `MobileMoveUnitloadService:365,492,496`,
`MobilePutAwayService:153,188,190,211,571,575`.
The 8 `true`: `UnitloadBusinessService:548,629,646`, `ReceivingService:721,749`,
`CustomerorderService:650`, `StockunitService:533`, `PickingorderBusinessService:352`.

**Correction C4 (Low):** fix `15`/`9` → `16`/`8` in the `transferUnitLoadToLocation` javadoc.

### The missed caller — **Correction C1 (Medium-High), the one I would fix before merge**

The javadoc asserts:

> *"Of the 24 call sites in `src/main` (15 passing `ignoreLock=false`, 9 passing `true`), **the two that
> need one already have one** — `MobileMoveUnitloadService` ... and `StockunitService.assertWholeContainerSourceUnlocked` ..."*

**"The two" is false.** `MobileTransferOrderService.transferStock:387-397` is a **structurally
identical twin of the exact defect this ticket fixes**, and it is left unfixed:

```java
if (stockUnit.getAvailableamount().intValue() <= amountLeft) {
    if (stockUnit.getReservedamount().intValue() == 0) {
        // move whole stock unit
        if (fixLocationAssignmentRepository.findByAssignedunitloadId(stockUnit.getUnitloadId()).isPresent()) {
            Unitload unitLoad = unitloadRepository.findById(stockUnit.getUnitloadId())...;
            unitloadBusinessService.transferUnitLoadToLocation(unitLoad, transferLane, false, null, null, null);
        } else {
            // is from flowbin
            Unitload unitLoad = unitloadService.createUnitload(...);
            stockunitBusinessService.transferStockToUnitLoad(stockUnit, unitLoad, availableAmount,
                WmsConstants.CODE_MANUAL_SPLIT, null, null, false, true);
        }
```

Same shape, one method away: a geometry-driven branch where **one arm relocates the container through
`transferUnitLoadToLocation` (no source guard) and the other splits through `transferStockToUnitLoad`
with `ignoreLock=false` (full source guard)**. `grep -n "EntityLock\|ON_HOLD\|isLocked"` over
`MobileTransferOrderService.java` returns **nothing** — the file has no lock check anywhere. (The FLA
polarity is inverted versus `StockunitService` — here FLA *present* selects the whole-container arm —
but the asymmetry is identical.)

This is the invariant-over-instance problem: SBDEV-3341 fixed the instance in `StockunitService` and
the javadoc then claims completeness over the estate. Either fix this site too, or restate the claim
as an enumeration with its axis and its exceptions.

**Exposure today: latent.** 132 FLA-backed unit loads on PRD, **0** with a non-zero UL lock and **0**
carrying locked stock. So the route cannot currently mis-move a locked container on Hydra — but the
population is one pick away from being non-zero.

### `MobileTransferOrderService` passing a NULL activityCode — yes, it is a problem

`transferUnitLoadToLocation(unitLoad, transferLane, false, null, null, null)`. Two consequences:

1. **The SBDEV-2481 pick-line guard is silently skipped.** `PickLineActivityCodeClassifier.classify`
   returns `PASS_THROUGH` on null **before** the unknown-code branch, so it does not even emit the
   fail-open `LOG.warn`:
   ```java
   if (activityCode == null || activityCode.isEmpty()) { return Bucket.PASS_THROUGH; }
   ```
   Its sibling — `MobileMoveUnitloadService:365`, the same kind of operator container move — passes
   `CODE_TRANSFER`, which **is** in `BLOCK_REALIGN_CODES`. So two comparable moves get opposite
   pick-line treatment, and the divergent one is invisible in logs.
2. **`unitload_record.activitycode` is written NULL**, so the move is unattributable in the audit trail.

Measured: `count(*) FILTER (WHERE activitycode IS NULL) = 0` out of 2854 rows, positive control
`TRUCKLOADING = 204` in the same query — a true zero, so this route has never executed on Hydra PRD.
Worth a line on the ticket; not a blocker.

### The other 13 `ignoreLock=false` callers

I checked each for "is a silently-relocated locked container a real problem here?" — none are:
`MobilePutAwayService` (×6) and `ReceivingService:552` move freshly-received inbound stock (lock 0 by
construction); `MobilePickingService:544` assigns an empty tote; `FixLocationAssignmentService:165`
moves a fix-assignment container (the 132 FLA-backed ULs, all at lock 0);
`MobileMoveUnitloadService` (×3) has the ON_HOLD guard discussed above;
`MobileTruckLoadingService:246` / `ParcelMonitorViewService:410` are the two deliberate ones.

---

## Attack 6 — Claim discipline

### `transferUnitLoadToLocation` javadoc

| Sentence | Verdict |
|---|---|
| "`ignoreLock` gates **exactly one** check in this method: the DESTINATION location's lock." | **TRUE.** `!ignoreLock` appears twice — the `findByIdForUpdate` re-fetch and the `STORAGELOCATION_LOCKED` throw — both on the destination. Names no method; add "verified by reading every `ignoreLock` occurrence in the method body". |
| "There is deliberately **no** check on the moved unit load's own lock, on the source location's lock, or on the locks of the stock it carries." | **TRUE.** |
| "The sibling primitive ... does guard **all** of those." | **TRUE** — `StockunitBusinessService:286-297` guards source SU, source UL, source location. |
| "A symmetric source guard would stop the **entire** outbound path ... A guard under `!ignoreLock` refuses **all** of them." | **OVERSTATED** — see C2. True for shape C only. |
| "of the 199 labels ... **199/199** had TRUCKLOADING strictly before SHIPPING — **so** at every one of them the carried stock was still at PICKED_FOR_GOODSOUT" | Numbers **TRUE**; the inferential "so" needs the caveat in C3. |
| "Of the **24** call sites (**15** false, **9** true)" | Total **TRUE**; split **WRONG** (16/8) — C4. |
| "**the two** that need one already have one" | **FALSE** — C1, `MobileTransferOrderService` is a third. |
| "Method and blind spots ...: a `git grep` of the method name against `origin/develop`, `src/main` only — complete for compiled Java callers, since dispatch here is neither reflective nor proxy-mediated, but it says nothing about v1 or about branches not yet merged to develop." | **Good — this is the model.** It names the instrument and its blind spots. Every other completeness sentence above should look like this one. |

### `assertWholeContainerSourceUnlocked` javadoc

- *"Checks the same three sources the sibling guard checks ... and uses the same message shape"* —
  **TRUE**, message strings match `StockunitBusinessService:286-297` verbatim in shape.
- *"Measured on Hydra PRD 2026-09-14: 0 nulls out of 804 stockunit, 831 unitload and 267 location rows
  (the positive control being that the same query returned those non-zero totals)"* — **reproduces
  exactly, and the positive control is correctly stated.** Best-disciplined claim in the diff.
- *"The split route delegates to `transferStockToUnitLoad(..., ignoreLock=false, ...)`, which refuses
  any non-zero SOURCE lock."* — **incomplete.** Within this same method the split arm has three
  sub-paths and **two pass `ignoreLock=true`**: `StockunitService:395` (QUALITY_FAULT → Damaged) and
  `:401` (`CODE_DAMAGED`). Only `:430` passes `false`. **Correction C5 (Low):** qualify as "the split
  route's non-damaged sub-path". The doc edit already gets this right ("four of its six calls ... the
  two `ignoreLock = true` sites are the damaged-stock branches, deliberately" — I verified 6 calls at
  `:307, :311, :357, :395, :401, :430`, four `false`, two `true` ✓), so the javadoc is out of step with
  the doc it points at.

### The doc edit (`wms2-move-stock-unitload-workflow.md`)

**Good, and notably honest** — it says the row "has now been wrong three times", names the axis error
("it enumerated call sites of one primitive rather than routes through the method"), and states the
generalisable lesson ("a completeness claim must name the axis it searched"). Frontmatter
`last_verified` / `verified_by` updated correctly with the base SHA. The only fix is the `because`
clause flagged in C2.

### Numbers I checked that are right

`76` (the "76-container PRD shape" in the SHIPPED test's DisplayName) — confirmed:

```sql
WITH ul1 AS (SELECT u.id, u.entity_lock ul_lock, u.storagelocation_id loc_id, min(s.entity_lock) su_lock
             FROM unitload u JOIN stockunit s ON s.unitload_id=u.id GROUP BY 1,2,3 HAVING count(*)=1)
SELECT su_lock, ul_lock, l.entity_lock loc_lock, (fla.id IS NOT NULL) has_fla, count(*)
FROM ul1 JOIN location l ON l.id=ul1.loc_id
LEFT JOIN fix_location_assignment fla ON fla.assignedlocation_id=ul1.loc_id GROUP BY 1,2,3,4;
```
→ `307` pass · `132` take the split branch (FLA present) · **`76` refused by the new guard, all at
`su_lock=405, ul_lock=405`**. So the guard's live blast radius on PRD today is 76 containers, all
already-shipped — which is the right population to refuse.

---

## Test-quality check (not requested, but it is the floor)

- Both new nested classes **actually ran**: surefire XML shows
  `StockunitServiceUnitTest$TransferStockSourceLockGuard tests="6"` and
  `UnitloadBusinessServiceUnitTest$TransferUnitLoadToLocationSourceLockAsymmetry tests="3"`.
- **Mutation 1** — deleted the `assertWholeContainerSourceUnlocked(...)` call:
  `Tests run: 6, Failures: 4` — the four refusal tests go red, AC-3 and AC-4 (the permissive ones)
  stay green. Correct discrimination.
- **Mutation 2** — flipped `isLocked` to refuse on null (`entityLock == null || ...`):
  `Tests run: 6, Errors: 1`. AC-4 genuinely pins the permissive resolution.
- **Mutation 3** — added the narrow source guard to `transferUnitLoadToLocation`:
  2 of the 3 asymmetry pins fire (see Attack 3). The third is shape-specific by design.
- **No collateral damage.** All 10 `transferStock`-adjacent test classes together:
  `Tests run: 295, Failures: 0, Errors: 0 — BUILD SUCCESS`.
- All mutants reverted; `git diff --stat` back to 4 files / 331 insertions.

---

## Ranked corrections

| # | Sev | Correction |
|---|---|---|
| **C1** | **Med-High** | *"the two that need one already have one"* is **false**. `MobileTransferOrderService.transferStock:387-397` has the identical FLA-driven branch — whole-container arm through `transferUnitLoadToLocation` (unguarded), split arm through `transferStockToUnitLoad(..., false, ...)` (guarded) — and the file has **no lock check at all**. Either guard it too, or restate the claim with its axis. Latent on PRD (132 FLA-backed ULs, 0 locked). |
| **C2** | **Med** | *"A guard under `!ignoreLock` refuses all of them"* holds only for a guard that **enumerates carried stock through the carrier tree**. A guard on the moved UL's own lock, or on the source location's, refuses **none** — no `src/main` path mints a non-zero Unitload lock before BOL close, and 267/267 PRD locations are unlocked. Proven by experiment. Also retitle `transferUnitLoadToLocation_doesNotRefuse_whenSourceUnitLoadIsLocked`, whose DisplayName asserts a production state that cannot occur, and soften the doc edit's `because` clause. |
| **C3** | **Low** | "TRUCKLOADING before SHIPPING **so** the stock was locked" — the data proves **ordering only**. `entity_lock` is not historised (`stockrecord.entity_lock` = 0 on all 2689 rows, `unitload_record.entity_lock` = 0 on all 2854). The lock value follows from the two writers (`PickingorderBusinessService:876`, `BillofladingService:673/1599`), not from the query. State that. |
| **C4** | **Low** | `15` / `9` → **`16` / `8`**. Total of 24 is correct. |
| **C5** | **Low** | *"The split route delegates to `transferStockToUnitLoad(..., ignoreLock=false, ...)`"* — two of the split arm's three sub-paths pass `ignoreLock=**true**` (`StockunitService:395`, `:401`, the damaged-stock branches). Qualify. The doc edit already states this correctly; the javadoc contradicts it. |
| **C6** | **Info** | The new guard refuses `QUALITY_FAULT`, while `MobileMoveUnitloadService:554,591` explicitly permits it (`!= NOT_LOCKED && != QUALITY_FAULT`). Web Move Stock is now stricter than mobile Move Unit Load for the same action. Zero PRD exposure (0 rows at 103 or 104 anywhere, incl. history). Make it deliberate or align it. |
| **C7** | **Info** | `MobileTransferOrderService:392` passes `activityCode=null` → `classify` returns `PASS_THROUGH` **without** the fail-open WARN, so the SBDEV-2481 pick-line guard is skipped silently where its sibling (`CODE_TRANSFER`) blocks/realigns; and `unitload_record.activitycode` is written NULL. 0 such rows on PRD (positive control: 204 TRUCKLOADING in the same query). |
| **C8** | **Info** | Undocumented lock-loss path in the primitive the argument leans on: `transferStockToUnitLoad`'s `createStockUnit` sub-branch mints the destination at `NOT_LOCKED` (`StockunitBusinessService:133-134`), so a **partial** move — or any move whose **source** location carries an FLA — silently drops the reservation. Packaging never reaches it (full amount, no FLA on a tote location). |

**Bottom line: the premise is sound and the fix is sited correctly. Do not move the guard into
`transferUnitLoadToLocation`.** C1 is the finding worth acting on before merge — not because it
weakens the reasoning, but because the javadoc makes a completeness claim the estate does not satisfy.
