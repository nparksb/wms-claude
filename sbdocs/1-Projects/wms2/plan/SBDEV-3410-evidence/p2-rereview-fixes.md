# SBDEV-3410 P2 — re-review of the FIX COMMITS (`1ec4f271..936a4cf4`)

**Lane:** fourth, delta-only. **Date:** 2026-09-22.
**Subject:** `git diff 1ec4f271..936a4cf4` — commits `37564268` and `936a4cf4`. Nothing earlier.
**Worktree:** `/Users/np1076/dev/spk/owl/.claude/worktrees/wms2-api/SBDEV-3410` @ `936a4cf4`, clean, `ahead 3` of `origin/develop`.
**Constraint honoured:** read-only. No file in the worktree was modified. No `mvn` was run — see §8 for the exact commands I need run.

**Verdict: the delta is sound and I found no defect that changes runtime behaviour.** The SDR rule is
correctly wired, correctly constrained, and its blast-radius claim reproduces exactly on prd. The nine
code-review fixes are real fixes, not symptom patches. But there are **two substantive claim defects**
(one of which makes an EXPLAIN measure a different expression than the one shipped, and one of which is a
comment that contradicts itself two lines later) and **six Lows**, five of them false or stale statements
of fact of the kind this repo fixes rather than suppresses.

---

## 1. Severity table

| # | Sev | Where | One line |
|---|-----|-------|----------|
| M1 | **Medium** | `StockrecordViewRepositoryFilterIT.keywordSql()` (37564268) | Raw-SQL `CONCAT(...)` is PostgreSQL's NULL-**ignoring** `concat()` function, not the `\|\|` Hibernate emits — so "operand-for-operand identical … the plan being measured is the plan the repository produces" is false, and the COALESCEs just added to the copy are semantically inert |
| M2 | **Medium** | `TestClassTransactionManagerArchTest` EXEMPT entry (37564268, edited 936a4cf4) | The entry's second stated reason ("inside a test transaction a plain `SET` is undone by the rollback") cannot apply to this lane, and the same comment says so two lines later after the L6 fix. Entry required; reason wrong |
| L1 | Low | `StockrecordViewEntityContractUnitTest.equalsAndHashCodeAreHandWrittenOnId` (936a4cf4) | Fixture ids `42L`/`43L` sit inside the `Long` cache band, so a `getId() == other.getId()` reference-comparison mutant survives all six new assertions |
| L2 | Low | same test / L3's commit-message framing | The rewrite does not kill `hashCode -> return 0`, and cannot — the message lists it among the mutants the old assertion let through without saying it stays alive (correctly, since it is behaviourally identical to the shipped `getClass().hashCode()`) |
| L3 | Low | `StockrecordViewRepository` javadoc (936a4cf4, L2 replacement) | "measured false on PG 16.10 (`wh01_hydra_v2`)" — `wh01_hydra_v2` is **PostgreSQL 14.23**. The substance is true (I reproduced both halves on 14.23); only the version attribution is wrong |
| L4 | Low | `936a4cf4` commit message, L9 | Three false premises: `exposeIdsFor` is not alphabetically sorted; the new slot is not the ASCII-alphabetical one; and the "IDENTICAL claim between the two lists" is between two *other* lists |
| L5 | Low | arch-test EXEMPT comment (37564268) | Inventory says `stockrecord 9913420-9913423`; there is no `…423` — the class seeds `…420/421/422` |
| L6 | Low | plan doc | §3.5 and the §5.2 checklist carry the supersede marker; three sibling statements elsewhere still assert the withdrawn decision as fact, one of them arithmetic that is now wrong |
| L7 | Low / informational | ticket | At `ENFORCE_RULED`, `oms_integration` and `anonymous` are denied `/v3/stockrecordView/**`. Correct today (no reader exists); it is a constraint on P6 and on any future OMS read |

---

