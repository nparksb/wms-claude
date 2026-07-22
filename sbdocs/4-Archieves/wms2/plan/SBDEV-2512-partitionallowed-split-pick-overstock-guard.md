---
title: "SBDEV-2512 (v2 port) — Honor partitionallowed=false in Overstock Release: Hold-or-Single-Pick Instead of Fragmenting a Non-Partitionable Position Across Stock Units"
ticket: "SBDEV-2512"
ticket_url: "https://app.clickup.com/t/SBDEV-2512"
type: "bugfix"
priority: "high"
status: archived
status_detail: "v1→v2 port of PR #194 (b9655bf). ralplan consensus → tdd-gate → ralph implement → code review APPROVE → PR #68 into develop (open). 2026-07-10."
project: ["wms2"]
version: "v2"
requester: "Nam Park"
created: "2026-07-10"
updated: "2026-07-15"
db_verified: true
related:
  - "[[SBDEV-2512-partitionallowed-split-pick-overstock-guard]]"
  - "[[2026-07-10-wms-v1-sync]]"
  - "[[wms2-picking-workflow]]"
  - "[[wms2-state-machine-catalog]]"
tags:
  - plan
  - wms2
  - picking
  - release-order
  - overstock
  - data-integrity
---

# SBDEV-2512 (v2 port) — Honor partitionallowed=false in Overstock Release: Hold-or-Single-Pick Instead of Fragmenting a Non-Partitionable Position Across Stock Units

