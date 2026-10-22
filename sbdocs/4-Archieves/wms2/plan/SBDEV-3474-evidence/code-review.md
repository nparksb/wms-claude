# SBDEV-3474: independent code review of `3b8b19e1`

- **Worktree:** `.claude/worktrees/wms2-api/SBDEV-3474`, branch off `origin/develop` `67acb39d`
- **Reviewer lane:** code-reviewer, read-only. No Maven run, no file changes, no stash or checkout. A `mvn verify` was running in the worktree during the review.
- **Evidence:** `git show 3b8b19e1`, targeted reads of the touched files and their collaborators (`StringConverter`, `SyspropService.getSysvalue`, `TruckLoadingController`, `MobileTruckLoadingWriteService` PHASE A/B/D0, `MobileMoveUnitloadService.handleTruckOffLoading*`), and `git grep` sweeps. Cross-repo UI claims were checked against `origin/develop` of `wms2-mobile-ui` and `wms2-web-ui`.
- **Not done:** compile, type diagnostics or test execution. These are left to the in-flight `mvn verify`. Every "passes" or "fails" below is reasoned from the code, not observed.

## Summary

| Severity | Count |
|---|---|
| Critical | 0 |
| High | 0 |
| Medium | 2 |
| Low | 8 |

Stage 1 (spec): **PASS.** The change matches the architect consult (Option C). The pure guard is its own `@Component`. It is called in the non-transactional facade before and outside the `PessimisticLockingFailureException` try. `checkPallet` delegates to it. Matching is configured-only, and the guard fails closed when neither pattern is configured. The ITs mock it, and an ArchUnit rail with a positive control pins the call site. The write-service javadoc paragraph is updated. One small deviation: the consult put the regression tests in `MobileTruckLoadingServiceUnitTest` with an `InOrder`. They landed in `MobileTruckLoadingServiceTest` and use a real guard plus a lenient throwing stub on the write service. That proves the same ordering, so this is not a finding.

---

## Q1: OutboundPalletLabelGuard vs. the old `checkPallet` inline check

**Configured cases (both patterns set) are preserved exactly.** Traced side by side:

- Old: `if (!palletLabel.matches(pattern) && !palletLabel.matches(convertedPrintingPattern)) throw new BusinessException("noValidString", palletLabel, StringConverter.describeExpectedFormat(printingPattern, pattern, convertedPrintingPattern));`
- New: `boolean matches = (patternConfigured && palletLabel.matches(pattern)) || (printingPatternConfigured && palletLabel.matches(convertedPrintingPattern)); if (!matches) throw new BusinessException("noValidString", palletLabel, StringConverter.describeExpectedFormat(printingPattern, pattern, convertedPrintingPattern));`

The key and all three message arguments are identical. Evaluation order is also identical: the string pattern is tried first, and the printing pattern only when the first does not match. So a malformed-regex `PatternSyntaxException` happens in the same place as before. The null/empty-label branch (`entityNotFoundForName`, `Unitload.class.getSimpleName()`, label) is byte-identical to the old line and to the write service's PHASE A (`MobileTruckLoadingWriteService.java:252-253`).

**Where the behaviour changed (all as the javadoc claims):**

| Sysprop state | Old `checkPallet` | New guard |
|---|---|---|
| pattern set, printing null or empty | `matches("")` is false for a non-empty label, so this was the same as "pattern only" | same result, no change |
| pattern null, printing set | `String.matches(null)` gives an **NPE**, a 500 | printing pattern alone decides (**loosened**, which is the intended fix) |
| pattern `""`, printing set | `"".matches` false, then printing decides | printing decides, no change |
| both null | NPE, a 500 | `LOG.warn` + `noValidString` "(no label format configured)" (fail closed) |
| both `""` | already `noValidString` (not an NPE) | `LOG.warn` + `noValidString`, same outcome |

The javadoc sentence "A tenant with neither sysprop set already got a 500 from `checkPallet`" holds for null values. For empty-string values the old result was already `noValidString`, so "blocks no one who works today" still holds.

