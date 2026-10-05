---
title: SBDEV-3410 P2 — plan-conformance verification
ticket: SBDEV-3410
phase: P2
commit: 1ec4f271f4b7da44f7901acae911f9e4b176e1fe
branch: feature/SBDEV-3410-p2-stockrecord-view-entity-sdr (off origin/develop @ f2ee75f1)
worktree: /Users/np1076/dev/spk/owl/.claude/worktrees/wms2-api/SBDEV-3410
lane: conformance (read-only; no maven executed)
date: 2026-09-21
verdict: PASS with documented exceptions
---

# SBDEV-3410 P2 — conformance verdict

**Question graded:** did P2 build exactly what the plan specifies, no less and no more? Correctness and
security are other lanes' business.

**Method:** every row below is graded against the **committed blob** at `1ec4f271`
(`git show 1ec4f271:<path>`), not against the worktree. This matters — see *Tree hygiene* at the end.

**Nothing was executed.** No `mvn`, no test run, no DB query. Every row whose truth depends on
execution is marked **NOT VERIFIABLE HERE** and named explicitly in §6.

---

## 1. §5.2 P2 — the seven authoritative checkbox items

| # | P2 item | Verdict | Proof |
|---|---|---|---|
| 1 | `StockrecordView.java` per §3.3 — no `AbstractBaseEntity`, explicit `@Column` on every camelCase field, hand-written `equals`/`hashCode` on `id`, `created`/`modified` re-declared as `LocalDateTime` | **VERIFIED** | `src/main/java/net/aim_ai/wms/model/StockrecordView.java`. `public class StockrecordView {` — no `extends` (:67). `private LocalDateTime created; private LocalDateTime modified;` (:73-74). `equals` on `getId()` with the `instanceof StockrecordView other` pattern (:343-347), `hashCode` = `getClass().hashCode()` (:353). Six camelCase fields, six `@Column(name=…)`: `entity_lock` :77, `client_id` :96, `item_id` :106, `item_name` :109, `cl_nr` :112, `cl_name` :115 — exactly the six §3.3 rule 3 enumerates. Detail in §2 |
| 2 | `StockrecordViewRepository.java` per §3.4 — `ReadOnlyPagingAndSortingRepository`, two searches, plain equality with no `OR` arms, all three `findAll` suppressed, ONE `KEYWORD_CLAUSE` concatenated into both | **VERIFIED** | `src/main/java/net/aim_ai/wms/repo/jpa/StockrecordViewRepository.java`. Detail in §3 |
| 3 | `RestConfiguration`: add `StockrecordView.class` to `exposeIdsFor(...)` **and** to `SDR_WRITE_WITHDRAWN` | **VERIFIED** | `RestConfiguration.java:538` sits inside `SDR_WRITE_WITHDRAWN` (array opens :441, closes :547). `:890` sits inside the `config.exposeIdsFor(` call (opens :880, closes `ViewWarehouseLocationReport.class);` :891). Both present, one diff hunk each |
| 4 | `SdrWriteWithdrawalContextTest`: add the 50th name, bump `hasSize(49)` → `50`, correct the "IDENTICAL — 49 names" javadoc | **VERIFIED** | `"StockrecordView",` added to `WITHDRAWN` at :159; `assertThat(WITHDRAWN).hasSize(50);` at :211; javadoc `49 → 50` in both places, plus the `49 withdrawn + 9 kept = 58` arithmetic corrected to `50 + 9 = 59`. All three sub-items done, which §3.5 says nothing else in the suite would catch |
| 5 | `StockrecordViewRepositoryFilterIT`, `StockrecordViewHalContextTest`, `StockrecordViewRepositoryQueryShapeUnitTest` written first and failing | **PARTIAL — present, ordering NOT VERIFIABLE HERE** | All three exist: `src/test/java/net/aim_ai/wms/integration/repository/StockrecordViewRepositoryFilterIT.java`, `src/test/java/net/aim_ai/wms/security/StockrecordViewHalContextTest.java`, `src/test/java/net/aim_ai/wms/unit/repo/StockrecordViewRepositoryQueryShapeUnitTest.java`. **"Written first" cannot be verified from git**: the branch has exactly one commit (`git reflog` — `@{1}` is the branch creation from `origin/develop`, `@{0}` is `1ec4f271`), so tests and implementation landed together. There is no P2 TDD-gate comment on the ticket either (§6). *Circumstantial support, not proof:* the two reflection-only classes carry `Class.forName` + an `AssertionError` reading *"does not exist. SBDEV-3410 P2 adds it (plan §3.3/§3.4)"* (QueryShape :79-86, SchemaIT :375-381), a shape that only makes sense if written before the type existed. The HalContextTest seeds and **flushes** through `@PersistenceContext(unitName = "tenant")` (:66-89) exactly as the plan's ⚠ requires |
| 6 | Mutation checks, each with an attributable kill; **not** "drop a `@Column`"; `filteredSearchKeepsAnIndexCondition` is **not** the OR-arm killer | **PARTIAL — recorded and routed correctly, execution NOT VERIFIABLE HERE** | Five mutants named in the commit message with one killing assertion each. Both plan-mandated routings are honoured in writing: the OR-arm mutant is routed to `queryShapeForbidsADisjunction` (QueryShape :178-187, and the IT's own javadoc :315-319 disclaims itself), and no mutant is "drop a `@Column`". One mutant is **outside** the plan's list — "drop one `COALESCE`" — which is correct, because it belongs to the approved deviation (§4). I did not re-run any mutation |
| 7 | Do **not** add an `SdrFunctionRules` entry; note the resulting `wms2.authz.sdr.unruled` label on the ticket | **PARTIAL** | *Code half VERIFIED:* `SdrFunctionRules.java` is not in the commit's file list; it still holds `7` `rules.put(` calls; `grep -rn StockrecordView src/main/java` returns exactly two hits, both in `RestConfiguration`. *Ticket half MISSING at time of writing:* `SBDEV-3410` has 8 comments, the newest being the P1-merged note (2026-09-19); there is no P2 comment and so no record of the new `unruled` label value. Expected if the P2 ticket comment is still pending behind these lanes — but it is an unticked P2 item, not a discharged one |

---

## 2. §3.3 — the entity's four rules

| Rule | Verdict | Proof |
|---|---|---|
| 1. `@Id` is `sr.id`, the real PK — not a synthetic `row_id` | **VERIFIED** | `@Id private Long id;` (:71-72). No `row_number`, no `@Column(name="row_id")`. The javadoc states the *condition* (both joins non-multiplying ⇐ `itemdata`'s `UNIQUE (client_id, item_nr)`) and the symptom if absent (deduplicated `content` vs inflated `totalElements`) — §3.3's "state the condition, not just the conclusion" instruction, followed |
| 2. Does NOT extend `AbstractBaseEntity`; `created`/`modified` re-declared `LocalDateTime`; hand-written `equals`/`hashCode` | **VERIFIED** | No `extends` (:67). No `@Version` **annotation** anywhere in the file (the two `@Version` hits are javadoc prose at :33 and :35); `version` is a plain `Integer` (:75), which §3.3 rule 4 requires to be mapped. `equals` matches the plan's prescribed shape verbatim. `hashCode` returning `getClass().hashCode()` is not spelled out in §3.3 but matches both cited precedents byte-for-byte — `StockView.java:139-141` and `AbstractBaseEntity.java:78-82`, same comment reasoning |
| 3. Every camelCase field carries an explicit `@Column(name = …)` | **VERIFIED** | Six camelCase fields, six annotations (listed in §1 row 1). Every remaining field is all-lowercase and identity-resolves, matching how `Stockrecord` itself works. Reconciled against the real view by `StockrecordViewSchemaIT.everyMappedColumnResolves` (§5) |
| 4. Field names match the UI's nine sort keys; `id` and `version` also mapped | **VERIFIED** | All nine present as fields: `created` :73, `type` :94, `activitycode` :79, `itemdata` :87, `fromstoragelocation` :85, `tostoragelocation` :92, `amount` :81, `amountstock` :83, `operator` :88. Plus `id` :72 and `version` :75 |

**Extra not asked for (benign, precedented):** four `@Column(columnDefinition = "numeric(17,4)")` on
`amount`, `amountstock`, `reservedamountchange`, `reservedamountstock` (:80, :82, :98, :100). §3.3 asks
only for `@Column(name=…)` on camelCase fields. These carry no `name`, so they do not change column
resolution; they shape DDL in the H2 `create-drop` lane. Precedent is explicitly recorded in §7.5 row 4
(`StockView.transfer` is `@Column(columnDefinition = "numeric")` with no `name`). Not a finding.

---

## 3. §3.4 — the repository

| Spec | Verdict | Proof |
|---|---|---|
| `@RepositoryRestResource(collectionResourceRel = "stockrecordView", path = "stockrecordView")` | **VERIFIED** | :56 — both attributes exactly as specified |
| extends `ReadOnlyPagingAndSortingRepository<StockrecordView, Long>` | **VERIFIED** | :57 |
| **Two** searches, not one three-valued one | **VERIFIED** | `findByKeyword(String, Pageable)` :113 and `findByKeywordAndClient(String, Long, Pageable)` :133-136. No third. `findByKeyword` carries **no** `clientId` parameter, per §3.4 |
| `p.clientId = :clientId` is a **plain equality**, no `OR` arms | **VERIFIED** | :131 — `@Query("SELECT p FROM StockrecordView p WHERE" + KEYWORD_CLAUSE + " AND p.clientId = :clientId")`. No `IS NULL`, no `= -1` |
| **ONE** shared `KEYWORD_CLAUSE`, concatenated into both | **VERIFIED** | `String KEYWORD_CLAUSE` :99-102, referenced at :112 and :131. Both are compile-time constant expressions, so reflection sees the folded text — the property §3.4 relies on |
| Same five searched columns, in the same order | **VERIFIED** | `activitycode`, `fromstoragelocation`, `fromunitload`, `itemdata`, `operator` — the plan's five, same order |
| `or :keyword = ''` escape carried from the `StockView` precedent | **VERIFIED** | :102, trailing the `LIKE`. `LOWER(concat('%', :keyword,'%'))` preserved verbatim, spacing included |
| All three `findAll` overloads `@Override @RestResource(exported = false)` | **VERIFIED** | `findAll(Pageable)` :148-150, `findAll(Sort)` :152-154, `findAll()` :156-158. Return types match the plan (`Page`, `Iterable`, `Iterable`) |
| `p.clNr = :clientNumber` **rejected** (Q1) | **VERIFIED** | No `clNr` predicate anywhere in the file; `clNr` appears only as a projected entity field |
| Rationale recorded, not merely obeyed | **VERIFIED** | The class javadoc :14-55 carries the generic-plan measurement, the pgjdbc `prepareThreshold` mechanism, the `FixLocationAssignmentRepository` precedent and the caller-side sentinel fold; the `findByKeywordAndClient` javadoc :115-131 carries the `StockunitRepository.getDetailViewByKeyword` divergence and names which test kills the fold-it-back mutant |

**One addition beyond the plan's javadoc:** :38-40 records a *post-merge* re-measurement on the real
index (2026-09-19, `Index Cond: (client_id = $2)`, 0.595 ms vs 2,865 ms). That figure matches the P1
ClickUp comment of 2026-09-19 exactly. It strengthens the claim rather than replacing the plan's
`dev_wh01_om1` measurement, which is still present. Not a finding.

---

## 4. The one approved deviation — `COALESCE` on all five operands

Asked to verify the deviation is **correctly and honestly documented**, in three places, with reasoning
matching the code. All three: **VERIFIED**.

| Where | Verdict | What it says |
|---|---|---|
| Repository javadoc | **VERIFIED** | `StockrecordViewRepository.java:75-92`. Labels itself *"a deliberate, approved deviation from plan §3.4"*, names the plan's original instruction (carry the clause verbatim from `StockView`), gives the mechanism (Hibernate renders JPQL `CONCAT` as `||`; `NULL || anything` is NULL), the symptom (*"there when you browse, gone the moment you type"*), the measurement date and lane (2026-09-21, PostgreSQL 14 container, `StockrecordViewRepositoryFilterIT`), the two nullable columns, the inheritance disclaimer, Nam's approval date, the scope of the fix, and the `FlowbinMonitorViewRepository` precedent. :90-92 states the all-five rule and *why* a 2-of-5 exception is refused |
| The test that grades it | **VERIFIED** | `StockrecordViewRepositoryFilterIT.nullInOneSearchedColumnDoesNotHideTheRow` :201-241. Same reasoning, plus the `V2.2.00` line citation and a mutation note. Two assertions: a **control** on the empty keyword (which passed pre-fix, so it proves the row and its client exist and a red below is the keyword path) and the real assertion on the keyword path. The fixture is purpose-built: `SR_NULL_UL` is seeded with `fromUnitload = null` (:109) under its own client `CLIENT_NULLCOL` (:53) *"so it perturbs no other count"* |
| Commit message | **VERIFIED** | Paragraph 4 of `1ec4f271`. Same facts, same approval attribution, same scoping, same precedent. Also routes the "drop one `COALESCE`" mutant to this IT with the reason no text assertion can see it (the constant is shared, so the mutation changes both queries identically) |

**Does the stated reasoning match the code?** Yes, and the load-bearing claim checks out independently:

- **Code:** all five operands wrapped — `git show 1ec4f271:…/StockrecordViewRepository.java` :100-102 is
  `LOWER(COALESCE(p.activitycode, ''))`, `LOWER(COALESCE(p.fromstoragelocation, ''))`,
  `LOWER(COALESCE(p.fromunitload, ''))`, `LOWER(COALESCE(p.itemdata, ''))`,
  `LOWER(COALESCE(p.operator, ''))`. No operand is bare.
- **The "exactly two are nullable" claim is true, and the line citation is exact.** From
  `db/migration/V2.2.00__base_v2_schema.sql`, `CREATE TABLE public.stockrecord` opens at :2166;
  within it `activitycode`, `fromstoragelocation`, `operator` are `NOT NULL`, while `fromunitload`
  (:2178) and `itemdata` (:2179) are not — the FilterIT's *"V2.2.00 lines 2178–2179"* is right to the
  line. No later `V2.2.x` migration issues an `ALTER TABLE … stockrecord` touching nullability
  (swept every `V2.2.*.sql` naming `stockrecord`).
- **Blast radius honestly bounded.** The legacy `StockrecordRepository.findByKeyword` is left alone, as
  the deviation claims; `SdrFunctionRules` is untouched; no other production file is edited.

**One documentation inaccuracy the deviation created, in a fourth place nobody updated.**
`StockrecordViewRepositoryFilterIT.keywordSql()` (:380-385) is described by its own comment as
*"the keyword arm, matching the shape of `StockrecordViewRepository.KEYWORD_CLAUSE`"* — and it is the
**un-COALESCEd** text. The hand-copy itself is plan-sanctioned (§7.2 requires this test to hold its own
statement, per the `OutboxClaimExplainIT` precedent, and it is precisely why it is *not* the OR-arm
killer). What is now false is the phrase *"matching the shape of"*: post-deviation the EXPLAIN probe
plans a predicate production no longer renders. The plan's reason for keeping this test —
*"that a plain equality **is** index-backed under a generic plan"* — is unaffected, since `COALESCE` on
the keyword arm cannot change the `client_id` index qual. **Severity: documentation only.** Fix is one
comment (*"deliberately the pre-deviation text; this probe grades the `client_id` qual, not the keyword
arm"*), or add the `COALESCE`s to keep the two in step. Flagged because the lead asked whether the
deviation is honestly documented everywhere, and this is the one spot where it is not.

---

## 5. §3.5 — SDR registration

| Item | Verdict | Proof |
|---|---|---|
| `exposeIdsFor` gains `StockrecordView.class` | **VERIFIED** | `RestConfiguration.java:890`, inside the call opening at :880 |
| `SDR_WRITE_WITHDRAWN` gains it — required, not parity | **VERIFIED** | `:538`, inside the array `:441-547`, with a 4-line comment restating the *required-not-parity* reasoning (`ReadOnlyPagingAndSortingRepository` suppresses exactly `save`/`saveAll`, `CrudRepository` keeps the delete verbs, so `DELETE /api/stockrecordView/{id}` would route at a VIEW) |
| `SdrWriteWithdrawalContextTest` pin moves in the **same commit** | **VERIFIED** | Same commit `1ec4f271`; name, size and javadoc all moved together |
| **No** `SdrFunctionRules` entry | **VERIFIED** | File absent from the commit; still 7 `rules.put(` calls; `StockrecordView` appears nowhere in it |
| §7.2 row 2 / §3.3 rule 3 — `everyMappedColumnResolves` reconciles the entity against the migrated view | **VERIFIED** | `StockrecordViewSchemaIT.everyMappedColumnResolves` :403-470 (new in this commit; the class itself is P1's and exists at `origin/develop`). Applies the **runtime** naming rule (`@Column(name)` when present, field name verbatim otherwise), carries a positive control on `columnsOf(VIEW)` being non-empty and a vacuity guard on the field list being non-empty, and names its own blind spot (names only — not type, order or nullability). Not enumerated in P2's checkbox list, but mandated by §7.2 and §3.3 rule 3, and it could not have been written before the entity existed |

---

## 6. §7.2 / §7.3 — the test classes P2 was supposed to produce

P3–P6 rows excluded per the scope boundary, so `exportPredicateRendersOnPostgres`,
`unfilteredExportRouteIsUnchanged`, and every `ReportController` / `ReportService` /
`StockrecordService` / `ClientController` / `Sbdev3017TrancheGateContextTest` / jest row is **out of
scope and not counted as a gap.**

### §7.2 rows in P2's scope

| Row | Verdict | Proof |
|---|---|---|
| `StockrecordViewSchemaIT.everyMappedColumnResolves` | **VERIFIED** | :403-470 |
| `StockrecordViewSchemaIT.everyUiSortKeyResolves` | **VERIFIED, RELOCATED** | The assertion exists — `StockrecordViewEntityContractUnitTest.everyUiSortKeyResolvesToAField` :191, over a single source-of-truth list `UI_SORT_KEYS` :71 (the plan's *"not nine hand-written cases"* requirement, honoured). It is in a **surefire unit class**, not in `StockrecordViewSchemaIT` where §7.2 assigns it. Substantively equal or better (no container needed; the property is reflection over the entity, not over `information_schema`), but it is a location deviation the plan does not authorise and the plan text now points at the wrong class |
| `StockrecordViewRepositoryFilterIT.filterReturnsOnlySelectedShipper` | **VERIFIED** | :166-187. Rows **and** `totalElements` (3 and 2), plus an unfiltered control asserting all seven fixture rows first, so the filter assertions cannot pass for the wrong reason |
| `…clientIdZeroIsARealShipper` | **VERIFIED** | :245-260. `SYSTEM_CLIENT = 0L`, asserted **by id** (`containsExactly(SR_SYS)`), `totalElements == 1`, plus an `allSatisfy` on `getClientId()` |
| `…keywordAndFilterAndSortAndPageCompose` | **VERIFIED** | :264-293. All four named AC-4 combinations (a) filter alone (b) filter+keyword (c) filter+`sort=created,asc` (d) page 2 disjoint from page 1 — with `totalElements` and `totalPages` on (d) |
| `…filteredSearchKeepsAnIndexCondition` | **VERIFIED (as specified)** | :331-378. `plan_cache_mode = force_generic_plan` + `SET enable_seqscan = off` as the control; asserts `Index Cond` present and `Seq Scan on stockrecord` absent on the plain form; and carries the three-arm `OR` form as an explicit **negative control** in the same session, asserting it derives **no** `Index Cond` — which is the discrimination proof §7.2 demands. `RESET ALL` + `DEALLOCATE ALL` in a `finally`, so the pooled connection cannot leak `enable_seqscan` into later tests |
| `…clientWithNoRowsReturnsAnEmptyPage` | **VERIFIED** | :295-307. `CLIENT_EMPTY` committed with no `stockrecord` rows; `totalElements` and `totalPages` both zero |
| Repository-tests-COMMIT discipline (the §7.2 ⚠) | **VERIFIED** | `@Transactional(propagation = Propagation.NOT_SUPPORTED)` :45, `wipe()` in both `@BeforeEach` :90 and `@AfterEach` :113, every assertion keyed on fixture ids, no `isEmpty()`/`hasSize()` over a shared table except the one scoped to `CLIENT_EMPTY`'s own id list (:301, explicitly justified in a comment). `wipe()` is id-scoped so it cannot delete the `V2.2.00`-seeded System-Client row |

### §7.3 rows in P2's scope

| Row | Verdict | Proof |
|---|---|---|
| `StockrecordViewHalContextTest.idIsInTheHalBody` | **VERIFIED** | `src/test/java/net/aim_ai/wms/security/StockrecordViewHalContextTest.java`. `extends BaseControllerIntegrationTest`, in the package §7.3 names. Seeds one row through `@PersistenceContext(unitName = "tenant")` and **flushes** (:66, :88-89) — both ⚠s honoured, including the bare-`@PersistenceContext`-is-landlord trap. Asserts `$._embedded.stockrecordView[0].id` **by value** (:100), not `status().isOk()`, which §7.3 forbids as a repair. Adds `$._embedded.stockrecordView` `isArray()` and `[0].itemName` |
| `StockrecordViewRepositoryQueryShapeUnitTest.queryShapeForbidsADisjunction` | **VERIFIED** | :155-191, in `src/test/java/net/aim_ai/wms/unit/repo/` as specified. Implements the plan's exact three-line recipe: whitespace-normalise, `contains("AND p.clientId = :clientId")`, then slice **at the conjunct**, upper-case the tail, `doesNotContain(" OR ")`. The ⚠ about a whole-string scan being vacuous-or-wrong is restated in a comment (:170-174), and the seven-mutant measurement that validated the slicing logic is recorded (:176-187) |
| `SdrWriteWithdrawalContextTest` extension — `hasSize(50)` + the set still matching `RestConfiguration` | **VERIFIED** | :159, :211 |

### Not verifiable in this lane

1. **Whether any of these tests actually pass.** No `mvn` was run (hard constraint). Every row above
   grades the *source* — the assertion exists, is not vacuous by construction, and asserts the property
   the plan names.
2. **Whether the tests failed first, for the right reason** (P2 item 5) — single commit, no P2 TDD-gate
   ticket comment.
3. **Whether the five mutants were actually applied and observed red** (P2 item 6) — recorded in the
   commit message, not reproducible from source.
4. **Full-suite comparison against the known baseline** — the lead owns this.
5. **The DB-side floor item** (one query confirming the symptom) for P2 specifically — P1's ClickUp
   comments carry the `dev_wh01_om1` and container measurements this phase's design rests on; nothing
   new was needed or claimed here.

---

## 7. §7.5 — v2-only constraint rows that apply to P2

| # | Row | Verdict | Proof |
|---|---|---|---|
| 1 | Jakarta namespace, never `javax` | **VERIFIED** | `StockrecordView.java:6-9` — `jakarta.persistence.{Column,Entity,Id,Table}`. `grep "javax\."` over both new main files → no hits. The new/edited tests use `jakarta.persistence.*` too (SchemaIT `Column`/`Transient`, HalContextTest `EntityManager`/`PersistenceContext`) |
| 2 | OSIV off — unaffected | **VERIFIED** | The entity declares no association, no `@ManyToOne`/`@OneToMany`, no `FetchType`. Flat view entity, fully materialised by the repository |
| 3 | No `@Transactional` added in production code | **VERIFIED** | `grep "@Transactional"` over `StockrecordView.java` + `StockrecordViewRepository.java` → no hits. `RestConfiguration`'s two edits are list entries. (The FilterIT's `@Transactional(NOT_SUPPORTED)` is test-side fixture discipline, which §7.2 requires) |
| 4 | Hibernate naming strategy — explicit `@Column(name=…)` on every camelCase field | **VERIFIED** | §2 rule 3. Picked up automatically by the repo-wide `EntityColumnNameResolutionArchTest` (surefire, imports `net.aim_ai.wms.model` wholesale) and reconciled by `everyMappedColumnResolves` |
| 5 | SDR registration — `exposeIdsFor` **and** `SDR_WRITE_WITHDRAWN`, `ReadOnlyPagingAndSortingRepository`, all three `findAll` suppressed | **VERIFIED** | §5 and §3 |
| 6 | No new cache | **VERIFIED** | `grep "@Cacheable\|@CacheEvict"` over both new main files → no hits. `CacheConfig` not in the commit |
| 7 | No new metric | **VERIFIED** | `grep "Counter\|Timer"` over both new main files → no hits. The `wms2.authz.sdr.unruled` label gain is an expected side effect of exporting an unruled type, recorded in the commit message. ⚠ **Not recorded on the ticket yet** — §1 row 7 |
| 8 | Flyway / migration conventions | **N/A to P2** | No migration in this commit; `db/migration` untouched. P1 owns `V2.2.33` |

---

## 8. Code in the commit that NO plan item asked for

The commit touches 10 files (3 production, 7 test) and nothing outside them. Production scope is
**exactly** the three files the plan names. Everything below is test-side.

| # | Unauthorised item | Weight | Assessment |
|---|---|---|---|
| 1 | **`StockrecordViewEntityContractUnitTest`** — a whole new class, 6 tests (`src/test/java/net/aim_ai/wms/unit/model/`) | Moderate (in count, not in risk) | The string `EntityContract` appears **nowhere** in the plan (`grep` over all 2,026 lines). It pins §3.3's four rules in surefire — `isAnEntityOnTheViewAndDoesNotExtendAbstractBaseEntity`, `idIsTheRealStockrecordPrimaryKey`, `timestampsAreRedeclaredAsLocalDateTime`, `equalsAndHashCodeAreHandWrittenOnId`, `everyUiSortKeyResolvesToAField`, `joinedColumnsAreMapped`. §3.3 rule 2 does note that extending `AbstractBaseEntity` *"COMPILES AND BOOTS"*, so **something** had to assert that negative and the plan named no home for it; one of its six tests is the §7.2 `everyUiSortKeyResolves` row relocated. Defensible, but it is a class the plan did not authorise and its §7.2/§7.3 tables were not updated to admit it |
| 2 | **`StockrecordViewSdrRegistrationUnitTest`** — a whole new class, 1 test (`src/test/java/net/aim_ai/wms/unit/config/`) | Low | Also absent from the plan. §7.3 routes the `exposeIdsFor` mutant to `StockrecordViewHalContextTest` alone. This adds a fast surefire duplicate of the same production call (`SdrWriteExposureUnitTest`'s idiom), with `StockView` as a positive control and a recorded Mockito varargs-captor trap. Strictly additive; its own javadoc argues for keeping both. Still unauthorised |
| 3 | **`SdrWriteWithdrawalContextTest`'s `STOCK_VIEW` → `COLLECTION_GET_ABSENT_BY_REPOSITORY_SHAPE` refactor** | Low–Moderate | P2 item 4 authorises exactly three edits to this file: add the name, bump the size, correct the javadoc. It **also** generalises the one-off `if (STOCK_VIEW.equals(name) && …)` skip into a two-element `Set` with the membership rule written down (:298-312). Justified in the commit message and arguably the right call — the alternative was a second hard-coded name — but it is a behavioural edit to a shared authorization rail that no plan item requested, in a phase whose review lanes are scoped to a new entity. The generalisation is conservative: membership skips **only** the COLLECTION axis; both members still must answer GET on the ITEM axis, and the rule states the precondition (all three `findAll` overloads withdrawn), which `StockrecordViewRepository` satisfies |
| 4 | **`StockrecordViewRepositoryFilterIT.nullInOneSearchedColumnDoesNotHideTheRow`** + its `CLIENT_NULLCOL`/`SR_NULL_UL` fixture | None — required by the approved deviation | Not a §7.2 row, because §7.2 predates the deviation. A deviation with no grading test would be the worse outcome; per the floor, a new assertion needs a mutation check and this one has one |
| 5 | **`StockrecordViewRepositoryFilterIT.joinedColumnsResolvePerShipper`** | Low | Not a §7.2 row. Asserts `itemName`/`clName`/`clNr`/`itemId` come back per shipper — AC-3's payload half, which the plan grades at the *view* level (P1's `view_shouldResolveItemName_perShipper…`) but never at the *entity mapping* level. Three lines, zero risk |
| 6 | Four `@Column(columnDefinition = "numeric(17,4)")` on the entity's `BigDecimal` fields | None | §2, closing note. Precedented and named in §7.5 row 4 |

**Verdict on scope:** no unauthorised **production** code. Six unauthorised **test** additions, all
additive, none weakening an existing assertion, none touching production behaviour — except item 3,
which edits a shared SDR rail's skip logic and is the one a reviewer should look at deliberately rather
than wave through. Items 1, 2, 3 and 5 should be either reflected back into the plan's §7.2/§7.3 tables
or explicitly accepted, so the plan does not ship describing a test layout the branch does not have.

---

## 9. Verdict

### **PASS** — with three unticked items and one documentation fix

All seven §5.2 P2 checkbox items are satisfied in source. §3.3's four entity rules, §3.4's eight
repository requirements, §3.5's four registration requirements and §7.5's seven applicable constraint
rows are **all VERIFIED**. Every §7.2/§7.3 test row in P2's scope exists and asserts the property the
plan names, with the plan's ⚠ traps (tail-slicing, the H2 seed+flush, the tenant `EntityManager`, the
EXPLAIN negative control, commit-not-rollback fixture discipline, the vacuity guards) honoured
individually. The approved `COALESCE` deviation is documented in all three required places, its stated
reasoning matches the code, and its load-bearing factual claim — exactly two of the five searched
columns are nullable — independently checks out to the cited line of `V2.2.00`.

**Not PASS-blocking, but open:**

1. **§1 row 7, ticket half — MISSING.** The `wms2.authz.sdr.unruled` label note is not on SBDEV-3410.
   Cheap to discharge with the P2 comment.
2. **§4, fourth location — documentation inaccuracy.** `FilterIT.keywordSql()`'s comment claims it
   matches `KEYWORD_CLAUSE`'s shape; post-deviation it does not. One comment, or add the `COALESCE`s.
3. **§6 row 2 / §8 — plan text drift.** `everyUiSortKeyResolves` moved class, and four test artefacts
   exist that §7.2/§7.3 do not list. Reconcile the plan or accept them explicitly.

**What this verdict does not cover, and must not be read as covering:** that the tests pass, that they
failed first, that the five mutants were observed red, or that the suite matches baseline. Nothing was
executed in this lane. Those are the reconciling lane's rows.

### Tree hygiene — read before comparing this report to any other lane's

While I was reading, the worktree held an **uncommitted mutation** of the file under grade:
`git diff` showed `KEYWORD_CLAUSE`'s `fromunitload` operand stripped to `LOWER(p.fromunitload)` — the
"drop one `COALESCE`" mutant from the commit message, evidently mid-flight in a sibling lane. It was
reverted a few minutes later and the worktree now matches `1ec4f271`. Left alone per the read-only
constraint; recorded because **a lane that graded the worktree instead of the commit during that window
would have reported the deviation as only 4-of-5 applied, and would have been wrong.** Every verdict
above is taken from `git show 1ec4f271:<path>`. A concurrent maven run in this same tree during that
window would also have produced a genuine red on
`nullInOneSearchedColumnDoesNotHideTheRow` and on `filterReturnsOnlySelectedShipper`'s seven-row
control — a real failure of a mutated file, not of the commit.
