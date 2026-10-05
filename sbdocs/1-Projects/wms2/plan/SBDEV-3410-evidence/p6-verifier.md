# SBDEV-3410 P6 — conformance verification

**Lane:** conformance verifier (independent of the authoring lane)
**Date:** 2026-09-23
**Worktree graded:** `/Users/np1076/dev/spk/owl/.claude/worktrees/wms2-web-ui/SBDEV-3410-p6`
**Branch:** `feature/SBDEV-3410-p6-shipper-filter-and-sku-name` … `origin/develop`
**Diff:** 3 tracked files modified (`.gitignore`, `components/reports/stockUnitRecord.vue`,
`store/reports/stockUnit.js`, +171/−10) + 1 untracked spec
(`test/components/reports/stockUnitRecordShipperFilter.spec.js`, 22 `it(` blocks).
**Plan:** `sbdocs/1-Projects/wms2/plan/SBDEV-3410-stock-unit-record-shipper-filter-and-product-name.md`

**Not run in this lane (by instruction):** jest. Every measurement quoted as "measured" is the lead's,
attributed as such; everything else in this report I read off the code myself.

---

## Overall verdict — **INCOMPLETE**

The **code** is complete and conformant: I found no §5.2 P6 checkbox whose *implementation* is absent or
partial, and every wire contract AC-1 names (route, parameter, rel, entity field) matches what is actually
merged on `wms2-api` `origin/develop` @ `b87ec747`.

What is not discharged is **§5.2 P6 checkbox 3's test coverage**, and it fails against the plan's **own**
rule (checkbox 9). Two of the three mechanisms that populate the dropdown — the
`'$store.state.admin.client.clients'()` watcher and the `admin/client/getClients` dispatch — are asserted by
**no test in the suite**. Delete either and all 22 stay green, while the production screen ships with a
permanently empty Shipper dropdown on a cold visit. That is §3.8's "latent empty dropdown" made live, and it
is exactly the failure mode checkbox 9 exists to prevent: every test that needs `shippers` seeds `clients`
into the store **before** mount, so only the `created()` path is graded and the reactive path never runs.

Two tests, roughly ten lines, close it. Details in **F1** and **F2**. I would not merge without them.

---

## §5.2 P6 — the nine checkboxes

