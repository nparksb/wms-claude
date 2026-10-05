# SBDEV-3410 P6 — code review (UI, `wms2-web-ui`)

- **Lane:** independent code review, P6 only
- **Reviewed:** worktree `/Users/np1076/dev/spk/owl/.claude/worktrees/wms2-web-ui/SBDEV-3410-p6`,
  branch `feature/SBDEV-3410-p6-shipper-filter-and-sku-name`, base `origin/develop` @ `9254bf5`
- **Files:** `.gitignore`, `components/reports/stockUnitRecord.vue` (459 lines),
  `store/reports/stockUnit.js` (168 lines), untracked
  `test/components/reports/stockUnitRecordShipperFilter.spec.js` (471 lines)
- **Date:** 2026-09-23

⚠ **The working tree moved while this lane ran.** I started from `/tmp/p6.diff` (spec at 404 lines)
and re-read the tree before writing up; by then the verifier lane had added four cases (F1–F4) to
the spec and the component's `shipper` computed comment had been rewritten. **All line numbers below
are against the tree as of the re-read** (component 459 lines / spec 471 lines). One of my findings
(L2) was fixed by that concurrent edit and is marked RESOLVED. Nothing else changed.

**Constraints honoured:** no `git checkout --` / `git restore` / `git stash`; **no jest run** (a
suite and its baseline are running elsewhere). Everything is derived by reading the worktree,
`origin/develop` and the plan. Where a claim needs a run to clinch it, it is labelled SUSPECTED and
the exact measurement is named in §4.

**Verdict: do not merge as-is.** One HIGH (the `.gitignore` narrowing points at the wrong directory
and un-ignores real generated output), three MEDIUM, twelve LOW + one RESOLVED. The core of the
phase — the `-1`/`null` fold, the route split, `rowsOf`, the `String(...)` prop, the
computed-not-`data()` rule — is correct and matches §3.6/§3.9. Nothing here disputes the design.

---

## 1. Findings

### H1 — `.gitignore` now ignores a directory nothing writes to, and stops ignoring the one that is written **[HIGH · VERIFIED]**

`.gitignore:106-111` replaces `reports/` with `cypress/reports/`.

The Cypress Excel reporter does **not** write to `cypress/reports/`. It writes to the repository
root:

```js
// cypress/support/reporter/excelReporter.js:178-183
const out = path.join(process.cwd(), 'reports');
fs.mkdirSync(out, { recursive: true });
…
const file = path.join(out, prefix + '-' + stamp + '.xlsx');
```

Corroborating evidence, all in-repo:

- `cypress/support/reporter/excelReporter.js:1` — *"Writes a timestamped workbook to reports/."*
- 15 spec headers say `// Output: reports/scenario…-*.xlsx`
  (`cypress/e2e/wms/scenario1-hybrid/step0a-create-order-api.cy.js:22` and siblings).
- `find . -type d -name reports` returns exactly four directories — `pages/reports`,
  `store/reports`, `components/reports`, `test/components/reports`. **There is no `cypress/reports`
  and nothing in the repo creates one.**
- Every `cypress run` script in `package.json:15-54` runs from the repo root, so `process.cwd()`
  is the repo root.
- `.gitignore` carries no `*.xlsx` rule and nothing else covering `<root>/reports/`
  (`grep -n "xlsx\|^/reports\|coverage" .gitignore` → only the unrelated `coverage` entries).

**Effect as written:** after any Cypress run the generated `.xlsx` workbooks at `<root>/reports/`
become untracked-and-visible, appear in `git status`, and are one `git add -A` from being
committed. The rule that was preventing that is the one being removed. The comment's closing
sentence — *"Scoped to the Cypress output it was written for"* — is false.

