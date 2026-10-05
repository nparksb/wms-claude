# SBDEV-3547 PR-B — review round 1 (2026-09-28, at 09306eed)

## Conformance (verifier, Opus): PASS
- All re-run fresh: `clean compile` OK · 7 touched classes 429/0/0 · H2 IT 2/2 · full `clean test` 7396/0/1 (develop 7377/0/1 + 19).
- Every PR-B §0 row, §7.1 row, §7.3 flip and §9 item is VERIFIED. All 4 deviations were accepted.
- Gaps it raised:
  - The RED phase and the mutants were not re-run by the lane (read-only).
  - `historytote`-null strand: **already measured, 0 on all 4 PRD tenants** (tdd-gate-report-pr-b.md).
  - The pre-run refusal names the root (= code-review M2).

## Security (security-reviewer, Sonnet): risk LOW, 0 C/H/M
- L1: the type check fails open only on pre-existing bad data. `typeId` is set only in `createUnitload`, there is no retype endpoint, and Unitload/Stockunit are in `SDR_WRITE_WITHDRAWN`. No change.
- L2: the messages expose a label, an SU id and a lock code. These are operator-visible identifiers, the same as PR-A. No change.
- No bypass via SDR or the other `transferUnitLoadToCarrier` callers (StockunitService:411 MANUAL_SPLIT refuses via M1 first). Every delete endpoint runs the pre-run, and `deleteUnitLoad` re-checks. No TenantContext leak. No new SQL. `CancellationReversalService` is untouched, and both exits release 100 (IT).

## Code review (code-reviewer, Opus): APPROVE with Mediums fixed; 0 High
- Sibling sweep: no missed lock-lowering path. The sweep covered:
  - every stock-lock writer;
  - every Nirwana sender;
  - the other cancel variants;
  - the MMU damaged branches.
- M1: stale cross-ref javadoc (SourceLockGuard, the asymmetry test). M2: the recursive pre-run names the root, not the holder, and pre-empts "has child container". M3: the pre-run test stub is lenient `anyCollection()`, so a root-only mutant survives. M4: the C1 comment says "every path owes the clear".
- L1: stale CancellationReversalService precedent comment. L2: the delete message is repetitive and says "moving". L3: raw label in MMU. L4: PACKED-guard javadoc overclaim. L5: no missing-type-row test. L6: no `Picked` assert. L7: bulk delete commits #1 and then refuses #2 (**proposed, out of scope**). L8: TOCTOU, pre-existing (**noted**). L9: rail constant. L10: IT javadoc.
- Open question (**release gate**): a pre-PR-B pallet already carrying a Tote at 100, moved as the source onto another carrier, is not refused. R5 measured 0 tote→carrier moves. Needs one PRD query (child Tote with an SU at 100 under any carrier) before release. The DB MCPs were down this session.

Fix round 1: M1–M4, L1–L6, L9, L10 → executor; scoped re-review follows.

## Review round 3 (tip review of 885bba83): APPROVE, 4 Lows
- L1: fixed. The comment now says SHIPPED (TRANSFER for a TRANSFER_INTRACOMPANY closeBOL), per `BillofladingService` "Integer entityLock = billOfLading.getType().equals(\"TRANSFER_INTRACOMPANY\")".
- L2: fixed. A blank verb now also falls back to "moving". New test `goodsOutHint_blankVerb_defaultsToMoving`; the mutant (null-only check) was KILLED: "before    it." vs "to end with … before moving it.".
- L4: accepted, not changed. The fixed "before <verb> it." template can't name the root cleanly, and the message stays actionable.
- L3: **closed by evidence.** On wms2-wineco-dev, 4 of 575 SUs at 100 are goods-receipt-position SUs, and 6 of 16 cancellation-log rows point at one. So whole-SU picks DO reuse the received SU, and the reviewer's "implausible" assumption was wrong. However, all 4 are Packages at Packaging (Outbound, useforgoodsin=false). None is still on its receipt unit load (same_ul=false), and none has a pending reversal. Both `deletePosition` callers (`adjust` to 0 and `delete`) run `checkAndGetGoodsReceiptPosition` first. That check refuses "StockUnit not on UnitLoad anymore!" when the SU has left its receipt unit load, and it also requires a goods-in area and an OPEN advice. FixLocationAssignmentService sends only amount-0 SUs from a fixed-assignment virtual container. Neither path can reach picked stock.

