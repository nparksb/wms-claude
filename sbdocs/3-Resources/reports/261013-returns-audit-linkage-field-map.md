---
title: "Returns audit linkage — field map (return ↔ inbound BOL ↔ receipt ↔ unit load ↔ stock records)"
type: investigation
status: concluded
version: "v2 (wms2-api + oms-laravel-api)"
scope: "returns audit linkage, SBDEV-2778 carrier AC"
owner: "Nam Park (Claude-assisted)"
created: "2026-10-13"
updated: "2026-10-15"
last_verified: "2026-10-13"
verified_by: "DB: wsl-wineco-prd + wsl-wineco-uat; code: wms2-api origin/develop 371d8a09, oms-laravel-api origin/develop 4981db86, siteboss-frontend origin/main 64836f4d"
ticket: "SBDEV-3736"
ticket_url: "https://app.clickup.com/t/868mg9b5t"
related:
  - "[[SBDEV-2778-return-to-inventory-not-received-bol-not-closed]]"
  - "[[SBDEV-1512-receive-damaged-from-returns]]"
  - "[[wms2-receiving-putaway-workflow]]"
tags:
  - investigation
  - report
  - returns
  - wms2
  - oms2
---

# Returns audit linkage — field map

**Topic:** returns audit linkage | **Version:** v2
**Started:** 2026-10-13 | **Investigator:** Nam Park (Claude-assisted)
**Status:** concluded

Evidence of record (raw lanes, quoted code, query output):
`sbdocs/4-Archieves/wms2/plan/SBDEV-3736-evidence/` — `lane-wms.md`, `lane-oms.md`, `db-wineco-prd.md`.

---

## 1. Context & Trigger

SBDEV-2778 (Closed) left one AC unticked: *"Return, BOL, receipt, Unit Load, and inventory transactions are
linked for audit."* SBDEV-3736 carries it, filed **T3 as filed (data model, multi-repo)**, with the instruction
that the first deliverable is this report and that **only fields needing a schema change justify T3**.

Prior art: SBDEV-1406's `V2.2.25__transaction_detail_return_order_refs.sql` resolves a RETURN stock record to
its order inside `transaction_detail()` only, via
`stockrecord.ordernumber → adviceposition.number → advice(externalid RETURN{parcel_id}) → customerorder.externalnumber`.

## 2. Questions

1. For each of the 11 SBDEV-2778 fields, is it (a) reconstructable today and by which join, (b) reconstructable
   with a report/query change only, or (c) does it need a schema change?
2. Does anything in (c) exist — i.e. does this ticket stay T3?
3. Are there defects in the linkage surface that make (a)/(b) unreliable?

## 3. Initial Hypotheses

| # | Hypothesis | Initial confidence | Rationale |
|---|---|---|---|
| H1 | Most fields are (a)/(b); the WMS↔OMS key `RETURN{parcel_id}` plus WMS internal joins cover them | medium | V2.2.25 already proved the order hop |
| H2 | At least one field (OMS return id, QA user/timestamp, disposition) is absent from WMS and needs a contract/schema change | medium | ticket's own list of V2.2.25's gaps |
| H3 | Nothing is actually missing — the AC is satisfied by existing data and only lacks a query | low | "nothing wrong" hypothesis |
| H4 | The string-convention joins are unreliable (fan-out, label reuse, gaps) | low–medium | V2.2.25 needed `LATERAL LIMIT 1` |

## 4. Method

- Code read on `origin/develop` (never a local checkout) of wms2-api and oms-laravel-api, plus the QA UI in
  siteboss-frontend — two parallel evidence lanes, written to `lane-wms.md` / `lane-oms.md`.
- DB queries, read-only: WineCo **PRD** (`wsl-wineco-prd`) for the population (180 days) and trails; WineCo UAT
  (`wsl-wineco-uat`) by the WMS lane for an end-to-end example.
- Two instruments for every count that drives a decision (string/label join vs FK join) — they disagreed once
  (§5.4) and the disagreement was itself a finding.
- **Cohort split (review F4).** WineCo went live on WMS v2 PRD on 2026-09-26; earlier rows were migrated from v1
  (ms-precision timestamps vs µs after cutover). Of the 180-day population (150 advices / 626 positions),
  **128 advices / 540 positions are v1-written**; the **v2 cohort is 22 advices / 86 positions**. Every PRD count
  below is given for both, and only the v2 cohort is evidence about the wms2-api write path.
- An independent critic lane reviewed the draft in two rounds (`SBDEV-3736-evidence/review-critic.md`: round 1
  3H/4M/5L, round 2 1H/2M/4L, round 3 0H/1M/4L); every finding is applied or answered in this version.

### 3.5 Sources in scope

