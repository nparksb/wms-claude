**Mode:** SHORT (T3, one ralplan round; this is the round-2 revision). Not DELIBERATE: there is no `--deliberate` flag, and the only irreversible piece, the migration, is additive and idempotent. Its main operational risk, an unmigrated tenant, now has an explicit per-tenant gate (§8 step 2).

**Principles**
1. A body without the field behaves exactly as today: same code path, same tests, same GOLDEN_MAP, byte-identical detail JSON.
2. Lock 100 keeps exactly two exits (complete and waive). The new capability lives inside "complete", never in Move Stock.
3. Authz checks one principal everywhere: interceptor, gate and `completed_by` all use `authentication.getName()`.
4. Refuse early, loudly, **and at the right level**. Destination refusals and the gate denial are request-level and typed: the mobile loop stops and marks nothing waivable. Position refusals keep the SBDEV-3548 waivable path.
5. Minimal surface, one contract: no new endpoint and no new movement code. The gate denial reuses the interceptor's exact wire contract, and the 422 reuses the existing ProblemDetail handler with only its standard `type` field set.

**Decision drivers (top 3)**
1. Who can do plain RTS must not change: a class gate with 46 WineCo holders, which a method annotation would replace.
2. Failure-shape safety on the handheld: a mis-scan or a denial must not fan out into N requests and N Waive buttons (H1), or into an untyped 403 that retries and shows an opaque message (Architect M1).
3. Version-skew and tenant-migration safety: a dropped field or an unapplied column must not silently misroute stock or break cancellation.

**Viable options**

| Option | Pros | Cons |
|---|---|---|
| **A′: optional field on `/complete` + `RtsDestinationValidator` (in-service gate) + typed refusals (interceptor-contract 403, `type`-tagged 422)**, chosen | Class gate untouched. Binds any caller that supplies an operator destination. One request shape (D1). Handheld behaviour matches an annotated gate. Request-level refusals stop the loop without marking waivable | About 5 new small types (validator, 2 exceptions, writer, handler). The gate is invisible to annotation arch tests and is guarded by AC-8..8d plus mutants M-a..M-e and M-m..M-n. Residual in-request lane-lock race accepted |
| B: optional field + controller-level check (G2) + same typed refusals | Smaller service change | A future service caller supplying an operator destination bypasses the gate; validation splits across layers |
| C: separate `/complete-to-location` with method `@RequiresFunction` (G3) | Typed 403 and arch-test visibility for free | Contradicts D1's single request shape (not open). The mobile client would need two submit paths. The H1 typed 422 is still needed |

Invalidated:
- **D, Move Stock closes rows:** breaks 3547 and PO→SU lock order.
- **E, `BusinessException` gate (G4) or plain-422 destination refusals:** H1 fan-out plus waivable marking.
- **F, pre-flight validate endpoint:** a new route and gate, and it still cannot catch a mid-loop lock.

**ADR**
- **Decision:**
  - Add optional `destinationLocationName` to `POST /cancellation/{coId}/complete`.
  - The controller calls a 4-arg `completeReversal`. Both overloads carry the identical `@Transactional(tenantTransactionManager, rollbackFor={BusinessException, FacadeException})`.
  - Before the FOR UPDATE read, `RtsDestinationValidator` runs in order:
    - `checkAnyAccess(getAuthorizedName(), MOBILE_UI_ACTION_RTS_CHOOSE_DESTINATION)`; a denial throws `FunctionAccessDeniedException`, which `MobileEndpointExceptionHandler` renders through the shared static `AuthzDenialWriter` (403, `X-Authz-Denied`, root `reason`/`requiredFunction`, `wms2.authz.denied`, WARN);
    - blank, unknown, not a staging lane, lock ≠ 0 or null, flow bin or missing type, each a `RequestRefusedException` (422 ProblemDetail `type=urn:wms2:problem:request-refused`).
  - The resolved name flows through `resolveDestinationName` into the unchanged `transferStock`. That reaches the new-container arm (Tote: one new lock-0 UL per position) or the whole-container arm (single-SU Case/Default: the container moves).
  - The destination is recorded in a nullable `reversal_destination_location`. V2.2.38 runs the ALTER first, then seeds the function and grants it to outbound-manager and super-admin. initDB grants the same set.
  - Mobile keeps the destination as component-local data passed as an argument. The scan field is shown only to function holders. A typed 422 or a 403 breaks the loop with no waivable rows.
- **Drivers:** plain-RTS gate unchanged; handheld failure-shape safety; skew and tenant-migration safety.
- **Alternatives considered:**
  - G2 controller gate;
  - G3 separate route;
  - G4 422 gate;
  - plain-422 destination refusals;
  - pre-flight validate endpoint;
  - typed refusal through a ProblemDetail property;
  - inline validation with 17 constructor arguments;
  - translating the downstream lock message;
  - Move Stock closing rows;
  - any location as destination;
  - notes token (R1).
- **Why chosen:**
  - It is the only option that keeps the class gate and D1's request shape, binds every caller that supplies an operator destination, and gives the handheld the same denial behaviour as an annotated gate.
  - It reuses the existing ProblemDetail and interceptor mechanisms. The only new wire element is the standard `type` field, which is visible at the root in production and in both test lanes.
- **Consequences:**
  - one new UL per position on the Tote arm; a whole container moves on the Case/Default arm;
  - lane stock at lock 0 is consumable by club batches (accepted);
  - the gate is invisible to annotation arch tests, so AC-8..8d and mutants carry it;
  - `FunctionGuardInterceptor.deny()` now delegates to a shared writer, a refactor pinned by the existing interceptor tests;
  - an unmigrated tenant breaks order cancellation on that tenant, so §8 step 2 is mandatory per environment;
  - rollback must revert mobile first, or delete the grants and reload the handhelds;
  - an in-request lane-lock race can still mark one row waivable (accepted, bounded);
  - 24 of 37 WineCo PRD rows are not helped; SBDEV-3740 covers them.
- **Follow-ups:**
  - SBDEV-3733 fallback via `resolveDestinationName`, bypassing the validator by design;
  - container consolidation only if proliferation is observed;
  - M6 OMS inventory treatment;
  - P1 lane census, including Case admissibility, on every v2 tenant;
  - Flyway number re-sweep at gate time;
  - propose a finding for Case row `pos 35841889` (amount_picked > available);
  - consider mapping `FacadeException("STORAGELOCATION_LOCKED")` on the mobile path, which currently renders as a 500 (pre-existing, outside 3741).
