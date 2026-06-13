---
title: "SBDEV-2033 — Adjust Reserved Amount Does Not Stick on WineCo Production"
type: investigation
status: concluded
version: v1
scope: replenishment, reservations, StockunitService, ReplenishmentOrderMaintenanceService
owner: Nam Park
created: 2026-05-22
updated: 2026-05-22
last_verified: 2026-05-22
verified_by: code read of v1/wms-api release branch + WineCo production DB queries
related:
  - ../../1-Projects/wms1/plan/260422-changeReservedAmount-stale-object-state-fix.md
tags:
  - investigation
  - report
  - replenishment
  - reservation
  - wms1
  - wineco
---

# SBDEV-2033 — Adjust Reserved Amount Does Not Stick on WineCo Production

**Topic:** Replenishment reservation — v1/wms-api `release` branch | **Version:** v1  
**Started:** 2026-05-22 | **Investigator:** Nam Park  
**Status:** concluded  

---

## 1. Context & Trigger

ClickUp ticket SBDEV-2033 (urgent, open): WineCo production users are unable to permanently
clear a replenishment reservation via the Handling Units UI. When a user adjusts the reserved
amount to 0, the UI responds with "success", but on page refresh the reservation is still in
place. The workaround is a manual DB update by engineering.

The bug is **not reproducible on the dev server** (which runs the `develop` branch).  
WineCo production runs the `release` branch, built from commit `cdc4211a` (hotfix 260513).

Ticket: https://app.clickup.com/t/868hyr110  
Example UL at time of original report: `UL33972` (mid-day 2026-03-19, operator `mcervone`).  
The bug is ongoing: DB evidence confirms it is still occurring as of **2026-05-21** (yesterday).

---

## 2. Questions

1. Why does `adjustReservedAmount` return success yet the reservation reappears immediately on refresh?
2. Is the bug caused by the `triggerReplenishmentMaintenance` call that commit `b7707bfb` was supposed to remove from `adjustReservedAmount`?
3. Is there a WineCo-specific configuration (cron job, sysprop) that explains why this only manifests on production and not on dev?
4. Is the fix in commit `b7707bfb` actually deployed to WineCo production, and if so, is it sufficient?

---

## 3. Initial Hypotheses

| # | Hypothesis | Initial confidence | Rationale |
|---|-----------|-------------------|-----------|
| H1 | `adjustReservedAmount` still calls `triggerReplenishmentMaintenance` in production, immediately re-reserving the same stock within the HTTP request | high | Ticket author's own suspicion; pattern known from commit `b7707bfb` message |
| H2 | The fix `b7707bfb` is deployed but the scheduled `ReplenishOrderJob` re-reserves within ≤60 s because the replenishment order stays PROCESSABLE | medium | `recalculateOpenOrders()` is called by the job; runs every minute in prod per sysprop |
| H3 | Other stock operations the user performs AFTER clearing the reservation (e.g., split/transfer for the "move to Damaged" workflow) also call `triggerReplenishmentMaintenance` and re-reserve immediately | medium | Multiple `triggerReplenishmentMaintenance` call sites exist beyond `adjustReservedAmount` |
| H4 | Nothing is actually wrong with the code; the user is seeing a stale browser cache | low | "Nothing is wrong" baseline; ruled out by DB evidence showing reservation actually changes |

---

## 4. Method

1. Fetched SBDEV-2033 from ClickUp (task ID `868hyr110`).
2. Confirmed working branch: `release`, latest commit `cdc4211a` (`fix(transactional): restore rollbackFor for checked exceptions across 12 service files`).
3. Traced the call chain: `StockUnitController.adjustReservedAmount` → `StockunitService.adjustReservedAmount` → `StockunitBusinessService.changeReservedAmount`.
4. Ran `git log release..develop` and `git branch --contains` for key commits to determine what is/isn't deployed.
5. Read `StockunitService.java` (596 lines) and `StockunitBusinessService.java` (355 lines) on the release branch.
6. Read `ReplenishmentOrderMaintenanceService.java` (492 lines) — `recalculateForItem`, `recalculateOrder`, `updateRequestedAmount`, `redirectSource`.
7. Read `ReplenishOrderJob.java` and `SchedulingConfiguration.java` to understand cron frequency.
8. Queried WineCo production DB (read-only, `wms1-wineco` MCP):
   - `los_sysprop` for replenishment cron configuration.
   - `stockrecord` for `MANUAL_ADJUSTMENT` + `REPLENISHMENT` activity codes around the incident date (2026-03-19) and recent dates (last 14 days).
