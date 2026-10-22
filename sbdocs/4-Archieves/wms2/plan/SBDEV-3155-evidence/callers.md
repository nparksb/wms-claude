# SBDEV-3155 — Caller analysis for the ten ungated GET endpoints

Lane: caller-analysis. Date: 2026-09-01. Read-only investigation.

## Baseline — checkouts vs origin/develop

All three checkouts were fetched and are **exactly at `origin/develop`, 0 commits behind**, so
working-tree greps and `origin/develop` greps are the same content here. No `git grep origin/develop`
fallback was needed for the UI repos (it was used anyway for the API).

| repo | HEAD | origin/develop | commits behind |
|---|---|---|---|
| `v2/wms2-web-ui` | `3117aca` | `3117aca` | 0 |
| `v2/wms2-mobile-ui` | `c79e81c` | `c79e81c` | 0 |
| `v2/wms2-api` | `ad681319` | `ad681319` | 0 |

## Two corrections to the task brief (both load-bearing)

1. **`FunctionEnum` is not in `net.aim_ai.wms.constants.WmsConstants`.** That package does not exist.
   The constants live in **`net.aim_ai.wms.service.WmsConstants`**, in a nested static class
   `FunctionEnum` holding `public static final String` fields (it is *not* a Java `enum`). Cite it as
   `v2/wms2-api/src/main/java/net/aim_ai/wms/service/WmsConstants.java:363`. `net/aim_ai/wms/Authority.java`
   matched a `FunctionEnum` grep but holds **roles** (`sb_admin`, `wms_admin`), not functions.
2. **The web-ui route→function map is not in `middleware/require-function.js`.** That file imports
   `requiredFunctionFor` / `requiredFunctionsFor` from **`~/util/appMenuList`**; the map is
   `v2/wms2-web-ui/util/appMenuList.js`.

## The table

Confidence key: **High** = full store→component→page chain read end to end, plus a two-instrument
grep agreeing. **Medium** = chain established but one hop inferred.

