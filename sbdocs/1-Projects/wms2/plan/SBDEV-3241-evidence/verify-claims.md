# SBDEV-3241 — adversarial fact-check of seven claims

**Date:** 2026-09-06
**Target:** worktree `/home/nampark/dev/wms-claude/.claude/worktrees/wms2-api/SBDEV-3241`,
branch `bugfix/SBDEV-3241-2099-marker-audit`, base `origin/develop` @ `d4a6ab8a`
(confirmed: `git merge-base HEAD origin/develop` = `d4a6ab8a7da61e6b6918d3662bb7dc6ab8357733`,
`d4a6ab8a` = "Merge pull request #305 from SiteBossInc/claude/sbdev-3226-1xaq2q").
**Mode:** read-only. No git state mutated, no file in the worktree written, no maven run.
All code facts read out of the object database at `d4a6ab8a` (`git show d4a6ab8a:<path>`,
`git grep <pat> d4a6ab8a`), not out of the dirty working tree.

**Scoreboard**

| Claim | Verdict |
|---|---|
| 1 — 27 markers / 26 classes / 21+6 split; no larger variant population | **CONFIRMED** (two wording corrections; one scope gap) |
| 2 — SBDEV-2099 is a closed WMS v1 UI bug | **CONFIRMED** (one caveat: it *does* have a v2 fix lineage) |
| 3 — landlord datasource IS configured; base classes; none is `BasePostgresIntegrationTest` | **CONFIRMED in substance, REFUTED as stated** — there is a *third* base class |
| 4 — 95/0/0/61 vs 95/14/12/0, therefore 61 suppressed, 35 pass, 26 broken | **CONFIRMED** — but "95 run" does **not** mean 95 executed; see below |
| 5 — the 26 break for exactly five distinct causes | **CONFIRMED** as a proximate-cause partition (enumerated all 26, none unaccounted) |
| 6 — the 4 × 403 share SBDEV-3239 AC-4's root cause | **CONFIRMED** — same mechanism, proven by elimination, and 2 of the 4 are byte-identical tests |
| 7 — 6318/6/0/32, 6 pre-existing, 67−32=35 corroborates | **CONFIRMED**, but the corroboration is **algebraically circular**; a genuine independent reconstruction is given below |

---

## CLAIM 1 — the marker population — **CONFIRMED**

**Instrument.** `git grep -n -F "<exact reason string>" d4a6ab8a -- '*.java'`, then a
column-classifying pass over the hit lines; separately five variant sweeps against
`src/test/**/*.java` at the same SHA.

**Numbers.**

- Exact reason string `Pre-existing env issue: landlord datasource not configured (SBDEV-2099 env skip)`:
  **27 occurrences across 26 files**, all of them under `src/test/` — nothing in `src/main`.
- Column split: **21 begin at column 0**, **6 are indented**, **0 are neither** — i.e. every one of
  the 27 is a real `@Disabled(` annotation, no comment sneaks into the exact-string count.
- The naive-grep discrepancy is exactly as you described: `git grep -n "SBDEV-2099"` returns 45 lines
  tree-wide / 35 in `src/test`, and the extra hit in that file is
  `unit/repo/CustomerorderBatchRepositoryTest.java:43` — a `//` comment reading
  "Class-level @Disabled due to pre-existing SBDEV-2099 env issue (landlord datasource)." It does
  not carry the exact string and is correctly excluded.

**Two wording corrections (neither changes the count):**

1. **All 6 indented markers are on `@Nested` classes. None is method-level.** Read at each site, the
   preceding two lines are `@Nested` + `@DisplayName` in all six cases:
   `PickingControllerUnitTest:377` (`class ProcessPick`), `CleanUpOldMessagesJobUnitTest:71`
   (`DoCalculation`), `OrderReleaseJobUnitTest:149` (`DoCalculation`),
   `ReleaseExpiredPickingOrdersFromUserJobUnitTest:43` (`DoCalculation`),
   `SequenceTransactionServiceUnitTest:46` (`GetNextSequenceNumber`) and `:228` (`EdgeCases`).
   So "nested class **or method** level" should be just "nested class level".
