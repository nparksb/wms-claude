# SBDEV-3672 — review lane B (critic): design and claims

- Worktree: `.claude/worktrees/wms2-api/SBDEV-3672`, branch `fix/SBDEV-3672-outbox-read-timeout`, base `origin/develop` a4fd6490. The change is uncommitted, 9 modified files and 1 new test.
- Read-only review. No mvn run, no edits in the worktree.
- Evidence: `git -C <wt> diff`, `git grep`, read-only SQL on **c1wh-shipitez-prd** (tables `outbox_message` and `message`), and a read of `v2/oms-laravel-api` `LegacyWmsController::finishedShipping`.
- Date: 2026-10-13.

## VERDICT: DO NOT SHIP as-is

This is about the value and the claims, not the mechanism. The client split, the guard and the new test are sound. What fails is the rationale written into the code: that 30 s fixes the 37–107 KB band. PRD data contradicts it. Once H1 is settled by a measurement, or the claims are rewritten to say what the change actually buys (see H2), this becomes SHIP WITH FIXES.

---

## High

### H1. PRD data suggests 30 s will NOT clear most of the 37–107 KB band. The benefit is unproven and probably absent for 5 of the 7 payloads.

All SHIPPED traffic from c1wh since the OMS endpoint cutover (`message.destination` changed from `api-oms.shipitez.sbo.li` to `api-oms.sbo.li` between 2026-09-17 22:19 and 2026-09-18 22:47 UTC):

| | count | size |
|---|---|---|
| first attempt OK | 13 payloads | largest **16,356 B** |
| first attempt read-timeout (`EX`) | 8 payloads | smallest **33,489 B**: 33.5K, 37.0K, 88.5K, 93.8K, 97.5K, 102.2K, 106.6K, 664K |

Small payloads on that endpoint take about 1–5 s end to end, tick wait included: outbox 7344 (1.5 KB) took 1.1 s, 6049 (2 KB) 3.2 s, 9985 (4 KB) 4.3 s, 9099 (6.2 KB) 4.9 s. The 15 s threshold sits between 16.4 KB (under 15 s) and 33.5 KB (over 15 s).

On a linear model T ≈ a + b·KB with a ≈ 1 s, that bounds b at 0.42–0.85 s/KB. At those rates:
- 88–107 KB lands at **≥ 38–46 s at the slowest slope consistent with the data**, and up to 90 s.
- Only the 33–37 KB payloads (2 of 7) plausibly fit under 30 s.

The model is crude. Cost may scale with parcels or orders rather than bytes, and could be a step function. But it is the only principled estimate the data supports, and it points the wrong way.

**The retries do not measure first-call time, and the code proves it.** OMS `LegacyWmsController::finishedShipping` skips parcels already in `$SHIPPED_STATUSES` ("Parcel already shipped, skipping"). The OMS CHANGELOG records that PHP-FPM has no `request_terminate_timeout`, so a request WMS abandoned keeps running and commits. The ~3 s retries (11089 200@80.1 s, 11092 200@80.9 s; 11091's apparent 18 s is queueing behind 11092's own 15 s timeout on the serial DEFAULT lane) are therefore the skip path. The architect consult (§3) reached the same conclusion.

**Measurement that settles it, before merge:** the OMS v2 Laravel log for the c1wh tenant. For each BOL, take the first `finishedShipping: Found parcel` / `Parcel already shipped` line and the last one, for the 7 first-attempt `EX` timestamps:

| date | time (UTC) |
|---|---|
| 2026-09-21 | 23:01:3x |
| 2026-09-28 | 22:17:5x |
| 2026-10-05 | 22:31:0x |
| 2026-10-12 | 23:00:1x, 23:08:1x, 23:09:1x, 23:10:3x |

The span of those lines is the server-side duration of the first call. Any nginx `$request_time` field gives the same answer. Decision rule:
- p100 under 25 s: 30 s is right.
- 30–55 s: option (b) from the consult (55 s with STALE at 30 m, a deliberate SBDEV-3198 re-acceptance), or chunk the BOL.
- Over 55 s: no WMS timeout helps. That is SBDEV-3754.

If the log is unavailable, at least add the elapsed time per POST to the dispatcher's log line and service-log answer. Metrics are not scraped (memory: wms2 metrics unscraped), so a Timer alone would not be read.

- Fix: get the measurement and set the value from it. Until then, rewrite every "fixes the 37–107 KB band" phrasing (see L1) as a bet.
- Confidence: MEDIUM-HIGH. The data is solid; the extrapolation is a model.

### H2. The change's likely real effect is on the retry path, and nothing in the code or the consult says so.

