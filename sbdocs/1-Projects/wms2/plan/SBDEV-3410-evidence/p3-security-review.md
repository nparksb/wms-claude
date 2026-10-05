---
title: SBDEV-3410 P3 — security review
ticket: SBDEV-3410
phase: P3 (Stock Unit Record export — shipper filter)
commit: 56089a41
base: origin/develop f2ee75f1
worktree: /Users/np1076/dev/spk/owl/.claude/worktrees/wms2-api/SBDEV-3410-p3
branch: feature/SBDEV-3410-p3-export-shipper-filter
reviewer: p3-security-review lane
date: 2026-09-22
verdict: PASS — no new exposure shipped. 0 High, 0 Medium, 4 Low, 3 Informational.
---

# SBDEV-3410 P3 — security review

## Verdict

**This commit ships no new exposure.** Every finding below is either an **inherited** condition
(present on `origin/develop`, untouched here) or a **narrowing**. The one thing that could have gone
wrong — publishing a new Spring Data REST search — did not: the new repository method carries
`@RestResource(exported = false)`, which is the correct and (per the codebase's own SDR mechanism
inventory) the *only* effective lever on an SDR search path.

Scope reviewed: `git diff origin/develop...HEAD` at `56089a41` — 3 `src/main` files, 5 test files.
No `mvn` was run (concurrent-Maven false-red rule). No files were modified. All DB evidence is from
`nywh-hydra-uat` via read-only `SELECT`.

| # | Finding | Severity | New or inherited |
|---|---|---|---|
| L-1 | `catch (Exception)` echoes `e.getMessage()` into a **200** body; for a data-access failure that message embeds the executed SQL | Low | **Inherited** (develop, unchanged) |
| L-2 | `offset` / `limit` are caller-controlled with **no bound** — no `checkPageBounds`, no clamp | Low | **Inherited** |
| L-3 | The `exported = false` withdrawal is pinned only at the **annotation** level, never at the `SearchResourceMappings` level | Low | New (test-coverage gap, not an exposure) |
| L-4 | `LOG.debug("start export with id ={}", reqMap.toString())` now logs the `filter` value too | Low | **Inherited** shape, marginally widened |
| I-1 | `GET /v3/stockrecord/search/findByOffsetAndLimit` is exported, **ungated**, and has **no HTTP caller** in either UI | Info | **Inherited** (P6/Q5 owns it) |
| I-2 | The premise "the pre-fix code would throw `ClassCastException`" is **false for this endpoint on develop** — it never read `filter`. The live shape is in the 7 siblings | Info | Correction |
| I-3 | The web UI's own filter fold is `this.filter && …` — **truthiness** — so shipper id `0` would collapse to "All Shippers" in the UI even though the backend now handles it correctly | Info | Forward risk for the UI phase |

---

## 1. Native SQL injection — no vector

**Answer: every caller-supplied value arrives as a bound parameter. Nothing is interpolated.**

`NATIVE_KEYWORD_CLAUSE` is a `String` constant initialised from a string literal
(`StockrecordRepository.java`), so it is a **compile-time constant expression**. The `@Query` value is
`"SELECT …" + "WHERE" + NATIVE_KEYWORD_CLAUSE + "order by …" + "offset :offset limit :limit"` — all
four operands are constants, folded by `javac` into a single literal in the class file. There is no
runtime concatenation, no method parameter, and no request value anywhere in the SQL **text**. The
"assembled by String concatenation" phrasing in the task describes the *source form*, not a dynamic
query builder: nothing reaches the SQL text at runtime.

Every value that varies is a JPA named parameter bound by `@Param`:

- `:keyword` → `@Param("keyword") String keyword`
- `:clientId` → `@Param("clientId") Long clientId`
- `:offset`, `:limit` → `@Param("offset") int`, `@Param("limit") int`

**`CAST(:clientId AS bigint)` is not a vector.** The cast operates on the *bound placeholder*, not on
text. pgjdbc sends `$n` and PostgreSQL applies the cast to the received value; a hostile string cannot
reach the parser, and in any case the Java type is `Long`, so nothing string-shaped exists at that
point. The cast is present for a different reason (bare binds inside a native comparison can draw
*"could not determine data type of parameter"*), and that reason is sound — `StockViewRepository`
carries the same form. **The cast reduces risk of a runtime type failure; it adds none.**

**`offset :offset limit :limit` are bound**, so no injection there either. But they are *unbounded*
(→ **L-2**):

