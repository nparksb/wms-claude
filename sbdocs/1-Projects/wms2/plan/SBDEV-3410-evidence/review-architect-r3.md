# SBDEV-3410 — architect review, ROUND 3 (verification pass)

**Lane:** architect · **Mode:** read-only, verification-scoped · **Date:** 2026-09-18
**Plan:** `sbdocs/1-Projects/wms2/plan/SBDEV-3410-stock-unit-record-shipper-filter-and-product-name.md` (2,044 lines)
**Code read at:** `v2/wms2-api` `origin/develop` = `7ebb9c83` · `v2/wms2-web-ui` `origin/develop` = `a27703eb`

---

## VERDICT: **SOUND-WITH-CHANGES**

One blocker, and it is a **fact the plan asserts that the framework source says is inverted**. Everything
else I was asked to verify landed, and most of it landed better than the review that asked for it.

Ten of my round-2 items plus B-1, B-3, B-4 and the call-site count were re-checked **by execution** (a real
`javac`/`java` run, a `node` run, four DB queries, `git grep` at `origin/develop`, and a read of the resolved
dependency sources). All of them hold. Two corrections the planner made against its reviewers — the B-4
assertion form and the "five call sites" count — are **correct, and both reviewers were wrong**; I reproduced
each independently.

The blocker is not in the design. It is that the round-3 `_embedded` work rests on a wire fact borrowed from
one in-repo comment, and reading spring-data-rest 4.5.7 / spring-data-commons 3.5.7 / spring-hateoas 2.5.1 —
the exact versions `mvn dependency:list` resolves for this module — says the opposite. The **production**
accessor survives either way; **three of its four new test surfaces do not**.

---

## 1. Round-2 items — resolution check, by execution

### A-R2-2 (the filtered export's plan is unmeasured) — **LANDED, in full**

§3.2 now carries the measured export plan verbatim, including the `Sort` node and its estimate:

> ```
> Limit
>   ->  Gather Merge  (Workers Planned: 1)
>         ->  Sort  (Sort Key: created DESC)
>               ->  Parallel Index Scan using index_stockrecord_client_id on stockrecord p
>                     Index Cond: (client_id = $2)
> ```
> "`Index Cond` survives, so the split fixes **both** paths. But note the `Sort`: its estimate is `rows=559`
> against an actual of up to **873,021** … **The open question on the export is index *selection*, not index
> *reachability*.**"

P1's re-measurement bullet covers both shapes with the acceptance I asked for, and goes further than I asked:

> "**(b) The export path** … acceptance is **the `Sort` node is gone**, not merely that an `Index Cond` is
> present. … If the planner keeps the narrow index plus the sort, the composite index is not earning its
> 276 MB on the export path and that is a finding for the ticket, not something to leave unrecorded."

That last clause is the part that makes the bullet a measurement rather than a ritual. Accepted.

### A-R2-4 (the keyword clause is duplicated) — **LANDED; the extension is the best edit in round 3**

Precedent verified at `origin/develop`:
`src/main/java/net/aim_ai/wms/repo/jpa/FixLocationAssignmentRepository.java:166` declares
`String REFILL_ELIGIBILITY_FROM_WHERE =`, concatenated into two `@Query` values at `:196` and `:199`. Exactly
the idiom §3.4 claims.

**Grading the extension to §3.6's native pair.** I asked for one constant; the planner added a second,
`NATIVE_KEYWORD_CLAUSE`, over `StockrecordRepository.findByOffsetAndLimit` / the new
`findByClientOffsetAndLimit`, on the ground that the hazard is identical and neither review named it. That is
**invariant-over-instance applied correctly, and it is the stronger move.** The native pair is in fact the
*more* exposed of the two, because `findByOffsetAndLimit` is a live exported SDR route (`@RestResource(path =
"findByOffsetAndLimit", …)` at `StockrecordRepository.java:47`, no `exported = false`) while the JPQL pair is
both new. A drift there changes shipped behaviour, not just new behaviour. §3.10's edit-point row was updated
to name both constants, so the change that would trip it is routed at the one place a future implementer
looks. Full marks.