**Everything else in that comment checks out.** Blame confirms the premise: `reports/` was added by
`752f8ce "Add Cypress test suite covering OMS, WMS, and SiteBoss Admin"` on **2026-07-10**, inside
the `# Cypress` block, while `store/reports/stockUnit.js` has been tracked since **2024-07-16**
(`3462148`) — so *"the 32 files already there were tracked before the rule"* is exactly right, and
the diagnosis that the first genuinely new file in any source `reports/` directory is silently
dropped from its commit is right too.

**Fix — one character, not a different line:**

```gitignore
/reports/
```

A leading slash anchors the pattern to the `.gitignore`'s own directory, so it matches
`<root>/reports/` and **not** `components/reports/`, `store/reports/`, `pages/reports/` or
`test/components/reports/`. That satisfies the phase's actual blocker (its own spec was being
ignored) and keeps the reporter output ignored. The comment's last sentence should then say the
rule is *anchored to the repo root*, not *scoped to Cypress*.

**Scope: keep it in P6.** It is not in §10.4 and is not a plan task, but it is a blocker for P6's
own deliverable — without it the implementation commits without its spec, and splitting it out
means merging P6 with the test file missing. Record it on the ticket as an in-phase incidental,
with the `/reports/` form and the `excelReporter.js:178` citation, so nobody re-narrows it later.