| # | Checkbox | Verdict |
|---|---|---|
| 1 | store: `shippers`/`shipperFilter` state; merge-not-replace `setFilters`; `resetList` resets `clientId: -1`; `searchReport` picks the route on `clientId === -1` and appends `&clientId=` from state; `== null`/`=== -1`, never `!data.clientId` | **VERIFIED (2 deviations, both benign, both must be recorded)** |
| 2 | read rows through `rowsOf(results, 'stockrecordView')` | **VERIFIED** |
| 3 | component: widget · `item-value="id"` · `shipper` computed · `getClients` dispatch + `clients` watcher · SKU Name header `sortable: false` · `String(...)` filter · `'itemName'` label · `updateTable` passes `clientId` | **PARTIAL — code all present; the dispatch and the watcher are ungraded** |
| 4 | reset page to 1 when the shipper changes | **VERIFIED** |
| 5 | `test/components/reports/stockUnitRecordShipperFilter.spec.js` | **VERIFIED** |
| 6 | regression: `?search={sku}` still populates `keyword`, not the shipper | **VERIFIED** |
| 7 | mutation-check: `shipper` → `data()`, graded by `'shipper' in $data === false` | **VERIFIED** (lead-measured: exactly 1 red, the `$data` assertion) |
| 8 | mutation-check: drop `String(...)`, graded on the **POST body** | **VERIFIED** (lead-measured: exactly 1 red, the end-to-end export case, `Expected "0" / Received null`; the 3 characterisation tests green — which is what the spec's own doc comment predicts) |
| 9 | every spec changes the value **after** mount | **PARTIAL — violated for the dropdown-population half** |

### 1 — store · VERIFIED, with two deviations

Present and correct: `clientId: -1` in `state.list` (`store/reports/stockUnit.js:16`); `setFilters` merging
via `Object.assign({}, state.list, …)` (`:36`); `resetList` resetting `clientId: -1` (`:48`); route selection
on `clientId === -1` (`:108-110`); no truthiness test anywhere on the value. `(payload && payload.clientId) ?? -1`
is behaviourally identical to the plan's `payload.clientId ?? -1` on every input including `0`.

**Deviation 1 — `shippers` / `shipperFilter` are NOT in the store.** The checkbox names the
`store/reports/inventory.js` shape (`shippers: []`, `shipperFilter: null`, `setShippers`, `setShipperFilter`,
`resetShipperFilter` — confirmed present there, `store/reports/inventory.js:11-12`). The implementation
instead puts the **list** in component `data()` (`stockUnitRecord.vue:167`) and the **selection** in
`state.list.clientId`. That is the `store/handlingUnits/stockUnits.js` shape, which §3.9 explicitly instructs
the implementer to take *instead of* inventory's ("Take the store shape from `store/handlingUnits/stockUnits.js`,
not from `inventory.js`"), and the sibling does exactly this — `list.clientId` in the store
(`store/handlingUnits/stockUnits.js:25`), `shipperList` in component data
(`components/handlingUnits/stockUnitsTable.vue:237`). **§3.9 governs and the checkbox's wording is the stale
copy.** Accepted; record it in §9G so a later reader does not re-open it.

**Deviation 2 — `searchReport` prefers the payload over state.** §3.9 item 2 says `clientId` is read
"from `context.state.list`, **never from `data`**". The implementation is
`const fromPayload = data && data.clientId; const clientId = (fromPayload ?? context.state.list.clientId) ?? -1`
(`:102-103`) — payload first, state as fallback. Payload-less refresh still works (the "keeps the filter on a
payload-less refresh" test at spec `:354` pins it), and the only live caller derives its payload from the same
store state, so the two can never disagree today. But the plan's phrasing was chosen to make disagreement
*impossible*, and this leaves a stale payload able to override the filter the user can see. Low; record it.

### 2 — `rowsOf` · VERIFIED

`store/reports/stockUnit.js:69-85`. Three arms: missing `_embedded` → `[]` (documented as the unreachable
defence arm); missing rel → throw (the live arm); **plus a third the plan did not specify** — `!Array.isArray(rows)`
→ throw (`:81`). Harmless hardening, but no test feeds a non-array, so it is unexecuted code. Either drop it or
add the one-line case; I would drop it, since the plan's §3.9 snippet is deliberately six lines.

`countOf` (`:87`) matches the plan verbatim.

### 3 — component · PARTIAL

Every element of the checkbox is present in the code:

| element | site |
|---|---|
| `<v-autocomplete>` with `id="shipper"`, `item-text="label"`, `item-value="id"`, `:clearable="true"`, `:items="shippers"`, `v-model="shipper"`, placeholder | `stockUnitRecord.vue:18-27` |
| no `{ id: null, label: 'All Shippers' }` sentinel anywhere | `:351-353` (watcher) and `:437-440` (`created`) both build the list with a bare `.map`, no head entry |
| `shipper` as a computed over Vuex, `-1 ⇄ null` folded once | `:269-281` |
| `getClients` dispatch | `:386` |
| `clients` watcher | `:351` |
| SKU Name header, `sortable: false`, `value: 'itemName'` | `:200-207` |
| `:filter="String(shipper == null ? -1 : shipper)"` | `:107` |
| `'itemName': 'SKU Name'` in `<full-details>`'s `:field-names` | `:132` |
| `updateTable` passes `clientId: this.shipper == null ? -1 : this.shipper` | `:395` |

**The gap is coverage, not code** — see F1/F2 below.

One correctness note in this checkbox's favour that is easy to miss: `updateTable` was changed to
`const { sortBy = [], sortDesc = [], page, itemsPerPage } = this.options` (`:371`). `options` is `{}` in
`data()` (`:157`) and is only filled by `v-data-table`'s `:options.sync`, so before the table mounts
`sortBy.length` threw. The pre-existing keyword watcher is shielded by its 700 ms debounce; the new shipper
watcher fires synchronously and does reach it. The defaulting is necessary and the comment explaining it is
accurate.

### 4 — page reset · VERIFIED

`stockUnitRecord.vue:339-342`. The spec's assertion at `:191` is **not** vacuous: `options` is `{}` in
`data()`, so `options.page` is `undefined` at mount and only the watcher's `this.options.page = 1` can make
`toBe(1)` pass. Removing the line reds the test.

Observation (Low, informational, not a finding): in a browser `options.page` is reactive, so a shipper change
made while on page ≠ 1 fires `updateTable` **twice** — once from the watcher's explicit call and once from the
`options` deep watcher. The pre-existing keyword watcher has byte-identical shape (`:303-305`), so this is the
established pattern on this screen, not a regression. The test cannot see it because `v-data-table` is
stubbed and `options` stays `{}`.

### 9 — "change the value after mount" · PARTIAL

Honoured for the selection: spec `:183`, `:194`, `:203`, `:253` all mutate `wrapper.vm.shipper` post-mount and
assert the *emitted* dispatch. Violated for the dropdown list: see F1.

---

## §7.4 — the case list

§7.4 names 13 distinct cases. Twelve are implemented; the thirteenth is the substitution the lead flagged.

| § 7.4 case | Verdict | Where |
|---|---|---|
| widget renders (`find('#shipper')`) | VERIFIED | spec `:155` |
| mounts **empty**, `shipper` is `null`, first request unfiltered | VERIFIED | `:169` |
| `'shipper' in $data === false` | VERIFIED | `:160` |
| selection **after mount** dispatches new `clientId` and resets page to 1 | VERIFIED | `:183` |
| empty/cleared ⇒ `findByKeyword`, **no `clientId` on the URL** | VERIFIED | `:203` (fold to −1) + `:327` (route + `has('clientId') === false`) |
| selection ⇒ `findByKeywordAndClient` with `&clientId=N` | VERIFIED | `:336` |
| `?search={sku}` still binds `keyword` | VERIFIED | `:214` |
| **client id `0`** — table request on the filtered route **and** export body `filter: "0"`, read past the guard | VERIFIED | `:345` (route) + `:253` (end-to-end body). The e2e case un-stubs the real `exportReport.vue` by passing the component as the stub value and reads `dispatches[].payload.data.filter` — i.e. downstream of `exportReport.vue:136`'s `this.filter && …` guard, exactly as §7.4 demands. Not a prop-level assertion. |
| **zero-row response** `{_embedded:{stockrecordView:[]},page:{totalElements:0}}` ⇒ `[]` / `0` | VERIFIED | `:362` |
| **renamed-rel response** ⇒ does **not** commit, error toast fires | VERIFIED | `:374`, asserts both `setReportItems` absent and `$toast.error` called |
| clearing sets `null` and dispatches `clientId: -1` on the unfiltered route | VERIFIED | `:203` + `:327` |
| `shippers` contains no `{id: null, label: 'All Shippers'}` | VERIFIED | `:169` (`labels).not.toContain('All Shippers')` **and** `every(s => s.id != null)`) |
| typing a fragment of a shipper **name** / of its **`cl_nr`** each narrows `shippers` | **PARTIAL — substituted; the substitution is adequate for the framework half and leaves a real hole** | `:177` asserts the label shape `'Arrowood (ARW)'` |

### Judging the substitution (the lead's question)

**The reasoning is right; the substitution is one assertion short.**

Asserting that Vuetify narrows a list is testing Vuetify — the lead is correct to refuse it, and the label
shape `name (clNr)` is genuinely the only part of "a name fragment and a cl_nr fragment both match" that
`stockUnitRecord.vue` controls… **except it is not the only part.** Vuetify filters on `item-text`. The label
containing the `clNr` only makes the `clNr` searchable *because* `item-text` is bound to `label`. Change
`item-text="label"` to `item-text="name"` and the `cl_nr` fragment stops matching — a real regression in the
behaviour §7.4 asked about — and **every one of the 22 tests stays green**, because the label-shape test reads
`wrapper.vm.shippers` and never looks at the widget.

The same hole covers the rest of AC-1's widget contract. `item-value="id"` is asserted nowhere: change it to
`clNr` and the screen sends `clientId=ARW`, and no test reds, because every test writes `wrapper.vm.shipper`
directly and so bypasses `v-model` and `item-value` entirely. `:clearable`, and the `:items="shippers"`
binding, are likewise ungraded.

This makes the `AutocompleteStub`'s own doc comment (spec `:46-48`) unsupported: it says the stub "really
binds" so that *"a broken `v-model` or a missing `:items` passes"* against a bare `true` stub. The stub does
declare the props (`:51`) — but nothing in the file ever reads `.props()` or emits `input` on it, so the
claimed benefit is not realised. Either realise it (below) or delete the claim.

**Remedy (≈6 lines, one new `it`):**

```js
it('binds the widget contract the type-ahead depends on', async () => {
  const { wrapper } = mountReport({ clients: [ARW] })
  const box = wrapper.findComponent(AutocompleteStub)
  expect(box.props('itemText')).toBe('label')   // why a cl_nr fragment matches at all
  expect(box.props('itemValue')).toBe('id')     // AC-1: id, not clNr
  expect(box.props('clearable')).toBe(true)     // AC-1: clearable IS "All Shippers"
  expect(box.props('items')).toBe(wrapper.vm.shippers)
  box.vm.$emit('input', 0)                      // proves v-model is wired, on the one value that discriminates
  await wrapper.vm.$nextTick()
  expect(wrapper.vm.shipper).toBe(0)
})
```

---

## Acceptance criteria P6 owns

**AC-1 — the dropdown. PARTIAL.** Code fully conformant; the widget-contract half is ungraded (above). The
*wire* half is fully graded and I independently confirmed it against the merged API rather than against the
plan's prose:

| claim | checked against | result |
|---|---|---|
| route `…/stockrecordView/search/findByKeyword` | `wms2-api` `origin/develop` `StockrecordViewRepository.java:121,123` | matches |
| route `…/findByKeywordAndClient`, param named `clientId`, type `Long` | same file `:143-146` | matches |
| SDR path + rel are both `stockrecordView` | `@RepositoryRestResource(collectionResourceRel = "stockrecordView", path = "stockrecordView")`, `:56` | matches the `rowsOf(results, 'stockrecordView')` literal |
| no `clientId` on the unfiltered URL | `store/reports/stockUnit.js:109` appends nothing | matches |

**AC-2 — export honours the filter. VERIFIED.** `:filter="String(shipper == null ? -1 : shipper)"` at
`stockUnitRecord.vue:107`; graded end-to-end past `exportReport.vue:136`'s guard at spec `:253`; mutation 2
kills it with exactly one red on that case (lead-measured). The three characterisation tests are correctly
labelled "NOT a P6 gate" — they mount `exportReport.vue` alone and would pass against a screen that passes no
`:filter` at all. That labelling is accurate and load-bearing; keep it.

**AC-3 — the product name in the TABLE **and** in the POPUP. VERIFIED, both halves.**

- *Popup:* `'itemName': 'SKU Name'` added to `<full-details>`'s `:field-names` (`:132`); asserted at spec `:236`.
  This also discharges §9D's promotion gate ("P4 merged without P6 labels the popup row `ItemName`").
- *Table:* the header exists with `value: 'itemName'` (`:200-207`), asserted at spec `:228`. **The lead's
  concern about the route is discharged:** the store's *only* grid read is now
  `/stockrecordView/search/findByKeyword{,AndClient}` (`:109-110`) — I grepped the whole store file and the one
  remaining `/stockrecord/` reference is `stockRecordDetailsById` at `:162`, which is the popup endpoint and
  correctly unchanged. `itemName` is a real persistent field on the merged entity
  (`StockrecordView.java:109-110`, `@Column(name = "item_name")`), and `items()` (`:248-253`) spreads the row
  through untouched, with no `#[item.itemName]` slot to intercept it. So the table cell will render.
- ⚠ Scope note, not a finding: no test *renders* the cell (`v-data-table` is stubbed). That is correct for a
  component spec — the header array is the component's contribution — but it means the table half of AC-3 is
  graded by construction plus the API-side ITs from P1/P2, not by a P6 assertion. Say so in §9G rather than
  claiming the table half is test-covered here.

**AC-4 — keyword / sort / pagination still work in combination. PARTIAL at the UI layer.**
AC-4's substance is graded in the API ITs (§7.2), and §7.4 does **not** ask for a UI combination case, so this
is not a §7.4 miss. But P6 owns one thing AC-4 depends on that nothing grades: the **URL assembly on the
filtered branch**. Every store test passes `keyword: ''` and `sortUrl: null`, so no assertion shows that
`&clientId=N` is appended *alongside* a live `keyword`, `sort` and `page`. A mutant that built the filtered
path from scratch instead of from `urlPart` — dropping keyword and sort whenever a shipper is selected, which
is a plausible slip and a user-visible one — survives the suite. One extra store case closes it:

```js
it('keeps keyword, sort and page alongside the filter', async () => {
  const { ctx, scope, urls } = storeHarness({ list: { clientId: 42 } })
  await stockUnitActions.searchReport.call(scope, ctx,
    { page: 2, itemsPerPage: 10, keyword: 'ABC', sortUrl: 'created,desc', clientId: 42 })
  const q = search(urls[0])
  expect([q.get('keyword'), q.get('sort'), q.get('page'), q.get('clientId')])
    .toEqual(['ABC', 'created,desc', '1', '42'])
})
```

Also verified while here, because it is the mechanism AC-4's "filter survives" half rests on: the keyword
watcher (`:303`) and the `options` watcher (`:312`) both `Object.assign({}, state.list)` before committing
`setList`, so with `clientId` now living in `list` neither drops it. The merge-not-replace test at spec `:390`
pins the converse.

---

## The lead's five targeted questions

**1. A §5.2 P6 checkbox not done, or done partially.**
No checkbox is unimplemented. The expensive gap is coverage on checkbox 3 — **F1** and **F2** below. They are
the finding I would hold the merge for.

**2. §7.4 cases not implemented.** One, as the lead stated, and the substitution is adequate for the framework
half but leaves the `item-text` / `item-value` binding ungraded. Full reasoning above; remedy given. The other
twelve cases are all genuinely implemented — I checked each against the code, not against the spec's own
comments.

**3. AC-3's two halves.** Both delivered; the store really did switch routes; `itemName` really exists on the
merged entity. Verified above.

**4. Q5 / route withdrawal — the conclusion is CONFIRMED, with a correction the hand-off must carry.**
Q5 is **not** a §5.2 P6 checkbox (I read the checklist; it is absent), §10.2 states it is *"Proposed, flagged,
not decided"*, and it is a `wms2-api` change while P6's branch is `wms2-web-ui`. So P6 was right not to do it.
**But the plan books it *for P6's PR* in two places** — §10.2 (*"If Nam says yes, the withdrawal belongs in
P6's PR, not earlier: withdrawing before the UI has moved breaks the report"*) and §9C's "Still owed"
(*"**Q5 remains open and is P6's** … the plan books the withdrawal in P6's PR"*). P6 is the last phase, so
"later" no longer exists: after this merge the route is uncalled and the moment the plan chose for the
decision has arrived. It must go to Nam at hand-off as an explicit question, not be dropped as out-of-scope.
Two riders:
- Since P6's PR is a **web-UI** PR, the withdrawal cannot literally ride in it. It needs a small companion
  `wms2-api` PR, sequenced **after** this one merges. The plan's booking is internally inconsistent with its
  own one-repo-per-phase branch layout; say so rather than silently reinterpreting it.
- **The two Q5 statements name different routes.** §10.2 is about `stockrecordRepository.findByKeyword`;
  §9C is about `findByOffsetAndLimit`. Both are `stockrecord` SDR searches, both unruled, but only the first
  loses its last caller at P6 — `findByOffsetAndLimit` still has a Java caller in `ReportService`. Whoever
  closes Q5 must handle them separately; a single yes/no answer will otherwise be applied to the wrong one.

**5. Does `.gitignore` belong in this phase? YES — and its comment's factual claims check out.**
- The bare `reports/` matched `components/reports/`, `store/reports/`, `pages/reports/` **and**
  `test/components/reports/` — I confirmed all four directories exist
  (`find . -type d -name reports`) and that gitignore's trailing-slash rule matches at any depth.
- *"the 32 files already there were tracked before the rule"*: `git ls-files | grep -c '^\(components\|store\|pages\)/reports/'` → **32**. Exact.
- *"this phase's own spec was [silently dropped]"*: the spec lives at `test/components/reports/…`, an
  untracked path under a `reports/` directory. Claim supported.
- The narrowing un-ignores nothing real: `git status --ignored --short` now shows only `.omc/` and
  `node_modules/`, and no `reports/` directory exists outside the three source dirs and the new test dir — so
  `cypress/reports/` is a forward-looking scope, not a currently-populated one. Harmless either way, and it
  keeps the rule in the Cypress block it was written in.
- Add it to §4's File Change Summary, which currently lists only the two source files and the spec.

---

## Findings

### F1 — HIGH · the `clients` watcher is graded by nothing; deleting it leaves 22/22 green

`stockUnitRecord.vue:351-353` is the **only** path that populates the dropdown on a cold visit: `created()`
(`:437-440`) reads `$store.state.admin.client.clients` synchronously, and on a first navigation that is `[]`
because `getClients` is dispatched from `updateTable` and resolves later. The watcher is what fills the list
when it lands.

Every test that needs `shippers` seeds `clients` into the harness **before** `shallowMount`
(spec `:170`, `:179`, `:184`, `:195`, `:204`, `:254`), so all of them exercise the `created()` branch and none
exercises the watcher. I grepped the whole spec: there is no post-mount write to `state.admin.client.clients`
anywhere. Delete the watcher and the suite is unchanged.

This is §5.2 P6 checkbox 9's exact failure mode — *"mounting with a value already present is not a reactivity
test"* — applied to the half of the screen where it has a user-visible consequence: an empty Shipper dropdown
on every first visit, which is §3.8's latent-empty-dropdown symptom arriving through a different door.

```js
it('fills the dropdown when allClients resolves AFTER mount', async () => {
  const { wrapper, state } = mountReport({ clients: [] })
  expect(wrapper.vm.shippers).toEqual([])
  state.admin.client.clients = [ARW]          // the harness state is Vue.observable, so this is reactive
  await wrapper.vm.$nextTick()
  expect(wrapper.vm.shippers.map(s => s.label)).toEqual(['Arrowood (ARW)'])
})
```

(`reportHarness` already returns `state`, and `mountReport` already spreads it — no harness change needed.)

### F2 — MEDIUM · the `getClients` dispatch is graded by nothing

`stockUnitRecord.vue:386`. No test asserts that `updateTable` dispatches `admin/client/getClients`; the
harness records dispatches, so it costs one line. Without it, deleting the dispatch is green here and ships a
dropdown that never populates at all — the same user-visible outcome as F1, from the other half of the
mechanism. F1 and F2 are two mutants on one checkbox item ("`getClients` dispatch + `clients` watcher") and
neither is currently killed.

```js
expect(dispatches.some(d => d.name === 'admin/client/getClients')).toBe(true)
```

### F3 — MEDIUM · AC-1's widget binding contract is asserted nowhere

`item-text`, `item-value`, `clearable`, `:items` and `v-model` are all ungraded; a change to `item-value`
silently sends `clNr` as `clientId`. Remedy under **§7.4** above. This subsumes the lead's §7.4 substitution
question.

### F4 — MEDIUM · AC-4's UI half: no test shows the filter composing with keyword/sort/page

Remedy under **AC-4** above.

### F5 — MEDIUM · unsupported comment claim: "cross-navigation persistence"

`stockUnitRecord.vue:264-265`: *"It also gives the filter the cross-navigation persistence the other report
filters have."* **Both halves of that sentence are false.**

- *The other report filter does not have it.* `pages/reports/inventory-report.vue:14-20` commits
  `reports/inventory/resetShipperFilter` on `beforeRouteLeave` when leaving the section. Inventory's filter is
  deliberately cleared on cross-section navigation.
- *This one now does not have it either* — and by this phase's own doing.
  `pages/reports/stock-unit-record.vue:17` commits `reports/stockUnit/resetList` on the same hook, and P6
  added `clientId: -1` to `resetList` (`store/reports/stockUnit.js:48`), which is checkbox 1's third clause.
  The filter is cleared on section exit by design.

What the Vuex backing actually buys is (a) immunity from `searchUrlSync`'s `$data` scan — which is the real
and sufficient reason, already stated correctly two lines above — and (b) survival across component re-mounts
*within* the section. Neither is "cross-navigation persistence". The claim is inherited verbatim from plan
§3.9 (*"the same cross-navigation persistence the Inventory report has"*), so the **plan is wrong too** and
correcting only the comment leaves the sibling copy asserting it. Fix both, or the next reader re-derives it.

### F6 — LOW · unsupported comment claim: the `AutocompleteStub` "really binds"

Spec `:46-48` claims the hand-written stub prevents *"a broken `v-model` or a missing `:items`"* from passing.
Nothing reads its props or emits on it. Realise the claim (F3's snippet) or delete it.

### F7 — LOW · two recorded deviations from §5.2 checkbox 1

`shippers`/`shipperFilter` not in the store (§3.9-sanctioned, matches the handlingUnits precedent), and
`searchReport` preferring the payload over state (§3.9 said "never from `data`"). Both benign; both belong in
§9G as **approved deviations** so they are not re-litigated in review.

### F8 — LOW · `rowsOf`'s third arm is unexecuted

`store/reports/stockUnit.js:81`, `!Array.isArray(rows)` — beyond the plan's six-line snippet and reached by no
test. Drop it, or add the case.

### F9 — INFO · `.gitignore` is missing from §4's File Change Summary

---

## What I did not verify, and could not

- **No jest run in this lane** (instructed). "Spec 22/22" and "full suite 99 suites / 1585 tests green" and
  both mutation results are the lead's measurements, reproduced here as attributed claims. I confirmed the
  spec file contains exactly **22** `it(` blocks, which is consistent with 22/22, and I confirmed by reading
  that mutation 2's predicted blast radius (1 red = the e2e case; the 3 characterisation tests unaffected) is
  what the code shape implies.
- **Nothing rendered in a browser.** Whether the `<v-autocomplete>` lays out correctly next to the search
  field at narrow widths, and whether the SKU Name column fits without wrapping the grid, is unchecked. Per
  the standing headless-browser recipe this is checkable; it is not a conformance question, so I did not.
- **The cross-repo checks** (`StockrecordView.itemName`, the two search routes, the `stockrecordView` rel)
  were derived from `wms2-api` `origin/develop` @ `b87ec747` (2026-09-22 21:58 +0900) **without a fetch**. If
  P1–P4 have moved since, re-derive. The P5 PR (#398) is still open and touches none of these.
- **No DB query in this lane.** The floor's DB item was discharged in P1–P5 against the view and the client
  population; nothing in P6 makes a new data claim.
