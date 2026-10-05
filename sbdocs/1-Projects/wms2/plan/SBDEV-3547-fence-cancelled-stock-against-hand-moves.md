---
title: "Fence cancelled-order stock against hand moves — keep PICKED_FOR_GOODSOUT through cancel"
ticket: "SBDEV-3547"
ticket_url: "https://app.clickup.com/t/868mabmfn"
type: "bugfix"
priority: ""
status: "in-progress (PR-A on dev 35c3428b 2026-09-28; PR-B on dev 5d08e9fc 2026-09-29; NOT for PRD until G1–G3 + PRD type-config check)"
tier: T3
project: ["wms2"]
version: "v2"
requester: "Nam Park"
created: "2026-09-27"
updated: 2026-09-28
revision: "consensus round 2 + round-2 Lows"
db_verified: true
base_commit: "0ac108e2 (wms2-api origin/develop, 2026-09-27; drift since a5b36931 touches only StockViewRepository, SBDEV-3550)"
related:
  - "[[SBDEV-3321]]"
  - "[[SBDEV-3339]]"
  - "[[SBDEV-3341]]"
  - "[[SBDEV-3353]]"
  - "[[SBDEV-3381]]"
  - "[[SBDEV-3452]]"
  - "[[SBDEV-3548]]"
tags:
  - plan
---

# SBDEV-3547 — Fence cancelled-order stock against hand moves

