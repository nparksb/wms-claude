# SBDEV-3474: re-review of fix round `d9a708b9` (and the reworded parent `d62a663d`)

- **Worktree:** `.claude/worktrees/wms2-api/SBDEV-3474`, HEAD `d9a708b9`, parent `d62a663d`, base `origin/develop` `67acb39d` (fetched during this review, unchanged).
- **Lane:** code-reviewer, read-only. No edits, stash, checkout or reset. No `mvn verify`, no IT.
- **Executed:** `mvn -o -q test -Dtest='OutboundPalletLabelGuardUnitTest,MobileTruckLoadingServiceTest,TruckLoadingWriteEntryPointArchTest'`, with no other Maven process running (`pgrep` was empty first). Result: 12/0/0, 22/0/0, 2/0/0. The surefire report timestamps match this run.
- **Read:** `git show d9a708b9`, `git log -1 --format=%B d62a663d`, the full guard, the fixture javadoc, `MobileMoveUnitloadService.handleTruckOffLoadingNoClear`, `SyspropService.getSysvalue` + `CacheConfig`, `StringConverter.convertFormatToRegex/describeExpectedFormat`, and `origin/develop`'s `MobileTruckLoadingWriteService.scanGate` PHASE A–D plus the facade's `scanGate`.

## 1. Resolution check

| Item | Status | Note |
|---|---|---|
| M1 (doc half) | Resolved, but overstated | The comments now say the lane covers only the no-match exit. The new wording turns the prior review's "except for a sysprop edit between the two reads" into an absolute. See **F1**. Follow-up IT correctly deferred. |
| L1 | Resolved | "No entity access … reads only the two sysprops, through SyspropService (a cached los_sysprop lookup)". Accurate. |
| L2 (parent msg) | Resolved for "success" | The success case is now named, and it holds on `origin/develop` (see §2). The same sentence adds a new inaccuracy. See **F2**. |
| L3 | Resolved, slightly narrower than the rail's own list | See **F3**. |
| L4 | Resolved | The class-granularity paragraph is accurate on both effects. |
| L5 | Resolved | `verifyNoInteractions(syspropService)` added. Holds, because the null/empty branch returns before either `getSysvalue`. |
| L6 | Tests added and green; one display name over-claims | See **F4**. |
| L7 | Resolved | Label dropped from the WARN. See §3. |
| L8 | Resolved; its comment says slightly too much | See **F5**. |

## 2. Closed-set claims checked against code

- **Fixture/commit: "in production every scan that reaches D0 MATCHES a pattern and D0 always runs its purge"**: not exact. See F1.
- **Parent msg: "if every child carried an order, the scan SUCCEEDED and loaded a non-outbound pallet"**: TRUE on `origin/develop`. The facade `scanGate` (`MobileTruckLoadingService:166-193`) did no label check. PHASE A checks only that the label exists (`existsByLabelid`). PHASE C checks the gate match, the BOL state, and duplicate or orphan parcels (`throw new BusinessException("unexpectedUnitLoadDoesNotHaveOrder", …)`). It never checks the label. D0 purges nothing for a non-matching label. PHASE D's `transferUnitLoadToLocation` checks only gate lock state, fix-assignment and unit-load-type constraints, all independent of the label. So a non-outbound pallet whose children all have orders, or which has **no** children (the orphan loop passes trivially), was loaded when the gate and BOL checks passed.
- **Parent msg: "before, it got unexpectedUnitLoadDoesNotHaveOrder or entityNotFoundForName after the locks"**: partly false. See F2.
- **Guard comment "Logged on every rejected scan"**: accurate in context. It sits inside the neither-configured branch, and in that state every scan with a non-empty label is rejected and logs. A null or empty label returns before the WARN, but that case is rejected for a different reason. Not a finding.
- **Guard javadoc "touches no unitload, billoflading or customerorder row"**: true. `findSysvalueBySyskey` is a native scalar on `los_sysprop`.
- **Arch-test "would be flagged … MobileTruckLoadingService$Inner"**: true for `doNotHaveFullyQualifiedName`.
- **L6 javadoc "treating "" … for the printing pattern, convert to "" and match nothing"**: true. `convertFormatToRegex("")` returns `""`, `"".matches` only the empty label, and the guard rejects the empty label earlier.

## 3. L7

Dropping the label is right. The label is raw request input, SLF4J does not neutralise CR/LF, and the operator-facing `noValidString` exception already carries it (`new BusinessException("noValidString", palletLabel, …)`). Observed in the test log: the WARN now prints only the two keys. "Fires on every rejected scan" is accurate in context (§2). "Blocks all truck loading for the warehouse" is also accurate: both `/scanPallet` (`checkPallet:87`) and `/scanGate` (`:162`) go through the guard.

