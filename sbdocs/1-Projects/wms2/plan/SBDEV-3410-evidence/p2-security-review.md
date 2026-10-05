---
title: SBDEV-3410 P2 — security review of the StockrecordView SDR resource
ticket: SBDEV-3410
phase: P2
commit_reviewed: 1ec4f271
branch: feature/SBDEV-3410-p2-stockrecord-view-entity-sdr
worktree: /Users/np1076/dev/spk/owl/.claude/worktrees/wms2-api/SBDEV-3410
reviewed: 2026-09-21
lane: security
verdict: SHIP WITH ONE CHANGE — add the SdrFunctionRules entry (S1). Everything else passes.
---

# SBDEV-3410 P2 — security review

Reviewed `git diff origin/develop...HEAD` at commit `1ec4f271` (10 files, +1749/-10). Read-only lane;
no `mvn` run, no edits, no stash.

⚠ **Reviewed against the COMMIT, not the working tree.** At review time the tree carried one
uncommitted edit: `src/main/java/net/aim_ai/wms/repo/jpa/StockrecordViewRepository.java:101` reads
`LOWER(p.fromunitload)` where the commit has `LOWER(COALESCE(p.fromunitload, ''))`. That is the shape
of a sibling lane's in-flight mutation check, not a defect to report. It is authz-neutral either way.

## Verdict table

| # | Finding | Rating | New vs inherited |
|---|---|---|---|
| **S1** | No `SdrFunctionRules` entry — and §3.5's reasoning rests on the wrong fact. An unruled type is allowed at `ENFORCE_RULED`, the mode the programme rolls out to, not only at `OFF` | **Medium** | **New exposure** (new route, permanently ungated) |
| S2 | `findByKeyword&keyword=` is a full-table walk at ≤1000 rows/request over 9.7 M audit rows, unrate-limited | Low | **Inherited** — identical to `/v3/stockrecord/search/findByKeyword` |
| S3 | Both new comments name the route `/api/stockrecordView/{id}`. Real path is `/v3/...`, and `/api/**` is `permitAll` — so the comment invites the reader to conclude the DELETE was unauthenticated | Low (doc, security-reasoning) | New |
| S4 | `StockrecordView.java:52` names `PropertyReferenceException` for an unmapped `sort=`. Correct outcome (500), wrong exception for a `@Query` search | Info | New |
| — | Write verbs (Q2) | **PASS** | — |
| — | `findAll` suppression / unbounded routes (Q3) | **PASS** | — |
| — | Injection & parameter handling (Q4) | **PASS** | — |
| — | Tenant isolation (Q5) | **PASS** | — |

---

## Q1 — Exposure delta: what a `wms_user` can now reach

**Authentication is required.** `SecurityConfiguration.java:178` puts `/v3/**` behind
`hasAnyAuthority(Authority.WMS_USER_ROLE)`. The resource is not in the `permitAll` block at `:150-154`
and there is no `/api` alias for it (see S3). So the audience is *authenticated principals holding the
`wms_user` Keycloak role* — per the standing decision that everyone gets `wms_user` and functions are
the fine-grained axis, that is effectively every WMS user.

**Newly routed for that audience:**

| Route | Bound? |
|---|---|
| `GET /v3/stockrecordView/{id}` | one row; client-supplied `@Id` = the real `stockrecord.id`, so every one of 9.7 M rows is addressable |
| `GET /v3/stockrecordView/search/findByKeyword?keyword=&page=&size=` | paged, ≤1000/request (see Q3) |
| `GET /v3/stockrecordView/search/findByKeywordAndClient?keyword=&clientId=` | paged; **per-shipper filter is a new capability** — the legacy route has no `clientId` parameter |
| `GET /v3/stockrecordView/search` | search index (2 rels) |
| `GET /v3/profile/stockrecordView` | ALPS descriptor (schema, no data) |
| `GET /v3` → now lists `stockrecordView` | **unauthenticated** — `/v3` exactly is `permitAll` at `SecurityConfiguration.java:151`. Recon only (the hrefs themselves still 403). Inherited: every exported resource is on that index, and `SdrFunctionGuard`'s row-3 comment already records it as the §1.3 recon surface with zero callers |

