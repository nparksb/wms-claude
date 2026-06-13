---
title: "SBDEV-2236 — AdviceRestController RETURN-type advice auto-receives on creation"
ticket: "SBDEV-2236"
ticket_url: "https://app.clickup.com/t/868jj353c"
type: "bug"
priority: "normal"
status: "archived"
pr: "https://github.com/SiteBossInc/wms2-api/pull/24"
commit: "7f9c250"
project:
  - wms2-api
version: "v2"
requester: "David Oppenheim"
created: "2026-05-15"
updated: "2026-05-15"
related:
  - wms2-oms-integration-map
  - wms2-receiving-putaway-workflow
  - wms2-transaction-osiv-boundary-map
tags:
  - plan
  - wmsv2
db_verified: true
---

# SBDEV-2236 — `AdviceRestController` RETURN-type advice auto-receives on creation

**Ticket:** [SBDEV-2236](https://app.clickup.com/t/868jj353c)
**Project:** wms2-api | **Version:** v2 | **Type:** bug
**Priority:** normal
**Status:** draft
**Date:** 2026-05-15

> **db_verified: true** — RETURN-advice state distribution verified via MCP `wms1-wineco-dev`
> (v1 dev DB; the `advice` / `adviceposition` / `goodsreceiptposition` schema is structurally
> identical between v1 and v2 for the fields this plan touches). Queries run 2026-05-15.
>
> **Baseline (wineco-dev, 2026-05-15):** 2,215 rows in `advice` where `type='RETURN'`.
> **100% are in `state='FINISHED'`. 0 are in `state='OPEN'`.** Oldest auto-received RETURN
> advice: 2020-03-25. Every RETURN advice ever created via REST has been marked FINISHED at
> creation time — i.e. the bug has been present since RETURN-advice support shipped, and the
> historical record is uniformly "auto-received". This rules out the "maybe only some clients
> hit it" hypothesis; the broken code path is the only path.

---

## 0. Affected Sites

All sites in the RETURN-advice create / receive call chain were enumerated. Only the
`AdviceRestController.create(...)` RETURN branch implements the broken auto-receive behavior.
The `FileImportController` RETURN branch (already create-only) is the reference shape and the
mobile `/receive` entry point is the correct receive path — neither is in scope.

| # | File:line | Construct | Same root-cause? | In-scope this plan? |
|---|-----------|-----------|------------------|---------------------|
| 1 | `controller/rest/AdviceRestController.java:286-354` | `if (adviceEntity.getType() == AdviceType.RETURN) { ... receivingService.receiveGoods(...); ... updateAdviceToStateById(FINISHED) }` block inside `create(...)` | YES — THE bug | **YES — delete entire block** |
| 2 | `controller/rest/AdviceRestController.java:201-207` | `setType(REGULAR)` / `setType(RETURN)` — type-assignment stays | N/A | **YES — keep, no edit** |
| 3 | `controller/rest/AdviceRestController.java:164-167` | `if (RETURN || TRANSFER) → require client.enablereceiving` — validation stays | N/A | **YES — keep, no edit** |
| 4 | `controller/FileImportController.java:433-474` | RETURN branch already "create-only, no auto-receive" — reference shape | No (already correct) | **OUT — leave alone** |
| 5 | `controller/ReceivingController.java:235-252` | `POST /receive` — mobile receive entry point, unchanged | No | **OUT** |
| 6 | `service/ReceivingService.java:439-447, 505-521` | `switch(advice.getType())` handles RETURN correctly when called from `/receive` | No | **OUT** |
| 7 | `test/.../AdviceRestControllerUnitTest.java:522-565` | `shouldCreateReturnAdviceAndAutoReceiveGoods` — asserts broken behavior | YES | **YES — rewrite** |
| 8 | `test/.../AdviceRestControllerUnitTest.java:567-615` | `shouldCreateReturnAdviceWithExplicitPrinterIdAndAutoReceiveGoods` | YES | **YES — rewrite** |
| 9 | `test/.../AdviceRestControllerUnitTest.java:617-702` | Two printer-error 400 tests (only exist because printer is resolved at create time) | YES (consequence) | **YES — delete** |

**Scope rationale:** rows 1, 7, 8, 9 form one atomic deletion — remove the auto-receive block
and rewrite/delete the tests that asserted the broken behavior. Rows 2, 3 remain because they
encode the legitimate "RETURN advice exists, requires receiving-enabled client" semantics. Rows
4, 5, 6 prove the post-fix behavior is already correct on the other entry points: file-import
already does create-only, and the mobile `/receive` path through `ReceivingService` correctly
handles a RETURN advice that is in `state=OPEN`.

---

## 1. Problem Statement

`AdviceRestController.create(List<AdviceDto>, Principal)` is the REST entry point OMS uses to
push advice (notifications of incoming goods) into WMS. For type `REGULAR` (vendor receiving),
the endpoint correctly creates the advice + positions in `AdviceState.OPEN` and waits for a
mobile operator to scan the goods at the dock via `POST /receive`. For type `RETURN`
(customer return), the same endpoint **immediately synthesizes a goods-receipt for the full
notified amount, prints a return label, and flips the advice to `AdviceState.FINISHED`** —
before any physical confirmation that the goods arrived.

User-visible symptoms:

1. Every RETURN advice that OMS creates appears in WMS as already-received. Operators have
   no record of whether the bottles actually arrived; the stock report shows the increment as
   confirmed.
2. Reconciliation between OMS "advice sent" and WMS "goods received" is meaningless for
   RETURNs — the two systems agree 100% by construction, even when nothing was physically
   received.
3. DB-verified scope: in the wineco-dev tenant, **2,215 of 2,215 RETURN advices (100%)** are
   in `FINISHED` state, oldest dated 2020-03-25. Every RETURN advice ever created via REST has
   been auto-received; the bug has been continuously present since RETURN support shipped.

Reproduction:

1. `PUT /rest/advice/create` with `type=RETURN`, one position, `notifiedamount=10`.
2. Without sending `/receive` or scanning anything: `SELECT state FROM advice WHERE id=<new>;`
   returns `FINISHED`.
3. `SELECT count(*), SUM(amount) FROM goodsreceiptposition WHERE adviceposition_id IN (...);`
   returns one row, `amount=10` — a fully-synthesized goods-receipt for goods that never arrived.

---

## 2. Root Cause Analysis

**File:** `v2/wms2-api/src/main/java/net/aim_ai/wms/controller/rest/AdviceRestController.java:286-354`

After the `create(...)` method persists the `Advice` (type=RETURN, state=OPEN) and the
`Adviceposition` rows (also state=OPEN), control enters a RETURN-specific block that:

1. **Resolves a `Printer` of type `RETURN`** — either from the DTO's `printerId` (validated to
   be PrinterType.RETURN) or from the sysprop-driven default
   (`printerRepository.findByTypeAndProcessdefaultTrue(PrinterType.RETURN)`).
