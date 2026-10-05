# SBDEV-3410 P3 — code review

- **Commit under review:** `56089a41` "SBDEV-3410 P3: the Stock Unit Record export respects the shipper filter"
- **Worktree:** `/Users/np1076/dev/spk/owl/.claude/worktrees/wms2-api/SBDEV-3410-p3`
- **Branch:** `feature/SBDEV-3410-p3-export-shipper-filter`, branched off `origin/develop @ f2ee75f1`
- **Plan:** `sbdocs/1-Projects/wms2/plan/SBDEV-3410-stock-unit-record-shipper-filter-and-product-name.md` (§3.6, §5.2 P3, §7.2, §7.3, §7.5, §7.8, §9A)
- **Reviewer constraints honoured:** read-only, no `git checkout/restore/stash/reset`, no file edits, no `mvn`. All mutant reasoning done by reading, by re-implementing rails in Python, or against a live DB — never by editing the tree.
- **Date:** 2026-09-22

## Verdict

**The seven things you asked me to look hardest at are all correct.** In particular the byte-identical
claim — the single most important check — is **verified and NOT circular**: the test's literal equals
what `origin/develop` actually had, reconstructed mechanically rather than read by eye.

Two findings block the PR, neither in the logic: an **uncommitted P3 deliverable** (H-1) and a **stale
base that collides on the same file this diff edits** (M-1). Four Lows. Nothing in the diff contradicts
the plan's design.

| # | Severity | Finding |
|---|---|---|
| H-1 | **High** | `StockrecordExportWithdrawalContextTest.java` is untracked — a P3 deliverable that is not in the commit |
| M-1 | **Medium** | Base is 2 commits stale; `86180b4d` edits `NeverMatcherNullBlindnessArchTest`, the same file this diff edits |
| L-1 | Low | `unfilteredExportRouteIsUnchanged`'s second assertion reads a shared table through a 100-row window; `created` is nullable and NULLs sort FIRST under `DESC` |
| L-2 | Low | Fully-qualified inline type names where the repo imports them (26 other files) |
| L-3 | Low | A JSON float `60500.0` silently degrades to "All Shippers" — the plan's explicit choice, so a design note not a defect |
| L-4 | Low | `@ParameterizedTest` renders the `ABSENT` row as `java.lang.Object@…` |

---

## H-1 · HIGH — an uncommitted P3 deliverable

`git status --short` in this worktree:

```
## feature/SBDEV-3410-p3-export-shipper-filter...origin/develop [ahead 1, behind 2]
?? src/test/java/net/aim_ai/wms/security/StockrecordExportWithdrawalContextTest.java
```

That file is unambiguously P3 work — its javadoc opens *"SBDEV-3410 P3 — the filtered export is
withdrawn from Spring Data REST"* and cites *"Raised by the P3 security lane (L-3), which noted that
none of the three existing SDR rails would have covered it"*. Commit `56089a41` does not contain it.

Two consequences, and the first is the one that bites:

1. **A local `mvn verify` in this worktree runs it; the PR will not carry it.** That is the
   works-locally/broken-on-the-branch shape — a green verdict for a tree the reviewer never sees.
2. The security lane's L-3 remediation ships unaddressed. It is not redundant with
   `StockrecordExportQueryContractUnitTest`: that one asserts the *annotation*, this one asks the built
   `ResourceMappings` whether SDR honoured it — a different claim, and the right one, since SDR here is
   `RepositoryDetectionStrategies.ANNOTATED` **per repository**, so a query method on an annotated
   repository exports by DEFAULT.

I read the file. It is well-formed and needs no changes: `BaseRollbackIntegrationTest` exists
(`src/test/java/net/aim_ai/wms/common/base/`), `SdrMutatingSearchNotExportedContextTest` uses the same
base and the same `SearchResourceMappings` traversal, and it carries its own non-vacuity control —
`.contains("findByOffsetAndLimit")` before `.doesNotContain("findByClientOffsetAndLimit")`, so a
traversal that found nothing cannot pass. Its `@DisplayName`s trip no rail.

**Action:** commit it. *Caveat I cannot resolve from here:* three sibling lanes are live in this tree.
If another lane authored this for a different branch, say so — but the file names P3 and only P3.

