# P2 transfer delete: OMS-side trace

Source: `origin/develop` at `ab83f75e` (fetched 2026-10-21). Repo: `/home/nampark/dev/wms-claude/v2/oms-laravel-api`. All paths below are relative to that repo; quotes are from `git show origin/develop:<path>`.

## 1. What closeTransfer / completeTransfer write at destination and source

Entry chain:
- `routes/legacy-services.php:103` — `Route::post('closeTransfer', [LegacyWmsController::class, 'closeTransfer'])`
- `LegacyWmsController::closeTransfer` (line 3921) passes the raw `$request->all()` to `LegacyTransferCloseService::closeTransfer`.
- `app/Services/Legacy/LegacyTransferCloseService.php:52` — the only fields read from the WMS body are `transfer_id`: `if (!isset($transferData['transfer_id'])) {`. Quantities in the accept call are never read.
- `LegacyTransferCloseService.php` (~line 106): `$transferResult = $this->transferCompleteService->completeTransfer($parcelId, 1);`
- `getTransferInformation` is in `app/Services/Legacy/Traits/ResolvesTransferId.php:34`.

`app/Services/Legacy/LegacyTransferCompleteService.php`:
- `:95` `public function completeTransfer(int $parcelId, int $repId): array`
- Idempotency guard: `->whereIn('parcel_status', [self::STATUS_DELIVERED, self::STATUS_CANCEL])` then `'status' => 'NOOP'`. The close service treats any non-SUCCESS as failure (`if ($transferResult['status'] !== 'SUCCESS') { ... 'status' => 'FAILURE'`), so a re-sent closeTransfer after success returns FAILURE to WMS, not a second credit.
- Quantity source is the OMS transfer order's `order_item.quantity`, not the WMS accept call. `:343-350`: `$orderItems = $this->db()->table('order_item as oi') ... ->select('oi.product_id', 'oi.quantity')->get();`
- Source decrement (`:355-364`):
  `'quantity_in_transfer' => DB::raw("GREATEST(quantity_in_transfer - {$item->quantity}, 0)"),`
  `'quantity_on_hand' => DB::raw("GREATEST(quantity_on_hand - {$item->quantity}, 0)"),`
  `'quantity_allocated' => ...`, `'quantity_inv_allocated' => ...`
- Destination increment (`:367-374`):
  `'quantity_on_hand' => DB::raw("quantity_on_hand + {$item->quantity}"),`
  `'quantity_available' => DB::raw("quantity_available + {$item->quantity}"),`
  Raw SQL increments. No call to `applyReconciledCounters`, no `quantity_in_transfer` change at destination, no history row.
- Lock step (`:255-272`) locks `piDest` but writes are only the two updates above.
- Post-commit: `dispatchReallocationForDestination` (`:316`) queues `InventoryReallocationDispatcher::onIncrease` (queued, not traced).

Initiate side (`app/Services/Legacy/LegacyTransferInitiateService.php:336`):
`'pi.quantity_in_transfer' => DB::raw('pi.quantity_in_transfer + oi.quantity'),`
So source on_hand is unchanged at ship; source in_transfer rises by `order_item.quantity`, and completeTransfer later drops both on_hand and in_transfer by the same amount. The destination gets nothing at ship time.

Dead-end: `app/Services/Legacy/LegacyInventoryTransferService.php:140` `completeTransfer(string $transferId)` is a stub (`// For now, we'll return a success response`, no inventory writes). It is not on the closeTransfer path.

Answer to Q1: destination on_hand and quantity_available are credited by `order_item.quantity` (the shipped/ordered line quantity) at the moment closeTransfer succeeds. The WMS accept quantities are ignored. Source on_hand, in_transfer, allocated, and inv_allocated are decremented by the same amount.

## 2. How an inbound STOCK_UPDATE row is applied

- `routes/legacy-services.php:69` — `Route::post('stockUpdate', [LegacyWmsController::class, 'stockUpdate'])`. The controller that handles stockUpdate is `app/Http/Controllers/Api/Legacy/LegacyInventoryController.php` (~line 320): `$result = $this->inventoryAdjustService->processStockUpdates($updates, $source, $batchId);`
- `app/Services/Legacy/LegacyInventoryAdjustService.php:477` `processStockUpdates`: one DB transaction per row (`$this->db()->beginTransaction(); $result = $this->processWMSUpdate(...)`).
- `:685` `processWMSUpdate` maps `normal` to the on-hand delta:
  `$onHand = $update['normal'] ?? $update['quantity_on_hand'] ?? null;` then `$raw['quantity_on_hand'] = $onHand;`
  `activity_code` is read (`$activityCode = $update['activity_code'] ?? null;`) and only passed through to `applyInventoryQuantities` as a label.
