head: 560aeb45

# SBDEV-3353: P4 scoped review of the P3-Lows fix commit

- **Scope:** `git show 560aeb45` only (6 files, +40/−8) — the commit that closes P3-1..P3-4 from `p3-rereview.md` (head `ee40d348`).
- **Tree:** `.claude/worktrees/wms2-api/SBDEV-3353-review`, detached at `560aeb45`, mine alone.
- **Reviewer:** an independent lane (code-reviewer). It did not author `560aeb45`, `p3-rereview.md`, or any earlier SBDEV-3353 commit.
- **Verdict: APPROVE.** No CRITICAL or HIGH finding. All four P3 items are correctly closed. One MEDIUM finding on a pre-existing (not newly introduced) rule blind spot that the new test lines also fall into, plus two LOW/cosmetic notes.

## Instruments run

| What | Result |
|---|---|
| `pgrep -fl "surefire\|failsafe"` before any Maven run | Empty — safe to run. |
| `git grep -in "fail-closed\|fail closed"` over the 27 files touched since `5fa9bef0` | 3 hits, all in `UnitloadServiceUnitTest.java` (lines 1991/2119), about `isCartCarrier`/a different predicate — unrelated to the parcel guard. **Zero** hits in guard-related text. P3-1 confirmed closed with no missed sibling. |
| `git grep -in "writes nothing"` over the same file set | 1 hit: `CancellationReversalServiceUnitTest.java:1038`, the copy P3-2's own recommendation said to leave as-is ("this fixture's refusal writes nothing … in general it COMMITS nothing"). Matches exactly. No orphaned generic claim remains. |
| `git grep -in "unreachable"` over the same file set | `SourceContainerGuardUnitTest.java:42` still contains "unreachable" — read in context it is the deliberate contrast "absent, not unreachable," not a leftover. Confirmed by reading the full sentence. |
| `mvn -o -ntp test -Dtest=SourceContainerGuardUnitTest` at `560aeb45` (before mutation) | 16/0/0/0. |
| **Mutant M1** (re-run by me): drop `@RestResource(exported = false)` from `UnitloadRepository.findParcelGuardViewById` (`:42`), via a scratch copy restored under an EXIT trap, `cmp`-verified identical afterward | **1 red, 0 error**, in `findParcelGuardViewById_shouldNotBeExportedOverSpringDataRest`: `AssertionError: [UnitloadRepository.findParcelGuardViewById must carry @RestResource(exported = false)] Expecting actual not to be null`. Matches the claim exactly. Working tree confirmed clean after restore. |
| M2 (inject `stockunitRepository.findAllById` before the guard) | **Not re-run.** Plausible by inspection (the new `never(...).findAllById(any())` verifications are on `stockunitRepository` and `unitloadRepository` directly, matching the described shape), but not independently verified — see Open Questions. |
| `mvn -o -ntp test -Dtest=NeverMatcherNullBlindnessArchTest` | 4/0/0/0 (green), but see Finding 1 — green does not mean the new lines were scanned. |
| `mvn -o -ntp test -Dtest=StockunitServiceParcelSourceRefusalUnitTest,CancellationReversalServiceUnitTest,CancellationReversalParcelSourceIntegrationTest -Dsurefire.failIfNoSpecifiedTests=false` | 74/0/0/0. No regression from the wording/pin changes. |

## (1) Each P3 finding closed at every copy

| Finding | Status | Evidence |
|---|---|---|
| **P3-1** ("Fail-closed" capitalised copy) | **CLOSED** | `StockunitServiceParcelSourceRefusalUnitTest.java:90` now reads "Fail-open (proceed-unguarded): an unresolvable unit load or type is NOT treated as a parcel, so the move proceeds and a WARN is logged." Case-insensitive sweep over the branch's touched files finds zero remaining `fail-closed`/`fail closed` tied to this guard. |
| **P3-2** (sibling "writes nothing" copies) | **CLOSED**, correctly with one deliberate exception | `StockunitService.java:328-329` and `CancellationReversalParcelSourceIntegrationTest.java:52-56` now say "commits nothing (rolls back with it)". `CancellationReversalServiceUnitTest.java:1037-1039` keeps "writes nothing" but scopes it explicitly to "this single-position fixture" and adds the general "in general it COMMITS nothing" clause — exactly the fix p3-rereview itself recommended for that one copy. No sibling was missed. |
| **P3-3** (test coverage shape / SDR pin) | **CLOSED** | Two `never(...).findAllById(any())` verifications added to the N1 test (`StockunitServiceParcelSourceRefusalUnitTest.java:793-799`), plus a new reflection pin test asserting `@RestResource(exported=false)` on `findParcelGuardViewById`. Both mutation-checked; M1 re-confirmed by me (see above). |
| **P3-4** (wording/line-drift) | **CLOSED** | `SourceContainerGuardUnitTest.java:39-42` now reads "No row reaches those branches on any of 6 tenants today … measured 2026-09-24. That makes them absent, not unreachable" — correct completeness word, and the old word is kept only as the explicit contrast, not as a residual claim. `SourceContainerGuard.java:58-61` javadoc now names the two `assertNotParcel` callers (mobile Move Unit Load, putaway) and states they hand over an already-loaded entity. |

