# SBDEV-3321 F5 — code review

- **Worktree:** `/home/nampark/dev/wms-claude/.claude/worktrees/wms2-api/SBDEV-3321`
- **Branch:** `bugfix/SBDEV-3321-pending-reversal-reconciliation`, base `origin/develop @ e113467b`
- **Reviewed by reading only** — no `mvn` was run in that worktree (a full `clean verify` was in flight).
- **Date:** 2026-09-16
- **Reviewed surface:** `git diff origin/develop` (4 modified files) **plus the 3 untracked files**
  (`PendingReversalReconciliationJob.java`, `PendingReversalReconciliationJobUnitTest.java`,
  `PendingReversalOlderThanIntegrationTest.java`) — the diff alone shows only 45 added lines and
  hides the entire job class and both test classes.

Verdict: **the design is sound and the three riskiest hypotheses in the brief do not hold.** The
defects below are real but none of them break the job at runtime. One (H-1) removes coverage from a
guard that was written specifically to stop this class of change from going unnoticed.

---

## Part 1 — the five hypotheses in the brief, answered

### 1. Connection and pool behaviour — **not a problem. Dispute.**

`AdvisoryLockService.tryLock(long)` pins exactly **one** landlord connection in the one-key
`ThreadLocal` slot for the whole run (`AdvisoryLockService.java`, `lockedConnection.set(conn)`).
`tenantDbConfigurationRepository.findByActiveTrue()` takes a second, transiently. Per-tenant reads go
to the tenant datasource, not the landlord pool. So the job's landlord ceiling is 2.

`application.properties:76` — `landlord.datasource.maximum-pool-size=10`. The
`OUTBOX_DISPATCHER_CLUB` javadoc's "raised from 2 accordingly" note is describing a pool that is now
five times larger than the figure it reasons about.

02:00 vs 02:30: no collision. Different advisory-lock ids, different tables, and
`spring.task.scheduling.pool.size=14` means the 02:30 trigger gets its own scheduler thread even if
the 02:00 sweep is still running. Even with both in flight, landlord usage is 4 of 10.

**Low finding (L-5)** rides on this — see below: the *stated reason* for 02:30 is wrong even though
the choice is fine.

### 2. Transaction posture — **correct as written. Dispute.**

- The read is safe without `@Transactional`. `SimpleJpaRepository` carries a class-level
  `@Transactional(readOnly = true)`, so `findPendingReversalsOlderThan` runs inside its own
  short tenant transaction and returns detached entities.
- OSIV being disabled does not bite, because **`CustomerorderCancellationLog` has no associations at
  all** — every one of its 22 fields is a basic column (`Long`, `String`, `Integer`,
  `OffsetDateTime`, `BigDecimal`); `pickingorderId`, `picktounitloadId` etc. are raw FK longs, not
  `@ManyToOne`. `describe()` touches `getCreatedAt`, `getCustomerorderId`, `getToteLabelId`,
  `getId` — all eagerly materialised. No `LazyInitializationException` is reachable.