## 2. Q1 — is the `SdrFunctionRules` entry correct and correctly wired?

**Yes, on every axis asked.** Checked against the real mechanism, not the commit message.

- `rules.put(StockrecordView.class, STOCK_UNIT_RECORD_VIEW)` lands in `productionRules()`'s local
  `LinkedHashMap`, which is the map the constructor wraps into `this.rules`
  (`SdrFunctionRules.java:228-231` region, `productionRules()` returns it directly). It is the map
  `requiredFunctions()` and `ruledDomainTypes()` read. ✅
- `ordered(...)` is `Collections.unmodifiableSet(new LinkedHashSet<>(Arrays.asList(functions)))` —
  insertion-ordered, exactly as assumed. The whole reason it exists (the `Set.of` per-JVM `SALT`
  defect) is moot for a single-element set, so nothing turns on it here. ✅
- `WEB_UI_VIEW_STOCK_UNIT_RECORD` is the right constant. `ReportController:249` carries
  `@RequiresFunction(WmsConstants.FunctionEnum.WEB_UI_VIEW_STOCK_UNIT_RECORD)` on
  `POST /exportStockUnitRecord` — the CSV of these rows — and `StockRecordController:36,51` gates the
  two MVC stock-record reads on the same function. It is seeded per tenant since `V2.2.00`
  (`V2.2.00__base_v2_schema.sql:2768`, function id 529), so no new grant is needed. ✅
- **No startup assertion is violated.** `SdrRuleStartupAssertion.findStaleRules` requires each ruled
  type to have a `ResourceMetadata` that `isExported()`. `StockrecordViewRepository` carries a bare
  `@RepositoryRestResource(collectionResourceRel="stockrecordView", path="stockrecordView")` with no
  `exported=false`, and the detection strategy is `ANNOTATED`, so it is exported. The
  `SDR_WRITE_WITHDRAWN` entry works through `ExposureConfiguration` (HTTP-method disablement), which
  does **not** clear `ResourceMetadata.isExported()` — `StockView` is the standing proof of that.
  `findUnknownFunctions` reflects over `WmsConstants.FunctionEnum`'s declared `String` constants, and
  the constant is one of them. `findUnresolvableOverrides` is untouched (no override added). ✅
- **No test pins a count that this breaks.** `SdrRuleInventoryContextTest.enumeratesUnruledExportedTypes`
  deliberately logs rather than ratchets and asserts only `ruled` non-empty and `unruled` non-empty;
  `theAuthorizationGraphIsExported` uses `contains`/`doesNotContain` on five named types.
  `SdrRuleStartupCheckUnitTest` and `SdrRuleStartupAssertionUnitTest` operate on fixture maps built by
  `SdrFunctionRules.forTesting(...)`, not on production rules. `SdrFunctionGuardUnitTest:266` pins
  `UserGroup`'s set only. The one exact-set assertion that had to move —
  `SdrFunctionRulesUnitTest.ruledDomainTypes()` — was moved, in the same commit, correctly. ✅

**What breaks at `ENFORCE_RULED` that does not break at `OFF`:** a caller without
`WEB_UI_VIEW_STOCK_UNIT_RECORD` gets 403 on every `/v3/stockrecordView/**` read — collection, item, and
both searches (no per-search override, so the type rule applies to `findByKeyword` and
`findByKeywordAndClient` alike). At `OFF` the guard returns at `evaluate()`'s first branch before
`rules` is touched at all, so the entry is genuinely inert. At `SHADOW` it evaluates and emits
`would_deny` but allows. **Measured on prd (`wh01_hydra_v2`, PG 14.23, 2026-09-22), counting users
through `mywms_user → mywms_group_mywms_user → mywms_group_mywms_role → mywms_role_mywms_function →
mywms_function`:**

```
total users = 9 · holders = 7 · non-holders = anonymous, oms_integration
holders: admin, bcampbell, davido, jgero, panderson, thomasjr, tomh
```

