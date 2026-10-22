---
title: "SBDEV-3142 — independent security review of the implementation diff"
ticket: "SBDEV-3142"
lane: "x3-security"
reviewed: "2026-08-31"
base: "origin/develop @ c8b3634f"
head: "eabdf1e1 (2 commits)"
worktree: "/home/nampark/dev/wms-claude/.claude/worktrees/wms2-api/SBDEV-3142"
---

# SBDEV-3142 — security review of the diff

## Verdict

**Ship it.** The gate holds at runtime on all 33 paths, including the 13 inherited
`/v3/dashboard/*` registrations. No over-gating break exists in either UI. The denial path is
sane for the streaming handlers. The diff is 22 lines of annotation plus 2 imports and introduces
no logic, no route, and no new logging.

Two findings belong to **SBDEV-3142** and should be closed before merge or explicitly deferred with
Nam's sign-off:

- **F1 (Medium)** — `ReportController` is not enrolled in `FunctionGuardInterceptor.GUARDED`, which
  the plan's own §3.6 mandates *"in the same PR, as the final step."* The deletion tripwire the
  enrollment buys is therefore absent.
- **F2 (Medium)** — the `WEB_UI_VIEW_CLUB_LINE` and `WEB_UI_VIEW_TRANSFER_ORDER` gates are **mutually
  substitutable**. Three of the seven newly gated ClubLine/Transfers handlers have a byte-equivalent
  twin on the *other* controller and neither validates the batch type. This residual is **not**
  recorded anywhere — not in §3.7, not in AC-6's table, not in the earlier security lane's rows 16-18
  — and, critically, **SBDEV-3169 will not close it**, contrary to what those rows imply.

One finding belongs elsewhere:

- **F3 (Low)** — every newly gated export screen shows the operator a correct permission toast *and*
  a contradictory "network or server issue, please retry" toast. Owner: the SBDEV-3030/3031
  refusal-rendering follow-up, not 3142.

Nothing in the already-settled list is re-escalated. `/rest/**` untouched; the SDR twins are
§3.7/AC-6's and I add no residual to that table beyond what F2 names.

---

## Q1 — does the gate hold at runtime for all 33 paths?

**Yes, including `/v3/dashboard/export*`.** Four links, each read from source on the worktree:

1. **Registration is unrestricted.** `WebConfig.functionGuardMappedInterceptor()` returns
   `new MappedInterceptor(new String[] {"/**"}, functionGuardInterceptor)` — no path predicate, so
   `/v3/dashboard/**` is in scope, and the *bean* form is what reaches every `AbstractHandlerMapping`
   initialised inside the context via `detectMappedInterceptors`.
2. **The dual mapping is inheritance.** `DashboardController extends ReportController` and carries
   `@RequestMapping("/v3/dashboard")`. I read the whole class: it declares **six** handlers of its own
   (`orderMonitorViewSummary`, `orderMonitorViewBySectionName`, `orderMonitorClientViewSummary`,
   `orderMonitoClientrViewBySectionName`, `printToteLabels`, `replenishMonitorViewSummary`) and
   **overrides none** of `ReportController`'s 14. So for all 26 report-prefix paths
   `handlerMethod.getMethod().getDeclaringClass()` resolves to `ReportController`.
3. **Resolution does not depend on the declaring class anyway.** `preHandle` reads
   `handlerMethod.getMethodAnnotation(RequiresFunction.class)` *before* the class-level fallback, and
   that call is `AnnotatedElementUtils.findMergedAnnotation` with `TYPE_HIERARCHY` — so even a future
   `DashboardController` override of one of the 13 would inherit the marker rather than escape it.
   `declaringClass` matters only for the `GUARDED` fail-closed branch and for the metric tag.
4. **No shape found where the annotation is present but unenforced.** All 33 are `HandlerMethod`
   handlers, so the `instanceof` guard at the top of `preHandle` never short-circuits them.

**Blind spot, stated:** this is source-derived on the worktree. I sent no HTTP request and ran no
test — `mvn` is another lane's. The runtime half of the claim rests on the measurement already
recorded in `WebConfig`'s javadoc (2026-08-24, `develop` @ `b10b466`: the same interceptor as a
`MappedInterceptor` bean *is* invoked and *does* 403), not on a measurement of mine.

---

## Q2 — under-gating

### `ReportController` is now complete

14 declared handlers, 14 gated: the 13 in this diff plus `reprintLabels`, already gated on `develop`.
Nothing on that controller is left open. This is what makes F1 both safe and worth doing.

