**VERDICT: APPROVE.** Round 2b is ready for the TDD gate. Everything that remains is Low and can be fixed while writing the tests.

I checked against wms2-api `origin/develop` d9be4188 and wms2-mobile-ui `origin/develop` 5e99732. These claims hold in the code:
- the pre-validate, recovery-save and parcel-guard ordering (`CancellationReversalService:206-288`);
- the restore block (:419-431);
- the level-triggered enqueue (:454-457);
- `BusinessException` and `FacadeException` are checked exceptions, so T18b's "drop rollbackFor" mutant can be killed;
- the recovery needs `pul.unitload_id` (`CancellationLogService:114-138`);
- `UNIT_LOAD_TYPE_TOTE`/`PACKAGE` at `WmsConstants:872-873` and the `WEB_UI_ACTION_*` family at :426-433;
- `findParcelGuardViewById` at `UnitloadRepository:44` and `UnitloadTypeRepository.findByName`;
- the LockClear IT's Case-type tote, `setOrderbatchId(1L)`, the pending sibling, and the Tote `findByName` precedent;
- mobile `store/cancellation.js` :250-253 (`if (outcome.message)`) and `completeReversal`'s `applied`/`message: null`.

**Stale-phrase grep** (plan + ralplan-dr, for "three-state", "edge trigger in both", "outbox rows = 1", "Testcontainers IT (tenant", "onTote"): no stale text left. The remaining hits are "onTote" as a mutant name in T3/T5/T5b/T21b/§7.2, and "edge trigger in both" in §10, where it is quoted as the withdrawn default. Both are correct uses.

