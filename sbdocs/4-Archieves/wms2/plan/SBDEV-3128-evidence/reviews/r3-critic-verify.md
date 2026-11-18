# SBDEV-3128 r3: Critic verification (r2 -> r3 delta only)

**VERDICT: ITERATE.** 0 High, 2 Medium, 6 Low. Both Mediums are gate-affecting test-instrument text
errors (one or two lines each). The D9 probe design itself is sound.

Code: wms2-api `origin/develop` 207db277; DEV probe 2026-11-01; no working tree read.
## 1. r2-delta findings: are the fixes in the body?
| r2 | In body? | Where |
|---|---|---|
| M-1 | yes | §3.2 rationale, §7.3 mutant swap + "record drop-flushAutomatically green", AC-4b, PM-3. Residue: L-5 and M-2 below |
| M-2 | yes | Principle 5, frozen header :161-165, §3.3 D9 block, §6 row, PM-1, ADR |
| L-1 | yes | §3.2 `resetBounds … and assignedlocation_id`, §3.3 reset row, §3.6 races, AC-9/9b, mutant |
| L-2 | yes | §7.2 paragraph. The D9 premise shift holds: `FixLocationAssignmentServiceUnitTest` has no `verifyNoMoreInteractions` or strict-stubs setting, so a default-`false` probe keeps the five tests green |
| L-3 | **text yes, but infeasible as written** | AC-5b. See **M-1** |
| L-4 | yes | Principle 1, §6, §9 A, ADR |
| missing ×2 | yes | §3.3 reset executor note; §6 "under contention" row |

## 2. D9 probe
- **42703 or aborted transaction:** ruled out. `information_schema.columns` is a view that is readable by
  PUBLIC; a missing column yields no row, not an error. Ran on DEV: `bounds_inherited` -> `f`, `version` -> `t`.
- **`current_schema()`:** holds on DEV. Results: `current_schema()=public`, `search_path="$user", public`,
  the only non-system schema is `public`, the app role `wh01_om1` owns the table, and 13 columns are
  visible. The tenant pool sets only `SET timezone` (`TenantDynamicRoutingDataSource:195,227`), and no main
  code creates a schema or sets `currentSchema`. Not verified on PRD/UAT tenants or in the landlord
  `db_url` strings, because those MCPs failed to connect. See L-1.
- **Fallback = today's data path:** create, adjust, move and popup touch no new column. Overclaim: L-2.
- **AC-20/20b mutants:** both kill their mutants. With "hardcode true", AC-20's `never()` on
  `lockById`/`markOverridden` fails. With "wrong column", AC-20b stays false after `latest`.
- **AC-20c as the only H2 pin:** confirmed. No `BaseIntegrationTest` subclass reaches `getDetailView`,
  `getLocationDetails`, adjust or move (grep, blind spot: MockMvc-indirect calls). The test reaches create
  for real: `MobilePutawayServiceIntegrationTest:309-319`, "No FLA exists yet, so this one creates it".
  **But its instrument is wrong (M-2).**

## 3. Probe extended to move and the popup: consistent
Probe-false move keeps the old triple with no flag; the backfill classifies it when V2.2.45 lands. The
popup omits keys the UI never had. In-call flapping needs a column drop. One window is uncovered (L-6).

## Findings

### M-1. AC-5b cannot run "with no ambient test transaction" in the class it names, so the L-3 mutant stays green
- Plan, AC-5b: "**This method runs with no ambient test transaction** (no class-level `@Transactional`…)",
  in `service/FixLocationAssignmentServiceIT`.
- Code: `FixLocationAssignmentServiceIT:58 extends BasePostgresIntegrationTest`, and that base class carries
  `@Transactional("tenantTransactionManager")` at `BasePostgresIntegrationTest:61`. The annotation is
  inherited. With the mutant "drop `@Transactional` on `adjustUpperBound`", the test's own transaction
  supplies one, `markOverridden` succeeds, and AC-5b stays green. The gate would then encode a mutant that
  cannot go red, which is the same failure class as r2 M-1.
- Confidence HIGH (both annotations read).
- Fix: AC-5b's method gets `@Transactional(propagation = Propagation.NOT_SUPPORTED)`, or the test moves to a
  class that does not extend the base. Seed the fixture through committed writes (`TransactionTemplate`)
  and clean up in `@AfterEach`. Name `BasePostgresIntegrationTest:61` as the annotation being overridden.

### M-2. AC-20c's "(JdbcTemplate)" read cannot see the FLA, so the assertion can never go green
- Plan, AC-20c: "the FLA created by `storeBoxOnLocation_putsWholePalletAway` has `bounds_inherited = true`
  (JdbcTemplate)".
- Code: the H2 `JdbcTemplate` is `new JdbcTemplate(landlordDataSource)` (`TestDatabaseConfig:43-45`), and
  `landlordDataSource` is a `HikariDataSource` (`LandlordDatabaseConfig:38`). The test runs inside
  `BaseIntegrationTest:32 @Transactional("tenantTransactionManager")` and is rolled back. That transaction
  holds its connection under the mock routing DataSource's key, so the template borrows a different
  pooled connection. H2 MVStore runs at READ COMMITTED, so that connection does not see the uncommitted
  FLA, and the read returns `EmptyResultDataAccessException` with or without the implementation.