2. **"27 markers across 26 test classes" is 27 markers across 26 *files*.** At JUnit container
   granularity it is 27 markers on **27 distinct classes** — 21 top-level plus 6 nested — because the
   6 nested markers sit inside 5 files whose top-level class is *not* itself disabled. Either
   phrasing is defensible; "26" is the file count, and it is worth saying which unit you mean when
   the number reappears next to a class-count elsewhere.

**Variant hunt — the population is NOT larger than 27.** Five sweeps, all at `d4a6ab8a`, all over
`src/test/**/*.java`:

| Sweep | Result |
|---|---|
| Any `@Disabled` / `@Ignore` line | 98 hits; subtracting the 27 leaves 71, every one inspected |
| Line-wrapped `@Disabled(` (opening line not ending in `)`) | **13 exist** — so the risk was real — but none of the 13 continuation blocks mentions SBDEV-2099. Cross-checked against the complete 45-line `SBDEV-2099` grep: none of those 13 files appears in it |
| Bare `@Disabled` with no reason | **0** |
| `@DisabledIf*` / `@DisabledOn*` / `@EnabledIf*` | **0** |
| `assumeTrue` / `assumeFalse` / `Assumptions.` | **0** |

So there is no alternate-wording, wrapped, bare, conditional or assumption-based hiding place. **27 is
the complete population of that marker string.**

**Blind spot of this instrument.** It matches one literal string. It is blind to (a) suppression by a
*different* mechanism than an annotation — notably `pom.xml` surefire `<excludes>` (SBDEV-3239
documents `**/*IntegrationTest.java` / `**/*E2ETest.java` excluded at `:564-567`), which silences
tests with no marker at all; and (b) *semantically identical* markers under another ticket number,
which is the real scope gap below.

### Scope finding: 3 near-identical markers make the same landlord claim under SBDEV-2217

These are **out of** the 27 and unaffected by the branch, but they assert the same disproven cause:

- `integration/repository/ClientRepositoryIntegrationTest.java:259` — method-level, reason text:
  *"…BasePostgresIntegrationTest cannot boot — landlord datasource env issue, HikariConfig 'dataSource
  or jdbcUrl is required' (**same root cause as BillofladingPositionRepositoryTest @Disabled**…)"*.
  That explicit cross-reference names one of the 27 as its precedent.
- `integration/OrderReleaseSectionQueryIT.java:52` and `service/FixLocationAssignmentServiceIT.java:41`
  — both wrapped, both "Pre-existing IT-lane block: BasePostgresIntegrationTest cannot boot (SBDEV-2217
  landlord …".
- Plus 8 legacy classes reading "AppPostgresDBSetupExtension doesn't configure landlord datasource".

Those are SBDEV-3239's territory (its AC-3 covers them), so this is a *boundary* note, not a defect.

### Corroboration you may not have noticed: the repo already disputed its own markers

Four in-tree sites at `d4a6ab8a` state the reason is wrong, in `src/test`:

- `unit/schedulejob/CleanUpOldMessagesJobUnitTest.java:101`, `OrderReleaseJobUnitTest.java:179`,
  `ReleaseExpiredPickingOrdersFromUserJobUnitTest.java:73` — all three: *"The @Disabled reason above is
  also inaccurate — enabling this class fails with 'advisoryLockService is null', i.e. unwired mocks,
  not a missing landlord datasource."*
- `unit/schedulejob/AdminTriggerTenantScopeUnitTest.java:106-107` — *"Their @Disabled reason is also
  wrong…"*

And `smoke/WebContextLaneContextTest.java:32` records that whether these markers have any remaining
cause is unsettled. SBDEV-3239's body already says "three of those record in-file that their own
reason string is wrong". Independent agreement; the audit is not the first witness.

---

## CLAIM 2 — SBDEV-2099 in ClickUp — **CONFIRMED**

**Instrument.** `clickup_get_task SBDEV-2099` with `include: ["description"]`.

- `custom_id` **SBDEV-2099**, id `868j7bk2z`, task_type **Bug**.
- Title, verbatim: **"WMSV1 - Outbound Parcel Report Clears Results After Palletizing with filter set
  \"Unpalletized\""**.
