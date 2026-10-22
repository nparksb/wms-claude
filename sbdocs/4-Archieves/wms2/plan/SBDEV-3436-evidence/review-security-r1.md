# SBDEV-3436 — security / data-scoping review (lane B, round 1)

- **Commit:** `c85e7949` ("SBDEV-3436: split the Handling Units grid searches on filter shape")
- **Baseline:** `b6693a6a`
- **Worktree:** `/home/nampark/dev/wms-claude/.claude/worktrees/wms2-api/SBDEV-3436-review-b` (detached at `c85e7949`)
- **Axis:** can this change let someone see rows they could not see before, or reach a route they could not reach before?
- **Verdict:** **No.** No new reachable route; no input produces a superset of the pre-change row set; tenant routing untouched.
- **Risk level: LOW.** Four findings, none of them a live exposure; two are latent hazards worth closing in this pass.

**High: 0, Medium: 0, Low: 2, nit: 2**

---

## 1. SDR surface — does the split add a reachable HAL route?

**Answer: no. The exported-search set on both repositories is byte-identical across `b6693a6a` → `c85e7949`.**

Both repositories are **exported at class level** — `StockunitRepository.java:29` and `UnitloadRepository.java:29` both carry a bare
`@RepositoryRestResource(collectionResourceRel = "…", path = "…")` with no `exported` attribute, and both domain types sit in
`SdrUncalledSurfaceNotExportedContextTest.MUST_REMAIN_EXPORTED`. So the question is live: a query method added here *without*
`@RestResource(exported = false)` **is** published as `/v3/{stockunit,unitload}/search/…` to any `wms_user`.

### Instruments used, and what each cannot see

**(a) Source-level export-state diff at both revisions** — `git show <rev>:<file>` for both repository files, comments and
**string literals** stripped, every interface method paired with the export state of its own annotation block.

```
--- b6693a6a: 55 methods  |  c85e7949: 59 methods
ADDED:   StockunitRepository#getDetailViewByKeywordAndClient             WITHDRAWN
         StockunitRepository#getDetailViewByKeywordAndItemdata           WITHDRAWN
         StockunitRepository#getDetailViewByKeywordAndClientAndItemdata  WITHDRAWN
         UnitloadRepository#getDetailViewByKeywordAndClient              WITHDRAWN
REMOVED: (none)
EXPORT-STATE CHANGED on a surviving method: (none)
EXPORTED set IDENTICAL: True        (24 methods, both revisions)
```

`getDetailViewByKeyword` is absent from ADDED on both repositories because the *name* pre-existed; its state is unchanged
`WITHDRAWN` on both sides, and its arity change is invisible to SDR's export decision.

*Positive control:* the instrument classifies 24 EXPORTED against 35 WITHDRAWN, and places `findByUnitloadId` and
`getAmountAvailable` in EXPORTED — the first is the live `CONTROL_ROUTE` of
`StockunitLockingSearchRouteWithdrawalContextTest:89`, the second is documented live-called by `wms2-mobile-ui`. A scan that
returned "everything withdrawn" would have failed both.

*Blind spot:* it is a regex over source text. It cannot see a class-file-only difference, and it would misread an annotation
sitting between a `;` and the method it does not belong to.

**(b) Bytecode** — `javap -v -p` over the **compiled** `StockunitRepository.class` / `UnitloadRepository.class`
(`…/SBDEV-3436/target/classes/…`, mtime 20:15), which closes (a)'s blind spot by reading the resolved annotation, not the text:

```
getDetailViewByKeyword(String, boolean, Pageable)                          exported=false
getDetailViewByKeywordAndClient(String, Long, boolean, Pageable)           exported=false
getDetailViewByKeywordAndItemdata(String, Long, boolean, Pageable)         exported=false
getDetailViewByKeywordAndClientAndItemdata(String, Long, Long, …)          exported=false
UnitloadRepository#getDetailViewByKeyword                                  exported=false
UnitloadRepository#getDetailViewByKeywordAndClient                         exported=false
```