| Side | Source |
|---|---|
| WMS write path | `ReturnAdviceAutoReceiveService` (`executeInternal`, `applyDamage`, `markFinished`), `ReceivingService.receiveGoods`, `UnitloadService.moveStockToNewDamagedContainer`, `UnitloadRecordService`, `AdviceRestController.create`, `AdviceService.close` |
| WMS tables | `advice`, `adviceposition`, `goodsreceipt`, `goodsreceiptposition`, `unitload`, `unitload_record`, `stockrecord`, `stockunit`, `mywms_user`, `customerorder`, `message` / `message_archived` |
| OMS write path | `QaReturnService` (`processReturn`, `updateReturnManagement`, `sendReturnRestockAdvice`, `persistReturnItems`), `WmsApiService::createReturnAdvice`, `ReturnMgmtLut::dispositionAdvisesWms`, `ServiceLog::logWmsRequest` |
| OMS tables | `returns` (PK `parcel_id`), `return_item`, `return_mgmt_lut`, `parcel`, `order_item_parcels`, `parcel_status_history`, `order_status_history`, `audit_log`, `service_log`, `advices` |
| Prior reports/plans | SBDEV-2778, SBDEV-2236, SBDEV-1512 (plans), SBDEV-1406 (V2.2.25), SBDEV-1944 / SBDEV-3261 (tickets) |

## 5. Evidence

### 5.1 The OMS has no separate "return id" — the parcel id IS the return key

**Source:** `app/Models/ParcelReturn.php` `protected $primaryKey = 'parcel_id'; // Primary key is parcel_id, not return_id`;
`tenant-baseline.sql` `returns … PRIMARY KEY (\`parcel_id\`)`. The QA UI's manage route is `/qa/returns/${parcelId}/manage`.
**Observation:** one return per parcel, enforced in code as well as DDL — OMS SCAN rejects a re-scan
(`QaReturnService.php:106-120`) and WMS rejects a duplicate `reference_id` with `ENTITY_ALREADY_EXITS`
(`AdviceRestController.create`). `RETURN{parcel_id}` on WMS `advice.externalid` (UNIQUE,
`uk_4d13b6sg589c6y88tkm98xl89`) is therefore a **complete** return key, not a lossy proxy. `processReturn`'s
response field `return_id` is `$return->id` on a table with no `id` column → always null (cosmetic, misleading).
**Supports:** H1, H3. **Contradicts:** H2 for field 1.

### 5.2 WMS already has a real FK chain from the return advice to every received unit load

**Source:** `ReceivingService.receiveGoods` writes `goodsreceipt` (FK `advice_id`) and `goodsreceiptposition`
(FKs `adviceposition_id`, `unitload_id`, `stockunit_id`, `goodsreceipt_id`, `operator_id`) — `lane-wms.md` §2–3.
**PRD (D9):** last 180 days, 150 RETURN advices / 626 positions; **626/626** positions have exactly one
`goodsreceiptposition`; `unitload_id` NULL 0, dangling 0; `operator_id` NULL 0; 1 `goodsreceipt` per advice.
**v2 cohort alone (critic re-run): 22 advices, 86/86 positions with exactly one GRP, 0 without.** All-time:
0 of 10,173 return positions have more than one GRP — but the dock path *can* fan out (one UL + GRP per case,
`ReceivingService.receiveGoods` `while (amountBottles > 0)`), so an audit query must allow N GRPs per position.
133 historic RETURN advices (2020-10 → 2023-07) have **no positions**; use `LEFT JOIN adviceposition`.
**Observation:** V2.2.25's string hop through `stockrecord.ordernumber` is not needed for audit; the FK path is
stronger. On PRD, 0 duplicate `adviceposition.number` / `advice.number` values, and 626/626 positions have
exactly one RETURN stock record (no fan-out) — the string path is clean *today* but unconstrained.
**Supports:** H1. **Weakens:** H4.

### 5.3 The receipt-time destination is only in `unitload_record`; the stock record lies about it

**Source:** `ReceivingService` mints the UL at `InboundWorkstation` (`stockrecord` STOCK_CREATED,
`tostoragelocation='InboundWorkstation'`) then `transferUnitLoadToLocation(…, adviceposition.getNumber(), …)`
writes a `unitload_record` TRANSFERRED row and **no** stock record.
**PRD (D3, D6):** every sampled RETURN UL has `unitload_record` CREATED Spawn→InboundWorkstation + TRANSFERRED
InboundWorkstation→**PutAwayLane** with `ordernumber = adviceposition.number`; 180d: 1252 rows = 626 × 2 (complete).
Retained since 2019-10-02. v2 cohort: 86 TRANSFERRED rows carrying `ordernumber` (86/86).
**The record shape changed over time (review R2-1):** roughly 2025-Q1 → 2026-Q1 the put-away row was written as a
second **`CREATED`** row (`InboundWorkstation → PutAwayLane`, carrying `ordernumber`) with no TRANSFERRED row. All-time
PRD, keyed on `ordernumber = adviceposition.number AND activitycode = 'RETURN'` with **any** recordtype:
**10,173 / 10,173** positions get a destination (2,279 via CREATED — 2,102 in 2025, 177 in 2026 — the rest via
TRANSFERRED); filtering on `recordtype = 'TRANSFERRED'` would blank 22.4% (e.g. `IBOL012303`, 2025: NULL on all 5).
**Performance (R2-3):** `unitload_record` has no index beyond the pkey (~6.8 M rows / 1.4 GB). A per-row LATERAL
lookup times out; a **set-based** join (`DISTINCT ON (ordernumber)` over `ordernumber LIKE 'IBOL%' AND
activitycode = 'RETURN'`, then hash join) covers all 10,173 positions inside the 30 s MCP limit. A `created` bound
prunes nothing (no index on `created`). **No index is needed — measured.**
**Join it on `ordernumber = adviceposition.number`, never on `label = unitload.labelid`** — `unitload_record.label`
keeps the *original* label while `unitload.labelid` is rewritten (§5.4). Verified on PRD: for `IBOL014975`
(relabelled ULs) the label join returns NULL destinations, the ordernumber join returns `PutAwayLane`. Under dock
fan-out (N ULs per position) key on `(ordernumber, stripped label)` so each UL keeps its own destination.
Dock receipts with a carrier go to `transferUnitLoadToCarrier` instead (no TRANSFERRED-to-location row) — latent,
0 on PRD.
**Supports:** H1 (field 8 is (b)), with a performance caveat.

