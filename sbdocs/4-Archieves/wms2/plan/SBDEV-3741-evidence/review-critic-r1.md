**VERDICT: ITERATE.** There is one High finding, and it is cheap to fix. Everything else can be fixed in place.

**Overall assessment.** The server-side design is sound. The class gate is untouched, the programmatic gate runs before the FOR UPDATE read using the same principal as the interceptor, and the uncached location read and the staging-lane-only rule are both right. Three things need fixing:
1. The mobile half sends a request-level refusal (a bad destination) down the per-position refusal path. That path is the one SBDEV-3548 restricted on purpose.
2. A key claim about how stock moves to a lane is false for Case containers.
3. Several ACs or mutants are vacuous or misattributed.

**Mode.** I started THOROUGH and went ADVERSARIAL after finding one High plus several Mediums on the test plan.

**What I checked on origin/develop** (api `60ddb320`, mobile `b03b96a`). All of these exist as named:
- `CancellationCompleteRequest`
- `OrderCancellationController.completeReversal`, which has only the class gate
- the `CancellationReversalService.completeReversal` 3-arg form (`:234`) and its `transferStock(... log.getPickfromlocationname() ...)` call (`:429`)
- `AccessService.doesUserHaveAnyAccess(String, String...)` (`:107`)
- `SecurityContextUtils.getAuthorizedName`
- `LocationRepository.findByName` (returns Optional)
- `ScannedCodeResolver.canonicalLocationName`
- `MOBILE_UI_ACTION_WAIVE_CANCELLATION_REVERSAL` (`WmsConstants:484`)
- `STORAGE_LOCATION_TYPE_BOX_RESTRICTION_FLOWBIN = "flowbin"`
- `MSG_TRANSFER_DESTINATION_LOCATION_NOT_FOUND`
- the `"Destination location=… is locked="` message (`StockunitBusinessService:316`)
- the initDB waive grant (`UtilRestController:432`)
- audit SET 9 `step5_WAIVE_CANCELLATION`
- `MobileEndpointExceptionHandler.rethrowAccessDenied`
- `CancellationWaiveMigrationIT`, `CancellationLogEntryDtoSerializationTest`, `FunctionGuardMockMvcUnitTest` T11, `UtilRestControllerSeedUnitTest` T14
- `LocationService.getByName` is `@Cacheable`
- the V2.1.x onboarding migrations stop at V2.1.17, so V2.2.38 applies to every tenant.

---

### High

**H1. A bad destination returns 422, which makes every position "waivable" and keeps the loop running.**
- Plan §3.5 says `"The existing loop already stops on 401, 403 or no response"` and treats that as enough. It is not.
- Destination refusals (unknown, non-lane, locked, flow-bin, blank) are `BusinessException`, so 422.
- In `store/cancellation.js`, `completeReversal` returns `waivable: isPositionRefusal(status)`, which is true for any 4xx except 401/403.
- `completeSelectedPositions` then sets `if (outcome.waivable) waivable[positionId] = true` and only breaks on `status === null || 401 || 403`.
- Result: one mis-scan sends N POSTs. All N fail the same way, and all N rows get the Waive button.
- The loop's own comment calls these failures "about the REQUEST rather than the position, so the remaining positions would fail identically", which is exactly what a bad destination is.
- The store's SBDEV-3548 comment says Waive must be offered only on real position refusals, because a `stockReturned=false` waive "permanently suppresses the order's ORDER_BATCH_REVERSAL_COMPLETED notice".
- The people who can choose a destination (outbound-manager, super-admin) are the same people who hold the waive function, so this will happen in practice.
- A lane locked between position 1 and position 2 gives the same outcome: some positions land on the lane, the rest are marked waivable.
- No AC covers any of this. AC-17 tests only the 403 case.
- **Fix:** make destination refusals distinguishable and add an AC. Either:
  - (a) the API refuses them with a typed key or ProblemDetail `type` (e.g. `RTS_DESTINATION_INVALID`), and mobile treats that as a request-level failure: break the loop, set no `waivable`, show the message once on the scan field; or
  - (b) the scan field calls a cheap validate endpoint before the loop starts. This means a new route and gate, so (a) is preferred.
  - New Jest AC: "422 destination refusal on request 1 → no further POSTs and `waivable` empty". Mutation check: drop the break → red.

### Medium

