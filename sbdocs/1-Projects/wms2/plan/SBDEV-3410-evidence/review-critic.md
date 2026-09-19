# SBDEV-3410 — CRITIC review (independent lane)

**Reviewer:** critic lane, read-only. **Date:** 2026-09-18.
**Target:** `SBDEV-3410-stock-unit-record-shipper-filter-and-product-name.md` (1,386 lines, fixed snapshot).
**Instruments used:** `git show/grep/log origin/develop` in `v2/wms2-api` @ `29ce240d` and `v2/wms2-web-ui` @
`a27703eb` (both confirmed to be the current `origin/develop` tips, matching the plan's frontmatter);
read-only SQL against the `wms2-wineco-dev` MCP target, which reports `current_database() = dev_wh01_om1` —
the same tenant the plan measured. Nothing was mutated: no DDL, no writes, no branches, no worktrees.

## VERDICT: **ITERATE**

Three findings change what gets shipped, not merely how it is described. Two of them (C-1, C-2) would land
as silent wrong-data behaviour on the exact acceptance criterion they sit under, and both trace back to one
root cause (C-3): the §0 enumeration missed the two closest precedents in the repo — which happen to be the
sibling half of this plan's own parent ticket, and which carry an in-source comment that contradicts the plan
in writing.

This is otherwise a strong plan. Its measurements are unusually reproducible: I re-derived 28 independent
quantitative claims and **every one matched**, including the two that carry the whole design (join
elimination, and the filtered-first-page regression). The failures are, as the standing pattern predicts,
concentrated in the completeness claims and in one arithmetic conflation.

---

## 1. What reproduced

Re-derived independently. `✓` = my instrument agrees with the plan's number.

| # | Plan's claim | My measurement | |
|---|---|---|---|
| 1 | base commits `29ce240d` / `a27703eb` | both are the current `origin/develop` tips | ✓ |
| 2 | `stockrecord` = 9,726,795 rows | 9726795 | ✓ |
| 3 | `itemdata` 8,808 rows, 8,721 distinct `item_nr` | 8808 / 8721 | ✓ |
| 4 | `uk3l3dgof3l6mc1dl7s3lmida65` = `UNIQUE (client_id, item_nr)` | `pg_get_constraintdef` returns exactly that; it is the table's only unique constraint | ✓ |
| 5 | ARW = `client_id 60500`, 873,021 rows | 873021; `client` row is `(0,'System',…)`,`…`,`(60500,'ARW','Argyle Winery')` | ✓ |
| 6 | `item_nr`-only join inflates ARW to 887,856 (+14,835) | 887856 | ✓ |
| 7 | pair join multiplies 0 — ARW 873,021→873,021, whole table 9,726,795→9,726,795 | both exact | ✓ |
| 8 | 0 of 9,726,795 rows fail to resolve a SKU | `count(*) FILTER (WHERE i.id IS NULL)` = 0 | ✓ |
| 9 | Join elimination: the unfiltered count over the view plans as a bare `Parallel Seq Scan on stockrecord sr` | `EXPLAIN` over the inline-equivalent derived table: `Finalize Aggregate → Gather (Workers Planned: 4) → Partial Aggregate → Parallel Seq Scan on stockrecord sr`. **Both joins eliminated.** | ✓ |
| 10 | Filtered first page today: `Index Scan Backward using index_stockrecord_created`, `Rows Removed by Filter: 7,564,825` | identical plan, `Rows Removed by Filter: 7564825`, 1,755 ms (plan: 2,865/1,987 ms — same order, shared box) | ✓ |
| 11 | `stockrecord` has 13 indexes; `index_stockrecord_created` is `btree (created)`; no `(client_id, created)` composite | 13; `CREATE INDEX index_stockrecord_created … btree (created)`; no composite | ✓ |
| 12 | `stockrecord_view` does not exist on any tenant | 0 rows in `information_schema.views` on `dev_wh01_om1` | ✓ (one tenant) |
| 13 | 45 users hold `WEB_UI_VIEW_STOCK_UNIT_RECORD`; **0** hold none of the eleven | 45 / 0, traversing `mywms_group_mywms_user → mywms_group_mywms_role → mywms_role_mywms_function → mywms_function` | ✓ |
| 14 | positive controls on that zero | fake function → 0 holders; any-function → 54 users. Both controls behave | ✓ |
| 15 | `exposeIdsFor(…)` lists `Stockrecord.class, Stockunit.class, StockView.class` | `RestConfiguration.java`: `… Shippingmethod.class, ShippingmethodShipperid.class, Stockrecord.class,` / `Stockunit.class, StockView.class, Unitload.class,` | ✓ |
| 16 | `SDR_WRITE_WITHDRAWN` holds both `StockView` and `Stockrecord` | `net.aim_ai.wms.model.StockView.class,` / `net.aim_ai.wms.model.Stockrecord.class,` | ✓ |
| 17 | `SdrFunctionRules` holds 7 `rules.put(...)`, none for `Stockrecord`/`StockView` | 7 `rules.put(` lines: User, UserFunction, UserGroup, UserGroupUser, UserRole, Sysprop, Message | ✓ |
| 18 | `allClients` is an ANY-of **eleven**, `WEB_UI_VIEW_STOCK_UNIT_RECORD` absent | exactly the eleven the plan lists, in that order; SUR absent | ✓ |
| 19 | `Sbdev3017TrancheGateContextTest` pins `allClients` with the same eleven | `row("ClientController", "/v3/client/allClients", "WEB_UI_VIEW_CLIENT", …)` | ✓ |
| 20 | `AdminController.toFilterId` is `protected static Long`, folds null/blank/non-numeric to `-1L` | verbatim | ✓ |
| 21 | `@Formula` occurs 0× in `src/main/java`; positive control `@Column` hits 65 model files | `git grep -c '@Formula' … \| wc -l` → 0; `git grep -l '@Column' … model/*` → 65 | ✓ |
| 22 | `b20eb9f1` = SBDEV-3417 and is on `develop` | `b20eb9f1 SBDEV-3417: withdraw 53 exported SDR searches that cannot be rendered`; `git merge-base --is-ancestor` → yes | ✓ |
| 23 | View-migration precedent is **three statements in two files** (V2.2.01 ×1, V2.2.02 ×2), excluding V2.2.00 | exactly those three `CREATE OR REPLACE VIEW` lines | ✓ |
| 24 | `V2.2.32` is the max on develop; `V2.2.33` is free | max is `V2.2.32__adviceposition_notified_damaged_amount.sql`; `git log --all --diff-filter=A -- 'db/migration/V2.2.3*'` shows only 30/31/32 added on **any** ref | ✓ |
| 25 | `**/*IT.java` is in the failsafe `<includes>`; surefire excludes only `*IntegrationTest`/`*E2ETest` | both confirmed in `pom.xml` | ✓ |
| 26 | `MIGRATION_LOCATION = "classpath:db/migration"`; only `BaseControllerUnitTest` + `BaseControllerIntegrationTest` exist | both confirmed | ✓ |
| 27 | Nine `sortable: true` header values, exactly as listed | `created, type, activitycode, itemdata, fromstoragelocation, tostoragelocation, amount, amountstock, operator` | ✓ |
| 28 | Every `stockrecord` column is projected unchanged (strict superset) | the table has **24** columns and the plan's `SELECT` lists all 24 in `ordinal_position` order, then adds `item_id, item_name, cl_nr, cl_name` | ✓ |

Also confirmed verbatim: `stockUnitRecord.vue` contains no `<v-select>` and no `:filter` on `<export-report>`;
`store/reports/stockUnit.js` emits `'&state=' + data.state` with no caller supplying `state` and reads
`results._embedded.stockrecord`; `mixins/searchUrlSync.js` has
`const possibleProps = ['search', 'keyword', 'filter', …]` and binds the **first** match in `$data` from its
own `created()` hook, so `keyword` (index 1) beats a hypothetical `filter` (index 2) — the §3.9 trap is real
but self-limiting, and the plan says so; `store/reports/inventory.js` really does use the bitwise
`data.clientNumber != null & data.clientNumber !== 'All Shippers'`, and the `!== 'All Shippers'` arm really is
vestigial (the "All Shippers" entry is `{ name: null, label: 'All Shippers' }` with no `clNr`, so under
`item-value="clNr"` the model is `undefined` and `undefined != null` already short-circuits);
`exportReport.vue` declares `props: ['show', 'reportType', 'filter', 'includeShipped']` and builds
`filter: this.filter && this.filter != 'All Shippers' ? this.filter : null,`; `ClientController.allClients`
returns `clientRepository.findAll(PageRequest.of(0, count.intValue(), Sort.by("name")))` — i.e. **every**
client, unfiltered.

**Not reproducible by me, stated rather than disputed.** The composite index's 6.3 s build / 276 MB /
0.455 ms figures, the 17,942 ms `item_name` sort with its 54,984 kB per-worker spill, and the 4,090 ms
`cl_nr` vs 987 ms `client_id` comparison all require either building the index or creating the view. I am
read-only and `hypopg` is not installed on this server, so I could not simulate the index either. I note that
the *decision-carrying* half of the index argument — that the filtered first page is catastrophic **without**
it — reproduced exactly (row 10), so the conclusion stands on evidence I could check even though the
"after" number rests on the author's say-so.

---

## 2. Findings that change the work

### C-1 (HIGH) — `client.id = 0` exists, is a real shipper, and silently breaks AC-2

**The plan says** (§3.6, "⚠ `exportReport.vue`'s truthiness guard"):

> "Client ids are database sequence values and `0` is not among them on `dev_wh01_om1` (derived by
> `SELECT min(id) FROM client`), but the guard would misread a `0` id if one ever existed. Not changed by
> this ticket — recorded so the next reader does not mistake it for new."

