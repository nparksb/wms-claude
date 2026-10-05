---
name: wms2-test-suite-baseline-and-h2-verdict
description: "mvn verify goes GREEN end to end; the 'red, aborts before the IT lane' half is history. Derive counts fresh — and CI runs a DIFFERENT command than you do, so its failsafe total is 1 lower. Docker ~9%, H2 migration stays rejected"
metadata: 
  node_type: memory
  type: project
  originSessionId: c7416d10-78c7-4674-bfba-30dc6a406da6
  modified: 2026-09-15T17:07:07.788Z
---

## ⚠ CURRENT READING FIRST

**⚠ CORRECTED 2026-09-21 (SBDEV-3410 P2): "both lanes green on develop" is NO LONGER TRUE, and acting
on it cost a wrong attribution.** Measured on a detached worktree at `origin/develop` `f2ee75f1`,
failsafe lane only: **474 run, 0 failures, 2 errors, 31 skipped, BUILD FAILURE.**

```
MobilePickingServiceIntegrationTest.mobileRapidPickingService_Rapid_Test:776
    » EntityNotFound Itemunit not found with id: 0          <- reproduces on develop
ParcelMonitorViewServiceConcurrencyIT.concurrentFindByIdForUpdate_...:74
    » DataIntegrityViolation duplicate key "index_customerorder_externalnumber"
```

The first reproduces on untouched develop and is **pre-existing**. The second is very likely
**accumulated state in the REUSED `postgres:14-alpine` container** (`withReuse(true)` + the machine
opt-in keeps it alive between builds, so rows from an earlier — or killed — run survive);
`docker rm -f` the running container before trusting a concurrency-IT red.

**Why this matters more than the counts.** A full-lane red on your branch is NOT evidence you broke
something. Establish the baseline by running the same lane on a **detached `origin/develop`
worktree** — not from this file, not from memory. On SBDEV-3410 P2 the branch showed 482/1 against
develop's 474/2: the branch had FEWER errors, and the +8 is exactly the new ITs.

**The rest of this file stands:** `clean verify` does reach the IT lane (the "red, aborts before the
IT lane" era is over), and the COUNTS are not **The COUNTS are not** — they move with every merge (6629+409 on 2026-09-15 at
`9e294d4b`; 6644+418 on 2026-09-16 at `e113467b`, two tickets later). Never quote a number from this
file as "the baseline". Derive it fresh, and compare **failures, not totals**.

### ⚠ CI does NOT run `mvn clean verify` — its failsafe total is 1 LOWER than yours

`.github/workflows/docker-image-develop.yml` runs:

```
mvn -B -ntp clean verify -Dmaven.javadoc.skip=true -Dspringdoc.skip=true \
    -Dfailsafe.excludes='**/SequenceTransactionServiceConcurrencyIT.java'
```

So a local `clean verify` runs **strictly more** than CI does, and a local failsafe total is **exactly
+1** against the same commit's CI total. Measured both directions on SBDEV-3363 (2026-09-16): CI
develop baseline 416 → local-equivalent 417; after +2 new ITs, local 419 and CI 418.

**Take the baseline from the develop push run at your branch's BASE COMMIT, not from a local re-run of
develop** — `gh run list --branch develop --workflow docker-image-develop.yml --json headSha,...` then
`gh run view <id> --log | grep -oE "Tests run: .*"`. It is free, it is the number CI will compare
against, and it removes a whole class of "my branch added 3 tests but I only wrote 2" confusion. Then
reconcile **per class**, not on the total: `Test set:` lines in `target/failsafe-reports/*.txt` versus
the `-- in <class>` lines in the CI log. That per-class diff is what identified the excluded class.

**Both lanes run and both are green — `mvn verify` no longer aborts before the IT lane.** SBDEV-3239 /
3240 / 3241 landed between the two readings. So: **do not quote the 2026-09-06 numbers below as the
baseline, and do not use the `-Dtest=ZzzNone` workaround to "get past" surefire** — there is nothing to
get past. A red suite is now a signal, not the expected state.

⚠ A suite that **matches** the baseline is also not evidence that new code is covered. On SBDEV-3363 the
first commit's surefire was identical to baseline and green while carrying a blocker, and
`grep -rn "<the new field>" src/test` returned zero hits. Matching the baseline means "no regression the
EXISTING tests can see" — nothing more.