## M-1 · MEDIUM — stale base, colliding on the same file

`origin/develop` has moved to `3214a9c3` (2 commits ahead of this branch's base):

- `86180b4d` SBDEV-3452 — allow re-palletizing
- `3214a9c3` merge of PR #392

**Good news, verified:** those 2 commits touch **none** of `StockrecordRepository.java`,
`ReportService.java`, `ReportController.java`. So the byte-identical pin's literal is still accurate
against *current* develop, not merely against `f2ee75f1`.

**The collision:** `86180b4d` also edits
`src/test/java/net/aim_ai/wms/unit/config/NeverMatcherNullBlindnessArchTest.java`, adding
`"MobileMoveUnitloadServiceUnitTest:1"` to `PRIMITIVE_MATCHER_INVENTORY` at ~line 452. This diff edits
the `ReportServiceUnitTest` entry at ~line 498. The hunks are disjoint, so a 3-way merge resolves
cleanly and the merged inventory is correct — but `primitiveCapableMatchersMatchInventory` asserts an
**exact set**, so a merge that loses either entry reds the build with a message that reads like a code
defect rather than a merge accident.

**Action:** rebase onto `3214a9c3`, confirm both inventory entries survive, re-run.

---

## The seven checks

### 1 · The byte-identical claim — VERIFIED, and not circular

This is the check you flagged as most important, so I did it mechanically rather than by eye: extracted
the Java string literals from `git show origin/develop:…StockrecordRepository.java` and from the
working tree, decoded `\"` / `\\`, substituted `NATIVE_KEYWORD_CLAUSE`, and joined.

Three strings compared:

| string | source |
|---|---|
| A | `findByOffsetAndLimit`'s `@Query` value at `origin/develop` |
| B | the post-change rendered value (`"SELECT…" + "WHERE" + NATIVE_KEYWORD_CLAUSE + "order by…" + "offset…"`) |
| C | the test's `UNFILTERED_QUERY_AT_DEVELOP` literal (lines 77-83) |

**A == B == C, byte for byte.** All three are:

```
SELECT * FROM Stockrecord p WHERE (CONCAT(LOWER(p.activitycode), ' ', LOWER(p.fromstoragelocation), ' ', LOWER(p.fromunitload), ' ', LOWER(p.itemdata), ' ', LOWER(p."operator")) LIKE LOWER(concat('%', :keyword,'%')) or :keyword = '') order by p.created DESC offset :offset limit :limit
```

So the pin encodes the **pre**-change text, and the post-change text equals it — which is exactly the
property the lift is supposed to have. **Not circular.** Note the quoted `LOWER(p."operator")` survives
in all three, which is the silent-swap this pin exists to catch.

Residual, inherent, not worth changing: nothing mechanically ties C to git history, so a future commit
that edits the constant and the literal together stays green. The javadoc says as much. A frozen-literal
pin cannot do better without a build-time git read.

The method's `@RestResource` assertions (`isNotNull()`, `exported()` is `true`) are the right companion —
the text could be identical while the exposure moved.

### 2 · The new filtered query's SQL — VERIFIED VALID, and executed on PostgreSQL

Rendered value (reconstructed the same way):

```
SELECT * FROM Stockrecord p WHERE (CONCAT(…) LIKE LOWER(concat('%', :keyword,'%')) or :keyword = '') AND p.client_id = CAST(:clientId AS bigint) order by p.created DESC offset :offset limit :limit
```

Every seam:

- `"WHERE"` + NKC's **leading** space → `WHERE (CONCAT` ✓
- NKC's **trailing** space + `"AND p.client_id…"` → `'') AND p.client_id` ✓ — one space, not two
- `CAST(:clientId AS bigint) ` + `"order by"` ✓
- **The load-bearing one:** the keyword clause is parenthesised, so `AND` binds against the whole
  disjunction and is not swallowed by `or :keyword = ''`. A missing paren here would silently widen the
  result set to every shipper whenever the keyword were blank. It is closed. ✓

**Executed against `dev_wh01_om1`** (9,726,805 `stockrecord` rows, 160 clients):

| probe | result |
|---|---|
| rendered SQL, keyword `''`, clientId 60500, offset 0 limit 100 | 100 rows, `count(distinct client_id) = 1`, min = max = **60500** |
| rendered SQL, keyword `'receiv'`, clientId 60500 | **47,403** rows — keyword and filter compose |
| `client_id = 0` | client 0 exists, owns **16** `stockrecord` rows — corroborates §3.6 |
| `PREPARE … CAST($2 AS bigint) … OFFSET $3 LIMIT $4` with `$2/$3/$4` **untyped** | **succeeds** — the explicit CAST resolves the bind |
| the same `PREPARE` with `$1` also untyped | `could not determine data type of parameter $1` |

That last pair is worth stating precisely: the *keyword* bind, inside `concat('%', $1,'%')` (a
`VARIADIC "any"` function), is the one PostgreSQL cannot type on its own — and it has always worked in
production because pgjdbc declares it via `setString`. The *clientId* bind resolves purely from the
`CAST`. So the plan's stated reason for the CAST is the right reason, and it is now executed rather
than reasoned.

`order by p.created DESC` after a filter: correct, and it is exactly the shape of the index P1 already
shipped — `V2.2.33:149` `CREATE INDEX index_stockrecord_client_created ON public.stockrecord
(client_id, created DESC)`. `EXPLAIN` on dev (still pre-`V2.2.33`, so worst case) gives
`Limit → Index Scan on stockrecord`, cost `0.43..34.28` for the first 100 — no `Seq Scan`, no `Sort`.

`offset`/`limit` are applied after `WHERE` and after `ORDER BY` by SQL semantics, so pagination is over
the filtered, ordered set. ✓

### 3 · `toFilterId(String.valueOf(reqMap.get("filter")))` — claim VERIFIED

`AdminController.toFilterId` (line 98), read in full:

```java
if (raw == null || raw.isBlank()) return -1L;
try { return Long.parseLong(raw.trim()); } catch (NumberFormatException e) { return -1L; }
```

`reqMap` is `Map<String,Object>` (`ReportController:251`), so the compiler selects
`String.valueOf(Object)` — the notorious `valueOf(char[])` NPE needs a `char[]`-typed or literal-`null`
argument and is not reachable here. `String.valueOf((Object) null)` is the literal `"null"` → NFE →
`-1L`. **The claim is exactly true as written.**

`toFilterId` never returns `null`, so `ReportService`'s `clientId == null` arm is unreachable from this
controller. Defensive only, and correct for in-process callers — not dead code worth removing.

Wire shapes I traced that the comment does not enumerate. **All land on `-1L` with no exception**, so
"no cast can throw" holds:

| wire | Jackson type | `String.valueOf` | `toFilterId` |
|---|---|---|---|
| `60500.0` | `Double` | `"60500.0"` | **`-1L`** |
| `6.05e4` | `Double` | `"60500.0"` | **`-1L`** |
| `true` | `Boolean` | `"true"` | `-1L` |
| `[60500]` | `ArrayList` | `"[60500]"` | `-1L` |
| `{"a":1}` | `LinkedHashMap` | `"{a=1}"` | `-1L` |
| `99999999999999999999` | `BigInteger` | the digits | `-1L` |
| `" 60500 "` | `String` | as-is | `60500L` ✓ (`trim()`) |
| `"+60500"` | `String` | as-is | `60500L` ✓ (`parseLong` takes a leading `+`) |

**L-3, and it is out of scope as a design change.** Every unparseable shape silently becomes "export
all shippers" rather than a 4xx — a wrong-data download with no signal, the same class as SBDEV-3437.
§3.6 chose this deliberately ("absent, JSON-null, blank and non-numeric all collapse to no filter
through one existing helper"), so I am not asking for it to change. I am asking for one line on the
ticket, because `60500.0` is the one plausible shape a non-Vuetify client could produce (`JSON.stringify`
of an integral JS number never emits `.0`, and §3.6's UI fold sends a String, so it is not live today).

Sibling casts, **pre-existing and out of scope**: `(Integer) reqMap.get("offset")` and `("limit")` on
the two lines immediately above still sit over the `try` and still CCE on a float or NPE at unboxing on
an omitted key. Both land in the pre-existing `catch (Exception e)` → 200 with an error body. The new
comment makes a strong point about cast safety while leaving its two neighbours as they were; that is
the right scope, just worth knowing.

### 4 · Can the three new/changed tests pass vacuously? — NO

**`filterValueMatrix` cannot silently not-run.**
`@MethodSource("net.aim_ai.wms.unit.controller.ReportControllerUnitTest#filterMatrix")` is the
fully-qualified external-factory form; a bad name throws `JUnitException`, it does not skip. `filterMatrix`
is `static` on the **outer** class, which is required because a `@Nested` class cannot host a
`@MethodSource` factory — the comment's reason is correct. `Arguments.of(null, -1L)` is unambiguous
(two args → `Object[]{null, -1L}`).

**The `ABSENT` sentinel behaves.** It is a `static final Object`, so `.equals` is identity.
`ABSENT.equals(null)` is `false`, so the JSON-null row **does** put `"filter" -> null` into the body.
That row and the ABSENT row are behaviourally identical (both `-1L`) but neither is skipped.

**The verify is a real `times(1)`.** Mocks come from `@ExtendWith(MockitoExtension.class)` via
`BaseUnitTest`, with `@Mock` fields — every parameterized invocation gets a fresh `reportService`. A
controller that ignored `filter` reds **4 of 10** rows (`60500`, `"60500"`, `0`, `"0"`).

**`numericFilterIsForwarded` does distinguish the fix from the bug**, and for the stated reason. With
`(String) reqMap.get("filter")` and a JSON number, the CCE is thrown above the `try` — I confirmed
against `origin/develop` that all seven sibling `String filter = (String) reqMap.get("filter")` reads
(lines 66/93/121/148/175/202/229) sit above their `try` — so it escapes the handler entirely and
`mockMvc.perform` raises a nested `ServletException`. There is no status to assert on, which is why
asserting the forwarded value is right and "does not throw" would grade the wrong thing. It is
redundant with `filterValueMatrix`'s `60500 → 60500L` row; §7.3 asked for both, so keep it.

**`filterReachesRepository`'s two `never()`s are non-vacuous.** The test makes four calls, two of which
*do* reach the filtered method (`60500L`, `0L`), so `never().findByClientOffsetAndLimit(any(), eq(-1L), …)`
and the `isNull()` sibling genuinely constrain the `-1L`/`null` calls rather than being trivially true.
`eq(-1L)` / `isNull()` on position 2 are safe: the parameter is boxed `Long`, so Mockito's null
placeholder does not unbox. Class is `@MockitoSettings(STRICT_STUBS)` and both stubs are consumed.

**`exportHeaderNamesAndOrderAreUnchanged` — the varargs-captor trap does NOT apply here.**
`FileExportService.exportExcelFile(Workbook, String, List<Object[]>, String[] headerNames, List<Object[]>, HttpServletResponse)`
takes a **plain array parameter, not varargs**, so `ArgumentCaptor.forClass(String[].class)` is correct.
The 15 captured headers match `ReportService:410-412` exactly and in order; pinning order as well as
membership is the assertion that matters for a positional `String[]`. The mock stubs `getId`,
`getAmount`, `getAmountstock` — all three consumed by the loop, so no `UnnecessaryStubbing`.

**`bothExportQueriesShareOneKeywordClause`'s third assertion is subtle and correct.** The normalised
unfiltered prefix up to `"order by"` ends in a single space; the normalised filtered query has `'') AND`
at that offset, so `startsWith` holds. It reds on a narrowed clause, a reordered conjunct, or a
hand-copy. And `containsExactlyInAnyOrder("activitycode", "fromstoragelocation", "fromunitload",
"itemdata", "operator")` pins **which** five columns rather than merely that the two queries agree —
that closes the "a control on a literal cannot detect a narrowed pattern" hole the comment names.

**No new identifier trips `TestIdentifierCountArchTest`.** Its `@DisplayName` pattern is
`(the|exactly|all)\s+([2-9]|[1-9][0-9])\s+[a-z]` and its method pattern is
`(Exactly|All)(Two…Twelve)`. No new `@DisplayName` matches; the `15` lives only in an `.as()` message
and in `src/main` javadoc, neither scanned.

> **Doc nit (part of L-2's family).** The javadoc on `exportHeaderNamesAndOrderAreUnchanged` says the
> count is kept out of "this test's name or `@DisplayName`" because the rail "caught the first draft of
> this very test". The `@DisplayName` risk was real — `"the 15 export columns are unchanged"` would
> match. The **method-name** risk was not: `METHOD_NAME_COUNT` only matches `Exactly|All` +
> `Two…Twelve`, so `fifteenColumnsUnchanged` (the plan's §7.3 name) would have passed. Worth trimming
> the claim so a future reader does not think method names with spelled numbers are forbidden.

### 5 · `StockrecordExportClientFilterIT` — it works for the stated reason, not by accident

**The auto-commit claim is true.** `PostgresTestSupportConfig.jdbcTemplate()` builds a standalone
`DriverManagerDataSource` over `AppPostgresDBContainer.container.getJdbcUrl()`. `JdbcTemplate` resolves
its connection through `DataSourceUtils` against *that* DataSource, for which the tenant transaction
manager has bound no `ConnectionHolder` — so every `update` runs on a fresh `autoCommit` connection and
commits. ✓

**The read sees the rows for the documented reason.** PostgreSQL's default **READ COMMITTED** takes a
new snapshot per statement, so the JPA-side native query on a different connection sees the committed
rows even though the test transaction opened first (`TransactionalTestExecutionListener` begins it
before `@BeforeEach`). The javadoc's "raise the isolation to REPEATABLE READ and this class breaks" is
correct. Belt, unstated and worth knowing: Spring Boot's `DELAYED_ACQUISITION_AND_HOLD` means the JPA
connection is not even acquired until the first repository call, after the seed has committed.

**The `NOT_SUPPORTED` decision is right and needs no rail edit.** Nothing is written through JPA, so
the inherited `@Transactional("tenantTransactionManager")` is inert here — its real purpose is staying
off `TestClassTransactionManagerArchTest`'s `EXEMPT_NON_TRANSACTIONAL` (line 164), which
`nonTransactionalPropagationsMustBeDeclared` pins **exactly**. Declaring `NOT_SUPPORTED` would have
required an allow-list entry and a justification; the sibling `HandlingUnitsClientFilterIT` is in that
set for precisely this. Copying `StockrecordAdjustmentAlertDoubleToastIT` instead is the cheaper,
already-proven route, and that class is in the same package so the `{@link}` resolves.

**Sibling perturbation: safe, and I checked rather than assumed.**

- `activitycode = 'sbdev3410p3it'` appears nowhere else in `src/test`. Both filtered assertions and the
  first unfiltered assertion filter on it.
- Fixture ids `9_913_700`–`9_913_710` (and the `9_913_601` mock id) appear nowhere else in `src/test`.
  They sit well above the reserved-fixed-id band start (9000).
- `client.cl_nr` is UNIQUE (`uk_e2cgvit466blvvac3y77crsyg`, `V2.2.00:3676`) and `'T3410P3B'` is unused.

**`wipe()` is complete and in FK order.** `stockrecord` (the child, via
`fk7si5rq7yt4ohwmaob5kmluhyc`) then `client`, and only `client WHERE id = CLIENT_B`. I confirmed
`V2.2.00` seeds **exactly one** client — `(0, …, 'System-Client', 'System', …)` at line 2377 — and
**zero** `stockrecord` rows, so the javadoc's "the base dump seeds exactly one client: id 0" is
accurate and the "never the seeded row 0" comment is doing real work. Running `wipe()` in `@BeforeEach`
as well is the right call given the rows commit.

**The `stockrecord` insert covers every NOT NULL column** — `id, version, activitycode,
fromstoragelocation, tostoragelocation, operator, client_id` — checked against `V2.2.00`'s DDL. `type`
is nullable and correctly omitted.

#### L-1 · LOW — the one assertion that reads a shared table through a window

```java
assertThat(ids(stockrecordRepository.findByOffsetAndLimit(ALL, 0, 100)))
    .contains(SR_SYS, SR_B1, SR_B2);
```

`ALL` is `""`, so the escape arm matches **every** `stockrecord` row and the query takes the newest 100
by `created DESC`. `stockrecord.created` is **nullable** (`V2.2.00`), and PostgreSQL sorts NULLs
**FIRST** under `DESC` — so ≥100 committed rows with `created IS NULL` would evict the fixture rows and
produce a red that reads as a real regression in the SQL.

Latent, not live. I checked all three sibling classes that insert `stockrecord`
(`StockrecordAdjustmentAlertDoubleToastIT`, `StockrecordViewSchemaIT`,
`ClientRepositoryTransactionDetailIT`): every one sets `created`, each inserts a handful of rows, and
each cleans up. So nothing reaches this today.

Worth closing anyway, because the class's own javadoc leans on "the rows still commit". Cheapest fix:
keep the escape-arm coverage but stop pairing it with an unbounded window — the filtered route's
`emptyKeywordTakesTheEscapeArmWhenFiltered` already grades `or :keyword = ''` on the shared constant,
so this second assertion can safely become `findByOffsetAndLimit(KEYWORD, 0, 100)` with
`containsExactlyInAnyOrder`, or keep `ALL` with a limit well above any plausible sibling residue.

### 6 · The inventory change 4 → 8 — CORRECT, verified by re-running the rule

I re-implemented the rule's own algorithm in Python — its `stripComments`, `NEVER_VERIFY`, `spanEnd`
and `PRIMITIVE_CAPABLE`, copied from the source — and ran it over `ReportServiceUnitTest`. Result:
**exactly 8**, from four sites:

| site | primitive-capable matchers |
|---|---|
| `never().findByClientOffsetAndLimit(any(), eq(-1L), anyInt(), anyInt())` | 2 — **new** |
| `never().findByClientOffsetAndLimit(any(), isNull(), anyInt(), anyInt())` | 2 — **new** |
| `never()` on `lockOverviewAllDtoViewRepository.findByClientOffsetAndLimit(any(), any(), anyInt(), anyInt())` | 2 — pre-existing |
| `never()` on `lockOverviewDtoViewRepository.…` | 2 — pre-existing |

So the "4 → 8" arithmetic is right, nothing missed, nothing over-counted.

**The primitive claim is right, read from the declaration.** `StockrecordRepository.java:120-123`:

```java
List<Stockrecord> findByClientOffsetAndLimit(@Param("keyword") String keyword,
                                             @Param("clientId") Long clientId,
                                             @Param("offset") int offset,
                                             @Param("limit") int limit);
```

Positions 3 and 4 are primitive `int`, so `anyInt()` is required and `any()` would NPE at unboxing.
Position 2 is a boxed `Long` matched with `eq(-1L)`/`isNull()`, which `PRIMITIVE_CAPABLE` does not
match — the comment's accounting for why it adds nothing to the count is correct.

One thing the comment does not claim but which I checked, because it is how this rail goes silent:
`NEVER_VERIFY` uses `\s*` throughout, and `\s` matches `\n`, so the
`never())\n        .findByClientOffsetAndLimit(` line break is matched and the span is **found**, not
silently skipped.

See **M-1** — `origin/develop` has since added one entry to this same list.

### 7 · `ReportService.exportStockUnitRecord`'s branch — safe, and it unboxes

```java
boolean unfiltered = clientId == null || clientId == -1L;
```

`clientId` is a boxed `Long`; the right operand is the **primitive** literal `-1L`, so binary numeric
promotion applies and `clientId` is **unboxed**. This is not the `Long != Long` reference-comparison
trap that inverts past 127 — that needs both operands boxed. And `||` short-circuits, so the unboxing
cannot NPE on the `null` path. **Correct.**

No other value should mean "no filter": `toFilterId` already normalises every unusable wire shape to
`-1L`, and `0L` correctly *filters* (System-Client). A negative id other than `-1` would filter and
return zero rows, but the dropdown cannot produce one.

`@Transactional` correctly **absent**, matching §7.5 row 3 and the rest of the class. The javadoc's
reason (a fully materialised flat entity, no lazy associations, and no wish to pin a tenant connection
across the Excel build plus the response stream) is the right one.

---

## Plan conformance

**Nothing in the diff contradicts the plan's design.** Three differences, all improvements or forced:

1. **The filtered `@Query`'s third fragment.** The plan wrote `" AND p.client_id = …"` with a leading
   space; since `NATIVE_KEYWORD_CLAUSE` already ends in a space, the plan's form renders a **double**
   space. The implementation's `"AND p.client_id = …"` is the correct one. The plan's §3.6 snippet
   should be corrected so the next reader does not "fix" the code back.
2. **The IT's home.** §7.2 assigned `exportPredicateRendersOnPostgres` and
   `unfilteredExportRouteIsUnchanged` to `StockrecordViewRepositoryFilterIT`. **That class does not
   exist in the tree** — P2 never created it. Putting them in a new `StockrecordExportClientFilterIT`
   under `integration/repository/` is right: a different repository, a different table, and the export
   has no dependency on `stockrecord_view`.
   *Cross-phase note, P2's debt not P3's:* the other §7.2 rows the plan assigned to that class —
   `filterReturnsOnlySelectedShipper`, `clientIdZeroIsARealShipper`, `keywordAndFilterAndSortAndPageCompose`,
   `filteredSearchKeepsAnIndexCondition`, `clientWithNoRowsReturnsAnEmptyPage` — have no home either.
   §9B's "still owed" should say so.
3. **The service test's name.** §7.3 called it `fifteenColumnsUnchanged`; it shipped as
   `exportHeaderNamesAndOrderAreUnchanged`. Correct call (the count belongs in the assertion), with the
   over-stated justification noted in check 4.

§5.2 P3's checklist, item by item: controller read via `toFilterId(String.valueOf(…))` ✓ · service gains
`Long clientId` and branches on `clientId == null || clientId == -1L`, no `@Transactional` ✓ ·
`findByClientOffsetAndLimit` added with `@RestResource(exported = false)` and a plain
`p.client_id = CAST(:clientId AS bigint)` ✓ · `findByOffsetAndLimit` rendered predicate byte-identical ✓ ·
the four existing `findByOffsetAndLimit` stubs kept and new stubs added for the new method rather than
widening theirs ✓ · all 11 four-argument call sites updated (4 in `ReportServiceUnitTest`, 7 in
`ReportControllerUnitTest`) ✓ · the two `Sbdev3017TrancheGateContextTest` rows are path+function based
and signature-independent, so they cannot have moved ✓ · mutation checks not evidenced in the diff
(verifier's lane).

## Rails and inventories swept for owed updates — none found

Adding a query method with `exported = false` and changing a service signature perturbs none of these,
and I checked each rather than assuming:

| rail | why it is unaffected |
|---|---|
| `SdrUncalledSurfaceNotExportedContextTest` | `Stockrecord` already in `MUST_REMAIN_EXPORTED`; `WITHDRAWN`'s `hasSize(27)` is domain-type level |
| `SdrWriteWithdrawalContextTest` | `hasSize(49)` / `hasSize(9)`, write verbs only |
| `SdrSurfaceInventoryContextTest`, `SurfaceInventoryContextTest`, `SdrNonEntityCollectionSearchNotExportedContextTest`, `SdrLockingSearchNotExportedContextTest` | all `isGreaterThan` **floors**, not exact pins |
| `Sbdev3017TrancheGateContextTest`, `ReportReadGateUnitTest` | path + function rows; unchanged |
| `TestClassTransactionManagerArchTest` | `ALLOWED` is empty; `EXEMPT_NON_TRANSACTIONAL` untouched (no `NOT_SUPPORTED` added) |
| `TestIdentifierCountArchTest` | no new identifier matches either pattern |
| `PostgresTestHarnessPinTest` | `hasSizeGreaterThan(300)` floor; no subclass count to bump |
| `NeverMatcherNullBlindnessArchTest` main rule | flags only always-reference matchers; `any()`, `eq()`, `isNull()` are not in `REFERENCE_NULL_BLIND` |

## Remaining Lows

**L-2 · Style, and Lows get fixed on this repo.** `ReportControllerUnitTest` writes
`org.junit.jupiter.params.ParameterizedTest`, `…provider.MethodSource`, `…provider.Arguments` and
`java.util.stream.Stream` fully qualified inline, where 26 other test files in this repo import them —
it makes `filterMatrix` hard to read. `ReportServiceUnitTest` writes `java.util.Collections.emptyList()`
although `java.util.Collections` is already imported at line 27. (The pre-existing
`throws Exception, net.aim_ai.wms.exceptions.BusinessException` is the file's own style and I would
leave it.)

**L-4 · Test-report legibility.** `@ParameterizedTest(name = "filter={0} -> {1}")` renders the ABSENT
row as `java.lang.Object@1a2b3c` — a nondeterministic name in the surefire report. Giving `ABSENT` a
`toString()` (`new Object() { @Override public String toString() { return "<absent>"; } }`) keeps
identity semantics and makes the output readable.

---

## What I could not run, and the commands for you

No `mvn` from this lane (concurrent Maven in one worktree produces false reds). Everything above is
from reading, from re-implementing two rails in Python, or from live SQL against `dev_wh01_om1`. The
mutant verdicts below are **reasoned, not executed** — please run them.

```bash
# 1. rebase first — see M-1
git fetch origin && git rebase origin/develop
#    then confirm BOTH inventory entries survive the merge:
grep -n 'MobileMoveUnitloadServiceUnitTest:1\|ReportServiceUnitTest:8' \
  src/test/java/net/aim_ai/wms/unit/config/NeverMatcherNullBlindnessArchTest.java

# 2. fast surefire pass. `clean` because mvn test runs DELETED test classes from a stale
#    target/test-classes; `,` not `+` between selectors, or the selector matches nothing and
#    leaves stale XML you would read as a verdict.
mvn clean test -Dtest='ReportServiceUnitTest,ReportControllerUnitTest,StockrecordExportQueryContractUnitTest,StockrecordExportWithdrawalContextTest,NeverMatcherNullBlindnessArchTest,TestIdentifierCountArchTest,TestClassTransactionManagerArchTest'

# 3. the full floor — both lanes, compared against the known baseline
mvn clean verify

# 4. PIT, scoped, per the pom's instruction (no hand-rolled harness)
mvn test-compile
mvn org.pitest:pitest-maven:mutationCoverage \
    -DtargetClasses=net.aim_ai.wms.service.ReportService \
    -DtargetTests=net.aim_ai.wms.unit.service.ReportServiceUnitTest
```

Hand mutants (not PIT-reachable — annotation text, SQL, and MVC binding):

| # | mutant | must red | expected message shape |
|---|---|---|---|
| a | drop the `filter` read, pass `-1L` | `ReportControllerUnitTest.filterValueMatrix` | 4 of 10 rows fail naming the dropped filter |
| b | `(String) reqMap.get("filter")` | `numericFilterIsForwarded` | **nested `ServletException` / CCE out of the handler**, NOT a 200 with an error body |
| c | `clientId == null \|\| clientId == -1L \|\| clientId == 0L` | `ReportServiceUnitTest.filterReachesRepository` | names the `0L` case |
| d | swap `NATIVE_KEYWORD_CLAUSE` for `StockrecordViewRepository.KEYWORD_CLAUSE`'s **unquoted** `LOWER(p.operator)` | `unfilteredExportQueryTextIsByteIdentical` | text diff on the quoting — this is the silent swap the pin exists for |
| e | drop `@RestResource(exported = false)` | `filteredExportIsUnexportedAndUsesAPlainEquality` **and** `StockrecordExportWithdrawalContextTest` | only (e) shows why H-1 matters: without the committed file, only the annotation-level half fires |
| f | delete `or :keyword = ''` from `NATIVE_KEYWORD_CLAUSE` | `emptyKeywordTakesTheEscapeArmWhenFiltered`, `unfilteredExportRouteIsUnchanged`, and the byte-identical pin | broad but attributable |
| g | swap two adjacent headers in `ReportService` | `exportHeaderNamesAndOrderAreUnchanged` | names the positions — the count alone would not move |