**One thing the extension should say and does not.** The two constants are *not* the same text. The existing
native clause quotes the column — `LOWER(p.\"operator\")` at `StockrecordRepository.java:49` — where §3.4's
JPQL clause writes `LOWER(p.operator)`. §3.4's constant is spelled out in full in the plan; §3.6's is
described only as "the existing text byte-for-byte". That asymmetry invites an implementer to reach for the
one that is written down. I checked whether the wrong choice would announce itself: it would **not** —
`SELECT catcode FROM pg_get_keywords() WHERE word = 'operator'` returns `U` (unreserved) on `dev_wh01_om1`,
and both `LOWER(p.operator)` and `LOWER(p."operator")` execute (`1` row each, control: the column is named
`operator` lower-case in `information_schema.columns`). So the mistake compiles, runs, and returns the same
rows — it just silently breaks the "byte-identical" property that §6's "No" and
`unfilteredExportRouteIsUnchanged` rest on. **Fix: quote `NATIVE_KEYWORD_CLAUSE`'s text in §3.6 the way §3.4
quotes `KEYWORD_CLAUSE`'s.** Two lines. (LOW — implementer-absorbable, but free.)

### A-R2-3 (`SDR_WRITE_WITHDRAWN` "for parity", F4's fourth copy) — **LANDED**

`grep -n 'parity'` over the plan returns five hits: §0.1 row 6, §3.5, §4, §7.5 row 5 and the revision-log row
— all four content sites now read "**REQUIRED, not parity**" with the reason
(`ReadOnlyPagingAndSortingRepository` suppresses only `save`/`saveAll`). The fifth hit is line 388, a SQL
comment about *column* shape parity, unrelated. Sweep complete for the literal, and the planner says so.

### A-R2-5 (§0.1 row 21's "no edit needed" is false) — **LANDED, and the correction is the planner's, not mine**

See §4 below. Row 21 is now the most precise row in §0.1.

### N-2 (the HAL test's fixture is "none" in an H2 lane) — **LANDED; every lane fact verified**

Verified at `origin/develop`:

- `src/test/resources/application-integration.properties`: `spring.datasource.url=jdbc:h2:mem:wms_integration…`,
  `spring.jpa.hibernate.ddl-auto=create-drop`, `spring.flyway.enabled=false`, `app.flyway.migrate-on-startup=false`.
- `src/test/java/net/aim_ai/wms/common/base/BaseIntegrationTest.java`: `@ActiveProfiles("integration")` and
  `@Transactional("tenantTransactionManager")`; `BaseControllerIntegrationTest` `extends BaseIntegrationTest`
  with `@AutoConfigureMockMvc`.

So §7.3's statement — empty Hibernate table, seed in `@BeforeEach` and **flush** — is exactly right, and the
"do not repair a red by weakening to `status().isOk()`" warning is the right guard.

### N-3 (`constraintIsAsserted` feasibility + assertion form) — **LANDED on substance; the citation points at the wrong precedent**

The SQLSTATE requirement is right and important. But §7.2's recipe sentence is:

> "`Flyway.configure()` is already used directly in `AppPostgresDBSetupExtension` and eight ITs
> (`OutboxItFlyway`, the four `TransactionDetail*` ITs, `StockHistoryClientIsolationIntegrationTest`,
> `PickingStartedGuardScalarSubqueryIntegrationTest`), so migrate to `.target("2.2.32")` …"

Three problems, in increasing order of importance:

1. The parenthetical names **seven**, not eight. (`git grep -l 'Flyway.configure()' origin/develop -- src/test`
   is in fact **17 files**, so the count is understated, not overstated — the conclusion is unaffected.)
2. **None of the named files demonstrates `.target(`.** `git grep -n '\.target(' origin/develop -- src/test`
   returns exactly **two** hits, and they are in neither list:
   `src/test/java/net/aim_ai/wms/integration/schema/BillofladingTransferIdNotNullIT.java:121` and
   `src/test/java/net/aim_ai/wms/integration/schema/CancellationLogPickingorderPositionIdIT.java:103`.
   The sentence conflates "uses `Flyway.configure()`" with "uses `target()`".
