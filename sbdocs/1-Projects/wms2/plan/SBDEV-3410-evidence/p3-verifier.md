# SBDEV-3410 P3 — conformance verification

**Question graded:** did P3 build exactly what the plan specifies — no less and no more? Not "is the code
good" (a sibling lane owns that).

- **Commit:** `56089a41` "SBDEV-3410 P3: the Stock Unit Record export respects the shipper filter"
- **Worktree:** `/Users/np1076/dev/spk/owl/.claude/worktrees/wms2-api/SBDEV-3410-p3`
- **Branch:** `feature/SBDEV-3410-p3-export-shipper-filter`, off `origin/develop` @ `f2ee75f1`
- **Diff:** 8 files, +731 / −16. `git diff origin/develop...HEAD --stat` is identical to
  `git show 56089a41 --stat`, so the branch is exactly one commit and nothing is uncommitted-but-graded.
- **Plan:** `sbdocs/1-Projects/wms2/plan/SBDEV-3410-stock-unit-record-shipper-filter-and-product-name.md`
- **Method:** read-only. Source-level grading only. **No `mvn` was run** (three sibling lanes live in this
  tree; a second maven produces false reds). Every row below says explicitly whether it was verifiable from
  source or requires execution.

**Verdict: PASS.** All six §5.2 P3 checkboxes are implemented; both §7.2 P3 rows and all four §7.3 P3 rows
are present and assert what the plan describes; the applicable §7.5 row is satisfied. Two items are
**PARTIAL only because they are execution claims** — nothing in the source contradicts them and the source
is shaped so they should hold. Three pieces of code the plan does not name are in the commit; **one was
forced by a rail, two are justified additions**, and none contradicts the plan. Details in §4 and §5.

---

## 1. §5.2 P3 — the six authoritative checkboxes