2. **Loops over every persisted `Adviceposition`** via
   `advicepositionRepository.findByAdviceId(adviceEntity.getId())`.
3. **For each position, calls `receivingService.receiveGoods(positionId, null, false,
   notifiedamount, notifiedamount, 1, boxtypeId, returnPrinter)`** — synthesizing exactly one
   case-unitload equal to the full notified amount. This is identical to what a mobile operator
   would do at the dock, except no operator was involved.
4. **Marks all positions then the parent advice as `AdviceState.FINISHED`** via
   `updateAdvicepositionToStateByAdviceId(FINISHED, adviceId)` and
   `updateAdviceToStateById(FINISHED, adviceId)`.

The act of receiving — which exists to certify that goods are physically present at the dock —
is invoked at advice-creation time, when no goods are guaranteed to exist anywhere except
inside OMS's intent. The advice is born FINISHED.

**Transaction boundary:** `create(...)` is NOT itself `@Transactional`. Each
`receivingService.receiveGoods(...)` call opens its own
`@Transactional(value="tenantTransactionManager", rollbackFor={BusinessException.class,
FacadeException.class})` per loop iteration. A failure on position N leaves positions 1..N-1
committed as "received" and the parent advice still in `OPEN` until the loop completes — there
is no atomicity. This is a secondary consequence of the primary bug; the fix removes the loop
entirely, which moots it.

**Reference: `FileImportController.RETURN` branch (lines 433–474)** does the right thing — it
creates the advice + positions in `OPEN` and stops. The REST-API path is the outlier, not the
rule. Whatever requirement once motivated REST auto-receive has either lapsed or was never
correct.

### Affected locations

| # | File | Line | Description |
|---|------|------|-------------|
| 1 | `controller/rest/AdviceRestController.java` | 286–354 | Auto-receive block to delete (printer resolution + receive loop + mark-FINISHED) |
| 2 | `test/.../controller/rest/AdviceRestControllerUnitTest.java` | 522–565 | Rewrite to assert no auto-receive |
| 3 | `test/.../controller/rest/AdviceRestControllerUnitTest.java` | 567–615 | Rewrite to assert printer is ignored |
| 4 | `test/.../controller/rest/AdviceRestControllerUnitTest.java` | 617–702 | Delete (printer-error 400 tests are moot once printer resolution is gone) |

---

## 3. Design / Proposed Fix

### 3.1 Fix — Delete the RETURN auto-receive block from `AdviceRestController.create`

**Problem:** Lines 286–354 of `AdviceRestController.java` resolve a printer, loop over
positions calling `receivingService.receiveGoods(...)`, and mark the advice FINISHED — all at
advice-creation time, before any physical receipt event.

**Solution:** Delete the entire `if (adviceEntity.getType() == AdviceType.RETURN) { ... }`
block. After deletion, control flows from the end of the per-position save loop (line 284)
directly into `messageService.createMessage(...)` (line 358). RETURN advice creation becomes
byte-for-byte symmetric with REGULAR advice creation: persist `Advice` in `OPEN`, persist
`Adviceposition` rows in `OPEN`, emit the OMS-bound notification message, return HTTP 204.

