---
title: "SBDEV-3741 — Return to Stock: let the operator choose a staging-lane destination"
ticket: "SBDEV-3741"
ticket_url: "https://app.clickup.com/t/868mgde8k"
type: "feature"
priority: ""
status: archived
tier: T3
db_verified: true
project: [wms2]
version: "v2"
requester: "Nam Park"
created: "2026-10-12"
updated: "2026-10-12"
related:
  - "[[SBDEV-3741-evidence/analysis]]"
  - "[[SBDEV-3741-evidence/review-architect]]"
  - "[[SBDEV-3741-evidence/review-critic-r1]]"
  - "[[SBDEV-3547]]"
  - "[[SBDEV-3381]]"
  - "[[261012-wineco-cancelled-orders-stock-shipped]]"
  - "[[261012-c1wh-pending-reversals-waive]]"
tags:
  - plan
---

> **Archived 2026-10-13.** Shipped to dev: wms2-api#507 (`11468c4a`) → wms2-mobile-ui#87 (`36368b6`). V2.2.38 was verified on the dev tenant, and the feature was live-tested on dev as panderson (ClickUp comment 90110278741188).
> No acceptance script was planned, so none was retired.
> Implementation worktree(s) removed 2026-10-13: wms2-api/SBDEV-3741, wms2-api/SBDEV-3741-baseline, wms2-mobile-ui/SBDEV-3741.
>
> **Finding dispositions at archival** (findings gate):
> - Flyway number re-sweep — **Fixed.** V2.2.38 is free on all branches (collision script) and applied on dev.
> - P1 lane census — **Fixed** for all 4 PRD tenants and dev. **UAT: owner Nam/devops**, done with the per-environment check below.
> - Per-environment `flyway_schema_history` V2.2.38 check before UAT/PRD promotion — **owner Nam/devops**; already stated on SBDEV-3741.
> - M6 (OMS inventory treatment of lane stock) and M3 (live 403 for a non-holder) — **not machine-knowable; owner Nam (manual QA).** M3 needs an account without the function.
> - A13 audit `step6` row — **Dropped:** `audit-access-invariants.sql` is not in the wms2-api repo, and the access audit reads grants from the DB.
> - Case row `pos 35841889` (amount_picked 2 > available 1) — **on SBDEV-3740** (comment 90110278758002).
> - Accepted residuals (lane locked or re-typed inside one request; retry after a lane lock) — **Dropped as deliberate design.** The rationale is in code comments, §3.2.2 and the PR inline notes.
> - ScanInput emits the literal `keyup.enter`, which other screens' `@keyup.enter` shorthand may not receive in scanner mode — **proposed new ticket, NOT filed** (SBDEV-3741 is past `on dev`; unverified, outside this ticket). **Owner: Nam** decides whether to file.

# SBDEV-3741 — Return to Stock: let the operator choose a staging-lane destination

**Ticket:** [SBDEV-3741](https://app.clickup.com/t/868mgde8k) · **Tier:** T3 (new authz function, Flyway migration, two repos) · **Version:** v2
**Evidence:** [analysis.md](SBDEV-3741-evidence/analysis.md) and the round-1 reviews ([architect](SBDEV-3741-evidence/review-architect.md), [critic](SBDEV-3741-evidence/review-critic-r1.md)).
- Code claims come from `origin/develop`: wms2-api `60ddb320`, wms2-mobile-ui `b03b96a`. Both were re-fetched 2026-10-12 and are unchanged since round 1.
- Line numbers are approximate. Quoted snippets are exact.
- **Analysis §B4.3 is superseded by §2 B4 below.** Case containers can be moved whole.

---

## 0. Affected sites

Rows A1–A28 are from analysis §A; A29 onwards were added in round 2. C = covered, X = excluded.

| # | Repo · site | C/X | Where |
|---|---|---|---|
| A1 | api `json/CancellationCompleteRequest`: add a nullable `destinationLocationName` | C | §3.1 |
| A2 | api `OrderCancellationController.completeReversal`: pass the field through; class gate only | C | §3.1 |
| A3 | api `CancellationReversalService.completeReversal`: add a 4-arg overload; the 3-arg form delegates with `null`; **both carry the identical `@Transactional`** | C | §3.2 |
| A4 | other production callers of `completeReversal(` | X | `git grep "completeReversal(" -- src/main` finds only the controller plus comments. Blind spot: reflective or SpEL callers (none known) |
| A5–A7 | `transferStock`, `transferStockToUnitLoad`, residue re-lock | X | Unchanged. Both arms are reachable (§2 B4); covered by AC-2, AC-2c, AC-14 |
| A8 | `SourceContainerGuard` (3353) | X | Judges the source. AC-13 |
| A9 | `waiveReversal` | X | Same FOR UPDATE lock; ignores the destination |
| A10 | `WmsConstants.FunctionEnum`: add `MOBILE_UI_ACTION_RTS_CHOOSE_DESTINATION` | C | §3.3 |
| A11 | Flyway `V2.2.38` (provisional): ALTER first, then the function row and grants | C | §3.3, §3.4 |
| A12 | `UtilRestController.initDB`: add a `grantFunction` line | C | §3.3 |
| A13 | `audit-access-invariants.sql` SET 9: add a `step6` row | C (optional) | §5.2 |
| A14–A18 | seed/initDB tests, GOLDEN_MAP (must stay unchanged), T11 pin, `ActionGuardAnnotationContractUnitTest` (blind to programmatic checks) | C | §7.1 |
| A19–A20 | `OrderCancellationControllerUnitTest`, service unit test and IT | C | §7.1 |
| A21 | `CancellationLogEntryDto.reversalDestinationLocation`, built in `CancellationReversalService.toDetailDto` (~:873); there is no separate mapper | C | §3.4 |
| A22 | `CancellationLogService`, pending job, finders | X (coupled) | No code change. They depend on V2.2.38 applying, because the entity maps the column (§6 row 6, §8 step 2) |
| A23 | club-line `validateStockOnStagingLane` | X | Lock-0 stock can be consumed by the lane's batch (D1) |
| A24 | mobile `store/cancellation.js` | C | §3.5 |
| A25 | mobile `components/cancellation/cancellationAction.vue` | C | §3.5 |
| A26 | mobile `pages/cancellation.vue` | X | `<cancellation-action v-else-if="process === '2_action'">`, so the component remounts per entry. AC-20 pins it |
| A27 | mobile Jest specs | C | §7.2 |
| A28 | wms2-web-ui | X | `git grep -i "reversalNotes\|reversal_notes\|cancellation/"` finds 0 hits. Blind spot: dynamic URL building |
| A29 | api **new** `service/RtsDestinationValidator` (`@Component`) holds the gate and the lane rules | C | §3.2 |
| A30 | api **new** `security/FunctionAccessDeniedException extends AccessDeniedException` (carries an `AccessDecision`) | C | §3.2.1 |
| A31 | api **new** static `security/AuthzDenialWriter.write(...)`, extracted from `FunctionGuardInterceptor.deny()`; the interceptor delegates to it | C | §3.2.1 |
| A32 | api `MobileEndpointExceptionHandler`: `@ExceptionHandler(FunctionAccessDeniedException.class)`, plus an `@Autowired (ObjectMapper, MeterRegistry)` constructor. The no-arg constructor is kept, so its 7 test sites stay untouched | C | §3.2.1 |
| A33 | api **new** `exceptions/RequestRefusedException extends BusinessException`; `RestExceptionHandler` maps it to 422 with ProblemDetail `type` | C | §3.2.2 |
| A34 | test constructor-only edits: `CancellationReversalServiceUnitTest:128` and `StockunitServiceParcelSourceRefusalUnitTest:609` each gain one argument (the validator) | C | §7.1 |
| A35 | `UnitloadBusinessService.transferUnitLoadToLocation`: its destination lock check throws `FacadeException("STORAGELOCATION_LOCKED")` | X | Unchanged. Pre-empted by the validator; the residual race is in §3.2.2 |
| A36 | mobile `util/apiError.js`: export `REQUEST_REFUSED_TYPE` and `isRequestRefusal(error)` | C | §3.5 |
| A37 | api `Authority.java:~141` comment "Emitted by `FunctionGuardInterceptor` and nowhere else" | C | reword: "emitted only through `AuthzDenialWriter` (interceptor + `MobileEndpointExceptionHandler`)" |
| A38 | api `FunctionGuardArchTest.java:~1172` comment "the header's first and only emitter" | C | same rewording |

## 1. Problem

On WineCo PRD between 2026-09-25 and 2026-10-12 there were **3 cancel-and-re-create events covering 43 units** (`261012-wineco-cancelled-orders-stock-shipped.md` §5.3, §8 row 3). In each, the picked stock was needed on a staging lane for the re-created order.

Today's options:
- Return to Stock (RTS) sends the stock to the **source bin**, so the stock is re-picked.
- The old workaround, a hand Move Stock to the lane, is now refused by **SBDEV-3547** (lock 100 has two exits: complete and waive).

What's missing is a third option inside "complete": send the stock **to a staging lane the operator scans**.

**Scope (F6, re-measured in round 2):** of the 37 pending WineCo PRD rows, **13 can use this feature**: 11 Tote rows at Clearing and 2 Case rows at PutAwayLane. **24 cannot, whatever the destination:**
- 13 in Nirwana at lock 2;
- 10 in shipped Packages at lock 405;
- Case row `pos 35841889` on StagingLane05, whose `amount_picked` (2) exceeds the stock unit's available amount (1). `transferStockToUnitLoad` refuses it with "amount=… requested is more than available=…", and it would be refused on today's path too.

**SBDEV-3740 (waive) covers those 24.** Source: analysis DB-3, plus DB-6 run 2026-10-12, which is pending rows joined to stockunit, unitload, `unitload_type`, location and `fix_location_assignment`.

## 2. Current architecture

Analysis §B is not restated here. The anchors:
- **B1:** the class gate is `MOBILE_UI_VIEW_CANCELLATION`. `/complete` has no method annotation.
- **B2:** order of work: input checks, then `findPendingReversalsForUpdateByCustomerorderId`, then pre-validation (3316 recovery save, null-source refusal, 3326, 3353), then the loop (clear to 0 + flush, then `transferStock(su, amt, false, log.getPickfromlocationname(), null, null, false)`, residue re-lock, stamps), then `enqueueReversalCompletedIfClosed`.
- **B4 (corrected): a lane destination reaches two arms of `transferStock`.**
  - **New-container arm:** taken when the source is a Tote (`restsInStorageLocation` is false), or the source container holds more than one stock unit or more than `amountPicked`. It mints one unit load (UL) at lock 0 per call, then calls `transferStockToUnitLoad`. A locked lane is refused with BusinessException "Destination location=… is locked=".
  - **Whole-container arm** (`StockunitService:~517`): taken when the source is a Case, Default or PickLocation (`TYPES_THAT_REST_IN_A_STORAGE_LOCATION`) holding one stock unit whose amount equals `amountPicked`, with no fixed-location assignment (FLA) at the source location.
    - It calls `SourceLockGuard.assertSourceUnlockedForContainerRelocation`, which refuses any non-zero lock on the stock unit, UL or source location. Null passes.
    - It then calls `transferUnitLoadToLocation(..., CODE_MANUAL_TRANSFER, ...)`, which moves the **original container** and mints nothing.
    - A locked lane is refused with `FacadeException("STORAGELOCATION_LOCKED")`.
    - **The lock order matches today's route to the source bin.** Only the destination location row is different. `lockOwningPickingorders` resolves through `pickfromstockunitId`, and a pick-to stock unit is never a pick source, so the Pickingorder set is empty (comment in the service's movement loop).
  - Neither arm can reach the flow-bin branch or the Damaged (D5) branch, because §3.2 refuses both kinds of destination up front.
  - **Open question resolved (Critic):** on WineCo PRD both PutAwayLane Case ULs have UL lock 0, location lock 0 and stock-unit lock 0, so SourceLockGuard does **not** trip. The stock unit is in any case cleared and flushed before the call.
