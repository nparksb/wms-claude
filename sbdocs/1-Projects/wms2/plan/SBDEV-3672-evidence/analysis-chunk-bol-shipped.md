---
ticket: SBDEV-3672
kind: analysis (T3, read-only)
date: 2026-10-13
base: wms2-api origin/develop a4fd6490 · oms-laravel-api origin/develop 9e24cdfa
author: executor (opus) analysis lane; saved by the main session because the harness blocked the subagent's write
db_verified: true
---

# SBDEV-3672 — analysis: chunk the ORDER_BATCH_SHIPPED notification

`BOLS` = `src/main/java/net/aim_ai/wms/service/BillofladingService.java`; `LWC` = OMS `app/Http/Controllers/Api/Legacy/LegacyWmsController.php`.

## §0 Affected sites (enumeration)

Producers: `git grep -n "MessageProcessType.ORDER_BATCH_SHIPPED\|finishedShipping\|ORDER_BATCH_SHIPPED_URL_KEY" -- src/main` → one producer, `BOLS:799-806`. `git grep "runShippingPhase("` → 2 callers.

| # | Site | In scope | Why |
|---|---|---|---|
| P1 | `BOLS:444` runShippingPhase, enqueue `:800-806` | **yes** | sole producer; `BILL_OF_LADING`, aggId = bol.id, no idempotency key (OutboxService:48-49 assigns UUID) |
| P2 | closeBOL (`BOLS:342/352`) → `:411` | **yes — REGULAR + HUB_AND_SPOKE only** | 4 types accepted (`:391-400`); OMS HUB_AND_SPOKE only logs then takes the regular path (`LWC:2181-2188`) |
| P3 | finishTransfer (`BOLS:1521`) → `:1578` | no | only TRANSFER_INTRACOMPANY (`:1533-1535`); OMS shipTransfer never iterates parcels (`LWC:2130-2138`) |
| P4 | transferOrder (`BOLS:845`, SBDEV-3311) | no | enqueues CUSTOMER_ORDER RELEASED/STARTED (`:1085`), not SHIPPED |
| P5 | MessageService.resendMessage:162 / MessageController:62 | no change | each outbox attempt writes its own `message` row (OutboxDispatchService:277) → a resend replays one chunk |
| P6 | UtilRestController:174 | no | commented-out code |