The mobile operator then receives the goods through the existing `POST /receive` flow
(`ReceivingController` → `ReceivingService.receiveGoods()`), which contains the production
goods-receipt synthesis logic and is the only correct way for goods to be marked received.
The existing guard at `ReceivingService.java:347` (`state == OPEN`) accepts fresh RETURN
advices unchanged.

**Before** (`AdviceRestController.java:286-354` — the block to delete):

```java
if (adviceEntity.getType() == AdviceType.RETURN) {
    Printer returnPrinter = null;
    if (adviceDto.getPrinterId() != null) {
        Optional<Printer> requestedPrinterOptional = printerRepository.findById(adviceDto.getPrinterId());
        if (requestedPrinterOptional.isPresent()) {
            Printer requestedPrinter = requestedPrinterOptional.get();
            if (PrinterType.RETURN.equals(requestedPrinter.getType())) {
                returnPrinter = requestedPrinter;
            } else {
                throw new WebserviceBusinessExceptionClientSide(ENTITY_DOES_NOT_EXISTS, ...);
            }
        } else {
            throw new WebserviceBusinessExceptionClientSide(ENTITY_DOES_NOT_EXISTS, ...);
        }
    } else {
        Optional<Printer> printerOptional = printerRepository.findByTypeAndProcessdefaultTrue(PrinterType.RETURN);
        if (printerOptional.isPresent()) {
            returnPrinter = printerOptional.get();
        }
    }

    List<Adviceposition> advicepositionList = advicepositionRepository.findByAdviceId(adviceEntity.getId());

    for (Adviceposition pos : advicepositionList) {
        try {
            // boxtype resolution (falls back itemdata → sysprop)
            if (returnPrinter != null) {
                receivingService.receiveGoods(pos.getId(), null, false,
                    pos.getNotifiedamount().intValue(),
                    pos.getNotifiedamount().intValue(), 1, boxtypeId, returnPrinter);
            } else {
                LOG.error("No RETURN printer available ...");
            }
        } catch (BusinessException | FacadeException e) {
            throw new WebserviceBusinessExceptionClientSide(GENERIC_ERROR, e);
        }
    }

    advicepositionRepository.updateAdvicepositionToStateByAdviceId(AdviceState.FINISHED, adviceEntity.getId());
    adviceRepository.updateAdviceToStateById(AdviceState.FINISHED, adviceEntity.getId());
}
```

**After:** The entire block above is removed. The method body now reads (in skeleton form):

```
PUT /rest/advice/create  (type=RETURN)
  → validateWarehouse / referenceId / type / clientId
  → require client.enablereceiving                [unchanged — line 164-167]
  → build Advice, setType(RETURN), setState(OPEN), save
  → for each position: build Adviceposition, setState(OPEN), save   [ends at line 284]
  → [REMOVED: printer resolution, receiveGoods loop, mark-FINISHED]
  → messageService.createMessage(...)             [now reached directly]
  → return 204 NO_CONTENT
```

RETURN is now byte-for-byte symmetric with REGULAR at this endpoint, and matches the existing
`FileImportController` RETURN branch.

**Files changed:** `controller/rest/AdviceRestController.java`

### 3.2 Why Option A (delete), not Option B (pending state) or Option C (document and accept)

| Option | Description | Why rejected |
|---|---|---|
| **A — Delete the block** *(chosen)* | RETURN advice stays in `OPEN` until mobile operator scans at the dock | Matches existing `FileImportController` RETURN behavior; matches REGULAR behavior; smallest blast radius; one file change |
| **B — Add `PENDING_CONFIRMATION` state + reconcile endpoint** | Introduce a new state value, a new OMS-callable confirm endpoint, and a Flyway migration | Requires new state in `AdviceState` enum + Flyway migration + reconcile endpoint + mobile UI work — scope ~5× larger for no behavioral win over A |
| **C — Document the auto-receive as intentional** | Mark the behavior as a "feature" in design docs | Conflicts with OMS-team requirement (from David Oppenheim) that physical confirmation must precede the WMS stock increment; reconciliation is broken by construction under this option |

The `FileImportController` RETURN branch already implements Option A (create-only, no
auto-receive). After this fix, the REST API matches the file-import API — the two RETURN-advice
ingress paths converge on identical semantics.

---

## 5. Prerequisites & Implementation Plan

### 5.1 Prerequisites