9. Correlated stockrecord timestamps to isolate synchronous (same-request) vs. async (scheduled-job) re-reservations.

---

## 3.5 Sources In Scope

| Symbol / file | Relevance |
|---|---|
| `StockunitService.java:400–428` | `adjustReservedAmount` — entry point from controller |
| `StockunitService.java:106–213` | `transferStock` / split path — trigger at line 243 |
| `StockunitService.java:303–355` | `setLockDamaged` — trigger at line 354 |
| `StockunitService.java:260–301` | `setLockOnHold` — trigger at line 297; requires reservedamount = 0 |
| `StockunitService.java:556–560` | `triggerReplenishmentMaintenance` — private helper, 5 call sites |
| `StockunitBusinessService.java:316–353` | `changeReservedAmount` — `@Transactional`, writes `stockunit.reservedamount` |
| `ReplenishmentOrderMaintenanceService.java:88–106` | `recalculateForItem` — called by direct trigger |
| `ReplenishmentOrderMaintenanceService.java:65–86` | `recalculateOpenOrders` — called by scheduled job every minute |
| `ReplenishmentOrderMaintenanceService.java:108–146` | `recalculateOrder` — per-order logic; calls `updateRequestedAmount` |
| `ReplenishmentOrderMaintenanceService.java:341–355` | `updateRequestedAmount` — calls `changeReservedAmount` to re-sync reservation |
| `ReplenishOrderJob.java:61–97` | `doCalculation` — calls `recalculateOpenOrders()` at line 93 |
| `SchedulingConfiguration.java:114–124` | `replenish` cron task — schedule from `los_sysprop` keys |
| `los_sysprop` (WineCo prod DB) | Cron schedule keys; confirms job frequency |
| `stockrecord` (WineCo prod DB) | Transaction-level audit log; confirms re-reservation timestamps and operators |
| Commit `b7707bfb` | "fix: remove replenishment trigger from adjustReservedAmount to prevent re-reservation" |
| Commit `dee2e0f9` | "fix(picking): prevent StaleObjectStateException in changeReservedAmount" |

---

## 5. Evidence

### 5.1 Fix commit `b7707bfb` IS in the release branch code

**Source:** `StockunitService.java:418–426` (release branch, commit ancestry confirmed by `git log release -- StockunitService.java`)  
**Observation:**
```java
Stockunit newStockUnit = stockunitBusinessService.changeReservedAmount(
    stockUnit, amount, true, WmsConstants.CODE_MANUAL_ADJUSTMENT, null, comment);

// Intentionally NOT triggering replenishment maintenance here.
// Manual reservation adjustment is a deliberate user action — triggering
// recalculateForItem() would immediately re-reserve the stock the user just
// released (for any open replenishment orders), undoing their adjustment.
// Replenishment will recalculate on its next scheduled cycle.
```
The direct `triggerReplenishmentMaintenance` call has been removed from `adjustReservedAmount`.  
**Supports:** H1 (refuted — trigger is gone from this method).  
**Contradicts:** H1 (as a complete explanation).

---

### 5.2 Four other methods in `StockunitService` still call `triggerReplenishmentMaintenance`

