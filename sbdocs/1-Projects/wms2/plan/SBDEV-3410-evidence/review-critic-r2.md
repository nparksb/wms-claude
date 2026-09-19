# SBDEV-3410 — CRITIC review, ROUND 2 (ralplan consensus lane)

**Reviewer:** critic lane, read-only. **Date:** 2026-09-18.
**Target:** `SBDEV-3410-stock-unit-record-shipper-filter-and-product-name.md`, 1,984 lines (was 1,386).
**Instruments:** `git show/grep/log/for-each-ref origin/develop` in `v2/wms2-api` @ `29ce240d` and
`v2/wms2-web-ui` @ `a27703eb` (both re-confirmed as the current tips); read-only SQL against the
`wms2-wineco-dev` MCP target (`current_database() = dev_wh01_om1`); one `node -e` evaluation of the two
JavaScript expressions in question. Nothing mutated: no DDL, no writes, no branches, no worktrees, no edits
to the plan.

**Round-1 files read:** my own `review-critic.md`, plus `review-architect.md` and `review-architect-r2.md`,
now that the independence rule is closed. Where I agree with the architect I say so and say how I confirmed
it independently.

---

## VERDICT: **ITERATE**

Round 2 is a large, honest and mostly successful revision. **All three of my round-1 blocking findings were
re-derived by the author rather than taken on my word, and two of the three are fully discharged.** The six
drifted claims are all corrected, including the one that becomes uneditable once `V2.2.33` is applied. Three
of the four broken mutation rows are repaired and the fourth is correctly *dropped* rather than patched. The
ACs are now genuinely encodable, with one exception noted below.

I am nevertheless returning ITERATE, on a short list, because of one defect that I am responsible for:

> **C-1 is diagnosed correctly and fixed incorrectly. The fix I prescribed in round 1 does not work, the plan
> adopted it verbatim, and the mutation row written to protect it cannot kill.** Selecting *System-Client*
> still exports every shipper's rows.

That is not a re-litigation of round 1 — it is a new, executed measurement against the round-2 text. Three
further items are listed. None requires a rewrite; my estimate is one focused pass of well under a day.

---

## 1. My round-1 blockers, graded on their merits

### C-1 — `client.id = 0` — **NOT RESOLVED.** The diagnosis landed; the fix does not fix it

Everything the revision says about the *problem* is right, and I re-verified all of it:

| Claim | My measurement on `dev_wh01_om1` | |
|---|---|---|
| `min(client.id)` is `0`, `System-Client` | `min_client_id` = **0** | ✓ |
| that client owns 16 `stockrecord` rows | **16** | ✓ |
| `client` has 159 rows (the §3.9 shipper count) | **159** | ✓ |
| `exportReport.vue` guard is `filter: this.filter && this.filter != 'All Shippers' ? this.filter : null,` | verbatim at `components/reports/popups/exportReport.vue` line 136 | ✓ |
| 9 components mount `<export-report>`; 7 pass `:filter="shipper"`; all 7 use `item-value="clNr"` | 9 mounts, 7 `:filter="shipper"`, and `item-value="clNr"` in **all seven** files (checked one at a time) | ✓ |

**Now the fix.** §3.6, §3.9, §0 row 28 and §5.2 P6 all specify:

> `<export-report … :filter="shipper == null ? -1 : shipper" … />`

That expression maps `null → -1` and leaves every other value alone. **It does not touch `0`.** The falsy
collapse the finding is about happens *inside* `exportReport.vue`, downstream of the binding, and `0` is
still falsy when it gets there. Executed, rather than reasoned:

```js
const guard = f => (f && f != "All Shippers" ? f : null);   // exportReport.vue:136, verbatim
const fold  = s => (s == null ? -1 : s);                     // the plan's fix
const foldS = s => (s == null ? -1 : String(s));             // the fix that works
```

| `shipper` | mutant `:filter="shipper"` | **plan's fix** | `String(...)` fold |
|---|---|---|---|
| `null` (All Shippers) | `null` | `-1` | `-1` |
| **`0` (System-Client)** | **`null`** | **`null`** | **`"0"`** |
| `60500` (ARW) | `60500` | `60500` | `"60500"` |

Three consequences, in order of cost.