- `status`: **Closed** (`date_closed` = 1781189223332 → 2026-06-07). List: Fulfillment Development
  Backlog. Priority high. Tags include `desktop`, `outbound`, `parcel`, `report`, `palletizing`.
- Body self-describes as *"a **UI / state refresh issue**"*, root-cause guesses *"Filter state not
  re-applied correctly after mutation / Table data not being re-fetched or re-rendered"*. Zero
  occurrences of "landlord", "datasource", "Java", "Spring", "H2" or "test" in the description.

**Caveat that narrows the "nothing to do with v2" half of the claim.** SBDEV-2099 *does* have a v2
lineage — it just has nothing to do with disabled tests or a datasource. At `d4a6ab8a` the wms2-api
repo carries `docs/plan/v2-fixes/SBDEV-2099-outbound-parcel-report-clears-after-palletize.md`
("Fix 1: ParcelMonitorViewRepository (3 queries — Primary SBDEV-2099 target)"), the house rule in
`CLAUDE.md:182` cites it for the empty-string JPQL filter pattern, `repo/jpa/LocationRepository.java:274`
and `repo/jpa/UnitloadRepository.java:239` cite it in production javadoc, and five test `@DisplayName`s
in `ReportControllerUnitTest` / `ViewDtoServiceUnitTest` are named after it. So say **"a closed v1 UI
report-filter bug, whose v2 counterpart is a JPQL empty-string fix, and which has nothing to do with a
landlord datasource or a test harness"** rather than "nothing to do with v2" — the latter is
attackable and the former is not.

**Blind spot.** A ClickUp read is a point-in-time snapshot; a re-open would invalidate the "Closed"
half. `date_updated` is 1787755020694 (2026-08-25), well before today.

---

## CLAIM 3 — the landlord datasource IS configured — **CONFIRMED in substance, REFUTED as stated**

**Instrument.** For each of the 26 marker-bearing files at `d4a6ab8a`, `git show` piped through a
`class X extends Y` extractor (all 26, not a sample), plus a direct `grep BasePostgresIntegrationTest`
over the same 26, plus `git show d4a6ab8a:src/test/resources/application-integration.properties`.

**Where the claim is right:**

- `BaseRepositoryIntegrationTest` (`src/test/java/net/aim_ai/wms/common/base/`) carries
  `@SpringBootTest(classes = StartApplication.class)`, **`@ActiveProfiles("integration")`**,
  `@Import(TestDatabaseConfig.class)`, `@Transactional`.
- `application-integration.properties:9` sets
  `landlord.datasource.jdbc-url=jdbc:h2:mem:wms_integration;DB_CLOSE_DELAY=-1;MODE=PostgreSQL;DATABASE_TO_LOWER=TRUE`
  plus username/password/driver/pool. Its own header says it backs *both* landlord and tenant
  datasources with one H2 instance. **The reason string is factually false for these classes.**
- **None of the 26 extends `BasePostgresIntegrationTest`** — grep for that symbol across all 26 files
  returns zero hits. That base class is the one that genuinely cannot boot (it has no
  `@ActiveProfiles`, per SBDEV-3239), and it is not in this population.

**Where the claim is wrong: there are THREE base classes, not two.**

| Base class | Count | Which |
|---|---|---|
| `BaseRepositoryIntegrationTest` | **21** | 14 `unit/repo/*RepositoryTest`, 5 `unit/service/*` (`AdviceServiceH2Test`, `CustomerorderServiceTest`, `PickingorderBusinessServiceH2Test`, `PickingorderServiceH2Test`, `mobile/MobileReplenishServiceH2Test`), and both `unit/controller/*H2Test` |
| `BaseServiceUnitTest` | **4** | `CleanUpOldMessagesJobUnitTest`, `OrderReleaseJobUnitTest`, `ReleaseExpiredPickingOrdersFromUserJobUnitTest`, `SequenceTransactionServiceUnitTest` |
| **`BaseControllerUnitTest`** | **1** | **`unit/controller/mobile/PickingControllerUnitTest`** — not named in the claim |