*Positive control:* the same pipeline prints `(no exported attr -> EXPORTED)` for `findByUnitloadId`, `findByUnitloadIdIn` and
`getAmountAvailable`, and the Stockunit census splits **11 EXPORTED / 20 WITHDRAWN** — so a pipeline that printed
`exported=false` unconditionally is excluded.
*Caveat, stated:* the class files are dated 20:15 and the commit 20:25. The four signatures and their annotations match the
committed source exactly, so this is the same code compiled before the commit object was written — but it is **not**
independently pinned to `c85e7949`, and that is the one thing this instrument does not prove.

**(c) Mechanism coverage.** For a **search** route the four withdrawal mechanisms do not all apply, and the repo states why:
`SdrUncalledSurfaceNotExportedContextTest` records that `ResourceType` has only `COLLECTION` and `ITEM` and
`RepositorySearchController` never calls `verifySupportedMethod`, so **`RestConfiguration`'s `ExposureConfiguration` /
`SDR_WRITE_WITHDRAWN` cannot reach `/search/**` at all**, and `@ReadOnlyProperty` is a write-path field filter. For a search the
levers are exactly two: the class-level export (unchanged — both types stay in `MUST_REMAIN_EXPORTED`) and the method-level
`@RestResource(exported = false)` (verified by (a) and (b)). `SdrFunctionRules` carries **no** entry and **no**
`SearchOverrideKey` for `Stockunit` or `Unitload` — its only matches in that file are three prose comments — so no rule went
stale and `SdrRuleStartupCheck` has nothing to refuse the boot over.

**(d) Runtime `ResourceMappings`** — a `mvn -o test -Dtest='net.aim_ai.wms.security.*Test'` run in the review worktree is
**queued behind three other Maven processes** in this workspace and had not started at the time of writing. See §6.

---

## 2. The context-test pins — broken, widened, or silently unaffected?

**No pin breaks. One pin is derived and would genuinely catch an accidental export; the exact-size pins are all counting
something else, and say so explicitly rather than silently.**

| Pin | Reaction to +6 method names | Is it a pin that *noticed*? |
|---|---|---|
| `SdrNonEntityCollectionSearchNotExportedContextTest#noExportedSearchReturnsACollectionOfNonEntities` | **Would go RED on an accidental export.** It iterates every exported search and condemns any returning a collection whose element has no `PersistentEntity`. All six variants return `Page<StockunitDetailView>` / `Page<UnitloadDetailView>` — interface projections, i.e. offenders the moment one is exported. | **Yes — derived, not a list.** Carries two non-vacuity guards (`exportedSearches > 100`, `collectionReturns > 50`) and a mutation rail (`detectorRecognisesEverySideOfThePredicate`). This is the real protection. |
| `SdrOmittedPrimitiveParamSearchContextTest` — "no exported SDR search declares a primitive parameter" | **Would also go RED.** All six declare `boolean includeToDelete`. | Yes — a genuinely independent second rail. |
| `SdrUncalledSurfaceNotExportedContextTest` — `assertThat(WITHDRAWN).hasSize(28)` | Unaffected. | **`WITHDRAWN` is a list of domain *types* withdrawn at class level, not of searches.** `Stockunit`/`Unitload` are in the *other* list (`MUST_REMAIN_EXPORTED`). Its method-granular pin covers only `ReplenishorderRepository`'s three searches. So this pin does not notice — **and it is not meant to**; it is not a surface ratchet. |
| `SdrSurfaceInventoryContextTest` | Unaffected. | **Explicitly an inventory generator, not a ratchet** — its only assertion is `resources > 20`. It writes `target/sdr-surface-inventory.tsv`. It would not catch a newly exported search. Its own javadoc says so. |
| `SdrWriteWithdrawalContextTest` — `hasSize(51)` / `hasSize(8)` | Unaffected. | Write-verb axis only; this diff adds no verb and no write. |
| `SdrRuleInventoryContextTest` — "every per-search OVERRIDE key resolves to a live, exported search path" | Unaffected. | Correct: there is no override key for either type, so the rename of nothing breaks nothing. |
| `StockunitLockingSearchRouteWithdrawalContextTest` | Unaffected. | Its over-gating control is `/v3/stockunit/search/findByUnitloadId`, which this diff does not touch. |
| `Sbdev3017TrancheGateContextTest` — `hasSize(227)` | Unaffected. | MVC handler tranche list; neither controller file is in the commit. |
| `SdrMutatingSearchNotExportedContextTest`, `SdrLockingSearchNotExportedContextTest` | Unaffected. | Mutation / `@Lock` axes; the six variants are plain reads with no `@Lock`. |

