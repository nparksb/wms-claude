---
title: "SBDEV-2507 — Web Palletize: Reject Palletizing a Parcel Already On/Shipped-With a Truck-Loaded Pallet"
ticket: "SBDEV-2507"
ticket_url: "https://app.clickup.com/t/868k7cq35"
type: bugfix
priority: high
status: archived
status_detail: "Implemented 2026-07-01 (commit 9134417, PR #189 -> develop); Architect+Critic+code-review approved"
project: [wms1]
version: v1
requester: "Nam Park"
created: 2026-07-01
updated: "2026-07-15"
db_verified: true
related:
  - "[[260701-sbdev-2507-repalletize-double-ship-after-closed-bol]]"
  - "[[SBDEV-2099-outbound-parcel-report-clears-after-palletize]]"
  - "[[wms1-bol-truck-loading-workflow]]"
tags:
  - plan
  - palletizing
  - bol
  - data-integrity
---

# SBDEV-2507 — Web Palletize: Reject Palletizing a Parcel Already On/Shipped-With a Truck-Loaded Pallet

**Ticket:** [SBDEV-2507](https://app.clickup.com/t/868k7cq35) (ST#1023, WineCo)
**Project:** wms1 | **Version:** v1/wms-api | **Type:** bugfix
**Priority:** High
**Status:** implemented — commit `9134417`, [PR #189](https://github.com/SiteBossInc/wms-api/pull/189) → `develop` (2026-07-01). Architect+Critic+code-review approved. Rev 2 re-scoped after review found the original Fix A mis-targeted the wrong `palletise` branch.
**Date:** 2026-07-01

> **Rev-2 note.** Rev-1 proposed guarding only the *target pallet* in `palletise`'s reuse branch. Architect + Critic review (grounded in the code and DB) showed the SBDEV-2507 vector — a parcel moved off an already-shipped **pallet** onto a **new** pallet — bypasses that branch entirely, and the existing parcel-level BOL guard also misses it (a parcel shipped *as part of a pallet* is not itself a BOL position). This revision re-targets the fix to the **parcel's current carrier pallet** and keeps the target-pallet guard as a second (mobile-parity) layer.
>
> ⚠️ **Data caveat.** The live WineCo DB likely contains post-incident manual fixes, so the exact original vector is unprovable. This plan therefore closes **both** plausible vectors (source-parcel-on-shipped-pallet AND target-pallet-already-gated); it is correct regardless of which the incident used. The out-of-scope `closeBOL` "stuck at 670" finalize question remains open (verify-first).

---

## 0. Affected sites (enumeration before drafting)

Enumerated via `grep -rn` over `src/main/java` (`palletise`/`palletiseAndTruckLoad`, `getBySourceUnitLoadLabelId`, `transferUnitLoadToCarrier`, `"already assigned to gate"`) and confirmed against the code + DB.

| # | File:line | Construct | Same root-cause? | In-scope this plan? |
|---|-----------|-----------|------------------|----------------------|
| 1 | `service/ParcelMonitorViewService.java:117-161` (`palletise` parcel loop) | palletizes each parcel with NO check that the parcel's **current carrier pallet** is already shipped/on a closed BOL | **yes (incident vector)** | **YES — Fix A** (source-parcel guard) |
| 2 | `service/ParcelMonitorViewService.java:110-114` (`palletise` reuse branch) | reuses an existing pallet with the "already exists" throw commented out; no gate check | yes (reuse vector) | **YES — Fix B** (target-pallet guard, mobile parity) |
| 3 | `service/BillofladingPositionService.java` | home for the two shared guard helpers | n/a | **YES — Fix C** |
| 4 | `service/mobile/MobilePalletizingService.java:198-201, 244-247, 273-276, 292-295` | existing inline `getBySourceUnitLoadLabelId(...).isEmpty()` → `"Pallet already assigned to gate!"` (reference impl; site 4 uses `pallet.getLabelid()`, not `palletLabel`) | yes | **YES — Fix C refactor** (route through shared helper; behavior-neutral) |
| 5 | `service/ParcelMonitorViewService.java:120-122` order-FINISHED guard | throws only when order `>= FINISHED(700)`; a parcel stuck at `PALLETIZED(670)` passes | yes (why existing guards missed it) | documented in §2; not the fix locus |
| 6 | `service/ParcelMonitorViewService.java:125-150` (`removeBOLPositionIfExists` on the parcel) | fires only if the **parcel itself** is a BOL position; misses parcels shipped *via a pallet* (pallet is the source, parcel is not) | yes (why existing guards missed it) | documented in §2; complemented by Fix A |
| 7 | `service/ParcelMonitorViewService.java:166+` (`palletiseAndTruckLoad`) | sibling; **no Java caller** (grep) and its reuse branch already throws `"Pallet with name=... already exists!"` at `:225-227` | yes | **no** — dead/unreachable for reuse; Fix A's per-parcel guard SHOULD also be applied here if it is ever wired (noted §5) |
| 8 | `controller/BillOfLadingController.java:316-352` (`POST /palletize`) | web entry; wraps in `try/catch(BusinessException/FacadeException)` → HTTP 200 error map (confirmed `:337-352`) | entry | no code change |
| 9 | `transferUnitLoadToCarrier` non-palletizing sites (`AdviceService:196`, `StockunitService:136`, `ReceivingService:525`, `MobileMoveStockService:330`, `MobileMoveUnitloadService:317`) | attach UL to carrier under non-outbound-palletize activity codes | no | no — different workflow |
| 10 | `MobileTruckLoadingService.java:114` `getBySourceUnitLoadLabelId` | truck-loading phase check | no | no |

Rows 1–4 in scope. Rows 5–6 explain why the current guards miss the vector. Rows 7–10 excluded with rationale.

---

## 1. Problem Statement

**Ticket (SBDEV-2507 / ST#1023, WineCo):** order 54068 / parcel `XR1781642381900` still appeared on the Outbound Report as **Palletized** while its BOL **OBOL117374** was **CLOSED/shipped**.

**Operator-reported action:** a user used the **web UI (Outbound Parcel Report → Palletize)** to create another pallet and palletize a parcel that was already on a pallet **truck-loaded onto a (closed) BOL**. The mobile floor flow structurally can't do this (you can't scan an already-shipped parcel/pallet); the web report lets you select any parcel row and palletize it. The result was a shipment/BOL-state corruption (a parcel associated with two pallets / two BOLs).

**DB / code verification (root cause is code-level):**
- Confirmed the parcel `XR1781642381900`, when shipped via pallet `PM-017012` on **OBOL117374**, was **NOT** an individual `billoflading_position` (only the pallet `PM-017012` was the source position `33559560`). So the parcel-level guard in `palletise` (`:125-150`) would find no position for it and never throw "already shipped!".
- `MobilePalletizingService` guards the *target* pallet (`getBySourceUnitLoadLabelId(palletLabel).isEmpty()` → `"Pallet already assigned to gate!"`, `:198-201` etc.); `ParcelMonitorViewService.palletise` has **no equivalent guard on the target pallet and no guard on the source parcel's current carrier**.
- `BillofladingPositionRepository.getBySourceUnitLoadLabelId` exists (`:39-43`) — the guard's building block. `db_verified: true` on this basis.

> ⚠️ The current WineCo data may be post-manual-fix; the fix is justified by the code gaps, not by the (possibly remediated) `unitload_record` timeline.

---

## 2. Root Cause Analysis

### Bug 1 — `palletise` never checks whether the parcel is currently on an already-shipped/truck-loaded pallet (incident vector)

`ParcelMonitorViewService.palletise` (`:117-161`) palletizes each selected parcel onto the target pallet with three guards, **all of which miss a parcel that was shipped as part of a pallet**:

1. `:120-122` — throws only if the order `>= FINISHED(700)`. In SBDEV-2507 the order was stuck at `PALLETIZED(670)` (report), so this passed.
2. `:125-150` — looks up BOL positions by **parcel** label (`findByUnitloadLabelIdList(parcelNames)`) and routes any hit through `removeBOLPositionIfExists`, which throws `"already shipped!"` only when the **parcel's own** position is `CLOSED` (`BillofladingPositionService:63-64`). But a parcel shipped *inside a pallet* is **not** an individual BOL position (verified: on OBOL117374 only the pallet was the source), so this guard finds nothing and does not fire.
3. There is **no** check on the parcel's **current carrier pallet** (`parcel.carrierunitloadId`). A parcel sitting on a pallet that is already assigned to a gate / on a closed BOL can be re-palletized freely.

So the parcel gets transferred (`transferUnitLoadToCarrier`, `:154`) onto a new/other pallet, and its `carrierunitloadId` overwritten (`:158`), corrupting the shipment. **This is the vector the operator hit.**

### Bug 2 — `palletise` reuse branch lacks the target-pallet "already assigned to gate" guard (mobile parity)

`palletise` existing-pallet branch (`:110-114`) reuses an existing pallet with the "already exists" throw commented out and **no** check that the pallet is already on a BOL — whereas mobile blocks exactly that (`MobilePalletizingService.scanPallet:198-201`). This is a distinct, narrower vector (reuse an already-gated *target* pallet). Closing it restores web/mobile parity even though it is not the SBDEV-2507 vector (the incident's target was a freshly-created pallet).

Not a regression chain — neither guard was ever present on the web path.

---

## 3. (Regression Chain)

N/A.

---

## 4. Architecture Overview

```
WEB  Outbound Parcel Report → Palletize
  └─ POST /palletize                         BillOfLadingController.java:316-352 (catches BusinessException → HTTP 200 error map)
       └─ ParcelMonitorViewService.palletise()
            ├─ pallet resolve: create :96-109 | reuse :110-114   ← Bug 2 → Fix B (target-pallet guard, reuse branch)
            └─ per-parcel loop :117-161
                 ├─ order>=FINISHED? :120           (misses 670)          ┐ existing guards
                 ├─ parcel-as-BOL-position? :125-150 (misses pallet-shipped parcels) ┘ both miss the vector
                 ├─ ★ Fix A: assertParcelCarrierNotShipped(parcel)  ← NEW source-side guard (incident vector)
                 └─ transferUnitLoadToCarrier(CODE_PALLETISING) :154

MOBILE  MobilePalletizingService scanPallet/scanPalletBulk/scanParcelBulk
        getBySourceUnitLoadLabelId(...).isEmpty()? else "Pallet already assigned to gate!"  :198,244,273,292
                                                                    ↓ route through
SHARED  BillofladingPositionService
          • assertPalletNotAssignedToGate(String palletLabel)     ← Fix B/C (used by web reuse + mobile ×4)
          • assertParcelCarrierNotShipped(Unitload parcel)        ← Fix A (used by web palletise loop)
        (ParcelMonitorViewService & MobilePalletizingService already inject BillofladingPositionService — no new dep)
```

**Key Files**

| File | Lines | Role |
|------|-------|------|
| `service/ParcelMonitorViewService.java` | 96-114, 117-161 | Web palletize; Fix A (loop) + Fix B (reuse branch) |
| `service/BillofladingPositionService.java` | 20-21, 48-78 | New shared helpers (Fix C); `removeBOLPositionIfExists` reference for state semantics |
| `service/mobile/MobilePalletizingService.java` | 198-201, 244-247, 273-276, 292-295 | Existing inline guards → route to helper (Fix C) |
| `repo/jpa/BillofladingPositionRepository.java` | 39-43 | `getBySourceUnitLoadLabelId(labelId)` (no BOL-state filter — see §9) |
| `controller/BillOfLadingController.java` | 316-352 | `POST /palletize` (no change) |

---

## 5. Fix Design

### Fix C — two shared guard helpers in `BillofladingPositionService`

`BillofladingPositionService` already injects `BillofladingPositionRepository` (`:20-21`) and both callers already inject `BillofladingPositionService` — no new dependency, no cycle.

```java
/** Reject a pallet label already used as a source on any BOL position (assigned to a gate / truck-loaded). */
public void assertPalletNotAssignedToGate(String palletLabel) throws BusinessException {
    if (palletLabel != null && !billofladingPositionRepository.getBySourceUnitLoadLabelId(palletLabel).isEmpty()) {
        throw new BusinessException("Pallet already assigned to gate!");
    }
}

/** Reject palletizing a parcel that currently sits on a pallet already shipped on a CLOSED BOL. */
public void assertParcelCarrierNotShipped(Unitload parcel) throws BusinessException {
    Long carrierId = parcel.getCarrierunitloadId();
    if (carrierId == null) return;
    Unitload carrier = unitloadRepository.findById(carrierId).orElse(null);   // UnitloadRepository added to this service per §5 decision
    if (carrier == null) { LOG.debug("assertParcelCarrierNotShipped: carrier {} not found for parcel {}", carrierId, parcel.getLabelid()); return; }
    // A CLOSED BOL position on the carrier pallet means the parcel was already shipped with that pallet.
    boolean carrierClosed = billofladingPositionRepository.getBySourceUnitLoadLabelId(carrier.getLabelid())
        .stream().anyMatch(p -> WmsConstants.BillOfLadingState.CLOSED.equals(p.getState()));
    if (carrierClosed) {
        throw new BusinessException("Parcel=" + parcel.getLabelid() + " is on pallet " + carrier.getLabelid() + " already shipped on a closed BOL!");
    }
}
```

> **Decision (fixed — resolves the review's helper-home ambiguity):** both helpers live in `BillofladingPositionService`, and `assertParcelCarrierNotShipped` gets a **new `UnitloadRepository` dependency** added there (a leaf query repo — no dependency cycle; `mvn clean compile` gates it). This keeps a single shared source of truth for both the web and mobile paths, and it matches the verify script's `$SVC`-targeted checks (C2/C4/C5). Do **not** host it privately in `ParcelMonitorViewService` — that would leave the script's checks pointing at the wrong file. If `carrier == null` (dangling ref), `LOG.debug` and return (fail-open: a missing carrier is not a shipped carrier).

### Fix A — guard the source parcel's carrier in the `palletise` loop (PRIMARY — closes the incident vector)

In the per-parcel loop, before the transfer (`:152-154`), resolve the parcel and assert its carrier is not shipped:

```java
Unitload unitLoad = unitloadRepository.findById(customerOrder.getParcelId())
    .orElseThrow(() -> new BusinessException("Unit load not found: " + customerOrder.getParcelId()));
assertParcelCarrierNotShipped(unitLoad);   // Fix A — reject re-palletizing a parcel already shipped on a pallet
unitloadBusinessService.transferUnitLoadToCarrier(unitLoad, pallet, WmsConstants.CODE_PALLETISING, customerOrder.getNumber(), null);
```

(The existing `:120` order-finished and `:125-150` parcel-position guards stay — Fix A closes the gap they miss: parcels shipped *inside* a pallet.)

### Fix B — guard the target pallet in the `palletise` reuse branch (mobile parity)

```java
// :110-114 after
} else {
    assertPalletNotAssignedToGate(palletName);   // Fix B — reject reusing an already-gated pallet (mobile parity)
    pallet = palletOpt.orElseThrow(() -> new NoSuchElementException("No value present"));
}
```

Only the reuse branch needs it (a system-created or brand-new named pallet is fresh). **Not** applied to `palletiseAndTruckLoad`'s reuse branch: that already throws `"...already exists!"` at `:225-227`, so a guard there is unreachable dead code (§0 row 7). If `palletiseAndTruckLoad` is ever wired to a caller, apply Fix A's per-parcel guard to its loop instead.

### Fix C (refactor half) — route mobile's 4 inline guards through `assertPalletNotAssignedToGate`

Replace the 4 inline blocks in `MobilePalletizingService` with the helper, **preserving each site's argument**:
- `scanPallet:198-201` → `assertPalletNotAssignedToGate(palletLabel)`
- `scanPalletBulk:244-247` → `assertPalletNotAssignedToGate(palletLabel)`
- `scanPalletBulk:273-276` → `assertPalletNotAssignedToGate(palletLabel)`
- `scanParcelBulk:292-295` → `assertPalletNotAssignedToGate(pallet.getLabelid())`  ← **note: this site has no `palletLabel` local**; use the re-fetched pallet's label.

Behavior-neutral (same query, same message). Single-sources the guard so web and mobile cannot drift again.

**Why this and not alternatives:** the incident vector is a *parcel on a shipped pallet*, which only a source-side (Fix A) guard catches; the target-side guard (Fix B) is mobile-parity for the reuse vector. Putting both helpers in the already-shared `BillofladingPositionService` prevents future drift.

---

## 6. File Change Summary

| File | Change Type | Description |
|------|-------------|-------------|
| `service/BillofladingPositionService.java` | edit (add 2 methods + `UnitloadRepository` dep) | Fix C: `assertPalletNotAssignedToGate`, `assertParcelCarrierNotShipped` (new `UnitloadRepository` — leaf repo, no cycle) |
| `service/ParcelMonitorViewService.java` | edit | Fix A: call `assertParcelCarrierNotShipped` in loop before transfer; Fix B: call `assertPalletNotAssignedToGate` in reuse branch |
| `service/mobile/MobilePalletizingService.java` | edit (refactor ×4) | Fix C: route the 4 inline gate guards through the helper (correct per-site arg) |
| `src/test/java/net/aim_ai/wms/unit/service/BillofladingPositionServiceUnitTest.java` | edit (add tests) | Guard unit tests (§8) |
| `src/test/java/net/aim_ai/wms/unit/service/ParcelMonitorViewServiceUnitTest.java` | edit (add tests) | Incident-vector + reuse-vector tests (§8) |
| `sbdocs/9-System/scripts/verify-SBDEV-2507-web-palletize-already-truckloaded-guard.sh` | new | Acceptance script |

---

## 7. Implementation Steps

### 7.1 Prerequisites

| Concern | Applies? | Detail |
|---|---|---|
| DB state | No | Server-side logic guard; no schema/data change. |
| Feature flags / sysprop | No | Guard is unconditional (matches mobile). |
| Config / env | No | — |
| Data migration | No | — |
| Deploy-order | No | Single JAR change. |
| External systems | No | — |
| Observability | Recommended | Add `LOG.warn` when a guard rejects (parcel/pallet label + BOL) so ops can see blocked attempts. |
| **Out-of-scope prereq** | Note | Data remediation for order 54068 (double-BOL) is an ops task (report §8); the closeBOL/670 finalize question is a separate verify-first investigation. |

### 7.2 Steps (each independently committable)

1. **Fix C helpers** in `BillofladingPositionService` (add the `UnitloadRepository` dependency per §5); unit tests. Commit.
2. **Fix A** — `assertParcelCarrierNotShipped` call in `palletise` loop; tests. Commit.
3. **Fix B** — `assertPalletNotAssignedToGate` call in `palletise` reuse branch; tests. Commit.
4. **Fix C refactor** — route the 4 mobile guards through the helper (correct args); run `MobilePalletizingServiceUnitTest`. Commit.
5. Run `bash sbdocs/9-System/scripts/verify-SBDEV-2507-web-palletize-already-truckloaded-guard.sh` → `Result: N pass, 0 fail`.

---

## 8. Testing Plan

### Unit (Mockito 3.3.3 — no `mockStatic`; repos are injected mocks)
Add to `BillofladingPositionServiceUnitTest` and `ParcelMonitorViewServiceUnitTest` (exact existing class names, under `unit/service/`):
- `assertPalletNotAssignedToGate_whenPositionsExist_throws()` / `_whenEmpty_doesNotThrow()`.
- `assertParcelCarrierNotShipped_whenCarrierOnClosedBol_throws()` — parcel with `carrierunitloadId` → carrier pallet whose `getBySourceUnitLoadLabelId` returns a `CLOSED` position → `BusinessException`.
- `assertParcelCarrierNotShipped_whenCarrierNotShipped_or_noCarrier_doesNotThrow()` — explicitly cover: empty positions, **OPEN**, **CANCELLED** (the documented distinction from Fix B — CANCELLED must NOT throw), and null carrier → no throw. This is the behavioral gate for the CLOSED-only decision.
- **Incident-vector test (key):** `palletise_parcelOnClosedBolPallet_throws()` — parcel’s current carrier pallet has a CLOSED position; assert `BusinessException` and `verify(unitloadBusinessService, never()).transferUnitLoadToCarrier(...)` (the guard sits before `:154`).
- **Reuse-vector test:** `palletise_reuseGatedPallet_throws()` — existing named pallet with a BOL position → throws before transfer.
- **Happy path:** `palletise_freshPalletAndUnshippedParcel_proceeds()` — verify transfer is called (matches existing `ParcelMonitorViewServiceUnitTest` mock pattern).
- Regression: existing `MobilePalletizingServiceUnitTest` cases still pass after the Fix C refactor.

### Integration
- **Skipped** — v1 `@SpringBootTest`/Testcontainers lane blocked (ro_id view drift SBDEV-2384 + Testcontainers). Acceptance = `mvn clean compile` + the unit tests + manual. Re-enable once unblocked.

### Regression
- `mvn clean compile`; `mvn test -Dtest=BillofladingPositionServiceUnitTest,ParcelMonitorViewServiceUnitTest,MobilePalletizingServiceUnitTest`.

### Manual test plan

| # | Scenario | Env | Steps | Expected |
|---|---|---|---|---|
| M1 | **Incident vector blocked** | staging web | Select a parcel currently on a pallet that is on a CLOSED BOL; palletize it (to a new or existing pallet) | Rejected: "Parcel=… on pallet … already shipped on a closed BOL!"; no transfer; report unchanged |
| M2 | Reuse-gated-pallet blocked | staging web | Palletize onto an existing pallet already on a BOL | Rejected "Pallet already assigned to gate!" |
| M3 | Happy path unaffected | staging web | Palletize an un-shipped parcel onto a fresh/valid pallet | Succeeds |
| M4 | Mobile unchanged | staging mobile | scanPallet/scanPalletBulk/scanParcelBulk onto gated & fresh pallets | Same behavior as today (Fix C behavior-neutral) |
| M5 | Error is HTTP-200 error-map, not 500 | staging web | Trigger M1/M2 | Business message in the error map (BusinessException handled at `BillOfLadingController:337-352`) |

### Post-implementation gate
Run `verify-SBDEV-2507-...sh` first (FAIL baseline) and last (`Result: N pass, 0 fail`); paste the final line. Update §10 with SHAs, test names, `mvn` results.

---

## 9. Risks & Mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| **Guard signal has no BOL-state filter** (`getBySourceUnitLoadLabelId`) | `assertPalletNotAssignedToGate` (Fix B) rejects a pallet whose only position is on a **CANCELLED** BOL — stricter than `removeBOLPositionIfExists` (which treats CANCELLED as removable) | **Intentional, matches mobile exactly** (`:198-201`). Documented here. `assertParcelCarrierNotShipped` (Fix A) deliberately filters to `CLOSED` only, so it does NOT over-reject on CANCELLED. Add unit tests pinning both decisions. If a "reuse cancelled-BOL pallet" workflow is ever wanted, that's a separate change. |
| Legitimate back-office correction now blocked | Ops can't re-palletize a shipped parcel/pallet from the report | Intended — mutating a shipped pallet is the bug. A sanctioned "remove from BOL → re-palletize" workflow is a separate feature (§10). |
| Fix C refactor drops a mobile guard | Floor regression | Verify script asserts the helper appears ≥4× in the mobile file AND the raw throw string is gone; `MobilePalletizingServiceUnitTest` proves behavior. |
| New `UnitloadRepository` dep in `BillofladingPositionService` | Compile / cycle risk | Committed decision (§5): add it — `UnitloadRepository` is a leaf query repo, no cycle. `mvn clean compile` gates it. The verify script's C2/C4/C5 assume this home, so it must not move to `ParcelMonitorViewService`. |
| Fix A adds a `findById` per parcel | Minor extra query in the loop | Bounded by parcels-per-palletize (small); acceptable. |

**Horizontal scalability (v2):** N/A — v1-only. Evaluate a v2 counterpart separately (v2 has its own palletize services).

---

## 10. Open Questions / Resolved Decisions

- **Resolved (review-driven, rev 2):** the fix targets the **parcel's current carrier pallet** (Fix A, incident vector) plus the **target pallet reuse** (Fix B, mobile parity). Rev-1's target-only guard was insufficient.
- **Resolved (defaults):** Fix A rejects on CLOSED-only; Fix B mirrors mobile (any position state). Single PR. `BusinessException` (HTTP-200 error map).
- **Resolved (scope of Fix A — updated by code review MEDIUM-2):** Fix A blocks a parcel whose carrier pallet is on a **CLOSED or TRANSFER** BOL position — both are already-shipped-out states (CLOSED = shipped/closed BOL; TRANSFER = shipped to another warehouse, not yet accepted). It deliberately **allows** moving a parcel off a pallet still OPEN/TRUCK_LOADING/CREATED (legitimate in-progress correction) or CANCELLED (aborted). Original draft was CLOSED-only; TRANSFER was added after review flagged it as an un-guarded shipped-out vector.
- **Resolved (code review MEDIUM-1 — atomicity):** `palletise` (and `palletiseAndTruckLoad`) now carry `@Transactional(rollbackFor = {BusinessException.class, FacadeException.class})` so a mid-batch guard rejection rolls back any parcels already transferred in the same request — no partial re-palletize.
- **Resolved (helper home):** both helpers live in `BillofladingPositionService` (+ new `UnitloadRepository`); the verify script's C2/C4/C5 assume this — see §5.
- **Open (data):** the exact original incident vector is unprovable (WineCo DB may be post-manual-fix). Closing both vectors makes the fix robust regardless. Confirm original state from ST#1023 / app logs / backups if a definitive RCA is required.
- **Open (out of scope):** the `closeBOL` "stuck at 670" finalize question — reproduce before any fix.
- **Open (product):** should a sanctioned "remove pallet/parcel from BOL → re-palletize" correction workflow exist for back-office? Separate feature.
- **v1↔v2:** check whether v2's palletize path has the same gaps; pair a v2 plan if so.

---

## 11. Implementation Status

**Implemented 2026-07-01.**
- **Commit:** `9134417` on branch `fix/SBDEV-2507-web-palletize-already-truckloaded-guard`.
- **PR:** https://github.com/SiteBossInc/wms-api/pull/189 (→ `develop`).
- **Changes:** Fix C helpers + new `UnitloadRepository` dep in `BillofladingPositionService`; Fix A/B calls in `ParcelMonitorViewService.palletise` (+ `palletiseAndTruckLoad`); `@Transactional(rollbackFor={BusinessException,FacadeException})` on both (code-review MEDIUM-1); mobile 4-site refactor; guard blocks CLOSED **and** TRANSFER (code-review MEDIUM-2); `LOG.warn` on rejection.
- **Tests added:** `BillofladingPositionServiceUnitTest`: `assertPalletNotAssignedToGate_whenPositionsExist_throws`, `_whenEmpty_doesNotThrow`, `assertParcelCarrierNotShipped_whenCarrierOnClosedBol_throws`, `_whenCarrierOnTransferBol_throws`, `_whenCarrierNotClosedOrNoCarrier_doesNotThrow`, `_whenCarrierNotFound_doesNotThrow`. `ParcelMonitorViewServiceUnitTest`: `palletise_parcelOnClosedBolPallet_throws`, `palletise_reuseGatedPallet_throws`, `palletise_freshPalletAndUnshippedParcel_proceeds`. 4 existing mobile gate tests updated for the shared-helper refactor.
- **Results:** 82 tests green across the 3 affected classes (`BillofladingPositionServiceUnitTest` 15, `ParcelMonitorViewServiceUnitTest` 23, `MobilePalletizingServiceUnitTest` 44); `mvn clean test-compile` BUILD SUCCESS; acceptance `verify-SBDEV-2507-...sh` → **Result: 12 pass, 0 fail, 0 skip**.
- **Review:** Architect + Critic APPROVED the plan (rev 2); code review APPROVE (0 HIGH; 2 MEDIUM fixed; LOWs — observability logging, extra tests, `verify()` on wiring tests — also applied).
- **Docs updated (2026-07-01):** `wms1-transaction-boundary-map.md` §4.2 (added `ParcelMonitorViewService` palletize as a new @Transactional site) and `wms1-bol-truck-loading-workflow.md` §2 (documented Fix A/B guards, CLOSED/TRANSFER rejection, transactional batch; fixed drifted line refs); both `last_verified` bumped. (These live in the `sbdocs/` Obsidian vault, which is not git-tracked, so they are not part of PR #189's diff.)

---

## Acceptance

Machine-checkable script: `sbdocs/9-System/scripts/verify-SBDEV-2507-web-palletize-already-truckloaded-guard.sh`
Run: `bash sbdocs/9-System/scripts/verify-SBDEV-2507-web-palletize-already-truckloaded-guard.sh` — acceptance = `Result: N pass, 0 fail`.