The substance survives: `BaseControllerUnitTest` and `BaseServiceUnitTest` both extend
`BaseUnitTest`, which is `@ExtendWith(MockitoExtension.class)` and nothing else — no Spring context,
no datasource of any kind. So the "plain Mockito" characterisation is true of the 5 non-Spring
classes; it is just spread over two base classes rather than one. **Fix the sentence, keep the
conclusion.** As written it is a completeness claim ("either A or B") that a reviewer disproves with
one grep, which costs you the surrounding argument for free.

**Blind spot.** `extends` is a static read; it cannot see a `@TestPropertySource`, a
`@DynamicPropertySource` or a `TestDatabaseConfig` override that re-points the landlord URL at
runtime. That risk is retired empirically by CLAIM 4 — with the markers off, 21 of these 26 classes
run green against exactly this configuration, which is a stronger disproof of "landlord datasource
not configured" than any amount of reading.

---

## CLAIM 4 — the two runs and the 61 / 35 / 26 arithmetic — **CONFIRMED**, with one important reading correction

**Instrument.** Independent re-parse of the two logs and of the 43 saved surefire XML files
(`xml.etree` over `TEST-*.xml`, summing the `tests`/`failures`/`errors`/`skipped` attributes), plus a
per-class decomposition of both `Skipped` columns.

**Both totals reproduce exactly:**

- Baseline (`3241-baseline.log:1050`): `Tests run: 95, Failures: 0, Errors: 0, Skipped: 61`.
  Per-class skip lines sum to **exactly 61** across 27 report units.
- Deactivated (`3241-run.log:2803`): `Tests run: 95, Failures: 14, Errors: 12, Skipped: 0`.
  Independent XML sum over the 43 files in `3241-reports-DEACTIVATED`:
  **tests=95, failures=14, errors=12, skipped=0** — matches the log line, so the saved reports are
  genuinely from that run and not a stale directory.

### The correction: "95 tests run" does not mean 95 tests executed

Surefire counts skipped tests **inside** `Tests run`. The per-class lines prove it directly — e.g.
`Tests run: 2, Failures: 0, Errors: 0, Skipped: 2 -- in …ClientRepositoryTest`, and
`Tests run: 7, …, Skipped: 7 -- in …SequenceTransactionServiceUnitTest$EdgeCases`. So the baseline
**executed 34** tests, not 95. Write it as "95 collected, 34 executed, 61 skipped" — a reader who
takes "95 run / 0 failures" at face value will conclude the suite was green when two-thirds of it
never fired, which is precisely the failure mode this ticket exists to correct.

### The attribution holds, and is independently checkable

`61 − 26 = 35` is legitimate **only** if every one of the 26 failures/errors falls inside the set that
was previously skipped. It does. Matching the two decompositions unit by unit:

| Report unit | baseline skipped | deactivated F+E |
|---|---|---|
| `SequenceTransactionServiceUnitTest$GetNextSequenceNumber` | 9 | 9 |
| `SequenceTransactionServiceUnitTest$EdgeCases` | 7 | 7 |
| `PickingControllerUnitTest$ProcessPick` | 3 | 3 |
| `CustomerOrderControllerH2Test` | 2 | 2 |
| `ReplenishOrderControllerH2Test` | 2 | 2 |
| `CustomerorderBatchRepositoryTest` | 3 | 1 |
| `CleanUpOldMessagesJobUnitTest$DoCalculation` | 2 | 1 |
| `ReleaseExpiredPickingOrdersFromUserJobUnitTest$DoCalculation` | 2 | 1 |
| all other units | 31 | 0 |

Every failing unit is a previously-skipped one; **no unit that executed in the baseline fails in the
deactivated run**. Therefore 95 − 26 = 69 passed, of which 34 were already passing, leaving
**35 newly-passing**, which equals 61 − 26. The inference is sound.

"Zero pre-existing failures in those classes" is also true — but note it is a *weak* statement in the
baseline, because only 34 of the 95 were in a position to fail. Its strength comes from the
deactivated run, where all 95 ran and only previously-skipped ones broke.

**Run hygiene checks I ran against the known false-red traps.** File mtimes show the runs were
strictly sequential — `3241-run.log` 21:09:21, `3241-baseline.log` 21:10:15, `3241-fullsuite.log`
21:17:29 — so no two maven processes shared the worktree, which rules out the concurrent-Maven
false-red pattern. The failure signature also argues against it: 26 specific, individually explicable
failures rather than a wall of context-init errors. Both runs collected the identical 95, which rules
out scope drift between them.