## Release-gate check: pallet already carrying a fenced Tote (round-1 open question)
- wms2-wineco-dev: **0** SUs at 100 on a Tote under a carrier. Positive controls: 575 SUs at 100, 147 of them on a Tote; 416,326 child unit loads.
- The PRD tenants were NOT measured: their MCPs were still at CONNECT_TIMEOUT. This stays a G-gate item. The query:
  `SELECT count(*) FROM stockunit s JOIN unitload u ON u.id=s.unitload_id JOIN unitload_type t ON t.id=u.type_id WHERE s.entity_lock=100 AND t.name='Tote' AND u.carrierunitload_id IS NOT NULL`

## Orchestrator runs, round 3 (1427d702 / d0cfb81a)
- Full `mvn -o clean test` at the round-3 working tree (committed as `1427d702`): **Tests run: 7402, Failures: 0, Errors: 0, Skipped: 1**, BUILD SUCCESS. Log: `scratchpad/rf3-full.log`.
- Round-3 hand mutants, run by the orchestrator, both KILLED:
  - R3-1: `verb == null || verb.isBlank()` → `verb == null`. Killed by `goodsOutHint_blankVerb_defaultsToMoving` (`before    it.`).
  - R3-2: → `verb == null || verb.equals("  ")`. Killed by the added empty-string assertion (`before  it.`).
- `d0cfb81a`: `LockRefusalMessagesUnitTest` 8/8.

## Review of 1427d702 (code-reviewer, Sonnet): APPROVE
- L1 is exactly right: `closeBOL` writes TRANSFER for TRANSFER_INTRACOMPANY, and `finishTransfer` always writes SHIPPED.
- L2: the javadoc matches the code, and the one-argument form is byte-identical.
- The L3 claims in the commit message hold.
- Two optional Lows:
  - Add an empty-string case → done in `d0cfb81a`.
  - "Amount-0" should be "non-positive" → the PR body uses "non-positive".

## Review of d0cfb81a (code-reviewer, Sonnet): APPROVE, 0 findings

## Final full-branch lane at d0cfb81a (security-reviewer + PR-body fact-check, Opus)
- **M1 (Medium):** web Move Stock → Damaged turned 100 into 103 with `ignoreLock=true` and no function check beyond `/transferStock`. `removeLock` then cleared 103, so plan R2's "Needs WEB_UI_ACTION_ADJUST_LOCK_DAMAGED" was false. → Decision **D5**: fenced in `c2d71a42`.
- Lows:
  - L1: the carrier fence checks only the source's own stock. Already a PRD gate.
  - L2: delete-guard TOCTOU. Pre-existing.
  - L3: test-only SQL concatenation of a constant.
- PR body: 8 corrections, applied in the PR-body rewrite after D5.

## Review of c2d71a42 (D5; code-reviewer, Opus): APPROVE, 4 Lows
- It covers every route into the Damaged branch:
  - the existing-container and flow-bin arms use `ignoreLock=false`;
  - the whole-unit-load arm is covered by SourceLockGuard;
  - nothing is persisted before the refusal.
- The flipped `StockunitServiceParcelSourceRefusalUnitTest` fixture change (100 → ON_HOLD) is justified. The NeverMatcher count going from 5 to 7 is correct.
- The "only operator exits" claim is now TRUE: completeReversal, waive, plus the BOL-close overwrite.
- L1: detached lock read. **Accepted by Nam as a known narrowing** and documented in the code (`9e7be519`).
- L2: no operator route is left to damage live picked stock. **Accepted by Nam; state it in the PR and the G3 floor briefing.**
- L3: the fixture id equalled the lock code. Fixed in `9e7be519` (id 4711); StockunitServiceUnitTest 94/0.
- L4: dropping the Damaged conjunct is an equivalent mutant (a 100 split elsewhere is refused by `transferStockToUnitLoad(ignoreLock=false)`). Accepted.
- Open question (low confidence): cancelled and live stock sharing a tote at packaging. No evidence of cross-order tote sharing; pre-existing.

## Verdict record: re-review of d714a968 (code-reviewer, Opus)
- **APPROVE**, with 1 new Medium (N1, the false "only exits from 100" comment) and 7 new Lows (N2–N8). All were fixed in `885bba83`.

