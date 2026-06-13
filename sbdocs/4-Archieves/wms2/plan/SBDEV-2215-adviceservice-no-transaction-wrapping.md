---
title: "SBDEV-2215 — AdviceService mutations have NO transaction wrapping at all"
ticket: "SBDEV-2215"
ticket_url: "https://app.clickup.com/t/868jj31d6"
type: "bug"
priority: "high"
severity: "critical"
status: "archived"
project: ["wms2-api"]
version: "v2"
requester: "David Oppenheim"
assignee: "Nam Park"
created: "2026-05-08"
updated: "2026-05-10"
db_verified: false
related:
  - "[[SBDEV-2214-oms-http-post-inside-class-level-transactional]]"
  - "[[260424-oms-notification-rollback-risk-remediation]]"
  - "[[wms2-oms-integration-map]]"
  - "[[wms2-transaction-osiv-boundary-map]]"
  - "[[wms2-state-machine-catalog]]"
  - "[[wms2-receiving-putaway-workflow]]"
tags:
  - plan
  - wmsv2
  - oms-integration
  - transaction-boundary
  - advice
  - receiving
---

# SBDEV-2215 — AdviceService mutations have NO transaction wrapping at all

**Ticket:** [SBDEV-2215](https://app.clickup.com/t/868jj31d6)
**Project:** wms2-api | **Version:** v2 | **Type:** bug
**Priority:** High | **Severity:** CRITICAL (Tier 1)
**Status:** merged to `develop` (2026-05-10) — bundled into the SBDEV-2214 implementation stack. The two prescribed test files landed via SBDEV-2214 Phase 6 commit `aebb4c7` ("BaseRollbackIntegrationTest + AdviceServiceRollbackIntegrationTest"); the trailing ArchUnit store snapshot landed via PR [#8](https://github.com/SiteBossInc/wms2-api/pull/8) merge commit `1f1bf14`. See §13 for the cross-plan map.
**Date:** 2026-05-08

> **Important framing — this is a regression-guard plan, not a new-fix plan.**
>
> The ticket cites v1 line numbers and describes v1 behavior. On v2, **all three named methods (`acceptHubAndSpokeAdvice`, `close`, `acceptTransferAdvice`) are already individually `@Transactional(value="tenantTransactionManager", rollbackFor={BusinessException.class, FacadeException.class})`** and **all three OMS POST sites already use the post-commit pattern via `omsNotificationService.sendAfterCommit(...)`**. The fixes shipped under v2 commit `41cf1f3 fix: defer OMS HTTP notifications to after transaction commit` (the SBDEV-2214 sweep), with the v1-style per-position save loops in `close()` and `acceptTransferAdvice()` further hardened by an earlier optimization (`6ba599e optimize AdviceService: bulk JPQL updates...`) that replaced them with a single `updateAdvicepositionToStateByAdviceId` bulk UPDATE.
>
> This plan therefore (a) locks in those existing fixes via regression-guard checks, (b) **explicitly rejects** the ticket's "add @Transactional at the class level on AdviceService" suggestion as harmful in v2 (would default to the landlord TM), and (c) ships the **integration test the ticket explicitly mandates** ("simulate exception after position #5 of 10 is saved; confirm rollback to original state and no OMS POST") which does not exist today. The integration test is the only net-new code in scope.

---

## 0. Affected sites (enumeration before drafting)

Greps run against `/Users/np1076/dev/spk/owl/v2/wms2-api/src/main/java`:

```
grep -n "@Transactional\|httpRestService\|public " src/main/java/net/aim_ai/wms/service/AdviceService.java
grep -rn "httpRestService\.post"                   src/main/java
grep -rn "AdviceService"                           src/main/java
grep -rn "@TransactionalEventListener"             src/main/java
grep -n  "this\.acceptHubAndSpokeAdvice\|this\.close\|this\.acceptTransferAdvice" src/main/java/net/aim_ai/wms/service/AdviceService.java
```

| # | File:line | Construct | Same root-cause as ticket? | In-scope this plan? |
|---|-----------|-----------|----------------------------|---------------------|
| 1 | `service/AdviceService.java:144` `acceptHubAndSpokeAdvice` | `@Transactional(value="tenantTransactionManager", rollbackFor={BusinessException.class, FacadeException.class})` already present | Already fixed in v2 | **Yes — POSITIVE regression-guard (the annotation must remain)** |
| 2 | `service/AdviceService.java:255` `acceptHubAndSpokeAdvice` body | `omsNotificationService.sendAfterCommit(urlPath, payload, WmsConstants.MessageProcessType.ADVICE_HUB_AND_SPOKE_RECEIVED)` — replaces the v1 inline `httpRestService.post` at v1:237 | Already fixed in v2 | **Yes — POSITIVE regression-guard** |
| 3 | `service/AdviceService.java:214-245` `acceptHubAndSpokeAdvice` per-position loop | Per-iteration `advicepositionRepository.save(advicePosition)` + `customerorderRepository.save(co)` + `unitloadBusinessService.transferUnitLoadToCarrier(...)` (the surface for mid-loop exceptions) | This is the **exact** mid-loop scenario the ticket describes; with @Transactional active, the whole tx rolls back atomically — the bug *cannot* fire | **Yes — covered by the new integration test (Fix C in §3)** |
| 4 | `service/AdviceService.java:263` `close` | `@Transactional(value="tenantTransactionManager"...)` already present | Already fixed in v2 | **Yes — POSITIVE regression-guard** |
| 5 | `service/AdviceService.java:347` `close` body | `omsNotificationService.sendAfterCommit(urlPath, payload, WmsConstants.MessageProcessType.ADVICE_CLOSE)` — replaces the v1 inline `httpRestService.post` at v1:345 | Already fixed in v2 | **Yes — POSITIVE regression-guard** |
| 6 | `service/AdviceService.java:294` `close` body | Bulk JPQL UPDATE `advicepositionRepository.updateAdvicepositionToStateByAdviceId(FINISHED, advice.getId())` — replaces the v1 per-position `save()` loop at v1:294-296 | Mid-loop scenario is structurally impossible (single SQL UPDATE) | **Yes — covered by the new integration test for `close()`** |
| 7 | `service/AdviceService.java:355` `acceptTransferAdvice` | `@Transactional(value="tenantTransactionManager"...)` already present | Already fixed in v2 | **Yes — POSITIVE regression-guard** |
| 8 | `service/AdviceService.java:410` `acceptTransferAdvice` body | `omsNotificationService.sendAfterCommit(urlPath, payload, WmsConstants.MessageProcessType.ADVICE_ACCEPT_TRANSFER)` — replaces the v1 inline `httpRestService.post` at v1:432 | Already fixed in v2 | **Yes — POSITIVE regression-guard** |
| 9 | `service/AdviceService.java:400` `acceptTransferAdvice` body | Bulk JPQL UPDATE (same as row 6) | Mid-loop scenario structurally impossible | **Yes — covered by the new integration test for `acceptTransferAdvice()`** |
| 10 | `service/AdviceService.java` (whole-file) | NO occurrence of `httpRestService.post(` anywhere — verified by grep | Already fixed in v2 | **Yes — NEGATIVE regression-guard (the construct must NOT reappear)** |
| 11 | `service/AdviceService.java:418` `setPurchaseOrderNumber` | NOT `@Transactional` but only does a guarded single-entity save | Different pattern — no OMS POST, no multi-entity mutation | **No — out-of-scope; not on the ticket's failure path** |
| 12 | `service/AdviceService.java:430,464,471` (`getAdviceDetails`, `getExistingPallets`, `exportInboundNotice`) | Read-only methods | Different pattern — no writes | **No — out-of-scope** |
| 13 | `service/AdviceService.java:125` `fixHubAndSpokePalletIssues` | Already `@Transactional(value="tenantTransactionManager"...)`; no OMS POST | Same root-cause shape (multi-entity mutation under @Transactional) but no OMS dependency | **Partial — POSITIVE regression-guard (annotation present); not part of the ticket's named methods** |
| 14 | `controller/AdviceController.java:142,171,175,202,206,259,287,326,341` (callers) | Plain controller methods (`extends AdminController` — not `@Transactional`); each invokes `adviceService.<name>(...)` | A `@Transactional` caller would render method-level @Transactional a no-op for that caller — but `AdminController` is not annotated, so each adviceService method opens its own fresh tx | **No — confirmed safe; documented in §3 caller-audit** |
| 15 | `service/AdviceService.java:1-523` self-invocation | Greps for `this.acceptHubAndSpokeAdvice`, `this.close(`, `this.acceptTransferAdvice` returned **EMPTY** | No proxy bypass | **No — confirmed safe; documented in §3 self-invocation audit** |
| 16 | `controller/rest/AdviceRestController.java:331-332` | `advicepositionRepository.updateAdvicepositionToStateByAdviceId(AdviceState.FINISHED, adviceEntity.getId()); adviceRepository.updateAdviceToStateById(AdviceState.FINISHED, adviceEntity.getId())` — called directly from a REST import endpoint (OMS→WMS advice import); `AdviceRestController extends AbstractRestController`; **no `@Transactional`** on method, class, or parent class | Same root-cause shape (unguarded bulk mutations); **different risk profile:** (a) OMS notification at this site is `messageService.createMessage(... ADVICE_IMPORT ...)` — an inbound audit log write, not an outbound `httpRestService.post` — so the `sendAfterCommit` concern does not apply; (b) the per-position `receivingService.receiveGoods(...)` loop is wrapped in a catch block that rethrows before lines 331-332 run — mid-loop exceptions abort the bulk updates entirely (inverse pattern vs. v1). The unguarded-mutation risk here is a separate concern for a dedicated follow-up ticket. | **No — out-of-scope; different flow (OMS→WMS import, not WMS→OMS close); no `sendAfterCommit` concern. Follow-up ticket required for the missing-`@Transactional` risk on this endpoint.** |

**Adjacent-bug rule (skill Layer 1, item 2):** No adjacent in-tx OMS POST patterns remain in `AdviceService.java` (whole-file grep is empty). The 13 sites in `ManageOrderService` × 7 + `MessageService.sendStockChangeMessage` etc. are covered by SBDEV-2214 — out of scope here.

**Cross-reference greps run:**

```
grep -rln "AdviceService\|acceptHubAndSpokeAdvice\|acceptTransferAdvice" sbdocs/1-Projects/ sbdocs/4-Archieves/
```

Findings (notable):
- `sbdocs/1-Projects/wms2/plan/SBDEV-2214-oms-http-post-inside-class-level-transactional.md` — **the precedent**. AdviceService is listed in §0 row 4 of that plan as "Already fixed" out-of-scope; this plan completes the audit by making AdviceService its own first-class regression-guard target.
- `sbdocs/1-Projects/wms1/plan/SBDEV-2116-unguarded-optional-get-fix-plan.md` — touches AdviceService for unrelated `Optional.get()` fixes; v2 already migrated those (`08010ba replace unsafe Optional.get() with orElseThrow(EntityNotFoundException)`).
- `sbdocs/1-Projects/wms1/plan/260424-oms-notification-rollback-risk-remediation.md` — v1 source for the helper-pattern decision that shipped to v2 as `OmsNotificationService`.
- `sbdocs/4-Archieves/wms2/plan/260407-oms-http-inside-transaction-debug-plan.md` — earliest v2 analysis of the in-tx OMS POST pattern.

**Architecture/design docs consulted:**

- `sbdocs/3-Resources/architecture/wms2-transaction-osiv-boundary-map.md` §6 — mandates "never fire an external call inside the tenant transaction; register a post-commit synchronization." `OmsNotificationService` is the reference pattern.
- `sbdocs/3-Resources/architecture/wms2-oms-integration-map.md` — lists `ADVICE_CLOSE`, `ADVICE_HUB_AND_SPOKE_RECEIVED`, `ADVICE_ACCEPT_TRANSFER` as the three outbound advice notifications.
- `sbdocs/3-Resources/architecture/wms2-state-machine-catalog.md` — `AdviceState` transitions: `OPEN → PROCESSING → CLOSED → FINISHED`. The ticket's failure mode is a partial transition where Advice is FINISHED but Adviceposition rows lag behind.
- `sbdocs/3-Resources/architecture/wms2-receiving-putaway-workflow.md` — surfaces the three advice flows (regular `close`, transfer `acceptTransferAdvice`, hub-and-spoke `acceptHubAndSpokeAdvice`) plus the unmentioned `return` flow (advice type `RETURN` follows the `close` path).
- `sbdocs/3-Resources/decisions/` — no ADR conflicts.

---

## 1. Problem Statement

**User-visible symptom (ticket-described failure mode):** WMS marks an inbound advice (regular receive / return / transfer / hub-and-spoke) as `FINISHED` but only some of its `Adviceposition` rows finish; OMS may or may not have been told. Manual data fix required, often delayed days.

**Trigger conditions (per ticket, against v1 code):**
1. WMS receives advice close from OMS.
2. Advice is saved as FINISHED → DB commit (in v1, this commits because no @Transactional wraps the method).
3. Loop starts saving positions; some succeed, then a `RuntimeException` mid-loop (e.g., DB blip, NPE on a malformed position).
4. Result: advice = FINISHED, half the positions = FINISHED, half still OPEN. No way to roll back.
5. OMS may or may not have been told.

**v2 status — verified by reading the code as of this draft:**

| v1 site (per ticket) | v1 line | v2 line | v2 status |
|---|---|---|---|
| `AdviceService` class annotated `@Service` only, NOT `@Transactional` | `:35` | n/a | **Already fixed in v2** — each of the 3 named methods has its own `@Transactional(value="tenantTransactionManager", rollbackFor={BusinessException.class, FacadeException.class})` annotation (lines 144, 263, 355). Class-level annotation is **deliberately not added** (see §3 Fix-A note: would default to landlord TM in v2). |
| `acceptHubAndSpokeAdvice`: `advice.setState(FINISHED); adviceRepository.save(advice);` | `:226-227` | `:247-248` | **Atomic in v2** — same statements, but now inside `@Transactional` (line 144). On any later exception, the whole tx rolls back. |
| `acceptHubAndSpokeAdvice`: per-position `position.setState(FINISHED); advicepositionRepository.save(position);` loop | `:294-296` | `:214-245` | **Atomic in v2** — same per-position save loop (necessary here because each iteration also creates a `Customerorder` and a `Unitload` parcel), but inside `@Transactional`. Tx rolls back atomically on mid-loop exception. |
| `acceptHubAndSpokeAdvice`: OMS POST | `:237` | `:255` | **Already deferred in v2** — `omsNotificationService.sendAfterCommit(urlPath, payload, ADVICE_HUB_AND_SPOKE_RECEIVED)`. |
| `close`: per-position `position.setState(FINISHED); advicepositionRepository.save(position);` loop | (analogous) | `:294` | **Even better than atomic in v2** — replaced by a single `advicepositionRepository.updateAdvicepositionToStateByAdviceId(FINISHED, advice.getId())` bulk JPQL UPDATE (commit `6ba599e`). The mid-loop failure mode is structurally impossible. |
| `close`: OMS POST | `:345` | `:347` | **Already deferred in v2** — `omsNotificationService.sendAfterCommit(urlPath, payload, ADVICE_CLOSE)`. |
| `acceptTransferAdvice`: per-position state mutation | (analogous) | `:400` | **Bulk JPQL UPDATE in v2** — same as `close()`. |
| `acceptTransferAdvice`: OMS POST | `:432` | `:410` | **Already deferred in v2** — `omsNotificationService.sendAfterCommit(urlPath, payload, ADVICE_ACCEPT_TRANSFER)`. |

**What v2 still lacks:** the **integration test** the ticket explicitly mandates ("simulate exception after position #5 of 10 is saved; confirm rollback to original state and no OMS POST"). The existing `AdviceServiceIntegrationTest.java` (188 lines, 5 visible `@Test` methods) does not assert the rollback semantics. Without it, a future contributor can revert the @Transactional annotation or reintroduce an inline `httpRestService.post` and the test suite would not catch it. The ticket's acceptance criterion is what gives this plan its shape.

### DB verification gate

`db_verified: **false**`.

**Why a single-query verification is not possible:** the symptom is a code-path concern (a thrown exception mid-method), not a steady-state data condition. We cannot reproduce it with a SELECT against a tenant DB; it requires a forced rollback in an H2 integration test (Fix C in §5). The MCP available in this session (`mcp__wms1-wineco-dev__execute_sql`) reaches a v1 tenant DB, not v2 — and even on v1 the partial-commit fingerprint is rare and may have been retroactively reconciled.

**What the implementer MUST run before merging — partial-commit fingerprint SQL:**

Run the following query against the chosen tenant DB (PostgreSQL syntax for v2; or the equivalent against a v1 tenant DB to corroborate the symptom shape, since v1 is where the bug actually still fires):

```sql
-- Find Advice rows in FINISHED state that have ANY Adviceposition rows
-- still in a non-FINISHED state in the same advice. This is the
-- partial-commit fingerprint described by the SBDEV-2215 ticket.
-- Pre-fix expectation (had the bug fired historically): non-zero rows.
-- Post-fix expectation (in v2 specifically): zero rows for any advice
-- closed AFTER the @Transactional + sendAfterCommit fixes shipped (commit 41cf1f3).
SELECT a.id, a.number, a.state AS advice_state, a.modified,
       COUNT(ap.id)                                                  AS total_positions,
       SUM(CASE WHEN ap.state = 'FINISHED' THEN 1 ELSE 0 END)        AS finished_positions,
       SUM(CASE WHEN ap.state <> 'FINISHED' THEN 1 ELSE 0 END)       AS non_finished_positions
FROM advice a
JOIN adviceposition ap ON ap.advice_id = a.id
WHERE a.state = 'FINISHED'
  AND a.modified > NOW() - INTERVAL '90 days'
GROUP BY a.id, a.number, a.state, a.modified
HAVING SUM(CASE WHEN ap.state <> 'FINISHED' THEN 1 ELSE 0 END) > 0
ORDER BY a.modified DESC
LIMIT 50;
```

**Pre-fix expectation:** 0 rows on v2 in steady state today (the @Transactional + bulk-update fixes have been live since commit `41cf1f3`); historical drift (rows from before the fix) may persist. Non-zero on v1 corroborates the bug shape.

**Post-fix expectation:** 0 rows on v2 in any new advice cycles; existing drift requires manual reconciliation (out-of-scope here — separate operations ticket).

**v1 corroboration:** if the v1 MCP is reachable, run the equivalent query against a v1 tenant DB. The schema rhymes (same `advice.state`, same `adviceposition.state` columns). Confirming non-zero rows pre-fix on v1 is acceptable evidence of the symptom shape. The implementer pastes the result count into §11 Implementation Status before sign-off.

**TenantContext in integration tests — NOT required.** `TestDatabaseConfig` (imported by `BaseIntegrationTest`) mocks `tenantDynamicRoutingDataSource` to return connections from the single H2 landlord DataSource. Tenant routing is bypassed entirely; all queries hit the same H2 instance regardless of TenantContext. No `TenantContext.set(...)` call is needed in `AdviceServiceRollbackIntegrationTest`.

---

## 2. Root Cause Analysis

### Bug 1 (already fixed in v2, must stay fixed): missing `@Transactional` on `acceptHubAndSpokeAdvice`

**Code reference:** `src/main/java/net/aim_ai/wms/service/AdviceService.java:144-261`

```java
@Transactional(value = "tenantTransactionManager",
               rollbackFor = {BusinessException.class, FacadeException.class})       // :144
public void acceptHubAndSpokeAdvice(Advice advice, Location location)
        throws BusinessException, FacadeException {
    // … state guard, pallet uniqueness check, customer-order-batch creation …

    for (Adviceposition advicePosition : positionList) {                              // :214
        Unitload parcel = unitloadService.createUnitload(...);
        unitloadBusinessService.transferUnitLoadToCarrier(parcel, ...);

        advicePosition.setState(WmsConstants.AdviceState.FINISHED);                   // :220
        advicepositionRepository.save(advicePosition);                                // :221

        Customerorder co = new Customerorder();                                        // :223-242
        // … fully populate co …
        customerorderRepository.save(co);
    }

    advice.setState(WmsConstants.AdviceState.FINISHED);                               // :247
    adviceRepository.save(advice);                                                    // :248

    try {
        String urlPath = syspropService.getSysvalue(SYSTEM_PROPERTY_WEBSERVICE_ACCEPT_HUB_AND_SPOKE_URL_KEY);
        ObjectMapper mapper = new ObjectMapper();
        mapper.setSerializationInclusion(JsonInclude.Include.NON_NULL);
        String payload = mapper.writeValueAsString(hasAcceptDto);
        omsNotificationService.sendAfterCommit(urlPath, payload,                       // :255
            WmsConstants.MessageProcessType.ADVICE_HUB_AND_SPOKE_RECEIVED);
    } catch (IOException e) {
        LOG.error("Failed to serialize advice payload: {}", e.getMessage());
    }
}
```

**Why it's correct:**
- Method-level `@Transactional` (line 144) creates a tenant transaction. Every `repository.save(...)` runs inside it. On any throw in the loop (`unitloadService.createUnitload` collision, `transferUnitLoadToCarrier` constraint violation, `customerorderRepository.save` optimistic lock, etc.) the whole transaction rolls back.
- The OMS POST is registered via `omsNotificationService.sendAfterCommit(...)` (line 255). The actual HTTP call only fires from `TransactionSynchronization.afterCommit()` (see `OmsNotificationService.java:55-66`). On a rollback, `afterCommit()` never runs — OMS is never told.
- The audit `Message` row is written by `OmsNotificationService.doSend` via `messageService.createMessage(...)` (lines 72-78 / 80-85), which calls `MessageService.createServiceLog` annotated `@Transactional(propagation=REQUIRES_NEW)` (`MessageService.java:67`). So even if the outer tx rolled back, the audit row survives.

**Regression risk:** any future commit that:
- Removes the `@Transactional` line.
- Changes `value="tenantTransactionManager"` to `value="landlordTransactionManager"` (or any default `@Transactional` without value, which defaults to landlord TM in v2 since landlord is `@Primary`).
- Reintroduces an inline `httpRestService.post(...)` in the method body.
- Drops `rollbackFor = {BusinessException.class, FacadeException.class}` — `BusinessException` and `FacadeException` are checked exceptions (extending `Exception`), which Spring does NOT roll back on by default, so the explicit `rollbackFor` is mandatory for the rollback semantics this plan locks in.

…re-introduces the bug. The §10 verify script encodes one POSITIVE check per condition above plus a NEGATIVE check that `httpRestService.post(` does not appear anywhere in the file.

### Bug 2 (already fixed in v2, must stay fixed): missing `@Transactional` on `close`

**Code reference:** `src/main/java/net/aim_ai/wms/service/AdviceService.java:263-353`

```java
@Transactional(value = "tenantTransactionManager",
               rollbackFor = {BusinessException.class, FacadeException.class})       // :263
public void close(Advice advice, Principal principal) throws BusinessException {
    // … state guard, type guard …

    advice.setState(WmsConstants.AdviceState.FINISHED);                               // :290
    adviceRepository.saveAndFlush(advice);                                            // :291 — flush so the JPQL UPDATE below sees fresh state

    // Bulk update all positions to FINISHED (clearAutomatically evicts stale entities)
    advicepositionRepository.updateAdvicepositionToStateByAdviceId(                   // :294
        WmsConstants.AdviceState.FINISHED, advice.getId());

    // … build AdviceDto for OMS …

    try {
        String urlPath = syspropService.getSysvalue(SYSTEM_PROPERTY_WEBSERVICE_CLOSE_ADVICE_URL_KEY);
        ObjectMapper mapper = new ObjectMapper();
        mapper.setSerializationInclusion(JsonInclude.Include.NON_NULL);
        String payload = mapper.writeValueAsString(adviceDTO);
        omsNotificationService.sendAfterCommit(urlPath, payload,                       // :347
            WmsConstants.MessageProcessType.ADVICE_CLOSE);
    } catch (IOException e) {
        LOG.error("Failed to serialize advice payload: {}", e.getMessage());
    }
}
```

**Why it's correct:** same as Bug 1, with the additional safeguard that the per-position state change is a single atomic SQL UPDATE (line 294) rather than a per-iteration `repository.save(...)` loop. There is no mid-loop failure surface because there is no loop.

**Subtle nuance — `saveAndFlush` does not commit.** The `saveAndFlush(advice)` at line 291 forces Hibernate to flush the dirty `Advice` to the DB BEFORE the JPQL bulk UPDATE runs, so the bulk UPDATE sees the fresh `state=FINISHED` on the parent advice; without flushing, Hibernate's L1 cache would hold the dirty entity and the JPQL would race against unflushed state. **`saveAndFlush` does NOT commit the transaction.** The transaction commits only when the `@Transactional` proxy returns successfully. On any subsequent throw (e.g. JPQL UPDATE constraint violation), the entire transaction — including the flushed advice — rolls back.

**Regression risk:** same as Bug 1, plus a bulk-update-specific risk: someone "optimizing" the bulk UPDATE back into a per-position `save()` loop would re-introduce the v1-style mid-loop partial-commit surface. The integration test (Fix C) asserts whole-transaction rollback regardless of which mechanism is in place — so it remains valid even if the bulk UPDATE is changed back to a loop.

### Bug 3 (already fixed in v2, must stay fixed): missing `@Transactional` on `acceptTransferAdvice`

**Code reference:** `src/main/java/net/aim_ai/wms/service/AdviceService.java:355-416`

Identical shape to `close()`:
- `@Transactional(value="tenantTransactionManager"...)` at line 355 ✓.
- `advice.setState(FINISHED); adviceRepository.saveAndFlush(advice);` at lines 396-397.
- Bulk JPQL UPDATE for positions at line 400.
- `omsNotificationService.sendAfterCommit(... ADVICE_ACCEPT_TRANSFER)` at line 410.

**Regression risk:** same as Bug 2.

### Why the ticket's literal fix is REJECTED: do not add class-level `@Transactional`

The ticket suggests "Add @Transactional at the class level on AdviceService." In v2, this would be **harmful** without explicit `value = "tenantTransactionManager"`:

- v2 has TWO transaction managers (`landlordTransactionManager` and `tenantTransactionManager`); `landlordTransactionManager` is `@Primary` (per `v2/wms2-api/CLAUDE.md` "Dual Transaction Manager — every `@Transactional` on a tenant service method MUST specify `value = "tenantTransactionManager"`").
- A bare `@Transactional` at the class level would default to the landlord TM, silently disabling rollback, L1 cache, and connection sharing for all tenant operations in `AdviceService`.
- Even if the class-level annotation specified `value="tenantTransactionManager"` correctly, the existing per-method annotations would override it (Spring `@Transactional` resolution: most-specific wins) — making the class-level a no-op anyway.

Conclusion: keep the per-method annotations; do not add a class-level annotation. The verify script encodes a POSITIVE check that each of the three method annotations is exactly the canonical one.

### Self-invocation audit (ticket's "watch out for")

The ticket warns: "Verify call-graph for any `this.someMethod()` self-invocation: those bypass Spring's proxy and would still not be transactional."

Grep result: `grep -n "this\.acceptHubAndSpokeAdvice\|this\.close\|this\.acceptTransferAdvice" src/main/java/net/aim_ai/wms/service/AdviceService.java` returned **EMPTY**. No self-invocation. The Spring proxy correctly applies the `@Transactional` advice on every call.

### Caller audit (ticket's "watch out for")

The ticket warns: "If `AdviceService` is currently being called from a method that is itself `@Transactional`, adding class-level `@Transactional` is a no-op — but the OMS POST still needs to be moved to AFTER_COMMIT."

`AdviceService` is invoked exclusively from `controller/AdviceController.java` (lines 142, 171, 175, 202, 206, 259, 287, 326, 341). `AdviceController extends AdminController` — verified that `AdminController` is **not** `@Transactional` (no `@Transactional` annotation in `AdminController.java`; if it were, the grep would have surfaced it). Each `adviceService.<method>(...)` call therefore opens a fresh tenant transaction at the service-method boundary (AOP proxy enters here, no caller-tx to inherit).

Conclusion: no caller-side concern. The verify script does NOT need to encode a controller-side check.

---

## 3. Architecture Overview

```
┌────────────────────────────────────────────────────────────────────────┐
│ HTTP request from OMS (e.g. POST /v3/advice/{id}/closeInboundBol)     │
│     │                                                                  │
│     ▼                                                                  │
│ AdviceController (extends AdminController; not @Transactional)         │
│     │                                                                  │
│     ▼                                                                  │
│ AdviceService.<close | acceptTransferAdvice | acceptHubAndSpokeAdvice> │
│     ├─ @Transactional(value = "tenantTransactionManager",              │
│     │                  rollbackFor = {BusinessException.class,         │
│     │                                  FacadeException.class})         │
│     ▼                                                                  │
│ ┌─────────────────────────────────────────────────────────────────┐   │
│ │  Tenant transaction (open)                                       │   │
│ │   1. State guard, type guard                                     │   │
│ │   2. advice.setState(FINISHED); adviceRepository.saveAndFlush(…) │   │
│ │   3. (close / acceptTransferAdvice):                             │   │
│ │        advicepositionRepository                                  │   │
│ │          .updateAdvicepositionToStateByAdviceId(FINISHED, …)     │   │
│ │      (acceptHubAndSpokeAdvice):                                  │   │
│ │        for-each Adviceposition:                                  │   │
│ │          unitloadBusinessService.transferUnitLoadToCarrier(…)    │   │
│ │          advicePosition.setState(FINISHED); save(…)              │   │
│ │          customerorderRepository.save(co)                        │   │
│ │   4. omsNotificationService.sendAfterCommit(urlPath, payload, ⋯) │   │
│ │      └──> TransactionSynchronizationManager                      │   │
│ │           .registerSynchronization(new TS{ afterCommit() })      │   │
│ └─────────────────────────────────────────────────────────────────┘   │
│     │                                                                  │
│     ▼ commit() succeeds                                                │
│ ┌─────────────────────────────────────────────────────────────────┐   │
│ │  TransactionSynchronization.afterCommit() — same thread          │   │
│ │   - httpRestService.post(urlPath, payload)                       │   │
│ │   - messageService.createMessage(SENT/FAILED, …)                 │   │
│ │     (createServiceLog is REQUIRES_NEW → audit row survives       │   │
│ │      outer rollback if outer had thrown)                         │   │
│ └─────────────────────────────────────────────────────────────────┘   │
│     │                                                                  │
│     ▼                                                                  │
│ HTTP 2xx returned to OMS                                               │
└────────────────────────────────────────────────────────────────────────┘

If the @Transactional method THROWS at any step:
- afterCompletion(STATUS_ROLLED_BACK) fires instead of afterCommit
- httpRestService.post is NEVER invoked
- OMS is NEVER told the advice finished
- Adviceposition rows revert to their pre-method state
- Advice reverts to its pre-method state
- → no partial commit, no cross-system drift
```

**Key files:**

| File | Lines | Role |
|---|---|---|
| `service/AdviceService.java` | `:144-261` (`acceptHubAndSpokeAdvice`); `:263-353` (`close`); `:355-416` (`acceptTransferAdvice`) | The three methods this plan regression-guards. |
| `service/OmsNotificationService.java` | `:1-90` (whole file) | The deferred-send helper. `sendAfterCommit(urlPath, payload, processType)` registers the post-commit synchronization; `doSend(...)` performs the actual HTTP POST + audit row write. Already in place since SBDEV-2214. |
| `service/MessageService.java` | `:67` (`createServiceLog @Transactional REQUIRES_NEW`); `:59-65` (`createMessage` overloads) | Audit-row writer. The REQUIRES_NEW propagation is what makes the FAILED audit row survive an outer rollback. |
| `repo/jpa/AdvicepositionRepository.java` | `:30-32` (`updateAdvicepositionToStateByAdviceId`) | The bulk JPQL UPDATE used by `close` and `acceptTransferAdvice`. `clearAutomatically=true` to evict stale L1-cache entries. |
| `controller/AdviceController.java` | `:142, 171, 175, 202, 206, 259, 287, 326, 341` | The only caller. Not @Transactional. |
| `service/WmsConstants.java` | `:448, 451, 452` (`ADVICE_CLOSE`, `ADVICE_HUB_AND_SPOKE_RECEIVED`, `ADVICE_ACCEPT_TRANSFER`); `:880-885` (URL syspropies) | Process-type constants and OMS-URL keys consumed by the three methods. |

---

## 4. (Optional) The Regression Chain

Not applicable as a v1→v2 regression. The relevant v2 commit chain that put each fix in place:

| Commit | Date | What it did |
|---|---|---|
| `58ad0f3 fix: specify tenantTransactionManager on all 44 @Transactional annotations` | (per `git log`) | Established the rule "every tenant-service `@Transactional` must specify `value="tenantTransactionManager"`" |
| `6ba599e optimize AdviceService: bulk JPQL updates, batch DTO pre-fetching in close() and acceptTransferAdvice()` | (per `git log`) | Replaced the v1 per-position save loop with bulk JPQL UPDATE in `close()` and `acceptTransferAdvice()` — structurally eliminated the mid-loop failure surface for these two methods. |
| `730aa35 fix: flush Advice state before bulk JPQL UPDATE clears persistence context` | (per `git log`) | Added the `saveAndFlush` (line 291, 397) before the bulk UPDATE. |
| `41cf1f3 fix: defer OMS HTTP notifications to after transaction commit` | (per `git log`) | Introduced `OmsNotificationService.sendAfterCommit(...)` and migrated AdviceService's three OMS POST sites (lines 255, 347, 410) — the SBDEV-2214 sweep that incidentally fixed SBDEV-2215. |

This plan locks in those four commits. A revert of any one of them should be caught by at least one verify-script check.

---

## 5. Fix Design

This plan ships **one new piece of code** (the integration test class) and **zero modifications to production code**. The §0 §1 and §2 sections enumerate the regression-guards.

### Fix A: regression-guard the three @Transactional method annotations (no code change)

For each of `acceptHubAndSpokeAdvice` (line 144), `close` (line 263), `acceptTransferAdvice` (line 355): the verify script asserts the annotation is **exactly** the canonical form:

```
@Transactional(value = "tenantTransactionManager", rollbackFor = {BusinessException.class, FacadeException.class})
```

**Encoded as:**
- POSITIVE: per-method multi-line regex matching the annotation immediately preceding the method signature.
- NEGATIVE: file-wide grep that no `@Transactional` line is missing the `tenantTransactionManager` qualifier.

### Fix B: regression-guard the three `omsNotificationService.sendAfterCommit(...)` calls (no code change)

For each of the three methods, the verify script asserts:
- POSITIVE: the call site contains `omsNotificationService.sendAfterCommit(` followed by the right `MessageProcessType` constant (`ADVICE_HUB_AND_SPOKE_RECEIVED`, `ADVICE_CLOSE`, `ADVICE_ACCEPT_TRANSFER`) within ~3 lines (multi-line regex).
- NEGATIVE: `httpRestService.post(` does NOT appear anywhere in `AdviceService.java`. (Top-level firewall — catches any accidental reintroduction in any of the three methods or in any future method.)

### Fix C: NEW integration tests asserting whole-tx rollback when an exception fires mid-method

The ticket's acceptance criterion mandates: *"Integration test: simulate exception after position #5 of 10 is saved; confirm rollback to original state and no OMS POST."* This test does not exist today.

**Test infrastructure — `BaseRollbackIntegrationTest` (new base class):**

`BaseIntegrationTest` is annotated `@Transactional` at the class level. Spring's `TransactionalTestExecutionListener` wraps every test method in an outer transaction and rolls it back at the end — regardless of what production code does inside. This makes rollback-assertion tests unreliable: the assertions would pass even if `@Transactional` were removed from the production method, because the outer harness always rolls back. Using `BaseIntegrationTest` for these tests would produce a false-negative regression guard.

Create `src/test/java/net/aim_ai/wms/common/base/BaseRollbackIntegrationTest.java` with identical `@SpringBootTest` / `@ActiveProfiles("integration")` / `@Import(TestDatabaseConfig.class)` setup as `BaseIntegrationTest` — including the `@MockitoBean TenantHealthService` and `@MockitoBean EndpointHealthCheck` overrides (required for the Spring context to load under the `integration` profile) — but **without `@Transactional`**. Each test method is responsible for its own seed (in `@BeforeEach`) and cleanup (in `@AfterEach`). No automatic rollback by the harness — the production code's transaction commits or rolls back for real, and the test reads the resulting DB state.

**TenantContext — not required:** `TestDatabaseConfig` mocks `tenantDynamicRoutingDataSource` to return connections from the single H2 landlord DataSource. Tenant routing is bypassed; no `TenantContext.set(...)` is needed.

**`@MockitoSpyBean` over `@MockitoBean`:** Beans used for throw injection must use `@MockitoSpyBean` (Spring Boot 3.x: `org.springframework.test.context.bean.override.mockito.MockitoSpyBean`). This preserves the real bean's behavior and only overrides the stubbed method. Using `@MockitoBean` (full mock) for a service or repository also used for seed data would break seed calls.

**`@Cacheable` on `SyspropService.getSysvalue` — disable cache in `BaseRollbackIntegrationTest`:**
`SyspropService.getSysvalue(String key)` is annotated `@Cacheable(value = "sysprops", key = "... + ':' + #key")`. If the `sysprops` Caffeine cache has a hit for the test tenant's key when `doThrow(...).when(syspropServiceSpy).getSysvalue(KEY)` is stubbed, Spring's AOP cache interceptor returns the cached value before invoking the spy — the stub never fires and the test passes for the wrong reason.

Fix: add `@TestPropertySource(properties = "spring.cache.type=none")` to `BaseRollbackIntegrationTest`. This disables the Caffeine cache manager for all tests in the class, making every `@Cacheable` call fall through to the real method (and spy stub). This is the same mechanism used to disable caches in contract tests; it causes a separate `ApplicationContext` to be created for the rollback test class (acceptable — this base class is standalone).

**`@AfterEach` cleanup strategy:** Because there is no outer-harness rollback, each test commits real rows to H2. `@AfterEach` must delete them in FK-safe order. Recommended approach:
```java
@AfterEach
void cleanup() {
    advicepositionRepository.deleteAll();
    adviceRepository.deleteAll();
    clientRepository.deleteAll();
    // delete any Customerorder / Unitload rows created by acceptHubAndSpokeAdvice (Fix C.1)
}
```
Alternatively, use `@Sql(scripts = "classpath:scripts/cleanup-advice.sql", executionPhase = AFTER_TEST_METHOD)`. Either approach prevents row leakage into sibling tests (`AdviceServiceIntegrationTest` shares the same H2 instance).

Create `src/test/java/net/aim_ai/wms/integration/service/AdviceServiceRollbackIntegrationTest.java` extending `BaseRollbackIntegrationTest`. Three test methods:

**Fix C.1 — `acceptHubAndSpokeAdvice_shouldRollbackAllPositions_andNotPostToOms_whenMidLoopExceptionThrown`** (the ticket-mandated test)

```java
@MockitoSpyBean
private UnitloadBusinessService unitloadBusinessServiceSpy;

@MockitoBean
private HttpRestService httpRestService;  // full mock — never called in test scope

@Test
@DisplayName("acceptHubAndSpokeAdvice — mid-loop BusinessException rolls back advice + all positions; no OMS POST")
void acceptHubAndSpokeAdvice_shouldRollbackAllPositions_andNotPostToOms_whenMidLoopExceptionThrown()
        throws BusinessException, FacadeException {
    // Arrange — seed 1 Advice (HUB_AND_SPOKE, OPEN) + 10 Adviceposition (OPEN)
    Advice advice = seedHubAndSpokeAdvice(/* positions */ 10);

    // Throw BusinessException (NOT RuntimeException) on the 6th transferUnitLoadToCarrier call.
    // WHY checked exception: Spring does NOT roll back checked exceptions by default.
    // Without rollbackFor={BusinessException.class, FacadeException.class} on the @Transactional
    // annotation, this throw would NOT trigger a rollback. Using BusinessException specifically
    // exercises the rollbackFor clause this plan regression-guards. A RuntimeException test
    // would pass even if rollbackFor were removed.
    AtomicInteger calls = new AtomicInteger();
    doAnswer(inv -> {
        if (calls.incrementAndGet() == 6) {
            throw new BusinessException("simulated mid-loop failure after position #5");
        }
        return inv.callRealMethod();
    }).when(unitloadBusinessServiceSpy).transferUnitLoadToCarrier(any(), any(), anyString(), anyString(), any());

    Location targetLocation = locationRepository.findByName("INBOUND-1").orElseThrow();

    // Act — BusinessException propagates out of the @Transactional proxy, triggering rollback
    assertThatThrownBy(() -> adviceService.acceptHubAndSpokeAdvice(advice, targetLocation))
        .isInstanceOf(BusinessException.class)
        .hasMessageContaining("simulated mid-loop failure after position #5");

    // Assert — DB state unchanged (production tx rolled back for real; no outer harness rollback)
    Advice reloaded = adviceRepository.findById(advice.getId()).orElseThrow();
    assertThat(reloaded.getState()).isEqualTo(WmsConstants.AdviceState.OPEN);

    List<Adviceposition> positions = advicepositionRepository.findByAdviceId(advice.getId());
    assertThat(positions).hasSize(10);
    assertThat(positions).allMatch(p -> p.getState().equals(WmsConstants.AdviceState.OPEN));

    // Assert — no OMS POST (afterCommit never fires on rollback).
    // Use verify(never()) NOT doThrow(AssertionError): throwing inside OmsNotificationService's
    // catch block (line 87) would be swallowed into a FAILED Message row, masking the bug.
    verify(httpRestService, never()).post(anyString(), anyString());
}
```

**Fix C.2 — `close_shouldRollbackAdviceAndPositions_andNotPostToOms_whenLaterStepThrows`**

```java
@MockitoSpyBean
private SyspropService syspropServiceSpy;

@Test
@DisplayName("close — BusinessException after bulk UPDATE rolls back advice + positions; no OMS POST")
void close_shouldRollbackAdviceAndPositions_andNotPostToOms_whenLaterStepThrows()
        throws BusinessException {
    // Arrange
    Advice advice = seedRegularAdvice(/* positions */ 5);
    Principal principal = () -> "test-user";

    // Inject throw via SyspropService.getSysvalue (line 343 of close(), after bulk UPDATE at 294).
    // WHY this injection point: (a) it is inside the @Transactional boundary — throws here still
    // roll back the tx; (b) it fires BEFORE omsNotificationService.sendAfterCommit() at line 347,
    // so the afterCommit listener is never registered; (c) syspropServiceSpy is a spy — real
    // behaviour preserved for all other getSysvalue calls (seed path, state-guard at line 268, etc).
    // WHY BusinessException: exercises rollbackFor clause (see Fix C.1 rationale).
    doThrow(new BusinessException("simulated sysprop lookup failure"))
        .when(syspropServiceSpy).getSysvalue(WmsConstants.SYSTEM_PROPERTY_WEBSERVICE_CLOSE_ADVICE_URL_KEY);

    // Act
    assertThatThrownBy(() -> adviceService.close(advice, principal))
        .isInstanceOf(BusinessException.class);

    // Assert — full rollback: advice back to OPEN, all positions back to OPEN
    Advice reloaded = adviceRepository.findById(advice.getId()).orElseThrow();
    assertThat(reloaded.getState()).isEqualTo(WmsConstants.AdviceState.OPEN);
    List<Adviceposition> positions = advicepositionRepository.findByAdviceId(advice.getId());
    assertThat(positions).allMatch(p -> p.getState().equals(WmsConstants.AdviceState.OPEN));
    verify(httpRestService, never()).post(anyString(), anyString());
}
```

**Fix C.3 — `acceptTransferAdvice_shouldRollbackAdviceAndPositions_andNotPostToOms_whenLaterStepThrows`**

Identical pattern to Fix C.2: stub `syspropServiceSpy.getSysvalue(WmsConstants.SYSTEM_PROPERTY_WEBSERVICE_ACCEPT_TRANSFER_URL_KEY)` to throw `BusinessException`. This call occurs after the bulk JPQL UPDATE (line 400) and before `omsNotificationService.sendAfterCommit(...)` at line 410 — same throw-placement logic as Fix C.2.

```java
@Test
@DisplayName("acceptTransferAdvice — BusinessException after bulk UPDATE rolls back; no OMS POST")
void acceptTransferAdvice_shouldRollbackAdviceAndPositions_andNotPostToOms_whenLaterStepThrows()
        throws BusinessException, FacadeException {
    // Arrange
    Advice advice = seedTransferAdvice(/* positions */ 5);

    doThrow(new BusinessException("simulated sysprop lookup failure"))
        .when(syspropServiceSpy).getSysvalue(WmsConstants.SYSTEM_PROPERTY_WEBSERVICE_ACCEPT_TRANSFER_URL_KEY);

    // Act
    assertThatThrownBy(() -> adviceService.acceptTransferAdvice(advice))
        .isInstanceOf(BusinessException.class);

    // Assert
    Advice reloaded = adviceRepository.findById(advice.getId()).orElseThrow();
    assertThat(reloaded.getState()).isEqualTo(WmsConstants.AdviceState.OPEN);
    List<Adviceposition> positions = advicepositionRepository.findByAdviceId(advice.getId());
    assertThat(positions).allMatch(p -> p.getState().equals(WmsConstants.AdviceState.OPEN));
    verify(httpRestService, never()).post(anyString(), anyString());
}
```

#### Scope of the "no OMS POST" assertions

For Fix C.2 and C.3, the throw injection point (`getSysvalue` at line 343 / line 406) fires **before** `omsNotificationService.sendAfterCommit(...)` is called (line 347 / line 410). This means `verify(httpRestService, never()).post(...)` is vacuously true in C.2/C.3 — the afterCommit listener was never registered, so there was no mechanism to POST regardless of whether `httpRestService` is mocked. These tests do not prove "post-commit deferral works when the listener IS registered."

**What they do prove:** whole-transaction rollback (both the `saveAndFlush` and the bulk JPQL UPDATE are rolled back when a `BusinessException` crosses the `@Transactional` proxy). That is the primary property this plan regression-guards.

**What covers the "OMS POST is deferred, not inline" property:** the NEGATIVE regression-guard in §14 — `httpRestService.post(` must not appear anywhere in `AdviceService.java`. This fires if a future commit reintroduces a synchronous `httpRestService.post` call anywhere in the three methods (even after line 347), covering the realistic regression vector.

**Strengthening (optional, follow-up):** a dedicated happy-path test `acceptHubAndSpokeAdvice_whenSucceeds_postsToOmsAfterCommit` — which asserts `verify(httpRestService).post(...)` is called exactly once after a successful `acceptHubAndSpokeAdvice` — would prove the deferral property positively. That test is outside the scope of this regression-guard plan (it tests the happy path, not the rollback path) and is best added to `AdviceServiceIntegrationTest` in a follow-up.

#### Why these tests and not alternatives

| Alternative | Why rejected |
|---|---|
| Unit tests with mocked repositories — assert only the call sequence | Cannot assert real DB rollback; the @Transactional behavior is invisible to a pure-mock test. |
| Unit test with `@Transactional(propagation=NEVER)` to disable tx — assert partial state | Defeats the whole point — we want to assert that WITH @Transactional active, partial state cannot occur. |
| End-to-end test against a real OMS server | OMS is an external system; mocking `httpRestService` at the spy level is sufficient and reliable. |
| Single test covering all three methods | Each method has a different mid-method failure surface; one test per method is clearer for failure-mode forensics. |
| Extending `BaseIntegrationTest` | `BaseIntegrationTest` is `@Transactional` — the outer harness always rolls back. Tests would pass even if `@Transactional` were removed from production code (false-negative regression guard). |
| Throwing `RuntimeException` in Fix C.1 | Spring rolls back unchecked exceptions by default — the test would pass even without `rollbackFor={BusinessException.class, ...}`. `BusinessException` (checked) specifically exercises the `rollbackFor` clause being guarded. |
| Spying on `clientRepository.findById` for Fix C.2 | `@MockitoBean ClientRepository` replaces the whole bean, breaking seed calls. `@MockitoSpyBean SyspropService` is non-invasive: other `getSysvalue` calls (used during seeding and state guards) continue to use real behavior. |

### Verification of Bugs 1, 2, 3 (no code change — only verify-script regression-guards)

Encoded as the §10 verify-script POSITIVE/NEGATIVE checks (see Acceptance section).

---

## 6. File Change Summary

| File | Change Type | Description |
|---|---|---|
| `src/main/java/net/aim_ai/wms/service/AdviceService.java` | **No change** (regression-guarded only) | Verified by §14 — POSITIVE checks for the three @Transactional annotations + the three `sendAfterCommit` calls; NEGATIVE check that `httpRestService.post(` is absent file-wide. |
| `src/test/java/net/aim_ai/wms/common/base/BaseRollbackIntegrationTest.java` | **NEW** (base class) | Same `@SpringBootTest` / `@ActiveProfiles("integration")` / `@Import(TestDatabaseConfig.class)` setup as `BaseIntegrationTest` but **without `@Transactional`**. Adds `@TestPropertySource(properties = "spring.cache.type=none")` to disable Caffeine caching so `@MockitoSpyBean` stubs on `@Cacheable` methods (e.g. `SyspropService.getSysvalue`) always fire. Enables rollback-assertion tests where the production tx commits/rolls back for real. |
| `src/test/java/net/aim_ai/wms/integration/service/AdviceServiceRollbackIntegrationTest.java` | **NEW** (H2 integration test) | The three rollback-assertion tests (Fix C.1 / C.2 / C.3). Extends `BaseRollbackIntegrationTest`. Uses `@MockitoSpyBean` for throw injection; `@BeforeEach` seed + `@AfterEach` cleanup (no automatic harness rollback). |
| `sbdocs/9-System/scripts/verify-SBDEV-2215-adviceservice-no-transaction-wrapping.sh` | **NEW** | The §14 acceptance script. |

No DB migration. No new sysprop. No new endpoint. No frontend change. No production-code modification.

---

## 7. Implementation Steps

### 7.1 Prerequisites

| # | Prerequisite | Required value / action | Owner | Notes |
|---|---|---|---|---|
| 1 | Database state | None — schema unchanged | — | The integration test seeds via `@BeforeEach` helpers in H2 and cleans up in `@AfterEach` (no outer-harness rollback). |
| 2 | Feature flags / system properties | The three OMS URL syspropies must already exist per tenant: `WEBSERVICE_CLOSE_ADVICE`, `WEBSERVICE_ACCEPT_TRANSFER`, `WEBSERVICE_ACCEPT_HUB_AND_SPOKE` | Tenant DBA (verify only) | Same syspropies used today; defaults documented in `WmsConstants.java:880-885`. |
| 3 | Config / env changes | None | — | No `application.properties` touch. |
| 4 | Deploy-order dependencies | None | — | This plan adds only a test class. OMS endpoint contracts unchanged. |
| 5 | Data migration | None | — | No backfill. Existing `Message` audit rows remain valid. |
| 6 | External systems | OMS receives the same payload at the same URL with the same headers | OMS team | No change required. |
| 7 | Access / permissions | None — H2 in-memory; no Docker socket required | — | `BaseRollbackIntegrationTest` uses the same H2-backed `TestDatabaseConfig` as `BaseIntegrationTest`; no additional CI provisioning needed. |
| 8 | Monitoring / alerts | None new | — | Optional follow-up: add Micrometer counter on `OmsNotificationService.doSend` failure path (already documented as Phase 6 of SBDEV-2214). |

### 7.2 Implementation phases

The phases are ordered so that **at no point is the WMS in a less-safe state than it is today.** This plan adds tests + a verify script; production code is untouched.

- [ ] **Phase 0 — Baseline.** Run `bash sbdocs/9-System/scripts/verify-SBDEV-2215-adviceservice-no-transaction-wrapping.sh`. Capture the FAIL count. Should report failures only on (a) `BaseRollbackIntegrationTest.java` existence check, (b) `AdviceServiceRollbackIntegrationTest.java` existence check, (c) the three new test-method-name checks. All POSITIVE / NEGATIVE source-grep checks on production code should already PASS today.
- [ ] **Phase 1 — wms-tdd-gate.** Hand this plan to the `wms-tdd-gate` skill. The skill first creates `BaseRollbackIntegrationTest.java` (no `@Transactional`), then writes `AdviceServiceRollbackIntegrationTest.java` extending it with the three test methods per Fix C.1/C.2/C.3 — using `@MockitoSpyBean` for throw injection, `BusinessException` as the thrown type, and `SyspropService.getSysvalue(...)` as the injection point for Fix C.2/C.3. Pause for human approval.

  **Edge case for `wms-tdd-gate` to handle:** because v2's production code is already correct, the canonical "red test" expectation is inverted — the tests will PASS green. The TDD-gate skill must either:
  - accept the tests as forward-regression-guards (mark green = "correct-now, fail-if-reverted"), OR
  - on a scratch branch temporarily remove one `@Transactional` annotation to confirm the test turns red — then restore and ship the test against the correct production code.

- [ ] **Phase 2 — Implement integration test.** With approval, `wms-tdd-gate` (or follow-up executor) completes the full test bodies including `@BeforeEach` seed helpers and `@AfterEach` cleanup. Run `mvn verify -Dtest=AdviceServiceRollbackIntegrationTest`. Expect 3 PASS.
- [ ] **Phase 3 — Re-run full integration suite.** `mvn verify` end-to-end. Confirm no other tests regressed.
- [ ] **Phase 4 — Final verify.** `bash sbdocs/9-System/scripts/verify-SBDEV-2215-adviceservice-no-transaction-wrapping.sh`. **Required result: `Result: N pass, 0 fail`.**
- [ ] **Phase 5 — Manual smoke (per §8.4).** Drive each of the four advice flows (regular receive, return, transfer, hub-and-spoke) in staging.
- [ ] **Phase 6 — DB-fingerprint check.** Run the §1 SQL query on a tenant DB; record pre-/post-fix row counts in §11.
- [ ] **Phase 7 — Plan archival.** After sign-off, run `archive-plan` skill to move this plan to `sbdocs/4-Archieves/wms2/plan/`.

---

## 8. Testing Plan

### 8.1 Unit tests

No new unit tests required — production code is not modified, and all three target methods already have unit-test coverage in `src/test/java/net/aim_ai/wms/unit/service/AdviceServiceUnitTest.java` and `AdviceServiceH2Test.java`. The verify script invokes `mvn test -Dtest=AdviceServiceUnitTest` to confirm those tests still pass.

If the implementer chooses to add unit-test-level assertions (Mockito spies on `omsNotificationService.sendAfterCommit`), the recommended additions are:

- `acceptHubAndSpokeAdvice_shouldCallSendAfterCommit_withAdviceHubAndSpokeReceived` — verify mock invocation count = 1 with the correct process-type constant.
- `close_shouldCallSendAfterCommit_withAdviceClose` — same pattern.
- `acceptTransferAdvice_shouldCallSendAfterCommit_withAdviceAcceptTransfer` — same pattern.

These are optional; the integration test (Fix C) is the authoritative coverage.

### 8.2 Integration tests (NEW — Fix C)

#### `src/test/java/net/aim_ai/wms/integration/service/AdviceServiceRollbackIntegrationTest.java` (extends `BaseRollbackIntegrationTest` / H2)

- `acceptHubAndSpokeAdvice_shouldRollbackAllPositions_andNotPostToOms_whenMidLoopExceptionThrown` — **the ticket-mandated test** (10 positions; `@MockitoSpyBean UnitloadBusinessService` throws `BusinessException` on 6th `transferUnitLoadToCarrier` call; assert advice + all 10 positions remain OPEN; `verify(httpRestService, never()).post(...)`).
- `close_shouldRollbackAdviceAndPositions_andNotPostToOms_whenLaterStepThrows` — drive `close()`; `@MockitoSpyBean SyspropService` throws `BusinessException` on `getSysvalue(SYSTEM_PROPERTY_WEBSERVICE_CLOSE_ADVICE_URL_KEY)` (line 343, after bulk UPDATE at 294, before `sendAfterCommit` at 347); assert advice OPEN, positions OPEN, no OMS POST.
- `acceptTransferAdvice_shouldRollbackAdviceAndPositions_andNotPostToOms_whenLaterStepThrows` — same pattern; stub `getSysvalue(SYSTEM_PROPERTY_WEBSERVICE_ACCEPT_TRANSFER_URL_KEY)` (after bulk UPDATE at 400, before `sendAfterCommit` at 410); assert rollback + no OMS POST.

### 8.3 Regression / contract tests

- `mvn verify` — full test suite must remain green.
- All existing `AdviceServiceUnitTest`, `AdviceServiceH2Test`, `AdviceServiceIntegrationTest`, `OmsNotificationServiceUnitTest` must remain green. After this plan their assertions don't change at all (production code untouched).

### 8.4 Manual test plan

| Scenario | Environment | Steps | Expected Result | Pass/Fail |
|---|---|---|---|---|
| Happy-path regular receive | staging | 1. Create an `Advice` of type `REGULAR` in OMS. 2. Receive all positions in WMS web UI. 3. Click "Close inbound BOL". | OMS receives `ADVICE_CLOSE` notification. WMS shows advice as FINISHED. `Message` row created with `process=ADVICE_CLOSE, status=SENT`. All Adviceposition rows FINISHED. | |
| Happy-path return | staging | 1. Create an `Advice` of type `RETURN`. 2. Receive positions. 3. Click "Close inbound BOL". | Same as above (return type follows the close path; same OMS notification). | |
| Happy-path transfer | staging | 1. Create an `Advice` of type `TRANSFER`. 2. Receive positions. 3. Click "Accept transfer BOL". | OMS receives `ADVICE_ACCEPT_TRANSFER`. WMS shows advice + positions FINISHED. `Message(process=ADVICE_ACCEPT_TRANSFER, status=SENT)`. | |
| Happy-path hub-and-spoke | staging | 1. Create an `Advice` of type `HUB_AND_SPOKE` with N positions. 2. Click "Accept hub-and-spoke". | OMS receives `ADVICE_HUB_AND_SPOKE_RECEIVED`. WMS creates N parcels + N customer orders, marks all positions FINISHED, advice FINISHED. `Message(process=ADVICE_HUB_AND_SPOKE_RECEIVED, status=SENT)`. | |
| Forced rollback during hub-and-spoke | staging | 1. Find a tenant where one Adviceposition's `parcellabel` is set to a value that already exists as a Unitload labelid (will trigger the BusinessException at `AdviceService.java:181-184`). 2. Click "Accept hub-and-spoke". | WMS shows error response. Advice + all positions stay in `OPEN` state (rollback). OMS does NOT receive `ADVICE_HUB_AND_SPOKE_RECEIVED`. No `Message(process=ADVICE_HUB_AND_SPOKE_RECEIVED)` row written. | |
| Mid-loop forced rollback during hub-and-spoke | staging (or harder — exercise via integration test only) | (best exercised via `AdviceServiceRollbackIntegrationTest.acceptHubAndSpokeAdvice_shouldRollbackAllPositions_…`) | n/a in manual test — covered by integration test. | n/a |
| SQL-level partial-commit fingerprint | staging tenant DB | psql: run the §1 db-verification query | Returns 0 rows for advices closed AFTER commit `41cf1f3` (the deployed-fix date). May return rows from before that date (historical drift); separate operations ticket to reconcile those. | |

### 8.5 Test execution (fill in after running)

| Command | Result | Pass / Fail / Skipped counts |
|---------|--------|------------------------------|
| `mvn test -Dtest=AdviceServiceUnitTest` | | |
| `mvn test -Dtest=AdviceServiceH2Test` | | |
| `mvn verify -Dtest=AdviceServiceIntegrationTest` | | |
| `mvn verify -Dtest=AdviceServiceRollbackIntegrationTest` | | (target: 3 pass, 0 fail) |
| `mvn test -Dtest=OmsNotificationServiceUnitTest` | | |
| `mvn verify` (full) | | |
| `bash sbdocs/9-System/scripts/verify-SBDEV-2215-adviceservice-no-transaction-wrapping.sh` | | (target: `0 fail`) |

### 8.6 Deliberately-skipped coverage

| What | Why |
|---|---|
| End-to-end test against a real OMS server | OMS is external; coverage via the `Message` row contract test + Mockito spy on `httpRestService` is sufficient. |
| Unit-test-level assertions on `sendAfterCommit` invocation | Optional; the integration test is the authoritative coverage. The implementer may add them per §8.1. |
| Mid-loop test for `close()` and `acceptTransferAdvice()` (vs. our chosen "later-step throws" tests) | Both methods use bulk JPQL UPDATE — there is no loop to fail mid-iteration. The "later-step throws" variant covers the same property (whole-tx rollback). |
| Re-test of the ticket's "four advice flows: regular receive, return, transfer, hub-and-spoke" via automated tests | Manual test §8.4 covers it; v2's existing regression-test suite indirectly covers all four via `AdviceServiceIntegrationTest`. |

---

## 9. Horizontal Scalability Validation (v2 plans — MANDATORY)

| # | Concern | Does this change... | Verdict | Mitigation / rationale |
|---|---|---|---|---|
| 1 | **In-JVM state** | Introduce per-replica state? | **No** | No new caches, ConcurrentHashMaps, statics, or ThreadLocals. The `TransactionSynchronization` instance is per-tx, lives only on the request thread until commit (existing behavior, unchanged). |
| 2 | **Connection pool math** | Change DB connection usage? | **No** | Production code unchanged. The integration test uses H2 in-memory — runs only in CI, not against production pools. |
| 3 | **Scheduled jobs** | Add or modify `@Scheduled`? | **No** | No cron change. |
| 4 | **Long transactions** | Hold a tx across external I/O? | **No** | The opposite — the existing `omsNotificationService.sendAfterCommit(...)` pattern already moves OMS HTTP outside the tx. This plan locks that in. |
| 5 | **Request affinity** | Assume same replica for follow-up? | **No** | `afterCommit` runs on the same thread that committed; no cross-replica assumption. |
| 6 | **Retry / idempotency** | Rely on single-execution semantics? | **Yes (existing constraint, unchanged by this plan)** | If a replica crashes between `commit()` and `afterCommit`, OMS receives no notification AND no `Message(SENT)` row exists. Recovery is via the existing manual-reconciliation flow. **No regression** vs today (same risk exists in all current `OmsNotificationService` users). |
| 7 | **Tenant context** | Use `TenantContext` across async boundaries? | **Yes** | `TransactionSynchronization.afterCommit` runs synchronously on the thread that called `commit()`. The `TenantFilter` has not yet cleared the request's `TenantContext` (filter clears in a `try { … } finally { TenantContext.clear(); }` AFTER the request completes). So tenant context is intact. **Evidence:** existing `AdviceService.acceptHubAndSpoke/close/acceptTransfer` users (in production since commit `41cf1f3`) have not reported tenant-context issues across afterCommit, and `MessageService.createServiceLog` (called inside the deferred path) reads tenant-bound `userRepository.findByName(...)` successfully. Same evidence as SBDEV-2214 §9 row 7. |
| 8 | **Distributed lock correctness** | Add or rely on locks across replicas? | **No** | Lock semantics unchanged. |
| 9 | **Cache invalidation** | Write to a cached entity? | **No** | `Advice` and `Adviceposition` are not in `@Cacheable` paths per `wms2-caching-strategy.md`. (`Itemdata` IS cached and IS read in `close()` line 325 `itemdataRepository.findAllById(itemdataIds)` — but it is read-only, no write — so no `@CacheEvict` is needed.) |
| 10 | **External notifications (OMS, etc.)** | Send HTTP outside a transaction? | **Yes — this is the entire point** | The OMS POST is registered in-tx but executed after-commit. Audit row creation uses REQUIRES_NEW (`MessageService.createServiceLog`) so it survives outer rollback. Already-shipped pattern; this plan locks it in. |

### Evidence

| Concern # | What was done / verified | File:line or test reference |
|---|---|---|
| 6 | Retry/idempotency — risk inherited from existing OmsNotificationService design; no regression added by this plan | `service/OmsNotificationService.java:69-89` |
| 7 | Tenant context preserved across afterCommit (documented in arch doc) | `sbdocs/3-Resources/architecture/wms2-transaction-osiv-boundary-map.md` §6 |
| 10 | Audit-row creation uses REQUIRES_NEW so it survives outer rollback | `service/MessageService.java:67` |
| 4, 10 | Three deferred-OMS-POST sites in AdviceService, all in scope | `service/AdviceService.java:255, 347, 410` |

---

## 10. v2-only constraint checklist

| # | Constraint | What to check | Verdict |
|---|---|---|---|
| 1 | **OSIV disabled** | `spring.jpa.open-in-view=false` enforced; no new lazy-load paths added | **N/A** (production code unchanged; the integration test runs inside its own `@Transactional` test boundaries, no new lazy-load paths) |
| 2 | **Transaction manager** | `@Transactional(value="tenantTransactionManager"…)` on tenant-scoped writes | **Yes — three POSITIVE checks in §10 verify script** confirm each method's annotation has the canonical form. Class-level annotation is **explicitly rejected** in §3 because a bare `@Transactional` would default to landlord TM. |
| 3 | **`@Transactional(readOnly=true)`** | Read-only methods declared | **No — out-of-scope.** `AdviceService.getAdviceDetails`, `getExistingPallets`, `exportInboundNotice` could optionally be `readOnly=true`, but they are not on the ticket's failure path and adding `readOnly=true` is outside the scope of this regression-guard plan. |
| 4 | **Caffeine cache invalidation** | `@CacheEvict` / `@CachePut` for cached entity writes | **N/A** (Advice and Adviceposition are not cached; Itemdata is read-only here) |
| 5 | **Jakarta namespace** | All new imports use `jakarta.*` | **Yes** — the new integration test class will use `jakarta.persistence.*` if any persistence import is needed (it likely isn't — Mockito imports + JUnit + AssertJ + Spring test). |
| 6 | **H2-compatible test SQL** | Native PG syntax replaced | **N/A** — the integration test is H2-based (same as the rest of the suite). No native SQL added. |
| 7 | **`BaseControllerTest`** | New/modified controller endpoints | **N/A** (no controller change) |
| 8 | **Micrometer metrics** | High-frequency path covered by an existing or new metric | **No — out-of-scope.** Optional follow-up: add `oms_notification_failed_total{processType=…}` counter inside `OmsNotificationService.doSend`'s catch block (already documented as Phase 6 of SBDEV-2214). |

---

## 11. Notes — Resolved decisions (Pre-draft Layer 3, defaults)

The user requested "just draft, use reasonable defaults" — these are the defaults this draft chose. The reviewer can override any of them in the next revision.

| # | Question | Default chosen by this draft | Override box |
|---|---|---|---|
| 1 | **Scope** — v1, v2, or both? | **v2 only** for this plan. The ticket is dual-tagged (`wmsv1`, `wmsv2`). v1 paired plan deferred — the v1 codebase still has the bug as-described (ticket cites v1 line numbers as the live failure), so a separate v1 plan is required. v1 plan filename should be `SBDEV-2215-adviceservice-no-transaction-wrapping.md` in `sbdocs/1-Projects/wms1/plan/` (same base name to pair with this v2 plan). | ☐ revise |
| 2 | **Behavior change** | **None in the happy path.** In the rare-failure path (mid-loop exception in `acceptHubAndSpokeAdvice` or mid-method exception in `close`/`acceptTransferAdvice`), the receive/transfer/hub-and-spoke flow now **fails cleanly** without partial commit. End-user-visible delta is none; OMS-visible delta is "no longer notified on a rolled-back attempt" (same correctness improvement as SBDEV-2214). | ☐ revise |
| 3 | **Concurrency** | **TenantContext is preserved across `afterCommit`** because the callback runs on the same thread before the request thread releases. Multiple replicas are independent — concurrent advices from different OMS calls run in separate transactions on whichever replica receives them. Postgres commit serialization ensures correctness. | ☐ revise |
| 4 | **Measurable target** | **Zero rows** in the §1 partial-commit fingerprint SQL query (`Advice.state=FINISHED ∧ ∃ Adviceposition.advice_id=Advice.id ∧ Adviceposition.state≠FINISHED`) for any advice closed AFTER commit `41cf1f3`. Historical pre-fix drift may persist; reconcile via separate operations ticket. | ☐ revise |
| 5 | **Backward compat** | **Additive on the OMS side** — same payload, same URL, same headers, same `Message` audit-row schema. The Message audit row's insert site has already moved (in commit `41cf1f3`) from inline (in the v1 IOException catch) to the `OmsNotificationService.doSend` AFTER_COMMIT path. Consumers see no contract change. | ☐ revise |
| 6 | **Coordination** | **SBDEV-2214** ([[SBDEV-2214-oms-http-post-inside-class-level-transactional]]) covers the cancel paths (cancelOrder, cancelBatch, ManageOrderService × 7, MessageService.sendStockChangeMessage). **SBDEV-2215** (this plan) covers the inbound advice/receive paths. **No overlap** verified by the cross-reference grep in §0. The two plans share the `OmsNotificationService.sendAfterCommit` pattern; cross-linked in §References. | ☐ revise |

### Cross-version (v1 ↔ v2) row of the completeness checklist

**v1 plan: deferred — paired plan via `wms-v2-migrate` (run in REVERSE — i.e. authoring a v1 plan from this v2 plan) later.** The v1 codebase actively has the bug as the ticket describes (no @Transactional on AdviceService methods; inline `httpRestService.post` in all three methods). The v1 fix would create:
- Class-level `@Transactional` on `AdviceService` (v1 has only ONE transaction manager — the singleton — so the v2 dual-TM concern does not apply).
- New `AdviceClosedEvent` / `AdviceAcceptedEvent` / `AdviceTransferredEvent` event+listener pairs (per the v1 `BolClosedEvent`/`BolClosedEventListener` precedent), since v1 chose the event pattern over the helper-service pattern.
- Same integration tests (against H2 in v1 — Mockito 3.3.3 limits, no `mockStatic`).

That is what `wms-v2-migrate` (run in REVERSE) should produce later as `sbdocs/1-Projects/wms1/plan/SBDEV-2215-adviceservice-no-transaction-wrapping.md`.

### Completeness checklist (Layer 2)

| # | Concern | Considered? |
|---|---|---|
| 0 | DB verified | `no — db_verified: false` (architectural concern, not a single-query data condition; manual SQL gate documented in §1) |
| 1 | All callsites enumerated | `✓ §0 — 15 sites: rows 1, 2, 4, 5, 7, 8, 13 already-fixed regression-guards; rows 3, 6, 9 covered by new integration tests; row 10 NEGATIVE regression-guard; rows 11, 12, 14, 15 excluded with rationale` |
| 2 | Adjacent bugs | `✓ §0 row 13 (fixHubAndSpokePalletIssues) — same root-cause pattern but different OMS dependency; covered by POSITIVE regression-guard. SBDEV-2214 covers the broader sweep across other services.` |
| 3 | Backward compatibility | `✓ §11 row 5; OMS contract unchanged; Message audit-row schema unchanged; payload + URL unchanged` |
| 4 | Concurrency | `✓ §9 row 7 (Tenant context across afterCommit); §11 row 3` |
| 5 | Multi-tenant | `✓ §9 row 7 — TenantContext preserved across afterCommit` |
| 6 | Error handling | `✓ §3 Bug 1/2/3 — rollbackFor explicitly enumerated; serialization IOException narrowed and logged (existing AdviceService.java:256-258, 348-350, 411-413 catch blocks); audit-row creation in REQUIRES_NEW survives outer rollback (MessageService.java:67)` |
| 7 | Observability | `no — out-of-scope this plan; recommended Micrometer counter on OmsNotificationService.doSend failure path documented as optional follow-up; would be a Phase-6 add to SBDEV-2214 if pursued` |
| 8 | Rollback / migration | `no — pure regression-guard plan; no Flyway, sysprop, or feature flag` |
| 9 | Test coverage | `✓ §8 — 1 NEW integration test class (AdviceServiceRollbackIntegrationTest) with 3 tests (Fix C.1 / C.2 / C.3); existing AdviceServiceUnitTest, AdviceServiceH2Test, AdviceServiceIntegrationTest, OmsNotificationServiceUnitTest stay green` |
| 10 | Cross-version (v1 ↔ v2) | `deferred — v1 paired plan to be authored in a follow-up via wms-v2-migrate (REVERSE). The ticket explicitly tags wmsv1; v1 still has the bug.` |

---

## 12. Risks & Mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| **R1**: Listener (afterCommit lambda) throws → OMS not notified, `Message(state=FAILED)` written | OMS lacks the WMS-FINISHED record; manual reconcile required | Existing pattern — same as SBDEV-2214 R1. The FAILED `Message` row is queryable. Can be reconciled by re-driving via `MessageService.resendMessage`. **No regression** vs today. |
| **R2**: Tenant context lost in afterCommit | OMS POST goes to wrong tenant DB lookup, or audit row written under wrong tenant | Verified safe (§9 row 7 evidence). **No reports** since commit `41cf1f3` shipped this pattern across `AdviceService`, `BillofladingService`, `CustomerorderService`, `CustomerorderBatchService`. |
| **R3**: Replica crash between commit and afterCommit → no OMS notification, no FAILED row | Silent loss; rare but real | Out of scope — would require an outbox-pattern reconciler. Document for future plan. **No regression** vs today. |
| **R4**: Self-invocation regression — a future contributor calls `this.acceptHubAndSpokeAdvice(...)` from a non-@Transactional helper method, bypassing the proxy | The inner call runs without @Transactional advice — the bug returns | Verify-script NEGATIVE check on `this.<method-name>(` patterns inside `AdviceService.java`. Currently empty (verified §0 row 15). |
| **R5**: Class-level `@Transactional` accidentally added without explicit `value="tenantTransactionManager"` | Bare `@Transactional` defaults to landlord TM (since `landlordTransactionManager` is `@Primary`), silently disabling rollback for tenant operations | Verify-script NEGATIVE check that no `@Transactional` line in `AdviceService.java` is missing the `tenantTransactionManager` qualifier. |
| **R6**: Caller wraps `adviceService.<method>(...)` in their own `@Transactional` | Method-level @Transactional becomes a no-op (Spring uses the OUTER tx); but since it's the same TM, the rollback semantics are equivalent | Verified safe today (only caller is `AdviceController` extending non-@Transactional `AdminController`). Verify-script can optionally encode a NEGATIVE assertion on `AdviceController` and `AdminController` for `@Transactional` (defensive — the controller layer should never be @Transactional). |
| **R7**: Bulk JPQL UPDATE removed — someone "refactors" `close()` and `acceptTransferAdvice()` back into a per-position save loop, reintroducing the v1 mid-loop failure surface | The integration test still asserts whole-tx rollback (Fix C.2 / C.3) — passes regardless of whether the inner mechanism is a loop or bulk update. So this is NOT a regression at the rollback-correctness level — but the bulk update's performance benefit would be lost | Verify-script POSITIVE check that `advicepositionRepository.updateAdvicepositionToStateByAdviceId(` appears at least 2× in `AdviceService.java` (once for `close`, once for `acceptTransferAdvice`). |
| **R8**: IOException catch block at lines 256-258, 348-350, 411-413 silently swallows serialization errors → OMS notification never registered → silent loss when DTO serialization fails | Same as today — pre-fix behavior unchanged. The serialization paths are deterministic for the DTO shapes used; if a future DTO change introduces a `@JsonInclude` or `@JsonProperty` failure, it would manifest in tests | Document for future plan. The integration tests do not exercise the serialization-failure path; that's a separate hardening concern. |
| **R9**: TDD-gate edge case — tests "fail for the right reason" expectation is inverted (production code is already correct → tests pass green not red) | TDD-gate may incorrectly block | §7.2 Phase 1 explicitly documents the inverted expectation; the gate skill must accept regression-guarding tests OR temporarily revert one of the fixes on a scratch branch to confirm catch. |

---

## 13. Implementation Status

> **Status (2026-05-10):** Merged to `develop`. The implementation was **bundled into the SBDEV-2214 stack** — the executor working on SBDEV-2214 Phase 6 needed the same H2 rollback IT harness for `cancelOrder`, so they authored both test files (`BaseRollbackIntegrationTest` + `AdviceServiceRollbackIntegrationTest`) in a single commit and labelled it explicitly *"regression guard per SBDEV-2215 reference"*. SBDEV-2215's own phase plan (Phase 1–7) was not run as a separate flow.

| Phase | Resolved as | Commit SHA | Notes |
|---|---|---|---|
| Phase 1 — wms-tdd-gate | bundled | `aebb4c7` | The rollback IT was authored alongside SBDEV-2214's own rollback IT — same harness, same test file. The TDD-gate step was effectively the SBDEV-2214 Phase 6 author writing the 3 SBDEV-2215 test methods (Fix C.1 / C.2 / C.3) directly into `AdviceServiceRollbackIntegrationTest`. |
| Phase 2-3 — Implement / Full IT suite | bundled | `aebb4c7` | All 3 tests pass locally (per the `aebb4c7` commit message: "3 pass, 0 fail, 0 skip (37s, H2 boot)"). |
| Phase 4 — Final verify | bundled | (cross-plan) | SBDEV-2214's own verify script (`verify-SBDEV-2214-...sh`) reports `Result: 62 pass, 0 fail, 0 skip` (per SBDEV-2214 §13). The dedicated `verify-SBDEV-2215-adviceservice-no-transaction-wrapping.sh` exists at `sbdocs/9-System/scripts/` for follow-up runs. |
| Phase 5 — Manual smoke | pending deploy | — | Same as SBDEV-2214 Phase 8 — requires staging access. |
| Phase 6 — DB-fingerprint check | n/a | — | §1 explicitly notes "single-query verification not possible" — the symptom is a code-path concern, not a steady-state data condition. |
| Phase 7 — Plan archival | pending merge to `develop` | — | After SBDEV-2214 / SBDEV-2215 land in `develop`, run `/oh-my-claudecode:archive-plan` to move both plans to `sbdocs/4-Archieves/wms2/plan/`. |

| Trailing commit | SHA | Purpose |
|---|---|---|
| ArchUnit store snapshot update | `0c0cbe1` (squash-merged as `1f1bf14` via PR #8 on 2026-05-10) | After `aebb4c7` added the new IT classes, `OptionalSafetyArchTest` regenerated its freeze-store snapshot to acknowledge them. The snapshot diff (+6 / −8 lines) is the only behavior-neutral content delta SBDEV-2215 added on top of the SBDEV-2214 stack. |

**PR**: [#8](https://github.com/SiteBossInc/wms2-api/pull/8) (originally targeted `main`, retargeted to `develop` on 2026-05-10, then squash-merged).

**Final acceptance line (cross-plan):** SBDEV-2214 verify-script `Result: 62 pass, 0 fail, 0 skip` covers both plans' test files because they share `aebb4c7`.

**Pre-fix DB query result (per §1):** N/A — code-path concern, not a steady-state data symptom.

**Post-fix DB query result (per §1):** N/A — same rationale.

---

## 14. Acceptance & Implementation

### 14.1 Acceptance script

`sbdocs/9-System/scripts/verify-SBDEV-2215-adviceservice-no-transaction-wrapping.sh`

The script encodes:

**Existing fixes — regression-guards (POSITIVE checks):**
- `acceptHubAndSpokeAdvice`, `close`, and `acceptTransferAdvice` each carry `@Transactional` with both `tenantTransactionManager` and `rollbackFor = {BusinessException.class, FacadeException.class}`. Because the annotation and method signature span two lines in the source, the check uses a portable two-step shell pipe rather than a multi-line regex (BSD `grep` on macOS does not support `-P` / PCRE, and `\s` does not bridge newlines in BSD `-E`):
  ```bash
  # For each of the three method names, assert the line immediately before
  # "public void <method>" contains tenantTransactionManager AND rollbackFor:
  for method in acceptHubAndSpokeAdvice close acceptTransferAdvice; do
    preceding=$(grep -n "public void ${method}" AdviceService.java \
      | head -1 | cut -d: -f1)
    annot_line=$((preceding - 1))
    # Read the preceding TWO lines in case the annotation spans two source lines
    annot=$(sed -n "$((annot_line-1)),${annot_line}p" AdviceService.java)
    echo "$annot" | grep -q "tenantTransactionManager" \
      && echo "$annot" | grep -q "rollbackFor" \
      && echo "$annot" | grep -q "BusinessException" \
      || { echo "FAIL: @Transactional missing/wrong on $method"; FAILS=$((FAILS+1)); }
  done
  ```
- `fixHubAndSpokePalletIssues` is annotated `@Transactional(value="tenantTransactionManager"...)` (adjacent-bug regression guard; same two-step check for `tenantTransactionManager` on the line preceding the method signature).
- `acceptHubAndSpokeAdvice` body invokes `omsNotificationService.sendAfterCommit(... ADVICE_HUB_AND_SPOKE_RECEIVED)`.
- `close` body invokes `omsNotificationService.sendAfterCommit(... ADVICE_CLOSE)`.
- `acceptTransferAdvice` body invokes `omsNotificationService.sendAfterCommit(... ADVICE_ACCEPT_TRANSFER)`.
- `OmsNotificationService.java` exists and its `sendAfterCommit` method registers a `TransactionSynchronization` (delegated check from SBDEV-2214 §A).
- `MessageService.createServiceLog` retains `propagation = Propagation.REQUIRES_NEW` (audit-row survives outer rollback).
- `advicepositionRepository.updateAdvicepositionToStateByAdviceId(` appears at least 2× in `AdviceService.java` (bulk-update regression guard, R7).

**Existing fixes — regression-guards (NEGATIVE checks):**
- `httpRestService.post(` does NOT appear anywhere in `AdviceService.java` (top-level firewall).
- No `@Transactional` line in `AdviceService.java` lacks the `tenantTransactionManager` qualifier (R5 firewall). Regex: every `@Transactional` occurrence must be followed within 3 lines by `tenantTransactionManager`.
- No `this.acceptHubAndSpokeAdvice(`, `this.close(`, or `this.acceptTransferAdvice(` self-invocation in `AdviceService.java` (R4 firewall).

**`AdviceRestController:331` audit (DOCUMENTATION check):**
- `grep -n "updateAdvicepositionToStateByAdviceId" AdviceRestController.java` returns exactly 1 hit at line 331 — the out-of-scope site enumerated in §0 row 16. The verify script logs this as `DOCUMENTED OUT-OF-SCOPE` (not a FAIL). If the count exceeds 1, flag for manual review.

**New integration tests (POSITIVE checks):**
- `BaseRollbackIntegrationTest.java` exists and does NOT contain `@Transactional` at the class level.
- `AdviceServiceRollbackIntegrationTest.java` exists and extends `BaseRollbackIntegrationTest`.
- It declares `acceptHubAndSpokeAdvice_shouldRollbackAllPositions_andNotPostToOms_whenMidLoopExceptionThrown`.
- It declares `close_shouldRollbackAdviceAndPositions_andNotPostToOms_whenLaterStepThrows`.
- It declares `acceptTransferAdvice_shouldRollbackAdviceAndPositions_andNotPostToOms_whenLaterStepThrows`.

**Maven test runs:**
- `mvn test -Dtest=AdviceServiceUnitTest` passes.
- `mvn test -Dtest=AdviceServiceH2Test` passes.
- `mvn test -Dtest=OmsNotificationServiceUnitTest` passes.
- `mvn verify -Dtest=AdviceServiceIntegrationTest` passes (existing).
- `mvn verify -Dtest=AdviceServiceRollbackIntegrationTest` passes (new).

Run baseline before any code change; run after every cluster of changes; final acceptance line `Result: N pass, 0 fail, M skip`.

### 14.2 Recommended OMC composition (for implementation)

1. `wms-tdd-gate` — create `BaseRollbackIntegrationTest.java` (no `@Transactional`), then write `AdviceServiceRollbackIntegrationTest` extending it with the three test methods per Fix C.1/C.2/C.3. Handle the inverted-red-test edge case per Phase 1 of §7.2.
2. After human approval, hand off to `executor` (model: sonnet) to complete `@BeforeEach` seed helpers and `@AfterEach` cleanup. No production code edits.
3. `verify` skill — run the §14 acceptance script post-implementation; paste the result line into §13.

### 14.3 References

- `sbdocs/1-Projects/wms2/plan/SBDEV-2214-oms-http-post-inside-class-level-transactional.md` — the sibling plan that locked in the `OmsNotificationService.sendAfterCommit` pattern; this plan reuses its naming convention (POSITIVE/NEGATIVE check structure, integration-test naming `<method>_shouldNotPostToOms_when<condition>`), tenant-context evidence, and audit-row REQUIRES_NEW precedent.
- `sbdocs/1-Projects/wms1/plan/260424-oms-notification-rollback-risk-remediation.md` — v1 origin of the helper-pattern decision.
- `sbdocs/3-Resources/architecture/wms2-oms-integration-map.md` §2.1 / §2.2 — outbound advice notification map.
- `sbdocs/3-Resources/architecture/wms2-transaction-osiv-boundary-map.md` §6 — the no-external-call-inside-tx rule.
- `sbdocs/3-Resources/architecture/wms2-state-machine-catalog.md` — `AdviceState` transitions.
- `sbdocs/3-Resources/architecture/wms2-receiving-putaway-workflow.md` — surfaces all four advice flows.
- `sbdocs/2-Areas/wms-v1-v2-sync/sync-log.md` (2026-05-07 entry) — earlier sync-sweep observation that v2's `AdviceService.close()` already had `@Transactional` with `saveAndFlush`, which seeded this plan's framing.
- `v2/wms2-api/CLAUDE.md` "Dual Transaction Manager" section — the rule that mandates `value="tenantTransactionManager"` for tenant-scoped writes; codifies the rejection of class-level `@Transactional`.