- Negative `offset` — PostgreSQL rejects it. Measured on `nywh-hydra-uat`:
  `SELECT id FROM client ORDER BY id LIMIT 1 OFFSET -1` → `ERROR: OFFSET must not be negative`.
  In the controller that error is raised **inside** the `try`, so it lands in `catch (Exception e)`
  and becomes a 200 with an error body (→ **L-1**), not a 500. Not exploitable beyond L-1.
- Huge `limit` — nothing clamps it. `ReportController` never calls the inherited
  `AdminController.checkPageBounds` (grep: zero call sites in that file), and `api.paging.max-size`
  is injected into other controllers but is not applied to any `/report/export*` handler. A caller
  holding `WEB_UI_VIEW_STOCK_UNIT_RECORD` can ask for `limit: 100000000`; the service materialises the
  whole `List<Stockrecord>` in heap and builds an .xlsx from it. This is a **resource-exhaustion
  footgun available to an authorised operator**, not a privilege issue.

**Both are entirely inherited**: `offset`/`limit` were already caller-controlled and unbounded on
`origin/develop`, and P3 changes neither their read nor their path. **No fix is owed in this PR.** If
you want the clamp, it belongs on all eleven `/report/export*` handlers at once, as its own ticket.

## 2. A NEW unexported route — correctly withdrawn

**Answer: `exported = false` genuinely withdraws it from SDR; it is not merely a Swagger hint.**

The premise in the task is right and load-bearing: `RestConfiguration.java:891` sets
`RepositoryDetectionStrategies.ANNOTATED`, `StockrecordRepository` carries
`@RepositoryRestResource(collectionResourceRel = "stockrecord", path = "stockrecord")`, and
`Stockrecord` is in `SdrUncalledSurfaceNotExportedContextTest.MUST_REMAIN_EXPORTED` — the resource is
live. **A query method on it therefore exports by default**, and omitting the annotation would have
published `GET /v3/stockrecord/search/findByClientOffsetAndLimit`. The commit does not omit it.

Mechanism check, not annotation-reading: `@RestResource` is `org.springframework.data.rest.core.annotation`
— Spring Data REST's own, not an OpenAPI annotation, and nothing in `OpenApiConfig` reads it. SDR
builds `SearchResourceMappings` from the repository's query methods and **`SearchResourceMappings`
contains only exported methods** — the codebase states this itself at
`SdrMutatingSearchNotExportedContextTest:130`, and that class's `getSearchResourceMappings(...)`
iteration is the existing instrument for exactly this property. At method level the withdrawal is
*scoped to that finder* and does not touch item/collection exposure, which is precisely the desired
shape here (the entity must stay readable).

**No other surface exposes it:**

- **Path aliases** — the SDR base path is `/v3` and nothing else (`MY_BASE_URI_URI = "/v3"`,
  `config.setBasePath` at `RestConfiguration.java:873`; no `spring.data.rest.*` properties exist in
  `src/main/resources`). The `/api/**` entries in `SecurityConfiguration.java:151-153` are
  Swagger/actuator permit-all paths, not a second SDR mount.
- **Projections** — projections expose entity *properties*, never repository methods. The method
  returns `List<Stockrecord>` (the entity itself), so no projection can surface it.
- **Associations** — association resources are derived from entity relationships, not query methods.
- **MVC** — no controller references `findByClientOffsetAndLimit`; the only caller in
  `src/main` is `ReportService.java` (grep across `src/main`: one hit).

**Severity: none.** This is the correct call and it follows the repo's own rail (a search with no HTTP
caller is withdrawn, not ruled).

**L-3, the one gap:** the withdrawal is asserted only by reflection —
`StockrecordExportQueryContractUnitTest.filteredExportIsUnexportedAndUsesAPlainEquality` reads
`filtered.getAnnotation(RestResource.class).exported()`. That grades the **annotation**, not SDR's
resolved mapping. None of the three existing context-level rails would catch a regression here:
`SdrUncalledSurfaceNotExportedContextTest` works at domain-type granularity and lists `Stockrecord` as
must-remain-exported; `SdrMutatingSearchNotExportedContextTest` covers mutating searches only; and
`SdrNonEntityCollectionSearchNotExportedContextTest` covers non-entity collections, whereas this
returns an entity collection. So if someone later drops the annotation, the reflection test fails
(good) — but if some future config re-exported it *with* the annotation still present, nothing would
notice. **Low**, and a coverage note rather than a defect: the cheap close is one extra assertion in
the existing `SdrMutatingSearchNotExportedContextTest` style asserting
`mappings.getSearchResourceMappings(Stockrecord.class)` has no mapping named
`findByClientOffsetAndLimit`. Worth doing; not a blocker.