| # | Prerequisite | Required value / action | Owner | Notes |
|---|---|---|---|---|
| 1 | **Database state** | No schema change. No migration. | N/A | Pure code-deletion |
| 2 | **Feature flags / system properties** | None required. The `wms.printer.return.default` sysprop (if any) becomes unused by `AdviceRestController` post-fix but remains in use by `FileImportController` and operator-driven `/receive`; do NOT remove it. | N/A | |
| 3 | **Config / env changes** | None | N/A | |
| 4 | **Deploy-order dependencies** | Coordinate with OMS team — once deployed, OMS will see RETURN advices stay in `OPEN` until a WMS operator scans the dock. OMS reconciliation reports that assumed "RETURN advice == received" must be updated. | OMS team (David Oppenheim) | Coordinate cutover; OMS does not need a code change, only an expectations update |
| 5 | **Data migration** | Historical reconciliation: 2,215 RETURN advices currently in `FINISHED` were auto-received without physical confirmation. **This plan does NOT execute the reconciliation** — it is a separate operational task owned by the OMS / warehouse reconciliation team. The reconciliation SQL (Reconciliation report) is provided for that work but is not run as part of this code rollout. | OMS / reconciliation team | Separate ticket |
| 6 | **External systems** | None new. RETURN printer integration is unaffected — printer is still resolved when an operator hits `/receive`. | N/A | |
| 7 | **Access / permissions** | None | N/A | |
| 8 | **Monitoring / alerts** | Post-deploy: graph the count of RETURN advices in `state=OPEN` vs `state=FINISHED` per day. Pre-fix this ratio is `0:N`; post-fix it should rise toward `N:N` as new RETURN advices stay OPEN until the operator receives them. A flat zero post-deploy would indicate the fix did not deploy or no RETURN advices are arriving. | Implementer | Existing log/metric stack — no new metric required |
| 9 | **Reconciliation report** | Run the SQL below per-tenant before deploying the fix. Share output with OMS team for correlation. Identifies the historical "auto-received without physical confirmation" RETURN advices. | Implementer (read) / OMS team (action) | Verify expectations; not gated on code merge |
| 10 | **Cross-repo OMS audit** | Before deploy, confirm that `v2/oms-laravel-api` and `v1/oms` have no report, batch job, or webhook handler that keys off the assumption "RETURN advice exists in WMS ⇒ goods already received". Status: `v2/oms-laravel-api` grep performed — `ReturnProcessingService.php:611` and `WmsApiService.php:2012` reference `advice_type='RETURN'` only at outbound creation; no consumer of WMS receipt timing found. `v1/oms` still to be checked by OMS team. | OMS team (David Oppenheim) | Block deploy if v1/oms audit is not complete |

**Reconciliation SQL** (run once per tenant, pre-deploy):

```sql
-- Identifies all RETURN advices auto-received by the buggy code path.
-- This is INFORMATIONAL — share output with OMS for correlation.
-- This plan does NOT execute corrective action on these rows.
SELECT
    a.id                                         AS advice_id,
    a.externalid                                 AS advice_external_id,
    a.type,
    a.state                                      AS advice_state,
    a.created                                    AS advice_created_at,
    COUNT(DISTINCT ap.id)                        AS position_count,
    COUNT(DISTINCT grp.id)                       AS goods_receipt_position_count,
    COALESCE(SUM(grp.amount), 0)::numeric        AS received_total_bottles,
    COALESCE(SUM(ap.notifiedamount), 0)::numeric AS notified_total_bottles
FROM advice a
JOIN adviceposition ap             ON ap.advice_id = a.id
LEFT JOIN goodsreceiptposition grp ON grp.adviceposition_id = ap.id
WHERE a.type  = 'RETURN'
  AND a.state = 'FINISHED'
GROUP BY a.id, a.externalid, a.type, a.state, a.created
HAVING COALESCE(SUM(grp.amount), 0) = COALESCE(SUM(ap.notifiedamount), 0)
ORDER BY a.created DESC;
```

wineco-dev result (2026-05-15): **2,215 rows** — 100% of all RETURN advices in the tenant,
spanning 2020-03-25 → 2026-04-21. Every historical RETURN advice was auto-received with
`received_total_bottles == notified_total_bottles`.

### 5.2 Implementation Checklist

