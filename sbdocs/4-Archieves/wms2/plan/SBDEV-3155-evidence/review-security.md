# SBDEV-3155 — independent security review

Lane: `sec3155`. Date: 2026-09-01. Worktree read-only; **no maven was run there, no git mutation.**
Instruments: source read on `.claude/worktrees/wms2-api/SBDEV-3155` (HEAD `ad681319`), `git grep` against
`origin/develop` of `wms2-web-ui` (`3117aca`, 3h old), `wms2-mobile-ui` (`c79e81c`, 28h old),
`oms-laravel-api` (`809e1eb3`, 63min old), and live SQL on `wms2-wineco-dev` + `wms2-hydra` (PRD).

Verdict up front: **the gate is genuinely reachable — the annotations are not inert.** But **four of the
ten routes have a live, ungated, equivalent write route that the product itself uses**, so for the
Transfers lane operations the change is defence-in-depth, not closure. Two more findings are about the
change's own evidence (a measurement that does not reconcile, and a rationale that is false for one row),
and there is no behavioural denial test at all, which departs from the precedent set on these exact
controllers by SBDEV-3142.

---

## Q1 — Is the gate actually reachable for these three controllers? YES.

Chain, each link read from source:

1. `src/main/java/net/aim_ai/wms/WebConfig.java` registers the guard as a bean over **every** path:
   `return new MappedInterceptor(new String[] {"/**"}, functionGuardInterceptor);`
   Declared return type is `MappedInterceptor`, which is what `detectMappedInterceptors` needs.
2. All three controllers are `@RestController` with a `/v3/...` class mapping
   (`ClubLineController` `@RequestMapping("/v3/clubLine")`, `TransfersController` `"/v3/transfers"`,
   `PickingOrderPositionController` `"/v3/pickingOrderPosition"`), so they register on
   `requestMappingHandlerMapping`, which picks the bean up.
3. `FunctionGuardInterceptor.preHandle` resolves method-level `@RequiresFunction` first
   (`RequiresFunction methodLevel = handlerMethod.getMethodAnnotation(RequiresFunction.class);`), before
   any class-level fallback and before the `GUARDED`-set logic. None of the three classes is in `GUARDED`,
   but that only matters for the *unannotated* fall-through path — an annotated method is checked
   regardless of set membership.
4. `RequiresFunction` is `@Target({TYPE, METHOD})` + `@Retention(RUNTIME)`, so reflection sees it.
5. `SecurityConfiguration.java:178` — `.requestMatchers("/v3/**", "/putawayConfig/**").hasAnyAuthority(Authority.WMS_USER_ROLE)`.
   None of the three prefixes appears in the `permitAll()` list at `:150-154`. So the filter chain admits
   an authenticated `wms_user` and the interceptor then applies the function check.
6. No `@PreAuthorize` / `@Secured` / `@RolesAllowed` / `@DenyAll` anywhere on the three classes (grepped
   all four annotations across all three files — zero hits), so there is no second gate to interact with.
7. All three declare the ten handlers themselves, so `getMethod().getDeclaringClass()` is the concrete
   controller and there is no `AdminController` alias-URL ambiguity for these routes.

Nothing makes the annotation inert. The `activeBatch`-method/`/activateBatch`-path mismatch is harmless:
the annotation is on the method, and the pin keys on the path, which is the right call.

---

## Q2 — Equivalent open routes, per endpoint

Method used, for each of the ten: (a) find the service method the handler calls; (b) `grep -rn` every
caller of that service method in `src/main`; (c) identify the entity + columns actually written;
(d) check whether that entity's SDR surface withdraws the write verbs in `RestConfiguration.SDR_WRITE_WITHDRAWN`;
(e) `git grep` `origin/develop` of both UIs and `oms-laravel-api` for another caller; (f) grep `@Scheduled`
classes for the same service methods; (g) grep the `permitAll` `/rest/**` controllers.

### 🔴 FINDING S1 (High) — `PATCH /v3/customerorder/{id}` is a live equivalent for four of the ten

