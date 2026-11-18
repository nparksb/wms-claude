# SBDEV-3998 review r1 (wms2-api, bugfix/SBDEV-3998-fla-bounds-sysprop-one-rule)

Read-only review of `git diff origin/develop`. No mvn run, nothing written in the worktree. No lsp_diagnostics run (a suite is running; compile verdict is the suite's).

Verdict: COMMENT (no High at high confidence). 1 Medium, 4 Low, plus verified-OK items.

## Stage 1 - spec
- (1) `SyspropService.parseLongOrFallback` exists, same no-trim parse as `parseLongOrDefault`, WARN + default on rejection. Job and maintenance service use it. OK.
- (2) FLA write paths map NFE to `BusinessException("Sysprop <KEY> is not a whole number: '<v>'")`. All four paths (create, move, reset, clear) funnel through `parseSyspropLong`, so there is one mapping site. OK.
- (3) Background readers fall back to 84, never throw. OK.

## Findings

### MEDIUM-1: job now ignores a padded value that it used to honour
File: `src/main/java/net/aim_ai/wms/schedulejob/ReplenishOrderJob.java:759-763`
```java
SyspropService.parseLongOrFallback(KEY,
        syspropService.getSysvalue(KEY), WmsConstants..._UPPER_BOUND_VALUE)
```
Old: `getIntValue` does `value.trim()` + `isBlank()` -> default (`SyspropService.java:365-373`). New: no trim. Why this is live, not theoretical: `setSysvalue` (`SyspropService.java:377-390`) stores `value` untrimmed, and the one-arg `getSysvalue(key)` (`@Cacheable`, line ~333) returns the raw repo value. Only the 3-arg overload trims (`.trim()` at 197/212/227/240/265). So a row saved as `"120 "` or `"120\n"` (paste, trailing newline) was 120 for the job and the maintenance pass sized with... see below, and is now 84 for the job with a WARN. This is the user-decided "one rule", and it matches the write paths and `ViewDtoService`, so the new behaviour is consistent. The risk is the silent shift for a tenant that currently has a padded row: replenishment sizes to 84 instead of 120 with only a WARN.
Fix (pick one, or accept and record): (a) trim inside `parseLongOrFallback` only for the background readers - but then it no longer shares the write paths' rule; (b) keep no-trim and state the whitespace change in the ticket/PR body, and run one DB check (`SELECT syskey, sysvalue FROM sysprop WHERE syskey LIKE 'FIX_LOCATION_ASSIGNMENT_DEFAULT_VALUE_%' AND sysvalue <> btrim(sysvalue)`) on dev/UAT/PRD (read-only) before merge. Option (b) is the cleaner reading of the ticket. Confidence: HIGH on the mechanism, MEDIUM that any tenant has such a row.

### LOW-1: stale Javadoc on `parseLongOrDefault`
File: `src/main/java/net/aim_ai/wms/service/SyspropService.java:339-345`
```
A value it rejects throws NumberFormatException: the write paths let it fail, the display path maps it to SYSTEM_INVALID.
```
Now wrong: the write paths map it to `BusinessException`, and the background readers use `parseLongOrFallback`. Also "shared by FixLocationAssignmentService ... and ViewDtoService" omits the two new readers. Fix: "the write paths refuse (BusinessException), the display path maps it to SYSTEM_INVALID, background readers use parseLongOrFallback."

### LOW-2: WARN every minute per bad value
File: `SyspropService.java` `parseLongOrFallback` (`LOG.warn("Sysprop {} is not a whole number: '{}'; falling back to default {}"`)
The replenish cron runs every minute (per MobileReplenishService comment) and the maintenance resolver runs per assignment per recalculation. One bad row produces a WARN per tick, per FLA. Not a correctness bug; log volume only. Fix: accept, or rate-limit (e.g. log once per distinct (key,value) via a small `ConcurrentHashMap` set). Also note an absent value logs nothing here (null -> default is silent), unlike `FixLocationAssignmentService.parseSyspropLong` which WARNs on absent. Inconsistent but harmless.

### LOW-3: blank value changes meaning slightly
Old `getIntValue`: `""`/blank -> default 100 silently. New: `""` -> `Long.parseLong("")` NFE -> 84 with WARN. Same destination (84), noisier. Covered by no test. Fix: add one `parseLongOrFallback(KEY, "", "84")` case, or note it.

### LOW-4: test gaps
- `FixLocationAssignmentServiceUnitTest` `UnparseableSysprop` / `move_unparseableSysprop...`: the "nothing written" claim is only partly provable in a unit test. For `move`, the unit-load transfer (`unitloadRepository.save` is stubbed and called before the bound resolution at `FixLocationAssignmentService.java:176-180`) has already happened when the exception is thrown; the assert only checks `fixLocationAssignmentRepository.save` never called. Rollback of the earlier write rests on `@Transactional(rollbackFor = BusinessException)` on `move` (line 121 block), which is correct in production but not tested. The `@DisplayName` for move says only "BusinessException naming the key", so it does not over-claim; the nested-class Javadoc ("before writing anything") does for move. Fix: soften the Javadoc to "create/reset/clear refuse before writing; move relies on the transaction rollback", or add an IT.
- No test that a `BusinessException` from `createFixedLocationAssignment` reaches a caller and rolls back (e.g. `FixLocationAssignmentServiceIT` with a bad UPPER row). Low, the callers' annotations are correct (see below).
- Only UPPER is the bad key in all new tests. LOWER/MIDDLE mapping share the single `parseSyspropLong`, so this is fine; mutation-check would still go red if the catch were removed.
- `ReplenishOrderJobUnitTest` has no test with a valid padded or valid non-default value through the new path besides the existing 150 case; fine.

### LOW-5: `ReplenishOrderJobConnectionBudgetTest` and other job tests now see 84, not 0
Tests that never stubbed `getIntValue(UPPER)` used to get Mockito's `0`; unstubbed `getSysvalue` returns null -> now 84. Not in the diff's list because they don't mention the constant. Only a problem if one asserts the bound; none found by grep (`ConnectionBudgetTest` has no UPPER reference). The full suite run will confirm.

## Verified OK (no finding)

- Checked-exception ripple: `createFixedLocationAssignment` has five production callers, all already declare `throws BusinessException`:
  - `StockunitService.transferStock` (:436, `@Transactional rollbackFor={BusinessException,...}`)
  - `MobileReplenishService.finishReplenishmentOrderWithoutRefill` (:223, throws FacadeException, BusinessException)
  - `MobileReplenishService.assignDestinationForMultiUnitLoads` (:1074, throws ... BusinessException), reached via `fulfillMultipleUnitLoadsTx` which carries `rollbackFor = {BusinessException.class, ...}`
  - `MobilePutAwayService.storeBoxOnLocation` (:583, same rollbackFor)
  - `MobileMoveUnitloadService.scanDestination` (:356, same rollbackFor)
  No caller wraps the call in a catch. The only `catch (Exception)` nearby (`MobileReplenishService.java:932`) wraps the post-commit `recalculateForItem`, not creation, and runs after `fulfillMultipleUnitLoadsTx` has returned. `createFixedLocationAssignment` itself has no `@Transactional`; it joins the caller's, and all five callers' transactions roll back on `BusinessException`. `FixLocationAssignmentService` move/reset/clear all carry `rollbackFor = BusinessException`.
- Test callers of `createFixedLocationAssignment` (11 files) are the compile risk, not production; those in lambdas need `throws`. Not verifiable without a compile; the running suite covers it.
- `FindOrCreateUnitloadCallerArchTest` call-site count key (`createFixedLocationAssignment/2`, 1L) is unaffected (no call sites added or removed).
- Valid values: for a valid integer string the job gets the same number (long vs int, scale 0 `BigDecimal.valueOf(long)`), maintenance service same. Values above Integer.MAX now parse instead of defaulting; irrelevant in practice.
- Absent key: job 100 -> 84 is the intended fix; `getSysvalue` is `@Cacheable(unless result == null)`, so the number of DB reads is unchanged.
- Stub conversions (`ReplenishOrderJobUnitTest` x3, `ReplenishOrderJobSweepStarvationTest`): `getIntValue(UPPER, any)` -> `getSysvalue(UPPER)` returning the same number as a string. Sound. The strictness shifts: SweepStarvation and the ~line 320 one are strict `when`, so they now require the job to read `getSysvalue(UPPER)` (good, an unused-stub failure if it stops). The two new job tests make `getIntValue` answer its own fallback, so a revert to `getIntValue(..., 100)` yields 100 and goes red for both absent and unparseable: they do guard the stated bug.
- Raw-spelling sweep: `grep` of the three key literals in `src` finds only the constants, `WmsConstants`, the V1.0.04 / V2.2.00 seed rows, `V2.2.45__location_default_fla_bounds.sql` (SQL copies the values into locations once; not a runtime reader) and a commented-out block in `UtilRestController:166-168`. Readers: `FixLocationAssignmentService` (3 keys), `ViewDtoService:981-985` (3 keys, `parseLongOrDefault`, SYSTEM_INVALID on NFE), `ReplenishOrderJob` (UPPER), `ReplenishmentOrderMaintenanceService.resolveUpperBound` (UPPER). No missed reader. Nothing reads LOWER/MIDDLE in a background path.
- `ReplenishmentOrderMaintenanceService`: the private `parseLong(String,String)` is still used at :403 (cadence), so it is not dead. It catches `Exception` (broader than needed) but is outside scope. Existing test `fallsBackToDefaultUpperBoundOnNonNumeric` already covers the changed method with "invalid".

## Positive
- One mapping site (`parseSyspropLong`) for all four write paths; the message names the key and the offending value.
- `parseLongOrFallback` composes `parseLongOrDefault` rather than re-implementing, so the rules cannot drift.
- Tests assert the exact message and `never()` on writes; stubs are strict where the read is mandatory.

## Open Questions
- None at HIGH/CRITICAL. Only decision needed: MEDIUM-1 (accept the whitespace change, and run the read-only DB check for padded rows).