- [ ] Read `controller/rest/AdviceRestController.java` lines 270–360 to confirm the block boundary matches the §3.1 snippet (line numbers may drift slightly with merges).
- [ ] Delete `controller/rest/AdviceRestController.java` lines 286–354 — the entire `if (adviceEntity.getType() == AdviceType.RETURN) { ... }` block.
- [ ] After deletion, verify control flow falls directly from the end of the position-save loop (line 284) into `messageService.createMessage(...)` (now contiguous).
- [ ] Verify imports: if the deletion leaves `Printer`, `PrinterType`, `Adviceposition`, or `BoxType` imports unused, remove them. If `printerRepository`, `advicepositionRepository`, `receivingService`, `boxtypeRepository` fields become unused **inside `AdviceRestController` only**, remove the field declarations and constructor parameters. Other methods in the class may still use them — `grep` before deleting.
- [ ] Rewrite `AdviceRestControllerUnitTest.shouldCreateReturnAdviceAndAutoReceiveGoods` (line 522) as `shouldCreateReturnAdviceWithoutAutoReceive` per §6 table.
- [ ] Rewrite `AdviceRestControllerUnitTest.shouldCreateReturnAdviceWithExplicitPrinterIdAndAutoReceiveGoods` (line 567) as `shouldCreateReturnAdviceIgnoresPrinterId` per §6 table.
- [ ] Delete `AdviceRestControllerUnitTest.shouldReturnBadRequestWhenExplicitReturnPrinterIdNotFound` (line 617) and `shouldReturnBadRequestWhenExplicitPrinterIdIsNotReturnType` (line 660) — printer resolution removed from create path.
- [ ] Add `shouldCreateReturnAdviceInOpenState` — ArgumentCaptor verifies saved Advice and Adviceposition rows both have `state == AdviceState.OPEN`.
- [ ] Add `shouldNotInvokeReceivingServiceForReturnAdvice` — `verify(receivingService, never()).receiveGoods(any(), any(), any(), any(), any(), any(), any(), any())`.
- [ ] Add `shouldNotMarkAdviceFinishedOnCreate` — `verify(advicepositionRepository, never()).updateAdvicepositionToStateByAdviceId(eq(AdviceState.FINISHED), any())` AND `verify(adviceRepository, never()).updateAdviceToStateById(eq(AdviceState.FINISHED), any())`.
- [ ] Confirm with OMS team (David Oppenheim) that the `StockChangeDto` `CODE_RECEIVING_RETURN` notification timing shift is acceptable: pre-fix it fired synchronously at advice-create time (via `ReceivingService.java:512-514`); post-fix it fires at operator `/receive` time (potentially hours/days later). No OMS code change required — this is an expectations confirmation, not a code gate.
- [ ] Run `mvn test -Dtest=AdviceRestControllerUnitTest` — expect all PASS.
- [ ] Run `mvn verify` — full test + integration test suite green.
- [ ] Run `bash sbdocs/9-System/scripts/verify-SBDEV-2236-return-advice-auto-receive-fix.sh` — all PASS.
- [ ] Code review completed.
- [ ] Update plan: status → implemented, record commit SHA, mvn results, and PR link.

---

## 6. Test Plan

### Test scenarios

| Scenario | Steps | Expected Result |
|----------|-------|-----------------|
| RETURN advice create stays in OPEN | Unit test exercises `create(...)` with `type=RETURN` | `verify(receivingService, never()).receiveGoods(any())`; ArgumentCaptor confirms saved Advice.state == OPEN and Adviceposition.state == OPEN; HTTP 204 returned |
| RETURN advice ignores `printerId` in DTO | Unit test passes `adviceDto.setPrinterId(123L)` with `type=RETURN` | `verify(printerRepository, never()).findById(any())` AND `verify(printerRepository, never()).findByTypeAndProcessdefaultTrue(any())`; HTTP 204 |
| RETURN advice never marked FINISHED on create | Unit test exercises `create(...)` | `verify(advicepositionRepository, never()).updateAdvicepositionToStateByAdviceId(eq(FINISHED), any())` AND `verify(adviceRepository, never()).updateAdviceToStateById(eq(FINISHED), any())` |
| REGULAR advice unchanged | Existing regression tests for `type=REGULAR` | All existing REGULAR-advice unit tests pass without modification |
| Mobile receive on a fresh RETURN advice | Integration / manual: create RETURN advice via REST, then call `/receive` on its positions | `ReceivingService.receiveGoods` succeeds, creates `goodsreceiptposition` rows, flips advice + positions to FINISHED at receive time (not create time) |

### New / updated tests

| Test class | Test method | Action | What it asserts |
|------------|-------------|--------|-----------------|
| `AdviceRestControllerUnitTest` | `shouldCreateReturnAdviceAndAutoReceiveGoods` (line 522) | **Rewrite** → `shouldCreateReturnAdviceWithoutAutoReceive` | `verify(receivingService, never()).receiveGoods(...)` + HTTP 204 + saved Advice.state == OPEN |
| `AdviceRestControllerUnitTest` | `shouldCreateReturnAdviceWithExplicitPrinterIdAndAutoReceiveGoods` (line 567) | **Rewrite** → `shouldCreateReturnAdviceIgnoresPrinterId` | `verify(printerRepository, never()).findById(any())` + `verify(printerRepository, never()).findByTypeAndProcessdefaultTrue(any())` + HTTP 204 |
| `AdviceRestControllerUnitTest` | `shouldReturnBadRequestWhenExplicitReturnPrinterIdNotFound` (line 617) | **Delete** | Printer resolution removed from create path; test is moot |
| `AdviceRestControllerUnitTest` | `shouldReturnBadRequestWhenExplicitPrinterIdIsNotReturnType` (line 660) | **Delete** | Same reason |
| `AdviceRestControllerUnitTest` | `shouldCreateReturnAdviceInOpenState` | **Add** | ArgumentCaptor confirms saved `Advice` + `Adviceposition` both have `state == AdviceState.OPEN` |
| `AdviceRestControllerUnitTest` | `shouldNotInvokeReceivingServiceForReturnAdvice` | **Add** | `verify(receivingService, never()).receiveGoods(any(), any(), any(), any(), any(), any(), any(), any())` |
| `AdviceRestControllerUnitTest` | `shouldNotMarkAdviceFinishedOnCreate` | **Add** | Neither `updateAdvicepositionToStateByAdviceId(FINISHED,…)` nor `updateAdviceToStateById(FINISHED,…)` is called |

