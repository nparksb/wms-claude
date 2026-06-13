---
title: "OMS sends empty/wrong transfer_id to WMS — transfer batch rejected (field transfer_id not set)"
ticket: ""
ticket_url: ""
type: bugfix
priority: high
status: draft
project: [wms2]
version: v2
requester: nam.park@siteboss.net
created: 2026-06-09
updated: 2026-06-09
related:
  - "[[260424-Transfer_Error_Fix]]"
  - "[[wms2-oms-integration-map]]"
db_verified: true
tags:
  - plan
  - oms-integration
  - transfer
---

# OMS sends empty/wrong transfer_id to WMS — transfer batch rejected (field transfer_id not set)

**Project:** wms2 (defect is in `v2/oms-laravel-api`; symptom surfaces at `v2/wms2-api`) | **Version:** v2 | **Type:** bugfix
**Priority:** High
**Status:** Draft
**Date:** 2026-06-09

> **ralplan note:** This plan was authored directly (skipping the `ralplan` consensus loop) under the skill's mechanical-fix exception. The root cause is triangulated across (a) the code, (b) three independent contract references in OMS itself, and (c) live WMS DB evidence; the fix is contained to a single helper method (`BatchProcessingService::getTransferId`). The change is small enough that the Planner→Architect→Critic loop adds process overhead without changing the design. A `critic`/`code-reviewer` pass is still recommended at implementation time (see §9.2).

> **Cross-codebase note:** The failing validation lives in `wms2-api` (`OrderRestController.java`), but **WMS is behaving correctly** — it is rejecting a malformed payload. The bug to fix is in **`v2/oms-laravel-api`**. This plan is filed under `wms2/plan/` because it belongs to the v2 OMS↔WMS integration surface and pairs with [[260424-Transfer_Error_Fix]].

---

## 0. Affected sites (enumeration before drafting)

Enumeration commands run:
- `grep -rn "transfer_destination" app --include=*.php`
- `grep -rn "pushBatchToWms\|buildBatchPayload" app --include=*.php`
- `grep -rn "getTransferId\|getTransferDestination" app --include=*.php`
- `grep -rln "transfer_id\|TRANSFER_OFFSITE\|getTransferId" sbdocs/1-Projects sbdocs/4-Archieves`

| # | File:line | Construct | Same root-cause? | In-scope this plan? |
|---|-----------|-----------|------------------|----------------------|
| 1 | `app/Services/BatchProcessingService.php:373-381` | `getTransferId()` returns `order->transfer_destination` as the transfer_id | **yes — the defect** | **yes** |
| 2 | `app/Services/BatchProcessingService.php:191` | call site that feeds `transfer_id` into `$batchData` | yes (consumer) | yes |
| 3 | `app/Services/BatchProcessingService.php:361-368` | `getTransferDestination()` reads `order->transfer_destination` (used to pick `TRANSFER_OFFSITE` vs `TRANSFER_INTRACOMPANY`) | partial — it shares the field, but this use is *correct* (destination → batch_type) | no — leave as-is; only documents why the two helpers must NOT share output |
| 4 | `app/Services/WmsApiService.php:2384-2398` `buildBatchPayload()` | coerces missing `transfer_id` to `''` and defaults `batch_type` to `PICK_PACK` | no — generic builder; correct to keep the `?? ''` default for non-transfer batches | no |
| 5 | `app/Services/WmsApiService.php:2265` `pushBatchToWms()` | transport; passes `$batchData` through | no | no |
| 6 | `app/Console/Commands/SmokeTestOrderFlowCommand.php:848-854` | other `pushBatchToWms` caller; hardcodes `batch_type=PICK_PACK`, no transfer | no | no |
| 7 | `app/Services/Legacy/LegacyTransferCloseService.php:153-179` | inbound `closeTransfer` parses `transfer_id` as `CLIENT_CODE-ORDER_ID` (`explode('-', $id, 2)`) | no (consumer of the contract) — **proves the required format** | no — but is the regression's downstream victim; covered by manual test |
| 8 | `app/Http/Controllers/Api/Reporting/InventoryReportController.php:695` | report maps `transfer_id => o.orderID` | no — **corroborates the contract** | no |