- `createServiceLog` supplies its own transaction:
  `MessageService.java:75` — `@Transactional(value = "tenantTransactionManager", propagation = Propagation.REQUIRES_NEW)`.
  The job injects `MessageService` and calls it through the container proxy (not a self-invocation),
  so the annotation is honoured and `basicService.generateMessageNumber` gets its sequence read and
  the `messageRepository.save` in one committed tenant transaction. This is *better* than the
  `SkuRestController` callers, which reach it via `createMessage` — a same-bean self-invocation that
  bypasses the proxy (noted in that controller's own comment at `:165`).

### 3. `createServiceLog` under a job — **disproved. This is the strongest dispute in the review.**

The brief calls this "the most likely runtime break and it would only appear in production." It is
neither a break nor production-only-unknown.

- `SecurityContextUtils.getUserName()` cannot NPE. `SecurityContextHolder.getContext()` never returns
  null (it creates an empty context), `authentication` is then null, and the method falls straight to
  `String username = ANONYMOUS;` → `"anonymous"`.
- `WmsConstants.USER_ANONYMOUS` is the **same literal** `"anonymous"`
  (`WmsConstants.java:863`), so `createServiceLog`'s two lookups are the same query. Either both hit
  or both miss.
- The real hazard was one layer down and it is also clear: `message.client_id` and
  `message.operator_id` are **`NOT NULL`** (`V2.2.00__base_v2_schema.sql`, confirmed live on Hydra
  PRD via `information_schema.columns`), and `createServiceLog` writes `null` into both when the user
  lookup misses. So a tenant DB without an `anonymous` row would fail the insert.

  It does not miss. The row is seeded by the base dump
  (`V2.2.00__base_v2_schema.sql`: `INSERT INTO public.mywms_user VALUES (1, …, 'anonymous', …, 0, NULL)`),
  and I queried it on **6 of 6 reachable tenant DBs** — `wms2-hydra` (prd), `nywh-hydra-uat`,
  `c1wh-shipitez-uat`, `nywh-shipitez-uat`, `wsl-wineco-uat`, `wms2-wineco-dev` — all return
  `id=1, name='anonymous', client_id=0`.

- **Live proof the path already runs:** on Hydra PRD, `message` holds **1,935 rows with
  `client_id=0, operator_id=1`** (i.e. written as `anonymous`), most recent `2026-09-16 07:01 UTC`.
  `StockSummaryExportJob:570/:598` and `OutboxDispatchService:279` already call `createMessage` from
  scheduled-job context with no security context. This is a worn path, not a new one.

  Derivation of "6 of 6": the six MCP-registered tenant databases in this session. Tenant DBs not
  registered here (none known) were not checked.

### 4. Error handling — **structurally correct; one untested branch.**

The nesting matches `RestIdempotencyCleanupJob:113-144` exactly, including the load-bearing detail
that `TenantContext.setCurrentTenant(tenantProfile)` sits *inside* the outer `try` so a null tenant
name NPEs into a per-tenant catch instead of killing the remaining tenants. The inner catch keeping
the outer label honest is a genuine improvement over the reference.

Nothing escapes the per-tenant loop. Above the loop,
`tenantDbConfigurationRepository.findByActiveTrue()` and the `c.getTenant().getName()` mapping are
uncaught — but they sit inside the outer `try…finally`, so the lock is still released and Spring's
scheduler logs and re-fires next night. Same exposure as the reference job; not a finding.

The `LOG.error`-before-`try` ordering is right and the comment justifying it is accurate.

Gap: **the Service-Log-failure branch has no test** — see M-6.

### 5. The message body — **actionable, but unbounded.** See M-3.

Bounded against the column, though: `message.message` is `text` and **nullable** on Hydra PRD
(`information_schema.columns`), so there is no length limit to overflow. `process` is
`varchar(255)` and the literal is 26 chars. No truncation risk anywhere.

### 6. Javadoc accuracy — **every measured claim I could check is true.**

| Claim | Verdict | Derivation |
|---|---|---|
| "There is no mail capability at all" — the exact `git grep -lI -iE "JavaMailSender\|jakarta\.mail\|starter-mail"` over `src/main` and `pom.xml` | **TRUE** | Re-ran it in the worktree: empty output, exit 1 |
| `/actuator/prometheus` → 401 | **TRUE (mechanism confirmed)** | `SecurityConfiguration.java:147` — `.requestMatchers("/actuator/**").hasAnyAuthority("ADMIN", Authority.WMS_ADMIN_ROLE)`. I did not re-issue the HTTP request. |
| "`SecurityConfiguration` gates `/actuator/**`" | **OVERSTATED** | see L-4 |
| "`findSysvalueBySyskey` returns null for a missing row … `Boolean.parseBoolean(null)` is quietly false" | **TRUE** | `SyspropService.java:335` returns the repository value unwrapped; `SchedulingConfiguration.java:1240` records the same trap in its own words |
| "three independent gates" on the six `SchedulingConfiguration` jobs | **TRUE** | `basicService.isCron()` (`SchedulingConfiguration:270`) + `SYSTEM_PROPERTY_NEW_CRON_JOB_ACTIVATED_KEY` (6 call sites across the 5 job classes) + each job's own `*_TIMER_ACTIVATED` key |
| "63 units … 47 days … 7 rows … 0 initiated, 0 completed … oldest 2026-07-31 … totes T-0002 and T-0007" | **TRUE, all of it** | Hydra PRD: `reversal_required=true, completed IS NULL, initiated IS NULL` → `count=7, sum(amount_picked)=63.0000, min(created_at)=2026-07-31 15:52:44 UTC, totes='T-0002,T-0007'`. 2026-07-31 → 2026-09-16 is 47 days. |
| "Hydra PRD has 9 such rows against 7 that matter" (integration test) | **TRUE** | same query, `reversal_required=false` bucket → `count=9` |
| `AdvisoryLockService` javadoc: "`100009L` was NOT free … catalog corrected on 2026-09-16" | **TRUE** | `wms2-scheduled-jobs-catalog.md:112` now carries the `OUTBOX_DISPATCHER_CLUB` row, `:114` states next-free `100010L`, and the `:596` changelog row records the fix |

---

## Part 2 — findings

### HIGH

#### H-1 — the cron-collision rail was walked past, and it fails silent

**File:** `src/test/java/net/aim_ai/wms/schedulejob/SchedulingReconcileIdempotencyUnitTest.java:1171-1173`

```java
// ⚠ app.cron.outbox-dispatcher-club was MISSING from this list. It arrived with the CLUB
// lane and was never added, so a cadence change that collided on the club lane alone
// would have passed here. Keep this list exhaustive: grep src/main for
// @Scheduled(cron = "${...}") rather than trusting it by eye.
for (String key : List.of("app.cron.outbox-dispatcher",
                          "app.cron.outbox-dispatcher-club",
                          "app.cron.cleanup-rest-idempotency")) {
```

This change adds a **fourth** cron-valued `@Scheduled` property —
`@Scheduled(cron = "${app.cron.pending-reversal-reconcile}")` at
`PendingReversalReconciliationJob.java:104` — and the list is not extended. The list's membership
rule is exactly "`@Scheduled(cron = "${…}")` in `src/main`", so the new key is unambiguously a
member.

**Why it is wrong, not merely untidy.** The test's job is to prove `RECONCILE_CRON`'s second (50)
collides with no fixed-phase cron. The new cron is `0 30 2 * * *` — second 0, so the test would pass
today either way. Nothing goes red. The coverage is simply gone, and the comment above the list is a
signed statement that this precise omission has already happened once and cost real coverage. The
next person who changes `app.cron.pending-reversal-reconcile` to a step cadence gets no signal.

**Fix:** add `"app.cron.pending-reversal-reconcile"` to the `List.of(...)`. One line. The loop's own
`isNotBlank()` guard then also protects against the key being deleted from
`src/main/resources/application.properties`.

---

### MEDIUM

#### M-2 — the Service Log row's identity is entirely unpinned

**File:** `src/test/java/net/aim_ai/wms/unit/schedulejob/PendingReversalReconciliationJobUnitTest.java:107-108`

```java
verify(messageService).createServiceLog(
    anyString(), anyString(), body.capture(), anyString(), any(), any(), any(), any());
```

Four of the eight arguments that define what this row *is* are matched by `anyString()`/`any()`:
`sender`, `receiver`, `process`, `status`. The job's own javadoc calls `PROCESS` **"the handle to
query these rows by"** (`PendingReversalReconciliationJob.java:78`) — and a mutation setting
`PROCESS = ""`, or to `"OUTBOX"`, or swapping `MessageStatus.CREATED` for `SENT`, survives every test
in both new classes. `reconcile_should_isolateTenantFailures` at `:184-185` is the same shape with
`anyString()` for the body too.

The cause is structural: the test lives in `net.aim_ai.wms.unit.schedulejob` while the class lives in
`net.aim_ai.wms.schedulejob`, so the package-private `PROCESS` / `WMS_SENDER` / `OPS_RECEIVER`
constants are invisible to it. That is also why `setThresholdHours` needs `setAccessible(true)`.

**Fix (either):**
- Move the class to `net.aim_ai.wms.schedulejob` — where `SchedulingReconcileIdempotencyUnitTest`
  already sits — which makes the constants visible, lets the reflection helpers be deleted, and
  allows `eq(PendingReversalReconciliationJob.PROCESS)`; or
- keep the location and assert the literals:
  `eq("WMS"), eq("OPS"), body.capture(), eq("PENDING_REVERSAL_RECONCILE"), isNull(), eq(WmsConstants.MessageStatus.CREATED), isNull(), isNull()`.

#### M-1 — the test comment justifying the reflection is factually wrong

**File:** same, `:152-153`

```java
// The field is package-private, and this test sits in the mirror test package.
```

It does not. `net.aim_ai.wms.unit.schedulejob` ≠ `net.aim_ai.wms.schedulejob`; if it were the mirror
package the `setAccessible(true)` in `thresholdHoursOf`/`setThresholdHours` would be unnecessary.
Folded into M-2's fix — moving the class makes the sentence true and the reflection removable.

#### M-3 — three of the four integration tests are negative assertions with no positive control

**File:** `src/test/java/net/aim_ai/wms/integration/repo/PendingReversalOlderThanIntegrationTest.java:73, :87, :100`

```java
.doesNotContain(fresh.getId());
```

`excludesARowInsideTheThreshold`, `excludesACompletedReversal` and
`excludesARowThatNeverRequiredAReversal` each save one row and assert it is *absent* from the result.
Mutate `findPendingReversalsOlderThan` to `return List.of()` — or break the fixture so
`saveAndFlush` never lands — and all three stay green. Only
`findsARowWhoseCreatedAtIsOlderThanTheCutoff_evenWhenNeverInitiated` can tell an empty result from a
correct exclusion, and it is a different test method with a different fixture.

This is the shape recorded as *"a negative assertion on a fixture nobody wrote passes forever."*

**Fix:** in each of the three, also save a control row that *must* be returned, and assert both in one
statement — e.g.

```java
CustomerorderCancellationLog control = save(row(OffsetDateTime.now().minusDays(47), true, null));
CustomerorderCancellationLog fresh   = save(row(OffsetDateTime.now().minusHours(1),  true, null));
List<Long> found = idsFrom(repository.findPendingReversalsOlderThan(OffsetDateTime.now().minusHours(24)));
assertThat(found).contains(control.getId()).doesNotContain(fresh.getId());
```

The `contains` half is what makes the `doesNotContain` half mean anything.

#### M-4 — the message body is unbounded

**File:** `src/main/java/net/aim_ai/wms/schedulejob/PendingReversalReconciliationJob.java:196-200`

```java
String detail = stale.stream()
    .map(l -> "order " + l.getCustomerorderId()
        + " tote " + (l.getToteLabelId() == null ? "(none)" : l.getToteLabelId())
        + " logId " + l.getId())
    .collect(Collectors.joining("; "));
```

`findPendingReversalsOlderThan` has no `LIMIT`/`Pageable` and `describe()` has no cap. At ~48 bytes
per entry, 500 stale rows on one tenant produce a ~24 KB string that is written **twice** — once as a
single `LOG.error` line (`:166`) and once as the `message` body. The DB tolerates it (`message` is
`text`), but a 24 KB log line is the kind of thing that gets a logging pipeline dropped, and a 24 KB
Service Log row is not readable in the UI it was chosen for. Note this repeats **every night** for as
long as the rows stay pending — Hydra PRD's oldest is already 47 days.

Also worth stating: the count that triggers it is a *degraded* state, so the bad case is not
hypothetical — a cancel-cascade regression is exactly what produces hundreds of pending rows at once.

**Fix:** cap the detail list and say so in the text, keeping the count and oldest-age headline intact:

```java
private static final int MAX_DETAIL_ROWS = 20;
...
String detail = stale.stream().limit(MAX_DETAIL_ROWS).map(...).collect(joining("; "));
if (stale.size() > MAX_DETAIL_ROWS) {
    detail += String.format("; … and %d more (query customerorder_cancellation_log)",
                            stale.size() - MAX_DETAIL_ROWS);
}
```

The query already orders `createdAt ASC`, so the 20 shown are the 20 oldest — the right 20.

#### M-5 — the scheduled-jobs catalog now re-creates the exact trap this ticket documented

**File:** `sbdocs/3-Resources/architecture/wms2-scheduled-jobs-catalog.md:112, :114, :583`

`grep -n "PENDING_REVERSAL\|pending-reversal\|PendingReversalReconciliation"` over that doc returns
**zero hits**. So:

- §2's lock-id table has no row for `PENDING_REVERSAL_RECONCILE = 100010L`.
- `:114` still reads *"The high-water mark is `100009L`, so the next free id is `100010L`."* — now
  false; `100010L` is taken and the next free is `100011L`.
- `:583`'s "Add a new cron job" row says the same.

`AdvisoryLockService.java`'s new javadoc goes out of its way to warn that a stale catalog silently
hands the next implementer a colliding id — and then leaves the catalog stale in the identical way,
one revision later. The mitigation it offers ("derive from THIS block") is right, but it does not
undo the doc saying `100010L` is free.

**Fix:** add the §2 row, bump `:114` and `:583` to `100011L`, add the job to the §4 inventory and a
changelog row. The `last_verified` date can stay at 2026-09-06 with the same "targeted fix, not an
audit" note the 2026-09-16 row already uses.

#### M-6 — four prose enumerations of the scheduler's triggers are now wrong

This change adds the **5th** real `@Scheduled` method in `src/main` (derivation:
`grep -rn "@Scheduled" src/main/java` → 15 hits, of which 8 are prose inside javadoc; the 7 real ones
are `OutboxDispatcherJob` ×2, `RestIdempotencyCleanupJob`, `TenantConfigLoader`,
`TenantPoolEvictor`, `SchedulingConfiguration.reconcileSchedules`, and the new job — of which 5 sit
on job/infrastructure beans and are what the counts below mean).

| Site | Says | Should say |
|---|---|---|
| `SchedulingConfiguration.java:83` | "six job crons, **four** `@Scheduled` methods" | five |
| `SchedulingConfiguration.java:241-243` | "**twelve** standing triggers against ten threads" | thirteen |
| `src/main/resources/application.properties:196` | "14 = the **twelve** standing triggers on a cron replica (two outbox lanes, eight business crons, `TenantConfigLoader.scheduledRefresh`, `TenantPoolEvictor`) plus headroom" | thirteen; the enumeration in parentheses also omits the new job, and the headroom this sentence is justifying drops from 2 to 1 |
| `SchedulingConfiguration.java:60-64` | "Jobs NOT listed here, and why: `OutboxDispatcherJob` and `RestIdempotencyCleanupJob` … Note they are not the only such schedulers … `TenantConfigLoader` and `TenantPoolEvictor` also carry `@Scheduled`." | incomplete — `PendingReversalReconciliationJob` is a fifth, and it is the one a reader of `CONFIGURED_JOB_NAMES` is most likely to go looking for |

None of these changes behaviour (14 threads still covers 13 triggers, and the scheduler creates
threads on demand). They are wrong facts in the two places a reader goes to size the pool.

**Fix:** update all four. For `application.properties:196`, state the rule rather than re-listing —
e.g. *"14 ≥ the number of standing triggers on a cron replica (derive with
`grep -rn '@Scheduled' src/main/java` plus the six crons `configureAllTasks` registers) plus
headroom"* — since this is the third incarnation of a list that has rotted each time.

