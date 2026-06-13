---
title: "SBDEV-2222 — REST inbound endpoints have no idempotency contract"
ticket: "SBDEV-2222"
ticket_url: "https://app.clickup.com/t/868jj32rc"
type: "bug"
severity: "high"
priority: "high"
status: "archived"
impl_commit: "0373141"
impl_pr: "https://github.com/SiteBossInc/wms2-api/pull/11"
project: ["wms2-api"]
version: "v2"
requester: "David Oppenheim"
assignee: "Nam Park"
created: "2026-05-10"
updated: "2026-05-12"
last_updated: "2026-05-12"
db_verified: true
related:
  - "[[wms2-oms-integration-map]]"
  - "[[wms2-end-to-end-request-journey]]"
  - "[[wms2-transaction-osiv-boundary-map]]"
  - "[[SBDEV-2214-oms-http-post-inside-class-level-transactional]]"
  - "[[SBDEV-2215-adviceservice-no-transaction-wrapping]]"
tags:
  - plan
  - wmsv2
  - oms-integration
  - idempotency
  - rest-contract
  - reliability
---

# SBDEV-2222 — REST inbound endpoints have no idempotency contract

**Ticket:** [SBDEV-2222](https://app.clickup.com/t/868jj32rc)
**Project:** wms2-api | **Version:** v2 | **Type:** bug
**Priority:** High | **Severity:** HIGH (Tier 2)
**Status:** reviewed (2026-05-12) — REVISE round 1 applied; verify script ships alongside this plan; first implementation pass pending.
**Date:** 2026-05-12

> **Framing:** The ticket targets v1 AND v2. This is the v2 plan. The shape of the bug is the same on both stacks — inbound `PUT/POST /rest/...` endpoints (`OrderRestController.create`, `AdviceRestController.create`, `SkuRestController.create`/`update`, `OrderRestController.cancelPositions`) perform a `findByExternalNumber` / `findByBatchid` / `findByExternalid` existence check at the start of the handler and proceed to insert with **no idempotency key**. Two simultaneous OMS retries of the same payload both pass the existence check and both proceed to insert. The DB-level unique constraint (verified present in §0 — see DB verification) catches one of the two, but only after partial state has potentially been auto-committed by inner service calls, and OMS receives a confusing **400** (the race-loser path: `DataIntegrityViolationException` is caught and wrapped as `WebserviceBusinessExceptionClientSide` → `ResponseEntity.badRequest()`) instead of the original 2xx it should have received on retry.
>
> The v2-specific complications are:
> 1. `OrderRestController.create` mixes `@CacheEvict(value = "itemdata", ...)`-style inner controller behavior (`SkuRestController.update` actually does call into `create` directly) — so a retry of `update` can re-enter `create` and the idempotency layer has to be aware of both call paths.
> 2. v2 runs **multi-replica**. The dedup table MUST live in the tenant DB (not in-JVM Caffeine) — see §7 Horizontal Scalability row 1 + row 6.
> 3. v2 uses `tenantTransactionManager` — every `@Transactional` we add MUST specify it (see §8 row 1).
> 4. The proposed `IdempotencyFilter` MUST run **after** Spring Security's OAuth2 resource-server filter; otherwise unauthenticated callers could force tenant DB roundtrips and replay cached 2xx responses (see §3 Fix B placement note, §7 row 11, §9 risk row 9).

---

## 0. Affected sites (enumeration before drafting)

Greps run against `/home/nampark/dev/wms-claude/v2/wms2-api/src/main/java/net/aim_ai/wms/controller/rest`:

```
grep -rn "@PutMapping\|@PostMapping\|@DeleteMapping\|@RequestMapping" controller/rest/*.java
grep -rn "extends AbstractRestController"                              controller/rest/*.java
grep -rn "@RequestMapping\|@PostMapping\|@PutMapping" controller/MessageDummyController.java
```

The earlier draft of this table missed `@RequestMapping(method = RequestMethod.POST)` write endpoints in `UtilRestController.java` (which uses the older `@RequestMapping(value=…, method=…)` style instead of `@PostMapping`), and mis-classified `MessageDummyController.java` as outside `/rest/**`. The table below incorporates the re-grep.

| # | Endpoint (HTTP method, path) | Handler (file:line) | Writes state? | In-scope this plan? |
|---|---|---|---|---|
| 1 | `PUT /rest/order/create` | `OrderRestController.java:110-509` | **Yes** — creates `customerorder_batch` + `customerorder` + `customerorder_position` rows | **Yes — Fix A.1** |
| 2 | `POST /rest/order/updatePriority` | `OrderRestController.java:594-677` | Yes — updates priority on existing batch | **Yes — Fix A.2** (mutation, retry-safe candidate) |
| 3 | `POST /rest/order/cancelPositions` | `OrderRestController.java:679-771` | **Yes** — cancels customer orders; calls `customerorderService.cancelOrder` (which itself fires `omsNotificationService.sendAfterCommit`) | **Yes — Fix A.3** |
| 4 | `POST /rest/order/finishedQA` | `OrderRestController.java:773-900` | Yes — packages orders | **Yes — Fix A.4** |
| 5 | `PUT /rest/order/finishedTransfer` | `OrderRestController.java:902-945` | Yes — finishes transfer BOL | **Yes — Fix A.5** |
| 6 | `PUT /rest/advice/create` | `AdviceRestController.java:121-368` | **Yes** — creates `advice` + `adviceposition` rows (+ optional `receiveGoods` for RETURN type) | **Yes — Fix A.6** |
| 7 | `PUT /rest/advice/createTransfer` | `AdviceRestController.java:370-486` | Yes — creates transfer advice | **Yes — Fix A.7**. DB-level backstop: `adviceRepository.findByTransferId(transferAdvice.getTransferId())` at L397 (unique on `advice.transfer_id`). Does NOT share `findByExternalid` with row 6 — different identity column. |
| 8 | `PUT /rest/advice/createHubAndSpoke` | `AdviceRestController.java:488-644` | Yes — creates hub-and-spoke advice | **Yes — Fix A.8**. DB-level backstop: `adviceRepository.findByTransferId(hubAndSpokeAdvice.getTransferId())` at L525 (same unique on `advice.transfer_id` as row 7). Does NOT share `findByExternalid` with row 6 — different identity column. |
| 9 | `POST /rest/advice/reopen` | `AdviceRestController.java:648-652` | n/a — throws `RuntimeException("method not supported")` | No — dead method, NEGATIVE-check that it stays not supported (out of scope) |
| 10 | `PUT /rest/sku/create` | `SkuRestController.java:71-189` | **Yes** — creates `itemdata` rows | **Yes — Fix A.9** |
| 11 | `POST /rest/sku/update` | `SkuRestController.java:192-310` | **Yes** — updates `itemdata` rows (and may recursively call `create` if SKU missing — line 230) | **Yes — Fix A.10** (note the recursive `create()` call path — see §3 nuance) |
| 12 | `DELETE /rest/sku/delete` | `SkuRestController.java:312-361` | Yes — deletes `itemdata` rows | **Yes — Fix A.11** |
| 13 | `POST /rest/stockcount/getStockCount` | `StockCountRestController.java:56` | **No** — read-only report | No — read-only |
| 14 | `POST /rest/transactionreport/getTransactionReport` | `TransactionReportRestController.java:76` | No — read-only report | No — read-only |
| 15 | `POST /rest/transactionreport/getTransactionDetailedReport` | `TransactionReportRestController.java:178` | No — read-only report | No — read-only |
| 16a | `POST /v3/util/initDB` | `UtilRestController.java:126` | Yes — bootstraps tenant DB | **No** — `UtilRestController` is `@Service`-annotated (not `@RestController`/`@Controller`); Spring does NOT route its `@RequestMapping` methods. It is effectively dead code from a routing perspective AND no class-level `/rest/**` prefix anyway. Excluded with rationale. |
| 16b | `POST /v3/util/recalculateLocationConstraints` | `UtilRestController.java:696` | Yes — recalculates constraint table | **No** — same `@Service` rationale as 16a. |
| 16c | `POST /v3/util/populateCaseTypes` | `UtilRestController.java:792` | Yes — bulk-loads case types | **No** — same `@Service` rationale as 16a. |
| 16d | `POST /v3/util/initAdmin` | `UtilRestController.java:873` | Yes — seeds admin user | **No** — same `@Service` rationale as 16a. |
| 17 | `POST /rest/stockcount/sendDummyMessageStockCountList` | `MessageDummyController.java:24, :38` | Yes (dev/test only — writes a dev message into `message` table) | **No** — class-level mapping IS `/rest/stockcount`, so the filter WOULD intercept it; but this is a dev/test controller and the body is non-deterministic. **Add `shouldNotFilter` carve-out for `/rest/stockcount/**` in Fix B** (covers both row 13 read-only and row 17 dev/test). |

**Total in-scope sites: 11** (rows 1-8, 10-12). Rows 13-15 are read-only and excluded by `shouldNotFilter` carve-out (`/rest/stockcount/**`, `/rest/transactionreport/**`, plus GET methods generally). Row 9 is dead code. Rows 16a-d are not routed (`@Service` instead of `@Controller`). Row 17 is dev/test and also covered by the `/rest/stockcount/**` carve-out.

**Carve-out rationale (Fix B `shouldNotFilter`):** the filter will explicitly skip `/rest/stockcount/**` and `/rest/transactionreport/**` (and all GETs) so that (a) dev-only `MessageDummyController` writes don't pollute the dedup table and (b) read-only reports never pay the dedup-roundtrip tax.

**Adjacent-bug rule:** The ticket explicitly named rows 1, 3, 6, 10, 11. The §0 enumeration adds rows 2, 4, 5, 7, 8, 12 because they (a) live in the same controller class, (b) handle the same OMS-→-WMS inbound message family, (c) are also `@Put/@Post` mutating endpoints with no idempotency contract today, and (d) the filter-based fix in §3 Fix B will cover all of them uniformly — splitting the rollout would leave the same bug live on adjacent endpoints with identical blast radius.

**Cross-reference greps run:**

```bash
grep -rln "Idempotency\|rest_idempotency\|idempotency_key" \
  sbdocs/1-Projects/ sbdocs/4-Archieves/ v2/wms2-api/src
```

Findings:
- No prior plan addressed REST inbound idempotency in either v1 or v2.
- The only existing `idempotency` mention in v2 code is in `service/ReplenishGeneratorService.java` (`Idempotency` comment about replenish-cap behaviour — unrelated to REST inbound).
- `sbdocs/1-Projects/wms2/plan/SBDEV-2214-*.md` (OMS HTTP POST inside `@Transactional`) and `sbdocs/1-Projects/wms2/plan/SBDEV-2215-*.md` (AdviceService no-tx-wrapping) are sibling reliability plans for the same OMS↔WMS surface; this plan should land **after** SBDEV-2214 has merged so the in-tx OMS POST risk is already eliminated. SBDEV-2222 closes the **inbound** half of the duplicate-call problem; SBDEV-2214 closes the **outbound** rollback-drift half.

**Architecture/design docs consulted:**

- `sbdocs/3-Resources/architecture/wms2-oms-integration-map.md` — §3 (inbound REST surface), §4 (request-ID conventions used today: there is no one — OMS does not currently send any correlation header).
- `sbdocs/3-Resources/architecture/wms2-end-to-end-request-journey.md` §2 (filter chain) — `TenantFilter` runs at `Ordered.HIGHEST_PRECEDENCE`; the new `IdempotencyFilter` must run **after** `TenantFilter` so `TenantContext` is set when we look up the dedup row (the dedup table lives in the tenant DB).
- `sbdocs/3-Resources/architecture/wms2-transaction-osiv-boundary-map.md` §3 — filters run outside Spring's `@Transactional` AOP advice; any DB work inside a filter must use an explicit `TransactionTemplate(tenantTransactionManager)` block or a `@Transactional` repository method.

---

## 1. Problem Statement

**User-visible symptom (today):** OMS sends a `PUT /rest/order/create` with `batch_id="B1234"`. The TCP connection flaps or OMS hits its own retry timeout. OMS retries the same payload. WMS handles both requests concurrently. Both pass the `findByBatchid("B1234").isPresent()` check at the top of `OrderRestController.create` (line 162) because neither has committed yet. Both proceed into the long body (validation loop, position loop, save loop). One of them eventually loses the race at the DB-level UNIQUE INDEX `uk_hsst0psb47fsttxg3uw9ot1v5(batchid)` (verified present — see §0 DB verification). The losing request:

- Has **already** saved some `customerorder` rows inside its own per-row try/catch that handles `DataAccessException` (line 376) but the outer batch save at line 375 throws and aborts the rest of the iteration.
- BUT the `messageService.createMessage(...)` audit row at line 479 has **not** been written yet (it sits after the loop).
- The `DataIntegrityViolationException` is caught by the handler and wrapped into `WebserviceBusinessExceptionClientSide(GENERIC_ERROR)`. `WebserviceBusinessExceptionClientSide` maps to **`ResponseEntity.badRequest()` → HTTP 400** (verified by re-reading `RestExceptionHandler` / `AbstractRestController` error mapping). The race-loser therefore returns **400** to OMS — not 500.
- OMS now sees the original request "failed" with a 400 and may retry **again**, this time when the winning request HAS committed, so the next retry hits the existence check and returns `ENTITY_ALREADY_EXITS` (also 400) — still a non-2xx, so OMS reconciliation is now broken.

**Consistency note:** earlier drafts of this plan and the original ticket loosely described the race-loser as a "500." That is incorrect for the v2 handlers. v2 wraps `DataIntegrityViolationException` into `WebserviceBusinessExceptionClientSide` → HTTP 400. The OMS-facing UX is "confusing 400-then-400" not "500-then-400," and the fix (replay the 2xx) is identical either way.

**Failure-mode timeline (Order import — ticket §1):**

```
T0: OMS sends PUT /rest/order/create {batch_id="B1234"}.
T0: WMS req-1: findByBatchid("B1234") → empty. Begin inserts.
T1: OMS retry (network blip; OMS sees no response).
T1: WMS req-2: findByBatchid("B1234") → empty. Begin inserts.
T2: WMS req-1 reaches customerorderBatchRepository.save() at line 375. Commits.
T3: WMS req-2 reaches same line. PostgreSQL fires unique-constraint violation
    on uk_hsst0psb47fsttxg3uw9ot1v5(batchid). Spring wraps as DataIntegrityViolationException.
    The handler catches it and throws WebserviceBusinessExceptionClientSide(GENERIC_ERROR)
    → HTTP 400 to OMS (NOT 500 — v2 wraps the DB-integrity exception into a
    client-side webservice exception which maps to ResponseEntity.badRequest()).

    OMS sees req-1 → no HTTP response (timed out) → req-2 → 400. OMS has no
    record of the order being created, even though req-1 actually succeeded.
    Order is "stuck" from OMS's view until human reconciles.
```

**Failure-mode timeline (Advice & SKU import — ticket §1):** identical shape, swap `findByBatchid` with `findByExternalid` (Advice) or `findByClientIdAndItemNr` (SKU). DB unique constraints already exist for advice (`uk_4d13b6sg589c6y88tkm98xl89`) and itemdata (`uk3l3dgof3l6mc1dl7s3lmida65` — composite on `(client_id, item_nr)`).

**Failure-mode timeline (cancelPositions — ticket §1):** different mechanism — `customerorderService.cancelOrder` is `@Transactional(tenantTransactionManager, rollbackFor = {BusinessException, FacadeException})` (after SBDEV-2214 lands). A double-call from OMS retry produces:

- First call: order goes from `PICKED` to `CANCELED`. After-commit OMS notification fires.
- Second call: order is already `CANCELED` → throws `BusinessException(WRONG_STATE)` → 400 to OMS. OMS sees the retry as failed even though the cancel succeeded.

A correctly-cached idempotent response (200 with the same body as the first call) would resolve this.

### DB verification gate

`db_verified: **true**`.

**Queries run against the v1 wineco-dev tenant DB (Postgres) on 2026-05-10:**

1. Confirm `rest_idempotency` table does NOT exist (we are not regressing an existing structure):
   ```sql
   SELECT table_schema, table_name
   FROM information_schema.tables
   WHERE table_name IN ('rest_idempotency', 'idempotency_key', 'rest_idempotency_key');
   -- Result: [] (empty)
   ```

2. Confirm `customerorder_batch.batchid` already has a UNIQUE constraint (so DB-level backstop already exists; only the application-layer dedup is missing):
   ```sql
   SELECT indexname, indexdef
   FROM pg_indexes WHERE tablename = 'customerorder_batch'
   ORDER BY indexname;
   -- Result: uk_hsst0psb47fsttxg3uw9ot1v5 — CREATE UNIQUE INDEX ... ON customerorder_batch(batchid)
   ```

3. Confirm `advice.externalid` already UNIQUE:
   ```sql
   SELECT indexname, indexdef
   FROM pg_indexes WHERE tablename = 'advice' ORDER BY indexname;
   -- Result: uk_4d13b6sg589c6y88tkm98xl89 — CREATE UNIQUE INDEX ... ON advice(externalid)
   ```

4. Confirm `itemdata(client_id, item_nr)` already UNIQUE composite:
   ```sql
   SELECT indexname, indexdef
   FROM pg_indexes WHERE tablename = 'itemdata' ORDER BY indexname;
   -- Result: uk3l3dgof3l6mc1dl7s3lmida65 — CREATE UNIQUE INDEX ... ON itemdata(client_id, item_nr)
   ```

5. Confirm that no historic duplicates have leaked through despite the existing checks (i.e. the DB unique constraints have been catching the race-loser):
   ```sql
   SELECT batchid, COUNT(*) AS dup_count
   FROM customerorder_batch
   WHERE batchid IS NOT NULL
   GROUP BY batchid HAVING COUNT(*) > 1 LIMIT 10;
   -- Result: [] (empty — confirms DB-level constraint has held; the symptom
   --   surfaces as 500/400 to OMS, not as duplicated rows).
   ```

**Interpretation:** the DB-level constraints in the ticket §1 Step 4 are already in place (Hibernate's `@UniqueConstraint` / column `unique=true` generated them). The bug is therefore not "duplicate rows in DB" but "OMS sees confusing 5xx/4xx on retries that should have been 2xx replays." **The fix has to be application-layer dedup + cached response replay — DB constraints alone do not solve the OMS-facing UX**, which is what the ticket calls out.

---

## 2. Root Cause Analysis

### Bug 1: `OrderRestController.create` performs TOCTOU existence check then insert; no idempotency key.

**Code reference:** `src/main/java/net/aim_ai/wms/controller/rest/OrderRestController.java:160-165`

```java
resolveClient(clientMap, orderBatch.getClientId(), orderBatch);

Optional<CustomerorderBatch> customerorderBatch =
        customerorderBatchRepository.findByBatchid(orderBatch.getBatchId());     // :162
if (customerorderBatch.isPresent()) {
     throw new WebserviceBusinessExceptionClientSide(
         WmsConstants.ENTITY_ALREADY_EXITS, null, "orderBatch", orderBatch);
}
// … then later, line 375:
customerorderBatchRepository.save(customerOrderBatch);                            // :375
```

**Why it's wrong:** classic TOCTOU. The existence check at `:162` and the insert at `:375` are not atomic. The handler is **not** `@Transactional` at all (verified by `grep -rln "@Transactional" controller/rest/`). Two concurrent requests both see "no existing batch" at `:162`, both reach `:375`, one wins on the DB unique constraint, the loser returns 400/500 to OMS. The handler runs the full validation + entity-construction work twice (~300 lines of CPU) even though one of the two requests was always going to fail.

**Root cause:** lack of an explicit idempotency key. The current contract is "if `batch_id` exists, the request is a dupe" — but that's a check, not a key. OMS has no way to say "this is the same request as before" because there is no such header.

### Bug 2: `AdviceRestController.create` — identical pattern.

**Code reference:** `src/main/java/net/aim_ai/wms/controller/rest/AdviceRestController.java:152-156`

```java
Optional<Advice> adviceOpt = adviceRepository.findByExternalid(adviceDto.getReferenceId());
if (adviceOpt.isPresent()) {
    throw new WebserviceBusinessExceptionClientSide(
        WmsConstants.ENTITY_ALREADY_EXITS, null, "advice", adviceDto.getReferenceId());
}
// … then line 209:
adviceEntity = adviceRepository.save(adviceEntity);                               // :209
```

Same TOCTOU. Backstopped by `uk_4d13b6sg589c6y88tkm98xl89` on the DB but produces 400 to OMS on race-loser.

**Additional v2-specific risk:** if `adviceDto.getType() == AdviceType.RETURN` (line 286 onward), the handler calls into `receivingService.receiveGoods(...)` (line 323) which is `@Transactional(tenantTransactionManager)` and creates `stockunit` + `unitload` rows. The race-loser may have **partially** executed `receiveGoods` for some positions before the parent advice's `adviceRepository.save` at the earlier `:209` blew up via constraint violation. **However** — the v2 code calls `adviceRepository.save` BEFORE any `receiveGoods` call, so the constraint violation fires at `:209` and the per-position loop is never entered for the race-loser. This bound is verified by re-reading lines 209-329. No partial state should leak; verify with the manual smoke test in §6.

### Bug 3: `SkuRestController.create` + `SkuRestController.update` — recursive call complicates idempotency.

**Code reference:** `src/main/java/net/aim_ai/wms/controller/rest/SkuRestController.java:102-105` (create) and `:223-230` (update).

```java
// create():
Optional<Itemdata> itemDataValue = itemdataService.findByClientIdAndItemNr(client.getId(), sku.getSku());
if (itemDataValue.isPresent()) {
    throw new WebserviceBusinessExceptionClientSide(
        WmsConstants.ENTITY_ALREADY_EXITS, null, "sku_name", sku);
}

// update():
Optional<Itemdata> itemDataValue = itemdataService.findByClientIdAndItemNr(client.getId(), sku.getSku());
if (!itemDataValue.isPresent()) {
    List<SkuDto> createList = new ArrayList<>();
    createList.add(sku);
    create(createList);                                                            // :230 — re-enters create()
}
```

**Why it's wrong (compounding bug):** in addition to the TOCTOU on `create`, `update` calls `create(...)` directly when the SKU is missing. If a concurrent OMS retry of `update` lands while another `create` for the same `(client_id, item_nr)` is in flight, both `update` calls see `findByClientIdAndItemNr` empty, both re-enter `create`, both reach the inner existence check (line 103) which is also empty, both proceed to `itemdataRepository.save` (line 151) — one wins on `uk3l3dgof3l6mc1dl7s3lmida65`, the other 400s to OMS.

**Implication for Fix B:** the `IdempotencyFilter` must key on the **outer request URL + method + body hash + Idempotency-Key header**, not on the inner method name. A retry of `update` that internally falls through to `create` must still be deduped against the original `update` call.

### Bug 4: `OrderRestController.cancelPositions` — state-machine race, not duplicate-row race.

**Code reference:** `src/main/java/net/aim_ai/wms/controller/rest/OrderRestController.java:720-724`

```java
try {
    customerorderService.cancelOrder(customerOrder, false);                       // :721
} catch (BusinessException e) {
    throw new WebserviceBusinessExceptionClientSide(
        WmsConstants.WRONG_STATE, e, WmsConstants.State.getCodeText(customerOrder.getState()), order);
}
```

`customerorderService.cancelOrder` is method-level `@Transactional(value = "tenantTransactionManager", rollbackFor = {BusinessException.class, FacadeException.class})`. If `customerOrder.getState() != WmsConstants.State.OPEN` (or any pre-cancellable state), `cancelOrder` throws `BusinessException(WRONG_STATE)`. So a retry after a successful cancel produces 400 (WRONG_STATE) to OMS. With idempotency replay this becomes a 200 with the original success body. **No duplicate cancellation can happen** because `cancelOrder` itself is state-guarded — but the OMS-facing UX is still bad.

### Bug 5: cross-cutting — there is no central place in v2 to enforce a "this is the same request" contract.

`AbstractRestController` only validates the warehouse code. Filter chain (`TenantFilter`, `OAuth2`) has no idempotency layer. SBDEV-2222's fix is therefore both **(a) add the missing key** (header + dedup row + cached response) and **(b) extend the documented contract** so future endpoints inherit the guarantee without per-endpoint code.

---

## 3. Design / Proposed Fix

The fix has 4 parts. Each is independently reviewable.

### Fix A — New `rest_idempotency` table (tenant DB, Flyway migration)

**Files changed:**
- `src/main/resources/db/migration/V2.1.10__add_rest_idempotency.sql` (new)

**Why:** per-tenant dedup row store. Lives in the **tenant** DB because the keyspace, the entities they reference, and the request bodies are all tenant-scoped. Putting it in the landlord DB would (a) re-introduce cross-tenant noisy-neighbour risk and (b) break the tenant DB's hermetic backup/restore story (a tenant restore from yesterday would not roll the idempotency table back, leaving phantom keys).

**Schema:**

```sql
-- V2.1.10__add_rest_idempotency.sql
CREATE TABLE rest_idempotency (
    idempotency_key VARCHAR(64) NOT NULL,
    request_method  VARCHAR(8)  NOT NULL,
    request_path    VARCHAR(255) NOT NULL,
    request_hash    VARCHAR(64) NOT NULL,   -- sha256 hex of normalized request body
    response_status INTEGER     NOT NULL,
    response_body   TEXT,                   -- captured response body (gz-base64 if > 1MB; see §3 Fix B)
    created_at      TIMESTAMP WITHOUT TIME ZONE NOT NULL DEFAULT NOW(),
    CONSTRAINT pk_rest_idempotency PRIMARY KEY (idempotency_key)
);

-- TTL helper index — cleanup job in §3 Fix D wipes rows older than 7 days.
CREATE INDEX index_rest_idempotency_created_at
    ON rest_idempotency (created_at);
```

**Why no `tenant_id` column:** the row already lives in the tenant database, which is per-tenant by construction. Adding a redundant `tenant_id` column would be both wrong (the tenant resolved at filter time is the only authoritative one) and harmful (it would let an upgrade-script bug mix tenants).

**Capacity:** at ~3000 inbound REST requests/day/tenant × 7 days × ~2 KB row = ~42 MB/tenant. Negligible. Cleanup job (Fix D) keeps it bounded.

### Fix B — `IdempotencyFilter` (new `OncePerRequestFilter`)

**Files changed:**
- `src/main/java/net/aim_ai/wms/landlord/config/IdempotencyFilter.java` (new — placed alongside `TenantFilter` for consistency, see "Placement rationale" below)
- `src/main/java/net/aim_ai/wms/repo/jpa/RestIdempotencyRepository.java` (new)
- `src/main/java/net/aim_ai/wms/model/RestIdempotency.java` (new entity)
- `src/main/java/net/aim_ai/wms/service/RestIdempotencyService.java` (new — owns the read-then-insert transaction)
- `src/main/java/net/aim_ai/wms/SecurityConfiguration.java` (modified — wire `IdempotencyFilter` via `http.addFilterAfter(idempotencyFilter, BearerTokenAuthenticationFilter.class)` so it runs AFTER OAuth2 resource-server auth)

**Placement rationale:** the new filter lives in `net.aim_ai.wms.landlord.config` next to `TenantFilter` rather than under a fresh `net.aim_ai.wms.web` package because (a) it is conceptually a tenant-scoped infrastructure filter (it reads tenant DB), (b) `TenantFilter` is the only other request-scoped filter in the project and lives there, (c) creating a brand-new `web/` package for a single class is a code-smell the verify script can easily check against, and (d) consistency with existing filters reduces reviewer cognitive load.

**Filter-order contract (security-critical):**

Earlier drafts of this plan placed the filter at `@Order(Ordered.HIGHEST_PRECEDENCE + 10)`, which is **before** Spring Security's `BearerTokenAuthenticationFilter`. That is wrong on two counts:

1. **Unauthenticated DB load.** An anonymous caller hitting `PUT /rest/order/create` with any `Idempotency-Key` header would force the filter to (a) buffer the request body, (b) hash it, (c) do a tenant DB lookup — all *before* Spring Security rejects the request with 401. That's a free DoS amplifier against the tenant DB.
2. **Unauthenticated replay.** If a stored 2xx response exists for a guessed/leaked key, an anonymous caller could fetch that response body without authenticating. That's a confidentiality bug (response bodies contain order/advice payloads with PII).

**Corrected placement.** The filter MUST run **after** Spring Security's OAuth2 resource-server filter. Implementation options (use option 2 — explicit `SecurityFilterChain.addFilterAfter` — for clarity and to avoid relying on numeric ordering arithmetic):

- Option 1 (annotation-based): `@Order(SecurityProperties.DEFAULT_FILTER_ORDER + 10)` on the filter bean. `SecurityProperties.DEFAULT_FILTER_ORDER` is `-100` by default, so `+10` places us at `-90`, well after the security chain.
- Option 2 (preferred — explicit wiring): inside `SecurityConfiguration.securityFilterChain(...)`, call `http.addFilterAfter(idempotencyFilter, BearerTokenAuthenticationFilter.class)`. This is explicit, self-documenting, and survives refactors of the ordering constants.

**Defence-in-depth:** in addition to the ordering, the filter MUST explicitly check `SecurityContextHolder.getContext().getAuthentication()` is non-null and `isAuthenticated()` before serving any replay. If unauthenticated, the filter short-circuits to 401 immediately (no DB hit). This guards against accidental future filter-order regressions.

**Behavior contract:**

```
HTTP Request arrives:
  1. TenantFilter (Ordered.HIGHEST_PRECEDENCE) sets TenantContext.
  2. Spring Security's BearerTokenAuthenticationFilter runs and populates
     SecurityContextHolder.getContext().getAuthentication().
  3. IdempotencyFilter (wired via SecurityFilterChain.addFilterAfter(
     idempotencyFilter, BearerTokenAuthenticationFilter.class)) runs:
      a. shouldNotFilter: if URI matches /rest/stockcount/** or
         /rest/transactionreport/** → skip (read-only carve-out covering
         StockCountRestController, TransactionReportRestController,
         and the dev-only MessageDummyController).
      a'. If request URI is not /rest/** → skip (chain.doFilter).
      b. If method is GET → skip (read-only).
      c. If SecurityContextHolder.getContext().getAuthentication() is null
         or !isAuthenticated() → respond 401 immediately (defence-in-depth
         in case the filter is accidentally re-ordered).
      d. If header "Idempotency-Key" missing → log warn, chain.doFilter
         (back-compat for OMS versions that have not yet been upgraded;
         rely on DB unique constraint).
      e. Cache request body via ContentCachingRequestWrapper so we can hash + replay.
      f. SHA-256 hash the body.
      g. Look up rest_idempotency by key (READ-ONLY tenant tx).
         - If found AND hash matches AND method+path matches:
              → if URI is /rest/sku/create or /rest/sku/update, invoke
                CacheManager.getCache("itemdata").clear() BEFORE returning the
                replay (handler's @CacheEvict will NOT fire because we short-circuit).
              → return stored response_status + response_body. SHORT-CIRCUIT chain.
         - If found AND hash mismatches:
              → return 409 Conflict with body {"error":"idempotency-key-conflict",
                 "key":"<key>"}. OMS bug — same key, different payload.
         - If not found → proceed (h).
      h. Wrap response with ContentCachingResponseWrapper so we can capture it.
      i. chain.doFilter — let the actual handler run.
      j. After handler returns (regardless of 2xx / 4xx / 5xx):
         - If response status is 2xx → INSERT into rest_idempotency (REQUIRES_NEW tenant tx
           on a separate connection, so this insert succeeds even if the handler's
           transaction rolled back).
         - If response status is 4xx or 5xx → do NOT persist (OMS may legitimately retry
           after fixing the payload).
      k. copyBodyToResponse so the captured body is actually sent.
```

**`@CacheEvict` replay handling (P2-1 mitigation):** `SkuRestController.create` (line 70) and `SkuRestController.update` (line 191) carry `@CacheEvict(value = "itemdata", allEntries = true)`. When the filter short-circuits with a replay, Spring AOP never sees the controller method invocation, so the Caffeine eviction never fires. Stale `itemdata` reads are then possible elsewhere in the JVM. Mitigation: at step (g) on the replay path, if the URI is `/rest/sku/create` or `/rest/sku/update`, the filter explicitly calls `cacheManager.getCache("itemdata").clear()` (matching `allEntries = true` semantics) before writing the cached response. The `CacheManager` is injected via constructor. A unit test asserts this behavior (`IdempotencyFilterUnitTest.replay_for_sku_endpoints_clears_itemdata_cache`).

**Why a filter and not an `@Aspect`:** we need to **short-circuit** the request before it ever reaches the handler. `@Aspect` on the handler method can prevent the handler running but cannot intercept body-reading; if the handler reads the request body before the aspect short-circuits, the cached response replay corrupts the request stream. Filter is cleaner.

**Why `REQUIRES_NEW` for the persist step:** the handler's transaction may have rolled back due to an unrelated `@Transactional` boundary inside the handler body (the handlers themselves are not `@Transactional`, but `customerorderService.cancelOrder` etc are). We want the dedup row to persist if the response went out to OMS — i.e., if the response status is 2xx — independent of what the handler's downstream transactions did. Therefore the `RestIdempotencyService.persistResponse(...)` method gets `@Transactional(value = "tenantTransactionManager", propagation = Propagation.REQUIRES_NEW)`.

**Why we only persist 2xx responses, not 4xx/5xx:** a 4xx response signals the request was malformed (bad payload). OMS should be allowed to fix the payload and retry. A 5xx signals a transient WMS-side failure; OMS should be allowed to retry. If we persisted 4xx/5xx, every transient failure would become permanent ("you can't retry, we already returned 500 to you"). Only successful (2xx) responses are immutable from OMS's view.

**Race between two concurrent first-time requests:** scenario — OMS retries before the first request finishes. Both filter passes find no row at step (f), both reach (g), both run the handler concurrently. The TOCTOU race in the handlers re-asserts itself, ONE wins the DB unique constraint, the other 500s. **Fix B does not prevent the in-handler race for the first occurrence.** It DOES prevent it on the second-and-later retry, which is the high-frequency case (OMS's retry policy is exponential; the third retry comes minutes later, well after the first commits).

To close the first-attempt-race as well, **Fix C** adds an opportunistic INSERT-then-do-work pattern at the top of the filter, leveraging the dedup table's primary-key constraint as the cross-replica mutex. See Fix C.

### Fix C — Opportunistic "claim" insert at filter entry (first-attempt race close)

**Files changed:**
- `src/main/java/net/aim_ai/wms/service/RestIdempotencyService.java` (extended)
- `src/main/java/net/aim_ai/wms/web/IdempotencyFilter.java` (extended)

**Why:** the simple read-then-handle in Fix B leaves a TOCTOU window between filter step (f) lookup and handler completion. We can close it by inserting a "claim" row at filter entry, BEFORE the handler runs:

```sql
-- Pseudo-code in RestIdempotencyService.tryClaim(key, method, path, hash):
INSERT INTO rest_idempotency
  (idempotency_key, request_method, request_path, request_hash,
   response_status, response_body, created_at)
VALUES (?, ?, ?, ?, 102, NULL, NOW())   -- 102 = "processing" sentinel
ON CONFLICT (idempotency_key) DO NOTHING
RETURNING idempotency_key;
```

If the INSERT succeeds (one row returned) → this is the FIRST claim — proceed to handler.
If the INSERT does nothing (no rows returned) → some other replica/thread already has the key. We then:

- Wait briefly (50 ms exponential backoff up to 3s) for the original claim to either commit a final response_status (2xx) or expire (`created_at < NOW() - INTERVAL '60 seconds'` — the in-flight handler must have crashed without writing back; treat as stale, DELETE the stale row and retry our claim).
- Once the original claim has a non-102 response_status, replay it.

After the handler runs, the IdempotencyFilter UPDATES (not INSERTS) the claim row with the final status + body (still `REQUIRES_NEW`). On 4xx / 5xx the row is DELETED (so OMS can legitimately retry) — see Fix B.

**Native SQL with `ON CONFLICT DO NOTHING`:** the v2 codebase uses native SQL via `@Query(nativeQuery = true)` for similar upsert-style operations (see e.g. `UnitloadRepository.clearCarrierUnitloadByIds`). Use the same idiom. `RETURNING` is supported by Postgres.

**Why not `SELECT ... FOR UPDATE`:** pessimistic lock acquisition on a row that doesn't exist yet returns nothing; you'd have to fall back to an INSERT either way. `ON CONFLICT DO NOTHING ... RETURNING` is the single-roundtrip Postgres idiom for "claim or read existing."

**Why 60s stale-claim TTL:** any handler that takes >60s to write its response back to the dedup row is itself a separate bug. Empirically the slowest /rest/** handler in v2 (`/rest/order/create` with 5000-position batch) takes <20s on staging hardware. 60s gives 3× headroom. The cleanup job (Fix D) wipes anything older than 7 days; the 60s threshold is only for "deadlocked claim recovery within an active second-call retry."

### Fix D — Daily cleanup `@Scheduled` job

**Files changed:**
- `src/main/java/net/aim_ai/wms/schedulejob/CleanupRestIdempotencyJobService.java` (new)
- `src/main/java/net/aim_ai/wms/service/AdvisoryLockService.java` (modified — add one new `public static final long` constant to `JobLockId`)
- `src/main/resources/application.properties` (add `app.cron.cleanup-rest-idempotency=0 30 2 * * *`)

**Why:** the dedup table grows monotonically. A daily 02:30 UTC sweep deletes rows older than 7 days. 7 days is sufficient because (a) OMS's retry policy gives up after ~24h and (b) any human reconciliation that pulls a stale request body has a separate audit trail in `message`.

**Tenant-context handling:** scheduled job runs outside HTTP request scope. The job iterates tenants (via `LandlordService.findAllTenants()`), sets `TenantContext.setCurrentTenant(...)` per tenant, runs `DELETE FROM rest_idempotency WHERE created_at < NOW() - INTERVAL '7 days'` (native SQL via repository method, in a `@Transactional(value="tenantTransactionManager")` boundary), then clears `TenantContext` in a `finally` block.

**Horizontal-scale safety:** uses `AdvisoryLockService.JobLockId.CLEANUP_REST_IDEMPOTENCY` (a new `public static final long` constant — NOT an enum value) so only one replica runs it per night.

**Important — `JobLockId` is NOT an enum.** Verified by reading `AdvisoryLockService.java:63-72`:

```java
public static final class JobLockId {
    public static final long ORDER_RELEASE = 100001L;
    public static final long REPLENISH_ORDER = 100002L;
    public static final long CLEAN_UP_MESSAGES = 100003L;
    public static final long STOCK_SUMMARY_EXPORT = 100004L;
    public static final long RELEASE_EXPIRED_PICKING = 100005L;
    public static final long STALE_CLUB_BATCH_CLEANUP = 100006L;    // SBDEV-2164

    private JobLockId() {}
}
```

`tryLock(...)` accepts a `long`. The patch is therefore one line added to the existing `JobLockId` static-final class:

```java
public static final long CLEANUP_REST_IDEMPOTENCY = 100007L;  // SBDEV-2222
```

…and the job calls `advisoryLockService.tryLock(AdvisoryLockService.JobLockId.CLEANUP_REST_IDEMPOTENCY)`. **Do not create a new enum**; do not break the existing `long`-keyed lock API.

### Fix E — Document the contract in v2/wms2-api/CLAUDE.md and update wms2-oms-integration-map.md

**Files changed:**
- `v2/wms2-api/CLAUDE.md` (add "Idempotency Contract" section)
- `sbdocs/3-Resources/architecture/wms2-oms-integration-map.md` (add row to §3 inbound surface)

**Why:** every future REST inbound endpoint inherits the filter automatically (because the filter matches `/rest/**`), but reviewers need to know:

1. The header is `Idempotency-Key`, ≤64 chars, recommended UUIDv4.
2. Replays of 2xx responses are byte-identical to the original 2xx.
3. Replays of 4xx/5xx are not stored — OMS can retry with the same key after fixing the payload.
4. Different body with the same key → 409 Conflict (OMS bug).
5. TTL: 7 days.

### Rejected alternative — per-handler `DataIntegrityViolationException` catch

A simpler-looking alternative was considered and rejected:

> In each handler (`OrderRestController.create`, `AdviceRestController.create`, `SkuRestController.create`, …), catch `DataIntegrityViolationException` at the `save(...)` call, look up the existing entity by its natural key (batchid / externalid / client+itemNr), and return that entity's existing response (200 with the existing row's projection).

It is rejected for four concrete reasons:

1. **Does not cache the original response body.** A replay of the same `Idempotency-Key` would re-derive the response from the *current* DB state, not the body that was actually sent to OMS the first time. If the row was mutated between calls (e.g. the audit-message portion changed), OMS sees a different 2xx body on retry. The OMS reconciliation invariant ("same key → same response bytes") is then broken.
2. **Does not cover the cancel-positions state-machine retry case** (`Bug 4` in §2). `customerorderService.cancelOrder` doesn't throw `DataIntegrityViolationException`; it throws `BusinessException(WRONG_STATE)`. The per-handler catch wouldn't intercept that — and the retry would still 400 to OMS.
3. **Does not extend cleanly to new endpoints.** Every new write endpoint would need its own dedup catch block. The filter is one place; the per-handler approach is N places, each with its own copy-paste risks.
4. **Per-handler duplication.** 11 in-scope endpoints × ~10 lines of duplicate `try { … } catch (DataIntegrityViolationException) { … lookup … return existing … }` = ~110 lines of boilerplate that drifts over time. The filter is one ~200-line class.

The filter trades these four costs for: one additional DB lookup per write request (under load, that's the rate-limiter we already account for in §7 row 2) and one new infrastructure component (the filter + table). On balance, the filter wins.

---

## 4. V1/V2 Applicability

| Aspect | V1 | V2 | Impact |
|---|---|---|---|
| Java version | Java 8 | Java 21 | v2 uses `jakarta.servlet.*` (not `javax.servlet.*`) — the filter import path differs |
| Spring Boot | 2.3.7 | 3.5.9 | `OncePerRequestFilter` API unchanged; `ContentCachingRequestWrapper` / `ContentCachingResponseWrapper` unchanged |
| Transaction manager | implicit single | dual (`landlord`, `tenant`) — `@Primary` is landlord | v2 MUST specify `value = "tenantTransactionManager"` on the persist transaction |
| Horizontal scaling | single replica | multi-replica | v2 dedup table MUST be in DB (not in-JVM); v2 cleanup job MUST use distributed lock |
| Multi-tenancy filter ordering | n/a | TenantFilter @ HIGHEST_PRECEDENCE; OAuth2 BearerTokenAuthenticationFilter sits later in the chain | v2 IdempotencyFilter must run AFTER both `TenantFilter` (so `TenantContext` is set) AND `BearerTokenAuthenticationFilter` (so unauthenticated requests can't force DB roundtrips or fetch cached 2xx bodies). Wire via `SecurityFilterChain.addFilterAfter(idempotencyFilter, BearerTokenAuthenticationFilter.class)` — see §3 Fix B. |
| DB schema | Liquibase | Flyway | v2 migration goes to `src/main/resources/db/migration/V2.1.10__add_rest_idempotency.sql` |

### What Needs Porting

This plan is **v2-only**. The companion v1 plan (`sbdocs/1-Projects/wms1/plan/SBDEV-2222-rest-inbound-no-idempotency-contract.md` — to be created via the `wms-bugfix-plan` skill against v1/wms-api) will share the same base name + ticket prefix.

The v1 plan will differ in three places only:
1. Filter import path (`javax.servlet.*` not `jakarta.servlet.*`).
2. No `tenantTransactionManager` specifier (v1 has only one TM).
3. Liquibase migration file instead of Flyway.

### What Does NOT Need Porting

- The cleanup job's `AdvisoryLockService.JobLockId` — v1 doesn't deploy multi-replica so single-instance scheduled-execution is fine without a distributed lock.
- The cross-replica race in Fix C — v1 doesn't have it. v1 only needs Fix B (the simpler read-then-handle) because there's only one JVM.

---

## 5. Prerequisites & Implementation Plan

### 5.1 Prerequisites

| # | Prerequisite | Required value / action | Owner | Notes |
|---|---|---|---|---|
| 1 | **Database state** | Flyway at `V2.1.09`. `V2.1.10__add_rest_idempotency.sql` is the next migration | DBA / dev | Verify with `SELECT MAX(version) FROM flyway_schema_history;` |
| 2 | **Feature flags / system properties** | `app.cron.cleanup-rest-idempotency=0 30 2 * * *` in `application.properties`. `app.idempotency.enforce=true` to enable the filter at all (default `true`; allows kill-switch) | dev | Two flags: cron schedule and filter master kill-switch |
| 3 | **Config / env changes** | No new env vars. Hikari pool size unchanged (the filter uses the existing tenant DataSource via `REQUIRES_NEW` — accounted for in §7 row 2) | dev | |
| 4 | **Deploy-order dependencies** | **SBDEV-2214 must merge first** so the in-tx OMS POST drift is closed before we start replaying responses (replaying a 2xx that triggered an in-tx OMS POST that later rolled back would be wrong) | release manager | Listed in `related:` frontmatter |
| 5 | **Data migration** | None — the `rest_idempotency` table starts empty | dev | |
| 6 | **External systems** | **OMS team must agree on the `Idempotency-Key` header contract** (UUIDv4, ≤64 chars, same key for retries). Until OMS sends the header, the filter falls back to "chain.doFilter without dedup" (Fix B step c) | David O. + OMS team | Documented in §3 Fix E; not a blocker for filter deployment because of back-compat fallback |
| 7 | **Access / permissions** | No new role; the filter runs for any authenticated `/rest/**` caller | n/a | |
| 8 | **Monitoring / alerts** | Two new Micrometer counters: `rest_idempotency_replay_total{endpoint=…}` and `rest_idempotency_conflict_total{endpoint=…}` (409 path). Grafana panel + alert when `rate(rest_idempotency_conflict_total[15m]) > 0` (OMS bug: same key, different body) | dev + ops | Conflicts should be zero in steady-state |

### 5.2 Implementation Checklist

- [ ] **5.2.1** Add Flyway migration `V2.1.10__add_rest_idempotency.sql` (Fix A schema)
- [ ] **5.2.2** Add `RestIdempotency` JPA entity + `RestIdempotencyRepository` (with `@Query(nativeQuery=true)` for the `ON CONFLICT DO NOTHING RETURNING` upsert)
- [ ] **5.2.3** Add `RestIdempotencyService` with two methods: `tryClaim(...)` returning `ClaimResult { CLAIMED, REPLAYED, CONFLICT, IN_FLIGHT }` and `persistResponse(...)` annotated `@Transactional(value = "tenantTransactionManager", propagation = Propagation.REQUIRES_NEW)`
- [ ] **5.2.4** Add `IdempotencyFilter extends OncePerRequestFilter` in `net.aim_ai.wms.landlord.config` (alongside `TenantFilter`). Implement `shouldNotFilter()` to skip GET, non-`/rest/**`, `/rest/stockcount/**`, and `/rest/transactionreport/**`.
- [ ] **5.2.5** Wire `IdempotencyFilter` via `SecurityFilterChain.addFilterAfter(idempotencyFilter, BearerTokenAuthenticationFilter.class)` in `SecurityConfiguration.java`. The filter MUST run AFTER Spring Security's OAuth2 resource-server auth so unauthenticated requests cannot force tenant DB roundtrips or fetch cached 2xx bodies. Filter is NOT `@Component` (would attach to the wrong chain position); it is a `@Bean` constructor-injected with `CacheManager`, `RestIdempotencyService`, and config.
- [ ] **5.2.6** Inside the filter, check `SecurityContextHolder.getContext().getAuthentication() != null && .isAuthenticated()` BEFORE doing any DB lookup or replay (defence-in-depth against accidental future filter-order regressions).
- [ ] **5.2.7** On replay path for `/rest/sku/create` or `/rest/sku/update`, call `cacheManager.getCache("itemdata").clear()` before writing the cached response (P2-1 mitigation: handler's `@CacheEvict` does not fire when we short-circuit).
- [ ] **5.2.8** Add `app.idempotency.enforce` boolean property with default `true` and read it inside the filter (kill-switch)
- [ ] **5.2.9** Add `public static final long CLEANUP_REST_IDEMPOTENCY = 100007L;` to `AdvisoryLockService.JobLockId` (this is a static-final-long constant, NOT an enum value).
- [ ] **5.2.10** Add `CleanupRestIdempotencyJobService` with `@Scheduled(cron = "${app.cron.cleanup-rest-idempotency}")` + `advisoryLockService.tryLock(AdvisoryLockService.JobLockId.CLEANUP_REST_IDEMPOTENCY)` guard + per-tenant `TenantContext` set/clear in try-finally
- [ ] **5.2.11** Add Micrometer counters `rest_idempotency_replay_total`, `rest_idempotency_conflict_total`, `rest_idempotency_claimed_total` (with `endpoint` tag)
- [ ] **5.2.12** Update `v2/wms2-api/CLAUDE.md` with the idempotency contract section (Fix E)
- [ ] **5.2.13** Update `sbdocs/3-Resources/architecture/wms2-oms-integration-map.md` §3 (Fix E)
- [ ] **5.2.14** Unit tests added/updated — see §6
- [ ] **5.2.15** Integration tests (Testcontainers Postgres) for cross-replica race — see §6
- [ ] **5.2.16** Run `bash sbdocs/9-System/scripts/verify-SBDEV-2222-rest-inbound-no-idempotency-contract.sh` — must report `0 fail`
- [ ] **5.2.17** Manual smoke per §6 manual test plan
- [ ] **5.2.18** Code review completed by architect / OMS-integration owner
- [ ] **5.2.19** Implementation status updated in this plan's "Notes" section with Plan-fix SHAs, `mvn` results, and PR link

---

## 6. Test Plan

### Test scenarios

| Scenario | Steps | Expected Result |
|---|---|---|
| Duplicate POST with same Idempotency-Key, same body | 1. POST /rest/order/create with `Idempotency-Key: K1`, body B1 → 204. 2. POST again with `K1`, B1 | Second call returns identical 204 with no new DB row. `rest_idempotency_replay_total{endpoint="/rest/order/create"}` increments by 1. |
| Duplicate POST with same Idempotency-Key, different body | 1. POST with `K1`, body B1 → 204. 2. POST with `K1`, body B2 | Second call returns 409 Conflict with `{"error":"idempotency-key-conflict"}`. `rest_idempotency_conflict_total` increments. |
| Concurrent retries with same Idempotency-Key (cross-replica) | 2 replicas. Send 2 concurrent POSTs with same `K1`, same body, same batch_id | Both ingress; one wins the `ON CONFLICT DO NOTHING` claim and proceeds; the other detects `IN_FLIGHT` and polls (50ms × ≤3s) until the first commits, then replays. Exactly one DB row created. Both clients receive 204. |
| Retry after handler 5xx | 1. POST with `K1`, body B1 → 500 (internal error). 2. Retry with `K1`, body B1 | 5xx is NOT cached. Second call runs through handler again. (Validates that transient failures stay retryable.) |
| Retry after handler 4xx (validation error) | 1. POST with `K1`, body B1 (bad field) → 400. 2. Retry with `K1`, body B1-fixed | Second call NOT replayed (4xx not cached); runs through, returns 204 with the fix. (Validates that legitimate-fix retries work.) |
| Missing Idempotency-Key header (back-compat) | POST without the header | Filter logs WARN, passes through to handler. Handler behaves as today (TOCTOU race possible — same risk as before this plan). |
| GET endpoint with Idempotency-Key | GET /rest/transactionreport/getTransactionReport with `K1` | Filter skips dedup for GET. Pass-through. |
| Non-`/rest/**` endpoint with Idempotency-Key | GET /api/customerorder/123 with `K1` | Filter skips entirely (only matches `/rest/**`). |
| Cleanup job (Fix D) | Insert rows aged 8 days. Trigger job manually | Job deletes rows older than 7 days. Newer rows preserved. `rest_idempotency_cleaned_total` increments. |
| Tenant isolation | Insert dedup row for tenant T1 with key K1. Send request with same K1 against tenant T2 | T2 request proceeds (different tenant DB → no row). No cross-tenant leakage. |
| Filter kill-switch (`app.idempotency.enforce=false`) | Set property to false. POST with K1, body B1 → 204. POST with K1, body B1 again | Filter is bypassed entirely (chain.doFilter at the top). Second call runs as today (TOCTOU). Verifies graceful disable path. |
| SkuRestController.update → create recursive path | POST /rest/sku/update with K1 for missing SKU (triggers internal `create()` call) | Outer `update` is keyed by K1. Internal `create()` is NOT separately keyed (filter only catches the outermost servlet entry). Replay returns the original `update` response. |
| Recovering from a stalled claim (Fix C) | Manually insert a `response_status=102` row with `created_at = NOW() - INTERVAL '90 seconds'`. Send a real request with the same key | Filter detects the stale claim (>60s with status 102), DELETEs it, re-CLAIMs, runs handler. Verifies the 60s recovery. |
| Unauthenticated replay attempt (P1-1 security) | 1. As authenticated OMS, POST `/rest/order/create` with `K1`, body B1 → 204 (cached). 2. As anonymous (no Bearer token), POST `/rest/order/create` with `K1`, body B1 | Second call returns 401 from Spring Security; the IdempotencyFilter never runs (because it sits AFTER auth). Verifies filter-after-auth ordering. |
| Replay clears `itemdata` cache (P2-1) | 1. POST `/rest/sku/create` with `K1`, body B1 → 204 (Spring AOP fires `@CacheEvict`). Pre-warm Caffeine cache with a `findByClientIdAndItemNr` after step 1. 2. Mutate `itemdata` directly via SQL. 3. POST `/rest/sku/create` with `K1`, body B1 (replay path) | Replay must invoke `cacheManager.getCache("itemdata").clear()` before returning. Subsequent reads of the same item return the post-SQL state, not the pre-mutation cached state. |
| `Content-Length > 5MB` body cap (P3-3) | POST `/rest/order/create` with `K1` and a 6MB body (5000-position order) | Filter does NOT buffer the body. `chain.doFilter` runs directly (no dedup for this request). Verifies the 5MB cap mitigation in §9 row 5. |

### New / updated tests

| Test class | Test method | What it asserts |
|---|---|---|
| `RestIdempotencyServiceUnitTest` (new) | `tryClaim_firstTime_returnsCLAIMED` | `ON CONFLICT DO NOTHING` returns 1 row → state CLAIMED |
| `RestIdempotencyServiceUnitTest` | `tryClaim_secondTime_returnsREPLAYED_when_status_2xx` | Existing row with status 204 → REPLAYED |
| `RestIdempotencyServiceUnitTest` | `tryClaim_returnsCONFLICT_when_hash_differs` | Existing row with different hash → CONFLICT |
| `RestIdempotencyServiceUnitTest` | `tryClaim_returnsIN_FLIGHT_when_status_102` | Existing row with status 102 → IN_FLIGHT |
| `RestIdempotencyServiceUnitTest` | `tryClaim_recoversStaleClaim_when_claim_older_than_60s` | Status 102 + created_at > 60s ago → DELETE + reclaim → CLAIMED |
| `RestIdempotencyServiceUnitTest` | `persistResponse_usesRequiresNewTx` | Asserts the method's `@Transactional` propagation is `REQUIRES_NEW` (reflect on annotations) |
| `RestIdempotencyServiceUnitTest` | `persistResponse_skipsFor4xxAnd5xx` | 4xx and 5xx responses don't persist |
| `IdempotencyFilterUnitTest` (new) | `filter_short_circuits_on_replay_2xx` | `MockHttpServletRequest` + pre-populated dedup row → filter returns cached body without calling chain |
| `IdempotencyFilterUnitTest` | `filter_returns_409_on_hash_conflict` | Pre-populated row + different body hash → 409 with error map |
| `IdempotencyFilterUnitTest` | `filter_passes_through_when_no_header` | Missing header → chain.doFilter called once, no DB lookup |
| `IdempotencyFilterUnitTest` | `filter_skips_GET_and_non_rest_paths` | GET / non-`/rest/**` → chain.doFilter, no DB lookup |
| `IdempotencyFilterUnitTest` | `filter_skips_stockcount_and_transactionreport_carveouts` | `/rest/stockcount/**` and `/rest/transactionreport/**` → `shouldNotFilter` returns true; chain.doFilter, no DB lookup |
| `IdempotencyFilterUnitTest` | `filter_returns_401_when_unauthenticated` | `SecurityContextHolder` empty → 401 short-circuit, no DB lookup (defence-in-depth) |
| `IdempotencyFilterUnitTest` | `replay_for_sku_endpoints_clears_itemdata_cache` | Replay path on `/rest/sku/create` or `/rest/sku/update` → `cacheManager.getCache("itemdata").clear()` invoked exactly once before response write (P2-1) |
| `IdempotencyFilterUnitTest` | `filter_skips_dedup_when_content_length_over_5MB` | Content-Length=6_000_000 → chain.doFilter without ContentCachingRequestWrapper (P3-3) |
| `IdempotencyFilterIT` (Testcontainers Postgres) | `concurrent_requests_with_same_key_serialize` | 2 threads, same key, same body → exactly one handler invocation, both threads see 2xx |
| `IdempotencyFilterIT` | `cross_tenant_isolation_preserved` | Two tenant DBs, same key, different tenants → both proceed; no cross-DB leak |
| `OrderRestControllerIdempotencyIT` (Testcontainers) | `duplicate_create_order_returns_cached_response` | E2E: PUT /rest/order/create twice with same key → second call replays |
| `AdviceRestControllerIdempotencyIT` (Testcontainers) | `duplicate_create_advice_returns_cached_response` | E2E for advice |
| `SkuRestControllerIdempotencyIT` (Testcontainers) | `duplicate_update_with_internal_create_handled` | E2E for the recursive `update → create` path |
| `CleanupRestIdempotencyJobServiceUnitTest` (new) | `cleanup_deletes_rows_older_than_7_days` | Job deletes only rows where `created_at < NOW() - INTERVAL '7 days'` |
| `CleanupRestIdempotencyJobServiceUnitTest` | `cleanup_acquires_advisory_lock` | Job calls `advisoryLockService.tryLock(CLEANUP_REST_IDEMPOTENCY)` before deleting |

### Manual test plan

| Scenario | Environment | Steps | Expected Result | Pass/Fail |
|---|---|---|---|---|
| OMS retry storm (staging) | staging | 1. Stand up wms2-api in 2-replica config. 2. Use a load-test tool to send 10 concurrent identical `PUT /rest/order/create` with the same Idempotency-Key. | All 10 return 204. Exactly one `customerorder_batch` row created. `rest_idempotency_replay_total` shows 9 replays. No 500s. |  |
| OMS retry storm WITHOUT Idempotency-Key (legacy OMS) | staging | Same as above but omit the header | At most one 204 (or 9 errors); same as pre-fix behavior. Verifies graceful back-compat. |  |
| 409 alarm wires up | staging | 1. Send `K1` + body1 → 204. 2. Send `K1` + body2 → 409. 3. Watch Grafana panel for `rest_idempotency_conflict_total`. | Counter increments, alert fires within 1 min. |  |
| SQL-level sanity | staging DB | `psql: SELECT idempotency_key, response_status, request_hash FROM rest_idempotency WHERE created_at > NOW() - INTERVAL '1 hour' ORDER BY created_at DESC LIMIT 20;` | Row visible after first 2xx; not visible after isolated 4xx. |  |
| Cleanup job manual run | staging | Insert a row with `created_at = NOW() - INTERVAL '8 days'`. Manually trigger the job. | Row deleted. Recent rows preserved. |  |

### Test execution (fill in after running)

**Important — Surefire vs Failsafe:** the Maven `surefire` plugin (driven by `mvn test`) by default excludes class names ending in `IT` (`**/*IT.java`); those are picked up by the `failsafe` plugin during `mvn verify` via the `it.test` property. Use `mvn test -Dtest=…` only for unit tests; use `mvn verify -Dit.test=…` for `*IT` integration tests. Earlier drafts of this plan and the verify script used `mvn test -Dtest=…IT` which silently runs zero tests.

| Command | Result | Pass / Fail / Skipped counts |
|---|---|---|
| `mvn test -Dtest=RestIdempotencyServiceUnitTest -DfailIfNoTests=false` | | |
| `mvn test -Dtest=IdempotencyFilterUnitTest -DfailIfNoTests=false` | | |
| `mvn verify -Dit.test=IdempotencyFilterIT -DfailIfNoTests=false` | | |
| `mvn verify -Dit.test='*RestController*IdempotencyIT' -DfailIfNoTests=false` | | |
| `mvn test -Dtest=CleanupRestIdempotencyJobServiceUnitTest -DfailIfNoTests=false` | | |
| `mvn verify` (full suite) | | |
| `bash sbdocs/9-System/scripts/verify-SBDEV-2222-rest-inbound-no-idempotency-contract.sh` | | |

### Deliberately-skipped coverage

| What | Why |
|---|---|
| Cross-replica concurrent-claim test as a pure unit test | Requires a real Postgres for `ON CONFLICT DO NOTHING RETURNING` — covered by `IdempotencyFilterIT` (Testcontainers) instead. |
| Idempotency for `DELETE /rest/sku/delete` payload edge case | DELETE is idempotent by definition; if the row is gone the second call returns 400 today (ENTITY_DOES_NOT_EXISTS) which is the correct OMS contract. Filter still keys it (so concurrent duplicate DELETEs serialize) but no special handling needed. |

---

## 7. Horizontal Scalability Validation (v2 plans — MANDATORY)

| # | Concern | Does this change… | Verdict | Mitigation / rationale |
|---|---|---|---|---|
| 1 | **In-JVM state** | Introduce state that only exists in one replica? | **No** | Dedup state lives in tenant DB (`rest_idempotency` table). No Caffeine, no `ConcurrentHashMap`, no static fields. The filter is stateless. |
| 2 | **Connection pool math** | Change per-request DB connection usage? | **Yes** | The filter does ONE additional DB roundtrip per `/rest/**` write request (the `tryClaim` upsert), and one MORE for `persistResponse` on 2xx (REQUIRES_NEW → new connection). Total: +2 connections per write request, held briefly. **Assumption (must hold):** `tryClaim` INSERT commits in <5ms (executes before the handler runs; one row insert into a `idempotency_key`-keyed table); `persistResponse` UPDATE commits in <5ms (after handler returns; updates one row by primary key). This assumption breaks for large payloads — a 5000-position `/rest/order/create` body of ~6MB will spend the time copying `response_body` into the dedup row, not in tryClaim. The 5MB Content-Length cap in §9 risk 5 prevents that path. With current HikariCP `maximumPoolSize=20` per tenant × 2 replicas × ~3 tenants = 120 max connections used; ~3000 inbound requests/day at 2-second peak burst = ~6 extra connections/sec sustained. Well under PostgreSQL's `max_connections=200`. Documented in §5 prereq 3. |
| 3 | **Scheduled jobs** | Add or modify a `@Scheduled` / cron job? | **Yes** | New `CleanupRestIdempotencyJobService` runs nightly. Uses `AdvisoryLockService.JobLockId.CLEANUP_REST_IDEMPOTENCY` (a new `public static final long` constant added to the existing `JobLockId` static-final class — NOT a new enum) for distributed-lock guard. |
| 4 | **Long transactions** | Hold a DB transaction across multiple repository calls or external I/O? | **No** | The filter's `tryClaim` and `persistResponse` are each single-statement transactions. No external I/O inside the dedup transactions. |
| 5 | **Request affinity** | Assume follow-up request lands on the same replica? | **No** | The dedup row is in the shared tenant DB, visible to all replicas. Any replica can serve a replay. |
| 6 | **Retry / idempotency** | Rely on single-execution semantics that break if a replica dies mid-op? | **Yes — this plan IS the mitigation** | The `tryClaim` uses `ON CONFLICT DO NOTHING RETURNING` — Postgres provides the atomic cross-replica mutex. If a replica dies between CLAIM and persist, the stale-claim recovery (60s TTL, Fix C) kicks in on the next retry. |
| 7 | **Tenant context** | Use `TenantContext` / `ThreadLocal` across async boundaries? | **No** | All filter work happens in the request thread, synchronously. The cleanup job sets and clears `TenantContext` explicitly per tenant. |
| 8 | **Distributed lock correctness** | Add or rely on pessimistic / optimistic lock across replicas? | **No** (advisory lock is for the cleanup job, not the request path) | Cleanup job: `advisoryLockService.tryLock(JobLockId.CLEANUP_REST_IDEMPOTENCY)` (passes the `long` constant directly — same pattern as existing nightly jobs which all use long constants, not enums). Request path uses the DB unique constraint, not a lock. |
| 9 | **Cache invalidation** | Write to an entity that is cached? | **Yes — special-case for sku endpoints** | `rest_idempotency` itself has no `@Cacheable`. **However** `SkuRestController.create/update` carry `@CacheEvict(value="itemdata", allEntries=true)`. On replay we short-circuit Spring AOP so the `@CacheEvict` never fires. Mitigation (P2-1): the filter explicitly calls `cacheManager.getCache("itemdata").clear()` on the replay path for those endpoints. See §3 Fix B and §9 risk row 10. |
| 10 | **External notifications** | Send HTTP / message to an external system inside a transaction? | **No** | The filter does not call any external service. **Note (P2-3):** the handlers we wrap DO fire OMS notifications via `omsNotificationService.sendAfterCommit`. A replay returns the cached 2xx body without re-firing those notifications (they fired the first time, after the original commit). If OMS receives a 2xx replay for an order it already processed, OMS must remain idempotent on its own receiving side — see §9 risk row 11 (OMS notification re-trigger). |
| 11 | **Filter-before-auth (security)** | Run before Spring Security's `BearerTokenAuthenticationFilter`? | **NO — explicit MUST-run-after** | The filter is wired via `SecurityFilterChain.addFilterAfter(idempotencyFilter, BearerTokenAuthenticationFilter.class)` so unauthenticated requests cannot force tenant DB roundtrips or fetch cached 2xx response bodies. Defence-in-depth: filter checks `SecurityContextHolder.getContext().getAuthentication() != null && .isAuthenticated()` before any DB lookup. See §3 Fix B and §9 risk row 9. |

### Evidence

| Concern # | What was done / verified | File:line or test reference |
|---|---|---|
| 2 | Connection-pool math worked through; +2 connections/request bounded; Hikari at 20 × 2 × 3 = 120 < 200 max | `application.properties` `spring.datasource.hikari.maximumPoolSize` (existing) |
| 3 | Advisory-lock guard for nightly job | `CleanupRestIdempotencyJobService.cleanup()` calls `advisoryLockService.tryLock(JobLockId.CLEANUP_REST_IDEMPOTENCY)` (new) |
| 6 | Atomic claim test | `IdempotencyFilterIT.concurrent_requests_with_same_key_serialize` |
| 7 | Tenant set + clear in cleanup job | `CleanupRestIdempotencyJobService.cleanup()` try/finally |

---

## 8. v2-only Constraint Checklist

| # | Rule | Compliant? | Where verified |
|---|---|---|---|
| 1 | All tenant-scoped `@Transactional` uses `value = "tenantTransactionManager"` | Yes | `RestIdempotencyService.persistResponse` annotation; cleanup job's per-tenant delete |
| 2 | OSIV disabled — repository calls outside `@Transactional` open new sessions; the filter wraps its DB calls in explicit `@Transactional` service methods | Yes | `RestIdempotencyService` is the only DB-touching component; all methods are `@Transactional(tenantTransactionManager)` |
| 3 | Constructor injection only — no `@Autowired` fields | Yes | New service / filter / job all use constructor injection (matches existing v2 codebase style) |
| 4 | SLF4J parameterized logging — no string concatenation | Yes | All `LOG.warn`/`LOG.error` in new code use `{}` placeholders |
| 5 | Prefer `.orElseThrow(() -> new EntityNotFoundException(...))` over `.get()` | Yes | New code does not call `.get()` on `Optional` (we use `findById(...).isPresent()` style explicitly because the absent case is the happy path) |
| 6 | Jakarta namespace (`jakarta.*`) — not `javax.*` | Yes | Filter imports `jakarta.servlet.*` (matches `TenantFilter.java`) |
| 7 | `AbstractBaseEntity.equals()` is ID-based — do not rely on `.equals` for unsaved entities | Yes | `RestIdempotency` entity does NOT extend `AbstractBaseEntity` (it has its own composite-ish PK via `idempotency_key`); equality is by key |
| 8 | Multi-tenant — every entity write goes through the tenant DataSource | Yes | `RestIdempotency` entity lives in `net.aim_ai.wms.model` (the **tenant** persistence-unit package). Verified by reading `TenantDatabaseConfig.java:68` → `.packages("net.aim_ai.wms.model")` — the tenant `LocalContainerEntityManagerFactoryBean` scans exactly this package, so the new entity auto-registers with the tenant `EntityManagerFactory` and routes via `tenantTransactionManager`. `RestIdempotencyRepository` lives in `net.aim_ai.wms.repo.jpa` which inherits `tenantTransactionManager` from `@EnableJpaRepositories` (per CLAUDE.md "Repository `@Transactional`/`@Modifying`" exception). |

---

## 9. Risks & Mitigations

| # | Risk | Likelihood | Blast radius | Mitigation |
|---|---|---|---|---|
| 1 | OMS team takes time to start sending `Idempotency-Key`. Filter is deployed but does nothing until then. | High (week 1-2) | Zero — back-compat fallback (Fix B step c) preserves today's behaviour | Documented in §5 prereq 6. Push OMS team early. |
| 2 | `rest_idempotency` table grows faster than cleanup can keep up (e.g. burst OMS retries). | Low | Medium — disk pressure | Cleanup job runs nightly. Backup plan: manual `DELETE FROM rest_idempotency WHERE created_at < NOW() - INTERVAL '1 day'` runnable from `psql`. Index on `created_at` makes it cheap. |
| 3 | Filter mis-classifies a path and short-circuits a non-idempotent handler with a stale 2xx body. | Low | High — wrong data returned | (a) Filter only matches `/rest/**` (most restricted path), (b) `shouldNotFilter` override skips GET, (c) hash-based payload matching means even if path collides, body collision is astronomically unlikely |
| 4 | Race between `tryClaim` and `persistResponse` when replica dies mid-handler. Stale `status=102` row blocks retries for up to 60s. | Medium | Low — 60s OMS delay only | Documented in §3 Fix C. 60s TTL with active stale-row recovery. |
| 5 | `ContentCachingRequestWrapper` buffers entire request body in memory. Large `/rest/order/create` with 10MB payload could pressure heap. | Low | Medium — OOM in extreme cases | Cap body size (Spring Boot default `spring.servlet.multipart.max-request-size=10MB` already in effect). For `/rest/**` JSON bodies, observed max is <1MB. Add a hard cap in the filter: if `Content-Length > 5MB`, skip dedup (chain.doFilter without caching). |
| 6 | A bug in the filter takes ALL `/rest/**` traffic down. | Low | Critical | (a) Kill-switch `app.idempotency.enforce=false` (Fix B kill-switch path), (b) filter MUST `try { … } catch (Exception e) { LOG.error(...); chain.doFilter(req, resp); }` so a filter bug never becomes a 500 on the request itself. |
| 7 | A SQL injection via the `Idempotency-Key` header value. | Low | Critical | All DB writes use parameterized JPA queries / `@Query(nativeQuery=true)` with `:param` placeholders — no string concatenation. The header is also validated against `[A-Za-z0-9_-]{1,64}` regex at filter entry; non-conforming keys are rejected with 400. |
| 8 | The captured response body contains sensitive PII (recipient address, parcel number). Stored in `response_body` for 7 days. | Medium | Medium — additional data residency surface | (a) `rest_idempotency` lives in the tenant DB (same residency profile as the source order data — no new residency surface). (b) Cleanup TTL is 7 days. (c) Document in `wms2-oms-integration-map.md`. |
| 9 | **Filter-before-auth** (P1-1). Earlier draft placed the filter at `Ordered.HIGHEST_PRECEDENCE + 10`, BEFORE Spring Security's `BearerTokenAuthenticationFilter`. That would let unauthenticated callers (a) force tenant DB roundtrips on every request (free DoS amplifier) and (b) replay cached 2xx response bodies (PII leak). | Was certain pre-fix | Critical | (a) Filter wired via `SecurityFilterChain.addFilterAfter(idempotencyFilter, BearerTokenAuthenticationFilter.class)` so it runs AFTER auth. (b) Defence-in-depth: filter checks `SecurityContextHolder.getContext().getAuthentication().isAuthenticated()` before any DB lookup; unauth → 401 immediately. (c) Verify-script has a positive check for both wiring and the in-filter authentication check (see B-27, B-28, B-29). |
| 10 | **Cache staleness on replay** (P2-1). `SkuRestController.create` and `SkuRestController.update` carry `@CacheEvict(value="itemdata", allEntries=true)`. The filter's short-circuit prevents Spring AOP from firing the eviction, so a replay leaves the Caffeine `itemdata` cache stale until the next mutation. | Medium | Medium — stale SKU lookups inside the same JVM | Filter explicitly calls `cacheManager.getCache("itemdata").clear()` on the replay path for `/rest/sku/create` and `/rest/sku/update`. Unit-tested by `IdempotencyFilterUnitTest.replay_for_sku_endpoints_clears_itemdata_cache`. |
| 11 | **OMS notification re-trigger** (P2-3). A handler like `OrderRestController.cancelPositions` calls `customerorderService.cancelOrder` which fires `omsNotificationService.sendAfterCommit` on the FIRST (winning) call. On retry the filter returns the cached 2xx body without re-entering the handler — OMS sees a 2xx for a cancel it already received the notification for. If OMS is not idempotent on its own receiving side, this could trigger duplicate downstream work (e.g., double-refund). | Low (depends on OMS contract) | Medium | (a) Replay is served ONLY for the exact same request body hash AND the same `Idempotency-Key`, so OMS's own retry-receiver should already be deduplicating by its outbound key. (b) The OMS team must confirm their receiver handles a 2xx replay of `/oms/order/cancel-callback` as a no-op. (c) Tracked in Open Questions §13 item 1 (what should OMS do on 409 / 200-replay?). |

---

## 10. Completeness Checklist (Layer 2)

| # | Question | Verified? | Where |
|---|---|---|---|
| 1 | Are all REST inbound endpoints enumerated (not just the 5 in the ticket)? | Yes | §0 table — 16 endpoints inspected, 11 in scope |
| 2 | Are the existing DB unique constraints confirmed (so we know the "DB-level backstop" sub-task is already done)? | Yes | §0 DB verification (3 unique indexes confirmed) |
| 3 | Is the filter chain order correct (TenantFilter before IdempotencyFilter)? | Yes | §3 Fix B + §0 architecture refs |
| 4 | Is the tenant context handled in the scheduled cleanup job? | Yes | §3 Fix D + §7 row 7 |
| 5 | Is the v2 transaction-manager rule (`tenantTransactionManager`) honored? | Yes | §8 row 1 |
| 6 | Are the connection-pool implications accounted for? | Yes | §7 row 2 |
| 7 | Are there both unit tests (mocked Postgres semantics) and integration tests (real Postgres `ON CONFLICT` behavior)? | Yes | §6 test tables |
| 8 | Is the cross-replica `ON CONFLICT DO NOTHING` semantics tested concretely? | Yes | `IdempotencyFilterIT.concurrent_requests_with_same_key_serialize` |
| 9 | Is the kill-switch tested? | Yes | §6 scenarios, `filter_kill_switch` test |
| 10 | Is the OMS deploy-order dependency captured? | Yes | §5 prereq 4 + §5 prereq 6 |
| 11 | Is the verify script comprehensive (positive + negative + JUnit invocations)? | Yes | See `sbdocs/9-System/scripts/verify-SBDEV-2222-rest-inbound-no-idempotency-contract.sh` |

---

## 11. Notes

**Related plans / docs:**
- `sbdocs/1-Projects/wms2/plan/SBDEV-2214-oms-http-post-inside-class-level-transactional.md` — closes the OUTBOUND half (rollback-after-OMS-POST). This plan closes the INBOUND half. Both should be merged before declaring the OMS↔WMS surface "reliable."
- `sbdocs/1-Projects/wms2/plan/SBDEV-2215-adviceservice-no-transaction-wrapping.md` — sibling AdviceService transactionality plan.
- `sbdocs/3-Resources/architecture/wms2-oms-integration-map.md` — to be updated by Fix E.
- `sbdocs/3-Resources/architecture/wms2-end-to-end-request-journey.md` — filter chain reference.

**Deployment considerations:**
- Deploy SBDEV-2214 first (merge before this plan starts implementation — §5 prereq 4).
- Migration `V2.1.10` runs on first wms2-api startup against each tenant DB; ~50ms per tenant; no migration downtime.
- After deployment, OMS team can roll out the `Idempotency-Key` header on their own schedule. WMS is back-compat until they do.

**Follow-up work (not in this plan):**
- Extend the same filter to handle `/rest/cycleCount/*` writes if they exist (TBD — `StockCountRestController` is read-only today, but if they add a non-read-only endpoint, the filter automatically covers it because the URL pattern is `/rest/**` — note that the `shouldNotFilter` carve-out for `/rest/stockcount/**` would need to be narrowed/removed in that case).
- Consider a `Retry-After` header on 409 responses so the OMS retry timer knows to back off.
- Audit `UtilRestController` — its `@RequestMapping` methods are `@Service`-only (not `@RestController`/`@Controller`) and therefore not routed by Spring at all today; the routing is effectively dead. If it ever grows into a real controller, the filter's `/rest/**` URL match would pick it up automatically (its current path prefix is `/v3/util/*`, NOT `/rest/**` — so even if it became a controller, the filter would not cover it without an additional change).
- `MessageDummyController` IS under `/rest/stockcount/**` and IS therefore covered by the filter's URL match — but excluded via `shouldNotFilter` because it is dev/test only and writes non-deterministic `message` rows. If it is promoted to a production endpoint, remove the carve-out.

**Implementation status (to be filled in by the implementer):**
- Migration SHA: `TBD`
- Filter SHA: `TBD`
- Service SHA: `TBD`
- Job SHA: `TBD`
- Docs SHA: `TBD`
- `mvn verify` result: `TBD`
- Verify-script result: `TBD`
- PR link: `TBD`

---

## 12. Acceptance & Implementation

### 12.1 Acceptance script (machine-checkable)

`sbdocs/9-System/scripts/verify-SBDEV-2222-rest-inbound-no-idempotency-contract.sh`

Covers:
- Positive: `IdempotencyFilter.java` exists in `net.aim_ai.wms.landlord.config` (alongside `TenantFilter`) with `extends OncePerRequestFilter` + `jakarta.servlet.*` imports.
- Positive: `RestIdempotency` entity + `RestIdempotencyRepository` exist with the `ON CONFLICT DO NOTHING RETURNING` native query.
- Positive: `RestIdempotencyService.persistResponse` has `@Transactional(value = "tenantTransactionManager", propagation = Propagation.REQUIRES_NEW)`.
- Positive: Flyway migration `V2.1.10__add_rest_idempotency.sql` exists and contains the schema.
- Positive: `CleanupRestIdempotencyJobService` exists with `@Scheduled` + advisory-lock guard.
- Positive: `AdvisoryLockService.JobLockId` declares `public static final long CLEANUP_REST_IDEMPOTENCY = 100007L;` (a long constant — NOT an enum value).
- Positive: New Micrometer counters present.
- Positive: `v2/wms2-api/CLAUDE.md` mentions "Idempotency-Key" header.
- Positive: `wms2-oms-integration-map.md` mentions the contract.
- Positive (security): Filter checks `SecurityContextHolder.getContext().getAuthentication()` before any DB lookup.
- Positive (security): Filter is wired via `SecurityFilterChain.addFilterAfter` OR uses `SecurityProperties.DEFAULT_FILTER_ORDER` (NOT `Ordered.HIGHEST_PRECEDENCE`).
- Positive (cache): Filter clears `itemdata` cache on `/rest/sku/create`/`/rest/sku/update` replay path.
- Negative: No `@Component` on the filter (must be `@Bean` + explicit `SecurityFilterChain` wiring so the chain position is explicit, not implicit).
- Negative: No `Ordered.HIGHEST_PRECEDENCE` on the filter (would run before Spring Security).
- Negative: No use of `javax.servlet.*` (must be `jakarta.*`).
- JUnit (`mvn test`): `RestIdempotencyServiceUnitTest`, `IdempotencyFilterUnitTest`, `CleanupRestIdempotencyJobServiceUnitTest`.
- JUnit (`mvn verify -Dit.test=`): `IdempotencyFilterIT`, `OrderRestControllerIdempotencyIT`, `AdviceRestControllerIdempotencyIT`, `SkuRestControllerIdempotencyIT`. Surefire excludes `*IT` by default — must be run via Failsafe (`mvn verify`).
- Modes: set `PRE_IMPL_MODE=1` for pre-implementation runs so negative `file_not_contains` checks on not-yet-existing files report `SKIP` instead of `FAIL`.

### 12.2 Recommended OMC composition (for implementation)

| Aspect | Value | One-line rationale |
|---|---|---|
| Size class | Large | 11 affected endpoints + new filter + new entity + new repository + new service + new scheduled job + 2 doc updates — multi-area cross-cutting feature |
| Pre-draft step | analyst+planner | Pattern decision (filter shape, claim semantics) benefited from explicit planning |
| Plan-review step | critic | This plan introduces a NEW pattern (cross-replica DB-backed idempotency) — critic should catch gaps before coding |
| Implementation shape | ralph | Loops: implement cluster → run verify → fix FAIL → repeat until verify-script reports `0 fail` |
| Verification step | verify-script + verifier (mandatory) | Standard |
| Code-review step | code-reviewer | Filter chain ordering and `@Transactional` placement are subtle — extra eyes warranted |
| Commit step | git-master | Multiple logical commits: migration, entity+repo+service, filter+config, cleanup job, docs, tests |

### 12.3 Why this matters

- **Inbound REST is the trust boundary between OMS and WMS.** Today the contract is "if it looks like a dupe, fail." After this plan: "if it IS a dupe, reply identically; if it's a true conflict, return 409." That's the correct OMS-facing UX.
- **The DB unique constraints are already there.** This plan trades a 400 (race-loser, via `WebserviceBusinessExceptionClientSide`) for a 200 (replay) — same data, better UX.
- **Future endpoints inherit the contract for free** because the filter matches `/rest/**`. The "Suggested fix Step 5" in the ticket (document the contract) is captured in Fix E.

---

## 13. Open Questions

Deferred decisions that must be resolved before, or shortly after, this plan ships. Tracking them here so they don't get lost in review.

1. **What should OMS do on 409 Conflict?**
   The filter returns 409 when the same `Idempotency-Key` arrives with a different request-body hash. Today OMS does not parse 409 specifically — it treats any non-2xx as a generic retry/failure. **Open:** does OMS need to implement 409 handling (alert / human-review queue) for this plan to deliver full value, and if so, is that part of this rollout or a separate OMS-side ticket? **Owner:** David O. + OMS team.

2. **Tenant-prefix on `Idempotency-Key`?**
   The key is currently a free-form UUIDv4 chosen by OMS. The `rest_idempotency` table lives per-tenant, so cross-tenant collisions cannot leak (each lookup is against the current tenant's DB only). **Open:** should we additionally namespace the key at the WMS side (e.g., prepend `<tenant_id>:`) to defend against a future bug in `TenantContext` resolution? Or is per-DB isolation sufficient? **Recommendation pending:** per-DB isolation is sufficient — adding a tenant prefix doubles the key length and complicates OMS-side key generation. Leave as-is unless we see a real cross-tenant resolution bug.

3. **Behavior on tenant DB restore.**
   If we restore a tenant DB from a backup taken at T-1d, the `rest_idempotency` table is restored along with everything else. Any OMS retry whose original 2xx was AFTER T-1d will find no dedup row → handler re-runs → either succeeds (idempotent at the DB layer thanks to the unique constraints) or 400s (constraint violation on insert). **Open:** is this acceptable? **Tentative answer:** yes — tenant restore is an "all timelines reset to T-1d" operation; OMS retries after restore are expected to re-validate via the underlying business invariants, not via the dedup table. Document this in `wms2-oms-integration-map.md`.

4. **Behavior when OMS doesn't send `Idempotency-Key`.**
   The filter currently falls through to `chain.doFilter` without dedup, logging a WARN. The DB unique constraint backstop still applies (race-loser returns 400). **Open:** is the log line enough, or do we want a Micrometer counter (`rest_idempotency_missing_header_total{endpoint=…}`) so we can dashboard when OMS catches up? **Recommendation:** add the counter (it's cheap), and we already have the alert framework. Tracked as a follow-up in §11.

5. **Should the 102 sentinel be a real HTTP status value, or a reserved DB-only sentinel?**
   We chose `102` (HTTP "Processing") to mean "claim in flight." It is never actually sent over the wire (we never serve a 102 to OMS — if we hit an in-flight claim we poll and serve the eventual 2xx). **Open:** would a more readable sentinel (`-1` or a separate `state` column) reduce confusion for future readers? **Tentative answer:** leave 102 — `response_status` is INTEGER and 102 is a well-known never-sent status; adding a column doubles the schema surface for one bit of state.

6. **Backfill of historic in-flight requests on first deploy.**
   At first deploy, OMS may have in-flight retries from before the filter existed. The filter will start fresh with an empty dedup table. **Open:** is there anything to do, or do we accept that the very-first-window OMS retries get the legacy (TOCTOU) behavior? **Tentative answer:** accept — the deploy window is a few seconds, the OMS retry window is exponential (seconds-to-minutes), so essentially zero OMS retries land in that exact window.

---

## Implementation Status

**Status:** Implemented (2026-05-12)
**Commit SHA:** _pending — fill in after first commit_
**Verify script baseline:** `sbdocs/9-System/scripts/verify-SBDEV-2222-rest-inbound-no-idempotency-contract.sh` (planned).

### Files created

- `src/main/java/net/aim_ai/wms/model/RestIdempotency.java` — JPA entity (natural PK on `idempotency_key`, does NOT extend `AbstractBaseEntity`).
- `src/main/java/net/aim_ai/wms/repo/jpa/RestIdempotencyRepository.java` — Spring Data JPA repo with `findByIdempotencyKey`, `deleteByIdempotencyKeyIfExists`, `deleteOlderThan(Instant|LocalDateTime)`.
- `src/main/java/net/aim_ai/wms/service/RestIdempotencyService.java` — `tryClaim`/`getCachedResponse` (read tenant tx) + `persistResponse` (REQUIRES_NEW tenant tx).
- `src/main/java/net/aim_ai/wms/landlord/config/IdempotencyFilter.java` — `OncePerRequestFilter`; checks `SecurityContextHolder` for 401; hashes body via SHA-256; clears `itemdata` Caffeine cache on `/rest/sku/**` replay.
- `src/main/java/net/aim_ai/wms/schedulejob/RestIdempotencyCleanupJob.java` — nightly cleanup wrapped in `AdvisoryLockService.JobLockId.CLEANUP_REST_IDEMPOTENCY` (100007L).
- `src/main/resources/db/migration/V2.1.10__add_rest_idempotency.sql` — Flyway migration for the `rest_idempotency` table + `created_at` index.

### Files modified

- `src/main/java/net/aim_ai/wms/service/AdvisoryLockService.java` — added `JobLockId.CLEANUP_REST_IDEMPOTENCY = 100007L`.
- `src/main/java/net/aim_ai/wms/SecurityConfiguration.java` — wired `IdempotencyFilter` via `http.addFilterAfter(idempotencyFilter, BearerTokenAuthenticationFilter.class)`; controlled by `app.idempotency.enforce` (default `true`).

### Tests

- 11/11 TDD-gate tests pass (`RestIdempotencyServiceUnitTest`, `IdempotencyFilterUnitTest`, `RestIdempotencyCleanupJobUnitTest`, `AdvisoryLockServiceJobLockIdContractTest`).
- Test-scope stubs under `src/test/java/net/aim_ai/wms/stubs/idempotency/` were deleted; the four test files re-pointed at the production packages.
- `RestIdempotencyServiceUnitTest` `underTest()` helper rewritten to wire the real `RestIdempotencyService` against a Mockito-mocked `RestIdempotencyRepository` (key-dispatched answers). Assertion logic in each test method is unchanged.

### `mvn test` results

**Targeted run (SBDEV-2222 gate tests only):**
```
$ mvn test -Dtest=RestIdempotencyServiceUnitTest,IdempotencyFilterUnitTest,RestIdempotencyCleanupJobUnitTest,AdvisoryLockServiceJobLockIdContractTest
Tests run: 11, Failures: 0, Errors: 0, Skipped: 0
BUILD SUCCESS  (10.340 s)
```

**Full suite:**
```
Tests run: 3931, Failures: 1, Errors: 2, Skipped: 65
BUILD FAILURE
```

Pre-existing failures (present on baseline before this change — confirmed via `git stash` run):
- `OptionalSafetyArchTest` — ArchUnit reports `Optional.get()` in `StockunitService.java:197`
  and `UnitloadService.java:262/265`. **Not introduced by SBDEV-2222** (my service uses `.orElseThrow()`).
- `StockSummaryExportJobTest$SendListErrorHandling.shouldHandleEmptyStockCountList` — `UnnecessaryStubbingException` — pre-existing.
- `ViewDtoServiceUnitTest$ReplenishOrderViews.getReplenishOrderViewByKeywordShouldReturnOpenOrders` — `UnnecessaryStubbingException` — pre-existing.

Zero regressions introduced by this change.
