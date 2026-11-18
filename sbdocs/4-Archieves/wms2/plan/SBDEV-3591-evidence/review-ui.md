head: 72746f2

# SBDEV-3591 UI review: wms2-web-ui Status filter on the Parcel Picking Report

Reviewer: review-3591-ui (independent lane, not the authoring context). Date: 2026-10-29.
Scope: `git diff origin/develop...72746f2` in `.claude/worktrees/wms2-web-ui/SBDEV-3591`. That covers
`components/reports/parcelPickingReport.vue`, `store/reports/parcelPicking.js`, and the two new specs.
Tree state at the end: `git status --short` was empty, and both source files were restored from copies
(`cmp` showed them identical).

## Verdict: COMMENT (fix M1 before merge, which is small)

No High finding. There is one Medium functional defect (M1): the filter outlives navigation, unlike every
other piece of this report's state. There is one Medium test gap (M2): the page-reset test does not prove
that a page-1 fetch happens. The ACs are otherwise met.

## Stage 1: spec compliance (ClickUp ACs)

| AC | Result | Evidence |
|---|---|---|
| Status filter exists | PASS | `parcelPickingReport.vue:44-57` v-select `id="status"` |
| Picked selectable, shows only Picked | PASS | `statuses()` includes `{name:'Picked',code:600}`; `updateTable` sends `state: this.status`; the store appends `&state=600` (`parcelPicking.js:70-72`) |
| Clearing restores the normal set | PASS | The setter folds `undefined` to `null` (`newVal ?? null`), and `Number.isInteger` omits the param. "All Statuses" has `code: null`, so it takes the same path |
| Sort, Shipper, search, pagination, export unaffected | PASS, with M1 | Sort and shipper params are untouched. Export adds `state` only when it is an integer (`parcelPicking.js:99-100`), as the architect consult asked. It is not added in the shared `exportReport.vue` |

## Findings

### [Medium, HIGH confidence] M1: the Status filter is never reset when leaving the report, unlike Shipper, list and pagination
- `store/reports/parcelPicking.js:58-60` adds `resetStatusFilter(state) { state.statusFilter = null }`, but no
  code calls it. `grep -rn resetStatusFilter components pages store layouts plugins mixins` finds only the definition.
- `pages/reports/parcel-picking-report.vue:14-21` (`beforeRouteLeave`) resets `resetList`,
  `resetPagination` and `resetShipperFilter` when the user leaves `/reports/parcel-picking-report`. This
  commit did not change that file.
- `plugins/persistedState.client.js` reducer persists `reports` (allow-by-default, only `returnsAudit`
  is stripped). So `statusFilter` reaches localStorage and survives reloads and navigation until logout.
  That makes it more persistent than Shipper, which is reset on route leave.
- Failure scenario: the operator filters to Picked and goes to Outbound. Later, the same operator or the
  next shift on the same login opens the Parcel Picking Report. Search, sort, page and Shipper are back to
  defaults, but the list still shows only Picked parcels. The selected value is easy to miss in a 200px
  select, so the report looks like it has lost orders. The written-but-unused mutation suggests the author
  intended this wiring.
- Fix: add `this.$store.commit('reports/parcelPicking/resetStatusFilter')` beside `resetShipperFilter` in
  `pages/reports/parcel-picking-report.vue:19`. Add one test that runs the page's `beforeRouteLeave` with
  a `to.path` outside the section and asserts `statusFilter === null`. Add a second test where the path is
  inside the section and the filter is kept.

### [Medium, HIGH confidence] M2: the page-reset test passes even when no page-1 fetch is made; the harness's `options.page` is not reactive
- Test: `test/components/reports/parcelPickingStatusFilter.spec.js`, "changing the status from a later page
  goes back to page 1". It only asserts `expect(wrapper.vm.options.page).toBe(1)`.
- Cause: `created()` sets `this.options.page = pagination.page` on the `options: {}` data object. That is a
  plain assignment, so `page` is not reactive. The harness then calls `wrapper.setData({ options: {...} })`.
  VTU 1's `recursivelySetData` merges into the existing object and calls `vm.$set` on keys that already
  exist. `Vue.set` on an existing key is a plain assignment, so `page` and `itemsPerPage` stay non-reactive
  in the test, while `sortBy` and `sortDesc` become reactive. In production, the real `v-data-table`
  replaces `options` with a fully reactive object through `:options.sync`, so the app works. The harness
  does not reproduce that.