**Two independent instruments say otherwise.**

*Instrument 1 — the same query the plan names.* `SELECT id, cl_nr, name FROM client ORDER BY id LIMIT 5` on
`dev_wh01_om1` returns `{'id': 0, 'cl_nr': 'System', 'name': 'System-Client'}` as the first row. `min(id)`
is **0**, not a positive sequence value. That client owns **16** `stockrecord` rows, so it is a live,
selectable, non-empty entry in the dropdown this ticket adds.

*Instrument 2 — the repo's own source, at `origin/develop`.*
`v2/wms2-web-ui/components/handlingUnits/stockUnitsTable.vue` carries this comment, written for
**SBDEV-2976 Gap 2** — the sibling half of the very ticket SBDEV-3410 was split out of:

> "`== null ? -1 :`, never `|| -1`. Client id 0 is a REAL shipper — 'System-Client', seeded
> by V2.2.00 and present on Hydra PRD, where it owns 52 unit loads — and it is returned by
> the unfiltered allClients, so it appears in this very dropdown. `0 || -1` would map it
> onto the "no filter" sentinel and show every shipper's rows. The API does not fold 0:
> only NULL and -1 mean "no filter" there."

`components/handlingUnits/containerTable.vue` repeats the short form of it at its own dispatch site.

**What breaks.** The plan's AC-2 implementation is one attribute: `:filter="shipper"` with
`item-value="id"` (§3.9). Select **System-Client** and `shipper` is the number `0`. `exportReport.vue` then
evaluates `filter: this.filter && … ? this.filter : null` → `0` is falsy → it sends `filter: null` → the
plan's own controller read `toFilterId(String.valueOf(null))` folds `"null"` to `-1L` → **"no filter"**. The
table shows 16 System-Client rows; the downloaded `.xlsx` contains every shipper's rows. No error, no toast,
no non-200 — a silent wrong-data export, which is the worst failure shape a report can have, and it lands
directly on the acceptance criterion that introduces it.

