---
ticket: SBDEV-3672
kind: ralplan step 4 — Critic review (deliberate mode), independent of the architect review
date: 2026-10-13
plan: SBDEV-3672-chunk-bol-shipped-notification.md (snapshot as read 2026-10-13)
base: wms2-api a4fd6490 · wms2-web-ui 9e31726 · oms-laravel-api 9e24cdfa
verdict: ITERATE
---

# SBDEV-3672 — Critic review

**VERDICT: ITERATE** (equivalent to REVISE). The core design is sound and the citations hold up. The plan still has to change before wms-tdd-gate. It is missing two things deliberate mode requires (a stated Principles section and a pre-mortem). It also leaves one deploy-time failure mode open: a single tenant whose Flyway run fails would lose all its outbox writes.

## Pre-commitment predictions vs actual
| Predicted | Found |
|---|---|
| Chunk id/key scheme collides with the claim gate or with uk_outbox_message_idempotency_key | Not a collision. The scheme is sound. The unique constraint does turn a D-ii double-click into a 500 (M3) |
| Status math "confirmed = N − pending − failed" is unsound because rows leave the table some other way | Mostly sound. The only other src/main delete path is the cutover-only 06-drain.sh. Service Log resend leaves the status stale (M2) |
| The new mapped column fails on a tenant that missed the migration | **Confirmed: H2** |
| Mutation targets that cannot be killed | **Confirmed: M1 (NON_NULL)** |
| Pre-mortem / observability tests missing | **Confirmed: H1, M7** |

