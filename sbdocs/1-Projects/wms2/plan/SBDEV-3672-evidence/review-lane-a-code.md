---
ticket: SBDEV-3672
lane: A (code review)
reviewed: 2026-10-13
worktree: .claude/worktrees/wms2-api/SBDEV-3672
base: origin/develop a4fd6490 (no commits ahead; uncommitted diff + 1 untracked test)
method: read-only. git diff, git grep, targeted reads. No mvn/compile (a clean verify was running in the worktree).
verdict: SHIP WITH FIXES
---

# SBDEV-3672 — review lane A (code)

**Files reviewed:** 10 (9 modified + `HttpRestServiceReadTimeoutTest.java` untracked)
**Findings:** 0 High · 3 Medium · 8 Low · 3 open questions (low confidence)

No compile or LSP check ran: the worktree was busy with `mvn clean verify`. The compile and test
evidence has to come from that run.

## Stage 1 — spec compliance: PASS

- Split confirmed. `post`/`get` use `restClient` (`app.oms.http.read-timeout-ms`, default 15000).
  `postWithIdempotencyKey` uses `outboxRestClient` (`app.outbox.dispatcher.read-timeout-ms`, default
  30000). `HttpRestService.java:65-83,130,149,168`.
- `postWithIdempotencyKey` has one caller in `src/main`: `OutboxDispatchService.java:203`
  (`git grep "httpRestService\.(post|get|postWithIdempotencyKey)\("`). The other 7 call sites use
  post/get: ItemDataController:127, AdminActionController:212, MessageDummyController:43,
  StockSummaryExportJob:579, BillofladingService:1732, MessageService:175, OmsNotificationService:118.
- Values ≤ 0 throw IAE at construction (`HttpRestService.java:76-78`). `WORST_CASE_PER_MESSAGE` is
  gone, with no references left in src. The `@PostConstruct` guard is in place
  (`OutboxDispatchService.java:118-131`). The pin test reads both keys from `src/main/resources/application.properties`.
- The club chunks that `CustomerorderBatchService.CLUBLINE_OMS_CHUNK_SIZE_CEILING` bounds go through the
  outbox, so changing that comment to name the outbox timeout is correct.

## Stage 2 — findings

### [MEDIUM] M1 — An operator resend of the failing BOL still uses 15 s, so the recovery path keeps the bug
File: `src/main/java/net/aim_ai/wms/service/MessageService.java:175` (`resendMessage` → `httpRestService.post`)
Confidence: HIGH that the path uses the 15 s client. MEDIUM on how often it happens.
Issue: `dispatchOne` writes a service-log `message` row for every attempt (`writeServiceLog`,
OutboxDispatchService:208-237), and `GET /resend/{messageId}` (MessageController:62) replays that row
through `post()`, which uses the interactive 15 s client. For the 664 KB BOL in this ticket, that resend
is the repair an operator would try. It times out at 15 s again and records `FAILED`/`"503"`, while OMS
probably processed it anyway (outcome unknown). It also sends no `Idempotency-Key`. The ticket's own
symptom comes back on the repair path.
Failure scenario: a row reaches FAILED_TERMINAL on prd. Support opens Service Log and clicks Resend. The
call times out at 15 s and shows "failed". Support clicks again, and OMS may apply the shipment twice
(the resend carries no idempotency key).
Fix (choose one, and record the choice on the ticket):
(a) Give `HttpRestService` a `postLongRunning(url, body)` that uses `outboxRestClient`, and use it in
`resendMessage` when `process` is an outbox-only type (`ORDER_BATCH_SHIPPED` and similar).
(b) Make resend of an outbox-originated row re-enqueue an outbox message (with its idempotency key)
instead of POSTing inline.
(c) Accept the gap explicitly and leave it for SBDEV-3754.
Option (b) also fixes the missing idempotency key.

### [MEDIUM] M2 — Only 25 s of margin is left for everything that is not connect or read time
File: `src/main/resources/application.properties:246-248`, `OutboxDispatchService.java:118-131`
Confidence: HIGH on the arithmetic. MEDIUM on whether it gets breached.
Issue: The guard and the pin test both model a tick as `batch × (connect + read)` = 875 s, against a
reclaim cutoff of 900 s. Before this change the same model gave 500 s against 900 s, so the headroom
fell from 400 s to 25 s. That 25 s has to absorb several costs the model leaves out:
- Per-row DB work: `markSent`, `markRetry` or `markTerminal`, plus `writeServiceLog`, each a
  REQUIRES_NEW tenant transaction. Under tenant-pool pressure, one Hikari `connectionTimeout` wait
  (30 s by default) is longer than the whole margin.
