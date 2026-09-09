# SBDEV-3142 — does the MOBILE UI call any of the 16 ungated POST-as-query read endpoints?

**Verdict: I found no mobile caller of any of the 16.** Distinguished from "there is no caller" in
§5 — the completeness claim is the weak part of this report and is bounded there explicitly.

**But the landmine is real via a different mechanism than a caller.** `DashboardController extends
ReportController`, and the guard's class-level fallback uses `AnnotationUtils.findAnnotation`, which
walks superclasses. A **class-level** `@RequiresFunction` on `ReportController` would therefore be
inherited by `DashboardController`'s own handlers — including the two `/v3/dashboard/*` GETs the
mobile UI **does** call — and 403 two mobile screens. See §4. This is a hard design constraint on
SBDEV-3142 even though no mobile caller of the 16 exists.

## 1. Provenance

| | |
|---|---|
| `wms2-mobile-ui` `origin/develop` HEAD | `c79e81c30b879f7a82213a8a9a76ede44228157d` (Mon Aug 31 07:55:35 2026 -0400, "Merge pull request #53 from SiteBossInc/claude/wms-500-errors-failures-zqbvlq") |
| `wms2-api` `origin/develop` HEAD | `d434a3e5ce44a8a7a5aa16f9d65b3db57130cf3b` |
| Tracked files in mobile repo | 202 — small enough to sweep exhaustively rather than sample |

Both repos were `git fetch origin`'d first. **Every claim below is derived from `origin/develop` via
`git grep <pat> origin/develop` / `git show origin/develop:<path>`, never from the working tree.**

### `.gitignore` — hides nothing source-relevant (checked, as instructed)