**New exception paths at scanGate.** `StringConverter.convertFormatToRegex` throws `ArrayIndexOutOfBoundsException`, `StringIndexOutOfBoundsException` or `NumberFormatException` on a malformed printing format (`split("-")[1]`, `substring(digitLen-3, …)`). A malformed `STRING_PATTERN` throws `PatternSyntaxException`. These now fire in the scanGate facade. They are **not new failure modes for scanGate**, because PHASE D0 (`MobileMoveUnitloadService.handleTruckOffLoadingNoClear:534-536, 563`) already ran `convertFormatToRegex` unconditionally and `matches(pattern)` whenever a pattern was configured. It did so **inside the write transaction, after B1–B5 had taken their row locks**. The same misconfiguration now fails **before any lock**, which strictly improves on the old behaviour. The result is still an uncaught RuntimeException, so a 500 via `RestExceptionHandler`, as it was from D0 and from `checkPallet`. The consult accepted this as out of scope, and I agree.

**ReDoS:** the regex is admin-configured and the label is user input, which was already true in `checkPallet` and D0. scanGate now evaluates the same regex twice (guard + D0), which costs nothing extra in complexity. No new exposure.

## Q2: Transaction placement

- `MobileTruckLoadingService` is `@Service` with no `@Transactional` on the class or on `scanGate` (grep: the only occurrence is the javadoc at `:139`).
- `TruckLoadingController` has no `@Transactional`, and `AdminController` (its base) has none.
- `FunctionGuardInterceptor` is a `HandlerInterceptor.preHandle` (`:190`). It opens no transaction that spans the handler, and no `@Aspect`/`@Around` exists in `src/main`.
- `spring.jpa.open-in-view=false` (`application.properties:85`). So no request-scoped EntityManager joins the guard's sysprop read to the write transaction.
- `SyspropService.getSysvalue` is `@Cacheable` and non-transactional. It calls `syspropRepository.findSysvalueBySyskey`, a scalar projection that materialises no entity. Even when called inside the write transaction it would touch no locked table.

Verdict: the guard really does run outside any tenant transaction.

**Response shape:** `BusinessException("noValidString")` propagates from `MobileTruckLoadingService.scanGate` to `TruckLoadingController.scanGate:121`, which calls `catch (BusinessException e) { errors.add(getErrorMessage("Runtime Error", e.getMessage())); }` and returns 200 + `errors`. That is the same shape as every other BusinessException rejection on this endpoint and as `/scanPallet`. `EntityNotFoundException` rejections (BOL by name) still go via `RestExceptionHandler`, as before.

## Q3: Removal of `syspropService` from MobileTruckLoadingService

- No remaining reference in `MobileTruckLoadingService.java` (grep for `syspropService|StringConverter|WmsConstants.SYSTEM` finds nothing).
- Only two constructor call sites exist in the repo, both updated: `MobileTruckLoadingServiceTest:71` and `MobileTruckLoadingServiceUnitTest:85`.
- No `extends MobileTruckLoadingService`, no `ReflectionTestUtils`/`setField` naming it, and no `"syspropService"` string anywhere in `src/`.
- Spring constructs it by its single constructor, so no `@Bean` factory needs changing.

Clean.

## Q4: `@MockitoBean OutboundPalletLabelGuard` in the ITs

- **MobileTruckLoadingRollbackIT:** both tests assert a failure far below the guard: `EntityNotFoundException` "ItemData" at D6 (`:356-359`) and `FacadeException` "STORAGELOCATION_LOCKED" (`:466-469`). Neither asserts anything label-related. Without the mock, `TL1-PALLET-0001` fails the seeded `OUT-[0-9]{6}` / `OUT-%06d` patterns, so the tests would die at the guard with `noValidString`. The mock is necessary and hides no previous assertion.
- **AbstractTruckLoadingPgFixture** (subclasses `MobileTruckLoadingRaceIT`, `MobileTruckLoadingLockOrderProbeIT`): the scanGate calls at RaceIT `:328` and Probe `:302` grade lock contention and lock order, not labels. `TL3465-…` matches neither V2.2.00 pattern, so without the mock every scan would stop at the guard. No hidden assertion.
- The mocked `void` method is a no-op by default. Correct.