Readers affected by one BOL → N rows:
- R1 `findAndClaimPending` (OutboxMessageRepository:37-58) gates on a lower-id same (type,id) row in PENDING/FAILED_RETRY/IN_FLIGHT/**FAILED_TERMINAL** → chunks need distinct aggregate ids.
- R2 stuck-aggregate gauge (`:102-115`): single-row chunk aggregates never register; no change.
- R3 `scripts/oms-egress-watchdog/egress-failures.sql`: keys on `message` × process type (0 refs to aggregate_type) → still alerts per failing chunk.
- R4 metrics `skipped_empty`/`serialize_failed` tagged BILL_OF_LADING (`BOLS:782-795`): keep — BOL-level events.
- R5 dispatcher batch sort (OutboxDispatchService:142-150): harmless.
- R6 no controller uses OutboxMessageRepository.
- R7 tests: `FinishTransferPreTransferCloseIT:185-190` (exactly 1 row; transfer → stays valid); `BillofladingServiceUnitTest:3046-3070` (single row ≤K).
- R8 docs already stale: `wms2-bol-truck-loading-workflow.md:44,114,313-329` ("post-commit, closeBOL line 653"), `wms2-oms-integration-map.md:112`.

## §2 Payload shape and split rule

- `BillOfLadingWebServiceDto` header: bol_id, shared_unique_bol_id, tracking_device_id, transfer_id, carrier_id, truck_id, seal_id, outbound_bol_type, source_warehouse, destination_warehouse (bol_name exists, never set) + `positions: [PalletDto]` (`BOLS:750-761`).
- `PalletDto`: pallet_label + `positions: [OrderDto]` (`:582-584,:652`).
- **OrderDto = parcel**: unique_id = customerOrder.externalnumber (`:608`), parcel_external_number, manifest_location, shippers_id, `positions: [OrderPositionDto]` (`:606-626`).
- OrderPositionDto = item line: unique_id = orderPosition.externalid (`:644`), sku_id, amount.
- OMS reads only the parcel-level unique_id (`LWC:2226-2236` collect; loop `:2264-2271`); never reads a parcel's `positions` or `pallet_label` (0 hits in `LWC:2055-2560`).
- ~6.5 unique_id per parcel: 11135 has 1,528 parcels + 8,346 items → (1,528+8,346)/1,528 = 6.46.

Split rule: walk parcels in order, cut every K, never split a parcel from its items; a straddling pallet is copied into each chunk with the same pallet_label; every chunk carries the full header and same bol_id (OMS uses it for logs + labelGuard->recordBlocked); count parcels not pallets; never emit an empty-pallets-only chunk; chunk only when total > K; build slices as copies, not subList views (CustomerorderBatchService:996-1000).

## §3 Outbox mechanics per chunk

- Ordering gate → distinct aggregate id per chunk, else one FAILED_TERMINAL chunk wedges the rest (terminal rows never auto-deleted, Repo:81-82).
- Idempotency key unique, ≤64 chars (OutboxMessage:75). Proposed `BOL-SHIPPED-<bolId>-C<i>` (≤28). ≤K path keeps today's UUID. No double enqueue today: closeBOL returns early on CLOSED (`BOLS:381-386`).
- Lane DEFAULT per decided design (cost R-3).
- Retention: SENT purged after 7 d (application.properties:245); FAILED_TERMINAL persists.
- STALE_INFLIGHT (15 min vs 25 × 20 s) unaffected — each POST still bounded by 5 s + 15 s.
- Empty BOL (SBDEV-2737): check `palletDtos.isEmpty()` before chunking (`BOLS:779-785`).
- Serialize failure (SBDEV-2221): serialize all chunks before enqueueing any (club precedent CustomerorderBatchService:992-1004); counter once per BOL; any throw rolls back the close.
- Retries: 400/404/422 terminal else up to 5 attempts (OutboxDispatchService:299-301); OMS 503 label-pending (`LWC:2537-2545`) now re-sends one chunk.
- event_version stamped but never read by OMS.

## §4 Aggregate-id scheme

| DB | max(billoflading.id) | max outbox aggregate_id |
|---|---|---|
| c1wh ShipItEZ | 121,932,106 | 121,956,293 |
| wsl WineCo | 36,300,997 | 36,301,229 |
| nywh Hydra | 284,431 | 295,856 |
| nywh ShipItEZ | 711,361 | — |

Type `BILL_OF_LADING_CHUNK`, id = bolId × 100,000 + i (same span as CLUB_CHUNK_AGGREGATE_ID_SPAN). Today 1.22×10¹³ vs bigint 9.22×10¹⁸. Ids come from shared `seqentities`; gate/gauge key on (type,id) so a new type cannot collide. A BOL is all-`BILL_OF_LADING` (1 row) or all-chunk (N rows), including chunk 0.

## §5 Sysprop + Flyway

- Next free: **V2.2.39** (424 remote branches swept; max V2.2.38 on develop). Re-sweep before push.
- `WmsConstants` (after :1397): `SYSTEM_PROPERTY_BOL_SHIPPED_OMS_CHUNK_SIZE_KEY = "WMS_BOL_SHIPPED_OMS_CHUNK_SIZE"`, `_DEFAULT_VALUE = "40"`.
- SQL shape: copy V2.2.29:37-50 (nextval seqentities, workstation DEFAULT, client 0, group 'Operation Options', NOT EXISTS guard, description < 255). Seed-consistency test mirroring `unit/db/ClublineOmsChunkSizeSeedConsistencyTest`.
- Missing/blank/garbage/<1 → **40 (not unchunked)** + WARN; must never fail a close.
- Ceiling **60** + WARN (min observed first-attempt timeout = 70 parcels).

## §6 Chunk-size justification

PRD `message` ORDER_BATCH_SHIPPED since 2026-07-01, first attempt per bol_id:

| Tenant | first 200 (BOLs / max parcels / max items) | first timeout (BOLs / min parcels / min items) | 503 label-pending |
|---|---|---|---|
| ShipItEZ c1wh | 70 / 114 / 267 | 8 / 112 / 331 | 1 (298 parcels) |
| WineCo wsl | 96 / 216 / 793 | 18 / **70** / 410 | 7 (253–500) |
| Hydra nywh | 49 regular (≤14) + 7 transfer (≤1) | 0 | 0 |

Overlap 70–216 parcels → size alone does not decide; OMS cost is per parcel (shipParcel, `LWC:2418-2424`). Rough fit ≈ 0.19 s/parcel (4 points, includes ≤3 s dispatcher wait): 70 → ~13 s, 112 → ~21 s, **K=40 → ~7.6 s**. 40 × 5.46 = 218 items < min timed-out 331. Exposure at K=40: ShipItEZ 36/91 BOLs chunked, WineCo 70/142, Hydra 0. No non-200 BOL anywhere had ≤40 parcels. 1,528-parcel BOL → 39 chunks.

## §7 Risks

- R-1 merchant `outbound_bol_close` (`LWC:2523`, SendClientCallbackJob.php:75-100) fires once per successful call → up to N callbacks per BOL. Configured clients unknown (needs OMS tenant DB).
- R-2 partial visibility: a failed chunk leaves part of the BOL unshipped in OMS; each failed chunk is its own FAILED message row, resendable via /resend.
- R-3 DEFAULT-lane hold: batch of 25 sequential → ~25 × 7.6 s ≈ 190 s per tick for a 39-chunk BOL; pick/pack notifications wait. Options: accept / LANE_CLUB / new lane.
- R-4 ordering: BILL_OF_LADING has one producer; chunks are order-independent (already-shipped skip + NOOP = success, `LWC:2313-2319,2426-2432`).
- R-5 K changes mid-flight: read once per close; low risk.
- R-6 BOL 101226(5) probably unshipped in OMS (inference: all 6 attempts timed out; a committed attempt would have made the retry fast). Needs a one-off replay in ≤40-parcel slices; not fixed by this change.

Tests — keep: BillofladingServiceUnitTest:3046-3070 (+ explicit same payload/type/id case), never().enqueue cases (:395,410,468,1864-1995,3127,3502), :1783 times(2), FinishTransferPreTransferCloseIT:185-190, BillofladingServiceFinishTransferIT:170-187 (new IT must seed chunk sysprop). Extend serialize-failure :3122-3127 (any chunk fails → zero enqueues). Add: >K → ⌈n/K⌉ rows, ids/keys ≤64, every parcel exactly once in order; straddling pallet label; HUB_AND_SPOKE chunked, transfer >K stays one row; sysprop blank/garbage/0/>60; seed consistency; PG IT through findAndClaimPending (a FAILED_TERMINAL chunk does not hold others).

## §8 DB query confirming the symptom (c1wh-shipitez-prd, 2026-10-13)

```sql
select o.id, o.aggregate_id, o.status, o.attempts, length(o.payload) bytes, o.created_at, o.sent_at,
  (select sum(jsonb_array_length(p->'positions')) from jsonb_array_elements(o.payload::jsonb->'positions') p) parcels,
  (select count(*) from jsonb_array_elements(o.payload::jsonb->'positions') p, jsonb_array_elements(p->'positions') c,
     jsonb_array_elements(c->'positions') i) items, left(o.last_error,80) err
from outbox_message o where aggregate_type='BILL_OF_LADING' order by id;
```

| ids | status | attempts | bytes | parcels | items | note |
|---|---|---|---|---|---|---|
| 6049, 7344, 9099, 9985 | SENT | 0 | 1.5–6.2 KB | 5–25 | 12–49 | sent 1.1–4.9 s after create |
| 11089–11092 | SENT | 1 | 88–107 KB | 281–329 | 904–1,221 | first attempt read timeout, 200 on retry |
| **11135** (bol 121932106, 101226(5)) | **FAILED_TERMINAL** | **5** | **664,147** | **1,528** | **8,346** | 6 EX rows 23:25:12 → 23:57:42 UTC |