#### M-7 — the Service-Log-failure isolation branch is untested

**File:** `src/main/java/net/aim_ai/wms/schedulejob/PendingReversalReconciliationJob.java:172-177`

```java
} catch (Exception e) {
    // Never let one tenant's Service Log failure cost the remaining tenants their sweep.
    LOG.error("pendingReversalReconcile: failed to write the Service Log row for {} - {}; "
            + "the ERROR line above is the only surviving record of this finding",
```

`reconcile_should_isolateTenantFailures` covers the *repository* throwing, not `createServiceLog`
throwing — and `createServiceLog` is the one that declares `throws BusinessException` and does real
I/O against a sequence and a `NOT NULL`-constrained table. Deleting this whole `catch` leaves every
test green (the outer per-tenant catch would absorb it), so the branch the comment defends is not
actually pinned to this position.

**Fix:** one test —

```java
when(messageService.createServiceLog(any(), any(), any(), any(), any(), any(), any(), any()))
    .thenThrow(new RuntimeException("message sequence unavailable"))
    .thenReturn(new Message());
newJob(lockService, twoTenants(), repo, messageService).reconcile();
verify(messageService, times(2)).createServiceLog(...);   // tenant 2 still got its row
verify(lockService).unlock(AdvisoryLockService.JobLockId.PENDING_REVERSAL_RECONCILE);
```