| # | endpoint | web-ui callers (file:line) | mobile-ui callers | cypress callers | screen | best-fit existing constant | new constant needed? | conf |
|---|---|---|---|---|---|---|---|---|
| 1 | `GET /v3/clubLine/runClubLine/{orderBatchId}` | `store/processes/clubRuns.js:276` ← `components/processes/clubRuns/itemsTable.vue:230` ← `components/processes/clubRuns/clubRunDetails.vue:79` ← `pages/processes/club-fulfillment.vue:17` | **none** | `cypress/support/helpers/wmsHelpers.js:583`; `cypress/e2e/wms/club/club-line-order.cy.js:473` (test D.1) | Club Fulfillment (`/processes/club-fulfillment`) | `WEB_UI_VIEW_CLUB_LINE` | **No** | High |
| 2 | `GET /v3/clubLine/assignStagingLane/{orderBatchId}/{locationId}` | `store/outbound/club.js:350` (action **`updateStagingLane`**) ← `components/outbound/club/pop/updateStagingLanePop.vue:85` ← `components/outbound/club/openClub.vue:129,137,368` ← `pages/outbound/club/index.vue:23` | **none** | none | Outbound → Club, "Update Staging Lane" row action | `WEB_UI_VIEW_CLUB_LINE` | **No** | High |
| 3 | `GET /v3/clubLine/unlinkStagingLane/{orderBatchId}` | **NONE** | **none** | none | — (no caller found anywhere) | `WEB_UI_VIEW_CLUB_LINE` (by controller sibling) | **No** | High |
| 4 | `GET /v3/clubLine/activateBatch/{orderBatchId}/{locationId}` | `store/outbound/club.js:257` ← **two** dispatchers: `components/outbound/club/activate/confirmationPop.vue:66` (← `pages/outbound/club/index.vue`) and `components/processes/clubRuns/activate/confirmationPop.vue:84` (← `activateClubBatch.vue:23` ← `pages/processes/club-run.vue:84`) | **none** | `wmsHelpers.js:574`; `club-line-order.cy.js:308` (test B.3 "Start Club") | Outbound → Club **and** Processes → Club Run | `WEB_UI_VIEW_CLUB_LINE` (both screens carry it) | **No** | High |
| 5 | `GET /v3/transfers/runTransfer/{orderId}` | `store/processes/transferPicking.js:237` ← `components/processes/transferPicking/itemsTable.vue:128` (button `Run Transfer`, `itemsTable.vue:5`) ← `transferPickingDetails.vue:66` ← `pages/processes/transfer-fulfillment.vue:17` | **none** | `wmsHelpers.js:1121`; `cypress/e2e/wms/transfer-offsite/transfer-offsite.cy.js` | Transfer Fulfillment (`/processes/transfer-fulfillment`) | `WEB_UI_VIEW_TRANSFER_ORDER` | **No** | High |
| 6 | `GET /v3/transfers/assignTransferLane/{customerOrderId}/{locationId}` | `store/outbound/transfer.js:251` (action **`changeTransferLane`**) ← `components/outbound/transfer/activate/changeLanePop.vue:76` ← `components/outbound/transfer/openTransfers.vue:117` ← `pages/outbound/transfer/index.vue:23` | **none** | none | Outbound → Transfer, "change lane" popup | `WEB_UI_VIEW_TRANSFER_ORDER` | **No** | High |
| 7 | `GET /v3/transfers/reassignTransferLane/{customerOrderId}/{locationId}` | **NONE** | **none** | none | — (no caller found anywhere) | `WEB_UI_VIEW_TRANSFER_ORDER` (by controller sibling) | **No** | High |
| 8 | `GET /v3/transfers/unlinkTransferLane/{customerOrderId}` | **NONE** | **none** | none | — (no caller found anywhere) | `WEB_UI_VIEW_TRANSFER_ORDER` (by controller sibling) | **No** | High |
| 9 | `GET /v3/transfers/activateTransferOrder/{customerOrderId}/{locationId}` | `store/outbound/transfer.js:237` ← **two** dispatchers: `components/outbound/transfer/activate/confirmationPop.vue:84` (← `pages/outbound/transfer/index.vue`) and `components/processes/transferPicking/activate/confirmationPop.vue:85` (← `activateTransferBatch.vue:23` ← `pages/processes/transfer-picking.vue:80`) | **none** | `wmsHelpers.js:1102`; `transfer-offsite.cy.js:230` (test D.2) | Outbound → Transfer **and** Processes → Transfer Picking | `WEB_UI_VIEW_TRANSFER_ORDER` (both screens carry it) | **No** | High |
| 10 | `GET /v3/pickingOrderPosition/fixPickingPosition/{id}` | **NONE** | **none** | none | — (no caller found anywhere, in any repo) | `WEB_UI_VIEW_PICKING_POSITION` (see §"the one judgement call") | **No** | Medium |

### Verdict on the gate axis

**No new `FunctionEnum` constant is needed for any of the ten.** Every one maps onto a constant that
already exists in `WmsConstants.FunctionEnum`, already has a `mywms_function` row, and already has
non-super-admin holders on production. Per the T-router this removes the "new constant → every tenant
must be granted" cost that would otherwise push the ticket to T3.

## Mobile-ui: a clean, loud negative — and one trap that is NOT a trap

**Zero of the ten endpoints are reachable from `wms2-mobile-ui`.** Two independent instruments agree:

1. Per-fragment `command grep -rn` over the whole repo for all ten fragments → 0 hits each.
2. Controller-root greps: `clubLine` → 0 hits, `transfers/` → 0 hits, `pickingOrderPosition` → 1 hit,
   and that one hit is `tests/e2e/.auth/user.json:44` — a **persisted-Vuex snapshot inside a Playwright
   auth fixture**, i.e. serialized state, not a call site.

Mobile's own API surface confirms it. Enumerating every template-literal and quoted path under
`store/ pages/ components/ util/` yields 45 distinct paths, none of them under `/clubLine`,
`/transfers` or `/pickingOrderPosition`.

**The disambiguation that matters:** mobile *does* have a transfer screen, but it calls a **different
controller** — `/transferOrder/*` (`net.aim_ai.wms.controller.mobile.TransferOrderController`), not
`/transfers/*` (`TransfersController`):