### Landed-check: round-1 change list
1. ok. `toteState` now has four states (it had three in r2). (i′) clears only when ON. Rows (ii)–(iii-d) are rewritten, and §3.4 uses `≠ OFF`.
2. ok. §3.2 step 5 has the recovered-SU guard, and T3 pins it.
3. ok. The ownership rule declines on null (§3.2), with a T3 row, but see finding 2.
4. ok. §3.3.2 has the exact predicate, ANDed on. It is struck from §6 "What does NOT change", and T22 exists (but see finding 1).
5. ok. The level/edge wording is consistent across §1, §3.3.1, §6, §7.5 #6, §10, the ADR and RALPLAN-DR Option 1. T19 is inverted.
6. ok. Distinct-id rules, T5b, T22, T4 non-null ids, T18 on H2 by `aggregate_id`, T18b, the T17 role-name set, the T21a/b split and the T8 cap are all present.
7. ok. §3.5 item 1 cites :426-433 (verified).
8. ok. §3.8 has the `waivePosition` `reversalWaived` check and `applied && !p.reversalWaived`.
9. ok. SET 9 runs before and after, at dev and at PRD (§5.1 #7, M7, §8 steps 1/4/5).
10. ok. §8 5a/5b are gating pre-steps, and "allowed because case (i)" is gone.
11. ok. M1 and M3 have recipes, and M6 compares an `array_agg` role set.
12. ok. §9 has 1′, and so does RALPLAN-DR.
13. ok. Row 34 is deleted with its reason.
14. ok. F3 and F4 are recorded as Resolved in §10, O4 is added, and §5.1 #6 flags OMS alerting as UNVERIFIED.

### Landed-check: architect round-2 findings
1. ok. PARCEL is its own state, (ii′/ii″/iii-b/iii-d) refuse it, T4 has the "Package treated as OFF" mutant, and the §0 blind spot is added.
2. ok. The new fixture builder has 6 steps, including the Tote `findByName` (matches IT precedent :647), `pul` id ≠ tote id, the batch, the `@MockitoSpyBean` sysprop and no sibling. The positive control is added.
3. ok. T18 expects 1, then 2 for `true`, and 0 → 0 for `false`. This is right: the plan correctly departs from the architect's "stays at 1", because suppression also applies to the closing call.
4. ok. `waivedShare` is computed before the loop from `findByCustomerorderId`, the AUTO-flush reason is given, and the "sum taken from `logs`" mutant is named.
5. ok. The message is non-null, `toastError` is called, and Jest pins the `SET_REFUSALS` entry.
6. ok. The permanent strand is stated with "0 live rows" in §3.2 step 5, the ADR and the RALPLAN-DR Cons.

### Remaining findings (all Low: fix during implementation)
None of these encodes a wrong contract. Four of them are fixtures that cannot kill a mutant their row names. The mandatory mutation check would catch those too, but fixing them now saves a loop.

**1. Low: T22 cannot kill two of its named mutants.**
- **"Drop the `anyNull` guard" survives** if the implementation skips nulls in the sum. In the plan's variant (A=null, B=2, SU=3), `waivedShare` becomes 0, the residue is 1, 1 > 0 means restore, lock 100. That is the expected result, so the mutant passes.
- **"Standalone OR" also survives.** Both variants have a residue that is > 0 and < before, so the bypassed conjuncts never matter.
- **Fix:** add two variants to the T22 row:
  - (c) A1(null) and A2(1) waived `false`, then complete B(2) on SU 3. The residue is 1, equal to the non-null share, and it must end at **lock 100**. This kills "drop anyNull".
  - (d) A(null) waived `false`, then complete B(3) on SU 3. B drains the SU (residue 0, or it leaves the unit load), and it must **not** be set to lock 100. This kills "standalone OR".

**2. Low: T3's "null `amountPicked` → kept" cannot kill "drop the null guard".** If the null is skipped, Σ shrinks and `su.amount > Σ` keeps the lock anyway.
- **Fix:** T3 null fixture: "A(null) and B(3) both waived in this call, SU amount 3, lock 100, ON → kept". With the guard dropped, Σ=3 and the mutant clears.

**3. Low: T7's mutant only dies if the first waive closed the CO with `stockReturned=true`.** With `false`, suppression hides the enqueue. With a pending sibling, the level check hides it.
- **Fix:** T7 text: "the first waive closed the last row with `stockReturned=true`; the second call → `enqueue` never, `logRepository.save`/`stockunitRepository.save` never".

**4. Low: the T18 row shapes are not stated, and a natural reading makes the waive refuse.** With the builder's ON tote, a `stockReturned=true` waive is allowed only at amount 0 (i′). Row (ii) refuses it.
- **Fix:** T18 text: "the waived row's SU: amount 0, lock 100, ON (i′). The completed row: a **distinct** SU, amount > 0, lock 100."
- **Related:** no unit row asserts that (i′)-ON actually clears, so a "never clear in (i′)" mutant survives T1–T5. Add "(i′) lock 100 ON, not recovered → cleared" to T2's asserts.

**5. Low: the T18b fixture needs the recovery's inputs.** The recovery reads `pickingorderPositionRepository.findByCustomerorderpositionId → itemdataId`, then `pickingorderUnitloadRepository.findById(picktounitloadId).getUnitloadId()`.
- **Fix:** add a step 7 to the builder: "for T18b only: log `picktostockunitId` null, `pul.unitload_id` = tote id, a `PickingorderPosition` with the SU's itemdata".
- Name the refusal trigger: ON, amount > 0, lock 100, `stockReturned=true` (row ii).

**6. Low: T17's "re-run idempotent" must count rows after the second run.** The function row should be 1 per name and the grant rows 2. "No error" is not enough: these tables have no unique indexes, so an `ON CONFLICT DO NOTHING` seed runs cleanly and duplicates. Only a count kills the `ON CONFLICT` mutant T17 names.
- **Fix:** T17 text: "after a second apply: `count(*)` function rows by name = 1, grant rows = 2, role set unchanged".

**7. Low, cosmetic:** the §0 numbering skips row 30. Either note "30 intentionally unused" or renumber.

**Nothing new at Medium or above.**
- **Concurrency:** waive and complete on the same CO both take the pending-row FOR UPDATE finder keyed by `coId`, so a waive of A and a complete of B are serialized. Pick-to SUs are per order.
- **Rollback:** it depends on checked exceptions plus `rollbackFor`, which is verified.
- **§8 PRD step:** gated by 5a/5b, run by an operator with no SQL writes, and M1 predicts one outbox row after four single-position waives.

### Ralplan summary
- **Principle/Option consistency: Pass.** Principle 2's three clauses map onto `toteState` fail-closed, the recovered guard and the waive-aware restore. Option 1's wording matches settled F3/F4.
- **Alternatives depth: Pass.** 1′ is argued fairly and rejected under Driver 2. Options 2 and 3 are tied to settled Q2 and Q5.
- **Risk/Verification rigor: Pass, with findings 1–6.** Every other T-row has a fixture that can tell its mutant apart. §8 is gated by evidence and a destination check. SET 9 timing is correct for a Flyway-on-merge deploy.
- **Deliberate additions:** N/A (SHORT mode).

**Mode:** THOROUGH. I did not escalate, because there were no Critical or Major findings.

**Files reviewed:**
- `/Users/np1076/dev/spk/owl/sbdocs/1-Projects/wms2/plan/SBDEV-3381-cancellation-reversal-waive.md`
- `/Users/np1076/dev/spk/owl/sbdocs/1-Projects/wms2/plan/SBDEV-3381-evidence/{ralplan-dr,critic-review-r1,architect-review-r2,r2-changelog,r2b-changelog,analysis}.md`
