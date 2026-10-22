**VERDICT: APPROVE**, with the Medium edits below to be made before the TDD gate.

**Overall assessment.** r2 fixes both of my r1 Highs at the design level:
- Moving to static `ReservationShare` arithmetic, with MRS keeping its own queries, really does leave the MRS suites unchanged.
- §8.1 now gives the executor approved expected values plus a stop rule.

I re-ran the arithmetic for all 12 unit tests and 3 ITs on today's code and on the proposed code. The design (Fixes A–E, the post-condition proof, and the `amount` cap) holds. What remains is a test-specification problem, not a design one:
- §8.1 is incomplete. It misses 2 ROMS rows, the ReassignTest mock wiring, and a reflection pin.
- One §8.1 treatment contradicts itself.
- Two unit tests (U-4, U-9) pass on today's code.
- IT-2 queries a column that does not exist.

The stop rule ("any other red → stop and add a row") turns each of these into a pause, not a hollowed-out pin. So none of them is High.

Code: `origin/develop` @ `652f37f7`. DB: DEV, where REPL389503 still shows 18/18/26 as of today.

---

### 1. My r1 findings

| r1 | Status | Evidence |
|---|---|---|
| H-1 tests-unchanged vs delegate | **RESOLVED** | The static-function option means MRS's `ownShareOfReservation` (`MobileReplenishService:1426-1432`) keeps both repository calls. Only its return line changes, so the `@InjectMocks` and `inOrder` pins at MRS-UT `:4414-4566` still see both sums. U-8's "verify on the mock" is gone. |
| H-2 changed pins | **PARTIAL** | §8.1 exists and its 7 rows check out, but it is incomplete and one treatment is invalid (M-A, M-B below). |
| M-1 unlocked move path | **RESOLVED** (Fix D) | "Same upgrade later" is true: `changeReservedAmount:509` locks the same READ-managed row from `findByUnitloadId` (`UnitloadBusinessService:535`). Order → current → target now matches recalc. |
| M-2 `amount` bound | **RESOLVED** for booking. **PARTIAL** for releases | See L-C. |
| M-3 `:280` admin redirect | **RESOLVED** | §0 #9. I re-counted: 27 `changeReservedAmount(` call sites in `src/main`. |
| M-4 query count | **RESOLVED** | One Share per source, pinned by U-8 `times(1)`. |
| M-5 IT-2 | **RESOLVED** in intent. New defect: L-A | `recordChangeReservedAmount` (`StockrecordService:300`) writes a row even for a zero delta, so the "drop the delta guard" mutant is killed. |
| M-6 IT-3 | **PARTIAL** | The fixture, route and columns are now specified. Shortage is not (L-B). |
| M-7 options and pre-mortem | **RESOLVED** | 4 options, each with a reason; 3 pre-mortems. |
| M-8 gate compile | **RESOLVED** | A reflection contract test, and U-tests go through the existing surface. `@Mock PickingorderPositionRepository` compiles today. |
| L-1 to L-4 | **RESOLVED** | |
| L-5 class count | **RESOLVED** | |
| L-6 | **RESOLVED** | §7's "only PROCESSABLE" now covers only the shrink, which happens only in recalc. That is correct. |

### 2. Acceptance tests, re-computed (amount/reserved/requested)

