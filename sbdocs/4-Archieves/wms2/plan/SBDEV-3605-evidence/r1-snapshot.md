---
title: "Multi-UL pick releases only the order's own share of the old SU's reservation; locked template, state guard, credit == release; NULL-ordernumber release; Optional-by-SU finders"
ticket: "SBDEV-3605"
ticket_url: "https://app.clickup.com/t/868mbjatz"
type: "bugfix"
priority: ""
status: "pending approval"
tier: T3
repos: [wms2-api]
project: ["wms2"]
version: "v2"
requester: "Nam Park"
created: "2026-09-30"
updated: "2026-09-30"
db_verified: true
db_verified_note: "DEV wineco only; PRD classifier not run. Re-checked 2026-09-30 07:51Z: 565 open orders, 0 SUs with two open orders, 0 open orders with NULL stockunit_id. The 565 matches the analysis count and serves as the positive control."
base_commit: "wms2-api daf64d41 (origin/develop, fetched 2026-09-30); wms2-web-ui 299cec1 and wms2-mobile-ui 108b2f5 read-only (caller sweep)"
related:
  - "[[SBDEV-3561]]"
  - "[[SBDEV-3244]]"
  - "[[SBDEV-2610]]"
  - "[[260709]]"
  - "[[260713]]"
tags:
  - plan
---

# SBDEV-3605 — Multi-UL pick releases another order's reservation

