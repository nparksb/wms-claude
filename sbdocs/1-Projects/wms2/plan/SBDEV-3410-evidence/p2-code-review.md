# SBDEV-3410 P2 — code review

- **Subject:** commit `1ec4f271` "SBDEV-3410 P2: StockrecordView entity, repository and SDR registration"
- **Worktree:** `/Users/np1076/dev/spk/owl/.claude/worktrees/wms2-api/SBDEV-3410`
- **Branch:** `feature/SBDEV-3410-p2-stockrecord-view-entity-sdr`, ahead 1 of `origin/develop` @ `f2ee75f1`
- **Plan:** `sbdocs/1-Projects/wms2/plan/SBDEV-3410-stock-unit-record-shipper-filter-and-product-name.md` (§3.3, §3.4, §3.5, §5.2 P2, §7.2, §7.3, §7.5)
- **Reviewer:** p2-code-review lane, 2026-09-21. Read-only: no `mvn`, no file edits, no git state changes in the worktree.
- **Scope note:** the working tree carries **two uncommitted files** (`StockrecordViewRepositoryFilterIT`, `TestClassTransactionManagerArchTest`) that a sibling lane has since edited. Findings are stated against **commit `1ec4f271`**, and every finding already closed by the working tree is marked **ALREADY FIXED IN WORKING TREE**.

## Verdict

**Does the diff build the wrong thing? No.** Nothing in it contradicts the plan's design. Every item on §5.2 P2's checklist is present, the one deviation (COALESCE in `KEYWORD_CLAUSE`) is the approved one and I measured that it costs nothing the plan cared about, and the two §7.2 rows that are absent are export-path cases that belong to P3 and that §5.2 P2 does not list. The design is sound and the implementation matches it.

**One High.** As committed, `1ec4f271` reds the surefire lane: a new `@Transactional(propagation = NOT_SUPPORTED)` test class was added without its mandatory `TestClassTransactionManagerArchTest` allowlist entry, and that rail asserts an **exact set equality**. Already fixed in the working tree, uncommitted.

Then 2 Medium and 9 Low. No Critical. Most of the Lows are claim-accuracy defects in javadoc that this repo treats as load-bearing (a false mechanism in a comment is what the next ticket builds on), plus three assertions that are weaker than the sentence describing them.

## What I measured independently

All against `wh01_hydra_v2` (hydra UAT, PostgreSQL **16.10**) via the `nywh-hydra-uat` MCP, read-only. V2.2.33 has landed there — `stockrecord_view` and `index_stockrecord_client_created` both exist — so this is a second database, independent of the author's `dev_wh01_om1` measurements.

1. **Column mapping is an exact bijection — 28/28.** The live migrated view has exactly 28 columns; `StockrecordView` maps exactly those 28. No mapped column that does not exist, no projected column left unmapped, no phantom. `stockrecord` itself has 24 columns, so the view is a strict superset (24 + `item_id`, `item_name`, `cl_nr`, `cl_name`) exactly as the migration header claims.
2. **Types match `Stockrecord`.** `activitycode`/`fromstoragelocation`/`fromunitload`/`itemdata`/`operator`/`ordernumber`/`type`/`unitloadtype`/`additionalcontent`/`fromstockunitidentity`/`tostockunitidentity`/`tostoragelocation`/`tounitload` = `character varying` → `String`; `amount`/`amountstock`/`reservedamountchange`/`reservedamountstock` = `numeric` → `BigDecimal`; `scale`/`version`/`entity_lock` = `integer` → `Integer`; `id`/`client_id`/`item_id` = `bigint` → `Long`; `cl_nr`/`cl_name`/`item_name` = `character varying` → `String`. `created`/`modified` are `timestamp with time zone` mapped as `LocalDateTime` — **which is exactly what `Stockrecord` does today against the same underlying column**, under the same `ddl-auto=validate` lane, so it is parity and not a new risk.
3. **The COALESCE deviation does not cost the index.** The *shipped* clause (all five operands COALESCEd) plus the plain equality, under `plan_cache_mode = force_generic_plan` and `enable_seqscan = off`:
   ```
   Index Scan using index_stockrecord_client_id on stockrecord sr
     Index Cond: (client_id = $2)
     Filter: ((concat(lower((COALESCE(activitycode, ''::character varying))::text), ' ', …)) ~~ lower(concat('%', $1, '%'))) OR ($1 = ''::text))
   ```
   Index Cond derived, and **both LEFT JOINs eliminated** (plan is over `stockrecord sr` alone) — so the COUNT half of the `Page` still gets join elimination with the COALESCEs in place.