## 3. The LIVE route — exposure and behaviour both unchanged

**Answer: unchanged. Verified independently of the commit's own test.**

I reconstructed the rendered `@Query` text on both sides by resolving the constant myself (Python
tokenise of the annotation expression at HEAD with `NATIVE_KEYWORD_CLAUSE` substituted, against
`git show origin/develop:…StockrecordRepository.java`). Both render, byte for byte:

```
SELECT * FROM Stockrecord p WHERE (CONCAT(LOWER(p.activitycode), ' ', LOWER(p.fromstoragelocation), ' ', LOWER(p.fromunitload), ' ', LOWER(p.itemdata), ' ', LOWER(p."operator")) LIKE LOWER(concat('%', :keyword,'%')) or :keyword = '') order by p.created DESC offset :offset limit :limit
```

Identical → `True`. That is a **second instrument** agreeing with
`unfilteredExportQueryTextIsByteIdentical`, derived without reading that test's expected literal.

- **Signature unchanged**: `findByOffsetAndLimit(String keyword, int offset, int limit)` — the diff
  adds no parameter, so **there is no new value an SDR caller can supply** on that route. This was the
  sharpest question and the answer is clean: a new bind parameter on an exported search would have
  become a new query-string knob, and none was added.
- **Exposure unchanged**: still `@RestResource(path = "findByOffsetAndLimit", rel = ...)` with no
  `exported` attribute, and the commit's test pins `exported()` as `true` with an explicit note that
  withdrawing it is Q5/P6's job. Correct scoping — withdrawing a live route inside a filter PR is how
  you ship a broken grid.
- The design decision **not** to add the predicate in place is right, and for a security reason beyond
  the perf one: a null-bound `Long` makes `AND (CAST(:clientId AS bigint) = -1 OR p.client_id = …)`
  evaluate to NULL, so the route would return `[]` **silently**. A silent empty result on a live
  reader is a worse failure than an error.

## 4. Authorization — unchanged, and this endpoint was NEVER client-scoped

**Answer: the gate is byte-identical, and a caller cannot escalate through the new parameter, because
there is nothing to escalate *from* — the export has always returned every shipper's rows.**

`@RequiresFunction(WmsConstants.FunctionEnum.WEB_UI_VIEW_STOCK_UNIT_RECORD)` sits at
`ReportController.java:249` at HEAD and at the identical position in
`git show origin/develop:…ReportController.java`. Unchanged.

**It still applies to the inherited `/v3/dashboard/exportStockUnitRecord` route.**
`DashboardController extends ReportController` (`DashboardController.java:26`) with
`@RequestMapping("/v3/dashboard")`, so the handler is reachable under both prefixes. The gate is
enforced by `FunctionGuardInterceptor`, registered as a broad `MappedInterceptor` bean over `/**` by
`WebConfig` — deliberately annotation-driven rather than path-driven, so a route moving prefix cannot
escape it. Resolution is `handlerMethod.getMethodAnnotation(RequiresFunction.class)`
(`FunctionGuardInterceptor.java:237`), which delegates to `AnnotatedElementUtils.findMergedAnnotation`
on the **declared** method — `ReportController#exportStockUnitRecord` — so the inherited handler on
`DashboardController` resolves the same annotation. Both routes are gated on the same function.

**Was it ever client-scoped? No — and I want this stated rather than assumed.** Evidence, three ways:

1. **Nothing derives a client from the caller.** `User.clientId` exists on the entity
   (`User.java:58`), but across 118 `getClientId()` call sites in `src/main` none is used in an
   authorization decision or as a query predicate on the caller's behalf. The uses are display/lookup
   (`ClientService:113`, `UserService:178`, `UserGroupService:118`) and one write
   (`MessageService:95`). `SecurityContextUtils` has no client concept at all; neither
   `JwtAccessTokenCustomizer` nor `SecurityConfiguration` mentions `clientId`.
2. **The pre-fix query has no client predicate.** `findByOffsetAndLimit` (unchanged, text above)
   filters on keyword only. The export therefore returned **all shippers'** rows before this commit.