**Ticket:** [SBDEV-3605](https://app.clickup.com/t/868mbjatz) · **Tier:** T3. It is data integrity: reservations move between SUs, and a check-then-act on the reservation runs on an unlocked read inside the only live pick transaction. Escalation trigger #2 fired because the fix adds a new repository method. · **Evidence:** `SBDEV-3605-evidence/analysis.md` (cited as *A§Qn*). Every snippet below comes from `git show origin/develop:<path>` at `daf64d41`.

## RALPLAN-DR summary

**Principles**
1. A release frees only what this order holds. Whatever the SU's other holders explain stays reserved.
2. The value used as the credit and the value released are one computation, done under the lock.
3. Each row's first touch in a transaction is its lock (SBDEV-3244). The order is locked first, then SUs.
4. Fail closed. Contention rolls the transaction back; it never proceeds on stale data.
5. Reuse existing surface. Add exactly one scalar query, found by grepping both repositories for an SU-keyed sum (none exists).

**Decision drivers:** (1) Order Y's reservation must survive order X's pick (IT-M1b). (2) Order X's own leak must not be stranded (REPL049240 would strand 7). (3) The change must stay small and reviewable inside the SBDEV-260713 multi-UL transaction.

**Options**

| Option | Pros | Cons | Verdict |
|---|---|---|---|
| **Requested-based:** release `min(requested, reserved)` | Trivial; no query | Strands own leaks forever. Nothing releases them once the order is 700, and a stranded SU is invisible to the generator (it requires `reservedamount = 0`). A§Q3b: REPL049240 would strand 7, REPL049628 would strand 5. SBDEV-3561 P10 names this explicitly as "must not" | Rejected |
| **Ledger-derived:** net Σ`reservedamountchange` for the order's number on the SU | Exact when the ledger is clean | The ledger is not clean. `releaseReservation` writes CANCELLED with NULL `ordernumber`. On SU 988285734 the order's own rows sum to 26,724 against a real reservation of 12 (A§Q8). Clamped releases record the requested delta, not the real change (D5b) | Rejected: the instrument is broken, and D4a only stops new damage |
| **Invariant-based (chosen):** `release = max(0, min(res, res − Σreq(other open replen) − Σamount(open picks)))`, under the old-SU lock | Releases own leaks, keeps every explained holder, and needs only current state. It measured correct on 430 "holds" SUs (A§Q2) | Holder-less (manual) reservations are released as part of the order's share (D3). Needs one new sum query | **Chosen** |

## 0. Affected sites

Enumeration: `git grep -n 'changeReservedAmount(' origin/develop -- src/main` found 27 delta arguments, all read (A§Q5). Positive control: the known site in `MobileReplenishService.applyExplicitSourceToOrder` is among the hits. Finder callers: `git grep -n 'findIdByStateLessThanAndStockunitId\|findByStateLessThanAndStockunitId' origin/develop -- src`. Positive control: both declarations (`ReplenishorderRepository` `Optional<Replenishorder> findByStateLessThanAndStockunitId(` and `Optional<Long> findIdByStateLessThanAndStockunitId(`) are among the hits.

| # | Site | Construct | Disposition |
|---|---|---|---|
| S1 | `MobileReplenishService.applyExplicitSourceToOrder` | `oldStockOpt.get().getReservedamount().negate()` from a plain `stockunitRepository.findById` | **Fix B** |
| S2 | `MobileReplenishService.validateUnitLoadEntry` | credit `template.getRequestedamount().min(reserved)` | **Fix C** (D2) |
| S3 | `MobileReplenishService.fulfillMultipleUnitLoadsTx` | `replenishorderRepository.findById(request.getOrderId())`, with no state check | **Fix A** |
| S4 | `ReplenishmentOrderMaintenanceService.releaseReservation` | `changeReservedAmount(source, releaseAmount.negate(), true, WmsConstants.CODE_REPLENISHMENT_CANCELLED, null, null)` | **Fix D** (D4a) |
| S5 | `ReplenishmentOrderMaintenanceService.reassignOrCancelForMovedStockUnit` | `.findIdByStateLessThanAndStockunitId(WmsConstants.State.FINISHED, movedStock.getId()).orElse(null)` | **Fix E**: List, lock each ascending, apply to each |
| S6 | `ReplenishmentOrderSourceSyncService.syncForMovedStockUnit` | same probe on `stockUnit.getId()` | **Fix E**: List, lock each ascending, re-point each |
| S7 | `ReplenishorderService.existsForStockUnit` (readOnly; called from `MobileMoveUnitloadService` at the scan-time banner and in `checkReservedStock`) | `findByStateLessThanAndStockunitId(...).orElse(null)` | **Fix E**: exists-semantics, deterministic first-by-id |
| S8 | SDR search `findByStateLessThanAndStockunitId` (exported, `@RestResource(path = "findByStateLessThanAndStockunitId")`) | Optional over HTTP | **Kept as is.** Changing the return type changes the HAL contract. There are 0 HTTP callers: `git grep` in web-ui 299cec1 and mobile-ui 108b2f5 returns nothing, with positive controls `replenishorder` (web-ui, 3 files) and `/replenish` (mobile-ui, 3 files). Blind spot: external callers and the OMS (oms-laravel-api HEAD: 0 hits). Un-exporting it is proposed (P-3) |
| X1 | `ReplenishmentReservationReconciliationService` `stockUnit.getReservedamount().negate()` | admin zeroing after re-checking `countStrandedReservationById` | Excluded: its purpose is to zero |
| X2 | `StockunitService.adjustReservedAmount` | admin absolute set | Excluded: deliberate |
| X3 | `updateRequestedAmount`, mobile `checkSource` switch/finish, `redirectSource`, cancel, generator, 12 picking sites | release the holder's own amount | Excluded: a different root cause (A§Q10) |
| X4 | `getAvailableIncludingReservation`; clamped-delta ledger drift | over-grant; wrong recorded delta | **D5, proposed, not filed** |

## 1. Problem

On `/multi-unitloads`, the first scanned UL re-sources the template order X. `applyExplicitSourceToOrder` then releases the old SU's **entire** `reservedamount` under `CODE_REPLENISHMENT_FINISHED` and X's number. If order Y (another replenishment) or an open pick also holds stock on that SU, their reservation is stripped silently. Y's later finish clamps at 0 via `zeroIfNegative`, so no error ever surfaces. SBDEV-3561's web redirect added an operator-driven trigger for this (3561 R8b). IT-M1b measured the effect on 2026-09-30: B's reservation ended at `0.0000` against an expected 3, and the FINISHED row was −8.

**DB evidence (DEV WineCo, 2026-09-30):**
- **Fires, but no harm observed.** 18 multi-UL releases on DEV. All 3 whole-amount FINISHED releases since 2026-01-01 cleaned up the order's own leak rather than stripping another order: REPL050660 −12, REPL049240 −12, REPL050443 −82 (the last on SU 21568079: +53, +29, −82, all its own) (A§Q2).
- **The ledger cannot arbitrate.** SU 988285734 carries an order-number net of 26,724 against 12 actually reserved. The cause is the Dec-2025 SWITCHED/CANCELLED loop, where each CANCELLED wrote a NULL number (A§Q8).
- **The invariant (reserved = Σ open replen requested + Σ open pick amount) across 2,238 in-scope SUs:** 430 hold, 1,753 leak (1,658 of them stranded with no holder, which the repo's own stranded SQL confirms verbatim), and 55 are under. Examples of "under": 987376483 (reserved 3, REPL049495 requesting 9) and 985090431 (reserved 5, REPL049523 requesting 12).
- **Harm is latent on DEV.** 0 SUs carry two open orders (re-queried today) and 0 SUs carry both pick and replen holders. Blind spot: DEV only. The PRD MCP servers failed to connect, and the PRD classifier (3561 §5.1 #0) has not run.

## 2. Root cause

- **Bug 1: whole-amount release from an unlocked read (S1).** The delta is computed from a plain `findById` snapshot. `changeReservedAmount` then locks and refreshes, but applies the caller's stale delta. The delta also has no notion of whose reservation it is.
- **Bug 2: credit/release mismatch (S2).** The validation credit is `min(requested, reserved)` but the release is `reserved`. The own-leak case (reserved 12, requested 5, qty 12) is rejected even though the release would free 12. In the broken case (reserved 2, Y requesting 3), 2 is credited against a reservation that belongs to Y.
- **Bug 3: unlocked template, no state check (S3, R10).** A concurrent `redirectSource` or cron recalc can move X between the read and the write. The transaction then releases from the wrong SU, or processes a 700/800 order. Only `@Version` at flush, or 40P01, stops it, and the flush-vs-lock order is unmeasured (3561 R10).
- **Bug 4 (D4a): NULL `ordernumber` on the release (S4).** Every redirect and cancel release by the maintenance service is anonymous in `stockrecord`. That is what made the ledger unusable.
- **Bug 5 (D4b): Optional-by-SU finders (S5–S7).** With two open orders on one SU, they throw `IncorrectResultSizeDataAccessException`. The repository's own comment says so: "behaviour preserved, not improved". The multi-UL path and the cron can both create that state (A§Q5 #3). A move or a scan of such a UL then 500s.

## 3. Architecture / key files

```
ReplenishController POST /v3/replenish/multi-unitloads (errors → 200 {errors}; runtime exc → 500)
 └ MobileReplenishService.fulfillMultipleUnitLoads (no tx) → self.fulfillMultipleUnitLoadsTx (@Transactional tenantTM)
     ├ [A] template findByIdForUpdate → state guard
     ├ [B] old SU findByIdForUpdate → ownShareOfReservation(oldSu, templateId)   ← new helper
     ├ assignDestinationForMultiUnitLoads (saves template.destinationId)
     ├ validateUnitLoadEntry × n  [C] credit = ownShare when scanned SU == old SU
     ├ lock scanned SUs ≠ old, ascending id
     ├ applyExplicitSourceToOrder  [B] release = ownShare → reserve scanned
     └ finish / createOrderFromTemplate … (unchanged, Fix A.2 flushes kept)
    post-commit: refillFixedLocations(); recalculateOpenOrders(true)   (unchanged, best-effort)
```
Files: `service/mobile/MobileReplenishService.java` (1503 lines; grep-only), `repo/jpa/ReplenishorderRepository.java`, `service/ReplenishmentOrderMaintenanceService.java`, `service/ReplenishmentOrderSourceSyncService.java`, `service/ReplenishorderService.java`. `PickingorderPositionRepository` is reused but not modified.

## 4. Fix design

### Fix A — template locked as its first read; state guard (Bug 3)
Before: `Optional<Replenishorder> templateOpt = replenishorderRepository.findById(request.getOrderId());`
After:
```java
Replenishorder template = replenishorderRepository.findByIdForUpdate(request.getOrderId())
        .orElseThrow(() -> new FacadeException("MsgCannotReadOrder"));
Integer state = template.getState();
if (state == null || state > WmsConstants.State.PROCESSABLE) {
    throw new BusinessException("Replenishment order " + template.getNumber() + " is in state " + state
            + "; only a PROCESSABLE (≤300) order can be picked.");
}
```
Nothing earlier in the transaction reads the row, because the new transaction starts in the wrapper's `self.` call and `spring.jpa.open-in-view=false`, so this is a first touch and not a version-checked upgrade. The BusinessException surfaces as the controller's 200 `{errors}` body, the same shape as every other refusal on this endpoint.

### Fix B — release this order's share, computed once under the old-SU lock (Bug 1)
Placed immediately after Fix A and the empty-list check, **before** `assignDestinationForMultiUnitLoads`:
```java
Stockunit oldSu = template.getStockunitId() == null ? null
        : stockunitRepository.findByIdForUpdate(template.getStockunitId()).orElse(null); // missing → no lock taken
BigDecimal ownShare = oldSu == null ? BigDecimal.ZERO : ownShareOfReservation(oldSu, template.getId());
```
```java
/** SBDEV-3605: the part of lockedOldSu's reservation no other live holder explains. Caller holds the row lock. */
private BigDecimal ownShareOfReservation(Stockunit lockedOldSu, Long templateId) {
    BigDecimal reserved = lockedOldSu.getReservedamount() == null ? BigDecimal.ZERO : lockedOldSu.getReservedamount();
    if (reserved.signum() <= 0) {
        return BigDecimal.ZERO;
    }
    BigDecimal others = replenishorderRepository.sumRequestedAmountOfOtherOpenOrdersOnStockunit(
            lockedOldSu.getId(), WmsConstants.State.FINISHED, templateId);
    BigDecimal picks = BigDecimal.ZERO;
    for (PickingorderPosition p : pickingorderPositionRepository.findByPickfromstockunitId(lockedOldSu.getId())) {
        if (p.getState() != null && p.getState() < WmsConstants.State.PICKED && p.getAmount() != null) {
            picks = picks.add(p.getAmount());
        }
    }
    return reserved.subtract(others == null ? BigDecimal.ZERO : others).subtract(picks).min(reserved).max(BigDecimal.ZERO);
}
```
New repository method (`@RestResource(exported = false)`, because this is a `@RepositoryRestResource` interface):
```java
@Query("SELECT COALESCE(SUM(r.requestedamount), 0) FROM Replenishorder r "
     + "WHERE r.stockunitId = :stockunitId AND r.state < :state AND r.id <> :excludedId")
@RestResource(exported = false)
BigDecimal sumRequestedAmountOfOtherOpenOrdersOnStockunit(@Param("stockunitId") Long stockunitId,
        @Param("state") Integer state, @Param("excludedId") Long excludedId);
```
`applyExplicitSourceToOrder` receives `(oldSu, ownShare)` instead of re-reading the SU:
```java
if (oldSu != null && ownShare.signum() > 0) {
    stockunitBusinessService.changeReservedAmount(oldSu, ownShare.negate(), true,
            WmsConstants.CODE_REPLENISHMENT_FINISHED, order.getNumber(), null);
}
```
- **Pick term.** It reuses `findByPickfromstockunitId` with the Java filter `state < PICKED`, the same predicate `MobileMoveUnitloadService.checkReservedStock` uses (`pick.getState() < WmsConstants.State.PICKED`). That avoids adding surface to a second repository, and it is indexed (`index_pickingorder_position_pickfromstockunit_id`). The cost is loading every historical position on one SU. Replenishment sources are reserve SUs, so the count is small; this is not measured (R6).
- **Clamps.** `max(0, …)`: if the SU is already under its holders (the 55 class), nothing is released and no row is written. `min(res, …)` only bites when a stored `requestedamount` is negative, which is bad data, and it caps the release at what is reserved.
- **Missing old SU.** No lock is taken (FOR UPDATE on a missing row locks nothing), `ownShare = 0`, and nothing is released. That matches today's `oldStockOpt.isPresent()` branch.
- **Auto-flush.** Both queries run before the template is dirtied, so the AUTO flush has nothing to write. If a later edit moved the computation after `assignDestinationForMultiUnitLoads`, the template's destination UPDATE would flush at the sum query instead. That is safe under the template lock, but a violation of `idx_replenishorder_active_item_dest` would then surface there instead of at the Fix A.2 flush. U-5 pins the ordering.
- **Side effect (D3).** A holder-less (MANUAL_ADJUSTMENT) reservation on the old SU is released as part of X's share, which is consistent with SBDEV-2610's stranded model.
- **Lock order:** template → old SU → scanned SUs ≠ old, ascending by id. The scanned SUs are locked right after the validation loop with `stockunitRepository.findByIdForUpdate(id)`. They are upgrades on rows `findByUnitloadId` loaded, so a concurrent change since the validation read throws `StaleObjectStateException` and rolls back. That is the same failure class `changeReservedAmount`'s own upgrade has today, and a passing version check proves the validation read was current.

### Fix C — credit == release (Bug 2; D2)
`validateUnitLoadEntry(template, dto, oldSu, ownShare)` replaces the four-clause add-back with:
```java
if (oldSu != null && oldSu.getId().equals(matching.getId())) {
    effectiveAvailable = effectiveAvailable.add(ownShare);
}
```
The old `min(requested, reserved)` rule guarded against over-crediting a reservation that would not be freed. The credit and the release are now the same `BigDecimal`, so they cannot diverge. The own-leak case (res 12, req 5, qty 12) now accepts: 12 is released and 12 is reserved. The broken case (res 2, Y 3) credits 0.

### Fix D — release carries the order number (Bug 4; D4a)
`releaseReservation(Stockunit source, BigDecimal releaseAmount, String orderNumber)`, with both callers passing `order.getNumber()`: `redirectSource` `releaseReservation(currentSource, safe(order.getRequestedamount()), order.getNumber())` and `cancelOrder`. The activity code is unchanged.

### Fix E — SU-keyed finders safe for two open orders (Bug 5; D4b)

| Caller | Semantics | Change |
|---|---|---|
| S5 `reassignOrCancelForMovedStockUnit` | Every active order bound to the moved SU must be redirected or cancelled. Taking one would leave the other pointing at an SU on a non-replenishable lane | `List<Long> findIdsByStateLessThanAndStockunitIdOrderByIdAsc` (`SELECT r.id … ORDER BY r.id`, exported=false). Loop: `findByIdForUpdate(id)` ascending (first touch preserved). Any `state >= STARTED` → throw (unchanged message). Else `redirectSource` or `cancelOrder` |
| S6 `syncForMovedStockUnit` | Re-point every bound order | Same List. Lock each ascending, block on any STARTED, re-point each |
| S7 `existsForStockUnit` | Exists plus one number for the scan banner | `Optional<Replenishorder> findFirstByStateLessThanAndStockunitIdOrderByIdAsc` (derived, exported=false): the lowest id, deterministic |

The Optional `findIdByStateLessThanAndStockunitId` is removed. After this change it has no callers, per the §0 grep. `ReplenishmentIdProjectionContractUnitTest` pins `"findIdByStateLessThanAndStockunitId/2"` and a name array, and both are updated to the new name. Its `never().findByStateLessThanAndStockunitId(any(), any())` pin stays valid.

## 5. File change summary

| File | Change |
|---|---|
| `service/mobile/MobileReplenishService.java` | Fix A/B/C. New constructor parameter `PickingorderPositionRepository` (the unit test needs a `@Mock`, or `@InjectMocks` passes null; SBDEV-3091 trap) |
| `repo/jpa/ReplenishorderRepository.java` | + `sumRequestedAmountOfOtherOpenOrdersOnStockunit`, + `findIdsByStateLessThanAndStockunitIdOrderByIdAsc`, + `findFirstByStateLessThanAndStockunitIdOrderByIdAsc`, − `findIdByStateLessThanAndStockunitId` |
| `service/ReplenishmentOrderMaintenanceService.java` | Fix D; Fix E S5 |
| `service/ReplenishmentOrderSourceSyncService.java`, `service/ReplenishorderService.java` | Fix E S6, S7 |
| tests | `MobileReplenishServiceUnitTest`: 18 `fulfillMultipleUnitLoads*` calls, whose template stubs move from `findById` to `findByIdForUpdate`. AC-5 test reversed. `ReplenishorderRedirectSourceIT` (IT-M1b enabled, plus new ITs). Reassign/SourceSync/ReplenishorderService unit tests. Projection contract test. New `ReplenishorderStockunitFinderIT` |

### 5.1 Prerequisites
- **#0 PRD classifier** (SBDEV-3561 §5.1 #0): run it read-only on the 4 PRD tenants when a tunnel is up and post the result to the ticket. **It does not gate this ticket.** It re-ranks D5 and tells us whether PRD harm is latent or real.
- **Worktree:** `.claude/worktrees/wms2-api/SBDEV-3605`, branch `bugfix/SBDEV-3605-multi-ul-release-own-share` off a freshly fetched `origin/develop`.
- **No Flyway.** `replenishorder_stockunit_id_index` and `idx_replenishorder_state_stockunit` exist in `V2.2.00__base_v2_schema.sql` (and onboarding `V2.1.04`).
- JDK 21 on PATH for the build and PIT; JDK 25 gives a silent 0% under PIT.

## 6. Implementation steps (atomic commits)
1. **Red tests.** IT-1..IT-7, U-1..U-7, U-A1, U-B1..B3 and IT-B1 are written, and each is confirmed failing for the stated reason. IT-M1b's `@Disabled` is removed.
2. Repository methods: the sum, the List, and findFirst; the Optional is removed; contract test updated.
3. Fix E (S5–S7) → U-B*, IT-B1 green.
4. Fix D → U-A1 green.
5. Fix A (template lock and guard; 18 stubs migrated) → U-4, U-7 green.
6. Fix B + C, including the reversed AC-5 test → IT-1..IT-7, U-1..U-3, U-5, U-6 green.
7. Docs (below).
8. Mutation pass (§8) and a baseline comparison of the full suite.

## 7. Horizontal scalability and v2 constraints

| # | Concern | Assessment |
|---|---|---|
| 1 | JVM-local state | None added. `ownShare` is a local |
| 2 | Lock medium | PG row locks (PESSIMISTIC_WRITE) inside `tenantTransactionManager`, so they hold across replicas |
| 3 | Lock timeout | `SET LOCAL lock_timeout`, **per acquisition**: 3 s in main, 10 s in the IT profile. Worst case is about (n + 2) × 3 s for n scanned ULs |
| 4 | Multi-UL vs web redirect | Both lock the order first, then SUs. No cycle. IT-7 |
| 5 | Multi-UL vs cron | Cron order: order → current SU → target SU. A residual ABBA remains, bounded by 40P01 or lock_timeout. It is the same class as the one already accepted in the maintenance comment |
| 6 | Multi-UL vs multi-UL, different orders | X: old A → scanned B; Y: old B → scanned A. That is an ABBA, bounded by 40P01, and it needs two pickers cross-scanning each other's sources at the same moment. Accepted residual (R3) |
| 7 | "Others" sum read time | Read after the old-SU lock. A cron placing Y on the SU must take the SU lock in `changeReservedAmount` first, so it serialises |
| 8 | Post-commit refill/recalc | Stays outside the transaction (AC-6b rail). Exercised by IT-6 |
| 9 | Caches | 0 `@Cacheable` on the four touched classes (`git grep`; positive control: `ClientController` has 4) |
| 10 | Retry after rollback | Whole-transaction rollback; the handheld resubmits. Idempotent, because nothing commits partially |

| v2 constraint | Plan conforms by |
|---|---|
| First-touch rule (SBDEV-3244) | Template and old SU are locked as first reads. The S5/S6 probes stay id-only |
| New `@Query` on an SDR interface | `@RestResource(exported = false)` per method, pinned by the projection contract test |
| Self-proxy transaction | Unchanged: `self.fulfillMultipleUnitLoadsTx` |
| OSIV | `spring.jpa.open-in-view=false`, so there is no pre-read before the service |
| REQUIRES_NEW under locks | None added (deadlock memory) |
| `@InjectMocks` constructor | The new repository needs a `@Mock` |
| `never()` null-blindness | Typed matchers. The `NeverMatcherNullBlindnessArchTest` inventory is updated if it counts new sites |
| Repository ITs commit | Assert by id, never `isEmpty`/`hasSize`. Fixture ids come from the existing 999x band |

## 8. Testing

**Integration** (`ReplenishorderRedirectSourceIT` on `AbstractReplenishRedirectPgFixture`; `fulfillMultipleUnitLoadsTx` on the injected bean unless stated):

| # | Scenario | Assert | Mutant that must turn it red |
|---|---|---|---|
| IT-1 | IT-M1b enabled: B reserved 8 (X 5, Y 3) | B.reserved = 3; FINISHED on B = −5 | Revert to the whole-amount release (measured −8, B = 0) |
| IT-2 | Own leak, cross-SU: B reserved 12, X req 5, no others | B = 0; FINISHED −12 | Requested-based release (B stays 7) |
| IT-3 | Own leak, same SU: amount 12, res 12, req 5, qty 12 | Accepted; FINISHED −12, CREATED +12, final res 0 after finish | Old credit rule → `MsgUnitLoadStockAlreadyReserved` |
| IT-4 | Open pick position (state < 600, amount 2) on B; B res 7 | B = 2 | Drop the pick term |
| IT-5 | Broken invariant: B res 2, Y (own destination) req 3 on B | B stays 2; 0 FINISHED rows for X's number on B | Remove `max(0, …)` |
| IT-6 | Wrapper `fulfillMultipleUnitLoads`, FLA `lowerbound ≤` post-transfer amount, `Y.manuallyoverridepriority = true` | Only X-numbered rows from the transaction; Y keeps 3 after the post-commit recalc | Whole-amount release |
| IT-7 | R10: T1 = `TransactionTemplate { redirectSource(X, B) }` held on a latch. T2 = multi-UL on A | T2 waits on the order row (`awaitOrderLockWait`, `pg_stat_activity`). After the release, T2 releases X's 5 from **B** and A keeps its remainder | Template read reverted to `findById` (no wait; releases from A) |
| IT-B1 | New `ReplenishorderStockunitFinderIT`: two open orders plus one 700 order on one SU | List = both ids ascending; findFirst = lower id; 700 excluded (by id) | Drop `ORDER BY` / `state <` |

IT-M1 stays green unchanged (X is B's only holder, so it still releases 5). It is a pin.

**Unit** (`MobileReplenishServiceUnitTest`, BigDecimal compared with `argThat(v -> v.compareTo(x) == 0)`):

| # | Assert | Mutant |
|---|---|---|
| U-1 | res 8, others 3, picks 0 → `changeReservedAmount(oldSu, −5, …FINISHED, number, null)` | `others` term dropped |
| U-2 | res 2, others 3 → `verify(never()).changeReservedAmount(eq(oldSu), any(BigDecimal.class), anyBoolean(), eq(CODE_REPLENISHMENT_FINISHED), anyString(), isNull())` | `max(0)` dropped |
| U-3 | Stored requested −4 on the other order, res 8 → release 8, not 12 | `min(res)` dropped |
| U-4 | `findByIdForUpdate(eq(orderId))` called; `verify(never()).findById(eq(orderId))` | Revert to `findById` |
| U-5 | `InOrder`: order lock → old-SU lock → sum → `assignDestination…` save → scanned-SU locks ascending (request lists ids 30, 20) | Swap / unsorted |
| U-6 | Credit == release: reversed AC-5 (res 12, req 5, qty 12) accepted; release −12 | Old rule |
| U-7 | Template state 700 / 800 / null → BusinessException; no `changeReservedAmount`, no `save` | Guard removed |
| U-A1 | `cancelOrder` and `redirectSource` release carry `eq("REPL-1")` | Pass `null` back |
| U-B1 | S5 with ids [7, 9]: both locked ascending, each redirected or cancelled; one STARTED → throw, no writes | Only the first processed |
| U-B2 | S6 with two ids: both re-pointed | Only the first |
| U-B3 | S7 uses `findFirst…OrderByIdAsc` | Reverted to the Optional finder |

**Run one IT on JDK 21:**
`JAVA_HOME=$(/usr/libexec/java_home -v 21) mvn -Dit.test=ReplenishorderRedirectSourceIT -Dtest=NoSuchTest -Dsurefire.failIfNoSpecifiedTests=false verify`. Use a positive selector only; `'!Class'` discards the includes. Before running, `pgrep -f surefire|failsafe`, because peer Maven runs share the reusable postgres.

**Baseline:** a detached origin/develop worktree, run adjacent in time to the post-change run. Known flakies are rerun first: `OutboxConcurrentEnqueueIT`, `ReplenishDupConcurrencySliceIT`.

**PIT:** the pom recipe from SBDEV-3561 §8.4, `-DtargetClasses=net.aim_ai.wms.service.mobile.MobileReplenishService -DtargetTests=net.aim_ai.wms.unit.service.mobile.MobileReplenishServiceUnitTest`. Every surviving mutant in `ownShareOfReservation`, Fix A or Fix C is killed or justified in the PR.

**Manual (DEV WineCo, handheld):**

| Case | Setup | Expect |
|---|---|---|
| Same-SU pick | Order on its own source | Accepted; stockrecord shows FINISHED −own share, CREATED +qty |
| Cross-SU pick | Scan a different UL | Old SU released by exactly X's share |
| Other holder | Second order placed on the old SU (web redirect, then cron) | Other order's reservation intact after the pick |
| Finished order | Resubmit a 700 order | `{errors}` naming the state; nothing written |

No verify script: this is T3 opt-in, and every assertion here is expressible and stronger as JUnit.

## 9. Risks

| # | Risk | Mitigation |
|---|---|---|
| R1 | Manual (holder-less) reservations released by a pick (D3) | Consistent with SBDEV-2610. Named in the PR and in the docs |
| R2 | The AC-5 reversal lets a same-SU own-leak pick through | Intended (D2). U-6 and IT-3 pin that credit == release |
| R3 | Multi-UL vs multi-UL and cron ABBA | Bounded by 40P01 / lock_timeout. Rollback, then retry |
| R4 | New stale-row throw at the scanned-SU lock | The same class as today's `changeReservedAmount` upgrade. It surfaces as a 500 and a retry |
| R5 | Fix E changes the move path from a 500 to acting on every order | Only reachable with two open orders on one SU (0 on DEV). U-B1/B2 |
| R6 | Pick-list load on an SU with long history | Indexed; reserve SUs. Replace with a scalar sum if profiling shows cost |
| R7 | PRD may hold real P10 harm we have not measured | #0 classifier posted to the ticket; the fix is correct either way |

## 10. Decisions, proposals, ADR

- **D1 (Nam 2026-09-30):** the invariant-based release under the old-SU lock. One new scalar sum, `exported = false`. The pick term reuses `findByPickfromstockunitId` (§4 Fix B).
- **D2:** credit == release. This reverses the 260709 AC-5 unit test and the "Do NOT 'correct'" rule in `wms2-multi-unitload-replenish.md`, and the reason is recorded in both.
- **D3:** holder-less reservations are released as part of the order's share.
- **D4:** (a) the release carries the order number (T1); (b) the SU finders are made safe (T2). Both are on this ticket.
- **D5, proposed and not filed (ranked):**
  1. **D5a, `getAvailableIncludingReservation` over-grant** (`amount − reserved + currentRequest`, `ReplenishmentOrderMaintenanceService`).
     - **Evidence:** 55 "under" SUs on DEV, net −445. REPL050060 was raised to 13 on a 12-unit SU.
     - **Blast radius:** orders ask for more than exists, which produces pick shortfalls, and it is the population that Fix B's `max(0)` clamp meets.
     - **Cost:** about ½ day, T2 (subtract other holders' share, using the same helper shape).
     - **Do this first.**
  2. **D5b, `changeReservedAmount` records the requested delta, not the clamped real change** (`recordChangeReservedAmount(stockUnit, amount, …)` after `newReservedAmount = BigDecimal.ZERO`).
     - **Blast radius:** ledger drift only; no stock is affected.
     - **Cost:** 1 line plus a test, T1, but every clamping caller's recorded rows change.
  3. **P-3, un-export the SDR `findByStateLessThanAndStockunitId` search.** 0 HTTP callers (§0 S8); it still 500s with two orders. T1, following the SBDEV-3486 pattern.

**ADR**
- **Decision:** the multi-UL pick releases `ownShareOfReservation` (the invariant remainder) under order-then-SU locks, and feeds the same value to the self-source credit.
- **Drivers:** protect other holders; do not strand own leaks; minimal change to the 260713 transaction.
- **Alternatives:**
  - Requested-based: strands leaks.
  - Ledger-derived: the ledger is corrupt.
  - Locking all SUs as one ascending set: removes R3's multi-UL ABBA, but splits `validateUnitLoadEntry` into resolve and check passes. Deferred.
- **Why chosen:** it is correct on every measured class (holds, own leak, under), and it uses current state only.
- **Consequences:**
  - Manual reservations are released (D3).
  - AC-5 is reversed.
  - One new repository query.
  - The template is locked for the whole pick transaction.
- **Follow-ups:** D5a, D5b, P-3, #0 classifier.

## Acceptance criteria

| AC | Statement | Test |
|---|---|---|
| AC1 | Another order's reservation on the old SU survives the pick | IT-1, U-1 |
| AC2 | The order's own leak is released in full | IT-2 |
| AC3 | Same-SU credit equals release | IT-3, U-6 |
| AC4 | Open-pick reservations survive | IT-4 |
| AC5 | Already-broken SU: nothing released, no row | IT-5, U-2, U-3 |
| AC6 | Post-commit recalc does not disturb other orders | IT-6 |
| AC7 | Concurrent redirect is serialised; release from the fresh source | IT-7, U-4 |
| AC8 | Non-PROCESSABLE template refused before any write | U-7 |
| AC9 | Lock order: template → old SU → scanned ascending | U-5 |
| AC10 | Maintenance releases carry the order number | U-A1 |
| AC11 | Two open orders on one SU: move handles all; banner deterministic | U-B1..B3, IT-B1 |
| AC12 | Full suite equals baseline; PIT survivors resolved | §8 |

## Docs to update
- `3-Resources/design/wms2-replenishment-design.md` §7:
  - fix the transaction boundary (the transaction is on `fulfillMultipleUnitLoadsTx`);
  - step 1 becomes "lock template, state guard";
  - step 4 becomes "release own share".
- `3-Resources/workflows/wms2-multi-unitload-replenish.md`: line 110 gets the credit rule, with "Do NOT 'correct'" replaced by the D2 reason; lines 54 and 100 ("release it") change; add a changelog row.
- `3-Resources/design/wms2-stockunit-design.md` (around line 389): add the holder invariant and D3.
- `3-Resources/architecture/wms2-transaction-osiv-boundary-map.md`: add a multi-UL entry with the lock order.
- `wms2-function-to-docs-map.md` §9: `MobileReplenishService` row pointing at the above.

## Layer-2 completeness checklist

| # | Item | ✓ | Ref |
|---|---|---|---|
| 0 | DB verified | ✓ | §1: DEV re-query 2026-09-30 with control; PRD #0 not run (stated) |
| 1 | Call sites | ✓ | §0: 27-site grep plus finder grep, each with a positive control; UI/OMS HTTP sweep with controls |
| 2 | Adjacent bugs | ✓ | D4a/D4b in scope; D5a, D5b, P-3 proposed |
| 3 | Backward compat | ✓ | SDR search kept (S8); the AC-5 reversal is intended (D2); error shape unchanged (200 `{errors}`) |
| 4 | Concurrency | ✓ | §4 lock order; §7 #3–7; IT-7; R3/R4 |
| 5 | Multi-tenant | ✓ | Row-level inside the tenant transaction; no tenant state added |
| 6 | Error handling | ✓ | Fix A guard; missing old SU; clamps; stale-lock rollback |
| 7 | Observability | ✓ | D4a makes release rows attributable; #0 classifier |
| 8 | Rollback / migration | ✓ | No Flyway; revert is a single-repo code revert |
| 9 | Test coverage | ✓ | §8: every test paired with a mutant; PIT scoped |
| 10 | v1↔v2 | no | v1 is reference-only |