### Manual test plan

| Scenario | Environment | Steps | Expected Result | Pass/Fail |
|---|---|---|---|---|
| RETURN advice create → no auto-receive | staging | 1. `PUT /rest/advice/create` with `type=RETURN`, `notifiedamount=10`. 2. `SELECT state FROM advice WHERE id=<new>`. 3. `SELECT count(*) FROM goodsreceiptposition WHERE adviceposition_id IN (SELECT id FROM adviceposition WHERE advice_id=<new>)`. | (2) returns `OPEN`; (3) returns 0 — no synthesized goods-receipt for this advice. | |
| RETURN advice mobile receive (happy path) | staging | After the create above, scan the adviceposition via mobile `POST /receive`. Re-run the SELECTs. | `advice.state = FINISHED`; `adviceposition.state = FINISHED`; ≥1 `goodsreceiptposition` row created with `amount = received amount`. The flip to FINISHED happens at receive time, not at create time. | |
| REGULAR advice unchanged | staging | `PUT /rest/advice/create` with `type=REGULAR`. Verify behavior identical to pre-fix. | Advice + positions persisted in `OPEN`, OMS notification sent, HTTP 204. | |
| Reconciliation SQL (historical) | staging DB | Run the §5.1 reconciliation SQL. | Returns rows with `advice_created_at < deploy_time` (the historical 2,215). No new rows appear with `advice_created_at > deploy_time` (post-fix RETURN advices stay OPEN, so the `state='FINISHED'` filter excludes them until they are physically received). | |

### Test execution (fill in after running)

| Command | Result | Pass / Fail / Skipped counts |
|---------|--------|------------------------------|
| `mvn test -Dtest=AdviceRestControllerUnitTest` | | |
| `mvn verify` | | |
| `bash sbdocs/9-System/scripts/verify-SBDEV-2236-return-advice-auto-receive-fix.sh` | | |

### Deliberately-skipped coverage

| What | Why |
|------|-----|
| Integration test for the RETURN → `/receive` flow end-to-end | The `/receive` handler is unchanged by this plan; `ReceivingService.receiveGoods` already has its own coverage. The manual test plan exercises the joined flow in staging. |
| Reverse-migration test (re-introduce the auto-receive block) | Negative testing of a deletion is exercised by the verify-script's "block must be absent" check. |
| Historical-data backfill tests | This plan does not migrate the 2,215 historical RETURN advices — that is a separate operational task owned by the OMS / reconciliation team. |

---

## 7. Horizontal Scalability Validation (v2 — MANDATORY)

| # | Concern | Does this change... | Verdict | Mitigation / rationale |
|---|---|---|---|---|
| 1 | **In-JVM state** | Introduce state that only exists in one replica (Caffeine cache, `ConcurrentHashMap`, static field, `ThreadLocal`)? | No | Pure deletion; no new state of any kind |
| 2 | **Connection pool math** | Change per-request DB connection usage (holding connection longer, new pools, new tenants)? | No (net improvement) | Removes a per-position `@Transactional` `receiveGoods` call from the `create(...)` request — each historical RETURN advice creation released N+1 transaction acquisitions (1 for advice create + N for the receive loop); post-fix only the advice-create transactions remain. Net reduction in per-request DB connection usage. |
| 3 | **Scheduled jobs** | Add or modify a `@Scheduled` / cron job? | No | |
| 4 | **Long transactions** | Hold a DB transaction across multiple repository calls or external I/O? | No (net improvement) | Fewer transactions per request; no new I/O introduced |
| 5 | **Request affinity** | Assume a follow-up request lands on the same replica? | No | Stateless endpoint; no in-memory session state |
| 6 | **Retry / idempotency** | Rely on single-execution semantics that break if a replica dies mid-op and another replica retries? | No | `create(...)` is idempotent on advice creation via the existing duplicate-externalId guard. The deletion does not affect idempotency. |
| 7 | **Tenant context** | Use `TenantContext` / `ThreadLocal` / `@RequestScope` across async boundaries? | No | No async path involved; tenant context is set by the standard request filter and unchanged |
| 8 | **Distributed lock correctness** | Add or rely on pessimistic / optimistic lock across replicas? | No (net improvement) | Removes the per-position pessimistic-lock acquisition that `receivingService.receiveGoods` performs on `Stockunit` / `Unitload`; one less serialization point in the create path |
| 9 | **Cache invalidation** | Write to an entity that is cached (Caffeine local or Redis shared)? | No | No cached entities are touched by the deleted code path |
| 10 | **External notifications (OMS, printer, etc.)** | Send an HTTP / message to an external system inside a transaction? | No (timing shift) | The deleted code triggered `receiveGoods` (which prints a label and emits a `StockChangeDto` via `ReceivingService.java:512-514` with `code=CODE_RECEIVING_RETURN`). Pre-fix this notification fired at advice-create time; post-fix it is deferred to the operator `/receive` event (potentially hours/days later). The message itself is unchanged — only its timing shifts. OMS must tolerate late-arriving `CODE_RECEIVING_RETURN` stock-change messages and not assume they arrive synchronously with advice creation. `messageService.createMessage(...)` at line 360 remains after the main flow and is unaffected. |

