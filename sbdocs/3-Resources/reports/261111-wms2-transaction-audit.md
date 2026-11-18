---
title: "WMS v2 transaction audit — propagation, locking, side effects, jobs"
type: investigation-report
status: complete
version: v2
scope: wms2-api
owner: Nam Park
created: 2026-11-11
updated: 2026-11-11
related:
  - ../architecture/wms2-transaction-osiv-boundary-map.md
  - ../architecture/wms2-oms-integration-map.md
  - ../architecture/wms2-scheduled-jobs-catalog.md
  - ./260507-picking-lock-ordering-inconsistency.md
tags: [investigation, transactions, concurrency, locking, wms2]
trigger: "Ad-hoc request 2026-11-11: audit WMS v2 transactions for bugs/weaknesses"
audited_ref: "v2/wms2-api origin/develop df30fa62 (detached worktree, read-only)"
verdict_summary: "Core transaction plumbing is sound (no mis-routed TM, no silently-joined REQUIRES_NEW, no checked-exception commit holes, tenant context handled correctly in every job, outbox atomic). Weaknesses cluster in four places: (1) check-then-act races locked on the wrong row (transfer lane, staging lane, goods receipt); (2) side effects inside or holding a transaction (CUPS print in transferStock, afterCommit OMS POST holding the pool connection); (3) multi-commit controller flows with no compensation (fixed-location update, user create, club batch activate); (4) small latent traps. No Critical/High. Two races checked on WineCo PRD: neither has occurred since v2 go-live."
---

# WMS v2 transaction audit (2026-11-11)

## 1. Question

Does `v2/wms2-api` (origin/develop `df30fa62`) contain transaction-related bugs or weaknesses
**not already documented** in the boundary map (§7, §8, §10)? Four dimensions, one independent
lane each: propagation/boundaries, locking/races, side effects vs. commit, jobs/threads.
Lane reports (full file:line evidence, "checked & clean" lists): `261111-wms2-transaction-audit-evidence/lane{1..4}-*.md`.

## 2. Verdict

The fundamentals hold. **Clean, verified across 412 `@Transactional` sites / 110 files:**
- 0 bare `@Transactional` on tenant services (11 bare hits: 4 `LandlordService` — correct; 7 repo interfaces — tenant via `transactionManagerRef`).
- 0 `REQUIRES_NEW` silently joined by self-invocation (49 self-call sites read); 0 private/final `@Transactional`.
- 0 checked-exception commit holes (5 methods lack `rollbackFor`; all throw before any write).
- Every tenant-iterating job sets context per tenant, clears in `finally`, isolates failures; per-item `REQUIRES_NEW`; cross-pod advisory locks. No `@Async`/executor/parallelStream.
- All 20 outbox enqueues join the business tx; dispatcher claims with `SKIP LOCKED`, no lock held across HTTP.
- Version conflict / lock timeout / deadlock all map to 409 (503 on `/rest`).

No Critical or High findings. The real weaknesses are below.

## 3. Findings (ranked)

Verify column: **ME** = re-checked by the author against code/DB after the lane; **L** = lane-verified only.

