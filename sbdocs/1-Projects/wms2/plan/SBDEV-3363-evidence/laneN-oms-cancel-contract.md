---
title: "SBDEV-3363 §10 Q2 — What OMS does on ORDER_BATCH_CANCELLED_FROM_WMS"
lane: laneN
date: 2026-09-16
status: evidence
sources:
  - oms-laravel-api origin/develop @ 7ae51e24bb381e7e4ca86215ed22ae17ab12f256
  - wms2-api          origin/develop @ e113467b4e0710d56fece47b8f264bc431b8c2fa
  - wms2-wineco-dev   los_sysprop (live query, 2026-09-16)
---

# Lane N — the OMS side of `ORDER_BATCH_CANCELLED_FROM_WMS`

**Bottom line.** OMS's handler is a **flat, unconditional, state-blind cancel**. It reads nothing
about the order's age, its OMS status, or whether it shipped. It is idempotent *only* against a
re-delivery of the same cancel (a compare-and-swap on `order_item_parcels.qa_status`), and it
credits `product_inventory.quantity_available` **unclamped and across every facility** the product
exists at. Whether the replay is safe therefore reduces entirely to one question this lane cannot
answer from code: *what is the current OMS-side state of those two parcels and their items?* If
their `order_item_parcels.qa_status` is already `28`, the replay is a **no-op**. If it is anything
else — including the `0` written at parcel creation — the replay **credits inventory and cancels
the rows**, regardless of what happened to the parcel in the seven months since February.

---

## 1. The entry point

**Route** — `oms-laravel-api`, `routes/legacy-services.php`:

```php
Route::prefix('services/call')->group(function () {
    ...
    Route::post('cancelPosition', [LegacyWmsController::class, 'cancelPosition'])
        ->name('legacy.wms.cancel-position');
```

**Middleware** — `bootstrap/app.php`; the group carries **only** `api`:

```php
Route::middleware('api')
    ->group(base_path('routes/legacy-services.php'));
```

There is **no authentication middleware** on this route. (Contrast, in the same file: the merchant
surface is `Route::middleware(['api', 'ensure.tenant', 'tenant', 'auth.external.api',
'throttle:external-api'])`.) WMS does send HTTP Basic (`HttpRestService.applyHeaders` →
`headers.setBasicAuth`), but nothing in this route's pipeline reads it. Derived by reading the whole
`withRouting`/`withMiddleware` block in `bootstrap/app.php`; blind spot: a global middleware
registered elsewhere (a service provider) would not appear there, and I did not sweep providers.

**Handler signature** — `app/Http/Controllers/Api/Legacy/LegacyWmsController.php`:

```php
public function cancelPosition(Request $request): JsonResponse
{
    $this->logLegacyRequest($request, 'cancelPosition', 'WMS');
```

**There is no `process_type` dispatch.** `git grep ORDER_BATCH_CANCELLED_FROM_WMS origin/develop`
in `oms-laravel-api` returns **6 hits, every one a comment or a test comment** — e.g.
`LegacyPositionCancelService.php`: `* Idempotent (SBDEV-2685): the WMS delivers
ORDER_BATCH_CANCELLED_FROM_WMS`. The string is never read as a field. Dispatch is by **URL**: the
WMS sysprop `WEBSERVICE_ORDER_BATCH_CANCELLED` holds the full endpoint, and `process_type` is a
WMS-internal outbox label only. *Positive control for the grep*: `git grep -c
ORDER_BATCH_REVERSAL_COMPLETED origin/develop` returns non-zero hits (2 doc files), so the
instrument works and a `git grep` is immune to the ugrep binary-skip trap.

**Where the POST actually goes, for this tenant.** Live query against `wms2-wineco-dev`
`los_sysprop`:

| syskey | sysvalue |
|---|---|
| `WEBSERVICE_ORDER_BATCH_CANCELLED` | `https://api-oms.dev.sbo.li/services/call/cancelPosition` |
| `WEBSERVICE_ORDER_BATCH_CANCELLED_ACTIVATED` | `false` |
| `OMS_TENANT_ID` | `wineco` |
| `OMS_API_USER` | `api_user/…` |
| `MULTIWAREHOUSE_IDENTIFIER` | `WSL` |