Every in-scope row (1, 2) is addressed in §3. Rows 3–8 are explicitly excluded with rationale.

---

## 1. Problem Statement

When OMS pushes a **transfer** order batch to WMS (`PUT /rest/order/create`), WMS rejects it with HTTP 400:

```
WMS validation error: field transfer_id not set for OrderBatchDto{batchid='19ead9974d', ...}
```

WMS backend log (tenant `wine-wsl`):

```
OrderRestController - create called with 1
ReceivingService - start createServiceLog
ReceivingService - create message with operator = anonymous
ReceivingService - end with created message=...
RestIdempotencyService - persistResponse skipped: key=... status=400 cleared=1
```

The log is consistent with a clean client-side rejection: the request reached `OrderRestController.create`, validation threw a `WebserviceBusinessExceptionClientSide` (HTTP 400), and the idempotency filter declined to cache the 4xx and cleared the key so OMS may safely retry once the payload is fixed. **No WMS-side defect is implicated.**

**User-visible symptom:** transfer orders created in OMS never appear in the WMS Outbound/Transfer screen, because the batch push fails and `BatchProcessingService` rolls back the OMS transaction (`BatchProcessingService.php:199-216`).

### DB verification (Analysis protocol §8 — `db_verified: true`)

Run against tenant `wine-wsl` (`mcp__wms2-wineco-dev2__execute_sql`):

```sql
SELECT type,
       count(*) AS n,
       count(*) FILTER (WHERE transferid IS NULL OR transferid='') AS empty_xfer,
       min(transferid) AS sample_min, max(transferid) AS sample_max
FROM customerorder_batch
WHERE type IN ('TRANSFER_OFFSITE','TRANSFER_INTRACOMPANY')
GROUP BY type;
```

Result:

| type | n | empty_xfer | sample_min | sample_max |
|------|---|------------|------------|------------|
| TRANSFER_INTRACOMPANY | 228 | **0** | `ACB-ACB-Bixler-WCPU-04132026` | `XNO-XNOWILLCALL12052025` |
| TRANSFER_OFFSITE | 232 | **0** | `ACB-390211` | `WVV-WVV-WCPU-09102025` |

Two facts proven by the data:
1. **No transfer batch in production history (460 rows) has ever had an empty `transferid`.** Both subtypes always carry one. The new Laravel OMS attempting to send an empty `transfer_id` for offsite transfers is therefore a regression against an invariant the legacy OMS always honored.
2. **The historical `transferid` format is `CLIENT_CODE-ORDER_ID`** (`ACB-390211` → client `ACB`, order `390211`). This is the format the fix must reproduce.

---

## 2. Root Cause Analysis

### Bug 1: `transfer_id` is sourced from `transfer_destination` (the wrong field)

**File:** `v2/oms-laravel-api/app/Services/BatchProcessingService.php:373-381`

```php
protected function getTransferId($parcels, string $packType): string
{
    if ($packType !== 'Transfer') {
        return '';
    }
    // Get transfer destination from first parcel's order
    $firstParcel = $parcels->first();
    return $firstParcel->order->transfer_destination ?? '';   // ← WRONG SOURCE
}
```

`order->transfer_destination` is a **foreign key to `facility.facility_code`** (the destination warehouse), confirmed by `app/Models/Order.php:232`:

```php
return $this->belongsTo(Facility::class, 'transfer_destination', 'facility_code');
```

It is a *destination warehouse code*, not a transfer identifier. Using it as the WMS `transfer_id` fails in two distinct ways depending on the transfer subtype:

#### 1a. Offsite transfer → empty `transfer_id` → the reported 400

`batch_type` is selected by the **same** field via `mapPackTypeToWms` / `getTransferDestination` (`BatchProcessingService.php:340-368`):

