---
title: "Picking nirvana-guard self-depleting-pick — v2 applicability analysis (NOT APPLICABLE)"
ticket: ""
ticket_url: ""
type: bugfix
priority: high
status: archived
project: [wms2]
version: v2
requester: "Nam Park"
created: 2026-07-09
updated: 2026-07-15
db_verified: false
related:
  - "[[260709-picking-nirvana-guard-blocks-self-depleting-pick]]"
  - "[[wms2-picking-workflow]]"
  - "[[wms2-transaction-osiv-boundary-map]]"
tags:
  - plan
  - picking
  - nirvana
  - SBDEV-2481
  - v1-v2-port
  - not-applicable
---

# Picking nirvana-guard self-depleting-pick — v2 applicability analysis

**Project:** wms2 | **Version:** v2 | **Type:** bugfix applicability (v1→v2 port)
**Priority:** high | **Status:** NOT APPLICABLE (v2 already correct — no code change)
**Date:** 2026-07-09 (v1 origin) / 2026-07-12 (v2 analysis)

**V1 Source Plan:** `sbdocs/1-Projects/wms1/plan/260709-picking-nirvana-guard-blocks-self-depleting-pick.md` (implemented; v1 PR #196, commit `573eff5`)
**V2 Target:** `v2/wms2-api`
**Sweep:** Unit 6 (final unit) of `sbdocs/2-Areas/wms-v1-v2-sync/sweeps/2026-07-10-wms-v1-sync.md`

---

## 2. Summary

**Verdict: NOT APPLICABLE — do not port.** The v1 defect cannot occur in v2 because v2's SBDEV-2481 implementation **removed the inline pick-line guard from `sendStockUnitToNirvana`** and relocated it into `PickLineRealignmentService.assertNoActivePickFor`, which runs **only** for `BLOCK_REALIGN` activity codes. The picking-confirm path uses `CODE_PICKING`, classified `PASS_THROUGH`, so the guard is unreachable there. v1's late-FK-null ordering is structurally still present in v2 but is now **harmless** — nothing reads the live `pickfromstockunit_id` on the picking-confirm/nirvana path.

| v1 Fix | Description | V2 Verdict | Rationale |
|--------|-------------|-----------|-----------|
| Fix A | Move `confirmPick`'s `setPickfromstockunitId(null)+save` to *before* `transferStockToUnitLoad`, so the inline nirvana guard doesn't see the completing line | **Not needed (v2 already correct)** | v2 has no inline `findByPickfromstockunitId` guard in `sendStockUnitToNirvana`; the extracted guard runs only on `BLOCK_REALIGN` codes, and `CODE_PICKING` is `PASS_THROUGH` |

**Counts:** 1 v1 fix analysed → **0 ported**, **1 not-applicable (v2 already correct)**, **0 NEW v2-only issues**. No code change, no tests, no PR.

> **Archived 2026-07-15 — resolved as NOT APPLICABLE.** This is a completed v2-applicability analysis with a definitive verdict: the v1 self-depleting-pick 500 does not exist in v2 (v2's SBDEV-2481 `PickLineRealignmentService` + BLOCK_REALIGN architecture makes the nirvana-guard unreachable on the picking path). Nothing to implement or merge — archived as a closed investigation, not as a shipped fix.

**Architectural divergence that drives the verdict:** v1 kept the SBDEV-2481 guard **inline** in `StockunitBusinessService.sendStockUnitToNirvana`. v2 (SBDEV-2481 port, commits `21370b2`/`0baee3a` PR #52) extracted it into a dedicated `PickLineRealignmentService` + `PickLineActivityCodeClassifier` bucket model, and gates the guard behind the `BLOCK_REALIGN` bucket only. This is the same "extracted service" divergence class the migration skill warns about — here it eliminates the failure locus rather than relocating the bug.

---

## 1. Problem Statement (v1) and the v2 question

**v1 defect:** during multi-pick, confirming the pick that fully depletes its own source stock unit failed with HTTP 500 `ACTIVE_PICK_MESSAGE`. Root cause: `confirmPick` nulled the completing pick line's `pickfromstockunit_id` *after* `transferStockToUnitLoad` (v1 `:306` vs transfer `:290`); the transfer depleted the source → `sendStockUnitToNirvana` → the SBDEV-2481 inline guard (v1 `StockunitBusinessService:323-324`, `findByPickfromstockunitId(su.getId()).isEmpty()`) saw the still-referenced completing line and threw.

**v2 question:** does the same self-depleting-pick 500 exist in v2, given v2 implemented SBDEV-2481 with a different architecture (`PickLineRealignmentService` + BLOCK_REALIGN loop)?

---

## 2b. Analysis — evidence chain (all v2 `origin/develop`, verified 2026-07-12)

Investigation: `tracer` pre-investigation + independent grep verification of the proof triad.

### The proof triad (why the bug can't fire on the picking path)

1. **The inline guard is GONE from nirvana.** v2 `StockunitBusinessService.sendStockUnitToNirvana` (`:401-426`) contains no `findByPickfromstockunitId` / `ACTIVE_PICK_MESSAGE` / `assertNoActivePickFor`. Its body is: reservation check (`:403-406`) → `changeAmount` to zero (`:408-410`) → re-fetch (`:414`) → already-in-nirvana short-circuit (`:416-420`) → move to nirvana UL + record (`:422-425`). The v1 `:323-324` guard is absent.

2. **The relocated guard runs only for `BLOCK_REALIGN`.** The single guard invocation on the transfer path is `pickLineRealignmentService.assertNoActivePickFor(sourceStockunit.getId())` at `StockunitBusinessService.java:356`, gated at `:354-355` by `PickLineActivityCodeClassifier.classify(activityCode) == Bucket.BLOCK_REALIGN`. (A second BLOCK_REALIGN gate at `:203` is on a different method, also not the picking path.)

3. **`CODE_PICKING` is `PASS_THROUGH`, not `BLOCK_REALIGN`.** `PickLineActivityCodeClassifier`: `BLOCK_REALIGN_CODES` = `{CODE_MOVE_FIX_ASSIGNMENT, CODE_MANUAL_TRANSFER, CODE_TRANSFER, CODE_ON_HOLD}` (`:33-37`); `CODE_PICKING` (and `CODE_PICKING_CARRIER_EMPTY`, `CODE_PICKING_CHANGE_STOCK_UNIT`) are in `PASS_THROUGH_CODES` (`:60-62`). `confirmPick` passes `CODE_PICKING` to the transfer (`PickingorderBusinessService.java:552`) and to `changeReservedAmount` (`:542`). So neither transfer branch reaches the guard on a picking confirm.

### Completeness check (no other guard reads the live FK on this path)

Every caller of `findByPickfromstockunitId` in v2 `src/main`:
- `PickLineRealignmentService.java:89, 102, 125` — the extracted realign/guard helpers (BLOCK_REALIGN-gated on this path).
- `MobileInfoService.java:369` — read-only info display.
- (declaration: `PickingorderPositionRepository.java:33`.)

None is on the `CODE_PICKING` confirm → transfer → nirvana path.

### The ordering "bug" is present but inert

v2 `confirmPick` still nulls the FK *after* the transfer: `transferStockToUnitLoad` at `PickingorderBusinessService.java:552`, then `setPickfromstockunitId(null)` at `:568`. Identical to v1's "buggy" ordering — **but harmless**, because on the picking path (a) `sendStockUnitToNirvana` no longer reads the FK, and (b) the relocated guard is BLOCK_REALIGN-only. Branch-B (`StockunitBusinessService.java:379` `fixLocationAssignment == null && sourceAmount == 0 → sendStockUnitToNirvana :380`) is still reachable from a picking confirm when the destination tote already holds the SKU, but it lands in the guardless nirvana method (reservation already released to 0 at `confirmPick:542`), so the unit is quietly moved to nirvana with no pick-line lookup and no throw.

### Secondary note (v1's rejected "Option C" is v2's correct design)

v2's `assertNoActivePickFor` narrows to **active** picks only (`isActive` = owning order state ≥ STARTED, `PickLineRealignmentService.java:77-94`). v1's plan explicitly rejected an "ACTIVE-only" guard as insufficient *for the picking case* — but v2 applies that narrowing **only on the external-move (BLOCK_REALIGN) path**, never on pick-confirm, so it is correct in v2 and irrelevant to this (non-existent) failure mode.

---

## 3. Design / Proposed Fix

**None.** No code change. This document records the applicability verdict only.

If any of the following ever change, re-open this analysis (they are the verdict's load-bearing assumptions):
- `CODE_PICKING` (or an unknown/empty activity code reaching the transfer on a pick confirm) is added to `BLOCK_REALIGN_CODES`.
- A `findByPickfromstockunitId` guard is reintroduced into `sendStockUnitToNirvana` or anywhere on the branch-B path.
- A picking-confirm path begins passing a BLOCK_REALIGN activity code into `transferStockToUnitLoad`.

---

## 4. V2-Specific Adaptation Notes

N/A — no change ported. (The relevant v2 adaptation fact is the SBDEV-2481 "extracted service" divergence documented above: the guard lives in `PickLineRealignmentService`, not inline.)

---

## 5. Prerequisites & Implementation Plan

N/A — no implementation. No branch, no migration, no sysprop, no deploy-order dependency.

---

## 6. Test Plan

No automated test added (no code change). **Optional runtime confirmation** (discriminating probe, if desired before closing): in a v2 test tenant, reproduce the PICK227210 shape — a `PICK_PACK` cop fragmented 2+1 across two ULs where the 2nd pick fully depletes a 1-unit source, the destination tote already holds the SKU, and the source location has no fix-location-assignment — and confirm the depleting pick via `/v3/picking/processPick`. Expected: pick completes, source stock unit lands in nirvana, **no `ACTIVE_PICK_MESSAGE`**. (Full-context ITs remain `@Disabled` per SBDEV-2217; this is a manual/staging probe.)

### Manual test plan

| Scenario | Environment | Steps | Expected Result | Pass/Fail |
|---|---|---|---|---|
| Self-depleting pick (v1 repro shape) | wms2 staging | 2+1 fragmented `PICK_PACK` cop; confirm the depleting line where the tote already holds the SKU and the source has no FLA | Pick completes; source SU in nirvana; no `ACTIVE_PICK_MESSAGE` (v2 already correct) | |
| External move still blocked | wms2 staging | With a live pick line on stock unit X, attempt a `CODE_TRANSFER`/`CODE_MANUAL_TRANSFER` move of X | Blocked (BLOCK_REALIGN guard preserved via `assertNoActivePickFor`) | |

---

## 7. Horizontal Scalability Validation

No code change → no new horizontal-scaling surface. All 10 concerns **N/A** (In-JVM state, connection-pool math, scheduled jobs, long transactions, request affinity, retry/idempotency, tenant context, distributed-lock correctness, cache invalidation, external notifications) — this document changes nothing at runtime.

---

## 8. Notes

- **Intentional v1↔v2 divergence (do NOT re-flag):** v1 fixed this by re-ordering `confirmPick`; v2 does not need it because the guard was architecturally relocated out of the nirvana path. A future `wms-v1-sync-sweep` diffing `confirmPick` will see v2 still nulls the FK after the transfer — that is safe in v2 and must **not** be "fixed" to match v1.
- Pairs with v1 plan `260709-picking-nirvana-guard-blocks-self-depleting-pick.md`.

---

## 9. Acceptance & Implementation

No acceptance script (no code change). Verdict evidence is the proof triad in §2b (three direct-source facts + the completeness grep), gathered by `tracer` pre-investigation and independently grep-verified 2026-07-12.

**ralplan skipped (stated per skill exception):** the migration skill mandates ralplan for plans that feed `wms-tdd-gate`; this is a zero-code-change NOT-APPLICABLE verdict with nothing to implement or consense on, matching the many already-done / not-applicable analyses recorded directly in `sync-log.md`. The load-bearing claim (guard unreachable on the picking path) was adversarially traced and self-verified.

---

## 10. Review log

- **2026-07-12 — tracer (read-only):** verdict NOT-APPLICABLE, high confidence. Proof triad: (1) `StockunitBusinessService.sendStockUnitToNirvana:401-426` has no inline guard; (2) the only `assertNoActivePickFor` call (`:356`) is BLOCK_REALIGN-gated (`:354-355`); (3) `CODE_PICKING` is `PASS_THROUGH` (`PickLineActivityCodeClassifier:60`), not BLOCK_REALIGN (`:33-37`). Ordering bug structurally present (`PickingorderBusinessService:552`→`:568`) but inert.
- **2026-07-12 — self-verification (grep):** all four facts confirmed against `origin/develop`, plus completeness — every `findByPickfromstockunitId` caller is `PickLineRealignmentService` (89/102/125) or read-only `MobileInfoService:369`; none on the picking-confirm write path. Verdict accepted.
