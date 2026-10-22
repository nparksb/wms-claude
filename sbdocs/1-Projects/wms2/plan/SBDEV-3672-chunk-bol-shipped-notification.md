---
title: "SBDEV-3672 — chunk the BOL-shipped OMS notification, with per-BOL delivery status, a longer retry budget and requeue"
ticket: "SBDEV-3672"
ticket_url: "https://app.clickup.com/t/868med0p1"
type: "bug"
priority: "high"
status: "parked"
project: ["wms2-api", "wms2-web-ui"]
version: "v2"
requester: "Nam Park"
created: "2026-10-13"
updated: "2026-10-17"
revision: "PARKED 2026-10-17 (Nam) in favour of SBDEV-3757; PRs now drafts. Was: implemented 2026-10-16 — PRs wms2-api#526 + wms2-web-ui#176 (approved 2026-10-13; D-ii dropped; migration renumbered V2.2.40)"
tier: T3
db_verified: true
related:
  - "[[SBDEV-3672-evidence/analysis-chunk-bol-shipped]]"
  - "[[SBDEV-3672-evidence/architect-consult-outbox-read-timeout]]"
  - "[[SBDEV-3672-evidence/ralplan-architect-review]]"
  - "[[SBDEV-3672-evidence/ralplan-critic-review]]"
  - "[[SBDEV-3672-evidence/plan-snapshot-round1]]"
  - "[[SBDEV-3672-evidence/plan-snapshot-round2]]"
  - "[[SBDEV-3672-evidence/ralplan-architect-review-round2]]"
  - "[[SBDEV-3672-evidence/ralplan-critic-review-round2]]"
  - "[[SBDEV-3672-evidence/plan-snapshot-pre-drop-dii]]"
  - "[[wms2-bol-truck-loading-workflow]]"
  - "[[wms2-oms-integration-map]]"
tags:
  - plan
---

# SBDEV-3672: chunk the BOL-shipped OMS notification