**Answered directly, because it was asked:** yes, there are exact-size pins that pass without noticing — `hasSize(28)`,
`hasSize(51)`, `hasSize(8)`, `hasSize(227)`. In every case the set they size is a different axis (domain types, write verbs,
MVC handlers), not the search surface, and each carries a comment saying what it counts. They are not false comfort here. The
comfort comes from §2 row 1 and row 2, which are derived invariants over the whole exported-search population.

---

## 3. Function gating — unchanged, and genuinely enforced

Neither controller file appears in `git show c85e7949 --stat`. Both handlers carry, unchanged:

```java
@RequiresFunction({WmsConstants.FunctionEnum.WEB_UI_VIEW_STOCK_UNIT,
                   WmsConstants.FunctionEnum.WEB_UI_VIEW_CONTAINER})
@GetMapping(path = "/detailView", produces = "application/json")
```

`StockUnitController.java:771` and `UnitLoadController.java:226` (ANY-of, deliberate — the Handling Units page toggles the two
grids with a `v-select`, so the page's own menu gate is already ANY-of).

**One thing worth stating precisely, because it is easy to get backwards:** neither `StockUnitController` nor `UnitLoadController`
is in `FunctionGuardInterceptor.GUARDED`. That does **not** weaken the gate. Reading
`FunctionGuardInterceptor#preHandle:270-279`, `GUARDED` is consulted only on the `annotation == null` branch — it is the
fail-closed rule for *unannotated* handlers. An annotated handler goes to `accessService.checkAnyAccess(username,
annotation.value())` regardless of membership. So the gate is live on both handlers, and this diff does not touch it.

`SdrFunctionRules` names neither search (§1c).

---

## 4. Row-visibility equivalence — the truth table

**No input produces a superset.** The decisive fact is upstream of the diff: `AdminController.toFilterId:99` **never returns
`null`** —

```java
protected static Long toFilterId(String raw) {
    if (raw == null || raw.isBlank()) return -1L;
    try { return Long.parseLong(raw.trim()); }
    catch (NumberFormatException e) { return -1L; }
}
```

so every wire input collapses to `-1L` or a parsed `Long` before `ViewDtoService` ever sees it.

Old predicate: `AND (COALESCE(CAST(:clientId AS BIGINT), -1) = -1 OR c.id = CAST(:clientId AS BIGINT))`.
New decision: `isFiltered(id) = id != null && id != -1L`, then one variant carrying `AND c.id = :clientId` or no clause at all.

| wire `clientId` | `toFilterId` | OLD SQL | NEW route | OLD rows | NEW rows | same? |
|---|---|---|---|---|---|---|
| absent | `-1L` | arm TRUE → no filter | unfiltered variant | all | all | ✅ |
| `""` (v-autocomplete cleared) | `-1L` | arm TRUE → no filter | unfiltered | all | all | ✅ |
| `"abc"` (unparseable) | `-1L` | arm TRUE → no filter | unfiltered | all | all | ✅ |
| `"-1"` ("All Shippers") | `-1L` | `COALESCE(-1,-1) = -1` TRUE | unfiltered | all | all | ✅ |
| **`"0"` (System-Client)** | `0L` | `COALESCE(0,-1) = 0 ≠ -1` → `c.id = 0` | `…AndClient`, `c.id = 0` | client 0 | client 0 | ✅ |
| `"52200"` | `52200L` | `c.id = 52200` | `…AndClient` | client 52200 | client 52200 | ✅ |
| **`"-2"`** | `-2L` | `-2 ≠ -1` → `c.id = -2` | `…AndClient`, `c.id = -2` | **0 rows** | **0 rows** | ✅ |
| **`Long.MIN_VALUE`** | `MIN` | `c.id = MIN` | `…AndClient`, `c.id = MIN` | **0 rows** | **0 rows** | ✅ |
| overflow (`"9…9"`) | `-1L` (NFE) | no filter | unfiltered | all | all | ✅ |
| `null` (Java caller only) | — | `COALESCE(NULL,-1) = -1` TRUE | `isFiltered` → false, unfiltered | all | all | ✅ |

The general argument, which is what makes the table complete rather than a sample: `(A OR B)` where `A` is
`COALESCE(bind,-1) = -1`. `A` depends **only** on the bind, never on the row. So for any bind the clause is either the constant
`TRUE` (bind ∈ {null, −1}) or exactly `B`. `isFiltered` partitions on the identical condition and picks a variant that is either
"no clause" or exactly `B`. The two are therefore equivalent on **every** input, not just the ten above. Three-valued logic
agrees: with a NULL `c.id`, the old filtered form yields `FALSE OR NULL` = NULL (row dropped) and the new `c.id = :clientId`
yields NULL (row dropped). The same argument holds verbatim for `itemdataId`, and for the 2×2 composition because the two arms
were independent conjuncts before and are independent appended conjuncts now.

**The shipper filter is confirmed to be a UI filter, not an authorization boundary** — `Client` is a business dimension, there is
no client scoping anywhere on this path, and the gate (§3) is per-screen, not per-shipper. A caller holding
`WEB_UI_VIEW_STOCK_UNIT` could already read every shipper's rows before this change by sending `clientId=-1`, which is the
default page load.

**The other place a filter can be lost is the derived COUNT query** (filter applied to the page, not the count → the grid
paginates into rows it cannot show). `HandlingUnitsClientFilterIT#countQuery_appliesTheSameFilters` forces the count with
`PageRequest.of(0, 1)` and was correctly migrated to the new arities. **No IT test was dropped**: 14 `@Test` methods at
`b6693a6a`, 14 at `c85e7949`, name sets identical by diff.

Structurally, the split is *safer* than four hand-copied queries would have been: the `entity_lock != 405`, the lock-2 /
`includeToDelete` arm and the `keyword` `LIKE` all live in the single shared `DETAIL_VIEW_BY_KEYWORD` constant, and
`HandlingUnitsDetailViewQueryShapeUnitTest#everyVariantIsTheUnfilteredOnePlusAConjunct` asserts `startsWith(unfiltered)`, so a
variant cannot silently lose a visibility filter.

---

## 5. Tenant scoping — no escape path

`TenantDatabaseConfig:22` binds **`basePackages = "net.aim_ai.wms.repo.jpa"`** to `tenantEntityManagerFactory` /
`tenantTransactionManager`. Both repositories already live in that package and the diff adds **no new repository, no new
package, no new `EntityManager`, no new datasource and no `@Query(... )` against a landlord table** — the six methods are
siblings on the same two interfaces, resolved through the same proxy and the same routing key
(`first4(tenantName) + "-" + facilityCode`). The shared `DETAIL_VIEW_BY_KEYWORD` is a `static final String` on the interface; a
constant has no persistence-unit affinity.

The one thing I did **not** do: execute a request under two tenant headers and compare. The claim here is structural
(same interface ⇒ same persistence unit), which is sound but is not a measurement.

---

## 6. Findings

### L-1 (Low) — the family's own fast-lane test pins query shape but not export state

**Where:** `src/test/java/net/aim_ai/wms/unit/repo/HandlingUnitsDetailViewQueryShapeUnitTest.java`

The change adds five new method names to two class-level-**exported** SDR repositories. The test that owns this family already
reflects over all six variants and pins the signature set exactly —

```java
@DisplayName("StockunitRepository declares exactly the four filter shapes, UnitloadRepository exactly two")
void theVariantFamilyIsExactlyTheExpectedShapes() {
```

— but contains **zero** references to `RestResource` or `exported` (grep returns nothing; positive control: `Query` matches 7
times in the same file, so the grep works). Today an accidental export is caught only by the two **generic** context-lane rails
in §2, which need a Spring context and do not name this family; a reader of this test would reasonably conclude export state is
covered here.

**Blast radius if it ever regresses:** one un-exported-by-accident variant is an unauthenticated-to-`wms_user` read over
~1.6M stock units — the thing this review exists to prevent. The generic rails do hold, so this is defence-in-depth and
locality, not a live gap.

**Fix** — the test already has the `Method` objects in hand, so this is additive:

```java
// in theVariantFamilyIsExactlyTheExpectedShapes, or as a sibling @Test
everyVariant((signature, method) -> {
    RestResource rr = method.getAnnotation(RestResource.class);
    assertThat(rr).as("%s must carry @RestResource — both repositories are exported at class "
            + "level, so an un-annotated query method is published as /v3/…/search/…", signature)
        .isNotNull();
    assertThat(rr.exported()).as("%s returns a Page<…DetailView> interface projection; exported, the "
            + "route 500s on the first matching row and serves the whole grid to any wms_user",
            signature)
        .isFalse();
});
```

### L-2 (Low) — composition-by-append is safe only because the shared constant happens to end in a parenthesised group

**Where:** `src/main/java/net/aim_ai/wms/repo/jpa/StockunitRepository.java` (`DETAIL_VIEW_BY_KEYWORD` and the three suffixed
variants); identically `UnitloadRepository.java`.

Today the constant ends:

```java
"AND s.entity_lock != 405 AND (s.entity_lock != 2 OR CAST(:includeToDelete AS BOOLEAN))";
```

and a variant is `DETAIL_VIEW_BY_KEYWORD + " AND c.id = :clientId"`. The trailing `OR` is parenthesised, so the appended `AND`
binds at the top level and the composition is correct. **That is a property of the current text, not of the idiom.** `AND` binds
tighter than `OR`: if a later change appends a *top-level* disjunct to the constant — exactly the shape the file already
contains twice and deliberately keeps — then `… OR X AND c.id = :clientId` parses as `… OR (X AND c.id = :clientId)`, and every
filtered variant silently returns a **superset**: the shipper filter stops filtering whenever `X` is true.

The existing rail cannot see this. `everyVariantIsTheUnfilteredOnePlusAConjunct` asserts `startsWith(unfiltered)`, which is
satisfied by the broken composition too — it is a *textual* prefix check, and the defect is in operator precedence, not in
prefixing. `eachVariantCarriesExactlyItsOwnConjuncts` likewise only asserts the equality text is present.

This is the only mechanism I found by which this design could produce "rows you could not see before", and it is one edit away.

**Fix** — one assertion in the shape test, which already reads the constant:

```java
@Test
@DisplayName("the shared constant's predicate is AND-composable — a trailing top-level OR would make "
           + "every appended filter bind to the last disjunct and silently un-filter the grid")
void theSharedConstantIsSafeToAppendTo() {
    everyBaseConstant((name, sql) -> {
        String where = sql.substring(sql.toLowerCase().indexOf(" where "));
        assertThat(depthAwareTopLevelTokens(where))
            .as("%s ends with a top-level OR: appending \" AND c.id = :clientId\" would parse as "
              + "\"… OR (X AND c.id = :clientId)\" and return a SUPERSET on the filtered variants. "
              + "Wrap the new disjunct in parentheses.", name)
            .doesNotContain("OR");
    });
}
```

A cheaper equivalent that needs no parser: make the suffix defensive at the source —
`"(" + DETAIL_VIEW_BY_KEYWORD_PREDICATE + ") AND c.id = :clientId"` — but that requires splitting the constant, so the
assertion is the smaller change.

### nit-1 — `isFiltered`'s null branch is unreachable from the wire

`ViewDtoService#isFiltered` is `id != null && id != -1L`, and the javadoc explains the `-1L` half carefully. The `id != null`
half is correct and must stay, but **no HTTP input can reach it**: `AdminController.toFilterId:99` returns `-1L` for `null`,
blank and unparseable, and both controllers call it unconditionally. The `null` rows of
`ViewDtoServiceHandlingUnitsRoutingUnitTest`'s 4×4 matrix therefore grade a Java-caller-only path. That is worth keeping (the
service is public and `ViewDtoServiceUnitTest` calls it directly) but worth one comment line, so a future reader does not take
the matrix as evidence about wire behaviour.