### The remaining-reads split — the brief's "12" is one short; it is **13**

Derived by enumerating every `@GetMapping` / `@PostMapping` / `@RequestMapping` on the two
controllers and classifying each by reading its body:

| controller | ungated reads after this diff |
|---|---|
| `ClubLineController` (6) | `GET /orderBatch/{orderBatchId}` · `GET /openClubRun` · `GET /closedClubRun` · `GET /activeClubRun` · `GET /inactiveClubRun` · `GET /availableStagingLanes` |
| `TransfersController` (7) | `GET /transferOrder/{customerOrderId}` · `GET /transferOrderByOrderBatchId/{orderBatchId}` · `GET /openTransfer` · `GET /allOpenTransfer` · `GET /activeTransfer` · `GET /closedTransfer` · `GET /inactiveTransfer` |

The earlier security lane's table (`3142-review-security.md` §144-149) lists **14** rows; one of them,
`GET /transfers/skus`, was subsequently pulled in as row 20, leaving 13. Owner **SBDEV-3158** —
correct as stated.

The **9 mutating GETs** are exactly right: `runClubLine`, `assignStagingLane`, `unlinkStagingLane`,
`activateBatch` (ClubLine) and `runTransfer`, `assignTransferLane`, `reassignTransferLane`,
`unlinkTransferLane`, `activateTransferOrder` (Transfers). Owner **SBDEV-3155**. ✔

### Does anything in the *gated* set have an ungated same-controller twin?

Checked each of the seven non-report gated handlers against every ungated handler on its own
controller, by reading the controller body → the service method → the repository call. Two near-misses,
both cleared:

- `GET /v3/clubLine/availableStagingLanes` (ungated) vs `POST /v3/transfers/availableTransferLanes`
  (gated) — **not** a twin. Different repository queries and different id semantics:
  `LocationRepository.getAvailableStagingLanes(orderBatchId, ORDER_BATCH_CLUB_RUN_FINISHED)`
  (`CustomerorderBatchService:901`) vs `getAvailableTransferLanes(customerOrderId, FINISHED)`
  (`TransferOrderService:84`).
- `GET /v3/transfers/transferOrderByOrderBatchId/{orderBatchId}` (ungated) →
  `CustomerorderService.getCustomerOrderDetails` — an order-header projection, not
  `getOrderDetailView`'s parcel rows. Adjacent, not identical, but it is keyed on the same
  `orderBatchId` a denied user already holds, so **SBDEV-3158 should record it as the sharpest of its
  13** rather than as one list read among many.

`GET /v3/transfers/skus` was pulled in for the right reason and **the same argument applies to nothing
else on these three controllers** — the report surface is complete, and the remaining ClubLine /
Transfers reads serve batch *lists* and order *headers*, not the per-batch detail the gated four serve.

### F2 — the real twin is cross-controller, and nothing records it

**Finding F2 · Medium · in scope for SBDEV-3142 · not recorded by the plan, AC-6, or the prior
security lane.**

Three of the gated handlers on `ClubLineController` have an equivalent on `TransfersController`
gated on a *different* function, and **neither side validates the type of the batch it was handed**:

| pair | ClubLine (`WEB_UI_VIEW_CLUB_LINE`) | Transfers (`WEB_UI_VIEW_TRANSFER_ORDER`) | relationship |
|---|---|---|---|
| parcels | `POST /v3/clubLine/parcels` | `POST /v3/transfers/parcels` | **identical** — both bodies are `return dtoViewService.getOrderDetailView(orderBatchId)`, and `ViewDtoService:436` runs `customerorderRepository.getOrderViewsByBatchId(orderBatchId)` with no type predicate |
| SKUs | `POST /v3/clubLine/skus` | `GET /v3/transfers/skus` | **equivalent** — `CustomerorderBatchService:1239/1246` and `TransferOrderService:251/253` both do `findByOrderbatchId(orderBatchId)` then `findByOrderId(orders.get(0).getId())`, and both return `List<ClubLineSkuDto>` |
| unit loads | `POST /v3/clubLine/unitLoads` | `POST /v3/transfers/unitLoads` | **equivalent shape** — one loads `CustomerorderBatch` by id, the other `Customerorder` by orderbatchId; neither asserts `OrderBatchType` |

