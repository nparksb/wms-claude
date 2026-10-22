# SBDEV-3442 re-review of review-fix commit ba03785c (independent lane)

Reviewed: `git diff ee523d44..ba03785c` in `.claude/worktrees/wms2-api/SBDEV-3442` (3 files, +61/-21), with `origin/develop...HEAD` for context.
Method: read-only. Code read at HEAD; no Maven run (a suite was running on this worktree). One read-only Hydra prd query (section 4).

## VERDICT: APPROVE — 0 Critical, 0 High, 0 Medium, 10 Low

All 12 review findings are resolved or have a reasoned non-change. Two are only partly resolved (L4 and L6 below).
The rewritten call-site comment is accurate on every completeness claim I checked against the code.
Four of its phrasings overclaim a little (findings 1, 4, 9, 10). The two new or changed assertions are sound and non-vacuous.
The fixes introduced no functional defect. The `BlockedBackendReads` import is harmless (finding 6).
Per the fix-Lows policy, all ten are listed with fixes. None blocks.

## 1. Finding-by-finding resolution

| Finding | Claimed | Verified |
|---|---|---|
| CR M1 / CC L1 (N2 partner) | Fixed | YES. `StockunitBusinessService.transferStockToUnitLoad` locks PO (Hook B, `:196`), then `stockunitRepository.findByIdForUpdate` (`:201`), then `unitloadRepository.findByIdForUpdate(sourceStockunitUnitloadId)` (`:237`), so SU is locked before UL. closeBOL has been removed from the comment. |
| CR L1 (per-branch table) | Fixed by stating the rule | YES. This is acceptable: the rule "any row lock or write this method takes comes after UL(source)" covers `:439/:481/:495` and `transferUnitLoadToCarrier`. |
| CR L2 / CC L2 (Damaged, creates) | Fixed | YES for Damaged. `setStockDamaged`/`removeStockDamaged` save the source's Stockunits, and those of its child unit loads, after `:329`. The INSERT part (createFixedLocationAssignment / createUnitload) is covered by the general rule but is not named. It takes only KEY SHARE on FK parents, which is benign. Accepted. |
| CR L3 (IT PO blind spot) | Fixed | PARTLY. The javadoc (`:59-64`) is narrowed, but the assertion message at `:137-139` still names "a Pickingorder" (finding 2). |
| CR L4 (test 1 outcome) | Fixed | PARTLY. The `outcome` isNull assertion was added (`:143-147`). The reviewer's second half, asserting `storagelocation_id = DEST`, was not (finding 3). |
| CR L5 (xid read in 3rd stmt) | Fixed | YES (`:253-260`). Sound, but the comment's wording is off (finding 7), and the change duplicates the helper (finding 6). |
| CR L6 (refusals wait on lock) | Fixed | PARTLY. The general statement is at `:327-328`. The reviewer's Nirvana-sentinel sub-case is not recorded (finding 5). |
| CR L7 (N3 either field) | Fixed | YES. `canonicalDestinationCode`'s fallback (`ScannedCodeResolver:177`) loads `findAllByLabelidIgnoreCase` entities only when there is no exact hit in either domain, so the source is hydrated only if the destination matches its label case-insensitively. "either scanned field ... only case-insensitively" is exact. |
| CR L8 (canonical label PIT survivor) | Fixed | YES. The new unit test is sound (section 3). |
| CC L3 (N1 parent/child partner) | Fixed | YES, with one wording nit (finding 10). |
| CC L4 (consult misses 2 sites) | Recorded in review-fixes.md, not in the consult | This non-change is justified: the consult is the architect's own file, and the two sites add no new order edge. |

## 2. Call-site comment (`MobileMoveUnitloadService.java:307-328`) checked against code

- **"Nothing above this line locks or writes (the two resolver calls only read)"**: TRUE.
  - Lines 289-299 are `LOG.debug`, then `canonicalUnitLoadLabel` and `canonicalDestinationCode`.
  - Both are `@Transactional(readOnly = true)` and use `existsByLabelid`, `findByName`, `findAll*IgnoreCase` and plain SELECTs (`ScannedCodeResolver:105-181`).
  - The only caller is `MoveUnitloadController.selectStock:75`, which has no `@Transactional` and nothing before the call, so no outer transaction brings earlier locks.