Side benefit worth recording: the bare rule also made `ugrep`/ripgrep skip all 32 tracked source
files under those directories (this repo's known `git grep`-not-`grep` trap). The anchored form
fixes that too.

---

### M1 — a shipper change from any page ≠ 1 fires the whole fetch twice **[MEDIUM · VERIFIED by reading]**

`components/reports/stockUnitRecord.vue:346-349`:

```js
shipper() {
  this.options.page = 1
  this.updateTable()
},
```

Once `v-data-table` has synced `:options.sync` (`stockUnitRecord.vue:58`), `options` carries a
reactive `page`. So when the user is on page 7 and picks a shipper:

1. `this.options.page = 1` mutates a reactive property → queues the `options` deep watcher
   (declared at `:314`).
2. `this.updateTable()` runs synchronously → GET #1 (already with `page` 1) + `getClients` #1.
3. The `options` watcher is declared at **314**, the `shipper` watcher at **346**, so `options` owns
   the lower watcher id. Vue 2's `queueWatcher` splices a watcher queued *during* a flush by id, and
   a lower id already passed runs immediately next — so the `options` handler runs right after,
   ending in its own `this.updateTable()` (`:328`) → GET #2 + `getClients` #2.

Four requests where one is wanted, two of them against the query §3.10 measured at 1.8 s filtered /
7.8 s unfiltered. Clearing the filter from page ≠ 1 fires the unfiltered 7 s query twice.

This is the same shape as the pre-existing `keyword` watcher (`:299-313`), and §5.2 P6 told the
implementer to mirror it — so it is inherited, not invented. Worth fixing here anyway, because the
filter is the one control a user will toggle repeatedly against an expensive query.

Minimal fix that keeps the stubbed-table tests working. Note `options` starts as `{}`
(`:157`), so a pre-sync `page` assignment is a non-reactive property *add* and fires no watcher — a
naive `if (page !== 1)` guard would silently stop fetching in every test:

```js
shipper() {
  const noOptionsWatcherWillFire = this.options.page === 1 || this.options.page === undefined
  this.options.page = 1
  if (noOptionsWatcherWillFire) this.updateTable()
},
```

---

### M2 — the "resets the page to 1" assertion is vacuous **[MEDIUM · VERIFIED]**

`stockUnitRecordShipperFilter.spec.js:191` asserts `expect(wrapper.vm.options.page).toBe(1)`.

`reportHarness` hard-codes the store pagination at `page: 1` (`spec:74`) and exposes no way to
override it — `list` is the only settable key. `created()` then copies it into the component
(`stockUnitRecord.vue:437`: `this.options.page = pagination.page`). So `options.page` is **already 1
before the watcher runs**, in every test in the file.

Deleting `this.options.page = 1` from the `shipper` watcher leaves the whole suite green. §5.2 P6
lists *"Reset the page to 1 when the shipper changes"* as a task and §7.4 requires the spec to
assert it; nothing grades it today. This is the third mutant in this phase and it is the one that
was not checked. (The verifier lane's F1–F4 additions do not touch it.)

Fix: let `reportHarness` take a `pagination` override (default as today), seed `{ page: 7 }` in that
one test, and assert the transition 7 → 1. Under the stubbed `v-data-table` the watcher's assignment
is a non-reactive add, so M1's duplicate fetch will not appear in the test — the assertion stays a
clean single-behaviour pin.

---

### M3 — `searchReport` takes `clientId` from the payload first, which the plan forbids, on a justification that is not true **[MEDIUM · VERIFIED]**

`store/reports/stockUnit.js:102-103`:

```js
const fromPayload = data && data.clientId
const clientId = (fromPayload ?? context.state.list.clientId) ?? -1
```

**The arithmetic is correct.** I walked every input the lead asked about:

| `data` | `fromPayload` | resulting `clientId` | right? |
|---|---|---|---|
| `undefined` | `undefined` | `state.list.clientId ?? -1` | ✔ |
| `null` | `null` | `state.list.clientId ?? -1` | ✔ |
| `{}` | `undefined` | `state.list.clientId ?? -1` | ✔ |
| `{clientId: 0}` | `0` | **`0`** | ✔ — `0 ?? x` is `0`; **`0` is never folded to "no filter"** |
| `{clientId: -1}` | `-1` | `-1` → unfiltered branch | ✔ |
| `{clientId: null}` | `null` | falls back to **state**, not to `-1` | see L7 |

The lead's belief is **confirmed**: `data = {clientId: 0}` yields `0`, and `0` reaches the filtered
branch. No path folds client id 0 onto "no filter" — not here, not in `setFilters` (`store:38`,
where `payload && payload.clientId` also yields `0` and `0 ?? -1` is `0`), not in the computed's
getter (`stockUnitRecord.vue:277-279`, `(id == null || id === -1) ? null : id`) or its setter
(`:281-285`, `newVal == null ? -1 : newVal`). §3.6's rule holds at all four sites.

**What is wrong is the branch existing at all.** §3.9 specifies `const clientId =
context.state.list.clientId ?? -1` and §5.2 P6 repeats *"appends `&clientId=` **from state**"*. The
implementation adds a payload override the plan does not have, and justifies it in the comment
(`store:99-100`) with:

> *"Read from STATE, not from `data`: this action is also reached by payload-less refreshes"*

**There are no payload-less refreshes.** `git grep "reports/stockUnit/searchReport"` returns exactly
one dispatcher — `stockUnitRecord.vue:388` — and it always passes a full payload including
`clientId` (`:402`). A genuinely payload-less call could not work anyway: `store:93` dereferences
`data.page` before anything else, so `data === undefined` throws a `TypeError` nine lines above the
comment.

The `data.clientId` arm is therefore unreachable-by-construction dead code that creates a second
source of truth for the filter, explained by a call that cannot happen. The spec's
`it('keeps the filter on a payload-less refresh …')` (`spec:421`) reinforces the wrong mental model
— it passes a payload *without* `clientId`, which is also something no caller produces.

Fix: reduce to the plan's form (`context.state.list.clientId ?? -1`), drop the `clientId` key from
`updateTable`'s dispatch payload (`stockUnitRecord.vue:402`), and rename that test to what it
actually pins (*reads clientId from state, not from the payload*). If the override is kept
deliberately, the comment must say why in terms that are true, and §5.2 P6's bullet needs amending.

---

### L1 — `setFilters`'s comment names a rule the codebase breaks **[LOW · VERIFIED]**

`store/reports/stockUnit.js:31-35` claims *"every in-component caller copies the existing list
first"*. `layouts/default.vue:490` does not:

```js
// stockUnit
this.$store.commit("reports/stockUnit/setList", { search: "" });
```

That fires from the layout's `$route` watcher when the top-level route section changes
(`layouts/default.vue:366-379`) and replaces `state.list` wholesale — dropping `sortBy`, `sortDesc`
and now `clientId`.

The **behaviour is fine**: `state.list.clientId` becomes `undefined`, the getter's `id == null` arm
returns `null`, and `searchReport`'s trailing `?? -1` catches it. So `?? -1` really is load-bearing
— but for the reason the comment denies, not the one it gives. Rewrite it to cite
`layouts/default.vue:490` as the caller that makes the fallback necessary.

### L2 — "cross-navigation persistence" claim **[RESOLVED during this review]**

The `shipper` computed's comment used to claim *"It also gives the filter the cross-navigation
persistence the other report filters have"*, which is false on both halves. It was rewritten
(now `stockUnitRecord.vue:267-273`) while this lane was running. **I verified the replacement and it
is accurate**: all six named pages commit `resetShipperFilter` at line 19 of
`pages/reports/{inventory,lock,receiving,flowbin,sku-location,parcel-picking}-report.vue` (checked
individually), and `pages/reports/stock-unit-record.vue:17` commits `resetList`, which this phase
made clear `clientId` (`store:48`). No change requested. ⚠ §3.9 still carries the original false
sentence — fix it in the plan too, or the next port re-imports it.

### L3 — the `getClients` dispatch moved, and its comment describes where it used to be **[LOW · VERIFIED]**

`stockUnitRecord.vue:391-393` puts the dispatch inside `updateTable()` and says it *"Fires on every
table option change, matching the sibling reports."* `inventoryReport.vue:280` puts it in the
`options` deep watcher — and §3.9 says *"inside the `options` deep watcher, as `inventoryReport.vue`
does"*. From `updateTable()` it fires on every option change **plus** every 700 ms keyword debounce
**plus** every shipper change (twice per change, per M1). Either move it to the `options` handler as
the plan specifies, or change the comment to state the larger set. The Caffeine cache absorbs the
cost either way; the defect is the claim, not the traffic.

### L4 — the `sortBy = []` default is right, but its comment overclaims and the guard is partial **[LOW · VERIFIED]**

`stockUnitRecord.vue:377-381`. The default itself is the correct fix, not a mask: `options` is `{}`
in `data()` (`:157`) and Vue 2 cannot make `created()`'s property *additions* reactive, so before
`v-data-table` emits its first `update:options` there is genuinely no `sortBy` and `sortBy.length`
throws.

Two corrections:

1. *"the SBDEV-3410 shipper watcher fires synchronously on change and so reaches here earlier, where
   `sortBy.length` threw"* is demonstrated **in jest only**. In a browser the `shipper` computed can
   change only via the autocomplete (rendered alongside the table, which has already synced) or via
   the route-change commits in `layouts/default.vue` / `beforeRouteLeave` (which are destroying the
   component). I could not construct a browser path that reaches `updateTable` with an unsynced
   `options`. Say "under the stubbed `v-data-table` in the spec" — true, and the reason that matters.
2. The guard covers `sortBy`/`sortDesc` but not `page`/`itemsPerPage`, which are `undefined` in the
   same state. In that state the request is `?page=NaN&size=undefined&…` — a loud `TypeError` became
   a silent malformed GET. **Every component test in the spec dispatches exactly that shape** (the
   harness stubs `v-data-table`, so `options` never gains its keys) and asserts only
   `call.payload.clientId`, so nothing notices. The verifier lane's new F2 case
   (`spec:244-252`) documents this honestly for `getClients`; the same caveat applies to every
   dispatch assertion in the file. Either give `data()` a fully-formed `options` default, or assert
   `call.payload.page` in one test so the harness cannot drift further from production's shape.

### L5 — the rel-guard failure is reported to the user as a network error **[LOW · VERIFIED]**

`rowsOf` throws `SBDEV-3410: response carried _embedded without the "stockrecordView" rel`
(`store/reports/stockUnit.js:76`) inside the `try`, so it lands in the catch at `:118-121`, which
`console.log`s it and toasts *"Error: Request failed due to a network or server issue. Please
retry."* (`:120`). §7.4's *"the error toast fires"* is satisfied and the spec asserts it
(`spec:452`), but a renamed `collectionResourceRel` is a contract/deploy fault, and telling the
operator to retry sends them down the wrong path. Consider re-toasting `Error.message` when the
error is not an axios error.

### L6 — pagination is committed before the request, so a failed fetch leaves the toolbar ahead of the rows **[LOW · VERIFIED]**

`store/reports/stockUnit.js:93` commits `setPagination` before the GET. On the new rel-guard throw
(and on any network failure) the rows are intentionally left untouched while the page number has
already moved. Pre-existing ordering; the new throw arm gives it a second way to fire.

### L7 — `null` means different things in the mutation and the action **[LOW · VERIFIED]**

`setFilters({clientId: null})` → `-1` ("no filter", `store:38`); `searchReport({clientId: null})` →
falls back to `state.list.clientId`, i.e. keeps the current filter (`store:103`). No caller sends
`null` today, so this is latent. If M3's fix lands the inconsistency disappears with the branch.

### L8 — the popup-label test does not pin the key **[LOW · VERIFIED]**

`spec:290` asserts the serialised `:field-names` *contains the string* `SKU Name`. Renaming the key
from `itemName` to anything else leaves it green. Assert `props('fieldNames').itemName === 'SKU
Name'` instead.

### L9 — the two type-ahead cases §7.4 asks for were substituted, silently **[LOW · VERIFIED]**

§7.4 requires *"typing a fragment of a shipper **name** and, separately, of its **`cl_nr`** both
narrow `shippers`"*. The spec ships one label-shape assertion instead (`spec:177`), with an in-test
comment saying Vuetify owns the filtering. The reasoning is sound — the component controls the
label, not the filter — and the verifier lane's new F3 case (`spec:258-266`) now pins
`item-text="label"`, which strengthens it further. It is still a substitution against a written AC:
record it on the ticket rather than leaving §7.4 reading as satisfied.

### L10 — every request to the two new routes carries `state=undefined` **[LOW · VERIFIED]**

`store/reports/stockUnit.js:94` keeps `'&state=' + data.state` while no caller passes `state`
(`stockUnitRecord.vue:395-403`). The text is pre-existing, but this diff repointed it from
`/stockrecord/search/findByKeyword` onto the brand-new `/stockrecordView/search/findByKeyword` and
`…/findByKeywordAndClient` (`store:108-110`). Spring Data REST ignores unknown query parameters, so
it is harmless — but the line is already being edited and shipping a literal `state=undefined` to a
new endpoint invites someone to bind it later. Delete it, or note that it is deliberately inert.

### L11 — leaving the screen with a filter active may fire a discarded request that un-resets the pagination **[LOW · SUSPECTED]**

`pages/reports/stock-unit-record.vue:17-18` commits `resetList` then `resetPagination` in
`beforeRouteLeave`, while the component is still alive. `resetList` now changes `clientId` from N to
`-1` (`store:48`), so the `shipper` computed changes and its watcher is queued → `updateTable()` → a
`searchReport` nobody wants, and a `setPagination` commit landing *after* `resetPagination`. Vue
deactivates a destroyed component's queued watchers (`Watcher.run()` checks `active`), so whether it
fires depends on flush-vs-destroy ordering, which I cannot settle by reading. Same shape via
`layouts/default.vue:490`. This is **new** — the `keyword` watcher is immune because `resetList`
touches the store, not `this.keyword`. Measurement in §4(c).

### L12 — no request sequencing; a fast double selection can be won by the older response **[LOW · SUSPECTED]**

`updateTable` (`stockUnitRecord.vue:376-405`) has no request id or cancellation, and `loading` is a
plain boolean, so two overlapping fetches both commit `setReportItems` in completion order. Against
a 1.8–7.8 s query, a user changing shipper twice quickly can end up looking at the first shipper's
rows. Pre-existing across all seven report screens; the new control makes it reachable without
touching the URL. Not P6's to fix — worth a line on the ticket.

### L13 — `toMatchObject` leaves `sortDesc` ungraded in the merge test **[LOW · VERIFIED]**

`spec:461` matches a subset. A `setFilters` that dropped `sortDesc` would pass. Use `toEqual` with
the full expected list.

### L14 — `setFilters`'s `?? -1` fallback is untested **[LOW · VERIFIED]**

No test calls `setFilters` with a payload lacking `clientId`, so mutating
`(payload && payload.clientId) ?? -1` (`store:38`) to `payload.clientId` survives. Given L1 makes
the fallback genuinely load-bearing, add the one-liner:
`mutations.setFilters(state, {}); expect(state.list.clientId).toBe(-1)`.

---

## 2. What I checked and found correct

Recorded so a later lane does not re-derive it.

- **The `-1` ↔ `null` fold, all four sites.** Getter `stockUnitRecord.vue:277-279`, setter
  `:281-285`, `updateTable`'s `this.shipper == null ? -1 : this.shipper` `:402`, and the export prop
  `:filter="String(shipper == null ? -1 : shipper)"` `:107`. Client id `0` survives every one.
  Traced through `setFilters` (`store:38`) and `searchReport` (`store:102-103`) to the wire.
- **`String(...)` is load-bearing and the chosen mutant was the right one.** `exportReport.vue:136`
  is `filter: this.filter && this.filter != 'All Shippers' ? this.filter : null`, and `filter` is a
  declared prop (`exportReport.vue:92`), so the value does reach the guard. `:filter="shipper"` and
  the un-stringified fold are indeed byte-identical on `0`; they differ only on `null` (`null` vs
  `"-1"`, both "no filter" server-side via §3.6's `toFilterId`). The lead's mutant choice was
  correct, and §5.2 P6's warning against `:filter="shipper"` is why.
- **Route split and URL shape.** `=== -1` → `/stockrecordView/search/findByKeyword` with **no**
  `clientId` parameter; anything else → `…/findByKeywordAndClient` + `&clientId=N`
  (`store:108-110`). Matches §3.9 and the AC-1 absence assertion.
- **`rowsOf` / `countOf` against the measured `_embedded` shape.** The throw arm is the right call:
  it throws inside the `try` (`store:113-117`), so the catch fires, **nothing is committed**, the
  previous rows stay, and `updateTable` still clears `loading` because the dispatch resolves
  normally. Exactly §3.9's and §7.4's specification. The `!embedded → []` arm is correctly labelled
  as unreachable defence. The extra `!Array.isArray` arm (`store:78-80`) is beyond the plan's
  snippet and is a strict improvement.
- **No sentinel row.** `shippers` is built by `map` only (`:358-361` and the `created()` seed
  `:444-447`) — no `{id: null, label: 'All Shippers'}` anywhere, and `clearable` is the single
  spelling of "no filter". The §3.9 divergence from `inventoryReport.vue:301-303`, applied correctly.
- **`created()` seeding does not race or duplicate.** `created()` assigns `this.shippers` from the
  cached list; the `'$store.state.admin.client.clients'()` watcher *assigns* (never concatenates) a
  freshly-mapped array. Both can run; the second overwrites the first. No duplicates. It also fixes
  a real bug in the precedent it copied: `inventoryReport.vue:302` does `Object.assign(client, …)`,
  mutating the store's own client objects; this code uses `Object.assign({}, client, …)`.
- **Selection survives a `shippers` rebuild** — `item-value="id"` matches by value, not identity.
- **`shipper` is not in `$data`.** It is a computed (`:276`), so `mixins/searchUrlSync.js`'s
  `possibleProps` scan cannot see it and `keyword` keeps winning; the SBDEV-2658 deep link is pinned
  by `spec:214-227`.
- **Header and popup label** — `{text: 'SKU Name', sortable: false, value: 'itemName'}` inserted
  after `itemdata` (SKU ID), and `'itemName': 'SKU Name'` added to `:field-names`, matching plan
  rows 27 and 29 and §3.7's `details.put("itemName", …)` key spelling.
- **The renamed-rel test is the one that kills the `rowsOf` mutant**, and the zero-row test
  correctly does not claim to. Both are written the way §7.4 demands.
- **The harness is genuinely reactive** (`Vue.observable` + real mutations applied inside `commit`),
  so the post-mount change assertions are real reactivity tests, not `data()` snapshots.
- **The spec is picked up by jest** — `jest.config.js` sets no `testMatch`, so the default
  `**/?(*.)+(spec|test).js` matches `test/components/reports/stockUnitRecordShipperFilter.spec.js`.
- **The `.gitignore` comment's factual premise** — blame and tracking dates both check out (see H1).
- **The replacement `shipper`-computed comment** (L2) — its six-sibling claim verified page by page.

---

## 3. Cross-phase note

`store/reports/stockUnit.js` now calls `/stockrecordView/search/findByKeyword` and
`…/findByKeywordAndClient`, which do not exist until P2 ships
(`@RepositoryRestResource(collectionResourceRel = "stockrecordView", path = "stockrecordView")`,
plan row 4). P6 must not reach an environment ahead of P2 — the failure mode is a 404 caught by
`store:118`, i.e. an empty grid under a "network or server issue" toast, which reads as an outage
rather than a missing deploy.

---

## 4. Measurements I want (I was told not to run jest)

- **(a) H1.** In a scratch clone with `/reports/` applied: create `reports/x.xlsx` and
  `test/components/reports/y.spec.js`, then `git status --porcelain` — expect the `.xlsx` absent and
  the spec present. The current `cypress/reports/` form gives the opposite on the first file.
- **(b) M2.** Delete `this.options.page = 1` from `stockUnitRecord.vue:347` and run the spec — I
  predict it stays **fully green**. If so, M2 is confirmed and the assertion needs the seeded
  `pagination: {page: 7}`.
- **(c) M1 / L11.** Instrument `$axios.$get`, seed the harness pagination at page 7, mount with a
  synced `options` (`wrapper.setData({options: {page: 7, itemsPerPage: 10, sortBy: [], sortDesc:
  []}})`) and change `shipper` — I predict **2** `searchReport` GETs and **2** `getClients`
  dispatches. The same rig with a `resetList` commit instead of a selection answers L11.
- **(d) L14.** `mutations.setFilters(state, {})` → expect `clientId === -1`.

---

## 5. Requested fixes, in the order I would do them

1. **H1** — `/reports/` instead of `cypress/reports/`, and fix the comment's last sentence.
2. **M2** — make the page-reset assertion non-vacuous (`pagination` override in `reportHarness`).
3. **M3** — drop the `data.clientId` precedence to the plan's from-state form, drop the `clientId`
   key from `updateTable`'s dispatch, rename the misleading test.
4. **M1** — guard the `shipper` watcher against the duplicate fetch.
5. **L1, L3, L4** — correct the three comments that still assert more than holds (L2 already done).
6. **L8, L13, L14** — three one-line test strengthenings.
7. **L5, L6, L7, L9, L10** — judgement calls; each is a line of code or a line on the ticket.
8. **L11, L12** — measure (§4c) before deciding; L12 is pre-existing and probably its own ticket.
9. **Plan hygiene** — §3.9 still carries the false cross-navigation-persistence sentence that L2
   removed from the code.