**Affects:** `assignTransferLane`, `reassignTransferLane`, `unlinkTransferLane`, `activateTransferOrder`.

All four reduce to two setters and a save on the same entity. `TransferOrderService.java`:

```java
customerOrder.setTransferlaneId(transferLane.getId());
customerOrder.setState(CUSTOMER_ORDER_TRANSFER_LANE_ASSIGNED);
customerorderRepository.save(customerOrder);
```

(`unlink` sets `null` + `CUSTOMER_ORDER_ACTIVATED`; `activateAndAssignTransferLane` sets the same pair.)

`Customerorder` is SDR-exported with the write verbs **intact**:

- `CustomerorderRepository.java:22-23` —
  `@RepositoryRestResource(collectionResourceRel = "customerorder", path = "customerorder")`
  over `PagingAndSortingRepository<Customerorder, Long>, CrudRepository<Customerorder, Long>`.
  `CrudMethodsSupportedHttpMethods` therefore publishes ITEM `PUT`/`PATCH`/`DELETE`.
- `RestConfiguration.SDR_WRITE_WITHDRAWN` does **not** contain `Customerorder` — and that is deliberate,
  its own javadoc says so: *"⚠ **NOT in this list, deliberately:** the ELEVEN resources with a live UI
  writer at their SDR path — `advice`, `boxtype`, `client`, **`customerorder`**, `cyclecount`,
  `location`, …"*. (`CustomerorderBatch` and `PickingorderPosition` **are** in the list — see S2.)
- `Customerorder.java` — `@Column(name = "transferlane_id") private Long transferlaneId;` with a public
  `setTransferlaneId`, plus a public `setState`. No `@JsonIgnore`, no `@ReadOnlyProperty`.
- `SdrFunctionGuard.evaluate` short-circuits at the top: `if (mode == SdrGuardMode.OFF) { return SdrVerdict.allow(...); }`,
  and `SdrGuardModeProvider` defaults to `OFF`. Even at an enforcing mode, `Customerorder` is unruled
  (Slice 1 rules the eight authorization-graph types only) and unruled is allowed below `FAIL_CLOSED`.
  The guard is also verb-blind — nothing in `evaluate` reads the HTTP method.
- `/v3/**` needs only `wms_user` (`SecurityConfiguration:178`).

**This is not theoretical.** `wms2-web-ui` `store/common/order.js:15` on `origin/develop`:

```js
const result = await this.$axios.$patch(`/customerorder/${data.id}`, data)
```

So the product ships a caller for exactly this route, and it is reachable by any authenticated
`wms_user` holding **zero** functions.

**Failure scenario.** A warehouse user with `wms_user` and no `WEB_UI_VIEW_TRANSFER_ORDER` sends
`PATCH /v3/customerorder/814 {"transferlaneId": 4471, "state": 510}`. The transfer order is bound to a
lane, exactly as `assignTransferLane` would have done — with the gate returning 403 on the front door.

**It is strictly worse than the gated route, not merely equal.** The MVC handler runs
`locationRepository.getAvailableTransferLanesForUpdate(...)` under `PESSIMISTIC_WRITE` and throws
`"transfer lane is not available anymore"` when the lane is taken. The SDR PATCH runs none of that, so it
can bind a lane already held by another order — the 505-with-lane / lane-collision class of defect that
`activateAndAssignTransferLane`'s own comment (citing `260629-activate-transfer-atomicity`) exists to
prevent.

**Fix.** Not "add `Customerorder` to `SDR_WRITE_WITHDRAWN`" — that breaks `updateCustomerOrder`. Two
workable shapes, in preference order:

1. **Field-level:** annotate `Customerorder.transferlaneId` and `Customerorder.state` `@ReadOnlyProperty`
   so SDR ignores them on binding while the JPA writes from `TransferOrderService` still land. Verify
   `store/common/order.js`'s `updateCustomerOrder` does not send either field (its payload is the whole
   `data` object, so this needs an actual check of the caller's fields before shipping).