- `:943` `applyInventoryQuantities(..., $addToExisting = true, ...)`:
  - Lookup: `Client::where('client_code', $clientNumber)` then `Product::where('product_sku', trim($sku))->where('client_id', ...)`, then `ProductInventory::where('product_id', ...)->where('facility_code', $facilityCode)->lockForUpdate()`. A missing row is created with zeros.
  - Netting is explicitly skipped on the incremental path (comment at ~`:1027-1041`): "The incremental stock-update path ($addToExisting = true) is NOT netted".
  - Apply (`:1050-1052`):
    `$newValue = $addToExisting ? ((int) $inventory->{$column} + (int) $value) : (int) $value;`
    `$inventory->{$column} = max(0, $newValue); // inventory can never go negative`
  - So `normal: -12` on an existing row changes **`product_inventory.quantity_on_hand` by -12, floored at 0**. No other column moves (`quantity_in_transfer` only changes if a `transfer` key is present).
- `:357` `applyReconciledCounters` then runs (`$inventory->save()` follows):
  - `$reserved = min($unavailable, $onHand);` / `$inventory->quantity_available = $onHand - $reserved;` (`:437-438`).
  - If `$unavailable > $onHand`, it calls `LegacyProductDeallocateService::deallocateProduct` (~`:385`), releasing order reservations at that facility. Deallocation is driven by on-hand only; `quantity_in_transfer` is not consulted.
- Activity code: `:1146-1158` `ACTIVITY_CODE_TO_LUT_KEY` maps `MANUAL_REMOVAL => 'MANUAL_REMOVAL'`, `RECEIVING => 'RECEIVING'`. It is used only for `product_update_history` / `product_update_type_id` (`:1095`) and history labels. Quantity math has no branch on activity_code.
- Alert side effect: `app/Services/InventoryAdjustmentAlertDispatcher.php:27` lists `'MANUAL_REMOVAL'` in `ALERT_ACTIVITY_CODES` (queued/after-commit, never throws). This is notification only.
- Validation (`:610-684`) requires `sku`, `facility_code`, a client identifier, and at least one numeric quantity. It does not look at activity_code or open transfers.
- No in-transit awareness: grep found no reference to `quantity_in_transfer` in `LegacyInventoryAdjustService` apart from pass-through, and no check against `transfer_destination` or open `bol`/transfer state.

Answer to Q2: `normal: -12`, MANUAL_REMOVAL, facility X → `product_inventory.quantity_on_hand` for (product, facility X) becomes `max(0, on_hand - 12)`; `quantity_available` is recomputed as `on_hand - min(reserved, on_hand)`. activity_code only selects the history/alert label. There is no special case for MANUAL_REMOVAL, RECEIVING, or in-transit stock.

## 3. Does OMS react to a destination RECEIVING / TRANSFER advice?

- `RECEIVING` appears only in the label map (`LegacyInventoryAdjustService.php:1157`) and the `InventoryAdjustmentAlertDispatcher` list does not include it.
- Advice-related handlers: `LegacyWmsController::closeAdvice` (`:3822`) → `app/Services/Legacy/LegacyAdviceCloseService.php:38` `closeAdvice`. Grep for `product_inventory`/quantity writes in that file found none; it builds a receipt notification (`sendInventoryReceiptNotification`, `:214`) and a callback payload (`prepareApiCallbackData`, `:241`). It is for advice closure, not transfers.
- `receiveHubAndSpoke` (`LegacyHubAndSpokeReceiveService.php:53`) is a separate hub/spoke path, not on the transfer path.
- `createTransferAdviceFromBol` (`app/Services/WmsApiService.php:2775`) is outbound (OMS → destination WMS PUT `advice_create_transfer`); it writes nothing to OMS inventory.

Answer to Q3: no handler reacts to a destination receive. OMS learns of the transfer's arrival only from `closeTransfer` (ADVICE_ACCEPT_TRANSFER). Destination credit comes solely from completeTransfer.

## 4. Destination arithmetic for a post-receipt MANUAL_REMOVAL of transfer goods

Notation: B = OMS destination on_hand before the transfer closes (assume it equals WMS on_hand before receipt). Q = `order_item.quantity` of the transfer (credited by completeTransfer). n = units the WMS deletes with MANUAL_REMOVAL (`normal: -n`). Q_acc = units WMS accepted.

WMS destination on-hand after receipt and delete: B + Q_acc − n.

(a) Delete BEFORE accept/closeTransfer:
- STOCK_UPDATE runs first on OMS on_hand B: `max(0, B − n)`. The delete consumes pre-existing stock, not the in-transit units OMS has not yet counted.
- closeTransfer then adds Q: OMS = `max(0, B − n) + Q`.
- Without clamp (B ≥ n): OMS = B − n + Q, identical to WMS if Q_acc = Q.
- With clamp (B < n): `max(0,B−n)+Q = Q`, while WMS = `B+Q_acc−n`. Overstatement = `Q − (B + Q_acc − n)` = `(n − B) + (Q − Q_acc)`.
  Example: B = 0, Q = 10, n = 10, Q_acc = 10 → WMS 0, OMS 10 (phantom +10).
