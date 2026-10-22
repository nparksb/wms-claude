# SBDEV-3493 — re-review of re-review-fix commit 4163b178 (independent lane, round 2)

- Reviewer: code-reviewer lane (separate context from the author), 2026-09-24.
- Subject: `4163b178` on `bugfix/SBDEV-3493-unset-pattern-npe`. Delta reviewed: `git diff 3be7aa6e..4163b178` (14 files, +202/-71).
- Inputs: `re-review.md` (the 9 Lows on `3be7aa6e`), `review-fixes.md` (correction + R1-R9 + mutant handling).
- Method: read-only, no Maven run (per instruction — a full suite runs elsewhere), no DB queries. All findings below are from reading the diff and the surrounding file context directly, not from re-running the author's claimed numbers (576/587 run, 0 failed) — those are unverified by this lane.

## Verdict: **APPROVE**

No Critical, High, or Medium findings. All R1-R9 from `re-review.md` are resolved in code exactly as `review-fixes.md` claims. One trivial optional style note (N1) that does not affect correctness.

## (1) R1-R9 vs code — each checked directly

| # | Claimed | Verified in code | Where |
|---|---|---|---|
| R1 | Helper renamed `requireConfiguredLabelPattern`, moved after `convertFormatToRegex`, so `describeExpectedFormat` keeps its own javadoc | **Yes.** New method sits at `StringConverter.java:45-58`, directly after `convertFormatToRegex` (ends :43). `describeExpectedFormat`'s SBDEV-2962 javadoc is intact and immediately precedes it again at :60-81, no longer orphaned. | `StringConverter.java:30-82` |
| R2 | `whitespacePatternsCountAsUnset` now asserts the purge's skip WARN | **Yes.** ListAppender added on `MobileMoveUnitloadService`'s logger, detached in `finally`, asserts `.contains("skipping truck-off-loading purge for OUT-123")`. This is the only assertion that distinguishes "blank counts as unset" from "blank pattern legitimately fails to match" (as `re-review.md` itself noted was missing). | `MobileMoveUnitloadServiceUnitTest.java:877-895` |
| R3 | WARN assertions added for the Guard and for `isToteLabel`/`isParcelLabel` | **Yes**, all three. Guard test wraps both `matchesConfiguredPattern` calls in one ListAppender span and asserts on `"no label can match an outbound-pallet pattern"`; detached in `finally`. `MobilePickingServiceUnitTest` adds a private `warnsDuring(Runnable)` helper (own ListAppender + try/finally) reused by both the tote and parcel null-pattern tests, each asserting the key-specific "is not configured" text. | `OutboundPalletLabelGuardUnitTest.java:221-241`, `MobilePickingServiceUnitTest.java:840-873` |
| R4 | "null or empty" → "null or blank" (guard x2 + MoveUnitloadService); helper WARN drops "so every pallet is rejected" | **Yes**, all three wording sites changed, plus the WARN text in `OutboundPalletLabelGuard.matchesConfiguredPattern` shortened to stop asserting the caller's consequence. | `OutboundPalletLabelGuard.java:65,77,93-94`, `MobileMoveUnitloadService.java:617` |
| R5 | Ticket claims corrected (single-definition wording, #11 coverage, 8-10 mutation-checked not failing-first) | **Not independently verifiable from this worktree** — it is a ClickUp comment edit, not a code change, and this lane has no ClickUp access. No code-side falsification found either. Treating as accepted on the author's word per standing practice for ticket-text-only fixes. | — |
| R6 | OrderMonitor client-specific check `isEmpty` → `isBlank`; existing message text kept | **Yes.** `patternToteLabel.isBlank()` at :166 (was `.isEmpty()`), same message text. New test `shouldRefuse_whenClientSpecificPatternIsBlank` sends `"   "` and asserts the refusal — this input previously fell through silently to the default-key lookup. | `OrderMonitorViewService.java:163-167`, `OrderMonitorViewServiceUnitTest.java:285-315` |
| R7 | Refusal moved before the sequence draw at all three format sites | **Yes, verified at all three.** `requireConfiguredLabelPattern` (or the inline `isBlank` check for the OrderMonitor client row) now runs before `basicService.getNextSequenceNumber(...)`, and every affected test asserts `verify(basicService, never()).getNextSequenceNumber(any())`. | `ParcelMonitorViewService.java:123-132`, `BillofladingService.java:849-861`, `OrderMonitorViewService.java:163-187` |
| R8 | Loop + `Mockito.reset` replaced with `@ParameterizedTest` (ParcelMonitor, StringConverter) | **Yes**, both. `ParcelMonitorViewServiceUnitTest.shouldRefuseSystemPallet_whenPrintingPatternIsUnset(String)` uses `@NullSource @ValueSource(strings={"","  "})`, no `reset` call (fresh mocks per invocation, default per-method test lifecycle). `StringConverterUnitTest.requireConfiguredLabelPattern_shouldRefuse_whenUnset(String)` likewise. | `ParcelMonitorViewServiceUnitTest.java:160-179`, `StringConverterUnitTest.java:245-259` |
| R9 | Two new OrderMonitor tests close the untested site | **Yes.** `shouldRefuse_whenClientSpecificPatternIsBlank` and `shouldRefuseBeforeDrawingASequence_whenDefaultPatternIsUnset`, the latter asserting both the message names the DEFAULT key and that no sequence number is drawn. | `OrderMonitorViewServiceUnitTest.java:285-364` |

All nine are resolved as claimed. No sibling regressions found while reading the surrounding code.

## (2) `requireConfiguredLabelPattern` placement and OrderMonitor side-effect ordering

**Placement, all three sites: correct, before the sequence draw.**
- `ParcelMonitorViewService.palletise` — helper call (:125-127) precedes `basicService.getNextSequenceNumber(...)` (:129).
- `BillofladingService.transferOrder` — same shape (:851-855 before :857).
- `OrderMonitorViewService.printToteLabels` — the default-pattern refusal (:174-176) sits before the per-order loop that draws sequence numbers (starts ~:178); the client-specific blank check (:166-168) is even earlier.

**Behavior for a CONFIGURED tenant: unchanged.** In every site `n` is drawn as a `long` exactly as before; the helper no longer formats (it now just validates and returns the pattern), and callers do `String.format(pattern, n)` themselves immediately after — same format call, same arguments, same result as the old inlined `formatConfiguredLabel`. This is a real API-shape change from round 1 (the method used to format; now it only validates), but it is fully internal to this class/its three callers, and all three callers were updated consistently. Confirmed by grep: no remaining reference to the old `formatConfiguredLabel` name anywhere in `src/main` or `src/test`.

**OrderMonitor early refusal happens before every other side effect in the loop** (no `createUnitload`, no `PickingorderUnitload` write, no `getNextSequenceNumber` call for the affected order). One earlier, **pre-existing and unrelated** side effect still runs first regardless: `printToteLabels`'s `makeUserDefault` printer-save block executes at `OrderMonitorViewService.java:130`, well before the pattern checks at :166/:174. This is not new — the same ordering already applied to the pre-existing "No picking order found to print" refusal at :143 — and is out of scope for this ticket; not a new finding.

## (3) Tests: soundness, non-vacuity, attribution

- **ParcelMonitor parameterized test**: sound. Removing `Mockito.reset` is actually cleaner than the round-1 loop — JUnit 5's default per-method test-instance lifecycle gives each parameterized invocation fresh `@Mock` fields via the Mockito extension, so there is no cross-iteration stubbing leakage to guard against. `""` and `"  "` both hit `isBlank()`; `null` is covered by `@NullSource`. Assertions on `never().getNextSequenceNumber(any())` plus the message content are attributable and non-vacuous (a revert to eager sequence-draw, or to the old `isEmpty` check on the underlying `isBlank`, would flip these).
- **BOL test**: same shape, `""` only plus the new `never(getNextSequenceNumber)` assertion — consistent with `re-review.md`'s original verdict that `""` alone is the dangerous shape and null is covered by the helper's own unit test.
- **Two new `OrderMonitorViewServiceUnitTest` tests**: sound, non-vacuous. `shouldRefuse_whenClientSpecificPatternIsBlank` pins the `isBlank` change with `"   "`, which `isEmpty()` would not catch — a real mutation kill. `shouldRefuseBeforeDrawingASequence_whenDefaultPatternIsUnset` pins both the refusal message (names the DEFAULT key, confirming R6's fix didn't regress key attribution) and the "no sequence drawn" guarantee.
- **WARN assertions (guard, tote, parcel, purge)**: all follow the same pattern — `ListAppender` added, action run, `detachAppender` in `finally`, filtered on `Level.WARN`, message-content assertion. All four ListAppender-based tests detach unconditionally regardless of assertion outcome inside the try block; no leaked appenders even on failure.
- **Hygiene**: no `.only`, no `@Disabled`, no `TODO`/`FIXME`, no `System.out.println`, no stubbed unit under test anywhere in the diff (grepped the full diff).

## (4) `never()`/`any()` — NeverMatcherNullBlindnessArchTest caveats

Every site changed from `anyString()` to a bare `any()` targets `UnitloadService.createUnitload`'s **5-arg, all-reference-typed** overload (`String, Location, Long, Long, String`) — confirmed by reading its declared overloads (`UnitloadService.java:186-231`; six overloads total, none of which has a primitive parameter). The `(String) any()` cast on the first argument only picks the correct overload at compile time (Mockito's `any()` alone is ambiguous between the `(Location,...)` and `(String,...)` 5-arg overloads); it is not narrowing the matcher itself, and none of the five parameters in that overload is a primitive or a varargs slot, so none of `NeverMatcherNullBlindnessArchTest`'s two carve-outs (primitive-capable matchers, varargs `any(X[].class)`) apply here. This is exactly the same pattern the arch test's own javadoc cites for `StockunitServiceToteContainerRelocationUnitTest`. Confirmed sites: `ParcelMonitorViewServiceUnitTest.java` (x2), `BillofladingServiceUnitTest.java`, `MobilePalletizingScanPalletFormatTest.java` (x2).