This is not a hypothetical the plan chose to accept. The plan declined to mitigate it *because it believed
the value could not occur*, and that belief is false on the tenant it measured and (per the sibling's
comment) on Hydra PRD.

**Cheapest correct fix, staying inside the plan's own scope.** Do **not** change `exportReport.vue` — it is
shared by eight report components and changing its guard is a separate blast radius. Pass an already-folded
value from the one component this ticket touches:

```html
<export-report :show="showExport" :reportType="reportType" :filter="shipper == null ? -1 : shipper" … />
```

`-1` is truthy, survives the guard, and `toFilterId("-1")` → `-1L` → "no filter" — exactly the semantics the
plan's own §3.4/§3.6 already define, and exactly the `== null ? -1 :` idiom the two sibling components
already use. It is one expression and it makes the whole null/absent/`0`/`-1` matrix testable.

**And it needs an AC and a test.** Add to AC-2 an explicit value matrix (see §4 below), and to §7.4 a Jest
case asserting that selecting the client whose `id` is `0` produces a request carrying `filter: 0`, not
`filter: null`. Without that case the defect is invisible to every test in the plan.

### C-2 (HIGH) — the export predicate has no `IS NULL` arm, and `/api/stockrecord/search/findByOffsetAndLimit` is an exported SDR route

**The plan proposes** (§3.6) that `StockrecordRepository.findByOffsetAndLimit` gain:

```sql
AND (CAST(:clientId AS bigint) = -1 OR p.client_id = CAST(:clientId AS bigint))
```

Compare its own read-path predicate (§3.4), which has three arms:
`p.clientId = :clientId OR :clientId IS NULL OR :clientId = -1`. The export version drops the `IS NULL` arm.

**Why that matters.** `findByOffsetAndLimit` is **not** a private service helper. On `origin/develop` it
carries `@RestResource(path = "findByOffsetAndLimit", rel = "findByOffsetAndLimit")` with **no**
`exported = false`, so `GET /api/stockrecord/search/findByOffsetAndLimit?keyword=&offset=0&limit=100` is a
live HTTP route today. Spring Data REST binds a missing `Long` parameter to `null`. With the proposed
predicate and `:clientId = NULL`, both disjuncts evaluate to `NULL`, the conjunction is `NULL`, and **no row
qualifies**. Verified directly against `dev_wh01_om1`:

```sql
SELECT count(*) FROM stockrecord p
WHERE (CAST(NULL AS bigint) = -1 OR p.client_id = CAST(NULL AS bigint)) AND p.client_id = 60500;
-- 0     (the same query without the first conjunct returns 873,021)
```

