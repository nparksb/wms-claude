---
title: "Replenishment redirect takes its two stock-unit locks in role order, not id order: close the target-acquisition edge"
ticket: "SBDEV-3637"
ticket_url: "https://app.clickup.com/t/868mcjv7b"
type: "bugfix"
priority: "low"
status: "implemented"
tier: T3
repos: [wms2-api]
project: ["wms2"]
version: "v2"
requester: "Nam Park"
created: "2026-10-04"
updated: "2026-10-05"
revision: "r3 — ralplan round 3, final. Revised against review-architect-r2.md (SOUND-WITH-CHANGES; 8/10 cleared, A-7 NOT cleared and raised to HIGH, plus A-5′/A-5″/N-2) and review-critic-r2.md (ITERATE; H1,H3,H4,H5,H6 cleared, H2 PARTIAL = NEW-1 the single blocker). Both reviewers converged on ONE blocker: r2 deleted r1's false 'already deadlock-free' justification and put a DIFFERENT false one in the same slot ('neither of those cycles runs through two stock units'). r3 deletes that too and does NOT replace it with a third — it states the split verdict (always-skip-locked WOULD close the transferStockToUnitLoad cycle, would NOT close the cancelReplenishmentOrder one) and re-bases the hybrid on the measured 253/329 cost. P-7 re-ranked first. r2 revised against review-architect.md / review-critic.md; r1 grounded on lane-a/lane-b/lane-c."
db_verified: true
db_verified_note: "wsl-wineco-uat (570 PROCESSABLE orders, edge split measured), nywh-hydra-prd, nywh-hydra-uat, 2026-10-04. ⚠ Both ShipItEZ prd roles return `permission denied for table replenishorder`, and both prd MCP endpoints resolve to `current_database() = wh01_hydra_v2`. Every zero below is a three-tenant measurement, not a fleet measurement."
base_commit: "wms2-api ec42f43a (origin/develop, fetched 2026-10-04) — read in .claude/worktrees/wms2-api/SBDEV-3637-readonly"
related:
  - "[[SBDEV-3244]]"
  - "[[SBDEV-3250]]"
  - "[[SBDEV-3561]]"
  - "[[SBDEV-3618]]"
  - "[[SBDEV-3622]]"
  - "[[SBDEV-3626]]"
tags:
  - plan
---

# SBDEV-3637 — Replenishment redirect locks two stock units in role order, not id order