3. **`OutboxItFlyway` is the one precedent the real precedent warns against copying.**
   `BillofladingTransferIdNotNullIT`'s javadoc says so in as many words:

   > "An earlier revision of this harness copied `executeInTransaction(false)` + `setTransactionalLock(false)`
   > from `OutboxItFlyway` without needing either, and that pinned a materially worse aftermath than
   > production's: a `success=f` history row, and every later `V2.2.x` then blocked behind `Validate failed`
   > until an operator ran `flyway repair`."

`BillofladingTransferIdNotNullIT` is also in **the same package** §7.2 puts `StockrecordViewSchemaIT` in
(`net/aim_ai/wms/integration/schema/`), carries the `migrateTo(url, target)` helper, **and** carries a
SQLSTATE cause-chain walker — which is precisely what N-3's "assert SQLSTATE P0001" needs and which none of
the named eight provides.

**Fix: replace the citation with `BillofladingTransferIdNotNullIT`** (`migrateTo` + the SQLSTATE walk),
and drop the "eight ITs" count. One sentence. **LOW-MEDIUM** — it is implementer-absorbable, but the current
citation actively points at a known trap that costs a `flyway repair`.

### N-4 (the guard sweep's enumeration is incomplete) — **LANDED**

Sites 11–13 added, each with a verdict and a "changes no verdict" statement. Site 13's framing is the one
that earns its place: `'&clientId=' + (…ShipperFilter || '')` is a **second expression shape** in the file
site 8 already covers, and §10.4 item 1 now says Cycle Count must fix both "or it fixes half". That is the
right conclusion.

---

## 2. The B-1 fix — verified by execution

I re-ran the real guard, quoted from `origin/develop`
(`components/reports/popups/exportReport.vue:136`: `filter: this.filter && this.filter != 'All Shippers' ? this.filter : null,`),
over `{null, undefined, 0, 60500}` for all three candidate bindings, in `node`:

| `shipper` | `:filter="shipper"` | `:filter="shipper == null ? -1 : shipper"` | `:filter="String(shipper == null ? -1 : shipper)"` |
|---|---|---|---|
| `null` | body `null` | body `-1` | body `"-1"` |
| `undefined` | body `null` | body `-1` | body `"-1"` |
| **`0`** | body **`null`** | body **`null`** | body **`"0"`** |
| `60500` | body `60500` | body `60500` | body `"60500"` |

**Confirmed, including the part that matters:** the round-2 fold and the naive binding are byte-identical on
`0` (`same=true`) and differ only on `null`/`undefined`. The `String(...)` form differs from the round-2 fold
on **every** input. §3.6's table reproduces exactly.

**The re-pointed §7.8 mutant genuinely kills.** Mutant = *drop the `String(...)`* → on `shipper = 0` the
emitted body is `null` where the fixed code emits `"0"`. That is a strict, attributable difference, and it is
the only value that discriminates — so the plan's ⚠ that `→ :filter="shipper"` **cannot** kill is correct and
correctly stated in both §7.8 and §5.2 P6.

**§7.4 does assert on the emitted POST body**, in the form that makes the kill real:

> "⚠ **Assert on the request body `exportReport.vue` builds, not on `wrapper.vm.filter` or on the prop.** The
> whole defect lives *downstream of the prop*, inside the shared component's `this.filter && …` guard, so a
> prop-level assertion certifies the bug."

**Corroboration the plan does not claim and could:** the `String(...)` is *also* what makes the seven
existing `(String) reqMap.get("filter")` reads in `ReportController` safe from this caller — §3.6 notices
this ("It also removes the `ClassCastException` trap as a property of the value") and still, correctly, fixes
the API side too, because `/v3/dashboard/exportStockUnitRecord` is a second route into the same method. Belt
and braces, graded separately. Right call.

**Binding sweep is complete** — `grep -n 'String(shipper'` returns nine sites; the two remaining bare
occurrences (lines 1015, 1310) are deliberate negative references to the rejected fold.
**One tenth site was missed:** §7.7's manual row (line 1620) still reads *"the export body carries
`filter: 0`"* where every other site says `"0"`. An operator reading DevTools sees `"0"`. **LOW** — but it is
the same one-short enumeration this ticket has now produced four times, so it is worth fixing rather than
shrugging at.

