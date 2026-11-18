head: b503d2e8

# SBDEV-3591 — independent code review, wms2-api

Reviewer lane: code-reviewer (read-only). Scope: `git diff origin/develop...b503d2e8` in
`.claude/worktrees/wms2-api/SBDEV-3591` (9 files, +449/-23). Code read via `git show b503d2e8:<path>`.
No maven run (a `mvn clean verify` was running in the worktree); compile/test status is owned by that run.
Cross-checked the wire shape against `.claude/worktrees/wms2-web-ui/SBDEV-3591` @ 72746f2 (read only).

## Verdict: APPROVE (no High, no Medium; 7 Low + 3 nit)

## Stage 1 — spec conformance (ClickUp ACs + architect consult)

| AC / consult item | Status | Evidence |
|---|---|---|
| Status filter exists | Met (API side) | `ReportController.getDetailView` `@RequestParam(value = "state", required = false) Integer state`; export `exportState(reqMap)` |
| Picked selectable, shows only Picked | Met | JPQL `AND (p.state = :state OR :state IS NULL)`; native `AND (CAST(:state AS integer) IS NULL OR p.state = CAST(:state AS integer))`; IT `pagedView_shouldReturnOnlyPicked_whenStateIsPicked`, `export_shouldReturnOnlyPicked_whenStateIsPicked` |
| Clearing restores normal result set | Met | null state -> `IS NULL` arm true; IT `*_shouldReturnEveryStatus_whenStateIsNull` on both queries; UI omits `&state=` / `exportData.state` when not an integer, so the wire is "absent" |
| Status sort unaffected | Met | Sort is untouched; IT `pagedView_shouldStillSortByState` |
| Shipper filter, search unaffected | Met | Predicates ANDed outside the existing parenthesised keyword/client groups; IT composition cases |
| Pagination unaffected | Met | Derived count query of the JPQL carries the new predicate (count stays consistent with content) |
| Export unaffected / matches screen | Met | Same predicate in native export; 422 contract reused before the `try` |
| Consult (a) native CAST | Kept as defensive; comments now accurate (see below) |
| Consult (b) callers/tests | Met: only callers are `ViewDtoService:1436` and `ReportService:284`; all test mocks updated; `isNull()` added for the absent-state path |
| Consult 2 (no raw `(Integer)` cast) | Met: `wholeNumberOrNull` reused, 422 naming `state` |
| Consult (d) authz/SDR | Unchanged: `@RequiresFunction(WEB_UI_VIEW_PARCEL_PICKING)` on both; repo is `exported = false`, so the new `@Param` adds no HTTP surface |

Nothing extra beyond the request. No other caller of the changed signatures (`git grep` of `findByClientOffsetAndLimit`,
`getParcelPickingReportViewByKeyword`, `exportParcelPickingReport`, `OrderDetailMonitorViewRepository` across `src/main`:
the same-named methods on `Flowbin/ParcelMonitor/Stock/Receiving/LockOverview*` repositories are separate interfaces).

## Specific questions from the lead

- **CAST comment accuracy.** `OrderDetailMonitorViewRepository` now says: "The CAST is defensive, matching MessageRepository:
  Hibernate 6 binds this null Integer typed today (measured: the bare form passes the IT too)." The IT javadoc and the
  contract test say the same. Consistent with each other and with the measured mutant; `MessageRepository:107/109/120` does
  use `CAST(:days AS INTEGER)`. Accurate. (nit N1 on wording.) I could not re-measure the mutant (no maven allowed).
- **JSON `"state": null` vs absent.** Both: `reqMap.get("state") == null` -> `null` -> no filter. Same behaviour. Not
  covered by a test (L3).
- **State outside 200-600** (e.g. 650, 55, -1, 0): accepted, query returns zero rows, 200. Truthful (the view only holds
  200..600), no 500 and no leak. The UI only offers 200..600. Acceptable; no change requested.
