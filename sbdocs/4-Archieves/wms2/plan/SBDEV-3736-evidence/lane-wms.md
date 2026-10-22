---
ticket: SBDEV-3736
lane: wms (wms2-api side of returns audit linkage)
source: v2/wms2-api origin/develop @ 11468c4a (read via git show / git grep; local checkout NOT used)
db: wsl-wineco-uat (v2 WineCo UAT), read-only SELECTs, 2026-10-13
status: evidence — read-only, no code changed
---

# SBDEV-3736 — WMS-side returns linkage evidence

Legend: **[F]** = fact (code quote or DB row), **[I]** = inference.
Paths are relative to `v2/wms2-api/` on `origin/develop` unless marked otherwise.

## 0. Headline

1. **[F] WMS already has a full FK chain from a return advice to every unit load and stock unit it
   created.** `goodsreceiptposition` carries real FKs to `adviceposition`, `unitload`, `stockunit`,
   `goodsreceipt` and `mywms_user`. `goodsreceipt` carries a real FK to `advice`. The SBDEV-1406
   resolver (V2.2.25) goes the long way, through the string `stockrecord.ordernumber`. For audit
   linkage you don't need that hop.
2. **[F] The only WMS link to OMS is one string: `advice.externalid = 'RETURN{parcel_id}'`.** It has
   a UNIQUE constraint. Per position you also get `adviceposition.externalid = 'RETURN{parcel_id}_{n}'`,
   which is a convention with no constraint. WMS does not receive the OMS return id, the original
   order id, a disposition beyond the damaged/undamaged split, a QA user, or a QA timestamp.