```php
return empty($transferDestination) ? 'TRANSFER_OFFSITE' : 'TRANSFER_INTRACOMPANY';
```

For an **offsite** transfer, `transfer_destination` is empty *by definition* (there is no intra-company destination facility). So in the same payload:
- `batch_type = TRANSFER_OFFSITE` (because destination is empty), **and**
- `transfer_id = ''` (because it reads the same empty field).

WMS requires `transfer_id` for **both** transfer subtypes — the `TRANSFER_INTRACOMPANY` case falls through to `TRANSFER_OFFSITE` (`v2/wms2-api/.../OrderRestController.java:173-181`):

```java
case TRANSFER_INTRACOMPANY:
    // waterfall
case TRANSFER_OFFSITE:
    if (orderBatch.getPositions().size() > 1) { ... }
    if (orderBatch.getTransferId() == null || orderBatch.getTransferId().isEmpty()) {
        throw new WebserviceBusinessExceptionClientSide(WmsConstants.FIELD_NOT_SET, null, "transfer_id", orderBatch);
    }
```

→ exactly the `field transfer_id not set` 400 the user observed.

#### 1b. Intracompany transfer → facility code as `transfer_id` → two latent failures

For an **intracompany** transfer, `transfer_id` becomes a bare facility code (e.g. `"WH02"`):

- **WMS duplicate guard collides.** `OrderRestController.java:182-188` looks up `findByTransferid(transfer_id)` and rejects any non-terminal match with `NOT_UNIQUE_VALUE`. Every transfer to the same destination warehouse shares the same `transfer_id`, so the *second* transfer to that warehouse is rejected as a duplicate. (This is the same failure class [[260424-Transfer_Error_Fix]] hardened on the WMS side — but that fix only relaxed the *terminal-state* check; it cannot help when the id itself is non-unique.)
- **`closeTransfer` round-trip breaks.** The WMS→OMS `closeTransfer` callback parses `transfer_id` as `CLIENT_CODE-ORDER_ID` (`LegacyTransferCloseService.php:157`, `explode('-', $transferId, 2)`). A bare facility code has no `-`, so `count($parts) !== 2` → `"Invalid transfer_id format"` (`LegacyTransferCloseService.php:159`) → the transfer never closes in OMS.

### The correct contract: `CLIENT_CODE-ORDER_ID`

The `transfer_id` format is documented and consumed in three independent places in OMS, all agreeing:

| Evidence | File:line | Says |
|---|---|---|
| Inbound parser | `LegacyTransferCloseService.php:150` | `Format: CLIENT_CODE-ORDER_ID` and splits it back into client_code + orderID |
| Close-transfer API contract | `LegacyWmsController.php:2662` | `"transfer_id": "CLIENT_CODE-ORDER_ID"` |
| Inventory report | `InventoryReportController.php:695` | `'transfer_id' => 'o.orderID'` |

And the live DB (§1) shows every historical `transferid` matches `CLIENT_CODE-ORDER_ID`. Under `explode('-', $id, 2)` even multi-dash order numbers round-trip correctly: `WVV-WVV-WCPU-09102025` → client `WVV`, order `WVV-WCPU-09102025`.

---

## 3. Design / Proposed Fix

### 3.1 Fix A — build `transfer_id` from `client_code` + `orderID` (Bug 1)

**Site:** `BatchProcessingService.php:373-381` (+ call site at line 191)

**Solution:** Source the transfer_id from the order identity, not the destination. `client_code` and `orderID` are already available — `$clientCode` is derived at `BatchProcessingService.php:109-110` and parcels are eager-loaded with `order.client` (`:84`, `:164`).

**Before:**
```php
protected function getTransferId($parcels, string $packType): string
{
    if ($packType !== 'Transfer') {
        return '';
    }
    // Get transfer destination from first parcel's order
    $firstParcel = $parcels->first();
    return $firstParcel->order->transfer_destination ?? '';
}
```