Consequence: a user holding **only** `WEB_UI_VIEW_CLUB_LINE` obtains transfer-batch parcel rows, SKU
overview and unit loads by handing a transfer `orderBatchId` to the `/v3/clubLine/*` handler — and the
converse holds for a `WEB_UI_VIEW_TRANSFER_ORDER`-only user against club batches. Both are
`wms_user`-authenticated, so this is horizontal, not a privilege escalation, and it needs a valid
`orderBatchId` (a small dense integer space — enumerable, but that is a separate observation).

**Why this is not just another §3.7 residual.** §3.7's whole point is that an SDR twin serves the same
rows today, which is true here too (`GET /v3/customerorder/search/findByOrderbatchId`, the prior lane's
rows 16 and 18). So the *marginal* exposure today is zero. But rows 16 and 18 assign the residual to
**SBDEV-3169**, and 3169 closes SDR — it does not touch these two MVC handlers, which are already
gated. **When 3169 lands, this pair stays open**, and the ticket's own accounting will say it closed.
That is the `a-guard-fences-the-mechanism-you-aimed-at` shape one level down from the one §3.7 caught:
the gates are correct, the *partition* they imply is not enforced.

Plan §3.5 gets within one sentence of this — it notes the two `getParcelView` bodies are "identical in
effect" and calls it "unfinished API symmetry" — but draws an API-hygiene conclusion, not an
authorization one, and then assigns the two handlers different functions without noting that the
difference is unenforceable.

**Recommendation.** Do *not* add another annotation. Either (a) assert the batch type in each of the
three ClubLine handlers and its counterpart (the cheap, correct fix — one `orderBatch.getType()` check
against `OrderBatchType.CLUB` / `TRANSFER_*`), or (b) if the partition is not actually intended,
record that explicitly so nobody later reads the two functions as a boundary. Minimum acceptable
outcome: **an AC-6 row naming this residual with an owner**, since neither 3169 nor 3158 reaches it.

### F1 — `GUARDED` enrollment was mandated by the plan and is missing

**Finding F1 · Medium · in scope for SBDEV-3142 · plan-conformance gap with a security consequence.**

Plan §3.6 is unambiguous: *"Recommendation: enroll `ReportController` in `GUARDED` in the same PR, as
the final step — after the 13 annotations, so the boot assertion is green at every commit."* It even
reverses an earlier draft that had rejected this, and shows the two premises for rejecting it were
false. The diff does not touch `FunctionGuardInterceptor`; `GUARDED` still holds 14 classes and
`ReportController` is not among them.

What is lost: the **deletion tripwire**. With enrollment, removing any one of the 13 annotations makes
the application refuse to boot (`FunctionGuardStartupAssertion`); without it, the removal falls
through *allowed* and is caught only by `Sbdev3017TrancheGateContextTest`'s reflection pin — a test
whose lane health I did not verify (another lane owns `mvn`) and which is strictly weaker than a boot
refusal. The plan's §3.6 also verifies the safety precondition: the assertion keys on
`declaringClass`, so `DashboardController`'s six own handlers are skipped and cannot become
violations, and `ReportController` is 14-of-14 annotated after this diff.

`ClubLineController` and `TransfersController` must stay out of `GUARDED` — the plan is right about
that, and enrolling either would fail-close their 13 reads and 9 mutating GETs.

---

## Q3 — over-gating

**No break found in `wms2-web-ui` @ `9e70a73` or `wms2-mobile-ui` @ `c79e81c`.**

**Method.** For each of the 20 handlers, `command grep` (not the ignore-aware `grep` shell function —
`.gitignore` hides `reports/`, which is where most of these screens live) over `store/ components/
pages/ plugins/ util/ layouts/ middleware/`, excluding `dist/`, which is a stale build that polluted a
first sweep. Every call site was then traced back through its Vuex namespace to the screen that
dispatches it, and matched against `util/appMenuList.js`.

- **All 9 report screens map 1:1** to the function their export and view are gated on
  (`appMenuList.js:109-121`): inventory→`INVENTORY_RECORD`, lock→`STOCK_UNIT_LOCK_OVERVIEW`,
  receiving→`RECEIVED_STOCK_OVERVIEW`, skuLocation→`LOCATION_OVERVIEW`, flowbin→`FLOWBIN_MONITOR`,
  parcelPicking→`PARCEL_PICKING`, outboundParcel→`PARCEL_MONITOR`, stockUnit→`STOCK_UNIT_RECORD`,
  container→`UNIT_LOAD_RECORD`. `exportStorageLocations` is called only from
  `components/masterData/location/storageLocations/storageLocation.vue:314` →
  `appMenuList.js:87` `WEB_UI_VIEW_STORAGE_LOCATION`. ✔