- DNS resolution, which the connect timeout does not cover.
- More than one read per response body, since the read timeout bounds each read, not the exchange.
  The guard's javadoc already says this.
- Clock skew. The cutoff comes from the reclaiming replica's JVM clock (`Instant.now()`,
  OutboxDispatchService:160) and is compared with `modified_at`, which the DB's `NOW()` set at claim
  time (`OutboxMessageRepository.java:66-78`).
The guard's `>=` is the right boundary for the model as written, but the model is optimistic. In
practice, connect and read rarely both max out on the same row (≈25 × 31 s = 775 s), and that is what
keeps this at Medium rather than High.
Failure scenario: OMS degrades and every `finishedShipping` takes 30 s or more. During the same tick the
tenant pool is contended, and a few `markRetry` calls each wait several seconds for a connection. The
tick passes 900 s. Replica B's Phase 0 then reclaims rows that replica A has not POSTed yet, and they
are sent twice. The Idempotency-Key limits the damage only if OMS honours it on that endpoint.
Fix: include an explicit overhead allowance in the guard, e.g.
`perMessage = connect + read + PER_ROW_OVERHEAD (2 s)`. At the deployed values that gives
25 × 37 s = 925 s, which fails. So either set the outbox read to 28 s, or raise `STALE_INFLIGHT_TIMEOUT`
to 20 min. The javadoc's "a crash is rare and self-heals" argument already supports the second option.
Either change makes the margin a deliberate number. Also update the `STALE_INFLIGHT_TIMEOUT` javadoc
("15 minutes clears 25 with room", OutboxDispatchService:66-67), which is no longer true at 875/900.

### [MEDIUM] M3 — The 30000 default is written in two places, and the guard checks its own copy, not the client's value
File: `HttpRestService.java:67` and `OutboxDispatchService.java:102-104`
Confidence: HIGH
Issue: Two independent `@Value("${app.outbox.dispatcher.read-timeout-ms:30000}")` read the same key.
They agree today only because a comment says they must. If someone changes the HttpRestService default
to 60000, or the client gets built from any other source, the guard keeps checking 30000 while the
client waits 60 s. The guard was added to catch exactly that kind of breach. The defaults are live
whenever the key is absent, and `src/test/resources/application.properties` shadows main and does not
set the key, so every Spring test context runs on the defaults.
Failure scenario: a later ticket raises only `HttpRestService`'s default and removes the property line
"because the default matches". Nothing fails: the guard sees 30000, the client waits 60 s, and
25 × 65 s = 1625 s is far past the cutoff.
Fix: have the guard read the value the client was actually built with. Add
`public int outboxReadTimeoutMs()` to HttpRestService (keep the int in a field), delete the
OutboxDispatchService `@Value`, and compute the guard from `httpRestService.outboxReadTimeoutMs()`.
That is a single source of truth by construction. In tests where `HttpRestService` is a mock, the getter
returns 0 and the guard passes trivially, which is fine. If a second `@Value` has to stay, the minimum is
one `public static final String DEFAULT_OUTBOX_READ_TIMEOUT_MS = "30000"` constant used by both
annotations (`"${app.outbox.dispatcher.read-timeout-ms:" + CONST + "}"` is a legal compile-time
constant).

### [LOW] L1 — Nothing checks which property goes to which constructor parameter
File: `HttpRestService.java:66-67`. Tests: `HttpRestServiceReadTimeoutTest.java:73`, `HttpRestServiceUnitTest.java:55`
Confidence: HIGH
Issue: Both unit tests pass ints positionally. If the two `@Value` keys were swapped on the constructor
(operator calls get 30 s, the outbox gets 15 s), every test would still pass. The timeout test proves
which client each method uses, not which property feeds which client.
Fix: add a small `ApplicationContextRunner` test (or `new AnnotationConfigApplicationContext` with
`MockEnvironment`) that sets `app.oms.http.read-timeout-ms=200` and
`app.outbox.dispatcher.read-timeout-ms=10000` and reruns the two timeout assertions against the bean.
A reflection check of the parameter annotations would also work. M3's getter makes this easy to assert.