**Blind spot.** These are single runs; nothing here would expose an order-dependent or flaky test.
Two of the causes are order-sensitive in principle (Mockito strict-stubs state, and a `@Transactional`
H2 fixture), so a repeat run is the cheap confirmation if any number is load-bearing for a decision.

---

## CLAIM 5 — five distinct causes — **CONFIRMED** as a proximate-cause partition

**Instrument.** Per-`<testcase>` extraction of every `<failure>`/`<error>` node from the 43 XML files:
class, method, kind, exception type, message. All 26 enumerated; none unclassified.

| n | Site | Exception | Message |
|---|---|---|---|
| 16 | `SequenceTransactionServiceUnitTest$GetNextSequenceNumber` (9) + `$EdgeCases` (7) | 7 `UnnecessaryStubbingException` + 9 `AssertionFailedError` | "Unnecessary stubbings detected"; `expected: 101L but was: 0L` etc. |
| 4 | `CustomerOrderControllerH2Test` (2), `ReplenishOrderControllerH2Test` (2) | `AssertionError` | `Status expected:<200> but was:<403>` |
| 3 | `PickingControllerUnitTest$ProcessPick` | `ServletException` **wrapping** `EntityNotFoundException` | "PickingOrder not found with id: " |
| 2 | `CleanUpOldMessagesJobUnitTest$DoCalculation`, `ReleaseExpiredPickingOrdersFromUserJobUnitTest$DoCalculation` | `NullPointerException` | `Cannot invoke "…JobMetrics.markLastRun()" because "this.jobMetrics" is null` |
| 1 | `CustomerorderBatchRepositoryTest.findStaleClubBatchIds_shouldReturnBatch_whenAllOrdersTerminal` | `AssertionError` | "[Seeded all-terminal CLUB batch must be returned] Expecting actual not to be empty" |

16 + 4 + 3 + 2 + 1 = **26**. The counts and the class attributions are all correct.

**Two refinements:**

1. **The surefire `type` for the ProcessPick three is `ServletException`, not `EntityNotFoundException`.**
   Your description names the root cause, which is the more useful label — just do not expect a
   reader grepping the XML for `EntityNotFoundException` in a `type=` attribute to find it.
2. **The 16 are genuinely ONE cause, and you can say so more strongly than "two exception types".**
   Read at the source: `SequenceTransactionServiceUnitTest:53` stubs
   `losSequencenumberRepository.findByClassname("TEST_KEY")`, while
   `SequenceTransactionService.getNextSequenceNumber` (`src/main/.../SequenceTransactionService.java:28`)
   calls **`findByClassnameForUpdate(key)`** — a pessimistic-lock variant. The stub therefore never
   matches: the unstubbed call returns `Optional.empty()`, the service takes the else-branch and
   returns `returnSeq = 0L` (hence every `but was: 0L`), and the never-used stub trips
   `MockitoExtension`'s default STRICT_STUBS at `afterEach` (hence every
   `UnnecessaryStubbingException`). **One production-signature drift, two symptoms** — the test was
   parked before the method was renamed and has never run since.

**On the word "exactly".** Five is a correct *proximate* partition and the enumeration is complete, so
the claim stands. But note that four of the five (16, 3, 2, 1) are all instances of the same
meta-cause — *a fixture that drifted out from under a marker while nothing executed it* — and only the
403s are a production-behaviour change. That framing is more useful in a ticket than "five causes",
because it says why the markers were expensive rather than merely that they were wrong.

**Blind spot.** Symptom-level classification from XML cannot prove two same-typed failures share a
root; I read the source to establish the 16, and took the 2 NPEs on the in-tree explanation (the class
declares `@Mock` for 4 of the production constructor's 6 dependencies, so `@InjectMocks` leaves
`jobMetrics` null). The single `CustomerorderBatchRepositoryTest` failure I did **not** trace to
source — its own in-file `TODO(SBDEV-2164)` says the seeding was never written, which is consistent,
but I did not independently verify that.

---