### 5.4 Two instruments disagreed: unit-load labels are rewritten on SEND_TO_NIRWANA

**PRD (D7, D9, D10):** joining `unitload.labelid = stockrecord.tounitload` found 538/626 return ULs "missing";
joining by FK `goodsreceiptposition.unitload_id` found 0 dangling. Cause: emptied ULs are relabelled
`{label}-X-{id}` (e.g. `UL349197` → `UL349197-X-33258969`, location `Nirwana`); `lane-wms.md` §2 confirms no
service deletes `unitload` rows.
**Observation:** any audit query must join unit loads **by id via `goodsreceiptposition`**, never by label from
`stockrecord`, and must report the *created* UL as `regexp_replace(unitload.labelid, '-X-[0-9]+$', '')` (or
`stockrecord.tounitload` of the STOCK_CREATED row). A label-based report would silently blank ~86% of historic
rows. The first draft of this report's own reference join fell into exactly this trap (review F3; corrected in
`lane-wms.md` §4 and re-run on PRD).
**Supports:** H4 (for the label path only).

### 5.5 Put-away into existing stock breaks the trail: the REMOVED/CREATED pair shares no key

**PRD (D8):** `IBOL014975` (2026-06-01). After receipt, a human put UL349198 away: `stockrecord` TRANSFER /
STOCK_REMOVED −4 on `UL349198` (ordernumber NULL), immediately followed (id+1, +1 ms) by TRANSFER / STOCK_CREATED
+4 on `60-C01`, a *different* stock unit; then `unitload_record` SEND_TO_NIRWANA.
**Observation:** the final bin is linkable **only by adjacency heuristics** (id/created/operator/itemdata/opposite
amount). No column carries the return's position number past `PutAwayLane`. Fixing this needs a **code** change
(propagate `adviceposition.number`, or a correlation value, into the existing `stockrecord.ordernumber` of the
transfer pair), not a schema change — but it is **not small**: put-away is a generic later flow, so it must look
up UL → `goodsreceiptposition` → adviceposition at put-away time; once stock merges into an existing bin, later
moves cannot be attributed anyway; and it changes `transaction_detail()` output (§5.6 note). **T2** (a report-contract
change in one repo; no migration, no authz — T3 only if one of those turns up).
**Supports:** H2 (weakly — only if "destination" means final bin, see §9).

### 5.6 Damaged units go to a second UL linked only by a clamped comment string

**Source:** `applyDamage` → `setLockDamaged(…, "RETURN DAMAGED " + line.positionExternalId(), …)` →
`moveStockToNewDamagedContainer` → `transferStockToUnitLoad(…, CODE_DAMAGED, null /*orderNumber*/, comment, …)`.
The damaged UL has no `goodsreceiptposition`; the link is `stockrecord.additionalcontent = 'RETURN DAMAGED RETURN{pid}_{n}'`,
passed through `AuditCommentUtil.clamp`.
**PRD (D4):** 0 positions with `notifieddamagedamount > 0` in 180 days (UAT: none either) — the path is
code-derived only. A code change (pass `adviceposition.number` instead of `null` as orderNumber) would make it a
real join on an existing column.
**Consumer impact (review F6):** V2.2.25's resolver keys on `sr.ordernumber` only (not gated on `activitycode`),
and `sr.ordernumber` is also emitted as `transaction_number`. Writing `adviceposition.number` onto DAMAGED (S3) or
put-away TRANSFER rows (§5.5) therefore makes those rows show an order/transaction number in the customer-visible
Detailed Transaction Report, and `TransactionDetailReturnOrderRefsIntegrationTest` must be updated. Whether that
is wanted is a decision, not a side effect.
**Supports:** H4 (latent).

### 5.7 OMS-only fields: present in OMS, never sent, joinable by parcel_id — for the managed case