| Test | Today's code | Proposed code | Fails at gate? | Mutant named |
|---|---|---|---|---|
| U-1 18/1/9, shortage 40 | cap 26, req 26, +17 | own 1, cap 18, req 18, +17 | **Yes** (req) | add-back ✓ |
| U-2 18/18/26, shortage 40 | early return, 26 | held 18, delta 0, req 18, no call | **Yes** | delta vs req (−8) ✓ |
| U-3 20/5/9, shortage 9 | early return, no call | +4 | **Yes** | early return ✓ |
| U-4 20/12/5, shortage 5 | cap 13, desired 5 = req, no call | held 5, delta 0, no call | **No: passes today** | `held = ownShare` (−7) ✓ |
| U-5 18/18, other 18, this 4 | 4 > 0, usable | cap 0, unusable | **Yes** | old helper ✓ |
| U-6 cancel 20/3/9 | −9 | −3 | **Yes** | ✓ |
| U-7 redirect 20/3/9 | −9 | −3 | **Yes** | ✓ |
| U-8 `times(1)` | 0 calls, `WantedButNotInvoked` | 1 | **Yes** (assertion) | ✓ |
| U-9 20/2/9, others 5, shortage 9 | cap 27, desired 9 = req, **early return, no call, req 9** | invariant broken, no call, req 9 | **No: passes today** unless the WARN is captured | no-invariant top-up (+9) ✓ |
| U-10 5/12/10, shortage 10 | cap 3, −7, req 3 | cap 5, step 4 skip, req 5 | **Yes** | ✓ |
| U-11 move path | no SU lock, −9 | lock first, −3 | **Yes** | ✓ |
| U-12 same row | SWITCHED reserve called | none | **Yes** | ✓ |
| IT-1 | gives req 26 only if shortage ≥ 26; at shortage 18 it gives req 18 / res 10 | 18/18 | Yes (on `reserved`) | — (L-B) |
| IT-2 | early return, req 26, 0 rows | req 18, 0 rows | Yes (req), but see L-A | delta guard ✓ |
| IT-3 | SWITCHED +9, then −9, ends 1/9 | re-point, Fix B +8, ends 9/9, if shortage = 9 | Yes (no SWITCHED row) | ✓ |

### 3. §8.1 audit

I read all four test classes and the replenishment ITs.

**Rows the plan lists, checked:**
- `:625`, U-A1 `:1151`, `:771`, `:1541`, the ReassignTest release pins and FirstTouch are valid as treated.
- FirstTouch is fine because `findById(candidateId)` is unstubbed and returns empty, so `source == null` and no share query runs. That holds only if the post-redirect Share is computed *after* that re-read.
- The ITs I checked need no rows: the redirect IT fixture is consistent (20/5/5), the move IT seeds `reserved = REQUESTED`, and the stale-version AC-5 case still converges to 50 because `held = min(0, 99950) = 0`.

**Missing or invalid rows:** M-A and M-B below.

---

### Medium

**M-A. §8.1 is not the complete list that pre-mortem 1 relies on.** Pre-mortem 1 says `§8.1 lists every expected flip`. Four gaps:
1. **`noUpdateWhenAmountUnchanged`** (ROMS-UT `:778-812`). Fixture 84/0/84, shortage 84. Today: cap 168, early return, so the test pins `never()` on `changeReservedAmount` and on `save`. Proposed: held 0, cap 84, delta **+84**, save. Both pins go red.
   - Fix: F, with reserved 84. Then held = req, delta 0, and the early return holds.
2. **`treatsEmptyTotalsRowsAsZero`** (`:1405-1460`). Same 50/0/10 shape as `:739`. It asserts `changeReservedAmount(eq(su), eq(new BigDecimal("50")) …)` and `getRequestedamount() == 60`. Proposed gives req **50**.
   - Fix: an A row identical to `:739`'s.
3. **ReassignTest has no `@Mock PickingorderPositionRepository`.** Its mock list is at `:61-68`. `@InjectMocks` constructor injection passes `null` for an unmocked type. Once Fix D computes Share on the move path, every test reaching a release or redirect NPEs on `pickingorderPositionRepository.sum…` (AC2, AC3, R-5, AC8, AC5-sanity, M4 and AC5-guard). The §8.1 row only says `plus a new findByIdForUpdate stub (Fix D)`.
   - Fix: add the mock and the same `lenient()` zero stubs for both sums to ReassignTest's `@BeforeEach`.
   - Also say the `findByIdForUpdate(42L)` stub must return **the same `movedStock` instance**. The `eq(movedStock)` pins at `:204-206` and `:307-309` compare by `Stockunit` equality.