## CLAIM 6 — the 403s vs SBDEV-3239 AC-4 — **CONFIRMED** (the claim you were least confident in is the one that survives best)

This needed proof by elimination, because a 403 in a Spring MVC test has at least three possible
producers and the stack traces show only `AssertionErrors.assertEquals` — they name no mechanism.

**First: SBDEV-3239 AC-4, read verbatim.** *"`ClientRepositoryIntegrationTest` boots (12 errors → 0),
and the 4 `CustomerOrderControllerIntegrationTest` `403`s are resolved by granting the required
functions in the fixture — **not** by relaxing a gate."* Its cause table attributes those 4 to *"the
function-gating programme landed and the test grants no functions."*

**Candidate producers of the 403, and how each was settled:**

| Candidate | Verdict | Evidence |
|---|---|---|
| CSRF (would explain the POST only) | **ruled out** | `SecurityConfiguration.java:131` — `.csrf(AbstractHttpConfigurer::disable)`, globally |
| The Spring Security chain's `/v3/**` authority rule | **ruled out** | The rule exists (`.requestMatchers("/v3/**", "/putawayConfig/**").hasAnyAuthority(Authority.WMS_USER_ROLE)`, and `WMS_USER_ROLE = "wms_user"`, which `@WithMockUser(roles={"ADMIN"})` → `ROLE_ADMIN` would **not** satisfy) — **but the chain is not present in these tests.** `SecurityConfiguration` is `@ConditionalOnProperty(prefix="rest.security", value="enabled", havingValue="true")` and `application-integration.properties:49` sets `rest.security.enabled=false`; the same file's `spring.autoconfigure.exclude` additionally removes `SecurityAutoConfiguration`, `SecurityFilterAutoConfiguration` and `OAuth2ResourceServerAutoConfiguration`. No filter chain, no 403 from it. |
| A `@PreAuthorize` on the base controller | **ruled out** | `AdminController` carries `@PreAuthorize(Authority.IS_SB_ADMIN)` only on its `/user/*` methods (`:79, :107, :120, :133`), none of which is on these four routes |
| **`FunctionGuardInterceptor`** | **the producer** | Registered unconditionally as a `MappedInterceptor` bean on `/**` (`WebConfig.java:86-87`), in a plain `@Configuration` with no profile guard — so it is live in exactly the context where the security chain is absent. `preHandle` reaches `accessService.checkAnyAccess(username, annotation.value())` and on denial calls `deny(...)`, which does `response.setStatus(HttpStatus.FORBIDDEN.value())` (`FunctionGuardInterceptor.java:352`) |

**All four routes are `@RequiresFunction`-annotated at `d4a6ab8a`:**

- `CustomerOrderController.java:114` — `@RequiresFunction(WEB_UI_VIEW_ORDER)` on
  `POST /batchUpdatePriorityByOrderIds`
- `CustomerOrderController.java:154-157` — `@RequiresFunction({WEB_UI_VIEW_ORDER, WEB_UI_VIEW_CLUB_LINE,
  WEB_UI_VIEW_BILL_OF_LADING, WEB_UI_VIEW_PICKING_ORDER})` on `GET /detailsByOrderId/{orderId}`
- `ReplenishOrderController.java:197` — `@RequiresFunction(WEB_UI_VIEW_REPLENISHMENT_ORDER)` on
  `GET /cancelReplenishOrder/{id}`
- `ReplenishOrderController.java:341` — same function, on `GET /replenishorderDetailsById/{id}`

`@WithMockUser(username="admin", …)` produces a principal whose username has no WMS user row in the
H2 fixture, so `checkAnyAccess` denies. **Same mechanism, same description, as AC-4.**

**And it is closer than "same mechanism" — two of the four are the same test.**
`unit/controller/CustomerOrderControllerH2Test.detailsByOrderId` and
`.batchUpdatePriorityByOrderIds` are **byte-for-byte identical** in route, `@WithMockUser`, request
body and assertions to `integration/controller/CustomerOrderControllerIntegrationTest$HappyPath`'s two
methods of the same names — a duplicated pair, one copy in each lane. Both lanes even run the same
Spring profile: `BaseControllerIntegrationTest` → `BaseIntegrationTest` carries
`@ActiveProfiles("integration")` (`:23`), exactly as `BaseRepositoryIntegrationTest` does. So the two
sets are not merely alike, they are the same test executing under the same context configuration.