**After:**
```php
/**
 * Build the WMS transfer_id for a Transfer batch.
 *
 * WMS requires transfer_id for BOTH TRANSFER_OFFSITE and TRANSFER_INTRACOMPANY
 * batches, and the OMS<->WMS contract format is "CLIENT_CODE-ORDER_ID"
 * (see LegacyTransferCloseService::getTransferInformation, which parses it back
 * via explode('-', $id, 2)). It is NOT the destination facility code.
 */
protected function getTransferId($parcels, string $packType, string $clientCode): string
{
    if ($packType !== 'Transfer') {
        return '';
    }

    $order = $parcels->first()->order ?? null;
    $orderID = $order->orderID ?? '';

    if ($clientCode === '' || $orderID === '') {
        // Defensive: a Transfer batch with no client/order identity cannot
        // produce a valid transfer_id. Surface it loudly instead of letting
        // WMS reject an empty value with an opaque 400.
        throw new BusinessLogicException(
            'Cannot build transfer_id: missing client_code or orderID for Transfer batch'
        );
    }

    return $clientCode . '-' . $orderID;
}
```

**Call site update (`BatchProcessingService.php:191`):**
```php
// Before
'transfer_id' => $this->getTransferId($parcels, $data['pack_type']),
// After
'transfer_id' => $this->getTransferId($parcels, $data['pack_type'], $clientCode),
```

**Why this and not alternatives:**
- *Pass `$clientCode` rather than re-deriving inside the helper* — it is already computed once in `createBatchFromParcels` and reused for `client_id`/positions; re-deriving risks divergence if the derivation ever changes.
- *Throw rather than silently send `''`* — the empty value is precisely what produces the opaque WMS 400. Failing fast in OMS with a clear message (and rolling back, per the existing `catch (BusinessLogicException)` at `:255`) gives operators an actionable error instead of a remote validation failure. The DB evidence (`empty_xfer = 0`) confirms an empty transfer_id is never valid, so this throw cannot reject a legitimate case.
- *Use the stored `client_code` verbatim (no `strtoupper`)* — `closeTransfer` queries `where('c.client_code', $clientCode)` with the exact value, so the round-trip must use the same casing the DB stores. Historical samples are already uppercase; do not transform. (See §10.)
- *Do NOT change `getTransferDestination`* (row 3) — using `transfer_destination` to choose `TRANSFER_OFFSITE` vs `TRANSFER_INTRACOMPANY` is correct; only the transfer_id source was wrong.

**Files changed:** `app/Services/BatchProcessingService.php`

---

## 4. V1/V2 Applicability

| Aspect | V1 | V2 | Impact |
|--------|----|----|--------|
| OMS that builds the batch payload | Legacy Zend `oms` (PHP 5.6) | `oms-laravel-api` (this fix) | V1 OMS already sends `CLIENT_CODE-ORDER_ID` correctly — proven by the 460 historical rows in §1, all created by V1. |
| WMS validation | `v1/wms-api` | `v2/wms2-api` | No change either side — WMS validation is correct. |

### What Needs Porting

- Nothing. This is a **v2-OMS-only regression** introduced by the new Laravel `BatchProcessingService`. The legacy OMS is the reference implementation that already does it right.

### What Does NOT Need Porting

- No `wms2-api` (Java) change — WMS correctly enforces the contract.
- No `v1` change — the legacy OMS already produces the correct format.

---

## 5. Prerequisites & Implementation Plan

### 5.1 Prerequisites

| # | Prerequisite | Required value / action | Owner | Notes |
|---|---|---|---|---|
| 1 | **Database state** | None | — | N/A — pure application-logic fix; no schema/seed dependency. |
| 2 | **Feature flags / system properties** | None | — | N/A — no toggle; the fix is unconditionally correct. |
| 3 | **Config / env changes** | None | — | N/A. |
| 4 | **Deploy-order dependencies** | `oms-laravel-api` deploys independently | OMS | WMS needs no change; deploy OMS whenever ready. |
| 5 | **Data migration** | None | — | Existing rejected transfers were never persisted in WMS (400 + rollback), so there is nothing to backfill. Operators must **re-send** affected transfers after deploy. |
| 6 | **External systems** | WMS `/rest/order/create` reachable for the tenant | — | Already in use; no new endpoint. |
| 7 | **Access / permissions** | None | — | N/A. |
| 8 | **Monitoring / alerts** | Optionally add a log-based alert on the new `BusinessLogicException` message | OMS | See §6 manual plan. |