**No new data class.** Every column in the view is already reachable by the same audience over SDR
today:

- all 24 `stockrecord` columns → `/v3/stockrecord/{id}` and `/v3/stockrecord/search/findByKeyword`
  (`StockrecordRepository` is `@RepositoryRestResource`, unruled)
- `item_name` → `/v3/itemdata` (`ItemdataRepository` exported, unruled)
- `cl_nr`, `cl_name` → `/v3/client` (`ClientRepository` exported, unruled)

So what P2 adds is **server-side correlation plus a shipper filter**: it saves a caller the three-way
join and the `client_id → cl_nr/cl_name` lookup they could already assemble. That is a real but small
widening of convenience, not of reach. **Inherited exposure, not a new one** — on the data axis.

**Is §3.5's reasoning sound? The fact is true; the inference is not.** See S1.

Verified directly, not assumed (2026-09-21):

```
dev_wh01_om1   los_sysprop WMS2_SDR_READ_GUARD_MODE = OFF
wh01_hydra_v2  los_sysprop WMS2_SDR_READ_GUARD_MODE = OFF   (stockrecord_view already present → P1 is on prd)
```

So "read enforcement is OFF everywhere measured" holds as committed. But it is the weaker half of the
story, and the half that carries the weight points the other way:

`SdrFunctionGuard.evaluate` **row 5** (`SdrFunctionGuard.java:281-294`) allows a domain type with no
rule at `SHADOW` **and at `ENFORCE_RULED`** — only `FAIL_CLOSED` denies (`mode.deniesUnruled()`). Its
own comment states the rollout mode: *"Slices 1-3 run at ENFORCE_RULED, so that is where a tenant
spends the entire rollout."* Therefore:

> An unruled resource is not "open until the flip". It is **open at every mode the programme plans to
> reach**, indefinitely, and nothing in the rollout will ever close it.

§3.5 argues from "enforcement is off today, so no new enforcement gap." The correct statement is "an
unruled type has no enforcement at any planned mode, so a new unruled type is a permanent new
ungated route." That is a new exposure, and it is the one thing in this diff I would change before
merge.

---

## Q2 — Write verbs: PASS

`RestConfiguration.java:536` adds `StockrecordView` to `SDR_WRITE_WITHDRAWN`.
`configureUnwrittenResourceWriteExposure` (`:551-556`) disables `WRITE_VERBS` =
`{POST, PUT, PATCH, DELETE}` (`:28-29`) on **collection, item and association** exposure. That is
every write axis SDR has for this resource.

**The entry is required, not parity — the comment is correct.**
`ReadOnlyPagingAndSortingRepository` (`repo/cinterface/`) overrides exactly `save(S)` and
`saveAll(Iterable)` with `@RestResource(exported = false)`, and extends `CrudRepository`, so
`deleteById` / `delete` / `deleteAll` are inherited un-suppressed. Without the withdrawal, item
DELETE would be routed against a VIEW.

**This is the sharpest edge in the change, and it is closed correctly.** `@Id` is the real
`stockrecord.id` and is **not** `@GeneratedValue` — `StockrecordView` deliberately does not extend
`AbstractBaseEntity`. So the item routes are fully addressable by a caller-chosen id, and — because
there is no `@Version` field either — `JpaMetamodelEntityInformation.isNew` falls back to the **id**
check rather than the version check. That is the opposite of the `Advice` case documented at
`RestConfiguration.java:600ff`: a body carrying only `id` would be treated as *not new* and take
`em.merge`. The withdrawal is what makes that unreachable, and it is the only thing that does.

Nothing else leaves a writable surface:

- **PUT-for-creation** — a sub-case of item PUT, already disabled by the `PUT` withdrawal.
  `configurePutForCreationWriteExposure` (`:356-368`) exists only for types that *keep* item PUT
  (`UserGroup`, `UserRole`, `Boxtype`, `Sysprop`); adding `StockrecordView` there would be redundant.
- **Item verbs** — `StockrecordView` is correctly absent from
  `configureMustStayWritableItemVerbWriteExposure` (`:840-864`) and from
  `configureMustStayWritableCollectionCreateWriteExposure`.