- Side effect: the pre-close delete can push reserved above on_hand, so `applyReconciledCounters` deallocates destination orders (`:437-438`; deallocate call ~`:385`, `LegacyProductDeallocateService`) for stock that OMS had not yet credited. These orders can enter exception until `dispatchReallocationForDestination` runs after close.

(b) Delete AFTER closeTransfer:
- After close OMS on_hand = B + Q. Delete: `max(0, B + Q − n)`. Clamp cannot fire when n ≤ Q (because B+Q ≥ n).
- OMS = B + Q − n. WMS = B + Q_acc − n. Overstatement = `Q − Q_acc` only.
- So (b) is arithmetically correct whenever the WMS deletes exactly the units it did not accept or keeps accepted units; the only residual is the accept-quantity gap, which closeTransfer never reads. If WMS accepts Q_acc < Q and does not send a delete for the shortfall, OMS holds `Q − Q_acc` phantom units.

Double count / negative summary:
- Unclamped, the order of (a) vs (b) does not change the final value (addition/subtraction commute). The divergence is the `max(0, ·)` clamp at `:1052`, which only bites in (a) when n > B. Result: OMS over-counts by `n − B` (never goes negative in OMS; WMS is the one that would be 0 for those goods).
- Source side is not covered here; source on_hand can also clamp at 0 via `GREATEST(... , 0)` at `LegacyTransferCompleteService.php:~360`.
- A replayed STOCK_UPDATE is not deduplicated: `batch_id` is only logged (`LegacyInventoryAdjustService.php:569`), and no idempotency key exists in `processWMSUpdate`. A WMS retry applies `-n` twice (OMS under-counts by n). Replayed closeTransfer is safe (NOOP → FAILURE to WMS).

## Blind spots

- Queued/after-commit jobs not traced: `InventoryReallocationDispatcher::onIncrease` (called from completeTransfer `:316` and processStockUpdates), `InventoryAdjustmentAlertDispatcher::onAdjustments`, `InventoryChanged` event, `ProductInventoryObserver` (`app/Observers/ProductInventoryObserver.php`, external inventory push on update) — could emit webhooks/pushes on each write; not read.
- Did not read `LegacyProductDeallocateService` internals (order-item reservation release) or `LegacyQuantitiesByClientMethodService`; the reserved/available math is taken from their names and call sites.
- Did not verify the shipped quantity (what `order_item.quantity` equals after finishedShipping/parcel ship); assumed Q = shipped.
- DB triggers: `CREATE TRIGGER` grep over `database/` on origin/develop returned nothing; the one trigger migration (`2026_08_07_200000_drop_legacy_trigger_inventory_product.php`) drops a legacy trigger. Did not inspect the live tenant DBs or `database/schema` dumps for triggers.
- Other OMS callers of product_inventory (LegacyProductUpdateService, LegacyClientController stock sync, batch/cron recalculation, InventoryReportController) were not traced for interaction with an in-flight transfer.
- Read from origin/develop only; the local checkout was not compared. WMS-side behavior (what it sends and when) is not verified here.

## Summary

- Destination credit happens only in `LegacyTransferCompleteService::updateInventoryForTransfer` (`:367-374`): `quantity_on_hand + order_item.quantity`, `quantity_available + order_item.quantity`, on closeTransfer success. WMS accept quantities are ignored (closeTransfer reads only `transfer_id`).
- Source: on_hand, in_transfer, allocated, inv_allocated all decremented by `order_item.quantity` (GREATEST 0) at the same moment.
- Ship time: source `quantity_in_transfer += order_item.quantity` (`LegacyTransferInitiateService.php:336`); destination untouched.
- STOCK_UPDATE `normal: -n` adds to `quantity_on_hand` (floored at 0, `:1052`), recomputes available, and deallocates orders if reserved exceeds on-hand. No activity_code or in-transit branch; MANUAL_REMOVAL only labels history and triggers an alert.
- No OMS handler reacts to destination RECEIVING or to TRANSFER advice receipt; `closeAdvice` writes no inventory.
- Case (b), delete after close: OMS = WMS except for accept-count gap (`Q − Q_acc`).
- Case (a), delete before close: OMS = `max(0, B−n) + Q`; overstates by `n − B` when `n > B` (clamp), e.g. B=0, Q=n=10 → OMS 10, WMS 0. Otherwise equal.
- Replayed STOCK_UPDATE is not idempotent (under-count); replayed closeTransfer is safe (returns FAILURE after NOOP).
- Blind spots: queued reallocation/alert jobs, ProductInventoryObserver pushes, deallocate internals, shipped-quantity assumption, live DB triggers, WMS-side send timing.
- Ready for: wms-triage/architect review of whether the WMS should send `transfer` deltas instead of `normal`, and whether the OMS should credit accepted quantities.