That is the commit message's claim, reproduced digit-for-digit including which two users are excluded.
Both tenants are at `OFF` (`V2.2.23` seeds the sysprop as `OFF`; `SdrGuardMode.parse` maps absent /
unparseable to `OFF`), so the live effect today is nil. ✅

The one thing the javadoc asserts that I could not independently measure is "neither of which reads this
report". It is true by construction today — P2 created the route and P6 has not shipped a caller — but
see **L7**.

---

## 3. Q2 — did adding the rule invalidate a claim made elsewhere?

**The `36 - 8 = 28` arithmetic is right, and the line that carries it is already hedged correctly.**
`productionRules()` now holds eight `rules.put` calls (`User`, `UserFunction`, `UserGroup`,
`UserGroupUser`, `UserRole`, `Sysprop`, `Message`, `StockrecordView`). `StockrecordView` is a genuinely
new export, so the exported population goes 35 → 36 and the unruled count is unchanged at 28. The
comment's own instruction ("⚠ Re-derive rather than trusting this line") is the right posture and I did
not find a test that depends on the stated figure. ✅

**The `StockrecordViewHalContextTest` javadoc correction is true of that lane specifically**, and I
checked the one way it could have been true-by-accident. `BaseControllerIntegrationTest` is
`@AutoConfigureMockMvc` over a full `@SpringBootTest` context, i.e. `webAppContextSetup`, so the
interceptor chain **is** installed and `SdrFunctionGuard` really does run — the rule is not inert for the
trivial "no interceptor" reason that has bitten this repo before. It is inert for exactly the reason
stated: `evaluate()` short-circuits on `mode == OFF` before `rules.requiredFunctions(...)` is reached,
and nothing in the H2 lane sets `WMS2_SDR_READ_GUARD_MODE`. The pointer to
`SdrReadGateEnforcementContextTest` as the class that exercises an enforcing mode is correct; the class
exists. ✅

---

## 4. Q3 — the `EXEMPT_NON_TRANSACTIONAL` entry  → **M2**

**The entry itself is required and the exact-set assertion is satisfied.**
`nonTransactionalPropagationsMustBeDeclared` builds a `TreeSet` of every class/method whose
`@Transactional` `runsNonTransactionally(...)` and asserts `isEqualTo(EXEMPT_NON_TRANSACTIONAL)`.
`StockrecordViewRepositoryFilterIT:45` declares `@Transactional(propagation = Propagation.NOT_SUPPORTED)`
at class level, so without the entry the set inequality reds — which is exactly the surefire failure
`37564268` describes. Adding it was mandatory and is correct. ✅

**The stated justification is not.** You asked specifically whether the second reason is factually
right. It is a true PostgreSQL fact applied to a lane where it cannot bite:

- The general fact is true. PostgreSQL's `SET` (session form) issued inside a transaction block **is**
  reverted if that transaction rolls back. So the sentence is not wrong about PostgreSQL.
- But this test's `SET`s never enter a test-managed transaction. `filteredSearchKeepsAnIndexCondition`
  runs them through `jdbcTemplate.execute((ConnectionCallback) con -> …)`, and that `JdbcTemplate` is
  `PostgresTestSupportConfig`'s bean over a **`DriverManagerDataSource`**
  (`PostgresTestSupportConfig.java`, `jdbcTemplate()`). The test transaction, were the class not
  `NOT_SUPPORTED`, would be opened by `BasePostgresIntegrationTest`'s
  `@Transactional("tenantTransactionManager")` — a JPA manager over the tenant EMF, whose DataSource is
  the `tenantDynamicRoutingDataSource` mock, a **different bean**. `DataSourceUtils.getConnection` keys
  its `ConnectionHolder` lookup on the DataSource instance, finds nothing bound for the
  `DriverManagerDataSource`, and hands back a fresh autocommit connection outside the transaction.
  A rollback therefore has nothing to undo. **The `SET`s would survive the rollback and die with the
  connection — which is precisely what the comment asserts three lines further down, in the text L6
  added.** The two halves of the same comment now contradict each other.