`api-oms.dev.sbo.li` is the **v2 Laravel OMS** dev host: `sbdocs/3-Resources/architecture/
wms2-greenfield-db-provisioning.md` maps all `WEBSERVICE_*` syspropss to the provisioning flag
`--oms-api-base-url`, "e.g. `https://api-oms.dev.sbo.li/`", and `oms-laravel-api`'s own `.env.dev`
carries `REVERB_CLIENT_HOST=api-oms.dev.sbo.li`.

> ⚠ **`WEBSERVICE_ORDER_BATCH_CANCELLED_ACTIVATED=false` is inert — it does NOT gate this send.**
> `git grep SYSTEM_PROPERTY_WEBSERVICE_ORDER_BATCH_CANCELLED_ACTIVATED_KEY origin/develop -- src/main`
> in `wms2-api` returns exactly two hits: the constant declaration in `WmsConstants.java`, and a
> **commented-out** seed line in `UtilRestController.java` (`//        syspropService.createSystemProperty(...)`).
> No runtime consumer. Positive control: the sibling
> `SYSTEM_PROPERTY_WEBSERVICE_ORDER_BATCH_UPDATE_PRIORITY_ACTIVATED_KEY` **is** consumed, at
> `PriorityChangeNotificationService.java:110`. Do not plan on that `false` stopping anything.

### v1 OMS — could not determine, repo absent

`/home/nampark/dev/wms-claude/v1/oms` **does not exist on this machine** (`ls /home/nampark/dev/
wms-claude/v1/` → `carrier-integration label-automation qa-api qa-ui wms-api wms-mobile-ui
wms-web-ui`). I could not inspect the v1 Zend OMS source at all, so I cannot say what it would do
with this payload, nor whether its handler differs.

What I *can* say about routing: the WineCo-dev WMS points `WEBSERVICE_ORDER_BATCH_CANCELLED` at
`api-oms.dev.sbo.li`, which the evidence above identifies as the **v2 Laravel OMS**. The sysprop
census (`sbdocs/3-Resources/reports/260730-wms2-sysprop-current-value-census.md`) shows every v2
tenant's `WEBSERVICE_*` URL pointing at `api-oms.{dev,uat}.sbo.li`. So **this tenant talks to OMS
v2**, and the v1 handler is not on the path for the replay — but that conclusion rests on the
hostname mapping, not on a probe of the running service, and I did not make any outbound call.

---

## 2. The payload contract

### What WMS sends

Both emitters build the same `OrderBatchDto`. `CustomerorderService.cancelOrder`
(`wms2-api`, `src/main/java/net/aim_ai/wms/service/CustomerorderService.java`, ~:1015-1060):

```java
OrderDto orderDto = new OrderDto();
orderDto.setUniqueId(customerOrder.getExternalnumber());
orderDto.setPositions(orderPositionList);
...
orderBatchDto.setFacilityCode(warehouseId);
orderBatchDto.setBatchId(orderBatch.getBatchid());
orderBatchDto.setPositions(orderList);
```

`PickingorderBusinessService.cleanUpCancelledOrder` (~:740-750) — the **deferred-cancel** path,
which is the one the stuck orders will take:

```java
orderDto.setUniqueId(customerOrder.getExternalnumber());
orderDto.setPositions(java.util.Collections.emptyList());
orderBatchDto.setBatchId(batch.getBatchid());
orderBatchDto.setFacilityCode(syspropService.getSysvalue(...MULTIWAREHOUSE_IDENTIFIER_KEY));
orderBatchDto.setPositions(java.util.Collections.singletonList(orderDto));
```

JSON field names come from `@JsonProperty` on `OrderBatchDto` / `OrderDto` / `AbstractWebServiceDto`:

```json
{ "facility_code": "WSL",
  "batch_id":      "<customerorder_batch.batchid>",
  "positions":     [ { "unique_id": "<customerorder.externalnumber>", "positions": [ … ] } ],
  "event_version": <outbox row id> }
```

