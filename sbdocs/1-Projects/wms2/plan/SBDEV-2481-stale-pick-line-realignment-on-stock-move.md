---
title: "Stale Pick-Line References Survive Stock / Unit-Load Moves — v2 PORT"
ticket: "SBDEV-2481"
ticket_url: "https://app.clickup.com/t/9006034209/SBDEV-2481"
pr: "https://github.com/SiteBossInc/wms2-api/pull/51"
type: bug
priority: urgent
status: implemented
project:
  - wms2-api
version: v2
requester: "v1→v2 sync sweep 2026-06-25 (Lane B, Feature A)"
created: 2026-06-25
updated: 2026-06-25
db_verified: false
v1_source_plan: "[[SBDEV-2481-stale-pick-line-realignment-on-stock-move]] (v1/wms-api, PR #176)"
v1_commits:
  - "7c47a2b (SBDEV-2481 — full feature)"
base_branch: "port/SBDEV-2488-relocation-stock-history (stacked — move() already @Transactional + recordRelocation loop from PR #49)"
related:
  - "[[SBDEV-2481-stale-pick-line-realignment-on-stock-move]]"
  - "[[260624-stock-unit-history-on-unitload-relocation]]"
tags:
  - plan
  - picking
  - move-stock
  - concurrency
  - v2-port
---

# Stale Pick-Line Realign/Block on Moves — v2 Port (wms2-api)