- The **first** reason has the same shape: "the seed must be committed rather than parked in a
  test-managed transaction the JdbcTemplate *may not* share". It does not merely *may not* share — it
  categorically does not, for the reason L6 established. The `@BeforeEach` seed commits regardless of
  the class's propagation. This phrasing is inherited verbatim from the neighbouring
  `ReplenishorderLocationKeywordSearchIT` entry, so **L6's correction was not swept to its siblings** —
  the repo's standing "it is sibling copies, a token grep is not a sweep" pattern.

**Consequence:** the rail requires a *written reason*, so a false reason is a defect in the rail's own
artifact even though the code is right. I did not find a way for this to change behaviour: the class is
`NOT_SUPPORTED`, which is the honest declaration given the rows genuinely commit. The honest reason is
simpler than either of the two given — *the fixture commits whatever the class declares, because the
JdbcTemplate is on its own unpooled connection; `NOT_SUPPORTED` is what makes that visible to the rail
instead of hiding it behind a rollback that never covered those writes.*

Suggested rewrite (one paragraph replacing both reasons) is at §7.

---

## 5. Q4 — did any of the nine fixes introduce a defect or patch a symptom?

### 5.1 `keywordSql()` — **M1**, the one I would fix before merge

`37564268` rewrote the hand copy to carry `COALESCE`, with this claim:

> Kept operand-for-operand identical to the constant, `COALESCE` included, so the plan being measured is
> the plan the repository produces — an un-COALESCEd copy here would EXPLAIN a query this application
> never issues.

The two texts are now token-identical modulo `:keyword` → `$1`. But they are not the same *expression*,
and the difference is the one this ticket calls the whole defect. `keywordSql()` is fed to `PREPARE` as
**raw SQL**, where `CONCAT(a, ' ', b, …)` resolves to `pg_catalog.concat(VARIADIC "any")` — a function
that **ignores NULLs**. The repository's `KEYWORD_CLAUSE` is **JPQL**, and its own javadoc (corrected in
this very commit) says:

> Hibernate renders JPQL `CONCAT` as PostgreSQL's `||` rather than its `concat()` FUNCTION — the
> distinction is the whole defect, because `concat()` ignores NULLs and `||` propagates them

So the corrected copy still EXPLAINs a query the application never issues; it merely changed which
wrong one. Two follow-ons:

- The `COALESCE`s just added to `keywordSql()` are **semantically inert** in that copy — `concat()`
  already ignores NULLs. They change the `Filter` node's printed text and nothing else.
- The stated purpose of the fix ("so the plan being measured is the plan the repository produces") is
  not achieved.

**Does the test's verdict change?** No. Neither `concat(...) LIKE …` nor `a||' '||b… LIKE …` is
indexable, both degrade to a post-index `Filter`, and the three assertions (`Index Cond` present, no
`Seq Scan on stockrecord`, negative control derives no `Index Cond`) are unaffected. So this is a claim
defect with a latent measurement defect, not a green-that-should-be-red. It is Medium rather than Low
because the paragraph exists specifically to bound the hand-copy hazard and it overstates the fidelity
it achieved, and because this is the *second* hand-copy fidelity claim on this ticket to be wrong.

**Fix:** either write the operator form in the copy —
`(LOWER(COALESCE(p.activitycode,'')) || ' ' || LOWER(COALESCE(p.fromstoragelocation,'')) || …)` — or keep
`CONCAT` and say plainly that the copy measures a NULL-ignoring `concat()` while the application issues
`||`, that this is immaterial to plan *shape*, and that the NULL semantics are graded by
`nullInOneSearchedColumnDoesNotHideTheRow` instead. The first is strictly better and is a one-line edit.

