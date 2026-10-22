# SBDEV-3672 — architect consult: outbox read timeout (30 s vs 55 s/STALE vs batch)

Worktree: `.claude/worktrees/wms2-api/SBDEV-3672` (paths below relative to it). 2026-10-13.

## Verdict
Ship the split and 30 s **as a property, with STALE and batch left alone**. Do not go to (b) or (c) on the evidence you have.
The part of the proposal that matters most, and that it is missing, is a **runtime** invariant check. The file-reading pin cannot see a deploy-time override, and that override is exactly how someone would "just bump it to 55" on PRD.
Caveat: nothing in hand shows that 30 s clears the 37–107 KB band (see §3). Treat 30 s as a bet you can tune, not a measured fix.

## 1. False reclaim is narrower than the proposal assumes
- Phase 0 runs only inside `runLane` after `advisoryLockService.tryLock` (`schedulejob/OutboxDispatcherJob.java:103`). The lock is a session-level `pg_try_advisory_lock` on a pinned landlord connection held for the whole tick (`service/AdvisoryLockService.java:17-20`, `OutboxDispatcherJob.java:116-117`). While a tick is live, no other replica can run Phase 0 for that lane.
- A false reclaim therefore needs the lock holder's landlord session to **die mid-tick**, which releases the lock while the JVM keeps POSTing. STALE (`job/OutboxDispatchService.java:71`) guards that edge only.
- Within that edge the arithmetic is right. `findAndClaimPending` stamps `modified_at = NOW()` on the whole batch at once (`repo/jpa/OutboxMessageRepository.java:40`), and reclaim keys on `modified_at < cutoff` (`:76`). So the last row ages batch × (connect + read). At 30 s that is 25 × 35 = 875 s < 900 s: legal, but with only 25 s of margin.
- **The duplicates that actually happen are already worse.** Every 37–107 KB BOL is delivered twice today. WMS gives up at 15 s, OMS keeps processing, and the retry at +60 s backoff (`OutboxService.java:91`, `60s × 2^attempts`) re-POSTs. A longer read timeout *removes* real duplicates. Raising STALE only guards a hypothetical one.

## 2. Trade-off table
| | (a) 30 s, STALE 15 m, batch 25 | (b) 55 s, STALE 30 m | (c) 55 s, batch ≤14 |
|---|---|---|---|
| Reclaim margin | 875/900 s (thin) | 1500/1800 s | 14×60 = 840/900 s |
| Crash recovery | 15 m (unchanged) | **30 m**: pick/pack rows stuck IN_FLIGHT, and the aggregate gate (`OutboxMessageRepository.java:47-51`) blocks every later row of that aggregate | 15 m |
| Head-of-line per slow BOL (DEFAULT, all tenants serial) | +15 s vs today. Net *less* lane time if it clears, because 1 call replaces 15 s + retry | +40 s, ×6 attempts on a BOL that never clears = 5.5 min of lane wall-time | same as (b) |
| Landlord pin (SBDEV-3198 accepted at 15 s) | per-tenant worst case 500 → 875 s | 1500 s | 840 s |
| Throughput | 500 rows/min/lane (`application.properties:233-235`) | same | **≤280/min**, paid on every tick to buy margin for a rare BOL |
| Useful ceiling | — | 55 s is just under OMS nginx's 60 s default, so values above ~58 s buy only 504s | — |

(b)'s real cost is the crash-recovery doubling plus the SBDEV-3198 pin growing to 3.3× what was accepted. Neither is worth paying until a measurement shows 30 s misses. (c) taxes every tick for a rare row type.