---

## 3. The B-4 correction — the planner is right, and I reproduced it

I compiled and ran the actual construct on JDK 21 (`~/.sdkman/candidates/java/21.0.11-ms`): an interface
holding `String KEYWORD_CLAUSE = …`, two `@Query`-annotated methods concatenating it, then reflection over
the annotation, then the proposed assertion against the correct text and six mutants.

**Constant folding reaches reflection — confirmed, not assumed.** The reflected annotation value is the
whole folded string:

```
SELECT p FROM StockrecordView p WHERE (CONCAT(LOWER(p.activitycode), ' ', … LOWER(p.operator)) LIKE LOWER(concat('%', :keyword,'%')) or :keyword = '') AND p.clientId = :clientId
```

`contains the CONCAT text? true`. So §3.4's claim that a `String` constant is a compile-time constant
expression and the annotation carries the folded text is correct **for this exact construct**, not by
analogy.

**The substitute assertion: green once, red six times.**

| case | result |
|---|---|
| CORRECT | **GREEN** |
| M1 3-arm `OR` | RED — *"expected the JPQL to contain `AND p.clientId = :clientId`"* |
| M2 un-parenthesised tail | RED — *tail contained `" OR "`: `AND P.CLIENTID = :CLIENTID OR :CLIENTID = -1`* |
| M3 `COALESCE` sibling form | RED — assertion 1 |
| M4 conjunct deleted | RED — assertion 1 |
| M5 lower-case `or` tail | RED — *tail contained `" OR "`* (this is the one a naive scan misses) |
| M6 §7.8's named form `AND (p.clientId = :clientId OR :clientId = -1)` | RED — assertion 1 |

**The reviewer's literal prescription is wrong, exactly as the planner says — and I can now say which way.**
Against the *correct* text:

- `assertThat(jpql).doesNotContain(" OR ")` → **GREEN, vacuously.** It passes only because the keyword arm's
  `or` is lower-case. It would never have detected M5.
- `doesNotContain(" or ")` → **RED on correct code.**
- whole-string `toUpperCase(...).doesNotContain(" OR ")` → **RED on correct code.**

So "either reds on correct code or passes vacuously depending on its casing" is precise and now executed.
Adopting the reviewer's line verbatim would have shipped a vacuous assertion. The planner was right to
substitute, and right to record that it did.