4. **The negative control discriminates, reproduced on a second DB.** Same session, same clause, the three-arm OR form instead:
   ```
   Seq Scan on stockrecord sr  (cost=10000000000.00..10000006505.53 …)
     Filter: (((client_id = $2) OR ($2 IS NULL) OR ($2 = '-1'::integer)) AND …)
   ```
   No Index Cond, at penalty cost. **The two-method split is justified and the IT's negative control is real.**
5. **`COALESCE` on a NOT NULL column is NOT discarded by the planner.** Measured twice (once standalone, once inside the plan above): `COALESCE(activitycode, '')` on a `NOT NULL` column survives verbatim into the `Filter`. See L2.
6. **Nullability matches the commit's claim exactly.** `activitycode`, `fromstoragelocation`, `operator` are NOT NULL; `fromunitload`, `itemdata` are nullable. 2-of-5, as stated.
7. **The FilterIT fixture supplies every NOT NULL-without-default column** on all four tables it writes: `client` (id, version, name, cl_nr) · `itemdata` (id, version, name, item_nr, scale, client_id, handlingunit_id) · `itemunit` (id, version, basefactor, unitname) · `stockrecord` (id, version, activitycode, fromstoragelocation, tostoragelocation, operator, client_id). No missing-column red risk.
8. **Both new ITs are in a lane.** `pom.xml` failsafe `<includes>` carries `**/*IT.java`; surefire excludes only `*IntegrationTest`/`*E2ETest` and its default patterns do not match `*IT`. The four `*Test` classes are surefire. Nothing is inert.
9. **The postgres-integration lane will validate this entity.** `app.flyway.migrate-on-startup=true` is set in the main `application.properties` and is **not** overridden by `application-postgres-integration.properties`, so tenant Flyway runs `db/migration` on context start and the view exists before `ddl-auto=validate` (which *does* reach the tenant PU — `TenantDatabaseConfig:77-78` puts `hibernate.dialect` and `hibernate.hbm2ddl.auto` in explicitly, which is why those two survive the empty-`jpaProperties` gap SBDEV-3247 documented).

---

## Findings

### H1 — Critical/**High**: the commit reds surefire — missing `TestClassTransactionManagerArchTest` allowlist entry
**ALREADY FIXED IN WORKING TREE** (uncommitted).

`StockrecordViewRepositoryFilterIT` carries `@Transactional(propagation = Propagation.NOT_SUPPORTED)`. `TestClassTransactionManagerArchTest.nonTransactionalPropagationsMustBeDeclared()` collects every test class with `NOT_SUPPORTED`/`NEVER` and asserts:

```java
.isEqualTo(EXEMPT_NON_TRANSACTIONAL);
```