`event_version` is injected at dispatch (`OutboxDispatchService.withEventVersion`). Headers:
`Content-Type: application/json`, `Authorization: Basic …`, `x-tenant: wineco`,
`Idempotency-Key: CO-CANCELLED-<customerorder.id>`.

### What OMS reads and requires

```php
$validator = Validator::make($request->all(), [
    'batch_id'             => 'required|string',
    'positions'            => 'required|array|min:1',
    'positions.*.unique_id' => 'required|string'
]);
```

Then only: `$batchId = $request->input('batch_id');` and `$positions = $request->input('positions');`.

**Mismatches found:**

| # | Finding | Impact |
|---|---|---|
| M1 | OMS **ignores `facility_code` entirely** on this endpoint. It never scopes the batch, the parcel, or the inventory credit by facility. | Feeds directly into S1 below (cross-facility inventory credit). |
| M2 | OMS ignores the **nested** `positions[].positions[]` (the per-SKU `unique_id`/`amount`/`sku_id`/`number` array). It cancels **every** `order_item_parcels` row of the resolved parcel. So the direct-cancel path's line detail is decorative — and the deferred path sends `emptyList()` anyway, with **identical effect**. | The two WMS emitters are indistinguishable to OMS. Good for the replay: the deferred path is not a degraded payload. |
| M3 | OMS ignores the `Idempotency-Key` header and the `event_version` field. `git grep 'event_version\|Idempotency-Key\|idempotency' origin/develop -- app/Http/Controllers/Api/Legacy app/Services/Legacy` returns **only comments**. | WMS's dedup protects the *outbox*, not OMS. OMS's own idempotency is the CAS in §3. |
| M4 | The OpenAPI annotation on the handler says *"updates parcel status to **CANCELLED (5)**"*, but the code uses `private const STATUS_CANCEL = 28;`. `28` is the value every other cancel service uses (`LegacyOrderCancelService`, `OrderWmsRecallService`); `5` is `Returned` per `LegacyOrderCancelService`'s own comment. The **doc** is wrong, not the code. | Cosmetic, but it misleads anyone auditing this path. |

**`unique_id` resolution** — the only lookup that can make the replay a silent no-op:

```php
private function findParcelByUniqueId(string $uniqueId, int $batchCriteriaId): ?Parcel
{
    if (is_numeric($uniqueId)) {
        $parcel = Parcel::where('parcel_id', $uniqueId)->where('batch_criteria_id', $batchCriteriaId)->first();
        if ($parcel) { return $parcel; }
    }
    return Parcel::where('parcel_id_str', $uniqueId)->where('batch_criteria_id', $batchCriteriaId)->first();
}
```

and the batch: `BatchCriteria::where('batch_label', $batchId)->first()`.

So the replay only bites if **(a)** a `batch_criteria` row still exists with `batch_label` =
the WMS `batchid`, **and (b)** a `parcel` row exists in that batch whose `parcel_id`/`parcel_id_str`
equals the WMS `externalnumber`. Either miss yields an error string, not an exception — see §3.

---

## 3. The state machine

### There is no state guard. At all.

`app/Services/Legacy/LegacyPositionCancelService.php` is the whole of the business logic. It reads
`parcel_status` **nowhere** before acting. The only condition on the write is the CAS on
`qa_status`:

```php
private function cancelOrderItemParcel(OrderItemParcel $orderItemParcel): void
{
    $claimed = OrderItemParcel::where('order_item_parcel_id', $orderItemParcel->order_item_parcel_id)
        ->where(function ($query) {
            $query->whereNull('qa_status')
                ->orWhere('qa_status', '!=', self::STATUS_CANCEL);
        })
        ->update(['qa_status' => self::STATUS_CANCEL]);

    if ($claimed === 0) {
        return; // already cancelled (outbox re-delivery, or a hold-recall got there first)
    }

    $this->returnInventoryToAvailable($orderItemParcel->product_id, $orderItemParcel->assigned_quantity);
}
```

