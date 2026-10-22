# SBDEV-3442 re-review of fix commit 2f0ceb04 (independent lane, round 2)

Reviewed: `git diff ba03785c..2f0ceb04` in `.claude/worktrees/wms2-api/SBDEV-3442` (4 files, +57/-22).
Inputs: `re-review.md` (10 Lows against `ba03785c`), `review-fixes.md` (author's "how each was handled").
Method: read-only, no Maven (a full suite was running on this worktree). Verified claims by reading
`MobileMoveUnitloadService.java`, `MoveUnitloadLockOrderProbeIT.java`, `BlockedBackendReads.java`,
`TestClassTransactionManagerArchTest.java`, `UnitloadService.getNirvana`, and
`PickLineRealignmentService.lockOwningPickingorders`.

## VERDICT: APPROVE — 0 Critical, 0 High, 0 Medium, 0 Low

All 10 Lows from `re-review.md` are resolved as claimed, several with a stronger fix than the
suggested wording. No new defect found. The one item left genuinely open (Open Questions below) is a
pre-existing, low-confidence textual nit that was never one of the 10 Lows and does not block.

## 1. Finding-by-finding resolution (the 10 Lows from re-review.md)

| # | Claimed | Verified |
|---|---|---|
| 1. "measured ... by MoveUnitloadLockOrderProbeIT" overclaim | Fixed | YES. `MobileMoveUnitloadService.java:309-311` now reads "measures it for the location branch against the destination Location lock only: its fixture holds no stock, so it cannot see a Pickingorder lock" — states the IT's actual blind spot, stronger than the suggested one-clause fix. |
| 2. Assertion message still names "a Pickingorder" | Fixed | YES. `MoveUnitloadLockOrderProbeIT.java:138` now reads "in this stockless fixture, the destination Location — was taken BEFORE the source lock". No stray "Pickingorder" left. |
| 3. CR L4 half-done: outcome asserted, destination not | Fixed | YES, and sound (see §2). `MoveUnitloadLockOrderProbeIT.java:148-151` adds the DEST-location assertion almost verbatim to the reviewer's suggested fix. |
| 4. N2 partner list reads as closed (2 of ~12 families) | Fixed | YES. `:322-324` now reads "any concurrent transferStockToUnitLoad on the same unit load (it has many callers: Move Stock, pick confirm, putaway and replenish among them)" — open-ended, matches the fix's intent exactly. |
| 5. Nirvana-sentinel sub-case unrecorded | Fixed | YES and accurate (see §3). `:331-334` adds "That includes a scan of the shared Nirvana sentinel label, which now briefly locks that row before assertNotNirvanaSentinel refuses it." |
| 6. `BlockedBackendReads` duplication + import javadoc-only | Fixed | YES, fully — not just documented. New `BlockedBackendReads.Confirmed` record + `confirmedBlockedStatementAndXid` (`BlockedBackendReads.java:77-96`), called from the IT (`:255-256`), plus the "seen but unconfirmed" case now throws `LEFT_WAIT_BEFORE_CONFIRMED` (`:268-269`) like its siblings. See §4 for sibling-probe impact (none). |
| 7. "describe one instant" wording | Fixed | YES and accurate (see §5). The inline comment was replaced by `Confirmed`'s own javadoc: "The two values come from one status copy, and a blocked backend cannot take another lock or write while it waits, so the xid read here is the one it held while blocked on the holder." |
| 8. N2 "0 overlaps" basis not recorded | Fixed | YES. `review-fixes.md`'s last section records the section-4 `stockrecord` join, its 6-row result, and the RECEIVING-rows-as-positive-control reading, as "the N2 exposure instrument." |
| 9. "right after this lock" (Damaged) imprecise | Fixed | YES and accurate (see §3). `:325-326` now reads "update the stock units after the guards, and those updates reach the database at the next flush, before any Pickingorder lock." |
| 10. N1 "now deadlocks" unconditional | Fixed | YES and accurate (see §3). `:317-320` now reads "...so when that tree has stock backing a pick line, a concurrent move of one of its children can deadlock where both used to queue on the Pickingorders." |

## 2. `MoveUnitloadLockOrderProbeIT` test 1's new DEST assertion — sound, not vacuous

```java
Long destId = jdbcTemplate.queryForObject("select id from location where name = ?", Long.class, DEST_LOCATION);
assertThat(jdbcTemplate.queryForObject("select storagelocation_id from unitload where id = ?", Long.class, sourceId))
        .as("the completed move must have put the source on DEST")
        .isEqualTo(destId);
```
- `run(...)` (`:220`) blocks on `worker.get(90, TimeUnit.SECONDS)` before constructing `Probe`, so by the
  time this assertion runs, `scanDestination` has either returned normally or thrown — its
  `@Transactional` has already committed or rolled back. The follow-up `jdbcTemplate` read (a separate
  connection) therefore sees final, committed state, not a race.
- The fixture seeds the source at `SOURCE_LOCATION`, distinct from `DEST_LOCATION` (`seed()`, `:97-108`),
  so the assertion can only pass if the source actually moved — it is not trivially true from the
  fixture's initial state.
- Combined with the preceding `probe.outcome()).isNull()` (no exception), this closes exactly the gap
  the original CR L4 flagged: null-outcome alone proved no exception, not that the move happened.
- The author's claimed mutation check (flipping the location branch's `isMoveStock` refusal turns this
  assertion red with "no such element"/wrong location, while the earlier block-order readings stay
  green) is consistent with the code path — the guard sits inside the location branch, after the point
  the block-order readings measure.