**V1 Source:** `sbdocs/1-Projects/wms1/plan/SBDEV-2481-stale-pick-line-realignment-on-stock-move.md` (v1 PR #176, commit `7c47a2b`). Read it for the full design rationale, lock-order discipline, taxonomy, and the cycle constraint.
**V2 Target:** `v2/wms2-api`. **Base branch: `port/SBDEV-2488-relocation-stock-history`** (stacked on the relocation PR #49 — see §0.1).
**Status:** PENDING APPROVAL (ralplan consensus). **Priority:** urgent (picking directed to invalid location).

> `db_verified: false` — v1 proved 37 stale rows on a live tenant; v2 is code-provable parity. The DBA close-out (detector count on a v2 tenant) is a deploy-time step.

---

## 0.1 Branch sequencing (NEW-1 resolution — USER-APPROVED: stack)

SBDEV-2481 and the relocation **PR #49** both rewrite `FixLocationAssignmentService.move()`. To avoid a hand-merge conflict, this port is built **on top of** the relocation branch `port/SBDEV-2488-relocation-stock-history`. On that base, `move()` already carries `@Transactional(value="tenantTransactionManager", rollbackFor={BusinessException.class,FacadeException.class})` and the post-save `recordRelocation` loop. SBDEV-2481 therefore:
- **PRESERVES** PR #49's `@Transactional` (does NOT re-add it) and the `recordRelocation` loop (orthogonal — stock-history logging).
- **DELETES** the broken finder + dead realign loop.
- Routes realign through Hook A.

If PR #49 merges to develop first, this branch rebases cleanly. The SBDEV-2481 PR targets `develop` (after #49) or stacks its PR on #49.

---

## 2. Summary

| Metric | Count |
|--------|------:|
| v1 sites | 13 + outbound-caller set |
| Confirmed-missing in v2 (port) | detector SQL (P0), broken finder, dead loop, Hook A, Hook B, owning-PO locks, `selectDestination` @Transactional, 2 new services |
| Already-correct in v2 | entry-method tenant-TM on the 3 chokepoint entries; `findByPickfromstockunitId`; `findByIdForUpdate`; all activityCode constants |
| NEW v2-only issues | NEW-1 (PR#49 collision — resolved by stacking), NEW-2 (FLA test depends on broken finder), NEW-3 (move() auto-commit if not transactional — moot on the stacked base), NEW-4 (cycle rationale correction), NEW-5 (PO lock into existing SBDEV-2232 block), NEW-6 (BOL bypasses choke), NEW-7 (recursion synchronous — safe), NEW-8 (`SEND_TO_NIRWANA` misspelling + 2 nirvana paths) |

**v2 divergences:** constructor injection (the 2 new services + the 2 modified services); `tenantTransactionManager` on every new `@Transactional`; Mockito 5 (mockStatic allowed); BOL shipping bulk-updates and bypasses the choke (so the taxonomy gate only needs to cover picking-finish/truck-load on the choke path); the realign primitive stays acyclic by injecting **repositories only** (NOT because `@Lazy` is absent — it exists in v2 — but because repos-only is the correct structural break).

---

## 3. V1 → V2 Applicability Analysis

| V1 site | v2 file:line | Verdict | Action |
|---------|--------------|---------|--------|
| P0 detector SQL missing `=` | `repo/jpa/PickingorderPositionRepository.java:46-47, :57-58` | **Needed (identical bug)** | Insert two `=` per query; `:69-70` (`...ById`) is the correct template. |
| `findByPickfromstockunitId` | `PickingorderPositionRepository.java:32-33` | Already-done | Reuse in both hooks. |
| Broken finder + guard + dead loop (ONE cluster) | stacked base: finder `findByCustomerorderpositionId(oldLocation.getId())` `:133`, guard `if(!updatePickingPositions && ...)` `:134`, dead realign loop (both fields=location name) `:176-182` | **Needed** | **Delete by SYMBOL** (lines drift on the stacked base): delete the `findByCustomerorderpositionId` finder, its `updatePickingPositions` guard-throw, and the `if (updatePickingPositions) { ... setPickfromlocationname/​setPickfromunitloadlabel = destination.getName() ... }` loop — the whole cluster. **PRESERVE PR#49's `recordRelocation` loop** (separate block, ~`:171-175` on the base — writes stock-history rows, different fields). |
| Choke A `setStoragelocationId` + recurse | `UnitloadBusinessService.java:263` (set), `:270-277` (sync `for` recursion); entry `transferUnitLoadToLocation:107-108` tenant-TM | **Needed (Hook A absent)** | Hook A after `:263`, before recursion; classify-gated; entry-method owning-PO lock. |
| Choke B `setUnitloadId` | `StockunitBusinessService.java:325` (set); entry `transferStockToUnitLoad:181-182` tenant-TM; existing lock block `:222-269` (SBDEV-2232) | **Needed (Hook B absent)** | Hook B after `:325`; owning-PO lock slotted into the existing block (NEW-5). |
| `selectDestination` not transactional | `mobile/MobileMoveStockService.java:229` (no class/method `@Transactional`) | **Needed** | Add tenant-TM `@Transactional`. |
| `sendStockUnitToNirvana` | `StockunitBusinessService.java:369` (`:390` setUnitloadId); + `UnitloadBusinessService.sendToNirvana:281` | Already-exists | Pass-through (block active + not-started; substitute only via ops flow). Key taxonomy on the constant (NEW-8). |
| Replenish-finish | `mobile/MobileReplenishService.java:490` | Already-done routing | Inherits Hook B. |
| Mobile move-UL | `mobile/MobileMoveUnitloadService.java:205` (`scanDestination`, tenant-TM) | Already-done routing | Inherits Hook A. |
| Web move-stock | `StockunitService.java:144-145, :208` | Already-done routing | Inherits Hook A/B. |
| Outbound pass-through callers | `PickingorderBusinessService:310` (FINISHED_PICKING), `MobileTruckLoadingService:244` (TRUCK_LOADING); **BOL bulk-updates, bypasses choke (NEW-6)** | Needed (taxonomy) | Taxonomy PASS_THROUGH; AC-7 covers picking-finish/truck-load (NOT BOL). |
| `findByIdForUpdate` | `PickingorderRepository.java:24-27` (PESSIMISTIC_WRITE, **1000ms** timeout) | Already-done | Reuse; mind 1000ms vs batch 5000ms (NEW-5). |
| activityCode constants | `WmsConstants.java:836,840,849-856,864,876,883-884` | Already-done | All present; `CODE_SEND_TO_NIRVANA` value is `"SEND_TO_NIRWANA"` (key on the constant). |

---

## 4. V2-Specific Adaptation Notes
1. **Constructor injection** for both new services + the `StockrecordService`/new-collaborator additions to modified services (no `@Autowired` fields).
2. **Tenant TM:** `PickLineRealignmentService` and `MobileMoveStockService.selectDestination` use `@Transactional(value="tenantTransactionManager", rollbackFor={BusinessException.class,FacadeException.class})`. The hooks run inside the entry methods' existing tenant tx (PROPAGATION_REQUIRED) — they join, but the primitive's own annotation must name the tenant TM for correctness under independent invocation/test.
3. **Cycle rationale (NEW-4 correction):** `PickLineRealignmentService` injects **repositories only** (`PickingorderPositionRepository`, `PickingorderRepository`, `StockunitRepository`, `LocationRepository`, `UnitloadRepository`) — never `PickingorderPositionService`/`*BusinessService`. v2 DOES use `@Lazy` elsewhere (incl. as cycle-breakers at `CustomerorderBatchService:113`, `MessageService:46`), and there's no `spring.main.allow-circular-references`, so a service→service cycle is still a default startup failure — but repos-only is the correct structural break, NOT a `@Lazy` crutch. The verify-script must check "repos-only / no `*BusinessService`/`PickingorderPositionService` injected", NOT "no `@Lazy` in the repo".
4. **`Set.of(...)`** for the taxonomy (Java 21) instead of v1's `HashSet`+`unmodifiableSet`.
5. **Taxonomy keys on constants** (`WmsConstants.CODE_*`), never string literals — `CODE_SEND_TO_NIRVANA` = `"SEND_TO_NIRWANA"` (NEW-8). Both nirvana paths (`SBS.sendStockUnitToNirvana`, `UBS.sendToNirvana`) classify consistently.
6. **Lock placement (NEW-5, architect-corrected):** the owning-Pickingorder `findByIdForUpdate` must be acquired at the **top** of `StockunitBusinessService.transferStockToUnitLoad` — **at `:184`, BEFORE the src-stockunit lock at `:188`** — NOT "into the `:222-269` block" (the src-stockunit lock is already at `:188`, so slotting the PO lock after it would **invert** the canonical *Pickingorder > Unitload/Stockunit* order). For `UnitloadBusinessService.transferUnitLoadToLocation`, acquire the PO lock at entry **before `:120`** (the first existing lock, dst-location). **Lock-order anchor (NEW-6 correction):** the canonical *PO-before-SU* order is NOT documented at `CustomerorderBatchRepository:33` (that doc-comment does not exist in v2). Derive it from the pick-confirm path — `PickingorderBusinessService` locks CO (`:523`) → PO (`:526`) → stock — and add a NEW lock-order doc-comment at `StockunitBusinessService` (next to the existing intra-method order comment at `:219-222`) and `PickingorderRepository.findByIdForUpdate`. **Move-vs-pick deadlock-freedom (state explicitly):** the move path locks the owning Pickingorder (and SU/UL/Location) but **NEVER** a Customerorder/CustomerorderBatch; the pick-confirm path locks CO→PO. Because the move path never acquires CO, there is **no CO↔PO lock cycle** between the two paths — so move-vs-pick cannot deadlock (it resolves by the 1000ms PO timeout). A future change that makes a move touch CO/CustomerorderBatch would reintroduce the cycle — guard against it in review.
7. **PO lock timeout is a design knob (ADR):** `PickingorderRepository.findByIdForUpdate` has a **1000ms** timeout vs CustomerorderBatch's 5000ms. PO-lock-**first** + 1000ms = a move **fast-yields to active picks** (intended: moves lose to picks), but also means a move can spuriously fail under any PO contention >1s. This is an explicit decision (§10 ADR), not a footnote.

---

## 5. Changes by File (Phased P0→P5)

### P0 — `repo/jpa/PickingorderPositionRepository.java` (detector SQL)
`getPickingorderPositionCount` (`:46-47`) and `getPickingorderPositions` (`:57-58`): insert the two missing `=` (`pp.pickfromstockunit_id = stockunit.id`, `stockUnit.unitload_id = unitLoad.id`), mirroring `getPickingorderPositionsById:69-70`. **Gates everything** (detector is the fail-open backstop).

### P1 — Taxonomy + realign primitive + hooks + locks
- **NEW** `service/PickLineActivityCodeClassifier.java`: `final` class, private ctor, `Set.of` BLOCK_REALIGN_CODES = {CODE_MOVE_FIX_ASSIGNMENT, CODE_MANUAL_TRANSFER, CODE_TRANSFER, CODE_ON_HOLD}; PASS_THROUGH_CODES = the broad set from the v1 impl (FINISHED_PICKING, FINISHED_PACKAGING_MOVE_TOTE, TRUCK_LOADING, SHIPPING, SEND_TO_NIRVANA, **MANUAL_SPLIT**, receiving/putaway/picking/packaging/damaged); `classify(code, suId)` → unknown/blank → PASS_THROUGH + WARN.
- **NEW** `service/PickLineRealignmentService.java`: `@Service`, `@Transactional(tenantTransactionManager,...)`, **constructor-injected repositories ONLY**. `isActive(pp)` (owning `Pickingorder.state >= WmsConstants.State.STARTED`), `assertNoActivePickFor(suId)` (block w/ exact ticket message → `BusinessException` → 422), `realignForMovedStockUnit(su, newUl, newLoc)` (inline `repository.save()`, rewrites `pickfromunitloadlabel`+`pickfromlocationname`, **keeps `pickfromstockunitId`** I-1), `lockOwningPickingorders(...)` (ascending-id dedup via `findByIdForUpdate`), tree helpers.
- **Hook A — locking via PRE-WALK at the entry method (architect-corrected, finding #2).** The carrier tree's child unit loads are only discovered *inside* `processTransfer` (`findByCarrierunitloadId:268`) during the synchronous recursion (`:270-277`), so the entry method **cannot** know the full set of owning Pickingorders unless it walks the tree first. Therefore, at the top of `transferUnitLoadToLocation` (before any write), when `classify(activityCode)==BLOCK_REALIGN`:
  1. **Pre-walk** the whole carrier tree transitively (`findByCarrierunitloadId` from the top UL) + `stockunitRepository.findByUnitloadId` per node → collect all backing stock-unit ids.
  2. `pickingorderPositionRepository.findByPickfromstockunitId(suId)` → collect distinct owning `pickingorder_id`s.
  3. **Sort ascending, dedup, lock once each** via `PickingorderRepository.findByIdForUpdate` (this is the only way to guarantee ascending-id ordering across the whole tree — locking on-demand during traversal would lock in tree order, not id order → deadlock risk).
  4. Then proceed into `processTransfer`.
  The per-node guard then runs inside `processTransfer` after `:263` (`setStoragelocationId`), before recursion: for each `stockunitRepository.findByUnitloadId(unitload.id)` → `assertNoActivePickFor` (belt-and-suspenders; the PO is already locked) then `realignForMovedStockUnit`. **Cost owned:** this is a second tree traversal in addition to `processTransfer`'s own walk — acceptable because carrier trees are shallow and the finders are indexed (§7-#2). The pre-walk logic must stay in sync with `processTransfer`'s walk shape.
- **Hook B** — `StockunitBusinessService.transferStockToUnitLoad`: per-stockunit classify→guard after `:325` (`setUnitloadId`); owning-PO `findByIdForUpdate` acquired at **`:184` (before the src-stockunit lock at `:188`)**, not in the `:222-269` block (NEW-5/finding #1). Single-SU path here, so no tree pre-walk — just lock the one backing SU's owning PO(s). **Overload note:** `transferStockToUnitLoad` has TWO tenant-TM overloads — an 8-arg (`:173`) and a 9-arg (`:182`, `preloadedFixLocationAssignment`). Hook B + the PO lock go in the **9-arg** (`:182/:184/:188/:325`); **confirm the 8-arg delegates to the 9-arg** (so hooking once covers both) rather than duplicating the choke.
- Inject `PickLineRealignmentService` (constructor) into `UnitloadBusinessService` + `StockunitBusinessService`; `PickLineActivityCodeClassifier` is static (no injection).
- **Taxonomy must ENUMERATE every choke-reaching code (finding #5)** — do not rely on fail-open for legitimate inbound flows. Confirmed choke-reaching codes to classify + unit-test each: BLOCK_REALIGN = {`CODE_MOVE_FIX_ASSIGNMENT`, `CODE_MANUAL_TRANSFER`, `CODE_TRANSFER`, `CODE_ON_HOLD`}; PASS_THROUGH = {`CODE_FINISHED_PICKING`, `CODE_TRUCK_LOADING`, `CODE_MANUAL_SPLIT`, + receiving/putaway/palletising/hub-spoke/assign-tote/packaging/damaged inbound codes that reach `transferUnitLoadToLocation`/`transferStockToUnitLoad`}. **Known fail-open hole (detector-backstopped):** `MobileTransferOrderService:392` calls `transferUnitLoadToLocation(..., null, ...)` with a **null** activityCode → classifies PASS_THROUGH (won't block, won't realign) — a real pre-pick transfer-order move that the **P0 detector must catch**. Documented, not silently relied upon.

### P2 — `FixLocationAssignmentService.move()` (on the stacked base)
- **PRESERVE** PR#49's `@Transactional(tenantTransactionManager,...)` + `recordRelocation` loop (do NOT duplicate/remove).
- **DELETE the whole `updatePickingPositions` cluster** (resolves the prior delete-vs-keep contradiction): the `findByCustomerorderpositionId(oldLocation.getId())` finder (base `:133`), its guard-throw (`:134`), and the `if (updatePickingPositions) { ... }` realign loop (`:176-182`). Realign now happens inside Hook A (the UL is relabeled before transfer so the realigned label matches).
- **`updatePickingPositions` parameter fate (D-13):** check `FixLocationAssignmentController` + any other caller of `move(...)`. If no caller relies on `updatePickingPositions=false` to skip (the finder was always empty, so the skip never did anything), **drop the parameter** from `move(...)` and the controller call. If a caller's signature can't change cheaply, retain it as a documented no-op. Decide at implementation; do not leave it ambiguous.
- **NEW-2 (expanded):** `FixLocationAssignmentServiceUnitTest` mocks `findByCustomerorderpositionId(1L)` at **8 sites** (`:507, :520, :541, :563, :580, :604, :655, :696`) — not just the first four. Rewrite/delete **every** test method exercising the deleted finder/guard/loop; after deletion the later 4 mocks become unused-stub/behavior-mismatch failures if left. Add `move_stillInvokesRecordRelocation` (assert PR#49's loop is preserved) and `move_routesThroughHookA` (delegates to `transferUnitLoadToLocation` with `CODE_MOVE_FIX_ASSIGNMENT`).

### P4 — `mobile/MobileMoveStockService.selectDestination:229`
Add `@Transactional(value="tenantTransactionManager", rollbackFor={BusinessException.class,FacadeException.class})` so a block rolls back the outer write (mobile atomicity, AC-2/I-2).

### P5 — nirvana / replenish
`sendStockUnitToNirvana` + `UBS.sendToNirvana` pass-through (block active + not-started; substitute only via ops flow, D-5). Replenish-finish inherits Hook B.

---

## 6. NEW Issues
| NEW-# | Severity | Issue | Resolution |
|-------|----------|-------|-----------|
| NEW-1 | High | PR#49 `move()` collision | **Resolved** — stack on the relocation branch (§0.1). |
| NEW-2 | High | FLA unit test depends on the broken finder (`:504-577`) | Rewrite those tests in P2. |
| NEW-3 | Medium | `move()` auto-commit if not transactional | Moot on the stacked base (PR#49 added the tenant TM). Verify it's present. |
| NEW-4 | Medium | v1 cycle premise (`no @Lazy`) false in v2 | Rationale corrected (§4.3); verify-script checks repos-only, not `@Lazy`. |
| NEW-5 | Medium | Owning-PO lock into existing SBDEV-2232 block; 1000ms PO timeout | Slot in canonical order, no inversion; document lock-order comment. |
| NEW-6 | Low | BOL bypasses the choke (bulk update) | AC-7 covers picking-finish/truck-load only, NOT BOL. |
| NEW-7 | Low | `processTransfer` recursion synchronous | Positive — TenantContext safe across the tree (multi-replica OK). |
| NEW-8 | Low | `CODE_SEND_TO_NIRVANA`=`"SEND_TO_NIRWANA"`; two nirvana paths | Key taxonomy on the constant; classify both paths. |

---

## 7. Implementation Priority & Horizontal Scalability

**Order:** P0 → P1 → P2 → P4 → P5. **Prerequisites:** base branch = relocation branch; SBDEV-2116 `BusinessException`→422 (already in v2 via `RestExceptionHandler`); no schema change.

### Horizontal Scalability Validation
| # | Concern | Verdict | Evidence |
|---|---------|---------|----------|
| 1 | In-JVM state | N/A | Per-tree `Set<Long> lockedPickingorderIds` is request-scoped local. |
| 2 | Connection pool | Yes (bounded) | Extra `findByPickfromstockunitId`/`findByIdForUpdate` per blocked/realigned SU within the existing tx; indexed, bounded. |
| 3 | Scheduled jobs | N/A | None. |
| 4 | Long transactions | Yes (bounded) | Pessimistic locks held within the move tx; PO timeout 1000ms bounds waits. |
| 5 | Request affinity | N/A | — |
| 6 | Retry / idempotency | N/A | Block rolls back the whole move; operator retries. |
| 7 | Tenant context | Yes (safe) | `processTransfer` recursion is a synchronous `for` (NEW-7); no async hand-off. |
| 8 | Distributed lock | Yes | DB-level `PESSIMISTIC_WRITE` on owning Pickingorder, ascending-id, deduped — serializes move vs pick-start across replicas. |
| 9 | Cache invalidation | N/A | No cached entity mutated by realign. |
| 10 | External notifications | N/A | No OMS/printer. |

---

## 8. Testing Plan

**Unit (Mockito 5 — mockStatic OK):**
- `PickLineActivityCodeClassifierUnitTest`: BLOCK_REALIGN set; `CODE_MANUAL_SPLIT`→PASS_THROUGH; PASS_THROUGH set; unknown/blank→PASS_THROUGH+WARN.
- `PickLineRealignmentServiceUnitTest`: `isActive` authority by owning-order state (compare by `getId()`); `assertNoActivePickFor` exact message; `realign_rewritesLabelAndLocation_keepsStockUnitId` (I-1); `realign_usesRepositorySave_notFixPickingPosition` (#A repos-only/no-cycle).
- `FixLocationAssignmentServiceUnitTest` (rewrite NEW-2): broken finder/loop gone; routes through `transferUnitLoadToLocation`; **assert PR#49's recordRelocation loop still invoked** (don't regress the stacked change).
- `UnitloadBusinessServiceUnitTest` / `StockunitBusinessServiceUnitTest`: new collaborator (`PickLineRealignmentService`) mocked; Hook invoked for BLOCK_REALIGN, NOT for PASS_THROUGH.

**Integration (Testcontainers Postgres via `@ActiveProfiles("integration")` — the documented SBDEV-2217 workaround; H2 where SQL-compatible):**
- `detector_seedMismatch_countGtZero_thenZero` (P0).
- `fixedAssignmentMove_notStarted_realigns` (AC-1); `move_activeOrder_blocksAndRollsBack` (AC-2).
- `mobileMoveStock_block_noWriteCommitted` (#3, needs the new `@Transactional`).
- `prePickEntryPoints_sameBehavior` parameterized (AC-3).
- `postPickOutbound_passThrough` (AC-7) — **picking-finish + truck-load only** (NOT BOL — NEW-6).
- `manualSplit_passThrough`; `sendToNirvana_blocksActiveAndNotStarted` (D-5); `concurrentMoveTrees_noDeadlock` (AC-6); `ulTree_sameOrderTwice_lockedOnce`; `context_loads` (no cycle — #A).
- `move_yieldsTo_inFlightPick_within1s` (AC-6/ADR knob) — an active pick holds the owning PO `findByIdForUpdate`; a concurrent move on the same order **fast-yields at the 1000ms PO timeout** (fails, does not block the pick, no stale write committed). This is the contended counterpart to AC-2's single-thread block.
- `detector_catchesNullCodeTransferOrderMove` — seed a `MobileTransferOrderService`-style move with `activityCode=null` (fail-open PASS_THROUGH) that strands a pick line; assert the (post-P0) detector count catches it — proves the compensating control for the documented null-code hole.

> **IT-lane note:** detector + lock/deadlock tests target Testcontainers Postgres (H2 emulates native SQL + `PESSIMISTIC_WRITE` poorly). If the `@ActiveProfiles("integration")` boot still fails in this environment, mark the affected ITs `@Disabled("SBDEV-2217")` with a TODO and verify those ACs via staging — but PREFER running them (the architect confirmed the profile workaround boots the Testcontainers lane).

### Acceptance Criteria
AC-1 realign on not-started (owning order <500); AC-2 block + full rollback on active (>=500); AC-3 all pre-pick entry points identical; AC-4 nirvana blocks (active + not-started); AC-5 detector count 0 after realign; AC-6 no deadlock under concurrent move trees; AC-7 outbound (picking-finish/truck-load) pass-through — no block, no string mutation; AC-8 `CODE_MANUAL_SPLIT` pass-through; AC-9 context loads (no cycle); I-1 `pickfromstockunitId` never rewritten.

**Manual:** the v1 plan's 11-case matrix, on a v2 tenant (drop the BOL-via-choke case; BOL ships via bulk update).

---

## 9. Risks
| ID | Risk | Mitigation |
|----|------|-----------|
| R-1 | Hook halts shipping/split | Taxonomy PASS_THROUGH; AC-7 + `manualSplit_passThrough`. |
| R-2 | Lock-order inversion → deadlock | Slot owning-PO lock into the existing SBDEV-2232 order (NEW-5), ascending id, dedup; `concurrentMoveTrees_noDeadlock`. |
| R-3 | Mobile block not atomic | `@Transactional` on `selectDestination`; `mobileMoveStock_block_noWriteCommitted`. |
| R-4 | StaleObjectState from lock+reuse | Lock first, rebind from fresh read. |
| R-6 | Spring cycle (hard startup fail) | Repos-only primitive (NEW-4); `mvn clean compile` + `context_loads` IT. |
| R-9 | PR#49 stacking drift | Built on the relocation branch; preserve its `@Transactional`+recordRelocation; rebase if #49 changes. |
| M3 | Fail-open relies on detector | P0 fixes the detector first; alert on count>0. |

---

## 10. ADR
- **Decision:** Port SBDEV-2481 to v2 with v2 adaptations (constructor injection, tenant TM, taxonomy on constants, repos-only acyclic primitive), stacked on the relocation branch to resolve the `move()` collision.
- **Alternatives:** off-develop independent PR (rejected — hand-merge conflict on move()); merge #49 first (viable but blocks on review). Stacking chosen (user-approved).
- **Decision (lock timeout knob):** owning-Pickingorder lock is acquired **first** (before SU/UL/Location) with the existing **1000ms** `findByIdForUpdate` timeout. This intentionally makes a move **fast-yield to active picks** — the move aborts at 1s rather than blocking a pick-confirm. Accepted trade-off: a move can spuriously fail under heavy PO contention (>1s), which is preferable to a move winning a race against an in-flight pick.
- **Decision (tree locking):** pre-walk the carrier tree at the entry method to collect+sort+lock all owning POs ascending BEFORE `processTransfer` (finding #2) — correctness/determinism over the cost of a second shallow traversal.
- **Consequences:** the SBDEV-2481 PR depends on PR #49 landing first (or merges stacked). Concurrency ACs verified via the Testcontainers integration profile. Deleting the broken `:127` finder also removes the now-dead `:128` `updatePickingPositions` guard-throw (it never fired — the finder was always empty); D-13 confirm no caller depends on that throw.
- **Follow-ups:** D-13 (`updatePickingPositions` fate + dead `:128` guard); the v2 lock-order doc-comment gap (anchor on `PickingorderBusinessService` pick-confirm order, not the non-existent `CustomerorderBatchRepository:33`); if the IT profile can't boot here, disable + staging-verify the concurrency ACs.

---

## 11. Implementation Status

**Implemented 2026-06-25** (v1→v2 sync sweep, Lane B Feature A) on branch `port/SBDEV-2481-stale-pick-line` (**stacked on `port/SBDEV-2488-relocation-stock-history`**), commit **`024eab3`**, **[PR #51](https://github.com/SiteBossInc/wms2-api/pull/51)** (base = relocation branch; retarget to develop after #49). Consensus: ralplan (Planner → Architect SOUND-WITH-NITS → Critic APPROVE, iter 2); TDD-gate (8 unit fail-first → green).

| Phase | Status | Notes |
|-------|--------|-------|
| P0 detector SQL | ✅ | `PickingorderPositionRepository` — two `=` inserted (`:46-47`, `:57-58`). |
| P1a classifier | ✅ | `PickLineActivityCodeClassifier` — `Set.of` taxonomy on `CODE_*`; fail-open + WARN. |
| P1b realign service | ✅ | `PickLineRealignmentService` — **repos-only (verified: 5 repositories, zero `*Service` deps → no DI cycle)**; isActive/assertNoActivePickFor/realignForMovedStockUnit (I-1 keeps `pickfromstockunitId`)/lockOwningPickingorders/collectStockUnitIdsForUnitloadTree. |
| P1c Hook A | ✅ | `UnitloadBusinessService` — **pre-walk** lock at entry (`:130-131`); per-su guard in `processTransfer` (`:292-293`). |
| P1d Hook B | ✅ | `StockunitBusinessService` — PO lock before src-SU lock (`:204`); guard after `setUnitloadId` (`:356-357`); lock-order doc-comment added. |
| P2 FLA move() | ✅ | Deleted broken finder + dead loop + **dropped `updatePickingPositions` param** (D-13: sole caller passed `true`; controller → 2-arg). **Preserved** `@Transactional` (`:108`) + `recordRelocation` (`:172`). |
| P4 mobile @Transactional | ✅ | `MobileMoveStockService.selectDestination` tenant-TM. |
| Unit tests | ✅ **103/103** | classifier 6, realign 4, FixLocationAssignment 36, Unitload 27, Stockunit 30. `mvn clean compile` SUCCESS. |
| Integration tests | ⏸ **written, `@Disabled`** | `PickLineRealignmentIT` (12 methods: detector, AC-1/2/4/6/7/8, context-load, fast-yield knob, null-code detector). **Blocked by SBDEV-2217** (v2 Testcontainers lane). **AC-1/2/6/7 + detector + block-rollback NOT verified in CI this pass** — enable + verify once SBDEV-2217 lands, or staging-verify. |

**Adaptations:** line drift handled by symbol-anchoring (transfer/lock/setStoragelocationId lines differ from plan); `processTransfer` signature widened to `throws FacadeException, BusinessException`; `updatePickingPositions` param dropped (controller test updated); the now-unused `pickingorderPositionRepository` field in `FixLocationAssignmentService` retained (harmless; avoids ctor/@Mock churn).

**Follow-ups:** SBDEV-2217 (enable the concurrency ITs); §7.3-style backfill of stale rows at deploy on a v2 tenant; the unused FLA repo field could be removed in a cleanup.
