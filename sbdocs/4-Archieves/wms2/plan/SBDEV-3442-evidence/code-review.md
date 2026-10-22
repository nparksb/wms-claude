---
ticket: SBDEV-3442
kind: code-review (T2, lane 1 of 2: correctness + design conformance)
commit: ee523d44 (bugfix/SBDEV-3442-scandestination-row-lock), diff origin/develop...HEAD
worktree: .claude/worktrees/wms2-api/SBDEV-3442
date: 2026-09-24
reviewer: independent code-reviewer lane (read-only; no Maven run, per lane rules)
---
# SBDEV-3442 code review — lane 1 (correctness + design conformance)

## Verdict: APPROVE (with 1 Medium + 7 Low to fix before merge, per the "fix Lows" policy)

The 2-file production change follows architect-consult option 1 exactly. The locking finder at
`MobileMoveUnitloadService:318` is the first row lock in the transaction and the source's first touch on
every path except the accepted N3 fallback (plus one sub-case of it, L7). The resolver swap
`findByLabelid(..).isPresent()` → `existsByLabelid` does not change behaviour for any of its five callers.
The IT and the unit rail together kill every realistic regression of `:318`, and no existing assertion was
weakened: one was strengthened. **Every finding is in the call-site comment, the test documentation, or
behaviour the comment does not record. None is a code defect in the fix itself.** The one Medium is a
factually inverted claim in the new comment (the N2 partner).

Instruments: `git diff`, targeted reads of the worktree only, and `grep`. I did not run LSP or Maven (lane
rule). For compile and green status I rely on floor.md (101 unit + 2 IT green, M1/M2 killed).

---

## Stage 1 — spec compliance

| Ask (ticket + consult option 1) | Status |
|---|---|
| Source resolved with a row lock before any guard | Done: `:318` `findByLabelidForUpdate`, before `assertNotNirvanaSentinel` and all SBDEV-3490 guards |
| Resolver exact probes do not hydrate the entity (SBDEV-3244 first-touch) | Done: `ScannedCodeResolver:129`, `:174` |
| Per-branch order + N1/N2/N3 recorded at the call site | Done, but with errors (M1, L1, L2) |
| No pallet-first lock, no dest lock, Location lock not moved | Honoured |
| Resolver unit test + row-granular probe IT + mutation checks | Done (floor.md). The consult's "N3-free control: re-lock in branch (b) under a concurrent version bump" IT was **not** written. Branch (b) is untested under contention, which the IT javadoc admits. Acceptable at T2; noted, not a finding. |

## Answers to the five specific checks

**1. First touch.** Lines 289–317 contain only the two resolver calls. `canonicalUnitLoadLabel` now makes
exactly one query (`existsByLabelid`, scalar) on an exact hit. `canonicalDestinationCode` loads a
**Location** entity (`findByName`, pre-existing, which is why `UBS:245` upgrades and then refreshes) and makes
a scalar UL probe. OSIV is off (`application.properties:85 spring.jpa.open-in-view=false`), and
`MoveUnitloadController:75` loads nothing first, so no earlier persistence context can carry the entity in.
The only entity-loading routes before `:318` are the case-insensitive fallbacks. For the source that is
N3, which is accepted. There is one sub-case the comment does not name: see L7.

**2. Other resolver callers**: `MobileMoveUnitloadService:139` (scanUnitLoad), `MobileMoveStockService:119`,
`StockunitService:341`, and `StockUnitController:789` via `canonicalUnitLoadLabelForProbe`. None of them
depends on the entity being managed after the call; each re-queries by label, and a derived query always hits
the DB. The semantics are equal:
- Both use PG `=` on `labelid`, which is case-sensitive.
- `labelid` is UNIQUE (`uq_unitload_labelid`), so `findByLabelid` could never throw
  IncorrectResultSize, and `exists` cannot diverge from it.
- `null`/blank is short-circuited by `isBlank` before either call.
- Auto-flush behaviour is the same: both are JPQL queries over `Unitload`.
- Net effect is one fewer entity hydration per exact hit.
- `existsByLabelid` already existed (SBDEV-3398) with `@RestResource(exported = false)`, so the change adds
  no new SDR surface.

**3. Call-site comment accuracy.** N1 is accurate, and so is N3 for the source. The claims "first row lock"
and "first touch" hold, qualified by N3. **N2 names the wrong partner (M1).** The per-branch table leaves out
the transferStock arms of the container branch (L1) and the writes that come before the Pickingorder lock
(L2).