4. **`MultiUnitLoadOwnShareContractUnitTest:198`** pins `.contains("cancelOrder/3")`. Fix B already threads `share` into `updateRequestedAmount(order, source, share, desired)`. If Fix C does the same to `cancelOrder`, this positive control goes red, and no row covers it.
   - Fix: state that `cancelOrder` keeps arity 3 (it gets the Share by other means), or add the row.

**M-B. The redirect-then-cancel row cannot work as written, and where held comes from is unspecified when `isSourceUsable` returns early.**
- **The row contradicts itself.** It says `stub others so that capacity = 0 on the candidate. The post-redirect cancel then releases held`.
  - The candidate entity is 15/20 (`:709`). Capacity 0 with amount 15 needs held + free = 0, so others ≥ 20, so own = 0 and **held = 0**.
  - With held 0, the cancel releases nothing. The pin's second `inOrder` verify (`changeReservedAmount(eq(candidateSu), eq(-5), …CANCELLED)`, `:731-736`) can never pass. That pair is the test's "distinguishing evidence".
  - Also, the mocked `changeReservedAmount` never mutates the entity, so the post-redirect Share is computed from fixture values, not post-reserve values. The plan does not say this.
  - Concrete fix: candidate entity `buildStockunit(21L, 51L, BigDecimal.ZERO, new BigDecimal("5"))` with others 0. That gives own 5, held 5, free 0, cap = min(5, 0) = 0 (still exactly the boundary, so the `<= 0` → `< 0` mutant stays killed). The cancel then releases −5 and the SWITCHED +5 / CANCELLED −5 pair is preserved.
- **Held when `isSourceUsable` returns early.** Fix A computes Share "in `isSourceUsable`, for the first-touch source". But `isSourceUsable` returns at `:425-430` (amount null or ≤ 0) *before* the capacity check. Several fixtures go down exactly that path: U-A1's F treatment (originalSu amount 0, reserved 10), the redirect tests, `cancelsWhenSourceAmountIsZero`. With no Share computed, redirectSource and cancelOrder have no held. An executor who defaults it to 0 makes U-A1's F row red.
  - Fix: one sentence in Fix A. "If `isSourceUsable` returns before the capacity check, `redirectSource` and `cancelOrder` compute Share on demand from the locked source." Also say whether a held of 0 skips the release call in `redirectSource`, as it does in `cancelOrder`.

**M-C. U-4 and U-9 pass on today's code.**
- **U-9:** today's code takes the early return (desired 9 = requested 9). Today and proposed both give "no call, requested 9". It reds only if the WARN is asserted, and the plan does not say it is.
  - Fix: use shortage **12**. Today: cap 27, +3, req 12. Proposed: invariant broken, no call, req = min(12, 9) = 9. The no-invariant mutant gives +12. Or say explicitly that the WARN is asserted through a log appender.
- **U-4:** this one is inherently green today. held == requested makes the old and new formulas agree, which is the plan's own revert argument.
  - Fix: label it "green at gate by design; it is a mutant pin for `held = ownShare`" so the gate does not count it as a red.

### Low

- **L-A. IT-2's count query names a column that does not exist.** It says `stockrecord WHERE stockunit_id=? AND ordernumber=?`, but DEV `information_schema` shows `fromstockunitidentity` (varchar) and `ordernumber`, and no `stockunit_id`. The existing fixtures use `fromstockunitidentity = ?` (`AbstractReplenishRedirectPgFixture:263`). As written, IT-2 reds with BadSqlGrammar, the wrong reason.
- **L-B. Shortage is under-specified in two ITs.**
  - IT-1 says `shortage ≥ 18` but `Current code gives requested 26`. That claim needs shortage ≥ 26.
  - IT-3's `== 9` needs shortage exactly 9, with the cancel threshold below it. Neither is stated.