- **"any row lock or write this method takes comes after UL(source)"**: TRUE, and it follows from the claim above.
- **"measured for the location branch by MoveUnitloadLockOrderProbeIT"**: overclaims (finding 1).
- **N1**:
  - `transferUnitLoadToLocation` Hook A (`UnitloadBusinessService:235-238`) locks the tree's owning Pickingorders when the code classifies BLOCK_REALIGN. `CODE_TRANSFER` is in `BLOCK_REALIGN_CODES` (`PickLineActivityCodeClassifier:36`).
  - `transferStock` reaches Hook B.
  - The parent/child cycle works as described: A holds UL(P) and then POs(tree ⊇ POs(C)); B holds UL(C) and waits on POs(C); A later needs UL(C).
  - It requires owning Pickingorders to exist (finding 10).
- **N2**: TRUE on both counts. Two caveats: the partner list is incomplete (finding 4), and "right after" is imprecise (finding 9).
- **N3**: TRUE (see CR L7 above).
- **"Every rejection below now also waits for this lock"**: TRUE. Every `throw` in `scanDestination` comes after `:329`.
- **"0 such overlaps in 90 days on Hydra prd"**: correct for N1. For N2 it was not measured by the cited queries, and I closed that gap (finding 8).

## 3. Changed and new assertions

**IT test 1 outcome (`:143-147`): sound.**
- `DEST_LOCATION` is a real location, so the container branch is unreachable.
- The fixture has no stock, so the flow-bin branch would throw "No stock to assign to flow bin".
- A `null` outcome can therefore only mean the location branch completed. The author reports a mutation check (isMoveStock refusal → red with this message).

**backend_xid read in the confirming statement (`:253-260`): sound.**
- The worker cannot leave the wait before the method returns, because the holder is released only in `run()`'s `finally` after `awaitBlockedBackend` returns. The one exception is the lane's 10 s `lock_timeout`, and the `holderPid = ANY(pg_blocking_pids(pid))` predicate in the same statement filters that case out.
- So a returned `(query, xid)` pair describes a backend that was blocked by our holder from the poll through the predicate evaluation.

**`scanDestination_shouldLockTheCanonicalSourceLabel` (`UnitTest:729-738`): sound and non-vacuous.**
- `findByLabelidForUpdate("CASE-1")` is a strict stub (fixture `:600`). The resolver override `canonicalUnitLoadLabel("case-1") → "CASE-1"` is also strict.
- Mutant "lock the raw label": `findByLabelidForUpdate("case-1")` hits the strict stub with other arguments. That is swallowed by `catchThrowable`, but the `verify` then fails with "Argument(s) are different".
- Mutant "drop the rewrite" or "resolver not called": the resolver stub goes unused (STRICT_STUBS) and the verify fails.
- I found no way for it to pass for a wrong reason. One weak spot is recorded as finding 11b.

## 4. DB measurement for N2's exposure (new, read-only, Hydra prd)

floor.md's query counted `unitload_record` rows. N2's partners (Move Stock, pick confirm, any `transferStockToUnitLoad`) write `stockrecord`, not `unitload_record`, so that query could not see them. I ran this:

```sql
with ur as (select label, created, operator from unitload_record
            where activitycode='TRANSFER' and created > now() - interval '90 days')
select ur.label, ur.operator, s.operator, s.activitycode, s.type, s.created - ur.created
from ur join stockrecord s on (s.fromunitload = ur.label or s.tounitload = ur.label)
 and s.created between ur.created - interval '60 seconds' and ur.created + interval '60 seconds';
```

Result: 6 rows.
- All six are `RECEIVING / STOCK_CREATED`, 24-47 s *before* the move. That is the unit load being received and then moved in sequence, and it doubles as the positive control that the join matches.
- 2 of the 6 involve different operators.
- 0 rows come from a stock transfer or pick (the transferStock-shaped partners).

So the comment's "0 such overlaps" does hold for N2, but by this measurement, not by the one on record.