## (5) Comment/javadoc accuracy

- `requireConfiguredLabelPattern`'s new javadoc (`StringConverter.java:46-49`) accurately describes the new behavior (validates and returns the pattern; caller does the `String.format`) and correctly states "Callers check BEFORE drawing the sequence number, so a refusal burns no number" — true at all three call sites per section (2).
- The three "null or empty" → "null or blank" wording fixes (`OutboundPalletLabelGuard.java:65,77`, `MobileMoveUnitloadService.java:617`) are accurate; `convertFormatToRegex` does treat blank as unset per `isBlank()` at `StringConverter.java:33`.
- The guard's WARN text change (dropping "so every pallet is rejected") resolves the contradiction `re-review.md` flagged against the javadoc's "what that means is the caller's call" — now consistent.
- New inline comments in `ParcelMonitorViewService.java`, `BillofladingService.java`, `OrderMonitorViewService.java` ("refuse an unset pattern/default before a sequence number is drawn") accurately describe the code directly below them.

## Findings

### [LOW] N1 — Fully-qualified names in new test code where the class already has (or could add) an import
Confidence: LOW (style only, not correctness).
Files: `OutboundPalletLabelGuardUnitTest.java:224-238` (`ch.qos.logback.classic.Logger`, `ch.qos.logback.core.read.ListAppender`, `ch.qos.logback.classic.spi.ILoggingEvent`, `ch.qos.logback.classic.Level`, `org.slf4j.LoggerFactory` all fully qualified inline); `MobilePickingServiceUnitTest.java`'s new `warnsDuring` helper same pattern; `OrderMonitorViewServiceUnitTest.java`'s two new tests fully-qualify `net.aim_ai.wms.exceptions.BusinessException`.
- This is a deliberate minimal-diff choice (avoids touching the import block) and the same style is already used and accepted elsewhere in this same fix (`MobileMoveUnitloadServiceUnitTest.java` uses plain imports for the same Logback classes, so the codebase is inconsistent either way). Not blocking, not worth a follow-up commit on its own — only worth doing if these files are touched again.
- Fix (optional, next time these files are edited): add the Logback/BusinessException imports and drop the FQNs.

