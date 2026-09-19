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

**`mvn -B -ntp clean verify` goes BUILD SUCCESS on `develop`, both lanes green, ~8-9 min.** That is the
durable fact. **The COUNTS are not** — they move with every merge (6629+409 on 2026-09-15 at
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

