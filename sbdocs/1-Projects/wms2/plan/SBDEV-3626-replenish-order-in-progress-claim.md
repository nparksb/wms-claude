---
title: "SBDEV-3626 — Replenish order in-progress claim (STARTED 500) so the cron cannot cancel an order mid-pick"
ticket: "SBDEV-3626"
ticket_url: "https://app.clickup.com/t/868mc5hpj"
type: "bugfix"
priority: ""
status: approved — gate tests committed c99ddaff; PARKED until SBDEV-3621 merges (Nam, 2026-10-02)
project: [wms2]
version: "v2"
tier: "T3"
db_verified: true
requester: "Nam Park"
created: "2026-10-02"
updated: "2026-10-02"
revision: "r3 (ralplan round 3: architect-r2 + critic-r2 folded in; D7–D10 applied, §11)"
refs: "wms2-api origin/develop 09f861da · wms2-mobile-ui origin/develop 62fc642 (local refs, not re-fetched)"
related:
  - "[[SBDEV-3561]]"
  - "[[SBDEV-3605]]"
  - "[[SBDEV-3607]]"
  - "[[SBDEV-3618]]"
  - "[[SBDEV-3205]]"
  - "[[wms2-replenishment-design]]"
  - "[[wms2-scheduled-jobs-catalog]]"
tags:
  - plan
---

# SBDEV-3626 — Replenish order in-progress claim