**Source:** `lane-oms.md` §2–3. The advice payload carries only `reference_id`/`delivery_note_number`/`shipment_id`
(all `RETURN{parcel_id}`), facility, SKU and undamaged/damaged amounts. OMS holds `returns.disposition`
(→ `return_mgmt_lut`), `returns.managed_by` / `scanned_by` (rep id), `returns.manage_date` / `scan_date`,
`return_item` per-line quantities incl. `quantity_missing`.
**Observation:** on oms-laravel-api's live path an advice is sent **only** when the disposition has `advises_wms=1`
(seeded: *Restock Inventory*), so an advice that oms-laravel-api sent *and whose MANAGE committed* implies
disposition = Restock (+ the damaged split). This does **not** cover (i) the 2,689 historic advices sent by the v1
OMS / qa-api path, nor (ii) the divergence case in §5.10, where WMS holds an advice and OMS does not hold a
committed Restock. Within those limits, QA user and QA completion time are a cross-system lookup on `parcel_id`.
**Supports:** H1/H3, scoped. **Contradicts:** H2 for fields 6, 9 (QA user), 10.

### 5.8 Timestamps: no true "completed" stamp on the auto-receive path; proxies are faithful

**Source:** `markFinished` (`ReturnAdviceAutoReceiveService`) uses bulk JPQL updates
(`AdviceRepository` `UPDATE Advice a SET a.state = :state WHERE a.id = :id`, `AdvicepositionRepository`), so
`@LastModifiedDate` does not fire and `advice.modified` stays = `created` (v2 cohort: 22/22). **A RETURN advice has
no other route to FINISHED** (review R2-2, correcting round-1 F7): `AdviceService.close()` rejects non-REGULAR
(`"Close inbound BOL not allowed for type"`), the other FINISHED writers are TRANSFER / HUB_AND_SPOKE paths, and
`ReceivingService` only ever sets `OPEN`. SBDEV-2236 chose "RETURN advice stays OPEN until the dock scans" on a
partial auto-receive — but nothing then finishes it once the dock has received every position, so it stays **OPEN
permanently** (S8). Latent: all 2,822 RETURN advices on PRD are FINISHED. `goodsreceipt.receiptdate` has no writer (`git grep -i receiptdate src/main` → entity + migrations only);
PRD all-time **0 / 20,346** populated.
**Observation:** auto-receive runs inside the advice/create request (stock records within ~1 s of
`advice.created`), so `max(goodsreceiptposition.created)` per advice is a faithful receiving-completion time **when every position is
fully received** — derive completion from the positions (Σ GRP amount ≥ notified), never from `advice.state`, which
for a dock-completed partial would read OPEN forever.
**Supports:** H1 (fields 10/11 are (b)).

### 5.9 Receiving user is a system principal on the auto path

**PRD (D5), 180 days:** `anonymous` 540 rows (2026-04-17 → 2026-09-22) = the **v1-era** principal (the split lines
up with the cutover, not with a missing-user fallback); `oms_integration` 86 rows (2026-09-30 → today) = v2.
No human operator in this 180-day population. A dock completion of a partial auto-receive *would* record the
human (`lane-wms.md` §5) — none on PRD.
**Observation:** "receiving user" in WMS is the integration principal; the human is the OMS QA operator
(`returns.managed_by`). OMS's `?? 1` fallback (`QaReturnService.php:124`, `:353`) can attribute a return to rep 1
when auth resolves nobody.

### 5.10 OMS↔WMS writes are not atomic — WMS can hold a RETURN advice with no committed OMS manage (review F1)

**Source:** `QaReturnService::updateReturnManagement` runs in `DB::connection('tenant')->transaction` (`:339`),
sets disposition / `manage_date` / `managed_by`, then calls WMS (`:386-387`); *"A WMS failure rolls back the whole
manage transaction"* (`:383`). WMS commits the advice and the auto-received stock in its own transaction. OMS calls
with `timeout = 30 s`, `retryAttempts = 3` (`WmsApiService.php:36-37`). OMS itself names the outcome at
`QaReturnService.php:738-739`: *"ENTITY_ALREADY_EXITS, which means stock for this parcel was already advised — most
likely by an earlier attempt that reached WMS before this transaction rolled back"*, and asks a human to reconcile
(`:747-757`). WMS's `IdempotencyFilter` covers only byte-identical replays of a *completed* request.
**Observation:** the result is a FINISHED WMS RETURN advice with stock received while OMS `returns` has
`managed = 0`, `disposition / manage_date / managed_by` NULL — or, later, a non-Restock disposition, since only
Restock calls WMS. The `service_log` row of the failed attempt is rolled back too (S6), so **OMS keeps no trace
that the WMS advice exists.** This is exactly the population an audit exists to surface (stock returned to
inventory with no managed return behind it).
**Not measured:** no lane has OMS DB access. The count needs, per tenant:
`SELECT r.parcel_id FROM returns r WHERE r.parcel_id IN (<parcel ids from WMS RETURN advices created after the tenant's cutover>) AND (r.managed = 0 OR r.disposition IS NULL OR NOT EXISTS (SELECT 1 FROM return_mgmt_lut l WHERE l.return_mgmt_lut_id = r.disposition AND l.advises_wms = 1))`
(`NOT EXISTS` / `IS NULL`, not `NOT IN`, so a NULL disposition is counted — R2-6)
plus WMS advices whose parcel has no `returns` row at all.
**Scope to the post-cutover cohort (R3-4):** feed the query only parcel_ids from advices created after the tenant's OMS v2 / WMS v2 cutover (WineCo: `advice.created > 2026-09-26`, 22 advices). For the 2,689 v1-era advices `managed = 0` / a non-`advises_wms` disposition does not signal non-atomicity (the v1 sender never ran `updateReturnManagement`; `advises_wms` was bootstrapped 2026-07), so they would inflate the count — report the cohorts separately if both are wanted. Whether v1-era returns look divergent in the v2 `returns` table is unmeasured (no OMS DB access).
**Consequence:** the audit must **surface** the mismatch, not just join — as a two-step ad-hoc support query (WMS parcel list → OMS query above), not a built-in WMS report column (R3-1: WMS cannot read OMS data). Still a query concern — no schema
change — so the headline holds; but the claim "the parcel_id lookup is complete" does not.
**Supports:** H4 (new axis: cross-system consistency).