- **B7:** adding a function needs three touches.
- **B9:** mobile sends one POST per position with `notes: ''`. Lane facts are in analysis DB-1..DB-5: WineCo PRD has 20 lanes, all lock 0, type `cases and pallets`, no FLA, no constraint rows, and 13 of the 20 hold an open club batch. Prerequisite P1 covers the other tenants.

## 3. Design

### 3.1 Request and controller (A1, A2)
- `CancellationCompleteRequest` gains `private String destinationLocationName;` with no annotations.
- The controller calls the **4-arg** form: `completeReversal(customerOrderId, request.getNotes(), request.getPositionIds(), request.getDestinationLocationName())`.
- There is **no** method-level `@RequiresFunction`. A method gate *replaces* the class default (waive javadoc).

### 3.2 Service, validator and order of checks (A3, A29)
```
@Transactional(value="tenantTransactionManager", rollbackFor={BusinessException.class, FacadeException.class})  ← identical on BOTH
completeReversal(id, notes, positionIds)                  → return completeReversal(id, notes, positionIds, null)
@Transactional(…identical…)
completeReversal(id, notes, positionIds, destinationLocationName):
  1. existing positionIds checks (unchanged)
  2. Location dest = destinationLocationName == null ? null : rtsDestinationValidator.validate(destinationLocationName)
  3. findPendingReversalsForUpdateByCustomerorderId(...)     ← unchanged from here on, except:
  4. loop: transferStock(su, amt, false, resolveDestinationName(log, dest), null, null, false)
           if (dest != null) { log.setReversalDestinationLocation(dest.getName()); LOG.info(coId, positionId, dest, operator) }
```

**Transaction invariant (Architect M2):**
- Both overloads carry the **identical** annotation. The 3-arg form's self-call bypasses the proxy, so neither form may rely on the other's annotation.
- The controller calls the 4-arg form.
- Pinned by AC-21 (reflection, annotation `equals`, so propagation, readOnly and isolation are all covered).

**`RtsDestinationValidator.validate(raw)`** (new `@Component`, 4 dependencies). It throws, in this order:
1. **Gate (D3):**
   - `AccessDecision d = accessService.checkAnyAccess(SecurityContextUtils.getAuthorizedName(), MOBILE_UI_ACTION_RTS_CHOOSE_DESTINATION.name())`.
   - If `!d.allowed()`, throw `new FunctionAccessDeniedException(d)` (§3.2.1).
   - The principal choice (F10, unchanged) is analysis §F10 / round-1 §3.2.
2. **Blank after trim:** `RequestRefusedException("Destination location is blank — scan a staging lane or leave the field empty")`.
3. **Resolve the name:** `scannedCodeResolver.canonicalLocationName(trimmed)`, **wrapped**: its plain keyed `BusinessException(MSG_SCAN_CODE_AMBIGUOUS_LOCATION)` (thrown when ≥2 locations differ only by case — `ScannedCodeResolver.java:~106-114`; WineCo PRD has 2 such non-lane pairs today) is rethrown as `RequestRefusedException` preserving key and params (copy constructor `RequestRefusedException(BusinessException)`). Then **`locationRepository.findByName(..)`** (uncached, F9). If nothing is found: `new RequestRefusedException(MSG_TRANSFER_DESTINATION_LOCATION_NOT_FOUND, name)`, the keyed form, so tests assert `getKey()`.
4. **Not a staging lane:** `!Boolean.TRUE.equals(loc.getStaginglane())` refuses (null is refused). Message: `"<name> is not a staging lane — Return to Stock can only send stock to a staging lane"`.
5. **Locked:** `!Objects.equals(loc.getEntityLock(), NOT_LOCKED)` refuses (null is refused). Message: `"Staging lane <name> is locked (" + LockRefusalMessages.describe(lock) + ") — choose another lane"`.
6. **Flow bin (D2):** if `loc.getTypeId() == null`, refuse (typed, missing-type message) — `findById(null)` throws `IllegalArgumentException`. Otherwise resolve the type with `locationTypeRepository.findById(loc.getTypeId())`. Refuse when `WmsConstants.STORAGE_LOCATION_TYPE_BOX_RESTRICTION_FLOWBIN.equals(type.getSltname())`, or when the type is missing. Message: `"<name> is a flow bin — Return to Stock cannot assign a flow bin"`.

