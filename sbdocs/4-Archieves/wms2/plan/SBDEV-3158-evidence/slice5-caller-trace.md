# SBDEV-3158 Slice 5 — Full Per-Route Caller Trace (Dashboard + admin/system, rows 83-93)

Evidence-gathering only, no code changes. Method follows the slice-2 lesson (§12): a per-FUNCTION
sweep ("does this constant map to *some* screen") is necessary but not sufficient — this trace finds
each route's *actual* caller(s) in `wms2-web-ui` and `wms2-mobile-ui`, the page/component that issues
the call, and that page's real gating function from `util/appMenuList.js` / `pages/admin.vue` (web) or
`util/menuCatalog.js` (mobile), then compares against the plan's §0.5 planned target.

All web-ui greps used `git -C .../wms2-web-ui grep` per the `reports/` `.gitignore` trap noted in the
task brief — confirmed this repo's `.gitignore` does contain a bare `reports/` line, so plain
ignore-aware `grep -r` would have silently skipped any tracked file under a `reports/` directory.
None of this slice's call sites happened to live under `reports/`, but the git-grep discipline was
used throughout regardless, per instruction.

---

## Row 83 — `GET /v3/dashboard/orderMonitorClientViewSummary`

Planned target: `WEB_UI_VIEW_ORDER_MONITOR`

- **Caller (web-ui):** `store/dashboard/pickpackMonitor.js:109` (`getClientSummary` action) — issues
  `this.$axios.$get('/dashboard/orderMonitorClientViewSummary')`.
- **Dispatched from:** `components/homepage/pickPackMonitor/tables/shipperBrandTable.vue:371` —
  `await this.$store.dispatch('dashboard/pickpackMonitor/getClientSummary')`.