## 6. Updated Hypothesis Ranking

| # | Hypothesis | Final confidence | Key evidence |
|---|---|---|---|
| H1 | (a)/(b) cover the fields | **high** (v2 cohort n = 22 advices / 86 positions; all-time 10,173 positions once the CREATED-era record shape is handled) | §5.1, 5.2, 5.3, 5.7, 5.8 |
| H2 | a schema change is needed | **low** — no field requires one; final bin and damaged UL need a *code* change | §5.5, 5.6 |
| H3 | AC already satisfied, only needs a query | **medium** — true for the core chain; false for final bin, damaged UL, and the §5.10 divergence (needs a flag) | §5.2 vs §5.5/5.6/5.10 |
| H4 | links unreliable | **medium, reshaped** — label path broken (relabel); ordernumber path clean on PRD but unconstrained; FK path reliable; OMS↔WMS not atomic (unmeasured) | §5.4, §5.10 |

## 7. Verdict

**No SBDEV-2778 field needs a schema change.** The return is keyed by `parcel_id` end to end (OMS PK + SCAN guard;
WMS `advice.externalid` UNIQUE + `ENTITY_ALREADY_EXITS`), and inside WMS a real FK chain (`advice → goodsreceipt /
adviceposition → goodsreceiptposition → unitload / stockunit / mywms_user`) covers the receipt — 626/626 positions on
WineCo PRD, 86/86 in the v2-written cohort. Every remaining field is a WMS join or a cross-system lookup on
`parcel_id` against OMS `returns` — **with one caveat the audit must surface rather than hide**: OMS and WMS writes
are not atomic (§5.10), so some WMS advices may have no committed Restock behind them; the size of that population is
unmeasured.

| # | Field | Class | How |
|---|---|---|---|
| 1 | Return ID | **(a)** | = `parcel_id`; `substring(advice.externalid from 7)`. OMS has no other return id (§5.1) |
| 2 | Original order ID | **(a)** merchant order no., same facility · **(b)** OMS order id | WMS: `customerorder.clientordernumber` via `externalnumber = parcel_id` — the **client/merchant** order number (e.g. `97564336432:807`). WMS never receives the OMS order id; if the AC means that, it is (b) on **every** facility via OMS `parcel.order_id` |
| 3 | Original parcel ID | **(a)** | `advice.externalid` suffix; carrier id via `customerorder.parcelexternalnumber` |
| 4 | Inbound BOL ID | **(a)** | `advice.number` (IBOL…) + `goodsreceipt.number` (GRT…) via FK. No `billoflading` row exists for returns |
| 5 | SKU + qty | **(a)** | `adviceposition.itemdata_id` → `itemdata.item_nr`, `notifiedamount`, `notifieddamagedamount`; received `goodsreceiptposition.amount`. OMS-only: `quantity_missing` (never sent) |
| 6 | Disposition | **(a)** restock/damaged split · **(b)** label | WMS advice ⇒ Restock **if the OMS manage committed** (§5.10); damaged split on the position. Label via OMS `returns.disposition` |
| 7 | Created UL IDs | **(a)** undamaged · **code change** damaged | FK `goodsreceiptposition.unitload_id`, reported as the label with `-X-{id}` stripped (§5.4). Damaged UL: comment-string only (§5.6) |
| 8 | Destination locations | **(b)** put-away lane · **code change (T2)** final bin | `unitload_record` on `ordernumber = adviceposition.number AND activitycode = 'RETURN'`, **any** recordtype (CREATED in 2025-26), keyed per stripped UL label, set-based — **not** label = labelid; 10,173/10,173 all-time. Final bin only heuristically (§5.5) |
| 9 | Receiving user | **(a)** WMS principal · **(b)** QA human | `goodsreceiptposition.operator_id` (system user); human = OMS `returns.managed_by` (NULL in the §5.10 case) |
| 10 | Return QA completion ts | **(b)** | OMS `returns.manage_date` (MySQL `timestamp`, session-tz converted — normalise to UTC against WMS `timestamptz`; stamped *before* the WMS call; NULL in the §5.10 case). WMS proxy `advice.created` |
| 11 | Receiving completion ts | **(b)** | `max(goodsreceiptposition.created)` per advice, valid once every position is fully received (derive from positions, not `advice.state` — §5.8); `goodsreceipt.receiptdate` never written (0/20,346) |