- Measured: a temporary probe spec (deleted afterwards) changed the status from page 3. It recorded
  **zero** `searchReport` dispatches after the change (`PROBE3 []`). On page 1 the same probe recorded
  `[[1,600]]`.
- Mutants that survive all 13 tests:
  - M4: `if (page !== 1) { this.updateTable(); this.options.page = 1 }`. This is a fetch with the stale
    page 3 followed by a reset. In production that sends two concurrent requests. If the page-3 response
    arrives last, it overwrites the table with an empty page and sets `totalItems`.
  - M3: `this.options.page = 1; this.updateTable()` with no branch. In production this double-fetches
    whenever page is not 1.
  - Killed: M1 (no reset), M5 (no `?? null`), M6 (range up to 650), and the store mutants S1 (drop export
    state), S2 (`!= null` guard) and S3 (truthy guard).
- Fix: build `options` reactively in the harness. One way is `wrapper.vm.options = { page, itemsPerPage,
  sortBy: [], sortDesc: [] }` (a whole-object replacement, as `.sync` does), instead of `setData`. Another
  is to declare `options: { page: 1, itemsPerPage: 10, sortBy: [], sortDesc: [] }` in data. That also
  removes the latent production reliance on v-data-table's first emit. Then assert that the searches made
  after the change are exactly `[{page: 1, state: 600}]`. That pins both "goes back to page 1" and "the
  fetch uses page 1, once".

### [Low, MEDIUM confidence] L1: the production page reset depends on v-data-table's first `update:options` making `options.page` reactive
- `parcelPickingReport.vue:396-403` relies on `this.options.page = 1` firing the deep `options` watcher.
  That works only because `options` was replaced through `.sync`. VData's `internalOptions` watcher is
  `immediate` and emits whenever the internal options differ from the prop. They always differ, because
  of `groupBy`, `mustSort` and similar keys. So in practice this holds. If the table is ever `v-if`-gated,
  or the sync is dropped, the status change at page > 1 would silently do nothing.
- Fix: covered by the M2 data-shape fix. Declare the option keys in `data()` so they are reactive from the start.

### [Low, HIGH confidence] L2: inconsistent page reset between the two filters (pre-existing on Shipper)
- `shipper(newVal) { console.log(newVal); this.updateTable() }` (`:392-395`) does not reset to page 1, but
  the new `status` watcher does. A probe changed the shipper from page 3 and the request went out as
  `[3,"X"]`. A narrower shipper list can therefore show an empty page 3. This existed before the change,
  and the new code is correct. The two filters now behave differently within one toolbar.
- Fix: in a follow-up, or on this ticket since it is sub-T3, give `shipper` the same reset branch. It
  should land with a test that uses the reactive harness from M2.

### [Low, MEDIUM confidence] L3: no guard against out-of-order responses (pre-existing, now easier to trigger)
- `searchReport` commits whatever response arrives last. Quick changes such as Picked, then Started,
  then All Statuses can leave the table showing an earlier filter's rows while the select shows the latest
  value. The same is true for shipper and keyword today.
- Fix (optional): add a request sequence number in `updateTable` and drop stale responses, or use an axios
  CancelToken as the export already does.

### [Low, HIGH confidence] L4: the 200..600 range is written inline, as magic numbers
- `CONSTANT.stateList.filter(s => s.code >= 200 && s.code <= 600)` (`:336`). The comment explains why, but
  it is tied to `order_detail_monitor_view`'s definition in wms2-api. If that view widens (for example to 650
  Packed), the UI will silently hide that option.
- Fix: name the bounds (for example `PARCEL_PICKING_MIN_STATE` / `MAX_STATE`) next to `stateList`, and
  cite the view or migration that defines them.

### [nit] N1: with no selection, the select shows "All Statuses" plus a clear icon instead of the placeholder
- `null` matches the `{code: null}` item, so Vuetify treats the field as dirty. It renders "All Statuses"
  with the clear icon visible, and `placeholder="Choose Status"` never shows. This matches the existing
  Shipper filter ("All Shippers", `clNr: null`), so it is consistent. Mentioned only because clearing
  "All Statuses" is a no-op.