### [LOW] L2 — `get()` has no test pinning it to the interactive client
File: `HttpRestService.java:168`. Test: `HttpRestServiceReadTimeoutTest.java:98-106`
Confidence: HIGH
Issue: Only `post()` is tested against the slow server. Changing `get()` to `outboxRestClient` would
survive. `BillofladingService.getFacilities` and `AdminActionController`'s connectivity check both run
behind operator screens.
Fix: add a GET context on the stub server and a matching `assertThatThrownBy(() -> service.get(url))`.

### [LOW] L3 — The new test leaks a thread pool per test and leaves a handler sleeping after stop
File: `HttpRestServiceReadTimeoutTest.java:68,77-80`
Confidence: HIGH
Issue: `Executors.newCachedThreadPool()` is never shut down, and `HttpServer.stop(0)` neither
interrupts nor waits for a running handler. After `interactiveCallKeepsTheShortTimeout`, a non-daemon
handler thread sleeps the remaining ~1.3 s and then writes to a closed socket (the catch handles that).
Surefire's fork exits regardless, so this is untidy rather than broken.
Fix: keep the executor in a field and call `executor.shutdownNow()` in `@AfterEach` after `stop(0)`.
`shutdownNow` interrupts the sleep, and the handler already handles `InterruptedException`.

### [LOW] L4 — Flakiness: low risk; no `timing-sensitive` tag needed
File: `HttpRestServiceReadTimeoutTest.java:39-41`
Confidence: HIGH
Assessment: The interactive test cannot pass spuriously or fail from slowness. The server cannot
answer before 1500 ms, the client gives up at 200 ms, and a slow runner only widens that gap. The outbox
test has 8.5 s of slack (1.5 s against 10 s). On a starved 2-vCPU runner, the first-request cost
(HttpServer start, JIT, RestClient init) is well under a second, so I would not tag it. The one way it
could go red is the stub's sleep stretching past 10 s, which needs a stall of seconds on the runner. No
change needed. The note is here so lane B does not re-raise it.

### [LOW] L5 — The pin test inlines `HttpRestService.CONNECT_TIMEOUT_MS`, which the test class's own rule warns against
File: `OutboxDispatchServiceUnitTest.java:633`, cf. `fieldValue` javadoc at :684-686
Confidence: HIGH
Issue: `CONNECT_TIMEOUT_MS` is a `public static final int`, so javac inlines it into the test. The same
file reads `STALE_INFLIGHT_TIMEOUT` reflectively precisely so that "a stale .class would keep passing
against the old value". CI runs `clean verify`, so the risk is limited to incremental local builds.
Fix: read it with `HttpRestService.class.getField("CONNECT_TIMEOUT_MS").getInt(null)`, or note why the
rule does not apply here.

### [LOW] L6 — `@PostConstruct` goes against the repo's move away from it, and sits above the constructor
File: `OutboxDispatchService.java:21,118`
Confidence: MEDIUM (convention, not a defect)
Issue: No other `src/main` class uses `@PostConstruct`. ExceptionMessageService:14, StockunitBusinessService:94
and UnitloadBusinessService:108 all record removing it (SBDEV-3190). It works correctly here: field
`@Value`s are injected before the callback, and the callback runs on the target, not the CGLIB proxy
created for `cleanupSent`'s `@Transactional`. Unit tests built with `new` never call it, which is why
the two new tests call it explicitly. The method is declared between the fields and the constructor, and
the `jakarta.annotation` import sits among the `net.aim_ai` imports.
Fix (optional): move `batchSize`/`readTimeoutMs` to constructor `@Value` params, validate them in the
constructor, and make the fields final. That conflicts with the existing `ReflectionTestUtils.setField(service, "batchSize", …)`
tests, so it is acceptable to keep `@PostConstruct`. At minimum, move the method below the constructor
and the import into the jakarta/org block.

### [LOW] L7 — Stale or weakened claims left in src
Confidence: HIGH
- `OutboxDispatchService.java:66-67`: "15 minutes clears 25 with room". At 875/900 it no longer has
  room (see M2).
- `CustomerorderBatchService.java:127-131`: "300 is the last size with real margin and 600 would cross
  the timeout". That reasoning was against 15 s. At 30 s, 600 (11.8 s locally, more on dev) no longer
  crosses it. The new parenthetical dates the measurement but leaves the conclusion as written. Add
  "(against the then-15 s timeout)" after "cross the timeout".
- `OutboxDispatcherJob.java:117`: the new comment says "connect 5s". Write `HttpRestService.CONNECT_TIMEOUT_MS`
  as the other edited comments do, so it cannot drift.
- `V2.2.29__seed_clubline_oms_chunk_size_sysprop.sql:15,18` still say "15 s read timeout". This is
  correct to leave: an applied migration must not change (Flyway checksum).