- **The shared export popup is safe.** `components/reports/popups/exportReport.vue` is imported by all
  9 report screens, but `exportReport()` dispatches on `reportType` (`:145-167`), 1:1 with the store
  module, so no screen exports through another screen's endpoint.
- **Two cross-module store usages checked and cleared.** `components/reports/skuLocationReport.vue:363`
  and `components/receiving/open/create/createPurchaseOrderSkuTable.vue:412` both dispatch
  `reports/inventory/getReportInfo`, which GETs `/itemData/itemdataDetailsById/{id}` — not a gated
  path. `components/admin/shippers/addShipper.vue:97` is a commented-out line.
- **`store/reports/data.js:48` is a dead second caller** of `/report/exportReceiving`, reachable only
  when `reportType === 'Data'`, which no screen sets (`reportType` assignments swept across
  `components/` and `pages/`). Not an over-gating path.
- **Club/Transfer call sites all match their gate.** `store/processes/clubRuns.js:201/218/238/258` and
  `store/outbound/club.js:203` sit behind `WEB_UI_VIEW_CLUB_LINE` (`appMenuList.js:60,69,172-174`);
  `store/processes/transferPicking.js:169/183/198/222` and `store/outbound/transfer.js:211/225` behind
  `WEB_UI_VIEW_TRANSFER_ORDER` (`:61,70,180-181`). ✔
- **Mobile UI: zero callers** of any of the 20 (all 20 path fragments swept). The five
  `DashboardController`-declared handlers the mobile UI *does* call stay ungated, and
  `Sbdev3017TrancheGateContextTest` now pins them ungated — the right defence against a future
  "simplify to a class-level annotation" refactor, which would otherwise 403 two mobile screens
  silently (`@RequiresFunction` is not `@Inherited`, so the ArchUnit class-annotation check stays
  green while the runtime denies).

**One latent over-gating, Low, tracked with the web-ui half.** `store/outbound/outboundBols.js:199`
`getItemInfo` POSTs `/clubLine/skus` from the BOL module. It is dispatched from **nowhere** —
`outboundBols/getItemInfo` returns zero hits across `components/`, `pages/`, `store/` — which
confirms plan §3.4's read. §3.4 decided to delete it in the paired web-ui PR; that PR is not part of
this API-only diff. If it is ever re-wired to a BOL screen, a `WEB_UI_VIEW_BILL_OF_LADING`-only user
403s.

**Blind spot, stated:** I did not sweep `omsv2-UI` or `oms-laravel-api` — the same gap the plan records
for §3.5. A caller there would not appear in either sweep.

**Availability risk already owned (not re-escalated):** the plan's **P7** — WineCo PRD lacks
`WEB_UI_VIEW_PARCEL_PICKING` entirely, so rows 6 and 12 fail closed for all 93 users there, as does
the already-merged `reprintLabels`. That is a release blocker on the plan and is correctly recorded;
I only note that it is the one place where this diff's failure mode is *denial of service to
legitimate operators*, which is the over-gating failure the brief asks about, arriving by a data path
rather than a code path.

---

## Q4 — denial-path behaviour

**Sane. No `response.reset()` anywhere in scope.** Grepped `ReportController`, `ClubLineController`,
`TransfersController` and `ReportService` for `reset()` / `resetBuffer()`: zero hits. The
CORS-header-stripping trap this codebase has hit before does not apply to these handlers.

**Denial cannot happen mid-stream.** The gate runs in `preHandle`, before the handler executes, so for
the 9 streaming exports nothing has been written and the response is uncommitted when
`FunctionGuardInterceptor.deny` runs. `setStatus(403)` → `setContentType(application/problem+json)` →
`setHeader(X-Authz-Denied, …)` all take effect, and the problem body is written to
`getOutputStream()` afterwards. Once export writing has begun the gate is already past; there is no
window in which a partial spreadsheet and a 403 can both be emitted.

**The header survives and is readable cross-origin.** `SecurityConfiguration.java:220-221` adds
`Authority.AUTHZ_DENIED_HEADER` to the CORS exposed-header list when absent. `responseType: 'blob'`
does not affect header delivery, so `util/authzDenied.js#readAuthzDeniedHeader` works unchanged on
these requests — which is precisely why the existing helper is header-keyed rather than body-keyed.