- **Associations** — the entity declares only basic-typed fields (`Long`, `String`, `Integer`,
  `BigDecimal`, `LocalDateTime`); no `@ManyToMany`/`@OneToMany`/`@ManyToOne`. SDR generates no
  association resource, so `/v3/stockrecordView/{id}/{property}` does not exist. The
  `withAssociationExposure` line is future-proofing, exactly as its comment says.
- **`count` / `existsById`** — inherited from `CrudRepository`, not routed by SDR.

Rail: `SdrWriteWithdrawalContextTest` now asserts `hasSize(50)`, carries `"StockrecordView"` in
`WITHDRAWN`, and — correctly — moves the collection-GET carve-out from a single `STOCK_VIEW` constant
to `COLLECTION_GET_ABSENT_BY_REPOSITORY_SHAPE = Set.of("StockView", "StockrecordView")` with the rule
written down ("withdraws all three `findAll` overloads") rather than a name added by reflex. The ITEM
GET assertion still applies to both, so the carve-out is not an exemption from the rail.

---

## Q3 — `findAll` suppression and unbounded collections: PASS

All three overloads carry `@RestResource(exported = false)`. **One would have been enough** — SDR's
`DefaultCrudMethods` selects a single `findAll` (preferring `findAll(Pageable)`) and
`CrudMethodsSupportedHttpMethods` adds collection GET only if *that* one is exposed — but annotating
all three is the right defence: it closes the `?sort=` collection path critic M3 named on
`StockViewRepository` and survives a change to that selection order. The context test verifies the
outcome at runtime rather than inferring it.

Swept for every remaining route that could return more than one row:

| Candidate | Status |
|---|---|
| `GET /v3/stockrecordView` (collection) | **405** — no exposed `findAll`, verified by the context test |
| `GET /v3/stockrecordView?sort=x` | **405** — same handler; this is the `findAll(Sort)` bypass, closed |
| `search/findByKeyword`, `search/findByKeywordAndClient` | `Page<>`, capped — see below |
| Projections / excerpt projections | **none exist.** `grep -rln StockrecordView src/main/java` → only the entity, its repository and `RestConfiguration`. No `@Projection`, no `excerptProjection` |
| Association resources | **none** — no association-typed fields (Q2) |
| `/api` vs `/v3` alias | **no alias.** Base path is `/v3` (`RestConfiguration.java:25`); no `server.servlet.context-path` in any `src/main/resources/application*.properties`; the only `/api`-mapped handlers are `PublicVersionController` and `TenantDiscoveryController` |

**Page cap.** Nothing configures it — `grep -rn "setMaxPageSize\|setDefaultPageSize\|max-page-size" src/main/java src/main/resources` returns **zero hits** — so SDR's default `maxPageSize = 1000` applies and `size=999999` yields ≤1000 rows. The cap is real but it rests on an unset framework default rather than on anything this repo states.

### S2 (Low, inherited) — paged full-table walk

`keyword=` (empty) short-circuits the CONCAT via the `or :keyword = ''` arm and returns every row.
At 1000 rows/request that is ~9,727 requests to drain the entire 9.7 M-row audit log, and there is no
rate limiter anywhere in the stack. **Inherited, not introduced**: the legacy
`/v3/stockrecord/search/findByKeyword` has no `= ''` escape but its `LIKE '%%'` matches every non-null
row anyway, so the same walk exists today on the route this report uses. Not a blocker for P2; worth
one line in the ticket so it is not discovered as new later.

---

## Q4 — Injection and parameter handling: PASS

Both searches are JPQL `@Query` methods with `@Param`-bound named parameters, so every operand reaches
the database through `TypedQuery.setParameter` — no string assembly anywhere in the path.