### Evidence

| Concern # | What was done / verified | File:line or test reference |
|-----------|--------------------------|------------------------------|
| 2 | Existing `receivingService.receiveGoods` is `@Transactional(value="tenantTransactionManager")` — removing its invocation from `AdviceRestController.create` strictly reduces transaction count per request. | `service/ReceivingService.java` (transactional boundary unchanged) |
| 4 | Post-fix `create(...)` flow ends at `messageService.createMessage(...)`; no I/O introduced. | `controller/rest/AdviceRestController.java:358` (post-fix contiguous with line 284) |
| 8 | Removes per-position `Stockunit` / `Unitload` pessimistic-lock acquisitions that `receiveGoods` makes inside the loop. | `service/ReceivingService.java` (lock acquisition site unchanged; we just stop calling it) |

---

## 8. Notes

### 8.1 Acceptance Criteria

**AC1 — Auto-receive block removed**

`grep -nE "receivingService\.receiveGoods" v2/wms2-api/src/main/java/net/aim_ai/wms/controller/rest/AdviceRestController.java` returns no matches.

**AC2 — Printer resolution removed from create path**

`grep -nE "printerRepository\.(findById|findByTypeAndProcessdefaultTrue)" v2/wms2-api/src/main/java/net/aim_ai/wms/controller/rest/AdviceRestController.java` returns no matches.

**AC3 — Mark-FINISHED removed from create path**

`grep -nE "updateAdviceToStateById|updateAdvicepositionToStateByAdviceId" v2/wms2-api/src/main/java/net/aim_ai/wms/controller/rest/AdviceRestController.java` returns no matches in the RETURN-create context (any other usage in the controller — e.g. an explicit close endpoint — is fine; the deletion scope is the `create(...)` method).

**AC4 — Type-validation and `enablereceiving` guard unchanged**

`grep -nE "enablereceiving" v2/wms2-api/src/main/java/net/aim_ai/wms/controller/rest/AdviceRestController.java` still returns the existing line in the `if (RETURN || TRANSFER)` block.

**AC5 — RETURN advice persists in OPEN state**

Unit test `shouldCreateReturnAdviceInOpenState` asserts via ArgumentCaptor that the saved `Advice` and `Adviceposition` rows both have `state == AdviceState.OPEN` after `create(...)`.

**AC6 — `receivingService.receiveGoods` is never invoked from `create(...)`**

Unit test `shouldNotInvokeReceivingServiceForReturnAdvice` asserts
`verify(receivingService, never()).receiveGoods(any(), any(), any(), any(), any(), any(), any(), any())`.

**AC7 — Printer-error 400 tests deleted**

`grep -nE "shouldReturnBadRequestWhenExplicitReturnPrinterIdNotFound|shouldReturnBadRequestWhenExplicitPrinterIdIsNotReturnType" v2/wms2-api/src/test/java/...` returns no matches.

**AC8 — `mvn test` green**

`mvn test -Dtest=AdviceRestControllerUnitTest` exits 0. `mvn verify` exits 0.

### 8.2 Related plans

- **SBDEV-2215** (`AdviceService` `@Transactional` annotations): orthogonal — operates on the
  service-layer boundary inside `AdviceService`, not on the REST entry point's RETURN branch. No
  ordering dependency.
- **SBDEV-2222** (idempotency filter): orthogonal — ship in any order. The
  duplicate-externalId guard inside `create(...)` is independent of the auto-receive deletion.
- **SBDEV-2217** (advice sequence number): orthogonal — touches sequence-assignment, not
  type-specific behavior. No overlap.
- **`FileImportController`** RETURN branch: the reference shape. After this plan ships, the
  REST and file-import RETURN-ingress paths are semantically identical.

### 8.3 Pre-mortem — failure scenarios

**Scenario A — OMS reconciliation reports degrade because RETURN advices now stay OPEN**

Some OMS-side reports may count "RETURN advice exists in WMS" as proof of receipt. Post-fix, a
RETURN advice can exist in WMS in `OPEN` state for hours or days before an operator scans the
dock. Any OMS report that conflated "advice created" with "goods received" will now show a gap
between the two events — which is the correct state but a change in reporting reality.
**Mitigation:** §5.1 prereq 4 calls out the coordination with David Oppenheim's OMS team
explicitly; the reconciliation SQL in §5.1 lets OMS distinguish historical (pre-fix,
auto-received) from new (post-fix, awaiting physical receipt).

**Scenario B — Operators do not know they now need to scan RETURN dock arrivals**

If the warehouse SOP previously skipped the `/receive` step for RETURN advices (because the
system auto-marked them received), operators may not realize they must now scan the dock. The
result is RETURN advices stuck in `OPEN` forever, accumulating in the queue.
**Mitigation:** the existing mobile `POST /receive` flow already handles RETURN advices —
no UI change is required, only a procedural one. Coordinate with the warehouse training lead
before deploy. Add a monitoring panel for RETURN-advice age in `OPEN` (e.g. count of RETURN
advices with `state='OPEN' AND created < now() - interval '7 days'`); if this counter rises,
operators need a training nudge.

