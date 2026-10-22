---
title: SBDEV-1512 — E7 verification: does the WMS stock-change message reach LegacyInventoryAdjustService, is it live, and is E7's call-site verdict right?
ticket: SBDEV-1512
type: evidence
status: complete
date: 2026-09-15
derived_from:
  - v2/wms2-api origin/develop @ 9e294d4b
  - v2/oms-laravel-api origin/develop @ 97c5ced5, origin/main @ 71bb2eac
  - v1/wms-api origin/develop
  - MCP: wms2-hydra (PRD), c1wh-shipitez-uat, nywh-shipitez-uat, wms1-shipitez1 (v1 PRD)
---

# E7 verification — WMS→OMS stock-change routing, liveness, and the netting contract

## Verdict up front

**E7 is CONFIRMED in its core consequence and WRONG in its diagnosis.**

- The routing E7 assumed is real and live (Q1 ✅, Q2 ✅).
- The OMS contract E7 quotes is real, is on `main`, and has been since 2026-08-04 (Q3 ✅).
- But E7's causal story — *"three WMS damage sites are wrong, `UnitloadService:582` is right"* — is
  **backwards**. There is no inconsistency inside the WMS. The WMS has emitted one coherent
  convention since 2022, it is still emitting it on live v1 production today, and the v2 OMS
  **unilaterally changed its interpretation of that convention on 2026-07-31** in commit `dd17b84f`,
  on the strength of an explicit assumption about the WMS that the WMS does not satisfy.
- The blast radius is **~10 of 18 call sites, in both directions**, not 3 in one direction. E7
  understates it, and its proposed one-argument fix would repair one of ten and entrench the wrong
  contract.

---

## Q1 — Does the message reach `LegacyInventoryAdjustService`? **YES. Two independent instruments.**

### Producer chain (v2/wms2-api `origin/develop`)

`SharedService.getStockChangeDTO(...)` → `MessageService.sendStockChangeMessage(list)` →
`StockChangeNotificationService.sendAfterCommit(list)` → `OmsNotificationService.sendAfterCommit(url, payload, "STOCK_UPDATE")`
→ `doSend` → `HttpRestService.post(url, payload)`.

`service/MessageService.java` — the whole body is a delegation:

```java
public void sendStockChangeMessage(List<StockChangeDto> stockChangeList) {
    // SBDEV-2214 Fix B — defer the STOCK_UPDATE POST until after the caller's tx commits.
    stockChangeNotificationService.sendAfterCommit(stockChangeList);
}
```

`service/StockChangeNotificationService.java` resolves the target and serializes in-transaction:

```java
String urlPath = syspropService.getSysvalue(WmsConstants.SYSTEM_PROPERTY_WEBSERVICE_STOCK_UPDATE_URL_KEY);
payload = WmsObjectMapper.shared().writeValueAsString(stockChangeList);
omsNotificationService.sendAfterCommit(urlPath, payload, WmsConstants.MessageProcessType.STOCK_UPDATE);
```

`service/WmsConstants.java:1092-1093` fixes the sysprop and its default target:

```java
public static final String SYSTEM_PROPERTY_WEBSERVICE_STOCK_UPDATE_URL_KEY = "WEBSERVICE_STOCK_UPDATE";
public static final String SYSTEM_PROPERTY_WEBSERVICE_STOCK_UPDATE_URL_DEFAULT_VALUE =
    "https://oms-XXXXX.siteboss.net/call/inventory/stockUpdate";
```

`HttpRestService.post` uses the sysprop value as the **whole URL** (`restClient.post().uri(url)`) — there
is no base-URL composition, so the sysprop alone decides which OMS route is hit.

**Not outbox-mediated.** Derivation: `git grep -n "STOCK_UPDATE" origin/develop -- src/main/java` returns
11 hits, none of them an `outboxService.enqueue` site. `STOCK_UPDATE` still rides the legacy
`OmsNotificationService` fire-and-forget path — **no retry, no backoff, no outbox row**.
*Blind spot:* the grep keys on the constant name and the `STOCK_UPDATE` literal; an enqueue site using a
different `OutboxMessage` type name for the same semantic payload would not appear. None was found by the
complementary `StockChangeDto` grep either (20 hits, all listed in Q4).

### Consumer (v2/oms-laravel-api `origin/develop`) — and the two paths DO differ

**There are two OMS routes named `stockUpdate` and they implement different contracts.** This is the
central finding of Q1 and it is worse than "they differ in netting": **only one of them can parse the
WMS payload at all.**

| | `/call/inventory/stockUpdate` | `/services/call/stockUpdate` |
|---|---|---|
| Route file | `routes/legacy-inventory.php:56` | `routes/legacy-services.php:69` |
| Controller | `LegacyInventoryController::stockUpdate` | `LegacyWmsController::stockUpdate` |
| Body shape | bare JSON array **or** `{updates:[…]}` | **requires** top-level `updates` key |
| Item keys read | `sku` / `clientNumber` / `normal` / `damaged` / `on_hold` … | `SKU` / `client_code` / `quantity_on_hand` / `quantity_damaged` … |
| Service | `LegacyInventoryAdjustService::processStockUpdates` → `processWMSUpdate` | `LegacyProductUpdateService::updateProduct` → `processUpdate` |
| Netting of on-hand | **NO** on the incremental path (since `dd17b84f`, 2026-07-31) | **YES, unconditionally** |
| Reachable by the WMS payload | yes | **no** — see below |

`LegacyInventoryController::stockUpdate` is the one the WMS hits:

```php
// The WMS posts a bare JSON array of StockChangeDto items; also accept
// a { "updates": [...] } envelope for backward compatibility.
$updates = $this->extractLegacyItems($request, 'updates');
...
$result = $this->inventoryAdjustService->processStockUpdates($updates, $source, $batchId);
```

