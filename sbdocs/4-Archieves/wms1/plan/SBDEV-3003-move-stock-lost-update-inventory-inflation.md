---
title: "WMSv1: Move Stock silently inflates inventory — transferStockToUnitLoad re-fetches the source stock unit but computes its new amount from the stale caller instance, laundering a lost update past the @Version check"
ticket: "SBDEV-3003"
ticket_url: "https://app.clickup.com/t/868ku68tw"
type: "bugfix"
priority: "urgent"
status: "archived"
project: [wms1]
version: v1
requester: "Nam Park"
created: 2026-08-20
updated: 2026-08-20
db_verified: true
related:
  - ../../wms2/plan/SBDEV-3003-move-stock-lost-update-inventory-inflation.md
  - ../../../3-Resources/workflows/wms1-move-stock-unitload-workflow.md
  - ../../../3-Resources/design/wms1-stockunit-design.md
tags:
  - plan
---

> **ARCHIVED 2026-08-21 — merged and verified on DEV.**
>
> `wms-api` PR **#200** (merge `c41a425`) + `wms-mobile-ui` PR **#101** (merge `5b95591`), both merged
> 2026-08-20. Fixes A(+C), D and H shipped. M1, M2 and M5 passed manually against WineCo v1 dev,
> including the club-run shared-instance case no automated test covers.
>
> ⚠ **Fix E was DEFERRED and is not being built here.** It required an idempotency table, Flyway
> `V1.26.32`, a nonce parameter and a purge job. It is **superseded in effect** by the v2 work: the v2
> Slice 2 plan delivered exactly that server-side dedupe for `/v3/stockUnit/transferStock`, is merged,
> deployed and fully matrix-verified. Under the standing v1-is-reference-only policy, v1 Fix E is not
> self-initiated work — if v1 ever needs it, this plan's §"Fix E" section is the design record.
> Acceptance criterion **AC-5** was deferred with it, as was the two-transaction concurrency test
> (needs the IT lane).
>
> **Acceptance script RETIRED to `sbdocs/4-Archieves/scripts/verify-SBDEV-3003-move-stock-lost-update-inventory-inflation.sh`.**
> It graded BOTH plans of this pair plus Slice 2, and all three are now archived, so nothing active
> references it. Final grading, measured against `origin/develop` heads (v1 api `c41a425`, v1 ui
> `5b95591`, v2 api `26fd052`, v2 ui `55435bf`): **49 pass, 0 fail, 3 skip** — the 3 skips are the
> maven rows under `SKIP_MVN=1`.
>
> ⚠ **That number is only meaningful against `origin/develop`, not a local checkout.** Graded against
> the working checkouts it read **5 pass, 44 fail** — because all four were behind origin (v2 api by
> 10 commits, v2 mobile-ui by 13). A wall of credible, honest-looking reds that meant only "stale
> tree". Re-grade in a throwaway `--detach` worktree at `origin/develop`, never in the main checkout.
>
> **Implementation worktrees removed 2026-08-21:** `wms-api/SBDEV-3003`, `wms-mobile-ui/SBDEV-3003`,
> `wms2-api/SBDEV-3003`, `wms2-mobile-ui/SBDEV-3003`, and `.verify-root/SBDEV-3003`. All four branches
> were confirmed merged (PRs #200, #101, #175, #39) and ancestors of `origin/develop` before removal.

# WMSv1: Move Stock silently inflates inventory (lost update laundered past @Version)

**Ticket:** [SBDEV-3003](https://app.clickup.com/t/868ku68tw)
**Project:** wms1 | **Version:** v1 | **Type:** bugfix
**Priority:** urgent — active inventory-integrity loss on a live client's stock
**Status:** pr submitted — [wms-api #200](https://github.com/SiteBossInc/wms-api/pull/200) · [wms-mobile-ui #101](https://github.com/SiteBossInc/wms-mobile-ui/pull/101)
**Date:** 2026-08-20

> **Scope note.** Nam authorized fixing **both** v1 and v2 for this ticket, overriding the standing
> v2-only policy. The **inventory-inflation defect is v1-only** — v2's `StockunitBusinessService` was
> hardened by SBDEV-1710 / SBDEV-2481 and computes from a pessimistically-locked instance. The
> **duplicate-unit-load / missing-submit-guard defects are live in both**, and are covered in the
> paired v2 plan. The ClickUp title says *WMSv1* and Scott confirmed it; that is **correct** for the
> inflation. Nam's initial "it's v2" read was right only about the duplicate-UL half.

---

## 0. Affected sites (enumeration before drafting)

Enumerated by grep, not memory. The Class-A signature — a write to a re-fetched object whose value
is computed from a *different* (stale) object — was searched across both repos:

```
grep -rnoP '\b(\w+)\.set(\w+)\(\s*(?!\1\b)(\w+)\.get\2\(\)\s*\.\s*(add|subtract)\(' --include=*.java src/main
# v1: exactly 1 hit (StockunitBusinessService.java:270).  v2: 0 hits.
```

| # | File:line | Construct | Same root cause? | In scope? |
|---|-----------|-----------|------------------|-----------|
| A | `service/StockunitBusinessService.java:268-271` | `freshSourceStockunit.setAmount(sourceStockunit.getAmount().subtract(amount))` — re-fetch, stale operand | **yes — THE bug** | **yes** |
| B | `service/StockunitBusinessService.java:333` `changeAmount` | no `@Transactional`, no re-fetch; reservation guard reads stale `reservedamount` | yes — same class, absolute write | **NO — dropped 2026-08-20**, see §11. Annotating it would newly roll back cycle-count work that currently commits |
| C | `service/StockunitBusinessService.java:141` | availability check `amount - reservedamount` on the stale caller instance, before the re-fetch | yes — check-then-act on a stale read | **yes — folded into Fix A** |
| D | `v1/wms-mobile-ui` — 27 of 28 scan components | `submit()` bound to both `@keyup.enter.prevent` and button `@click`; no in-flight flag; dispatch not awaited | **trigger**, not cause | **yes** (Move Stock now; rest phased) |
| E | `service/StockunitService.transferStock` pallet branch | `unitloadService.createUnitload()` on **every** request → replays fragment into N phantom ULs instead of merging | yes — amplifier | **yes** |
| F | `service/StockunitBusinessService.java:265` | destination branch — computes from its **own fresh** object | no — **this one is correct**; it is the asymmetry that creates the phantom | no |
| G | `service/GoodsReceiptPositionService.java:82` `adjust` | absolute `newAmount`, delegates to `changeAmount` (B) | inherits B | via B |
| H | `service/StockunitBusinessService.java:363` `changeReservedAmount` | detach → `findByIdForUpdate` → compute from **locked** instance | no — **reference implementation**, copy this shape | no |
| I | DTO writes: `ParcelMonitorViewService:332`, `MobileTruckLoadingService:261`, `MobileInfoService:211`, `CustomerorderService:668`, `BillofladingService:515/738/895`, `TransferOrderService:273`, `CustomerorderBatchService:212/1020`, `StockrecordService:317`, `ReceivingService:516` | projections onto DTOs / records, not persistent quantity mutations | no | no |
| **K1** | `controller/StockUnitController.java:87→97` | **stale entity captured in a retry lambda** — `Stockunit stockUnit = findById(id)` is fetched *outside* `OptimisticLockRetryTemplate.executeWithRetry`, captured as `su`, and passed into `transferStock` on **every retry attempt** | **yes — Class A″** | **yes** |
| **K2** | `controller/StockUnitController.java:355` `setLockOnHold` | same shape — entity captured outside the lambda | yes | **yes** |
| **K3** | `controller/StockUnitController.java:392` `bulkSetLockOnHold` | same shape, per-id loop | yes | **yes** |
| **K4** | `controller/StockUnitController.java:160` `bulkTransferStock` | passes the `stockUnit` **entity** into `transferStock`, and — unlike its single-item sibling at `:97` — has **no `executeWithRetry` wrapper at all**, just a bare `try`. So the web bulk path is both entity-passing and unprotected against lock contention. *Found by verify row H2, not by the original enumeration.* | yes | **yes** |

### Class A″ — the retry lambda audit (all 10 v1 `executeWithRetry` sites)

Added by SBDEV-2492 to *survive* optimistic-lock failures. Three sites violate the helper's own
documented contract ("the supplier MUST re-fetch the entity inside the lambda"):

| Site | Passes into the lambda | Safe? |
|---|---|---|
| `StockUnitController:97` `transferStock` | **`Stockunit su` (entity)** | **NO** — our defect path |
| `StockUnitController:355` `setLockOnHold` | **`Stockunit stockUnit`** | **NO** |
| `StockUnitController:392` `bulkSetLockOnHold` | **`Stockunit stockUnit`** | **NO** |
| `FixLocationAssignmentController:97` | `id.longValue()` | yes — service re-fetches |
| `MoveUnitloadController:75` | `inDto` (labels only) | yes |
| `BillOfLadingController:211` / `:243` | `id` / `bolIds` | yes |
| `ClubLineController:94` / `:121` / `:149` | `locationId`, `orderBatchId`, `batchId` | yes |

**7 of 10 already use the correct shape — pass identifiers, let the service re-fetch inside the
transaction.** That is the reference pattern for Fix H; it exists in this codebase already.

**Why this compounds Bug A.** The retry was added to make lock contention survivable. But on a retry
attempt the lambda re-enters `transferStock` holding the *same* stale `su`, and Bug A's line then
launders that stale amount past the `@Version` check — so a retry can **silently commit a wrong
quantity instead of failing**. The mechanism intended to make concurrency safe is an amplifier for
this specific defect.

Rows A, C, D, E and K1–K4 map to Fixes A (with C folded in), D, E and H in §4, and to POSITIVE
checks in the verify script. **Row B is out of scope** (see §11), so no verify row asserts it.

---

## 1. Problem Statement

WineCo (Northwest Distribution & Storage), shipper Elk Cove Vineyards, ST#1116. An operator used
Mobile UI → Move Stock to move **96 bottles** of `PNCC24` to `TransferLane07`. Afterwards WMS showed
**2,016 bottles** at that lane across ~21 repeated 96-unit unit loads (`UL3524xx`, each Amount 96 /
Reserved 0 / Not Locked), and PNCC24 totalled **4,550** against OMS's **2,629**.

Two distinct symptoms are conflated in the ticket, and they have different causes:

1. **Many phantom unit loads** for one operator action — caused by D (no submit guard) × E (a new UL
   minted per request).
2. **Total quantity inflation** — caused by A: a lost update that debits the source once while
   crediting the destination once per replay.

### DB verification (floor item 1 — mandatory)

Brent reproduced this on **v1 DEV** (`wh01_om1` @ 10.0.0.4, MCP `wms1-wineco-dev`) with item
`CWUSTK` (itemdata `21375992`). One Move Stock of 12 produced **two** transactions **137 ms apart**:

```
10:31:36.434  unitload_record  CREATED  MANUAL_SPLIT  UL317406  Spawn → TransferLane01
10:31:36.477  stockrecord      STOCK_REMOVED  -12  amountstock=2988  UL313340
10:31:36.482  stockrecord      STOCK_CREATED  +12  amountstock=12    UL317406
10:31:36.585  unitload_record  CREATED  MANUAL_SPLIT  UL317408  Spawn → TransferLane01
10:31:36.595  stockrecord      STOCK_REMOVED  -12  amountstock=2988  UL313340   ← same result as .477
10:31:36.597  stockrecord      STOCK_CREATED  +12  amountstock=12    UL317408
```

**Both removals report `amountstock = 2988`** — and the row itself proves why that is worse than it
looks:

```sql
SELECT id, amount, version, modified FROM stockunit WHERE id = 21376110;
-- 21376110 | 2988.0000 | version 1 | 2026-08-20 10:31:36.456   <- transaction ONE's timestamp
```

`version = 1`, modified at transaction **one's** timestamp: the source row was `UPDATE`d **exactly
once**. Transaction 2 emitted **no UPDATE on the source at all** — Hibernate's dirty check compared
the freshly-loaded `2988` against the computed `3000 − 12 = 2988`, found the entity clean, and issued
no SQL. `@Version` was never consulted because there was no statement for it to guard.

**This is not the "fresh version lets a stale value commit" story.** It is worse in one specific way:
there is **zero forensic trace on the row** — no version bump, no `modified` change — so no
`stockunit`-based query can find a victim after the fact. Detection must key on the duplicate
`stockrecord` pair (§6). Corrected 2026-08-20 after review; the earlier description in this plan and
in the gate test's javadoc was wrong on this point.

Resulting state and reconciliation:

```sql
-- current on-hand vs everything ever received
SELECT (SELECT sum(su.amount) FROM stockunit su JOIN itemdata i ON i.id=su.itemdata_id
          WHERE i.item_nr='CWUSTK')                                        AS onhand,   -- 3012
       (SELECT sum(amount) FROM stockrecord WHERE itemdata='CWUSTK'
          AND activitycode='RECEIVING')                                    AS received, -- 3000
       (SELECT sum(amount) FROM stockrecord WHERE itemdata='CWUSTK')       AS ledger;   -- 3000
-- UL313340 @StagingLane07 = 2988, UL317406 @TransferLane01 = 12, UL317408 @TransferLane01 = 12
```

**3,012 on hand against 3,000 ever received — +12 phantom bottles.** Critically the `stockrecord`
ledger sums to exactly 3,000 (−12 −12 +12 +12 nets to zero), so **the audit trail certifies the
inventory as correct while `stockunit` is inflated.** That is why this defect has gone unnoticed and
why WMS diverges from OMS rather than from itself.

For contrast, PNCC24 in `wh01_om1_v2` (`wsl-wineco-uat`) reconciles perfectly — 3,828 received =
3,828 on hand across 66 records. **The UAT DB is not where the incident happened**; do not use it to
reproduce.

### Already predicted in our own docs

`sbdocs/3-Resources/workflows/wms1-move-stock-unitload-workflow.md` §12 item 1 documented this gap
verbatim and it was never fixed:

> **No pessimistic lock on split path.** `findByIdForUpdate()` exists in v1 but is not called from
> the move-stock path. Concurrent splits … both reads see `amount=10`, both write `amount=5`, net
> result is `amount=5` instead of `0`. **Symptom: inventory count drifts positive over time on busy
> flowbins.**

---

## 2. Root Cause Analysis

### Bug A — the re-fetch launders a stale value past `@Version` (silent corruption)

`v1/wms-api/src/main/java/net/aim_ai/wms/service/StockunitBusinessService.java:262-271`:

```java
} else {
    Long destId = destinationStockUnit.getId();
    destinationStockUnit = stockunitRepository.findById(destId).orElseThrow(...);
    destinationStockUnit.setAmount(destinationStockUnit.getAmount().add(amount));   // :265 CORRECT
    destinationStockUnit = stockunitRepository.save(destinationStockUnit);

    Long sourceId = sourceStockunit.getId();
    Stockunit freshSourceStockunit = stockunitRepository.findById(sourceId).orElseThrow(...);
    freshSourceStockunit.setAmount(sourceStockunit.getAmount().subtract(amount));   // :270 BUG
    sourceStockunit = stockunitRepository.save(freshSourceStockunit);
```

`Stockunit` carries `@Version` (`model/Stockunit.java:43`), so a lost update *should* be impossible.
The re-fetch is exactly what defeats it:

- The row is re-read, so `freshSourceStockunit` holds the **current** version `N`.
- The new amount is an **absolute** value computed from `sourceStockunit` — the caller's instance,
  loaded at the start of *this* request, before the sibling request committed.
- The `UPDATE … SET amount=?, version=N+1 WHERE id=? AND version=N` therefore **matches and commits
  cleanly**. Only the *value* is stale; the version is not.

Sequence for the DEV repro:

| | Request 1 | Request 2 |
|---|---|---|
| loads `sourceStockunit` | amount **3000**, version N | amount **3000**, version N |
| `findById` → fresh | 3000, version N | 2988, version **N+1** |
| computes | `3000 − 12 = 2988` | `3000 − 12 = 2988` ← from **stale** operand |
| commits | amount 2988, version N+1 | amount 2988, version N+2 — **no exception** |

Source debited **once** (−12); destination credited **twice** (+24, into two separate new ULs
because of E). Net **+12**.

**The `findById` makes it worse than doing nothing.** Saving the stale `sourceStockunit` directly
would have carried version `N` against a row at `N+1` and thrown `OptimisticLockException` — a loud,
correct failure. Someone hardened the wrong half of the statement: they made the *entity* fresh and
left the *operand* stale. **The fix is to move the arithmetic onto the re-fetched instance — not to
add a lock around unchanged arithmetic.** A lock would serialize the two transactions while the
second still computed `3000 − 12`; the operand is the defect, and once value and version share a
snapshot `@Version` handles the residual race on its own (§4).

### Bug B — `changeAmount` has no transaction, no lock, no re-fetch

`StockunitBusinessService.java:333`. Absolute write from a client-supplied target, and the
reservation guard (`amount.compareTo(reservedAmount) >= 0`) reads `reservedamount` off the stale
caller instance. Two concurrent adjusts silently lose one; a concurrent reservation can slip past the
guard. v2's equivalent (`:432`) does `findByIdForUpdate` + `entityManager.refresh` first.
Reached from `GoodsReceiptPositionService.adjust:82` (receiving quantity correction) and cycle count.

### Bug C — availability check on an unlocked entity

`StockunitBusinessService.java:141` validates `amount − reservedamount >= requested` against the
stale instance before anything is locked, so the guard can pass on quantity that another transaction
has already committed away. Note `MobileMoveStockService` calls with `ignoreLock=true`
(workflow doc §"lock checks"), so the entity-lock checks are bypassed on this path and this
availability check is the only quantity guard.

### Bug D — no double-submit guard (the trigger)

`v1/wms-mobile-ui/components/moveStock/scanDestination.vue`: `submit()` is bound to **both**
`@keyup.enter.prevent` and the Submit button's `@click`, there is no in-flight flag, the button has
no `:disabled`/`:loading`, and the Vuex dispatch is not awaited. A barcode scanner emitting a
trailing CR, or an operator tapping again during the (lock-heavy, multi-hundred-ms) request, fires a
second full transfer. 137 ms in the repro is consistent with a scanner double-fire.

**Systemic:** 27 of 28 scan components in this repo have no guard.
`components/replenish/process/selectDestination.vue` (`:loading="updating"`) is the **only** guarded
component in either mobile UI — copy its shape.

### Bug E — a new unit load per request

`StockunitService.transferStock` existing-container pallet branch calls
`unitloadService.createUnitload(...)` unconditionally on every request, so replays never merge into
the destination UL — each one mints another container. This is what turns one bad action into 21
phantom `UL3524xx` records.

---

## 3. Architecture Overview

```
mobile scanDestination.vue submit()          ← D: no in-flight guard, fires N times
  └─ POST /stockUnit/transferStock
       └─ StockUnitController.transferStock
            └─ StockunitService.transferStock          ← E: createUnitload() per request
                 └─ StockunitBusinessService.transferStockToUnitLoad
                      :141 availability check on STALE entity          ← C
                      :265 destination  = fresh.get() + amount         ← correct
                      :270 source       = STALE.get()  − amount        ← A  ** the defect **
```

| File | Lines | Role |
|------|-------|------|
| `service/StockunitBusinessService.java` | 132-291 | `transferStockToUnitLoad` — A, C |
| `service/StockunitBusinessService.java` | 333-357 | `changeAmount` — B |
| `service/StockunitBusinessService.java` | 363-399 | `changeReservedAmount` — **reference impl** |
| `service/StockunitService.java` | transfer path | E |
| `repo/StockunitRepository.java:31` | — | `findByIdForUpdate` exists (JPQL + `@Lock`) and stays **unused by this path, deliberately** — see §4 |
| `wms-mobile-ui/components/moveStock/scanDestination.vue` | 92-124 | D |

---

## 4. Fix Design

### Fix A — one snapshot for both value and version (REVISED 2026-08-20 after review)

> **The pessimistic lock originally planned here was REVERSED.** The first draft ported v2's
> `findByIdForUpdate` + `entityManager.refresh`. An independent architecture lane rejected it and I
> accepted; the rationale and the measurement are in §11. Fix C is folded in here; **Fix B is
> dropped from this PR** (see §11).

```java
// BEFORE — guard at :141 reads the caller's instance; write at :269-270 mixes snapshots
if (sourceStockunit.getAmount().subtract(sourceStockunit.getReservedamount()).compareTo(amount) < 0) { ... }
...
Stockunit freshSourceStockunit = stockunitRepository.findById(sourceId).orElseThrow(...);
freshSourceStockunit.setAmount(sourceStockunit.getAmount().subtract(amount));
sourceStockunit = stockunitRepository.save(freshSourceStockunit);

// AFTER — re-fetch once, in-transaction; guard AND arithmetic both read that instance
final Long srcId = sourceStockunit.getId();
sourceStockunit = stockunitRepository.findById(srcId)
    .orElseThrow(() -> new BusinessException("Source stock unit " + srcId + " not found"));
if (sourceStockunit.getAmount().subtract(sourceStockunit.getReservedamount()).compareTo(amount) < 0) {
    throw new BusinessException("amount=" + amount + " requested is more than available="
        + sourceStockunit.getAmount().subtract(sourceStockunit.getReservedamount()));
}
...
sourceStockunit.setAmount(sourceStockunit.getAmount().subtract(amount));
sourceStockunit = stockunitRepository.save(sourceStockunit);
```

**No `refresh`, no `flush`, no `detach` — just the re-fetch (final shape, after two corrections).**
The draft called for `detach`; implementation showed that breaks `runClubLine`; the second attempt
used `flush` + `refresh`; review showed the refresh is **unnecessary** and the flush only papers over
its hazard. What makes all of it unnecessary is that the write is **relative**
(`sourceStockunit.setAmount(sourceStockunit.getAmount().subtract(amount))`), never an absolute value
copied off another object. That is correct in every case:

| Caller instance | `findById` returns | Why it is correct |
|---|---|---|
| detached, nothing in L1 (the controller path) | a real read | fresh value **and** fresh version |
| managed (most of the 23) | the same object | the subtract is read-your-own-writes; a concurrent commit is caught by `@Version` at flush and surfaces loudly as `StaleObjectStateException` |
| detached but an L1 copy exists | the L1 copy | a coherent in-transaction read |

**Why `refresh` was removed** (both hazards were found by tracing callers, not by reading the diff):
- It **discards pending in-memory state.** `MobileMoveStockService.selectDestination` (`:229`) sets
  `QUALITY_FAULT` + `additionalcontent` via `setStockDamaged` on the same managed instance, then
  transfers it at `:272`; `runClubLine` reuses one shared `Stockunit` across positions carrying an
  unflushed debit. A refresh reverts both. An explicit `flush()` first makes it *safe* but not
  *useful*, at the cost of forcing an early whole-session flush on all 22 call sites.
- With the refresh gone, the `EntityNotFoundException` path goes with it. That mattered more than
  first rated: when the caller's instance is in L1, `findById` is an L1 hit with no SQL, so
  `orElseThrow` is unreachable and `refresh` was the *only* thing that would notice an
  already-deleted row — as a `RuntimeException` escaping the controller's
  `BusinessException`/`FacadeException` catches as a 500, and unretryable.

**Why not `detach`:** `CustomerorderBatchService:687`'s post-call `findById` feeds an identity-based
`removeAll` at `:693`, and `Stockunit` has no `equals` override — detaching makes that hydrate a new
instance and silently remove nothing.

**The transfer-all case needs no special handling — and the re-base that was added for it was
removed.** Four callers pass their own instance's amount to mean "move all of it"
(`BillofladingService:992` in a per-stock-unit loop, `CustomerorderService:471`,
`MobilePutAwayService:463`, `MobileMoveUnitloadService:361`). **All four load the stock unit inside
their own transaction**, so `findById` returns the same managed object, the guard reads exactly the
value they passed, and nothing throws. Verified per caller.

An implementation draft re-based `amount` onto the current amount whenever
`amount == callerAmount`. Review killed it, correctly:
- it cannot distinguish *"move everything"* from *"move exactly this number, which happens to be
  everything"* — a numeric coincidence, not intent;
- the guard was `!= 0`, so a row that had **grown** re-based `amount` **upward** and moved *more*
  than the operator asked for;
- on the operator path it silently moved **less** than requested with only a `LOG.warn`, replacing a
  clear `"more than available"` error with a wrong quantity — the same failure class this ticket
  exists to eliminate.

AC-8b pins the correct behaviour: a stale request for more than is currently available is **refused**,
not quietly downgraded.

Net ~4 lines. Rebinding `sourceStockunit` is deliberate — callers already expect it
(`CustomerorderBatchService:686` carries the comment *"stockUnit may be updated by
transferStockToUnitLoad, get the updated one"*), and it guarantees no stale reference survives to be
used as an operand later in the method.

**Why no lock is needed.** The defect required the *value* and the *version* to come from different
snapshots. Making them the same object eliminates the class structurally, in both OSIV modes:

| | OSIV off (UAT + prd) | OSIV on (DEV may be) |
|---|---|---|
| the re-fetch returns | fresh row, fresh version | an L1 hit — the same object as the caller's |
| arithmetic | correct on fresh values | self-consistent on the L1 values |
| a concurrent commit in the window | `UPDATE … WHERE version=N` finds `N+1` → `StaleObjectStateException` | version equally stale → same exception |

So the residual race is *detected*, not silently absorbed — which is exactly what `@Version` is for
and what `:269-270` was defeating. Under OSIV-on the fix is **not** a no-op: it degrades to a loud
failure, which is correct behaviour.

**Why the lock was rejected** (full reasoning §11): it would apply to **all 23 call sites**,
including `BillofladingService:992` inside a per-stockunit loop and `CustomerorderBatchService:666-684`
in nested loops under one `@Transactional` at `:558`, in a codebase with **zero lock timeouts** in
`src/main` — a connection-pool-exhaustion risk affecting every endpoint, to fix a defect that needs
no lock. And `findByIdForUpdate` is **JPQL** (`StockunitRepository:31`), so an L1 hit returns the
cached instance unrefreshed: without also replicating the `entityManager.detach` at `:372`, the lock
would have been **decorative** — taken, but with the arithmetic still stale.

### Fix C — folded into Fix A

The availability guard moves onto the re-fetched instance as part of the block above. This is
load-bearing beyond concurrency: `:270` writes an **absolute** amount with no negative check
(contrast `changeAmount:337`, which has one) and there is **no DB CHECK constraint** on
`stockunit.amount`, so a stale over-permissive guard can drive stock negative. The guard sits
*outside* the `if (!ignoreLock)` block at `:187`, so this protects all 23 callers — including the
`ignoreLock=true` ones (`PickingorderBusinessService:309`, `CustomerorderService:471`).

### Destination side (`:263-265`) — verified safe, deliberately not changed

`destinationStockUnit` is obtained at `:264` and added to *that same instance*. Note it is an **L1
hit** on the object already loaded by `findByUnitloadId:150` — not a fresh read — but that does not
matter, because the arithmetic is **relative** (`.add`) rather than absolute, so value and version
are coherent and a concurrent add into the same destination raises an optimistic-lock
failure rather than being lost. The destination is also **always** loaded inside the method, so
unlike the source it can never arrive stale from a caller — which is exactly why the source is broken
and the destination is not. Reviewed twice as a possible gap and **refuted** both times.

⚠ **If anyone later "hardens" this with `findByIdForUpdate`, they must detach first.** JPQL hydration
runs `Loader.checkVersion` against the L1 copy and throws `StaleObjectStateException` before any of
their code executes — the same trap `changeReservedAmount:365-373` documents.

### Fix D — in-flight guard

`data: { submitting: false }`; `submit()` returns early when `submitting`; `try/finally` around the
awaited dispatch; `:disabled="submitting"` + `:loading="submitting"` on the button. Model on
`components/replenish/process/selectDestination.vue`.

### Fix E — idempotent replay, fail open (**decided 2026-08-20 — Nam**)

> **DEFERRED TO A FOLLOW-UP PR (decided 2026-08-20 — Nam).** Fixes A(+C), D and H shipped in the
> first PR; Fix E lands on top. Reasons:
> - The first PR is **pure correctness with no deploy prerequisite** — a revert is a single
>   `git revert`. Fix E adds a **Flyway migration**, which is applied to *no* database until an
>   operator runs it, so bundling it makes the inventory-integrity fix wait on a schema rollout and
>   leaves an orphan table behind any revert.
> - Fix E is **defence in depth**, not the primary fix. Fix D stops the double-submit at source and
>   Fix A makes any replay that slips through quantity-safe; Fix E covers the residual — a client
>   retry that beats the UI guard, or two devices.
> - **Prerequisite for that PR:** the verify script currently has **no v1 row for Fix E** — `E1`,
>   `G1` and `G2` all target the v2 files (`$V2_SUS` / `$V2_SUC`). v1 rows must be added, and
>   negative-tested, before the follow-up can be machine-checked.
> - **Flyway head is `V1.26.31`** (`trim_itemdata_item_nr_whitespace`), verified 2026-08-20 — not
>   V1.26.30. Continue from `V1.26.32`; re-verify at PR time, since unmerged branches can hold
>   invisible versions.


A UI guard alone cannot stop a scanner double-fire that beats the flag, a client retry, or two
devices. The endpoint dedupes server-side. Three decisions, all settled:

**1. Return the prior result — do not reject.** The likely trigger is the client's own automatic
retry, so rejecting turns an operation that *did* succeed into an operator-visible error, which is
the worst available outcome on a handheld mid-move. A duplicate replays the first attempt's outcome.

**2. Missing nonce → fail OPEN** (accept, no dedupe, log a WARN and increment a counter). The mobile
UI deploys separately from the API, so failing closed would brick Move Stock on every un-upgraded
handheld the moment the API ships — in a live warehouse. Flip to fail-closed only after the counter
reads zero for a sustained period, and make that a separate, deliberate change.

**3. Key on a per-intent client nonce, NOT on the value tuple.** The nonce is minted once when the
destination screen is armed and travels with every replay of that intent, so retries share it while a
deliberate second identical move gets a fresh one. Deduping on
`(stockunitId, destination, amount)` would reject legitimate repeat work — operators routinely split
a pallet into equal chunks — trading a visible phantom-UL bug for a silent "your move didn't happen"
one, which is strictly worse because nothing tells them which occurred.

**Storage: a table with a UNIQUE constraint on `(operator, stockunit_id, nonce)`, inserted in the
same transaction as the transfer.** This is the only option correct under both rollback and multiple
replicas. A cache populated *before* commit is a trap: the internal `OptimisticLockRetryTemplate`
retry would see its own first attempt's nonce and silently drop a legitimate retry, converting a
recoverable conflict into a lost operation. On duplicate key (23505), look up and replay the stored
outcome. TTL 24 h with a scheduled purge.

**Do this first, regardless.** Two lines aimed at the actual cause, and worth more than Fix E on its
own: disable the submit button on click (Fix D), and exclude non-idempotent POSTs from the UI's
axios-retry configuration. Fix E is the backstop for what those cannot catch.

Fixes A–C make a replay *quantity-safe* on their own; E is what stops the phantom containers.

### Fix H — pass identifiers into retry lambdas, not entities (rows K1–K3)

```java
// BEFORE (StockUnitController:87-99)
Stockunit stockUnit = stockunitRepository.findById(id).orElseThrow(...);
final Stockunit su = stockUnit;
OptimisticLockRetryTemplate.executeWithRetry(() -> {
    stockunitService.transferStock(su, amt, ...);      // same stale instance on every attempt
}, "stockUnit.transferStock(" + su.getId() + ")");

// AFTER — the service re-fetches per attempt, inside its own transaction
OptimisticLockRetryTemplate.executeWithRetry(() -> {
    stockunitService.transferStock(id, amt, ...);      // id only
}, "stockUnit.transferStock(" + id + ")");
```

Requires an id-taking overload on `StockunitService.transferStock` (and `setLockOnHold` for K2/K3)
that resolves the entity inside the transactional boundary. This is the shape 7 of the 10 existing
retry sites already use — `FixLocationAssignmentController:97` is the closest precedent.

Retaining the existing controller-level `findById` for the amount/existence validation is fine; what
must not survive is passing that instance *through* the retry boundary.

---

## 5. File Change Summary

| File | Change | Description |
|------|--------|-------------|
| `service/StockunitBusinessService.java` | modify | Fix A (:268-271), Fix B (:333), Fix C (:141) |
| `service/StockunitService.java` | modify | Fix H — id-taking `transferStock` / `setLockOnHold` overloads |
| ~~Fix E surfaces~~ | deferred | idempotency table + Flyway `V1.26.32` + nonce param + purge job → **follow-up PR** |
| `wms-mobile-ui/components/moveStock/scanDestination.vue` | modify | Fix D |
| `wms-mobile-ui/components/moveStock/inputAmount.vue` | modify | Fix D |
| `test/.../StockunitBusinessServiceStaleOperandTest.java` | **new** | AC-1/AC-2 — deterministic, no Spring context |
| `test/.../MoveStockMoveUnitloadConcurrencyIT.java` | modify | implement the `fail()` stubs (blocked — see §7) |

### 5.1 Prerequisites

| Item | Status |
|------|--------|
| DB state | **+12 phantom CWUSTK live in v1 DEV right now.** Decide: reconcile, or retain as QA evidence (§10 Q2) |
| Detection sweep | Must run §6 detection query on all tenants/envs **before** deploy, to size existing corruption |
| Feature flags | None — A/B/C are unconditional correctness fixes |
| Deploy order | API before mobile UI (the UI guard is defence-in-depth over a correct server) |
| Data migration | **Possible** — repair of already-corrupted rows; needs authoritative physical counts first |
| Access | `wms1-wineco-dev` MCP confirmed working; prd v1 DBs need read access for the sweep |

---

## 6. Detection and repair

**The obvious detector does not work.** A `stockunit`-vs-ledger drift query looks right but cannot
find victims reliably: the corrupting transaction issues **no UPDATE at all** (dirty-check silence,
§1), so the row carries no version bump and no `modified` change, and the `stockrecord` deltas still
sum to the correct total. Drift only shows up as a *whole-item* imbalance, which is also produced by
renamed SKUs (`stockrecord.itemdata` is a varchar item number, not an FK) and by items older than the
record retention window.

**Key on the duplicate-removal fingerprint instead.** Two `STOCK_REMOVED` rows for the same stock
unit reporting the *same* `amountstock` seconds apart is the signature, and it is unambiguous — the
second removal recorded a debit that never reached the row:

```sql
SELECT itemdata, fromunitload, amount, amountstock, count(*) AS dup_removals,
       min(created) AS first_seen, max(created) AS last_seen
FROM stockrecord
WHERE type = 'STOCK_REMOVED' AND created >= '2026-01-01'
GROUP BY itemdata, fromunitload, amount, amountstock
HAVING count(*) > 1 AND max(created) - min(created) < interval '10 seconds'
ORDER BY dup_removals DESC;
```

**Validated in both directions 2026-08-20 (do not trust an empty result without this):**

| Environment | Result |
|---|---|
| `wh01_om1` (v1 DEV) — **positive control** | finds exactly the CWUSTK case: `UL313340`, `amount=-12`, `amountstock=2988`, 2 rows 118 ms apart. **Exactly one occurrence in all of 2026.** |
| `wh01_om1_v2` (v2 UAT) | **zero** occurrences across 2026 — consistent with v2's `transferStockToUnitLoad` being correct |

A detector that has only ever returned empty is worthless. This one has been seen to fire on the
known case, so an empty result elsewhere is now evidence rather than silence.

Per victim found, the inflation is `dup_removals - 1` times `abs(amount)`.

**Repair is not a code change.** Per ticket investigation items 4 and 7 the authoritative physical
quantity must be established (cycle count) before any adjustment. Do not auto-correct: a phantom
+12 and a genuine +12 receipt are indistinguishable in `stockunit` alone.

---

## 7. Testing Plan

**The primary trap: a single-threaded test passes on the broken code and proves nothing.**

Bug A is reachable **deterministically without concurrency**, because the defect is the stale
*operand*, not the timing. That side-steps both v1 lane blockers:

```java
// StockunitBusinessServiceStaleOperandTest — plain Mockito, no Spring context, no threads
// Caller's instance says 3000; the repository (post-lock) returns 2988.
Stockunit stale  = stockunit(id=1L, amount=3000);
when(stockunitRepository.findById(1L)).thenReturn(Optional.of(stockunit(id=1L, amount=2988)));

service.transferStockToUnitLoad(stale, destUl, BigDecimal.valueOf(12), MANUAL_SPLIT, ...);

// AC-1: saved amount must be 2976 (= 2988 - 12), NOT 2988 (= 3000 - 12)
assertThat(captor.getValue().getAmount()).isEqualByComparingTo("2976");
```

**Acceptance criteria — REVISED 2026-08-20 for design B.** Measured against the gate as written:

| AC | Asserts | Status after the reversal |
|---|---|---|
| **AC-1** | source amount derives from the re-fetched instance (2976, not 2988) | **unchanged and passing under design B** — it pins the *operand*, which is the actual defect, independent of locking |
| **AC-2** | *(rewritten)* the `STOCK_REMOVED` stockrecord stamps `amountstock=2976` | **replaced** — the old row asserted `verify(findByIdForUpdate)`, which encoded design A and could never pass. The new criterion is design-agnostic and anchored in the DEV evidence: both real rows carried `2988`, so a stale operand corrupts the **audit trail** in the same stroke as the row. Distinct from AC-1, which pins what is *persisted* rather than what is *reported* |
| **AC-3** | ~~`changeAmount` locks before computing `diffAmount`~~ | **DROP** — Fix B is out of scope |
| **AC-4** | availability guard rejects using the re-fetched values | **unchanged and passing under design B** |
| **AC-5** | two identical transfers (same nonce) → one destination UL, second rejected | unchanged; deferred to the executor's first commit (the nonce parameter must exist before a behavioural test can compile) |
| **AC-6** | `scanDestination.vue` ignores a second `submit()` in flight | **cannot be gated in v1** — no test lane exists (see Lane constraints) |
| **AC-7** | id-taking `transferStock` overload exists (Fix H) | unchanged |

Measured 2026-08-20 by applying design B to the worktree and running the gate: **AC-1 and AC-4 pass,
AC-2 fails (the test is wrong under B, not the code), AC-3 fails (out of scope), AC-7 fails
(legitimately unmet).** Reverted afterwards.

**Mutation-check every assertion (floor item 3).** For AC-1: restore the stale operand and confirm
red. For AC-2: leave the row correct but restore the stale operand in the `recordRemoval` argument
and confirm red. An assertion never observed failing is not evidence.

### Lane constraints

- **`v1/wms-mobile-ui` has NO test lane at all** — no `test` script, no `jest` devDependency, no
  `jest.config.js`, no spec files (verified 2026-08-20). It is the only one of the four UI repos in
  that state: `v1/wms-web-ui` and `v2/wms2-mobile-ui` both run Jest 27. **AC-6 therefore cannot be
  gated by a test in v1.** Coverage falls back to verify rows D2/D2b/D2c/D2d (code-shape assertions
  on `scanDestination.vue`, proven to flip red→green against a patched shadow) plus manual M1/M2.
  Standing up a Jest lane here is out of scope for this plan — recorded as an observation, since it
  means **no v1 mobile UI change has ever been unit-tested**.
- v1 `@SpringBootTest` ITs **all fail at context load** (SBDEV-2384, `ro_id` view drift).
  `MoveStockMoveUnitloadConcurrencyIT` is `@Disabled` with `fail()`-stubbed bodies — **it never ran,
  which is why it never caught this.** Keep it disabled; implement the stubs but do not gate on it.
- Mockito 3.3.3 — no `mockStatic()`. The tests above do not need it.
- A true two-transaction concurrency test requires the IT lane and is therefore **deferred**; AC-1
  is the deterministic substitute and is strictly stronger for this defect.

### Manual test plan

| Scenario | Env | Steps | Expected |
|---|---|---|---|
| M1 double-tap Move Stock | v1 DEV | Move 12 of a test SKU to a transfer lane; tap Submit twice fast | one UL; source −12; total unchanged |
| M2 scanner double-fire | v1 DEV | Same via handheld scanner with trailing CR | as M1 |
| M3 reconciliation | v1 DEV | Run §6 query before/after | no new drift |
| M4 CWUSTK regression | v1 DEV | Re-run the exact repro | on-hand stays 3012, not 3024 |

---

## 8. Risks & Mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| `findByIdForUpdate` on the hot move path adds lock contention | Slower moves on busy flowbins | Matches `changeReservedAmount` precedent; lock is per-stockunit and short. Measure on DEV |
| New lock ordering deadlocks against picking | Hung transactions | v2's `:196-206` documents the canonical order (Pickingorder → Stockunit → Unitload → Location). **Adopt v1's existing `pickLineRealignmentService.lockOwningPickingorders` first**, as v1 already does at :137 |
| Repairing corrupted rows without physical counts | Wrong inventory, worse than the bug | §6 — cycle count first, never auto-correct |
| Fix E changes UL granularity | Reports counting ULs shift | Decide semantics in §10 Q1 before implementing |
| v1 IT lane stays blocked | No true concurrency regression test | AC-1 is deterministic and does not need the lane |

---

## 9. Acceptance

Verify script: `sbdocs/9-System/scripts/verify-SBDEV-3003-move-stock-lost-update-inventory-inflation.sh`
(covers all four repos; roots via `V1_API` / `V2_API` / `V1_UI` / `V2_UI`). Final acceptance requires
`Result: N pass, 0 fail`, plus AC-1…AC-6 green and each mutation-checked.

**Baseline captured 2026-08-20 against the unfixed tree: `Result: 3 pass, 25 fail, 3 skip`**
(31 rows, `SKIP_MVN=1`). The 3 passes are the P1–P3 v2 regression pins, which pass by design.

**Revised after the design reversal.** Rows asserting a pessimistic lock were deleted or rewritten
because under the accepted design they could **never** go green — a permanently-red row is
indistinguishable from unfinished work, and is exactly the kind someone later "fixes" by
reinstating the lock the review removed:

| Old row | Fate |
|---|---|
| A3, A4 (`findByIdForUpdate` call sites in v1) | **deleted**, replaced by rebind + containment rows |
| B1, B2 (`changeAmount` lock / `@Transactional`) | **deleted** — Fix B dropped |
| C1 ("locks BEFORE the guard") | **rewritten** — now "guard sits AFTER the in-tx rebind" |
| P2 (v2 `findByIdForUpdate`) | **kept** — v2 genuinely does lock |

Gate tests: **4** (was 5). AC-3 removed with Fix B; AC-2 rewritten (see §7). Measured both ways:
4/4 fail on the unfixed tree, **4/4 pass** with design B + Fix H applied.

The script was **negative-tested, not merely read** — this is what the run proved:

| Check | Method | Outcome |
|---|---|---|
| A1–A4, B1–B2, C1 can go green | patched shadow copy of `StockunitBusinessService.java` | all 7 flip red → green |
| H1–H3 can go green | patched shadow of `StockUnitController.java` + `StockunitService.java` | all 3 flip red → green |
| **H2 has teeth** | first patch fixed only K1–K3 | **stayed red** until K4 (`:160`) was also fixed — the row found a site the enumeration missed |
| D1–D1d can go green | patched shadow copy of `scanDestination.vue` | all 4 flip red → green |
| P1/P3 have teeth | reintroduced the v1 stale operand into v2 | both flip green → **red** |
| P2 is an independent axis | same mutation | correctly stays green (operand changed, lock did not) |

**Two latent script bugs were found only by running it**, both in `file_contains_ml` — the pattern was
being interpolated into perl *source* instead of passed as data:

1. A pattern containing `//` (the Java-comment tolerance group) **terminates perl's `m//` literal**,
   so perl dies and the row is permanently red. Row B1 read as an honest FAIL against correctly
   patched code.
2. A perl regex literal **interpolates variables**, so `@Transactional` parsed as an *array* and
   silently flattened to the empty string — over-matching. Affects any pattern containing `@` or `$`,
   i.e. every annotation assertion.

Both fixed by passing the pattern via the environment (`VERIFY_RE`). **This flaw is inherited from
`verify-plan-template.sh` and is present in every script built from it** — worth sweeping separately.

---

## 10. Open Questions

- **Q1 — RESOLVED 2026-08-20 (Nam): dedupe and reject.** Merge-into-existing-UL is not pursued. See
  Fix E for the consequence that follows from the decision: the dedupe must key on a **per-intent
  client nonce**, not on `(stockunitId, destination, amount)`, or it will reject legitimate repeat
  moves.
- **Q2 — RESOLVED 2026-08-20 by inspection: `/moveStock/scanDestination` is DEAD for this flow in
  both UIs.** `store/moveStock.js` defines a `scanDestination` action (v1 `:123`, v2 `:136`) but **no
  component dispatches it** — `components/moveStock/scanDestination.vue:126` dispatches
  `moveStock/transferStock`, which posts to `/stockUnit/transferStock`. Confirmed by grep across
  `components/` and `pages/` in both repos. Fix E therefore lands on `StockUnitController` only.
  `MobileMoveStockService.selectDestination` remains a near-duplicate implementation of the transfer
  logic — recommend a deprecation note now and deletion under a separate cleanup, **not** in this PR.
- **Q3.** Roll Fix D across all 27 unguarded scan components in this PR, or Move Stock only now and
  the rest as a follow-up? Recommend **Move Stock now**, rest phased. *(Proceeding on the
  recommendation unless told otherwise — it is a scope choice, not a contract change.)*
- **Q4.** Reconcile the +12 phantom CWUSTK in v1 DEV now, or keep it as QA evidence until the fix is
  verified? Recommend **keep** — it is the only live reproduction.
- **Q5.** Does the prd v1 sweep need sign-off before running read-only queries against live client
  DBs?
- **Q6 — RESOLVED 2026-08-20 (Nam): fail open, return the prior result.** See Fix E. TTL 24 h; if
  made a sysprop, note `los_sysprop.description` is `varchar(255)` and an over-long seed raises
  `22001`, rolling back the whole migration file.

**Blocking questions: none.** Q1, Q2 and Q6 are decided. Q3 and Q4 proceed on the stated
recommendation unless overridden — both are scope choices, not contract changes. Q5 only arises if
the prd sweep is actually run.

---

## 11. Notes / Observations

### Review outcome (2026-08-20) — floor item 4

Four independent lanes were spawned; **one delivered.** `architect` returned a substantial review
after one prompt and named its own gaps honestly. `code-reviewer`, `critic` and a replacement
`challenger` each signalled idle without returning anything, and nothing was recoverable from the
task directories — so the design-judgment half of the review is **partially uncovered**. Treat the
following as resting on: one delivered lane, plus the measurements below, plus first-principles
analysis — not on four lanes.

**What the review changed (none of which the authoring pass had found):**

1. **Reversed the central design decision** — Fix A went from a pessimistic lock across 23 call
   sites and 4 batch loops to ~5 lines in one method. Verified consequences: zero lock timeouts in
   `src/main`; `BillofladingService:992` in a per-stockunit loop; `CustomerorderBatchService:666-684`
   in nested loops under one `@Transactional` at `:558`.
2. **`findByIdForUpdate` is JPQL** (`StockunitRepository:31`), so an L1 hit returns the cached
   instance unrefreshed. Design A without replicating the `entityManager.detach` at `:372` would
   have taken the lock and **still done stale arithmetic** — a fix that looks applied and changes
   nothing. No unit test would have caught it.
3. **Fix B dropped.** `changeAmount:333` is reached without any transaction from
   `MobileCycleCountService:122/385` and `StockunitService.adjustAmount:414`, where
   `stockunitRepository.save` and `stockrecordService.recordChange` commit **separately** today.
   Annotating `changeAmount` would newly roll back an amount change that currently survives — a real
   behaviour change for cycle-count operators, and the boundary belongs on
   `countSingleUnitLoad` / `countBySKURecount`, not here. Separate ticket, recorded not filed.
4. **`wms1-transaction-boundary-map.md` §8.1 was factually wrong** — it listed `Stockunit`,
   `Pickingorder`, `Customerorder`, `CustomerorderBatch`, `Billoflading`, `Replenishorder` as
   "notably **missing** `@Version`". All six have it (45 of 67 model classes do;
   `Stockunit.java:43-44`). That sentence is what makes a pessimistic lock look necessary. Corrected.
5. **OSIV is not what either doc claimed.** v1 pins it nowhere; it is **off on UAT and Production,
   and DEV may not be**. The tx-map asserted "enabled" in ~8 places and
   `wms-bugfix-plan/SKILL.md` (§Non-negotiable WMS context; was line 210 pre-2026-08-22, when the tier sections moved out to `wms-triage`) asserted "disabled in both versions". Both corrected. This matters
   because it decides whether the caller's entity is detached or managed, which changes the *failure
   mode* of this very defect.
6. **Five verify rows would have been permanently red** under design B (A3, A4, B1, B2 assert
   `findByIdForUpdate` call sites; C1's wording assumes a lock) — indistinguishable from unfinished
   work, and the kind of red row someone eventually "fixes" by reinstating the lock. Deleted/rewritten.

**Reviewed and refuted** (recorded so it is not re-raised): the destination branch at `:263-265` was
flagged as an unlocked second instance of the same bug class. It re-fetches and adds to *that same
instance*, so value and version are coherent and a concurrent add raises an optimistic-lock failure
rather than being lost. Structurally identical to v2. No change needed.

### Review round 2 (2026-08-20) — a replacement lane, and what it changed

A fifth lane was spawned to attack the reversal itself. It delivered, and it was the most valuable of
the five. **Everything below was verified against the code or the DB before being accepted.**

**Accepted and folded in:**
1. **The mechanism was wrong** — no second UPDATE was ever issued (`version=1`, dirty-check silence).
   §1 and the gate javadoc corrected. Consequence: no `stockunit`-based detector can work.
2. **§6's detection query was unusable** — replaced with the duplicate-removal fingerprint, now
   validated in both directions (positive control on CWUSTK, zero on v2 UAT).
3. **`entityManager.detach` is mandatory** — without it the fix is a no-op for every caller whose
   instance is already managed, which is most of the 23.
4. **Fix A as specified would have regressed four transfer-all callers** — see §4. A test for the
   clamp is now required before Fix A ships.
5. **`:263` is an L1 hit, not a re-fetch** — correct for a different reason than the plan said
   (relative arithmetic, not a fresh read). Plus the `Loader.checkVersion` trap for any future
   hardener.
6. **A stronger argument for rejecting design A**: `BasicService.getNextSequenceNumber:110` spins up
   to 100 times on optimistic-lock failure against one `los_sequencenumber` row via a `REQUIRES_NEW`
   inner transaction. Under design A, a transaction holding the stock-unit row lock and spinning on
   the sequence row, against another holding the sequence version and blocking on the row lock, is an
   unbounded wait — there are no lock timeouts. That is a better reason to reject A than "value and
   version share a snapshot", which is true but is not why A is wrong.

**Rejected after verification:**
- **"Bug A cannot fire on the mobile path, so the incident is unexplained."** The lane assumed mobile
  Move Stock routes through `MobileMoveStockService.selectDestination` (`@Transactional` at `:229`,
  loads the source in-transaction → managed instance → fix is a no-op). It does not.
  `components/moveStock/scanDestination.vue:126` dispatches `moveStock/transferStock`, which posts to
  **`/stockUnit/transferStock`** (`store/moveStock.js:156`) → `StockUnitController:87`, which fetches
  **outside** any transaction. Nothing dispatches the `scanDestination` action;
  `/moveStock/scanDestination` is dead for this flow. **So mobile hits the detached path and Bug A
  fires.** The CWUSTK reproduction and the PNCC24 report are the same path and the same defect.
- **"The orphaned `UL317407` proves a rolled-back attempt."** It does not, and my earlier inference
  from it was over-read. `SequenceTransactionService:21` is `REQUIRES_NEW`, so a label commits
  independently the instant it is issued — any concurrent `createUnitload` on a shared DEV box burns
  one. Entity-id gaps also occur *inside* both committed transactions here. No retry is implicated;
  `version=1` on the source positively rules out a conflict on that row.

**Recorded, not filed** (one-ticket cap): `BasicService:150-156` returns a **negative** sequence
number after `maxTries` — the `throw` is commented out — so `String.format("UL%1$06d", -1)` yields
`UL-00001`, and `createUnitload` returns the **existing** unit load on a label match. Under sequence
contention, unrelated stock movements silently merge into one shared container. Verified present.

**Still uncovered:** the nonce contract's fail-open/fail-closed choice (Fix E / §10 Q6) is a product
decision. Round 2's recommendation, which I endorse: **fail open** (accept, WARN, count) so an
un-upgraded handheld is not bricked by an API deploy; **return the prior result** rather than
rejecting, since the likely trigger is the client's own retry and rejecting turns a succeeded
operation into an operator-visible error; and record the nonce in a table with a UNIQUE constraint
**in the same transaction as the transfer** — a cache populated before commit would let the internal
`OptimisticLockRetryTemplate` see its own first attempt and silently drop a legitimate retry.
- **The WMS↔OMS gap is a separate issue.** PNCC24 showed WMS 4,550 vs OMS 2,629 (+1,921). This
  defect explains WMS-side inflation, but the status-blind outbox dispatcher (which marks SENT on
  HTTP 2xx while legacy OMS returns 200 with a failure verdict in the body) is the likelier cause of
  OMS being *low*. Recorded here deliberately rather than filed — ticket cap is one per fix.
- **`OptimisticLockRetry` teaches this bug.** The v2 helper's javadoc example is
  `fresh.setAmount(newAmount)` with `newAmount` computed *outside* the lambda — precisely the
  stale-operand shape. Doc fix tracked in the v2 plan (Fix F). v1 has no such helper.
- **Why `@Version` is not the answer here.** v1 declares `@Version` on `Stockunit` and it is
  correctly configured. It cannot help: version guards *which row state you overwrite*, never *which
  values you computed*. Any absolute write derived from a stale read defeats it.

---

## 12. Implementation Status (2026-08-20)

**PRs:** [wms-api #200](https://github.com/SiteBossInc/wms-api/pull/200) · [wms-mobile-ui #101](https://github.com/SiteBossInc/wms-mobile-ui/pull/101) — **both MERGED into `develop` 2026-08-20.**
**Merge commits:** `c41a425` (wms-api) · `5b95591` (wms-mobile-ui). In both repos the fix commit sat
directly on its tested base (`03bb5a8` / `9f71ff5`) with no intervening commits, so the merged tree is
identical to the tree the suite was run against — no post-merge re-test was required.
**Merged without human diff review, and without M1–M6 executed** (see "Explicitly NOT done").
**Commits:** `5425625` (wms-api, 5 files +513/−15) · `b95b5e4` (wms-mobile-ui, 2 files +27/−4)
**Branch:** `feature/SBDEV-3003-move-stock-lost-update` in both repos, off `origin/develop` @ `03bb5a88` / `9f71ff5`
**Worktrees (retained for review feedback):** `.claude/worktrees/{wms-api,wms-mobile-ui}/SBDEV-3003`

### Shipped

| Fix | Status |
|---|---|
| **A + C** — re-fetch in-transaction, guard and arithmetic on that instance (relative write) | ✅ |
| **H** — identifiers not entities through `OptimisticLockRetryTemplate`; new id-taking overloads (rows K1–K4) | ✅ |
| **D** — in-flight submit guard, Move Stock screens only | ✅ |
| **E** — server-side idempotent replay | ⏸ **deferred to a follow-up PR** (Nam, 2026-08-20) |
| **B** — `@Transactional` on `changeAmount` | ❌ **dropped** — would newly roll back cycle-count work that currently commits |

### Tests

`StockunitBusinessServiceStaleOperandTest` (new, 6 tests):
`…shouldDeriveSourceAmountFromRefetchedRow_whenCallerInstanceIsStale` (AC-1) ·
`…shouldRecordRemovalAgainstThePostFixAmount_notTheStaleOne` (AC-2) ·
`…shouldRejectUsingRefetchedAmount_whenCallerInstanceOverstates` (AC-4) ·
`…shouldRelocateWholeUnit_whenManagedCallerTransfersAll` (AC-8) ·
`…shouldRefuse_whenDetachedCallerAsksForMoreThanCurrentAmount` (AC-8b) ·
`stockunitService_shouldDeclareIdTakingTransferStockOverload` (AC-7)

`StockunitBusinessServiceUnitTest` (modified): 6 cases gained a stub for the new in-transaction
`findById`, each returning that test's own source instance. Assertions unchanged. 27/27.

**Mutations run, all red:** stale operand restored → AC-1 + AC-2 · guard back on the caller instance
→ AC-4 + AC-8b · guard rejects an exactly-equal request → AC-8.

```
mvn test -Dtest=StockunitBusinessServiceStaleOperandTest  →  Tests run: 6, Failures: 0, Errors: 0
mvn test (full)                                           →  Tests run: 1782, Failures: 0, Errors: 19, Skipped: 1
Result: 17 pass, 11 fail, 3 skip     (all 11 failures are v2 rows, out of scope)
```
The 19 errors are the pre-existing baseline, confirmed against a pristine `origin/develop` worktree.

### Landmines found during implementation that the plan did not predict

1. **`detach` breaks `runClubLine`.** `Stockunit` has no `equals` override, so
   `CustomerorderBatchService:693`'s `stockUnits.removeAll(...)` compares by identity over instances
   from a post-call `findById` at `:687` that was an L1 hit. Detaching makes it hydrate a new
   instance → removes nothing → batch bookkeeping breaks.
2. **`refresh` discards callers' pending state.** `MobileMoveStockService.selectDestination:229` sets
   `QUALITY_FAULT` via `setStockDamaged` then transfers the same managed instance at `:272`;
   `runClubLine` reuses one shared `Stockunit` across positions with an unflushed debit.
3. **Neither is needed.** The relative write makes every managed/detached case correct on its own.
   Final shape is 4 lines: re-fetch, guard on the result, subtract from the result.
4. **A transfer-all "re-base" is actively harmful.** Keying on `amount == callerAmount` cannot tell
   intent from coincidence; it re-based *upward* when the row had grown (moving more than requested)
   and silently moved *less* on the operator path. Removed; AC-8b pins the correct refusal.
5. **Six existing tests broke** on the new `findById` interaction — the test-side impact no review
   lane had assessed.
6. **`plugins/axios.js` already excludes non-idempotent POSTs** — `retryCondition` returns `false`
   for anything but 401/403 and for undefined `error.response`. §4's "do this first regardless" item
   needs no work.
7. **`BasicService:150-156` returns a negative sequence number** after `maxTries` (the `throw` is
   commented out) → `UL-00001` → `createUnitload` returns the **existing** unit load on a label
   match, silently merging unrelated movements into one container. Recorded, not filed.

### Dev verification (2026-08-20) — executed, not planned

Runbook with every command and gotcha: `2-Areas/runbooks/wms1-verify-move-stock-lost-update-on-dev.md`.
Environment: API `https://wms-api.wineco.dev.sbo.li` (Java 8 — v1), DB `wh01_om1` @ 10.0.0.4,
confirmed as the same environment by fetching a known batch through the API and matching it against the DB.

| Test | Result |
|---|---|
| **M2** — two concurrent `POST /v3/stockUnit/transferStock`, 90 ms apart, **no UI in the path** | ✅ **PASS** — `amountstock` stepped `9891 → 9841 → 9791`; source `version 1 → 3`; `onhand = ledger` |
| **M1** — UI double-tap on Move Stock | ✅ **PASS** — one removal, one unit load, ledger intact |
| **M5** — club run, **3 orders × 6 from ONE 30-unit stock unit** | ✅ **PASS** — `amountstock` stepped `24 → 18 → 12`; staged unit `version 1 → 4`; batch state `530` |
| Batch `41664-6` — whole-unit relocation | ✅ PASS (AC-8's branch; single `STOCK_TRANSFERRED`, `delta 0`) |

**M5 closes the one real gap in this plan.** It is the exact scenario that killed both rejected
designs — `detach` (breaks `CustomerorderBatchService:693`'s identity-based `removeAll`) and
`refresh` (discards the unflushed debit between orders, signature `24, 24, 24`) — and the dead v1 IT
lane means no test will ever cover it. Landmine 1 is now **evidence, not reasoning**.

`version` is the decisive field throughout: in the original CWUSTK incident the source sat at
`version = 1` after **two** removals, proving a write never reached the database. Here three debits
produced three version bumps.

**Two API warts found while building the test** (recorded, not filed):
1. `activateBatch/{orderBatchId}` does `Long.parseLong` (wants the numeric PK) while
   `runClubLine/{orderBatchId}` does `findByBatchid` (wants the batchid string) — same parameter
   name, opposite semantics, same controller.
2. `parcel_external_number` is optional at `PUT /rest/order/create` but **mandatory** at club-run
   time, so a batch can be imported and activated into a state that can never run.

**Also confirmed:** `stockrecord.created` is `timestamp without time zone` holding **warehouse-local**
time while `now()` is UTC — a naive `now() - interval` filter returns empty and reads as "nothing
happened". It could equally mask a failing test. v2 returns tz-aware timestamps, so a working v2
query is wrong here.

### Explicitly NOT done

- **M4 and M6 still unrun.** M4 is one query (CWUSTK must stay at 3,012 — the fix prevents new
  corruption, it does not repair old). M6 is a BOL close over a pallet holding several stock units
  (`BillofladingService:992` loops per stock unit). Neither has automated coverage.
- No human reviewed the diff; the independent passes were agent lanes only.
- Plan not archived; worktrees retained.
- **The customer's reported numbers are not verified as explained by this fix.** PNCC24's incident
  state is in no reachable database. Two of the four reported figures match UAT's history exactly
  (`PutAwayLane 2,112` = 4×528, `06-XB14` = 86), so the report came from that lineage — most likely
  v1 production. The mechanism is confirmed reachable on the reported path (mobile Move Stock posts
  to `/stockUnit/transferStock`, whose controller fetches outside the transaction), but the link to
  that data is unproven. **§6's detector settles it in one query given access.**
- **Duplicate unit loads only partly addressed** — Fix A makes a replay quantity-safe; it does not
  stop N containers being minted. Fix E is the backstop and is deferred.
- **No behavioural test for the `runClubLine` scenario.** The v1 IT lane is dead (SBDEV-2384), so
  landmine 1 above is reasoned through, not proven. M5 in the PR's manual plan is the only check.
- **26 unguarded scan components per UI** remain out of scope.