| # | Plan item | Verdict | Proof |
|---|---|---|---|
| 1 | `ReportController.exportStockUnitRecord`: `Long clientId = toFilterId(String.valueOf(reqMap.get("filter")));` — **never** `(String) reqMap.get("filter")` | **VERIFIED** | `ReportController.java:268` — `Long clientId = toFilterId(String.valueOf(reqMap.get("filter")));`, forwarded at `:273`. Placed **above** the `try {` like the seven sibling reads, which is safe precisely because no cast can throw. `toFilterId` confirmed to exist and be inherited: `AdminController.java:98` `protected static Long toFilterId(String raw)`, and `ReportController extends AdminController`. Zero `(String) reqMap.get("filter")` in the new code. |
| 2 | `ReportService.exportStockUnitRecord` gains `Long clientId` and **branches** on `clientId == null \|\| clientId == -1L`; **no `@Transactional`** (§7.5 row 3) | **VERIFIED** | `ReportService.java:371` signature `(HttpServletResponse, int, int, String, Long)`; `:377` `boolean unfiltered = clientId == null \|\| clientId == -1L;`; `:379-380` the two-arm call. Literally the plan's guard — no truthiness anywhere. `clientId == -1L` compares a `Long` against a `long` **literal**, so `clientId` is unboxed by numeric promotion; the boxed-`Long`-identity trap does not apply. **No `@Transactional`**: the only two `^+.*@Transactional` lines in the entire diff are javadoc prose (`ReportService.java` javadoc "No `@Transactional` (plan §7.5 row 3)", and the IT's javadoc describing the *inherited* base-class annotation). |
| 3 | **Add** `StockrecordRepository.findByClientOffsetAndLimit` with `@RestResource(exported = false)` and a plain `p.client_id = CAST(:clientId AS bigint)`; **`findByOffsetAndLimit`'s rendered predicate stays byte-identical**; the only edit to it is lifting its keyword clause into `NATIVE_KEYWORD_CLAUSE`; `unfilteredExportRouteIsUnchanged` is the guard for the lift | **VERIFIED** | New method at `StockrecordRepository.java:114-123` — `@RestResource(exported = false)` at `:114`, plain equality `"AND p.client_id = CAST(:clientId AS bigint) "` in the `@Query`, no `OR`/`IS NULL`/`COALESCE` arm. `NATIVE_KEYWORD_CLAUSE` at `:69`. `findByOffsetAndLimit` at `:88-93` keeps `@RestResource(path = "findByOffsetAndLimit", rel = "findByOffsetAndLimit")` (no `exported = false`), its signature, and its rendered text: the annotation is now `"SELECT * FROM Stockrecord p " + "WHERE" + NATIVE_KEYWORD_CLAUSE + "order by p.created DESC " + "offset :offset limit :limit"`, and the constant opens with `" ("` and closes with `") "`, so `"WHERE" + " (…) " + "order by"` reproduces the pre-lift string character-for-character. A `String` constant is a compile-time constant expression, so this is a single `String` in the class file, not a runtime concat. **Asserted, not assumed** — `StockrecordExportQueryContractUnitTest.unfilteredExportQueryTextIsByteIdentical` pins the whole value against a literal captured at `f2ee75f1`, and the quoted `LOWER(p."operator")` is preserved (the §3.6 warning that the unquoted §3.4 form executes identically and would break only this property). Row set guarded by `StockrecordExportClientFilterIT.unfilteredExportRouteIsUnchanged`. |
| 4 | Extend the existing nested `ExportStockUnitRecord` classes; add stubs for the new method rather than widening the four existing ones; **fix the 11 breaking four-argument call sites** (4 in `ReportServiceUnitTest`, 7 in `ReportControllerUnitTest`) | **VERIFIED — and the plan's count of 11 was exact** | `ReportServiceUnitTest`: 4 call sites updated — three `reportService.exportStockUnitRecord(mockResponse, 0, 100, "")` act lines (`:449`, `:480`, `:494` post-diff) plus the `assertThatThrownBy` lambda (`:528`), each gaining a `NO_FILTER` (`-1L`) fifth argument. `ReportControllerUnitTest`: 7 stub/verify lines updated (2 in `exportsStockUnitRecordSuccessfully`, 2 in the null-keyword case, 2 in the BusinessException case, 1 `doThrow` in the LocalDateTime case), each gaining `eq(NO_FILTER)`. 4 + 7 = 11. The four existing `when(...findByOffsetAndLimit(any(), anyInt(), anyInt()))` stubs are untouched; `filterReachesRepository` adds its **own** stub for `findByClientOffsetAndLimit` rather than widening theirs, exactly as specified. |
| 5 | Confirm **both** `Sbdev3017TrancheGateContextTest` rows (`/v3/report/...` and the inherited `/v3/dashboard/...`) stay green | **PARTIAL — execution-dependent** | Both rows are intact and **unedited** by this commit: `Sbdev3017TrancheGateContextTest.java:212` `row("ReportController", "/v3/report/exportStockUnitRecord", "WEB_UI_VIEW_STOCK_UNIT_RECORD");` and `:213` the `/v3/dashboard/` twin. The commit touches no `@RequiresFunction`, no `@RequestMapping` and no controller-class hierarchy, which is the only way those rows could move — so *from source* there is no mechanism by which they would red. **I cannot assert they are green without executing**, and per the hard constraint I did not. Reconcile against the claimed full surefire result. |
| 6 | Mutation checks: (a) make the controller ignore `filter` → the controller unit test reds naming the dropped filter; (b) revert to `(String) reqMap.get("filter")` with a JSON-**number** body → reds with a **thrown `ClassCastException` out of the handler** (nested `ServletException`), **not** a 200 with an error body | **PARTIAL — the killing assertions are present and correctly shaped; the kills themselves need execution** | (a) `filterValueMatrix` and `numericFilterIsForwarded` both end in `verify(reportService).exportStockUnitRecord(..., eq(<expected>))`, so a controller that drops `filter` fails the verify on the forwarded argument — an attributable message. (b) `numericFilterIsForwarded` sends `requestBody.put("filter", 60500)` (a genuine JSON number via `toJson`) and asserts **the forwarded value**, not "does not throw" — which is what §7.3 demands, and the reason it can grade the mutant at all: a `(String)` cast at line 268 sits above the `try {`, escapes both catch blocks, and `mockMvc.perform(...)` raises a nested `ServletException` with no status to assert on. The test is written so that mutant produces an **ERROR**, not a soft failure. Four of the ten `filterMatrix` cases send numbers (`-1`, `60500`, `0`, and JSON `null`), so the cast mutant reds several cases, matching the commit message's "4 ERRORS". Commit message claims five mutants killed attributably; **not verifiable from source**. |

---

## 2. §3.6 — the export design, in full (API half only)

The UI half (`:filter="String(shipper == null ? -1 : shipper)"`, `store/reports/stockUnit.js`) is **P6's** and
is correctly absent from this diff. Sites 1, 2, 3 of §3.6's sweep table belong to P6; sites 4 and 5 are P3's.