The sibling `wms2-web-ui` failure mode (a `.gitignore`d `reports/` directory invisible to
ignore-aware tools and to this shell's `grep` function, producing false "no caller" verdicts) **does
not exist in this repo.** `git show origin/develop:.gitignore` ignores only build/tooling output:
`node_modules`, `.nuxt`, `dist`, `coverage`, `.nyc_output`, `playwright-report/`, `test-results/`,
`.claude/worktrees/`, `.omc/`, `.env`. No source directory is ignored. `git grep` was used
throughout regardless, so the question is moot either way.

## 2. Commands run

```bash
# provenance
git fetch origin; git rev-parse origin/develop

# axis 1 — the 10 export handler names, case-insensitive, repo-wide (no pathspec: tests included)
for p in exportInventory exportLock exportReceiving exportSkuLocation exportFlowbin \
         exportParcelPicking exportOutboundParcel exportStockUnitRecord \
         exportContainerRecord exportStorageLocations; do
  git grep -n -i "$p" origin/develop; done

# axis 2 — the clubLine / transfers families, repo-wide
git grep -n -i "clubline"  origin/develop
git grep -n -i "transfers" origin/develop
git grep -n -i "availableTransferLanes" origin/develop

# axis 3 — path prefixes, incl. /dashboard searched as carefully as /report
git grep -n "/transfers" origin/develop
git grep -n "/dashboard" origin/develop
git grep -n "/report"    origin/develop

# axis 4 — leading path segments that would betray an alternate literal
git grep -nE "['\"\`]/[A-Za-z]*(skus|unitLoads|parcels|availableTransferLanes)" origin/develop -- store pages components util plugins middleware

# axis 5 — DYNAMIC construction: template literals, concatenation, variable first args
git grep -nE "\\\$(get|post|put|patch|delete)\(\s*\`|\\\$(get|post|put|patch|delete)\(\s*['\"][^'\"]*['\"]\s*\+|\\\$(get|post|put|patch|delete)\(\s*[A-Za-z_\$]" origin/develop -- store pages components plugins middleware util layouts

# axis 6 — other invocation forms the shorthand regex would miss
git grep -nE '\$axios\.(get|post|put|patch|delete|request|head|options)\(|\$axios\(\s*\{|\$axios\.\$request' origin/develop -- store pages components util layouts plugins middleware
git grep -nE '\bfetch\(' origin/develop -- store pages components plugins middleware util layouts
git grep -nE "^\s*(const|let|var) [A-Z_]+ *= *['\"\`]/" origin/develop -- store util plugins components pages

# axis 7 — transport layer: baseURL, proxy, rewrite, embedded web UI
git show origin/develop:plugins/axios.js
git show origin/develop:nuxt.config.js | grep -nE 'proxy|baseURL|BASE_URL|rewrite|target'
git grep -niE '<iframe|webview|window\.open|location\.href *=' origin/develop -- pages components layouts plugins store util middleware

# axis 8 — sibling check: does mobile have ANY export/download capability?
git grep -niE 'responseType|blob|\.csv|xlsx|download|exportTo|saveAs' origin/develop -- store pages components util layouts plugins

# axis 9 — shared-package axis
git show origin/develop:package.json

# axis 10 — full inventory of every API path mobile calls
git grep -hoE "\\\$(get|post|put|patch|delete)\(\s*[\`'\"]/[A-Za-z0-9_/{}$.:-]*" origin/develop -- store pages components util layouts | sed -E "s/^\\\$(get|post|put|patch|delete)\(\s*[\`'\"]//" | sed -E 's#/\$\{.*##' | sort -u

# API side — controller identity, dual-mapping, guard resolution
git grep -nE 'RequestMapping\(.*"(/)?v3/(transfers|transferOrder)' origin/develop -- 'src/main/**/*.java'
git grep -n "orderMonitorViewSummary\|replenishMonitorViewSummary" origin/develop -- 'src/main/**/*.java'
git show origin/develop:src/main/java/net/aim_ai/wms/security/FunctionGuardInterceptor.java
```

## 3. Per-endpoint verdict — 16 rows

Path column is the **mobile-facing** shape (mobile's axios `baseURL` already ends in `/v3`, so a
source literal `'/dashboard/x'` is the wire path `/v3/dashboard/x`; see §4.1).

| # | Endpoint | Mobile caller? | Basis |
|---|---|---|---|
| 1 | `POST /v3/{report,dashboard}/exportInventory` | **No** | `git grep -i exportInventory origin/develop` → 0 hits repo-wide |
| 2 | `POST /v3/{report,dashboard}/exportLock` | **No** | `git grep -i exportLock` → 0 hits repo-wide |
| 3 | `POST /v3/{report,dashboard}/exportReceiving` | **No** | `git grep -i exportReceiving` → 0 hits repo-wide |
| 4 | `POST /v3/{report,dashboard}/exportSkuLocation` | **No** | `git grep -i exportSkuLocation` → 0 hits repo-wide |
| 5 | `POST /v3/{report,dashboard}/exportFlowbin` | **No** | `git grep -i exportFlowbin` → 0 hits repo-wide |
| 6 | `POST /v3/{report,dashboard}/exportParcelPicking` | **No** | `git grep -i exportParcelPicking` → 0 hits repo-wide |
| 7 | `POST /v3/{report,dashboard}/exportOutboundParcel` | **No** | `git grep -i exportOutboundParcel` → 0 hits repo-wide |
| 8 | `POST /v3/{report,dashboard}/exportStockUnitRecord` | **No** | `git grep -i exportStockUnitRecord` → 0 hits repo-wide |
| 9 | `POST /v3/{report,dashboard}/exportContainerRecord` | **No** | `git grep -i exportContainerRecord` → 0 hits repo-wide |
| 10 | `POST /v3/{report,dashboard}/exportStorageLocations` | **No** | `git grep -i exportStorageLocations` → 0 hits repo-wide. ⚠ near-miss, see §3.1 |
| 11 | `POST /v3/clubLine/skus` | **No** | `git grep -i clubline origin/develop` → **0 hits repo-wide.** The string "clubLine" does not occur in this repo in any case |
| 12 | `POST /v3/clubLine/unitLoads` | **No** | same — no `clubLine` literal at all |
| 13 | `POST /v3/clubLine/parcels` | **No** | same — no `clubLine` literal at all |
| 14 | `POST /v3/transfers/unitLoads` | **No** | `git grep -n "/transfers" origin/develop` → 0 hits. ⚠ near-miss, see §3.2 |
| 15 | `POST /v3/transfers/parcels` | **No** | same — no `/transfers` path literal |
| 16 | `POST /v3/transfers/availableTransferLanes` | **No** | `git grep -i availableTransferLanes` → 0 hits repo-wide |

Corroborating negative (independent of the path greps): **the mobile UI has no
file-export/download capability at all.** Axis 8 returned zero `responseType`, zero `saveAs`, zero
`.csv`/`xlsx`, zero real `download` — every "blob" hit is prose about the Vuex persisted-state blob,
e.g. `plugins/persistedState.client.js`: *"this mobile blob was observed carrying web's whole"*. The
ten `/export*` handlers exist to return a downloadable file; a UI with no download path has no way to
consume one. Two independent instruments, same answer.

### 3.1 Near-miss #1 — `exportStorageLocations` vs a real mobile call

Mobile **does** call `/stockUnit/storageLocationsForStockMovement`
(`store/moveStock.js`, via the `$get`/`$post` inventory in §3.3). Different controller
(`/v3/stockUnit/…`), different handler, **not** `/v3/report/exportStorageLocations`. Flagging it
because the names collide on "storageLocations" and a sloppier grep could pair them.

### 3.2 Near-miss #2 — `/v3/transfers/*` (in scope) vs `/v3/transferOrder/*` (mobile's, out of scope)

This is the single most likely way this verdict could have gone wrong, so it was checked on the API
side rather than reasoned about:

- `TransfersController.java:35` → `@RequestMapping("/v3/transfers")`, `public class
  TransfersController extends AdminController`. It declares the three in-scope handlers:
  `@RequestMapping(value = "/unitLoads", … method = RequestMethod.POST)`, `"/parcels"` POST,
  `"/availableTransferLanes"` POST.
- `controller/mobile/TransferOrderController.java:29` → `@RequestMapping("/v3/transferOrder")`,
  `public class TransferOrderController extends AdminController`. Declares mobile's five:
  `/orderList`, `/processOrderPositionSelect`, `/processScanUnitLoad`, `/processScanTransferLane`,
  `/updateOrder`.

**No dual-mapping and no inheritance between them** — they share only `AdminController`, the common
base of ~43 controllers, which contributes no path. Mobile's `store/transferOrder.js` calls resolve
to `/v3/transferOrder/*`, never `/v3/transfers/*`.

Extra trap worth naming: `TransfersController` itself declares
`@GetMapping(path= "/transferOrder/{customerOrderId}")`, i.e. the literal string `transferOrder`
appears **inside** the in-scope controller at wire path `/v3/transfers/transferOrder/{id}`. A grep
for `transferOrder` therefore hits both controllers. Mobile calls the `/v3/transferOrder/…` prefix,
which routes to `TransferOrderController`; it does not call `/v3/transfers/transferOrder/…`.

Also: all 39 `transfers`-matching hits in the mobile repo are the substring `transferStock`
(`store/moveStock.js:263`: `this.$axios.$post('/stockUnit/transferStock', data, {`) — the Move Stock
commit on `/v3/stockUnit/`, a third distinct controller.

### 3.3 The two `/v3/dashboard/*` GETs mobile does call — context, not hits

As the brief predicted, and confirming the search reaches the right files:

- `pages/replenish.vue:133` — `const results = await this.$axios.$get('/dashboard/replenishMonitorViewSummary')`
- `pages/replenish.vue:153` — same path, inside the `Promise.all([...])`
- `store/picking.js:246` — `const results = await this.$axios.$get('/dashboard/orderMonitorViewSummary')`

Plus Playwright mocks (`tests/e2e/replenish.spec.ts`, `tests/e2e/picking.spec.ts`:
`await page.route('**/dashboard/orderMonitorViewSummary', …)`). Both are GETs, both outside the 16.
**These are the reason §4 matters.**

`git grep -n "/report" origin/develop` returns **only `yarn.lock` noise** (`"@jest/reporters"`) — the
mobile UI never uses the `/v3/report` prefix at all.

### 3.4 Full inventory — the 77 distinct API paths mobile calls

Derived by axis 10: 77 distinct paths from 91 `$axios.$VERB` call sites across 20 files. None of the
16 appears. Grouped with braces below for width — the brace groups expand to the 77.

```
/cancellation                       /picking/pickingOrderPositionsInfo
/cancellation/list                  /picking/pickingOrders
/cancellation/scan-tote             /picking/pickTimeOutValue
/cycleCountLos/countSingleUnitLoad  /picking/processLocation
/cycleCountLos/countUnitLoad        /picking/processPick
/cycleCountLos/locationList         /picking/processRapidPickScanPackage
/cycleCountLos/orderList            /picking/processRapidPickScanPackageToVerify
/cycleCountLos/processScanUnitLoad  /picking/processRapidPickScanPackageType
/cycleCountLos/recountSingleUnitLoad /picking/processRapidPickScanSource
/cycleCountLos/recountUnitLoad      /picking/processRapidPickScanSourcePass
/cycleCountLos/scanSingleUnitLoad   /picking/releasePickingOrder
/cycleCountLos/unitLoadList         /picking/resetPickingOrder
/dashboard/orderMonitorViewSummary  /putaway/calculatePutawayList
/dashboard/replenishMonitorViewSummary /putaway/scanFlowBinLocation
/lookup/locationByLocationName      /putaway/scanPallet
/lookup/search                      /putaway/storeBoxOnLocation
/lookup/stockListByItemNumber       /putaway/storePalletBackOnPutawayLane
/lookup/unitLoadListByLocationName  /putaway/storePalletOnLocation
/moveStock/selectSource             /replenish/{checkAmount,checkDestination,checkSource}
/moveStock/selectStockUnit          /replenish/{clientList,clientOrderList}
/moveUnitload/selectDestination     /replenish/fixedLocationUpperBound
/moveUnitload/selectSource          /replenish/loadOrderById
/palletizing/scanPallet             /replenish/multi-unitloads
/palletizing/scanPalletBulk         /replenish/order
/palletizing/scanParcel             /replenish/{requestAmount,requestLocation}
/palletizing/scanParcelBulk         /section, /section/search/findByName
/stockUnit/isUnitLoadIdValid        /transferOrder/orderList
/stockunit/search/getAmountAvailable /transferOrder/processOrderPositionSelect
/stockUnit/storageLocationsForStockMovement /transferOrder/processScanTransferLane
/stockUnit/transferStock            /transferOrder/processScanUnitLoad
/system/mobileUiUrl                 /transferOrder/updateOrder
/system/syncAdminWithKeycloak       /truckLoading/{loadOrder,orderList,scanGate,scanPallet}
/tenant/health                      /truckLoading/truckLoadingInfo
/unitLoad/search/findByItemForReplenish
/user/getAllRoles, /user/isWmsUser
```

## 4. THE ACTUAL LANDMINE — inheritance, not a caller

A per-handler gate on the 16 is safe for mobile. A **class-level** gate on `ReportController` is not.

**4.a All ten export handlers are declared on `ReportController`, not `DashboardController`.**
Verified per-name: `git grep -l '"/exportInventory"' origin/develop -- 'src/main/**/*.java'` →
`ReportController.java`, and identically for the other nine. `ReportController.java:31-32`:
`@RequestMapping("/v3/report")` / `public class ReportController extends AdminController`.

**4.b The two GETs mobile calls are declared on `DashboardController` itself** —
`DashboardController.java:48` `@GetMapping(path= "/orderMonitorViewSummary", …)` and `:116`
`@GetMapping(path= "/replenishMonitorViewSummary", …)`. They are **not** inherited from
`ReportController`. And `DashboardController.java:25-26`: `@RequestMapping("/v3/dashboard")` /
`public class DashboardController extends ReportController` — the dual-mapping the brief describes.

**4.c The guard falls back to a superclass-walking class-level lookup.**
`FunctionGuardInterceptor.java:166` binds the subject class as the *method's declaring* class:

```java
Class<?> declaring = handlerMethod.getMethod().getDeclaringClass();
```

then at `:207-209`:

```java
RequiresFunction annotation = methodLevel;
if (annotation == null) {
    annotation = AnnotationUtils.findAnnotation(declaring, RequiresFunction.class);
}
```

`RequiresFunction` is `@Target({ElementType.TYPE, ElementType.METHOD})` and **is not `@Inherited`** —
but that is irrelevant here, because Spring's `AnnotationUtils.findAnnotation(Class, …)` performs its
own traversal of the superclass/interface hierarchy (that is precisely its documented difference from
`getAnnotation`). So for an unannotated `DashboardController` handler, `declaring` is
`DashboardController`, the lookup walks up, and it **finds** any class-level annotation sitting on
`ReportController`.

**Consequence:** put `@RequiresFunction(WEB_UI_VIEW_…)` at class level on `ReportController` and
mobile's Replenish screen (`pages/replenish.vue`, two call sites) and Picking screen
(`store/picking.js:246`) start receiving 403s — via inheritance, with no mobile caller of any of the
16 anywhere in the picture. **Recommendation: gate the 16 per-method.** A method-level annotation on
each of the ten export handlers covers both URL prefixes uniformly (same declaring class for
`/v3/report/export*` and `/v3/dashboard/export*`) and cannot leak onto `DashboardController`'s own
handlers.

**4.d Second-order trap — the fail-closed branch makes this worse, not better.** At `:214-221`, if
no annotation resolves, an unannotated handler is allowed *unless* its declaring class is in
`GUARDED`, in which case it is **denied fail-closed**. `GUARDED` (`:112`) currently holds 14 classes
— `LookupController, PutawayController, MoveUnitloadController, MoveStockController,
PickingController, PalletizingController, TruckLoadingController, CycleCountLosController,
ReplenishController, TransferOrderController, OrderCancellationController, UserRoleController,
UserGroupController, UserController` — and **neither `ReportController` nor `DashboardController` is
among them**, consistent with the ticket's premise that these 16 are ungated today. If
`ReportController` is added to `GUARDED`, every unannotated handler whose declaring class is
`ReportController` denies; combined with 4.c, adding `DashboardController` would deny mobile's two
GETs outright.

**4.e A `WEB_UI_*` prefix is not itself disqualifying for mobile — there is precedent.** Worth
knowing before anyone argues the naming alone breaks mobile: the mobile UI already gates one of its
own screens on a `WEB_UI_*` function. `util/menuCatalog.js:88` `role: 'WEB_UI_VIEW_TRANSFER_ORDER'`,
with the deliberate note at `:83`: *"D4: deliberately a WEB_UI_* constant. No rename, no new
constant — it is a live row in mywms_function on every tenant, so renaming it needs a coordinated
data migration (§10.6)."* Same constant in `store/home.js:136`. Every other mobile menu entry uses
`MOBILE_UI_VIEW_*`. So mobile operators are already expected to hold a `WEB_UI_*` function, and the
real risk in SBDEV-3142 is 4.c's inheritance path, **not** the prefix.

Also relevant, from mobile's own client-side gate `middleware/require-function.js:9-12` — it names
this exact gap: *"Still uncovered on gated screens: `/v3/section*` … and `/v3/dashboard/*`. Both are
READS, so bypassing this middleware exposes data on those two, not a mutation … Tracked as
SBDEV-3017."*

## 5. Blind spots — what this method could NOT see

The headline is a completeness claim, and in this estate completeness claims are what break under
review while counts survive. **Method: exhaustive `git grep` over all 202 tracked files at
`origin/develop`, on ten axes (§2) — handler names, path families, path prefixes, leading segments,
dynamic construction, alternate invocation forms, transport config, a capability sibling-check, the
dependency manifest, and a full derived path inventory.** Its blind spots, explicitly:

1. **Runtime-computed paths — closed, but by inspection, not by proof.** Axis 5 found 47 dynamic-path
   sites; **every one has a static literal prefix** (`` `/replenish/checkSource/${id}/…` ``). The only
   three first-arg-is-a-variable sites were resolved by reading them:
   `pages/replenish.vue:154`/`:196` → `let url = '/replenishOrder/detailView?state=OPEN&…'` (SDR
   route, not one of the 16); `components/common/VersionBadge.vue:40` →
   `` `${base}/api/public/version` ``. Axis 6 confirmed **no** config-object form (`$axios({url:…})`),
   **no** `$axios.get(` non-shorthand form, **no** `$axios.$request`, and **no** module-level path
   constants. So there is no indirection layer where a path could be assembled out of sight — but
   this is a reading of 91 call sites, not a runtime trace.
2. **Shared npm package — closed.** `package.json` has no first-party/`@siteboss` dependency; all 17
   runtime deps are third-party (nuxt, vuetify, keycloak-js, axios-retry, moment, js-cookie…). No
   shared client library can smuggle a call in.
3. **Proxy / rewrite — closed.** `nuxt.config.js` has no `@nuxtjs/proxy`, no `proxy` block, no
   `rewrite`. `baseURL: process.env.API_BASE_URL || 'http://localhost:8088/v3'` and
   `browserBaseURL: process.env.API_BASE_URL`. **Residual:** `API_BASE_URL` is supplied at deploy
   time and I cannot see its production value; an nginx layer in front could in principle rewrite
   paths. I found no evidence of one, and none of the 16 paths would be produced by a prefix-only
   rewrite of the 77 paths mobile actually sends.
4. **WebView loading the web UI — closed.** No `<iframe>` and no WebView component embedding
   `wms2-web-ui`. The "WebView" mentions are about the handheld's *own* Android browser hosting this
   SPA (`store/moveStock.js:36`: *"On a handheld WebView served over plain HTTP…"*), not the mobile
   app embedding the web app. `pages/index.vue:189` `window.location.href = newUrl` is a
   tenant/warehouse switch to `` `${protocol}//${host}/mobile/` `` — the mobile SPA's own base, not
   the web UI. **Residual:** an operator can of course open the web UI in the handheld browser
   manually; that is a web-UI session holding web-UI functions, correctly out of scope here.
5. **Non-axios transports — closed.** Only two raw `fetch(` sites, both resolved:
   `plugins/tenant-auth-fetch.js:56` `` const url = `${baseUrl}/api/public/authConfig?key=${key}` ``
   (public bootstrap) and `plugins/initTenantAuth.client.js:147`, its caller. No `XMLHttpRequest`,
   no WebSocket, no service worker (`sw.*` is gitignored and none is committed).
6. **Freshness — the real residual.** This is `origin/develop` at
   `c79e81c3` / API `d434a3e5`. A branch pushed after my fetch, or an unmerged feature branch that
   adds a mobile export screen, is invisible to me. The measured lesson in this estate is that a
   sweep cannot catch a branch pushed later — **re-run axes 1–3 immediately before the gate merges.**
   That is cheap: three `git grep` commands.
7. **`git grep` sees only tracked files at that commit.** An untracked local file is out of scope by
   definition (it cannot ship), and §1 establishes nothing source-bearing is gitignored.
8. **Reflection/eval — not applicable.** No `eval`, no dynamic `import()` of a path table; the 77
   paths are all string literals in 20 files.

**What I am asserting, precisely:** across all 202 tracked files at `c79e81c3`, on ten independent
search axes, there is **no source expression that can produce a request to any of the 16 paths**, and
the mobile UI additionally lacks the download machinery any of the ten `/export*` handlers would
require. **What I am not asserting:** that no caller can ever exist — item 6 is the live gap, and
items 3's deploy-time `API_BASE_URL` is unobserved.

## 6. Bottom line for SBDEV-3142

1. **Gating the 16 does not 403 any mobile screen** — no mobile caller found, on two independent
   instruments (path greps; absence of any download capability).
2. **Gate them per-method, not class-level on `ReportController`.** A class-level annotation is
   inherited by `DashboardController` through `AnnotationUtils.findAnnotation` and would 403 mobile's
   Replenish and Picking screens (§4.c). This is the SBDEV-2968 R12 / SBDEV-3017 §1.3 landmine
   arriving through inheritance rather than through a caller.
3. **Do not add `ReportController`/`DashboardController` to `GUARDED`** as part of this ticket
   without annotating *every* handler on both, including `DashboardController`'s own 2 mobile GETs
   (§4.d fail-closed branch).
4. **The `WEB_UI_*` prefix is not itself a problem for mobile** — `WEB_UI_VIEW_TRANSFER_ORDER` is
   already a live mobile menu gate (§4.e).
5. **Re-run axes 1–3 right before merge** (§5.6).