**One imprecision, not a defect.** §7.8's row attributes the kill message *"expected the JPQL to contain `AND
p.clientId = :clientId`"*. That is assertion 1's message and it is correct for M1/M3/M4/M6; M2 and M5 red on
assertion 2 with a different (also attributable) message. Worth a half-sentence so the implementer does not
"fix" a correct red because the message did not match the plan.

---

## 4. The call-site count — the planner is right; **both** review lanes were wrong

Run at `origin/develop`:

```
$ git grep -c '\.exportStockUnitRecord(' origin/develop -- src/test
ReportControllerUnitTest.java:7
ReportServiceUnitTest.java:4
```

Enumerated: `ReportControllerUnitTest` **387, 395, 407, 415, 428, 436, 452** — four stubs
(`doNothing().when(...)` ×2 at 387/407, `doThrow(...).when(...)` ×2 at 428/452) and three
`verify(reportService).exportStockUnitRecord(...)` at 395/415/436. `ReportServiceUnitTest` **443, 474, 488,
522**, the last inside `assertThatThrownBy(() -> …)`. **11 in 2 files.** Every one passes four arguments and
every one stops compiling when the service gains `Long clientId`.

`ReportReadGateUnitTest` references the route *string* only — confirmed; it does not break.

§0.1 row 21, §3.6, §4 (7 + 4) and §5.2 P3 all now carry 11 and agree with each other. Dispute withdrawn on my
side; the count in my round-2 review was wrong.

---

## 5. ⚠ NEW BLOCKER — the `_embedded` fact is inverted on this stack

**A-R3-1 · `_embedded` is PRESENT with an empty array on a zero-row SDR page, not absent · HIGH · §3.9 item 4, §7.4, §7.7, §7.8**

The plan states, in four places, as fact:

> "⚠ **`_embedded` is ABSENT, not empty, when SDR returns an empty collection**"
> "a mocked SDR payload with **no `_embedded` key** … A payload with `_embedded: { stockrecordView: [] }`
> does not reproduce it: **SDR omits the key entirely**"

Its only source is one in-repo comment — `store/admin/group.js` at `origin/develop`, which asserts it flatly
with no measurement attached and about a **different** call (`/userRole/{id}/functions`, a property-reference
resource, plus two association collections). Nothing in this ticket measured it.

**I read the framework chain instead, against the versions this module actually resolves.**
`mvn -o dependency:list` in `v2/wms2-api`:

```
org.springframework.data:spring-data-commons:jar:3.5.7:compile
org.springframework.data:spring-data-rest-webmvc:jar:4.5.7:compile
org.springframework.hateoas:spring-hateoas:jar:2.5.1:compile
```

From the sources jars of those exact artifacts:

1. `spring-data-rest-webmvc` `RepresentationModelAssemblers.java`:
   ```java
   private CollectionModel<?> entitiesToResources(Page<Object> page, Class<?> domainType) {
       return page.isEmpty()
               ? pagedResourcesAssembler.toEmptyModel(page, domainType)
               : pagedResourcesAssembler.toModel(page, persistentEntityResourceAssembler);
   }
   ```
   (The `Iterable` overload and `RepositoryPropertyReferenceController:110` route through the same
   `emptyCollectionOf` fallback, so the association path is not an exception either.)

2. `spring-data-commons` `PagedResourcesAssembler.java:182`:
   ```java
   EmbeddedWrapper wrapper = wrappers.emptyCollectionOf(type);
   List<EmbeddedWrapper> embedded = Collections.singletonList(wrapper);
   return addPaginationLinks(PagedModel.of(embedded, metadata), page, link);
   ```
   Its own javadoc: *"Creates a `PagedModel` with an empt collection `EmbeddedWrapper` for the given domain type."*

3. `spring-hateoas` `EmbeddedWrappers.EmptyCollectionEmbeddedWrapper`: `getValue()` → `Collections.emptySet()`,
   `isCollectionValue()` → `true`, `getRelTargetType()` → the domain type. `EmbeddedWrappers.wrap` returns an
   `EmbeddedWrapper` unchanged (`if (source instanceof EmbeddedWrapper) { return (EmbeddedWrapper) source; }`).

4. `spring-hateoas` `HalEmbeddedBuilder.add` therefore falls through to
   `embeddeds.put(collectionRel, list)` with `list` empty, and `Jackson2HalModule.HalResourcesSerializer`
   serializes that map as `_embedded`.

**Net: a zero-row `Page` from `/api/stockrecordView/search/findByKeywordAndClient` renders**

```json
{"_embedded": {"stockrecordView": []}, "_links": {…}, "page": {"totalElements": 0, …}}
```

— the shape §7.4 explicitly says "does **not** reproduce it". `git grep 'HalConfiguration|LinkRelationProvider|RelProvider' origin/develop -- src/main`
returns **zero** (positive control: `exposeIdsFor` returns 2 hits in the same tree), so no local bean alters
this.

### What this does and does not break

**The production code is fine, and should still ship.** `rowsOf` returns `[]` for a missing `_embedded` *and*
returns the array for `_embedded.stockrecordView === []`. Both shapes yield `[]`. The accessor is
shape-robust and the `throw`-on-missing-rel arm remains the correct renamed-`collectionResourceRel` detector.
**No design change is required.**

**Three of the four new test surfaces are pinned to a shape the server does not send:**

- **§7.4's Jest zero-row fixture** is mandated as *"no `_embedded` key at all"* and the realistic fixture is
  explicitly forbidden. That is a green test that proves nothing about the live path — the exact failure mode
  the plan's own §7.8 preamble exists to prevent.
- **§7.8's mutation row** ("drop the `rowsOf` guard") kills only against that unreal fixture. Against the
  real shape, `results._embedded.stockrecordView` is `[]` and the unguarded code behaves correctly, so the
  mutant **survives**.
- **§7.7's hydra-PRD manual row** cannot fail: on the real shape the grid empties correctly with or without
  the fix. It grades nothing. (The environment move to hydra PRD is nonetheless **correct and verified** —
  `SELECT count(*) FROM stockrecord WHERE client_id = 0` returns **16** on `dev_wh01_om1` and **0** on
  `wh01_hydra_v2` PRD, where `client.id = 0` exists. Dev genuinely cannot reproduce a zero-row page for
  System-Client. Keep the move; it is the row's *pass condition* that is unsound.)
- **§7.2's `clientWithNoRowsReturnsAnEmptyPage` IT is unaffected** — it asserts at the repository level and
  never sees the wire.

The knock-on is that B-2's severity was over-stated: with `_embedded.stockrecordView = []` the unguarded
`results._embedded.stockrecord` in `store/reports/stockUnit.js:53` does **not** throw on a zero-row page, so
"the grid keeps the previous shipper's rows under a network toast" is not a live failure mode. `rowsOf` stays
worth adding as hardening and as the renamed-rel detector; it is not the HIGH both lanes graded it.

### Required change — cheap, and the instrument is already in the plan

**Measure the shape before writing those three surfaces, and pin it.** `StockrecordViewHalContextTest`
(§7.3) already runs a MockMvc request in the H2 `integration` lane against a table that is **empty by
construction** — it is the zero-row case for free. Add one assertion to it:

```java
mockMvc.perform(get("/v3/stockrecordView/search/findByKeyword?keyword=&page=0&size=1"))
       .andExpect(jsonPath("$._embedded.stockrecordView").isArray())   // or .doesNotExist() — whichever it is
       .andExpect(jsonPath("$.page.totalElements", is(0)));