Q4 hides nothing, but a coverage gap sits right next to it. See **M1**.

## Q5: Unit tests

- **MobileTruckLoadingServiceTest** already built the service by hand. The only change is that it now passes `new OutboundPalletLabelGuard(syspropService)`. The existing `checkPallet` tests stub both sysprops. Both `getSysvalue` calls happen before matching, so STRICT_STUBS stays satisfied. The four existing scanGate tests gained `stubOutboundPalletPatterns()`. `"PALLET001"` matches `PALLET.*`, and `convertFormatToRegex("PALLET-001")` evaluates to `PALLET-\d{0}` without throwing. No assertion was removed or loosened.
- The new `scanGate_shouldRejectANonOutboundLabelBeforeTheWriteService` is well built. The lenient `thenThrow(new AssertionError(...))` on the write service makes removing or reordering the guard fail with a self-naming error. `verifyNoInteractions` is not tripped by the stubbing call, because Mockito removes the `when(...)` invocation from the recorded interactions. A mutant that moves the guard below the write-service call is killed.
- **MobileTruckLoadingServiceUnitTest:** replacing `@InjectMocks` with manual construction is faithful. Mockito's constructor injection resolves by type, and the class never declared `@Mock ManageOrderService` or `@Mock MobileTruckLoadingWriteService`, so `@InjectMocks` already passed `null` for both. No test in the class calls `scanGate` (grep), and `loadOrder`/`checkPallet`/`truckLoadingMobileDTOByBolName`/`resolveBOLType`/`getBOLManifestLocations` never touch either collaborator (`manageOrderService` is used only at `:202`, the write service only at `:166`). The outer `@BeforeEach` runs before each `@Nested` test. The javadoc's claim is accurate.

## Q6: TruckLoadingWriteEntryPointArchTest

- `callMethod(Class<?> owner, String methodName, Class<?>... parameterTypes)` is the correct ArchUnit 1.3.0 overload, and the signature matches `scanGate(TruckLoadingMobileDto)`.
- `noClasses().that().doNotHaveFullyQualifiedName(...)`: fluent `should().callMethod` walks `getMethodCallsFromSelf()` over **all** code units, so constructors and static initialisers are covered. That is unlike the hand-rolled `getMethods()` form the memory note warns about. Lambdas inside the facade compile to synthetic methods of the same class and are correctly allowed.
- `DO_NOT_INCLUDE_TESTS` is correct: `MobileTruckLoadingWriteServiceUnitTest` calls the write service directly.
- The positive control is sound. `classes().that().haveFullyQualifiedName(X).should().callMethod(...)` fails if the facade stops calling that exact signature, which covers a rename or an added parameter that would make the negative rule vacuous. `archRule.failOnEmptyShould` defaults to true in 1.3.0, so an empty class set also fails. `archunit.properties` configures only a freeze store, and this rule is not frozen.
- The blind-spot list (method refs, reflection, differently-typed subtype or proxy receivers) is accurate but incomplete. See **L4**.

## Q7: Sibling sweep (report only)

1. **No other production path creates a BOL position for a pallet.** `billofladingPositionService.createEntity(` is called only from `MobileTruckLoadingWriteService:465/474/482`. `new BillofladingPosition()` exists only in `BillofladingPositionService:123`. `BillofladingService:610 saveAll` is `closeBOL` re-saving existing positions. `BillofladingPositionRepository` is `exported = false`, so there is no SDR POST. Within the "load onto a truck/BOL" axis, the facade is the only entry point.
2. **The same inline outbound-label check survives in four other sites, each with the old NPE-on-null-pattern shape** (`label.matches(pattern)` with `pattern` possibly null):
   - `MobilePalletizeWriteService.java:278` and `:466`: `if (!palletLabel.matches(pattern) && !palletLabel.matches(convertedPrintingPattern))`
   - `ParcelMonitorViewService.java:149` (`palletise`, new-pallet branch): same shape, and a different message (`"Not valid format: "`)
   - `MobileMoveUnitloadService.java:494` (`handleTruckOffLoading`, the clearing overload used by `scanDestination`): `if (unitLoadLabel.matches(pattern) || unitLoadLabel.matches(convertedPrintingPattern))`. Its javadoc at `:512-516` already records the NPE divergence.
   The palletize sites could call `OutboundPalletLabelGuard` directly: its javadoc states it is safe inside a transaction, and they are admission checks too. `handleTruckOffLoading` must **not** use it, because it is a purge whose safe side is fail-open, the rule the guard's own javadoc explains. Estimated cost: about 10 lines per palletize site plus unit-test stubs. Blast radius: the palletize handheld flow and the web parcel-monitor palletise. Proposed on the existing ticket as a follow-up (under T3), or as a separate ticket if SBDEV-3474 ships first.