## 4. L6

The tests pin what the guard does. For `("", "")`, `patternConfigured` and `printingPatternConfigured` are both false, the WARN fires (seen in the run log), and `describeExpectedFormat` receives no non-blank accept pattern, so it returns `(no label format configured)`. For `("", "AOUT-%1$06d")`, `AOUT-000123` matches `AOUT-\d{6}` and `IN-000002` does not. Both are green. The one gap is F4.

---

## Findings

### [LOW] F1: "every scan that reaches D0 MATCHES" / "D0 always runs its purge" / "production cannot reach" are absolutes the code does not guarantee
**Files:** `src/test/java/net/aim_ai/wms/integration/service/mobile/AbstractTruckLoadingPgFixture.java` (class javadoc, new ⚠ paragraph, and the `@MockitoBean` javadoc); commit message of `d9a708b9` (M1 bullet)
**Confidence:** HIGH

> `so in production every scan that reaches D0 MATCHES a pattern and D0 always runs its purge.`
> `Since SBDEV-3474 this lane tests a D0 branch production cannot reach.`
> `this lane exercises only PHASE D0's no-match exit, which production can no longer reach`

The guard (`OutboundPalletLabelGuard:63-64`, in the non-transactional facade) and D0 (`MobileMoveUnitloadService.handleTruckOffLoadingNoClear`, inside the write transaction after B1–B6) each call `syspropService.getSysvalue` for both keys **separately**. The two reads are not atomic, and several things make them diverge:
- `getSysvalue` is `@Cacheable(value = "sysprops", unless = "#result == null", …)`. A **null result is never cached**, so an unset key is re-read from the DB on every call. An admin who inserts the row between the two reads is seen by D0 immediately.
- `setSysvalue`/`createSystemProperty` carry `@CacheEvict`, and `SdrCacheEvictionEventHandler` evicts on SDR PATCH. An edit through the app or SDR between the reads reaches D0 at once, with no TTL wait.
- A direct-SQL edit becomes visible when the 2-minute `expireAfterWrite` entry expires (`CacheConfig:36/90`), and each key expires on its own schedule.
- The gap between the reads is not tiny. It spans BOL, pallet, per-child and per-order lock acquisitions, and under contention that can take seconds.

If the pattern is narrowed or cleared in that window, D0 takes the no-match exit or the "neither configured → skip" return that the fixture says production "cannot reach". So production reaches them rarely, not never. The prior review stated this exception explicitly ("The only exception is a sysprop edit landing between the two reads"). The fix dropped it and made the claim absolute. The practical conclusion is unchanged: this lane does not cover the purge, and the purge is the branch that matters.
**Fix:** "…so in production a scan reaches D0 with a label that matched the guard's read of the patterns. D0 re-reads them, and barring a sysprop change between the two reads (edits evict the cache, and an unset key is never cached) it takes the purge branch. The no-match exit this lane exercises is reachable only in that window." Make the same change in the `@MockitoBean` javadoc ("which production reaches only if a sysprop changes mid-scan") and, if convenient, in the commit message's M1 bullet.

### [LOW] F2: Reworded parent message puts `entityNotFoundForName` "after the locks"; for a non-existent label it was raised before any lock
**Commit:** `d62a663d` message, "Behaviour change" paragraph
**Confidence:** HIGH

> `Before, it got unexpectedUnitLoadDoesNotHaveOrder or entityNotFoundForName after the locks, or, if every child carried an order, the scan SUCCEEDED`

On `origin/develop` `67acb39d`, PHASE A of `MobileTruckLoadingWriteService.scanGate` throws `entityNotFoundForName` for a missing label through the scalar probe `if (!unitloadRepository.existsByLabelid(dto.getPalletName()))`. That runs **before** B1 takes any lock. The only post-lock `entityNotFoundForName` is B2's `findByLabelidForUpdate(...).orElseThrow(...)`, which fires only if the row vanishes between PHASE A and B2. Only `unexpectedUnitLoadDoesNotHaveOrder` was reliably "after the locks". The list of old outcomes is also still partial. A non-outbound label combined with a bad BOL name, a gate mismatch or a closed BOL used to get that error (`EntityNotFoundException "BillOfLading not found by name"`, `scannedAndRequiredGateDiffer`, `billOfLadingUnxepectedStateFound`), and now gets `noValidString` first, because the guard runs before PHASE A. That is a message-precedence change for direct API callers, the same class of change as the Cypress `9.V4/9.V5` note in the original L2.
**Fix:** "Before, it got entityNotFoundForName (a missing label, before any lock) or unexpectedUnitLoadDoesNotHaveOrder (after the locks), or whatever BOL/gate error applied, or, if every child carried an order, the scan SUCCEEDED…". This message is already on the branch, so fix it on the next reword or in the PR body.

