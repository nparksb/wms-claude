---
title: "SBDEV-3755 ralplan r1: architect review"
ticket: SBDEV-3755
lane: architect
round: 1
plan_snapshot: "SBDEV-3755-transferstock-replen-held-opt-in.md (r1, status pending approval)"
code_base: "wms2-api origin/fix/SBDEV-3755-replen-holder-multi-and-child-banner @ c6f0cbc0 (#510); origin/develop a4fd6490"
created: 2026-10-13
verdict: "APPROVE WITH CHANGES"
---

# SBDEV-3755 ralplan r1: architect review

**Verdict: APPROVE WITH CHANGES.** 0 High · 5 Medium · 9 Low.

I checked the nine load-bearing claims against #510 @ c6f0cbc0, read with `git show`. Seven hold as written. Two hold only once a fixture or wording condition is added: claim 4 (lock order) and claim 8 (AC-17 red on base). None of the findings disputes the design or §10 D1–D4. They are about completeness, documentation and test non-vacuity. No mid-flight escalation trigger fires.

Code citations are `file:line` on #510 unless marked.

---

## 1. Load-bearing claims: verification

| # | Claim | Verdict | Evidence |
|---|---|---|---|
| 1 | `fla == null && A <= amount` is exactly {re-parent, drain-to-zero} | **Holds** while R ≥ 0. It is exact because it keys on the same `fixLocationAssignment` variable the branch decision uses, including a caller-preloaded FLA (BOL `transferLaneFla`, club `stagingLaneFixAssignment`). | Placeholder: `if (destinationStockUnit == null && (sourceStockunit.getAmount().compareTo(amount) > 0 \|\| fixLocationAssignment != null))` (`StockunitBusinessService.java:328`). Re-parent: `if (destinationStockUnit == null)` (`:337`), which needs ¬(A>amount ∨ fla) = (A≤amount ∧ fla==null). Drain: `if (fixLocationAssignment == null && BigDecimal.ZERO.compareTo(sourceStockunit.getAmount()) == 0)` (`:416`). The available guard `getAmount().subtract(getReservedamount()).compareTo(amount) < 0` (`:206`) gives amount ≤ A when R ≥ 0, so on the merge arm A ≤ amount ⇔ A = amount ⇔ drain. With R < 0 the predicate over-approximates: a merge can leave the source negative and not drained. That state is already corrupt, so a refusal there is acceptable. Say so in the javadoc (L-6). |
| 2 | The guard runs before any write | **Holds inside SBS.** Lines 180–326 are lock reads and validations only. The first write is `createStockUnit(...)` at `:334`. | `lockOwningPickingorders` and `LockReads.forUpdate` take locks and do not write. The callers' own prior writes roll back with the tx. The one exception is a REQUIRES_NEW label mint in the caller (L-7). |
| 3 | DI: SBS cannot take `ReplenishorderService` or the trigger; `PickingorderBusinessService` can take the trigger | **Holds.** | `ReplenishorderService` has `private final StockunitBusinessService stockunitBusinessService;` (`ReplenishorderService.java:34`). Trigger → `private final ReplenishmentOrderMaintenanceService maintenance;` (`ReplenishmentMaintenanceTrigger.java`) → `private final StockunitBusinessService stockunitBusinessService;` (`ReplenishmentOrderMaintenanceService.java:82`): a cycle. The trigger's transitive graph is maintenance → {repos, SBS, `SyspropService`→`ClientService` (repos only)}, SBS → {`UnitloadBusinessService` (`@Lazy` class) → `ReplenishmentOrderSourceSyncService` (`@Lazy` maintenance), `ItemdataService` (repos), `PickLineRealignmentService` (repos)}. None of these reaches `PickingorderBusinessService`, so the new edge PBS → trigger closes no cycle. `PickingorderBusinessServiceUnitTest` uses `@InjectMocks`, and `git grep "new PickingorderBusinessService("` finds only a javadoc hit, so no constructor call sites need edits. `ReplenishmentMaintenanceCallSiteArchTest` restricts direct `recalculateForItem` callers only, not trigger users. |
| 4 | Fix B lock order agrees with the 3622 cut and `recalculateForItem`, so there is no deadlock edge | **Holds for those two lockers. The claim as worded is too broad (M-1).** | Cut: POs → holders ≤300 ascending → SU (`StockunitService.java:991,998-1004,1019`). Cron: `findIdsByStateAndItemdataId ... ORDER BY r.id` (`ReplenishorderRepository.java`), then one tx per item, order → SU → target per order (`ReplenishmentOrderMaintenanceService.java:161-200`). Fix B: holders ascending → SU. If the cron holds order 5 + S and waits on 9, the move cannot hold 9 without 5. No cycle. **But** the move takes the **unit load** before any order: `unitloadRepository.findByLabelidForUpdate(...)` (`MobileMoveUnitloadService.java:367`) and the UL `save` in `processTransfer` (`UnitloadBusinessService.java:525-526`). The replen finish takes order → SU → UL: `findByIdForUpdate(request.getOrderId())` (`MobileReplenishService.java:853`), SUs ascending (`:907`), then `transferStockToUnitLoad` locks the source UL (`StockunitBusinessService.java:238`). That is a pre-existing UL↔order ABBA at N=1. It is not a new edge class, but §4's "every locker takes orders → SU" omits it, and AC-18 cannot see it. |
| 5 | `shareOf` is a live read per order | **Holds.** | `shareOf` reads `locked.getReservedamount()` from the entity passed in, and `sumRequestedAmountOfOtherOpenOrdersOnStockunit` is JPQL (`ReplenishmentOrderMaintenanceService.java:964-976`), so AUTO flush makes the previous order's `markCancelled`/re-point visible. The release goes through `changeReservedAmount` → `LockReads.forUpdate`, which for a managed row does `entityManager.refresh(managed, PESSIMISTIC_WRITE)` and returns the **same instance** (`LockReads.forUpdate`). So `lockedSource` and the mutated row are one object, and the plan's AC-19 instrument is the right one. |
| 6 | #12 double-trigger avoidance | **Holds.** | `setLockDamaged` carries no `@Transactional`, and the in-code comment confirms it: *"this method is not @Transactional (nor is StockUnitController)"* (`StockunitService.java:810`). It calls the helper cross-bean (`:829`, the helper is `@Transactional` at `UnitloadService.java:173`) and then `replenishmentMaintenanceTrigger.requestForItem(stockUnit.getItemdataId());` (`:841`) with no tx, so `runNow`. A second request inside the helper would defer to the helper's commit, which is a different tx, so the trigger's per-tx `LinkedHashMap` would not de-duplicate it. The only callers of `moveStockToNewDamagedContainer` are `setLockDamaged`, and its callers are `StockUnitController:591,633` and `ReturnAdviceAutoReceiveService:1005`. |
| 7 | AC-6 InOrder is achievable | **Holds.** | In unit tests `@PersistenceContext entityManager` is null, so `LockReads.forUpdate` takes the `session == null` branch and calls `stockunitRepository::findByIdForUpdate` (`LockReads.forUpdate`, first statement). `inOrder(stockunitRepository, replenishorderRepository)` can therefore observe the lock → `findHolders…` → `findById` sequence. The 10-arg overload is reached by `this.` delegation from the 8/9-arg ones, so no proxy is needed. |
| 8 | AC-17 really fails on the base commit | **Holds, given two conditions the plan does not state (M-3).** | Base probe: `Optional<Long> findIdByStateLessThanAndStockunitId` with JPQL `SELECT r.id ... WHERE r.state < :state AND r.stockunitId = :stockunitId` (`ReplenishorderRepository.java:222-226`). Spring Data's single-result execution throws `NonUniqueResultException`, which the repository translates to `IncorrectResultSizeDataAccessException`. Condition 1: the IT enters through a BLOCK_REALIGN whole-UL move (`UnitloadBusinessService.processTransfer:533-537`), **not** through the `MobileMoveUnitloadService` stock arm, which the SBDEV-3747 pre-check refuses first (`MobileMoveUnitloadService.java:776`). Condition 2: the fixture's two holders need **different `destination_id`**, or the seed itself fails with 23505 on `CREATE UNIQUE INDEX idx_replenishorder_active_item_dest ON public.replenishorder USING btree (itemdata_id, destination_id) WHERE (state < 700)` (`V2.2.00__base_v2_schema.sql:3876`). |
| 9 | ArchUnit AC-13 is feasible and non-vacuous | **Feasible. Non-vacuous only with the implementation notes in L-4.** | Callers go through the Spring proxy by a compile-time call on `StockunitBusinessService`, which ArchUnit sees as a `JavaMethodCall` on the 10-arg signature. Enclosing methods: `PickingorderBusinessService.confirmPick` (`:1208`, call at `:1326`), `StockunitService.transferStock` (`:289`, #10 at `:605`), `UnitloadService.moveStockToNewDamagedContainer` (`:174`, call `:192`), `MobileReplenishService.finishReplenishmentOrderWithoutRefill` (`:212`, call `:317`). Exactly one call site each today. |

Census cross-check: `git grep -n "transferStockToUnitLoad(" #510 -- src/main`, excluding SBS and comments, returns exactly 18 call expressions in 10 files. That matches §0.

---

## 2. Findings

### M-1 (Medium): §4's lock-order statement omits the move's UL → order edge, and Fix B waits on STARTED holders it is about to refuse

**Evidence.**
- Mobile move entry: `Unitload sourceUnitLoad = unitloadRepository.findByLabelidForUpdate(dto.getUnitLoadLabel())` (`MobileMoveUnitloadService.java:367`). In `processTransfer`, `unitload.setStoragelocationId(destinationLocation.getId()); unitload = unitloadRepository.save(unitload);` runs **before** `syncForMovedStockUnit` (`UnitloadBusinessService.java:525-537`).
- Replen finish: `Replenishorder template = replenishorderRepository.findByIdForUpdate(request.getOrderId())` (`MobileReplenishService.java:853`) → SUs (`:907`) → `transferStockToUnitLoad` → `LockReads.forUpdate(... Unitload.class, sourceStockunitUnitloadId ...)` (`StockunitBusinessService.java:238`).
- Plan §5 B step 2–3: *"For each holder id ascending: `findByIdForUpdate(id)` … If any locked order `blocksMove(order)`, throw"*. It locks first and checks second, including a STARTED holder whose finish may hold that row's lock.

**Why it matters.** If the move holds UL U and waits on order 9 while 9's finish holds 9 + S and waits on U, PostgreSQL detects the cycle and one side gets 40P01. This exists today at N=1 (base: `findByIdForUpdate(probeId)` after the UL lock). It is pre-existing, so it does not block the plan. But the plan's text claims a global property that the code does not have, and Fix B makes every multi-holder move wait on every STARTED holder before it can refuse. The analysis already proposed the narrowing (An §4 step 2, *"Pre-check (no lock): if any holder has `blocksMove(state)`, throw … This is optional"*), and the plan dropped it without saying why.

**Change.**
- (a) Restate §4: *"orders ascending → SU on every locker; the move additionally holds its UL (and dest Location) before the orders, and the replen finish takes order → SU → UL, a pre-existing ABBA detected by PG (40P01), not introduced here."* Add it to R6.
- (b) In Fix B, refuse from the projection **before** taking any order lock when a holder's projected state is ≥ STARTED, and keep the under-lock re-check. This costs nothing (the projection is already read) and removes the wait in the common in-progress case.
- (c) Add a unit assertion: projected holder @500 → `findByIdForUpdate` is never called.

### M-2 (Medium): #10's new trigger contradicts the standing SBDEV-2033 comment in the same method, and the plan does not mention it

**Evidence.** `StockunitService.transferStock` (`:640-644`):
> `// [SBDEV-2033] Intentionally NOT triggering replenishment maintenance here. … triggering recalculateForItem() would immediately re-reserve stock on any open replenishment orders, undoing a reservation the operator just released.`

`ReplenishmentOrderMaintenanceService.java:176-187` already warns readers not to trust that comment blindly, because of the FLA-creation route.

**Why it matters.** The case D3 opts #10 into (R ≤ 0 + holder, followed by a damage move) is exactly the shape SBDEV-2033 described: a release, then a move. Post-3622 the release cancels the holder, so the conflict is mostly moot, and the recalc runs only when `displacedHolders` is non-empty. A reviewer or a later session reading the old comment will still flag or revert the new call. There is also a side effect the plan does not state: `recalculateForItem` recalcs **every** PROCESSABLE order of the item, so a partially-cut order may regrow (3622 D-H1). The cron would do the same within a minute.

**Change.** Amend the SBDEV-2033 comment in the same commit, scoped to "except when a damage move displaced an active holder (SBDEV-3755 D3), after commit". Note in §5 A.6 that the recalc is item-wide.

### M-3 (Medium): Multi-holder IT fixture traps are not named: the partial unique index, and the entry path

**Evidence.**
- `CREATE UNIQUE INDEX idx_replenishorder_active_item_dest ON public.replenishorder USING btree (itemdata_id, destination_id) WHERE (state < 700);` (`V2.2.00__base_v2_schema.sql:3876`). Two active holders of one SU necessarily share `itemdata_id`.
- SBDEV-3747 stock-arm refusal: `Replenishorder heldBy = replenishorderService.existsForStockUnit(sourceStockUnit);` (`MobileMoveUnitloadService.java:776`).

**Why it matters.** AC-17/18/19 and manual row 5 all need two active holders on one SU. With a shared destination, the seed dies with 23505, and a hurried implementer may "fix" it by putting one holder at state 700, which makes the test vacuous. If AC-17 enters through the mobile stock arm, it goes red on base for the wrong reason (the 3747 refusal, not `IncorrectResultSizeDataAccessException`), and green after the fix for the wrong reason.

**Change.** In §8.1, under "Fixture traps", add:
- two holders need distinct `destination_id`;
- AC-17/19 enter through `UnitloadBusinessService.transferUnitLoadToLocation` with a BLOCK_REALIGN code (`CODE_MANUAL_TRANSFER`), or through the mobile **location** arm;
- AC-17 asserts the base failure **by type** (`IncorrectResultSizeDataAccessException` in the cause chain);
- for AC-19, no other stock of the item may exist anywhere, or redirect will find a candidate.

### M-4 (Medium): AC-18 (no deadlock under a latch) can pass vacuously

**Evidence.** AC-18: *"under a latch, both txs end; neither ends in SQLSTATE 40P01."* Nothing in it proves the two transactions ever contended.

**Why it matters.** A latch orders thread starts, not lock acquisition. If the cut finishes before the move reaches its first order lock, the test is green for any lock order, including the descending-order mutant. That mutant is caught only by the unit-level AC-14. The PG IT lane has no tenant pool (N threads = N connections), so the test also needs its connection budget stated.

**Change.** Add a positive control: before releasing the second thread, poll `pg_stat_activity` (or `pg_locks`, `granted = false`) until the second backend shows `wait_event_type = 'Lock'`. Fail the test if it never does within the bound. Then mutation-check AC-18 itself by reversing the cut's or the move's order in a scratch build and confirming 40P01 or a timeout. Without that, it should be labelled a smoke test, not an AC.

### M-5 (Medium): Test-churn inventory for Fix B is incomplete, and opt-in caller mocks will NPE silently

**Evidence.** `git grep -c findIdByStateLessThanAndStockunitId -- src/test` on #510:
- `ReplenishmentOrderSourceSyncServiceBranchTest` (3, `lenient().when(...)` at `:104,121,136`)
- `ReplenishmentOrderMaintenanceServiceUnitTest` (1, `:2233`)
- `ReplenishmentIdProjectionContractUnitTest`, which has a **second** reference in a name list at `:158` (`"findStockunitIdsByIdIn", "findIdByStateLessThanAndStockunitId"}`)

The plan lists none of these three; it names only `…SourceSyncServiceTest`, `…ReassignTest` and the two contract tests.

For the opt-ins, the 10-arg overload returns a record. A Mockito mock returns `null` for it, so every existing `confirmPick` / `transferStock` / damage / finish test that stubs the 8-arg overload will reach `outcome.displacedHolders()` / `.stock()` and NPE.

**Why it matters.** The compile breaks are loud. The real risk is a "fix" that wraps the NPE with a null check in production code to make tests pass, which would hide an unstubbed path.

**Change.**
- Add the three files to §6/§8.1.
- State in §6 that every caller test for #5/#10/#12/#15 must stub the policy overload with `new TransferOutcome(stock, List.of())` as its default.
- Production code must not null-check `TransferOutcome`. ArchUnit or review should treat a null return as a bug.

### L-1 (Low): The REFUSE path's `findById(chosen.getId())` has no defined empty case

**Evidence.** Plan §5 A.3: *"Only now `findById(chosen.getId())`."* #510's newest commit exists for exactly this case: `c6f0cbc0 test(replenish): pin existsForStockUnit when the chosen holder's row is gone`.

**Change.** Specify that the refusal is built from the projection's `getNumber()` when `findById` is empty, so it stays a 422 and never becomes an `EntityNotFoundException`. Better still, add `getSourcelocationname()` to `ReplenishorderHolderView`, which avoids loading the entity at all. Adding a getter is harmless to the 3622 cut planner.

### L-2 (Low): ALLOW_ANY over a STARTED holder strands an in-progress replen, and the WARN does not say so

**Evidence.** After #5 or #10/#12 the moved SU carries `PICKED_FOR_GOODSOUT` or `QUALITY_FAULT`. The holder's finish is then refused by `if (!ignoreLock) { ... "Source stockUnit=" ... " is locked=" ...` (`StockunitBusinessService.java:282-290`), and the recalc heals only 300 (An §1, `REDIRECT_NO_HEAL`).

**Change.** D2/D3 are binding, so this is about documentation only: include each holder's **state** in `REPLEN_HELD_DISPLACED holders={}`, e.g. `REPL062966@500`, so support can see a stranded in-progress replen. Name the residual in §9 next to R4.

### L-3 (Low): Fix C keeps an entity finder with the same trap as the finder Fix B deletes

**Evidence.** Fix B deletes `findIdByStateLessThanAndStockunitId` because *"leaving it is a trap"*. Fix C keeps `Optional<Replenishorder> findByStateLessThanAndStockunitId` (`ReplenishorderRepository.java:128-129`), which throws identically on ≥2 rows **and** loads an entity, the SBDEV-3244 F5 first-touch hazard. Once it is `exported = false`, its only consumers are tests.

**Change.** Pick one rule for both finders. Either delete it too (one test `never()` at `ReplenishmentOrderMaintenanceServiceReassignTest:185`, and the `ReplenishorderServiceUnitTest` stubs if #510 left them), or add the same "throws on multi-holder; do not use in src/main" javadoc plus an ArchUnit no-caller rule. Deleting is cheaper than guarding.

### L-4 (Low): AC-13 implementation notes needed for non-vacuity

- Import with `ImportOption.DoNotIncludeTests`. Otherwise test classes that call the overload count as callers (memory: src-wide scans pick up test classes).
- Use `getAccessesToSelf()` (calls **and** method references), not `getCallsOfSelf()`. Resolve the target by its full 10-parameter list.
- Name the transitive blind spot: any new caller of `UnitloadService.moveStockToNewDamagedContainer` or `MobileReplenishService` paths inherits ALLOW_ANY without appearing in the rule. Today the helper's only caller is `StockunitService.setLockDamaged` (`:829`).

### L-5 (Low): AC-1 and AC-8 assert things the instrument cannot observe

- AC-1 *"`createStockUnit` [is] never called"*: `createStockUnit` is a method on the class under test (`@InjectMocks`), so it cannot be verified without a spy. Assert `stockunitRepository.save` never and `clientRepository.findById` never, which is the first statement of the placeholder block at `:331`.
- AC-8: `archunit.properties` sets `freeze.store.default.allowStoreCreation=true` and leaves store updates at ArchUnit's default, so a resolved violation is pruned automatically. The test is green whether or not line 38 is deleted by hand. The real AC is the negative one: moving the body **without** `.orElse(null)` must go red. Make that the mutation check.

### L-6 (Low): Two guard-scope edges should be stated in the javadoc

- **FLA drain-to-zero is excluded.** AC-4 excludes it, but An §1 lists *"or at 0 on the FLA location"* as a displacement. The exclusion is defensible: the SU stays at its location, and `isSourceUsable`'s `amount <= 0` heals it at 300. The plan should say that it is deliberate.
- **R < 0** over-approximates (claim 1). Name it as accepted.

### L-7 (Low): "Refusal writes nothing" holds for SBS, not for every caller

**Evidence.** For #6/#11, `unitloadService.createUnitload(...)` mints a label through a REQUIRES_NEW sequence write before the transfer (`StockunitService.java:377,581`; `setLockDamaged`'s comment: *"mintUnitloadLabel below is the first, a REQUIRES_NEW sequence write"*). A refusal burns one UL label number.

**Change.** Reword horizontal-scalability row 6 to "the refusal commits nothing in the caller's transaction; a REQUIRES_NEW label draw by the caller may be burned (harmless gap)".

### L-8 (Low): RTS is an indirect REFUSE caller and should be named

`CancellationReversalService.completeReversal` reaches `transferStock` (An §2 "Indirect callers"). §0 and R2 list BOL and club as batch aborts but not RTS. Its stock comes from cancelled-order totes or parcels, so it is practically unreachable. One line in R2 closes the census.

### L-9 (Low): #5 and #10 duplicate the "trigger iff displaced" rule

Both sites will carry `if (!outcome.displacedHolders().isEmpty()) replenishmentMaintenanceTrigger.requestForItem(itemdataId)`. Mutation "unconditional trigger" is pinned per site (AC-10, AC-11), so drift is caught. A two-line static helper in the trigger's package (`healIfDisplaced(outcome, itemId, trigger)`) would make it one rule with one test. This is optional.

---

## 3. Steelman antithesis

**Strongest case against the chosen design: put the guard at the callers, not inside `transferStockToUnitLoad`.**

1. **Layering inversion.** `StockunitBusinessService` is the stock primitive that the replenishment subsystem itself depends on: `ReplenishmentOrderMaintenanceService.java:82`, `ReplenishorderService.java:34`, `MobileReplenishService.java:66`. Fix A makes the primitive read replenishment state. The DI graph can only avoid a cycle by taking the **repository**, not the service, and by pushing the trigger back out to callers through a new return type. Those are two symptoms of one inverted dependency, and the plan pays for it with the `TransferOutcome` split and the per-caller trigger wiring (#5, #10) that L-9 already finds duplicated.
2. **A latent invariant guarded at the costliest point.** Post-3622, PRD shows 0 R≤0 holders and 0 multi-holder SUs, and every observed displacement self-healed at 300 within 50 s. The guard's new behaviour is a hard refusal on 14 sites, including whole-BOL builds (#1/#2) and club runs (#3), where the operator can neither see nor act on the replen. It catches a drift the cron would repair in under a minute.
3. **The existing pattern is caller-side.** SBDEV-3747 guarded the one real PRD hazard path (#13) at the caller with a specific message. P-1 (`MobileTransferOrderService:424`, the null-code `transferUnitLoadToLocation`) shows that a primitive-level guard does not close the class anyway: the same R=0 hole reaches stock through a second primitive.
4. **`TransferOutcome` as a second return type** leaks an implementation concern (who was displaced) into the API of a method whose contract was "move stock, return the destination SU". Four callers now unwrap `.stock()`, and every caller test has to learn the record (M-5).

**Why I still favour the plan.** A caller-side guard is pre-lock: SBDEV-3747's check is explicitly *"Pre-lock, not TOCTOU-safe"* (An §2 #13). It is also opt-**out**, so a new caller is unguarded by default. Only inside the primitive can the predicate key on the exact branch variable (`fixLocationAssignment`, the locked `getAmount()`) under the source-SU lock, and that is what makes claim 1 exact rather than approximate. Point 2 is answered by RALPLAN driver 1 and R2: the same drift with R > 0 already aborts those batches today through "more than available".

**On deleting `findIdByStateLessThanAndStockunitId`:** the antithesis is that it encodes SBDEV-3244 F5's first-touch rule, which the contract tests pin. The list projection preserves the same property, since it is a projection that loads no entity, and the re-targeted contract test keeps it pinned. The inconsistency worth fixing is L-3, not the deletion.

**On Fix B acting on the locked set:** the antithesis is that the 3622 cut refuses on drift (`RESERVATION_CUT_CHANGED`), so the move should too. The plan's answer holds: the cut refuses because it is a consented operation over a previewed holder list, and a move has no consent to protect. Refusing on drift would still not close the post-probe-insert residual, because creation inserts before it locks the SU.

---

## 4. Tradeoff tensions and synthesis

**T-1: Default-safe centrality vs layering and blast radius.** The guard is correct by construction only inside the primitive, which is the stronger guarantee. The primitive is shared by batch flows whose abort radius is a whole truck or club run. Synthesis, within D1: keep the guard central, and make its output carry the batch context already planned (the `Stock unit … on unit load …:` prefix). Add `REPLEN_HELD_REFUSED su=… ul=… code=… holder=…` as a WARN token at the throw, next to `REPLEN_HELD_DISPLACED`. A BOL or club abort on drift then becomes findable in the log without a stack-trace hunt. The cost is one log line. This keeps principle 1 (default-safe) without making batch aborts opaque.

**T-2: Fix B's under-lock correctness vs lock-wait exposure.** Locking every holder before judging any of them makes the decision correct under contention. It also makes the move wait on the lock of a STARTED order that it will refuse anyway, and in the UL↔order ABBA (M-1) that wait turns into a 40P01. Synthesis: projection pre-check for ≥ STARTED (no lock, fast refusal), then the full ascending lock + re-check. This is both cheap and correct, and it is what An §4 step 2 proposed.

**T-3: Explicit `TransferOutcome` vs an implicit event.** Publishing a `ReplenHeldDisplacedEvent` through `ApplicationEventPublisher` would keep the `Stockunit` return type and avoid any DI cycle. It would hide the opt-in's consequence at the call site, though, which is exactly what principle 1 and AC-13 want to keep visible. I would keep `TransferOutcome` and take L-9's helper to de-duplicate the trigger rule.

---

## 5. Missing items (summary)

- **Lock-edge class:** move UL → order vs replen finish order → SU → UL (M-1). Pre-existing, but undocumented.
- **IT fixture traps:** `idx_replenishorder_active_item_dest` distinct destinations, the entry path for AC-17/19, an empty candidate pool for AC-19 (M-3), and the contention proof for AC-18 (M-4).
- **Test files:** `ReplenishmentOrderSourceSyncServiceBranchTest`, `ReplenishmentOrderMaintenanceServiceUnitTest`, `ReplenishmentIdProjectionContractUnitTest:158` (M-5).
- **Callers and paths:** RTS (L-8); transitive ALLOW_ANY through `moveStockToNewDamagedContainer` (L-4).
- **Comment drift:** SBDEV-2033 in `transferStock` (M-2).

## 6. References

- `v2/wms2-api/src/main/java/net/aim_ai/wms/service/StockunitBusinessService.java:169-179,203-208,238,320-335,337,406-425` (#510). Overloads, lock sequence, available guard, FLA resolution, branch decision.
- `.../service/ReplenishmentOrderSourceSyncService.java:69-114`. Sync probe → lock → blocksMove → re-point.
- `.../service/ReplenishmentOrderMaintenanceService.java:82,152-200,263-311,905-976`. DI edge, cron loop, reassign, cancel/release, `shareOf`.
- `.../service/StockunitService.java:289,597,605,640-644,769,829,841,991-1027`. transferStock arms, SBDEV-2033 comment, setLockDamaged, 3622 cut.
- `.../service/UnitloadService.java:173-200`. Damage helper.
- `.../service/UnitloadBusinessService.java:235-237,521-538`. Tree PO lock, processTransfer UL save then sync.
- `.../service/mobile/MobileMoveUnitloadService.java:367,776`. UL FOR UPDATE at entry, 3747 stock-arm pre-check.
- `.../service/mobile/MobileReplenishService.java:212-330,853,907`. Finish lock order.
- `.../service/ReplenishmentMaintenanceTrigger.java`. Defer and de-duplicate semantics.
- `.../repo/jpa/ReplenishorderRepository.java:125-129,219-243`. Exported positive control, SDR search, id probe, holders projection.
- `src/main/resources/db/migration/V2.2.00__base_v2_schema.sql:3876`. Partial unique index.
- `src/test/resources/archunit_store/5fb3fee0-6caf-4f48-a5cd-5271da610572:38`, `src/test/resources/archunit.properties`.

---

## Round 2

**Snapshot reviewed:** the plan at r2 (599 lines, revision line *"r2: revised against ralplan-r1-architect.md … and ralplan-r1-critic.md …"*), checked against #510 @ c6f0cbc0, read with `git show`. I did not read `ralplan-r1-critic.md`.

**Verdict: APPROVE.** 0 High · 1 Medium · 6 Low.

All 14 round-1 findings are resolved; none is only nominally addressed. The new findings concern test feasibility and fixture precision, not design. All seven can be folded in at the TDD gate (§7.2 steps 1–6) without another planning round.

### R2.1: Round-1 findings, resolution check

| R1 | Resolved? | r2 text (quoted) |
|---|---|---|
| M-1 | **Yes** | §4: *"**UL vs order.** The Move Unit Load takes the **UL** … before any order. The replen finish takes order → SU → UL … That is a UL↔order ABBA, already present at N = 1. PostgreSQL detects it and returns 40P01."* §5 B.2: *"**Pre-check before any lock (Ar M-1).** If any **projected** state satisfies `blocksMove(Integer)`, take the first such id and `findById` it. Throw `replenBlockMessage(o)`"*. AC B2: *"`findByIdForUpdate` is never called"*. R6 is updated. |
| M-2 | **Yes** | §5 A.9 #10: *"**Amend the SBDEV-2033 comment** … to add: 'except when a damage move displaced an active holder (SBDEV-3755 D3), after commit …'"*. §5 A.8: *"`recalculateForItem` recalculates **every** PROCESSABLE order of the item, so a partially-cut order may grow back (3622 D-H1)."* |
| M-3 | **Yes** | §5 B "Fixture traps": *"Two active holders of one SU need **distinct `destination_id`** … Never 'fix' that by putting a holder at 700"* and *"Fix B ITs must enter through a BLOCK_REALIGN whole-UL move: `UnitloadBusinessService.transferUnitLoadToLocation(ul, dest, false, CODE_MANUAL_TRANSFER, …)`"*. B5: *"`IncorrectResultSizeDataAccessException` in the cause chain (asserted by type in the gate run)"*. B6: *"no other stock of the item anywhere"*. |
| M-4 | **Yes in intent.** Feasibility gap: R2-M1 | B8: *"poll `pg_stat_activity` until the second backend shows `wait_event_type = 'Lock'`, and fail if it never does within 10 s. 20 iterations, 3 connections … PROBE"* |
| M-5 | **Yes** | §6 lists `…SourceSyncServiceBranchTest:104,121,136`, `ReplenishmentOrderMaintenanceServiceUnitTest:2233` and `ReplenishmentIdProjectionContractUnitTest:93,158`. Default stub: *"`thenReturn(new TransferOutcome(stock, List.of()))`"*. §5 A.1: *"Production code never null-checks a `TransferOutcome`."* |
| L-1 | **Yes** (projection widening declined, acceptably) | §5 A.4: *"a candidate whose row is gone is treated as no holder … Never call `.get()`."* AC A8. |
| L-2 | **Yes** | §5 A.5: *"Holders are rendered as `NUMBER@state`, e.g. `REPL062966@500`"*. §5 A.10 and R4 name the residual. |
| L-3 | **Yes, within D4** | §5 C: *"add a javadoc warning … add an ArchUnit rule that `src/main` has no caller (AC B10)."* |
| L-4 | **Yes** | A13: *"(`ImportOption.DoNotIncludeTests`, `getAccessesToSelf()` on the 10-arg signature) … *Blind spots:* … transitive callers of the helper or of `setLockDamaged`"* |
| L-5 | **Yes** | A1: *"`clientRepository.findById` is never called (the first statement of the placeholder block)"*. A12's mutant: *"body moved but `.get()` kept"*. |
| L-6 | **Yes** | §5 A.2: *"*FLA drain-to-zero is excluded on purpose* … *R < 0 over-approximates*"* |
| L-7 | **Yes** | Scalability row 6: *"a refusal commits nothing in the caller's transaction. A caller's REQUIRES_NEW label draw may be burned (R8)"* |
| L-8 | **Yes** | §0: *"RTS `CancellationReversalService.completeReversal`"*. R2 updated. |
| L-9 | **Yes** | §5 A.8: *"`ReplenishmentMaintenanceTrigger.requestIfDisplaced(TransferOutcome outcome, Long itemdataId)` … One rule, one test (AC A19)."* |

### R2.2: Specific checks

**(a) B2 pre-check then B3/B4 under-lock re-check.**
- **Correct, and no new lock edge.** The pre-check is a projection plus a plain `findById`, with no `FOR UPDATE`.
- A present row always throws. The exception crosses `UnitloadBusinessService.transferUnitLoadToLocation`'s `@Transactional(value = "tenantTransactionManager", rollbackFor = {BusinessException.class, FacadeException.class})`, which marks the transaction rollback-only. So no lock read ever meets the entity that `findById` made managed.
- Absent rows are not managed, so step 3's `findByIdForUpdate` on them stays a first touch.
- That is the SBDEV-3244 F5 property, and `LockReadRail` (*"a lock read never meets a row the transaction already holds without its lock"*) would catch a regression in every Spring test context.
- One residual is acceptable but should be documented: see R2-L4.

**(b) Scaffold ordering (§7.2 step 1).**
- **Sound.** The 10-arg overload exists from step 1, so A13, A15–A18 and A19 go red on an assertion, not a compile error. A19 targets the no-op helper. A13 reports *"red after scaffold: 0 found"*.
- The SBS tests keep calling the 8-arg overload, which now delegates.
- `@Mock ReplenishorderRepository` is needed only from step 4, when the constructor gains the repository. Mockito's default empty `List` keeps the existing full-move tests green, and §6 lists all three classes.
- Two wording gaps: see R2-L6.

**(c) `verifyNoTransfer` and the bare-`never()` rail.**
- **The helper is feasible,** with one specification defect (R2-L1).
- **A20 is feasible** but can escape on shapes the existing rail has already met (R2-L2).
- Each overload has a different arity, so bare `any()` resolves the overload unambiguously. The helper itself sits under `src/test`, which means `NeverMatcherNullBlindnessArchTest` still scans its `verify(sbs, never())` spans. That is good: it polices the helper's matchers.

**(d) B7 redirect fixture.**
- **It reaches the code that matters, given one fixture precaution (R2-L3).**
- `redirectSource` does not call `shareOf` itself. It releases the **passed-in** share: `releaseHeld(order, currentSource, currentShare, WmsConstants.CODE_REPLENISHMENT_CANCELLED); // SBDEV-3618 Fix C` (`ReplenishmentOrderMaintenanceService.java`, in `redirectSource`).
- The value under test is therefore the per-order `shareOf` in the Fix B loop, which B7 exercises once both orders reach `REDIRECTED`. The r2 correction in §5 B.6 is accurate: *"A cancel does not consume the loop's `share`: `cancelOrder` recomputes it … A **redirect** does consume it"*.
- Trace with requests 3 and 5 and R = 8:

  | Path | REPL-5 share | REPL-9 share | Source reserved |
  |---|---|---|---|
  | Live (correct) | own = 8 − 5 = 3 → releases 3 | own = 5 − 0 = 5 → releases 5 | pre − 8 |
  | Snapshot mutant | 3 | reuses 3 → releases 3 | pre − 6 |

  B7 kills the snapshot mutant.
- A second variant survives, and correctly so: computing every order's share upfront, before any redirect, gives 3 and 5 (`others` = 3 for REPL-9). It is an **equivalent** mutant, because `held = min(requested, own)`, and own falls by exactly the amount released. Expect PIT to report it as a survivor. It is not a defect.

**(e) B8 `pg_stat_activity` proof.** The control is the right shape, but nothing tells the implementer where the first transaction pauses (R2-M1).

**(f) Callers stub an empty `TransferOutcome`; production never null-checks it.**
- **Safe in production.** The only producer is SBS's own `return new TransferOutcome(...)`, and the `@Transactional` proxy returns that value unchanged.
- **In tests,** a null comes only from an unstubbed mock and produces an NPE. That is loud, with two exceptions measured on #510:

  | Test class | `lenient()` count |
  |---|---|
  | `MobileReplenishServiceUnitTest` | 113 |
  | `StockunitServiceParcelSourceRefusalUnitTest` | 40 |
  | `StockunitServiceUnitTest` | 39 |
  | `PickingorderBusinessServiceUnitTest` | 20 |

  1. `lenient()` stubs disable STRICT_STUBS' unused-stub report (counts above), so an orphaned 8-arg stub goes unnoticed.
  2. `catch (Exception ignored)` swallows the NPE (`PickingorderBusinessServiceUnitTest` ~`:500`, *"catch (Exception ignored) { // Downstream … may not complete under unit mocks"*).

  In the `:500` case the following `verify(unitloadBusinessService).relocateEmptiedContainer(eq(pallet), …)` runs after the transfer, so it still goes red. At `:3502` the transfer is already unstubbed on base, so nothing changes. I found no false-green today. See R2-L5 for hardening.

### R2.3: New findings

**R2-M1 (Medium): B8 does not say where the first transaction pauses, so the positive control is likely to flake and be excluded.**
- **Evidence.** B8 says *"A latch, then **a positive control**: poll `pg_stat_activity` until the second backend shows `wait_event_type = 'Lock'` … If it is flaky in the gate run, tag it `timing-sensitive` (excluded under `-Pci`)"*.
- **Why it matters.** `adjustReservedAmount` is one service call that takes its holder and SU locks and commits within milliseconds. A latch before the call orders thread starts, not lock tenure, so the second backend is rarely seen waiting. The predictable outcome is "flaky → tagged → excluded", and AC-level evidence for move-vs-cut ordering would then rest on the unit InOrder tests B1/B4 alone.
- **Fix.**
  1. **Thread A** opens a `TransactionTemplate`, takes `replenishorderRepository.findByIdForUpdate(holder5)` (the same first lock the cut takes), and parks on a latch.
  2. **Thread B** runs the move.
  3. **The poller** identifies B by `pg_backend_pid()`, captured inside B's transaction, or by `SET application_name`. It waits for B's `wait_event_type = 'Lock'`.
  4. **Release A,** which then calls the real `adjustReservedAmount` **inside the same transaction**. Its re-lock of 5 is a no-op on its own row; it then locks 9, then the SU.
- **What this buys.**
  - Contention becomes deterministic, and the PROBE can stay in `-Pci`.
  - It makes the stated mutant observable: with descending order, B holds 9 and waits on 5, A wants 9, and the result is 40P01.
  - The base-red claim also holds: on c6f0cbc0, B's probe throws without waiting, so the control fails.

**R2-L1 (Low): `verifyNoTransfer` as specified would fail the existing null-blindness rail.**
- §6 says the helper uses *"`anyBoolean()` and `any(ReplenHoldPolicy.class)`"*.
- `NeverMatcherNullBlindnessArchTest` flags `any(Foo.class)` inside `verify(…, never())`: *"`any(Foo.class)` too, which has been null-excluding since Mockito 2. Only bare `any()` and `nullable(...)` match null."*
- **Fix.**
  - Use bare `any()` (or `nullable(...)`) for every reference parameter: `orderNumber`/`comment` are often null, and BOL/club pass a nullable FLA. Use `anyBoolean()` only on the two primitives.
  - Add a three-case self-test for the helper: call each overload on a mock with nulls in every reference slot, and assert the helper throws `NeverWantedButInvoked`. That is the positive control showing the helper is not vacuous.
- Severity is Low because step 1 fails loudly on the rail.

**R2-L2 (Low): A20's text rail has to handle the shapes that once slipped past the existing rail.**
- A20 bans `never()).transferStockToUnitLoad(` outside `TransferVerifications`.
- The existing rail documents two earlier silent-escape forms: *"`never ()` … triple-silent"* and *"`verify(mock, never().description(\"...\")).method(...)` — 18 sites in 6 classes"*.
- **Fix.** Reuse that rail's paren lexer and `NEVER_VERIFY` pattern rather than a literal string. Add one planted-offender self-test per shape. Add a floor: at least 19 `verifyNoTransfer(` call sites in `src/test`, so a mass revert to `verifyNoInteractions` or a deletion cannot pass silently.

**R2-L3 (Low): B7 should not depend on flush timing, and it should assert that the redirect actually happened.**
- `getAvailableReplenishmentSources` filters with `su.amount > su.reservedamount`, the lane flags and `area.useforreplenish = true`. The moved SU S drops out only if `processTransfer`'s UL relocation has been flushed before that native query.
- If S were chosen, the move path returns `NO_CANDIDATE` (*"if (!recalcPath) { return RedirectOutcome.NO_CANDIDATE; }"*) and B7 silently becomes a cancel test. C's +8 would catch that, but only by its absence.
- **Fix.**
  - Seed S with `amount == reservedamount` (= 8), so S is never a candidate.
  - Assert both orders' `stockunitId == C`.
  - Seed C clear of `MANUAL_CUT_COOLDOWN_EXCLUSION` and on an area with `useforreplenish` and no lane flags.
  - Note the equivalent upfront-share mutant from R2.2(d) in `fix1-review-code.md`, so it is not "repaired".

**R2-L4 (Low): the B2 pre-check can refuse on a stale projection, and that must not be "fixed" by falling through.**
- Between the projection read and `findById`, the holder may have been reset to 300, finished, or redirected (READ COMMITTED). B2 still throws an "in progress" refusal. The operator retries and succeeds. That is harmless.
- The tempting fix is to re-check the loaded row and fall through. That would leave a **managed** order which step 3 then locks: exactly the version-checked upgrade (`StaleObjectStateException`) that F5 and `LockReadRail` exist to stop.
- **Fix.** Javadoc on the pre-check: *"refusal is on the projected state by design; a present row always throws; do not fall through after a present `findById`"*. Fix A's REFUSE path already has the same correct shape (present → throw).

**R2-L5 (Low): make the non-null `TransferOutcome` contract explicit, and migrate lenient stubs deliberately.**
- Add a compact constructor: `Objects.requireNonNull(stock); displacedHolders = List.copyOf(displacedHolders);`. This turns the "never null" rule into a property of the type, not just of review.
- At step 5, grep the four caller test classes for `lenient().when(stockunitBusinessService.transferStockToUnitLoad(` with 8 or 9 arguments, and convert each one explicitly, because strictness will not report those.

**R2-L6 (Low): §7.2 wording does not match the AC table, and the stub-migration step is not named.**
- Step 4 says *"ACs A1–A14 red"*, but the table marks A3–A5 and A12 as CTRL and A13–A14 as RAIL. Say "RED rows red, CTRL rows green then killed by their mutant, RAIL rows added".
- §6's *"Stubs and verifies on an opt-in path → the policy overload"* has no step. It must happen in **step 5**, together with the caller switch. Done in step 1, the stubs would not match the callers that still use the 8-arg overload, and the scaffold baseline would not hold.

### R2.4: Declined items: should any be reopened?

No. Each decline has a stated reason that I accept.

| Item | Accepted because |
|---|---|
| L-1 projection widening | Changing the 3622 contract-test shape is real cost, and the vanished-row fallback closes the actual risk |
| L-3 full deletion | Scoped out by D4. Javadoc plus the B10 rail is an adequate substitute |
| Steelman caller-side guard | Rebutted on TOCTOU and default-safety grounds |
| T-3 Spring event | Rejected for hiding the opt-in's consequence |
| Refuse-on-drift (Choice 2B) | Correctly rejected: it does not close the insert-after-probe residual |

### Round 2 summary

**APPROVE.** 0 High / 1 Medium (R2-M1) / 6 Low (R2-L1…L6).

Round 1 is fully resolved. The new findings are test-mechanics precision and can be folded in at the TDD gate without re-planning. R2-M1 should be settled **before** B8 is written, or B8 will end up excluded from CI.