If the first call to OMS completes server-side (see H1), the problem is the retry. For the 664 KB BOL (outbox 11135), each of attempts 2–6 hit the skip path and still exceeded 15 s. Scaling the ~3 s per 100 KB skip-path cost gives roughly 20 s. At 30 s, the second attempt of a 664 KB-class BOL would probably return 200 and end `SENT` instead of `FAILED_TERMINAL`.

Two consequences:

1. **Outbox 11135 may be a false terminal.** OMS may have shipped every parcel of that BOL on attempt 1. Check the OMS parcel status for that BOL before anyone replays or hand-fixes it.
2. **The javadoc rationale is wrong.** `HttpRestService.java` and `application.properties:244-247` say the BOL "outlived" 15 s and imply 30 s lets it finish. The consult says "No timeout below nginx's 60 s will clear it [664 KB]". Both describe first-call time. The value of 30 s, if any, is that the idempotent retry fits. State that in the code, because it changes what a future reader tunes:
   - The value is bounded by the skip-path time, not the full-processing time.
   - The first attempt still always times out for large BOLs.
   - That first attempt still costs the lane 30 s, not 15 s.

- Fix: reword the rationale in `HttpRestService` and `application.properties`. Add the OMS parcel-status check of 11135 to the ticket.
- Confidence: MEDIUM. It rests on the OMS code path and the CHANGELOG plus the retry timings; nothing measured it directly.

---

## Medium

### M1. Nothing tests that the `@PostConstruct` wiring exists. Deleting the annotation leaves every test green.

`OutboxDispatchServiceUnitTest:661/673/678` call `assertStaleTimeoutCoversWorstCaseTick()` directly on a hand-built instance. Remove `@PostConstruct` (`OutboxDispatchService.java:118`) and the guard never runs in production, yet all three tests still pass. That annotation is the entire point of the runtime half that the consult (§4.1) asked for.

- Fix: add an `ApplicationContextRunner`/`@SpringBootTest`-slice test that sets `app.outbox.dispatcher.read-timeout-ms=55000` and asserts the context fails. The cheaper alternative is a reflection assertion that the method carries `jakarta.annotation.PostConstruct`. Mutation-check it by deleting the annotation.

### M2. Failing the boot is the right failure mode only on cron replicas. It also kills replicas that never dispatch.

`OutboxDispatchService` is an unconditional `@Service`. Only `SchedulingConfiguration` is `@ConditionalOnProperty(app.cron=true)` (`SchedulingConfiguration.java:30`). So an override typo on a web-only replica, where `dispatchBatch` never runs, refuses to start operator-facing WMS over a setting that cannot affect it. Deploys are Portainer webhook recreates of a `:develop` container, not a rolling update that keeps the old pod serving. A bad stack-level env value therefore means an outage of that stack until someone edits the env.

Compared with clamping:
- **For the guard as written:** today no override exists anywhere in the repo (`git grep` over properties, yml, env and Dockerfile finds only `application.properties:243/248`). A breach only causes duplicates if the lock-holder's landlord session dies mid-tick (consult §1). OMS skips already-shipped parcels (H1), so a duplicate `finishedShipping` is benign on OMS. That is a low-probability, low-cost harm, and the guard answers it with a guaranteed total outage.
- **Clamping** (clamp the effective read timeout to the largest value that fits, `ERROR` log naming both values, and keep the build-time pin as the hard gate) keeps WMS up. It degrades to the known 15–30 s behaviour.
- **Recommendation:** clamp plus `ERROR` everywhere. If fail-fast is kept, make it conditional on `app.cron=true`, since only those replicas can claim. Clamping means the clamp must feed the value the client is built with, which ties into L5.

### M3. The 875/900 s budget leaves 25 s margin across 25 rows, and three costs sit outside the formula.

The budget is `batch × (connect + read)`. It leaves out:
- per-row DB work in the same tick (`recordOmsVerdict`, `markSent`/`markRetry` REQUIRES_NEW tx, and `writeServiceLog`, which inserts the full payload: 664 KB per attempt into `message`);
- DNS resolution, which `setConnectTimeout` does not bound;
- the request-body write, since `SO_TIMEOUT` does not bound writes.

The guard's javadoc already admits it is "a bound on silence, not on a slow trickle". The margin shrinks from 400 s (25 × 20 = 500 vs 900) to 25 s, about 1 s per row for all non-HTTP work. This is the one way the change makes duplicate delivery (attack point 5) more likely. It is still gated on the landlord-session-death edge, so Medium, not High.

- Fix: either budget a per-row overhead constant in the guard (for example +2 s/row, which caps read at 29 s at batch 25), or use a strict guard ratio such as worst-case ≤ 0.9 × STALE, and say so in the properties comment.