**Validator invariant (round-2 Architect M-1 / Critic M1):** every exception `validate` throws is a `RequestRefusedException` or a `FunctionAccessDeniedException`. Method: the six steps above are the validator's only calls; repository calls on a well-formed name throw nothing typed-as-business (blind spot: infrastructure exceptions such as a dropped connection still surface as 500, which is not waivable). Pinned by `RDVUT.ambiguousCaseSpelling_refusedTyped` and `RDVUT.nullTypeId_refused`.

**Destination-caused refusal downstream (round-2 Critic M2) — typed by key, not by text.** Both movement arms can refuse a lane's location type with the keyed `BusinessException(MSG_UNITLOAD_TYPE_NOT_PERMITTED_ON_LOCATION)` (`UnitloadBusinessService.java:~321` whole-container arm; `StockunitService.java:~275` new-container arm when `TRANSFER_DESTINATION_CONSTRAINT_ENFORCED`). In the 4-arg loop, **only when `dest != null`**, catch a `BusinessException` whose `getKey()` equals that constant and rethrow it as `RequestRefusedException(e)`. Matching on the key, not message text, is why the §9 "fragile" objection does not apply. Every other `BusinessException` from the loop (null source, 3326, 3353, amount > available) propagates unchanged and stays per-position waivable (SBDEV-3548). Pinned by `CRSUT.destination_typeNotPermittedOnLane_rethrownTyped` and `CRSUT.destination_amountExceedsAvailable_staysUntyped`.

**Why a collaborator, not 17 constructor arguments (Architect M5, L2):**
- Inlining this logic would take the service from 13 to 17 arguments (`AccessService`, `LocationRepository`, `ScannedCodeResolver`, `LocationTypeRepository`). The validator brings it to 14.
- The validator is also the operator-input half of the SBDEV-3733 seam. `resolveDestinationName(log, dest)` stays a private method in the service, so 3733's system-chosen fallback goes there and never meets the operator gate.
- SourceLockGuard's javadoc warns that a guard reached through a mock leaves its tests asserting a stub. That does not apply here, for two reasons:
  - the rules are tested directly in `RtsDestinationValidatorUnitTest`;
  - `CancellationReversalServiceUnitTest` passes a **real** validator over mocked repositories, never a mocked validator.

**F3 (L4 reworded):** the null-`pickfromlocationname` refusal still applies **after destination validation passes**. A row with both a bad destination and a null source reports the destination error. AC-7b pins this.

**F7 (corrected):**
- New-container arm: one new UL per position on the lane.
- Whole-container arm: no new UL; the original Case or Default container moves to the lane.
- Consolidation stays out of scope (13 of 20 lanes are busy, and there is one POST per position).

**F9:**
- The validator reads the uncached repository, because `LocationService.getByName` is `@Cacheable` and can be stale.
- The new code calls no `Location` setter and no `save`. Method: review of the diff surface.
- Whatever the two movement primitives already write on today's source-bin route, they write the same way on a lane.

**F5:** unchanged. Totals are judged by the `stock_view` DDL; the OMS inventory sync is checked manually in M6.

#### 3.2.1 Gate denial uses the interceptor's wire contract (Architect M1, Critic M5)
- `AuthzDenialWriter.write(HttpServletResponse, ObjectMapper, MeterRegistry, AccessDecision, String controllerTag)` is a **static** method holding the body of today's `FunctionGuardInterceptor.deny()`:
  - the explicit `LinkedHashMap` body: `type`, `title`, `status`, top-level `reason`, `requiredFunction`;
  - `X-Authz-Denied`;
  - the `wms2.authz.denied` counter.
- `deny()` delegates to it as a **pure move**: no logic edits, `METRIC_DENIED` moves with it, `logDenial` stays in the interceptor. It is static so that none of the 14 `new FunctionGuardInterceptor(...)` test sites change. Gate: `FunctionGuardInterceptorUnitTest` and `ReplenishOrderControllerGateH2Test` pass unchanged.
- `FunctionAccessDeniedException` holds its decision as `private final transient AccessDecision decision` (`RuntimeException` is `Serializable`; `AccessDecision` is not).
- `MobileEndpointExceptionHandler` gets `@ExceptionHandler(FunctionAccessDeniedException.class) void handleFunctionDenied(ex, HandlerMethod hm, HttpServletResponse resp)`:
  - it logs WARN `"Denied {fn} (RTS destination) on {handler} for user '{}' ({reason})"`;
  - it calls the writer with `controllerTag = hm.getMethod().getDeclaringClass().getSimpleName()`, the same derivation as the interceptor (`FunctionGuardInterceptor.java:~197`; `getBeanType()` differs for handlers inherited from a base class such as `AdminController`).
  - The kept no-arg constructor delegates `this(new ObjectMapper(), new SimpleMeterRegistry())`, so an advice built in a test never NPEs on a denial.
- `ExceptionDepthComparator` prefers this handler to the generic `AccessDeniedException` rethrow. `RestExceptionHandler` (`@Order(0)`) has no `AccessDeniedException` handler, so this advice is reached.
- The result on the handheld:
  - `axios.js` sees the header and does not retry;
  - `onError` shows the typed denial toast;
  - `apiErrorMessage` returns null, so there is no second toast;
  - the loop breaks on 403, which is existing behaviour.
- Callers that are not mobile still receive an `AccessDeniedException`.

#### 3.2.2 Destination refusals are request-level and typed (Critic H1)
- **Existing mechanism, reused.** `RestExceptionHandler` renders a `BusinessException` as a 422 ProblemDetail, and the mobile client reads `detail`. No key reaches the wire, and `properties.*` nest under `$.properties` in production but are flattened in `standaloneSetup` (memory: problemdetail-properties-nest).
- **The one addition** uses ProblemDetail's standard root field `type`, which sits at the root on every channel and in both test lanes:
  - `RequestRefusedException extends BusinessException`, with both the message constructor and the keyed constructor;
  - a new `RestExceptionHandler.handleRequestRefused` returning 422 with `detail = ex.getMessage()`, `title = "Business Rule Violation"`, `retryable=false` and `type = URI.create("urn:wms2:problem:request-refused")`;
  - it is more specific than the `BusinessException` handler, so it wins within the same advice.
- **On mobile:**
  - `completeReversal` returns `{ requestRefused: true, waivable: false }` when `isRequestRefusal(error)` is true;
  - the loop breaks on `requestRefused` alongside 401, 403 and null, records **neither** `refusals` nor `waivable` for that position, and returns `{ requestRefusal: message }`;
  - the component shows the message under the scan field.
  - A 422 without that `type` keeps today's per-position behaviour, which is the SBDEV-3548 fence (AC-19b).