### F3 — the operator gets a correct toast and a contradictory one

**Finding F3 · Low · NOT SBDEV-3142's — owner: the SBDEV-3030/3031 refusal-rendering follow-up.**

On a gated export denial, two things fire:

1. `plugins/axios.js:114` correctly identifies the authz 403 by header, declines to retry, and toasts
   *"You do not have permission for this action (WEB_UI_VIEW_…). Ask an administrator if you need
   access."*
2. The rejection then propagates to the store action's own `catch`, which in **every** report export
   (`store/reports/{inventory,lock,receiving,skuLocation,flowbin,parcelPicking,outboundParcel,
   stockUnit,container}.js` and `store/masterData/storageLocation.js`) unconditionally toasts *"Error:
   Request failed due to a network or server issue. Please retry."*

So the screen tells the operator both that they lack permission and that they should retry a transient
fault. Only `store/handlingUnits/stockUnits.js` and `store/handlingUnits/container.js` use
`isAuthzDenial` to suppress their own message — the SBDEV-3030/3031 pattern, which none of these ten
actions adopted. This is not code the diff touches, but the diff is what makes these ten paths
reachable, so it belongs on the same follow-up rather than nowhere.

Secondary note for whoever picks that up: because the request sets `responseType: 'blob'`,
`error.response.data` on the 403 is a `Blob`, not the parsed problem object — any handler tempted to
read `.reason` off the body will get `undefined`. Use `isAuthzDenial(error)`, which reads the header.

---

## Q5 — anything the diff exposes that it did not intend

Nothing. `git diff origin/develop...HEAD -- src/main/java` is 22 added annotation lines and 2 added
imports across three controllers. No logic change, no new route, no new logging of request bodies, no
change to `FunctionGuardInterceptor`, `WebConfig`, `SecurityConfiguration`, or `AccessService`. The
test diff adds 38 pin rows (85→123) and a 534-line unit test; the pin's stated arithmetic checks out
(26 + 3 + 4 + 5 = 38).

One observation on the pin's honesty rather than its correctness: the five `DashboardController` rows
are asserted **ungated**, which is the right call and well-reasoned in the comment — but it means the
`123` count now mixes "must be gated" and "must stay ungated" assertions in one number. A future reader
reconciling `123` against a route inventory should not read it as "123 gated routes."

---

## Summary table

| # | Finding | Severity | Scope |
|---|---|---|---|
| F1 | `ReportController` not enrolled in `GUARDED` — the deletion tripwire the plan's §3.6 mandates is absent | Medium | **SBDEV-3142** |
| F2 | `WEB_UI_VIEW_CLUB_LINE` and `WEB_UI_VIEW_TRANSFER_ORDER` are mutually substitutable across parcels/SKUs/unitLoads; no batch-type check; **SBDEV-3169 will not close it** and no AC-6 row records it | Medium | **SBDEV-3142** (record under AC-6 at minimum) |
| F3 | Every newly gated export screen emits a correct permission toast plus a contradictory "retry" toast; 10 store actions never adopted `isAuthzDenial` | Low | SBDEV-3030/3031 follow-up |
| — | `GET /v3/transfers/transferOrderByOrderBatchId/{orderBatchId}` is the sharpest of the 13 remaining ungated reads (same key, adjacent projection) | informational | SBDEV-3158 |
| — | `outboundBols/getItemInfo` → `/clubLine/skus` is dead but will 403 if re-wired | Low | web-ui half of 3142 (§3.4) |
| — | Brief's "12 remaining reads" is **13** | correction | SBDEV-3158 |

## Instruments and blind spots

- **Instruments:** source read of the worktree diff and of `FunctionGuardInterceptor`, `WebConfig`,
  `SecurityConfiguration`, `DashboardController`, and the four service/repository call chains;
  `command grep` sweeps of `wms2-web-ui` @ `9e70a73` and `wms2-mobile-ui` @ `c79e81c`.
- **No live probe, no test run** — `mvn` is another lane's and no HTTP request was sent. Every runtime
  claim here is source-derived and says so where it matters (Q1, F2).
- **Not swept:** `omsv2-UI`, `oms-laravel-api`. A caller of any of the 20 there would be invisible to
  the Q3 over-gating analysis.
- **Not verified:** whether `Sbdev3017TrancheGateContextTest` actually executes in a green lane. F1's
  severity depends on it — if that lane is down, the 13 annotations have *no* automated protection at
  all and F1 rises to High.