- **L-C. §9 #6 overclaims.** It says `Fix B steps 3–4 remove the throw paths when … res > amount`. Fix C's releases are unguarded. Example: amount 5, res 12, held 5 → release −5 → 7 > 5 → `CANCELLED_MORE_THAN_AVAILABLE`, and the shared tx is marked rollback-only. The old code behaves the same, and DEV has 0 such rows. Narrow the claim to "booking", or apply the step-4 guard to releases too.
- **L-D. Fix B step 3's rationale claims more than the step does.** It says `must not … backfill another order's deficit under this order's number`. Step 3 only prevents that when the invariant is broken. When it holds (A holds 10 for itself, B holds 9 but is under-reserved, res 10), A's recalc books B's 9 under A's number. The quantities converge correctly, but the attribution does not. DEV `shared_su` = 0. Reword it.
- **L-E. §0's Method says each of the 27 sites is classified, but the table shows about 10.** The 13 customer-order, picking and release-job sites (`CustomerorderService:350/432`, `PickingorderBusinessService:568/1156`, `ReleaseOrderJobService:623-703`, …) and MRS `:394/:404/:581/:1488/:1492` are not shown. Add one line: "the remaining N book picks or customer orders, not replenishment orders; out of scope".

### What's missing
- The §8.1 rows in M-A.
- Where the post-redirect Share is computed relative to `ensureValidSource`'s `findById` re-read. FirstTouch's "expected unchanged" depends on it.
- Null semantics for `ReservationShare` inputs (an unstubbed BigDecimal mock returns `null`). §8 tests null inputs, but Definitions does not say null is treated as 0.

### Design consistency (task 5)
- Fixes B–E agree with the stated principles: one home for the arithmetic, held = min(requested, ownShare), and no ratcheting of a broken SU.
- I checked the post-condition proof myself, including that delta > 0 can never happen when res > amount (free = 0 there).
- Fix D's lock order holds; on the move path the unit-load locks precede both.
- Fix E cannot loop: a capacity of 0 means amount ≤ reserved, which the candidate query's `su.amount > su.reservedamount` already excludes.
- Behaviour change 6 is harmless to the SBDEV-3605 ITs: the fixtures are consistent, and Y is manual-priority in IT-6.

### Verdict justification
I stayed in THOROUGH mode: no High, and fewer than 3 Majors. Realist check:
- **M-A:** would be High without the stop rule. With it, the worst case is an executor pause and a row added mid-gate.
- **M-B:** an executor following the row as written gets a red they cannot clear without dropping the pin's evidence. It stays Medium because the stop rule catches it.
- **M-C:** a gate-rigor issue; the mutant kills are real.

Apply M-A to M-C and L-A/L-B, and the plan is gate-ready.

### Open questions (unscored)
- Does `assignDestinationForMultiUnitLoads` ever create an FLA, and so run maintenance inside `fulfillMultipleUnitLoadsTx`, on a fixture where X is under-reserved? IT-4 and IT-5 set B to 7 and 2 after the redirect. I found no FLA-creating path in those fixtures, but did not trace it fully.
- `others` sums other orders' *requested*, not their held. An over-granted sibling (the very defect being fixed) inflates `others` and can mark this order's SU invariant-broken. That converges after the sibling's own recalc, but it may take two crons. Worth one sentence in Behaviour change 1.

---
**Ralplan summary**
- **Principle/option consistency: Pass.** The static-function choice delivers "MRS tests unchanged in fact".
- **Alternatives depth: Pass.** Four options, each with a reason; the SBDEV-2610 precedent is addressed.
- **Risk/verification rigor: Pass with edits.** 13 of 15 tests fail correctly at the gate; U-4 and U-9 pass today (M-C). §8.1 is incomplete (M-A, M-B). IT-2 has a column error (L-A).
- **Deliberate additions: Pass.** Three concrete pre-mortems, each with a mitigation.

Files:
- `/Users/np1076/dev/spk/owl/sbdocs/1-Projects/wms2/plan/SBDEV-3618-evidence/plan-r2-snapshot.md`
- `/Users/np1076/dev/spk/owl/sbdocs/1-Projects/wms2/plan/SBDEV-3618-evidence/critic-r1.md`
- Code was read from `origin/develop` in `/Users/np1076/dev/spk/owl/v2/wms2-api`.