**4. Test quality.**
- IT test 1 ("xid NULL while blocked"):
  - Sound for Location, writes, and any lock taken on a row this fixture actually has. PG assigns an xid
    only inside `heap_lock_tuple` *after* the wait, or at the top of `heap_update`/`heap_insert`. So a NULL
    `backend_xid` while blocked means no earlier row lock and no earlier write.
  - The pinning is sound: exactly one pid blocked by the holder, and the statement re-confirmed via
    `BlockedBackendReads`.
  - It cannot see a Pickingorder-first mutant, because the fixture has no stock (L3). It leaves the
    post-lock outcome unasserted (L4). There is a tiny xid-read window (L5).
- IT test 2 (holder commits a move to Shipped plus a version bump) is the strong one:
  - It kills M1 (unlocked read → optimistic-lock failure at flush).
  - It kills M2 (resolver re-hydrates → upgrade version check).
  - It kills a late `findByIdForUpdate` mutant (upgrade → optimistic-lock failure).
  - It kills a late `em.refresh(PESSIMISTIC_WRITE)` mutant: the guards already passed, the move completes,
    and the outcome is null ≠ BusinessException.
  - Tests 1 and 2 together are not vacuous for the claim "locked, then judged".
- Fixture cleanup is FK-ordered and scoped by tag. If a completed move in test 1 left undeletable residue,
  the `@AfterEach` would fail loudly. The 30 s deadline against the lane's 10 s lock timeout and a 100 ms
  poll is fine, and the `worker.isDone()` fast-fail stops the probe from measuring nothing.
- Unit rail `scanDestination_shouldLockTheSourceBeforeAnyGuard`:
  - The lenient `findByLabelid` stub means a revert runs on and fails on `never()` by name, as intended.
  - `InOrder` pins lock before `findById(SHIPPED_LOCATION_ID)`. Sound.
- Resolver tests: under STRICT_STUBS, an `existsByLabelid` stub left unused plus `never().findByLabelid`
  kills the revert.
- **No existing assertion was weakened.**
  - Every stub swap `findByLabelid` → `findByLabelidForUpdate` is on a `scanDestination` test. The remaining
    `findByLabelid` stubs are all on `scanUnitLoad` tests, or on *destination* labels (`PALLET-9`,
    `PM-000B/C`) that `:450` still reads unlocked.
  - The `PKG-0001` stub (`MobileMoveUnitloadServiceUnitTest:1431`) was already `lenient()` before the
    change.
  - `testScanDestinationPropagatesAnAmbiguousDestinationRefusal` gained a `never().findByLabelidForUpdate`
    and kept its `never().findByLabelid`. That is strictly stronger.

**5. Previously-successful moves that now fail.** A concurrent commit on the source after the resolver
already failed pre-fix at the versioned flush `UPDATE`, so the N3 409 is not new. Every branch already took
the source row lock eventually, pre-fix: the flush UPDATE in (a) and (c), and `StockunitBusinessService:237`
in (b). Lock-timeout exposure on a *completing* move is therefore unchanged. What is new, and not recorded, is
L6: **refusal** paths now wait for the lock.

---

## Findings

### [Medium] M1 — N2 names the wrong cycle partner: UL→SU *matches* closeBOL; it inverts Move Stock
File: `src/main/java/net/aim_ai/wms/service/mobile/MobileMoveUnitloadService.java:315`
```java
//   N2 UL(source) before Stockunit on the flow-bin branch inverts closeBOL's order;
```
Confidence: HIGH.
closeBOL's measured table order is `Billoflading → Unitload → Stockunit → …`
(`MobilePalletizeWriteService.java:112-115`, from `ClosebolLockOrderProbeIT`). UL(src)→SU therefore
**agrees** with closeBOL. The order it inverts is `StockunitBusinessService.transferStockToUnitLoad`'s SU→UL
(`findByIdForUpdate` SU at `:201`, then UL at `:237`). architect-consult.md states this correctly: *"The
partner is a concurrent Move Stock off the same source … closeBOL's measured table order is UL→SU … and it
already contradicts transferStockToUnitLoad's SU→UL."* The comment compressed that into its opposite.
Failure scenario: someone chasing a 40P01 between Move Unit Load and a concurrent Move Stock reads this
comment, looks at closeBOL, finds the orders consistent, and concludes N2 cannot fire. Or someone "fixes"
closeBOL to SU-first to match this path, which reintroduces the palletize ABBA that SBDEV-3418/3419 closed.
Fix: `N2 UL(source) before Stockunit (every transferStock arm) inverts transferStockToUnitLoad's SU->UL
(a concurrent Move Stock off the same source); it matches closeBOL's UL->SU, and no order satisfies both.`

### [Low] L1 — the per-branch table misses the transferStock arms of the container branch
File: `MobileMoveUnitloadService.java:308-311, 315`
```java
//   flow bin  UL(source) -> Pickingorder -> Stockunit -> ... -> Location
//   container UL(source) -> (FOR KEY SHARE on the destination pallet via the carrier FK)
```
Confidence: HIGH.
`transferStock` (Pickingorder → SU → UL …, the branch-(b) order) is called from **three** sites, not only the
flow bin:
- `:439` flow bin
- `:481` container with `dto.isMoveStock()`
- `:495` container whose destination UL has a fixed assignment

