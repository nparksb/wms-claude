# SBDEV-3436 — architect consult: how to split `getDetailViewByKeyword`

**Consulted:** 2026-10-06 · single T2 architect consult · READ-ONLY, no product code touched.
**Code basis:** `origin/develop` @ `b6693a6a` (the brief named `3f5ae6a7`; verified `3f5ae6a7` is an
ancestor, `b6693a6a` is current — every citation below is from `b6693a6a`). ⚠ The working checkout at
`/home/nampark/dev/wms-claude/v2/wms2-api` is at `5240ab17` and does **not** contain
`StockrecordViewRepository.java` at all; read via `git show origin/develop:<path>`, not from the tree.
The consult also reported the brief's line numbers (472-473, 258) as drifted; they are not — both are
unchanged at `b6693a6a`, since `3f5ae6a7..b6693a6a` touches only test files. Cite the quoted snippets
regardless, per house rule.

---

## 1. Recommendation

**Option (a): four `@Query` methods, one shared `static final String` SQL constant, plain equalities only.**

The deciding reason: (a) is the only candidate that keeps the fix *readable by reflection*. The whole
value of SBDEV-3410's precedent is that `@Query` is `RetentionPolicy.RUNTIME`, so a 60-line unit test
with no Spring context can read the exact text a future author would have to edit to re-introduce the
regression. Options (b) and (c) move the predicate into Java, where no annotation exists to read and
the mutant becomes an `if` nobody pins. Criterion (1) — plan quality — is satisfied identically by
(a), (b) and (c), so criterion (2) decides, and (a) wins it outright.

Option (d) was examined seriously and has a concrete disqualifier, not a vague one — see §5.

---

## 2. `StockunitRepository` — four methods, exact signatures

One shared constant carries everything up to and including the `includeToDelete` arm. Each variant is
that constant plus its own conjunct(s). The constant must be built by `+` on string literals so it
stays a *compile-time constant expression* — javac enforces this anyway (an annotation value must be
constant), which is why the folded text lands in the class file and reflection can see it.

```java
/** ONE copy. Idiom: FixLocationAssignmentRepository.REFILL_ELIGIBILITY_FROM_WHERE. */
String DETAIL_VIEW_SELECT_FROM_WHERE =
    "select s.id, i.item_nr as skuNumber, ... s.entity_lock as lock "
  + "from stockunit s join itemdata i on s.itemdata_id = i.id "
  + "join client c on s.client_id = c.id ... "
  + "where CONCAT(LOWER(u.labelid), ...) LIKE LOWER(concat('%', :keyword,'%')) "
  + "AND s.entity_lock != 405 AND (s.entity_lock != 2 OR CAST(:includeToDelete AS BOOLEAN))";

// 1. no filter — THE DEFAULT PAGE LOAD, the 6,102 ms → 632 ms case. Keeps the existing name.
@RestResource(path = "getDetailViewByKeyword", rel = "getDetailViewByKeyword", exported = false)
@Query(value = DETAIL_VIEW_SELECT_FROM_WHERE, nativeQuery = true)
Page<StockunitDetailView> getDetailViewByKeyword(
        @Param("keyword") String keyword, @Param("includeToDelete") boolean includeToDelete, Pageable p);

// 2. shipper only — the 796 ms → 70 ms case.
@Query(value = DETAIL_VIEW_SELECT_FROM_WHERE + " AND c.id = :clientId", nativeQuery = true)
Page<StockunitDetailView> getDetailViewByKeywordAndClient(
        @Param("keyword") String keyword, @Param("clientId") Long clientId,
        @Param("includeToDelete") boolean includeToDelete, Pageable p);

// 3. SKU only.
@Query(value = DETAIL_VIEW_SELECT_FROM_WHERE + " AND i.id = :itemdataId", nativeQuery = true)
Page<StockunitDetailView> getDetailViewByKeywordAndItemdata(
        @Param("keyword") String keyword, @Param("itemdataId") Long itemdataId,
        @Param("includeToDelete") boolean includeToDelete, Pageable p);

// 4. both.
@Query(value = DETAIL_VIEW_SELECT_FROM_WHERE + " AND c.id = :clientId AND i.id = :itemdataId",
       nativeQuery = true)
Page<StockunitDetailView> getDetailViewByKeywordAndClientAndItemdata(
        @Param("keyword") String keyword, @Param("clientId") Long clientId,
        @Param("itemdataId") Long itemdataId,
        @Param("includeToDelete") boolean includeToDelete, Pageable p);
```