Also note the log carries ~19 lines matching `ERROR`/`FAIL` on a **green** run — all of them test output
from deliberately exercised failure paths (`ReturnAdviceAutoReceiveService` PARTIAL FAILURE,
`StartupFlywayMigrator` enumeration, tenant-health rejection bodies). **Grepping the log for `FAIL` is not
a way to read this suite**; read the two `Tests run:` aggregate lines and the BUILD result.

Skipped moved 67→1 (unit) and 65→31 (IT), so most of the `@Disabled` archaeology below is now historical.
Treat everything from here down as the *2026-09-06* state and the reasoning that produced the repairs.

---

### Historical — measured 2026-09-06 at `d4a6ab8a`

| Lane | Time | Result |
|---|---|---|
| surefire (unit) | 2m01s | 6318 tests, **6 failures**, 67 skipped |
| failsafe (integration) | 1m42s | 269 tests, **5 failures + 15 errors**, 65 skipped |

At that time `mvn verify` aborted in surefire so the integration lane never ran.

**The suite is not slow — it is red and a third is switched off.** Testcontainers class ≈1.6–3.2s,
H2 repository class ≈0.02–0.2s, ~10 self-container classes ⇒ Docker is **~20s of 225s (~9%)**.

**DECISION (Nam, 2026-09-06): the four H2-migration plans are superseded, not scheduled.** Filed
**SBDEV-3239** ("make the integration lane runnable") instead. Rejected the PL/pgSQL→Java port: 542
lines, revised 3× in 3 months (V2.2.07/08/12), unblocks **one** disabled test method, and Phase D
would break 4 tests that pin the bodies via `pg_get_functiondef`. Its SQL baseline is gone anyway —
history squashed into `V2.2.00__base_v2_schema.sql` on 2026-07-17 (`cf82ad72`), no `V1.*`/`V2.1.*`
remains. Keep two lanes: H2 for Spring/repo wiring, Testcontainers-PG for SQL fidelity (201
`nativeQuery` across 44 files is what H2 cannot model). See [[wms2-no-pipeline-runs-tests]].

**Trap worth generalising: 14 `@Disabled` classes cite SBDEV-2217, which is Closed and about
`getNextSequenceNumber()` returning `-1`** — nothing to do with Testcontainers. The real cause is
`BasePostgresIntegrationTest` having no `@ActiveProfiles`, so the landlord datasource is unwired.
11 of the 14 were added *after* 2026-06-22, ~1.4/month. **Always open the ticket a marker cites
before believing the marker.** Related: [[verify-script-traps]], [[green-tests-that-prove-nothing]].

Evidence: `sbdocs/1-Projects/wms2/plan/260422-testing-rollup-reground/{P1-h2,P2-report-functions,P3-advisory-lock}.md`

**Follow-ons filed 2026-09-06: SBDEV-3240** (rebuild the 9 Category-A classes on the existing H2 base
— note it is **9**, not 8; `service/KeycloakServiceTest` sits outside `integration/` and earlier plans
missed it) and **SBDEV-3241** (the `SBDEV-2099` pile — **27** markers across 26 classes, 21 top-level + 6 indented;
SBDEV-3239's "27" was right, and a `grep "@Disabled.*SBDEV-2099"` that counted a *comment* as a marker
is what briefly made it 28 — for an annotation census anchor the position:
`grep -E ':[0-9]+:[[:space:]]*@Disabled'`).

**`testcontainers.reuse.enable=true` is worth ~0 on today's tree — SBDEV-3239 AC-6 overstates it.**
`withReuse(true)` sits on two `AppPostgresDBContainer` classes, but their *only* consumers
(`SkuRestControllerIntegrationTest`, `ClientControllerLegacyIntegrationTest`) are both `@Disabled`
Category-A, and the 10 raw-Testcontainers classes that do run never call `withReuse`. So the flag is a
no-op twice over in v2. Its one real effect is in **v1**, where it collapses the documented
container leak — see [[v1-testcontainers-withreuse-leaks-a-container-per-run]]. Deferred hazard: v1
and v2 build the same container shape (`postgres:12` / `wms_test` / `test`:`test`) but migrate
*different* Flyway locations (`db/migration` vs `db/v1-to-v2-onboarding/schema`), so once 3239
re-enables the v2 consumers, a shared reused container could cross-contaminate their schema history.

**A `@Disabled` reason string is evidence of nothing.** `AdminTriggerTenantScopeUnitTest:99-104` records
that `CleanUpOldMessagesJobUnitTest`'s "landlord datasource (SBDEV-2099 env skip)" marker is false —
it fails with `NPE: "this.advisoryLockService" is null`, a class that never wires its mocks. Same
failure mode as the 14 markers citing closed SBDEV-2217. **Open the ticket a marker cites, then enable
the test and read the actual failure.** Related: [[green-tests-that-prove-nothing]].

