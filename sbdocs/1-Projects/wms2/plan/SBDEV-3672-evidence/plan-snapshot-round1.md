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
tier: T3
db_verified: true
related:
  - "[[SBDEV-3672-evidence/analysis-chunk-bol-shipped]]"
  - "[[SBDEV-3672-evidence/architect-consult-outbox-read-timeout]]"
  - "[[wms2-bol-truck-loading-workflow]]"
  - "[[wms2-oms-integration-map]]"
tags:
  - plan
---

# SBDEV-3672: chunk the BOL-shipped OMS notification

**Ticket:** [SBDEV-3672](https://app.clickup.com/t/868med0p1). **Repos:** `v2/wms2-api` (base `origin/develop` a4fd6490), `v2/wms2-web-ui` (base `origin/develop` 9e31726). **Tier:** T3 (multi-repo, Flyway, data integrity across OMS).

The facts below come from `SBDEV-3672-evidence/analysis-chunk-bol-shipped.md` (the **analysis**). This plan builds on the analysis and does not re-derive it. `BOLS` = `src/main/java/net/aim_ai/wms/service/BillofladingService.java`, `ODS` = `service/job/OutboxDispatchService.java`, `OS` = `service/OutboxService.java`, `OMR` = `repo/jpa/OutboxMessageRepository.java`, `ODJ` = `schedulejob/OutboxDispatcherJob.java`, `LWC` = OMS `LegacyWmsController.php`. All wms2-api paths are under `src/main/java/net/aim_ai/wms/` unless stated otherwise.

**Superseded approach.** The read-timeout split (`superseded-outbox-read-timeout-split.patch`, review lanes A/B, architect consult) is **not** re-proposed. Review lane B H1 showed that 30 s does not clear the 88–107 KB band. `HttpRestService` stays at 15 s.

---

## §0 Affected sites

Enumerated with `git grep -n "MessageProcessType.ORDER_BATCH_SHIPPED\|ORDER_BATCH_SHIPPED_URL_KEY" -- src/main` (one producer) and `git grep "runShippingPhase("` (2 callers). See analysis §0.

| # | Site | Change |
|---|---|---|
| P1 | `BOLS:799-806`: the single `outboxService.enqueue(... aggregateType("BILL_OF_LADING") ...)` | **Fix A**: chunk it when parcels > K, for REGULAR and HUB_AND_SPOKE only |
| P2 | `closeBOL` (`BOLS:341/351` → `:411`). Accepts REGULAR, TRANSFER_OFFSITE, TRANSFER_INTRACOMPANY, HUB_AND_SPOKE (`:391-400`) | goes through P1. The TRANSFER_* types stay one row |
| P3 | `finishTransfer` path (`BOLS:1576-1578`, `runShippingPhase` for TRANSFER_INTRACOMPANY) | none. OMS `shipTransfer` never iterates parcels (`LWC:2130-2138`) |
| P4 | `ODS.isTerminal` `:299-302`, plus the exception branch `:193` | **Fix C**: per-row attempt budget |
| P5 | `ODS.writeServiceLog` `:277-297`. The `message` row it writes has no link back to the outbox row | **Fix B**: record `outbox_message.last_message_id` |
| P6 | `BillOfLadingController` (`/v3/billOfLading`, `:39`) | **Fix B and Fix D**: two new handlers |
| P7 | `MessageService.resendMessage:162` / `MessageController:62` | none. It replays one attempt's payload, which is now ≤K parcels (≈7.6 s, under 15 s). This also closes lane A M1 |
| P8 | Readers R1–R8 (analysis §0) | R1 forces distinct aggregate ids. R2 and R3 are unaffected (see HSV). R7 tests must stay green. R8: update the docs |
| U1 | `components/outbound/bol/outboundBolDetails.vue`, shared by `pages/outbound/outbound-bol/{open,closed}/_id.vue` (`:14`) | **Fix B and Fix D UI** |
| U2 | `store/outbound/outboundBols.js` (next to `getBolDetails:161`) | two actions |
| U3 | `components/admin/serviceLog/serviceLog.vue` (`showDetails:279`, `mounted:305`) | deep link `?messageId=` |

## §1 Problem

On closing a BOL, WMS sends **one** `ORDER_BATCH_SHIPPED` POST that carries every parcel. OMS `finishedShipping` takes time proportional to the parcel count, about 0.19 s per parcel (analysis §6). Large BOLs therefore exceed the 15 s read timeout. On c1wh ShipItEZ PRD, outbox **11135** (BOL 101226(5), id 121932106) holds 1,528 parcels, 8,346 items and 664 KB. It went `FAILED_TERMINAL` after 5 retries, with 6 `EX` Service Log rows between 23:25 and 23:57 UTC on 2026-10-12. Outbox rows 11089–11092 (281–329 parcels) timed out on their first attempt and then went through on retry (analysis §8). Operators cannot see on the BOL screen whether OMS heard about the shipment, and they have no way to retry it short of the Service Log.

## §2 Root cause

1. **The notification is not bounded.** `BOLS:750-761` builds one `BillOfLadingWebServiceDto` that contains all pallets. `BOLS:789` serializes it, and `BOLS:800-806` enqueues it as one row. No setting caps the size.
2. **The retry budget is about 31 minutes.** Backoff is `min(60 s × 2^attempts, 3600 s)` (`OS:98`), and the row goes terminal at `attempts >= 5` (`ODS:301`, `application.properties:244`). That gives 60+120+240+480+960 s ≈ 31 min, which an OMS outage or a deploy window easily outlasts.
3. **Nothing reports delivery per BOL.** The service-log row (`ODS:279-287`) stores only the payload, the process type and the destination. The outbox row id is not on it, and `MessageRepository.getDetailViewByKeyword` (`:116-121`) cannot search by BOL. `FAILED_TERMINAL` rows are never auto-deleted (`OMR:80-86`), and no UI path requeues them.

## §4 Architecture

```
closeBOL ─► runShippingPhase (one tenant tx)
              build palletDtos ─► palletDtos.isEmpty()? ─ yes ─► skip (SBDEV-2737), no rows
                                       │ no
              type ∈ {REGULAR,HUB_AND_SPOKE} && parcels > K ?
                 no ─► 1 row  BILL_OF_LADING / bol.id / UUID key / lane DEFAULT   (unchanged)
                 yes ─► serialize ALL N chunks first ─► N rows  BILL_OF_LADING_CHUNK
                        id = bol.id×100000+i, key BOL-SHIPPED-<bol.id>-C<i>of<N>, lane CLUB
                                       │ commit
OutboxDispatcherJob ─ lane DEFAULT (ODJ:62) / lane CLUB (ODJ:83) ─► ODS.dispatchBatch(lane)
   claim (OMR:37-58, per-(type,id) gate) ─► POST (15 s) ─► markSent / markRetry / markTerminal
   ─► writeServiceLog ─► [Fix B] link last_message_id (ORDER_BATCH_SHIPPED only)
   [Fix C] chunk rows: terminal at attempts ≥ 29 (≈24 h), others unchanged at 5
BOL detail screen ─► GET  /v3/billOfLading/omsNotificationStatus/{id}   [Fix B]
                  ─► POST /v3/billOfLading/requeueOmsNotification/{id}  [Fix D]
                  ─► link /admin?messageId=… ─► Service Log detail dialog
```

| File | Role |
|---|---|
| `BOLS` `runShippingPhase:444`, enqueue `:779-807` | producer |
| `service/BolShippedNotificationChunker.java` (**new**) | pure splitter and K resolver |
| `OS`, `ODS`, `OMR`, `model/OutboxMessage.java` | outbox state machine, claim, retention |
| `ODJ:62-86,102-171` | lane consumers (DEFAULT has housekeeping, CLUB has none) |
| `service/BolOmsNotificationService.java` (**new**) | status read and requeue |
| `controller/BillOfLadingController.java` | two handlers |
| `db/migration/V2.2.39__bol_shipped_chunk_size_and_outbox_message_link.sql` (**new**) | sysprop seed and nullable column |

## §5 Fix design

### Fix A: chunk the notification (D1, D2, D7)

**Before:** `BOLS:800-806` enqueues one row for the whole BOL.

**After:** `BolShippedNotificationChunker.split(dto, k)` returns `List<BillOfLadingWebServiceDto>`:
- It walks the parcels (`OrderDto`) in order and cuts every K. A parcel is never split from its items.
- A pallet that straddles a cut is copied into each chunk with the same `pallet_label`.
- Every chunk has the full header and the same `bol_id`.
- Slices are new lists, never `subList` views.
- It never emits a chunk that holds only empty pallets.

`runShippingPhase` calls it only when `type ∈ {REGULAR, HUB_AND_SPOKE}` **and** total parcels > K. In that case:
- It serializes **every** chunk before enqueueing any of them. Any failure throws `FacadeException`, which rolls back the close (SBDEV-2221). The `serialize_failed` counter increments once per BOL.
- It enqueues N rows: `aggregateType("BILL_OF_LADING_CHUNK")`, `aggregateId(bol.getId() * 100_000L + i)`, `idempotencyKey("BOL-SHIPPED-" + bol.getId() + "-C" + i + "of" + n)`, `lane(LANE_CLUB)`.
- The key is at most 45 chars, under the 64 limit checked at `OS:52`.
- It throws if `n > 99_999`.

The DTO gains `@JsonProperty("chunk_index")` and `chunk_count` (Integer), both with `@JsonInclude(NON_NULL)`. The ≤K payload therefore stays **byte-identical**, and OMS ignores unknown keys (analysis §2).

K is `resolveBolShippedOmsChunkSize()`, read **once** per close from `WMS_BOL_SHIPPED_OMS_CHUNK_SIZE`, using the club resolver's shape (`CustomerorderBatchService:680`):
- missing, blank, unparseable or <1 → 40, with a WARN
- >60 → 60, with a WARN
- the read never throws

**Why not the alternatives:**
- Same aggregate id for every chunk: one terminal chunk wedges the others (`OMR:46-52`).
- Splitting by pallet: one pallet can hold hundreds of parcels, and OMS cost scales with parcels (`LWC:2418-2424`).
- Chunking the transfer types: OMS never iterates parcels there.
- Longer read timeout: superseded (lane B H1).

### Fix B: per-BOL OMS confirmation status (D3)

**Before:** none exists. The service-log `message` row cannot be traced back to its outbox row.

**After:**
1. **Link column.** V2.2.39 runs `ALTER TABLE outbox_message ADD COLUMN IF NOT EXISTS last_message_id bigint` (nullable, no FK, metadata-only in PG). `OutboxMessage.lastMessageId` maps it.
   - In `ODS.dispatchOne`, after each `writeServiceLog` and **only for `ORDER_BATCH_SHIPPED`**, call the new `OS.linkServiceLog(outboxId, messageId)` (REQUIRES_NEW, one `UPDATE`).
   - `writeServiceLog` returns the saved `Message` id, or null.
   - The link is best-effort and wrapped in try/catch, like `:288-296`, so a link failure can never reach `dispatchOne`'s catch. The existing `markSent/markRetry/markTerminal` order is unchanged.
2. **Query.** The new `OMR.findBolNotificationRows(bolId)` is native SQL:

   ```sql
   (aggregate_type='BILL_OF_LADING' AND aggregate_id=:bolId)
   OR (aggregate_type='BILL_OF_LADING_CHUNK' AND aggregate_id BETWEEN :bolId*100000 AND :bolId*100000+99999)
   ```

   It is served by `index_outbox_message_aggregate_order (aggregate_type, aggregate_id, id, status)` (onboarding `V2.1.14`). It `LEFT JOIN`s `message m ON m.id = o.last_message_id` and returns `messagePresent`.
3. **Service.** `BolOmsNotificationService.status(bolId)` runs under `@Transactional(value="tenantTransactionManager", readOnly=true)`.
   - N comes from `chunk_count`, parsed from a chunk row's key (`…of<N>`). A `BILL_OF_LADING` row gives N = 1. No rows means N is unknown.
   - `failed` counts `FAILED_TERMINAL` rows. `pending` counts `PENDING`, `IN_FLIGHT` and `FAILED_RETRY` rows.
   - `confirmed = N − pending − failed`. This count includes SENT rows that have since been purged. That is sound because rows leave the table **only** as `SENT` (`OMR:84-86`), plus the Fix D-ii delete, which replaces the row with chunks in the same tx.
   - `state` is one of: `NOT_SHIPPED` (BOL not CLOSED/TRANSFER), `CONFIRMED`, `PENDING`, `FAILED`, or `NO_RECORD`. `NO_RECORD` means a closed BOL with no rows retained. Its UI text: *"No outstanding OMS notification. Sent rows are purged after 7 days, and empty BOLs send none (SBDEV-2737)."*
   - The response carries `retentionDays` (`app.outbox.dispatcher.retention-days`) and `failedChunks[]`, each with `{outboxId, chunkIndex, chunkCount, attempts, nextAttemptAt, lastError (abbrev 300), lastMessageId, messagePresent}`.
   - "Confirmed" means **HTTP 2xx**. Body-level `Status:Error` stays with SBDEV-2736 (D6), and the UI labels it "Delivered (HTTP 2xx)".
4. **Endpoint.** `@RequiresFunction(WEB_UI_VIEW_BILL_OF_LADING) @GetMapping("/omsNotificationStatus/{id}")` on `BillOfLadingController`. It inherits `/v3` from `:39`. An unknown BOL id returns 404 via `EntityNotFoundException`.
5. **UI.**
   - `outboundBolDetails.vue` gains an "OMS notification" row in the second column (after `:73`). It shows, for example, `38/39 delivered · 1 failed`, or the `NO_RECORD` text.
   - It also shows a failed-chunk list. Each item links to the Service Log, but only if `$store.state.functions` includes `WEB_UI_VIEW_MESSAGES` (the pattern at `pages/admin.vue:93-94`). The link commits `admin/setParentTab` to 6 (canonical Service Log, `admin.vue:62`) and pushes `/admin?messageId=<id>`.
   - `serviceLog.vue` `mounted()` calls `showDetails({id})` when `$route.query.messageId` is numeric.
   - The status is fetched from a `watch` on `outboundBol.id`, so both pages get it without duplicating the call.

**Why not the alternatives:**
- Matching `message` rows by payload `LIKE`: a seq scan over a large text column, which breaks the moment a payload changes.
- A `message.outbox_message_id` column: `message` is the large table and would need a concurrent index, and the link is lost once the outbox row is purged anyway.
- Persisting N on `billoflading`: a second schema change to a hot table, when N is already in the key.

### Fix C: about 24 h of retries for every BOL-shipped notice (D4)

**Before:** `ODS:181` and `ODS:193` both terminate at `maxAttempts` (5).

**After:** a private `int maxAttemptsFor(OutboxMessage m)` returns `bolShippedMaxAttempts` when `WmsConstants.MessageProcessType.ORDER_BATCH_SHIPPED.equals(m.getProcessType())`, and `maxAttempts` otherwise. That covers chunk rows, the single ≤K `BILL_OF_LADING` row, and transfer BOLs alike (Nam, 2026-10-13: a shipped notice lost after ~31 min is the same loss at any size). Both branches use it. 400, 404 and 422 still go terminal immediately (`:300`).
- New property: `app.outbox.dispatcher.bol-shipped-max-attempts=29`, read via `@Value(...:29)`.
- Arithmetic: the delays for attempts 0–5 add up to 3,780 s. Each attempt from 6 to 28 waits the 3,600 s cap, so the total is 3,780 + 23 × 3,600 = 86,580 s ≈ 24.05 h over 30 POSTs.
- The backoff formula and its 1 h cap already exist (`OS:97-98`), so there is no change there.
- **Unchanged:** `STALE_INFLIGHT_TIMEOUT` (`ODS:71`), because each POST is still bounded at 5 + 15 s. The stuck-aggregate gauge (`OMR:102-115`) needs a lower-id terminal sibling, and a chunk aggregate has one row.

**Why not the alternatives:** a global `max-attempts` raise would retry poisoned pick/pack payloads for 24 h (D4 excludes it). Keying on aggregate type would have left the ≤K single row at 5 attempts, which Nam rejected. A time-based terminal would need a `created_at` comparison, which the count-based design does not have.

### Fix D: requeue a BOL's failed chunks (D5)

**After:** `@RequiresFunction(WEB_UI_VIEW_BILL_OF_LADING) @PostMapping("/requeueOmsNotification/{id}")` → `BolOmsNotificationService.requeue(bolId)`, under `@Transactional(value="tenantTransactionManager")`.

- **D-i (normal).** One native `UPDATE` on the Fix B row set, `WHERE status='FAILED_TERMINAL'`. It sets:
  - `status='FAILED_RETRY'`
  - `attempts=0`
  - `next_attempt_at=NOW()`
  - `modified_at=NOW()`
  - `last_error = COALESCE(last_error,'') || ' [requeued by <user> <ts>]'`

  Idempotency keys stay untouched. It returns `{requeued: n}`. A second click matches 0 rows, so it is idempotent. The dispatcher never claims `FAILED_TERMINAL`, so the dispatcher cannot race the update (`OMR:44`). The requeue logs INFO with user and count, and increments the counter `wms2.outbox.requeued{aggregate_type}`.
- **D-ii (legacy oversized single row; this is what replays 11135).** The condition is: the row set is exactly one `BILL_OF_LADING` row, `FAILED_TERMINAL`, whose payload has `outbound_bol_type ∈ {REGULAR, HUB_AND_SPOKE}` and parcels > K. In that case, in **one** tx:
  1. deserialize the payload into `BillOfLadingWebServiceDto`
  2. `split` it with the same chunker
  3. enqueue the N chunk rows (Fix A shape)
  4. `DELETE` the original row
  5. log the original id and payload size at WARN

  This keeps the "a BOL is either all `BILL_OF_LADING` or all chunks" invariant (analysis §4). The audit trail is the six `message` rows that stay in the Service Log. Transfer payloads are never re-chunked; they get D-i.
- **The gate is the screen's own function, WEB_UI_VIEW_BILL_OF_LADING**, which already gates `closeOutboundBol` (`BillOfLadingController:237-238`), the action that emitted the notification in the first place.
  - **sb_admin-only is rejected.** It is the retired anti-pattern (plan template §5.1 row 7; memory *wms2-authz-axis-keycloak-coarse-functions-fine*).
  - **A new `WEB_UI_ACTION_*` is rejected.** It needs three artifacts: a constant, a Flyway grant, and an `initDB` line at `UtilRestController:353`. Any role that can close a BOL could re-emit the same idempotent notification by closing anyway. SBDEV-3017 §9.16 Option B is the standing rule. The only exception to it, SBDEV-3606, does not generalise.
- **UI.** A "Requeue failed OMS chunks" button appears when `failed > 0`. A confirm dialog shows the count, then it refreshes the status.

## §6 File change summary

| Repo | File | Change |
|---|---|---|
| api | `service/BillofladingService.java` | chunk branch at `:786-807`; resolver |
| api | `service/BolShippedNotificationChunker.java` | **new**, pure |
| api | `json/BillOfLadingWebServiceDto.java` | +`chunk_index`, `chunk_count` (NON_NULL) |
| api | `service/WmsConstants.java` (after `:1397`) | `SYSTEM_PROPERTY_BOL_SHIPPED_OMS_CHUNK_SIZE_KEY` / `_DEFAULT_VALUE="40"`; `BOL_SHIPPED_CHUNK_AGGREGATE_TYPE` |
| api | `model/OutboxMessage.java` | +`lastMessageId` |
| api | `service/OutboxService.java` | +`linkServiceLog` |
| api | `service/job/OutboxDispatchService.java` | `maxAttemptsFor`; link after service log |
| api | `repo/jpa/OutboxMessageRepository.java` | +`findBolNotificationRows`, +`requeueBolTerminal` |
| api | `service/BolOmsNotificationService.java` | **new**: status and requeue |
| api | `controller/BillOfLadingController.java` | +2 handlers |
| api | `resources/application.properties` (`:244`) | +`bol-shipped-max-attempts=29` |
| api | `db/migration/V2.2.39__bol_shipped_chunk_size_and_outbox_message_link.sql` | sysprop seed (shape of `V2.2.29:37-50`) + `ADD COLUMN` |
| ui | `components/outbound/bol/outboundBolDetails.vue` | status row, failed list, requeue button |
| ui | `store/outbound/outboundBols.js` | `getBolOmsStatus`, `requeueBolOms` |
| ui | `components/admin/serviceLog/serviceLog.vue` | `?messageId` deep link |
| docs | `wms2-bol-truck-loading-workflow.md:44,114,313-329`, `wms2-oms-integration-map.md:112` | correct the stale "post-commit, closeBOL line 653"; describe chunking |

## §7 Implementation steps

### Prerequisites

| # | Prerequisite | Required value / action |
|---|---|---|
| 1 | DB state | Flyway at V2.2.38 on every tenant. Before pushing, re-sweep all remote branches for V2.2.39 (memory: *flyway-version-pick-sweep-all-remote-branches*). Rename it if it has been taken. |
| 2 | Sysprops | `WMS_BOL_SHIPPED_OMS_CHUNK_SIZE=40` is seeded by V2.2.39. Fallback is 40, ceiling 60. No per-tenant change is needed. Hydra has zero BOLs >40 (analysis §6). |
| 3 | Config | `app.outbox.dispatcher.bol-shipped-max-attempts=29`. No env override. |
| 4 | Deploy order | **wms2-api first.** A merge to develop deploys and runs Flyway. Then wms2-web-ui. The UI must tolerate a 404 from `/omsNotificationStatus` and hide the row, so the reverse order degrades gracefully. |
| 5 | Data migration | None for the schema. For 11135, see step 6. |
| 6 | External systems | OMS: no change. It ignores the extra keys and skips already-shipped parcels (`LWC:2313-2319,2426-2432`). **R-1 is open:** we do not know which merchants have `outbound_bol_close` configured. Each chunk can fire one callback (`LWC:2523`). |
| 7 | Access | No new function. Both endpoints use `WEB_UI_VIEW_BILL_OF_LADING`, and the Service Log link needs `WEB_UI_VIEW_MESSAGES`. |
| 8 | Monitoring | Existing `wms2.outbox.dispatched{outcome}` and `tick_duration{lane=CLUB}`, plus the new `wms2.outbox.requeued`. Metrics are not scraped (memory). The SBDEV-3325 egress watchdog `failing` streak still fires on a dead endpoint, because a chunk's per-attempt `message` rows feed it. |

### Steps

1. **API, chunker and producer (Fix A).** Worktree `.claude/worktrees/wms2-api/SBDEV-3672`, branch `fix/SBDEV-3672-chunk-bol-shipped`.
   - Write the failing tests first (§8 U1–U9).
   - Then add the chunker, DTO fields, constants, resolver and the `BOLS` branch.
   - **AC-A:** ≤K → exactly one row, identical to today's. >K → ⌈n/K⌉ rows with the ids, keys and lane above. Transfer >K → 1 row.
2. **API, Flyway V2.2.39 + link column + retry budget (Fixes B-1, C).**
   - Add the seed-consistency test.
   - Add `linkServiceLog` and `maxAttemptsFor`.
   - **AC-C:** a chunk row goes terminal only at attempts 29. A `CUSTOMER_ORDER` row still goes terminal at 5.
3. **API, status + requeue (Fixes B-2..4, D).**
   - Add the repository queries, the service and the controller.
   - **AC-B:** status counts are correct before **and after** a SENT purge.
   - **AC-D:** requeue flips only this BOL's terminal rows, and D-ii re-chunks in one tx.
4. **API close-out.**
   - Run `mvn clean verify` and compare against the suite baseline.
   - Mutation-check every new assertion.
   - Run code review with 4 lanes and fix every finding, including Low.
   - Open a PR into develop.
5. **UI.** Create worktree `.claude/worktrees/wms2-web-ui/SBDEV-3672` off fresh `origin/develop`.
   - Write the Jest tests first (§8 J1–J5), then the component, store and service-log changes.
   - Run `yarn test` against the baseline. Open a PR into develop **after** the API PR merges.
6. **Post-deploy replay of BOL 101226(5)** (c1wh-shipitez PRD, after the PRD release; release/main is a devops task).
   - Open the closed BOL detail for id 121932106 and click Requeue. D-ii turns outbox 11135 into 39 chunk rows of ≤40 parcels in the CLUB lane.
   - Verify with `select status,count(*) from outbox_message where aggregate_type='BILL_OF_LADING_CHUNK' and aggregate_id between 12193210600000 and 12193210699999 group by 1`. Expected: `SENT = 39` within about 5 min.
   - Spot-check OMS parcel statuses for 3 unique_ids.
   - If R-1 shows that the merchant has `outbound_bol_close` configured, warn them first.
7. **Docs.** Update the two docs listed in §6 and run `verify-docs`.

## §8 Testing plan

**Unit (wms2-api)**

| # | Class#method | Asserts |
|---|---|---|
| U1 | `BolShippedNotificationChunkerUnitTest#splitsEveryKParcelsKeepingItemsWithTheirParcel` | 95 parcels at K=40 → 40/40/15. Every parcel appears exactly once, in order. |
| U2 | `…#straddlingPalletIsCopiedWithSameLabel` / `#neverEmitsEmptyPalletOnlyChunk` / `#slicesAreCopiesNotViews` | split rule |
| U3 | `…#everyChunkCarriesFullHeaderAndSameBolId` | header fields equal |
| U4 | `BillofladingServiceUnitTest#closeBol_atOrBelowK_enqueuesTodaysSingleRow` | type, id, UUID key, DEFAULT lane. Payload has no `chunk_` keys. Extends `:3046-3070`. |
| U5 | `…#closeBol_aboveK_enqueuesChunkRowsWithKeysUnder64` | `BILL_OF_LADING_CHUNK`, ids `bolId×100000+i`, keys `BOL-SHIPPED-<id>-C<i>of<N>`, lane CLUB |
| U6 | `…#hubAndSpokeAboveK_isChunked` / `#transferOffsiteAndIntracompanyAboveK_stayOneRow` | type filter |
| U7 | `…#anyChunkSerializeFailure_enqueuesNothingAndThrows` | extends `:3122-3127` |
| U8 | `…#chunkSizeSysprop_blankGarbageZeroFallBackTo40_above60ClampsTo60` | resolver. The 61 case is mutation-checked. |
| U9 | `BolShippedOmsChunkSizeSeedConsistencyTest#seedMatchesConstant` | mirrors `ClublineOmsChunkSizeSeedConsistencyTest` |
| U10 | `OutboxDispatchServiceUnitTest#bolShippedChunkRow_retriesUntil29Attempts` / `#bolShippedSingleRow_retriesUntil29Attempts` / `#otherProcessType_stillTerminalAt5` / `#bolShipped400_isTerminalImmediately` | Fix C, both branches (`:181`, `:193`); keyed on process type, so the ≤K single row is covered (D4) |
| U11 | `OutboxDispatchServiceUnitTest#bolShippedRow_linksServiceLogId` / `#linkFailure_doesNotChangeOutcome` / `#otherProcessTypes_notLinked` | Fix B-1 |
| U12 | `BolOmsNotificationServiceUnitTest#confirmedCountsPurgedSentRows` / `#noRowsClosedBol_isNoRecord` / `#openBol_isNotShipped` / `#unchunkedTransferRow_countsAsOne` | status math |
| U13 | `BolOmsNotificationServiceUnitTest#requeueLegacyOversizedRegular_rechunksAndDeletesOriginal` / `#legacyTransfer_isPlainRequeue` | D-ii |
| U14 | `BillOfLadingControllerUnitTest#omsNotificationStatus_isGatedOnViewBillOfLading` / `#requeue_isGatedOnViewBillOfLading` / `#requeue_isPost` | annotation-level. `standaloneSetup` cannot see the gate (memory), so `ControllerRequestMappingConventionUnitTest` covers `/v3`. |

**Integration (Testcontainers PG, failsafe `*IT`, Flyway via `OutboxItFlyway.migrateProduction`)**

| # | Class#method | Asserts |
|---|---|---|
| I1 | `BolChunkOutboxClaimIT#terminalChunkDoesNotHoldSiblings` | one chunk `FAILED_TERMINAL`; `findAndClaimPending(…, "CLUB")` claims the rest |
| I2 | `BolChunkOutboxClaimIT#defaultLaneNeverClaimsChunkRows` | lane isolation |
| I3 | `BolOmsNotificationRowsIT#findsBothShapesOnlyForThisBol` | neighbour BOL ids `bolId±1` and a `CLUB_BATCH_CHUNK` with the same numeric id are excluded. Asserts by id; repository tests commit (memory). |
| I4 | `BolOmsNotificationRowsIT#requeueFlipsOnlyTerminalRowsAndKeepsKeys` | statuses, attempts=0, keys unchanged, a second call returns 0 |
| I5 | `BolOmsNotificationRowsIT#lastMessageIdLeftJoinReportsPurgedMessage` | `messagePresent=false` |
| I6 | `OutboxMigrationV2239IT#addsNullableColumnAndSeedIsIdempotent` | column exists and is null for old rows. A re-run inserts no second sysprop. |

**Regression (must stay green, unchanged):**
- `FinishTransferPreTransferCloseIT:185-190` (exactly one row)
- `BillofladingServiceFinishTransferIT:170-187` (seed the chunk sysprop)
- `BillofladingServiceUnitTest` `never().enqueue` cases (`:395,410,468,1864-1995,3127,3502`) and `:1783 times(2)`
- `OutboxLaneClaimIT`, `OutboxTerminalHoldIT`, `OutboxStuckAggregateIntegrationTest`

**Jest (wms2-web-ui)**

| # | Spec | Asserts |
|---|---|---|
| J1 | `test/components/outbound/outboundBolOmsStatus.spec.js` | renders "38/39 delivered · 1 failed". `NO_RECORD` shows the retention text. `NOT_SHIPPED` hides the row. A 404 hides the row. |
| J2 | same | Requeue button only when `failed>0`. Confirm dispatches `requeueBolOms`, then re-fetches. |
| J3 | same | Service Log link only when `functions` includes `WEB_UI_VIEW_MESSAGES`. The click commits `admin/setParentTab` 6 and pushes `/admin?messageId=…`. |
| J4 | `test/components/admin/serviceLogDeepLink.spec.js` | numeric `messageId` → `getLogDetail` with that id. A non-numeric value is ignored. |
| J5 | `test/store/outboundBolsOmsStatus.spec.js` | GET `/billOfLading/omsNotificationStatus/{id}` and POST `/billOfLading/requeueOmsNotification/{id}` (relative to the `/v3` baseURL) |

**Manual test plan**

| Scenario | Environment | Steps | Expected | Pass/Fail |
|---|---|---|---|---|
| ≤K BOL | wms2 dev | Close a REGULAR BOL with 10 parcels | 1 `BILL_OF_LADING` row in DEFAULT lane; screen shows 1/1 delivered | |
| >K BOL | wms2 dev | Close a REGULAR BOL with 95 parcels | 3 chunk rows in CLUB lane, all SENT; OMS ships all 95 | |
| OMS down | wms2 dev | Point the shipped URL at a dead host, close a 95-parcel BOL | rows are FAILED_RETRY with growing backoff; screen shows "pending" | |
| Requeue | wms2 dev | Force a chunk to FAILED_TERMINAL, click Requeue | row returns to FAILED_RETRY → SENT; the key is unchanged | |
| Service Log link | wms2 dev | Click the failed chunk link | Admin › Service Log opens that message's detail | |
| Legacy re-chunk | wms2 dev (11135 payload copied in) | Requeue | 39 chunk rows; original deleted | |
| Transfer | wms2 dev | Close a TRANSFER_OFFSITE BOL with >40 parcels | 1 `BILL_OF_LADING` row | |

## §9 Risks & mitigations

| # | Risk | Mitigation |
|---|---|---|
| R-1 | Merchant `outbound_bol_close` callback fires once per chunk | Open. Query OMS tenant config before the PRD release. If any merchant has it configured, tell them or debounce on the OMS side (follow-up). |
| R-2 | Partial visibility: some chunks fail | This is the point of Fix B/C/D. Each chunk is independently resendable and requeueable. |
| R-3 | A 39-chunk BOL occupies the CLUB lane for about 5 min (39 × 7.6 s) | Club and BOL rows are both bulk traffic. The DEFAULT lane (pick/pack/QA) is untouched. A dedicated lane is the fallback (§10 D7). |
| R-4 | Chunk replay order | OMS is order-independent: it skips already-shipped parcels and treats NOOP as success (analysis R-4). |
| R-5 | K changes mid-close | K is read once per close. |
| R-6 | D-ii deletes a FAILED_TERMINAL row | Only in the same tx that inserts its replacement chunks. The `message` rows keep the audit trail. Covered by U13 and the manual row. |
| R-7 | 24 h retries inflate Service Log rows: up to 30 per failing chunk | Accepted. Message retention cleanup (`MessageRepository:99-102`) bounds them, and the watchdog streak becomes a stronger signal. |
| R-8 | An extra `UPDATE` per BOL-shipped dispatch (link) | Limited to `ORDER_BATCH_SHIPPED`, best-effort. Throughput impact is negligible (≤ chunks per BOL). |

## Horizontal Scalability Validation

| Concern | Affected? | Evidence |
|---|---|---|
| In-JVM state | No | The chunker is pure. K comes from the tenant-keyed Caffeine sysprop cache (`SyspropService:106`) and is read once per close. |
| Pool math | No | No new long transactions. The link is one short REQUIRES_NEW UPDATE in Phase 2, with no transaction held across HTTP (`ODS:152-157`). |
| Scheduled jobs | Yes, existing CLUB lane | `ODJ:83-86` uses its own advisory lock `OUTBOX_DISPATCHER_CLUB`, so only one replica runs it per tick. There is no new job and no landlord-pool change (`ODJ:91-97`). |
| Long tx | No | Close tx gains N inserts (39 for 1,528 parcels), fewer bytes than today's single 664 KB row. Requeue is one UPDATE. |
| Request affinity | No | Both endpoints are stateless. |
| Retry / idempotency | Yes | Deterministic keys per chunk (D2). Requeue preserves the keys. OMS skips already-shipped parcels. A stale reclaim is lane-scoped (`OS:125-135`). |
| Tenant context | No | Close and HTTP endpoints run under `TenantFilter`. The dispatcher sets it per tenant (`ODJ:138`). |
| Distributed locks | No | No new lock. The requeue UPDATE is guarded by `status='FAILED_TERMINAL'`, so concurrent clicks are idempotent. |
| Cache invalidation | No | The new sysprop is read through the existing `sysprops` cache. An edit via the admin UI evicts as it does for any sysprop. |
| External notifications | Yes | N POSTs per BOL instead of 1. R-1 callbacks. Each POST is bounded at 5 + 15 s, and `STALE_INFLIGHT` holds (25 × 20 s = 500 s < 900 s). |

## v2 constraint checklist

| Constraint | Status |
|---|---|
| OSIV | `spring.jpa.open-in-view=false` (`application.properties:85`). The status service returns DTOs built inside its readOnly tx. |
| `tenantTransactionManager` | Every new `@Transactional` names it, like `OS:41` and `BOLS:351`. |
| readOnly | `status()` is `readOnly=true`. `requeue()` is not. Tx tests cannot see propagation or readOnly (memory), so they are pinned by annotation assertions in U12. |
| Caffeine eviction | No new cache. |
| jakarta | New entity field uses `jakarta.persistence.Column`. |
| H2 SQL | New native queries are PG-only and tested in a Testcontainers IT, not on H2. The H2 lane picks up the new nullable column through DDL auto. |
| BaseControllerTest | It does not exist. Use the `BillOfLadingControllerUnitTest` / `BaseControllerUnitTest` pattern. |
| Micrometer | New counter `wms2.outbox.requeued{aggregate_type}`, with no null tags. Existing tags are unchanged (analysis R4). |

## Completeness checklist

| # | Item | Status |
|---|---|---|
| 0 | Affected sites enumerated by grep (§0) | done |
| 1 | DB query confirming the symptom | done: analysis §8 (11135) plus a 2026-10-13 estate census. Exactly 1 `BILL_OF_LADING` `FAILED_TERMINAL` row exists (c1wh). WineCo and Hydra have 0. |
| 2 | Root cause traced to file:line | §2 |
| 3 | Sibling sweep (other producers, readers) | §0 P1–P8, analysis R1–R8 |
| 4 | Invariant over instance | The split covers every BOL >K. Retry and requeue cover every chunk, not just 11135. |
| 5 | Failing test first, per AC | §8 U/I/J |
| 6 | Mutation-check plan | every new assertion. Specifically: K clamp 60, `maxAttemptsFor` type check, the `NON_NULL` annotation, the requeue status guard |
| 7 | Flyway version swept across branches | V2.2.39 (analysis §5). Re-sweep before push. |
| 8 | Cross-repo deploy order | API → UI (§7 Prereq 4) |
| 9 | Docs to update | §6 docs row |
| 10 | Independent review | 4 lanes (T3), each writing to a file in `SBDEV-3672-evidence/` |

## §10 Resolved decisions + ADR

| # | Decision | By |
|---|---|---|
| D1 | Chunk REGULAR and HUB_AND_SPOKE at K=`WMS_BOL_SHIPPED_OMS_CHUNK_SIZE` (seed 40, fallback 40, clamp 60, WARN). ≤K stays exactly today's single row. Chunk aggregate is `BILL_OF_LADING_CHUNK`, id `bolId×100000+i`. Read timeout stays 15 s. | Nam |
| D2 | Key `BOL-SHIPPED-<bol.id>-C<i>of<N>`, plus additive `chunk_index`/`chunk_count`. `bol.id` is the DB pk, not the name, because `bol_id` in the payload is `getName()` (`BOLS:753`) and is not guaranteed unique. | Nam (pk choice: planner) |
| D3 | Status endpoint and UI on the open/closed detail screens. After purge, behaviour is `confirmed = N − pending − failed`, and no rows means `NO_RECORD`. | Nam (purge semantics: planner, **needs confirmation**) |
| D4 | 29 attempts (≈24 h), backoff cap 1 h, for **every `ORDER_BATCH_SHIPPED` row**: chunks, the ≤K single row, and transfers. Other process types stay at 5. | Nam (2026-10-13, incl. the ≤K extension) |
| D5 | Requeue gated on `WEB_UI_VIEW_BILL_OF_LADING`, plus D-ii re-chunk for a legacy oversized row | Nam (2026-10-13: scope, gate and D-ii confirmed) |
| D6 | Scope E (body-level `Status:Error`) stays on SBDEV-2736 | Nam |
| D7 | Chunk rows go on **LANE_CLUB**. **Confirmed by Nam 2026-10-13.** Evidence: the CLUB consumer is the generic `dispatchBatch` (`ODJ:85,139`) with no housekeeping (`ODJ:79-81`), and `lane` is referenced only by club enqueue sites (`CustomerorderBatchService:889,900,916,1034`). Reclaim is lane-scoped (`OS:125-135`). PRD CLUB volume is 4,557 (c1wh) and 2,385 (WineCo) rows per 7 days. | Nam (2026-10-13) |

**ADR**
- **Decision:** bound each OMS shipped call to ≤K parcels by chunking at the producer. Make delivery observable and recoverable per BOL (status, 24 h retries, requeue). Leave transport timeouts alone.
- **Drivers:** (1) OMS cost is linear in parcels, so no WMS timeout under nginx's 60 s clears 1,528 parcels. (2) Every chunk must be independently retryable, without one chunk wedging the others. (3) Operators must see and fix a partial failure from the BOL screen.
- **Alternatives:**
  - (a) Longer read timeout: superseded. Lane B H1 found 88–107 KB needs at least 38 s, and 664 KB is over 60 s.
  - (b) OMS async (SBDEV-3754): the real long-term fix, but in another repo and not scheduled.
  - (c) Chunking by pallet: unbounded parcels per pallet.
  - (d) A dedicated BOL lane: one more advisory lock, one more cron, and +2 landlord connections (`ODJ:91-97`) for low-volume traffic.
- **Why chosen:** the smallest change that bounds the call at its source. It reuses the proven club-chunk pattern (`CustomerorderBatchService:1034-1036`, the same id span), and it needs no OMS change.
- **Consequences:**
  - A BOL becomes 1..N outbox rows.
  - N merchant callbacks are possible (R-1).
  - CLUB lane load rises (R-3).
  - The outbox gains a nullable `last_message_id`.
  - The Service Log gains up to 30 rows per failing chunk.
- **Follow-ups:**
  - R-1 merchant census.
  - SBDEV-3754 OMS async.
  - SBDEV-2736 body-level verdicts.
  - If R-3 shows club latency complaints, revisit D7 with a dedicated lane.