## 3. New/changed comment claims checked against `MobileMoveUnitloadService.java`

- **N2 Damaged flush-timing** (`:325-326`, "update the stock units after the guards, and those updates
  reach the database at the next flush, before any Pickingorder lock"): `setStockDamaged`/
  `removeStockDamaged` are called at `:383`/`:388`, strictly after the Nirvana guard (`:342`), the
  source-location guards (`:350-356`), the ON_HOLD guards (`:358-367`), the fixed-assignment guard
  (`:370-372`) and `checkReservedStock` (`:374`) — "after the guards" is accurate. The calls are plain
  repository `.save()`s inside a JPA/Hibernate transaction, so the UPDATE reaches the DB only at the
  next auto-flush (confirmed by re-review.md §1's finding CR L2, unchanged by this commit) — "next
  flush" is accurate.
- **Nirvana sentinel sub-case** (`:331-334`): `UnitloadService.getNirvana()` (`:255-274`) resolves the
  sentinel via **unlocked** `unitloadRepository.findByLabelid(...)`, so `getNirvana()` itself takes no
  lock. But if the *scanned source label* is the sentinel's, the row lock comes from the earlier
  `findByLabelidForUpdate(dto.getUnitLoadLabel())` at `:335`, which resolves "the source" — i.e., the
  sentinel row — under `FOR UPDATE`, before `assertNotNirvanaSentinel` (`:342`) throws. Pre-fix, the
  source was resolved with an unlocked `findByLabelid` (per this IT class's own javadoc), so this is a
  genuinely new coupling introduced by the fix, not a restatement of prior behavior. The claim is
  accurate.
- **N1 conditional** (`:317-320`, "when that tree has stock backing a pick line ... can deadlock"):
  `PickLineRealignmentService.lockOwningPickingorders` (`:144-147`) returns immediately when
  `stockUnitIds` is null or empty — confirmed by direct read. The deadlock cycle genuinely requires the
  tree to contain stock backing a pick line; the conditional wording is accurate and the previous
  unconditional "now deadlocks" was the overclaim it replaces.

## 4. `BlockedBackendReads` — new members and sibling-probe impact

- `Confirmed(String statement, String xid)` (record) and `confirmedBlockedStatementAndXid(Connection,
  int, int)` are purely additive to `BlockedBackendReads.java` — the existing `confirmedBlockedStatement`
  method and `LEFT_WAIT_BEFORE_CONFIRMED` constant are untouched (diff shows only insertions after the
  original method).
- Grepped all four probes' call sites: `ClosebolLockOrderProbeIT.java:398,428`,
  `PalletizeLockOrderProbeIT.java:455,472`, and `MobileTruckLoadingLockOrderProbeIT.java:403,433` (found
  under `src/test/java/net/aim_ai/wms/integration/service/{,mobile/}`) all still call the original
  `confirmedBlockedStatement`/`LEFT_WAIT_BEFORE_CONFIRMED`. None reference the new record or method.
  **The three existing probes are unaffected.**
- The new method's query, record accessors (`confirmed.statement()`, `confirmed.xid()`), and the
  `Blocked` record constructed from them (`MoveUnitloadLockOrderProbeIT.java:257-258`) all line up
  syntactically; no LSP/Maven available in this read-only lane, but no signature mismatch found by
  inspection.

## 5. `Confirmed`'s javadoc reasoning — accurate

"The two values come from one status copy, and a blocked backend cannot take another lock or write
while it waits, so the xid read here is the one it held while blocked on the holder."
- Per `confirmedBlockedStatement`'s own (unchanged) javadoc (`:36-49`), a single `pg_stat_activity`
  query first copies every backend's status row (which includes both `query` and `backend_xid`) and only
  then evaluates `pg_blocking_pids()` per row against the live lock manager. So `query` and `xid` do come
  from the same status copy — accurate, and it correctly avoids the earlier ("describe one instant")
  wording's implication that the block-confirmation and the xid read are simultaneous in wall-clock time
  (they are not: the snapshot is copied first, `pg_blocking_pids()` is evaluated afterward for that row).
- The validity argument holds: a backend that is confirmed still-blocked by `holderPid` at
  `pg_blocking_pids()`-evaluation time cannot have taken a new lock or write in between (it never left
  the wait), so the xid captured in the same status copy is still the one it held throughout.

## 6. `TestClassTransactionManagerArchTest` `EXEMPT_NON_TRANSACTIONAL` entry — justified and accurate

```java
// SBDEV-3442. Deliberately non-transactional: a holder connection parks on the source unitload
// row while scanDestination runs on a worker in its own transaction; a test-managed transaction
// would own the fixture rows and hide the contention. Writes only SBDEV3442-prefixed rows, which
// it deletes before and after each test.
"net.aim_ai.wms.integration.service.mobile.MoveUnitloadLockOrderProbeIT",
```
- Field name confirmed: `private static final Set<String> EXEMPT_NON_TRANSACTIONAL` (`:164`).
- `MoveUnitloadLockOrderProbeIT` is annotated `@Transactional(value = "tenantTransactionManager",
  propagation = Propagation.NOT_SUPPORTED)` (`:78`), matching the comment's premise.
- The three-session shape (holder / worker / observer on separate JDBC connections, `run()` at
  `:185-227`) matches the pattern already accepted for the sibling entries directly above it
  (`ClosebolLockOrderProbeIT`, the `MobileTruckLoadingLockOrderProbeIT` base) — a test-managed
  transaction would indeed make the holder's `FOR UPDATE` invisible to the worker.
- `TAG = "SBDEV3442"` (`:84`) and `deleteResidue()` (`:116-120`) is called from both `@BeforeEach seed()`
  (`:99`) and `@AfterEach cleanUp()` (`:112`) — "Writes only SBDEV3442-prefixed rows, which it deletes
  before and after each test" is literally true.

## Open Questions (not blocking — surfaced only)

None at HIGH confidence. One pre-existing LOW-confidence textual nit was already flagged as optional in
`re-review.md` finding 11(a) (the second assertion's "describe a guard, not the move" wording at
`MoveUnitloadLockOrderProbeIT.java:144-146`) and was correctly left unchanged in this commit — it was
never one of the 10 numbered Lows requiring a fix, only a "minor test observation." No new instance of
it, or anything like it, was introduced by this commit.

## Positive Observations

- Finding 6's fix goes further than requested: rather than merely accepting the duplication, the author
  extended `BlockedBackendReads` with a proper sibling method + record, and additionally closed the
  latent "seen but never confirmed" gap that the inline copy had silently reproduced, bringing this probe
  in line with its three siblings' timeout semantics.
- Finding 1, 4, 9, and 10's rewrites are more precise than the literal suggested fixes (e.g. 4 uses an
  open-ended "among them" instead of hand-naming a fourth caller family, avoiding the same prose-rots
  failure mode called out elsewhere in this codebase's memory).
- The new DEST-location assertion in test 1 is a real strengthening of the IT, not a cosmetic add — it
  closes the gap between "no exception" and "the move actually happened."
- All four resolutions I could independently re-derive from source (Nirvana sentinel, Damaged flush
  timing, N1 conditional, EXEMPT_NON_TRANSACTIONAL wording) checked out exactly against the code, with no
  overclaim left behind.

## Recommendation

APPROVE