An **exact set equality**, not a `containsAll`. Commit `1ec4f271` adds the class and does not add the name, so that test fails in **surefire** — the lane `.github/workflows/docker-image-develop.yml` runs via `mvn clean verify` and on which the `build` job declares `needs: test`. A merge of `1ec4f271` as committed would turn `develop` red and silently stop deploying (the failure mode `wms2-api`'s CLAUDE.md names explicitly).

This is not a style point: it means the surefire lane was not run before the commit. The commit message gives a full six-class test accounting and a five-mutant table, and never mentions the seventh file it needed to touch. Worth saying plainly because the plan's §5.2 P2 does not list this rail either — the rail is discoverable only by running the lane.

The working-tree fix is good: the entry is written in the rail's own idiom, gives both reasons (committed fixture; session GUCs that a test-managed transaction would roll back), enumerates the ids and the FK delete order, and calls out the client-0 carve-out. Two nits inside it:
- it claims `stockrecord 9913420-9913423`; the actual ids are `9913420`/`9913421`/`9913422` — there is no `...423`;
- it repeats "because the connection returns to a shared pool", which is false in this lane (see L6).

**Fix:** commit the working-tree change; correct the id range and the pool claim in the same edit. Then run `mvn test -Dtest=TestClassTransactionManagerArchTest` before pushing.

---

### M1 — Medium: the IT's hand-copied `keywordSql()` had drifted from the constant it claims to mirror
**ALREADY FIXED IN WORKING TREE** (uncommitted).

At `1ec4f271`, `StockrecordViewRepositoryFilterIT.keywordSql()` was documented as *"The keyword arm, matching the shape of `StockrecordViewRepository.KEYWORD_CLAUSE`"* and carried the **un-COALESCEd** five operands — in the very commit that added the COALESCEs. So `filteredSearchKeepsAnIndexCondition` was EXPLAINing a predicate the application never issues, and the one claim the whole two-method split rests on was graded against the wrong SQL.

I measured the correct form (item 3 above) and the verdict is unchanged — the Index Cond survives the COALESCEs — so this was a latent instrument defect rather than a wrong conclusion. But it is exactly the hand-copy drift the repository's own javadoc warns about, and it drifted inside one commit.

The working-tree fix restores operand-for-operand parity and adds the right javadoc: *"an un-COALESCEd copy here would EXPLAIN a query this application never issues."* Good. Commit it.

---

### M2 — Medium: `bothSearchesSearchTheIdenticalColumnSet` pins *equality*, never *which five columns*

`SEARCHED_COLUMN` = `LOWER\((?:COALESCE\()?p\.([A-Za-z_]+)`. I traced it over the shipped text: it matches all five operands in both queries and does **not** match `LOWER(concat('%', :keyword,'%'))` (the inner token is lower-case `concat`, the pattern is case-sensitive) nor `p.clientId` (no `LOWER(` prefix). So the regex does today match what it claims — the lead's specific worry is unfounded.

The gap is different. Three assertions run: `unfilteredColumns.isNotEmpty()`, `filteredColumns.isEqualTo(unfilteredColumns)`, and `filtered.startsWith(unfilteredWhere)`. Narrow **both** queries to a single column — or narrow `SEARCHED_COLUMN` itself to match only one — and **all three stay green.** The `isNotEmpty()` guard is a control on a literal, which per this repo's own rule ("a control on a literal can't detect a narrowed pattern") cannot see a narrowed pattern. Nothing asserts the cardinality, and nothing asserts the identity of the five.

The practical exposure is bounded: `startsWith(unfilteredWhere)` does kill the one-sided hand-copy, which is the failure mode §3.4 actually names. So this is not a live hole, it is an unpinned invariant that the test's own `.as()` message asserts it pins.

One-line close:
```java
assertThat(unfilteredColumns).containsExactlyInAnyOrder(
    "activitycode", "fromstoragelocation", "fromunitload", "itemdata", "operator");
```

**Related, and worth a line on the ticket:** the commit message's mutant table attributes *"hand-copy the clause, drop a searched column"* to `bothSearchesSearchTheIdenticalColumnSet` and claims "every kill attributable to exactly one assertion". Two of the five rows break that claim — this mutant is killed by both the set-equality and the `startsWith` assertion in the same method, and the `exposeIdsFor` mutant is killed by both `StockrecordViewSdrRegistrationUnitTest` **and** `StockrecordViewHalContextTest` (the commit message says so itself, in the same table). Defence in depth is fine; the accounting sentence is what is wrong.

---

### L1 — Low: `hashCode()`'s stated rationale does not apply to this entity

Answering the lead's question 2 directly: **keying `hashCode` on `getClass()` is not a defect here** — it is consistent with `equals` (equal objects hash equal), it matches both `AbstractBaseEntity` and `StockView`, and no code puts these in a hash container at scale. Keep the code.

The **comment** is wrong, though:

> `// keying on getId() would change from null→Long and corrupt any hash container the entity was added to first.`

That mechanism is `AbstractBaseEntity`'s, where `@Id` is `@GeneratedValue(SEQUENCE)` and genuinely transitions `null → Long` at flush. `StockrecordView`'s `@Id` is **assigned** — set by the JDBC read on every real path, and set explicitly before `persist()` on the one test path — and the entity is read-only, so the transition the comment describes cannot occur. Keying on `getId()` would in fact be strictly better *for this class*, which makes the comment an argument for the wrong conclusion.

**Fix:** state the real reason — parity with `StockView`/`AbstractBaseEntity`, so the package has one rule — and drop the lifecycle claim. Note in passing that `getClass().hashCode()` makes every instance collide, which is why keeping a page of these in a `HashSet` is O(n²); irrelevant at page size 50, worth not discovering later.

---

### L2 — Low: "COALESCE on a NOT NULL column is a no-op the planner discards" is measurably false

`StockrecordViewRepository.KEYWORD_CLAUSE`'s javadoc justifies wrapping all five operands rather than the two nullable ones with:

> *"The uniform rule costs nothing — `COALESCE` on a NOT NULL column is a no-op the planner discards."*

Measured on PG 16.10, `wh01_hydra_v2`:
```
EXPLAIN (VERBOSE, COSTS OFF) SELECT id FROM stockrecord WHERE COALESCE(activitycode,'') = 'zzz' …
  Filter: (((COALESCE(stockrecord.activitycode, ''::character varying))::text = 'zzz'::text) AND …)
```
`activitycode` is NOT NULL and the `COALESCE` node **survives into the plan verbatim** — twice, including inside the real filtered plan in item 3. PostgreSQL simplifies `COALESCE` only when an argument is a non-null constant or all arguments are constants; a plain column reference is neither, and `eval_const_expressions` has no NOT-NULL-aware rewrite.

**The decision is still right** — a future migration relaxing a NOT NULL cannot silently reintroduce the NULL-hides-the-row defect, and that is a real argument. Only the cost claim is wrong, and it is the kind of claim the next person will reuse as a general rule. The honest version: three extra `COALESCE` nodes are evaluated per row, at a fraction of the `LOWER` + `CONCAT` + `LIKE` already in the same filter, and the whole filter folds away on the `keyword = ''` path under a custom plan.

**Second, smaller claim in the same javadoc:** *"Hibernate renders JPQL `CONCAT` as `||`, `NULL || x` is NULL."* If Hibernate instead rendered it as PostgreSQL's `concat()` **function**, NULLs would be ignored and the defect would not exist. The author states this was measured in a PG 14 container, and `nullInOneSearchedColumnDoesNotHideTheRow` is a **behavioural** test that is correct either way — so nothing depends on the mechanism being right. Recording it because the sentence is stated as fact and I could not reproduce the rendering without running the lane.

---

### L3 — Low: `equalsAndHashCodeAreHandWrittenOnId` asserts declaration, not behaviour

The test's `@DisplayName` and message say *"keyed on id"* and *"in the StockView shape: `getId() != null && getId().equals(other.getId())`"*. The body is:

```java
assertThat(type.getDeclaredMethod("equals", Object.class)).isNotNull();
assertThat(type.getDeclaredMethod("hashCode")).isNotNull();
```

`getDeclaredMethod` throws `NoSuchMethodException` when absent, so the `isNotNull()` can never fail and the `.as()` message can never surface. More to the point, nothing grades the *semantics*: mutate `equals` to `return false;`, or to `return o instanceof StockrecordView;`, or `hashCode` to `return 0;`, and the test stays green. The plan's §3.3 rule 2 prescribes the body; this test pins only that a body exists.

**Fix (three lines):** two instances with the same id are equal and hash equal; two with different ids are not; one with a null id is not equal to a distinct instance. That also converts H1's "assigned id" property into something asserted rather than assumed.

---

### L4 — Low: `StockrecordViewHalContextTest` asserts `[0]` on an unordered match-all page

`get("/v3/stockrecordView/search/findByKeyword?keyword=&page=0&size=1")` then `$._embedded.stockrecordView[0].id`. `keyword=` takes the `or :keyword = ''` escape, so the page is "any one row, unordered".

It is correct today: nothing else in the H2 `integration` lane writes `stockrecord_view`, and `BaseControllerIntegrationTest` rolls back. The moment a sibling seeds that table and commits, `[0]` silently grades another row — and the failure would read as "`exposeIdsFor` regressed" rather than "the fixture moved". The class javadoc is otherwise careful about exactly this class of hazard, so the omission stands out.

**Free hardening:** the seeded row already carries `activitycode = "SBDEV3410HAL"`, and `activitycode` is one of the five searched columns. Pass `keyword=SBDEV3410HAL` and the page contains exactly the seeded row, by construction. No new fixture, no new assertion.

(Not a finding: `jsonPath(...).value(ROW_ID)` with a `long` against a JSON integer is safe — `JsonPathExpectationsHelper.assertValue` re-evaluates the path with the expected type when the classes differ.)

---

### L5 — Low: `filteredSearchKeepsAnIndexCondition` does not pin *which* index

Answering part of the lead's question 1's follow-on. The assertion is `plain.contains("Index Cond")`. `stockrecord` already carries `index_stockrecord_client_id`, a pre-existing single-column index that also yields `Index Cond: (client_id = $2)` — and on hydra UAT the planner in fact **chose the old index**, not `index_stockrecord_client_created` (see item 3). So dropping V2.2.33's 276 MB index would leave this test green, while its own `.as()` message says *"that reachability is the entire reason V2.2.33 built a 276 MB index"*.

**Severity is Low because the gap is already covered by a sibling in the same file:** `StockrecordViewSchemaIT.index_shouldExistOnClientIdAndCreated()` (AC-P1d, P1) pins the index's existence directly. So the invariant is guarded; only this test's self-description overstates what it grades.

**Recommendation:** soften the message rather than the assertion. Pinning the index *name* here would be actively worse — on a 7-row fixture the planner may legitimately pick either index, and a name assertion would be flaky. If a stronger form is ever wanted, the discriminating query is the *sorted* one (`ORDER BY created DESC` under the filter), where only the composite index avoids a sort.

---

### L6 — Low: the GUC-leak comment describes a pooled connection that this lane does not have

Answering the lead's question 6 definitively: **no, a leaked GUC cannot reach another test, and the reason is not the `finally`.**

`StockrecordViewRepositoryFilterIT`'s `jdbcTemplate` is the bean from `PostgresTestSupportConfig.jdbcTemplate()`, which wraps a Spring **`DriverManagerDataSource`** — a new physical `DriverManager` connection on every `getConnection()`, closed on release. Nothing is pooled. The class is `@Transactional(NOT_SUPPORTED)` so no transaction-bound connection is reused either. `SET plan_cache_mode` / `SET enable_seqscan` die with the connection; the `RESET ALL` / `DEALLOCATE ALL` in the `finally` are harmless belt-and-braces. **Keep them** — they cost nothing and they are correct if the bean is ever repointed at a pool — but the comment

> `// The connection goes back to a shared pool — a leaked enable_seqscan would silently reshape every later test's plans.`

is false in this lane, and it is now repeated verbatim in the working tree's `TestClassTransactionManagerArchTest` entry. Two copies of a false mechanism is how this repo's sibling-copy problem starts.

**Fix:** say what is true — *"this lane's `JdbcTemplate` is a `DriverManagerDataSource`, so the connection is not pooled and these SETs die with it; the reset is kept for the case where that bean is repointed at a pool"* — and correct both copies.

**For the record on the sharper hazard,** in case the bean ever *is* pooled: `DEALLOCATE ALL` is the dangerous statement, not `RESET ALL`. It invalidates pgjdbc's own server-side prepared-statement cache, which is normally a hard error on the next reuse. pgjdbc's `flushCacheOnDeallocate` defaults to `true` and scans executed SQL for `DEALLOCATE ALL`/`DISCARD ALL`, and nothing in this repo disables it (grepped), so it is handled — but the guard is a driver default, not something this repo asserts.

---

### L7 — Low: `SdrWriteWithdrawalContextTest` — the generalisation is faithful, but its rule is enforced only by prose

Answering the lead's question 7: **this is a faithful generalisation, not a weakening.** Four reasons:
1. `COLLECTION_GET_ABSENT_BY_REPOSITORY_SHAPE` is a closed allowlist of exactly two literal names, not a predicate that could match more. A one-name `String` constant and a two-name `Set` have identical strength.
2. The ITEM-axis GET requirement still applies to both members — the `continue` skips only `ResourceType.COLLECTION`.
3. Every other name in `WITHDRAWN` is still required to answer GET on both axes.
4. The stated rule is *true of both members*, which I verified rather than assumed: `StockViewRepository` overrides all three `findAll` overloads with `@RestResource(exported = false)` (SBDEV-2219 Fix D, critic M3), and `StockrecordViewRepository` does the same.

The residual weakness is that the rule — *"a repository that overrides all three `findAll` overloads … has no collection read for SDR to expose"* — is enforced by the javadoc's *"check that, do not infer it from a red"*, i.e. by prose. Per this repo's own "prose enumerations rot — state the rule" rule, the mechanical form is available: resolve the name's repository off the SDR metadata and assert all three `findAll` overloads carry `exported = false` **before** allowing the skip, so a name added by reflex fails rather than passes. Genuinely a nice-to-have and defensible to defer; recording it because it is the only thing the generalisation gave up.

Also correct and worth noting: the javadoc's arithmetic reconciles (50 withdrawn + 9 kept = 59), `hasSize(50)` moved with the set, and the paragraph explains *why* this 50th is a new resource rather than a reclassification — which is the distinction the three earlier corrections in that file did not have.

---

### L8 — Low: `everyMappedColumnResolves` is one-directional, and that blind spot is not in its list

The method's javadoc carefully enumerates its blind spots (*"column NAMES only. Type, order and nullability are not checked here"*) but omits the direction: it asserts entity ⊆ view, never view ⊆ entity. I measured the bijection is exact today (28/28), and an appended column in some future `V2.2.x` that the entity does not map is harmless for a read-only report — so this is **genuinely out of scope** and I would not fix it. It belongs in the blind-spot list, though, because that list is the thing a later reader trusts.

---

### L9 — Low (nits)

- **`exposeIdsFor` ordering.** The insertion reads `Stockunit.class, StockView.class, StockrecordView.class,` — the list is otherwise alphabetical, and `SDR_WRITE_WITHDRAWN` places the same name correctly (`Stockrecord`, `StockrecordView`, `Stockunit`). Cosmetic; worth matching so the two lists diff cleanly against each other, which is how the `IDENTICAL` claim is maintained.
- **The `Class.forName` reason has expired for three of the four reflection tests.** `StockrecordViewEntityContractUnitTest`, `StockrecordViewRepositoryQueryShapeUnitTest` and `StockrecordViewSdrRegistrationUnitTest` all still address the types by string literal. The TDD-gate justification ("a test file that cannot compile takes the whole lane with it") is no longer live now that the types exist, and plan §5.2 explicitly permits the conversion — `StockrecordViewSchemaIT.everyMappedColumnResolves`'s javadoc says so in as many words; the other three do not mention it. Direct references would give compile-time safety against a rename, which a string literal silently survives. Low because the tests do work as written.
- **`StockrecordView.equals` uses `instanceof` without `getClass()`.** `AbstractBaseEntity` adds `this.getClass() != other.getClass()`; `StockView` omits it, and so does this. Consistent with the precedent it names, and there are no subclasses and no Hibernate proxies (no association targets it). Non-issue, recorded so it is not re-raised.

---

## Plan conformance — item by item

Nothing here **contradicts** the plan's design. Two rows differ in placement, one deviates by prior approval.

| §5.2 P2 checklist item | Status |
|---|---|
| `StockrecordView.java` per §3.3 — no `AbstractBaseEntity`, explicit `@Column` on every camelCase field, hand-written `equals`/`hashCode`, `created`/`modified` as `LocalDateTime` | **Done.** All four §3.3 rules built and asserted. Rule 1 (real PK `@Id`), rule 2 (stands alone, superclass is `Object`, no `@Version`), rule 3 (six camelCase fields annotated; 28/28 resolve — measured), rule 4 (nine sort keys present) |
| `StockrecordViewRepository.java` per §3.4 — `ReadOnlyPagingAndSortingRepository`, two searches, plain equality, all three `findAll` suppressed, one shared `KEYWORD_CLAUSE` | **Done.** One approved deviation: every operand `COALESCE`d (§3.4 specified verbatim carry-over from `StockView`). Measured: does not affect index reachability or join elimination |
| `RestConfiguration`: `exposeIdsFor` **and** `SDR_WRITE_WITHDRAWN` | **Done.** Both, with the "required not parity" reasoning inline |
| `SdrWriteWithdrawalContextTest`: 50th name, `hasSize(49)`→`50`, javadoc corrected | **Done.** Plus a faithful generalisation of the one-off `STOCK_VIEW` case (L7) |
| FilterIT + HalContextTest + QueryShapeUnitTest written first and failing | **Done**, plus two unlisted extras (`StockrecordViewEntityContractUnitTest`, `StockrecordViewSdrRegistrationUnitTest`) — additional coverage, not a contradiction |
| Mutation checks with attributable kills; do **not** use "drop one `@Column`" | **Done**, and the forbidden mutant is correctly absent. Two of the five rows are not singly-attributable (M2) |
| Do **not** add an `SdrFunctionRules` entry; note the `wms2.authz.sdr.unruled` label | **Done.** Recorded in the commit message |

Three plan rows worth flagging so nothing is lost:

- **`everyUiSortKeyResolves` (§7.2, filed under `StockrecordViewSchemaIT`) was relocated**, not dropped — it is `StockrecordViewEntityContractUnitTest.everyUiSortKeyResolvesToAField`, with the same single source-of-truth list. Surefire instead of failsafe, so it runs earlier and faster. **Better than specified**; the plan row should be updated to match.
- **`exportPredicateRendersOnPostgres` and `unfilteredExportRouteIsUnchanged` (§7.2) are absent, correctly.** Both test `StockrecordRepository`'s **export** methods (`findByClientOffsetAndLimit` / `findByOffsetAndLimit`), which are **P3**'s subject; §5.2 P2 does not list them. The plan mis-filed two P3 cases into a P2 test class. **Not a code defect — a plan defect.** Move those two rows to P3's testing section before P3 is gated, or they will be lost at the P2→P3 boundary.
- §7.2's stated reasoning for the negative control — *"its keyword arm references five unindexed columns, so there is no index-only path either"* — is **false on the real schema**: `stockrecord` carries single-column indexes on all five (`index_stockrecord_activitycode`, `_fromstoragelocation`, `_fromunitload`, `_itemdata`, `_operator`). The **conclusion still holds** for a different reason: `LOWER(COALESCE(col,'')) LIKE '%…%'` is not an indexable expression on any of them, which is why my re-measurement of the OR form still fell to a penalised seq scan. Worth correcting in the plan so the control is defended on the reason that is true.

## Answers to the seven questions asked

1. **Column mapping.** Exact bijection, 28/28, measured against the live migrated view on a second database. Types mirror `Stockrecord` including the `timestamptz → LocalDateTime` pair, which is the existing entity's own behaviour under the same validator. **No defect.**
2. **`equals`/`hashCode`.** The code is right (consistent, matches both precedents, no exposure). The **comment's rationale is inapplicable** to an assigned `@Id` — fix the comment, keep the code. L1.
3. **`KEYWORD_CLAUSE` COALESCE.** No effect on the index story, **measured**: plain equality still derives `Index Cond: (client_id = $2)` under `force_generic_plan`, and both joins still eliminate. No bad interaction with `or :keyword = ''` — the escape gets strictly *better*, because the CONCAT can no longer be NULL. The one wrong thing is the cost claim about constant folding. L2.
4. **Vacuity of the three reflection tests.** All three carry real vacuity guards and the `SEARCHED_COLUMN` regex does match what it claims. Two real gaps: `bothSearchesSearchTheIdenticalColumnSet` never pins the *five* (M2), and `equalsAndHashCodeAreHandWrittenOnId` pins declaration rather than behaviour (L3). `queryShapeForbidsADisjunction`'s second assertion currently examines an empty tail (the conjunct is last), which is fine — it is a forward guard, and the mutants it claims are killed by assertion 1.
5. **FilterIT fixture isolation.** Sound. Every assertion is scoped by `activitycode = 'sbdev3410filterit'` (unique to this class) and asserted by id; `wipe()` covers all four tables in correct FK order (`stockrecord` → `itemdata` → `itemunit` → `client`), by id in every case, and **never deletes the `client` id 0 row itself** — only the `stockrecord`/`itemdata` rows the fixture attached to it. `CLIENT_A`…`CLIENT_NULLCOL` and all seven `stockrecord` ids are in a range no other class uses. The one soft spot is AC-4 case (a), which uses `contains(...)` rather than `containsExactly(...)`; it is covered by the `allSatisfy(clientId == CLIENT_A)` that follows and by the fact that `CLIENT_A` is created and wiped per test, so no leak is reachable. **No finding.**
6. **Can a leaked GUC reach another test?** **No.** `PostgresTestSupportConfig.jdbcTemplate()` is a `DriverManagerDataSource` — a fresh physical connection per statement, closed on release. The `finally` is correct but not load-bearing; the comment claiming a shared pool is wrong and is now duplicated. L6.
7. **The `SdrWriteWithdrawalContextTest` change.** A **faithful generalisation**, not a weakening — closed two-name allowlist, ITEM-axis GET still required, rule verified true of both members. Only residual: the rule is enforced by prose rather than mechanically. L7.

## Suggested order of work

1. **H1** — commit the working-tree `TestClassTransactionManagerArchTest` entry, fix its id range and pool claim, run `mvn test -Dtest=TestClassTransactionManagerArchTest`.
2. **M1** — commit the working-tree `keywordSql()` fix.
3. **M2** — one line: `containsExactlyInAnyOrder` the five searched columns. Correct the commit message's / plan §7.8's attribution for the two rows that have two kills.
4. **L1, L2, L6** — three comment corrections; L2 and L6 both assert mechanisms I measured to be false, and L6's false copy already propagated once.
5. **L3, L4** — two cheap test strengthenings (behavioural `equals`; scope the HAL page by keyword).
6. **L5, L8, L9** — message/blind-spot/ordering corrections.
7. **Plan edits** — relocate §7.2's `everyUiSortKeyResolves` row; move `exportPredicateRendersOnPostgres` and `unfilteredExportRouteIsUnchanged` to P3; correct the "five unindexed columns" reasoning.
8. **L7** — optional, and a fair candidate to defer to the SBDEV-3222/3183 SDR-rules programme that already owns this area.

---

## Addendum — L10 and working-tree drift observed during the review

**L10 — Low: `/api/stockrecordView` in comments and assertion messages; the SDR base path is `/v3`.**
Commit `1ec4f271` writes the route as `/api/stockrecordView` in three places — the `SDR_WRITE_WITHDRAWN`
comment in `RestConfiguration` (*"SDR routes DELETE /api/stockrecordView/{id}"*), and two assertion
messages in `StockrecordViewRepositoryQueryShapeUnitTest` (*"/api/stockrecordView unbounded"*,
*"/api/stockrecordView?sort="*). `config.setBasePath(MY_BASE_URI_URI)` puts SDR at **`/v3`**, which
`StockrecordViewHalContextTest` itself demonstrates by calling `get("/v3/stockrecordView/search/...")`.
The same slip is carried into `SdrWriteWithdrawalContextTest`'s new javadoc. Harmless at runtime,
but these are the strings a reader greps for when reproducing the delete-against-a-view hazard.
**Being fixed by a sibling lane while this review was written** — `/api/` → `/v3/` edits are present
in the working tree for the query-shape test.

**Working-tree state at the end of this review** (six modified files, all uncommitted). A sibling lane
is actively editing, and at least H1, M1 and L10 are already addressed there:

```
 M src/main/java/net/aim_ai/wms/RestConfiguration.java
 M src/main/java/net/aim_ai/wms/repo/jpa/StockrecordViewRepository.java
 M src/test/java/net/aim_ai/wms/integration/repository/StockrecordViewRepositoryFilterIT.java
 M src/test/java/net/aim_ai/wms/security/SdrWriteWithdrawalContextTest.java
 M src/test/java/net/aim_ai/wms/unit/config/TestClassTransactionManagerArchTest.java
 M src/test/java/net/aim_ai/wms/unit/repo/StockrecordViewRepositoryQueryShapeUnitTest.java
```

Re-check each finding against the working tree before acting on it — this report is anchored to
commit `1ec4f271`, not to the tree as it stands now.