2. **Rule-level:** add a `SdrFunctionGuard` rule for `Customerorder` → `WEB_UI_VIEW_TRANSFER_ORDER` /
   `WEB_UI_VIEW_ORDER` (any-of), and note it only bites at `ENFORCE_RULED` or above, which no tenant is
   at today — so this alone does not close it now.

At minimum: the ticket must **state** this residual rather than ship "ten state-changing GETs are now
gated" with no qualifier. That is precisely the SBDEV-3142 failure the team lead cited.

### FINDING S2 (informational) — the other six have NO equivalent route. Stated plainly.

- `assignStagingLane`, `unlinkStagingLane`, `activateBatch` — mutate `CustomerorderBatch.staginglaneId` /
  `.state`. `net.aim_ai.wms.model.CustomerorderBatch.class` **is** in `SDR_WRITE_WITHDRAWN`, so
  `PUT/PATCH/POST/DELETE` are stripped from its collection, item and association resources. No SDR twin.
- `fixPickingPosition` — `net.aim_ai.wms.model.PickingorderPosition.class` **is** in
  `SDR_WRITE_WITHDRAWN`. No SDR twin. Its service method has exactly one other `src/main` caller,
  `MobilePickingService.java:478`, reached only through the mobile `PickingController`, which is in
  `FunctionGuardInterceptor.GUARDED` and gated on its own picking function — a different, already-closed
  door, not a residual.
- `runClubLine`, `runTransfer` — `CustomerorderBatchService.runClubLine` and
  `BillofladingService.transferOrder` each have **exactly one** `src/main` caller, the gated handler
  itself (`grep -rn "\.transferOrder("` → one hit, `TransfersController.java:252`).
- **Scheduled jobs:** zero. Every `@Scheduled`-bearing class was grepped for `runClubLine|transferOrder|
  activateOrderBatch|StagingLane|TransferLane` — no matches.
- **`/rest/**` (the `permitAll` surface):** the seven `/rest` controllers were grepped for
  `TransferLane|StagingLane|transferlane|staginglane|runClubLine|activateOrderBatch` — zero matches.
  `OrderRestController` has `/create`, `/updatePriority`, `/cancelPositions`, `/finishedQA`,
  `/finishedTransfer`; none touches `transferlane_id` or `staginglane_id`.
- **Another MVC controller:** `CustomerOrderBatchController` and `CustomerOrderController` were read in
  full for mappings — only priority/picking-date writes, all already gated, none touching lane binding
  or batch activation.
- **Mobile:** `wms2-mobile-ui` `origin/develop` has zero occurrences of `club`, `clubline`, `runclub`, or
  `/transfers/` anywhere under `store/ pages/ components/ plugins/`. The pin's claim that mobile talks to
  its own `/v3/transferOrder/*` controller is **correct** — `store/transferOrder.js` +
  `components/transferOrder/*` exist, and `controller/mobile/TransferOrderController` carries a
  **class-level** `@RequiresFunction(WEB_UI_VIEW_TRANSFER_ORDER)` at line 30, so that surface is already
  gated on the same function.

---

## Q3 — Is `WEB_UI_VIEW_*` the right axis?

**For the nine club/transfer routes: yes, and the strongest argument is one the ticket does not make.**
`wms2-web-ui` `util/appMenuList.js` on `origin/develop` already binds these screens to these exact
functions in its route guard (`middleware/require-function.js`):

```
{ text: 'Club',    to: '/outbound/club',            fn: 'WEB_UI_VIEW_CLUB_LINE' },
{ text: 'Transfer', to: '/outbound/transfer',        fn: 'WEB_UI_VIEW_TRANSFER_ORDER' },
{ text: 'Club Run', to: '/processes/club-run',       fn: 'WEB_UI_VIEW_CLUB_LINE' },
{ text: 'Transfer Picking', to: '/processes/transfer-picking', fn: 'WEB_UI_VIEW_TRANSFER_ORDER' },
'/outbound/club/open/:id':     'WEB_UI_VIEW_CLUB_LINE',
'/outbound/transfer/open/:id': 'WEB_UI_VIEW_TRANSFER_ORDER',
```