```
store/transferOrder.js:53   $get('/transferOrder/orderList')
store/transferOrder.js:66   $post('/transferOrder/processOrderPositionSelect', data)
store/transferOrder.js:89   $post('/transferOrder/processScanUnitLoad', data)
store/transferOrder.js:107  $post('/transferOrder/processScanTransferLane', data)
store/transferOrder.js:117  $post('/transferOrder/updateOrder', ...)
```

`/transfers` and `/transferOrder` are two different controllers. Anyone searching `transfer` alone
will conflate them and wrongly report mobile as a caller of endpoints 5–9.

### The "would a WEB_UI_* gate 403 the mobile screen?" question — answered, and the answer is no

This was the brief's loudest concern. It does not bite, for two independent reasons:

1. **No mobile screen calls any of the ten** (above).
2. **Even if one did, mobile already gates on the WEB_UI constant.** `wms2-mobile-ui/store/home.js:133-136`
   defines its menu entry as:

   ```js
   title: "Transfer Process",
   link: "/transfer-order",
   role: "WEB_UI_VIEW_TRANSFER_ORDER",
   ```

   Every other mobile menu entry uses a `MOBILE_UI_VIEW_*` role; this one entry deliberately reuses the
   **web** constant. So a mobile operator who can reach Transfer Process already holds
   `WEB_UI_VIEW_TRANSFER_ORDER` by construction. There is no `MOBILE_UI_VIEW_CLUB_*` at all, and
   mobile has no club screen.

   This is corroborated server-side: `controller/mobile/TransferOrderController.java` is one of the
   files that already references `WEB_UI_VIEW_TRANSFER_ORDER`.

## Four endpoints have NO caller anywhere in the monorepo

`unlinkStagingLane`, `reassignTransferLane`, `unlinkTransferLane`, `fixPickingPosition` return **zero
hits** across **all four** UI repos (`v2/wms2-web-ui`, `v2/wms2-mobile-ui`, `v1/wms-web-ui`,
`v1/wms-mobile-ui`), excluding only `node_modules/.git/.nuxt/dist/coverage`, and zero in the Cypress
suite. Cross-checked with `git grep` (file counts 0) as the second instrument.

Read this as **"no in-repo UI caller"**, not "dead code" — see blind spots. In particular
`fixPickingPosition` is a repair/remediation action of exactly the shape an operator or support
engineer invokes by hand or via a tool outside these repos.

Note the asymmetry this creates for the ticket: gating an endpoint with no caller is the *safest*
possible gate (nothing can regress in the UI), but it is also the one where a gate can silently break
an out-of-repo consumer. These four deserve an explicit decision, not a default.

## The one judgement call — `fixPickingPosition` (endpoint 10)

This is the only endpoint whose constant is not settled by a sibling route on the same controller.

- `PickingOrderPositionController` (`@RequestMapping("/v3/pickingOrderPosition")`) has **exactly one
  mapped route** — `fixPickingPosition` — and imports no `RequiresFunction` at all. There is no sibling
  to inherit from.
- Three plausible existing constants: `WEB_UI_VIEW_PICKING_ORDER`, **`WEB_UI_VIEW_PICKING_POSITION`**,
  `WEB_UI_VIEW_PICKING_UNIT_LOAD` (`WmsConstants.java:392-394`).
- `WEB_UI_VIEW_PICKING_POSITION` is the name-exact match for the controller's own resource, and it has
  real holders on production (below). **Recommend it.**
- ⚠️ Caveat, stated plainly: neither `WEB_UI_VIEW_PICKING_ORDER` nor `WEB_UI_VIEW_PICKING_POSITION` is
  currently attached to any *live* `@RequiresFunction`. Both appear in `src/main` only in
  `WmsConstants.java` and `controller/rest/UtilRestController.java` — and per the known repo trap,
  `UtilRestController` is annotated `@Service`, **not** `@RestController`, so its `@RequestMapping`
  methods do not route. So this would be the first real enforcement of that constant. That is a
  *reason to verify the grants*, which I did, not a blocker.
- The web-ui side gates Pick Pack on a **third** constant, `WEB_UI_VIEW_PICKING_ORDER`
  (`appMenuList.js:59`, flagged in-file as "⚠ semantics-derived"). If the ticket prefers "gate a route
  on its screen's existing function", and if a screen for this action is ever added under Pick Pack,
  `WEB_UI_VIEW_PICKING_ORDER` would be the alternative. With no caller today there is no screen to
  derive from, so the resource-exact constant is the better default.