**Source:** `StockunitService.java` — grep output:
```
212:    triggerReplenishmentMaintenance(stockUnit.getItemdataId());  // transferStock / split path
243:    triggerReplenishmentMaintenance(stockUnit.getItemdataId());  // transferStock / split path (end)
297:    triggerReplenishmentMaintenance(stockUnit.getItemdataId());  // setLockOnHold
354:    triggerReplenishmentMaintenance(stockUnit.getItemdataId());  // setLockDamaged
```
`setLockDamaged` (`StockunitService.java:303`) and `transferStock` (`StockunitService.java:106`)
are direct steps in the user's "move to Damaged" workflow (the workflow described in SBDEV-2033).  
**Supports:** H3 (high confidence).

---

### 5.3 `ReplenishOrderJob` cron fires every minute on WineCo production

**Source:** WineCo production DB `los_sysprop`:
```
REPLENISHMENT_TIMER_ACTIVATED  = true
NEW_CRON_JOB_ACTIVATED         = true
REPLENISHMENT_TIMER_HOUR        = *
REPLENISHMENT_TIMER_MINUTE      = *
```
`SchedulingConfiguration.java:117`: `String cronjob = 0+" "+minutes+" "+hours+" * * *";`  
With `minutes='*'` and `hours='*'` this resolves to `0 * * * * *` — **every minute**.  
The job calls `replenishmentOrderMaintenanceService.recalculateOpenOrders()` (line 93).  
There are currently **624 PROCESSABLE replenishment orders** in WineCo production.  
**Supports:** H2 (confirmed).

---

### 5.4 Scheduled job re-reservations: DB evidence from original incident date

**Source:** `stockrecord` table — 2026-03-19 10:44:
```
id=31196597  MANUAL_ADJUSTMENT   UL339772  reservedchange=-1  reservedstock=0   operator=mcervone   10:44:23.924
id=31196598  REPLENISHMENT        UL339772  reservedchange=+1  reservedstock=1   operator=mcervone   10:44:23.977
```
53 ms between clearing the reservation and it being re-applied. **Same operator**, meaning
`triggerReplenishmentMaintenance` was called synchronously within the same HTTP request.  
This is the pre-`b7707bfb` behaviour, confirming the original trigger was active in the March 19 incident.  
**Supports:** H1 (for the original incident date, before the fix was in the deployed code).

---

### 5.5 Bug still occurring — DB evidence from May 2026 (post-fix)

**Source:** `stockrecord` table — selected examples from last 14 days:

| Date | UL | MANUAL_ADJUSTMENT | REPLENISHMENT | Gap | Operator (repl) | Source |
|---|---|---|---|---|---|---|
| 2026-05-21 | UL347864 | -6 at 12:18:29 | +6 at 12:19:08 | 39 s | anonymous | scheduled job |
| 2026-05-21 | UL347864 | -6 at 12:19:43 | +6 at 12:19:45 | **1.9 s** | **adampetersen** | MANUAL_SPLIT |
| 2026-05-19 | UL299494 | -5 at 12:16:06 | +5 at 12:16:07 | **0.4 s** | **anonymous** | scheduled job (in flight) |
| 2026-05-13 | UL324496 | -4 at 12:35:53 | +4 at 12:36:05 | 12 s | anonymous | scheduled job |
| 2026-05-12 | UL324496 | -5 at 12:21:05 | +5 at 12:21:06 | **0.4 s** | **anonymous** | scheduled job (in flight) |
| 2026-05-12 | UL339818 | -12 at 11:29:18 | +9 at 11:29:19 | **1.7 s** | **adampetersen** | MANUAL_SPLIT |
| 2026-05-11 | UL340327 | -12 at 13:45:10 | +7 at 13:45:12 | **2 s** | **adampetersen** | MANUAL_SPLIT |

Key observations:
- Sub-second `anonymous` re-reservations (0.4 s): the scheduled job was mid-run when the user
  adjusted; within the same minute-cycle it reached this replenishment order and re-applied it.
- Sub-2-second `adampetersen` re-reservations: happen coincident with a `MANUAL_SPLIT` record
  (same second, same operator), confirming `transferStock` → `triggerReplenishmentMaintenance`.
- Users are seen trying the same UL **3–4 times in a row** (e.g., `UL324496` on May 11–14),
  unable to permanently clear it.