**Ticket:** [SBDEV-3672](https://app.clickup.com/t/868med0p1). **Repos:** `v2/wms2-api` (base `origin/develop` a4fd6490), `v2/wms2-web-ui` (base `origin/develop` 9e31726). **Tier:** T3 (multi-repo, Flyway, data integrity across OMS). **Mode:** ralplan DELIBERATE.

The facts below come from `SBDEV-3672-evidence/analysis-chunk-bol-shipped.md` (the **analysis**). This plan builds on it and does not re-derive it. **Review labels:** `A-…` = architect findings, `C-…` = critic findings; round-2 findings carry an `N`/`m` (e.g. `A-N2`, `C-m3`); bare round-1 labels are not used, because both reviews numbered from M1/L1. `BOLS` = `src/main/java/net/aim_ai/wms/service/BillofladingService.java`, `ODS` = `service/job/OutboxDispatchService.java`, `OS` = `service/OutboxService.java`, `OMR` = `repo/jpa/OutboxMessageRepository.java`, `ODJ` = `schedulejob/OutboxDispatcherJob.java`, `MS` = `service/MessageService.java`, `LWC` = OMS `LegacyWmsController.php`. wms2-api paths are under `src/main/java/net/aim_ai/wms/` unless stated otherwise.

**Approved 2026-10-13 (Nam), with a scope reduction.** The D-ii re-chunk branch of Fix D was dropped after its only PRD candidate (outbox 11135, BOL 101226(5)) was fixed manually in OMS. Requeue is now plain D-i only; see §10 D10. The pre-drop text is kept in [[SBDEV-3672-evidence/plan-snapshot-pre-drop-dii]].

**Superseded approach.** The read-timeout split (`superseded-outbox-read-timeout-split.patch`, review lanes A/B, architect consult) is **not** re-proposed. Lane B H1 showed 30 s does not clear the 88–107 KB band. `HttpRestService` stays at 15 s.

---

## §0 Affected sites

Enumerated with `git grep -n "MessageProcessType.ORDER_BATCH_SHIPPED\|ORDER_BATCH_SHIPPED_URL_KEY" -- src/main` (one producer) and `git grep "runShippingPhase("` (2 callers). See analysis §0.

| # | Site | Change |
|---|---|---|
| P1 | `BOLS:799-806`: the single `outboxService.enqueue(... aggregateType("BILL_OF_LADING") ...)` | **Fix A**: chunk when parcels > K, REGULAR and HUB_AND_SPOKE only |
| P2 | `closeBOL` (`BOLS:341/351` → `:411`), types REGULAR, TRANSFER_OFFSITE, TRANSFER_INTRACOMPANY, HUB_AND_SPOKE (`:391-400`) | through P1; TRANSFER_* stay one row |
| P3 | `finishTransfer` (`BOLS:1576-1578`) | none. OMS `shipTransfer` never iterates parcels (`LWC:2130-2138`) |
| P4 | `ODS.isTerminal` `:299-302`, exception branch `:193` | **Fix C**: per-process-type attempt budget |
| P5 | `ODS.writeServiceLog` `:277-297` (no link back to the outbox row) | **Fix B**: native link of `outbox_message.last_message_id` |
| P6 | `BillOfLadingController` (`/v3/billOfLading`, `:39`) | **Fix B, Fix D**: two handlers |
| P7 | `MS.resendMessage:162` / `MessageController:62` | none in code. Replays one attempt's payload (≤K parcels, ≈7.6 s). Fix B status **reconciles** a successful resend **of the latest linked message** via `redeliver_id` (A-M3/C-M2; limits in R-9). The guard at `MS:163` (sender must equal `getWmsInstanceName()`) also makes the requeue audit row non-resendable (Fix D-3) |
| P8 | Readers R1–R8 (analysis §0) | R1 forces distinct aggregate ids; R2/R3 unaffected (HSV); R7 tests stay green; R8 docs |
| P9 | `MS` (new `createServiceLogInCallerTx`, `Propagation.MANDATORY`) | **Fix D** audit row joins the requeue tx |
| P10 | `scripts/oms-egress-watchdog/egress-failures.sql:90-91` (counts every `message` row with `destination IS NOT NULL AND destination <> 'N/A'`) | none in the script; the audit row uses destination `'N/A'` so it is excluded (A-N1/C-N2), pinned by a new `OmsEgressWatchdogQueryIT` case |
| U1 | `components/outbound/bol/outboundBolDetails.vue`, shared by `pages/outbound/outbound-bol/{open,closed}/_id.vue` (`:14`) | Fix B and D UI |
| U2 | `store/outbound/outboundBols.js` (next to `getBolDetails:161`) | two actions |
| U3 | `components/admin/serviceLog/serviceLog.vue` (`showDetails:279`, `mounted:305`) | `?messageId=` deep link |

## §1 Problem

On closing a BOL, WMS sends **one** `ORDER_BATCH_SHIPPED` POST carrying every parcel. OMS `finishedShipping` costs ~0.19 s per parcel (analysis §6), so large BOLs exceed the 15 s read timeout. On c1wh ShipItEZ PRD, outbox **11135** (BOL 101226(5), id 121932106; 1,528 parcels, one pallet, 664 KB, REGULAR) went `FAILED_TERMINAL` after 5 retries (6 `EX` Service Log rows, 23:25–23:57 UTC 2026-10-12). Outbox 11089–11092 (281–329 parcels) timed out once, then succeeded (analysis §8). Operators cannot see on the BOL screen whether OMS heard about the shipment, and cannot retry it except through the Service Log.

## §2 Root cause

1. **The notification is unbounded.** `BOLS:750-761` builds one DTO with all pallets; `:791` serializes; `:800-806` enqueues one row.
2. **The retry budget is ~31 min.** Backoff `min(60 s × 2^attempts, 3600 s)` (`OS:98`), terminal at `attempts >= 5` (`ODS:301`, `application.properties:244`).
3. **Nothing reports delivery per BOL.** The service-log row (`ODS:279-287`) has no outbox id; `MessageRepository.getDetailViewByKeyword` (`:116-121`) cannot search by BOL; `FAILED_TERMINAL` rows are never auto-deleted (`OMR:80-86`) and no UI path requeues them.

## §3 Principles, drivers and options (RALPLAN-DR)

**Principles** — every option and every fix below is judged against these.

| # | Principle | How this plan honours or bends it |
|---|---|---|
| P-1 | **Bound the call at its source.** | Fix A chunks at the producer; transport timeouts untouched. |
| P-2 | **No change for what is not broken**: ≤K BOLs, transfers and other process types keep today's wire shape. | ≤K payload byte-identical (U4 fixture). **Bent deliberately by D4** (Nam): every `ORDER_BATCH_SHIPPED` row gets 24 h of retries. |
| P-3 | **Every chunk is independently retryable**; no chunk wedges another. | Distinct aggregate id per chunk (`OMR:46-52`). |
| P-4 | **Every failure is visible and fixable from the BOL screen**, and the screen agrees with the system of record **for the paths it models**. | Fix B + D; the status reconciles a successful manual Service Log resend **of the latest linked message** (A-M3/C-M2). Not reconciled, stated in R-9: a resend of an earlier attempt's row, and a chunk whose final link failed. |
| P-5 | **New code must not widen the blast radius of existing paths.** | `last_message_id` is native-only (no entity field), so a tenant that misses V2.2.40 keeps dispatching (C-H2/A-M4). The requeue audit row is invisible to the egress watchdog and cannot be resent (A-N1/C-N2); the requeue's guarded UPDATE matches only `FAILED_TERMINAL` rows, which the dispatcher never touches, so it never blocks the dispatcher's `markSent` (A-N4). There is no operator-triggered outbox DELETE (D-ii dropped, D10). Fixes B and D **override "smallest change"**. Nam sanctioned that override in D3/D5, and the surface stays as narrow as P-5 allows. |

**Decision drivers (top 3):** (1) OMS cost is linear in parcels, so no WMS timeout under nginx's 60 s clears 1,528 parcels. (2) A partial failure must neither wedge siblings nor go unseen. (3) The change must not put any tenant's non-BOL outbox traffic at risk.

**Options**

| Option | Pros | Cons | Verdict |
|---|---|---|---|
| **O1. Fix A + C + B + D** (chunk, 24 h retries, status, plain requeue D-i) | Bounds every POST; operator self-service for every BOL shipped after deploy | Larger surface: Flyway column, Phase-2 write, two endpoints, UI. Every guard brings its own interaction (A-N1, A-N2, A-N4), and each one is pinned by a test. A legacy oversized single row is requeued whole (known limitation, manual recipe in §7) | **Chosen** (Nam D3/D5, D10), with the A-M1/A-M4 guards and the round-2 interaction tests. The round-1/2 version also carried D-ii (re-chunk + DELETE of a legacy row); dropped 2026-10-13 (D10) |
| **O2. Fix A + C only, defer UI** (architect antithesis) | Smallest change; no schema change | Next terminal BOL is invisible again; recovery needs a DB-capable engineer; violates P-4 | Rejected by Nam's D3/D5; kept as the fallback if the B/D surface blocks release |
| O3. Longer read timeout | One-line change | 664 KB needs >60 s (nginx cap); lane B H1 | **Invalidated** |
| O4. OMS async (SBDEV-3754) | Real long-term fix | Other repo, unscheduled | Follow-up, not an alternative now |

## §4 Architecture

```
closeBOL ─► runShippingPhase (one tenant tx)
              build palletDtos ─► empty? ─ yes ─► skip (SBDEV-2737), no rows
                                       │ no
              type ∈ {REGULAR,HUB_AND_SPOKE} && parcels > K ?
                 no  ─► 1 row  BILL_OF_LADING / bol.id / UUID key / lane DEFAULT  (unchanged)
                 yes ─► serialize ALL N chunks first ─► N rows BILL_OF_LADING_CHUNK
                        id = bol.id×100000+i (i 0-based), key BOL-SHIPPED-<bol.id>-C<i>of<N>, lane CLUB
                                       │ commit
OutboxDispatcherJob ─ lane DEFAULT (ODJ:62) / lane CLUB (ODJ:83) ─► ODS.dispatchBatch(lane)
   claim (OMR:37-58) ─► POST (5+15 s) ─► markSent / markRetry / markTerminal
   ─► writeServiceLog ─► [B] native UPDATE last_message_id (ORDER_BATCH_SHIPPED only, best-effort)
   [C] ORDER_BATCH_SHIPPED terminal at attempts ≥ 29 (≈24 h); others unchanged at 5
BOL detail ─► GET  /v3/billOfLading/omsNotificationStatus/{id}   [B]
           ─► POST /v3/billOfLading/requeueOmsNotification/{id}  [D] (+ audit row in Service Log, destination 'N/A')
              guarded UPDATE … WHERE status='FAILED_TERMINAL' RETURNING id ─► REQUEUE (≥1 row) / NONE (0 rows)
              lock_timeout behind another tx → 409 ProblemDetail
           ─► /admin?messageId=… ─► Service Log detail dialog
```

| File | Role |
|---|---|
| `BOLS` `runShippingPhase:444`, enqueue `:779-807` | producer |
| `service/BolShippedNotificationChunker.java` (**new**) | pure splitter + K resolver |
| `OS`, `ODS`, `OMR` | outbox state machine, claim, link, row-set queries |
| `model/OutboxMessage.java` | **unchanged** (P-5) |
| `ODJ:62-86,102-171` | lane consumers |
| `service/BolOmsNotificationService.java` (**new**) | status read, requeue, audit |
| `MS` | +`createServiceLogInCallerTx` (MANDATORY) |
| `controller/BillOfLadingController.java` | two handlers |
| `db/migration/V2.2.40__bol_shipped_chunk_size_and_outbox_message_link.sql` (**new**) | sysprop seed + nullable column |

## §5 Fix design

### Fix A: chunk the notification (D1, D2, D7)

`BolShippedNotificationChunker.split(dto, k)` returns `List<BillOfLadingWebServiceDto>`:
- walks parcels (`OrderDto`) in order and cuts every K; a parcel is never split from its items;
- a pallet straddling a cut is copied into each chunk with the same `pallet_label` (11135 is a single 1,528-parcel pallet, so every chunk carries it);
- every chunk has the full header and the same `bol_id`; slices are new lists, never `subList` views;
- never emits a chunk holding only empty pallets.

`runShippingPhase` calls it only when `type ∈ {REGULAR, HUB_AND_SPOKE}` **and** total parcels > K. Then:
- it serializes **every** chunk before enqueueing any; a failure throws `FacadeException`, rolling back the close (SBDEV-2221); `serialize_failed` increments once per BOL;
- it enqueues N rows: `aggregateType("BILL_OF_LADING_CHUNK")`, `aggregateId(bol.getId() * 100_000L + i)`, `idempotencyKey("BOL-SHIPPED-" + bol.getId() + "-C" + i + "of" + n)`, `lane(LANE_CLUB)`. `i` is **0-based** everywhere (id, key, payload). Key ≤45 chars (< 64, `OS:52`). Throws if `n > 99_999`.
- the chunk DTO carries `chunk_index` (0-based) and `chunk_count`. On the ≤K path neither is set; the ≤K payload stays byte-identical **because `WmsObjectMapper.standard()` already applies global `NON_NULL` (`WmsObjectMapper.java:42`)**, not because of a field annotation. U4 pins this with a byte-equal fixture captured from today's serializer.

K = `resolveBolShippedOmsChunkSize()`, read **once** per close from `WMS_BOL_SHIPPED_OMS_CHUNK_SIZE`, exactly the club resolver's shape (`CustomerorderBatchService:680-700`):
- missing or blank → 40, **no WARN** (matches `:683-684`);
- unparseable or <1 → 40 with WARN; >60 → 60 with WARN;
- never throws.

**Why not the alternatives:** same aggregate id for every chunk wedges siblings on one terminal (`OMR:46-52`); pallet split is unbounded (11135 = one pallet); transfers are never iterated by OMS; longer timeout invalidated (O3).

### Fix B: per-BOL OMS confirmation status (D3)

1. **Link column, native-only (C-H2/A-M4, A-L2, A-L5).** V2.2.40 starts with `SET LOCAL lock_timeout = '5s';` (LOCAL so the setting dies with Flyway's migration tx rather than riding a pooled connection). `StartupFlywayMigrator:292-299` runs each migration in its default transaction and V2.2.40 has no `CONCURRENTLY`, so `SET LOCAL` is in scope. The statement carries a SQL comment explaining why. Per `V2.2.26:114-117`, SBDEV-3250's `lock_timeout` is applied by `tenantTransactionManager` at transaction begin, and `StartupFlywayMigrator` builds its own `Flyway.configure().dataSource(...)` and never passes through it. Without the `SET LOCAL`, the ALTER would wait unbounded behind a replica's long close tx during a rolling deploy. Then `ALTER TABLE outbox_message ADD COLUMN IF NOT EXISTS last_message_id bigint` (nullable, no FK, metadata-only in PG). **`OutboxMessage` gets no field.** Access is native SQL only:
   - `OMR.linkServiceLog(id, mid)`: `@Modifying` native `UPDATE outbox_message SET last_message_id = :mid WHERE id = :id` — touches neither `version` nor `modified_at` (reclaim `OMR:76` and watchdog ordering unaffected). Called via `OS.linkServiceLog` (REQUIRES_NEW, `tenantTransactionManager`).
   - `writeServiceLog` returns the saved `Message` id or null. In `ODS.dispatchOne`, after each `writeServiceLog` and **only for `ORDER_BATCH_SHIPPED`**, call the link inside its **own** try/catch. In the 2xx branch `markSent` (`ODS:178`) sits inside the try whose catch (`:192`) would re-mark a SENT row; the link's own guard is what prevents that (A-L3). A link failure logs WARN and increments `wms2.outbox.service_log_link.failed{process_type}`.
   - Consequence: a tenant missing V2.2.40 still enqueues, claims and dispatches (the claim's `RETURNING *` maps only entity columns); only the link (swallowed) and the two new endpoints fail on that tenant.
2. **Row-set query.** `OMR.findBolNotificationRows(bolId)` (native; served by `index_outbox_message_aggregate_order (aggregate_type, aggregate_id, id, status)`, `V2.2.00:4149`):

   ```sql
   (aggregate_type='BILL_OF_LADING' AND aggregate_id=:bolId)
   OR (aggregate_type='BILL_OF_LADING_CHUNK' AND aggregate_id BETWEEN :bolId*100000 AND :bolId*100000+99999)
   ```

   It `LEFT JOIN`s `message m ON m.id = o.last_message_id` (→ `messagePresent`) and, **only for `FAILED_TERMINAL` rows**, evaluates `resendConfirmed = EXISTS (SELECT 1 FROM message r WHERE r.id > o.last_message_id AND r.redeliver_id = o.last_message_id AND r.statuscodeanswer ~ '^2')` (A-M3/C-M2). The `r.id >` bound is sound because `message` ids come from `seqentities` with `allocationSize=1` (`AbstractBaseEntity.java:19-24`), and on WineCo `max(id)` equals `seqentities.last_value` (C-m7). `message.redeliver_id` has an FK but **no index** (`V2.2.00:1408,5618`); the `r.id > last_message_id` bound turns it into a PK range scan over messages written since the failure. Before merge, Step 3 runs `EXPLAIN ANALYZE` of this query on **both** c1wh-ShipItEZ PRD (`message` ≈0.50 M rows) **and** WineCo PRD (≈1.82 M rows, the largest), each against a real `FAILED_TERMINAL` row or a representative `last_message_id` (C-m7). If either takes >200 ms, a `CREATE INDEX CONCURRENTLY` on `message(redeliver_id)` becomes a follow-up needing Nam's yes. Only one resend hop is followed, and only from the **latest linked** message (R-9).
3. **Service.** `BolOmsNotificationService.status(bolId)`, `@Transactional(value="tenantTransactionManager", readOnly=true)`.
   - N: from a chunk row's key (`…of<N>`); a `BILL_OF_LADING` row → N = 1; no rows → N unknown.
   - `failed` = `FAILED_TERMINAL` and not `resendConfirmed`. `pending` = `PENDING`, `IN_FLIGHT`, `FAILED_RETRY`. `resendConfirmed` rows count as confirmed, labelled "delivered via manual resend".
   - `confirmed = N − pending − failed`. Includes purged SENT rows: rows leave the table only as SENT (`OMR:84-86`; the cutover-only `06-drain.sh:27` and the one-off Step 7 close-out of 11135 are out of scope; no product path deletes a non-SENT row). An operator's manual DELETE of a terminal row would read as confirmed — documented, not defended.
   - **`state` precedence (C-L4):** `NOT_SHIPPED` (BOL not CLOSED/TRANSFER) › `FAILED` (failed > 0) › `PENDING` (pending > 0) › `CONFIRMED` › `NO_RECORD` (closed, no rows).
   - **`NO_RECORD` reason (D3, confirmed by Nam 2026-10-13; A-N5):** evaluated in this order:
     - `EMPTY_BOL`, **kept**, with the predicate named here so the executor does not choose one. The close skips the notification iff `palletDtos.isEmpty()` (`BOLS:779`). `palletDtos` gets one entry per *top-level* position of `billofladingPositionRepository.findByBillofladingId(bol.id)` (`BOLS:463`), classified at `BOLS:479-490`. A top-level position is one whose `carrierId` is null or names no position of the same BOL. Garbage rows (operator, carrier, itemdata and source all null) are deleted at close (`:493-497`), so any top-level row that survives a close is a pallet. The status read is therefore one native `NOT EXISTS` over `billofladingposition` for this BOL: a row whose carrier id is null or not among the same BOL's position ids, and which is not garbage-shaped. This is the same source query and the same classification, read as an existence check. U12 pins it against the `:479-490` classification fixture.
     - `PURGED` only when `billoflading.shipped` < today − (`retentionDays` + 1). The +1 is needed because purge keys on the outbox row's `sent_at` (`deleteSentOlderThan`, `OMR:84-86`; corrected 2026-10-13 from `modified_at`, same reasoning), and under Fix C the last send can land up to ~24 h after the ship date. BOLs closed under v1 (before the v2 outbox) also read `PURGED`; that label is harmless, because they were notified by v1.
     - `UNKNOWN` otherwise, **including the boundary day** (`shipped` within [today − `retentionDays` − 1, today − `retentionDays`]).

   - **Legacy row (A-L6):** a single non-SENT `BILL_OF_LADING` row with parcels > `CHUNK_SIZE_CEILING` (60) carries top-level `legacy: true, legacyParcels` (*amended 2026-10-16 from "> K"*: the label means "cannot fit one OMS call", which depends on OMS cost — 60 × 0.19 s ≈ 11.4 s < 15 s — not on the operator's K; keying on K would relabel legitimate single rows whenever K is lowered. Review-api-code round 2 addendum) and the UI says "1 legacy notification (1,528 parcels)" instead of "0/1". Requeue sends such a row **whole**; it is not re-chunked (D10, known limitation, §7 "Known limitation: legacy oversized row").
   - Response: `state`, `noRecordReason`, `chunkCount`, `confirmed`, `pending`, `failed`, `resendConfirmed`, `retentionDays` (the value from `RestIdempotencyCleanupJob.safeOutboxRetentionDays()` — extracted to a shared helper so the UI names the value actually used, C-L6), `failedChunks[]` of `{outboxId, chunkIndex (null for BILL_OF_LADING), chunkCount, attempts, nextAttemptAt, lastError (abbrev 300), lastMessageId, messagePresent}`.
   - "Confirmed" means **HTTP 2xx**; body-level `Status:Error` stays with SBDEV-2736 (D6). UI label: "Delivered (HTTP 2xx)".
4. **Endpoint.** `@RequiresFunction(WEB_UI_VIEW_BILL_OF_LADING) @GetMapping("/omsNotificationStatus/{id}")`; inherits `/v3` (`:39`). Unknown BOL → 404 (`EntityNotFoundException`).
5. **UI.** `outboundBolDetails.vue` gains an "OMS notification" row after `:73` (`38/39 delivered · 1 failed`, legacy text, or the `NO_RECORD` text by reason). A failed-chunk list links to the Service Log **only if** `functions` includes `WEB_UI_VIEW_MESSAGES` (`pages/admin.vue:93-94`) **and** `messagePresent` (C-L5 — `getLogDetail`, `store/admin/serviceLogs.js:97-99`, rejects unhandled on a purged id). The link commits `admin/setParentTab` 6 (`admin.vue:62`) and pushes `/admin?messageId=<id>`. `serviceLog.vue` `mounted()` calls `showDetails({id})` when `$route.query.messageId` is numeric. Fetched from a `watch` on `outboundBol.id`; a 404 from the endpoint hides the row.

**Why not the alternatives:** payload `LIKE` matching (seq scan, brittle); a `message.outbox_message_id` column (large table, concurrent index, lost on purge anyway); persisting N on `billoflading` (second hot-table schema change); mapping the column on the entity (C-H2: tenant-wide outbox outage if V2.2.40 fails).

### Fix C: ~24 h of retries for every BOL-shipped notice (D4)

Private `int maxAttemptsFor(OutboxMessage m)` returns `bolShippedMaxAttempts` when `ORDER_BATCH_SHIPPED.equals(m.getProcessType())`, else `maxAttempts`. Both `ODS:181` and `:193` use it. 400/404/422 stay immediately terminal (`:300`). Property `app.outbox.dispatcher.bol-shipped-max-attempts=29` (`@Value(...:29)`). Delays: attempts 0–5 sum 3,780 s; 6–28 each 3,600 s → 86,580 s ≈ 24.05 h over 30 POSTs. `STALE_INFLIGHT_TIMEOUT` (`ODS:71`) unchanged (25 × 20 s = 500 s < 900 s). Stuck-aggregate gauge (`OMR:102-115`) unaffected (chunk aggregates have one row).

**Why not:** global raise retries poisoned pick/pack for 24 h; keying on aggregate type leaves the ≤K single row at 5 (Nam rejected); time-based terminal needs a `created_at` comparison the design lacks.

### Fix D: requeue a BOL's failed notification (D5)

`@RequiresFunction(WEB_UI_VIEW_BILL_OF_LADING) @PostMapping("/requeueOmsNotification/{id}")` → `BolOmsNotificationService.requeue(bolId)`, `@Transactional(value="tenantTransactionManager")`. Response `{requeued, mode: REQUEUE|NONE, reason?}`. **A lock timeout is a 409 ProblemDetail, never a 500.** A clean "nothing eligible", including the loser of a concurrent double click, returns 200 with `mode: NONE`.

Requeue is **D-i only** (D10). There is no re-chunk branch, no DELETE, no `SELECT … FOR UPDATE` and no `OutboxRequeueConflictException`.

1. **Read, then one guarded UPDATE (A-N4).**
   - **Plain read.** `findBolNotificationRows(bolId)` (Fix B-2, non-locking) yields the BOL's full row set with `resendConfirmed`. Eligible ids = rows that are `FAILED_TERMINAL` and **not** `resendConfirmed`. If none: `NONE`, with `reason` = `"in flight, nothing to requeue"` when any row is `IN_FLIGHT`, else `"nothing failed"`. No UPDATE, no audit row.
   - **Requeue.** `OMR.requeueBolTerminal(ids, currentUrl)`, `@Modifying` native, same `UPDATE … RETURNING` shape as the claim (`OMR:36-58`): `UPDATE outbox_message SET status='FAILED_RETRY', attempts=0, next_attempt_at=NOW(), modified_at=NOW(), destination_url=:currentUrl WHERE id IN (:ids) AND status='FAILED_TERMINAL' RETURNING id`. `currentUrl` = the **current** `WEBSERVICE_ORDER_BATCH_SHIPPED` sysprop (A-L4). Keys are untouched. `last_error` is **not** annotated, because `markRetry/markTerminal` overwrite it (`OS:101,115`), so it is no audit trail; this also retires C-L9. Transfers and legacy single rows take the same path.
   - **Result.** Returned ids non-empty → write the audit row (step 3) naming exactly those ids, return `REQUEUE`. Returned ids empty (every eligible row changed status between the read and the UPDATE) → `NONE`, `"nothing failed"`, **no audit row, no counter**.
   - **Lock scope (A-N4).** A PG `UPDATE` locks only rows that satisfy its `WHERE`. The ids are `FAILED_TERMINAL` rows, which the dispatcher never claims (it claims `PENDING`/`FAILED_RETRY`, `OMR:36-58`), so `IN_FLIGHT`, `PENDING`, `FAILED_RETRY` and `SENT` rows are never locked and the dispatcher's `markSent` (REQUIRES_NEW, `OS:81`) cannot wait out the 3 s tenant `lock_timeout` behind a requeue.
   - **Concurrency: naturally idempotent.** Two concurrent requests both read the same eligible ids. The first `UPDATE` takes the row locks; the second blocks on them, and under READ COMMITTED re-evaluates `status='FAILED_TERMINAL'` after the first commits, finds `FAILED_RETRY`, and **updates 0 rows**. It returns `NONE` with no audit row. A second request that starts after the first commits reads no eligible rows and returns `NONE` directly. Either way: exactly one `REQUEUE`, one audit row, one counter increment.
   - **The one remaining 409 path (A-N2).** The blocked second `UPDATE` waits under the 3 s tenant `lock_timeout` (`LockTimeoutHibernateJpaDialect.java:213`, `application.properties:128`). The winner's tx is one UPDATE plus one INSERT, so this needs the row lock held elsewhere for > 3 s, e.g. a stalled winner or a manual SQL session holding the row. That path is real but remote, so the mapping stays: the service catches nothing, and `BillOfLadingController` catches `PessimisticLockingFailureException` (covers `CannotAcquireLockException`) **outside** the service tx and maps it to **409 ProblemDetail** (precedents `StockUnitController:421`, `mobile/PickingController:76`). The `DataIntegrityViolationException` and `OutboxRequeueConflictException` mappings are **dropped**: D-i inserts no outbox row (no idempotency-key collision is possible) and has no rowcount guard. Any other exception keeps today's handling.
2. *(Removed 2026-10-13: the D-ii re-chunk branch. See D10 and [[SBDEV-3672-evidence/plan-snapshot-pre-drop-dii]].)*
3. **Audit row (A-M1, A-N1/C-N2).** For a `REQUEUE` with ≥1 returned id, the requeue tx writes one Service Log `message` row via the new `MS.createServiceLogInCallerTx(...)`, annotated `@Transactional(value="tenantTransactionManager", propagation=MANDATORY)`. It is called from another bean, so the proxy applies. It is needed because `createMessage` delegates (`MS:106-107`) to `createServiceLog`, which is `REQUIRES_NEW` at `MS:110` and would survive a rollback. Fields, all pinned in I4/O4:
   - `process` = `ORDER_BATCH_SHIPPED_REQUEUE` (new `MessageProcessType` constant);
   - operator = the principal (`saveServiceLog` resolves it, `MS:125-136`);
   - **`destination` = `'N/A'`**. This is the egress watchdog's own exclusion literal (`scripts/oms-egress-watchdog/egress-failures.sql:90-91`, `WHERE m.destination IS NOT NULL AND m.destination <> 'N/A'`), so the watchdog excludes the row **by destination**, whatever its code. A non-`'N/A'` destination with a non-2xx code would count as a failure, and three requeues within the lookback window would put `ORDER_BATCH_SHIPPED_REQUEUE` in `failing`;
   - **`statuscodeanswer` = `'REQUEUE'`**, so Service Log can filter on it. It is not a 2xx code, but that does not matter, because the watchdog never reads it for an `'N/A'` row;
   - **`sender` = literal `wms:requeue`**, which never equals `syspropService.getWmsInstanceName()`, so `MS.resendMessage` refuses the row with "Message not from WMS!" (`MS:163-164`) and an operator cannot "Resend" an audit row into a FAILED/503 row;
   - `answer` = Jackson-serialized `{bolId, outboxIds, mode, user}` (`outboxIds` = the ids the UPDATE returned), with all values bound through the serializer, never concatenated.

   MANDATORY matters even without D-ii: the audit row must commit or roll back with the status flip, so a requeue tx that fails after the audit write (at flush/commit, or a later exception in the call) leaves neither a flipped row nor an orphan audit row. Under `REQUIRES_NEW` the audit row would commit on its own.

   Pins: `OmsEgressWatchdogQueryIT#requeueAuditRows_yieldZeroFindings` (three audit rows inside the lookback window → zero `failing`/`misrouted` rows for that process) and U13 `#auditRow_isNotResendable` (`resendMessage` on it throws).
4. **Telemetry (C-m6).** INFO `requeue bolId={} user={} mode={} rows={}`. Counter `wms2.outbox.requeued{aggregate_type, mode}` increments **by 1 per successful requeue call** (one operator action = one count). The row count lives in the log's `rows` field and in the audit answer, not in the counter. `aggregate_type` is the shape of the requeued rows: `BILL_OF_LADING` for a single row, `BILL_OF_LADING_CHUNK` for chunk rows. `mode` is always `REQUEUE` now (kept as a tag so the metric shape is stable). `NONE` (including the 0-rows concurrent loser) and 409 do not increment.
5. **Gate.** The screen's own function, `WEB_UI_VIEW_BILL_OF_LADING`, which already gates `closeOutboundBol` (`BillOfLadingController:237-238`), the action that emitted the notification. sb_admin-only is the retired anti-pattern; a new `WEB_UI_ACTION_*` needs three artifacts for no gain (SBDEV-3017 §9.16 Option B; SBDEV-3606 does not generalise).
6. **UI.** "Requeue failed OMS notification" button when `failed > 0`; confirm dialog with the count; shows `reason` on `NONE`; on 409 shows "Another requeue is in progress — refresh and retry" (no error toast); refreshes status. A legacy row keeps its "1 legacy notification (N parcels)" label; the UI does not block its requeue, and the runbook (§7) tells operators to use the manual recipe instead. Rows reconciled by a resend show "delivered via manual resend (of the latest linked message)".

## §6 File change summary

| Repo | File | Change |
|---|---|---|
| api | `service/BillofladingService.java` | chunk branch at `:786-807`; resolver |
| api | `service/BolShippedNotificationChunker.java` | **new**, pure |
| api | `json/BillOfLadingWebServiceDto.java` | +`chunk_index`, `chunk_count` (Integer, unset on ≤K) |
| api | `service/WmsConstants.java` | chunk-size key/default `"40"`; `BOL_SHIPPED_CHUNK_AGGREGATE_TYPE`; `MessageProcessType.ORDER_BATCH_SHIPPED_REQUEUE` |
| api | `service/OutboxService.java` | +`linkServiceLog` (REQUIRES_NEW) |
| api | `service/job/OutboxDispatchService.java` | `maxAttemptsFor`; guarded link after service log; `writeServiceLog` returns id |
| api | `repo/jpa/OutboxMessageRepository.java` | +`linkServiceLog`, `findBolNotificationRows` (plain read), `requeueBolTerminal` (guarded `UPDATE … WHERE status='FAILED_TERMINAL' RETURNING id`) (all native) |
| api | `service/MessageService.java` | +`createServiceLogInCallerTx` (MANDATORY) |
| api | `service/BolOmsNotificationService.java` | **new** |
| api | `schedulejob/RestIdempotencyCleanupJob.java` | expose `safeOutboxRetentionDays` via a shared helper |
| api | `controller/BillOfLadingController.java` | +2 handlers; requeue maps `PessimisticLockingFailureException` → 409 ProblemDetail outside the service tx |
| api | `resources/application.properties` (`:244`) | +`bol-shipped-max-attempts=29` |
| api | `db/migration/V2.2.40__bol_shipped_chunk_size_and_outbox_message_link.sql` | `SET LOCAL lock_timeout` + explanatory comment citing `V2.2.26:114`; seed (shape of `V2.2.29:37-50`); `ADD COLUMN` |
| api (test) | `integration/OmsEgressWatchdogQueryIT.java` | +1 case: requeue audit rows yield zero findings |
| api (test) | `integration/MessageServiceCallerTxIT.java` | **new**: I10, MANDATORY behaviour |
| ui | `components/outbound/bol/outboundBolDetails.vue` | status row, failed list, requeue button |
| ui | `store/outbound/outboundBols.js` | `getBolOmsStatus`, `requeueBolOms` |
| ui | `components/admin/serviceLog/serviceLog.vue` | `?messageId` deep link |
| docs | `wms2-bol-truck-loading-workflow.md:44,114,313-329`, `wms2-oms-integration-map.md:112` + retry row, `wms2-sysprop-catalog.md`, `wms2-scheduled-jobs-catalog.md` (29 attempts), `wms2-entity-enumeration-report.md` (new column, native-only), SBDEV-3325 watchdog README (`WATCHDOG_ACK` for a 24 h poisoned row, A-L8; note that requeue audit rows use destination `'N/A'` and are excluded by design) | describe chunking, retry budget, link |

## §7 Implementation steps

### Prerequisites

| # | Prerequisite | Required value / action |
|---|---|---|
| 1 | DB state | PRD is at **V2.2.38** (installed 2026-10-16 11:05 UTC; checked on c1wh-ShipItEZ and WineCo PRD 2026-10-16, all four per review-api-code). V2.2.39 (SBDEV-3659, `delete_retired_lane_exclusion_sysprop`) is on develop, unreleased; it must be applied, or ship in the same release ahead of V2.2.40. Re-sweep all remote branches for V2.2.40 before push (memory: *flyway-version-pick-sweep-all-remote-branches*). |
| 2 | Sysprops | `WMS_BOL_SHIPPED_OMS_CHUNK_SIZE=40` seeded by V2.2.40; fallback 40, ceiling 60. Hydra has zero BOLs > 40. |
| 3 | Config | `app.outbox.dispatcher.bol-shipped-max-attempts=29`; no env override. |
| 4 | Deploy order | **wms2-api first** (a merge to develop deploys and runs Flyway), then wms2-web-ui. UI hides the row on 404, so the reverse order degrades gracefully. |
| 5 | **Release gate R-1 (merchant callbacks)** | **Owner: Nam.** On each OMS v2 tenant DB serving a wms2 PRD warehouse: `SELECT client_id, debug FROM outbound_api WHERE call_name='outbound_bol_close' AND client_id IS NOT NULL AND isactive=1;` (`ClientCallbackService::endpoints:46-63`). **Go** if no production rows. **No-go** for the PRD release if any client has one, until that merchant acknowledges partial per-chunk callbacks or OMS debounces. Record the result and decision on the ticket before the PRD release. NOOP parcels are excluded from callbacks (`LWC:2434-2435`), so requeues/replays never duplicate a callback for an already-shipped parcel. |
| 6 | External systems | OMS: no change; it ignores extra keys and skips already-shipped parcels (`LWC:2313-2319,2426-2432`). Open (A-L7): can a late PACKED/LOADED (DEFAULT lane) regress a SHIPPED parcel (CLUB lane) at OMS? Ask before PRD. |
| 7 | Access | No new function. Endpoints use `WEB_UI_VIEW_BILL_OF_LADING`; the Service Log link needs `WEB_UI_VIEW_MESSAGES`. |
| 8 | Monitoring | Metrics are not scraped (memory). Interim signals are DB queries: §9 pre-mortem detection rows. |
| 9 | Oversized rows at deploy (A-L8/C-L8) | Any oversized single `BILL_OF_LADING` row (parcels > K) still `FAILED_RETRY` or `FAILED_TERMINAL` at deploy is **not** re-chunked (D10): it keeps timing out hourly for 24 h, and a requeue sends it whole again. PRD census 2026-10-13: none outside 11135 (c1wh, WineCo, Hydra, nywh-ShipItEZ), and 11135 is closed by Step 7. **Re-run the census the day of release**; any new hit → "Known limitation: legacy oversized row" recipe below. |

### Steps

1. **API, chunker + producer (Fix A).** Worktree `.claude/worktrees/wms2-api/SBDEV-3672`, branch `fix/SBDEV-3672-chunk-bol-shipped`. Failing tests first (§8 U1–U9). **AC-A:** ≤K → exactly one row whose payload is byte-equal to the fixture; >K → ⌈n/K⌉ rows with the ids/keys/lane above; transfer >K → 1 row.
2. **API, V2.2.40 + native link + retry budget (Fixes B-1, C).** **AC-C:** an `ORDER_BATCH_SHIPPED` row goes terminal only at attempts 29; `CUSTOMER_ORDER` still at 5. **AC-B1:** `OutboxMessage` maps no `last_message_id`; a link failure changes no outcome.
3. **API, status + requeue + audit (Fixes B-2..4, D).** **AC-B:** counts correct before and after a SENT purge and after a successful manual resend. **AC-D:** requeue flips only this BOL's `FAILED_TERMINAL` rows (not `resendConfirmed` ones) to `FAILED_RETRY`, attempts 0, current URL, keys unchanged; two concurrent requeues yield one REQUEUE and one NONE, exactly one audit row, no 500. **AC-D2:** a lock timeout is a 409 ProblemDetail; the audit row is invisible to the egress watchdog and refused by `resendMessage`; an audit row written inside a caller tx that rolls back does not survive (MANDATORY). Before merge, run the `EXPLAIN ANALYZE` from Fix B-2 on **c1wh-ShipItEZ PRD and WineCo PRD** and record both timings on the ticket (C-m7).
4. **API close-out.** `mvn clean verify` vs the suite baseline; mutation-check every new assertion (§8 targets); 4 review lanes (T3), fix every finding incl. Low; PR into develop.
5. **UI.** Worktree `.claude/worktrees/wms2-web-ui/SBDEV-3672` off fresh `origin/develop`. Jest first (J1–J5); `yarn test` vs baseline; PR into develop **after** the API PR merges.
6. **Post-deploy schema gate (C-H2, C-m1).** After each environment's API deploy, derive that environment's tenant DB list from its landlord, `SELECT * FROM tenant_db_configuration;` (via `landlord-{dev,uat,prd}`). Do not use a remembered count: PRD has **4** rows today, all at V2.2.38 (2026-10-16). On **every** listed DB run `SELECT version, success FROM flyway_schema_history WHERE version='2.2.40' AND script LIKE '%bol_shipped_chunk_size%';` **and** confirm the effect directly, since a version number alone is what went stale once already (security review M1, 2026-10-16): `SELECT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name='outbox_message' AND column_name='last_message_id') AS col, EXISTS (SELECT 1 FROM los_sysprop WHERE syskey='WMS_BOL_SHIPPED_OMS_CHUNK_SIZE' AND workstation='DEFAULT') AS seed;` — both must be `t`. Any missing/failed → fix (usually ownership drift), restart to re-run; dispatch is unaffected meanwhile (P-5). Deploy is not done until all report `success=t`.
7. **One-off post-deploy: close outbox 11135 (owner Nam, c1wh-shipitez PRD only).** Right after the PRD API deploy, run the statement in "Runbook: outbox 11135 close-out" below; expect exactly 1 row. Do **not** Requeue BOL 121932106.
8. **Docs.** Update the §6 docs row; run `verify-docs`.

### Rollback

Revert the wms2-api image. V2.2.40 is additive (nullable column + one sysprop) and harmless to old code, which maps no such column. Chunk rows already enqueued are dispatched by the old CLUB consumer (generic `dispatchBatch`) under the old 5-attempt budget. Revert the UI independently. No down-migration.

**Under the old image, a `FAILED_TERMINAL` chunk row has no requeue path** (no endpoint, no UI). Its Service Log rows can still be resent one attempt at a time. The manual recovery, Nam-run, per tenant:

```sql
UPDATE outbox_message SET status='FAILED_RETRY', attempts=0, next_attempt_at=now(), modified_at=now()
 WHERE aggregate_type='BILL_OF_LADING_CHUNK' AND aggregate_id BETWEEN :bolId*100000 AND :bolId*100000+99999
   AND status='FAILED_TERMINAL';
```

The old dispatcher then retries those rows under the 5-attempt budget.

### Runbook: outbox 11135 close-out (owner Nam)

> **RESOLVED 2026-10-13 (Nam):** BOL 101226(5) was fixed manually on the OMS side. No OMS replay is needed or allowed for it. Outbox row 11135 (c1wh PRD) is still `FAILED_TERMINAL` in WMS (checked 2026-10-13, attempts 5, modified 2026-10-12 23:57:42 UTC). After deploy it would show as "1 legacy notification (1,528 parcels)", failed, on BOL 121932106. **Do not Requeue it**: D-ii is dropped (D10), so a requeue would POST the whole 664 KB payload again and time out.

**One-off, post-deploy (Step 7).** On **c1wh-shipitez PRD only**, right after the API deploy:

```sql
UPDATE outbox_message
   SET status='SENT', sent_at=now(),
       last_error='resolved manually in OMS 2026-10-13 (SBDEV-3672)'
 WHERE id=11135 AND status='FAILED_TERMINAL';
```

- **Expect exactly 1 row.** 0 rows → someone already changed it: `SELECT id, status, attempts, sent_at, last_error FROM outbox_message WHERE id=11135;` and record the result on the ticket; do not re-run blindly.
- **Effect.** BOL 121932106's status reads `CONFIRMED` (1/1). The row is deleted by normal SENT retention (`deleteSentOlderThan`, `OMR:84-86`) `retentionDays` after `sent_at`; after that the BOL reads `NO_RECORD`/`PURGED`.
- **Record** the rowcount and run time on the ticket.

### Known limitation: legacy oversized row (manual recipe, owner Nam)

Requeue (D-i) sends a single `BILL_OF_LADING` row **whole**. A row with parcels > K written before deploy (none on PRD after Step 7; Prereq 9 re-checks on release day) will keep timing out. If one appears, do not Requeue it; use this recipe, the sliced replay from the pre-drop runbook generalised to `:id`:

- **Before snapshot.** Extract the `unique_id`s from `SELECT payload FROM outbox_message WHERE id=:id` into the session scratchpad. On the tenant's OMS DB: `SELECT parcel_status, count(*) FROM parcel WHERE parcel_id IN (<numeric unique_ids>) OR parcel_id_str IN (<unique_ids as strings>) GROUP BY 1;` Save the result on the ticket. The query mirrors `finishedShipping`'s resolution on OMS `origin/develop`: numeric `parcel_id` first (`LWC:2287`), then the `parcel_id_str` fallback (`LWC:2291`); an unresolved id is logged "Parcel not found" (`LWC:2295`). Check that the count of matched rows equals the parcel count, so that no id matches both columns or neither (C-M8).
- **Sliced replay (Nam-run).** Slice the payload with `jq` into ≤K-parcel bodies (full header, straddling pallet copied, same `bol_id`), and POST them **sequentially** to the `WEBSERVICE_ORDER_BATCH_SHIPPED` URL with the OMS credential WMS uses (never pasted into the ticket). Stop on the first non-2xx. Check R-1 (Prereq 5) first, since each call can fire one merchant callback for its SUCCESS parcels. OMS NOOPs parcels already shipped.
- **After snapshot.** Re-run the OMS query. **Expected:** every parcel in a shipped status, i.e. SUCCESS (non-shipped before) + NOOP (shipped before) = parcel count.
- **Close the WMS row** with the Step 7 statement shape (`id=:id`, `last_error` naming the date and ticket); expect 1 row.

## §8 Testing plan

**Unit (wms2-api)**

| # | Class#method | Asserts |
|---|---|---|
| U1 | `BolShippedNotificationChunkerUnitTest#splitsEveryKParcelsKeepingItemsWithTheirParcel` | 95 at K=40 → 40/40/15; each parcel once, in order |
| U2 | `…#straddlingPalletIsCopiedWithSameLabel` / `#neverEmitsEmptyPalletOnlyChunk` / `#slicesAreCopiesNotViews` / `#singlePalletOf1528Gives39Chunks` | split rule |
| U3 | `…#everyChunkCarriesFullHeaderSameBolIdAndZeroBasedChunkIndex` | header equal; `chunk_index` 0..N−1, `chunk_count` N |
| U4 | `BillofladingServiceUnitTest#closeBol_atOrBelowK_payloadIsByteEqualToTodaysFixture` | type, id, UUID key, DEFAULT lane; payload byte-equal to a fixture captured from the a4fd6490 serializer (extends `:3046-3070`) |
| U5 | `…#closeBol_aboveK_enqueuesChunkRowsWithKeysUnder64` | `BILL_OF_LADING_CHUNK`, ids `bolId×100000+i`, keys `…-C<i>of<N>`, lane CLUB |
| U6 | `…#hubAndSpokeAboveK_isChunked` / `#transferOffsiteAndIntracompanyAboveK_stayOneRow` | type filter |
| U7 | `…#anyChunkSerializeFailure_enqueuesNothingAndThrows` | extends `:3122-3127` |
| U8 | `…#chunkSize_missingOrBlank_40NoWarn` / `#garbageOrZero_40WithWarn` / `#above60_clampsTo60WithWarn` | resolver + WARN presence/absence (ListAppender) |
| U9 | `BolShippedOmsChunkSizeSeedConsistencyTest#seedMatchesConstant` | mirrors `ClublineOmsChunkSizeSeedConsistencyTest` |
| U10 | `OutboxDispatchServiceUnitTest#bolShippedChunkRow_retriesUntil29` / `#bolShippedSingleRow_retriesUntil29` / `#otherProcessType_terminalAt5` / `#bolShipped400_terminalImmediately` | Fix C, both branches (`:181`, `:193`) |
| U11 | `OutboxDispatchServiceUnitTest#bolShippedRow_linksServiceLogId` / `#linkFailureIn2xxBranch_neverCallsMarkRetryOrMarkTerminal` / `#otherProcessTypes_notLinked` | Fix B-1; failure injected in the **2xx** branch (A-L3) |
| U12 | `BolOmsNotificationServiceUnitTest#confirmedCountsPurgedSentRows` / `#resendConfirmedCountsAsConfirmed` / `#failedBeatsPending` / `#noRows_emptyBol_vs_purged_vs_unknown` / `#purged_onlyBeyondRetentionPlusOneDay_boundaryIsUnknown` / `#emptyBol_matchesRunShippingPhaseTopLevelClassification` / `#openBol_isNotShipped` / `#legacyOversizedRow_isLabelledLegacy` / `#statusIsReadOnlyTenantTx` / `#requeueIsReadWriteTenantTx`; `MessageServiceUnitTest#createServiceLogInCallerTxIsMandatory` | status math, precedence, NO_RECORD reasons incl. the A-N5 boundary (shipped = today − retention − 1 → `UNKNOWN`; − 2 → `PURGED`); the last three assert `@Transactional` value **and** `propagation` by reflection (C-L2, A-N3/C-N1) |
| U13 | `BolOmsNotificationServiceUnitTest#requeue_inFlightOnly_returnsNoneWithReason` / `#resendConfirmedRows_areNotRequeued` / `#legacyOversizedRow_isRequeuedWhole_notRechunked` / `#transfer_isPlainRequeue` / `#requeueUsesCurrentShippedUrl` / `#requeueUpdateTouchesOnlyFailedTerminalRows` / `#concurrentLoser_zeroRowsReturned_isNoneWithoutAuditOrCounter` / `#auditRow_namesReturnedIds` / `#auditRow_destinationNA_codeREQUEUE_senderNotInstance` / `#auditRow_isNotResendable` | eligibility and NONE reasons, A-L4, A-L6 (a legacy row yields one requeued row and no enqueue); A-N4 lock scope (the UPDATE's native SQL contains `status='FAILED_TERMINAL'`); the concurrent-loser branch (mock `requeueBolTerminal` → empty list ⇒ `NONE`, `createServiceLogInCallerTx` never called, counter not incremented); audit `outboxIds` = the returned ids, not the read's ids; audit fields; `MS.resendMessage` on the audit row throws (`MS:163`) |
| U14 | `BillOfLadingControllerUnitTest#requeue_isPost` / `#lockTimeout_maps409` / `#nothingEligible_is200None` | verb + error shape. `#lockTimeout_maps409` makes the **service mock throw** `CannotAcquireLockException` and asserts 409 + ProblemDetail body (A-N2, C-m2). The `DataIntegrityViolationException` / `OutboxRequeueConflictException` cases are gone with D-ii (D10) |
| U15 | `OutboxMessageMappingUnitTest#entityDoesNotMapLastMessageId` | reflection over fields/`@Column` names (C-H2 pin) |
| G1 | `Sbdev3017TrancheGateContextTest` (`:110-117`, `:533-535`) + two `row(...)` | `(BillOfLadingController, /v3/billOfLading/omsNotificationStatus/{id}) → WEB_UI_VIEW_BILL_OF_LADING` and the requeue path; full context, also covers `/v3` (C-L1) |

**Integration (Testcontainers PG, failsafe `*IT`, Flyway via `OutboxItFlyway.migrateProduction`; assert by id — repository tests commit)**

| # | Class#method | Asserts |
|---|---|---|
| I1 | `BolChunkOutboxClaimIT#terminalChunkDoesNotHoldSiblings` | one chunk terminal; `findAndClaimPending(…,"CLUB")` claims the rest |
| I2 | `…#defaultLaneNeverClaimsChunkRows` | lane isolation |
| I3 | `BolOmsNotificationRowsIT#findsBothShapesOnlyForThisBol` | neighbours `bolId±1` and a `CLUB_BATCH_CHUNK` with the same numeric id excluded |
| I4 | `…#requeueFlipsOnlyTerminalRowsKeepsKeysAndWritesOneAuditRow` | statuses, attempts=0, keys unchanged, destination = current sysprop; second call `NONE`; one `ORDER_BATCH_SHIPPED_REQUEUE` message row with the answer JSON fields, operatorId, **`destination='N/A'`, `statuscodeanswer='REQUEUE'`, `sender='wms:requeue'`** (A-N1/C-N2) |
| I4b | `…#requeueUpdate_skipsRowsNoLongerTerminal` | calls `OMR.requeueBolTerminal` directly with the ids of an `IN_FLIGHT`, a `FAILED_RETRY` and a `SENT` row of the BOL → returns no ids, all three rows unchanged (status, attempts, `next_attempt_at`, `destination_url`). This is the deterministic version of the concurrent loser's re-evaluation, and the only test that reaches the UPDATE's `status='FAILED_TERMINAL'` guard (the service's plain read filters first) |
| I5 | `…#lastMessageIdLeftJoinReportsPurgedMessage` / `#resendWith2xxRedeliverIdReconciles` / `#resendWith5xxDoesNot` / `#resendOfEarlierAttemptIsNotReconciled` | `messagePresent=false`; A-M3/C-M2 both ways; the R-9 gap is pinned as documented behaviour |
| I6 | *(removed with D-ii, D10: the re-chunk atomicity test has no code path left)* | — |
| I10 | `MessageServiceCallerTxIT#auditRowRollsBackWithCallerTx` / `#withoutCallerTx_throwsIllegalTransactionState` | **Replaces the D-ii-based I10** (which relied on `deleteTerminalById` → 0). D-i has no natural failure after the audit write, and spying a `@Transactional` bean to inject one is a known trap, so I10 tests MANDATORY **directly, without a requeue**: (1) inside a `TransactionTemplate` on `tenantTransactionManager`, call `MS.createServiceLogInCallerTx(...)`, then `setRollbackOnly()` → **zero** `ORDER_BATCH_SHIPPED_REQUEUE` rows afterwards (under REQUIRES_NEW the row commits on its own and survives); (2) call it with no tx → `IllegalTransactionStateException` (REQUIRES_NEW or REQUIRED would succeed). Assert by id/process, not by rollback (memory *wms2-repository-tests-commit-they-do-not-roll-back*). Sibling of `ServiceLogPropagationIT` |
| I7 | `…#concurrentRequeue_oneRequeuesOtherReturnsNone` | two threads + latch on a 3-chunk fixture with all chunks `FAILED_TERMINAL`: exactly one `REQUEUE` and one `NONE`, no exception, every chunk `FAILED_RETRY` with attempts 0, **exactly one** audit row (memory: *wms2-concurrency-it-fixture-traps*, *wms2-pg-it-lane-has-no-tenant-pool*). Outcome-only: the latch cannot force the loser onto the blocked-then-0-rows path rather than the read-sees-nothing path, so the 0-rows branch is pinned deterministically by U13 `#concurrentLoser_…` and I4b. The winner's tx is short, so this fixture never exercises the 3 s lock timeout; that path is U14 `#lockTimeout_maps409` (A-N2) |
| I8 | `…#linkUpdateLeavesVersionAndModifiedAtUnchanged` | A-L2 |
| I9 | `OutboxMigrationV2240IT#addsNullableColumnAndSeedIsIdempotent` | column null for old rows; the seed SQL executed **twice by hand** inserts one sysprop |
| I11 | `OmsEgressWatchdogQueryIT#requeueAuditRows_yieldZeroFindings` | three audit rows as Fix D-3 writes them, inside the lookback → no `failing`/`misrouted` row for `ORDER_BATCH_SHIPPED_REQUEUE`. Positive control in the same case: the same three rows with a URL destination **do** produce `failing` (A-N1/C-N2; memory *a-zero-scan-needs-a-positive-control*) |

**Regression (unchanged, must stay green):** `FinishTransferPreTransferCloseIT:185-190`, `BillofladingServiceFinishTransferIT:170-187` (seed the chunk sysprop), `BillofladingServiceUnitTest` `never().enqueue` cases (`:395,410,468,1864-1995,3127,3502`) and `:1783 times(2)`, `OutboxLaneClaimIT`, `OutboxTerminalHoldIT`, `OutboxStuckAggregateIntegrationTest`, `ServiceLogPropagationIT`, `SelfInvokedTransactionalArchTest`.

**Observability (asserted, not just emitted)**

| # | Where | Asserts |
|---|---|---|
| O1 | U13 + I4/I7 with `SimpleMeterRegistry` | `wms2.outbox.requeued{aggregate_type=BILL_OF_LADING_CHUNK,mode=REQUEUE}` and `{aggregate_type=BILL_OF_LADING,mode=REQUEUE}` increment by **exactly 1 per successful call**, whatever the row count (C-m6); `NONE` (incl. the 0-rows loser, I7 total = 1) and 409 do not increment; no null tags. The row count is asserted on the INFO line's `rows` field (O3) |
| O2 | U11 | `wms2.outbox.service_log_link.failed{process_type=ORDER_BATCH_SHIPPED}` increments on link failure |
| O3 | U13 (ListAppender) | INFO requeue line carries user, bolId, mode, rows |
| O4 | I4 + I11 | the audit message row (process `ORDER_BATCH_SHIPPED_REQUEUE`, destination `'N/A'`, statuscodeanswer `'REQUEUE'`, sender `wms:requeue`, answer JSON) and its invisibility to the egress watchdog |

**Jest (wms2-web-ui)**

| # | Spec | Asserts |
|---|---|---|
| J1 | `test/components/outbound/outboundBolOmsStatus.spec.js` | "38/39 delivered · 1 failed"; legacy text; "delivered via manual resend"; `NO_RECORD` text per reason; `NOT_SHIPPED` and 404 hide the row |
| J2 | same | Requeue only when `failed>0`; confirm dispatches `requeueBolOms`, re-fetches, shows `reason` on NONE |
| J3 | same | Service Log link only with `WEB_UI_VIEW_MESSAGES` **and** `messagePresent`; click commits `setParentTab` 6 and pushes `/admin?messageId=…` |
| J4 | `test/components/admin/serviceLogDeepLink.spec.js` | numeric `messageId` → `getLogDetail(id)`; non-numeric ignored |
| J5 | `test/store/outboundBolsOmsStatus.spec.js` | GET/POST paths relative to the `/v3` baseURL |

**E2E — manual only (declared).** No browser harness runs in CI for wms2-web-ui. Run on wms2 dev against dev OMS; never with PRD data.

| Scenario | Setup | Steps | Expected |
|---|---|---|---|
| Chunking | Admin › System Properties: set `WMS_BOL_SHIPPED_OMS_CHUNK_SIZE=2` (the admin edit evicts the `sysprops` cache) | Close a REGULAR BOL with 5 parcels | 3 chunk rows (C0of3..C2of3) on CLUB, all SENT; screen "3/3 delivered" |
| ≤K | chunk size 40 | Close a 3-parcel BOL | 1 `BILL_OF_LADING` row on DEFAULT; "1/1 delivered" |
| OMS down | Record the current `WEBSERVICE_ORDER_BATCH_SHIPPED` value; set it to `http://127.0.0.1:9/` via the admin UI (evicts cache) | Close a 5-parcel BOL at K=2 | rows `FAILED_RETRY`, growing `next_attempt_at`; screen "pending" |
| Requeue | **First**, while the URL is still broken, force: `UPDATE outbox_message SET status='FAILED_TERMINAL', attempts=29 WHERE id=:id AND status='FAILED_RETRY';` and confirm rowcount 1. **Then** restore the URL via admin UI. Doing it in this order means the dispatcher cannot deliver the row between the restore and the UPDATE (C-m8) | Click Requeue | `FAILED_RETRY` → SENT to the **restored** URL; key unchanged; one audit row with destination `N/A`, code `REQUEUE`; that row's Service Log "Resend" is refused |
| Double click | as Requeue, fresh BOL at K=2 (3 chunk rows forced `FAILED_TERMINAL`) | Click Requeue twice fast | one REQUEUE, one audit row; the second shows "nothing failed" (or, if it waited > 3 s on the lock, the 409 "another requeue is in progress" text); never an error toast or 500 |
| Service Log link | a failed chunk with `messagePresent` | click link | Admin › Service Log opens that message |
| Transfer | — | Close a TRANSFER_OFFSITE BOL with > K parcels | 1 `BILL_OF_LADING` row |
| Restore | — | reset chunk size to 40 and the URL to the recorded value | — |

**Mutation targets.** Each target must turn the named test red. Every test named here reaches the mutated line; reachability was rechecked in round 2 (C-N1) and again after the D-ii drop (2026-10-13).

| Target | Killing test |
|---|---|
| K clamp at 60 | U8 |
| `maxAttemptsFor` type check | U10 |
| setting `chunk_*` on the ≤K path | U4 byte fixture. This replaces the unkillable `NON_NULL` annotation target, C-M1 |
| D-i UPDATE without `status='FAILED_TERMINAL'` | I4b (runtime: non-terminal rows would flip) + U13 `#requeueUpdateTouchesOnlyFailedTerminalRows` (SQL text). Re-pointed from I4, whose second call returns `NONE` at the plain read and never reaches the UPDATE |
| `resendConfirmed` rows not excluded from the eligible ids | U13 `#resendConfirmedRows_areNotRequeued` |
| audit row written when the UPDATE returned 0 ids | U13 `#concurrentLoser_zeroRowsReturned_isNoneWithoutAuditOrCounter` (I7's one-audit-row assert also catches it whenever the loser takes the blocked path) |
| `createServiceLogInCallerTx` MANDATORY → REQUIRES_NEW | U12 `#createServiceLogInCallerTxIsMandatory` (reflection) + I10 `#auditRowRollsBackWithCallerTx` (the row would survive the rollback). I10 no longer depends on a D-ii failure |
| `createServiceLogInCallerTx` MANDATORY → REQUIRED | U12 (reflection) + I10 `#withoutCallerTx_throwsIllegalTransactionState` (REQUIRED would open its own tx and succeed) |
| audit `destination` changed from `'N/A'` | I4 + I11 |
| audit `sender` set to the instance name | U13 `#auditRow_isNotResendable` |
| controller 409 mapping removed | U14 `#lockTimeout_maps409` |
| `resendConfirmed` `^2` regex | I5 |
| `PURGED` +1 day removed | U12 `#purged_onlyBeyondRetentionPlusOneDay_boundaryIsUnknown` |
| entity field added | U15 |
| link outside its own try | U11 |

I7 is **not** listed as the killer of the 0-rows target: its latch cannot force the loser onto the blocked path, so it would pass on runs where the loser's read already sees nothing.

**Deliberately skipped coverage:** browser e2e in CI (no harness); OMS-side behaviour (other repo; covered by NOOP/skip citations); CLUB-lane load test (arithmetic in R-3 instead); a proactive alert for a BOL notice terminal after 24 h — **accepted gap**, interim detection is the daily query in pre-mortem 3 / Follow-ups.

## §9 Risks, pre-mortem and mitigations

| # | Risk | Mitigation |
|---|---|---|
| R-1 | Merchant `outbound_bol_close` fires once per chunk (`LWC:2523`) | **Release gate**, Prereq 5 (owner Nam, query, go/no-go). NOOP parcels excluded from callbacks (`LWC:2434-2435`). |
| R-2 | Partial visibility | Fix B/C/D; per-chunk resend and requeue. |
| R-3 | **CLUB lane occupancy, cross-tenant.** Healthy: 39 × 7.6 s ≈ 5 min. OMS hung: each POST costs up to 20 s; a tick claims 25 rows per tenant → 500 s per tenant per tick, and `ODJ:136-139` runs tenants **sequentially** in one advisory-locked tick, so a 39-chunk wave holds ~13 min and recurs ~hourly for 24 h (Fix C), delaying every other tenant's club notices. | Accepted for now (club and BOL are both bulk; DEFAULT lane untouched). **Fallback trigger:** `tick_duration{lane=CLUB}` p95 > 300 s once scraped, or (today) any due CLUB row older than 15 min: `SELECT count(*) FROM outbox_message WHERE lane='CLUB' AND status IN ('PENDING','FAILED_RETRY') AND next_attempt_at < now() - interval '15 minutes';` on any tenant → ship a per-type claim cap (≤5 chunk rows per tenant per tick) or a dedicated lane (D7 fallback). |
| R-4 | Chunk replay order | OMS order-independent; skips shipped parcels, NOOP = success. |
| R-5 | K changes mid-close | Read once per close. |
| R-6 | **Legacy oversized single row requeued whole** (replaces the D-ii DELETE risk, which is gone with D10). An operator requeues a pre-deploy `BILL_OF_LADING` row with parcels > K; it times out hourly for 24 h again | None on PRD after Step 7 closes 11135; Prereq 9 release-day census; the UI labels it "legacy notification (N parcels)"; runbook "Known limitation" recipe (sliced manual replay, then close the WMS row). Accepted: the population is zero at release and only shrinks, since every post-deploy BOL > K is chunked. | If OMS per-parcel cost rises so that 60 parcels no longer clears the 15 s read timeout, revisit `CHUNK_SIZE_CEILING`: it governs both the K clamp and the legacy label.
| R-7 | Service Log growth: ≤30 rows per failing chunk (~1,170 for a 39-chunk BOL over 24 h) | Bounded by message retention (`MessageRepository:99-102`). |
| R-8 | Extra UPDATE per BOL-shipped dispatch | Native, one row, best-effort. |
| R-9 | Status drift vs system of record | A successful resend **of the latest linked message** is reconciled (A-M3/C-M2). Two accepted gaps, documented in the UI tooltip and `wms2-bol-truck-loading-workflow.md` (A-(b), C-m4): **(1)** a Service Log resend of an *earlier* attempt's row is **not** reconciled, because only `redeliver_id = last_message_id` counts; **(2)** if the final attempt's link failed (`service_log_link.failed`), `last_message_id` still points at the *previous* attempt, so a resend of the truly latest row is not reconciled either. Both leave the chunk reading `failed`, which is safe in the conservative direction; the operator can requeue (OMS NOOPs shipped parcels). A manual operator DELETE of a terminal row reads as confirmed; this is documented, not defended. |
| R-10 | Watchdog red ~24 h for one poisoned row on a low-traffic tenant (A-L8) | Document `WATCHDOG_ACK` in the SBDEV-3325 watchdog README. |

**Pre-mortem** (it is 2 weeks after release and this went wrong — why?)

| # | Scenario | Detection | Mitigation |
|---|---|---|---|
| 1 | **V2.2.40 failed on one tenant** (ownership drift, or the 5 s lock_timeout hit behind a long close tx during rolling boot) | Step 6 `flyway_schema_history` gate; `StartupFlywayMigrator` ERROR; status endpoint 500 on that tenant only; `service_log_link.failed` rising | Native-only column means pick/pack/close/dispatch keep working (P-5, U15). Fix ownership, restart to re-run. Missing seed → resolver falls back to 40. |
| 2 | **Merchant callback multiplication** — a merchant's integration double-books on partial `outbound_bol_close` callbacks | Prereq 5 query before release; merchant complaint after | No-go rule in Prereq 5; OMS debounce as follow-up; requeue never duplicates (NOOP excluded). |
| 3 | **CLUB lane starvation during an OMS outage** — club notices for every tenant lag for hours | R-3 DB query (due CLUB rows > 15 min); later `tick_duration{lane=CLUB}`. Daily: `SELECT id, aggregate_id FROM outbox_message WHERE process_type='ORDER_BATCH_SHIPPED' AND status='FAILED_TERMINAL';` per tenant | R-3 fallback (claim cap / dedicated lane); requeue after OMS recovers. |
| 4 | **A legacy oversized row is requeued and times out for another 24 h** (replaces the dropped D-ii race scenario, D10) — e.g. a pre-deploy row the release-day census missed | Pre-mortem 3's daily `FAILED_TERMINAL` query; the BOL screen's "legacy notification" label; `EX` Service Log rows with ~664 KB-class payloads | Prereq 9 census; Step 7 closes the only known row; runbook "Known limitation" recipe. OMS NOOPs already-shipped parcels, so a partial server-side run before each timeout does no harm. |
| 5 | **Watchdog false red from requeue audit rows.** Three requeues in a lookback window would put `ORDER_BATCH_SHIPPED_REQUEUE` in `failing` (A-N1/C-N2). **Now prevented** by design | `OmsEgressWatchdogQueryIT#requeueAuditRows_yieldZeroFindings` (I11) in CI, with its positive control; on PRD a watchdog finding naming that process | Audit row destination `'N/A'` (the watchdog's own exclusion, `egress-failures.sql:90-91`). If a future watchdog edit drops the `'N/A'` exclusion, I11 goes red. |
| 6 | **Requeue/dispatcher lock interplay.** A requeue UPDATE that matched an `IN_FLIGHT` row would make the dispatcher's `markSent` (REQUIRES_NEW) hit the 3 s `lock_timeout`, so the row would be reclaimed after 15 min and re-POSTed (A-N4). Separately, a concurrent requeue loser that waits more than 3 s would get a 500 (A-N2) | U13 `#requeueUpdateTouchesOnlyFailedTerminalRows`; I4b; U14 `#lockTimeout_maps409`; on PRD an `OMS NOOP` re-POST of a chunk shortly after a requeue, or a `CannotAcquireLockException` in the logs | The guarded UPDATE matches only `FAILED_TERMINAL` rows (the dispatcher never touches them), and PG locks only matching rows; controller maps lock failures to 409. A residual duplicate POST is harmless, because OMS NOOPs parcels it has already shipped. |

## Horizontal Scalability Validation

| Concern | Affected? | Evidence |
|---|---|---|
| In-JVM state | No | Chunker pure; K from the tenant-keyed Caffeine sysprop cache (`SyspropService:106`), read once per close. |
| Pool math | No | No new long tx. Link is one short REQUIRES_NEW UPDATE in Phase 2; no tx across HTTP (`ODS:152-157`). |
| Scheduled jobs | Yes, existing CLUB lane | `ODJ:83-86` advisory lock `OUTBOX_DISPATCHER_CLUB`, one replica per tick. **Tenants dispatched sequentially within the tick (`ODJ:136-139`) — outage cost is cross-tenant (R-3).** No new job. |
| Long tx | No | Close tx gains N inserts (39 for 1,528 parcels), fewer bytes than one 664 KB row. Requeue: one guarded UPDATE over the BOL's terminal rows plus one audit INSERT. |
| Request affinity | No | Stateless endpoints. |
| Retry / idempotency | Yes | Deterministic chunk keys; requeue preserves keys; OMS skips shipped parcels; stale reclaim lane-scoped (`OS:125-135`). |
| Tenant context | No | `TenantFilter` for HTTP; dispatcher per tenant (`ODJ:138`). |
| Distributed locks | Yes (implicit row lock) | No `SELECT … FOR UPDATE`. The D-i UPDATE's own row locks plus its `status='FAILED_TERMINAL'` guard serialize concurrent clicks across replicas: the loser re-evaluates after the winner commits, updates 0 rows and returns `NONE` (I7, I4b, U13). |
| Cache invalidation | No | New sysprop via existing `sysprops` cache; admin edit evicts. |
| External notifications | Yes | N POSTs per BOL; R-1 gate. Each POST ≤ 5 + 15 s; `STALE_INFLIGHT` holds (500 s < 900 s). |

## v2 constraint checklist

| Constraint | Status |
|---|---|
| OSIV | `open-in-view=false` (`application.properties:85`); status returns DTOs built in its readOnly tx. |
| `tenantTransactionManager` | Every new `@Transactional` names it. |
| readOnly / propagation | `status()` readOnly; `requeue()` read-write; `createServiceLogInCallerTx` MANDATORY. Pinned by U12 `#statusIsReadOnlyTenantTx`/`#requeueIsReadWriteTenantTx`/`#createServiceLogInCallerTxIsMandatory` (reflection) and I10 (an audit row written in a caller tx that rolls back does not survive; no caller tx → `IllegalTransactionStateException`). |
| Caffeine eviction | No new cache. |
| jakarta | No new entity field. |
| H2 SQL | New native queries are PG-only, tested in Testcontainers ITs. H2 lane unaffected (no entity change). |
| BaseControllerTest | Does not exist; use `BillOfLadingControllerUnitTest` / `BaseControllerUnitTest`. Gate pinned in `Sbdev3017TrancheGateContextTest` (G1). |
| Micrometer | New `wms2.outbox.requeued{aggregate_type,mode}`, `wms2.outbox.service_log_link.failed{process_type}`; no null tags. |

## Completeness checklist

| # | Item | Status |
|---|---|---|
| 0 | Affected sites by grep (§0) | done |
| 1 | DB query confirming the symptom | done: analysis §8 (11135); 2026-10-13 census — 1 `BILL_OF_LADING` `FAILED_TERMINAL` row (c1wh, 11135, resolved in OMS 2026-10-13, closed by Step 7); WineCo, Hydra, nywh-ShipItEZ 0 |
| 2 | Root cause to file:line | §2 |
| 3 | Sibling sweep | §0 P1–P9, analysis R1–R8 |
| 4 | Invariant over instance | every BOL >K chunked; retry and requeue cover every BOL-shipped row |
| 5 | Failing test first, per AC | §8 |
| 6 | Mutation-check plan | §8 "Mutation targets" table: 15 targets, each with a test that reaches it. The NON_NULL annotation target is dropped as unkillable (C-M1). After the D-ii drop: the DELETE-guard and audit-before-DELETE targets are removed, the 409 target shrinks to the one lock-timeout mapping, and the lock-query target merges into the D-i guard target, re-pointed from I4 to I4b; MANDATORY is killed by U12 + the rewritten I10 (no D-ii dependency); new targets for `resendConfirmed` exclusion, the 0-rows audit skip and MANDATORY → REQUIRED |
| 7 | Flyway version swept | Planned as V2.2.39 (free across 425 remote refs on 2026-10-13); **renumbered to V2.2.40 on 2026-10-16** after SBDEV-3659 took V2.2.39 on develop. V2.2.40 swept free on every remote and local branch that day; re-sweep before push; post-deploy gate step 6 |
| 8 | Cross-repo deploy order | API → UI |
| 9 | Docs | §6 docs row (6 docs) |
| 10 | Independent review | 4 lanes (T3), each writing to `SBDEV-3672-evidence/` |

## §10 Resolved decisions + ADR

| # | Decision | By |
|---|---|---|
| D1 | Chunk REGULAR and HUB_AND_SPOKE at K=`WMS_BOL_SHIPPED_OMS_CHUNK_SIZE` (seed 40, fallback 40, clamp 60). ≤K unchanged. Aggregate `BILL_OF_LADING_CHUNK`, id `bolId×100000+i`. Read timeout 15 s. | Nam |
| D2 | Key `BOL-SHIPPED-<bol.id>-C<i>of<N>` (0-based i) + additive `chunk_index`/`chunk_count`. `bol.id` (pk), not `bol_id` (= `getName()`, `BOLS:753`, not unique). | Nam (pk: planner) |
| D3 | Status endpoint + UI on open/closed detail. `confirmed = N − pending − failed`; rows reconciled by a resend of the latest linked message count as confirmed; no rows → `NO_RECORD` with reason `EMPTY_BOL` (exists-check equivalent of `palletDtos.isEmpty()`) / `PURGED` (shipped < today − retention − 1) / `UNKNOWN` (incl. the boundary day). | Nam (2026-10-13; semantics drafted by planner, confirmed as planned) |
| D4 | 29 attempts (≈24 h), cap 1 h, for every `ORDER_BATCH_SHIPPED` row. Others stay at 5. | Nam (2026-10-13) |
| D5 | Requeue gated on `WEB_UI_VIEW_BILL_OF_LADING`; **D-i only**: one guarded `UPDATE … WHERE status='FAILED_TERMINAL'` flips the BOL's terminal rows (minus `resendConfirmed`) to `FAILED_RETRY`, attempts 0, `next_attempt_at` now, current URL sysprop, keys preserved; per-requeue MANDATORY audit row; lock timeout → 409. | Nam (2026-10-13); guards: ralplan rounds 1–2; D-ii removed by D10 |
| D6 | Body-level `Status:Error` stays on SBDEV-2736. | Nam |
| D7 | Chunk rows on **LANE_CLUB** (generic consumer `ODJ:85,139`; `lane` used only by club sites `CustomerorderBatchService:889,900,916,1034`; reclaim lane-scoped). | Nam (2026-10-13) |
| D8 | `last_message_id` is native-only; no entity field. Audit = one Service Log row per requeue in the requeue tx: destination `'N/A'`, statuscodeanswer `'REQUEUE'`, sender `wms:requeue` (not resendable, not watched). | ralplan (A-M1/A-M4, C-H2; round 2 A-N1/C-N2) |
| D9 | Requeue counter increments by 1 per successful call; row count goes to the log `rows` field and the audit answer. | ralplan round 2 (C-m6), planner's pick |
| D10 | **Approval and scope reduction (2026-10-13).** (a) **D-ii dropped entirely**: its only PRD candidate, outbox 11135 / BOL 101226(5), was fixed manually in OMS on 2026-10-13, and both review rounds' main antithesis was that D-ii is a permanent destructive feature for one row. Removed with it: the re-chunk branch, the guarded DELETE and rowcount assert, `SELECT … FOR UPDATE`, `OutboxRequeueConflictException`, the `DataIntegrityViolationException` 409 mapping, the `deletedOriginalId`/`payloadBytes` audit fields, I6 and the D-ii-based I10/I7, the D-ii mutation targets, pre-mortem 4 and R-6 as written, and the "retire D-ii" follow-up. The `PessimisticLockingFailureException` → 409 mapping stays, because the D-i UPDATE can still wait out the 3 s `lock_timeout` behind another tx. (b) **11135** is closed by a one-off post-deploy UPDATE to `SENT` (Step 7, owner Nam). (c) A legacy oversized single row is a **known limitation**: requeue sends it whole; manual recipe in §7; Prereq 9 census kept. (d) **D3 confirmed** as planned; **D4, D5 (now D-i only), D7** already confirmed. (e) This scope reduction was **not re-reviewed by a ralplan round**: it only removes code paths. The tests that replace D-ii-dependent pins (I4b, the rewritten I10 and I7, the new U13 cases) are named in §8, and the T3 4-lane review in Step 4 covers them. | Nam (2026-10-13) |

**Superseded analysis text:** analysis §3's "Lane DEFAULT" and key `…-C<i>` are superseded by D7 (LANE_CLUB) and D2 (`…-C<i>of<N>`).

**Consensus record (ralplan DELIBERATE)**

| Round | Architect | Critic |
|---|---|---|
| 1 | APPROVE WITH CHANGES (A-M1..A-M5, A-L1..A-L8): [[SBDEV-3672-evidence/ralplan-architect-review]] | ITERATE (C-H1, C-H2, C-M1..C-M8, C-L1..C-L9): [[SBDEV-3672-evidence/ralplan-critic-review]] |
| 2 | APPROVE WITH CHANGES (A-N1..A-N5, notes (b), (e), (f), (g)): [[SBDEV-3672-evidence/ralplan-architect-review-round2]] | APPROVE with required edits RE-1..RE-3 (C-N1, C-N2, C-m1) and foldable C-m2..C-m8: [[SBDEV-3672-evidence/ralplan-critic-review-round2]] |

All round-2 items are folded into this revision (planner, final synthesis, 2026-10-13); no third round. The plan snapshots reviewed are [[SBDEV-3672-evidence/plan-snapshot-round1]] and [[SBDEV-3672-evidence/plan-snapshot-round2]]. The architect's round-2 synthesis was adopted (keep O1, make each guard's interaction an explicit test); its "ship D-ii behind the retirement follow-up" part is **superseded by D10**, which drops D-ii outright. Nam approved the plan on 2026-10-13 with that reduction; it was not sent back for a third round (D10 (e)). The pre-reduction text is [[SBDEV-3672-evidence/plan-snapshot-pre-drop-dii]].

**Open questions** (also in `.omc/plans/open-questions.md`): R-1 go/no-go (Nam, release gate); can a late PACKED/LOADED regress SHIPPED at OMS (L7); `message(redeliver_id)` index if the EXPLAIN is slow (Nam's yes). Closed 2026-10-13: D3 semantics (confirmed), interim 11135 replay (fixed in OMS; Step 7 closes the WMS row), whether D-ii is still needed (dropped, D10).

**ADR**
- **Decision:** bound each OMS shipped call to ≤K parcels by chunking at the producer; make delivery observable and recoverable per BOL (status reconciled with manual resends, 24 h retries, audited requeue); keep the new column off the entity; leave transport timeouts alone.
- **Drivers:** (1) OMS cost is linear in parcels — no WMS timeout under nginx's 60 s clears 1,528 parcels. (2) Partial failures must neither wedge siblings nor go unseen. (3) No tenant's non-BOL outbox traffic may depend on the new migration.
- **Alternatives considered:** D-ii, a requeue branch that re-chunks a legacy oversized row and deletes the original (designed and reviewed in rounds 1–2, dropped by Nam 2026-10-13, D10: its only PRD candidate was fixed in OMS, and it was a permanent destructive path for one row); O2 A+C, defer UI (smallest; rejected by Nam's D3/D5, kept as fallback); O3 longer read timeout (invalidated: 664 KB > 60 s, lane B H1); O4 OMS async SBDEV-3754 (other repo, unscheduled); chunking by pallet (unbounded); a dedicated BOL lane (another advisory lock, cron and +2 landlord connections, `ODJ:91-97`, for low-volume traffic — kept as R-3 fallback); entity-mapped `last_message_id` (tenant-wide outage on a failed migration).
- **Why chosen:** smallest change that bounds the call at its source and satisfies P-4; reuses the proven club-chunk pattern (`CustomerorderBatchService:1034-1036`); no OMS change; P-5 guards keep the extra surface from touching existing paths.
- **Consequences:**
  - a BOL becomes 1..N outbox rows; up to N merchant callbacks (gated, R-1);
  - CLUB lane load rises, cross-tenant in an outage (R-3);
  - outbox gains a native-only nullable column;
  - Service Log gains ≤30 rows per failing chunk plus one audit row per requeue. The audit row uses destination `'N/A'` and code `REQUEUE` and is excluded from the egress watchdog by destination, so **any future change to the watchdog's `'N/A'` exclusion must keep I11 green**;
  - no operator-triggered outbox DELETE is introduced (D-ii dropped, D10);
  - a legacy oversized single row (none on PRD after Step 7) is requeued whole and needs the manual recipe (§7 "Known limitation");
  - the requeue endpoint can answer 409 on a lock timeout;
  - status reconciliation covers only a resend of the latest linked message (R-9);
  - under a rolled-back image, terminal chunk rows need the manual UPDATE in Rollback.
- **Follow-ups:**
  - R-1 merchant census (release gate);
  - SBDEV-3754 OMS async;
  - SBDEV-2736 body-level verdicts;
  - R-3 fallback when its trigger fires;
  - Step 7: close outbox 11135 on c1wh-shipitez PRD after deploy (owner Nam);
  - proactive alert for terminal `ORDER_BATCH_SHIPPED` rows once metrics are scraped;
  - `message(redeliver_id)` index if either PRD EXPLAIN (c1wh, WineCo) exceeds 200 ms;
  - if operators hit R-9 gap (1) in practice, follow the full `redeliver_id` chain instead of one hop;
  - Service Log UI: hide or disable "Resend" for rows whose sender is not the instance name (the server already refuses at `MS:163`).

## §11 Implementation status (2026-10-16)

**PRs:** [wms2-api#526](https://github.com/SiteBossInc/wms2-api/pull/526) (merge first) · [wms2-web-ui#176](https://github.com/SiteBossInc/wms2-web-ui/pull/176). Status: **pr submitted**, ⏳ pending-merge(SBDEV-3672).

**How it was built.** The TDD gate was approved by Nam on 2026-10-16. Ralph could not start (omc CLI 4.14.6 has no `ralph` subcommand), so Nam's standing fallback was used: an opus executor per repo, working the stories in order, with the floor and the review lanes run from the lead session.

**wms2-api** (`fix/SBDEV-3672-chunk-bol-shipped`, base `origin/develop` 4ce87ead, head **ad8ff63e**):

| SHA | Commit |
|---|---|
| `29648d54` | TDD gate |
| `f47fa759` | Renumber V2.2.39 → V2.2.40 (SBDEV-3659 took V2.2.39 on develop) |
| `1213d9be` | Fix A |
| `616a4b87` | Fix B-1 + C |
| `fb89bd31` | Fix B-2..4 + D |
| `c8782d2a`, `1866ab66` | Review round 1 fixes |
| `0f54c0bf`, `057d0e3b` | Review round 2 fixes |
| `ad8ff63e` | Review round 3 fixes |

- **Suite of record** (CI command `mvn -B -ntp clean verify -Pci …`, clean tree at ad8ff63e): surefire **8505/0/0/1**, failsafe **938/0/0/23**. Develop CI at 4ce87ead: 8443/0/0/1 and 917/0/0/23.
- **Tests added:** see `SBDEV-3672-evidence/impl-api-executor.md`. Beyond §8 they include:
  - the lock-timeout IT, a real 55P03 → 409 through the controller (`BolOmsNotificationRowsIT#requeueBlockedPastLockTimeout_is409AtTheController`);
  - the `process_type` fence ITs;
  - a `lastError` redaction timing guard;
  - pinning of the wire names.
- **Mutation:** every §8 target was hand-mutated red. The U15 entity-field mutation was run by the executor. The reviewers' mutants were all killed by the final head.

**wms2-web-ui** (`fix/SBDEV-3672-bol-oms-notification-status`, base add0628, head **63b0a89**):

| SHA | Commit |
|---|---|
| `36e93c8` | Gate |
| `39591fa` | Implementation |
| `2678b94`, `00a4634`, `938247a`, `af44fcc` | Review rounds 1–4 |
| `63b0a89` | Security L5 |

- `yarn test`: 135/135 suites, 2448/2448 tests. All mutants were killed (coverage off).
- **Scope addition:** `store/admin/serviceLogs.js` `getLogDetail` now awaits its request. This fixed the deep link and the existing eye icon.

**Review lanes (T3, 4 lanes).** The evidence files are in `SBDEV-3672-evidence/`.

| Lane | File | Outcome |
|---|---|---|
| Conformance | `conformance-verifier.md` | PASS; the contract matches field by field; docs reviewed twice |
| API code | `review-api-code.md` | 5 rounds; 1 High, 1 Medium and 22 Low fixed; 1 Low closed by decision (`process_type` tag key) |
| Security | `review-api-security.md` | Risk LOW; M1 (this plan's stale `2.2.39` deploy gate) fixed in the plan; L1/L2/L5 fixed; L3 dispatched (no cooldown on requeue after a 4xx: documented behaviour, inline PR note); L4 agrees with D5 |
| UI code | `review-ui-code.md` | 5 rounds; 5 Medium and 15 Low fixed; L7 partial and accepted (a new-tab link doesn't pre-select the Service Log tab; needs `pages/admin.vue`) |

**Pre-merge measurements.**
- Step 3 `resendConfirmed` probe on PRD (`EXPLAIN` + timed run; `ANALYZE` is blocked on the PRD MCPs): c1wh **3.5 ms** (2,878 rows after the anchor, 11135's final attempt) and WineCo **13.6 ms** (9,216 rows, a 4-day anchor). Both are PK range scans, far under 200 ms. No `message(redeliver_id)` index is needed.
- PRD Flyway is at V2.2.38, installed 2026-10-16.

**Landmines found during implementation (not predicted by the plan).**
- V2.2.39 was taken on develop mid-flight, which made the Step 6 gate stale. The gate now checks the version, the column and the seed.
- `NeverMatcherNullBlindnessArchTest` and `TestClassTransactionManagerArchTest` both caught new test code. Typed `any*()` inside `never()` misses a null argument, and a NOT_SUPPORTED IT class must be listed as exempt.
- The first `lastError` redaction regex was quadratic (62 s on 100k characters while holding a DB connection). It was replaced with a linear pattern and pinned by a timing test.
- The legacy label keys on `CHUNK_SIZE_CEILING`; A-L6 is amended.

**Still open (not this skill's):**
- merge (API first);
- the §8 manual E2E on dev;
- R-1 merchant-callback release gate (Nam);
- Step 6 per-tenant gate after each deploy;
- Step 7 close-out of 11135 after the PRD deploy;
- archive the plan after the merge.

## §12 Parked (2026-10-17, Nam)

PRs wms2-api#526 and wms2-web-ui#176 are converted to **draft**, and ClickUp SBDEV-3672 is set to **pending**.

**Why.** SBDEV-3757 (async finishedShipping; OMS plan `oms-laravel-api/docs/plans/2026-10-13-async-finished-shipping-large-bol.md`) owns this problem on both the OMS and the WMS side. Once OMS is async, WMS chunking conflicts with it:
- chunks share `shared_unique_bol_id` with different positions, so §4.3 of that plan treats each chunk as a revised BOL;
- the result callback in its §6.4 keeps one status row per BOL, so each chunk's result would overwrite the last.

Fix B/D would also duplicate that ticket's BOL OMS status and "Resend to OMS".

**Scope from here.**
- §2 of the ticket moves to SBDEV-3757.
- §1 (the 8 v1 notifications that failed with 503 before cutover) stays open on SBDEV-3672 as OMS reconciliation.

**Conditions** (recorded on the ticket):
- OMS #777 (Phase 1) reaches PRD;
- SBDEV-3757's WMS side gets an owner and a date;
- a daily `FAILED_TERMINAL` `ORDER_BATCH_SHIPPED` check runs per PRD tenant until then.

**If revived:**
- rebase;
- renumber V2.2.40 if it's taken;
- add a "skip chunking when `OMS_ASYNC_BOL_SHIPPED_ACTIVATED`" switch.

The reusable pieces are listed in the SBDEV-3757 ClickUp comment of 2026-10-17.

**Docs.** The five sbdocs edits keep their `⏳ pending-merge(SBDEV-3672)` markers, which is still accurate: the behaviour is not on develop. If the ticket is abandoned rather than revived, remove those passages. Do not flip them.


**Fix C dropped (2026-10-17, Nam).** Fix C will not be split out as a stopgap. On all four PRD tenant DBs, across all history, exactly one `ORDER_BATCH_SHIPPED` row has ever gone `FAILED_TERMINAL`: outbox 11135. A longer budget would not have saved it, because every attempt timed out on size. No other BOL-shipped row needed 3 or more attempts within the SENT-retention window. The only other terminal rows are 2 Hydra `ADVICE_CLOSE` rows from 2026-07-13. If a long OMS outage ever strands BOL-shipped notices, the retry budget belongs in SBDEV-3757's WMS outbox work.