### 5.2 `equalsAndHashCodeAreHandWrittenOnId` — real fix, one surviving mutant → **L1**, **L2**

The rewrite is correct and is a genuine improvement, not a symptom patch. The old assertion really was
unreachable (`getDeclaredMethod` throws rather than returning null). The reflection-built instances
**do** exercise the shipped `equals`: `entity()` is `Class.forName("net.aim_ai.wms.model.StockrecordView")`,
`withId` calls the real `setId(Long)` (declared at `StockrecordView.java:122`), and AssertJ's
`isEqualTo`/`isNotEqualTo` route through `org.assertj.core.util.Objects.areEqual`, which calls
`actual.equals(other)` with **no reference-equality short-circuit** — so the reflexivity assertion really
does kill `equals -> return false`. Nothing here passes vacuously.

Two gaps:

- **L1.** The ids are `42L` and `43L`. Both are inside `Long`'s valueOf cache band (−128..127), so
  `Long.valueOf(42) == Long.valueOf(42)` is `true`, and a mutant that degrades the body to
  `getId() == other.getId()` survives every one of the six assertions. This repo already carries a
  standing note on exactly this inversion. **Use ids outside the band** — `4_200L` / `4_300L` — and the
  mutant dies on `a1.isEqualTo(a2)`. One-character-class change, no new fixture.
- **L2.** The rewrite does not kill `hashCode -> return 0`: `assertThat(a1.hashCode()).isEqualTo(a2.hashCode())`
  is satisfied by a constant. It *cannot* be killed, because the shipped `getClass().hashCode()` is also
  a per-class constant — the two are behaviourally indistinguishable. The commit message lists
  `hashCode -> return 0` among the mutants the old assertion let through and then says the rewrite
  "kills the first of those", which is accurate but reads as if all three are now covered. Worth one
  clause saying that mutant is unkillable by design.

Also noted, not a finding: the `.as()` messages on the two `getDeclaredMethod` calls were dropped. They
were unreachable, so nothing is lost — a missing method now surfaces as `NoSuchMethodException` naming
the method, which is adequate.

### 5.3 The five-column `containsExactlyInAnyOrder` — real fix, not vacuous

`SEARCHED_COLUMN` is `LOWER\((?:COALESCE\()?p\.([A-Za-z_]+)`. It matches the five `LOWER(COALESCE(p.x`
operands and deliberately does **not** match `LOWER(concat('%', :keyword,'%'))`. Narrow the regex,
narrow either query, or drop a column, and the set loses a member and
`containsExactlyInAnyOrder("activitycode","fromstoragelocation","fromunitload","itemdata","operator")`
reds. Narrow it to nothing and it reds on an empty set. **It cannot pass vacuously**, which is exactly
what the old `isNotEmpty()` could. The `filteredColumns.isEqualTo(unfilteredColumns)` and the
`startsWith(unfilteredWhere)` structural assertion remain as the cross-checks. ✅

One property worth recording so nobody mistakes it for coverage: the regex matches with *or* without
`COALESCE`, so this pin cannot see a dropped `COALESCE`. That is correct and already documented —
`FilterIT.nullInOneSearchedColumnDoesNotHideTheRow` is the instrument for that, and it is the only one
that can be, since the constant is shared.

### 5.4 The HAL keyword scoping — real fix, with a bonus the message does not claim

`keyword=SBDEV3410HAL` matches the fixture's own `activitycode` (`seedOneRow()` sets exactly that
string), `activitycode` is one of the five searched columns, and `LOWER` on both sides makes the case
irrelevant. With `size=1` the page is now exact by construction. ✅