## DB evidence — the grants exist, so none of these gates locks anyone out

Orientation check first: `mywms_role_mywms_function(rolelist_id, functionlist_id)` was historically
**reversed** (SBDEV-3005). I ran the join **both ways** rather than trusting the column names.
Face-value orientation returns holders; the reversed orientation returns 0 rows for all four
functions. **Face-value is correct on these DBs.**

`wms2-wineco-dev` (`dev_wh01_om1`):

| function | roles | role names |
|---|---|---|
| `WEB_UI_VIEW_CLUB_LINE` | 5 | CS-REP, ROLE000057, ROLE000102, **outbound-manager**, super-admin |
| `WEB_UI_VIEW_TRANSFER_ORDER` | 3 | **inventory-manager**, **outbound-manager**, super-admin |
| `WEB_UI_VIEW_PICKING_ORDER` | 3 | CS-REP, **outbound-manager**, super-admin |
| `WEB_UI_VIEW_PICKING_POSITION` | 3 | CS-REP, **outbound-manager**, super-admin |

`wms2-hydra` — **production**, the only v2 PRD client. Counting **users**, not roles (a role count is
not the unit; a 1-role constant can still be 38 users):

| function | roles | **users via group** | role names |
|---|---|---|---|
| `WEB_UI_VIEW_CLUB_LINE` | 2 | **7** | outbound-manager, super-admin |
| `WEB_UI_VIEW_TRANSFER_ORDER` | 3 | **7** | inventory-manager, outbound-manager, super-admin |
| `WEB_UI_VIEW_PICKING_ORDER` | 2 | **7** | outbound-manager, super-admin |
| `WEB_UI_VIEW_PICKING_POSITION` | 2 | **7** | outbound-manager, super-admin |

All four have a **non-super-admin production holder** (`outbound-manager`, which is a fleet role seeded
by `V2.2.19__seed_web_view_function_grants.sql`, not a tenant-authored one). Per V2.2.19's own warning
I did **not** count `CS-REP` as fleet coverage — it is WineCo-only and absent on hydra, which the hydra
numbers confirm.

**Consequence:** all ten gates can be applied using existing constants with existing grants. No new
constant, no new grant migration, no `initDB` line.

## Server-side precedent — the gate is already used on these very controllers

Both controllers already carry the exact constant on sibling routes, so this is pattern-matching, not
new design:

- `ClubLineController.java:256, 264, 301` — `@RequiresFunction(WmsConstants.FunctionEnum.WEB_UI_VIEW_CLUB_LINE)`
  on `/skus`, `/unitLoads`, `/parcels`.
- `TransfersController.java:333, 340, 362` — `@RequiresFunction(WmsConstants.FunctionEnum.WEB_UI_VIEW_TRANSFER_ORDER)`
  on `/skus`, `/unitLoads`, `/parcels`.
- `PickingOrderPositionController.java` — **no gates at all**, does not import `RequiresFunction`.

I confirmed all ten target routes are currently **ungated**: none carries `@RequiresFunction` or
`@PreAuthorize` (verified by reading the mapping/annotation lines of all three controllers).

## Screen → function map used above (source of truth)

From `v2/wms2-web-ui/util/appMenuList.js`:

```
:59  { text: 'Pick Pack',         to: '/outbound/pick-pack',           fn: 'WEB_UI_VIEW_PICKING_ORDER' }  // ⚠ semantics-derived
:60  { text: 'Club',              to: '/outbound/club',                fn: 'WEB_UI_VIEW_CLUB_LINE' }
:61  { text: 'Transfer',          to: '/outbound/transfer',            fn: 'WEB_UI_VIEW_TRANSFER_ORDER' }
:69  { text: 'Club Run',          to: '/processes/club-run',           fn: 'WEB_UI_VIEW_CLUB_LINE' }
:70  { text: 'Transfer Picking',  to: '/processes/transfer-picking',   fn: 'WEB_UI_VIEW_TRANSFER_ORDER' }
:167 '/processes/club-fulfillment':     'WEB_UI_VIEW_CLUB_LINE'
:168 '/processes/transfer-fulfillment': 'WEB_UI_VIEW_TRANSFER_ORDER'
:172 '/outbound/club/open/:id':         'WEB_UI_VIEW_CLUB_LINE'
:180 '/outbound/transfer/open/:id':     'WEB_UI_VIEW_TRANSFER_ORDER'
```