So the function is not merely "a view permission" in this estate — it is already the *entry credential
for the workspace in which these actions live*, and the server was simply failing to enforce what the
client had been asserting. Gating the actions on it makes server and client agree. The objection that a
view function should not authorize a state change is real in the abstract, but here the alternative —
minting `WEB_UI_ACTION_*` constants — costs a Flyway migration, an `initDB` grant line, and a
fail-closed window on every tenant provisioned between the two (see `wms2-adding-a-function-constant-needs-three-things`),
for an authorization boundary that would be granted to exactly the same population. Option B is right.

### 🔴 FINDING S3 (Medium) — the rationale is FALSE for `fixPickingPosition`

The pin comment asserts, of all ten: *"Each takes the function that ALREADY gates its screen."* For
`WEB_UI_VIEW_PICKING_POSITION` that is not true — **there is no screen**:

- `wms2-web-ui` `origin/develop`, whole-tree `git grep WEB_UI_VIEW_PICKING_POSITION` → **two hits, both in
  `test/support/webFunctionConstants.js`** (lines 56, 110). Zero in `util/appMenuList.js`, zero in
  `pages/`, `store/`, `components/`, `middleware/`.
- `wms2-mobile-ui` `origin/develop` → **zero hits.**
- `fixPickingPosition` itself has zero callers in either UI, in `oms-laravel-api`, or in any Cypress spec.
- Its only other `src/main` mention outside `WmsConstants` is `UtilRestController` (the tenant seeder),
  which is `@Service`, so its mappings do not route.

So this row is not "reuse the screen's function"; it is "pick a plausibly-named unused constant". The
consequence is a population chosen by accident. Measured on `wms2-wineco-dev`, the roles holding
`WEB_UI_VIEW_PICKING_POSITION` are `super-admin` (37 users), `outbound-manager` (10) and **`CS-REP` (4)**.
`fixPickingPosition` re-points a picking position at a different `Stockunit` and rewrites reservations
(`PickingorderPositionService.fixPickingPosition`, `@Transactional`, throws
`"No stock found on pickable location"` / `"not enough stock on single unit load found."`). Handing an
inventory-repair primitive to a customer-service role is a decision, and right now it is being made
silently by constant-name similarity.

**Fix (cheap):** keep the constant, but change the comment to say what is actually true — *"no screen
exists for this function; it is the nearest-named existing constant and the grant population is
super-admin / outbound-manager / CS-REP"* — and get an explicit yes on CS-REP holding it. Do **not**
mint a new constant for one route.

---

## Q4 — Over-gating / denial of service. **No legitimate caller is broken.** Challenge sustained on 4/10.

### PRD is decisive

`wms2-hydra` (the only v2 PRD client), per-user function holdings:

| user | CLUB_LINE | TRANSFER_ORDER | PICKING_POSITION |
|---|---|---|---|
| admin, bcampbell, davido, jgero, panderson, thomasjr, tomh | ✔ | ✔ | ✔ |
| `anonymous` | — | — | — |
| `oms_integration` | — | — | — |

The only two non-holders on PRD are the anonymous placeholder and the **OMS service account**, which
belongs to no group and therefore holds **no functions at all** — meaning OMS is already 403'd on every
gated `/v3` route and necessarily talks over the `permitAll` `/rest/**` surface. Independently confirmed:
`oms-laravel-api` `origin/develop` has **zero** occurrences of `clubLine`, `transfers/`,
`pickingOrderPosition`, `runTransfer` or `activateTransferOrder`. **Zero human PRD users lose anything.**

### dev: 45/100 hold the constants — but the losers were already blocked

`wms2-wineco-dev`, per role: `super-admin` (37 users) and `outbound-manager` (10) hold all three;
`inventory-manager` (11) holds TRANSFER only; `CS-REP` (4) holds CLUB + PICKING_POSITION;
`outbound-worker` (17), `outbound-forklift` (11), `inventory-worker` (11), `receiving` (7) hold none.