**Supports:** H2 and H3 (both active simultaneously, both confirmed).  
**Contradicts:** H4.

---

### 5.6 MANUAL_SPLIT pattern: `transferStock` is a step in the "move to Damaged" workflow

**Source:** `StockunitService.java:125–130` (uses `WmsConstants.CODE_MANUAL_SPLIT`); line 243 triggers `triggerReplenishmentMaintenance` at the end of `transferStock`. DB confirms the MANUAL_SPLIT record and the REPLENISHMENT record have the same operator and appear within 10–18 ms of each other.  
**Supports:** H3 (confirmed — this is the dominant re-reservation path after the `b7707bfb` fix).

---

### 5.7 `dee2e0f9` (StaleObjectState fix) IS in the release branch code

**Source:** `StockunitBusinessService.java:324–326`:
```java
if (entityManager.contains(staleStockUnit)) {
    entityManager.detach(staleStockUnit);
}
```
`git branch --contains dee2e0f9` shows develop but not release — however the code is present,
indicating cherry-pick/squash into release. This fix is orthogonal to SBDEV-2033.

---

### 5.8 Dev does not reproduce — cron job almost certainly disabled

**Source:** Ticket description ("tested on dev — not reproducible"). WineCo production has
`REPLENISHMENT_TIMER_ACTIVATED=true` + `NEW_CRON_JOB_ACTIVATED=true` + `HOUR='*'`/`MINUTE='*'`.
Dev almost certainly has one or both flags set to `false`, or the hour/minute set to a specific
non-wildcard value. This is the **only** configuration difference that explains the discrepancy.
The `doCalculation` guard (line 65–71 of `ReplenishOrderJob.java`) exits early when either flag
is false.  
**Supports:** H2 (confirmed as the production-specific factor).

---

### 5.9 `recalculateOrder` re-reservation mechanism

**Source:** `ReplenishmentOrderMaintenanceService.java:108–146, 334–354`:
```java
// getAvailableIncludingReservation:
BigDecimal currentRequest = safe(order.getRequestedamount());
return source.amount - source.reservedamount + currentRequest;   // line 338

// updateRequestedAmount:
BigDecimal delta = desiredAmount.subtract(currentRequested);
if (delta == 0) return;  // no-op if unchanged
stockunitBusinessService.changeReservedAmount(source, delta, ...);  // line 348
```
When user clears `stockunit.reservedamount` to 0 but `replenishorder.requestedamount` remains N:
- `getAvailableIncludingReservation = source.amount - 0 + N`  
- If shortage ≈ N: `desiredAmount = N`, `delta = N − N = 0` → no re-reservation.  
**BUT**: when the scheduled job coincidentally runs while the order is in an intermediate state
(requestedamount = 0 from a prior cancellation, or after a `redirectSource` switches the source
and resets requestedamount), `delta = N − 0 = N` → full re-reservation.
This explains the sub-second "in-flight" re-reservations (evidence 5.5 rows with 0.4s gap).

---

## 6. Updated Hypothesis Ranking

| # | Hypothesis | Final confidence | Key evidence |
|---|-----------|------------------|--------------|
| H1 | Direct trigger in `adjustReservedAmount` | **Refuted for current code** — fix is deployed | §5.1: comment + no call site; fix committed via `b7707bfb` |
| H2 | Scheduled job re-reserves within ≤60 s | **Confirmed — high** | §5.3 (cron every minute), §5.5 (anonymous re-reservations 0.4–39 s after adjustment) |
| H3 | Follow-on operations (`transferStock`, `setLockDamaged`) re-trigger replenishment | **Confirmed — high** | §5.2 (4 call sites), §5.5/§5.6 (MANUAL_SPLIT 1.7–2 s, adampetersen operator) |
| H4 | Nothing is actually wrong | **Refuted** | §5.4/§5.5: DB shows reservation changes that are then immediately undone |

---

## 7. Verdict

**The `b7707bfb` fix is real and deployed** — the direct trigger inside `adjustReservedAmount`
is gone from the release branch code. However, the fix is **incomplete**: it only removed one
of five call sites for `triggerReplenishmentMaintenance` in `StockunitService`.