**The contrast that settles the "terminal state" question.** The OMS-initiated whole-order cancel,
`app/Services/Legacy/LegacyOrderCancelService.php`, carries exactly the guard this handler lacks:

```php
/**
 * Uncancelable parcel statuses (from legacy CancelValidator)
 * Same as order statuses plus 28=Cancelled (parcel already cancelled)
 */
private const UNCANCELABLE_PARCEL_STATUSES = [4, 5, 11, 12, 13, 14, 15, 16, 17, 18, 20, 21, 27, 28, 29];
```

(4 = Shipped, 5 = Returned, 11–18 = transport states, 20 = Destroyed, 21 = Damaged, 27 = Completed,
29 = Removed, per that file's own comment.) **`LegacyPositionCancelService` references no such
list.** Derived by reading the file end to end — it is 260 lines and quoted above in full substance;
its complete `use` block is `UsesTenantDatabase, BatchCriteria, Parcel, OrderItemParcel,
ProductInventory, Product, CountCacheRefreshDispatcher, DB, Log`. Blind spot: a guard could in
principle live in a global Eloquent scope on `Parcel`/`OrderItemParcel`; I checked the models' heads
and found only `UsesTenantConnection`/`HasFactory`/`GuardsNewSchema`, not a `booted()` cancel guard —
but I did not read those models in full.

Answering the four sub-questions directly:

**Already-cancelled?** The CAS makes it a true no-op per item: `$claimed === 0` → `return` before the
inventory credit. Parcel-level and batch-level writes are likewise transition-guarded:

```php
$updated = Parcel::where('parcel_id', $parcelId)
    ->where(function ($query) {
        $query->whereNull('parcel_status')->orWhere('parcel_status', '!=', self::STATUS_CANCEL);
    })
    ->update(['parcel_status' => self::STATUS_CANCEL]);
```

**Already shipped / invoiced / terminal?** **Nothing stops it.** A parcel at status 4 (Shipped) whose
items still carry the `qa_status => 0` written at creation (`ParcelCreationService`: `'qa_status' =>
0, // Not yet QA'd`) satisfies `qa_status != 28`, so the CAS claims them, sets them to 28, **credits
inventory for goods that physically left the building**, and then — since no active items remain —
flips `parcel_status` to 28 over the Shipped status. This is the single most dangerous property of
the endpoint.

**Unexpected state?** Never an exception and never a refusal — it **forces the transition**. The only
non-forcing outcomes are the two *lookup misses*, and both are soft: a missing batch returns
`status: 'FAILURE'` with `"Batch '{$batchId}' not found"`; a missing parcel appends
`"Parcel '{$uniqueId}' not found in batch '{$batchId}'"` to `$errors` and continues the loop.

**Idempotent?** **Yes, against replay of the same cancellation** — and deliberately so (SBDEV-2685,
quoted in the file's own javadoc). Second delivery: every CAS returns 0, no inventory moves, the
parcel/batch guards no-op, `cancelled_count` is still incremented (it counts *parcels processed*,
not *items claimed*), and the response is `Status: Success`. It is **not** idempotent in the sense
that matters here: idempotency is keyed on `qa_status === 28`, not on "this cancellation was already
applied". A first-ever delivery to a stale order is a **first** application, whatever else happened
to the order in between.

### Response codes → will WMS retry?

| OMS outcome | HTTP | WMS `OutboxDispatchService` verdict |
|---|---|---|
| all parcels resolved | **200** `{"Status":"Success",…}` | 2xx → `markSent` |
| some/all parcels not found; batch not found | **200** `{"Status":"Error",…}` | 2xx → `markSent` — **a refusal is recorded as delivered** |
| validation failure (`batch_id`/`positions` malformed) | **422** | `isTerminal(422) → true` → `FAILED_TERMINAL` on attempt 1 |
| unhandled exception | **500** (`handleLegacyException` → `legacyErrorResponse($message, null, 500)`) | retry with backoff, then terminal at `max-attempts` |

```php
private boolean isTerminal(int statusCode, int attempts) {
    if (statusCode == 400 || statusCode == 404 || statusCode == 422) return true;
    return attempts >= maxAttempts;
}
```

So the realistic failure mode is **not** a retry storm — it is the 200-with-an-error-body case, where
WMS records `SENT` and nobody learns OMS did nothing. (WMS's `recordOmsVerdict` is Phase-1
observation only: *"the caller still marks the row SENT for every 2xx"*.)

⚠ A `FAILED_TERMINAL` row is not free: per `OutboxMessageRepository.findAndClaimPending`'s
head-of-line `NOT EXISTS` clause, **one terminal `CUSTOMER_ORDER` row wedges every later
`CUSTOMER_ORDER` message for that aggregate id until an operator clears it.** A malformed replay
payload (→ 422) would therefore also block that order's future reversal/priority/picking-date
notifications.

---

## 4. Side effects, ranked by blast radius

**S1 — Inventory credit, unscoped by facility and unclamped. This is the finding.**

```php
private function returnInventoryToAvailable(int $productId, int $quantity): void
{
    ProductInventory::where('product_id', $productId)
        ->update([
            'quantity_allocated' => DB::raw("GREATEST(quantity_allocated - {$quantity}, 0)"),
            'quantity_available' => DB::raw("quantity_available + {$quantity}")
        ]);
}
```

`product_inventory` has `facility_code` **and** `client_id` columns (`app/Models/
ProductInventory.php` `$fillable`). This `WHERE` uses neither. Compare the OMS-initiated path,
`LegacyOrderReturnToInventoryService::returnItemToInventory`, which does all four things this one
does not:

```sql
UPDATE product_inventory AS pi
SET pi.quantity_available      = GREATEST(LEAST(pi.quantity_available + (? * ?), pi.quantity_on_hand), 0),
    pi.quantity_inv_allocated  = GREATEST(pi.quantity_inv_allocated - (? * ?), 0),
    pi.quantity_allocated      = GREATEST(pi.quantity_allocated - ?, 0)
WHERE pi.product_id = ?
  AND BINARY UPPER(pi.facility_code) = BINARY UPPER(?)
```

Divergences, each independently a risk on a stale replay:
1. **no `facility_code` filter** → the credit lands on **every** facility row for that product;
2. **no `LEAST(…, quantity_on_hand)` clamp** → `quantity_available` can exceed on-hand → oversell;
3. **no `inventory_assigned` gate** → credits `assigned_quantity` whether or not stock was ever
   actually reserved;
4. **`quantity_inv_allocated` is never decremented**, so the two allocation counters drift apart.

Conditional on: the CAS claiming at least one item (`$claimed !== 0`). If every item is already
`qa_status = 28`, **no inventory moves at all**.

**S2 — Status writes.** `order_item_parcels.qa_status → 28`; `parcel.parcel_status → 28` if no
active items remain; `batch_criteria.batch_status → 28` if no active parcels remain. All are
**mass updates**, so **no Eloquent observer fires** — `ParcelObserver`'s own javadoc says so:
*"Non-Eloquent parcel writers (mass updates, raw SQL) never reach this observer."*

**S3 — Internal cache/broadcast refresh only.** The one deliberate side effect:

```php
if ($updated > 0) {
    app(CountCacheRefreshDispatcher::class)->refreshParcelWriteSideEffects($parcelId);
}
```

That fans out to `OrderSummaryBroadcastDispatcher` (a Reverb websocket summary to any OMS UI session
watching that order) and `UpdateGroupCountsJob` / `UpdateShipperCountsJob` (cached fulfillment
buckets). Both are guarded and never rethrow. Conditional on the parcel-status write actually
changing a row.

**S4 — Logging.** `logLegacyRequest` writes the **full request body** to the Laravel log at INFO;
`LogActivity` middleware appends an activity-log row. No PII beyond order identifiers is in this
payload.

**What does NOT happen** — enumerated by reading `LegacyPositionCancelService`'s complete `use`
block and the `cancelPosition` method body end to end, then confirming the one ambiguous symbol by
line number:

- **No customer email / notification.** No `Mail`, `Notification` or mailable is referenced in the
  service, the handler, `OrderSummaryBroadcastDispatcher`, or either counts job.
- **No carrier call and no label void.** `LabelVoidDispatcher` *is* imported by
  `LegacyWmsController` — but its single use site is **line 2992, inside `held()`** (which spans
  2817–3035), not inside `cancelPosition()` (3784–3855). `LegacyOrderCancelService` imports
  `LabelVoidDispatcher`; `LegacyPositionCancelService` does not.
- **No refund / payment call.** No payment service in the path.
- **No downstream event back to WMS.** The handler is terminal; it emits nothing.
- **No `parcel_status_history` / `order_status_history` row.** The mass update writes the status
  column only, so the cancellation leaves **no audit trail** on the parcel timeline.

*Blind spot on all five:* this is a two-hop enumeration (the service's imports plus the one
dispatcher it calls and that dispatcher's two jobs). A side effect reached through a DB trigger, a
queue listener bound to a model event (there is none, since mass updates fire none), or a
scheduled job that polls for `parcel_status = 28` would not appear. I did not sweep the scheduler.

---

## 5. What makes a *stale* cancellation specifically dangerous

**There is no age check anywhere on this path.** `git show origin/develop:app/Services/Legacy/
LegacyPositionCancelService.php | grep -n 'now()\|Carbon\|subDays\|diffIn\|created_at\|order_date\|
shipping_date\|billing'` → **zero hits**. Positive control: the same grep against
`LegacyOrderCancelService.php` returns 4 `now()` hits, and `LegacyWmsController.php` returns ~20 —
so the instrument finds what is there. No idempotency window, no reconciliation cursor, no
accounting-period fence, no "order too old to cancel" rule. **February is exactly as cancellable as
today.**

That absence is the danger, not a comfort. The concrete stale-specific hazards:

1. **The seven-month gap is where the order changed state, and the handler cannot see it.** Every
   guard that would catch "this shipped in March" lives in `LegacyOrderCancelService`, not here.
2. **Inventory drift is silent and cumulative.** S1's credit is unclamped, so it does not
   self-correct against on-hand; a spurious credit shows up later as an oversell, far from its
   cause, with no `parcel_status_history` row to trace it back to.
3. **Billing.** `LegacyBillingQueryService::BILLABLE_PARCEL_STATUSES = [4, 5, 13, 14, 15, 16, 17,
   18, 21]` — **28 is not in it**, and the billable-shipment subquery filters
   `whereIn('parcel_status', self::BILLABLE_PARCEL_STATUSES)`. Billing reports are generated
   **on demand for a date range** (`whereBetween('shipped.ship_date', [$start, $end])`), not
   frozen at period close. So flipping a *shipped* parcel to 28 would silently remove it from any
   **re-run** of a historical billing report. For parcels that never shipped (the expected case for
   orders stuck since February) there is **no billing exposure** — they are not billable at any
   status.
4. **`updateBatchStatusIfAllParcelsCancelled` has NULL-blind SQL.** `->where('parcel_status', '!=',
   self::STATUS_CANCEL)->count()` does not match rows where `parcel_status IS NULL` (SQL three-valued
   logic). A February batch holding *other* parcels with a NULL status would count zero active
   parcels and have its `batch_status` flipped to 28 — cancelling a batch on the strength of the
   two orders being repaired. The item-level sibling
   (`updateParcelStatusIfAllItemsCancelled`, `->where('qa_status', '!=', STATUS_CANCEL)`) has the
   same shape; `ParcelCreationService` writes `qa_status => 0` at creation, so it is less likely to
   bite, but it is the same defect. **Unverified against the actual OMS rows** — I have no OMS DB
   access from this lane (the MCP roster carries WMS and landlord DBs only).
5. **A malformed replay costs more than a failed replay.** Per §3, a 422 turns into
   `FAILED_TERMINAL` immediately and then wedges every *later* `CUSTOMER_ORDER` outbox row for that
   order until an operator clears it.

---

## 6. Verdict and the one check that decides it

**Safe · harmful · no-op — it is decided by one query, on the OMS side, which this lane could not
run.**

```sql
-- against the WineCo OMS tenant DB, per stuck order:
SELECT p.parcel_id, p.parcel_id_str, p.parcel_status, p.ship_date,
       oip.order_item_parcel_id, oip.qa_status, oip.assigned_quantity, oip.product_id
FROM parcel p
JOIN batch_criteria bc ON bc.batch_criteria_id = p.batch_criteria_id
LEFT JOIN order_item_parcels oip ON oip.parcel_id = p.parcel_id
WHERE bc.batch_label = '<WMS customerorder_batch.batchid>'
  AND (p.parcel_id_str = '<WMS customerorder.externalnumber>'
       OR p.parcel_id   = '<WMS customerorder.externalnumber>');
```

| What that returns | Replay outcome |
|---|---|
| no `batch_criteria` row, or no matching `parcel` | **No-op.** HTTP 200 with `Status: Error` in the body; WMS marks `SENT`. Nothing is written. |
| every `oip.qa_status = 28` | **No-op.** Every CAS claims 0; no inventory moves; `Status: Success`. |
| `oip.qa_status` is 0/NULL/anything ≠ 28, and `parcel_status` is pre-ship | **Intended effect.** Items → 28, parcel → 28, inventory credited. This is the cancel the orders should have emitted in February. Verify the credit against S1's facility blindness if the tenant has more than one facility row for the products. |
| `oip.qa_status ≠ 28` **and** `parcel_status ∈ {4,5,11..18,20,21,27}` | **Harmful.** Terminal state overwritten with 28, no history row, inventory credited for goods that shipped, and any billing re-run for that period silently loses the parcel. **Do not replay these; repair them out-of-band.** |

Two things to settle before the replay, both cheap:

- **(a)** Run the query above. It is the entire decision.
- **(b)** Confirm how many `product_inventory` rows exist per implicated `product_id` in the WineCo
  OMS tenant DB. If the answer is 1, S1's facility blindness is inert for this repair and can be
  filed rather than blocking it. If it is >1, the replay over-credits every other facility and the
  repair needs the credit corrected by hand afterwards.

---

## 7. Findings worth filing regardless of the replay decision

| # | Severity | Finding |
|---|---|---|
| F1 | **High** | `LegacyPositionCancelService` has **no** terminal-state guard, while its OMS-initiated sibling `LegacyOrderCancelService` has `UNCANCELABLE_PARCEL_STATUSES`. A WMS cancel can overwrite Shipped/Returned/Completed. |
| F2 | **High** | `returnInventoryToAvailable` filters on `product_id` only — no `facility_code`, no `client_id`, no `LEAST(…, quantity_on_hand)` clamp, no `inventory_assigned` gate, and never decrements `quantity_inv_allocated`. Its sibling does all five. |
| F3 | **Medium** | `updateBatchStatusIfAllParcelsCancelled` (and the parcel-level sibling) use `!= 28`, which is NULL-blind. Rows with a NULL status are counted as inactive and can cause a premature batch cancel. |
| F4 | **Medium** | `/services/call/cancelPosition` has **no auth middleware** (`Route::middleware('api')` only). WMS sends Basic auth; nothing reads it. Anyone who can reach the host can cancel any batch. |
| F5 | **Low** | A cancellation writes no `parcel_status_history` row — no audit trail for the transition. |
| F6 | **Low** | The endpoint's OpenAPI annotation says *"parcel status to CANCELLED (5)"*; the code writes **28**. Doc is wrong. |
| F7 | **Low** | `WEBSERVICE_ORDER_BATCH_CANCELLED_ACTIVATED` exists as a constant and as a DB row (`false`) but **has no runtime consumer in `wms2-api`**. Anyone reading the sysprop census would reasonably believe the cancel notification is gated off. It is not. |
| F8 | **Low** | `LegacyPositionCancelService` imports `App\Models\Product` and never uses it. |