**M1. The claim that a lane destination always takes the new-container branch is false for Case, Default and PickLocation containers.**
- Analysis §B4.3 says `"Tote and Case containers always take the new-container branch"`. Plan §2 B4 and §3.2 F7 (`"one new unit load per position"`) depend on it.
- `UnitloadService.TYPES_THAT_REST_IN_A_STORAGE_LOCATION = Set.of(UNIT_LOAD_TYPE_BOX, PICKLOCATION, DEFAULT)`, and `UNIT_LOAD_TYPE_BOX = "Case"` (`WmsConstants:934`).
- So a Case holding one stock unit with `amount == amountPicked` and no fixed-location assignment at its source takes the whole-unit-load arm (`StockunitService:517-546`): `transferUnitLoadToLocation(..., CODE_MANUAL_TRANSFER, ...)`. That moves the container itself to the lane and mints nothing.
- That arm's lock and authz path differs: an owning-Pickingorder pre-walk lock, `SourceLockGuard`, and `STORAGELOCATION_LOCKED` as a `FacadeException`.
- The 3 Case rows are explicitly in scope (§1: `"It applies to the 11 Clearing tote rows and the 3 Case rows"`).
- §7.4 row 8 (`"taken last in the standard order … so no new cycle"`) and AC-2 and AC-3 only reason about the new-container arm.
- The sibling `CancellationReversalLockClearIntegrationTest` already knows this arm is reachable from `completeReversal` (`reversalThatRelocatesTheContainerLeavesTheStockUnlocked`).
- **Fix:** correct B4 and F7. Add `CRDIT.toLane_singleSuCase_relocatesContainerWhole_lockZero`, asserting the stock is on the original UL now at the lane, at lock 0, with no new UL. State that the lock order on that arm is unchanged from today's source-bin route, rather than "no new cycle".

**M2. `CRDIT` is described as Testcontainers PG, but the sibling it names runs on H2.**
- §7.1 says `"CRDIT = new CancellationReversalDestinationIntegrationTest (Testcontainers PG, sibling of CancellationReversalLockClearIntegrationTest)"`. §7.5 row 7 says CRDIT runs on PG.
- The sibling `extends BaseRollbackIntegrationTest`, and its javadoc says it runs "against a real (H2) database".
- An executor copying the sibling lands on H2. That breaks the PG claim and inherits the shared-H2 create-drop cross-talk.
- **Fix:** pick one. Either extend `BasePostgresIntegrationTest` and say so (accepting that the PG IT lane has no tenant pool), or keep `BaseRollbackIntegrationTest` and remove the "PG" claims from §7.1 and §7.5.

**M3. Several refusal ACs have no mutant, and some can pass vacuously.**
- M-a…M-h cover the gate, its ordering, the principal and `staginglane`. Nothing mutates:
  - the lock-0 check,
  - the null-lock refusal,
  - the flow-bin refusal,
  - the blank check.
- The floor requires every new assertion to be mutation-checked.
- AC-6's `…_noTransfer` and AC-7's tests use `never()` on `transferStock`. If the FOR UPDATE finder mock is unstubbed, it returns an empty list, so `transferStock` is never reached whatever the validation does. If the assertion is only `assertThrows(BusinessException.class)`, a removed check can still go red or green for an unrelated reason, such as `detail(coId)` failing on an unstubbed repository.
- AC-6 says "recovery save rolled back", but validation runs before the finder, so no recovery save ever happens. The IT clause proves nothing.
- **Fix:**
  - Stub the finder with a movable pending row in every refusal test, so `never()` has teeth.
  - Assert the exact message text for each refusal.
  - Add mutants M-i (drop the lock check), M-j (accept null lock), M-k (drop the flow-bin check) and M-l (drop blank-after-trim), each naming its test.
  - Reword AC-6 to "no `logRepository.save`, no stamp".

**M4. The mutation list misattributes M-g.**
- M-g (`"Pass log.getPickfromlocationname() unconditionally → AC-2 and AC-15 red"`) leaves the column write intact, so AC-15 (`toLane_recordsDestinationColumn`) stays green. Only AC-2 goes red.
- M-h's red on AC-1 comes from an NPE (`dest.getName()` on null), not from an assertion.
- **Fix:** list M-g → AC-2 only. Define M-h as "write `dest`'s name when `dest == source`, skip it otherwise" and decide which test kills it, or drop it. Make AC-1's assertion `verify(log).setReversalDestinationLocation(any())` with `never()` on a stubbed row.

**M5. The 403 from the programmatic gate does not match the interceptor's 403, and the plan doesn't say so.**
- `FunctionGuardInterceptor` writes a ProblemDetail with a top-level `reason` (`:349`) and increments `wms2.authz.denied` (`:333`).
- The new `AccessDeniedException` is rethrown to `ExceptionTranslationFilter`. That response has no `reason` and emits no metric.
- Mobile `util/apiError.js:49` only recognises a typed denial when `status === 403 && data.reason`. Otherwise the operator gets the generic fallback ("Failed to complete reversal."). Plan §3.5 just says `"A 403 surfaces through the existing error path"`.
- **Fix:** state the expected body and toast in M3. Either accept the generic message explicitly, or throw something the handler renders with `reason: MISSING_FUNCTION` and `requiredFunction`. Add a WARN log line naming the user and the function (the §5.1 row 8 INFO line covers successes only).

