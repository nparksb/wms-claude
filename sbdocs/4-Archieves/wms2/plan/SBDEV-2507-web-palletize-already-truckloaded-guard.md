---
title: "SBDEV-2507 — Web Palletize (v2 port): Reject Palletizing a Parcel Already On/Shipped-With a Truck-Loaded Pallet"
ticket: "SBDEV-2507"
ticket_url: "https://app.clickup.com/t/868k7cq35"
type: "bugfix"
priority: "high"
status: archived
status_detail: "Implemented 2026-07-10 (PR #67 -> develop); ralplan consensus + code review APPROVE; 87/0 tests, verify 12/0"
project: ["wms2-api"]
version: "v2"
requester: "Nam Park"
created: "2026-07-10"
updated: "2026-07-15"
db_verified: false
related:
  - "[[SBDEV-2507-web-palletize-already-truckloaded-guard]]"
  - "[[2026-07-10-wms-v1-sync]]"
tags:
  - plan
  - wms2
  - palletizing
  - bol
  - data-integrity
---

# SBDEV-2507 — Web Palletize (v2 port): Reject Palletizing a Parcel Already On/Shipped-With a Truck-Loaded Pallet

**Ticket:** [SBDEV-2507](https://app.clickup.com/t/868k7cq35) (ST#1023, WineCo — v1 incident)
**Project:** wms2-api | **Version:** v2/wms2-api | **Type:** Bug fix (v1→v2 port of `9134417`, PR #189)
**Priority:** High (preventive parity — **the guarded gap is real in v2 specifically for data migrated from v1**)
**Status:** Reviewed — ralplan consensus (Planner → Architect ITERATE → revision → Critic APPROVE, 2026-07-10). Pending implementation approval.
**Sweep:** [[2026-07-10-wms-v1-sync]] Lane B unit 2 of 6.

> **Scope note.** v2's palletize region already received a v2-native concurrency-hardening pass (`@Transactional(tenantTransactionManager)`, sorted+locked orders, `findByIdForUpdate` on pallet/parcel/BOL) that v1 lacked when SBDEV-2507 landed. This port adds **only the SBDEV-2507 guard behavior** on that skeleton — **no new `@Transactional`, no new locking**. Line numbers verified 2026-07-10; re-verify at implementation.

---

## §1. Root Cause Analysis (v2-accurate — REVISED per Architect consensus)

**v1 incident (ST#1023, WineCo):** an operator used web Outbound Parcel Report → Palletize to re-palletize a parcel already shipped *inside* a pallet on a CLOSED BOL (order 54068, parcel `XR1781642381900`, OBOL117374), corrupting the shipment. On that v1 data, only the **pallet** was the BOL source position — the parcel had none, so the parcel-position guard found nothing.

**v2-native data is already protected against the CLOSED vector.** Both v2 truck-load paths create **per-parcel** BOL source positions (`MobileTruckLoadingService.java:257-278`; `ParcelMonitorViewService.palletiseAndTruckLoad:399-419`), and `closeBOL` flips positions to CLOSED/TRANSFER (`BillofladingService.java:353-355`, `:484/:493/:540`). So for a v2-native shipped parcel, `palletise`'s existing guard chain (`findByUnitloadLabelIdList:173` → sourceId match `:186-194` → `removeBOLPositionIfExists:197`, which throws `"already shipped!"` on CLOSED at `BillofladingPositionService:67`) already fires.

**Fix A is nevertheless required in v2, on three grounds (do NOT remove as "redundant"):**
1. **Migrated v1 data** — pre-cutover BOLs carry **pallet-only** source positions (exactly the WineCo incident shape). The parcel has no own position; the existing guard finds nothing; only a **carrier-side** guard catches it. Every v2 tenant is migrated from v1.
2. **Clean TRANSFER handling** — a parcel-own TRANSFER position hits `removeBOLPositionIfExists`'s `default` branch and throws the confusing `"Unexpected status=TRANSFER found!"` (`:69`); the carrier-side guard gives a clean shipped-message for the carrier case.
3. **Defense-in-depth** — any future load path that omits per-parcel positions re-opens the gap silently.

**Bug 2 (reuse branch):** `palletise`'s existing-pallet branch (`:146-151`) re-fetches under lock and guards `pallet.getCarrierunitloadId() != null` (`"Pallet already loaded onto a carrier"`) — a **different, complementary** signal from the mobile gate guard (a BOL *source position* exists: `getBySourceUnitLoadLabelId`). Mobile blocks that (`"Pallet already assigned to gate!"`, 4 sites); the web reuse branch does not. Fix B adds it.

---

## §2. V1 → V2 Applicability

| V1 fix (`9134417`) | V2 Verdict | Rationale |
|---|---|---|
| Fix C helpers (`assertPalletNotAssignedToGate`, `assertParcelCarrierNotShipped` + `UnitloadRepository` dep) | **Needed** (v2-adapted: constructor injection) | No shared guard exists in v2; `BillofladingPositionService` ctor `:22-28` currently 3 params |
| Fix A — carrier guard before both transfers | **Needed (CRITICAL)** | v2 gap for migrated data + TRANSFER (§1); `palletise:203`, `palletiseAndTruckLoad:353` |
| Fix B — gate guard in reuse branch | **Needed** | `:146-151` lacks it; additive next to the carrier guard |
| Fix C refactor — mobile 4 inline guards → helper | **Needed** | identical blocks at `:208-212`, `:271-275`, `:298-302`, `:316-320`; behavior-neutral |
| v1's `@Transactional(rollbackFor=…)` on both methods | **Not needed (V2 already correct — stronger)** | `:102` and `:231` already `tenantTransactionManager` + `rollbackFor` + pessimistic-lock skeleton |
| CLOSED **and** TRANSFER rejection (v1 rev-2) | **Port as-is** | `WmsConstants.BillOfLadingState` has both |
| `LOG.warn` on rejection | **Port as-is** | into both helpers |

**NEW v2-only issues: none found.** The touched region already carries more hardening than v1 (tx/locks); the hunt across both methods, the reuse branch, the mobile guards, and the helper data path surfaced nothing new.

---

## §3. Design (changes by file)

### Phase 0 — Transaction & concurrency posture
**No new `@Transactional`, no new locks.** Both callers already run in the correct tenant tx (`palletise:102`, `palletiseAndTruckLoad:231`, `rollbackFor={BusinessException, FacadeException}`). The helpers are **read-only queries** inside that tx; a rejection throws `BusinessException` (in `rollbackFor`) → the whole batch rolls back (no partial re-palletize).

### File 1 — `service/BillofladingPositionService.java` (Fix C)
Widen the constructor (`:22-28`, currently `clientService, billofladingPositionRepository, basicService`) with a 4th param + `private final UnitloadRepository unitloadRepository` (leaf repo — no DI cycle; `mvn clean compile` + context-load gate). Add:

```java
/** Reject a pallet label already used as a source on any BOL position (assigned to a gate / truck-loaded). */
public void assertPalletNotAssignedToGate(String palletLabel) throws BusinessException {
    if (palletLabel != null
            && !billofladingPositionRepository.getBySourceUnitLoadLabelId(palletLabel).isEmpty()) {
        LOG.warn("assertPalletNotAssignedToGate: pallet {} already assigned to a gate/BOL", palletLabel);
        throw new BusinessException("Pallet already assigned to gate!");   // message matches mobile exactly
    }
}

/** Reject palletizing a parcel that currently sits on a pallet already shipped on a CLOSED/TRANSFER BOL. */
public void assertParcelCarrierNotShipped(Unitload parcel) throws BusinessException {
    Long carrierId = parcel.getCarrierunitloadId();
    if (carrierId == null) return;                              // distinct branch: no carrier (AC-5)
    Unitload carrier = unitloadRepository.findById(carrierId).orElse(null);
    if (carrier == null) {                                      // distinct branch: dangling ref — fail-open (AC-6)
        LOG.debug("assertParcelCarrierNotShipped: carrier {} not found for parcel {}", carrierId, parcel.getLabelid());
        return;
    }
    boolean carrierShipped = billofladingPositionRepository.getBySourceUnitLoadLabelId(carrier.getLabelid())
        .stream().anyMatch(p -> WmsConstants.BillOfLadingState.CLOSED.equals(p.getState())
                             || WmsConstants.BillOfLadingState.TRANSFER.equals(p.getState()));
    if (carrierShipped) {
        LOG.warn("assertParcelCarrierNotShipped: parcel {} on pallet {} already shipped (closed/transfer BOL)",
                 parcel.getLabelid(), carrier.getLabelid());
        throw new BusinessException("Parcel=" + parcel.getLabelid() + " is on pallet " + carrier.getLabelid()
                + " already shipped (closed/transfer BOL)!");
    }
}
```

**Deliberate asymmetry (v1 decision, carried):** the gate helper rejects on **any** position state (matches mobile — including CANCELLED-only); the carrier helper filters to **CLOSED/TRANSFER only** (OPEN/TRUCK_LOADING/CREATED/CANCELLED = legitimate in-progress/aborted correction). Pinned by AC-2/AC-5.

### File 2 — `service/ParcelMonitorViewService.java` (Fix A + Fix B)

**Fix A — INSERTION OFFSET IS LOAD-BEARING (Critic finding 1):** insert `billofladingPositionService.assertParcelCarrierNotShipped(unitLoad);` **after the `removeBOLPositionIfExists` block (`:196-201`) and immediately before `transferUnitLoadToCarrier` (`:203`)** — NOT before the position-matching loop. Placement governs AC-7b: the v2-native parcel-own-CLOSED case must keep throwing the existing `"already shipped!"`, with Fix A reached only when the parcel has no own position (migrated shape). Same call in `palletiseAndTruckLoad` before `:353` (uses that method's locked parcel from `:333`).

**Fix B:** in the reuse branch (`:146-151`), after the `findByIdForUpdate` re-fetch, alongside (not replacing) the existing carrier guard — **using the canonical locked row's label** (Architect finding 4):

```java
billofladingPositionService.assertPalletNotAssignedToGate(pallet.getLabelid());   // Fix B — mobile parity
```

No new dependencies (service already injects `billofladingPositionService` and `unitloadRepository`).

### File 3 — `service/mobile/MobilePalletizingService.java` (Fix C refactor — behavior-neutral)
Replace the 4 inline blocks with helper calls, preserving each site's argument: `scanPallet:208-212` → `(palletLabel)`; `scanPalletBulk:271-275` → `(palletLabel)`; `scanPalletBulk:298-302` → `(palletLabel)`; `scanParcelBulk:316-320` → `(pallet.getLabelid())`. Parcel-level checks (`:185-187`, `:368-370`) untouched.

### Scope notes
- **Mobile gets NO Fix A (documented tension, Architect):** v2 mobile transfer sites carry the same structural gap **for migrated data**; "the floor can't scan a shipped parcel" is an ops assumption, not a code guarantee. Kept out of scope for v1 parity + small blast radius; **follow-up candidate**: extend Fix A to mobile transfer sites if migrated-data reconciliation flows surface it.
- **`palletiseAndTruckLoad` is dead code in v2** (no production caller; grep = tests only). Fix A applied there for parity/future-safety with **static-grep coverage only — no behavioral AC** (Critic finding 2). Implementation must also grep the controller layer once to confirm no HAL/Spring-Data-REST exposure (Critic open question).
- **TRANSFER follow-up (out of scope):** a parcel-**own** TRANSFER position on the web path still hits `removeBOLPositionIfExists`'s `"Unexpected status=TRANSFER found!"` before Fix A; Fix A cleans only the carrier-side case. Candidate: explicit TRANSFER handling in `removeBOLPositionIfExists` (likely rare on migrated data — confirm if it surfaces).

---

## §4. Prerequisites

| # | Prerequisite | Applies? | Detail |
|---|---|---|---|
| 1 | Database state | **No** | Logic guard; no schema/data/Flyway change |
| 2 | Feature flags / sysprops | **No** | Unconditional (matches mobile) |
| 3 | Config / env | **No** | — |
| 4 | Deploy-order | **No** | Single-JAR change |
| 5 | Data migration | **No** | Tenant-specific double-BOL cleanup (if any) is a separate ops task |
| 6 | External systems | **No** | — |
| 7 | Access / permissions | **No** | — |
| 8 | Observability | **Built-in** | `LOG.warn` on rejection in both helpers |

## §5. Implementation checklist

- [ ] **S1** `BillofladingPositionService`: `UnitloadRepository` ctor dep + both helpers (CLOSED+TRANSFER; `LOG.warn`; fail-open dangling carrier). Commit.
- [ ] **S2** Fix A calls: `palletise` (after `:196-201`, before `:203`) + `palletiseAndTruckLoad` (before `:353`). Commit.
- [ ] **S3** Fix B call in reuse branch (`pallet.getLabelid()`). Commit.
- [ ] **S4** Mobile 4-site refactor. Commit.
- [ ] Unit tests per §6; IT `@Disabled TODO(SBDEV-2217)`.
- [ ] `mvn clean compile` + context-load green; `bash sbdocs/9-System/scripts/verify-SBDEV-2507-web-palletize-already-truckloaded-guard-v2.sh` → `0 fail`.
- [ ] Code review.

---

## §6. Testing Plan / Acceptance criteria (wms-tdd-gate consumable)

Existing classes (verified): `unit/service/BillofladingPositionServiceUnitTest`, `unit/service/ParcelMonitorViewServiceUnitTest`, `unit/service/mobile/MobilePalletizingServiceUnitTest`.

| AC | Statement | Test | Gate type |
|----|-----------|------|-----------|
| **AC-1** | Gate helper throws on any non-empty positions (incl. CANCELLED-only) | `BillofladingPositionServiceUnitTest#assertPalletNotAssignedToGate_whenPositionsExist_throws` | red→green |
| **AC-2** | Gate helper no-throw on empty positions or null label | `…#assertPalletNotAssignedToGate_whenEmptyOrNull_doesNotThrow` | red→green |
| **AC-3** | Carrier helper throws when carrier has a **CLOSED** position | `…#assertParcelCarrierNotShipped_whenCarrierOnClosedBol_throws` | red→green |
| **AC-4** | Carrier helper throws when carrier has a **TRANSFER** position | `…#assertParcelCarrierNotShipped_whenCarrierOnTransferBol_throws` | red→green |
| **AC-5** | Carrier helper no-throw: OPEN / TRUCK_LOADING / CREATED / CANCELLED / empty positions / **null carrierId** (distinct branch) | `…#assertParcelCarrierNotShipped_whenNotShippedOrNoCarrier_doesNotThrow` | red→green |
| **AC-6** | Carrier helper **fail-open on dangling carrier ref** (findById empty → no-throw; distinct branch from AC-5) | `…#assertParcelCarrierNotShipped_whenCarrierNotFound_doesNotThrow` | red→green |
| **AC-7a** | **Migrated shape (exercises Fix A in isolation):** `palletise` with `findByUnitloadLabelIdList` EMPTY (parcel has no own position) + carrier position CLOSED → throws + `verify(unitloadBusinessService, never()).transferUnitLoadToCarrier(...)` | `ParcelMonitorViewServiceUnitTest#palletise_migratedParcelOnClosedBolPallet_throws` | red→green |
| **AC-7b** | **V2-native shape (pinning test — GREEN pre-fix, must STAY green):** parcel has its own CLOSED position → existing `removeBOLPositionIfExists` throws `"already shipped!"` (Fix A not reached) | `ParcelMonitorViewServiceUnitTest#palletise_nativeParcelOwnClosedPosition_existingGuardThrows` | pinning |
| **AC-8** | Reuse vector: reusing a gated named pallet throws `"Pallet already assigned to gate!"` before transfer | `ParcelMonitorViewServiceUnitTest#palletise_reuseGatedPallet_throws` | red→green |
| **AC-9** | Happy path: fresh pallet + unshipped parcel → transfer called | `ParcelMonitorViewServiceUnitTest#palletise_freshPalletAndUnshippedParcel_proceeds` | pinning |
| **AC-10** | Mobile gate behavior unchanged after refactor (4 sites, same message) | `MobilePalletizingServiceUnitTest` existing gate cases | pinning |
| **AC-11** (deferred) | Rejection surfaces as HTTP-200 error map, not 500 | IT `@Disabled TODO(SBDEV-2217)` | deferred |

> **TDD-gate note:** AC-7b/9/10 are pinning tests (green before the fix) — do not expect fail-first. Fix A at `palletiseAndTruckLoad:353` has **static-grep coverage only** (dead code — no behavioral AC).

### Manual test plan

| # | Scenario | Env | Steps | Expected | Pass/Fail |
|---|---|---|---|---|---|
| M1 | Incident vector blocked (migrated shape) | dev/staging web | Palletize a parcel whose carrier pallet is on a CLOSED (or TRANSFER) BOL | Rejected "…already shipped (closed/transfer BOL)!"; no transfer |  |
| M2 | Reuse-gated-pallet blocked | staging web | Palletize onto an existing pallet already on a BOL | "Pallet already assigned to gate!" |  |
| M3 | Happy path | staging web | Palletize un-shipped parcel onto fresh pallet | Succeeds |  |
| M4 | Mobile unchanged | staging mobile | scanPallet/scanPalletBulk/scanParcelBulk onto gated & fresh pallets | Same as today |  |
| M5 | Error is HTTP-200 error map | staging web | Trigger M1/M2 | Business message in error map (`BillOfLadingController:347/:349`) |  |

### Test execution (fill after running)

| Command | Result | P/F/S |
|---------|--------|-------|
| `mvn clean compile` | | |
| `mvn test -Dtest='BillofladingPositionServiceUnitTest,ParcelMonitorViewServiceUnitTest,MobilePalletizingServiceUnitTest'` | | |

---

## §7. Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| Gate helper rejects CANCELLED-only pallets (stricter than `removeBOLPositionIfExists`) | Certain | Low | Intentional — mobile parity; pinned AC-1/AC-2; carrier helper does NOT over-reject CANCELLED (AC-5) |
| Legitimate back-office correction blocked | Certain | Low–Med | Intended; sanctioned "remove-from-BOL → re-palletize" flow is a separate feature |
| Refactor drops a mobile guard | Low | High | Verify script R1/R2 + AC-10 |
| `UnitloadRepository` ctor dep (compile/DI) | Low | Med | Leaf repo, no cycle; compile + context-load gate; helper home pinned by script C6 |
| Fix A per-parcel `findById` cost | Certain | Low | Bounded by parcels-per-palletize; read-only in existing tx |
| Fix A misplaced before the position loop | Low | Med (breaks AC-7b semantics) | Explicit insertion-offset note (§3 File 2); AC-7b pins it |
| Mobile migrated-data asymmetry (documented) | — | Low | Follow-up candidate row (§3 scope notes) |

## §8. Horizontal Scalability Validation

| # | Concern | Verdict | Rationale |
|---|---|---|---|
| 1 | In-JVM state | No | Stateless read helpers |
| 2 | Connection pool | No | Bounded reads inside the caller's existing tx/connection |
| 3 | Scheduled jobs | No | None touched |
| 4 | Long transactions | No | Existing boundary; quick reads, no external I/O |
| 5 | Request affinity | No | Stateless |
| 6 | Retry / idempotency | N/A | Deterministic reject before transfer; re-evaluates same DB state |
| 7 | Tenant context | No | Synchronous request thread |
| 8 | Distributed locks | No (relies on existing) | Pre-existing `findByIdForUpdate` skeleton; guards read within it |
| 9 | Cache invalidation | No | Direct repo queries; no `@Cacheable` write path |
| 10 | External notifications | No | Only `LOG.warn` |

All No/N-A — no "Yes" evidence rows required.

---

## §9. ADR (consensus record)

- **Decision:** Option A — shared guards in `BillofladingPositionService` (+ `UnitloadRepository` ctor dep); Fix A after the parcel-position block in both loops; Fix B (via `pallet.getLabelid()`) in the reuse branch; mobile 4-site refactor. No new `@Transactional`. CLOSED+TRANSFER rejection.
- **Drivers:** parity + drift-prevention (single guard source); blast radius (live `/palletize` — business rejection, never 500/partial write); minimal structural change on v2's existing tx/lock skeleton.
- **Alternatives:** guards inline in `ParcelMonitorViewService` — rejected (re-creates the web/mobile drift that caused the incident); copy mobile's inline pattern — rejected (no source-side guard exists to copy; can't close the vector).
- **Consequences:** one leaf-repo ctor dep; mobile guard copies 4→1; **v2-accurate RCA** recorded (v2-native data already guarded; Fix A = migrated-data + TRANSFER + defense-in-depth) so future maintainers don't strip it; mobile migrated-data asymmetry documented as follow-up.
- **Consensus:** Architect ITERATE (RCA re-grounding, AC-7 split, `pallet.getLabelid()`, TRANSFER note) → all folded → Critic **APPROVE** (3 minors folded: insertion-offset note, dead-code AC caveat, citation tightening).

## §10. Acceptance script

`sbdocs/9-System/scripts/verify-SBDEV-2507-web-palletize-already-truckloaded-guard-v2.sh` (authored with this plan; baseline all-FAIL). Positive C1–C7 (helpers exist; gate message in helper; carrier helper queries `getBySourceUnitLoadLabelId` + reads `getCarrierunitloadId`; **C6** ctor takes `UnitloadRepository`; **C7** both CLOSED and TRANSFER greped in the service; A1 Fix A call in `ParcelMonitorViewService` ≥2×; B1 Fix B call). Negative R1 (raw inline gate throw gone from mobile), R2 (helper ≥4× in mobile), R3 (the raw `"Pallet already assigned to gate!"` **throw** appears ONLY in the helper file). Commented mvn rows T1–T3.

## §11. Implementation Status

**Implemented 2026-07-10** (branch `port/SBDEV-2507-palletize-guard`, [PR #67](https://github.com/SiteBossInc/wms2-api/pull/67) → `develop`).

### Commits (v2/wms2-api)
| SHA | Scope |
|---|---|
| `9686ab1` | S1 shared guards + `UnitloadRepository` ctor dep (+ AC-1..AC-6 tests) |
| `481be6e` | S2 Fix A both loops (offset after `removeBOLPositionIfExists`) + S3 Fix B reuse branch (+ AC-7a/7b/8 tests) |
| `4a77fbb` | S4 mobile 4-site refactor (+ S5 pinning test for the previously-uncovered 4th gate site) |

### Tests / gates
- TDD gate: 8 red→green (AC-1..6, 7a, 8) + 3 pinning confirmations (AC-7b, AC-9 existing, AC-10 existing ×3); 86-test baseline, 0 errors.
- Post-implementation: `mvn test` (3 suites) **87 run / 0 failures / 0 errors** (re-run green after review LOW fixes); `mvn clean compile` BUILD SUCCESS.
- Verify script: **`Result: 12 pass, 0 fail, 1 skip`**.
- Controller-layer grep confirmed `palletiseAndTruckLoad` has no controller/HAL/Spring-Data-REST exposure (dead code; guarded for parity).
- AC-11 IT deferred `@Disabled TODO(SBDEV-2217)`.

### Review
- Code review: **APPROVE — 0 HIGH / 0 MEDIUM / 3 LOW.** Fixed: dead repo stubs removed from the 3 converted mobile gate tests (live parcel-level stubs kept) + explicit `verify(billofladingPositionService)` delegation asserts added. LOW-3 (AC-7a exercises the call site via stubbed helper) noted — real branch logic covered by AC-3..AC-6.
- Both executor judgment calls verified legitimate (stub relocation to the mocked collaborator boundary; strict-Mockito prunes).

### Docs updated
- [[wms2-bol-truck-loading-workflow]] §4: SBDEV-2507 guard documentation added; `last_verified` → 2026-07-10.

### Follow-ups
- Mobile migrated-data asymmetry (mobile transfer sites lack Fix A — documented decision; extend if reconciliation flows surface it).
- `removeBOLPositionIfExists` explicit TRANSFER handling (own-position TRANSFER still yields "Unexpected status=TRANSFER found!" on the web path).
- `palletiseAndTruckLoad` dead-code removal — separate ticket candidate.
