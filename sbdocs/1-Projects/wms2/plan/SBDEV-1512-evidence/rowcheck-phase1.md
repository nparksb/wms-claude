# SBDEV-1512 Phase 1 — §7 row-by-row conformance check

**Lane:** `rowcheck` (independent adjudication lane, read-only on source)
**Worktree:** `/home/nampark/dev/wms-claude/.claude/worktrees/wms2-api/SBDEV-1512-rowcheck` @ `e01bce85`
**Plan:** `/home/nampark/dev/wms-claude/sbdocs/1-Projects/wms2/plan/SBDEV-1512-receive-damaged-from-returns.md`
**Date:** 2026-09-16

**Headline:** of the 22 in-scope §7 rows, **3 are BUILT, 7 are COVERED-ELSEWHERE, 12 are ABSENT.**
The requesting lane's suspicion — that a name-matching sweep undercounts — is **partly right and
partly wrong**. Six unit rows and one integration row really are implemented under names the plan
did not predict, and I killed six of those seven with a mutation probe. But twelve rows are
genuinely unpinned, and **five of them survive a mutation that reverts the exact behaviour the row
was written to guard** (T1.1, T1.2, T1.4, T1.6, T1.9 — each left the 147-test unit suite fully
green). Two of those five are the rows the plan itself singles out as load-bearing: **T1.7b** ("the
one that actually matters") and **T1.9**.

---

## 1. Row table

Verdict key: **BUILT** = a test exists with the plan's method name pinning that behaviour ·
**COVERED-ELSEWHERE** = genuinely pinned under a different name/class, assertion quoted ·
**ABSENT** = nothing pins it · **N/A** = out of Phase 1 scope.

`P#` refers to the mutation probes in §4. A row marked COVERED-ELSEWHERE with a `P#` was proved by
reverting the production behaviour and confirming the substitute went red.

| Row | Plan's stated method | Verdict | Actual test that covers it | Evidence |
|---|---|---|---|---|
| **T1.1** | `resolveRefs_acceptsZeroUndamagedWhenDamagedPositive` | **ABSENT** | — | **P3**: reverting `if (totalAmount < 1)` to `if (position.getAmountOfBottles() < 1)` in `resolveRefs` left **147/147 green**. No test anywhere sets `amountOfBottles = 0` together with a positive damaged value — the whole §3.1 relaxation is unguarded. |
| **T1.2** | `resolveRefs_rejectsNegativeDamaged` | **ABSENT** | — | **P12**: replacing `if (rawDamaged != null && rawDamaged < 0)` in `resolveRefs` with `if (false)` left **147/147 green**. `T1.18`'s test covers only the three paths that *skip* `resolveRefs`, and the controller loop rejects first on those, so the auto-receive tier's own check is unreachable by any assertion. |
| **T1.3** | `resolveRefs_rejectsZeroTotal` | **COVERED-ELSEWHERE** *(shortfall named)* | `ReturnAdviceAutoReceiveServiceUnitTest$MirroredPositionChecks.validateThrowsWhenAmountOfBottlesIsZero` — `assertThrows(WebserviceBusinessExceptionClientSide.class, () -> service.validate(dto));` on a `0 + (absent)` fixture | **P1 kill**: neutering the guard produced `Expected net.aim_ai.wms.exceptions.WebserviceBusinessExceptionClientSide to be thrown, but nothing was thrown.` ⚠ **Shortfall:** the row requires the test to *name which message key*. It does not — it asserts only the exception **type**, and this class's own integration sibling records that "the TYPE alone discriminates nothing: validate/resolveRefs throw this one type for every rejection they have." So the row is covered for *rejection happens*, not for *rejected by the total rule, with this code*. |
| **T1.4** | `resolveRefs_rejectsTotalAboveMaximum` | **ABSENT** | — | **P2**: reverting `if (totalAmount > MAX_UNITS_PER_POSITION)` to `if (position.getAmountOfBottles() > …)` left **147/147 green**. The two pre-existing cap tests (`SecurityGuards.validateThrowsWhenAmountExceedsPerPositionCap` 100_001, `validateAcceptsAmountExactlyAtCap` 100_000) both leave `amountOfBottlesDamaged` unset, so neither can see the total. The controller-tier cap *is* pinned (`perPositionCapIsEnforcedOnRegularAdvice`, `totalAtExactlyTheCapIsAccepted`) but that is a different code site. |
| **T1.5** | `resolveRefs_preflightsDamagedLocationOnlyWhenDamagePresent` | **COVERED-ELSEWHERE** | the pair `resolveRefs_rejectsWhenDamagedLocationMissing` + `resolveRefs_doesNotRequireDamagedLocation_whenNothingIsDamaged` — the second ends `verify(locationRepository, never()).findByName(WmsConstants.STORAGE_LOCATION_DAMAGED);` after a `validate(validReturnDtoWithDamaged(0))` that must not throw | **P6 kill**: making the pre-flight unconditional (`if (lines.stream().anyMatch(…))` → `if (true)`) turned the negative-half test red. ⚠ The red arrives as an **escaping exception at the `validate` call**, not at the `never()` verify (`WebserviceBusinessExceptionClientSide entity %1s does not exists…`), and the same mutant reddens **13 other tests**, so the signal is not specific. The row's *pairing* requirement — a positive control guarding the `never()` — is satisfied: `resolveRefs_rejectsWhenDamagedLocationMissing` is the positive half, and its stub set is deliberately fully resolvable so it cannot pass for the wrong reason. |
| **T1.6** | `bind_zipsDamagedAmountPositionally` | **ABSENT** | — | **P13**: replacing `line.damagedAmount()` with `0` inside `bind`'s `AutoReceiveLine` construction left **147/147 green**. Every unit test that drives the damage pass builds `AutoReceivePlan` directly via the `planWithDamagedLines` helper, bypassing `bind` entirely; the two `bind` tests that exist (`bindMapsPositionExternalIdsToPersistedIds`, `bindDoesNotCollapsePositionsThatShareAReferenceId`) never mention `damagedAmount`. |
| **T1.7a** | `applyDamage_returnsDamageFailedWhenSetLockDamagedThrowsChecked` | **COVERED-ELSEWHERE** *(shortfall named)* | `applyDamage_failure_returnsDamageFailedAndStillFinishes` — stubs `doThrow(new BusinessException("boom"))`, asserts `Status.DAMAGE_FAILED`, `reason == FailureReason.DAMAGE_APPLY_FAILED`, `isWarning()`, a rendered description, `verify(adviceRepository).updateAdviceToStateById(eq(FINISHED), eq(1L))`, `verify(advicepositionRepository, never()).save(any())` | **P8 kill**: gating `self.markFinished(plan.adviceId())` on `damageOutcome == null` produced `Wanted but not invoked: adviceRepository.updateAdviceToStateById("FINISHED", 1L)` — names the broken thing. ⚠ **Shortfall:** the row's fourth assertion, `received == total`, is **not** made. `outcome.received()`/`outcome.total()` are never read; the factory sets both to `total` by construction, so an argument-order slip there is unguarded. |
| **T1.7b** | `applyDamage_returnsDamageFailedWhenSetLockDamagedThrowsUnchecked` | **ABSENT** | — | **P9**: narrowing the damage-loop catch from `catch (BusinessException \| FacadeException \| RuntimeException e)` to `catch (BusinessException \| FacadeException e)` left **147/147 green**. No test stubs `setLockDamaged` to throw an unchecked type. The plan calls this row "the one that actually matters" and states its mutation check explicitly; that check is not performed by anything in the tree. |
| **T1.8** | `applyDamage_damagesRemainingPositionsAfterFirstFailure` | **COVERED-ELSEWHERE** | `applyDamage_failureOnOnePosition_stillDamagesTheRest` — `verify(stockunitService, times(3)).setLockDamaged(any(), any(), any(), anyBoolean(), any());` plus `assertThat(outcome.failedSku()).isEqualTo("SKU001")` | **P7 kill** (re-run — see §4 note on a false green in the batch): inserting `break;` into the damage-loop catch produced `stockunitService.setLockDamaged(<any>,<any>,<any>,<any boolean>,<any>); Wanted 3 times: … but was 1 time`. The row says "position 2 fails, position 3 still damaged"; the built test fails position **1** and asserts positions 2–3 still ran. Same invariant, different index — accepted. |
| **T1.9** | `damageFailedOutcomeRendersWarningEnvelope` | **ABSENT** | — | **P4**: swapping `case DAMAGE_FAILED -> WmsConstants.getErrorCodeName(RETURN_AUTO_RECEIVE_DAMAGE_FAILED)` to `…(RETURN_AUTO_RECEIVE_PARTIAL)` left **147/147 green**. Nothing constructs a `DAMAGE_FAILED` outcome through `AdviceRestController`; the existing envelope tests (`ReturnAdviceAutoReceiveSoftFail.createReturns200WithWarningWhenAutoReceivePartiallyFails` etc.) all use `PARTIAL`. The service test asserts only `assertThat(outcome.code()).isNotNull()`, which the swapped constant satisfies. HTTP 200, the exact `warning.code` string, and a non-null `correlation_id` for this status are all unpinned. |
| **T1.10** | `damageIsAppliedOnlyWhenDamagedAmountPositive` | **ABSENT** *(case (b) covered; case (a) is not)* | case (b) → `applyDamage_passesDamagedSubsetAndTheReceivedStockunit`; the 204 + `notifieddamagedamount == 0` part of case (a) → `explicitZeroDamagedQuantityIsAccepted` | The row's defining assertion — `damaged = 0` produces **no** `setLockDamaged` interaction — exists nowhere: `git grep -n "never()).setLockDamaged" -- src/test` returns **no matches** (blind spot: this is a literal-text grep and would miss `verifyNoInteractions(stockunitService)` or a `verify(…, times(0))` spelling; I also grepped `setLockDamaged` across all of `src/test` and the only occurrences are the three positive verifies in the service unit test). **P11**: deleting the `if (line.damagedAmount() <= 0) continue;` guard *is* detected, but only incidentally, by two unrelated SBDEV-2778 tests whose message reads `expected: SUCCESS but was: DAMAGE_FAILED` — it names neither `setLockDamaged` nor the zero-damage guard, so under the plan's own attributability rule it is not a kill for this row. |
| **T1.11** | `ReceivingServiceUnitTest.receiveGoods_returnsCreatedStockunitIds` | **ABSENT** | — | `ReceivingServiceUnitTest.java` is **untouched** by this branch (`git diff --name-status origin/develop...HEAD` lists it nowhere). All 18 `receiveGoods` call sites in that class discard the return value — there is no `assertThat(...receiveGoods(...))` and no `List<Long>` local anywhere in the file. §5.2's checklist flags this row as the one "an implementer ticking boxes by class would drop", and that is what happened. I1 gives incidental end-to-end coverage (an empty or wrong list makes `applyDamage` throw), but only in the failsafe lane, and its message would read `DAMAGE_FAILED here means setLockDamaged threw` — which misdirects. The only edit to a receiving test is three `doNothing()` → `doReturn(List.of())` stub repairs in `ReceivingControllerUnitTest`, which assert nothing. |
| **T1.12** | `applyDamage_invokesSetLockDamagedWithDamagedAmountAndReceivedStockunit` | **COVERED-ELSEWHERE** | `applyDamage_passesDamagedSubsetAndTheReceivedStockunit` (its `@DisplayName` literally starts `"T1.12 — …"`) — captures the args and asserts `amount.getValue()` is `3` on a 3-of-10 fixture and `unit.getValue().getId()` is `7001L` | **P10 kill**: `new BigDecimal(line.damagedAmount())` → `line.amount()` produced `[must lock the DAMAGED subset (3), not the total (10) — an amount/damagedAmount swap lands here and nowhere else] expected: 3 but was: 10`. Exactly the mutant the row names, killed with an attributable message. Name differs only. |
| **T1.13** | `damageFailedPersistsNotifiedAmounts` | **COVERED-ELSEWHERE** | `AdviceRestControllerUnitTest$DamagedQuantity.presentDamagedKeyIsSummedIntoNotifiedamountAndRecorded` — 7+3 fixture, asserts `saved.getNotifiedamount()` is `10` and `saved.getNotifieddamagedamount()` is `3` off a captured `advicepositionRepository.save` | **P5 kill**: setting `notifiedamount` from the undamaged field only produced `[notifiedamount must be the TOTAL (7+3) …] expected: 10 but was: 7`. The row's stated mutation target ("setting `notifiedamount` from the undamaged field") is precisely what I reverted. |
| **T1.17** | `absentDamagedKeyDoesNotNpeAndLeavesColumnNull` | **BUILT** | same name, in `AdviceRestControllerUnitTest$DamagedQuantity`, **plus** a REGULAR sibling `absentDamagedKeyDoesNotNpeOnRegularAdvice` | Asserts `HttpStatus.NO_CONTENT`, `notifiedamount == 100`, `notifieddamagedamount == null`, and pre-asserts the fixture's absent key. Both required shapes (RETURN + REGULAR) present. The plan records this row as already mutation-proven 2026-09-16; I did not re-run that probe. |
| **T1.18** | `damagedFieldIsValidatedOnPathsThatSkipResolveRefs` | **BUILT** *(2 of 3 shapes)* | same name, same nested class | Shapes (1) REGULAR and (2) RETURN-with-auto-receive-off are both present with `-5000` and both assert `BAD_REQUEST`, closed by `verify(returnAdviceAutoReceiveService, never()).validate(any())`. ⚠ The third shape the row names — **a RETURN with an empty `positions` list** carrying `amount_of_bottles_damaged: -5000` — is **not** there. That shape is arguably unconstructible as written (an empty positions list has no position to carry the field), so this looks like an incoherent row rather than an omission; flagging it so the plan can be corrected rather than silently deviated from. |
| **T1.19** | `damagedPortionRecoveryWorklistExcludesRecoveredPositions` | **ABSENT** *(as specified)* | the stamp's two states **are** pinned: `applyDamage_success_stampsDamageApplied` (`assertThat(saved.getValue().getDamageappliedat()).isNotNull()`) and `applyDamage_failure_returnsDamageFailedAndStillFinishes` (`verify(advicepositionRepository, never()).save(any())`) | The row asks for a **worklist query** test — seed a recovered position, assert it is *absent* from the §3.2 worklist, plus a residual-window case. **There is no worklist in `src/main`**: `git grep -n "damageappliedat" -- src/main` returns only the entity field/accessors, three comments, and the stamp call — no repository method and no query. The worklist lives only in prose, so the row as written has no production code to grade. Note the `@DisplayName` on `applyDamage_failure_returnsDamageFailedAndStillFinishes` claims the id "T1.19", which is a **mislabel**: that test is T1.7a's behaviour. |
| **I1** | *(class `ReturnAdviceAutoReceiveIntegrationTest`, extend)* | **BUILT** *(one sub-assertion missing)* | `mixedReturn_receivesTotalAndLocksDamagedPortion`, `@DisplayName("I1 — …")` | Asserts every listed item: one stock unit at `entity_lock = QUALITY_FAULT` with `amount == 3` (the primary grade), unit load at location `Damaged` (secondary), one unlocked unit at `amount == 7`, a `DAMAGED` stockrecord **delta** of exactly 3, `notifiedamount == 10`, `notifieddamagedamount == 3`, `damageappliedat` non-null, `goodsreceiptposition` sum `10`, both states `FINISHED`. ⚠ **`HTTP 204` is not asserted** — the test deliberately drives `validate`/`bind`/`execute` directly and persists what the controller persists, so it never issues a request. The 204 for a clean auto-receive is covered separately by the pre-existing `ReturnAdviceAutoReceiveSoftFail.createStillReturns204OnFullSuccess`, but for a non-damaged fixture. |
| **I2** | *fully damaged line, `0 + 4`* | **ABSENT** | — | No test anywhere constructs a `0`-undamaged / positive-damaged advice. `git grep -n "I2 \|fullyDamaged\|fully damaged" -- src/test` → no matches (blind spot: matches the plan's row id and two obvious names only; I cross-checked by reading every `@DisplayName` in the five damaged-return test classes). Same underlying gap as T1.1. |
| **I3** | *`Damaged` row absent → 400 before save, advice count unchanged* | **COVERED-ELSEWHERE** *(two halves, both at a lower level than the row asks)* | (a) the rejection + no-save ordering → `resolveRefs_rejectsWhenDamagedLocationMissing`, ending `verify(adviceRepository, never()).save(any());` with the comment "create() is not transactional, so a post-save throw burns externalid permanently"; (b) the same invariant against a **real DB** → the pre-existing integration test `r9_validationRejection_persistsNoAdviceRow`, `assertThat(adviceRowCount(dto.getReferenceId())).isEqualTo(before)` | What would have to break for (a) to go red: removal of the `orElseThrow` on `locationRepository.findByName(STORAGE_LOCATION_DAMAGED)`, or hoisting it after the caller's save. ⚠ **Not covered:** the HTTP **400** status for this specific rejection, and a real-DB row count for *this* trigger — (b) exercises a wrong-type-printer rejection, not a missing `Damaged` row. The `never()` uses a **bare `any()`**, so the typed-matcher blind spot does not apply. |
| **I4** | *zero-damage regression at integration level* | **ABSENT** | — | The only integration test that actually receives is I1 (mixed). The pre-existing zero-damage integration case, `returnAdvice_endsFinishedWithGoodsreceiptPerPosition`, is `@Disabled(DEFERRED)` with an empty body and is not re-enabled by this branch. In particular **"no `DAMAGED` stockrecord on a zero-damage advice" is asserted nowhere** — the damaged-stockrecord delta is only ever asserted as a *rise*, never as a *zero*. |
| **I5** | *two `StockChangeDto` payloads, `normal +10 / damaged 0` then `normal 0 / damaged +3`* | **ABSENT** | — | `git grep -ln "StockChangeDto" -- src/test` lists 8 classes, **none** of them in `net.aim_ai.wms.integration` and none touching the return auto-receive path (blind spot: a test that asserted on the serialized JSON without naming the type would be missed; I cross-checked by grepping `notifieddamagedamount\|damagedAmount\|setLockDamaged` across `src/test`, which lists 9 files, and none of them is a message/notification test). The §7 preamble devotes ~25 lines to how this row's expected values were derived; the row itself does not exist. |
| **I6** | `v1/wms-api AdviceDtoUnknownPropertyToleranceTest` | **N/A** | — | Phase 2a, `v1/wms-api`. Out of Phase 1 scope per the task brief and §5.3. |

Rows `T2.x` / `T3.x` / `T4.x` (§7.1, `qa-api` and `qa-ui`) are Phases 2–4 and are excluded from the
table entirely rather than reported as gaps.

---

## 2. Counts and how the in-scope row list was derived

| Verdict | Count | Rows |
|---|---|---|
| **BUILT** | 3 | T1.17, T1.18, I1 |
| **COVERED-ELSEWHERE** | 7 | T1.3, T1.5, T1.7a, T1.8, T1.12, T1.13, I3 |
| **ABSENT** | 12 | T1.1, T1.2, T1.4, T1.6, T1.7b, T1.9, T1.10, T1.11, T1.19, I2, I4, I5 |
| **N/A (out of Phase 1)** | 1 | I6 |
| **Denominator (in scope)** | **22** | 17 unit + 5 integration |

Three of the seven COVERED-ELSEWHERE rows carry a **named shortfall** (T1.3's message key, T1.7a's
`received == total`, I3's HTTP status and real-DB trigger). They are still COVERED-ELSEWHERE because
the row's primary behaviour is pinned and killable; the shortfall is recorded so nobody reads the
verdict as "row fully satisfied".

**Derivation of the in-scope list — method and blind spots, stated inline as required.**

1. Read §7.1 (plan lines 1496–1527) and §7.2 (1528–1542) as tables and took every `id` cell.
2. Enumerated ids mechanically with `grep -o "T1\.[0-9]*[ab]\?" <plan> | sort -u` and
   `grep -o "\bI[1-9]\b" <plan> | sort -u`. That yields `T1.1–T1.13`, `T1.17–T1.19`, `I1–I6`, with
   `T1.7` split into `T1.7a`/`T1.7b`, i.e. **17 unit rows** and **6 integration rows**.
   **Blind spot:** this instrument only sees ids written with the literal `T1.` / `I` prefix. A row
   referred to as "row 14" or "the fourteenth row" would be invisible to it. I cross-checked the
   §7.1 table by reading it in full, and `T1.14`–`T1.16` do not exist as rows — the numbering skips
   from `T1.13` to `T1.17`, and §5.2's checklist line reads "Tests T1.1–T1.13" plus a separate
   mention of T1.11, consistent with that.
3. Scope filter: `I6` → `v1/wms-api` (Phase 2a) and every `T2.x`/`T3.x`/`T4.x` → `qa-api`/`qa-ui`
   (Phases 2–4), per the task brief and §5.2/§5.3. `T1.11` names `ReceivingServiceUnitTest`, which
   is `wms2-api`, so it stays **in** scope.
4. **No row in §7.1 or §7.2 is marked withdrawn or deferred by the plan.** (Instrument: read §7's
   full preamble at lines 1446–1496 plus every row cell; the only withdrawal language in the plan is
   §3.11's D8, which is a *design* decision, not a test row, and the §7.5 M-rows which are the
   manual plan and out of this lane's remit. Blind spot: a withdrawal recorded only in §10's
   "Resolved decisions" and not reflected in the §7 table would be missed — I spot-checked §10's
   heading list and found no test-row withdrawals, but did not read all 200 lines of §10.)

**Test-tree instrument.** The classes I inspected are exactly the six that
`git diff --name-only origin/develop...HEAD -- src/test` reports, plus `ReceivingServiceUnitTest`
(named by T1.11, and shown by the same command to be **untouched**). Blind spot: a row satisfied by
a test that existed on `develop` and was never modified would not appear in that diff — which is why
I additionally ran `git grep -ln "notifieddamagedamount\|AmountOfBottlesDamaged\|damagedAmount\|setLockDamaged" -- src/test`
(9 files, superset of the 6) and `git grep -ln "StockChangeDto" -- src/test` (8 files) before
calling I5 and T1.10 absent. `grep` here is `ugrep` and silently skips binary files without `-a`;
all paths queried are `.java` text, and `git grep` is unaffected by that behaviour regardless.

**Baseline.** Both unit classes are fully green at `e01bce85`: `ReturnAdviceAutoReceiveServiceUnitTest`
**72/72**, `AdviceRestControllerUnitTest` **75/75**, **147 combined, 0 failures, 0 errors**. Every
probe below is measured against that.

---

## 3. The ABSENT rows — what is unpinned, and what pinning it would cost

Ordered by what I would do first.

### 3.1 T1.7b — unchecked exceptions escaping the damage loop *(highest value)*
**Unpinned production behaviour:** the damage-loop catch is
`catch (BusinessException | FacadeException | RuntimeException e)`. The `RuntimeException` arm is the
only thing standing between a `PessimisticLockingFailureException` (the global 5 s `lock_timeout` on
`moveStockToNewDamagedContainer`'s opening `findByIdForUpdate`) or an `EntityNotFoundException` (the
two name-keyed `orElseThrow` sites inside `setLockDamaged`) and an **HTTP 500 raised after every
position has been received and before `markFinished` runs** — leaving the advice OPEN with all its
stock in, which is the double-receive hazard the two-loop ordering exists to prevent. P9 shows that
arm can be deleted with the suite green.
**Cost to pin: ~15 minutes.** Two cases in one method, copied from
`applyDamage_failure_returnsDamageFailedAndStillFinishes` with the stub changed to
`doThrow(new EntityNotFoundException("x"))` and `doThrow(new PessimisticLockingFailureException("x"))`.
Same four assertions. Build it now.

### 3.2 T1.9 — the `DAMAGE_FAILED` wire code and its 200 envelope
**Unpinned:** the `code()` switch arm for `DAMAGE_FAILED`, and the fact that a damage failure renders
a **200 + warning** rather than a 500 or a silent 204. P4 shows the arm can be pointed at
`RETURN_AUTO_RECEIVE_PARTIAL` (code 602 rather than 603) with the suite green — a consumer would then
be told "some stock is still on the dock" about an advice that is fully received, which is the exact
distinction §3.4 and the `damageFailed` factory's javadoc say the constant exists to carry.
**Cost: ~20 minutes.** One method in `AdviceRestControllerUnitTest$DamagedQuantity` modelled on the
existing `createReturns200WithWarningWhenAutoReceivePartiallyFails`, stubbing `execute` to return
`AutoReceiveOutcome.damageFailed(...)` and asserting `OK`, `warning.get("code")` equals
`"RETURN_AUTO_RECEIVE_DAMAGE_FAILED"`, and non-null `description` / `correlation_id`.
⚠ Context for whoever writes it: `AdviceRestControllerUnitTest extends BaseServiceUnitTest`, **not**
`BaseControllerUnitTest` as §7.4 row 4 assumes, so the assertion lands on the `ResponseEntity`, not
on serialized JSON. That is pre-existing and not something this ticket introduced, but the plan row
should be corrected rather than the base class changed. Build it now.

### 3.3 T1.1 / T1.2 / T1.4 — the whole `resolveRefs` validation tier *(one test file, do them together)*
Three separate mutants each survive the full suite (P3, P12, P2):
- **T1.1** — the `undamaged >= 1` → `total >= 1` relaxation. Revertible silently. Today qa-api never
  emits a `0 + N` line, so the live blast radius is nil; the exposure is that the forward-readiness
  §3.1 claims, and which OQ-2's flip depends on, is an untested assertion.
- **T1.2** — `amount_of_bottles_damaged < 0` in `resolveRefs`. The controller loop catches it first
  on every path, so deleting this check changes no observable behaviour **today**; it becomes live
  the moment anything reorders those two tiers. Lowest urgency of the three.
- **T1.4** — the cap graded on the total. This one has teeth: with the mutant in place a caller can
  pass `100_000` in each field and have `resolveRefs` accept `200_000` units. The controller-tier cap
  does reject it, so it is defence-in-depth rather than a live hole — but it is exactly the
  "two tiers cannot drift apart" property the `public static final MAX_UNITS_PER_POSITION` comment
  claims to buy, and nothing currently holds it.
**Cost: ~30 minutes for all three**, as three short methods beside the existing
`resolveRefs_acceptsATotalOfExactlyOne`, reusing `validReturnDtoWithDamaged`. T1.4's fixture must be
`99_999 + 2` as the row specifies, so the `<`→`<=` boundary mutant lands in the dominant band.

### 3.4 T1.10 (case a) and T1.6 — the zero-damage guard and `bind`'s zip
**Unpinned:** (a) that a `damaged = 0` line never touches `setLockDamaged` — currently only detected
incidentally, with a message naming neither; (b) that `bind` carries `damagedAmount` through at all
(P13: a constant `0` is green at unit level, and I1's single-position fixture cannot see a mis-zip
either — it would only see a constant 0, and then only via the integration lane).
**Cost: ~20 minutes.** Add `verify(stockunitService, never()).setLockDamaged(any(), any(), any(), anyBoolean(), any())`
as a second case inside the existing T1.12 test method — that gives the row the paired
positive/negative shape the plan demands, with the positive half already written. For T1.6, one
`bind` test with two positions carrying **different** damaged values (e.g. 3 and 5) so a positional
swap is visible, asserted on `plan.lines()`.
⚠ Watch the varargs trap when writing the `never()`: `setLockDamaged`'s fourth parameter is a
primitive `boolean`, so it must be `anyBoolean()` — `any()` returns `null` and NPEs at unboxing.

### 3.5 T1.11 — `receiveGoods` returning the created stock unit ids
**Unpinned:** the signature change the entire damage pass depends on. Nothing in
`ReceivingServiceUnitTest` reads the returned list; a `return List.of()` or a list of the wrong ids
is invisible to the unit lane, and reaches only I1, in the failsafe lane, with a misdirecting message.
**Cost: ~20 minutes**, and it needs the existing fixture in that class, which already drives
`receiveGoods` 18 times. One method: capture the created `Stockunit` (or read it back off the
`stockunitRepository.save` captor) and assert the returned id **is** that entity's, for
`amountCases = 1` and again for a multi-case call, so a positional coincidence is excluded.

### 3.6 T1.19 — the recovery worklist
**Unpinned:** the worklist itself, because it does not exist in code. The two stamp states *are*
pinned. This row cannot be built as written without first deciding whether the worklist is a
repository method or stays a runbook query. **Cost: 0 to defer, ~45 minutes if a
`findByNotifieddamagedamountGreaterThanAndDamageappliedatIsNull` derived query is added** (plus the
repository-test traps: wms2 repository tests commit rather than roll back, so assert by id).
**Recommendation: defer, and correct the row** — and separately fix the mislabelled `@DisplayName`
on `applyDamage_failure_returnsDamageFailedAndStillFinishes`, which currently claims id "T1.19" for
T1.7a's behaviour. That mislabel is how a name-matching sweep would wrongly score T1.19 as built.

### 3.7 I2 / I4 / I5 — the missing integration rows
- **I2** (fully damaged, `0 + 4`): shares T1.1's gap. **~30 min** as a second method in
  `ReturnAdviceAutoReceiveIntegrationTest` cloned from I1 — but note the row's own warning: assert
  `sum(amount) where entity_lock = 0` is `0`, **not** a row count, because `transferStockToUnitLoad`
  can leave a zero-amount unlocked row depending on the fixture's fix-location state.
- **I4** (zero-damage regression): **~25 min**, same clone with the damaged key absent, asserting one
  unlocked unit, `204`-equivalent outcome `SUCCESS`, and **a `DAMAGED` stockrecord delta of exactly
  `0`** — the assertion that currently exists nowhere in either direction.
- **I5** (two `StockChangeDto` payloads): **~1 hour and the most fragile.** The row demands assertion
  on the **serialized payload** because `getStockChangeDTO` takes positional `int` arguments where an
  order mutant survives a mock-interaction assertion. Nothing about the OMS wire for this path is
  currently pinned at any level. Given §7's own 25-line treatise on how this row's expected values
  were derived, shipping Phase 1 without it is the largest single divergence between the plan's
  stated intent and the tree.

**If only three are built before merge:** T1.7b, T1.9, and T1.4. Those are the three where the
surviving mutant changes what a caller or an unauthenticated client can actually observe.

---

## 4. Commands run

All runs in `/home/nampark/dev/wms-claude/.claude/worktrees/wms2-api/SBDEV-1512-rowcheck` with
`PATH="$HOME/.sdkman/candidates/maven/current/bin:$HOME/.sdkman/candidates/java/current/bin:$PATH"`
(Java 21.0.11, Maven 3.9.15). Production files were copied to a scratchpad backup before any
mutation and restored from it after each; `git status --porcelain` is **empty** and both files'
md5sums match the backup at the end. **No `git checkout --` / `restore` / `stash` was run.**

### 4.1 Inspection

| Command | Result |
|---|---|
| `git log --oneline -3` / `git rev-parse HEAD` | detached at `e01bce85` "SBDEV-1512: close the boundary gaps PIT found" |
| `git diff --name-status origin/develop...HEAD` | 6 main + 1 migration + 6 test paths; `ReceivingServiceUnitTest` **not** among them |
| `git diff --stat origin/develop...HEAD -- src/test` | 6 files, +1069 / −11 |
| `grep -o "T1\.[0-9]*[ab]\?" <plan> \| sort -u` | T1.1–T1.13, T1.17–T1.19 (+T1.7a/b); no T1.14–T1.16 |
| `grep -o "\bI[1-9]\b" <plan> \| sort -u` | I1–I6 |
| `git grep -n "never()).setLockDamaged" -- src/test` | **no matches** (drives T1.10 ABSENT) |
| `git grep -ln "StockChangeDto" -- src/test` | 8 classes, none on the return auto-receive path (drives I5 ABSENT) |
| `git grep -n "damageappliedat" -- src/main` | entity field + accessors + 3 comments + the stamp call; **no query** (drives T1.19) |
| `git grep -n "DAMAGE_FAILED\|damageFailed" -- src/main src/test` | 1 `code()` arm, 1 factory, 2 constants; no controller-level test |
| `grep -n "= receivingService.receiveGoods\|List<Long>" ReceivingServiceUnitTest.java` | **no matches** (drives T1.11 ABSENT) |
| `grep -n -A12 "failsafe" pom.xml` | surefire **excludes** `**/*IntegrationTest.java`; failsafe **includes** it — I1 runs only in `mvn verify` |
| surefire XML `testcase name=` for `…$FollowUpRegression` | the 8 SBDEV-1512 service tests execute **inside** the `FollowUpRegression` nested class (9 tests), not at class top level as their indentation suggests. They do run; the placement is cosmetic and worth tidying. |

### 4.2 Baseline and mutation probes

`mvn -o test -Dtest='<selector>' -Dsurefire.failIfNoSpecifiedTests=false`, selector
`ReturnAdviceAutoReceiveServiceUnitTest,AdviceRestControllerUnitTest` unless noted.

| # | Mutation (reverting the behaviour a row guards) | Expectation | Result |
|---|---|---|---|
| — | **baseline**, unmutated | green | **147/147 green** (72 service + 75 controller) |
| **P1** | `resolveRefs`: `if (totalAmount < 1)` → `if (false)` | RED (T1.3) | **KILLED** — `MirroredPositionChecks.validateThrowsWhenAmountOfBottlesIsZero:477 Expected …WebserviceBusinessExceptionClientSide to be thrown, but nothing was thrown.` 72 run, 1 failure |
| **P2** | `resolveRefs`: cap on `totalAmount` → cap on `position.getAmountOfBottles()` | RED if T1.4 built | **SURVIVED** — 147/147 green |
| **P3** | `resolveRefs`: `totalAmount < 1` → `position.getAmountOfBottles() < 1` | RED if T1.1 built | **SURVIVED** — 147/147 green |
| **P4** | `code()`: `case DAMAGE_FAILED ->` returns `RETURN_AUTO_RECEIVE_PARTIAL`'s name | RED if T1.9 built | **SURVIVED** — 147/147 green |
| **P5** | controller: `setNotifiedamount(BigDecimal.valueOf(totalNotified))` → `new BigDecimal(getAmountOfBottles())` | RED (T1.13) | **KILLED** — `presentDamagedKeyIsSummedIntoNotifiedamountAndRecorded:1822 [notifiedamount must be the TOTAL (7+3)…] expected: 10 but was: 7` (also `totalAtExactlyTheCapIsAccepted`) |
| **P6** | `resolveRefs`: `if (lines.stream().anyMatch(l -> l.damagedAmount() > 0))` → `if (true)` | RED (T1.5) | **KILLED** — `resolveRefs_doesNotRequireDamagedLocation_whenNothingIsDamaged:1793 » WebserviceBusinessExceptionClientSide entity %1s does not exists…`; ⚠ blast radius 14 errors, red arrives at `validate`, not at the `never()` |
| **P7** | damage loop: `break;` inserted into the catch | RED (T1.8) | **KILLED** on re-run — `setLockDamaged(…); Wanted 3 times … but was 1 time` at `applyDamage_failureOnOnePosition_stillDamagesTheRest:1675`. ⚠ **The batch run reported a FALSE GREEN**: the batch's `sed` replacement contained a raw newline, so GNU `sed` errored and the mutation never applied while `mvn` ran clean and exited 0. I caught it by re-applying the `sed` by hand, diffing the result, and re-running. Recorded because it is the same class of defect the repo's "a no-match selector leaves a stale verdict" note describes. |
| **P8** | `self.markFinished(plan.adviceId());` → gated on `damageOutcome == null` | RED (T1.7a) | **KILLED** — `applyDamage_failure_returnsDamageFailedAndStillFinishes:1649 Wanted but not invoked: adviceRepository.updateAdviceToStateById("FINISHED", 1L)` |
| **P9** | damage-loop catch narrowed to `BusinessException \| FacadeException` | RED if T1.7b built | **SURVIVED** — 147/147 green |
| **P10** | `setLockDamaged(received, new BigDecimal(line.damagedAmount()), …)` → `line.amount()` | RED (T1.12) | **KILLED** — `applyDamage_passesDamagedSubsetAndTheReceivedStockunit:1616 [must lock the DAMAGED subset (3), not the total (10)…] expected: 3 but was: 10` |
| **P11** | damage loop: `if (line.damagedAmount() <= 0) { continue; }` → `if (false)` | RED, attributably, if T1.10(a) built | **KILLED ONLY INCIDENTALLY** — 2 failures, both in unrelated SBDEV-2778 tests, message `expected: SUCCESS but was: DAMAGE_FAILED`; nothing names the guard or `setLockDamaged` |
| **P12** | `resolveRefs`: `if (rawDamaged != null && rawDamaged < 0)` → `if (false)` | RED if T1.2 built | **SURVIVED** — 147/147 green |
| **P13** | `bind`: `line.damagedAmount()` → `0` in the `AutoReceiveLine` constructor | RED if T1.6 built | **SURVIVED** — 147/147 green |
| — | final `md5sum` of both production files vs backup; `git status --porcelain` | identical / empty | **worktree restored clean** |

**What these probes cannot tell you.** Every probe ran the **surefire** lane only. `I1` and the two
schema integration tests live in failsafe (`**/*IntegrationTest.java` is explicitly excluded from
surefire) and were **not** executed by this lane at all — so every I-row verdict above is derived
from reading the test source and from the plan's own assertions about the lane, not from a run. In
particular I did not verify that I1 currently passes. A mutant that only I1 catches would read as
"SURVIVED" in P2/P3/P4/P9/P12/P13; for P13 specifically I have said so inline, and for the others the
mutated code sites (`resolveRefs` validation tiers, `code()`) are not exercised by I1's assertions.

---

## 5. Two things outside the §7 remit, noted because they change the row picture

1. **A `@DisplayName` mislabel that a name-matching sweep would score as coverage.**
   `applyDamage_failure_returnsDamageFailedAndStillFinishes` is titled `"T1.19 — …"`. Its behaviour is
   **T1.7a**'s. Anything grading rows by display name will report T1.19 built and T1.7a absent —
   exactly inverted from the truth.
2. **§5.2's FU-2 item was not done.** The Phase 1 checklist says, in bold, "**FU-2 — fix it here, in
   this edit**" (the `Boxtype boxtype = optionalBoxtype.get()` NPE on a REGULAR advice with no
   `box_id`), and asks for a test alongside T1.18. The implementation instead records the opposite
   decision in a code comment: *"That is pre-existing (FU-2), it is **NOT** fixed here."* That is a
   defensible scope call, but it is a deviation from the reviewed plan rather than a completed item,
   and it is not a §7 row, so no row above reflects it.