Unclaimed bonus: the fixture leaves `fromunitload` **null**, and the old `keyword=` took the
`or :keyword = ''` escape arm, so the H2 lane never evaluated the CONCAT at all. It now does — which
makes this test a second, independent detector for a dropped `COALESCE` (H2's `||` propagates NULL, so
the row would vanish and `$._embedded.stockrecordView[0]` would not resolve). Worth saying out loud,
because it also means **this test now has a dependency it did not have before**: revert the COALESCE and
this reds with a message about `exposeIdsFor`. That is the right direction, but the javadoc should say
so.

### 5.5 The remaining five

- **L4 (`exposeIdsFor` move)** — see §6.
- **L5 (index message)** — verified true. `index_stockrecord_client_id` is a real pre-existing
  single-column btree on `stockrecord(client_id)`, created by `V2.2.00__base_v2_schema.sql:4296`
  (and again by `v1-to-v2-onboarding/schema/V1.0.05__wms_indexes.sql:1`), and
  `index_stockrecord_client_created` is `V2.2.33__stockrecord_view.sql:149`. Either yields
  `Index Cond: (client_id = $2)`, so the old message really did claim a guard the assertion does not
  provide. The cited fallback pin exists and is correctly named:
  `StockrecordViewSchemaIT.index_shouldExistOnClientIdAndCreated`, line 585, `@DisplayName("AC-P1d: …")`.
  Leaving the assertion unchanged is the right call. ✅
- **L8 (schema-IT blind spot direction)** — verified true. The bijection is exact: the entity declares
  **28** non-static fields and the view projects **28** columns (`sr.id` + 22 more `sr.*` +
  `item_id`, `item_name`, `cl_nr`, `cl_name`). ✅
- **L7 / L9-forname, not taken** — both deferrals are reasonable and both are argued rather than
  dropped. No objection.
- **The 1ec4f271 commit-message correction** ("every kill attributable to exactly one assertion" was
  wrong for two of five rows) — correct, and the table in
  `StockrecordViewRepositoryQueryShapeUnitTest:180-195` does show it.

---

## 6. Q5 — are the three replacement claims true?

| Claim | Verdict |
|---|---|
| **L2** "COALESCE on a NOT NULL column is a no-op the planner discards" was false; the node survives into the `Filter`; PostgreSQL folds a COALESCE only when an argument is a non-null **constant** | **Substance TRUE, reproduced. Version citation FALSE → L3.** |
| **L6** "the connection goes back to a shared pool" was false; it is a `DriverManagerDataSource` | **TRUE.** |
| **L1** the hashCode rationale (the `null→Long` lifecycle argument) cannot apply to an assigned `@Id` | **TRUE.** |

**L2, measured myself on `wh01_hydra_v2` (2026-09-22), both halves:**

```sql
EXPLAIN (COSTS OFF) SELECT p.id FROM public.stockrecord p
WHERE lower(coalesce(p.activitycode, '')) LIKE '%zzq%';
-- Seq Scan on stockrecord p
--   Filter: (lower((COALESCE(activitycode, ''::character varying))::text) ~~ '%zzq%'::text)

EXPLAIN (COSTS OFF) SELECT p.id FROM public.stockrecord p
WHERE p.activitycode = COALESCE('zzq'::varchar, 'other'::varchar);
-- Seq Scan on stockrecord p
--   Filter: ((activitycode)::text = 'zzq'::text)
```

`activitycode` is `is_nullable = NO` on that database. The COALESCE survives on a column argument and is
folded away on a constant argument — both halves of the replacement confirmed, with a positive control.

**L3 — the version is wrong.** `SELECT version()` on `wh01_hydra_v2` returns
`PostgreSQL 14.23 on x86_64-pc-linux-musl` (`current_setting('server_version')` = `14.23`,
`current_database()` = `wh01_hydra_v2`). The javadoc says "measured false on PG 16.10 (`wh01_hydra_v2`)".
The pairing is impossible. It matters because planner behaviour is version-dependent and the whole point
of the sentence is to let the next reader re-check it — on the wrong engine. It also sits three
paragraphs from a javadoc that correctly says "Measured 2026-09-21 in a PostgreSQL 14 container", so the
file now names two different engines for the same finding. **Change `16.10` to `14.23`** (the substance
needs no other change — I verified it holds on 14.23).