### [nit] N2: the store test row `'All Statuses'` is a value the UI never emits
- In `it.each([[null],[undefined],['All Statuses']])` the string value is never produced by the
  component, because "All Statuses" carries `code: null`. It still has value: it is the row that kills
  the truthy-guard mutant S3. You could rename it to make that intent explicit, for example as a
  "non-integer is dropped" case.

## Things checked and found fine
- `searchUrlSync`: `status` is a computed property, so it is not in `$data` and cannot capture `?search=`.
  `keyword` still wins. No interaction.
- Clearing: Vuetify 2.6 clear emits `null` (older versions `undefined`). The setter folds both to `null`,
  and the M5 mutant is killed.
- When the status changes at page 1 there is exactly one fetch (`[[1,600]]`). At page > 1 in production,
  the options watcher fetches once. The `pagination` deep watcher writes `currentPage` (already 1) back,
  which is a no-op. There is no double fetch.
- Export: `state` is added in the store action and not in `exportReport.vue`. It is omitted when not an
  integer. This matches the architect consult. Shipper still travels as `filter` from the popup (pre-existing).
- Sort, shipper, keyword and pagination params in `updateTable` are unchanged. The Status column sort
  still uses `sortBy`.
- Style: no new `console.log`, comments carry the ticket tag, and the code matches the shipper pattern.
  `CONSTANT` is imported the same way as in sibling components.
- Tests run: `npx jest` on both specs gave 13/13 passing. The mutation results are listed under M2.

## Recommendation
COMMENT. Wire `resetStatusFilter` into `beforeRouteLeave` (M1) and make the page-reset test genuinely
observe the fetch (M2) before merge. Under the house rule, address L1-L4 in the same pass, or record why
they are deferred. L2 and L3 are pre-existing.

## Re-review of b6ea379
head: b6ea379

Scope: `git diff 72746f2 b6ea379`, limited to the fixes for M1, M2, L1-L4 and N1-N2. All three specs
pass 17/17. Mutants and probes were run from copies, restored with `cp`, and checked with `cmp`.
Temporary probe specs were deleted. `git status --short` is empty at the end.

### Per-finding verdicts

| Finding | Verdict | Evidence |
|---|---|---|
| M1 status filter survives leaving the report | **RESOLVED** | `pages/reports/parcel-picking-report.vue:20` commits `resetStatusFilter`. Mutant P1, which drops that line, is killed by `parcelPickingReportLeave.spec.js`. The spec also covers the in-section path, where the filter must be kept |
| M2 page-reset test passes with no reload | **RESOLVED** as a test gap; see NEW-1 for the over-claim | The harness now assigns a whole `options` object, so `page` is reactive. Exact request lists are asserted, so the stale-fetch-then-reset mutant is now caught |
| L1 reset depends on v-data-table's first sync | **RESOLVED** | `reloadFromFirstPage()` replaces `options`, which fires the deep watcher whether or not `page` was reactive |
| L2 Shipper doesn't reset to page 1 | **RESOLVED** | The `shipper` watcher calls `reloadFromFirstPage()`, and a new spec asserts `[[1,'WINECO']]`. Note that this changes Shipper behaviour, but the change was asked for. Restoring from the store in `created()` writes the same value, so the watcher does not fire there |
| L3 responses arriving out of order | **RESOLVED** for the success path; the catch branch is not tested (NEW-2) | `latestSearch` sequence: the new store test releases the older response last and asserts that the newer rows remain |
| L4 200/600 hard-coded | **RESOLVED** | `constantValues.parcelPickingStateRange` now holds the bounds and cites `V2.2.00__base_v2_schema.sql` |
| N1 "All Statuses" shown instead of placeholder | Kept on purpose, to match Shipper | Accepted |
| N2 the `'All Statuses'` row | **RESOLVED** | The rows are labelled, and the string row is now described as "a non-integer" |

### Lead's question 1: is the module-level `latestSearch` counter safe?
Yes. The concerns raised do not apply here.
- **SSR:** `nuxt.config.js:7` sets `ssr: false`. The store never runs on a server, so the counter cannot leak
  between requests or users. It would only become a cross-request leak if this app ever switched SSR on.
- **Store instances:** the browser creates one store per page load. `searchReport` has one caller,
  `parcelPickingReport.vue:474`. In Jest the counter is shared between tests in one file, but it only
  increases, and each test compares only its own calls. A test that left a request pending would still be
  safe: its late reply would simply be dropped.
- **Tabs:** each browser tab is a separate JavaScript runtime with its own module instance, so the counter is
  never shared between tabs. Within one tab, mounting the report twice at once is not possible with the
  current routes.