3. **The parameter is a filter, not a scope.** `clientId` is read from the request body and passed
   straight through; it is never compared against the principal. That is the same established pattern
   already in `UnitLoadController:226` and `StockUnitController:753`, both of which call
   `toFilterId(clientId)` on a caller-supplied value.

So: **a caller who holds the function could already read every shipper's rows. The filter can only
return a subset of what they were already entitled to. This is a narrowing, not a widening.** A caller
who passes "a different `clientId`" gains nothing they did not already have, and a caller who holds no
function gets 403 at the interceptor before any of this runs. This is the correct model for a WMS —
it is warehouse-operator facing, one deployment per warehouse DB, with shipper as a *business* axis
rather than a tenancy boundary. If per-shipper scoping is ever wanted it is a new feature across the
whole surface, not a P3 concern.

## 5. Information disclosure through the filter — no real change

**Answer: no practical enumeration primitive, and nothing here is new.**

Measured on `nywh-hydra-uat`: `client` holds **138** rows, including **id 0** (System-Client) —
which independently confirms the `0 is a real shipper` premise the service's fold rests on. Running
the shipped filtered predicate with a nonexistent id returned **0 rows, no error**:

```sql
SELECT count(*) FROM Stockrecord p
WHERE (CONCAT(LOWER(p.activitycode), … ) LIKE LOWER(concat('%','','%')) or '' = '')
  AND p.client_id = CAST(999999999 AS bigint)   -- → 0
```

So "client exists" and "client exists but has no stock records" are **indistinguishable**: both yield
an empty spreadsheet with the same 200 and the same 15 headers. There is no error/no-error oracle and
no message that names the client. The only signal is non-empty vs empty, which means *"this id has
stockrecord rows"* — and a caller who can learn that can already dump every row unfiltered and read
`client_id` off them. **The filter gives an attacker strictly less information than the unfiltered
export they already have.** Not a finding.

Worth noting for completeness: `Client` is itself an exported SDR resource (it is in
`MUST_REMAIN_EXPORTED`), so the shipper list is directly readable over `/v3/client` by any
authenticated user — enumeration does not need this endpoint and is not made easier by it. That is
inherited and out of P3's scope.

## 6. The `(String)` cast → 500 — the premise needs correcting, and the real exposure is elsewhere

**I-2, correction.** The task states *"the pre-fix code would throw `ClassCastException` out of the
handler on a JSON-number `filter`"*. For **this endpoint** that is not what `origin/develop` does:
`exportStockUnitRecord` at develop reads only `offset`, `limit` and `keyword` — **it never reads
`filter` at all** (`git show origin/develop:…ReportController.java`, lines 254-256). A JSON-number
`filter` was silently ignored. So there was **no pre-fix 500 here**; the `ClassCastException` is the
failure mode of the *natural implementation* P3 deliberately avoided, which is what the commit's
comment and `numericFilterIsForwarded` actually describe. The distinction matters because it means P3
**introduces the `filter` read and does so in the safe form from the start** — there is no window in
which the endpoint 500s.

**What the 500 would have leaked, had it landed.** Not much, and I checked rather than assumed:

- `ReportController` is in package `net.aim_ai.wms.controller`. The two `@ExceptionHandler(Exception.class)`
  advices are package-scoped elsewhere — `@ControllerAdvice(basePackages = "net.aim_ai.wms.controller.rest")`
  and `…".controller.mobile"` — so **neither covers this controller**. A `ClassCastException` would
  fall through to Boot's `BasicErrorController`.
- No `server.error.include-stacktrace`, `include-message`, `include-exception` or
  `include-binding-errors` property exists anywhere in the repo (grep over all `*.properties`,
  `*.yml`, `Dockerfile*` → zero hits), so Boot 3 defaults apply: **`NEVER` for both stacktrace and
  message**. The body would have been the generic
  `{timestamp, status: 500, error: "Internal Server Error", path}`.
- Conclusion: the pre-fix shape would have been a **500 with no stack trace, no SQL and no internal
  path beyond the request URI** — an availability bug, not an information leak.