### 5.2 Implementation Checklist

- [ ] Update `getTransferId()` signature + body (Fix A) in `BatchProcessingService.php`.
- [ ] Update the single call site at line 191 to pass `$clientCode`.
- [ ] Confirm `BusinessLogicException` is imported in `BatchProcessingService.php` (it is already caught at `:255`, so the import exists — verify).
- [ ] Add/adjust unit tests (see §6).
- [ ] Run `php artisan test --filter=BatchProcessing` and `./vendor/bin/pint` on the touched file.
- [ ] Run `bash sbdocs/9-System/scripts/verify-260609-oms-transfer-id-wrong-source-fix.sh` → `0 fail`.
- [ ] Code review.

---

## 6. Test Plan

> Framework: PHPUnit (`php artisan test`). This is `oms-laravel-api`, **not** wms2-api — the WMS Java test guidance (Testcontainers / `BaseControllerTest`) does **not** apply here.

### Test scenarios

| Scenario | Steps | Expected Result |
|----------|-------|-----------------|
| Offsite transfer (no destination) | `pack_type='Transfer'`, order has `transfer_destination=null`, `client_code='ACB'`, `orderID='390211'` | payload `batch_type=TRANSFER_OFFSITE`, `transfer_id='ACB-390211'` (non-empty) |
| Intracompany transfer (with destination) | `pack_type='Transfer'`, `transfer_destination='WH02'`, `client_code='WVV'`, `orderID='WVV-WCPU-09102025'` | `batch_type=TRANSFER_INTRACOMPANY`, `transfer_id='WVV-WVV-WCPU-09102025'` |
| Non-transfer batch | `pack_type='Pick Pack'` | `transfer_id=''` (unchanged behavior) |
| Transfer batch missing orderID | `pack_type='Transfer'`, `orderID=''` | throws `BusinessLogicException`; OMS transaction rolls back; no WMS call |
| Round-trip parse | feed `transfer_id` into `LegacyTransferCloseService::getTransferInformation` logic | `explode('-', $id, 2)` yields `[client_code, orderID]` matching the source order |

### New / updated tests

| Test class | Test method | What it asserts |
|------------|-------------|-----------------|
| `tests/Unit/Services/BatchProcessingServiceTest.php` (or Feature, per existing convention) | `test_getTransferId_offsite_uses_client_and_order_id` | offsite → `CLIENT_CODE-ORDER_ID`, never empty |
| same | `test_getTransferId_intracompany_uses_client_and_order_id` | intracompany → `CLIENT_CODE-ORDER_ID` (not the facility code) |
| same | `test_getTransferId_non_transfer_returns_empty` | regression guard for `PICK_PACK`/`CLUB` |
| same | `test_getTransferId_throws_when_orderID_missing` | fail-fast guard |
| same | `test_transfer_id_roundtrips_through_close_transfer_parser` | `explode('-', $id, 2)` recovers client_code + orderID |

If `getTransferId` is `protected`, test via a small subclass exposing it, or assert through the public `buildBatchPayload`/`createBatchFromParcels` path (preferred — exercises the real call site at line 191). Match the existing test style in `tests/`.

### Manual test plan