- **`row_number() OVER ()` with filtering.** The window function blocks pushdown of the outer `p.state` predicate, so
  `row_id` is numbered over the unfiltered set and then filtered: ids stay unique within one execution (so the
  `@Id`-keyed entity mapping is safe) but are gapped and not stable across executions. That non-determinism is
  pre-existing (no ORDER BY in the window) and the filter does not make it worse; see L6 for the export consequence.
- **Optional-String `= ''` rule.** `state` is `Integer`, so the `OptionalStringFilterEmptyArmArchTest` does not grade it
  and no `= ''` arm is needed; `?state=` (empty) is converted to `null` by Spring for an `Integer` param, i.e. "no filter".
- **Handler-name rule.** `viewEndpointAcceptsOptionalState` keys on `@GetMapping` path `/parcelPickingView`, not the
  handler name, and says why. Compliant.

## Issues

[LOW] L1 — Stale TDD-gate prose in the contract test javadoc and messages
File: src/test/java/net/aim_ai/wms/unit/repo/ParcelPickingStatusFilterContractUnitTest.java (class javadoc; `viewEndpointAcceptsOptionalState`)
Confidence: HIGH
Issue: Written before implementation and not updated. Javadoc: "A behavioural test that calls the new signature cannot
compile until it exists ... This class pins the contract on today's code. The executor's first commit adds the behavioural
tests". Assertion message: "GET /parcelPickingView must declare a 'state' @RequestParam; today it ignores ?state=600 and
returns every status". After b503d2e8 the signature exists, the behavioural tests exist, and "today" is false. A future
reader is told the code ignores `?state=` when it does not.
Fix: Rewrite the "Why reflection" paragraph as "pins the query text and parameter contract; the IT executes it", and change
the message to "... without it, ?state=600 would be ignored and every status returned".

[LOW] L2 — Stale/misleading javadoc on the new nested controller test class
File: src/test/java/net/aim_ai/wms/unit/controller/ReportControllerUnitTest.java (nested `ExportParcelPickingStateFilter` javadoc)
Confidence: HIGH
Issue: "Before this, a raw `(Integer)` cast would 500 on a JSON string such as "600"." There was never a raw cast on
develop; before this change `state` was ignored. The sentence describes a design alternative the consult rejected, not
a prior behaviour. Also "Behavioural pass-through of a valid state is added with the new service signature (executor)."
is a gate-era TODO that is now done (`passesStateFilterToExport`).
Fix: "A raw `(Integer)` cast would 500 on a JSON string such as "600" (ClassCastException), so the value goes through
`wholeNumberOrNull`." Delete the "(executor)" sentence or point at `passesStateFilterToExport`.