with `repo` stubbed to return a stale row both times.

---

### LOW

#### L-1 — `.contains("2")` is close to vacuous

**File:** `PendingReversalReconciliationJobUnitTest.java:113-115`

```java
.as("must name how many rows are pending")
.contains("2")
```

The body under test is
`"2 cancellation reversal(s) pending beyond 24h on test - 01; oldest 1128h. order 60861 tote T-0002 logId 1; …"`.
`"2"` appears in `T-0002`, in `logId 2`, and in `24h`. The assertion passes for a body that never
names the count at all. (Contrast the sibling `1128h` assertion at `:124`, which was deliberately
tightened for exactly this reason and is the right shape.)

**Fix:** `.contains("2 cancellation reversal(s)")`.

#### L-2 — the integration test's stated rationale for id-based assertions is wrong

**File:** `PendingReversalOlderThanIntegrationTest.java:37-38`

```java
* <p>Assertions extract ids rather than using {@code hasSize}/{@code isEmpty}: the table is shared
* with whatever else the lane has written, so a count is not a statement about <em>this</em> fixture.
```

`BaseRepositoryIntegrationTest` is `@Transactional("tenantTransactionManager")` — and the qualifier
is the SBDEV-3242 fix, whose own comment at `:27-38` explains that without it the rollback bound to
the *landlord* manager and saves committed. With the qualifier present, each test rolls back and the
table is **not** shared across methods.

