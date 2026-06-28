---
title: "Restore three replenishment-maintenance triggers on lock-state changes in StockunitService"
ticket: "SBDEV-2033 (follow-up)"
ticket_url: https://app.clickup.com/t/868hyr110
type: feature
priority: medium
status: implemented
project: [wms1]
version: v1
requester: Nam Park
created: 2026-06-26
updated: 2026-06-26
related:
  - sbdocs/3-Resources/reports/260522-sbdev-2033-reserve-amount-adjust-not-sticking.md
  - sbdocs/4-Archieves/wms1/plan/260424-Reserved_Amount_Adjustment_Fix.md
db_verified: "manual — per-env los_sysprop cron check is a manual DB step (see §5.1)"
tags: [plan, replenishment, reservation, wms1]
---

# Restore three replenishment-maintenance triggers on lock-state changes in StockunitService

**Ticket:** [SBDEV-2033 (follow-up)](https://app.clickup.com/t/868hyr110)
**Project:** wms1 | **Version:** v1 | **Type:** feature
**Priority:** medium
**Status:** implemented — 2026-06-26, commit `d3f5ce1` on `fix/SBDEV-2033-restore-availability-triggers`, **PR [#185](https://github.com/SiteBossInc/wms-api/pull/185) → `develop`** (open). TDD-gated (4 positive incl. removeLock QUALITY_FAULT + 2 negatives), all 6 plan tests pass, verify script 9/9. Reviewed: ralplan consensus (Planner → Architect → Critic) + code-reviewer (2 MEDIUM fixed). ⚠️ **Cron prerequisite (§5.1) must be confirmed per env before merge.**
**Date:** 2026-06-26

> Follow-up to SBDEV-2033, addressing Brent Campbell's ClickUp question on whether the removed
> triggers had a good reason. This plan does not have its own ticket; it references SBDEV-2033.

---

## 0. Affected Sites

All line numbers are on `develop` (HEAD). `release` is ~28 lines longer (helper at 623 vs 595) — re-grep on `release` before porting (§8).

| # | File:line (current, `develop`) | Construct | In-scope? | Phase |
|---|---|---|---|---|
| 1 | `StockunitService.java:331` (insert before `return stockUnitUpdated;`) | `setLockOnHold` — restore trigger | **YES — restore** | Phase 1 (impl) |
| 2 | `StockunitService.java:389` (insert after `printLabel(...)` at 387, before `return damagedStock;`) | `setLockDamaged` — restore trigger | **YES — restore** | Phase 1 (impl) |
| 3 | `StockunitService.java:500` (insert after `save` at 498, before `return newStockUnit;`) | `removeLock` — restore trigger | **YES — restore** | Phase 1 (impl) |
| 4 | `StockunitService.java:268–273` ("Intentionally NOT triggering" block in `transferStock`) | `transferStock` (MANUAL_SPLIT) — keep OFF | **NO — keep off** (re-reservation bug) | Negative assertion |
| 5 | `StockunitService.java:452–456` ("Intentionally NOT triggering" block in `adjustReservedAmount`) | `adjustReservedAmount` — keep OFF | **NO — keep off** (re-reservation bug) | Negative assertion |
| 6 | `StockunitService.java:393–430` (`adjustAmount`) | `adjustAmount` — deferred | **NO — deferred / document only** | Out of scope |
| 7 | `StockunitService.java:595–601` | `private void triggerReplenishmentMaintenance(Long itemDataId)` — dead helper, becomes live | **YES** (no edit; becomes live) | Phase 1 |
| 8 | `ReplenishmentOrderMaintenanceService.java:88–106` | `recalculateForItem(Long)` — invoked target | reference | — |
| 9 | `ReplenishmentOrderMaintenanceService.java:108–146` | `recalculateOrder(Replenishorder)` | reference | — |
| 10 | `ReplenishmentOrderMaintenanceService.java:194–248` | `ensureValidSource` / `isSourceUsable` | reference (safety) | — |
| 11 | `ReplenishmentOrderMaintenanceService.java:334–339` | `getAvailableIncludingReservation` | reference (sizing) | — |
| 12 | `ReplenishOrderJob.java:61–97` (guard 65–71) | `doCalculation` cron guard | cron prerequisite | Pre-merge gate |
| 13 | `SchedulingConfiguration.java:118–129` | `replenish()` cron task (hour/minute) | cron prerequisite | Pre-merge gate |
| 14 | `WmsConstants.java:960, 996, 994, 992` | sysprop key constants | reference | Pre-merge gate |
| 15 | `StockunitServiceUnitTest.java` (whole class, 1170+ lines) | test class | **YES — add 3 positive + 1 negative test** | Phase 2 (TDD) |

---

## 1. Problem Statement

`StockunitService.triggerReplenishmentMaintenance(Long itemDataId)` (`StockunitService.java:595–601`) is **dead code — zero callers** on both `develop` and `release`. It was removed from all five of its original call sites by SBDEV-2033.

SBDEV-2033 **over-removed**. The actual re-reservation bug lived in only two of the five call sites — `transferStock` and `adjustReservedAmount` — where a synchronous recalc re-grabbed a source unit-load that had just been moved/split while it was still `NOT_LOCKED` and available (report §5.4: re-grabbed in 53ms; §5.6: 1.7–2s by the same operator). To stop that, SBDEV-2033 stripped **all five** triggers.

The other three — `setLockOnHold`, `setLockDamaged`, `removeLock` — were legitimate (introduced under SBDEV-1742). Their removal means replenishment can keep pointing a pick at stock that was **just damaged or just put on hold** until the next cron cycle. With the replenishment cron cadence at `*`/`*` (every minute — `SchedulingConfiguration.java:118–129`), that is a **stale-source window of up to ~60 seconds** during which operators are directed to pick stock that is no longer pickable. Worse: on **dev**, the cron was historically disabled (this is why SBDEV-2033 did not reproduce on dev), meaning **no recalc at all** — an unbounded stale-source window.

This plan restores exactly the three lock-state triggers while keeping the two buggy ones off, answering Brent Campbell's question: *yes, three of the removed triggers had a good reason; two did not.*

---

## 2. Current Architecture

### 2.1 StockunitService trigger state (all OFF currently)

| Method | Lines | Trigger state | Notes |
|---|---|---|---|
| `transferStock` | 110–273 | OFF | "Intentionally NOT triggering" comment block 268–273 |
| `setLockOnHold` | 275–332 | OFF | save 322 → `sendStockChangeMessage` 328 → return 331 |
| `setLockDamaged` | 334–391 | OFF | `sendStockChangeMessage` 385 → `printLabel` 387 → return 390 |
| `adjustAmount` | 393–430 | OFF | deferred (out of scope) |
| `adjustReservedAmount` | 432–460 | OFF | "Intentionally NOT triggering" comment block 452–456 |
| `removeLock` | 462–502 | OFF | save 498 → return 501 |
| `triggerReplenishmentMaintenance` (helper) | 595–601 | defined, **0 callers** | — |

Helper body (`StockunitService.java:595–601`):
```java
private void triggerReplenishmentMaintenance(Long itemDataId) {
    try {
        replenishmentOrderMaintenanceService.recalculateForItem(itemDataId);
    } catch (Exception e) {
        LOG.warn("replenishment maintenance failed for itemDataId=" + itemDataId, e);
    }
}
```
Best-effort: try/catch swallows + logs, so it **cannot break the host operation or change the return**. `replenishmentOrderMaintenanceService` is already injected (mock present at `StockunitServiceUnitTest.java:46`).

### 2.2 Recalc call chain (the safety mechanism)

`recalculateForItem` → `recalculateOrder` → `ensureValidSource`/`isSourceUsable` → `getAvailableIncludingReservation` → `updateRequestedAmount`:

- **`recalculateForItem`** `ReplenishmentOrderMaintenanceService.java:88–106` — null itemDataId → `recalculateOpenOrders`; else loads PROCESSABLE orders for the item, skips `manuallyoverridepriority`, calls `recalculateOrder` per order inside a try/catch.
- **`recalculateOrder`** `108–146` — re-fetches; bails if not PROCESSABLE; `source = ensureValidSource(...)` (123), null → return; computes shortage (131); ≤ cancelThreshold → `cancelOrder`; `desiredAmount = shortage.min(getAvailableIncludingReservation)` (139); ≤0 → `cancelOrder`; else `updateRequestedAmount` (145).
- **`ensureValidSource`** `194–205` — loads `order.stockunitId`; if `isSourceUsable` → return source; else `redirectSource`; else `cancelOrder` + null.
- **`isSourceUsable`** `207–248` — returns false if source/amount null, amount ≤ 0, `getAvailableIncludingReservation` ≤ 0 (215–218), unitload missing, **`unitload.entityLock != NOT_LOCKED` (224–226)**, no location, location ≠ `requestedlocationId`, **`location.entityLock != NOT_LOCKED` (237–239)**, or location area not `useforreplenish` (240–246).
- **`getAvailableIncludingReservation`** `334–339` — `source.amount − source.reservedamount + order.requestedamount`.
- **`updateRequestedAmount`** `341–355` — delta logic; `changeReservedAmount(source, delta)`; persists `order.requestedamount`.
- **`cancelOrder`** `357–367` — releases reservation + sets state CANCELED (removes from the cron sweep).

The two bolded rejection points (224–226, 237–239) are why restoring the three lock-state triggers is safe: a just-locked or just-relocated UL is rejected as a source.

### 2.3 Cron wiring + sysprop keys

- **Guard** `ReplenishOrderJob.java:65–71` — if `isCronJob` and (`NEW_CRON_JOB_ACTIVATED != true` OR `REPLENISHMENT_TIMER_ACTIVATED != true`) → early return.
- **Recalc call** `ReplenishOrderJob.java:93` — `recalculateOpenOrders(true)`.
- **Schedule build** `SchedulingConfiguration.java:118–129` — cron = `"0 " + minutes + " " + hours + " * * *"`; `*`/`*` → every minute.
- **Registration** `SchedulingConfiguration.java:59` — only if `basicService.isCron()` (i.e. `app.cron=true`).
- **Sysprop keys** (`WmsConstants.java`): `NEW_CRON_JOB_ACTIVATED` 960 (default true 961); `REPLENISHMENT_TIMER_ACTIVATED` 996 (default true 997); `REPLENISHMENT_TIMER_HOUR` 994 (default `*` 995); `REPLENISHMENT_TIMER_MINUTE` 992 (default `*` 993).

---

## 3. Design

Same one-line statement at all three sites, matching the original removed form (`triggerReplenishmentMaintenance(stockUnit.getItemdataId())`, confirmed via `git show 0d6f989`), placed just before the `return` — after persistence and after the `StockChangeDto` message has been sent. Add a short why-this-is-safe comment at each site. (Note: none of the three restore sites carry an "Intentionally NOT triggering" comment on `develop` — those comments live only at the two keep-off sites, `transferStock` 268–273 and `adjustReservedAmount` 452–456. Re-confirm on `release` during the port and remove any stale comment found there.)

**Concurrency note (sync trigger × scheduled cron):** the restored synchronous trigger and the every-minute `ReplenishOrderJob` can both call `recalculateOrder` for the same PROCESSABLE order, so an optimistic-lock collision on `changeReservedAmount` is possible. This is already mitigated and is **not new risk**: the helper swallows + logs any exception (595–601), `recalculateForItem` wraps each order in its own try/catch (101–104), and the cron is the convergent backstop. This is the same interaction the triggers had before SBDEV-2033 removed them — the change restores prior behavior, it does not introduce a new race.

### 3.1 setLockOnHold — insert at line 331 (before `return stockUnitUpdated;`)

```java
triggerReplenishmentMaintenance(stockUnit.getItemdataId());
```

**Why safe (architect-verified against code 2026-06-26):** the method requires `reservedamount == 0` (315–317) and `amount > 0` (311–313), then — *before* the proposed insert point — moves the UL via `transferUnitLoadToLocation(..., CODE_ON_HOLD, ...)` (319), sets `entityLock = ON_HOLD` (320), and persists at `save` (322). The trigger therefore fires on already-committed on-hold state. `isSourceUsable` excludes the unit: it is now at the on-hold location, which is **not a `useforreplenish` source area** (rejected at 240–246), and/or the location/UL is no longer the order's `requestedlocationId` (232–234) — so it cannot be re-grabbed. The recalc only re-points orders at *other* genuinely-available stock for the same item, which is correct. (Precondition `reservedamount==0` also means there was nothing reserved to re-grab.)

### 3.2 setLockDamaged — insert at line 389 (after `printLabel(...)` at 387, before `return damagedStock;`)

```java
triggerReplenishmentMaintenance(stockUnit.getItemdataId());
```
(`stockUnit.getItemdataId()` is the source item; `damagedStock.getItemdataId()` equals it — same SKU.)

**Why safe (architect-verified against code 2026-06-26):** the method requires `availableamount >= amount` (358–360), transfers `amount` to a **new** UL at the DAMAGED location via `transferStockToUnitLoad` (375), locks that new UL's stock unit `QUALITY_FAULT` (376), and saves (378) — all *before* the proposed insert point (line 389). The damaged quantity has genuinely left the source's available pool. The damaged UL is excluded by `isSourceUsable` because it sits at the DAMAGED location (not a `useforreplenish` source area — rejected at 240–246) and is `QUALITY_FAULT`-locked. Argument is `stockUnit.getItemdataId()` (the source item), faithful to the original removed call and equal to `damagedStock.getItemdataId()` (same SKU).

**Partial-damage residual nuance (document, do NOT suppress):** if only part of the source is damaged, the original source UL is left `NOT_LOCKED` and still available. The recalc may then reserve the *remaining* source stock. This is **correct** — that stock is genuinely available — and is **not** the SBDEV-2033 re-grab (which re-reserved stock that had logically left). No change needed; this is expected, desired behavior.

### 3.3 removeLock — insert at line 500 (after `save` at 498, before `return newStockUnit;`)

```java
triggerReplenishmentMaintenance(stockUnit.getItemdataId());
```

**Why safe / actively correct (architect-verified against code 2026-06-26):** clears `entityLock` back to `NOT_LOCKED` (497) and persists at `save` (498) — *before* the proposed insert point (line 500). The stock becomes a valid source again, so re-reserving it for an open shortage is the **intended** outcome — the operator deliberately freed it. This is the one site where triggering is not merely safe but positively desirable.

### 3.4 Dead-code-becomes-live

Helper at 595–601 goes from 0 callers to 3. **No signature change, no new field, no new import.** Pure three-line addition plus comment swaps. `replenishmentOrderMaintenanceService` is already a field and already mocked in the unit test (line 46).

### 3.5 Cron prerequisite (BLOCKING — see §5.1)

After this change, the only **synchronous** recalc paths are these three lock transitions; everything else (including the two intentionally-off sites) relies on the cron sweep. Therefore, before merge to each environment, confirm the cron is actually live:
- `REPLENISHMENT_TIMER_ACTIVATED = true`
- `NEW_CRON_JOB_ACTIVATED = true`
- `REPLENISHMENT_TIMER_HOUR` / `REPLENISHMENT_TIMER_MINUTE` cadence acceptable
- `app.cron = true` on the cron node

Do not assume defaults — **dev historically had cron disabled** (this is why SBDEV-2033 did not reproduce on dev). Prod was `*`/`*`/true/true as of 2026-05-22. Verify per environment via `los_sysprop`.

---

## 4. File Change Summary

| File | Change Type | Description |
|---|---|---|
| `src/main/java/net/aim_ai/wms/service/StockunitService.java` | Modify (×3 sites) | Insert `triggerReplenishmentMaintenance(stockUnit.getItemdataId());` at lines 331 (`setLockOnHold`), 389 (`setLockDamaged`), 500 (`removeLock`); swap any stale "Intentionally NOT triggering" comment for a why-safe comment. Helper 595–601 becomes live (no edit). |
| `src/test/java/net/aim_ai/wms/unit/service/StockunitServiceUnitTest.java` | Modify | Add 3 positive tests (each verifies `recalculateForItem` called once) + 1 new negative test for `transferStock`; keep existing `adjustReservedAmount` negative test. |
| `sbdocs/9-System/scripts/verify-260626-restore-replenishment-triggers-on-lock-state-changes.sh` | Add | Machine-checkable acceptance script (see §9.1). |

---

## 5. Prerequisites & Implementation Plan

### 5.1 Prerequisites

| # | Prerequisite | Required value / action | Owner | Notes |
|---|---|---|---|---|
| 1 | **Replenishment cron live (BLOCKING GATE)** | Per environment, in `los_sysprop`: `REPLENISHMENT_TIMER_ACTIVATED=true`, `NEW_CRON_JOB_ACTIVATED=true`, `REPLENISHMENT_TIMER_HOUR`/`MINUTE` cadence acceptable, **and** `app.cron=true` on the cron node. | Nam Park / DBA | **Merge is blocked** until verified for the target env. Dev was historically cron-off; verify, don't assume. Prod was `*`/`*`/true/true on 2026-05-22. Use `los_sysprop` MCP. |
| 2 | **Database state** | N/A — no schema change, no Flyway migration, no seed rows added by this plan. | — | Only a *read* of `los_sysprop` (row 1). |
| 3 | **Config / env changes** | N/A — no new properties; cron keys are pre-existing (only verified, not changed). | — | — |
| 4 | **Deploy-order dependencies** | N/A — single-service change, no cross-service contract change. | — | — |
| 5 | **Data migration** | N/A — no backfill. | — | — |
| 6 | **External systems** | N/A — no new printer/OMS/Keycloak dependency. | — | — |
| 7 | **Access / permissions** | N/A — no new role/authority. | — | — |
| 8 | **Monitoring / alerts** | Optional: watch for an uptick in swallowed `"replenishment maintenance failed for itemDataId="` WARN logs post-deploy. | Nam Park | Best-effort; the helper already logs at WARN. |

### 5.2 Implementation Checklist

- [ ] **Gate:** confirm cron prerequisite (5.1 row 1) for `develop`'s target env before coding lands.
- [ ] Insert trigger in `setLockOnHold` at line 331; add why-safe comment.
- [ ] Insert trigger in `setLockDamaged` at line 389; add why-safe comment (incl. partial-damage nuance).
- [ ] Insert trigger in `removeLock` at line 500; add why-safe comment.
- [ ] Confirm helper 595–601 is unchanged and now has exactly 3 callers.
- [ ] Add 3 positive unit tests + 1 new `transferStock` negative test (§7).
- [ ] Run `mvn test -Dtest=StockunitServiceUnitTest` (green). **Do NOT run full `mvn verify`** — v1 IT blocked by `ro_id` view drift (SBDEV-2384).
- [ ] Run `verify-260626-restore-replenishment-triggers-on-lock-state-changes.sh` → 0 fail.
- [ ] Code review completed.

---

## 6. Backward Compatibility

| Aspect | Before | After | Impact |
|---|---|---|---|
| `setLockOnHold` / `setLockDamaged` / `removeLock` return value | (un)locked `Stockunit` | identical | None — trigger added after persistence + messaging, inside try/catch |
| Replenishment recalc timing on these 3 transitions | next cron cycle (≤60s, or never on cron-off envs) | synchronous, within the same request | Stale-source window closed for these transitions |
| Exceptions / API contract | host op succeeds | host op succeeds | None — helper swallows + logs; cannot throw |
| `transferStock` / `adjustReservedAmount` behavior | OFF | OFF | None — deliberately unchanged |
| Replenishment cron behavior / sysprop keys | as configured | as configured | None — only verified, never modified |

**Caller set is closed (verified):** the sole caller of all three methods is `StockUnitController.java` (web Handling Units endpoints) — there is **no mobile-service, batch-job, or REST-integration caller, and no bulk/loop call path**. The trigger lives inside the service method, so it is caller-agnostic: any current or future caller gets the same item-scoped recalc (`recalculateForItem` runs the narrow `findByStateAndItemdataId` query for one SKU, bounded cost). No caller enumeration beyond this is required.

### What Does NOT Change
- `transferStock` trigger stays **OFF** (SBDEV-2033 re-reservation bug boundary).
- `adjustReservedAmount` trigger stays **OFF** (same bug boundary).
- `adjustAmount` stays **untriggered / deferred** (out of scope).
- `triggerReplenishmentMaintenance` helper body — **unchanged** (only becomes live).
- Cron wiring, sysprop keys, and defaults — **unchanged** (only verified per env).

---

## 7. Test Plan

Test class: `net.aim_ai.wms.unit.service.StockunitServiceUnitTest`. Mock of `replenishmentOrderMaintenanceService` present at line 46. **Mockito 3.3.3 — no `mockStatic()`.**

### New / updated tests

| Test class | Test method | What it asserts |
|---|---|---|
| `StockunitServiceUnitTest` | `setLockOnHold_*_triggersReplenishmentMaintenance` | `verify(replenishmentOrderMaintenanceService, times(1)).recalculateForItem(itemDataId)` on happy path (build on existing `setLockOnHold` test) |
| `StockunitServiceUnitTest` | `setLockDamaged_*_triggersReplenishmentMaintenance` | same, on the validated/unlocked path (build on `setLockDamaged_validUnlockedStock_createsDamagedStockUnit`, ~306–342) |
| `StockunitServiceUnitTest` | `removeLock_triggersReplenishmentMaintenance` | same, ON_HOLD removal path (build on `removeLock_onHoldLock_removesLockAndSendsMessage`) |
| `StockunitServiceUnitTest` | `removeLock_qualityFault_triggersReplenishmentMaintenance` | **NEW** (added per code review): same, QUALITY_FAULT removal branch |
| `StockunitServiceUnitTest` | `transferStock_doesNotTriggerReplenishmentMaintenance` | **NEW** (closes a current gap): `verify(replenishmentOrderMaintenanceService, never()).recalculateForItem(any())` |
| `StockunitServiceUnitTest` | `adjustReservedAmount_doesNotTriggerReplenishmentMaintenance` | **KEEP** existing (749–768) — negative assertion stays green |

### Test scenarios

| Scenario | Steps | Expected Result |
|---|---|---|
| Put-on-hold triggers recalc | Call `setLockOnHold` on a valid unlocked stock unit | `recalculateForItem` called once with the item's id |
| Damage triggers recalc | Call `setLockDamaged` on validated stock | `recalculateForItem` called once |
| Unlock triggers recalc | Call `removeLock` on a locked UL | `recalculateForItem` called once |
| Split (transferStock) does NOT trigger | Call `transferStock` (MANUAL_SPLIT) | `recalculateForItem` never called |
| Reserved-amount adjust does NOT trigger | Call `adjustReservedAmount` | `recalculateForItem` never called |

### Manual test plan

| Scenario | Environment | Steps | Expected Result | Pass/Fail |
|---|---|---|---|---|
| Damage a replen source | staging | Pick a UL that is the source of an open PROCESSABLE replenish order; damage it via Handling Units | Replenish order recalcs (redirected/cancelled), no longer points at the damaged UL | |
| Hold a replen source | staging | Put a replen-source UL on hold | Order recalcs; held UL no longer used as source | |
| Unlock previously-held stock | staging | Remove the hold from a UL with an open shortage for the item | Order re-reserves the freed stock | |
| Cron sysprop check | staging DB / per env | `SELECT syskey, sysvalue FROM los_sysprop WHERE syskey IN ('REPLENISHMENT_TIMER_ACTIVATED','NEW_CRON_JOB_ACTIVATED','REPLENISHMENT_TIMER_HOUR','REPLENISHMENT_TIMER_MINUTE');` plus confirm `app.cron=true` on cron node | All four present with expected values; cron node has `app.cron=true` | |

### Test execution (run 2026-06-26 — branch `fix/SBDEV-2033-restore-availability-triggers`)

| Command | Result | Pass / Fail / Skipped counts |
|---|---|---|
| `mvn test -Dtest=StockunitServiceUnitTest#<plan's 6 tests>` (3 positive + removeLock QUALITY_FAULT + 2 negatives) | **PASS** | Tests run: 6, Failures: 0, Errors: 0 |
| `bash verify-260626-...sh` (clean shell) | **PASS** | Result: 9 pass, 0 fail, 0 skip (exit 0) |
| `mvn test -Dtest=StockunitServiceUnitTest` (full class) | 1 PRE-EXISTING error (not this change) | Tests run: 55, Failures: 0, Errors: 1 — see skipped-coverage note |
| `mvn verify` | **SKIP** — v1 IT blocked by `ro_id` view drift (SBDEV-2384) | |

TDD baseline (before implementation): the 3 positive tests failed with `WantedButNotInvoked` (correct failure); the 2 negatives passed. After restoring the 3 triggers, all 5 pass.

### Deliberately-skipped coverage

| What | Why |
|---|---|
| `transferStock_toNewLocation_nonFlowbin_entireStockUnit_noFla_movesUnitload` (existing test, NPE at :1138) | **Pre-existing failure on `develop`, NOT caused by this change** — confirmed by running it with this plan's changes stashed (still NPEs). Root cause: the 260624 stock-unit-history work added `stockrecordService` to the transfer path and this older test doesn't stub it. Out of scope here; should be fixed alongside that work. The plan's verify script scopes `T-unit` to the 5 plan tests so the gate isn't held hostage by this. |
| Full `mvn verify` / Testcontainers ITs | v1 IT lane blocked by `ro_id` view drift (SBDEV-2384) — would fail at context load for unrelated reasons |
| `adjustAmount` test | Out of scope (deferred); optional guard test only |

---

## 8. Rollout

1. Branch from `develop`: `fix/SBDEV-2033-restore-availability-triggers`.
2. Implement the 3 sites + tests; run `mvn test -Dtest=StockunitServiceUnitTest` and the verify script.
3. Confirm cron prerequisite (§5.1 row 1) for the `develop` target env.
4. PR → `develop`.
5. **Port to `release`:** the substance is identical on both branches, but `release` is ~28 lines longer (helper at 623, not 595). **Re-grep `release`** for the three method bodies before inserting — develop line numbers will not transfer. Re-run the verify script (with `PROJECT_ROOT` pointing at the release checkout) and re-confirm the cron prerequisite for release's env.

---

## 9. Alternatives Considered

| Option | Description | Verdict |
|---|---|---|
| (a) Restore all 5 | Restore the trigger at all five original sites incl. `transferStock` + `adjustReservedAmount` | **Rejected** — reintroduces the SBDEV-2033 re-reservation bug; the source UL stays `NOT_LOCKED` & available and is re-grabbed within ms (report §5.4: 53ms; §5.6: 1.7–2s same operator) |
| (b) Restore none | Rely solely on the cron sweep | **Rejected** — ≤60s stale-source window directs picks to absent stock; on cron-off envs (historically dev) no recalc at all. Defeats the purpose of Brent's question |
| (c) Add `cancelOrder`-guard to `transferStock` | Add a guard so `transferStock` can also be safely restored | **Deferred** — plausible, but a larger, separately-scoped follow-up; see §10 open questions |
| (d) Restore 3 + `adjustAmount` | Also restore on quantity edits | **Deferred** — low marginal value, widens scope/test surface for a path with no reported defect (locked decision 2) |

### 9.1 Acceptance script

Machine-checkable acceptance lives at:
`sbdocs/9-System/scripts/verify-260626-restore-replenishment-triggers-on-lock-state-changes.sh`

Positive checks: `triggerReplenishmentMaintenance(stockUnit.getItemdataId())` appears 3 times in `StockunitService.java` and within each of the three method bodies. Negative checks: it is absent from the `transferStock`, `adjustReservedAmount`, and `adjustAmount` bodies. Plus a `run` line for `mvn_test_passes StockunitServiceUnitTest`.

**Toolchain + executed-result note (2026-06-26):** the script is **awk-implementation-agnostic** — it deliberately avoids ERE interval quantifiers (`{n}`) because the default `awk` on this box / CI images is `mawk 1.3.4`, which panics on intervals. Method-body scoping uses literal-space anchors instead. Closed-loop verified under mawk:
- **Pre-implementation baseline (current `develop`):** `4 pass, 5 fail` — the 4 positive trigger checks FAIL (not yet implemented), `P-helper` + the 3 negatives PASS. (`T-unit` fails only because maven needs the SDKMAN PATH export — not a logic failure.)
- **Simulated correct implementation** (trigger inserted at the 3 sites): all 8 grep checks PASS.
- **Regression injection** (trigger added to `transferStock`): `N-split` correctly flips to **FAIL** — proving the negative checks bite, not pass vacuously.

### 9.2 Recommended OMC composition

| Aspect | Value | One-line rationale |
|---|---|---|
| **Size class** | Standard | 3 call sites + tests in a single service |
| **Pre-draft step** | analyst+planner (done via this ralplan loop) | consensus draft |
| **Plan-review step** | critic (optional) | low blast radius; critic optional |
| **Implementation shape** | executor | single subsystem, mechanical inserts |
| **Verification step** | verify-script + verifier | mandatory |
| **Code-review step** | none (executor + verifier sufficient) | small surface |
| **Commit step** | git directly | single logical commit |

---

## 10. Open Questions / Resolved Decisions

### Resolved (locked decisions — do NOT re-litigate)
1. **Rollout:** `develop` first, then port to `release` (normal GitFlow; not a hotfix).
2. **`adjustAmount`:** out of scope / deferred (documented only).
3. **Cron prerequisite is BLOCKING per environment:** `REPLENISHMENT_TIMER_ACTIVATED` + `NEW_CRON_JOB_ACTIVATED` both true, `REPLENISHMENT_TIMER_HOUR`/`MINUTE` cadence acceptable, `app.cron=true` on the cron node — verified before merge (§5.1 row 1).

### Open (fill at rollout)
- Per-env cron verification **results** (dev → release/QA → prod) — to be recorded in §5.1 at rollout. Dev historically cron-off; prod was `*`/`*`/true/true on 2026-05-22.
- Whether a future plan adds the `transferStock` `cancelOrder`-guard (alternative (c)) so that site can also be safely restored.
- v2 migration follow-up (`wms2-api`) — expected later but **gated on the v2 IT harness fix (SBDEV-2217)**; do not start the v2 port until that harness boots.