**L6 — true, and it is the load-bearing fact.** `PostgresTestSupportConfig.jdbcTemplate()` builds a
`new JdbcTemplate(new DriverManagerDataSource(container url, user, pass))`. `DriverManagerDataSource`
opens a fresh physical connection per `getConnection()` and closes it on release — no pooling, so the
`SET`s cannot leak. The reset is correctly kept as defence. (This same fact is what makes M2's
transaction claim impossible; see §4.)

**L1 — true.** `StockrecordView.java:71-72` is a bare `@Id private Long id;` with no `@GeneratedValue`
(the class javadoc at line 33 explicitly records that it does *not* carry the
`@GeneratedValue(SEQUENCE, generator="entity_gen")`/`@Version` shape of `AbstractBaseEntity`), so the id
is assigned on every path. The `O(n²)` consequence is real: `getClass().hashCode()` is one value for
every instance of the class.

---

## 7. Q6 — contradictions with the plan, and what an earlier lane would have flagged

**The §3.5 deviation is properly recorded.** The plan carries a supersede marker at §3.5
("⚠ **SUPERSEDED 2026-09-21 — P2 DID add the rule. Do not restore this decision; see §9B**"), the §5.2
checklist item is struck through with the reversal noted, and §9B records the decision with the
reasoning. That is the right treatment and I have no objection to the deviation itself.

**L6 — three sibling statements were not swept.** The same "it is sibling copies" pattern that produced
this ticket's earlier corrections. All three still assert the withdrawn decision as present fact:

1. The risk table — `| An SdrFunctionRules entry for StockrecordView | Adds no new enforcement gap …
   Closing the gap is separate scope on the SBDEV-3222/3183 programme, needing shadow-mode measurement. |`
2. The change summary — ``` `SdrFunctionRules` — 7 rules before, 7 after, and **no new enforcement gap**
   … ``` — the arithmetic is now simply wrong (7 before, **8** after), and it is the same figure
   `SdrFunctionGuard` was edited to correct.
3. The Micrometer row — "`wms2.authz.sdr.unruled{domainType=...}` gains a label value **because**
   `StockrecordView` is exported **without** an `SdrFunctionRules` entry — expected, not a regression".
   A ruled type never reaches that counter. The §5.2 checklist already says this note "is therefore
   **inverted**" but the source row was left standing.

**What the earlier lanes would have flagged had they seen the delta.** The code-review lane's own M2
finding was *"a control on a literal cannot see a narrowed pattern"*; M1 above is the same failure one
level up — a control on the **text** of a hand copy cannot see that the copy is parsed by a different
grammar. And the security lane, having established that the guard short-circuits at `OFF`, would have
asked the `oms_integration` question in L7 rather than accepting "neither of which reads this report" as
settled.

**Suggested replacement for the EXEMPT entry's two reasons (M2)** — keeps everything true:

> Non-transactional because the fixture commits whatever this class declares: it is seeded through
> `PostgresTestSupportConfig`'s `JdbcTemplate`, which sits on its own `DriverManagerDataSource` and is
> therefore never enlisted in the `tenantTransactionManager` transaction `BasePostgresIntegrationTest`
> would otherwise open. `NOT_SUPPORTED` is what makes that visible to this rail instead of hiding it
> behind a rollback that never covered those writes. `filteredSearchKeepsAnIndexCondition` additionally
> needs session-level GUCs (`plan_cache_mode = force_generic_plan`, `enable_seqscan = off`) plus
> `PREPARE`/`EXECUTE`; those ride the same unpooled connection and die with it, and the
> `DEALLOCATE ALL` / `RESET ALL` in the `finally` is defence for the day that bean is repointed at a
> pool. Everything under test is read-only: two `@Query` searches and an EXPLAIN.

