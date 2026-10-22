# SBDEV-3493 — re-review of review-fix commit 3be7aa6e (independent lane)

- Reviewer: code-reviewer lane (separate context from the author), 2026-09-24.
- Subject: `3be7aa6e` on `bugfix/SBDEV-3493-unset-pattern-npe`. Delta reviewed: `git diff 38ba14ac..3be7aa6e` (13 files, +175/-32). Full branch context: `origin/develop...HEAD`.
- Inputs: code-review.md, completeness-review.md, review-fixes.md, floor.md, and the rewritten ticket (ClickUp 868m9d9xn).
- Method: read-only. No Maven was run, because the shared full suite was running (surefire XMLs were being rewritten at 17:50). No DB queries were run.
- Test evidence:
  - `target/surefire-reports` currently has passing records for the three `StringConverterUnitTest$Sbdev3493UnsetPatterns` tests.
  - The other new tests (ParcelMonitor, BOL, MoveUnitload, Guard) have no report yet, because the suite had not reached them. For those tests, "576 run / 0 failed" is the author's claim and I have not verified it.

## Verdict: **APPROVE**

There are no Critical, High or Medium findings. All 9 findings below are Low, and per standing policy the Lows get fixed.

For a configured tenant, behaviour is unchanged at all three `formatConfiguredLabel` sites and at every `isConfigured` site. The refusal surfaces cleanly through all three controllers.

## (1) Prior findings vs code

| # | Claimed | Verified | Note |
|---|---|---|---|
| CR-L1 | "neither" WARN moved into `matchesConfiguredPattern` | Yes, `OutboundPalletLabelGuard.java:88-97` | The WARN is not asserted anywhere (see R3) |
| CR-L2 | tote/parcel WARN naming the key | Yes, `MobilePickingService.java:1589-1601` | Not asserted (R3) |
| CR-L3 | stale NoClear inline comment | Yes, `MobileMoveUnitloadService.java:637-638` | A sibling line at :617 is still stale (R4) |
| CR-L4 | LabelPrintingService javadoc | Yes, `:826-827` | Accurate |
| CR-L5 | NoClear uses the shared helper | Yes, `:625` and `:639` | Both purges are now token-identical |
| CR-L6 | blank = unset everywhere | Yes for the outbound sites | Not literally "one definition" (R5) |
| CR-L7 / CS-F3 | ticket text drift | Yes | scanPalletBulk is corrected, the fix shape is described, "skips" replaces "fail open" |
| CR-L8 | purge early return pinned by the WARN | Yes, `MobileMoveUnitloadServiceUnitTest` `notConfiguredRunsNoPositionQuery` | ListAppender, detached in `finally`, filters on WARN level plus the "skipping truck-off-loading purge for OUT-123" text. Attributable, since that text is unique to the purge |
| CS-F1 | `formatConfiguredLabel` at ParcelMonitor, BOL, OrderMonitor | Yes | See section 2 |
| CS-F2 | `convertFormatToRegex` null-or-blank | Yes, `StringConverter.java:33` | Test covers `" "` and `"\n"` |
| CS-F4 | exposure line | Yes | Ticket names Delete Setting, the unchecked textarea, and ShipItEZ/UAT as unmeasured |
| CS-F5 | accepted | Yes | The WARN gives the configuration signal |

## (2) `formatConfiguredLabel` and its three sites

**Configured tenant: unchanged.**
- At all three sites `n` is already a `long` (`basicService.getNextSequenceNumber`). So `String.format(pattern, n)` inside the helper boxes to the same `Long` as before, with the same default locale and the same result.
- The guard adds only a null/blank test, and neither shape can be a working pattern.

**Exception shape.**
- The helper uses the 1-arg `BusinessException(String)`: key `placeholder`, and the message renders through `placeholder=%1s` as the literal text.
- `getMessage()` therefore returns "System property <KEY> is not configured, so no label can be generated".

**Controllers.** Each catches `BusinessException` and returns 200 with `errors[{"Runtime Error", e.getMessage()}]`, the same envelope as their other business refusals:
- `BillOfLadingController.palletize:526-531` (ParcelMonitor)
- `TransfersController.runTransfer:255-260` (BOL `transferOrder`)
- `DashboardController.printToteLabels:111-117` (OrderMonitor via `orderMonitorDtoService`)

**Side effects before the throw.** No unit load is created at any site. The throw sits before the first `createUnitload`, and at OrderMonitor it fires on loop iteration 1 because the pattern is loop-invariant. There are two pre-existing side effects, neither new in kind (see R7):
- One sequence number is burned per refused call.
- OrderMonitor's `makeUserDefault` printer save runs first. It already did so for the pre-existing "No picking order found" refusal.