- `git grep` found no other stale "15 s read" claims in `src/main` or `src/test`. The remaining "15 s"
  hits are about the old dispatcher cadence, not the timeout.

### [LOW] L8 — Doc drift in sbdocs (for the verify-docs pass)
Confidence: HIGH
- `sbdocs/3-Resources/architecture/wms2-oms-integration-map.md:77` ("5 s connect / 15 s read") and `:330`
- `sbdocs/3-Resources/architecture/wms2-scheduled-jobs-catalog.md:410` ("N × 15 s"). The code comment
  this mirrors (OutboxDispatcherJob:117) was updated, but the doc was not.
- `v2/wms2-api/CLAUDE.md` "OutboxDispatcherJob (every 15 s …)". The cadence is `*/3` (application.properties:222).
  This drift predates this change.

### [LOW] L9 — The worst-case lane stall grows 75 % per slow tenant
File: `application.properties:244-248`, `OutboxDispatcherJob.java:116-117`
Confidence: HIGH (design note, already acknowledged in the property comment)
Issue: Lanes are sequential across tenants under one advisory lock, so a single degraded tenant OMS can
now hold its lane for 875 s per tick instead of 500 s, delaying every other tenant's notifications
(QA tote scans wait on these). The comment states this, and SBDEV-3754 is the real fix. It is listed
only so the trade-off is written down in a review. Worth adding to the PR description.

## Open questions (low confidence, not blocking)

- **[HIGH] OQ1 — The JDK `HttpURLConnection` silently retries a POST.** With `SimpleClientHttpRequestFactory`,
  sun.net's `HttpClient` retries a request once when a reused keep-alive connection fails with a
  non-timeout `IOException` (`sun.net.http.retryPost` defaults to true). That can double a single row's
  wall time, which breaks the per-message model in M2, and it re-sends a POST that may already have been
  processed. `SocketTimeoutException` itself does not trigger the retry, which is why my confidence is
  LOW. This predates the change, but the budget is now tight enough for it to matter. Probe: set
  `-Dsun.net.http.retryPost=false`, or check a dispatcher log for back-to-back duplicate idempotency
  keys in OMS.
- **[MEDIUM] OQ2 — Request-body writes have no timeout.** `SO_TIMEOUT` does not apply to writes. A
  664 KB body is larger than a typical socket send buffer, so if the peer stops reading, the write
  blocks without limit while holding the advisory lock. nginx in front of PHP-FPM normally buffers the
  whole request body promptly, so this is unlikely in practice. It predates the change.
- **[MEDIUM] OQ3 — Is 30 s actually enough?** The motivation shows 37–107 KB payloads exceeding 15 s
  and a 664 KB payload exceeding it six times. If the plan or ticket has no measured OMS-side duration
  for those payloads (OMS access logs or `request_time`), 30 s is a guess, and the largest BOLs may
  still go FAILED_TERMINAL. Ask the author for the measured distribution. If the 664 KB one took more
  than 30 s, say on the ticket that SBDEV-3754 is required for that class of payload.

## Positive observations

- Splitting by caller class instead of raising the shared timeout is the right decision, and the javadoc
  gives the reason (operator screens).
- The non-positive guard covers the real `SimpleClientHttpRequestFactory` trap where 0 means wait
  forever, and the message names the property.
- The pin test now derives the per-message budget from the shipped properties file, which closes the
  blind spot of the old constant. The positive-control assertion is kept and parameterised.
- The guard covers a deploy-time environment override, which the build-time test cannot see, and the
  `>=` edge is tested exactly (30 × 30 s = 900 s is refused).
- The timeout test uses a real socket, so it is not fooled by a mock, and it is
  mutation-sensitive on the question that matters: reverting `postWithIdempotencyKey` to `restClient`
  turns the outbox test red, and swapping the clients' build arguments turns the interactive test red.
- The Flyway migration comments were correctly left alone.

## Verdict: **SHIP WITH FIXES**

No High-severity finding at high confidence. Before merge:
- **M3**: make the guard read the client's actual timeout. This is cheap and removes a silent-drift class.
- **M2**: add the overhead allowance, or raise `STALE_INFLIGHT_TIMEOUT`, and fix the "with room" javadoc.
- **M1**: decide explicitly (a/b/c) and record the decision on the ticket.

L1–L3, L5 and L7 are small and belong in the same pass, per the repo's fix-Lows rule. L8 goes to
verify-docs. L4 needs no action.