---

## 8. What I could not verify — exact commands

No test was executed in this lane. `936a4cf4` changes five test classes and one production javadoc-only
file plus one production list reorder; `37564268`'s arch-test entry is the one that turned surefire
green again. **Nothing here has been observed passing.** Two things specifically at risk:

- `StockrecordViewHalContextTest.idIsInTheHalBody` now depends on the H2 lane resolving
  `CONCAT(LOWER(COALESCE(...)), …) LIKE '%sbdev3410hal%'` against a row with a NULL `fromunitload`. It
  reads correct to me but it is a behaviour change from the previous escape-arm path.
- `StockrecordViewEntityContractUnitTest` gained reflection-constructed instances.

Please run, from the worktree, and report back:

```bash
# 1. full surefire, clean — `mvn test` without clean runs deleted test classes on this repo
cd /Users/np1076/dev/spk/owl/.claude/worktrees/wms2-api/SBDEV-3410 && mvn -o clean test

# 2. if you want the fast targeted pass first (comma separator, never '+')
cd /Users/np1076/dev/spk/owl/.claude/worktrees/wms2-api/SBDEV-3410 && mvn -o clean test \
  -Dtest='StockrecordViewEntityContractUnitTest,StockrecordViewRepositoryQueryShapeUnitTest,SdrFunctionRulesUnitTest,TestClassTransactionManagerArchTest,StockrecordViewSdrRegistrationUnitTest,StockrecordViewHalContextTest,SdrWriteWithdrawalContextTest,SdrRuleInventoryContextTest' \
  -Dsurefire.failIfNoSpecifiedTests=false

# 3. the Testcontainers lane for the two ITs the delta touches
cd /Users/np1076/dev/spk/owl/.claude/worktrees/wms2-api/SBDEV-3410 && mvn -o clean verify \
  -Dit.test='StockrecordViewRepositoryFilterIT,StockrecordViewSchemaIT' \
  -Dtest=ZzzNone -Dsurefire.failIfNoSpecifiedTests=false
```

Compare (1) against the known baseline rather than against zero. If L1 is taken, re-run (2) after
changing the two ids and confirm it still passes; then, to prove the mutant is now killed, temporarily
change the entity's `equals` to `getId() == other.getId()` and confirm **red** (it is currently green
against that mutant).

---

## 9. What is verified good — recorded so it is not re-derived

- Rule wiring, `ordered(...)`, both startup assertions, no count-pin collateral (§2).
- Blast radius reproduced exactly on prd: 9 users / 7 holders / `anonymous` + `oms_integration` (§2).
- `36 - 8 = 28` consistent, and the line correctly tells the reader to re-derive (§3).
- `StockrecordViewHalContextTest`'s "inert at OFF" claim true of that lane, interceptor installed and all (§3).
- The exact-set arch assertion is satisfied by the new entry; the entry was mandatory (§4).
- L5 index claim, L6 DataSource claim, L8 28/28 bijection, L1 assigned-`@Id` claim: all true (§5, §6).
- L2's substance reproduced with a positive control on PG 14.23 (§6).
- Every cited symbol exists: `ReportController:249`, `OutboxClaimExplainIT`,
  `SdrReadGateEnforcementContextTest`, `StockrecordViewSchemaIT.index_shouldExistOnClientIdAndCreated`,
  `index_stockrecord_client_id`, `index_stockrecord_client_created`.
- The FilterIT committed-id inventory is otherwise accurate (clients …410/411/412/413, itemunit …400,
  itemdata …401/402, stockrecord …420/421/422/430/431/440/450 = the 7 the `wipe()` deletes), the band
  `9913400-9913450` is used by no other test class (`grep` over `src/test`: only this class and the arch
  test mention it), and the client-0 treatment is exactly as described — the wipe deletes fixture rows by
  id and the four fixture clients, never client 0.