## 3. Does 30 s plausibly clear 37–107 KB? Unproven
c1wh PRD `outbox_message` (process_type ~ SHIPPED), queried 2026-10-13:
- 11089–11092 (88–107 KB): `attempts=1`, `SENT`, created→modified 78–96 s. That fits 15 s timeout + 60 s backoff + ≤3 s tick + a **≤ ~3–18 s retry**. A retry that fast is most likely OMS answering an already-completed shipment (an idempotent or "already shipped" path). It does **not** measure first-call processing time.
- 9985 (4 KB) 4.3 s, 9099 (6 KB) 4.9 s, 7344 (1.5 KB) 1.1 s, 6049 (2 KB) 3.1 s. These figures include up to 3 s of tick wait. Linear extrapolation is noisy; at ~0.3–0.7 s/KB, 100 KB lands at 30–70 s, which brackets 30 s.
- 11135 (664 KB) failed all attempts → OMS takes > 60 s at that size, consistent with the nginx ceiling.
**Decisive measurement, cheap:** OMS nginx/PHP access-log `$request_time` for `finishedShipping` at 2026-10-12 23:00–23:11 UTC (ids 11089–11092). If p100 < ~25 s, 30 s is right. If it is 30–55 s, take (b). Get it before merge, or set the PRD value from it.

## 4. Things the proposal gets wrong or misses
1. **The pin can be bypassed by an override.** `OutboxDispatchServiceUnitTest#staleTimeoutExceedsTheWorstCaseTick` (`src/test/.../OutboxDispatchServiceUnitTest.java:622-640`) reads `src/main/resources/application.properties`. An env/`SPRING_*` override of `app.outbox.dispatcher.read-timeout-ms` (or of `batch-size`, a gap that exists today) breaks the invariant with the build green. Add a startup guard in `OutboxDispatchService` (`@PostConstruct`) that compares `STALE_INFLIGHT_TIMEOUT` with `batchSize × (connect + readTimeout)` using the **injected** values, and fails context load. Keep the file-reading unit test as the build-time half. Make `WORST_CASE_PER_MESSAGE` an instance value computed from the same injected properties, so the guard and the javadoc formula (`:55-60`) cannot drift apart.
2. **Callers you did not list.** `schedulejob/StockSummaryExportJob.java:579` (`post`, a cron job, not interactive) also uses the shared client. Keeping it on 15 s is fine, but list it in the split's rationale. `CustomerorderService` and `AdviceService` inject `HttpRestService` but have no call site that grep can find, so they are unaffected.
3. **The CLUB lane rides on the same client.** `postWithIdempotencyKey` serves both lanes (`job/OutboxDispatchService.java:172`). `CustomerorderBatchService.java:125-131` and `:976` justify `CLUBLINE_OMS_CHUNK_SIZE_CEILING = 300` "against the 15 s read timeout". The ceiling stays safe at 30 s (it only loosens), but the prose becomes false: update it to name the outbox timeout property.
4. **The 15 s literal appears in prose that will rot.** Update `application.properties:238-242`, `OutboxDispatchService.java:57,73`, `SchedulingConfiguration.java:241`, `SchedulingConfigurationUnitTest.java:677`, and `OutboxDispatcherJob.java:117`. That last one already reads "N × 15s" and omits batch; correct it to N × batch × (connect + read).
5. **The connect 5 s is part of the bound.** Make it a property on the outbox client too (or a named constant both the guard and the factory read), not a second bare literal.
6. **The read timeout is per socket read** (`SimpleClientHttpRequestFactory` → `SO_TIMEOUT`), not a total-time limit. PHP-FPM buffers its output, so this does not bite in practice. Note it in the guard's javadoc so the bound is not described as hard.

## Recommendation (ordered)
1. Split the clients. Outbox client property `app.outbox.dispatcher.read-timeout-ms=30000`, connect from a shared constant. Interactive client stays at 15 s. Effort: S.
2. Add a startup invariant guard on injected values, plus a unit test that a 55 s override fails it. Mutation-check: drop the guard and confirm the test goes red. Effort: S.
3. Pull the OMS `$request_time` for ids 11089–11092 before merge. If it is above 25 s, switch to (b) with STALE at 30 m, as a deliberate SBDEV-3198 re-acceptance. Effort: S, ops.
4. Prose sweep from §4.3–4.4. Effort: XS.
SBDEV-3754 (OMS async) remains the real fix for the 664 KB class. No timeout below nginx's 60 s will clear it.