**OrderMonitor site is untested. Risk: LOW.**
- The change is a mechanical one-line swap with the same variable and the same `n`, and it is compile-checked. The helper's semantics are unit-tested (null, `""`, `"  "`, and the configured format).
- The untested parts:
  - Reverting this one line to `String.format` would stay green.
  - The key argument is wrong for one input shape (R6).
- Blast radius if it regressed: web tote-label printing on a tenant with the row missing. Measured exposure is 0.
- This is acceptable only because the ticket says so explicitly. Its current wording overstates the coverage, though (R5).

## (3) WARN relocation: double or lost logging

- **No double logging.** `matchesConfiguredPattern` is the only emitter on the admission paths:
  - Guard `requireOutboundPalletLabel` calls it once, and no longer logs itself.
  - Palletize :279 and :468, and ParcelMonitor :153, have no WARN of their own.
- **The purges log once.** Both purges return at their own `isConfigured` check (:553, :625) before calling the helper, so they emit only the purge WARN.
- `checkPallet` (:92) and `scanGate` (:167) each call the guard once, on separate requests.
- **Nothing lost.** The guard still logs, now via the helper, and sites 1-3 gained the WARN they lacked.
- Tote/parcel log once per call.
- Wording caveat: the helper's WARN says "so every pallet is rejected". That is true for every current caller, but it contradicts the helper's own javadoc ("what that means is the caller's call — an admission check rejects, a purge skips"). The contract only holds because the purges pre-empt the helper, so a future purge-style caller would log a false statement. Folded into R4.

## (4) `isConfigured` (blank = unset)

I found no site where a legitimately configured pattern is now treated as unset:
- A whitespace-only regex can match only a whitespace label, and no real label is whitespace.
- `convertFormatToRegex` output is `alpha + "\\d{" + n + "}"` for any non-blank input, so the converted pattern is never blank when the printing row is set.
- Leading/trailing-whitespace patterns (`" OUT-\d{6}"`) are non-blank and still count as configured. Whether they match is pre-existing behaviour, untouched.

The only behaviour deltas:
- A whitespace STRING pattern alongside a configured printing pattern is now ignored. It used to admit a label equal to that whitespace. That is an improvement, since palletize's upstream check is `isEmpty`, not `isBlank`.
- A whitespace-only pair in the purge now logs and skips. It used to skip silently. The outcome is the same.

## (5) Tests

- **ParcelMonitor `shouldRefuseSystemPallet_whenPrintingPatternIsUnset` and its `Mockito.reset` loop: sound.**
  - `setUp` stubs only `unitloadTypeRepository`, leniently, and that mock is not reset. The reset therefore removes no fixture the path needs.
  - Under MockitoExtension STRICT_STUBS, every stubbing made in iteration 1 is consumed before the reset. Stubbings removed by `reset` are no longer in `getStubbings()`, so no UnnecessaryStubbingException can arise.
  - The reset also scopes `never()` to each iteration.
  - The reset on iteration 1 is a no-op. A failure in the `null` case hides the `""` case, which a `@ParameterizedTest @NullAndEmptySource` would avoid (R8, style).
  - Non-vacuous. With a `String.format` mutant, `null` NPEs (not a BusinessException), and `""` reaches `createUnitload`. Attributable, via the key in the message plus `never()` on `createUnitload`.
- **BOL `refusesWhenPrintingPatternIsUnset`:** tests `""` only, which is the dangerous shape. A `pattern == null`-only mutant would survive here, but the helper test kills it. Sound.
- **`formatConfiguredLabel_*`, `convertFormatToRegex_shouldTreatWhitespaceAsUnset`, `matchesConfiguredPattern_neverTestsAWhitespaceOnlyPattern`:** sound. The last one is the kill for the `isBlank→isEmpty` mutant on `isConfigured`, because `" ".matches(" ")` is true.
- **`whitespacePatternsCountAsUnset` (MoveUnitload) does not pin what its name claims** (R2). It would stay green if `isConfigured` treated `"  "` as configured: the helper would then test `"OUT-123".matches("  ")`, which is false, so again no position query runs. It pins only the converter's AIOOBE (`convertFormatToRegex(" ")`).
- Hygiene: the new tests contain no `.only`, no `skip`, and no stubbed unit under test.

## (6) Comments and ticket claims

Covered by R1, R4, R5 and R6 below.

## Findings