- **`keyword`** appears only as a bind value inside `LOWER(concat('%', :keyword, '%'))`. The only
  metacharacters that do anything are the LIKE wildcards `%` and `_`, and they can only *broaden* a
  match inside a result set the caller already has unrestricted access to (`keyword=` already returns
  everything). No `ESCAPE` clause is declared, so `\` is literal on PostgreSQL's default — a
  correctness nuance, not a security one.
- **`clientId`** is a bound `Long`. `clientId=abc` →
  `QueryMethodParameterConversionException` → **400** via `RestExceptionHandler.java:278`, which
  deliberately does not echo the rejected value into the response and clamps it in the log with
  `LogFormatUtils.formatValue(..., 100, true)` (CRLF-escaped, 100 chars) — that handler is already
  hardened against log forging.
- **`clientId` omitted** → bound `null` → `p.clientId = null` → **zero rows**. It does **not** fall
  back to unfiltered, so the two-method split is not a filter-bypass shape. (The `Long` is boxed, so
  this is not the omitted-*primitive* 500 case `SdrOmittedPrimitiveParamSearchContextTest` covers.)
- **`sort=`** — not exploitable. Spring Data JPA's `QueryUtils.checkSortExpression` rejects any sort
  property containing punctuation other than `.` and `_` **before** it is appended, and nothing in
  `src/main` uses `JpaSort.unsafe` (`grep -rn JpaSort src/main/java` → zero hits). So
  `sort=id);DROP TABLE…` is rejected, not interpolated. A well-formed but *unmapped* property (e.g.
  `sort=itemdata2`) is appended textually to the declared JPQL and fails at query parse → **HTTP 500**.
  Nothing leaks in that 500: `server.error.include-message` / `include-stacktrace` are unset (Boot
  default `never`) and `RestExceptionHandler` declares no `@ExceptionHandler(Exception.class)`
  catch-all. The UI cannot trigger it — all nine `sortable: true` headers map to declared fields.

### S4 (Info) — exception name in the entity javadoc

`StockrecordView.java:52` states an unmapped `sort=` throws `PropertyReferenceException`. That is the
shape for a **derived** query or a collection `findAll`; for these two `@Query` searches the sort is
applied textually by the query enhancer and the failure is a JPQL parse error. The stated *outcome*
(HTTP 500, not a graceful fallback) is correct and is the load-bearing part — but the exception name
is the kind of claim a future reviewer greps for.

---

## Q5 — Tenant isolation: PASS, confirmed on all three axes

**Persistence unit.** `TenantDatabaseConfig.java:83` scans `.packages("net.aim_ai.wms.model")` and
names the unit `"tenant"` (`:84`). `LandlordDatabaseConfig.java:54-55` scans
`.packages("net.aim_ai.wms.landlord.model")` / `.persistenceUnit("landlord")`. The two are **disjoint**,
and `StockrecordView` is in `net.aim_ai.wms.model` — so the landlord EntityManager cannot resolve the
type at all, let alone read through it.

**Repository binding.** `TenantDatabaseConfig.java:22-25`:
`@EnableJpaRepositories(basePackages = "net.aim_ai.wms.repo.jpa", entityManagerFactoryRef = "tenantEntityManagerFactory", transactionManagerRef = "tenantTransactionManager")`.
`StockrecordViewRepository` is in that package; landlord's `@EnableJpaRepositories` scans only
`net.aim_ai.wms.landlord.jpa`. So the tenant EMF **and** the tenant TM are bound by package
declaration — the `@Primary` landlord TM is never reachable here. The repository declares no
`@Transactional` of its own, which is correct (CLAUDE.md's stated exception for `repo.jpa`).

**The relation itself.** `V2.2.33__stockrecord_view.sql:100-131` reads only `public.stockrecord`,
`public.itemdata`, `public.client` — three tables inside whichever tenant database
`TenantDynamicRoutingDataSource` selected. No `dblink`, no `postgres_fdw`, no cross-database
reference. It is a plain `CREATE OR REPLACE VIEW` with no `security_invoker` / `security_barrier`
option and no `SECURITY DEFINER` function in the path, and no RLS is in play on these tables — so it
carries no privilege of its own and nothing is elevated by reading through it.

**Column sensitivity.** The four joined columns are `itemdata.id`, `itemdata.name`, `client.cl_nr`,
`client.name`. No credential-shaped column is projected — this is not the `los_sysprop` /
`tenant_auth_configuration` shape.

**The test's `unitName = "tenant"` is correct and load-bearing** exactly as
`StockrecordViewHalContextTest`'s javadoc says: a bare `@PersistenceContext` resolves the `@Primary`
landlord EM, which does not map this entity, so the seed would throw or write where the request does
not read.

Conclusion: **nothing here can read across tenants**, and the change introduces no new isolation axis —
it reuses the one every other tenant entity uses.

---

## Q6 — Should `StockrecordView` carry an `SdrFunctionRules` entry?

**Yes. I disagree with plan §3.5 and would add the entry before merge.** Seven grounds, in the order
I find them persuasive:

**1. The codebase has already priced this data, and priced it higher.**
`ReportController.java:249` gates `POST /v3/report/exportStockUnitRecord` — the CSV of this exact
report — on `@RequiresFunction(WmsConstants.FunctionEnum.WEB_UI_VIEW_STOCK_UNIT_RECORD)`. P2 adds a
second, *richer* path to the same rows (the export does not carry `cl_name`/`item_name`) with no gate
at all. One ticket now owns both halves of that asymmetry.

**2. The rule costs zero human users on prd.** Measured 2026-09-21, counting **USERS, not roles**:

| DB | total users | hold `WEB_UI_VIEW_STOCK_UNIT_RECORD` | control: `WEB_UI_VIEW_SYSTEM_PROPERTY` |
|---|---|---|---|
| `dev_wh01_om1` | 100 | **45** | 37 |
| `wh01_hydra_v2` (only v2 PRD tenant) | 9 | **7** | 7 |

Both controls reproduce the figures `SdrFunctionRules`' own Sysprop comment records for these two
databases (37 on dev, 7 on hydra prd), which is what validates the access-chain join
(`mywms_group_mywms_user` → `mywms_group_mywms_role` → `mywms_role_mywms_function` → `mywms_function`;
note the `grouplist_id`/`rolelist_id`/`functionlist_id` column naming).

On prd the **only two** principals that would be denied are `anonymous` (id 1) and `oms_integration`
(id 106197). Neither consumes this report, and OMS reads over `/rest/**`, a different surface. The
route is brand new, so it has no callers at all outside the UI.

**3. It changes nothing live, today.** Both tenants are at `WMS2_SDR_READ_GUARD_MODE = OFF` (queried,
not assumed). Shipping a rule ahead of the flip is precisely the argument `SdrFunctionRules` makes for
its own `Sysprop` entry: *"it closes the hole for whenever a tenant is switched to ENFORCE_RULED …
which is the entire point of this programme shipping rules ahead of that flip."* A zero-risk, one-line
addition.

**4. Without it, the route is never gated.** Row 5 allows unruled types at `ENFORCE_RULED` (Q1). No
future step of the rollout closes this; only a rule does, or `FAIL_CLOSED`, which the row-5 comment
explains is not reachable while 28 types are unruled.

**5. The precedent is established and named.** Gating an SDR route on its **screen's** existing
`WEB_UI_VIEW_*` function is SBDEV-3017 §9.16 Option B, and `WEB_UI_VIEW_STOCK_UNIT_RECORD` is exactly
that function — `pages` gates the Stock Unit Record screen on it, and the UI is the only caller.

**6. The mechanism already reaches SDR.** `WebConfig#functionGuardMappedInterceptor` registers the
gate as a `MappedInterceptor` **bean**, which every `AbstractHandlerMapping` — including SDR's —
picks up via `detectMappedInterceptors`; measured for `GET /v3/itemdata/search/findByItemNr`. Nothing
new has to be built.

**7. No boot risk.** `SdrRuleStartupAssertion.findStaleRules` fails the boot for a rule on an
**un-exported** type; `StockrecordView` is exported, so that rail is satisfied. The assertion also
validates each rule's function-name strings against `WmsConstants.FunctionEnum` by reflection, and
`WEB_UI_VIEW_STOCK_UNIT_RECORD` is a declared constant (`ReportController` already uses it), so a typo
cannot slip through either.

### The change

```java
// in SdrFunctionRules.productionRules()
rules.put(net.aim_ai.wms.model.StockrecordView.class,
          ordered(WmsConstants.FunctionEnum.WEB_UI_VIEW_STOCK_UNIT_RECORD));
```

Use `ordered(...)`, not `Set.of(...)` — that is the M1 fix recorded in its javadoc: `Set.of`'s
iteration order is unstable across JVM restarts, so `functions[0]` (which becomes the
`X-Authz-Denied` header, the `requiredFunction` body field, the WARN log and the metric tag) would
differ between replicas. Single-element sets make it unobservable today; use the helper anyway.

**One arithmetic follow-on:** `SdrFunctionGuard.evaluate`'s row-5 comment writes out
`35 exported - 7 ruled = 28 unruled` and instructs the reader to redo the sum when the ruled set
changes. Adding this rule makes it 36 exported − 8 ruled = 28 unruled — the exported count moves too,
because `StockrecordView` is itself new. Update that comment in the same commit, or it becomes the
fourth drift its own text complains about.

### What the rule does NOT do — stated plainly

The legacy `/v3/stockrecord/search/findByKeyword` stays ungated and serves the same audit log to
everyone. So this rule does **not** close the data today; it closes the *new* path, and it is what
makes P6's retirement of the legacy route actually mean something. If the intent is to close the data
rather than the route, `Stockrecord` needs the same rule — but that type has other callers, so it is a
separate proposal and not a rider on P2. Likewise `Itemdata` and `Client` remain exported and unruled,
which is where `item_name` / `cl_name` are reachable independently; that is Slice 4's scope, inherited,
and out of this ticket's.

---

## S3 (Low) — the `/api/` path in the new comments

Two places, both added by this commit:

- `RestConfiguration.java:535` — *"SDR routes `DELETE /api/stockrecordView/{id}`"*
- `SdrWriteWithdrawalContextTest` javadoc — the same sentence

The real path is `DELETE /v3/stockrecordView/{id}` (`RestConfiguration.java:25`,
`config.setBasePath("/v3")`; no `server.servlet.context-path` anywhere in `src/main/resources`).

This is worth fixing rather than shrugging at, because `SecurityConfiguration.java:151` makes
**`/api/**` `permitAll`**. A reviewer who takes the comment literally and checks whether that DELETE
required a token would land in the permitAll block and conclude the route was reachable with no
authentication at all — a two-step path from a typo to a wrong severity. Change both to `/v3/`.

---

## What I checked and found clean (no finding)

- `/v3/**` requires `wms_user`; the resource is not in the `permitAll` block and has no `/api` alias.
- SDR endpoints are **not** in the unauthenticated `/api-docs` — `pom.xml` carries only
  `springdoc-openapi-starter-webmvc-ui`, no `springdoc-openapi-starter-data-rest`, so the repository
  methods are not documented. (The `@Hidden` annotations on `ReadOnlyPagingAndSortingRepository` are
  inert here.)
- No `@ExceptionHandler(Exception.class)` catch-all in `RestExceptionHandler`; `include-message` and
  `include-stacktrace` unset, so no 500 on these routes echoes a message or a stack.
- No `@PublicHandler`, no `@PreAuthorize`, no `permitAll` touching this resource.
- The entity declares no `@Version` and no `@GeneratedValue` — correct for a view, and
  `StockrecordViewEntityContractUnitTest` asserts the `AbstractBaseEntity` negative, which is the
  right instrument (extending it compiles and boots).
- View cardinality / join-elimination reasoning is a correctness and performance matter, not authz;
  not re-reviewed here beyond confirming the view exposes no privileged column.

## The floor, for this lane

- **DB query confirming the premise:** `WMS2_SDR_READ_GUARD_MODE` read directly on `dev_wh01_om1` and
  `wh01_hydra_v2` (both `OFF`), plus the user-population counts in Q6 — with a positive control on
  each (`WEB_UI_VIEW_SYSTEM_PROPERTY` = 37 / 7, matching the figures `SdrFunctionRules` records) so a
  broken join could not read as a true zero.
- **Independent review:** this lane. Not self-approved — the author's lane is separate.
- No test was written or run by this lane (read-only, `mvn` forbidden). S1's fix, if taken, needs its
  own failing test: assert `SdrFunctionRules.requiredFunctions(StockrecordView.class)` is present and
  equals `WEB_UI_VIEW_STOCK_UNIT_RECORD`, and mutation-check it by removing the `rules.put` line.