- **Lane locked mid-loop: request-level, pinned.**
  - Every per-position POST re-runs the validator before the FOR UPDATE read. A lane locked between position *k−1* and position *k* is therefore refused on request *k* with the typed 422. The loop breaks, positions 1..*k−1* stay completed, and no Waive button is offered (AC-7c, AC-19c).
  - **Residual race, accepted (security review L3, same class):** an admin re-typing the lane (staging-lane flag / flow-bin type) between the validator's unlocked read and the transfer is not re-caught — only `entity_lock` is re-checked under the row lock. Closing it means locking the destination location before the stock/unit-load rows, inverting the transfer lock order (deadlock risk against every other transfer).
  - **Retry after a lane lock (code review L9), documented:** the validator runs before the loop's "already completed → skip", so a handheld retry of a timed-out POST that DID commit, against a lane locked in between, gets a typed 422 instead of the success detail. Harmless (the stock is already on the lane); confusing to the operator; not fixed.
  - **Residual race, accepted:** a lane locked *inside* one request, between the validator's non-locking read and the lane's FOR UPDATE.
    - On the new-container arm that gives an untyped 422 ("Destination location=… is locked="), so that one row is marked waivable and its reason text names the lane.
    - On the whole-container arm it gives a 500 through the mobile catch-all (`STORAGELOCATION_LOCKED` is unmapped), which is not waivable.
    - In either case the next request hits the typed refusal and breaks.
    - Closing this would mean matching downstream message text (the lock refusal carries no dedicated key). That is rejected as fragile; contrast the keyed type-not-permitted refusal, which IS typed (§3.2).

### 3.3 Function provisioning (D3, A10–A12): three touches
1. Add the constant next to `MOBILE_UI_ACTION_WAIVE_CANCELLATION_REVERSAL`. The `ACTION_` prefix keeps it out of audit SET 3.
2. Add `V2.2.38__rts_choose_destination.sql`, ordered as follows (Architect M4):
   - **ALTER first** (§3.4);
   - then `INSERT INTO mywms_function … WHERE NOT EXISTS`;
   - then `INSERT INTO mywms_role_mywms_function … WHERE r.name IN ('outbound-manager','super-admin') AND NOT EXISTS`.
   - These copy V2.2.34. Flyway runs the script in one transaction, so a failed ALTER leaves no function row, and the scan field stays hidden.
3. Add `initDB` `grantFunction(...RTS_CHOOSE_DESTINATION, role_outbound_manager, role_super_admin)` next to the waive line. `role_*` are the Java identifiers; the SQL role names are `outbound-manager` and `super-admin`.