**3239 / 3240 / 3241 are three-way disjoint and all three can run in parallel** (verified 2026-09-06 by
set intersection on `@Disabled` markers, plus consumer analysis). Two traps behind that:

- **There are TWO `AppPostgresDB{Container,SetupExtension}` pairs** with disjoint consumers:
  `net.aim_ai.wms.*` (root) is used *only* by the 9 Category-A classes; `net.aim_ai.wms.common.extension.*`
  *only* by `BasePostgresIntegrationTest`. Both carry the swapped `withUsername`/`withPassword`. Saying
  "the shared container" is wrong and produces a phantom dependency.
- **The `SBDEV-2099` unit markers are NOT the landlord root cause.** Those classes extend
  `BaseRepositoryIntegrationTest` (H2, `@ActiveProfiles("integration")`) or `BaseServiceUnitTest` (plain
  Mockito, no Spring context) — never `BasePostgresIntegrationTest`. And
  `src/test/resources/application-integration.properties:9-17` already wires `landlord.datasource.*` on H2.
  Proven at runtime: `LocationRepositoryTest` **passes** (1 run / 0 fail / 24.84s) with the marker off,
  while `CleanUpOldMessagesJobUnitTest` NPEs on `"this.advisoryLockService" is null` — a broken test class.

**Recipe — run a `@Disabled` test without editing source.** Write
`junit.jupiter.conditions.deactivate=org.junit.*` into `target/test-classes/junit-platform.properties`
(a build artifact, not source), run, then **delete it** — left behind it silently un-skips everything.
Two ways this instrument fails looking like a result: the FQN
`org.junit.jupiter.api.extension.DisabledCondition` is **wrong** (the condition is in
`...jupiter.engine.extension`) and leaves every test "Skipped"; and `mvn surefire:test` standalone dies
with "Error occurred in starting fork" because the pom's `@{argLine}` is jacoco late-binding
(`pom.xml:526-528`) — use the full `test` phase. Also: `mvn` is **not on PATH** in non-interactive shells
here; use `/home/nampark/.sdkman/candidates/maven/current/bin/mvn` with
`JAVA_HOME=/home/nampark/.sdkman/candidates/java/21.0.11-ms`. Related: [[a-zero-scan-needs-a-positive-control]],
[[verify-script-traps]].