1. **The defect is unfixed.** Select System-Client, hit Export: the body carries `filter: null`,
   `toFilterId(String.valueOf(null))` folds `"null"` to `-1L`, the service takes the unfiltered branch and
   the `.xlsx` contains every shipper's rows while the grid shows 16. That is the exact silent-wrong-data
   outcome §3.6 spends a page establishing, landing on the acceptance criterion that introduces it.

2. **§7.8's new mutation row cannot kill.** The row is
   *"`:filter="shipper == null ? -1 : shipper"` → `:filter="shipper"` | the Jest client-id-`0` case —
   'expected `filter: 0`, received `filter: null`'"*. For `shipper = 0` the mutant and the fixed code produce
   **byte-identical** output (`null`). The only input on which they differ is `null`, and there both outcomes
   mean "no filter" at the API. This is the same failure class as round-1's M-3, re-created by the repair.

3. **AC-2's `0` row is unreachable by the specified design**, so the TDD gate will write a test that can
   never go green. §7.4's Jest case — *"selecting the client whose `id` is `0` produces a request carrying
   `filter: 0`"* — is **correctly worded**; it is the implementation that is wrong. The risk is that when it
   reds, the cheapest repair looks like weakening the assertion from the emitted POST body to the prop, which
   would certify the defect. Say in §7.4, in so many words, that the assertion is on the **request body built
   by `exportReport.vue`**, not on `wrapper.vm.filter`.

**I own this.** My round-1 §2 C-1 prescribed that exact expression and called it "one expression [that] makes
the whole null/absent/`0`/`-1` matrix testable". It does not. I checked `-1` against the guard and did not
check `0` against it — the same shape of error the plan's own **Principle 4** names: *a guard fences the
mechanism you aimed at*. The plan applied the fix faithfully; the prescription was wrong.

**Two fixes, both one line, neither touching `exportReport.vue`:**

- **A (preferred):** `:filter="shipper == null ? -1 : String(shipper)"`. `"0"` is a non-empty string and
  therefore truthy, survives the guard, `"0" != 'All Shippers'` holds, the body carries `"0"`, and
  `toFilterId(String.valueOf("0"))` → `0L`. Every other value is unaffected (`"-1"` → `-1L`, `"60500"` →
  `60500L`), and it removes the `ClassCastException` trap as a side effect rather than relying on it having
  been handled. Both the AC-2 matrix and the mutation row become live.
- **B:** widen `exportReport.vue`'s guard to `this.filter != null && this.filter != 'All Shippers'`. The plan
  rejects this as an eight-screen blast radius. That caution is reasonable but the blast radius is, on
  measurement, nil: all seven other callers bind `shipper` under `item-value="clNr"`, so the value is either
  `undefined` (which `!= null` rejects loosely, same as today) or a non-empty `cl_nr` string (truthy today,
  `!= null` true — same). If B is chosen, say that this is why, because "we did not change the shared
  component" is currently recorded as a safety property it does not need to be.

Whichever is taken, the §7.8 mutation row must be re-pointed at a mutant that can actually kill — with fix A,
`String(shipper)` → `shipper` is that mutant, and the Jest case reds with "expected `filter: \"0\"`, received
`filter: null`".