The assertion *style* is still the right one (it is robust to a future base-class change and to
container reuse), so only the justification needs correcting — say "robust to the rollback contract
changing" rather than asserting a sharing that does not currently happen.

#### L-3 — new package `integration.repo` duplicates the established `integration.repository`

**File:** `src/test/java/net/aim_ai/wms/integration/repo/PendingReversalOlderThanIntegrationTest.java:1`

`net.aim_ai.wms.integration.repository` already exists with **13** repository integration tests
(`ClientRepositoryIntegrationTest`, `MessageRepositoryIntegrationTest`,
`SyspropRepositoryIntegrationTest`, …). The new class creates a second, near-homonymous package
holding one file. Both run in the failsafe lane (`**/*IntegrationTest.java`), so nothing breaks — but
a `ls src/test/java/net/aim_ai/wms/integration/repository/` no longer enumerates the repository ITs.

**Fix:** move it to `net.aim_ai.wms.integration.repository` and delete the `repo/` directory.

#### L-4 — the `/actuator/**` javadoc claim omits its own carve-out

**File:** `PendingReversalReconciliationJob.java:37-38`

```java
* <li><b>Nothing can scrape a metric.</b> {@code SecurityConfiguration} gates {@code /actuator/**}
*     behind {@code ADMIN}/{@code WMS_ADMIN_ROLE}, and
```