3. **[F] There is no "receiving completed" timestamp column.** `advice`/`adviceposition` go to
   FINISHED through bulk JPQL updates that don't touch `modified`. On UAT, `advice.modified ==
   advice.created` on every FINISHED RETURN advice sampled. `goodsreceipt.receiptdate` is never
   written: there is no caller of the setter, and the column is 0/all on UAT. The usable proxy is
   `max(goodsreceiptposition.created)`.
4. **[F] The destination location at the time of receipt lives only in `unitload_record`.** The
   TRANSFERRED row (or, in 2025-26, a second CREATED row — R2-1) has activitycode `RETURN`, `ordernumber = adviceposition.number`, and
   `tolocation` set. The `stockrecord` STOCK_CREATED row records `InboundWorkstation`, not the
   destination. `unitload.storagelocation_id` is the **current** location, which changes over time.

## 1. What `/rest/advice/create` accepts, and what it drops

DTOs: `json/AdviceDto.java`, `json/AdvicePositionDto.java`, `json/AbstractWebServiceDto.java`.
Persisted by `controller/rest/AdviceRestController.java` `create()` (`:138`).

| Wire key (advice) | Persisted to | Evidence |
|---|---|---|
| `reference_id` | `advice.externalid` (UNIQUE) | `:261 adviceEntity.setExternalid(adviceDto.getReferenceId());` |
| `client_id` (client code) | `advice.client_id` (resolved FK) | `:243 clientRepository.findByClNr(...)`, `:260 setClientId(client.getId())` |
| `type` | `advice.type` (REGULAR/RETURN only, else 400) | `:291-296` |
| `day_of_delivery` / `_until` | `advice.dayofdelivery` / `dayofdeliveryuntil` | `:263-277` |
| `delivery_note_number` | `advice.deliverynotenumber` | `:279` |
| `comment`, `supplier`, `purchase_order_number` | same-named columns | `:280-282` |
| **`shipment_id`** | **DROPPED** (no setter call in `create()`) | grep `getShipmentId` in controller → 0 hits [F] |
| **`transfer_id`** | **DROPPED on this endpoint** (only set by `/createTransfer` `:653`, `/createHubAndSpoke` `:780`) | [F] |
| `printer_id` | not persisted; used only to pick the label printer in auto-receive | [I] from `ReturnAdviceAutoReceiveService.validate` hoisting the printer |
| `facility_code` | not persisted; tenant routing | [I] |
| — (server-generated) | `advice.number = 'IBOL…'` | `:288 basicService.generateNumber(WmsConstants.EntityPrefixes.ADVICE, "ADVICE")`; `WmsConstants:750 ADVICE = "IBOL"` |

| Wire key (position) | Persisted to | Evidence |
|---|---|---|
| `reference_id` | `adviceposition.externalid` (no constraint) | `:427 position.setExternalid(advicePosition.getReferenceId());` |
| `sku` + `client_id` | `adviceposition.itemdata_id` (FK) | `:405 itemdataService.findByClientIdAndItemNr(...)`, `:429` |
| `box_id` | `adviceposition.boxtype_id` (FK) | `:418`, `:433` |
| `amount_of_boxes` | `adviceposition.notifiedcases` | `:434` |
| `amount_of_bottles` + `amount_of_bottles_damaged` | `notifiedamount` = SUM; `notifieddamagedamount` = damaged (NULL if key absent) | `:481 long totalNotified = (long) advicePosition.getAmountOfBottles() + damaged;` `:485-486` |
| — (server-generated) | `adviceposition.number = '{advice.number}-{count:000000}'` | `service/BasicService.java:85-91 generateNumberWithAdvice` — count-based |

**[F] The raw payload is kept.** Every create writes a `message` row with process `ADVICE_IMPORT`
and `message = WmsObjectMapper.writeValueAsString(adviceList)` (`AdviceRestController` after the
loop: `messageService.createMessage(..., payload, WmsConstants.MessageProcessType.ADVICE_IMPORT, ...)`).
Because this re-serializes the DTO, `shipment_id`/`transfer_id`/`printer_id` survive in the JSON
even though no column stores them. Keys that aren't in the DTO are gone.

Retention: `message` rows older than `CLEAN_UP_OLD_MESSAGES_PERIOD` (default `"365"` days,
`WmsConstants:1370-1371`) get copied into `message_archived` and then deleted
(`MessageRepository:91 INSERT INTO message_archived SELECT * FROM message where created < :refDate`).
- **[F, UAT]** Sample payload for RETURN286363:
  `[{"type":"RETURN","positions":[{"sku":"BBP18F","reference_id":"RETURN286363_1","client_id":"ADE","box_id":"1","amount_of_boxes":1,"amount_of_bottles":2,"amount_of_bottles_damaged":0},…`

**What OMS actually sends** (cross-check: `v2/oms-laravel-api` origin/develop @ 1369c109,
`app/Services/Qa/QaReturnService.php:714-724` and `:899-902`). The OMS lane owns this; it's quoted
here only to show the wire. `reference_id`, `delivery_note_number` and `shipment_id` are **all**
`'RETURN' . $return->parcel_id`. Each position's `reference_id` is `RETURN{parcel_id}_{counter}`.
None of these go on the wire: the return id, order id, QA user, QA timestamp, or disposition
(other than the damaged count).

## 2. Constraints and FKs (Flyway `V2.2.00__base_v2_schema.sql` + later)

| Object | Constraint | Kind |
|---|---|---|
| `advice.externalid` | `uk_4d13b6sg589c6y88tkm98xl89 UNIQUE (externalid)` | **unique** — and load-bearing (`AdviceRestController:68-72` "Treat as a security control; do not drop it") |
| `advice.number` | none | by convention (sequence-generated). UAT: 0 duplicates |
| `adviceposition.number` | none. Plain index `index_adviceposition_number` added by V2.2.25:423 | by convention, count-based. UAT: 0 duplicates |
| `adviceposition.externalid` | none | by convention |
| `adviceposition.advice_id` | `fksl6cw7u257w403akhdtg58xl0 → advice(id)` | **FK** |
| `goodsreceipt.advice_id` | `fk5i5w7iybhlovjbvwnx08kblqs → advice(id)` | **FK** |
| `goodsreceipt.operator_id` | `fk90y6x3epoo81wthhyft85ddg3 → mywms_user(id)` | **FK** |
| `goodsreceiptposition.adviceposition_id` | `fkoenhrs8vnoaqbgjm34ea812hu → adviceposition(id)` | **FK** |
| `goodsreceiptposition.unitload_id` | `fk40qe9lg0t9gj7drhlyms318jl → unitload(id)` | **FK** |
| `goodsreceiptposition.stockunit_id` | `fk9ltnv2vij99cj7fnf8mddh4d2 → stockunit(id)` | **FK** |
| `goodsreceiptposition.goodsreceipt_id` | `fkrxgrkgoafn97vmsv59j5xsi4 → goodsreceipt(id)` | **FK** |
| `goodsreceiptposition.operator_id` | `fkgr6swvoovxlys8ypej6pvc9dl → mywms_user(id)` | **FK** |
| `unitload.labelid` | `uk_s2ujivixnde5dqb2stih8m2vh` and `uq_unitload_labelid` UNIQUE | **unique** (twice) |
| `stockrecord.*` | only `client_id` FK. `ordernumber`, `tounitload`, `tostoragelocation`, `operator` are free strings (lower() indexes) | **by convention** |
| `unitload_record.*` | only `client_id` FK. `label`, `ordernumber`, `tolocation`, `operator` are strings | **by convention** |
| `customerorder.externalnumber` | `index_customerorder_externalnumber UNIQUE` | **unique** |

**[F]** No FK runs from `stockrecord` or `unitload_record` to `advice`/`adviceposition`. The FK path
is `goodsreceiptposition`.
**[F]** No service calls `unitloadRepository.delete` (git grep over `src/main/java/.../service`), so a
received unit load row survives being emptied. It gets relocated (Nirvana / empty pool) instead.
The FK from `goodsreceiptposition.unitload_id` therefore stays resolvable. [I] An admin
`GoodsReceiptPositionService.delete` (`:131`/`:200`) **deletes** the `goodsreceiptposition` row and
sends the UL to Nirvana. A voided receipt loses its FK link, and only `stockrecord`/`unitload_record`
strings remain.

## 3. Receive path — what gets written (auto-receive)

`ReturnAdviceAutoReceiveService.execute` → `executeAsIntegrationUser` → `executeInternal`
(`:750`): `receivingService.receiveGoods(line.advicePositionId(), null, false, line.amount(), line.amount(), 1, line.boxtypeId(), plan.printer())`.
`amountCases = 1` means one unit load and one stock unit per advice position.

`service/ReceivingService.java` `receiveGoods` (`:337`):
- `:439-454` creates or reuses **one `goodsreceipt` per advice** (`setAdviceId`, `setOperatorId(user.getId())`, `number = GRT…`). It **never** sets `receiptdate` or `deliverynotenumber`.
- `:554` `unitloadService.createUnitload(inboundWorkStation, …, codeReceiving, spawnLocation, …)` mints a fresh `UL…` label. This writes `unitload_record` CREATED `Spawn->InboundWorkstation` with ordernumber NULL.
- `:556` `createStockUnit(..., codeReceiving, adviceposition.getNumber(), inboundWorkStation, ...)` writes `stockrecord` type `STOCK_CREATED`, `activitycode = 'RETURN'`, `ordernumber = adviceposition.number`, `tostoragelocation = InboundWorkstation`, `tounitload = UL label`, `operator = SecurityContextUtils.getUserName()` (`StockunitBusinessService:140-157`).
- `:561-570` writes `goodsreceiptposition` with `advicepositionId`, `unitloadId`, `stockunitId`, `amount`, `operatorId`.
- `:573` `transferUnitLoadToLocation(unitload, putaway.location(), false, codeReceiving, adviceposition.getNumber(), null)` writes a `unitload_record` TRANSFERRED row (`UnitloadRecordService:40-62`) with `tolocation = putaway destination` and `ordernumber = adviceposition.number`. It **does not** write a stockrecord.
- `codeReceiving` for RETURN is `CODE_RECEIVING_RETURN = "RETURN"` (`WmsConstants:1053`, switch at `ReceivingService:478`).

Then `markFinished` (`ReturnAdviceAutoReceiveService:955-957`) runs
`AdvicepositionRepository:39 "UPDATE Adviceposition a SET a.state = :state WHERE a.adviceId = :adviceId"`
and `AdviceRepository:37 "UPDATE Advice a SET a.state = :state WHERE a.id = :id"`. These are bulk
JPQL updates, so the auditing listener does not fire and `modified` is not touched.

Damaged portion (`applyDamage`, `:981-1040`) calls
`stockunitService.setLockDamaged(received, damagedAmount, "RETURN DAMAGED " + line.positionExternalId(), false, null)`.
That reaches `UnitloadService.moveStockToNewDamagedContainer` (`:174`), which mints a **new** UL
in location `Damaged` and calls `transferStockToUnitLoad(..., WmsConstants.CODE_DAMAGED, null /*orderNumber*/, comment, ...)`.
It sets `entity_lock = QUALITY_FAULT` and `additionalcontent = comment`. On success it stamps
`adviceposition.damageappliedat`.
**[F]** The damaged container is **not** in `goodsreceiptposition`. Its stockrecords carry
`activitycode='DAMAGED'` and `ordernumber = NULL`. The only link back is the string
`additionalcontent = 'RETURN DAMAGED RETURN{parcel}_{n}'`, which is `AuditCommentUtil.clamp`'d and
so could be truncated [I].
**[F, UAT]** No positions with `notifieddamagedamount > 0` exist on wineco UAT yet, so the damaged
chain isn't DB-verified.

### DB verification (wsl-wineco-uat, advice id 35074049 = `IBOL015377` / `RETURN286363`) [F]

Every one of the 5 positions resolves end to end. Example row:
```
ap_number IBOL015377-000000  ap_ext RETURN286363_1  sku BBP18F  notified 2.00 damaged 0.00  state FINISHED
grp_amount 2.00  grp_created 2026-09-23 17:34:16.42Z  ul UL354197  ul_current_loc PutAwayLane
unitload_record: CREATED:RETURN:Spawn->InboundWorkstation:∅:oms_integration
               | TRANSFERRED:RETURN:InboundWorkstation->PutAwayLane:IBOL015377-000000:oms_integration
stockrecord:     STOCK_CREATED:RETURN:InboundWorkstation:IBOL015377-000000:oms_integration
customerorder (externalnumber = substring(externalid from 7)): 752381 / QY1667572653610 / 286363
advice.created = advice.modified = 2026-09-23 17:34:16.174Z although state = FINISHED
```
Estate counts on UAT: 2797 RETURN advices. 0 have a non-`^RETURN[0-9]+$` externalid. 0 fail to
resolve a `customerorder`. 0 duplicate `advice.number` / `adviceposition.number`.
`goodsreceipt.receiptdate IS NOT NULL` = 0 rows.
The 8 most recent RETURN advices each have exactly 1 `goodsreceipt` and one `goodsreceiptposition`
per position. Operator is `oms_integration` on 2026-09-23 and `anonymous` on everything ≤ 2026-08-27.

## 4. Field-by-field

Classes: **(a)** reconstructable today by a join · **(b)** needs only a report/query change (data is
there, nothing exposes it) · **(c)** needs a schema/contract change.

| # | Field | What WMS stores today | Link strength | Class |
|---|---|---|---|---|
| 1 | **Return ID** (OMS return id) | Nothing. WMS has only `advice.externalid = 'RETURN{parcel_id}'` (UNIQUE) and the redundant `advice.deliverynotenumber` (same value). There is no return-id key in `AdviceDto`/`AdvicePositionDto`; `git grep -i "return_?id\|parcel_?return"` in `src/main` finds only the V2.2.25 filename. | parcel_id by convention (string prefix); OMS return id **absent** | **(c)** if the OMS return id is required. **(a)** if parcel_id is accepted as the return key ([I] it is 1:1 only while OMS allows one managed return per parcel, which the UNIQUE externalid enforces on the WMS side) |
| 2 | **Original order ID** | Not sent. Resolvable on the shipping tenant: `customerorder.externalnumber = substring(advice.externalid from 7)` → `customerorder.clientordernumber` (OMS order number) / `customerorder.number`. Used by V2.2.25. | UNIQUE on both ends, but joined by a **string transform**. Fails when the return is received at a facility that never shipped the parcel (V2.2.25 header "Known limitation") | **(a)** same-facility · **(c)** cross-facility |
| 3 | **Original parcel ID** | `substring(advice.externalid from 7)` (OMS parcel_id). Also `customerorder.externalnumber` = parcel_id and `customerorder.parcelexternalnumber` (carrier package id, e.g. `QY1667572653610`) | convention + UNIQUE | **(a)** |
| 4 | **Inbound BOL ID** | WMS's "inbound BOL" for a return is the **advice itself**: `advice.number = 'IBOL…'` (`EntityPrefixes.ADVICE = "IBOL"`). Positions are `IBOL…-NNNNNN`. The receipt is `goodsreceipt.number = 'GRT…'` (one per advice, FK). There is **no** `billoflading` row for an inbound return; `billoflading` is outbound/transfer. | advice ↔ goodsreceipt **FK**. `advice.number` has no unique constraint (0 dups on UAT) | **(a)** |
| 5 | **SKU and qty** | `adviceposition.itemdata_id` (FK) → `itemdata.item_nr`. Notified: `adviceposition.notifiedamount` (total incl. damaged) and `notifieddamagedamount`. Received: `goodsreceiptposition.amount` (FK to adviceposition). Also `stockrecord.itemdata`/`amount` (strings) | **FK** | **(a)** |
| 6 | **Disposition** | Only the restock-vs-damaged split: `adviceposition.notifieddamagedamount` + `damageappliedat` (V2.2.32), and stock `entity_lock = QUALITY_FAULT` in location `Damaged`. Nothing else is carried (no reason code, no "missing", no restock/scrap/vendor-return enum). OMS doesn't advise "missing" lines at all. | column on position (by convention) | **(a)** damaged/undamaged only · **(c)** for any richer disposition |
| 7 | **Created unit-load IDs** | Undamaged: `goodsreceiptposition.unitload_id` → `unitload.labelid` (UNIQUE). Also by string: `stockrecord.tounitload` / `unitload_record.label` where ordernumber = `adviceposition.number`. Damaged: a **second** UL minted by `moveStockToNewDamagedContainer`. It is **not** in `goodsreceiptposition`; it links only via `stockrecord.activitycode='DAMAGED' AND additionalcontent = 'RETURN DAMAGED {adviceposition.externalid}'`. Unit loads carry no advice/adviceposition column. | undamaged **FK** · damaged **string-only** | **(a)** undamaged · **(b)**, borderline **(c)**, damaged (string match on a clamped comment; an FK or column would make it robust) |
| 8 | **Destination locations** | At receipt: `unitload_record` row `recordtype='TRANSFERRED'` (or, in 2025-26, a second CREATED row — R2-1; the §4 SQL takes any recordtype), `activitycode='RETURN'`, `ordernumber = adviceposition.number`, `label = UL`, `tolocation` (UAT: `PutAwayLane`). `stockrecord` STOCK_CREATED only says `InboundWorkstation`. Current: `unitload.storagelocation_id` (mutable). Damaged: location `Damaged` (stockrecord `tostoragelocation`). | string (unitload_record) | **(b)** — data is there, but no report joins `unitload_record` for returns |
| 9 | **Receiving user** | `goodsreceipt.operator_id` / `goodsreceiptposition.operator_id` (FK → `mywms_user`). Also `stockrecord.operator` / `unitload_record.operator` strings. Auto-receive runs as `oms_integration` (`ReturnAdviceAutoReceiveService:104`, seeded by V2.2.09), but falls back to `anonymous` when that user row is missing (`:712-714`). That is the UAT state for all returns ≤ 2026-08-27. **This is the system user, not the human at the QA station**; WMS never receives the QA user. | **FK** | **(a)** for the WMS actor · **(c)** for the human QA operator |
| 10 | **Return QA completion timestamp** | Not sent. Proxy: `advice.created` (insert time of the OMS call, which OMS makes inside its manage transaction — [I] ≈ QA completion). The `message` ADVICE_IMPORT row `created` is the same instant. `day_of_delivery` is a date only. | proxy only | **(b)** proxy · **(c)** for the true QA timestamp |
| 11 | **Receiving completion timestamp** | No dedicated column. `goodsreceipt.receiptdate` is never written (no caller of `setReceiptdate`; UAT 0 rows non-null). `advice.modified` is **not** bumped by the FINISHED flip (bulk JPQL). Proxy: `max(goodsreceiptposition.created)` per advice (UAT: ~1.4 s after `advice.created`), or the TRANSFERRED `unitload_record.created`. Damage completion: `adviceposition.damageappliedat`. | proxy via FK | **(b)** proxy · **(c)** for a state-transition timestamp |

### Join that reconstructs 3/4/5/7/8/9/11 (and 2 same-facility) today

```sql
SELECT a.externalid                         AS return_ref,          -- RETURN{parcel_id}
       substring(a.externalid from 7)       AS parcel_id,
       co.clientordernumber, co.parcelexternalnumber,               -- same-facility only
       a.number                             AS inbound_bol,         -- IBOL…
       gr.number                            AS goods_receipt,       -- GRT…
       ap.number AS position_no, ap.externalid AS position_ref,
       i.item_nr AS sku, ap.notifiedamount, ap.notifieddamagedamount, ap.damageappliedat,
       grp.amount AS received_qty, regexp_replace(u.labelid, '-X-[0-9]+$', '') AS unit_load,
       ur.tolocation AS putaway_destination,
       op.name AS receiving_user,
       a.created AS advised_at, grp.created AS received_at
-- ⚠ CORRECTED 2026-10-13 after critic review F3/F8 + round-2 R2-1/R2-3/R2-5 (see review-critic.md):
--   * unitload_record keeps the ORIGINAL label; unitload.labelid is rewritten to '{label}-X-{id}' on
--     SEND_TO_NIRWANA (538/626 PRD 180-day return ULs). Join unitload_record on ordernumber, not label,
--     and report the created UL as the stripped label.
--   * LEFT JOIN adviceposition: 133 historic RETURN advices (2020-10 → 2023-07) have no positions.
FROM advice a
LEFT JOIN adviceposition ap   ON ap.advice_id = a.id
LEFT JOIN itemdata i          ON i.id = ap.itemdata_id
LEFT JOIN goodsreceiptposition grp ON grp.adviceposition_id = ap.id
LEFT JOIN goodsreceipt gr     ON gr.id = grp.goodsreceipt_id
LEFT JOIN unitload u          ON u.id = grp.unitload_id
LEFT JOIN mywms_user op       ON op.id = grp.operator_id
LEFT JOIN (SELECT DISTINCT ON (ordernumber, label) ordernumber, label, tolocation   -- set-based (R2-3): per-row LATERAL times out
             FROM unitload_record
            WHERE ordernumber LIKE 'IBOL%' AND activitycode = 'RETURN'           -- ANY recordtype (R2-1): 2025-26 rows are CREATED
            ORDER BY ordernumber, label, id) ur
       ON ur.ordernumber = ap.number
      AND ur.label = regexp_replace(u.labelid, '-X-[0-9]+$', '')               -- per UL, tolerates dock fan-out (R2-5); never label = u.labelid
LEFT JOIN customerorder co    ON a.externalid ~ '^RETURN[0-9]+$'
                             AND co.externalnumber = substring(a.externalid from 7)
WHERE a.type = 'RETURN';
```
[F] The original label-join shape (as the §3 verification query) was run against UAT advice 35074049 and returned
the rows shown; that is a superseded shape. The current set-based SQL above (any recordtype, `(ordernumber, label)` key) was run on WineCo PRD all-time on 2026-10-15 (critic round 3): 10,173 rows, 0 NULL destination, 0 multi-row groups. Damaged ULs need an additional
`stockrecord sr ON sr.activitycode='DAMAGED' AND sr.additionalcontent = 'RETURN DAMAGED ' || ap.externalid`
branch, which is untested (no damaged data on UAT).

## 5. Caveats and gaps

- **[F]** `goodsreceipt` reuse: `ReceivingService:452-455` `// TODO: WMS support team / select the correct one` `goodsreceipt = goodsreceipts.get(0);`. Each advice has one receipt, and a later dock receive of the same OPEN advice (after a partial auto-receive) appends positions to it.
- **[F]** Partial auto-receive leaves the advice OPEN (`executeInternal` ~`:770`). The remaining positions are then received by a human on the mobile dock path. `goodsreceiptposition.operator_id` then becomes that human, so "receiving user" can be mixed within one advice.
- **[I]** `advice.number` and `adviceposition.number` have no unique constraint. V2.2.25 uses `LATERAL … LIMIT 1` for that reason. Any join on the **string** ordernumber should do the same. The FK path through `goodsreceiptposition` avoids the problem.
- **[F]** `customerorder` lives in the **shipping** facility's tenant DB. A return received at a different facility can't resolve fields 2/3-enrichment inside WMS.
- **[F]** Payload retention: `message` (365-day default) then `message_archived`. This is the only place `shipment_id` survives, and it's redundant (same value as reference_id).

## 6. Looked for and did NOT find

- A return id, order id, QA user, QA timestamp or disposition field in `AdviceDto`/`AdvicePositionDto` — none.
- Any `advice`/`adviceposition` column for an OMS return id or order id — none (entity fields enumerated in §1/§2).
- Any FK from `stockrecord` or `unitload_record` to `advice`/`adviceposition` — none (only `client_id`).
- Any column on `unitload` pointing to advice/adviceposition/goodsreceipt — none (`labelid, client_id, type_id, carrierunitload_id, storagelocation_id, boxtype_id, shippingmethod_id`).
- Any writer of `goodsreceipt.receiptdate` — none (only the setter at `model/Goodsreceipt.java:84`).
- Any "finished at" timestamp on advice/adviceposition — none. The state flips are bulk updates without `modified`.
- A `billoflading` row for inbound returns — none. Inbound "BOL" means `advice` (IBOL prefix).
- A unique constraint on `adviceposition.number` / `advice.number` / `adviceposition.externalid` — none.
- Damaged-return rows on wineco UAT — none, so the damaged linkage is code-derived only.