### [LOW] R1 — `describeExpectedFormat` lost its javadoc; the new javadoc was inserted between it and its method
Confidence: HIGH. File: `src/main/java/net/aim_ai/wms/util/StringConverter.java:40-80`.
```java
	 * producing it is what fails.
	 */
	/**
	 * SBDEV-3493 — {@code String.format(pattern, n)} for a label-printing sysprop, refusing an unset one.
	...
	public static String formatConfiguredLabel(String pattern, String syskey, long n) throws BusinessException {
	...
	public static String describeExpectedFormat(String printingPattern, String... acceptPatterns) {
```
- Two consecutive `/** */` blocks sit above `formatConfiguredLabel`. Javadoc and the IDE take the last one, so `describeExpectedFormat`'s SBDEV-2962 doc is now orphaned and attached to nothing.
- That orphaned doc carries the load-bearing "MUST NOT THROW on any sysprop value" contract.
- Fix: move `formatConfiguredLabel` and its javadoc above the SBDEV-2962 block, or below `describeExpectedFormat`.

### [LOW] R2 — `whitespacePatternsCountAsUnset` cannot tell "unset" from "configured but not matching"
Confidence: HIGH. File: `MobileMoveUnitloadServiceUnitTest.java`, new test after `notConfiguredRunsNoPositionQuery`.
```java
assertThatCode(() -> mobileMoveUnitloadService.handleTruckOffLoading("OUT-123")).doesNotThrowAnyException();
verify(billofladingPositionRepository, never()).findBolIdByUnitLoadLabelId(any());
```
Fix: add the same ListAppender assertion as `notConfiguredRunsNoPositionQuery` ("skipping truck-off-loading purge for OUT-123"). Only the skip branch emits it, so the test then pins "counts as unset". Mutation-check it with `isConfigured` → `isEmpty`: the test should go red.

### [LOW] R3 — The three relocated or new WARNs are unasserted
Confidence: HIGH.
Files:
- `OutboundPalletLabelGuard.java:93` ("no label can match an outbound-pallet pattern")
- `MobilePickingService.java:1590` and `:1600`

- CR-L1 and CR-L2 were each resolved by adding a log line, but no test captures any of them. Deleting all three stays green.
- CR-L8 was judged worth pinning with a ListAppender; these are the same kind of operator signal.
- Fix:
  - One ListAppender assertion in `OutboundPalletLabelGuardUnitTest.matchesConfiguredPattern_isFalse_whenNeitherIsConfigured`, asserting the WARN names both keys.
  - One in a `MobilePickingService` test for `isToteLabel(null pattern)` asserting the tote key, and one for `isParcelLabel` asserting the parcel key.
  - Mutation-check each by deleting its line.

### [LOW] R4 — Stale "null or empty" wording after the isEmpty→isBlank change, and the helper's WARN over-claims
Confidence: HIGH.
- `OutboundPalletLabelGuard.java:65`: `// Never null: convertFormatToRegex returns "" for a null or empty input.` Should be "null or blank".
- `OutboundPalletLabelGuard.java:77`: "A null or empty pattern is never tested". Should be "null or blank (see isConfigured)".
- `MobileMoveUnitloadService.java:617`: `convertFormatToRegex returns "" (never null) for a null or empty input`. Should be "null or blank".
- `OutboundPalletLabelGuard.java:93-94`: the WARN asserts "so every pallet is rejected", while the javadoc at :79-80 says the meaning is the caller's call. Fix: either reword it to "…is configured; no label can match an outbound-pallet pattern", dropping the consequence, or state in the javadoc that purge-style callers must pre-check with `isConfigured`, as both purges do.

### [LOW] R5 — Ticket and javadoc claims that overstate
Confidence: HIGH.
- Ticket: *"'Unset' means null or blank everywhere, with a single definition: `OutboundPalletLabelGuard.isConfigured`, plus the same check in the inbound, picking and format helpers."* This contradicts itself. The predicate `== null || isBlank()` is written inline in five more places:
  - `StringConverter.convertFormatToRegex:33`
  - `StringConverter.formatConfiguredLabel:75`
  - `MobilePickingService:1589` and `:1599`
  - `MobileMoveUnitloadService` scanDestination inbound fallback
  
  Fix: say "one rule (null or blank), defined once for the outbound sites (`isConfigured`) and repeated inline at five other sites". Alternatively, move `isConfigured` to `net.aim_ai.wms.util.StringConverter` and call it everywhere, which also removes the `service` → `service.mobile` import CR-L5 noted.