**Ticket:** [SBDEV-3547](https://app.clickup.com/t/868mabmfn) · **Tier:** T3 (data integrity: stock leaves a pending reversal and is destroyed; fail-closed change to three cancel paths and two operator paths) · **Mode:** DELIBERATE
**Evidence:** `SBDEV-3547-evidence/analysis.md` (cited *A§n*), reviews `review-{architect,critic}-round{1,2}.md`, rail instrument `rail-census.py`. **Code:** every citation is `git show origin/develop:<path>` at `0ac108e2` (the only `src/main` drift from `a5b36931` is one line in `StockViewRepository`, SBDEV-3550; no cited line moved).
**Settled, not re-opened:** D1′ (supersedes D1), D2, D3′ (restates D3), D4, and the "carried as-is" list (A, *Resolved* + *Round-1 review decisions*).

## Round-2 changes

| Finding (critic # / architect F#) | Where addressed |
|---|---|
| 1 + 1b / F1 — M6 already refuses 100; AC-D3 could not fail | §0 M6, §2 B3, §4 A5 (message moves to PR-A, keeps `value not changed`), §7.1, §7.3 (:2498/:2528 stays green), §4 A4 (:869/:871 → EXEMPT) |
| 2 / F4 — swap test against a non-mock | §7.1 row A1 (captor on `recordForTransferUnitLoad` args 8/9), §4 A1 javadoc warning |
| 3 — IT lane and fixture | §7.1 IT spec (H2 full-context under failsafe, seeded rows, mocks, suffixes, attributable failure; MMU step dropped) |
| 4 — rail rule narrowed | §4 A4 (condition-level rule, top-level throw, reporting-stage control, self-tests, census re-run and quoted). Note: CRS:289 is **not** an offence under that rule (it has a `!= NOT_LOCKED` conjunct at :290); it is printed as an allowlist exclusion |
| 5 — R5 stale | §8 R5 (four-tenant measurement, Tote→carrier = 0 on all four); WineCo briefing re-based on the Move Stock measurement (R9, gate G3) |
| 6 — RED vs GREEN | §7.1 column; §6 steps name what must be red |
| 7 — RALPLAN-DR missing, steelman absent | §5; ADR alternatives |
| 8 / F2 — rail green by moving code out of scope | Resolved by construction: no util policy class; the D1′ check is a private MMU method (in scope), EXEMPT (literal text only); behaviour pinned by the two RED MMU carrier-arm tests; AC-6 rewritten |
| 9 / F3 — pool slots | §4 A3, §7.5 |
| 10 / F5 — `typeId == null` before `findById` | §4 B-2 `isToteType`; test `_toteTypeIdNull_` |
| 11 / F6 — C3 shape | §4 B-1 (inside the existing lambda) |
| 12 — `never()` too broad | §7.1 (`never().findById(any())`, existing-pallet carrier arm) |
| 13 — BOL tests need synchronization | §7.1 BOL row (precedent `PickingorderBusinessServiceUnitTest:1692/:1765`) |
| 14 — mutation discipline | §7.2 |
| 15 — manual steps | §7.4 steps 0, 3, 4 |
| 16 / F7 — bulk delete, pre-run finder | §4 B-3 |
| Missing: PRD-gate rows; M5 merge strand | §6.1 G1–G4; §8 R2 |
| Critic open questions (Tote as pallet / putaway source) | §0 "Reachability" |
| D1′ re-check (policy shape, tests, rail, AC-3, risks) | §4 B-2, §4 A4, §7.1, §9 AC-3, §8 R4/R10 |
| **Round-2 Lows applied** (architect N1–N4, critic L1–L5 + 2 open questions) | N1 §8 R9 · N2 §0 grep + reachability · N3 §4 A4, §6.3, AC-6 · N4 frontmatter, §4 B-2 · L1 §4 A4/A5/B-3, §6.3, AC-6 · L2 §4 A4 keying, §7.1 · L3 §4 A5 · L4 §7.1 IT · L5 §6.2/§6.3 step 1 · OQ §7.1 IT command, §4 A3 index wording |

## 0. Affected sites

Methods: A§0.1–§0.3; `sendToClearing` callers `git grep -n 'sendToClearing(' origin/develop -- src`; carrier writers `git grep -n 'transferUnitLoadToCarrier(\|transferUnitLoadToCart(\|setCarrierunitloadId(' origin/develop -- src/main`. **Blind spot (all greps here):** literal call text only; no reflection, method references or unmerged branches.

| # | Site (origin/develop) | Disposition |
|---|---|---|
| C1 | `CustomerorderService.java:1037` `toteStock.forEach(su -> su.setEntityLock(NOT_LOCKED))` (cancelOrder) | **Fixed, PR-B**: skip 100 (D2) |
| C2 | `PickingorderBusinessService.java:701` same shape (cleanUpCancelledOrder) | **Fixed, PR-B** |
| C3 | `CustomerorderService.java:490-493` per-row lambda (forceCancelOrder `< PACKED`; unreachable per :480–484) | **Fixed, PR-B**, inside the lambda |
| C4 | `CustomerorderService.java:524` parcel stock (forceCancel PACKED arm) | **Excluded, keeps clearing** + comment: the arm writes no `recordCancellation` row (A§2.3); P1 |
| M1 | web Move Stock → `StockunitBusinessService.java:286-289` `if (lock != NOT_LOCKED) throw` | Code unchanged; already refuses 100. After B-1 it now **sees** 100 on cancelled totes (R9). PR-A: message (B5) |
| M2 | `StockunitService:571` → `SourceLockGuard` | Unchanged. PR-A: message |
| M4 | `MobileMoveUnitloadService` carrier arm: `:485` (inbound-pattern branch, before `createUnitload` :492) and `:512` → `transferUnitLoadToCarrier` `:514` | **Fixed, PR-B (D1′)**: refuse a Tote-type source carrying 100 stock. Location arm (`:424` → `transferUnitLoadToLocation`), `scanUnitLoad`, and the `== ON_HOLD` checks `:163/:169/:359/:365` unchanged |
| M5 | `StockunitService.java:614-616` Move Stock → Damaged, `ignoreLock=true`, 100 → 103 | **Residual** (D3′; SBDEV-3341 asymmetry). R2 |
| M6 | `StockunitService.java:885-897` adjustAmount `switch` allows only ON_HOLD/QF/NOT_LOCKED; `default:` throws before `changeAmount` :899 | **Already refuses 100** (pinned `StockunitServiceUnitTest:2498`). The message `"unexpected lock=100 found. value not changed"` is unactionable → PR-A message only (D3′). Callers: `StockUnitController:318/:360` only |
| M7 | `UnitloadService.java:570` `deleteUnitLoad`; stock loop `:596` sends every SU to Nirwana (`:604`), no lock check | **Fixed, PR-B** (D3′) |
| BOL-1/2 | `BillofladingService.java:675-680` (closeBOL), `:1604-1609` (finishTransfer) bulk `UPDATE Stockunit … entityLock` | **Not fenced; made visible, PR-A** (A3) |
| SC | `UnitloadBusinessService.java:691` passes `(…, activityCode, comment, orderNumber)` into `:221` `(…, activityCode, orderNumber, comment)` | **Fixed, PR-A**. All 5 main callers (`CustomerorderService:494/:528/:1034`, `PickingorderBusinessService:698`, `MobileMoveUnitloadService:722`) pass `(…, CODE_TRANSFER, null, <orderNo or null>)`; none compensates |
| — | **Unchanged, and why:** C5 UL lock `:488/:519` (not the fence, A§0.1); C6 `CancellationReversalService:418/:482/:634` (consume the fence); M3 `MobileTransferOrderService:423-440` (refuses); MMU `:767/:804` (allowlist-shaped); M8–M11 removeLock, SDR PATCH (405), putaway/replenish, empty-tote reuse (refuse or unreachable, A§0.2) | — |

**Reachability — can a fenced Tote reach a carrier or truck another way?** (critic's open questions, traced on origin/develop; PRD read-only 2026-09-27)
- **Truck loading.** `MobileTruckLoadingWriteService:299` reads the "pallet" by label with no type check, and PHASE C only rejects parcels that have no order (:399-:405). That is not enough to make a tote-as-pallet impossible. What stops it is that both entry steps call `OutboundPalletLabelGuard.requireOutboundPalletLabel` (`MobileTruckLoadingService:92`, `:167`). On all four PRD tenants, **0 Tote labels match** the configured `STRING_PATTERN_OUTBOUND_PALLET`/`PRINTING_PATTERN_OUTBOUND_PALLET_LABEL` (230 c1wh / 1,036 WineCo / 8 Hydra / 28 nywh-shipitez totes checked). Positive control: 1,231 c1wh Pallet labels match. **Blind spot:** this is a label-scheme guard that depends on configuration, not a type guard. R10.
- **Putaway.** `MobilePutAwayService.findUnitLoad` (:137-:149) accepts only Pallet or Box types, so a Tote is refused (`entityNotFoundForName`). `storePalletOnLocation` (:167) has no type check, but it calls `transferUnitLoadToLocation`, which is a relocation. D1′ allows relocations.
- **Palletize.** `MobilePalletizeWriteService:357` (`scanPallet`, carrier call :402) and `scanParcelBulk` (:530; order at :561, carrier call :589) both resolve the order by parcel label (`findIdByParcelLabelId`, `CustomerorderRepository:215-219`, `c.parcel_id`). On all four PRD tenants every order parcel is a Package (106,804 / 473,027 / 238 / 1,401 orders). So a Tote is never a parcel.
- **Other carrier writers:** `AdviceService:238` (hub-and-spoke parcels), `ParcelMonitorViewService:320/:322` (packing; :322 is a direct `setCarrierunitloadId`), `ReceivingService:575` (inbound) take no picked tote; `BillofladingService:865` sets the carrier on a Package it has just created (:863); `StockunitService:410` moves stock first with `ignoreLock=false` (refuses 100); `MobilePickingService:1645` assigns a tote to a cart at pick start, where M11 refuses a non-empty tote. The only other `setCarrierunitloadId(` writers are `UnitloadBusinessService:503` (inside `transferUnitLoadToCarrier`) and `:333` (clears to null). All are covered by the palletize DB control (every order parcel is a Package, four tenants).
- **SDR.** `Unitload` and `Stockunit` are both in `SDR_WRITE_WITHDRAWN` (`RestConfiguration:441`, entries :545/:546), so `carrierunitloadId` cannot be written over HTTP.

## 1. Problem statement

Cancelling an already-picked order leaves the picked stock on a tote at Clearing. The pending reversal (`customerorder_cancellation_log.reversal_required`) needs that stock intact. But two of the three cancel paths reset its lock to 0, so any hand move can drain the tote and strand the reversal.

- **c1wh-shipitez PRD (re-queried 2026-09-27):** order 121691091, tote **C1-0063**, sent to Clearing at 21:50:19Z by cancelOrder (:1034); C1 cleared the locks. rfernandez then ran 4× `MANUAL_SPLIT` into flowbins (21:54–21:55Z); the tote drained and has been reused 6×. Log rows 1–4 are still `reversal_required`; their SUs are amount 0 at lock 2 on Nirwana, which `completeReversal` refuses (`CancellationReversalService:288-297`). Stranded.
- **Hydra PRD, the fence holding:** T-0002/T-0007 (cancelled before SBDEV-3339, which never cleared the lock) sat at 100 for up to 54 days with zero operator moves; `completeReversal` resolved them on 2026-09-23 (A§1.2).
- **Ticket corrections:** "the `== ON_HOLD` arm succeeded on T-0002" is a static trace, not a recorded move (A§1.2). "`TransferUnitLoadToLocationSourceLockAsymmetry` flips" is false; only its javadoc goes stale (real flips: §7.3).

## 2. Root cause

- **B1 — cancel lowers PICKED_FOR_GOODSOUT (C1/C2/C3).** `confirmPick` stamps 100 (`PickingorderBusinessService:1161`) in the PICKED transaction and `CancellationLogService:47` records `reversalRequired = state >= PICKED`, so at C1/C2 "SU at 100" already means "a reversal is owed" (A§2.1). The forEach writes 0 anyway, lifting the only guard M1–M3 honour. c1wh is this bug.
- **B2 — Move Unit Load onto a carrier.** MMU refuses only `== ON_HOLD`. A tote carrying 100 stock can be loaded onto a pallet (:514) and ride to BOL close, whose bulk UPDATE overwrites the lock (B4). A relocation does not harm the reversal: `completeReversal` works by SU id, and `toteState` goes by label (A§2.2, D1′).
- **B3 — destroy path.** `deleteUnitLoad` checks only the UL's To-Delete state (:583) and sends every SU to Nirwana (:604). adjustAmount already refuses 100 through its `switch` (:885-897). Only its message is unhelpful.
- **B4 — BOL bulk overwrite is invisible** (`BillofladingService:675-680`, `:1604-1609`).
- **B5 — floor messages.** R1 (`StockunitBusinessService:288-289`) shows a bare `locked=100` and adjustAmount's `default:` arm `unexpected lock=100`; neither says what to do.
- **B6 — `sendToClearing` argument swap.** Every cancel's Clearing move stores the order number in `additionalcontent` and NULL in `ordernumber` (c1wh `unitload_record` 121692146; the same holds on WineCo, per F4).

## 3. Files touched (src/main/java/net/aim_ai/wms/…)

| PR | File | Change |
|---|---|---|
| A | `service/UnitloadBusinessService.java` | :691 argument order; javadoc warning on `sendToClearing` |
| A | `util/LockRefusalMessages.java` (new) | `describe`, `goodsOutHint` |
| A | `util/SourceLockGuard.java`, `service/StockunitBusinessService.java` | R2 / R1 messages |
| A | `service/StockunitService.java` | A5: adjustAmount `default:` message |
| A | `repo/jpa/CustomerorderCancellationLogRepository.java`, `service/BillofladingService.java` | A3 |
| B | `util/CancelLockRelease.java` (new), `service/CustomerorderService.java`, `service/PickingorderBusinessService.java` | B-1 |
| B | `service/mobile/MobileMoveUnitloadService.java` | B-2 (private method, 2 call sites) |
| B | `service/UnitloadService.java` | B-3 |

No Flyway migration, sysprop, endpoint, DTO or `messages*.properties` change.

## 4. Fix design

### 4.A PR-A — fail-open (`bugfix/SBDEV-3547-a-visibility`)

**A1. `sendToClearing` swap (B6).** At `:691`, change the call to `transferUnitLoadToLocation(unitload, clearingLocation, true, activityCode, orderNumber, comment)`. Add a javadoc warning on `sendToClearing`: its own parameter order is `(comment, orderNumber)`, the reverse of every sibling wrapper (`sendToNirvana:586`, `relocateEmptiedContainer:674`). Both parameters are Strings, so a swap still compiles, and the javadoc must say not to reorder them. Only audit rows and ReportService read `ordernumber`, so no behaviour changes (F4).

**A2. Lookup-free messages (B5).** Add a new static `util/LockRefusalMessages` with no repositories:
- `describe(Integer)` → `"100 (Picked)"` (takes over `SourceLockGuard.describe` :108, which delegates). `goodsOutHint(label)` → `" Stock on <label> is reserved for goods-out. If its order was cancelled, complete the reversal on the mobile Cancellation screen, or ask an outbound manager, before moving it."` No Waive button (SBDEV-3548 carve-out), no order: 100 also marks every live picked tote.
- **R1:** `"Source stockUnit=" + id + " is locked=" + describe(lock)` + hint only at 100 (`sourceUnitload` loaded at :237). **R2:** `SourceLockGuard:94-96` appends the same hint at 100. `is locked=<code>` survives (§7.3). The 1-arg `BusinessException` sets `key="placeholder"`, so tests assert substrings; `getKey()` would pin nothing.

**A3. BOL visibility (B4).**
- A private `reportPendingReversalsOnShippedPallets(List<Long> palletIds, String bolNumber)` runs **immediately before** the Stockunit bulk UPDATE at `:675` and `:1604`.
- New repository method, declared here so that it does not count as escalation trigger 2:
  ```java
  @Query("SELECT l FROM CustomerorderCancellationLog l, Stockunit s, Unitload u "
       + "WHERE l.reversalRequired = true AND l.reversalCompletedAt IS NULL "
       + "AND s.id = l.picktostockunitId AND u.id = s.unitloadId AND u.carrierunitloadId IN :palletIds")
  List<CustomerorderCancellationLog> findPendingReversalsOnPallets(@Param("palletIds") Collection<Long> palletIds);
  ```
  It mirrors the bulk UPDATE's WHERE clause (children of pallets, one level). Its predicate matches the partial index `idx_cancel_log_reversal_pending` (`V2.2.00:3869`, `WHERE reversal_required AND reversal_completed_at IS NULL`), but the index leads with `(tenant_name, facility_code, …)`, so at best the planner scans the whole partial index. Harmless at 4 pending rows; not an index-served lookup.
- When non-empty: an inline `LOG.warn` breadcrumb (BOL, `logId/order/tote/suId`) outside any try (precedent `PendingReversalReconciliationJob:188-192`), then `registerSynchronization` whose `afterCommit()` calls `messageService.createServiceLog(...)` **directly** in a try/catch logging ERROR — never via a self-deferring wrapper (`OmsNotificationService:68-105`).
- **Why after commit:** an inline row would survive a closeBOL rollback as a false "shipped" record. `createServiceLog` is `REQUIRES_NEW` (`MessageService:75`); from `afterCommit` it briefly holds **2 pool slots** (the outer connection is released only after completion), with the row locks and the BOL `FOR UPDATE` (:355) already released; bounded by the pending-row count (4 c1wh, 0 Hydra). `REQUIRES_NEW` is necessary: a REQUIRED write would join the finished transaction and be lost (F3).
- The method never refuses. Its javadoc states that the overwrite is deliberately not fenced (SBDEV-3321 architect §1.3.1).
- **Blind spot:** stock sitting directly on a "pallet" UL is not matched, and neither is the bulk UPDATE. §0 shows no tote reaches that position today.

**A4. Rail (item 6, "carried as-is").** `MoveSourceLockComparisonRailTest` is a source-text scan in the `NestedCallSiteRailTest` shape. It is not ArchUnit, which cannot see the comparison constant (A§4.5).
- **Scope (derived at test time):** every `src/main/java` class whose comment- and string-stripped text calls `.transferUnitLoadToLocation(`, `.transferUnitLoadToCarrier(`, `.transferStockToUnitLoad(` or `stockunitService.transferStock(`. That is **19** today. The D1′ check lives in MMU, so it is in scope by construction (finding 8 / F2).
- **Offence (condition level):** an `if` whose body has a **top-level** `throw` (not one nested in an inner block), whose condition holds ≥1 source-lock comparison — `…getEntityLock() ==/!= K`, `Integer.valueOf(K).equals(…getEntityLock())`, or a local `int|Integer v = …getEntityLock()` then `v ==/!= K` — and in which **no** comparison is against `NOT_LOCKED`/0 (a NOT_LOCKED conjunct makes the whole condition allowlist-shaped). "Top-level" because the nested variant also flags `StockunitService:601`, a permission throw inside a QF branch.
- **Census, re-run with exactly this rule** (`SBDEV-3547-evidence/rail-census.py`, re-run read-only on origin/develop 0ac108e2; output identical to a5b36931):
  ```
  scope: 19 classes
    allowlist-conjunct (not an offence) CancellationReversalService.java:289
    OFFENDER StockunitService.java:869 / :871 (== SHIPPED / == GOING_TO_DELETE, adjustAmount)
    OFFENDER StockunitService.java:918 / :920 (same, adjustReservedAmount)
    allowlist-conjunct (not an offence) StockunitService.java:693 / :701 / :708, UnitloadService.java:296
    OFFENDER MobileMoveUnitloadService.java:163 / :169 / :359 / :365 (== ON_HOLD)
    allowlist-conjunct (not an offence) MobileMoveUnitloadService.java:767 / :804, MobilePickingService.java:1422 / :1437
  offenders: 8
  ```
  **Correction to critic 4:** `CancellationReversalService:289` carries `sourceLock != NOT_LOCKED` (:290), so it does not match the rule. MMU :767/:804 do not match either.
- **One `EXEMPT` list keyed on `file + enclosing method + condition snippet`** (not line numbers), each with a reason, and **each key must match exactly one offence**. Chosen over a per-key-count multiset because a `file + snippet` key collapses 8 entries to 5 (MMU :169/:365, StockunitService :869/:918 and :871/:920 share text), and the enclosing method separates every pair today (scratch run of the census `scan()` on 0ac108e2: 8 distinct keys, max 1 match each), keeps one reason per site, and a second identical offence in the same method fails as an over-match rather than silently sharing an entry. No KNOWN_OFFENDERS list: PR-B rewrites none of these sites (L1: B-3 *adds* one, below). MMU ×4 (`scanUnitLoad` :163/:169, `scanDestination` :359/:365): "ON_HOLD refusal, kept by D1′"; `StockunitService.adjustAmount` :869/:871: "denylist made redundant by the allowlist `switch` at :885, the real guard"; `adjustReservedAmount` :918/:920: "reserved-amount edit neither moves nor destroys stock". **PR-B adds two:** `MobileMoveUnitloadService.assertNotFencedToteOntoCarrier` (B-2): "D1′ carrier-arm fence; single-value refusal by decision"; `UnitloadService.<B-3 private check>` (B-3; `UnitloadService` is in scope via `.transferStockToUnitLoad(` :175, and every natural B-3 shape is flagged, checked with `scan()`): "D3′ destroy guard; single-value refusal by decision". A5 adds **no** entry: its hint is a ternary inside the existing `default:` throw (not flagged, checked with `scan()`).
- **The test fails when** an unlisted offence appears; a key matches zero sites (stale; self-test mutant: delete MMU `scanDestination` :365, which a `file + snippet` key could not see because :169 still matches) or more than one; or the reporting-stage control finds MMU :767, :804 or CRS:289 missing from the *allowlist-conjunct* set (the control against a narrowed lexer).
- **What pins D1′ is the two RED MMU tests** (`scanDestination_carrierArm_refusesToteAtPickedForGoodsout`, `scanDestination_inboundPalletArm_refusesToteAt100_beforeCreateUnitload`), not the rail. The EXEMPT entry pins only the literal text: an equivalent rewrite (a `continue` guard, or `anyMatch` then `if (fenced && tote) throw`) returns `[]` from `scan()` and leaves the entry stale. A stale entry means "review this change", never "delete the line". The same holds for B-3 and its two RED `UnitloadServiceUnitTest` rows.
- **Self-tests** (runtime-built snippets, SBDEV-3353 p4 precedent; verified with the census script): must fire on `== ON_HOLD` alone, the equals form, the local-variable form and the B-2 early-return shape; must **not** fire on the `:767` shape, a non-throwing comparison, or a nested permission throw.
- **What it is worth, honestly:** after D1′ the rail fixes nothing in PR-B. Its value is recurrence only: a new single-value lock refusal in a move-entry class needs a written reason at review, and a change to the D1′/B-3 check text forces a review (its behaviour is pinned by the RED service tests, not the rail).
- **Blind spots (javadoc):** helper-wrapped reads, `switch (getEntityLock())` (the real guard in adjustAmount), reflection, wrapper-only entry classes, and a lexer that is not a parser. Green means the known shape has not recurred.

**A5. adjustAmount message (D3′).** In the `default:` arm (`StockunitService:896`), keep the text `"unexpected lock=" + lock + " found. value not changed"` and append the hint **with a ternary inside the existing `throw`**: `+ (Integer.valueOf(PICKED_FOR_GOODSOUT).equals(lock) ? goodsOutHint(label) : "")`. No new `if…throw` is added, so the rail sees nothing new (L1).
- Label, fail-open (as O2): `unitloadId == null ? "this container" : unitloadRepository.findById(unitloadId).map(Unitload::getLabelid).orElse("this container")`. `unitloadRepository` is already injected (:65). Evaluated only on the 100 branch of the ternary (O3). Never `orElseThrow`: that would replace the expected `BusinessException`.
- `value not changed` is kept, so the shared helper at `StockunitServiceUnitTest:2528` stays green, and `adjustAmount_pickedForGoodsout_doesNotCommit` (:2498) stays green **with no new stubbing**: `testStockunit` has a non-null `unitloadId` (:170), the unstubbed `findById` returns `Optional.empty()`, and the label falls back to `"this container"`.
- The redundant `:869/:871` denylist stays as it is (EXEMPT). Deleting it would change the 405/2 messages with no ticket.

### 4.B PR-B — fail-closed (`bugfix/SBDEV-3547-b-fence`)

**B-1. Cancel keeps 100 (D2).**
- `util/CancelLockRelease.releaseUnlessGoodsOut(Stockunit su)`, null-safe: if `!Integer.valueOf(PICKED_FOR_GOODSOUT).equals(su.getEntityLock())` set `NOT_LOCKED`. Javadoc: *a cancel never lowers PICKED_FOR_GOODSOUT, the fence a pending reversal relies on; other locks belong to other processes and reset as before.*
- C1 `:1037` / C2 `:701`: `toteStock.forEach(CancelLockRelease::releaseUnlessGoodsOut)`; `saveAll` stays unconditional (:1038 / :702) so the AC-2 ordering pin stays meaningful. C3: call it **inside the existing per-row lambda** (:490-493), keeping the per-row `save` (F6).
- C4 `:524` is unchanged. It gets this comment: *"Deliberately clears 100: this arm writes no cancellation-log row, so a kept 100 would be a strand with no Cancellation-screen entry, no waive and no removeLock route. See SBDEV-3547 P1."*

**B-2. Move Unit Load refuses a Tote at 100 on the carrier arm only (D1′).**
- **⚠ Dev test finding (2026-09-29): this route was not open.** `UnitloadBusinessService.transferUnitLoadToCarrier` already refuses any source type with `onotherunitloadallowed = false`, whatever its lock. Tote is false on dev WineCo, and the SBDEV-3320 comment says every tenant. The only exemption, `transferUnitLoadToCart` (Tote → Cart), is called only by `MobilePickingService` when it assigns a tote. On the inbound-pallet branch, `createUnitload` ran first but was rolled back, because `scanDestination` is @Transactional. So D1′ is **defence in depth** (an earlier, actionable message, and a guard if the type config changes), not a closed hole. The plan's premise that this was one of the hand routes that ignored the fence was wrong. R5's measured 0 tote→carrier moves on PRD is consistent with this.
- **Shape:** private MMU method `assertNotFencedToteOntoCarrier(Unitload source, List<Stockunit> stock)`, called right after the two carrier-arm `assertSourceCarrierNotOnTruck` calls: `:485` (inbound-pattern branch, under `!dto.isMoveStock()`, before `createUnitload` :492, so no pallet is created then refused) and `:512` (before `transferUnitLoadToCarrier` :514). **Not** at `:424` (location arm), in `scanUnitLoad` (destination unknown), or on the `isMoveStock` arms (`transferStock` → M1 refuses). `stock` = `stockUnitList` (:363), read under the source `FOR UPDATE` (:336). A util class with an `arm` parameter was rejected (§5).
  ```java
  for (Stockunit su : stock) {
      if (Integer.valueOf(PICKED_FOR_GOODSOUT).equals(su.getEntityLock())) {
          if (!isToteType(source)) return;          // Package at 100: SBDEV-3452 re-palletizing stays allowed
          throw new BusinessException("Tote " + source.getLabelid() + " holds stock unit " + su.getId()
              + " locked=" + describe(PICKED_FOR_GOODSOUT) + " and cannot go onto a carrier."
              + goodsOutHint(source.getLabelid()));
      }
  }
  ```
- **`isToteType(source)`** follows `SourceContainerGuard.judge` (:130-:139), failing open (O2): `typeId == null` → WARN, not a Tote, checked **before** `findById` because `findById(null)` throws `IllegalArgumentException` (precedent `CustomerorderService:1026`); missing type row → WARN, not a Tote; else `UNIT_LOAD_TYPE_TOTE.equals(type.getName())` (`WmsConstants:889`, null-safe).
- The type is read at most once per call site and only when a 100 is present (a Package at 100 sent to a new inbound pallet passes both :485 and :512, so two unlocked reads per request; harmless); no log rows (so no uncommitted-row blindness), no lock. ON_HOLD, Package-at-100, QF and location-arm behaviour and text are unchanged. Javadoc: `SourceLockGuard:69-73` and `UnitloadBusinessServiceUnitTest:903-907` record the carrier-arm rule.

**B-3. Destroy guard (D3′: M7 only).** In `UnitloadService.deleteUnitLoad` (:570, **no `@Transactional`**), refuse **before the loop at :596**, after the To-Delete check (:583) and the child check (:590).
The check is one private method (the B-3 EXEMPT key, §4 A4) written as a loop with `if (Integer.valueOf(PICKED_FOR_GOODSOUT).equals(su.getEntityLock())) throw`. If any SU in the `:593` list is at 100, throw `"Container " + originalLabel(unitLoad) + " holds stock reserved for goods-out (Picked, 100)." + goodsOutHint(...)`. The same private check runs over the collected list in `deleteUnitLoadRecursivePreRun`'s top branch (:430), via the existing `StockunitRepository.findByUnitloadIdIn` (:426) — no new persistence surface (F7). Type-blind by design (D3); measured cost 0 operator Tote/Package deletes (c1wh 60 d, Hydra 90 d; control 142 / 172 Case deletes). **Out of scope:** `bulkDeleteContainer` (`UnitLoadController:176-178`) still commits container #1 before refusing #2 (pre-existing; same as today's fixed-assignment refusal).

## 5. RALPLAN-DR (DELIBERATE)

**Principles.** P1 a fail-closed fence needs a floor exit (SBDEV-3321 architect §4.3) · P2 no decision reads log rows the cancel has not committed · P3 do not break measured live workflows · P4 guard at the harm point, smallest diff (D1′) · P5 visibility ships before enforcement (D4).

**Drivers (top 3).** P1, P2, P3.

| Decision | Options | Verdict |
|---|---|---|
| Fence predicate | (a) lock value 100 at C1/C2/C3 · (b) pending-reversal lookup at each refusal site · (c) a distinct "pending reversal" lock state written at cancel (architect steelman) | (a). (b) fails P2 and adds a query on the operator path. (c) is cleaner: no type heuristics, messages can name the Cancellation screen outright, and a leftover state is easy to detect. But it needs new handling in completeReversal, Waive, removeLock, `stock_view` and the web lock report, plus a Flyway seed. Rejected for scope under D2 |
| MMU shape (D1′) | (a) private method, 2 carrier-arm call sites · (b) util policy class with an `arm` parameter · (c) refuse in `scanUnitLoad` | (a). (b) adds a class outside the rail's derived scope (F2) and a parameter nobody needs after D1′. (c) cannot see the destination, so it would refuse relocations that D1′ keeps (WineCo: 50 Tote relocations in 365 d) |
| O1 rail lists | (a) one EXEMPT list with reasons, failing on stale entries · (b) red / `@Disabled` test · (c) rewrite the denylists into allowlist predicates to reach zero | (a). (b) breaks the floor and blocks every merge. (c) changes adjustReservedAmount and ON_HOLD behaviour with no ticket and against D1′ |
| O2 unresolvable type | (a) fail-open + WARN · (b) fail-closed | (a), the `SourceContainerGuard` precedent: no operator remedy for states that do not occur (0 Tote-labelled rows without a Tote type on c1wh or Hydra, F5) |

**Pre-mortem.** (1) PR-B reaches PRD before the Waive exit, no floor way out → G1/G2. (2) WineCo/c1wh floors keep draining cancelled totes by hand, get refused, escalate → G3 briefing; the hint names the route (R9). (3) A tote reaches a truck via a label matching the outbound pattern → R10/P3.

## 6. Implementation steps

### 6.1 Prerequisites and PRD gate

| Item | State / action |
|---|---|
| Base | Fresh `origin/develop` (≥ 0ac108e2). Worktrees `.claude/worktrees/wms2-api/SBDEV-3547-a` / `-b` |
| Baseline | Full `mvn -o clean test` plus failsafe, **adjacent in time** to the change. Use `-Dfailsafe.excludes`, never `-Dit.test='!…'` |
| DB / data | Symptom re-confirmed (§1). No data repair here. C1-0063's 4 rows are resolved by waive (`stockReturned=false`) once SBDEV-3381 is on PRD (ops) |
| Flyway / sysprops | None. Merging to develop is still a dev deploy plus a Flyway run of whatever is pending |
| PR-A → PRD | No gate (fail-open) |
| Order | PR-A merges first. PR-B rebases on it |
| **G1** | SBDEV-3381 (V2.2.34 + waive API) is in the running build on **each** of c1wh-shipitez, nywh-hydra, nywh-shipitez and wsl-wineco. Check with `/api/public/version` (full SHA) against the 3381 merge commit, not branch HEAD |
| **G2** | The same check for SBDEV-3548 (mobile Waive) on each tenant |
| **G3** | Floor briefing for **WineCo and c1wh**: "Stock on a cancelled tote at Clearing can no longer be moved by hand. Complete it on the mobile Cancellation screen, or ask an outbound manager." Warranted by R9, not by Move Unit Load. Hydra and nywh-shipitez measured 0 |
| **G4** | Re-run the §8 R5/R9 queries within 7 days of the release and quote them on the ticket |

### 6.2 PR-A
1. **Compile skeletons first** (L5), so every RED test fails on an assertion, not a compile error: `LockRefusalMessages` with stub methods returning `""`/`String.valueOf(lock)`; `CustomerorderCancellationLogRepository.findPendingReversalsOnPallets` (the §4 A3 query); the new `BillofladingService` constructor parameter plus a `@Mock` and the extra argument in the explicit `new BillofladingService(...)` at `BillofladingServiceUnitTest:145` (`BolCloseGuardPerTenantUnitTest:57` uses `@InjectMocks`; every test there throws before the bulk UPDATE, so the null repository is never reached). Then write the §7.1 PR-A rows. **Must be red before the fix, and record each failure message:** the swap test, the R1/R2 lock-100 hint tests, `adjustAmount_lock100_messageCarriesGoodsOutHint`, and the two BOL "writes after commit" tests. The rest are GREEN guards: turn each red with its named mutant, then restore it.
2. A1 → A2 → A5 → A3 → A4 (rail with the 8-entry EXEMPT list, 0 unlisted).
3. Full suite against the baseline. One independent review lane. PR into develop.

### 6.3 PR-B
1. **Compile skeletons first** (L5): `CancelLockRelease.releaseUnlessGoodsOut` with the current unconditional behaviour (sets `NOT_LOCKED`), so the keep-100 and `CancelLockReleaseUnitTest` rows fail on assertions. Then write the §7.1 PR-B rows, recording each failure message. **Must be red:** the three keep-100 cancel tests, the two carrier-arm refusals, the two delete refusals, and IT step 2. Flip the §7.3 tests in the same commit as the change they pin.
2. B-1 → B-2 → B-3 → add the D1′ and B-3 EXEMPT entries (10 total). Confirm that removing the B-2 check **and** removing the B-3 check each turn the rail red (stale key). The rail pins only literal text; D1′ is pinned by the two RED MMU carrier-arm tests and B-3 by its two RED `UnitloadServiceUnitTest` rows (§4 A4).
3. Write the IT. Full suite against the baseline. Review lanes. Open the PR. **Do not request a PRD release** until G1–G3 are confirmed.

## 7. Testing plan

### 7.1 New tests — RED-first vs GREEN-guard, and the mutant each must kill

| PR | Test | Kind | Mutant → must go red |
|---|---|---|---|
| A | `UnitloadBusinessServiceUnitTest.sendToClearing_recordsOrderNumberAsOrderNumber`: captor on `unitloadRecordService.recordForTransferUnitLoad` **args 8/9** (`UnitloadBusinessService:542`); `orderNumber=="ORD-001"`, `comment==null` | RED | restore the swap |
| A | `LockRefusalMessagesUnitTest` (`Picked`, `Cancellation screen`, `outbound manager`; asserts **absence** of `Waive`) | RED (new class) | PIT |
| A | R1 `transferStockToUnitLoad_lock100_messageNamesToteAndCancellationScreen` | RED | drop the hint |
| A | R1 `_lock104_hasNoGoodsOutHint` | GREEN | make the hint unconditional |
| A | `SourceLockGuardUnitTest.stockunitAt100_messageCarriesGoodsOutHint` | RED | drop the hint in R2 |
| A | `StockunitServiceUnitTest.adjustAmount_lock100_messageCarriesGoodsOutHint` (also asserts `value not changed`) | RED | drop the hint |
| A | `adjustAmount_lockTransfer_hasNoGoodsOutHint` | GREEN | make the hint unconditional |
| A | `BillofladingServiceUnitTest.closeBOL_writesServiceLogAfterCommit_whenShippedPalletCarriesPendingReversal`, `finishTransfer_…` twin. Non-empty tests call `TransactionSynchronizationManager.initSynchronization()`, invoke `afterCommit()` by hand, and clear in `@AfterEach` (precedent `PickingorderBusinessServiceUnitTest:1692/:1765`) | RED | delete the call; invert the predicate |
| A | `closeBOL_serviceLogNotWrittenBeforeAfterCommit` | GREEN | call `createServiceLog` inline |
| A | `closeBOL_registersNothing_whenNoPendingRows` | GREEN | register unconditionally |
| A | `MoveSourceLockComparisonRailTest` + 7 self-tests + stale-entry + allowlist-conjunct control | GREEN | add a bare `== ON_HOLD` throw in an in-scope class; delete MMU `scanDestination` :365 (stale key; a `file + snippet` key would miss it); duplicate :365 inside `scanDestination` (over-match); make the lexer drop `NOT_LOCKED` lines |
| B | `CustomerorderServiceUnitTest.cancelOrder_keepsPickedForGoodsout_resetsOtherLocks` (fixture 100 + 104) | RED | unconditional forEach → red on 100; skip-all → red on 104 |
| B | `PickingorderBusinessServiceUnitTest.cleanUpCancelledOrder_keepsPickedForGoodsout` | RED | same |
| B | `forceCancelOrder_belowPacked_keepsPickedForGoodsout` (reflection, like the existing NPE test) | RED | same |
| B | `forceCancelOrder_packedArm_stillClearsParcelStock_noReversalRowExists` | GREEN | apply the skip at :524 |
| B | `CancelLockReleaseUnitTest` (null, 0, 100, 103, 104) | RED (new class) | PIT; `equals`→`==` (NPE on null) |
| B | `MobileMoveUnitloadServiceUnitTest.scanDestination_carrierArm_refusesToteAtPickedForGoodsout` (existing pallet; message has the tote label and `Cancellation screen`) | RED | delete the `:512` call |
| B | `scanDestination_inboundPalletArm_refusesToteAt100_beforeCreateUnitload` (`verify(unitloadService, never()).createUnitload(...)`) | RED | delete the `:485` call / move it after `createUnitload` |
| B | `scanDestination_locationArm_stillRelocatesToteAt100` | GREEN | also call the check at `:424` |
| B | `scanUnitLoad_toteAt100_notRefused` | GREEN | call the check in `scanUnitLoad` |
| B | `scanDestination_carrierArm_stillMovesPackageAtPickedForGoodsout` | GREEN | drop `isToteType` (refuse any type) |
| B | `scanDestination_carrierArm_toteTypeIdNull_failsOpen` (`verify(unitloadTypeRepository, never()).findById(any())`) | GREEN | remove the null check (the mock would then see `findById(null)`) |
| B | `scanDestination_carrierArm_noTypeLookupWhenNo100` (Case at 0 onto an existing pallet; `never().findById(any())`. That path legitimately reads only `:490`'s `findByName`, and only on the inbound branch) | GREEN | look up the type unconditionally |
| B | `UnitloadServiceUnitTest.deleteUnitLoad_refusesContainerWithGoodsOutStock_beforeAnyNirvanaSend` (`never().sendStockUnitToNirvana`) | RED | move the check after the loop |
| B | `deleteUnitLoadRecursivePreRun_refusesWhenChildHolds100` | RED | drop the pre-run check |
| B | `CancelPreservesGoodsOutFenceIntegrationTest` (below) | RED at step 2 | revert C1 → "step 2: entity_lock expected 100, was 0" |

**`CancelPreservesGoodsOutFenceIntegrationTest`** runs in the **H2 full-context lane**. It extends `BaseRollbackIntegrationTest`: `jdbc:h2:mem:rollback_tenant`, `ddl-auto=create-drop`, Flyway off, no test transaction, so every write commits.
- **Lane:** `*IntegrationTest` is excluded from surefire (`pom.xml:588`) and run by failsafe (`:753`). Run it alone with the repo recipe: `mvn -o verify -Dit.test=CancelPreservesGoodsOutFenceIntegrationTest -Dtest=ZzzNone -Dsurefire.failIfNoSpecifiedTests=false -Dmaven.javadoc.skip=true -Dspringdoc.skip=true` (`-Dtest=ZzzNone` skips the surefire lane; never `failsafe:integration-test`, which reports `Tests run: 0` for any class). Read the failsafe report: `Tests run: 0` with a non-zero exit is not a pass.
- **Per-run suffixes:** an `AtomicInteger RUN` suffix on every name-looked-up row, following `CancellationReversalLockClearIntegrationTest:113-121`.
- **Seeded rows:** client; rack `LocationType`; **get-or-create once per context** the name-resolved locations `Clearing` (`sendToClearing` resolves it by name into an `Optional`; a second row makes the second method non-unique, and `cancelOrder`'s `catch (Exception e)` at `CustomerorderService:1061` would wrap that as `ToteTeardownException`), `EmptyTotes` (step 4 / §7.4 step 5) and `Nirwana`, via `findByName(…).orElseGet(save…)` (precedent `CancellationReversalLockClearIntegrationTest:675` EmptyTotes, `:1114` Nirwana), and `Spawn` (once); per-run `FinishedPicking-<run>`, `bin-<run>` (pick-from); unit-load types `Tote`, `Case` (**once per context, not suffixed**, precedent ⚠ :190); boxtype; 2 itemdata; tote `T-<run>` at FinishedPicking with 2 SUs at **lock 100** (seeded directly, as the precedent does); a customerorder at PICKED with `pickingtote_id` = the tote and 2 PICKED positions; a pickingorder in state **PICKED (below PACKED**, required by `canOrderPositionBeCancelled`) with 2 PICKED positions (`picktostockunit_id` = those SUs, `pickfromlocationname` = the bin) and its `pickingorder_unitload` row.
- **Mocked:** `MessageService` (`@MockitoBean`, precedent :145), plus the base class's `TenantHealthService` and `EndpointHealthCheck`. Nothing on the cancel path is mocked. `TenantContext` is null, and `CustomerorderPositionService:136-138` tolerates that. If `cancelOrder` needs another row, seed it; don't mock the service.
- **Steps:** (1) real `customerorderService.cancelOrder(order, false)`; (2) JdbcTemplate: `entity_lock` 100 on both SUs (`"step 2: entity_lock expected 100, was <n>"`) and 2 `reversal_required` rows whose `picktostockunit_id` are those SUs; (3) `stockunitService.transferStock(...)` to a bin → `BusinessException` containing `locked=100 (Picked)` and `Cancellation screen`; (4) `completeReversal` → stock in the bin at lock 0; (5) second method: `waiveReversal(stockReturned=false)` → lock 0, row closed.
- **What this IT adds:** the unit tests mock the persisted lock, and the `findByIdForUpdate`+`refresh` re-read inside `transferStockToUnitLoad` (step 3) is not visible from them.

### 7.2 Mutation discipline
PIT (JDK 21) for the two new `util/` classes (`LockRefusalMessages`, `CancelLockRelease`). Every service-site mutant in §7.1 is a named hand edit, run with its exact selector (e.g. `-Dtest='MobileMoveUnitloadServiceUnitTest#scanDestination_carrierArm_refusesToteAtPickedForGoodsout'`; several separated by `,`, never `+`), red output recorded, then restored. Check the surefire XML timestamp (a no-match selector leaves stale XML); `mvn clean` after any constant mutant.

### 7.3 Existing tests that flip by design (same commit as the change)

| Test | Why |
|---|---|
| `CustomerorderServiceUnitTest:4001-4014` "AC-1: releases the goods-out lock…" | rewritten as its inverse (B-1) |
| `CustomerorderServiceUnitTest:2307` `shouldSkipRapidPickingCleanupWhenNotStarted` (:2379 `rapidStock` 100→0) | now stays at 100 |
| `PickingorderBusinessServiceUnitTest:1545`, **:1593 only** | the fixture `stockUnit1` is 100 (:1559). :1594 (ON_HOLD → 0) stays green and pins "other locks still reset". This corrects A§7.1 |
| **Stay green:** `StockunitServiceUnitTest:2498` (`value not changed` kept, :2528); MMU "locked on hold" tests (`…UnitTest:321-353`, `:1243-1278`, `MobileMoveUnitloadServiceTest:431/:451`); SBDEV-3490 ordering pin `:690` (location checks still precede); `TransferUnitLoadToLocationSourceLockAsymmetry` (:910, javadoc only); `StockunitServiceUnitTest:2144/:2159/:2173/:2187`, `MobileTransferOrderServiceUnitTest:784/:817`, `CancellationReversalServiceUnitTest:560` (`is locked=<code>` kept) | — |

**Blind spot** of this census (A§7.1 method): assertions written as `isZero()` or `== 0`, and IT SQL asserts. The baseline-versus-after suite diff is the second instrument.

### 7.4 Manual test plan (dev WineCo `wms2-wineco-dev` = `dev_wh01_om1`; API or headless recipe)

| # | Step | Expect |
|---|---|---|
| 0 | **Baseline on the pre-PR-B build:** do step 1 | SUs `entity_lock=0` (proves the bug; PR-B must change it) |
| 1 | PR-B build: pick a 2-line order to a tote; cancel from OMS | tote at Clearing; SUs at 100; 2 pending rows |
| 2 | Web Move Stock one SU to a bin | toast `… is locked=100 (Picked). Stock on <tote> is reserved for goods-out…` |
| 3 | Mobile Move Unit Load: tote → a pallet label; then tote → a location | first refused, naming the tote and the `Cancellation screen`; second succeeds |
| 4 | Web adjust amount; web delete container | adjust refused with **`reserved for goods-out`** in the text; delete refused |
| 5 | Mobile Cancellation screen → complete | stock back, lock 0, tote empties to EmptyTotes |
| 6 | Repeat 1, then waive (`stockReturned=false`) | lock 0; row closed |
| 7 | A packed parcel at 100 onto another pallet; QF container out of Damaged | both still succeed |
| 8 | `unitload_record` for step 1's Clearing move | `ordernumber` = the order number (PR-A) |

### 7.5 Horizontal scalability and v2 constraints
- No in-JVM state, caches, scheduled jobs or new row locks. B-1 issues fewer Stockunit UPDATEs, and the B-2 type read is an unlocked `unitload_type` read taken after UL(source) `FOR UPDATE`. Lock order (SBDEV-2481/3442) is unchanged.
- A3's `afterCommit` briefly holds 2 pool slots, with no row locks, bounded by the pending-row count. It runs on the request thread, so the tenant context is still bound (precedent `ReceivingService:624`).
- No new `@Transactional` methods. `deleteUnitLoad` stays non-transactional, so it must refuse before mutating. Constructor injection is unchanged. SLF4J `{}` in the WARN lines. No properties files.

## 8. Risks & mitigations

| # | Risk | Mitigation |
|---|---|---|
| R1 | **Waive `lockRetained` becomes live.** After B-1, 100 is the normal waive input. The retained branch (`CancellationReversalService:603-617`) closes the row and leaves the SU at 100 forever | Exposure today: 0. Accepted. Propose-only detector P2 |
| R2 | **M5, Move Stock → Damaged** (`StockunitService:614-616`, `ignoreLock=true`, 100 → 103) | ~~Accepted SBDEV-3341 asymmetry (D3′). Needs `WEB_UI_ACTION_ADJUST_LOCK_DAMAGED`.~~ **Superseded by D5 (2026-09-29): the "needs ADJUST_LOCK_DAMAGED" premise was false (the function is checked only on the QF→Damaged-in-place branch), so M5 is now fenced in PR-B.** **Two outcomes:** (a) a fresh damaged SU — `completeReversal` refuses 103 visibly; (b) a **merge into an existing damaged SU** — the source drains, and the log's `picktostockunit_id` then points at a drained SU. That is a **strand** with c1wh's signature, not a visible refusal. Measured: 0 `stockrecord` rows from Clearing → Damaged in 365 d on all four PRD tenants (control: c1wh has 92 `DAMAGED` rows overall) |
| R3 | A tote is out of circulation for each pending reversal | Fail-safe (M11). C1-0063 was reused 6× in 4 days |
| R4 | Package-at-100 onto a carrier and QF out of Damaged are deliberately unchanged, and Tote relocations stay open (D1′) | WineCo moved Packages onto carriers 15× in 365 d (last 2026-04-03), which is the SBDEV-3452 re-palletizing workflow. The Package's exit risk is covered by C4 / `SourceContainerGuard`. Relocation doesn't harm the reversal (A§2.2) |
| R5 | **Four-tenant measurement** (replaces "2 of 4"). `unitload_record`, `activitycode='TRANSFER'`, `unitloadtype='Tote'`, operator ∉ {'', anonymous, anonymousUser}, 365 d: | "relocation" = `tounitload` NULL, "onto carrier" = non-NULL (`UnitloadRecordService:54` writes the destination UL's label). Rows are mostly v1-era on WineCo (v2 went live 2026-09-26). The lock at move time is not historised |
| | wsl-wineco-prd: **50 relocations / 0 onto carrier**. This includes the critic's 17 Clearing→StagingLane, 1 →Club04, 1 →PutAwayLane, and 3 live FinishedPicking→Staging. T-0082 was moved 7 min after its cancel | Under D1′ none of these are refused |
| | c1wh-shipitez-prd: 14 / **0** · nywh-hydra-prd: 0 / 0 · nywh-shipitez-prd: 0 / 0 | **D1′'s carrier refusal has 0 measured cost on four tenants.** Control that carrier moves are recorded: WineCo Case onto carrier 25,546, nywh-shipitez 3. c1wh has none of any type in 365 d |
| R6 | PR-B on PRD before 3381/3548 would fence with no floor exit | G1/G2 on `/api/public/version`, because the deployed image differs from branch HEAD |
| R7 | M7's type-blind refusal blocks deleting a stuck packed parcel at 100 | 0 operator Tote/Package deletes measured. Remedy: finish the order flow, or a DBA. The message names the reason |
| R8 | The rail's derived scope misses a wrapper-only entry class | Stated blind spot. It prevents recurrence; it is not the policy |
| R9 | **Behaviour change on the floor from B-1 + M1.** `stockrecord` `MANUAL_SPLIT` from a Tote at `Clearing`, operator non-anonymous, 365 d: **WineCo 372 rows / 78 totes, c1wh 72 / 21** (C1-0063 included); Hydra 0, nywh-shipitez 0. After StagingLane, WineCo does almost no hand restock (1 row) | This is the fence working: completeReversal does the same move, and does it correctly. But it is a real process change → **G3 briefing** (WineCo + c1wh), and the hint names the route. **Cancel-related split** (architect round 2, PRD read-only, each row's tote's last arrival at Clearing): WineCo **362 / 372 rows (73 / 78 totes)** and c1wh **72 / 72 (all 21 totes)** carry a CANCELED (800) order number; code only sends a Tote to Clearing via the cancel callers or an operator relocation (`MMU:722` sends default/Package only; a Tote goes to EmptyTotes, :707). All WineCo rows precede its v2 go-live (2026-09-26; last 2026-09-23), so they record v1-era floor habit. The count joins the tote's **current** type, not `stockrecord.unitloadtype`, because that column records the **destination** type (`StockrecordService:439`) and gives 204 / 43 only by catching tote→tote moves — do not "correct" to it. Recorded for Nam as D2's measured cost; D2 is not re-opened |
| R10 | A tote reaches a truck via truck loading, whose "pallet" has no type check (§0) | Unreachable today: 0 Tote labels match any tenant's outbound pattern. If a label scheme or sysprop changes, A3's WARN still fires only for stock one level below a pallet. Proposal P3 |

## 9. Acceptance

| AC | Statement | Test(s) |
|---|---|---|
| AC-1 | cancelOrder, cleanUpCancelledOrder and forceCancel `< PACKED` never lower 100; other locks reset to 0 | §7.1 B cancel rows; §7.3 flips |
| AC-1b | forceCancel PACKED arm still clears (no log row) | `…packedArm_stillClearsParcelStock…` |
| AC-1c | End to end on H2: real cancel → persisted 100 → Move Stock refused → completeReversal works | IT steps 1–4 |
| AC-1d | Waive exit works on fenced stock | IT second method |
| AC-3 | Move Unit Load refuses a Tote carrying 100 stock **onto a carrier** (existing pallet or inbound-pattern pallet, before it is created). A Tote at 100 still relocates to a location. `scanUnitLoad`, Package-at-100 onto a carrier, QF out of Damaged and ON_HOLD behave as today | MMU rows |
| AC-D3 | adjustAmount's refusal of 100 (already in place) now carries the goods-out hint and still says `value not changed`. deleteUnitLoad and the recursive pre-run refuse a container carrying 100 stock before any Nirvana send | `adjustAmount_lock100_messageCarriesGoodsOutHint`; UnitloadService rows |
| AC-4 | Refusal text names the container, `Picked`, the Cancellation screen and an outbound manager; no Waive button | message rows |
| AC-5 | closeBOL and finishTransfer write a WARN and an after-commit Service Log when a shipped pallet carries a pending-reversal SU, and register nothing otherwise | BOL rows |
| AC-6 | Rail: PR-A green with 0 unlisted offences and 8 EXEMPT keys (`file + method + snippet`, each matching exactly one site). PR-B green with 10 (plus D1′ and B-3). An unlisted offence, a key matching zero sites (mutant: delete MMU :365; also removing the B-2 or the B-3 check) or more than one, or a missing allowlist-conjunct control fails. All 7 self-tests behave as specified. The rail pins literal text only; D1′ and B-3 behaviour are pinned by their RED service tests | rail rows; MMU and UnitloadService RED rows |
| AC-SC | The cancel's Clearing move records the order number in `ordernumber` | swap test; manual #8 |

## 10. Decisions, open questions, proposals

**Settled (Nam, 2026-09-27):** D1′ carrier arm only · D2 skip only 100, C4 keeps clearing · D3′ M6 was already in place on develop, so D3 = the M7 guard + the adjustAmount message (PR-A) · D4 two PRs, PR-B's PRD release gated · carried as-is: wording (a), BOL WARN + after-commit Service Log, source-scan rail, retained-lock residual.

**For Nam, not re-opening:** D2 now has a measured floor cost (R9); D1′ has none (R5). The rail no longer drives any PR-B change; it stays because it is settled, and it is the first item to drop if cost must shrink.

**Recommended (options in §5):** O1 a single EXEMPT list · O2 fail-open with WARN · O3 resolve the adjustAmount label (one `findById`, refusal branch only).

**Proposed separately (T3 findings are proposed, not filed), in the order I'd do them:**
- **P2 first — detector for "closed row ∧ SU still at 100"** (the waive `lockRetained` case), in `PendingReversalReconciliationJob` style. Exposure today is 0, but B-1 is what makes it reachable. Cost: one query plus a Service Log.
- **P1 — force-cancel of a PACKED/PALLETIZED order writes no reversal row.** Population is 0 today (c1wh 0/1042, Hydra 0/9). Blast radius: silent loss of return tracking. Cost: one `recordCancellation` per parcel SU, plus a decision on C4.
- **P3 — truck-loading type guard.** Refuse a non-Pallet "pallet" in `MobileTruckLoadingWriteService` PHASE C. Exposure is 0 (R10). Cost: one type read on an already-locked row, plus the SBDEV-3244 first-touch analysis.

**Deferred follow-up:** once SBDEV-3548 is on PRD, `goodsOutHint` may name the Waive action. That is a one-line change.

## Layer-2 completeness checklist

| # | Item | ✓ | Ref |
|---|---|---|---|
| 0 | DB verified | ✓ | §1, R2, R5, R9, §0 reachability (4 PRD tenants, read-only, with positive controls) |
| 1 | Call sites | ✓ | §0 (methods and blind spots stated) |
| 2 | Adjacent bugs | ✓ | B6; R2; P1–P3 |
| 3 | Backward compat | ✓ | §3; §7.3 |
| 4 | Concurrency | ✓ | §7.5 |
| 5 | Multi-tenant | ✓ | Column-value fence; all 4 PRD tenants measured |
| 6 | Error handling | ✓ | §4 A3, B-2, B-3 |
| 7 | Observability | ✓ | A3; B-2 WARN |
| 8 | Rollback / migration | ✓ | No Flyway. Reverting PR-B re-opens the hole but loses no data |
| 9 | Test coverage | ✓ | §7.1–7.3 |
| 10 | v1↔v2 | no | v1 is reference-only |

## ADR

- **Decision.** Keep PICKED_FOR_GOODSOUT through cancel at C1/C2/C3, keyed on the lock value. Refuse a Tote carrying 100 stock only on Move Unit Load's carrier arm. Refuse deleting a container that holds 100 stock. Ship first, fail-open (PR-A): visibility, actionable messages including adjustAmount's, the `sendToClearing` fix, and a recurrence rail. Ship the fence second, fail-closed (PR-B), gated on the Waive exit and a floor briefing.
- **Drivers.** P1 (floor exit), P2 (no uncommitted-row reads), P3 (measured workflows: Package re-palletizing, QF out of Damaged, WineCo Tote relocations).
- **Alternatives considered.** See the §5 table. The strongest is the architect's distinct "pending reversal" lock state. It removes the type heuristic and the hedged wording, but it costs new state handling across 5 consumers plus a Flyway seed. It was rejected for scope under D2, and it is the natural successor if a fourth guard ever has to ask "is this 100 a cancel or a live pick?".
- **Why chosen.** By the producer census, "lock 100 at C1/C2" means exactly "a reversal is owed" (A§0.1, A§2.1). So the value itself is a lookup-free predicate that survives statement reordering. D1′ puts the MMU guard at the one move that leads to an overwrite, and that move has 0 measured cost.
- **Consequences.** See R1, R2, R3, R7 and R9. Refusal wording is conditional ("if its order was cancelled") because 100 also marks live picks.
- **Follow-ups.** P2, P1, P3. The `goodsOutHint` wording once SBDEV-3548 is on PRD. G4 re-measurement after the release.

## 11. Implementation status

### PR-A: PR submitted 2026-09-28
- **PR:** wms2-api [#429](https://github.com/SiteBossInc/wms2-api/pull/429), branch `bugfix/SBDEV-3547-a-visibility`. Worktree `.claude/worktrees/wms2-api/SBDEV-3547-a`, based on origin/develop `0ac108e2`.
- **Develop moved since the base:** SBDEV-3545 merged as `85b8afcf`. There is no file overlap, and that change adds no lock comparisons or primitive calls, so the rail result is unchanged on the merge.
- **Commits:**
  - `1f7dec85`: A1–A5
  - `7481c01f`: conformance gaps (H2 query IT, finishTransfer guards, lookup only at 100)
  - `924ce396`: review round 1, 13 Lows
  - `e67c0d3b`: re-review, 5 Lows
  - `593f441b`: tip review, 1 Low
- **Tests added:**
  - `LockRefusalMessagesUnitTest`
  - `SourceLockGuardUnitTest` (new class)
  - `MoveSourceLockComparisonRailTest` (main test + 12 self-tests + 4 bookkeeping self-tests)
  - `PendingReversalsOnPalletsIntegrationTest` (H2, 5)
  - rows in `UnitloadBusinessServiceUnitTest$SendToClearing`, `StockunitBusinessServiceUnitTest$Sbdev3547_SourceLockRefusalText`, `StockunitServiceUnitTest$NonTransactionalWritePathOrdering`, `BillofladingServiceUnitTest$Sbdev3547_ShippedPalletPendingReversal` (8)
  - N3 literal pins in `PendingReversalReconciliationJobUnitTest`
- **Results:**
  - `mvn -o clean test`: **7291 run, 0 failures, 1 skipped**. The baseline had 10 failures: the 9 gate reds plus a `never().save(any(Stockunit.class))` scaffolding defect in the gate tests, which was widened to `any()`.
  - 31/31 hand mutants killed. The harnesses are in the session scratchpad `mut3547/`.
  - PIT `LockRefusalMessages`: 3/3.
  - The **Testcontainers IT lane was not run locally** because Docker Desktop was hung, so it rests on the PR's CI `verify` job.
- **Review:**
  - Verifier: PASS.
  - Code review: round 1 APPROVE (13 Lows), scoped APPROVE (5 Lows), tip APPROVE (1 Low). All 19 were fixed. There were 0 High/Medium. Reviewed SHA = tip.
  - 5 inline PR notes: the load-bearing order of A3, `order=` being the customerorder_id, the no-synchronization branch, the `goodsOutHintIfPicked` blind spot, and the rail's NOT_LOCKED-anywhere rule (review #6).
- **Deviations from §4.A:**
  - The goods-out hint opens with `". "`, because §7.4 expects the refusal sentence to end first.
  - The Service Log sender/receiver moved to `WmsConstants.SERVICE_LOG_SENDER_WMS/RECEIVER_OPS`, and the reconciliation job now uses them too.
  - A fail-open no-synchronization branch was added in A3.
  - A third public helper, `goodsOutHintIfPicked`, was added.
  - The Service Log body names `order=<customerorder_id>`.
- **Landmines found:**
  - A `WmsConstants` literal mutant survives an incremental build, because the value is a compile-time constant inlined into callers. Run `mvn clean` for constant mutants.
  - `UnitloadRepository` and `StockunitRepository` are not `JpaRepository` (no `saveAndFlush`).
  - `Unitload` requires `clientId`; `Stockunit` requires `clientId` and `itemdataId` (Bean Validation).
- **Docs:** `wms2-bol-truck-loading-workflow.md` §6.4.

### PR-A: merged and on dev, 2026-09-28
- **Merge:** #429 merged into `develop` as `35c3428b`.
- **PR CI `test` job:** passed in 14m24s. It runs `clean verify` on the merge ref, which covers the Testcontainers lane that was not run locally.
- **Develop pipeline:** test ✓, build ✓.
- **Dev:** `/api/public/version` reports `develop-35c3428b…`, `drift: false`.
- **Flyway:** no migration.

### PR-B: merged and on dev, 2026-09-29
- **Dev test (both phases) passed:** `SBDEV-3547-evidence/reviews-pr-b-round1.md`. The cancel keeps 100, all hand moves are refused, the location move is allowed, and complete and waive each release. PR-A's `ordernumber` fix is confirmed. Finding: D1′ is defence in depth, because Tote is `onotherunitloadallowed = false` (see the note under §4.B B-2). The #431 body was corrected to match.
- #431 was merged as `5d08e9fc`. The develop `Docker Image CI` run succeeded. Dev `/api/public/version` reports `develop-5d08e9fc…`, with `drift:false`.
- PR CI on head `b3938629`: unit tests 7435/0/1, IT lane (Testcontainers) 550/0/31 skipped.
- **PRD is still gated** on:
  - G1: SBDEV-3381 and 3548 on PRD for each tenant;
  - G2: WineCo/c1wh floor briefing, including the D5 behaviour change;
  - G3: the PRD unit-load type config check (Tote, Cart, Pallet all `onotherunitloadallowed = false`) on every tenant; this replaced the "Tote SU at 100 under a carrier" count, which guards an unreachable move and is legitimately non-zero during cart picking.

  A measurement of how often picked stock goes to Damaged is also still owed.
- ClickUp was moved to `on dev` on 2026-09-29, with a summary and PRD-gate comment (comment 90110274246364).

### PR-B: updated 2026-09-29, D5 added
- A final full-branch security lane found web Move Stock → Damaged (M5) escaping the fence: 100 went to 103 with no lock or function check, and `removeLock` then cleared it. **D5 (Nam): fence it in PR-B.**
  - Commits: `c2d71a42` is the fence (the rail now has 11 entries); `9e7be519` and `b3938629` hold the review notes and the fixture id.
- **Accepted by Nam:**
  - The D5 fence reads a detached copy of the lock. This is a known narrowing, documented in code.
  - There is no operator route to damage lock-100 stock. This goes in the G3 briefing.
- The PR body was rewritten after two fact-check lanes. Every count has an evidence file.
- Tests: branch tip 7404/0/1. Merged with develop `5fe8c2f4` (#432 overlaps `PickingorderBusinessService`): 7435/0/1.
- #431 head: `b3938629`.
- Additional PRD open check: how often picked (100) stock is moved to Damaged today. Not measured; the DB MCPs dropped.

### PR-B: PR submitted 2026-09-28
- The PR is [#431](https://github.com/SiteBossInc/wms2-api/pull/431), branch `bugfix/SBDEV-3547-b-fence`.
- Commits:
  - `346cbee7`: the gate.
  - `09306eed`: B-1..B-3.
  - `d714a968`, `885bba83`, `1427d702`, `d0cfb81a`: the review-fix rounds.
- Tests: full suite 7402/0/1 before `d0cfb81a`, which was checked only in `LockRefusalMessagesUnitTest` (8/8). The H2 IT passes 2/2. Mutants: 21+1 at implementation, then 6, 9 and 3 at the three review-fix rounds; PIT killed 3 of 3. The Testcontainers lane did not run locally (Docker hung), so CI `verify` is its first run.
- Reviews: conformance PASS, security LOW, code review APPROVE ×3, and the last two fix commits APPROVE with 0 findings. Details: `SBDEV-3547-evidence/reviews-pr-b-round1.md` and `implementation-report-pr-b.md`.
- ~~Before PRD, beyond G1–G3: every PRD tenant must return 0 for "Tote SU at 100 under a carrier".~~ **Superseded 2026-09-29.** That count guards an unreachable move, so it was replaced by the type-config check in G3 above.
- ClickUp has not been moved to `pr submitted`, because the ClickUp MCP was disconnected.
- §7.1 rename: `toteTypeIdNull_proceedsWithWarn` → `_failsOpen`.

### PR-B: TDD gate done 2026-09-28
- The gate commit is `346cbee7` on `bugfix/SBDEV-3547-b-fence` (worktree `.claude/worktrees/wms2-api/SBDEV-3547-b`). Its tests are 8 RED unit tests plus the RED IT (both methods fail at step 2) and 11 GREEN guards. Report: `SBDEV-3547-evidence/tdd-gate-report-pr-b.md`.
- Plan corrections:
  - The IT needs a TenantContext, because `facility_code` is NOT NULL.
  - The fixture must set `historytote`. PRD has 0 orders without it, so the strand is latent.
  - The B-3 pre-run must **add** the `findByUnitloadIdIn` call.
It is gated on PR-A merging. Its TDD gate runs first (§6.3). It must not reach PRD until G1–G3 hold.