### 3.4 Recording the destination (D5, A21)
- In V2.2.38: `ALTER TABLE public.customerorder_cancellation_log ADD COLUMN IF NOT EXISTS reversal_destination_location character varying(255);`
- Map it on `CustomerorderCancellationLog`. Set `CancellationLogEntryDto.reversalDestinationLocation` in `toDetailDto` (~:873).
- **Wire:** `WebConfigurer` sets `Include.NON_NULL` globally, so the key is **absent** whenever it is null. Detail responses for default completions are byte-identical (resolves the Critic's open question).
- Write the column only when the operator supplied a destination, including when it equals the source.
- The `reversal_notes` write is unchanged.

### 3.5 Mobile (A24, A25, A36): dispatch path spelled out (Critic L4, Architect M3)
- **Component-local state, not Vuex.** `cancellationAction.vue` `data()` gains `rtsDestination: ''` and `destinationError: null`. The data is not persisted and is rebuilt on every `2_action` mount. A `watch` on `order.customerorderId` clears both, as defence in depth.
- **The path:**
  - `complete()` dispatches `completeSelectedPositions({ coId, notes: '', positionIds, destinationLocationName: rtsDestination.trim() || undefined })`;
  - for each position, that dispatches `completeReversal({ coId, notes, positionIds: [id], destinationLocationName })`;
  - `completeReversal` builds `body = { notes, positionIds }` and adds `body.destinationLocationName` **only if it is truthy**, then calls `$post`.
  - No store field and no new mutation are involved.
- `completeSelectedPositions` returns `{ requestRefusal }` on **every** exit after the loop, including the `if (!refreshed)` early return (capture `requestRefusal` before `fetchDetail`). `complete()` becomes `async` and `await`s the dispatch, then assigns the result to `destinationError` (today `complete()` neither awaits nor returns — `cancellationAction.vue:~254`).
- **One message, not two:** `completeReversal`'s catch skips `toastError` when `isRequestRefusal(error)`; the refusal is shown only under the scan field (AC-19).
- `canChooseDestination = functions.includes('MOBILE_UI_ACTION_RTS_CHOOSE_DESTINATION')`, the same pattern as `canWaive`. The scan field is shown only when this is true.
- The subtitle reads "returned to staging lane X" when a destination is set, and keeps "returned to its source location" otherwise.
- **Version skew:** the scan field depends on the function row, which exists only after V2.2.38. `FAIL_ON_UNKNOWN_PROPERTIES=false` is settled.

## 4. File change summary

| Repo | File | Change |
|---|---|---|
| api | `json/CancellationCompleteRequest.java`, `controller/mobile/OrderCancellationController.java` | add the field; 1-line pass-through |
| api | `service/CancellationReversalService.java` | 4-arg overload (identical `@Transactional` on both), `resolveDestinationName`, column write, INFO line, `toDetailDto` DTO field; +1 constructor arg (validator) |
| api | `service/RtsDestinationValidator.java` | **new** |
| api | `security/FunctionAccessDeniedException.java`, `security/AuthzDenialWriter.java` | **new**; `FunctionGuardInterceptor.deny()` delegates to the writer |
| api | `exceptions/RequestRefusedException.java` | **new** |
| api | `exceptions/RestExceptionHandler.java`, `exceptions/MobileEndpointExceptionHandler.java` | one handler each; the mobile advice gets an `@Autowired` constructor |
| api | `WmsConstants.java`, `model/CustomerorderCancellationLog.java`, `json/CancellationLogEntryDto.java` | constant; column field; DTO field |
| api | `db/migration/V2.2.38__rts_choose_destination.sql`, `UtilRestController.java` (initDB) | add; one grant line |
| api | `audit-access-invariants.sql` SET 9 | optional `step6` row |
| mobile | `util/apiError.js`, `store/cancellation.js`, `components/cancellation/cancellationAction.vue` | modify |
| mobile | `test/store/cancellationRtsDestination.spec.js`, `test/components/cancellation-rts-destination.spec.js` | **new** |

## 5. Phased plan

### 5.1 Prerequisites

| # | Prerequisite | Action | Notes |
|---|---|---|---|
| 1 | Database state | Re-run DB-1 (lanes: lock, type, FLA, constraint rows, whether the type admits **Case**) on **every v2 tenant DB**. Enumerate the tenants from the landlord `tenant` table at gate time; the six-DB census note predates WineCo PRD | Refusals cover flow-bin and locked lanes. A lane type that excludes Case would refuse the whole-container arm inside `transferUnitLoadToLocation`; record it |
| 2 | Feature flags | N/A | Gated by function |
| 3 | Config | N/A | `FAIL_ON_UNKNOWN_PROPERTIES=false` and `Include.NON_NULL` are existing behaviour |
| 4 | Deploy order | **API (V2.2.38) before mobile, everywhere** | §8 |
| 5 | Migration | **Re-sweep all remote branches for V2.2.38 at gate time** (420 refs were clean on 2026-10-12; control: V2.2.35–37 found) | Runs every boot (SBDEV-2801) |
| 6 | External | N/A | OMS payload unchanged |
| 7 | Access | Flyway plus initDB grant to outbound-manager and super-admin | |
| 8 | Monitoring | INFO per destination completion (`coId`, `positionId`, `destination`, `operator`); WARN plus `wms2.authz.denied{controller=OrderCancellationController}` per denial | No new metric name |

### 5.2 Phase 1: wms2-api
- **Branch:** `feature/SBDEV-3741-rts-choose-destination`, in worktree `.claude/worktrees/wms2-api/SBDEV-3741` off a fresh `origin/develop`.
- **Goal:** §3.1–§3.4 plus §7.1.
- **Order of work:** failing tests first (`wms-tdd-gate`), then the migration and constant, the exceptions and writer, the validator, the service, the controller, and initDB.
- **Risk:** Medium (an authz surface, a schema change and the shared denial writer). The default path is byte-identical.
- **Effort:** about 2 days.

### 5.3 Phase 2: wms2-mobile-ui
- **Goal:** §3.5 plus §7.2, in worktree `.claude/worktrees/wms2-mobile-ui/SBDEV-3741`.
- **Risk:** Low–Medium (it changes the loop's break rule).
- **Effort:** about 0.5–1 day.
- **Merge only after §8 step 2 passes on dev.**

## 6. Backward compatibility

| Aspect | Before | After | Impact |
|---|---|---|---|
| `/complete` body without the field | moves to source bin | same path (`resolveDestinationName` returns the source); detail JSON identical (NON_NULL) | none; the 47 test call sites still use the 3-arg form |
| Who can do plain RTS | VIEW_CANCELLATION | unchanged; GOLDEN_MAP unchanged | none |
| Old mobile on new API | works | works | none |
| New mobile on old API | n/a | scan field hidden (no function row) | §8 rollback order |
| Interceptor 403 body/header/metric | — | same bytes, now via `AuthzDenialWriter` | pinned by the existing `FunctionGuardInterceptorUnitTest` |
| **Schema / unmigrated tenant** | — | the entity maps the new column | **If V2.2.38 fails on a tenant, that tenant's order cancellation breaks, not just RTS.** Every load or insert of `CustomerorderCancellationLog` fails: `recordCancellation`, list/detail, waive, `PendingReversalReconciliationJob`. `ddl-auto=none` and `StartupFlywayMigrationRunner` ("migrations never take the app down") boot anyway. Mitigation: §8 step 2. Precedent: V2.2.34 ALTERed the same table on every tenant |
| Error shapes | 422 `BusinessException` | adds a typed 403 (interceptor contract) and a 422 with `type=urn:wms2:problem:request-refused`, on the destination path only | the mobile loop stops on both without marking rows waivable. Method: every validator exception is typed (§3.2 invariant) and the one keyed downstream destination refusal is rethrown typed. Blind spot: the in-request lane-lock race (§3.2.2) can still mark one row waivable |

**What does NOT change:** the OMS payload and its re-send on replay; the residue re-lock condition; 3316, 3326 and 3353; `waiveReversal`; the 3547 refusal; the `reversal_notes` write; web-ui; `pages/cancellation.vue`; the plain-422 waivable rule.

## 7. Testing

### 7.1 API: acceptance criteria mapped to tests

> **As built (2026-10-12) — test homes that differ from the table below** (reviewed: verifier + code review, both accepted):
> - Destination service tests live in a sibling class `CancellationReversalServiceDestinationUnitTest` (same fixtures, real validator), not inside the 2,200-line `CancellationReversalServiceUnitTest`.
> - AC-8e (typed 422 / untyped control) is in `MobileEndpointExceptionHandlerUnitTest` through MockMvc advice resolution, not `RestExceptionHandlerUnitTest`.
> - AC-10's T11b pin and AC-21's annotation-`equals` pin are in `RtsDestinationContractUnitTest` (the TDD-gate reflection contract).
> - AC-13 is covered twice: a unit test (kills a pre-validate-only mutant) and `CancellationReversalDestinationIntegrationTest.withDestination_parcelSource_refused` on the real projection — which is an OUTCOME pin: with the pre-validate guard removed, `transferStock`'s own parcel guard still refuses with the same key (defence in depth, measured by mutant).
> - AC-2 also has a drained-TOTE case (`toLane_drainedTote_goesToEmptyTotes`); AC-3's full-move lock 0 is asserted inside the AC-2 tote test.
> - Added beyond the plan: fail closed with NO authenticated principal (security review L1 — the `getAuthorizedName()` fallback is the ANONYMOUS sentinel, a real user row on some tenants), and refusal of control characters in the scan (security review L2, CWE-117).

**Test classes:**
- `CRSUT` = `CancellationReversalServiceUnitTest`, built with a **real** `RtsDestinationValidator` over mocks.
- `RDVUT` = new `RtsDestinationValidatorUnitTest`.
- `CRDIT` = new `CancellationReversalDestinationIntegrationTest` **`extends BaseRollbackIntegrationTest` (H2)**, like its siblings `…LockClearIntegrationTest` and `…ParcelSourceIntegrationTest`. It runs on H2 and asserts by id or aggregate, never by global counts (shared-H2 note).
- The **migration IT stays on PG**: `CancellationRtsDestinationMigrationIT` copies `CancellationWaiveMigrationIT`, a standalone Testcontainers `PostgreSQLContainer` plus Flyway.

**Refusal-test fixture rule (Critic M3):** every refusal test stubs `findPendingReversalsForUpdateByCustomerorderId` with **one movable pending row** (lock 100, source set), so that `never()` on the finder and on `transferStock` has teeth. Assert the exception **class**, plus `getKey()` (keyed form) or the **exact** message.

| AC | Observable criterion | Test |
|---|---|---|
| 1 | No destination: `transferStock` gets `pickfromlocationname`; notes are written as sent; `verify(log, never()).setReversalDestinationLocation(any())` on the stubbed row | `CRSUT.noDestination_usesSourceBin_neverWritesDestination` (captor) |
| 2 | Tote → lane (new-container arm): stock is on a new UL at the lane; the tote is at EmptyTotes; the row is closed | `CRDIT.toLane_tote_newContainer_landsOnLane_rowClosed` + `CRSUT.destination_passesLaneNameToTransferStock` (captor) |
| 2c | Single-SU **Case** → lane (whole-container arm): the stock is on the **original** UL, now at the lane; SU and UL locks are 0; no new UL; the row is closed | `CRDIT.toLane_singleSuCase_relocatesContainerWhole_lockZero` |
| 3 | Lock 0 at the destination: full move and split (split: `reservedamount` 0) | `CRDIT.toLane_fullMove_lockZero`, `…_split_lockZero_reservedZero` |
| 4 | On-hand per SKU unchanged | `CRDIT.toLane_onHandPerSkuUnchanged` |
| 5 | OMS notice once, on the last position | `CRDIT.toLane_twoPositions_oneOutboxRowForOrder` + `CRSUT.destination_enqueueOnlyWhenClosed` |
| 6 | Non-lane refused: `RequestRefusedException` with the exact text; finder `never()`; no `logRepository.save`; no stamp; no `transferStock`. IT: row still pending, stock unit's UL unchanged | `RDVUT.notStagingLane_refused`, `…nullStaginglane_refused`; `CRSUT.invalidDestination_refusedBeforeForUpdateRead`; `CRDIT.toNonStagingLocation_refused_rowStillPending` |
| 7 | Each refused with the exact text or key: unknown (`getKey()==MSG_TRANSFER_DESTINATION_LOCATION_NOT_FOUND`), blank after trim, locked lane, null lock, flow bin, missing type | `RDVUT.unknown_…`, `…blankAfterTrim_…`, `…lockedLane_…`, `…nullLock_…`, `…flowBin_…`, `…missingType_…` |
| 7b | Null source with a valid destination: still the "no source location was recorded" refusal | `CRSUT.nullPickfrom_withValidDestination_stillRefused` |
| 7c | Lane locked after request 1: request 2 gets the typed refusal before the FOR UPDATE read; position 1 stays closed | `CRDIT.laneLockedBetweenRequests_secondRequestRefusedTyped_firstStaysClosed` |
| 8 | Gate only with a destination. Without the function: `FunctionAccessDeniedException` and finder `never()`. No destination: `accessService` never called | `CRSUT.destinationWithoutFunction_denied_beforeForUpdateRead`, `CRSUT.noDestination_neverChecksFunction` |
| 8b | Gate judges `getAuthorizedName()`. JWT with `getName()`="alice" and no `preferred_username` (`sub` = UUID). Stub **exactly** `checkAnyAccess(eq("alice"), eq(FN))`: one matcher per varargs element, no `anyString()`. STRICT_STUBS (default) fails any other argument | `RDVUT.gate_usesAuthorizedName_notSub` |
| 8c | Holding the waive function does not grant this one | `RDVUT.holdsWaiveOnly_denied` |
| 8d | Typed 403: status 403; header `X-Authz-Denied: MOBILE_UI_ACTION_RTS_CHOOSE_DESTINATION`; root `reason`=`MISSING_FUNCTION` and `requiredFunction`; `wms2.authz.denied{function=…,reason=missing_function}` = 1 | `MobileEndpointExceptionHandlerUnitTest.functionAccessDenied_writesInterceptorContract` **through MockMvc**: new `ThrowingController` route `/test/function-denied` throwing `FunctionAccessDeniedException`; `TestableMobileEndpointExceptionHandler` gains a `(new ObjectMapper(), new SimpleMeterRegistry())` constructor; advice set `(new RestExceptionHandler(), testable)`. This sees advice resolution (`RestExceptionHandler` order 0 has no match; depth comparator beats `rethrowAccessDenied`; `HandlerMethod` argument resolves). Existing `FunctionGuardInterceptorUnitTest` + `ReplenishOrderControllerGateH2Test` green **unchanged** — the `deny()` extraction is a pure move |
| 8e | Typed 422: `RequestRefusedException` → 422, `getType()` = `urn:wms2:problem:request-refused`, `detail` = message; serialised with a bare `new ObjectMapper()` + NON_NULL, `"type"` is at the **root**. A plain `BusinessException` still gets `about:blank` | `RestExceptionHandlerUnitTest.requestRefused_typed422`, `…plainBusiness_untyped` |
| 9 | Controller: the 4-arg form receives the bound destination; absent → null | `OrderCancellationControllerUnitTest.complete_bindsDestination`, `…absentDestination_isNull` |
| 10 | Plain RTS keeps its gate: VIEW-only user reaches `/complete`; no method `@RequiresFunction`; GOLDEN_MAP unchanged | existing T11 + `FunctionGuardMockMvcUnitTest.T11b_completeHasNoMethodLevelGate`; `FunctionGuardArchTest` unchanged |
| 11 | Provisioned three ways: constant; V2.2.38 grants exactly {outbound-manager, super-admin}, is safe to run twice, ALTER precedes the inserts; initDB grants the same set, resolved by name; column nullable varchar(255) | `CancellationRtsDestinationMigrationIT`, `UtilRestControllerSeedUnitTest` new T, `UtilRestControllerUnitTest` grant row |
| 12 | SBDEV-3547 holds: Move Stock of a lock-100 unit to a lane is refused | `CRDIT.moveStock_lock100ToStagingLane_stillRefused` |
| 13 | SBDEV-3353 holds with a destination | `CancellationReversalParcelSourceIntegrationTest.withDestination_parcelSource_refused` |
| 14 | Shared SU: one of two positions to a lane re-locks only the tote residue at 100; lane stock at 0 | `CRDIT.sharedStockunit_residueRelocked100_laneStockZero` |
| 15 | Column written iff a destination is supplied (including when it equals the source); on the DTO; absent from JSON when null | `CRDIT.toLane_recordsDestinationColumn`, `…destinationEqualsSource_stillRecorded`; `CancellationLogEntryDtoSerializationTest.reversalDestinationLocation_serialised`, `…_nullOmitted` |
| 21 | Both overloads carry `@Transactional` and the two annotations are `equals` (manager, `rollbackFor`, propagation, readOnly) | `CancellationReversalServiceTransactionalContractTest` (reflection) |

**Mutation checks (floor; each must turn the named test red, then revert):**

| Id | Mutation | Killed by |
|---|---|---|
| M-a | Delete the gate | AC-8 |
| M-b | Swap the constant to WAIVE | AC-8c |
| M-c | Gate when `== null` | AC-8 `noDestination_neverChecksFunction` |
| M-d | Validate after the FOR UPDATE read | AC-8 / AC-6 `never()` (the finder is stubbed) |
| M-e | `getUserName` / `doesUserHaveAccess` | AC-8b |
| M-f | Drop the `staginglane` check | AC-6 |
| M-g | Pass `getPickfromlocationname()` unconditionally | **AC-2 only** (CRSUT captor + CRDIT) |
| M-h | Write the column as `dest == null ? log.getPickfromlocationname() : dest.getName()` | AC-1 (`never()`, an assertion, not an NPE) |
| M-i | Drop the lock check | AC-7 `lockedLane` |
| M-j | Treat a null lock as unlocked | AC-7 `nullLock` |
| M-k | Drop the flow-bin check | AC-7 `flowBin` |
| M-l | Drop blank-after-trim | AC-7 `blankAfterTrim` (would otherwise get the not-found key) |
| M-m | Throw a plain `AccessDeniedException` | AC-8 (`assertThrows(FunctionAccessDeniedException.class)`) |
| M-n | Drop the `X-Authz-Denied` header in the writer | AC-8d + interceptor tests |
| M-o | Map `RequestRefusedException` without `setType` | AC-8e |
| M-p | Remove `@Transactional` from either overload | AC-21 |
| M-q | Let the resolver's ambiguous-name `BusinessException` escape unwrapped | `RDVUT.ambiguousCaseSpelling_refusedTyped` |
| M-r | Drop the key-matched rethrow of `MSG_UNITLOAD_TYPE_NOT_PERMITTED_ON_LOCATION` | `CRSUT.destination_typeNotPermittedOnLane_rethrownTyped` |
| M-s | Widen the rethrow to every `BusinessException` | `CRSUT.destination_amountExceedsAvailable_staysUntyped` |
| M-t | Delete the new `@ExceptionHandler(FunctionAccessDeniedException)` | AC-8d (MockMvc gets the rethrow, not the typed body) |
| M-u | Remove the null-`typeId` guard | `RDVUT.nullTypeId_refused` (`IllegalArgumentException` instead of the typed refusal) |

**Blind spots:**
- Annotation arch tests cannot see the programmatic gate. AC-8, AC-8b, AC-8c and AC-8d are its guards.
- No unit test exercises the literal Spring Security filter chain or a cross-origin header read: AC-8d uses `standaloneSetup` MockMvc, which has no filter chain. Manual row M3 covers the live wire.
- OMS inventory treatment of lane stock is manual (M6).
- The in-request lane-lock race (§3.2.2) is accepted and untested.

**Verify script: none.** Method: each invariant is mapped to a JUnit or Jest test above. The exceptions are manual rows M3 (live 403 through the filter chain and CORS), M6 (OMS inventory) and the per-tenant Flyway check (§8 step 2), whose evidence is a query, not a script.

### 7.2 Mobile: Jest

| AC | Criterion | Test |
|---|---|---|
| 16 | Without the function: scan field hidden; payload deep-equals `{ notes, positionIds }` (no key) | component "hides scan without function"; store "omits key when undefined/blank" |
| 17 | With a destination: every per-position POST carries the same `destinationLocationName` | store "sends destination on every position" |
| 17b | Typed 403 (`reason`, header) on request 1: 1 POST total, `waivable` `{}` | store "typed 403 stops the loop" |
| 19 | **H1:** 422 with `type=urn:wms2:problem:request-refused` on request 1: 1 POST total; `waivable` and `refusals` both `{}`; returns `{ requestRefusal: detail }`; the component shows it under the scan field | store "request-level refusal breaks, no waivable"; component "shows destination error" |
| 19b | Plain 422 (no `type`): still marks that position waivable and continues (3548 regression guard) | store "plain 422 still waivable" |
| 19c | Request 1 OK, request 2 typed 422: no request 3; position 1 counted completed; "1 of 3 reversed" aggregate; `waivable` `{}` | store "lane locked mid-loop" |
| 20 | Order A with a lane, then order B (remount, or a `customerorderId` change) → B's payload has no `destinationLocationName`; the store holds no destination state | component "order A lane not carried to order B"; store "destination is an argument, not state" |

Existing `cancellationPartialReversal`, `cancellationWaive`, `cancellationErrorSurface` and `cancellation-waive` specs stay green and unchanged. **As built (2026-10-12):** one exception — `cancellationPartialReversal.spec.js` "does not throw when $toast has no handle" now expects `{ requestRefusal: null }` instead of `undefined`, because §3.5 makes `completeSelectedPositions` resolve to `{ requestRefusal }` on every exit; the test's point (no throw) is kept and the assertion is stricter. **The new specs must not `jest.mock('~/util/apiError')`** — `isRequestRefusal` is the layer under test. AC-19 also asserts: no `toastError` call for the typed refusal, and `requestRefusal` is still returned when the post-loop `fetchDetail` fails.

Mutants:
- drop the `requestRefused` break → AC-19 red;
- set `waivable` for request-level refusals → AC-19 red;
- treat every 422 as request-level → AC-19b red;
- always send the key → AC-16 red;
- read `canWaive` instead → AC-16 red;
- move the destination into Vuex without clearing it → AC-20 red.

### 7.3 Manual test plan

| # | Scenario | Env | Steps | Expected | Pass/Fail |
|---|---|---|---|---|---|
| M1 | Happy path, tote | wineco dev | outbound-manager: cancel a picked order, open RTS, scan `StagingLane0x`, Complete | new UL at the lane, lock 0; tote at EmptyTotes; column set; one OMS notice | |
| M1c | Happy path, Case | wineco dev | as M1 with a single-SU Case pick | Case UL itself now at the lane, lock 0; no new UL | |
| M2 | Plain RTS, VIEW-only | dev | no new function; Complete | no scan field; source bin; column null | |
| M3 | Typed 403 on the wire | dev | curl `/complete` with a destination as a VIEW-only user; also through the handheld | 403, `X-Authz-Denied: MOBILE_UI_ACTION_RTS_CHOOSE_DESTINATION`, root `reason: MISSING_FUNCTION`; handheld shows the axios typed denial toast once, no retry; WARN line; nothing moved | |
| M4 | Non-lane / locked lane | dev | scan `PutAwayLane`; lock a lane and scan it; lock a lane between positions 1 and 2 | 422 `type=…request-refused`, message under the scan field, **no Waive buttons**, loop stops; row(s) pending | |
| M5 | Club consumption | dev | Complete to a lane with an open batch for the SKU | stock available to the batch (D1) | |
| M6 | Inventory (F5) | dev + OMS dev | `stock_view` and OMS inventory before/after M1 | totals unchanged. **Unverified in code** | |
| M7 | Migration | dev DB | `SELECT f.name, r.name FROM mywms_function f JOIN mywms_role_mywms_function x ON x.functionlist_id=f.id JOIN mywms_role r ON r.id=x.rolelist_id WHERE f.name='MOBILE_UI_ACTION_RTS_CHOOSE_DESTINATION'`; `\d customerorder_cancellation_log` | exactly 2 rows (`outbound-manager`, `super-admin`); nullable varchar(255) | |

### 7.4 Horizontal scalability

| # | Concern | Verdict | Rationale |
|---|---|---|---|
| 1 | In-JVM state | No | stateless validator; static writer; uncached repository read |
| 2 | Connection pool | No | about 3 extra reads in the existing transaction |
| 3 | Scheduled jobs | No | — |
| 4 | Long transactions | No | indexed reads before the lock |
| 5 | Request affinity | No | — |
| 6 | Retry / idempotency | Yes, unchanged | completed rows skipped; a replay re-sends the OMS notice by design |
| 7 | Tenant context | No | synchronous |
| 8 | Locks | Yes | New-container arm: the lane location is locked last in `transferStockToUnitLoad`'s order. Whole-container arm: lock order identical to today's source-bin route; only the target location row differs (§2 B4). Complete and waive still serialise on the order |
| 9 | Cache invalidation | No | Location not written by new code (F9) |
| 10 | External notifications | Unchanged | outbox |

### 7.5 v2 constraints

| # | Constraint | Verdict |
|---|---|---|
| 1 | OSIV off | Yes: all reads are inside the transaction |
| 2 | `tenantTransactionManager` | Yes: **identical annotation on both overloads** (AC-21) |
| 3 | readOnly | N/A |
| 4 | Cache eviction | N/A (F9) |
| 5 | Metrics | the existing `wms2.authz.denied` counter on denial; INFO on success |
| 6 | Jakarta | Yes: `org.springframework.security.access.AccessDeniedException` |
| 7 | H2 vs PG | CRDIT runs on **H2** (`BaseRollbackIntegrationTest`, same as its siblings); the migration IT runs on **PG** Testcontainers |
| 8 | Controller test | `OrderCancellationControllerUnitTest` (`BaseControllerUnitTest`) |

## 8. Rollout
1. Phase 1 PR into `develop`. The merge deploys to dev and runs V2.2.38.
2. **Per-tenant migration gate (Architect M4, Critic M6):** before Phase 2 merges, and again after each devops promotion, run `SELECT version, success FROM flyway_schema_history WHERE version='2.2.38'` on **every v2 tenant DB** of that environment. Enumerate the tenants from landlord; read-only MCP or psql. Every DB must return exactly one row with `success=true`. Any miss or failure means **stop**: that tenant's cancellation is broken (§6). Fix the migration or roll the API back.
3. M7 on dev, then M1–M6.
4. Phase 2 PR into `develop` only after the dev API carries the build. Check the `actuator/info` build time and watch for the `:develop` tag race.
5. UAT and PRD promotion is done by devops, in the same order: **API first, mobile second**, with step 2 repeated per environment.

**Rollback:**
- Revert **mobile first**.
- If the API alone must be reverted while new mobile stays: delete the new function's grants on each tenant first (`DELETE FROM mywms_role_mywms_function WHERE functionlist_id=(SELECT id FROM mywms_function WHERE name='MOBILE_UI_ACTION_RTS_CHOOSE_DESTINATION')`), **then have operators return to Home** (or reload).
  - `home.functions` is not persisted (`stripAuthzState`, `persistedState.client.js:~40-63`). It is re-fetched when Home mounts (`pages/index.vue` → `redirectPage` → `home/setMenus` → `setFunctions`), and both `refreshMenus` and the action screen's `goBack()` route to Home.
  - Until then, a handheld can still show the scan field. An old API ignores the field (source bin), so the operator must be told.
- The column is harmless if left in place (`ddl-auto=none`; the old entity does not map it). An applied V2.2.38 on a reverted build is ignored as `*:future`.

## 9. Alternatives

| Option | Why rejected |
|---|---|
| Move Stock takes lock-100 stock and closes the rows | Breaks SBDEV-3547's two-exit rule and the PO→SU lock-order rule |
| Separate `/complete-to-location` with method `@RequiresFunction` (G3) | Contradicts D1's single request shape. Its real advantages (typed 403, arch-test visibility) are recovered by §3.2.1; the arch-test gap is covered by AC-8..8d. Kept as a fallback |
| Gate in the controller (G2) | The gate must bind **any caller that supplies an operator-chosen destination** to the 4-arg service method (e.g. a future web screen), not only the mobile controller. The 3733 system-chosen fallback deliberately bypasses it through `resolveDestinationName` and never goes through the validator |
| Gate via `BusinessException` (G4) | 422: the loop does not stop and rows are marked waivable |
| Destination refusals as a plain 422 | Same H1 hazard: N POSTs, N Waive buttons (SBDEV-3548 fence) |
| Pre-flight validate endpoint before the loop | A new route and a new gate; still needs the typed in-loop refusal for mid-loop locks |
| Typed refusal through a `ProblemDetail` property (e.g. `code`) | Nests at `$.properties.code` in production but is flattened by `standaloneSetup`, so the unit lane would assert a shape production never sends. `type` is a root field on both |
| Inline validation (17 constructor args) | §3.2: the collaborator is smaller and matches the 3733 seam |
| Any location as destination | Opens flow-bin assignment, rack constraints, Damaged, Nirwana and Shipped |
| Record in `reversal_notes` (R1) | `initiateReversal` rewrites notes; D5 chose a column |
| Translate the downstream "Destination location=… is locked" into the typed refusal | Matches message text; the in-request race it closes is sub-transaction and bounded (§3.2.2) |

## 10. Resolved decisions and open questions

**Resolved (Nam, 2026-10-12; do not reopen):**
- **D1:** optional destination on Complete. Stock lands at lock 0, not reserved; club packing may consume it.
- **D2:** staging lanes only. Locked lanes and flow-bin types are refused.
- **D3:** new function `MOBILE_UI_ACTION_RTS_CHOOSE_DESTINATION` for outbound-manager and super-admin. Plain RTS keeps the class gate. In-service programmatic check, 403, only with a destination, before the FOR UPDATE read. Three touches.
- **D4:** one destination per submission.
- **D5:** new nullable column `reversal_destination_location` in the same migration, mapped and on the DTO, written only when supplied.
- **Out of scope:** re-create detection and reservation (SBDEV-3733). The seam is kept: `resolveDestinationName` plus `RtsDestinationValidator`.
- **Settled:** unknown JSON fields are ignored. Mitigated by function-gated UI and API-first deploy (AC-16).

**Planner positions:**
- F3: keep refusing (after destination validation).
- F7: one UL per position on the new-container arm; the whole container moves on the Case/Default arm.
- F9: uncached repository.
- F10: `getAuthorizedName` + `checkAnyAccess`.
- F5: `stock_view` unchanged; OMS goes to M6.
- F6: 13 of 37 rows in scope; SBDEV-3740 covers the other 24.
- Request-level refusals are typed (§3.2.2).
- The gate denial uses the interceptor contract (§3.2.1).

**Open:**
- [ ] Final Flyway number: re-sweep at gate time.
- [ ] P1: lane shape (including Case admissibility) on every v2 tenant DB.
- [ ] M6: if OMS treats lane stock differently, escalate (mid-flight trigger 1).
- [x] A13 `step6` audit row — **deferred** (implementation, 2026-10-12): `audit-access-invariants.sql` is not in the wms2-api repo; add the row wherever that audit lives. Not a code-path gap.
- [x] Case row `pos 35841889` (amount_picked 2 > available 1): **not an anomaly** (re-queried 2026-10-13). Both picked units were hand-moved to StagingLane05 (UL357085), and 1 was club-packed for CLUB-20261002-002 eleven seconds later. Covered by SBDEV-3740 (T-0042 Waive, comment 90110278758002). No ticket.

**Review history:**
- Round 1 (2026-10-12): Architect **SOUND-WITH-FIXES** (M1–M5, L1–L6); Critic **ITERATE** (H1, M1–M6, L1–L8, 2 open questions).
- Round 2 (2026-10-12): [disposition of round-1 findings](SBDEV-3741-evidence/disposition-r2.md). Architect **SOUND-WITH-FIXES** ([review](SBDEV-3741-evidence/review-architect-r2.md): M-1, L-1…L-7); Critic **APPROVE** ([review](SBDEV-3741-evidence/review-critic-r2.md): M1–M3, L1–L5).
- Round-2 synthesis (orchestrator, same day), applied in this file: typed wrap of the ambiguous-name refusal + validator invariant (Arch M-1 / Critic M1); key-matched typing of `MSG_UNITLOAD_TYPE_NOT_PERMITTED_ON_LOCATION` (Critic M2); AC-8d via MockMvc and M-m re-attributed (Arch L-1 / Critic M3); null-`typeId` guard (Critic L2); async `complete()` + returns on every exit + single message (Arch L-2/L-3, Critic L3/L4); no-mock rule for `apiError` (Critic L5); rollback wording (Critic L1); §0 rows A37–A38, writer details (Arch L-4…L-7). Mutants M-q…M-u added.


## 11. Implementation status (2026-10-12)

**PRs (merge in this order):**
1. [SiteBossInc/wms2-api#507](https://github.com/SiteBossInc/wms2-api/pull/507): branch `feature/SBDEV-3741-rts-choose-destination`, 12 commits, `b89ca23b` (TDD gate) → `9c606c3a`.
2. [SiteBossInc/wms2-mobile-ui#87](https://github.com/SiteBossInc/wms2-mobile-ui/pull/87): same branch name, 8 commits, `07a5328` (TDD gate) → `c5ad5f9`. Merge only after #507 is on dev **and** `V2.2.38` shows `success=true` on every tenant DB.

**Phase 1, API:**

| Measure | Result |
|---|---|
| Full `mvn clean verify -Pci` at `9c606c3a` | unit 8236 run / 0 fail; IT 842 / 0 |
| Develop baseline | unit 8175 / 0; IT 831 / 0 |
| PIT on new/changed lines | 42 / 42 killed |
| Hand mutants | all killed by the named test |

- Verifier: PASS.
- Code review: APPROVE. Security: PASS.
- Three scoped re-reviews: APPROVE. `9c606c3a` (test-only) was not separately reviewed.

**Phase 2, mobile:**

| Measure | Result |
|---|---|
| Jest | 43 suites / 611 tests / 0 fail |
| Develop baseline | 41 / 575 / 0 |
| Hand mutants | all killed, including real-ScanInput keydown-driven tests |

- Verifier: PASS.
- Code review: REQUEST CHANGES (1 High), all fixed. Three scoped re-reviews: APPROVE. `c5ad5f9` (comments plus one test) was not separately reviewed.

**Landmines found during implementation (not predicted by the plan):**
- **The mobile scan field appends every scan to the last one.** `ScanInput` copies `value` into its buffer once, and in scanner mode its Enter keeps the text there. So clearing the v-model does nothing, and every scan is appended. Fixed with a `:key` remount after each completed scan (scanner mode only) and on clear.
- **ScanInput emits the literal event name `keyup.enter`.** Vue's `@keyup.enter` shorthand never matches it, so the listener needs the object form of `v-on`. Every other screen using `@keyup.enter` on `scan-input` receives Enter only through the native soft-keyboard path. That may deserve its own look.
- **In scanner mode, ScanInput captures every window keydown.** A second text input on the same screen (here, the Waive reason) is unusable while it is mounted.
- **`getAuthorizedName()` falls back to the ANONYMOUS sentinel,** a real user row on some tenants. An in-service gate must read `authentication.getName()` and fail closed.
- **Two repo rails tripped:**
  - `NameKeyedGrantSeedRailTest` needs an allow-list entry for any name-keyed grant migration.
  - `NeverMatcherNullBlindnessArchTest` rejects `anyLong()` in a `never()` on a boxed `Long`.
- **A hand mutation harness that restores files with `git checkout` reverts uncommitted work.** Commit before running it. This is now in memory under `mutation-harness-traps`.

**Deliberately skipped:** A13 audit row (deferred, see §10). No verify script (none planned).

**Not done (by design):** merge, `on dev`, the per-tenant Flyway check, archiving this plan, worktree removal. Worktrees: `.claude/worktrees/wms2-api/SBDEV-3741` and `.claude/worktrees/wms2-mobile-ui/SBDEV-3741` (its `node_modules` is a symlink to the main checkout).

**Merged and on dev (2026-10-13):**
- **API:** #507 merged as `11468c4a`; its develop run (`test` then `build`) passed.
- **Migration:** V2.2.38 applied on `dev_wh01_om1`, the only active dev tenant. `flyway_schema_history` shows success=true at 14:02:31 UTC. The new column and the function (granted to outbound-manager and super-admin) are present; all three were absent before the deploy.
- **Mobile:** #87 merged as `36368b6`, after that check. Image CI and Layout Tests passed.
- **Still open:** manual tests M1–M7 on dev, the per-environment V2.2.38 check before UAT/PRD, and `archive-plan` once the ticket closes.