- **Top-level page:** `pages/dashboard/index.vue` (imports the pickPackMonitor component tree).
- **Page's gating function:** `util/appMenuList.js:39` — `{ to: '/dashboard', ..., fn:
  'WEB_UI_VIEW_ORDER_MONITOR' }` (menu row 1).
- **Mobile caller:** none found (`git grep "orderMonitorClientViewSummary"` in `wms2-mobile-ui`: 0 hits).
- **Verdict: target confirmed.** Single web-only caller, gate matches the caller's screen exactly.

---

## Row 84 — `GET /v3/dashboard/orderMonitorViewBySectionName/{sectionName}`

Planned target: `WEB_UI_VIEW_ORDER_MONITOR`

- **Caller (web-ui):** `store/dashboard/pickpackMonitor.js:98` (`getZoneDetails` action).
- **Dispatched from:** `components/homepage/pickPackMonitor/tables/zoneViewTable.vue:325` —
  `this.$store.dispatch('dashboard/pickpackMonitor/getZoneDetails', { sectionName: ... })`.
- **Top-level page:** `pages/dashboard/index.vue`, same as row 83.
- **Page's gating function:** `WEB_UI_VIEW_ORDER_MONITOR` (`appMenuList.js:39`).
- **Mobile caller:** none found.
- **Verdict: target confirmed.**

---

## Row 85 — `GET /v3/dashboard/orderMonitoClientrViewBySectionName/{clientName}/{sectionName}`

Planned target: `WEB_UI_VIEW_ORDER_MONITOR`. Note: the Java method name is the plain 3-arg overload
of `orderMonitorViewBySectionName`; only the URL path carries the live typo `orderMonitoClientr...`.

- **Caller (web-ui):** `store/dashboard/pickpackMonitor.js:122` (`getClientDetails` action) — confirmed
  the exact typo string `orderMonitoClientrViewBySectionName` is live in the frontend call, not just
  the backend route: `` `/dashboard/orderMonitoClientrViewBySectionName/${data.clientName}/${data.sectionName}` ``.
- **Dispatched from:** `components/homepage/pickPackMonitor/tables/shipperBrandTable.vue:324` —
  `this.$store.dispatch('dashboard/pickpackMonitor/getClientDetails', { clientName, sectionName })`.
- **Top-level page:** `pages/dashboard/index.vue`, same as rows 83-84.
- **Page's gating function:** `WEB_UI_VIEW_ORDER_MONITOR`.
- **Mobile caller:** none found.
- **Verdict: target confirmed.** Confirms the plan's warning that this typo is genuinely live and load-
  bearing — the path must NOT be corrected as part of this ticket.

---

## Row 86 — `GET /v3/dashboard/orderMonitorViewSummary`

Planned target: ANY-of `WEB_UI_VIEW_ORDER_MONITOR` + `MOBILE_UI_VIEW_PICKING`

- **Caller (web-ui):** `store/dashboard/pickpackMonitor.js:85` (`getZoneSummary` action), dispatched
  from `components/homepage/pickPackMonitor/tables/zoneViewTable.vue:372`. Top-level page
  `pages/dashboard/index.vue` → `WEB_UI_VIEW_ORDER_MONITOR` (same menu row as 83-85).
- **Caller (mobile-ui):** `store/picking.js:246` (`getRapidPickingSectionOverview` action), dispatched
  from `components/picking/scanSection.vue:66` — `this.$store.dispatch('picking/getRapidPickingSectionOverview', { value: ... })`.
  `scanSection.vue` is imported by `pages/picking.vue:15` (`import ScanSection from
  '~/components/picking/scanSection.vue'`), confirmed also via `test/pages/workflow-reset-on-entry.spec.js:74`.
- **Mobile page's gating function:** `util/menuCatalog.js` — `{ title: 'Picking', link: '/picking',
  role: 'MOBILE_UI_VIEW_PICKING' }`.
- **Verdict: target confirmed.** Two-caller, two-screen route; the plan's ANY-of set exactly matches
  both actual callers' actual screen functions. No widening needed.

---

## Row 87 — `GET /v3/dashboard/replenishMonitorViewSummary`

Planned target (plan §0.5): ANY-of `WEB_UI_VIEW_REPLENISHMENT_MONITOR` + `MOBILE_UI_VIEW_REPLENISHMENT`

- **Caller (web-ui):** `store/dashboard/replenishMonitor.js:33`, dispatched as
  `dashboard/replenishMonitor/getReplenishSummary` from
  `components/homepage/replenishMonitor/replenishViewTable.vue:247`. That component is imported into
  `pages/dashboard/index.vue:20` (`import ReplenishMoitor from
  '~/components/homepage/replenishMonitor/replenishViewTable.vue'`) and rendered there — i.e. it is a
  **widget on the Dashboard page**, not on a page reachable via a `WEB_UI_VIEW_REPLENISHMENT_MONITOR`-
  gated menu row.
- **Dashboard page's actual gating function:** `WEB_UI_VIEW_ORDER_MONITOR` (`appMenuList.js:39`, same
  row that gates 83-86).
- **`WEB_UI_VIEW_REPLENISHMENT_MONITOR` swept against every function-name-bearing web-ui file** —
  `util/appMenuList.js`, `pages/admin.vue`, `pages/index.vue`,
  `components/masterData/material/skuData/skuData.vue`, `util/putawayScopeFunctions.js` — **zero
  hits in any of them.** It also appears explicitly in the plan's own H1 "partial list of unmapped
  constants" (§12, cross-slice finding). Only place it exists at all in wms2-web-ui is
  `test/support/webFunctionConstants.js`, which documents it as a function CS-REP is *granted* at the
  DB level but which gates no menu leaf — the leaf ("Replenishment") needs `WEB_UI_VIEW_REPLENISHMENT_ORDER`
  instead, a different constant entirely (`test/support/webFunctionConstants.js:132`, "Replenishment
  CS-REP holds REPLENISHMENT_MONITOR, the leaf needs REPLENISHMENT_ORDER").
  **`WEB_UI_VIEW_REPLENISHMENT_MONITOR` gates ZERO screens in wms2-web-ui — confirmed dead, per H1
  method.**
- **Caller (mobile-ui):** `pages/replenish.vue:129,149` — `fetchHeldUp()` and `fetchAllReplen()` both
  call `this.$axios.$get('/dashboard/replenishMonitorViewSummary')` directly (page-local, not via a
  store action). ⚠ **Correction (code review, 2026-09-04):** this was first recorded as `:133,153`.
  The local `v2/wms2-mobile-ui` checkout was 10 commits behind `origin/develop` at trace time, and
  `git grep` with no revision argument reads the working tree, not `origin/develop` — so this one
  citation measured a stale checkout (a `priorityLabels` refactor upstream shifted the lines) and
  overwrote the plan's own already-correct `:129,149`. Re-verified against `origin/develop` @
  `3744a18` for this correction. Every other citation in this document was independently
  re-confirmed against `origin/develop` during code review and found correct.
- **Mobile page's gating function:** `util/menuCatalog.js:70-74` — `{ title: 'Replenish Process ',
  link: '/replenish', role: 'MOBILE_UI_VIEW_REPLENISHMENT' }`. Matches the plan's mobile half exactly.
- **Verdict: target needs widening to ANY-of.** The web half of the plan's pair
  (`WEB_UI_VIEW_REPLENISHMENT_MONITOR`) is a dead constant with no caller on any matching screen — the
  actual (only) web caller's screen is gated on `WEB_UI_VIEW_ORDER_MONITOR`. Per D.4 ("sibling fn vs
  caller's screen disagree → ANY-of both") and the H1 precedent ("one row whose original single
  function had no caller on any matching screen at all" was widened by ADDING the actual caller's
  function, not by replacing the original), the corrected set is:
  **ANY-of { `WEB_UI_VIEW_REPLENISHMENT_MONITOR` (original target, dead but DB-granted, kept per H1
  precedent), `WEB_UI_VIEW_ORDER_MONITOR` (actual web caller's screen — Dashboard), `MOBILE_UI_VIEW_REPLENISHMENT`
  (mobile caller's screen, unchanged) }.**
  Without the `WEB_UI_VIEW_ORDER_MONITOR` addition, gating on `WEB_UI_VIEW_REPLENISHMENT_MONITOR` alone
  (or ANY-of it with only the mobile function) would 403 every Dashboard-page web user viewing the
  Replenishment Monitor widget, since that constant maps to nothing any web role's menu actually grants
  through UI navigation.

---

## Row 88 — `GET /v3/message/detailView` (⚠fn — inferred, zero gated siblings per plan)

Planned target: `WEB_UI_VIEW_MESSAGES`

- **Caller (web-ui):** `store/admin/serviceLogs.js:50` (`searchServiceLogs` action) —
  `this.$axios.$get('/message/detailView' + urlPart)`.
- **Dispatched from:** `components/admin/serviceLog/serviceLog.vue:301` —
  `this.$store.dispatch('admin/serviceLogs/searchServiceLogs', { page, itemsPerPage, keyword, sortUrl })`,
  fired on tab load + search + sort (confirmed by Cypress comment
  `cypress/e2e/wms/admin/admin.cy.js:796` — "dispatched by searchServiceLogs() action on tab load,
  page change, search, and sort").
- **Top-level page/tab:** `pages/admin.vue:62` — `{ text: 'Service Log', fn: 'WEB_UI_VIEW_MESSAGES',
  component: 'ServiceLog', canonical: 6 }`. `serviceLog.vue` is registered as that tab's component
  (`pages/admin.vue:25`, `import ServiceLog from '~/components/admin/serviceLog/serviceLog.vue'`).
- **`WEB_UI_VIEW_MESSAGES` also appears in `util/appMenuList.js`'s Admin row `fn:` array** (line 137,
  `'WEB_UI_VIEW_MESSAGES', // Service Log`) as one of the Admin ANY-of's 6 tab functions — it is a
  first-class, live member of the Admin menu-row ANY-of, not merely a `pages/admin.vue`-local gate.