| # | Sev | Finding | Where | Verify |
|---|---|---|---|---|
| 1 | Med | **Transfer-lane lock doesn't serialize.** `getAvailableTransferLanesForUpdate` locks `location` rows but the write goes to `customerorder.transferlane_id`; the lane row is never updated, so Postgres READ COMMITTED does no EvalPlanQual recheck: T2 waits on L, wakes, and gets L with its stale `NOT EXISTS`. Two orders → one lane. The repo comment and `wms2-transfer-order-workflow.md:147` claim it "refuses a lane another open order holds" — false under concurrency. Fix: partial unique index `customerorder(transferlane_id) WHERE state < 700`, or touch the lane row (`UPDATE location SET version=version+1`) under the lock. | `repo/jpa/LocationRepository.java:195-215`, `TransferOrderService.java:102,144` | ME (code). PRD: 0 shared lanes, but only 7 open transfer orders. |
| 2 | Med | **CUPS print inside `transferStock` tx, under the destination-pallet `FOR UPDATE`.** CUPS outage → `FacadeException` (in `rollbackFor`) rolls back every transfer in a bulk transfer+print; other operators wait (3 s lock_timeout → 409) during print latency; label can print for a transfer that fails at commit. Sibling `setLockDamaged` already moved print after commit (SBDEV-3086). | `service/StockunitService.java:448` (tx) → `:540` lock → `:879` `cupsPrint` | ME (code) |
| 3 | Med | **Staging-lane assignment: unlocked check-then-act, no constraint.** Two club batches can be assigned the same staging lane. | `service/CustomerorderBatchService.java:1244-1272` | L |
| 4 | Med | **afterCommit OMS POST still holds the tenant DB connection.** No `hibernate.connection.handling_mode` override → Spring default `DELAYED_ACQUISITION_AND_HOLD`; `triggerAfterCommit` runs before `cleanupAfterCompletion` closes the EM. A slow OMS (5 s connect + 15 s read) pins 1–2 of the tenant's 5 pool slots on the hot `STOCK_UPDATE` path (~14 call sites). Contradicts `SBDEV-3674-evidence/architect-fix-shape.md:341`. Same mechanism, worse: `ReleaseOrderJobService.releaseOrder` ON_HOLD POST nested in a streaming tx can pin 3 of 5. | `OmsNotificationService`, `ReleaseOrderJobService` | ME (no override in `src/main`); impact unmeasured — needs a pool-count probe |
| 5 | Med | **Goods-receipt find-or-create locks the advice *position*, not the advice.** Two operators receiving different positions of a new advice concurrently → two `goodsreceipt` rows; later receipts attach to `get(0)` (no ORDER BY). | `service/ReceivingService.java:484-505` | ME (PRD): **not occurring** — 453 receipts / 453 advices since 2026-09-01; the 1,623 historical multi-receipt advices are all ≤ 2025-01-30, gaps < 1 min (bulk import, not this race). Latent. |
| 6 | Med | **`FixLocationAssignmentController.upadteFixedAssignment`: 4 commits, non-idempotent toggle.** `changeActive` flips, then up to 3 bound updates each commit separately. Failure mid-way + retry flips `active` back; bound changes aren't atomic. | `FixLocationAssignmentController.java:65-90` | L |
| 7 | Med | **`UserController.createUser`: Keycloak first, DB second, no compensation.** DB failure leaves a Keycloak user; every retry → "User already exists". `updateUser` same split; `if (passwordChange)` NPEs on a missing field after both writes. | `UserController` | L (lanes 1 & 3 independently) |
| 8 | Med | **Optional OMS callbacks share the fail-closed `CUSTOMER_ORDER` ordering chain.** If picking-date/priority callback fails permanently (404, seeded `CHANGE-ME` URL), every later RELEASE/STARTED/FINISHED/CANCEL for that order is held. Off by default — risk starts when a tenant enables them. | outbox enqueue sites | L |
| 9 | Med→Low | **`AdvisoryLockService.unlock` closes the connection in `finally` even when unlock SQL throws** → session advisory lock can stay on a pooled connection → that job silently stops for that tenant on all replicas until the connection retires. | `AdvisoryLockService` | L (plausible) |
| 10 | Low-Med | **`ClubLineController.activeBatch`**: assign-lane and activate are separate commits; second-step failure strands batch at 525 and the "already active" guard blocks retry. | `ClubLineController` | L |
| 11 | Low-Med | **Swallowed `FacadeException` poisons the tx.** `ReplenishOrderJobService.cancelReplenishmentOrder` (REQUIRES_NEW) catches a `FacadeException` from `ReplenishorderService.cancelReplenishmentOrder`, which *joins* with `rollbackFor=FacadeException` → rollback-only → `UnexpectedRollbackException` at commit instead of the intended quiet skip. Same shape at `ReplenishmentOrderMaintenanceService` :921, :1025 (unlike :760, no ACCEPTED note). | `service/job/ReplenishOrderJobService.java:303-324`; `ReplenishorderService.java:396` | ME (code) |
| 12 | Low | `StockSummaryExportJob` commits `inventory_record` chunks before OMS delivery; partial failure leaves orphans, retry duplicates under new UUIDs. (Lanes 3 & 4 independently.) | `StockSummaryExportJob` | L |
| 13 | Low | Mobile transfer: no tx, no lock on order position → two handhelds over-fill the lane (each SU amount stays correct). | `mobile/MobileTransferOrderService.java:353-447` | L |
| 14 | Low | Cron priority bulk `UPDATE … WHERE id IN :ids` drops the select's guards (manual override, state) and bypasses `@Version`; can overwrite an operator's manual priority. Its OptimisticLock catch is dead code. | `ReplenishorderRepository.java:441` | L |
| 15 | Low | Outbox `mark*` don't check `status='IN_FLIGHT'`, claim doesn't bump `@Version` — the per-lane advisory lock is the only double-send fence; `markSent` failure after 2xx → re-POST. | outbox repo | L |
| 16 | Low | Misc: `PrinterController.deletePrinter/setDefault` multi-commit; `ReceivingController.setPallet` orphan pallet; count-based position numbering (no unique); shipper-id find-or-create collides (fails safe); `TimezoneService` caches zone forever (no caller of `invalidateCache`); in-tx `@CacheEvict` before commit (`PutawayConfigController`); `TenantHealthService` clears caller's context; unbatched cleanup deletes; `TenantConfigLoader` clear-then-put. | see lane reports | L |
| 17 | Latent | Landlord advisory-lock connection sits idle-in-transaction for the whole job. **Harmless today** — `idle_in_transaction_session_timeout=0` on landlord dev and PRD, no role/db overrides (`pg_db_role_setting` empty). Becomes a double-processing bug if that GUC is set or **PgBouncer transaction pooling** (open plan `260405-PgBouncer_Connection_Pool_Strategy`) fronts landlord — session advisory locks don't survive transaction pooling. | `AdvisoryLockService` | ME (DB) |