## High
**H1. No Principles section and no pre-mortem, though deliberate mode requires both.** `grep -niE "pre-?mortem|principle"` on the plan finds nothing. The headings jump from §2 to §4 (there is no §3). The ADR carries "Drivers" and "Alternatives", but nothing states the principles the options should be judged against. Criterion 1 (principle–option consistency) therefore has nothing to check against. The implicit principles I can reconstruct are "bound at the source", "≤K unchanged", "smallest change", and "reuse the club pattern". Fixes B and D (a status endpoint, UI, a link column and requeue) are not the smallest change. Nam's D3/D5 justify them, but the plan should say outright that they override "smallest change".
- Failure scenario: tdd-gate and the review lanes have no agreed pre-mortem to test against. H2, M2 and M3 below are exactly the kind of scenario a pre-mortem would have surfaced.
- Fix: add §3 Principles (3–5 items) and a pre-mortem with at least 3 scenarios, each with a detection signal and a mitigation. Candidates: H2 (a tenant's migration fails), M4 (R-1 merchant callback storm on the first PRD day), M5 (the CLUB lane is wedged for every tenant during an OMS outage).

**H2. A tenant that fails V2.2.39 loses every outbox write on that tenant, not only BOL ones.** `OutboxMessage` gains a mapped `lastMessageId`. There is no `@DynamicInsert` (only `@DynamicUpdate`, `OutboxMessage.java:34`), so every `enqueue` INSERT names `last_message_id`. The claim `RETURNING *` and the `findById` in markSent/markRetry also select it. `StartupFlywayMigrator.java:53` says plainly: "One tenant's failure never blocks the app ... degrades that one tenant". `ddl-auto=none` (`application.properties:133`), so nothing catches the gap at boot. On a tenant left on V2.2.38, every business transaction that enqueues (pick, pack, club, close BOL) would throw and roll back. This is not hypothetical: wh01_hydra_v2 sat nine migrations behind for twelve days (`StartupFlywayMigrator.java:325`), and memory records ownership drift blocking `ALTER TABLE`. V2.2.30 (`lane`) had the same exposure and got through, which is luck rather than design. Prereq 1 says only "Flyway at V2.2.38 on every tenant" before. The plan has no post-deploy gate and no rollback section.
- Fix: in §7, add a post-deploy gate. Query `flyway_schema_history` on all six tenant DBs for V2.2.39 success (memory: *estate census is SIX tenant DBs*) before considering the API deploy done. Add a rollback row: revert the API image, since the column is additive and harmless to old code. Alternatively, map the field `insertable=false` so that only the Fix B/D paths read it, which shrinks the blast radius to the new endpoints.

## Medium
**M1. One listed mutation target cannot be killed: "the NON_NULL annotation" (Completeness row 6).** `WmsObjectMapper.standard()` already calls `setSerializationInclusion(NON_NULL)` (`WmsObjectMapper.java:42`), and `BOLS:44` serializes through `WmsObjectMapper.shared()`. Deleting `@JsonInclude(NON_NULL)` leaves U4's "no `chunk_` keys" green. The ≤K payload is byte-identical because of the global setting, not the annotation, so §5 Fix A's stated reason is wrong.
- Fix: drop that mutation target. Pin the true protector instead. Either (a) U4 asserts byte equality against a fixture captured from today's serializer, or (b) the mutation target becomes "setting chunk_index/chunk_count on the ≤K path".

**M2. Service Log resend, which P7 endorses, leaves Fix B's status wrong.** `MessageService.resendMessage:162` POSTs `originalMessageFromDB.getMessage()` via `httpRestService.post` and writes only a `message` row. It never touches `outbox_message`. An operator who repairs a failed chunk from the Service Log (the path P7 says "closes lane A M1") still sees "1 failed" and an active Requeue button on the BOL screen. Requeue would then POST the chunk again; OMS NOOPs it, so this is harmless but confusing. The plan offers two recovery paths and only one of them feeds the status.
- Fix: either state in the UI text that Service Log resends are not reflected, or (cheap) have status look up a later successful resend row whose `redeliver_id` matches the linked `last_message_id`. Add a unit case for whichever you choose.

**M3. D-ii atomicity and concurrency are tested only with mocks.** U13 is a unit test, and AC-D says "D-ii re-chunks in one tx". The one-tx guarantee (DELETE rolls back if any enqueue throws) is exactly what a mock cannot see (memory: *Tx tests blind to propagation*). A double-click runs two D-ii transactions: both read the single FAILED_TERMINAL row, and the second one's chunk INSERT hits `uk_outbox_message_idempotency_key` (`V2.2.00:3748`). The user sees a 500. The HSV "Distributed locks" row ("concurrent clicks are idempotent") holds only for D-i.
- Fix: in D-ii, read the row set `FOR UPDATE`, so the second click blocks and then finds chunk rows and does D-i. Add a PG IT `BolOmsNotificationRowsIT#rechunkIsAtomicAndSecondCallIsPlainRequeue`, plus one case where an enqueue fails and the original row survives.

**M4. R-1 (merchant `outbound_bol_close` callbacks) is not a release gate.** `LWC:2523` `SendClientCallbackJob::queueOutboundBolClose($shippedParcelIds)` runs once per call. With chunking, each merchant gets a partial callback per chunk. §9 R-1 says "Query OMS tenant config before the PRD release". §7 step 6 only warns merchants before the 11135 replay. Fix A itself chunks every >40 BOL from the moment it deploys (ShipItEZ 36/91 and WineCo 70/142 of BOLs, analysis §6). The query is not named, nobody owns it, and there is no go/no-go.
- Fix: add a §7 prerequisite row that names the OMS table/column for `outbound_bol_close`, who runs the query on which tenants, and the decision rule (for example, "any configured merchant → hold the PRD release until OMS debounces or the merchant acknowledges").

**M5. R-3 understates the CLUB-lane cost: it is cross-tenant and gets worse during an OMS outage.** `ODJ:136-139` dispatches tenants **sequentially** inside one advisory-locked CLUB tick. The 39 chunk rows were enqueued together, so they come due together. While OMS is down, a tick holds 25 × 20 s = 500 s for one tenant, every hour, for 24 h (Fix C), and every other tenant's club rows wait behind it. R-3 only gives the healthy 39 × 7.6 s figure.
- Fix: state the outage case in R-3 and give a trigger for D7's fallback (a dedicated lane), for example `tick_duration{lane=CLUB}` p95 > 300 s. Optionally add jitter to `next_attempt_at` for chunk rows.

**M6. The §8 manual test plan cannot be run as written on wms2 dev.**
- "Close a REGULAR BOL with 95 parcels": nobody will build 95 shippable parcels on dev. Say to lower `WMS_BOL_SHIPPED_OMS_CHUNK_SIZE` to 2 and close a 5-parcel BOL, and include the sysprop cache eviction.
- "Point the shipped URL at a dead host": this is a shared, cached sysprop. Name the eviction step and the restore step.
- "Force a chunk to FAILED_TERMINAL": no SQL or access is given.
- "11135 payload copied in": this copies PRD customer data into dev, and dev OMS will not recognise those unique_ids. It also needs an outbox row whose `aggregate_id` matches a closed dev BOL. Instead, synthesize a >K legacy row for a dev BOL with a given INSERT.

**M7. Observability coverage is missing from the expanded test plan.** Nothing asserts the new `wms2.outbox.requeued{aggregate_type}` counter, the D-ii WARN, or the requeue INFO line (user and count). Nothing defines the counter's tag value for D-ii either. Prereq 8 itself notes that metrics are not scraped, and the plan has no proactive alert for a BOL notification that went terminal after 24 h, so an operator learns about it only by opening that BOL. The e2e layer is manual only. That is acceptable, but the plan should say so in a "Deliberately-skipped coverage" section (template §6).
- Fix: add counter and log assertions to U13 and the D-i test. State the alerting gap as an accepted risk, or add a watchdog query on `FAILED_TERMINAL ... process_type='ORDER_BATCH_SHIPPED'`.

**M8. The post-deploy replay of 11135 is concrete, but it is late and its check is thin.** The query and the arithmetic hold: 121932106 × 100000 = 12193210600000, 1,528 / 40 → 39 chunks, and I verified the 11135 payload is REGULAR. The payload has **one pallet with all 1,528 parcels**, so every chunk copies the straddling pallet, which is fine. Two problems:
- (a) The BOL stays unshipped in OMS until a devops PRD release, which could be days or weeks away. The plan does not consider an interim one-off replay or OMS-side manual ship, though analysis R-6 flagged the need.
- (b) "Spot-check 3 unique_ids" happens only after the replay. Take a before snapshot of parcel status counts for all 1,528 unique_ids, compare after, and expect `SUCCESS + NOOP = 1528`.

## Low
- L1: the gate test is annotation-level only (U14). `Sbdev3017TrancheGateContextTest` (`:110-117`, `:533-535`) already pins `(declaring class, deployed path) → function` in a full context, which also covers `/v3`. Add two `row(...)` entries there instead of claiming that only an annotation check is possible.
- L2: the v2 constraint row says readOnly and propagation are "pinned by annotation assertions in U12", but no U12 method does that. Name it, e.g. `#statusIsReadOnlyTenantTx`.
- L3: "club resolver's shape … blank → 40 with a WARN" contradicts the shape it cites. `CustomerorderBatchService:683-684` returns the default on blank **without** a WARN. Pick one and make U8 assert it.
- L4: ambiguous in Fix B: which `state` wins when there are both pending and failed rows? Is chunk index 0-based in `chunk_index`? (The key/id are 0-based per analysis §4, but the payload field is unspecified.) Is `failedChunks.chunkIndex` null for a `BILL_OF_LADING` row?
- L5: the Service Log link should also require `messagePresent`. `getLogDetail` (`store/admin/serviceLogs.js:97-99`) returns an un-awaited promise, so a link to an archived or purged message rejects without being handled.
- L6: `retentionDays` should mirror `RestIdempotencyCleanupJob.safeOutboxRetentionDays()`, not the raw property, or the UI text can name a value that is not actually used.
- L7: the docs row misses `wms2-sysprop-catalog.md` (new sysprop), `wms2-scheduled-jobs-catalog.md` / `wms2-oms-integration-map.md` retry rows (29 attempts), and `wms2-entity-enumeration-report.md` (new column). Step 7's verify-docs should catch these, but list them.
- L8: any oversized single row that is still `FAILED_RETRY` at deploy time now times out hourly for 24 h before D-ii can re-chunk it. PRD census today: none outside 11135 (verified on c1wh, WineCo, Hydra and nywh-ShipItEZ), so note it only.
- L9: the D-i `last_error` suffix contains the user name. Say it is a bound parameter.

## Criterion-by-criterion
1. **Principle–option consistency: FAIL (H1).** No stated principles. Against the implicit ones, Fixes B and D bend "smallest change" (sanctioned by Nam, but unstated). Fix C bends "leave transport alone" only nominally.
2. **Fair alternatives: PASS.** Each rejection cites evidence: same aggregate id (`OMR:46-52` verified), pallet split (11135 is a single 1,528-parcel pallet, which proves the point), longer timeout (lane B H1), dedicated lane (`ODJ:91-97` verified), message-column link, persisting N.
3. **Risk mitigation clarity: PARTIAL.** R-1 is not a gate (M4). R-3 omits the outage case (M5). R-6's "covered by U13" is mock-only (M3). R-2, R-4, R-5, R-7 and R-8 are fine.
4. **Testable ACs: PARTIAL.** AC-A, AC-B and AC-C are all encodable. AC-D's "one tx" is not encodable with the named unit test (M3). One mutation target cannot be killed (M1). New classes are plausible: BolShippedNotificationChunkerUnitTest, BolOmsNotificationServiceUnitTest, BolChunkOutboxClaimIT, BolOmsNotificationRowsIT, OutboxMigrationV2239IT and BolShippedOmsChunkSizeSeedConsistencyTest are new. Every extended class exists: BillofladingServiceUnitTest, OutboxDispatchServiceUnitTest, BillOfLadingControllerUnitTest, ControllerRequestMappingConventionUnitTest, BaseControllerUnitTest, OutboxItFlyway, OutboxLaneClaimIT, OutboxTerminalHoldIT, OutboxStuckAggregateIntegrationTest and ClublineOmsChunkSizeSeedConsistencyTest. I6's "re-run inserts no second sysprop" has to execute the SQL twice by hand, because Flyway will not re-run it.
5. **Concrete verification: PARTIAL (M6, M8).**
6. **Pre-mortem: MISSING. This is a defect (H1).**
7. **Expanded test plan:** unit yes · integration yes (gaps M3) · e2e manual only, not declared (M7) · observability absent (M7).
8. **Checklists:** Completeness rows 0–10 are all filled. Row 6 has a dead target (M1). Row 1's census covers 3 tenants; I extended it to nywh-ShipItEZ (0 rows). HSV: 10 rows filled, but "Distributed locks: No … concurrent clicks are idempotent" is false for D-ii (M3), and "Scheduled jobs" omits the cross-tenant hold (M5). v2 constraints: 8 rows, but the readOnly row claims a test that does not exist (L2).
9. **Claim discipline (completeness words):**
   - "one producer" (§0) — **TRUE**. `git grep ORDER_BATCH_SHIPPED -- src/main` finds one enqueue at `BOLS:800`.
   - "rows leave the table **only** as SENT" (Fix B) — **TRUE for src/main**: `OMR:85` is the only DELETE. The exception is `db/v1-to-v2-onboarding/.../06-drain.sh:27`, which deletes FAILED_TERMINAL during a cutover only.
   - "The dispatcher **never** claims FAILED_TERMINAL" — **TRUE** (`OMR:44`).
   - "`lane` is referenced **only** by club enqueue sites" (D7) — **TRUE**: `CustomerorderBatchService:889,900,916,1034`, plus the definition and ODJ.
   - "≤K payload stays byte-identical" — **TRUE, but for a different reason** (global NON_NULL, M1).
   - "**Exactly** 1 BILL_OF_LADING FAILED_TERMINAL (c1wh); WineCo and Hydra 0" — **TRUE**, re-queried 2026-10-13. c1wh has 11135 only (1 FAILED_TERMINAL across the whole outbox). WineCo has 0 non-SENT rows. Hydra's 2 non-SENT rows are ADVICE_CLOSE. nywh-ShipItEZ has 0.
   - "**Every** new @Transactional names tenantTransactionManager" — a design claim and checkable at review. OK.
   - "**No** per-tenant change is needed" — TRUE given the seed.
   - "Each POST is **still** bounded at 5 + 15 s; 25 × 20 = 500 < 900" — **TRUE** (`ODS:71,74`; `application.properties:243`).
   - "**no** transaction held across HTTP" — **TRUE** (`ODS:152-157`).
   - "**never** throws" (K resolver) — a design claim. U8 covers it.
   - "Hydra has **zero** BOLs >40" — from the analysis, consistent with max 14.
   - HSV "concurrent clicks are idempotent" — **FALSE for D-ii** (M3).
10. **Citations spot-checked (all accurate unless noted):**
    - `BOLS:411`, `:444` (runShippingPhase), `:1578` (finishTransfer caller), `:753` (`setBolId(getName())`), `:779` (empty check), `:791` (serialize; the plan says `:789`, close enough), `:800-806` (enqueue), `:391-400` (type switch)
    - `ODS:181,193,299-302,277-297,71`
    - `OS:52` (64-char check), `OS:97-98` (backoff). The arithmetic checks out: 60+…+1920 = 3,780, plus 23 × 3,600 = 86,580 s over 30 POSTs
    - `OMR:37-58,80-86,102-115`; `ODJ:62,83,79-81,91-97,138`
    - `BillOfLadingController:39,237-238`
    - `CustomerorderBatchService:680` (resolver), `:1034-1036` (span 100_000)
    - `V2.2.29:37-50` (seed shape); index `index_outbox_message_aggregate_order (aggregate_type, aggregate_id, id, status)` is in `V2.2.00:4149` and in onboarding `V2.1.14`
    - V2.2.39 is free across 425 local remote refs (re-sweep before push, as planned)
    - web-ui: `outboundBolDetails.vue:73` (end of the second column's list), pages `{open,closed}/_id.vue:14`, `outboundBols.js:161`, `serviceLog.vue:279,305`, `admin.vue:62,93-94`; baseURL `/v3` (`nuxt.config.js:201`)
    - OMS: `LWC:2130-2138` (transfer branch), `:2181-2188` (HUB_AND_SPOKE logs only), `:2313-2319` (already-shipped skip), `:2418-2432` (shipParcel/NOOP), `:2523` (callback)
    - Test lines: `BillofladingServiceUnitTest:3046-3070,3122-3127,1783`, the never() list, `FinishTransferPreTransferCloseIT:185-190`, `BillofladingServiceFinishTransferIT:170-187`
    - Docs: `wms2-bol-truck-loading-workflow.md:44,114,313-329` and `wms2-oms-integration-map.md:112` are stale exactly as claimed

## What's missing
- Principles, a pre-mortem, a rollback section, and deliberately-skipped coverage (template §6)
- A post-deploy schema-conformance gate for V2.2.39 (H2)
- The R-1 owner, the query and a go/no-go (M4)
- What happens to the status after a Service Log resend (M2)
- An interim plan for BOL 101226(5) before the PRD release (M8)
- A proactive signal for a BOL notification that went terminal after 24 h (M7)

## Multi-perspective notes
- **Executor:** Fix A–D are implementable as written. Gaps that would stall an executor: D-ii locking (M3), the state precedence (L4), and dev manual-test setup (M6).
- **Stakeholder:** it solves the stated problem. The operator-visible "Delivered (HTTP 2xx)" label honestly scopes out SBDEV-2736. The 11135 business recovery is gated on an unscheduled release (M8).
- **Skeptic:** the strongest case against is merchant callback amplification (R-1). It is real and unresolved, and the plan lets the code ship before anyone knows the answer.

## Verdict justification
ITERATE. The review escalated to ADVERSARIAL after H2 and the cluster of Mediums. The design choices themselves (aggregate-id scheme, LANE_CLUB, key-derived N, the D-i guard) survived adversarial checking.

Realist check:
- **H2 stays High.** Its blast radius is every outbox-enqueuing write on a tenant. The precedent of a tenant lagging 12 days is real. Detection is fast (exceptions on every close or pick), but the impact is a tenant-wide write outage.
- **H1 stays High.** It is a hard gate for deliberate mode.
- **M3 recalibrated from High to Medium.** Mitigated by the unique constraint: a racing D-ii fails closed (500 plus rollback) rather than duplicating rows.

To reach APPROVE:
- fix H1 and H2
- fix M1, M3 and M4
- add the M6 and M8 concrete steps
- address M2, M5 and M7 with a line each

## Open questions (unscored)
- Does OMS PHP keep processing after WMS's 15 s client disconnect (`ignore_user_abort`) and commit under nginx's 60 s? If it does, chunk retries after a timeout are NOOPs (fine). If it does not, it does not matter at K=40.
- Should `NO_RECORD` distinguish "empty BOL (SBDEV-2737)" from "purged after 7 d"? The `skipped_empty` counter exists, but nothing per BOL is persisted.

---
*Ralplan summary row*
- Principle/Option Consistency: **Fail.** No stated principles. Fixes B and D silently override "smallest change".
- Alternatives Depth: **Pass.** Evidence-based rejections, verified.
- Risk/Verification Rigor: **Fail.** R-1 is not gated, the replay is under-specified, D-ii atomicity is mock-only, and dev manual steps are not executable.
- Deliberate Additions: **Fail.** No pre-mortem. The expanded test plan lacks observability and has no declared e2e scope.