So every existing caller of that route that does not know about the new parameter gets `[]` — an empty list,
not an error. That is the failure mode the plan itself flags as untestable elsewhere ("an over-gated read
renders an empty screen rather than an error… invisible to every test").

**§6 does not list this surface at all.** The Backward-Compatibility table covers
`/api/stockrecord/search/findByKeyword`, `/api/stockrecordView/search/findByKeyword`, both
`exportStockUnitRecord` routes, `stockRecordDetailsById`, `allClients`, the HAL payload, the DB schema and
the spreadsheet — nine rows, every one "**No**" breaking — and omits the one route the change actually
breaks. Q5 debates withdrawing `findByKeyword` (which this ticket does not touch) while leaving
`findByOffsetAndLimit` (which it does) unmentioned.

**Fix, two lines.** Either write the predicate with all three arms —
`AND (:clientId IS NULL OR CAST(:clientId AS bigint) = -1 OR p.client_id = CAST(:clientId AS bigint))` —
or, better, do both: add the arm **and** withdraw the route
(`@RestResource(exported = false)`), which is consistent with the SBDEV-3417 programme and with the fact that
its only in-process caller is `ReportService`. Add a §6 row either way, and add an IT case
`nullClientIdMeansNoFilterOnTheNativeQuery` next to the existing `exportPredicateRendersOnPostgres`.

Note also that `UnitloadRecordRepository.findByOffsetAndLimit` is the identical-shape sibling (it backs
`exportContainerRecord`). Not this ticket's scope, but the §0 sibling sweep should have surfaced it.

### C-3 (HIGH, process) — §0 missed the two closest precedents, and they are the sibling half of this plan's own parent ticket

The §0 derivation greps `getClients` over `*.vue` and reports "7 report files hit". I reproduced that exactly
(7 files). But the same grep, **unrestricted**, returns 26 dispatch sites in 15 files — and among them are
`components/handlingUnits/containerTable.vue` and `components/handlingUnits/stockUnitsTable.vue`, which the
plan never mentions in any section.

Those two components implement the shipper filter **that this plan is about to re-derive**, under
SBDEV-2976 Gap 2, and they already made every decision the plan re-opens:

| Decision | `handlingUnits/*` (already shipped) | The plan (§3.9, presented as new) |
|---|---|---|
| dropdown value | `item-value="id"` | `item-value="id"` — same, but justified only against `inventoryReport.vue`'s rejected `clNr` |
| wire parameter | `clientId` | `clientId` — Q1 records "accepted cost: the wire format differs from the six sibling reports". It does **not** differ from these two. |
| "no filter" sentinel | `-1`, folded with `== null ? -1 :` and explicitly **never** `\|\| -1` | `-1`, but folded nowhere on the UI side |
| where the filter lives | in the Vuex store, with the reason in-source: *"this module also refreshes the grid from payload-less dispatches after a write, and a component-only filter would silently drop out of those requests"* | in Vuex, justified instead by the weaker `searchUrlSync` argument |
| store mutation | *"merge, never replace; search and sort must survive a filter change"* — `Object.assign({}, state.list, { clientId: payload.clientId ?? -1 })` | `setShipperFilter` copied from `inventory.js`, no merge-vs-replace note |
| widget | `<v-autocomplete>`, because *"137 shippers hold containers on the ShipItEZ warehouse that requested this, past the point a scrolling list is usable"* | `<v-select>`, copied from `inventoryReport.vue` |
| client id 0 | warned about in two files | asserted not to exist (see C-1) |

Consequences, in order of cost: C-1 exists **only** because this precedent was missed. Q1's stated accepted
cost is wrong — there is no divergence to accept, there is an established convention to follow. And the
`<v-select>` choice inherits a UX problem a sibling already measured and solved.

**What to change.** Re-run the §0 derivation without the `components/reports/` restriction; add
`handlingUnits/{containerTable,stockUnitsTable}.vue` and `store/handlingUnits/{container,stockUnits}.js` as
the primary REFERENCE rows, demote `inventoryReport.vue` to "the older `clNr` shape, rejected by Q1", and
re-decide `<v-select>` vs `<v-autocomplete>` explicitly against the shipper count on the target tenants.

---

## 3. Findings that change the confidence, not the design

### M-1 (MEDIUM) — the `ClassCastException` failure shape in §3.6 is wrong, and a TDD-gate author will encode it

§3.6 states that a `(String) reqMap.get("filter")` cast on a numeric filter

> "is caught by `exportStockUnitRecord`'s own second catch block … and turned into a **200 with an error
> body**, which the UI writes to disk as a downloaded `.xlsx` containing an error string."

That cannot happen at the natural insertion point. In `ReportController.java`, **all seven** existing
`String filter = (String) reqMap.get("filter");` reads sit at the top of their method, *above* the `try {` —
the same position as `exportStockUnitRecord`'s own `Integer offset = (Integer) reqMap.get("offset");` /
`String keyword = (String) reqMap.get("keyword");`. A cast placed there throws **out of** the method; the
second catch block never sees it. The result is a 500 through Spring's default handler, and in the MockMvc
lane the test's `mockMvc.perform(...)` call itself throws a nested `ServletException` — it does not return a
status to assert on.

The recommended fix (`toFilterId(String.valueOf(...))`) is correct either way, so the design does not change.
But three downstream artefacts are written against the wrong shape and would be wrong if implemented
literally: §7.3's `numericFilterIsForwarded` ("does not throw"), §7.8's mutation row *"change the read back to
`(String) reqMap.get("filter")`"*, and §7.7's manual row *"Export does not silently 200 an error"* — which
describes an outcome this cause cannot produce.

Restate it as: *a `(String)` cast on a JSON number throws before the try block, so the mutant surfaces as a
thrown `ClassCastException` out of the handler (a nested `ServletException` in the MockMvc lane), not as a
200.* Then the mutation kill is attributable and the test asserts the right thing.

Minor sibling note, same paragraph: the plan says the second catch block "exists on this method and not on
its siblings `exportInventory`/`exportOutboundParcel`". True of the two it names, but
`exportContainerRecord` has one too — `grep -n "catch (Exception e)"` returns exactly two hits, at the
`exportStockUnitRecord` and `exportContainerRecord` methods. The phrasing reads as uniqueness.

### M-2 (MEDIUM) — §3.8 states the invariant and then applies it to one instance

§3.8 and RALPLAN-DR Principle 3 both put the rule as: *"every screen carrying a shipper dropdown contributes
its view function to `allClients`."* The same sweep that finds Stock Unit Record finds a screen that already
violates it:

- `util/appMenuList.js`: `{ icon: 'mdi-sitemap', text: 'Handling Units', to: '/handlingUnits/handling-units', fn: ['WEB_UI_VIEW_STOCK_UNIT', 'WEB_UI_VIEW_CONTAINER'] }`
- `components/handlingUnits/containerTable.vue` and `stockUnitsTable.vue` both dispatch `admin/client/getClients` and both render a shipper `<v-autocomplete>`.
- Neither `WEB_UI_VIEW_STOCK_UNIT` nor `WEB_UI_VIEW_CONTAINER` is in `allClients`'s eleven.

So the defect the plan discovers is **already live**, on a screen that shipped with the same parent ticket.
I ran the plan's own blast-radius query for it on `dev_wh01_om1`: 45 users hold one of those two functions
and **0** of them hold none of the eleven — identically latent to the Stock Unit Record case, with the same
one-tenant caveat (Q6). P5 costs nothing extra to make it twelve→fourteen and fix the rule rather than the
instance; leaving it means the plan's own Principle 3 example is the place the principle was not applied.

### M-3 (MEDIUM) — the "shipper is a computed" mutant cannot kill

§7.8's last row and §5.2 P6's last checkbox specify:

> "Mutation-check: make `shipper` a `data()` property instead of a computed and confirm a spec asserting
> `'filter' in wrapper.vm.$data === false` goes red."

Those are two different mutants. The mutant described ("make `shipper` a `data()` property") introduces a key
named **`shipper`**, which is not in `searchUrlSync`'s `possibleProps` at all — so `'filter' in $data` is
still `false` and the assertion stays **green**. The mutant survives.

The assertion that grades the stated design rule is `expect('shipper' in wrapper.vm.$data).toBe(false)`.
(The assertion that grades the `searchUrlSync` hazard is a different one, and as the plan itself notes in
§3.9, that hazard is already neutralised by `keyword` sorting first — so it is the weaker of the two.)

### M-4 (MEDIUM) — `exposeIdsFor` is called mandatory, is a named mutation target, and no test carries it

§3.5 calls the `exposeIdsFor` entry mandatory and explains the failure precisely
(`/stockRecordDetailsById/undefined`). §7.8 lists the mutant "remove `StockrecordView.class` from the list"
with the kill "assert `id` is in the HAL body". But neither §7.2 test can make that assertion:
`StockrecordViewSchemaIT` checks the schema and `StockrecordViewRepositoryFilterIT` is a repository test —
`exposeIdsFor` only affects HAL **rendering**, which needs a MockMvc/full-context request. §8 step 3 checks
it by hand.

The repo has the lane for this: the `security/*ContextTest` classes issue real SDR requests through MockMvc
(e.g. `SdrReadGateEnforcementContextTest`). Name a test that performs
`GET /api/stockrecordView/search/findByKeyword` and asserts `$._embedded.stockrecordView[0].id` exists, or
the mutation row is unexecutable and the "mandatory" claim is enforced by nothing but the manual plan.

### M-5 (MEDIUM) — `EntityColumnNameResolutionArchTest` and `ddl-auto=validate` already exist; the plan cites neither, which mis-grades one mutation and mis-states one justification

Two repo-wide rails already cover §3.3 rule 3 / §7.5 row 4:

1. `src/test/java/net/aim_ai/wms/unit/config/EntityColumnNameResolutionArchTest.java` — *"Every persistent
   field of a JPA-mapped class in this codebase must either carry an explicit `@Column(name = …)` /
   `@JoinColumn(name = …)`, or have a Java name that contains no uppercase letter."* It imports
   `net.aim_ai.wms.model` wholesale, so a new `StockrecordView` is picked up **automatically**, in surefire.
2. Its own javadoc records that *"as of **SBDEV-3285** … the `postgres-integration` profile runs
   `spring.jpa.hibernate.ddl-auto=validate`, so every mapped field of both persistence units is checked
   against its migrated schema on each context load in that lane."*

Two consequences.

**The P2 mutation is over-determined.** "Drop one `@Column(name = …)` and confirm the schema IT fails" would
turn *at least three* things red — the ArchUnit rule (surefire, first), every `postgres-integration` context
load, and the new schema IT. The plan's own standard for §7.8 is that the kill must be **attributable**
("the failure message names the thing broken"); a mutant that reds a whole lane does not meet it. Either
pick a mutant only the new IT can see, or state plainly that this one is covered by an existing rail and
drop it.

**The stated justification for `everyMappedColumnResolves` is the wrong one.** §7.5 row 4 justifies it as
the thing that catches a missing annotation — which rail 1 already does, earlier and repo-wide. Its real
value is the gap rail 2 leaves, which that same javadoc names: *"Hibernate's validator reports the FIRST
mismatch and stops, and it verifies a mapped column EXISTS with a compatible type — it does not enforce
nullability and ignores columns no entity maps."* A reflection check that enumerates **all** of
`StockrecordView`'s columns in one pass is genuinely stronger than a validator that stops at the first. Say
that, and the test survives review on its merits instead of on a duplicated claim.

### M-6 (MEDIUM) — P2 leaves a coverage set silently incomplete, and nothing goes red

`src/test/java/net/aim_ai/wms/security/SdrWriteWithdrawalContextTest.java` asserts
`assertThat(WITHDRAWN).hasSize(49);` over its own literal set, and its javadoc records:

> "**This set and `RestConfiguration.SDR_WRITE_WITHDRAWN` are now IDENTICAL — 49 names, measured by diffing
> them, zero difference in either direction.**"

P2 adds a 50th name to the production array and none to the test. I checked whether that breaks anything:
**it does not.** The test's set stays 49, all 49 still pass, and `StockrecordView`'s write-withdrawal is
simply never verified. The javadoc's "IDENTICAL" becomes false silently.

I also checked the other SDR inventory rails for closed-set ratchets that a new exported type would trip,
and — contrary to my initial hypothesis — **none of them breaks**: `SdrRuleInventoryContextTest` is
deliberately not a ratchet (*"Deliberately NOT a ratchet on the count… The assertion is only that Slice 1 did
not accidentally rule everything or nothing"*, asserting `isNotEmpty()`); `SdrSurfaceInventoryContextTest`
asserts only `resources > 20`; `SdrSearchParameterConversionContextTest` is scoped to `Pickingorder`. I state
this because a reviewer reading "a new SDR type breaks the inventory tests" would waste a cycle — it does
not. The finding is the opposite and smaller: **nothing catches the omission**, which is why §4 has to name
`SdrWriteWithdrawalContextTest` as a P2 edit (add the name, bump 49→50, correct the javadoc) rather than
relying on the suite.

### M-7 (MEDIUM) — P1→P2 is a build-order dependency, not only a deploy-order one

§5.1 row 4 lists "**P1 → P2 → …**" under *"Deploy-order dependencies"*, and P2's independence rationale is
*"it exposes a new read route the UI does not yet call."* Because of `ddl-auto=validate` (M-5, rail 2), P2
branched off a `develop` that does not yet carry `V2.2.33` fails **every** `postgres-integration` context
load, not just the new IT — a whole-lane red with a schema-validation message, which is a confusing first
failure. Say so in P2's preamble: *branch P2 only after P1 has merged to `develop`.*

---

## 4. Acceptance criteria — testability, AC by AC

This is the criterion that matters downstream, so I state for each AC the exact assertion a test would make,
and where it cannot be written.

**AC-1** — *"a Shipper / Brand dropdown, defaulting to 'All Shippers', populated from `admin/client/getClients`. Selecting a shipper narrows the table."*

*Testable:* yes for the first two clauses. Jest:
`expect(wrapper.find('#shipper').exists()).toBe(true)`;
`expect(wrapper.vm.shippers[0]).toEqual({ id: null, label: 'All Shippers' })`;
`expect(dispatchSpy).toHaveBeenCalledWith('admin/client/getClients')`.

*Not testable as written:* "narrows the table". The AC never states the **wire contract**, which is the only
thing a test can assert across the repo boundary — that the request carries `&clientId=<id>`, and that "no
selection" is `-1` (or absent), not `null`, not `''`, not `0`. That contract lives only in §3.4 and §3.9
prose. **Needs:** fold the sentinel semantics into AC-1, e.g. *"…and the request carries `clientId=<id>`;
with no selection it carries `clientId=-1`."* Otherwise the TDD gate writes an assertion against whatever
shape the implementer happened to choose, which is not a test.

**AC-2** — *"Export output respects the selected shipper."*

*Testable:* the happy path, yes — `ReportServiceUnitTest`:
`verify(stockrecordRepository).findByOffsetAndLimit(eq("k"), eq(60500L), anyInt(), anyInt())`.

*Not testable as written, and this is where C-1 hides.* "Respects" has no value matrix. The four inputs that
must be pinned are absent / JSON-null / `-1` / a real id — and the fifth, `0`, is the one that is currently
wrong. **Needs** a table in the AC itself:

| `filter` on the wire | expected |
|---|---|
| key absent | all shippers |
| `null` | all shippers |
| `-1` | all shippers |
| `""` or `"abc"` | all shippers |
| `60500` (number) | ARW only, no throw |
| **`0`** | **System-Client only** — not all shippers |

The last row is the one that fails against the plan as written.

**AC-3** — *"The table shows a SKU Name column, and the details popup shows the product name."*

*Testable:* both halves.
`expect(wrapper.vm.headers.map(h => h.value)).toContain('itemName')`;
`assertThat(details).containsEntry("itemName", "Pinot Noir 2019")`.

*Gap:* the AC does not state the unresolved-SKU behaviour, yet that is the plan's own mutation target
(`ifPresent` vs `put(null)`, `doesNotContainKey` vs `get() == null`). An AC that does not mention it cannot
generate that test. **Needs:** *"…and when the SKU string resolves to no `itemdata` row, the key is absent
from the payload and the row still appears in the table."* Note the second clause is what makes the
`LEFT`-not-`INNER` decision an acceptance criterion rather than an implementation detail — currently that
decision is graded only by an IT the ACs do not require.

**AC-4** — *"Keyword search, sorting and pagination continue to work in combination with the shipper filter."*

*The weakest of the four.* "Work" is not an assertion. §7.2's `keywordAndFilterAndSortAndPageCompose` says
"4 combinations (AC-4), asserting rows **and** `totalElements`" but never names the four, so two
implementers write two different tests.

**Needs** the combinations enumerated and, more importantly, the *specific* regression named. The realistic
failure here is not that sorting stops working — it is that the filter reaches the page query but not the
count query, so the table shows 10 ARW rows under a footer reading "9,726,795". Written as an assertion:
*"with `clientId=60500` and `keyword=''`, `page.totalElements` equals `SELECT count(*) FROM stockrecord WHERE
client_id = 60500`, not the unfiltered count"* — that is one line and it grades the thing that actually
breaks. Add the paging clause too: *"page 2 returns a disjoint row set from page 1 under the same filter."*

---

## 5. The other grading axes

**Principle–option consistency.** Largely real rather than decorative — Principles 4 and 5 visibly changed
choices (Q4 recorded as *policy with no technical enforcement* instead of claimed as a guarantee; four zeros
each given a control). Two exceptions, and both are instructive:

- *Principle 3 (invariant over instance)* is asserted for §3.8 and then not applied — M-2.
- *Principle 5 (a zero needs a positive control)* is the sharpest. The plan gives controls for the four
  zeros it chose to list. The claim in C-1 — *"`0` is not among them"* — is **also a zero**, is stated with
  its deriving query, has **no** control, and is false. It also "agrees with the comfortable conclusion",
  which the plan's own Principle 5 paragraph identifies as exactly when a bad instrument is hardest to
  notice. The principle is sound; it was applied to the zeros the author was already worried about.

**Fair alternatives (§9).** This is the strongest part of the document. 9.1 and 9.2 are invalidated on
evidence (a commit; a positive-controlled census), not taste. 9.3 is genuinely steelmanned — RALPLAN-DR
Option B says outright *"Not invalidated — genuinely viable, and rejected on cost and consistency, not on
impossibility,"* and names the condition under which it becomes right. 9.5 and 9.7 carry their own blind
spots. One defect: **9.4's stated cost is wrong.** It rejects `cl_nr` on measurement (correct) but prices the
decision as *"the wire format differs from the six sibling reports"* — and per C-3 it matches two existing
callers exactly. The alternative is rejected for the right reason at an inflated price, which is the mirror
image of a strawman: the *chosen* option was handicapped, not the rejected one.

**Risk mitigation clarity.** Mixed, and the pattern is clean — every risk the author *measured* has an
owner and a trigger; every risk they *inherited* has neither.

| Risk | Mitigation | Owner | Trigger | |
|---|---|---|---|---|
| ~6 s `SHARE` lock on `stockrecord` | accepted, sized, explained | implementer | the deploy boot that applies V2.2.33 (§8 step 2) | concrete |
| a tenant misses the migration → 42P01 behind green health | per-tenant `information_schema.views` + `pg_indexes` check | implementer | after each merge and each promotion (§5.1 row 8, §8 steps 2 & 7) | concrete |
| `V2.2.33` collision | re-run `check-migration-version-collision.sh` **immediately before merge** | whoever merges | §8 step 6 | concrete |
| rollback | honest: Flyway does not revert by reverting the file; forward migration needed; prefer reverting P6 | — | — | concrete, no owner named |
| `42501` ownership drift | `reassign-tenant-ownership.sh` named | operator | **none stated** — nothing says how you learn a tenant is frozen. The row-8 check would surface it, but only if someone runs it. | weak |
| Q6 — blast radius measured on one tenant | *"a cheap extra query against the prd MCP targets"* | **none** | **none** | weak — this is the one risk that is one query away from closed and it is left as prose |
| the numeric `filter` on a component shared by 8 reports | *"NO EDIT — already generic"* | — | — | **absent** — true that the seven String callers are unaffected, but nothing pins it |

**Phase independence.** I looked for a counterexample and found no violation of *independent reviewability*;
the ordering in §5.1 row 4 is correct, and the claim that P6-before-P3 degrades to "filter ignored on export"
rather than an error is right (the controller ignores `filter` today, so P6 alone is inert). Two
qualifications: M-7 (P1→P2 is also a build-order dependency) and the fact that P3 must widen four existing
`when(stockrecordRepository.findByOffsetAndLimit(any(), anyInt(), anyInt()))` stubs in `ReportServiceUnitTest`
— a **compile** break rather than a test failure, which the "extend the nested class" instruction does not
convey.

**Test adequacy / attributable kills.** Of the nine mutation rows in §7.8: four are good (zero-multiplication
and LEFT-vs-INNER, both with the fixture requirement correctly stated; `itemName` absence, with the
`doesNotContainKey` vs `get() == null` distinction exactly right; the `allClients` gate, which lands on a
full-varargs row as the standing guidance requires). One is over-determined (M-5). One predicts the wrong
failure shape (M-1). One has no test to execute it (M-4). One cannot kill (M-3). One — "make the controller
ignore `filter`" — is fine. That is 4 sound, 4 needing repair, 1 neutral.

**Length.** 1,386 lines, against the 1,142-line plan the tier router cites as the over-documentation failure
mode. My judgment: **the measurement content earns its length; roughly 200 lines of literal duplication do
not.** Concretely:

- **§3.1 prose vs. the SQL header — ~60 lines, verbatim duplication.** The same five arguments (join key,
  both-LEFT, elimination, keyword warning, column set) appear once as prose and once as SQL comment with the
  same numbers. The SQL header is the artefact that ships and is CRC-locked; the prose above it should be
  three lines pointing at it.
- **§9 vs. RALPLAN-DR "Viable options" — ~45 lines.** Option A/B/C/D restate §9.1–9.4 with the same evidence.
  Keep the options block (it carries the pros/cons framing) and cut §9.1/9.2/9.4 to one line each pointing
  at it.
- **§0 rows 19–24 and 35–44 — ~35 lines.** Sixteen "NO" / "REFERENCE" rows whose content recurs in §3.
  A single "out of scope, and why" paragraph replaces them.
- **§7.1 — ~25 lines** of repo-wide test-lane facts (surefire vs failsafe, the `-Dit.test` traps, the H2
  verdict) that are true of every ticket. They belong in `CLAUDE.md`, not in one plan.

That is ~165 lines of pure restatement, plus another ~40 across §7.5/§7.6's thirteen "No"/"N/A" checklist
rows — though those follow the repo's standing template, so cutting them is a template decision rather than
this plan's. Everything else — the §0 table, the measured tables in §3.1/§3.2/§3.4/§3.10, §7.2/§7.3, the
§10.3 "what the evidence did NOT establish" list — is enumeration and measurement, and I would not cut any
of it. §10.3 in particular is the best section in the document and should be the template for other plans.

---

## 6. Smaller claims that did not reproduce

None of these changes a decision; all are the kind of drift the repo's standing discipline asks to be caught.

| # | Plan says | Measured | Where it matters |
|---|---|---|---|
| 1 | *"87 SKU strings are shared between shippers"* | **71** strings are shared; **87** is the excess row count (`sum(count-1)` over duplicate groups = 87, confirmed). 8,808 − 8,721 = 87 is a row surplus, not a string count. | §3.1 **and the `V2.2.33` SQL header**, which the plan instructs the implementer to copy. Flyway's CRC32 covers comments, so once it ships this sentence cannot be corrected without a new migration file. Fix before P1. |
| 2 | `getStockRecordDetails` *"builds a 22-key map that includes `clientNumber` and `clientName`"* | 22 unconditional `details.put(...)` calls **plus** `clientNumber` and `clientName` inside `if (s.getClientId() != null)` → **24** keys when client resolves, 22 when it does not. The sentence is self-contradictory: 22 is the count *without* the two keys it says are included. | §1, §2.3, §6. Harmless, but §6's row reads "22-key map → adds `itemName`", which an implementer may turn into a size assertion. |
| 3 | *"`StockView.java` annotates all eleven of its columns"* | `StockView` declares **12** persistent fields; **11** carry `@Column(name = …)`; the twelfth (`transfer`) carries `@Column(columnDefinition = "numeric")` with no `name` and identity-resolves because it is lowercase. | §7.5 row 4. Defensible under one reading, misleading under the obvious one. |
| 4 | Prereq 1: *"`V2.2.11` is permanently burned"* | `src/main/resources/db/migration/V2.2.11__seed_adjustment_alert_poll_sysprop.sql` **exists on `origin/develop`**. `db/migration/README.md` still says it is *"deliberately skipped… Do not reuse"* — the README is stale and the plan repeats it as current fact. | §5.1 row 1. Irrelevant to V2.2.33, but it is a false statement inherited without checking, and the README should be corrected on this ticket or another. |
| 5 | §1: *"**Six** sibling reports (Flowbin, Inventory, Lock, Outbound Parcel, Parcel Picking, Receiving, SKU Location — **7** files…)"* | Seven names, seven files. The "six" is inherited from `Sbdev3017TrancheGateContextTest`'s stale comment, which §3.8 correctly identifies as a rotting count — and then reproduces in §1. | §1. Self-inconsistent in one sentence. |
| 6 | The V2.2.33 collision sweep covered *"40 remote refs"* | the repo has **310** remote refs. My own sweep — `git log --all --diff-filter=A --name-only -- 'db/migration/V2.2.3*'`, which covers everything reachable from `--all` — returns only V2.2.30/31/32, so **the conclusion holds**. Only the stated coverage is understated. | §10.2 Q7. The conclusion is right; the sweep's described scope is not what was run. |

**A hypothesis I tested and disproved**, recorded so it is not re-tested: moving the table read from
`StockrecordRepository.findByKeyword` (no empty-keyword escape) to `StockrecordViewRepository.findByKeyword`
(`or :keyword = ''`) changes which rows the default unfiltered page returns *only if* some row has a `NULL`
in one of the five `CONCAT`ed columns. Measured: **0** rows on `dev_wh01_om1` have a NULL in `activitycode`,
`fromstoragelocation`, `fromunitload`, `itemdata` or `operator`. Positive control for that zero: the same
scan on `ordernumber` returns **2,352,543** NULLs, so the instrument reports non-zeros. The escape is
therefore a pure plan-shape optimisation here, as the plan treats it. Blind spot: one tenant.

---

## 7. What ITERATE requires

Blocking, in order:

1. **C-1** — client id `0`. Correct §3.6, fold the value on the `:filter` binding, add the value matrix to
   AC-2, add the Jest case. Cite `stockUnitsTable.vue`'s comment as the second instrument.
2. **C-2** — add the `IS NULL` arm to the export predicate (and preferably withdraw
   `findByOffsetAndLimit` from SDR); add the missing §6 row; add the IT case.
3. **C-3** — re-run §0 without the `components/reports/` restriction; make
   `handlingUnits/{containerTable,stockUnitsTable}` the primary reference; correct Q1's "accepted cost";
   re-decide `<v-select>` vs `<v-autocomplete>` explicitly.
4. **AC-1 … AC-4** — make each one encode the assertion a test would write (§4 above). AC-4 in particular
   needs the `totalElements`-vs-page regression named.
5. **M-1, M-3, M-4** — the three mutation rows that predict the wrong shape, cannot kill, or have no test.
6. Fix the six drifted claims in §6, **starting with #1**, which is the one that becomes uneditable once
   `V2.2.33` is applied anywhere.

Non-blocking but cheap and worth doing in the same pass: **M-2** (make P5 fourteen functions, not twelve),
**M-5** (cite the two existing rails and re-justify `everyMappedColumnResolves` on the "stops at the first
mismatch" gap), **M-6** (name `SdrWriteWithdrawalContextTest` as a P2 edit), **M-7** (say P2 branches after
P1 merges), the four `ReportServiceUnitTest` stubs P3 must widen, and the ~200 lines of duplication in §5.

I would re-review after 1–3 and 5; 4 and 6 are verifiable by reading.