[LOW] L3 — JSON `"state": null` is not pinned
File: src/test/java/net/aim_ai/wms/unit/controller/ReportControllerUnitTest.java (`ExportParcelPickingStateFilter`)
Confidence: HIGH
Issue: `exportState`'s javadoc promises "Absent or JSON null means no filter". Absent is covered (the updated
`isNull()` test omits the key). Explicit null is not. A refactor to `reqMap.containsKey("state")` would make
`{"state":null}` a 422 and nothing would fail; a UI that serialises `state: null` (the store's default) would then break
the export for "All Statuses".
Fix: add one case posting `"state":null` and `verify(...exportParcelPickingReport(..., isNull()))` with 200.

[LOW] L4 — The "composes with the shipper filter" IT case cannot detect a broken state arm
File: src/test/java/net/aim_ai/wms/integration/repository/OrderDetailMonitorViewStateFilterIT.java `pagedView_shouldApplyClientAndState_together`
Confidence: HIGH
Issue: `paged(null, "NOT-" + CL_NR, PICKED)` is empty whatever the state predicate does (no rows for that client), so it
only re-proves the existing client filter. The DisplayName claims a composition it does not test. (Composition is in
fact exercised by `pagedView_shouldReturnOnlyPicked_whenStateIsPicked`, which passes `CL_NR` + state, so coverage is not
lost, but this case is near-vacuous.)
Fix: assert a positive composition, e.g. `paged(null, CL_NR, STARTED)` -> `containsExactly(STARTED_NR)`, or drop the case.

[LOW] L5 — Native export: state composed with a non-empty keyword is not executed
File: OrderDetailMonitorViewStateFilterIT.java (export section)
Confidence: MEDIUM
Issue: Both export cases pass `keyword = ""`, so the native query's keyword arm is always short-circuited by
`or :keyword = ''`. The JPQL side has a keyword+state case; the native side, which has different keyword SQL, does not.
A precedence mistake in a future edit of the native WHERE (e.g. dropping the parentheses around the keyword OR) would
not be caught.
Fix: add `findByClientOffsetAndLimit("3591-picked", CL_NR, ASSIGNED, 0, 100)` -> empty and with `PICKED` -> `[PICKED_NR]`.

[LOW] L6 — (pre-existing, not introduced) export pages with OFFSET/LIMIT and no ORDER BY
File: src/main/java/net/aim_ai/wms/repo/jpa/OrderDetailMonitorViewRepository.java `findByClientOffsetAndLimit`
Confidence: MEDIUM
Issue: `... OFFSET :offset LIMIT :limit` with no ORDER BY over a view whose `row_id` is `row_number() OVER ()`. A
multi-chunk export (offset > 0) can duplicate or skip rows between chunks. The status filter does not cause or worsen
this; recorded for completeness, out of scope for SBDEV-3591.
Fix: `ORDER BY p.customer_order_number, p.picking_order_number, p.sku_id` (a deterministic key) in a separate ticket if
anyone exports past 10,000 rows. Not a blocker.

[LOW] L7 — The sort IT does not combine sort with an active filter
File: OrderDetailMonitorViewStateFilterIT.java `pagedView_shouldStillSortByState`
Confidence: MEDIUM
Issue: The case sorts with `state = null`, so it proves sort works on the unfiltered query (which it did before). It does
not prove the AC's "existing Status sort ... unaffected" while a filter is applied (trivially single-valued when state is
set, so the useful pairing is sort-by-another-column + state). Low value either way; noted because the DisplayName says
"alongside the filter".
Fix: rename to "Status sorting still works (unfiltered)" or pass a state and sort by `customerOrderNumber`.

[nit] N1 — Comment says "Hibernate 6 binds" where the typed bind comes from Spring Data JPA + Hibernate
File: OrderDetailMonitorViewRepository.java native-query comment
Confidence: LOW
Issue: The measurement is of the stack, not of Hibernate alone. Harmless; "Spring Data JPA 3 / Hibernate 6 bind this
null Integer typed" is more precise and tells a future upgrader which layer to re-measure.

[nit] N2 — `wholeNumberOrNull` javadoc says callers reject "with the range message"
File: src/main/java/net/aim_ai/wms/controller/ReportController.java `wholeNumberOrNull` javadoc
Confidence: HIGH
Issue: Now has a third caller (`exportState`) whose message is "state must be a whole number (a state code)", not a range.
Fix: "rejected by the caller" (drop "with the range message").

[nit] N3 — Import order / fixture naming
Files: ReportControllerUnitTest.java imports (`ValueSource` inserted between `ParameterizedTest` and `Arguments`);
OrderDetailMonitorViewStateFilterIT.java names the 200 fixture `RELEASED_NR`/"Released (200)" but seeds
`WmsConstants.State.ASSIGNED`. The UI label for 200 may well be "Released", but a reader grepping the constant sees two
names. Also the IT javadoc's "one per state the view holds on WineCo DEV" is an unverified data claim (the consult
records the DB MCPs as unreachable).
Fix: move the import after `MethodSource` or alphabetically; add "(ASSIGNED)" to the comment; soften or cite the DEV claim.

## Open questions (not blocking)
- None at High/Critical. GET `?state=abc` answers 400 (Spring type mismatch; `RestExceptionHandler` has no handler for it)
  while the export answers 422 for a bad `state`. Pre-existing asymmetry shared by `page`/`size`; the UI never sends a
  non-integer, so not worth changing here.

## Checks performed
- Correctness of both predicates and their composition: ANDed after the parenthesised keyword group and client group in
  both queries; no precedence leak. JPQL count query derived from the same WHERE.
- Null passthrough identical to before: null -> `IS NULL` arm true -> predicate is a no-op; both IT null cases assert the
  full fixture set.