and `processWMSUpdate` hard-codes the incremental flag:

```php
$result = $this->applyInventoryQuantities($sku, $clientNumber, $facilityCode, $itemId,
                                          $cast['values'], true, $source, $comment, $activityCode);
```

(`true` is the `$addToExisting` argument.)

The sibling `LegacyWmsController::stockUpdate` **nets on both branches** —
`LegacyProductUpdateService::processUpdate`:

```php
// Adjust on_hand by subtracting damaged, missing, and on_hold
$adjustedOnHand = $onHand - $damaged - $missing - $onHold;
```

…and that `$adjustedOnHand` is what `updateInventoryQuantities` writes in **both** the
`if ($flagAddExisting)` and the `else` branch. So the netting difference is real and total.

**But the WMS can never reach the sibling**, on three independent grounds:
1. It calls `$this->validateLegacyParameters($request, ['updates'])` — the WMS posts a bare array, so
   `updates` is absent and the request 400s before any inventory code runs.
2. It reads `$update['SKU']` / `$update['client_code']`; the DTO serializes `sku` / `clientNumber`
   (`json/StockChangeDto.java`, `@JsonInclude(NON_EMPTY)`, no `@JsonProperty` aliases on those two).
3. It reads `quantity_on_hand` / `quantity_damaged`; the DTO emits `normal` / `damaged`.

**So "which path does the WMS call" has one answer and it is not configurable into the other one.**
Pointing a tenant's sysprop at `/services/call/stockUpdate` would not switch to netting — it would
produce 400s. Any remediation that reads as "just point it at the netting path" is unsound.

### Second instrument for Q1: the recorded response bodies

Hydra PRD `message.answer` for `process='STOCK_UPDATE'` (id 126906, 2026-08-24), verbatim:

```json
{"status":"success","message":"Stock updated successfully","data":{"status":"SUCCESS",
 "result":"Stock updates processed successfully","update_id":"SU_1787589854","batch_id":null,
 "source":"WMS","status_text":"processed","records_processed":1,"records_failed":0,
 "update_timestamp":"2026-08-24T16:44:15.085754Z","processing_time":"2.3 seconds",
 "failed_records":[],"summary":{"total_quantity_updated":12,"facilities_affected":["NYWH"],
 "skus_updated":["Organic Red 23"]}}}
```

That is `legacySuccessResponse($result, 'Stock updated successfully')` wrapping
`processStockUpdates`' own return (`update_id: SU_…`, `records_processed`, `failed_records`,
`summary.skus_updated`). The sibling path returns a different `data` shape (`total_records`,
`successful_updates`, `errors`) and is absent here. **The response body confirms the service, not just
the route table.**

**Q1 verdict: CONFIRMED.** `POST {WEBSERVICE_STOCK_UPDATE}` → `LegacyInventoryController::stockUpdate`
→ `LegacyInventoryAdjustService::processStockUpdates` → `processWMSUpdate` → `applyInventoryQuantities(…, $addToExisting = true)`.

---

## Q2 — Is the path live, and for whom? **YES, on every tenant checked, including PRD.**

### Sysprop values (`los_sysprop.sysvalue`, read per tenant)

| tenant DB | `WEBSERVICE_STOCK_UPDATE` | modified |
|---|---|---|
| `wms2-hydra` (**v2 PRD**) | `https://api-oms.sbo.li/call/inventory/stockUpdate` | 2021-07-12 |
| `c1wh-shipitez-uat` (`wh01_shipitez_v2`) | `https://api-oms.uat.sbo.li/call/inventory/stockUpdate` | 2026-09-09 |
| `nywh-shipitez-uat` | `https://api-oms.uat.sbo.li/call/inventory/stockUpdate` | 2021-07-12 |
| `wms1-shipitez1` (**v1 PRD, live**) | `https://api-oms.shipitez.sbo.li/call/inventory/stockUpdate` | 2022-07-19 |