| §3.6 requirement | Verdict | Proof |
|---|---|---|
| **API:** controller reads `filter` and passes it through | VERIFIED | `ReportController.java:268`, `:273`. |
| **API:** service gains the parameter and **branches** on it | VERIFIED | `ReportService.java:371`, `:377-380`. |
| **API:** `StockrecordRepository` gains a **new** `findByClientOffsetAndLimit`; existing `findByOffsetAndLimit` left byte-identical | VERIFIED | `StockrecordRepository.java:114-123` / `:88-93`; text pinned by `unfilteredExportQueryTextIsByteIdentical`. |
| **The export stays on the `stockrecord` table** — no view, no `item_name`, no column-contract change (Q2) | VERIFIED | `ReportService.java:379-380` both branches hit `stockrecordRepository`; no `StockrecordView`/`stockrecord_view` reference anywhere in the diff. The 15 columns are pinned by name **and order** in `ReportServiceUnitTest.exportHeaderNamesAndOrderAreUnchanged` via `ArgumentCaptor<String[]>` + `containsExactly(...)` — `"ID", "Time Stamp", "Activity", "SKU ID", "From Container", "From Location", "To Container", "To Location", "Moved", "Remain", "Reserved Change", "Reserved Stock", "Operator", "Order No", "Type"`. |
| `NATIVE_KEYWORD_CLAUSE` quoted **verbatim** from §3.6, including the leading space after `WHERE` and the trailing space before `order by` | VERIFIED | `StockrecordRepository.java:69-70`. Diffed against `origin/develop`'s inline text: identical, both boundary spaces preserved. |
| ⚠ `NATIVE_KEYWORD_CLAUSE` is **not** §3.4's `KEYWORD_CLAUSE` — it quotes the column, `LOWER(p."operator")` | VERIFIED | The constant carries `LOWER(p.\"operator\")`. The hazard is documented in the constant's javadoc ("Do not 'normalise' them to match") **and** graded: the byte-identical pin is the only thing that can see the unquoted swap, since both forms execute and return the same rows. |
| One shared clause, not two verbatim copies — the split is a **filter** split, not a search-semantics split | VERIFIED | Both `@Query` values concatenate the same constant. `StockrecordExportQueryContractUnitTest.bothExportQueriesShareOneKeywordClause` pins **which** five columns (`containsExactlyInAnyOrder("activitycode", "fromstoragelocation", "fromunitload", "itemdata", "operator")`) before comparing the two sets — the plan's own "a control on a literal cannot see a narrowed pattern" lesson, applied. |
| `exported = false` on the new method (no HTTP caller; the repo's rail says withdraw rather than rule) | VERIFIED | `StockrecordRepository.java:114`. Checked for collateral rail drift: `SdrUncalledSurfaceNotExportedContextTest`'s `WITHDRAWN`/`MUST_REMAIN_EXPORTED` enumerate **domain types**, not methods, and `Stockrecord.class` correctly remains in `MUST_REMAIN_EXPORTED` (`:172`) — a method-level withdrawal moves neither list, so `hasSize(27)` (`:223`) is untouched. No inventory needed updating. |
| The `ClassCastException` trap fixed on the API side **even though the UI will send a String** — belt and braces, because `/v3/dashboard/exportStockUnitRecord` reaches the same method behind a second route | VERIFIED | `String.valueOf(...)` read at `:268`. The reasoning, including the `DashboardController extends ReportController` second route, is recorded in the code comment at `:257-267` rather than only in the plan. |
| `String.valueOf((Object) null)` → `"null"` → `toFilterId` → `-1L`; absent / JSON-null / blank / non-numeric all collapse through one existing helper | VERIFIED | Graded case-by-case by `filterValueMatrix`: `ABSENT → -1L`, JSON `null → -1L`, `"" → -1L`, `"abc" → -1L`. |
| **`clientId == null \|\| clientId == -1L`, never truthiness — `0` is a REAL shipper** (System-Client, 5 of 5 reachable DBs incl. prd) | VERIFIED, on **both** sides | Service fold: `ReportService.java:377`. Controller normalisation: `filterMatrix` carries `Arguments.of(0, 0L)` **and** `Arguments.of("0", 0L)`. Service fold: `filterReachesRepository` exercises `0L` and asserts `findByClientOffsetAndLimit("k", 0L, 0, 100)`. SQL side: `StockrecordExportClientFilterIT.clientIdZeroFiltersRatherThanDisablingTheFilter` executes it against real PostgreSQL and asserts `containsExactly(SR_SYS)`. Three instruments on the one value the plan says everything turns on. |
| §3.6's executed truth table — the **API column**, `toFilterId(String.valueOf(body))` applied to `null` / `0` / `60500` | VERIFIED as a superset | The plan's three rows are `"-1" → -1L`, `"0" → 0L`, `"60500" → 60500L`. All three are in `filterMatrix`, alongside seven more (`ABSENT`, JSON `null`, `-1`, `""`, `"abc"`, `60500`, `0`). |
| §7.2's named guard for the lift | VERIFIED | `unfilteredExportRouteIsUnchanged` — see §3 below. |

**One byte-level difference from §3.6's code snippet, and it is not a defect.** The plan writes the filtered
query as `"… WHERE" + NATIVE_KEYWORD_CLAUSE + " AND p.client_id = …"`; the implementation writes
`… "WHERE" + NATIVE_KEYWORD_CLAUSE + "AND p.client_id = …"`, relying on the constant's own trailing space. The
plan's form would render two spaces before `AND`, the implementation's one. Identical SQL, and §5.2 P3
explicitly says *"Confirm the rendered SQL against the IT, not against this document"* — which is what
`StockrecordExportClientFilterIT` does. Recorded so a later reader does not mistake it for drift.

---

## 3. §7.2 — integration rows belonging to P3

Both rows are present in **`src/test/java/net/aim_ai/wms/integration/repository/StockrecordExportClientFilterIT.java`**
(new, P3-owned), not in `StockrecordViewRepositoryFilterIT` as §7.2 files them.

| §7.2 row | Verdict | What it actually asserts |
|---|---|---|
| `exportPredicateRendersOnPostgres` — the native `CAST(:clientId AS bigint)` form in the **new** `findByClientOffsetAndLimit` executes without a *"could not determine data type of parameter"* error | **VERIFIED** | Calls `stockrecordRepository.findByClientOffsetAndLimit(KEYWORD, CLIENT_B, 0, 100)` against the real container (execution is itself half the assertion, as the plan requires), then asserts the returned ids are exactly `{SR_B1, SR_B2}` and that every row's `getClientId()` equals `CLIENT_B`. **Stronger than the §7.2 row**, which asked only that it executes. |
| `unfilteredExportRouteIsUnchanged` — `findByOffsetAndLimit(keyword, 0, 100)` returns the same row set it returns today; the regression guard for the route §3.6 deliberately did not touch | **VERIFIED** | Asserts the keyword-scoped unfiltered call returns `containsExactlyInAnyOrder(SR_SYS, SR_B1, SR_B2)` — i.e. **every** shipper's rows including client `0`'s, which is exactly the property a wrongly-added predicate would destroy. Paired with the byte-identical text pin in the unit test, so both the text and the row set are guarded. |

**The placement deviation is correctly reasoned — stronger than the plan's own filing.** Two independent
reasons, both verified:

1. **`StockrecordViewRepositoryFilterIT` does not exist on `origin/develop`.** `git ls-tree -r origin/develop`
   returns exactly one `StockrecordView*` test — `src/test/java/net/aim_ai/wms/integration/schema/StockrecordViewSchemaIT.java`
   (P1, merged). P2's class lives on P2's branch behind open PR #391. P3 branched off `f2ee75f1`, so filing
   these rows there was **not physically possible** without depending on an unmerged branch — which would
   have converted §5.1 row 4's stated "(P3, P4, P5 in any order)" independence into a P2→P3 hard pair.
2. **Both rows exercise the wrong repository for that class.** They call `StockrecordRepository`
   (the base-table export repo), not `StockrecordViewRepository`. `StockrecordViewRepositoryFilterIT` is
   named for, and fixtured for, the view. The plan's filing was a clerical grouping, not a design decision.

**Two IT cases the plan does not name.** `clientIdZeroFiltersRatherThanDisablingTheFilter` and
`emptyKeywordTakesTheEscapeArmWhenFiltered`. Both are additions, neither contradicts anything: the first is
the SQL-side half of §3.6's `client.id = 0` invariant (§7.2's `clientIdZeroIsARealShipper` row grades the
*view* repository's `findByKeywordAndClient`, which is P2's — nothing in §7.2 or §7.3 grades the
**export**'s `0`), and the second grades that `or :keyword = ''` survived the lift onto the filtered route,
which is the default operating case (shipper selected, keyword box empty) and the one failure that would ship
a blank spreadsheet. Judgement: **justified additions, and gaps in the plan's enumeration rather than
unauthorised scope.**

---

## 4. §7.3 — unit rows belonging to P3

| §7.3 row | Verdict | Proof |
|---|---|---|
| `ReportControllerUnitTest$ExportStockUnitRecord.numericFilterIsForwarded` — a body with `"filter": 60500` reaches the service as `60500L`; **assert the forwarded value, not "does not throw"** | **VERIFIED** | Present. `requestBody.put("filter", 60500)`; asserts `status().isOk()` **and** `verify(reportService).exportStockUnitRecord(any(HttpServletResponse.class), eq(0), eq(100), eq("K"), eq(60_500L))`. No `try`/`catch`, no `assertThatThrownBy` — the value is the assertion, which is precisely what the plan says the test must be. |
| `filterValueMatrix` — absent · JSON `null` · `-1` · `""` · `"abc"` → `-1L`; `60500` → `60500L`; **`0` → `0L`, NOT `-1L`** | **VERIFIED — superset (10 cases for 7 required)** | `@ParameterizedTest` + `@MethodSource` onto a static `filterMatrix()` on the **outer** class (a `@Nested` class cannot declare a static factory — a real JUnit constraint, correctly handled and documented). Cases: `ABSENT→-1L`, `null→-1L`, `-1→-1L`, `""→-1L`, `"abc"→-1L`, `"-1"→-1L`, `60500→60500L`, `"60500"→60500L`, `0→0L`, `"0"→0L`. `ABSENT` is a sentinel `Object` so "key not in the body" is distinct from JSON `null` — the distinction §7.3 asks for and that a `null` placeholder would have collapsed. |
| `ReportServiceUnitTest$ExportStockUnitRecord.filterReachesRepository` — `60500L` and `0L` reach `findByClientOffsetAndLimit`; `-1L` and `null` reach `findByOffsetAndLimit` and **never** the filtered method | **VERIFIED, with a FORCED narrowing of the plan's literal matcher** | All four cases present, plus `verify(stockrecordRepository, times(2)).findByOffsetAndLimit("k", 0, 100)`. **Deviation, and it is the plan that is wrong:** §7.3 prescribes `verify(stockrecordRepository, never()).findByClientOffsetAndLimit(any(), anyLong(), anyInt(), anyInt())`. That is **unsatisfiable inside a method that also exercises `60500L` and `0L`** — `anyLong()` matches both of those earlier invocations, so `never()` would red against correct code. The implementation narrows the second matcher to `eq(-1L)` and `isNull()` in two separate `never()` verifications, which grades the same property (neither sentinel reached the filtered method) and is satisfiable. Both `never()` sites keep `anyInt()` on positions 3 and 4, honouring §7.3's Mockito warning; `isNull()` on a **boxed** `Long` carries no unboxing hazard. |
| `fifteenColumnsUnchanged` — the header names and their order are byte-identical to today's | **VERIFIED as content; RENAMED to `exportHeaderNamesAndOrderAreUnchanged`** | The assertion is exactly §7.3's: `ArgumentCaptor<String[]>` on `exportExcelFile`, `containsExactly(...)` over all 15 names in order. **The rename was partly forced and partly voluntary, and I verified which is which:** the original `@DisplayName` ("the 15 export headers") **does** match `TestIdentifierCountArchTest`'s `DISPLAYNAME_COUNT` at `TestIdentifierCountArchTest.java:78` — `"\\b(?:the\|exactly\|all)\\s+([2-9]\|[1-9][0-9])\\s+[a-z]"` matches `the 15 export` — so that half was a **hard build failure**. The method name `fifteenColumnsUnchanged` does **not** match `METHOD_NAME_COUNT` at `:82`, which requires `Exactly`/`All` plus a number-word from `Two`..`Twelve`; so renaming the method was **voluntary**, taken in the direction the rail intends and in the gap the rail leaves. The commit message states this accurately. The count now lives only in the `containsExactly` assertion. |
| `Sbdev3017TrancheGateContextTest` *(no edit)* — the two `exportStockUnitRecord` rows must stay green through P3's signature change | **PARTIAL — execution-dependent** | See §1 item 5. Rows intact at `:212-213`, unedited, and nothing the commit touches can move them. |

Rows in §7.2/§7.3 belonging to **P1** (`StockrecordViewSchemaIT`, 6 rows), **P2** (`StockrecordViewRepositoryFilterIT`
5 rows, `StockrecordViewHalContextTest`, `StockrecordViewRepositoryQueryShapeUnitTest`,
`SdrWriteWithdrawalContextTest`), **P4** (`StockrecordServiceUnitTest`, 2 rows), **P5**
(`Sbdev3017TrancheGateContextTest`'s `allClients` row) and **P6** (all of §7.4) are correctly absent and were
not graded.

---

## 5. Code in the commit that no plan item asked for

Three items. **None is a scope violation; one was forced, two are additions in the plan's own direction.**

### 5.1 `NeverMatcherNullBlindnessArchTest` — inventory `ReportServiceUnitTest:4` → `8`. **FORCED.**

§5.2 P3 does not mention this file, so I checked whether the edit was compelled rather than chosen. It was:

- The rail's second test, `primitiveCapableMatchersMatchInventory` (`:561`), scans every
  `verify(mock, never()).method(` span in `src/test/java`, counts `PRIMITIVE_CAPABLE` matchers
  (`:374-377` — `any(?:Int|Long|Double|Float|Short|Byte|Char|Boolean)\(\)`) inside each span, and asserts
  **zero drift** against the hand-maintained `PRIMITIVE_MATCHER_INVENTORY` (`:441`). It is an inventory, not
  a budget: adding matchers without updating it reds the build.
- **The arithmetic checks out exactly.** At `origin/develop`, `ReportServiceUnitTest` has precisely two
  `never()` spans — `verify(lockOverviewAllDtoViewRepository, never()).findByClientOffsetAndLimit(any(), any(), anyInt(), anyInt())`
  and the `lockOverviewDtoViewRepository` twin — carrying 2 `anyInt()` each = **4**, matching the pre-existing
  entry. P3 adds two more spans in `filterReachesRepository`, each
  `findByClientOffsetAndLimit(any(), eq(-1L)|isNull(), anyInt(), anyInt())` = 2 `anyInt()` each = **+4**.
  4 + 4 = **8**.
- **The justification is sound and was derived the way the rail demands** (from the declaration, not the
  matcher name): `StockrecordRepository.java:120-123` declares `findByClientOffsetAndLimit(String, Long, int, int)`
  — positions 3 and 4 are primitive `int`, so `anyInt()` is required there (a bare `any()` returns `null` and
  NPEs at unboxing); position 2 is a boxed `Long` matched with `eq(-1L)`/`isNull()` and contributes nothing to
  the count. The comment in the inventory says exactly that.
- I also confirmed the rail's **first** test does not object to the new code: `REFERENCE_NULL_BLIND`
  (`:158-163`) matches `anyString()`/`any(X.class)`/`isA(X.class)`/`notNull()` but **not** bare `any()`, so
  the `any()` in position 1 (a `String`) is legitimate and unflagged.

**Verdict: FORCED, correctly reasoned, arithmetically right.** Not unauthorised scope.

### 5.2 `StockrecordExportQueryContractUnitTest` (new, 237 lines). **Not enumerated by the plan; justified.**

No §7.2/§7.3 row and no §5.2 P3 checkbox names this class. Assessment:

- It is the **TDD gate** the repo's own workflow requires, and it is the only gate shape that *can* exist
  here: the behavioural tests (`numericFilterIsForwarded`, `filterValueMatrix`, `filterReachesRepository`)
  cannot **compile** until the signatures land, and a non-compiling test file takes the whole module's lane
  with it. Reflection over `RUNTIME`-retained `@Query`/`@RestResource` is the documented workaround, with
  in-repo precedent (`OnHandQueryContractUnitTest`, `StockrecordRepositoryAdjustmentAlertQueryTest`).
- It grades **three §5.2-P3 requirements that nothing else in §7.2/§7.3 grades**: (a) the byte-identical
  rendered predicate — §3.6 routes this to `unfilteredExportRouteIsUnchanged`, which pins the **row set**,
  not the text, and cannot see the unquoted-`operator` swap that §3.6 warns returns identical rows;
  (b) `@RestResource(exported = false)` on the new method; (c) the plain equality with no disjunction. For
  P2's analogous view repository the plan *did* provide a shape pin (`StockrecordViewRepositoryQueryShapeUnitTest.queryShapeForbidsADisjunction`);
  for P3's native method it provided none. The class is the missing sibling.
- Its fourth case, `serviceAcceptsTheClientIdParameter`, is a pure signature gate with an attributable
  `AssertionError` message.
- It contains one forward-looking assertion worth naming: `unfilteredExportQueryTextIsByteIdentical` also
  asserts `annotation.exported()).isTrue()` on `findByOffsetAndLimit`, with the message "Withdrawing it is
  proposed separately as Q5 and belongs in P6's PR, not here". I verified **Q5 is real** and is about
  `findByKeyword` (§10.2), and that the plan does place any withdrawal in **P6**. So the assertion pins the
  current state and defers the change correctly; it does not pre-empt an open question.

**Verdict: authorised in substance, unenumerated in the plan.** Record it as a plan-document gap (§7.2/§7.3
should have carried a P3 query-contract row), not as scope creep. Two of its four cases pass on the unfixed
build **by design** — they are regression pins, and both say so in their own text, so a later reader cannot
mistake a pin for a gate.

### 5.3 Two extra `StockrecordExportClientFilterIT` cases. **Justified additions** — see §3.

---

## 6. §7.5 — applicable constraint rows

| Row | Applies to P3? | Verdict |
|---|---|---|
| 3 — **Transaction manager / `readOnly`: no `@Transactional` added anywhere**; `ReportService` deliberately exports outside a transaction | **YES** | **VERIFIED.** No `@Transactional` annotation is added by this commit; the two `+@Transactional` diff lines are javadoc prose. The reason is restated at the method (`ReportService.java` javadoc): a fully materialised flat entity, OSIV-off is a non-issue, and a tx would pin a tenant connection for the whole HTTP response. The package rule (bare `@Transactional` = landlord in `service`) is not engaged, because nothing was annotated. |
| 1 — **Jakarta namespace** | Marginally | **VERIFIED.** No `javax.*` import anywhere in the diff. `StockrecordExportQueryContractUnitTest` imports `jakarta.servlet.http.HttpServletResponse`. |
| 8 — Flyway / migration conventions | No | No migration, no `db/migration` change, **no new `*.properties` file** (so the `.gitignore`-swallow trap is not engaged). Correctly untouched. |
| 2, 4, 5, 6, 7 — OSIV, naming strategy, SDR registration, Caffeine, Micrometer | No | All are `StockrecordView`-scoped (P2) or explicitly N/A. Nothing in the diff touches `RestConfiguration`, `CacheConfig` or a metric. Correctly untouched. |

---

## 7. What I could not verify without executing

Stated explicitly, per the hard constraint. None of these is contradicted by the source; all need
reconciliation against the lane that ran them.

1. **Full surefire 6762 run / 0 failures / 0 errors / BUILD SUCCESS.** Not run.
2. **The targeted 101-green figure** and the commit message's "105 assertions" / per-class counts.
3. **`StockrecordExportClientFilterIT` 4/4 against real PostgreSQL.** The class has exactly 4 `@Test`
   methods, which is consistent; the result is not.
4. **The five mutant kills and their attribution.** I verified that for each of the five claimed mutants an
   assertion exists that is *shaped* to catch it, and that the two mutants the plan warns about
   (`(String)` cast → nested `ServletException` not a 200; unquoted `LOWER(p.operator)` → only the
   byte-identical pin can see it) are routed to tests that can in fact see them. The reds themselves were
   not reproduced.
5. **`Sbdev3017TrancheGateContextTest` green** (§1 item 5).
6. **Compilation.** Checked the cheap prerequisites instead: `toFilterId` exists and is `protected static`
   on the inherited `AdminController` (`:98`); `Stockrecord.getClientId()` exists (`:180`);
   `ReportServiceUnitTest` already imports `org.mockito.ArgumentCaptor`, `java.math.BigDecimal` and
   `org.mockito.Mockito.*` (which re-exports `any`/`anyInt`/`anyLong`/`isNull`/`times`/`never`), so the new
   code needed no import hunk; `ReportControllerUnitTest` uses fully-qualified
   `org.junit.jupiter.params.*` inline for the same reason. `BasePostgresIntegrationTest` and the cited
   fixture sibling `StockrecordAdjustmentAlertDoubleToastIT` both exist at the paths the IT's javadoc names.

---

## 8. Two conformance-adjacent notes for the code-review lane

Not conformance failures — both concern whether a *named plan row* will keep grading what §7.2 says it
grades. Flagged here because they bear on the row, not on style.

1. **`unfilteredExportRouteIsUnchanged`'s second assertion is not fixture-scoped.** Its first assertion is
   keyword-scoped (`findByOffsetAndLimit(KEYWORD, 0, 100)` → `containsExactlyInAnyOrder`) and is safe. Its
   second calls `findByOffsetAndLimit(ALL, 0, 100)` — an **empty keyword**, which takes the `or :keyword = ''`
   escape arm and returns the newest 100 rows of the whole committed table — and asserts
   `contains(SR_SYS, SR_B1, SR_B2)`. Per the standing rule that **repository tests in this repo commit and
   do not roll back**, any sibling IT that leaves behind >100 `stockrecord` rows with a later `created` pushes
   the fixture rows off the page and reds this assertion against correct code. Keyword-scoping it, or raising
   the limit, removes the dependency. The `@BeforeEach`-and-`@AfterEach` double wipe protects this class's own
   rows but not other classes' leftovers.
2. **`exportPredicateRendersOnPostgres` says "newest first" but does not grade order.** Both the
   `@DisplayName` and the `as()` description claim "newest first"; the assertion is
   `containsExactlyInAnyOrder`. Since both fixture rows are inserted with `created = now()` in the same
   statement batch, `ORDER BY created DESC` is not deterministic between them — so the assertion is right and
   the **wording** should drop the claim, rather than the assertion being strengthened to match it. A reader
   who fixes it the other way will write a flaky test.

---

## 9. Verdict

**PASS.**

- All **six** §5.2 P3 checkboxes are implemented as written; items 5 and 6 are PARTIAL solely because they
  are execution claims, and the source contains no mechanism by which either would fail.
- **§3.6's API half is implemented in full**, including all three of its non-obvious requirements — the
  byte-identical unfiltered predicate (asserted, not assumed), the quoted `LOWER(p."operator")`, and the
  `ClassCastException`-proof `String.valueOf` read. The UI half is correctly left to P6.
- **Both §7.2 P3 rows and all four §7.3 P3 rows are present** and assert what the plan describes. The one
  placement deviation is not merely defensible but **necessary**: P2's class does not exist on
  `origin/develop`, and both rows exercise `StockrecordRepository` rather than the view repository.
- **One deviation is the plan's error, not the implementation's:** §7.3's prescribed
  `never()).findByClientOffsetAndLimit(any(), anyLong(), …)` is unsatisfiable in a method that also exercises
  the positive cases. The narrowing to `eq(-1L)`/`isNull()` is correct. **§7.3 should be amended** so a later
  reader does not "restore" the prescribed form and red the suite.
- **§7.5 row 3 (no `@Transactional`) is satisfied**; the other rows do not apply to P3 and were correctly
  left alone.
- **Nothing in the commit is unauthorised scope.** The `NeverMatcherNullBlindnessArchTest` edit was **forced**
  by `primitiveCapableMatchersMatchInventory` and its 4→8 arithmetic is exactly right;
  `StockrecordExportQueryContractUnitTest` and the two extra IT cases are additions that grade plan
  requirements the plan's own test tables failed to enumerate. Judgement: **plan-document gaps, not scope
  creep** — and worth back-filling into §7.2/§7.3 so P4–P6 reviewers see the same surface.
- **No plan item is MISSING.**

### Amendments the plan should carry
1. §7.3 `filterReachesRepository` — replace the unsatisfiable `anyLong()` `never()` matcher with
   `eq(-1L)` / `isNull()`.
2. §7.3 — rename the `fifteenColumnsUnchanged` row to `exportHeaderNamesAndOrderAreUnchanged` and note that a
   count in a `@DisplayName` reds `TestIdentifierCountArchTest`.
3. §7.2 — re-file `exportPredicateRendersOnPostgres` and `unfilteredExportRouteIsUnchanged` under
   `StockrecordExportClientFilterIT`, and add the two extra cases the phase actually needed.
4. §7.2/§7.3 — add the P3 query-contract row (the byte-identical text pin, `exported = false`, plain
   equality) that §5.2 P3 item 3 requires but no test table names.

*Verified 2026-09-22 from source only, at `56089a41`. No `mvn` executed; no files in the worktree modified.*
