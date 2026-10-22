---
ticket: SBDEV-3437
type: code-review
commit: 5ab444f
base: origin/develop 8412347
repo: v2/wms2-web-ui
worktree: .claude/worktrees/wms2-web-ui/SBDEV-3437
reviewer: independent code-reviewer lane (not the authoring context)
date: 2026-10-06
---

# SBDEV-3437 — independent code review of 5ab444f

Scope: `store/internalOps/cycleCount.js` (4 guards), `store/admin/labelPrinting.js` (1 guard),
`test/store/internalOps/cycleCountShipperFilter.spec.js` (new), `test/store/admin/labelPrinting.spec.js` (+1 case).
`git diff origin/develop` is exactly 4 files / +88 −5 and equals `git show 5ab444f`. Worktree clean before and after
(no edits made; mutation probes ran in a scratch copy).

## Stage 1 — spec compliance: PASS

- Ticket ask: picking System-Client (id 0) in the Cycle Count shipper dropdown must filter to client 0, not return all.
- Both URL builders in both actions are fixed (data path `if (data.clientId != null)`, state path `?? ''`). Nothing missing,
  nothing extra beyond the explicitly flagged latent `previewTote` fix.
- Backend contract confirmed on wms2-api origin/develop `ViewDtoService.java:765-767`:
  `long cId = Long.parseLong("-1"); if (clientId != null && !clientId.isEmpty()) { cId = Long.parseLong(clientId);`
  → absent / empty = -1 (all), `"0"` = 0. The wire shape for "All Shippers" (null) is unchanged on both paths.
- DB (nywh-hydra-prd): `client` id 0 = `System-Client`, `cl_nr = 'System'`. `cyclecount` has 0 rows in total on that
  tenant, so current prd exposure there is nil; the fix is a correctness fix, not an incident fix.

## Stage 2 — findings

### 1. Correctness — can undefined / other values now produce a different URL?

All dispatchers and setters (git grep on origin/develop, components/pages/store/plugins):

| Site | What reaches the guard |
|---|---|
| `components/internalOps/cycleCount/planned/plannedCycleCount.vue:315-321` `clientId: this.selectedShipper` | store `openShipperFilter` |
| `components/internalOps/cycleCount/closed/closedCycleCount.vue:298-304` `clientId: this.selectedShipper` | store `closedShipperFilter` |
| `pages/internalOps/cycle-count.vue:41,44` dispatch with no data | state path |
| `store/internalOps/cycleCount.js:212,219` (`cancelCycleCount`) `context.dispatch('searchPlannedRequests')` | state path |
| `store/internalOps/createCc.js:73` `dispatch('internalOps/cycleCount/searchPlannedRequests', null, {root:true})` | state path |
| Setters: v-select `v-model` → `setOpen/ClosedShipperFilter`; `pages/internalOps/cycle-count.vue:56-57` commit `null` on section exit | null / numeric id |
| `components/admin/labelPrinting/toteLabels.vue:313,367,380` `previewTote({})` / `({ labelId })` | `clientId` always undefined |

Value domain of the filter: initial `null` (`cycleCount.js:39-40`); v-select items `[{ id: null, label: 'All Shippers' }, ...clients]`
with `item-value="id"` (numeric); Vuetify 2.7.2 clear button: `clearableCallback() { this.setValue(this.multiple ? [] : null)` → `null`,
not `undefined`. Persisted state: `plugins/persistedState.client.js` reducer is allow-by-default at root, so
`internalOps.cycleCount.open/closedShipperFilter` IS persisted to `vuex-web`; JSON cannot carry `undefined`, so rehydration yields
`null`, a number, or (key absent) the initial `null`.

Behavioural delta vs. before, by input value:

| value | data path before → after | state path before → after |
|---|---|---|
| `null` | omitted → omitted | `clientId=` → `clientId=` |
| `undefined` | omitted → omitted (`undefined != null` is false) | `clientId=` → `clientId=` |
| `0` | omitted → `clientId=0` (the fix) | `clientId=` → `clientId=0` (the fix) |
| `''` | omitted → `clientId=` (backend: empty = -1, same semantics) | unchanged |
| `false` / `NaN` | would change, but unreachable | unreachable |