- **Mobile caller:** none found (`git grep "message/detailView"` in `wms2-mobile-ui`: 0 hits).
- **Verdict: target confirmed — and the plan's ⚠fn inference is CORROBORATED, not merely unrefuted.**
  `WEB_UI_VIEW_MESSAGES` is a real, live gate on a real screen (Admin > Service Log), present in both
  `appMenuList.js` and `pages/admin.vue`. It is not one of the H1 dead-constant set.

---

## Row 89 — `GET /v3/message/messageDetailsById/{id}` (⚠fn — inferred)

Planned target: `WEB_UI_VIEW_MESSAGES`

- **Caller (web-ui):** `store/admin/serviceLogs.js:95` (`getLogDetail` action) —
  `` this.$axios.$get(`/message/messageDetailsById/${data.id}`) ``.
- **Dispatched from:** `components/admin/serviceLog/serviceLog.vue:280` — `this.details =
  await this.$store.dispatch('admin/serviceLogs/getLogDetail', {id: item.id})`, fired from the "Show
  Details" row action (confirmed by Cypress comment: "dispatched by getLogDetail() from 'Show Details'
  button").
- **Top-level page/tab:** same `pages/admin.vue` Service Log tab as row 88 — `WEB_UI_VIEW_MESSAGES`.
- **Mobile caller:** none found.
- **Verdict: target confirmed — ⚠fn inference corroborated**, same evidence chain as row 88 (same tab,
  same component, same gate).

