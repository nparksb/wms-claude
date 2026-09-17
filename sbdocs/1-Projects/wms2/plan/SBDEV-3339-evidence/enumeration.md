# SBDEV-3339 — §0 Affected-Sites Enumeration

**Repo:** `v2/wms2-api` · **Graded ref:** `origin/develop` @ `221caed1` (fetched 2026-09-14)
**⚠ The local checkout `/home/nampark/dev/wms-claude/v2/wms2-api` is 35 commits behind.** Every claim below
was derived with `git show origin/develop:<path>` / `git grep <pat> origin/develop`. Nothing was read from a
working tree.

**Lane:** pre-draft enumeration only. No production code was written.
**Companion:** [db-evidence.md](./db-evidence.md) (same ticket, DB lane).

---

## 1. The complete cancel-path inventory

### 1.1 Deriving method and its blind spots

**Deriving method (D1):** `git grep -n "State.CANCELED" origin/develop -- 'src/main/**/*.java'` (74 hits),
then hand-filtered to the hits whose assignment target is a `Customerorder`. Widened from the brief's
`setState(WmsConstants.State.CANCELED)` because the literal form misses `setState(allCanceled ? CANCELED : FINISHED)`
(`PickingorderBusinessService:586`) and `int orderState = WmsConstants.State.CANCELED` (`:159`) — both real
writes through a variable.

**Blind spots of D1, each probed separately:**

| Blind spot | Probe | Result |
|---|---|---|
| Bulk `@Modifying` UPDATE writing state 800 | `git grep -n -A8 "@Modifying"` over all 24 `src/main` files that contain it | **One candidate found** — see §1.3. The brief was right that `setState` cannot see it. |
| A numeric literal `800` instead of the constant | `git grep -n "setState(800)\|= 800" origin/develop -- 'src/main/**/*.java'` | only the two `!= 800` guards inside the JPQL strings at `CustomerorderRepository:167` and `CustomerorderPositionRepository:118`. No literal write. |
| Native SQL touching `customerorder.state` | `git grep -n -i "UPDATE customerorder" origin/develop -- 'src/main/**/*.java'` | none |
| Scheduled job path | all five writers below traced to their callers; the only job-adjacent one is `UtilRestController.resetOrdersInReleasedStatus` — see §1.2 row 3a |
| **Flyway / DB triggers** | **NOT PROBED.** A migration or trigger writing state 800 is outside what any `src/main` grep can see. Stated, not resolved. |

**Positive control for the `@Modifying` scan:** the first run (`@Modifying` + 6 lines, filtered on `update|state|800|CANCELED`)
returned **zero**. A zero-scan needs a control, so I re-ran the locator alone: `git grep -l "@Modifying" origin/develop -- 'src/main/**/*.java' | wc -l` → **24 files**.
The instrument was working; the filter was too narrow (the annotation and the `@Query` are separated by
`@Transactional` + a `@RestResource` + comment block, often >6 lines). The widened re-run (`-A8`, per-file
`git show | grep -A8`) found the real hits. **The original zero was a false zero.**

### 1.2 The inventory

Five `src/main` constructs can leave a `Customerorder` at `state = CANCELED` (800). Columns are
yes/no **for the tote the order was picking into**, not for a parcel.

| # | Writer (file:line on `origin/develop`) | Entry point → HTTP route | clears stock `entity_lock` | nulls `pickingtote_id` | `sendToClearing`/`sendToNirvana` on tote | cancels pick lines | notifies OMS |
|---|---|---|---|---|---|---|---|
| **1** | `CustomerorderService:442` — `forceCancelOrder`, `state < PACKED` branch | not routed directly; reached from #3 | **yes** (tote **and** its stock — the only writer that does both) | **yes** | **yes** — `sendToClearing` | **yes** | via #3's caller |
| **2** | `CustomerorderService:480` — `forceCancelOrder`, `PACKED`/`PALLETIZED` branch | same | **yes**, but on the **parcel**, not the tote | n/a (parcel path) | **yes** — `sendToClearing(parcel, …)` | positions only | via #3's caller |
| **3** | `CustomerorderService:821` — `cancelOrder` **success branch** | `POST /rest/order/cancelPositions` → `OrderRestController:570` | **NO** | **NO** | **NO** | yes, via `customerorderPositionService.cancelOrderPosition` (`:818`) | yes — outbox `ORDER_BATCH_CANCELLED_FROM_WMS` (`:862`) | 
| **3a** | same writer, second caller | `UtilRestController:1089` `resetOrdersInReleasedStatus` — **NOT an HTTP route**, see §1.4 | — | — | — | — | — |
| **4** | `PickingorderBusinessService:617` — `cleanUpCancelledOrder` | reached from `CustomerorderService:881` (deferred-cancel branch) and `PickingorderBusinessService:270` (`finishPickingOrder`, `markedforcancellation`) | **stock only** — **NOT the tote's own** `entity_lock` | **yes** (`:611`) | **yes** — `sendToClearing` (`:604`) | **yes** — `cancelOpenPickLines` (`:625`) | yes — outbox (`:634-646`) |
| **5** | `CustomerorderBatchService:463` — `cancelBatch` | **no `src/main` caller** — see §1.4 | **NO** | **yes** (`:513`) | **NO** | **yes** (`:488`, incl. reservation release) | yes — outbox (`:451`) |