3. **`ParcelMonitorViewService.palletise` and palletize onto an EXISTING pallet skip the label check entirely.** `:141-149` checks the pattern only when `palletOpt.isEmpty()`. Parcels can therefore be palletised onto an existing non-outbound pallet (for example an inbound pallet). The guard now stops that pallet at `/scanGate`, which is good defence in depth. But the root admission gap sits upstream in palletising, not in truck loading. Not verified against data; confidence LOW.

---

## Findings

### [MEDIUM] M1: The truck-loading ITs certify a PHASE D0 branch that production can no longer reach through scanGate, and the reachable branch has no IT
**Files:** `src/test/java/net/aim_ai/wms/integration/service/mobile/AbstractTruckLoadingPgFixture.java:87-93, 130-137`; `MobileTruckLoadingRollbackIT.java:219-227`
**Confidence:** HIGH (reachability); MEDIUM (impact)

Now that the guard runs first with the **same two sysprops, read the same way** (the `SyspropService` cache), every label that reaches PHASE D0 in production matches a configured pattern. So D0 always takes its purge branch (`MobileMoveUnitloadService:563-571`, which runs `findBolIdByUnitLoadLabelId` and, for a re-scanned pallet, DELETEs `billoflading_position` rows inside the locked boundary). The only exception is a sysprop edit landing between the two reads. The ITs deliberately use non-matching labels and a mocked guard, so they only ever exercise D0's "configured but no match" early exit, which is now production-unreachable via scanGate. The comments still describe that branch as the one "this test wants exercised":

> `// the branch this test wants exercised is the one where the patterns ARE configured and simply do not match.` (RollbackIT `:222-223`)
> `{@link #PREFIX} matches neither pattern, so the purge resolves and deletes nothing` (fixture `:90-91`)

This gap existed before the commit, because the UI always went through `checkPallet` first. But until now a direct call could reach that branch. The commit makes the tested branch fully unreachable and cements the label choice with a mock. The architect consult flagged the unverified consequence: *"In RaceIT that may mean the second scanner purges the first scanner's committed position (not verified)."* That is the production behaviour of two concurrent re-scans today, and no test observes it. The LockOrderProbe likewise never sees D0's DELETE row locks, which come after B1.