**Ticket:** [SBDEV-3626](https://app.clickup.com/t/868mc5hpj) · **Tier:** T3 (concurrency + data integrity, 2 repos) · **Status:** pending approval · **Date:** 2026-10-02
**Evidence bundle:** `.omc/research/SBDEV-3626-analysis.md` (**[B §n]**). **Decisions:** `.omc/research/SBDEV-3626-decisions.md` (D1–D10, §10). **Reviews:** `.omc/research/SBDEV-3626-{architect,critic}-r{1,2}.md` (summary in §11).

## RALPLAN-DR (mode: SHORT)

**Principles.** (P1) Fail before physical work, not at submit. (P2) Every state decision is made under the order's row lock (SBDEV-3244 first-touch rule). (P3) Each PR deploys alone, in either order. Old handhelds keep working without protection. (P4) Additive contracts: new endpoints, new non-exported queries, no changed signatures on exported SDR searches. (P5) An abandoned claim self-heals without a human.

**Decision drivers.** (1) Mid-pick **cancellation** by four paths (recalc, two ROJ sweeps, admin cancel) wastes a physical pick at `REPLENISH_ALREADY_FINISHED`. (2) A pre-existing TOCTOU in `ROJS.cancelReplenishmentOrder` cancels even a 500 order, so wiring 500 alone is not enough. (3) A mixed handheld fleet during rollout.

**Options.**
| Option | Shape | Verdict |
|---|---|---|
| **A** explicit `start`/`reset` endpoints + strict heartbeat + server timeout + tolerant `/multi-unitloads` | [B §7 Design A] | **Chosen** |
| B implicit claim inside `GET /loadOrderById` | A GET with a side effect. It is re-called inside `checkSource`/`checkAmount`/`checkDestination` and by web admin views, so browsing would take claims. Release still needs a UI change. | Invalidated |
| C no 500; the cron defers on a recent `modified` | Recalc's own `updateRequestedAmount` writes defeat it. Two pickers still collide. The predicate would be repeated in five queries (*prose enumerations rot*). | Invalidated |
| D "the physical move wins": on submit to a **system**-cancelled template, book the scanned ULs as an ad-hoc order via `createOrderFromTemplate` (architect steelman) | Protects old handhelds on day one and needs no claim state. But it can overfill the flowbin whose fullness caused the cancel, does not stop two pickers, races a re-reservation of the released stock, and discovers the conflict after the work (P1). | **Considered, deferred → Follow-up 6**, as a residual-only complement to A (an 800 `CODE_REPLENISHMENT_CANCELLED` order submitted by its last holder within the TTL) |

---

## 0. Affected sites

Enumerated with four instruments, each with blind spots and a positive control [B §0]. **Blind spots:** a state passed through a variable from a third class; DB views/functions other than `ReplenishmentMonitorViewRepository`; web-UI client-side filters. The architect independently re-derived the cancel writers (exactly `ROMS.cancelOrder:733` and `ROS.cancelReplenishmentOrder:332`) and found no bulk state write.

| # | Site | Verdict | Fix |
|---|---|---|---|
| 1-3 | `ROMS.recalculateOpenOrders` / `recalculateForItem` / `recalculateOrder` (`≠ PROCESSABLE → return` under `findByIdForUpdate`) | OK: skips 500 under the lock | AC-1, AC-11 |
| 4 | `ROMS.getInboundReplenish` (private) → `RR.sumRequestedAmountForOpenOrders` (`ro.state = :state`) | FIX | **F** |
| 5-6 | `ROMS.reassignOrCancelForMovedStockUnit` L243, `ReplenishmentOrderSourceSyncService.syncForMovedStockUnit` ~L96 (`>= STARTED` throws) | OK by design, now reachable. Operational cost in §9 | AC-10 |
| 7-8 | `ROJ.cancelUnreachableReplenishment`, `cancelReplenishmentIfFlowbinIsFull` (`state <= :state` at selection) | OK at selection | **C** at execution |
| 9 | `ROJS.cancelReplenishmentOrder`: plain `findById`, then cancel, no re-check | **FIX (TOCTOU)** | **C** |
| 10 | `ROS.cancelReplenishmentOrder` (`> FINISHED` throws, `== FINISHED` returns) | Shared. Body unchanged; callers decide. Over-release → **SBDEV-3621** (prerequisite, §7.1; 3632 closed as its duplicate) | **C** |
| 11 | `ROS.redirectSource` (`state > PROCESSABLE` throws) | OK | none |
| 12 | ROJ sub-op 9 `ROS.recalculateReplenishmentOrderWithoutFixedLocationAssignment` (selects `≤ 300` unlocked, saves later) | OK at selection, **OLE at commit** if a claim lands in between. Rolls back that tick's batch (caught ROJ L819) and self-heals next tick | none (AC-12 positive control does not use sub-op 9) |
| 13-16 | ROJ priority (`< :replenishOrderStarted`), FLA `NOT EXISTS (… < :FINISHED)`, `findByStateLessThanAndItemdataId(FINISHED…)`, FLA move L142 (`> PROCESSABLE` → "is currently in processing!") | OK. FLA-move cost in §9 | none |
| 17 | `MRS.loadOrderByDestination` (`> PROCESSABLE` → `MsgReplenishAlreadyStarted`) | OK, **unchanged**. Request-side endpoint only; no holder flow reaches it (critic L5) | none |
| 18 | `MRS.loadOrderById`: read-only | OK, stays a pure read (Option B rejected); the 404/405 fallback target (Fix H) | none |
| 19 | Web `GET /v3/replenishOrder/cancelReplenishOrder/{id}`: `findById` outside a tx → #10 | Keep as the supervisor escape hatch, read under the lock, log the holder | **C** |
| 20 | `MRS.update` (PUT `/v3/replenish/order/{id}`): `state > PROCESSABLE` → BusinessException | **FIX**: blocks the holder on every `selectSource.submit()` | **D** |
| 21 | `MRS.fulfillMultipleUnitLoadsTx` (`>= FINISHED` → `REPLENISH_ALREADY_FINISHED`, L1241/L1254) | Add a foreign-claim refusal | **E** |
| 22-23 | `MRS.checkSource` / `checkDestination` + `finishReplenishmentOrderInternal` | Legacy, no UI dispatcher [B §1]. Finish gets the same refusal as #21 | **E** |
| 24 | `MRS.startOrder`: no lock, no lower bound, unreachable OLE retry | FIX | **A** |
| 25 | `MRS.resetOrder`: no operator check | FIX | **B** |
| 26 | `MRS.getReservedOrder` (`> :processable and < :finished`, by operator) | OK, serves resume | AC-9 |
| 27-28 | `getCalculatedOrders` / `ClientRepository.getClientList` (`= :processable`) | Excluded: reached only by the dead `selectOrder.vue` | none |
| 29 | `ViewDtoService` → `getOpenViewByKeyword(<670)` (mobile "All" tab) | Excluded: a claimed order shows no holder. Follow-up 2 | none |
| 30-33 | Monitor view `< 600`, `StockunitRepository` `< 700`, FLA refill `< :FINISHED`, `PickLineRealignmentService` | OK / n/a | none |
| 34 | `RR.bulkUpdatePriorityForItems*` called with `State.FINISHED` against `r.state = :state` | Pre-existing | **SBDEV-3633** (filed) |
| — | `UtilRestController:1045` → #10 | Excluded: `@Service`, so its mappings do not route | none |
| — | SDR: `Replenishorder` ∈ `RestConfiguration.SDR_WRITE_WITHDRAWN` | No SDR write to `state`/`operator_id` | none |
| — | `operator_id` writers: `startOrder`, `resetOrder` only (+ new `releaseExpiredClaim`). Readers: `getReservedOrder*`, `findDetailMapById` [B §0] | Writers rewritten | **A/B/G** |

## 1. Problem statement and DB evidence

A handheld picker opens a replenish order at state 300 and walks to the source. Before they submit, any of four paths can cancel the order: `ROMS.cancelOrder` from recalc, `ROJ.cancelUnreachableReplenishment`, `ROJ.cancelReplenishmentIfFlowbinIsFull`, or web admin cancel. The submit then fails with `REPLENISH_ALREADY_FINISHED` after the physical move [B headline 3]. STARTED 500 is written only by `MRS.startOrder`, which has had **no caller since the initial check-in** (`git log -S startOrder` → `a685e07b`, plus a javadoc mention in `4c7314cf`). v1 never called it either [B §6].

**Why SBDEV-3561 P8 is reopened (D5).** P8 ("wire `startOrder`") was dropped on 2026-09-29 in favour of F8a, judged on **release accounting at submit**. That verdict still holds and F8a stays. SBDEV-3626 targets **mid-pick cancellation**, which F8a cannot cover because it refuses at finish (P1). The premise changed, not the verdict on P8's original question.

**DB evidence (PRD, read-only, 2026-10-02):** `select state, count(*), count(operator_id), min(modified)::date from replenishorder where state < 700 group by state`
| Tenant | Result | Reading |
|---|---|---|
| wsl-wineco-prd | 300 × **563**, operator 0, oldest 2025-08-29 | no 500 rows; open orders idle > 1 year, so the TTL applies only to 500 |
| c1wh-shipitez-prd | 300 × **97**, operator 0 | same |
| nywh-hydra-prd | 300 × **1**, operator 0 | same |
| nywh-shipitez-prd | no open orders | — |

There are zero 500 rows on these 4 PRD tenants. WineCo over 30 days shows **700 × 318 vs 800 × 677**, so cancellation is the hot path. Which of those cancels hit a pick in progress cannot be measured, because no operator is recorded. WineCo `operator_id` is set only on legacy 2020–2023 rows [B §9]. **ROJ gate (architect + critic, 2026-10-02):** `NEW_CRON_JOB_ACTIVATED` and `REPLENISHMENT_TIMER_ACTIVATED` are both `true` on all 4 PRD tenants, so release runs everywhere on PRD. **Not queried:** every UAT tenant (MCP `*-uat` failed to connect). §7.1 requires that query.

## 2. Root cause analysis

**Bug 1: the claim is unwired, and unsafe if wired as written** (#24). `startOrder` reads with `readReplenishOrder` (plain `findById`) and has no `>= PROCESSABLE` bound. Its `catch (ObjectOptimisticLockingFailureException)` is **unreachable**: `save()` on a managed entity does not flush, so the OLE surfaces at commit, and the "fresh" re-read would return the same first-level-cache instance [B §4].
**Bug 2: anyone can release anyone's claim** (#25). `resetOrder` has no operator check.
**Bug 3: the cron cancels a committed claim (TOCTOU)** (#9). `ROJS.cancelReplenishmentOrder` (REQUIRES_NEW) re-reads with `findById` and calls `ROS.cancelReplenishmentOrder`, which cancels anything `< FINISHED`. The id page was selected earlier, in another tx. `@Version` cannot help because the read is fresh.
**Bug 4: the holder is blocked by its own order** (#20). `MRS.update` throws for `state > PROCESSABLE`, so wiring the claim alone breaks every live submit at the source scan [B headline 4].
**Bug 5: a claimed sibling drops out of inbound** (#4). `ro.state = 300`. Exposure is near zero, because the sum is non-zero only for a null destination [B headline 6].
**Bug 6: no release for an abandoned 500** [B §3]. Only `resetOrder` returns 500 → 300.

## 4. Architecture overview

```
handheld (replenish.vue)                       wms2-api                                      cron (ReplenishOrderJob, advisory-locked per tenant)
 select order ─ POST /order/{id}/start ──────▶ MRS.startOrder: lock O, 300→500, op=U        replenish():
   (404/405 w/o code → GET /loadOrderById)       200 DTO+claimTimeoutSeconds | 409 {code}    ├─ NEW releaseExpiredReplenishClaims: 500 & modified<now-TTL → 300
 every ttl/4 + on visible ─ POST …/start?heartbeat=true ▶ MRS.heartbeatOrder: 500&U → re-stamp 204; else 409 CLAIM_LOST
 source scan ─ PUT /order/{id} ──────────────▶ MRS.update: holder admitted                   ├─ cancelUnreachable / cancelIfFlowbinFull → ROJS.cancel (lock + ≤300 re-check)
 submit ─ POST /multi-unitloads ─────────────▶ fulfillMultipleUnitLoadsTx: lock O;           ├─ … generate / priority (skip 500) …
                                                 foreign 500 → RESERVED; →700                └─ recalculateForItem → ROMS.recalculateOrder (lock, ≠300 → return)
 → 1_select / route-leave / re-entry ─ POST …/reset ▶ MRS.resetOrder: lock, holder only, 500→300 (204)
web admin cancel ──────────────────────────────▶ ROS.cancelReplenishmentOrderById: lock, cancels 300|500, WARN names holder
```

## 5. Fix design

### 5.0 Contract for start/heartbeat/reset
Designed against the real envelope. Mobile writes return **HTTP 200 `{errors:[{field,message}]}`** with only localized text (`AdminController.getErrorMessage` L322-326; `updateOrder` L293-317). The global `@Order(0) RestExceptionHandler` maps `PessimisticLockingFailureException` → **409** ProblemDetail "Resource Locked", `retryable:true` (L370), `BusinessException` → 422, `EntityNotFoundException` → 404. `MobileEndpointExceptionHandler` (LOWEST_PRECEDENCE, `controller.mobile`) passes Spring's own 404/405 through and turns any other escaped exception into a 500 with a `reference` (L107). The axios interceptor retries only 401/403 and toasts only a 403 with `reason`, so a 409/404 reaches the store's catch.

The new endpoints **do not use the 200 envelope**:
| Outcome | HTTP | Body | UI |
|---|---|---|---|
| start: claimed / re-claimed | 200 | `ReplenishMobileOrderDto` + additive `claimTimeoutSeconds` | `startOrder`: commit order + `clearULBatch` + `setClaimTtl(claimTimeoutSeconds)`, return `true` |
| start: `REPLENISH_RESERVED` / `REPLENISH_NOT_RELEASED` / `REPLENISH_ALREADY_FINISHED` | 409 | ProblemDetail, `detail` = localized text, **`code` = message key**, `retryable:false` | toast `detail`, refresh list, return `false` |
| heartbeat: 500 held by U, re-stamped | 204 | — | `heartbeatClaim` → `'ok'`, **commits nothing** |
| heartbeat: anything else (300, foreign holder, ≥ 700) | 409 | `code = REPLENISH_CLAIM_LOST` | `'lost'` → claim-lost handling (Fix H) |
| order / user not found | 404 | ProblemDetail **with** `code` (`MsgCannotReadOrder` / `ENTITY_NOT_FOUND`) | start: toast, `false`. heartbeat: `'lost'` |
| row lock timeout (55P03 → `CannotAcquireLockException` ⊂ `PessimisticLockingFailureException`) | 409 | global ProblemDetail, **no `code`**, `retryable:true` | start: toast `detail`, `false`. heartbeat: `'transient'` |
| **endpoint absent (old API)** | 404/405 | Spring `ErrorResponse`, **no `code`** | start: **fallback** `GET /replenish/loadOrderById/{id}`, no claim, today's behaviour; `setClaimTtl(null)` → no heartbeat. reset: swallowed |
| fallback finds no order | 200, empty body (`loadOrderById` returns `null`: MRS L231-235, controller L178-182) | — | toast "Order no longer available", refresh list, return `false` |
| reset ok / no-op | 204 | — | ignore |
| reset refused | 409 `{code}` | as above | `console.warn` only (fire-and-forget) |

- **Controller.** The three new handlers catch **only** `FacadeException` (→ 409 `{code}`, except key `MsgCannotReadOrder` → 404 `{code}`) and the custom `EntityNotFoundException` from the user lookup (→ 404 `code=ENTITY_NOT_FOUND`). Lock exceptions reach the global advice. The local catch is load-bearing: without it a `FacadeException` falls to `MobileEndpointExceptionHandler.handleUnexpected` → 500 (AC-16 mutant). `FacadeException.key` is private with no getter → additive `public String getKey()`. `REPLENISH_ORDER_BUSY` is not introduced.
- **The fallback discriminator is "404/405 without `code`"**, so a provisioning fault (unknown user) is shown, not silently degraded to an unclaimed pick.
- **New key** `REPLENISH_CLAIM_LOST` in every bundle that carries `REPLENISH_RESERVED` (on develop: `messages_en_US.properties` only).
- **UI rule:** `selectOrder` advances to `2_source` **only when** `startOrder` resolves `true`. Today it advances unconditionally after `getOrderById` (replenish.vue L213-219).

### Fix A: `startOrder(Long id)`, `heartbeatOrder(Long id)` and `POST /v3/replenish/order/{id}/start[?heartbeat=true]`
**start.** `findByIdForUpdate(id)` is the first touch (`orElseThrow FacadeException("MsgCannotReadOrder")`). Then: `state < PROCESSABLE` → `REPLENISH_NOT_RELEASED`; `>= FINISHED` → `REPLENISH_ALREADY_FINISHED`; `operatorId != null && != U` → `REPLENISH_RESERVED`; `state == STARTED && operatorId == U` → re-stamp; otherwise set `operatorId = U`, `state = STARTED`. An explicit start on a lapsed order (300/null after a release) **re-claims**: it is a deliberate re-open, and the UI commits the fresh DTO.

**heartbeat** (`?heartbeat=true`, same mapping, same class gate). Lock first; re-stamp **only** when `state == STARTED && operatorId == U`, else `REPLENISH_CLAIM_LOST`. It never re-claims, so a lapse during which recalc re-sized or redirected the order (ROMS L719, L431→L499) is reported to the picker instead of hidden behind a 200 (architect r2 M2).

**Re-stamp** needs an explicit `order.setModified(LocalDateTime.now())`: `modified` is `@LastModifiedDate` (`AbstractBaseEntity` L31, `AuditingEntityListener`), which fires only on a dirty flush, so `save()` alone is a no-op. The set dirties the row, auditing overwrites it, `version` increments.

U = `userRepository.findByName(SecurityContextUtils.getUserName())` (MRS L246). start returns the `loadOrderById` DTO with `claimTimeoutSeconds` (Fix G). The unreachable OLE block and the DTO overload are deleted (`git grep -F "startOrder("` → declaration only); their unit tests are rewritten. The only lock is the order lock, so the claim cannot join a cycle.

### Fix B: `resetOrder(Long id)` and `POST /v3/replenish/order/{id}/reset`
Lock first, then: 300 with null operator → no-op 204; STARTED held by U → `operatorId = null`, `state = PROCESSABLE`; held by V → `REPLENISH_RESERVED`; `>= FINISHED` → `REPLENISH_ALREADY_FINISHED`. Privileged release is the timeout (G) or a supervisor cancel (C); a web "release" button is Follow-up 2.

### Fix C: locked re-check on every cancel caller (#9, #19)
- **`ROJS.cancelReplenishmentOrder`.** `findById` → `findByIdForUpdate`, then `if (state > PROCESSABLE) { LOG.info("skip cancel, order {} claimed by {}"); return; }`. The skipped id cannot be re-selected by `drainPageZero`, because selection is `≤ 300`.
- **ROJ cancel loops (L611/L634).** Widen `catch (OptimisticLockException | OptimisticLockingFailureException e)` with the sibling `PessimisticLockingFailureException` (compiles: not a subtype of either), so a cancel waiting behind a long submit logs WARN, not ERROR.
- **Web admin.** The controller's bare `findById` + `cancelReplenishmentOrder(entity)` becomes `ROS.cancelReplenishmentOrderById(id)` (`tenantTransactionManager`): lock, delegate to the unchanged `cancelReplenishmentOrder`, **still cancel 500** (escape hatch), WARN with the holder. A lock timeout reaches the global 409 (the controller catches only `FacadeException`).
- **Recalc.** `ROMS.cancelOrder` is already behind `recalculateOrder`'s locked `≠ PROCESSABLE → return`.
- **Sibling sweep.** `git grep "cancelReplenishmentOrder(" origin/develop -- src/main` → exactly 3 callers (ROJS, ReplenishOrderController, the non-routing UtilRestController). Blind spot: reflective/SpEL calls.
- **Over-release** in the shared body is fixed by SBDEV-3621 (`HeldShareRelease.release` under the SU lock), merged before this step (§7.1). With Fix C the cancel takes order → SU.

### Fix D: admit the holder at PUT (#20)
`MRS.update`: allow `state == PROCESSABLE`, or `state == STARTED && operatorId == U`. Otherwise throw `BusinessException` with `"Replenish order <number> is in state <s> and claimed by another user"`, or `"… can only be changed while it is PROCESSABLE"` when there is no foreign claim. `loadOrderByDestination` is unchanged.

### Fix E: foreign-claim refusal at finish (D3)
**Directly after the locked `>= FINISHED` check at MRS L1240**, before `assignDestinationForMultiUnitLoads` (which can create an FLA and run joined maintenance): `if (state == STARTED && operatorId != null && !operatorId.equals(U)) throw REPLENISH_RESERVED`. A 300 order (old handheld) and an own 500 pass. The mirror in `finishReplenishmentOrderInternal` goes next to L542 and is **lock-free** (legacy `checkDestination` path, no UI dispatcher [B §1]; a lock there would be an upgrade after earlier reads). This is the one stated exception to P2.

### Fix F: inbound counts 300..699
Add `RR.sumRequestedAmountForActiveOrders(itemDataId, destinationId, excludedId)`, `@RestResource(exported = false)`, filtering `ro.state >= 300 AND ro.state < 700`, and switch `ROMS.getInboundReplenish` to it. The exported `sumRequestedAmountForOpenOrders` is untouched (P4).

### Fix G: timeout release (D2, D6, D7)
**Sysprop** `REPLENISHMENT_CLAIM_TIMEOUT_SECONDS`, default **600** (D7), read via the existing `syspropService.getIntValue(key, 600)`, which falls back **silently** on blank/non-numeric (SyspropService L338-346). `<= 0` disables release. The read is **uncached**: `getIntValue` self-invokes `getSysvalue` (L338-339), bypassing the `@Cacheable` proxy, so it is one DB read per tick and a change takes effect on the next tick/claim. ITs and the manual test still use `setSysvalue` (hygiene only).

**Seed.** `V2.2.36__seed_replenishment_claim_timeout_sysprop.sql` copies V2.2.29: `INSERT … SELECT … WHERE NOT EXISTS (syskey, workstation='DEFAULT')`, `nextval('public.seqentities')`, `client_id 0`, `hidden false`, the replenishment `groupname`, description < 255 chars (varchar(255), 22001).

**Release.** New `RR.findIdsOfExpiredClaims(STARTED, cutoff)` (non-exported: `state = :started AND modified < :cutoff`). New `ROJS.releaseExpiredClaim(id, cutoff)` (REQUIRES_NEW, `tenantTransactionManager`): lock, re-check `state == STARTED && modified < cutoff`, set `operatorId = null`, `state = PROCESSABLE`. New package-private `ROJ.releaseExpiredReplenishClaims()` runs **first** in `replenish(tenantName)`; cutoff = JVM `LocalDateTime.now().minusSeconds(ttl)` (auditing's clock domain).
- Per row: `catch (ConcurrencyFailureException | OptimisticLockException | PessimisticLockException | LockTimeoutException e)` at WARN — Spring parent only (`PessimisticLockingFailureException` is its subclass, so naming both would not compile); the three jakarta types are unrelated siblings. Released item ids join `affectedItemIds`; `jobMetrics.replenishSubOpRows(tenantName, "release_expired_claim", n)`.
- **Test seam.** `replenish(String)` goes from `private` to package-private, with a `/** test seam: bypasses landlord row, advisory lock and activation gate */` javadoc.

**Heartbeat and the TTL.** `start` returns `claimTimeoutSeconds` = effective TTL. The UI heartbeats every `max(30, ttl/4)` s (150 s at 600) and once immediately on `visibilitychange` → visible (Fix H). The TTL measures handheld liveness **only while the browser runs page timers**; a screen-off or backgrounded Android browser may throttle or freeze them. 600 s is therefore **not** claimed safe: it is gated by the fleet browser check in §7.1. If that check fails, raise the sysprop per tenant (e.g. 1800 or more) — no code change, since the UI reads the TTL from `claimTimeoutSeconds`.

**D6 rule.** Any `replenishorderRepository.save(`, or any dirty flush, of a row at 500 moves `modified` and so extends the claim by up to one TTL. Derived, not recalled: `git grep -n -E "replenish[Oo]rderRepository\.(save|saveAll|saveAndFlush)\(" origin/develop -- src/main/java` → **21 sites** (both reviewers re-derived the count).
| Sites (file:line → method) | Can it write a 500 row? | Verdict |
|---|---|---|
| RGS:272 `calculateOrder`, :324 `createOrderFromTemplate` | No: creates at 300 | n/a |
| ROMS:392 `alignDestination`, :532/:611 `redirectSource`, :719 `updateRequestedAmount`, :734 `cancelOrder` | No: only via `recalculateOrder` (locked `≠ 300 → return`) or move-sync after its `>= STARTED` throw | OK |
| SourceSync:125 `syncForMovedStockUnit` | No: after the `>= STARTED` throw | OK |
| **ROS:206 `updateReplenishmentOrderPriority(Replenishorder,int)`** ← `ROS.update(id,null,prio)` (web `POST /update`) and `ROS.updatePriority`, both plain `findById`, no state guard | **Yes** | **Accepted**: one TTL per supervisor priority edit. Pinned by AC-12b |
| ROS:295 `redirectSource(Long,Long)` | No: `> PROCESSABLE` throws | OK |
| ROS:333 `cancelReplenishmentOrder` | Terminal (→ 800) | n/a |
| ROS:380 sub-op 9 | No: OLE at commit (§0 #12) | OK |
| ROJS:244 `updateReplenishmentOrderPriority(long,Integer)` | No `src/main` caller (only `ReplenishOrderJobServiceUnitTest:486`) | Unreachable; **left as is** (deleting it buys nothing) |
| MRS:260/:270 `startOrder`, :288 `resetOrder` | Claim writers | Rewritten (A/B) |
| MRS:408 `switchSourceToUnitLoad`, :504 `checkDestination`, :667 `finishReplenishmentOrderInternal` | Holder-side, legacy | OK |
| MRS:1412 `assignDestinationForMultiUnitLoads`, :1512 `applyExplicitSourceToOrder` | Submit tx, ends at 700 | OK |

The JPQL bulk writes (`updatePriorityByIdIn`, `bulkUpdatePriorityForItems*`) set `prio` only and bypass auditing. **Blind spots:** a dirty-checked setter with no `save(` (architect swept one level: none outside the table), native SQL, a future writer. AC-12a pins a full tick.

### Fix H (UI PR): wms2-mobile-ui
- **`store/replenish.js startOrder({id})`.** Implements the §5.0 start rows, including the "404/405 without `code`" fallback and the empty-body case. Returns a boolean; on success commits `setOrder` + `clearULBatch` like `getOrderById`, **plus** `setClaimTtl(dto.claimTimeoutSeconds)`; the fallback commits `setClaimTtl(null)`. Used **only** by `selectOrder`.
- **TTL lives in its own store field, never in `order`** (architect r3 H1, critic r3 H1). The source-scan PUT replaces `order` with a fresh `MRS.update` DTO (MRS L1605-1611, store L209) that has no `claimTimeoutSeconds`, so a TTL read from `order` dies at `2.5_unitLoad`. New `claimTtl: null` in `initialState()` (store L3-17), so `resetState` clears it. Written **only** by `startOrder` (`setClaimTtl`); cleared by `resetState`, by claim-lost and by the submit success path (store L370-375, `setClaimTtl(null)`). `setOrder` never touches it. Also new: `submitting: false` in `initialState()`, set true/false around the `/multi-unitloads` post in `submitULBatchToDestination` (L332, `finally`).
- **`store/replenish.js heartbeatClaim({id})`** (architect r2 H1, critic r2 H1). POSTs `start?heartbeat=true` and **commits nothing** to `order` or `selectedULBatch` — staging is client-side (`selectUnitLoad.vue` L226/L243) and the PUT's scanned source lives only in the stored response (MRS L1600-1611, store L203-205). Returns `'ok' | 'lost' | 'transient'`: 409/404 **with** `code` → `'lost'`; network error, 5xx, 409 without `code`, 404/405 without `code` → `'transient'`.
- **`replenish.vue selectOrder`.** `if (!(await dispatch('replenish/startOrder', {id}))) { refresh list; return }`, then advance.
- **Heartbeat.** A **component-scoped** `setInterval` in `replenish.vue`, not store state (SBDEV-2930 `picking.timer` landmine). It runs while `process ∈ {2_source, 2.5_unitLoad, 1.5_destination}` and `state.replenish.claimTtl > 0`; **both the interval tick and the visibility handler read `this.$store.state.replenish.claimTtl`, never `order.claimTimeoutSeconds`**. A tick is skipped while `state.replenish.submitting` (a heartbeat queued behind the submit's row lock would read 700 and toast "Claim lost" before "Replenish completed"). One immediate call on `visibilitychange` → visible: the listener is added in `mounted()`, removed in `beforeDestroy` next to the interval, and acts only in a claimed step with `claimTtl > 0` and not `submitting`. Each call captures `sentId = order.id`; the response is **ignored** if `process === '1_select'`, `order?.id !== sentId`, or `submitting` is true when it resolves (e.g. a heartbeat queued behind the submit's row lock returning after "Replenish completed"). `'transient'` → keep the timer, no toast. `'lost'` → stop the timer, toast "Claim lost — the order was released or taken; reopen it" once, `setOrder(null)` then process `1_select`, refresh list. Cleared on leaving the claimed steps and in `beforeDestroy`.
- **Release: merged into the EXISTING `watch.process`** in `replenish.vue` (L87-99, the list refresh), rewritten as `process(newProcess, oldProcess)` — a second `process:` key in the same object literal silently replaces the first and drops the refresh. On a transition into `1_select` from a claimed step while `order?.id` is set, post reset fire-and-forget with that id. This covers `selectSource.goBack` / `confirmDiscardAndBack` (L266-277, which leave `order` set) with **no `selectSource.vue` change**. A successful submit nulls `order` first (store L373-375) and claim-lost nulls it first, so neither fires a reset. Also **new code** (develop has no `beforeRouteLeave` on `pages/replenish.vue`): a `beforeRouteLeave` (menu and hardware back) that posts reset when `order?.id` is set in a claimed step; plus and `created()` **before** `resetState` when a persisted `order.id` exists with `process ≠ 1_select` (vuex-persistedstate re-entry). No `goMain` hook: the Main Menu button renders only at `1_select` (L42), after the watcher has released.
- **Reset is fire-and-forget:** 404 **and** 409 (`REPLENISH_RESERVED`, `ALREADY_FINISHED` on re-entry after another device acted) are swallowed with `console.warn`, no toast.
- **Not handled.** Keycloak logout (clears storage) relies on the TTL. A `/reservedOrder` resume banner is Follow-up 3. Deeper back buttons within the claimed steps keep the claim; a successful submit needs no release (700).

## 6. File change summary

| Repo / file | Change |
|---|---|
| api `controller/mobile/ReplenishController.java` | +`POST /order/{id}/start[?heartbeat=true]`, +`POST /order/{id}/reset`; class gate inherited; local `FacadeException` / `EntityNotFoundException` → 409/404 `{code}` |
| api `exceptions/FacadeException.java` · `messages_en_US.properties` | +`getKey()` · +`REPLENISH_CLAIM_LOST` |
| api `json/mobile/ReplenishMobileOrderDto.java` | +`claimTimeoutSeconds` (nullable) |
| api `service/mobile/MobileReplenishService.java` | rewrite `startOrder`/`resetOrder` (id-based), +`heartbeatOrder`; guards in `update`, `fulfillMultipleUnitLoadsTx`, `finishReplenishmentOrderInternal` |
| api `service/job/ReplenishOrderJobService.java` | lock + re-check in `cancelReplenishmentOrder`; +`releaseExpiredClaim` |
| api `schedulejob/ReplenishOrderJob.java` | first sub-op `releaseExpiredReplenishClaims`; `replenish` package-private; WARN catch widened |
| api `service/ReplenishorderService.java` / `controller/ReplenishOrderController.java` | +`cancelReplenishmentOrderById` / admin cancel uses it |
| api `service/ReplenishmentOrderMaintenanceService.java` / `repo/jpa/ReplenishorderRepository.java` | inbound → new query / +2 non-exported queries |
| api `service/WmsConstants.java` · `db/migration/V2.2.36__seed_replenishment_claim_timeout_sysprop.sql` | sysprop key + default 600 · seed |
| mobile `pages/replenish.vue`, `store/replenish.js` | claim, fallback, `claimTtl` + `submitting` store fields, heartbeat, visibility, release merged into the existing `process` watcher, new `beforeRouteLeave` |
| sbdocs | `wms2-replenish-workflow.md` L24, `wms2-state-machine-catalog.md` §4.6, `wms2-replenishment-design.md` L219/L349, `wms2-sysprop-catalog.md`, `wms2-scheduled-jobs-catalog.md` [B §5] |

## 7. Implementation steps

### 7.1 Prerequisites (§5.1)
| Item | Status |
|---|---|
| **SBDEV-3621** (held-share release at web cancel / change-source / handheld switch+finish; [ticket](https://app.clickup.com/t/868mc1d6c), pr submitted, branch `bugfix/SBDEV-3621-release-held-share`). SBDEV-3632 was a duplicate of it and is closed | **Must be merged to `origin/develop`, and this branch (gate commit `c99ddaff`) rebased onto it, before ANY implementation step** — 3621 rewrites `MobileReplenishService` (+176) and `MobileReplenishServiceUnitTest` (+707), both touched here. Re-run the gate classes after the rebase. Lock order: 3621's cancel locks the SU first ("order row is not locked first … known, bounded residual"); Fix C locks the order before calling it → order → SU, the cron's order, closing that residual. AC-13's fixture uses held == requested, so it passes either way |
| DB state | No 500 rows on 4 PRD tenants (§1), so no backfill. **UAT: re-query `state<700` and both ROJ gate sysprops before the UAT deploy** (unmeasured) |
| Flyway | V2.2.36. **Immediately before merge: `git -C v2/wms2-api fetch --all --prune`, then the all-remote-branch collision sweep.** Max was V2.2.35 on 2026-10-02 on unfetched local refs |
| Gate | Release runs only where `NEW_CRON_JOB_ACTIVATED` and `REPLENISHMENT_TIMER_ACTIVATED` are both true (all 4 PRD tenants, §1). Where off, claims never expire (§9) |
| **Fleet browser check (before the UI goes past dev)** | On the fleet's actual handheld + browser, dev, TTL 120: open an order, screen off 5 min, confirm `replenishorder.modified` advanced during screen-off; then screen on and confirm one heartbeat fires at once. **Pass** → keep 600. **Fail** (timers frozen/throttled) → raise `REPLENISHMENT_CLAIM_TIMEOUT_SECONDS` per tenant above the longest expected screen-off walk (sysprop only, no code change); the visibility heartbeat still reports a lapse on wake, before the next scan |
| Deploy order | Either order is safe (P3). Preferred: API first, merged to develop only; the UI follows once `/api/public/version` shows the API on dev. Mind the `:develop` tag race |
| Access / external | N/A: no schema change, no OMS send, no new function (class gate inherited). Personal logins (D8), so a per-user claim suffices |

### 7.2 Steps
Each step is an atomic commit in worktree `.claude/worktrees/wms2-api/SBDEV-3626`, branch `bugfix/SBDEV-3626-replenish-claim`, off freshly fetched `origin/develop`. The TDD gate first lands **throwing stubs** for every new signature, plus the `replenish` visibility change, so reds are runtime/assertion reds, not compile errors. **Stubs add methods only: no new call site is wired into `replenish()` and no new `@PostMapping` is registered before its step** (AC-3b and AC-16 depend on this).
1. Fix A + B + heartbeat + §5.0 contract + `getKey` + `REPLENISH_CLAIM_LOST` + gate rail rows → AC-5, AC-6, AC-9, AC-15c, AC-16.
2. *(after SBDEV-3621 is on develop and the branch rebased, §7.1)* Fix C + WARN catch → AC-2, AC-11, AC-13.
3. Fix D + E → AC-7, AC-8.
4. Fix F → AC-4.
5. Fix G + V2.2.36 + seed test → AC-3a/b, AC-12a/b, AC-14, AC-15a/b.
6. AC-1 end-to-end, AC-10 pin, full suite vs baseline, doc-drift pass → PR into develop.
7. UI PR (`wms2-mobile-ui`, same branch name): Jest (AC-17) + manual table → PR into develop; fleet browser check (§7.1) before promotion.

## 8. Testing plan

Testcontainers lane (`*IT`; failsafe includes `**/*IT.java` in any package). Fixtures follow `MobileReplenishMultiUnitLoadIT` and `ReplenishmentOrderSourceSyncIT`. **Repo tests commit:** assert by id, never `isEmpty()`/`hasSize()`. **Mutation-check every assertion.** Concurrency uses latches, never sleeps. Timestamps are JVM-computed `LocalDateTime` parameters through jdbcTemplate, so fixture and cutoff share one clock. Margins: a 120 s fixture TTL, expired rows at now − 10 min, fresh rows at now (precedent `ReleaseExpiredPickingOrdersQueryPolarityIntegrationTest` L340-343).

**Users and threads.** Seed two `User` rows, **U** and **V**. A `runAs(user, Callable)` helper sets `TenantContext` and a `TestingAuthenticationToken(user, …)` in `SecurityContextHolder` on the executing thread and clears both in `finally`. Every call that resolves U (`SecurityContextUtils.getUserName()`, thread-local, falls back to `ANONYMOUS`) goes through it, on the test thread and on every executor thread (AC-5, 6, 7, 8, 11, 13).

**Classes.**
- `integration/service/mobile/ReplenishClaimIT`: AC-1, 2, 4–8, 11, 13, 15a, 15c. Copies `landlord.datasource.maximum-pool-size=5` from `MobileReplenishMultiUnitLoadIT` L111 (the tenant DS routes to the landlord pool; AC-13 needs T, thread 2 and the `pg_stat_activity` poller at once).
- **`schedulejob/ReplenishOrderJobClaimIT`** (same package as `ReplenishOrderJob`, for the package-private seam): AC-3b, AC-12a, AC-15b. It calls `replenish(tenantName)` under `TenantContext`; the seam bypasses the landlord row, the advisory lock and the activation gate. **This is the first IT to run a full ROJ tick**, so it is sensitive to committed rows from other tests in the class DB: every sub-op runs over every committed row, and the final `recalculateOpenOrders(false)` is outside any catch (ROJ L478), so a foreign leftover that throws fails the tick. Mitigations: assert by id only (never `isEmpty`/`hasSize`); dedicated item/location codes; a class javadoc naming that failure mode; call `releaseExpiredReplenishClaims()` directly where same-tick behaviour is not under test. `recalculateOpenOrders(false)` is cadence-gated by a sysprop last-run (ROMS L346-365); AC-3b relies only on the per-item recalc, so it is unaffected.
- `ReplenishClaimReleaseQueryPolarityIntegrationTest` (AC-3a). `ReplenishmentOrderSourceSyncIT#moveBlockedWhileClaimed` (AC-10).
- Unit: `MobileReplenishServiceUnitTest`, `ReplenishOrderJobServiceUnitTest` (mock-only OLE cases replaced). `ReplenishControllerUnitTest` (extends `BaseControllerUnitTest`, `setupMockMvc(controller, new RestExceptionHandler(), new MobileEndpointExceptionHandler())`) for AC-16. `FunctionGuardMockMvcUnitTest` gets the new paths as ungated-by-override rows asserting `MOBILE_UI_VIEW_REPLENISHMENT`. `FunctionGuardArchTest` AC-28 stays green. `ReplenishClaimTimeoutSeedConsistencyTest` (AC-14).
- UI Jest: `test/store/replenishStartOrder.spec.js` (next to `replenishUpdateSourceLocation.spec.js`), `test/pages/replenish-claim.spec.js` (AC-17): `jest.mock`-stub `selectUnitLoad.vue` and `selectDestination.vue` exactly as `test/pages/workflow-reset-on-entry.spec.js` L31-38 does (vue-jest 3.0.7 cannot parse their template `?.`), and mock `$axios` for `selectSource`'s own fetches.

**Acceptance criteria.** "Red on develop" is how each test fails before the fix. *assertion* = a behaviour assertion red on develop; *stub* = an exception from the gate's throwing stub; *pin* = green on develop, protected only by the named mutant.
| AC | Test (assert by id) | Red on develop | Mutant (must go red post-fix) |
|---|---|---|---|
| **AC-1** handheld sequence | O at 300 that both a recalc and `getIdsToCancelReplenishOrdersPage` select. Page selected, then claim via jdbcTemplate (500, op U). Then as U: `MRS.update(O, dto)` (PUT), `ROJS.cancelReplenishmentOrder(O)` on the pre-selected id, `recalculateOpenOrders(true)`, `fulfillMultipleUnitLoads` → **700**, source/requested/SU reservation consistent | **assertion**: PUT throws BusinessException (Bug 4); with PUT bypassed, cancel → 800 (Bug 3) | revert Fix D; revert Fix C |
| AC-2 job-cancel TOCTOU | as AC-1 up to the cancel, **without the PUT** → still 500/U, reservation intact, INFO skip | **assertion**: 800 | `findByIdForUpdate` → `findById` without the re-check |
| AC-3a release unit + polarity | rows 300 / 500-old / 500-fresh / 700 → `findIdsOfExpiredClaims` selects only 500-old; `releaseExpiredClaim(old)` → 300/null; positive control ≥ 1 selected | stub | `<` → `>`; drop `state =`; drop the re-check |
| AC-3b release in a tick | seam tick, TTL 120: O1 500/old (fixture is a **re-size, not cancel**: desired > threshold), O2 500/fresh → O1 `operator_id IS NULL AND state <> 500`; O2 500/U | **assertion**: O1 stays 500 (stub not wired, §7.2) | remove the sub-op call |
| AC-4 claimed sibling in inbound | item I, **no active FLA**. O1 300 null destination, O2 500 destination D, amounts so counting O2 flips O1 to **cancel**. `recalculateOrder(O1)` → O1 800. **Positive control:** same fixture with O2 at 300 → O1 800 on develop too | **assertion**: O1 re-sized, not 800 | ROMS back on `sumRequestedAmountForOpenOrders` |
| AC-5 contention | `runAs(U)` ∥ `runAs(V)` `start(O)` (latch) → exactly one 500/winner, the other `REPLENISH_RESERVED`, no OLE. U again → `modified` and `version` advanced | stub | drop `setModified`; lock → plain read |
| AC-6 reset ownership | V resets U's → RESERVED. U → 300/null. 300 → no-op. 700 → ALREADY_FINISHED | stub | drop the operator check |
| AC-7 holder PUT | U holds O: PUT as U → DTO. PUT as V → `BusinessException` whose message contains O's number and "another user" | **assertion** (both) | revert the admission; revert the message |
| AC-8 finish rules | 500 held by V, submitted by U → RESERVED, and the source UL has **not** moved. 300 → 700. Own 500 → 700. 800 → ALREADY_FINISHED. Same on `finishReplenishmentOrderInternal` | **assertion** on the foreign case; others pin | drop the guard; move it after `assignDestination…` |
| AC-9 resume | U holds → `GET /reservedOrder` as U returns O; as V null | pin | break the operator predicate |
| AC-10 move-sync | move O's source UL while 500 → `BusinessException` naming O | pin | `>=` → `>` STARTED |
| AC-11 outcomes | (a) claim ∥ `recalculateOrder(O)` → 500 (claim won) or claim-time ALREADY_FINISHED, never 500 with a released reservation. (b) smoke: `ROJS.cancel` ∥ `fulfillMultipleUnitLoadsTx` on a 300 order → no deadlock; 700, or 800 with the submit refused; reservation consistent | (a) stub; (b) pin | (a) lock → plain read; (b) none (an ABBA mutant is only probabilistically killable) |
| AC-12a D6 tick pin | seam tick with claimed O (jdbc, fresh) and a **positive control** P at 300 that `cancelReplenishmentIfFlowbinIsFull` cancels → P 800 **and** O's `modified`/`version` unchanged | pin (P proves the tick ran) | release query ignores the cutoff |
| AC-12b accepted writers | claimed O: `ROS.update(O,null,p)` and `ROS.updatePriority(O,p)` → `modified` **advances** | pin | n/a; documents D6 |
| AC-13 supervisor cancel locked | Thread T: `runAs(U)` + `new TransactionTemplate(tenantTransactionManager).execute(…)` locks O via `findByIdForUpdate` and awaits latch L. Thread 2: `runAs(V)` `cancelReplenishmentOrderById(O)`. The test polls `pg_stat_activity` (`wait_event_type = 'Lock'`, query on `replenishorder`, ≤ 10 s) to prove thread 2 waits. T sets O to 700, commits; `future.get(15, SECONDS)` → no exception, O stays **700**, SU reservation unchanged. Separately, 500 → 800 with WARN naming the holder. Worst case bounded by the SBDEV-3250 `lock_timeout` (10 s) and harness `statement_timeout` (8 s) | stub | bare `findById` → OLE or 800 |
| AC-14 seed | V2.2.36 literal == `WmsConstants` default **600**; no row → 600 | stub (constant) | change either literal |
| AC-15 heartbeat | (a) claim with `modified` = now − 10 min, U heartbeats, then `releaseExpiredClaim` → still 500/U. (b) seam tick after the heartbeat → still 500/U. (c) **strict**: on a lapsed O (300/null) U's heartbeat → `REPLENISH_CLAIM_LOST`, O still 300/null; on O held by V → `REPLENISH_CLAIM_LOST`, O still 500/V | (a) stub; (b) **pin** (develop has no release, so O stays 500 regardless); (c) stub | (a)(b) drop `setModified`; (c) heartbeat falls through to the start path (re-claims) |
| AC-16 contract | MockMvc with both advices registered: start ok → 200 + `claimTimeoutSeconds`. RESERVED → 409 `code=REPLENISH_RESERVED`. Heartbeat ok → 204; lost → 409 `code=REPLENISH_CLAIM_LOST`. Missing order → 404 `code=MsgCannotReadOrder`. `CannotAcquireLockException` → 409 `retryable:true`, no `code`. Reset ok → 204 | **assertion**: 404 (no mapping) | catch `Exception` broadly; drop `code`; **remove the local `FacadeException` catch → 500 with `reference`**, not 409 |
| AC-17 UI (Jest) | `selectOrder`: 409 `{code}` stays `1_select` and refreshes; 404/405 without `code` → `loadOrderById` and advances; 404 **with** `code` → toast, no fallback; fallback empty body → toast, stays `1_select`. **Heartbeat survives the source PUT (r3 H1), driven through the real actions from `1_select`:** a real `replenish` module (actions included, `$axios`/`$toast` mocked); mount at `1_select` and do **not** pre-seed the store (`created()` commits `resetState`, L104-106); `selectOrder` → start mock 200 `{id, claimTimeoutSeconds: 600}`; `updateOrderSourceLocation` → PUT mock returns a server-shaped DTO **without** `claimTimeoutSeconds`; `setProcess('2.5_unitLoad')` (as `selectSource.vue` L313 does — `stageUL` does not move the process), `stageUL` ×2; advance fake timers past ttl/4 → one heartbeat with `heartbeat=true`, `selectedULBatch.length === 2`, `order` deep-equals the PUT response; `setProcess('1.5_destination')`, advance again → a second heartbeat; `visibilitychange` → visible in `1.5_destination` posts at once. With `submitting` true a tick posts nothing. `'lost'` → toast, back at `1_select`, no reset posted. `'transient'` → timer keeps, no toast. Stale response (process changed to `1_select`, or `submitting` set, before it resolves) → no toast. Watcher: `2_source` → `1_select` with `order.id` posts reset with that id **and** the list refresh still runs; submit path (order nulled first) posts none. `created()` with a persisted id posts reset. Reset 404 and 409 swallowed, no toast. After `beforeDestroy`, `visibilitychange` posts nothing | **assertion**: develop dispatches `getOrderById` and advances | remove the advance guard; remove the fallback; **route the heartbeat through `startOrder`**; **read the TTL from `order.claimTimeoutSeconds`**; drop the `submitting` skip; add a second `process:` watcher key; drop the staleness check |

**Regression.** Full wms2-api suite against a baseline taken adjacent in time (known flaky: `OutboxConcurrentEnqueueIT`, `ReplenishDupConcurrencySliceIT`, ParcelMonitor IT). mobile-ui: `git ls-tree -r --name-only origin/develop -- test | grep -c '\.spec\.js$'` → **37 spec files on `62fc642`**; the executor records suite/test counts from a `jest` baseline run before the change and compares.

### Manual test plan
| Scenario | Env | Steps | Expected | P/F |
|---|---|---|---|---|
| Claim protects pick | dev | A opens order; web: fill dest FLA so the cron would cancel; wait 1 tick; scan + submit | 700 | |
| Second picker refused | dev | A opens; B taps the same order | B toast "locked by different user", stays on list | |
| Back / menu / re-entry releases | dev | A opens, then back, menu or reload; B opens | B succeeds | |
| Heartbeat holds, staging intact | dev | TTL 120 via the web sysprop screen; A opens, scans source, stages 2 ULs, idles 5 min screen on, submits | still 500/A while idle; submit 700 with both ULs | |
| **Screen-off / backgrounded** | dev | fleet handheld, TTL 120; A opens, scans source, stages 2 ULs (in `2.5_unitLoad`, and again in `1.5_destination`), then screen off (or app backgrounded) 5 min; check `modified` in DB; screen on | record whether `modified` advanced; on wake one heartbeat fires; if lapsed: "Claim lost", back at list (§7.1 check) | |
| Claim lost, then taken | dev | TTL 120; A opens, screen off past TTL + 1 tick; B claims; A wakes | A: "Claim lost", list; B keeps 500/B | |
| Timeout | dev | TTL 120; A opens, kill app; wait > 2 ticks | `state=300, operator_id null` | |
| Supervisor cancel | dev | A holds; web cancel | 800, WARN names holder; A's next heartbeat → "Claim lost" | |
| Old handheld / old API | dev | API new + old UI bundle; and UI new on an API without the endpoints | both: unchanged behaviour, 700 | |

## 9. Risks and mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| Abandoned claim hides an order from recalc/cron for ≤ TTL (D1 cost) | flowbin may run dry | NOT EXISTS (`< FINISHED`) sees 500, so no duplicate is generated; release runs first in the tick; TTL 600 (D7) |
| **Abandoned claim blocks moves of the order's source UL** (§0 #5-6) **and its FLA** (`FixLocationAssignmentService.move` L142) for ≤ TTL; **indefinitely where the ROJ gate is off** (non-PRD) | warehouse moves refused | message names the order; supervisor cancel; UI releases on every observable exit (Fix H) |
| Handheld browser freezes timers with the screen off → claim lapses mid-walk → another picker claims | first picker loses the order | visibility heartbeat reports "Claim lost" on wake, before the scan (P1); §7.1 fleet check gates 600, fallback = raise the sysprop; Follow-up 6 |
| Lapse while the picker has already pulled stock (no wake in between) | wasted pick, as today | heartbeat ttl/4; strict heartbeat makes it visible; Follow-up 6 |
| Old handhelds get no claim | unprotected, as today | D3 tolerant rule; Follow-up 1 |
| Claim, heartbeat or cancel waits behind a long tx | ≤ `lock_timeout` | 409 retryable (start toasts, heartbeat treats as transient); WARN in ROJ |
| A claim landing mid sub-op 9 rolls back that tick's batch (§0 #12) | one-tick delay | self-heals next tick |
| Supervisor cancels a claimed pick | wasted pick | deliberate; WARN; next heartbeat tells the picker; Follow-up 2 |
| Flyway collision | boot fails on merge | fetch + sweep immediately before merge (§7.1) |

## Horizontal scalability and v2 constraints

| Concern | Verdict |
|---|---|
| In-JVM state / request affinity | None: claim is in `replenishorder.operator_id/state`; the UI timer is per device |
| Pool math / long tx | One short tx per call; release is one REQUIRES_NEW per row, like the cancel sweep; heartbeat is one tiny tx per device per 150 s at the default |
| Scheduled jobs / tenant context | New sub-op inside ROJ, serialized by `JobLockId.REPLENISH_ORDER` per tenant, inside its `TenantContext` loop; no `@Async` |
| Retry / idempotency | start idempotent for the holder; heartbeat never re-claims; reset no-op on 300; release re-checks under the lock (AC-3, 5, 15c) |
| Lock correctness | `findByIdForUpdate` under `tenantTransactionManager`, SBDEV-3250 `lock_timeout`, order-only claim lock (AC-11); one lock-free legacy check (Fix E) |
| OSIV / tx manager / readOnly | admin cancel read moves inside the tx; every new method `tenantTransactionManager` with `rollbackFor` Business/Facade; no new readOnly method |
| Cache / Jakarta / H2 / metrics | entity not cached; sysprop read uncached on this path (Fix G); `jakarta.persistence` lock exceptions; JPQL only, Testcontainers; reuse `replenishSubOpRows` (published, not yet scraped) |
| External notifications | N/A: no OMS send on the touched paths |

**Completeness:** DB verified on 4 PRD tenants (UAT noted) · all callsites in §0 · sibling sweep in Fix C, D6 writer table in Fix G · backward compatible in both deploy orders (§5.0) · error contract in §5.0 · rollback: V2.2.36 is idempotent and harmless; revert the UI, then the API, then drain any 500s by setting the TTL to 1 · v1: no work (reference-only; same unwired `startOrder`).

## 10. Resolved decisions (Nam, 2026-10-02)

| # | Decision | Applied in |
|---|---|---|
| D1 | Claim on order open/select, before the source scan; pinned-until-reset/timeout accepted | Fix H, §9 rows 1-2 |
| D2 | Cron releases 500 → 300 after a sysprop TTL (timer and default superseded by D6/D7) | Fix G |
| D3 | `/multi-unitloads` + finish accept 300 and 500; reject only another operator's claim | Fix E |
| D4 | API first, then UI; each half deploys alone | §5.0 fallback, §7.1 |
| D5 | Reopen P8: changed premise is mid-pick cancellation; F8a stays | §1 |
| D6 | Timer = existing `modified`; only Flyway = sysprop seed; pin non-claim writers or state the blind spot | Fix G table, AC-12a/b |
| D7 | TTL default 600 s with heartbeat | Fix G, AC-14; gated by the §7.1 fleet check |
| D8 | Personal logins: a per-user claim suffices, no device token | §7.1 |
| D9 | Over-release is a separate ticket landing first → filed as SBDEV-3632, then closed as a duplicate of **SBDEV-3621** (already pr submitted); 3626 waits for 3621 to merge and rebases (Nam, 2026-10-02) | §7.1, §7.2 |
| D10 | Bulk-priority `state = FINISHED` bug filed as T1 → **SBDEV-3633** | Findings outside scope |

## 11. Review disposition

All r1–r3 findings from both lanes are addressed in the body; full reviews are in `.omc/research/SBDEV-3626-{architect,critic}-r{1,2,3}.md`. One finding was rejected: critic r1 L3b (web-cancel lock timeout → 500) — the controller catches only `FacadeException`, so the exception reaches the unscoped `@Order(0)` `RestExceptionHandler` → 409 (L370). Both reviewers confirmed the rejection in r2. Decided by Nam rather than by review: TTL (D7), shared logins (D8), over-release sequencing (D9), bulk priority (D10).

r2 → r3 in brief: separate `heartbeatClaim` that commits nothing, with staleness checks (H1); strict `?heartbeat=true` → `REPLENISH_CLAIM_LOST` (A-M2); 600 s gated by a visibility heartbeat and a fleet check (A-M1); AC-15b relabelled pin, stub-wiring rule (C-M1); `runAs` helper, AC-13 mechanics (C-M2); 404-with-`code` discriminator and empty-body fallback; AC-16 advices + mutant; full-tick IT pollution note; `@Cacheable` rationale corrected; one `process` watcher replaces the `goMain`/`selectSource` hooks; ROJS:244 deletion cut; Fix G catch compiles; AC-11b mutant dropped.

r3 → r4 (narrow; A-H1 = C-H1 plus Lows): TTL in its own store field `claimTtl`, never read from `order`; AC-17 drives the real actions through the source PUT, with the `order.claimTimeoutSeconds` mutant; screen-off row moved after staging; heartbeat skipped while `submitting`; release merged into the existing `process` watcher; `beforeRouteLeave` marked new; visibility listener removed in `beforeDestroy` and gated; reset swallows 409; AC-13 pool size 5; §8 ROJ L478. r4 verify Lows (verifier, `.omc/research/SBDEV-3626-verify-r4.md`): heartbeat response also ignored while `submitting`; AC-17 sets `2.5_unitLoad` explicitly; §5.0 rows name `setClaimTtl`.

## Findings outside scope (filed)

1. **[SBDEV-3633](https://app.clickup.com/t/868mcgc6v)** — `RR.bulkUpdatePriorityForItems[WithOldPriority]` is called with `State.FINISHED` against `r.state = :state` (from `ROS.updateReplenishmentOrderPriority(List,…)`; callers `CustomerorderService:616`, `CustomerorderBatchService:358`), so customer-order priority bumps never reach open orders. T1, every tenant. Independent of this ticket.
2. **[SBDEV-3621](https://app.clickup.com/t/868mc1d6c)** (SBDEV-3632 was filed for this and closed as its duplicate) — `ROS.cancelReplenishmentOrder` (L325-328) releases `requestedamount`, while `ROMS.cancelOrder` (L726-734) releases the held share (SBDEV-3618 Fix C, `3d0cf1e7`), so every ROJ and web cancel over-releases a cut reservation. **Prerequisite of every implementation step** (§7.1): Fix C changes only the callers, but routes more cancels through that body.

## ADR

- **Decision:** Wire STARTED 500 as an explicit, strictly heartbeated, server-released claim (Design A); close the cron-cancel TOCTOU under the row lock; tolerate unclaimed submits, and an absent API, during rollout.
- **Drivers:** mid-pick cancellation (§1); the TOCTOU that makes 500 alone insufficient (Bug 3); a mixed fleet.
- **Alternatives:** B (claim in a GET) invalidated, admin views would take claims. C (activity heuristic) invalidated, cron writes defeat it and pickers collide. D (book the physical move on a cancelled template) deferred: overfills, does not stop two pickers, fails P1; kept as a residual follow-up.
- **Why chosen:** fails at selection, before physical work (P1), and a strict heartbeat reports a lapse before the next scan; each half ships alone in either order (P3, §5.0); reuses existing columns, so the only Flyway file is a seed (D6).
- **Consequences:** an abandoned order, its source UL and its FLA are pinned ≤ TTL; a supervisor cancel can still kill a pick; old handhelds unprotected until upgraded; `modified` doubles as claim age and is extended by web priority edits (pinned); one heartbeat tx per open handheld per ttl/4; the 600 s default depends on the fleet browser keeping timers alive (§7.1), with a sysprop-only fallback.
- **Follow-ups:** (1) `REPLENISH_REQUIRE_CLAIM` once the fleet upgrades. (2) Holder column in "All" + web "release claim". (3) `/reservedOrder` resume banner. (4) Revisit the TTL per tenant from the fleet check (sysprop only). (5) SBDEV-3621 (merge first), SBDEV-3633. (6) Option D residual: accept a submit by the last holder of a system-cancelled order within the TTL.
