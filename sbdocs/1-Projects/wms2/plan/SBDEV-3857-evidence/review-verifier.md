# SBDEV-3857 verifier lane (read-only, no build run)

Worktree: .claude/worktrees/wms2-api/SBDEV-3857, branch fix/SBDEV-3857-recount-locks-db-stock-unit.
Branch diff vs merge-base c9e8f9a1 is exactly 4 files (service, UnitTest, IT, ArchTest). The 9-file
`git diff origin/develop` stat also shows unrelated files only because origin/develop (f88d4559) has moved
past the merge-base; the branch is behind develop, so the suite result belongs to a base that is not current develop.

## Test-first
- 3ebf76d0 (16:25) adds IT + 15 JudgedOnTheDatabaseRow unit tests + ArchTest exemption; 5ac73663 (16:51) is the only src/main change.
- 84094313 (16:52, after the fix) adds 2 unit tests (refresh-under-lock, first SKU count FINISHED). Those two were NOT test-first.
- Fail-against-develop reasoning (develop service read from the code, not run): develop's recountSingleUnitLoad judged the posted
  stockUnit and had no findByIdForUpdate in the file (grep = 0 hits), so the AC-2 tests (expect BusinessException "moved or removed")
  fail (no throw); AC-3 tests (same(dbRow) handed to sendStockUnitToNirvana / IT expects FacadeException) fail (posted copy used);
  countBySKURecount did findById(posted.getStockunitId()), so the "stored position's stock unit" tests fail. Correct reasons.

## AC map
AC-1 pre-fix DEV probe: not code. Cannot be verified from the repo; evidence is the ticket comment. NOT VERIFIED here (out of scope, note only).

AC-2 foreign stock unit refused, nothing changes:
- Unit: recountSingleUnitLoad_shouldRefuse_whenTheStockUnitIsNotOnThePostedContainer, ..._whenTheStockUnitDoesNotExist,
  countSingleUnitLoad_shouldRefuse_whenTheStockUnitIsNotOnThePostedContainer (verifyNoInteractions on business services/messageService).
- IT: recountSingleUnitLoad_shouldRefuse_whenTheStockUnitIsNotOnThePostedContainer (asserts BusinessException message, both
  stockunits/unitloads untouched via JDBC, no OMS payload).
- Judgement: proves AC. Rows asserted from the DB, not mocks. Production code: onPostedContainer compares DB row unitload to posted unitload.
VERIFIED

AC-3 judged on DB row; reserved refused although body says 0:
- Unit: ..._shouldRetireTheLockedRow_whenThePostedCopyClaimsNoReservation (same(dbRow) identity), ..._whenTheDatabaseRowIsLockedButThePostedCopyIsNot.
  Caveat: the reservation refusal itself is inside stockunitBusinessService (mocked), so the unit test only proves the right object is passed.
- IT: recountSingleUnitLoad_shouldRefuse_whenTheBodyHidesTheReservation: real service, amount 12/reserved 5 in DB, body 0/0, count 0 ->
  FacadeException, row/container unretired, no position left, no OMS payload. This carries the AC.
- Residual: only the count==0 retirement path has a real-DB reservation test; non-zero stale reserved is covered by identity only
  (changeAmount(same(dbRow))). Low risk.
VERIFIED

AC-4 OMS delta == stock-record delta from locked row, both methods:
- recountSingleUnitLoad: IT ..._shouldSendOmsTheRecordedDelta_whenTheBodyAmountIsStale (DB 12, body 0, count 8 -> stockrecord sum -4,
  payload contains "normal":-4, amountbefore 12). Unit asserts getStockChangeDTO(-7) with posted amount 0, DB 12, count 5.
- countBySKURecount: IT countBySKURecount_shouldRecountTheStoredStockUnit_whenTheBodyNamesAnother (-4 record, -4 payload);
  unit ..._whenThePlainReadIsStale (plain findById returns 10, locked 12 -> -7, amountbefore 12).
- Payload-field check: getStockChangeDTO -> setNormal(total); StockChangeDto has field `normal` (no @JsonProperty rename);
  StockChangeNotificationService serialises with WmsObjectMapper.shared().writeValueAsString(list) (compact, NON_NULL), so the
  literal is `[{"sku":...,"normal":-4,...}]`; the substring "normal":-4 is correct. Delivery: OmsNotificationService.sendAfterCommit
  registers afterCommit when synchronization is active, else posts directly; the service method is @Transactional so afterCommit
  fires, then httpRestService.post(urlPath,payload) (2 args), which is what omsPayloads() filters (same filter as DeleteContainerWithStockIT:191),
  plus SKU filter. singleElement() proves exactly one send. Cannot pass vacuously (empty list fails singleElement).
- Weakness (Low): contains("\"normal\":-4") would also match -40..-49; harmless with seeded delta -4 exactly. Could assert on
  parsed JSON. recordedDelta() sums only the cycle-count STOCK_ALTERED rows for the client, valid for the single-row seed.
- Mutation observation: if production sent the posted-amount delta (0-8=-8) the IT fails on -4; good discrimination because the
  posted amount (0) differs from DB (12).
VERIFIED

AC-5 failing-test-first, mutation-checked, full verify vs baseline:
- Test-first ordering VERIFIED from git (3ebf76d0 before 5ac73663; reasoning above). Exception: 2 tests added in 84094313 post-fix.
- Mutation check: no mutation evidence found in the repo/branch or evidence dir for me to inspect (dir exists; I did not find a
  mutation log requested in this lane). NOT VERIFIED by me; needs the executor's mutation table.
- Full verify -Pci vs baseline: supplied separately, not assessed.
NOT VERIFIED (mutation + suite pending)

## Registration / id collision
- ArchTest EXEMPT_NON_TRANSACTIONAL entry: "net.aim_ai.wms.integration.service.CycleCountJudgesTheDatabaseRowIT", package matches the file;
  class has class-level @Transactional(NOT_SUPPORTED), consistent with the neighbouring DeleteContainerWithStockIT entry and rationale. OK.
- `git grep "3857[0-9]" -- src/test` outside the IT: only the ArchTest comment lines (538-541). No collision of 38570-38579.
  (Ranges 38540-38551 belong to DeleteContainerWithStockIT.) Note: the IT also uses seeded id 0 rows (location/itemunit/unitload type) as other ITs do.

## Other findings
- Medium: the two post-fix tests (84094313) and the new `entityManager.refresh(cycleCountPosition)` branch are covered only by a mocked
  EntityManager (ReflectionTestUtils); the real LockReads managed-entity path (refresh PESSIMISTIC_WRITE) is exercised by the IT only for
  recountSingleUnitLoad/countBySKURecount when the entity is already managed. No concurrent IT for the double-submit case. Risk: medium-low.
- Low: countSingleUnitLoad/countCycleCountStockUnit gained @Transactional(rollbackFor BusinessException, FacadeException) — behaviour change
  (rollback of partial writes); unit-tested only for refusal paths, no IT.
- Low: first-count paths (countSingleUnitLoad, countCycleCountStockUnit) have unit coverage only.
- Process: branch is behind origin/develop; the full-suite baseline should be re-graded on current develop before merge.

## Verdicts
AC-1 NOT VERIFIED (pre-fix evidence, outside repo)
AC-2 VERIFIED
AC-3 VERIFIED
AC-4 VERIFIED
AC-5 NOT VERIFIED (test-first order VERIFIED; mutation check and full -Pci suite not evidenced to this lane)