Every calling screen for endpoints 1–2 and 4–6 and 9 resolves to `WEB_UI_VIEW_CLUB_LINE` or
`WEB_UI_VIEW_TRANSFER_ORDER` with no ambiguity — including the two endpoints (4 and 9) reachable from
*two different screens*, because both of each pair carry the same function.

## Method and blind spots

### What I searched

- `git fetch` on all three repos, then `git rev-list --count HEAD..origin/develop` to prove staleness = 0.
- **Fragment search, not path search**: all ten searched as bare fragments (`runClubLine`,
  `assignStagingLane`, `fixPickingPosition`, …). This was necessary — two of the six live callers sit
  in store actions whose **names do not match the URL**: `updateStagingLane` → `assignStagingLane`,
  `changeTransferLane` → `assignTransferLane`. A search by action name would have missed both.
- **Two instruments, per the `reports/` gitignore trap**: every fragment counted with both
  `command grep -rn` (not ignore-aware) and `git grep` (tracked files, sees `reports/`). Counts agreed
  on all ten — in particular the four zero-caller endpoints are zero under *both*.
- **Cypress searched explicitly**, including `cypress/support/helpers/wmsHelpers.js`, which does call
  endpoints directly via `cy.wms('GET', ...)` and is invisible to a store→component→page trace.
- Full store → component → page chain read for each of the six live endpoints (both dispatcher paths
  for the two dual-screen endpoints).
- Mobile: per-fragment, plus controller-root, plus a full enumeration of its API path surface.
- API: all three controllers' mappings/annotations read from `origin/develop` via `git show`.
- DB: both orientations of the role↔function join, on dev and on production.

### What this method cannot see — state as limits, not as coverage

1. **Out-of-repo callers.** OMS (`v2/oms-laravel-api`, `v1/oms`), Postman/HAR collections, ops runbooks,
   cron jobs and hand-run curl are all outside the four UI repos I searched. This is the live risk for
   the four zero-caller endpoints, and especially for `fixPickingPosition`, whose shape is
   "support engineer repairs a stuck position". **I did not search `oms-laravel-api` or `v1/oms`.** If
   the ticket intends to gate those four, that search should happen first.
2. **Fully dynamic URL construction.** A path assembled from a variable (`const ep = 'runClub' + 'Line'`)
   or read from config would evade a fragment grep. I saw no such pattern, but I cannot exclude it.
3. **`v1/wms-web-ui` and `v1/wms-mobile-ui` were searched only for the four zero-caller fragments**, not
   for all ten. v1 is a separate API anyway (per repo policy v1 is reference-only), so a v1 hit would
   not change a v2 gating decision — but I did not do the exhaustive pass there and am not claiming one.
4. **Runtime reachability ≠ static reference.** A component that is imported but never rendered, behind
   a feature flag or a `v-if` a tenant never satisfies, still counts as a "caller" in this table. I did
   not verify any of the six live endpoints actually fires at runtime for any tenant.
5. **A contradicted HAR claim I could not resolve.** `cypress/e2e/wms/club/club-line-order.cy.js:476,500`
   asserts the club Run flow "mirrors what the WMS Mobile UI does (verified in HAR: runClubLine appears
   twice in the captured flow)". **The mobile-ui source at `origin/develop` contains no reference to
   `runClubLine` or `clubLine` at all.** Either that HAR was captured against the *web* UI and
   mislabelled, or against v1, or against a mobile build that has since dropped the feature. I am
   reporting the source-of-truth measurement (mobile does not call it) and flagging the contradiction
   rather than silently picking a side. If a mobile club caller matters to the ticket, resolve this
   against a fresh HAR, not against the repo.
6. **`coverage/lcov-report/**` produced duplicate hits** (a build artifact mirroring `components/`). I
   excluded it from the app-source pass. It contains no independent call sites.
7. **DB coverage is two tenants** (wineco-dev, hydra-prd). I did not survey shipitez or the UAT tenants.
   The grant claim is "holders exist on dev and on the only v2 PRD client", not "on every tenant".