- Export 422 contract: `exportState` runs before the `try` (same placement rationale as `exportLimit`'s javadoc); Integer
  only, so "600", 6.5, 3000000000 and "Picked" are 422 naming `state`, with `verifyNoInteractions(reportService)`.
- Callers: none besides the two updated (grep above). Repo not SDR-exported.
- Test strength: removing `p.state = :state` (either query) fails the Picked IT cases; removing the `IS NULL` arm fails
  the null cases; dropping the controller/service pass-through fails the `eq(600)` verifies. Fixture ids derived as
  id+100 / id+200 (36020-36122) collide with nothing under `src/test` (grepped). IT is `*IT.java`, included by failsafe
  (`pom.xml` `<include>**/*IT.java</include>`). IT is client-scoped, so shared-DB residue cannot make it vacuous.
- Security: Integer param, no string interpolation, authz unchanged.
- lsp_diagnostics not run: no maven/LSP in a worktree with a live `mvn verify`; compile is graded by that run.

## Positive observations
- Validation contract reused exactly (`wholeNumberOrNull` + 422 before the `try`), rather than a raw cast.
- The deviation from the consult (CAST kept as defensive) is measured, documented in three places consistently, and the
  contract test deliberately does not pin implementation shape.
- The IT executes both queries on PostgreSQL through the real view, client-scoped, with cleanup on both sides.
- The handler-name rule is honoured with an explanatory comment.
- Existing tests were tightened from `any()` to `isNull()` for the absent-state path rather than loosened.

## Re-review of 69a31e5d

head: 69a31e5d

Scope: `git diff b503d2e8 69a31e5d` only (6 files). Read-only; no maven run (a `clean verify -Pci` was live in the
worktree). The lead reports mutation checks for L3 and L5. I re-derived both on paper (below) and did not execute them.

**Verdict: APPROVE.** All findings that were in scope are resolved. L6 is deferred by decision. One new Low.

| Finding | Verdict | Notes |
|---|---|---|
| L1 contract-test stale prose | **Resolved** | The "What this class pins" paragraph is accurate and names where behaviour is proven. The assertion message is now conditional ("without it ?state=600 would be ignored"). |
| L2 nested-class javadoc | **Resolved** | "a raw `(Integer)` cast would instead 500" now reads as the rejected alternative. The cross-reference `ExportParcelPicking#passesStateFilterToExport` resolves (`ReportControllerUnitTest` nested class at :309, method at :334). |
| L3 JSON null state | **Resolved, not vacuous** | `explicitNullStateIsNoFilter` posts `"state":null` and asserts 200 + `exportParcelPickingReport(..., isNull(), eq(""), isNull())`. A `containsKey` mutant makes `exportState` throw, which gives 422 and fails `status().isOk()`. A mutant that mapped null to a value would fail the `isNull()` verify. The mocks are fresh for each test, so the sibling `verifyNoInteractions` cases cannot interfere. |
| L4 shipper+state composition | **Resolved, not vacuous** | `CL_NR`+STARTED gives exactly `[STARTED_NR]` and `CL_NR`+ASSIGNED gives exactly `[RELEASED_NR]`. Both fail if the state arm is dropped (all 3 rows come back) or if the client arm is dropped (the shared DB could add rows, and `containsExactly` catches extras). |
| L5 native keyword+state | **Resolved, not vacuous** | `"3591-picked"` matches only `LOWER('CO-3591-PICKED')`, through `client_order_number`. PG `CONCAT` skips the NULL `tote_name`, so the match holds. The ASSIGNED+keyword assertion carries the test: an ignored keyword returns `RELEASED_NR`, and an ignored state never reaches it. Dropping the keyword parentheses turns it into `A OR (B AND C AND D)`, so the PICKED row comes back through `A` and the assertion fails. That agrees with the lead's mutation result. The PICKED+keyword assertion alone would be implied by state; it is fine as the positive half. |
| L6 export OFFSET/LIMIT without ORDER BY | **Not fixed, deferred (accepted)** | Pre-existing in all 6 native exports per the lead's census; a recorded finding on the ticket is the right home. Not a blocker for this change. |
| L7 sort test name | **Resolved** | The DisplayName now says "unfiltered" and gives the reason. |
| N1 bind wording | **Resolved** | "Spring Data JPA 3 / Hibernate 6 ... Re-measure on an upgrade of either layer." Accurate, and names the test that measured it. |
| N2 `wholeNumberOrNull` javadoc | **Resolved** | "rejected by the caller". |
| N3 import order / naming / DEV claim | **Resolved** | `ValueSource` is now after `MethodSource` (alphabetical). The javadoc says "Released (200, `ASSIGNED`)". The DEV claim now carries the query, the DB (`dev_wh01_om1`), the date and the counts (200 x149, 500 x3, 600 x161). I could not re-run it because DB MCPs are unreachable in this session. The citation form is adequate. |

### New issue

[LOW] R1: the exemption reason in `TestClassTransactionManagerArchTest` describes the mechanism imprecisely
File: src/test/java/net/aim_ai/wms/unit/config/TestClassTransactionManagerArchTest.java (new `EXEMPT_NON_TRANSACTIONAL` entry)
Confidence: MEDIUM
Quote: "the seed must be committed rather than parked in a test transaction the JdbcTemplate may not share."
Issue: Repo evidence says the JdbcTemplate does not share the tenant test transaction. `ClientRepositoryTransactionDetailIT`
says so: "SBDEV-3258: jdbcTemplate writes auto-commit outside the test transaction". So the seed is committed whether or not
the class is `NOT_SUPPORTED`, and "must be committed rather than parked" names a choice that does not exist. The real
effect of `NOT_SUPPORTED` here is that the read-only repository queries run with no test transaction. That is harmless,
and it matches `HandlingUnitsClientFilterIT`, the closest sibling (JdbcTemplate seed plus native read, `NOT_SUPPORTED`,
listed in the same set at :223). The rail's own javadoc asks that each addition carry a reason a future reader can check,
and this one sends them after a hazard that is not there.
Failure scenario: a later contributor reads "may not share", concludes the IT depends on transaction isolation, and
keeps or copies the exemption on that basis. Or they "fix" it by moving the seed into a transaction, which changes nothing.
Low impact, documentation only.
Fix (either):
(a) Reword: "Same shape as HandlingUnitsClientFilterIT: the fixture is seeded through JdbcTemplate, whose writes
auto-commit outside any test transaction (SBDEV-3258), so the class owns cleanup and runs without one. The queries
under test are read-only." or
(b) Drop `propagation = NOT_SUPPORTED` from the IT and the exemption entry. The class then runs inside the base
`@Transactional("tenantTransactionManager")`, which is allowed because it names the manager. The committed seed is still
visible and still cleaned up by `@BeforeEach`/`@AfterEach`. This shrinks the frozen set, which the rail says is
always welcome. Re-run the IT once if you choose (b).

### Checks on the new code
- The arch-test entry's FQN matches the class (`net.aim_ai.wms.integration.repository.OrderDetailMonitorViewStateFilterIT`)
  and its id range comment (35910-35922 plus +100/+200 children) matches the fixture.
- No production behaviour changed: only javadoc and comments in `ReportController` and `OrderDetailMonitorViewRepository`.
  The query string literals are byte-identical apart from the `//` comment lines.
- No new vacuous assertion was found.

## Re-review of 46c4112c

head: 46c4112c

Scope: `git diff 69a31e5d 46c4112c`. That is one file, `TestClassTransactionManagerArchTest.java`, with +4/-3 lines, all of
them comments in the `EXEMPT_NON_TRANSACTIONAL` entry for `OrderDetailMonitorViewStateFilterIT`. The string set and the code
are unchanged. No maven run.

**Verdict: APPROVE. R1 is resolved (option a).** No new findings.

I checked each claim in the new comment against the code at 46c4112c:
- "same shape as HandlingUnitsClientFilterIT above". True. That entry sits earlier in the same set (:223), and that class
  is also a `NOT_SUPPORTED` IT that seeds through JdbcTemplate and reads through a native query.
- "writes auto-commit outside any test transaction anyway (SBDEV-3258, see ClientRepositoryTransactionDetailIT)".
  True. `ClientRepositoryTransactionDetailIT` :41 says "SBDEV-3258: jdbcTemplate writes auto-commit outside the test
  transaction, so they must be removed explicitly".
- "NOT_SUPPORTED only means the read-only queries under test run with no test transaction, as the report endpoints
  do". True. `ViewDtoService.getParcelPickingReportViewByKeyword` (:1435) and `ReportService.exportParcelPickingReport`
  (:277) carry no `@Transactional`. The class's own javadoc (:118, :362) records `ReportService` as deliberately
  non-transactional, and `spring.jpa.open-in-view=false` (application.properties:91). So production also runs these
  queries with no caller transaction; only Spring Data's per-call repository transaction applies.
- The id-range line is unchanged and still matches the fixture.

## Review of merge 41d9c6bc

head: 41d9c6bc

The merge has parents 46c4112c (feature) and 1544ce39 (develop, SBDEV-2251 PR #581). The merge base is 5e05ab42, the feature's
original base. No maven run.

**Verdict: APPROVE.** The merge is semantically correct. No findings.

### Method
- `git diff 1544ce39 41d9c6bc` lists exactly the 10 SBDEV-3591 files (+480/-26). For each of the three auto-merged files, its hunks
  match the feature's own change hunk for hunk. Nothing from develop was dropped, and no stray text was added.
- `git diff 46c4112c 41d9c6bc` lists exactly develop's 6 SBDEV-2251 files (+370/-2), the same stat as `git diff 5e05ab42 1544ce39`.
  Nothing from the feature was dropped.

### Per file
- **ViewDtoService.java.** Both features are intact and sit in different methods. 2251 adds `dto.put("amtReachable", toInteger(result [7]))`
  in `getCustomerOrderPositionsByOrderId`. 3591 adds the `Integer state` parameter and its forwarding at :1435/:1437. Every main-source
  caller of the three changed signatures uses the new arity: `ReportController:274/:518`, `ReportService:284`, `ViewDtoService:1437`.
  2251 adds no caller of `OrderDetailMonitorViewRepository`, `getParcelPickingReportViewByKeyword` or `exportParcelPickingReport`.
- **ViewDtoServiceUnitTest.java.** Both sides are present, each exactly once:
  - 2251: the extended `Object[]` row with `Integer.valueOf(37)` plus the `amtReachable` assertion, and the new test
    `getCustomerOrderPositionsByOrderId_shouldMapAmtReachable_whenRowCarriesReachable` (:1467).
  - 3591: the `findByKeyword("test", "CL001", null, pageable)` stub and call, and `getParcelPickingReportViewByKeywordForwardsStateFilter` (:2379).

  The two sides touch different nested test groups and different repository mocks (`customerorderPositionRepository` and
  `orderDetailMonitorViewRepository`), so no `when(...)` stub is duplicated, lost or shadowed.
- **TestClassTransactionManagerArchTest.java.** `PickPackReachableColumnIT` (:230, with its reason at :224-229) and
  `OrderDetailMonitorViewStateFilterIT` (the last element) each appear exactly once (`grep -c` = 1 each). A
  `sort | uniq -c` over all 59 string literals inside `EXEMPT_NON_TRANSACTIONAL = Set.of(...)` shows no duplicate, so `Set.of` cannot
  throw `IllegalArgumentException` at class init. The comma sits on the previous last element (`MobilePickingJudgesTheStoredPositionIT",`),
  and the new last element has none before `);`, so the syntax is valid.

### Shared-DB fixture interaction (both are committed, NOT_SUPPORTED ITs)
- 2251's `PickPackReachableColumnIT` draws ids from `seqentities` and deletes only the bounded window (watermark, ceiling]. Its own rail
  asserts the ceiling stays below the 9000 literal-id band. 3591 uses literal ids 35910-36122, so neither class's cleanup can reach the
  other's rows. 3591's queries are scoped to client `SBDEV3591`, so 2251 residue cannot leak into its assertions.