`SecurityConfiguration.java:146-147`:

```java
.requestMatchers("/actuator/health/**", "/actuator/info").permitAll()
.requestMatchers("/actuator/**").hasAnyAuthority("ADMIN", Authority.WMS_ADMIN_ROLE)
```

`/actuator/health/**` and `/actuator/info` are `permitAll`, on the line immediately above. The
conclusion about `/actuator/prometheus` is unaffected and correct, but the sentence as written is a
completeness claim (`/actuator/**`) that the code contradicts.

**Fix:** *"`SecurityConfiguration:146-147` leaves only `/actuator/health/**` and `/actuator/info`
public and gates the rest — `/actuator/prometheus` included — behind `ADMIN`/`WMS_ADMIN_ROLE`."*

#### L-5 — the 02:30 comment gives a reason that does not hold

**File:** `src/main/resources/application.properties:164-166`

```
# SBDEV-3321 F5 — nightly pending-reversal reconciliation. 02:30 so it does not contend with the
# 02:00 retention sweep for the landlord connections each job pins while it holds its lock.
```

Each job pins exactly one landlord connection for its lock; the pool is 10
(`application.properties:76`). Two concurrent jobs would use 4 of 10 including their tenant-list
reads. There is no landlord contention to avoid. The real reasons to stagger are tenant-DB I/O (the
02:00 sweep runs unindexed `DELETE`s over `outbox_message`, per `RestIdempotencyCleanupJob`'s own
javadoc) and keeping the two jobs' logs separable.