All four carry the `/call/inventory/` path. **No tenant is on the sibling route.** (Derivation: direct
`SELECT` on each DB. Blind spot: four tenant DBs, not the full fleet — `wineco`/`wsl` and the dev
landlord's other tenants were not read.)

### No additional gate on this path

- `StockChangeNotificationService` reads **only** the URL; a null URL writes a `FAILED` message row and
  returns — there is no boolean `*_ACTIVATED` sysprop for `STOCK_UPDATE`, unlike
  `WEBSERVICE_ORDER_BATCH_CANCELLED_ACTIVATED` / `..._UPDATE_PRIORITY_ACTIVATED`, which Hydra does carry.
- `WEBSERVICE_BEHAVIOUR` (Hydra value `send`) **gates nothing**. Derivation:
  `git grep -n "WEBSERVICE_BEHAVIOUR\|SYSTEM_PROPERTY_WEBSERVICE_BEHAVIOUR" origin/develop -- src/main/java`
  returns 4 hits: three constant declarations in `WmsConstants` and one *commented-out* line in
  `UtilRestController`. Zero readers. *Blind spot:* the grep covers both the constant name and the raw
  literal, so a reader would have to build the key by concatenation to hide.

### Traffic (two instruments, and a positive control)

`message` table, `process = 'STOCK_UPDATE'`:

| DB | total | `damaged ≠ 0` | `normal:0 & damaged:+N` | window |
|---|---|---|---|---|
| `wms2-hydra` (PRD) | **23** | **0** | **0** | 2026-07-12 → 2026-08-24 |
| `c1wh-shipitez-uat` | 12 566 | 316 | **172** | 2022-07-31 → 2026-09-08 |
| `nywh-shipitez-uat` | 102 | — | 3 | → 2025-12-05 |
| `wms1-shipitez1` (v1 PRD) | **12 609** | **318** | **173** | 2022-07-31 → **2026-09-15** |

**Positive control for the Hydra zero.** The identical query shape on the same table/DB returns
non-zero for 21 other `(process, status)` pairs — `INVENTORY_FULL_EXPORT` 719, `ADVICE_CLOSE` 228,
`ORDER_BATCH_PICKING_RELEASED` 187 — and `STOCK_UPDATE` itself returns 23. So the instrument works; the
zero is a **true zero on the damaged axis only**, not a broken probe. Same for `nywh-shipitez-uat`
(10 532 messages total, 667 `ORDER_BATCH_PICKING_RELEASED`).

**The two ShipItEZ instruments agree.** `wms1-shipitez1` is the live v1 PRD database;
`c1wh-shipitez-uat` is its migrated v2 copy. 12 609 / 318 / 173 vs 12 566 / 316 / 172 — the deltas are
exactly the rows written after the migration snapshot. Two instruments, same answer.

### The critical liveness split

`message.destination` disambiguates which OMS answered:

- **Hydra PRD** → `https://api-oms.sbo.li/call/inventory/stockUpdate`, answer = the **Laravel** envelope
  quoted in Q1. Hydra is on the v2 OMS. **Live.**
- **ShipItEZ v1 PRD** → `https://api-oms.shipitez.sbo.li/call/inventory/stockUpdate`, answer =
  `{"Status":"Success","Message":"Stock was updated."}` — the **v1 Zend** envelope (capitalised keys,
  no `data` object). ShipItEZ's damage traffic is **not** hitting the Laravel service.

**So all 173 real-world `normal:0 / damaged:+N` messages have been answered by the v1 OMS, and the only
client on the v2 OMS has never sent one.**

**Q2 verdict: LIVE, but the defective shape has produced ZERO drift so far.** The exposure is
prospective: it lands the day a client that performs manual damage moves runs on both v2 WMS and v2 OMS.
ShipItEZ generates roughly 30–50 such messages a year (2023: 56, 2024: 30, 2025: 52, 2026-to-date: 33)
and is mid-migration.

---

## Q3 — Which OMS build, and does it contain the netting change?

`git log origin/develop -- app/Services/Legacy/LegacyInventoryAdjustService.php` places the whole WMS
stock-sync feature at **2026-07-13** (`8bc2e1c4`, "apply WMS stock sync in v2 (SBDEV-2561)"), and the
`$addToExisting` netting guard plus its comment at **`dd17b84f`, 2026-07-31**, titled
*"SBDEV-2671 Address Codex review: kit child-inventory join + incremental on-hand netting"*.

**It is on `main`.** `git merge-base --is-ancestor dd17b84f origin/main` → yes. Earliest tag containing
it: **`v2.0.76`, dated 2026-08-04**. So any production OMS build tagged ≥ `v2.0.76` carries the
non-netting incremental path, and the most recent main-line release is `v2.0.104`
(`396bdb89`, 2026-09-10).

**Before `dd17b84f`, the incremental path NETTED** — i.e. the WMS's `normal:0 / damaged:+N` shape was
handled *correctly*. The commit body says so in its own words:

> *"LegacyInventoryAdjustService netted the reported on-hand by damaged/missing/on-hold on BOTH
> ingestion paths. That is correct for the absolute stock-count (a gross physical count, matching v1
> productUpdate), but wrong for the incremental stockUpdate, which is a per-bucket delta of good units:
> **a good→damaged move arrives as normal -1 / damaged +1** and must drop on-hand by 1, not 2."*

That bolded clause is the load-bearing premise of the change, and **it is false**. The WMS has never
sent `normal -1 / damaged +1` for a good→damaged move. It sends `normal 0 / damaged +1` — 173 times in
live production, from 2022-07-31 to 2026-09-14, with zero counter-examples.

**What I could NOT determine without deploy access:** the exact image/tag running behind
`api-oms.sbo.li` and `api-oms.uat.sbo.li`. There is no build stamp in the recorded `answer` bodies
(`status_text` and `processing_time` both date to the initial 2025-06-06 commit, so they carry no
temporal signal), and I did not make outbound HTTP calls. The inference "PRD ≥ v2.0.76, therefore
non-netting" rests on the tag ancestry plus the 2026-08-04 tag date, not on an observation of the
deployment. **Confirm it before acting.**

---

## Q4 — Re-derivation of the call sites, and why E7's verdict is backwards

### Instrument and its blind spots

`git grep -n "getStockChangeDTO" origin/develop -- src/main/java` → **20 hits: 2 declarations in
`SharedService` (:119 one-arg-short overload, :129 the real factory) and 18 call sites.** Same count E7
reports.

**Blind spot 1 — direct construction.** Checked, and it is clean:
`git grep -n "new StockChangeDto" origin/develop -- src/main/java` returns **exactly one** hit,
`SharedService.java:133`, inside the factory. *Residual blind spot:* Jackson could materialise one by
deserialization on an inbound endpoint; the broader `git grep -n "StockChangeDto"` (49 hits) shows no
controller or `@RequestBody` binding of the type, so no inbound constructor exists either.

**Blind spot 2 — E7 missed this one, and it is a live defect.** A *different* DTO is posted to the
*same* sysprop URL. `controller/ItemDataController.java:104-131`, handler
`GET /sendStockUpdate/{itemdataid}`:

```java
List<StockCountDto> stockCounts = warehouseStockReportService.getStockCount(itemData.getClientId(), itemData.getId());
...
urlPath = syspropService.getSysvalue(WmsConstants.SYSTEM_PROPERTY_WEBSERVICE_STOCK_UPDATE_URL_KEY);
payload = WmsObjectMapper.shared().writeValueAsString(stockCounts);
```

`StockCountDto` carries `itemDataNumber` / `total` / `damage`; the incremental endpoint's
`validateStockUpdate` requires `sku` **or** `SKU`:

```php
$sku = $updateData['sku'] ?? $updateData['SKU'] ?? null;
if ($sku === null || $sku === '') {
    return ['status' => 'FAILURE', 'message' => 'Missing required field: sku'];
}
```

so **every row this handler sends is rejected**. The snapshot shape belongs on `WEBSERVICE_STOCK_COUNT`
(`…/call/inventory/stockCountExport`), which Hydra has configured and which `StockSummaryExportJob:555`
uses correctly. This handler is pointed at the wrong sysprop. It is a separate, smaller finding — not
part of E7 — and it is **not** currently corrupting inventory, because the rejection is total rather
than partial.

### What `quantity_on_hand` means in the OMS

Settled by the OMS's own comment in `applyInventoryQuantities`, describing the snapshot path:

> *"v1's productUpdate subtracts the damaged/missing/on-hold counts before storing it
> (productUpdate.psql: SET on_hand = on_hand - damaged - missing - on_hold); **quantity_on_hand then
> holds sellable stock with the buckets parallel.**"*

`quantity_on_hand` = **sellable**, excluding damaged / missing / on-hold. Damaged units are not in it.

### The 18 sites, scored against BOTH contracts

`N` = `stockUnit.getAmount()`, `diff` = signed amount change. "netting" = pre-`dd17b84f` v2 OMS and the
v1 OMS; "no-net" = v2 OMS from `dd17b84f` on.

| # | Site | args `(normal, damaged, missing, onHold, transfer)` | under **netting** | under **no-net** (today) |
|---|---|---|---|---|
| 1 | `GoodsReceiptPositionService:113` | `(diff,0,0,0,0)` | ✅ | ✅ |
| 2 | `GoodsReceiptPositionService:179` | `(total,0,0,0,0)` | ✅ | ✅ |
| 3 | `ReceivingService:579` | `(N,0,0,0,0)` | ✅ | ✅ |
| 4 | `ReceivingService:584` | `(N,0,0,0,0)` | ✅ | ✅ |
| 5 | `MobileCycleCountService:239` | `(diff,0,0,0,0)` | ✅ | ✅ |
| 6 | `MobileCycleCountService:452` | `(diff,0,0,0,0)` | ✅ | ✅ |
| 7 | `StockunitService:841` `adjustAmount`/NOT_LOCKED | `(diff,0,0,0,0)` | ✅ | ✅ |
| 8 | `StockunitService:609` `transferStock`→Damaged | `(0,+N,0,0,0)` | ✅ on_hand −N, dmg +N | ❌ **over-states sellable by N** |
| 9 | `StockunitService:786` `setLockDamaged` | `(0,+N,0,0,0)` | ✅ | ❌ **over-states sellable by N** |
| 10 | `MobileMoveUnitloadService:560` `setStockDamaged` | `(0,+N,0,0,0)` | ✅ | ❌ **over-states sellable by N** |
| 11 | `StockunitService:723` `setLockOnHold` | `(0,0,0,+N,0)` | ✅ on_hand −N, hold +N | ❌ **over-states sellable by N** |
| 12 | `StockunitService:838` `adjustAmount`/QUALITY_FAULT | `(diff,diff,0,0,0)` | ✅ on_hand 0, dmg +diff | ❌ on_hand +diff **and** dmg +diff — double count |
| 13 | `StockunitService:835` `adjustAmount`/ON_HOLD | `(diff,0,0,diff,0)` | ✅ on_hand 0, hold +diff | ❌ on_hand +diff **and** hold +diff |
| 14 | `StockunitService:936` `removeLock`/QUALITY_FAULT | `(0,−N,0,0,0)` | ✅ on_hand +N, dmg −N | ❌ **under-states sellable by N — stock vanishes** |
| 15 | `StockunitService:939` `removeLock`/ON_HOLD | `(0,0,0,−N,0)` | ✅ on_hand +N, hold −N | ❌ **under-states sellable by N** |
| 16 | `MobileMoveUnitloadService:599` `removeStockDamaged` | `(0,−N,0,0,0)` | ✅ | ❌ **under-states sellable by N** |
| 17 | `UnitloadService:582` delete, NOT_LOCKED | `(−N,0,0,0,0)` | ✅ | ✅ |
| 18 | `UnitloadService:582` delete, QUALITY_FAULT / ON_HOLD | `(−N,−N,0,0,0)` / `(−N,0,0,−N,0)` | ✅ on_hand 0, bucket −N | ❌ **under-states sellable by N** |

(#17 and #18 are the same source line under different `entityLock` values — the `damaged` / `on_hold`
arguments are computed by a ternary on `stockUnit.getEntityLock()`.)

**Under the netting contract: 18/18 correct. Under today's contract: 8 correct, 10 wrong, in both
directions.**

### Arguing E7's side properly, then rejecting it

E7's case is: `UnitloadService:582` passes `stockUnit.getAmount().negate()` while the damage sites pass
`0`; two call sites of one factory disagree; one must be wrong; the OMS comment names `normal −1 /
damaged +1` as the required shape, so the `0` sites are the wrong ones.

That is a coherent reading of the two lines in isolation, and it is why the finding was filed. It fails
on four grounds, each independently sufficient:

1. **The two sites are not doing the same thing, so they are not in disagreement.**
   `UnitloadService:582` is `deleteUnitLoad` — the stock leaves the warehouse entirely, so the *gross*
   physical delta genuinely is `−N`, and it additionally reports `damaged: −N` to drain the bucket the
   stock was sitting in. `setLockDamaged` moves stock *between* buckets, so the gross physical delta is
   genuinely `0`. **Both are consistent with a single rule: `normal` is the GROSS physical delta;
   the bucket fields are bucket deltas; the OMS derives sellable by netting.** Under that rule every
   one of the 18 sites is right, including the pair E7 calls contradictory.

2. **The same convention is live in v1, unchanged.** `git grep -n "getStockChangeDTO" origin/develop --
   src/main/java` in `v1/wms-api` returns the identical pattern: `StockunitService:248` and `:428` pass
   `(0, +N, …)`; `UnitloadService:327` passes `(negate(), damaged, …)`. The "inconsistency" is not a v2
   port defect. It is the v1 design, still running in ShipItEZ production, still being answered
   `{"Status":"Success"}` by a v1 OMS that nets.

3. **The OMS's own new contract was written against a false premise.** `dd17b84f`'s justification is
   *"a good→damaged move arrives as normal -1 / damaged +1"*. No WMS site, in v1 or v2, has ever emitted
   that. 173 live production rows say `normal:0 / damaged:+N`. Zero say otherwise. The change asserted a
   producer behaviour rather than measuring it.

4. **The pinning test cannot see the defect.** `LegacyInventoryControllerTest::test_stock_update_adds_deltas_from_wms_bare_array`
   fixes `normal:10, damaged:1, on_hold:2` and asserts on_hand 110 / damaged 6 / onhold 12. **No WMS call
   site can produce that tuple** — the only sites that send a non-zero `normal` alongside a non-zero
   bucket are `adjustAmount` (#12, #13), where the two are *equal by construction*. The test is green
   and proves nothing about real traffic; it pins the assumption, not the contract.

**Q4 verdict: E7's observation is right, its attribution is wrong.** The `0` is not a WMS bug. It is
the WMS's contract, and the OMS walked away from it on 2026-07-31.

---

## Consequences for SBDEV-1512's D5

E7's arithmetic for the ticket stands, on the current OMS build: a 5-unit return with 2 damaged sends
`receive(normal +5)` then `damage(normal 0, damaged +2)`, leaving OMS at sellable 5 / damaged 2 against
a physical 3 / 2. **Sellable is over-stated by exactly the damaged quantity.** That part of E7 is
confirmed and should not be softened.

What changes is the fix:

- **E7's proposed fix ("pass `normal = −damagedAmount`") repairs 1 of 10 sites** (or 3 of 10 if the
  sibling sweep is done) and would make the WMS internally inconsistent for the first time — sites
  #11–#16, #18 would still be wrong, and #14–#16, #18 are wrong in the *opposite* direction, which no
  amount of sign-flipping at the damage sites addresses.
- The **invariant-over-instance** fix is to restore the netting the incremental path had before
  `dd17b84f` — one condition in one PHP file — which returns all 18 sites to correct simultaneously and
  re-aligns v2 with v1, with no WMS change and no deploy-ordering hazard.
- If instead the no-netting contract is judged correct on the merits, then **all 10 sites must move
  together in one release**, and the v1↔v2 divergence becomes permanent and must be documented, because
  ShipItEZ's v1 stack will keep emitting the old shape to a netting v1 OMS while its v2 stack emits a
  new shape to a non-netting v2 OMS.

That is a contract decision, not a call-site decision, and it is **T3** (data integrity, cross-system,
cross-repo, affects live client inventory). Per the ticket policy it is **PROPOSED, not filed.**

**Drift to date: zero.** Hydra PRD — the only client on both v2 WMS and v2 OMS — has sent 23
`STOCK_UPDATE` messages and **none** carried a non-zero `damaged`, `missing` or `on_hold` (verified:
`count(*) FILTER (WHERE message NOT LIKE '%"damaged":0%')` = 0 over all 23). No backfill is needed
today. The window closes the moment a damage-performing client is on both v2 stacks.

---

## Blind spots and what I did not establish

1. **No deploy observation.** The running image behind `api-oms.sbo.li` / `api-oms.uat.sbo.li` was not
   read. The "PRD has the non-netting code" claim is an inference from tag ancestry (`v2.0.76`,
   2026-08-04) and nothing stronger.
2. **No OMS-side data.** No MySQL MCP for the OMS tenant DBs in this session, so
   `product_inventory.quantity_on_hand` was never compared against WMS stock for any SKU. The
   "zero drift" conclusion is derived from the *absence of defective messages*, not from reconciling
   the two systems. Those are different claims and the second is stronger.
3. **Four tenant DBs, not the fleet.** `wineco` / `wsl` and the remaining landlord tenants were not read
   for `WEBSERVICE_STOCK_UPDATE`. A tenant pointed at a third URL would not have been seen.
4. **v1 OMS source not available.** `v1/oms` is not checked out in this monorepo, so
   `productUpdate.psql`'s incremental branch was not read directly. That v1 nets on the incremental path
   rests on (a) `LegacyProductUpdateService::processUpdate`'s unconditional `$adjustedOnHand` — a
   declared faithful port — and (b) `dd17b84f`'s own description of v1. Both secondary.
5. **The 2026 date arithmetic on ShipItEZ** counts calendar rows, not damage *events*; a single
   operator action produces one message, but a multi-SKU unit-load deletion produces one message
   containing several items. Row counts under-count items.

---

# Q5 — `adjustAmount`'s locked arms, and the general invariant

**Correction to the brief's citation, adopted:** the method is `StockunitService.adjustAmount`
(`"public Stockunit adjustAmount(Stockunit stockUnit, BigDecimal amount, String comment)"`), not
`setAmount`, and `diff = amount.intValue() - oldAmount.intValue()` is a **signed** delta on the stock
unit's own amount. The three arms are the `switch (stockUnit.getEntityLock())` beneath it.

## Q5.0 — Adjudicated from the OMS side at runtime, as instructed

The brief is right that the WMS call sites cannot corroborate either reading. So the question was put
to the consumer. **Four independent OMS-side instruments agree, and they are unanimous:
`quantity_on_hand` means SELLABLE.**

**Instrument 1 — the runtime derivation.** `LegacyInventoryAdjustService::applyReconciledCounters`,
which runs on **every** incremental update (called from `applyInventoryQuantities` immediately after
the delta loop):

```php
$onHand = (int) $inventory->quantity_on_hand;
...
$reserved = min($unavailable, $onHand);
$inventory->quantity_allocated     = $allocated;
$inventory->quantity_inv_allocated = $reserved;
$inventory->quantity_available     = $onHand - $reserved;
```

`quantity_available = quantity_on_hand − reserved`. **Damaged, on-hold and missing are not subtracted.**
Under a gross model they would have to be. They are not. This is the answer the brief asked for: the
derivation *is* the contract, and it is unambiguous.

**Instrument 2 — the OMS says so in prose, in the same ticket that broke it.**
`app/Http/Controllers/Api/ProductInventoryController.php:505-510`:

> *"SBDEV-2671: the inventory model (v1 available_qty_by_client_method) is `quantity_available =
> quantity_on_hand - quantity_inv_allocated` (reserved stock), clamped at 0. **quantity_on_hand already
> excludes damaged / missing / on-hold (they are parallel buckets, netted out at WMS ingestion)**, so
> subtracting them again double-counts."*

Note what that comment asserts: the buckets are *"netted out at WMS ingestion."* **That is exactly what
`dd17b84f` deleted from the incremental path, in the same ticket.** The OMS codebase now contradicts
itself across two files: this comment says ingestion nets, and `applyInventoryQuantities` no longer
does. Both were written under SBDEV-2671.

**Instrument 3 — a report query that only type-checks under the sellable model.**
`app/Http/Controllers/Api/Reporting/InventoryReportController.php:350`:

```php
$query->where(DB::raw('pi.quantity_on_hand + pi.quantity_damaged'), '>', 0);
```

"Does this row hold any stock at all" is expressed by **adding** damaged to on-hand. Under a gross
model that double-counts every damaged unit. It is only correct if `quantity_on_hand` excludes them.
(The parallel row at `:439` does the same over `pih` history.)

**Instrument 4 — the gross formula exists and is explicitly forbidden.**
`app/Models/ProductInventory.php:133-142` carries the gross derivation
(`on_hand − inv_allocated − onhold − damaged − missing − in_transfer`) **commented out**, under
`// Placeholder - DO NOT USE without verifying SP logic`. The gross model was considered and rejected.

**Conclusion.** The good-units-only reading is the one the v2 OMS implements at runtime. The two
conventions no longer coexist in the v2 OMS — the gross one survives only in v1, and in the `!$addToExisting`
snapshot branch. *Blind spot:* all four instruments are `origin/develop`; I did not observe the running
build (same limitation as Q3), and I have no OMS DB to confirm `quantity_available = quantity_on_hand −
quantity_inv_allocated` holds in live rows.

## Q5.1 — Verdict on each arm

| arm | args `(normal, damaged, missing, onHold, transfer)` | Δsellable (truth) | verdict |
|---|---|---|---|
| `ON_HOLD` | `(diff, 0, 0, diff, 0)` | **0** — the unit is already on-hold; only its quantity changed | **WRONG** — overstates sellable by `diff` |
| `QUALITY_FAULT` | `(diff, diff, 0, 0, 0)` | **0** — already damaged | **WRONG** — overstates sellable by `diff` |
| `NOT_LOCKED` | `(diff, 0, 0, 0, 0)` | `diff` | **CORRECT** |

**The remedy is `normal = 0`, not `normal = −diff`.** The brief's refinement #2 is right and it matters:
these are **single-bucket deltas**, not bucket moves. Nothing crosses a boundary. `−diff` would drive
sellable down by `diff` on an edit that never touched sellable stock — a new defect in the opposite
direction. Correct calls: `(0, 0, 0, diff, 0)` and `(0, diff, 0, 0, 0)`.

Both arms are wrong for the **same reason** as E7's three sites — a non-sellable quantity landing in
`normal` — but by a **different mechanism**, and with a different fix. Any remediation that treats them
as one class and applies one arithmetic fix will break half of them.

## Q5.2 — The invariant: the brief's candidate is necessary but NOT sufficient, and it over-confirms

### First, a count correction

`git grep -n "getStockChangeDTO" origin/develop -- src/main/java` returns 20 hits = **2 declarations**
(`SharedService:119`, `:129`) + **1 internal forward** (`SharedService:120`, the 7-arg overload
delegating to the 8-arg form) + **17 business call sites**. E7 and my own Q4 table said "18 call sites";
that counted the internal forward. 17 sites, 18 behavioural cases (`UnitloadService:582` branches on
`entityLock`).

### Testing `"a delta to non-sellable stock is not a delta to normal"`

| case | site | sent | correct | flagged by candidate? | actually wrong? |
|---|---|---|---|---|---|
| A | `StockunitService:609` transferStock→Damaged | `(0,+N,0,0,0)` | `(−N,+N,0,0,0)` | **no** | **YES** (overstate) |
| B | `StockunitService:723` setLockOnHold | `(0,0,0,+N,0)` | `(−N,0,0,+N,0)` | **no** | **YES** (overstate) |
| C | `StockunitService:786` setLockDamaged | `(0,+N,0,0,0)` | `(−N,+N,0,0,0)` | **no** | **YES** (overstate) |
| D | `StockunitService:835` adjustAmount/ON_HOLD | `(diff,0,0,diff,0)` | `(0,0,0,diff,0)` | **yes** | YES |
| E | `StockunitService:838` adjustAmount/QUALITY_FAULT | `(diff,diff,0,0,0)` | `(0,diff,0,0,0)` | **yes** | YES |
| F | `StockunitService:841` adjustAmount/NOT_LOCKED | `(diff,0,0,0,0)` | same | no | no ✅ |
| G | `StockunitService:936` removeLock/QUALITY_FAULT | `(0,−N,0,0,0)` | `(+N,−N,0,0,0)` | **no** | **YES** (understate) |
| H | `StockunitService:939` removeLock/ON_HOLD | `(0,0,0,−N,0)` | `(+N,0,0,−N,0)` | **no** | **YES** (understate) |
| I | `MobileMoveUnitloadService:560` setStockDamaged | `(0,+N,0,0,0)` | `(−N,+N,0,0,0)` | **no** | **YES** (overstate) |
| J | `MobileMoveUnitloadService:599` removeStockDamaged | `(0,−N,0,0,0)` | `(+N,−N,0,0,0)` | **no** | **YES** (understate) |
| K | `UnitloadService:582` delete/NOT_LOCKED | `(−N,0,0,0,0)` | same | no | no ✅ |
| L | `UnitloadService:582` delete/QUALITY_FAULT | `(−N,−N,0,0,0)` | `(0,−N,0,0,0)` | **yes** | YES (understate) |
| M | `UnitloadService:582` delete/ON_HOLD | `(−N,0,0,−N,0)` | `(0,0,0,−N,0)` | **yes** | YES (understate) |
| N–R | receiving ×4, cycle-count ×2 | `(N,0,0,0,0)` | same | no | no ✅ |

**Result: the candidate catches 4 of 12 defects (D, E, L, M) and is blind to 8 (A, B, C, G, H, I, J).**

**It over-reaches in the way that matters most.** The brief asked me to check `StockunitService:936` and
`MobileMoveUnitloadService:599` — cases **G** and **J** — and said *"if those are correct, your invariant
must not flag them."*

**They are not correct.** Both release stock *out of* the damaged bucket and back into sellable service.
The true Δsellable is **+N**; they send `normal = 0`. Under today's OMS the damaged bucket drains and
**nothing is added back to sellable — the stock silently vanishes from OMS availability.** Same for
case H (on-hold release). The candidate invariant would pass all three as clean, because they respect
"no non-sellable delta in `normal`" while omitting the *sellable* half of the move.

**So the candidate is a one-sided rule.** It constrains what must NOT be in `normal` and says nothing
about what MUST be. Eight of the twelve defects are omissions, not misplacements. Built as a rail, it
would green-light G, H and J permanently.

### The invariant that does hold

> **`normal` is the signed delta to SELLABLE units; each bucket field is the signed delta to that
> bucket; and every stock movement must report BOTH of its endpoints.** A move from bucket X to bucket Y
> of N units reports `X: −N` and `Y: +N`, where "sellable" is the bucket named `normal` and "outside the
> warehouse" is the absent bucket that receives no field. A quantity change *within* one bucket reports
> that bucket alone.

Tested against all 18 cases above: it flags exactly the 12 that are wrong and clears exactly the 6 that
are right (F, K, N–R). No false positives, no false negatives.

**So the answer to the question the factory design turns on: the invariant is about
NON-SELLABLE STOCK GENERALLY — and it is broader still.** It is not about damage (that would miss
on-hold: cases B, D, H, M). It is not even about non-sellable stock alone (that would miss the sellable
endpoint: cases A, B, C, G, H, I, J). **It is a conservation law over all buckets including sellable.**
A rail built on "damage" covers 5 of 12; a rail built on "non-sellable" covers 4 of 12; only the
conservation law covers all 12.

### What that implies for the factory's shape

The current factory takes five positional `int`s, which is precisely the representation that makes an
omitted endpoint invisible — `(0, +N, 0, 0, 0)` looks complete. A factory that enforces the invariant
cannot take buckets as independent numbers. It must take **a movement**:

```
stockMove(itemData, FROM_BUCKET, TO_BUCKET, qty, comment, activityCode)   // both endpoints, derived
stockAdjust(itemData, BUCKET, signedDelta, comment, activityCode)         // within one bucket
```

with buckets `SELLABLE | DAMAGED | ON_HOLD | MISSING | IN_TRANSFER | EXTERNAL`, and the five ints
derived rather than supplied. Under that API every one of the 18 cases has exactly one spelling and the
12 defects become unrepresentable — `setLockDamaged` is `stockMove(SELLABLE → DAMAGED, N)`, `removeLock`
is `stockMove(DAMAGED → SELLABLE, N)`, `adjustAmount`/QUALITY_FAULT is `stockAdjust(DAMAGED, diff)`,
`deleteUnitLoad` of damaged stock is `stockMove(DAMAGED → EXTERNAL, N)`, receiving is
`stockMove(EXTERNAL → SELLABLE, N)`.

**Caveat the plan must carry:** this is only correct against the *post-`dd17b84f`* OMS. If the Q1–Q4
recommendation is taken instead — restore netting on the incremental path — then all 18 current call
sites are already correct and **the factory must not be built at all**, because it would encode the
opposite convention. These two remediations are mutually exclusive and the contract decision (Q3/Q4)
must be settled **before** the factory is designed, not after.

## Q5.3 — `missing` and `transfer`: never written by the WMS

Instrument: positional extraction of the argument list at all 17 business call sites (argument 3 =
`missing`, argument 5 = `transfer`). **Both are the literal `0` at every site.**

**Positive control on the zero:** the identical extraction shows non-zero values in the neighbouring
bucket positions — argument 2 (`damaged`) is non-zero at 6 sites and argument 4 (`onHold`) at 4 sites.
The parser can see non-zero bucket arguments; the zero at positions 3 and 5 is a true zero, not a
broken instrument.

*Blind spots:* (a) the extraction is textual over the argument list and would mis-split an argument
containing a comma — inspected, none exists; the only compound arguments are comma-free
`.intValue()` / `.negate().intValue()` chains. (b) A caller bypassing the factory would be invisible —
ruled out separately in Q4 (`new StockChangeDto` occurs once, inside the factory).

**So `missing` and `transfer` cannot carry this defect today** — no WMS operation writes them. Two
consequences the plan needs:

1. The OMS's `quantity_missing` and `quantity_in_transfer` are fed **only** by the snapshot path
   (`StockCountDto.missing` / `.transfer` via `stockCountExport`), never incrementally. Any drift in
   those two columns is corrected wholesale at the next full count, which is a materially different
   risk profile from `damaged` / `onhold`.
2. The rail must still **permit** them. A `MISSING → SELLABLE` or `SELLABLE → IN_TRANSFER` move is
   well-formed and the snapshot path already uses both buckets; a factory that omits them because "the
   WMS never sends them" would block the next feature that needs one.

## Q5.4 — The clamp, and what it does to backfill

`applyInventoryQuantities`:

```php
$inventory->{$column} = max(0, $newValue); // inventory can never go negative
```

Per column, silently, with no record that it fired.

### Where the pre-clamp payload survives — and where it does not

| store | what it holds | usable to recover the payload delta? |
|---|---|---|
| OMS `product_inventory_history` | **mixed snapshot**: `quantity_on_hand` and `quantity_available` are the values *before* the change; every other column is the value *after*. No deltas at all. | **No** — and the mixture is a trap for anyone reading it as a uniform snapshot |
| OMS `product_update_history.*_adj` | **APPLIED (post-clamp)** deltas, computed as `$inventory->{col} − $originalQuantities[{col}]` | **No** — post-clamp by construction |
| OMS Laravel log (`logLegacyRequest` → `request_data`) | the raw payload | In principle yes; in practice application logging — rotated, unqueryable, not an audit store |
| **WMS `message.message`** | **the full serialized `List<StockChangeDto>` JSON, retained permanently, per tenant** | **YES — this is the durable pre-clamp record** |

So the brief's concern is well-founded on the OMS side and resolved on the WMS side: **the payload
delta is not recoverable from the OMS, but it is recoverable from the WMS.** Every payload quoted in
Q1/Q2 of this report came out of `message.message`.

That yields a usable clamp detector: join WMS `message` rows (payload delta) against OMS
`product_update_history` (`*_adj`, applied delta) on SKU + facility + timestamp; **any mismatch is a
clamp**. Constraints: `product_update_history` only exists since `8814ac3d` (2026-08-11) and is written
only when `$addToExisting && config('inventory.adjustment_alert.enabled', true)`, so the detector has
no reach before that date or with the kill switch off.

### But sizing total drift is still a reconciliation, not a replay — for a second reason

Even with the payload fully recoverable, summing WMS deltas cannot reproduce a row's history, because
`product_inventory` has **other writers**: the snapshot path (`processStockCount`), the sibling
`/services/call` path (`LegacyProductUpdateService`), the scheduled reconciliation sweep,
`ProductInventoryController` direct edits, and `applyReconciledCounters`' own deallocation. The clamp
makes replay lossy; the multiple writers make it wrong even if it were lossless.

**Sizing the drift requires a point-in-time reconciliation of OMS `product_inventory` against WMS stock,
per SKU per facility.** That is a query I could not run — no OMS MySQL MCP in this session.

### The clamp's asymmetry cuts against us

Mapping the clamp onto the twelve defects:

- The **six overstating** cases (A, B, C, D, E, I) push `quantity_on_hand` **up**. `max(0, …)` never
  fires on an increase. **This drift is unbounded and accumulates monotonically.**
- The **six understating** cases (G, H, J, L, M, and the bucket half of the others) push
  `quantity_damaged` / `quantity_onhold` **down**, which is exactly where `max(0, …)` bites.

So the clamp preferentially truncates the *understating* direction, which means the two errors **cannot
be assumed to offset** — and the residue after clamping is biased **toward overstating sellable**. The
overselling exposure is the unbounded one. That strengthens, rather than weakens, the Q1–Q4 conclusion.

**Empirically unmeasured:** whether any clamp has actually fired on any tenant. No OMS DB access. On
Hydra PRD it is moot — 0 of 23 messages carried a non-zero bucket, so no clamp-eligible delta has ever
been sent there.

## Q5 — answers, restated plainly

1. **`adjustAmount` ON_HOLD arm: WRONG.** `adjustAmount` QUALITY_FAULT arm: **WRONG.** NOT_LOCKED arm:
   **CORRECT.** Both remedies are `normal = 0` (never `−diff`).
2. **The candidate invariant over-reaches in one direction and under-reaches in the other:** it catches
   4 of 12 defects and would permanently green-light `StockunitService:936`, `:939` and
   `MobileMoveUnitloadService:599`, which are themselves defective (they omit the `+N` sellable
   endpoint). The invariant that holds is a **conservation law across all buckets including sellable** —
   *every movement reports both endpoints* — and the factory must take a movement, not five ints.
   It is **not** about damage, and **not** merely about non-sellable stock.
3. **`missing` and `transfer` are never written by the WMS** (literal `0` at all 17 sites, with a
   positive control), so they carry no drift today — but the rail must still permit them, because the
   snapshot path uses both.
4. **Build the factory only if the no-netting contract is confirmed as intended.** If netting is restored
   instead (the Q1–Q4 recommendation), all 17 sites are already correct and the factory would encode the
   wrong convention. **Settle the contract first.**