Conclusion: no reachable input produces `clientId=undefined` or `clientId=null`, and the only behavioural change is for 0.

- **[Info] Persisted pre-fix blobs holding 0 now filter correctly.** A browser whose `vuex-web` already holds
  `openShipperFilter: 0` previously showed "System-Client" in the dropdown while the table listed every shipper; after this change
  the table matches the dropdown. This is the intended direction; no migration/heal needed.
  Confidence: HIGH.

- **[Info] `previewTote` change is latent.** All three callers in `toteLabels.vue` pass `{}` or `{ labelId }`; `clientId` is never set,
  so the wire is unchanged today. Also: axios drops `undefined`/`null` params, so even a mis-written guard there would be wire-neutral.
  Confidence: HIGH.

### 2. Is `??` supported for store files?

- **[Info] Yes.** `??` already ships in store files on origin/develop and origin/main:
  `store/handlingUnits/stockUnits.js:218` `urlPart += '&clientId=' + (context.state.list.clientId ?? -1)` (introduced 6947d71,
  2026-09-17, contained in `origin/main`), also `store/handlingUnits/container.js:73,126`, `store/internalOps/replenishments.js:230`,
  `store/reports/lock.js:66`. App build: Nuxt 2.15 (`@nuxt/babel-preset-app` 2.18.1, `@babel/preset-env` 7.29.5) transpiles all
  app sources including `store/`; Jest uses `.babelrc` `env.test` preset-env targeting current node. Both affected specs pass:
  `Tests: 33 passed, 33 total`. Confidence: HIGH.

### 3. Test adequacy

Mutation probes (scratch copy, the two specs only):

| mutant | result |
|---|---|
| M1 planned data guard → `if (data.clientId)` | killed (1 fail) |
| M2 closed data guard → `if (data.clientId)` | killed |
| M3 `openShipperFilter ?? ''` → `|| ''` | killed |
| M4 `closedShipperFilter ?? ''` → `|| ''` | killed |
| M5 labelPrinting → `data.clientId)` | killed |
| M6 data guards → `!== undefined` (would send `clientId=null`) | killed (2 fail) |
| M10 state path → `String(filter)` (would send `clientId=null`) | killed |
| **M7** data guards → `!== null` (would send `clientId=undefined`) | **survives** |
| M8 / M9 labelPrinting → `!== undefined` / `!== null` | survives (wire-equivalent: axios omits null/undefined params; `toHaveBeenCalledWith` treats `{clientId: undefined}` as `{}`) |

The tests assert at the wire (`$axios.$get` URL parsed with `URLSearchParams.getAll`), cover 0 / ordinary id / null on both paths
for both actions, and kill every revert of the commit. The author's claim "each of the 5 reverted guards is killed by its own test"
is confirmed.

- **[Low] No `undefined` case on the data path — mutant M7 survives.**
  File: `test/store/internalOps/cycleCountShipperFilter.spec.js:33-49` (data-path `describe`).
  A future refactor to `if (data.clientId !== null)` would emit `&clientId=undefined`, which the backend turns into
  `Long.parseLong("undefined")` → `NumberFormatException` → 500. Unreachable today (no caller passes undefined), hence Low.
  Fix: add `it('omits clientId when undefined', async () => expect(clientIdParams(await dispatch(undefined))).toEqual([]))`.
  Confidence: HIGH (measured).

- **[Low] No component-level pin that the v-select value 0 reaches the dispatch.** The specs start at the store action; the
  `clientId: this.selectedShipper` hand-off in `plannedCycleCount.vue:321` / `closedCycleCount.vue:304` and the
  `selectedShipper` watcher (`if (newVal !== oldVal) { this.updateTable() }`) are untested for 0. Both are trivially correct
  today (no coercion, strict `!==` so null→0 triggers a refresh), so this is optional.
  Fix (optional): a shallowMount test committing `setOpenShipperFilter(0)` and asserting the dispatched payload has `clientId: 0`.
  Confidence: MEDIUM.