## (2) New comments verified

**"the SBDEV-3316 heal save rolls back."** `CancellationReversalService.java`: `completeReversal` is `@Transactional(value = "tenantTransactionManager", rollbackFor = {BusinessException.class, FacadeException.class})` (line 199). The recovery `log.setPicktostockunitId(recovered); logRepository.save(log);` runs at lines 240-241, inside the same `for` loop, before `SourceContainerGuard.assertStockNotInParcel(...)` at line 288 — same method, same transaction. `assertStockNotInParcel` → `assertUnitloadNotParcel` → `judge()` throws a keyed `BusinessException` on refusal (`WmsConstants.MSG_TRANSFER_SOURCE_IS_PARCEL`), which is in `rollbackFor`. **Confirmed true**: the save is rolled back together with everything else in the transaction if the guard refuses.

**"the `assertNotParcel` callers hand over a unit load they already loaded; only the type row is read."** `SourceContainerGuard.java:120-127`: `assertNotParcel(Unitload sourceUnitload, UnitloadTypeRepository unitloadTypeRepository)` reads only `sourceUnitload.getId()/getTypeId()/getLabelid()` off the parameter, then delegates to `judge()`, which calls only `unitloadTypeRepository.findById(...)` — no call to `unitloadRepository` anywhere in this path. Both call sites pass an entity the caller already holds: `MobileMoveUnitloadService.java:636` passes `sourceUnitLoad`, a parameter of the enclosing private `transferStock(Unitload, Unitload)`; `MobilePutAwayService.java:552` passes `unitLoad`, loaded at `:512-513` via `unitloadRepository.findByLabelid(...)` earlier in the same method, before the guard call. **Confirmed true** at both sites.

## (3) The new `never().findAllById(any())` verifications

**Matcher choice.** Bare `any()` against `findAllById(Iterable<ID>)` is the compliant, non-null-blind form per this repo's own SBDEV-3170 convention (`NeverMatcherNullBlindnessArchTest`'s own javadoc: bare `any()` is correct wherever the parameter is a reference type, which `Iterable` is — no unboxing hazard). So the matcher itself is right.