```

Run it once **before** seeding the row that `idIsInTheHalBody` needs, record the observed shape in §3.9 item
4 with the run as its evidence, and write §7.4's fixture and §7.8's mutant against **that**. If it comes back
absent, my reading is wrong and nothing in the plan changes except that the claim finally has a measurement
behind it. If it comes back present-and-empty, §3.9 item 4's rationale, §7.4's fixture, §7.8's row and
§7.7's pass condition all need restating — and `store/admin/group.js`'s comment is a bug of its own worth a
line in §10.4.

I am confident in the source reading and I have not seen the live wire. That asymmetry is exactly why this is
"go measure it" and not "the plan is wrong".

---

## 6. Other new defects in round 3

**A-R3-2 · §3.9 item 2 still says "for both branches", contradicting AC-1, the snippet below it, and §7.4 · MEDIUM · §3.9**

The revision log's B-3 row claims: *"§3.9's 'for both branches' wording and §7.4 follow"*. §7.4 does follow.
**§3.9 does not** — line 1245 still reads:

> "2. **Append from state, for both branches.** `urlPart += '&clientId=' + (context.state.list.clientId ?? -1)`"

Fifteen lines below it, the actual snippet routes the other way, correctly:

```js
const path = (clientId === -1)
  ? '/stockrecordView/search/findByKeyword' + urlPart
  : '/stockrecordView/search/findByKeywordAndClient' + urlPart + '&clientId=' + clientId