**Doc drift (FIXED 2026-11-11):** boundary map §6 rebuilt (+ the `ReceivingService` row was mislabelled — it is a post-commit print); transfer-order workflow line 147 qualified + landmine 13 added; PgBouncer plan got a landlord advisory-lock prerequisite section. Original finding: boundary map §6 lists `MobileReplenishService` (no longer registers) and omits 5 live
post-commit sites (`ReplenishmentMaintenanceTrigger`, `BolOmsNotificationService`, `ClubRunJobService`,
`BillofladingService` ×2). `wms2-transfer-order-workflow.md:147` overstates the lane lock (#1).
**Guardrail gap:** `HttpInTransactionArchTest` only catches direct `HttpRestService` calls — misses CUPS (#2), Keycloak (#7) and indirect calls.

## 4. Recommendation

| Order | Item | Why first | Rough cost |
|---|---|---|---|
| 1 | #1 transfer lane + #3 staging lane — DB partial unique indexes (Flyway) | Data-integrity; the fix is a constraint, not code; also corrects a doc that tells people it's safe | T3 (Flyway) — small diff |
| 2 | #2 move `cupsPrint` after commit in `transferStock` (copy SBDEV-3086 pattern) + widen `HttpInTransactionArchTest` to CUPS/Keycloak | Operator-visible 409s/rollbacks during any printer outage; precedent exists | T1–T2 |
| 3 | #4 pool-count probe on dev (slow-OMS stub, watch Hikari active) → decide `handling_mode=DELAYED_ACQUISITION_AND_RELEASE_AFTER_TRANSACTION` or post-commit executor | Pool is 5/tenant; a slow OMS can starve picking | probe ~1 h, fix T2 |
| 4 | #11 rollback-only poison (catch in a `REQUIRES_NEW` inner or drop the catch) | Cheap, confirmed | T1 |
| 5 | #6, #7, #10 multi-commit controller flows → single service tx / compensation | Real but low frequency, admin screens | T1–T2 each — fixed by SBDEV-4109 (user create is DB-first plus a local undo, not a Keycloak compensation; receiving `createAndSelectPallet` was added as a sibling) ✓ merged(SBDEV-4109: #666 3690a730, 2026-11-12) |
| 6 | #5 goods receipt — lock the advice (or unique index) | Latent, not observed on PRD | T2 |
| — | #17 | Must be resolved **before** PgBouncer transaction pooling lands; add as a prerequisite on that plan | note only |

### Filed 2026-11-11 (Nam confirmed; in-flight sweep: no open PRs, release branch carries only hold/restore reverts, no local worktree touches these files)

| Ticket | Covers | Tier | Priority |
|---|---|---|---|
| [SBDEV-4107](https://app.clickup.com/t/868mv915q) | #1, #3, #5, position numbering — assignment races | T3 | normal |
| [SBDEV-4108](https://app.clickup.com/t/868mv915x) | #2, #4, arch-test gap — network I/O holding tx/lock/connection | T2 | normal |
| [SBDEV-4109](https://app.clickup.com/t/868mv9161) | #6, #7, #10, printer/setPallet — multi-commit controller saves | T2 | normal |
| [SBDEV-4110](https://app.clickup.com/t/868mv9162) | #8, #12, #15 — outbox robustness | T2 | low |
| [SBDEV-4111](https://app.clickup.com/t/868mv9165) | #11, #14 — replenish cron tx correctness | T1–T2 | low |
| [SBDEV-4112](https://app.clickup.com/t/868mv916b) | #9, #17, pool starvation — advisory lock | T1 | low |

Not filed: #13 is already [SBDEV-3412](https://app.clickup.com/t/868m6g1u7) (parked, zero exposure). The remaining #16 hygiene items stay in this report only. Doc drift is fixed directly, not ticketed.

## 5. Open questions
- #4 is reasoned from Spring/Hibernate lifecycle, not measured.
- #9 trigger frequency (how often does `pg_advisory_unlock` throw in practice?) unknown.
- Not covered by any lane: cycle-count writes, `CancellationReversalService`, BOL close beyond its id-ordered locks, `FileImportController`/`UtilRestController` batch handlers, `EmptyPalletCleanupJob`/`StaleClubBatchCleanupJob` bodies.
- Native `assignToteToAllPositions` may leave managed positions stale (possible `picktounitload_id` write-back) — not traced.
