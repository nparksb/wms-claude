---
title: "SBDEV-1512 — WMS/QA: Receive Damaged from Returns"
ticket: "SBDEV-1512"
ticket_url: "https://app.clickup.com/t/868f2bh69"
type: "feature"
severity: "urgent"
priority: "urgent"
status: "BOTH PHASES MERGED TO DEVELOP 2026-09-17 — Phase 1 wms2-api `0e4c5a43` (PR #367), Phase 2 oms-laravel-api `5955e50b` (PR #567), merged in that order as the ordering constraint required. The end-to-end capability is now live on DEV: the QA UI already sent qty_damaged, the OMS now forwards it as amount_of_bottles_damaged, and the WMS receives the total and locks the damaged subset (entity_lock 103 + move to Damaged). ⚠ V2.2.32 runs against every tenant DB on next boot. NOT yet on UAT or PRD, and it reaches ShipItEZ/WineCo at their v2 cutover (weeks away). Phases 3-4 out of scope (v2 QA UI lacks Defects A/C). Open: SBDEV-3366 (OMS netting, gates ShipItEZ cutover) and SBDEV-3382 (whole-unit damage writes no stockrecord)."
project:
  - "wms2-api"
  - "oms-laravel-api"
version: "v2"
requester: "Brent Campbell"
assignee: "Nam Park / David Oppenheim"
created: "2026-09-15"
updated: "2026-09-16"
db_verified: true
db_verified_note: >
  E0 — ShipItEZ runs v1 in production (`wh01_shipitez`, no `flyway_schema_history`, taking writes
  2026-09-15); `wh01_shipitez_v2`'s **advice data** is a migration snapshot frozen 2026-09-10 — its
  **schema** is not frozen and is kept Flyway-current (§5.1 row 1b) — carrying an identical
  1037 RETURN advices, so no return has ever been processed by a v2 WMS for this client.
  E1 — a whole-schema `information_schema.columns` scan for `%damag%` returns exactly two columns
  (`inventory_record.damage`, `stock_view.damaged`); nothing on advice / adviceposition /
  goodsreceiptposition. Positive control: the same instrument on `%notified%` returns
  `notifiedamount` + `notifiedcases`, so the zero is real.
  E2 — `stock_view.damaged` is `sum(CASE WHEN su.entity_lock = 103 OR ul.entity_lock = 103 ...)`
  and never references `location.name='Damaged'`. Two instruments disagree on today's population:
  171 rows locked 103 vs 158 rows sitting in the Damaged location (15 locked elsewhere, 2 in the
  location unlocked); quantities agree at 42 because the extras carry amount 0.
  E3 — all 1037 RETURN advices are FINISHED with `goodsreceiptposition.amount == notifiedamount`
  (15 most recent positions inspected across six advices, 2026-08-20 → 2026-09-08). Restock itself
  is not broken; only the damaged half never leaves the OMS.
  E4 — an all-damaged return yields a zero-position advice: 1 of 1037 on live `wh01_shipitez`.
  That is a lower bound only; partial damage leaves no WMS trace, so true exposure needs
  `sum(quantity_damaged)` from the QA MySQL, for which no MCP server exists in this session.
  E5 — v1/wms-api tolerates an unknown advice key: `WebConfigurer` sets
  `FAIL_ON_UNKNOWN_PROPERTIES=false` at three sites and no class in v1's `json` package carries
  `@JsonIgnoreProperties` (blind spot from the evidence lane — the inherited-annotation case on
  `AbstractWebServiceDto` — was closed while drafting this plan: that class carries only
  `@JsonSubTypes` and `@JsonProperty`).
related:
  - "sbdocs/1-Projects/wms2/plan/SBDEV-1512-evidence/db-verification.md"
  - "sbdocs/1-Projects/wms2/plan/SBDEV-1512-evidence/wms-damaged-capability.md"
  - "sbdocs/1-Projects/wms2/plan/SBDEV-1512-evidence/qa-station-return-flow.md"
  - "sbdocs/1-Projects/wms2/plan/SBDEV-1512-evidence/review-architect.md"
  - "sbdocs/1-Projects/wms2/plan/SBDEV-1512-evidence/review-critic.md"
  - "sbdocs/1-Projects/wms2/plan/SBDEV-1512-evidence/oms-stock-sync-routing.md"
  - "sbdocs/1-Projects/wms2/plan/SBDEV-1512-evidence/review-d6-migration.md"
blocked_by:
  - "SBDEV-3366 — https://app.clickup.com/t/868m5j9qr — oms-laravel-api netting regression (dd17b84f). CORRECTNESS dependency gated on ShipItEZ v2 cutover, not on this ticket's merge; SBDEV-1512 is safe to ship before it"
  - "sbdocs/1-Projects/wms2/plan/SBDEV-2778-return-auto-receive-hard-blocks-return-on-partial-failure.md"
  - "sbdocs/3-Resources/workflows/wms2-receiving-putaway-workflow.md"
  - "sbdocs/3-Resources/architecture/wms2-oms-integration-map.md"
  - "sbdocs/3-Resources/architecture/wms2-state-machine-catalog.md"
tags:
  - plan
  - wms2
  - returns
  - receiving
  - damaged
  - oms-integration
  - qa-station
---

# SBDEV-1512 — WMS/QA: Receive Damaged from Returns