Those non-holders cannot reach the buttons today: `util/appMenuList.js`'s route guard already blocks
`/outbound/club`, `/outbound/transfer`, `/processes/club-run` and `/processes/transfer-picking` on the
same two functions, and the process screens additionally call already-gated reads before the action is
usable (`store/processes/clubRuns.js` → `/clubLine/skus`, `/clubLine/unitLoads`, `/clubLine/parcels`;
`store/processes/transferPicking.js` → `/transfers/skus`, `/transfers/unitLoads`,
`/transfers/availableTransferLanes` — all gated by SBDEV-3142). Mobile transfer users already needed
`WEB_UI_VIEW_TRANSFER_ORDER` from the class-level annotation on the mobile controller.

### Caller inventory for the ten (challenging the "four have no caller" claim — **confirmed**)

Six have a web caller: `activateBatch` (`store/outbound/club.js:257`), `assignStagingLane` (`:350`),
`activateTransferOrder` (`store/outbound/transfer.js:237`), `assignTransferLane` (`:251`), `runClubLine`
(`store/processes/clubRuns.js:276`), `runTransfer` (`store/processes/transferPicking.js:237`).
Four have **no caller anywhere** — `unlinkStagingLane`, `unlinkTransferLane`, `reassignTransferLane`,
`fixPickingPosition` — verified across `wms2-web-ui`, `wms2-mobile-ui`, `oms-laravel-api` on
`origin/develop`, plus the `/rest/**` controllers and every `@Scheduled` class. The team lead's claim
holds.

### 🟠 FINDING S4 (Low) — the Cypress specs DO call eight of the ten, as an operator-supplied user

`wms2-web-ui/cypress/e2e/wms/club/club-line-order.cy.js` (B.3 `activateBatch`, D.1 `runClubLine` ×2) and
`cypress/e2e/wms/transfer-offsite/transfer-offsite.cy.js` (D.2 `activateTransferOrder`, F.1 `runTransfer`)
hit the newly-gated routes directly. They authenticate as `env.KC_USERNAME`
(`cypress/support/plugins/auth-task.js:51`), which lives in an untracked `cypress.env.json`
(`cypress.env.example.json:22` ships `"YOUR_USERNAME"`), so **I cannot resolve it statically**. On dev
only 45 of 100 users hold the constants. There is no CI on PRs in this estate, so this is a manual-run
break, not a pipeline break.

**Fix:** before the next club or transfer spec run, confirm the `KC_USERNAME` account is in a group
carrying `super-admin` or `outbound-manager`. One line in the ticket's verify notes is enough.
(Related, and worth noting to whoever picks up 403-path testing: `cypress/e2e/cross-cutting/cross-cutting.cy.js:310`
already flags the absence of a second, role-restricted test user as a testability gap — this ticket is
another reason to close it.)

---

## Q5 — What the pin cannot see

### 🟠 FINDING S5 (Medium) — there is NO behavioural denial test, and that departs from the precedent on these exact controllers

`Sbdev3017TrancheGateContextTest` asserts the annotation's *value* is present
(`resolve()` reads `findMergedAnnotation` and returns the function name). It never issues a request, never
observes a 403, never observes the response body or the `AUTHZ_DENIED_HEADER`.

The three existing controller tests give zero gate coverage, by construction:
`ClubLineControllerUnitTest:77`, `TransfersControllerUnitTest:90` and
`PickingOrderPositionControllerUnitTest:48` all call plain `setupMockMvc(controller)`, which builds
`MockMvcBuilders.standaloneSetup(...)` with **no** `.addInterceptors(...)`. They will stay green whatever
the annotations say.

The estate already has the right tool and has used it **on these two controllers**:
`BaseControllerUnitTest.setupMockMvcWithGuard(controller, interceptor)`, used by
`ReportReadGateUnitTest` (SBDEV-3142) at `:327` (`clubLineController`) and `:339` (`transfersController`),
with both a deny-403 sweep and a hold-the-function-200 assertion — and by
`AdminActionConsoleGateUnitTest` (SBDEV-3154, the immediately preceding ticket) at `:150`. Shipping
SBDEV-3155 with no equivalent is a regression in test discipline relative to its own two predecessors.