## Environment note
- Docker Desktop was hung for this whole work session: `docker info` hangs, and the first IT baseline attempt stalled on Testcontainers. So the Testcontainers IT lane was not run locally. Only the H2 lanes (BaseRollbackIntegrationTest and BaseRepositoryIntegrationTest) were run.

## Review of 9e7be519 + PR-body fact-check (code-reviewer, Opus): COMMENT
- **Code:** 1 Low. The narrowing note said "closing it needs a new scalar repository query". In fact a lock-free re-read only narrows the window, and closing it needs a row lock, which F1 forbids. Fixed in `b3938629`.
- **Body:** 5 false statements, 3 overclaims, and manual-test row 6. All applied to the body before publishing.
- **Sweeps:** both main completeness claims hold:
  - no operator route marks stock at lock 100 damaged;
  - the three hand routes were the only ones that ignored the fence.
- SDR sweep (the same 9e7be519 fact-check lane): `RestConfiguration` `SDR_WRITE_WITHDRAWN` includes `Stockunit`, `Unitload` and `UnitloadType`. This is the "later sweep" the PR body cites.

## Check of b3938629 + applied body fixes (code-reviewer, Sonnet): APPROVE
- The comment reword is TRUE: the fence reads the detached `stockUnit`, and `stockUnitList` holds an in-transaction copy of that row.
- A row lock here would invert the SBDEV-2481 order that `transferStockToUnitLoad`'s Hook B enforces.
- All 8 body corrections and rows 6/7 are TRUE, and the edits introduced no new false claim.
- Low (a): the comment says "SBDEV-3341 F1 lock order" where the underlying rule is SBDEV-2481. Kept: F1 is where that rule is stated in this method.
- Low (b): the SDR "later sweep" sentence had no evidence trail. Recorded above.
- Scratch merge of PR-B tip b3938629 + develop 5fe8c2f4 (#432 SBDEV-3556 overlaps PickingorderBusinessService): full `mvn -o clean test` 7435/0/1, BUILD SUCCESS; overlapping classes + rails 257/0.

## Dev test on the deployed build (2026-09-29, wineco/wsl, `develop-5d08e9fc`, user panderson)
- **Subject:** live picked tote T-0202 (unit load 963878291), SU 30795747 at lock 100, 12 units, at FinishedPicking.
- **Script:** `scratchpad/dev-test-3547b.sh`. The password is read from `$PW` only. Every request was expected to be refused.

| # | Request | Result |
|---|---|---|
| T1 | web Move Stock, 1 unit → bin 00-XA01 | refused: `Source stockUnit=30795747 is locked=100 (Picked). Stock on T-0202 is reserved for goods-out. …before moving it.` (PR-A M1) |
| T2 | web Move Stock, 1 unit → Damaged | refused, same text. **This is the D5 fence**: the Damaged branch runs `ignoreLock=true`, so before D5 this move would have succeeded |
| T3 | mobile Move Unit Load, selectSource T-0202 | not refused (hasStock, FinishedPicking), as designed |
| T4 | mobile MMU T-0202 → existing pallet IN-000645 | refused: `Tote T-0202 holds stock unit 30795747 locked=100 (Picked) and cannot go onto a carrier. …` |
| T5 | mobile MMU T-0202 → new inbound pallet IN-935401 | refused, same text; **no pallet created** |
| T6 | web Delete Container T-0202 | refused: `Container T-0202 cannot be deleted: it holds stock unit 30795747 locked=100 (Picked). … before deleting it.` |

- **DB after the run:** SU 30795747 is unchanged (lock 100, 12 units, FinishedPicking; the SU and UL `modified` timestamps are still 2026-08-31). IN-935401 does not exist, IN-000645 has 0 children, and no new Damaged SU or unit load was created in the last 15 minutes.
- **Not covered here** (these write data): the cancel path itself (§7.4 rows 1, 5, 6), the location-arm move, and Package-onto-pallet (row 7). The H2 IT and the CI IT lane cover the cancel path.

## Dev test, phase B: the cancel path end to end (2026-09-29, wineco/wsl, develop-5d08e9fc, panderson)
- **Subject:** order 051797-000001 (ext 570983, batch BATCH-20260817-002), 2 positions PICKED; tote T-0702 (UL 30695088) at FinishedPicking; SUs 30695093 and 30695143, both lock 100. There were no log rows before.
- **Script:** `scratchpad/dev-test-3547b-cancel.sh` (password from `$PW` only).

| # | Step | Result |
|---|---|---|
| B1 | OMS `POST /rest/order/cancelPositions` | 200. Order and positions → 800; tote → Clearing. **Both SUs stayed at lock 100.** Log rows 19 (pos 30666892 / SU 30695093) and 20 (pos 30666893 / SU 30695143), both `reversal_required`, tote_label T-0702 |
| PR-A | unitload_record 31251465 (TRANSFER → Clearing) | `ordernumber = 051797-000001`, additionalcontent NULL. The A1 swap fix is confirmed |
| B3 | Move Stock → bin; → Damaged; MMU → pallet IN-000645; Delete Container | all refused with the goods-out hint (the same texts as phase A) |
| B4 | MMU T-0702 → location FinishedPicking | **allowed**; the SUs stay at 100 on the tote |
| — | Side effects of B3 | no new unit loads, no Damaged SUs, IN-000645 still has 0 children, no stockrecord rows |
| B5 | initiate + complete for pos 30666892 | 200. SU 30695093 drained into bin SU 66350 at TCOMPANY-01 (lock 0, +2 → 9584). The source was retired to Nirwana. Row 19 closed |
| B6 | waive pos 30666893, `stockReturned=false` | 200. **SU 30695143 released to lock 0** and stays on T-0702. Row 20 closed, `waiveLockRetained=false` |
| B7 | after release: MMU T-0702 → pallet IN-000645 | refused by a **different, pre-existing** rule: `unitLoad=T-0702 with type=Tote not allowed on other unit load` |

- **Finding from B7:** on dev, `unitload_type.onotherunitloadallowed` is FALSE for Tote (only Package and Case are TRUE). The SBDEV-3320 comment in `UnitloadBusinessService` says Tote is false on every tenant.
  - So `transferUnitLoadToCarrier` already refused every Tote onto a carrier, whatever its lock. Only the `transferUnitLoadToCart` exemption (SBDEV-3320, Tote → Cart) bypasses that rule.
  - The inbound arm's `createUnitload` ran first but was rolled back, because `scanDestination` is @Transactional.
  - **So D1′ closed no live hole on the MMU carrier arms.** It gives an earlier, actionable message and is defence in depth if the type config changes. That matches R5's measured 0 tote→carrier moves on PRD.
  - The PR body's "closes three hand routes that ignored it" overclaims for MMU-carrier. The routes that really ignored the fence were Move Stock → Damaged (D5) and Delete Container (B-3).
- **Not run:** a Package at 100 onto a pallet (§7.4 row 7, GREEN). Covered by the unit test `scanDestination_carrierArm_stillMovesPackageAtPickedForGoodsout`.
- **Dev state left behind:** order 051797-000001 is CANCELED with both reversal rows closed. T-0702 is at FinishedPicking holding SU 30695143 (2 units, lock 0, waived as not returned). Bin SU 66350 gained 2.

## Fact-check of the D1′ body edits (code-reviewer, Opus): 5 corrections + 1 optional, all applied, then published
- It confirmed that the "two hand routes" set is right. Before PR-B:
  - Delete Container: `deleteUnitLoad` → `sendStockUnitToNirvana` had no lock check;
  - Move Stock → Damaged: ran with `ignoreLock=true`;
  - Move Stock → bin and adjustAmount: already refused.
- It confirmed the B-2 note with code quotes:
  - the type gate never reads the lock;
  - `transferUnitLoadToCart` is called only by `MobilePickingService:1645`;
  - `scanDestination` is @Transactional with rollbackFor=BusinessException;
  - both carrier branches reach `transferUnitLoadToCarrier`.
- The PRD gate changed. The "Tote SU at 100 under a carrier = 0" count guarded an unreachable move: a Tote reaches a carrier only on a Cart during picking, and Cart and Pallet are themselves refused onto another carrier. Mid-pick the count is legitimately non-zero. It was replaced by a type-config check: `SELECT name, onotherunitloadallowed FROM unitload_type WHERE name IN ('Tote','Cart','Pallet')` should return all false. dev WineCo: all false.