---

## Row 90 — `GET /v3/message/resend/{messageId}` (ACTION, per plan §E.3)

Planned target: `WEB_UI_VIEW_MESSAGES`

- **Caller (web-ui):** `store/admin/serviceLogs.js:78` (`resendMessage` action, confirmed at the exact
  line the task brief names) — `this.$axios.$get('/message/resend' + urlPart)`.
- **Dispatched from:** `components/admin/serviceLog/resendConfirmation.vue:63` —
  `this.$store.dispatch('admin/serviceLogs/resendMessage', {id: this.item.id})`. `resendConfirmation.vue`
  is a child dialog of the Service Log tab (used from `serviceLog.vue`'s row actions per the Cypress
  suite's "Resend" test at `cypress/e2e/wms/admin/admin.cy.js:826`).
- **Top-level page/tab:** same Service Log tab, `WEB_UI_VIEW_MESSAGES`.
- **Mobile caller:** none found.
- **Verdict: target confirmed.** Same tab/gate as rows 88-89; the plan correctly separately flags this
  one as an ACTION (a resend replays a message through the OMS↔WMS bus) rather than a pure read, which
  is a §E.3 classification question, not a caller-trace question — the caller trace itself is clean.

---

## Sweep: does `WEB_UI_VIEW_MESSAGES` gate any menu row at all (H1 method)?

**Yes — confirmed via two independent files:**
1. `util/appMenuList.js:137` — member of the Admin row's `fn: [...]` ANY-of array (Service Log).
2. `pages/admin.vue:62` — `{ text: 'Service Log', fn: 'WEB_UI_VIEW_MESSAGES', component: 'ServiceLog',
   canonical: 6 }`.

Not one of the 23-of-58 dead constants from the H1 finding. This is a real control.

---

## Row 91 — `GET /v3/system/searchSystemByGroupname/{groupName}` (⚠fn — inferred, plan cites 5 callers)

Planned target: `WEB_UI_VIEW_SYSTEM_PROPERTY`

- **All 5 callers found in `store/admin/configuration.js`, matching the plan's count exactly:**
  1. `configuration.js:116` — `getSystemLabels` (hardcoded groupname `Labels`, actually reroutes to
     `Patterns` per line 116's literal path — a pre-existing app-level oddity, not a gating concern).
  2. `configuration.js:285` — `searchSystemByGroupname(context, groupName)`, the generic action, called
     with a caller-supplied groupname.
  3. `configuration.js:297` — `getSystemPatterns` (hardcoded `Patterns`).
  4. `configuration.js:309` — `getOperationOptions` (hardcoded `Operation Options`).
  5. `configuration.js:321` — `getSystemSettings` (hardcoded `System Settings`).
- **Dispatched from `components/admin/parametersAndConfiguration/parametersMain.vue`:** lines 72-79 —
  `admin/configuration/getSystemPatterns`, `getSystemLabels`, `getOperationOptions`,
  `getSystemSettings`, all fired on tab mount. `parametersMain.vue` is the component rendered inside
  `pages/admin.vue`'s Parameters & Configuration tab.
- **Top-level page/tab:** `pages/admin.vue:57` — `{ text: 'Parameters & Configuration', fn:
  'WEB_UI_VIEW_SYSTEM_PROPERTY', component: 'ParametersMain', canonical: 1 }`.
- **`WEB_UI_VIEW_SYSTEM_PROPERTY` also confirmed in `util/appMenuList.js:133`** — member of the Admin
  row's `fn: [...]` ANY-of array (`'WEB_UI_VIEW_SYSTEM_PROPERTY', // Parameters & Configuration`).
- **Mobile caller:** none found (`git grep "searchSystemByGroupname"` in `wms2-mobile-ui`: 0 hits).
- **Verdict: target confirmed — ⚠fn inference corroborated.** `WEB_UI_VIEW_SYSTEM_PROPERTY` is a real,
  live gate on a real screen (Admin > Parameters & Configuration), present in both `appMenuList.js` and
  `pages/admin.vue`. Not one of the H1 dead-constant set.

---

## Sweep: does `WEB_UI_VIEW_SYSTEM_PROPERTY` gate any menu row at all (H1 method)?

**Yes — confirmed via the same two files:**
1. `util/appMenuList.js:133` — member of the Admin row's `fn: [...]` ANY-of array.
2. `pages/admin.vue:57` — `{ text: 'Parameters & Configuration', fn: 'WEB_UI_VIEW_SYSTEM_PROPERTY', ... }`.

Not dead. Real control.

---

## Row 92 — `GET /v3/system/mobileUiUrl` (`@PublicHandler` — bootstrap, both UIs per plan; handler name `triggerOrderReplenish` is a misnomer)

- **Web-ui callers (2):**
  1. `pages/index.vue:103` — `await this.$store.dispatch("getMobileUrl")`, called unconditionally
     inside `handleAuthentication()` immediately after Keycloak auth succeeds and BEFORE
     `functionsLoaded`/redirect — genuine pre-entitlement bootstrap call.
  2. `layouts/default.vue:550` — `openMobileUI()` method calls `this.$axios.$get('/system/mobileUiUrl')`
     directly (not via the store action), triggered by a header "open mobile UI" button — this is a
     **post-login, user-initiated** call, not a bootstrap call, but it is unconditional with respect to
     any function gate (no `v-if` function check found guarding the button in the surrounding markup
     scan).
  - `store/index.js:95` defines the `getMobileUrl` action itself (`GET /system/mobileUiUrl`).
- **Mobile-ui:** `store/index.js:53-58` defines an identical `getMobileUrl` action calling the same
  endpoint, **but no `.vue` file in `wms2-mobile-ui` dispatches it** (`git grep "getMobileUrl"` across
  the whole mobile repo returns only the action's own definition, no caller). **This action is
  currently dead/unreachable in wms2-mobile-ui.**
- **Verdict: confirmed as a genuine pre-entitlement bootstrap read on web-ui** (`pages/index.vue:103`
  fires before any function set is loaded, so no function gate could ever be satisfied there — `@PublicHandler`
  is correct and necessary). **Correction to the plan's framing:** "bootstrap, both UIs" overstates the
  current mobile-ui reality — mobile-ui defines the same client-side action but never calls it anywhere
  today. This does not change the `@PublicHandler` disposition (web-ui's bootstrap call alone requires
  it), but the plan should not cite mobile-ui as an active caller of this route without qualification.

---

## Row 93 — `GET /v3/tenant/health` (`@PublicHandler` — bootstrap, both UIs per plan)

- **Mobile-ui caller:** `pages/index.vue:117` — `await this.$store.dispatch("checkTenantHealth")`,
  called unconditionally inside `handleAuthentication()` right after Keycloak auth and warehouse
  init, and BEFORE any function/menu load — the `isTenantHealthy` result gates whether the user is
  redirected to `/unhealthy-tenant` or continues to `redirectPage()`. Genuine pre-entitlement bootstrap
  read. Also documented in `wms2-mobile-ui/CLAUDE.md:68,74`: "`pages/index.vue` listens for
  `keycloak-authenticated`, calls `checkTenantHealth` ... gates rendering on `authorized && affiliated`"
  and "`checkTenantHealth` hits `GET /tenant/health`".
- **Web-ui:** `store/index.js:82-90` defines an identical `checkTenantHealth` action calling
  `/tenant/health`, and `pages/index.vue:41` has a computed `isTenantHealthy()` reading
  `state.tenantHealth` — **but no `.vue` file in `wms2-web-ui` dispatches `checkTenantHealth`
  anywhere** (`git grep "checkTenantHealth"` across the whole web-ui repo returns only the action's own
  definition at `store/index.js:82`, never a `dispatch("checkTenantHealth")` call). The `tenantHealth`
  state value therefore stays at its hardcoded default (`true`, `store/index.js:8`) for the entire
  session — the computed getter reads a value nothing ever updates. **This action is currently
  dead/unreachable in wms2-web-ui.**
- **Verdict: confirmed as a genuine pre-entitlement bootstrap read on mobile-ui.** `@PublicHandler` is
  correct and necessary for the same reason as row 92 (mobile calls this before any function set is
  loaded). **Correction to the plan's framing:** the roles are inverted from row 92 — here it is
  **mobile-ui** that's the live caller and **web-ui** where the action exists but is never dispatched.
  "Bootstrap, both UIs" again overstates current reality for one side; disposition unaffected.

---

## Summary of deviations from the plan's §0.5 table

| Row | Plan's stated target | Trace verdict |
|---|---|---|
| 83 | `WEB_UI_VIEW_ORDER_MONITOR` | confirmed, no change |
| 84 | `WEB_UI_VIEW_ORDER_MONITOR` | confirmed, no change |
| 85 | `WEB_UI_VIEW_ORDER_MONITOR` | confirmed, no change; typo path confirmed live and must stay |
| 86 | ANY-of `WEB_UI_VIEW_ORDER_MONITOR` + `MOBILE_UI_VIEW_PICKING` | confirmed, no change |
| **87** | ANY-of `WEB_UI_VIEW_REPLENISHMENT_MONITOR` + `MOBILE_UI_VIEW_REPLENISHMENT` | **needs widening** — add `WEB_UI_VIEW_ORDER_MONITOR` (actual web caller's screen); `WEB_UI_VIEW_REPLENISHMENT_MONITOR` itself is a dead constant (zero menu-row callers) |
| 88 | `WEB_UI_VIEW_MESSAGES` (⚠fn) | confirmed, corroborated real (not dead) |
| 89 | `WEB_UI_VIEW_MESSAGES` (⚠fn) | confirmed, corroborated real |
| 90 | `WEB_UI_VIEW_MESSAGES` | confirmed, action classification unaffected |
| 91 | `WEB_UI_VIEW_SYSTEM_PROPERTY` (⚠fn) | confirmed, corroborated real (not dead) |
| 92 | `@PublicHandler`, "bootstrap, both UIs" | disposition confirmed correct; **mobile-ui does not currently call this route at all** — plan's "both UIs" framing is imprecise, not the `@PublicHandler` decision itself |
| 93 | `@PublicHandler`, "bootstrap, both UIs" | disposition confirmed correct; **web-ui does not currently call this route at all** (dead action) — same imprecision, mirrored |

**Rows needing ANY-of widening: row 87 only** (1 of 11 in-scope rows).

**⚠fn rows and their corroboration status:** all three (88, 89, 91) are corroborated as real, live
gates — found directly in both `util/appMenuList.js` (Admin row's ANY-of array) and `pages/admin.vue`
(per-tab `fn:`). None turned out to be dead constants; the plan's inference held up under the full
per-route trace.

**No "no UI caller found in either repo" rows** in this slice — every one of the 11 routes traced has
at least one confirmed caller in at least one of the two UI repos.