**Fix:** one `Sbdev3155ActionGateUnitTest` in the shape of `ReportReadGateUnitTest` — `denyEverything()`
+ `setupMockMvcWithGuard`, assert 403 on all ten paths, then assert 200 on one path per function when the
function is held. `ReportReadGateUnitTest:318` carries the trap to avoid, verbatim: a missing required
param *"yields a 400 BEFORE the gate is consulted, which proves nothing."* All ten of these routes are
`@PathVariable`-only, so that trap does not bite here — but the 200-side assertion still matters, because
a deny-everything test alone passes on a route that 500s after the guard.

### 🟠 FINDING S6 (Medium) — the "9 → 15" measurement does not reconcile

`SurfaceInventoryContextTest` javadoc now claims: *"Five tokens were added … taking it from 9 to 15
matches out of 792 registrations"*, and the inline comment claims
*"`/assign` (2) `/reassign` (1) `/unlink` (3) `/activate` (2) `/run` (2) — 10 matches, 10 true."*
9 + 10 = **19**, not 15.

Both operands check out against source, which is what makes the total wrong rather than ambiguous:

- **Old count = 9.** `grep -rniE '@GetMapping\((path *= *)?"[^"]*(/delete|/remove|/cancel|/reset|/create)'`
  over `src/main` yields exactly 7: `ShipperIdController:163`, `UserController:503`,
  `UnitLoadController:176`, `UserGroupController:113`, `UserRoleController:117`, `PrinterController:156`,
  `ReplenishOrderController:198`. Plus the 2 named false positives — `OrderCancellationController` is
  `@RequestMapping("/v3/cancellation")` with `@GetMapping("/list")` and `@GetMapping("/{customerOrderId}/detail")`,
  and `"/v3/cancellation/…"` does contain the literal `/cancel`. 7 + 2 = 9. ✔
- **New count = 10.** `grep -rniE '@GetMapping\((path *= *)?"[^"]*(/assign|/reassign|/unlink|/activate|/run)'`
  yields exactly 10 — the 9 club/transfer routes plus `ReceivingController:341 unlinkSelectedPallet`. Zero
  false positives, and `/assign` genuinely does not subsume `/reassign`. ✔ Both sub-claims are right.

I could not re-derive the runtime figure because maven is barred in that worktree — this is a static
count of *declarations*, and the test counts *registrations*. But none of these nineteen is declared on
`AdminController`, so no alias multiplication applies to any of them and declarations and registrations
should agree 1:1 here.

**Fix:** re-run the test and take the printed number, or change `15` to `19`. This is a "measured" figure
in a security-relevant comment; it will be quoted by the next slice.

### 🟡 FINDING S7 (Low) — javadoc paragraph damage in `SurfaceInventoryContextTest`

The insertion split an `(a)` … `(b)` pair across two `<p>` blocks. `(b)` now dangles mid-sentence at the
end of the SBDEV-3155 paragraph — *"…rather than re-run it and trust a zero. (b) POST-as-query handlers
(the report/dashboard export* family) are labelled MUTATE while changing no state."* — and the sentence
**"Human classification is not replaceable by this tool"** now appears twice, once bolded in the new
paragraph and once at the very end.

Same edit, second problem: the surviving text still reads *"12 of §1's rows"* while
`unlinkSelectedPallet` was deleted from the enumeration because the `/unlink` token now catches it. If it
now classifies `GET-MUTATE` it is no longer one of the rows *"labelled `read` here"*, so that count is 11.
**Fix:** close the `(b)` clause back into its own paragraph, drop the duplicate sentence, and re-derive
the 12.

### 🟡 FINDING S8 (Low) — `@PublicHandler` drift is invisible to the pin

`resolve()` reads only `RequiresFunction`. If someone adds `@PublicHandler` to one of the ten, the pin
stays green while `FunctionGuardInterceptor.preHandle` takes the marker branch, hits the mutual-exclusion
check and denies **everyone** with `CONFLICTING_ANNOTATIONS`. That is the fail-closed direction, so it is
an availability bug rather than a hole — but the pin will report "correct" while the route is dead for
all users. The build-time `@PublicHandler` allow-list rail catches it; worth naming so the pin is not
read as covering it.

