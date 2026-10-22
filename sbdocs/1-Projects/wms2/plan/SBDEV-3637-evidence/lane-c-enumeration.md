# SBDEV-3637 — Lane C: affected-sites enumeration

**Tree read:** `/home/nampark/dev/wms-claude/.claude/worktrees/wms2-api/SBDEV-3637-readonly`, detached at
`ec42f43a` (`Merge pull request #453 from SiteBossInc/feature/SBDEV-2624-sku-rename-in-place`), `git status --porcelain` empty.
The main checkout `v2/wms2-api` is at `5240ab17`; `git rev-list --count 5240ab17..origin/develop` = **329**. Every claim below is derived
against `ec42f43a` only.

**Instrument note.** All scans are `git grep` (not bare `grep`) because the shell's `grep` is ugrep, which skips binary files
without `-a` and exits 1 identically to a genuine no-match. `git grep` is unaffected. Every zero-result scan below carries a
positive control run in the same invocation.

**No production file was read-modified. Nothing was written outside this file. No `mvn`, no `git stash`, no HEAD change.**

---

## 0. Headline findings (read these first — three of them change the plan's shape)

1. **Every branch the task brief called "in flight RIGHT NOW" is already merged into `origin/develop`.** SBDEV-3608, 3618,
   3621, 3624, 3633, 3636, 3638, 3605 and 3622 are all ancestors of `ec42f43a`. There is **no** branch-level collision in
   `ReplenishmentOrderMaintenanceService.java` from any of them. Details and the two instruments in §4.
2. **SBDEV-3626 IS a live collision and its state cannot be read from its plan.** Its plan edits
   `ReplenishmentOrderMaintenanceService.java` and claims "gate tests committed `c99ddaff`" — **that object does not exist in
   this repository**, and no `SBDEV-3626` worktree exists. Details in §4.
3. **The ticket's claim that the other re-source writers lock in id order is TRUE for both of them**, verified per site with
   quoted snippets (§1.2). I independently reproduce the team lead's `setStockunitId` result exactly, and confirm
   `switchSourceToUnitLoad` is gone from every tracked file. **No disagreement.**
4. A **fourth** Stockunit-lock asymmetry exists on the replenishment path that the fix as scoped does not touch:
   `ReplenishorderService.cancelReplenishmentOrder` locks the **source SU before the order row**, inverting the cron's
   order→SU direction. It is documented in-code as an accepted residual (§1.1 row 11). Flagged, not in scope.

---

## 1. §0 Affected Sites

### 1.1 Every acquisition of a Stockunit row lock in `src/main`

**Derivation (three mechanisms, because no single one is complete):**
- **(a) Entity-finder locks:** `git grep -n "stockunitRepository\.findByIdForUpdate" -- src/main/java`, piped through
  `grep -v '^\s*//'` to drop javadoc/comment mentions. → **17** call sites. Cross-checked against
  `git grep -hoE "[a-zA-Z]+Repository\.findByIdForUpdate" -- src/main/java | sort | uniq -c`, which independently reports
  `17 stockunitRepository.findByIdForUpdate`. **Two instruments agree at 17.**