- **[Info] The labelPrinting test pins only the 0 case.** `test/store/admin/labelPrinting.spec.js:124-131`. Since axios omits
  null/undefined params, M8/M9 are equivalent mutants on the wire; no further test needed.

### 4. Sibling sweep (origin/develop, both UI repos)

Instrument: `git -C <repo> grep -E` over `*.js`/`*.vue` excluding tests, for `if (x.clientId)`, `clientId ||/&&`,
`shipper*Filter ||/&&`, `selectedShipper ||/&&`, `!clientId`. Positive control: the same patterns hit all four pre-fix lines
in `store/internalOps/cycleCount.js:142,146,284,288` and `store/admin/labelPrinting.js:179` on origin/develop, so the instrument
is not blind.

- **[Medium] `components/admin/systemManagement/uploads/inboundBolUpload.vue:107,118` rejects Shipper ID 0.**
  `const clientId = lineData['Shipper ID']` … `if (!clientId) errors.push({field: 'Shipper ID', message: 'cannot be empty'})`.
  The CSV is parsed with `Papa.parse(..., { header: true, dynamicTyping: true, ... })` (line 64-67), so a cell `0` arrives as the
  NUMBER 0 and is rejected as "cannot be empty". This is a numeric client id: the backend `FileImportController.importInboundBols`
  does `clientRepository.existsById(Long.parseLong(adviceDto.getClientId()))`. Client 0 does receive advices — nywh-hydra-prd has
  `advice where client_id = 0` = 1 row — so an inbound-BOL upload for System-Client is plausible, and the operator gets a wrong
  error message. Same defect class as the ticket, different surface.
  Fix: `if (clientId == null || clientId === '')`. Ticket policy: sub-T3, same class → add to SBDEV-3437 (if not yet `on dev`)
  or note on the ticket as a follow-up. Confidence: HIGH (code + parser option + DB row).

- **[Low] `components/admin/systemManagement/uploads/skuUpload.vue:105,118`** `const clientNumber = lineData['Shipper Code']` …
  `if (!clientNumber)` with the same `dynamicTyping: true`. This is a clNr STRING, not a numeric id, so it is outside the strict
  scope; it would only misfire for a client whose code is literally `0` (dynamicTyping turns `"0"` into 0). No such clNr on
  hydra prd (a query for `id = 0 or cl_nr ~ '^[0-9]+$'` returned only id 0, whose clNr is `'System'`). Fix: same `== null || === ''`
  form, or disable dynamicTyping for that column. Confidence: MEDIUM.

- **[Info] `components/reports/popups/exportReport.vue:136` is NOT reachable with numeric 0.**
  `filter: this.filter && this.filter != 'All Shippers' ? this.filter : null`. Its callers:
  - `flowbinReport`, `inventoryReport`, `lockReport`, `outboundParcelReport`, `parcelPickingReport`, `receivingReport`,
    `skuLocationReport` bind `:filter="shipper"` where the v-select uses `item-value="clNr"` (a string; System-Client's is
    `'System'`, truthy). Numeric 0 cannot appear.
  - `stockUnitRecord.vue:107` binds `:filter="String(shipper == null ? -1 : shipper)"`, so 0 arrives as the truthy string `"0"`
    (and the comment at lines 99-103 documents exactly this hazard).
  - `containerRecord.vue:75-79` passes no `filter` at all, and that component binds no shipper filter, so 0 cannot reach the guard.
  The guard is a latent trap for any future numeric caller; a defensive rewrite (`this.filter != null && this.filter !== '' && ...`)
  is optional. Confidence: HIGH.

- **[Info] Report-store truthiness on shipperFilter is clNr-typed and safe.** e.g. `components/reports/flowbinReport.vue:319`
  `if (this.$store.state.reports.flowbin.shipperFilter) {` and `store/reports/outboundParcel.js:141`
  `const clientNumber = context.state.shipperFilter || null` — all clNr strings. Safe while no clNr is `''` or `"0"`-coerced.