The ticket's T3 rationale ("data model") does not hold. Whether the *remaining* work is T2 or T3 depends on scope
choices — see §8.

**Confidence:** high for fields 1–5, 7 (undamaged), 9, 11 on WineCo (v2 cohort measured, code read on develop);
medium for 6/9-human/10 (cross-system, §5.10 unmeasured), the damaged path (no data on either env) and field 8 (depends
on what "destination" means).

## 8. Recommendation

- [x] **Fix later** — on the existing ticket. **The tier is conditional** (review F2; router T3 shapes include
  *Flyway migration* and *multi-repo*):
  - **T2** if the deliverable is a **WMS-only** audit query/report (option 1 or 3 below) built on the corrected §7 joins,
    and the OMS side findings (S4–S6) are **split off** to an OMS ticket (decision 6). The §5.10 mismatch flag is **not**
    part of a WMS-only report (it needs OMS `returns` data WMS cannot read): at T2 it exists only as an **ad-hoc two-step
    support query** (option 3) — export the WMS parcel_id list, run the §5.10 OMS query. Any built-in flag is option 2 / T3.
    The §5.5 final-bin change stays T2 (report-contract change, one repo). S3 is T1 on its own; it rides the T2 deliverable
    because it changes `transaction_detail()` output and the V2.2.25 IT. The `unitload_record` index is
    **not needed** — the set-based join covers all 10,173 positions (§5.3, R2-3) — so it is no longer a T3 trigger.
  - **Stays T3** if: an OMS screen + new WMS read endpoint (option 2 — wms2-api + oms-laravel-api +
    siteboss-frontend), or S4–S6 stay on this ticket (it remains multi-repo, as it was filed: "[WMS v2 + OMS v2]").
  - Draft via **`wms-feature-plan`** (v2) after Nam's decisions. At T2, per `wms-triage`: no verify script, assertions
    in JUnit ITs — include a **relabelled UL** and a **position-less advice** in the IT fixture (both broke the first
    draft's join).

Decisions needed from Nam before planning (each changes scope or tier):
1. **"Destination locations": put-away lane (available today) or final bin** (§5.5, T2 code change)? **ANSWERED 2026-10-15: put-away lane.**
2. **"Original order ID": merchant order number (WMS has it) or OMS order id** (OMS-only)? **ANSWERED 2026-10-15: merchant order number.**
3. **Where does the audit view live?** (1) WMS report, OMS fields blank — overlaps SBDEV-1944; (2) OMS screen calling
   a new WMS read endpoint keyed by `RETURN{parcel_id}` — multi-repo, T3; (3) an ad-hoc support query. **ANSWERED 2026-10-15: WMS, scope narrowed (see Decisions).**
4. **Is the §5.5 / S3 change to `transaction_detail()` output wanted** (order/transaction number appearing on DAMAGED
   and put-away TRANSFER rows)? **ANSWERED 2026-10-15: yes, S3 included.**
5. **Measure §5.10 first?** It needs an OMS tenant DB query (no MCP for OMS here), scoped to the post-cutover cohort
   (R3-4). Recommended before any build: if the divergent population is non-zero, the mismatch is the most valuable
   finding — delivered as the two-step ad-hoc support query (a WMS-only report cannot carry it, R3-1). **ANSWERED 2026-10-15: flag not built; measuring still open.**
6. **S4–S6 (OMS repo): on this ticket or split off?** The policy default is *on this ticket*: each is sub-T3 when
   tiered on its own (`wms-triage` "Tier the ADDED scope on its own"), the ticket is still Open, and the skill says
   sub-T3 findings are not split for other reasons ("do not invent other reasons to split"). Splitting them to an
   OMS ticket is what lets 3736 drop to a single-repo T2 — a trade only Nam can make. **ANSWERED 2026-10-15: split off.**

### Decisions (Nam, 2026-10-15)

1. **Destination = putaway lane.** No final-bin change; the §5.5 change is NOT in scope.
2. **Original order ID = merchant order number** (`customerorder.externalnumber`) — the default; WMS has it.
3. **Audit view = WMS.** Scope narrowed on triage: a WMS screen needs wms2-web-ui, and extending the Receiving Report
   means altering DB view `receiving_dto_view` (Flyway) — both T3 triggers. So 3736 ships a **read-only wms2-api audit
   endpoint on a native set-based query** (no migration, no view) — **T2**; the wms2-web-ui page is a separate proposed
   UI ticket.
4. **S3 included.** The `transaction_detail()` output change is accepted; update
   `TransactionDetailReturnOrderRefsIntegrationTest`.
5. **Mismatch flag: not built** (R3-1); documented as the two-step ad-hoc support query, scoped to the post-cutover
   cohort (R3-4). Measuring it is still open (needs an OMS tenant DB).
6. **S4–S6 split to a proposed OMS ticket** (not yet filed; Nam confirms).

**In scope for 3736:** the endpoint + S1, S2, S3, S8. **Tier T2.**

### Side findings — routed per the ticket policy

| # | Finding | Repo | Tier | Route |
|---|---|---|---|---|
| S1 | `goodsreceipt.receiptdate` has no writer — 0/20,346 on PRD all-time. Fix must stamp UTC consistently (`LocalDateTime` on a `timestamptz` column, `V1.2.01__utc_standard_tables.sql`) | wms2-api | T1 | onto SBDEV-3736 |
| S2 | `markFinished` bulk JPQL leaves `advice.modified = created` on the auto-receive path. The two repository methods are shared — set `modified` in `markFinished` only, or list every caller first | wms2-api | T1 | onto SBDEV-3736 |
| S3 | Damaged-UL transfer passes `orderNumber = null` (§5.6). Changes `transaction_detail()` output; update the V2.2.25 IT | wms2-api | T1 | onto SBDEV-3736 (pending decision 4). S3 is T1 on its own; it rides the T2 deliverable because it changes `transaction_detail()` output and the V2.2.25 IT |
| S4 | OMS `processReturn` returns `return_id = $return->id`, always null | oms-laravel-api | T0 | onto SBDEV-3736 by default; split per decision 6 |
| S5 | OMS `scanned_by` / `managed_by` fall back to rep **1** when auth resolves nobody | oms-laravel-api | T1 | as S4 |
| S6 | OMS `service_log` row for a **failed** restock advice is rolled back with MANAGE — it erases the **only** OMS evidence of a divergent WMS advice (§5.10), not just trail noise | oms-laravel-api | T1–T2 | as S4; rank **first** of S4–S6 |
| S8 | A partially auto-received RETURN advice stays OPEN permanently: SBDEV-2236 left it OPEN for the dock, but no code path finishes a RETURN advice once the dock receives the rest (`close()` rejects non-REGULAR; `ReceivingService` sets only OPEN). Latent — 0 OPEN of 2,822 on PRD | wms2-api | T1 | onto SBDEV-3736 |
| S7 | `return_item` quantities are signed `tinyint` (max 127 per parcel line) | oms-laravel-api | **T3** (schema) | **propose only** — exposure unmeasured |

S1–S6 and S8 are sub-T3 on their own and default onto this ticket (Open); where S4–S6 end up is decision 6. None of
them is required for the audit AC. S7 is T3 and only proposed.

## 9. Open Questions

- **Size of the §5.10 divergent population** — OMS tenant query, per tenant. Highest-value open question.
- **Does WineCo's live QA run on oms-laravel-api or still on v1 OMS/qa-api?** ADVICE_IMPORT payloads are re-serialised
  DTOs and cannot distinguish the senders; this decides whether `lane-oms.md` governs WineCo's post-cutover advices.
- **Meaning of "destination locations"** and **"original order ID"** — decisions 1–2.
- **Damaged path is unverified against data** — 0 damaged positions on WineCo PRD and UAT.
- **Other tenants** — all figures are WineCo. ShipItEZ (two warehouses) matters most for cross-facility field 2.
- **OPEN-forever RETURN advices (S8)** — latent today; becomes real the first time an auto-receive is partial.
- **Dock-path shapes** — N GRPs per position (one per case) and carrier destinations (`transferUnitLoadToCarrier`, no
  TRANSFERRED-to-location row); both latent (0 on PRD) but the audit query must tolerate them.
- **Positions merged per SKU** in OMS — WMS positions cannot be tied to a specific `order_item_parcel_id` when one SKU
  spans two lines. Not needed by the 11 fields as worded.
- **`message_archived` is empty on WineCo PRD while `message` holds ~1.8 M rows** — the 365-day cleanup does not appear
  to run there. Irrelevant to the verdict; relevant if the raw ADVICE_IMPORT payload is ever cited as audit evidence.

## 10. References

- **Tickets:** SBDEV-3736 (this), SBDEV-2778 (origin AC), SBDEV-1406 (V2.2.25), SBDEV-1944, SBDEV-3261, SBDEV-1512, SBDEV-3313
- **Plans:** `4-Archieves/wms2/plan/SBDEV-2778-return-to-inventory-not-received-bol-not-closed.md`,
  `SBDEV-2236-return-advice-auto-receive-fix.md`, `SBDEV-1512-receive-damaged-from-returns.md`
- **Workflow:** `3-Resources/workflows/wms2-receiving-putaway-workflow.md`
- **Code:** pinned at wms2-api `origin/develop` 11468c4a; oms-laravel-api `origin/develop` 1369c109 (citations and line numbers are as pinned; origin/develop has since moved to 371d8a09 / 4981db86 — `QaReturnService` `:383`→~`:387`, `:738-739`→~`:760`; SBDEV-3742 `wms_warning_code` reinforces S8: an aborted auto-receive is a real route to a partially received, permanently OPEN RETURN advice; no verdict changes); siteboss-frontend `origin/main` 64836f4d
- **Evidence (preserved):** `4-Archieves/wms2/plan/SBDEV-3736-evidence/` — `lane-wms.md` (reference join SQL §4,
  corrected), `lane-oms.md`, `db-wineco-prd.md` (D1–D10), `review-critic.md` + `review-critic-r3.md` (independent review, 19 findings over rounds 1–2, plus round 3)

## 11. Verification Log

| Date | Check | Result |
|---|---|---|
| 2026-10-13 | 180-day RETURN population, WineCo PRD: positions ↔ GRP ↔ unitload FK | 626/626, 0 null, 0 dangling; v2 cohort 86/86 |
| 2026-10-13 | Label-join vs FK-join for return ULs (two instruments) | disagreed 538 vs 0 → Nirwana relabel; FK authoritative |
| 2026-10-13 | `unitload_record` coverage for RETURN ULs | 1252 = 626 × 2; v2 cohort 86 TRANSFERRED w/ ordernumber |
| 2026-10-13 | `goodsreceipt.receiptdate` populated | 0/150 (180d), 0/20,346 all-time |
| 2026-10-13 | Corrected reference join on `IBOL014975` (relabelled) + `IBOL015569` (v2) | destination `PutAwayLane` on all 5 rows; old label join → NULL on the relabelled 2 (control went red as expected) |
| 2026-10-13 | Set-based destination join, all-time, any recordtype | 10,173/10,173 filled (2,279 via 2025-26 CREATED rows); TRANSFERRED-only filter would blank 22.4% — `IBOL012303` NULL ×5 (control) |
| 2026-10-13 | RETURN advice states, PRD all-time | 2,822 FINISHED, 0 OPEN (S8 latent) |
| 2026-10-13 | Independent critic review, round 1 | REVISE, 3H/4M/5L — all applied |
| 2026-10-13 | Independent critic review, round 2 | 10 resolved, 2 partial; new 1H/2M/4L (R2-1…R2-7) — applied or answered (R2-7 answered by decision 6's policy default) |
| 2026-10-15 | Current set-based reference SQL (`lane-wms.md` §4), WineCo PRD all-time (critic r3) | 10,173 rows, 0 NULL destination, 0 no-UL, 0 multi-row `(ordernumber, label)` groups; 180-day window 624 rows, 0 NULL |
| 2026-10-15 | Independent critic review, round 3 | 6 resolved / 1 partial; new 0H/1M/4L (R3-1…R3-5) — applied |

## Completeness checklist

| # | Concern | Considered? |
|---|---|---|
| 1 | In-scope sources enumerated | ✓ §3.5 |
| 2 | "Nothing wrong" hypothesis | ✓ H3 |
| 3 | Primary evidence per hypothesis | ✓ §5 (code quotes in lane files; PRD rows D1–D10; critic re-runs) |
| 4 | Confidence per hypothesis | ✓ §6 |
| 5 | Null results documented | ✓ no return-id column, no receiptdate writer, no FK stockrecord→advice, 0 damaged rows, no MANAGE history write, §5.10 unmeasured (named query) |
| 6 | v1/v2 deltas | ✓ cohort split (§4); v1 code is reference-only |
| 7 | Related reports/plans cited | ✓ §10 |
| 8 | Open questions | ✓ §9 |
| 9 | One recommendation picked | ✓ Fix later (tier conditional, §8) |
| 10 | Downstream verify script | no — at T2 per `wms-triage`, assertions go in JUnit; at T3 opt-in ≤15 rows |
| 11 | Ticket | ✓ inbound SBDEV-3736 in frontmatter; no new ticket filed (S4–S6 placement = decision 6; S7 proposed only) |

## Implementation status (2026-10-15)
- **Merged:** yes. PR https://github.com/SiteBossInc/wms2-api/pull/518 merged to develop 2026-10-15 (merge `a05e8998`, PR head `f6445546`). Deployed to dev and tested there by two sessions; results are on the ticket. ClickUp: **on dev**. Worktree and branch removed.
- **Shipped:** the returns audit endpoint (A) and fixes S1, S2, S3, S8, plus the R3-L2 RETURN label fix. S8 finishes on an exact match only (Nam, review M1).
- **Tests:** CI command, unit 8,320 / IT 879, 0 failures.
- **ClickUp:** SBDEV-3736 → pr submitted.
- **Follow-ups filed:**
  - SBDEV-3768 (OMS S6/S4/S5, plus measuring the divergence)
  - SBDEV-3769 (UI page)
  - SBDEV-3775 (TRANSFER corrections)
- **Proposed, not filed:**
  - S7 (`return_item` tinyint, T3)
  - the partial index on `unitload_record (ordernumber, label) WHERE activitycode = 'RETURN'` (T3, needs a migration)