**Ticket:** [SBDEV-1512](https://app.clickup.com/t/868f2bh69)
**Project:** wms2-api · qa-api · qa-ui | **Version:** v2 | **Type:** feature
**Priority:** urgent | **Tier:** T3
**Status:** draft rev7 — D6 lane folded in; all design questions closed. **D6/D7 settled; D8 withdrawn on E8** (the defect is in `oms-laravel-api`, not the WMS, and is filed as [SBDEV-3366](https://app.clickup.com/t/868m5j9qr)). **This plan is safe to ship now and unsafe at ShipItEZ cutover without SBDEV-3366** — the WMS work is correct and can ship independently, but until netting is restored every damaged return computes wrongly in the OMS, and ShipItEZ's cutover is where the return volume arrives (§3.11.3). **D6 is settled in both halves** — D6-A (`notifiedamount` = the total; no migration) and D6-B (the `notifieddamagedamount` column + `V2.2.32`), the latter kept by Nam on 2026-09-15 (§10). D6-B carries **two** columns — `notifieddamagedamount` and `damageappliedat` — in a single `ALTER`, which makes the recovery worklist deterministic (§3.2). **No design question is left open.**
**Date:** 2026-09-15

**Reference point for every code claim in this document:** `origin/develop` of each repo, fetched
2026-09-15 — `v2/wms2-api` @ `9e294d4b`, `v1/wms-api` @ `4cdd945`, `v1/qa-api` @ `b905d77`,
`v1/qa-ui` @ `ad4284b`. *(Earlier revisions said the local `v2/wms2-api` checkout was "56 commits
behind". That was true when first measured and **stale immediately after** — a `git fetch` brought it
current. Re-verified 2026-09-15: `HEAD` = `origin/develop` = `9e294d4b`, `rev-list --count
HEAD..origin/develop` = **0**. No conclusion changes, because every claim was derived from
`origin/develop` explicitly either way, but the instruction not to read the checkout was resting on a
fact that had expired.)* Citations give a file plus a short distinctive quoted snippet rather than a
bare line number, because line numbers decay on every merge.

**Review lineage, so a later reader knows what each lane actually saw.** The **Architect** lane
(SOUND WITH CHANGES) graded the **rev1** snapshot, md5 `1b3cf2bc4af8be544e772d8299608aa2`; §3.1–§3.9
were byte-identical in rev2, so its design-core findings transferred unchanged. The **Critic** lane
(ITERATE) graded **rev2**. A third lane graded **D6 only** at rev5 (SOUND WITH CHANGES — three Highs,
all folded into rev6). No lane has seen the E7→E8 reversal, which was **deliberately not re-reviewed**
because it was scope *removal* plus a decision reversal, both of which shrink the reviewed surface.

**That third lane exists because rev5's own closing note said D6 was the one unreviewed addition, and
it returned three Highs** — an inert recovery worklist, an unboxing NPE that would have 500'd a
`permitAll()` endpoint for all live traffic, and a validation tier placed where it does not run. It
is the clearest evidence in this ticket that "the reviewers approved the design" and "the reviewers
saw this part" are different claims, and that tracking which is which is worth the bookkeeping.

---

## 0. Affected Sites

**Enumeration instrument.** Three `git grep` censuses over `origin/develop`, each with the positive
control that produced a non-zero result: (a) `receiveGoods(` across `src/main/java` → 3 hits, of
which 2 are call sites; (b) `setLockDamaged|moveStockToNewDamagedContainer` → 2 call sites, both in
`StockUnitController`; (c) `AdviceDto|AdvicePositionDto` across `controller/` → **1** controller
(`AdviceRestController`). *(Rev1 said 2, naming `FileImportController`; that file references only
`AdviceUploadDto`, so it is not what the stated instrument returns. Row 14's out-of-scope verdict is
unaffected — it is excluded on DTO shape, which is now the only reason given.)* **Blind spots, stated:** all three key on a
literal token, so a reflective invocation, a SpEL expression, or a mapping contributed by a
superclass or a `MappedInterceptor` would not appear. `AbstractRestController` was read and declares
no mapping; no reflective call to any of these symbols is plausible in this codebase, but "no
reflective caller" is a reasoned judgement here, not a measured one.

| # | Repo · Site | In scope? | Phase | Rationale |
|---|---|---|---|---|
| 1 | `v2/wms2-api` `json/AdvicePositionDto.java` | **In** | 1 | The wire field has to land somewhere. Six fields today; no damaged/condition/disposition field of any kind. |
| 2 | `v2/wms2-api` `service/ReturnAdviceAutoReceiveService.java` — `resolveRefs`, `bind`, `executeInternal`, `applyDamage` (incl. the `damageappliedat` stamp), the `ResolvedLine` / `AutoReceiveLine` / `AutoReceiveOutcome` records, `diagnose` | **In** | 1 | This is the only class that drives a RETURN receipt end to end; the damaged quantity must be validated pre-persist, carried through the positional zip, and applied after the receive. |
| 3 | `v2/wms2-api` `service/ReceivingService.java` — `receiveGoods` return type | **In** | 1 | Returns `void` today, so the caller cannot reach the `Stockunit` it just created. See §3.2 and §9 Alternative B. |
| 4 | `v2/wms2-api` `service/WmsConstants.java` — 6xx error block, `getErrorCodeName`, `getErrorCodeText` | **In** | 1 | The new outcome status needs a code; `600`/`601`/`602` are taken (`RETURN_AUTO_RECEIVE_PARTIAL`, `PRINTER_NOT_AVAILABLE`, `RETURN_AUTO_RECEIVE_ABORTED`), `603` is free. |
| 5 | `v1/qa-api` `common_util/wms_api.py` — `build_wms_create_advice_request` | **In** | 2 | `amount_of_bottles = returned_items[item.item_id]['qty_undamaged']` is where the damaged quantity is dropped. |
| 6 | `v1/qa-api` `view_helpers/returns_helper.py` — the `except WmsException` block in `process_managed_returned_parcel` | **In** | 4 | Emits `messages` as a **string** where every other error path emits a list of dicts. The producer half of Defect C. *(Rev1 attributed this to `views/parcel_info.py`; that file's four `messages` occurrences are all `'messages': None` and it only passes the helper's dict through, so it needs **no** change — §3.9.)* |
| 7 | `v1/qa-ui` `components/returns/dispositionSelection.vue` + `pages/manageReturn/_id.vue` | **In** | 3 | Defect A — the `mounted()` pre-selection never emits `change`, so the parent keeps `disposition: 1`. |
| 8 | `v1/qa-ui` `store/util.js` — `processApiErrors` | **In** | 4 | Defect C — `.forEach` on a string throws out of the `catch`, so no toast fires and the persistent modal never clears. |
| 9 | `v2/wms2-api` `service/StockunitService.java` — `setLockDamaged` | **Excluded — reused unchanged** | 1 (consumer only) | Per D1 it is the reuse target. It already does everything needed (move, split, lock 103, stock history, optional label — plus a sixth side effect, `triggerReplenishmentMaintenance`, which §3.3 prices). Changing it would put the manual-damage UI path at risk for no gain. |
| 10 | `v2/wms2-api` `service/UnitloadService.java` — `moveStockToNewDamagedContainer` | **Excluded — unchanged** | — | Holds the transactional boundary and the `findByIdForUpdate(damagedLocation.getId())` deadlock-ordering guard. Touching it would re-open SBDEV-3086's lock-ordering work. |
| 11 | `v2/wms2-api` `controller/rest/AdviceRestController.java` | **In** *(rev1 said excluded; D6 reverses it)* | 1 | D6 sets `notifiedamount = undamaged + damaged` and the new `notifieddamagedamount` in the save loop. Rev1's claim that the file needs no edit was true **only** of the warning envelope, which is genuinely generic (`warning.put("code", autoReceiveOutcome.code())`, `...reason()`, `...correlationId()`, …) — T1.9 still grades that, and it is a different claim about the same file. |
| 11a | `v2/wms2-api` `model/Adviceposition.java` | **In** | 1 | One nullable `BigDecimal notifieddamagedamount` field + accessors. No JPA association is added — manual FK convention is unchanged. |
| 12 | `v2/wms2-api` `json/StockChangeDto` + `SharedService.getStockChangeDTO` | **Excluded** | — | D5: two messages, both already emitted by existing code, and both **correct** — see §3.11. No DTO change, no call-site change. |
| 13 | `v2/wms2-api` `src/main/resources/db/migration/V2.2.32__adviceposition_notified_damaged_amount.sql` | **In** *(rev1 said excluded; D6 reverses it)* | 1 | One `ALTER TABLE public.adviceposition ADD COLUMN IF NOT EXISTS notifieddamagedamount numeric(19,2);` + the `-- WHY` header. Nullable, so no backfill and no default; catalog-only, so no rewrite. Version from the all-remote-branch sweep in §5.1 row 1, **not** from listing the directory. |
| 14 | `v2/wms2-api` `controller/FileImportController` (`AdviceUploadDto`) | **Excluded** | — | Spreadsheet advice upload, a different DTO with a different shape, and not reachable from the QA station. |
| 15 | `v1/wms-api` `json/AdviceDto`, `json/AdvicePositionDto`, `AdviceRestController` | **Excluded from behaviour change; test-only addition** | 2a | D2 — v1 is not being fixed. A *test* is added to pin the tolerance claim (§3.7); it changes no production code. |
| 16 | `v1/qa-api` `view_helpers/returns_helper.py` — `advise_wms_of_managed_return`'s `total_returned_items = sum(qty_returned)` gate | **Excluded from Phase 2, flagged** | — | Changing this gate is what would make a *fully*-damaged return reach the WMS, and it is exactly the change that is unsafe for live v1 traffic. See §3.1 W2 and §10 OQ-2. |
| 17 | `v1/wms-web-ui`, `v2/wms2-web-ui`, `v2/wms2-mobile-ui` | **Excluded** | — | No WMS UI surface changes: the damaged stock appears in the existing damaged-inventory view by virtue of `entity_lock=103`, which those screens already render. |
| 18 | `v2/oms-laravel-api` | **Excluded** | — | D5 keeps the `StockChangeDto` contract identical, so OMS parses exactly what it parses today. |

---

## 1. Problem Statement

### 1.1 What the client reports

Ryan Fernandez (ShipItEZ), 2026-05-29: *"I have the restock option selected every time, yet it
still does not print and the bottles disappear."* Brent Campbell's ticket asks that damaged units
identified at the QA station be received into the WMS and **placed in the Damage location**.

### 1.2 What is actually happening

The QA station sends a RETURN-type Advice to the WMS via `PUT {wms_base_url}rest/advice/create`.
`build_wms_create_advice_request` (`v1/qa-api flask_app/common_util/wms_api.py`) sets

```python
amount_of_bottles = returned_items[item.item_id]['qty_undamaged']
if not amount_of_bottles or amount_of_bottles == 0:
    # don't send positions with amount_of_bottles = 0
    continue
```

so the damaged quantity never leaves the OMS, and a line that is 100 % damaged is dropped entirely.
The WMS could not store it if it were sent: the `%damag%` column scan in E1 returns only
`inventory_record.damage` and `stock_view.damaged`, nothing on `advice`, `adviceposition` or
`goodsreceiptposition`.

Four probes with positive controls (evidence §4) establish that **no path in v2 receives stock into
a damaged state**. The three `setEntityLock(QUALITY_FAULT)` write sites are all operator-initiated
moves of stock that already exists. The method behind that claim is a `git grep` for the constant
name plus a second grep for the literal `103`; the literal grep found exactly one hit and it is a
*read* (the `stock_view` definition). **Two blind spots, both material because Alternative A's
rejection rests on this invariant:** a native-SQL `UPDATE`, and a **propagating** write that names no
constant — `StockunitService` does `stockUnitDest.setEntityLock(stockUnit.getEntityLock());`, which
can carry `103` onto a new stock unit without matching either grep. The count of three *literal*
sites is right; "no path receives stock into a damaged state" is the claim the propagating write
could in principle falsify, and no receiving path reaches that line. **This is
net-new capability, not a broken feature.**

E3 partially refutes the reported cause: restock is **not** broken. All 1037 RETURN advices on
`wh01_shipitez_v2` are `FINISHED` with `goodsreceiptposition.amount == notifiedamount`. What
vanishes is precisely the quantity the QA station never sends. Blind spot: E3 measures the WMS side
only and cannot see whether a label physically printed.

### 1.3 ⚠ THE CRITICAL REFRAME — grade the lock, not the location

`stock_view.damaged`, the view behind the client's damaged-inventory report, is defined as

```sql
sum(CASE WHEN ((su.entity_lock = 103) OR (ul.entity_lock = 103)) THEN su.amount ELSE (0)::numeric END) AS damaged
```

It **never references `location.name = 'Damaged'`** (method: read of the view body in
`V2.2.00__base_v2_schema.sql`; blind spot: a tenant whose view was redefined out-of-band by a
migration not in `db/migration` would differ, and §7 T3.4 measures the view body per tenant rather
than assuming it).

The ticket asks for the stock to be "placed in the Damage location". **Doing only that leaves the
client's report as empty as it is today.** Therefore:

> **Every acceptance criterion in this plan grades `entity_lock = 103`. Location membership is a
> secondary assertion, never the primary one.**

The two instruments genuinely disagree about today's population, and the disagreement is the reason
each AC must name which one it grades:

| Instrument | Rows | Qty |
|---|---|---|
| `entity_lock = 103` on stockunit **or** unitload | **171** | 42 |
| unit load sitting in location `Damaged` (id 50184, type_id 50053 on `c1wh`) | **158** | 42 |
| both | 156 | — |
| locked damaged but **not** in the Damaged location | **15** | — |
| in the Damaged location but **not** locked damaged | **2** | — |

Quantities agree at 42 only because the 15 extra rows carry amount 0. At row level they do not
agree, so "42 units are damaged" is true under both instruments and "158 damaged stock units exist"
is true under neither.

Separately, `transaction_detail.damaged` keys on a **third** axis —
`sr.activitycode = 'DAMAGED' AND sr.type = 'STOCK_CREATED'`. Reusing `setLockDamaged` covers this
axis too, because `moveStockToNewDamagedContainer` calls
`transferStockToUnitLoad(..., CODE_DAMAGED, ...)`, which writes `stockrecord` rows with
`activitycode = 'DAMAGED'`. That is the single strongest argument for reuse over both a bespoke
receive-into-damaged path and a lock-only design; §3.10 and §9 Alternative D make it explicit.

> **⚠ Correction to `wms-damaged-capability.md` §6(b) — do not carry its stronger claim forward.**
> That file states that a damaged return "lands in the report as `Returned`, with `damaged = 0`"
> because the label `CASE` puts `Returned` ahead of `Damaged`, and concludes *"Fixing (a) alone does
> not fix (b)"*. Checked against the function body on `c1wh-shipitez-uat`:
> `transaction_detail(client_number_in, sku_in, startdate_in, enddate_in)` is a **UNION of
> per-`activitycode` arms**, each carrying its own `WHERE sr.activitycode = ...` and its own
> `GROUP BY c.name, c.cl_nr, i.id, i.name, i.item_nr, i.vintage, i.bottle_size, sr.type,
> date_trunc('DAY', sr.modified), sr.ordernumber, sr.operator`. A `DAMAGED`/`STOCK_CREATED` record
> and a `RETURN`/`STOCK_CREATED` record therefore land in **separate rows**, and the ordered label
> `CASE` is evaluated **per row** — so the damaged row has `returned = 0` and is labelled `Damaged`.
> The evidence file's conclusion holds **only** for a lock-only design (set `entity_lock = 103`,
> write no stock record). D1 is not that design. **Blind spot, stated:** the grouping of one arm and
> the `damaged` column expression were read directly and the union shape inferred from them; the
> arms of a 17 633-character function were **not** enumerated. §7.5 M9 closes this by running
> `transaction_detail` over a range containing a known manual *Transfer To Damaged* and checking the
> row label.

### 1.4 Blast radius

- All 1037 RETURN advices are `FINISHED` with `received == notified`, so restock itself is not
  broken — **only the damaged half vanishes**.
- An all-damaged return yields a zero-position advice: **1 of 1037** on live `wh01_shipitez`. That
  is a measured lower bound, not the exposure.
- Partial damage leaves **no WMS trace at all**, so the true exposure is only obtainable as
  `sum(quantity_damaged)` from the QA MySQL (query in §10 OQ-1; no MCP server for that DB in this
  session).
- **ShipItEZ does not get this in production on merge.** They run **v1** (`wh01_shipitez`, no
  `flyway_schema_history`, taking writes 2026-09-15). `wh01_shipitez_v2` is a migration snapshot
  whose **advice data** is frozen at 2026-09-10 with an identical 1037 RETURN advices — its **schema**
  is separately kept current, so do not read "frozen" as "not a Flyway target" (§5.1 row 1b). The WMS half of this fix reaches them at
  their v2 cutover. The **QA half ships into live v1 traffic on day one**, because `qa-api` is
  shared and routes by `wms_url` per facility — see §5.1 row 4 and §8.

---

## 2. Current Architecture

### 2.1 The intake path

`PUT /rest/advice/create` → `AdviceRestController.create(@RequestBody List<AdviceDto> adviceList, ...)`.
`/rest/**` is `permitAll()`, with the tenant chosen from an unauthenticated header
(`TenantFilter`). `create()` is deliberately **not** `@Transactional`: a throw after
`adviceRepository.save` would burn `advice.externalid = RETURN{parcel_id}` and every OMS retry
would then die on the duplicate guard.

For a RETURN advice with non-empty positions and `RETURN_ADVICE_AUTO_RECEIVE_ACTIVATED` enabled,
`ReturnAdviceAutoReceiveService` runs three phases:

| Phase | Method | Transactional? | What it does |
|---|---|---|---|
| 0 | `validate(adviceDto)` → `resolveRefs` | `@Transactional(tenantTransactionManager, readOnly = true)` on `resolveRefs`, reached through the `@Lazy self` proxy; the CUPS probe runs **outside** it | Resolves printer (RETURN type), rejects null positions, caps at 500, asserts `MAXIMUM_RECEIVING_DURING_INBOUND` parses, resolves `UNIT_LOAD_TYPE_BOX`; per position resolves SKU + box type and calls `putawayDestinationResolver.requireUsablePlacement(...)`. **Runs before anything is persisted.** |
| 1 | `bind(validated, savedAdvice, savedPositions)` | no | Pure in-memory positional zip; aborts if sizes diverge or any `positionExternalId` mismatches. |
| 2 | `execute(plan)` → `executeAsIntegrationUser` → `executeInternal` | **no, by design** | Sets the principal to `oms_integration`, then per position calls `receivingService.receiveGoods(line.advicePositionId(), null, false, line.amount(), line.amount(), 1, line.boxtypeId(), plan.printer())`. Only after every position succeeded does `self.markFinished(adviceId)` flip positions and advice to `FINISHED` in one tenant transaction. |

`AutoReceiveOutcome` is `(Status, adviceNumber, failedSku, received, total, FailureReason,
correlationId, description)` with `Status ∈ {SUCCESS, PARTIAL, SKIPPED}` and `isWarning()` being
`status != SUCCESS`. `PARTIAL` returns immediately, so `markFinished` is **not** reached and the
advice stays `OPEN` for dock recovery. `diagnose()` probes observed state, never the exception:
`PRINTER_UNREACHABLE → ZPL_TEMPLATE_MISSING → CONFIG_MISSING → UNKNOWN`. The `FailureReason`
javadoc records that adding a value is a security-relevant change: it must name a **class** of
condition and must not encode any printer name, location name, entity id, sysprop key, SQL or
exception text, because the envelope crosses a `permitAll()` boundary.

### 2.2 Where the stock lands today

`ReceivingService.receiveGoods` is `@Transactional(value = "tenantTransactionManager", rollbackFor
= {BusinessException.class, FacadeException.class})` and **returns `void`**. Per case it creates a
unit load at `InboundWorkstation`, creates a stock unit with no lock argument (so `entity_lock`
stays at its default `0`), saves a `Goodsreceiptposition` carrying `stockunitId`, and transfers the
unit load to the resolved putaway destination. Because the auto-receive path passes `amountCases =
1` and `amountBottlesPerCase == amountBottles`, the `while (amountBottles > 0)` loop runs exactly
once — **one unit load and one stock unit per position**.

Live confirmation (evidence §2, `c1wh-shipitez-uat`, goods-receipt positions on RETURN advices,
last 120 days): 11 rows at `PutAwayLane` with `entity_lock = 0`, and all 2 956 `RETURN` stock
records carry `tostoragelocation = 'InboundWorkstation'`. Returned stock arrives unlocked and
immediately pickable.

The case label is accumulated inside the per-case loop and printed in an `afterCommit` callback
gated on sysprop `PRINT_CASE_LABEL` (`Boolean.parseBoolean`, **default OFF**). A CUPS failure is
logged and swallowed.

### 2.3 The damage capability that already exists

`StockunitService.setLockDamaged(Stockunit, BigDecimal amount, String comment, boolean printLabel,
Principal principal)` is **not** `@Transactional`; the atomicity lives in
`UnitloadService.moveStockToNewDamagedContainer`, which is
`@Transactional(value = "tenantTransactionManager", rollbackFor = {BusinessException.class,
FacadeException.class})` and whose **first statement must remain**
`locationRepository.findByIdForUpdate(damagedLocation.getId())` — the deadlock-ordering guard.

Preconditions, read from the method body: the source stock unit must be at `entity_lock = 0` (a
`switch` admits `NOT_LOCKED`, raises named `BusinessException`s for `SHIPPED` and
`GOING_TO_DELETE`, and since SBDEV-3226 names the offending lock for everything else);
`amount > 0`; `availableamount >= amount`; and `locationRepository.findByName("Damaged")` must
resolve or it throws `EntityNotFoundException`. `amount` is clamped down to `stockUnit.getAmount()`
if larger. It always mints a **`Box`** unit load, which happens to satisfy the
`CONSTRAINT_OVERSTOCK_BOX` constraint on the `Damaged` location type — a `Pallet` would not.

`printLabel(printLabel, unitLoad, damagedStock)` runs **last**, wrapped in a catch that only warns,
and selects `printerRepository.findByTypeAndProcessdefaultTrue(WmsConstants.PrinterType.INBOUND)` —
an **INBOUND** printer, whereas auto-receive uses a **RETURN** printer. Two different selections for
the two paths.

The existing callers are both in `StockUnitController` (`/transferToDamaged`,
`/bulkTransferToDamaged`), both gated by
`@RequiresFunction(WmsConstants.FunctionEnum.WEB_UI_ACTION_ADJUST_LOCK_DAMAGED)`, and both follow
the same idiom: `stockunitRepository.findById(id).orElseThrow(...)` **outside** any transaction
(OSIV is off, so the entity is detached), then `setLockDamaged(stockUnit, ...)`. §3.3 reuses that
exact idiom rather than passing an entity out of the receive transaction.

### 2.4 The `Damaged` location is name-keyed and not guaranteed

`WmsConstants.STORAGE_LOCATION_DAMAGED = "Damaged"`, resolved by
`locationRepository.findByName("Damaged")` at each of its four consumers. There is no id constant,
no enum, no FK, **no unique index on `location.name`**, and — unlike `Nirwana` / `Clearing` /
`Spawn` — no `'This is a system used entity. DO NOT REMOVE OR LOCK IT!'` description; the row's
description is `NULL` in both seeds. `UtilRestController.initDB` does **not** create it: the
creation line is commented out and the method then does
`findByName(...).orElseThrow(...)`, i.e. it throws rather than repairing.

Measured, not assumed — both ShipItEZ UAT tenants have it, with different identities:

| Tenant | id | `type_id` | `sltname` | `area_id` |
|---|---|---|---|---|
| `nywh-shipitez-uat` | 6 | 3 | `overstock box` | 0 (`Default`) |
| `c1wh-shipitez-uat` | **50184** | **50053** | `overstock box` | **50100** |

The `50xxx` ids are the v1-migration offset: on `c1wh` that row came from the client's own v1 data,
not from the v2 seed.

### 2.5 The QA station side

`process_managed_returned_parcel` branches on `if disposition_id == 2 and receive_now in
true_values:`, and the only producer of `receive_now` is `pages/manageReturn/_id.vue`'s
`if (dataObject.disposition_id === 2)`. The id `2` is hard-coded on both sides, in two repos.
Two independent instruments put "Restock Inventory" at id 2 (qa-api's `readme/SYSTEM_INFO.md` and
the v2 OMS tenant seed, whose migration docblock explicitly warns against keying off the id);
neither reads the live ShipItEZ MySQL.

`advise_wms_of_managed_return` gates the WMS call on `total_returned_items = sum(qty_returned) > 0`
and `get_config().CONTACT_EXTERNAL`. Because `manageReturnTable.vue` **decrements** `qty_returned`
by the damaged amount, a fully damaged parcel gives `0`, the gate fails, and the helper logs
*"No returned items, skipping call to create advice in WMS."* while returning success.

---

## 3. Design

### 3.1 The wire contract — additive, and why `amount_of_bottles` must keep its meaning

**New key: `amount_of_bottles_damaged`** on each advice position. Java field
`AdvicePositionDto.amountOfBottlesDamaged`, type `Integer` (nullable), annotated
`@JsonProperty("amount_of_bottles_damaged")`. Absent or `null` means zero, which is exactly today's
behaviour — so REGULAR advices, the spreadsheet import path, and any qa-api build older than
Phase 2 are unaffected without a single conditional.

**Semantics, and this is the load-bearing part of the whole plan:**

| Field | Meaning | Changed by this plan? |
|---|---|---|
| `amount_of_bottles` | the **undamaged** quantity | **No** |
| `amount_of_bottles_damaged` | the **damaged** quantity, in addition to the above | new |
| total received by v2 | `amount_of_bottles + amount_of_bottles_damaged` | derived |

D1 says "receive the FULL quantity". That is satisfied by the *sum*, not by redefining
`amount_of_bottles`. Redefining it would break D2's own safety argument: v1 would then receive
damaged bottles as **normal, sellable, pickable stock**, silently, for every live v1 client on the
day Phase 2 ships. That is a worse outcome than today's loss, and it is why the field semantics are
pinned here rather than left to the implementer.

**Three candidate wire designs were evaluated. Two are rejected; the rejections are load-bearing.**

- **W1 (chosen).** `amount_of_bottles` unchanged; new key carries the damaged quantity; the
  position-emission predicate in `build_wms_create_advice_request` stays keyed on
  `amount_of_bottles > 0`. v1 behaviour is byte-identical except for one dropped key. v2 fixes
  every **mixed** line. Residual gap: a line that is 100 % damaged is still not emitted — see
  §10 OQ-2.
- **W2 (rejected).** As W1 but the predicate becomes `undamaged + damaged > 0`. **This breaks live
  v1 production.** Derived from `origin/develop` of `v1/wms-api`: `AdviceRestController` rejects
  `amount_of_bottles < 0` but **accepts `0`**, saves the advice and the position with
  `notifiedamount = 0` — committing and thereby burning `externalid` — and then calls
  `receivingService.receiveGoods(pos.getId(), null, false, 0, 0, 1, ...)`, where
  `ReceivingService` does `if (amountBottles < 1) { throw new BusinessException(
  "argumentMustBeGreaterZero", "amount", amountBottles); }`. Result: HTTP 400 → qa-api raises
  `WmsException` → the whole return is compensating-rolled-back → and because the advice row with
  `externalid = RETURN{parcel_id}` is already committed, **every retry hits the duplicate guard and
  the parcel becomes permanently unmanageable.** A silent loss is turned into a hard, unrecoverable
  failure.
- **W3 (rejected).** `amount_of_bottles` becomes the full quantity and the new key carries the
  damaged subset. Never emits `0`, so no 400 — but v1 then receives damaged bottles as normal
  sellable stock, which can be picked and shipped to a customer. Trading a reporting gap for a
  quality escape is not an acceptable trade, and it contradicts D2's premise that v1 merely
  *ignores* the new field.

**v2-side validation, deliberately written for the predicate W1 does not yet use.** In
`resolveRefs`, validate the **total**, not the undamaged field:

- `damaged := amountOfBottlesDamaged == null ? 0 : amountOfBottlesDamaged`
- `damaged >= 0`, else `FIELD_MALFORMED_FORMAT` / `amount_of_bottles_damaged`
- `undamaged >= 0` (relaxed from the current `>= 1`)
- `total = undamaged + damaged`; `total >= 1` and `total <= MAX_UNITS_PER_POSITION` (100 000),
  reusing the existing constant and its existing error shape
- no `damaged <= total` check is needed — it holds by construction

Relaxing `undamaged >= 1` to `total >= 1` costs one line and makes v2 **forward-ready**: the moment
ShipItEZ (and every other v1 client) is on v2, closing OQ-2 is a one-line predicate flip in qa-api
with zero further WMS work. It introduces no v1 risk because W1 never emits such a position today.

**Config keys:** none. **No new sysprop, no new feature flag.** The behaviour is driven entirely by
the wire value, and a zero/absent value reproduces today's path exactly. Adding a flag would create
a **second** such flag, and one silent-off path already exists: `RETURN_ADVICE_AUTO_RECEIVE_ACTIVATED`
gates `ReturnAdviceAutoReceiveService` **entirely**, so on a tenant where it is `false`, qa-api sends
`amount_of_bottles_damaged`, the WMS parses it, `resolveRefs` never runs (so §3.5's pre-flight never
runs either), and nothing applies damage — the damaged units are simply never received, exactly as
today, with no warning and no log. That degradation is recorded in §6. `PRINT_CASE_LABEL` is a third,
on the label rather than the stock. The claim here is therefore narrow and checkable: **no new flag
is added**, not "there is no way to be silently off".

### 3.2 Carrying the quantity through the three phases

**Record deltas** (the positional zip in `bind` is the only thing holding these in sync, and it
already aborts on any size or `externalId` divergence):

```java
public record ResolvedLine(String positionExternalId, String sku, Long boxtypeId,
                           int amount, int damagedAmount) { }

public record AutoReceiveLine(Long advicePositionId, String positionExternalId, String sku,
                              Long boxtypeId, int amount, int damagedAmount, Long itemdataId) { }
```

`amount` becomes the **total** to receive (`undamaged + damaged`), and `damagedAmount` the subset to
damage afterwards. Naming `amount` as the total keeps `executeInternal`'s existing
`receiveGoods(..., line.amount(), line.amount(), 1, ...)` call correct with no change — one unit
load holding the full physical quantity, which is D1 and D3.

**`ReceivingService.receiveGoods` return type: `void` → `List<Long>`** (ids of the stock units
created by this call, in creation order).

**Rationale.** The caller cannot otherwise reach what it just created. This is a **source-compatible**
change: Java permits discarding a return value, so the only other call site,
`ReceivingController` (`receivingService.receiveGoods(advicePositionId, carrierUnitloadId, ...)`),
needs no edit. The census behind "only two call sites" is `git grep -n "receiveGoods("` over
`src/main/java` on `origin/develop`, which returned three hits — the declaration plus two callers;
its blind spot is a reflective invocation, of which there is none in this codebase that I can find
by that instrument. §9 Alternative B records the re-query design and why it loses.

**Data-model delta — D6-B: two nullable columns on `adviceposition`, one `ALTER`.** *(Rev1 said "none". That is
**withdrawn**, not qualified: both review lanes converged independently on it as the root defect, and
Nam settled it 2026-09-15.)*

```sql
-- src/main/resources/db/migration/V2.2.32__adviceposition_notified_damaged_amount.sql
--
-- WHY: <multi-paragraph header, matching every sibling V2.2.2x file — V2.2.26 runs ~45 comment
-- lines, V2.2.30 ~23. State: what the column records, that it is nullable-with-no-default so NULL
-- means "written by a path that does not set it", and that ddl-auto is none so a tenant that misses
-- this surfaces as a per-request 42703 rather than a startup failure (§5.1 row 1a).>
ALTER TABLE public.adviceposition
    ADD COLUMN IF NOT EXISTS notifieddamagedamount numeric(19,2),
    ADD COLUMN IF NOT EXISTS damageappliedat       timestamp with time zone;
```

**Idiom, deliberately.** `public.` + `IF NOT EXISTS`, following `V2.2.13` and `V2.2.30` — **not**
`V2.2.03`'s bare unqualified form, which is the file this repo's `CLAUDE.md` singles out as *not
replay-safe*. No explicit `BEGIN`/`COMMIT`: Flyway runs each script in a transaction and DDL is
transactional on PostgreSQL, matching all three sibling files.

**Lock and rewrite risk: negligible, stated once so it is not re-derived.** PostgreSQL 11+ adds a
nullable column with no default as a **catalog-only** change — no table rewrite. `adviceposition` is
9 613 rows / 2 832 kB on the largest reachable tenant (`wh01_shipitez_v2`); the `ACCESS EXCLUSIVE`
lock is taken and released immediately.

plus one field on the `Adviceposition` entity and two lines in `AdviceRestController`'s save loop,
beside the existing `position.setNotifiedamount(new BigDecimal(advicePosition.getAmountOfBottles()));`.

> #### ⚠ H2 — write the coalescing EXPLICITLY. `notifiedamount = undamaged + damaged` is an outage.
>
> `AdvicePositionDto.amountOfBottles` is a boxed `private Integer`, and so is the new field. Written
> literally, `undamaged + damaged` unboxes a `null` for **every request that omits the new key** —
> every REGULAR advice from the OMS, every RETURN from a `qa-api` that has not deployed Phase 2,
> every v1-era caller. That is an **NPE → HTTP 500 on a `permitAll()` endpoint, for essentially all
> live traffic**, the day Phase 1 reaches dev. The required form:
>
> ```java
> Integer rawDamaged = advicePosition.getAmountOfBottlesDamaged();
> int damaged = rawDamaged == null ? 0 : rawDamaged;
> position.setNotifiedamount(new BigDecimal(advicePosition.getAmountOfBottles() + damaged));
> position.setNotifieddamagedamount(rawDamaged == null ? null : new BigDecimal(rawDamaged));
> ```
>
> Note the asymmetry on the last line and keep it: `notifiedamount` coalesces to `0`, the **column**
> stays `null`, because `null` is what makes "written by a path that does not set this" readable.
> Graded by **T1.17**, mutation-checked by removing the coalescing.
>
> Do **not** review this against its neighbours for consistency — the neighbours are broken. The same
> loop already NPEs on `new BigDecimal(advicePosition.getAmountOfBoxes())` when `amount_of_boxes` is
> absent, and on `optionalBoxtype.get()` when `box_id` is absent. Pre-existing (FU-2), not D6's doing.

| column | value after D6 | value today |

| column | value after D6 | value today |
|---|---|---|
| `notifiedamount` | `undamaged + damaged` — **the total that physically arrives** | `undamaged` only |
| `notifieddamagedamount` | `damaged`; `null` when the wire key is absent | — |
| `damageappliedat` | the instant the damage **succeeded**; `null` until then | — |

**Two columns, one `ALTER`, one Flyway run, one ownership precondition.** The second column costs
nothing operationally — same migration, same statement, same `42501` exposure, same catalog-only
non-rewrite. The cost is conceptual only. Nam took it (2026-09-15) because an **approximate** worklist
loses the same information one layer up: it cannot say whether a given damaged portion was applied,
which is the question Half B exists to answer at all.

**Entity field — no initialiser (M4).** `Adviceposition.notifiedamount` is declared
`@Column(columnDefinition = "numeric(19,2)") private BigDecimal notifiedamount = BigDecimal.ZERO;`.
Copying that idiom two lines down would make **every** post-deploy row `0.00` and never `null`,
falsifying the NULL semantics this section and §5.1 row 5 both rest on. Declare it with **no
initialiser**.

**What `null` actually means, stated accurately.** Not "predates the feature" — **five** other writers
of `Adviceposition` leave it `null` forever and D6 touches none of them: `AdviceRestController`'s
`createTransfer` and `createHubAndSpoke`, `ReceivingService`'s `createAdviceWithPositions` and
`updateAdviceWithPositions`, and `FileImportController`'s spreadsheet import. So `null` means
**"written by a path that does not set it"** — which includes pre-feature rows and those five paths.
Behaviourally fine; worth saying, because a worklist that reads `null` as "old" would be wrong.

**Why a column — the deciding argument, which is not the worklist.** Once `notifiedamount` becomes
the total (D6-A), **nothing in the WMS records how much of it was damaged**. After the fact a mixed
line and a pure one are indistinguishable, in every failure state and in every audit, permanently —
a loss of exactly the quantity this ticket exists to stop losing. The recovery worklist below is one
*use* of the column, and the D6 review lane was right that as first written it did not work (H1); but
a broken query is a symptom of a weak justification, not a reason to drop the record. **Kept by Nam,
2026-09-15**, on the argument above rather than on the worklist.

**The secondary argument, which is what rev1 reached for.** It is consumed
within the request **only on the happy path**. Rev1 had no failure mode from which the damaged
quantity was recoverable: `PARTIAL` carried no quantity at all, `DAMAGE_FAILED` carried a SKU and no
number, and the documented recovery — an operator performing a manual damage move — needed a
quantity that existed only in the OMS MySQL and in one `LOG.error` line keyed by a correlation id
that no operator-facing surface indexes. One nullable column makes every one of those states
queryable, and gives the recovery story an actual data source — **provided the worklist query can
tell a recovered position from an unrecovered one, which is harder than it looks.**

> #### ⚠ H1 — the rev5 worklist was INERT
>
> **What rev5 had, and why it was worthless.** It keyed on
> `NOT EXISTS (SELECT 1 FROM stockrecord sr WHERE sr.activitycode = 'DAMAGED' AND sr.ordernumber = ap.number)`.
> A `DAMAGED` stockrecord **never carries an `ordernumber`**: `moveStockToNewDamagedContainer` calls
> `transferStockToUnitLoad(stockUnit, container, amount, WmsConstants.CODE_DAMAGED, null, comment, false, true)`
> — that `null` is the order number, planted verbatim by `StockrecordService`. So the `NOT EXISTS` was
> true for every row and the worklist returned **every** damaged position forever, recovered or not.
> *Measured* on `wh01_shipitez_v2`: `DAMAGED` **396 rows / 0** with a non-empty `ordernumber`;
> positive control from the same expression — `PICKING` 886 310/886 310, `RETURN` 2 956/2 956 — so
> the instrument reads the column and the zero is real.
>
> **And the replacement the lane proposed does not work either** — that is the "do not re-propose"
> block below, kept separate because it is the durable half.

**The worklist — deterministic, one predicate, no join:**

```sql
-- Positions whose damaged portion was recorded but never applied.
SELECT id, externalid, notifiedamount, notifieddamagedamount
FROM   adviceposition
WHERE  notifieddamagedamount > 0
  AND  damageappliedat IS NULL;
```

**Where the stamp is written, precisely.** In `applyDamage` (§3.3), **after
`stockunitService.setLockDamaged(...)` returns normally** — never before the call, and never on the
attempt. `applyDamage` is not transactional, so the stamp is its own short
`tenantTransactionManager` update on the position row.

**The one residual window, stated rather than smoothed over.** The stamp commits in a *separate*
transaction from the damage, so a crash in between leaves a position that **was** damaged showing
`damageappliedat IS NULL` — a false positive on the worklist. That matters more than it first
appears: on a **mixed** line the source stock unit still holds the undamaged remainder at
`entity_lock = 0`, so an operator who re-damages from the worklist without checking would damage a
*second* tranche. The window is one statement wide, but the consequence is not benign, so **the
recovery runbook must verify the position's current damaged stock before acting** — and that
verification is a human step, because as established below no FK supports it as a query.

*The atomic alternative, with the reason it is not the default:* making `applyDamage`
`@Transactional(tenantTransactionManager)` would let `moveStockToNewDamagedContainer` join it and the
stamp commit atomically. It also puts `setLockDamaged`'s `mintUnitloadLabel()` — a `REQUIRES_NEW`
sequence write, deliberately hoisted **out** of any transaction — inside one, which is the shape this
repo has been bitten by before. The implementer may take it, but only with that hazard re-checked
explicitly; the non-transactional stamp plus a verification step is the lower-risk default.

> #### ⚠ Do not re-propose the goods-receipt join. It was evaluated and it does not work.
>
> The obvious alternative — join `adviceposition → goodsreceiptposition → stockunit` and look for
> `entity_lock = QUALITY_FAULT` — was proposed by the D6 review lane and **rejected on evidence**,
> so that it is not rediscovered as a cheaper option later.
>
> `StockunitBusinessService.transferStockToUnitLoad` creates a **new** destination stock unit when
> `destinationStockUnit == null && (sourceStockunit.getAmount().compareTo(amount) > 0 || fixLocationAssignment != null)`
> — i.e. on any **partial** move — and only otherwise relocates the source
> (`sourceStockunit.setUnitloadId(destinationUnitload.getId())`).
>
> | line | who ends at `entity_lock = 103` | does `goodsreceiptposition.stockunit_id` point at it? |
> |---|---|---|
> | **mixed** (damaged < total) — the common case | a **new** stock unit | **No.** The GRP still points at the source, which stays at `entity_lock = 0`. |
> | fully damaged | the source stock unit itself | Yes |
>
> So that join reports **every mixed position as unrecovered** — a false-positive worklist instead of
> rev5's universal one. Different failure, equally useless. **There is no FK from the damaged stock
> unit back to the advice position**, which is the whole reason `damageappliedat` exists rather than a
> query over existing tables.

It also removes a second defect rev1 did not notice. `AdviceRestController` sets
`position.setNotifiedamount(new BigDecimal(advicePosition.getAmountOfBottles()));` — the
**undamaged** field — while `receiveGoods` would take the **total**, making every mixed line a
permanent over-delivery against its own advice. It would not have thrown, but only because the same
controller does `adviceEntity.setAllowoverdelivery(true);` ~200 lines earlier, defusing
`ReceivingService`'s `if (!advice.getAllowoverdelivery())` guard — luck, not design, and an unpinned
single-flag dependency under the whole feature. Setting `notifiedamount` to the total **removes** that
dependency instead of pinning it.

⚠ **It does not remove all flag dependencies, and rev5 implied it did.** D6 trades
`allowoverdelivery` for the symmetric `allowshortdelivery`, which `AdviceService` reads in the
short-delivery guard — `if (amountReceived < advicePosition.getNotifiedamount().intValue())` inside
`if (!advice.getAllowshortdelivery())`. Post-D6 `notifiedamount` is the total, so a mixed RETURN
finished having received only the undamaged portion would trip that guard **if the flag were ever
`false`**. `AdviceRestController` sets `setAllowshortdelivery(true)` and `setAllowoverdelivery(true)`
on adjacent lines, so it is always `true` on this path today — stated rather than claimed away.

**Consumers of `notifiedamount`, and the bound on the change.** *Instrument:* `git grep -ln
"notifiedamount" origin/develop -- src/main` (14 files) for the Java side, plus **E6**'s live-schema
queries for the SQL side — `information_schema.views` matching `%notifiedamount%` → **one** view
(`receiving_dto_view`), and `pg_get_functiondef` over `pg_proc` with `prokind='f'` → **zero** report
functions, with a positive control (`%activitycode%` returns true for `stock_history`,
`transaction_detail`, `transaction_summary`) proving the instrument works. *Blind spots, all from
E6:* the schema read is a snapshot frozen 2026-09-10, so a function added in a later `V2.2.x` would
not appear; `prokind='f'` excludes procedures and aggregates; a Java projection interface deriving
the column by property name is invisible to both instruments. The blast radius is therefore
**bounded to two Java consumers plus the view behind one of them** — `AdviceRepository`'s
`SUM(ap.notifiedamount) as qtyRequired` and `ReceivingDtoViewRepository`'s
`ap.notifiedamount AS orderedbottles` — and **no report function is reached**. Both consumers now
read the quantity that physically arrived, which is the correct value. §6 records it.

⚠ **"Two consumers" is the count of *reporting* consumers only.** The same grep also returns two
**behavioural** readers that rev5 did not name and that differ in kind — `AdviceService`'s
short-delivery guard and `ReceivingService`'s over-delivery guard, both above. Neither changes outcome
on this path (both flags are set `true` by the controller), but "bounded to two consumers" was the
wrong shape of claim: it is two reporting consumers **plus two guards**.

**What D6 buys the rest of this design, stated once so later sections can rely on it:** every
failure path below is now recoverable from the WMS's own data, so §3.4's loop ordering is a **free
choice argued on its own merits** rather than a choice between two unrecoverable states.

### 3.3 Applying the damage — reuse `setLockDamaged`, in the caller's proven idiom

A new private method on `ReturnAdviceAutoReceiveService`:

```java
private void applyDamage(AutoReceiveLine line, Long createdStockunitId)
        throws BusinessException, FacadeException
```

**How the id reaches it.** `receiveGoods` returns `List<Long>` (§3.2), and `executeInternal`'s
receive loop stores it as `Map<Long, Long> receivedStockunitByPositionId`, keyed on
`line.advicePositionId()`. The damage loop reads that map by the **same** key. This is stated
because leaving the association to the implementer is the exact hazard Alternative B was rejected to
avoid — a wrong association damages an arbitrary unit load and no test would notice. Do not key the
map on list index, and do not iterate the two loops in the assumption that their orders agree.

Sequence, per position with `damagedAmount > 0`, executed **after** `receiveGoods` has returned
(i.e. after its transaction has committed) and **inside** the `executeAsIntegrationUser` block so
that `stockrecord` rows are attributed to `oms_integration`:

1. Require exactly one created stock unit for the position. The auto-receive path passes
   `amountCases = 1` and `amountBottlesPerCase == amountBottles`, so the
   `while (amountBottles > 0)` loop runs once.

   > ⚠ **WITHDRAWN 2026-09-16 (Nam). This row specified `IllegalStateException`, not
   > `BusinessException`, on the reasoning that a broken loop-shape invariant is a programming error
   > and routing it into the `DAMAGE_FAILED` ladder would present a defect as "stock received, advice
   > FINISHED, operator please fix by hand".**
   >
   > **That instruction was unreachable as written**, found by the conformance lane (F5): the damage
   > loop catches `BusinessException | FacadeException | RuntimeException`, and
   > `IllegalStateException` is a `RuntimeException` — so it would have been swallowed into
   > `DAMAGE_FAILED` regardless, and the row's own stated goal could never have been met by the throw
   > type alone. Meeting it would have required narrowing the catch, which is strictly worse: the
   > exception would then escape as an HTTP 500 **after** every position was received and **before**
   > `markFinished` ran, leaving the advice `OPEN` with all its stock already in — the double-receive
   > hazard §3.4's two-loop ordering exists to prevent.
   >
   > **Implemented as `BusinessException` → `DAMAGE_FAILED`.** A missing stock-unit id is a real
   > failure of that position; the advice IS finished, the damage IS outstanding, and the recovery
   > worklist (`notifieddamagedamount > 0 AND damageappliedat IS NULL`) finds it. `applyDamage` still
   > **throws rather than skipping** — silently continuing would recreate the exact defect this
   > feature removes.
2. `Stockunit stockUnit = stockunitRepository.findById(id).orElseThrow(...)` — **re-read by id**,
   exactly as `StockUnitController` does. This is deliberate: OSIV is off, and an entity handed out
   of `receiveGoods`'s committed transaction would be detached with no guarantee about which fields
   are initialised. Re-reading also picks up the post-transfer `storagelocation_id`.
3. `stockunitService.setLockDamaged(stockUnit, new BigDecimal(line.damagedAmount()),
   "RETURN DAMAGED " + line.positionExternalId(), false, principal)`.
4. **Only if step 3 returned normally** — stamp `adviceposition.damageappliedat = now()` for
   `line.advicePositionId()`, in its own short `tenantTransactionManager` update. **Never before the
   call and never in a `finally`**: the column means *the damage succeeded*, not *it was attempted*,
   and a stamp on the attempt would make the §3.2 worklist silently miss every real failure — the
   same class of defect as the inert query it replaces. The one-statement window between the damage
   commit and this stamp, and why the recovery runbook must verify before acting, are in §3.2.

`setLockDamaged` then does everything the reporting surfaces need — moves the stock to `Damaged`,
**splits** the stock unit when `damagedAmount < amount`, sets `entity_lock = 103` inside
`moveStockToNewDamagedContainer`'s transaction, writes `stockrecord` rows with
`activitycode = 'DAMAGED'`, and emits the second OMS message. Nothing in `StockunitService` or
`UnitloadService` changes.

**⚠ It also has a sixth side effect that the reuse inventory must not omit**, because it changes the
scalability arithmetic in §7.3: between the OMS message and the label print it calls
`triggerReplenishmentMaintenance(stockUnit.getItemdataId())` →
`replenishmentOrderMaintenanceService.recalculateForItem(itemDataId)`, which is
`@Transactional(REQUIRED)`. With no ambient transaction — which is exactly `applyDamage`'s shape —
**it opens its own transaction and takes row locks**. So each damaged position costs **two**
transactions, not one, and the second one is a locking write into the replenishment subsystem. The
swallow-or-rethrow logic there is runtime-predicated on
`TransactionSynchronizationManager.isActualTransactionActive()` and is correct for a
non-transactional caller, so this is a cost to state, not a bug to fix.

**Preconditions.** Rev1 derived these from `setLockDamaged`'s body alone and therefore missed three
that live one layer down, in `transferStockToUnitLoad` — which `moveStockToNewDamagedContainer`
calls with `ignoreLock = false`. `setLockDamaged` itself carries `// TODO check locks on unit load`
/ `// TODO check locks on location`; the checks are not absent, they are delegated. Two of the three
are **environment-dependent**, which is the point:

| Precondition | Holds on this path? |
|---|---|
| source stockunit `entity_lock == NOT_LOCKED` | **Yes, by construction.** `createStockUnit` passes no lock argument and the column defaults to `0` (live corroboration: 11 recent RETURN goods-receipt positions at `PutAwayLane` all read `entity_lock = 0`). |
| `amount > 0` | **Yes.** Guarded by `damagedAmount > 0`; the stock unit holds `total ≥ damagedAmount ≥ 1`. |
| `availableamount >= amount` | **Not guaranteed — the weakest link.** `getAvailableamount()` is `@Transient` `amount.subtract(reservedamount)`, so any reservation makes `setLockDamaged` throw *"Stock unit has too much reserved amount."* Two concrete grabbers exist: `ReplenishGeneratorService`'s `changeReservedAmount(sourceStock, replenishOrder.getRequestedamount(), false, CODE_REPLENISHMENT_CREATED, …)` driven by `ReplenishOrderJob`, and the operator-reachable `StockUnitController /adjustReservedAmount`. §3.4 sizes the window and T1.7a asserts the failure path. |
| **source unit load `entity_lock == NOT_LOCKED`** | **Environment-dependent.** `transferStockToUnitLoad`: `if (lock != NOT_LOCKED) throw new BusinessException("Source unitLoad=" + sourceUnitload.getLabelid() + " is locked=" + lock);` The unit load is freshly created here, so this holds unless something locked it in the window. |
| **source *location* `entity_lock == NOT_LOCKED`** | **Environment-dependent, and the sharp one.** Same method: `throw new BusinessException("Source location=" + sourceLocation.getName() + " is locked=" + lock);` The source location is **not** `InboundWorkstation` — `receiveGoods` has already run `transferUnitLoadToLocation(unitload, putaway.location(), …)`, so it is the **putaway destination**. A locked `PutAwayLane` (a cycle count, an operator hold) turns **every** damaged return into `DAMAGE_FAILED` while ordinary receives keep succeeding. Manual row M10 measures it. |
| `unitloadType.getStockunitallowed()` on the destination | **Environment-dependent.** `if (!unitloadType.getStockunitallowed())` in the same method; `moveStockToNewDamagedContainer` always mints a `Box`, so this is a property of the tenant's `Box` unit-load type. |
| `Damaged` location resolves | **Pre-flighted at validate time** — §3.5. That pre-flight covers **one** of the at-least-three ways a tenant can make the damage step fail; the other two are the location and unit-load-type locks above, which cannot be pre-flighted because they are evaluated against state that does not exist until the receive has run. |
| destination accepts a `Box` | **Yes.** `moveStockToNewDamagedContainer` always mints a `Box`, satisfying `CONSTRAINT_OVERSTOCK_BOX`. A design that placed a `Pallet` into `Damaged` would not — a second reason to reuse rather than reimplement. |

**Exception handling — the damage loop catches `BusinessException | FacadeException |
RuntimeException`, and `RuntimeException` is not optional.** `applyDamage`'s declared `throws` clause
covers only the checked pair, but the real failure modes are largely unchecked: `setLockDamaged`
reaches two `orElseThrow(() -> new EntityNotFoundException(...))` sites (the `Damaged` location and
`UNIT_LOAD_TYPE_BOX`), and `moveStockToNewDamagedContainer` opens with
`findByIdForUpdate(damagedLocation.getId())`, whose 5 s `lock_timeout` surfaces as an unchecked
`PessimisticLockingFailureException`. If the loop caught only the declared pair, an unchecked throw
would escape `execute()` → `create()` as an **HTTP 500 after every position had been received and
before `markFinished` ran** — leaving the advice `OPEN` with all its stock already in the building,
which is precisely the double-receive hazard §3.4 introduces `DAMAGE_FAILED` to prevent. This is the
same rationale the receive loop already carries in a comment that calls it "NOT optional"; the
damage loop inherits it. T1.7 is split into a checked and an unchecked case for this reason.

**Transaction shape.** `applyDamage` runs with **no** surrounding transaction, like `executeInternal`
itself. `moveStockToNewDamagedContainer` opens its own `tenantTransactionManager` boundary. This
matters for the OMS message: `MessageService.sendStockChangeMessage` →
`StockChangeNotificationService.sendAfterCommit` → `OmsNotificationService.sendAfterCommit`, whose
javadoc carries an explicit rail — *"a caller must never wrap a call to this method in its own
afterCommit callback, because the registration below would land in the list Spring is already
iterating and be discarded unseen — no POST, no message row, no metric. Enforced by
NestedCallSiteRailTest."* `applyDamage` is not inside any `afterCommit` callback, and must not be
moved into one. The no-transaction branch of `sendAfterCommit` is the branch the existing manual
damage flow already takes, and it demonstrably produces messages (230 `DAMAGED`/`STOCK_CREATED`
stockrecord rows on `c1wh-shipitez-uat`).

**Transaction shape.** `applyDamage` runs with **no** surrounding transaction, like `executeInternal`
itself. `moveStockToNewDamagedContainer` opens its own `tenantTransactionManager` boundary. This
matters for the OMS message: `MessageService.sendStockChangeMessage` →
`StockChangeNotificationService.sendAfterCommit` → `OmsNotificationService.sendAfterCommit`, whose
javadoc carries an explicit rail — *"a caller must never wrap a call to this method in its own
afterCommit callback, because the registration below would land in the list Spring is already
iterating and be discarded unseen — no POST, no message row, no metric. Enforced by
NestedCallSiteRailTest."* `applyDamage` is not inside any `afterCommit` callback, and must not be
moved into one. The no-transaction branch of `sendAfterCommit` is the branch the existing manual
damage flow already takes, and it demonstrably produces messages (230 `DAMAGED`/`STOCK_CREATED`
stockrecord rows on `c1wh-shipitez-uat`).

### 3.4 What happens when the damage step fails — a new outcome, and why not `PARTIAL`

**The problem with reusing `PARTIAL`.** `PARTIAL` deliberately does **not** reach `markFinished`, so
the advice stays `OPEN` for dock recovery. That is exactly right when a *receive* failed. It is
exactly **wrong** when the receive succeeded and only the damage step failed: every position's stock
is already physically in the warehouse and recorded, and an `OPEN` advice invites an operator to
dock-receive it again, **doubling the stock**. Recovering from a failed damage step is a manual
damage move in the existing UI (`WEB_UI_ACTION_ADJUST_LOCK_DAMAGED`), not a re-receive.

**Proposal: a fourth `Status`.**

```java
public enum Status { SUCCESS, PARTIAL, SKIPPED, DAMAGE_FAILED }
```

with these properties:

| Property | Value | Why |
|---|---|---|
| `markFinished` runs? | **Yes** | The advice's receiving obligation is discharged; leaving it OPEN is the double-receive hazard above. |
| `isWarning()` | `true` (falls out of `status != SUCCESS`, unchanged) | The controller turns it into `200` + a warning envelope rather than the `204` a caller short-circuits on. ⚠ **Producing the envelope is not the same as anyone reading it** — see D7 immediately below, which is what makes this row true. |
| `code()` | `WmsConstants.getErrorCodeName(WmsConstants.RETURN_AUTO_RECEIVE_DAMAGE_FAILED)` | New constant at **603** — `600` `RETURN_AUTO_RECEIVE_PARTIAL`, `601` `PRINTER_NOT_AVAILABLE`, `602` `RETURN_AUTO_RECEIVE_ABORTED` are taken; `603` is the next free value in the block (method: read of the contiguous constant block in `WmsConstants`; blind spot: a constant declared outside that block would be missed, so the implementer must `git grep -n "= 603;"` before committing). Needs an arm in **both** `getErrorCodeName` and `getErrorCodeText` — `NOT_ENABLLED_FOR_RECEIVING` has only the latter and silently degrades, which the code comments flag as a bug not to copy. |
| `FailureReason` | new value **`DAMAGE_APPLY_FAILED`** | Names a *class* of condition. It encodes no printer name, location name, entity id, sysprop key, SQL or exception text, satisfying the enum's stated security contract for a `permitAll()` boundary. |
| `received` / `total` | positions received / total positions | Unchanged meaning; every position was received, so these are equal in this status — which is itself the signal that distinguishes it from `PARTIAL`. |
| `correlationId` | a fresh UUID, as `PARTIAL` does | The only join key from the operator-facing banner to the log line carrying the cause and the position id. |
| metric | `wms2.returns.autoreceive.damage_failed` counter | Sits alongside the existing `success` / `partial_failure` / `skipped_no_positions` counters. Per the standing note that nothing scrapes Prometheus yet, this is an aid to post-hoc diagnosis, **not** a control. |

**D7 — the envelope must reach a human, or the fourth `Status` does not earn its existence.**
Rev1 asserted that a warning "must be told" to the caller. On this path the caller is **qa-api, not
the OMS Laravel app**, and qa-api does not look: `AdviceRestController` emits
`body.put("status", "success");` *beside* the warning map, and `send_wms_create_advice` branches
solely on `if data.get('status') != 'success':` before `return {'status': 'success'}` — the word
`warning` does not appear in that function. So without D7 a `DAMAGE_FAILED` produces a `service_log`
row, a `LOG.error` and an unscraped counter, while **the QA operator sees an unqualified success, the
WMS shows a `FINISHED` advice, and the damaged bottles sit as normal sellable stock** — the original
defect, re-created in the failure path, with the advice now closed so the dock cannot recover it
either.

D7 (Nam, 2026-09-15) closes it in the **same function Phase 2 is already editing**: on a 200,
`send_wms_create_advice` inspects `data.get('warning')` and surfaces it to the operator rather than
returning a bare success. ~10 lines, pinned by T2.5. With D7 the `200`+envelope is a real channel and
the row above is true; without it, the honest wording would have been "log-and-metric only, seen by
nobody", and the case for a fourth `Status` over reusing `PARTIAL` would have to be re-argued.

**⚠ This argument depends on D6's worklist actually working.** "With D6 neither state is
unrecoverable" is true only once the query in §3.2 can distinguish a recovered position from an
unrecovered one — which the rev5 version could not (H1). If Half B is dropped, or if the worklist
ships in its approximate form, the ordering below reverts to a choice between two states that are
recoverable only by hand, and it should be re-argued on that basis rather than inherited.

**Ordering inside `executeInternal` — re-argued on its own merits, because D6 changed the question.**
Rev1 chose *receive-all-then-damage-all* because the alternative was an `OPEN` advice with part of
its stock already locked `103`, inviting a dock re-receive that would duplicate the good stock. That
argument was made when the damaged quantity was persisted **nowhere**, so the choice was between two
unrecoverable states. **With D6 neither state is unrecoverable** — `notifieddamagedamount` is on the
row either way, and the §3.2 worklist query finds every position received-but-not-damaged. The
ordering is now a free choice and has to be justified on its costs, not on which loss is preferable:

| | receive-all-then-damage-all (**chosen**) | interleave per position |
|---|---|---|
| receive fails at position *k* | positions 1..*k*-1 hold their damaged portion as normal stock until recovery runs; `notifieddamagedamount` makes them findable | positions 1..*k*-1 are already correct; nothing to recover |
| dock re-receive of the `OPEN` advice | receives `notifiedamount` (= the total, post-D6) — correct quantity, damage then applied by the worklist | would duplicate the good stock of already-damaged positions |
| position 1's reservation window | **N-1 further receives wide**, each containing a CUPS round-trip (`receiveGoods` probes `printService.isPrintAvailable` as its first real statement) — this is what makes `availableamount` "the weakest link" in §3.3 | one transaction wide |
| `Damaged` row `FOR UPDATE` held | once per damaged position, late | once per damaged position, interleaved |

**The decision stands, and the deciding reason is the dock-recovery column, not the reservation
column.** An operator dock-receiving an `OPEN` advice is a routine, high-frequency action; a
reservation landing inside the window is rare and now merely produces a recoverable
`DAMAGE_FAILED`. Making the common path safe beats narrowing a rare window. But the cost is now
**stated rather than unpriced**: with N positions, position 1's freshly-received stock sits at
`entity_lock = 0`, unreserved and grabbable, across N-1 further receives each containing a network
round-trip.

**The committed-unlocked window, named explicitly** because rev1 discussed the *reservation* race
without naming the *pickability* it implies: between `receiveGoods`'s commit and `applyDamage`'s
commit, the damaged bottles are ordinary stock at a pickable location and can be allocated to an
order. This window is inherent to D1/D3 — it is the one thing a receive-straight-into-`Damaged`
design would have eliminated — and it is accepted. It is bounded by the two commits, not by the
advice, for the position being damaged; for *earlier* positions it is bounded by the whole advice,
per the table above.

If a damage step throws, the implementation records the first failure, **continues** applying damage
to the remaining positions (they are independent, and half-damaged is strictly better than
one-damaged), then runs `markFinished` and returns `DAMAGE_FAILED` naming the first failed SKU.

**Idempotent replay.** `AdviceRestController` carries an explicit comment that a warned 2xx is
*"DELIBERATELY CACHEABLE BY IdempotencyFilter. DO NOT 'FIX' THAT."* `DAMAGE_FAILED` inherits that
silently, because the filter keys on the status code. The inherited reasoning still holds — replaying
the cached 200 beats manufacturing a duplicate-key error — but it was written for a state where the
advice stays `OPEN`, and here the advice is `FINISHED`. Replay is still the right behaviour (the
retry must not re-receive), and T1.13 pins it so the inheritance is graded rather than assumed.

**`diagnose()` is not extended.** Its ladder probes receive-time conditions (printer reachability,
ZPL template, config). A damage failure's causes — a reserved `availableamount`, a missing or
renamed `Damaged` row surviving the pre-flight, a concurrent lock — are not distinguishable by any
probe cheap enough to run here, and the enum's javadoc is explicit that a reason a probe cannot
establish must not be invented. `DAMAGE_APPLY_FAILED` plus the correlation id is the honest answer.

### 3.5 Pre-flight the `Damaged` location at validate time, conditionally

**Rationale.** `ReturnAdviceAutoReceiveService` already applies exactly this discipline (the "R9"
rule) to the printer, the box type and the putaway destination: resolve in `resolveRefs`, fail
**before** `adviceRepository.save`, because `create()` is not transactional and a post-save throw
burns `externalid` permanently. A `Damaged` row that does not resolve is the same class of failure —
name-keyed, no unique index, no "DO NOT REMOVE" description, differing ids across tenants, and
`initDB` throws rather than creating it.

In `resolveRefs`, **after** the per-position loop and **only if** any position carries
`damagedAmount > 0`:

```java
locationRepository.findByName(WmsConstants.STORAGE_LOCATION_DAMAGED)
    .orElseThrow(() -> {
        meterRegistry.counter("wms2.returns.autoreceive.rejected_tenant_misconfigured").increment();
        return new WebserviceBusinessExceptionClientSide(
            WmsConstants.ENTITY_DOES_NOT_EXISTS, null, Location.class.getSimpleName(), adviceDto);
    });
```

**The code is `ENTITY_DOES_NOT_EXISTS`, not `FIELD_MALFORMED_FORMAT`** *(rev1 had the latter)*. A
missing `location` row is a **tenant misconfiguration**, not a malformed field, and telling OMS its
field is malformed sends the operator to the wrong system. The two existing tenant-misconfiguration
pre-flights in this same method already use that vocabulary — `DEFAULT_TYPE_NOT_EXIST` with the
`rejected_tenant_misconfigured` counter, and `ENTITY_DOES_NOT_EXISTS` for the missing
`UNIT_LOAD_TYPE_BOX` row — so this follows the local convention rather than inventing one. Passing
the generic entity name rather than the literal `"Damaged"` keeps the `permitAll()` disclosure
discipline.

Two properties of this that must not be misread:

1. **It is conditional.** An advice with no damaged quantity must not start failing on a tenant that
   lacks the row. This preserves the behaviour of every RETURN advice in flight today.
2. **It is a gate, not a hand-off.** The resolved `Location` is deliberately **not** carried into
   `ValidatedAutoReceive` or passed to `setLockDamaged`. `resolveRefs` is `readOnly` and OSIV is off,
   so that entity would be detached; `setLockDamaged` does its own `findByName` at execute time and
   must keep doing so. The pre-flight narrows the window between "advice accepted" and "damage
   applied" — it does not close it, and §7 T1.8 asserts the execute-time failure path too.

The error shape reuses `FIELD_MALFORMED_FORMAT` against the new field name rather than inventing a
code, so the `permitAll()` boundary leaks no location name.

### 3.6 `printLabel = false` for the damaged portion, and the one consequence of that

**Decision: pass `printLabel = false`.** Justification, in order:

1. **D1 says so** — no UL label for the damaged portion.
2. `setLockDamaged`'s `printLabel(...)` helper selects
   `printerRepository.findByTypeAndProcessdefaultTrue(WmsConstants.PrinterType.INBOUND)`, while this
   entire path is built around a **RETURN**-type printer resolved in `resolveRefs` and CUPS-probed
   there. Passing `true` would reach a printer that was never validated, on a path whose whole
   design is that the printer is proven reachable before the advice is persisted.
3. It is **safe** because the helper is already wrapped in a catch that only warns — but "safe to
   fail" is not "safe to do": a print to an unvalidated INBOUND printer in a warehouse that has none
   would log a warning on every damaged return, forever, with no way to tell it from a real outage.

**The consequence that must be stated, because it is real and it is not fixed by this plan.** For a
**mixed** line, `receiveGoods` builds the case label from the stock unit while it still holds the
**full** quantity, and prints it in an `afterCommit` callback that fires at the receive transaction's
commit — i.e. **before** `applyDamage` splits it. So the one label that prints overstates the good
unit load by the damaged quantity. Options, with the recommendation:

- **(i) Accept for Phase 1** *(recommended)*. The operator who typed the damaged quantity is holding
  the damaged bottles; the physical split is unambiguous to them, and every downstream system reads
  the database, not the label. §7 manual row M4 measures it rather than assuming it is tolerable.
- **(ii) Defer the label.** Add a `deferLabel` parameter to `receiveGoods` so the auto-receive path
  can print after the split. This touches a method shared with the dock-receive path and is scope
  the ticket did not ask for.

This is recorded as a ranked follow-up in §10 FU-1, not smuggled into Phase 1.

### 3.7 Pinning "v1 ignores the new field" with an executable check

E5's verdict is a **code-level read**: `v1/wms-api`'s `WebConfigurer` sets
`FAIL_ON_UNKNOWN_PROPERTIES=false` at **three** sites, not two as rev1 said — `WebConfigurer`'s
`@Primary` `ObjectMapper` bean, `WebConfigurer.extendMessageConverters`, and `StartApplication`
(*instrument:* `git grep -n "FAIL_ON_UNKNOWN_PROPERTIES" origin/develop -- src/main/java`) — and no
DTO overrides it. The direction of the claim is unaffected; the number is corrected because this is
a paragraph whose whole point is that a code read of this kind has been wrong here before. The evidence lane left one blind spot open —
an annotation inherited from `AbstractWebServiceDto`, which `AdviceDto` extends. **That blind spot
is now closed:** `git show origin/develop:.../json/AbstractWebServiceDto.java` on `v1/wms-api`
@ `4cdd945` shows the class carries `@JsonSubTypes` and a single `@JsonProperty("facility_code")`
field and nothing else, and `git grep -n "JsonIgnoreProperties" origin/develop -- src/main/java/net/aim_ai/wms/json/`
returns no hits. Blind spot of *that* instrument: it scans only the `json` package, so a
mix-in registered on the `ObjectMapper` would not appear; none is registered in `WebConfigurer`,
which was read.

**That is still a code read, and this class of claim has been wrong in this repo before.** Phase 2a
adds a **test-only** change to `v1/wms-api` (no production code, so D2 holds):

```java
// v1/wms-api src/test/java/.../json/AdviceDtoUnknownPropertyToleranceTest.java
// Binds a real create-advice payload carrying the new key "amount_of_bottles_damaged" through the
// SAME ObjectMapper configuration WebConfigurer installs, and asserts (a) no exception is thrown,
// (b) amountOfBottles still binds to its value, i.e. the unknown key is dropped, not conflated.
```

The test must obtain its mapper from the application's configuration, not construct a fresh
`new ObjectMapper()` — a fresh mapper defaults to `FAIL_ON_UNKNOWN_PROPERTIES=true` and would make
the test fail for the wrong reason, while a hand-configured one would assert the test's own
configuration rather than the application's. If Nam prefers **zero** commits to `v1/wms-api`, the
fallback is manual row M5: `PUT` a payload carrying the key at a v1 dev instance and record the
204. The test is strongly preferred — the manual probe verifies one instance on one day.

### 3.8 Defect A — the disposition select never emits `change` (qa-ui, T2)

**Cause.** `components/returns/dispositionSelection.vue` sets `this.chosenDisposition` in
`mounted()`. A programmatic write to a Vuetify 2 `v-select`'s bound value does not emit `change`:
verified against the installed **2.7.2** source — `VSelect.js`'s
`setValue(value) { if (!this.valueComparator(...)) { this.internalValue = value; this.$emit('change', value); } }`
is reached only from user-interaction paths (`selectItem`, clear, keydown), and
`mixins/validatable/index.js`'s `value` watcher is `value(val) { this.lazyValue = val }` with no
emit. The parent learns the value only through `@change="changedDisposition"`, so it keeps its own
`disposition: 1`; `returns_helper.py` takes the non-WMS branch; the operator gets a green success
toast with no advice, no receipt, no UL and no stock — **an exact match for the client complaint**,
and it affects v1 and v2 clients alike.

**The exposure is inverted from what it looks like, and this is the part to carry into testing.**
`data()` returns `{ chosenDisposition: 1 }` and `mounted()` overwrites it only
`if (preferred_disposition)`. So a client whose `ship_return_management` is **unset** is *safe*: the
select displays "Manually Manage", the operator sees a visibly wrong option, clicks it, `change`
fires, and everything works. A client configured to **Restock Inventory** is the broken one: the
select displays exactly the option the operator wants, so they never touch it, no `change` fires,
and the parent submits `1`. **The defect is worst precisely where the configuration is correct** —
which also means it is invisible to anyone testing against an unconfigured client, and that a "yes"
to OQ-3 raises Defect A's priority rather than narrowing it.

**A second cause on the same three lines, which the fix must also handle.** `mounted()` reads
`this.$store.state.returnsCall.dispositions` and calls `.find(...)` on it. That list is populated by
`GET /system/returns/dispositions`, fired from the **parent** page's `mounted()` — and in Vue 2 a
child's `mounted()` runs **before** its parent's, with the HTTP call asynchronous on top. So on a
cold navigation the list is empty, `preferred_disposition` is `undefined`, and the preference is
never applied at all. The component's own `watch: { dispositionList(newVal) {} }` — **empty** — reads
as an abandoned attempt to handle exactly this. *Confidence:* the ordering is a Vue lifecycle
guarantee and the two call sites are read directly; what is **not** established is which case
ShipItEZ's operators actually hit, because the Vuex store persists across in-SPA route changes, so a
second visit can find the list already populated. Both cases end with the parent holding
`disposition: 1`, so both produce the reported symptom, and a fix that only emits from `mounted()`
repairs one of them.

**Fix.** Make the parent learn the value on **every** path that can set it. A `watch` on
`chosenDisposition` that emits unconditionally is the smallest diff and covers the user path, the
`mounted()` path and the late-arriving-dispositions path in one place; filling in the empty
`dispositionList` watcher to re-resolve the preference is what makes the third path reachable at all.
The test (§7 T3.1–T3.3) grades the **behaviour** — *the parent's `disposition_id` equals the
pre-selected value without any user interaction, including when the dispositions arrive after mount*
— not the mechanism.

⚠ **Do not change `chosenDisposition`'s `1` default as part of this.** `data()` returns
`{ chosenDisposition: 1 }`, so an unmatched preference renders disposition **1**, not the
`placeholder="Choose Option"`. Defaulting it to `null` to make an "empty select" assertion pass would
be an unrequested behaviour change that also alters what the parent's own untouched `disposition: 1`
means. T3.2 is written against the `1` default for this reason.

**Invariant over instance.** The same `mounted()`-assigns-without-emitting shape may exist on other
`v-select` components in qa-ui. A sibling sweep is part of Phase 3:
`git grep -n "mounted" -- components/ pages/` cross-referenced against components that emit only on
`@change`. Findings go on this ticket per the sub-T3 policy.

### 3.9 Defect C — `processApiErrors` crashes on a string payload (qa-ui, T1)

**⚠ Rev1 named the wrong file.** It attributed the string payload to `views/parcel_info.py`. The
single producer on `origin/develop` is **`flask_app/view_helpers/returns_helper.py`**, in the
compensating-rollback branch of `process_managed_returned_parcel` (*instrument:*
`git grep -n "'messages': str(" origin/develop -- flask_app` → **exactly one** hit; *blind spot:* it
matches that literal spelling only, so a payload built by variable assignment or `dict()` would not
appear). `parcel_info.py` contains four `messages` occurrences and **every one is
`'messages': None`**; its only role is `if result.get('status') == 'failure': response = result;
code = 400`, i.e. it passes the helper's dict through untouched. **`parcel_info.py` therefore needs
no change at all** and has been removed from §0, §4 and the test plan.

**Cause.** `returns_helper.py` returns `{'status': 'failure', 'messages': str(exc)}` from its
`except WmsException` block — a **string**, because `WmsException.__str__` is
`f'{self.code}: {self.message}'` — where every other error path in the app emits the documented
list-of-dicts shape produced by `create_error_response`. `store/util.js` then does
`error.response.data.messages.forEach(...)` behind a truthiness guard that a non-empty string
passes. `String.prototype.forEach` does not exist, so a `TypeError` escapes `processApiErrors` and
therefore escapes the `catch` in `returnsCall.js`: no toast of any kind fires, the promise rejects
so `hideQaLoadingWheelPop` never runs, and `qaLoadingWheelPop.vue` is a `<v-dialog persistent>`, so
the operator must reload the page.

**Fix, both halves** — the invariant is "the error channel carries one shape", and fixing only the
consumer leaves the producer free to break the next consumer:

- `store/util.js`: normalise before iterating — accept a string, an array, or a
  `{message}`-shaped object, and always render *something*; keep the existing generic fallback
  reachable.
- `view_helpers/returns_helper.py`: emit the documented list shape via `create_error_response` from
  the `except WmsException` block, as every other failure path in the app does.

### 3.10 Why D1 covers all three reporting surfaces *and* the OMS wire — the property that selected it

This is the positive statement of §1.3's correction, and it is the reason D1 was chosen over the
cheaper lock-only variant rejected in §9 Alternative D.

The three **reporting** surfaces key on **two** different things, and the OMS wire is a fourth
consumer that is not a report. A design has to hit all of them:

| Surface | Keyed on | Damaged return today | Covered by D1? | By what |
|---|---|---|---|---|
| `stock_view.damaged` (the client's damaged-inventory report) | `su.entity_lock = 103 OR ul.entity_lock = 103` | counted as normal | **Yes** | `moveStockToNewDamagedContainer` sets `QUALITY_FAULT` **inside** its transaction |
| `InventoryRecord.damage` (periodic snapshot) | same `entity_lock = 103` key (`UnitloadService`'s derivation idiom reads `entityLock == QUALITY_FAULT`) | 0 | **Yes** | same write |
| `transaction_detail.damaged` (transaction report) | `sr.activitycode = 'DAMAGED' AND sr.type = 'STOCK_CREATED'` | no row at all | **PARTIALLY — corrected 2026-09-16** | `transferStockToUnitLoad(..., CODE_DAMAGED, ...)` writes the `stockrecord` **only when the damaged quantity is a strict SUBSET of the stock unit.** Measured by I2 against real PostgreSQL: a MIXED line (7+3) raises this surface by 3; a FULLY damaged line (0+4) raises it by **0**. `StockunitBusinessService.transferStockToUnitLoad` splits off a new stock unit only when `sourceStockunit.getAmount().compareTo(amount) > 0` — when something is left behind. When the damaged amount IS the whole unit it takes the full-move branch instead: re-parents the existing stock unit and calls `recordTransferStockUnit`, which writes `rec.setAmount(BigDecimal.ZERO)`. No `DAMAGED`/`STOCK_CREATED` row is produced, and this surface sums exactly that shape. **So on an all-damaged return the damaged INVENTORY report is right and the damaged column of the TRANSACTION report is empty.** §3.1's relaxation exists precisely to let all-damaged lines through, so the case is reachable by design once Phase 2 ships. Pinned by I2 as `ZERO` — asserting what the code does, not what this row used to claim. **Raised as a T3 finding for Nam, NOT fixed here:** the fix lives in `transferStockToUnitLoad`, shared stock-movement code with many callers far outside this ticket's blast radius. |
| OMS `StockChangeDto.damaged` (the wire) | explicit call argument | sent as `normal` | **Yes** | D5's second message, `normal = 0 / damaged = +N`, already emitted by `setLockDamaged` and **correct** — `normal` is a gross delta the OMS nets (E8). ⚠ Today's `oms-laravel-api` mishandles it because of a consumer-side regression; that is a prerequisite, not a WMS defect — §3.11.3. |

**The load-bearing point:** a design that sets `entity_lock = 103` and nothing else satisfies the
first two rows and misses the third (the transaction report) and the fourth (the OMS wire) entirely. D1 gets all four **because it reuses the method
the manual damage flow already uses**, not because anything new was written for them. Corroboration
that the third surface's population is real and reachable: `c1wh-shipitez-uat` `stockrecord` holds
230 `DAMAGED`/`STOCK_CREATED` rows and 165 `DAMAGED`/`STOCK_REMOVED` rows against 2 956
`RETURN`/`STOCK_CREATED` rows — two disjoint populations, with not one `DAMAGED` row produced by a
return. Integration test **I1** asserts all four in one pass, and manual row **M9** confirms the
`transaction_detail` row label against the un-enumerated arms of the function.

### 3.11 The OMS netting contract — D8 proposed, then WITHDRAWN on evidence

This section records a WMS-side fix that was designed, settled as **D8**, and then **withdrawn**. It
is kept rather than deleted so nobody re-derives it: the symptom is real, the diagnosis was
backwards, and the cheapest way to stop the next person repeating it is to leave the reversal visible.

#### 3.11.1 The symptom, and the wrong conclusion (E7)

`setLockDamaged` sends `getStockChangeDTO(itemData, 0, damagedStock.getAmount().intValue(), …)` —
`normal = 0`, `damaged = +N`. Today's `oms-laravel-api` adds each bucket independently
(`$newValue = $addToExisting ? ($inventory->{$column} + $value) : $value`), so that pair leaves
`quantity_on_hand` unchanged while `quantity_damaged` rises: **sellable inventory overstated by N**.
E7 concluded the WMS was wrong at three sites, and **D8** was settled to fix them plus a two-factory
enforcement shape.

#### 3.11.2 ⚠ E8 inverts it. `normal` is a GROSS delta and the WMS is correct.

`normal` is a **gross physical delta**; the OMS derives sellable by netting the buckets out of it.
Under that rule the three sites E7 flagged are **right**, and they match v1's Zend OMS
(`productUpdate.psql`, `SET on_hand = on_hand - damaged - missing - on_hold`) unchanged since 2022.

The regression is in the **consumer**: `oms-laravel-api` commit **`dd17b84f` (2026-07-31,
SBDEV-2671)** narrowed the netting guard from unconditional to incremental-path-excluded —

```php
-        if (array_key_exists('quantity_on_hand', $quantities)) {
+        if (!$addToExisting && array_key_exists('quantity_on_hand', $quantities)) {
```

Before it, `normal:0, damaged:+N` netted to `−N` on hand: correct. After it, sellable is overstated.

**The measurement that settles it**, on live v1 production `wh01_shipitez` over the `message` table:

| probe | rows |
|---|---|
| shape `"normal": 0` **and** `"damaged": +N` | **173** |
| shape `"normal": -N` **and** `"damaged": +N` | **0** |
| span | 2022-07-31 → 2026-09-15 |

**Positive control on the zero** — decisive, because a broken matcher and a true zero are
indistinguishable: the same matcher finds `"normal": -N` **1 634** times overall, and `"normal": +N`
10 802 times. The WMS *can* and *does* emit a negative `normal`; it has simply never paired one with a
positive `damaged`. **The tuple `dd17b84f` assumed has never existed in four years of production
traffic.** `dd17b84f`'s own pinning test fixes `normal:10, damaged:1` — a tuple no WMS call site emits.

**D8 is withdrawn in full.** No edits to `setLockDamaged`, `transferStock` or
`MobileMoveUnitloadService`; no two-factory `moveBetweenBuckets`/`adjustBucket`; no rail; Phase 1
returns to single-subsystem and to its original estimate. Making those edits would have repaired 1 of
the lane's 10 mismatched sites, broken the WMS's four-year internal consistency with v1, and left the
actual regression in place.

**`adjustAmount`'s two locked arms dissolve as a question.** Under the gross model all three arms are
coherent, so there is nothing to fix.

> **The method that produced that outcome, stated as a method because it is the reusable part.**
> While E7's reading was the working hypothesis, the three `adjustAmount` arms were tested against
> **both** candidate models rather than against the preferred one. The result was: under *gross* all
> three arms cohere; under *good-units-only* only `NOT_LOCKED` does. Therefore **the arms are
> consistent with either model and corroborate neither** — they are not evidence, and only the
> consumer could settle it.
>
> That is what kept the call sites from being read as confirmation of a reading already committed to.
> Had they been, D8 would have **grown to five sites** on the strength of a hypothesis that was about
> to be inverted, instead of shrinking to zero. **Generalised: before citing code as evidence for a
> contract, check whether it would look the same under the competing contract. If it would, it is not
> evidence — it is compatible with your conclusion, which is a much weaker thing.**

#### 3.11.3 The real gate is ShipItEZ's cutover, not this ticket's merge

The `oms-laravel-api` defect has produced **no measured drift**, and the reason is not that it is
harmless: the shape it mishandles is one **no v2 client has sent since it landed**.

This plan's earlier revision drew the obvious conclusion — *SBDEV-1512 creates that traffic, so the
OMS fix gates this ticket.* **The mechanism is right and the timing is wrong**, and the correction
makes the gate stronger rather than weaker. Measured on `wms2-hydra` (`wh01_hydra_v2`), the only v2
production client on the Laravel OMS:

| probe | result |
|---|---|
| `RETURN` advices, all time | **1** (2026-08-05) |
| `REGULAR` advices, all time | 232 (2026-07-12 → 2026-09-11) — **the built-in positive control**: the table and query work, so the `1` is a true count, not a broken probe |
| `STOCK_UPDATE` messages with non-zero `damaged` | **0** of 23 |

**One return, ever.** Shipping Phases 1–2 therefore does not by itself manufacture drift: there is no
return traffic on the only exposed client to damage.

**The trigger is ShipItEZ's v2 cutover.** They carry ~1 037 RETURN advices historically (2022 →
2026-09-08, roughly 250/year), and damaged returns are this ticket's entire subject. Their v2 DBs are
already provisioned and schema-current (§5.1 row 1b), so **cutover is an event someone owns and
schedules — not a code deploy.** That makes it a better gate than "before SBDEV-1512 ships" on three
counts: it names a scheduled event, it is checkable against a date rather than a backlog dependency,
and it correctly permits this feature to reach dev, UAT and Hydra without manufacturing drift.

> **SBDEV-1512 is safe to ship now. It is unsafe at ShipItEZ cutover without SBDEV-3366.**
> A reader who takes only "blocked" from this will hold a ready feature for no reason.

> **FILED as [SBDEV-3366](https://app.clickup.com/t/868m5j9qr)** (Urgent · Bug · Fulfillment
> Development Backlog), on Nam's direction.
>
> **SBDEV-1512 is blocked on SBDEV-3366 for CORRECTNESS, not for DELIVERY — both halves matter.**
>
> - **Not blocked for delivery.** Every WMS-side change in this plan is correct as written and can be
>   built, reviewed and merged independently. Nothing here waits on the OMS repo.
> - **Blocked for correctness, at the cutover boundary.** Until netting is restored in
>   `applyInventoryQuantities`, every damaged return computes wrongly **in the OMS** even with a
>   perfectly correct WMS — so at any client with real return volume the feature does not achieve its
>   purpose end to end.
>
> Read only the first half and you eventually ship a feature that silently overstates sellable
> inventory. Read only the second and you stall work that is ready to go today. §5.1 row 4 carries
> the gate in its schedulable form.

#### 3.11.4 The reusable lesson — and it is the third instance in this ticket

E7 read the **consumer's own code comment** as the contract, and never checked it against the
**producer's traffic**. The comment was newly written, by the very change that introduced the
regression, and it described a convention that had never existed. A comment asserting what a caller
sends is **a claim about a system, not documentation of it**. The 173/0 query is twenty seconds of
work and would have inverted the conclusion before any decision was taken.

That is the same family as the two test failures named in §7's preamble — T1.10 asserting an absence
with no positive control, and I5 carrying a correct value with no independent derivation, which is
exactly why a plausible contrary argument could flip it to a wrong one. All three share one shape:
**an artefact was trusted to describe reality instead of being checked against it**, and in all three
the check was cheap and available. Where a claim is about what another system *does*, the evidence is
its traffic, its data, or its behaviour — never its prose.

---

## 4. File Change Summary

> ### ⚠ Citation trap in `StockunitService` — applies to ANY edit in that file
>
> `setLockDamaged` and `transferStock` both contain this statement, character for character:
>
> ```java
> list.add(sharedService.getStockChangeDTO(itemData, 0, damagedStock.getAmount().intValue(), 0, 0, 0, comment, WmsConstants.CODE_DAMAGED));
> ```
>
> `git grep -c` for that literal returns **2**, both in `StockunitService`, and the snippet cannot say
> which is which. **This is the one place where the repo's "cite a quoted snippet, not a line number"
> rule fails** — the stable discriminator is the **enclosing method signature**.
>
> **The dangerous half.** The *statements* are identical; the *lines* are not — `:609` sits at
> indentation **24** (nested in a block) and `:786` at indentation **8** (measured). A find-and-replace
> on the **trimmed** literal hits both. A **whitespace-sensitive** replace — which is what most
> `sed -i` one-liners and most verify-script greps are — hits **exactly one** and leaves the other
> silently unedited *while reporting success*.
>
> No test, verify row or scripted edit in this file may key on that literal. Key on the enclosing
> method. Kept here although the change that surfaced it (D8) was withdrawn, because the trap is a
> property of the file, not of that fix.

| # | Repo | File | Change | Phase |
|---|---|---|---|---|
| 0 | wms2-api | `src/main/resources/db/migration/V2.2.32__adviceposition_notified_damaged_amount.sql` | **new** — `ALTER TABLE public.adviceposition ADD COLUMN IF NOT EXISTS notifieddamagedamount numeric(19,2), ADD COLUMN IF NOT EXISTS damageappliedat timestamp with time zone;` — **two columns, one statement** — plus the `-- WHY` header every sibling file carries (D6-B). **`public.` + `IF NOT EXISTS`**, per `V2.2.13`/`V2.2.30` — not `V2.2.03`'s bare form. Version re-confirmed by the §5.1 row 1 sweep immediately before creating the file | 1 |
| 1 | wms2-api | `src/main/java/net/aim_ai/wms/json/AdvicePositionDto.java` | add `amountOfBottlesDamaged` + `@JsonProperty("amount_of_bottles_damaged")` + accessors + `toString` | 1 |
| 1a | wms2-api | `src/main/java/net/aim_ai/wms/model/Adviceposition.java` | add `BigDecimal notifieddamagedamount` **and `Instant damageappliedat`** + accessors (D6-B). ⚠ **No initialiser on either** — the sibling `notifiedamount = BigDecimal.ZERO` idiom would make every new row `0.00` and falsify the NULL semantics (§3.2 M4) | 1 |
| 1b | wms2-api | `src/main/java/net/aim_ai/wms/controller/rest/AdviceRestController.java` | save loop: the **explicit-coalescing** block in §3.2 — `int damaged = raw == null ? 0 : raw;` then `notifiedamount = amountOfBottles + damaged`, `notifieddamagedamount = raw == null ? null : new BigDecimal(raw)`. ⚠ **Never write `undamaged + damaged` literally** — both are boxed `Integer` and it NPEs for every caller omitting the key (H2). **Also add the damaged-field validation here**, in the save loop, not only in `resolveRefs` (H3) | 1 |
| 2 | wms2-api | `src/main/java/net/aim_ai/wms/service/ReturnAdviceAutoReceiveService.java` | `ResolvedLine`/`AutoReceiveLine` gain `damagedAmount`; `resolveRefs` validates the total and pre-flights `Damaged`; `bind` zips the new component; `executeInternal` splits into a receive loop and a damage loop; new `applyDamage`; `Status.DAMAGE_FAILED`; `FailureReason.DAMAGE_APPLY_FAILED`; `code()` arm; new counter; new `AutoReceiveOutcome.damageFailed(...)` factory | 1 |
| 3 | wms2-api | `src/main/java/net/aim_ai/wms/service/ReceivingService.java` | `receiveGoods` returns `List<Long>` of created stockunit ids (source-compatible) | 1 |
| 4 | wms2-api | `src/main/java/net/aim_ai/wms/service/WmsConstants.java` | `RETURN_AUTO_RECEIVE_DAMAGE_FAILED = 603` + arms in **both** `getErrorCodeName` and `getErrorCodeText` | 1 |
| 5 | wms2-api | `src/main/resources/messages*.properties` (if the new template needs a key) | error text for 603 | 1 |
| 6 | qa-api | `flask_app/common_util/wms_api.py` | `build_wms_create_advice_request` emits `amount_of_bottles_damaged` unconditionally; **and** the 204 branch writes a `service_log` row before returning (§5.3.1) | 2 |
| 7 | v1/wms-api | `src/test/java/.../AdviceDtoUnknownPropertyToleranceTest.java` | **new test only**, no production change | 2a |
| 8 | qa-ui | `components/returns/dispositionSelection.vue` | emit the pre-selected disposition to the parent | 3 |
| 9 | qa-ui | `pages/manageReturn/_id.vue` | (only if the chosen mechanism requires it) stop relying on the hard-coded `disposition: 1` default | 3 |
| 10 | qa-ui | `store/util.js` | `processApiErrors` normalises string / array / object payloads | 4 |
| 11 | qa-api | `flask_app/view_helpers/returns_helper.py` | `except WmsException` block emits the documented list shape via `create_error_response` (**rev1 named `views/parcel_info.py`; that file needs no change** — §3.9) | 4 |
| 12 | qa-api | `flask_app/common_util/wms_api.py` | `send_wms_create_advice` inspects `data.get('warning')` on a 200 and surfaces it (D7) | 2 |

---

## 5. Phased Implementation Plan

### 5.1 Prerequisites

| # | Prerequisite | Required value / action | Owner | Notes |
|---|---|---|---|---|
| 1 | **Database state** | **One Flyway migration (D6)** — `ALTER TABLE public.adviceposition ADD COLUMN IF NOT EXISTS notifieddamagedamount numeric(19,2), ADD COLUMN IF NOT EXISTS damageappliedat timestamp with time zone;` — **two columns in one statement**, both nullable, no default, no backfill, catalog-only (no rewrite; 9 613 rows / 2 832 kB on the largest tenant). **Pick the version by sweeping ALL remote branches, not by listing the directory**, because a local listing shows a stale head and will collide with a migration on an unmerged branch:<br>`for b in $(git for-each-ref --format='%(refname)' refs/remotes/origin); do git ls-tree -r --name-only "$b" -- src/main/resources/db/migration; done \| sed 's#.*/##' \| grep -oE '^V[0-9.]+' \| sort -V \| tail -1`<br>⚠ **THE RE-SWEEP FIRED ON ITS FIRST USE — the version moved. Use `V2.2.32`, not `V2.2.31`.**<br>On 2026-09-15 the sweep returned `V2.2.30` across 287 refs, making `V2.2.31` the candidate. Re-run at the executor's Phase 0 on **2026-09-16**, it returns **`V2.2.31`** across **289** refs: `V2.2.31__cancellation_log_pickingorder_position_id.sql` (SBDEV-3363) is present on three refs **including `origin/develop`**, in the very merge this branch is based on (`4bef7e77`). Had the plan's 2026-09-15 number been used, two different scripts would have shipped as `V2.2.31`. **`V2.2.32` is free** — 0 occurrences across all 289 refs. *Positive control on that zero:* the same sweep finds `V2.2.30` on **18** distinct refs, so the instrument works and the zero is real.<br>**Re-run it again immediately before writing the file** — a sweep cannot see a branch pushed after it ran, and **this directory has collided before**: the all-ref sweep shows three duplicated version numbers across branches (two different `V2.2.01`, two `V2.2.02`, two `V2.2.03`). That history is why the rule exists, and the 2026-09-16 near-miss above is why it is not theatre. Required *rows*: `location` WHERE `name = 'Damaged'` in every tenant that will receive damaged returns. | Nam / ops | `Damaged` verified present on `nywh-shipitez-uat` (id 6, type 3, area 0) and `c1wh-shipitez-uat` (id 50184, type 50053, area 50100). **Name-keyed with no unique index and no "DO NOT REMOVE" description**, and `UtilRestController.initDB` throws rather than creating it. Add to the tenant-onboarding checklist. |
| 1a | **Flyway run safety** (new — D6 introduces the first migration in this plan) | Merging Phase 1 to `develop` is a dev deploy **and runs Flyway against every tenant DB on boot**. Before merging: (i) run the migration-collision sweep in row 1 again; (ii) confirm no tenant is already **stalled** at an earlier version — tenant object-ownership drift stops Flyway at the failing migration and it stays stopped (prd `wh01_hydra_v2` sat at `V2.2.06` for exactly this reason), so a new migration lands on some tenants and not others; (iii) note that a DB with **no `flyway_schema_history`** is skipped entirely rather than migrated. **Do not reason about which tenants those are — measure it.** Run **both** probes per tenant before merge — they answer different questions and the second is the one that would have caught the `V2.2.06` incident a boot earlier:<br>① *already stalled?* `SELECT count(*) FILTER (WHERE success IS FALSE) AS failed, max(version) FILTER (WHERE success) AS max_ok FROM flyway_schema_history;`<br>② *would `V2.2.32` stall it?* `SELECT pg_get_userbyid(c.relowner) AS owner, current_user FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname='public' AND c.relname='adviceposition';` — Postgres checks ownership **before** `IF NOT EXISTS`, so being fully caught up says nothing about it. Measured 2026-09-15: the app role owns `adviceposition` on **all six** active tenant DBs (every row of both landlords' `tenant_db_configuration`, plus dev), so this passes everywhere today — which is exactly when it is cheap to institutionalise. | Nam / ops | ⚠ **There is no startup safety net.** Production runs `spring.jpa.hibernate.ddl-auto=none` (`application.properties:105`; `validate` is commented out at `:104` and appears only in the test tree, whose own comment says it *"DIVERGES from production"*). A tenant that misses `V2.2.32` **boots green** and then throws `42703 column … does not exist` **per request**, behind passing health probes, across the whole receiving stack — `git grep -ln "Adviceposition"` returns **18** `src/main/java` files including `ReceivingService`, `AdviceService`, `ReportService` and `FileImportController`. *(Rev5 claimed Hibernate `validate` would catch it. That was false and is withdrawn — a false safety net is worse than none.)* The pre-merge probes are the only control. |
| 1b | **⚠ Do not confuse "client not yet cut over" with "v2 schema not provisioned"** — they are different axes and conflating them invents a manual step nobody needs | **ShipItEZ's v2 tenant DBs are live, current Flyway targets.** Measured 2026-09-15 over MCP: `wh01_shipitez_v2` and `wh02_shipitez_v2` each hold 31 `flyway_schema_history` rows, **0 failed**, max successful **`V2.2.30`** — the same max the 285-remote-ref sweep returns — both applied at 15:53 **today**. So `V2.2.32` reaches ShipItEZ automatically on the next boot after merge: **no manual step, no history backfill.** The DB with no `flyway_schema_history` is `wh01_shipitez`, their **v1 production** database, which is a different system — not in the v2 landlord's tenant list and never a Flyway target. *(An earlier revision of this plan asserted the opposite, generalising from "not yet cut over". The client's **traffic** has not cut over; their **v2 schema** is provisioned and kept current ahead of it. E0's "frozen 2026-09-10" is true of the **advice data** and not of the **schema**, which moved today — both facts hold, and conflating them is what produced the error.)* | Nam | The real stalled-tenant instance is **prd `wh01_hydra_v2`**, which sat at `V2.2.06` on `42501 must be owner of function stock_history` until an operator ran the ownership tool. Use that as the worked example; ShipItEZ is not one. |
| 2 | **Feature flags / system properties** | `RETURN_ADVICE_AUTO_RECEIVE_ACTIVATED` — **leave alone.** It is default-**ON** via a deliberate `!"false".equalsIgnoreCase(...)` read whose javadoc says *"Do not 'consistency-fix' this."* No new sysprop is introduced (§3.1). `PRINT_CASE_LABEL` must be `true` for any label at all; it is `Boolean.parseBoolean`, **default OFF**. | Nam | Measured `true` on `c1wh-shipitez-uat`, `modified 2026-09-09` — but `los_sysprop.modified` dates the **row**, not the value, so that timestamp does not prove the value changed. |
| 3 | **Config / env changes** | None. No new property, no Keycloak client, no Jasypt (v2 has no property encryption). | — | Rationale for `N/A`: the feature adds no configurable behaviour; §3.1 argues that deliberately. |
| 4 | **Deploy-order dependencies** | ⚠ **Restore netting in `oms-laravel-api` ([SBDEV-3366](https://app.clickup.com/t/868m5j9qr), Urgent · Bug) BEFORE ShipItEZ — or any other high-return-volume client — cuts over to v2 with this feature live.** Commit `dd17b84f` (2026-07-31) made the OMS stop netting `quantity_on_hand` on the incremental path, so the `normal = 0, damaged = +N` pair this feature emits on every mixed return overstates sellable inventory by N. **The gate is a cutover event, not this ticket's merge** — see the measurement in §3.11.3. **Both halves, because the asymmetry is the useful part: SBDEV-1512 is safe to ship now, and unsafe at ShipItEZ cutover without SBDEV-3366.** **Phase 1 (wms2-api) must be on `develop` before Phase 2 (qa-api) merges.** Not for safety — if Phase 2 lands first the new key is simply dropped by every WMS — but because otherwise the feature reads as shipped while doing nothing. **⚠ The binding constraint is the other direction: `qa-api` is SHARED and routes by `wms_url` per facility, so Phase 2 ships into live v1 traffic on day one.** Phase 2 must not merge until §3.7's tolerance test is green. Phases 3 and 4 (qa-ui) are independent of 1 and 2 and can land in any order. | Nam / David | Merging to `wms2-api` `develop` **is** a dev deploy and runs Flyway; there is no CI on PRs, only on branch push. |
| 5 | **Data migration** | **None, and the new column needs none** — it is nullable, and `null` reads as "this advice predates the feature", which is exactly right. Historical damaged quantities live in the OMS `return_item.quantity_damaged` for returns already closed on both sides, and back-filling them would create WMS stock for bottles physically disposed of months ago. *(Rev1 used this same rationale to justify adding no column at all. It never argued that — it answers a question about **historical backfill**, which stays "no"; it says nothing about a forward column, and D6 adds one.)* | — | If Nam wants historical visibility, that is a report against the OMS, not a WMS backfill. |
| 6 | **External systems** | A `printer` row of type `RETURN` with `processdefault = true` must exist and be CUPS-reachable — an existing precondition of auto-receive, unchanged. OMS `WEBSERVICE_STOCK_UPDATE_URL` must be configured, or `OmsNotificationService.sendAfterCommit` logs a `FAILED` message row instead of POSTing. **⚠ `wms_url_lut` must be confirmed correct per facility before Phase 2 reaches a two-warehouse client** — the lookup is keyed on the *fulfilling* facility, not the returning one (FU-4, §10). Run `SELECT facility_code, wms_url FROM wms_url_lut;` on each client's OMS schema and confirm every row points at the intended WMS. | ops | `wh01_shipitez` has `OPS 1`, type RETURN, `processdefault true`. **`wh02_shipitez` was not checked** — no MCP for it in this session. The `wms_url_lut` read also has no MCP in this session and is therefore an unmet prerequisite, not a verified one. |
| 7 | **Access / permissions** | **None added.** `setLockDamaged` is reached from a service, not a controller, so `WEB_UI_ACTION_ADJUST_LOCK_DAMAGED` is not consulted. This is D4's knowingly-accepted exposure — see §10 D4. No new `FunctionEnum` constant, therefore no `initDB` grant line and no role-matrix change. | — | |
| 8 | **Monitoring / alerts** | New counter `wms2.returns.autoreceive.damage_failed`, alongside the existing `success` / `partial_failure` / `skipped_no_positions`. | Nam | **A metric here is not a control**: nothing scrapes Prometheus in this estate yet. It exists for post-hoc diagnosis. The operational signal is the `200`+warning envelope and the `LOG.error` with the correlation id. |

### 5.2 Phase 1 — WMS receive-damaged capability (`wms2-api`)

Prereq: none. Independently landable. Ships a capability nothing yet exercises — by design, so the
QA-side change in Phase 2 lands against a WMS that already understands it.

- [ ] **D6-B migration** `V2.2.32__adviceposition_notified_damaged_amount.sql` — free as of
      2026-09-15 across 287 remote refs; **re-run the §5.1 row 1 sweep immediately before creating
      the file**, since a sweep cannot see a branch pushed after it ran
- [ ] **D6-B** `Adviceposition.notifieddamagedamount` **and `damageappliedat`** fields + accessors —
      **no initialiser on either** (M4)
- [ ] **D6-B** stamp `damageappliedat` in `applyDamage`, **only after `setLockDamaged` returns
      normally**, in its own short tenant transaction (§3.3 step 4)
- [ ] **D6-A + D6-B** `AdviceRestController` save loop: the explicit-coalescing block from §3.2 —
      **never** `undamaged + damaged` (H2), and the damaged-field validation goes here, in the
      unconditional loop, not only in `resolveRefs` (H3)
- [ ] `AdvicePositionDto.amountOfBottlesDamaged` + accessors + `toString`
- [ ] **FU-2 — fix it here, in this edit.** Adding H2's coalescing puts the implementer **three lines
      from** `Boxtype boxtype = optionalBoxtype.get();`, which NPEs on any REGULAR advice submitted
      without `box_id` — `Optional<Boxtype> optionalBoxtype = null;` is only assigned inside
      `if (StringUtils.isNotEmpty(advicePosition.getBoxId()))`. That is an HTTP 500 **after**
      `adviceRepository.save` has committed, so the advice's `externalid` is burned and every OMS
      retry dies on the duplicate guard — a permanently unmanageable parcel. Same file, same loop,
      same class of bug as H2, and the marginal cost is minutes.
      **Leaving a known unrecoverable 500 untouched while editing the lines around it is not a scope
      boundary, it is an omission** — and the RETURN path only escapes it because `resolveRefs`
      pre-empts it, which is exactly the asymmetry H3 is also correcting. Add a test alongside T1.18
      for a REGULAR advice with no `box_id`.
- [ ] **Validation in the POSITION SAVE LOOP** (H3) — beside the two checks already there
      (`getAmountOfBottles() == null` → `FIELD_NOT_SET`, `< 0` → `FIELD_MALFORMED_FORMAT`): reject
      `amount_of_bottles_damaged < 0`, and reject `amountOfBottles + damaged` above
      `MAX_UNITS_PER_POSITION`. **This loop runs unconditionally**; `resolveRefs` does not
- [ ] `resolveRefs`: the auto-receive-specific **additional** tier — relax `undamaged >= 1` to
      `total >= 1`, and the per-position rules that only make sense when auto-receiving
- [ ] `resolveRefs`: conditional `Damaged` pre-flight (§3.5)
- [ ] `ResolvedLine` / `AutoReceiveLine` gain `damagedAmount`; `bind` zips it
- [ ] `ReceivingService.receiveGoods` returns `List<Long>`
- [ ] `executeInternal`: receive loop, then damage loop; `applyDamage`
- [ ] `Status.DAMAGE_FAILED`, `FailureReason.DAMAGE_APPLY_FAILED`, `code()` arm, `damageFailed(...)` factory
- [ ] `WmsConstants` 603 + arms in **both** name and text switches (`git grep -n "= 603;"` first)
- [ ] counter `wms2.returns.autoreceive.damage_failed`
- [ ] Tests T1.1–T1.13 (§7), each mutation-checked with PIT scoped to the changed class. **T1.11
      lives in a different class** (`ReceivingServiceUnitTest`) and guards the signature change §3.2
      depends on — an implementer ticking boxes by class would drop it.

### 5.3 Phase 2 — QA station sends the damaged quantity (`qa-api`), with 2a in `v1/wms-api`

Prereq: Phase 1 on `develop`; §3.7's tolerance test (Phase 2a) green.

- [ ] **2a:** `v1/wms-api` test-only `AdviceDtoUnknownPropertyToleranceTest` (no production change)
- [ ] `build_wms_create_advice_request`: emit `'amount_of_bottles_damaged': returned_items[item.item_id].get('qty_damaged', 0) or 0` **unconditionally** on every position. ⚠ **`.get`, not a subscript** — `returned_items` is `{item['item_id']: item for item in returned_items}` built from raw request dicts, and the rest of the file already treats the key as optional (`returned_item.get('qty_damaged', 0)`, twice). A subscript is a 500 on every return whose client payload omits `qty_damaged`, shipped into live v1 production traffic on day one per §8 constraint 1
- [ ] **D7** — `send_wms_create_advice` inspects `data.get('warning')` on a 200 and surfaces it rather than returning a bare success (§3.4)
- [ ] `amount_of_bottles` semantics **unchanged** (undamaged only) — §3.1 W1
- [ ] emission predicate **unchanged** (`amount_of_bottles > 0`) — §3.1 W2 is why
- [ ] **Log the success case to `service_log`** — see §5.3.1 below
- [ ] Tests T2.1–T2.4 (§7)

#### 5.3.1 Also in Phase 2 — make the success case observable

`wms_api.py` returns on HTTP 204 **before** `insert_wms_response_in_service_log` runs:

```python
if response.status_code == 204:
    return {'status': 'success'}
```

so `service_log` holds **failures only**. Non-204 responses are logged (both the parseable-JSON and
the non-JSON branches write a row before the status check); 204 — the normal WMS success — writes
nothing. This is inconsistent with the QA-complete path, which *does* log its 204 via
`check_wms_qa_response`.

**Why this is in scope rather than a follow-up:** an absent `service_log` row currently means one of
*"the advice succeeded"*, *"the advice was never attempted"* (Defect A, or the fully-damaged skip) or
*"`CONTACT_EXTERNAL` is false"* — the table cannot distinguish them. That is exactly the ambiguity
Defect A creates, and it means **there is no instrument in the estate that can measure how often the
WMS branch is actually taken.** Without it, Phase 3's fix cannot be shown to have worked except by
anti-joining the OMS `returns` table against the WMS `advice` table across two databases, one of
which has no MCP server here. The change is a few lines in the 204 branch and it is the cheapest
observability in this document.

Keep the existing `service_url` filter discipline in any query built on it: `service_log` is also
written by the Komatik notification path with a `None` response.

### 5.4 Phase 3 — Defect A, the disposition select (`qa-ui`, T2)

Prereq: none. Independent of Phases 1, 2 and 4. **Highest client-visible value of the four** — it is
the only one that restores restock for an operator who never touches the dropdown.

- [ ] `dispositionSelection.vue` notifies the parent of the pre-selected value
- [ ] sibling sweep for the same `mounted()`-without-emit shape across qa-ui (§3.8)
- [ ] Tests T3.1–T3.2 (§7)

### 5.5 Phase 4 — Defect C, the swallowed error (`qa-ui` + `qa-api`, T1)

Prereq: none.

- [ ] `store/util.js` `processApiErrors` normalises the payload shape
- [ ] `view_helpers/returns_helper.py`'s `except WmsException` block emits the documented list shape
      (**not `views/parcel_info.py`** — §3.9)
- [ ] Tests T4.1–T4.2 (§7)

---

## 6. Backward Compatibility

| Aspect | Before | After | Risk |
|---|---|---|---|
| `AdvicePositionDto` without the new key | 6 fields bind | 7 fields declared; absent key → `null` → treated as 0 | **None.** Identical code path. |
| REGULAR advices — **the damage branch** | no damage concept | unchanged — gated on `damagedAmount > 0`, and REGULAR never reaches `ReturnAdviceAutoReceiveService` | None |
| REGULAR advices — **the D6 write** | `notifiedamount = amount_of_bottles` | `notifiedamount = amount_of_bottles + damaged`, and `notifieddamagedamount` persisted — **the save loop is unconditional** | ⚠ **Not "unchanged", and rev5's row said it was.** A REGULAR advice, a tenant with auto-receive off, and an empty-positions RETURN all reach this write without ever entering `resolveRefs`. That is why H3 moves the damaged-field validation into the save loop; without it an unauthenticated caller could put an arbitrary value into `notifiedamount` on those three shapes. Graded by T1.18. |
| Spreadsheet advice import (`FileImportController`, `AdviceUploadDto`) | — | untouched, different DTO | None |
| RETURN advice with `damaged = 0` | received unlocked at the putaway destination | **byte-identical** — no pre-flight, no damage loop, no second OMS message | None |
| `receiveGoods` callers | `void` | `List<Long>`; discarding a return value is legal Java, so `ReceivingController` needs no edit | Compile-checked |
| `amount_of_bottles` validation | `>= 1` | `>= 0`, with `total >= 1` | A position with `undamaged = 0, damaged = 0` is now rejected by the *total* rule rather than the field rule — same rejection, different message key. T1.3 pins it. |
| v1/wms-api receiving the new key | n/a | key dropped; `amount_of_bottles` unchanged | **None, if W1 holds.** §3.7 makes it executable rather than asserted. |
| OMS `StockChangeDto` | one message, `normal = +N` | two messages: `normal = +N` then `normal = 0, damaged = +D` — the same pair the manual damage flow has emitted since 2022 | **None to the contract, and this is now measured rather than asserted** (E8: 173 occurrences of that exact pair on live v1 production, 0 of any other shape, with a working positive control). ⚠ **But today's `oms-laravel-api` mishandles it** — not because the WMS is wrong, but because of a consumer-side regression (`dd17b84f`). See §3.11.3: the OMS fix is a deploy-order prerequisite for this ticket. |
| `AutoReceiveOutcome` consumers | 3 statuses | 4; the controller builds the envelope generically | Low — T1.9 asserts the envelope for the new status |
| **`adviceposition` schema** | **19** columns (V2.2.00 DDL, confirmed by `information_schema.columns` on two tenants of different lineage) | **+2** nullable — `notifieddamagedamount` and `damageappliedat`, added by one `ALTER` in one Flyway file | **Low, but it is a Flyway run on every tenant.** Nullable with no default and no backfill, so existing rows read `null` = "predates the feature". §5.1 rows 1 and 1a carry the collision sweep and the stalled-tenant check. |
| **`notifiedamount` semantics** | the **undamaged** quantity | the **total that arrives** (undamaged + damaged) | **Bounded, and measured rather than asserted.** Consumers: `AdviceRepository`'s `SUM(ap.notifiedamount) as qtyRequired` and `ReceivingDtoViewRepository`'s `ap.notifiedamount AS orderedbottles` (+ the `receiving_dto_view` behind it). Per **E6**, `information_schema.views` matching `%notifiedamount%` → 1 view, `pg_get_functiondef` over `pg_proc` → **0** report functions, with a working positive control. Both consumers now read the quantity that physically arrived, i.e. the *correct* value; the receiving screen stops being able to read "ordered 7 / received 10". E6's blind spots: snapshot frozen 2026-09-10, `prokind='f'` excludes procedures, and a Java projection deriving the column by property name is invisible to both instruments. |
| **E3 as a health check** | `goodsreceiptposition.amount == notifiedamount` on all 1037 RETURN advices | **still holds**, because `notifiedamount` becomes the total | None — and this is a reason to prefer D6's `notifiedamount = total` over leaving it at the undamaged quantity, which would have broken the invariant this plan's own evidence uses. |
| **`RETURN_ADVICE_AUTO_RECEIVE_ACTIVATED = false`** | returns not auto-received | **unchanged, and it silently disables this feature too** | **Accepted, recorded.** On such a tenant qa-api sends the damaged quantity, the WMS parses and persists `notifieddamagedamount`, and nothing applies damage — because `resolveRefs` never runs, §3.5's pre-flight never runs either. Post-D6 the quantity is at least **on the row**, so the §3.2 worklist query finds it; pre-D6 it was lost. Default is ON, so this is an opt-out, not a default state. |
| **`DAMAGE_FAILED` visibility to the operator** | n/a | surfaced by qa-api (D7) | Without D7 this would be invisible — `send_wms_create_advice` branches only on `status`, and the WMS sets `status: success` beside the warning. T2.5 grades the consumer, not just the producer. |
| `qa-ui` disposition behaviour | parent silently keeps `1` | parent receives the pre-selected value | **Behaviour change by intent.** An operator who *relied* on the silent non-restock default would now restock. That is the fix. |

### What Does NOT Change

- `StockunitService.setLockDamaged` — reused verbatim; the manual damage UI path is untouched.
- `UnitloadService.moveStockToNewDamagedContainer` — untouched, including
  `findByIdForUpdate(damagedLocation.getId())` as its **first** statement.
- `StockChangeDto`, `SharedService.getStockChangeDTO` — D5, no DTO change.
- `RETURN_ADVICE_AUTO_RECEIVE_ACTIVATED` and its deliberate default-ON read.
- `AutoReceiveOutcome`'s `SUCCESS` / `PARTIAL` / `SKIPPED` semantics, the `diagnose()` ladder, and
  the `PARTIAL`-leaves-the-advice-`OPEN` recovery contract.
- The single-element-array batch shape (`MAX_RETURN_ADVICES_PER_REQUEST`, and the rule that an
  auto-receiving RETURN advice must arrive alone).
- `AdviceRestController`'s **warning envelope** — genuinely generic, so a fourth `Status` flows
  through untouched (T1.9). The file itself **is** edited, for D6's two setters (§0 row 11).
- The `adviceposition` **primary key, indexes and existing columns**; no table, no index and no data
  migration are added. The one schema change is the single nullable column in D6.
- `v1/wms-api` production code, and `v1/wms-web-ui` / `wms2-web-ui` / `wms2-mobile-ui` entirely.
- The `amount_of_bottles` wire field's meaning.

---

## 7. Testing Strategy

**Two standing rules apply to every row below.** (a) Each new assertion is **mutation-checked with
PIT scoped to the changed class**, and the kill must be **attributable** — the failure message must
name the thing broken. A red arriving as `NoSuchMethodException`, or as an NPE in setup, is not a
kill. (b) The mutation fixture must carry a value in the **dominant band** for the mutated operator,
or a boundary-only fixture lets a survived mutant read as killed.

> ### ⚠ Where a test's expected value comes FROM is a separate question from whether it is right
>
> This plan produced two instructive failures, and the second one only became legible after the
> design was reversed. Name the pattern here, because the next author will meet it:
>
> - **T1.10** (rev1) asserted only that `setLockDamaged` is *never* invoked when `damaged = 0`. An
>   implementation in which `applyDamage` was never written satisfied it perfectly. A bare `never()`
>   with no positive control grades nothing. Fixed by pairing the two cases in one method.
> - **I5** asserted `normal = 0, damaged = +3`. That value is **correct** — E8 measured 173
>   occurrences of exactly that pair on live production traffic and zero of any other shape. But it
>   was correct **by transcription**: it was copied from what the design said to send, not derived
>   from what the consumer's contract requires. The provenance, not the value, was the defect — and
>   it showed when E7 arrived with a plausible contrary reading and the row was duly "corrected" to
>   `normal = −3`, which would have pinned a defect as the expected result. A value with no
>   independent derivation cannot resist a wrong argument, because there is nothing to check the
>   argument against.
>
> **The rule both point at: an expected value needs a source that is independent of the change being
> tested, and the source has to be named.** For I5 that source is **producer traffic** — the 173/0
> measurement in E8 — not this plan, not the design, and not the consumer's code comment.
>
> **The same failure produced E7, one layer up, in this same session — and the pair is more
> convincing than either alone.** I5 transcribed its expected value from the design instead of
> deriving it from the contract. E7 transcribed the contract from the OMS's code comment instead of
> deriving it from the wire. **Two instances, one root: an artefact was copied where it should have
> been checked.** Neither was careless — the design *was* the best available description of intended
> behaviour, and the comment *was* written by the people who own that code. That is exactly why the
> failure is worth naming: it does not feel like guessing at the time, and in I5's case it produced
> the *right answer*, which is the version that leaves no trace until something flips it.
>
> Where a contract is external, cite the artefact the expected value came from, so the next person
> can re-check it instead of re-arguing it.

**These tables are the acceptance criteria.** There is no separate AC section: each `T`/`I`/`M` id
below is a numbered, independently gradable criterion, and `wms-tdd-gate` should take them as its
input directly rather than synthesising ACs from prose. The primary AC is **I1** and it grades
`entity_lock = 103` per §1.3, not location membership.

Correction to the brief: **`BaseControllerTest` does not exist** in this repo. The controller bases
are `BaseControllerUnitTest` and `BaseControllerIntegrationTest` (instrument:
`git ls-tree -r --name-only origin/develop -- src/test | grep Base`).

### 7.1 Unit tests

| id | Class | Method | Asserts |
|---|---|---|---|
| T1.1 | `ReturnAdviceAutoReceiveServiceUnitTest` | `resolveRefs_acceptsZeroUndamagedWhenDamagedPositive` | `undamaged = 0, damaged = 5` validates; pins the relaxation and the forward-readiness of §3.1 |
| T1.2 | ″ | `resolveRefs_rejectsNegativeDamaged` | `FIELD_MALFORMED_FORMAT` naming `amount_of_bottles_damaged` |
| T1.3 | ″ | `resolveRefs_rejectsZeroTotal` | `undamaged = 0, damaged = 0` rejected **by the total rule**; names which message key, per §6 |
| T1.4 | ″ | `resolveRefs_rejectsTotalAboveMaximum` | `undamaged + damaged > 100_000` rejected; a fixture at `99_999 + 2` so the `<`→`<=` mutant is in the dominant band |
| T1.5 | ″ | `resolveRefs_preflightsDamagedLocationOnlyWhenDamagePresent` | `findByName("Damaged")` is invoked when any position has damage and **is not invoked** when none does. ⚠ The negative half must use a **strict** stub with an ungated positive control — a `never()` on a method nobody calls passes vacuously. |
| T1.6 | ″ | `bind_zipsDamagedAmountPositionally` | `AutoReceiveLine.damagedAmount` matches the DTO order; mutating one position's value fails the assertion |
| T1.7a | ″ | `applyDamage_returnsDamageFailedWhenSetLockDamagedThrowsChecked` | `setLockDamaged` stubbed to throw `BusinessException` (the reserved-amount case): outcome is `DAMAGE_FAILED`, **`markFinished` still ran**, `received == total`, reason `DAMAGE_APPLY_FAILED`. |
| T1.7b | ″ | `applyDamage_returnsDamageFailedWhenSetLockDamagedThrowsUnchecked` | **The one that actually matters.** Stub an *unchecked* throw — `EntityNotFoundException` (the two `orElseThrow` sites) and, as a second case, `PessimisticLockingFailureException` (the 5 s `lock_timeout` on `findByIdForUpdate`). Same four assertions. Rev1's single row did not name an exception, so a test stubbing `BusinessException` would have passed while every real failure mode escaped as an HTTP 500 with all stock received and `markFinished` unreached. **Mutation-check both**: narrowing the catch to `BusinessException \| FacadeException` must turn T1.7b red, and the failure message must name the escaping exception — a red arriving as a Mockito stubbing error is not a kill. |
| T1.8 | ″ | `applyDamage_damagesRemainingPositionsAfterFirstFailure` | Position 2 fails, position 3 is still damaged, the outcome names position 2's SKU |
| T1.9 | `AdviceRestControllerUnitTest` (`BaseControllerUnitTest`) | `damageFailedOutcomeRendersWarningEnvelope` | HTTP **200**, `warning.code == "RETURN_AUTO_RECEIVE_DAMAGE_FAILED"`, non-null `description` and `correlation_id`. Also pins §0 row 11's "no controller edit" expectation. |
| T1.10 | ″ | `damageIsAppliedOnlyWhenDamagedAmountPositive` | **Two cases in one test method**, so the negative half is guarded by the positive half and the whole row can fail: (a) `damaged = 0` → **no** `setLockDamaged` interaction, `notifieddamagedamount` persists as `0`/`null`, `204`; (b) `damaged = 3` on an otherwise identical fixture → `setLockDamaged` **is** invoked. *(Rev1 stated only case (a). That was a bare `never()` with no positive control — an implementation in which `applyDamage` was never written satisfied it perfectly, so it reported coverage it did not provide. The plan flags exactly this failure mode on T1.5 and rev1 did not apply it one row later.)* Mutation target: deleting the `damagedAmount > 0` guard must turn case (a) red; deleting the `applyDamage` call must turn case (b) red. |
| T1.12 | ″ | `applyDamage_invokesSetLockDamagedWithDamagedAmountAndReceivedStockunit` | **The success path, which rev1 graded nowhere.** Fixture 3-of-10 (deliberately *not* 5-of-5, so a `damagedAmount` → `amount` swap lands in a distinguishing band): capture the `setLockDamaged` arguments and assert `amount == 3` **and** that the `Stockunit` id is the one `receiveGoods` returned for **that position**. Without this, a mutant swapping `line.damagedAmount()` for `line.amount()`, or dropping the `damagedAmount > 0` guard, survives every unit test and is caught only by I1 — which PIT's `-DtargetTests=…unit.service…` recipe does not run, so the repo's own "mutation-check every new assertion" rule could not reach the plan's primary behaviour. |
| T1.17 | `AdviceRestControllerUnitTest$DamagedQuantity` | `absentDamagedKeyDoesNotNpeAndLeavesColumnNull` | **H2.** POST a position body with **no** `amount_of_bottles_damaged`: assert **2xx** (not 500), `notifiedamount == amount_of_bottles`, and `notifieddamagedamount == null`. Repeat for a REGULAR advice, since that is the bulk of live traffic. **Mutation-check by deleting the coalescing** — the test must go red with an NPE *named at the controller*, not at a mock. ✅ **Written and mutation-proven 2026-09-16.** Kill message: `NullPointerException: Cannot invoke "java.lang.Integer.intValue()" because the return value of "AdvicePositionDto.getAmountOfBottlesDamaged()" is null at AdviceRestController.create(AdviceRestController.java:457)` — names the method and the controller line.<br>⚠ **Correction to this row's earlier framing.** It was described as the row standing between the spec and a silent production outage. The mutation run shows that is **overstated**: the naive boxed addition also errors **6 pre-existing tests** in `ReturnAdviceAutoReceiveSoftFail`, which pass advices through the same loop and have nothing to do with the damaged field. Develop is green and CI gates the **deploy** on `mvn verify`, so the defect would have gone red in the build rather than reaching production. What T1.17 actually buys is a **named, intentional assertion with a diagnostic that says what is wrong**, instead of six unrelated tests erroring with a stack somebody has to decode — real value, but "better diagnosis", not "the only thing preventing an outage". |
| T1.18 | ″ | `damagedFieldIsValidatedOnPathsThatSkipResolveRefs` | **H3.** Shapes that never enter `resolveRefs`, each carrying `amount_of_bottles_damaged: -5000`, all of which must be **rejected** by the save-loop validation: a REGULAR advice, and a RETURN with auto-receive disabled. ⚠ **CORRECTED 2026-09-16 — the row originally named a third shape, a RETURN with an EMPTY `positions` list, and that shape is unconstructible:** the field being validated is a *per-position* field, so an advice with no positions has nowhere to carry it and the save loop it is validated in does not execute. The row was incoherent as written; it is two shapes, not three, and the built test covers both. Recorded rather than silently deviated from. ⚠ Without this row the validation can sit in `resolveRefs` and every one of these tests still passes, which is exactly how rev5 specified it. |
| ~~T1.19~~ | ″ | ~~`damagedPortionRecoveryWorklistExcludesRecoveredPositions`~~ | **DEFERRED 2026-09-16 — this row grades code that does not exist.** An independent row-conformance lane established, by `git grep -n "damageappliedat" -- src/main`, that the worklist lives only in this document's prose: there is no repository method and no query. The row cannot be written without first deciding whether the worklist is a derived repository query or stays a runbook SQL — a decision this ticket never took. **What the column buys is still delivered and still tested:** the stamp's two states are pinned by `applyDamage_success_stampsDamageApplied` (stamp written on success) and `applyDamage_failure_returnsDamageFailedAndStillFinishes` (`never()).save` on failure), so a position that needs recovery is distinguishable in the data whether or not a query exists to list it. Re-open this row with the worklist itself, ~45 min including the repository-test traps (wms2 repository tests commit rather than roll back — assert by id). |
| T1.13 | `AdviceRestControllerUnitTest` | `damageFailedPersistsNotifiedAmounts` | D6: for a 7+3 line, `adviceposition.notifiedamount == 10` **and** `notifieddamagedamount == 3`. Mutation target: swapping the two setters, or setting `notifiedamount` from the undamaged field, must fail here. |
| T1.11 | `ReceivingServiceUnitTest` | `receiveGoods_returnsCreatedStockunitIds` | One id for `amountCases = 1`; asserts the id **is** the created stock unit's, not a positional coincidence |
| T2.1 | qa-api `tests/test_unit/.../test_wms_api.py` | `test_build_request_always_emits_damaged_key` | The key is present on **every** position, including when `qty_damaged == 0` (D2's "unconditional") **and when the client payload omits `qty_damaged` entirely** — the latter case is what distinguishes `.get('qty_damaged', 0)` from a subscript, and a subscript is a 500 on live v1 traffic (§5.3) |
| T2.5 | ″ | `test_200_with_warning_is_surfaced_not_swallowed` | **D7.** A 200 body carrying `{"status":"success","warning":{...}}` must not return a bare success. Grades the **consumer**; T1.9 grades the producer, and rev1 had no row on this side at all — which is why §3.4's "the caller must be told" was false. |
| T2.2 | ″ | `test_amount_of_bottles_still_undamaged_only` | Regression pin for §3.1 W1 — the value equals `qty_undamaged`, **not** the total. If this test is ever changed, W2/W3's consequences apply. |
| T2.3 | ″ | `test_position_skipped_when_undamaged_zero` | The emission predicate is **unchanged**; this test is the guard on W2 and its docstring must say why |
| T2.4 | qa-api `tests/test_unit/.../test_wms_api.py` | `test_204_response_writes_service_log_row` | §5.3.1 — a 204 now produces a `service_log` row. ⚠ Assert the row's **content** (`service_url`, `response`), not merely that the writer was called: a writer invoked with an empty payload would satisfy a call-count assertion and leave the forensic gap exactly as it was. |
| T3.1 | qa-ui `tests/unit/dispositionSelection.test.js` (new) | `emits_preselected_disposition_without_user_interaction` | Mount with a `return_preference` matching a disposition → the parent receives it. ⚠ **Mount-with-value-present is not a reactivity test** — the assertion is on the emitted event, not on rendered state. |
| T3.2 | ″ | `emitsNothingWhenPreferenceUnmatched` | Unset / unmatched preference → no emit, and `chosenDisposition` **remains at its `1` default**, i.e. the select displays **"Manually Manage"** — *not* an empty select. *(Rev1 said "renders empty". `data()` returns `{ chosenDisposition: 1 }` and `mounted()` overwrites it only `if (preferred_disposition)`, so that assertion would fail against correct code, and the natural way to make it pass — defaulting to `null` — is an unrequested behaviour change that also alters what the parent's untouched `disposition: 1` means. §3.8 says why not.)* |
| T3.3 | ″ | `emits_when_dispositions_arrive_after_mount` | Mount with an **empty** `dispositions` store, then populate it. The parent must receive the preference. This is the cold-navigation path (§3.8): a child's `mounted()` runs before its parent's, and the list is fetched asynchronously, so a fix that only emits from `mounted()` leaves this case broken. |
| T4.1 | qa-ui `tests/unit/util.test.js` | `processApiErrors_handles_string_payload` | A string `messages` produces a toast and **does not throw** |
| T4.2 | qa-api `tests/test_unit/.../test_returns_helper.py` | `test_wms_failure_returns_list_shaped_messages` | `process_managed_returned_parcel`'s `except WmsException` block emits the documented list-of-dicts. *(Rev1 named `test_parcel_info.py` for behaviour that lives in `returns_helper` — §3.9.)* |

### 7.2 Integration tests (Testcontainers)

| id | Class | Asserts |
|---|---|---|
| I1 | `ReturnAdviceAutoReceiveIntegrationTest` (extend) | **Mixed line, the primary AC.** POST an advice with `amount_of_bottles = 7, amount_of_bottles_damaged = 3`. Assert against the DB: exactly one stock unit with `amount = 3` **and `entity_lock = 103`** (the primary grade — §1.3), one with `amount = 7` and `entity_lock = 0`; the damaged unit's unit load sits at the location named `Damaged` (the **secondary** assertion); a `stockrecord` row exists with `activitycode = 'DAMAGED'` and `type = 'STOCK_CREATED'` (the `transaction_detail` axis); **D6: `adviceposition.notifiedamount = 10` and `notifieddamagedamount = 3`, and `goodsreceiptposition.amount = 10`, i.e. `amount == notifiedamount` so E3's invariant still holds**; advice and positions are `FINISHED`; HTTP `204`. |
| I2 | ″ | **Fully damaged line.** `amount_of_bottles = 0, amount_of_bottles_damaged = 4` → one stock unit, `amount = 4`, `entity_lock = 103`. (This shape is not emitted by qa-api under W1; the test proves v2 is forward-ready for the OQ-2 flip.) ⚠ **Assert on quantity, not on row count.** Rev1 asserted "no leftover unlocked unit", which is environment-dependent: `transferStockToUnitLoad` takes its split branch when `fixLocationAssignment != null` — resolved as `findByAssignedlocationId(sourceLocation.getId())`, i.e. the **putaway destination** — and on a tenant where that location carries a fixed assignment the source stock unit is driven to `amount = 0` and **not** sent to Nirwana, leaving a zero-amount `entity_lock = 0` row. That is exactly the shape E2 measured (15 locked-but-not-in-location rows, all amount 0). Assert `sum(amount) where entity_lock = 0` is `0`, or name the fixture's fix-location state in the AC. |
| I3 | ″ | **`Damaged` row absent** → `400` **before** `adviceRepository.save`; assert `advice` count unchanged, so `externalid` is not burned. ⚠ `Hibernate validate` ignores extra columns and nullability, so this must assert row counts, not schema shape. |
| I4 | ″ | **Zero-damage regression.** An advice with no damaged key produces the pre-change state exactly: one unlocked stock unit, no `DAMAGED` stockrecord, `204`. |
| I5 | ″ | **Two OMS messages (D5).** Assert two `StockChangeDto` payloads: `normal = +10, damaged = 0` (receive), then `normal = 0, damaged = +3` (damage). ⚠ **The expected values are derived from measured producer traffic** (E8: 173/0 on live v1 production, positive control passed), **not** from a consumer-side code comment — which is what made the earlier revision of this row assert the wrong arithmetic. Assert on the **serialized payload**, because `getStockChangeDTO`'s positional `int` arguments are exactly the shape where an argument-order mutant survives a mock-interaction assertion. |
| I6 | `v1/wms-api` `AdviceDtoUnknownPropertyToleranceTest` | §3.7 — the payload binds, `amountOfBottles` keeps its value, through the application's mapper configuration |

**Repository-test trap that applies to I1–I5:** wms2 repository/integration tests **commit**; they do
not roll back. Assert by id, never by `isEmpty()` / `hasSize()` on a table-wide read, and do not use
a bare `@PersistenceContext` (that binds the **landlord** EM).

### 7.3 Horizontal Scalability Validation (10 rows — MANDATORY for v2)

| # | Concern | Verdict | Mitigation / rationale |
|---|---|---|---|
| 1 | **In-JVM state** | **No** | No cache, map, static or `ThreadLocal` is introduced. The `damagedAmount` lives in a record inside one request. |
| 2 | **Connection pool math** | **Yes, bounded** | `applyDamage` opens **two** additional short transactions per damaged position, not one as rev1 said: `moveStockToNewDamagedContainer`, then `triggerReplenishmentMaintenance` → `recalculateForItem`, which is `@Transactional(REQUIRED)` and therefore opens its own when called with no ambient transaction (§3.3). Both run **after** `receiveGoods` has committed and released its connection, and they are sequential, so peak concurrent connections per request is unchanged and the "slots, not milliseconds" argument still holds; total connection-seconds roughly double per damaged position. |
| 3 | **Scheduled jobs** | **No job class changed — but the replenishment subsystem is now driven from this path** | No `@Scheduled` method is added or modified. However `recalculateForItem` — the same entry point `ReplenishOrderJob` uses — is now invoked once per damaged position from an HTTP request thread. Rev1's "nothing added or modified" was true of the job classes and false of the subsystem. No ShedLock concern (it is not a scheduled execution), but it is a second writer into replenishment on a `permitAll()` path. |
| 4 | **Long transactions** | **No** | Each damage move and each `recalculateForItem` is its own short boundary; the receive transaction's duration is unchanged. The overall *request* is longer by **two** transactions per damaged position. The relevant duration risk is not transaction length but the **committed-unlocked window** and the **reservation window** named in §3.4, neither of which is a held transaction. |
| 5 | **Request affinity** | **No** | Nothing is remembered between requests. |
| 6 | **Retry / idempotency** | **⚠ Yes — the known sharp edge** | `setLockDamaged` is **not idempotent** (its own code comments say so). If a replica dies between the receive commit and the damage move, an OMS retry hits the `advice.externalid` duplicate guard and is rejected — so the retry does **not** double-damage. The residual state is received-but-not-damaged stock, which is the same state `DAMAGE_FAILED` reports and which the manual UI resolves. Recorded, not mitigated in code. |
| 7 | **Tenant context** | **No** | No `@Async`, no `CompletableFuture`, no new thread. `executeAsIntegrationUser` already manages the `SecurityContext` and `applyDamage` runs inside it. |
| 8 | **Distributed lock correctness** | **Yes — inherited ordering, but a new contention profile** | `moveStockToNewDamagedContainer` takes `findByIdForUpdate(damagedLocation.getId())` as its **first** statement; concurrent damaged returns across replicas serialise on that one row. That is the existing SBDEV-3086 ordering and **must not be reordered**. `findByIdForUpdate` throws **at the lock read**, not at flush; the global 5 s `lock_timeout` (SBDEV-3250) bounds the wait, and a timeout surfaces as `DAMAGE_FAILED` — which is only true because the damage loop catches `RuntimeException` (§3.3). **What is new:** this ticket converts an operator-paced path into a machine-paced one. `MAX_POSITIONS_PER_ADVICE = 500`, so a single `permitAll()` request can take that row's `FOR UPDATE` up to 500 times sequentially, each followed by a `recalculateForItem` (row 2), concurrently with other replicas' returns and the manual `/bulkTransferToDamaged` path. A 5 s timeout degrades into manual recovery work at a rate nobody measures (nothing scrapes Prometheus — §5.1 row 8). **Accepted, not capped**, on the grounds that a 500-position return is not a shape the QA station produces (one parcel, one return) and capping damaged positions would reject a legitimate advice; §10 OQ-6 asks Nam to confirm. |
| 9 | **Cache invalidation** | **No** | `Stockunit`, `Unitload` and `Location` are not Caffeine-cached on this path (instrument: `git grep -n "@Cacheable\|@CacheEvict"` over `StockunitService`, `UnitloadService`, `ReceivingService`; blind spot — a cache declared on a repository interface or via a `CacheManager` lookup would not appear, so the implementer re-runs this grep after the edit). |
| 10 | **External notifications** | **Yes — already correct** | Both `StockChangeDto` messages are deferred via `sendAfterCommit`. ⚠ `applyDamage` must **not** be moved inside an `afterCommit` callback: the registration would land in the list Spring is already iterating and be discarded — no POST, no message row, no metric. `NestedCallSiteRailTest` enforces this; confirm it covers the new call site. |

### 7.4 v2-only constraint checklist (8 rows)

| # | Constraint | Verdict |
|---|---|---|
| 1 | `tenantTransactionManager` named on every tenant write | Yes — no new `@Transactional` is added; all tenant writes go through `moveStockToNewDamagedContainer` and `receiveGoods`, both already correctly named. A bare `@Transactional` would differ by package (landlord in `service`, tenant in `repo.jpa`), so none is added. |
| 2 | OSIV off — no lazy access outside a transaction | Yes — `applyDamage` re-reads the `Stockunit` by id rather than using one handed out of a committed transaction (§3.3 step 2). |
| 3 | Jakarta namespace | Yes — no new `javax.*` import; the new test files must use `jakarta.*` where applicable. |
| 4 | Controller test base class | `BaseControllerUnitTest` for T1.9. **`BaseControllerTest` does not exist** — see §7 preamble. |
| 5 | Caffeine eviction if a cached type is written | `N/A` — §7.3 row 9 establishes no cached type is written on this path, with the instrument and its blind spot named. |
| 6 | No JPA association annotations; manual FK only | Yes — no entity is modified; `Goodsreceiptposition.stockunitId` is already a plain `Long`. |
| 7 | Entity comparison by id, not `.equals()`; no boxed-`Long` `==` | Yes — the assertion in `applyDamage` step 1 compares a **size**, not ids. ⚠ Any id comparison added during implementation must use `.equals()`: boxed-`Long` `!=` works only under 128 and inverts past 127. |
| 8 | Flyway migration required? | **Yes — one, and rev1 said no.** `V2.2.32__adviceposition_notified_damaged_amount.sql` (D6-B), version re-confirmed by the all-remote-branch sweep in §5.1 row 1 immediately before the file is created, with the stalled-tenant and no-`flyway_schema_history` checks in row 1a. Also: `.gitignore` can swallow a newly added `*.properties` file silently, so if a message-bundle entry is added for code 603, confirm `git status` shows it before pushing. |

### 7.5 Manual Test Plan

| Scenario | Environment | Steps | Expected Result | Pass/Fail |
|---|---|---|---|---|
| **M1** Mixed return, happy path | UAT (`c1wh-shipitez-uat` or `nywh-hydra-uat`) | 1. QA station: manage a return, mark 3 of 10 damaged, disposition **Restock Inventory**, submit. 2. WMS: open damaged inventory. 3. `psql`: `SELECT id, amount, entity_lock, storagelocation_id FROM stockunit WHERE ...` | Two stock units: 7 @ `entity_lock = 0`, 3 @ `entity_lock = 103`; the damaged one's unit load is at `Damaged`; **the 3 bottles appear in the damaged-inventory report**; `204` returned to qa-api | |
| **M2** Zero-damage return (regression) | UAT | Manage a return with 0 damaged, restock, submit | Byte-identical to today: one unit load, all stock unlocked, `204`, label prints if `PRINT_CASE_LABEL` is true | |
| **M3** `Damaged` row missing | UAT, on a scratch tenant with the row renamed | Submit a return with damage | `400` before persist; `SELECT count(*) FROM advice WHERE externalid = 'RETURN<id>'` returns **0**, so a retry after fixing the row succeeds | |
| **M4** Label quantity on a mixed line (§3.6 consequence) | UAT with `PRINT_CASE_LABEL = true` | Submit a 10-with-3-damaged return; collect the printed label | Records the **actual** printed quantity. If it reads 10 against a unit load holding 7, FU-1 is confirmed and goes to Nam with this evidence. This row is a **measurement**, not a pass/fail on the feature. | |
| **M5** v1 tolerance (fallback for §3.7) | v1 dev instance | `PUT rest/advice/create` with a payload carrying `amount_of_bottles_damaged` | `204`; the advice is created and `notifiedamount` equals `amount_of_bottles`. **Only run this if Nam declines the Phase 2a test**; one instance on one day is weaker evidence than a test. | |
| **M6** Defect A | qa-ui staging, **two** clients: one with `ship_return_management` = Restock Inventory, one with it unset | For each: open manage-return, change nothing, submit | Configured client: an advice **is** created in the WMS (before the fix: none — this is the reproducing case). Unset client: the select reads "Manually Manage" and no advice is created **either before or after** the fix, because the operator never selected restock. The second row is the **negative control** — without it, testing against an unconfigured client shows "no advice" and reads as a failed fix rather than correct behaviour (§3.8). | |
| **M7** Defect C | qa-ui staging | Force a WMS failure (stop the RETURN printer), submit | An error toast appears **and the modal spinner clears**. Before the fix: silence and a permanent spinner. | |
| **M8** Cross-warehouse routing | UAT, two-warehouse client | Submit a return whose fulfilment facility differs from the physical return facility | Records which WMS receives it, and whether **damaged** stock therefore lands in the wrong building. `return_location` is `fulfillment_facility_code`, i.e. the **fulfilling** facility — pre-existing behaviour (FU-4), flagged, not changed here. This row **measures** FU-4 rather than assuming it. | |
| **M10** Locked putaway lane | UAT | 1. Lock the `PutAwayLane` location (cycle count / operator hold). 2. Submit a mixed damaged return. | `DAMAGE_FAILED` with the advice `FINISHED` and the damaged quantity on `adviceposition.notifieddamagedamount`; **ordinary (undamaged) returns keep succeeding**. This measures the §3.3 source-location precondition, which cannot be pre-flighted because the location is not known until the receive has run. | |
| **M11** Migration landed, per tenant | every v2 tenant DB, before and after the Phase 1 deploy | `SELECT count(*) FILTER (WHERE success IS FALSE) AS failed, max(version) FILTER (WHERE success) AS max_ok FROM flyway_schema_history;` | Before: `failed = 0` and `max_ok` at the pre-merge head on every tenant (measured 2026-09-15: ShipItEZ `wh01`/`wh02` both `2.2.30`, 0 failed). After: `max_ok` is the new `V2.2.x` and `failed` is still 0. A tenant stalled by ownership drift shows an unchanged `max_ok` — that is the signal, and it is a measurement, not an inference from cutover status (§5.1 row 1b). | |
| **M9** `transaction_detail` row label | UAT | Run `transaction_detail(client, sku, start, end)` over a range containing a known manual *Transfer To Damaged*, then over a range containing a damaged return from M1 | Both produce a row labelled **`Damaged`** with `damaged > 0`, distinct from the `Returned` row. **This closes the un-enumerated-arms blind spot in §1.3 / §3.10** — if it instead shows `Returned` with `damaged = 0`, the evidence file's original conclusion was right, §3.10 is wrong, and Alternative D's rejection needs re-deriving. | |

### 7.6 Verify script

**None.** Rationale, per the T3 opt-in rule: every assertion in this plan is expressible as a JUnit,
pytest or Jest test that runs in CI, survives refactors and can be mutation-checked. The one
genuinely cross-repo invariant — *v1 tolerates the new key* — is pinned far better by a test **inside
`v1/wms-api`** (I6) than by a grep row in a shell script, because the test exercises the actual
mapper configuration rather than asserting that a line of config text is present. Verify scripts
have been a measured net negative in this repo, and the two `PROJECT_ROOT` traps plus the
`mvn`-not-on-PATH false red would add noise without adding coverage.

---

## 8. Rollout Plan

| Phase | Repo | Branch | Merge target | Gate before merge |
|---|---|---|---|---|
| 1 | `v2/wms2-api` | `feature/SBDEV-1512-receive-damaged-from-returns` | `develop` | **~3 days**, including FU-2 (minutes, §5.2). T1.1–T1.13 + I1–I5 green; the §5.1 row 1a Flyway checks done and M11 recorded; PIT kills attributable; full suite compared against the known baseline — **measured fresh at the TDD gate, 2026-09-16, on `feature/SBDEV-1512-…` @ `4bef7e77`: surefire runs `6634` tests with `0` failures, `0` errors, `1` skipped.** ⚠ The figure previously recorded here — *"26 red / 132 skipped, `mvn verify` aborts before the IT lane"* — was **stale and wrong in the dangerous direction**: an implementer comparing against 26 expected reds would wave through 26 genuine regressions. `develop` is green (it has been since SBDEV-3089 cleared both reds), so **any** surefire failure is a signal, not a baseline. Re-measure rather than quoting this number; the total moves with every merge and only the failure count is meaningful. At gate time the only failing class was the gate's own `DamagedReturnApiSurfaceContractUnitTest` (2 expected reds); one independent review lane with a report on disk |
| 2 | **`v2/oms-laravel-api`** | `feature/SBDEV-1512-send-damaged-quantity` | `develop` | **MERGED 2026-09-17 — `5955e50b`, PR #567**, after #367, as constraint 1a required. Commits `efddf6d4` + `1655cb7c`. 6 tests, all mutation-proven; one independent review lane, four findings fixed. Unit suite 4149/499/48 against a measured HEAD baseline of 4143/500/47. ⛔ **Gated on Phase 1 reaching `wms2-api` `develop` first — see constraint 1a; merging out of order is worse than the bug.** |
| ~~2a~~ | ~~`v1/wms-api`~~ | — | — | **WITHDRAWN pending an answer to OQ-8.** It existed to prove WMS v1 tolerates the new key. Now that the sender is the **v2** OMS, that only matters if some client runs **OMS v2 against WMS v1**. If none does, WMS v1 never sees the field and the row is dead. |
| ~~3~~ | ~~`v1/qa-ui`~~ | — | — | **OUT OF SCOPE — the v2 UI does not have this defect.** Verified by reading `siteboss-frontend/apps/qa`: the disposition lives in React state that the submit handler reads directly, so the Vue `@change`-only path does not exist. Defect A is v1-only. |
| ~~4~~ | ~~`v1/qa-ui` + `v1/qa-api`~~ | — | — | **OUT OF SCOPE — same.** v2 uses structured error bars with i18n keys and branches on the re-fetched record, not a parsed error string; no `processApiErrors` exists in the monorepo. |

**Total ~4.5 days of implementation** across three repos, excluding review lanes and the two open
questions (OQ-3 and OQ-7) that need a database this session cannot reach. Estimates are for a
developer who has read §3; rev1 carried none, which `wms-tdd-gate` and any scheduling conversation
both need.

### ⚠ REPO-MAP CORRECTION — 2026-09-16 (Nam)

**QA is part of the OMS, and the QA repos split by OMS version.** This plan was written against the
wrong ones for Phases 2–4.

| QA surface | OMS v1 | OMS v2 |
|---|---|---|
| UI | `v1/qa-ui` (Nuxt 2 / Vue 2) | **`v2/siteboss-frontend` → `apps/qa`** — reached via the **Application Switcher** icon → *QA Manager*. Returns live in `apps/qa/src/containers/Returns/` |
| Backend | `v1/qa-api` (Python Flask) | **`v2/oms-laravel-api`** — `routes/legacy-qa.php` (base `/old_code/qa/v1`), `app/Services/Qa/` |

⚠ **`v2/omsv2-UI` is NOT the OMS v2 UI** — it is a Lovable prototype (`omsv2.lovable.app`), `main`
stale since 2026-05-11, with no QA surface in its entire history. An earlier revision of this
correction named it as the v2 target; that was wrong and is withdrawn. The real UI is
`v2/siteboss-frontend`, a React 19 / Vite 7 / MUI v7 monorepo (`apps/`: admin cms owl pos qa shared
siteboss website). Two traps there: **`main` is the DEVELOPMENT branch** (`main` → `qa` →
`production`, no `develop`), and the root `npm test` is a stub that exits 1 — tests are **Cypress
component specs** at `apps/**/src/**/*.cy.jsx`.

`v1/qa-api` and `v1/qa-ui` are **OMS v1 only** — not shared infrastructure. The `v1/` prefix made
them look like "the QA station, which happens to live under v1", and this plan built a deploy-order
constraint on that misreading. Combined with the standing *v1 is reference-only, v2 is the only
target* rule, they are off-limits for new work.

**What actually changes:**

- **Phase 2 moves to `v2/oms-laravel-api`.** The v2 counterpart of `qa-api`'s
  `build_wms_create_advice_request` is
  **`app/Services/Qa/QaReturnService.php::buildReturnAdvicePositions`**. It reaches the WMS the same
  way (`WmsApiService` → `PUT {host}/rest/advice/create`) and **carries the identical defect**,
  verified 2026-09-16: it builds positions from an `$undamagedByItem` map only, skips lines with
  `if ($qty <= 0) continue;`, and emits `amount_of_bottles` with no damaged field anywhere. So the
  fix design in §3 survives the move intact; only the language and the file change.
  *(Corroboration: SBDEV-2778's §10 row 10 already had this right — "v1's OMS caller is the legacy
  `qa-api`, not `QaReturnService`". This plan simply did not.)*
- **Phases 3 and 4 have no v2 counterpart — because the v2 UI does not have the defects.** This is a
  stronger and better-grounded statement than the previous revision's "no v2 target exists", which
  was merely a failure to locate the repo. The v2 QA UI was found and **read**:

  - **Defect A cannot occur in v2.** `apps/qa/src/containers/Returns/ManageReturns/ManageReturns.jsx`
    holds the disposition in React state (`const [disposition, setDisposition] = useState('')`), the
    preference effect calls `setDisposition(pref.disposition_id)`, and `handleManage` reads **that
    same state** (`parseInt(disposition, 10)`). There is no parent/child hand-off for a programmatic
    write to fall through — the Vue 2 `@change`-only notification path simply does not exist here.
    (It also already implements this plan's own Alternative E: `receive_now` follows the
    disposition's `advises_wms` flag, "never a hard-coded id (SBDEV-2689)".)
  - **Defect C has no analogue in v2.** `useReturns.jsx` surfaces failures through structured error
    bars with i18n keys (`setStepStatus({ message: 'qa:returns.detailError', severity: 'error' })`)
    and explicitly "branch[es] on the record itself (re-fetched detail), not a parsed English error
    string". No `processApiErrors` exists anywhere in the monorepo.

  They are real **v1** defects. Under the v1-is-reference-only rule they are out of scope here.

- **⭐ The v2 UI is already correct about the damaged quantity — the loss is entirely in the Laravel
  backend.** `ManageReturns.handleManage` already submits, per item,
  `{item_id, qty_undamaged, qty_damaged, qty_missing}`. So `qty_damaged` reaches
  `oms-laravel-api` intact and is dropped by `buildReturnAdvicePositions`. **That single method is
  the whole of the remaining v2 work**, which collapses this ticket's v2 scope to two phases:
  Phase 1 (done, PR #367) and Phase 2.
- **Phase 2a is withdrawn pending OQ-8** (below).

**The claim this correction kills:** rev1–rev8 asserted, as deploy-order constraint 1, that
"`qa-api` is **shared** across clients and routes by `wms_url` per facility, so Phase 2 ships into
**live v1 production traffic** on the day it deploys." That is **false** and it inverted the
ticket's delivery story — it made the QA half look like the part that reaches ShipItEZ immediately.
It does not. The v2 OMS change reaches a client at their **v2 cutover**, exactly like the WMS half.

**Deploy-order constraints, restated because they are the risky part:**

1. Phase 2 now ships in `v2/oms-laravel-api` and reaches a client only when that client is on OMS v2.
   It does **not** touch live OMS v1 traffic, because OMS v1's sender (`qa-api`) is a different
   codebase this ticket no longer modifies.

1a. ⛔ **PHASE 2 MUST NOT MERGE BEFORE PHASE 1 IS ON `wms2-api` `develop`. This is the single
    highest-risk item in the ticket, and shipping it out of order is WORSE THAN THE BUG.**

    Raised by the Phase 2 review lane 2026-09-16, which measured it rather than inferring it: a
    sweep of **all 291 remote refs** of `wms2-api` finds `amount_of_bottles_damaged` on **exactly
    one** — the unmerged `origin/feature/SBDEV-1512-receive-damaged-from-returns`. (Positive control
    in the same loop: `amount_of_bottles` hits 291/291, so the 1 is real and not a broken scan.)
    `origin/develop` still carries `if (position.getAmountOfBottles() < 1) throw
    FIELD_MALFORMED_FORMAT`.

    Consequences of merging Phase 2 first, both worse than the current silent loss:

    - **On a v2 tenant with auto-receive ON:** an all-damaged return now sends
      `amount_of_bottles: 0`. `resolveRefs` rejects it, the WMS 400s the whole advice,
      `sendReturnRestockAdvice` throws, and the manage transaction rolls back — **the operator
      cannot complete the return at all.** Today that path merely logs a warning and returns
      `skipped`.
    - **On WMS v1, or any v2 tenant with auto-receive OFF** (where `resolveRefs` never runs): the
      zero-quantity position is **silently accepted**, burning `externalid = RETURN{parcel_id}` —
      and this service's own `ENTITY_ALREADY_EXITS` handler then blocks every retry for that parcel
      **permanently**.

    `createReturnAdvice` has **no version gating** (1 unrelated `wms_version` hit against 172
    control files), so there is no runtime guard that makes the order safe. The ordering is the
    guard.
2. Merging to `wms2-api` `develop` **is** a dev deploy and **runs Flyway against every tenant DB on
   boot**. Rev1 said this branch adds no migration; under D6 it adds one, so the Flyway run is **not**
   a no-op. Before merging: re-run the all-remote-branch collision sweep (§5.1 row 1 — a sweep cannot
   see a branch pushed after it ran), confirm no tenant is stalled at an earlier version from
   ownership drift, and note that a DB with no `flyway_schema_history` is **skipped**, not migrated.
   **ShipItEZ is not an instance of that** — both their v2 tenant DBs are at `V2.2.30` with zero
   failures as of 2026-09-15 (§5.1 row 1b). M11 verifies per tenant rather than assuming either way.
3. Only ever merge to `develop`. `release` and `main` are DevOps-owned.
4. ShipItEZ gets the WMS half at their **v2 cutover**, not at merge. Do not report this ticket as
   "fixed for ShipItEZ in production" — report it as "capability shipped to v2; reaches ShipItEZ at
   cutover; QA-side defects A and C reach them immediately."
5. Phases 3 and 4 have **no dependency** on 1 or 2 and deliver client-visible value first. If time is
   short, Phase 3 is the highest-value single change in this document. **One coupling to state,
   though:** Phase 3 is the *volume amplifier* for the defect Phases 1–2 fix. Making the disposition
   select work means restock actually fires for every client whose `ship_return_management` is
   pre-set, so shipping Phase 3 first **increases the number of returns flowing through the
   damage-losing path** until Phase 2 lands. That does not make Phase 3 wrong — the operator's intent
   was restock either way, and today those returns produce nothing at all — but "ship it first" and
   "it increases exposure to the loss in the interim" are both true and the second was unstated in
   rev1.

**Post-rollout verification (first damaged return on UAT):**

```sql
-- the primary grade: the lock, not the location
SELECT su.id, su.amount, su.entity_lock, l.name AS location
FROM   stockunit su
JOIN   unitload ul ON ul.id = su.unitload_id
LEFT   JOIN location l ON l.id = ul.storagelocation_id
WHERE  su.created >= now() - interval '1 hour'
ORDER  BY su.id;

-- the transaction-report axis
SELECT activitycode, type, count(*) FROM stockrecord
WHERE created >= now() - interval '1 hour' GROUP BY 1,2;
```

---

## 9. Alternatives Considered

### Alternative A — receive the damaged portion straight into `Damaged` from `ReceivingService`

Teach `receiveGoods` (or a sibling) to place a unit load directly at the `Damaged` location with
`entity_lock = 103`, skipping the receive-then-move round trip.

**Pros:** one unit load per line instead of two; one label with a correct quantity; no window
between "received unlocked" and "locked damaged".

**Rejected, for four reasons:**

1. It writes `entity_lock = 103` from a **fourth** site. Today there are exactly three sites naming
   the constant (method: `git grep` for the constant name plus a second grep for the literal `103`;
   blind spots: a native-SQL `UPDATE`, and the **propagating** write
   `stockUnitDest.setEntityLock(stockUnit.getEntityLock())` in `StockunitService`, which can carry
   `103` forward without naming it — §1.2). Every one of those three is an operator-initiated move.
   Adding a receive-time writer means the invariant "damaged-ness is created by a move" no longer
   holds, and every future audit of damaged stock has one more path to enumerate.
2. It would **not** write a `stockrecord` with `activitycode = 'DAMAGED'` unless that were
   reimplemented too. `transaction_detail` is a union of per-`activitycode` arms, so with no
   `DAMAGED` record there is simply **no damaged row to produce** — the return appears only under
   its `RETURN` arm and `damaged` stays 0. Reuse gets that axis for free (§3.10).
3. `PutawayDestinationResolver` routes by item / merchant / warehouse config and `Damaged` is never
   a candidate destination; the placement gate, the pick-face divert and `requireCompatible` would
   all need a bypass. The `Damaged` location's `type_id` and `area_id` **differ across tenants**
   (6/3/0 vs 50184/50053/50100), and `LocationArea.useforpicking` feeds that resolver — so the
   bypass would need per-tenant validation that the reuse path does not.
4. `moveStockToNewDamagedContainer` holds a reviewed deadlock-ordering guard
   (`findByIdForUpdate(damagedLocation.getId())` first) from SBDEV-3086. A parallel implementation
   would have to re-derive it, and a second lock-acquisition order on the same row is how deadlocks
   are born.

### Alternative B — recover the created stock unit by re-querying `goodsreceiptposition`

Leave `receiveGoods` returning `void` and, after it commits, call the existing
`goodsreceiptpositionRepository.findByAdvicepositionId(advicePositionId)` to reach
`getStockunitId()`.

**Pros:** no signature change at all; the repository method already exists.

**Rejected:** the query returns a `List`, and an advice position can legitimately carry **more than
one** goods-receipt position — that is exactly what happens when a position is dock-received in
several passes. On the auto-receive path the advice was created milliseconds earlier so the list
should hold one element, but "should hold one" is an invariant that lives nowhere in the schema and
that a future partial-receive feature would silently break — at which point this code would damage
an arbitrary unit load with no test failing. Returning the ids the call itself created is
**deterministic by construction**, and its cost is a source-compatible change to a method with two
call sites. Where a design can be right by construction or right by invariant, prefer construction.

### Alternative C — split at receive time via `amountBottlesPerCase`

Call `receiveGoods(..., amountBottles = total, amountBottlesPerCase = undamaged, amountCases = 1,
...)` so the existing `while (amountBottles > 0)` loop mints two unit loads — good and damaged —
each with a correct label, then lock only the second.

**Pros:** two correctly-quantified labels; no split inside `setLockDamaged`.

**Rejected:** (a) it prints a label for the damaged portion, which D1 excludes; (b) `setLockDamaged`
would still be needed on the second stock unit, and it **always mints a new `Box` unit load**, so
the unit load `receiveGoods` just created for the damaged chunk would be emptied and a third one
created — worse, not better; (c) **it cannot receive a fully-damaged line at all.** With
`undamaged = 0` the call passes `amountBottlesPerCase = 0`, and `receiveGoods` rejects that
~170 lines before the loop:
`if (amountBottlesPerCase < 1) { throw new BusinessException("argumentMustBeGreaterZero",
"amountBottlesPerCase", amountBottlesPerCase); }`. The position throws, the advice returns `PARTIAL`
and stays `OPEN`, and C would need a special case for the exact shape OQ-2 exists to eventually
support. The chosen design handles that shape with no special case — `setLockDamaged` moves the
whole stock unit when `damagedAmount == amount` and simply does not split.

> *(Rev1 gave reason (c) as "`amountBottles -= 0` **never terminates** — an infinite loop in a
> `@Transactional` method", and called it decisive. **That was false and is withdrawn:** the guard
> above makes the loop unreachable, so the case throws cleanly. The replacement above is the same
> guard read correctly — it is a hard failure on a shape this feature must eventually accept, not a
> hang. Recorded rather than quietly swapped, because a rejection rationale the code contradicts
> makes §9 read as alternatives erected to be knocked down.)*

### Alternative D — lock-only: set `entity_lock = 103` on the received stock unit, move nothing

The cheapest possible design. Receive as today, then a single
`stockunit.setEntityLock(QUALITY_FAULT)` + save. No move to `Damaged`, no split into a second unit
load, no `stockrecord`, no second OMS message.

**Pros:** the smallest diff in this document; it satisfies `stock_view.damaged` and
`InventoryRecord.damage`, which are keyed purely on `entity_lock = 103` — i.e. it would make the
client's damaged-inventory report correct, which is the loudest symptom.

**Rejected, and this rejection is the reason D1 exists:**

1. **It misses `transaction_detail.damaged` entirely.** That surface is a union of per-`activitycode`
   arms; with no `DAMAGED`/`STOCK_CREATED` `stockrecord` there is no damaged row to produce, so the
   transaction report keeps reading `damaged = 0` forever. (§3.10; the arm-enumeration blind spot is
   stated there and closed by M9.)
2. **It misses the OMS wire.** OMS would still be told the units are `normal`, so WMS and OMS would
   disagree about the same bottles — the one outcome D5 exists to prevent.
3. **It leaves damaged and good stock in one unit load at a pickable location.** `stock_view` counts
   `su.entity_lock = 103 OR ul.entity_lock = 103`, so a *partial* lock on one stock unit inside a
   shared unit load is representable — but the physical bottles stay mixed on the same pallet at the
   putaway destination, which is precisely what the ticket asks to stop ("placed in the Damage
   location").
4. It writes `103` from a new site without the `Damaged`-location `findByIdForUpdate` ordering, i.e.
   it inherits Alternative A's objection 1 without Alternative A's benefit.

**The general lesson, and why §1.3 leads with it:** a design graded only against the surface the
client named would have passed here. Three of the four surfaces disagree about what "damaged"
means, so the design was selected against the *set*, not against the complaint.

### Alternative E — drive the disposition branch off `advises_wms` instead of the hard-coded id 2

`v2/oms-laravel-api database/schema/tenant-seed-data.sql` carries an **`advises_wms`** column on the
disposition lookup (`return_mgmt_lut`), added by a migration whose own docblock says it exists
*"instead of keying it off the hard-coded id 2"* and warns that keying off the id *"would wrongly
flag an unrelated disposition on any tenant whose auto-increment no longer lines up with the restock
row"*. The four values are 1 Manually Manage / 2 **Restock Inventory** / 3 Forward to Address /
4 Destroy Product. Both `qa-api` (`if disposition_id == 2 and receive_now in true_values:`) and
`qa-ui` (`if (dataObject.disposition_id === 2)`) hard-code the id today.

**Pros:** removes a hazard the OMS team has already identified and paid to fix on their side; makes
the WMS branch correct on any tenant whose auto-increment has drifted.

**Not adopted for Defect A, deliberately.** Defect A is a ~3-line UI emit fix that must stay
**independently shippable** — it is the highest client-visible value in this document and the only
change that restores restock for an operator who never touches the dropdown. Coupling it to a
cross-repo lookup change would put a same-day fix behind an OMS schema dependency that the v1 tenant
schemas may not even carry. Recorded as the forward-looking option: when `qa-api` next touches this
branch, read `advises_wms` rather than comparing to `2`. Blind spot worth stating: the `advises_wms`
evidence is the **v2** OMS baseline and is not proof of what exists in ShipItEZ's live **v1** tenant
schema — which is the same caveat that makes it wrong to depend on it now.

---

## 10. Open Questions / Resolved Decisions

### Resolved — Nam, 2026-09-15. Do not re-open.

| id | Decision | Where it lands |
|---|---|---|
| **D1** | Receive the **full** quantity, then apply **both** `entity_lock = 103` and the move to `Damaged` by reusing `StockunitService.setLockDamaged`. No UL label for the damaged portion. | §3.2, §3.3, §3.6 |
| **D2** | The QA→WMS contract change is **additive and unconditional** — qa-api always sends the new per-position damaged quantity; v2 consumes it, v1 ignores it. `v1/wms-api` is **not** being fixed. | §3.1, §3.7, §5.3 |
| **D3** | Physical outcome is receive-then-split/move: two unit loads per mixed line, label on the good one only. | §3.3 |
| **D4** | The `/rest/advice/create` `permitAll()` plus service-layer-ungated `setLockDamaged` exposure is **knowingly accepted**. | below |
| **D5** *(superseded by D8, then **REINSTATED** — see below)* | OMS gets **two** `StockChangeDto` messages (receive `normal = +N`, then damage `normal = 0 / damaged = +N`), matching what the manual damage flow already emits. No DTO change. **Net-correct**, because `normal` is a gross physical delta the OMS nets the buckets out of. | §3.3, §3.11, §6, I5 |
| **D8** | ~~Fix three WMS `getStockChangeDTO` sites to send `normal = −N`, with two purpose-shaped factories and a rail.~~ **WITHDRAWN 2026-09-15 — do not implement.** | §3.11.2 |

> **The D5 → D8 → D5 reversal, recorded in full because a decision log that hides a reversal is worse
> than one that never moved.**
>
> **D5 original:** two messages, net-correct. **Superseded by D8** on E7, which found today's
> `oms-laravel-api` adds each bucket independently and concluded three WMS sites were wrong.
> **D8 withdrawn** on E8, which measured the producer instead of reading the consumer: 173 occurrences
> of `normal:0, damaged:+N` on live v1 production and **0** of `normal:−N, damaged:+N`, spanning four
> years, with a positive control proving the matcher finds negative `normal` 1 634 times elsewhere.
> `normal` is a **gross** delta; the WMS has been right since 2022; the regression is
> `oms-laravel-api` `dd17b84f`. **D5 is reinstated in its original form** — for the reason it was
> dismissed.
>
> **What was actually wrong in each step, since that is the reusable part.** D5's rev1 justification
> was weak even though its conclusion was right: it verified the *shape* of the OMS contract and
> treated that as verifying the *arithmetic*. E7 then supplied arithmetic — from the consumer's code
> comment, written by the change that broke it, describing a convention that had never existed. The
> fix for both is the same and it is in §3.11.4: **a claim about what another system does is
> evidence only when it comes from that system's traffic, data or behaviour — never from its prose.**
| **D6-A** | **`notifiedamount` becomes `undamaged + damaged`.** A one-line change to an **existing** column — **not a migration**. Removes the accidental reliance on `setAllowoverdelivery(true)` being set ~200 lines earlier, keeps E3's `goodsreceiptposition.amount == notifiedamount` invariant intact, and makes the receiving screen's `orderedbottles` show what physically arrived. | §3.2, §0 row 11, §4 row 1b, §6, T1.13, T1.17, I1 |
| **D6-B** | **Persist the damaged quantity and whether it was applied** — nullable `adviceposition.notifieddamagedamount` **and `damageappliedat`**, both added by a single `ALTER` in the `V2.2.32` Flyway file, plus two entity fields. **KEPT and extended to two columns (Nam, 2026-09-15)** after the D6 review lane found its stated justification broken. | §3.2, §0 rows 11a/13, §4 rows 0/1a, §5.1 rows 1/1a, §7.4 row 8, §8 constraint 2, T1.19 |

> **Why D6 is split, and why Half B survived a review that found its justification inert.**
> The two halves were decided together and are **scored separately**: A is a one-line change to a
> column that already exists; B is a new column and a Flyway run against every tenant. Only B carries
> the migration, so only B was ever the lever for "make Phase 1 smaller".
>
> §3.2 originally justified B *solely* as recovery data — and the D6 lane showed the recovery query
> did not work (H1), while nothing else in the codebase reads the column at all. On that
> justification alone B would not have survived. **The broken worklist was a symptom of a weak
> justification, not a reason to drop the column**, and the deciding argument is the stronger one the
> lane supplied:
>
> > Once `notifiedamount` becomes the total, **nothing in the WMS records how much of it was
> > damaged.** After the fact you cannot distinguish a mixed line from a pure one — in any failure
> > state, or in any audit, ever.
>
> That is permanent, unrecoverable loss of precisely the quantity this ticket exists to stop losing,
> for the sake of two nullable columns on a 2.8 MB table that every active tenant already owns. A
> worklist is one *use* of the record; the record is the point. Dropping B and keeping A was
> defensible and was explicitly considered — it is recorded here as declined, not as unexamined.
>
> **Why B ended up as two columns.** The first column alone makes the worklist *approximate*: with no
> FK from the damaged stock unit back to the advice position (§3.2), "was this applied?" can only be
> inferred, and every inference had a named confounder. `damageappliedat` answers it directly. It is
> the **same** `ALTER`, the same Flyway run, the same ownership precondition and the same
> catalog-only non-rewrite — **the cost is conceptual, not operational** — and Nam took it because an
> approximate worklist loses the same information one layer up, which is the reason B was kept at all.
| **D7** | **Make `DAMAGE_FAILED` reach a human** — `send_wms_create_advice` inspects `data.get('warning')` on a 200 and surfaces it to the operator. Same function Phase 2 already edits. | §3.4, §5.3, §4 row 12, T2.5 |

**Why D6 was taken, in one paragraph, because it reverses rev1.** Both review lanes converged
independently on the same root defect: the damaged quantity was persisted nowhere, so **every**
failure path lost it irrecoverably — `PARTIAL` dropped it silently for positions that had already
received (turning a reporting gap into the quality escape §3.1 uses to reject W3), `DAMAGE_FAILED`
named a SKU with no quantity, and the documented manual recovery needed a number that existed only
in the OMS MySQL. One nullable column dissolves all of it, and it additionally removes the
`setAllowoverdelivery(true)` accident that rev1's `notifiedamount` handling depended on without
noticing. The cost is one Flyway migration and the operational weight in §5.1 row 1a.

**D4, recorded with its reasoning so a review lane does not re-raise it as a blocker.**
`setLockDamaged` carries no `@PreAuthorize` and no `@RequiresFunction` — the
`WEB_UI_ACTION_ADJUST_LOCK_DAMAGED` gate lives on the two `StockUnitController` handlers only — and
it never reads the `Principal` it is passed. `/rest/advice/create` is `permitAll()` with the tenant
taken from an unauthenticated header. Wiring the two together therefore lets an unauthenticated
caller reach a capability the UI gates. **This is accepted**, per the 2026-08-27 decision that
`/rest/**` is an internal WMS↔OMS surface with JWT deferred: it is not a live external exposure, and
the incremental capability granted is bounded — the caller can only damage stock it has just caused
to be received on an advice it created. It is **not** a new authorization hole in a different sense
than the one already accepted for `/rest/**`. If the `/rest/**` JWT decision is revisited, this call
site is in scope for that work and should be listed there.

### Open — needs an answer, with the blast radius of each

**OQ-1 — What is the true exposure?** `sum(quantity_damaged)` is only obtainable from the OMS/QA
MySQL, for which there is **no MCP server in this session**. Run against the ShipItEZ QA schema
(the unit-test fixture names `om1_shipitez`, which is the strongest in-repo hint — **confirm before
running**):

```sql
SELECT count(DISTINCT rt.parcel_id) AS returns_with_damage,
       sum(rti.quantity_damaged)    AS units_never_received,
       min(rt.manage_date)          AS first_seen,
       max(rt.manage_date)          AS last_seen
FROM   return_item rti
JOIN   return_ rt ON rt.parcel_id = <join per flask_app/models.py rti_/rt_ definitions>
WHERE  rti.quantity_damaged > 0;
```

The exact table and column identifiers **must be read from `flask_app/models.py`** (`rti_`, `rt_`),
not taken from this snippet. Blocks nothing; it sizes the ticket.

**OQ-2 — The fully-damaged line is still dropped.** Under W1 a line with `qty_undamaged == 0` is
not emitted, so a 100 %-damaged line remains invisible to the WMS. Measured floor: 1 of 1037 advices
is zero-position on live `wh01_shipitez`; the line-level count needs OQ-1's query. **The v2 side is
already built for it** (§3.1 relaxes `undamaged >= 1` to `total >= 1`, and I2 tests the shape), so
closing this is a **one-line predicate flip in qa-api** the moment every facility that `qa-api`
serves is on v2. Doing it sooner requires either a per-facility opt-in in `wms_url_lut` (which
touches D2's "unconditional") or accepting W2's unrecoverable-parcel failure on v1 (which is not
acceptable). **Recommendation: leave it open, revisit at ShipItEZ cutover.**

**OQ-8 — ✅ ANSWERED 2026-09-17: NO. No client runs OMS v2 against WMS v1.**

Nam, 2026-09-17. **The environments are version-matched, not mixed:**

| Environment | OMS | WMS | Clients |
|---|---|---|---|
| UAT | v2, multi-tenant | **v2**, one app set (api + web UI + mobile UI) per client's warehouses | WineCo, ShipItEZ, Hydra |
| PRD | v1 for WineCo/ShipItEZ | **v1** for WineCo/ShipItEZ; v2 for Hydra | — |

Verified: the WMS v2 **UAT** landlord holds `hydra`, `shipitez` (**2** `tenant_db_configuration` rows,
their two warehouses) and `wineco`; the WMS v2 **PRD** landlord holds **only** `hydra`. ShipItEZ UAT
is a real v2 WMS at `V2.2.30`, 0 failed, last applied 2026-09-15. ShipItEZ and WineCo cut over to v2
in a few weeks.

⚠ **A WRONG ANSWER I PUBLISHED AND WITHDREW — recorded because the reasoning error is the reusable
part.** For roughly one working session this row read *"YES — ShipItEZ runs OMS v2 against WMS v1"*,
and I escalated PR #567's title and body around it. The inference came from `shipitez` appearing in
`oms-laravel-api`'s `TenantSeeder` plus several operational code references
(`CarrierFacilityLocationService`, `ReportAccessService`, `WidgetService`, SBDEV-2661/2663). **All of
those are true and none of them establish the claim:** the seeder entry is
`'database' => 'dev_om1_shipitez'` — a **dev** database — and a code reference names a tenant, never
an environment. I had the right evidence for *"ShipItEZ is an OMS v2 tenant somewhere"* and used it
for *"in production"*. The generalisation: **a tenant's existence in code or a seeder says nothing
about which environment runs it — only an environment's own registry does** (here, the per-environment
landlord `tenant` table, which answered it in one query).

Phase 2a stays **withdrawn**: WMS v1 never receives the new field, because the OMS that would send it
never talks to a WMS v1.

**Superseded question (kept for the record):****Superseded question (kept for the record):**

Phase 2a existed to prove, executably, that WMS v1 ignores the new `amount_of_bottles_damaged` key.
That mattered when the sender was believed to be a shared `qa-api`. Now that the sender is
**`oms-laravel-api`** (OMS v2), WMS v1 only ever sees the field if some client is on **OMS v2 with a
WMS v1 backend**. `WmsApiService` targets `{host}/rest/advice/create`, a route that exists in **both**
WMS versions and is chosen per facility, so the pairing is *possible* — this is not a theoretical
question, and it is not answerable from the code alone.

- **If yes** → reinstate Phase 2a. WMS v1 will receive the key and its tolerance must be pinned.
- **If no** → delete it. WMS v1 never sees the field and the row is dead weight.

⚠ **This also determines whether SBDEV-1512 reaches ShipItEZ at all in its current form.** §1.4
records that ShipItEZ runs **WMS v1** in production. If they are also on **OMS v1**, then neither
half of this ticket touches them until *both* cut over, and the "QA-side defects reach them
immediately" story — already false for the repo-map reason above — is doubly wrong. **Confirm which
OMS ShipItEZ runs before reporting any client-facing benefit from this ticket.**

**OQ-3 — Does ShipItEZ's client row set `ship_return_management` to the restock disposition?**
**Blocks Defect A only** — not the damaged-receive work, and not Phases 1, 2 or 4.

⚠ **The mechanism is the opposite of a "maybe it does not apply", and rev1/rev2 framed it wrongly as
"the select renders empty".** `data()` returns `chosenDisposition: 1` and `mounted()` overwrites it
only `if (preferred_disposition)`, so:

| `client.ship_return_management` | what the operator sees | does Defect A bite? |
|---|---|---|
| unset, or resolving to `'No Preference'` | `chosenDisposition` stays **1** → the select displays **"Manually Manage"** | **No.** The operator sees a visibly wrong option, clicks it, `change` fires, the parent is updated correctly. |
| set to **Restock Inventory** | `chosenDisposition` is set to **2** programmatically, no `change` fires, the parent keeps **1** | **Yes.** The operator sees exactly the option they want and therefore does **not** touch it. |

So **the bug is worst precisely for the clients configured the way the feature intends**, and a
"yes" to OQ-3 raises Defect A's priority rather than confirming a niche case. It also means the
defect is invisible to anyone testing with an unconfigured client. Needs an OMS MySQL query. **Now reachable without guessing at table names:** `oms-laravel-api` carries the models directly — `app/Models/ReturnMgmtLut.php` and the `client` table used by `QaReturnService` — so read the real names from there rather than from the qa-api sketch below. ⚠ **But OQ-3 only matters if Defect A is ever fixed, and Defect A is now out of scope** (no v2 target — see the repo-map correction in §8). Answer it only if v1 qa-ui work is separately authorised. Source the identifiers from qa-api's
`parcel_info_helper.py` `return_preference` join —
`func.COALESCE(rtml_.c.value, 'No Preference').label('return_preference')` joined
`ON rtml_.return_mgmt_lut_id == cl_.ship_return_management` — and read the **real table names from
`flask_app/models.py`, not from this sketch**:

```sql
SELECT c.client_id, c.client_code, c.ship_return_management,
       COALESCE(rml.value, 'No Preference') AS return_preference
FROM   client c
LEFT   JOIN return_mgmt_lut rml ON rml.return_mgmt_lut_id = c.ship_return_management;
```

A useful companion is the disposition mix of managed returns since 2026-04: if they are
overwhelmingly disposition 1 while the client's stated preference is Restock Inventory, Defect A is
confirmed from data rather than from a Vuetify source read.

**OQ-4 — Was `PRINT_CASE_LABEL` ever false on ShipItEZ?** It is `Boolean.parseBoolean`, default OFF,
measured `true` on `c1wh-shipitez-uat` with `modified = 2026-09-09` — six days before this survey.
`los_sysprop.modified` dates the **row**, not the value, so that timestamp does not prove the value
changed. This is the only switch on the restock path that produces exactly the reported symptom
(receipt succeeds, no label, no error anywhere). **Ask the client before attributing the "no UL"
half of the complaint to code.** Blocks nothing.

**OQ-5 — Does `wh02_shipitez` (NY) have a default RETURN printer and `PRINT_CASE_LABEL = true`?**
Only `wms1-shipitez1` = `wh01_shipitez` is registered here, so §3.4 of the QA evidence refutes the
printer and sysprop failure modes for **one of the two warehouses only**.

**OQ-6 — is the 500-position `FOR UPDATE` contention profile acceptable, or should damaged positions
be capped?** §7.3 row 8 accepts it on the grounds that a 500-position return is not a shape the QA
station produces (one parcel, one return) and that capping would reject a legitimate advice. The
cost if that reasoning is wrong is `DAMAGE_FAILED`s that degrade into manual recovery work, at a rate
nothing measures. **Recommendation: accept, and revisit if M10/M11 or production shows any
`damage_failed` counter movement.** Needs Nam's yes because it is an accepted risk, not a closed one.

**OQ-7 — does the OMS *decrement* `normal` when `damaged` rises, or treat them as independent
deltas?** §6 records the `StockChangeDto` risk as "None to the contract", and that is a claim about
**shape** — both call sites emit exactly the existing pair, which was verified. The **arithmetic** is
a different claim and does not follow from it: if OMS treats the two messages as independent
additions, every mixed return overstates sellable inventory by the damaged quantity, which is the
opposite of this ticket's goal. **Neither this plan nor any of the three evidence files contains an
`oms-laravel-api` read.** Before Phase 1 ships, read the `STOCK_UPDATE` handler in
`v2/oms-laravel-api` and confirm how `normal` and `damaged` compose; the manual damage flow already
emits this pair today, so the answer is observable in production data as well as in code. Blocks
nothing in the WMS, but it decides whether the feature achieves its purpose end to end.

**OQ-8 — OMS inventory drift: measured as zero to date, and the reason matters more than the number.**

The `oms-laravel-api` regression (`dd17b84f`, 2026-07-31) has produced **no measured drift**, because
**no v2 client has sent a damage message since it landed** — `wms2-hydra`, the only v2 PRD client,
holds 23 `STOCK_UPDATE` rows with **0** carrying a non-zero `damaged`, positive control passed. So
there is **no backfill to design**, and the earlier revision of this item — which costed a
per-tenant reconciliation — is withdrawn along with D8.

**Three limits on that zero, stated because it is a convenient answer:**

1. It rests on the **absence of defective messages**, not on a reconciliation. No MySQL MCP exists for
   the OMS tenant DBs in this session, so `product_inventory.quantity_on_hand` was never compared
   against WMS stock. "No cause observed" is weaker than "no effect measured".
2. The deployed `oms-laravel-api` build was not read. `dd17b84f` is on `main` with earliest tag
   `v2.0.76` (2026-08-04) — **tag ancestry, not a deploy confirmation.**
3. Four tenant DBs were read, not the fleet; `wineco` / `wsl` and the dev landlord's other tenants
   were not.

**And the zero is conditional on this ticket not shipping first** (§3.11.3, §5.1 row 4). Once mixed
returns flow, every one of them emits the mishandled shape.

One finding from the withdrawn work is worth keeping because it survives the reversal and bears on
the **OMS-side** fix: `applyInventoryQuantities` ends with `max(0, $newValue)`, so a negative delta
that would take a bucket below zero is **silently clamped**. If drift ever does need sizing, replaying
WMS-side deltas would **under-report** it — every clamped delta is information the log no longer
contains — so sizing is a reconciliation against current OMS values, not a query. That belongs to
whoever fixes `dd17b84f`, not to this ticket.

### Ranked follow-ups found during analysis

Per the ticket policy, a finding whose own tier is under T3 goes onto **this** ticket; a T3 finding
is proposed and Nam confirms. The withdrawn one-proposal cap does not apply — everything grounded is
listed.

⚠ **Rev1 titled this section "proposed, not filed" and then listed three sub-T3 findings under it,
contradicting the policy it had just quoted.** A finding recorded only in a plan dies when that plan
is archived. **FU-1, FU-2 and FU-4 are sub-T3 and were posted as a comment on SBDEV-1512 on
2026-09-15** (comment `90110270185076`), ranked FU-2 → FU-4 → FU-1 — FU-2 first because it is a live
HTTP 500 on the REGULAR advice path that burns `externalid` into an unrecoverable parcel.

**FU-5 was T3 and therefore proposed rather than filed; Nam confirmed it on 2026-09-15 and it is now
its own ticket** — https://app.clickup.com/t/868m5jmyc (Urgent). Verification on filing found it
wider than this table had recorded: **both** workflow files carry it (two credential blocks each,
four in total), and `git grep -c "secrets\." -- .github/workflows/` returns **0**, so that repo uses
GitHub Secrets nowhere. Exposure window opens at `1dcc05b`, 2025-03-24. No credential values are
reproduced here or in the ticket.

The table's "do first" column is the ranking Nam asked for; the ticket comment carries the same
ranking.

| id | Finding | Tier | Blast radius | Cost | Do first? |
|---|---|---|---|---|---|
| **FU-1** | Mixed-line case label overstates the good unit load by the damaged quantity (§3.6) | T2 | Every mixed damaged return, every tenant, once this ships | ~½ day (a `deferLabel` parameter on `receiveGoods`, touching the dock path) | **POSTED to SBDEV-1512.** Ranked 2nd — gate it on M4's measurement |
| **FU-2** | `create()`'s REGULAR branch NPEs on a missing `box_id`: `Optional<Boxtype> optionalBoxtype = null; if (StringUtils.isNotEmpty(...)) {...} ... optionalBoxtype.get();` — an HTTP 500 **after** `adviceRepository.save` committed, burning `externalid`. The RETURN path pre-empts it; **REGULAR is live.** | T1 | Any REGULAR advice submitted without `box_id` | **minutes, if taken in Phase 1** | **POSTED to SBDEV-1512, ranked 1st. ⚠ Fix it in Phase 1's own edit** — §5.2 says why: it is three lines from the code H2 changes, in the same loop, in the same file. |
| **FU-3** | qa-api's `service_log` writer returns **before** logging on HTTP 204, so the success case is unlogged — inconsistent with the QA-complete path, which does log its 204. An absent row cannot distinguish "succeeded", "never attempted" and "`CONTACT_EXTERNAL` false". | T1 | All forensic analysis of this flow, including OQ-1 and any measurement of Defect A's fix | ~1 hr | **In Phase 2 (§5.3.1)**, not deferred — the only instrument that can show the WMS branch is being taken, and it costs a few lines in a file Phase 2 already edits |
| **FU-4** | **The WMS URL lookup uses the wrong facility** — see the expanded finding below. | **T2** | Two-warehouse clients only — ShipItEZ is one | ~½ day of code, but needs a product decision first | **POSTED to SBDEV-1512.** Ranked jointly with FU-1 — ask Brent before coding |
| **FU-5** | **FILED as [qa-ui plaintext registry credentials](https://app.clickup.com/t/868m5jmyc)** (Urgent · Bug · Fulfillment Development Backlog) — plaintext container-registry credentials committed in `qa-ui`'s GitHub Actions workflows. **Both** workflow files carry them, **two blocks each, four in total** (measured: `git ls-tree` returns exactly two workflow files, `grep -c "^ *registry:"` returns 2 in each). `git grep -c "secrets\." -- .github/workflows/` returns **0** — no workflow in that repo uses GitHub Secrets at all, so this is the repo's **pattern**, not a single oversight. Exposed since **`1dcc05b`, 2025-03-24** — ~18 months. No credential values are reproduced here (nor in the ticket) — the finding is the committed pattern and its location, which is enough to act on. | **T3** | The registry account, plus any repo sharing the pattern | rotation + migrate all four blocks to `secrets.*` | **Filed and out of this ticket's scope.** No longer a proposal. |

#### FU-4 in full — `wms_url_lut` is keyed on the *fulfilling* facility, not the returning one

`wms_api.py`'s `get_wms_base_url(return_facility)` selects
`wms_url_lut.wms_url WHERE facility_code == return_facility`, and the UI supplies that argument as
`this.parcelInfo.fulfillment_facility_code` (`pages/manageReturn/_id.vue`) — **the facility that
fulfilled the order, not the facility the parcel physically came back to**.

**Why it belongs on this ticket's radar rather than in a footnote:** a parcel fulfilled in LA but
returned to NY is advised to the **LA** WMS, so under this plan the **damaged stock would be created
in the wrong warehouse** — a unit load at `Damaged` in a building where the bottles are not. The
damaged half makes the consequence worse than it is today, because today's wrong-warehouse receipt
at least produces pickable stock that a cycle count will eventually reconcile, whereas damaged stock
sits locked at `103` and is invisible to picking.

ShipItEZ has exactly two warehouses (NY = `wh02`, LA = `wh01` — note the inversion), so this is live
for the very client that raised the ticket. Note also that `send_wms_qa_complete_request` resolves
its target from a **different** source entirely — `parcel_info.wms_base_url` carried on the parcel
row — so the QA-complete path and the returns path **can disagree about which WMS a parcel belongs
to**, and nothing reconciles them.

**Deliberately not folded into any phase.** Fixing it means deciding which facility is authoritative
for a return, which is a product question for Brent, not a code question; and the two paths should
probably be unified rather than patched independently. It is recorded here with its own tier so it
is visible when Phase 2 ships, because Phase 2 is what makes the consequence damaging.

**Blind spot:** this is derived from a read of the two call sites and the lookup query; it is not
measured. `SELECT facility_code, wms_url FROM wms_url_lut;` on ShipItEZ's OMS schema, plus the
`facility_code` actually sent for a cross-warehouse return, would confirm it — and no MySQL MCP is
registered in this session.

---

## 11. Implementation Status — Phase 1 (`wms2-api`)

**Branch** `feature/SBDEV-1512-receive-damaged-from-returns`, in the per-ticket worktree
`.claude/worktrees/wms2-api/SBDEV-1512`, based on `origin/develop` @ `4bef7e77`.
**MERGED TO `develop` 2026-09-17 — merge commit `0e4c5a43`, PR #367.** Verified on develop: `V2.2.32__adviceposition_notified_damaged_amount.sql` present, `amountOfBottlesDamaged` present in `AdvicePositionDto`. ⚠ **Flyway now runs this migration against every tenant DB on next boot.** Rebased onto `origin/develop` @ `e113467b` before pushing; head is now `dd42914d`. ⚠ **NOT merged** — merging is a dev deploy and runs Flyway against every tenant DB on boot. Re-run the all-remote-branch collision sweep immediately before merge: it was clean at push time (only V2.2.30/V2.2.31 exist) but a sweep cannot see a branch pushed after it ran, which is exactly how V2.2.31 was lost the first time.

| # | SHA | What it does |
|---|---|---|
| 1 | `e8bcbbe3` | The wire field and the columns: `AdvicePositionDto.amountOfBottlesDamaged` (boxed `Integer`, `@JsonProperty("amount_of_bottles_damaged")`), `Adviceposition.notifieddamagedamount` + `damageappliedat`, and migration `V2.2.32` |
| 2 | `6bf54176` | Carries the damaged quantity through `resolveRefs` into the auto-receive plan — `ResolvedLine` and `AutoReceiveLine` widened, guards regraded onto the **total** |
| 3 | `17a9f062` | The behaviour itself: receive the full quantity, then `setLockDamaged` the damaged portion. `ReceivingService.receiveGoods` widened `void` → `List<Long>` so the created stock unit can be located |
| 4 | `5136ed87` | `I1` — a mixed return, end to end against real PostgreSQL, graded on `entity_lock = 103` |
| 5 | `89b444b2` | The five HIGH findings from three independent review lanes |
| 6 | `ebb6bb5f` | The three Mediums and eight Lows |
| 7 | `e01bce85` | Seven assertion gaps PIT found in the tests added by 5 and 6 |
| 8 | `fb307d90` | The §7 row gaps (T1.1-T1.4, T1.6, T1.7b, T1.9-T1.11, I2, I4) and the eight re-review findings |
| 9 | `dd42914d` | I5 — the two `StockChangeDto` payloads on the OMS wire, asserted on the serialized form |

**Suite:** `mvn -o clean verify` on `29af735f` — **surefire `6665` / 0 / 0 / 1 skipped, failsafe `424` / 0 / 0 / 31 pre-existing skips, BUILD SUCCESS**, against the §8 baseline of `6634 / 0 / 0 / 1` on `4bef7e77`. ⚠ Earlier revisions of this section quoted a surefire-only figure; **that number never graded the integration tests at all** — both touched ITs are excluded from surefire and run only in the failsafe lane. Grade this branch with `clean verify`, never `test`. Compare failures, never totals; the total moves with
every merge.

**Mutation:** PIT scoped to `AdviceRestController` and `ReturnAdviceAutoReceiveService`. Every
correctness line is killed. Four survivors are left **knowingly**, all in
`ReturnAdviceAutoReceiveService`: the two metric-counter increments and the M3 logging filter.
Nothing scrapes these metrics yet (see the standing note that a metric is not a working control), and
the log line is diagnostic — an assertion on either would pin a string rather than a behaviour. This
is recorded so a later reader does not infer the class is fully covered.

### What is NOT done

1. **Phases 2–4 are untouched** — `qa-api` still sends only the undamaged quantity, so nothing
   populates the new field in production. Phase 1 alone changes no observable behaviour for any
   client; it is the receiving half of a two-sided contract.
2. **[SBDEV-3366](https://app.clickup.com/t/868m5j9qr)** gates *correctness* at ShipItEZ cutover, not
   merge (§3.11.3). It is the item most likely to be forgotten, because this branch will look
   finished. Nam will take it once this ticket is done (2026-09-16).
2a. **[SBDEV-3382 — the all-damaged stockrecord gap](https://app.clickup.com/t/868m61q5j)** — filed 2026-09-16 at
   Nam's request, found by I2. Damaging a WHOLE stock unit writes no `DAMAGED`/`STOCK_CREATED`
   record, so `transaction_detail.damaged` reads 0 while `stock_view.damaged` is correct. **Live on
   2 of 2 tenants with damage history (11 units since 2020) through the MANUAL damage path, so it
   predates this ticket** — §3.1's relaxation simply adds a second route to it. Recommended fix is
   in `UnitloadService.moveStockToNewDamagedContainer` (damage-specific, no other caller affected),
   not in `transferStockToUnitLoad`. I2 currently asserts the buggy `ZERO`; the fix flips it to 4.
3. ~~**I5 is the one §7 row still open.**~~ **BUILT 2026-09-16** at Nam's request, as
   `mixedReturn_sendsReceiveThenDamageStockChange`. Both messages fire unconditionally for a RETURN:
   `ReceivingService`'s switch gates only the REGULAR branch behind
   `INBOUND_UPDATE_STOCK_IMMEDIATELY`, so no sysprop arrangement is needed and a tenant with that
   flag off still gets both.

   Asserted on the **serialized payload**, not on a mock interaction, because
   `SharedService.getStockChangeDTO` takes five consecutive positional `int`s —
   `(itemData, total, damaged, missing, onHold, transfer, …)` — mapped straight onto
   `normal/damaged/missing/on_hold/transfer`. Any swap among the five is type-correct, compiles, and
   is invisible to `verify(...).sendStockChangeMessage(anyList())`. All five buckets are asserted on
   both messages. `MessageService` is a `@MockitoSpyBean` (delegates, so the real notification still
   happens); Spring resets it after each test, so the `hasSize(2)` count cannot accumulate across the
   class.

   **Mutation-proven, both halves:** swapping `normal`/`damaged` on the damage message → red naming
   the swap; moving the receive quantity into the `missing` bucket → red naming the normal-stock
   assertion. ⚠ The first probe initially reported `EDIT-NOT-UNIQUE` rather than a verdict — the
   anchor missed a blank line, and `getStockChangeDTO(itemData, 0, damagedStock…)` appears **twice**
   in `StockunitService` (`setLockDamaged` at `:786` and a second damage path at `:609`). The
   uniqueness guard is what stopped a silently-unapplied patch reporting as a survivor. **That
   duplicate at `:609` is an unexercised sibling emitting the same payload shape — worth sweeping if
   [SBDEV-3382](https://app.clickup.com/t/868m61q5j) is picked up.**

   The load-bearing assertion for the OMS side is the damage message's `normal == 0` (not `-3`): the
   WMS reports damage as an addition to the damaged bucket and says nothing about normal. If that
   ever becomes `-3` the WMS half of the contract changed and
   [SBDEV-3366](https://app.clickup.com/t/868m5j9qr) must be re-read first.
4. **FU-2 was dropped from Phase 1** by Nam on 2026-09-16 and keeps its own ticket scope. (A lane
   read the implementation comment as an undocumented deviation from the plan — it is not; it
   records a decision.)

### The two independent lanes — what they found and what was done

Both wrote reports to `SBDEV-1512-evidence/`.

**Row-conformance lane** (`rowcheck-phase1.md`) — of 22 in-scope §7 rows: **3 BUILT, 7
COVERED-ELSEWHERE, 12 ABSENT**. It corrected the implementing context, which had suspected the
earlier name-matching sweep of undercounting: seven rows genuinely were built under unpredicted
names, but twelve were genuinely unpinned and **five survived a mutation of the exact behaviour
they were written to guard**. All twelve are now closed except I5 (above) and T1.19 (deferred — it
graded a recovery worklist that does not exist in `src/main`; see §7.1).

⚠ One lane claim **disproved**: it reported the SBDEV-1512 service tests executing inside the
`FollowUpRegression` nested class. The surefire **XML** shows all of them at top level and
`FollowUpRegression` holding exactly its own 1 test. The lane read surefire's *console* grouping,
which disagrees with the XML. Nothing to tidy — recorded because the console/XML disagreement will
mislead the next reader the same way.

**Re-review lane** (`rereview-fixes.md`) — **PASS-WITH-FINDINGS, no defect in `src/main`.** It
independently re-proved F1 (`break` → red) and F2 (pre-flight deleted → red) by mutation. Every
finding was in the test layer, and all are closed:

| # | Finding | Disposition |
|---|---|---|
| M-1 | the damage-failure test's `never().save()` was vacuous — `findById` unstubbed, so the stamp no-oped and `save` was unreachable either way | stub added; mutation-proven (stamping the *attempt* now reddens it) |
| M-2 | replacing `entity_lock = 103` with the constant dropped the only cross-check against `stock_view`, which **hardcodes 103** | fixed by grading `stock_view.damaged` **directly** — the surface the client reads — plus a constant pin |
| M-3 | `size() != 1` reverted to `isEmpty()` with the full suite green | parameterised test (empty list, two-id list); mutation-proven |
| L-1 | M3's `damage_outstanding_after_partial` counter had zero coverage | test added; counter is per-ADVICE, not per-position |
| L-2 | the `%N$s` positional fix survived reversion to bare `%Ns` | assertion replaced with the exact rendered string |
| L-3 | `verify(adviceRepository, never()).save(...)` structurally vacuous — the service never calls it | removed, with the reason recorded in place |
| L-4 | `stampDamageApplied`'s `rollbackFor` is inert | **DELIBERATE DEPARTURE — kept.** Spring does not roll back checked exceptions by default, so it is inert only for this body as written; the day a `BusinessException`-throwing call is added, its absence silently commits a half-done stamp. Reasoning recorded in the code so it is not re-raised |
| L-5 | a code comment asserted "rows with a negative value already exist in the estate" | **unsupported and removed.** The lane measured Hydra PRD + wsl-wineco UAT: 52,904 positions, 0 over cap, 0 negative. The guard is still right; the evidence sentence was fabricated |

Also raised by that lane and acted on: the "6650 green" reported after several commits **never
graded the integration tests at all** — both touched ITs are excluded from surefire. Phase 1 is now
verified with `mvn clean verify`, which runs both lanes.

### A measurement trap that produced a false red, recorded so it is not repeated

A mutation harness restored production files with `shutil.copy2`, which **preserves mtime**. Maven
then saw the sources as older than the mutant `.class` files, skipped recompilation, and a later
`mvn verify` (no `clean`) graded leftover mutant bytecode — three green tests reported as failures.
The source was clean the whole time. Restores must set mtime to now (`os.utime`) or the run must
`clean`. The KILLED verdicts taken *before* a restore are unaffected; any green taken *straight
after* one is worthless. This is the same family as the mutation-harness traps already on record.

### Doc drift this branch introduces — apply at merge, not before

These `sbdocs/` files describe **deployed** reality and are dated against `origin/develop`. Rewriting
them to describe an unmerged branch would make them wrong for as long as the PR is open, so this is a
merge-time task list, not a now task list.

| Doc | What drifts | Why |
|---|---|---|
| `3-Resources/workflows/wms2-receiving-putaway-workflow.md` | `receiveGoods` anchor `[line 320-614]` → the method now opens at **337**; the stock-change gate anchor `(line 578-594)` → `sendStockChangeMessage` is now at **615**. `ReceivingService` grew 765 → 788 lines | Every anchor below the insert point shifts. The 2026-08-29 pass found all 24 anchors in this file had drifted once already |
| ″ §7 `execute(plan)` row | The row says "per-position `receiveGoods`, each in its own tenant tx". There is now a **second loop** after it that applies damage, with its own failure mode (`Status.DAMAGE_FAILED`) that does not fail the receive | A reader planning a change to this flow would not know the second loop exists |
| ″ §4 signature | `receiveGoods` is documented as the owner of the physical receive; it now **returns** `List<Long>` (the created stock unit ids) rather than `void` | Callers can now depend on the return value; three `doNothing()` stubs already had to change |
| `3-Resources/architecture/wms2-state-machine-catalog.md` §4.8 | `Adviceposition` write sites gain `notifieddamagedamount` (controller) and `damageappliedat` (`ReturnAdviceAutoReceiveService.stampDamageApplied`) | The write-site inventory is the thing this section exists for |
| `3-Resources/data-dictionary/` entity map | `adviceposition` gains two columns via `V2.2.32` | Schema of record |

Not drifting, checked: `3-Resources/design/wms2-stockunit-design.md` references `receiveGoods` only as
an example caller of a `createStockUnit` overload, which is unchanged.

**Method and its blind spot:** derived by grepping `sbdocs/3-Resources/` and `sbdocs/2-Areas/` for
`adviceposition`, `notifiedamount`, `ReturnAdviceAutoReceive` and `receiveGoods`, then reading each
hit. It will miss any doc that describes this flow **without naming those four tokens** — prose
referring to "the return receive path" in other words would not surface. A full `verify-docs` pass at
merge is the instrument that closes that gap; this list is the cheap version.

---

## Completeness checklist

| Row | Status |
|---|---|
| §0 affected-sites enumeration, every row in/out with rationale and phase | ✓ §0, 18 rows, instrument and blind spots named |
| Problem statement with user-visible symptom | ✓ §1.1–§1.2 |
| DB verification performed and cited | ✓ frontmatter `db_verified_note`, E0–E5, plus **E6** (`notifiedamount` consumers, with a positive control) folded into §3.2 and §6; primary-grade queries in §8 |
| Root cause / current architecture traced to code | ✓ §2, all citations from `origin/develop` with quoted snippets |
| Design section, numbered, each with rationale + signature + config keys + data-model delta | ✓ §3.1–§3.10 |
| Evidence-file claims re-verified rather than inherited | ✓ §1.3 corrects `wms-damaged-capability.md` §6(b) (`transaction_detail` is a union of per-`activitycode` arms, so D1 does cover that surface); §3.7 closes the `AbstractWebServiceDto` blind spot the evidence lane left open. Both corrections carry their own blind spot and a manual row that closes it (M9, M5) |
| File change summary table | ✓ §4, 11 rows |
| §5.1 Prerequisites, all 8 rows, `N/A` justified | ✓ §5.1 |
| Phased plan with prereq ordering and independence stated | ✓ §5.2–§5.5, §8 |
| Backward compatibility table | ✓ §6 |
| Explicit "What Does NOT Change" | ✓ §6 |
| Named unit tests | ✓ §7.1, 27 rows (T1.1–T1.13 wms2-api · T2.1–T2.5 qa-api · T3.1–T3.3 + T4.1 qa-ui · T4.2 qa-api); the tables are the ACs — §7 preamble |
| Named integration tests | ✓ §7.2, 6 rows |
| 10-row horizontal scalability checklist | ✓ §7.3 |
| 8-row v2-only constraint checklist | ✓ §7.4 |
| Manual test plan table | ✓ §7.5, 11 rows (M10 locked lane, M11 Flyway-landed added in rev3) |
| Mutation-check requirement stated per assertion | ✓ §7 preamble (attributable kill + dominant-band fixture) |
| Verify script: present, or absence justified | ✓ §7.6 — none, with rationale |
| Rollout plan with branch names per phase | ✓ §8 |
| ≥2 alternatives with explicit rejection rationale | ✓ §9, five (A receive-direct, B re-query, C case-split, D lock-only, E `advises_wms`); C's decisive reason **withdrawn** and replaced with a true one |
| Decisions that turned out wrong are corrected in place, not annotated | ✓ §3.2's "no data-model delta" withdrawn; Alternative C's decisive reason withdrawn; §3.9's file attribution retargeted; §5.1's ShipItEZ-Flyway claim corrected |
| Cross-ticket dependency stated with its TYPE | ✓ §3.11.3 and §5.1 row 4 — blocked on [SBDEV-3366](https://app.clickup.com/t/868m5j9qr) for **correctness**, not delivery, with both halves spelled out so neither a premature ship nor a needless stall follows from reading one of them |
| Every reviewer High dispositioned in the text, not just acknowledged | ✓ D6 lane: H1 (worklist now `damageappliedat IS NULL` — deterministic; **and the lane's own suggested join shown not to reach the damaged stock unit on a mixed line, recorded so it is not re-proposed**), H2 (explicit coalescing + T1.17), H3 (validation moved to the unconditional save loop + T1.18); M1/M2/M4 and L1–L5 all folded |
| Reviewer *fixes* checked, not only reviewer *findings* | ✓ §3.2 — the D6 lane's H1 finding was acted on, and its proposed replacement join was independently disproved against `transferStockToUnitLoad` before being rejected. Acting on a finding does not license adopting its fix unchecked |
| Reversals recorded rather than hidden | ✓ §10's D5 → D8 → D5 entry keeps the full path, and §3.11 keeps the withdrawn D8 design with the evidence that reversed it, so nobody re-derives E7 |
| Test-design failure modes named where the next author reads them | ✓ §7 preamble — T1.10 (vacuous `never()`) and I5 (right value, transcribed provenance, which is why a contrary argument could flip it), plus the observation that E7 failed the same way one layer up: two instances, one root — an artefact copied where it should have been checked |
| D1–D5 recorded as resolved | ✓ §10 |
| D4 accepted risk recorded with reasoning | ✓ §10 |
| ShipItEZ open question recorded | ✓ §10 OQ-3, scoped to Defect A only |
| Findings ranked, with blast radius and cost, none suppressed | ✓ §10 FU-1…FU-5; FU-3 promoted into Phase 2; FU-1/FU-2/FU-4 **posted on SBDEV-1512** 2026-09-15 (comment `90110270185076`, sub-T3); FU-5 proposed as T3, confirmed by Nam and **filed** as https://app.clickup.com/t/868m5jmyc. No finding left recorded only in this document. |
| Effort estimates per phase | ✓ §8, ~4.5 days total — rev1 carried none |
| Review findings dispositioned | ✓ rev3 folds in Architect H1–H3 · M1–M6 · L1–L5 and Critic H1–H5 · M1–M8 · L1–L7; every reversal of rev1 is marked as such inline rather than silently rewritten |
| Completeness words carry their method and blind spots inline | ✓ §0, §1.2, §1.3, §3.2, §3.7, §7.3 row 9, §9 A1 |
| Environment truth — no claim that ShipItEZ gets this in production | ✓ §1.4, §8 constraint 4 |
| Verify-docs / doc-drift pass identified | no — belongs to `wms-plan-executor` after implementation, not to the plan |
| Failing tests written | no — that is `wms-tdd-gate`'s phase, which this plan chains into |
| Line numbers invented | no — every citation is a quoted snippet against a named `origin/develop` SHA |
| Now-wrong justifications deleted rather than caveated | ✓ Alternative C's non-termination reason **withdrawn** (the loop is unreachable behind `amountBottlesPerCase < 1`); §3.2's "Data-model delta: none" **withdrawn**; §3.4's "which OMS does parse" **replaced**; §3.9's `parcel_info.py` attribution **removed**, not annotated |