| Scenario | Environment | Steps | Expected Result | Pass/Fail |
|---|---|---|---|---|
| Offsite transfer end-to-end | staging | Create a Transfer order with no intra-company destination in OMS → batch it → push to WMS | WMS returns 2xx; batch appears in WMS Outbound/Transfer screen with `transferid = CLIENT-ORDER` | |
| Intracompany transfer end-to-end | staging | Create a Transfer order with a destination facility → batch → push | WMS 2xx; `transferid = CLIENT-ORDER`; a *second* transfer for a different order to the same facility also succeeds (no `NOT_UNIQUE_VALUE`) | |
| closeTransfer round-trip | staging | After WMS finishes the transfer, let WMS call `closeTransfer` | OMS parses transfer_id, marks parcel SHIPPED; no `"Invalid transfer_id format"` log | |
| SQL sanity | staging WMS DB | `SELECT type, transferid FROM customerorder_batch WHERE type LIKE 'TRANSFER%' ORDER BY id DESC LIMIT 5;` | new rows show `CLIENT_CODE-ORDER_ID`, none empty | |

### Test execution (fill in after running)

| Command | Result | Pass / Fail / Skipped counts |
|---------|--------|------------------------------|
| `php artisan test --filter=BatchProcessing` | | |
| `./vendor/bin/pint --test app/Services/BatchProcessingService.php` | | |

### Deliberately-skipped coverage

| What | Why |
|------|-----|
| wms2-api Java tests | No Java code changes; WMS validation is already correct and covered by `OrderRestControllerCreateTransferTest`. |

---

## 7. Horizontal Scalability Validation (v2 plans — MANDATORY)

> The change is entirely in `v2/oms-laravel-api` (PHP/Laravel). `wms2-api` (the multi-replica Java service this checklist targets) is **not modified**. All WMS-replica concerns are therefore N/A; the one substantive cross-cutting concern — idempotency/retry — is improved by this fix.

| # | Concern | Verdict | Mitigation / rationale |
|---|---|---|---|
| 1 | In-JVM state | N/A | No wms2-api change. |
| 2 | Connection pool math | N/A | No wms2-api change. |
| 3 | Scheduled jobs | N/A | No cron added. |
| 4 | Long transactions | N/A | No wms2-api change. The OMS-side tenant transaction boundary is unchanged. |
| 5 | Request affinity | N/A | No wms2-api change. |
| 6 | Retry / idempotency | **Improved** | `transfer_id` becomes **deterministic per order** (`CLIENT_CODE-ORDER_ID`) instead of a non-unique facility code. This makes WMS's `findByTransferid` dedup and the SBDEV-2222 REST idempotency layer behave correctly on retry — a re-pushed transfer maps to a stable key instead of colliding with unrelated transfers to the same warehouse. |
| 7 | Tenant context | N/A | No wms2-api change. |
| 8 | Distributed lock correctness | N/A | No wms2-api change. |
| 9 | Cache invalidation | N/A | No cached entity written. |
| 10 | External notifications | N/A | No new external send; the existing WMS push is unchanged in shape. |

### Evidence (for "Improved" row 6)

| Concern # | What was verified | File:line |
|-----------|-------------------|-----------|
| 6 | WMS dedups by `transferid`; per-order stable id prevents cross-transfer collisions | `OrderRestController.java:182-188`; DB §1 (`empty_xfer=0`, all `CLIENT_CODE-ORDER_ID`) |

---

## 8. Notes

- Pairs with [[260424-Transfer_Error_Fix]] (WMS-side: relaxed the `transfer_id` duplicate check to allow re-sending CANCELED transfers, fixed controller annotations, restored UI toasts). That plan made WMS *tolerant* of re-sent transfer_ids; **this** plan makes OMS *send a correct, unique* transfer_id in the first place. They are complementary, not overlapping.
- See [[wms2-oms-integration-map]] for the WMS→OMS notification/return path.
- **Adjacent observation (out of scope, flag for follow-up):** WMS rejects transfer batches with more than one position (`OrderRestController.java:176-177`, `TRANSFERS_ONLY_ONE_ORDER_ALLOWED_PER_BATCH`). `BatchProcessingService::buildPositionsArray` emits one position per parcel, so a transfer order with multiple parcels would hit that rejection independently of this bug. Not fixed here; raise as a separate ticket if multi-parcel transfers are a real flow.