**Rapid-pick sub-branch of #3** (`CustomerorderService:790-806`, guarded by
`section RAPID_PICKING && state == ASSIGNED && historytote != null && pickingOrder.state == STARTED`):
this *does* `sendToNirvana` + null `pickingtote_id` — but it **refuses to run on a tote with stock**:

> `if (!stockUnits.isEmpty() || !unitLoads.isEmpty()) { throw new BusinessException("tote=" + pickingTote.getLabelid() + " not empty"); }`

So it is not a second teardown implementation; it is an empty-tote retire. It cannot reach the
7 stranded rows (which are, by definition, stock **on** a tote).

### 1.3 The `@Modifying` blind spot — the one real candidate

`CustomerorderRepository.java:166-168`:

> ```java
> @RestResource(exported = false)
> @Modifying
> @Query("UPDATE Customerorder c SET c.state = :state WHERE c.id IN :ids AND c.state != 800")
> int updateStateByIds(@Param("ids") List<Long> ids, @Param("state") int state);
> ```

`:state` is caller-supplied, so this construct **can** write 800 and is invisible to D1.
**It does not, today.** Deriving method: `git grep -n "updateStateByIds" origin/develop -- 'src/main/**/*.java'`
→ exactly one caller, `CustomerorderBatchService:975`, which passes `WmsConstants.State.PACKED`.
Blind spot of *that* grep: an HTTP caller reaching it as a Spring Data REST search — closed by
`@RestResource(exported = false)` on the line above (landed under SBDEV-3183).
Its sibling `CustomerorderPositionRepository.updateStateByOrderIds:117-119` is identical in shape and has
the same single caller (`:976`, also `PACKED`). **In scope: no. Worth one sentence in the plan's
"why a `setState` grep is not the whole inventory" note: yes.**

### 1.4 Two reachability corrections the plan must carry

1. **`UtilRestController` is `@Service`, not `@RestController`** (`origin/develop:…/rest/UtilRestController.java:23-24`).
   Its `@RequestMapping("/resetOrdersInReleasedStatus")` at `:1081` **does not route**. The method has
   zero `src/main` callers (`git grep -n "resetOrdersInReleasedStatus"` → the declaration plus five
   `UtilRestControllerUnitTest` call sites, nothing else). Row 3a is therefore **test-only reachable**.
   → The single live HTTP entry point into the defect is **`POST /rest/order/cancelPositions`**.
2. **`cancelBatch` has no production caller.** `git grep -n "cancelBatch" origin/develop` (whole tree, not just
   `src/main`) returns: the declaration at `CustomerorderBatchService:398`; 4 `docs/plan/**` files; and
   **only test call sites** (`CustomerorderBatchServiceUnitTest` ×13, `CustomerorderBatchOutboxIntegrationTest` ×4,
   `CancelOrderRollbackIntegrationTest` ×1). `docs/plan/completed/WMS_Staging_Lane_Bug_Fix_Plan.md:324` says so
   outright: *"`cancelBatch()` has no callers; wiring it to a controller is a separate enhancement."*
   → It carries the **same defect**, but with **zero production exposure**. That is what makes it a
   fix-the-invariant candidate rather than a second user-facing bug.

### 1.5 The divergence the brief's framing understates

The brief says the two siblings "both do all three". They do not do the *same* three:

| | tote's own `entity_lock` | tote's stock `entity_lock` | `pickingtote_id` | tote relocated |
|---|---|---|---|---|
| `forceCancelOrder` (#1) | **cleared** (`:463`) | cleared (`:466`) | nulled (`:461`) | `sendToClearing` (`:469`) |
| `cleanUpCancelledOrder` (#4) | **not touched** | cleared (`:612`) | nulled (`:611`) | `sendToClearing` (`:604`) |
| `cancelOrder` (#3) | not touched | **not touched** | **not touched** | **not touched** |

`sendToClearing` does **not** clear a lock — it is three lines and delegates to
`transferUnitLoadToLocation`:

> `UnitloadBusinessService.java:603-607` — `Location clearingLocation = …findByName(STORAGE_LOCATION_CLEARING)…; transferUnitLoadToLocation(unitload, clearingLocation, true, activityCode, comment, orderNumber);`

So "call `sendToClearing`" and "clear the lock" are genuinely independent obligations; #3 omits both.
Whether #1's extra tote-level clear matters is a **separate, answerable question**: no `src/main` site
ever sets a `Unitload`'s `entity_lock` to `PICKED_FOR_GOODSOUT` (see §2.2), so a picking tote's own
`entity_lock` is normally 0 and #1's line is defensive. **The plan should pick #4's shape, not #1's,
and say why** — otherwise a reviewer will read the missing tote-level clear as a new omission.

### 1.6 Also missing from #3, found while enumerating

`cancelOrder`'s success branch never sets `historytote`. Both siblings do
(`CustomerorderService:460`, `PickingorderBusinessService:610`). On the 2 stranded PRD orders `historytote`
*is* populated — but [db-evidence.md §3](./db-evidence.md) establishes that came from
`MobilePickingService` at tote **assignment**, not from teardown. So this is a genuine third omission in #3,
not a fourth symptom of the same one. Low blast radius; name it so the fix is complete.

---

## 2. Adjacent instances of the same root-cause pattern

Pattern under test: *a terminal-state transition that abandons a container without releasing the lock its stock carries.*

### 2.1 `PICKED_FOR_GOODSOUT` (100) — producers

**Deriving method:** `git grep -n "PICKED_FOR_GOODSOUT" origin/develop -- 'src/main/**/*.java'` → 14 hits;
filtered to assignment (`setEntityLock(...PICKED_FOR_GOODSOUT)`) → **2**, of which one is a restore.

| Site | Role |
|---|---|
| `PickingorderBusinessService:876` — `pickToStock.setEntityLock(WmsConstants.BusinessObjectLockState.PICKED_FOR_GOODSOUT);` inside `confirmPick` | **the only producer.** The brief's "set in exactly one place" is correct for the production sense. |
| `CancellationReversalService:407` — `residue.setEntityLock(…PICKED_FOR_GOODSOUT)` | **re-**lock of a partial-reversal residue (landed under SBDEV-3326). Restores a lock this class itself just cleared; not an independent producer. |

**Blind spot, probed:** a bulk/native write to `entity_lock` is invisible to a `setEntityLock` grep, exactly as
for `setState`. `git grep -n -i "entity_lock" origin/develop -- 'src/main/**/*.java'` surfaces
**`BillofladingService:1599-1605`**, two `entityManager.createQuery("UPDATE Stockunit s SET s.entityLock = :lock …")`
statements. They write `SHIPPED`, not `PICKED_FOR_GOODSOUT` — so the producer count survives — but they prove the
blind spot is real in this codebase and not hypothetical. `SHIPPED` (405) is **never** written by a
`setEntityLock` call anywhere in `src/main`; it reaches the DB only through those two bulk statements plus
`BillofladingService:406`. Any future "who locks this stock" sweep that greps only `setEntityLock` will
miss 100% of the SHIPPED population — which is 328 of 804 rows on Hydra PRD.

### 2.2 `PICKED_FOR_GOODSOUT` — consumers that must later clear it

| Consumer | Clears? | Same root cause as 3339? |
|---|---|---|
| `CustomerorderService:466` — `forceCancelOrder` | yes | n/a — this is the correct sibling |
| `PickingorderBusinessService:612` — `cleanUpCancelledOrder` | yes | n/a — correct sibling |
| `CancellationReversalService:350` | yes (SBDEV-3326) | n/a — correct |
| `BillofladingService:1599/1605` — ship | **overwrites** 100 → 405 | **no.** The goods left the building; 405 is the right terminal lock, not a leak. |
| `StockunitService.removeLock` (`:707-727`) — the operator's manual escape hatch | **refuses.** `OPERATOR_REMOVABLE = { QUALITY_FAULT, ON_HOLD }` (`WmsConstants:1516`) — 100 is not in it, so the `default:` arm throws *"Can't remove lock: this stock unit is Picked. Only Quality Fault or On Hold locks can be removed here."* | **This is what converts 3339 from an untidy row into a stuck one.** There is no operator path out. Not a separate defect — it is the reason the defect has no workaround. `CancellationReversalService:288` already records this in a javadoc. |
| `CustomerorderService.packageOrder` (happy path) | n/a — no clear needed | **no.** `transferStockToUnitLoad` mints the destination via `createStockUnitCore`, which sets `NOT_LOCKED` unconditionally (`StockunitBusinessService:133-134`); the source is retired at `GOING_TO_DELETE` (`:414`). The lock is not propagated, so the happy path leaves no residue. The one site that *does* propagate a lock copies it explicitly (`StockunitService:345`). |
| **`CustomerorderBatchService:463` — `cancelBatch`** | **NO** | **YES — identical root cause, strictly worse shape.** It nulls `pickingtote_id` (`:513`) and cancels the `pickingorder_unitload` row (`:502`) but never clears the stock lock and never relocates the tote. So it severs the only link from the cancelled order to the locked stock **and** leaves the lock — where #3 at least leaves `pickingtote_id` populated, which is precisely what made the PRD rows diagnosable. Mitigated only by §1.4's zero production callers. |

### 2.3 Other terminal transitions near container handling — checked, NOT same root cause

| Site | Verdict |
|---|---|
| `MobilePickingService:323` — `pickingOrder.setState(CANCELED)` in the picking-order reset | **no.** Writes `Pickingorder`, not `Customerorder`; no container is abandoned — it is a reset that leaves the tote attached and live. |
| `PickingOrderMergeService:127` — `pickingOrder.setState(CANCELED)` on merge | **no.** The merge re-parents the pick lines; the tote follows the surviving picking order. |
| `PickingorderBusinessService:159/396` — `finishPickingOrder`'s `orderState` seed | **no.** `Pickingorder` only; `:396` is the settle, and the tote is moved by the same method. |
| `ReplenishorderService:270`, `ReplenishmentOrderMaintenanceService:637` | **no.** `Replenishorder` has no tote. `ReplenishmentOrderMaintenanceService.cancelOrder(order, source, …)` releases the *reservation* on `source`, which is the analogous obligation and it is discharged. |
| `CustomerorderPositionService:167` — `cancelOrderPosition` | **no, and deliberately so.** Per-position; the tote is an order-level resource. Cancelling the last position must not tear down a tote the order still owns. The obligation correctly belongs to the order-level caller — which is exactly the caller that drops it. |

---

## 3. Test surface

### 3.1 The mock-strictness premise in the brief is **false for two of the three classes**

| Class | Declared strictness (`origin/develop`) |
|---|---|
| `CustomerorderServiceUnitTest` | **`@MockitoSettings(strictness = Strictness.LENIENT)`** (`:59`) |
| `PickingorderBusinessServiceUnitTest` | `@MockitoSettings(strictness = Strictness.STRICT_STUBS)` (`:90`) |
| `CustomerorderPositionServiceUnitTest` | no `@MockitoSettings` at all → JUnit5 Mockito default (`STRICT_STUBS`) |
| `CustomerorderBatchServiceUnitTest` (needed for §2.2) | **`LENIENT`** (`:38`); `:1980` even annotates the consequence — *"⚠ This class is `@MockitoSettings(LENIENT)`, so an unexercised stub does NOT fail the test."* |

**Consequence for the TDD gate.** The class that owns the fix, `CustomerorderServiceUnitTest`, is LENIENT.
So the brief's stated risk — *"an unstubbed `sendToClearing` may throw"* — does not apply, and it would not
have applied under STRICT_STUBS either: `sendToClearing` is `void`, and an unstubbed `void` on a Mockito mock
is a no-op. STRICT_STUBS fails on *unnecessary stubbing* and on argument mismatch, never on an unstubbed void call.

**The real breakage vector is different, and it is not about strictness at all:**
`unitloadRepository.findById(customerOrder.getPickingtoteId())` returns `Optional.empty()` from an
unstubbed mock, and both siblings follow it with `.orElseThrow(() -> new EntityNotFoundException(…))`.
Any existing `cancelOrder` success-path test whose fixture has a **non-null** `pickingtoteId` would go red
with `EntityNotFoundException` the moment the fix adds that lookup. **Measured: that set is empty.**
`createTestCustomerorder` (`CustomerorderServiceUnitTest:198-216`) never calls `setPickingtoteId`, and the
two tests in `CancelOrderSuccessPaths` (`:1203-1267`) do not set it either — so `getPickingtoteId()` is
`null` and a guarded fix short-circuits. Every `testOrder.setPickingtoteId(50L)` in the file
(`:1088, :1101, :1918, :1985, :2043, :2161, :2235, :2292, :2348, :2361, :2715, :3032`) sits in
`packageOrder`, `cleanUpCancelledOrder`-delegation or rapid-picking nests — none reaches the general
success branch. **The fix as specified breaks no existing test in this class.** That is a finding the gate
needs: it means a new test must *create* the tote fixture, and it means a green suite after the fix
proves nothing on its own.

### 3.2 Does any existing test assert tote teardown or `entity_lock` after cancel?

**Deriving method:** per-class `git show origin/develop:<f> | grep -n "EntityLock\|sendToClearing\|sendToNirvana\|[Pp]ickingtote"`.

| Class | Verdict |
|---|---|
| `CustomerorderServiceUnitTest` | **No test asserts `entity_lock` after a cancel.** The only `EntityLock` lines are **fixture setup** (`:1332`, `:2843` `parcel.setEntityLock(NOT_LOCKED)`; `:2901`, `:2928` `parcel.setEntityLock(0)` with the comment *"// not shipped"*) — they configure the `isShippedOrPastCancellationBoundary` guard, they assert nothing. Teardown assertions exist only for the **rapid-pick sub-branch**: `shouldHandleRapidPickingCancellationWithEmptyTote` (`:2158`) — `assertThat(testOrder.getPickingtoteId()).isNull()` (`:2224`) + `verify(unitloadBusinessService).sendToNirvana(eq(pickingTote), …)` (`:2227`); and `shouldSkipRapidPickingCleanupWhenPickingOrderNotStarted` (`:2288`) — `verify(…, never()).sendToNirvana(…)` (`:2336`). Both are `sendToNirvana`, neither touches a lock. |
| `CustomerorderPositionServiceUnitTest` | **Zero hits.** *Positive control:* the file is 603 lines and `grep -c "cancelOrderPosition"` → **25**, so the instrument reads the file and the method is under test — the absence is real, and correct per §2.3 (position-level cancel owes no tote teardown). |
| `PickingorderBusinessServiceUnitTest` | **The only class with a real lock assertion, and it is the model for the new test.** At `:1547-1591`: fixture `stockUnit1.setEntityLock(PICKED_FOR_GOODSOUT)` (`:1556`) / `stockUnit2.setEntityLock(ON_HOLD)` (`:1560`), then `verify(unitloadBusinessService).sendToClearing(eq(tote), …)` (`:1588`) and `assertThat(stockUnit1.getEntityLock()).isEqualTo(NOT_LOCKED)` (`:1590`), `stockUnit2` likewise (`:1591`). Also `:451-475` (`sendToClearing` + `assertThat(customerOrder.getPickingtoteId()).isNull()`), `:487-518` (null-tote guard, `verify(…, never()).sendToClearing(…)`), `:2178` `cleanUpCancelledOrder_NullPickingtoteId_SucceedsAndPreservesCancellationFlow`. |

**Note on `stockUnit2` (`ON_HOLD` → asserted `NOT_LOCKED`):** `cleanUpCancelledOrder:612` is an
unconditional `forEach(su -> su.setEntityLock(NOT_LOCKED))`, so it clears an operator's `ON_HOLD` too.
Whether the 3339 fix should copy that breadth or narrow to `PICKED_FOR_GOODSOUT` is a **design question
for the plan, not a finding** — but it must be decided explicitly, because `CancellationReversalService:259`
made the opposite choice on the reversal path (it refuses to clear a lock other than `PICKED_FOR_GOODSOUT`:
*"entitled to clear. PICKED_FOR_GOODSOUT is the one the reversal itself invalidates"*). Two live paths, two
policies. Do not let the TDD gate pick one by accident.

### 3.3 What the gate must therefore write

1. A `cancelOrder` success-path test with a **non-null** `pickingtoteId` and a tote carrying
   `PICKED_FOR_GOODSOUT` stock — no such fixture exists anywhere in `CustomerorderServiceUnitTest`.
2. Its mutation check: the assertion must go red when the three new calls are removed individually,
   not only all together (three omissions, three mutants).
3. A negative control mirroring `:487-518`: null `pickingtoteId` → `verify(…, never()).sendToClearing(…)`.
   Without it the fix can regress into an unguarded `findById(null)`, which throws
   `IllegalArgumentException` before returning `Optional` — the exact SBDEV-2102 trap that
   `CustomerorderService:455-458` carries a comment about.
4. If `cancelBatch` (§2.2) is taken in scope, note that `CustomerorderBatchServiceUnitTest` is LENIENT:
   a stub added there and never exercised will **not** fail, so a new assertion there needs its mutation
   check even more than usual.

---

## 4. Cross-reference — prior plans touching these symbols

**Deriving method:** `grep -rln "cancelOrder\|cleanUpCancelledOrder\|PICKED_FOR_GOODSOUT" sbdocs/1-Projects/ sbdocs/4-Archieves/`
→ 77 files. *Positive control:* `grep -rln "SBDEV" sbdocs/1-Projects/ | wc -l` → 216, so the recursive grep
is reading the tree. Blind spot: matches `cancelOrder` as a substring, so `ReplenishmentOrderMaintenanceService.cancelOrder`
(a different method) inflates the count. Ranked below by actual bearing, not by hit.

### 4.1 Direct predecessors — read before drafting

| Plan | Bearing |
|---|---|
| `4-Archieves/wms2/plan/260424-phase7-cancel-orchestrator-plan.md` | **The closest prior art.** Contains a four-column comparison table — *"Aspect \| cancelOrder \| cancelBatch \| forceCancelOrder \| cleanUpCancelledOrder"* — i.e. somebody already built this exact matrix. Also files **B3**: *"`cancelBatch()` uses `zeroIfNegative=false` … instead of clamping to zero like `cancelOrder()`"*. **Archived without the tote column being filled in.** Read it first; do not re-derive its table from scratch. |
| `4-Archieves/wms2/plan/SBDEV-1921-order-cancellation-reversal-workflow.md` | The reversal workflow that exists *because* cancels strand stock. 3339 reduces the population that workflow has to clean up — check for an AC that assumes the stranding. |
| `4-Archieves/wms2/plan/SBDEV-2102-putaway-unit-load-not-found-stuck.md` | Source of the null-`pickingtoteId` guards at `CustomerorderService:455`, `:788` and `PickingorderBusinessService:601`. **Any new tote block must carry the same guard** or it re-opens SBDEV-2102. |
| `4-Archieves/wms2/plan/260629-transfer-lane-leak-on-cancel.md` | Precedent for *"add the missing release to both cancel branches"* — structurally the same fix on a different resource. Its shape (guarded direct clear in `cancelOrder` **and** `forceCancelOrder`) is the shape 3339 should follow. |
| `4-Archieves/wms2/plan/260320-Auto_Release_Club_Transfer_Lane_Fix.md` | Only `docs/plan/partial/` in-repo; its Fix #7 *"Make `cancelBatch()` cancel all child entities (Critical)"* was **partially** landed — the child-entity loop exists on develop, the lock release does not. §2.2's finding is the unfinished half of that fix. |
| `1-Projects/wms2/plan/SBDEV-3244-concurrent-recalculate-stale-version-under-lock.md` | **Active, uncommitted** (`git status` shows it `M`). Coordinate only — no symbol overlap found. |

### 4.2 Supersession / coordination

- **No plan document exists for SBDEV-3326, 3316, 3319 or 3313.** `grep -rln "SBDEV-3326\|SBDEV-3316\|SBDEV-3319\|SBDEV-3313" sbdocs/1-Projects/ sbdocs/4-Archieves/`
  returns only two files, both inside `SBDEV-3320-evidence/`. All four landed sub-T3 (on-ticket), and
  `git log origin/develop --grep` confirms they are merged (`#345`, `#348`, `#349` + `ddecbbaf`).
  **Their design record lives only in source javadoc.** The three that bear on 3339:
  - **SBDEV-3326** (`0bedae4a`…`1bf43fe1`, PR #345→#349) — *"RTS reversal clears PICKED_FOR_GOODSOUT so the stock can move."*
    Same lock, opposite direction. Its `CancellationReversalService:251-259` comment is the authority on
    *which* locks a cleanup is entitled to clear (§3.2 note). **Do not contradict it.**
  - **SBDEV-3319** (`b7acb52f`…`b9447cc6`, PR #348) — added `cancelOpenPickLines` to `cleanUpCancelledOrder`
    and **split the cancel lifecycle out to SBDEV-3332**. `CustomerorderService:872-895` carries a 20-line
    comment explaining why the `markedforcancellation` path was deliberately left alone. **3339 must not
    re-open that branch** — it is 3332's, by an explicit prior decision.
  - **SBDEV-3316** (`577eb830`, `d2ed6a48`, PR #345) — left an **ordering constraint** at
    `PickingorderBusinessService:648-662`: *"⚠ THIS BLOCK MUST STAY BELOW THE recordCancellation LOOP ABOVE"*,
    pinned by `PickingorderBusinessServiceUnitTest$Sbdev3316_CancellationLogOrdering` with `InOrder`.
    If 3339 makes `cancelOrder` call into shared teardown code, **that ordering pin must be preserved.**
- **SBDEV-3332** owns the `markedforcancellation` lifecycle. Adjacent, not overlapping. Name it in §5.1 as
  a non-blocking neighbour.

---

## 5. Docs — what confirms, and what is now FALSE

### 5.1 `3-Resources/workflows/wms2-cancel-cascade-workflow.md` (`last_verified: 2026-05-08`)

**Confirms the framing, by omission.** §3's cascade tree for `cancelOrder` lists four entities —
`Customerorder`, `CustomerorderPosition`, `Pickingorder`, `PickingorderUnitload` — and **the picking tote
appears nowhere in it.** The doc has never claimed `cancelOrder` tears the tote down. 3339 is a genuine
gap, not a regression.

**FALSE claims in that doc, verified against `origin/develop` @ `221caed1`:**

| # | Doc claim | Reality |
|---|---|---|
| D-1 | §5, `cancelBatch` pseudocode: *"for each Unitload / Stockunit locked by the batch: **release entity locks (so stock is returnable)**"* | **FALSE, and it is the §2.2 defect.** `cancelBatch` (`:398-530`) contains **zero** `setEntityLock` calls. Deriving method: `git grep -n "setEntityLock(" origin/develop -- 'src/main/**/*.java'` — 90 hits across `src/main`, **none** in `CustomerorderBatchService`. This doc line is the single most dangerous thing in the vault for this ticket: it tells a reader the batch path is already correct. |
| D-2 | §2 entry-point table: *"`CustomerorderBatchService.cancelBatch(...)` … Trigger: REST `/clubLine/...` + admin"* | **FALSE.** Zero `src/main` callers (§1.4). Not reachable by any route. |
| D-3 | §9 item 2: *"[forceCancelOrder] Always writes `Customerorder.state = CANCELED` regardless of prior state"* | **FALSE.** Two guarded branches only — `state < PACKED` (`:414`) and `== PACKED \|\| == PALLETIZED` (`:472`). `PACKED = 650`, `PALLETIZED = 670`, `FINISHED = 700` (`WmsConstants:108,113,123`), so an order at e.g. `LOADED_TO_TRUCK` falls through both and is **not** cancelled — it reaches the final `customerorderRepository.save` unchanged. |
| D-4 | §9 item 3: *"Writes `Pickingorder.state = PICKED` (line 356) — a deliberately unusual choice"* | **Conditional, not unconditional.** `:447-450` — only `if (poPositions.stream().allMatch(p -> p.getState() >= FINISHED))`. Landmine §10 item 7 repeats the absolute form and inherits the error. |
| D-5 | §9 item 4: *"Does **not** unwind the `PickingorderUnitload` cascade the way `cancelOrder` does"* | **Inverted.** `forceCancelOrder` does more tote work than `cancelOrder`, not less (§1.5). `cancelOrder` unwinds `PickingorderUnitload` **only** inside the rapid-pick sub-branch (`:796`). |
| D-6 | §7 code block: `if (order.getState() == ASSIGNED && order.getHistorytote() != null) { handleRapidPickingForCancelledOrder(order); }` | **The method does not exist** and the guard is under-stated — the real guard also requires `section.getSectionpickingtype() == RAPID_PICKING` **and** `pickingOrder.getState() == STARTED` (`:783-789`). The state-machine catalog §5.1 already flagged the method name on 2026-08-06; this doc was not updated. |
| D-7 | Every `file:line` in §2, §3, §4 | Stale by ~130 lines. `cancelOrder` is cited at `:588`; it is at **`:722`**. `forceCancelOrder` cited at `:323`; it is at **`:407`**. The doc's own §12 log admits a partial drift in the 2026-06-29 entry and left `last_verified` at 2026-05-08 — but did not correct the body. |
| D-8 | §12: *"Re-verify every 60 days. Next due: 2026-07-07"* | **69 days overdue** as of 2026-09-14. Four merged tickets (3316/3319/3326/3332-split) have landed in `CustomerorderService`/`PickingorderBusinessService` since. |

### 5.2 `3-Resources/architecture/wms2-state-machine-catalog.md`

**It does not document stock lock states at all.**
`grep -n -i "entity_lock\|entityLock\|BusinessObjectLock\|PICKED_FOR_GOODSOUT" …` → **zero hits**.
*Positive control:* `grep -n "^#"` on the same file returns 29 headings, so the file is being read.
§4.11 is titled *"Entities with NO state field"*; `Stockunit` and `Unitload` are state-less in the
`WmsConstants.State` sense, so they fall outside the catalog's declared scope — **the omission is
by-design, not drift.** But it means **the brief's request for "stock lock states" cannot be answered
from this doc**, and `BusinessObjectLockState` is documented nowhere in `sbdocs/`. The authoritative
source is `WmsConstants:1444-1494` (8 constants) plus the `OPERATOR_REMOVABLE` set at `:1516`.
→ **Recommend the plan file a doc ticket** (not a code one): either a `BusinessObjectLockState` section in
the catalog or a lock-lifecycle section in the cancel-cascade workflow. Without it, the next person
re-derives §2 of this file from scratch.

**Confirms:** §5.1 correctly flags that `handleRapidPickingForCancelledOrder` no longer exists and that
the rapid-pick branch sets `PROCESSABLE`, not `CANCELED` — consistent with `origin/develop:784`.
Its 2026-08-06 warning banner (*"Anchors in §5 were re-checked and MOST WERE WRONG"*) is the reason
its line numbers are closer to reality than the workflow doc's.

**Also FALSE there:** §4.1's key-write-site table cites
`controller/rest/UtilRestController.java:1092,1095,1099 (resetOrdersInReleasedStatus :1080) → RAW`
as a live `Customerorder` write path. Per §1.4 the class is `@Service` and that method is
test-only reachable.

---

## 6. §0 Affected-Sites table — plan format

| # | File | Construct | Same root-cause? | In-scope this plan? |
|---|---|---|---|---|
| 1 | `v2/wms2-api/src/main/java/net/aim_ai/wms/service/CustomerorderService.java:722` | `cancelOrder` success branch (`setState(CANCELED)` at `:821`) — no lock clear, no `pickingtote_id` null, no `sendToClearing`, no `historytote` | **Yes — this is the defect** | **Yes** |
| 2 | `v2/wms2-api/src/main/java/net/aim_ai/wms/service/CustomerorderBatchService.java:398` | `cancelBatch` — nulls `pickingtote_id` (`:513`) and cancels the `pickingorder_unitload` (`:502`) but never clears stock `entity_lock` and never relocates the tote | **Yes — identical, and worse (severs the diagnostic link)** | **Yes** — one guarded block, mirrors #1; zero production callers so blast radius is nil. If the plan's budget forces a cut, this is the cut — but say so explicitly and file it, do not drop it silently |
| 3 | `v2/wms2-api/src/main/java/net/aim_ai/wms/service/CustomerorderService.java:407` | `forceCancelOrder` — correct sibling; clears tote lock + stock lock + nulls + `sendToClearing` | No — reference implementation | No (read-only; the fix must not diverge from it) |
| 4 | `v2/wms2-api/src/main/java/net/aim_ai/wms/service/PickingorderBusinessService.java:599` | `cleanUpCancelledOrder` — correct sibling; the shape the fix should copy (stock lock only, not the tote's own) | No — reference implementation | No (read-only; **preserve the SBDEV-3316 ordering pin at `:648`**) |
| 5 | `v2/wms2-api/src/main/java/net/aim_ai/wms/service/CustomerorderService.java:783-806` | rapid-pick sub-branch of `cancelOrder` — `sendToNirvana` + null, but throws on a non-empty tote | No — empty-tote retire, cannot reach the stranded population | No |
| 6 | `v2/wms2-api/src/main/java/net/aim_ai/wms/service/CustomerorderPositionService.java:118` | `cancelOrderPosition` — no tote teardown | No — position-level; the tote is an order-level resource | No |
| 7 | `v2/wms2-api/src/main/java/net/aim_ai/wms/repo/jpa/CustomerorderRepository.java:166` | `@Modifying updateStateByIds` — *can* write 800, invisible to a `setState` grep; sole caller passes `PACKED` | No (latent only) | No — cite in the plan as the grep's blind spot |
| 8 | `v2/wms2-api/src/main/java/net/aim_ai/wms/service/StockunitService.java:707` | `removeLock` refuses `PICKED_FOR_GOODSOUT` (`OPERATOR_REMOVABLE = {QUALITY_FAULT, ON_HOLD}`, `WmsConstants:1516`) | No — but it is **why** the defect has no operator workaround | No — do not widen the set; that would be a different, security-shaped ticket |
| 9 | `v2/wms2-api/src/main/java/net/aim_ai/wms/service/BillofladingService.java:1599,1605` | bulk `entityManager.createQuery("UPDATE Stockunit s SET s.entityLock = :lock")` → `SHIPPED` | No — correct terminal lock | No — cite as proof the `setEntityLock` grep has a real blind spot |
| 10 | `sbdocs/3-Resources/workflows/wms2-cancel-cascade-workflow.md` §5, §9, §2 | 8 false claims (D-1…D-8), incl. *"cancelBatch releases entity locks"* — which asserts the §2 defect is already fixed | Doc drift on the defect's own surface | **Yes** — verify-docs pass; D-1 and D-2 must be corrected in the same PR |
| 11 | `sbdocs/3-Resources/architecture/wms2-state-machine-catalog.md` | `BusinessObjectLockState` documented nowhere in `sbdocs/`; §4.1 cites `UtilRestController` as a live write path | Documentation gap, not a code defect | No — **propose** a doc ticket; do not absorb it into 3339 |

---

## 7. Open items this lane could not close

1. **Flyway migrations / DB triggers writing `customerorder.state = 800`** — not probed. No `src/main` grep can see them.
2. **Fleet-wide blast radius** — blocked on environment access, per [db-evidence.md §6](./db-evidence.md). Only Hydra PRD was reachable.
3. **Breadth-of-clear policy** (§3.2): clear every lock like `cleanUpCancelledOrder:612`, or only `PICKED_FOR_GOODSOUT` like `CancellationReversalService:259`? Two live paths, two policies. **Needs an explicit decision in the plan** — the TDD gate will otherwise pick one by accident.
4. **Whether `cancelBatch` should be fixed or deleted.** It has had no caller since at least 2026-03 and three archived plans say so. Fixing dead code and deleting dead code are both defensible; that is Nam's call, not this lane's.