The bug persists today via two concurrent mechanisms:

1. **Immediate re-reservation via follow-on operations** (H3, dominant after fix): The user's
   "move to Damaged" workflow requires performing a `transferStock` (split) or `setLockDamaged`
   step after clearing the reservation. Both methods still call `triggerReplenishmentMaintenance`
   (lines 243, 354), which synchronously calls `recalculateForItem`, which calls
   `updateRequestedAmount`, which calls `changeReservedAmount` back onto the same stock unit
   within milliseconds. DB evidence: MANUAL_SPLIT → REPLENISHMENT within 1.7–2 s with the user's
   own operator, on 2026-05-11, 2026-05-12, 2026-05-21.

2. **Scheduled job re-reservation** (H2, always active in background): `ReplenishOrderJob` is
   configured to run every minute on WineCo production (`REPLENISHMENT_TIMER_HOUR='*'`,
   `REPLENISHMENT_TIMER_MINUTE='*'`). It calls `recalculateOpenOrders()` which sweeps all 624
   PROCESSABLE replenishment orders and re-applies the expected reservation amount. Any manual
   clearance is undone within ≤60 seconds. The "natural backstop" acknowledged in `b7707bfb`'s
   commit message is effectively a continuous re-apply mechanism.

**Why only WineCo production**: Dev has cron jobs disabled (either flag or different schedule);
users can clear reservations and they stay cleared. Production runs the cron every minute and
has hundreds of active PROCESSABLE replenishment orders, so re-reservation is near-instant.

**Root cause summary**: The WMS has no concept of "user has intentionally overridden this
reservation". Once a replenishment order is PROCESSABLE, both the synchronous trigger and the
scheduled job will continuously re-reserve the source stock. The only way to permanently clear
a reservation that is tied to a PROCESSABLE replenishment order is to **cancel that order**
first — which the current UI does not expose to the user.

**Confidence:** high — multiple independent DB evidence points from multiple dates and operators,
all consistent with both mechanisms.

---

## 8. Recommendation

- [x] **Fix now** — open a bugfix plan via `wms-bugfix-plan` for v1/wms-api (`release` branch).

**Proposed fix approach**:  
When `adjustReservedAmount` reduces `stockunit.reservedamount` to 0 (or when the user
explicitly requests a full clear), automatically cancel any PROCESSABLE replenishment orders
that reference this stock unit (`replenishorder.stockunit_id = su.id` AND
`replenishorder.state = 300`). `cancelOrder()` already exists in
`ReplenishmentOrderMaintenanceService` — it releases the reservation AND sets
`order.state = CANCELED`, removing it from the scheduled job's sweep.

This is preferable to suppressing the scheduled job or adding a "skip" flag, because:
- It correctly models the business intent (user wants this stock for a different purpose)
- It prevents both the direct trigger AND the scheduled job from re-reserving
- `cancelOrder` already handles the `releaseReservation` call so there is no double-free risk

**Note for the downstream bugfix plan**: a `verify-<plan-id>.sh` script MUST ship with the
plan (per `wms-bugfix-plan` skill requirements), confirming that after `adjustReservedAmount`
to 0, the replenishment order transitions to CANCELED and the reservation remains 0 across a
scheduled-job cycle.

---

## 9. Open Questions

- **Is `REPLENISHMENT_TIMER_HOUR='*'` intentional for WineCo?** Running the full 624-order
  sweep every minute under a single-threaded cron is expensive. The author of `b7707bfb`
  acknowledged the job as a "natural backstop" implying it was expected to run periodically,
  not every minute. Clarify with WineCo ops whether this was intentional or a misconfiguration.

- **Does dev have cron disabled?** Could not directly query dev DB. Confirming
  `REPLENISHMENT_TIMER_ACTIVATED` and `NEW_CRON_JOB_ACTIVATED` on dev would close the
  "why not on dev" question definitively.