## Open questions (not blocking)
- R5's ticket-text correction is not verifiable from this worktree (no ClickUp access in this lane); accepted on the author's word, consistent with how `re-review.md` treated the equivalent round-1 ticket-text items (CS-F3/CS-F4).
- The author's claimed "587 run / 0 failed" and PIT "all KILLED" for this round were not independently re-run here, per the no-Maven instruction for this lane. Nothing in the code read contradicts them, and every mutant described (Mf-Mk) has a corresponding, correctly-targeted assertion in the diff (see sections 1 and 3).

## Positive observations
- The R7 fix (refuse before drawing the sequence number) is a genuine improvement over accepting the burned-sequence-number tradeoff from round 1 — it removes an entire class of "harmless but avoidable" side effect at all three sites, not just patches around it.
- Removing the `Mockito.reset` loop in favor of `@ParameterizedTest` is a real simplification, not just a cosmetic change — it removes the exact "first failure masks the second" risk `re-review.md` flagged, for free.
- All four new WARN-capturing tests follow one consistent, correct ListAppender-with-try/finally pattern — no copy-paste drift between them despite being added across three different test files.
- The rename to `requireConfiguredLabelPattern` plus returning the raw pattern (rather than the formatted label) is a cleaner separation of "validate configuration" from "format a label," and every caller was updated in lockstep — grep confirms zero dangling references to the old name/signature.

## Recommendation
**APPROVE.** N1 is optional and cosmetic; nothing here blocks merge.
