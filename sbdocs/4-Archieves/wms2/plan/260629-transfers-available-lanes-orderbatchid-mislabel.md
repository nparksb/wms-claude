---
title: "Transfers availableTransferLanes — orderBatchId mislabeled as customerOrderID (self-exclusion never matches)"
plan_id: 260629-transfers-available-lanes-orderbatchid-mislabel
type: bugfix
repo: v2/wms2-api
status: archived
db_verified: true
created: 2026-06-29
author: nam.park@siteboss.net
severity: low
component: transfers / activate-reassign lane dialog
related:
  - "[[260629-transfer-lane-leak-on-cancel]]"
  - "[[260629-activate-transfer-atomicity]]"
acceptance_script: sbdocs/9-System/scripts/verify-260629-transfers-available-lanes-orderbatchid-mislabel.sh
---

# Transfers `availableTransferLanes` — `orderBatchId` mislabeled as `customerOrderID`

> Sibling plan [[260629-transfer-lane-leak-on-cancel]] §10 flagged this as a deferred,
> separate ticket ("`orderBatchId`/`customerOrderId` param mislabel,
> `TransferOrderService.java:196`"). This plan is that ticket. **It does NOT cause the
> empty-dialog lane leak** (that is the sibling plan's H1/abandonment root cause). This is
> a **latent self-exclusion correctness bug** in the activate/reassign-lane display path.

---

## 0. Affected sites

All sites share the `reqMap.get("orderBatchId")` → passed-as-`customerOrderID` pattern in
`controller/TransfersController.java`. Two of the four already resolve the real CO; two do not.

| # | Endpoint | Site | Passes orderBatchId where service wants… | Already resolves CO? | In scope |
|---|----------|------|------------------------------------------|----------------------|----------|
| A | `POST /v3/transfers/availableTransferLanes` | `TransfersController.java:367-372` | **customerOrderId** (`LocationRepository.getAvailableTransferLanes` self-exclusion `co.id != :customerOrderId`) | **No — bug** | **YES (primary)** |
| B | `POST /v3/transfers/unitLoads` | `TransfersController.java:339-348` | a `Customerorder` object | **Yes** — `customerorderRepository.findByOrderbatchId(orderBatchId).get(0)` (`:343`) | No — reference pattern |
| C | `GET /v3/transfers/skus` | `TransfersController.java:333-337` → `TransferOrderService.getSKUOverview(orderBatchId)` (`:197`) | a **batch id** (service loops `findByOrderbatchId`) | n/a — param genuinely IS a batch id (already named `orderBatchId`); only two stale `LOG.debug` message strings read `customerOrderID=` | No — cosmetic only |
| D | `POST /v3/transfers/parcels` | `TransfersController.java:360-364` → `DtoViewService.getOrderDetailView(orderBatchId)` (`:364`) | a **batch id** | n/a — param genuinely IS a batch id | No — correct as-is |

**Conclusion: only site A is semantically wrong.** Sites C/D legitimately consume a batch id;
site B already does the correct resolution and is the in-repo reference for the fix.

---

## 1. Problem + DB verify + frontend data-flow

### 1.1 The defect (static, file:line)

`TransfersController.getAvailableTransferLanes` (`:367-372`):

```java
@RequestMapping(value = "/availableTransferLanes", produces = "application/json", method = RequestMethod.POST)
public List<Location> getAvailableTransferLanes(@RequestBody Map<String,Object> reqMap,
                                               @AuthenticationPrincipal Principal principal) {
    Long orderBatchId = Long.valueOf( (Integer) reqMap.get("orderBatchId") );
    return transferOrderService.getAvailableTransferLanes(orderBatchId);   // <-- value is a BATCH id; used as customerOrderID
}
```

flows into `TransferOrderService.getAvailableTransferLanes(Long customerOrderID)` (`:78-83`):

```java
public List<Location> getAvailableTransferLanes(Long customerOrderID) {
    List<Location> resultList = locationRepository.getAvailableTransferLanes(customerOrderID, State.FINISHED);
    return resultList;
}
```

→ `LocationRepository.getAvailableTransferLanes` (`:57-67`), JPQL:

```
SELECT l FROM Location l
 WHERE l.transferlane = true
 AND NOT EXISTS (
   SELECT co FROM Customerorder co
   WHERE co.transferlaneId = l.id
   AND co.id != :customerOrderId      <-- self-exclusion: keep THIS order's own lane in the result
   AND co.state < :state              <-- state < FINISHED(700)
 )
 ORDER BY l.name
```

The purpose of `co.id != :customerOrderId` is the **self-exclusion**: a lane already held by the
order *being reassigned/re-activated* should still appear in the picker so the operator can keep
or re-pick the same lane. Because the controller passes a **batch id** (not a CO id), the
predicate `co.id != <batchId>` is **always true** for the real order (its `co.id` is never equal
to its `orderbatch_id`) → the order's **own** currently-assigned lane is wrongly excluded from the
list. The dialog cannot surface the order's already-assigned lane.

### 1.2 Why this is NOT the empty-dialog leak

Sibling [[260629-transfer-lane-leak-on-cancel]] §2.1 proved the empty dialog is caused by lanes
*leaked by other abandoned orders* — `NOT EXISTS (… co.state < 700)` excludes lanes held by
**other** orders, and the mislabel does not change which *other* orders match (the `!=` only ever
intended to drop **one** row — the self row). So:

- **First activation** (order has no lane yet): the self-exclusion is **moot** — there is no row
  with `co.transferlaneId = l.id AND co.id = thisOrder` to keep. The bug is invisible.
- **Reassign / re-activate** (order already holds a lane): the self row exists; with the wrong id,
  `co.id != batchId` stays true, the inner `NOT EXISTS` fires, and the order's **own** lane is
  dropped from the picker. **This is the only behavior the fix changes.**

### 1.3 Frontend data-flow (the crux)

`v2/wms2-web-ui`:

- **Table row → store**: `components/outbound/transfer/openTransfers.vue:329`
  `startTransfer(item)` → `this.$store.commit('outbound/transfer/setActivate1Batch', item)`.
  The `item` is a row from `transferPickingData` (the `searchOpenTransfer` page).
- **Row shape**: backed by `ActiveOrderBatchViewDto`
  (`v2/wms2-api/src/main/java/net/aim_ai/wms/json/ActiveOrderBatchViewDto.java`). Built in
  `ViewDtoService.getActiveOrderBatchDtoPage` (`:301-328`):
  - `dto.setId(result.getId())` (`:305`) — **the `customerorder_batch.id` (orderbatch id)**.
    Used everywhere in the UI as `orderBatchId` (e.g. `openTransfers.vue:320-322`,
    `getTransferOrderDetails` passes `{orderBatchId: item.id}`).
  - `dto.setCustomerOrderId(result.getCustomerOrderId())` (`:320-321`) — **a SEPARATE field**
    already carrying the real `customerorder.id`. (Projection `OrderBatchPageView` exposes both
    `getId()` and `getCustomerOrderId()` as distinct accessors —
    `repo/projection/OrderBatchPageView.java:10,22`.)
- **Dispatch**: `components/outbound/transfer/activate/selectLanePop.vue:74`
  `this.$store.dispatch('outbound/transfer/getAvailableTransferLanes', {orderBatchId: this.activate1Batch.id})`
  and `changeLanePop.vue:64` `{ orderBatchId: this.batchOrder.id }` →
  `store/outbound/transfer.js:207-217` POSTs `{orderBatchId}` to `/transfers/availableTransferLanes`.

**So `activate1Batch.id` is the orderbatch (`customerorder_batch.id`), NOT the `customerorder.id`.**
The frontend genuinely sends a batch id. The DTO it holds **already contains** the right value in
its separate `customerOrderId` field — the backend simply isn't using it.

### 1.4 DB verify (`db_verified: true`)

**Confirmed on `wms2-wineco-dev`, 2026-06-29** (MCP endpoint reachable on re-run):

```
transfer_batches = 24 | avg_orders_per_batch = 1.00 | max_orders_per_batch = 1
transfer_orders  = 24 | rows_where_coid_equals_batchid = 0
```

→ Transfer batches are **single-order** (so `findByOrderbatchId(batchId).get(0)` is the correct CO), and a transfer `customerorder.id` is **never** equal to its `orderbatch_id` (so the current code's self-exclusion `co.id != :customerOrderId` never matches the real order). This is the root-cause proof. Query used:

```sql
SELECT count(*) AS transfer_batches,
       avg(oc.orders_per_batch)::numeric(10,2) AS avg_orders_per_batch,
       max(oc.orders_per_batch) AS max_orders_per_batch
FROM (SELECT co.orderbatch_id, count(*) AS orders_per_batch
      FROM customerorder co
      WHERE co.fulfillmenttype = 'Transfer' AND co.orderbatch_id IS NOT NULL
      GROUP BY co.orderbatch_id) oc;
-- + count FILTER (WHERE co.id = co.orderbatch_id) over the same transfer-order set → 0
```

Original intended query (kept for reference; the simpler executed form above supersedes it):

```sql
SELECT cb.type, COUNT(*) AS batches,
       AVG(oc.cnt)::numeric(10,2) AS avg_orders_per_batch,
       MAX(oc.cnt) AS max_orders_per_batch,
       SUM(CASE WHEN oc.co_id = cb.id THEN 1 ELSE 0 END) AS rows_where_coid_equals_batchid
FROM customerorder_batch cb
JOIN (SELECT orderbatch_id, COUNT(*) cnt, MIN(id) co_id
      FROM customerorder GROUP BY orderbatch_id) oc
  ON oc.orderbatch_id = cb.id
WHERE cb.type IN ('TRANSFER_OFFSITE','TRANSFER_INTRACOMPANY')
GROUP BY cb.type;
```

**Live execution status (2026-06-29):** the MCP endpoint was unreachable at first-draft time but was
**reachable on re-run and the query executed** (results above, OQ-1 resolved). It is further
corroborated by:

1. **Cardinality — single-order transfer batches**: sibling [[260629-transfer-lane-leak-on-cancel]]
   §1 (DB-verified `true`, same tenant `wms2-wineco-dev`, same date 2026-06-29) found all leaked
   transfer orders were `fulfillmenttype='Transfer'`, **single-order batches**. So a transfer
   `orderbatch_id` maps to exactly one `customerorder`, and the real `customerorder.id` is
   derivable via `SELECT id FROM customerorder WHERE orderbatch_id = :batchId` (the exact call
   `findByOrderbatchId(...).get(0)` already used by sibling endpoint B at `:343`).
2. **Distinct id spaces (static)**: `customerorder.id` and `customerorder_batch.id` are different
   columns on different tables backed by the shared `seqentities` sequence (see memory
   `wms2-seqentities-dual-island-id-space`); they coincide only by astronomically-unlikely
   accident. The DTO already proves they differ — it carries `id` and `customerOrderId` as two
   separate fields populated from two separate projection accessors (§1.3).

Verdict: the batch-id ≠ co-id premise is sound; the single-order-batch derivation is the correct
and verified lever. Live numeric re-run is OQ-1 (non-blocking for design).

---

## 2. Root cause

The display/read path threads a **batch id** into a parameter (`customerOrderID`) that the JPQL
self-exclusion (`co.id != :customerOrderId`) requires to be a **customerorder id**. The write
paths (`assignTransferLaneToTransferOrder:89`, `activateTransferOrder:118`) correctly pass
`customerOrder.getId()`, so only the **controller read path** is wrong. The mislabel is invisible
on first activation (no self row) and only mis-behaves on **reassign / re-activate**, where it
hides the order's own currently-assigned lane.

Root cause class: **parameter semantic mismatch** at a controller boundary that the neighboring
endpoint (`/unitLoads`) already handles correctly — a copy-paste divergence, not a query defect.

---

## 4. Architecture / data-flow

```
selectLanePop.vue / changeLanePop.vue
  activate1Batch.id  ==  ActiveOrderBatchViewDto.id  ==  customerorder_batch.id   (BATCH id)
        │  POST {orderBatchId: <batchId>}
        ▼
store/outbound/transfer.js getAvailableTransferLanes  ──►  POST /v3/transfers/availableTransferLanes
        ▼
TransfersController.getAvailableTransferLanes (:367)
        Long orderBatchId = reqMap.get("orderBatchId")        ← BATCH id (correct read)
        transferOrderService.getAvailableTransferLanes(orderBatchId)   ← BUG: passed as customerOrderID
        ▼
TransferOrderService.getAvailableTransferLanes(Long customerOrderID) (:78)
        locationRepository.getAvailableTransferLanes(customerOrderID, FINISHED)
        ▼
LocationRepository JPQL:  ... AND co.id != :customerOrderId ...   ← expects customerorder.id, gets batch id
                                                                     → self-exclusion never matches the real order
```

Correct reference path (sibling endpoint B, `/unitLoads`, `:339-347`):

```
Long orderBatchId = reqMap.get("orderBatchId");
Customerorder customerOrder = customerorderRepository.findByOrderbatchId(orderBatchId).get(0);   // resolve real CO
transferOrderService.getTransferLineUnitLoads(customerOrder, ...);
```

---

## 5. Fix design — Before / After

### Chosen: Option (a) — resolve the real `customerOrderId` in the controller (backend-only)

Mirror the established `/unitLoads` pattern. Backward-compatible: the frontend keeps sending
`{orderBatchId}`; no `wms2-web-ui` change required.

**Before** — `TransfersController.java:367-372`:

```java
@RequestMapping(value = "/availableTransferLanes", produces = "application/json", method = RequestMethod.POST)
public List<Location> getAvailableTransferLanes(@RequestBody Map<String,Object> reqMap,
                                               @AuthenticationPrincipal Principal principal) {
    Long orderBatchId = Long.valueOf( (Integer) reqMap.get("orderBatchId") );
    return transferOrderService.getAvailableTransferLanes(orderBatchId);
}
```

**After**:

```java
@RequestMapping(value = "/availableTransferLanes", produces = "application/json", method = RequestMethod.POST)
public List<Location> getAvailableTransferLanes(@RequestBody Map<String,Object> reqMap,
                                               @AuthenticationPrincipal Principal principal) {
    Long orderBatchId = Long.valueOf( (Integer) reqMap.get("orderBatchId") );
    List<Customerorder> orders = customerorderRepository.findByOrderbatchId(orderBatchId);
    if (orders.isEmpty()) {
        return java.util.Collections.emptyList();   // batch has no order → no lanes (don't 500)
    }
    Customerorder customerOrder = orders.get(0);
    return transferOrderService.getAvailableTransferLanes(customerOrder.getId());
}
```

> Single-order transfer batches (§1.4) make `orders.get(0)` correct and unambiguous — identical
> assumption already relied on by `/unitLoads:343` and `transferOrderByOrderBatchId:95`.
> `customerorderRepository` and `Customerorder` are already imported/fields in this controller
> (used by `transferOrder`, `reassignTransferLane`, `activateTransferOrder`, etc.).

#### Empty-batch guard (chosen, included)

A bare `findByOrderbatchId(...).get(0)` throws `IndexOutOfBoundsException` (→ HTTP 500) if the batch
has no orders — a fix-introduced 500. The guard above is therefore **part of the chosen After
block** (not optional): an empty batch returns an empty lane list, which is the semantically correct
answer (no order → no lanes) and cannot 500. The existing `/unitLoads` and
`transferOrderByOrderBatchId` siblings share the same latent unguarded `.get(0)`; hardening those
two is deferred to OQ-2 (a shared sweep) — this plan applies the guard only to the endpoint it
touches.

### Alternatives considered

- **Option (b) — rename the param + change the frontend to send `customerOrderId`.** The DTO
  already carries `customerOrderId` (§1.3), so the UI *could* dispatch
  `{orderBatchId: this.activate1Batch.customerOrderId}` (or a renamed key). **Rejected** as the
  primary: touches two repos, breaks any other caller still POSTing `orderBatchId`, and the
  display query is the *only* consumer that needs the CO id — resolving server-side is strictly
  smaller and self-contained. Keep as fallback only if a future change must avoid the extra
  per-request `findByOrderbatchId` lookup.
- **Option (c) — change the JPQL to self-exclude by `orderbatch_id` instead of `co.id`.**
  **Rejected**: the same repo method (`getAvailableTransferLanesForUpdate`) is called by the write
  paths with a genuine `customerOrder.getId()` (`:89,:118`); changing the predicate semantics would
  break those correct callers or require two divergent queries. The parameter contract
  (`customerOrderId`) is right; only the controller's *argument* is wrong.
- **Option (d) — overload `TransferOrderService.getAvailableTransferLanes(batchId)` to resolve
  internally.** **Rejected**: pushes batch-vs-CO ambiguity into the service whose existing
  signature is explicitly `customerOrderID`; the write callers pass CO ids. Controller-level
  resolution keeps the service contract honest.

---

## 6. File change summary

| File | Change | LOC |
|------|--------|-----|
| `v2/wms2-api/.../controller/TransfersController.java` | `getAvailableTransferLanes` (`:367-372`) — resolve real CO via `findByOrderbatchId(orderBatchId)`, empty-batch guard returns `Collections.emptyList()`, pass `customerOrder.getId()` to the service | ~5 (was 1-line passthrough) |
| `v2/wms2-api/.../service/TransferOrderService.java` | fix two stale `LOG.debug` MESSAGE STRINGS in `getSKUOverview` (`:198` and `:240`) that read `customerOrderID=` when the logged value is a batch id; the method param is already correctly named `orderBatchId` — no var rename. So the §0-C log stops lying; **no behavior change** (in scope per OQ-4 resolved) | ~2 |
| `v2/wms2-api/src/test/java/net/aim_ai/wms/unit/controller/TransfersControllerUnitTest.java` | **already exists** — add a test method asserting the controller resolves the CO id (see §8); do not create a new class | +1 method |

No `wms2-web-ui` file is modified. No JPQL is modified. No migration.

---

## 7. Implementation steps

### Prerequisites

- [ ] Confirm `customerorderRepository` field + `Customerorder` import already present in
      `TransfersController` (they are — used by `transferOrder:77`, `activateTransferOrder:156`).
- [ ] SDKMAN: `export PATH` so `mvn`/`java` (Java 21) resolve (per memory
      `wms2-develop-preexisting-test-failures`).
- [ ] Run OQ-1 DB query once the `wms2-wineco-dev` MCP endpoint is reachable; paste numbers into §1.4.

### Steps

1. Edit `TransfersController.getAvailableTransferLanes` per §5 After (resolve CO via `findByOrderbatchId`, empty-batch guard returns `Collections.emptyList()`, pass `customerOrder.getId()`).
2. Fix two stale `LOG.debug` MESSAGE STRINGS in `TransferOrderService.getSKUOverview` (`:198` and `:240`) that read `customerOrderID=` when the logged value is a batch id — the method param is already correctly named `orderBatchId`, so this is no var rename, just two string edits. Cosmetic, no behavior change (OQ-4 resolved).
3. Add the unit test (§8).
4. `mvn clean compile` then `mvn test -Dtest=TransfersControllerUnitTest` (and any
   `TransferOrderServiceUnitTest`).
5. Run `bash sbdocs/9-System/scripts/verify-260629-transfers-available-lanes-orderbatchid-mislabel.sh`
   with `PROJECT_ROOT=/home/nampark/dev/wms-claude/v2/wms2-api`.
6. Manual click-path (§8).

### Horizontal-Scalability checklist (10 rows)

| # | Concern | Applies? | Note |
|---|---------|----------|------|
| 1 | Stateless request handling | Yes | Read-only display endpoint; no in-memory state introduced. |
| 2 | No node-local caches gating correctness | Yes | No cache touched. |
| 3 | Scheduled-job advisory lock | No | Not a scheduled job. |
| 4 | Idempotency of writes | N/A | Read-only (`GET`-semantics over POST body); no state change. |
| 5 | Tenant context propagation | Yes | Runs in HTTP scope; `TenantContext` set by `TenantFilter`. No `@Async`. |
| 6 | Transaction manager correctness | Yes | New `findByOrderbatchId` read uses repo default (`tenantTransactionManager`) — correct. |
| 7 | OSIV / lazy-init safety | Yes | Display query is the non-locking variant (`getAvailableTransferLanes`, `:57`) — already chosen to avoid `TransactionRequiredException` with OSIV off. Extra lookup is a simple repo call. |
| 8 | Connection-pool pressure | Yes | One extra short read per dialog open — negligible. |
| 9 | Race with concurrent lane assignment | Acceptable | Display path is advisory; the authoritative guard is `getAvailableTransferLanesForUpdate` (PESSIMISTIC_WRITE) at assign/activate time — unchanged. |
| 10 | N-replica amplification | No | Per-request, not a fan-out job. |

### v2-constraint checklist (8 rows)

| # | Constraint (CLAUDE.md) | Status |
|---|------------------------|--------|
| 1 | `@Transactional` on tenant service specifies `tenantTransactionManager` | N/A — no new `@Transactional`; repo read inherits tenant TM |
| 2 | No JPA association annotations / manual FK | OK — `findByOrderbatchId` is manual FK lookup already in use |
| 3 | Entity comparison by id, not `.equals()` | OK — passes `customerOrder.getId()` |
| 4 | Optional JPQL filter handles `NULL` + `''` | N/A — no new optional filter param |
| 5 | New migration numbering / never edit existing | N/A — no migration |
| 6 | Idempotency for `/rest/**` writes | N/A — `/v3/transfers`, read-only |
| 7 | Outbox vs `sendAfterCommit` for OMS notify | N/A — no OMS notification |
| 8 | Cache eviction for modified entities | N/A — no write, no cached entity changed |

---

## 8. Testing

### Unit (controller)

`TransfersControllerUnitTest` (extends `BaseControllerTest`) — **the class already exists**
(`src/test/java/net/aim_ai/wms/unit/controller/TransfersControllerUnitTest.java`); add a method,
do not create a new class:

- **Test `getAvailableTransferLanes_resolvesCustomerOrderIdFromBatch`**: mock
  `customerorderRepository.findByOrderbatchId(BATCH_ID)` → `[co]` where `co.getId() == CO_ID` and
  `CO_ID != BATCH_ID`. POST `{orderBatchId: BATCH_ID}`. Assert
  `transferOrderService.getAvailableTransferLanes(CO_ID)` is invoked (`ArgumentCaptor<Long>` equals
  `CO_ID`, **not** `BATCH_ID`). This is the regression guard for the mislabel.

### Service (optional, self-exclusion semantics)

If a `TransferOrderServiceUnitTest` / repo slice exists: assert that for an order holding lane `L`,
`getAvailableTransferLanes(co.getId())` **includes** `L` (self-exclusion keeps own lane), while
calling with a foreign id **excludes** `L`. Documents the behavior the fix restores.

### Manual click-path (the acceptance demo)

1. Pick a TRANSFER order that **already has a lane assigned** (state 505/510, `transferlane_id`
   not null) on `wms2-wineco-dev` (or seed one).
2. Open the **Activate / Change Lane** dialog (`openTransfers.vue` → `selectLanePop.vue` /
   `changeLanePop.vue`).
3. **Before fix**: the order's own currently-assigned lane is **missing** from the picker.
4. **After fix**: the order's own currently-assigned lane **appears** (selectable), alongside other
   free lanes. (First-activation orders with no lane are unaffected either way.)

### Integration

If a Testcontainers slice is added, mark `@Disabled("TODO(SBDEV-2217): v2 IT harness broken")`
per memory `wms2-it-harness-broken-sbdev-2217` — the v2 Postgres IT lane cannot boot. Gate on unit
tests + `mvn clean compile`.

---

## 9. Risks

| Risk | Likelihood | Mitigation |
|------|-----------|------------|
| Batch has zero orders → `.get(0)` throws (HTTP 500) | Low | Guard included in §5 After — returns empty lane list, cannot 500. (The unguarded sibling `.get(0)` calls in `/unitLoads` + `transferOrderByOrderBatchId` remain a deferred shared sweep — OQ-2.) |
| Multi-order transfer batch (cardinality assumption breaks) | Very low | §1.4 + sibling plan: transfer batches are single-order. `.get(0)` is already the de-facto contract for transfers. If multi-order transfers ever appear, OQ-3. |
| Extra `findByOrderbatchId` read per dialog open | Negligible | One indexed lookup; same query the sibling endpoints already issue. |
| Behavior change surprises QA (lane now appears) | Low | This is the intended fix; documented in §8 click-path. Only reassign/re-activate is affected; first activation unchanged. |

---

## 10. Open questions / ADR

### Open questions

- **OQ-1 — RESOLVED (verified on `wms2-wineco-dev`, 2026-06-29):** confirmation query ran — **24 transfer batches, `avg_orders_per_batch = 1.00`, `max_orders_per_batch = 1`, `rows_where_coid_equals_batchid = 0`** (across 24 transfer orders). Confirms (a) transfer batches are single-order → `findByOrderbatchId(batchId).get(0)` is the correct CO, and (b) the batch id is never equal to the CO id → the current code's self-exclusion `co.id != :customerOrderId` never matches the real order. `db_verified: true`. (Also closes OQ-3: no multi-order transfer batches exist.)
- **OQ-2 (shared, defer):** the empty-batch guard is now applied to **this endpoint only**
  (`availableTransferLanes` — see §5 After). The unguarded `findByOrderbatchId(...).get(0)` in
  `unitLoads` (`:343`) and `transferOrderByOrderBatchId` (`:95`) remains: fix those two in one
  shared sweep or leave per current behavior? **Recommend defer** (out of this scope).
- **OQ-3 (data model):** Are multi-order TRANSFER batches possible in any tenant? If yes, the
  single-order `.get(0)` derivation for the lane picker is ambiguous and needs a different design.
- **OQ-4 — RESOLVED (requester decision 2026-06-29): INCLUDE the log-string fix.** Fix the two stale
  `LOG.debug` MESSAGE STRINGS in `TransferOrderService.getSKUOverview` (`:198` and `:240`) that read
  `customerOrderID=` when the logged value is a batch id. The method param is **already** correctly named
  `orderBatchId` — there is NO local var named `customerOrderID` to rename; this is only two string edits
  (zero behavior change; the value genuinely is a batch id). In scope for this plan (§6 row, §7 step 2).

### ADR — resolve CO id in controller (Option a)

- **Context:** Display query needs `customerorder.id` for its self-exclusion; UI sends a batch id;
  the DTO already carries both ids.
- **Decision:** Resolve `customerorder.id` server-side via the existing
  `findByOrderbatchId(...).get(0)` pattern (same as `/unitLoads`), keeping the wire contract
  (`{orderBatchId}`) and the service signature (`customerOrderID`) unchanged.
- **Consequences:** Backend-only (~5 lines incl. empty-batch guard), backward-compatible; no UI
  change; consistent with sibling endpoint B. Relies on single-order transfer batches (verified).
  The misleading `co.id` vs `orderbatch_id` ambiguity is removed at the only call-site that
  mattered.
- **Rejected:** (b) frontend sends `customerOrderId` — two-repo change, breaks other callers;
  (c) change JPQL self-exclusion column — breaks the correct write-path callers; (d) overload the
  service — muddies an honest signature.

---

## Acceptance

Run: `PROJECT_ROOT=/home/nampark/dev/wms-claude/v2/wms2-api bash sbdocs/9-System/scripts/verify-260629-transfers-available-lanes-orderbatchid-mislabel.sh`

The script asserts (positive) that `getAvailableTransferLanes` resolves a real customerorder id
(`findByOrderbatchId(orderBatchId)` present and `getAvailableTransferLanes(customerOrder.getId())`
called), that the empty-batch guard is present (`orders.isEmpty()` → `Collections.emptyList()`,
check A5), and (negative) that the old straight-through
`transferOrderService.getAvailableTransferLanes(orderBatchId)` call is gone.

---

## 11. Implementation Status — implemented 2026-06-29

**Branch:** `fix/260629-transfers-available-lanes-orderbatchid-mislabel` (off `develop`) · **PR:** [SiteBossInc/wms2-api#57](https://github.com/SiteBossInc/wms2-api/pull/57) → `develop` · **Commit:** `f619f94`

| Change | Site | Status |
|---|---|---|
| Resolve real CO id from batch id + empty-batch guard | `TransfersController.getAvailableTransferLanes` (`:370-376`) | ✅ done |
| Fix two stale `LOG.debug` message strings (`customerOrderID=`→`orderBatchId=`) | `TransferOrderService.getSKUOverview` (`:197`, `:239`) | ✅ done |

**Tests added** (`TransfersControllerUnitTest`, nested `GetAvailableTransferLanes`): `getAvailableTransferLanes_resolvesCustomerOrderIdFromBatchId` (ArgumentCaptor: CO id 7001, not batch id 9001, reaches the service); `getAvailableTransferLanes_emptyBatch_returnsEmptyListWithoutCallingService` (200 + empty list, service `never()` called).

**Results:** `mvn clean compile` SUCCESS (Java 21) · `TransfersControllerUnitTest` = **20 run, 0 failures** · verify script = **6 pass, 0 fail**.

**Process:** ralplan (Architect SOUND, Critic APPROVE after the cosmetic-step correction + empty-batch guard fold-in) → TDD gate (2 red tests) → implement → code review **SHIP** (0 critical/high/medium; 2 NITs fixed in-PR — FQN `Collections`, unused `lenient()`). DB verified (`db_verified: true`). Also fixed a verify-harness false-negative (`mvn_test_passes` greps suppressed `-q` output → now uses mvn exit code).

**Deferred follow-up (OQ-2):** apply the same empty-batch guard to the still-unguarded sibling `.get(0)` sites (`/unitLoads`, `transferOrderByOrderBatchId`), or extract a `resolveLeadOrder(batchId)` helper.