### nit-2 — the sentinel matrix is narrower than its `@DisplayName` claims

`@DisplayName("Stock Units: every sentinel/real combination reaches exactly its own variant")` over
`{null, -1L, 0L, REAL}`. It omits negative ids other than `-1` and `Long.MIN_VALUE` — the two the equivalence argument most
needs, since they are the inputs where "sentinel-ish" and "real id" are easiest to confuse. I confirmed by hand (§4) that both
behave identically before and after, so **this is a wording/coverage nit, not a defect**: `isFiltered` partitions on
`== null || == -1L`, so every other value takes the filtered path *by construction* and the filtered path is a plain equality.
Adding `-2L` and `Long.MIN_VALUE` to the `clients`/`skus` arrays is a two-token change that makes the matrix match its name.

---

## 7. Checked and clean (no finding)

- **Native-query sort injection.** Both controllers pass the raw `sort` request param into
  `Sort.by(Sort.Order.asc(sort))` against a `nativeQuery = true` method, and the codebase has **no** sort allow-list anywhere
  (`git grep` for `checkSortExpression|JpaSort.unsafe|sortWhitelist|ALLOWED_SORT|sanitizeSort` over `src/` → zero; positive
  control: `Sort.by` matches across many controllers, so the search ran). Spring Data's `QueryUtils.checkSortExpression`
  rejects any sort property containing punctuation other than `.`/`_` before it reaches the SQL, so this is not injectable.
  **Pre-existing and unchanged by this diff** either way.