```

and AC-1 grades it: *"with 'All Shippers' selected the request targets `/stockrecordView/search/findByKeyword`
and carries **no `clientId` at all**"*, with §7.4 asserting *"no `clientId` on the URL"*.

This is not cosmetic: an implementer who follows item 2's heading appends `&clientId=-1` on the unfiltered
branch and **reds the §7.4 assertion**. It is 3:1 outvoted inside its own subsection, so it will probably be
caught — but the revision log asserts it was fixed and it was not, which is the failure mode that lets a
round-4 reviewer take the row at its word. Item 2 should read *"append from state on the **filtered** branch"*
(the from-state-not-from-`data` rationale is still correct and still worth keeping).

**A-R3-3 · N-3's recipe cites a precedent that the real precedent warns against copying · LOW-MEDIUM.** See §1
above. Replace with `BillofladingTransferIdNotNullIT`.

**A-R3-4 · `NATIVE_KEYWORD_CLAUSE`'s text is not quoted, and it differs from `KEYWORD_CLAUSE`'s · LOW.** See §1
above. `LOWER(p.\"operator\")` vs `LOWER(p.operator)`; both execute, so the wrong copy is silent.

**A-R3-5 · §7.7's System-Client row says `filter: 0`, not `filter: "0"` · LOW.** The tenth site of a
nine-site sweep.

**Two nits, not findings.** (1) §7.8's B-4 row attributes one kill message where two are possible (§3 above).
(2) §3.6's bullet *"`store/reports/stockUnit.js` needs **no change** for the filter"* is true of the export
path and reads oddly next to guard-sweep sites 2 and 3, which are new code in that same file for the read
path. The qualifier carries it; I would not edit it.

---

## 7. Length — a direct answer

**I agree with the planner's premise and disagree with its framing.**

The premise is right: I spot-checked all four named blocks and none has internal redundancy. §3.1's SQL
header states each of the five load-bearing arguments once; the 24-column `SELECT` is what §3.3 maps and
`everyMappedColumnResolves` grades; §3.5's six-rail table is M-6's resolution and prevents a wasted review
cycle at ~10 lines; §3.8's derivation carries a positive-controlled zero (45 / 0 / two controls) in six
lines. Trimming any of them deletes content.

But **"has no redundancy" is not the test.** The test is *does the implementer need it inline to act*. On
that test the planner looked in the wrong place, and the cheapest cut in the document is one it did not name.

**Move these two. Both are zero-cost to implementation. −195 lines, landing at ~1,850.**

| Move | Lines | Why it is free |
|---|---|---|
| **The `## Revision log`, lines 1949–2044 → `SBDEV-3410-evidence/revision-log.md`** | **−94** (keep a 2-line pointer) | It is pure provenance. Round 2's half already says *"Kept for provenance"* about itself. No implementer reads it to build anything; the next reviewer and Nam do, and both are already reading the evidence directory. This is the single largest purely-non-implementation block in the plan and it is **larger than three of the four blocks the planner named.** |
| **§3.1's SQL fence, lines 333–443 → `SBDEV-3410-evidence/V2.2.33__stockrecord_view.sql`** | **−101** (keep a ~10-line pointer; §3.1's preamble at 285–332 already carries the three plan-level facts and the five-argument summary) | §3.1's own preamble makes the argument for me: the header *"is the artefact that ships and the one a future reader will be standing in front of."* An artefact that ships belongs in a **file the implementer copies**, not a markdown fence they retype — and P1's *"proof-read the header's numbers before the first apply, Flyway's CRC32 covers comments"* is materially safer against a file than against a fence. Move the header **and** the `SELECT` as one unit; splitting them would be worse than either. |

Optional third, ~−25: §10.4's five proposals (lines 1924–1939 plus lead-in) belong on the **ticket** under the
standing policy, not in the plan. The plan already says they are proposed and not filed; the ranked list can
live where it will be acted on.

I would **not** move §3.5's rail table or §3.8's derivation. Both are under 20 lines, both prevent a specific
re-derivation, and both are read at the moment the implementer is editing the thing they describe.

**What I would not do at all:** trim to hit a number. The document is a T3 plan for a Flyway migration, a new
SDR-exported domain type, an export contract change and an authz widening across two repos. 1,850 lines of
that, with every measurement carrying its control, is not the problem. The round-3 target of ~330 was set
against the round-2 document before round 3's required additions existed, and the revision log is right to
say so in those words rather than rounding.

---

## 8. What still blocks

**Genuine blocker — one:**

1. **A-R3-1.** Measure the zero-row SDR wire shape with `StockrecordViewHalContextTest` before §7.4's
   fixture, §7.8's `rowsOf` row and §7.7's zero-row pass condition are written. Restate §3.9 item 4's
   rationale against the measurement. The production accessor ships either way.

**The implementer or a follow-up can absorb these:**

2. A-R3-2 — §3.9 item 2's "for both branches" → "on the filtered branch". (Would red §7.4 if followed, but
   the snippet, AC-1 and §7.4 all contradict it in the same subsection.)