**Two boundaries worth stating on the ticket, since "same cause" invites a wrong inference:**

1. **AC-4 as written does not cover these.** It names `CustomerOrderControllerIntegrationTest` (and
   bundles in `ClientRepositoryIntegrationTest`'s 12 boot errors, which are a *different* cause).
   Granting functions in *that* class's fixture fixes nothing in `CustomerOrderControllerH2Test` or
   `ReplenishOrderControllerH2Test` — separate classes, separate absent fixtures. The recipe
   transfers; the fix does not.
2. **The two `ReplenishOrderControllerH2Test` failures need a different function**
   (`WEB_UI_VIEW_REPLENISHMENT_ORDER`, not `WEB_UI_VIEW_ORDER`), so "same root cause" is true at the
   mechanism level and false at the missing-grant level.

**Blind spot.** I proved the producer by eliminating the alternatives from configuration and source; I
did **not** capture a response body or an `X-Authz-Denied` header from a live run, because that would
have required editing the worktree. The decisive direct instrument, if you want it, is one run of
these two classes with the marker off and `.andDo(print())`, or an assertion on
`header().exists(Authority.AUTHZ_DENIED_HEADER)` — that header is emitted by `FunctionGuardInterceptor`
and nowhere else, so its presence would settle it in one line.

---

## CLAIM 7 — full suite and the 67 → 32 corroboration — **CONFIRMED**, with the corroboration re-derived

**Instrument.** `3241-fullsuite.log` re-parsed: the Results line **and** a full decomposition of every
class line carrying `Skipped: >0`.

- `3241-fullsuite.log:65417` — `Tests run: 6318, Failures: 6, Errors: 0, Skipped: 32`. **Confirmed.**
- All 6 failures are `StockunitServiceUnitTest`: `$RemoveLock` ×3 (`:795`, `:777`, `:831`),
  `$SetLockDamagedExtended.throwsWhenAlreadyLocked` (`:1090`), `$SetLockOnHoldExtended` ×2 (`:887`,
  `:871`). **Confirmed**, and SBDEV-3239 independently attributes exactly these to SBDEV-3226
  ("it changed six `BusinessException` messages without updating `StockunitServiceUnitTest`").
- Lane: `surefire:3.2.5:test`, one invocation. Same lane as SBDEV-3239's surefire row.

### Was 67 measured under the same command and scope? Yes — and I can reconstruct it without trusting the ticket

SBDEV-3239's description says: *"Measured on a clean throwaway worktree at `origin/develop` @ `d4a6ab8a`
(2026-09-06)… surefire (unit) | 2m 01s | **6318 tests — 6 failures, 67 skipped**"*. Same SHA, same
lane, and the **collected total 6318 is identical** to the branch's — which is the control that matters,
since a scope difference would move the total. So the comparison is like-for-like.

Better, the 32 decomposes in a way that **regenerates 67 from branch-local data alone**:

| Skipped unit, branch tip | n | Category |
|---|---|---|
| `SequenceTransactionServiceUnitTest$GetNextSequenceNumber` | 9 | 2099 marker still in tree |
| `SequenceTransactionServiceUnitTest$EdgeCases` | 7 | 2099 marker still in tree |
| `PickingControllerUnitTest$ProcessPick` | 3 | 2099 marker still in tree |
| `CustomerOrderControllerH2Test` | 2 | 2099 marker still in tree |
| `ReplenishOrderControllerH2Test` | 2 | 2099 marker still in tree |
| `CustomerorderBatchRepositoryTest` | 1 | **new** SBDEV-3241 marker |
| `CleanUpOldMessagesJobUnitTest$DoCalculation` | 1 | **new** SBDEV-3241 marker |
| `ReleaseExpiredPickingOrdersFromUserJobUnitTest$DoCalculation` | 1 | **new** SBDEV-3241 marker |
| `KeycloakServiceTest` | 3 | unrelated, pre-existing |
| `ClientRepositoryIntegrationTest$GetTransactionDetailSmokeTest` | 2 | unrelated, pre-existing |
| `TenantPoolEndpointSecurityTest` | 1 | unrelated, pre-existing |
| **total** | **32** | |

Re-suppressed = 23 + 3 = **26**, exactly the broken set. Unrelated residue = **6**. Therefore the base
figure must have been 6 + 61 = **67**. That reconstruction uses only the branch's own log and the
CLAIM 4 numbers, so 67 is corroborated *without* leaning on SBDEV-3239's description at all.

### The circularity to strike from the writeup

**"67 − 32 = 35 corroborates the 35 re-enabled tests" is not an independent instrument.** The branch's
skipped count is, by construction, `67 − 61 + 26`. Rearranged, `67 − 32 = 61 − 26 = 35` — the identity
is forced by the same two numbers the claim is trying to support. It cannot fail unless the arithmetic
is wrong, so it corroborates nothing about whether those 35 *pass*.

What the 32 genuinely proves is worth more, and is what the ticket should say: **the full-suite skip
count moved by exactly the predicted amount, confirming that 61 tests were suppressed, 26 were
re-suppressed, and nothing else in the suite changed** — with the 6318 constant as the control that no
tests were added or removed. The evidence that 35 *pass* is CLAIM 4's deactivated run, and only that.

### Two smaller notes

- Neither run used `clean` (`3241-fullsuite.log` reports "Nothing to compile - all classes are up to
  date" for main and recompiles 22 test sources). The known stale-`target/test-classes` trap requires a
  *deleted* test class; this change deletes none, so it does not bite here. Worth a line in the ticket
  so nobody has to re-derive that.
- The saved `3241-reports-DEACTIVATED` directory contains 43 XML files, all belonging to the 26
  targeted classes — no strays from an earlier full-suite run leaked in.

---

## Residual findings the claims did not cover

1. **5 of the 27 disproven markers are still in the tree, unmodified, carrying the false reason.**
   The working-tree diff touches 22 files; `CustomerOrderControllerH2Test`, `ReplenishOrderControllerH2Test`,
   `PickingControllerUnitTest` and `SequenceTransactionServiceUnitTest` (×2) are **not** among them,
   so 23 of the 26 re-suppressed tests remain parked behind text this audit proved wrong — pointing at a
   closed v1 UI ticket. The three *newly* written markers are exemplary by contrast (they name
   SBDEV-3241, state the real failure, and say why it is not environmental). Either finish the sweep or
   state on the ticket that those 5 are deliberately deferred and to what.
2. **Three non-`@Disabled` sites still assert the same false reason** and were not updated:
   `unit/schedulejob/AdminTriggerTenantScopeUnitTest.java:107` (quotes the marker text),
   `smoke/WebContextLaneContextTest.java:32`, and `src/test/resources/application.properties:126`
   ("…makes the \"landlord datasource not configured (SBDEV-2099)\" note on the two @Disabled H2…").
   A future reader greps the *text*, not the annotation.
3. **`OrderReleaseJobUnitTest` was un-disabled but its stale in-file commentary was not corrected.**
   Its diff is a single deleted line, leaving `:175` ("this assertion DOES NOT RUN: the enclosing
   `@Nested` class is `@Disabled`") and `:179` ("The `@Disabled` reason above is also inaccurate")
   asserting things that are now false — the sibling files
   (`CleanUpOldMessagesJobUnitTest`, `ReleaseExpiredPickingOrdersFromUserJobUnitTest`) both got that
   prose rewritten. Same class of defect as retitling a section and leaving the rule below it.

---

## What I could not test

- No live run: I did not execute maven, so every runtime claim above is re-derived from the four saved
  logs plus the 43 saved XML files, not re-measured. If any number is decision-critical, one
  `mvn test -Dtest=<the 26>` re-run is the confirmation.
- No response body for the 403s — mechanism established by elimination from source and configuration,
  not by observation (see CLAIM 6's blind spot for the one-line direct probe).
- No DB probe. Nothing in these seven claims turns on tenant or landlord data; the "landlord
  datasource" in question is an H2 URL in a properties file, which I read directly.
- Flakiness and test-order dependence are invisible to single runs.