## Findings

### 1. [Low] Comment says the ordering rule is "measured" by the IT, but the IT is blind to the one lock that matters for N1
File: `MobileMoveUnitloadService.java:309-310`
> `this method takes comes after UL(source) -- measured for the location branch by MoveUnitloadLockOrderProbeIT.`

Confidence: MEDIUM.
- The IT's own javadoc (`:59-61`) now says a Pickingorder-first mutant would pass, because the fixture has no stock.
- The IT measures "no Location lock and no write before UL(source)", not "any row lock".

Fix: `-- measured for the location branch by MoveUnitloadLockOrderProbeIT (stockless fixture, so a Pickingorder lock is not observed)`.

### 2. [Low] Test 1's xid assertion message still names the Pickingorder the fixture cannot produce
File: `MoveUnitloadLockOrderProbeIT.java:137-139`
> `"... any xid ('%s') means a lock or write — the destination Location, a Pickingorder — was taken BEFORE the source lock"`

Confidence: HIGH.
CR L3 quoted exactly these lines and asked to narrow "the javadoc and message". Only the javadoc was narrowed.

Fix: drop ", a Pickingorder", or append "(this fixture cannot produce a Pickingorder lock)".

### 3. [Low] CR L4 is half done: completion is asserted, the destination is not
File: `MoveUnitloadLockOrderProbeIT.java:143-147`

Confidence: MEDIUM.
A `null` outcome proves that no exception was thrown. It does not prove the source was moved.

Fix: `assertThat(jdbcTemplate.queryForObject("select l.name from unitload u join location l on l.id = u.storagelocation_id where u.id = ?", String.class, sourceId)).isEqualTo(DEST_LOCATION);`

### 4. [Low] N2's partner list reads as complete but names 2 of about 12 caller families
File: `MobileMoveUnitloadService.java:320-321`
> `the inverse of a concurrent Move Stock or pick confirm on the same unit load.`

Confidence: HIGH.
- `git grep "transferStockToUnitLoad("` over src/main finds callers in `StockunitService` (6), `MobileTransferOrderService` (3), `MobilePutAwayService` (2), `BillofladingService` (2), `MobileReplenishService`, `ClubLineOrderProcessor`, `CustomerorderService`, `PickingorderBusinessService`, `UnitloadService` and `SourceLockGuard`.
- This is the "prose enumerations rot" pattern: a reader chasing a 40P01 from putaway or replenish would conclude it is not N2.

Fix: `the inverse of any concurrent transferStockToUnitLoad on one of its stock units (Move Stock, pick confirm, putaway, replenish, transfer order, ...)`.

### 5. [Low] CR L6's Nirvana-sentinel sub-case is still unrecorded
File: `MobileMoveUnitloadService.java:327-328` and `:336`

Confidence: MEDIUM.
- A scan of the Nirvana sentinel label now takes NO KEY UPDATE on the shared sentinel row before `assertNotNirvanaSentinel` refuses it.
- Discards lock that row as a destination, so a mis-scan now contends with every discard.
- The hold is brief, because the refusal rolls back at once, but it is a new coupling on a hot shared row. The general "every rejection waits" line does not convey it.

Fix: add a clause: `including a scan of the Nirvana sentinel itself, which now briefly locks the shared sentinel row that discards also lock`.

### 6. [Low] Confirming read inlined instead of extending `BlockedBackendReads`; the import is now javadoc-only
File: `MoveUnitloadLockOrderProbeIT.java:5`, `:250-260`, `:268`

Confidence: HIGH on the facts, LOW on the impact.
- **Duplication:** the SBDEV-3470 reasoning lives in `BlockedBackendReads.confirmedBlockedStatement`, and a hand copy will not pick up a future fix there. CR L5 itself suggested a sibling helper.
- **Import:** the import is not a defect.
  - javac has no unused-import lint.
  - `pom.xml` carries checkstyle only as a `<dependency>`, with no plugin execution.
  - `gradle/checkstyle.xml:71` `UnusedImports` defaults to `processJavadoc=true`, so the `{@link BlockedBackendReads}` at `:55` counts as a use.
  - ArchUnit sees bytecode, not imports.
