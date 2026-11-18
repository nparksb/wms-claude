---
title: "WMS v2 — Receiving & Putaway Workflow"
type: workflow
status: active
version: v2
scope: receiving-putaway
owner: Nam Park
created: 2026-04-19
updated: 2026-11-11
last_verified: 2026-11-11
verified_by: "Full-doc re-verification 2026-11-11 against wms2-api origin/develop df30fa62 (detached worktree): AdviceService, ReceivingService, ReturnAdviceAutoReceiveService, GoodsReceiptPositionService, MobilePutAwayService, AdviceRestController, ReceivingController, PutAwayController, FileImportController read from src/main; every anchor re-pinned. Previous full pass 2026-08-29 (e5daa8ca)."
related:
  - ../architecture/wms2-state-machine-catalog.md
  - ../architecture/wms2-transaction-osiv-boundary-map.md
  - ../architecture/wms2-tenant-routing-datasource-topology.md
  - ../data-dictionary/wms2-sysprop-catalog.md
  - ../../4-Archieves/wms2/plan/260424-RECEIVING_PERFORMANCE_PLAN.md
  - ../../4-Archieves/wms2/plan/260424-RECEIVING_QUANTITIES_FIX_PLAN.md
  - ../../4-Archieves/wms1/plan/260424-receiving-stockunit-unitload-error-analysis-review.md
  - ../../4-Archieves/wms2/plan/SBDEV-2102-putaway-unit-load-not-found-stuck.md
tags:
  - workflow
  - receiving
  - putaway
  - wms2
---

# WMS v2 — Receiving & Putaway Workflow

**Scope:** Physical inbound flow in `v2/wms2-api` — from supplier ASN arrival through goods receipt, stock creation, and putaway to a storage location · **Version:** v2
**Owner:** Nam Park · **Last verified:** 2026-11-11

---

## 1. Overview

Receiving takes a promised shipment (an `Advice` / ASN) and turns it into physical stock at a warehouse location. The flow spans three distinct phases:

1. **Advice lifecycle** — the paper-trail: `CREATED → OPEN → PROCESSING → CLOSED → FINISHED` (String states, two-L `CANCELLED`).
2. **Physical receive** — scanner-driven ingestion that creates `Goodsreceiptposition`, `Stockunit`, `Stockrecord`, and `Unitload` rows. Owner: `ReceivingService.receiveGoods()`.
3. **Putaway** — mobile-driven movement from the receiving lane to a storage slot. Owner: `MobilePutAwayService`. Target-location selection classifies by `LocationType` (`FLOWBIN` vs `OVERSTOCK`) and enforces `FixLocationAssignment` constraints.

Three things to hold in mind:

- **String-state entities** — `Advice` and `Adviceposition` use `AdviceState.CANCELLED` (two L's), not the Integer `CANCELED`. See [wms2-state-machine-catalog.md](../architecture/wms2-state-machine-catalog.md) §7 item 2.
- **`INBOUND_UPDATE_STOCK_IMMEDIATELY` (default `true`)** gates whether a stock-change message is fired to OMS synchronously during receive. Flipping it moves stock updates out of the hot path but delays OMS visibility.
- **`SBDEV-2102`** (active) documents the fix for a multi-replica race where `storePalletBackOnPutawayLane` would yank a pallet off another replica's operator. The fix requires "pallet must be on the current user's location" — don't remove that guard.

---

## 2. Entity Cast

| Entity | Role | State field |
|---|---|---|
| `Advice` | Header for a promised inbound shipment | String `state` (`AdviceState.*`) |
| `Adviceposition` | Line — SKU + expected qty | String `state` (same set) |
| `Goodsreceipt` | Header for the physical receiving event (one per advice) | — (no state) |
| `Goodsreceiptposition` | One physical case received | — |
| `Unitload` | The pallet / tote that holds the received stock | — |
| `Stockunit` | Amount at a location (created per case) | — |
| `Stockrecord` | Audit entry for stock movement | — |
| `Location` | The physical slot | — |
| `FixLocationAssignment` | Item → designated pick face binding | — |

---

## 3. Advice Lifecycle

```
  (OMS creates / file import arrives)
            │
            │  AdviceService (various)  OR  AdviceRestController.create/createTransfer/createHubAndSpoke
            ▼
   Advice.state = OPEN                 (created with state=OPEN; never dwells in CREATED for long)
   Adviceposition.state = OPEN
            │
            │  ⚠ SBDEV-2778 EXCEPTION — type=RETURN via /rest/advice/create does NOT stop here.
            │  Unless the RETURN_ADVICE_AUTO_RECEIVE_ACTIVATED sysprop is 'false', the advice is
            │  received and closed synchronously inside the same request: no dock scan, no operator.
            │  See §3.5 below. Every other path (REGULAR, TRANSFER, and RETURN via FILE IMPORT)
            │  still follows the arrow below.
            │
            │  physical receive per position
            │  ReceivingService.receiveGoods() [:353-675; the 9-arg overload :373 holds the body, the 8-arg :353 delegates with printLabel=true]
            ▼
   Adviceposition.state = OPEN → (stays OPEN until close — except a RETURN advice, which finishReturnAdviceIfComplete
                                  FINISHES on an exact received==notified match per position, SBDEV-3736, see §4.3a)
   Goodsreceiptposition rows created
   Stockunit rows created
   Unitload rows created / transferred
            │
            │  AdviceService.close()       [:299-397]
            ▼
   Advice.state = FINISHED
   Adviceposition.state = FINISHED  (bulk JPQL update via updateAdvicepositionToStateByAdviceId)
            │
            ▼
   OMS callback: WEBSERVICE_CLOSE_ADVICE — an outbox row enqueued INSIDE the close tx (`AdviceService:381`), POSTed by the dispatcher after commit
```

### Variants

| Entry method | Path | Purpose |
|---|---|---|
| `AdviceService.close(Advice, Principal)` | `AdviceService.java:299` | Regular advice finalize; **REGULAR type only** (any other type → `BusinessException("Close inbound BOL not allowed for type …")`) and only from `OPEN` (`CREATED`/`PROCESSING`/`CLOSED`/`FINISHED`/`CANCELLED` → `"Not allowed in state=…"`); enqueues `WEBSERVICE_CLOSE_ADVICE` on the outbox |
| `AdviceService.acceptTransferAdvice(...)` | `AdviceService.java:399` | Transfer-type advice accept (**TRANSFER type only**, from `CREATED`/`OPEN`; refuses a short delivery unless `allowshortdelivery`); enqueues `WEBSERVICE_ACCEPT_TRANSFER` on the outbox |
| `AdviceService.acceptHubAndSpokeAdvice(...)` | `AdviceService.java:172` | Hub-and-spoke accept; enqueues `WEBSERVICE_ACCEPT_HUB_AND_SPOKE` on the outbox; creates `Unitload`, `CustomerorderBatch`, `Customerorder` in the same TX |
| `AdviceRestController.reopen(...)` | `AdviceRestController.java:991` | **NOT IMPLEMENTED** — throws `RuntimeException("method not supported")`. See §9 item 3. |

All three state-writing methods: `@Transactional(value="tenantTransactionManager", rollbackFor={BusinessException, FacadeException})`.

---

## 4. Physical Receive — `ReceivingService.receiveGoods`

The core inbound operation at `ReceivingService.java:353-675` (`@Transactional(tenantTransactionManager, rollbackFor={BusinessException, FacadeException})`; two overloads — the 8-arg form at `:353` calls the 9-arg form at `:373` with `printLabel=true`; the RETURN auto-receive calls it with `false`, §3.5). Called from the receiving workstation when an operator scans items at the inbound gate.

### 4.1 Preconditions

- The `Adviceposition` is row-locked (`findByIdForUpdate`, `:418`) and `Adviceposition.state == OPEN` (`:421`) AND `Advice.state == OPEN` (`:439`), else `unexpectedStateFound`. (`AdviceService.close` itself rejects every non-OPEN state, including `CREATED`.)
- The printer answers: `printService.isPrintAvailable(printer.getAddress())` (`:386`) — an unavailable printer refuses the whole receive (`"Printer not available. Cannot process receiving."`), even when no label will be printed.
- `amountBottles`, `amountBottlesPerCase`, `amountCases` ≥ 1 and `amountCases` ≤ sysprop `MAXIMUM_RECEIVING_DURING_INBOUND` (`:399-415`, an unguarded `Integer.parseInt`); unless `advice.allowoverdelivery`, received + new ≤ notified (`:446-454`).
- A carrier (`storeOnCarrier`) must be at `InboundWorkstation`, or parked by `unassignPallet` at `PutAwayLane`/`EmptyPallets`, in which case it is brought back (`returnToInboundWorkstation`, SBDEV-3615, `:465-477`, `:1045`); anywhere else → `carrierNotAtWorkstation`.
- A `Goodsreceipt` header exists for the advice, or is created on first receive (`:484-504`).
- Pallet / cart label matches regex `STRING_PATTERN_INBOUND_PALLET` (default `CART-\d{4}|IN-\d{6}`), validated by `verifyPalletOrCartLabel` at `ReceivingService.java:946-958`.
  ⚠ **Updated 2026-08-25 for SBDEV-3004.** The stated default is now actually applied in code: `getSysvalue` returns the raw repository result, so a tenant with no `STRING_PATTERN_INBOUND_PALLET` row previously produced `label.matches(null)` → NPE. `verifyPalletOrCartLabel` now falls back to `WmsConstants.SYSTEM_PROPERTY_STRING_PATTERN_INBOUND_PALLET_DEFAULT_VALUE` when the row is absent or blank. Measured across WineCo dev, four UAT tenants and Hydra prd, the key is seeded everywhere, so this is a guard rather than a fix for an observed failure. Same commit also added the missing `verifyPalletOrCartLabel` call to `unassignPallet` (now `:1085`, inside the method at `:1072`; it validated nothing before) and made `updatePallet` (`:1007`) the transaction boundary for the unassign→assign pair. Re-anchored 2026-11-11.

### 4.2 Core loop (the `while (amountBottles > 0)` loop, `ReceivingService:591`)

**Updated 2026-08-10 for SBDEV-2732 (wms2-api PR #139) — MERGED 2026-08-11; this is shipped behaviour.** `putAwayLocation` is no
longer `itemdata.putawaylocation_id`. It is resolved through a **four-tier hierarchy** ONCE above the
loop, on **both** the carrier and non-carrier branches, and a pick-face destination is diverted before
placement.

```java
// ABOVE the loop. Resolving inside `if (carrier == null)` is SBDEV-2731's root cause: the configured
// destination then never reaches the display and the operator cannot see where the receipt is going.
Resolution putaway = putawayDestinationResolver.resolve(itemdata, client, adviceposition.getUnitloadtypeId());
//   tier 1 itemdata.putawaylocation_id → tier 2 client.defaultputawaylocation_id
// → tier 3 sysprop DEFAULT_PUTAWAY_LOCATION (system client, workstation DEFAULT) → tier 4 PutAwayLane
putawayResolutionMetrics.resolved(putaway.source(), carrier != null, putaway.compatible());

// (iv-b) PLACEMENT GATE. A pick face is a LEGAL configuration at every tier, but a receipt is never
// placed into one: receiving moves a whole unit load and a flowbin permits only PickLocation. The
// receipt goes to the lane and putaway routes it into the bin (SBDEV-2821, §5.2).
// The OR is deliberate — the constraint is a location TYPE property, useforpicking is an AREA
// property, and nothing in the schema ties them.
boolean pickFace = area.getUseforpicking() == TRUE || locationType.getSltname() == 'flowbin';
if (pickFace && putaway.source() != STANDARD_PUTAWAY_LANE)
    putaway = putawayDestinationResolver.divertPickFaceToLane(putaway, unitloadtypeId);

// Hard-fail ONLY on the non-carrier branch (D10): on the carrier path the destination is surfaced but
// not applied, so a config error irrelevant to this receipt must not abort it.
if (carrier == null) putawayDestinationResolver.requireCompatible(putaway);
```

```
for each case being received on the adviceposition:
    Unitload unitload = unitloadService.createUnitload(workstation, typeId, client, CODE_RECEIVING, ...)
    Stockunit stockUnit = stockunitBusinessService.createStockUnit(client, item, amount, false, unitload, ...)
    Goodsreceiptposition pos = new Goodsreceiptposition()
    pos.setStockunitId(stockUnit.getId()); pos.setAmount(stockUnit.getAmount())
    goodsreceiptpositionRepository.save(pos)

    if (carrier == null)
        unitloadBusinessService.transferUnitLoadToLocation(unitload, putaway.location(), ...)
    else
        unitloadBusinessService.transferUnitLoadToCarrier(unitload, carrier, ...)
```

The loop runs once per case (`amountBottlesPerCase` drives the divisor). Each iteration creates: 1 `Unitload` + 1 `Stockunit` + 1 `Stockrecord` (via `createStockUnit`) + 1 `Goodsreceiptposition` row.

Pessimistic-write lock on the `Adviceposition` row (`:418`, taken once before the loop) guards against concurrent receivers doing the same case twice. The `carrier == null` fork is at `:621`; the pick-face gate at `:570-575`; `requireCompatible` at `:578-579` (carrier branch only logs, `:580-586`).

**The resolution is per-RECEIPT, not per-case** — the SKU, merchant and unit-load type are identical for
every case in the loop, and a bad destination fails before any unit load exists. `GET
/v3/receiving/getPutawayDestination/{advicePositionId}` returns the same resolution for the display,
including a `divertedTo` field when the gate retargets it, so the screen and the placement cannot
disagree.

### 4.3 OMS stock-change gate (`ReceivingService:646-666`)

```java
if (advice.getType() == REGULAR) {
    if (Boolean.parseBoolean(syspropService.getSysvalue(INBOUND_UPDATE_STOCK_IMMEDIATELY_KEY))) {
        list.add(getStockChangeDTO(...));
    }
} else if (advice.getType() == RETURN) {
    list.add(getStockChangeDTO(...));  // always
} else if (advice.getType() == TRANSFER) {
    // intentionally empty — OMS books transferred stock itself
}
messageService.sendStockChangeMessage(list);
```

- `INBOUND_UPDATE_STOCK_IMMEDIATELY` (default `true`) — when true, every REGULAR receive fires a stock-change message. When false, no message is sent during receive (OMS catches up via the nightly `StockSummaryExportJob`).
- RETURN advices **always** fire a stock-change message regardless of the sysprop. TRANSFER advices send none (the `case AdviceType.TRANSFER` is empty, `:659-661`).

### 3.5 RETURN auto-receive at advice-create time (SBDEV-2778, supersedes SBDEV-2236)

**History matters here, because this behavior has flipped twice.** v1/wms-api always auto-received a
RETURN advice at create time. SBDEV-2236 (merged 2026-05-15, PR #24, `7f9c250`) deliberately deleted
that, on the requirement that physical confirmation must precede the stock increment. SBDEV-2778
restored it on BA decision (2026-08-03) — Return QA *is* the physical confirmation. **Do not "re-fix"
this by citing SBDEV-2236; its plan carries a SUPERSEDED banner.**

Path: `AdviceRestController.create` → `ReturnAdviceAutoReceiveService`. Two insertion points, and the
order is load-bearing:

| Phase | What | Why there |
|---|---|---|
| `validate(dto)` | printer + boxtype + amount + SKU resolution, then ONE CUPS reachability probe | Runs **before** `adviceRepository.save(...)`. `create()` is not `@Transactional`, so a rejection after the save would commit an orphan OPEN advice holding `externalid=RETURN{parcel_id}`, and every OMS retry would then fail the duplicate guard — the return becomes unrecoverable without DB surgery |
| `bind(validated, savedAdvice, savedPositions)` | zips validated lines to persisted position ids **positionally** | Keying by `externalid` collapses two positions that share a `reference_id` (the duplicate checks are on SKU, not reference_id) |
| `execute(plan)` | per-position `receiveGoods(…, printLabel=false)`, each in its own tenant tx; then the damage pass (SBDEV-1512, `applyDamage` → `setLockDamaged`, only for lines with a damaged amount); run as the `oms_integration` principal when that row exists. A failure on position K returns `PARTIAL` (the advice stays OPEN, positions 1..K-1 stay committed, `ReturnAdviceAutoReceiveService:786-822`); a damage failure returns `DAMAGE_FAILED` but the advice is still finished | Deliberately NOT wrapped in an outer transaction: it would hold one connection across all N CUPS round-trips, batch all N STOCK_UPDATEs onto one commit, and poison the outer tx via `receiveGoods`'s `rollbackFor` |
| `markFinished(adviceId)` (`:1010-1016`) | both FINISHED flips, in ONE tenant tx, only after every position was received (the damage pass runs first; it is reached on `DAMAGE_FAILED` too, never on `PARTIAL`) | Split commits can leave positions FINISHED with the advice OPEN, which `ReceivingService:439-441` (advice must be `OPEN`) then refuses to dock-receive — a BOL no path can ever receive |

**Kill switch:** `RETURN_ADVICE_AUTO_RECEIVE_ACTIVATED`, seeded `'true'` by Flyway `V2.2.09`.
⚠ **It is read DEFAULT-ON** — `!"false".equalsIgnoreCase(trimToEmpty(getSysvalue(...)))`, deliberately
**not** the house `Boolean.parseBoolean(getSysvalue(...))` pattern used by every other flag, because
`parseBoolean(null) == false` would silently restore the bug on any tenant missing V2.2.09. An absent
row means ON.

**Landmine — v1 has a defect that was NOT ported.** (⚠ unverified 2026-11-11: the `v1:` line cites were not re-read — v1 is outside this pass's code of record.) `v1:307` wraps `receiveGoods` in
`if (printerOptional.isPresent())` with no `else`, while the FINISHED flips at `v1:317-318` sit
*outside* that guard. On a tenant with no `processdefault` RETURN printer, v1 therefore marks the
advice FINISHED having received nothing — a phantom-**closed** return, worse than the open BOL the
ticket reported. v2 throws instead.

**Per-tenant prerequisites** (any missing one makes every RETURN advice 400, or worse):
a `processdefault=true` `type='RETURN'` printer; a `boxtype` with `externalid='1'`; a resolvable
operator user (`ReceivingService:433-434` looks up `SecurityContextUtils.getUserName()`); and the
`MAXIMUM_RECEIVING_DURING_INBOUND` and `WAREHOUSE_NAME` sysprops set.
⚠ **Corrected 2026-11-11 — this paragraph described the pre-SBDEV-2778-hardening code.** (a) The operator is
no longer the shared `anonymous` fallback: `execute` runs under the principal `oms_integration`
(`ReturnAdviceAutoReceiveService.OMS_INTEGRATION_USER`, seeded by V2.2.09) so returns are attributable; if
that `mywms_user` row is absent the receive DEGRADES to the shared `anonymous` user (base schema V2.2.00 id=1,
`SecurityContextUtils.ANONYMOUS`) with a WARN and the counter `wms2.returns.autoreceive.integration_user_missing`
(`:304-309`, `:715-717`). (b) `WAREHOUSE_NAME` is now guarded: `receiveGoods` reads it through
`SharedService.requireConfig` (`ReceivingService:515-517`), so a missing value is a `BusinessException`
(`MissingReceivingConfiguration`), not an NPE. (c) `MAXIMUM_RECEIVING_DURING_INBOUND` is still an unguarded
`Integer.parseInt` inside `receiveGoods` (`:411`), but `validate` pre-checks it before the advice row commits
(`ReturnAdviceAutoReceiveService:282-294`), so a non-numeric value rejects the request instead of burning the
`RETURN{parcel_id}` externalid.

> **SBDEV-3736 (merged 2026-10-15):** `markFinished` saves the advice as an entity, and dock-received RETURN advices can also reach FINISHED on an exact match — see the SBDEV-3736 block before §4.4.

**Note the notification timing moved.** `CODE_RECEIVING_RETURN` `STOCK_UPDATE` now fires at
advice-create time for auto-received RETURNs, not at dock-receive time — which is v1's timing, and
what SBDEV-2236 had deliberately changed.

**Label timing — SBDEV-3510 ✓ merged(SBDEV-3510: #595 cf686a71, 2026-10-31).** The auto-receive calls
`receiveGoods(.., printer, false)`, so no label prints inside the receive. After the damage pass and
`markFinished` (and on the PARTIAL exit), `ReceivingService.printReceiveLabels` labels each received stock
unit from its current state, and only one still on the unit load it was received onto, with stock, unlocked.
So a mixed line prints the undamaged amount, and a fully damaged line prints nothing: the damage move takes
the whole stock unit onto a new Damaged container, and its old unit load goes to Nirwana. Before this, the
label showed undamaged + damaged and printed before the split (ShipItEZ PRD: 8 of 8 damaged positions
labelled a unit load emptied a second later). The print runs in a `finally` around `markFinished`,
so received stock is labelled even if that throws. A stock unit whose label cannot be built is logged,
skipped and counted (`wms2.returns.autoreceive.label_build_failed`), and never changes the outcome; a
CUPS failure after commit is only logged, as for every receive label. The dock receive (8-arg
`receiveGoods`) still prints inside the receive, unchanged.

⚠ **Damage applied later means the label is stale — reprint it.** On a PARTIAL outcome, or a
DAMAGE_FAILED line, the received lines are labelled at the full received amount because no damage has
been applied yet. Whoever then works the recovery worklist (`notifieddamagedamount > 0 AND
damageappliedat IS NULL`) and moves the damaged units by hand must **reprint the good unit load's label**
afterwards (Unit Load → reprint), or it still shows undamaged + damaged.

#### SBDEV-3736 — RETURN receiving changes (**MERGED** to develop 2026-10-15 (PR #518, merge `a05e8998`, PR head `f6445546`; on dev))

Re-verified 2026-11-11 against `origin/develop` `df30fa62`: all six items hold. Anchors: `finishReturnAdviceIfComplete` `ReceivingService:880-929`, called at `:642` and from `GoodsReceiptPositionService:133,141`; `markFinished` `ReturnAdviceAutoReceiveService:1010-1016`; `receiptdate` `ReceivingService:496`; damaged-transfer call `ReturnAdviceAutoReceiveService:1066-1067`; `receivingCode` `GoodsReceiptPositionService:157`; `returnsAudit` `ReportController:464` (window cap `MAX_RETURNS_AUDIT_WINDOW` = 366 days, `:446`).

1. **RETURN advice finishes on an exact match.** `ReceivingService.finishReturnAdviceIfComplete(Advice)` (public, joins the
   caller's tx) runs at the end of `receiveGoods` (`finishReturnAdviceIfComplete(advice);`) and after
   `GoodsReceiptPositionService.adjust` / `.delete`. A RETURN advice with at least one position is FINISHED (positions, then
   advice, via entity `save`) when **every** position's received total `compareTo(notifiedamount) == 0`. Exact, not `>=`:
   RETURN advices have `allowoverdelivery=true`, so an over-key stays OPEN and correctable. So a **dock-received** RETURN
   advice can now reach FINISHED, and so can one corrected by adjust/delete. It locks OPEN sibling positions in ascending id
   order (`LockReads.forUpdate`), re-reads totals (`LockReads.reconcileLocked`), and throws
   `ObjectOptimisticLockingFailureException` if a locked sibling is FINISHED or missing. Residual windows (method javadoc):
   a sibling adjust/delete committing after the re-read (adjust/delete lock no position); and a same-location concurrent
   completion deadlock (40P01, operator retries).
   **SBDEV-4107 ✓ merged(SBDEV-4107: #665 fd712d7a, 2026-11-12):** the finisher locks the **advice** first, before its first read. The
   same-location deadlock between two receives of one advice and the "lost finish" are therefore closed; see §9 landmine 11.
   It also **fails closed**: if the locked advice is already FINISHED, it throws `ObjectOptimisticLockingFailureException`
   (409, rollback), so a correction whose OPEN check went stale can no longer commit against a FINISHED advice. That
   closes the sibling adjust/delete window for writes through the finisher (`ReturnAdviceStaleCorrectionRaceIT`).
2. **`ReturnAdviceAutoReceiveService.markFinished`** (§3.5) saves the advice as an entity
   (`adviceRepository.saveAndFlush(advice)`), so `advice.modified` bumps. The position flip stays a bulk update.
3. **`goodsreceipt.receiptdate`** is stamped at creation: `goodsreceiptTemp.setReceiptdate(LocalDateTime.now(ZoneOffset.UTC));`
   (set once at the only creator; the reuse branch does not re-stamp).
4. **Damaged return transfer carries the position number.** `setLockDamaged(received, ..., "RETURN DAMAGED " + line.positionExternalId(), false, null, line.number())`
   in `ReturnAdviceAutoReceiveService` — the `adviceposition.number` becomes `stockrecord.ordernumber`, so `transaction_detail`
   DAMAGED rows show an order/transaction number.
5. **Correction notifications.** `GoodsReceiptPositionService.adjust` / `.delete` pick the code through `receivingCode(advice)`:
   `CODE_RECEIVING_RETURN` (`"RETURN"`) for RETURN advices, `CODE_RECEIVING_REGULAR` (`"RECEIVING"`) for every other type, as
   before. For TRANSFER, `receiveGoods` writes `RECEIVING_TRANSFER` as the activity code on WMS's own stock record, but sends
   OMS **no** stock-change message (`case AdviceType.TRANSFER: // intentionally empty`). ~~Adjust/delete still send OMS a
   `RECEIVING` delta for that stock (SBDEV-3775, not fixed).~~ **SBDEV-3775 is FIXED** (`63524924`, 2026-10-15): `GoodsReceiptPositionService.reportsCorrectionToOms` (`:169`, used at `:120` and `:239`) is an allow-list — only REGULAR and RETURN corrections are reported, so an adjust/delete on a TRANSFER receipt sends OMS nothing. (Re-checked 2026-11-11.)
   Still gated by `INBOUND_UPDATE_STOCK_IMMEDIATELY`.
6. **New read endpoint:** `GET /v3/report/returnsAudit` (+ `/v3/dashboard/returnsAudit`, inherited), `@RequiresFunction(WEB_UI_VIEW_RECEIVED_STOCK_OVERVIEW)`;
   params `from`, `to` (ISO date-time, window max 366 days), `page`, `size`, optional `clientNumber`.

### 4.4 Post-commit label print

Label printing goes through `printAfterCommit` (`ReceivingService:763-765`, a `TransactionSynchronizationManager.registerSynchronization`), invoked at `:670-671` only when `printLabel` is true AND sysprop `PRINT_CASE_LABEL` is true, so the printer only fires after the receive commits. If the transaction rolls back, no label is printed — this is the correct behavior. The RETURN auto-receive passes `printLabel=false` and labels through `printReceiveLabels` (`:709`) after its damage pass (§3.5).

---

## 5. Putaway — Mobile Flow

Owner: `MobilePutAwayService`. All seven methods below use `@Transactional("tenantTransactionManager")`; three are `readOnly=true`. (Line column = the `@Transactional` annotation line, re-pinned 2026-11-11.)

| Method | Line | `@Transactional` mode | Purpose |
|---|---|---|---|
| `findUnitLoad` | 105 | write | Validate scanned unit load is in PUTAWAY_LANE or CLEARING; transfer to operator's current location |
| `storePalletOnLocation` | 176 | write | Transfer the operator's pallet → scanned storage location. ✓ merged(SBDEV-3908: #567 c80eee6e, 2026-10-25): refuses (before any write) a unit load that is not a Pallet (`entityNotOfExpectedType`), not on the caller's own location in the `users` area (`putawayUnitLoadNotOnYourLocation`), a Damaged/Shipped/Nirwana destination by name, and a `!useforstorage && !staginglane` area (`locationNotUsableForStorage`). Before SBDEV-3908 it moved ANY pallet to ANY location and used `useforstorage` only to pick `CODE_PUT_AWAY` vs `CODE_UNASSIGN_PUT_AWAY` (the latter is now reachable only via a staging lane) |
| `storePalletBackOnPutawayLane` | 222 | write | Error-recovery path. **SBDEV-2102 fix**: only recovers if pallet is on the *current user's* location (prevents yanking under multi-replica) |
| `calculatePutAwayList` | 318 | readOnly | Classify target locations as FLOWBIN or OVERSTOCK (§5.2) |
| `updateCurrentItemDataUnitLoadList` | 485 | readOnly | Per-SKU filtering as operator works through a mixed pallet |
| `verifyScannedLocation` | 528 | readOnly | Validate `FixLocationAssignment` constraint on the scanned location (§5.3) |
| `storeBoxOnLocation` | 582 | write | Box-level (case-level) putaway. **SBDEV-2102 Bug 6 fix**: passes `removeUnitLoadIfEmpty=true` to prevent stale-object-state on consecutive empty transfers ✓ merged(SBDEV-3908: #567 c80eee6e, 2026-10-25): the same shared source/destination check as `storePalletOnLocation` (box on the caller's own `users`-area location; Damaged/Shipped/Nirwana refused by name) runs before its area gate; `scanPallet`/`findUnitLoad` now refuses an operator with no `users`-area location (`putawayOperatorLocationNotInUsersArea`) before moving anything |

### 5.1 Scan flow (happy path)

```
Operator scans pallet
   │
   ▼ findUnitLoad()
   Unitload moved to operator's current location; pallet contents + SKUs loaded
   │
   ▼ calculatePutAwayList()
   Query Location.getStorageLocationsForPutAwayItemData(itemId)
   Classify each location by LocationType.sltname:
     - STORAGE_LOCATION_TYPE_BOX_RESTRICTION_FLOWBIN → flowBinLocationList
     - STORAGE_LOCATION_TYPE_BOX_RESTRICTION_OVERSTOCK or PALLET_RESTRICTION_OVERSTOCK → overstockLocationList
   Sort by DefaultStrategy (rack-row → rack → column/level; direction controlled by PICK_PATH_DIRECTION sysprop via PickPathConfig → DefaultStrategy)
   ⚠ SBDEV-3133: the tier logic now lives in LocationPathOrdering, shared with the handheld pick
     route (InMemoryLocationComparator) and CycleCountStrategy, so the suggested putaway order and
     the printed tote label cannot drift apart. UNZONED racks (rackrowId == null) sort AFTER every
     zoned rack, as one contiguous block — previously the rack-row tier was skipped for such pairs,
     which made the relation cyclic and the emitted order arbitrary. See picking-workflow §9.1.
   │
   ▼ operator walks to suggested location, scans it
   │
   ▼ verifyScannedLocation()
   If FLOWBIN: confirm FixLocationAssignment matches (or target has no assignment)
   │
   ▼ storeBoxOnLocation() or storePalletOnLocation()
   unitloadBusinessService.transferUnitLoadToLocation(...) OR transferStockToUnitLoad(...)
```

### 5.2 Target-location classification (`MobilePutAwayService` lines 394–412, the type switch inside `calculatePutAwayList` at :319)

⚠ **Updated 2026-08-09 for SBDEV-2821.** Two things changed: where candidates come from, and a fourth
location type that was previously dropped.

**Updated again 2026-08-10 for SBDEV-2732 step 17a (PR #139) — MERGED 2026-08-11.** The second argument is no
longer the tier-1 column: `V2.2.13` nulls `putawaylocation_id` wherever it merely held the seeded lane
id, and §4.2's gate diverts pick-face destinations at **every** tier — so a merchant- or
warehouse-scope destination left on tier 1 would be diverted to the lane at receipt and then never
offered here, stranding the unit load on the lane with nowhere the screen will send it.

```java
// SBDEV-2821: was getStorageLocationsForPutAwayItemData(skuId), which derives candidates ONLY from
// where the SKU already has stock — so a SKU being received into a dedicated bin for the first time
// got ZERO candidates and its configured destination was never offered.
// SBDEV-2732 step 17a: the destination is the FOUR-TIER resolution, not the SKU column. Tier 4 maps
// back to null — resolve() always answers, and passing the lane id would offer the lane the unit load
// is being moved OFF as somewhere to move it TO.
List<Location> candidates = locationRepository.getPutAwayCandidateLocations(
        currentSku.getId(), resolveCandidateDestinationId(currentSku, skuClient));
for (Location loc : candidates) {
    LocationType type = locationTypeRepository.findById(loc.getTypeId()).orElseThrow(...);
    switch (type.getSltname()) {
        case STORAGE_LOCATION_TYPE_BOX_RESTRICTION_FLOWBIN:
            flowBinLocationList.add(loc.getName()); break;
        case STORAGE_LOCATION_TYPE_BOX_RESTRICTION_OVERSTOCK:
        case STORAGE_LOCATION_TYPE_PALLET_RESTRICTION_OVERSTOCK:
        case STORAGE_LOCATION_TYPE_STOCK_RESTRICTION:   // SBDEV-2821 — 'cases and pallets'
            overstockLocationList.add(loc.getName()); break;
        default:
            // still only LOGS — any other type is silently not offered
    }
}
```

FLOWBIN locations are pick-face (fast-moving) — they take priority in the UI. OVERSTOCK absorbs overflow.

**`cases and pallets` (`STORAGE_LOCATION_TYPE_STOCK_RESTRICTION`, `WmsConstants:997`) used to hit
`default:` here and be silently dropped** — the destination never reached the operator. It is the type
wineco's club lanes use. It is bucketed with overstock because it takes a **whole unit load**, unlike
flowbin which merges stock into a resident `PickLocation` UL.

**The candidate query's second leg carries `(useforstorage = 'true' OR staginglane = true)`, mirroring
§5.3's own gate.** That predicate is load-bearing, not decorative: `PutAwayLane` is itself a
`cases and pallets` location with `useforstorage = false`, and on `wms2-wineco-dev` 8,803 of 8,804 SKUs
have `putawaylocation_id = PutAwayLane`. Without it, adding the type to this switch would offer every
operator "put it back on the PutAwayLane".

### 5.3 Fixed-assignment constraint (`:555-579`, inside `verifyScannedLocation` at :529)

When the operator scans a FLOWBIN target, `verifyScannedLocation` enforces:

- If the item has a `FixLocationAssignment`, the scanned location must be that assigned location, else `itemDataNotMatchFixedAssignment` (`:566`).
- If the item has NO assignment but the scanned location has one (for some other item), the put is refused: `scannedLocationHasDifferentFixedAssignment` (`:574`). Re-worded 2026-11-11; the old text said "the item being put away must match", which the code does not test — it refuses, because an item without an assignment cannot match one.
- If neither side has an assignment, the put is allowed (and `storeBoxOnLocation`'s FLOWBIN arm then creates one, `:638-641`, after refusing a whole parcel via `SourceContainerGuard.assertNotParcel`, SBDEV-3353).

Mismatches throw `BusinessException` with a UI-facing message.

**This whole block is FLOWBIN-only** — `verifyScannedLocation`'s fixed-assignment branch is gated on
`sltname == 'flowbin'`. A `cases and pallets` target (a club lane) is deliberately **not** subject to it,
and `storeBoxOnLocation` must never create a `FixLocationAssignment` for one: a club lane is a live
multi-SKU pick face (`Club01` carries 27 distinct SKUs on `wsl-wineco-uat`; 15 on `wms2-wineco-dev`), and `fix_location_assignment` is
`UNIQUE(assignedlocation_id)`, so binding it to the first SKU put away would break every other SKU on
that lane. Pinned by `casesAndPalletsDestinationShouldPlaceWithoutCreatingFixLocationAssignment`.

What `verifyScannedLocation` *does* apply to every type is its area gate at `:549-551` —
`!useforstorage && !staginglane` ⇒ `locationNotUsableForStorage`, preceded since SBDEV-3908 by the by-name refusal of Damaged / Shipped / Nirwana (`PUTAWAY_FORBIDDEN_DESTINATIONS`, `:30`, checked at `:544`). SBDEV-2821's candidate query mirrors
that gate exactly (§5.2) so a location can never be offered that the scan would then refuse.

---

## 6. REST + File-Import Entry Points

### Advice creation

| Endpoint | Method | File:Line | Input |
|---|---|---|---|
| `/rest/advice/create` | PUT | `AdviceRestController.java:145` | `List<AdviceDto>` — creates REGULAR or RETURN advices. **RETURN is also received + closed here** unless the kill switch is off (SBDEV-2778, §3.5). Reads `printer_id`, which was accepted-and-discarded before SBDEV-2778 |
| `/rest/advice/createTransfer` | PUT | `:694` | `BillOfLadingWebServiceDto` — TRANSFER-type advice from OMS |
| `/rest/advice/createHubAndSpoke` | PUT | `:822` | `BillOfLadingWebServiceDto` with manifest — hub-and-spoke flow |
| `/rest/advice/reopen` | POST | `AdviceRestController.java:991` | **Throws RuntimeException — not implemented**; removed by SBDEV-4115 (404) ✓ merged(SBDEV-4115: #664 938c9fe2, 2026-11-11) |

### File import

| Controller | Endpoint | File:Line | Creates |
|---|---|---|---|
| `FileImportController` | `POST /v3/import/clients` | 112 | `Client` entities (supports receiving flow by seeding clients) |
| `FileImportController` | `POST /v3/import/inbound-bols` | 439 | `Advice` rows from a file (REGULAR and RETURN only, `:488`; RETURN via file import is NOT auto-received, §3) — row added 2026-11-11 |
| `FileImportController` | `POST /v3/import/locations` | 169 | `Location`, `LocationArea`, `LocationRack`, `LocationRackRow` |
| `ReceivingController` | `POST /v3/receiving/createPallet` | 298 | `Unitload` (pallet at INBOUND) |
| `ReceivingController` | `POST /v3/receiving/createAndSelectPallet` | 243 | `Unitload` + pallet swap — one transaction via `ReceivingService.createAndSelectPallet` (create used to commit alone and orphan an empty pallet) ✓ merged(SBDEV-4109: #666 3690a730, 2026-11-12) |
| `ReceivingController` | `POST /v3/receiving/setPallet` | 193 | Pallet assignment swap — one transaction via `ReceivingService.replacePallet` ✓ merged(SBDEV-4109: #666 3690a730, 2026-11-12) |
| `ReceivingController` | `POST /v3/receiving/receive` | 421 | The receive action → `ReceivingService.receiveGoods` |
| `ReceivingController` | `GET /v3/receiving/getPutawayDestination/{advicePositionId}` | 94 | The §4.2 resolution for the display (`WEB_UI_VIEW_RECEIVING`) |

### Mobile putaway REST

All under `/v3/putaway/...` (`PutAwayController:24`): `GET scanPallet/{input}` `:39`, `POST calculatePutawayList` `:75`, `POST scanFlowBinLocation` `:96`, `POST storeBoxOnLocation` `:117`, `POST storePalletOnLocation` `:141`, `POST storePalletBackOnPutawayLane` `:164`, delegating to `MobilePutAwayService` methods. ⚠ Corrected 2026-11-11: this section said `/mobile/putAway/...`; no such prefix exists in `src/main` (the controller is `@RequestMapping("/v3/putaway")`).

---

## 7. OMS Callbacks

| Callback | Fired from | Sysprop URL key |
|---|---|---|
| `WEBSERVICE_CLOSE_ADVICE` | `AdviceService.close` (outbox enqueue `:381`) | `SYSTEM_PROPERTY_WEBSERVICE_CLOSE_ADVICE_URL_KEY` |
| `WEBSERVICE_ACCEPT_TRANSFER` | `AdviceService.acceptTransferAdvice` (outbox enqueue `:452`) | `SYSTEM_PROPERTY_WEBSERVICE_ACCEPT_TRANSFER_URL_KEY` |
| `WEBSERVICE_ACCEPT_HUB_AND_SPOKE` | `AdviceService.acceptHubAndSpokeAdvice` (outbox enqueue `:281`) | `SYSTEM_PROPERTY_WEBSERVICE_ACCEPT_HUB_AND_SPOKE_URL_KEY` |
| Per-receive stock-change | `ReceivingService.receiveGoods` (`:646-666`) | via `messageService.sendStockChangeMessage` — gated by `INBOUND_UPDATE_STOCK_IMMEDIATELY` |

The three advice callbacks (CLOSE_ADVICE, ACCEPT_TRANSFER, ACCEPT_HUB_AND_SPOKE) are **transactional-outbox rows** enqueued inside the advice transaction (`outboxService.enqueue`; process types `ADVICE_CLOSE`, `ADVICE_ACCEPT_TRANSFER`, `ADVICE_HUB_AND_SPOKE_RECEIVED`; serialization failure → `FacadeException`, rollback), delivered by `OutboxDispatcherJob` with retry — a rollback leaves no row. Corrected 2026-11-11: this line said all callbacks use `omsNotificationService.sendAfterCommit` and that a rollback silently drops them; `AdviceService` has no `sendAfterCommit` call. ⚠ unverified 2026-11-11: delivery mechanics of the per-receive `messageService.sendStockChangeMessage`.

---

## 8. Transaction Boundaries

- `AdviceService.close` / `acceptTransferAdvice` / `acceptHubAndSpokeAdvice`: single `@Transactional` atomic.
- `ReceivingService.receiveGoods`: single `@Transactional` atomic — all cases for one adviceposition commit together, all roll back together.
- `MobilePutAwayService` write methods: single TX each. The 3 `readOnly=true` methods (`calculatePutAwayList :318`, `updateCurrentItemDataUnitLoadList :485`, `verifyScannedLocation :528`) are the cache-friendliest read paths.
- Pessimistic-write lock on `Adviceposition` during receive (see [wms2-transaction-osiv-boundary-map.md](../architecture/wms2-transaction-osiv-boundary-map.md) §8.2).
- Post-commit hooks: label printing (receive). OMS callbacks (close / accept) are outbox rows written inside the transaction (§7); stock-change message (receive) goes through `messageService.sendStockChangeMessage`. The RETURN auto-receive deliberately runs each position in its own transaction (§3.5).

---

## 9. Known Landmines

1. **`CANCELLED` spelling** — String-state entity. Use `WmsConstants.AdviceState.CANCELLED`, not `State.CANCELED`.
2. **`SBDEV-2102` putaway-lane recovery** — `storePalletBackOnPutawayLane` only recovers pallets at the current user's location. Any change to that guard re-opens the multi-replica race. See the active plan.
3. **`AdviceRestController.reopen` is a stub.** Calling it throws `RuntimeException("method not supported")`. If an operator UI exposes a reopen button, it silently errors. Either implement it or remove the endpoint.
4. **`INBOUND_UPDATE_STOCK_IMMEDIATELY` flip is load-bearing.** When `false`, no stock-change message fires during receive — OMS visibility depends on nightly `StockSummaryExportJob`. Be explicit per-tenant.
5. **`RETURN` advices always fire stock-change**, ignoring the sysprop. The RETURN branch (`ReceivingService:655-658`) is unconditional. Don't "consolidate" both cases.
6. **`receiveGoods` loop-per-case can produce hundreds of rows.** One palletful of bottles at 12/case × 12 cases creates 12 Unitloads + 12 Stockunits + 12 Stockrecords + 12 Goodsreceiptpositions per receive — all in one TX. Large advices sustain pessimistic-lock contention.
7. **Fixed-assignment mismatch throws `BusinessException`, not a soft warning.** The mobile UI surfaces this as a red error. A legitimate one-off override requires admin action (unset the assignment, then re-put).
8. **Pallet label regex is tenant-configurable** (`STRING_PATTERN_INBOUND_PALLET`, default `CART-\d{4}|IN-\d{6}`). A tenant with a different barcode scheme must override it.
9. **`GoodsreceiptService` doesn't exist as a class.** The goods-receipt writes happen inside `ReceivingService.receiveGoods`. Don't grep for `GoodsreceiptService` — nothing there. (`GoodsReceiptPositionService` does exist: it owns the adjust/delete corrections, §4.3a item 5.)
10. **Label printing is post-commit.** If the printer is down, the commit still succeeds; the label is lost. No automatic re-queue.
11. **Receives of one advice serialize on the advice row; one goods receipt per advice; position numbers are max + 1 (SBDEV-4107) ✓ merged(SBDEV-4107: #665 fd712d7a, 2026-11-12).**
    - **Lock order.** `receiveGoods` reads the advice id with a scalar query (`findAdviceIdById`), locks the advice
      (`adviceRepository.findByIdForUpdate`), then the position (`advicepositionRepository.findByIdForUpdate`). That is
      advice → position → put-away location, the same order as `AdviceService.close` and `acceptTransferAdvice`.
      `updateAdviceWithPositions` and the RETURN finisher take the same advice lock.
    - **Why.** Before this, two operators receiving *different* positions of a new advice held different locks, and both
      created a `goodsreceipt`.
    - **Contention.** A second receive on the same advice waits. Past the 3 s tenant `lock_timeout` it gets
      "Another operation is holding this receipt's data — retry." (the `ReceivingController` 55P03 arm). On WineCo PRD over
      90 days, 0 cross-operator receive pairs on one advice fell within 2 s.
    - **Reuse.** A receive attaches to the **oldest** receipt (`findFirstByAdviceIdOrderByIdAsc`), not an arbitrary
      `get(0)`. 2,036 historical advices (1,623 WineCo, 413 c1wh-shipitez) have more than one receipt. All date from
      before 2025-03 and come from bulk import, so there is **no** unique index on `goodsreceipt(advice_id)`; V2.2.51 adds a
      plain index on it.
    - **Numbering.** Advice-position and goods-receipt-position numbers are `max(numeric suffix after the last '-') + 1`
      (`BasicService.nextSuffix`), not a count. A count reissued live numbers after
      `GoodsReceiptPositionService.delete`: 160 duplicate GRP numbers on WineCo, 17 of them since 2026-09-01. Deleting
      the top-numbered position lets its number be issued again; live rows never share one. Old duplicates are not renumbered.

---

## 10. How to debug

| Symptom | Start here |
|---|---|
| "Advice stuck in OPEN, won't close" | §3 close path + guard at `AdviceService.close:304-319` (state switch) and `:322-324` (REGULAR-only type check) |
| "Stock shows at wrong location after receive" | §4.2 loop — one `Unitload` per case, each transferred independently |
| "Putaway refuses scanned location" | §5.3 fixed-assignment constraint + §9 item 7 |
| "Two operators ended up with the same pallet on putaway" | §9 item 2 SBDEV-2102 — the fix is already in place |
| "OMS didn't get stock update from a regular receive" | §4.3 — check `INBOUND_UPDATE_STOCK_IMMEDIATELY` + `message` table |
| "Label didn't print after receive" | §10 item 10 — post-commit, no retry |
| "`reopen` endpoint throws" | §6 + §9 item 3 — intentional |

---

## 11. Verification Log

| Date | What was checked | Result | Checked by |
|---|---|---|---|
| 2026-11-11 | **FULL PASS** against origin/develop `df30fa62`: all anchors re-pinned; §3-§10 behavioural claims re-read from `AdviceService`, `ReceivingService`, `ReturnAdviceAutoReceiveService`, `GoodsReceiptPositionService`, `MobilePutAwayService`, `AdviceRestController`, and the Receiving / PutAway / FileImport controllers. Code read on origin/develop `df30fa62`. | **Corrections:** (1) the three advice OMS callbacks are outbox rows, not `sendAfterCommit` (§3, §7); (2) `close` is REGULAR-only, `acceptTransfer` TRANSFER-only (§3); (3) §3.5 per-tenant prerequisites — `oms_integration` principal with `anonymous` fallback, `WAREHOUSE_NAME` now `requireConfig`-guarded, `MAXIMUM_RECEIVING_DURING_INBOUND` pre-validated; (4) §3.5 execute/markFinished rows — PARTIAL and DAMAGE_FAILED outcomes and the damage pass (SBDEV-1512, SBDEV-2778 partial-receive); (5) SBDEV-3736 block re-verified as merged, item 5's "SBDEV-3775 not fixed" is wrong (fixed 2026-10-15, `reportsCorrectionToOms` allow-list); (6) §4.1 preconditions — printer availability, carrier return-to-workstation (SBDEV-3615), Adviceposition AND Advice must be OPEN, MAX sysprop, over-delivery; (7) `receiveGoods` has two overloads, label print gated by `printLabel` + `PRINT_CASE_LABEL` (§4.4); (8) mobile putaway REST prefix is `/v3/putaway`, not `/mobile/putAway`; (9) §5.3 fixed-assignment wording (the item-without-assignment case refuses), forbidden-destination gate (SBDEV-3908); (10) every file:line anchor in §3-§10 moved (largest: `reopen` 730→991, `receiveGoods` 320-614→353-675, `acceptTransferAdvice` 384→399, controller routes). **Confirmed unchanged:** four-tier putaway resolution + pick-face gate (§4.2), SBDEV-2102 `storePalletBackOnPutawayLane` current-user guard, `reopen` still throws "method not supported", `cases and pallets` bucketing and the useforstorage/staginglane predicate (§5.2), `verifyPalletOrCartLabel` default fallback, `RETURN_ADVICE_AUTO_RECEIVE_ACTIVATED` default-ON read, SBDEV-3908 / SBDEV-3510 text. **Not re-verified:** `v1:` line cites in §3.5; live-data counts (8,803 of 8,804 SKUs, 27/15 club-lane SKUs); delivery mechanics of `sendStockChangeMessage`. | doc-drift pass, 2026-11-11 |
| 2026-10-31 | **SBDEV-3510** ✓ merged(SBDEV-3510: #595 cf686a71, 2026-10-31) — RETURN auto-receive label timing paragraph under the auto-receive section (label printed after the damage pass from current state; nothing for a fully damaged line). | Code read of branch `feature/SBDEV-3510-return-label-after-damage-split` @ 6ef87d07. **Scoped check — the rest of the doc was NOT re-verified.** | Claude (SBDEV-3510) |
| 2026-10-25 | **SBDEV-3908** — §5 endpoint table rows `storePalletOnLocation` / `storeBoxOnLocation` (source + destination rules, shared helper, pallet-only, users-area operator location, scan-time refusal). Marked ✓ merged(SBDEV-3908: #567 c80eee6e, 2026-10-25). Line pins on those two rows retired. | Code read of branch `bugfix/SBDEV-3908-putaway-pallet-destination` @ 92d4f3b3. **Scoped check — the rest of the doc was NOT re-verified.** | Claude (SBDEV-3908) |
| 2026-10-15 | **SBDEV-3736 — **MERGED** to develop 2026-10-15 (PR #518, merge `a05e8998`, PR head `f6445546`; on dev).** Added the SBDEV-3736 block before §4.4 (RETURN finisher, `markFinished` entity save, `receiptdate`, damaged `ordernumber`, correction notification code, `returnsAudit`) and a pointer under §3.5. **Scope: those only; `last_verified` unchanged.** | Code read of the branch (`ReceivingService`, `GoodsReceiptPositionService`, `ReturnAdviceAutoReceiveService`, `ReportController`). Re-verify after merge. | Code read (SBDEV-3736 branch) |
| 2026-08-29 | **FULL PASS — the first since 2026-04-19.** Every line anchor in the document re-derived against `origin/develop` at `e5daa8ca` and **all 24 rebased**; the load-bearing behavioural claims of §3–§9 re-checked. | ⚠ **Every anchor in the doc had drifted** — the three cited files had grown (`ReceivingService` 765 lines, `AdviceService` 559, `MobilePutAwayService` 589) and anchors were stale by 12–29 lines each. Rebased: `receiveGoods` 303-543→**320-614**; `AdviceService.close` 264-353→**284-381**; `acceptTransferAdvice` 356→**384**; `acceptHubAndSpoke` 145→**157**; Goodsreceipt create 405-414→**423-431**; anonymous-user lookup 359→**376**; core loop 459-499→the `while (amountBottles > 0)` at **522**; `carrier == null` 491-495→**508-509**; stock-change gate 505-523→**578-594**; `registerSynchronization` 532-541→**603**; putaway classification 268-295→**322-335**; `calculatePutAwayList` 217→**246**; fixed-assignment 433-455→**481-492**; area gate 427→**470-471**; readOnly trio 211/353/396→**245/412/455**; `WmsConstants` 741→**769**; `AdviceRestController.reopen` 648→**730**. `verifyPalletOrCartLabel` **616** was already correct (widened 616-628→616-642). All 24 re-verified programmatically after rewriting. Behaviour spot-checks all **held**: `reopen` still `throw new RuntimeException("method not supported")`; the SBDEV-3004 sysprop-default fallback present at `:621-623`; `receiveGoods` carries `@Transactional(tenantTransactionManager, rollbackFor=…)` at `:319`, so §4.4's one-transaction claim stands; `SecurityContextUtils.ANONYMOUS = "anonymous"` confirmed, so §4.5's per-tenant `anonymous` user prerequisite stands. **Scope of this pass: anchors (exhaustive) + behavioural claims (load-bearing ones). NOT re-read line-by-line: the §2 entity cast, §10 debug recipes, and the §9 landmine prose.** | Code read on `origin/develop` + programmatic anchor sweep |
| 2026-04-19 | `AdviceService` (close, accept variants, reopen stub); `ReceivingService.receiveGoods` loop + stock-change gate; `MobilePutAwayService` all 6 methods + location classification + fixed-assignment validator; OMS callbacks | All file:line refs confirmed against `src/main/java` | Code read (grep-based) |
| 2026-08-03 | §3.5 added: RETURN auto-receive at advice-create time (SBDEV-2778, supersedes SBDEV-2236); advice-lifecycle diagram annotated; `/rest/advice/create` row corrected | Verified against the SBDEV-2778 branch only — **the rest of the doc was NOT re-verified, so `last_verified` is deliberately left at 2026-05-10** | Code read (SBDEV-2778 diff) |

| 2026-08-06 | §4 receiving loop's `if (carrier == null)` fork and §5.2 target-location classification, re-checked for SBDEV-2731 (PRs wms2-api #133 / wms2-web-ui #39) | Both **confirmed accurate** against `ReceivingService:508-509` and `MobilePutAwayService:268-288`. §5.2's anchor was stale (`line 263-283`) and is corrected to `268–288`, now naming the enclosing method. SBDEV-2731 changed only the *message* thrown on constraint rejection, not the routing this doc describes, so no behavioural text needed updating. **Scoped check — the rest of the doc was NOT re-verified, so `last_verified` stays at 2026-05-10.** | Code read (SBDEV-2731 diff + targeted greps) |

| 2026-08-09 | §5.2 and §5.3 **rewritten** for SBDEV-2821. §5.2's quoted code block was invalidated on two counts: candidates now come from `getPutAwayCandidateLocations(skuId, configuredLocationId)` rather than the stock-derived `getStorageLocationsForPutAwayItemData(skuId)`, and the switch gained a fourth case (`cases and pallets`) that previously fell to `default:` and was silently dropped. §5.3 gained the flowbin-only scoping of the fixed-assignment branch and the club-lane no-FLA rule. Anchor corrected `268–288` → `268–295`; §5.3 anchor and its `:418` citation rebased to `433-455` / `:427`. | Confirmed against the SBDEV-2821 branch. The `(useforstorage OR staginglane)` predicate on the query's second leg was additionally proven by executing the shipped SQL against `wms2-wineco-dev` — it is what keeps `PutAwayLane` (itself `cases and pallets`, `useforstorage=false`, the configured destination of 8,803/8,804 SKUs) out of the candidate list. **Scoped check — the rest of the doc was NOT re-verified, so `last_verified` stays at 2026-05-10.** | Code read (SBDEV-2821 diff) + live SQL on `wms2-wineco-dev` |
| 2026-08-29 | §5.2's sort line re-checked for **SBDEV-3133** (wms2-api PR #233, merged 2026-08-29). `DefaultStrategy` now delegates its tier logic to the new shared `LocationPathOrdering`; the line described the tiers as "rack + rack-row" and did not mention unzoned racks. Corrected to the real tier order and annotated with the unzoned-block rule. | Confirmed against `origin/develop` at `e5daa8ca`: `DefaultStrategy.compare` delegates to `LocationPathOrdering.compareResolved`/`compareCoordinates`, and `MobilePutAwayService` constructs it at `:356`, `:366`, `:387` — so this doc's putaway suggestion order is genuinely governed by it. **Scoped check — the rest of the doc was NOT re-verified, so `last_verified` stays at 2026-05-10.** It is now **111 days** old and overdue a full pass. | Code read (SBDEV-3133 diff + targeted greps) |
| 2026-08-10 | §4.2 and §5.2 updated for **SBDEV-2732** (wms2-api PR #139, **MERGED 2026-08-11**). §4.2's `putAwayLocation` is no longer `itemdata.putawaylocation_id`: it is a four-tier resolution taken ONCE above the loop on both branches, followed by the (iv-b) pick-face placement gate and a `carrier == null`-only `requireCompatible`. §5.2's second query argument moves from the tier-1 column to that same resolution, with tier 4 mapping back to null. | Confirmed against the SBDEV-2732 branch at `aff434e`. **Described unmerged behaviour when written; PR #139 MERGED 2026-08-11, so this row now describes the shipped code** (status corrected 2026-08-25). **Scoped check: the rest of the doc was NOT re-verified, so `last_verified` stays at 2026-05-10** — it is now 92 days old and due a full pass. | Code read (SBDEV-2732 diff) |

**Re-verify every 90 days.** Next due: **2027-02-09** — receiving logic is stable but mobile putaway (SBDEV-2102 area) and the RETURN auto-receive path (SBDEV-2778 / 1512 / 3736 / 3510) are fix-prone.
