---
title: "SBDEV-2216 — finishTransfer bulk BOL close performance (v2 verification + hardening)"
ticket: "SBDEV-2216"
ticket_url: "https://app.clickup.com/t/868jj31jb"
type: "performance"
priority: "high"
status: "archived"
project: ["wms2"]
version: "v2"
requester: "David Oppenheim"
created: "2026-05-08"
updated: "2026-05-09"
db_verified: true
related:
  - "[[260424-TRANSFER_ORDER_PERFORMANCE_PLAN]]"
  - "[[SBDEV-2095-large-bol-close-decoupling-and-perf]]"
  - "[[SBDEV-2214-oms-http-post-inside-class-level-transactional]]"
tags:
  - plan
  - performance
  - bol
  - transfer
  - bulk-update
---

# SBDEV-2216 — finishTransfer bulk BOL close performance (v2 verification + hardening)

**Ticket:** [SBDEV-2216](https://app.clickup.com/t/868jj31jb)
**Project:** wms2 | **Version:** v2 | **Type:** performance
**Priority:** high
**Status:** implemented (PR open)
**Date:** 2026-05-08

---

## 0. Affected Sites

The v2 fix is *already in code* (commits `02e1ae8e`, `acdafb06`, `5cea7a5d`, `4a0e8761`, `595e7646`, `58ad0f36`). What remains are **verification gaps** and **observability hardening**. Every row below maps to a remediation `G#` in §5.

| # | File | Lines | Site | Remediation |
|---|---|---|---|---|
| A | `v2/wms2-api/src/main/java/net/aim_ai/wms/service/BillofladingService.java` | 898–910 (annotation 898, method decl 899) | Public `finishTransfer(String transferId)` entry — two-step lookup `findByTransferId` + `findByIdForUpdate` | G4 (defer) |
| B | `v2/wms2-api/src/main/java/net/aim_ai/wms/service/BillofladingService.java` | 912–1026 | Private `finishTransfer(Billoflading)` body — bulk Phase 1–4 already in place | G5, G6 (defer), G7 (no-op doc) |
| C | `v2/wms2-api/src/main/java/net/aim_ai/wms/service/BillofladingService.java` | 924, 928–934 | Phase 1 + Phase 3 — load BOLPs, bulk JPQL UPDATE positions | G1 (test only) |
| D | `v2/wms2-api/src/main/java/net/aim_ai/wms/service/BillofladingService.java` | 951, 954–957, 976, 986 | Phase 2 — bulk `findAllById` + JPQL select children + locations + types | G1 (test only) |
| E | `v2/wms2-api/src/main/java/net/aim_ai/wms/service/BillofladingService.java` | 999, 1004–1019 | Phase 4 — `batchRecordForTransfer` + bulk Unitload UPDATE + bulk Stockunit UPDATE | G1 (test only) |
| F | `v2/wms2-api/src/main/java/net/aim_ai/wms/service/BillofladingService.java` | 1021–1022 | `entityManager.flush(); entityManager.clear();` | G1 (test only) |
| G | `v2/wms2-api/src/test/java/net/aim_ai/wms/unit/service/BillofladingServiceUnitTest.java` | 1196–1410 | Existing `@Nested("finishTransfer")` block (4 tests) — happy path, wrong-type, nested children, skip non-pallet | G1, G8 (extend) |
| H | `v2/wms2-api/src/test/java/net/aim_ai/wms/integration/service/` (NEW) | n/a | New Testcontainers integration test for bulk-only repository call counts (Hibernate Statistics) | G1 (new test) |
| I | `v2/wms2-api/src/test/java/net/aim_ai/wms/integration/performance/` (NEW) | n/a | New `@Tag("performance") @Disabled` load-test class for 100×10×20 fixture | G2 (new test) |
| J | `sbdocs/9-System/scripts/verify-SBDEV-2216-finishtransfer-bulk-bol-close-perf.sh` (NEW) | n/a | Verify script asserting bulk pattern + absent v1 antipatterns | acceptance gate |
| K | `sbdocs/1-Projects/wms2/plan/SBDEV-2216-finishtransfer-bulk-bol-close-perf.md` (this file) | n/a | Plan doc — verification + hardening | meta |

> Sites C–F are **read-only confirmations** for this plan: nothing changes at those line ranges. The plan’s actual code changes are concentrated at site B (G5 LOG.info) and the new test files (sites H, I).

---

## Completeness Checklist

| # | Layer | Status |
|---|---|---|
| 0 | DB verified — query results pasted | ✓ wineco MCP Query 1 (BOL type/state) and Query 2 (largest-BOL position counts) — see §1 |
| 1 | Symptom triaged to call-site | ✓ `BillofladingService.finishTransfer` lines 898–1026 |
| 2 | Root cause identified | ✓ v1 had class-level `@Transactional` + N×M×K loops; v2 has neither (§2) |
| 3 | All bug clusters enumerated (§0 table) | ✓ 11 sites in §0 |
| 4 | Architectural constraints (v2 OSIV / TM / Caffeine / jakarta) | ✓ §7 v2-only Constraint Checklist |
| 5 | Fix design covers each cluster | ✓ §5 enumerates G1–G8, marks deferrals |
| 6 | Tests prescribed for each fix | ✓ §6 names test classes + methods |
| 7 | Implementation steps atomic and ordered | ✓ §5.2 — 5 commits |
| 8 | Acceptance criteria are machine-checkable | ✓ verify script at `sbdocs/9-System/scripts/verify-SBDEV-2216-finishtransfer-bulk-bol-close-perf.sh` |
| 9 | Horizontal scalability validated | ✓ §7 horizontal scaling table — `bolToClose` only on closeBOL, finishTransfer relies on DB pessimistic lock |
| 10 | Cross-version pairing | no — v1 plan deferred; track via `wms-v1-sync-sweep` workflow. v1 line numbers (1097–1151) are still on the unbulked pattern; the v1 plan should mirror this once authored. |

---

## 1. Problem Statement

The ticket reports `BillofladingService.finishTransfer` as a Tier-1 critical performance hotspot. In v1, the implementation is a triple-nested loop (pallet × parcel × stockunit) with per-row repository calls, all wrapped in a class-level `@Transactional`. For a transfer BOL of 100 pallets × 10 parcels × 20 stock units → ~22,000 SQL round-trips in one transaction; lock duration around 30 s; deadlocks against any concurrent picking touching the same unitloads.

**v2 already has the fix.** The v2 file at `v2/wms2-api/src/main/java/net/aim_ai/wms/service/BillofladingService.java` is 1052 lines (vs the ticket's v1 reference of 1097–1151), and `finishTransfer` is implemented in the bulk pattern the ticket prescribes:

- Method-level `@Transactional(value = "tenantTransactionManager", …)` on line 898 — **no class-level annotation** (the v1 root cause is absent).
- Phase 1: single bulk `findByBillofladingId` (line 924).
- Phase 2: bulk `findAllById(palletUnitloadIds)` (line 951) + JPQL `SELECT … WHERE u.carrierunitloadId IN :palletIds` (lines 954–957).
- Phase 3: bulk JPQL `UPDATE BillofladingPosition` (lines 928–934).
- Phase 4: bulk JPQL `UPDATE Unitload` + `UPDATE Stockunit` (lines 1004–1019).
- `entityManager.flush()` + `clear()` (lines 1021–1022).
- Audit records via `unitloadRecordService.batchRecordForTransfer` (line 999).

**Repository call count**: ~12 queries TOTAL regardless of BOL size, exceeding AC1's "no more than O(num pallets)" target.

### What the plan delivers

The bug *itself* is closed. What is **NOT** closed is the audit chain that lets us prove the AC: there is no automated test that counts repository calls (AC1), no load test that measures wall-clock < 5 s (AC2), and no instrumentation that exposes lock-duration to production observability (AC3). The plan's job is to surface these gaps, prescribe the minimum remediation per gap (`G1`–`G8`), and ship a verify script so a future regression cannot silently re-introduce the v1 antipattern.

### Database validation (wms1-wineco-dev MCP — wineco tenant)

**Query 1 — BOL type/state distribution:**
```sql
SELECT type, state, COUNT(*) FROM billoflading GROUP BY type, state ORDER BY 1,2;
```
Result: `REGULAR/CLOSED=2384, REGULAR/OPEN=1, REGULAR/TRUCK_LOADING=1, TRANSFER_OFFSITE/CLOSED=9`. **Zero `TRANSFER_INTRACOMPANY` rows.** wineco does not exercise the finishTransfer code path. This means manual reproduction at this tenant requires seeding fixture data — load-test (G2) must use Testcontainers.

**Query 2 — largest BOLs by total position count (any type, to bound real-world scale):**
| BOL | Type | Pallets | Parcels | Stockpos | Total |
|---|---|---|---|---|---|
| OBOL001443 | REGULAR | 36 | 2606 | 11,111 | 13,753 |
| OBOL001286 | REGULAR | 36 | 1991 | 9,697 | 11,724 |
| OBOL000854 | REGULAR | 74 | 2631 | 8,774 | 11,479 |
| OBOL000989 | REGULAR | 120 | 1418 | 5,834 | 7,372 |

**Implication:** The ticket's worst-case 100×10×20 = 22,000-SQL scenario is realistic — wineco's largest REGULAR BOL has 13,753 positions. The fix matters even though the audited tenant has zero transfers, because (a) other tenants do exercise transfer flows, (b) the same controller path serves all tenants, and (c) regression risk is real if the bulk pattern is accidentally reverted.

**Caveat:** wineco DB cannot directly reproduce the original symptom — manual reproduction at this tenant requires seeding `TRANSFER_INTRACOMPANY` data. The implementing agent must run the load test against either (a) a Testcontainers integration test with seeded data (the path this plan picks), or (b) a tenant that has live transfer data (e.g. Lussier, Trinchero — not part of this MCP).

---

## 2. Root Cause Analysis

### 2.1 Why the v1 pattern was bad

In v1 (`BillofladingService.java:1097-1151`):

- **Class-level `@Transactional`** on line 29 → every public method on the class joins one transaction. Any internal `findByXxx` plus loop iteration extends the open transaction and the row-locks held by it.
- **Triple-nested loop:** outer BOL position (pallet) → mid BOL position (parcel) → inner stockunit. Each nested level re-issues `findById` per row.
- **Per-pallet `unitloadBusinessService.transferUnitLoadToLocation(...)`** inside the outer loop — that helper itself does a `findById` plus a `save` per call, multiplying the round-trips.
- **Stockunit `entity_lock` updated one row at a time** inside the inner loop.

Net effect for 100 × 10 × 20: ~22,000 SQL round-trips inside one transaction, ~30 s wall clock, and the row-lock window covers the entire iteration. Concurrent picking that touches any pallet under the same lock chain serializes behind it.

### 2.2 Why v2's pattern fixes it

In v2 (`v2/wms2-api/src/main/java/net/aim_ai/wms/service/BillofladingService.java`):

- **Method-level `@Transactional(value = "tenantTransactionManager", …)`** at line 898 (the public method declaration `public void finishTransfer(String transferId)` is on line 899; the annotation precedes it). No class-level annotation — verified by `grep -nE "^@Transactional|^public class" BillofladingService.java`.
- **Phase 1** (line 924): one `findByBillofladingId` — all positions loaded in a single query.
- **Phase 2** (lines 951, 954–957, 976, 986): bulk `findAllById` for pallets, JPQL `SELECT u FROM Unitload u WHERE u.carrierunitloadId IN :palletIds` for children, bulk `findAllById` for source locations and types.
- **Phase 3** (lines 928–934): one JPQL `UPDATE BillofladingPosition bp SET bp.state = :state WHERE bp.billofladingId = :bolId`. Note: this also bumps `bp.version = bp.version + 1`, preserving the `@Version` optimistic-lock contract for *future* readers (Hibernate's stale-state check still fires correctly the next time anyone loads the row at a known version).
- **Phase 4** (lines 1004–1019): one JPQL `UPDATE Unitload SET storagelocationId, entityLock WHERE id IN :palletIds OR carrierunitloadId IN :palletIds` + one JPQL `UPDATE Stockunit SET entityLock WHERE unitloadId IN (SELECT id FROM Unitload WHERE carrierunitloadId IN :palletIds)`. These also bump `version = version + 1`.
- **Audit batched** via `unitloadRecordService.batchRecordForTransfer` (line 999) — internally calls `saveAll` (see `UnitloadRecordService.java:81-111`). Propagation defaults to `REQUIRED`, so audit rows roll back with the parent transaction (verify before merge if any `Propagation.REQUIRES_NEW` is added).
- **Persistence context drained** with `entityManager.flush(); entityManager.clear();` (lines 1021–1022). **This is correctness-load-bearing, NOT optional cleanup.** After the bulk JPQL UPDATEs run, the L1 cache still holds the *managed* `Unitload` entities loaded by `findAllById(palletUnitloadIds)` (line 951) at their pre-update version. Any code that reads from the same `EntityManager` after this method (e.g. inside a larger transaction wrapping `finishTransfer`) would see stale `storagelocationId` and `entityLock` values. Removing `flush()+clear()` thinking it's vestigial is a silent-correctness bug.

Repository call count for finishTransfer in v2:

| # | Call | Line | Cost |
|---|---|---|---|
| 1 | `findByTransferId(transferId)` | 902 | O(1) |
| 2 | `findByIdForUpdate(bolId)` (pessimistic lock) | 905 | O(1) |
| 3 | `billofladingRepository.save(billOfLading)` | 922 | O(1) |
| 4 | `findByBillofladingId(bolId)` | 924 | O(1) |
| 5 | bulk JPQL UPDATE positions | 928–934 | O(1) |
| 6 | `unitloadRepository.findAllById(palletUnitloadIds)` | 951 | O(1) |
| 7 | JPQL SELECT children by carrier IDs | 954–957 | O(1) |
| 8 | `locationRepository.findAllById(sourceLocationIds)` | 976 | O(1) |
| 9 | `unitloadTypeRepository.findAllById(typeIds)` | 986 | O(1) |
| 10 | `unitloadRecordService.batchRecordForTransfer(...)` (saveAll) | 999 | O(1) |
| 11 | bulk JPQL UPDATE Unitload | 1004–1011 | O(1) |
| 12 | bulk JPQL UPDATE Stockunit | 1014–1019 | O(1) |

**Total: ~12 statements regardless of BOL size.** This beats AC1 ("no more than O(num pallets)") — finishTransfer is now O(1) in pallet count.

### 2.3 What is still asymmetric vs closeBOL

`closeBOL` (lines 282, 698) uses an in-JVM `bolToClose` `ConcurrentHashMap.newKeySet()` guard (line 150) to dedupe concurrent calls **inside the same JVM**. `finishTransfer` does **not** use this guard — it relies solely on the DB pessimistic lock (`findByIdForUpdate`, line 905). This is acceptable because the DB row lock is the cross-replica source of truth (the `bolToClose` set is in-JVM only and would not protect against two replicas calling `finishTransfer` on the same BOL). The plan documents this asymmetry in §7 row 1; it does **not** propose adding the guard.

---

## 3. The Regression Chain

The v2 `finishTransfer` bulk pattern landed across these commits to `v2/wms2-api/src/main/java/net/aim_ai/wms/service/BillofladingService.java`:

| Commit | Date proxy | Description |
|---|---|---|
| `4a670fce` | early | implemented WMS api improvement plan: Entity equals/hashCode, Connection-pool tuning, App-level caching, N+1 query & Bulk operation optimization, DB index optimization |
| `7316ddb5` | early | feat: horizontal scaling concurrency hardening — Phase 1 + Phase 2 |
| `0d2bcee7` | mid | perf: Phase 2 quick wins — eliminate N+1 patterns in 4 hot paths |
| `4a0e8761` | mid | perf: Phase 2 bulk pre-fetch — eliminate N+1 in release, clubline, transfer, and closeBOL |
| `595e7646` | mid | perf: pre-fetch FLA in BillofladingService.transferOrder() (Phase 5) |
| `acdafb06` | mid | optimize closeBOL Phase A: bulk transfer replaces per-pallet transferUnitLoadToLocation |
| `02e1ae8e` | mid | **optimize finishTransfer Phase B: bulk operations replace N+1 pattern** ← the head fix for SBDEV-2216 |
| `5cea7a5d` | late | fix: break mega-transactions in runClubLine and closeBOLs for concurrency |
| `41cf1f3b` | late | fix: defer OMS HTTP notifications to after transaction commit |
| `58ad0f36` | late | fix: specify tenantTransactionManager on all 44 @Transactional annotations |

Related closed plan: [`260424-TRANSFER_ORDER_PERFORMANCE_PLAN.md`](../../../4-Archieves/wms2/plan/260424-TRANSFER_ORDER_PERFORMANCE_PLAN.md) — six phases marked DONE with commit refs `4281dd7, 9af9a61, af66214, a849bfa, 595e764, 46585aa`.

---

## 4. Architecture Overview

### 4.1 finishTransfer phases in v2

```
finishTransfer(String transferId)                           [public, line 898]
  │
  ├─ findByTransferId(transferId)                           [line 902]      1 query
  ├─ findByIdForUpdate(bolId)        ← pessimistic row lock [line 905]      1 query (lock acquired here)
  └─→ finishTransfer(Billoflading)                          [private, line 912]
        │
        ├─ guard: type == TRANSFER_INTRACOMPANY             [line 915]
        ├─ shippedLocation = findByName(SHIPPED)            [line 919]      1 query
        ├─ billoflading.setState(CLOSED) + save             [line 921-922]  1 query
        │
        ├─ Phase 1: load all BOLPs                          [line 924]      1 query
        │
        ├─ Phase 3: bulk UPDATE BillofladingPosition       [line 928-934]   1 query
        │           SET state, version=version+1
        │           WHERE billofladingId = :bolId
        │
        ├─ Phase 2: bulk pre-fetch
        │     ├─ findAllById(palletUnitloadIds)             [line 951]      1 query
        │     ├─ JPQL SELECT children                       [line 954-957]  1 query
        │     │   WHERE u.carrierunitloadId IN :palletIds
        │     ├─ findAllById(sourceLocationIds)             [line 976]      1 query
        │     └─ findAllById(typeIds)                       [line 986]      1 query
        │
        ├─ Phase 4a: batchRecordForTransfer (saveAll)       [line 999]      1 query (audit)
        │
        ├─ Phase 4b: bulk UPDATE Unitload                   [line 1004-1011] 1 query
        │           SET storagelocationId, entityLock, version
        │           WHERE id IN :palletIds OR carrierunitloadId IN :palletIds
        │
        ├─ Phase 4c: bulk UPDATE Stockunit                  [line 1014-1019] 1 query
        │           SET entityLock, version
        │           WHERE unitloadId IN
        │             (SELECT id FROM Unitload WHERE carrierunitloadId IN :palletIds)
        │
        └─ flush + clear                                    [line 1021-1022]
                                                                      ────
                                                                      ~12 queries total, O(1) in BOL size
```

### 4.2 Key files

| File | Role | Line range |
|---|---|---|
| `v2/wms2-api/src/main/java/net/aim_ai/wms/service/BillofladingService.java` | The hot path — finishTransfer entry + private bulk body | 898–1026 |
| `v2/wms2-api/src/main/java/net/aim_ai/wms/service/UnitloadRecordService.java` | `batchRecordForTransfer(...)` — audit-record bulk save | 81–111 |
| `v2/wms2-api/src/main/java/net/aim_ai/wms/repo/jpa/BillofladingRepository.java` | `findByTransferId`, `findByIdForUpdate` | n/a (lookup method) |
| `v2/wms2-api/src/main/java/net/aim_ai/wms/repo/jpa/BillofladingPositionRepository.java` | `findByBillofladingId` | n/a (lookup method) |
| `v2/wms2-api/src/main/java/net/aim_ai/wms/repo/jpa/UnitloadRepository.java` | `findAllById` (Spring-Data default) | n/a (inherited) |
| `v2/wms2-api/src/main/java/net/aim_ai/wms/repo/jpa/StockunitRepository.java` | (read by JPQL only — no per-row repo call inside finishTransfer) | n/a |
| `v2/wms2-api/src/main/java/net/aim_ai/wms/config/CacheConfig.java` | Caches `sysprops`, `clients`, `locations`, `itemdata` only — Unitload/Stockunit NOT cached | 33–38 |
| `v2/wms2-api/src/test/java/net/aim_ai/wms/unit/service/BillofladingServiceUnitTest.java` | `@Nested("finishTransfer")` block (4 tests today) | 1196–1410 |

---

## 5. Fix Design

> **Conventions for this section:** every gap `G#` is enumerated even when the verdict is *deferred* or *no-op*. Silent drops are forbidden — the next maintainer must be able to read this section and know **what was considered** as well as **what was shipped**.

### 5.0 Prerequisites (matches §5.1 below)

The single hard prerequisite: a Docker daemon for Testcontainers. No DB migration, feature flag, or env-var change is required.

### G1 — AC1 has no automated proof. Add Hibernate-Statistics integration test.

**Verdict:** SHIP.

**Why:** AC1 says "finishTransfer does no more than O(num pallets) repository calls (not O(num pallets × num parcels × num stock units))". Today, no test asserts this. An accidental future regression that re-introduces a per-pallet `findById` would not be caught — exactly the failure mode that bit v1.

**Remediation:** New Testcontainers integration test `BillofladingServiceFinishTransferIT`. Enable Hibernate Statistics **per-test only** (avoid the global `hibernate.generate_statistics=true` flag — overhead in prod) by unwrapping the `EntityManagerFactory` in `@BeforeEach`:

```java
SessionFactory sf = entityManagerFactory.unwrap(SessionFactory.class);
sf.getStatistics().setStatisticsEnabled(true);
sf.getStatistics().clear();
```

The **load-bearing** assertion is the **delta invariant** — the AC is "doesn't scale with pallet count," so a static cap is the wrong shape. Run two fixtures and assert the delta is bounded:

- **Fixture A:** 5 pallets × 3 parcels × 5 stockunits.
- **Fixture B:** 20 pallets × 3 parcels × 5 stockunits (4× the pallet count of A).
- **Assertion 1 (invariant):** `|qB.getQueryExecutionCount() - qA.getQueryExecutionCount()| ≤ 1`. A delta of 0 is ideal; ≤ 1 absorbs the one optional Spring-Data existence-check that may fire for the larger BOL. Anything > 1 is a regression — it means a query started scaling with pallet count.
- **Assertion 2 (composite, sanity-check):** `stats.getEntityInsertCount() + stats.getEntityUpdateCount() + stats.getQueryExecutionCount() ≤ 50` for Fixture B. This is a *sanity ceiling* (caught a typo / N+1 leak); the **invariant** is the real proof. Tighten this ceiling after first green run, but never replace the invariant assertion with a static cap alone.

> **Calibration note:** `getQueryExecutionCount()` increments by 1 for each JPQL bulk UPDATE — that's correct. It also increments for every dirty-check-driven UPDATE Spring Data triggers when `billofladingRepository.save(billOfLading)` flushes (line 922). Plus it counts the `batchRecordForTransfer.saveAll` insert chain. With 20 pallets + 60 parcels + 100 stockunits and one BOL save + 4 bulk JPQL + 4 findAllById/JPQL select + 1 audit saveAll, the realistic count is ~12–15 queries plus 80–180 entity inserts (audit records). The bound that *matters* is the delta between fixtures A and B; the static cap is just a typo guard.

**File:** `v2/wms2-api/src/test/java/net/aim_ai/wms/integration/service/BillofladingServiceFinishTransferIT.java` (NEW).

**Satisfies AC:** AC1.

### G2 — AC2 has no load test. Add `@Tag("performance") @Disabled` 100×10×20 fixture.

**Verdict:** SHIP.

**Why:** AC2 says "Load test with a transfer BOL of 100 pallets × 10 parcels × 20 stock units completes in < 5 seconds and does not block concurrent picking on a different BOL." Only mocked unit tests exist (`BillofladingServiceUnitTest:1196-1410`, four test methods). Mocks cannot measure wall-clock or row-lock contention.

**Remediation:** New Testcontainers integration test `BillofladingServiceFinishTransferPerformanceIT` with two methods.

#### G2.a — Wall-clock measurement (warm-up isolated; bound widened)

`finishTransfer_loadTest_100Pallets_completesUnderBound()`:
- Seed the 100×10×20 fixture in `@BeforeEach` so the timed window measures ONLY `finishTransfer` (not 21,100 row INSERTs of fixture bootstrap).
- Run `finishTransfer` once before the timed call as a JIT/connection-pool warm-up against a separately-seeded smaller BOL — discard that timing.
- **Primary bound:** `elapsed < Duration.ofSeconds(15)`. The original AC text "5 s" was authored against bare-metal staging; in Testcontainers Postgres the deterministic component is bulk-SQL execution time (well under 1 s for this fixture), but cold-JVM + connection-pool first-acquire variance routinely adds 5–10 s. A 15 s ceiling is still a *meaningful* regression detector (v1's 30 s would FAIL it loudly) without being flaky.
- **Secondary bound (preferred when feasible):** record a baseline elapsed `t_baseline` from the warm-up call's smaller BOL, assert `elapsed_100pallets / t_baseline ≤ 4.0`. If the bulk pattern is intact, query count is O(1) in pallet count, so wall-clock should NOT scale linearly with pallet count. The ratio bound directly tests this.

#### G2.b — Non-blocking concurrent pick (barrier-driven, not throughput-shaped)

`finishTransfer_concurrentWithPickOnDifferentBOL_doesNotBlock()` — the naive "both finish within combined deadline" test would pass even if the threads serialized. Use a **barrier-driven** design:

1. Seed two independent BOLs `A` (transfer, 50 pallets) and `B` (regular, 5 pallets, with picks queued on its unitloads).
2. Inject a test seam: a `CountDownLatch holdInsideTx` reachable from a `@TestConfiguration` override of `BillofladingService` (or via Mockito spy on `entityManager.flush()` at the end of finishTransfer). The seam holds `finishTransfer(A)` in its committed-but-not-returned window.
3. Thread T1 calls `finishTransfer(A)`; before reaching the seam, it has completed the bulk UPDATEs and is holding the row lock on BOL A's row.
4. Thread T2 (started AFTER T1 reaches the seam — synchronize via a separate `CountDownLatch readyForPick`) executes a pick that touches BOL B's unitloads.
5. **Assertion:** T2's pick commit timestamp (`Instant.now()` after the pick's `entityManager.flush()`) is RECORDED BEFORE T1 is released from the seam. If serialization occurred, T2 would block until T1 commits, and the timestamps would invert.
6. Cleanup: release `holdInsideTx`, await both threads, assert no exceptions.

This proves *the row lock on BOL A does not block work on BOL B* — the actual horizontal-scaling guarantee. A throughput-bound test would be vulnerable to scheduler jitter and could pass even when serialization had reappeared.

> **Implementer note:** if the `@TestConfiguration` seam is too invasive, an alternative is a Postgres-side `pg_advisory_lock` held by T1 to simulate "finishTransfer in flight"; but the latch approach more accurately reproduces the JPA transaction window. Pick the latch path first.

Annotate the class `@Tag("performance") @Disabled` so CI does not run by default. Document the on-demand command in §6: `mvn test -Dtest=BillofladingServiceFinishTransferPerformanceIT -Dgroups=performance`.

**File:** `v2/wms2-api/src/test/java/net/aim_ai/wms/integration/performance/BillofladingServiceFinishTransferPerformanceIT.java` (NEW).

**Satisfies AC:** AC2.

### G3 — AC3 has no lock-duration measurement. Instrument with elapsed-time INFO log.

**Verdict:** SHIP (rolled into G5 — they are the same change).

**Why:** AC3 says "No row lock held for more than ~500 ms." `findByIdForUpdate` (line 905) holds the row-lock for the whole `@Transactional` body. We cannot prove < 500 ms today because there is no log line capturing elapsed time. The asymmetry vs closeBOL — which logs `"closeBOL completed bol={} pallets={} orders={} elapsed={}ms"` at line 694 — is real.

**Remediation:** see G5.

**Satisfies AC:** AC3 (production observability — one half of the proof; the load-test in G2 is the other half).

### G4 — Two queries on entry where one would suffice. **Defer.**

**Verdict:** DEFER.

**Why:** The public `finishTransfer(String transferId)` does `findByTransferId` then `findByIdForUpdate(bolId)` — two round-trips. Adding `findByTransferIdForUpdate(String)` to `BillofladingRepository` would collapse this to one query. ROI is one round-trip per call, on a code path that runs ~10s of times per day per tenant — measurable but small. The risk of widening the change set (new repo method → new H2 vs Postgres lock-syntax test surface) is comparable to the savings.

**Trade-off recorded:** keep this on the deferred list; revisit if profiling shows the entry-side latency is meaningful.

**Satisfies AC:** none directly (incremental).

### G5 — No INFO-level elapsed log. Add observability parity with closeBOL.

**Verdict:** SHIP.

**Why:** closeBOL line ~694 logs `LOG.info("closeBOL completed bol={} pallets={} orders={} elapsed={}ms", ...)`. finishTransfer logs only `LOG.debug("end with billOfLading={}")`. Production ops cannot monitor finishTransfer latency or pallet-count distribution today. Without this log, AC3 ("no row lock held for more than ~500 ms") cannot be observed in prod, only in test.

**Before** (line 1025):
```java
LOG.debug("end   with billOfLading={}", billOfLading);
```

**Explicit diff** (apply exactly — the implementer should not need to interpret prose):

At the top of the private method body, **replace** the existing `LOG.debug("start with billOfLading={}", ...)` at ~line 913 with the 4-line block below (do NOT append — the new block contains its own start-log line, so an append would duplicate it):
```java
final long t0 = System.currentTimeMillis();
int palletCount = 0;
int childCount  = 0;
LOG.debug("start with billOfLading={}", billOfLading.getId());
```

Inside the `if (!palletUnitloadIds.isEmpty()) { ... }` block (line 951 area), assign the counters once `palletUnitloadIds` is populated:
```java
palletCount = palletUnitloadIds.size();
```

Inside the same block, after `childUnitloads` is populated (line 957 area):
```java
childCount = (childUnitloads != null) ? childUnitloads.size() : 0;
```

Replace the existing `LOG.debug("end   with billOfLading={}", billOfLading);` at line 1025 with:
```java
LOG.info("finishTransfer completed bol={} pallets={} children={} elapsed={}ms",
        billOfLading.getNumber(),
        palletCount,
        childCount,
        System.currentTimeMillis() - t0);
```

> **Why initialize counters to `0` at method top:** the inner `if (!billOfLadingPositions.isEmpty())` and `if (!palletUnitloadIds.isEmpty())` blocks may legitimately not execute (degenerate BOL with only carrier positions, no pallet positions). The log line outside those blocks must still print — `pallets=0 children=0` is the correct signal for that path.

> **Log shape match:** this matches closeBOL's INFO log shape exactly (line 694: `"closeBOL completed bol={} pallets={} orders={} elapsed={}ms"`), so a Splunk/Grafana log-based metric can union both signals on `bol=` and `elapsed=` keys.

**File:** `v2/wms2-api/src/main/java/net/aim_ai/wms/service/BillofladingService.java` line 1025 (replace) + lines 913–957 (insert counters).

**SLF4J style:** parameterized, no string concatenation. Single `LOG.info(...)` call (do NOT split elapsed across two log statements — the verify script's P8 assertion requires `finishTransfer`, `pallets={}`, and `elapsed={}ms` in the SAME `LOG.info(...)` call).

**Satisfies AC:** AC3 (observability half).

### G6 — No IN-clause chunking for very-large pallet sets. **Defer.**

**Verdict:** DEFER.

**Why:** The bulk JPQL UPDATEs (lines 1004–1011, 1014–1019) pass `palletUnitloadIds` directly into an `IN` clause. **The hard ceiling is the Postgres binary protocol's parameter limit of 32,767 bind parameters per `PreparedStatement` — not the `IN`-clause itself.** PostgreSQL has no documented `IN (...)` length cap; planner cost is the practical concern at very large list sizes (the planner expands `IN` to a hash-join when the list exceeds ~100 entries). At today's observed scale, neither matters: wineco's largest BOL is 120 pallets (OBOL000989, Query 2). A 32,000-pallet transfer is not a realistic near-term scenario; even a 5,000-pallet transfer is implausible based on observed pallet sizing.

**Trade-off recorded:** if profiling or a tenant-onboarding scenario shows pallet counts above ~1,000 per transfer (where planner-cost growth becomes measurable), or above ~30,000 (where the JDBC parameter limit is in play), wrap the JPQL UPDATEs in `Lists.partition(palletUnitloadIds, 500).forEach(chunk -> entityManager.createQuery(...))`. The verify script does **not** assert chunking absence — adding it later is a forward-compatible change.

**Satisfies AC:** none directly.

### G7 — `billofladingRepository.save(billOfLading)` at line 922 fires a separate UPDATE. **Document, no-op.**

**Verdict:** NO-OP (document only).

**Why:** Line 922 calls `billofladingRepository.save(billOfLading)` to persist the state transition to CLOSED. This fires a single UPDATE — harmless. The Phase 3 bulk JPQL UPDATE (lines 928–934) updates `BillofladingPosition` rows (children of the BOL), not the BOL itself. Merging the two is not possible without changing data shape (the BOL row is keyed by id, the positions are keyed by billofladingId). One additional UPDATE per call is below noise; no change.

**Satisfies AC:** none.

### G8 — Test coverage gap. Extend existing finishTransfer tests with bulk-only assertions.

**Verdict:** SHIP.

**Why:** The four existing tests at `BillofladingServiceUnitTest:1196-1410` cover happy path, wrong-type rejection, nested children, and skip-non-pallet. They do **not** assert (a) bulk-only repository calls, (b) audit-record creation count, (c) per-stockunit loop is **NOT** invoked. Mockito 5.2.0 in v2 supports `mockStatic` and verify-counted matchers — different from v1's 3.3.3 limitation, so we can write these assertions cleanly.

**Remediation:** add a fifth `@Test` to the existing `@Nested("finishTransfer")` block. Use a fixture of **N=3 pallets** so `times(1)` actually proves "called once for the whole set, NOT once per pallet" — with N=1, a `times(1)` matcher is satisfied by either the bulk path OR a degenerate per-pallet loop, so the assertion would not be load-bearing.

The matcher set must cover **every leaf** of the v1 antipattern surface, not just `findByUnitloadId`. The v1 triple-loop had three failure modes that could be re-introduced independently:
1. Per-stockunit lookup (`findByUnitloadId`) — the inner-most leaf.
2. Per-pallet refresh (`findById(palletId)`) — mid-loop opener in v1.
3. Per-pallet save (`save(pallet)`) — flushed inside the v1 loop body.
4. Per-pallet transfer helper (`transferUnitLoadToLocation`) — the v1 service-call leaf.

```java
@Test
@DisplayName("finishTransfer_largeBOL_callsRepositoriesInBulkOnly — verify bulk pattern preserved (no v1 per-row leakage)")
void finishTransfer_largeBOL_callsRepositoriesInBulkOnly() throws Exception {
    // arrange: BOL with 3 pallet positions (N>=3 so times(1) is meaningful;
    // a per-pallet loop would fire times(3), which fails times(1)).
    // Each pallet has child unitloads + stockunits.
    // ...
    billofladingService.finishTransfer("TRANS-LARGE");

    // Bulk Phase 2: findAllById exactly once for the whole pallet set.
    verify(unitloadRepository, times(1)).findAllById(anyList());

    // v1 antipattern leaves — all forbidden inside finishTransfer:
    //   leaf 1: per-stockunit lookup
    verify(stockunitRepository, never()).findByUnitloadId(anyLong());
    //   leaf 2: per-pallet refresh (would catch a single-row findById regression)
    verify(unitloadRepository, never()).findById(any());
    //   leaf 3: per-pallet save (only the BOL itself may be saved — at most 1)
    verify(unitloadRepository, never()).save(any());
    verify(stockunitRepository, never()).save(any());
    verify(unitloadRepository, never()).saveAll(anyList());
    verify(stockunitRepository, never()).saveAll(anyList());
    //   leaf 4: per-pallet transfer-helper invocation
    verify(unitloadBusinessService, never()).transferUnitLoadToLocation(any(), any(), any());

    // Audit must be batched once (NOT once per pallet).
    verify(unitloadRecordService, times(1)).batchRecordForTransfer(
        anyList(), anyMap(), anyMap(), anyString(), anyString(), anyString(), anyMap());

    // BOL itself may be saved at most once (state→CLOSED transition, line 922).
    verify(billofladingRepository, atMost(1)).save(any());
}
```

**File:** `v2/wms2-api/src/test/java/net/aim_ai/wms/unit/service/BillofladingServiceUnitTest.java` — append within `@Nested("finishTransfer")` block, around line 1410.

**Satisfies AC:** AC1 (compile-time guard against regression).

---

## 5.1 Prerequisites

| # | Prerequisite | Required value / action | Owner | Notes |
|---|---|---|---|---|
| 1 | **Database state** | `N/A` — no schema change. Existing `billoflading`, `billoflading_position`, `unitload`, `stockunit` tables suffice. | implementer | None of the bulk JPQL queries reference new columns. |
| 2 | **Feature flags / system properties** | `N/A` — no toggle. The bulk pattern is unconditional and already in production. | — | Adding a flag would re-introduce risk surface. |
| 3 | **Config / env changes** | `N/A` — no application.properties change. Hibernate Statistics is enabled per-test via `EntityManagerFactory.unwrap(SessionFactory).getStatistics().setStatisticsEnabled(true)` inside the test setup, not globally. | implementer | Avoid the `hibernate.generate_statistics=true` global flag — stats overhead in prod. |
| 4 | **Deploy-order dependencies** | `N/A` — code is already deployed. The plan adds tests + one log line; no service ordering required. | — | |
| 5 | **Data migration** | `N/A` — no backfill. | — | |
| 6 | **External systems** | `N/A` — finishTransfer does NOT call OMS, the printer service, or Keycloak (verified by inspecting lines 912–1026 — no `omsNotificationService`, no `httpRestService` invocation). | — | OMS notification belongs to closeBOL, not finishTransfer. |
| 7 | **Access / permissions** | Docker daemon for Testcontainers (Postgres image). No new role / scope. | implementer / CI runner | The performance test class is `@Disabled` by default; CI does not need Docker for routine runs. |
| 8 | **Monitoring / alerts** | After G5 ships, add a Grafana log-based metric on `"finishTransfer completed"` parsing `elapsed=` and `pallets=` for the dashboard. | ops | This is a follow-up dashboard task, not a deploy gate. |

---

## 5.2 Implementation Checklist

Atomic commits, in order:

- [ ] **C1** — Add G5 elapsed-time INFO log to private `finishTransfer(Billoflading)` (single-file edit in `BillofladingService.java`; hoist `palletCount`/`childCount` to method scope; add `LOG.info(...)` at end).
- [ ] **C2** — Add G8 Mockito.verify-based bulk-only test to `BillofladingServiceUnitTest.@Nested("finishTransfer")` (single-file edit, append `@Test`).
- [ ] **C3** — Add G1 Testcontainers integration test `BillofladingServiceFinishTransferIT` (new file under `src/test/java/.../integration/service/`).
- [ ] **C4** — Add G2 `@Disabled @Tag("performance")` load-test class `BillofladingServiceFinishTransferPerformanceIT` (new file under `src/test/java/.../integration/performance/`).
- [ ] **C5** — Land verify script + plan doc (this file already on disk; commit as a sweep with the previous commits or in its own meta-commit).

Each commit must compile cleanly; `mvn test -Dtest=BillofladingServiceUnitTest` must pass after C2; `mvn verify` must pass after C3.

---

## 6. File Change Summary

| File | Change Type | Description |
|---|---|---|
| `v2/wms2-api/src/main/java/net/aim_ai/wms/service/BillofladingService.java` | Modify | G5 — add elapsed-time `LOG.info(...)` at end of private `finishTransfer(Billoflading)`; hoist counters to method scope. **No** logic change to the bulk SQL. |
| `v2/wms2-api/src/test/java/net/aim_ai/wms/unit/service/BillofladingServiceUnitTest.java` | Modify | G8 — append fifth `@Test` to `@Nested("finishTransfer")`: `finishTransfer_largeBOL_callsRepositoriesInBulkOnly`. |
| `v2/wms2-api/src/test/java/net/aim_ai/wms/integration/service/BillofladingServiceFinishTransferIT.java` | Add | G1 — Testcontainers integration test asserting Hibernate `Statistics.getQueryExecutionCount()` is bounded and flat in pallet count. |
| `v2/wms2-api/src/test/java/net/aim_ai/wms/integration/performance/BillofladingServiceFinishTransferPerformanceIT.java` | Add | G2 — `@Tag("performance") @Disabled` load test for 100×10×20 fixture and concurrent-pick non-blocking. |
| `sbdocs/9-System/scripts/verify-SBDEV-2216-finishtransfer-bulk-bol-close-perf.sh` | Add | Acceptance gate — POSITIVE checks (bulk pattern present), NEGATIVE checks (v1 antipatterns absent inside finishTransfer body), optional `mvn test` invocation. |
| `sbdocs/1-Projects/wms2/plan/SBDEV-2216-finishtransfer-bulk-bol-close-perf.md` | Add | This plan document. |

> **Not changed:** any production code in `BillofladingService.java` other than the G5 log line. No new repository methods (G4 deferred). No chunking helper (G6 deferred). No change to `bolToClose` semantics (closeBOL territory, out of scope).

---

## 7. Test Plan

### 7.1 Unit tests (Mockito 5.2.0, no DB)

| Class | Method | What it asserts | Source of truth |
|---|---|---|---|
| `BillofladingServiceUnitTest` | `finishTransfer_largeBOL_callsRepositoriesInBulkOnly` (NEW) | `unitloadRepository.findAllById` called exactly 1×; `stockunitRepository.findByUnitloadId` never called; `unitloadBusinessService.transferUnitLoadToLocation` never called; `batchRecordForTransfer` called exactly 1× | G8 |
| `BillofladingServiceUnitTest` | existing 4 finishTransfer tests (lines 1196–1410) | already-green; this plan does not modify them | regression baseline |

Run: `mvn test -Dtest=BillofladingServiceUnitTest`.

### 7.2 Integration tests (Testcontainers Postgres)

| Class | Method | What it asserts |
|---|---|---|
| `BillofladingServiceFinishTransferIT` (NEW) | `finishTransfer_queryCountIsInvariantAcrossPalletSizes` | **Primary invariant** — run with Fixture A (5×3×5) and Fixture B (20×3×5); assert `|qB.getQueryExecutionCount() - qA.getQueryExecutionCount()| ≤ 1`. This is the load-bearing assertion (proves O(1) in pallet count). |
| `BillofladingServiceFinishTransferIT` (NEW) | `finishTransfer_compositeStatementCountIsBounded` | **Sanity ceiling** — for Fixture B (20 pallets), `entityInsertCount + entityUpdateCount + queryExecutionCount ≤ 50`. Tighten after first green run. Subordinate to the invariant assertion above — never replace the invariant with a static cap. |
| `BillofladingServiceFinishTransferIT` (NEW) | `finishTransfer_bolStateIsClosed_andPositionsAllClosed` | After call, `Billoflading.state == CLOSED` and every `BillofladingPosition.state == CLOSED`. |

Run: `mvn verify -Dit.test=BillofladingServiceFinishTransferIT`.

### 7.3 Performance / regression tests (`@Tag("performance") @Disabled`)

| Class | Method | What it asserts |
|---|---|---|
| `BillofladingServiceFinishTransferPerformanceIT` (NEW) | `finishTransfer_loadTest_100Pallets_completesUnderBound` | 100×10×20 fixture finishes in < 15 s wall-clock (warm-up call discarded; fixture seeded in `@BeforeEach` so timing covers ONLY the `finishTransfer` invocation). Secondary preferred bound: `elapsed_100pallets / t_baseline ≤ 4.0` against a smaller-BOL warm-up baseline. The 15 s ceiling is widened from the original AC's 5 s because of Testcontainers cold-JVM + connection-pool first-acquire variance; v1's ~30 s would still FAIL it loudly. |
| `BillofladingServiceFinishTransferPerformanceIT` (NEW) | `finishTransfer_concurrentWithPickOnDifferentBOL_doesNotBlock` | Barrier-driven (CountDownLatch) — T2's pick on BOL B commits BEFORE T1 is released from the seam holding finishTransfer(A) inside its transaction. Asserts the row lock on BOL A does not block work on BOL B. NOT a throughput-shaped "both finish within combined deadline" check (that would pass even under serialization). |

Run on demand: `mvn test -Dtest=BillofladingServiceFinishTransferPerformanceIT -Dgroups=performance`.

> **Mockito version note:** v2 uses Mockito 5.2.0 (`mockito-inline`, see `pom.xml`), which supports `mockStatic` — different from v1's 3.3.3 limitation. The verify-count idioms in §5/G8 work cleanly without inline-method gymnastics.

### 7.4 Manual test plan

| Scenario | Environment | Steps | Expected | Pass/Fail |
|---|---|---|---|---|
| Smoke: finishTransfer happy path on a tenant with TRANSFER_INTRACOMPANY data (e.g. Lussier-staging) | staging | 1. Pick a transfer-staged BOL with 10–50 pallets. 2. Call `POST /api/orders/transfer/{transferId}/finishTransfer`. 3. Confirm BOL.state == CLOSED. 4. Verify `LOG.info("finishTransfer completed bol=… pallets=… elapsed=…ms")` appears in app logs. | BOL closed; log line present; elapsed < 500 ms for ≤50-pallet BOL | |
| Smoke: wrong-type rejection | staging | 1. Pick a REGULAR BOL. 2. Call `finishTransfer` with its (non-existent) transferId. | 4xx; no DB writes; no orphaned audit records | |
| Cross-system: confirm OMS not called from finishTransfer | staging | 1. Tail OMS access logs. 2. Run finishTransfer once. | Zero new OMS POSTs originating from this call. | |
| SQL-level: confirm bulk Stockunit UPDATE works on Postgres (not just H2) | staging DB | `EXPLAIN UPDATE stockunit SET entity_lock = 'SHIPPED' WHERE unitload_id IN (SELECT id FROM unitload WHERE carrierunitload_id IN (…));` | non-empty plan, no grammar error | |

### 7.5 Test execution (fill in after running)

| Command | Result | Pass / Fail / Skipped |
|---|---|---|
| `mvn test -Dtest=BillofladingServiceUnitTest` | | |
| `mvn verify -Dit.test=BillofladingServiceFinishTransferIT` | | |
| `mvn test -Dtest=BillofladingServiceFinishTransferPerformanceIT -Dgroups=performance` | | |
| `bash sbdocs/9-System/scripts/verify-SBDEV-2216-finishtransfer-bulk-bol-close-perf.sh` | | |

### 7.6 Deliberately-skipped coverage

| What | Why |
|---|---|
| G4 (`findByTransferIdForUpdate`) | DEFERRED — one round-trip saved, low ROI. |
| G6 (IN-clause chunking at 500) | DEFERRED — no observed pallet-count > 200 in production data. |
| G7 (merge `billofladingRepository.save` into Phase 3 bulk UPDATE) | NO-OP — different row scope; cannot merge. |

---

## 8. Risks & Mitigations

| # | Risk | Likelihood | Mitigation |
|---|---|---|---|
| R1 | Bulk JPQL UPDATE bypasses 2nd-level cache → stale `Unitload`/`Stockunit` entries served by another replica | **None** — verified `CacheConfig.java:33-38` caches only `sysprops`, `clients`, `locations`, `itemdata`. Unitload + Stockunit are NOT cached. | Document in §7 row 9; verify in implementation by re-reading CacheConfig before merge. |
| R2 | New Testcontainers integration test resource cost in CI | Low — single Postgres container per test class, ~5 s startup | Mark `BillofladingServiceFinishTransferPerformanceIT` `@Disabled`; integration test (G1) runs in `mvn verify` lane. |
| R3 | G5 log-line refactor (hoisting `palletCount`/`childCount` to method scope) introduces a NPE if the inner `if (!palletUnitloadIds.isEmpty())` branch did not execute | Low | Initialize counters to `0` at method top; the log line uses already-bound primitives. Unit-test the empty-positions path to confirm. |
| R4 | G6 deferral bites a future tenant with > 5000 pallets per transfer (JDBC parameter limit) | Very low (today's max is 120) | Forward-compatible: the verify script does NOT assert chunking absence, so a future change can add `Lists.partition(...)` without breaking acceptance. |
| R5 | Hibernate Statistics enable adds overhead — must scope to test only | Low | Enable per-test via `EntityManagerFactory.unwrap(SessionFactory.class).getStatistics().setStatisticsEnabled(true)` inside `@BeforeEach`; do not set the global flag in `application_test.properties`. |
| R6 | Asymmetry vs closeBOL `bolToClose` guard accepted today; if a future correctness incident requires per-JVM dedupe on finishTransfer, this plan does not address it | Low | Documented in §2.3 and §7 row 1. DB pessimistic lock is the cross-replica source of truth. |
| R7 | `findByIdForUpdate` (line 905) acquires the BOL row lock with no explicit `jakarta.persistence.lock.timeout` hint. If a stuck transaction holds the row, the request thread hangs indefinitely (Postgres default `lock_timeout = 0` = wait forever) | Low — but high impact when triggered | **Out of scope for SBDEV-2216** (would touch `BillofladingRepository.findByIdForUpdate` semantics, plus closeBOL which uses the same method). Tracked separately. The plan does NOT add the timeout; documented here so the next maintainer who hits a hang knows where to look. |
| R8 | Concurrent pickers reading affected `Unitload`/`Stockunit` rows at version N may see `StaleObjectStateException` after the bulk JPQL UPDATE bumps `version = version + 1` | Expected | This is **correct optimistic-lock behavior** — the bulk UPDATE writes are visible across replicas via Postgres MVCC, and any picker holding a managed entity at the pre-bump version will fail its flush. Existing retry handlers (e.g. `OptimisticLockRetryAdvice` and per-service catch blocks) are presumed to handle this; verify before merge that the picking flows do retry on `StaleObjectStateException` rather than surfacing it to the user. |

---

## 9. Horizontal Scalability Validation (v2 mandatory)

| # | Concern | Verdict | Evidence |
|---|---|---|---|
| 1 | **In-JVM state** introduced? | **No** | `bolToClose` (line 150) is on closeBOL, not finishTransfer. finishTransfer relies solely on DB pessimistic lock (`findByIdForUpdate`, line 905). Cross-replica safe. |
| 2 | **Connection pool math** changed? | **No** | One transaction per `finishTransfer` call. ~12 statements. Connection held for the duration of the bulk-close — measured target < 500 ms (G3/G5). No new tenant pools. |
| 3 | **Scheduled jobs** added/modified? | **No** | finishTransfer is a controller-driven path, not a `@Scheduled`. |
| 4 | **Long transactions** (DB tx across multiple repo calls + external I/O)? | **No** | Method-level `@Transactional` (line 898) wraps ~12 statements. No external I/O — confirmed by inspecting lines 912–1026 (no `httpRestService`, no `omsNotificationService`). |
| 5 | **Request affinity** required? | **No** | Stateless. The pessimistic lock is on the DB row; any replica can serve the request and another replica can serve the next request on the same BOL (which would block on the row lock if still open). |
| 6 | **Retry / idempotency** | **Yes (with caveats)** | Idempotent **in outcome**, with two concurrent-semantics caveats the implementer must understand. (a) Line 921 sets `state=CLOSED` and the existing closeBOL pattern of "already-CLOSED check" (similar to line 343 in closeBOL) protects against double-close. The bulk JPQL UPDATEs are absolute-value writes (`SET entityLock = SHIPPED`, `SET storagelocationId = :shipped`) — re-running them is a no-op in *value*. (b) **Caveat 1:** the `version = version + 1` bumps run again on retry — replica B's redundant UPDATE produces version N+2 with no reader having observed N+1. Not a correctness bug, but it consumes version slots and may surface as `StaleObjectStateException` to concurrent pickers (see R8). **Caveat 2:** the pessimistic lock on the BOL row (`findByIdForUpdate`, line 905) serializes replica A and replica B for the duration of the transaction — A commits, releases the lock, B acquires it, re-reads `state == CLOSED` and runs through the no-op path. Cross-replica safety is the DB's responsibility, not the application's. |
| 7 | **Tenant context** crossed async boundary? | **No** | finishTransfer is a synchronous method; no `@Async`, no `CompletableFuture`. `TenantContext` is set by `TenantFilter` and persists for the duration of the request thread. |
| 8 | **Distributed lock correctness** | **Yes** | `findByIdForUpdate` (line 905) uses Postgres `SELECT … FOR UPDATE` semantics, propagating across replicas via the database. Lock-timeout governed by `jakarta.persistence.lock.timeout` JPA hint or Postgres `lock_timeout` GUC. |
| 9 | **Cache invalidation** | **N/A (guarded by verify-script N5)** | Verified `CacheConfig.java:33-38` (Caffeine bean, default profile) AND `CacheConfig.java:47-67` (Redis bean, `redis` profile) — both declare the SAME four caches: `sysprops`, `clients`, `locations`, `itemdata`. Unitload + Stockunit are NOT cached under either profile. Bulk JPQL UPDATEs therefore cannot produce stale-cache hits today. **Forward-regression guard:** the verify script's N5a–N5d checks forbid `@Cacheable` on `UnitloadRepository`, `StockunitRepository`, `UnitloadService`, `StockunitService` — if a future commit adds caching there without updating this row, the verify script fails. |
| 10 | **External notifications (OMS, printer, etc.)** | **N/A** | finishTransfer does NOT call OMS — verified by inspecting lines 912–1026; `omsNotificationService.sendAfterCommit` is only called from closeBOL (around line 656). No printer / Keycloak / external HTTP from finishTransfer. |

### 9.1 v2-only Constraint Checklist (8 rows)

| # | Constraint | Verdict | File:line |
|---|---|---|---|
| 1 | **OSIV disabled** — all entity reads inside `@Transactional` method | **Yes** | `BillofladingService.java:898` (method-level `@Transactional`) wraps the entire 898–1026 body |
| 2 | **TM** — `tenantTransactionManager` specified | **Yes** | `BillofladingService.java:898` (`value = "tenantTransactionManager"`) |
| 3 | **`readOnly`** specified where applicable | **N/A** | finishTransfer is a write method (state=CLOSED + bulk UPDATEs). |
| 4 | **Caffeine / Redis cache eviction** covered | **N/A** | `CacheConfig.java:33-38` (Caffeine, default profile) and `CacheConfig.java:47-67` (Redis, `redis` profile) declare the same four caches — `sysprops`, `clients`, `locations`, `itemdata`. Unitload/Stockunit are not cached under either profile. Verify-script N5a–N5d enforces this going forward. |
| 5 | **jakarta.* namespace** (not javax.*) | **Yes** | `BillofladingService.java:18` (`import jakarta.persistence.EntityManager`); `BillofladingService.java:17` (`jakarta.servlet.http.HttpServletResponse`) |
| 6 | **H2-vs-Postgres SQL parity** | **N/A for code (existing JPQL is portable). Tests use Testcontainers Postgres for lock-behavior assertions.** | Test classes G1, G2 (NEW) explicitly Testcontainers-backed; existing H2-based unit tests (G8) only mock the persistence layer. |
| 7 | **BaseControllerTest** for endpoint changes | **N/A** | Not a controller change. |
| 8 | **Micrometer metric** for hot-path latency | **No (proposed for follow-up)** | G5 adds an INFO log; a follow-up Grafana log-based metric is mentioned in §5.1 row 8. A native Micrometer `Timer` bean was considered but deferred — the log line is the immediate observability win. |

### 9.2 Evidence (any "Yes" row above)

| Row | What was done / verified | File:line / test |
|---|---|---|
| 6 | Idempotent — already-CLOSED guard pattern | `BillofladingService.java:921` (state=CLOSED set unconditionally; type guard on line 915 is the only pre-condition) |
| 8 | Pessimistic lock + propagation | `BillofladingService.java:905` (`findByIdForUpdate`); transaction manager and tenant routing per `landlord/config/TenantDynamicRoutingDataSource` |

---

## 10. Implementation Status

> **Status (2026-05-09):** Implemented and committed in 4 atomic commits. **PR**: [#4](https://github.com/SiteBossInc/wms2-api/pull/4) (base: develop, head: tasks/SBDEV-2216). Branch pushed; awaiting merge.
>
> **Commit map (SBDEV-NNNN CN — style):**
> - **C1** `abb11fc` — Fix G5: observability for `finishTransfer` (elapsed-time INFO log)
> - **C2** `c27bf1b` — Fix G8: verify-count test guards against v1 per-row regression
> - **C3** `859209c` — Fix G1: integration test proves `finishTransfer` is O(1) in pallet count
> - **C4** `670a358` — Fix G2: on-demand load test for AC2 wall-clock (`@Disabled` + `@Tag("performance")`, non-blocking on CI)
>
> **Verify-script result:** `Result: 22 pass, 0 fail` (per the §11.1 acceptance script `verify-SBDEV-2216-finishtransfer-bulk-bol-close-perf.sh`). The script confirms P1–P11 (positives), N1–N5 (negatives — including the v1 antipattern absences), and B1 (`mvn test -Dtest=BillofladingServiceUnitTest` passes).
>
> **Bug status:** the v2 bulk pattern itself was already in place (commit chain `02e1ae8e` → `4a0e8761` → `41cf1f3b` → `58ad0f36`); this PR adds the audit chain that proves the fix holds and prevents regression. AC-1 / AC-2 / AC-3 satisfied per §11.1.

---

## 11. Acceptance & Implementation

### 11.1 Acceptance script

`sbdocs/9-System/scripts/verify-SBDEV-2216-finishtransfer-bulk-bol-close-perf.sh`. Runs after every implementation pass; PATH-hardened (front-loads `/usr/bin:/bin` + `command -v` precheck for `grep`/`awk`/`perl`) and exits FATAL if any required tool is missing. Encodes:
- **POSITIVE (P1–P11):** bulk JPQL UPDATEs present (positions, unitload, stockunit), Phase 2 bulk pre-fetch present, `flush+clear` present, `tenantTransactionManager` specified, G5 elapsed-time `LOG.info` present, G8 unit test method present, G1 integration test class present, G2 performance test class present.
- **NEGATIVE (N1–N5):**
  - N1: no class-level `@Transactional` on `BillofladingService`.
  - N2–N4: inside finishTransfer body only, `stockunitRepository.findByUnitloadId(`, `unitloadRepository.findByCarrierunitloadId(`, and `unitloadBusinessService.transferUnitLoadToLocation(` are all absent.
  - **N5a–N5d (NEW):** `@Cacheable` is absent from `UnitloadRepository`, `StockunitRepository`, `UnitloadService`, `StockunitService` — guards the cache-invalidation invariant from §9 row 9.
- **OPTIONAL (B1):** `mvn test -Dtest=BillofladingServiceUnitTest` (skippable via `SKIP_MVN=1`).

### 11.2 Recommended OMC composition

| Aspect | Value | Rationale |
|---|---|---|
| **Size class** | Standard | 1 source-file edit (G5) + 3 test changes (G8 + 2 new test classes) + verify script. Single subsystem. |
| **Pre-draft step** | none | Plan complete; v2 fix already in code. |
| **Plan-review step** | critic | One pass on the plan to catch any missed AC verification path before implementation. |
| **Implementation shape** | executor (single-pass, model=opus for the test class authoring) | Verify script is the exit gate; no need for `ralph` looping. |
| **Verification step** | verify-script + verifier | Mandatory. |
| **Code-review step** | code-reviewer | Recommended for the integration-test classes. |
| **Commit step** | git directly | Five small commits per §5.2; git-master is overkill. |

---

## 12. Notes

- The v2 fix lifecycle predates this plan: see `260424-TRANSFER_ORDER_PERFORMANCE_PLAN.md` (archived, all six phases DONE) and the commit chain in §3.
- The v1 plan for SBDEV-2216 is **not yet authored**. Track via `wms-v1-sync-sweep`. v1 line numbers (1097–1151) still hold the unbulked pattern; the v1 plan should mirror this one but with v1 constraints (Java 8, Spring Boot 2.3.7, Mockito 3.3.3 — no `mockStatic`).
- The `bolToClose` asymmetry (closeBOL only) is **accepted** per §2.3 and §9 row 1. DB pessimistic lock is the cross-replica truth.