3. A-R3-3 — re-point N-3's recipe at `BillofladingTransferIdNotNullIT`.
4. A-R3-4 — quote `NATIVE_KEYWORD_CLAUSE`'s text in §3.6, noting the `"operator"` quoting.
5. A-R3-5 — §7.7's `filter: 0` → `filter: "0"`.
6. §7.8's B-4 row: name both possible kill messages.

**Everything else I was asked to verify is confirmed and needs nothing.** A-R2-2, A-R2-3, A-R2-4 (including
the extension, which I grade as the strongest edit in round 3), A-R2-5, N-2, N-4, B-1, B-3 (in AC-1 and
§7.4), B-4 and the 11-call-site correction all landed, and I reproduced the three contested ones — B-1's
fold, B-4's assertion, and the call-site count — independently rather than reading them.

---

## 9. Method, and the blind spots of every completeness word above

| Claim | How derived | Blind spot |
|---|---|---|
| "11 call sites in 2 files" | `git grep -n '\.exportStockUnitRecord(' origin/develop -- src/test` + `-c`, read every hit | Only textual call sites. A reflective or dynamically-proxied invocation would be invisible; none is plausible in a Mockito unit test. |
| B-1 fold table | `node` over the guard quoted from `exportReport.vue:136`, four inputs × three bindings, plus pairwise byte-identity | Models the guard in isolation, not Vue's prop coercion. A `:filter` binding on a prop declared without a type (`props: ['show','reportType','filter','includeShipped']` — verified untyped) passes the value through unchanged, so the model holds; a typed prop would not. |
| B-4 assertion verdicts | Real `javac`/`java` on JDK 21 against the exact interface-constant + `@Query` construct, 1 correct + 6 mutants, plus three forms of the reviewer's literal prescription | Mutant set is mine plus the plan's five; a seventh shape I did not imagine could still slip both assertions. The construct is faithful (real annotation, real reflection), but it is not the real `@Query` type — behaviour of constant folding is identical by JLS §15.29. |
| `_embedded` shape | Source read through four hops in `spring-data-rest-webmvc 4.5.7`, `spring-data-commons 3.5.7`, `spring-hateoas 2.5.1` — versions resolved by `mvn -o dependency:list` in `v2/wms2-api`, not inferred | **I did not observe a live response.** A `HalConfiguration` or custom `LinkRelationProvider` would change it; `git grep` over `src/main` returns zero for all three (positive control: `exposeIdsFor` → 2 hits). This is why the finding is "measure it", not "it is wrong". |
| "parity swept" | `grep -n 'parity'` over the plan, read every hit | Literal only. A paraphrase ("for symmetry", "to match `StockView`") would be missed — same blind spot the planner names. |
| `.target(` precedent count | `git grep -n '\.target(' origin/develop -- src/test`; `git grep -l 'Flyway.configure()' … \| wc -l` | `grep` here is ugrep and skips binary without `-a`; `git grep` is unaffected, and both commands used `git grep`. A `target(` built from a variable in a helper I did not open would be missed. |
| `operator` is unreserved / both forms execute | `pg_get_keywords()` + two executed `SELECT`s + `information_schema.columns` on `dev_wh01_om1` | One Postgres version, one tenant. Reservation status is a server-version property; a prd server on a different major could differ, though `operator` has been unreserved for many releases. |
| System-Client row counts | `SELECT count(*) FROM stockrecord WHERE client_id = 0` on `dev_wh01_om1` (16) and `wh01_hydra_v2` PRD (0), with `client` existence confirmed on both | Two databases. Both ShipItEZ prd databases remain unreachable from this MCP set — the plan already records this blind spot in §3.2 and §5.1. |
| "no HAL customisation beans" | `git grep 'HalConfiguration\|LinkRelationProvider\|RelProvider' origin/develop -- src/main` → 0, positive control `exposeIdsFor` → 2 | A bean registered via `spring.factories`/`AutoConfiguration.imports` or supplied by a dependency would not appear. |
| "three of four `_embedded` surfaces affected" | Read each of §7.2, §7.4, §7.7, §7.8's rows and reasoned about what each can observe | Reasoning, not execution — none of the four tests exists yet. |
