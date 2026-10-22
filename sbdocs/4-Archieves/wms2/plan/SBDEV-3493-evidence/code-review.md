# SBDEV-3493 — independent code review, lane 1 of 2 (correctness + ticket conformance)

- Reviewer: code-reviewer lane (separate context from the author pass), 2026-09-24
- Subject: `bugfix/SBDEV-3493-unset-pattern-npe` @ `38ba14ac`, base `origin/develop` `45433631`
- Worktree: `/Users/np1076/dev/spk/owl/.claude/worktrees/wms2-api/SBDEV-3493`; diff = `git diff origin/develop...HEAD` (10 files, +271/-20)
- Read-only. No Maven run (the shared full suite was running). LSP diagnostics unavailable (the jdtls server exited with code 1). Test evidence comes from the
  existing `target/surefire-reports` (17:22) plus the author's floor.md. **Caveat:** those XMLs list every new test except
  `stringPatternAloneStillPurges` (`HandleTruckOffLoading` shows 8 tests), so that one test has PIT evidence but no surefire record yet. The running full suite should add one.

## Verdict: **APPROVE** (no Critical/High/Medium. 8 Lows below. Per standing policy the Lows get fixed.)

## Stage 1 — ticket conformance (7 sites)

| # | Site | Ticket shape | Implemented | Conforms |
|---|---|---|---|---|
| 1 | `MobilePalletizeWriteService.scanPallet` (:279) | "use `requireOutboundPalletLabel`" | `OutboundPalletLabelGuard.matchesConfiguredPattern(...)` + the existing `noValidString` throw with the same `describeExpectedFormat(printingPattern, pattern, convertedPrintingPattern)` args | Yes in effect. The literal shape differs (L1) |
| 2 | `scanPalletBulk` (:468). The ticket calls it "scanParcelBulk" (L7) | same | same as #1 | Yes, same caveat |
| 3 | `ParcelMonitorViewService.palletise` (:152) | configured-only rule inline, keep message | helper + `"Not valid format: " + palletName` unchanged | Yes |
| 4 | `MobileMoveUnitloadService.handleTruckOffLoading` (:553) | configured-only, fail OPEN, like NoClear | early `return` + the same WARN text when neither is configured (the condition matches NoClear's `!patternConfigured && !printingPatternConfigured`), then helper | Yes |
| 5 | `scanDestination` inbound create (:466) | fall back to the shipped default like `ReceivingService.verifyPalletOrCartLabel` | `null \|\| isBlank()` → `SYSTEM_PROPERTY_STRING_PATTERN_INBOUND_PALLET_DEFAULT_VALUE` | Yes. Same predicate and constant as `ReceivingService:645-647` |
| 6 | `MobilePickingService.isToteLabel` | unconfigured → false | `pattern != null && !pattern.isBlank() && label.matches(pattern)` | Yes |
| 7 | `isParcelLabel` | same | same | Yes |

Admission sites keep their exact key/message: sites 1 and 2 still throw `new BusinessException("noValidString", palletLabel, describeExpectedFormat(...))`, and site 3 still throws `"Not valid format: " + palletName`.
With neither pattern set, `describeExpectedFormat(null, null, "")` is null-safe (null/blank accept patterns are skipped, and it returns `"(no label format configured)"`), so the rejection path cannot NPE either.

Independent re-sweep: `git grep "\.matches(" HEAD -- src/main/java` returns only the 7 fixed sites plus the two already-guarded ones (`LabelPrintingService:836`, `ReceivingService:648`) and the helper itself.
`Pattern.compile(<variable>)` and `Pattern.matches(` return no sysprop-driven sites. The sweep is complete.

## Stage 2 — correctness

### (2) `matchesConfiguredPattern` and the `requireOutboundPalletLabel` refactor
- The helper is correct. `(patternConfigured && label.matches(pattern)) || (printingPatternConfigured && label.matches(converted))`. The one addition over the old inline guard expression is `convertedPrintingPattern != null`, which is unreachable from `convertFormatToRegex` (it returns `""`, never null) but harmless for direct callers.
- `requireOutboundPalletLabel` behaves exactly as before. The removed expression is token-for-token the helper's body. The label null/empty check and the WARN still run first, and the throw is unchanged.

### (3) No behaviour change with both patterns configured (Hydra prd and dev, the only real population)
Walked every input class:
- **Both non-empty:** the admission sites were `!m(p) && !m(c)` and are now `!(m(p) || m(c))`. That is the same boolean with the same evaluation order, so the same `PatternSyntaxException` (if any) comes from the same call first. The purge's early return needs both unconfigured, so it cannot fire. Tote/parcel: a non-blank pattern goes through the same `matches`. Inbound: a non-blank pattern is used as-is.
- **Empty-string row (`""`) with the other pattern configured:** before, `label.matches("")` was true only for `label == ""`. Now `""` is never tested. An empty label is already rejected upstream at sites 1–3 (C1/C3 guards and the `palletName.isEmpty()` guard), so the only reachable difference is the purge with a `""` source label. That is not a Hydra shape.
- **Whitespace-only pattern:** outbound still tests it (`isEmpty`), so it behaves as before. Tote/parcel/inbound treat it as unset (`isBlank`), which changes only for a label consisting of exactly that whitespace. See L6 for the inconsistency.
- **Malformed printing pattern** (`convertFormatToRegex` AIOOBE/NFE): unchanged and pre-existing. It fires before the helper.
- **Null label:** unchanged. It NPEs when a pattern is configured, as before, and every admission site guards it upstream.
No label that matched before now fails to match for a both-configured tenant, and no label that failed now matches.

### (4) "unset → false" for isToteLabel / isParcelLabel: callers
| Caller | Before (unset) | Now (unset) | Is false dangerous? |
|---|---|---|---|
| `PickingController:353` (`/processPick`) | NPE outside the try → 500 | `"<tote> is not a tote. Please scan a tote."` in the `errors` payload, and `processPick` is not called | No. It fails closed and nothing is written |
| `MobilePickingService.rapidPickingScanPackage:1139` | NPE → 500 | `BusinessException("<pkg> is not a parcel ID!")`, thrown before any read | No. It fails closed |
| `rapidPickingConnectPackageAndType:1244` | NPE → 500 | same message | No. It fails closed |
Every caller uses false to mean "reject", so no caller treats false as permission. The operator message blames the scan rather than the configuration (L2).

### (5) Inbound fallback vs `ReceivingService.verifyPalletOrCartLabel`
Identical predicate (`pattern == null || pattern.isBlank()`) and constant (`"CART-\\d{4}|IN-\\d{6}"`). The consequence differs by design: Receiving rejects, while scanDestination falls through to `"No destination found for X"`, or creates an inbound pallet in Putaway Lane when the label matches.
Note: a blanked row (`""`) used to fall through to "No destination found" for every label. It now admits `IN-\d{6}` and `CART-\d{4}` creates. That is the behaviour the ticket asked for, and it matches the SBDEV-3004 precedent. Recorded here as information, not as a finding.

### (6) Comments and javadoc
- The NoClear javadoc's "divergence is gone" is accurate: the two overloads now resolve identically (same emptiness predicates, same WARN text, same configured-only match).
- The old-claim sweep (`git grep` for "deliberate divergence", "REFUSES to run", "this.pattern\" is null", "original's behaviour", plus sbdocs `3-Resources`) found one stale present-tense copy (L3) and one stale neighbouring javadoc (L4). No sbdocs copy of the old claim exists. `wms2-bol-truck-loading-workflow.md:213-216` describes the guard's fail-closed behaviour, which is unchanged.

### (7) Test quality
- `catchThrowable(...)` + `verify(unitloadService).createUnitload(eq(label), ...)` (palletize ×2, parcel monitor ×1) is **not vacuous**. `createUnitload` sits only after the pattern check on those paths. `findByLabelid*` returns empty. Parcel monitor passes `newPallet=false`, so the generated-label mint branch is not the one reached. On the base, the NPE fires before the mint, so the test goes red for the right reason.
- `scanDestination_shouldUseTheDefaultInboundPattern_whenItIsUnset` checks `verify(locationRepository).findByName(STORAGE_LOCATION_PUTAWAY_LANE)`. That lookup appears exactly once in the class (`:487`), inside the inbound-create branch, so the test is attributable. Its partner (`XYZ-1` → `"No destination found for XYZ-1"`) together with it pins "fall back" as distinct from both "unset → false" and "unset → match everything".
- `notConfiguredRunsNoPositionQuery` cannot tell the early return from the helper returning false. The floor acknowledges this: only the WARN distinguishes them, and it is not captured (L8).
- `printingPatternAloneStillPurges` is red on the base (NPE). `stringPatternAloneStillPurges` is green on the base: it is a mutation-closer, not a failing-first test, and it is labelled correctly in the floor.
- The palletize "neither" tests assert `getKey()` = `noValidString` (per the BusinessException key-vs-message memory) plus `never()` on `createUnitload`. Good.
- No mocked no-op stands in for the unit under test. The guard tests call the real static method.

### Package import `service` → `service.mobile` (ParcelMonitorViewService)
Acceptable. `PickingorderBusinessService` already imports from `service.mobile`, and no ArchUnit rule forbids the direction (checked `src/test`). The call is to a pure static method, so no bean-wiring edge is added. Optional tidy-up in L5.

## Findings

### [LOW] L1 — Sites 1/2 do not use the fix shape the ticket names; record the deviation on the ticket
File: `MobilePalletizeWriteService.java:279`, `:468`
```java
if (!OutboundPalletLabelGuard.matchesConfiguredPattern(palletLabel, pattern, convertedPrintingPattern)) {
    throw new BusinessException("noValidString", palletLabel, StringConverter.describeExpectedFormat(printingPattern, pattern, convertedPrintingPattern));
```
The ticket says "Use `OutboundPalletLabelGuard.requireOutboundPalletLabel`". The inline form is defensible, and arguably better: it avoids a second sysprop read, and the guard's `entityNotFoundForName` label branch is already handled upstream by C1/C3. The operator-visible result is identical. What is lost is the guard's WARN for the neither-configured case, so a warehouse with both rows missing now has every new pallet rejected and **nothing in the log** points at configuration (see L2).
Scenario: support gets "String is not valid: 'AOUT-000123' (no label format configured)" at palletizing, and the server log shows nothing.
Fix: either (a) add the same one-line WARN when `!patternConfigured && !printingPatternConfigured` at both sites, or move a `warnIfNeitherConfigured()` into the guard and call it; or (b) keep the code and add a line to the ticket and the PR body saying why the literal shape was not used. Do (b) in any case.

### [LOW] L2 — Tote/parcel "unset → false" shows a configuration fault as an operator error, with no log line
File: `MobilePickingService.java:1586-1596`
```java
return pattern != null && !pattern.isBlank() && label.matches(pattern);
```
With `STRING_PATTERN_PICKING_TOTE` missing, every pick on `/processPick` returns "X is not a tote. Please scan a tote." Operators rescan valid totes indefinitely, and nothing in the log names the missing sysprop. That is better than a 500 and conforms to the ticket, but the ticket's goal was "a clear message".
Fix: when the pattern is null or blank, `LOG.warn("{} is not configured; no label is recognised as a tote", KEY)`, and likewise for the parcel key. Keep the return value `false`.

### [LOW] L3 — Stale present-tense claim in NoClear's inline comment
File: `MobileMoveUnitloadService.java:639-640`
```java
// Only a CONFIGURED pattern may match. Testing an unconfigured one would either NPE (the
// original's behaviour) or, worse, let "" match and purge indiscriminately.
```
After this commit the original no longer NPEs. This is the sibling copy of the claim the javadoc fix rewrote.
Fix: "…would either NPE (`String.matches(null)`) or, worse, let `\"\"` match…". Drop "the original's behaviour".

### [LOW] L4 — `LabelPrintingService.requireScannableToteId` javadoc now describes the old isToteLabel behaviour
File: `LabelPrintingService.java:826-827`
```
 * configured means nothing to validate against (such a tenant's mobile flow is already
 * broken in isToteLabel, and this tab should not invent a stricter rule than the floor has).
```
"Broken" referred to the NPE. isToteLabel now deliberately rejects every tote.
Fix: "…(isToteLabel then rejects every tote — SBDEV-3493 — so the mobile flow cannot pick either; this tab should not invent a stricter rule than the floor has)."

### [LOW] L5 — The "lockstep" overloads now use two implementations of the same rule
File: `MobileMoveUnitloadService.java:561` (helper) vs `:641-642` (inline in NoClear)
The javadoc says "keep the two in lockstep", but `handleTruckOffLoading` calls `matchesConfiguredPattern` while `handleTruckOffLoadingNoClear` keeps its own inline expression. A later change to the helper (say, `isBlank`) would silently split them again.
Fix: make NoClear call `OutboundPalletLabelGuard.matchesConfiguredPattern(unitLoadLabel, pattern, convertedPrintingPattern)` too. This does not conflict with the "no shared helper with a flag" rule, which is about the delete calls. Optionally, host the static helper somewhere neutral (`StringConverter`, or a small `LabelPatterns` util in `net.aim_ai.wms.util`) instead of on a mobile `@Component`, which would also remove the `service` → `service.mobile` import. This is optional: the precedent exists.

### [LOW] L6 — Inconsistent "unset" predicate across the fix: `isEmpty` (outbound) vs `isBlank` (inbound, tote, parcel)
Files: `OutboundPalletLabelGuard.java:98-99`, `MobileMoveUnitloadService.java:553` vs `:467`, `MobilePickingService.java:1589/1595`
A whitespace-only outbound row is treated as configured: the purge then skips **without** the WARN, and admission rejects. The other three treat whitespace as unset. The outbound `isEmpty` follows SBDEV-3474's guard and the NoClear precedent, so changing it touches existing behaviour.
Fix: either state the difference in the helper javadoc, or switch the outbound predicates (guard, helper, both purges) to `isBlank` together. Not for a both-configured tenant, so it is not urgent.

### [LOW] L7 — The ticket's site table names a method that does not exist
Ticket row 2 says `MobilePalletizeWriteService.scanParcelBulk`. The site is `scanPalletBulk` (`:468`), and `scanParcelBulk` has no pattern `.matches(`. Fix: correct the ticket row so the next reader's grep lands on the right method.

### [LOW] L8 — The purge's fail-open early return is unpinned; the WARN is the only thing that distinguishes it
File: `MobileMoveUnitloadService.java:553-560`; test `notConfiguredRunsNoPositionQuery`
Deleting the whole `if (...) { LOG.warn(...); return; }` block leaves every test green, because the helper also returns false. The floor calls this "not pinnable", but it is pinnable with a log capture (for example a logback `ListAppender` on `MobileMoveUnitloadService`, or whatever pattern the NoClear WARN test uses, if one exists). The WARN is the operator-facing half of "fail open", and its only guard today is the review.
Fix: assert that one WARN containing `SYSTEM_PROPERTY_STRING_PATTERN_OUTBOUND_PALLET_KEY` and the label is emitted. Mutation-check it by deleting the block and confirming the test goes red.

## Open questions (not blocking)
- UAT tenants were not measured (MCP down, and still down during this review). If any UAT tenant is partially configured, sites 1–4 change behaviour there as intended (printing-only admission now works instead of 500ing). That needs no action, but it should be stated once the population is known.

## Positive observations
- The admission sites keep the exact key, message and expected-format arguments. Operators and translations see no change on the success-config path.
- The purge now matches its NoClear sibling exactly, including the WARN text, and the javadoc was rewritten rather than left asserting a divergence that no longer exists.
- The inbound fallback reuses the SBDEV-3004 constant and predicate instead of inventing a third rule.
- The tests use attributable probes (the unique Putaway Lane lookup, the mint call, `getKey()`) instead of message substrings, and pair positive with negative cases. PIT was run on changed lines, and the one survivor was closed with a named test.
- The independent `.matches(` re-sweep matches the ticket's 7-site list exactly.
