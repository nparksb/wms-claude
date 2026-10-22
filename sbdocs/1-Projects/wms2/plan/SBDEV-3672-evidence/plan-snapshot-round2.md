---
title: "SBDEV-3672 — chunk the BOL-shipped OMS notification, with per-BOL delivery status, a longer retry budget and requeue"
ticket: "SBDEV-3672"
ticket_url: "https://app.clickup.com/t/868med0p1"
type: "bug"
priority: "high"
status: "draft — pending approval"
project: ["wms2-api", "wms2-web-ui"]
version: "v2"
requester: "Nam Park"
created: "2026-10-13"
updated: "2026-10-13"
revision: "ralplan round 2 (architect APPROVE WITH CHANGES + critic ITERATE folded in)"
tier: T3
db_verified: true
related:
  - "[[SBDEV-3672-evidence/analysis-chunk-bol-shipped]]"
  - "[[SBDEV-3672-evidence/architect-consult-outbox-read-timeout]]"
  - "[[SBDEV-3672-evidence/ralplan-architect-review]]"
  - "[[SBDEV-3672-evidence/ralplan-critic-review]]"
  - "[[SBDEV-3672-evidence/plan-snapshot-round1]]"
  - "[[wms2-bol-truck-loading-workflow]]"
  - "[[wms2-oms-integration-map]]"
tags:
  - plan
---

# SBDEV-3672: chunk the BOL-shipped OMS notification