**[MEDIUM] Finding: these verify calls (and the 7 pre-existing sites of the same shape in this ticket's tests) are structurally invisible to `NeverMatcherNullBlindnessArchTest`, so "ran green" is not evidence they were checked.**
- **Confidence:** HIGH (empirically verified).
- **Files:** `StockunitServiceParcelSourceRefusalUnitTest.java:793-799` (the 2 new sites), and pre-existing sites at `:620`, `:622`, `:790`, `:796`, `:801`, `:804`, and `SourceContainerGuardUnitTest.java:211`.
- **Issue:** `NeverMatcherNullBlindnessArchTest`'s `NEVER_VERIFY` regex is `\bverify\s*\(\s*\w+\s*,\s*never\s*\(\s*\)\s*\)\s*\.\s*\w+\s*\(` — it requires `never()` to be followed immediately by the verify call's closing `)`. Every site above instead chains `never().description("...")` before that `)`, e.g. `verify(stockunitRepository, never().description("SBDEV-3353 N1/P3-3: …")).findAllById(any());`. I confirmed with the identical pattern in a standalone regex test: the plain form `verify(x, never()).findAllById(any())` matches (1 match), the `.description(...)`-chained form does not (0 matches). Because the whole span fails to open, the offender-scan inside it never runs, and the span is not counted toward `neverSpans` either — so the rule's floor assertion (`neverSpans > 400`) does not need bumping, but only because these sites were never inside its denominator to begin with. The class's own "What is deliberately NOT flagged" section (which lists qualified `Mockito.never()`, `MockedStatic`, `BDDMockito.should(never())`, `times(0)`, non-identifier mocks, explicit type witnesses, and matchers hidden behind helpers) does **not** mention `.description()`-chained `never()` as a gap, so this rule's own coverage claim is itself stale/incomplete. This is **not introduced by 560aeb45** — the `.description()` idiom predates this commit in this file — but this commit adds 2 more instances of the exact blind shape without noting the gap, and the practical safety net for "N1/P3-3 stays caught if a future edit widens `any()` to a reference-typed matcher" currently rests entirely on nobody doing that, not on this ArchUnit rule.
- **Fix:** widen `NEVER_VERIFY` to tolerate an optional `\.\s*description\s*\(.*?\)` (or, more robustly, any chained no-effect call) between `never\(\s*\)` and the closing `\)`, then re-measure `neverSpans`/`scanned` floors; or explicitly add this shape to the "what is deliberately not flagged" list so the gap is at least documented. Either is appropriate for a follow-up ticket, not a blocker for this one — the two new verifications still fire correctly today via Mockito's own strict verification (independent of this ArchUnit rail), which is what M2 exercises.

## (4) The `@RestResource` pin test's `getMethod(..., Long.class)` and signature drift

`SourceContainerGuardUnitTest.java:257-261`: `UnitloadRepository.class.getMethod("findParcelGuardViewById", Long.class)`. If a future edit changes the method's parameter type or count (e.g. adds a second parameter, or narrows/widens `Long`), `getMethod` itself throws `NoSuchMethodException` — the test method declares `throws NoSuchMethodException`, so JUnit reports this as a **test error** (uncaught exception), not as the custom `AssertionError` the test's own `.as(...)` messages would produce.

**Is that acceptable?** Yes. `NoSuchMethodException`'s own message names the exact class and signature being looked up (`net.aim_ai.wms.repo.jpa.UnitloadRepository.findParcelGuardViewById(java.lang.Long)`), so the stack trace alone tells a developer precisely what changed — this is an attributable kill, just delivered as a JUnit "Error" rather than a "Failure," which is the ordinary and accepted shape for reflection-based pin tests elsewhere in this codebase (e.g. `StartApplicationAutoConfigurationExclusionUnitTest`-style pins). No fix needed.

## (5) Mutation results

- **M1** — re-run by me, confirmed exactly: dropping `@RestResource(exported = false)` from `findParcelGuardViewById` produces **1 red, 0 error** in `SourceContainerGuardUnitTest`, specifically `findParcelGuardViewById_shouldNotBeExportedOverSpringDataRest`, with the named assertion message. All 15 other tests in the class stayed green (isolated kill). File restored and `cmp`-verified identical to the pre-mutation copy; `git status` confirmed clean afterward.
- **M2** — not re-run (not required to be cheap-verified per the task; flagged as an open question below). Plausible by code inspection: the new verifications target `stockunitRepository.findAllById(any())` and `unitloadRepository.findAllById(any())` directly with descriptions naming "N1/P3-3", matching the claimed kill shape.

## Additional cosmetic note

- **[LOW] Inline fully-qualified `RestResource` type instead of an import.** `SourceContainerGuardUnitTest.java:258,260` write `org.springframework.data.rest.core.annotation.RestResource` twice inline rather than adding an import — no other line in the file needs that FQN to disambiguate. Cosmetic only; does not affect correctness or maintainability materially. Fix (optional): add the import and use the simple name.

## Open Questions (not blocking)

- **M2 not independently re-run** (LOW confidence in my verification, MEDIUM in the orchestrator's claim by consistency of shape). If wanted, re-run is cheap: temporarily add `stockunitRepository.findAllById(List.of(sourceStockunit.getId()))` (or equivalent) ahead of the guard call in `StockunitService.transferStock` and confirm both new `never()` verifications go red with "N1/P3-3" in the message.

## Positive observations

- All four P3 findings are closed correctly, including the one nuanced case (P3-2's unit-test copy) where the "right" fix was to *keep* the specific wording while adding the general clause — the commit got that nuance right rather than mechanically replacing every occurrence.
- The P3-1 sweep this time was demonstrably case-insensitive (the surviving instance was capitalised and is now gone), closing the exact miss that caused P3-1 in the first place.
- The new SDR pin test (`findParcelGuardViewById_shouldNotBeExportedOverSpringDataRest`) closes a real coverage gap (P3-3's second half) with a cheap, correctly-scoped reflection assertion, and the commit message explicitly documents it as mutation-checked.
- The guard javadoc update (P3-4's third bullet) closes a genuine misreading risk — a reader could otherwise have concluded "the guard never manages a Unitload" covered the `assertNotParcel` callers too, when in fact their own managed entity is a pre-existing (out-of-scope) exposure.
- Full-suite spot check (74 tests across the three most relevant classes) is green with no regression.

## Recommendation

**APPROVE.** No CRITICAL or HIGH finding. The one MEDIUM finding (NeverMatcherNullBlindnessArchTest's blind spot on `.description()`-chained `never()`) is a pre-existing rule gap that this commit's new lines also sit in, not a defect introduced by this commit, and the underlying Mockito verifications still work correctly today. Safe to push.