**Fix (not in this ticket's scope, since it is T3-shaped: concurrency plus a destructive purge):** (a) update the two comments to say the no-match branch is unreachable from production scanGate since SBDEV-3474, and that the fixture deliberately trades realism for determinism. (b) Propose a follow-up with an IT that scans an outbound-labelled pallet already on a BOL (`WC_` + 16 digits, with the LIKE sweep adjusted as the consult describes), asserting the purge-then-rebuild sequence and that the race outcome is correct. Rank: first among the follow-ups.

### [MEDIUM] M2: Four sibling copies of the old check keep the NPE the guard just fixed
**Files:** `MobilePalletizeWriteService.java:278, :466`; `ParcelMonitorViewService.java:149`; `MobileMoveUnitloadService.java:494`
**Confidence:** HIGH

`if (!palletLabel.matches(pattern) && !palletLabel.matches(convertedPrintingPattern)) {`: with `STRING_PATTERN_OUTBOUND_PALLET` unset and only the printing pattern set, these give a 500 (NPE), the same defect the commit message says it fixed for `checkPallet`. The commit's own comment (`// SBDEV-2962 (C5): both accept patterns, same as the palletizing sites.`) keeps the pairing visible, so the sites are known. **Fix:** route the three palletize admission sites through `OutboundPalletLabelGuard`. Keep `handleTruckOffLoading` separate (a purge, so it fails open), but give it D0's configured-only rule. See the sibling sweep, item 2.

### [LOW] L1: "No repository access" is literally false
**File:** `src/main/java/net/aim_ai/wms/service/mobile/OutboundPalletLabelGuard.java:22-27`
**Confidence:** HIGH

> `<p><b>No repository access, on purpose.</b>`

The guard calls `SyspropService.getSysvalue`, which calls `syspropRepository.findSysvalueBySyskey` on a cache miss (`SyspropService.java:333-336`). The paragraph goes on to say "Sysprop reads are not entity touches on the locked tables", which is the true and load-bearing claim. The commit message repeats "no repository access". **Fix:** "No entity reads, on purpose. Its only I/O is two cached scalar sysprop reads (a projection on `los_sysprop`), which create no `EntityEntry` and touch none of the tables the write service locks."

### [LOW] L2: The commit message's closed list of old outcomes omits "success"
**Commit message:** `a non-outbound label at scanGate now gets noValidString (before any lock) instead of unexpectedUnitLoadDoesNotHaveOrder or entityNotFoundForName.`
**Confidence:** MEDIUM

A direct `/scanGate` caller with a non-outbound-labelled pallet whose children **do** carry orders previously **succeeded**. It now gets `noValidString`. The UI cannot reach that state (the handheld always calls `/scanPallet` first with the same `palletName`: `wms2-mobile-ui` `origin/develop` `components/truckLoading/scanPallet.vue:66` and `scanGate.vue:59`, so `checkPallet` already blocked it). So this is intended, but the sentence should say "…or, for a direct API caller, success". The `wms2-web-ui` Cypress suites call `/truckLoading/scanGate` directly (`pick-pack-order.cy.js:1333, 1476`; `club-line-order.cy.js:689`). The negative cases (`9.V4`, `9.V5`, label `PM-NEG-…`) accept any error and grade 4xx vs INFO, so they will not go red, but their error text changes from `entityNotFoundForName` to `noValidString`.

### [LOW] L3: The write-service javadoc's "never reaches B1" is stronger than the rail
**File:** `src/main/java/net/aim_ai/wms/service/mobile/MobileTruckLoadingWriteService.java:148-151`
**Confidence:** HIGH

> `so a label that matches neither outbound pattern (an inbound pallet, for example) never reaches B1.`

This is true for the call path through `MobileTruckLoadingService.scanGate` only. The pin is at class granularity with the blind spots listed in the arch test. **Fix:** "…never reaches B1 through the facade; `TruckLoadingWriteEntryPointArchTest` pins the facade class as the only production caller, within ArchUnit's call-site blind spots."

### [LOW] L4: The arch test's blind-spot list omits class granularity
**File:** `src/test/java/net/aim_ai/wms/unit/config/TruckLoadingWriteEntryPointArchTest.java:27-31`
**Confidence:** HIGH

The rule allows **any** method of `MobileTruckLoadingService` to call the write service, so a future `scanGateBulk` or retry helper added to the facade could skip the guard and stay green. The reverse also applies: a legitimate call moved into a nested or anonymous class (`MobileTruckLoadingService$1`, a different FQN) reds the rule against correct code. The memory note on ArchUnit call-site rules records both effects. **Fix:** add one sentence: "Class granularity: any method of the facade may call it, so a new facade method must call the guard itself; a call moved into a nested class of the facade reds this rule."

### [LOW] L5: The guard unit test's display name claims an unasserted property
**File:** `src/test/java/net/aim_ai/wms/unit/service/mobile/OutboundPalletLabelGuardUnitTest.java:158-166`
**Confidence:** HIGH

> `@DisplayName("a null or empty label is rejected with entityNotFoundForName, before any sysprop read")`

Nothing asserts "before any sysprop read". A mutant that reads the sysprops first (unstubbed mock returns null) and then checks the label still passes. **Fix:** add `verifyNoInteractions(syspropService);` after the assertion.

### [LOW] L6: Guard unit tests do not cover empty-string sysprop values
**File:** `OutboundPalletLabelGuardUnitTest.java`
**Confidence:** HIGH

`patternConfigured = pattern != null && !pattern.isEmpty()`. Only the `null` half is exercised. A mutant dropping `&& !pattern.isEmpty()` would let `""` through to `palletLabel.matches("")`. That still rejects a non-empty label, so it may be an equivalent mutant for the reject direction. But the pair "pattern `""` + printing set, matching printing label" is the one case that separates configured-only from the old code's order. **Fix:** add `stubPatterns("", HYDRA_PRINTING_PATTERN)` accept and reject cases, plus `stubPatterns("", "")`, to pin the fail-closed `LOG.warn` branch for empty values.

### [LOW] L7: Per-scan WARN logs a user-supplied label on a misconfigured tenant
**File:** `OutboundPalletLabelGuard.java:68-73`
**Confidence:** MEDIUM

> `LOG.warn("Neither {} nor {} is configured; rejecting pallet {} …", …, palletLabel);`

This fires on every `/scanPallet` and `/scanGate` for such a tenant (D0's twin warning has the same property), and it logs raw request input. SLF4J placeholders do not neutralise CR/LF. This mirrors existing D0 style and is acceptable. Noted for completeness.

### [LOW] L8: No test pins `checkPallet`'s guard-before-lookup order
**File:** `MobileTruckLoadingService.java:86-89`
**Confidence:** MEDIUM

`checkPallet` now delegates, and `testCheckPalletWithInvalidPattern` / `shouldThrowExceptionWhenPalletDoesNotMatchPattern` still assert the key. I found no `verifyNoInteractions(unitloadRepository)` on the reject path, so moving the guard below `findByLabelid` would not be caught. That is harmless for locks (the lookup does not lock) but changes the message precedence for a non-existent, non-outbound label. **Fix (optional):** assert `verify(unitloadRepository, never()).findByLabelid(any())` in the invalid-pattern test.

## Open questions (low confidence, not blocking)

- **[MEDIUM, confidence LOW] Printing-pattern width overflow makes system-generated pallets unloadable.** `ParcelMonitorViewService:125-130` builds labels with `String.format(PRINTING_PATTERN, n)`, while `convertFormatToRegex` accepts exactly `\d{width}`. Once the sequence passes `10^width − 1` (for example `AOUT-%1$06d` at n ≥ 1,000,000), new labels have one more digit and match no accept pattern unless `STRING_PATTERN` covers them. This predates the commit (`checkPallet` already rejected such labels). It is mentioned because the guard now enforces the same rule at a second entry point. Not checked against any tenant's current sequence value.
- **Context-cache cost of the added `@MockitoBean`.** The consult states that both IT classes already had unique context keys, so no extra context is created. I did not verify this independently. It affects performance only.

## Positive observations

- Guard placement is correct and minimal. It sits before and outside the lock-translation try, with a comment explaining why. It needs no transaction and changes no first-touch ordering.
- Byte-identical key and message arguments for the configured case, and identical evaluation order. Existing operator messages and the `describeExpectedFormat` rendering are unchanged.
- Fail-closed vs D0's fail-open is argued from the action's safe side, and both javadocs explain the asymmetry, so nobody "harmonises" them later.
- The scanGate regression test is mutation-aware (a lenient throwing stub makes a missing guard self-diagnose instead of NPE-ing), and it uses the real guard over mocked sysprops.
- The ArchUnit rail has a real positive control against vacuity, correctly excludes tests, and states its own blind spots.
- The write-service javadoc now states the fan-out residual honestly: an outbound-labelled pallet with no orders still locks every child before PHASE C.
- A malformed printing-pattern sysprop now fails before any row lock, where before it failed at D0 after all of them. The commit does not claim this, but it is an improvement.

## Verdict

No Critical or High finding. M1 and M2 are pre-existing gaps adjacent to the change (proposed as follow-ups: M1 first, since it covers the production-reachable destructive branch). L1–L8 are doc and test precision items that can be fixed in this pass per the "address Lows too" policy.

APPROVE