**SBDEV-3241 measured outcome (2026-09-06, worktree at `d4a6ab8a`).** Two runs of the same 26 classes,
differing only by the deactivation file: markers active → `95 run, 0 failures, 61 skipped`; markers off →
`95 run, 14 failures, 12 errors, 0 skipped`. So **the 27 markers suppress 61 tests, 35 of which pass the
instant the marker goes, and 26 are genuinely broken** — with *zero* pre-existing failures in those
classes, so attribution needed no baseline subtraction. The 26 split five ways:
`SequenceTransactionServiceUnitTest` 16 (Mockito `UnnecessaryStubbing` + assertion failures — and this is
the ONE group where closed **SBDEV-2217** genuinely applies, since it is about `getNextSequenceNumber()`);
4 × `403` in `CustomerOrderControllerH2Test`/`ReplenishOrderControllerH2Test` (**same fixture gap as
SBDEV-3239 AC-4** — one reusable function-granting fixture should close all 8); 3 ×
`EntityNotFoundException` in `PickingControllerUnitTest$ProcessPick`; 2 × `NPE: jobMetrics is null` in the
two schedule-job tests (they declare `@Mock` for 4 of the production constructor's 6 deps); 1 real
assertion failure in `CustomerorderBatchRepositoryTest`.

**`SBDEV-2099` is a closed WMS *v1* *UI* bug** — "Outbound Parcel Report Clears Results After Palletizing".
Not a datasource, not Java, not v2. So this is the SBDEV-2217 pattern twice over: two marker piles in two
lanes each citing a closed, unrelated ticket. ⚠ But `ViewDtoServiceUnitTest` and `ReportControllerUnitTest`
cite SBDEV-2099 in `@DisplayName` strings **legitimately** — those are the v2 port of that very fix. Do not
sweep by ticket number; sweep by the marker.

**SBDEV-3241 closed out 2026-09-07 except the 4×403.** The 16
`SequenceTransactionServiceUnitTest` tests were REPAIRED, not superseded: SBDEV-2217's fix moved the
service from `findByClassname` to **`findByClassnameForUpdate`** (pessimistic lock) and the tests still
stubbed the old finder — 7 `UnnecessaryStubbingException` + 9 wrong-value failures. Retarget the stubs
and all 16 pass.

⚠ **SBDEV-2217 spans TWO classes that both declare `getNextSequenceNumber`, and I keyed a supersession
judgement on the method name.** The `-1`-on-exhaustion half is **`BasicService`** (`:163-170`, now
throwing `BusinessException.SequenceExhausted`, pinned by `BasicServiceUnitTest`); only the lock half
touched `SequenceTransactionService`, which never returned `-1` at all. Same trap CLAUDE.md documents
for controller handlers (`orderList` is declared by four classes) — **key on (declaring class, method),
never the method name**, including when reading a ticket.

⚠ **A 100% PIT score can be narrow rather than strong.** 7/7 killed on this 17-line service, yet PIT
generated **no mutant for either repository call** — `VOID_METHOD_CALLS` only removes *void* calls and
both return values — so it would NOT catch a revert to the unlocked finder. It also cannot touch the
`@Lock` (different type, outside `targetClasses`, annotation on an interface method) or the
`REQUIRES_NEW` boundary (annotation; and `@InjectMocks` builds the bean directly, so no proxy exists —
flipping the propagation leaves every test green). Ask what the mutant SET was before quoting a
percentage. Related: [[transactional-tests-blind-to-propagation-and-readonly]].


## ADDENDUM 2026-09-22 (SBDEV-3410 P4): a FRESH container made the failsafe lane fully green — BOTH errors, not just one

Measured on `feature/SBDEV-3410-p4-...` @ `d011ccf8`, whose only production delta versus
`origin/develop` is **five lines** in `StockrecordService.getStockRecordDetails` — a method that
touches neither `customerorder` nor `itemunit`. Same worktree, same command (`mvn clean verify`), twice:

| run | container | surefire | failsafe |
|---|---|---|---|
| `9033f28b` | REUSED (3 h old, carried P2/P3 runs) | 6754 / 0 / 0 | 481 / 0 / **1 err** |
| `d011ccf8` | FRESH (`docker rm -f` first) | 6755 / 0 / 0 | **481 / 0 / 0, BUILD SUCCESS** |

The single error on the reused container was `ParcelMonitorViewServiceConcurrencyIT` —
`duplicate key ... Detail: Key (externalnumber)=(PARCELMON-ORD-1) already exists`, i.e. its own
fixture row surviving from an earlier build. Exactly what this file already predicted. Fine.

**What is NEW, and corrects the paragraph above:** `MobilePickingServiceIntegrationTest` is described
there as *"reproduces on untouched develop and is pre-existing"* — and it **passed on BOTH of these
runs** (3/3, 0.444 s). So the "2 pre-existing errors" baseline is not two different things, one real
and one flaky; **both are container-state-dependent**, and the `Itemunit not found with id: 0`
signature is as state-shaped as the duplicate-key one.

⚠ **Stated as the limit of the measurement:** I did not re-run `origin/develop` itself on a fresh
container, so "develop's failsafe is green on a fresh container" is an **inference** from a 5-line
unrelated delta, not a measurement. Do not quote it as one. What IS measured: a branch off develop,
with a fresh container, reaches **0 failures / 0 errors in both lanes**.

**How to apply — this changes what a red baseline means.** The standing advice ("establish the
baseline on a detached `origin/develop` worktree") is necessary but **not sufficient**: if that
baseline run reuses the same dirty container, it reproduces the same two errors and you conclude
develop is red when it is not. `docker rm -f` the reused container **before the baseline run as well
as before the branch run**, or the comparison is between two equally-contaminated numbers. A baseline
of "2 errors" that you then match is not evidence of no regression — it is two runs sharing one cause.

Related: [[outbox-concurrent-enqueue-it-is-timing-flaky]], [[wms2-concurrency-it-fixture-traps]],
[[concurrent-maven-one-worktree-false-reds]].

---

## ⚠ CORRECTION 2026-09-23 — the 2026-09-22 addendum above is WRONG, and I measured it wrong twice

The addendum says both develop failsafe errors are **container-state-dependent**, that a fresh
container reaches **0 failures / 0 errors in both lanes**, and that "develop's failsafe is green on a
fresh container" is only an inference. The first two claims are now **disproved by direct
measurement**; the third was right to hedge and the hedge is what saved it.

**Measured 2026-09-23, SBDEV-3410 P5.** Untouched `origin/develop` @ `b87ec747`, its own detached
worktree, **zero diff**, on a container cleared with `docker rm -f` immediately before, idle machine:

| tree | surefire | failsafe | build |
|---|---|---|---|
| P5 branch `fa8ae56c` (develop + 3 files) | 6787 / 0 / 0 | **492 / 0 / 0** | SUCCESS |
| **untouched develop `b87ec747`** | 6787 / 0 / 0 | **492 / 0 / 1** | **FAILURE** |

The one error is `ParcelMonitorViewServiceConcurrencyIT`
`.concurrentFindByIdForUpdate_secondThreadSeesCommittedState_noRedundantWrite`, and it is the SAME
message the reused-container run produced:

```
duplicate key value violates unique constraint "index_customerorder_externalnumber"
Detail: Key (externalnumber)=(PARCELMON-ORD-1) already exists.
```

**A FRESH container is not sufficient to make it pass.** On P4 I cleared the container, re-ran, got
0 errors, and recorded that as *proof* the cause was accumulated state. It was not proof — it was one
sample of a nondeterministic test, and the sample agreed with the hypothesis I already held. Two runs
of the same nondeterministic test are not a control; the second run must be of the OTHER condition.

**So the real classification is: `ParcelMonitorViewServiceConcurrencyIT` is FLAKY, not
state-dependent.** Consistent with the fixture mechanism already recorded in
[[wms2-repository-tests-commit-they-do-not-roll-back]] — these tests COMMIT rather than roll back, so
a fixture row with a hardcoded natural key (`PARCELMON-ORD-1`) survives its own test and collides
with any re-execution or racing sibling inside the same JVM run. Nothing about a clean container
prevents that; the collision is produced *within* a run. Compare
[[outbox-concurrent-enqueue-it-is-timing-flaky]] — same class of defect, different test.

### What this means for using a baseline at all

**wms2's failsafe lane has no single correct number.** Two runs of the *same* tree can be 492/0/0 and
492/0/1. Therefore:

- **Never conclude "my branch is clean" from matching a remembered baseline.** Run the baseline
  yourself, in its own worktree, adjacent in time to the branch run. It is ~20 min and it is the only
  thing that distinguishes a regression from this test.
- **A branch run that is GREENER than the baseline is the normal case, not a triumph.** P5 came out
  green while untouched develop came out red. Reading that as "P5 fixed something" would be wrong;
  reading it as "P5 regressed nothing" is all it supports.
- Failsafe totals moved 481 → **492** between 2026-09-21 and 2026-09-22 (SBDEV-3410 P2 and P3 merged
  their ITs). Totals move constantly — compare failures, never totals.

### A separate, genuinely transient failure seen once (do not confuse the two)

The FIRST P5 suite run, started the same second a `clean verify` in another worktree finished, gave
**3 errors in 2 classes** (`MoveCronConcurrencyIT`, `FixLocationAssignmentServiceIT`), all
`FATAL: sorry, too many clients already` (SQLSTATE 53300) at context startup. It did **not** reproduce
on a re-run. Standing arithmetic worth knowing, though it was not the proximate cause: nothing sets
`max_connections` (so it is postgres:14-alpine's default **100**), each Spring context holds a
landlord pool of 4 plus a tenant pool of 5, and Spring's TestContext cache holds **32** contexts, so
~12 simultaneous contexts exhaust the server. One line would buy headroom:
`.withCommand("postgres","-c","max_connections=200")` on `AppPostgresDBContainer`.

⚠ **And this corrects [[concurrent-maven-one-worktree-false-reds]]**, which says separate worktrees
are safe for concurrent maven. That holds for surefire. It does **not** hold for the integration
lane: `AppPostgresDBContainer` sets `withReuse(true)`, so with reuse enabled every worktree's failsafe
run shares ONE postgres and its single 100-connection budget. Run integration lanes one at a time.


**2026-10-02 develop `09f861da` full `clean verify` (SBDEV-3633 baseline):** units 7688 / 0 fail; ITs 588 with 5 F + 2 E in
`CancellationReversalParcelSourceIntegrationTest` (H2 "los_sequencenumber not found (this database is empty)" inside a PG IT —
context contamination), `SequenceTransactionServiceConcurrencyIT` (CannotCreateTransactionException — pool exhaustion) and
`OrderReleaseSectionQueryIT` $DashboardBucket/$ReleaseQuery. All pass ALONE. So a red in exactly these in a full run is the
known full-run-only set, not your change — but rerun them alone to prove it, as here.