- **Pre-existing, now more visible:** the 30 s timeout says "no backend was ever blocked" even when one was seen and never confirmed. The sibling probes (`PalletizeLockOrderProbeIT:472`, `ClosebolLockOrderProbeIT:428`) throw `BlockedBackendReads.LEFT_WAIT_BEFORE_CONFIRMED` for that case.

Fix: add `BlockedBackendReads.confirmedBlocked(observer, pid, holderPid)` returning `(query, xid)` and call it here. Track "seen but unconfirmed" and throw `LEFT_WAIT_BEFORE_CONFIRMED`. This also makes the import a real code reference.

### 7. [Low] "describe one instant" is not quite what one statement gives
File: `MoveUnitloadLockOrderProbeIT.java:251-252`
> `widened to read backend_xid in the SAME statement, so the xid and "still blocked by our holder" describe one instant.`

Confidence: MEDIUM.
- `BlockedBackendReads`' own javadoc (`:36-42`) says a single statement copies the `pg_stat_activity` status first and evaluates `pg_blocking_pids()` afterwards. So even within one statement the two readings are not taken at the same instant.
- The read is valid for a different reason: the backend was blocked by our holder at the poll and again at the predicate, and it cannot leave that wait in between without the holder releasing.

Fix: `...in the SAME statement: the poll saw it blocked by our holder and the predicate re-confirms it, and it cannot leave that wait in between, so the xid is the one it held while blocked.`

### 8. [Low] The "0 overlaps" basis for N2 was not measured by the queries on record
File: `MobileMoveUnitloadService.java:323-324`, floor.md "DB (exposure)", review-fixes.md CC L3

Confidence: HIGH that the recorded queries could not see N2's partners (they are `unitload_record` based). The claim itself holds (section 4).

Fix: record the section 4 query and its result in floor.md or review-fixes.md: 0 stock-transfer pairs, with the 6 RECEIVING rows as positive control.

### 9. [Low] "right after this lock" (N2, Damaged)
File: `MobileMoveUnitloadService.java:322`

Confidence: MEDIUM.
- The `stockunitRepository.save` calls come after 8 guard reads.
- The UPDATE SQL is emitted only at AUTO-flush. Per CR L2 that is the Stockunit query in `collectStockUnitIdsForUnitloadTree`.
- The order UL → SU is unaffected; only the timing word is wrong.

Fix: `update the stock units after this lock`.

### 10. [Low] N1 "now deadlocks" is unconditional
File: `MobileMoveUnitloadService.java:317-318`

Confidence: MEDIUM.
- `lockOwningPickingorders` returns immediately on an empty id list (`PickLineRealignmentService:146-148`), so the cycle needs stock in the tree that backs a pick line.
- It also needs the two moves to overlap in time.

Fix: `...a concurrent move of one of its children can now deadlock (when the tree has stock backing a pick line) where both used to queue on the Pickingorders`.

### 11. [Low] Minor test observations
- **(a)** `MoveUnitloadLockOrderProbeIT.java:144-146`: the message "so the two readings above describe a guard, not the move" is muddled. The readings are taken at the lock either way. What the outcome proves is that the fixture would have discriminated pre-fix, when the block moved to the flush UPDATE. Fix: say that.
- **(b)** `MobileMoveUnitloadServiceUnitTest.java:735`: `catchThrowable` discards the outcome, while the javadoc argues the raw spelling "would ... report the unit load as not found". Fix: add `assertThat(thrown).isInstanceOf(BusinessException.class).hasMessageContaining("Can not move unit load from")`, the Shipped refusal, which ties the test to the canonical row actually being found.

## Positive observations
- Replacing the per-branch table with a stated rule is the right answer to CR L1. It cannot rot the way the table did.
- The M1 correction checks out against the code (PO → SU → UL in `transferStockToUnitLoad`).
- Folding `backend_xid` into the predicate-bearing statement closes the lock_timeout window cleanly.
- Both new assertions were mutation-checked, and the checks are attributable (review-fixes L4, L8).
- The non-edit of `architect-consult.md` is correct lane discipline.