- Optional: moving the counter into module state, as a non-persisted field, would make it visible in devtools.
  It is not needed.

### Lead's question 2: can `reloadFromFirstPage` fetch twice after v-data-table re-emits? Yes, as measured
- Probe: a temporary spec mounted the **real** Vuetify 2.7.2 `v-data-table` with `:options.sync` and
  `server-items-length`, a deep `options` watcher that records every call, and `created()` restoring page 3.
  Replacing the object with `{...options, page: 1}` gave **`after [1,1]`**: the watcher fired twice.
  The old in-place approach (`options.page = 1`) also gave `[1,1]`. The reason is in `VData.js:187-204`:
  - The parent's replacement fires the parent's watcher, which makes fetch #1.
  - VData's `computedOptions` watcher then copies the new object into `internalOptions`, whose page changed
    from 3 to 1. `internalOptions` is not deep-equal to its old value, so it emits `update:options` with a
    new object.
  - `.sync` assigns that object back to the parent. A deep watcher fires whenever the reference changes, so
    the parent fetches again (#2).
  - After that, the two sides are deep-equal and the cycle stops.
- See NEW-1 for severity and the fix.

### On the trade-off: why not declare the option keys in `data()`?
I probed that variant against the real table. It declares `options: {page:1, itemsPerPage:10, sortBy:[],
sortDesc:[]}` and `created()` sets page 3. It produced **one** initial watcher run (`init ["3"]`), not
two. Vue queues a watcher only once per flush, and VData's immediate first emit happens during the same
mount tick. The feared extra initial fetch did not happen in this simplified parent. The probe did not
include the store or the `pagination` watcher, so I rate this MEDIUM confidence. Either design is
acceptable. Replacing the object is also correct, so I would not switch. Neither design avoids the
double fetch in question 2.

### New findings

**[Low, HIGH confidence] NEW-1: "exactly one load" holds only in the stubbed harness. The real table loads page 1 twice.**
- The tests "changing the status/shipper from a later page makes exactly one load, of page 1" stub
  `v-data-table`, so the re-emit described in question 2 never happens. In production, every page>1 filter
  change sends two identical `GET /report/parcelPickingView?page=0&...` requests. The old code did the same.
  The keyword watcher (`this.options.page = 1; this.updateTable()`, unchanged) can send three.
- Impact: one wasted request per change. The display is correct, because the requests are identical and
  `latestSearch` keeps the last one. That is why this is Low.
- Fix: in the `options` handler, skip `updateTable()` when page, itemsPerPage, sortBy and sortDesc
  are unchanged from the last load. Store a key such as
  `JSON.stringify([page, itemsPerPage, sortBy, sortDesc])` and compare against it. The probe confirmed the
  second run has a key identical to the first (`["1","1-dup"]`). Also route the keyword watcher through
  `reloadFromFirstPage()`. Alternatively, keep the code and rename the tests to "the first load after the
  change is page 1" with a comment that the stub hides the table's re-emit, so the test name does not
  claim something production does not do.

**[Low, HIGH confidence] NEW-2: the guard that drops a superseded failed request is not tested**
- `store/reports/parcelPicking.js` catch branch: `if (search !== latestSearch) return`. Mutant C1 removes
  that line and all 17 tests still pass. Without the guard, an older request that fails after a newer one
  succeeded shows a false "Request failed" toast over correct data.
- Fix: add a test that rejects the older call last and asserts `$toast.error` was not called.

**[Low, MEDIUM confidence] NEW-3: a superseded search turns off the loading spinner too early (pre-existing pattern, not regressed)**
- `updateTable` does `this.loading = true; await dispatch(...); this.loading = false`. A superseded search
  now returns early, so the first `await` to finish sets `loading = false` while the newest request is still
  running. This also happened before the change, and the counter does not make it worse.
- Fix (optional): keep a component-side counter and turn `loading` off only for the latest call.

### Re-review recommendation
**APPROVE.** M1, M2, L1, L2 and L4 are resolved. L3 is resolved but the error path is not tested (NEW-2).
No new High or Medium finding. Under the address-Lows rule, NEW-1 (dedupe, or rename the tests) and NEW-2
(one test) should land in this pass, and NEW-3 is optional.

## Re-review of aaf67fc
head: aaf67fc

Scope: `git diff b6ea379 aaf67fc`, which fixes NEW-1, NEW-2 and NEW-3.
- The three specs pass 19/19.
- Mutants and probes ran from copies. Source files were restored with `cp` and checked with `cmp`.
- The temporary probe spec was deleted, and `git status --short` is empty at the end.

### Real-table probe (Vuetify 2.7.2)
I mounted the **actual** `parcelPickingReport.vue` with the real `v-data-table` and `v-pagination`, using
`mount` with real Vuetify, not `shallowMount`. A fake `searchReport` records each load and commits
`setPagination` and `setReportItems` (totalItems 100), the same way the real action does.
`searchReport` dispatches recorded as `[page, itemsPerPage, sort, state, clientNumber]`:

| Scenario | Loads |
|---|---|
| initial mount, store page 1 | `[[1,10,null,null,null]]`: one |
| initial mount, store page 3 (restored in `created()`) | `[[3,10,null,null,null]]`: one |
| status 600 from page 3 | `[[1,10,null,600,null]]`: **one** (b6ea379 gave two) |
| status change on page 1 | `[[1,10,null,500,null]]`: one |
| user sort click (VData `internalOptions.sortBy` set) | `[[1,10,"state",500,null]]`: still reloads |
| itemsPerPage 10 to 20 (VData `internalOptions`) | `[[1,20,"state",500,null]]`: still reloads |
| v-pagination to page 2 (`currentPage` + `pageChanged`, through the `pagination` watcher) | `[[2,20,...]]`: one |
| v-pagination back to page 1 | `[[1,20,...]]`: one |
| shipper on page 1 | `[[1,20,"state",500,"WINECO"]]`: one |
| then paging to page 2 (a filter change on page 1, then the same paging) | `[[2,20,"state",500,"WINECO"]]`: one, not suppressed |
| clearing status from page 2 | `[[1,20,"state",null,"WINECO"]]`: one |
| after all of the above | `options.page 1`, `loading false` |

**Positive control:** the same probe run against the b6ea379 component, swapped in by copy and then
restored, gave `status from p3 [[1,600],[1,600]]`. This shows the probe can detect a double load, and that
aaf67fc's single load is a real fix.

### Can the dedupe suppress a needed reload?
I traced every path that writes `options` or calls `updateTable`. None of them suppresses a needed reload.
- **The key ignores the filters, by design.** Every filter goes through `reloadFromFirstPage()`: keyword
  (now), shipper and status.
  - On page 1 it calls `updateTable()` directly, with no dedupe.
  - On a later page it changes `page`, so the key differs from the last load, which used that later page.
  - The two can only collide if `options.page` moved away from 1 without a load. Any reactive change of
    `options` to a new key runs a load and records that key. The only non-reactive window is before the
    first `.sync`, and no filter can change then because nothing is rendered yet.
- **`pagination` watcher (`options.page = currentPage`).** After the page-2 click, `currentPage` is already
  2, so the key changes and the page reloads (probe row 7). After `searchReport` commits
  `setPagination`, the watcher writes the same page back. That is a no-op, and skipping it is correct.
- **Restoring from the store in `created()`.** This writes to a non-reactive `options`, and the first
  `.sync` emit makes the single load. `lastLoadKey` starts as null, so that first load cannot be skipped
  (probe row 2).
- **`searchUrlSync.getSearchFromUrl`** calls `updateTable()` directly, so it bypasses the dedupe.
- **A failed load.** `lastLoadKey` is recorded before the request goes out. The same paging after a
  failure would not refetch through the watcher. But the watcher never fired for identical values before
  this change either, and the user can still retry by changing any filter or page. No regression.

### Per-finding verdicts

| Finding | Verdict | Evidence |
|---|---|---|
| NEW-1: double load after a page reset | **RESOLVED** | Real-table probe: one load, where b6ea379 gave two. The keyword watcher now uses `reloadFromFirstPage()`. In the harness, `tableReEmitsOptions` reproduces the measured re-emit |
| NEW-2: superseded failure shows a toast | **RESOLVED** | The new store test makes the older request reject last and asserts no `$toast.error` and that the newer rows remain. The lead reports mutant V2 is killed |
| NEW-3: spinner turns off too early | **RESOLVED** | `loadSeq` guards `loading = false`. The new test resolves the older load first, then checks that `loading` is still true and becomes false only after the newer load. Probe end state: `loading false` |

### New findings

**[Low, HIGH confidence] R1: no test protects the dedupe from swallowing sort or itemsPerPage reloads**
- Mutants on `optionsKey` (`parcelPickingReport.vue`, `JSON.stringify([options.page, options.itemsPerPage,
  options.sortBy, options.sortDesc])`):
  - K1 reduces the key to `[options.page]`. All **19/19 pass**. In production, a sort click or a page-size
    change on the same page would then do nothing.
  - K2 reduces the key to `[page, itemsPerPage]`. All **19/19 pass**, and sort clicks would be suppressed.
  - K3 uses a constant key. 2 tests fail, so it is caught.
- The production code is correct today (probe rows 5-6). But the dedupe can now suppress reloads, and its
  key fields are not pinned by any test. Someone trimming that key later would get no red.
- Fix: in the harness, add two cases from a settled state:
  - assign `options = {...options, sortBy:['state'], sortDesc:[false]}`, expect one load with `sort: 'state'`;
  - assign `options = {...options, itemsPerPage: 20}`, expect one load with `itemsPerPage: 20`.
  
  Both should kill K1 and K2.

**[nit] R2: `lastLoadKey` and `loadSeq` are bookkeeping but are declared reactive in `data()`**
- The template never reads them, so every load does a little unneeded reactive work. Neither name is in
  `searchUrlSync`'s `possibleProps`, so there is no conflict there. Optionally assign them in `created()`
  as non-reactive fields (`this.lastLoadKey = null`). Harmless as is.

### Re-review recommendation
**APPROVE.** NEW-1, NEW-2 and NEW-3 are resolved, and the real-table probe confirms one load per change,
with sort, page-size, paging and mount loads all intact. Under the address-Lows rule, add the two R1 cases
in this pass. R2 is optional.

## Re-review of 21e76a5
head: 21e76a5

Scope: `git diff aaf67fc 21e76a5`, the fixes for R1 and R2.
- The three specs pass 21/21.
- Mutants and the probe ran from copies. Files were restored with `cp`, `cmp` confirmed them identical,
  and the temporary probe spec was deleted.
- `git status --short` is empty at the end.

### Lead's question 1: is `loadSeq` always initialised before `++this.loadSeq`?
**Yes.** In Vue 2, `initState` registers the data, computed properties and watchers. Then `created`
hooks run: the mixin's first, then the component's. Every route into `updateTable` happens after the
component's `created()` has finished:
- **options, pagination, shipper and status watchers:** none uses `immediate`
  (`grep immediate` finds only `searchUrlSync`'s unrelated `updateUrlWithSearch` parameter). They are
  queued and run on the next flush.
- **keyword watcher:** also queued, then delayed a further 700 ms by `setTimeout`.
- **`searchUrlSync.getSearchFromUrl`:** this runs in the mixin's `created`, before the component's
  `created`. It calls `this.$nextTick(() => this.updateTable())`, which is deferred to a later microtask.
- **The restore inside the component's `created()`:** it only assigns state (`keyword`, `options.*`,
  `shipper`). Any watcher it triggers is queued, so nothing calls `updateTable` synchronously.

Probe after mount: `seq 1`, `loading false`. Mutant I1 deletes `this.loadSeq = 0`, which makes
`++undefined` produce NaN, so the spinner never turns off. The spinner test catches it.

### Lead's question 2: real-table probe, re-run on 21e76a5
I mounted the actual component with the real Vuetify 2.7.2 `v-data-table` and `v-pagination`. Each case
made exactly one load:
- mount at page 1, and mount restoring page 3 from the store;
- status change from page 3 (`[1,…,600]`) and status change on page 1;
- sort click; page-size change from 10 to 20;
- v-pagination to page 2;
- shipper change from page 2 (back to page 1), then paging to page 2;
- clearing the status from page 2. The spinner was off afterwards.

These results match aaf67fc, so the R2 move did not change behaviour.
- The probe also mounted with `?search=ABC`. That gave 2 loads, both with `keyword ""`. This is a
  separate, pre-existing problem; see P1.

### Per-finding verdicts

| Finding | Verdict | Evidence |
|---|---|---|
| R1 dedupe key not pinned | **PARTIALLY RESOLVED** (see R3) | K1 (`[page]`) is caught by 2 tests and K2 (`[page, itemsPerPage]`) by 1 |
| R2 bookkeeping fields are reactive | **RESOLVED** | Both are plain instance fields set at the top of `created()`, initialised before any `updateTable` (question 1). The comment explains why |

### New findings

**[Low, HIGH confidence] R3: dropping `sortDesc` from the dedupe key goes undetected**
- Mutant K4: `JSON.stringify([options.page, options.itemsPerPage, options.sortBy])`. All **21/21 pass**.
- Why: the new `it.each` "a new sort" case changes `sortBy` (to `['state']`) and `sortDesc` together, so
  the `sortBy` change alone makes the key differ.
- Failure scenario: clicking a column that is already sorted toggles only `sortDesc`, from asc to desc.
  With K4 the dedupe would swallow that reload, and the arrow would flip while the rows stayed in the
  same order.
- Fix: add a row that starts from a sorted state and changes only the direction:
  `['a sort direction flip', { sortDesc: [true] }, …]`, with `sortBy` already `['state']` before the change.
  It should kill K4.

**[Low, HIGH confidence] P1 (pre-existing, not from this ticket): the `?search=` deep link is overwritten on this report**
- `searchUrlSync`'s `created` runs first and sets `this.keyword = 'ABC'` from the URL. The component's
  `created()` then runs `this.keyword = list.search` (`parcelPickingReport.vue`, the same line on
  `origin/develop`) and resets it to the stored `''`.
- Measured: mounting with `?search=ABC` gives `[[1,10,…,""],[1,10,…,""]]`. Both loads have an empty
  keyword: one from the mixin's direct `$nextTick(updateTable)` and one from the options sync. The direct
  call bypasses the dedupe.
- Impact: a link to this report with `?search=` shows the unfiltered list. I did not find a caller that
  deep-links this report today; SBDEV-2658's toast targets Stock Unit Record. So the impact is latent.
- This is outside SBDEV-3591's ACs. Per the ticket policy (sub-T3, ticket not yet `on dev`), it may go on
  this ticket or be left. The cheapest fix is to restore `keyword` from the store only when it is empty:
  `if (!this.keyword) this.keyword = list.search`. Add a test that mounts with `?search=` and expects one
  load carrying that keyword.

### Re-review recommendation
**APPROVE.** R2 is resolved. R1 is resolved apart from R3, a one-row test addition. Lead's question 1 is
confirmed by lifecycle analysis and mutant I1, and question 2 by the real-table probe. P1 is pre-existing
and optional for this ticket.

## Re-review of 80ce5d3
head: 80ce5d3

Scope: `git diff 21e76a5 80ce5d3`. It is test-only: one new case in
`test/components/reports/parcelPickingStatusFilter.spec.js`. The three specs pass 22/22. Mutants ran
from a copy and the file was restored (`cmp` showed it identical). `git status --short` is empty at the end.

### Per-finding verdicts

| Finding | Verdict | Evidence |
|---|---|---|
| R3 `sortDesc` not pinned in the dedupe key | **RESOLVED** | The new case sorts by `state` ascending, then flips only `sortDesc`, and expects exactly `[['state','desc']]` after the flip. Mutant K4 (key without `sortDesc`) fails 1 test, where it failed none before |
| P1 `?search=` deep link overwritten | **DEFERRED to the ClickUp ticket; accepted** | It predates this ticket and needs a sweep across components. My census: `grep -rln "this.keyword = list.search" components` finds **11** components. That is the 8 the lead counted under `components/reports/`, plus 3 outside: `handlingUnits/containerTable.vue`, `handlingUnits/stockUnitsTable.vue` and `masterData/material/skuData/skuData.vue`. Add these 3 to the ticket note so the sweep covers them |

### New finding

**[Low, HIGH confidence] R4: dropping `sortBy` from the dedupe key goes undetected (the mirror of R3)**
- Mutant K5: `JSON.stringify([options.page, options.itemsPerPage, options.sortDesc])`. All **22/22 pass**.
- Why: the "a new sort" row changes `sortBy` (`[]` to `['state']`) and `sortDesc` (`[]` to `[true]`)
  together, so the `sortDesc` change hides a missing `sortBy`.
- Failure scenario: the report is sorted ascending by column A, and the user clicks column B. Vuetify
  emits `sortBy: ['B']` with `sortDesc` still `[false]`. With K5 the dedupe would swallow that reload.
  The header would show B sorted while the rows stayed ordered by A.
- Production code is correct today, because the key includes `sortBy`. This is a test gap only.
- Fix: one row, the mirror of the R3 case. Start sorted by `state` ascending, change to
  `sortBy: ['priority']` with `sortDesc: [false]` unchanged, and expect one load `[['priority', null]]`.
  It should kill K5.

### Re-review recommendation
**APPROVE.** R3 is resolved, and deferring P1 to the ticket is reasonable, with the 3 non-report
components added to the census. The production code has no open finding. R4 is a test gap of the same
kind as R3, and a one-row addition. Under the address-Lows rule it belongs in this pass, but it does not
need another review round. The mirrored row and a passing run would be enough.

## Re-review of dffa18b
head: dffa18b

Scope: `git diff 80ce5d3 dffa18b`. It adds the R4 test and replaces the hand-rolled `latestSearch` counter
in `store/reports/parcelPicking.js` with the existing `util/latestRequest.js` `createLatestRequest`.
- The three SBDEV-3591 specs plus `test/util/latestRequest.spec.js` pass 31/31.
- Running the whole `test/util` folder, the only failing suite is `telemetry.spec.js`: it cannot find
  `@openobserve/browser-rum`, which is the known failure that also happens on develop.
- Mutants ran from copies, both files were restored (`cmp` showed them identical), and
  `git status --short` is empty at the end.

### Per-finding verdicts

| Finding | Verdict | Evidence |
|---|---|---|
| R4 `sortBy` not pinned in the dedupe key | **RESOLVED** | The new case starts at `state` ascending and switches to `priority` with the direction unchanged, expecting exactly `[['priority', null]]`. Mutant K5 (key without `sortBy`) now fails 1 test, where it failed none before |
| P1 `?search=` deep link | Deferred; the 11-site census is confirmed by the lead | No action needed in this PR |

### Is `createLatestRequest` equivalent to the old counter?
**Yes on every point the lead asked about.** One change is an improvement.
- **Sequence point:** the old code ran `++latestSearch` synchronously before `try`. `run()` is an async
  function, so its `++latest` also runs synchronously when it is called, before the first `await`. The
  order of increments relative to other dispatches is the same.
- **Superseded success:** `run` returns `{stale: seq !== latest, value}` and the caller does
  `if (stale) return` before `commit`, so a superseded success cannot commit. Mutant W1 (removing
  `if (stale) return`) fails both overlap tests. Mutant W2 (bypassing the helper with an always-fresh
  wrapper) also fails both, so the tests depend on the helper's staleness logic, not on the wrapper.
- **Superseded rejection:** the helper resolves it as `{stale: true, error}`, so it never reaches the catch
  and no toast is shown, which matches the old catch guard. The latest rejection is rethrown, caught, and
  shown as the toast, the same as before. A synchronous throw from the factory, such as a broken `$axios`,
  is caught inside the async `run` and handled by the same rule.
- **Staleness timing:** the old code checked staleness in the action after the `await`. The helper checks
  it inside `run` when the value arrives, and the caller reads it one microtask later. A newer dispatch
  cannot start between those two points, because user events are macrotasks. Even if it could, the
  newer result would still be committed last. No observable difference.
- **Scope:** one tracker per store module, at module level, the same as the old `let latestSearch`. The
  helper's doc asks for one tracker per logical request stream, and `skuLocation.js:6` follows the same
  pattern. With `ssr: false` (`nuxt.config.js:7`) and one store per page load, the earlier SSR and
  multi-tab analysis is unchanged. Separate trackers per module mean a slow skuLocation search cannot mark
  a parcelPicking search stale. That is correct.
- **Improvement:** the hand-rolled guard was duplicated in both branches. The shared helper has its own
  spec (`test/util/latestRequest.spec.js`), and this action now uses the same idiom as skuLocation and
  returnsAudit.
- `invalidate()` is not used. A response that arrives after the user leaves the report still commits into
  the module. The old counter behaved the same, and the next visit reloads from scratch. No regression, so
  no finding.

### New findings
None. The diff touches only the import, the tracker and the call site, and the new code follows the
skuLocation idiom.

### Re-review recommendation
**APPROVE.** R4 is resolved, and the helper reuse is behaviour-equivalent to the reviewed counter on the
success path, on both rejection paths and on sequencing. It is also tested by the new overlap tests and the
helper's own spec. No open finding remains in the SBDEV-3591 UI change. P1 is tracked on the ticket.
