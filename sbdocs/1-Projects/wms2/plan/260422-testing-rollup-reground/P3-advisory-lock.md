---
title: "P3 re-grounding — 260421-v2-replace-pg-advisory-lock vs origin/develop"
type: reground
version: v2
project: [wms2-api]
plan_under_review: "./../260421-v2-replace-pg-advisory-lock.md"
code_base: "origin/develop @ d4a6ab8a7da61e6b6918d3662bb7dc6ab8357733 (2026-09-04)"
prior_reground: 2026-06-22
reground_date: 2026-09-06
verdict: "REWRITE REQUIRED (SBDEV-3198 reshaped the surface); RECOMMEND DEFER — no consumer exists"
---

# P3 re-grounding — advisory lock plan vs `origin/develop`

All claims derived from `origin/develop @ d4a6ab8a` (`git fetch origin` 2026-09-06). No working-tree
reads. Line numbers are `git show origin/develop:<path>` line numbers.

---

## 1. Does `AdvisoryLockService` still exist? Yes — same name, same package, same mechanism, **grown**

`src/main/java/net/aim_ai/wms/service/AdvisoryLockService.java` — 260 lines (was 129 at the
2026-06-22 re-grounding). Still `@Service` (`:45`), still raw JDBC over
`@Qualifier("landlordDataSource") DataSource` (`:65`), still `pg_try_advisory_lock` / `pg_advisory_unlock`
with ThreadLocal connection pinning. No interface, no rename.

**What changed:** it now has **four** public methods, not two, and **two** ThreadLocal slots, not one.

| Member | Line | Note |
|---|---|---|
| `ThreadLocal<Connection> lockedConnection` | `:57` | ONE-KEY form's pinned-connection slot |
| `ThreadLocal<Connection> lockedTenantConnection` | `:63` | TWO-KEY form's slot — **separate**, added by SBDEV-3198 |
| `boolean tryLock(long lockId)` | `:76` | `SELECT pg_try_advisory_lock(?)` (`:79`) |
| `void unlock(long lockId)` | `:115` | `SELECT pg_advisory_unlock(?)` (`:122`) |
| `boolean tryLock(long jobLockId, long tenantDbConfigurationId)` | `:179` | **NEW** — `SELECT pg_try_advisory_lock(?, ?)` (`:184`), both bound `setInt`, `Math.toIntExact` narrowing that throws loudly (`:180-181`) |
| `void unlock(long jobLockId, long tenantDbConfigurationId)` | `:215` | **NEW** — `SELECT pg_advisory_unlock(?, ?)` (`:225`) |

An `F-7` review fix also added `lockedConnection.remove()` on the SQLException path (`:99`, and `:201`
for the two-key slot) — the plan's §2.1 quoted body is now wrong in that detail too.

**Critical new invariant the plan does not know about** (class javadoc `:35-43`, and `tryLock(long,long)`
javadoc `:148-153`): *the one-key and two-key lock spaces are DISJOINT.* `pg_try_advisory_lock(bigint)`
and `pg_try_advisory_lock(int4,int4)` never contend. The two forms MAY be held simultaneously by one
thread (that is required by the dual-lock rolling-deploy transition, §3 below); two locks of the SAME
form must never nest.

## 2. `JobLockId` — unchanged; contract test — still present; a **second** test now exists

- `JobLockId` is still a `public static final class` of `public static final long` constants inside
  `AdvisoryLockService` (`:248-259`). All 8 constants unchanged, `100001L`–`100008L`, `// SBDEV-2221`
  comment still on `OUTBOX_DISPATCHER` (`:256`). **It was never an enum**; the plan's §2.4 row 11
  wording ("`JobLockId` still an enum") does not describe this code and never did — the contract test
  at `AdvisoryLockServiceJobLockIdContractTest:41` explicitly asserts `long.class`, "not an enum value".
- `src/test/java/net/aim_ai/wms/unit/service/AdvisoryLockServiceJobLockIdContractTest.java` — **present**,
  unchanged, reflects `AdvisoryLockService.JobLockId.class.getField("CLEANUP_REST_IDEMPOTENCY")` at `:29`.
- **NEW and plan-breaking:** `src/test/java/net/aim_ai/wms/unit/service/AdvisoryLockServicePerTenantLockUnitTest.java`
  (SBDEV-3198). 13 tests over the two-key form, plus an **AC5a source-level pin** (`:277-300`) that
  `Files.readString`s `src/main/java/net/aim_ai/wms/schedulejob/{OutboxDispatcherJob,RestIdempotencyCleanupJob}.java`
  and asserts each `containsPattern("tryLock\\(\\s*AdvisoryLockService\\.JobLockId\\.[A-Z_]+\\s*\\)")`.
  **A rename to `JobLockService.JobLockId` reds this pin by regex, not by compile error** — and the pin's
  stated purpose (`:281-284`) is *"'tidy up the remaining one-key call sites' is the refactor this test
  exists to stop."* P3's rename is exactly that refactor's shape.