### Why four and not three

Variant 3 (SKU without shipper) is **unreachable from the UI**: `wms2-web-ui`
`components/handlingUnits/stockUnitsTable.vue` carries `:disabled="selectedShipper == null"` on the SKU
autocomplete, and its `selectedShipper(newVal)` watcher sets `this.selectedSku = null` when the shipper
is cleared. It is *not* unreachable from the wire —
`StockUnitController.getDetailView` takes `@RequestParam(value = "itemdataId", required = false)`
independently of `clientId`, and that route is a live gated endpoint. Collapsing variant 3 onto variant 4
is also **unsound**: a SKU belongs to one shipper, so `clientId=A, itemdataId=<B's SKU>` returns zero rows
today, and a collapsed form would return B's rows. Four distinct predicate sets ⇒ four methods.

### Why not keep the shipper arm on the filtered path

Measured: with the SKU arm removed, leaving the shipper `COALESCE` arm costs 152 ms vs 70 ms. Not
catastrophic — but keeping it forces the pinning test to *permit* a parameter-only `OR`, which guts the
one assertion the whole fix exists to buy. Reject on criterion (2), not on 2.2×.

### ⚠ The `includeToDelete` arm is NOT part of the defect — do not "clean it up"

`(s.entity_lock != 2 OR CAST(:includeToDelete AS BOOLEAN))` is also a parameter-only disjunct, and it was
**present in the measured 632 ms good plan** ("both arms gone" removed only the two `COALESCE` arms). It
filters the driving table and does not block the hash join on `s.client_id = c.id`. It stays, and the
pinning test must assert it is still there (§4 test 5), or the next author removes a correct arm while
chasing the pattern.

### Caller-side branch — `ViewDtoService.getStockUnitViewByKeyword` (`ViewDtoService.java`, `"Page<StockunitDetailView> page = stockunitRepository.getDetailViewByKeyword("`)

```java
private static boolean isFiltered(Long id) { return id != null && id != -1L; }  // 0 is a real shipper

boolean byClient = isFiltered(clientId), byItem = isFiltered(itemdataId);
Page<StockunitDetailView> page =
      byClient && byItem ? repo.getDetailViewByKeywordAndClientAndItemdata(keyword, clientId, itemdataId, includeToDelete, p)
    : byClient           ? repo.getDetailViewByKeywordAndClient(keyword, clientId, includeToDelete, p)
    : byItem             ? repo.getDetailViewByKeywordAndItemdata(keyword, itemdataId, includeToDelete, p)
    :                      repo.getDetailViewByKeyword(keyword, includeToDelete, p);
```

⚠ Two traps in that one line, both of which this repo has already been bitten by:
- Never truthiness. `AdminController.toFilterId` normalises the wire to `null`/`-1`, and **`0` is a real
  shipper** (System-Client, on every reachable DB). The test must cover `0` explicitly.
- Compare against the **primitive literal `-1L`**, never a boxed `Long`. `clientId != Long.valueOf(-1)`
  is reference comparison — and `-1` is inside the `Long` cache, so it would *accidentally* produce the
  right answer here and hide a defect that inverts past 127. The `isFiltered` helper exists so there is
  one site to get right and one site to test.

---

## 3. Sibling verdict — `UnitloadRepository`: same structure, two methods