- Ticket: *"Each site has a failing-first unit test … except #11: … its wiring is covered only through the helper's tests."* Two problems:
  - The helper's tests cover none of #11's wiring, so it is uncovered. Say "#11 has no test; a revert of that line would stay green".
  - Sites 8-10's tests were written in the fix commit and mutation-checked (review-fixes.md Ma-Mc), not failing-first on 45433631. Say "failing-first (1-7) or mutation-checked (8-10)".
- `isConfigured` javadoc, "One definition, used by every outbound site": accurate as scoped. No change needed.

### [LOW] R6 — OrderMonitor names the DEFAULT key when the client-specific pattern is the blank one
Confidence: HIGH. File: `OrderMonitorViewService.java:166-172`, `:185-187`.
```java
if (patternToteLabel != null && patternToteLabel.isEmpty()) { throw ... "must not be an empty string" }
...
String number = StringConverter.formatConfiguredLabel(patternToteLabel,
        WmsConstants.SYSTEM_PROPERTY_PRINTING_PATTERN_DEFAULT_TOTE_LABEL_KEY, n);
```
- A client-specific row of `"  "` passes the `isEmpty` check at :166, reaches the helper, and is refused. That refusal is correct and new: it used to mint a shared `"  "` tote.
- But the message names `PRINTING_PATTERN_DEFAULT_TOTE_LABEL`, so an admin fixes the wrong row.
- Fix: make :166 `isBlank()`, so the client-specific blank case keeps its own message, or pass the key that actually supplied the value (for example, track `String patternKey`).
- If you touch it, also note that the :166 message names `PRINTING_PATTERN_TOTE_LABEL`, which is not a real key (the real key is `PRINTING_PATTERN_CLIENT_SPECIFIC_TOTE_LABEL`). That is pre-existing.

### [LOW] R7 — The refusal burns a sequence number; it could be checked before `getNextSequenceNumber`
Confidence: MEDIUM.
Files:
- `ParcelMonitorViewService.java:127-132`
- `BillofladingService.java:853-858`
- `OrderMonitorViewService.java:180-187`

- Each site draws `n` and then refuses. It is harmless but avoidable: every refused click leaves a gap in the label sequence.
- Fix (optional): validate the pattern with a cheap pre-check (`isConfigured`) before drawing the number, and keep `formatConfiguredLabel` as the backstop. Not blocking.

### [LOW] R8 — The `reset` loop in the ParcelMonitor test should be a parameterized test
Confidence: HIGH (style). File: `ParcelMonitorViewServiceUnitTest.java:160-179`.
- The loop is correct (section 5), but the first failing iteration masks the second, and the fully-qualified `org.mockito.Mockito.reset` is noise when `Mockito.*` is already statically imported.
- The same applies to the loop in `StringConverterUnitTest.formatConfiguredLabel_shouldRefuse_whenUnset`, which also uses fully-qualified `org.assertj...` and `net.aim_ai...` names.
- Fix: `@ParameterizedTest @NullAndEmptySource` (add `@ValueSource(strings = "  ")` for the converter test), and drop the reset.

### [LOW] R9 — The OrderMonitor site has no regression test
Confidence: HIGH. File: `OrderMonitorViewService.java:185-187`.
- Risk is low for the reasons in section 2. If `printToteLabels` stays untestable at this size, a cheap alternative is an ArchUnit/grep rail: no `String.format(` whose first argument is a local read from a `PRINTING_PATTERN_*` sysprop in `src/main`.
- A rail would also catch a fourth site added later, which is the class of gap F1 found.
- Otherwise accept it as recorded on the ticket, after fixing the wording per R5.

## Open questions (not blocking)
- The per-class surefire records for the new ParcelMonitor, BOL, MoveUnitload and Guard tests were not on disk when I looked (the full suite was mid-run). Confirm from the finished run that they pass, and that the ListAppender test is green with the logback level configured under `src/test/resources`.

## Positive observations
- The two purges are now genuinely lockstep (same `isConfigured` pre-check, same helper, same WARN), and the stale "divergence" prose is gone.
- `formatConfiguredLabel` closes the silent `""` shared-unit-load mint, which is the only data-integrity shape in this ticket. The tests aim at `""` specifically rather than only at null.
- The mutation list in review-fixes.md names one killing test per new assertion.
- CR-L8 was pinned with a real log capture instead of being accepted as "not pinnable".
- The rewritten ticket is candid about unmeasured populations, and leaves the malformed-pattern case out of scope as a design question rather than half-fixing it.

## Recommendation
**APPROVE.** Fix R1-R6 in a follow-up commit on this branch. R1, R2 and R4 are minutes each. R7-R9 are optional or can be recorded.