**Ticket:** [SBDEV-2512](https://app.clickup.com/t/SBDEV-2512) (WineCo — v1 incident BF173533)
**Project:** wms2 | **Version:** v2/wms2-api | **Type:** Bug fix (v1→v2 port of `b9655bf`, PR #194)
**Priority:** High — same 100%-blast-radius cron as v1; the overstock-fragmentation gap and the gross-vs-net divergence both reproduce in v2 verbatim.
**Status:** Reviewed — ralplan consensus (Planner → Architect SOUND-WITH-CONDITIONS → Critic ITERATE → revised → Critic APPROVE). Pending implementation approval.
**Sweep:** [[2026-07-10-wms-v1-sync]] Lane B (SBDEV-2512 unit).

> **Scope note (v2 structural difference from v1).** v2's `releaseOrder` classifies in **two rounds** — ROUND 1 (`:145-240`) *replays* cached cross-order results carried across orders by `OrderReleaseJob`; ROUND 2 (`:246-528`) re-classifies fresh. The guard belongs in **ROUND 2 only** (round 1 is replay of an already-classified decision; round 2 re-derives it from live stock). v2 also already added a v2-native TOCTOU hardening (`getStockUnitsByItemDataIdForUpdate`, `FOR UPDATE OF stockunit`, comment at `:601`) that v1's phase-3 lacked. This port adds **only the SBDEV-2512 hold-or-single-pick behavior** on that skeleton — plus one **transaction-safety fix (NEW-1)** that fixes a **latent pre-existing partial-commit bug** and is required before Fix B lands a second checked throw. Line numbers verified by direct read 2026-07-10; re-verify at implementation.

---

## 1. Problem Statement & Root Cause (v2-accurate)

**v1 incident (SBDEV-2512, WineCo):** on BF173533, order parcel `061130-000002` released as **three** picking positions into one tote — 9 + 2 + 1 = 12 — instead of one 12-count pick, because the overstock release path never reads `CustomerorderPosition.partitionallowed`. The sibling parcel pulled cleanly as ONE 12-count case (single-source fixed-assignment path). DB-verified in the v1 plan (`db_verified: true`); the v2 port inherits that evidence — **no new v2 DB claim is made** here.

**Root cause reproduces in v2 verbatim.** `getPartitionallowed()` has **zero read call-sites** in the v2 release/picking hot path; the sole writer is `OrderBatchCreationService.java:202` `setPartitionallowed(false)` → every v2 position is non-partitionable today → **100% cron blast radius** → kill-switch mandatory, exactly as v1.

Two v2 loci collaborate to fragment (`service/job/ReleaseOrderJobService.java`, 702 lines):

- **ROUND 2 classification — overstock accept branch (`:328-351`).** Aggregate availability is read via `getStockUnitAvailable` → `StockunitAvailableView` (`:328`, `getTotal`/`getReserved`); `available >= requested` (`:340`) → healing (`:341-345`) → `pickFromOverstock.add(position)` (`:347`) → cross-order decrement `available -= requested` (`:349`) + `itemDataAvailableAmountUpdateMap.put(...)` (`:351`). This proves *enough total inventory across all units* — **not** that any single unit covers the amount. The insufficient branch sets `RAW_ON_HOLD_NOT_ENOUGH_STOCK_ON_LOCATION` (`:526`). The hold gate (`:545-556`: `RAW_ON_HOLD` + `manageOrderService.customerOrderOnHold` + `return`) runs **before** `pickingOrderService.create` (`:573`) — so a held order creates **zero** picks/reservations.

- **PHASE 3 creation loop (`:600-658`).** `pickingOrderService.create` inserts the pickingOrder at `:573`; the loop then fetches `getStockUnitsByItemDataIdForUpdate` (`:602`, pessimistic `FOR UPDATE OF stockunit`), runs an exact-match `net == missing` pass (`:606-620`), then a **greedy fragmenting** pass (partial `:636` / remainder `:644`) reserving stock (`:612-615`) until satisfied, and throws `RuntimeException` (`:656`) if not. It **never checks `partitionallowed`**.

**Gross-vs-net divergence reproduces (AC-5 ports directly).** Both `StockunitRepository.getStockUnitsByItemDataId` (`:86-97`) and `getStockUnitsByItemDataIdForUpdate` (`:99-111`) are `ORDER BY stockUnit.amount DESC` (**gross**) with an `amount > reservedAmount` filter; coverage is **net** (`amount − reserved`). So a phase-2 existence check can pass while phase-3's gross-ordered greedy pass still splits — a phase-2-only guard is provably insufficient in v2 too.

**Same-SKU multi-position re-query exposure reproduces (C-3, AC-6 ports directly).** The `amount > reservedAmount` filter means a phase-3 re-query after the first same-SKU position reserves its unit can drop the covering unit, so a *non-cumulative* fix would `throw` and rollback every cron = permanently stuck order. The fix must **hold cumulatively in round 2**.

### Affected Locations (v2)

| # | File | Line | Role / disposition |
|---|------|------|--------------------|
| 1 | `service/job/ReleaseOrderJobService.java` | `:114` | `@Transactional(...)` — **missing `rollbackFor`** → **NEW-1, EDIT** (Phase 0) |
| 2 | `service/job/ReleaseOrderJobService.java` | `:328-351` | ROUND 2 overstock accept branch — **Fix A** cumulative hold guard before `:347`; suppress `:349-351` decrement on hold |
| 3 | `service/job/ReleaseOrderJobService.java` | `:600-658` | PHASE 3 creation loop — **Fix B** single-covering-unit branch at top of loop body |
| 4 | `service/job/ReleaseOrderJobService.java` | `:145-240` | ROUND 1 replay — **no guard** (replay of round-2 decision); scope-note only |
| 5 | `service/job/ReleaseOrderJobService.java` | `:571` | pre-existing `.orElseThrow(() -> new BusinessException("Section not configured…"))` — **latent partial-commit path**, fixed by NEW-1 (see §2) |
| 6 | `service/WmsConstants.java` | `~:891-900` | add `SYSTEM_PROPERTY_ENFORCE_PARTITIONALLOWED_KEY = "ENFORCE_PARTITIONALLOWED"` |
| 7 | `repo/jpa/StockunitRepository.java` | `:86-97`, `:99-111` | gross-DESC sort + `amount>reservedAmount` filter — divergence + C-3 cause; **S6 comment guard** (no query change) |
| 8 | `service/OrderBatchCreationService.java` | `:202` | `setPartitionallowed(false)` — sole writer → 100% blast radius (context, no change) |

---

## 2. V1 → V2 Applicability

| V1 element (`b9655bf`) | V2 Verdict | Rationale |
|---|---|---|
| Fix A — cumulative round-2 hold via `reserveSingleCoveringUnit` net ledger | **Needed** | Same gross-vs-net divergence + same-SKU re-query exposure; ledger seeds from **non-locking** `getStockUnitsByItemDataId` |
| Fix B — phase-3 single-covering-unit pick + failsafe `throw` | **Needed** | Same fragmenting greedy pass (`:624-652`); Fix B scans the **already-locked** `getStockUnitsByItemDataIdForUpdate` list |
| Kill-switch `ENFORCE_PARTITIONALLOWED` (default ON) | **Needed** | Same 100% blast radius; v2 reads via `SyspropService.getSysvalue` (Caffeine 2-min TTL → no-redeploy flip in ≤2 min) |
| Mandatory hold `LOG` telemetry | **Needed (v2-adapted)** | v2 uses **SLF4J parameterized** logging (`LOG.info("… id={} …", …)`) not v1 string concat |
| `WmsConstants` sysprop key | **Needed** | Add near the `:891-900` block; `RAW_ON_HOLD` + `RAW_ON_HOLD_NOT_ENOUGH_STOCK_ON_LOCATION` already exist |
| v1's `rollbackFor={BusinessException, FacadeException}` on `releaseOrder` | **NEW-1 — v2 is MISSING it** | See below — fixes a latent pre-existing partial-commit bug AND is required before Fix B's second checked throw |

### NEW v2-only issue — NEW-1 (CRITICAL, Phase 0)

**Facts (corrected from iteration-1 draft):**
- `BusinessException` and `FacadeException` both **extend `Exception`** (checked; `exceptions/BusinessException.java:14`). The `releaseOrder` signature at `:115` **already declares `throws FacadeException, BusinessException`**.
- Fix B is **NOT** the first checked throw. `releaseOrder` **already** throws a checked `BusinessException` at `:571` via `.orElseThrow(() -> new BusinessException("Section not configured for order=" + orderNumber))`.
- **Latent pre-existing bug:** the `@Transactional` at `:114` **lacks `rollbackFor` today**. Because Spring's default only rolls back unchecked exceptions, the pre-existing `:571` "Section not configured" checked throw **currently COMMITS** the partial work already done in this `REQUIRES_NEW` tx — `markasvisited` side-effects (`:225-226`) and healed position states (`:341-345`). That is a real, shipped-today data-integrity defect, silent because the `:571` path is rare.
- **Why Fix B forces the fix now:** Fix B adds a **SECOND** checked throw in phase-3 — **after** `pickingOrderService.create` inserts the pickingOrder (`:573`) and **after** prior positions in the same order reserved stock (`:612-615`). Without `rollbackFor`, hitting that throw commits an **orphaned pickingOrder + phantom reservations**.
- **Intended blast of the fix:** adding `rollbackFor` **also changes the pre-existing `:571` path** — previously it committed `markasvisited`/heals on "Section not configured"; now it rolls them back. This is a **latent-bug fix, intended and correct**. It has **no positive unit test** (Mockito cannot observe tx-commit semantics) → deferred to **AC-9 IT** under SBDEV-2217; called out in §6 deliberately-skipped coverage, not silent.

### Structural difference documented (not a bug)
- **ROUND 1 / ROUND 2 split.** v1 had a single classification pass; v2 replays cached cross-order results in round 1 and re-derives fresh in round 2. Guarding round 1 would double-count a round-2 decision.

### What does NOT need porting
- v1's non-locking phase-3 query — v2 already hardened phase-3 with `getStockUnitsByItemDataIdForUpdate`. Fix B scans that locked list.
- Zero new constructor dependencies: `syspropService` (`:67`) and `stockunitRepository` (`:31`) are already injected.

---

## 3. Design (changes by file)

### Phase 0 — Transaction safety (NEW-1, ships first)
Pin the `releaseOrder` annotation at `:114` to **all three attributes verbatim**:
```java
@Transactional(value = "tenantTransactionManager", propagation = Propagation.REQUIRES_NEW,
        rollbackFor = { BusinessException.class, FacadeException.class })
public Map<Long, Integer> releaseOrder(...) throws FacadeException, BusinessException {
```
> **⚠ Dual-TM landmine (v2 CLAUDE.md).** `value = "tenantTransactionManager"` is **load-bearing and must be preserved**. Dropping it silently reverts tenant writes to the `@Primary` **landlord** auto-commit datasource — picks/reservations would land in the wrong DB with no rollback. The verify script asserts all three attributes (AC-8) precisely to prevent a formatter or careless edit from stripping `value`.

Gate on `mvn clean compile` + the release-job unit suite (annotation-only; DI wiring unchanged).

### File 1 — `service/WmsConstants.java`
Add near the `:891-900` `SYSTEM_PROPERTY_` block:
```java
public static final String SYSTEM_PROPERTY_ENFORCE_PARTITIONALLOWED_KEY = "ENFORCE_PARTITIONALLOWED";
```

### File 2 — `service/job/ReleaseOrderJobService.java`

**Kill-switch, read once at `releaseOrder` entry** (`SyspropService.getSysvalue :288-290`, `@Cacheable("sysprops")`, 2-min TTL, nullable trimmed String):
```java
boolean enforcePartitionGuard = !"false".equalsIgnoreCase(
        syspropService.getSysvalue(WmsConstants.SYSTEM_PROPERTY_ENFORCE_PARTITIONALLOWED_KEY));
// default ON: absent/null row or any value != "false" ⇒ enforce; value=false disables both fixes
// with no redeploy, propagating to every replica within ≤2 min (CacheConfig.java:34).
```

**Per-order net ledger** (seed once before the ROUND 2 classification loop):
```java
Map<Long, List<BigDecimal>> remainingNetByItemData = new HashMap<>();
```

**Fix A — cumulative hold guard, ROUND 2, immediately BEFORE `pickFromOverstock.add(position)` (`:347`):**
```java
if (enforcePartitionGuard
        && !Boolean.TRUE.equals(position.getPartitionallowed())
        && !reserveSingleCoveringUnit(remainingNetByItemData, position.getItemdataId(), requested)) {
    LOG.info("SBDEV-2512 held: no single unit covers non-partitionable position id={} itemdataId={} amount={} order={}",
            position.getId(), position.getItemdataId(), requested, order.getNumber());
    position.setState(WmsConstants.State.RAW_ON_HOLD_NOT_ENOUGH_STOCK_ON_LOCATION); // named constant, not literal 55
    customerorderPositionRepository.save(position);
    containsUnsatisfiedPosition = true;             // reaches the existing hold gate :545-556 → RAW_ON_HOLD + return
    itemDataAvailableAmountUpdateMap.put(itemdataId, available);  // UNDECREMENTED — see v1/v2 divergence note below
    continue;                                        // do NOT run :347 add or :349-351 decrement
}
```

> **v1/v2 divergence note (do NOT "correct" in a future sweep).** On hold, **v2 writes `itemDataAvailableAmountUpdateMap.put(itemdataId, available)` UNDECREMENTED**, whereas **v1's Fix A leaves the map untouched**. This is **deliberate and correct** — it matches v2's own reserved-nothing convention at `:358` (a position that reserves nothing puts the undecremented aggregate back so subsequent orders in the same `OrderReleaseJob` batch see the fresh un-consumed value). Architect verified this as correct/superior to leaving the map stale. A v1→v2 sync sweep must treat this as intentional divergence, not drift. (Also recorded as a one-line entry in [[2026-07-10-wms-v1-sync]].)

**New private helper** — per-order simulation of Fix B; lazily seeds each SKU's per-unit **net** list from the **non-locking** `getStockUnitsByItemDataId` (no early row locks in phase-2 simulation), decrements the first covering unit so a second same-SKU position cannot double-book it. Identical per-unit predicate to Fix B ⇒ *admission ⇒ phase-3 can single-pick* for the single-order path:
```java
private boolean reserveSingleCoveringUnit(Map<Long, List<BigDecimal>> ledger, Long itemdataId, BigDecimal required) {
    List<BigDecimal> remaining = ledger.computeIfAbsent(itemdataId, id -> {
        List<BigDecimal> nets = new ArrayList<>();
        for (Stockunit su : stockunitRepository.getStockUnitsByItemDataId(id)) {   // NON-locking, gross-DESC order
            nets.add(su.getAmount().subtract(su.getReservedAmount()));
        }
        return nets;
    });
    for (int i = 0; i < remaining.size(); i++) {
        if (remaining.get(i).compareTo(required) >= 0) {           // FIRST covering unit (deterministic)
            remaining.set(i, remaining.get(i).subtract(required)); // simulate reserving it
            return true;
        }
    }
    return false;
}
```

**Fix B — PHASE 3, at the TOP of the `:600` loop body, scanning the ALREADY-LOCKED candidate list** (`getStockUnitsByItemDataIdForUpdate`, `:602`):
```java
if (enforcePartitionGuard && !Boolean.TRUE.equals(orderPosition.getPartitionallowed())) {
    Stockunit covering = null;
    for (Stockunit su : stockUnitCandidates) {                     // same gross-DESC order, live net
        if (su.getAmount().subtract(su.getReservedAmount()).compareTo(missing) >= 0) { // SAME predicate as Fix A
            covering = su; break;                                  // FIRST covering candidate (deterministic)
        }
    }
    if (covering == null) {
        // Unreachable for the single-order path after cumulative Fix A. TRUE failsafe for the residual
        // inter-order race (same exposure as the pre-existing RuntimeException :656). rollbackFor (NEW-1)
        // now unwinds the inserted pickingOrder (:573) + any prior reservations (:612-615) cleanly.
        throw new BusinessException("SBDEV-2512: no single stock unit covers non-partitionable position "
                + orderPosition.getId());
    }
    // ... create exactly ONE pick of `missing` from `covering`; changeReservedAmount; setState(ASSIGNED); save ...
    continue;                                                      // skip the exact-match + greedy fragmenting passes
}
```
**Do NOT touch** the pre-existing `setState(ASSIGNED)+save` inside the greedy candidate loop (`:630-631`) — that is the partitionable path, unchanged.

### File 3 — `repo/jpa/StockunitRepository.java` (S6 — dual-query equivalence guard)
Add a code comment on **BOTH** `getStockUnitsByItemDataId` (`:86-97`) and `getStockUnitsByItemDataIdForUpdate` (`:99-111`):
```java
// SBDEV-2512: MUST stay byte-identical to getStockUnitsByItemDataIdForUpdate / getStockUnitsByItemDataId
// EXCEPT the trailing "FOR UPDATE OF stockunit". Fix A's non-locking ledger simulation and Fix B's locked
// reservation depend on the SAME "amount > reservedAmount" filter and "ORDER BY stockUnit.amount DESC".
// If these two diverge, the ledger admits a position phase-3 can't single-pick. Verify: script V-check.
```
No query change. A repo-level equivalence test is a nice-to-have but **not required** (H2/Testcontainer harness constraints — SBDEV-2217); the comment + verify-script V-check are the required minimum.

**Behavior matrix (kill-switch ON)** — identical to v1: non-partitionable + no single covering unit ⇒ order **held** (position `RAW_ON_HOLD_NOT_ENOUGH_STOCK_ON_LOCATION`, order `RAW_ON_HOLD`, no picks); non-partitionable + single covering unit (incl. gross-DESC divergence) ⇒ exactly **ONE** pick; two same-SKU non-partitionable positions with mutually-exclusive coverage ⇒ **held in round 2** (no throw); `partitionallowed=true` ⇒ **unchanged**; kill-switch OFF ⇒ today's fragmenting returns for all positions.

---

## 4. Prerequisites

| # | Prerequisite | Applies? | Detail |
|---|---|---|---|
| 1 | **Database state** (schema / Flyway) | **N/A** | No schema/DDL/Flyway change. `customerorder_position.partitionallowed` already exists. |
| 2 | **Feature flags / system properties** | **YES (new)** | Seed a sysprop row per tenant: key `ENFORCE_PARTITIONALLOWED`, value `true`. Read via `SyspropService.getSysvalue`. **Default ON:** absent/null row also enforces (`!"false".equalsIgnoreCase(...)`), so **safe before seeding**; `value=false` is the no-redeploy kill switch (≤2-min Caffeine propagation, §7). |
| 3 | **Config / env changes** | **N/A** | None beyond the sysprop row. |
| 4 | **Deploy-order dependencies** | **N/A** | Single wms2-api JAR; no OMS/UI coordination. |
| 5 | **Data migration** | **N/A** | Behavior is data-independent code logic; no data mutated. |
| 6 | **External systems** | **N/A** | None. |
| 7 | **Access / permissions** | **N/A** | No endpoint/authority change. |
| 8 | **Monitoring / alerts** | **YES (mandatory)** | The Fix A hold `LOG.info` (SLF4J parameterized: position id, itemdataId, amount, order) is **mandatory** — the guard runs on a 100%-blast-radius prod cron across multiple replicas, so ops must correlate any hold spike with the deploy. |

---

## 5. Implementation Priority & Checklist

**Branch:** `port/SBDEV-2512-partitionallowed-guard` off `develop`, **non-stacked** — open PRs #66 (sku-normalization) and #67 (palletize-guard) touch disjoint files; neither touches `ReleaseOrderJobService`, `StockunitRepository`, or `WmsConstants` (verified).

- [ ] **Phase 0 (NEW-1)** — pin the three-attribute `@Transactional` at `:114` (preserve `value="tenantTransactionManager"`; add `rollbackFor`). `mvn clean compile`. Commit.
- [ ] **S1** — add `SYSTEM_PROPERTY_ENFORCE_PARTITIONALLOWED_KEY` to `WmsConstants`; read `enforcePartitionGuard` once at `releaseOrder` entry (no new ctor dep). Compile. Commit.
- [ ] **S2** — add the per-order `remainingNetByItemData` ledger + private `reserveSingleCoveringUnit`. Compile. Commit.
- [ ] **S3 (Fix A)** — insert the cumulative ROUND 2 hold guard before `:347`, incl. the mandatory `LOG.info`, the named `RAW_ON_HOLD_NOT_ENOUGH_STOCK_ON_LOCATION` constant, and the undecremented `itemDataAvailableAmountUpdateMap.put(itemdataId, available)`. Compile. Commit.
- [ ] **S4 (Fix B)** — insert the phase-3 single-pick branch at the top of the `:600` loop body (failsafe `throw`). Compile. Commit.
- [ ] **S5** — add AC-1..AC-7 unit tests (§6) to `ReleaseOrderJobServiceUnitTest`; **audit the 29 existing tests** for any that exercise the split/greedy path and now need `partitionallowed=true` seeding (v1 adjusted 3 such tests) — flag/fix as an implementation task. `mvn test -Dtest=ReleaseOrderJobServiceUnitTest`.
- [ ] **S6** — add the dual-query equivalence comment on **both** `StockunitRepository` methods (`:86-97`, `:99-111`). Compile.
- [ ] Seed the `ENFORCE_PARTITIONALLOWED=true` sysprop row per target tenant.
- [ ] IT: leave `@Disabled TODO(SBDEV-2217)`.
- [ ] `bash sbdocs/9-System/scripts/verify-SBDEV-2512-partitionallowed-split-pick-overstock-guard-v2.sh` → `0 fail`.
- [ ] Code review.

---

## 6. Testing Plan / Acceptance Criteria (wms-tdd-gate consumable)

Existing classes: `unit/service/job/ReleaseOrderJobServiceUnitTest` (extends `BaseServiceUnitTest`, 29 `@Test`, injected mocks, **STRICT_STUBS**) and `ReleaseOrderJobServiceStaleStateTest`.

**Mock setup notes.** Stub `syspropService.getSysvalue(SYSTEM_PROPERTY_ENFORCE_PARTITIONALLOWED_KEY)` → `"true"` (or `null`) for enforce cases, `"false"` for AC-7. Stub **both** `getStockUnitsByItemDataId` (ledger seed) **and** `getStockUnitsByItemDataIdForUpdate` (phase-3) with **consistent** candidate lists. Stub `getStockUnitAvailable` → a `StockunitAvailableView` mock exposing `getTotal`/`getReserved`. Orders for hold cases (AC-1/AC-6) must be seeded in a state the hold gate `:545-556` acts on. **STRICT_STUBS is in effect** → in hold cases (AC-1/AC-6) the phase-3 `getStockUnitsByItemDataIdForUpdate` stub is unreached, so mark **that specific stub** `lenient()` **per-stub** (consistent with the suite's existing per-stub `lenient()` convention — do NOT switch the whole test to lenient). **AC-1's "no reservation side-effect" is verified concretely as `verify(stockunitBusinessService, never()).changeReservedAmount(...)`** (plus `never().createPickingPosition(...)`).

| AC | Statement | Gate type |
|----|-----------|-----------|
| **AC-1** | BF173533 hold (Fix A): `partitionallowed=false`, candidate nets `{9,2,1}`, amount 12 → position `RAW_ON_HOLD_NOT_ENOUGH_STOCK_ON_LOCATION`, order `RAW_ON_HOLD`, `customerOrderOnHold(...)` once, `verify(pickingorderPositionService, never()).createPickingPosition(...)`, `verify(stockunitBusinessService, never()).changeReservedAmount(...)` | **red→green** |
| **AC-2** | Single exact unit: `partitionallowed=false`, one candidate net = 12 → exactly ONE `createPickingPosition(12)`, `ASSIGNED`, no hold. **GREEN pre-fix** (net=12 already hits the existing exact-match pass at `:609`); proves the fix does not over-hold a satisfiable single-unit order | **pinning** |
| **AC-3** | Partitionable unchanged: `partitionallowed=true`, nets `{9,2,1}` → THREE picks (9/2/1). **GREEN pre-fix** (`partitionallowed=true` bypasses the guard) | **pinning** |
| **AC-4** | Single surplus unit: `partitionallowed=false`, one candidate net = 20 → exactly ONE `createPickingPosition(12)`, no hold. **GREEN pre-fix** (net=20 already hits the greedy `else` at `:644` → one pick of 12); regression guard against over-hold | **pinning** |
| **AC-5** | Gross-vs-net divergence (Fix B): `partitionallowed=false`, gross-DESC `[U_A gross25/net5, U_B gross18/net18]`, amount 12 → EXACTLY ONE `createPickingPosition(12)` from `U_B`, `never()` any partial/second pick. **Fails a phase-2-only fix.** | **red→green** |
| **AC-6** | C-3 cumulative hold (Fix A): ONE order, TWO same-`itemdataId` non-partitionable positions of 12; candidates `U`(net 18)+`V`(net 6) → whole order **HELD in round 2**, `never()` `createPickingPosition`, `never()` `changeReservedAmount`, **NO exception thrown** | **red→green** |
| **AC-7** | Kill-switch OFF: `getSysvalue → "false"`, `partitionallowed=false`, nets `{9,2,1}` → legacy fragmenting (THREE picks). **GREEN pre-fix** (guard absent) — confirms the switch restores legacy behavior | **pinning** |
| **AC-8** | **NEW-1:** the `releaseOrder` `@Transactional` carries **all three** attributes — `value = "tenantTransactionManager"` **AND** `propagation = Propagation.REQUIRES_NEW` **AND** `rollbackFor` containing **both** `BusinessException` **and** `FacadeException`. **Machine-checked by verify-script (multiline-aware), NOT a unit test** (Mockito can't observe tx semantics). | **verify-script** |
| **AC-9** (deferred) | Failsafe throw + `:571` "Section not configured" both roll back cleanly (no orphaned pickingOrder, no phantom reservations, no committed `markasvisited`/heals) | IT `@Disabled TODO(SBDEV-2217)` |

> **wms-tdd-gate framing.** Expect-fail-first ONLY for the red→green ACs: **AC-1, AC-5, AC-6**. **Pinning (green before AND after — must NOT fail first):** AC-2, AC-3, AC-4, AC-7. AC-8 is a verify-script grep (no red→green). AC-9 is deferred (IT under SBDEV-2217).

### Manual test plan

| # | Scenario | Env | Steps | Expected | Pass/Fail |
|---|---|---|---|---|---|
| M1 | Incident vector held (Fix A) | staging | SKU where no single unit's net covers a non-partitionable 12 (nets 9/2/1); run release | Order **HOLD**, position 55; **no** picks | |
| M2 | Single-unit clean pick (Fix B) | staging | Same SKU, one unit net = 12 | ONE pick of 12; no hold | |
| M3 | Divergence single-pick (AC-5) | staging | Units net5(gross25)+net18(gross18); amount 12 | ONE pick of 12 from the net-18 unit | |
| M4 | Same-SKU two-position hold (AC-6/C-3) | staging | One order, two non-partitionable positions of 12; units net18+net6 | Order **HELD** in round 2; **no** picks; **no** stuck/throw loop | |
| M5 | Partitionable still splits | staging | `partitionallowed=true`, units 9/2/1 | THREE picks — unchanged | |
| M6 | Kill-switch OFF (no redeploy) | staging DB | Set sysprop `ENFORCE_PARTITIONALLOWED=false`; wait ≤2 min (Caffeine TTL); rerun M1 | Today's fragmenting returns | |
| M7 | SQL sanity after M1 | staging DB | `SELECT count(*) FROM pickingorder_position WHERE customerorder_position_id = <held cop>;` | `0` | |

### Test execution (fill after running)

| Command | Result | P/F/S |
|---------|--------|-------|
| `mvn clean compile` | | |
| `mvn test -Dtest=ReleaseOrderJobServiceUnitTest` | | |
| `bash sbdocs/9-System/scripts/verify-SBDEV-2512-...-v2.sh` | | |

### Deliberately-skipped coverage
| What | Why |
|------|-----|
| Tx-commit-on-throw semantics (Fix B failsafe rollback) | Mockito can't observe it; covered by AC-8 verify-grep of the 3-attribute annotation + deferred IT AC-9. |
| **NEW-1 `:571` "Section not configured" rollback behavior change** | The pre-existing checked throw now rolls back `markasvisited` (`:225-226`) + heals instead of committing them (latent-bug fix, intended). **Not observable in Mockito** → deferred to **AC-9 IT under SBDEV-2217**; explicitly called out here, not silent. |
| Multi-order cross-order aggregate interaction (round-1 replay + `itemDataAvailableAmountUpdateMap`) | Single-instance harness; the undecremented-put-on-hold path is asserted at unit level (AC-1) and reasoned in §3. Full multi-order Testcontainers harness blocked by SBDEV-2217. |
| `StockunitRepository` dual-query byte-equivalence (repo test) | H2/Testcontainer harness constraints; substituted by the S6 comment + verify-script V-check (grep). |

---

## 7. Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| **Always-on prod cron, 100% blast radius** (`OrderBatchCreationService:202` → all v2 positions non-partitionable) | Certain | Med | **Sysprop kill-switch (default ON)** — `value=false` restores today's behavior with **no redeploy**, ≤2-min Caffeine propagation across all replicas (§4 row 2). Primary rollback lever. |
| **NEW-1: missing `rollbackFor` commits partial work** (pre-existing `:571` today; orphaned pickingOrder + phantom reservations after Fix B) | Certain (latent) | High | Phase 0 adds `rollbackFor`; AC-8 verify-grep (multiline-aware) gates all three attributes; deferred IT AC-9. |
| **Dropping `value="tenantTransactionManager"`** during the annotation edit | Low | High | Writes silently revert to `@Primary` landlord auto-commit DB. AC-8 asserts `value` explicitly; §3 warning. |
| Guard holds orders that previously released (fragmented) | Certain | Low–Med | **Intended** — fragmenting a non-partitionable case is the bug. Mandatory hold `LOG.info` lets ops replenish a full unit; kill-switch is the escape hatch. |
| Cumulative Fix A over-holds multi-position same-SKU orders | Low | Low | v1 measured **0 of 479,265** WineCo orders with >1 position per itemdataId; defensive insurance. Kill-switch covers the tail. |
| Over-hold of satisfiable single-unit orders (Fix A too aggressive) | Low | Med | **Pinned by AC-2 + AC-4** (both green pre- and post-fix) — a satisfiable net=12 or net=20 single unit must still pick, never hold. |
| Inter-order race on Fix B's failsafe `throw` | Low | Low | Same exposure as the pre-existing `RuntimeException :656`; order lock (`findByIdForUpdate :122`) serializes same-order releases; `rollbackFor` makes rollback clean; retried next cron. |
| Fix A / Fix B predicate drift | Low | Med | Identical per-unit predicate + first-covering rule; AC-2/4/5/6 pin it. |
| **Dual-query divergence** (someone edits one `StockunitRepository` method, not the other) | Low | Med | **S6 comment on both methods + verify-script V-check** asserting both carry the same core `WHERE`/`ORDER BY`. |
| Verify-script over-claim (weaker fix greps green) | Low | Med | Script requires `getPartitionallowed` read **≥2×**, the `reserveSingleCoveringUnit` helper querying `getStockUnitsByItemDataId`, the sysprop key, all three `@Transactional` attributes, dual-query equivalence, AND `mvn` gate incl. AC-5 + AC-6. |

---

## 8. Horizontal Scalability Validation (v2 — MANDATORY)

| # | Concern | Verdict | Rationale / mitigation |
|---|---|---|---|
| 1 | In-JVM state | **No** | `remainingNetByItemData` is method-local per `releaseOrder` call; not shared across requests/replicas. |
| 2 | Connection pool math | **No** | Reads occur inside the caller's existing `REQUIRES_NEW` tx/connection; helper reuses the open connection (non-locking query). No new pool. |
| 3 | Scheduled jobs | **No** | `OrderReleaseJob` is the existing cron; no new `@Scheduled`. Single-instance-cron assumption inherited (unchanged). |
| 4 | Long transactions | **No** | Fix A helper adds bounded in-memory ops; no external I/O; Fix B replaces the greedy loop with a single scan — net **shorter** work inside the tx. |
| 5 | Request affinity | **N/A** | Cron-driven, no session affinity. |
| 6 | Retry / idempotency | **Yes** | A held order or a failsafe-thrown order is retried next cron; hold is idempotent (re-evaluates live stock); `rollbackFor` (NEW-1) ensures no partial write survives a retry-triggering throw. |
| 7 | Tenant context | **No** | Runs on the existing tenant-scoped cron thread (`tenantTransactionManager`); no new async boundary. |
| 8 | Distributed lock correctness | **Yes (rely on existing)** | `findByIdForUpdate :122` (order) + `getStockUnitsByItemDataIdForUpdate :602` (`FOR UPDATE OF stockunit`) both inside the `tenantTransactionManager` `REQUIRES_NEW` tx; Fix B scans that locked list. No new lock. |
| 9 | Cache invalidation | **Yes (read-only)** | Reads `SyspropService.getSysvalue` (`@Cacheable("sysprops")`, 2-min TTL). No write to a cached entity; kill-switch flip propagates within TTL — documented rollback lever, not a correctness risk. |
| 10 | External notifications | **No** | Only `LOG.info`; no OMS/printer call added inside the tx. |

### Evidence (Yes rows)
| Concern # | Verified | Reference |
|-----------|----------|-----------|
| 6 | Retry-safe: hold re-evaluated next cron; `rollbackFor` prevents partial commit | `:545-556`, `:114` |
| 8 | Locks inside existing tx; Fix B uses the locked list | `:122`, `:602`, `:600-658` |
| 9 | Sysprop read is cached, read-only | `SyspropService:288-290`, `CacheConfig.java:34` |

---

## 9. ADR (consensus record)

- **Decision:** Port `b9655bf` as a **two-part guard on v2's two-round skeleton** — kill-switch read once at entry (default ON); cumulative **Fix A** hold in **ROUND 2** before `:347` (undecremented `itemDataAvailableAmountUpdateMap.put` on hold, matching v2's `:358` convention); **Fix B** single-covering-unit pick at the top of the phase-3 loop scanning the already-locked list; **NEW-1** three-attribute `rollbackFor` on `:114`; **S6** dual-query equivalence comment guard. Zero new constructor deps.
- **Drivers:** (1) same root cause + gross-vs-net divergence + same-SKU C-3 exposure reproduce in v2 → same fix design; (2) 100% cron blast radius → kill-switch + mandatory telemetry non-negotiable; (3) NEW-1 fixes a latent pre-existing partial-commit bug (`:571`) AND is required before Fix B's second checked throw (orphaned pickingOrder + phantom reservations).
- **Alternatives considered:** *Phase-2-only existence guard* — rejected (gross-DESC vs net divergence still fragments; AC-5). *Non-cumulative two-part fix* — rejected (Fix B `throw` reachable for same-SKU multi-position orders → permanently stuck order; AC-6). *Skip NEW-1* — rejected (Fix B makes the partial-commit live; silent orphaned pickingOrder is a data-integrity defect). *Fix-B-only detect-and-hold in phase 3* — rejected (by phase 3 the pickingOrder is already inserted `:573` and prior positions reserved `:612-615` → throwing/unwinding every 60 s cron for a persistently-held order; Fix A holds in round 2 with ZERO writes).
- **Why chosen:** cumulative Fix A makes Fix B's throw unreachable on the single-order path (failsafe only for the inter-order race); mirrors the reviewed+shipped v1 design (PR #194) so v1↔v2 stay paired; minimal structural change on v2's existing tx/lock skeleton.
- **Consequences:** one new `WmsConstants` key; one 3-attribute annotation edit; one new private helper; S6 comments on 2 repo methods; ~29 existing tests audited for `partitionallowed=true` seeding. Kill-switch + telemetry give ops a no-redeploy revert + observability. One **intentional v1/v2 divergence** (undecremented map put) recorded to prevent future sweep "correction."
- **Consensus:** Architect **SOUND-WITH-CONDITIONS** (5 conditions: NEW-1 rationale rewrite, 3-attribute annotation pin, named-constant usage, S6 dual-query guard, v1/v2 divergence note — all folded). Critic **ITERATE → APPROVE** (AC-2/AC-4 reclassified pinning; AC-8 3-attribute assert; multiline-aware verify; `:571` deferred-coverage callout; per-stub lenient + concrete `never().changeReservedAmount` — all folded).
- **Follow-ups:** re-enable IT AC-9 when SBDEV-2217 lifts; confirm no replenish/club-line/manual release route bypasses `releaseOrder` in v2 (v1 confirmed all route through it; v2 grep confirmed sole caller `OrderReleaseJob.java:290`).

---

## 10. Acceptance Script

`sbdocs/9-System/scripts/verify-SBDEV-2512-partitionallowed-split-pick-overstock-guard-v2.sh` (authored with this plan; baseline all-FAIL). Checks:
- **Positive:** `reserveSingleCoveringUnit` helper present **and** queries `getStockUnitsByItemDataId`; Fix A guard combines `getPartitionallowed` + `reserveSingleCoveringUnit` + `RAW_ON_HOLD_NOT_ENOUGH_STOCK_ON_LOCATION`; `getPartitionallowed` read **≥2×** (round-2 + phase-3, proving Fix B is in the loop); `SYSTEM_PROPERTY_ENFORCE_PARTITIONALLOWED_KEY` constant wired and read via `getSysvalue`.
- **AC-8 (3-attribute annotation, MULTILINE-AWARE):** confirm the `releaseOrder` `@Transactional` carries `value = "tenantTransactionManager"` **AND** `propagation = Propagation.REQUIRES_NEW` **AND** `rollbackFor` containing **both** `BusinessException` **and** `FacadeException`. The ~120-char 3-attribute annotation may wrap across lines under a formatter, so **do NOT use a single-line grep** — use `grep -Pzo '@Transactional[\s\S]*?\)\s*[\s\S]*?public\s+Map<Long,\s*Integer>\s+releaseOrder'` (or an `awk` block spanning from `@Transactional` to the `public Map<Long, Integer> releaseOrder` signature) and assert all three attribute substrings inside that span.
- **V-check (S6 dual-query equivalence):** assert `getStockUnitsByItemDataId` and `getStockUnitsByItemDataIdForUpdate` in `StockunitRepository` share the same core `amount > reservedAmount` filter and `ORDER BY stockUnit.amount DESC`, differing only by the trailing `FOR UPDATE OF stockunit`; assert the S6 comment is present on both.
- **Behavioral gate:** `mvn test -Dtest=ReleaseOrderJobServiceUnitTest` incl. **AC-5** (divergence) + **AC-6** (C-3 cumulative hold).
- Acceptance = `Result: N pass, 0 fail`.

---

## 11. Implementation Status

**Implemented 2026-07-10.** v1→v2 port of `30a6ca4` (SBDEV-2512, reinstated via v1 PR #194).

- **Branch / commits / PR:** `port/SBDEV-2512-partitionallowed-guard` @ `cb159b1` (production fix) + `7eb2577` (tests) → **PR [#68](https://github.com/SiteBossInc/wms2-api/pull/68)** into `develop` (**open, pending merge**; non-stacked, disjoint from open PRs #66/#67).
- **Code changes (v2/wms2-api):**
  - `service/WmsConstants.java` — added `SYSTEM_PROPERTY_ENFORCE_PARTITIONALLOWED_KEY = "ENFORCE_PARTITIONALLOWED"`.
  - `service/job/ReleaseOrderJobService.java` — **Phase 0** `rollbackFor={BusinessException.class, FacadeException.class}` added to the `releaseOrder` `@Transactional` (value + REQUIRES_NEW preserved); kill-switch `enforcePartitionGuard` read once at entry; per-order `remainingNetByItemData` ledger; **Fix A** cumulative round-2 hold guard before `pickFromOverstock.add` (mandatory `LOG.info`, named `RAW_ON_HOLD_NOT_ENOUGH_STOCK_ON_LOCATION`, undecremented `itemDataAvailableAmountUpdateMap.put` on hold); **Fix B** phase-3 single-covering-unit branch + failsafe `throw`; new private `reserveSingleCoveringUnit`.
  - `repo/jpa/StockunitRepository.java` — **S6** dual-query equivalence comments on both candidate queries (no query change).
- **Tests:** `ReleaseOrderJobServiceUnitTest` — new `PartitionAllowedGuard` suite (7: AC-1/AC-5/AC-6 red→green, AC-2/AC-3/AC-4/AC-7 pinning). **Existing-test audit:** seeded `partitionallowed=true` in the `ReleaseOrderOverstock` `@BeforeEach` (7 legacy overstock tests exercise the unguarded split/greedy path). **`Tests run: 36, Failures: 0`** (`mvn test -Dtest=ReleaseOrderJobServiceUnitTest`, SDKMAN). `mvn clean compile` SUCCESS.
- **Verify script:** `bash sbdocs/9-System/scripts/verify-SBDEV-2512-partitionallowed-split-pick-overstock-guard-v2.sh` → **`Result: 13 pass, 0 fail, 0 skip`** (incl. AC-8 multiline 3-attribute annotation check + the mvn behavioral gate running AC-5 + AC-6). Two script fixes during impl: V7c made multiline-robust (`[SBDEV-2512]` marker count + `byte-identical`), and `mvn_test_passes` wrapped the sdkman source in `set +u`.
- **Review lane:** Planner → Architect SOUND-WITH-CONDITIONS (5 conditions folded) → Critic ITERATE → revised → Critic APPROVE → `wms-tdd-gate` (3 red-right + 4 pinning) → ralph → `code-reviewer` **APPROVE** (0 HIGH / 0 MEDIUM; 3 LOW non-blocking).
- **Integration tests:** none added; existing lane remains `@Disabled TODO(SBDEV-2217)`.
- **Docs updated (sbdocs, not in git):** `data-dictionary/wms2-sysprop-catalog.md` (+`ENFORCE_PARTITIONALLOWED` row in §10 Picking, ~75→~76, `last_verified` 2026-07-10); `workflows/wms2-picking-workflow.md` (§2 guard note + §9 `rollbackFor` clause, `last_verified` 2026-07-10); `2-Areas/wms-v1-v2-sync/sweeps/2026-07-10-wms-v1-sync.md` (unit-3 record + intentional undecremented-map-put v1/v2 divergence note).

### Follow-ups (from code review — LOW, non-blocking)
- **Deterministic tie-breaker (LOW-1):** add `, stockunit.id` as a secondary sort to both `StockunitRepository` candidate queries so Fix A's simulation and Fix B's execution are provably identical under equal-gross ties. Benign today (covering/non-covering partition is order-independent); deferred to avoid an unreviewed change on 3 shared callers.
- **Mixed partitionable + non-partitionable same-SKU (LOW-2):** unreachable in v2 today (sole writer hard-codes `false`); revisit if a future feature emits `partitionallowed=true`.
- **AC-9 IT:** re-enable the tx-commit-rollback integration test (Fix B failsafe + `:571` "Section not configured" both roll back cleanly) when SBDEV-2217 lifts.