**What IS resolved under C-1, and I confirm it:** the ten-site guard sweep is real, each row carries a
verdict, and every prescribed rule is `== null ? -1 :` / `== null || === -1` — I found **no** `||` fold and no
bare truthiness test in any new-code row (sites 2, 3, 4, 5). The AC-2 matrix carries an explicit `clientId = 0`
row. The `System-Client` fixture requirement reaches four surfaces (AC-2, §7.2's `clientIdZeroIsARealShipper`,
§7.3's `filterValueMatrix`, §7.4). The sweep's *completeness* has three small gaps — see §5 below — none of
which changes a verdict.

### C-2 — export predicate / exported SDR route — **RESOLVED**, and the substitution is better than my prescription

I asked for the `IS NULL` arm plus, preferably, withdrawing the route. The plan declined the withdrawal and
split the method instead. **Judged on its merits, the split is strictly better than what I asked for**, and I
say so explicitly because the revision log flags it as a declined prescription:

- My fix (`IS NULL` arm) would have made the existing route return rows again — but the architect's A-1 shows
  the resulting three-arm disjunction is non-indexable under a generic plan, on the path that pulls thousands
  of rows. My fix trades a correctness bug for a performance bug.
- My preferred fix (withdrawal) is a contract change on an externally-visible route, which belongs with Q5.
- The split leaves `findByOffsetAndLimit` **byte-identical** — signature, predicate and `@RestResource` — so
  the route's behaviour is provably unchanged and §6's "No" is honest rather than asserted. Verified: the
  method on `origin/develop` carries `@RestResource(path = "findByOffsetAndLimit", …)` with no
  `exported = false`, and the plan instructs no edit to it. The new `findByClientOffsetAndLimit` carries
  `@RestResource(exported = false)`, so nothing is added to the HTTP surface — consistent with
  `SdrUncalledSurfaceNotExportedContextTest`'s stated default, which I confirmed is referenced across the
  `repo/jpa` package.
- §6 gains three rows, not one: the missing route, the new unexported method, and the new filtered read route.

I withdraw the withdrawal preference. The split is the right call and Q5 is the right home for the rest.

One correction inside it, which the architect found and I independently confirm: the revision log's framing
*"an in-place signature change would have been a compile break, not a test failure"* is true of the
**repository** method and false of the **service** method. `ReportService.exportStockUnitRecord` does gain
`Long clientId` (§0 row 9, §4, P3), and the four `ReportServiceUnitTest` act lines — plus
`ReportControllerUnitTest`'s `verify(reportService).exportStockUnitRecord(any(HttpServletResponse.class),
eq(0), eq(100), eq("STOCK789"))` — are four-argument call sites that will not compile. I confirmed the four
`when(stockrecordRepository.findByOffsetAndLimit(any(), anyInt(), anyInt()))` stubs are at lines
**439/470/484/515** exactly as §0 row 21 states, and that those *stubs* survive; it is the surrounding act
lines that break. §0 row 21's verdict should name the stubs rather than the file. Non-blocking (it announces
itself in seconds), but the claim as written is over-reaching.

### C-3 — the `getClients` sweep — **RESOLVED**, and the count reproduces exactly

The plan reports **26 dispatch sites in 15 files**. I re-derived it with my own instrument
(`git grep -c "getClients" origin/develop -- .`, summed per file):

- Repo-wide: **31 hits in 17 files**.
- Minus `store/admin/client.js` (4 hits — the action's own definition, not a dispatcher) and
  `test/store/adminReadLoggingSweep.spec.js` (1 hit — a test).
- **= 26 hits in 15 files.** No disagreement between our two instruments.

The 15 files in §0 row 45 are exactly the 15 mine returns: 7 reports + `handlingUnits/{containerTable,
stockUnitsTable}` + 3 cycleCount + 2 replenishment + `receiving/open/create/createPurchaseOrder`.

The downstream consequences are all carried: rows 37–40 make `handlingUnits/*` the PRIMARY REFERENCE with
their in-source comments quoted; `inventoryReport.vue` is demoted at row 41 with "copy only the Vuex-backed
computed idiom"; §10.1 Q1's accepted cost is corrected to *"there is no divergence to accept"* and the
`StockUnitController#getDetailView` `toFilterId(clientId)` precedent is cited on the API side (§0 row 19);
§9.4's price is corrected with it; and §3.9 reopens `<v-select>` vs `<v-autocomplete>` against measured
shipper counts and flags it for Nam rather than deciding it. That is the full remedy I asked for.

---

## 2. Are the ACs encodable? — three yes, one **contradicts the design**

This is the criterion that matters most, so I state the assertion a test would write for each.

**AC-1 — encodable, but its wire contract is contradicted by §3.9. BLOCKING.**

The assertions are now all present: `expect(wrapper.find('#shipper').exists()).toBe(true)`;
`expect(wrapper.vm.shippers[0]).toEqual({ id: null, label: 'All Shippers' })`;
`expect(dispatchSpy).toHaveBeenCalledWith('admin/client/getClients')`; and the wire contract
`expect(url).toContain('&clientId=60500')`.

But AC-1 states, as the assertion:

> *"with 'All Shippers' selected the request carries `&clientId=-1`. Never `null`, never `''`, **never the
> parameter's absence**."*

and §3.9's store code — the implementation the same plan specifies — is:

```js
const path = (clientId === -1)
  ? '/stockrecordView/search/findByKeyword' + urlPart
  : '/stockrecordView/search/findByKeywordAndClient' + urlPart + '&clientId=' + clientId
```

On the unfiltered branch the parameter is **absent**. A test written from AC-1 reds against the plan's own
design, for the value the default state uses. This is the one place where making the ACs encodable
introduced a contract the design does not implement.

The architect saw the neighbouring wording problem (§3.9's rule 2 says *"append from state, for both
branches"* while the code appends on one) and classified it as a nit because the *code* is right. I disagree
on severity for one reason they did not consider: **AC-1 is what the TDD gate writes tests from**, and it
states the opposite of the code. Either is a one-line fix and both are acceptable:

- append `&clientId=-1` on both branches (SDR ignores an undeclared query parameter on `findByKeyword`, so it
  is inert, and it makes the rule statement and the code agree); **or**
- restate AC-1 as *"with 'All Shippers' selected the request targets `findByKeyword` and carries no
  `clientId`; with shipper N selected it targets `findByKeywordAndClient` and carries `&clientId=N`"* — which
  is the stronger assertion anyway, because it also grades the route choice the split introduced.

**AC-2 — encodable.** `ReportControllerUnitTest.filterValueMatrix`, parameterised over the six rows: key
absent / JSON `null` / `-1` / `""` / `"abc"` → `-1L`; `60500` → `60500L`; `0` → `0L`. I traced each through
`toFilterId(String.valueOf(reqMap.get("filter")))` and all six resolve as the matrix says. The matrix is
correct; **only the UI half that feeds it is broken** (C-1 above).

**AC-3 — encodable.** `expect(wrapper.vm.headers.find(h => h.value === 'itemName').sortable).toBe(false)`;
`assertThat(details).containsEntry("itemName", …)` and, for the unresolved case,
`assertThat(details).doesNotContainKey("itemName")` — the absent-vs-null distinction is stated in the AC
itself, so the mutation row (`ifPresent` → `put(…, null)`) is executable from the AC. The second clause
("the row still appears in the table") is what promotes `LEFT`-not-`INNER` from an implementation detail to
an acceptance criterion, exactly as asked.

**AC-4 — encodable, and it is now the strongest of the four.** The named regression gives one line:
`assertThat(page.getTotalElements()).isEqualTo(<filtered count>)` and not the unfiltered count; the four
combinations (a)–(d) are enumerated so two implementers write the same test, and (d)'s "page 2's ids are
disjoint from page 1's" is assertable by id — which matters here, because these repository tests commit.

---

## 3. The four repaired mutations — three good, and one **new** row that cannot kill

| Row | Repair | Verdict |
|---|---|---|
| **M-1** `ClassCastException` shape | restated as a thrown CCE out of the handler / nested `ServletException` | **Correct.** Independently verified in `ReportController.java`: the seven `String filter = (String) reqMap.get("filter");` reads are at lines **66/93/121/148/175/202/229** and each method's `try {` at **72/100/127/154/181/208/235** — every read is above its `try`. The corrected sibling note is also right: `catch (Exception e)` appears at **270** (`exportStockUnitRecord`) and **304** (`exportContainerRecord`), and nowhere else among the export methods |
| **M-3** "shipper is a computed" | assertion changed to `expect('shipper' in wrapper.vm.$data).toBe(false)` | **Correct, and it now kills.** The mutant introduces a `data()` key named `shipper`; the assertion names `shipper`; the message is attributable. The reason is recorded in P6 so it is not "simplified" back |
| **M-4** `exposeIdsFor` had no executing test | new `StockrecordViewHalContextTest` in the `*ContextTest` surefire lane | **Right lane, wrong fixture** — see below. The lane claim itself is correct: `SdrReadGateEnforcementContextTest extends BaseControllerIntegrationTest`, is named `*ContextTest` so surefire runs it, and its javadoc records it "runs in the `@AutoConfigureMockMvc` lane proven bootable by `WebContextLaneContextTest`" |
| **M-5** over-determined column mutant | **dropped**, and `everyMappedColumnResolves` re-justified on the "reports the FIRST mismatch and stops" gap | **Correct, and the right call.** Dropping an unattributable row is better than patching it. P2's checklist repeats the warning where an implementer will actually read it |

**But the row added in round 2 to protect the A-1/C-2 fix cannot kill as specified.** §7.8:

> *"the filter predicate stays indexable | add `OR :clientId = -1` to `findByKeywordAndClient` |
> `StockrecordViewRepositoryFilterIT.filteredSearchKeepsAnIndexCondition`"*

and §7.2 describes that test as *"`EXPLAIN` of the `findByKeywordAndClient` **shape**"*. The repo's only
precedent for EXPLAIN-in-a-test is `src/test/java/net/aim_ai/wms/integration/outbox/OutboxClaimExplainIT.java`,
which holds its statement in a **hand-copied constant**:

```java
private static final String GATE_PROBE_SQL = """
    EXPLAIN
    …
```

An implementer following that precedent writes the SQL into the test. The mutant edits the `@Query`
annotation. **The test's own string is unchanged, so it stays green and the mutant survives** — and this is
the single test protecting the fix the whole round-2 revision was built around. I also confirmed there is no
`StatementInspector` and no `hibernate.SQL` capture anywhere in `src/test`, so nothing in the repo currently
binds a test's EXPLAIN to a repository's rendered SQL. §10.3 item 3 already concedes *"no Hibernate-generated
SQL was captured"*; this is the same gap arriving inside the protection.

**Cheapest repair — add a second, structural assertion the mutant provably flips**, alongside the EXPLAIN
case rather than instead of it:

```java
String jpql = StockrecordViewRepository.class
    .getMethod("findByKeywordAndClient", String.class, Long.class, Pageable.class)
    .getAnnotation(Query.class).value();
assertThat(jpql).contains("p.clientId = :clientId");
assertThat(jpql).doesNotContain(" OR ");   // the A-1/C-2 invariant, stated where it can be graded
```

That kills the stated mutant, names the thing broken, runs in surefire, and costs three lines. Keep
`filteredSearchKeepsAnIndexCondition` for what it genuinely grades — that a plain equality *is* index-backed
under a generic plan — and say in §7.2 that the two together are what protect the split.

---

## 4. The six drifted claims — all corrected; I re-measured the urgent one

| # | Round-1 finding | Round-2 text | My re-measurement |
|---|---|---|---|
| 1 | "87 SKU strings" | **71 strings / 87 excess rows**, in the prose *and* in the CRC-locked `V2.2.33` header | `SELECT count(*) FROM (SELECT item_nr FROM itemdata GROUP BY item_nr HAVING count(*)>1) d` → **71**; `sum(c-1)` → **87**; `itemdata` 8,808 rows / 8,721 distinct `item_nr`. ✓ **The header now reads correctly**, which was the one item that becomes uneditable on first apply |
| 2 | "22-key map that includes clientNumber/clientName" | 22 unconditional + 2 conditional = 24 / 22 | ✓ corrected in §1 and §6; §6 adds *"do not turn this into a size assertion"* |
| 3 | "`StockView` annotates all eleven columns" | 12 fields, 11 with `@Column(name = …)`, `transfer` identity-resolving | ✓ corrected in §7.5 row 4 |
| 4 | `V2.2.11` "permanently burned" | corrected: the file exists on `origin/develop`; the README is stale | ✓ corrected in prereq 1, and correcting the README is §10.4 item 2 |
| 5 | "six sibling reports … 7 files" | **seven**, with the inherited-from-a-stale-comment provenance recorded | ✓ corrected in §1 |
| 6 | "40 remote refs" | **310** | ✓ `git for-each-ref refs/remotes \| wc -l` → **310**. Conclusion unaffected, as both of us found |

Also re-verified free: `V2.2.32__adviceposition_notified_damaged_amount.sql` is the max on `origin/develop`,
and `git log --all --diff-filter=A --name-only -- '*db/migration/V2.2.3*'` returns only V2.2.30/31/32 across
**all** refs, so `V2.2.33` is still unclaimed today. The obligation to re-run the collision script
immediately before merge is correctly carried in prereq 1, P1 and Q7.

---

## 5. New defects in the revision

The plan grew 599 lines net. Per the repo's standing pattern I re-audited the **completeness** claims in the
new material rather than its measurements; the measurements again reproduced without exception.

### N-1 (HIGH) — the empty-page `_embedded` read. **I independently confirm the architect's A-R2-1**

I reached this from a different direction (auditing §3.9's new store snippet for the `0`-row case) and
arrived at the same place, so I record it as confirmed rather than echoed:

- `store/admin/group.js` line 41 carries SBDEV-3012's finding verbatim: *"`_embedded` is ABSENT, not empty,
  when Spring Data REST returns an empty collection"*, and its helper acts on it at line 51:
  `const embedded = payload && payload._embedded`.
- `store/reports/stockUnit.js` line **53** does the unguarded read today
  (`results._embedded.stockrecord`) inside a `try` whose only handler, line **56**, is
  `this.$toast.error('Error: Request failed due to a network or server issue. Please retry.')`.
- §3.9's replacement snippet reproduces the unguarded shape with the new rel.

So a zero-row page throws a `TypeError`, `setReportItems` never commits, and the grid keeps the **previous**
shipper's rows and `totalItems` under a network-error toast. This ticket is what makes an empty page routine:
`System-Client` is in the dropdown on 5 of 5 reachable databases and owns **0 `stockrecord` rows on hydra
prd** — a guaranteed empty page on the one environment that matters, while the §7.7 manual row is run on dev,
where that same client owns 16 rows. The architect's required fix (absence-tolerant accessor + one IT case +
one Jest case + one manual row) is right and I have nothing to add to it.

### N-2 (MEDIUM) — `StockrecordViewHalContextTest`'s fixture is listed as "none", and the lane is H2 with no `db/migration`

§7.8 gives the `exposeIdsFor` mutant the fixture "none". The lane it now runs in cannot supply a row on its
own. Derived by reading the chain: `BaseControllerIntegrationTest` → `BaseIntegrationTest`, whose javadoc
says *"Base class for integration tests using **H2 in-memory database**"*, `@ActiveProfiles("integration")`;
and `src/test/resources/application-integration.properties` carries
`spring.datasource.url=jdbc:h2:mem:wms_integration…`, `spring.jpa.hibernate.ddl-auto=create-drop`,
`spring.flyway.enabled=false` and `app.flyway.migrate-on-startup=false`. So in that lane `stockrecord_view`
is a Hibernate-created **empty table**, not the migrated view, and `$._embedded.stockrecordView[0].id`
resolves against nothing. The sibling `SdrOmittedPrimitiveParamSearchContextTest`'s own javadoc says as much
about that lane: *"200 with an empty `_embedded`, which is the answer that actually proves the route
resolves."*

Self-revealing at implementation time (the test reds against correct code), so **non-blocking** — but it will
cost the implementer a cycle, and the obvious "fix" is to weaken the assertion to `status().isOk()`, which
kills the mutant's executability all over again. State the fixture: seed one `StockrecordView`-shaped row
through the tenant `EntityManager` (or `jdbcTemplate`) in a `@BeforeEach`, then assert the `id` path. Note
`BaseIntegrationTest` is `@Transactional("tenantTransactionManager")`, so a flush is needed for the MockMvc
request to see it.

### N-3 (LOW-MEDIUM) — `constraintIsAsserted` is feasible but the plan does not say how, and its assertion form is the one the repo warns about

The new third statement is a good addition and I support it. Two notes on the test that grades it:

- **Feasibility is fine** — I checked, because "drop the constraint before the migrate" is awkward when
  `V2.2.00` is what creates it. The repo has the mechanism: `Flyway.configure()` appears in
  `AppPostgresDBSetupExtension` and in eight ITs (`PickingStartedGuardScalarSubqueryIntegrationTest`,
  `StockHistoryClientIsolationIntegrationTest`, the four `TransactionDetail*` ITs, `OutboxItFlyway`, …), so a
  test can migrate to `target(V2.2.32)`, drop the constraint, then migrate the rest and assert the failure.
  Name that recipe in §7.2 so the implementer does not conclude the case is unwritable.
- **Assertion form.** §7.2 grades it as *"fail with the message the `DO $$` block raises"*. The standing
  finding here is that Flyway wraps the cause and its message quotes the **script filename**, so a
  `hasMessageContaining(<text>)` passes for essentially any failure of that script. Assert the SQLSTATE
  (`RAISE EXCEPTION` without a condition gives **P0001**) and keep the message check as a secondary.

### N-4 (LOW) — the §3.6 guard sweep's completeness claim is over-stated in the safe direction

The sweep is titled *"Sweep of every such site"*. Running the deriving method myself over
`store/**/*.js` + `components/**/*.vue` at `a27703eb`, three sites are absent from the ten-row table:

| site | guard | why it does not change a verdict |
|---|---|---|
| `store/internalOps/replenishments.js:141` and `:343` | `if (data.clientId != null) {` | **already correct** — the rule, on a numeric id |
| `store/reports/outboundParcel.js:139` | `const clientNumber = context.state.shipperFilter \|\| null` | a truthiness fold, but on `clNr` (a non-empty String), so unreachable — same class as the table's site 7 |
| `store/internalOps/cycleCount.js:146` and `:278` | `'&clientId=' + (context.state.…ShipperFilter \|\| '')` | a **second mechanism** in a file the table already covers at site 8 via `if (data.clientId)`. `0 \|\| ''` → `''` → `toFilterId("")` → `-1` — the same defect by a different expression |

Nothing here flips a decision, and the omitted sites are all either correct or already covered at file level.
But the sweep's own stated blind spot ("a guard written against a differently-named variable") is precisely
what let `outboundParcel.js`'s `shipperFilter` through, and §10.4 item 1 should say cycleCount carries the
defect at **two expressions in two shapes**, not one, so whoever takes it does not fix half.

### N-5 — concurrence, briefly, with three architect findings I checked rather than assumed

- **A-R2-2** (the export's post-index plan is unmeasured; acceptance should be "the `Sort` node is gone"):
  agreed. §5.2 P1's re-measurement bullet says "filtered first page" only, and the export is a different
  shape on the same new index.
- **A-R2-4** (the 5-column `CONCAT` is now duplicated verbatim across the split with nothing pinning the two
  equal): agreed, and it is a hazard the fix created. Extracting the clause to one `String` constant is the
  cheaper of their two options and removes the failure mode rather than detecting it.
- **A-R2-3** (§7.5 row 5 still says `SDR_WRITE_WITHDRAWN` "gains it for parity" after F4 re-labelled it
  required elsewhere): agreed — and it is the repo's documented sibling-copy pattern, where a claim fixed in
  three of four homes reads as fixed.

### What I checked for and did **not** find

I re-audited the ~200 lines of cut duplication for load-bearing content and found none removed. Specifically:
§3.1's surviving prose keeps the three items that belong to the plan rather than the migration (the
elimination EXPLAIN, the `LEFT`-licensing zero **with its poisoned-predicate control**, and the schema-vs-
view-text caveat) and the five arguments now live once, in the header that ships. §7.1's trimmed lane facts
keep exactly the five that decide where *this* ticket's tests go, and I verified the two load-bearing ones
independently (`*IT.java` is in the failsafe `<includes>`; `*ContextTest` runs in surefire because surefire
excludes only `*IntegrationTest`/`*E2ETest`). §0's compressed "out of scope" paragraph preserves every
citation the six deleted rows carried. §9.1/9.2/9.4 now point at the RALPLAN-DR options block, which still
carries the evidence. **No measurement content was lost** — the revision log's claim on that point is accurate.

I also spot-checked the new §3.8 derivation (eleven → fourteen): the eleven constants, the mapping of every
`getClients` dispatcher to its `appMenuList.js` `fn`, and the remainder set
{`WEB_UI_VIEW_STOCK_UNIT`, `WEB_UI_VIEW_CONTAINER`, `WEB_UI_VIEW_STOCK_UNIT_RECORD`} all hold, and the blind
spot (menu-visibility `fn` need not be the screen's gate in general) is stated. M-2 is properly resolved:
the invariant is now applied in the document that asserts it.

---

## 6. What still blocks

1. **C-1 is unfixed (HIGH).** `:filter="shipper == null ? -1 : shipper"` does not survive
   `exportReport.vue`'s guard for `shipper = 0`; the mutant and the fix are behaviourally identical on that
   value; AC-2's `0` row is unreachable by the specified design. Take fix A (`String(shipper)`) or fix B
   (widen the shared guard to `!= null`, whose blast radius measures as nil), re-point the §7.8 mutation row,
   and state in §7.4 that the Jest assertion is on the emitted POST body. **The round-1 prescription was
   mine and it was wrong.**
2. **AC-1's wire contract contradicts §3.9 (blocking on encodability).** "never the parameter's absence" vs a
   store that omits `&clientId=` on the unfiltered branch. One line, either direction.
3. **§7.8's new index-condition mutant cannot kill (MEDIUM, but it guards the round-2 centrepiece).** Add the
   three-line structural assertion on the `@Query` string; keep the EXPLAIN case for what it does grade.
4. **A-R2-1 (HIGH), independently confirmed.** Absence-tolerant `_embedded` read in P6, plus a zero-row case
   at the IT, Jest and manual layers. Hydra prd reproduces it deterministically via `System-Client`; dev
   cannot.

## 7. Not blocking — absorbable by the implementer or a follow-up

N-2 (name the HAL test's fixture and note the H2 lane) · N-3 (name the `Flyway.configure().target(...)`
recipe; assert SQLSTATE P0001) · N-4 (three sweep sites; say cycleCount carries two expressions) · A-R2-2
(extend P1's re-measurement to the export shape) · A-R2-4 (one `CONCAT` constant) · A-R2-3 (one word in §7.5
row 5) · A-R2-5 and the revision log's compile-break sentence (§0 row 21's verdict names the file where it
means the stubs) · §3.9's "both branches" wording, which item 2 above resolves anyway.

**Explicitly not blocking, and I would not spend another round on them:** the plan's length (the added
material — the guard sweep, the plan-mode table, the per-environment sizes, the AC rewrites — earns its
space, and §10.3 remains the best section in the document); the `<v-select>`/`<v-autocomplete>` question,
which is correctly flagged for Nam rather than decided; Q5 and Q6, both correctly left open with the reason
each cannot be closed from this session.

## 8. Method and blind spots for the completeness words above

- **"All three round-1 blockers"** — graded one at a time against the revised text, then each fix re-derived
  against `origin/develop` or the DB. Blind spot: I verified the fixes as *specified*; code written during
  implementation is outside any review's reach — which is exactly how C-1's prescription survived round 1.
- **"26 sites in 15 files"** — `git grep -c` summed per file, minus the action definition and one test. `git
  grep`, not `grep`, because `wms2-web-ui` `.gitignore`s `reports/` and the local `grep` is ugrep. Blind
  spot: string-built or reflective dispatches; a sweep cannot see them.
- **"No `||` fold in any new-code row"** — read all ten rows of §3.6's table plus the code blocks in §3.9,
  §3.6 and §5.2 P6. Positive control: the same read finds the three truthiness guards the table itself flags
  (sites 6, 8, 9), so the instrument does report them when present.
- **"The mutant and the fix are identical for `shipper = 0`"** — not reasoned, **executed**: `node -e` over
  `exportReport.vue`'s guard as quoted from `origin/develop` and the plan's fold as quoted from §3.6, across
  `{null, 0, 60500}`. Blind spot: I modelled the guard expression, not the mounted component; if
  `exportReport.vue` coerced its prop before line 136 the result would differ — it does not (`props:` is a
  bare array at line 92, so there is no type coercion or default).
- **"All six drifted claims corrected"** — each re-measured independently: #1 and the `client`/`itemdata`
  figures by SQL on `dev_wh01_om1`; #6 by `git for-each-ref`; #2/#3/#5 by reading the corrected sections;
  #4 by `git show` of the migration path. Blind spot: one tenant for every DB figure, as §10.3 item 1 and
  item 8 already state.
- **"No measurement content was lost in the ~200 cut lines"** — compared §3.1, §7.1, §0 and §9 between the
  round-1 snapshot I reviewed and the current file, item by item against my round-1 §5 list of what I said
  should and should not be cut. Blind spot: I compared the categories I had named, not a line-level diff, so
  a cut outside those four sections would not have been caught.
- **"The `*ContextTest` lane is H2"** — read `BaseControllerIntegrationTest` → `BaseIntegrationTest` →
  `application-integration.properties` in full. Blind spot: `TestDatabaseConfig` was not read, so a
  test-scoped datasource override there could change the conclusion.