### [LOW] F3: The write-service javadoc's "enforced for direct calls only" leaves out two direct-call escapes the rail's own javadoc lists
**File:** `src/main/java/net/aim_ai/wms/service/mobile/MobileTruckLoadingWriteService.java:148-154`
**Confidence:** HIGH

> `it cannot see a call made by reflection or through a method reference, so this is enforced for direct calls only, not absolutely.`

"Direct calls only" implies every direct call is caught. Two direct calls are not: a call through a receiver typed as a subtype or proxy of `MobileTruckLoadingWriteService` (listed in `TruckLoadingWriteEntryPointArchTest`'s blind spots, and the call target owner differs), and a direct call from **another method of the facade** that skips the guard (class granularity, the L4 paragraph just added to the arch test). The second one also narrows "through that facade a label that matches neither outbound pattern … does not reach B1": that holds for `MobileTruckLoadingService.scanGate` (today the facade's only caller, `:166`), not for the facade class as a whole. Neither escape exists in `src/main` today (grep), so this is precision, not a live hole.
**Fix:** "…through `MobileTruckLoadingService.scanGate` a label that matches neither outbound pattern does not reach B1. `TruckLoadingWriteEntryPointArchTest` pins the facade class as the only production caller; see its javadoc for what it cannot see (reflection, method references, differently-typed receivers, and other methods of the facade)."

### [LOW] F4: L6 display name asserts "treated as unconfigured", which the test cannot tell apart from "treated as configured"
**File:** `src/test/java/net/aim_ai/wms/unit/service/mobile/OutboundPalletLabelGuardUnitTest.java` (new `rejectsWhenBothPatternsAreEmptyStrings`, and `usesThePrintingPatternWhenTheRegexPatternIsAnEmptyString`)
**Confidence:** HIGH

> `@DisplayName("both patterns set to empty strings: treated as unconfigured, rejected (fail closed)")`

The mutant that drops `&& !pattern.isEmpty()` from `boolean patternConfigured = pattern != null && !pattern.isEmpty();` survives both new tests. `"OUT-100059".matches("")` and `"AOUT-000123".matches("")` are false, so the outcome is the same. `(no label format configured)` comes from `describeExpectedFormat`, which skips blank accept patterns whatever `patternConfigured` is. The only observable difference is the neither-configured WARN, and nothing asserts it. The outcome assertions are correct and worth keeping. The name just claims an internal classification that is not pinned. This is the same pattern as the original L5, where the name claimed an unasserted property. The original L6 fix text also asked the `("", "")` case "to pin the fail-closed `LOG.warn` branch", and that did not happen.
**Fix:** either rename to "both patterns empty strings: rejected, no format configured (fail closed)", or pin the WARN (for example a Logback `ListAppender` on `OutboundPalletLabelGuard`, asserting one WARN for `("", "")` and none for `("", HYDRA_PRINTING_PATTERN)`). The second option kills the mutant.

### [LOW] F5: L8 comment says a bad label "costs no query"; the guard's sysprop reads are queries on a cache miss
**File:** `src/test/java/net/aim_ai/wms/unit/service/mobile/MobileTruckLoadingServiceTest.java:350`
**Confidence:** HIGH

> `// SBDEV-3474: the label check runs BEFORE the pallet lookup, so a bad label costs no query.`

`getSysvalue` hits `los_sysprop` on a cache miss, and every time for an unset key (`unless = "#result == null"`). The assertion (`verifyNoInteractions(unitloadRepository)`) proves "no pallet lookup", not "no query".
**Fix:** `// …so a bad label never reaches the pallet lookup.`

## Open questions (low confidence, not blocking)

None.

## Positive observations

- L1's rewrite names exactly what is and is not touched, and keeps the load-bearing SBDEV-3244 rationale.
- L5 and L8 now each pin an ordering with a real assertion, and both are green.
- L7 is the right call. The comment explains why the WARN fires every time and why the label is left out, so nobody "fixes" it back.
- The L4 paragraph correctly notes that the nested-class failure is a false positive to widen the rule for, not a reason to delete it. That heads off a predictable wrong reaction.
- The parent message's new success-case claim is correct against `origin/develop`, down to the UI-reachability caveat.
- The M1 note tells the reader directly not to treat a green run of the lane as coverage of D0's purge.

## Verdict

All requested items were addressed. No Critical, High or Medium findings. F1–F5 are wording-precision Lows: F1 makes absolute a claim the prior review qualified, F2 is a new inaccuracy in the reworded parent message, and F3–F5 are slight over-statements. None changes behaviour or hides a defect. Per "address Lows too", fix them in a small follow-up commit (F2 on the next reword or in the PR body).

APPROVE
