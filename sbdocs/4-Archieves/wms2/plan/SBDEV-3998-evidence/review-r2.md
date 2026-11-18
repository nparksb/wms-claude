# SBDEV-3998 review r2 (wms2-api PR #610), delta d9778ecb..ebeafd04 (a5c14e58, ebeafd04)

Read-only. No mvn, no lsp run (compile verdict belongs to the suite). Verdict: COMMENT. 0 High, 0 Medium, 3 Low.

## 1. Checked-exception ripple: no behaviour change
- ReplenishMaintenanceDeferralIT: `createFla` wraps `BusinessException` in `IllegalStateException`. Both call sites are `TransactionTemplate` lambdas (line ~166 and ~305). `BusinessException` is checked, and `createFixedLocationAssignment` has no `@Transactional`, so no rollback-only marker is set on this path. Spring rolls back on any RuntimeException, so an ISE gives the same rollback a runtime exception gave before. The REQUIRES_NEW site catches `Throwable` into `callbackError` and the test only asserts `isNull()`, so the wrapper type is invisible unless the call fails, and then the failure is just as loud.
- FixLocationAssignmentServiceIT `createThenEdit`: `create` sits in the first slot, which is `HeldRowLockRace.run(Runnable lockRow, ...)`. The holder catches `Throwable` into `holderError`, asserted null. The try/rethrow is required there and does not change what is observed. The third slot (`editThenCreate`, line 488) is `Subject.run() throws Exception`, so it needs no wrapper and compiles as it is.
- `create_marksInheritedOnRealPg ... throws BusinessException`: fine.
- MobilePutAwayServiceUnitTest `arrive(...)` throws BusinessException: all 3 callers (lines 3028, 3046, 3058) already `throws Exception`.
- MobileReplenishServiceUnitTest `stubDestinationCreatingFla ... throws BusinessException`: all 3 callers (3030, 3066, 3104) already `throws Exception`.
- The race harness has no special case for the exception type. It never inspects what the holder or subject throws beyond null.

## 2. Review-r1 Low fixes: all accurate
- L1 `SyspropService.java:339-345`: reader list (FLA, ViewDtoService, ReplenishOrderJob, ReplenishmentOrderMaintenanceService) and the three behaviours (write paths refuse with BusinessException naming the key, display maps to SYSTEM_INVALID, background fall back) match the code (`parseSyspropLong` line 465, `parseLongOrFallback` line 358).
- L3 `SyspropServiceUnitTest`: `parseLongOrFallback(KEY, "", "84")` -> `Long.parseLong("")` throws NFE -> WARN -> 84. The test is correct and guards the blank arm. Its DisplayName ("getIntValue's isBlank arm") is accurate.
- L4 `FixLocationAssignmentServiceUnitTest.java:1484-1488`: `move` is `@Transactional(value="tenantTransactionManager", rollbackFor={BusinessException.class, FacadeException.class})` (`FixLocationAssignmentService.java:121`). VERIFIED. The unit-load transfer (`transferUnitLoadToLocation`, line ~133) precedes `lockAndResolveDefaultBounds` (line ~140), so "refuses after the unit-load transfer" is right. Create (line 93) resolves bounds before `unitloadService.createUnitload` (line 99), so "refuses before any write" is right for create. Reset/clear: not re-read, taken from r1.

## 3. verifyNoInteractions swap: sound and strictly stronger
In FixLocationAssignmentService, `unitloadService` appears only at the field, constructor and line 99 (`createUnitload`), which is after bound resolution (line 91). `lockAndResolveDefaultBounds` and `systemDefaultBounds` do not touch it. `verifyNoInteractions` fails on any call to the mock, so it subsumes the old `never()` on `createUnitload`, and it has no null-blind matchers, so NeverMatcherNullBlindnessArchTest is satisfied. Stubbing in the test does not count as an interaction. The only risk is a future `@BeforeEach` that calls the mock, which would make it fail loudly, not silently.

## Findings

### LOW-1: DisplayName still over-claims "nothing written"
File: FixLocationAssignmentServiceUnitTest.java (nested class, just under the corrected Javadoc)
```
@DisplayName("SBDEV-3998 unparseable sysprop → BusinessException naming the key, nothing written")
```
The Javadoc now correctly says move writes then rolls back, but the DisplayName on the same class still says "nothing written", and it shows up in test reports. Fix: "... naming the key (create/reset/clear before any write; move rolls back)".

### LOW-2: move Javadoc omits when the move path reaches the parse
Same Javadoc, "move ... refuses after the unit-load transfer". `move` calls `lockAndResolveDefaultBounds` only inside `if (featureColumnsPresent() && findBoundsInheritedById(...).orElse(false))` (`FixLocationAssignmentService.java:~138`). An overridden (non-inherited) FLA never reads the sysprops on move. Accurate but incomplete; one clause ("for an inherited FLA") fixes it. The rollback is still asserted only by the annotation, not by any test (r1 L4 second bullet, still open).

### LOW-3: import placement and duplicated wrapper
- ReplenishMaintenanceDeferralIT.java:3-4 adds `net.aim_ai.wms.model.FixLocationAssignment` and `net.aim_ai.wms.exceptions.BusinessException` above `jakarta.persistence...`, out of the file's order. Cosmetic.
- The try/catch-rethrow-ISE appears three times now (`createFla` in the Deferral IT, inline in FixLocationAssignmentServiceIT, and the existing `edit()` in the same class). The IT could reuse one small private `create()` Runnable beside `edit()`, like the pattern already there.

## Positive
- Wrappers are minimal and keep the original cause (`new IllegalStateException(e)`), so a real failure keeps its trace.
- The swap to `verifyNoInteractions` strengthens the assertion while satisfying the arch rule.
- The Javadoc corrections now match the code on all three behaviours.

## Open Questions
- None.

## Recommendation
COMMENT (no blocking findings). r1 MEDIUM-1 (padded value now ignored by the job) is outside this delta and unchanged.
