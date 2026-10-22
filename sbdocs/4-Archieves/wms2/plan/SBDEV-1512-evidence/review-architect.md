# SBDEV-1512 — Architect review (ralplan consensus, Architect lane)

**Subject:** `SBDEV-1512-snapshot-rev1.md`, md5 `1b3cf2bc4af8be544e772d8299608aa2` (immutable snapshot of
`sbdocs/1-Projects/wms2/plan/SBDEV-1512-receive-damaged-from-returns.md`).
**Reviewer:** architect lane. **Date:** 2026-09-15.
**Code reference point:** `v2/wms2-api` @ `origin/develop` `9e294d4b` (confirmed by `git rev-parse`; the
local checkout was not read), `v1/qa-api` @ `origin/develop` `b905d77`. Every claim below was derived by
`git show origin/develop:<path>` / `git grep … origin/develop`; citations are file + quoted snippet.

## Verdict

**SOUND WITH CHANGES.**

The central architectural choice — receive the full physical quantity, then reuse
`StockunitService.setLockDamaged` — is correct and I verified the three reasons the plan gives for it.
`moveStockToNewDamagedContainer` really does carry the reviewed lock order
(`locationRepository.findByIdForUpdate(damagedLocation.getId())` is literally the first statement, with
`// This must remain the FIRST statement in the method.`), it really does mint a `Box`
(`createUnitload(containerLabel, damagedLocation, unitLoadTypeId, …)` with the caller resolving
`UNIT_LOAD_TYPE_BOX`), and it really does write the `activitycode = 'DAMAGED'` stock records via
`transferStockToUnitLoad(stockUnit, container, amount, WmsConstants.CODE_DAMAGED, …)`. Alternative A
would have had to re-derive all three. D1/D3 are executed correctly at that level.

What is not sound is everything that follows from **§3.2's "Data-model delta: none."** Three of my four
High findings are the same defect wearing different clothes: because the damaged quantity is persisted
nowhere, every partial-failure path in the design loses it irrecoverably, and the `adviceposition` row
ends up describing a shipment that never arrived. One nullable column dissolves all three.

---

## Strongest steelman antithesis

*The best argument that this plan's central approach is wrong, argued properly.*

The plan models "damaged on arrival" as **receipt followed by an operator adjustment**. The antithesis is
that damaged-on-arrival is not an adjustment at all — it is an **attribute of the receipt** — and that
modelling it as an adjustment means the system never records that the goods arrived damaged. It records
that they arrived clean and that someone damaged them 40 milliseconds later. Every difficulty the plan
wrestles with is a consequence of that single mismodelling, and they are not independent problems:

- The advice position says `notifiedamount = 7` while `goodsreceiptposition.amount = 10`, because the
  wire contract's "notified" concept and the receipt's "received" concept were deliberately decoupled
  (**H2**). The advice is now a record of a delivery nobody sent.
- The damaged quantity has nowhere to live, so no failure between the two steps is recoverable from the
  WMS's own data (**H3**).
- A receive failure at position *k* leaves positions 1..*k*-1 holding damaged bottles that are
  indistinguishable from good ones, forever (**H1**).
- The case label overstates the good unit load (plan §3.6, honestly recorded as FU-1).
- OMS receives `normal = +10` and then `damaged = +3` for a shipment where only 7 were ever sellable
  (**M5**).
- The stock is genuinely `entity_lock = 0` and pickable for the whole interval between two separate
  transactions, and there is no single boundary in which that window could be closed, because the
  design has deliberately placed the two writes in different transactions.

The plan rejects Alternative A (receive straight into `Damaged`) on four grounds. Three of them are
objections to a *particular* implementation of A rather than to A itself. "A fourth `setEntityLock(103)`
write site", "no `activitycode='DAMAGED'` stockrecord" and "`PutawayDestinationResolver` would need a
bypass" all dissolve if A is implemented as *delegation* — a `receiveDamagedGoods` path that creates the
goods-receipt row and then hands container creation to the existing
`unitloadService.moveStockToNewDamagedContainer`, which already mints the Box, takes the Damaged row
lock first, writes the `CODE_DAMAGED` stock records and sets `QUALITY_FAULT` inside one boundary. The
fourth objection — "a parallel implementation would have to re-derive the SBDEV-3086 lock ordering" — is
precisely what delegation preserves. Under that reading the plan rejected A by pricing its worst
implementation, and bought in exchange a design in which damaged stock is briefly sellable, permanently
unrecorded, and lost entirely on any partial failure.

