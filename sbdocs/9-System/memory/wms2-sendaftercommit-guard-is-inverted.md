---
name: wms2-sendaftercommit-guard-is-inverted
description: v2 OmsNotificationService.sendAfterCommit guards on isActualTransactionActive being false inside afterCommit, but it is true there
metadata:
  type: project
---

`v2/wms2-api` `OmsNotificationService.sendAfterCommit` decides between deferring and sending
synchronously with `isSynchronizationActive() && isActualTransactionActive()`, and its comment
claims `isActualTransactionActive()=false` "signals the DB TX has already committed (i.e., we are
nested inside an afterCommit callback)".

**That predicate is wrong.** Spring's `AbstractPlatformTransactionManager.processCommit` runs
`triggerAfterCommit()` strictly BEFORE `cleanupAfterCompletion()`, and `actualTransactionActive` is
only reset by the `TransactionSynchronizationManager.clear()` inside cleanup. So inside an
`afterCommit()` callback the flag is still **true** (verified against spring-tx 5.2.12 sources).

Consequence: a *nested* `sendAfterCommit` takes the register-another-synchronization branch, and a
synchronization registered during the synchronization loop is never invoked — **no HTTP POST and no
`message` row at all**, which is worse than v1's failure mode. Four nested sites found on develop:
`ParcelMonitorViewService` ×3 (`palletise`, `palletiseAndTruckLoad`) and
`mobile/MobilePickingService.processPick`.

Filed 2026-09-08 as **SBDEV-3267** (https://app.clickup.com/t/868m2zn9x).

Corroborated on Hydra **prd**: `ORDER_BATCH_PICKING_TOTE_ASSIGNED` has **0** rows ever. The
positive control that makes that zero mean something: **139 of 148** customer orders have
`historytote` set (a tote WAS assigned), and 139 is exactly the PICKING_STARTED / PICKING_FINISHED
row count — same population, 139 assignments, 0 notifications. PALLETIZED (136) and
LOADED_TO_TRUCK (33) are only *partially* broken: their mobile producers are not `@Transactional`
so they take the synchronous fallback and work; the web `ParcelMonitorViewService` ones are dropped.

⚠ `ORDER_BATCH_ON_HOLD` = 0 on Hydra is **NOT** evidence for this bug — `customerOrderOnHold` is
reached only on a direct, non-nested path that this hypothesis predicts works; with 145 released
orders, zero just means nothing went on hold. Do not cite it.

Fix direction is a **deletion**: the outer `registerSynchronization` at the four sites is redundant
because `sendAfterCommit` already defers. Call `manageOrderService.X()` directly inside the tx.

Sibling of [[wms1-aftercommit-message-rows-silently-lost]]; same family as
[[wms2-requires-new-in-lock-holding-tx-deadlock]].