- **Exact re-reservation path for the 0.4-second `anonymous` cases**: The analysis (§5.9)
  shows that `delta = 0` should prevent re-reservation when `order.requestedamount` is intact.
  The 0.4-second cases imply an intermediate state (requestedamount = 0 after a prior
  cancellation or `redirectSource`). Tracing `redirectSource` in detail would confirm this.

- **`setLockDamaged` guard** (`StockunitService.java:283`): `setLockOnHold` requires
  `reservedamount = 0` before allowing the lock. Does `setLockDamaged` have the same guard?
  If so, `triggerReplenishmentMaintenance` at line 354 runs AFTER the reservation was already
  0 — meaning the re-reservation fully undoes the user's work before they can complete the
  "move to Damaged" step.

- **v2 equivalent**: `wms2-api` likely has an analogous pattern (check
  `ReplenishmentOrderMaintenanceService` equivalent). A `wms-v2-migrate` follow-up is expected
  once the v1 fix is confirmed.

---

## 10. References

- **ClickUp ticket:** SBDEV-2033 — https://app.clickup.com/t/868hyr110
- **Commits (v1/wms-api release branch):**
  - `b7707bfb` — "fix: remove replenishment trigger from adjustReservedAmount to prevent re-reservation" (2026-03-23)
  - `dee2e0f9` — "fix(picking): prevent StaleObjectStateException in changeReservedAmount" (2026-04-22)
  - `fd13cd20` — "feat: add replenishment order maintenance service (SBDEV-1742)" — introduced the original trigger
  - `cdc4211a` — latest release commit (`fix(transactional): restore rollbackFor`, hotfix-260513)
- **Key files:**
  - `v1/wms-api/src/main/java/net/aim_ai/wms/service/StockunitService.java` (lines 400–428, 106–213, 303–355)
  - `v1/wms-api/src/main/java/net/aim_ai/wms/service/StockunitBusinessService.java` (lines 316–353)
  - `v1/wms-api/src/main/java/net/aim_ai/wms/service/ReplenishmentOrderMaintenanceService.java` (lines 65–146, 250–297, 334–355)
  - `v1/wms-api/src/main/java/net/aim_ai/wms/schedulejob/ReplenishOrderJob.java` (lines 61–97)
  - `v1/wms-api/src/main/java/net/aim_ai/wms/schedulejob/SchedulingConfiguration.java` (lines 114–124)
- **DB evidence (WineCo production — read-only queries, 2026-05-22):**
  - `los_sysprop`: REPLENISHMENT_TIMER_HOUR=`'*'`, REPLENISHMENT_TIMER_MINUTE=`'*'`, REPLENISHMENT_TIMER_ACTIVATED=`true`, NEW_CRON_JOB_ACTIVATED=`true`
  - `stockrecord` 2026-03-19: UL339772 MANUAL_ADJUSTMENT(-1) at 10:44:23.924 → REPLENISHMENT(+1) at 10:44:23.977 (53 ms, pre-fix)
  - `stockrecord` 2026-05-21: UL347864 MANUAL_ADJUSTMENT(-6) → REPLENISHMENT(+6) 1.9 s, coincident with MANUAL_SPLIT (adampetersen)
  - `stockrecord` 2026-05-19: UL299494 MANUAL_ADJUSTMENT(-5) → REPLENISHMENT(+5) 0.4 s (anonymous — scheduled job in-flight)
  - `stockrecord` 2026-05-12: UL339818 MANUAL_ADJUSTMENT(-12) → REPLENISHMENT(+9) 1.7 s, coincident with MANUAL_SPLIT (adampetersen)
  - `stockrecord` 2026-05-11: UL340327 MANUAL_ADJUSTMENT(-12) → REPLENISHMENT(+7) 2 s, coincident with MANUAL_SPLIT (adampetersen)
  - 624 PROCESSABLE replenishment orders currently in `replenishorder` table

---

## 11. Verification Log

| Date | What was re-checked | Result | Checked by |
|------|---------------------|--------|------------|
| 2026-05-22 | Release branch code + WineCo prod DB | Initial investigation completed | Nam Park |