**Fix:** restate the reason, or shorten to "02:30 to keep it clear of the 02:00 retention sweep's
unindexed deletes on the tenant DBs."

#### L-6 — no `JobMetrics`, and the javadoc does not say why

`CLAUDE.md`'s canonical new-scheduled-job pattern is four items. The class javadoc argues items 1
(advisory lock), 3 (sysprop gate — deliberately omitted, at length) and 4 (no `@Transactional`)
explicitly. Item 2 — *"Micrometer metrics — use `schedulejob/JobMetrics.java` … Call
`jobMetrics.startTimer`, `completed`, `failed`, `skippedLockBusy`"* — is silently skipped.

There is precedent: `RestIdempotencyCleanupJob`, the class this one models itself on, has no
`JobMetrics` either (derivation: `grep -rn "JobMetrics" src/main/java/net/aim_ai/wms/schedulejob/*.java`
→ `CleanUpOldMessagesJob`, `OrderReleaseJob`, `ReleaseExpiredPickingOrdersFromUserJob`,
`ReplenishOrderJob`, `StaleClubBatchCleanupJob`, `StockSummaryExportJob`, plus the config class —
the two `@Scheduled` cleanup/dispatch jobs are absent). And the class's own argument — that nothing
scrapes Prometheus — applies to its own metrics as much as to the alerting question.

So the omission is defensible. What is missing is the sentence saying so, in a javadoc that
deliberately justifies the other three items.

**Fix:** one sentence: *"No `JobMetrics`, matching `RestIdempotencyCleanupJob`: the same measurement
in §"Alert means a durable record" applies — nothing scrapes `/actuator/prometheus`, so a counter
here records for a reader who does not exist. Add it when a scrape exists."*

#### L-7 — duplicated default on `thresholdHours`

**File:** `PendingReversalReconciliationJob.java:91-92`

```java
@Value("${app.reconcile.pending-reversal.threshold-hours:24}")
int thresholdHours = 24;
```

Two independent defaults for one value. Harmless today — the field initialiser runs first, then
`@Value` overwrites it — but they can drift, and a reader has to work out which wins. Keep the
`@Value` default (it is the one that applies in a Spring context) and drop the `= 24`, or vice versa.
`RestIdempotencyCleanupJob:63-64` has the same shape, so this is house style rather than a new
defect — noting it only because it was introduced here too.

#### L-8 — the deliberate absence of a `@Scheduled` cron default deserves a comment

**File:** `PendingReversalReconciliationJob.java:104`

```java
@Scheduled(cron = "${app.cron.pending-reversal-reconcile}")
```

No `:default`, unlike `OutboxDispatcherJob:62` (`${app.cron.outbox-dispatcher:*/15 * * * * *}`).
This is the **right** call for a watchdog — a `:-` default would silently disable it if the property
went missing, which is precisely the "silence reads as nothing is wrong" failure the class javadoc
spends a paragraph arguing against — and it is why `src/test/resources/application.properties` needed
the new line. But the choice is invisible, and the next person comparing this to `OutboxDispatcherJob`
will read it as an oversight and "fix" it.