## 3. Call sites: the plan says 8 jobs / 16 sites. It is **8 jobs / 30 sites**, in three different shapes

`git grep -nE 'advisoryLockService\.(tryLock|unlock)\(' origin/develop -- src/main/java` → 32 hits;
2 are javadoc inside `AdvisoryLockService.java` itself, so **30 real call sites**. Split by form:
22 two-key, 8 one-key.

| # | Job | Lock id | Sites | Form today | Lines |
|---|---|---|---|---|---|
| 1 | `OrderReleaseJob` | 100001 | 4 | **two-key only** (converted, PR #301) | 221/242, 314/332 |
| 2 | `ReplenishOrderJob` | 100002 | 4 | **two-key only** (converted, PR #304) | 283/304, 385/403 |
| 3 | `CleanUpOldMessagesJob` | 100003 | 6 | **DUAL** — one-key wrapper + two-key inner | one-key 207/250; two-key 220/247, 343/370 |
| 4 | `StockSummaryExportJob` | 100004 | 6 | **DUAL** | one-key 266/310; two-key 280/307, 395/407 |
| 5 | `ReleaseExpiredPickingOrdersFromUserJob` | 100005 | 4 | **two-key only** (PR #293) | 195/220, 297/323 |
| 6 | `StaleClubBatchCleanupJob` | 100006 | 2 | **two-key only** (PR #286/#287) | 190/208 |
| 7 | `RestIdempotencyCleanupJob` | 100007 | 2 | **one-key, permanently** (AC5a) | 50/78 |
| 8 | `OutboxDispatcherJob` | 100008 | 2 | **one-key, permanently** (AC5a) | 59/110 |

The **dual-lock** shape (rows 3–4) is a deliberate, *temporary* rolling-deploy mitigation:
`CleanUpOldMessagesJob:207-251` takes the one-key `100003` around each tenant's two-key `(100003, tenantId)`,
with the comment at `:48` — *"the one-key acquisition is deleted in the following release once every
replica is converted."* Same at `StockSummaryExportJob:58`. **So rows 3–4 are scheduled to lose 2 call
sites each in an as-yet-unwritten follow-up.** Any P3 rewrite lands on a moving target.

Test-side blast radius (was "the contract test + job unit tests"): **28 test files, 203 `AdvisoryLockService`
references** (`git grep -c 'AdvisoryLockService' origin/develop -- src/test`), the largest being
`AdminTriggerTenantScopeUnitTest` (11), `OrderReleaseJobUnitTest` (16), `ReleaseExpiredPickingOrdersFromUserJobTest` (16),
`CleanUpOldMessagesJobUnitTest` (15), `OutboxDispatcherJobUnitTest` (14), `ReplenishOrderJobUnitTest` (14),
`AdvisoryLockServicePerTenantLockUnitTest` (12).

## 4. Scheduling topology today — the plan's §2.3 framing survives, the job list under it does not

- `@EnableScheduling` is **still unconditional**: `src/main/java/net/aim_ai/wms/config/SchedulingEnablementConfig.java:15-17`,
  javadoc `:7` — *"Enables the Spring scheduling infrastructure on ALL replicas (unconditionally)."* Unchanged.
- `SchedulingConfiguration` is **still** `@ConditionalOnProperty(name="app.cron", havingValue="true", matchIfMissing=false)`
  — `SchedulingConfiguration.java:30`. It has grown from ~24 lines of registration to **1725 lines** and now
  also carries `@Order(1)` (`:31`), a `TaskScheduler` bean with `POOL_SIZE = 10` (`:35`, `:232`), a boot probe
  with a 60-attempt retry budget (`:44-49`), and a **new `@Scheduled` reconcile** at `:1610-1611`.
- Method-level `@Scheduled` in `src/main/java` — **five** sites, not two:
  `OutboxDispatcherJob:57`, `RestIdempotencyCleanupJob:48`, `SchedulingConfiguration.reconcileSchedules():1610`
  (second 50, AC15), `TenantConfigLoader:61`, `TenantPoolEvictor:30`.
- So the plan's *"2 of 8 fire on all replicas"* is **still correct for the 8 lock-holding jobs**
  (`OutboxDispatcherJob`, `RestIdempotencyCleanupJob` — confirmed by `SchedulingConfiguration:63-66`, which
  names exactly those two as `@Scheduled`-activated and outside the probe's reach), but the surrounding
  claim that only 2 `@Scheduled` methods exist in the app is wrong — there are 5.
- `CONFIGURED_JOB_NAMES` (`SchedulingConfiguration:69-88`) still lists the same 6 `app.cron` jobs.

## 5. What SBDEV-3198 changed, and its true state (the plan doc is stale)

`git log origin/develop --oneline --grep=3198` → 31 commits. **All six `app.cron` jobs are converted and
merged.** Sequencing:

| Step | Job | Feature commit | Merge |
|---|---|---|---|
| 3 | `StaleClubBatchCleanupJob` | `7b7db3b6` | + follow-up `3941fb26` |
| 4 | `StockSummaryExportJob` | `680f1f15` | `f440b534` (PR #288) |
| 5 p1 | `CleanUpOldMessagesJob` | `55ec08e1` | `c360b380` (PR #291) + gate follow-up `bb264b87` (PR #296) |
| 5 p2 | `ReleaseExpiredPickingOrdersFromUserJob` | `64fb9223` | `8c178ed1` (PR #293) |
| 5 p3 | `OrderReleaseJob` | `29a64776` | `6fdb6d25` (PR #301), 2026-09-03 21:18 |
| 5 p4 | `ReplenishOrderJob` | `45586cfc` | `24082277` (PR #304), 2026-09-03 23:19 |

⚠ **The SBDEV-3198 plan document is out of date.** Its frontmatter (`updated: 2026-09-03`) says
`ReplenishOrderJob` is *"analysis done, implementation blocked on Nam's A-vs-B registration-shape call — the
LAST remaining job"* and its §7a step 5 part 4 (line 2048) says *"ANALYSIS DONE, implementation NOT started."*
`45586cfc` landed on develop at 2026-09-03 23:16 and `git branch -r --contains 45586cfc` lists `origin/develop`.
Per `plan-state-probe-beats-reading-plan-status`, trust the git evidence: **6/6 done.**

**Does the new model change the lock's semantics? Yes — the unit of mutual exclusion moved.**
`AdvisoryLockService.java:143-146`: the two-key lock is *"the unit of work under SBDEV-3198's D′ shape (§4a):
'one replica processes tenant X's job' rather than 'one replica runs the job'."* The key is
`tenant_db_configuration.id` — the landlord PK, chosen deliberately over a member-set hash or an ordinal
(`:155-163`, "the three things rev 1 got wrong", item 1). Concretely, for 6 of 8 jobs the lock is now
**per (job, tenant)**, taken and released inside a per-tenant loop (`ReplenishOrderJob:283-304`,
`StaleClubBatchCleanupJob:190-208`, etc.), so one slow tenant no longer makes every other tenant skip.

**Residual SBDEV-3198 work that touches this surface:**
1. Delete the one-key wrapper from `CleanUpOldMessagesJob` and `StockSummaryExportJob` once every replica
   is converted (`CleanUpOldMessagesJob:48`, `StockSummaryExportJob:58`) — **not done on develop**.
2. `OutboxDispatcherJob` / `RestIdempotencyCleanupJob` keep the one-key form **permanently** —
   SBDEV-3198 plan §3.2 and **AC5a** (plan line 1177), enforced by the source-regex pin in §2 above.

## 6. Do the plan's proposed artifacts exist? No — zero, verified with a positive control

```
JobLockService                 -> 0 files
PostgresAdvisoryJobLockService -> 0 files
InMemoryJobLockService         -> 0 files
job-lock.engine                -> 0 files
jobLockEngineCheck             -> 0 files
AdvisoryLockService            -> 42 files   <-- positive control, same command shape
```
(`for p in …; do git grep -c "$p" origin/develop | wc -l; done`.) None of the interface, the rename, the
in-memory impl, the engine property, or the allowlist guard exists in any form.

## 7. Is the lock still load-bearing? **Yes for the two one-key jobs; no longer for the six**

- **Six gated jobs (100001–100006):** *not* load-bearing across replicas. SBDEV-3198 §3.3 records Nam's
  2026-09-02 answer — **exactly one container carries `app.cron=true`**, and deploys are recreate
  (stop-then-start), so no second holder of `100001`–`100006` exists at any time. The two-key lock's value
  is now *intra*-job (per-tenant isolation, AC4), not anti-duplication.
- **Two ungated jobs (100007/100008):** **load-bearing, confirmed.** They are `@Service` + `@Scheduled` under
  the unconditional `@EnableScheduling`, so they run in **every** container built from the image.
  SBDEV-3198 §6 settles the topology from a human answer plus the workflow files: **two services per
  environment** (`wms-api` + a separate `cron`, each with its own Portainer webhook, both from the same
  image), **1 api replica today, scaling to 2, max 3** → **≥2 JVMs today, up to 4**. `OutboxDispatcherJob`
  fires every 15 s (`:57`). So P3's Open Question Q1 is **ANSWERED: yes, multi-replica, the lock is real.**
  (§3.2 also corrects *why* it matters: `findAndClaimPending` uses `FOR UPDATE SKIP LOCKED`, so losing the
  lock costs a doubled OMS request rate and a ~5-min `STALE_INFLIGHT_TIMEOUT` re-send window — not
  duplicate dispatch.)

## 8. Is anything actually blocked by the lock today? **No.**

The plan's stated goal is H2 test portability. Measured on develop:
- The H2 `integration` profile is alive — `src/test/resources/application-integration.properties`
  (H2 `MODE=PostgreSQL`, `spring.flyway.enabled=false`), **9** files carrying `@ActiveProfiles("integration")`.
- **None of them reaches a scheduled job or the advisory lock.** The only integration-profile file that even
  mentions a job-ish symbol is `MobileReplenishMultiUnitLoadIT`, and it contains no `AdvisoryLock` reference.
- Every one of the 28 job/lock test files is a plain Mockito unit test with a **mocked** `AdvisoryLockService`
  (e.g. `OutboxDispatcherJobUnitTest:63` constructs the job with a mock `lockService`). H2 never sees
  `pg_try_advisory_lock`.
- P3's only hard consumer, **P1 §5 (scenario tests that drive scheduled jobs)**, was explicitly **split to a
  follow-on plan** by rollup decision **D5** (`260422-v2-testing-migration-rollup.md:206-208`) and is marked
  *"◯ pending — optional"* (`:172`).

So P3 unblocks nothing that exists, and its one dependent was deferred by decision.

---

## 9. VERDICT

**Not worth doing as written. The plan needs a rewrite, and the rewrite should then be deferred.**

**Why it cannot be executed as written** — six load-bearing facts have moved since 2026-06-22:

1. The interface is no longer 2 methods; it is **4** (two disjoint lock spaces) plus `JobLockId`.
   The in-memory impl must model the disjointness (`{100006}` must NOT exclude `{(100006,7)}`) or it will
   pass tests that production would fail. The plan's `ConcurrentMap<Long,Boolean>` sketch (§3.1.3) cannot
   express that and is silently wrong.
2. **16 call sites → 30**, in three shapes (one-key-only, two-key-only, dual), across the same 8 files.
3. Test blast radius **28 files / 203 refs**, up from "the contract test plus a few job unit tests".
4. The rename **defeats the AC5a source-regex pin** (`AdvisoryLockServicePerTenantLockUnitTest:290`) —
   a red that looks like a bug in the pin, not in the rename — and the pin exists specifically to stop
   refactors of this shape. Renaming requires re-negotiating AC5a, not just editing a regex.
5. Two of the eight jobs are **mid-transition** (dual-lock) with a scheduled deletion of 4 call sites
   still owed. Renaming underneath that is gratuitous merge pain for the SBDEV-3198 owner.
6. Plan §2.1's quoted body, §2.4's whole line-anchor table, §3.1.1's 2-method interface, §3.1.3's
   in-memory sketch, §3.3's "8 files × 2 sites = 16", §5's checklist and §6's test table are all
   now inaccurate. That is most of the document.

**What survives:** the motivation is intact (H2 has no `pg_try_advisory_lock` in either arity), the
interface-extraction idea is still the right shape, and Open Question Q1 is now **answered yes**.

**Recommendation — DEFER, and rewrite only when P1 §5 is actually scheduled.** Doing it now buys nothing
measurable: no test on develop is blocked, the one consumer is deferred by decision D5, and the surface is
mid-refactor. Revisit when (a) SBDEV-3198's one-key-wrapper deletion has landed, and (b) P1 §5 is committed.

**If it is done anyway, two sizings:**

| Shape | Scope | Tier | Estimate |
|---|---|---|---|
| **Minimal (recommended if forced)** | Extract a 4-method `JobLockService` interface; `AdvisoryLockService` **keeps its name** and just `implements` it; `JobLockId` **stays where it is**. Job fields/ctor params retype to the interface. No rename, no `@ConditionalOnProperty`, no in-memory impl, no allowlist guard until a consumer exists. AC5a pin and the contract test both keep compiling and keep passing untouched. | **T2** | **~1 eng-day** (30 prod sites are type-only; 28 test files mostly need only the `@Mock` type widened) |
| **Full plan as written** (rename + in-memory + guard) | Everything above, plus `PostgresAdvisoryJobLockService` rename, two-lock-space in-memory impl with `reset()`, engine property, allowlist `ApplicationRunner`, retargeted contract test, re-negotiated AC5a pin, 203 test refs | **T3** — distributed-lock correctness, 8 files mid-transition, a substituted impl for a lock that is genuinely multi-JVM today | **3–4 eng-days**, and it should not start before SBDEV-3198's residual one-key deletion lands |

Rollup rows to correct: `260422-v2-testing-migration-rollup.md` lines **42, 79, 118, 151, 152, 167**
(all say "8 jobs / 16 sites"; and line 152 / D2 line 193 treat Q1 as open — it is answered).