### 🟡 FINDING S9 (Low) — an ungated read now feeds a gated action, on the club side only

`ClubLineController:314` `@RequestMapping(value = "/availableStagingLanes", method = GET)` is **ungated**,
while its transfer counterpart `TransfersController:376` `/availableTransferLanes` (POST) **is** gated on
`WEB_UI_VIEW_TRANSFER_ORDER`. `store/outbound/club.js:245` calls the former, `:350`/`:257` then call the
now-gated `assignStagingLane`/`activateBatch`. So on the club screen a caller can still enumerate
available staging lanes and then be refused the assignment; on the transfer screen the enumeration is
refused first. Not exploitable — lane names are low-value — and it is explicitly SBDEV-3158's scope. Flagged
only so the asymmetry is a known one and not discovered as a surprise. Note the pin's four asserted-UNGATED
sibling rows do **not** include `/availableStagingLanes`, so this route is unpinned in either direction.

### Blind spots checked and found NOT to apply

- **Test lane:** `Sbdev3017TrancheGateContextTest` ends in `ContextTest`; surefire excludes only
  `**/*IntegrationTest.java` and `**/*E2ETest.java`, so it does run under `mvn test` despite extending
  `BaseRollbackIntegrationTest`. The pin is live, not one of the 28 orphaned `*IT` classes.
- **`SecurityConfiguration` drift:** adding `/v3/clubLine/**` to `permitAll()` would not un-gate anything —
  the interceptor is independent of the filter chain, `currentUsername()` would return `"anonymousUser"`,
  and `AccessService` denies. Fail-closed.
- **Class-level annotation mutation:** genuinely covered. The four asserted-UNGATED sibling rows
  (`/clubLine/orderBatch/{id}`, `/clubLine/openClubRun`, `/transfers/transferOrder/{id}`,
  `/transfers/openTransfer`) do fail if a class-level `@RequiresFunction` is added to either class, and
  neither class is in `FunctionGuardArchTest`'s `SHARED_CONTROLLERS`, so nothing else would catch it.
  The stated impossibility of such a row for `PickingOrderPositionController` is correct —
  `fixPickingPosition` is its only declared handler.
- **CORS preflight:** `OPTIONS` never resolves to a `HandlerMethod`, so `preHandle` returns `true` early;
  the subsequent real `GET` is still gated.
- **Boot-time rails:** `FunctionGuardStartupAssertion`'s allow-list is arity-keyed on `@PublicHandler`
  sites, not `@RequiresFunction` sites, so ten new annotations cannot break boot.

---

## Severity roll-up

| # | Sev | Finding |
|---|---|---|
| S1 | **High** | `PATCH /v3/customerorder/{id}` is a live ungated equivalent for the 4 Transfers lane routes, and skips the lane-availability check the gated route enforces |
| S3 | Medium | `WEB_UI_VIEW_PICKING_POSITION` gates no screen anywhere; the pin's stated rationale is false for that row, and the resulting population includes `CS-REP` |
| S5 | Medium | No behavioural denial test for any of the ten; both predecessor tickets shipped one on these same controllers |
| S6 | Medium | "9 → 15" does not reconcile with "+10 matches"; both operands verify, the total does not (should be 19) |
| S4 | Low | Cypress club/transfer specs call 8 of the ten as an operator-supplied `KC_USERNAME`; unresolvable statically |
| S7 | Low | Javadoc `(a)/(b)` split, duplicated sentence, stale "12 of §1's rows" |
| S8 | Low | Pin is blind to a `@PublicHandler` added on one of the ten (fail-closed, but silently dead) |
| S9 | Low | `/clubLine/availableStagingLanes` ungated while its transfer twin is gated; unpinned in either direction |

**Nothing found at Critical.** No route among the ten is left reachable by an *unauthenticated* caller, no
privilege escalation is enabled by the change, and the change introduces no new write path.