**Ticket:** [SBDEV-3672](https://app.clickup.com/t/868med0p1). **Repos:** `v2/wms2-api` (base `origin/develop` a4fd6490), `v2/wms2-web-ui` (base `origin/develop` 9e31726). **Tier:** T3 (multi-repo, Flyway, data integrity across OMS). **Mode:** ralplan DELIBERATE.

The facts below come from `SBDEV-3672-evidence/analysis-chunk-bol-shipped.md` (the **analysis**). This plan builds on it and does not re-derive it. `BOLS` = `src/main/java/net/aim_ai/wms/service/BillofladingService.java`, `ODS` = `service/job/OutboxDispatchService.java`, `OS` = `service/OutboxService.java`, `OMR` = `repo/jpa/OutboxMessageRepository.java`, `ODJ` = `schedulejob/OutboxDispatcherJob.java`, `MS` = `service/MessageService.java`, `LWC` = OMS `LegacyWmsController.php`. wms2-api paths are under `src/main/java/net/aim_ai/wms/` unless stated otherwise.

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
| P7 | `MS.resendMessage:162` / `MessageController:62` | none in code. Replays one attempt's payload (≤K parcels, ≈7.6 s). Fix B status **reconciles** a successful resend via `redeliver_id` (M3) |
| P8 | Readers R1–R8 (analysis §0) | R1 forces distinct aggregate ids; R2/R3 unaffected (HSV); R7 tests stay green; R8 docs |
| P9 | `MS` (new `createServiceLogInCallerTx`, `Propagation.MANDATORY`) | **Fix D** audit row joins the requeue tx |
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
| P-4 | **Every failure is visible and fixable from the BOL screen**, and the screen agrees with the system of record. | Fix B + D; the status reconciles manual Service Log resends (M3). |
| P-5 | **New code must not widen the blast radius of existing paths.** | `last_message_id` is native-only (no entity field), so a tenant that misses V2.2.39 keeps dispatching (H2/M4). Fixes B and D **override "smallest change"** — sanctioned by Nam's D3/D5, and kept as narrow as P-5 allows. |

**Decision drivers (top 3):** (1) OMS cost is linear in parcels, so no WMS timeout under nginx's 60 s clears 1,528 parcels. (2) A partial failure must neither wedge siblings nor go unseen. (3) The change must not put any tenant's non-BOL outbox traffic at risk.

**Options**

| Option | Pros | Cons | Verdict |
|---|---|---|---|
| **O1. Fix A + C + B + D** (chunk, 24 h retries, status, requeue incl. D-ii re-chunk) | Bounds every POST; operator self-service; replays 11135 through product code | Largest surface: Flyway column, Phase-2 write, two endpoints, UI, the only destructive outbox path (D-ii) | **Chosen** (Nam D3/D5), with the M1/M2/M4 guards |
| **O2. Fix A + C only, one-off scripted replay of 11135, defer UI** (architect antithesis) | Smallest change; no schema change; no destructive path | Next terminal BOL is invisible again; recovery needs a DB-capable engineer; violates P-4 | Rejected by Nam's D3/D5; kept as the fallback if the B/D surface blocks release |
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
           ─► POST /v3/billOfLading/requeueOmsNotification/{id}  [D] (+ audit row in Service Log)
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
| `db/migration/V2.2.39__bol_shipped_chunk_size_and_outbox_message_link.sql` (**new**) | sysprop seed + nullable column |

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

1. **Link column, native-only (H2/M4, L2).** V2.2.39 starts with `SET LOCAL lock_timeout = '5s';` (LOCAL so the setting dies with Flyway's migration tx rather than riding a pooled connection), then `ALTER TABLE outbox_message ADD COLUMN IF NOT EXISTS last_message_id bigint` (nullable, no FK, metadata-only in PG). **`OutboxMessage` gets no field.** Access is native SQL only:
   - `OMR.linkServiceLog(id, mid)`: `@Modifying` native `UPDATE outbox_message SET last_message_id = :mid WHERE id = :id` — touches neither `version` nor `modified_at` (reclaim `OMR:76` and watchdog ordering unaffected). Called via `OS.linkServiceLog` (REQUIRES_NEW, `tenantTransactionManager`).
   - `writeServiceLog` returns the saved `Message` id or null. In `ODS.dispatchOne`, after each `writeServiceLog` and **only for `ORDER_BATCH_SHIPPED`**, call the link inside its **own** try/catch. In the 2xx branch `markSent` (`ODS:178`) sits inside the try whose catch (`:192`) would re-mark a SENT row; the link's own guard is what prevents that (L3). A link failure logs WARN and increments `wms2.outbox.service_log_link.failed{process_type}`.
   - Consequence: a tenant missing V2.2.39 still enqueues, claims and dispatches (the claim's `RETURNING *` maps only entity columns); only the link (swallowed) and the two new endpoints fail on that tenant.
2. **Row-set query.** `OMR.findBolNotificationRows(bolId)` (native; served by `index_outbox_message_aggregate_order (aggregate_type, aggregate_id, id, status)`, `V2.2.00:4149`):

   ```sql
   (aggregate_type='BILL_OF_LADING' AND aggregate_id=:bolId)
   OR (aggregate_type='BILL_OF_LADING_CHUNK' AND aggregate_id BETWEEN :bolId*100000 AND :bolId*100000+99999)
   ```

   It `LEFT JOIN`s `message m ON m.id = o.last_message_id` (→ `messagePresent`) and, **only for `FAILED_TERMINAL` rows**, evaluates `resendConfirmed = EXISTS (SELECT 1 FROM message r WHERE r.id > o.last_message_id AND r.redeliver_id = o.last_message_id AND r.statuscodeanswer ~ '^2')` (M3). `message.redeliver_id` has an FK but **no index** (`V2.2.00:1408,5618`); the `r.id > last_message_id` bound turns it into a PK range scan over messages written since the failure. Step 3 runs `EXPLAIN ANALYZE` on c1wh PRD's `message` table; if >200 ms, a `CREATE INDEX CONCURRENTLY` on `message(redeliver_id)` becomes a follow-up needing Nam's yes. Only one resend hop is followed.
3. **Service.** `BolOmsNotificationService.status(bolId)`, `@Transactional(value="tenantTransactionManager", readOnly=true)`.
   - N: from a chunk row's key (`…of<N>`); a `BILL_OF_LADING` row → N = 1; no rows → N unknown.
   - `failed` = `FAILED_TERMINAL` and not `resendConfirmed`. `pending` = `PENDING`, `IN_FLIGHT`, `FAILED_RETRY`. `resendConfirmed` rows count as confirmed, labelled "delivered via manual resend".
   - `confirmed = N − pending − failed`. Includes purged SENT rows: rows leave the table only as SENT (`OMR:84-86`; the cutover-only `06-drain.sh:27` is out of scope) or by D-ii, which replaces them in the same tx. An operator's manual DELETE of a terminal row would read as confirmed — documented, not defended.
   - **`state` precedence (L4):** `NOT_SHIPPED` (BOL not CLOSED/TRANSFER) › `FAILED` (failed > 0) › `PENDING` (pending > 0) › `CONFIRMED` › `NO_RECORD` (closed, no rows).
   - **`NO_RECORD` reason (D3, needs Nam's confirmation):** `EMPTY_BOL` when the BOL has no loaded parcels (SBDEV-2737 skip; executor reuses the existence check behind `runShippingPhase`'s pallet build, or folds into `UNKNOWN` if none is cheap); `PURGED` when `billoflading.shipped` ≤ today − `retentionDays`; otherwise `UNKNOWN`.
   - **Legacy row (L6):** a single non-SENT `BILL_OF_LADING` row with parcels > K carries `legacy: true, legacyParcels` and the UI says "1 legacy notification (1,528 parcels)" instead of "0/1".
   - Response: `state`, `noRecordReason`, `chunkCount`, `confirmed`, `pending`, `failed`, `resendConfirmed`, `retentionDays` (the value from `RestIdempotencyCleanupJob.safeOutboxRetentionDays()` — extracted to a shared helper so the UI names the value actually used, L6), `failedChunks[]` of `{outboxId, chunkIndex (null for BILL_OF_LADING), chunkCount, attempts, nextAttemptAt, lastError (abbrev 300), lastMessageId, messagePresent}`.
   - "Confirmed" means **HTTP 2xx**; body-level `Status:Error` stays with SBDEV-2736 (D6). UI label: "Delivered (HTTP 2xx)".
4. **Endpoint.** `@RequiresFunction(WEB_UI_VIEW_BILL_OF_LADING) @GetMapping("/omsNotificationStatus/{id}")`; inherits `/v3` (`:39`). Unknown BOL → 404 (`EntityNotFoundException`).
5. **UI.** `outboundBolDetails.vue` gains an "OMS notification" row after `:73` (`38/39 delivered · 1 failed`, legacy text, or the `NO_RECORD` text by reason). A failed-chunk list links to the Service Log **only if** `functions` includes `WEB_UI_VIEW_MESSAGES` (`pages/admin.vue:93-94`) **and** `messagePresent` (L5 — `getLogDetail`, `store/admin/serviceLogs.js:97-99`, rejects unhandled on a purged id). The link commits `admin/setParentTab` 6 (`admin.vue:62`) and pushes `/admin?messageId=<id>`. `serviceLog.vue` `mounted()` calls `showDetails({id})` when `$route.query.messageId` is numeric. Fetched from a `watch` on `outboundBol.id`; a 404 from the endpoint hides the row.

**Why not the alternatives:** payload `LIKE` matching (seq scan, brittle); a `message.outbox_message_id` column (large table, concurrent index, lost on purge anyway); persisting N on `billoflading` (second hot-table schema change); mapping the column on the entity (H2: tenant-wide outbox outage if V2.2.39 fails).

### Fix C: ~24 h of retries for every BOL-shipped notice (D4)

Private `int maxAttemptsFor(OutboxMessage m)` returns `bolShippedMaxAttempts` when `ORDER_BATCH_SHIPPED.equals(m.getProcessType())`, else `maxAttempts`. Both `ODS:181` and `:193` use it. 400/404/422 stay immediately terminal (`:300`). Property `app.outbox.dispatcher.bol-shipped-max-attempts=29` (`@Value(...:29)`). Delays: attempts 0–5 sum 3,780 s; 6–28 each 3,600 s → 86,580 s ≈ 24.05 h over 30 POSTs. `STALE_INFLIGHT_TIMEOUT` (`ODS:71`) unchanged (25 × 20 s = 500 s < 900 s). Stuck-aggregate gauge (`OMR:102-115`) unaffected (chunk aggregates have one row).

**Why not:** global raise retries poisoned pick/pack for 24 h; keying on aggregate type leaves the ≤K single row at 5 (Nam rejected); time-based terminal needs a `created_at` comparison the design lacks.

### Fix D: requeue a BOL's failed notification (D5)

`@RequiresFunction(WEB_UI_VIEW_BILL_OF_LADING) @PostMapping("/requeueOmsNotification/{id}")` → `BolOmsNotificationService.requeue(bolId)`, `@Transactional(value="tenantTransactionManager")`. Response `{requeued, mode: REQUEUE|RECHUNK|NONE, reason?}`; **never 500** for a race.

1. **Lock (M2).** `SELECT … FROM outbox_message WHERE <Fix B predicate> FOR UPDATE`. A second concurrent request blocks; under READ COMMITTED it then skips the row the winner deleted and does not see the winner's new rows, so it falls through to `NONE`.
2. **Branch.**
   - **D-ii (narrow; replays 11135):** the locked set is **exactly one** `BILL_OF_LADING` row, `FAILED_TERMINAL`, payload `outbound_bol_type ∈ {REGULAR, HUB_AND_SPOKE}`, parcels > K. In the same tx: deserialize → `split` → enqueue N chunk rows (Fix A shape, destination = **current** `WEBSERVICE_ORDER_BATCH_SHIPPED` sysprop, L4) → `DELETE FROM outbox_message WHERE id=:id AND status='FAILED_TERMINAL'`, assert rowcount = 1 (else throw → rollback → 409 ProblemDetail; unreachable under the lock, belt-and-braces). A `uk_outbox_message_idempotency_key` violation also maps to 409. WARN log `{originalId, payloadBytes, chunks}`.
   - **D-i (everything else):** native `UPDATE … SET status='FAILED_RETRY', attempts=0, next_attempt_at=NOW(), modified_at=NOW(), destination_url=:currentUrl WHERE id IN (:lockedIds) AND status='FAILED_TERMINAL'` excluding `resendConfirmed` rows. Keys untouched. `last_error` is **not** annotated (it is overwritten by `markRetry/markTerminal`, `OS:101,115`, so it is no audit trail; this also retires L9). Transfers always take D-i.
   - **NONE:** 0 rows; `reason` = `"in flight, nothing to requeue"` when any row is `IN_FLIGHT`, else `"nothing failed"`.
3. **Audit row (M1).** For D-i/D-ii with ≥1 row, one Service Log `message` row inside the requeue tx via new `MS.createServiceLogInCallerTx(...)` (`@Transactional(value="tenantTransactionManager", propagation=MANDATORY)`, called from another bean, so the proxy applies; `createMessage` is REQUIRES_NEW at `MS:110` and would survive a rollback). Process `ORDER_BATCH_SHIPPED_REQUEUE` (new `MessageProcessType` constant), operator = the principal (`saveServiceLog` resolves it, `MS:125-136`), destination literal `wms:requeue` (not an OMS URL, so the SBDEV-3325 egress watchdog never counts it — executor confirms against the watchdog's predicate), answer = Jackson-serialized `{bolId, outboxIds, mode, deletedOriginalId, payloadBytes, user}` (all values bound through the serializer, never concatenated).
4. **Telemetry.** INFO `requeue bolId={} user={} mode={} count={}`; counter `wms2.outbox.requeued{aggregate_type, mode}` (D-ii tags the original `BILL_OF_LADING`).
5. **Gate.** The screen's own function, `WEB_UI_VIEW_BILL_OF_LADING`, which already gates `closeOutboundBol` (`BillOfLadingController:237-238`), the action that emitted the notification. sb_admin-only is the retired anti-pattern; a new `WEB_UI_ACTION_*` needs three artifacts for no gain (SBDEV-3017 §9.16 Option B; SBDEV-3606 does not generalise).
6. **UI.** "Requeue failed OMS notification" button when `failed > 0`; confirm dialog with the count; shows `reason` on `NONE`; refreshes status.

## §6 File change summary

| Repo | File | Change |
|---|---|---|
| api | `service/BillofladingService.java` | chunk branch at `:786-807`; resolver |
| api | `service/BolShippedNotificationChunker.java` | **new**, pure |
| api | `json/BillOfLadingWebServiceDto.java` | +`chunk_index`, `chunk_count` (Integer, unset on ≤K) |
| api | `service/WmsConstants.java` | chunk-size key/default `"40"`; `BOL_SHIPPED_CHUNK_AGGREGATE_TYPE`; `MessageProcessType.ORDER_BATCH_SHIPPED_REQUEUE` |
| api | `service/OutboxService.java` | +`linkServiceLog` (REQUIRES_NEW) |
| api | `service/job/OutboxDispatchService.java` | `maxAttemptsFor`; guarded link after service log; `writeServiceLog` returns id |
| api | `repo/jpa/OutboxMessageRepository.java` | +`linkServiceLog`, `findBolNotificationRows`, `lockBolNotificationRows`, `requeueBolTerminal`, `deleteTerminalById` (all native) |
| api | `service/MessageService.java` | +`createServiceLogInCallerTx` (MANDATORY) |
| api | `service/BolOmsNotificationService.java` | **new** |
| api | `schedulejob/RestIdempotencyCleanupJob.java` | expose `safeOutboxRetentionDays` via a shared helper |
| api | `controller/BillOfLadingController.java` | +2 handlers |
| api | `resources/application.properties` (`:244`) | +`bol-shipped-max-attempts=29` |
| api | `db/migration/V2.2.39__bol_shipped_chunk_size_and_outbox_message_link.sql` | `SET LOCAL lock_timeout`; seed (shape of `V2.2.29:37-50`); `ADD COLUMN` |
| ui | `components/outbound/bol/outboundBolDetails.vue` | status row, failed list, requeue button |
| ui | `store/outbound/outboundBols.js` | `getBolOmsStatus`, `requeueBolOms` |
| ui | `components/admin/serviceLog/serviceLog.vue` | `?messageId` deep link |
| docs | `wms2-bol-truck-loading-workflow.md:44,114,313-329`, `wms2-oms-integration-map.md:112` + retry row, `wms2-sysprop-catalog.md`, `wms2-scheduled-jobs-catalog.md` (29 attempts), `wms2-entity-enumeration-report.md` (new column, native-only), SBDEV-3325 watchdog README (`WATCHDOG_ACK` for a 24 h poisoned row, L8) | describe chunking, retry budget, link |

## §7 Implementation steps

### Prerequisites

| # | Prerequisite | Required value / action |
|---|---|---|
| 1 | DB state | PRD is at **V2.2.37** (installed 2026-10-08) on all four PRD DBs; V2.2.38 is on develop, unreleased. V2.2.38 must be applied, or ship in the same release ahead of V2.2.39. Re-sweep all remote branches for V2.2.39 before push (memory: *flyway-version-pick-sweep-all-remote-branches*). |
| 2 | Sysprops | `WMS_BOL_SHIPPED_OMS_CHUNK_SIZE=40` seeded by V2.2.39; fallback 40, ceiling 60. Hydra has zero BOLs > 40. |
| 3 | Config | `app.outbox.dispatcher.bol-shipped-max-attempts=29`; no env override. |
| 4 | Deploy order | **wms2-api first** (a merge to develop deploys and runs Flyway), then wms2-web-ui. UI hides the row on 404, so the reverse order degrades gracefully. |
| 5 | **Release gate R-1 (merchant callbacks)** | **Owner: Nam.** On each OMS v2 tenant DB serving a wms2 PRD warehouse: `SELECT client_id, debug FROM outbound_api WHERE call_name='outbound_bol_close' AND client_id IS NOT NULL AND isactive=1;` (`ClientCallbackService::endpoints:46-63`). **Go** if no production rows. **No-go** for the PRD release if any client has one, until that merchant acknowledges partial per-chunk callbacks or OMS debounces. Record the result and decision on the ticket before the PRD release. NOOP parcels are excluded from callbacks (`LWC:2434-2435`), so requeues/replays never duplicate a callback for an already-shipped parcel. |
| 6 | External systems | OMS: no change; it ignores extra keys and skips already-shipped parcels (`LWC:2313-2319,2426-2432`). Open (L7): can a late PACKED/LOADED (DEFAULT lane) regress a SHIPPED parcel (CLUB lane) at OMS? Ask before PRD. |
| 7 | Access | No new function. Endpoints use `WEB_UI_VIEW_BILL_OF_LADING`; the Service Log link needs `WEB_UI_VIEW_MESSAGES`. |
| 8 | Monitoring | Metrics are not scraped (memory). Interim signals are DB queries: §9 pre-mortem detection rows. |
| 9 | Oversized rows at deploy (L8) | Any oversized single row still `FAILED_RETRY` at deploy now times out hourly for 24 h before D-ii applies. PRD census 2026-10-13: none outside 11135 (c1wh, WineCo, Hydra, nywh-ShipItEZ). Re-run the census the day of release. |

### Steps

1. **API, chunker + producer (Fix A).** Worktree `.claude/worktrees/wms2-api/SBDEV-3672`, branch `fix/SBDEV-3672-chunk-bol-shipped`. Failing tests first (§8 U1–U9). **AC-A:** ≤K → exactly one row whose payload is byte-equal to the fixture; >K → ⌈n/K⌉ rows with the ids/keys/lane above; transfer >K → 1 row.
2. **API, V2.2.39 + native link + retry budget (Fixes B-1, C).** **AC-C:** an `ORDER_BATCH_SHIPPED` row goes terminal only at attempts 29; `CUSTOMER_ORDER` still at 5. **AC-B1:** `OutboxMessage` maps no `last_message_id`; a link failure changes no outcome.
3. **API, status + requeue + audit (Fixes B-2..4, D).** **AC-B:** counts correct before and after a SENT purge and after a successful manual resend. **AC-D:** requeue flips only this BOL's terminal rows; D-ii is atomic (an enqueue failure leaves the original row and no audit row); two concurrent requeues yield one RECHUNK and one NONE, no 500. Run the `EXPLAIN ANALYZE` from Fix B-2 on c1wh PRD.
4. **API close-out.** `mvn clean verify` vs the suite baseline; mutation-check every new assertion (§8 targets); 4 review lanes (T3), fix every finding incl. Low; PR into develop.
5. **UI.** Worktree `.claude/worktrees/wms2-web-ui/SBDEV-3672` off fresh `origin/develop`. Jest first (J1–J5); `yarn test` vs baseline; PR into develop **after** the API PR merges.
6. **Post-deploy schema gate (H2).** After each environment's API deploy: `SELECT version, success FROM flyway_schema_history WHERE version='2.2.39';` on **every** tenant DB of that environment (PRD: all six, memory *wms2-estate-census-is-six-tenant-dbs*). Any missing/failed → fix (usually ownership drift), restart to re-run; dispatch is unaffected meanwhile (P-5). Deploy is not done until all report `success=t`.
7. **BOL 101226(5) / outbox 11135 recovery** — see runbook below.
8. **Docs.** Update the §6 docs row; run `verify-docs`.

### Rollback

Revert the wms2-api image. V2.2.39 is additive (nullable column + one sysprop) and harmless to old code, which maps no such column. Chunk rows already enqueued are dispatched by the old CLUB consumer (generic `dispatchBatch`) under the old 5-attempt budget. Revert the UI independently. No down-migration.

### Runbook: 11135 recovery (owner Nam)

- **Before snapshot (both paths).** Extract the 1,528 `unique_id`s from `SELECT payload FROM outbox_message WHERE id=11135` (c1wh-shipitez PRD) into the session scratchpad. On the ShipItEZ OMS DB: `SELECT parcel_status, count(*) FROM parcel WHERE <unique-id lookup column used by finishedShipping, LWC ~:2290> IN (…) GROUP BY 1;` Save the result on the ticket.
- **Interim, before the PRD release (optional, Nam-run).** Slice the payload with `jq` into ≤40-parcel bodies (full header, straddling pallet copied, same `bol_id`), and POST them **sequentially** to the `WEBSERVICE_ORDER_BATCH_SHIPPED` URL with the OMS credential WMS uses (never pasted into the ticket). Stop on the first non-2xx. Check R-1 (Prereq 5) first, since each call can fire one merchant callback for its SUCCESS parcels. Outbox 11135 stays `FAILED_TERMINAL` until the release.
- **Post-release.** Open BOL id 121932106 detail → Requeue. D-ii turns 11135 into 39 chunk rows (≤40 parcels) on CLUB. Verify `select status,count(*) from outbox_message where aggregate_type='BILL_OF_LADING_CHUNK' and aggregate_id between 12193210600000 and 12193210699999 group by 1` → `SENT = 39` within ~5 min, plus one `ORDER_BATCH_SHIPPED_REQUEUE` audit row naming `deletedOriginalId=11135`. If the interim replay ran, every parcel is NOOP and no callback fires.
- **After snapshot.** Re-run the OMS query. **Expected:** all 1,528 in a shipped status, i.e. SUCCESS (non-shipped before) + NOOP (shipped before) = 1,528. Any shortfall → list the missing `unique_id`s from the chunk `message.answer` bodies.

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
| U11 | `OutboxDispatchServiceUnitTest#bolShippedRow_linksServiceLogId` / `#linkFailureIn2xxBranch_neverCallsMarkRetryOrMarkTerminal` / `#otherProcessTypes_notLinked` | Fix B-1; failure injected in the **2xx** branch (L3) |
| U12 | `BolOmsNotificationServiceUnitTest#confirmedCountsPurgedSentRows` / `#resendConfirmedCountsAsConfirmed` / `#failedBeatsPending` / `#noRows_emptyBol_vs_purged_vs_unknown` / `#openBol_isNotShipped` / `#legacyOversizedRow_isLabelledLegacy` / `#statusIsReadOnlyTenantTx` / `#requeueIsReadWriteTenantTx` | status math, precedence, NO_RECORD reasons; the last two assert `@Transactional` attributes by reflection (L2) |
| U13 | `BolOmsNotificationServiceUnitTest#requeue_inFlightOnly_returnsNoneWithReason` / `#legacyTransfer_isPlainRequeue` / `#requeueUsesCurrentShippedUrl` | branch selection, L4, L6 |
| U14 | `BillOfLadingControllerUnitTest#requeue_isPost` / `#raceConflict_maps409` | verb + error shape |
| U15 | `OutboxMessageMappingUnitTest#entityDoesNotMapLastMessageId` | reflection over fields/`@Column` names (H2 pin) |
| G1 | `Sbdev3017TrancheGateContextTest` (`:110-117`, `:533-535`) + two `row(...)` | `(BillOfLadingController, /v3/billOfLading/omsNotificationStatus/{id}) → WEB_UI_VIEW_BILL_OF_LADING` and the requeue path; full context, also covers `/v3` (L1) |

**Integration (Testcontainers PG, failsafe `*IT`, Flyway via `OutboxItFlyway.migrateProduction`; assert by id — repository tests commit)**

| # | Class#method | Asserts |
|---|---|---|
| I1 | `BolChunkOutboxClaimIT#terminalChunkDoesNotHoldSiblings` | one chunk terminal; `findAndClaimPending(…,"CLUB")` claims the rest |
| I2 | `…#defaultLaneNeverClaimsChunkRows` | lane isolation |
| I3 | `BolOmsNotificationRowsIT#findsBothShapesOnlyForThisBol` | neighbours `bolId±1` and a `CLUB_BATCH_CHUNK` with the same numeric id excluded |
| I4 | `…#requeueFlipsOnlyTerminalRowsKeepsKeysAndWritesOneAuditRow` | statuses, attempts=0, keys unchanged, destination = current sysprop; second call `NONE`; one `ORDER_BATCH_SHIPPED_REQUEUE` message row with the answer JSON fields and operatorId |
| I5 | `…#lastMessageIdLeftJoinReportsPurgedMessage` / `#resendWith2xxRedeliverIdReconciles` / `#resendWith5xxDoesNot` | `messagePresent=false`; M3 both ways |
| I6 | `…#rechunkIsAtomic_enqueueFailureKeepsOriginalAndNoAuditRow` | pre-insert a row holding chunk C1's key → unique violation → 409; original still `FAILED_TERMINAL`, zero chunk rows, **zero audit rows** (pins MANDATORY) |
| I7 | `…#concurrentRequeue_oneRechunksOtherReturnsNone` | two threads + latch on a K=2 fixture: exactly one RECHUNK, one NONE, no exception, chunk count = N, original gone (memory: *wms2-concurrency-it-fixture-traps*, *wms2-pg-it-lane-has-no-tenant-pool*) |
| I8 | `…#linkUpdateLeavesVersionAndModifiedAtUnchanged` | L2 |
| I9 | `OutboxMigrationV2239IT#addsNullableColumnAndSeedIsIdempotent` | column null for old rows; the seed SQL executed **twice by hand** inserts one sysprop |

**Regression (unchanged, must stay green):** `FinishTransferPreTransferCloseIT:185-190`, `BillofladingServiceFinishTransferIT:170-187` (seed the chunk sysprop), `BillofladingServiceUnitTest` `never().enqueue` cases (`:395,410,468,1864-1995,3127,3502`) and `:1783 times(2)`, `OutboxLaneClaimIT`, `OutboxTerminalHoldIT`, `OutboxStuckAggregateIntegrationTest`, `ServiceLogPropagationIT`, `SelfInvokedTransactionalArchTest`.

**Observability (asserted, not just emitted)**

| # | Where | Asserts |
|---|---|---|
| O1 | U13 + I4/I7 with `SimpleMeterRegistry` | `wms2.outbox.requeued{aggregate_type=BILL_OF_LADING_CHUNK,mode=REQUEUE}` and `{aggregate_type=BILL_OF_LADING,mode=RECHUNK}` increment by the row count; no null tags |
| O2 | U11 | `wms2.outbox.service_log_link.failed{process_type=ORDER_BATCH_SHIPPED}` increments on link failure |
| O3 | U13 (ListAppender) | INFO requeue line carries user, bolId, mode, count; D-ii WARN carries originalId, payloadBytes, chunks |
| O4 | I4 | the audit message row (process, destination `wms:requeue`, answer JSON) |

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
| Requeue | Restore the URL via admin UI. Force: `UPDATE outbox_message SET status='FAILED_TERMINAL', attempts=29 WHERE id=:id AND status='FAILED_RETRY';` | Click Requeue | `FAILED_RETRY` → SENT to the **restored** URL; key unchanged; one audit row |
| Legacy re-chunk | K=40: close a 5-parcel BOL (1 row, SENT). Then `UPDATE outbox_message SET status='FAILED_TERMINAL', attempts=29 WHERE id=:thatRow;` and set K=2 | Click Requeue | 3 chunk rows, original deleted, audit row with `deletedOriginalId`; OMS NOOPs all |
| Double click | same as above, fresh BOL | Click Requeue twice fast | one RECHUNK, second shows "nothing failed"; no error toast |
| Service Log link | a failed chunk with `messagePresent` | click link | Admin › Service Log opens that message |
| Transfer | — | Close a TRANSFER_OFFSITE BOL with > K parcels | 1 `BILL_OF_LADING` row |
| Restore | — | reset chunk size to 40 and the URL to the recorded value | — |

**Mutation targets** (each must turn a named test red): K clamp at 60 (U8); `maxAttemptsFor` type check (U10); setting `chunk_*` on the ≤K path (U4 byte fixture — replaces the unkillable `NON_NULL` annotation target, M1); D-i `status='FAILED_TERMINAL'` guard (I4); D-ii DELETE guard/rowcount (I6/I7); `resendConfirmed` `^2` regex (I5); MANDATORY → REQUIRES_NEW (I6); adding the entity field (U15); link outside its own try (U11).

**Deliberately skipped coverage:** browser e2e in CI (no harness); OMS-side behaviour (other repo; covered by NOOP/skip citations); CLUB-lane load test (arithmetic in R-3 instead); a proactive alert for a BOL notice terminal after 24 h — **accepted gap**, interim detection is the daily query in pre-mortem 3 / Follow-ups.

## §9 Risks, pre-mortem and mitigations

| # | Risk | Mitigation |
|---|---|---|
| R-1 | Merchant `outbound_bol_close` fires once per chunk (`LWC:2523`) | **Release gate**, Prereq 5 (owner Nam, query, go/no-go). NOOP parcels excluded from callbacks (`LWC:2434-2435`). |
| R-2 | Partial visibility | Fix B/C/D; per-chunk resend and requeue. |
| R-3 | **CLUB lane occupancy, cross-tenant.** Healthy: 39 × 7.6 s ≈ 5 min. OMS hung: each POST costs up to 20 s; a tick claims 25 rows per tenant → 500 s per tenant per tick, and `ODJ:136-139` runs tenants **sequentially** in one advisory-locked tick, so a 39-chunk wave holds ~13 min and recurs ~hourly for 24 h (Fix C), delaying every other tenant's club notices. | Accepted for now (club and BOL are both bulk; DEFAULT lane untouched). **Fallback trigger:** `tick_duration{lane=CLUB}` p95 > 300 s once scraped, or (today) any due CLUB row older than 15 min: `SELECT count(*) FROM outbox_message WHERE lane='CLUB' AND status IN ('PENDING','FAILED_RETRY') AND next_attempt_at < now() - interval '15 minutes';` on any tenant → ship a per-type claim cap (≤5 chunk rows per tenant per tick) or a dedicated lane (D7 fallback). |
| R-4 | Chunk replay order | OMS order-independent; skips shipped parcels, NOOP = success. |
| R-5 | K changes mid-close | Read once per close. |
| R-6 | D-ii deletes a row | Locked, status-guarded, rowcount-asserted, same tx as its replacement and its audit row; PG ITs I6/I7. Narrow predicate. Follow-up to retire D-ii. |
| R-7 | Service Log growth: ≤30 rows per failing chunk (~1,170 for a 39-chunk BOL over 24 h) | Bounded by message retention (`MessageRepository:99-102`). |
| R-8 | Extra UPDATE per BOL-shipped dispatch | Native, one row, best-effort. |
| R-9 | Status drift vs system of record | Resend reconciled (M3); manual operator DELETE of a terminal row reads as confirmed — documented. |
| R-10 | Watchdog red ~24 h for one poisoned row on a low-traffic tenant (L8) | Document `WATCHDOG_ACK` in the SBDEV-3325 watchdog README. |

**Pre-mortem** (it is 2 weeks after release and this went wrong — why?)

| # | Scenario | Detection | Mitigation |
|---|---|---|---|
| 1 | **V2.2.39 failed on one tenant** (ownership drift, or the 5 s lock_timeout hit behind a long close tx during rolling boot) | Step 6 `flyway_schema_history` gate; `StartupFlywayMigrator` ERROR; status endpoint 500 on that tenant only; `service_log_link.failed` rising | Native-only column means pick/pack/close/dispatch keep working (P-5, U15). Fix ownership, restart to re-run. Missing seed → resolver falls back to 40. |
| 2 | **Merchant callback multiplication** — a merchant's integration double-books on partial `outbound_bol_close` callbacks | Prereq 5 query before release; merchant complaint after | No-go rule in Prereq 5; OMS debounce as follow-up; requeue never duplicates (NOOP excluded). |
| 3 | **CLUB lane starvation during an OMS outage** — club notices for every tenant lag for hours | R-3 DB query (due CLUB rows > 15 min); later `tick_duration{lane=CLUB}`. Daily: `SELECT id, aggregate_id FROM outbox_message WHERE process_type='ORDER_BATCH_SHIPPED' AND status='FAILED_TERMINAL';` per tenant | R-3 fallback (claim cap / dedicated lane); requeue after OMS recovers. |
| 4 | **D-ii race or partial re-chunk** — duplicate chunks, a lost original, or an orphan audit row | I6/I7 in CI; on PRD the audit row's `deletedOriginalId` vs the chunk-row count | `FOR UPDATE` + guarded DELETE + MANDATORY audit; 409 not 500. |

## Horizontal Scalability Validation

| Concern | Affected? | Evidence |
|---|---|---|
| In-JVM state | No | Chunker pure; K from the tenant-keyed Caffeine sysprop cache (`SyspropService:106`), read once per close. |
| Pool math | No | No new long tx. Link is one short REQUIRES_NEW UPDATE in Phase 2; no tx across HTTP (`ODS:152-157`). |
| Scheduled jobs | Yes, existing CLUB lane | `ODJ:83-86` advisory lock `OUTBOX_DISPATCHER_CLUB`, one replica per tick. **Tenants dispatched sequentially within the tick (`ODJ:136-139`) — outage cost is cross-tenant (R-3).** No new job. |
| Long tx | No | Close tx gains N inserts (39 for 1,528 parcels), fewer bytes than one 664 KB row. Requeue: one locked row set. |
| Request affinity | No | Stateless endpoints. |
| Retry / idempotency | Yes | Deterministic chunk keys; requeue preserves keys; OMS skips shipped parcels; stale reclaim lane-scoped (`OS:125-135`). |
| Tenant context | No | `TenantFilter` for HTTP; dispatcher per tenant (`ODJ:138`). |
| Distributed locks | Yes (row lock) | D-i: `status='FAILED_TERMINAL'` guard makes concurrent clicks idempotent. D-ii: `SELECT … FOR UPDATE` on the row set serializes replicas; the loser returns `NONE` (I7). |
| Cache invalidation | No | New sysprop via existing `sysprops` cache; admin edit evicts. |
| External notifications | Yes | N POSTs per BOL; R-1 gate. Each POST ≤ 5 + 15 s; `STALE_INFLIGHT` holds (500 s < 900 s). |

## v2 constraint checklist

| Constraint | Status |
|---|---|
| OSIV | `open-in-view=false` (`application.properties:85`); status returns DTOs built in its readOnly tx. |
| `tenantTransactionManager` | Every new `@Transactional` names it. |
| readOnly / propagation | `status()` readOnly; `requeue()` read-write; `createServiceLogInCallerTx` MANDATORY. Pinned by U12 `#statusIsReadOnlyTenantTx`/`#requeueIsReadWriteTenantTx` (reflection) and I6 (rollback removes the audit row). |
| Caffeine eviction | No new cache. |
| jakarta | No new entity field. |
| H2 SQL | New native queries are PG-only, tested in Testcontainers ITs. H2 lane unaffected (no entity change). |
| BaseControllerTest | Does not exist; use `BillOfLadingControllerUnitTest` / `BaseControllerUnitTest`. Gate pinned in `Sbdev3017TrancheGateContextTest` (G1). |
| Micrometer | New `wms2.outbox.requeued{aggregate_type,mode}`, `wms2.outbox.service_log_link.failed{process_type}`; no null tags. |

## Completeness checklist

| # | Item | Status |
|---|---|---|
| 0 | Affected sites by grep (§0) | done |
| 1 | DB query confirming the symptom | done: analysis §8 (11135); 2026-10-13 census — 1 `BILL_OF_LADING` `FAILED_TERMINAL` row (c1wh); WineCo, Hydra, nywh-ShipItEZ 0 |
| 2 | Root cause to file:line | §2 |
| 3 | Sibling sweep | §0 P1–P9, analysis R1–R8 |
| 4 | Invariant over instance | every BOL >K chunked; retry and requeue cover every BOL-shipped row |
| 5 | Failing test first, per AC | §8 |
| 6 | Mutation-check plan | §8 "Mutation targets" (NON_NULL annotation target dropped: unkillable) |
| 7 | Flyway version swept | V2.2.39 free across 425 remote refs; re-sweep before push; post-deploy gate step 6 |
| 8 | Cross-repo deploy order | API → UI |
| 9 | Docs | §6 docs row (6 docs) |
| 10 | Independent review | 4 lanes (T3), each writing to `SBDEV-3672-evidence/` |

## §10 Resolved decisions + ADR

| # | Decision | By |
|---|---|---|
| D1 | Chunk REGULAR and HUB_AND_SPOKE at K=`WMS_BOL_SHIPPED_OMS_CHUNK_SIZE` (seed 40, fallback 40, clamp 60). ≤K unchanged. Aggregate `BILL_OF_LADING_CHUNK`, id `bolId×100000+i`. Read timeout 15 s. | Nam |
| D2 | Key `BOL-SHIPPED-<bol.id>-C<i>of<N>` (0-based i) + additive `chunk_index`/`chunk_count`. `bol.id` (pk), not `bol_id` (= `getName()`, `BOLS:753`, not unique). | Nam (pk: planner) |
| D3 | Status endpoint + UI on open/closed detail. `confirmed = N − pending − failed`; resend-reconciled rows confirmed; no rows → `NO_RECORD` with reason `EMPTY_BOL`/`PURGED`/`UNKNOWN`. | Nam (purge semantics and NO_RECORD reasons: planner, **needs Nam's confirmation**) |
| D4 | 29 attempts (≈24 h), cap 1 h, for every `ORDER_BATCH_SHIPPED` row. Others stay at 5. | Nam (2026-10-13) |
| D5 | Requeue gated on `WEB_UI_VIEW_BILL_OF_LADING`; D-ii re-chunk for a legacy oversized row, now locked, guarded, audited and narrow. | Nam (2026-10-13); guards: ralplan round 2 |
| D6 | Body-level `Status:Error` stays on SBDEV-2736. | Nam |
| D7 | Chunk rows on **LANE_CLUB** (generic consumer `ODJ:85,139`; `lane` used only by club sites `CustomerorderBatchService:889,900,916,1034`; reclaim lane-scoped). | Nam (2026-10-13) |
| D8 | `last_message_id` is native-only; no entity field. Audit = one Service Log row per requeue in the requeue tx. | ralplan round 2 (architect M1/M4, critic H2) |

**Superseded analysis text:** analysis §3's "Lane DEFAULT" and key `…-C<i>` are superseded by D7 (LANE_CLUB) and D2 (`…-C<i>of<N>`).

**Open questions** (also in `.omc/plans/open-questions.md`): D3 purge/NO_RECORD semantics (Nam); R-1 go/no-go (Nam, release gate); can a late PACKED/LOADED regress SHIPPED at OMS (L7); `message(redeliver_id)` index if the EXPLAIN is slow (Nam's yes); interim 11135 replay — do it or wait for the release (Nam).

**ADR**
- **Decision:** bound each OMS shipped call to ≤K parcels by chunking at the producer; make delivery observable and recoverable per BOL (status reconciled with manual resends, 24 h retries, audited requeue); keep the new column off the entity; leave transport timeouts alone.
- **Drivers:** (1) OMS cost is linear in parcels — no WMS timeout under nginx's 60 s clears 1,528 parcels. (2) Partial failures must neither wedge siblings nor go unseen. (3) No tenant's non-BOL outbox traffic may depend on the new migration.
- **Alternatives considered:** O2 A+C + scripted replay, defer UI (smallest; rejected by Nam's D3/D5, kept as fallback); O3 longer read timeout (invalidated: 664 KB > 60 s, lane B H1); O4 OMS async SBDEV-3754 (other repo, unscheduled); chunking by pallet (unbounded); a dedicated BOL lane (another advisory lock, cron and +2 landlord connections, `ODJ:91-97`, for low-volume traffic — kept as R-3 fallback); entity-mapped `last_message_id` (tenant-wide outage on a failed migration).
- **Why chosen:** smallest change that bounds the call at its source and satisfies P-4; reuses the proven club-chunk pattern (`CustomerorderBatchService:1034-1036`); no OMS change; P-5 guards keep the extra surface from touching existing paths.
- **Consequences:** a BOL becomes 1..N outbox rows; up to N merchant callbacks (gated, R-1); CLUB lane load rises, cross-tenant in an outage (R-3); outbox gains a native-only nullable column; Service Log gains ≤30 rows per failing chunk plus one audit row per requeue; the codebase gains its first operator-triggered outbox DELETE (D-ii).
- **Follow-ups:** R-1 merchant census (release gate); SBDEV-3754 OMS async; SBDEV-2736 body-level verdicts; R-3 fallback when its trigger fires; retire D-ii once 11135 is replayed and one release cycle's census shows no oversized single `BILL_OF_LADING` rows; proactive alert for terminal `ORDER_BATCH_SHIPPED` rows once metrics are scraped; `message(redeliver_id)` index if needed.