**Same structure, different arity — that is not divergence.** The structure is "one method per filter
shape, plain equalities only, one shared compile-time constant". One optional parameter yields two
methods (`getDetailViewByKeyword`, `getDetailViewByKeywordAndClient`), which is literally the shipped
`StockrecordViewRepository` shape. Divergence would cost more than it saves: the two
`getDetailViewByKeyword` methods are read as a pair (`UnitloadRepository.java` says so in situ —
*"See the fuller note on StockunitRepository.getDetailViewByKeyword for why NULL and -1 both mean 'no
filter'"*), they are fixed by one ticket, and one pinning test covers both if they share an idiom.

✅ **Gap closed — the consult brief omitted this table, not the triage.** `unitload` was measured on the
same run (`dev_wh01_om1`, 2026-10-06, `force_generic_plan`, PREPARE, count form, keyword='a',
`includeToDelete=false`, shipper 52200; unitload 759,884 rows):

| case | plan | time | buffers |
|---|---|---|---|
| All Shippers — as shipped | client Seq Scan drives, 160 nested-loop probes into `index_unitload_client_id` | **777 ms** | **305,064** |
| ↳ arm gone | Parallel Seq Scan + Hash Joins | **192 ms** | **118,376** |
| One shipper — as shipped | `Index Cond: (client_id = c.id)`, no parallelism | 168 ms | 57,901 |
| ↳ arm gone (plain equality) | Parallel Bitmap `index_unitload_client_id` | 65 ms | 58,018 |

So the sibling's win is real but arrives by a different mechanism than `stockunit`'s: **the index is used
in both filtered forms** (buffers 57,901 vs 58,018 — neutral), and the gain comes from the unfiltered path
and from the `COALESCE` arm suppressing parallel workers. The inference in this section was right about
the direction and wrong about the mechanism; the numbers above supersede it. The executor's floor DB query
should go somewhere else.

---

## 4. The pinning test

`StockrecordViewRepositoryQueryShapeUnitTest` **does generalise** to a native query with four variants,
with one simplification. It reads `Class.forName(...).getMethod(...).getAnnotation(Query.class).value()`,
normalises whitespace, and asserts on the text — nothing about that is JPQL-specific. Its tail-slice
trick (`jpql.substring(indexOf(CLIENT_CONJUNCT)).toUpperCase()`) exists because its keyword clause carries
a legitimate lower-case `or :keyword = ''`. **Here no slice is needed**: the one legitimate disjunct is
`OR CAST(:includeToDelete AS BOOLEAN)`, which does not match `OR :`, so the two patterns are naturally
disjoint and a whole-string assertion is both simpler and stronger.

New test, `net.aim_ai.wms.unit.repo.HandlingUnitsDetailViewQueryShapeUnitTest`, covering **both**
repositories (4 + 2 = 6 variants):

1. **`theVariantFamilyIsExactlyTheExpectedShapes`** — collect
   `getMethods()` filtered to `name.startsWith("getDetailViewByKeyword")`, map to
   `name(ParamType,...)`, `containsExactlyInAnyOrder` the 4 (resp. 2) signatures. ⚠ Assert the **set
   first**, before anything iterates: a for-each over an empty list is 13/13 green against a gutted
   interface. Scoped to the name family, not to `getDeclaredMethods()` — `StockunitRepository` declares
   ~40 methods and a whole-interface pin would be pure churn. This is what catches a *fifth* variant
   being added with a `COALESCE` arm.
2. **`noVariantCarriesAParameterOnlyDisjunct`** — for each of the 6, uppercased text must
   `doesNotContain(" OR :")` **and** `doesNotContain("COALESCE(CAST(:")`. This is the mutant killer.
3. **Vacuity guard, in the same test** — each variant's text must also `contains("FROM STOCKUNIT S")`
   (resp. `FROM UNITLOAD U`) and be non-blank. A zero-match regex and a true absence look identical;
   without a positive control, a renamed alias silently certifies nothing. 
4. **`eachVariantCarriesExactlyItsOwnConjuncts`** — filtered variants `contains("AND c.id = :clientId")` /
   `contains("AND i.id = :itemdataId")`; the unfiltered one contains neither. Kills "dropped the conjunct
   entirely", which would silently un-filter the grid while test 2 stays green.
5. **`everyVariantIsTheUnfilteredOnePlusAConjunct`** — each variant `startsWith(unfilteredText)`. This is
   the Stockrecord `startsWith(unfilteredWhere)` idiom; it is what ONE shared constant produces and four
   hand-copies do not, and it subsumes "the searched column set drifted between variants".
6. **`theIncludeToDeleteArmSurvives`** — each variant
   `contains("(s.entity_lock != 2 OR CAST(:includeToDelete AS BOOLEAN))")`. Protects a *correct* OR arm
   from a future cleanup pass. See §2.

**Plus a caller test — this half is the one most likely to be dropped, and it is not optional.**
`ViewDtoServiceHandlingUnitsRoutingUnitTest` (Mockito), parameterised over
`clientId ∈ {null, -1L, 0L, 52200L} × itemdataId ∈ {null, -1L, 0L, 8807L}`, asserting which repository
method is invoked and `verifyNoMoreInteractions` on the rest. ⚠ In the `never()`/no-interaction
verifications use `anyBoolean()` for `includeToDelete` — `any()` returns `null` and NPEs at unboxing on a
primitive parameter.

### What these cannot see — stated, not fixed

- **They read the annotation, not the executed statement.** They cannot prove Hibernate/pgjdbc send that
  text, nor that the plan is good. Only an EXPLAIN against real PostgreSQL does — and the repo's only
  EXPLAIN precedent (`OutboxClaimExplainIT`) hand-copies its statement into a constant, so an IT written
  to that precedent *never reads what a mutant edits* and is not a pin. `StockrecordViewRepository`'s own
  javadoc says exactly this.
- **Two classes only, deliberately.** A package-wide ArchUnit sweep over `net.aim_ai.wms.repo.jpa` was
  considered and rejected on measured grounds: the same parameter-only-OR idiom exists at ~12 further
  sites across 8 other repositories — `CyclecountRepository` (4), `FlowbinMonitorViewRepository`,
  `LockOverviewDtoViewRepository`, `LockOverviewAllDtoViewRepository`, `OrderDetailMonitorViewRepository`,
  `ParcelMonitorViewRepository`, `ReceivingDtoViewRepository`, `ItemdataRepository`,
  `CustomerorderRepository`. A package rule would ship with a 12-entry allow-list, i.e. a list people
  append to rather than shrink. Propose those as a separate ticket; do not widen SBDEV-3436.
- **The regex cannot see an equivalent arm spelled differently** — `OR -1 = :clientId`,
  `OR :clientId::bigint IS NULL`, an arm buried in a subquery, or the predicate moved into Java.
- **It cannot see the caller.** If `ViewDtoService` stopped branching, all six query-shape assertions stay
  green while the grid silently ignores both filters. Only the routing test sees that.

---

## 5. Rejected options

**(b) custom `@Repository` fragment with `EntityManager.createNativeQuery`.** Disqualified four times
over, independently of plan quality. (i) **Zero precedent**: there is no `*RepositoryImpl` or
`*RepositoryCustom` file anywhere in the repo, `createNativeQuery` appears once in all of `src/main`
(`PutawayConfigService`), and `PageableExecutionUtils` appears nowhere in `src/main`. (ii) **Interface
projections do not survive**: `StockunitDetailView` is materialised by Spring Data's `ResultProcessor` on
*repository query methods*; a raw EM query returns `Tuple`/`Object[]`, so you would hand-build proxies or
convert the projection to a class — which ripples into `ViewDtoService` and `HandlingUnitsClientFilterIT`.
(iii) **Sorting becomes an injection surface**: `StockUnitController.getDetailView` takes
`@RequestParam(value = "sort", ...)` straight off the wire and builds `Sort.by(sort)`; today Spring Data
applies and *validates* that via `QueryUtils.applySorting`/`checkSortExpression`. Hand-assembling the
`ORDER BY` loses that validation. (iv) **No annotation to read**, so the §4 pin dies and the mutant
becomes an `if`. The one thing (b) gets right — a pure static SQL-builder is unit-testable — (a) gets for
free and more cheaply.

**(c) `Specification` / Criteria.** Not reachable without entity-mapping work, and it would not help if it
were. There is **no `JpaSpecificationExecutor` or `Specification` import anywhere in `src/main`**; the
repo-wide rule is *no JPA association annotations, manual FK relationships only*, so a 5-way `root.join()`
has nothing to join on and you would be writing multi-root cross joins in Criteria. The 10-column aliased
interface projection would have to become a DTO class (same ripple as (b)). And it composes the *same*
plain equalities, so it buys nothing on criterion (1) while losing criterion (2) exactly as (b) does.

**(d1) a one-method formulation that stays indexable.** `c.id = COALESCE(CAST(:clientId AS BIGINT), c.id)`
does not work: the right operand is a Var, not a constant, so no index condition is derivable under any
plan mode. `(:clientId IS NULL OR c.id = :clientId)` is the same disease by another spelling.

**(d2) one method, `UNION ALL` with pseudo-constant guards.** The idea is sound in principle —
PostgreSQL gates a Var-free qual as a `One-Time Filter` on a `Result` node and skips the subtree — but it
has a hard disqualifier here: **Spring Data cannot derive the count query.** The method returns `Page` with
no `countQuery` attribute, and `jsqlparser` is **not** in `v2/wms2-api/pom.xml` (verified), so
`QueryEnhancerFactory` falls back to the regex-based `DefaultQueryEnhancer`, which rewrites the select list
of the *first* branch and produces a malformed or wrong count over a `UNION ALL`. Secondary objections:
two optional params means **four** branches, i.e. the 5-way join written four times; `ORDER BY`+`LIMIT`
sits on the `Append`, not inside the surviving branch, so each page may sort the whole result; and the
pinning test would have to permit `OR` arms, which defeats the purpose. It is also unmeasured, and the
brief correctly forbids this consult from re-measuring. Rejected — but on a named mechanism, not a shrug.

**(d3) `prepareThreshold=0` on the pgjdbc URL.** Would keep every statement on the custom-plan path and
fold the sentinels away repo-wide. Rejected: it is a global config change affecting every query in every
tenant, costs re-planning on every execution, is T3-shaped, and is not this ticket.

---

## 6. Risks and blast radius

| Risk | Why it bites | Mitigation |
|---|---|---|
| **`HandlingUnitsClientFilterIT` will not compile** | It calls both methods directly with the old arity (`getDetailViewByKeyword(KEYWORD_ALL, CLIENT_A, ITEM_A1, false, PageRequest.of(0,1))` and three more sites). | It must be migrated in the same commit — not optional. Its row-level guarantees (System-Client `0`, cross-shipper SKU ⇒ zero rows, To-Delete/Shipped lock filtering) are the behavioural backstop reflection cannot give. Keep every assertion; re-home the three-valued sentinel cases onto the *routing* test. |
| **Interface projection + `Pageable` count derivation** | The four new queries are still `nativeQuery = true` returning `Page<StockunitDetailView>` with no `countQuery`. Derivation works today for this shape; appending a trailing `AND <plain equality>` keeps the select list and `FROM` untouched, so it keeps working. | Low — but this is exactly why (d2) dies. Any future edit that changes the *select list* or adds a set operation needs an explicit `countQuery`. |
| **Caller regression invisible to the query tests** | A branch that uses truthiness sends shipper `0` to the unfiltered method; a branch that always calls the unfiltered method ignores both filters. Both leave §4 fully green. | The routing unit test, with `0` as a first-class case. |
| **Sort/`created` ordering** | `getDetailView` defaults to `Sort.by(desc("created"))`; `stockunit.created` is referenced only through `Pageable`, not in the SQL text. Unchanged by the split. | None needed; just do not inline the sort. |
| **HAL / authz** | None. Both methods are `@RestResource(..., exported = false)`, and `Stockunit`/`Unitload` additionally appear in `SdrUncalledSurfaceNotExportedContextTest`'s `WITHDRAWN` list (whose `hasSize(28)` pins *entities*, not searches, so it is unaffected). `SdrFunctionRules` names neither. **Signature changes are free.** | Re-run the `security/` context lane anyway; it is cheap. |
| **Files touched** | `StockunitRepository` (1→4 methods + constant), `UnitloadRepository` (1→2 + constant), `ViewDtoService` (two methods gain a branch + one helper), `HandlingUnitsClientFilterIT` (migrate), two new test classes. No controller, no `toFilterId`, no UI, no Flyway, no index. Fully revertible. | — |

---

## References

- `v2/wms2-api/src/main/java/net/aim_ai/wms/repo/jpa/StockunitRepository.java` — the two arms:
  `"AND (COALESCE(CAST(:clientId AS BIGINT), -1) = -1 OR c.id = CAST(:clientId AS BIGINT)) "` and the
  `itemdataId` twin on the next line; the legitimate arm `"AND s.entity_lock != 405 AND (s.entity_lock != 2 OR CAST(:includeToDelete AS BOOLEAN)) "`.
- `.../repo/jpa/UnitloadRepository.java` — the single arm, and in situ *"See the fuller note on
  StockunitRepository.getDetailViewByKeyword for why NULL and -1 both mean 'no filter'"*.
- `.../repo/jpa/StockrecordViewRepository.java` — the shipped precedent: `String KEYWORD_CLAUSE =`,
  `findByKeyword` / `findByKeywordAndClient`, and *"⚠ `p.clientId = :clientId` is a PLAIN EQUALITY and must
  stay one"*; also names this very divergence — *"This deliberately diverges from
  StockunitRepository.getDetailViewByKeyword, which folds both sentinels into one method with COALESCE."*
- `.../src/test/java/net/aim_ai/wms/unit/repo/StockrecordViewRepositoryQueryShapeUnitTest.java` — the model:
  `queryShapeForbidsADisjunction`, the tail slice *"⚠ Slice at the conjunct; do NOT scan the whole string"*,
  and the set-first vacuity note *"measured elsewhere in this repo as 13/13 green against a gutted interface"*.
- `.../repo/jpa/FixLocationAssignmentRepository.java` — `String REFILL_ELIGIBILITY_FROM_WHERE =` (the shared-constant
  idiom) and the hazard it could not fix: *"removing a parameter changes the signature of an SDR-exported search — a contract change"*.
- `.../service/ViewDtoService.java` — the only two callers, `getStockUnitViewByKeyword` / `getUnitLoadViewByKeyword`.
- `.../controller/StockUnitController.java` — `return dtoViewService.getStockUnitViewByKeyword(keyword, toFilterId(clientId), toFilterId(itemdataId), includeToDelete, p);`
  and the independent `@RequestParam(value = "itemdataId", required = false)`.
- `.../src/test/java/net/aim_ai/wms/integration/repository/HandlingUnitsClientFilterIT.java` — the compile-breaking caller.
- `v2/wms2-web-ui/components/handlingUnits/stockUnitsTable.vue` — `:disabled="selectedShipper == null"` and the
  `selectedShipper(newVal)` watcher's `this.selectedSku = null`.
- `v2/wms2-api/pom.xml` — **no `jsqlparser`** (the (d2) disqualifier).