### M4. A slower OMS now costs the shared DEFAULT lane twice as much per attempt.

The properties comment says it itself (`application.properties:246-247`): "Waits here hold up the rest of the lane, every tenant included". If H1 holds and 88–107 KB still exceeds 30 s:
- each such BOL blocks the serial DEFAULT lane (pick/pack notifications for every tenant on the deployment) for 30 s on its first attempt instead of 15 s;
- a never-clearing BOL costs 6 × 30 = 180 s instead of 90 s.

The 2026-10-12 23:08–23:11 cluster already showed 11091's retry queued behind 11092's timeout.

- Fix: no code change needed if the measurement supports 30 s. Otherwise this is the cost side of the H1 decision, and the ticket should state it.

---

## Low

### L1. Completeness claims, checked with `git grep` and the PRD data

| Claim (location) | Verdict |
|---|---|
| "every payload of 37–107 KB outlived the old shared 15 s on its first attempt" (`HttpRestService` ctor javadoc; `application.properties:245`; `HttpRestServiceReadTimeoutTest` javadoc) | **True but under-scoped and mis-bounded.** True for 6 of 6 in 37–107 KB, but only since the 2026-09-18 cutover to `api-oms.sbo.li`. The band starts at **33.5 KB** (a 33,489 B payload also EX'd on 2026-09-21 23:01:48, 200 on retry at 23:02:51), and every payload ≥ 33.5 KB timed out (7 of 7 below 664 KB). The history refutes "every" if it is not time-scoped: across all `message` history, 174 of 181 payloads of 37–107 KB and 60 of 61 over 107 KB succeeded on the first try before the cutover (most of those rows predate WMS v2, so the comparison also crosses a WMS version). Say "since the 2026-09-18 OMS endpoint cutover, every payload ≥ 33 KB (7/7); none ≤ 16 KB (13/13)". The cutover is itself the most important fact for root cause (an OMS v2 performance regression), and the comments omit it |
| "a 664 KB BOL outlived it on all six" | True (6 × EX, outbox 11135). It is 664,147 B (decimal KB) |
| "`postWithIdempotencyKey`, whose only caller is the outbox dispatcher" (`HttpRestService.java:48`) | **True.** `git grep` in `src/main` finds only `OutboxDispatchService.java:203` |
| "Connect timeout for both clients" (`:42`) | True |
| "Read timeout for every other OMS call (post/get)" (`application.properties:249`) | **Overbroad.** `PlatformVersionCacheService:128` calls the OMS version registry through the `SecurityConfiguration.restClient()` bean, not `HttpRestService`, so this property does not govern it. `EndpointHealthCheck` may probe OMS URLs the same way. Change to "every other `HttpRestService` call" |
| "Raising the shared value would make an operator wait just as long on a stock-update or resend button" | Fair. `ItemDataController:127` and `MessageService:175` are `post` callers. `StockSummaryExportJob:579` is a cron caller on the short client too (consult §4.2); the comment could list it |
| "30s is the ceiling at batch-size 25 (25 x 35s = 875s < 900s)" | True in whole seconds (strictly < 31 s) |
| "or a second replica re-sends rows still in flight" (`HttpRestService` javadoc; guard message `OutboxDispatchService.java:125-126`) | **Overstated.** Per consult §1, Phase 0 runs only under the lane advisory lock, so a reclaim needs the holder's landlord session to die mid-tick. The message makes the guard sound like it prevents a routine event, which inflates the case for failing the boot (M2) |
| "whose PHP-FPM answers in one write once it has finished" (guard javadoc) | **Unverified claim about another system.** Plausible (Laravel `JsonResponse`, nginx buffering), but nothing cited proves it. Hedge it or cite the source |
| "`OutboxDispatchServiceUnitTest` pins that against the deployed properties file" (`HttpRestService` javadoc) | True, but incomplete: the runtime guard is the other half. Mention it, or a reader will think the env-override gap is still open |
| "Must match the value HttpRestService's outbox client is built with: same key, same default" (`OutboxDispatchService.java:102`) | True today, but nothing enforces it (L5) |
| `SchedulingConfigurationUnitTest:675` "Twelve standing triggers" vs `SchedulingConfiguration` javadoc "thirteen" | Pre-existing drift inside a comment block this diff edits. Fix it while you are there, or state the rule instead of a count (memory: prose enumerations rot) |

### L2. The CLUB lane (attack point 3) is safe; one sentence goes stale.

`postWithIdempotencyKey` serves both lanes (`OutboxDispatchService.java:203`, same `batchSize`). A longer timeout only loosens the chunk reasoning. `CLUBLINE_OMS_CHUNK_SIZE_CEILING = 300` stays a valid typo guard. No test in `src/test` pins 15 s against chunking (`git grep` for `15s|15 s|15000|15_000|read timeout` turns up only unrelated tick, poll and sleep constants). The CLUB worst-case tick has the same 875 s bound.

What goes stale: `CustomerorderBatchService.java:128-129` still says "600 would cross the timeout". That was already a dev extrapolation at 15 s, and at 30 s it no longer follows. Reword it as "600 would cross the then-15 s timeout on dev". The comment in migration `V2.2.29` also names the 15 s, but it is immutable (checksum), so leave it.

There is one CLUB benefit nobody wrote down. Per the `:964-969` javadoc, OMS rejects a same-status re-send, which makes the whole chunk read `Status: Error`. Any chunk that used to time out at 15–30 s and get re-sent now avoids that false Error.

### L3. The `@Value` default for the read timeout is duplicated in two classes.

`HttpRestService.java:67` and `OutboxDispatchService.java:103` both carry `:30000`. Change one, and the guard grades a value the client was not built with.

- Fix: have the guard read `httpRestService.getOutboxReadTimeoutMs()`, which the constructor stores, so it grades the value actually in use. This also makes the clamp option (M2) a single source of truth.

### L4. Both `@Value` defaults (30000) are dead on any deployment that ships `application.properties`, but live on the test classpath.

`src/test/resources/application.properties` shadows main, sets no outbox keys, and so gets batch-size default 10 with read-timeout default 30000 (350 s, which passes). That is fine. Just note that ITs never exercise the 25 × 35 configuration.

### L5. `OutboxDispatcherJob.java:117` repeats the literal "connect 5s"

The comment hard-codes "connect 5s" next to the new `HttpRestService.CONNECT_TIMEOUT_MS` constant; `application.properties:239` does the same. Cosmetic.

---

## What's missing

- **Root cause framing.** The slowdown began at the OMS endpoint cutover (2026-09-18). It is an OMS v2 regression, not an inherent property of BOL size. SBDEV-3754 (async OMS) should carry that evidence. Before the cutover, payloads up to 701 KB succeeded on the first try in the retained history.
- **A post-deploy success criterion.** The ticket should say what "fixed" means, for example "zero first-attempt EX for ≤ 107 KB SHIPPED on c1wh over N BOL days", and how to check it: the `message` query in this report, grouped by `md5(message)`.
- **OMS-side check of outbox 11135's parcels** before any replay (H2).
- **The duplicate-delivery picture is better than the ticket states.** OMS skips already-shipped parcels, so today's double delivery for this band is benign at OMS. The real costs are the 60 s latency, the `EX` service-log noise, and false `FAILED_TERMINAL`s.

## Answers to the five attack points

1. **Does 30 s fix anything?** Unproven. A linear extrapolation from PRD says the 88–107 KB band needs ≥ ~38–46 s on the first call. It plausibly fixes the retry of large BOLs (H2) and the 33–37 KB payloads. The settling measurement is OMS log timestamps for the 7 first-attempt EX calls (H1).
2. **Fail-boot on PRD?** Too blunt. It takes down non-cron replicas for a misconfiguration that only affects cron replicas, and Portainer recreates leave no old instance serving. Prefer clamp plus ERROR, or fail only when `app.cron=true` (M2).
3. **CLUB chunking?** No logic or test impact. One stale sentence (L2).
4. **Completeness claims?** "Only caller" is verified true. "Every 37–107 KB" is true only since the cutover, and the band actually starts at 33.5 KB. "Every other OMS call" is overbroad. "A second replica re-sends" is overstated. The PHP-FPM claim is uncited (L1).
5. **Worse duplicates?** Only through the shrunken reclaim margin (M3, 400 s → 25 s, with per-row DB work, DNS and body writes unbudgeted). Otherwise the change can only reduce duplicates.

## Mode

Started THOROUGH. Escalated to ADVERSARIAL after H1 (2 High findings plus a systemic pattern: the claims describe first-call time while the evidence is about retries). The escalation found H2, M2 and the cutover fact.

Realist check:
- H1 kept at High. A merged "fix" that does not fix the band, with the ticket closed, is the expensive failure. It is detectable within one evening of c1wh BOLs, which is why the measurement is cheap.
- M2 kept at Medium. No override exists today.
- M3 kept at Medium. The reclaim is gated on the lock-loss edge.

No severity was raised on data-loss grounds: a duplicate `finishedShipping` is idempotent at OMS (parcel skip).