- **Path / rel collisions.** The five new `@RestResource(path=…, rel=…)` values are distinct from each other and from every
  existing search on their repository; and since all six are withdrawn, no rel is published at all.
- **`DETAIL_VIEW_BY_KEYWORD` visibility.** It is an implicitly `public static final String` interface field. It carries SQL
  text, no credential, no tenant identifier, and no exposure consequence.
- **Write surface.** The diff adds no verb, no mutation, no `@Modifying`, no `@Lock`.
- **The `/rest/**` internal OMS↔WMS surface** is not touched by this diff.

## 8. Instrument still outstanding

A runtime `ResourceMappings` enumeration — `mvn -o test -Dtest='net.aim_ai.wms.security.*Test'` in the review worktree, which
runs all 28 security pins and regenerates `target/sdr-surface-inventory.tsv` — was **queued behind three concurrent Maven
processes** in this workspace and had not started when this report was written. It is belt-and-braces rather than load-bearing:
§1(a) already establishes the exported set is identical between the two revisions and §1(b) confirms it at bytecode level, both
positive-controlled. If it comes back red on anything in `net.aim_ai.wms.security`, that supersedes §2 and this file will be
amended.

**These context tests use H2 in-memory** (`BaseRollbackIntegrationTest`'s `@TestPropertySource`), **not Testcontainers**, so
running them does not contend for the shared reusable Postgres container.

**Already green at this commit** (read from the author's `target/surefire-reports/`, so not re-run here):
`HandlingUnitsDetailViewQueryShapeUnitTest` — 6/6, and `ViewDtoServiceHandlingUnitsRoutingUnitTest` — 21/21, both
`Failures: 0, Errors: 0`. No `Sdr*`/`*security*` report exists in that directory yet, so the §2 context pins have **not** been
executed at `c85e7949` by anyone; the queued run above is their first.