**Scenario C — A downstream system depends on the synthetic goods-receipt rows generated by the bug**

If any report, view, or external integration queries `goodsreceiptposition` joined to RETURN
advices and treats the synthesized rows as ground truth, those downstreams will see fewer
records post-fix (no new synthetic rows). Historical synthetic rows remain in the DB; only
new RETURN advices stop generating them at create time.
**Mitigation:** grep the codebase for `goodsreceiptposition` queries scoped to
`type='RETURN'` — none found in v2/wms2-api beyond the standard receive flow. Extended grep
to `v2/oms-laravel-api`: `ReturnProcessingService.php:611` and `WmsApiService.php:2012`
reference `advice_type='RETURN'` only at outbound advice creation — no consumer of WMS
receipt timing was found. `v1/oms` was not in the working tree; OMS team should verify no
legacy BI report keys off "RETURN advice created ⇒ already received" before deploy.
Coordinate with OMS and BI teams to confirm no external report depends on the synthetic-row
generation.

---

## 9. Acceptance & Implementation

### 9.1 Acceptance script

`sbdocs/9-System/scripts/verify-SBDEV-2236-return-advice-auto-receive-fix.sh`

The script encodes AC1–AC7 as grep-based checks and AC8 as a targeted `mvn test` invocation.
The script must exit 0 (all PASS) before the implementing agent's "DONE" claim is accepted.

### 9.2 Recommended OMC composition

| Aspect | Value | Rationale |
|---|---|---|
| **Size class** | Standard | 1 production-code change (deletion), 1 test-file change (2 rewrites + 2 deletes + 3 adds); high-impact behavioral change but mechanically simple |
| **Pre-draft step** | none | Plan grounded in verified code facts and DB-verified scope; no ccg / deep-interview needed |
| **Plan-review step** | `critic` | Behavioral change affecting OMS integration — second pair of eyes warranted before coding starts |
| **Implementation shape** | `executor` | Single-file deletion + test rewrites; well-bounded |
| **Verification step** | verify-script + `verifier` | Mandatory |
| **Code-review step** | `code-reviewer` | OMS-integration-affecting change — recommended before merge |
| **Commit step** | git directly | Single logical commit — controller deletion + test changes land together |

---

## §10 Rollout & Verification

**Pre-deploy DB baseline** (run per tenant, record output):

```sql
-- Capture the pre-fix RETURN-advice state distribution:
SELECT state, count(*)
FROM advice
WHERE type = 'RETURN'
GROUP BY state
ORDER BY state;
-- Expected pre-fix: state='FINISHED' = N, state='OPEN' = 0 (every RETURN auto-received).

-- Run the §5.1 reconciliation SQL — share output with OMS team.
```

```bash
# Run verify script against the pre-fix code — should report fail on AC1/AC2/AC3:
bash sbdocs/9-System/scripts/verify-SBDEV-2236-return-advice-auto-receive-fix.sh
# Expected pre-fix output: Result: <some pass>, <some fail> (deletion checks fail before patch).
```

**Deploy:** Single-JAR redeploy of `wms2-api`. No schema migration, no data migration, no
feature flag, no env-var change.

**Rollback:** Redeploy the previous JAR artifact. Any RETURN advices created between deploy
and rollback that the operator did NOT scan via `/receive` will remain in `state='OPEN'`. They
are not corrupted — they just await physical receipt. Operators can finish receiving them
through the normal mobile flow at any time post-rollback; the rolled-back code does not break
the receive path. No data cleanup required.

**Post-deploy verification (within 1 hour of deploy):**

1. Create one test RETURN advice via REST: `PUT /rest/advice/create` with `type=RETURN`,
   `notifiedamount=1`.
2. Confirm via SQL: `SELECT state FROM advice WHERE id=<new>` returns `OPEN`.
3. Confirm via SQL: `SELECT count(*) FROM goodsreceiptposition WHERE adviceposition_id IN
   (SELECT id FROM adviceposition WHERE advice_id=<new>)` returns 0.
4. Scan the test position via mobile `/receive`.
5. Confirm via SQL: `SELECT state FROM advice WHERE id=<new>` returns `FINISHED`; the
   `goodsreceiptposition` count is now 1.
6. Re-run the pre-deploy baseline SQL. The `state='OPEN'` count for RETURN advices should
   now be ≥1 (the test advice, plus any real RETURN advices that arrived during the deploy
   window).

**Post-deploy (24h after):** RETURN advices in `state='OPEN'` should rise to roughly the
typical daily intake of RETURN advices. The historical 2,215 in `FINISHED` are unchanged. Any
RETURN advice older than 7 days in `state='OPEN'` post-fix is an operational anomaly — flag
for the warehouse lead to investigate (likely operator missed a scan).
