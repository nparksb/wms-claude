---
title: "SBDEV-2492 (V2): Replenishment-Order Source Not Synced on Unit-Load Move — Replen Picks Directed to Stale Source Location"
ticket: "SBDEV-2492"
ticket_url: "https://app.clickup.com/t/9006034209/SBDEV-2492"
pr: "https://github.com/SiteBossInc/wms2-api/pull/53"
type: bug
priority: high
status: implemented
project:
  - wms2
version: v2
requester: Internal
created: 2026-06-26
updated: 2026-06-26
db_verified: inherited-from-v1
related:
  - "../../wms1/plan/SBDEV-2492-replen-order-source-sync-on-unitload-move.md"
  - "260610-wms2-multi-replica-hardening"
  - SBDEV-2481
  - SBDEV-2217
tags:
  - plan
  - replenishment
  - move-stock
  - move-unitload
  - sbdev-2492
  - v1-to-v2-port
---

# SBDEV-2492 (V2): Replenishment-Order Source Not Synced on Unit-Load Move — Replen Picks Directed to Stale Source Location

**Ticket:** [SBDEV-2492](https://app.clickup.com/t/9006034209/SBDEV-2492)
**Project:** v2/wms2-api (Java 21 / Spring Boot 3.5.9) | **Version:** v2 | **Type:** Bug (long-standing design gap masked by the maintenance cron's heal-on-next-pass)
**Priority:** High (replenishment picks directed to a location that no longer holds the stock; intermittent, masked by cron)
**Status:** APPROVED (ralplan consensus 2026-06-26 — Architect ITERATE→addressed; Critic APPROVE on iteration 2. Decisions: Option B pessimistic lock; NEW-1 as Phase 0; Decision-5 dropped.) Implementation pending.
**Date:** 2026-06-26
**Branch:** `port/SBDEV-2492-replen-source-sync` (v2/wms2-api)

**V1 source plan:** [`sbdocs/1-Projects/wms1/plan/SBDEV-2492-replen-order-source-sync-on-unitload-move.md`](../../wms1/plan/SBDEV-2492-replen-order-source-sync-on-unitload-move.md) (implemented v1, PR [SiteBossInc/wms-api#183](https://github.com/SiteBossInc/wms-api/pull/183), commit `e0ff548`). The v1 plan is extremely detailed; this plan ports it to v2, re-verifies every fix against the v2 tree, records what v2 already has, and surfaces three v2-only issues.
**Related v2 hardening plan (critical for the Decision-5 divergence):** [`260610-wms2-multi-replica-hardening.md`](260610-wms2-multi-replica-hardening.md) — commit `895ee9f` ("remove inert OptimisticLockRetry call sites; 260610 hardening Phase A") removed the **inert call sites** of `OptimisticLockRetry`. The `OptimisticLockRetry` **class still exists** at `src/main/java/net/aim_ai/wms/util/OptimisticLockRetry.java` and is still used by `MobilePalletizingService`; what `895ee9f` removed are the call sites where the wrapper sat inside an open transaction and could never fire (Hibernate throws at flush/commit, after the wrapper returns). `OptimisticLockRetryScopeTest` pins that `UnitloadBusinessService` / `PickingorderBusinessService` must **not inject** `OptimisticLockRetry`. **v2 does not use an in-process optimistic-retry wrapper on the move path.** This is the single largest divergence from the v1 fix.
**Sibling v2 plan:** SBDEV-2481 (stale pick-line realignment on stock move) — already on this branch; this plan hooks **beside** its `BLOCK_REALIGN` loop in `processTransfer` and reuses its classifier and entry-method locks.

> **v2 package note:** v2 JPA repositories live under `net/aim_ai/wms/repo/jpa/`. `Replenishorder` lives under `net/aim_ai/wms/model/` and extends `AbstractBaseEntity` (`@Version Integer` inherited at `AbstractBaseEntity:34-35` → ID-equality + optimistic lock). State constants in `net/aim_ai/wms/service/WmsConstants.java` (`WmsConstants.State`).

---

## 0. RALPLAN-DR Summary (consensus mode)

### Principles (top 5)

1. **Don't re-fix what v2 already has.** Fix C is already 90% present in v2 (`redirectSource` sets two of three fields). Only the missing line is ported. Verified, not assumed.
2. **Honor the v2 transactional contract.** Every tenant write must run under `@Transactional(value="tenantTransactionManager", rollbackFor={...})`. A bare `@Transactional` routes to the `@Primary` **landlord** TM and silently disables rollback on tenant writes — the same trap SBDEV-2102 §0 principle 3 names. The new sync service must **join the caller's tenant tx** (no bare `@Transactional`).
3. **Multi-replica safety is non-negotiable.** v2 runs ≥2 replicas behind a load balancer; the maintenance cron and a concurrent move can hit the same `replenishorder` row on different replicas. The chosen concurrency mechanism must be correct under that race — not merely "works on one box."
4. **The v1 retry mechanism does NOT port.** v2 deliberately removed the `OptimisticLockRetry` **call sites** on the move path (commit `895ee9f`) because a retry wrapper inside an open `@Transactional` can never fire — Hibernate throws at flush/commit, *outside* the wrapper. The class still exists (used by `MobilePalletizingService`), but `OptimisticLockRetryScopeTest` pins that the move services must **not inject** it. Re-wiring it into the move path would fail that test. The v2 concurrency stance is structurally different (see Principle 5 + the concurrency ADR).
5. **v2's documented optimistic stance + a pessimistic option.** v2's settled stance (260610) is: optimistic conflict → `ObjectOptimisticLockingFailureException` → `RestExceptionHandler:144-150` returns HTTP 409 `retryable:true` → **client** retries; the cron is the backstop. For the *new* re-point write, we can either lean on that (Option A) or pre-serialize against the cron with a pessimistic lock the move already holds the transaction for (Option B). The key design choice is which.

### Decision Drivers (top 3)

1. **Cron-vs-move write contention on a shared row (multi-replica).** The maintenance cron (`recalculateOpenOrders`) loads the replen via `findByIdForUpdate` (PESSIMISTIC_WRITE) on its own replica. The new sync writes the *same* row inside the move tx on another replica. Whatever mechanism we pick must define what happens when those two collide — a 409 the client must retry, or a serialized wait.
2. **Correctness of "block in-progress" + atomicity of the whole pallet tree.** A `>=STARTED` replen anywhere in the moved tree must fail the *entire* move atomically (no partial relocation). This requires the sync to run inside the move's single tenant transaction with REQUIRED propagation — which constrains where `findByIdForUpdate` may legally be called (it throws outside a tx).
3. **Smallest faithful diff that respects the v2 architecture.** Port the behavior (re-point, not cancel; block STARTED incl. 530; fix the adjacent name-set), not the v1 *plumbing* (the controller-wrap retry, which v2 has structurally rejected).

### Viable Options for the concurrency mechanism (≥2)

| # | Option | Pros | Cons | Verdict |
|---|--------|------|------|---------|
| **A** | **Optimistic-only.** New service does `findByStateLessThanAndStockunitId` → re-check state → `save`; rely on `@Version` + the 409/`retryable:true` client retry + cron backstop. | Simplest diff; zero new lock; matches the SBDEV-2481 sibling's documented 409 reliance; no lock-order surface. | The cron heal holds `PESSIMISTIC_WRITE` on the same row, so a move-vs-cron collision still surfaces a 409 the **operator's client** must retry — a user-visible blip on exactly the reporter's shape (fully-reserved child UL). | Considered (ADR alternative) |
| **B** | **Pessimistic (v2-consistent). RECOMMENDED.** New service finds the active replen via `findByStateLessThanAndStockunitId`, then `findByIdForUpdate(id)` to lock + re-read, re-checks `state>=STARTED`, then writes. Runs inside the caller's tenant tx (joins `transferUnitLoadToLocation`'s `@Transactional`). | Serializes with the cron **exactly as v2's documented stance and as SBDEV-2481 does for CO/PO**; converts a move-vs-cron collision from an operator-visible 409 into a serialized wait; single lock the move already transacts for. | Adds a pessimistic `PESSIMISTIC_WRITE` lock to the move path and **holds it for the remainder of the recursive whole-tree move tx**; a move that hits a row the cron is actively healing **blocks** until the cron tx commits/rolls back (an operator-perceived **stall**, bounded only by the tenant datasource `lock_timeout` if one is set — see R-3/R-9). `findByIdForUpdate` requires a tx — always satisfied here, since the move entry is `@Transactional(tenantTransactionManager)` on all four BLOCK_REALIGN paths (NEW-3). | **Selected** |
| **C** | Re-wire the v1 `OptimisticLockRetry` wrapper into the move controllers/services. | Mechanical parity with v1. | **Architecturally invalidated in v2** — the move-path call sites were removed in `895ee9f`; the wrapper can never fire inside an open `@Transactional`; `OptimisticLockRetryScopeTest` pins that the move services must NOT inject `OptimisticLockRetry`; `spring-retry` is absent from `pom.xml`. (The class itself still exists for `MobilePalletizingService`.) | **Rejected (cannot apply)** |

**Firm recommendation: Option B (pessimistic).** It is the v2-consistent realization of "serialize the re-point against the cron" and matches how SBDEV-2481 already handles owning CO/PO rows. **Honest tradeoff (not strictly superior):** Option B does not eliminate the contention — it converts a 409-the-client-retries (Option A) into a server-side **lock wait** the operator perceives as a brief stall while the cron's heal tx finishes. Whether that wait is bounded depends on the tenant datasource `lock_timeout` / `jakarta.persistence.lock.timeout` (flag for the implementer to verify; if none is configured, the wait is `lock_timeout`/indefinite — R-9). Option A is the documented alternative in the ADR (§10); it is defensible and lower-diff, trading the stall for a client-visible retry. Option C is not available in v2.

### Mode

**SHORT** (default). The change is narrowly scoped to the replenishment subsystem + the shared move choke point. Multi-replica concerns are addressed inline (§7 Horizontal Scalability). Escalate to `--deliberate` (pre-mortem + expanded e2e/observability) only if the critic flags the cron-vs-move race as higher-risk than the optimistic stance already covers.

---

## 1. Problem Statement

### User-Visible Symptom

A `Replenishorder` records its **source** as a coupled triple — `requestedlocationId` (rots on move), `sourcelocationname` (rots on move), `requestedrackId` (rots on move) — plus `stockunitId` (an FK that **stays valid**). When the underlying unit load moves, `UnitloadBusinessService` updates `unitload.storagelocation_id` (and recurses into child ULs) but **never touches the bound `Replenishorder`**. After a parent-pallet move, the child UL's physical location is correct, but the replen still points at the **old** location.

The mobile UI computes the source from the **live** UL location (new); the replen source-check compares against the **stale** `requestedlocation`/`sourcelocationname` (old). The operator sees a directive to a location that no longer holds the stock — e.g. *"no unit load at 53-734"* — and only the original `TC-OS` source still works.

### Reproduction (v2)

1. Place stock on a child UL nested on a parent pallet (`carrierunitload_id` non-null), fully reserved (`reservedamount == requestedamount`), backing a PROCESSABLE (`300`) replenishment order.
2. Move the **parent pallet** A → B (mobile move-unit-load or web manual move). The transfer recurses to the child and rewrites the child UL's `storagelocation_id` to B.
3. **Immediately** (before the next maintenance pass) the replen still points at A.

```sql
-- Stale-source detector: open replen whose bound SU's UL now sits at a
-- different location than the replen's recorded requestedlocation.
SELECT ro.id            AS replen_id,
       ro.state,
       ro.stockunit_id,
       ro.requestedlocation_id,
       ro.sourcelocationname,
       ro.requestedrack_id,
       ul.storagelocation_id AS ul_actual_location
FROM   replenishorder ro
JOIN   stockunit su ON su.id = ro.stockunit_id
JOIN   unitload  ul ON ul.id = su.unitload_id
WHERE  ro.state < 700                         -- open orders
  AND  ro.requestedlocation_id <> ul.storagelocation_id;   -- source rotted
-- > 0 rows in the window between the move and the next maintenance pass.
```

### DB-verification

`db_verified: inherited-from-v1`. The v1 plan confirmed against `wms1-wineco-dev`: `replenishorder` carries `stockunit_id`, `requestedlocation_id`, `sourcelocationname`, `requestedrack_id`, `state`, `version`; current stale-source count is 0 **only** because `ReplenishmentOrderMaintenanceService.recalculateOpenOrders` heals stale `state=300` rows on its sysprop-gated cadence — staleness is a transient window between the move and the next pass. The v2 schema is the same shape; re-confirm against `wms2-wineco-dev` before merge (the schema columns are identical; the heal cron exists in v2 too — see §3).

The intermittency (heal-on-next-pass) is exactly why this is a hard-to-catch, recurring report rather than a steady-state defect.

---

## 2. Summary (port counts)

| Category | Count | Detail |
|---|---|---|
| **v1 fixes total** | 3 (Fix A, Fix B, Fix C) + 1 mechanism decision (Decision 5 controller-wrap) | from the implemented v1 plan |
| **Already-in-v2 (no port / partial)** | Fix C partial (2 of 3 field-sets present); Decision 5 **N/A** | Fix C needs only the missing `setSourcelocationname` line; Decision 5's `OptimisticLockRetry` move-path **call sites were removed** from v2 (`895ee9f`) — not ported (the class still exists for `MobilePalletizingService`) |
| **Needed (port)** | Fix A (new service + hook), Fix B (drop cancel-on-move), Fix C (one line) | all infra present in v2; constructor injection, `findByIdForUpdate`, finder all confirmed |
| **NEW v2-only issues** | 3 (NEW-1 HIGH, NEW-2 MEDIUM, NEW-3 design guard) | surfaced by the v2 transactional-routing model — see §6 |

**Decision-5 divergence (call out prominently):** the v1 fix wrapped four move-entry controllers in `OptimisticLockRetry.executeWithRetry`. **That call-site pattern is gone from the v2 move path and must not be re-wired.** Commit `895ee9f` removed the move-path call sites because a retry wrapper inside an open `@Transactional` can never fire (Hibernate throws at flush/commit, after the wrapper has returned). The `OptimisticLockRetry` class still exists (used by `MobilePalletizingService`), but `OptimisticLockRetryScopeTest` pins that the move services must **not inject** it. v2's stance is: optimistic conflict → 409 `retryable:true` → client retries; cron is the backstop. The recommended v2 concurrency mechanism (Option B, pessimistic `findByIdForUpdate`) serializes the new write against the cron *inside the move tx* instead. See §3 V1→V2 table Decision-5 row and the §10 ADR.

---

## 3. V1 → V2 Applicability Matrix

Every v1 fix and decision is a row, with a v2 verdict. File:line are v2 sites (verified against branch `port/SBDEV-2492-replen-source-sync`).

| V1 item | V1 mechanism | v2 reproduction? | v2 site (verified) | Verdict / v2 action |
|---|---|---|---|---|
| **Fix A** — new `ReplenishmentOrderSourceSyncService` + hook in `processTransfer` `BLOCK_REALIGN` loop | new repos-only service; per-SU re-point of the source triple, recursive over the tree | **Yes** (same design gap) | `UnitloadBusinessService.java:290-296` (`if(classify==BLOCK_REALIGN){ for(su:findByUnitloadId){ assertNoActivePickFor; realignForMovedStockUnit(su,unitload,dest) }}`); insert after `realignForMovedStockUnit` at **:294** | **PORT.** New service joins the move's tenant tx; hook one call after the 3-arg realign. Constructor injection into `UnitloadBusinessService` (final field :55, ctor :60-80). |
| **Fix B** — drop cancel-on-move in `checkReservedStock` | replace `cancelReplenishmentOrder` with let-it-proceed (`continue`); keep reserved-but-no-replen `throw` | **Yes — confirmed present** | `MobileMoveUnitloadService.checkReservedStock:188-203`; `cancelReplenishmentOrder` at **:197**; reserved-no-replen `throw` at **:200** | **PORT.** Remove the `:197` cancel call (keep `continue;`); keep the `:200` throw. `existsForStockUnit` at `ReplenishorderService:275`, `cancelReplenishmentOrder` at `:202` exist. |
| **Fix C** — `redirectSource` sets `sourcelocationname` | additive one-line `setSourcelocationname` before save | **Partial — 2 of 3 already present** | `ReplenishorderService.redirectSource:170-199`: sets `requestedlocationId`(:191) + `requestedrackId`(:192) but **NOT** `sourcelocationname`; `location` in scope at :186; `save` at :193 | **PORT (one line).** Add `replenishOrder.setSourcelocationname(location.getName());` before `:193`. Leave `changeReservedAmount` unreserve(:178)/reserve(:195) + `setStockunitId`(:190) untouched. |
| Active-replen finder reuse | `findByStateLessThanAndStockunitId(state,suId):Optional<Replenishorder>` | n/a (reuse) | `ReplenishorderRepository.findByStateLessThanAndStockunitId(Integer,Long):91-92` → `Optional<Replenishorder>` | **REUSE.** New service calls the repo directly (repos-only / acyclic). |
| Re-point field-triple pattern | maintenance `redirectSource` sets all three | n/a (pattern) | `ReplenishmentOrderMaintenanceService` re-point (pattern reference) | **PATTERN REUSE** for the triple shape. |
| Owning-Pickingorder entry locks | SBDEV-2481 pre-walks + locks the owning POs at the entry method | n/a (inherited) | SBDEV-2481 already on this branch | **INHERIT.** The sync runs inside the same `BLOCK_REALIGN` block; no new pick-lock. |
| Optimistic `@Version` | `Replenishorder.version` `@Version` | yes | `AbstractBaseEntity.version` (`@Version Integer` :34-35), inherited by `Replenishorder` | **PRESENT.** Drives the 409/`retryable:true` path (Option A) or coexists with the pessimistic lock (Option B). |
| **Decision 5** — wrap 4 move controllers in `OptimisticLockRetry.executeWithRetry` | in-process retry wrapper at the controller boundary | **NO — call sites architecturally removed** | move-path call sites **removed in `895ee9f`** (260610 Phase A); class still exists at `util/OptimisticLockRetry.java` (used by `MobilePalletizingService`); `OptimisticLockRetryScopeTest` pins that the move services must NOT inject it; no `spring-retry` in `pom.xml` | **NOT APPLICABLE.** Do **not** wire `OptimisticLockRetry` into the move controllers/services; do **not** add `@Retryable`. v2 stance: 409 `retryable:true` (`RestExceptionHandler:144-150`) + cron backstop; Option B serializes the new write with `findByIdForUpdate` instead. See §10 ADR. |
| Decision 2 / 6 — block `>=STARTED` (incl. 530) | `>=STARTED` predicate | yes | `WmsConstants.State`: `PROCESSABLE=300`(:46), `STARTED=500`(:56), `ORDER_BATCH_CLUB_RUN_FINISHED=530`(:86), `FINISHED=700`(:116) | **PORT.** Same predicate `ro.getState() >= STARTED` (intentionally covers 530). |

**OUT (same as v1 taxonomy, re-confirmed for v2):** split (`CODE_MANUAL_SPLIT`), shipping/truck-load (`CODE_SHIPPING`/`CODE_TRUCK_LOADING`), carrier nesting, transfer-order (null `activityCode`) are all **PASS_THROUGH** by the SBDEV-2481 classifier and never reach the new write.

---

## 4. V2-Specific Adaptation Notes

These are the v2 translation rules applied throughout §5 (matching SBDEV-2102's port discipline):

- **Tenant transaction manager.** Tenant writes carry `@Transactional(value="tenantTransactionManager", rollbackFor={BusinessException.class, FacadeException.class})`. A bare `@Transactional` routes to the `@Primary` **landlord** TM and disables rollback on tenant writes. The new sync service **must not** carry a bare `@Transactional`; it joins the caller's tenant tx (REQUIRED propagation). See NEW-3.
- **`jakarta.*` not `javax.*`** for all imports (Spring Boot 3.x).
- **`.orElseThrow(...)` not `.get()`** on `Optional` (matches the v2 `EntityNotFoundException` pattern at `StockunitService:161` etc.).
- **Constructor injection**, not field `@Autowired`. `UnitloadBusinessService` already uses constructor injection (final fields :55, ctor :60-80) — add the new collaborator as a final field + ctor param + assignment.
- **`AbstractBaseEntity` ID-equality** — never `.equals()` on object refs that may be detached; compare by ID. `Replenishorder` extends `AbstractBaseEntity`.
- **Reuse `findByIdForUpdate`** for the pessimistic path (Option B) — `ReplenishorderRepository.findByIdForUpdate(Long)` PESSIMISTIC_WRITE at `ReplenishorderRepository.java:27-29` (the method itself, no comment); the maintenance cron already uses it at `ReplenishmentOrderMaintenanceService.java:154`. The warning that it throws `InvalidDataAccessApiUsageException` outside a transaction is documented at `ReplenishmentOrderMaintenanceService.java:73-77` (the `@Lazy` field Javadoc; ref plan `260520-replenishment-open-orders-missing-tx`). The sync therefore MUST run inside the move's tenant tx (NEW-3). **Note:** the call path is always transactional because the move entry (`transferUnitLoadToLocation`) is `@Transactional(tenantTransactionManager)` even when reached via `StockunitService.setLockOnHold` (a different bean → real proxy boundary → tenant tx begins). So `findByIdForUpdate` is legal on all four BLOCK_REALIGN entry paths regardless of NEW-1 — NEW-1 is an independent torn-write bug (see §6).
- **No parallel cache / metrics / scheduled job** added — the existing heal cron is the backstop.
- **ITs:** the v2 Testcontainers lane is **BROKEN (SBDEV-2217)** — gate on unit tests + `mvn clean compile` + context-load; write ITs but leave them `@Disabled("SBDEV-2217")` with a TODO.

---

## 5. Changes by File

### 5.0 Invariants

- **I-1 (FK + reservation preserved):** the sync rewrites `requestedlocationId` + `requestedrackId` + `sourcelocationname` ONLY. It NEVER changes `stockunitId`, `reservedamount`, or `requestedamount`. A location move does not change *which* stock backs the replen or *how much* is reserved — only *where it lives*. Do not call `changeReservedAmount`.
- **I-2 (atomic per move tree):** the sync runs inside the move's single tenant transaction (REQUIRED propagation). A later `BusinessException` in the same move rolls back ALL `setStoragelocationId` writes, all SBDEV-2481 realigns, AND all replen syncs — no partial state (AC8).

### 5.1 NEW: `ReplenishmentOrderSourceSyncService.java` (service) — Fix A

**Why:** the design gap (RC1) — the move relocates the UL but never re-points the bound replen's source triple. A shared, repos-only, acyclic service re-points it per moved SU.

**v2 fix (Option B, RECOMMENDED — pessimistic):**

```java
@Service
// NO class-level @Transactional. The method joins the caller's tenant tx
// (UnitloadBusinessService.transferUnitLoadToLocation is @Transactional(tenantTransactionManager)).
// A bare @Transactional would route to the @Primary landlord TM (NEW-3). REQUIRED propagation is
// implicit by not annotating — but findByIdForUpdate is illegal outside a tx, so the call path
// MUST always be transactional (asserted by AC11 + NEW-3 guard).
public class ReplenishmentOrderSourceSyncService {

    private final ReplenishorderRepository replenishorderRepository;   // constructor-injected, repos only (acyclic)
    private final LocationRackRepository  locationRackRepository;

    public ReplenishmentOrderSourceSyncService(ReplenishorderRepository replenishorderRepository,
                                               LocationRackRepository locationRackRepository) {
        this.replenishorderRepository = replenishorderRepository;
        this.locationRackRepository = locationRackRepository;
    }

    /** Re-point the source triple of any active (state < FINISHED) replen bound to the moved SU
     *  onto the destination location. Same-SU, location-only: reservation + stockunitId untouched (I-1).
     *  Blocks (throws) if the replen is already STARTED (>=500, incl. 530). Option B locks the row via
     *  findByIdForUpdate to serialize with the maintenance cron (must be inside the tenant tx). */
    public void syncForMovedStockUnit(Stockunit su, Location destinationLocation) throws BusinessException {
        Replenishorder probe = replenishorderRepository
            .findByStateLessThanAndStockunitId(WmsConstants.State.FINISHED, su.getId())
            .orElse(null);
        if (probe == null) {
            return;                                                 // AC7: no active replen -> no write
        }
        // Option B: lock + re-read to serialize with the cron's PESSIMISTIC_WRITE on the same row.
        // findByIdForUpdate is legal here because the call path is always inside the move's tenant tx
        // (warning documented at ReplenishmentOrderMaintenanceService:73-77; cron uses it at :154). (AC12)
        Replenishorder ro = replenishorderRepository.findByIdForUpdate(probe.getId())
            .orElseThrow(() -> new EntityNotFoundException("Replenishorder", probe.getId()));
        if (ro.getState() >= WmsConstants.State.STARTED) {          // decisions 2+6: block in-progress (incl. 530)
            throw new BusinessException(
                "Replenishment in progress for this stock; complete or cancel it before moving.");
        }
        // Tolerant rack resolution (G3 — REVERSED to tolerant by code review). Location.rackId is
        // nullable (dock/floor/staging; ~7% of locations on wms2-wineco-dev). A rackless destination
        // must NOT throw — mirrors the cron's own tolerant re-point (ReplenishmentOrderMaintenanceService:343).
        // A *non-null* rackId that fails to resolve is still a genuine data error and throws.
        // (Strict .orElseThrow — the pre-review choice — would 500 + roll back the whole move; redirectSource:188
        //  can be strict because its destination is an SU's current racked location, but this move path
        //  can target any location.)
        Long rackId = destinationLocation.getRackId() == null ? null
            : locationRackRepository.findById(destinationLocation.getRackId())
                .orElseThrow(() -> new EntityNotFoundException("LocationRack", destinationLocation.getRackId()))
                .getId();

        ro.setRequestedlocationId(destinationLocation.getId());     // setRequestedlocationId :136
        ro.setRequestedrackId(rackId);                              // setRequestedrackId :144 (null-tolerant)
        ro.setSourcelocationname(destinationLocation.getName());    // setSourcelocationname :88 (getName :83)
        // ro.stockunitId (:152) / reservedamount / requestedamount UNCHANGED (I-1)
        replenishorderRepository.save(ro);
    }
}
```

> **Option A variant (alternative, no `findByIdForUpdate`):** drop the lock+re-read; operate on `probe` directly, re-check `getState()`, `save`. Relies on `@Version` → 409 `retryable:true` + cron backstop. AC12 then asserts "no `findByIdForUpdate`, relies on `@Version`." See §ADR.

> **Signature notes (verified on branch):** `findByStateLessThanAndStockunitId(Integer,Long):Optional<Replenishorder>` at `ReplenishorderRepository.java:91-92`; `findByIdForUpdate(Long)` PESSIMISTIC_WRITE at `ReplenishorderRepository.java:27-29` (the method itself, no comment — line 75 of that file is the `findByStateLessThanAndKeyword` JPQL fragment); the "throws outside a tx" warning is at `ReplenishmentOrderMaintenanceService.java:73-77`; cron lock at `ReplenishmentOrderMaintenanceService.java:154`. `Replenishorder.getSourcelocationname:84`/`set:88`, `getState:92`, `setRequestedlocationId:136`, `setRequestedrackId:144`, `getStockunitId:148`/`set:152`. `Location.getName():83`, `getRackId():107`. `LocationRackRepository.findById` present. **Rack resolution: TOLERANT of a null `rackId` (G3 — reversed to tolerant by code review, 2026-06-26)** — `Location.rackId` is nullable (~7% rackless on `wms2-wineco-dev`); a rackless destination sets `requestedrackId=null` with no lookup (mirrors the cron at `ReplenishmentOrderMaintenanceService:343`), while a non-null rackId that fails to resolve still `.orElseThrow`s. Strict `.orElseThrow` on the raw `getRackId()` (the pre-review choice modelled on `redirectSource:188`) would 500 + roll back the whole move for rackless destinations — a regression `redirectSource` doesn't have because its destination is always an SU's racked location.

### 5.2 `UnitloadBusinessService.java:290-296` — Fix A hook

**Current (SBDEV-2481, verified):**
```java
290:        if (PickLineActivityCodeClassifier.classify(activityCode, null) == PickLineActivityCodeClassifier.Bucket.BLOCK_REALIGN) {
291:            for (Stockunit movedStockUnit : stockunitRepository.findByUnitloadId(unitload.getId())) {
292:                pickLineRealignmentService.assertNoActivePickFor(movedStockUnit.getId());
293:                pickLineRealignmentService.realignForMovedStockUnit(movedStockUnit, unitload, destinationLocation);
294:            }
295:        }
```

**v2 fix (add one line at :294, inside the existing loop):**
```java
293:                pickLineRealignmentService.realignForMovedStockUnit(movedStockUnit, unitload, destinationLocation);
294:                replenishmentOrderSourceSyncService.syncForMovedStockUnit(movedStockUnit, destinationLocation);   // SBDEV-2492
```

**Why:** reuses the SBDEV-2481 classifier (correct scope: `CODE_TRANSFER`/`CODE_MANUAL_TRANSFER` move; PASS_THROUGH on shipping/split — AC5/AC6 for free), the already-acquired entry-method PO locks, and the recursion over the whole pallet tree (AC1/AC3). Inject `replenishmentOrderSourceSyncService` as a constructor param + final field beside the existing collaborators (final fields :55, ctor :60-80). **Do NOT** add `stockrecordService` / `recordRelocation` to this method (the 260624 verify script asserts that lives elsewhere — negative check in §8).

### 5.3 `MobileMoveUnitloadService.checkReservedStock:188-203` — Fix B

**Current (verified):**
```java
195:                Replenishorder replenishOrder = replenishorderService.existsForStockUnit(stockUnit);
196:                if (replenishOrder != null) {
197:                    replenishorderService.cancelReplenishmentOrder(replenishOrder);   // DESTRUCTIVE
198:                    continue;
199:                }
200:                throw new BusinessException("Reserved stock! can not move unit load " + unitLoad.getLabelid());
```

**v2 fix:**
```java
195:                Replenishorder replenishOrder = replenishorderService.existsForStockUnit(stockUnit);
196:                if (replenishOrder != null) {
197:                    // SBDEV-2492: a valid active replen against this reserved stock is no longer
198:                    // cancelled on move. The source triple is re-pointed at the choke point
199:                    // (ReplenishmentOrderSourceSyncService inside processTransfer); let the move proceed.
200:                    continue;
201:                }
202:                throw new BusinessException("Reserved stock! can not move unit load " + unitLoad.getLabelid());
```

**Why:** cancelling a valid in-flight replen because its source pallet physically moved is data loss (RC2). The correct response is to re-point at the choke point. The reserved-but-no-replen `throw` is a legitimate guard and is **kept**. (`existsForStockUnit:275`, `cancelReplenishmentOrder:202` exist; verify script greps for the *absence* of `cancelReplenishmentOrder` in this file.)

### 5.4 `ReplenishorderService.redirectSource:170-199` — Fix C (one line, partially done)

**Current (verified — sets 2 of 3):**
```java
190:        replenishOrder.setStockunitId(stockUnit.getId());
191:        replenishOrder.setRequestedlocationId(location.getId());
192:        replenishOrder.setRequestedrackId(rack.getId());
193:        replenishorderRepository.save(replenishOrder);
```

**v2 fix (add the missing name-set before save; `location` in scope at :186):**
```java
191:        replenishOrder.setRequestedlocationId(location.getId());
192:        replenishOrder.setRequestedrackId(rack.getId());
193:        replenishOrder.setSourcelocationname(location.getName());   // SBDEV-2492: keep the source NAME in sync too
194:        replenishorderRepository.save(replenishOrder);
```

**Why:** this admin/different-SU re-point left `sourcelocationname` pointing at the old location even on a deliberate re-point. Purely additive. Leave `changeReservedAmount` unreserve(:178)/reserve(:195) + `setStockunitId`(:190) **untouched** — this path legitimately hands the reservation to a different SU (do not conflate with the same-SU sync).

---

## 6. NEW v2-Only Issues

These do not exist in v1 (v1 is single-replica and routes all writes to one TM). They surface from v2's tenant/landlord routing model.

| ID | Sev | Site | Issue | Recommendation |
|----|-----|------|-------|----------------|
| **NEW-1** | **HIGH** | `StockunitService.setLockOnHold:296-345` | **Dual-TM torn write.** `setLockOnHold` has **NO `@Transactional`** (siblings at `:149`/`:446` do; `:296` does not). At `:337` it calls a **different bean** — `unitloadBusinessService.transferUnitLoadToLocation` (`@Transactional(tenantTransactionManager):113`) — so via the Spring proxy a **tenant tx DOES begin and commit** for the relocation + the new SBDEV-2492 re-point. But then, **back in `setLockOnHold` with no tx**, the hold flag write (`setEntityLock` + `stockunitRepository.save:338-340`) and `sendStockChangeMessage:345` run in **landlord auto-commit** (landlord is `@Primary`), **after** the tenant tx already committed → a **torn write**: the UL is relocated and the replen re-pointed, but if the post-call landlord write fails the stock is **NOT held** (and `bulkSetLockOnHold` loops it → partial holds across the batch). `findByIdForUpdate` is *legal* here (it runs inside the inner tenant tx), so this is **independent of Option B**. | **Include as Phase 0 in THIS plan:** add `@Transactional(value="tenantTransactionManager", rollbackFor={BusinessException.class, FacadeException.class})` to `setLockOnHold`. Justification: the new sync now fires on the on-hold path, so the hold flag must commit **atomically** with the relocation + re-point (extends I-2/AC8 to this entry). *Alternative:* split into a sibling ticket — but the new sync makes the torn-write window land on a re-pointed replen, so co-shipping is strongly preferred. |
| **NEW-2** | MEDIUM | `StockunitService.setLockOnHold` | Uses plain `findById` (no `findByIdForUpdate`) for the on-hold unit-load read → unserialized concurrent on-hold + move on the same UL. | Flag; lower priority. May stay deferred unless the critic escalates; tracked as an open item. |
| **NEW-3** | design guard | `ReplenishmentOrderSourceSyncService` (new) | The new service must use **constructor injection** and carry **no bare `@Transactional`** (bare routes to the `@Primary` landlord TM). It joins the caller's tenant tx (REQUIRED propagation). Under Option B it calls `findByIdForUpdate`, which throws `InvalidDataAccessApiUsageException` outside a tx. | Verify the call path is always transactional: `transferUnitLoadToLocation` is `@Transactional(tenantTransactionManager)` on **all four** BLOCK_REALIGN entries, **including** the on-hold path (the `setLockOnHold → transferUnitLoadToLocation` cross-bean call crosses a proxy boundary, so a tenant tx begins) — so `findByIdForUpdate` is legal regardless of NEW-1. AC11 (context-load, no DI cycle) guards the wiring; AC13 guards NEW-1's atomicity (a separate concern). |

---

## 7. Implementation Priority

Sequence: **Phase 0 (NEW-1) → new service + hook (Fix A) → Fix B → Fix C → tests → verify.**

### 7.1 Prerequisites

| # | Prerequisite | Required value / action | Notes |
|---|--------------|------------------------|-------|
| 1 | **Database state** | No schema change; `replenishorder` columns (`stockunit_id`, `requestedlocation_id`, `sourcelocationname`, `requestedrack_id`, `state`, `version`) all exist in v2. | Re-confirm against `wms2-wineco-dev`. |
| 2 | **Feature flags / sysprops** | **N/A** — always-on. A flag would leave the destructive cancel-on-move reachable. | |
| 3 | **Config / env** | **N/A** — no new dependency. **`spring-retry` is NOT added** (and is absent); `OptimisticLockRetry` is **not** re-wired into the move path (its move-path call sites were removed in `895ee9f`; the class itself stays for `MobilePalletizingService`). | |
| 4 | **Deploy-order dependencies** | SBDEV-2481 must be on the target branch first — this plan hooks **inside** its `BLOCK_REALIGN` block. (Already on `port/SBDEV-2492-replen-source-sync`.) | Hard dependency. |
| 5 | **Data migration / backfill** | **N/A.** The existing v2 heal cron heals stale `state=300` rows on its cadence; once Fix A ships no *new* stale rows are produced; in-flight stale rows heal on the next pass. | DBA: none |
| 6 | **External systems** | **N/A** | |
| 7 | **Access / permissions** | **N/A** | |
| 8 | **Monitoring** | Schedule the §1 stale-source detector; **alert on count > 0 sustained across more than one maintenance interval** (a brief non-zero window is normal between a move and the cron pass). | Reuses the §1 SQL |

### 7.2 Implementation Checklist

- [ ] **Phase 0 — NEW-1 (HIGH, independent of Option B).** Add `@Transactional(value="tenantTransactionManager", rollbackFor={BusinessException.class, FacadeException.class})` to `StockunitService.setLockOnHold:296`. Confirm `bulkSetLockOnHold` callers still compile. Rationale: the new sync now fires on the on-hold path, so the hold flag (`setEntityLock`+`save:338-340`) and `sendStockChangeMessage:345` — currently landlord auto-commit **after** the inner tenant tx commits — must commit **atomically** with the relocation + re-point (extends I-2/AC8 to this entry; closes the dual-TM torn-write window). Not gated on Option B — `findByIdForUpdate` is already legal on this path via the inner tenant tx.
- [ ] **Step 1 — new service.** Create `ReplenishmentOrderSourceSyncService` (constructor injection, repos only, acyclic; **no bare `@Transactional`** — NEW-3). Implement `syncForMovedStockUnit`: finder → null-return (AC7) → (Option B) `findByIdForUpdate` lock+re-read (AC12) → `>=STARTED` block incl. 530 (AC9) → re-point triple `save` (AC1) preserving `stockunitId`+reservation (I-1).
- [ ] **Step 2 — Fix A hook.** Constructor-inject `replenishmentOrderSourceSyncService` into `UnitloadBusinessService`; add the call at `:294` inside the `BLOCK_REALIGN` loop, after `realignForMovedStockUnit`. Confirm per-SU recursion over the tree. Do NOT add `stockrecordService`.
- [ ] **Step 3 — Fix B.** `MobileMoveUnitloadService.checkReservedStock:197` — remove `cancelReplenishmentOrder`; keep the `:200` throw. Update `MobileMoveUnitloadServiceUnitTest` (AC4).
- [ ] **Step 4 — Fix C.** `ReplenishorderService.redirectSource` — add `setSourcelocationname(location.getName())` before the `:193` save. Update `ReplenishorderServiceUnitTest` (AC10).
- [ ] **Step 5 — tests.** Unit per §8; ITs written but `@Disabled("SBDEV-2217")`.
- [ ] **Step 6 — gates.** `mvn clean compile` + context-load (cycle gate, AC11) green; targeted `mvn test` green; verify script 0 FAIL.

---

## 8. Testing Plan

> **v2 gate:** unit test per change (Mockito; **v2 CAN `mockStatic`** — unlike v1). ITs written but `@Disabled("SBDEV-2217")` (Testcontainers lane cannot boot). Hard gates: `mvn clean compile` + `OmsNotificationConfigContextLoadTest`-style context-load + targeted `mvn test`. Verify script 0 FAIL.

### Unit tests (Mockito)

`ReplenishmentOrderSourceSyncServiceTest`:

| Test | Asserts | AC |
|------|---------|----|
| `sync_noActiveReplen_noWrite` | finder empty → no `findByIdForUpdate`, no `save`, no exception | AC7 |
| `sync_processable_repointsTriple` | state 300 → `requestedlocationId`==dest.id, `requestedrackId`==dest rack, `sourcelocationname`==dest.name; `save` called | AC1 |
| `sync_reserved_repointsTriple` | state 400 (RESERVED) → re-pointed | AC1 |
| `sync_keepsStockUnitIdAndReservation` | `setStockunitId` / reservation setters NEVER called | I-1 |
| `sync_started_throwsBusinessException` | state 500 → `BusinessException`, no `save` | AC9 |
| `sync_clubRunFinished530_throwsBusinessException` | state 530 → blocked by `>=STARTED` | AC9 |
| `sync_locksViaFindByIdForUpdate` (Option B) | `findByIdForUpdate(probe.id)` invoked before write; write operates on the re-read row | **AC12** |

`UnitloadBusinessServiceReplenSyncTest` (or extend the existing unit test):

| Test | Asserts | AC |
|------|---------|----|
| `processTransfer_blockRealign_callsReplenSyncPerSu` | `syncForMovedStockUnit` invoked once per SU inside `BLOCK_REALIGN` | AC1 |
| `processTransfer_movedUlDirectlyBacksReplen_synced` | the top-level SU on the moved UL itself (not a child) gets synced | AC2 |
| `processTransfer_passThroughCode_skipsReplenSync` | shipping/truck-load/split code → never called | AC5, AC6 |
| `processTransfer_childTree_syncsDeepest` | recursion reaches a nested child UL's SU | AC3 |

`MobileMoveUnitloadServiceUnitTest` (modify):

| Test | Asserts | AC |
|------|---------|----|
| `checkReservedStock_activeReplen_doesNotCancel` | `cancelReplenishmentOrder` NEVER called for a found valid replen; move proceeds | AC4 |
| `checkReservedStock_reservedNoReplen_throws` | reserved with no replen → still throws | — |

`ReplenishorderServiceUnitTest` (modify):

| Test | Asserts | AC |
|------|---------|----|
| `redirectSource_setsSourcelocationname` | `setSourcelocationname(location.getName())` invoked; reserve/unreserve + `setStockunitId` unchanged | AC10 |

`StockunitServiceLockOnHoldTxTest` (Phase 0, if NEW-1 included):

| Test | Asserts | AC |
|------|---------|----|
| `setLockOnHold_carriesTenantTransactional` | `setLockOnHold` annotated `@Transactional(value="tenantTransactionManager", rollbackFor=...)` (reflection / context-load assertion) | **AC13** |

### Integration tests (`@Disabled("SBDEV-2217")` — written, not executable)

`ReplenishmentOrderSourceSyncIT` (AC1–AC11): parent-pallet move syncs child replen; multi-level nesting reaches deepest child (AC3); reserved replen not cancelled (AC4); split/shipping skip (AC5/AC6); no-replen moves cleanly (AC7); **later throw rolls back the whole tree (AC8)**; STARTED + 530 block (AC9); `redirectSource` sets name e2e (AC10); context loads, no DI cycle (AC11).

`MoveCronConcurrencyIT` (Option B — AC12): a concurrent cron heal holds `findByIdForUpdate` on the same row; the move's `syncForMovedStockUnit` blocks on the lock then proceeds (serialized), no 409. (Option A variant: asserts the move surfaces a 409 `retryable:true` the client retries — choose per the ADR outcome.)

> All IT bodies carry `// TODO(SBDEV-2217): un-disable when the v2 Testcontainers lane boots.`

### AC → test-class map (every AC unit-testable)

| AC | Behavior | Test class :: method |
|----|----------|----------------------|
| AC1 | PROCESSABLE/RESERVED re-point the triple | `ReplenishmentOrderSourceSyncServiceTest::sync_processable_repointsTriple` / `sync_reserved_repointsTriple` |
| AC2 | **moved UL directly backs the replen** (the SU is on the moved UL itself, not a nested child — distinct from AC3) | `UnitloadBusinessServiceReplenSyncTest::processTransfer_movedUlDirectlyBacksReplen_synced` (unit: the top-level SU in the `findByUnitloadId` loop gets `syncForMovedStockUnit`); IT `ReplenishmentOrderSourceSyncIT::movedUlDirectlyBacksReplen_synced` (@Disabled SBDEV-2217) |
| AC3 | recursion reaches deepest child SU (nested child UL) | `UnitloadBusinessServiceReplenSyncTest::processTransfer_childTree_syncsDeepest` |
| AC4 | reserved replen NOT cancelled (Fix B) | `MobileMoveUnitloadServiceUnitTest::checkReservedStock_activeReplen_doesNotCancel` |
| AC4b (R-5 kept guard) | reserved stock with NO backing replen still throws | `MobileMoveUnitloadServiceUnitTest::checkReservedStock_reservedNoReplen_throws` |
| AC5/AC6 | PASS_THROUGH (split/shipping/truck-load) skip sync | `UnitloadBusinessServiceReplenSyncTest::processTransfer_passThroughCode_skipsReplenSync` |
| AC7 | no active replen → no write | `ReplenishmentOrderSourceSyncServiceTest::sync_noActiveReplen_noWrite` |
| AC8 | whole-tree atomic rollback (REQUIRED, joins move tx) | `ReplenishmentOrderSourceSyncIT::laterScanThrow_rollsBackSync` (@Disabled SBDEV-2217); + I-2 review |
| AC9 | state>=STARTED blocks (incl. 530) | `ReplenishmentOrderSourceSyncServiceTest::sync_started_throwsBusinessException` / `sync_clubRunFinished530_throwsBusinessException` |
| AC10 | `redirectSource` sets `sourcelocationname` | `ReplenishorderServiceUnitTest::redirectSource_setsSourcelocationname` |
| AC11 | context loads, no DI cycle | context-load test (e.g. `OmsNotificationConfigContextLoadTest`-style) |
| **AC12** | chosen concurrency mechanism — Option B: locks via `findByIdForUpdate` | `ReplenishmentOrderSourceSyncServiceTest::sync_locksViaFindByIdForUpdate`; `MoveCronConcurrencyIT` (@Disabled) |
| **AC13** | (Phase 0) `setLockOnHold` carries tenant `@Transactional` | `StockunitServiceLockOnHoldTxTest::setLockOnHold_carriesTenantTransactional` |

### Manual test plan

| # | Scenario | Env | Steps | Expected | Pass/Fail |
|---|----------|-----|-------|----------|-----------|
| 1 | Parent-pallet move, child backs PROCESSABLE replen | staging mobile | move parent A→B | replen source now B; no "no unit load at …" | |
| 2 | Moved UL directly backs replen | staging | web manual move | replen re-pointed | |
| 3 | Reserved stock, active replen | staging mobile | move UL backing reserved `300` replen | move succeeds; replen NOT cancelled; re-pointed | |
| 4 | STARTED replen | staging mobile | move UL backing `500` replen | blocked (422); old location intact | |
| 5 | Manual split | staging mobile | split a SU backing a replen | split succeeds; replen untouched | |
| 6 | Outbound move | staging | ship / truck-load a UL | not blocked, not re-pointed | |
| 7 | No active replen | staging | move a UL with no backing replen | moves cleanly | |
| 8 | Admin redirectSource | staging | re-point a replen via admin | `sourcelocationname` updated | |
| 9 | On-hold move (NEW-1) | staging mobile | set-lock-on-hold a SU backing a replen | hold + sync atomic; on failure no partial hold | |
| 10 | DB sanity | staging DB | run §1 detector after a move | brief non-zero window, then 0 (no sustained mismatch) | |

### Test execution (fill in after running)

| Command | Result | Pass/Fail/Skipped |
|---------|--------|-------------------|
| `mvn clean compile` (cycle gate) | _to fill_ | |
| context-load test | _to fill_ | |
| `mvn test -Dtest=ReplenishmentOrderSourceSyncServiceTest` | _to fill_ | |
| `mvn test -Dtest=UnitloadBusinessServiceReplenSyncTest` | _to fill_ | |
| `mvn test -Dtest=MobileMoveUnitloadServiceUnitTest,ReplenishorderServiceUnitTest` | _to fill_ | |
| `mvn test -Dtest=StockunitServiceLockOnHoldTxTest` (Phase 0) | _to fill_ | |
| `RUN_MVN=1 bash sbdocs/9-System/scripts/verify-SBDEV-2492-replen-order-source-sync-on-unitload-move.sh` (the **rewritten v2** script — PROJECT_ROOT defaults to v2/wms2-api; ITs SKIP with SBDEV-2217) | _to fill_ | 0 FAIL |

### Deliberately-skipped coverage

| What | Why |
|------|-----|
| Executable ITs | v2 Testcontainers lane blocked by SBDEV-2217; ITs written + `@Disabled` with TODO. AC8 + AC12 rest on unit tests + static review until the lane is restored. |
| One-off backfill SQL | N/A — heal cron heals stale rows; no new stale rows after Fix A. |

---

## 7-template. Horizontal Scalability Validation (v2 — MANDATORY)

| # | Concern | Does this change… | Verdict | Mitigation / rationale |
|---|---------|--------------------|---------|------------------------|
| 1 | **In-JVM state** | new Caffeine/`ConcurrentHashMap`/static/`ThreadLocal`? | **No** | New service holds only injected repos; no per-replica state. |
| 2 | **Connection pool math** | change per-request DB connection usage? | **No** | The re-point runs inside the existing move tx on the move's single connection; no new pool, no new tenant, no extra connection held beyond the move's (the added repo calls reuse that one connection). |
| 3 | **Scheduled jobs** | add/modify a `@Scheduled`/cron? | **No** | No job added; the existing heal cron is unchanged and remains the backstop. |
| 4 | **Long transactions** | hold a tx across extra repo calls / external I/O? | **Yes** | The sync adds **up to 4 repo calls per active replen per moved SU** inside the **existing** move tx: `findByStateLessThanAndStockunitId` (finder, ≤1 row) + `findByIdForUpdate` (Option B lock) + `LocationRack findById` + `save`. No external I/O. Critically, the `findByIdForUpdate` takes a `PESSIMISTIC_WRITE` row lock that is **held for the remainder of the recursive whole-tree move tx** (released only at commit/rollback). Evidence: `UnitloadBusinessService.transferUnitLoadToLocation` is `@Transactional(tenantTransactionManager)`; calls are O(active replens in tree). A large pallet tree with several active replens holds several replen row locks until the move commits. Bounded by the move's own duration; see row 8 for the cron-collision wait. **Row to watch.** |
| 5 | **Request affinity** | assume follow-up lands on the same replica? | **No** | Fully stateless; no session/SSE/WebSocket. |
| 6 | **Retry / idempotency** | rely on single-execution semantics that break on replica death + retry? | **Yes — addressed** | The re-point is **value-idempotent**: re-applying the same destination triple produces the same final state, though each re-save still bumps `@Version` and writes the row (it is not a literal no-op). Under Option B the `findByIdForUpdate` lock serializes a cron-vs-move collision (no lost update); under Option A a 409 `retryable:true` lets the client re-drive. **The `OptimisticLockRetry` wrapper is NOT wired into the move path** (call sites removed `895ee9f`; would never fire inside the open tx; class still exists for `MobilePalletizingService`). Evidence: `RestExceptionHandler:144-150`; `OptimisticLockRetryScopeTest`. **Row to watch.** |
| 7 | **Tenant context** | use `TenantContext`/`ThreadLocal` across async boundaries? | **No** | Synchronous, inside the move's tenant tx; no `@Async`/`CompletableFuture`. |
| 8 | **Distributed lock correctness** | add/rely on pessimistic/optimistic lock across replicas? | **Yes (Option B)** | Option B adds `findByIdForUpdate` (PESSIMISTIC_WRITE) on `replenishorder`. **Must be inside `@Transactional(tenantTransactionManager)`** (NEW-3) — the warning is at `ReplenishmentOrderMaintenanceService.java:73-77`. **Lock-acquisition order (explicit):** the move tx first holds the SBDEV-2481 owning-PO/CO locks + the `unitload` row(s), **then** takes `findByIdForUpdate` on each `replenishorder` per SU in tree-iteration order. The maintenance cron locks **one** `replenishorder` row at a time (`ReplenishmentOrderMaintenanceService.java:154`) and **never** takes a PO/CO or unitload lock under PESSIMISTIC_WRITE. **No deadlock cycle is possible:** a cycle requires two transactions each holding a lock the other wants; the cron only ever holds a single `replenishorder` lock and requests nothing else under write-lock, so it cannot hold something the move needs while waiting on the move — the worst case is a one-directional **wait** (the move blocks on a replen row the cron is healing; row 8 ↔ R-9), not a cycle. Two concurrent moves both order locks PO/CO → unitload → replenishorder consistently, so they cannot cycle either. Optimistic `@Version` remains the backstop. Evidence: `ReplenishorderRepository.java:27-29`; `ReplenishmentOrderMaintenanceService.java:154`; SBDEV-2481 PO/CO lock pattern. **Row to watch.** |
| 9 | **Cache invalidation** | write to a cached entity? | **No** | `Replenishorder` is not cached (no Caffeine/`@Cacheable` on it). |
| 10 | **External notifications** | send HTTP/message to an external system inside a tx? | **No** | No OMS/printer notification added in this path. The cron-shared row is touched, but writes are DB-only and commit atomically with the move. **Row to watch (cron-shared row):** the only cross-replica interaction is the cron vs. move on this row, covered by rows 6 + 8. |

### Evidence (for "Yes" rows)

| Concern # | What was verified | File:line / test |
|-----------|-------------------|------------------|
| 4 | Sync runs inside the move tx; up to 4 indexed repo calls per active replen per SU; row lock held to commit; no external I/O | `UnitloadBusinessService.transferUnitLoadToLocation` `@Transactional(tenantTransactionManager):113`; `ReplenishorderRepository.java:91-92`, `:27-29` |
| 6 | Value-idempotent re-point; `OptimisticLockRetry` not wired into the move path (call sites removed; class still used by `MobilePalletizingService`); 409 path documented | `RestExceptionHandler:144-150`; `OptimisticLockRetryScopeTest`; commit `895ee9f` |
| 8 | Pessimistic lock inside tenant tx; same row the cron locks; lock order PO/CO→unitload→replenishorder; cron holds ≤1 replen lock and requests nothing else → no cycle | `ReplenishorderRepository.findByIdForUpdate` `ReplenishorderRepository.java:27-29`; cron `ReplenishmentOrderMaintenanceService.java:154`; warning `ReplenishmentOrderMaintenanceService.java:73-77` |

---

## 9. Risk Assessment

| ID | Risk | Impact | Mitigation |
|----|------|--------|-----------|
| R-1 | Sync **halts shipping / truck-load / split** | Critical | Runs only inside SBDEV-2481's `BLOCK_REALIGN` block; PASS_THROUGH never reaches it. Unit `processTransfer_passThroughCode_skipsReplenSync` + IT AC5/AC6. |
| R-2 | **Spring context cycle (HARD startup failure)** | Startup fails | New service injects **repositories only** (constructor); never `ReplenishorderService`/`*BusinessService`. Acyclic; `mvn clean compile` + context-load (AC11). |
| R-3 | **Cron-vs-move write conflict** on the same `replenishorder` row (multi-replica) | 409 (Option A) or server-side lock wait (Option B) | **Option B (recommended):** `findByIdForUpdate` serializes with the cron inside the move tx — converts the 409 into a lock wait (AC12); see R-9 for the wait's bound. **Option A:** `@Version` → 409 `retryable:true` (`RestExceptionHandler:144-150`) → client retries; cron backstop. **NOT** the v1 `OptimisticLockRetry` move-path wrapper (call sites removed in v2; would never fire — `OptimisticLockRetryScopeTest` pins non-injection into the move services). |
| R-4 | Wider block radius — a STARTED/530 replen refuses the whole move | Medium | Intended (decisions 2+6). Whole-tree granularity: one STARTED child replen fails the **entire** move atomically (I-2/AC8). Call out in operator docs; surfaced as 422. |
| R-5 | Removing cancel-on-move (Fix B) strands reserved stock that should not move | Low | Reserved-but-no-replen `throw` kept; only the valid-replen branch changes cancel→proceed; choke-point sync re-points. Tested by `checkReservedStock_reservedNoReplen_throws` (kept guard) + AC4 (valid replen not cancelled). |
| R-6 | Per-SU finder/lock on every BLOCK_REALIGN move (perf) | Latency | `findByStateLessThanAndStockunitId` indexed, ≤1 row; runs only on BLOCK_REALIGN codes; Option B adds one `findByIdForUpdate` + one `LocationRack findById` per active replen (rare). |
| R-7 | **NEW-1**: `setLockOnHold` dual-TM **torn write** | High (relocated + re-pointed but NOT held; `bulkSetLockOnHold` → partial holds) | The inner `transferUnitLoadToLocation` commits its tenant tx (relocation + re-point); the subsequent hold-flag write + `sendStockChangeMessage` run in **landlord auto-commit** afterward. Phase 0 adds `@Transactional(tenantTransactionManager, rollbackFor=…)` to `setLockOnHold` so the hold commits **atomically** with the relocation + re-point (AC13). **Independent of Option B** — `findByIdForUpdate` is already legal on this path via the inner tenant tx. |
| R-8 | Re-wiring the removed `OptimisticLockRetry` into the move path / adding `@Retryable` | Test failure + dead code | Verify-script NEGATIVE checks guard against (a) injecting `OptimisticLockRetry` into the move controllers/services and (b) any `@Retryable`; `OptimisticLockRetryScopeTest` pins non-injection; no `spring-retry` in `pom.xml`. (The class itself legitimately remains for `MobilePalletizingService`.) |
| R-9 | **Option B lock wait** — a move hits a `replenishorder` row the cron is currently healing under `findByIdForUpdate` (`ReplenishmentOrderMaintenanceService:154`) | Medium (operator-perceived **stall**, not a 409) | The move **blocks** until the cron tx commits/rolls back. The wait is bounded only if the tenant datasource sets `lock_timeout` / `jakarta.persistence.lock.timeout`; **flag for the implementer to verify the tenant datasource lock timeout — if none is configured, the wait is `lock_timeout`/indefinite.** This is the honest cost of Option B over Option A (which would surface a retryable 409 instead). No deadlock (one-directional wait — §7 row 8). |

### Acceptance script

`sbdocs/9-System/scripts/verify-SBDEV-2492-replen-order-source-sync-on-unitload-move.sh` — **this file was already on disk as the V1 script and has been OVERWRITTEN to the v2 spec** (not "copied from template"). The v1 version defaulted `PROJECT_ROOT` to `v1/wms-api`, asserted the **dropped** Decision-5 controller-wrap (checks `D5a`–`D5f` for `OptimisticLockRetry.executeWithRetry` on four controllers), had no NEW-1 / Option-B checks, and ran the `@Disabled` Testcontainers ITs. The rewritten v2 script: defaults `PROJECT_ROOT` to `v2/wms2-api`; **deletes all `D5*` checks**; **SKIPs** the ITs with reason `SBDEV-2217`; runs `mvn` only for the §8 unit classes (incl. `StockunitServiceLockOnHoldTxTest`, gated behind `RUN_MVN=1`).

**POSITIVE checks (a–f):**
- (a) `UnitloadBusinessService` BLOCK_REALIGN loop references `replenishmentOrderSourceSyncService.syncForMovedStockUnit`.
- (b) `ReplenishmentOrderSourceSyncService.java` sets `requestedlocationId` + `requestedrackId` + `sourcelocationname`.
- (c) `>= STARTED` block present in the new service.
- (d) **Option B:** `findByIdForUpdate` present in `ReplenishmentOrderSourceSyncService`.
- (e) **NEW-1:** the `@Transactional(value = "tenantTransactionManager"` annotation sits **immediately above** `setLockOnHold` (proximity check via `awk`, so a sibling method's annotation can't pass it vacuously).
- (f) `ReplenishorderService.redirectSource` sets `sourcelocationname`.

**NEGATIVE guards (g–j):**
- (g) `MobileMoveUnitloadService.checkReservedStock` no longer calls `cancelReplenishmentOrder`.
- (h) `ReplenishmentOrderSourceSyncService` does NOT contain `@Retryable`.
- (i) **`OptimisticLockRetry` is NOT injected into the move controllers/services** (`UnitloadBusinessService`, `MobileMoveUnitloadService`, the new service) — this is the re-introduction guard, and it is what `OptimisticLockRetryScopeTest` actually pins. (The class still exists for `MobilePalletizingService`; the guard checks the move path only.)
- (j) `processTransfer` does NOT reference `stockrecordService` (don't regress 260624).

**BEHAVIOR:** `mvn clean compile` + context-load (cycle gate) + targeted `mvn test` for the named unit classes (`RUN_MVN=1`).

---

## 10. ADR — Concurrency Mechanism for the New Re-Point Write (+ Decision-5 Drop)

**Decision.** Adopt **Option B (pessimistic):** `syncForMovedStockUnit` finds the active replen via `findByStateLessThanAndStockunitId`, then `findByIdForUpdate(id)` to lock + re-read, re-checks `state>=STARTED`, then writes — inside the caller's tenant transaction. Do **not** re-wire the v1 `OptimisticLockRetry` wrapper into the move path (Decision 5).

**Drivers.**
1. Cron-vs-move write contention on a shared `replenishorder` row across replicas (the cron holds `PESSIMISTIC_WRITE`).
2. Whole-tree atomicity + the legality constraint that `findByIdForUpdate` must run inside a tx (always satisfied — the move entry is `@Transactional(tenantTransactionManager)` on all four BLOCK_REALIGN paths; NEW-3).
3. Smallest faithful diff that respects v2's removal of the move-path retry wrapper.

**Alternatives considered.**
- **Option A (optimistic-only):** rely on `@Version` + 409 `retryable:true` + cron backstop. Simpler, zero new lock, matches the SBDEV-2481 sibling's 409 reliance — but a move-vs-cron collision surfaces a client-visible 409 the operator must retry, on exactly the reporter's shape.
- **Option C (re-wire the v1 `OptimisticLockRetry` wrapper):** rejected — the move-path call sites were removed in `895ee9f`; a wrapper inside an open `@Transactional` can never fire (Hibernate throws at flush/commit, after the wrapper returns); `OptimisticLockRetryScopeTest` pins that the move services must not inject it; `spring-retry` is absent. (The class still exists for `MobilePalletizingService` — only the move-path wiring is forbidden.)

**Why chosen.** Option B serializes the new write with the cron exactly as v2's documented stance prescribes and as SBDEV-2481 already does for CO/PO rows. **It is NOT strictly superior to A** — it does not remove the contention, it relocates it from a client-retried 409 (A) to a server-side lock wait (B). We prefer B because the wait is invisible to the operator's client logic (no 409 to handle) and serializes deterministically with the cron, accepting the stall risk (R-9) as the tradeoff.

**Consequences.**
- Positive: no client-visible 409 on this path; deterministic serialization with the cron; atomic whole-tree rollback preserved.
- Negative: adds a `PESSIMISTIC_WRITE` lock held for the rest of the recursive move tx (§7 row 4); a move that collides with an in-flight cron heal **stalls** until the cron tx finishes, bounded only by the tenant datasource `lock_timeout` if configured (R-9 — flag for the implementer). It is the same single row the cron locks, so no new lock-order surface and no deadlock cycle (§7 row 8).
- **Independence note:** Option B does **not** depend on NEW-1. `findByIdForUpdate` is already legal on the on-hold path via the inner tenant tx. NEW-1 (Phase 0) is an independent torn-write fix that the new sync makes more pressing (the torn window now lands on a re-pointed replen), not a precondition for Option B's lock to be legal.

**Follow-ups.**
- Confirm the Option-A-vs-B choice with the critic/architect; if they prefer A, swap AC12 to the 409 assertion and drop `findByIdForUpdate`.
- NEW-2 (`findById` → `findByIdForUpdate` in `setLockOnHold`) tracked as a lower-priority hardening.
- G3: missing-rack fallback (raw `getRackId()` vs strict `null`).

---

## 11. Open Questions

| # | Item | Why it matters |
|---|------|----------------|
| G-A vs G-B | Option A (optimistic) vs Option B (pessimistic) for the new re-point write. | Determines whether a move-vs-cron collision is a client-retried 409 (A) or a server-side lock wait/stall (B, R-9). Recommend B; needs Architect/Critic sign-off. |
| NEW-1 scope | Include the `setLockOnHold` `@Transactional` (torn-write) fix as Phase 0 here vs a sibling ticket. | **Independent of Option B** (the inner tenant tx already makes `findByIdForUpdate` legal). The new sync makes the torn-write window land on a re-pointed replen, so co-shipping is recommended. |
| R-9 lock timeout | Verify the tenant datasource sets `lock_timeout` / `jakarta.persistence.lock.timeout` so Option B's cron-collision wait is bounded. | If none is configured, the wait is `lock_timeout`/indefinite. Implementer to confirm. |
| NEW-2 | `setLockOnHold` plain `findById` (unserialized concurrent on-hold+move). | Lower priority; flag for follow-up (may stay deferred). |
| G3 | **RESOLVED — strict `.orElseThrow`.** The new service resolves the rack via `.orElseThrow(EntityNotFoundException)` to mirror `ReplenishorderService.redirectSource:188`; the `.orElse(null)`+raw-getRackId fallback is dropped. | Consistency with the existing re-point; a valid location always has a resolvable rack, so the strict path matches the maintenance/admin contract. |
| SBDEV-2217 | ITs `@Disabled` until the Testcontainers lane boots. | AC8 + AC12 have no executable coverage until then; rest on unit tests + static review. |

These are persisted to `.omc/plans/open-questions.md`.

---

## 12. Recommended OMC Composition (for implementation)

| Aspect | Value | Rationale |
|---|---|---|
| **Size class** | Standard | 1 new service + 1 one-line hook + 2 small edits + 1 Phase-0 annotation; single subsystem. |
| **Pre-draft step** | analyst+planner (done) → ralplan consensus (Architect/Critic) | High-blast-radius shared choke point; concurrency choice + Decision-5 divergence need consensus. |
| **Plan-review step** | critic | Verify hook placement, cycle guard, and the Option A/B + NEW-1 calls. |
| **Implementation shape** | executor → `wms-tdd-gate` (write the named failing tests first) | Small, well-scoped. |
| **Verification step** | verify-script + verifier | Mandatory. `mvn clean compile` + context-load are hard gates (cycle + landlord-TM trap). |
| **Code-review step** | code-reviewer | Confirm Fix B does not strand reserved stock, sync preserves reservation (I-1), and NEW-1 routes to the tenant TM. |
| **Commit step** | git directly (single logical commit, or split Phase 0) | Depends on SBDEV-2481 already on the branch. |

---

## 13. Implementation Status

**Status:** IMPLEMENTED + CODE-REVIEWED on branch `port/SBDEV-2492-replen-source-sync`. Date: 2026-06-26. Commit `0a4d3a2` → rebased to `ad17cf3` after #52 merged → amended to **`e64b2cd`** after the code-review fix.

**Code review (separate pass, 2026-06-26):** `code-reviewer` returned REQUEST-CHANGES on one **HIGH** finding — strict `.orElseThrow` rack resolution would throw HTTP 500 + roll back the whole move when replen-backed stock moves to a **rackless** location (~7% of locations on `wms2-wineco-dev`), a regression vs. pre-SBDEV-2492 behavior and stricter than the cron it pre-empts. **Fixed:** rack resolution now tolerates a null `rackId` (sets `requestedrackId=null`, no lookup), mirroring `ReplenishmentOrderMaintenanceService:343`; a non-null rackId that fails to resolve still throws. Added unit `sync_racklessDestination_setsNullRack`. (The reviewer's MEDIUM — assert `setReservedamount` never called — was N/A: `Replenishorder` has no such setter; I-1's "reservedamount" is the Stockunit reservation the repos-only service never touches.) Re-verified: unit suite **107 run / 0 fail**; verify script **17 pass / 0 fail**. PR: [SiteBossInc/wms2-api#53](https://github.com/SiteBossInc/wms2-api/pull/53) — **MERGED → develop as squash `5415fb5`** (2026-06-26). **#52 (SBDEV-2481 re-land) merged to develop as squash `0baee3a` first; #53 then retargeted to develop + rebased (`git rebase --onto origin/develop 21370b2`) to drop the now-redundant SBDEV-2481 commit (the squash wasn't recognized as already-merged, so a plain retarget conflicted) → clean single-commit diff `e64b2cd`; re-compiled SUCCESS; merged. Both ports now in develop.**

### Changes landed (final line numbers)
| File | Change |
|------|--------|
| `service/ReplenishmentOrderSourceSyncService.java` (NEW, 88 lines) | Repos-only (`ReplenishorderRepository` + `LocationRackRepository`), constructor injection, **no `@Transactional`** (joins caller's tenant tx). `syncForMovedStockUnit`: finder → null-return (AC7) → **Option B `findByIdForUpdate` lock+re-read** (AC12) → `>= STARTED` `BusinessException` incl. 530 (AC9) → strict rack `.orElseThrow(EntityNotFoundException)` → re-point triple → save. Never touches stockunitId/reservation (I-1). No `@Retryable`. |
| `service/StockunitService.java:296` | **Phase 0 / NEW-1:** added `@Transactional(value="tenantTransactionManager", rollbackFor={BusinessException.class, FacadeException.class})` to `setLockOnHold` (was auto-committing the hold flag against the landlord TM after the relocation tx → torn write). |
| `service/UnitloadBusinessService.java:56-57,:80-81,:294` | Constructor-injected the new service; call `syncForMovedStockUnit(movedStockUnit, destinationLocation)` inside the SBDEV-2481 `BLOCK_REALIGN` loop after `realignForMovedStockUnit`. No `stockrecordService`. |
| `service/mobile/MobileMoveUnitloadService.java:196-202` | **Fix B:** removed `cancelReplenishmentOrder` from the valid-replen branch (move proceeds; sync re-points); kept the reserved-no-replen `throw`. |
| `service/ReplenishorderService.java:193` | **Fix C:** added `setSourcelocationname(location.getName())` before save; `changeReservedAmount`/`setStockunitId` untouched. |

### Tests
- **Unit (GREEN):** `ReplenishmentOrderSourceSyncServiceTest` (7: AC1/AC7/AC9/I-1/AC12), `UnitloadBusinessServiceReplenSyncTest` (4: AC1/AC2/AC3/AC5/AC6), `MobileMoveUnitloadServiceUnitTest` (AC4 + AC4b/R-5), `ReplenishorderServiceUnitTest` (AC10), `StockunitServiceLockOnHoldTxTest` (AC13). `UnitloadBusinessServiceUnitTest` got a `@Mock` for the new collaborator.
- **Integration (`@Disabled`):** `ReplenishmentOrderSourceSyncIT` (AC1–AC11) + `MoveCronConcurrencyIT` (AC12/Option B) — `@Disabled("SBDEV-2217")`, scenarios captured as stubs. **AC2/AC8/AC12 IT-level behavior has no executable coverage today** — rests on unit tests + static review until SBDEV-2217 restores the v2 IT lane.

### Verification (Java 21 via SDKMAN)
| Command | Result |
|---------|--------|
| `mvn clean compile` | BUILD SUCCESS (DI-cycle / landlord-TM compile gate, AC11) |
| `mvn test -Dtest=ReplenishmentOrderSourceSyncServiceTest,UnitloadBusinessServiceReplenSyncTest,UnitloadBusinessServiceUnitTest,MobileMoveUnitloadServiceUnitTest,ReplenishorderServiceUnitTest,StockunitServiceLockOnHoldTxTest` | `Tests run: 106, Failures: 0, Errors: 0, Skipped: 0` |
| `bash verify-SBDEV-2492-…sh` (RUN_MVN=1, independent pass) | `Result: 17 pass, 0 fail, 2 skip` (ITs skipped — SBDEV-2217) |
| `mvn verify` (full Testcontainers) | NOT run (v2 IT lane blocked by SBDEV-2217) |

### Open follow-ups
- **Merge order:** #52 (SBDEV-2481 re-land) must reach develop before #53.
- **SBDEV-2217:** flesh out the two `@Disabled` IT bodies when the v2 Testcontainers lane is restored (AC8 whole-tree rollback + AC12 cron-vs-move pessimistic-lock concurrency).
- **R-9 / lock_timeout (open question §11):** verify the tenant datasource has a bounded `lock_timeout` / `jakarta.persistence.lock.timeout`, else an Option-B move-vs-cron contention could wait indefinitely.
- **Sibling finder (Critic note):** `findByStateLessThanAndStockunitId` confirmed a derived query that filters by `stockunitId` (not the ambiguous `findByStateLessThanAndKeyword` JPQL near repo line 73).