- **[Info] Already-correct siblings (good precedent):** `store/internalOps/replenishments.js:172,413`
  `if (context.state.openShipperFilter != null) {`; `components/handlingUnits/containerTable.vue:449`,
  `stockUnitsTable.vue:684` `clientId: this.selectedShipper == null ? -1 : this.selectedShipper`;
  `store/handlingUnits/*.js` `?? -1`; `store/admin/configuration.js:400` `!== null && !== undefined`.

- **[Info] wms2-mobile-ui: no hits.** 36 lines mention client id / shipper on origin/develop; none sits in a truthiness guard.

### 5. General quality

- **[Low] Pre-existing noise in touched functions** (not introduced here): `cycleCount.js:131` `console.log('data ', data, data != null)`
  and the duplicated `this.$toast.error(...)` in the `searchPlannedRequests` catch (two identical toasts). Out of scope; mention only.
- **[Info]** Inline comments cite the ticket and the reason (`// != null, not truthiness: client id 0 is a real shipper`), which
  protects against a well-meaning revert. Good.
- Lint/type: plain JS in a Nuxt 2 repo, no TS/LSP diagnostics applicable; the specs run green.

## Summary

| Severity | Count |
|---|---|
| Critical | 0 |
| High | 0 |
| Medium | 1 (inboundBolUpload Shipper ID 0 — sibling, not in the diff) |
| Low | 4 (M7 undefined test gap; component-level pin; skuUpload clNr `0`; pre-existing console/toast noise) |
| Info | 8 |

Positive: wire-level assertions with `URLSearchParams`, both URL-building paths for both actions covered, null wire shape pinned on
both paths, every revert mutant killed, backend contract verified, comments explain the why.

The diff itself is correct and complete for the ticket. The one Medium is a same-class sibling outside the diff; under the
"findings go on the ticket you are in" rule it should be fixed on SBDEV-3437 (or explicitly deferred on the ticket), together with
the one-line `undefined` test.

VERDICT: APPROVE-WITH-FIXES

## Re-review of a97865b

Scope: `git show a97865b`. It changes `inboundBolUpload.vue:118` and `skuUpload.vue:118` to `== null || === ''`, adds
`test/components/admin/systemManagement/uploads/shipperZeroUploadValidation.spec.js` (new), and adds a
`dispatch(undefined)` case in `cycleCountShipperFilter.spec.js`. `git diff origin/develop` is now 7 files, +146 −7.
The worktree was clean before and after the review. The full suite run here (`npx jest --coverage=false`) gave
**124 suites / 2209 tests passed, 0 failed**, which matches the commit message.

### (a) Does the fix add a new defect?

I fed real Papa 5.5.3 output to the old and new checks, using the components' own options
(`header: true, dynamicTyping: true, skipEmptyLines: true`). Papa's `parseDynamic` can only return
true, false, a number, a Date, `null` (for `''`), a non-empty string, or `undefined` (a missing trailing column).
It never returns NaN, because `testFloat` requires a digit match.

| cell | parsed value | old `!v` rejects | new check rejects | changed? |
|---|---|---|---|---|
| `0` | `0` | yes | no | yes, this is the fix |
| ` 0 ` / `-0` | `0` / `-0` (serialized as `0`) | yes | no | yes, same as `0` (intended) |
| *(empty)* | `null` | yes | yes | no |
| *(missing column)* | `undefined` | yes | yes | no |
| `   ` (whitespace only) | `"   "` (string) | **no** | **no** | no |
| `true` / `TRUE` | `true` | no | no | no |
| `false` / `FALSE` | `false` | yes | **no** | **yes** |

- **[Low] A Shipper ID cell of `false`/`FALSE` is now accepted on the client.**
  - Where: `components/admin/systemManagement/uploads/inboundBolUpload.vue:118`, `if (clientId == null || clientId === '')`.
  - Before: the row was rejected with a wrong message ("Shipper ID cannot be empty").
  - Now: it is posted. The backend `FileImportController.importInboundBols` does
    `clientRepository.existsById(Long.parseLong((adviceDto.getClientId())))`, so the value `"false"` (or a Jackson 400,
    depending on boolean→String coercion) fails the whole request. Rows before it may already be saved.
  - This is not a new class of bug. `true`, `abc`, `1.5`, and whitespace-only cells already took exactly this path before and
    after the change. `false` simply joins them.
  - Optional hardening for all of them in one place: on the BOL Shipper ID check, also reject anything that is not an integer,
    e.g. `!Number.isInteger(clientId)` with the message "must be a numeric shipper id".
  - Confidence: HIGH on the client-side change (measured); MEDIUM on the exact HTTP status from the backend.