**The live instance of that shape is the seven siblings, and they are not exploitable today.** All
seven untouched `(String) reqMap.get("filter")` reads are at `ReportController.java:66, 93, 121, 148,
175, 202, 229` (count confirmed; there are also three commented-out copies at 443-446). Each sits
above its own `try`, so each would 500 the same way. **They are safe right now because the UI sends a
string**: `components/reports/popups/exportReport.vue:136` builds
`filter: this.filter && this.filter != 'All Shippers' ? this.filter : null`, and the shipper selects
bind `item-value="clNr"` (e.g. `inventoryReport.vue:30-31`) — a client *number*, not an id. So the
risk is **forward-looking**: if a later phase switches any of those pages to `item-value="id"`, that
export starts 500ing. That is a real trap worth a line on the ticket; it is **not** a defect this PR
introduces and it is **not** in P3's scope to fix.

**I-3, a forward finding the UI phase needs.** `exportReport.vue:136` folds with `this.filter &&` —
**truthiness**. P3's backend fold is correct (`clientId == null || clientId == -1L`, with `0L`
explicitly graded), but the moment the UI passes a numeric shipper **id**, `0` (System-Client, present
on Hydra UAT as measured above) is falsy in JavaScript and the UI collapses it to `null` → `-1L` →
"All Shippers", **exporting every shipper's rows when System-Client is selected**. That is exactly the
SBDEV-3437 defect class, one layer above where P3 fixed it. The backend is not at fault and the
`ReportController` comment is right that the API must not depend on the UI's fold — but the UI phase
must change that `&&` to an explicit `!= null && != -1` check, or the defect ships anyway.

## 7. Findings in fix-priority order

1. **L-3 (Low, in scope, cheap)** — add one `SearchResourceMappings`-level assertion that
   `findByClientOffsetAndLimit` is absent from `Stockrecord`'s search mappings, alongside the existing
   annotation pin. One assertion in the shape `SdrMutatingSearchNotExportedContextTest` already uses.
   This is the only item I would consider adding to this PR.
2. **I-3 (Info, blocks the UI phase)** — carry a note to P4/P5: `exportReport.vue:136`'s truthiness
   fold must become an explicit `-1`/null check before a numeric shipper id is sent, or shipper `0`
   silently exports everything.
3. **I-2 (Info, ticket note)** — the seven sibling `(String) reqMap.get("filter")` reads are a latent
   500 that activates if any report page moves to `item-value="id"`. Cheapest durable fix is the same
   `toFilterId(String.valueOf(...))` form P3 uses, applied to all seven — a separate small ticket, not
   this PR.
4. **L-1 / L-2 / L-4 (Low, inherited, out of scope)** — the `e.getMessage()` echo into a 200 body
   (for a data-access failure Hibernate 6's message embeds the executed SQL, so this path can return
   server SQL to the caller — derived from code, not executed, since this lane may not run `mvn`), the
   unbounded `offset`/`limit`, and the `LOG.debug` of the whole request body. All three predate this
   commit and are unchanged by it. Each belongs to a sweep across all eleven `/report/export*`
   handlers if you want it at all.
5. **I-1 (Info, already owned)** — `GET /v3/stockrecord/search/findByOffsetAndLimit` is exported,
   has **zero** HTTP callers in either UI (`git grep` across `v2/wms2-web-ui` and
   `v2/wms2-mobile-ui`: no hits), and is **not function-gated**: SDR handlers declare
   `RepositoryEntityController`, which is absent from `FunctionGuardInterceptor`'s `GUARDED` set, and
   `SdrFunctionRules` carries no rule for `Stockrecord` while `SdrGuardModeProvider` defaults to
   `OFF` (and only `FAIL_CLOSED` denies an unruled type). So the export's underlying rows are readable
   over SDR by any authenticated `wms_user` **without** `WEB_UI_VIEW_STOCK_UNIT_RECORD`. Entirely
   inherited, and the plan already books the withdrawal as Q5/P6 — which is the right resolution and
   the right PR for it.

## 8. Method and limits

- Read-only throughout. No `git checkout`/`restore`/`stash`/`reset`, no edits, no `mvn`.
- Independent instruments used: my own constant-resolution render of both `@Query` texts (§3); a
  `git show origin/develop` diff of the authorization annotation (§4); grep censuses of
  `getClientId()`, `(String) reqMap.get`, `toFilterId` and `checkPageBounds` call sites; four
  read-only `SELECT`s on `nywh-hydra-uat` (§1, §5).
- **Not verified by execution** (no Maven in this lane): the exact wrapper class and message text of
  the data-access exception in L-1, and the runtime `SearchResourceMappings` state asserted in L-3.
  Both are stated as derived from code and marked as such. Neither changes the verdict.