Only `:490` (`transferUnitLoadToCarrier`) matches the "container" line. N1 and N2 therefore also apply on two
container sub-paths, and "on the flow-bin branch" under-states N2. The consult's own branch (b) lists
`:422/:478` (develop numbering) and misses `:464` = HEAD `:481`, so the gap was inherited.
Even the `:490` line is incomplete: `processTransfer` (CODE_TRANSFER = BLOCK_REALIGN) then writes
`pickingorder_position` (realign) and takes Replenishorder NKU (consult (a)5 / (c)4), which the line omits.
Failure scenario: a later change to `transferStock` or `transferUnitLoadToCarrier` is judged against a table
that says the container path takes only a KEY SHARE.
Fix: key the table by callee instead of by destination kind:
- `transferUnitLoadToLocation (:408)`
- `transferStock (:439, :481, :495)`
- `transferUnitLoadToCarrier (:490) UL(source) -> KEY SHARE(dest) -> pickingorder_position/Replenishorder writes`

Say N1/N2 apply to every `transferStock` arm.

### [Low] L2 — writes that come before the Pickingorder lock are not in the table (damaged sub-path, creates)
File: `MobileMoveUnitloadService.java:307-309`, with `setStockDamaged` `:717-746`, `removeStockDamaged` `:754-780`,
`createFixedLocationAssignment` `:434`, `createUnitload` `:468`.
Confidence: MEDIUM. This rests on Hibernate AUTO-flush, not on a measurement.
- **Location branch, damaged source or damaged destination.** `setStockDamaged`/`removeStockDamaged` dirty
  the tree's Stockunits (and call `messageService.sendStockChangeMessage`) *before*
  `transferUnitLoadToLocation`. `collectStockUnitIdsForUnitloadTree` (`PickLineRealignmentService:183`) then
  runs `stockunitRepository.findByUnitloadId`, a Stockunit query, so AUTO-flush emits those UPDATEs first.
  The real order is `UL(src) → SU(tree) NKU → Pickingorder → Location`, not `UL → Pickingorders → Location`.
  SU-before-PO is pre-existing. UL-before-SU on this branch is the N2 shape again, on a branch the comment
  says N2 does not touch.
- **Flow bin without a fixed assignment (`:434`) and inbound-pallet creation (`:468`)** INSERT unitload,
  unitload_record and fixlocationassignment rows (IDENTITY → immediate flush) before the transfer. These
  assign the xid and take FK KEY SHARE locks before the Pickingorder lock.

Failure scenario: same as L1. The table is presented as "the lock order that follows", so readers will trust
it as complete.
Fix: add to the location line `(damaged in/out: tree Stockunit UPDATEs flush before Pickingorders)`, and to the
flow-bin and container lines `(may INSERT a unit load / fixed assignment first)`. Or state once, above the
table, that the table lists row locks from the transfer call onward and name the pre-transfer writes.

### [Low] L3 — IT test 1 claims it excludes a Pickingorder-first lock, but its fixture has no Pickingorder
File: `src/test/java/net/aim_ai/wms/integration/service/mobile/MoveUnitloadLockOrderProbeIT.java:58-61, 138-141`
```java
 *       row lock or write, so a NULL {@code backend_xid} while blocked means the source lock is the
 *       first lock this transaction takes: no Pickingorder, no Location, no write came before it.
...
                        + "destination Location, a Pickingorder — was taken BEFORE the source lock",
```
Confidence: HIGH.
The fixture unit load has no stock units. `lockOwningPickingorders` returns at once on an empty id list
(`PickLineRealignmentService:146-148`), so a mutant that pre-locked Pickingorders ahead of `:318` would lock
nothing here and keep `backend_xid` NULL. The assertion is sound for what exists (Location, writes); the
claim reaches further than the fixture.
Fix: either narrow the javadoc and message to "no Location lock and no write", or seed one stock unit plus one
`pickingorder_position` whose pickingorder exists (state any, since the lock has no state filter) so the
pre-walk has a row to lock. Then mutation-check it by hoisting the PO pre-walk.

### [Low] L4 — IT test 1 does not assert the move completed after the holder rolls back
File: `MoveUnitloadLockOrderProbeIT.java:126-143`
Confidence: MEDIUM.
floor.md records "move then completed (outcome null)", but no assertion pins it. A regression that locks
correctly and then fails afterwards, for example an exception caused by the lock itself, would stay green in
test 1. Test 2 only covers the refusal path.
Fix: `assertThat(probe.outcome()).as("after the holder rolled back, the move must complete").isNull();` and
assert `storagelocation_id` = DEST.