- **(b) Native `FOR UPDATE`:** `git grep -in "for update" -- src/main/java`. Exactly one executable native Stockunit lock:
  `StockunitRepository.getStockUnitsByItemDataIdForUpdate`, whose query ends `"FOR UPDATE OF stockunit"`. (Every other hit in
  that scan is a comment; `OutboxMessageRepository`'s `FOR UPDATE SKIP LOCKED` is on `outbox_message`, not `stockunit`.)
- **(c) `@Lock` annotations:** `git grep -n "@Lock(" -- src/main/java`. `StockunitRepository` declares exactly one —
  `@Lock(LockModeType.PESSIMISTIC_WRITE)` above `findByIdForUpdate`.

**Blind spots of this derivation, named:**
- A bulk `@Modifying UPDATE`/`DELETE` takes a row lock per matched row "exactly as FOR UPDATE does" — the repository's own
  comment says so: *"the 15 @Lock sites, the 2 native FOR UPDATE queries, and the ~31 bulk @Modifying UPDATE/DELETEs, which
  take a row lock per matched row exactly as FOR UPDATE does"* (`StockunitRepository.java`). `StockunitRepository` itself
  declares **no** `@Modifying` method (scan: `git grep -n -A3 "@Modifying" -- .../StockunitRepository.java` → only the comment
  line; positive control: the same grep over `repo/jpa/` returns counts for 8+ other repositories, so the instrument works).
  A bulk update on `stockunit` issued from **another** repository, or a plain dirty-checked `UPDATE` at flush, would not appear
  in (a)–(c) at all. **Those are real lock acquisitions this table does not enumerate.**
- A lock acquired through a `@Query` on a *different* repository that joins `stockunit` is not matched by (a).

| # | file | construct (quoted snippet) | same root cause? | in scope this plan? | rationale |
|---|---|---|---|---|---|
| 1 | `service/ReplenishmentOrderMaintenanceService.java` — `ensureValidSource` | `: stockunitRepository.findByIdForUpdate(order.getStockunitId()).orElse(null);` | **YES — this is the defect** | **YES** | The *current source* lock. Taken while the transaction already holds the `Replenishorder` row lock from `recalculateOrder`'s `findByIdForUpdate(orderId)`. Ordered by role, not by id. |
| 2 | `service/ReplenishmentOrderMaintenanceService.java` — `redirectSource` | `Stockunit targetStock = stockunitRepository.findByIdForUpdate(candidate.stockUnitId).orElse(null);` | **YES — this is the defect** | **YES** | The *target* lock, taken second. Transaction already holds: the order row + site 1's SU. The `⚠ LOCK ORDERING — NOT PROVED SAFE` comment sits immediately above this line. |
| 3 | `service/ReplenishmentOrderMaintenanceService.java` — `reassignOrCancelForMovedStockUnit` | `Stockunit lockedSource = stockunitRepository.findByIdForUpdate(movedStock.getId()).orElse(null);` | **YES — same pair, other entry point** | **YES** | SBDEV-3618 Fix D. The move path's "current" lock, feeding the same `redirectSource(order, lockedSource, share, false)`. Already holds the order row (`findByIdForUpdate(probeId)`) **and** the caller's move transaction. Both entry points now agree on current→target, which is exactly why the residual is cross-*order*, not cross-*path*. |
| 4 | `service/ReplenishorderService.java` — `redirectSource(Long,Long)` | `oldStockUnit = stockunitRepository.findByIdForUpdate(oldStockUnitId);` (asc branch) | Same *pair of rows*, **opposite discipline** | **Reference only** | Already id-ordered (§1.2). This is the writer the fix should be made to match — it is the precedent, not a defect. |
| 5 | same file, same method | `newStockUnit = stockunitRepository.findByIdForUpdate(newStockUnitId);` (asc branch) | ″ | Reference only | ″ |
| 6 | same file, same method | `newStockUnit = stockunitRepository.findByIdForUpdate(newStockUnitId);` (desc branch) | ″ | Reference only | ″ |
| 7 | same file, same method | `oldStockUnit = stockunitRepository.findByIdForUpdate(oldStockUnitId);` (desc branch) | ″ | Reference only | ″ |
| 8 | `service/mobile/MobileReplenishService.java` — `fulfillMultipleUnitLoadsTx` | `for (Long id : lockIds) { stockunitRepository.findByIdForUpdate(id).ifPresent(su -> locked.put(id, su)); }` over `SortedSet<Long> lockIds = new TreeSet<>();` | Multi-row Stockunit lock set, **ascending by construction** | **Reference only** | The strongest existing precedent: one ascending pass over `{old SU} ∪ scanned SUs`. Holds the template order lock first. |
| 9 | `service/mobile/MobileReplenishService.java` — `finishReplenishmentOrderWithoutRefill` | `sourceStock = stockunitRepository.findByIdForUpdate(mobileOrder.getSourceStockId()).orElse(null);` | No — re-lock of a row site 8 already locked | No | Comment: *"The caller already holds this lock, so this is a re-lock no-op"*. |
| 10 | `service/mobile/MobileReplenishService.java` — `readReplenishOrder` region | `Replenishorder template = replenishorderRepository.findByIdForUpdate(request.getOrderId())` (order, not SU — listed for the order-first discipline) | No | No | Shown because it establishes "order before any SU" on the live handheld flow. |
| 11 | `service/ReplenishorderService.java` — `cancelReplenishmentOrder` | `Optional<Stockunit> sourceStockOptional = stockunitRepository.findByIdForUpdate(replenishOrder.getStockunitId());` | **Related, DIFFERENT shape — SU before order** | **No — FINDING, flag it** | In-code: *"The order row is not locked first; that SU-then-order order is a known, bounded residual."* This inverts against the cron's order→SU on the **same order**. It is an accepted residual (SBDEV-3621), but an id-ordering fix at sites 1–3 does **not** close it, and a plan that says "lock ordering on the replenish path is now closed" would be false. |
| 12 | `service/StockunitBusinessService.java` — `changeReservedAmount` | `sourceStockunit = stockunitRepository.findByIdForUpdate(sourceStockunitId)` | **YES — reached from inside the defect** | **Indirect — must be reasoned about** | `redirectSource` calls `stockunitBusinessService.changeReservedAmount(targetStock, …)` *after* site 2. Because site 2 already locked that row, this is a re-lock no-op; but `releaseHeld` on the current source reaches the same method for site 1's row. Any change to the acquisition order at sites 1–3 changes what this method finds already-locked. |
| 13 | `service/StockunitBusinessService.java` — `transferStockToUnitLoad` | `destinationStockUnit = stockunitRepository.findByIdForUpdate(dstSuId)` | No — different pair (src SU + dst SU + 2 ULs + 2 Locations) | No | Carries its own canonical order: *"Canonical lock order is Pickingorder BEFORE Stockunit/Unitload/…"*. Reached from the replenish **finish**, not the recalc. |
| 14 | `service/StockunitBusinessService.java` (×2, `:472` / `:509` region) | `Stockunit stockUnit = stockunitRepository.findByIdForUpdate(staleStockUnit.getId())` | No | No | Re-lock of a caller-supplied stale entity. |
| 15 | `service/StockunitService.java` — stranded-reservation / holder path | `Stockunit stockUnit = stockunitRepository.findByIdForUpdate(stockUnitId)` | **Related — opposite direction** | No | Preceded by `Replenishorder locked = replenishorderRepository.findByIdForUpdate(holder.getId())` in the same method region: orders ascending, then the SU. Same discipline the fix wants; a second precedent. |
| 16 | `service/CustomerorderPositionService.java` | `Stockunit stockUnit = stockunitRepository.findByIdForUpdate(pickingPosition.getPickfromstockunitId())` | No — picking path | No | Holds a `Pickingorder` lock first (documented canonical order). |
| 17 | `service/PickingorderBusinessService.java` | `Stockunit sourceStock = stockunitRepository.findByIdForUpdate(sourceStockId)` | No — picking path | No | ″ |
| 18 | `repo/jpa/StockunitRepository.java` — `getStockUnitsByItemDataIdForUpdate` | `"ORDER BY stockUnit.amount DESC " + "FOR UPDATE OF stockunit"` | **No, but it is the sharpest adjacent hazard** | **No — but name it in the plan** | ⚠ Multi-row, **no LIMIT**, and ordered by `amount DESC`, **not by id**. Its own comment: *"⚠ MULTI-ROW LOCK, NO LIMIT… PostgreSQL applies lock_timeout separately to each lock ACQUISITION"*. Reached from `ReleaseOrderJobService` Fix B, not from replenish recalc. An "all Stockunit locks are id-ordered" invariant asserted by this plan would be **false** while this query exists. |

**What a transaction already holds at each of sites 1–3** (the reason a one-method fix is incomplete):

| entry point | held before the first SU lock | then |
|---|---|---|
| `recalculateOrder` (cron, `recalculateOpenOrders`) | `Replenishorder` row (`replenishorderRepository.findByIdForUpdate(orderId)`) | site 1 (current SU) → site 2 (target SU) |
| `recalculateForItem` (joined into a **caller's** tx) | the caller's whole transaction **plus** one `Replenishorder` row per iteration, released only at the outer commit | sites 1→2, per order, accumulating |
| `reassignOrCancelForMovedStockUnit` (unit-load move) | the move's tenant tx (`UnitloadBusinessService.transferUnitLoadToLocation`) + the `Replenishorder` row | site 3 (current SU) → site 2 (target SU) |

The `recalculateForItem` row is the one that makes this a genuine T3: `recalculateOrder` is called with a plain `this.` call
inside the shared outer transaction, so the per-order locks are **not** released between iterations. One sweep of N orders
accumulates up to N order locks and 2N SU locks before commit. The OSIV map already documents this as a landmine (§3).

### 1.2 Every re-source writer on an existing `Replenishorder`

**Derivation:** `git grep -n "setStockunitId" -- src/main/java` (13 hits), then filtered by receiver type.

| hit | receiver | classification |
|---|---|---|
| `json/CycleCountPositionViewDto.java` | DTO | not a writer |
| `model/CyclecountPosition.java`, `model/Goodsreceiptposition.java`, `model/Replenishorder.java` | the setters themselves | not call sites |
| `service/CyclecountPositionService.java`, `service/CyclecountService.java` | `CyclecountPosition` | different entity |
| `service/ReceivingService.java` | `Goodsreceiptposition` | different entity |
| `service/ViewDtoService.java` | DTO | not a writer |
| `service/ReplenishGeneratorService.java:~297` | `Replenishorder` | **CREATE** (`calculateOrder`) |
| `service/ReplenishGeneratorService.java:~349` | `Replenishorder` | **CREATE** (`createOrderFromTemplate`) |
| `service/ReplenishmentOrderMaintenanceService.java:~609` | `Replenishorder` | **RE-SOURCE writer 1** |
| `service/ReplenishorderService.java:~300` | `Replenishorder` | **RE-SOURCE writer 2** |
| `service/mobile/MobileReplenishService.java:~1010` | `Replenishorder` | **RE-SOURCE writer 4** |

**I reproduce the team lead's result exactly: three re-source writers plus two CREATE sites. I do not disagree.**

**`switchSourceToUnitLoad` — confirmed gone.** `git grep -n "switchSourceToUnitLoad"` over **all tracked files** (not just
`src/main`) exits 1 with zero output. **Positive control in the same scan:** `git grep -n "redirectSource"` over the same scope
returns 23+ hits across `src/main`, `docs/plan/`. So the instrument finds strings in this tree, and the zero is a true zero.
The ticket's "four writers including `switchSourceToUnitLoad`" is **stale** — it was removed by SBDEV-3638, which is merged
(§4).

**Per-writer lock discipline — the ticket's claim verified individually:**

- **Writer 1 — `ReplenishmentOrderMaintenanceService.redirectSource` — NOT id-ordered. This is the defect.**
  Current source first (`ensureValidSource` / `reassignOrCancelForMovedStockUnit`), target second
  (`Stockunit targetStock = stockunitRepository.findByIdForUpdate(candidate.stockUnitId).orElse(null);`), with no comparison
  of the two ids anywhere between them. The in-code comment is explicit that this is known and accepted:
  > *"NOT ESTABLISHED — that two DIFFERENT orders cannot want the same pair in opposite directions… The residual is ACCEPTED,
  > not denied, and it is bounded: PostgreSQL detects a row-lock cycle and aborts one side with 40P01, or SBDEV-3250's
  > per-acquisition lock_timeout fires first… If you want it actually closed rather than bounded: acquire the two stock-unit
  > locks in ascending id order and delete this comment."*

- **Writer 2 — `ReplenishorderService.redirectSource(Long,Long)` — id-ordered. CLAIM CONFIRMED.**
  ```java
  // Ascending-id lock order (D7): closes the redirect-vs-redirect cycle X: A->B / Z: B->A.
  if (oldStockUnitId != null && oldStockUnitId < newStockUnitId) {
      oldStockUnit = stockunitRepository.findByIdForUpdate(oldStockUnitId);
      newStockUnit = stockunitRepository.findByIdForUpdate(newStockUnitId);
  } else {
      newStockUnit = stockunitRepository.findByIdForUpdate(newStockUnitId);
      if (oldStockUnitId != null) {
          oldStockUnit = stockunitRepository.findByIdForUpdate(oldStockUnitId);
      }
  }
  ```
  Both arms are ascending: the `else` arm is reached only when `oldStockUnitId` is null or `> newStockUnitId`. ⚠ `Long <
  Long` here is an **unboxing** comparison, not a reference comparison, so the boxed-Long-128 trap does not apply; a null
  `oldStockUnitId` is short-circuited by the `!= null` guard before the unbox. The order row is locked first
  (`replenishorderRepository.findByIdForUpdate(orderId)` is the method's first statement).

- **Writer 4 — `MobileReplenishService.applyExplicitSourceToOrder` — id-ordered by its caller. CLAIM CONFIRMED.**
  `applyExplicitSourceToOrder` itself takes **no** SU lock; the locks are taken by `fulfillMultipleUnitLoadsTx` before it is
  called:
  ```java
  SortedSet<Long> lockIds = new TreeSet<>();
  for (ResolvedUnitLoad entry : resolved) { lockIds.add(entry.stockunitId); }
  if (template.getStockunitId() != null) { lockIds.add(template.getStockunitId()); }
  Map<Long, Stockunit> locked = new HashMap<>();
  for (Long id : lockIds) { stockunitRepository.findByIdForUpdate(id).ifPresent(su -> locked.put(id, su)); }
  ```
  `TreeSet<Long>` iterates in natural ascending order. The template order row is locked first (SBDEV-3605 Fix A).
  ⚠ **Nuance worth carrying into the plan:** the ordering here is a *caller-side* property, enforced by a data structure
  three statements away from the writer. A test that pins "writer 4 locks ascending" is pinning `fulfillMultipleUnitLoadsTx`,
  not `applyExplicitSourceToOrder`.

### 1.3 `ReplenishmentOrderSourceSyncService` — what it actually is

**Verdict: a ROUTER, not a fourth writer.** Read in full (148 lines).

- It writes `requestedlocationId` / `requestedrackId` / `sourcelocationname` only. Its own comment: *"stockunitId /
  reservedamount / requestedamount intentionally UNCHANGED (I-1)."* It does **not** appear in the `setStockunitId` scan.
- It takes **no Stockunit lock at all** — `git grep -n "stockunitRepository" .../ReplenishmentOrderSourceSyncService.java`
  returns nothing, and the class does not inject `StockunitRepository` (constructor takes `ReplenishorderRepository`,
  `LocationRackRepository`, `LocationAreaRepository`, `@Lazy ReplenishmentOrderMaintenanceService`, `SyspropService`).
- It locks the `Replenishorder` row: `Replenishorder replenishOrder = replenishorderRepository.findByIdForUpdate(probeId)`.
- **Its routing decision is what puts a transaction into the defect.** `syncForMovedStockUnit` branches:
  ```java
  if (!isReplenishableDestination(destinationLocation)) {
      replenishmentOrderMaintenanceService.reassignOrCancelForMovedStockUnit(stockUnit, destinationLocation);
      return;
  }
  ```
  → the non-replenishable arm is site 3.
- ⚠ **A real trap for the fix's test fixtures, already documented in a test javadoc and worth restating in the plan:** the two
  `isReplenishableDestination` implementations **do not agree**. `ReplenishmentOrderSourceSyncService`'s consults the
  SBDEV-1666 lane sysprop *and* the area flag; `ReplenishmentOrderMaintenanceService`'s consults the area flag **only**
  (*"// null area -> treat as NON-replenishable (safe default)"*). `ReplenReassignOnNonReplenishableMoveIT`'s javadoc calls
  this *"the trap in this subsystem and the fixture below is built around it."*

---

## 2. Existing test surface

**Derivation:** `git grep -ln -e "redirectSource" -e "ensureValidSource" -e "reassignOrCancelForMovedStockUnit" -- src/test`
(16 files), union `git grep -ln "stockunitRepository" -- src/test | xargs git grep -ln "findByIdForUpdate"` (33 files), union
`git ls-files src/test | grep -i replenish` (46 paths). Three instruments, unioned rather than intersected.

**Lane classification rule used** (per SBDEV-3239): `*IT`, `*IntegrationTest`, `*E2ETest` → **failsafe**; everything else →
**surefire**. H2 is a surefire sub-lane distinguished by the class name suffix `H2Test` and by `BasePostgresIntegrationTest`
being *absent*.

### 2.1 Directly implicated — the signature change reaches these

| class | lane | what it asserts | breaks on `boolean → 3-way enum`? |
|---|---|---|---|
| `unit/service/ReplenishmentOrderMaintenanceServiceUnitTest` (2165 lines, **76 `@Test`**) | surefire | The whole recalc surface. Nested `@DisplayName("Source redirect — redirectSource()")` block. Key cases: `redirectSource_shouldReleaseOldSourceUnderOrderNumber_whenOrderIsRedirected`, `redirectSource_shouldSwitchTheManualCutCooldownOn`, `redirectSource_shouldReleaseHeldFromCurrent_whenUnderReserved`, `redirectSource_shouldRepointOnly_whenCandidateIsCurrentSource` (U-12), `isSourceUsable_shouldSeekAnotherSource_whenCapacityIsExactlyZero` (U-5b) | **Not at compile time** — `redirectSource` is `private`, so no test calls it. **At behaviour:** yes, in the cases that observe the boolean *through* its caller. U-12 asserts `order.getState()` *"re-point returns true: the order is kept, not cancelled"*; the cancel-on-false cases assert `State.CANCELED`. A new `CONTENDED` outcome that **defers** (neither re-points nor cancels) is a **third** post-state these tests do not enumerate. Each such test is a candidate for an added `CONTENDED` sibling, not a rewrite. |
| `unit/service/ReplenishmentOrderMaintenanceServiceReassignTest` (449 lines, **15 `@Test`**) | surefire | The move path. **Carries the two lock-order pins the fix must preserve and extend:** U-11 `inOrder(stockunitRepository, stockunitBusinessService)` → `findByIdForUpdate(MOVED_STOCK_ID)` before the release; **U-11b** `inOrder(stockunitRepository, replenishorderRepository, stockunitBusinessService)` → `findByIdForUpdate(MOVED_STOCK_ID)` … then `findByIdForUpdate(99L)` (the candidate). | **U-11b breaks by design.** It pins *moved-SU-then-candidate*. Under ascending-id ordering that order inverts whenever `candidateId < movedStockId`. In the fixture `MOVED_STOCK_ID` vs `99L` decides it. **This test is the single most important thing to read before writing the fix** — it is a correct pin of the *current* contract that the fix deliberately changes, and silently flipping its fixture ids to keep it green would destroy the assertion. |
| `unit/service/ReplenishmentFirstTouchInvariantUnitTest` (272 lines, 3 `@Test`) | surefire | SBDEV-3244 AC-3′. `redirectSource_loadsTheTargetUnderItsLock` pins `InOrder`: `findByIdForUpdate(candidateId)` **before** `findById(candidateId)`. Also `recalculateOpenOrders_neverLoadsTheOrderWithANonLockingFinder`. | **Survives** — it pins locking-before-plain on the *same* row, which ascending-id ordering does not change. ⚠ But its `verifyNoMoreInteractions(ignoreStubs(...))` guard is explicitly documented as *weakened*: *"it marks every invocation that matched a stubbing as verified, so a newly added finder is caught only IF NOBODY STUBS IT."* **A new `findByIdForUpdateSkipLocked` that the fix stubs will slip past this guard.** The class's own comment says: *"If you tighten anything here, tighten the two weakened ones."* |
| `integration/service/ReplenishmentOrderMaintenanceServiceIntegrationTest` (291 lines, 1 `@Test`) | **failsafe / Testcontainers PG** | SBDEV-2234 AC-4 — concurrent `recalculateForItem` must not double-write the reservation. Asserts the *delta* invariant (`requestedamount` and `reservedamount` move by the same delta), not naive equality. | Does not touch the signature. **Most likely to go red for a real reason**: it is already a concurrency test on the exact method whose lock topology changes. Treat a red here as signal. |
| `service/ReplenReassignOnNonReplenishableMoveIT` (471 lines, 6 `@Test`) | **failsafe** | SBDEV-2074 AC1–AC8 on the move path, end to end. Its javadoc enumerates its own mutants: *"make `redirectSource` never succeed → kills AC2 and AC8"*. | **The AC2/AC8 mutant statement becomes ambiguous** once "never succeed" splits into `NO_CANDIDATE` vs `CONTENDED`. The javadoc needs updating with the code. |
| `integration/service/ReplenishorderRedirectSourceIT` (SBDEV-3561, 20+ `@Test`) | **failsafe / Testcontainers PG** | Writer 2's surface. **Already contains two-thread latch cases**: IT-C1 *"a redirect racing the cron's cancel of X WAITS on X's row lock"*, IT-C2 *"after the cron switched X from A to C, the waiting redirect proceeds on the FRESH row"*, SBDEV-3605 IT-7 *"a pick racing a held web redirect WAITS on the ORDER row"*. Uses `CountDownLatch t1Holding` / `releaseT1` + `Executors.newFixedThreadPool(2)`. | Writer 2 is unchanged → no break. **This is the richest source of copyable mechanics** for the new test. |
| `integration/repository/ManualCutCooldownPredicateIntegrationTest` | **failsafe** | `"recalc's redirectSource must not re-point an order onto a stock unit the operator just cut"` (SBDEV-3636). | Unaffected by the signature; affected if `CONTENDED` changes whether a re-point happens at all. |
| `unit/service/ReplenishmentOrderSourceSyncServiceTest`, `…BranchTest` | surefire | The router's two arms. | Only if the delegation signature changes — it does not (`reassignOrCancelForMovedStockUnit` stays `void`). |
| `unit/service/ReplenishorderServiceUnitTest` | surefire | Writer 2, incl. `redirectSource_shouldReleaseOnlyHeldShareFromOldSource_whenAnotherOrderHoldsStockThere` and an ascending-order case at `:986`/`:995`. | No break. **Read it for the id-ordering assertion style to copy.** |
| `unit/service/mobile/MobileReplenishServiceUnitTest` | surefire | Writer 4 + the PROCESSABLE guard parity with writer 2. | No break. |
| `unit/controller/ReplenishOrderControllerUnitTest`, `…GateH2Test` | surefire (H2 for the latter) | `verify(replenishorderService).redirectSource(1L, 2L)` — **writer 2's** public method. | **No break** — different class. Named here only because a `grep redirectSource` hit will surface it and look alarming. |
| `unit/repo/ReplenishmentSourceQueryParityUnitTest` | surefire | Byte-parity of the two source-selection queries. | Breaks **only** if the fix edits `getAvailableReplenishmentSources` or its twin. The planned fix does not. |
| `integration/service/ReplenishmentHeldShareIT`, `integration/ReplenishmentOrderSourceSyncIT`, `integration/service/mobile/MobileReplenishMultiUnitLoadIT`, `…SourceScanIT`, `smoke/ReplenishReassignContextLoadTest` | failsafe (last is surefire smoke) | Adjacent replenish surface; `ReplenishReassignContextLoadTest` pins the `@Lazy` DI-cycle break between the sync service and the maintenance service. | No break expected. `ReplenishReassignContextLoadTest` goes red if a new repository method is added with a bad signature — it is the cheapest canary for the `findByIdForUpdateSkipLocked` addition. |

### 2.2 Structural / ArchUnit pins that will react

**Derivation:** `git ls-files src/test | grep -iE "arch|invariant|pin|frozen"` → 37 paths. Reacting subset:

| pin | reacts to | how |
|---|---|---|
| `unit/config/OptionalSafetyArchTest` | **a new `Optional.get()` call site** | `FreezingArchRule.freeze(...)`, store at `src/test/resources/archunit_store/`. Its javadoc is emphatic: *"never refreeze merely because the store's line numbers look stale. They are stale on develop right now, by 55 entries, and the build is green."* A new `findByIdForUpdateSkipLocked(...).get()` would be a genuine new violation; `.orElse(null)` (the existing style at all three defect sites) would not. **Use `.orElse(null)`, matching the surrounding code, and this pin stays quiet.** |
| `unit/config/TestClassTransactionManagerArchTest` | **test-class `@Transactional` manager choice** | Already names this area: *"SBDEV-3561. NOT_SUPPORTED because the subjects (redirectSource, recalculateForItem, …)"*. A new concurrency IT **must** be `@Transactional(propagation = Propagation.NOT_SUPPORTED)` or this goes red. |
| `unit/config/TransactionManagerArchTest`, `unit/config/HttpInTransactionArchTest` | bare `@Transactional` / HTTP-in-tx | Only if the fix adds an annotation. It should not. |
| `unit/config/TestIdentifierCountArchTest`, `unit/config/JUnitTagWiringArchTest`, `unit/config/CommentOnlyTestBodyArchTest` | new test classes | A new IT must carry the right tag wiring and a non-empty body. |
| `unit/config/PostgresTestHarnessPinTest` | the PG harness shape | Reacts if a new IT diverges from `BasePostgresIntegrationTest`. |
| `unit/service/ReplenishmentFirstTouchInvariantUnitTest` | **the first-touch invariant** | Not ArchUnit, but it is the behavioural pin on this exact file. See §2.1 for its weakened guard. |

**No lock-order ArchUnit rule exists.** Scan: no file under `src/test/java/net/aim_ai/wms/unit/config/` has "lock" in its name
(`git ls-files` listing above is the whole directory). **Positive control:** the same listing does contain
`ParallelStreamSafetyArchTest`, `SingletonTenantStateArchTest` etc., so the directory and the instrument are real. Lock
ordering in this repo is pinned **behaviourally** (`InOrder` in unit tests, `*LockOrderProbeIT` against PG), never structurally.

### 2.3 Concurrency IT template — recommendation

| candidate | lines | `@Test` | thread constructs | latches | `40P01` mentions |
|---|---|---|---|---|---|
| `integration/PostgresDeadlockDetectorControlIT` | 216 | 1 | 4 | 3 (`CyclicBarrier`) | **25** |
| `integration/service/mobile/MoveUnitloadLockOrderProbeIT` | 279 | 2 | 3 | 0 | 0 |
| `integration/service/ClosebolLockOrderProbeIT` | 439 | 2 | 3 | 0 | 1 |
| `integration/service/mobile/MobileTruckLoadingLockOrderProbeIT` | 444 | 4 | 3 | 0 | 1 |
| `integration/service/PalletizeLockOrderProbeIT` | 568 | 3 | 3 | 0 | 0 |
| `integration/MoveCronConcurrencyIT` | 266 | 1 | 4 | 4 | 3 |
| `integration/service/ReplenishorderRedirectSourceIT` | 600+ | 20+ | 2 (pool) | 2 | 0 |
| `integration/ReplenishDupConcurrencySliceIT` | 276 | 2 | 4 | 4 | 0 |
| `integration/outbox/OutboxConcurrentEnqueueIT` | 166 | 2 | 2 | 5 | 0 |
| `service/StockunitBusinessServiceConcurrencyIT` | 318 | 2 | 7 | 8 | 0 |
| `integration/service/mobile/MobileTruckLoadingRaceIT` | 380 | 3 | 11 | 6 | 0 |

**Recommended template: `integration/service/ReplenishorderRedirectSourceIT` for the fixture, `MoveUnitloadLockOrderProbeIT`
for the probe mechanics, `PostgresDeadlockDetectorControlIT` as the positive control. Not one — three, and that is the
recommendation.**

- **Fixture →** `ReplenishorderRedirectSourceIT` via its base `AbstractReplenishRedirectPgFixture` (301 lines, 0 `@Test`,
  `abstract class … extends BasePostgresIntegrationTest`, `@Transactional(propagation = Propagation.NOT_SUPPORTED)`). It
  **already builds exactly the graph this fix needs**: two source SUs (`SU_A=9990`, `SU_B=9991`) plus `SU_C`, two orders
  (`ORDER_X=9995`, `ORDER_Y=9996`), two areas, an FLA, a destination. Two orders + two SUs is the literal shape of the
  cross-order ABBA the fix closes. It also carries the **id-band discipline** (9984–9998, swept per plan §6 A0) and the
  shared-`wipe()` rationale. Reusing it means the new class is a subclass, not a new fixture — and SBDEV-3637 is the fourth
  subclass, after `ReplenishorderRedirectSourceIT`, `ReplenishmentHeldShareIT`, `ReservationCutAttributionIT`.
  ⚠ **But the band is nearly full.** Writing a second *pair* of orders wanting the opposite pair of SUs may need ids outside
  9984–9998; re-run the A0 sweep (`git grep -n -E "99[0-9]{2}L" -- src/test`) before picking.
- **Probe mechanics →** `MoveUnitloadLockOrderProbeIT`. It parks a raw JDBC holder connection
  (`DriverManager.getConnection`) on a row and then asserts **where** the worker blocks, using
  `BlockedBackendReads` and the `pg_stat_activity.backend_xid` trick: *"PostgreSQL assigns an xid on a backend's first row
  lock or write, so a NULL `backend_xid` while blocked means no row lock or write came before"*. That is the only mechanism in
  this repo that can prove *which lock was taken first* rather than merely that a deadlock did or did not happen — which is
  exactly the AC an ordering fix needs. A pure "no deadlock in N runs" test is a zero-scan and would be worthless without it.
- **Positive control →** `PostgresDeadlockDetectorControlIT`. It exists because *"a broken instrument and a true zero are
  indistinguishable."* It proves, on the pinned `postgres:14-alpine`, that a deliberate ABBA **is** aborted with 40P01 and
  **does** increment `pg_stat_database.deadlocks`. Any SBDEV-3637 AC of the form "after the fix, no 40P01" is unfalsifiable
  without it in the same lane.

**Known-flaky — do NOT copy these, and expect them red for reasons unrelated to this fix:**
- `integration/outbox/OutboxConcurrentEnqueueIT` — **timing-flaky** (SBDEV-3280; a red develop silently stops deploying).
- `integration/ReplenishDupConcurrencySliceIT` — **timing-flaky**; the loser throws *"No replenish stock available"*, not the
  index violation. **Rerun before debugging.**
- `ParcelMonitorViewServiceConcurrencyIT` — flaky per the suite-baseline note, not container state.
- ⚠ Concurrent Maven runs against the shared reusable postgres container produce false reds across all of these. `pgrep` for
  a peer's `mvn` before treating any red as real.

---

## 3. Documentation to read now, and to update after

### 3.1 Map lookup, both axes

- **Class axis (§9 API Symbol → Doc Index):** `grep -n "ReplenishmentOrderMaintenanceService\|ReplenishorderService\|MobileReplenishService\|ReplenishmentOrderSourceSyncService\|ReplenishGeneratorService\|StockunitRepository"` on
  `wms2-function-to-docs-map.md` → **hit, line ~213**, the `Replenishment` row, which names all five services.
  `StockunitRepository` itself: **no hit** — repositories are not indexed on this axis.
- **Feature axis (§2–§8):** `grep -n -i "replenish"` → lines 70, 71, 89 (`/replenish`, `/replenish-request`,
  `/internalOps/replenishment`). Consistent with the class axis.
- **By-name check of the unindexed folders** (because a map miss means "not indexed", not "no doc"): `ls
  3-Resources/workflows/` and `3-Resources/design/` confirm `wms2-replenish-workflow.md`, `wms2-replenish-order-creation.md`,
  `wms2-multi-unitload-replenish.md`, `wms2-replenishment-design.md`, `wms2-stockunit-design.md`. All are already linked from
  the §9 row, so the map is **not** missing anything here.

### 3.2 The docs, their `last_verified`, and exactly what the fix invalidates

| doc | `last_verified` | section the fix invalidates | why |
|---|---|---|---|
| `3-Resources/design/wms2-replenishment-design.md` | **2026-10-02** | **"Who re-sources an order — SBDEV-3608 (2026-10-02)"** table, **row 1** | Quoted verbatim in §3.3. Row 1 says *"order → current SU → target SU, **not** id-ordered — the one writer left that can ABBA with another order (bounded by 40P01 / `lock_timeout`; SBDEV-3608 P5 → **SBDEV-3637**, T3, not built)"*. The fix makes that sentence false in every clause: the order becomes id-ordered, the writer stops being "the one left", and "not built" stops being true. |
| same | ″ | **"Releases outside the cron — SBDEV-3621"**, final bullet | *"Residual, out of scope (Nam): web cancel locks the SU before the order row…"* — still true after this fix (§1.1 row 11), but the plan should say so explicitly so a future reader does not infer it was closed. |
| `3-Resources/architecture/wms2-transaction-osiv-boundary-map.md` | **2026-09-30** | **§8.5**, bullets *"Residual ABBA, bounded"* and the 2026-10-01 SBDEV-3618 changelog row | §8.5's *"Residual ABBA, bounded"* says the inverse direction *"is not eliminated by this fix (plan proposal P-S5S6, not yet implemented)"*. The SBDEV-3618 changelog row says *"The move path's order is now order → current → target, matching recalc… the cross-order residual is unchanged."* **That cross-order residual is precisely what SBDEV-3637 closes** — both statements need a successor row. The §8.5 **landmine bullet** (destination assignment → `createFixedLocationAssignment` → `triggerReplenishmentMaintenance` → `recalculateForItem` locking every other open order of the item and their SUs) is the section that states the *accumulating* lock footprint and must be re-read before the fix, not just after. |
| same | ″ | **SBDEV-3622 lock-order bullet**, *"Known bounded residuals (plan §6.1, row 4)"* | Lists three SU-before-order paths. The third — *"`recalculateForItem` holding an order and SU then reaching a redirect target's order"* — is in the blast radius. |
| `3-Resources/workflows/wms2-replenish-workflow.md` | **2026-09-06** (header), amended 2026-10-02 | the recalc/redirect narrative | Oldest `last_verified` of the three workflow docs; already carries two single-purpose 2026-10-02 amendments. A `CONTENDED` outcome is a new terminal state for a recalc tick and belongs here. |
| `3-Resources/workflows/wms2-multi-unitload-replenish.md` | 2026-09-30 | — | Writer 4's path; unchanged by this fix. Listed to be ruled out explicitly. |
| `3-Resources/workflows/wms2-replenish-order-creation.md` | 2026-09-06 | — | Creation only; unchanged. |
| `3-Resources/design/wms2-stockunit-design.md` | 2026-09-30 | §6 reservation-holder invariant | Only if `CONTENDED` changes whether a reservation is written. On the deferral design it does not — but the deferral means a reservation that *would* have moved does not, within that tick. |
| `3-Resources/architecture/wms2-function-to-docs-map.md` | **2026-08-29** (header; deliberately not bumped by 6 subsequent partial passes) | §9 Replenishment row | Add the SBDEV-3637 pointer alongside the existing SBDEV-3605/3618/3622/3606 ones, following the house convention of **not** bumping `last_verified` for a single-row touch. |

⚠ **`last_verified` on these files is close to worthless as a freshness signal and the plan should not lean on it.** Each
`verified_by` is a stack of single-section passes that explicitly say *"last_verified deliberately NOT bumped: only those rows
were checked."* `wms2-function-to-docs-map.md` reads 2026-08-29 but was edited on 2026-10-02. Read `verified_by`, not
`last_verified`.

### 3.3 The "Who re-sources an order" table, quoted verbatim

From `3-Resources/design/wms2-replenishment-design.md`, immediately under the SBDEV-3608 paragraph:

> | # | Writer | Reached from | Locks |
> |---|---|---|---|
> | 1 | `ReplenishmentOrderMaintenanceService.redirectSource` (`order.setStockunitId(candidate.stockUnitId)`) | cron recalc, `recalculateForItem`, move-time `reassignOrCancelForMovedStockUnit` | order → current SU → target SU, **not** id-ordered — the one writer left that can ABBA with another order (bounded by 40P01 / `lock_timeout`; SBDEV-3608 P5 → **SBDEV-3637**, T3, not built) |
> | 2 | `ReplenishorderService.redirectSource(Long, Long)` | web `update`, `updateStockUnit`, `changeSourceStockUnit` | order → both SUs ascending; refuses `state > PROCESSABLE` |
> | ~~3~~ | ~~`MobileReplenishService.switchSourceToUnitLoad`~~ **removed by SBDEV-3638 (merged 2026-10-02, `f839921e`)** | handheld single-UL `GET /v3/replenish/checkSource/{id}/{input}` — **API-only**: no screen dispatches it (screens deleted in mobile-ui `5200dc4`; the dead store actions removed by SBDEV-3608 P11) | order → both SUs ascending (SBDEV-3621) |
> | 4 | `MobileReplenishService.applyExplicitSourceToOrder` | handheld `POST /v3/replenish/multi-unitloads` — **the live handheld flow** (§7) | order → {old SU} ∪ scanned SUs ascending |

**Verdict on staleness: the table is NOT stale — it is current and correct.** It already lists four rows with **row 3 struck
through**, i.e. three live writers, matching my independent measurement exactly. The team lead's expectation that it "lists
four writers and is believed stale" is based on reading the row *count*; the strikethrough is the correction. Its stated
derivation method and blind spot (*"a native `UPDATE replenishorder` or a reflective setter would not show"*, with a positive
control) are both sound, and I reproduced them. **Only row 1's `Locks` cell becomes false when this fix lands.**

---

## 4. Prior plans touching the same symbols

**Derivation:** three `grep -rln` passes over `1-Projects/` + `4-Archieves/` for `ReplenishmentOrderMaintenanceService` (81
hits), `redirectSource` (37), `findByIdForUpdate` (190). Below is the **decision-relevant** subset; the long tail is
cross-references in unrelated tickets' review files.

**⚠ `status:` frontmatter on every row below is hand-written prose that nothing validates. I report it as written and label it
as such. The authoritative probe is `sbdocs/9-System/scripts/plan-state.sh <TICKET>`, which I did not run (it shells out to
git and the toolchain, and the brief forbids changing worktree state).**

### 4.1 Merge status of the named "in-flight" tickets — two instruments

**Instrument 1:** `git rev-list --left-right --count origin/develop...origin/<branch>` — right-hand count (commits in branch
not in develop).
**Instrument 2:** `git merge-base --is-ancestor origin/<branch> origin/develop`.
**Positive control for instrument 2** (a zero-scan needs one): sweeping all remote refs found genuinely unmerged branches —
`origin/bugfix/SBDEV-3017-delete-legacy-setputawaylocation`, `origin/bugfix/SBDEV-3198-dprime-stale-club`,
`origin/bugfix/SBDEV-3314-non-2xx-recorded-as-sent`, `origin/chore/flyway-v2-migration-renumber`,
`origin/chore/wms2-remove-inert-junit-bom`, `origin/claude/SBDEV-3080-redact-credentials-in-logs`. **The probe can and does
return false**, so the MERGED verdicts below are not an artefact of a broken instrument.

| ticket | branch | instr. 1 (ahead) | instr. 2 | tip | edits `ReplenishmentOrderMaintenanceService`? |
|---|---|---|---|---|---|
| SBDEV-3608 | `bugfix/SBDEV-3608-replenish-followup-cleanup` | **0** | MERGED | `5a63130f` | its content is in develop; no pending diff |
| SBDEV-3618 | `bugfix/SBDEV-3618-recalc-held-share` | **0** | MERGED | `95f032bb` | **yes — `shareOf`/`bound`/`releaseHeld`/`reassignOrCancelForMovedStockUnit` Fix D; all present at `ec42f43a`** |
| SBDEV-3621 | `bugfix/SBDEV-3621-release-held-share` | **0** | MERGED | `5d1faaca` | no (ReplenishorderService + MobileReplenishService) |
| SBDEV-3624 | `bugfix/SBDEV-3624-replenish-sweep-starvation` | **0** | MERGED | `b1612027` | no (`ReplenishOrderJob`) |
| SBDEV-3633 | `bugfix/SBDEV-3633-replenish-bulk-priority-predicate` | **0** | MERGED | `cc369f20` | no |
| SBDEV-3636 | `bugfix/SBDEV-3636-replen-cooldown-after-manual-cut` | **0** | MERGED | `dbae18e3` | **yes — `ManualCutCooldown.current(syspropService)` inside `redirectSource`; present at `ec42f43a`** |
| SBDEV-3638 | `bugfix/SBDEV-3638-remove-single-ul-replenish-endpoints` | **0** | MERGED | `87fe58f0` | no (removed `switchSourceToUnitLoad` et al.) |
| SBDEV-3605 | `bugfix/SBDEV-3605-multi-ul-release-own-share` | **0** | MERGED | `fcd6d0b8` | no (MobileReplenishService) |
| SBDEV-3622 | `bugfix/SBDEV-3622-adjust-reserved-attributes-cut` | **0** | MERGED | `a184e828` | indirectly — routes cancels through `markCancelled` |
| **SBDEV-3626** | **no remote branch exists** | — | — | — | **YES — see 4.2** |
| SBDEV-3632 | no branch; **closed as a duplicate of SBDEV-3621** | — | — | — | n/a |

**Consequence: every doc sentence of the form "branch X, unmerged / PR pending" in `wms2-replenishment-design.md` and
`wms2-transaction-osiv-boundary-map.md` is now stale.** Specifically, the design doc's `verified_by` says SBDEV-3638 is *"PR
pending, not merged"* and SBDEV-3622 is *"unmerged, stacked on SBDEV-3621 PR #444"*; git says both are in develop. This is a
doc-drift finding in its own right, independent of SBDEV-3637.

### 4.2 SBDEV-3626 — the one real collision, and its state cannot be read from its plan

`1-Projects/wms2/plan/SBDEV-3626-replenish-order-in-progress-claim.md`, "Replenish order in-progress claim (STARTED 500) so
the cron cannot cancel an order mid-pick", T3, `db_verified: true`.

- Hand-written `status:` field reads: `approved — gate tests committed c99ddaff; PARKED until SBDEV-3621 merges (Nam,
  2026-10-02)`.
- **It edits `ReplenishmentOrderMaintenanceService.java`.** Its own §"files touched" row:
  `| api service/ReplenishmentOrderMaintenanceService.java / repo/jpa/ReplenishorderRepository.java | inbound → new query / +2 non-exported queries |`,
  and its call-site audit names `ROMS:392 alignDestination, :532/:611 redirectSource, :719 updateRequestedAmount, :734 cancelOrder`
  — **`redirectSource` is explicitly in its blast radius, at two line anchors.**
- **Its stated prerequisite is now satisfied.** The plan says 3626 *"Must be merged to `origin/develop`, and this branch (gate
  commit `c99ddaff`) rebased onto it, before ANY implementation step"* w.r.t. SBDEV-3621. SBDEV-3621 **is** merged (§4.1).
  **SBDEV-3626 is therefore unparked as of `ec42f43a`** and may start moving in this same file at any time.
- **⚠ The gate commit does not exist.** `git log --oneline -1 c99ddaff` → `fatal: ambiguous argument 'c99ddaff': unknown
  revision`. `git worktree list` (53 worktrees) contains **no** `SBDEV-3626` entry. So the plan's own claim that gate tests
  are committed is not verifiable in this clone. Three readings, not distinguishable from here: (a) the commit lives in
  another clone/machine, (b) it was written and lost, (c) the SHA is wrong. **NOT ESTABLISHED.** **Probe that settles it:**
  `git -C v2/wms2-api fetch --all --prune && git cat-file -t c99ddaff`, plus a ClickUp read of
  [SBDEV-3626](https://app.clickup.com/t/868mc5hpj).
- **Sequencing recommendation:** SBDEV-3637 and SBDEV-3626 both rewrite `redirectSource`'s control flow — 3626 adds a
  `STARTED(500)` claim state that changes *which* orders the cron may touch; 3637 changes *in what order* it locks. They are
  orthogonal in intent and **colliding in text**. Land one, rebase the other. Given 3626 has (claimed) gate tests and
  3637 has not started, **3626 first is the cheaper sequence** — but that is a call for the lead, and it hinges on whether
  `c99ddaff` is recoverable.

### 4.3 Direct ancestry of this defect

| plan | status (**hand-written, unvalidated**) | relation |
|---|---|---|
| `1-Projects/wms2/plan/SBDEV-3244-concurrent-recalculate-stale-version-under-lock.md` | active dir | **The direct parent.** F3/F4 are what created the current `current→target` order (*"F3+F4 flipped the relative order of two stock-unit locks on this path (target->current became current->target)"*). The first-touch rule it established is a **constraint on this fix**: the ascending-order rewrite must keep each lock the row's first touch. |
| `1-Projects/wms2/plan/SBDEV-3618-recalc-over-grants-requested-above-stock.md` + `SBDEV-3618-evidence/` (6 files) | merged (§4.1) | Fix D added site 3; Fix E added the same-row re-point branch that sits **before** any lock in `redirectSource` and must stay before it. Fix C added `releaseHeld`. Its `architect-r1/r2` and `critic-r1/r2` evidence files are the most recent prior reasoning about this exact lock pair. **Read `SBDEV-3618-evidence/architect-r2.md` before designing the fix.** |
| `1-Projects/wms2/plan/SBDEV-3605-multi-ul-pick-releases-other-orders-reservation.md` + `SBDEV-3605-evidence/` (6 files) | merged | Established the `TreeSet` ascending pattern at writer 4 — **the implementation pattern to copy**. |
| `4-Archieves/wms2/plan/SBDEV-3561-change-source-stock-unit-state-guard.md` | archived | Established "D7 ascending-id lock order" at writer 2 — **the naming and rationale to copy** (`// Ascending-id lock order (D7): closes the redirect-vs-redirect cycle X: A->B / Z: B->A.`). Also built `AbstractReplenishRedirectPgFixture`. |
| `4-Archieves/wms2/plan/SBDEV-2074-replen-reservation-reassign-on-nonreplenishable-move.md` | archived | Created `reassignOrCancelForMovedStockUnit` and the M4 reserve-before-release ordering that `CONTENDED` must not break. |
| `4-Archieves/wms2/plan/SBDEV-2492-replen-order-source-sync-on-unitload-move.md` | archived | Created `ReplenishmentOrderSourceSyncService` (the router, §1.3). |
| `4-Archieves/wms2/plan/SBDEV-2234-replenishment-maintenance-tx-and-lock.md` | archived | Original tx+lock shape; owns `ReplenishmentOrderMaintenanceServiceIntegrationTest`. |
| `1-Projects/wms2/plan/SBDEV-3622-adjust-reserved-attributes-cut` (referenced; no top-level plan file, evidence in design doc) | merged | Added `ORDER BY r.id` to `findIdsByStateAndItemdataId` *"so recalculateForItem locks an item's orders in the same order as the attributed reserved cut does"* — **the order-level half of this fix is already done; SBDEV-3637 is the SU-level half.** That framing is worth putting in the plan's §1. |
| `4-Archieves/wms2/plan/260313-WMS_V2_Horizontal_Scaling_Concurrency_Report.md`, `260424-CONCURRENCY_FIX_PLAN.md` | archived | Background only. |
| `4-Archieves/wms2/plan/SBDEV-3560-evidence/followup-ticket-drafts.md` | evidence | Contains a `redirectSource` follow-up draft; check it for an already-worded proposal before writing a new one. |

---

## 5. Flyway / migration / config surface

**Migration: NONE needed. Confirmed.** The fix adds a repository *method* and changes a private method's return type. No
column, index, constraint or seed row. Scan for a schema dependency: the three defect sites touch `stockunit` and
`replenishorder`, both of which exist at `V2.2.00__base_v2_schema.sql`.

**Highest migration present at `ec42f43a`:** `V2.2.35__seed_replenishment_order_action_function.sql`. Total files in
`src/main/resources/db/migration/`: **37** (i.e. 35 numbered `V2.2.*` plus 2 others; listing sorted with `sort -V`).
⚠ **This is the number on `origin/develop` only.** The SBDEV-3626 plan records *"Flyway V2.2.36 … Max was V2.2.35 on
2026-10-02 on unfetched local refs"*, so **a V2.2.36 may already be claimed on a branch not fetched here.** Per the standing
rule, a Flyway sweep must run across **all** remote branches immediately before merge, and a sweep run now cannot catch a
branch pushed later. If SBDEV-3637 ends up needing a migration (it should not), do not take 36.

**`wms.tenant.lock-timeout-ms`:**
- Default in the Spring binding: `@Value("${wms.tenant.lock-timeout-ms:3000}")` in
  `landlord/config/TenantDatabaseConfig.java`.
- Configured value: `wms.tenant.lock-timeout-ms=3000` in `src/main/resources/application.properties`.
- Two instruments agree at 3000.
- Applied as `SET LOCAL lock_timeout` at tenant-transaction begin by `LockTimeoutHibernateJpaDialect`
  (`statement.execute("SET LOCAL lock_timeout = " + lockTimeoutMillis)`), **per lock ACQUISITION, not per statement**.
- Overridable per environment without a rebuild via `WMS_TENANT_LOCK_TIMEOUT_MS`.
- **Load-bearing for this plan's ACs:** the properties comment records that the FLOOR is `> 1000ms` because PostgreSQL's
  `deadlock_timeout` is 1000 (measured default on Hydra prd and WineCo UAT) — *"At or below that, a genuine deadlock is killed
  as a generic 55P03 lock_not_available BEFORE the detector fires — destroying the 40P01 log line."* **So an AC written as
  "no 40P01 occurs" can be satisfied by a 55P03 instead, and a test that asserts only on 40P01 can go green for the wrong
  reason.** Assert on SQLSTATE explicitly, both values.
- ⚠ `SET LOCAL lock_timeout` is PostgreSQL syntax and **H2 rejects it** — the dialect logs *"Tenant lock_timeout is NOT being
  applied"* and continues. No H2-lane test can observe the bound.

**Replenish cron cadence sysprop:**
- Key: `REPLENISHMENT_RECALCULATION_CADENCE_SECONDS` (`WmsConstants.SYSTEM_PROPERTY_REPLENISHMENT_RECALCULATION_CADENCE_SECONDS_KEY`), **default `"0"`**.
- **Read in exactly one place:** `service/ReplenishmentOrderMaintenanceService.java` (~line 348–349),
  `syspropService.getSysvalue(WmsConstants.SYSTEM_PROPERTY_REPLENISHMENT_RECALCULATION_CADENCE_SECONDS_KEY)` then
  `long seconds = parseLong(sysValue, …_DEFAULT_VALUE)`. Derivation: `git grep -n "REPLENISHMENT_RECALCULATION_CADENCE_SECONDS" -- src/main/java`
  minus the `WmsConstants.java` declarations. Positive control in the same scan: the sibling key
  `SYSTEM_PROPERTY_REPLENISHMENT_TIMER_ACTIVATED` returns 4 hits across `ReplenishOrderJob.java` and `UtilRestController.java`,
  so the instrument finds sysprop reads elsewhere in `src/main`.
- The separate **master gate** is `REPLENISHMENT_TIMER_ACTIVATED` (default `"true"`), read twice in
  `schedulejob/ReplenishOrderJob.java` (~:296, ~:396) alongside `NEW_CRON_JOB_ACTIVATED`.

**No new `FunctionEnum` constant, no new endpoint, no SDR surface change.** The fix is entirely below the controller layer, so
the gating programme, `FunctionGuardArchTest` and the SDR withdrawal tests are all out of scope.

**`findByIdForUpdateSkipLocked` — one implementation note for the plan.** There is exactly one `SKIP LOCKED` precedent in
`src/main`: `OutboxMessageRepository.findAndClaimPending`, written as a **native query** (`FOR UPDATE SKIP LOCKED` inside a
text block), *not* as `@Lock` + a hint. The repository-level comment in `StockunitRepository` explains why a hint-based
approach is treacherous here: `PostgreSQLDialect.withTimeout` *"translates only 0 (NO_WAIT) and -2 (SKIP_LOCKED) and returns
the lock string unchanged for every other value"* — so `-2` **would** work via `@QueryHint`, but this is the same mechanism
that was **inert for years** at SBDEV-3250 and was only caught by `TenantLockTimeoutIT`, never by a unit check. **Recommend
the native-query form, matching the only working precedent, and a test that proves a second session is skipped rather than
blocked — a hint that silently does nothing looks identical to a lock that was never contended.**

---

## 6. NOT ESTABLISHED

| question | probe that settles it |
|---|---|
| Does SBDEV-3626's gate commit `c99ddaff` exist anywhere? | `git -C v2/wms2-api fetch --all --prune && git cat-file -t c99ddaff`; then ClickUp [SBDEV-3626](https://app.clickup.com/t/868mc5hpj) |
| Is a `V2.2.36` already claimed on an unfetched branch? | `git fetch --all --prune` then the all-remote-branch Flyway collision sweep |
| Has the cross-order ABBA ever actually fired in production? | `SELECT deadlocks FROM pg_stat_database` on each tenant DB + a `replenishorder`/`stockrecord` scan for aborted recalc ticks. The in-code comment asserts *"No production occurrence has been observed, and Hydra prd has never held a replenishorder row"* — **the second clause is superseded**: v2 prd has thousands of replenishorder rows since WineCo/ShipItEZ went live. **Re-query; do not reuse that sentence.** |
| Is the 9984–9998 IT id band still free for a second order/SU pair? | `git grep -n -E "99[0-9]{2}L" -- src/test` (the A0 sweep) |
| Does any bulk `@Modifying` statement outside `StockunitRepository` lock `stockunit` rows? | `git grep -n -B5 "update +stockunit\|UPDATE Stockunit" -- src/main/java/net/aim_ai/wms/repo` with `@Modifying` context |
| Which `recalculateForItem` callers can be holding other locks when the sweep starts? | call-graph from `triggerReplenishmentMaintenance` — the OSIV map §8.5 landmine names `StockunitService.transferStock` and `assignDestinationForMultiUnitLoads`, but that is a list, not a derivation |
| Suite baseline to compare a post-fix run against | run the full suite yourself, adjacent in time; there is no single correct number for this repo |