- Confidence MEDIUM-HIGH: reasoned from the wiring, not run. `TestDatabaseConfig:33-34` says "a row inserted
  here is visible to them", which covers only committed rows written through the template.
- Fix: read in the test's own transaction. After `em.flush()`, run
  `em.createNativeQuery("select bounds_inherited from fix_location_assignment where id = :id")` on the
  tenant persistence unit, or call the new `fixLocationAssignmentRepository.findBoundsInheritedById(fla.getId())`.
  Without the bean, this still turns red with "column not found", so the pin survives.

### Low
- **L-1 `current_schema()` is unverified off DEV.** If a tenant DB had a schema named after its app role
  (`search_path` is `"$user", public`), `current_schema()` would return that schema while unqualified SQL
  still resolves to `public`. The probe would then read false on that tenant indefinitely: edit, clear and
  reset would report "unavailable until V2.2.45", and the feature would silently degrade. Fix: add to the
  deploy prerequisites, for each of the 6 tenant DBs, `select current_schema(), exists(<probe with
  column_name='version'>)`, which must return `public | t`. Optionally, log WARN once per tenant when the
  probe reads false.
- **L-2 "behave exactly as before SBDEV-3128" (Principle 5) and "behave as before SBDEV-3128" (frozen
  header :163-164) overclaim.** `adjust*` becomes `@Transactional` regardless of the probe, so its trigger
  runs post-commit. The probe is also one extra native SELECT with no query spaces. By the r2 M-1 bytecode
  path, it likely forces an early full flush (MEDIUM confidence for a SELECT). Fix: say "take the
  pre-SBDEV-3128 data path (no new column is read or written)". Fix the header before it is checksum-frozen.
- **L-3 Principle 5 contradicts itself.** It says "Every native path that would touch them first runs a
  … probe", then "only the … lists raise 42703". The lists are unprobed native paths. Fix: "every native
  path except the two admin lists (`getDetailView`)".
- **L-4 The D9 rationale's "HTTP 500" is half right.** `FixLocationAssignmentController` catches only
  `BusinessException` (`:83,107,130,162`), so reset would return 500. But `LocationController`'s house
  idiom also catches `Exception` (`:76-78`), so an unguarded edit would return 200 `{errors}` with the SQL
  text. Fix: "500 on reset; on edit, a raw SQL message in `{errors}`".
- **L-5 Stale residue.** The §9 A+G row says "flag writes need `flushAutomatically` + an `== 1` guard",
  which contradicts §3.2 "not load-bearing". The same row says "about 9 native repository methods", but
  the ADR says "ten". Separately, the §7.3 mutant offers "(or run create under `FlushMode.COMMIT`)". That
  alternative is equivalent while `flushAutomatically = true`, because Spring Data's modifying execution
  calls `em.flush()` explicitly, as §3.2's own "independent of FlushMode" says. Fix: delete the alternative.
- **L-6 PM-1's "FLAs created meanwhile … are classified by the backfill" misses a window.** An FLA can be
  inserted after the migration commits but by a transaction that did not see it: a pre-3128 pod during a
  rolling deploy, or a probe-false transaction that has not yet locked FLA or location. Such an FLA gets
  `DEFAULT false` after the backfill has run, and stays Overridden permanently. This is fail-safe
  (edits do not propagate; the operator can reset). Fix: one sentence in PM-1 and O-4 noting that such
  rows are expected and that a reset fixes them.

## 4/5. Header, Principle 5 and completeness words
- Residual surface "only the Storage Locations and Fixed Locations lists raise 42703": **holds.** Method:
  §3.2's native list, plus a caller grep. `ViewDtoService:876,905` are the only callers of the two
  `getDetailView`, reached only from `LocationController:52` and `FixLocationAssignmentController:56`.
  Blind spot: UI screens that reuse those endpoints (r2 ruled this out). Exactness issues are L-2 and L-3.
- "one present implies all": holds (one transactional migration; no `CONCURRENTLY`/`executeInTransaction`).
- "every guarded path", "every replica sees it", "`never()` on every write": scoped and checkable.
  "exactly today's behaviour" (§3.3 create, Principle 5): see L-2.

## Ruled out
Probe raising 42703/42501 or aborting the transaction · probe flapping within a call · inconsistent move
state on a probe-false tenant · AC-20/20b mutants surviving · another H2 pin on the bean · the 5 legacy
unit tests going red (no `verifyNoMoreInteractions`) · a `getLocationDetails` exact-key assertion · the
`markInherited`-before-`save` mutant (null id, 0 rows, AC-4b red) · `resetBounds` predicate correctness.

## Verdict justification
ITERATE on M-1 (mutant cannot go red) and M-2 (assertion cannot go green). L-1..L-6 same pass; L-2
before the header freezes. APPROVE once AC-5b gets `NOT_SUPPORTED` (or a separate class) with committed
seeding and AC-20c reads inside the test transaction; no further critic round needed if they match.