**M6. If V2.2.38 doesn't apply on a tenant, cancellation breaks on that tenant, not just RTS-to-lane.**
- §6 (`"Schema … additive; hibernate validate only checks mapped columns"`) only argues the rollback direction.
- Going forward: `ddl-auto` defaults to `none`, and `StartupFlywayMigrator` lets one tenant fail or be skipped (no history) without failing the boot ("that tenant stays on its old schema").
- A mapped `reversal_destination_location` that is missing from the DB breaks every Hibernate load of `customerorder_cancellation_log` on that tenant. That includes `recordCancellation`, the list and detail screens, and waive, not just the new path.
- The function-row half fails safe (the scan stays hidden); the entity half does not. V2.2.34 set the same precedent, so this is a known pattern, but a T3 plan should name it.
- **Fix:** add a post-deploy check to §8: confirm `flyway_schema_history` has `2.2.38` with `success=true` on all six tenant DBs before Phase 2 merges. Add a row to §6 with this blast radius.

### Low
- **L1.** §3.2 step 4 uses `!loc.isStaginglane()`, but `Location.staginglane` is a `Boolean` with `getStaginglane()` (`Location.java:33,123`). Use `!Boolean.TRUE.equals(loc.getStaginglane())`.
- **L2.** Step 6 (refuse flow-bin) needs `LocationType.getSltname()`, so `LocationTypeRepository` is a fourth new dependency. §4 lists three, and "13 → 16" becomes 17.
- **L3.** Manual row M7 uses `SELECT … FROM function`. The tables are `mywms_function` and `mywms_role_mywms_function` joined to `mywms_role`, with role names `'outbound-manager'` and `'super-admin'`. §3.3 item 2 says to grant "role_outbound_manager and role_super_admin" in Flyway; those are the initDB Java identifiers, not SQL role names.
- **L4.** §3.5 says `"complete() builds the payload"`. The payload is actually built in the store action `completeReversal` (`$post(..., { notes, positionIds })`). The component's `complete()` dispatches `completeSelectedPositions`. The plan names no mutation such as `SET_RTS_DESTINATION`, and doesn't say how `rtsDestination` reaches the per-position dispatch. Spell out that path.
- **L5.** Completeness-word violations:
  - §7.1 says `"Every invariant above is JUnit- or Jest-observable"`, but the plan's own M3 (literal 403) and M6 (OMS inventory) are manual-only. State the method and the blind spot.
  - §3.2 F9 says `"Nothing here writes Location"` with no method given.
- **L6.** The AC-8b fixture must stub `doesUserHaveAnyAccess(eq("alice"), eq(FN))`, not `anyString()`. Otherwise M-e survives. Also mind the varargs matching.
- **L7.** Rollback (§8) doesn't mention that handhelds cache `home.functions` in persisted Vuex state. Deleting the grants takes effect only after `home/refreshMenus`.
- **L8.** Alternatives: G2 is rejected because it `"Leaves the service open to a future 3733 caller"`, while §3.2 says a 3733 system-chosen fallback should skip the operator gate anyway. That reasoning is thin, though option A is still the better choice. Reword it: the gate binds any caller that supplies an *operator* destination.

### What's missing
- An AC for a lane locked mid-loop (partial completion plus the H1 waivable marking).
- The whole-container-move arm to a lane (M1).
- A post-deploy check per tenant that V2.2.38 applied (M6).
- A denial log or metric for the programmatic gate (M5).

### Multi-perspective
- **Executor:** an executor hits L1, L2, L4 and M2 without having to ask anyone, and each costs time.
- **Stakeholder:** the scope limit (14 of 37 rows) is stated honestly.
- **Skeptic:** H1 is the realistic way this fails in production: a supervisor mis-scans, sees Waive on every row, and waives.

### Verdict justification
H1 survives the realist check. It recreates a hazard that SBDEV-3548 deliberately fenced off, and the destination-holders and waive-holders are the same people. It is not data loss on its own, but it opens a route to permanently suppressing an OMS notice, so it keeps its severity. No downgrades. To upgrade to APPROVE: fix H1 with an AC and mutant, M1–M3, and M6. The rest can be fixed during the TDD gate.

### Open questions (not scored)
- Does a picked Case's `unitload.entity_lock` trip `SourceLockGuard` on the whole-container arm today? If so, the 3 Case rows are refused regardless of destination, and §1's scope shrinks to 11.
- Does `CancellationLogEntryDto` serialise null fields? If so, the new key appears in every detail response. That is harmless to mobile, but it is a wire change.

### Ralplan summary
- **Principle/option consistency:** Pass. Principles 1–5 match option A. P4 ("refuse early") holds server-side but is broken by the mobile half (H1).
- **Alternatives depth:** Pass, with a thin reason for rejecting G2 (L8).
- **Risk/verification rigor:** Fail. Missing mutants and vacuous `never()` (M3), misattribution (M4), H2 vs PG (M2), no per-tenant migration check (M6).
- **Deliberate additions:** not applicable (SHORT mode).

Files reviewed:
- /home/nampark/dev/wms-claude/sbdocs/1-Projects/wms2/plan/SBDEV-3741-rts-choose-staging-lane-destination.md
- /home/nampark/dev/wms-claude/sbdocs/1-Projects/wms2/plan/SBDEV-3741-evidence/ralplan-dr.md
- /home/nampark/dev/wms-claude/sbdocs/1-Projects/wms2/plan/SBDEV-3741-evidence/analysis.md