- **[Info] skuUpload `false`.** `skuUpload.vue` posts `clientNumber: false` → `findByClNr("false")` → a per-row
  "client does not exists" error (FileImportController:362-364). The row is handled cleanly, so no harm.
- **[Info] Whitespace-only cells behave exactly as before.** `"   "` is not a float and is not `''`, so it stays a truthy
  string. The old check and the new one both accept it. Neither treats whitespace as empty; that gap already existed and
  is out of scope.
- **[Info] dynamicTyping also mangles shipper codes, out of scope.** Turning dynamicTyping on for `Shipper Code` rewrites
  codes such as `0042` → `42` and `-0` → `0` before validation. That is an existing data-fidelity issue that this ticket
  neither causes nor fixes. A per-column `dynamicTyping: { 'Shipper Code': false }` (or
  `dynamicTypingFunction`) would fix it at the source. Note it on the ticket if wanted.

### (b) Do the new tests guard what they claim to?

Mutation probes, run in a scratch copy:

| mutant | result |
|---|---|
| BOL revert to `!clientId` | killed (`accepts a numeric 0 shipper cell`) |
| SKU revert to `!clientNumber` | killed |
| BOL / SKU drop the `=== ''` arm | killed (`still rejects an empty shipper cell ("")`) |
| BOL `=== undefined \|\| === ''` (lets null through) | killed (`(null)` case) |
| SKU `=== null \|\| === ''` (lets undefined through) | killed (`(undefined)` case) |
| cycleCount data guard `!== null` (old M7) | **now killed**, 2 failures (`omits clientId when it is undefined`, planned + closed) |
| BOL additionally rejects `false` (a stricter variant) | survives, as expected: no test pins `false` either way |

- The tests do guard what the commit claims. Calling `validate.call({}, ...)` directly is sound: `validate()` reads nothing
  from `this`, as I confirmed by grepping the method body.
- **[Info] The fixtures are hand-built rows, not Papa output.** The table under (a) confirms that Papa really does emit
  `0` for `0`, `null` for blank, and `undefined` for a missing column, so the fixtures match what production sees.
  Optional: one test that runs `Papa.parse` on a CSV string (`header` + `dynamicTyping`, synchronous on a string) would
  pin that link if the parser options ever change.
- **[Info] No test pins `false`.** That fits the finding above being optional. If the integer check is added, add
  `false`/`true`/`'abc'`/`1.5` rejection cases with it.

### (c) Status of the earlier findings

| earlier finding | status |
|---|---|
| [Medium] inboundBolUpload rejects Shipper ID 0 | **closed** (fixed, and both revert and partial mutants are killed) |
| [Low] no `undefined` data-path test (M7) | **closed** (M7 now killed) |
| [Low] skuUpload `!clientNumber` | **closed** |
| [Low] no component-level pin for dropdown 0 → dispatch | open, by choice. It was optional; I accept leaving it out because the hand-off is a straight pass-through |
| [Low] existing `console.log` / duplicate toast clutter in `searchPlannedRequests` | open, mention-only, out of scope |
| Info items (exportReport, report-store clNr guards, mobile-ui, `??` support) | unchanged and still correct |

New from this pass: one Low (the `false` cell now reaches the existing non-numeric-id failure path) and three Info items.
None of them blocks the change.

VERDICT: APPROVE

---

> **Archived 2026-10-07.** T1, so there is no plan doc; the triage and evidence are on the ClickUp ticket. Merged as wms2-web-ui PR #162 (`5fcbd8a`) into `develop`; ClickUp `on dev`.
> Implementation worktree(s) removed 2026-10-07: wms2-web-ui/SBDEV-3437
