---
title: "SBDEV-2610 (v2) — Move Unit Load blocked by in-progress replenishment (0 reserved-out confusion)"
ticket: "SBDEV-2610"
ticket_url: "https://app.clickup.com/t/9006034209"
type: bugfix
priority: high
status: draft
project: [wms2]
version: v2
requester: "Scott Dalton (ST#1047, WineCo)"
created: 2026-07-20
updated: 2026-07-20
db_verified: partial
related:
  - "[[SBDEV-2610-move-unitload-false-reserved-block]]"
  - "[[SBDEV-2492-replen-order-source-sync-on-unitload-move]]"
  - "[[SBDEV-2074-replen-reservation-reassign-on-nonreplenishable-move]]"
tags:
  - plan
  - wms2
  - replenishment
  - move-unitload
---

# SBDEV-2610 (v2) — Move Unit Load blocked by in-progress replenishment (0 reserved-out confusion)

**Ticket:** [SBDEV-2610](https://app.clickup.com/t/9006034209) (ST#1047, WineCo)
**Project:** wms2 | **Version:** v2 (`wms2-api`, Java 21 / Spring Boot 3.5.9) | **Type:** bugfix (UX/observability) + latent-bug hardening
**V1 source plan:** [[SBDEV-2610-move-unitload-false-reserved-block]] (`sbdocs/1-Projects/wms1/plan/`)
**Status:** Draft — revised after v2 critic + architect review (2026-07-20)
**Date:** 2026-07-20

> **Port of the corrected v1 plan, then hardened by a v2-specific critic + architect pass.** The v1 incident cause is the **SBDEV-2492 in-progress-replenishment block**, not `checkReservedStock`. **v2 review found a decisive gap the v1 story doesn't have:** because of the v2 SBDEV-2074 refactor, that block is thrown from **two byte-identical sites** — see Bug 1. `checkReservedStock` dead-end is a separate latent bug (Part 2), splittable.

> **🚦 BLOCKING gate:** confirm (1) deployed v2 build on the affected tenant, (2) exact operator error text, (3) **whether any tenant is live on v2 for this flow**, and (4) **whether the incident move targeted a replenishable or non-replenishable destination** — this decides which of the two throw sites (§2 Bug 1) the operator actually hit.

## 2. Summary

- **v1 fixes considered:** 4 (A1 message clarity, A2 mobile surfacing, B1 guard honesty, C1 reconciliation). All apply to v2.
- **NEW v2-only concerns:** 2 — **NEW-1** (reconciliation cannot be a startup Flyway migration) and **NEW-2** (the `>=STARTED` block is thrown from **two** sites; Fix A1 must patch both).
- **v2 is more hardened than v1** on this path: SourceSync uses a locked re-read (`findByIdForUpdate`) inside the move's `tenantTransactionManager` tx, and the SBDEV-2074 refactor adds a reassign-or-cancel branch for non-replenishable destinations — but that refactor is exactly what created NEW-2, and both block messages **omit the replen order number** v1 includes.
- **Not cached:** `stockunit`/`replenishorder` are not in `CacheConfig` — no `@CacheEvict` needed (resolved, not "verify").
- **Dropped (same as v1):** replenishment release-target rework / split-carry. Also dropped: the `V2.2.04` migration (a fresh v2 DB has no orphaned rows, so a data-fix migration would be a permanent no-op).

## 3. V1 → V2 Applicability Analysis

| V1 Fix | Description | V2 Verdict | Rationale (v2 file:line) |
|--------|-------------|------------|--------------------------|
| A1 | Clarify in-progress-replen block message (name the order) | **Needed — TWO sites (NEW-2)** | Identical block string thrown at `ReplenishmentOrderSourceSyncService.java:92-94` (replenishable dest) **and** `ReplenishmentOrderMaintenanceService.java:181-184` (non-replenishable dest, via `reassignOrCancelForMovedStockUnit`). Both omit the replen number. |
| A2 | Surface active-replen state on mobile Move Unit Load | **Needed — DTO change** | The block never fires on the first scan: `checkReservedStock` silently `continue`s over the started replen (`MobileMoveUnitloadService.java:196-200`); it only throws on `scanDestination`. To signal early, `scanUnitLoad` (`:111`) must populate a new `TransferInfoDto` field — not just fuller exception text. |
| B1 | `checkReservedStock` honesty | **Needed — read-only** | `MobileMoveUnitloadService.java:188-205` is byte-identical to v1 (throw `:202`, SBDEV-2492 `continue` `:200`, child recursion `:189-191`). Reuse existing `PickingorderPositionRepository.findByPickfromstockunitId` (`:33`). **Hard constraint:** the guard is also called from `scanUnitLoad` (`:163`, **no `@Transactional`**, runs under OSIV) — it must stay strictly read-only. |
| C1 | Reconcile orphaned `reservedamount` | **Needed — audited admin path (NEW-1)** | Same shared-counter dead-end. Deliver as a guarded per-tenant admin job that mutates via `StockunitBusinessService.changeReservedAmount` (`:467` — `findByIdForUpdate` + audit `stockrecord`), not raw SQL. v2 app doesn't run Flyway at startup. |
| (dropped) | Replen release-target rework / split-carry | **Not ported** | Same rationale as v1. |

## 4. V2-Specific Adaptation Notes

1. **Transaction manager:** edited/new tenant `@Transactional` uses `value = "tenantTransactionManager", rollbackFor = {BusinessException.class, FacadeException.class}`. `scanDestination` already declares it (`:207`). A1's edits touch only exception-message strings inside methods that already join the caller tx.
2. **Guard read-only constraint:** `checkReservedStock` runs under BOTH `scanDestination` (tenant tx) and `scanUnitLoad` (**non-transactional**, OSIV). B1's rewrite must perform **no writes** — warn+allow only. Do not add any reservation-release inside the guard.
3. **Jakarta / Optional:** `jakarta.*`; `EntityNotFoundException` (already used in v2 SourceSync) / `BusinessException`; never `.get()`.
4. **Entity equality:** ID-based `AbstractBaseEntity.equals` — no v1 `.getId().equals()` rewrite needed.
5. **Caching (resolved):** `CacheConfig.java:34-37` caches only `sysprops/clients/locations/itemdata`. `stockunit`/`replenishorder` are **not cached** — no `@CacheEvict` needed. (Do not add a spurious `@CacheEvict("stockunit")`.)
6. **Constructor injection / DI:** reuse the leaf `PickingorderPositionRepository` (no cycle risk; `@Lazy` gymnastics apply only to SourceSync↔Maintenance, not here).
7. **SLF4J parameterized logging** for the stranded warn: `LOG.warn("stranded reservation su={} reserved={} (SBDEV-2610)", su.getId(), su.getReservedamount())`.
8. **Reconciliation delivery (NEW-1):** operator-run, per tenant DB, via an audited admin job/endpoint calling `changeReservedAmount`. **No `V2.2.04` migration** (fresh DBs have no orphans → permanent no-op). Raw SQL only for the orphan *report*, never the mutation.
9. **IT harness broken (SBDEV-2217):** gate on unit tests + `mvn clean compile`; leave any Testcontainers IT `@Disabled` with `TODO(SBDEV-2217)`.

## 5. Changes by File & Implementation Plan

### Fix A1 — clarify the block message at BOTH throw sites (NEW-2)
| Site | V2 Line | Status | Action | Priority |
|---|---|---|---|---|
| `ReplenishmentOrderSourceSyncService.java` | 92-94 | Missing order # | append replen number + source location; keep the block | High |
| `ReplenishmentOrderMaintenanceService.java` | 181-184 | Missing order # (non-replenishable dest path) | same message via a **shared builder** so the two cannot drift | High |

**Current (both sites, identical):**
```java
if (state >= WmsConstants.State.STARTED) {
    throw new BusinessException(
        "Replenishment in progress for this stock; complete or cancel it before moving.");
}
```
**Fix:** extract `replenBlockMessage(Replenishorder ro)` (order number + source-location name) and call it from both sites. Both have the loaded order in hand (`SourceSync:89`, `Maintenance:179`, both `findByIdForUpdate`). The mobile UI renders the `BusinessException` message verbatim (`RestExceptionHandler`), so this text *is* the operator-facing channel for the block itself.

**Truth table (why both sites matter):**
| Destination | Replen state | Outcome |
|---|---|---|
| Replenishable | `< STARTED` | silent re-point (`SourceSync:109-113`) |
| Replenishable | `>= STARTED` | **throw @ `SourceSync:94`** |
| Non-replenishable | `< STARTED` | silent redirect/cancel (`Maintenance:188-190`) |
| Non-replenishable | `>= STARTED` | **throw @ `Maintenance:183`** |

### Fix A2 — surface active-replen state early (DTO change)
Add a field to `TransferInfoDto` (e.g. `activeReplenNumber` / state) populated in `MobileMoveUnitloadService.scanUnitLoad` (`:111`) by looking up the bound replen, so the operator sees the in-progress replenishment on the **first** scan (before choosing a destination). Surface it in the `wms2-mobile-ui` move-unitload source-scan view. This is a real DTO + view change, not message text.

### Fix B1 — `checkReservedStock` honesty (read-only)
`MobileMoveUnitloadService.java:188-205`. Rewrite: exact-id open replen (`existsForStockUnit`, `state<700`) → `continue`; **active** pick (`findByPickfromstockunitId` with `state < 600`, outstanding reservation) → throw order-numbered message; else stranded → `LOG.warn` + allow. Preserve child recursion (`:189-191`). **No** broadened `findOpenSourceHolder`. **Strictly read-only** (called from non-transactional `scanUnitLoad`).

### Fix C1 — reconcile orphaned `reservedamount` (audited admin path, NEW-1)
Guarded, per-tenant one-off admin job/endpoint iterating orphans and calling `StockunitBusinessService.changeReservedAmount(su, su.getReservedamount().negate(), true, CODE_MANUAL_ADJUSTMENT/marker, …)` — gives audit `stockrecord` + `findByIdForUpdate` lock + `@Version` + tenant context. Predicate (confirmed against v2 schema): `reservedamount<>0 AND NOT EXISTS(replenishorder r WHERE r.stockunit_id=su.id AND r.state<700) AND NOT EXISTS(pickingorder_position p WHERE p.pickfromstockunit_id=su.id AND p.state<600)`. Raw SQL only for the orphan **report**. Idempotent (zeroed rows stop matching). **No Flyway migration.**

### 5.1 Prerequisites

| # | Prerequisite | Value / action | Notes |
|---|---|---|---|
| 1 | **🚦 Ops confirmation (BLOCKING)** | deployed v2 build + exact operator message + is any tenant live on v2 + **replenishable vs non-replenishable destination** | (4) decides which throw site (§2) was hit |
| 2 | Reconciliation | audited admin job, per tenant DB (NEW-1); **no Flyway migration** | fresh DBs have no orphans |
| 3 | Reconciliation target | re-run §6 orphan query on the **live v2 tenant** — dev count is a migration artifact | dynamic |
| 4 | Deploy order | wms2-api (A1/B1) before wms2-mobile-ui (A2) | UI relies on API message + new DTO field |
| 5 | Flags / sysprops / external / access | admin-job trigger may need a role gate | otherwise N/A |

### 5.2 Implementation Checklist
- [ ] Gate: ops confirms build + operator message + v2-live status + destination replenishability.
- [ ] Fix A1: shared `replenBlockMessage` builder; call from `ReplenishmentOrderSourceSyncService:92-94` **and** `ReplenishmentOrderMaintenanceService:181-184`.
- [ ] Fix A2: `TransferInfoDto` active-replen field populated in `scanUnitLoad`; wms2-mobile-ui view.
- [ ] Fix B1: rewrite `checkReservedStock` (read-only; reuse `findByPickfromstockunitId`; pick-state<600; no broadened lookup; keep recursion).
- [ ] Fix C1: audited per-tenant admin job via `changeReservedAmount`; orphan-report SQL.
- [ ] Unit tests (extend `BaseUnitTest`, `@ExtendWith(MockitoExtension.class)`); ITs `@Disabled` TODO(SBDEV-2217).
- [ ] `mvn clean compile` + `mvn test -Dtest=...` green; `bash sbdocs/9-System/scripts/verify-SBDEV-2610-move-unitload-false-reserved-block-v2.sh` → 0 fail.

## 6. NEW Issues Summary

| NEW-# | Issue | File:Line | Severity | Description |
|-------|-------|-----------|----------|-------------|
| NEW-1 | Reconciliation cannot be a startup migration | provisioning | Medium | v2 app doesn't invoke Flyway; deliver as an audited per-tenant admin job. No `V2.2.04`. |
| NEW-2 | `>=STARTED` block thrown from TWO sites | `ReplenishmentOrderSourceSyncService:94` + `ReplenishmentOrderMaintenanceService:183` | **High** | SBDEV-2074 refactor split the block across replenishable/non-replenishable paths with the identical order-number-less message. Fix A1 must patch both (shared builder) or the non-replenishable-destination operator keeps the confusing message. |

v2 orphan count on `wms2-wineco-dev` (migrated dev copy — **unreliable**): reserved-nonzero 2225 / no-open-replen 1664 / truly-orphan 1655. Re-derive on the live v2 tenant (§5.1 row 3).

## 7. Horizontal Scalability Validation

| # | Concern | Verdict | Rationale |
|---|---|---|---|
| 1 | In-JVM state | N/A | no new caches/threadlocals |
| 2 | Connection pool math | N/A | no new per-request connections |
| 3 | Scheduled jobs | N/A | reconciliation is a one-off admin job, not a cron |
| 4 | Long transactions | N/A | message/DTO/guard changes are short |
| 5 | Request affinity | N/A | stateless |
| 6 | Retry / idempotency | **Yes** | reconciliation idempotent via runtime predicate re-check |
| 7 | Tenant context | N/A | runs in request/admin tenant context |
| 8 | Distributed lock correctness | **Yes** | reconciliation uses `changeReservedAmount`→`findByIdForUpdate`; SourceSync already locks in-tx (`:88-90`) |
| 9 | Cache invalidation | **No** | `stockunit`/`replenishorder` not cached (`CacheConfig:34-37`) — nothing to evict |
| 10 | External notifications | N/A | pure relocation fires no OMS notification |

## 8. Testing Plan

| Test class | Method | Asserts |
|---|---|---|
| `ReplenishmentOrderSourceSyncServiceTest` (extends `BaseUnitTest`) | `startedReplen_replenishableDest_blocksWithOrderNumber` | SourceSync:94 message includes replen number |
| `ReplenishmentOrderMaintenanceServiceTest` (`BaseUnitTest`) | `reassignOrCancel_startedReplen_nonReplenishableDest_blocksWithOrderNumber` | **second site** (Maintenance:183) message includes replen number |
| `MobileMoveUnitloadServiceTest` (`BaseUnitTest`, `@ExtendWith(MockitoExtension.class)`) | `checkReservedStock_stranded_allows` | warn + allow, no write |
| `MobileMoveUnitloadServiceTest` | `checkReservedStock_activePick_blocks` | order-numbered throw (pick state<600) |
| `MobileMoveUnitloadServiceTest` | `checkReservedStock_childUL_recursion` | recursion preserved |
| `MobileMoveUnitloadServiceTest` | `scanUnitLoad_activeReplen_populatesDtoField` | A2 DTO field set on first scan |
| reconciliation | admin-job unit test | zeroes only orphans; audited via `changeReservedAmount`; idempotent |

v2 tests: modern Mockito; H2-suffixed unit tests or Testcontainers (ITs `@Disabled` SBDEV-2217). Controller changes (none expected) would use `BaseControllerUnitTest`.

### Manual test plan
| Scenario | Env | Steps | Expected | P/F |
|---|---|---|---|---|
| Replenishable dest, started replen | v2 staging | Move Unit Load to a replenishable location | clear "complete or cancel replen REPLxxxxx" (SourceSync site) | |
| Non-replenishable dest, started replen | v2 staging | Move Unit Load to floor/dock/damaged | **same clear message** (Maintenance site) — the NEW-2 case | |
| Early signal | v2 staging | scan UL on first screen | replen number/state shown before destination scan | |
| Stranded allow | v2 staging | orphan reservedamount | Move proceeds, no cancel | |
| Reconciliation | v2 tenant | run admin job; re-run §6 query | orphans → 0 with audit rows; replen/pick rows unchanged; rerun no-op | |

### Execution (fill after running)
| Command | Result | counts |
|---|---|---|
| `mvn clean compile` | | |
| `mvn test -Dtest=ReplenishmentOrderSourceSyncServiceTest,ReplenishmentOrderMaintenanceServiceTest,MobileMoveUnitloadServiceTest` | | |

## 9. Risk Assessment

| Risk | Impact | Mitigation |
|------|--------|-----------|
| Fix A1 patches only one throw site (NEW-2) | non-replenishable-destination operator keeps the confusing message; verify-script false-green | shared `replenBlockMessage` builder called from both sites; verify check on BOTH files |
| Reconciliation via raw SQL | no audit trail, no lock on an inventory counter | mutate via `changeReservedAmount` admin job; SQL for report only |
| Guard write in non-transactional `scanUnitLoad` | write outside a tenant tx | B1 is strictly read-only (warn+allow) |
| dev orphan count (1655) mistaken for prod | mis-scoping | re-derive on live v2 tenant |
| Spurious `@CacheEvict("stockunit")` | no-op / confusion | documented: stockunit not cached |

## 10. Open Questions / Resolved Decisions

| # | Item | Resolution |
|---|------|-----------|
| 1 | Keep the `>=STARTED` block? | **Keep** (mirror v1); make it clear + visible. |
| 2 | Part 2 here or sibling ticket? | Kept, separable. |
| 3 | Broadened `findOpenSourceHolder` | **Dropped** (architect H2, mirror v1). |
| 4 | Reconciliation delivery | **Audited admin job** (NEW-1); no Flyway migration; SQL for report only. |
| 5 | Which throw site did the incident hit? | **OPEN — ops gate row 1(4):** replenishable → SourceSync:94; non-replenishable → Maintenance:183. |
| 6 | Is any tenant live on v2 for this flow? | **OPEN — ops gate.** |
| 7 | `V2.2.04` migration? | **Dropped** — fresh DBs have no orphans. |

## 11. Implementation Status

_Not implemented. Blocked on the §5.1 ops gate. Record on execution: v2 build confirmation, commit SHA(s), test names, `mvn clean compile`/`mvn test` summary, verify-script line._

### Review trail
- v1 plan: critic + architect (corrected the root cause from `checkReservedStock` → SBDEV-2492 block).
- **v2 plan: critic + architect (2026-07-20)** — both APPROVE-WITH-CHANGES. Decisive finding NEW-2 (two throw sites) + A2 DTO scope + C1 audited path + `BaseUnitTest` + cache-not-cached + drop `V2.2.04`, all folded in above.

### Completeness checklist
| # | Concern | Considered? |
|---|---|---|
| 0 | DB verified | ⚠ partial — v2 code verified; orphan count dev-only (`db_verified: partial`) |
| 1 | All callsites enumerated | ✓ §3/§5 incl. NEW-2 second throw site |
| 2 | Adjacent bugs | ✓ split-carry ruled out; second block site found |
| 3 | Backward compatibility | ✓ message text + additive DTO field; reconciliation data-only |
| 4 | Concurrency | ✓ HS #8; guard read-only under OSIV caller |
| 5 | Multi-tenant | ✓ per-tenant admin job; NEW-1 |
| 6 | Error handling | ✓ both block sites carry order #; B1 stranded→warn |
| 7 | Observability | ✓ stranded warn + orphan-count report + A2 DTO signal |
| 8 | Rollback / migration | ✓ audited idempotent admin job; no Flyway migration |
| 9 | Test coverage | ✓ §8 incl. second-site test; ITs @Disabled SBDEV-2217 |
| 10 | Cross-version | ✓ paired v1 [[SBDEV-2610-move-unitload-false-reserved-block]] |

**Acceptance script:** `sbdocs/9-System/scripts/verify-SBDEV-2610-move-unitload-false-reserved-block-v2.sh`