**Where the antithesis is wrong:** it underrates the split. `setLockDamaged` on a *mixed* line does real
work that a receive-time path would have to reimplement — `transferStockToUnitLoad` creates the
destination stock unit, moves exactly `amount`, records both halves, and handles the emptied-source and
`FixLocationAssignment` cases (`if (destinationStockUnit == null && (sourceStockunit.getAmount().compareTo(amount) > 0 || fixLocationAssignment != null))`). A receive-time path would need two unit loads
in one loop and would hit exactly the non-termination trap the plan already identified in Alternative C
(`amountBottles -= 0` never terminates). And D1 is settled. So the antithesis should not change the
approach — it should change what the approach *persists*.

## Synthesis

Keep D1/D3 exactly as written. Add the one artefact the plan refused: **a nullable
`adviceposition.notifieddamagedamount`** (one `V2.2.x` Flyway file, one column, one DTO-to-entity line).
Then:

- Set `notifiedamount = undamaged + damaged` and `notifieddamagedamount = damaged` at save time. **H2
  dissolves** — the advice again describes what arrived, and `SUM(ap.notifiedamount) as qtyRequired`
  stops understating.
- `PARTIAL` stops being a silent quality escape: the damaged quantity is on the row, so a dock-recovery
  or a sweep job can find every position that was received but never damaged. **H1 becomes a recoverable
  state rather than an invisible one**, without changing the two-loop ordering.
- `DAMAGE_FAILED` gains a queryable recovery worklist instead of a `LOG.error` and a correlation id.
  **H3 dissolves.**

The plan's stated reason for no migration (§5.1 row 5) is about *historical backfill*, which is a
different question and is correctly answered "no". It does not argue against a forward column.

---

## Tradeoff tension the plan does not acknowledge

**§3.4's two-loop ordering prices the double-receive hazard and not the quality escape, and the choice
also maximises the very race §3.3 calls "the weakest link."**

The plan argues, correctly, that interleaving would produce an `OPEN` advice with part of its stock
already locked `103`, so a dock re-receive would duplicate the good stock. It therefore receives all
positions first. But that choice has two costs it never states:

1. **It guarantees that a receive failure loses the damage information for every earlier position** (H1).
   Interleaving guarantees the opposite: whatever was received has already had its damage applied.
2. **It stretches position 1's reservation window from one transaction to the whole advice.**
   `receiveGoods` probes CUPS *inside* its own transaction —
   `if(!printService.isPrintAvailable(printer.getAddress())) { … throw … }` is its first real statement —
   so with N positions, position 1's freshly-received stock sits at `entity_lock = 0`, unreserved and
   grabbable, across N-1 further receives each containing a network round-trip. §3.3's precondition table
   calls `availableamount >= amount` "the weakest link"; the chosen ordering is what makes it weak. The
   two concrete grabbers exist: `ReplenishGeneratorService` does
   `stockUnitBusinessService.changeReservedAmount(sourceStock, replenishOrder.getRequestedamount(), false, WmsConstants.CODE_REPLENISHMENT_CREATED, …)`, driven by `ReplenishOrderJob`, and
   `StockUnitController /adjustReservedAmount` is operator-reachable.

Both horns are only closable by persisting the damaged quantity. That is why H3 is the load-bearing
change and not a nice-to-have: without it, the Planner is choosing which of two unrecoverable states to
prefer; with it, neither is unrecoverable and the ordering becomes a genuinely free choice.

---

## Findings

### HIGH

**H1 — `PARTIAL` converts a reporting gap into a quality escape, which is the exact outcome §3.1 uses to reject W3.**