### [Low] L5 — `backend_xid` is read in a third statement, outside the confirmed-blocked read
File: `MoveUnitloadLockOrderProbeIT.java:219-224`
Confidence: LOW.
The statement is confirmed as blocked by the holder, and the xid is then read by `pid` alone. Suppose the
worker left the wait between the two reads, for example on the lane's 10 s `lock_timeout`, and its
transaction aborted. `backend_xid` would then read NULL for a mutant that *did* hold an xid. The window is one
round trip, so this is near-theoretical.
Fix: read both in the confirming statement:
`select query, backend_xid::text from pg_stat_activity where pid = ? and <holder> = ANY(pg_blocking_pids(pid))`.
This could be a sibling helper next to `confirmedBlockedStatement`, whose javadoc already explains why that
snapshot is stable.

### [Low] L6 — refusal paths now wait on the source lock; this is not recorded
File: `MobileMoveUnitloadService.java:318` onward
Confidence: HIGH that the behaviour exists. Impact is small.
Pre-fix, every business refusal after `:318` answered immediately, even while another transaction (closeBOL
over a large BOL, scanGate/scanPallet, a Move Stock) held the source row. Examples: "No destination found",
"Pallet not empty!", "No permission to alter damaged stock", the Nirvana/Shipped destination refusals, and
`assertNotNirvanaSentinel`. Now each refusal waits for the lock, and under the global lock timeout it becomes
a lock-timeout error instead of the business message. The lock is also held across the whole guard section,
not just from flush to commit, which lengthens waits for the partners above.
One sub-case is also absent from the comment: a scan of the **Nirvana sentinel** label now takes NKU on the
shared sentinel row before `assertNotNirvanaSentinel` refuses it. Discards lock that row as a destination
(`StockunitBusinessService:249`).
Failure scenario: an operator scans a wrong destination while closeBOL runs on the source's BOL. The error
shown is lock-timeout/409 rather than "No destination found".
Fix: record it in the comment as an accepted consequence ("refusals are now decided under the lock, so they
wait for it too"). No code change needed. Guards run under the lock by design.

### [Low] L7 — N3 is stated for the source field only; the destination fallback can also hydrate the source
File: `ScannedCodeResolver.java:172-181` (`canonicalDestinationCode`), `MobileMoveUnitloadService.java:316-317`
Confidence: HIGH that the path exists. Impact is negligible.
Take a destination that is the source's label in a different case (e.g. source `UL-1`, destination `ul-1`)
with no exact hit. `findAllByLabelidIgnoreCase` loads the source entity, and `:318` becomes an upgrade. The
request is then refused as `CARRIER_SELF_REFERENCE` anyway, or with a stale-version 409 if the source changed
concurrently.
Fix: widen N3 to "a label resolved only case-insensitively, in either field". No code change.

### [Low] L8 — the canonicalisation call feeding the lock survives PIT (untouched line, now load-bearing)
File: `MobileMoveUnitloadService.java:294` (pit-mutations.xml: `scanDestination` line 294 SURVIVED)
Confidence: HIGH.
Removing `dto.setUnitLoadLabel(scannedCodeResolver.canonicalUnitLoadLabel(...))` survives. `:318` locks by
`dto.getUnitLoadLabel()`, so a case-mismatched source label would then fail as `EntityNotFoundException` and
no test would notice. The line is pre-existing and was not touched by this diff. It is listed because the
lock now depends on it.
Fix: a unit test where the resolver maps `ul-001` → `UL-001`, which verifies
`findByLabelidForUpdate("UL-001")`.

---

## Open questions (low-confidence, non-blocking)
- None rated High/Critical. (L5 is low-confidence but Low severity, so it stays in the list above.)

## Positive observations
- The design uses the smallest diff that can work. The first-touch hazard (SBDEV-3244) is handled at its
  source, the resolver probe, instead of with `em.refresh`, which the house rule forbids. The resolver
  comment explains why.
- IT test 2 is a good oracle. It asserts the *business* outcome judged on committed state, so it discriminates
  "no lock", "late lock", "late refresh" and "re-hydrated before lock", which are four distinct mutants, with
  one assertion.
- The unit rail stubs the unlocked finder on purpose, so a revert fails by name instead of on a not-found.
  This is the right defence against a false red.
- The ambiguous-destination test was strengthened, not relaxed, and the stub swaps are complete under
  STRICT_STUBS.
- The call-site comment records accepted residuals, with the exposure measurement, at the point where the next
  editor will look. After M1/L1/L2 it will be accurate as well.
- The mutation checks in floor.md are attributable (named assertion and message per mutant), including
  M2 staying green in test 1 as predicted. That confirms the two tests are not redundant.

## Recommendation
**APPROVE.** Before the PR, fix M1 (a one-line comment correction) and L1–L4, L6–L8 (comments, test
javadoc, and two small assertions). L5 is optional hardening.