**Fix:** one line above the annotation saying the missing default is deliberate and that a missing
property must fail the boot, not disable the watchdog.

#### L-9 — `safeThresholdHours()` re-emits its WARN once per reporting tenant

**File:** `PendingReversalReconciliationJob.java:205` (inside `describe`) and `:118` (for the cutoff)

With a mistyped threshold, the WARN at `:225` fires once for the cutoff plus once for every tenant
that has stale rows. Trivial, but the fix is free: pass the already-computed value into `describe`,
which also removes the (currently impossible, but latent) inconsistency of the headline "beyond %dh"
disagreeing with the cutoff actually queried.

---

## Part 3 — things I checked that are fine

- **`src/test/resources/application.properties` shadowing.** The new `app.cron.pending-reversal-reconcile=-`
  line is correct and sufficient. `@TestPropertySource(properties = …)` is additive and higher
  precedence, so `BaseRollbackIntegrationTest:49` and `MobileReplenishMultiUnitLoadIT:115` — which
  pin `app.cron.cleanup-rest-idempotency=-` inline — still receive the new key from the classpath
  file and do not need their own line. `application-integration.properties` and
  `application-postgres-integration.properties` are profile overlays, not replacements. No
  context-refresh break. `WebContextLaneContextTest` remains the regression signal if the line is
  removed.
- **`"-"` as the disabling value** is Spring's own `Scheduled.CRON_DISABLED`, already used for
  `cleanup-rest-idempotency`.
- **Failsafe lane membership.** `PendingReversalOlderThanIntegrationTest` matches
  `<include>**/*IntegrationTest.java</include>` (pom `:753`) and is excluded from surefire (`:588`).
  It will run under `mvn verify` and be visible to CI. `PendingReversalReconciliationJobUnitTest`
  runs in surefire.
- **Mockito strictness.** `BaseUnitTest` is `@ExtendWith(MockitoExtension.class)`, so the
  `MockitoSession` tracks stubbings on inline `mock()` instances too — the `reconcile_should_doNothing_whenLockIsHeldElsewhere`
  comment about the deliberately-bare `tenantRepo` is correct, and every stub in the file is consumed
  on its own path.
- **`verifyNoServiceLogWritten`'s `catch (Exception e)`** does not swallow verification failures —
  Mockito's `NeverWantedButInvoked` extends `AssertionError`, not `Exception`. The catch exists only
  for `createServiceLog`'s declared `throws BusinessException`. Correct as written.
- **`oldestHours` uses `.max()`, not `.findFirst()`** — correct, and the comment explaining why it
  does not trust the query's `ORDER BY` is the right instinct.
- **`ChronoUnit.HOURS.between` on `OffsetDateTime`** is DST-safe here: `minusDays` on an
  `OffsetDateTime` holds the offset fixed, so the `1128h` assertion for 47 days is exact and will not
  flake.
- **JPQL query shape.** No optional-parameter branch is involved, so the
  `OR :param IS NULL OR :param = ''` rule in `CLAUDE.md` does not apply. `ORDER BY l.createdAt ASC` is
  load-bearing for the M-4 fix and worth keeping.
- **`@Version` on the entity** is populated by `saveAndFlush`; the integration fixture does not need
  to set it.

---

## Suggested order of work

1. **H-1** — one line, restores a guard. Do this first.
2. **M-2 + M-1** — move the unit test to `net.aim_ai.wms.schedulejob`, assert the four literals,
   delete the two reflection helpers and the wrong comment. One edit, three findings.
3. **M-3** — positive controls in the three negative integration tests.
4. **M-4** — cap the detail list at 20.
5. **M-7** — the Service-Log-failure test.
6. **M-5, M-6** — the catalog row and the four stale counts.
7. **L-1 … L-9** — all small; L-3 (package move) pairs naturally with step 2.