**Ticket:** [SBDEV-3637](https://app.clickup.com/t/868mcjv7b) · **Tier:** T3 (lock-topology change on the replenishment choke point) · **Branch:** `bugfix/SBDEV-3637-replenish-redirect-lock-order` · **Worktree:** `.claude/worktrees/wms2-api/SBDEV-3637` · **Evidence:** `SBDEV-3637-evidence/{lane-a-tracer,lane-b-architect,lane-c-enumeration}.md`

**Severity is genuinely LOW — on a measurement, not on a structural argument.** The measured count of items with ≥2 active orders is **0** on all three readable tenants, `pg_stat_database.deadlocks` is 0 on all three, and no production occurrence has been reported.

⚠ **The unique indexes do NOT bound this, and r1 claimed they did.** `idx_replenishorder_active_item_dest` is `(itemdata_id, destination_id) WHERE (state < 700)` (`src/main/resources/db/migration/V2.2.00__base_v2_schema.sql`) — it caps active same-item orders **per destination**, so N distinct destinations permit N active same-item orders for one item. The repo's own `ReplenishorderRedirectSourceIT` seeds exactly that shape (`replen(ORDER_Y, Y_NUMBER, SU_B, LOC_B, LOC_DEST_Y, new BigDecimal("3"))` alongside `ORDER_X` on `LOC_DEST`, same `ITEM`, both `state = 300`), and §7.2 **depends** on it. Only `idx_replenishorder_active_item_no_dest` — `(itemdata_id) WHERE ((state < 700) AND (destination_id IS NULL))` — is a true per-item cap, and only for destination-less orders. **The measured zero stands as a measurement; the mechanism r1 attached to it does not, and no claim below may lean on it.**

This is a correctness-of-topology fix, not an incident response. It is T3 because it changes the lock order at the busiest write path in the replenishment subsystem, not because the symptom is urgent. The cheapest alternative — **do nothing** — is weighed explicitly in §4 Fix B.

---

## 0. Affected sites

**Derivation (three mechanisms, because no single one is complete — from lane-c §1.1):**
- **(a)** `git grep -n "stockunitRepository\.findByIdForUpdate" -- src/main/java` → **17** call sites across 7 files. Cross-checked by `git grep -c` over the same pattern, whose per-file counts sum to 17 (`1+1+3+5+4+1+2`). Two instruments agree. **All 17 are tabulated below**, each with its own in-scope verdict. ⚠ r1 derived 17 and tabulated 10; among the seven it dropped was `StockunitBusinessService.transferStockToUnitLoad`, which is the *same defect shape as this ticket* (H2 below). A silently dropped row is the exact failure this section exists to prevent, so the table is now keyed to the derivation and must stay that way.
- **(b)** `git grep -in "for update" -- src/main/java` → exactly one executable native Stockunit lock, `StockunitRepository.getStockUnitsByItemDataIdForUpdate`.
- **(c)** `git grep -n "@Lock(" -- src/main/java` → `StockunitRepository` declares exactly one, above `findByIdForUpdate`.

**Named blind spots of (a)–(c):** a bulk `@Modifying UPDATE`/`DELETE` takes a row lock per matched row exactly as `FOR UPDATE` does and appears in none of the three scans; a dirty-checked `UPDATE` at flush likewise; a lock acquired through a `@Query` on another repository that joins `stockunit` is invisible to (a). `StockunitRepository` itself declares no `@Modifying` method (positive control: the same grep over `repo/jpa/` returns counts for 8+ other repositories, so the instrument works).

| # | Site · quoted snippet | Lock shape | In scope? |
|---|---|---|---|
| 1 | `service/ReplenishmentOrderMaintenanceService.java` · `ensureValidSource` — `: stockunitRepository.findByIdForUpdate(order.getStockunitId()).orElse(null);` | first of the defect pair | **yes** — reference point for the comparison, not itself changed |
| 2 | same file · `redirectSource` — `Stockunit targetStock = stockunitRepository.findByIdForUpdate(candidate.stockUnitId).orElse(null);` | **second of the defect pair, role-ordered** | **yes — this is the defect.** Fix B |
| 3 | same file · `reassignOrCancelForMovedStockUnit` — `Stockunit lockedSource = stockunitRepository.findByIdForUpdate(movedStock.getId()).orElse(null);` | first of the same pair, move entry (SBDEV-3618 Fix D) | **yes** — reference point; its pin is rewritten (§7.3) |
| 4–7 | `service/ReplenishorderService.java` · `redirectSource(Long,Long)` — `// Ascending-id lock order (D7): closes the redirect-vs-redirect cycle X: A->B / Z: B->A.` with `if (oldStockUnitId != null && oldStockUnitId < newStockUnitId)` | same pair, **ascending by explicit comparison** | **reference only** — the precedent this fix matches, not a defect |
| 8 | same file · `cancelReplenishmentOrder` — `Optional<Stockunit> sourceStockOptional = stockunitRepository.findByIdForUpdate(replenishOrder.getStockunitId());`, in-code: *"The order row is not locked first; that SU-then-order order is a known, bounded residual."* | one SU, but **SU before order row** | **no — RESIDUAL.** Accepted in-code under SBDEV-3621. See AC-8. **Its cycle runs through recalc's SOURCE acquisition (site 1), not the target — so no option in §4 Fix B, including always-skip-locked, could close it** |
| 9 | `service/mobile/MobileReplenishService.java` · `fulfillMultipleUnitLoadsTx` — `SortedSet<Long> lockIds = new TreeSet<>();` then `for (Long id : lockIds) { stockunitRepository.findByIdForUpdate(id)…}` | N SUs, ascending by construction | **reference only.** ⚠ The ordering is a **caller-side** property three statements from the writer; a test pinning "writer 4 locks ascending" pins `fulfillMultipleUnitLoadsTx`, not `applyExplicitSourceToOrder` |
| 10 | same file · `finishReplenishmentOrderWithoutRefill` — `sourceStock = stockunitRepository.findByIdForUpdate(mobileOrder.getSourceStockId()).orElse(null);`, in-code: *"The caller already holds this lock, so this is a re-lock no-op"* | one SU, re-lock | **no** — a same-mode re-lock of the row site 9 already holds |
| 11 | `service/StockunitBusinessService.java` · `transferStockToUnitLoad` `:202` — `sourceStockunit = stockunitRepository.findByIdForUpdate(sourceStockunitId)` | **first of a role-ordered pair** | **no — RESIDUAL (H2), newly named.** See AC-8 and §10 **P-7** |
| 12 | same file · `transferStockToUnitLoad` `:277` — `destinationStockUnit = stockunitRepository.findByIdForUpdate(dstSuId)` | **second of that pair: src-then-dst, no id comparison anywhere between them, and the dst SU is selected by `stockunit.getItemdataId().equals(sourceStockunit.getItemdataId())` — so it contends for exactly the same-itemdata pairs the recalc does** | **no — RESIDUAL (H2).** This is the identical defect shape as site 2, at the move choke point. **Its cycle runs through recalc's TARGET acquisition (site 2) and through two stock units and nothing else, so always-skip-locking site 2 WOULD close it — §4 Fix B declines to and ships with it live.** Fixing it *here* would be invariant-over-instance done wrong (one ticket, two unrelated methods); it is **P-7**, now ranked first |
| 13 | same file · `changeAmount` `:472` — `Stockunit stockUnit = stockunitRepository.findByIdForUpdate(staleStockUnit.getId())` then `entityManager.refresh` | one SU, re-lock of the caller's row | **no** — not reached from either path under change |
| 14 | same file · `changeReservedAmount` `:509` — `Stockunit stockUnit = stockunitRepository.findByIdForUpdate(staleStockUnit.getId())` then `entityManager.refresh` | one SU, re-lock | **indirect — reached from inside the defect.** Must stay a same-mode no-op on a row this transaction already holds (§3, AC-10) |
| 15 | `service/StockunitService.java` `:1060` (reservation cut) — `Stockunit stockUnit = stockunitRepository.findByIdForUpdate(stockUnitId)`, in-code *"(d) first touch of the stock unit is the lock"* | one SU, taken **after** its orders are locked ascending (`ORDER BY r.id`) | **no** — this is the counterparty SBDEV-3622 ordered the order-level half for; unchanged by this fix |
| 16 | `service/CustomerorderPositionService.java` `:148` — `Stockunit stockUnit = stockunitRepository.findByIdForUpdate(pickingPosition.getPickfromstockunitId())` inside `for (PickingorderPosition pickingPosition : pickingPositions)` | **N SUs per transaction, loop order unspecified** | **no** — inside the residual **rule** of AC-8, but off this ticket's axis: the SUs are the pick sources of one customer order, not same-itemdata replenish candidates |
| 17 | `service/PickingorderBusinessService.java` `:566` — `Stockunit sourceStock = stockunitRepository.findByIdForUpdate(sourceStockId)` inside a nested `for` over `findByCustomerorderpositionId` | same shape as 16 | **no** — same reason |

**Not a `findByIdForUpdate` site, carried here because it is the sharpest adjacent hazard:** `repo/jpa/StockunitRepository.java` · `getStockUnitsByItemDataIdForUpdate` — `"ORDER BY stockUnit.amount DESC " + "FOR UPDATE OF stockunit"`. Multi-row, **no LIMIT**, ordered by amount not id. Reached from `ReleaseOrderJobService`, not from replenish recalc. **No — RESIDUAL** (AC-8, §10 P-2).

**Re-source writers on an existing `Replenishorder`: three, not four.** Derivation: `git grep -n "setStockunitId" -- src/main/java` (13 hits) filtered by receiver type → writer 1 (`ReplenishmentOrderMaintenanceService`, the defect), writer 2 (`ReplenishorderService`, ascending), writer 4 (`MobileReplenishService.applyExplicitSourceToOrder`, ascending via its caller), plus two CREATE sites in `ReplenishGeneratorService`. The ticket's `switchSourceToUnitLoad` is **gone** — `git grep` over all tracked files exits 1 with zero output; positive control in the same scan: `git grep -n "redirectSource"` returns 23+ hits, so the instrument finds strings in this tree. It was removed by SBDEV-3638, merged. Blind spots of this axis: it is keyed on `setStockunitId` and is **independent of** the `findByIdForUpdate` axis above — it neither inherits nor repairs that table's coverage; and a native `UPDATE replenishorder` or a reflective setter would not show.

**What the transaction already holds when it reaches site 2:**

| entry point | held before the first SU lock | then |
|---|---|---|
| `recalculateOrder` (cron `recalculateOpenOrders`) | the `Replenishorder` row | site 1 → site 2 |
| `recalculateForItem` (joins a **caller's** tx) | the caller's whole transaction **plus** one order row per iteration, released only at the outer commit | sites 1→2 per order, **accumulating** |
| `reassignOrCancelForMovedStockUnit` (unit-load move) | the move's tenant tx + the order row + every lock the carrier-tree loop has already taken | site 3 → site 2 |

That last row is why the move path gets a different treatment from the recalc path (§4.2) and why this plan does not claim the move path becomes deadlock-free (§9 AC-8).

---

## 1. Problem statement

`ReplenishmentOrderMaintenanceService` acquires two `PESSIMISTIC_WRITE` `Stockunit` row locks per redirect, in **role order** (current source, then target) regardless of row id. The in-code `⚠ LOCK ORDERING — NOT PROVED SAFE` block above site 2 states the residual, accepts it, and ends with: *"If you want it actually closed rather than bounded: acquire the two stock-unit locks in ascending id order and delete this comment. That is a lock-topology change, not a comment fix, so it needs its own ticket and its own test."* This is that ticket.

Three sibling writers in the same subsystem already order their `Stockunit` locks ascending — `ReplenishorderService.redirectSource` (web Change Source, *"// Ascending-id lock order (D7)"*), `MobileReplenishService.fulfillMultipleUnitLoadsTx` (`TreeSet`), and `PickLineRealignmentService.lockOwningPickingorders` for `Pickingorder`. Writer 1 is the outlier against three conformers. SBDEV-3622 already did the **order-level** half (`findIdsByStateAndItemdataId` gained `ORDER BY r.id`, *"so recalculateForItem locks an item's orders in the same order as the attributed reserved cut does"*); SBDEV-3637 is the **stock-unit-level** half.

**The symptom when it fires:** PostgreSQL aborts one side with SQLSTATE `40P01`. On `recalculateForItem` the `hasSqlCause` branch rethrows and poisons the whole item sweep; on `recalculateOpenOrders` it logs and skips; on the move path the operator's relocation is rejected.

**DB evidence (2026-10-04, read-only):**

| tenant | PROCESSABLE orders | items with ≥2 active orders | `pg_stat_database.deadlocks` |
|---|---|---|---|
| `wsl-wineco-uat` | 570 | **0** | **0** |
| `nywh-hydra-prd` | 1 | **0** | **0** |
| `nywh-hydra-uat` | 8 | **0** | **0** |
| `c1wh-shipitez-prd`, `nywh-shipitez-prd` | — | — | `permission denied for table replenishorder` |

⚠ Three tenants at one instant; two of five production databases refused the query. Do not write "no tenant has …" from this table.

⚠ **The `deadlocks = 0` reading has no positive control in the environment it was measured in.** `PostgresDeadlockDetectorControlIT` controls the **test lane** on the pinned `postgres:14-alpine`; it says nothing about whether the counter is live on `wsl-wineco-uat`, `nywh-hydra-prd` or `nywh-hydra-uat`. Separately, `pg_stat_database.deadlocks` is cumulative since `stats_reset`, which was **not** read — a zero after a recent reset or restart is indistinguishable from a true zero. **Before merge, re-run with `stats_reset` in the projection** (`SELECT datname, deadlocks, stats_reset FROM pg_stat_database WHERE datname = current_database();`) and record the age of the window each zero covers. Until then this row is weak evidence, and nothing below rests on it: the fix is justified by the lock topology, not by the counter.

---

## 2. Root cause analysis

### 2.1 The mechanism, stated precisely

A row-lock cycle needs two transactions acquiring the same pair `(S_a, S_b)` in opposite relative order. Site 2's order is a function of **role**, not of id, so for any pair there exist two role assignments that produce opposite id orders. A counterparty that orders by id therefore disagrees with site 2 on half of all pairs (derivation: each unordered pair `{S_a, S_b}` admits two role assignments and exactly one of them is descending; blind spot: this is a statement about the *pairs*, not about their frequency in traffic — the measured edge split is in §4 Fix B).

### 2.2 The ⚠ comment's own stated mechanism is REFUTED

The comment attributes the residual to the `!locationId.equals(order.getRequestedlocationId())` route in `isSourceUsable` (the SBDEV-2492 scenario) making two sources *"each unusable to their own order … while remaining offered candidates to the other."* The second half is what breaks it: being location-mismatched does **not** remove a row from the candidate set. `getAvailableReplenishmentSources` has no location predicate beyond `area.useforreplenish` and the lane flags, and the service pipeline is `.map(this::mapCandidate).sorted(…).findFirst()` with **no `.filter`** (derivation: read of the query string and of the stream expression; blind spot: none for this clause — both are quoted literally from the file). So a merely location-mismatched source stays in its own order's candidate set, stays in its own order's preferred area, sorts first, and takes the SBDEV-3618 Fix E same-row re-point branch — which **returns before any second lock is taken**. No cycle.

Recording this matters for two reasons: it is why the plan does not try to reproduce the comment's scenario in a test, and it is why the replacement comment must not repeat it.

### 2.3 Where the residual actually lives

Three reachable shapes, ranked (lane-a §9):

1. **move × move** (high) — two operators moving same-item pallets onto non-replenishable destinations at the same moment. Each transaction's own UL relocation is visible to itself and invisible to the other, so each sees the other's source as its only candidate. Clean ABBA with no third party, no clock, no stale snapshot. This is the shape the test reproduces (§7.2).
2. **web `ReplenishorderService.redirectSource` (ascending) × maintenance `redirectSource` (role-ordered)** (medium-high) — the web path's eligibility guards all sit *after* both locks, so no candidate-snapshot argument protects it; the operator chooses the target.
3. **multi-UL mobile (ascending `TreeSet`) × maintenance** (medium) — and `assignDestinationForMultiUnitLoads` runs maintenance *inside* its own transaction, so one transaction mixes both orderings.
4. **recalc × recalc within a single candidate snapshot** — **impossible**, provable from the comparator plus the item-keyed query (lane-a §2.3). Reachable only through snapshot divergence (`recalculateForItem`'s own uncommitted writes, or the manual-cut cooldown clock) *and* a two-active-orders-per-item configuration. ⚠ That configuration is **permitted**, not blocked — the unique index caps per *destination*, not per item (§0) — and measures 0 on three tenants at one instant. It is rare **by measurement, not by construction**.

### 2.4 Concurrency is not gated the way it looks

`ReplenishOrderJob` wraps `replenish(tenantName)` in a two-key `pg_try_advisory_lock` on a pinned landlord connection, so **two concurrent cron sweeps of the same tenant cannot occur, across replicas**. But three callers reach the same code *outside* that lock (derivation: `git grep -n "recalculateOpenOrders\|recalculateForItem" -- src/main`, each hit read; blind spot: the grep is token-exact and would miss a functional-reference or reflective invocation — none seen, and `redirectSource` is `private`, so the only doors are the two public methods plus `reassignOrCancelForMovedStockUnit`):

- `MobileReplenishService:711` — `recalculateOpenOrders(true)`, **cadence-bypassing**, on every handheld multi-UL fulfilment;
- `StockunitService:174` (`triggerReplenishmentMaintenance`) → `recalculateForItem`;
- `FixLocationAssignmentService:307` → `recalculateForItem`.

And a unit-load move is an operator HTTP request that can always race a sweep.

---

## 3. Architecture overview

```
recalc path                              move path
recalculateOrder                         UnitloadBusinessService.processTransfer
 └ LOCK replenishorder(orderId)           └ LOCK pickingorders (ascending, whole tree)
   └ ensureValidSource                    └ LOCK destination location (unless ignoreLock)
      └ LOCK stockunit(source)   ◄── site 1    └ UPDATE unitload (row lock at flush)
      └ isSourceUsable → false              └ for each SU on the UL  (findByUnitloadId, NO ORDER BY)
         └ redirectSource                      └ ReplenishmentOrderSourceSyncService (router)
            └ candidate query (no lock)           └ LOCK replenishorder(probeId)
            └ Fix E same-row? → re-point, RETURN     └ LOCK stockunit(moved)  ◄── site 3
            └ LOCK stockunit(target)  ◄── site 2     └ redirectSource → site 2
            └ changeReservedAmount(target)            └ on false: cancelOrder
            └ releaseHeld(current)
```

`StockunitBusinessService.changeReservedAmount` re-locks the row the caller already holds (`findByIdForUpdate(staleStockUnit.getId())` then `entityManager.refresh`) — a no-op upgrade at the same mode, not a new acquisition. Nothing on the recalc path takes a `Location`, `Unitload` or `Pickingorder` lock (derivation: read of every line of `recalculateOrder → ensureValidSource → isSourceUsable → redirectSource → changeReservedAmount → recordChangeReservedAmount → releaseHeld → cancelOrder → markCancelled → updateRequestedAmount → shareOf`, plus `git grep -n "ForUpdate"` over the two services; blind spot: a bulk `@Modifying` UPDATE reached indirectly would take row locks invisibly to that grep — none seen on these paths).

---

## 4. Fix design

Five code fixes plus a docs fix. `[arch-N]` tags carry lane-b's round-1 requirements; `[A-N]`, `[H-N]`, `[M-N]`, `[L-N]` tags carry the round-2 architect and critic findings and say what r1 got wrong, so a reader can see which sentences were repaired rather than written.

### Fix A — `StockunitRepository.findByIdForUpdateSkipLocked`

**Before:** one locking finder, which always waits.

**After:** a second one that never waits.

```java
@Lock(LockModeType.PESSIMISTIC_WRITE)
@QueryHints(@QueryHint(name = "jakarta.persistence.lock.timeout", value = "-2"))
@Query("SELECT s FROM Stockunit s WHERE s.id = :id")
@RestResource(exported = false)
Optional<Stockunit> findByIdForUpdateSkipLocked(@Param("id") Long id);
```

`@RestResource(exported = false)` is mandatory and mirrors `findByIdForUpdate`'s own SBDEV-3169 comment — exported, it would let any authenticated caller take a `PESSIMISTIC_WRITE` row lock over HTTP GET.

**Why `-2` works, when SBDEV-3250 proved four sibling hints inert.** Confirmed by `javap -p -c org/hibernate/dialect/PostgreSQLDialect.class` from `hibernate-core-6.6.39.Final.jar` on the build classpath: `withTimeout(String,int)` compiles to `lookupswitch { -2: 46, 0: 28, default: 64 }`, where `46` calls `supportsSkipLocked()` (hard `iconst_1; ireturn`) and appends to the lock string, and `default: 64` is `aload_1; areturn` — **the lock string unchanged**. The route in is `getForUpdateString(String,LockOptions)` → `LockOptions.getTimeOut()` → `getWriteLockString(String,int)` → `withTimeout`. The hint reaches `LockOptions` via `AbstractCommonQueryContract.HINT_SPEC_LOCK_TIMEOUT` → `applyLockTimeoutHint(getInteger(value))` → `getQueryOptions().getLockOptions().setTimeOut(…)`; `ConfigurationHelper.getInteger` handles the `String` `"-2"` that `@QueryHint.value` necessarily carries.

**SBDEV-3250 is positive evidence FOR this design, not against it.** Its four removed hints carried *positive millisecond* values, which land on `default` and are discarded — the inertness was **value-dependent, not path-dependent**. The `@QueryHints` plumbing, Spring Data's `AbstractJpaQuery.applyHints`, and the tenant EMF all worked then and work now. Two in-repo javadocs already say exactly this (`TenantDatabaseConfig`: *"the per-query `jakarta.persistence.lock.timeout` hint is discarded by `PostgreSQLDialect` for every value except `0` and `-2`"*; `StockunitRepository`, directly above the finder being paired: *"PostgreSQLDialect.withTimeout translates only 0 (NO_WAIT) and -2 (SKIP_LOCKED) and returns the lock string unchanged for every other value"*), which is a second instrument agreeing with the disassembly.

The known *"`spring.jpa.properties.*` never reaches the tenant PU"* trap does not apply: `@QueryHints` is applied onto the `Query` object at execution time, not read from the PU property map. It **would** apply to any attempt to set the hint globally — do not take that route.

**Blind spot, named:** a `HibernatePropertiesCustomizer` or `EntityManagerFactoryBuilderCustomizer` bean elsewhere in the context could in principle interfere; the derivation read `TenantDatabaseConfig` and `LockTimeoutHibernateJpaDialect` in full but did not sweep for such a bean. AC-2 (§9) closes this by asserting the emitted SQL, not the annotation.

**Considered: a native `FOR UPDATE SKIP LOCKED` query.** This repo already does exactly that, working and pinned — `repo/jpa/OutboxMessageRepository.java` · `findAndClaimPending` carries `FOR UPDATE SKIP LOCKED` literally in its query text, and `OutboxLaneClaimIT` asserts `.contains("FOR UPDATE SKIP LOCKED")`. That route needs no dialect disassembly, no `@QueryHints` plumbing argument and no `HibernatePropertiesCustomizer` blind spot — r1 spent a paragraph on `javap` output without naming the in-repo precedent, which is not representing the alternative at its strongest. **The `-2` hint is still preferred, for two reasons.** (1) The same `OutboxMessageRepository` javadoc states the cost: *"they cannot be tested on H2. Use Testcontainers for integration tests covering these methods."* This finder sits on a path several H2 lanes parse (§9 v2-only #4); the JPQL form stays parseable everywhere and the hint is simply inert under H2's dialect. (2) `@Lock(PESSIMISTIC_WRITE)` is what puts the returned entity into the persistence context **at that lock mode**, which is what keeps `changeReservedAmount`'s own `findByIdForUpdate(staleStockUnit.getId())` a same-mode no-op rather than a version-checked upgrade — the SBDEV-3244 F3 shape (AC-10). ⚠ **Reason (2) is a mechanism claim, not a measurement:** Spring Data's handling of `@Lock` on a `nativeQuery = true` `@Query` was not disassembled in this pass. Reason (1) alone is sufficient to choose the hint; if the gate ever wants to switch routes, re-derive (2) first and do not switch on the strength of this paragraph.

### Fix B — hybrid acquisition at the target lock `[arch-2, arch-3]`

**Before** (`redirectSource`, the single line under the ⚠ block):

```java
Stockunit targetStock = stockunitRepository.findByIdForUpdate(candidate.stockUnitId).orElse(null);
```

**After:**

```java
// Role-ordered acquisition is RETAINED: the inverting edge declines to WAIT rather than reordering,
// because the source lock is already held and SBDEV-3244 F3 forbids reading it unlocked. This is NOT
// the ascending-id discipline of ReplenishorderService.redirectSource's D7 branch or of
// MobileReplenishService's TreeSet — those genuinely reorder their acquisitions; this one cannot.
// SKIP LOCKED, not NOWAIT: NOWAIT raises 55P03, a statement error, which puts the whole transaction
// into an aborted state (25P02 on every statement after it) and so poisons recalculateForItem's item
// sweep. SKIP LOCKED returns no row and leaves the transaction usable.
boolean skipLocked = !recalcPath || targetIsBelowHeldSource(currentSource, candidate.stockUnitId);
Stockunit targetStock = (skipLocked
        ? stockunitRepository.findByIdForUpdateSkipLocked(candidate.stockUnitId)
        : stockunitRepository.findByIdForUpdate(candidate.stockUnitId)).orElse(null);
if (targetStock == null) {
    if (!skipLocked) {
        return RedirectOutcome.NO_CANDIDATE;            // the row vanished between query and lock
    }
    // SKIP LOCKED returns nothing for TWO reasons: the row is locked, or the row is gone. Only the
    // first is a defer; mapping a vanished row to CONTENDED defers it forever (Fix C). Reached only
    // on the miss, never on the hot path. Still racy — it narrows the window, it does not close it,
    // but it can only ever err toward DEFER, never toward a spurious CANCEL (Fix C).
    // The null check is NOT redundant: on the move path skipLocked is unconditionally true, so a
    // null candidate.stockUnitId reaches here even though targetIsBelowHeldSource never saw it, and
    // CrudRepository.existsById(null) throws a bare IllegalArgumentException (SimpleJpaRepository
    // opens with Assert.notNull(id, ID_MUST_NOT_BE_NULL)) — the exact unchecked exception the
    // targetId != null guard exists to prevent, reintroduced one branch later. [A-5″]
    if (candidate.stockUnitId == null || !stockunitRepository.existsById(candidate.stockUnitId)) {
        return RedirectOutcome.NO_CANDIDATE;
    }
    // ... Fix E WARN(s) ...
    return RedirectOutcome.CONTENDED;
}
```

with

```java
/**
 * Returns true <b>exactly when this acquisition would DESCEND</b> — that is, when this transaction
 * already holds a lock on a stock unit whose id is HIGHER than the target's. Returns true when
 * {@code currentSource}'s id is above {@code targetId}.
 *
 * <p>⚠ This predicate is only the RECALC half of the branch. The caller skip-locks on this
 * <b>or</b> on the move path ({@code !recalcPath ||}), where skip-locked is unconditional and
 * independent of the comparison — see the case table. Do not read "exactly when" as a statement
 * about the branch; it is a statement about this method.
 *
 * <p>⚠ Do not "simplify" {@code >} to {@code >=}, {@code <}, {@code compareTo} or {@code Objects.equals}.
 * {@code >} on two {@code Long}s unboxes both operands and is a VALUE comparison — the repo's recorded
 * reference-comparison defect applies to {@code ==}/{@code !=}, not to {@code >}. The sign is
 * load-bearing: inverting it silently defers the ~77% of edges that were already safe AND leaves the
 * original ABBA live on the rest. The precedent is identically shaped —
 * {@code ReplenishorderService}: {@code if (oldStockUnitId != null && oldStockUnitId < newStockUnitId)}.
 */
private static boolean targetIsBelowHeldSource(Stockunit currentSource, Long targetId) {
    return currentSource != null && targetId != null && currentSource.getId() > targetId;
}
```

**`[A-1/H4]` The name, the javadoc and the body now state the same comparison.** r1 shipped `holdsLowerSourceLock` with a javadoc reading *"a stock unit whose id is BELOW the target's"* over a body computing `currentSource.getId() > targetId`. Both reviewers flagged it independently, at HIGH, as the single most likely implementation failure: an implementer who trusts the name — or who "corrects" the body to match the doc — inverts the fix in the worst direction, and nothing in production would show it (the WARN would fire *more* and read as working-as-intended). Nothing tests a doc/name/body disagreement, so the only defence is that the three agree.

**`[A-5/L4]` The explicit `targetId != null` guard** replaces r1's unsupported `// both non-null here`. `candidate.stockUnitId` comes from `mapCandidate(row) → toLong(row[0])`, and `toLong` has **two** null-returning branches (`if (value == null) { return null; }` and `catch (Exception e) { return null; }` around `Long.parseLong`). Without the guard a null id raises a bare NPE at unboxing *before* the finder, inside `recalculateForItem`'s loop whose catch arm distinguishes SQL-backed from non-SQL exceptions.

⚠ **`[A-5′]` What the guard preserves is `NO_CANDIDATE` with NO exception — r2 said it preserves a named `InvalidDataAccessApiUsageException`, and that was wrong.** `findByIdForUpdate` is **not** a derived finder: `repo/jpa/StockunitRepository.java` declares it as `@Query("SELECT s FROM Stockunit s WHERE s.id = :id")` over `Optional<Stockunit> findByIdForUpdate(@Param("id") Long id);`. A null argument **binds null**, `s.id = null` is never true, zero rows come back and the method returns `Optional.empty()`. `InvalidDataAccessApiUsageException` belongs to the derived `findById(null)` shape, which this is not. (Derivation: read of the declaration, quoted above. Blind spot: not executed — no test in this plan asserts it today; the `null-target` U-param row added in §7.4 is what will.) So today a null target id yields `Optional.empty()` → `NO_CANDIDATE` → the caller cancels; the guard keeps exactly that and replaces a bare NPE with it. The same correction lands on **AC-3** and **M-11**.

**The four cases, keyed on `recalcPath` first `[A-4]`.** Derivation: the expression has exactly two inputs — `recalcPath` and the predicate — so the table is their 2×2, split on why the predicate is false. Blind spot: it describes the *expression*, not what reaches it; the placement rule below covers that.

| `recalcPath` | id relation | branch | why |
|---|---|---|---|
| **false** (move) | **any, including a null source** | **skip-locked, always** | the transaction has already accumulated locks on earlier SUs of the carrier tree, taken in `findByUnitloadId` order with **no `ORDER BY`**, so "ascending from here" is not a property this path can claim. ⚠ **(move, null source) is reachable** — `reassignOrCancelForMovedStockUnit` passes `lockedSource` into `redirectSource(order, lockedSource, share, false)` with no null guard — and `!recalcPath` short-circuits first, so skip-locked wins. r1's table had this combination matching two contradictory rows; the parameterized test (§7.4) now covers it |
| **true** (recalc) | `targetId < sourceId` (descending) | **skip-locked** | the inverting edge. Cannot be reordered: the source lock is already held, and releasing it to re-take ascending would break SBDEV-3244 F3 |
| **true** (recalc) | `targetId > sourceId` (ascending) | **plain** `findByIdForUpdate` | see the justification immediately below. It is **not** "already deadlock-free" |
| **true** (recalc) | `currentSource == null`, or `targetId == null` | **plain** `findByIdForUpdate` `[arch-2]` | **no lock was taken for THIS order's source.** `source` is null either because `stockunitId` was null or because the locking read found nothing, and `FOR UPDATE` on a missing row takes no lock, so this acquisition adds no edge off a source of its own. ⚠ **This is NOT "the transaction holds no stock-unit lock"** `[F-1, fix-review 2026-10-05]`. `recalculateForItem` sweeps an item's orders in **one** transaction (plain `this.` call, deliberately) and is `REQUIRED`, so it **joins** an ambient transaction — an earlier order's `ensureValidSource` lock, or a caller's, may still be held at this line (`ReplenishorderRepository`'s SBDEV-3622 comment on `findIdsByStateAndItemdataId` states the sweep's cross-iteration lock accumulation directly). The predicate compares against **this order's** source only, so whether such an inherited lock sits above the target is **not tested on any recalc row** — a separate gap, unmeasured, not claimed safe, and **not closed by this ticket**. Note the asymmetry the comment block now spells out: the **recalc** rows reason per-order, the **move** row reasons per-transaction (*"has already accumulated locks on earlier SUs of the carrier tree"*). Load-bearing: this case is what keeps `ReplenishmentFirstTouchInvariantUnitTest.redirectSource_loadsTheTargetUnderItsLock` green (§7.3) |

`targetId == sourceId` is absent because it never reaches the line. SBDEV-3618 Fix E returns from **both** of its arms above: `if (currentSource != null && Objects.equals(candidate.stockUnitId, currentSource.getId())) { if (!recalcPath) { return false; } … replenishorderRepository.save(order); return true; }`. Derivation: read of every statement between that block and the target lock — there are two, the `newRequested` computation and a `<= 0 → return`. Blind spot: none for this clause; the region is six statements and all were read. **This has a consequence for mutation testing — see M-6 in §7.5.**

**Why the ascending edge keeps waiting `[A-7/H2]`.** r1 said *"already globally ordered, therefore already deadlock-free."* **That is false and it is deleted from the plan and forbidden in the code.** r2 then wrote, in the same slot, *"converting it to skip-locked would buy nothing against either residual above, because neither of those cycles runs through two stock units"* — **also false, and also deleted.** Two residual cycles cross recalc's stock-unit acquisitions and they are **not equivalent**; collapsing them is how the second false sentence was produced. Each is stated below with the acquisition it actually runs through, verified against `ec42f43a`:

- **`StockunitBusinessService.transferStockToUnitLoad` — runs through recalc's TARGET acquisition (site 2).** It takes `sourceStockunit = stockunitRepository.findByIdForUpdate(sourceStockunitId)` (`:202`) then `destinationStockUnit = stockunitRepository.findByIdForUpdate(dstSuId)` (`:277`) — two `PESSIMISTIC_WRITE` Stockunit acquisitions in **role order with no id comparison between them**, on rows of the **same itemdata** (the destination is chosen by `stockunit.getItemdataId().equals(sourceStockunit.getItemdataId())`), at the move choke point. Counterexample, both sides plain waits, both *after* this fix: recalc holds `S_low` (site 1) and waits on `S_high` (site 2, ascending, plain); `transferStockToUnitLoad` holds `S_high` (`:202`, its source) and waits on `S_low` (`:277`, its destination). **That is an ABBA through two stock units and nothing else, and always-skip-locked WOULD close it** — it deletes recalc's wait edge `S_low → S_high`, so recalc returns `CONTENDED` and the cycle cannot form. §0 rows 11–12; **§10 P-7**.
- **`ReplenishorderService.cancelReplenishmentOrder` — runs through recalc's SOURCE acquisition (site 1).** It locks the source SU (`Optional<Stockunit> sourceStockOptional = stockunitRepository.findByIdForUpdate(replenishOrder.getStockunitId());`) and then writes the order row through `markCancelled`, taking the order lock at flush — while `recalculateOrder` takes the **order** lock first (*"THE FIRST-TOUCH RULE"*) and then waits on the source SU. T1 holds `O` and waits on `S_src`; T2 holds `S_src` and waits on `O`. The waiting SU acquisition on recalc's side is `ensureValidSource`'s `: stockunitRepository.findByIdForUpdate(order.getStockunitId()).orElse(null);`, which stays a **plain** finder under the hybrid *and* under always-skip-locked — neither option touches it — so **always-skip-locked would NOT close this one**, and skip-locking a stock unit to close an order-row cycle would be invariant-over-instance inverted. §0 row 8, accepted in-code under SBDEV-3621.

**So the hybrid leaves a real, closable cycle open on the ascending edge — `transferStockToUnitLoad`'s. That is an accepted cost, not an absence of exposure.** What it is accepted against is the measured cost stated immediately below (*"Why not always-skip-locked"*): **253 of the 329 second-lock acquisitions are ascending**, and skip-locking them converts safe uncontended waits into spurious defers costing a full recalc cadence each — with no exception, no metric and no operator-visible symptom to distinguish a 0.1% defer rate from a 10% one. That cost is measured; the contention rate it would buy against is not, and cannot be before the fix ships (§10 D2). The trade still selects the hybrid, and D2's expiry stands unchanged: **if P-3 lands, collapse this branch to always-skip-locked.** The open cycle is closed at its origin by **P-7**, which orders `transferStockToUnitLoad`'s own pair and so imposes **no spurious-defer cost on the recalc path at all** — which is why P-7 now ranks **first** among the proposals. ⚠ That is a statement about where the cost falls, not about how cheap P-7 is to build: its own implementation cost is **NOT ESTABLISHED** (§10 P-7). Both residuals are named as residuals in AC-8 and, with this split, in the Fix F comment.

**Placement `[arch-3]`: immediately above the existing target lock, replacing that one line — not earlier.** Everything above it either takes no lock or returns first: `candidate == null → return`; the Fix E same-row branch saves the order and returns, locking no second row; `newRequested <= 0 → return`. Moving the branch up would change which path those cases take for no benefit, and the candidate query takes no lock, so nothing forces it up.

**Why not always-skip-locked (the simpler shape).** Stated at strength: one lock method, one branch fewer, no sign to get wrong — removing the artifact `[A-1/H4]` identifies as the likeliest defect in the whole change — no null-source edge case, and Fix C's hardest clause disappears (one finder, so `targetStock == null` has one meaning). It loses on a measured number. On `wsl-wineco-uat`, resolving the top candidate for each of the 570 PROCESSABLE orders under the real eligibility predicate gives **144 no candidate · 97 same-row Fix E · 253 ascending · 76 descending**. Of the 329 redirects that take a second lock at all, **77% are ascending** — edges where skip-locked converts "wait briefly, then certainly succeed" into "succeed unless someone happens to hold the row right now", at a cost of one full recalc cadence per spurious defer. And the failure would be silent: no exception, no metric (nothing scrapes Prometheus here), no operator-visible symptom — you could not distinguish a 0.1% defer rate from a 10% one.

⚠ **Stated against itself.** 77% is `P(ascending edge)`. The cost of always-skip-locked is `P(ascending) × P(target locked at that instant)`, and **the second factor is measured nowhere in this plan and cannot be measured before the fix ships**, because today that case *is* the deadlock. The hybrid is chosen because its worst case does not depend on an unmeasurable parameter — not because that parameter is known to be large. D2 therefore settled the **edge distribution**, not the contention rate, and it carries an expiry condition (§10 D2). *Derivation and blind spots of the 77%: one SQL query, `wsl-wineco-uat`, 2026-10-04, UAT, one instant. It approximates the real comparator by dropping the `preferredAreaId` tiebreak (reconstructing it per order needs each source's unit load and location), so 76/253 is an estimate, not a count. What it does establish robustly is that the descending edge is common rather than exotic: a looser query — does any lower-id eligible candidate exist at all — returns 448 of 570, 79%.*

**Why not do nothing, and why not catch `40P01` and retry.** *Do nothing* has the honest case: severity is LOW on every reading the team could take (§0) and a T3 is expensive. Rejected because this is a *topology* defect at a choke point, the change is small, and the measured zero is three tenants at one instant with two production databases refusing the query and `stats_reset` unread (§1) — it bounds the observed past, not the exposure. ⚠ If the §1 re-measurement shows the zeros cover days rather than months, re-read this line before merge. *Retry on `40P01`* is unavailable where it would matter: on `recalculateForItem` PostgreSQL has already aborted the transaction by the time the catch runs, so retrying inside it is impossible and retrying outside means restructuring the sweep; on `recalculateOpenOrders` it is what already happens (log and skip); and on the move path it still leaves the operator's relocation rejected.

**Why not pre-query the candidates and lock both ascending.** Not primarily cost — **sequencing**. To lock ascending you must know the target before locking the source, but you only know whether you need a target after `isSourceUsable`, which needs the source **entity** read under its lock. You would have to run `getAvailableReplenishmentSources` for every PROCESSABLE order every tick (570 extra 4-table native joins per minute per tenant on WineCo UAT, paid by the ~75% of orders whose source is fine) and select the target from a read taken *before* either row is locked — reintroducing exactly the pre-lock-decision staleness SBDEV-3244 F3 exists to eliminate. Caching the candidate set per item across the sweep does not rescue it: the set goes stale as soon as one order in the sweep reserves from it. **True global ascending ordering is structurally unavailable on this path.** Say this in the code; *"an extra query"* invites someone to argue the query is cheap.

**Why not `NOWAIT` (hint value `0`).** `withTimeout(s, 0)` → `supportsNoWait()` → appends `nowait`, and PostgreSQL then raises `55P03`, a **server-side statement error**, which aborts the whole transaction. `recalculateForItem`'s own SBDEV-3250 comment is the authority: *"PostgreSQL puts the whole transaction into an aborted state on ANY statement error: every subsequent statement then fails with 25P02 … Swallowing therefore does not skip one order — it poisons the transaction."* Since `recalculateOrder` is reached there through a plain `this.` call, a NOWAIT miss on one order would kill the sweep for the whole item. `SKIP LOCKED` is categorically different: no error, the row is simply absent, the transaction stays usable. `[arch-6]` **This sentence belongs in the code**, because it is the thing a future reader will try to "simplify" back to NOWAIT.

**Why not an unlocked source read** (so the ids are known before any lock): breaks SBDEV-3244 F3 outright — a plain finder leaves the row at `EntityEntry` lock mode READ, making `changeReservedAmount`'s `findByIdForUpdate` a version-checked **upgrade** that throws `StaleObjectStateException` from inside the locking call. It also silently corrupts the arithmetic: `share` and `desiredAmount` are computed from the source's `amount`/`reservedamount`, so a pre-lock read converges on pre-winner numbers even when nothing throws. Pinned by `ReplenishmentFirstTouchInvariantUnitTest`. Do not revisit.

### Fix C — `redirectSource` returns a 3-way outcome `[arch-1]`

**Before:** `private boolean redirectSource(...)`, where `false` means two unrelated things.

**After:**

```java
/**
 * The outcome of one redirect attempt.
 *
 * <p>CONTENDED carries the invariant the callers actually depend on, scoped to this method:
 * <b>redirectSource itself wrote nothing, reserved nothing, and did not mark the transaction
 * rollback-only — so the caller may carry on and the surrounding transaction may still commit.</b>
 * It is NOT a claim that the transaction is clean: on the recalc path {@code alignDestination} may
 * already have saved a destination id before {@code ensureValidSource} ran, and on the move path the
 * unit-load relocation is a pending write that D1 REQUIRES to commit.
 * The {@code catch (FacadeException)} arm below must map to {@link #NO_CANDIDATE}, never
 * to CONTENDED — see the SBDEV-2074 M5 comment: changeReservedAmount is
 * {@code @Transactional(rollbackFor = FacadeException.class)} and joins this tx, so by the time
 * that arm runs the shared transaction is already rollback-only and "carrying on" would do more
 * work on a doomed unit and fail at commit with a message further from the cause.
 */
private enum RedirectOutcome { REDIRECTED, NO_CANDIDATE, CONTENDED }
```

`[A-2]` r1's javadoc asserted *"nothing was written and the transaction is NOT rollback-marked"*, which is false at transaction scope on **both** paths: `alignDestination` writes (`order.setDestinationId(...); replenishorderRepository.save(order);`) and returns `false` on both arms, so execution continues into `ensureValidSource` with a pending write; and D1 *requires* the move's writes to commit. R-4's mitigation would otherwise have been protecting a false claim.

Mapping of today's `return false` sites: `candidate == null` → `NO_CANDIDATE`; move-path same-row → `NO_CANDIDATE`; `newRequested <= 0` → `NO_CANDIDATE`; `targetStock == null` from the **plain** finder → `NO_CANDIDATE`; `targetStock == null` from the **skip-locked** finder → `CONTENDED` *(but see the disambiguation below)*; `catch (FacadeException)` → **`NO_CANDIDATE`** `[arch-1]`. `return true` → `REDIRECTED`.

⚠ The plain-finder and skip-locked-finder `null` cases are **different outcomes from the same expression**, so the branch must record which finder ran (the `skipLocked` boolean in Fix B) rather than inspecting the result. Collapsing them is the easiest way to get Fix C wrong and is the subject of mutation M-4 (§7.5).

⚠ **`SKIP LOCKED` returns zero rows for two distinct reasons: the row is locked, or the row is gone `[M3]`.** On the move path the skip-locked finder runs unconditionally, so a candidate deleted between the candidate query and the lock would be reported `CONTENDED` and **deferred forever** instead of `NO_CANDIDATE` → cancelled — and in production the symptom (a repeating `SBDEV-3637 REDIRECT_CONTENDED` on the same order+target) is the same signature §7.6 tells the operator to read as a live-lock. Probability is low (the candidate came from a query moments earlier in the same transaction), but the mapping is not clean and must not be presented as clean. **Disambiguate on the miss path only:** `if (!stockunitRepository.existsById(candidate.stockUnitId)) → NO_CANDIDATE` — one non-locking statement, reached only when the skip-locked finder returned empty, never on the hot path. ⚠ It is itself racy (the row can be deleted after the check) — it narrows the window, it does not close it — so Fix E's WARN must still say that a persistent CONTENDED can mean a vanished row. U-J pins it. ⚠ **It also needs a null guard**, because the move path reaches it with `skipLocked` unconditionally true: `CrudRepository.existsById(null)` throws a bare `IllegalArgumentException` (`SimpleJpaRepository.existsById` opens with `Assert.notNull(id, ID_MUST_NOT_BE_NULL)`), which is the exception the `targetId != null` guard exists to prevent, reintroduced one branch later `[A-5″]`. M-13 pins the guard.

**The race errs in ONE direction only, and that is what makes a racy check acceptable here.** `existsById` returns `false` only for a row that is **committed-gone**; a row that merely exists and is locked by another transaction is still visible to a non-locking `SELECT`. So the four states resolve as: locked-not-deleted → `true` → defer ✓; deleted-and-committed before the check → `false` → cancel ✓ (today's behaviour through the plain finder, so not a new outcome); delete uncommitted at the instant of the check → `true` → defer, should have been cancel; deleted-and-committed after the check → `true` → defer, should have been cancel. **Every wrong answer is a defer that should have been a cancel; a cancel that should have been a defer is structurally unreachable.** Cancel is the destructive outcome and defer is the reversible one, and the benign direction self-heals on the next tick at `PROCESSABLE` (the candidate query re-runs from DB state and the vanished row is no longer a candidate). *Derivation: `existsById` is a non-locking JPQL count under the tenant transaction, so it reads committed state; the asymmetry follows from "no isolation level makes a live row invisible to its own-or-later committed snapshot" and therefore holds under **both** READ COMMITTED and REPEATABLE READ — it does not depend on an isolation level this plan has not pinned. Blind spot: derived, not executed; no test asserts the uncommitted-delete row and none is proposed, because no fixture in this repo can hold an uncommitted delete across a worker's statement without the raw-holder hazard §7.1 forbids.* At non-`PROCESSABLE` the benign direction does **not** self-heal, which is exactly what Fix D `[A-6]`'s `REDIRECT_NO_HEAL` WARN covers.

### Fix D — caller mapping `[arch-1, arch-7]`

| caller | today | after |
|---|---|---|
| `ensureValidSource` (recalc) | `if (redirectSource(...)) { …re-read… } cancelOrder(order, source, CANCELLED); return null;` | `REDIRECTED` → unchanged · `NO_CANDIDATE` → cancel + `return null`, unchanged · **`CONTENDED` → `return null`, no cancel, no release, no write** |
| `reassignOrCancelForMovedStockUnit` (move) | `if (!redirectSource(...)) { cancelOrder(order, lockedSource, CANCELLED); }` | `REDIRECTED` → unchanged · `NO_CANDIDATE` → cancel, unchanged · **`CONTENDED` → return, and the move still proceeds** |

**What a deferred order actually looks like, and why it heals.** `redirectSource` writes nothing: the order keeps `stockunitId` = the moved/current SU, keeps its reservation, and keeps its **old** `requestedlocationId`. On the move path that location is the replenishable one the SU just left, so the next recalc tick hits `isSourceUsable`'s `if (!locationId.equals(order.getRequestedlocationId())) { return false; }` and runs the ordinary redirect-or-cancel route. The order is briefly pointing at a stock unit on a non-replenishable location; the next tick resolves it. **This is the product owner's decision of 2026-10-04 and it is SETTLED — see §10 D1.**

⚠ **The self-heal is guaranteed only for `state == PROCESSABLE` `[A-6]`.** Both sweeps select on *exact* equality — `@Query("SELECT r.id FROM Replenishorder r WHERE r.state = :state")` and its `ORDER BY r.id` sibling, both called with `WmsConstants.State.PROCESSABLE` — and `recalculateOrder` re-guards with `!Objects.equals(order.getState(), WmsConstants.State.PROCESSABLE) { return; }`. But the move path admits a **wider** band: it probes `findIdByStateLessThanAndStockunitId(WmsConstants.State.FINISHED, …)` and rejects only `order.getState() >= WmsConstants.State.STARTED`. With `PROCESSABLE = 300 / RESERVED = 400 / STARTED = 500`, an order at 400 deferred on the move path **would be visited by no recalc sweep ever** — it keeps its reservation, keeps pointing at a stock unit on a non-replenishable lane, and nothing heals it. The existing move-path fixtures use exactly that state (`Replenishorder order = orderAt(WmsConstants.State.RESERVED);` in `ReplenishmentOrderMaintenanceServiceReassignTest`), so the codebase does not treat it as impossible.

**Measured, so it can be sized:** `SELECT state, count(*) FROM replenishorder GROUP BY state` returns `{300: 570, 700: 608, 800: 60452}` on `wsl-wineco-uat` and `{300: 1, 700: 2}` on `nywh-hydra-prd` — **no row at 400 or 500 on either**. Supporting code axis: `git grep -n "State.RESERVED" -- src/main/java` returns 9 hits and none sets a `Replenishorder` to it (all Pickingorder / Customerorder); positive control in the same scan, `git grep -c "State.PROCESSABLE"` returns counts across 5+ files, so the instrument finds state constants. **Blind spots:** two tenants at one instant; both ShipItEZ prd roles refuse `replenishorder`; and the grep cannot see a native `UPDATE replenishorder SET state` or a state arriving from an OMS import.

**So it is latent, not live — and the plan takes the cheap guard, not the narrowing one.** Fix E emits a **distinct, higher-visibility WARN** when `CONTENDED` is returned for an order whose state is not `PROCESSABLE`, naming the state. Narrowing `reassignOrCancelForMovedStockUnit` to cancel non-PROCESSABLE orders instead was considered and rejected: it would re-introduce the cancel-on-contention behaviour D1 just removed, for a state the measurement says does not occur. U-K pins the WARN.

**Who else reads that state** (axis: `git grep` on `replenishorder.stockunit_id` / `stockunit.reservedamount` read-for-a-decision, plus a read of each service named; blind spot: SQL views and Spring Data REST projections are not in that axis, so a report screen reading a view would be missed):

1. **SBDEV-2610 stranded-reservation reconciliation — safe by construction.** `findStrandedReservationStockunitIds` requires `AND NOT EXISTS (SELECT 1 FROM replenishorder r WHERE r.stockunit_id = su.id AND r.state < 700)`. A deferred order is `state = 300` and still points at the SU, so the SU is not stranded; `ReplenishmentReservationReconciliationService` additionally re-validates per row before mutating.
2. **Picking — unaffected.** Pick lines bind `pickingorder_position.pickfromstockunit_id`, a different FK, and `PickLineRealignmentService.realignForMovedStockUnit` explicitly leaves it alone (*"`pp.pickfromstockunitId` UNCHANGED (I-1)"*). The reservation reduces the SU's available amount for one cadence — a soft cost, not a correctness break.
3. **The move's own caller does not assume resolution.** `processTransfer` ignores the return (the method is `void`) and proceeds. The only thing it relies on is that no `BusinessException` is thrown, and the `state >= STARTED` guard that *does* throw runs **before** `redirectSource`, so a defer cannot let a started replenishment's stock move. That guard is preserved.
4. **Amplification:** `processTransfer` loops over every SU on the unit load and recurses into every child UL, so one move can produce N independent defer decisions in one transaction.

### Fix E — observability `[arch-5]`

A `WARN` on every `CONTENDED`, on both paths, naming the order number and the contended stock-unit id, with a stable greppable token:

```java
// A REPEATING order+target pair is the signal: it means either a live-lock, or a candidate row that
// no longer exists (SKIP LOCKED cannot distinguish "locked" from "gone"; the existsById check on the
// miss path narrows that window but does not close it — see Fix C).
LOG.warn("SBDEV-3637 REDIRECT_CONTENDED replenishOrder={} target={} path={} state={}",
         order.getNumber(), candidate.stockUnitId, recalcPath ? "recalc" : "move", order.getState());
// A6: a deferred order that is NOT PROCESSABLE is visited by no recalc sweep, so it does not self-heal.
if (!Objects.equals(order.getState(), WmsConstants.State.PROCESSABLE)) {
    LOG.warn("SBDEV-3637 REDIRECT_NO_HEAL replenishOrder={} state={} — no recalc sweep selects"
             + " this state; this order will not self-heal", order.getNumber(), order.getState());
}
```

There is no counter, no state and no stranded-order detector for this condition; nothing scrapes Prometheus in this deployment, so a log token beats a metric. A permanently contended target would otherwise defer forever with no symptom.

⚠ **`[N-2]` The two tokens must stay DISJOINT — neither a prefix of the other.** r2 named the second `REDIRECT_CONTENDED_NO_HEAL`, which has `REDIRECT_CONTENDED` as a prefix; a substring grep for the first then counts every no-heal line twice, so §7.6's *"a handful"* row hides the no-heal row's expected **zero** inside it, and U-I's *"exactly once"* reads two lines on a non-`PROCESSABLE` order. Renamed to `REDIRECT_NO_HEAL`. This is the **only production instrument this change ships**, so a token that cannot be counted is the whole instrument failing. If either token is renamed again, re-check disjointness and re-check §7.6 and U-I with it.

### Fix F — delete and replace the ⚠ comment `[arch-6, arch-7]`

Delete the whole `⚠ LOCK ORDERING — NOT PROVED SAFE` block. Its two VERIFIED claims survive and must be preserved in the replacement; its NOT ESTABLISHED claim points at the wrong cycle and its stated mechanism is refuted (§2.2).

⚠ **The replacement must NOT open with *"Ascending-id lock order: matches ReplenishorderService.redirectSource's D7 branch"* `[M8]`.** That is false: D7 genuinely reorders its two acquisitions and the `TreeSet` genuinely sorts; Fix B keeps role order and makes the inverting edge non-blocking — a different and weaker property. Writing a false equivalence at the exact site the old block occupied repeats the failure the old block's own history records: three successive attempts to argue this path safe, each wrong. Open with what is true — the Fix B code comment as drafted, verbatim: *"Role-ordered acquisition is RETAINED: the inverting edge declines to WAIT rather than reordering…"*

The replacement then states: the descending/ascending branch and the real reason each gets its finder; the `SKIP LOCKED` vs `NOWAIT` asymmetry (Fix B `[arch-6]`); the two id-ordering counterparties the old block never named; and D2's expiry condition (§10 D2). It must **not** repeat the `idx_replenishorder_active_item_dest` ceiling as a bound — that index caps per destination, not per item (§0).

⚠ **`[A-7′]` It must carry the two open residuals SPLIT, not collapsed** (§9 AC-8, §4 Fix B): `transferStockToUnitLoad`'s role-ordered src/dst pair runs through **this method's target acquisition**, so always-skip-locking this edge **would** close it and the ticket declines to — P-7 closes it at its own site instead, and **until P-7 lands this edge carries a live SU↔SU ABBA**. `cancelReplenishmentOrder`'s SU-before-order runs through the **source** acquisition, which no option here changes, so nothing done at this line can close it. ⚠ **It must NOT say that skip-locking this edge would buy nothing** — that is false for `transferStockToUnitLoad`, it was r2's wording, and it is the fourth successive wrong safety argument this site has attracted. The one a reader must be able to act on is that the cycle is closable and deliberately left open.

### Fix G — documentation

`sbdocs/3-Resources/design/wms2-replenishment-design.md`:
- the **"Who re-sources an order"** table, **row 1 `Locks` cell**, currently *"order → current SU → target SU, **not** id-ordered — the one writer left that can ABBA with another order (bounded by 40P01 / `lock_timeout`; SBDEV-3608 P5 → **SBDEV-3637**, T3, not built)"* — false in every clause once this lands;
- its stale `verified_by`, which still calls SBDEV-3638 *"PR pending, not merged"* and SBDEV-3622 *"unmerged, stacked on SBDEV-3621 PR #444"*; `git merge-base --is-ancestor` says both are in `develop` (positive control for that probe: the same sweep found six genuinely unmerged branches, so it can and does return false);
- the **"Releases outside the cron — SBDEV-3621"** bullet must be left standing, with a sentence saying this fix does not close it.

Also: `architecture/wms2-transaction-osiv-boundary-map.md` §8.5 (the *"Residual ABBA, bounded"* bullet and the 2026-10-01 SBDEV-3618 changelog row both need a successor row); `workflows/wms2-replenish-workflow.md` (`CONTENDED` is a new terminal state for a recalc tick); `architecture/wms2-function-to-docs-map.md` §9 Replenishment row (add the pointer, do **not** bump `last_verified` — house convention for a single-row touch).

⚠ `last_verified` on these files is close to worthless as a freshness signal; read `verified_by`, which is a stack of single-section passes that each say *"last_verified deliberately NOT bumped."*

---

## 5. File change summary

| File | Change |
|---|---|
| `repo/jpa/StockunitRepository.java` | **+1 method** `findByIdForUpdateSkipLocked` (Fix A) |
| `service/ReplenishmentOrderMaintenanceService.java` | `RedirectOutcome` enum + javadoc (C); hybrid branch + `targetIsBelowHeldSource` (B); the skip-locked-miss `existsById` disambiguation (C); two caller mappings (D); two WARNs (E); ⚠ comment deleted and replaced (F) |
| `src/test/.../unit/service/ReplenishmentOrderMaintenanceServiceReassignTest.java` | **U-11b and the SBDEV-3618 Fix D pin REWRITTEN**, not renumbered (§7.3) |
| `src/test/.../unit/service/ReplenishmentOrderMaintenanceServiceUnitTest.java` | new `CONTENDED` siblings; existing cases unchanged unless §7.3 lists them |
| `src/test/.../unit/service/ReplenishmentFirstTouchInvariantUnitTest.java` | expected green; its weakened `verifyNoMoreInteractions(ignoreStubs(...))` guard is tightened to name the new finder (§7.3) |
| `src/test/.../service/ReplenishRedirectLockOrderIT.java` | **new** (§7.2). ⚠ **Does NOT extend `AbstractReplenishRedirectPgFixture`** — see §7.1 |
| `src/test/.../integration/repository/StockunitSkipLockedIT.java` | **new** (§7.2) |
| `src/test/.../service/ReplenReassignOnNonReplenishableMoveIT.java` | javadoc mutant list updated — *"make `redirectSource` never succeed"* becomes ambiguous once that splits into two outcomes. ⚠ Its header's blanket *"measured 2026-09-07, every test killed by at least one mutant"* is amended: the split adds a mutant that post-dates that measurement |
| `src/test/.../unit/config/TestClassTransactionManagerArchTest.java` | ⚠ **ADDED to this table 2026-10-05 — the plan omitted it.** Rail **registration**, not drift: the `EXEMPT_NON_TRANSACTIONAL` allow-list gains the two new `NOT_SUPPORTED` ITs, which the rail otherwise reds |
| `src/test/.../unit/config/NeverMatcherNullBlindnessArchTest.java` | ⚠ **ADDED to this table 2026-10-05 — the plan omitted it, and its absence was flagged as possible unscoped drift before being confirmed legitimate.** A forced inventory bump, `ReplenishmentOrderMaintenanceServiceUnitTest: 7 → 10`, for three new `anyBoolean()` positions in U-F/U-G. All three are argument 3 of `StockunitBusinessService.changeReservedAmount`, declared `boolean zeroIfNegative` — **signature read, not inferred from the matcher name** — so `anyBoolean()` is required and `any()` would NPE at unboxing. Structurally identical to the row above, which the plan *did* anticipate; **§5 was incomplete, the diff was not** |
| docs | Fix G — four files, not one: `wms2-replenishment-design.md` plus `wms2-transaction-osiv-boundary-map.md`, `wms2-replenish-workflow.md` and `wms2-function-to-docs-map.md` |

**No change to `AbstractReplenishRedirectPgFixture` `[H6]`, and that is a decision, not an omission.** r1 planned the new IT as that class's fifth subclass. It cannot be one: its two seeding helpers are **private** and hard-code the values §7.2 must vary — `private void area(long id, String name)` inserts `useforreplenish` as a literal `true`, and `private void location(long id, String name, long areaId, Long rackId, long typeId)` inserts `staginglane, transferlane` as literal `false, false`. No non-replenishable lane destination can be seeded through them, so `reassignOrCancelForMovedStockUnit` would return at its first guard (`isReplenishableDestination(destination)`) and the IT would be **vacuous rather than red**. Making the helpers `protected` and parameterised would touch four existing subclasses (`ManualCutCooldownEndToEndIT`, `ReplenishmentHeldShareIT`, `ReplenishorderRedirectSourceIT`, `ReservationCutAttributionIT`). §7.1 takes a third route — model the new IT on `ReplenReassignOnNonReplenishableMoveIT`, which already seeds exactly this shape — so no existing test file changes and this row stays empty.

**No Flyway migration.** The fix adds a repository method and changes a private method's return type — no column, index, constraint or seed row. Both partial unique indexes this plan leans on already exist in `V2.2.00__base_v2_schema.sql` and in `db/v1-to-v2-onboarding/schema/V2.1.04__replenishorder_performance_indexes.sql`, and were observed live on `wsl-wineco-uat` and `nywh-hydra-prd`.

---

## 6. Implementation steps

### 6.1 Prerequisites

| # | Prerequisite | Required value / action | State |
|---|---|---|---|
| 1 | Database state | No schema change. Both partial unique indexes present | ✓ verified on 2 tenants |
| 2 | Feature flags / sysprops | None added. The defer window depends on `REPLENISHMENT_TIMER_{HOUR,MINUTE}`, `REPLENISHMENT_TIMER_ACTIVATED`, `NEW_CRON_JOB_ACTIVATED` — see §8 R-1 | ✓ verified on `nywh-hydra-prd` + 2 UATs; ⚠ not on either ShipItEZ prd |
| 3 | Config / env | None. Do **not** set the lock-timeout hint globally (§4 Fix A) | N/A |
| 4 | Deploy order | None. Single repo, no contract change | N/A |
| 5 | Data migration | None | N/A |
| 6 | External systems | None. No OMS/outbox write added | N/A |
| 7 | Access / permissions | None. No new endpoint, no new `FunctionEnum` constant. The new finder is `@RestResource(exported = false)` | N/A |
| 8 | Monitoring | Two WARN tokens, `SBDEV-3637 REDIRECT_CONTENDED` and `SBDEV-3637 REDIRECT_NO_HEAL`, are the only instruments (Fix E). They must stay **disjoint** — neither a prefix of the other `[N-2]` | — |
| 9 | Sequencing vs SBDEV-3626 | 3637 lands first; 3626 rebases | **✓ settled — §10 D4** |

**SBDEV-3626 is the only file-level collision, and the sequencing is settled (§10 D4).** It edits `ReplenishmentOrderMaintenanceService.java` and its own call-site audit names `redirectSource` at two line anchors. Different hunks (3626 adds a `STARTED(500)` claim state governing *which* orders the cron may touch; 3637 changes *in what order* it locks), so they are orthogonal in intent and colliding only in text. Its claimed gate commit `c99ddaff` does not resolve in this clone (`git cat-file -t` → *unknown revision*, no branch, no worktree among the 53 listed), so there is nothing for 3637 to rebase onto: 3637 lands first. Every other ticket the brief called "in flight" — SBDEV-3608, 3618, 3621, 3624, 3633, 3636, 3638, 3605, 3622 — is an **ancestor of `ec42f43a`** by two instruments (`git rev-list --left-right --count`, `git merge-base --is-ancestor`), with the positive control noted in Fix G.

### 6.2 Checklist

1. **TDD gate** (`wms-tdd-gate`, worktree off freshly-fetched `origin/develop`). Tests must compile against today's code: the unit tests drive the existing public surface, and the new IT's pre-fix expectation is `40P01`.
   ⚠ **`[M9]` Fix A has no literal red-first. Declared as a deviation, with a substitute that is a real one.** `StockunitSkipLockedIT` cannot name `findByIdForUpdateSkipLocked` before Fix A exists. The substitute costs one commit: write IT-3b and IT-3c against the **existing** `findByIdForUpdate` first and watch them fail for the right reasons — 3b fails because the call *waits* (elapsed ≈ `wms.tenant.lock-timeout-ms` rather than an immediate empty), 3c fails because the emitted SQL carries `for update` and **not** `skip locked`. Then re-point both at the new finder in step 2. Record both reds in the gate output; a gate that skips this has not red-firsted Fix A.
2. Fix A (repository method) + `StockunitSkipLockedIT`, with its positive control. Gate: `FOR UPDATE … SKIP LOCKED` is observed in the emitted SQL on the **tenant** EMF.
3. Fix C (enum + javadoc) and Fix D (caller mappings) as one commit — the signature change and its two call sites must not be split.
4. Fix B (hybrid branch). Apply the §7.3 pin rewrites in this same commit; they are what prove Fix D (SBDEV-3618) is still pinned.
5. Fix E (WARN) and Fix F (comment replacement).
6. Fix G (docs), then `verify-docs`.
7. Full `mvn clean verify` against a fresh baseline measured adjacent in time (there is no single correct suite number in this repo). PIT scoped to `ReplenishmentOrderMaintenanceService`, **JDK 21 runtime** — JDK 25 silently reports 0% — and `mvn clean` first if a constant mutant was run.

⚠ `pgrep` for a peer's `mvn` before treating any integration red as real: concurrent Maven runs share one reusable postgres container and produce false reds. `OutboxConcurrentEnqueueIT`, `ReplenishDupConcurrencySliceIT` and `ParcelMonitorViewServiceConcurrencyIT` are known timing-flaky — rerun before debugging.

---

## 7. Testing plan

**No verify script.** T3 makes one opt-in, not mandatory, and every assertion here is expressible in JUnit — which runs in CI, survives refactors and can be mutation-checked. Verify scripts have been a measured net negative in this repo (12 of 16 deliberately-broken implementations once scored a full green). §9's acceptance criteria are graded by the tests named below, by name.

### 7.1 Templates — three, not one

| role | class | why |
|---|---|---|
| fixture / seeding template | **`ReplenReassignOnNonReplenishableMoveIT`** (471 lines, `extends BasePostgresIntegrationTest`, `@Transactional(propagation = Propagation.NOT_SUPPORTED)`) | `[H6]` **This, not `AbstractReplenishRedirectPgFixture`.** It is the only class in the repo whose seeding helpers take the flags this IT must vary: `private void area(long id, String name, boolean useForReplenish)` and `private void location(long id, String name, long areaId, boolean transferLane)`. It already seeds the exact shape — a non-replenishable destination area plus an alternate same-item source — and carries its own `wipe()`. **Copy its helper shape into the new class** (the repo's existing practice; these helpers are private per-class, not shared). ⚠ `AbstractReplenishRedirectPgFixture`'s `area()` and `location()` are **private and hard-code `useforreplenish = true` / `staginglane = false, transferlane = false`**, so subclassing it yields an IT that returns at `isReplenishableDestination` and is **vacuous, not red** — see §5. ⚠ Whatever ids are chosen, re-run the SBDEV-3561 A0 sweep (`git grep -n -E "99[0-9]{2}L" -- src/test`) first: the 9984–9998 band is nearly full |
| probe | `MoveUnitloadLockOrderProbeIT` | its `pg_stat_activity.backend_xid` trick (*"PostgreSQL assigns an xid on a backend's first row lock or write, so a NULL `backend_xid` while blocked means no row lock or write came before"*) is **the only mechanism in this repo that proves WHICH lock came first**. Without it, "no deadlock in N runs" is a zero-scan and proves nothing |
| positive control | `PostgresDeadlockDetectorControlIT` | it exists because *"a broken instrument and a true zero are indistinguishable."* Any AC of the form "after the fix, no 40P01" is unfalsifiable without it in the same lane |

Do **not** drive locks through a raw `JdbcTemplate`: `MoveCronConcurrencyIT`'s javadoc records that a template bound to a standalone `DriverManagerDataSource` in autocommit releases a `SELECT … FOR UPDATE` lock at statement end, and that two sibling concurrency ITs in this repo have exactly that defect.

⚠ **`[A-8/M1]` This binds IT-2, which r1 wrote as "park a raw JDBC holder" — a direct contradiction of the line above.** IT-2's holder is either (a) the same `TransactionTemplate(tenantTransactionManager)` holder the IT-1 choreography already uses, or (b) a `java.sql.Connection` obtained from the container `DataSource` with **`setAutoCommit(false)`**, which issues its `SELECT … FOR UPDATE`, is held open across a `CyclicBarrier` for the whole probe, and is **rolled back and closed in a `finally`**. (a) is preferred — it reuses a mechanism already proven in this file. An autocommit holder makes IT-2 assert `CONTENDED` against a row nobody holds: a green that proves the opposite of what it claims.

### 7.2 New tests

**`ReplenishRedirectLockOrderIT`** — `extends BasePostgresIntegrationTest`, `@Transactional(propagation = Propagation.NOT_SUPPORTED)` (required by `TestClassTransactionManagerArchTest`, which already names this area). `[H6]` It carries its own seeding, copied in shape from `ReplenReassignOnNonReplenishableMoveIT`'s `area(id, name, useForReplenish)` / `location(id, name, areaId, transferLane)` / `unitload` / `stockunit` / `replen` helpers and its own `wipe()`. `[L2]` Its vocabulary is its own — it inherits none, so the parallel-naming hazard r1 created by mixing `S1/O1` with `SU_A/ORDER_X` does not arise; use one scheme and keep it.

Fixture: one client, one itemdata; `AREA_REPLEN (useforreplenish = true)` with `LOC_1`, `LOC_2`; `AREA_LANE (useforreplenish = false)` with **two distinct** `LANE_1`, `LANE_2` (so the two moves do not serialise on the destination `Location` lock — or pass `ignoreLock = true`, as `ReplenReassignOnNonReplenishableMoveIT.move()` already does); `UL_1 @ LOC_1`, `UL_2 @ LOC_2`; `S1` on `UL_1` (lower id, 100/10), `S2` on `UL_2` (higher id, 100/10); orders `O1 → S1` and `O2 → S2`, both `state = 300`, requested 10, **with two distinct `destination_id`s**.

⚠ Two distinct destinations are **mandatory**: `idx_replenishorder_active_item_dest` is `(itemdata_id, destination_id) WHERE (state < 700)`, so two active same-item orders sharing a destination violate it. Note what this means and what it does not: the index **permits** the two-order configuration this IT needs (that is why `ReplenishorderRedirectSourceIT` can seed it), it only forbids sharing a destination. This is the single easiest way to get the fixture wrong, and M-5 below pins it. ⚠ Second trap, already documented in `ReplenReassignOnNonReplenishableMoveIT`'s javadoc: the two `isReplenishableDestination` implementations **do not agree** — `ReplenishmentOrderSourceSyncService`'s consults the SBDEV-1666 lane sysprop *and* the area flag, `ReplenishmentOrderMaintenanceService`'s consults the area flag only.

Choreography — **pre-seize, do not race**. Thread A takes `findByIdForUpdate(S1)` inside a `TransactionTemplate(tenantTransactionManager)`, signals a `CyclicBarrier`, waits; thread B does the same for `S2`; then each runs `transferUnitLoadToLocation(UL_n, LANE_n, …, CODE_MANUAL_TRANSFER, …)` **in that same transaction**. The re-lock inside `reassignOrCancelForMovedStockUnit` is a no-op at the same mode, not an upgrade. The naked-race fallback is rejected: this repo already has three timing-flaky concurrency ITs.

| id | assertion | pre-fix | post-fix |
|---|---|---|---|
| IT-1a | precondition: `current_setting('deadlock_timeout')` is read, and the effective `lock_timeout` inside a tenant transaction **exceeds** it | — | — |
| IT-1b | `assertThat(failures).hasSize(1)` — **exactly one** side fails (derivation: the two futures' outcomes; both failing means the fixture serialised them on something else, neither failing means the cycle never formed and the test is vacuous) | 1 | 0 |
| IT-1c | unwrap to the `java.sql.SQLException` (walk `getCause()`, as `ReplenishmentOrderMaintenanceService.hasSqlCause` does) and assert `getSQLState().equals("40P01")`, with a message naming `55P03` as the wrong answer: *"55P03 here means a lock_timeout fired before the detector and this test graded ordinary contention, not an ABBA"* | `40P01` | n/a |
| IT-1d | `pg_stat_database.deadlocks` incremented by 1 (**poll** at `PGSTAT_STAT_INTERVAL` 500 ms; never `sleep`) | +1 | +0 |
| IT-1e | after the fix: both moves commit; **each order is asserted to a SPECIFIC post-state, not to a disjunction** — under the pre-seize choreography both targets are held, so both orders must be `state = 300` with `stockunit_id` **unchanged** (`O1 → S1`, `O2 → S2`), `reservedamount` unchanged on both SUs, and a `SBDEV-3637 REDIRECT_CONTENDED` WARN for each. `[M10]` r1's *"either redirected or deferred"* was satisfiable by an implementation that does nothing at all on the move path; the exact post-state is not, and the redirect-succeeds leg is graded separately by `ReplenReassignOnNonReplenishableMoveIT`'s AC2 (`moveOntoLaneWithAlternate_reassignsSameOrder`) — named here so the pair is read as one | — | green |

**Why `40P01` and not `55P03`, and why the lane's lock timeout must not be shortened.** `deadlock_timeout` is the PostgreSQL default **1000 ms** (measured `source = default` on Hydra prd and WineCo UAT). The integration lane sets `wms.tenant.lock-timeout-ms=10000` (`src/test/resources/application-postgres-integration.properties`), deliberately diverged from production's 3000 (`src/main/resources/application.properties`), and `LockTimeoutHibernateJpaDialect` issues `SET LOCAL lock_timeout` per tenant transaction, applied per lock **acquisition**. 10 000 ≫ 1 000, so the deadlock detector always wins in this lane and `40P01` is the stable, non-flaky expectation. **Do not shorten `wms.tenant.lock-timeout-ms` for this test** — at or below `deadlock_timeout` a genuine ABBA converts into a `55P03` that looks exactly like ordinary contention, which is the misattribution `PostgresDeadlockDetectorControlIT` was written to warn about. M-3 pins this.

**`ReplenishRedirectLockOrderIT` probe case (IT-2)** — using the `MoveUnitloadLockOrderProbeIT` mechanics: hold the target row from a **non-autocommit** holder per §7.1's rule `[A-8/M1]` (preferred: a second `TransactionTemplate(tenantTransactionManager)`; otherwise a `Connection` with `setAutoCommit(false)`, held across the probe and rolled back in a `finally`), drive one descending-edge redirect, and assert the worker **does not block at all** (it returns `CONTENDED` in-band) while a control ascending-edge redirect **does** block with a non-null `backend_xid`. This is the only assertion in the plan that distinguishes "ordered correctly" from "happened not to deadlock".

**`StockunitSkipLockedIT` (IT-3)** — repository-level, Testcontainers.
- IT-3a: with no competing lock, `findByIdForUpdateSkipLocked(id)` returns the row (**positive control** — without it, a method that always returns empty passes IT-3b).
- IT-3b: with a second connection holding the row, it returns `Optional.empty()` **immediately**, and the elapsed time is well under `wms.tenant.lock-timeout-ms` (asserting on the in-band miss, not on a timeout).
- IT-3c: the emitted SQL contains `for update` **and** `skip locked`, captured from the Hibernate SQL log or a statement inspector **on the tenant EMF**. This is the AC that closes Fix A's named blind spot (a `HibernatePropertiesCustomizer` elsewhere) — an annotation assertion would not.

**`ReplenishmentOrderMaintenanceServiceIntegrationTest` (existing, IT-4 — starvation).** A deferred order must be re-offered a source on a later pass and must not be starved by the deterministic candidate sort. Hold the target past one sweep, release, run the next `recalculateForItem`, assert the order is `PROCESSABLE` **with a source**. The structural reason this converges: the sort's tiebreak is `available = amount − reserved`, so a successful reservation on target T *lowers* T's available and demotes it. The pathological cases are exact `available` ties and a winner whose reservation is released again before the next pass; Fix E's WARN token is the observability for both.

### 7.3 Existing pins — two break BY DESIGN and must be REWRITTEN, not renumbered

| pin | what it asserts today | treatment |
|---|---|---|
| `ReplenishmentOrderMaintenanceServiceReassignTest` **U-11b** `reassignOrCancelForMovedStockUnit_shouldLockMovedStockBeforeShareAndBeforeCandidate_whenRedirecting` — `lockOrder.verify(stockunitRepository).findByIdForUpdate(MOVED_STOCK_ID)` … `.findByIdForUpdate(99L)` | **moved-SU-then-candidate** | **REWRITE.** `MOVED_STOCK_ID = 42L` vs candidate `99L` is an ascending pair, but the **move path always uses skip-locked** (§4 Fix B), so the second row becomes `findByIdForUpdateSkipLocked(99L)` and the `stubRedirectSuccess` helper's stub must be re-pointed with it. ⚠ **Flipping the fixture ids to keep the old assertion green would destroy what it asserts** — the pin's content is "the moved SU is locked before the candidate", and that content survives; only the finder changes. This rewrite **is** the proof that SBDEV-3618 Fix D is still pinned rather than silently un-pinned `[arch-4]` |
| ~~the SBDEV-3618 Fix D lock-order pin in the same class~~ | ~~`findByIdForUpdate(99L)` on the move path~~ | **CORRECTED 2026-10-05 — this row and the one above describe the SAME assertion, so "two pins" was a double-count.** At `origin/develop`, `ReplenishmentOrderMaintenanceServiceReassignTest` contained **exactly one** `findByIdForUpdate(99L)` — the U-11b assertion — so the two rows could only ever have described that one assertion. ⚠ **Narrower than it first reads:** that literal is *not* unique repo-wide. `MobilePalletizeFirstTouchInvariantUnitTest` carries two, but on `unitloadRepository`, a different repository on a different path, so they are unrelated. (Derivation: `git grep -c "findByIdForUpdate(99L)" origin/develop -- src/test` → ReassignTest 1, MobilePalletize 2; positive control: the scan returns non-zero, so it is not a broken instrument. Blind spot: a differently-spelled literal or a named constant would not match — this is a claim about that exact spelling.) U-11b **is** the SBDEV-3618 Fix D lock-order pin. One rewrite, not two — and the rewrite is what keeps Fix D pinned rather than silently un-pinned |
| `ReplenishmentFirstTouchInvariantUnitTest.redirectSource_loadsTheTargetUnderItsLock` | `InOrder`: `findByIdForUpdate(candidateId)` before `findById(candidateId)` | **Expected green.** Its fixture stubs `findByIdForUpdate(SU_SRC) → Optional.empty()`, so the **null-source rule** (§4 Fix B, `[arch-2]`) routes it to the plain finder. ⚠ Its `verifyNoMoreInteractions(ignoreStubs(...))` guard is documented as weakened — *"a newly added finder is caught only IF NOBODY STUBS IT"* — so a stubbed `findByIdForUpdateSkipLocked` would slip past it. **Tighten it to name the new finder explicitly**, per the class's own instruction (*"If you tighten anything here, tighten the two weakened ones"*) |
| `ReplenishmentOrderMaintenanceServiceUnitTest` (2165 lines, 76 `@Test`) | the recalc surface; `redirectSource` is `private`, so nothing calls it directly — the boolean is observed **through** its callers, as `State.CANCELED` or as a kept order | **No compile break.** `CONTENDED` is a **third** post-state these tests do not enumerate; add siblings (U-F below), do not rewrite the existing cases |
| `ReplenReassignOnNonReplenishableMoveIT` | AC1–AC8 on the move path; its javadoc enumerates its own mutants (*"make `redirectSource` never succeed → kills AC2 and AC8"*) | **Javadoc update with the code** — "never succeed" becomes ambiguous once it splits into `NO_CANDIDATE` and `CONTENDED` |
| `ReplenishmentOrderMaintenanceServiceIntegrationTest` (SBDEV-2234 AC-4, concurrent `recalculateForItem`) | the delta invariant under concurrency | **Treat any red here as signal**, not noise — it is already a concurrency test on the exact method whose lock topology changes |
| `OptionalSafetyArchTest` (`FreezingArchRule`) | `Optional.get()` sites | Quiet **if** the new finder is consumed with `.orElse(null)`, matching all three existing sites. Use `.orElse(null)`. ⚠ Never refreeze merely because the store's line numbers look stale — they are stale on develop by 55 entries and the build is green |
| `ReplenishReassignContextLoadTest` | the `@Lazy` DI-cycle break | The cheapest canary for a bad `findByIdForUpdateSkipLocked` signature |

Any other existing red means **stop and add a row here with its reason** before editing the test.

### 7.4 New unit tests

All on `ReplenishmentOrderMaintenanceServiceUnitTest` / `…ReassignTest`, driving the existing public surface.

**U-param `[A-10]` — ONE `@ParameterizedTest` over `(recalcPath, source id, target id)`, replacing r1's five separate `verify()` pins.** Five name-coupled Mockito pins drift case by case and a rename un-pins each silently; one table cannot. The axes are the two ids themselves, **not** "id relation plus a null-source flag" — r2 declared the narrower axes and then could not express the `null-target` row that AC-3 and M-11 both grade against `[N-3/NEW-4]`. Each row asserts **both** halves — which finder was called **and** `never()` on the other — so no row is vacuous, and the `never()` matchers use the literal id, never `any()` (`any()` returns null and NPEs at unboxing).

| row | `recalcPath` | source id | target id | expected finder |
|---|---|---|---|---|
| asc-wide | true | 10 | 99 | **plain** `findByIdForUpdate(99L)`, `never()` skip-locked |
| asc-boundary | true | 10 | 11 | **plain** `findByIdForUpdate(11L)` — `target = source + 1`, the `>` boundary from above `[H5]` |
| desc-wide | true | 99 | 10 | **skip-locked** `findByIdForUpdateSkipLocked(10L)`, `never()` plain on 10 |
| desc-boundary | true | 11 | 10 | **skip-locked** `findByIdForUpdateSkipLocked(10L)` — `target = source − 1`, the `>` boundary from below `[H5]` |
| null-source | true | `null` | 11 | **plain** `[arch-2]`. Kills a null-source implementation defaulting to skip-locked |
| **null-target** | true | 10 | `null` | **plain** `[A-5′/N-3]`. Outcome is `NO_CANDIDATE` with **no exception thrown** — not an NPE and not `InvalidDataAccessApiUsageException`; `findByIdForUpdate` is a `@Query` finder, so a null id binds null and returns `Optional.empty()` (§4 Fix B `[A-5′]`). Reachable: `toLong` returns null from two branches. Killed by M-11 |
| move-asc | false | 10 | 99 | **skip-locked** anyway. Kills applying the recalc branch to the move path |
| move-desc | false | 99 | 10 | **skip-locked** |
| **move-null-source** | false | `null` | 11 | **skip-locked** `[A-4]`. This is the combination r1's case table answered two contradictory ways; it is reachable because `reassignOrCancelForMovedStockUnit` passes `lockedSource` with no null guard |
| **move-null-target** | false | 10 | `null` | **skip-locked** `[A-5″]`. The only row that reaches the `existsById` disambiguation with a null id — `skipLocked` is unconditional here, the skip-locked finder returns empty, and without Fix B's `candidate.stockUnitId == null ||` guard the call reaches `CrudRepository.existsById(null)`, which **in production** throws a bare `IllegalArgumentException` from `SimpleJpaRepository`'s `Assert.notNull`. ⚠ In **this** test the repository is a Mockito `@Mock`, so that `Assert` never runs and the no-exception assertion below cannot see the mutant — the row therefore also carries `verify(stockunitRepository, never()).existsById(any())`, which is what kills M-13. Expected: `NO_CANDIDATE` with no exception, so the caller **does** cancel (the move-path `NO_CANDIDATE` mapping in Fix D, unchanged) — a null candidate id is a vanished/unreadable candidate, not a contended one. Killed by M-13 |

⚠ `[NEW-7]` The wide and boundary rows must be **different** pairs. r2 wrote `asc = (10, 11)` and `asc-boundary = (10, 11)` — byte-identical, so the fixture was adjacent-only while the note below claimed it spanned the band. A mutation fixture needs a row in the dominant value band on **both** sides of the comparison *and* an adjacent pair on each side: without the wide rows a sign mutant can survive on arithmetic that only works at ±1, and without the adjacent rows `>` → `>=` and `>` → `<` survive on half the rows.

- **U-C** recalc, candidate **is** the current source (SBDEV-3618 Fix E): **neither** finder is called a second time, paired with a positive assertion that the order *was* re-pointed and saved (otherwise the `never()` is vacuous). Kills moving the branch above the Fix E return `[arch-3]`. ⚠ **U-C grades the Fix E return, not the comparison operator** — see M-6.
- **U-F** recalc, skip-locked returns empty: order is **not** `CANCELED`, `changeReservedAmount` is `never()` called with `CODE_REPLENISHMENT_SWITCHED`, `releaseHeld` is `never()` called, and the order's `stockunitId` is unchanged. Kills "defer then cancel".
- **U-G** move path, skip-locked returns empty: `cancelOrder` is `never()` called and the method returns normally (no `BusinessException`), so the move proceeds.
- **U-H** `changeReservedAmount` throws `FacadeException`: the caller **cancels** (i.e. `NO_CANDIDATE`), on both paths. Kills mapping that arm to `CONTENDED` `[arch-1]` — the single easiest way to get Fix C wrong.
- **U-I** the Fix E WARN is emitted exactly once per `CONTENDED`, carrying the order number, the target id, the path and the state. ⚠ **Assert on the token `SBDEV-3637 REDIRECT_CONTENDED` with the two tokens disjoint `[N-2]`** — with r2's `REDIRECT_CONTENDED_NO_HEAL` spelling a substring-based log capture saw two lines on a non-`PROCESSABLE` order and *"exactly once"* was ambiguous. Killed by **M-12**.
- **U-L** `[NEW-4]` recalc path, ascending edge, the **plain** finder returns empty (the target row vanished between the candidate query and the lock): the order is `CANCELED`. This is today's behaviour and it must survive the split — it is the leg of M-4 that r2 attributed to U-H, which grades the `FacadeException` arm instead and cannot see this collapse. ⚠ Check the 76 existing `@Test`s in `ReplenishmentOrderMaintenanceServiceUnitTest` for a case that already asserts it before adding one; if one exists, re-point M-4 at it by name rather than duplicating.
- **U-J** `[M3]` skip-locked returns empty **and** `existsById(targetId)` is `false`: the outcome is `NO_CANDIDATE`, not `CONTENDED` — so the move path cancels rather than deferring forever on a row that no longer exists. Its mirror (`existsById` `true` → `CONTENDED`) is the `desc-wide` and `desc-boundary` rows of U-param, so the `existsById` branch is pinned in both directions.
- **U-K** `[A-6]` `CONTENDED` on the move path for an order at `State.RESERVED`: the `REDIRECT_NO_HEAL` WARN is emitted and `cancelOrder` is still `never()` called. Pins the premise that defer-on-move self-heals only at `PROCESSABLE` without re-introducing the cancel D1 removed.

⚠ `never()` matchers: do **not** widen a primitive argument to `any()` — `any()` returns null and NPEs at unboxing. And a `never()` assertion is vacuous if the fixture never reaches the call at all; each of U-C, U-F, U-G pairs its `never()` with a positive assertion on the same run.

### 7.5 Mutation checks — every new assertion, with an ATTRIBUTABLE kill

A kill counts only if the failure message names the thing that broke. PIT scoped to the changed class, JDK 21 runtime.

| # | mutant | must go red | at |
|---|---|---|---|
| M-1 | revert Fix B (restore the unconditional plain finder) | IT-1c with `40P01`; U-param `desc-wide` | the ABBA |
| M-2 | replace defer with cancel on either path | IT-1e, U-F, U-G on `CANCELED` | the post-state |
| M-3 *(manual, lane-wide — not PIT)* | set `wms.tenant.lock-timeout-ms=500` in the integration lane | ⚠ `[L3]` **IT-1b fails FIRST**, non-attributably (*"expected size 1 but was 2"*), because at `lock_timeout 500 < deadlock_timeout 1000` **both** sides time out before the detector runs. Read that as the kill, or scope the timeout to one transaction and then assert IT-1c with `55P03` | proves the SQLSTATE assertion is not a tautology |
| M-4 | collapse the two `targetStock == null` cases to one outcome | U-F (if collapsed to `NO_CANDIDATE`: the order is cancelled) **or U-L** (if to `CONTENDED`: a vanished target on the recalc ascending edge defers instead of cancelling). `[NEW-4]` r2 named **U-H** for the second leg; U-H grades the `catch (FacadeException)` arm, which this collapse does not touch, so that leg had no killer | Fix C's mapping |
| M-5 *(manual fixture mutant)* | seed both orders with the **same** `destination_id` | the fixture insert fails with `23505` on `idx_replenishorder_active_item_dest` | proves the fixture is pinned to the real constraint |
| **M-6 `[H5/A-3]`** | **invert the comparison in `targetIsBelowHeldSource`.** ⚠ **PIT emits `>` → `<=` (`NEGATE_CONDITIONALS`), not `>` → `<`** — match a survivor to this row by the mutator name, not by the plan's prose | U-param rows `asc-wide`, `asc-boundary`, `desc-wide`, `desc-boundary`, each with an attributable message naming the finder that was called. `<=` is behaviourally identical to `<` here for exactly M-6b's reason, so the kill holds as PIT actually emits it | the sign — the error `[A-1/H4]` makes likely, and the one whose production signature is invisible |
| **M-6b** | `>` → `>=` in `targetIsBelowHeldSource` (**PIT: `CONDITIONALS_BOUNDARY`** — this is the mutator name a survivor will carry) | **NOTHING — marked EQUIVALENT, expected to SURVIVE.** `>` and `>=` differ only at `sourceId == targetId`, and that case returns from the SBDEV-3618 Fix E block above the predicate (§4 Fix B), on both paths, so the mutant is behaviourally identical. Read a survivor here as confirmation, not as a gap | recorded so a PIT survivor is not "repaired" |
| M-7 | change the hint value from `-2` to a positive millisecond value | IT-3b (the call now waits) and IT-3c (`skip locked` absent from the SQL) | this is SBDEV-3250's exact failure, replayed as a mutant |
| **M-8 `[M10]`** | make the move path return `CONTENDED` unconditionally | `ReplenReassignOnNonReplenishableMoveIT` AC2 (`moveOntoLaneWithAlternate_reassignsSameOrder`) | stops IT-1e grading a do-nothing move path as a pass |
| **M-9 `[M3]`** | drop the `existsById` disambiguation (map every skip-locked miss to `CONTENDED`) | U-J | the vanished-row conflation |
| **M-10 `[A-6]`** | drop the `REDIRECT_NO_HEAL` WARN | U-K | the non-PROCESSABLE premise |
| **M-11 `[A-5/A-5′]`** | drop the `targetId != null` guard in `targetIsBelowHeldSource` | U-param **`null-target`** (§7.4). ⚠ **Expected-green side REPAIRED:** unmutated, the outcome is `NO_CANDIDATE` with **no exception at all**; mutated, the `>` unboxes a null and throws a bare `NullPointerException`. r2 wrote the green side as *"expect the named `InvalidDataAccessApiUsageException`"*, which is **unsatisfiable** — `findByIdForUpdate` is a `@Query` finder and never raises it (§4 Fix B `[A-5′]`). The kill is still attributable: no-exception → NPE | the diagnostic, which is the whole point of the guard |
| **M-12 `[N-2/NEW-4]`** | drop the primary `SBDEV-3637 REDIRECT_CONTENDED` WARN | U-I | the only production instrument this change ships. r2 had a mutant for the no-heal WARN (M-10) and none for the primary one, and did not list it as uncovered |
| **M-13 `[A-5″]`** | drop the `candidate.stockUnitId == null ||` guard on the `existsById` disambiguation | U-param rows **`null-target`** / **`move-null-target`**: `verify(stockunitRepository, never()).existsById(any())` — unmutated the guard short-circuits and the call never happens; mutated it happens. ⚠ **Corrected (code review, 2026-10-05).** This row previously named “a bare `IllegalArgumentException` from `CrudRepository.existsById(null)`” as the killer. It is not: in that unit test the repository is a Mockito `@Mock`, so `existsById(null)` returns the default `false` rather than tripping `SimpleJpaRepository`'s `Assert.notNull`, the mutant takes `!false` → `NO_CANDIDATE` → `CANCELED`, and the row's existing state assertion passes unchanged. **M-13 SURVIVED that killer**, and AC-11's “attributable kill” was falsified for this one mutant. The guard itself was always correct — only its pin was wrong. A mock cannot reproduce the `Assert`, so “no exception” cannot see this mutant; “the call never happens” can. | the null hazard reintroduced one branch below the guard that prevents it |

⚠ **`[H5]` r1's M-6 (`>` → `>=`) was an equivalent mutant with an AC that said it must die, and its cheapest "repair" was to move the branch above the Fix E return — which U-C and `[arch-3]` forbid. The plan set a trap for its own guard rail.** It is kept above as M-6b, explicitly marked EQUIVALENT with its reason, so the survivor is readable. The reachable sign mutant is now M-6.

⚠ Mutation fixtures need a row in the **dominant value band**: a boundary mutant survives when every fixture row sits on one side of it. That is what U-param's `asc-boundary` and `desc-boundary` rows are for. No fixture can rescue M-6b — no equal-id row can reach the predicate.

**Assertions NOT covered by a mutant, named rather than implied `[M2]`:** IT-3a (it *is* the positive control for IT-3b, so a mutant of it is circular), IT-2's `backend_xid` probe (no mutant can simulate "the worker entered the lock queue" without rewriting the probe), and IT-4's starvation case (it is bounded evidence, not a proof — see AC-9). AC-11 is narrowed to exactly this set.

### 7.6 Manual test plan

| Scenario | Environment | Steps | Expected | Pass/Fail |
|---|---|---|---|---|
| Normal redirect still works | DEV wineco | make an order's source unusable (move its UL within a replenishable area), wait one cron tick (≤60 s) | the order is re-pointed; `reservedamount == requestedamount`; a `REPLENISHMENT_SWITCHED` stockrecord row exists | |
| Move onto a lane with an alternate source | DEV wineco | web Move Stock: move a UL whose SU backs an open replen order onto a staging lane | the move succeeds; the order is re-pointed to the alternate source, **not** cancelled | |
| Move onto a lane with no alternate source | DEV wineco | same, with the only other candidate removed | the move succeeds; the order is `CANCELED` with `CODE_REPLENISHMENT_CANCELLED` (unchanged behaviour) | |
| Started order still blocks the move | DEV wineco | move a UL whose SU backs an order at `state >= STARTED` | `BusinessException` naming the replen order — the guard runs **before** `redirectSource`, so a defer cannot bypass it | |
| Defer is observable | DEV wineco | grep the app log for `SBDEV-3637 REDIRECT_CONTENDED` over 24 h after deploy | zero or a handful of lines. ⚠ `[N-2]` This count is only correct because the two tokens are **disjoint** — with r2's `REDIRECT_CONTENDED_NO_HEAL` spelling this grep matched the no-heal line too, double-counting it and hiding the next row's expected zero inside this row's "handful". ⚠ A **repeating order+target pair** is either a live-lock **or** a candidate row that no longer exists — `SKIP LOCKED` cannot distinguish them and the `existsById` check narrows that window without closing it (Fix C `[M3]`). Check the row's existence before concluding live-lock | |
| No-heal defer | DEV wineco | grep for `SBDEV-3637 REDIRECT_NO_HEAL` | **zero.** Any line means an order outside `state = 300` was deferred on the move path, and no recalc sweep will visit it — resolve it by hand and re-read Fix D `[A-6]` | |
| SQL-level sanity | DEV DB, then each readable prd tenant | `SELECT count(*) FROM replenishorder r JOIN stockunit s ON r.stockunit_id = s.id JOIN unitload u ON s.unitload_id = u.id JOIN location l ON u.storagelocation_id = l.id JOIN location_area a ON l.area_id = a.id WHERE r.state = 300 AND a.useforreplenish = false;` — orders sitting on a non-replenishable source | 0, or a count that returns to 0 within two cron ticks | |

---

## 8. Risks and mitigations

| # | Scenario | Mitigation |
|---|---|---|
| **R-1** | **The defer window is longer than ~60 s on a tenant nobody measured.** The whole defer decision rests on it. Verified on `nywh-hydra-prd` and two UATs: `REPLENISHMENT_TIMER_{HOUR,MINUTE}` both `*`, `REPLENISHMENT_TIMER_ACTIVATED` and `NEW_CRON_JOB_ACTIVATED` both `true`, so `deriveSpecForCurrentTenant` yields `"20 * * * * *"` — every minute at second 20 | ⚠ **Blind spot: both ShipItEZ prd roles return `permission denied` on `replenishorder`/`los_sysprop`, and both prd MCP endpoints resolve to `wh01_hydra_v2`.** Probe before merge, one query per tenant: `SELECT syskey, sysvalue FROM los_sysprop WHERE syskey IN ('REPLENISHMENT_RECALCULATION_CADENCE_SECONDS','REPLENISHMENT_TIMER_HOUR','REPLENISHMENT_TIMER_MINUTE','REPLENISHMENT_TIMER_ACTIVATED','NEW_CRON_JOB_ACTIVATED');`. Pass: hour and minute `*`, activated `true`, cadence absent or `0`, master gate `true`. A tenant that fails it needs the defer decision re-confirmed for that tenant. Note the known cutover trap: `NEW_CRON_JOB_ACTIVATED = false` is the master gate for all six cron jobs — a tenant in that state would never resolve a defer at all |
| **R-2** | An executor meets the two intentionally-breaking pins and edits assertions until green, hollowing out SBDEV-3618 Fix D | §7.3 names both pins, states what survives and what changes, and says explicitly that flipping fixture ids would destroy the assertion. Any red **not** in §7.3 means stop and add a row |
| **R-3** | A spurious defer on the ascending edge (if someone later "simplifies" to always-skip-locked) is silent — no exception, no metric, no operator symptom | The hybrid keeps the ascending edge deterministic (§4 Fix B), Fix E logs every defer, and U-param's `asc-wide` and `asc-boundary` rows are the regression pins |
| **R-4** | `CONTENDED` is mapped to the `FacadeException` arm by a later refactor, letting the move "proceed" on a rollback-marked transaction | The invariant is stated in the enum's own javadoc (Fix C) and pinned by U-H and mutant M-4 |
| **R-5** | SBDEV-3626 lands first or concurrently and conflicts textually in `redirectSource` | Settled: §10 D4 — 3637 lands first, 3626 rebases |
| **R-6** | A reviewer reads this plan as "the move path is now deadlock-free" | §9 AC-8 states the scope limit, and Fix F puts it in the code |

---

## 9. Acceptance criteria

Graded by the tests named in §7, by name. No verify script.

- **AC-1** On the recalc path with a non-null current source and `targetId > sourceId`, the target is acquired with the ordinary waiting finder; with `targetId < sourceId`, with the skip-locked finder, including at the `±1` boundary on both sides. — *U-param rows `asc-wide`, `asc-boundary`, `desc-wide`, `desc-boundary`*
- **AC-2 — AMENDED 2026-10-05 during implementation; the original was empirically false.** `findByIdForUpdateSkipLocked` emits a **row-lock clause (`for update` OR `for no key update`) AND `skip locked`** on the tenant EMF, returns the row when uncontended, and returns empty immediately when contended. — *IT-3a/b/c* (3a is the positive control; 3c closes Fix A's blind spot, since an annotation assertion would not)

  > **Amendment ledger — `kind: replaced`.**
  > **Original (verbatim, retained):** *"`findByIdForUpdateSkipLocked` emits `FOR UPDATE … SKIP LOCKED` **on the tenant EMF**, returns the row when uncontended, and returns empty immediately when contended."*
  > **Reason it no longer governs:** Hibernate's `PostgreSQLDialect` renders `LockModeType.PESSIMISTIC_WRITE` as **`for no key update`**, never `for update`. The original literal is unsatisfiable, and — more importantly — `for update` does **not** discriminate the new finder from the old one, because it is absent from *both*. Only the `skip locked` token carries the signal.
  > **Evidence (two instruments, measured in the implementation worktree):** (a) the captured Hibernate statement for the new finder — `… from stockunit s1_0 where s1_0.id=? for no key update skip locked`; (b) independently, the gate IT's `pg_stat_activity` probe read the *blocked* backend running the **existing** `findByIdForUpdate` as `… from Stockunit s1_0 where s1_0.id=$1 for no key update`, with no `skip locked`. Mutant **M-7** (hint `-2` → `3000`) confirms the `skip locked` half is load-bearing: it fails on exactly that assertion.
  > **Corollary worth keeping:** both finders take the *same* lock mode, which is what preserves the SBDEV-3244 F4 / AC-10 same-mode no-op in `changeReservedAmount`.
  > **Non-vacuity guard in IT-3c:** the captured statements are lowercased, filtered to those containing `from stockunit`, and that list is asserted `isNotEmpty()` before any `anySatisfy` runs — otherwise an empty capture would pass silently.
  > **Authority:** SBDEV-3637 implementation lane · **Timestamp:** 2026-10-05
- **AC-3** A null current source **on the recalc path** uses the ordinary finder: no lock was taken for **this order's** source, so this acquisition adds no edge off a source of its own (⚠ not "the transaction holds no stock-unit lock" — see the §4 Fix B case table). A null `candidate.stockUnitId` likewise, and the outcome is `NO_CANDIDATE` with **no exception thrown** — neither a bare NPE nor a named Spring Data exception `[A-5′]`. On the **move** path a null `candidate.stockUnitId` reaches the `existsById` disambiguation and must still produce `NO_CANDIDATE` with no exception `[A-5″]`. — *U-param rows `null-source`, `null-target`, `move-null-target` (all three now defined in §7.4); mutants M-11, M-13*
- **AC-4** The move path uses the skip-locked finder for the target regardless of id relation **and regardless of whether the source is null**. — *U-param rows `move-asc`, `move-desc`, `move-null-source`*
- **AC-5** **Scoped to the method, not to the transaction `[A-2]`.** `redirectSource` itself wrote nothing, reserved nothing, and did not mark the transaction rollback-only, so the caller may carry on and the surrounding transaction may still commit. It is **not** asserted that the transaction is clean — `alignDestination` may have saved a destination id before `ensureValidSource` ran, and D1 requires the move's own writes to commit. On both paths a deferred order is **not** cancelled, keeps its source and its reservation; on the move path the move still proceeds. — *U-F, U-G, IT-1e; mutant M-8 stops IT-1e grading a do-nothing move path*
- **AC-6** The `catch (FacadeException)` arm maps to `NO_CANDIDATE`, so the caller cancels. — *U-H*, mutant *M-4*
- **AC-7** Today's code produces `40P01` on the move × move ABBA and increments `pg_stat_database.deadlocks`; after the fix both transactions commit and neither order is `CANCELED`. On the descending edge the contending worker returns in-band without ever entering the lock queue (`backend_xid` probe). — *IT-1a–e, IT-2*, with `PostgresDeadlockDetectorControlIT` in the same lane as the positive control
- **AC-8** **Scope limit, asserted as a limit — as a RULE, not as a count `[arch-7] [H3]`.** This fix closes the **target-acquisition edge** on both paths, and nothing more. It does **not** make the move path deadlock-free: `processTransfer` iterates `stockunitRepository.findByUnitloadId(...)` with **no `ORDER BY`** and locks its own moved SUs in unspecified order. **"All Stockunit locks are id-ordered" is NOT assertable and no AC may assume it.**
  ⚠ r1 wrote *"two pre-existing residuals"* — an uncontrolled exactly-N claim, and it was wrong (it omitted `transferStockToUnitLoad`). **The rule replaces the count:** *the residual set is every site that takes two or more `Stockunit` row locks in one transaction without comparing their ids, plus every site that takes a `Stockunit` lock before a lock it will also need on another resource type.* **Derivation method:** `git grep -n "stockunitRepository\.findByIdForUpdate" -- src/main/java` (17 sites, two instruments, §0) plus a per-method read of each, plus `git grep -in "for update"` for native locks. **Blind spots of that method:** bulk `@Modifying UPDATE`/`DELETE` row locks, dirty-checked `UPDATE`s at flush, and locks taken through another repository's join query are all invisible to it — so the rule's answer set is a lower bound, not a census.
  **What the rule currently returns** (§0 gives the quoted snippets) — **starting with this method itself `[NEW-3]`:** `ReplenishmentOrderMaintenanceService` on **both** paths, because the fix removes the WAIT on the inverting edge without introducing an id ordering (on the move path `!recalcPath` short-circuits the comparison entirely, and on the recalc path the comparison selects a *finder*, not an *order*) — so the method this ticket fixes **stays in the rule's answer set by construction**, and an AC that graded "does the rule return the right set" while omitting its own subject would be self-exempting; `StockunitBusinessService.transferStockToUnitLoad` `:202`/`:277`, role-ordered src-then-dst on same-itemdata rows — **the same defect shape as this ticket, and a live counterparty to the ascending edge this fix leaves waiting, closable by always-skip-locking that edge and deliberately left open instead** (§4 Fix B, §10 **P-7**); `ReplenishorderService.cancelReplenishmentOrder`, SU before the order row, which runs through the **source** acquisition and which no option in §4 could close (accepted in-code under SBDEV-3621); `StockunitRepository.getStockUnitsByItemDataIdForUpdate`, an unbounded multi-row `FOR UPDATE` ordered by `amount DESC` (§10 P-2); and the two per-position cancel loops, `CustomerorderPositionService:148` and `PickingorderBusinessService:566`, which accumulate N SU locks in unspecified order on a different itemdata axis. All are proposed, none folded in
- **AC-9** A deferred order is re-offered a source on a later pass and is not starved by the deterministic candidate sort. — *IT-4*. ⚠ **BOUNDED EVIDENCE, not a proof, and nobody may later cite it as one.** IT-4 exercises one hold-and-release cycle; it exercises **neither** pathology §7.2 names (an exact `available` tie, and a winner whose reservation is released before the next pass). Fix E's WARN token is the production instrument for both, and a repeating order+target pair in the log is the signal that this AC's evidence has run out.
- **AC-10** SBDEV-3244 F3 survives: the source is still loaded **under its lock as its first touch**. F4 survives too — skip-locked is still a `PESSIMISTIC_WRITE` locking read, so when the row comes back it comes back locked, and `changeReservedAmount`'s own `findByIdForUpdate` is still a no-op upgrade. — *`ReplenishmentFirstTouchInvariantUnitTest`, with its weakened guard tightened (§7.3)*
- **AC-11** **Narrowed to what is true `[M2/NEW-4]`.** Every new assertion is mutation-checked with an attributable kill **except the three §7.5 names as uncovered by construction** — IT-3a (it *is* IT-3b's positive control, so a mutant of it is circular), IT-2's `backend_xid` probe, and IT-4's starvation case. r1 claimed blanket coverage over ~19 assertions with 7 mutants; r2 narrowed the claim but left three holes (U-I had no mutant, M-4's second leg named a test grading a different arm, and AC-3 cited a `null-target` row the table did not contain). All three are closed: **M-12** covers U-I, **M-4**'s second leg now names **U-L**, and §7.4 defines `null-target` and `move-null-target` with **M-11** and **M-13** over them. The table now carries **14** rows (M-1…M-13 plus the EQUIVALENT M-6b) and the gaps are named rather than implied. ⚠ This claim is graded by reading §7.5 against §7.2/§7.4 row by row — there is no instrument that derives it, so a new assertion added during implementation without a mutant row silently falsifies it. — *§7.5*

  > **⚠ AMENDED 2026-10-05 after implementation — the sentence above describes DESIGN coverage (every assertion has a mutant row), and was being read as MEASURED coverage (every mutant was run and killed). Those are different claims and only the first was ever true.** What was actually measured, by the conformance lane's own PIT run (JDK 21, scoped to `ReplenishmentOrderMaintenanceService`, Testcontainers reuse disabled so each IT got a fresh container):
  >
  > * **Class totals:** 236 mutants, 177 killed (75%), test strength 83%. **On the diff's changed lines: 25 mutants, 22 KILLED.**
  > * **6 of 13 confirmed KILLED by PIT**, identified by mutator + line: M-4, M-6, M-9, M-10, M-11, and M-6b's *predicted survival*.
  > * **M-7 confirmed manually** by the implementation lane (hint `-2` → `3000`; IT-3b then waited 10.28 s and raised `PessimisticLockingFailureException`, IT-3c red on the `skip locked` assertion). That is SBDEV-3250's exact failure replayed deliberately.
  > * **7 are not PIT-reachable at all** and have no PIT record: M-1, M-2, M-5 and M-8 are manual/fixture mutants; M-3 is a lane property (`wms.tenant.lock-timeout-ms`); M-7 is an annotation value; **M-12 is a logging call, which PIT filters out by default**. Their absence from the PIT report is expected, not a gap — but it is also not evidence of a kill.
  > * **M-13 was FALSIFIED and is now re-pinned.** Its original killer could never have worked (a Mockito `@Mock` cannot reproduce `SimpleJpaRepository`'s `Assert.notNull`). Re-pinned on `verify(..., never()).existsById(any())`, and ⚠ **only the `move-null-target` row can kill it** — on `null-target` the recalc path returns at `if (!skipLocked)` before `existsById` is reachable.
  >
  > **Two equivalent mutants, not one.** The plan predicted M-6b (line 749, `ConditionalsBoundary`). PIT also surfaced a **second**, unnamed in any revision: line 649 `NullReturnVals` on `return NO_CANDIDATE;` in the `if (!skipLocked)` arm — on the recalc path `null` and `NO_CANDIDATE` both fall through to `ensureValidSource`'s terminal `cancelOrder`, so the two are indistinguishable, and the line is unreachable on the move path where they would differ. It is `SURVIVED`, not `NO_COVERAGE`: the line executes. **Read both survivors as confirmation; do not "repair" either.**
  >
  > **One NO_COVERAGE on a changed line, and it is pre-existing:** line 586 `NullReturnVals` on the `newRequested <= 0` arm. That line counts as "changed" only because `return false` became `return NO_CANDIDATE`; it is not a new assertion and this ticket did not uncover it. *Derivation: PIT's per-line report, read against `git diff origin/develop...HEAD`. Blind spot: PIT reports only the mutators it emits, so "22 of 25 killed" bounds the mutators PIT generates, not every way the code could be wrong.*
- **AC-12** Full suite green against a baseline measured adjacent in time, with the three known-flaky ITs rerun before any red is treated as real.
- **AC-13** Docs updated per Fix G, including the stale `verified_by` in `wms2-replenishment-design.md`, with the SBDEV-3621 residual left explicitly standing.
- **AC-14** A skip-locked miss on a **deleted** candidate maps to `NO_CANDIDATE`, not `CONTENDED`, so the move path cancels rather than deferring forever on a row that no longer exists; and a `CONTENDED` on a non-`PROCESSABLE` order emits the `REDIRECT_NO_HEAL` WARN, because no recalc sweep selects that state. The disambiguation is **racy in one direction only** — it can defer a vanished row but can never cancel a merely-locked one (Fix C, with its derivation and blind spot) — which is the property that makes a racy check acceptable here; **it is not asserted by a test** and must not be cited as one. — *U-J, U-K; mutants M-9, M-10*

### Horizontal scalability (v2 — mandatory)

| # | Concern | Verdict | One line |
|---|---|---|---|
| 1 | In-JVM state | **No** | The outcome is a return value — no cache, static or `ThreadLocal` added |
| 2 | Connection pool math | **No** | Same statement count on the same tenant connection; skip-locked shortens the hold, never lengthens it |
| 3 | Scheduled jobs | **No** | No job added or rescheduled. `ReplenishOrderJob` already holds a per-tenant two-key `pg_try_advisory_lock` on the **landlord** pool, released in a `finally`, at both the scheduled and manual entry points — so cron × cron on one tenant cannot occur across replicas. What is unguarded is cron × interactive, and `recalculateForItem` from `StockunitService` / `FixLocationAssignmentService` |
| 4 | Long transactions | **Improves** | Removes a wait of up to `wms.tenant.lock-timeout-ms` from the descending edge, shortening the move transaction's worst case |
| 5 | Request affinity | **N/A** | Nothing request-scoped or stateful across calls |
| 6 | Retry / idempotency | **Yes — satisfied** | `redirectSource` itself writes nothing on `CONTENDED` (AC-5's scoped form — *not* "the transaction wrote nothing"); the retry is the next recalc tick, recomputed from DB state. The Fix C mapping (the reserve failure must **not** map to `CONTENDED`) is what makes this true. ⚠ Idempotency of the *retry* holds only for `PROCESSABLE` orders — see Fix D `[A-6]` |
| 7 | Tenant context | **No** | No async boundary; everything runs on the caller's thread inside the tenant transaction |
| 8 | Distributed lock correctness | **Yes — the point of the change** | Both finders stay inside `@Transactional("tenantTransactionManager")`; the ascending edge keeps the SBDEV-3250 bound, the descending edge replaces a transaction-poisoning `55P03` with an in-band miss |
| 9 | Cache invalidation | **No** | Neither `Stockunit` nor `Replenishorder` is `@Cacheable` on this path |
| 10 | External notifications | **No** | No OMS/outbox write added; a deferred order emits no event, the same as today's skip outcome |

**Does defer behave differently with N replicas?** Yes, favourably: the advisory lock means only one replica's cron can be the deferrer for a tenant, so defers cannot pile up N-fold. The interactive paths scale with request volume, not replica count.

### v2-only constraints

| # | Constraint | Status |
|---|---|---|
| 1 | No new `@Transactional` — the changed methods join the caller | ✓ |
| 2 | No OSIV reliance | ✓ nothing lazy-loaded outside the tx |
| 3 | Constructor injection only | ✓ no new dependency |
| 4 | JPQL only where H2 must parse it | ✓ the new finder is JPQL; the `-2` hint is a no-op under H2's dialect, and no H2 lane asserts on it |
| 5 | No controller or payload change | ✓ |
| 6 | No new `FunctionEnum` constant / gate | ✓ |
| 7 | New repository method `@RestResource(exported = false)` | ✓ mandatory (Fix A) |
| 8 | Observability: WARN token only; no new metric (nothing scrapes Prometheus here) | ✓ Fix E |

---

## 10. Decisions and open questions

### Resolved

**D1 — CONTENDED DEFERS ON BOTH PATHS (product owner, 2026-10-04). SETTLED. Do not re-litigate; do not present alternatives.**
- **Recalc path:** no cancel, no release, no write. The next pass retries.
- **Move path:** no redirect, no cancel, no reservation change, and **the move still proceeds.** The order is briefly left pointing at a stock unit on a non-replenishable location, and the next recalc tick resolves it through the normal `isSourceUsable` → redirect-or-cancel route (verified: `isSourceUsable`'s `if (!locationId.equals(order.getRequestedlocationId())) { return false; }` fires, because the order keeps its **old** requested location — the replenishable one the SU just left).
- **The ticket's original "move path cancels on CONTENDED" is SUPERSEDED.** Cancelling would be a behaviour regression dressed as a retry: today the operator's move waits and usually succeeds; cancelling destroys the order instead of deferring it.

**D2 — hybrid, not always-skip-locked (architect, measured). WITH AN EXPIRY CONDITION `[A-9]`.** §4 Fix B. 77% of second-lock acquisitions sit on the ascending edge.
- ⚠ **D2 settled the edge DISTRIBUTION, not the contention RATE.** The cost of always-skip-locked is `P(ascending) × P(target locked at that instant)`; only the first factor was measured, and the second cannot be measured before this fix ships, because today that case *is* the deadlock. Do not cite D2 as having resolved "how often is a target contended".
- ⚠ **EXPIRY: if P-3 lands, collapse this branch to always-skip-locked.** The whole justification for keeping the plain waiting finder is the cost of a **lost recalc cadence** per spurious defer. P-3 ("on `CONTENDED`, try the next candidate") removes that cost — a skip-locked miss stops being a lost cadence and becomes "take the second-best source in the same tick" — and with it the only argument for the branch. Write this sentence into the Fix F comment, so the hybrid reads as provisional rather than as a permanent invariant. Fix E's WARN token is the instrument that will make the decision measurable in production.

**D3 — no verify script.** §7 opening paragraph.

**D4 — SBDEV-3637 sequences BEFORE SBDEV-3626 (lead, 2026-10-04). SETTLED.** Both rewrite `redirectSource`'s control flow; orthogonal in intent, colliding in text. 3626's claimed gate commit `c99ddaff` does not resolve in this clone — no branch, no worktree, verified with a positive control in the same scan — so there is nothing to rebase onto. 3637 lands first and 3626 rebases. §6.1 row 9 is closed by this.

### Open

**Q2 — ShipItEZ prd sysprops (R-1). PARTIALLY CLOSED 2026-10-05.** The defer window was measured on a **production** tenant, not only UAT: `nywh-hydra-prd` returns `REPLENISHMENT_TIMER_HOUR = *`, `REPLENISHMENT_TIMER_MINUTE = *`, `REPLENISHMENT_TIMER_ACTIVATED = true`, `NEW_CRON_JOB_ACTIVATED = true`, and `REPLENISHMENT_RECALCULATION_CADENCE_SECONDS` **absent** (so the `"0"` default applies) — the same four values as `wsl-wineco-uat` and `c1wh-shipitez-uat`. All three tenants' `REPLENISHMENT_RECALCULATION_LAST_RUN_EPOCH_MS` fall within 700 ms of one instant and are current, so one live sweep covers them and the ~60 s window the D1 decision is costed on holds where it could be read.

*Derivation: `SELECT groupname, syskey, sysvalue FROM los_sysprop WHERE lower(syskey) LIKE '%replenish%' OR lower(groupname) LIKE '%replenish%' OR lower(syskey) LIKE '%cron%'`, run per tenant. Blind spots, stated: (a) the cadence key's absence is inferred from a `LIKE '%replenish%'` sweep that **did** return the sibling `REPLENISHMENT_*` keys, so the instrument is controlled — but absence is still absence, not a read of a default; (b) both ShipItEZ **prd** roles return `permission denied` on `los_sysprop` and `replenishorder`, and both prd MCP endpoints resolve to `current_database() = wh01_hydra_v2`, so "no tenant has pinned the timer" means **three readable tenants, one of them production** — not the fleet.*

**Residual gate on merge:** confirm the two ShipItEZ prd tenants once a read grant exists. A tenant that pinned `REPLENISHMENT_TIMER_HOUR` to a specific hour, or that sits at `NEW_CRON_JOB_ACTIVATED = false` (the master gate for all six cron jobs), would never resolve a defer on the ~60 s basis D1 assumes.

### Proposed, not filed (T3 findings — Nam confirms before any ticket exists)

- **P-1 — `stockunitRepository.findByUnitloadId` has no `ORDER BY`**, so `processTransfer` locks a carrier tree's own moved SUs in unspecified order. Likely a one-line fix (`ORDER BY s.id`, matching `findIdsByUnitloadIdAndItemdataIdOrderById`'s precedent), but it changes the lock order at the move choke point and overlaps `MobileReplenishService`'s ascending scanned set, so it is T3 and needs its own test. **Blast radius:** every `BLOCK_REALIGN` move. **Cost:** ~1 day with an IT. ⚠ **Ranked SECOND, behind P-7 `[A-7′]`** — r2 ranked it first. It is the other half of making the move path's claim true, but it closes no cycle that SBDEV-3637 knowingly leaves open; P-7 does.
- **P-2 — `getStockUnitsByItemDataIdForUpdate` is an unbounded multi-row `FOR UPDATE` ordered by `amount DESC`.** Its own comment flags it (*"⚠ MULTI-ROW LOCK, NO LIMIT… PostgreSQL applies lock_timeout separately to each lock ACQUISITION"*). Reached from `ReleaseOrderJobService`, not from replenish recalc. **Blast radius:** release-order job only. **Cost:** ~½ day to add `, stockUnit.id` to the ORDER BY plus a LIMIT decision — but the ordering change is semantic (it picks *which* stock to release), so it needs product input.
- **P-3 — on `CONTENDED`, try the next candidate** instead of giving up at `findFirst()`. Costs no extra query (the list is already materialised) and would convert most defers into redirects. Changes the candidate-selection contract, so it wants its own test. **Blast radius:** every redirect. **Cost:** ~½ day. Follow-up, explicitly **not** in this PR.
- **P-4 — `findIdsByState` has no `ORDER BY`**, unlike its sibling `findIdsByStateAndItemdataId` (`ORDER BY r.id`, added by SBDEV-3622). Two sweeps may visit orders in different physical orders, so "the loser retries after the winner" is not guaranteed to hold the same way twice. **Blast radius:** sweep determinism only. **Cost:** ~1 hr, T1.
- **P-5 — does SBDEV-2624 (SKU rename in place) re-point bound replen orders?** If not, `replenishorder.itemdata_id` can diverge from `stockunit.itemdata_id`, breaking the same-item premise the candidate-set reasoning rests on. **NOT ESTABLISHED.** Probe: read the rename service for a `replenishorder` update, plus `SELECT count(*) FROM replenishorder r JOIN stockunit s ON r.stockunit_id = s.id WHERE r.state < 700 AND r.itemdata_id <> s.itemdata_id;`. **Cost:** ~30 min to settle; tier depends on the answer.
- **P-7 — `StockunitBusinessService.transferStockToUnitLoad` takes its two Stockunit locks in ROLE order, exactly as this ticket's defect does `[H2]`.** `findByIdForUpdate(sourceStockunitId)` (`:202`) then `findByIdForUpdate(dstSuId)` (`:277`), no id comparison between them, on rows of the same itemdata (`stockunit.getItemdataId().equals(sourceStockunit.getItemdataId())`). **It is a live ABBA counterparty to the ascending edge this fix deliberately leaves waiting**, and the cycle runs through two stock units and nothing else (§4 Fix B). ⚠ **RANKED FIRST `[A-7′]`, and the ranking follows from the argument rather than sitting beside it:** SBDEV-3637 knowingly ships with that cycle live. Always-skip-locking site 2 would close it, the hybrid declines to pay that cost on 253 of 329 edges, and P-7 closes the same cycle at its origin — in the method that owns both ids — at no cost to the recalc path. It is the step that makes the ascending edge's continued waiting defensible. **Blast radius:** every `transferStockToUnitLoad` — the move choke point. **Cost:** ~½ day with a concurrency IT, **and treat that as a floor, because the reordering is NOT ESTABLISHED to be cheap `[NEW-6]`:** a `TreeSet`-style ascending acquisition would have to pick `dstSuId` from the **pre**-lock `List<Stockunit> destinationStockunitList = stockunitRepository.findByUnitloadId(destinationUnitload.getId());`, and the method deliberately discards that read — it re-reads the list after taking the destination unit-load lock, under *"Re-read destination stockunit list after holding the unitload lock (post-lock snapshot)"* and *"Lock destination unitload BEFORE reading its stockunit list to prevent a concurrent same-itemdata insert from bypassing the merge branch below."* Selecting the destination SU from the pre-lock read to id-sort the pair is structurally the same staleness this plan rejects at site 2 (*"Why not pre-query the candidates and lock both ascending"*). Whether the two can be reconciled needs its own trace. **Not folded into this ticket**: different method, different test, and bundling it would make this PR's own lock-topology change harder to review and to revert.
- **P-6 — `StockunitBusinessService.transferStockToUnitLoad` may ALSO form a cycle through `Location`** — after the destination SU lock (`:277`) it takes `locationRepository.findByIdForUpdate(destinationLocationId)` (`:283`), while the unit-load move takes Location before SU. ⚠ **`[L5/NEW-5]` r2 said r1 was *"wrong in both halves"* here. Only ONE half was wrong, and this correction is itself corrected.** r1's acquisition order — `src-SU → src-UL → src-location → dst-UL → dst-SU → dst-location` — is **right**: it is the method's own comment verbatim (*"Stable order: src-stockunit (held above) → src-unitload → src-location → dst-unitload (hoisted before findByUnitloadId) → dst-stockunit → dst-location"*) and the code matches it (`:202`, `:238`, `:243`, `:250`, `:277`, `:283`). r2's replacement *"src-SU → dst-SU → dst-Location"* dropped three real acquisitions and mis-cited `:283` as `:281`. What r1 **did** get wrong is only the second half: framing the SU→SU hazard as needing a `Location` to close it. It does not — the direct SU→SU role-ordered pair is P-7 and needs no `Location` at all, and this `Location` edge is a separate, additional hazard. Out of this lane's scope. **Blast radius:** move × transfer-stock. **Cost:** unknown — needs its own trace.

### Recommended OMC composition

| Aspect | Value |
|---|---|
| Tier | **T3** — lock-topology change at the replenishment choke point; a wrong branch is a silent spurious-defer or a new cycle |
| Pre-draft | done: 3 parallel evidence lanes (tracer / architect / enumeration) |
| Plan review | ralplan round 1 (`architect` + `critic`) → r2 → round 2 re-review (`review-architect-r2.md` SOUND-WITH-CHANGES, `review-critic-r2.md` ITERATE, both read) → **this r3**. Both r2 reviewers converged on one blocker and it is cleared by **deletion**, not by a third justification |
| Implementation | `ralph` in `.claude/worktrees/wms2-api/SBDEV-3637`, off freshly-fetched `origin/develop` |
| Verification | the floor: DB query ✓ · failing test first (IT-1c at `40P01`) · mutation-check every new assertion (§7.5) · one independent review · full suite vs an adjacent baseline. `verifier` lane |
| Code review | `code-reviewer` — **fix every finding including Low** |
| Commit | `git-master`; the step order in §6.2 is the commit order |

---

## 11. Implementation Status — 2026-10-05

**Status:** implemented · **PR:** https://github.com/SiteBossInc/wms2-api/pull/456 (open, into `develop` — NOT merged)
**Branch:** `bugfix/SBDEV-3637-replenish-redirect-lock-order` · **Worktree:** `.claude/worktrees/wms2-api/SBDEV-3637` · **Base:** `origin/develop` `ec42f43a`

| SHA | Subject |
|---|---|
| `29e43eb1` | order the redirect's two stock-unit locks, skip-locked on the descending edge (Fix A–G) |
| `6bd4f32c` | every finding from the code and security review rounds (4 Medium, 4 Low, 1 security Low) |
| `aafe1b05` | correct the null-source safety claim and two sibling copies (F-1/F-2/F-3) |
| `0d3661c8` | the fourth sibling of the retired null-source reason |

**Diffstat:** 12 files, +2092 / −48 — 2 under `src/main`, 9 test, 1 ArchUnit rail.

### Results

| lane | baseline | final |
|---|---|---|
| surefire | 7791 run / **3 F** | **7811 / 0 F** / 1 S |
| failsafe | 624 run / **2 F** | **627 / 0 F** / 31 S |
| IT classes | 121 | **122** |

The baseline's 5 failures were this ticket's own TDD-gate tests, red before the fix for the right reason (`40P01`). Zero pre-existing failures; the three known-flaky ITs passed first try. ⚠ The full suite was measured at `6bd4f32c`; `aafe1b05` and `0d3661c8` change **comments only** (verified by a diff filtered to non-comment lines), and the touched classes were re-run green (117, then 3).

**Mutation — PIT, JDK 21 verified:** 236 mutants; on changed lines **25, 22 KILLED**. Two survivors, both equivalent and both documented: `targetIsBelowHeldSource`'s `ConditionalsBoundary` (M-6b — equal ids return at the SBDEV-3618 Fix E block before the predicate) and `NullReturnVals` on the `if (!skipLocked)` arm. One `NO_COVERAGE` on a changed line is **pre-existing** — that line counts as changed only because `return false` became `return NO_CANDIDATE`. **M-13's guard is now KILLED**, which was the point of the re-pin.

### Review — four independent passes, every finding fixed at every severity

| pass | verdict |
|---|---|
| Conformance (`verifier`) | **PASS**, 0 blockers; re-ran every command itself |
| Code review | 0 High · 4 Medium · 4 Low — all fixed |
| Security | **LOW** risk · 0 Critical/High/Medium · 2 Low — 1 fixed, 1 dispatched |
| Scoped review of the fix commit | 1 Medium · 2 Low — all fixed |
| Claim check | **CLAIM SOUND** + 1 missed sibling — fixed |

**Dispatched, not fixed:** security **S-1** (SU↔SU ABBA still live on the retained waiting edge via `transferStockToUnitLoad`) — pre-existing, not introduced here; it is proposal **P-7**, ranked first.

### Landmines this implementation found that the plan did not predict

1. **Mutant M-13's stated killer could never have worked.** The repository is a Mockito `@Mock`, so `existsById(null)` returns `false` rather than tripping `SimpleJpaRepository`'s `Assert.notNull`; the mutant produced exactly the outcome the row already asserted. The guard was always correct — only its pin was fiction. Re-pinned on `verify(..., never()).existsById(any())`, and **only `move-null-target` can kill it**: on `null-target` the recalc path returns at `if (!skipLocked)` before `existsById` is reachable. *Generalises: a mock cannot reproduce a framework precondition, so "asserting no exception" is blind to any mutant whose effect is an exception the mock never throws.*
2. **The branch-table comment produced a FIFTH successive wrong safety argument** — inside the commit that was fixing the fourth. "No stock-unit lock is held" established only a per-order fact while asserting a transaction-scope one: `recalculateForItem` sweeps an item's orders in **one** transaction via a plain `this.` call and joins an ambient transaction, so an earlier order's lock may still be held. *The recalc rows reason per-order; the move row reasons per-transaction. That asymmetry is now stated.*
3. **A false claim has siblings, and the row-based sweep misses them.** Four copies of the retired reason existed across `src/main`, `src/test` and this plan; three were found by grepping the **claim**, the fourth only by a dedicated claim-check pass. Grep the sentence, never the location.
4. **AC-2's literal was unsatisfiable.** Hibernate renders `PESSIMISTIC_WRITE` on PostgreSQL as `for no key update`, never `for update` — so that token never discriminated the two finders, because it is absent from both. Amended with its evidence ledger; only `skip locked` carries signal.
5. **A `verify` that looks green can mean the IT lane never ran** — a surefire failure aborts the build before failsafe. Always count `Running .*(IT|IntegrationTest|E2ETest)`.

### Not done — deliberately

Merging · setting ClickUp to `on dev` · archiving this plan · deploying. **No Flyway migration, so no tenant DB is affected.** The worktree stays at `.claude/worktrees/wms2-api/SBDEV-3637` for review feedback; `archive-plan` owns its removal after the merge.

**Open at merge:** both ShipItEZ **prd** tenants still return `permission denied` on `los_sysprop` / `replenishorder`, so the ~60 s defer window is verified on `nywh-hydra-prd` plus two UATs, not fleet-wide.
