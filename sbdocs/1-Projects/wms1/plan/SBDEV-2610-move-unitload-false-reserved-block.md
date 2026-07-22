---
title: "SBDEV-2610 — Move Unit Load blocked by in-progress replenishment (0 reserved-out confusion)"
ticket: "SBDEV-2610"
ticket_url: "https://app.clickup.com/t/9006034209"
type: bugfix
priority: high
status: draft
project: [wms1]
version: v1
requester: "Scott Dalton (ST#1047, WineCo)"
created: 2026-07-20
updated: 2026-07-20
db_verified: true
related:
  - "[[SBDEV-2492-replen-order-source-sync-on-unitload-move]]"
  - "[[SBDEV-2074-replen-reservation-reassign-on-nonreplenishable-move]]"
  - "[[260424-Reservation_Leak_Fix_Plan]]"
tags:
  - plan
  - wms1
  - replenishment
  - move-unitload
---

# SBDEV-2610 — Move Unit Load blocked by in-progress replenishment (0 reserved-out confusion)

**Ticket:** [SBDEV-2610](https://app.clickup.com/t/9006034209) (ST#1047, WineCo)
**Project:** wms1 | **Version:** v1 (Java 8 / Spring Boot 2.3.7) | **Type:** bugfix (UX/observability) + latent-bug hardening
**Priority:** High
**Status:** Draft — awaiting review
**Date:** 2026-07-20

> **⚠ Diagnosis was corrected after critic + architect review (2026-07-20).** The first draft blamed `MobileMoveUnitloadService.checkReservedStock`. Production data disproves that: `reservedamount` on the incident stock unit was **0 for 2m34s before the move succeeded**, and an open exact-id replen makes that guard `continue`, not throw. The real blocker is the **SBDEV-2492 in-progress-replenishment guard** (`ReplenishmentOrderSourceSyncService.syncForMovedStockUnit`). The `checkReservedStock` dead-end is a **separate, real latent bug** that did **not** cause this incident — see Part 2.

> **Scope (from requester Q&A + architect):** **v1 now, paired v2 follow-up.** **Part 1** (incident) = make the in-progress-replenishment block clear and its state visible (the ticket's explicit "expected result"). **Part 2** (latent) = `checkReservedStock` guard-honesty + a reconciliation migration for the 17 orphaned rows; **may be split to a sibling ticket** — call it out at review. **Dropped:** the original "Fix B" replenishment release-target rework and any split-carry change (see §8).

> **🚦 Blocking pre-implementation gate:** confirm with ops (1) the WineCo prod deployed commit SHA/build and (2) the **exact** exception text the operator saw. Code+data force the SourceSync mechanism with high confidence, but the message text (`"Replenishment in progress…"` vs `"Reserved stock!"`) decides whether Part 1 alone resolves the ticket. Do not write code before this lands.

---

## 0. Affected sites (enumeration)

| # | File:line | Construct | Incident cause? | In-scope | Part |
|---|-----------|-----------|-----------------|----------|------|
| 1 | `service/ReplenishmentOrderSourceSyncService.java:52-63` | `syncForMovedStockUnit` — throws `"Replenishment in progress… complete or cancel it before moving"` when replen `state >= STARTED (500)` | **YES (primary)** | yes | 1 |
| 2 | `service/UnitloadBusinessService.java:247` | calls `syncForMovedStockUnit(su, destinationLocation)` inside `processTransfer` on every unit-load relocation (SBDEV-2492) | yes (call site) | yes | 1 |
| 3 | `service/mobile/MobileMoveUnitloadService.java:186-203` | `scanDestination` → `transferUnitLoadToLocation` (reaches #2); surfaces the thrown message to mobile | yes (surfacing) | yes | 1 |
| 4 | `wms-mobile-ui` move-unitload error/pre-scan view | operator saw only "0 reserved out"; the replen-in-progress state is not surfaced | yes (UX) | yes | 1 |
| 5 | `service/mobile/MobileMoveUnitloadService.java:166-183` | `checkReservedStock` — dead-ends `reservedamount!=0` with no open exact-id replen and no recourse | **no** (latent) | yes | 2 |
| 6 | `service/ReplenishorderService.java:273-281` | `existsForStockUnit` — exact-id + `state<700` only | no (latent) | yes | 2 |
| 7 | stock units with orphaned `reservedamount` (prod: 17 today) | reconciliation target | no (latent) | yes | 2 |
| 8 | `service/StockunitBusinessService.java:238-286` | `transferStockToUnitLoad` split path | **no** — verified: split does **not** carry `reservedamount` to a child; source keeps it. Not a leak origin. | no | — |
| 9 | replen release paths (`ReplenishorderService:202`, `ReplenishmentOrderMaintenanceService:371`, `MobileReplenishService:442-451`) | release keyed on `stockunit_id` | no — dominant orphan origin is picking/customer-order, not replen | **no — dropped/sibling** | — |

---

## 1. Problem Statement

**Symptom (ST#1047):** WineCo could not process Unit Load **UL347145** (SKU **2290074**) through mobile **Move Unit Load**; the move behaved as blocked "as if the inventory was reserved out," yet WMS showed **0 reserved out**. The operator had to **cancel the associated open Replenishment Request** before the move succeeded.

**Ticket's expected result (verbatim):** if an open replenishment request holds inventory on the UL, *the reserved quantity/state should be visible and accurate* and *the user should get a clear explanation that the replenishment must be completed or canceled before movement*; if nothing is reserved out, the move should proceed.

### DB verification (production `wms1-wineco`) — `db_verified: true`

UL347145 = `unitload.id 32439752`; the **only** stock unit ever on it is `32439754` (SKU 2290074). Replen **REPL061406** (requested 18, source `58-YH15`, `stockunit_id 32439754`) was **canceled 2026-07-20 11:06:53**; the **TRANSFER** (the move) landed **11:06:57** — 4 seconds later.

Reserved-amount trail on su 32439754 (production `stockrecord`, 07-20):
| time | activity | reservedΔ | reserved after |
|---|---|---|---|
| 11:02:10 | MANUAL_ADJUSTMENT | −2 | 0 |
| 11:03:48 | REPLENISHMENT (REPL061406) | +5 | 5 |
| 11:04:19 | MANUAL_ADJUSTMENT | −5 | **0** |
| 11:06:53 | REPLENISHMENT_CANCELLED (REPL061406) | −18 | 0 |
| 11:06:57 | **TRANSFER** (move) | — | — |

**Two facts that rule out `checkReservedStock` as the cause:**
1. `reservedamount` was **0 from 11:04:19 until the move at 11:06:57** — the guard's `reservedamount != 0` precondition was false at move time.
2. REPL061406 kept `stockunit_id = 32439754` for its entire life (no `CODE_REDIRECT_REPLENISHMENT_SOURCE` record; identity always `32439754`) and was open (`state < 700`) throughout — so even when reserved was briefly non-zero, `existsForStockUnit(32439754)` returned it and the guard would `continue` (SBDEV-2492), never throw.

**Why the move needed a cancel — deduction (high confidence):** The only deployed path that (a) blocks a unit-load move because of an active replen and (b) is cleared by canceling that replen is `ReplenishmentOrderSourceSyncService.syncForMovedStockUnit` (`:59`), called from `UnitloadBusinessService:247` during `processTransfer`. It **re-points** the replen source silently when the replen is `< STARTED`, but **throws** when `state >= STARTED (500)`. Since the operator was forced to cancel (a `PROCESSABLE` replen would have been re-pointed with no cancel needed), REPL061406 was `>= STARTED`; canceling it made `findByStateLessThanAndStockunitId(FINISHED, su)` return null → early return → move succeeded. The 4-second cancel→move gap corroborates.

> **Open (ops-confirm):** REPL061406's exact state at 11:06:5x is not recoverable from the current row (final state 800); and the operator's literal error message is not in the DB. Both are in the §5.1 blocking gate.

### Systemic latent bug (Part 2) — real but NOT the incident cause

`checkReservedStock` throws `"Reserved stock! can not move unit load"` when a child stock unit has `reservedamount != 0` and no **open, exact-id** replen references it — with no operator recourse. `reservedamount` is a **shared** counter (picking, customer orders, manual adjust, replenishment), so a stranded value from any origin dead-ends a move. Production today:
```sql
SELECT
 (SELECT COUNT(*) FROM stockunit WHERE reservedamount<>0) AS reserved_nonzero,           -- 631
 (SELECT COUNT(*) FROM stockunit su WHERE su.reservedamount<>0
    AND NOT EXISTS(SELECT 1 FROM replenishorder r WHERE r.stockunit_id=su.id AND r.state<700)) AS no_open_replen, -- 40
 (SELECT COUNT(*) FROM stockunit su WHERE su.reservedamount<>0
    AND NOT EXISTS(SELECT 1 FROM replenishorder r WHERE r.stockunit_id=su.id AND r.state<700)
    AND NOT EXISTS(SELECT 1 FROM pickingorder_position p WHERE p.pickfromstockunit_id=su.id)) AS truly_orphan; -- 17
```
Of 40 rows with no open replen, **23 have a pick position** (legitimate outbound reservation) and **17 are truly orphaned**. The orphan `reservedamount` history is dominated by `CREATE_PICK_POSITION` / `PICKING` activity codes — i.e. **picking/customer-order origin, not replenishment**. The set drifts intraday.

---

## 2. Root Cause Analysis

### Bug 1 (incident) — the in-progress-replenishment guard forces a manual cancel, and its state is invisible to the operator

`ReplenishmentOrderSourceSyncService.syncForMovedStockUnit` (`:52-63`):
```java
Replenishorder ro = replenishorderRepository
    .findByStateLessThanAndStockunitId(WmsConstants.State.FINISHED, su.getId()).orElse(null);
if (ro == null) return;                                   // no active replen → no-op
if (ro.getState() >= WmsConstants.State.STARTED) {        // 500 — block in-progress
    throw new BusinessException(
        "Replenishment in progress for this stock; complete or cancel it before moving. "
        + "replenOrderNumber=" + ro.getNumber());
}
// else: silently re-point source to destination
```
Called at `UnitloadBusinessService:247` inside `processTransfer`. This is **working as designed** per SBDEV-2492 (deliberately block a move of stock whose replenishment pick is already in progress). The defect is UX/observability, exactly matching the ticket's expected result:
- The block state ("this stock is the source of in-progress replenishment REPL061406") is **not surfaced** on the mobile Move Unit Load screen — the operator only saw the unrelated "reserved out = 0" figure and concluded the block was inexplicable.
- Forcing a manual cancel of a legitimately in-progress replen is heavy-handed and risks canceling replenishment unnecessarily (the ticket's stated impact).

### Bug 2 (latent, separate) — `checkReservedStock` dead-ends stranded reservations with no recourse

`MobileMoveUnitloadService.java:166-183`: any `reservedamount != 0` without an open exact-id replen throws with no operator path forward. Because `reservedamount` is shared, 17 orphaned rows (mostly picking-origin) currently make their unit loads unmovable. This is real and worth fixing, but it did not cause UL347145.

> **Corrected from draft v1:** the split path does **not** carry `reservedamount` to a child (`StockunitBusinessService.java:238-286`: full-move keeps the same su+reservation; split leaves source reservation intact, dest gets 0), so "split carry-over leak" is not a mechanism. And the dominant orphan origin is picking/customer-order, so a replenishment release-target rework would not address it — dropped.

---

## 3. Fix Design

### Part 1 — incident (do first, after the ops gate)

**Fix A1 — surface the in-progress-replenishment block clearly (API).** In `ReplenishmentOrderSourceSyncService:59`, keep the block but make the message self-describing and machine-parseable for the UI (order number, source location, "complete or cancel to move"). Ensure `MobileMoveUnitloadService.scanDestination` (and `scanUnitLoad`) propagate it as a first-class, operator-facing reason rather than a generic error.

**Fix A2 — show replen-in-progress state before/at the block (mobile UI).** On the Move Unit Load source-scan info (`wms-mobile-ui`), when the scanned UL's stock is the source of an active replen, display the replen number + state (and its reserved-for-replenishment quantity) so "0 reserved out" is no longer the only signal. This directly satisfies the ticket's "reserved quantity or state should be visible and accurate."

> **Policy question for review (§10):** keep the hard block for `>= STARTED` (recommended — a mid-pick replen source should not move), or allow the move + auto-cancel/re-point? Architect + SBDEV-2492 intent favor keeping the block; Part 1 makes it *understandable*, not permissive.

### Part 2 — latent hardening (may be a sibling ticket)

**Fix B1 — `checkReservedStock` honesty.** Rewrite the guard: exact-id open replen (`state<700`) → `continue`; **active** outbound pick (`pickingorder_position.state < 600` on `pickfromstockunit_id = su.id`, outstanding reservation) → throw an order-numbered, actionable message; otherwise (stranded, no live consumer) → `LOG.warn` and **allow** the move. Preserve the child-UL recursion (`findByCarrierunitloadId`, `:167`). **Do not** add an itemdata+location "broadened" replen lookup — there is no drift evidence and it risks false matches (architect H2).

**Fix C1 — reconciliation of the 17 orphaned rows.** A **Java Flyway callback** iterating stock units matching the runtime predicate and releasing via `StockunitBusinessService.changeReservedAmount` (locked `findByIdForUpdate` + correct `recordChangeReservedAmount` audit). Predicate: `reservedamount<>0 AND NOT EXISTS(open replen state<700) AND NOT EXISTS(pickingorder_position on pickfromstockunit_id)`. Do **not** special-case `MANUAL_ADJUSTMENT` (that is how operators tried to clear these). Idempotent via runtime re-check. Prefer the callback over raw SQL because `stockrecord.id` is app-managed (no DB default) with many NOT NULL columns.

---

## 4. Architecture Overview

```
Mobile Move Unit Load
  scanUnitLoad()   MobileMoveUnitloadService:88   → checkReservedStock (Bug 2 / Fix B1)
  scanDestination() :186  @Transactional
    → UnitloadBusinessService.transferUnitLoadToLocation :83
        → processTransfer
            → ReplenishmentOrderSourceSyncService.syncForMovedStockUnit  UnitloadBusinessService:247
                · replen < STARTED → re-point source (silent)
                · replen >= STARTED → THROW "Replenishment in progress…"   ← INCIDENT (Bug 1 / Fix A1)
    → surface message to wms-mobile-ui                                     ← Fix A1/A2
```

| File | Lines | Role | Fix |
|------|-------|------|-----|
| `ReplenishmentOrderSourceSyncService.java` | 52-63 | in-progress replen block (incident) | A1 |
| `UnitloadBusinessService.java` | 247 | call site in processTransfer | A1 (context) |
| `MobileMoveUnitloadService.java` | 88, 186-203 | move flow / message surfacing | A1 |
| `wms-mobile-ui` move-unitload views | — | show replen-in-progress state | A2 |
| `MobileMoveUnitloadService.java` | 166-183 | `checkReservedStock` dead-end (latent) | B1 |
| `ReplenishorderService.java` | 273-281 | `existsForStockUnit` | B1 |
| `db/migration/V1.26.32__…` (Java callback) | new | reconcile 17 orphans | C1 |

---

## 5. Prerequisites & Implementation Plan

### 5.1 Prerequisites

| # | Prerequisite | Required value / action | Notes |
|---|---|---|---|
| 1 | **🚦 Ops confirmation (BLOCKING)** | WineCo prod deployed commit SHA/build **and** the exact exception text the operator saw | Decides whether Part 1 alone resolves the ticket; do not code before this |
| 2 | **Database state** | Flyway head = **`V1.26.31`**; new migration = **`V1.26.32`** (confirm `ls db/migration/V*.sql \| sort -V \| tail`) | `v1.26.45` is a release **tag**, not a schema version |
| 3 | **Reconciliation target** | Re-run the §1 orphan query at implementation; target set is dynamic (17 today) | callback re-checks at runtime |
| 4 | **Deploy order** | API (Fix A1) before mobile UI (Fix A2), so the UI can rely on the structured message | |
| 5 | Feature flags / sysprops / external systems / access | None new | N/A — no OMS callback on a pure relocation |
| 6 | **Monitoring** | Watch the new `checkReservedStock` stranded-`LOG.warn`; periodic orphan-count query (§1) | detects Part 2 recurrence |

### 5.2 Implementation Checklist

- [ ] **Gate:** ops confirms deployed SHA + exact operator message. Record in §11.
- [ ] **Part 1 — Fix A1:** structured, self-describing block message in `ReplenishmentOrderSourceSyncService:59`; verify propagation through `scanDestination`.
- [ ] **Part 1 — Fix A2:** surface active-replen number/state on the mobile Move Unit Load source-scan view.
- [ ] **Part 2 — Fix B1:** rewrite `checkReservedStock` (exact-id replen continue / active-pick block / stranded warn+allow); preserve child recursion; no broadened lookup.
- [ ] **Part 2 — Fix C1:** Java Flyway callback `V1.26.32` reconciling orphans via `changeReservedAmount`.
- [ ] Unit + Testcontainers + manual tests (§9)
- [ ] `bash sbdocs/9-System/scripts/verify-SBDEV-2610-move-unitload-false-reserved-block.sh` → `0 fail`
- [ ] Code review

---

## 6. File Change Summary

| File | Change | Description |
|------|--------|-------------|
| `ReplenishmentOrderSourceSyncService.java` | Modify | Structured in-progress-replen block message (Fix A1) |
| `MobileMoveUnitloadService.java` | Modify | Surface A1 message; rewrite `checkReservedStock` (Fix B1) |
| `ReplenishorderService.java` | Modify | Holder helper for guard (Fix B1) |
| `wms-mobile-ui` move-unitload view(s) | Modify | Show active-replen state (Fix A2) |
| `db/migration/V1.26.32__reconcile_orphaned_reservedamount` (Java callback) | Add | Reconcile 17 orphans (Fix C1) |
| test classes (below) | Add/Modify | §9 |

---

## 7. V1/V2 Applicability

| Aspect | V1 | V2 | Impact |
|--------|----|----|--------|
| SourceSync in-progress block | present | verify in `wms2-api` | port Fix A1 UX after re-checking v2 shape |
| `checkReservedStock` dead-end | present | present | port Fix B1 |
| Orphaned reservation reconciliation | 17 rows (prod) | check v2 tenants | port Fix C1 as tenant-scoped migration |

**Paired v2 plan (follow-up, deferred):** re-verify the v2 SourceSync/guard independently (do not assume it mirrors the corrected v1 story); apply `@Transactional("tenantTransactionManager", rollbackFor=…)`, `jakarta.*`, ID-based equals, Caffeine eviction on `stockunit` writes, horizontal-scalability checklist, H2-safe migration tests. **Not implemented here.**

---

## 8. Notes — what was dropped and why

- **Dropped "Fix B" (replen release-target rework)** and any split-carry change. Split does not carry `reservedamount` (`StockunitBusinessService:238-286`); the dominant orphan origin is picking/customer-order, so a replen-only release fix would not stop new orphans. If ops confirms the operator saw `"Reserved stock!"` (not `"Replenishment in progress…"`) **and** a replen source-drift is later shown, reopen this. A customer-order/picking release-target audit is a candidate **sibling ticket**.
- SBDEV-2492 (archived) intentionally added the in-progress block; this plan does not revert it.

---

## 9. Test Plan

### Scenarios

| Scenario | Steps | Expected |
|---|---|---|
| In-progress replen blocks move (Bug 1) | replen `state>=STARTED` on the UL's su → Move Unit Load | Blocked with a clear message naming the replen number + "complete or cancel" |
| PROCESSABLE replen re-points, move proceeds | replen `state<STARTED` → Move Unit Load | Source re-pointed silently; move succeeds |
| Mobile surfaces replen state (Fix A2) | scan UL that is an active replen source | UI shows replen number/state before the block |
| Stranded reservation allows move (Fix B1) | `reservedamount>0`, no open replen, no active pick → Move Unit Load | Proceeds; `LOG.warn`; no throw |
| Active pick still blocks (Fix B1) | `pickingorder_position.state<600` on su → Move Unit Load | Throws order-numbered message |
| Child-UL recursion preserved (Fix B1) | reserved child UL under a carrier | guard still evaluates the child |
| Reconciliation (Fix C1) | run callback on DB with orphans | only orphan rows zeroed w/ audit; replen/pick rows untouched; re-run = no-op |

### New / updated tests

| Test class | Method | Asserts |
|---|---|---|
| `ReplenishmentOrderSourceSyncServiceTest` | `startedReplen_blocksWithActionableMessage` | message shape + order number |
| `ReplenishmentOrderSourceSyncServiceTest` | `processableReplen_repointsNoThrow` | re-point, no throw |
| `MobileMoveUnitloadServiceTest` | `checkReservedStock_stranded_allows` | warn + allow |
| `MobileMoveUnitloadServiceTest` | `checkReservedStock_activePick_blocks` | order-numbered throw |
| `MobileMoveUnitloadServiceTest` | `checkReservedStock_childUL_recursion` | recursion preserved |
| `V1_26_32_ReconcileOrphansIT` (Testcontainers) | `zeroesOnlyOrphans_idempotent` | predicate + audit + rerun-safe |

> v1 constraints: Mockito 3.3.3 (no `mockStatic`; set `SecurityContextHolder` directly); compare entities by `.getId().equals()`; native migration → Testcontainers PostgreSQL.

### Manual test plan

| Scenario | Env | Steps | Expected | P/F |
|---|---|---|---|---|
| Reproduce incident | staging (wineco copy) | replen `>=STARTED` on a UL's su; mobile Move Unit Load | Clear "complete or cancel replen REPLxxxxx" message + visible replen state | |
| Cancel-then-move | staging | cancel that replen; retry | Move proceeds | |
| Stranded allow | staging | orphan reservedamount; Move Unit Load | Proceeds without cancel | |
| Reconciliation sanity | staging DB | run migration; re-run §1 orphan query | orphan count → 0; pick/replen rows unchanged | |

### Execution (fill after running)

| Command | Result | counts |
|---|---|---|
| `mvn test -Dtest=ReplenishmentOrderSourceSyncServiceTest,MobileMoveUnitloadServiceTest` | | |
| `mvn verify` | | |
| `bash sbdocs/9-System/scripts/verify-SBDEV-2610-move-unitload-false-reserved-block.sh` | | `Result: N pass, 0 fail` |

### Deliberately-skipped coverage

| What | Why |
|---|---|
| Replen release-target / split-carry | Dropped (§8) — not the incident cause; sibling ticket if reopened |

---

## 10. Open Questions / Resolved Decisions

| # | Item | Resolution |
|---|------|-----------|
| 1 | Incident root cause | **SBDEV-2492 SourceSync `>=STARTED` block**, not `checkReservedStock` (data-proven; §1). Confirm operator message via ops gate. |
| 2 | Keep or soften the in-progress block? | **Keep the block** (a mid-pick replen source must not move); Part 1 makes it clear + visible, not permissive. Confirm at review. |
| 3 | Part 2 in this plan or sibling ticket? | Kept here, clearly separated; **splittable** — reviewer decides. |
| 4 | Broadened `findOpenSourceHolder` lookup | **Dropped** — no drift evidence; false-match risk (architect H2). |
| 5 | Replen release-target rework ("old Fix B") | **Dropped** to sibling ticket — dominant orphan origin is picking/customer-order; split does not carry reservation. |
| 6 | Flyway version | **`V1.26.32`** (head `V1.26.31`). Draft's `V1.26.46` was a release-tag confusion — corrected. |
| 7 | Reconciliation of `MANUAL_ADJUSTMENT` holds | **Zero them** — predicate already scopes to genuine orphans; manual adjust is how operators tried to clear them. |
| 8 | Version scope | v1 now, paired v2 follow-up (requester-confirmed); v2 re-verified independently. |

---

## 11. Implementation Status

_Not implemented. Blocked on the §5.1 ops-confirmation gate. On execution record: deployed SHA + operator message; commit SHA(s) per fix; test names; `mvn`/verify summary; final `verify-…sh` line._

### Completeness checklist (Layer 2)

| # | Concern | Considered? |
|---|---|---|
| 0 | DB verified | ✓ §1 (incident trail + orphan counts on `wms1-wineco`) |
| 1 | All callsites enumerated | ✓ §0 (9 rows) |
| 2 | Adjacent bugs | ✓ #5-7 latent guard/orphans; #8 split-carry ruled out |
| 3 | Backward compatibility | ✓ message text change (additive); reconciliation writes audit rows only |
| 4 | Concurrency | ✓ Fix C1 uses `changeReservedAmount` locked write; migration offline |
| 5 | Multi-tenant | ✓ migration per tenant DB |
| 6 | Error handling | ✓ A1 clearer BusinessException; B1 downgrades stranded to warn |
| 7 | Observability | ✓ §5.1 row 6 |
| 8 | Rollback / migration | ✓ `V1.26.32` Java callback, runtime re-check, idempotent |
| 9 | Test coverage | ✓ §9 |
| 10 | Cross-version | ✓ §7 v2 deferred |

### Recommended OMC composition

| Aspect | Value | Rationale |
|---|---|---|
| Size class | **Standard** | 2 incident fixes + guard rewrite + migration |
| Pre-draft | done (critic + architect this session) | diagnosis corrected |
| Plan-review | (done — this rewrite reflects critic+architect) | |
| Implementation | **executor**, gated on §5.1 ops confirmation | |
| Verification | verify-script + verifier | mandatory |
| Code-review | code-reviewer | guard rewrite + migration |
| Commit | git-master | commits: A1/A2 / B1 / C1 |

**Acceptance script:** `sbdocs/9-System/scripts/verify-SBDEV-2610-move-unitload-false-reserved-block.sh`