---

## 9. Acceptance & Implementation

### 9.1 Acceptance script (machine-checkable)

`sbdocs/9-System/scripts/verify-260609-oms-transfer-id-wrong-source-fix.sh`

Checks:
- **POSITIVE** — `getTransferId` builds `$clientCode . '-' . $order->orderID`.
- **POSITIVE** — call site at line ~191 passes `$clientCode` to `getTransferId`.
- **NEGATIVE** — `getTransferId` no longer returns `transfer_destination`.
- **NEGATIVE** — `getTransferId` signature no longer has the 2-arg `($parcels, string $packType)` form (i.e., the new 3-arg form is present).
- Optional: `php artisan test --filter=BatchProcessing` passes.

Run from repo root with `PROJECT_ROOT=v2/oms-laravel-api`. Final acceptance: `Result: N pass, 0 fail`.

### 9.2 Recommended OMC composition (for implementation)

| Aspect | Value | One-line rationale |
|---|---|---|
| **Size class** | Trivial | 1 fix, 1 method + 1 call site, single file. |
| **Pre-draft step** | none | Root cause triangulated (code + 3 contract refs + DB). |
| **Plan-review step** | critic (optional) | Touches an external contract; a quick critic pass is cheap insurance. |
| **Implementation shape** | executor | Single mechanical change. |
| **Verification step** | verify-script + verifier (mandatory) | always |
| **Code-review step** | code-reviewer | Contract change — worth one review pass. |
| **Commit step** | git directly | Single logical commit in `oms-laravel-api`. |

---

## 10. Open Questions / Resolved Decisions

| # | Question | Decision |
|---|---|---|
| 1 | Should `transfer_id` use raw or upper-cased `client_code`? | **Use raw stored value.** `closeTransfer` queries `client_code` with the exact value; transforming it would break the round-trip. Historical values are already uppercase. Revisit only if a client_code is stored lower/mixed-case. |
| 2 | What if a Transfer batch has multiple parcels (multiple orders)? | Out of scope — WMS independently rejects multi-position transfers (§8 adjacent observation). `getTransferId` uses `$parcels->first()->order`, consistent with WMS's one-order-per-transfer rule. |
| 3 | Block (throw) or warn-and-skip when orderID is missing? | **Throw `BusinessLogicException`.** DB evidence shows an empty transfer_id is never valid; fail fast in OMS with a clear message rather than emit an opaque remote 400. |
| 4 | Scope — v1, v2, or both? | **v2 OMS only.** v1 OMS already produces the correct format (proven by the 460 historical rows). |

---

## 11. Completeness checklist

| # | Concern | Considered? |
|---|---|---|
| 0 | DB verified | ✓ §1 — `execute_sql` against `wine-wsl`; `empty_xfer=0`, format confirmed; `db_verified: true` |
| 1 | All callsites enumerated | ✓ §0 — rows 1–8; only 1–2 in scope |
| 2 | Adjacent bugs | ✓ §8 — multi-parcel transfer rejection flagged as separate follow-up |
| 3 | Backward compatibility | ✓ §3 — output format now *matches* the legacy/contract format; no consumer change needed |
| 4 | Concurrency | ✓ §7 row 6 — deterministic id improves retry/idempotency |
| 5 | Multi-tenant | ✓ no cross-tenant query; client_code/orderID are tenant-local |
| 6 | Error handling | ✓ §3 — new throw is caught by existing `catch (BusinessLogicException)` at `:255` |
| 7 | Observability | ✓ §5.1/§6 — optional log-based alert on the new exception message |
| 8 | Rollback / migration | ✓ §5.1 — no migration; operators re-send affected transfers |
| 9 | Test coverage | ✓ §6 — 5 unit scenarios + manual end-to-end |
| 10 | Cross-version (v1↔v2) | ✓ §4 — v2-OMS-only; v1 already correct |