`ReturnAdviceAutoReceiveService.executeInternal`, inside the receive loop:

```java
return AutoReceiveOutcome.partial(plan.adviceNumber(), line.sku(), received,
    plan.lines().size(), reason, correlationId);
```

Plan §3.4: *"Receive **all** positions first, then apply damage to all positions that need it."*

A receive failure at position *k* returns before the damage loop runs at all. Positions 1..*k*-1 are
committed, holding `undamaged + damaged` units at `entity_lock = 0` at the putaway destination —
pickable and shippable. Nothing in the WMS records that a damaged portion existed (§3.2: *"Data-model
delta: none"*), and the dock-recovery path cannot re-apply it: `ReceivingService.receiveGoods` has no
concept of `amount_of_bottles_damaged`. Today's `PARTIAL` loses nothing; the new one ships damaged
bottles to a customer. §3.1 rejects design W3 on precisely this ground — *"v1 then receives damaged
bottles as normal sellable stock, which can be picked and shipped to a customer"* — and then reintroduces
it through the failure path.

*Fix options, cheapest first:* (a) persist the damaged quantity (synthesis above) so the state is
recoverable; (b) interleave receive-and-damage per position and accept the OPEN-with-locked-stock state
(which becomes safe once the quantity is persisted); (c) at minimum, make `PARTIAL` on an advice carrying
any damage emit a distinct, loud signal rather than reusing the existing recovery contract unchanged.

---

**H2 — `notifiedamount` stays at the undamaged quantity while the receive takes the total, making every mixed return a permanent over-delivery in the WMS's own reports.**

`AdviceRestController`:

```java
position.setNotifiedamount(new BigDecimal(advicePosition.getAmountOfBottles()));
```

Plan §3.2 redefines `amount` as the **total** and keeps `receiveGoods(..., line.amount(), line.amount(), 1, ...)`
unchanged; plan §0 row 11 declares `AdviceRestController` *"Excluded — expected to need no edit"*.

No hard failure — the same controller does `adviceEntity.setAllowoverdelivery(true)` two hundred lines
above, so `receiveGoods`'s guard `if (!advice.getAllowoverdelivery()) { … "Not allowed to receive more
than notified!" … }` is skipped. That is luck, not design, and the plan neither notices the guard nor the
flag that defuses it. The consequences that do land:

- `goodsreceiptposition.amount != adviceposition.notifiedamount` on every mixed line — which breaks the
  invariant the plan's own **E3** evidence rests on (*"all 1037 RETURN advices are FINISHED with
  `goodsreceiptposition.amount == notifiedamount`"*). After this ships, that query stops being a health
  check.
- `AdviceRepository`: `"(SELECT COALESCE(SUM(ap.notifiedamount), 0) FROM adviceposition ap WHERE ap.advice_id = a.id) as qtyRequired, "` — the advice list understates required quantity.
- `ReceivingDtoViewRepository`: `"ap.notifiedamount AS orderedbottles, "` — the receiving screen will read
  "ordered 7 / received 10" on every damaged return, permanently.

*Method for the consumer list:* `git grep -ln "notifiedamount" origin/develop -- src/main` (14 files),
then read the two repository query strings. *Blind spot:* it is a literal-token grep over `src/main`, so
a projection interface deriving the column by property name, or a report function inside
`V2.2.00__base_v2_schema.sql`, would not appear — and `notifiedamount` **does** appear in that SQL file,
which I did not read for view definitions.

---

**H3 — "No data-model delta" is what makes every failure mode unrecoverable, and the plan's stated reason for it answers a different question.**

Plan §3.2: *"Data-model delta: none. … The damaged quantity is consumed within the request."* It is
consumed within the request **only on the happy path**. On `DAMAGE_FAILED` the outcome carries the first
failed SKU and no quantities (`AutoReceiveOutcome.partial(...)`'s shape, reused); on `PARTIAL` it carries
nothing at all. The plan's recovery story is *"a manual damage move in the existing UI
(`WEB_UI_ACTION_ADJUST_LOCK_DAMAGED`)"* — which requires an operator to know **which stock unit** and
**how many units**, information that exists only in the OMS/QA MySQL and in one `LOG.error` line keyed by
a correlation id that no operator-facing surface indexes.

§5.1 row 5 justifies "no migration" with *"back-filling them would create WMS stock for bottles that were
physically disposed of months ago"* — a correct answer to a question about **historical backfill**, not
about a forward column. The two are conflated, and the conflation is what carries "no migration" through
the rest of the document (§7.4 row 8, §8 constraint 2).

---

### MEDIUM

**M1 — Two of `setLockDamaged`'s preconditions are missing from §3.3's derivation table, and both are environment-dependent.**

`setLockDamaged` itself carries `// TODO check locks on unit load` / `// TODO check locks on location` —
the checks are not missing, they live one layer down in `transferStockToUnitLoad`, which
`moveStockToNewDamagedContainer` calls with `ignoreLock = false`:

```java
lock = sourceUnitload.getEntityLock();
if (lock != WmsConstants.BusinessObjectLockState.NOT_LOCKED) {
    throw new BusinessException("Source unitLoad=" + sourceUnitload.getLabelid() + " is locked=" + lock);
}
lock = sourceLocation.getEntityLock();
if (lock != WmsConstants.BusinessObjectLockState.NOT_LOCKED) {
    throw new BusinessException("Source location=" + sourceLocation.getName() + " is locked=" + lock);
}
```

The **source location** here is the putaway destination, not `InboundWorkstation` — `receiveGoods` does
`unitloadBusinessService.transferUnitLoadToLocation(unitload, putaway.location(), false, codeReceiving, …)`
before returning. So a locked `PutAwayLane` (a cycle count, an operator hold) turns **every** damaged
return into `DAMAGE_FAILED` while ordinary receives keep succeeding, and §3.3's table — which derives
preconditions from `setLockDamaged`'s body alone — cannot see it. Also unlisted: the destination location
lock and `!unitloadType.getStockunitallowed()`. Add these rows, and add a manual row measuring the
locked-lane case.

---

**M2 — I2's "no leftover unlocked unit" is not tenant-independent.**

`transferStockToUnitLoad`:

```java
if (destinationStockUnit == null && (sourceStockunit.getAmount().compareTo(amount) > 0 || fixLocationAssignment != null)) {
    … destinationStockUnit = createStockUnit(client, itemdata, BigDecimal.ZERO, …);
}
…
if (fixLocationAssignment == null && BigDecimal.ZERO.compareTo(sourceStockunit.getAmount()) == 0) {
    sendStockUnitToNirvana(sourceStockunit, …);
```

`fixLocationAssignment` is resolved as
`fixLocationAssignmentRepository.findByAssignedlocationId(sourceLocation.getId())` — the **putaway
destination**. On a tenant where that location carries a fixed assignment, a fully-damaged line
(§7.2 **I2**) takes the split branch, the source stock unit is driven to `amount = 0` and is **not** sent
to Nirwana, so a zero-amount `entity_lock = 0` stock unit is left behind. That is exactly the shape the
plan's own **E2** measured (*"15 rows locked damaged but not in the location… the extras carry amount
0"*). I2's assertion *"no leftover unlocked unit"* is therefore an environment-dependent red. Name the
condition in the AC, or assert on quantity rather than row count.

---

**M3 — `setLockDamaged` has a sixth side effect the plan's reuse inventory omits, and it changes two scalability rows.**

`StockunitService.setLockDamaged`, between the OMS message and the label print:

```java
triggerReplenishmentMaintenance(stockUnit.getItemdataId());
```

which calls `replenishmentOrderMaintenanceService.recalculateForItem(itemDataId)` — `@Transactional(REQUIRED)`,
so with no ambient transaction (which is the plan's `applyDamage` shape) **it opens its own** and takes
row locks. Plan §3.3 enumerates *"all five things the three reporting surfaces need"* and does not
include it. Consequences for §7.3:

- Row 2 (*"one additional short transaction per damaged position"*) is **two**, the second one locking.
- Row 3 (*"Scheduled jobs: No — Nothing added or modified"*) is true of the job classes but false of the
  replenishment subsystem, which this path now drives once per damaged position.
- Row 4 (*"Long transactions: No"*) does not account for it.

Not a blocker — the swallow-or-rethrow logic is runtime-predicated on
`TransactionSynchronizationManager.isActualTransactionActive()` and is correct for a non-transactional
caller — but the plan must state it, because it is also what makes M4 bite harder.

---

**M4 — Damaged-location contention is asserted, not analysed.**

§7.3 row 8 is correct as far as it goes: the `findByIdForUpdate(damagedLocation.getId())` first-statement
guard exists, concurrent movers serialise on it, and the SBDEV-3250 5s bound applies. What is not
analysed is that this ticket converts an **operator-paced** path into a **machine-paced** one:

- `MAX_POSITIONS_PER_ADVICE = 500` (verified in `ReturnAdviceAutoReceiveService`), so a single
  `permitAll()` request can take that one row's `FOR UPDATE` up to 500 times sequentially, each
  acquisition followed by a `recalculateForItem` (M3).
- Concurrently: other replicas serving other returns for the same tenant, plus the manual
  `/bulkTransferToDamaged` path.
- A 5s timeout produces `DAMAGE_FAILED`, which by the plan's own §3.4 design is **not** auto-recoverable —
  it requires a manual UI action.

So contention under load degrades into manual work, at a rate nobody measures (nothing scrapes
Prometheus — the plan says so in §5.1 row 8). Recommend either a cap on damaged positions per advice, or
an explicit statement that the 500-position bound is accepted with this new cost.

---

**M5 — The OMS *arithmetic* is asserted from the OMS *shape*, and they are different claims.**

`SharedService.getStockChangeDTO(…, int total, int damaged, …)` sets `stockChange.setNormal(total)` /
`setDamaged(damaged)`. Under this plan message 1 becomes `normal = +total` (because `receiveGoods` sends
`originalAmountBottles`, which §3.2 redefines as undamaged+damaged) and message 2 is
`normal = 0, damaged = +D`. §6 records the risk as *"None to the contract. OMS sees a shape it already
handles."* The **shape** claim holds — I verified both call sites emit exactly the existing pair. The
**arithmetic** claim does not follow from it: whether OMS decrements `normal` when `damaged` rises is a
property of the OMS handler, and neither the plan nor the three evidence files contains an
`oms-laravel-api` read. If OMS treats them as independent deltas, every mixed return overstates sellable
inventory by the damaged quantity — the opposite of the ticket's goal. Make this an OQ with a named
query, not a backward-compatibility row reading "None".

---

**M6 — The reservation race is acknowledged but its magnitude is set by a choice the plan made for an unrelated reason.**

Covered in the tension section above. §3.3 correctly calls `availableamount >= amount` the weakest link
and §7 T1.7 correctly asserts the failure path rather than assuming the race away. What is missing is
that §3.4's ordering decision is what sets the window size, and that the decision was taken on
recovery-semantics grounds without pricing this. State the window explicitly (N-1 receives, each
containing a CUPS round-trip) so the Planner is choosing knowingly.

---

### LOW

**L1 — `applyDamage` step 1 routes a programming error into the least-recoverable outcome.**
§3.3: *"the assertion is a `BusinessException`, which routes into the outcome ladder of §3.4."* A broken
invariant in `receiveGoods`'s loop shape would then surface as `DAMAGE_FAILED` — stock received, advice
FINISHED, manual recovery required — rather than as a loud defect. The invariant is true today
(`amountBottles = amountBottles - amountBottlesPerCase` with `amountBottlesPerCase == amountBottles`
terminates in one pass; verified in `ReceivingService`), so this is about the failure mode, not the
assertion. Prefer an unchecked `IllegalStateException` plus a unit pin on the call shape.

**L2 — §3.5's pre-flight uses a field-validation code for a tenant-misconfiguration condition.**
The proposed throw is
`new WebserviceBusinessExceptionClientSide(WmsConstants.FIELD_MALFORMED_FORMAT, null, "amount_of_bottles_damaged", adviceDto)`.
The two existing tenant-misconfiguration pre-flights in the same method use different vocabulary —
`DEFAULT_TYPE_NOT_EXIST` with `meterRegistry.counter("wms2.returns.autoreceive.rejected_tenant_misconfigured")`,
and `ENTITY_DOES_NOT_EXISTS` for the missing `UNIT_LOAD_TYPE_BOX` row. Telling OMS its *field* is
malformed when the *tenant* is missing a `location` row sends the operator to the wrong system.
`ENTITY_DOES_NOT_EXISTS` with a generic entity name (not the literal `"Damaged"`) keeps the
`permitAll()` disclosure discipline and is accurate. Add the misconfigured counter too.

**L3 — The `DAMAGE_FAILED` 200 will be cached and replayed by `IdempotencyFilter`, and the plan does not say so.**
The controller carries a long comment justifying exactly this for warned responses —
*"⚠ THIS 2xx IS DELIBERATELY CACHEABLE BY IdempotencyFilter. DO NOT 'FIX' THAT."* — and
`DAMAGE_FAILED` inherits it silently because `isWarning()` is `status != SUCCESS`. The inherited
reasoning happens to be right (a replay is better than manufacturing a duplicate-key error), but it was
written for a state where the advice stays `OPEN`; here the advice is `FINISHED`. Add one sentence and
one AC.

**L4 — §0 row 11's "no controller edit expected" is falsified if H2 is fixed.**
The row is carefully written as *"an expectation with a test attached (T1.9), not an assumption"*, which
is the right posture — but T1.9 tests the *warning envelope*, which is genuinely generic
(`warning.put("code", autoReceiveOutcome.code()); … .reason() … .correlationId()`, verified). It does not
test `setNotifiedamount`. The two are different claims about the same file.

**L5 — Phase-2-before-Phase-1 safety is argued for v1 and never for v2.**
§3.7 goes to real trouble to make *"v1 ignores the new field"* executable. The same question for **v2
before Phase 1 lands** is never asked, even though §5.1 row 4 asserts *"if Phase 2 lands first the new key
is simply dropped by every WMS"*. It is true — `WebConfigurer` does
`mapper.configure(DeserializationFeature.FAIL_ON_UNKNOWN_PROPERTIES, false);` and again
`builder.featuresToDisable(DeserializationFeature.FAIL_ON_UNKNOWN_PROPERTIES);` and again at the
converter, and `WmsObjectMapper` a fourth time — but the plan states it without evidence on the very
repo it is changing. Cite it; it is a one-line grep. *Method:* `git grep -n "FAIL_ON_UNKNOWN_PROPERTIES|JsonIgnoreProperties" origin/develop -- src/main/java`, 4 hits, no `@JsonIgnoreProperties` anywhere.
*Blind spot:* same as §3.7's — a mix-in registered on the mapper would not appear in that grep.

---

## Answers to the seven questions asked

**1 — Is the freshly-received stockunit reliably at `entity_lock = 0` and unreserved?**
`entity_lock`: yes, reliably. `StockunitBusinessService.createStockUnit` is called with no lock argument
and `stockunit.setReservedamount(BigDecimal.valueOf(0))`; the column defaults to `0`. Unreserved: **not
reliably**, and the plan is right to call it the weakest link. `getAvailableamount()` is
`@Transient … return amount.subtract(reservedamount)`, so any reservation makes `setLockDamaged` throw
`"Stock unit has too much reserved amount. Please cancel orders first!"`. The concrete grabber is
`ReplenishGeneratorService.changeReservedAmount(sourceStock, …, WmsConstants.CODE_REPLENISHMENT_CREATED, …)`
driven by `ReplenishOrderJob`. **Before or after the transfer:** after, correctly — the plan calls
`applyDamage` once `receiveGoods` has returned, by which time the unit load is at the putaway
destination, and §3.3 step 2 re-reads by id *"exactly as `StockUnitController` does"*, which I confirmed
(`stockunitRepository.findById(id).orElseThrow(…)` outside any transaction, OSIV off). That choice is
right. What is wrong is the *window size* — see M6.

**2 — Transaction and lock architecture.**
(a) **No lock-ordering inversion found.** `applyDamage` runs with no ambient transaction, so the
`FOR UPDATE` on `Damaged` is taken and released inside `moveStockToNewDamagedContainer`; the order there
is Damaged → src-stockunit → src-unitload → src-location → dst-unitload → dst-stockunit → dst-location,
with Damaged pre-taken so the last acquisition is a no-op. *Method:* read of both lock sequences in
`UnitloadService` and `StockunitBusinessService`. *Blind spot:* I did not enumerate every
`findByIdForUpdate(location…)` caller in the repo, so "no inversion" is a reading of this path's two
sequences, not a census of all of them.
(b) **No REQUIRES_NEW-inside-lock-holder.** The sequence write is hoisted out by design —
`mintUnitloadLabel` is called by `setLockDamaged` *before* `moveStockToNewDamagedContainer`, with the
javadoc *"mints a unit-load label WITHOUT opening a transaction… so the `REQUIRES_NEW` sequence write
never runs inside a lock-holding transaction."* Reuse preserves it; a reimplementation would not have.
(c) **Yes, there is a committed-as-`entity_lock=0` window, and it is unavoidable in this design.**
`receiveGoods` commits, then `applyDamage` runs. Between them the stock is pickable. The plan does not
name this window as such anywhere — it discusses the *reservation* race but not the *pickability* of the
committed-unlocked interval. It should, because it is the one thing Alternative A would have eliminated
and the steelman's strongest point.

**3 — The `AutoReceiveOutcome` contract.** The `DAMAGE_FAILED` design is coherent *for the failure it
names*: `markFinished` runs, so `ReceivingService` refuses a dock re-receive
(`if (!AdviceState.OPEN.equals(advice.getState())) throw`), so no double-receive; an OMS retry either
replays the cached 200 (L3) or hits the `ENTITY_ALREADY_EXITS` duplicate guard. Adding the fourth status
is compile-enforced — `code()` is a `return switch` over `Status` with all arms present, so omitting one
will not compile. **What is not coherent is the case the question actually asks about in its second
half:** "the good portion receives but the damage step throws" is handled; "*some* positions receive and
then a *receive* throws" is not — that is `PARTIAL`, and it silently drops the damage for the positions
that did receive (**H1**).

**4 — Preflight placement.** Yes, §3.5 places it correctly: in `resolveRefs`, after the loop, conditional
on any `damagedAmount > 0`, before `adviceRepository.save`. It matches the R9 discipline the method
already applies to `MAXIMUM_RECEIVING_DURING_INBOUND` and `UNIT_LOAD_TYPE_BOX`, and §3.5's two caveats
(conditional; a gate not a hand-off, because `resolveRefs` is `readOnly` and OSIV is off) are both right.
The name-keyed / no-unique-index / per-tenant-id facts are all correctly carried. Two refinements: the
error code is wrong (**L2**), and the pre-flight does not narrow the *other* environment-dependent
failures I found (**M1**), so I3's "clean 400" covers one of at least three ways a tenant can make the
damage step fail.

**5 — Multi-tenant + horizontal scalability.** Rows 1, 5, 7, 9 are correct as written. Row 2 undercounts
(**M3**), rows 3 and 4 are written as if replenishment is untouched (**M3**), row 8 is asserted rather
than analysed (**M4**). Row 6 is the plan's best row — it is honest that `setLockDamaged` is not
idempotent, correctly derives that the `externalid` guard prevents double-damage, and says "recorded,
not mitigated in code" rather than pretending. Row 10's warning about not moving `applyDamage` into an
`afterCommit` is correct and load-bearing; I confirmed the rail it cites exists in the OMS-notification
javadoc chain.

**6 — Phase independence.** The claimed ordering is real. Phase 2 before Phase 1 is harmless on both
sides (v1 per §3.7/E5; v2 per **L5**, which the plan asserts without citing). Phase 1 before Phase 2 is a
true no-op: `damaged` is always `null → 0`, so `total == undamaged` and the `>= 1` relaxation cannot
change any verdict. **One coupling is not stated:** Phase 3 (Defect A) is the *volume amplifier* for the
defect Phases 1–2 fix. Fixing the disposition select makes restock actually fire for every client whose
`ship_return_management` preference is pre-set — so shipping Phase 3 first, as §8 constraint 5
recommends, increases the number of returns flowing through the damage-losing path before the fix
exists. That does not make Phase 3 wrong (the operator's intent was restock either way), but "highest
client-visible value, ship it first" should be stated alongside "and it increases exposure to the loss
until Phase 2 lands."

**7 — The two-warehouse WMS-URL finding (FU-4).** It does **not** invalidate the design. `qa-api` resolves
the target by `get_wms_base_url(return_location)` → `select(wul_.c.wms_url).where(wul_.c.facility_code == return_facility)`,
and `return_location` arrives from the UI request body (`return_location = data.get('return_location')`
in `views/parcel_info.py`), so the routing defect is upstream of and orthogonal to everything this
ticket changes. *Method:* read of `wms_api.get_wms_base_url` and the view handler; *blind spot:* I did not
read the qa-ui submit payload, so "it is the fulfilling facility" remains the plan's claim, not mine.
**But its priority should rise for ShipItEZ specifically.** Good stock sent to the wrong warehouse is a
transfer; damaged stock sent to the wrong warehouse is damaged inventory recorded at a site that never
physically held the bottles, and it interacts with OQ-5 (`wh02_shipitez`'s RETURN printer was never
checked). FU-4 ranked "4th — ask Brent before coding" is defensible for the general case and low for a
two-warehouse client about to cut over to v2 with this feature on.

---

## What the plan gets right, and should not be talked out of

Worth recording so the next lane does not re-litigate settled good work:

- The **W1/W2/W3 wire analysis** is the strongest section in the document. W2's rejection is derived
  correctly end-to-end — v1 accepts `0`, commits, then `ReceivingService` throws
  `"argumentMustBeGreaterZero"`, burning `externalid` into an unrecoverable parcel. That is exactly right
  and it is the kind of reasoning that only comes from reading both sides.
- **Alternative C's rejection on non-termination** (`amountBottles -= 0` with `amountBottlesPerCase = 0`)
  is a real infinite loop in a transaction holding a tenant connection. Correctly identified.
- **§1.3's reframe — grade the lock, not the location** — is right, and is the single most valuable
  paragraph for whoever writes the ACs.
- **§7.6's refusal to write a verify script**, with reasoning, is correct for this ticket.
- **D4's pre-emptive recording** so a review lane does not re-raise it worked; I am not re-raising it.

---

## Recommended disposition

Return to Planner for rev2 with three required changes and four recommended ones.

**Required (blocking):**
1. Resolve H3 — add `adviceposition.notifieddamagedamount` (one `V2.2.x` migration), or state explicitly
   why an unrecoverable H1/H2 is accepted. This unblocks the other two.
2. Resolve H2 — decide `notifiedamount = total` (recommended, and it follows from #1) or record the
   permanent over-delivery in §6 with the two named report consumers.
3. Resolve H1 — with #1 in place, either interleave the loops or add a recovery path; without #1, state
   that a partial receive silently ships damaged stock.

**Recommended:** M1 (precondition rows + a locked-lane manual row), M3 (correct §7.3 rows 2–4), M4
(cap or accept), M5 (make the OMS arithmetic an OQ), L2 (error code). L1, L3, L4, L5 are one-line fixes.

**Re-tier note:** escalation trigger (2) from `wms-triage` — *"the fix needs a repository/service method or
projection you had not anticipated"* — is arguably met by H2/H3 (a column and an entity write the plan
excluded). It is already T3, so nothing moves; but the "no Flyway migration" premise that several later
sections rest on (§5.1 row 1, §7.4 row 8, §8 constraint 2) should be re-examined rather than patched.
