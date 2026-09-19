---
title: "Mobile palletize — transaction boundary and row locking"
ticket: "SBDEV-3398"
ticket_url: "https://app.clickup.com/t/868m6ca0d"
type: "bugfix"
priority: "high"
status: "implemented"
project: ["wms2"]
version: "v2"
requester: "Nam Park"
created: "2026-09-17"
updated: "2026-09-17"
db_verified: true
base_commit: "9f600e52"
related:
  - "[[SBDEV-2620]]"
  - "[[SBDEV-2507]]"
  - "[[SBDEV-3397]]"
  - "[[SBDEV-2232-parcelmonitorview-palletise-toctou-lock-fix]]"
  - "[[260610-wms2-multi-replica-hardening]]"
  - "[[SBDEV-3267]]"
  - "[[SBDEV-3244]]"
  - "[[SBDEV-3250]]"
  - "[[SBDEV-3418]]"
  - "[[SBDEV-3419]]"
tags:
  - plan
  - wms2
  - concurrency
  - transaction-boundary
---

# Mobile palletize — transaction boundary and row locking

**Ticket:** [SBDEV-3398](https://app.clickup.com/t/868m6ca0d)
**Project:** wms2 | **Version:** v2 | **Type:** bugfix
**Priority:** high — deterministic silent data loss (see §1.1)
**Status:** implemented — PR pending
**Base:** `origin/develop` @ `9f600e52` (2026-09-17)

> **Evidence base.** This plan is a synthesis. Five analysis lanes wrote full reports to
> `.claude/worktrees/_reports/SBDEV-3398/` (`lane1-tracer-lockorder.md`,
> `lane2-architect-txboundary.md`, `lane3-enumeration.md`, `lane4-docs-context.md`,
> `lane5-truckloading.md`). This document states conclusions and decisions; it deliberately does
> **not** restate their derivations. Where a claim matters, the lane and section are cited so a
> reviewer can check it rather than take it on trust.

---

## 1. Problem Statement

`service/mobile/MobilePalletizingService` writes warehouse state with **no transaction boundary and
no row locks**: zero `@Transactional` annotations, zero `findByIdForUpdate`. Every repository call
commits on its own, so every guard is advisory — it can be true when checked and false when acted on.

`service/mobile/MobileTruckLoadingService` has the same defect shape and was briefly in scope here.
**It was unbundled on 2026-09-17** once its lock order was found to conflict with this one; it is now
proposal **P0** in §4.3, carrying its full analysis in §4.4.

The ticket was filed as a race. **Analysis found a worse, deterministic defect in front of it**, and
that is now the headline.

### 1.1 The headline defect — silent data loss, no concurrency required

In `MobilePalletizingService.scanPallet`, the committing DELETE runs **before** the guard that can
reject the operation:

| line | call |
|---|---|
| `:239` | `assertParcelCarrierNotShipped(parcel)` |
| `:244` | `assertParcelNotOnAnotherPallet(parcel, …)` |
| **`:248`** | **`removeBOLPositionIfExists(...)` — commits the DELETE** |
| **`:261`** | **pallet-label format check — throws** (independent trigger, different precondition) |
| **`:274`** | **`assertPalletNotAssignedToGate(palletLabel)` — throws** |

⚠ **Four** rejection points sit after the DELETE, not one (review finding F8). `:261`'s format
check is a *separate* deterministic trigger with its own precondition — a mistyped label for a
non-existent pallet also deletes the BOL positions and then throws. Both must be covered.

Parcel P sits on pallet A; A has been scanned to a gate, so both carry a `billoflading_position` in
`TRUCK_LOADING`. The operator re-scans P onto A:

1. `assertParcelCarrierNotShipped` **passes** — it fires only on `CLOSED`/`TRANSFER`.
2. `assertParcelNotOnAnotherPallet` **passes** — same pallet, documented "idempotent re-scan" early return.
3. `removeBOLPositionIfExists` **deletes** P's BOL position and its child stock positions.
   `TRUCK_LOADING` waterfalls to `break`. No transaction ⇒ each delete commits immediately.
4. `assertPalletNotAssignedToGate` **throws**.

`PalletizingController.scanPallet` catches `BusinessException` and returns
**`ResponseEntity.ok(errorMap)` — HTTP 200**. So the operator gets a success status carrying an error
message, and reasonably concludes nothing happened.

**Residue.** P keeps `carrierunitload_id = A`, so when A's BOL closes, `closeBOL`'s bulk
`UPDATE Unitload … WHERE u.id IN :palletIds OR u.carrierunitloadId IN :palletIds` still sweeps P to
`Shipped` — that statement keys off the carrier link, not off BOL positions. But P's `customerorder`
is built *from* BOL positions, so it never reaches `FINISHED` and never appears in the OMS payload.
Not operator-recoverable: Move Unit Load detaches the parcel but does not recreate a BOL position.

**The trigger is high-volume, quantified in the repo's own javadoc**
(`BillofladingPositionService.assertParcelNotOnAnotherPallet`):

> *"Re-scanning a parcel onto the pallet it is already on is normal and high-volume — 7.5% of all
> palletizing operations on ShipItEZ UAT, 5.7% on Hydra UAT."*

**It is reachable from the handheld.** `scanParcel` rejects only `state < PACKED`, `== CANCELED`,
`>= FINISHED`. `PALLETIZED = 670` sits between `PACKED = 650` and `FINISHED = 700`, so an
already-palletized parcel passes and the operator proceeds to `scanPallet`.

**Why it survived review — a false comment.** `:237` claims *"assertPalletNotAssignedToGate **above**
already refuses a target pallet carrying any BOL position"*. In `scanPallet` there is no such call
above `:237`; the only one is at `:274`, below. The comment is **correct in `scanParcelBulk`**, where
the guard genuinely is at the top (`:380`, ahead of the DELETE at `:443`). It was copy-pasted into
`scanPallet`, where it asserts exactly the safety property that does not hold.

### 1.2 Field evidence

Parcels whose carrier pallet has a `billoflading_position` but which have none of their own:

| tenant | orphans | positive control, same scan |
|---|---|---|
| WineCo UAT | **2** (both on pallet `PM-016720`) | 469,580 parcels WITH a position; 17,357 pallets |
| Hydra UAT | **1** | 9,402 parcels WITH a position |
| Hydra prd | 0 | 190-row control — volume too small to be informative |

The WineCo pair has a complete `unitload_record` trail: `PM-016720` → `Gate_01` at 20:24:04, then two
parcels palletized onto it at **20:24:57** and **20:28:25**, same operator. Both orders sit at
`FINISHED`, location `Shipped`, with no `billoflading_position`.

⚠ **Attribution, stated precisely.** At the April 2026 commit these rows were written
(`4eebba65`), the **desktop** path had neither the gate guard nor any lock, while mobile had the gate
guard inline. **These three rows are not evidence of the mobile ordering bug.** They are evidence
that the *outcome* is real, silent, and detected by nothing downstream. The mobile route to the same
outcome is the line ordering in §1.1, which is live today. (Lane 1 §3.6 records this as uncertainty
U2; do not let it drift into a stronger claim.)

### 1.3 The race the ticket was filed for

Still real, still unfixed, now second in priority — but **far larger than the Hydra numbers suggested.**

| measure | Hydra prd | Hydra UAT | **WineCo UAT** |
|---|---|---|---|
| parcel palletize events | 190 | 7,811 | **418,165** |
| a **different** parcel palletized within 2 s of the previous | 2 (1.1%) | 1,876 (24%) | **401,988 (96.1%)** |
| smallest gap between two different parcels | 10.6 ms | 3 ms | **0 ms** (sub-millisecond) |
| cross-pallet re-parents via this path | 0 | 114 | **19,088** |

**Read the 96.1% carefully — it is the number that matters.** On the busiest tenant, nearly every
palletize operation happens within two seconds of another one. This is not an occasional race
window; concurrent palletizing is the *normal operating mode* of this path, and the guards are
advisory throughout it. Hydra prd's 190 events were simply too small a sample to show it — that
dataset supports no conclusion about concurrency either way.

**19,088 cross-pallet re-parents** is the behaviour `assertParcelNotOnAnotherPallet` exists to
reject, occurring on a path where the guard cannot hold anything. As with Hydra's 114, these predate
the guard (merged `7b72265e`, 2026-09-17) and are therefore the **pre-guard baseline, not bypasses**.
⚠ The guard is one day old, so "no bypass observed" still carries no information; do not read it as
reassurance.

*Instrument notes.* (1) Counting **all** `PALLETIZING` records rather than `TRANSFERRED` only
inflates the adjacency figure, because a `scanPallet` that creates a pallet writes `CREATED` and
`TRANSFERRED` ~10 ms apart *within one request*; every figure above filters to `TRANSFERRED` and to
**distinct parcel labels**, so it counts genuinely separate operations. (2) The `0 ms` minimum means
two different parcels share a timestamp at the column's resolution — it is a floor on the true gap,
not a measurement of it. (3) Both re-parent counts were derived independently here and **match the
figures published in SBDEV-3397's commit message** (`0e6f4235`: "114/111 Hydra UAT",
"19,088/14,288 WineCo UAT") exactly — two derivations, same numbers.

### 1.4 The contract already being violated

`UnitloadBusinessService.transferUnitLoadToCarrier` declares:

> `// WARNING: Propagation.REQUIRED — joins the caller's transaction. Caller must hold all row-level`
> `// locks before invoking this method (SBDEV-2232 §3.0). Do NOT call from a non-transactional context.`

Both mobile sites call it from exactly that, holding no locks. Because there is no caller
transaction, `REQUIRED` opens and commits its **own**, so the carrier re-parent and its
`unitload_record` audit rows commit independently of the `PALLETIZED` state write and the BOL DELETE.
**The mobile palletize path is three unrelated transactions pretending to be one operation.** Lane 2
rates this the strongest argument for the ticket, ahead of the race.

---

## 2. Root Cause Analysis

### Bug 1 — guard/write ordering in `scanPallet` (§1.1)
Deterministic. Fixed by moving `assertPalletNotAssignedToGate` ahead of the writes **and** by the
boundary, which makes the DELETE roll back on any guard throw. Both, not either — the ordering fix
is structural, the boundary is defence in depth.

### Bug 2 — no transaction boundary
Zero `@Transactional` in either service. The annotation to apply is exactly
`@Transactional(value = "tenantTransactionManager", rollbackFor = {BusinessException.class, FacadeException.class})`
— a **bare** `@Transactional` binds the `@Primary` *landlord* manager and makes the whole fix inert.
(`TransactionManagerArchTest` catches it, which is why this is stated rather than assumed.) Every write auto-commits; a later rejection strands the
earlier ones. `rollbackFor = {BusinessException, FacadeException}` is load-bearing, not decoration:
both are **checked**, and Spring does not roll back on checked exceptions by default.

### Bug 3 — no row locks
All unit-load reads use `findByLabelid`. Nothing is pinned between check and write, so every guard is
advisory.

### Bug 4 — asymmetric order-state write
`scanPallet:277-288` re-fetches under `OptimisticLockRetry` and re-checks the guard against the fresh
instance. `scanParcelBulk:445-448` does a bare `order.setState(PALLETIZED); save(order)` on an entity
read ~60 lines earlier — a plain stale-entity write with a lost-update window and no guard at all.

### Bug 5 — `OptimisticLockRetry` becomes inert, and its rail stays green
`util/OptimisticLockRetry.java` javadoc: *"Use this only where each invocation runs in a fresh
transaction — as `MobilePalletizingService` does, having no `@Transactional` anywhere in the class."*
Adding the boundary degrades the retry to a no-op. `OptimisticLockRetryScopeTest`'s fourth test
asserts the class *must keep* the utility — but it checks the **ctor/field dependency**, not the
annotation, so it **stays green while its stated rationale becomes false**. Nothing reddens. This is
why the ticket needed a plan rather than an annotation.

---

## 3. Fix Design

### 3.0 Decisions taken (Nam, 2026-09-17) — do not relitigate in review

| # | Decision | Rationale |
|---|---|---|
| D1 | **Retire `OptimisticLockRetry` in this PR** (Scope A) | The pessimistic lock supersedes optimistic retry. `MobilePalletizingService` is its sole remaining `src/main` consumer, so the utility reaches zero consumers. |
| D2 | **Lock contention fails fast with an operator-legible message** | Translate the pessimistic-lock failure to a `BusinessException`, not a 500. |
| D3 | **OMS notification stays OUTSIDE the transaction boundary** | Writes move to a `@Transactional` method on a separate bean; the non-transactional outer method calls `customerOrderPalletized` after it returns. |
| D4 | ~~`MobileTruckLoadingService` is fixed in this PR too~~ → **REVERSED 2026-09-17.** Unbundled to its own ticket (§4.3 **P0**, detail in §4.4) | The bundling rationale was "adjacent step, same review pass". It stopped holding once verification showed truck loading resolves parcels **before** orders, inverting §3.2 — so bundling naively would have **introduced** an ABBA deadlock, and fixing it properly needs a lock-order restructure plus ~3 new projections. |
| D5 | **Doc sweep covers live docs only** | ~12 non-archived `sbdocs/`, **three** non-`completed/` `docs/plan/` files (F12), and retirement of `verify-260610-*.sh`. ~30 archived plans stay as an accurate record of a decision correct at its date. |
| D6 | **Mobile joins the desktop lock order verbatim**; the `closeBOL ↔ palletise` ABBA is proposed separately | Keeps scope on mobile. Lane 1 §4.5 confirms joining does not worsen the existing cycle. |

**D3 — recorded dissent.** Lane 2 §3.2 recommends the opposite (keep the call inside the
transaction, for parity with the already-deployed desktop twin, whose `sendAfterCommit` if-branch is
its designed primary path). That argument was weighed and not taken, because the same section
documents the shape newly exposing mobile to a failure it does not have today: under an open
transaction the existing `catch (Exception)` swallow sits inside the transaction, a repository
failure during payload building marks the session rollback-only, the swallow cannot undo it, and the
transaction dies at commit with `UnexpectedRollbackException` — which the controller does not catch,
producing an HTTP 500 with no operator-legible message. D3 avoids that **and** avoids holding a
tenant connection across an HTTP call, while still notifying only after a successful commit.
Trade-off accepted: mobile's notification shape diverges from desktop's, and that divergence must be
commented at both sites.

### 3.1 The locking shape — read this before writing any code

**The naive fix is wrong and will pass every test.** Adding `findByIdForUpdate` *next to* an existing
unlocked read is the shape that breaks. Per SBDEV-3244 (measured 2026-09-09 @ `84083464`), a
`@Lock(PESSIMISTIC_WRITE)` re-read of an **already-managed** entity whose in-context `@Version` has
been superseded throws `StaleObjectStateException` **from inside the repository call**
(`EntityInitializerImpl.upgradeLockMode` → `checkVersion`), and Hibernate marks the transaction
rollback-only itself.

> Under contention, read-then-lock converts a silent lost update into
> `StaleObjectStateException` → `UnexpectedRollbackException` → **HTTP 500**, instead of the guard
> rejection the ticket exists to produce. Uncontended, `checkVersion` passes and nothing throws — so
> **every test that does not reproduce the race is green either way.**

**Rule: each row's locking finder must be that row's FIRST touch in the transaction.**

**The repo has already solved this, and the remedy is id projections — not `refresh`.** SBDEV-3244
established the pattern and pinned it with two tests
(`unit/repo/ReplenishmentIdProjectionContractUnitTest`,
`unit/service/ReplenishmentFirstTouchInvariantUnitTest`):

> `ReplenishmentOrderMaintenanceService:265` — *"SBDEV-3244 — THE FIRST-TOUCH RULE. This locking read
> must be the FIRST time this transaction touches this row, which is why the parameter is an id and
> not an entity."*

`ReplenishorderRepository:148` goes further and **rules out the alternative this plan originally
proposed**, in so many words:

> *"…it throws `StaleObjectStateException` from inside the repository call — before any write, and
> **before any `entityManager.refresh` placed after it could run**."*

⚠ **Revision (review finding F4).** An earlier draft of this plan specified
`entityManager.refresh(order, PESSIMISTIC_WRITE)` for the customer order. That is **withdrawn**. It
had no precedent in this repo — all 11 `refresh` sites in `src/main` are single-argument (positive
control: those 11 hits prove the grep works) — it introduced a novel Hibernate interaction on the hot
path of the fix, it needed a new `EntityManager` field, and the repository comment above explicitly
says a later `refresh` does not help. **Use scalar id projections + the existing `findByIdForUpdate`.**

**Scalar projections are not a "touch".** A query returning `Long` or `boolean` creates no
`EntityEntry`, so it cannot make a later locking finder an upgrade. This is what lets every
pre-lock diagnostic survive without breaking the first-touch rule.

### 3.2 Lock order (D6)

```
UL(pallet) → Customerorder (ASC by customerorder.id) → UL(parcel, in customerorder.id order)
```

Two corrections to statements in circulation, both from Lane 1 §1:

- **The ticket's "BOL → pallet → …" is wrong on hop 1.** `ParcelMonitorViewService` takes no BOL
  lock, calls no `BillofladingRepository`, and does not inject one. No pessimistic finder exists on
  `billoflading_position` anywhere in the repo.
- **The desktop's own comment is wrong on hop 3.** It says *"Parcels (sorted by id asc)"*; parcels
  are actually locked in **`customerorder.id`** order. Measured 47.55% inversion between the two
  orderings on WineCo UAT. Fix the comment in this PR (free, and it is the citation everyone copies).

Mobile touches one of each, so intra-class ordering is vacuous here — but the **class** order must
match desktop, or a mobile scan and a desktop `palletise` on the same {parcel, pallet} pair form an
AB/BA vector.

### 3.3 `scanPallet` — target shape

```
PHASE A  validate inputs, and run every pre-lock diagnostic as a SCALAR PROJECTION
  A1  parcelLabel non-empty
  A2  palletLabel non-empty (+ C1 example-only message)
  A3  parcel-exists diagnosis -- REQUIRED, see the note below:
        if (!unitloadRepository.existsByLabelid(dto.getParcelLabel()))
            throw new BusinessException("entityNotFoundForName",
                    Unitload.class.getSimpleName(), dto.getParcelLabel());
        // ^ scanPallet's EXISTING message. NOT parcelMissingException() -- that is
        //   scanParcel's/scanParcelBulk's richer diagnosis. Changing which one scanPallet
        //   throws is a separate, deliberate decision; this plan preserves today's shape.
      scalar boolean -> no EntityEntry -> does not break the first-touch rule

PHASE B  acquire locks in order, each the FIRST *entity* touch of its row
  B1  pallet   unitloadRepository.findByLabelidForUpdate(palletLabel)
               absent -> pallet-label FORMAT CHECK here (see the A3 note), then
                         unitloadService.createUnitload(...)
               ⚠ CORRECTED DURING IMPLEMENTATION (review H1, 2026-09-17). This step
               originally read: "Do NOT re-lock a row this transaction just inserted: it is
               invisible to other sessions until commit, and per SBDEV-3244 a
               freshly-persisted entity is already at EntityEntry lock level WRITE.
               Deliberate divergence from desktop's Fix E."
               THAT INSTRUCTION IS WRONG, and following it shipped a defect:
                 * `unitloadService.createUnitload(String name, ...)` is a FIND-OR-CREATE.
                   It opens with an UNLOCKED `findByLabelid(name)` and returns the existing
                   row if one is there -- so "a row this transaction just inserted" is not
                   what you necessarily hold.
                 * A `SELECT ... FOR UPDATE` matching ZERO rows takes NO LOCK. Nothing
                   serialises the window between B1's miss and the insert, so a second
                   handheld (or scanPalletBulk) committing that label inside it means
                   createUnitload hands back THEIR row, unlocked -- hop 1 of this very lock
                   order silently absent for the rest of the transaction.
                 * It also made the pallet-TYPE check skippable on the strength of "the mint
                   branch ran", so a concurrently created Tote or Case could be accepted as
                   a palletising carrier.
               DO THIS INSTEAD: after createUnitload, re-take the lock with
               `findByIdForUpdate(pallet.getId())`, and run the type check unconditionally.
               That is correct in both branches -- if we really inserted the row its
               EntityEntry is already at lock level WRITE (Hibernate's highest internal
               mode), so it is not an upgrade and no version check runs; if createUnitload
               found someone else's row, it IS an upgrade, the version is checked, and a
               concurrent modification aborts the transaction, which is the right outcome.
               So desktop's "Fix E" was right and this plan's divergence from it was the
               error. Residual, pre-existing, deliberately NOT retried: two sessions that
               both miss B1 and both insert collide at uq_unitload_labelid.
  B2  order    Long orderId = customerorderRepository.findIdByParcelLabelId(label);  // NEW projection
               if (orderId == null) throw new EntityNotFoundException(...);  // shape unchanged
               Customerorder order = customerorderRepository.findByIdForUpdate(orderId)
                                       .orElseThrow(...);
  B3  parcel   unitloadRepository.findByLabelidForUpdate(dto.getParcelLabel())
                 .orElseThrow(() -> new BusinessException("entityNotFoundForName",
                     Unitload.class.getSimpleName(), dto.getParcelLabel()));
               Same message as A3. A3 remains anyway: it keeps the not-found diagnosis
               AHEAD of the order lookup, which is the ordering today relies on.
               A3's check is scalar, so this is still the parcel's first ENTITY touch and
               no upgradeLockMode path exists.

PHASE C  every guard, on the LOCKED instances
  C1  order state: <PACKED / ==CANCELED / >=FINISHED
      + LOG.warn when the LOCKED state is already >= PALLETIZED, i.e. another session got
        there first. This is the production race instrument.
        NOTE: an earlier draft asked to compare the locked state against "the pre-lock
        read". After the F3/F4 revision there IS no pre-lock state read -- PHASE A takes
        only a scalar id projection -- so that comparison is unimplementable. Desktop can
        make it (ParcelMonitorViewService:158) only because ParcelMonitorViewService:145-152
        is the read-then-lock shape 3.1 forbids. Do not copy desktop here.
  C2  shipping-method checks       C3  pallet type check
  C4  assertPalletNotAssignedToGate   ← MOVED AHEAD OF THE WRITES. This is the Bug 1 fix.
  C5  assertParcelCarrierNotShipped   C6  assertParcelNotOnAnotherPallet
      (C5 before C6 preserved — the subset-diagnosis reason is lock-independent)

PHASE D  writes
  D1  getBySourceUnitLoadLabelId → D2 removeBOLPositionIfExists
  D3  if (order.getState() < PALLETIZED) { setState; save }   // plain save, row is locked
  D4  transferUnitLoadToCarrier(...)   // NOW legal: REQUIRED joins us, all locks held

PHASE E  notification — OUTSIDE the boundary (D3 decision)
  E1  outer non-transactional method calls manageOrderService.customerOrderPalletized(...)
      after the transactional method returns.
```

**Repository surface: two new scalar projections** (revised — see the A3/B2 notes above). The three
*locking* finders already exist and are unchanged: `findByIdForUpdate` and `findByLabelidForUpdate`
(Unitload), `findByIdForUpdate` (Customerorder). What must be **added** is the pre-lock diagnostic
layer that lets those locking finders stay each row's first entity touch:

| new method | repository | shape |
|---|---|---|
| `existsByLabelid(String)` | `UnitloadRepository` | scalar `boolean` |
| `findIdByParcelLabelId(String)` | `CustomerorderRepository` | `SELECT c.id` over the join `getByParcelLabelId` already uses |

Both need `@RestResource(exported = false)` — both repositories are `@RepositoryRestResource`-exported.

⚠ **No `EntityManager` field is required.** An earlier draft added one for
`refresh(order, PESSIMISTIC_WRITE)`; that approach is withdrawn (§3.1, review finding F4) and the
field goes with it.

⚠ **This is a new persistence surface, declared rather than discovered.** Per the tier router, "the
fix needs a repository method you had not anticipated" is an escalation trigger. It fires here — the
plan was drafted claiming none was needed. The tier does not move (already T3), but the claim is
corrected in the open rather than quietly.

**`uq_unitload_labelid` is load-bearing.** `findByLabelidForUpdate` locks a single row only because
of that constraint, which the entity does not declare. Verified present on Hydra prd (alongside a
redundant Hibernate-generated twin `uk_s2ujivixnde5dqb2stih8m2vh`); 863 rows, 863 distinct labelids.

### 3.4 `scanParcelBulk` — target shape

Same phases; only B1 differs. The pallet arrives **detached** (the controller loads it outside any
transaction with OSIV off), so `findByIdForUpdate(palletId)` is correct here — a detached entity has
no `EntityEntry` in this context, hence no `upgradeLockMode` path. Guard order C5→C6 is already
correct in this method and stays. Bug 4's bare stale-entity state write is replaced by the plain save
on the locked instance.

⚠ The method reassigns and returns its `pallet` **parameter**; the returned instance is now managed
and locked, and the controller serialises it after the transaction closed. `Unitload` declares only
scalar columns and `Long` FK fields (no JPA associations, per repo convention), so nothing lazy can
initialise. *Blind spot: this does not cover a Jackson mixin or `@JsonSerialize` customiser
registered elsewhere.* `PalletizingControllerUnitTest` already round-trips this response — confirm
it stays green.

### 3.5 `scanPalletBulk`

Third mutating entry point; mints a pallet on the `pallet == null` branch behind a **GET**. Gets the
boundary. ⚠ **Hard constraint:** `scanPalletBulk` and `scanParcelBulk` are two separate HTTP
requests, so **no boundary can span the bulk flow**. Each request must be individually atomic;
treating "the bulk flow" as one unit of work is wrong at the HTTP layer.

### 3.6 Lock-contention handling (D2)

Each lock acquisition is bounded at 10 s (`wms.tenant.lock-timeout-ms=10000`, applied as
`SET LOCAL lock_timeout` by `LockTimeoutHibernateJpaDialect.beginTransaction` — it *"requires an open
transaction"*, which is why the mobile path is unbounded today). The bound is **per acquisition, not
per transaction**: three locks ⇒ worst case 30 s.

Catch `PessimisticLockingFailureException` (and `CannotAcquireLockException` for the PG `40P01`
deadlock abort, which fires at ~1 s) at the palletize entry points and translate to a
`BusinessException` the controller already renders:

> "Parcel is being palletized by another operator — rescan in a moment."

**RECOMMENDATION (measured 2026-09-17): lower `wms.tenant.lock-timeout-ms` from 10000 to `3000`.**

Three constraints fix the value; the floor is the binding one.

| constraint | value | source |
|---|---|---|
| **Hard floor — must exceed `deadlock_timeout`** | **> 1000 ms** | `pg_settings`, measured on Hydra prd **and** WineCo UAT: `deadlock_timeout = 1000`, `source = default` |
| Ceiling — operator-visible worst case is **3 × bound** (3 locks, per-acquisition) | 30 s today | `LockTimeoutHibernateJpaDialect` javadoc: *"per acquisition, not per transaction"* |
| Must clear the legitimate hold time | max observed **2235 ms** | WineCo UAT, below |

**Why the floor is non-negotiable.** PostgreSQL's deadlock detector only runs after a waiter has
blocked for `deadlock_timeout`. Set `lock_timeout` at or below 1000 ms and a genuine deadlock is
killed as `55P03 lock_not_available` *before* the detector ever runs — you lose `40P01
deadlock_detected` and, with it, the log line naming **both** parties and both statements. With
[SBDEV-3419](https://app.clickup.com/t/868m6j1t2) open — a live ABBA whose diagnosis depends on
exactly that log line — trading it away for a snappier handheld is the wrong call. 3000 ms leaves a
3× margin so the detector reliably wins the race.

**Measured legitimate hold time.** Proxy: the write span inside one palletize request
(`unitload_record` `CREATED` → `TRANSFERRED`, same operator). WineCo UAT (`wh01_om1_v2`), the busiest
tenant, **15,657 pairs**:

| band | pairs | cumulative |
|---|---|---|
| 1–499 ms | 15,499 | 98.99% |
| 500–974 ms | 130 | 99.82% |
| 1012–1489 ms | 21 | 99.95% |
| 1550–1907 ms | 5 | 99.98% |
| 2051–2235 ms | 2 | 100% |

p50 **41 ms**, p95 **211 ms**, p99 **466 ms**. 3000 ms clears the largest observed span; 2000 ms
would clip 2 in 15,657 (0.013%) and 1500 ms would clip 7. *Blind spot, stated: this measures the
**write span**, which is a lower bound on the transaction's hold time — it excludes the pre-write
reads and the commit — so treat 2235 ms as a floor on the tail, not the tail itself. That is the
reason to take 3000 rather than 2500.*

**Net effect:** operator-visible worst case falls from **30 s to 9 s**, and the realistic
single-contended-lock case from 10 s to 3 s.

⚠ **This property is GLOBAL, not per-path.** `TenantDatabaseConfig:47`
(`@Value("${wms.tenant.lock-timeout-ms:10000}")`) seats it on the tenant `EntityManagerFactory`, and
the dialect applies it via `SET LOCAL` in `beginTransaction` for **every** tenant transaction. There
is no per-path override mechanism and this plan does **not** add one. Lowering it therefore affects
all 15 `@Lock(PESSIMISTIC_WRITE)` methods, the 2 native `FOR UPDATE` queries and the ~31 bulk
`@Modifying` statements. **Anything that legitimately holds a tenant row lock for more than 3 s would
start failing waiters that previously succeeded** — the cron jobs and `closeBOL` are the candidates
worth a look before merging.

**De-risking:** standard Spring relaxed binding means `WMS_TENANT_LOCK_TIMEOUT_MS` overrides it as a
stack-level environment variable per environment, with no code change and no rebuild. So this is
tunable in place if a long holder does surface, and revertible without a deploy.

## 4. Scope

### 4.1 In scope
- `MobilePalletizingService` — boundary, locks, guard reorder, Bug 4 symmetry (3 mutating methods)
- **Not** `MobileTruckLoadingService` — unbundled; see §4.3 **P0** and §4.4
- `OptimisticLockRetry` retirement (D1) — see §4.2 for the corrected file list
- Live-doc sweep (D5)
- Desktop lock-order **comment** correction (§3.2) — comment only, no behaviour change

### 4.2 `OptimisticLockRetry` retirement — corrected file list

⚠ **The delete list in the ticket discussion was incomplete: five Java test classes plus one shell
script must change, not one file** (F13; an earlier draft said "six test files", conflating the two).
Leaving any of them fails compilation.

| file | why |
|---|---|
| `util/OptimisticLockRetry.java` | delete (0 consumers after D1) |
| `MobilePalletizingService.java` — import, field, ctor param, assignment, call site | ctor arity changes |
| `unit/service/OptimisticLockRetryScopeTest.java` | delete — all 4 tests |
| **`unit/util/OptimisticLockRetryTest.java`** | **~15 tests against the deleted type — was NOT on the original list** |
| `MobilePalletizingServiceUnitTest.java:13,78-79` | import + **`@Spy`** field (not `@Mock` — see §6.3) |
| `MobilePalletizingServiceTest.java:98` | positional `new OptimisticLockRetry()` ctor arg |
| `MobilePalletizingScanPalletFormatTest.java:80` | positional ctor arg |
| `sbdocs/4-Archieves/scripts/verify-260610-*.sh` | two POS rows **invert** — retire or annotate |
| `unit/service/Sbdev2620PalletizeGuardCoverageTest` | ⚠ **not a deletion — a constraint.** It pins `EXPECTED_…SITES = 3` and requires the guard and the transfer to be in the **same method**. D3's extraction of the writes onto a separate bean can break both. Re-run it explicitly and update the count only if the change is intended (F11). |

⚠ **Do not simply unwrap the retry at the call site.** Its lambda contains a re-fetch **and a
re-check** of the state guard against the fresh instance — the only lost-update protection on that
path today. It is replaced by the locked read, not deleted.

**Supersession, stated explicitly.** Archived plan `260610-wms2-multi-replica-hardening` Phase A
rejected *"delete `OptimisticLockRetry` entirely"* **solely because** `scanPallet` is
non-transactional. This ticket removes that premise, so the reversal is valid — but it must be
recorded, or two archived decisions sit in open conflict.

### 4.3 Out of scope — P0 and P1 filed on Nam's instruction; P2–P6 proposed, not filed

Per the ticket policy a T3 finding is *proposed* and Nam decides. **P0 ([SBDEV-3418](https://app.clickup.com/t/868m6hue5)) and P1 ([SBDEV-3419](https://app.clickup.com/t/868m6j1t2)) were decided and filed.** P2–P6 below remain proposals — nothing has been filed for them.

Ranked, each with blast radius and cost. **I would do P1 first.**

| # | Finding | Tier | Blast radius | Cost |
|---|---|---|---|---|
| **P0** | **[SBDEV-3418](https://app.clickup.com/t/868m6hue5) — `MobileTruckLoadingService`, the unbundled other half. FILED 2026-09-17.** Zero `@Transactional`, 5 writes, zero locks; writes a BOL header, N positions and a customer-order state across ~70 lines with no boundary. Analysis already complete — **§4.4** and `lane5-truckloading.md`. **Do this next.** | T3 | one service + ITs | ~1 day |
| **P1** | **[SBDEV-3419](https://app.clickup.com/t/868m6j1t2) — `closeBOL ↔ palletise` ABBA deadlock, live on develop today. FILED 2026-09-17.** `closeBOL` locks `customerorder` before `unitload`; `palletise` locks `unitload(pallet)` before `customerorder`. PG-detected `40P01` at ~1 s, so bounded and visible — but real, and this PR adds a third participant. Fix = flip `palletise` to CO-first. | T3 | `ParcelMonitorViewService` + `BillofladingService` + a desktop concurrency IT | ~1 day |
| P2 | **`MobileCycleCountService`** — zero `@Transactional`, 6 direct writes, delegates `sendStockUnitToNirvana` / `changeAmount`. Inventory adjustment: largest blast radius of the three siblings. | T3 | one service + ITs | ~½ day |
| P3 | **`MobileTransferOrderService`** — zero `@Transactional`, 7 delegated mutations, no locks. ⚠ **Corrected (review finding F5):** an earlier draft said it takes a `findByIdForUpdate` with no transaction to hold it in. It does **not** — the single occurrence of that token is a *comment* at `:405` recording a deliberate choice to use plain `findById` for lock-order reasons. The defect is the missing boundary, not a useless lock. | T3 | one service | ~½ day |
| P4 | **Migrate `ORDER_BATCH_PALLETIZED` to the transactional outbox** at *both* call sites. Blocked today: `outboxService.enqueue` is `Propagation.MANDATORY` (this ticket is its precondition) and no `buildPalletizedPayloadJson` exists. Caveat: the dispatcher's `Status`-blindness is a separate open item, so this is not a pure upgrade. | T3 | `ManageOrderService` + 2 callers + dispatcher routing | ~½ day |
| P5 | **Mutating `GET`s.** `scanPalletBulk` and `scanParcelBulk` write behind `@GetMapping` and are not covered by `IdempotencyFilter` (which skips GET and everything outside `/rest/**`). The mobile client does **not** amplify this — its `axios-retry` `retryCondition` returns false for anything that is not a 401/403 token refresh — so the replay risk is infrastructure-level only. Contract change; would break both UIs. | T2 | 2 endpoints + both UIs | ~½ day |
| P6 | Redundant duplicate unique index on `unitload(labelid)` — `uq_unitload_labelid` **and** `uk_s2ujivixnde5dqb2stih8m2vh`, both `UNIQUE(labelid)` on Hydra prd. Minor write-amplification only. | T1 | one migration | ~1 hr |

Also, four `transferUnitLoadToCarrier` callers violate the **lock half** of the SBDEV-2232 contract
while being correctly transactional (`AdviceService`, `ReceivingService`, `StockunitService`,
`MobileMoveUnitloadService`). ⚠ **Corrected (review finding F7):** `MobilePickingService` calls
`transferUnitLoadToCart`, not `…ToCarrier`, so the carrier-call denominator is **7**, not 8. The "8"
came from a stale javadoc and contradicted this plan's own claim that the list was enumerated
mechanically — exactly the failure mode the claim-discipline rule exists to catch. Two are already analysed and accepted with DB
controls in `Sbdev3397TransferGuardCoverageTest`. Not proposed as tickets — recorded here so the
denominator is accurate. *Derivation: all 7 `transferUnitLoadToCarrier` call sites in `src/main` enumerated mechanically
(Lane 3 Axis B; the 8th is `transferUnitLoadToCart`). Blind spot: a call reached through a lambda or reflection would not appear.*

---





### 4.4 P0 detail — `MobileTruckLoadingService` → filed as [SBDEV-3418](https://app.clickup.com/t/868m6hue5)

*Retained here because SBDEV-3418's description points back at this section. Do not delete it when
this plan is archived without first copying it onto that ticket.*

Source: Lane 5 (`lane5-truckloading.md`). Writes are at `:244 :253 :280 :299 :307`.

#### 4.4.1 Lock order — truck loading must take the BOL lock FIRST

```
Billoflading → Unitload (pallet, then parcels asc) → Customerorder asc
             → CustomerorderPosition → Stockunit → Location
```

`scanGate` today reads in the **opposite** order: pallet at `:189`, BOL at `:200`. Wrapping it in a
boundary while preserving that order **closes a cycle with `closeBOL`**, which holds the BOL lock
while bulk-writing `unitload` / `customerorder` / `stockunit`. That is precisely the
"this PR ships a worse bug than it fixes" case. **The BOL lock must move ahead of the pallet lock.**

#### 4.4.2 ⚠ Compatibility with §3.2 — THE PROOF WAS WRONG; this is why P0 is separate

An earlier draft claimed palletize and truck loading were compatible because "both paths always
contend first on `UL(pallet)`, so the loser blocks before holding anything the winner needs."
**That is only true for the SAME pallet.** Verification found the counter-example:

```
  DIFFERENT pallets, same parcel P:
    palletize      holds UL(B), CO(P)        wants UL(P)
    truck loading  holds BOL, UL(A), UL(P)   wants CO(P)
                                              => clean ABBA
```

`MobileTruckLoadingService` resolves parcels **before** orders —
`unitloadRepository.findByCarrierunitloadId(pallet.getId())` then
`customerorderRepository.getByParcelIdList(parcelIds)` — so locking in read order inverts §3.2's
customer-order-before-parcel. **Bundling the two naively would have introduced this deadlock**, on
the exact scenario AC-6 tests. Distinct from P1: P1 already exists on develop; this one would have
been created by this PR.

**Resolution for P0:** lock `BOL → UL(pallet) → CO asc → UL(parcels)`, which needs scalar id
projections to resolve the parcel and order sets without materialising them first (the §3.1
first-touch rule), plus possibly a multi-row locked customer-order finder. That restructure is why
P0 is its own ticket rather than a section of this one.

> ⚠ **SUPERSEDED 2026-09-18 by [SBDEV-3419](https://app.clickup.com/t/868m6j1t2). Do NOT implement
> the order above on SBDEV-3418.** It places `CO asc` before `UL(parcels)`, which is the ABBA
> SBDEV-3419 exists to close. `closeBOL`'s real order was measured off `pg_locks` — it is
> `unitload → stockunit → customerorder`, not the read order this plan inferred — so the agreed
> global order is:
>
> `Billoflading → Unitload (pallet, then parcels asc by PARCEL id) → Stockunit → Customerorder asc → CustomerorderPosition`
>
> `palletise` and `MobilePalletizeWriteService` were moved onto it under SBDEV-3419. SBDEV-3418 must
> join it rather than re-derive one.
>
> ⚠ **It is a TABLE order and it does not close every cycle.** It does not order rows *within* the
> `unitload` set, and one cycle is still open: `closeBOL`'s bulk update has no `ORDER BY` and its
> measured plan is a Bitmap Heap Scan (ctid order), with **27.32% of 480,334 (pallet, child) pairs**
> having the child physically ahead of its pallet. A palletize holding a pallet and waiting for its
> parcel can therefore still deadlock against a `closeBOL` holding that parcel. Pre-existing, **not**
> closed by SBDEV-3419. Do not read "join this order" as "cycles are impossible".
>
> ⚠ The obvious remedy does not exist: **a JPQL bulk UPDATE cannot carry an `ORDER BY`**, so that
> statement cannot simply be ordered. Closing it needs a locked pre-pass over the ids in sorted
> order, or native SQL whose subselect does the ordering. Note §4.4.1's own summary line already had this right
> (`Billoflading → Unitload (pallet, then parcels asc) → Customerorder asc`); this resolution
> paragraph contradicted it, and the contradiction is what would have been inherited.

#### 4.4.3 Highest risk here is NOT the lock order

`handleTruckOffLoading` (called at `:247`) invokes two delete queries annotated
`@Modifying(clearAutomatically = true)`. Under a single boundary, that `em.clear()` can **silently
discard the pending `UPDATE billoflading` queued at `:244`** — there is no query-space overlap, so
Hibernate may not auto-flush first. The method then returns 200 having lost the state + gate write.

**Fix: move `handleTruckOffLoading` to the front of the transactional method**, before any pending
write exists. ⚠ **This must be proven by a test, not reasoned about** — whether Hibernate auto-flushes
here depends on query-space overlap analysis that is not safe to predict.

#### 4.4.4 The `REQUIRES_NEW` sequence landmine — WITHDRAWN, it does not exist

⚠ **An earlier draft asserted that `scanGate` reaches a `REQUIRES_NEW` sequence allocation through
`BillofladingPositionService.createEntity` → `basicService.generatePositionNumber(...)`. That is
false (review finding F2).** `BasicService.generatePositionNumber:75-80` is pure
`String.format(prefix + getFormat(), positionIndex)` — it allocates nothing and touches no
sequence. **No `REQUIRES_NEW` *transaction* is reachable from `scanGate`** — traced every annotated bean on the call graph. *Blind spot named: `MessageService.createServiceLog` IS annotated and IS reached, but via self-invocation, so no proxy applies and no new transaction begins*, so there is no undetectable-hang
hazard on this path and no ordering constraint follows from it.

The general rule remains true and worth keeping in mind for *other* paths — a `REQUIRES_NEW` inside a
lock-holding transaction is not detectable by PostgreSQL's deadlock detector — but it does not apply
here. Recorded rather than deleted because the claim was published on the ticket and a reader may
remember it.

#### 4.4.5 Field evidence — partial BOLs are already durable

| tenant | duplicate position numbers | childless pallet positions | positive control |
|---|---|---|---|
| Hydra UAT | **4** | **8** | scans return non-zero on the control predicates |
| Hydra prd | 0 | 0 | 663 rows / 37 BOLs |

These partial BOLs ride through to `CLOSED` and land on the manifest — `closeBOL`'s garbage filter
does not catch them. So the boundary is not only a concurrency fix here; it closes a durable
data-quality leak. *Gap: the two UIs and `oms-laravel-api` were not grepped for consumers of a
partial BOL, so "nothing consumes them" is unverified downstream of WMS.*

#### 4.4.6 Test surface

**Zero new repository methods** (resolve the BOL by name, then `findByIdForUpdate(id)` — the
`palletise` shape). Expected reds: `OptionalSafetyArchTest` (the extraction orphans two frozen
entries — fix by converting `:190`/`:207` to `.orElse(null)`; **do not refreeze**),
`MobileTruckLoadingServiceTest` (hand-built ctor + `STRICT_STUBS`), `UnitloadBusinessServiceUnitTest`.

⚠ **Green-but-false:** `NestedCallSiteRailTest` stays green while the comment at `:313-316`
(*"correctness no longer depends on the absence of an annotation"*) becomes false. And
`HttpInTransactionArchTest` is **direct-call-only**, so it would **not** catch leaving the OMS call
inside the boundary — do not cite it as evidence that D3 was honoured. AC-5 is the only check for that.



---

## 5. Implementation Steps

### 5.1 Prerequisites

| Item | Status |
|---|---|
| DB state | None required. No migration, no backfill. |
| Feature flags / sysprops | None new. `wms.tenant.lock-timeout-ms` already exists (10000). |
| Config / env | None. |
| Deploy order | Single repo, single deploy. |
| External systems | OMS notification **timing is unchanged** by design (D3) — verify, do not assume. |
| Access | Hydra + WineCo UAT DB access for the §7 manual smoke. |
| Monitoring | `hikaricp.connections.active` should be observed across the change (Lane 2's recommendation — measure rather than assert either answer on connection holding). ⚠ Nothing scrapes Prometheus yet, so this is a manual read, not an alert. |

### 5.2 Order of work

1. **Branch** `bugfix/SBDEV-3398-mobile-palletize-tx-boundary` off fresh `origin/develop`.
   *(Worktree already created at `.claude/worktrees/wms2-api/SBDEV-3398`, branched at `9f600e52`.)*
2. **TDD gate — Bug 1 first.** The deterministic reproduction is the strongest acceptance test and
   needs no concurrency harness. Write it before anything else (§6.1 AC-1).
3. Boundary + locks on `MobilePalletizingService` (§3.3–3.5), guard reorder, Bug 4 symmetry.
4. Lock-contention translation (§3.6).
5. Notification extraction to a separate bean (D3).
6. `OptimisticLockRetry` retirement (§4.2) — **last** among code changes, so the compile breakage
   surfaces against otherwise-working code.
8. Live-doc sweep (D5) + desktop comment fix.
9. Full suite vs baseline; PIT on both changed services; review lanes.

---

## 6. Acceptance Criteria

### 6.1 Deterministic (no concurrency harness)

- **AC-1 — Bug 1.** Parcel on a gated pallet, re-scanned onto that same pallet via `scanPallet`:
  the call is rejected **and** the parcel's `billoflading_position` rows still exist afterwards.
  Must fail on the pre-fix tree for the right reason (asserting surviving rows, not an exception type).
- **AC-2 — rollback (restated; the original was vacuous).** ⚠ After the §3.3 reorder there is **no
  guard after `removeBOLPositionIfExists`** — C4/C5/C6 all move to PHASE C — so the original wording
  quantified over an empty set and would pass forever, including after someone deletes `rollbackFor`.
  Restated: **inject a failure at D4 (`transferUnitLoadToCarrier`) and assert the `:248` DELETE is
  rolled back.** Mutation check: drop `rollbackFor` ⇒ red.
- **AC-3 — guard order preserved.** `assertParcelCarrierNotShipped` still precedes
  `assertParcelNotOnAnotherPallet`, and both still precede the writes.
  `Sbdev2620PalletizeGuardCoverageTest` is a **source-text** scan sensitive to the guard and the
  transfer landing in different helper methods — re-run it explicitly after the refactor.
- **AC-4 — Bug 4 symmetry.** Both methods write the order state from a locked instance.
- **AC-5 — no OMS regression.** `customerOrderPalletized` fires exactly once, after commit, and its
  `sendAfterCommit` still takes the **else** branch (synchronous POST) — i.e. D3 held and the
  notification did not silently move inside the boundary.

### 6.2 Concurrency

- **AC-6 — the race.** Two threads palletizing the same parcel onto different pallets: exactly one
  succeeds; the loser is rejected by a guard, not by a 500. Model on
  `ParcelMonitorViewServiceConcurrencyIT` (`BasePostgresIntegrationTest`, `PgLaneFixtures`,
  `requiresNewTx()`, latch pattern) — that IT is repository-level; this one must be **service**-level.
- **AC-6b — the read-then-lock escape.** AC-6 as written cannot catch the naive shape: with two
  *different* pallets there is no pallet-lock contention, and a latch at the natural spot yields a
  clean guard rejection and a green AC-6 on a broken implementation. The harness must **force thread
  B's non-locking reads to complete before thread A commits**, and assert the outcome is a
  `BusinessException` — asserting on the **cause**, not the HTTP body.
- **AC-6c — static first-touch pin.** Model on `unit/service/ReplenishmentFirstTouchInvariantUnitTest`
  (`InOrder` + `never()` on the non-locking finders + `verifyNoMoreInteractions`). This closes the
  escape without a concurrency harness and is the cheaper of the two.
- **AC-7 — contention surfaces as a business message**, not `PessimisticLockingFailureException`.
  ⚠ **Pin the caught types exhaustively.** Broadening the catch to `RuntimeException` — or adding
  `ObjectOptimisticLockingFailureException` "for safety" — would turn the Escape-1 500 into the same
  business message and make AC-6 *and* AC-7 green on the broken shape.
- **AC-11 — the re-check survived D1.** With the order advanced to `PALLETIZED` by another session
  between the pre-lock diagnostic and the lock, the state write must be **skipped**. Without this,
  nothing distinguishes "re-checked under the lock" from "checked pre-lock, written post-lock".
- **AC-12 — `scanPalletBulk`.** The third mutating entry point had no AC at all. It mints a pallet
  row behind a `GET`: assert the boundary exists and that a rejection after the mint leaves no
  committed `unitload` row.

### 6.3 Floor (never skipped)

- Mutation-check every new assertion with **PIT** scoped to the changed class. The kill must be
  **attributable** — the failure message must name the thing broken. A `NoSuchMethodException` or a
  setup NPE is a red, not a kill.
- ⚠ Run `mvn clean test` / `mvn clean verify`, **not** `mvn test`. D1 deletes two test classes; a
  stale `target/test-classes` will keep running them and report a false green.
- Full suite vs baseline: **surefire 6711 / 0 failures / 0 errors / 1 skipped; failsafe 447 / 0 / 0 /
  31 skipped** on `origin/develop` @ `9f600e52`, BUILD SUCCESS. Compare **failures, not totals** —
  totals move with every merge.

⚠ **CORRECTION — an earlier draft of this plan, and two ticket comments, claimed that
`scanPallet`'s PALLETIZED state write "has never executed" in `MobilePalletizingServiceUnitTest`
because the `OptimisticLockRetry` collaborator was an unstubbed `@Mock`. **That is false** (review
finding F1). The field at `MobilePalletizingServiceUnitTest.java:78` is **`@Spy`**, not `@Mock`:

```java
    @Spy
    private OptimisticLockRetry optimisticLockRetry;
```

A `@Spy` wraps a **real** instance, so `executeWithRetry` runs the lambda normally. That is Mockito
semantics and is sufficient on its own.

⚠ **A second correction, on top of the first.** An earlier revision of this very paragraph argued the
stubs at `:922-923` *prove* the lambda runs, "because under `STRICT_STUBS` an unused stub fails".
**That proof is invalid**: the class is annotated `@MockitoSettings(strictness = Strictness.LENIENT)`
at `:33`, so unused stubs never fail here and their presence proves nothing. The conclusion stands on
`@Spy` alone. Recorded because it is an instructive instance of the documented failure mode —
correcting a false claim produced a new false claim inside the correction.

**How the error happened, because the shape matters more than the instance:** the symbol was located
with a grep for `OptimisticLockRetry`, which matched the field declaration on line 79 but not the
annotation on line 78. The absence of any `when(...)` on that field was then read as "unstubbed mock"
— true and unremarkable for a spy. The same mistake (locating a token without reading the line it
sits on) produced two other false claims in this plan, F2 and F5, and an incorrect
`findByIdForUpdate` count. **Do not carry any "expected fallout" allowance into implementation: there
is no known vacuity here, so a red after D1 is a real regression until proven otherwise.**

### 6.4 No verify script

Per the tier router, a T3 verify script is opt-in and capped at 15 rows. **This plan declines one.**
Every assertion above is expressible in JUnit, which runs in CI, survives refactors and can be
mutation-checked. The one cross-file invariant worth a row — "every `CODE_PALLETISING` transfer is
preceded by the re-palletize guard" — is **already** covered by `Sbdev2620PalletizeGuardCoverageTest`.

---

## 7. Testing Plan

**Unit.** Bug 1 ordering; guard evaluation against locked instances; Bug 4 symmetry; lock-failure
translation. Note the repo default is `STRICT_STUBS`.

**Integration (Testcontainers, `postgres:14-alpine` — matches production 14.23).** AC-6 service-level
concurrency IT. Fixture traps to avoid, both measured previously in this repo: `client_id` does **not**
isolate a committed fixture from an id-watermark sweep, and a `jdbcTemplate` version bump
self-deadlocks. Repository tests here **commit** rather than roll back — assert by id, never
`isEmpty()`/`hasSize()`.

⚠ `NestedSendAfterCommitIT` probes a synthetic bean, not `MobilePalletizingService`. It will stay
green through this change and **cannot** detect a regression in the real nesting depth at these two
sites. Do not treat its green as coverage of AC-5.

**Manual smoke.**

| # | Scenario | Env | Expected |
|---|---|---|---|
| M1 | Re-scan a parcel onto its own gated pallet (Bug 1) | Hydra UAT handheld | Rejected; `billoflading_position` rows intact (verify by SQL) |
| M2 | Two handhelds, same parcel, different pallets | Hydra UAT | One succeeds; other gets the business message, not a 500 |
| M3 | Normal palletize end-to-end | Hydra UAT | Unchanged; OMS receives `ORDER_BATCH_PALLETIZED` once |
| M4 | Bulk flow `scanPalletBulk` → `scanParcelBulk` | Hydra UAT | Unchanged across the two requests |
| M5 | Truck loading after palletize | Hydra UAT | Unchanged — truck loading is **not** touched by this PR (P0) |

---

## 8. Risks

| Risk | Impact | Mitigation |
|---|---|---|
| Read-then-lock shape ships by mistake | HTTP 500 under exactly the race being fixed; **all uncontended tests green** | §3.1 rule: locking finder is the row's first touch. AC-6 reproduces contention. Call it out in review. |
| 3 × 10 s worst-case handheld freeze | Operator-visible | §3.6; evaluate a shorter per-path bound at review |
| `catch (Exception)` swallow inside an open tx | `UnexpectedRollbackException` → HTTP 500 | Avoided by D3; if D3 is ever reversed, narrow the catch |
| Guard-coverage source-text rails break on refactor | False red / false green | AC-3 re-runs them explicitly |
| Doc sweep misses a live assertion | A doc asserts a false rationale | D5 list is derived, not recalled (Lane 3 Axis D) |

---

## 9. Open Questions

1. ~~**Shorter lock bound for the handheld path?**~~ **DECIDED 2026-09-17 (Nam): lower to 3000,
   in its own commit (`e3e90279`) so it can be reverted independently of the palletize fix.**
   Kept below in full because the derivation is the durable part. Worst case is 3 × 10 s on palletize, since the bound is per
   acquisition, not per transaction. The PR deliberately does **not** change
   `wms.tenant.lock-timeout-ms`: it is a global property affecting all 15 `@Lock` methods, the 2
   native `FOR UPDATE` queries and ~31 bulk `@Modifying` statements, and it was not approved.

   ⚠ **New evidence from the implementation's security review lane, which sharpens this from a UX
   question into an availability one.** The lane measured the prd landlord DB: `tenant_db_configuration`
   has exactly one active row, `tenant_id=1, warehouse='nywh'`, with **`max_pool_size=5`** and
   `connection_timeout_ms=30000` — and `TenantDynamicRoutingDataSource` passes both straight to Hikari.
   Five concurrent contending palletize scans therefore hold **all five** connection slots for up to
   ~30 s each, and the sixth request *for any endpoint on that tenant* waits out the 30 s connection
   timeout and fails — the whole warehouse's handhelds, not just the palletize screen. It is also
   silent: `leakDetectionThreshold` is 60 s, double the worst-case hold, so nothing logs, and nothing
   scrapes the Hikari metrics yet.

   **This exposure is new**, and the plan should say so plainly: before this change palletize held no
   connection across a lock wait, because it took no locks and opened no transaction. The boundary is
   still the right fix — the alternative is the committed-DELETE-then-reject data loss in §1.1 — but
   "we were already slow there" does not license it.

   **Two independent reviewers now converge on the same remedy**, which is §3.6's recommendation:
   lower the bound to **3000 ms** (floor set by PostgreSQL's `deadlock_timeout = 1000`, ceiling by the
   max observed legitimate hold of 2235 ms on WineCo UAT). That cuts the worst case 30 s → 9 s.
   Cheapest alternative if 3000 is judged too aggressive: raise `max_pool_size` above 5 on the prd
   tenant row — one UPDATE, no code — but it only moves the threshold rather than removing it.
   Revertible either way without a deploy via `WMS_TENANT_LOCK_TIMEOUT_MS`.

   **Decided: 3000.** Applied in `e3e90279`, separate from the correctness fix. Also updated: the
   `@Value` fallback in `TenantDatabaseConfig` (so a missing property cannot silently restore 10 s),
   two javadocs that stated "default 10s", and `TenantLockTimeoutPropertyUnitTest`, which pinned
   `10_000` and fired correctly — that rail reads the production file off the filesystem, because
   `src/test/resources/application.properties` shadows the main file and no Spring test lane can see
   it. Mutation-checked: setting the file to 9999 fails with a message naming the agreed value. The
   `postgres-integration` test profile is deliberately left at 10000 and now says why.

   ⚠ **One scope correction to the framing above**, which overstated the blast radius: this property
   bounds how long a transaction **waits to acquire** a lock, not how long it may **hold** one. A
   long-running cron job or `closeBOL` is unaffected unless something else waits on it past the
   bound. Given measured palletize holds are p99 466 ms, that is a much narrower risk than
   "anything holding a lock for more than 3 s".

   *Residual, stated rather than hidden:* the hold-time measurement covers the palletize flow only.
   Two attempts to measure other flows' hold times from `unitload_record` produced unusable
   instruments — one bucketed by second (capping every span at ~1 s), one used a 60 s window that
   captured consecutive operator actions rather than intra-transaction writes, reporting
   `PALLETIZING` at 53,922 ms against the careful measurement's 2,235 ms for the same flow. Both were
   discarded rather than reported. So "no other flow needs more than 3 s of lock WAITING" is
   reasoned from the scope correction above, not measured.
2. ~~**P1 (the `closeBOL ↔ palletise` ABBA)** — proposed, awaiting a decision to file.~~
   **RESOLVED — filed as [SBDEV-3419](https://app.clickup.com/t/868m6j1t2).** §4.4.2's compatibility
   proof covers **explicit** locks only; P1 is an implicit-lock inversion, so it is not resolved by
   anything in this PR. ⚠ This PR **widens** its window: `removeBOLPositionIfExists` locks a fourth
   row class not named in §3.2's order, and those locks are now held to commit instead of
   auto-committing microseconds later. Outcome when it fires is unchanged (`40P01` → the operator-legible
   contention message, not a 500). Recorded on SBDEV-3419 rather than left implicit.
3. ~~**Partial-BOL consumers downstream of WMS** (§4.4.5)~~ — **RESOLVED as out of scope:** a **P0**
   question, owned by [SBDEV-3418](https://app.clickup.com/t/868m6hue5), not this PR's — the two UIs and `oms-laravel-api` were not
   grepped. If something downstream *depends* on a partially-built BOL being visible, §4.4.3's
   reordering needs revisiting.

---

## 10. Implementation Status

**Implemented.** Branch `bugfix/SBDEV-3398-mobile-palletize-tx-boundary`, worktree
`.claude/worktrees/wms2-api/SBDEV-3398`, rebased onto `origin/develop` @ `f02fc805` (2026-09-17).

| commit | what |
|---|---|
| `f7032ac4` | the boundary, the three row locks, the two scalar projections, the guard reorder, Bug 4 symmetry, the contention translation, `OptimisticLockRetry` retirement |
| `697071ab` | review findings — 1 High, 4 Medium, 12 Low — plus the two §4.1 scope rows the conformance lane found missing |
| `b5b81926` | conformance follow-ups: the D3 structural pin, two stale rationale comments |

⚠ The SHAs above are post-rebase. The pre-rebase originals were `ee7bcfdf` and `e890b127`; the
review lanes graded those, so their reports cite them.

### 10.1 Design as built — where it differs from §3, and why

`MobilePalletizingService` keeps its **entire public API** (so `PalletizingController` and
`PalletizingControllerUnitTest` are untouched) and stays non-transactional. The mutating bodies moved
to a new `MobilePalletizeWriteService`, which owns one `@Transactional(value =
"tenantTransactionManager", rollbackFor = {BusinessException.class, FacadeException.class})` per entry
point. D3 requires the notification to run with no transaction active, and a `@Transactional` method
cannot call its own non-transactional sibling to achieve that — self-invocation bypasses the proxy —
so the boundary had to live on a second bean.

Deviations from the letter of §3, all judged **acceptable** by the conformance lane:

| # | Deviation | Why |
|---|---|---|
| a | `scanParcelBulk` keeps its **original** rejection ordering (gate guard right after the pallet lock) rather than a strict PHASE A/B/C/D block | Its guard order was already correct — only `scanPallet` evaluated one after a committed DELETE. The **acquisition** order, which is the thing §3.2 constrains, is unchanged. Moving it would have changed which message an operator sees for a gated pallet carrying an unknown parcel, for no benefit |
| b | `scanParcelBulk` locks the pallet by **label**, not by id as §3.3 B2 says | Keeps the not-found message byte-identical; `uq_unitload_labelid` makes the label a single-row key, so the lock is equivalent |
| c | The `UNIT_LOAD_TYPE_PALLET` lookup is **lazy** | A missing seed row no longer fails *every* `scanPallet` — only the mint and type-check paths |

### 10.2 ⚠ Operator-visible diagnosis changes — deliberate, and forced by the lock order

None of these changes a verdict; they change which message arrives first. Recorded because nothing in
§6 grades error ordering, so they would otherwise ship unannounced.

1. **Order-state errors now come after pallet resolution.** The lock order demands `UL(pallet)` first,
   and the order-state gate needs the *locked* order, so it cannot precede the pallet any more. A
   parcel on a not-yet-`PACKED` or already-`FINISHED` order, scanned onto an unknown **badly
   formatted** pallet label, now reports the label problem instead of the order state. With a
   well-formed new label the mint happens and the order-state message still arrives — after an insert
   that then rolls back. No durable difference.
2. **An empty pallet label** is rejected before the order-state guards.
3. **The pallet-type check and the gate guard** now precede `assertParcelCarrierNotShipped` /
   `assertParcelNotOnAnotherPallet`, so a parcel already on another pallet scanned onto a non-pallet
   unit load now reads `"Not a pallet: X"`.

### 10.3 Tests

Four new test classes plus rails; `MobilePalletizingServiceUnitTest`, `MobilePalletizingServiceTest`
and `MobilePalletizingScanPalletFormatTest` rewired onto the new bean via the shared
`PalletizeLockingFinderBridge`.

⚠ **Counting correction (re-review).** An earlier revision of this section, and the hand-off, said
"122 unit + 5 IT". That double-counted: the 122 came from a wildcard `-Dtest=MobilePalletize*`
selector, which surefire also matches against the `*IT` classes, so the five ITs were counted in both
figures. Re-derived with an explicit class list: **118 unit + 5 IT = 123 targeted tests.**

| class | ACs |
|---|---|
| `unit/repo/MobilePalletizeIdProjectionContractUnitTest` | §3.3 surface, both projections unexported |
| `unit/service/mobile/MobilePalletizeFirstTouchInvariantUnitTest` | AC-4, AC-6c, AC-11, + the H1 regression pin |
| `unit/service/mobile/MobilePalletizeLockContentionUnitTest` | AC-7 (incl. exhaustiveness), AC-5 once-only, the D3 structural pin (via `AnnotatedElementUtils.findMergedAnnotation`, so a composed annotation cannot slip past) |
| `integration/…/MobilePalletizeGuardOrderIT` | AC-1 |
| `integration/…/MobilePalletizeRollbackIT` | AC-2, AC-5 (no transaction active at the notification) |
| `integration/…/MobilePalletizeRaceIT` | AC-6 — Testcontainers PostgreSQL, 8 rounds |
| `integration/…/MobilePalletizeBulkMintIT` | AC-12 |

**AC-3** is `Sbdev2620PalletizeGuardCoverageTest` — re-run explicitly; it still finds exactly 3
`CODE_PALLETISING` sites and same-method guard containment holds, because the two mobile sites moved
*class* rather than breaking the rule.

**Mutation testing.** PIT on both changed classes: **108 mutations, 85 killed, test strength 98%**.
The only 2 survivors are `ConditionalsBoundary` and `NegateConditionals` on the
`state >= PALLETIZED` **`LOG.warn`-only** branch — the production race instrument. Behaviourally inert,
so no assertion can kill them without asserting on a log line; accepted and recorded rather than
papered over.

**Full suite vs a FRESHLY DERIVED baseline.** The plan's original baseline (surefire 6711, failsafe
447 at `9f600e52`) went stale — develop moved 9 commits during implementation, adding 14 surefire and
9 failsafe tests. Comparing against it would have shown a phantom +23. The baseline was therefore
re-derived on this branch's own merge base, in its own worktree:

| | baseline @ `f02fc805` | branch @ `b5b81926` | delta |
|---|---|---|---|
| surefire | 6725 / **0 fail** / **0 err** / 1 skip | 6728 / **0 fail** / **0 err** / 1 skip | +3 tests |
| failsafe | 456 / **0 fail** / **0 err** / 31 skip | 461 / **0 fail** / **0 err** / 31 skip | +5 tests |
| build | BUILD SUCCESS | BUILD SUCCESS | — |

Both deltas reconcile exactly: +21 new unit tests less the ~19 deleted with `OptimisticLockRetry`'s
two test classes (its retry test replaced one-for-one), and +5 new IT methods. **Failures are the
comparable quantity and both are zero.**

**AC-5 was mutation-checked by hand**, because PIT cannot generate an "add an annotation" mutant:
adding `@Transactional` to `MobilePalletizingService` turns `MobilePalletizeRollbackIT` red with a
message naming D3. Restored byte-identically and re-verified green.

### 10.4 Review

Three independent lanes, reports in `.claude/worktrees/_reports/SBDEV-3398/`:
`lane-conformance.md` (**PASS**), `lane-codereview.md` (1 High / 4 Medium / 9 Low),
`lane-security.md` (0 High / 1 Medium / 3 Low). **Everything at every severity was fixed**, except the
lock-timeout item, which is an owner decision (§9 OQ1).

**Round two — the fixes themselves were reviewed.** The first three lanes graded the original
implementation only; the two commits carrying the fixes (+625/-218 across 18 files) had had no pass,
which matters because the H1 fix changed behaviour covered by the ACs. Two further lanes ran against
that delta: `lane-reconform.md` (**PASS** — no previously-passing criterion broken; §3.2 lock order and
§3.1 first-touch re-graded in full and VERIFIED in both methods, all three earlier gaps confirmed
closed) and `lane-rereview.md`. The re-check also corrected **two false claims of my own**: the
`lockContention` javadoc said an untranslated `PessimisticLockingFailureException` becomes "an HTTP
500 with no message", when `RestExceptionHandler` in fact maps it to **409** with a retry message
(the translation's real justification is the response SHAPE the handheld renders, not the status
code); and the targeted-test count was double-counted, as noted above.

**The High is the one worth remembering, and it means §3.3 B1 of this plan was wrong** — corrected in
place above rather than only in the code. The mint branch could proceed on an **unlocked** pallet row:
`unitloadService.createUnitload(String name, …)` is a find-or-create over an unlocked
`findByLabelid`, and a `SELECT … FOR UPDATE` matching **zero rows takes no lock**, so nothing
serialised the window between the miss and the insert. A racing session's row came back unlocked —
hop 1 of this plan's own lock order silently absent — and the pallet-type check was skipped on the
strength of "our mint branch ran", so a concurrently created Tote could have been accepted as a
carrier. Desktop's "Fix E" had it right all along and this plan's deliberate divergence from it was
the defect.

### 10.5 Landmines found during implementation that the plan did not predict

1. **A `@Transactional` bean cannot be stubbed with `@MockitoSpyBean`.** Spring re-proxies the spy, so
   `doThrow(...).when(spy).transferUnitLoadToCarrier(...)` runs through
   `CglibAopProxy → TransactionInterceptor` and opens a real transaction *during stubbing*, giving
   `CannotCreateTransactionException` + `UnfinishedStubbingException`. AC-2 therefore injects a
   **natural** failure — a parcel type with `onotherunitloadallowed = false` — which is better
   evidence anyway.
2. **`createUnitload(String, Location, Long, Long, String)` does not declare
   `throws BusinessException`**, so a checked throw from a spy answer returns as
   `UndeclaredThrowableException`. AC-12's injected failure is unchecked as a result, so AC-12 is
   killed by removing `@Transactional` but **not** by removing `rollbackFor`; the latter is pinned by
   AC-2 alone.
3. **`TestClassTransactionManagerArchTest` fired, correctly.** All three new `NOT_SUPPORTED` ITs commit
   fixtures that outlive the test. Registered with justifications and given FK-ordered cleanup — and
   `MobilePalletizeRaceIT` needed a sweep by the **unique keys** (`customerorder.externalnumber`,
   batch number), not by ids, because it runs against the *reused* Testcontainers container where its
   fixed labels would collide on the next build.
4. **The ArchUnit freeze store shrank by two entries** — rewriting `scanParcelBulk` removed two
   unguarded `Optional.get()` calls. Tightening, so committed.
5. **Verify scripts want the SUB-REPO root.** Run with no `PROJECT_ROOT`, the archived
   `verify-260610-*.sh` grades the main checkout and reports a clean 20/0/3 that says nothing. Pointed
   at this worktree it reports 18/2/3, the two reds being exactly the rows §4.2 predicted would invert.

### 10.6 Docs updated (D5)

`wms2-transaction-osiv-boundary-map.md` (§8.3 rewritten as a retirement record + the §5 post-commit
table row removed), `wms2-stockunit-design.md`, `wms2-cancel-cascade-workflow.md`,
`wms1-transaction-boundary-map.md`, `_symptom-index.md`, the 260610 audit report, and
`verify-260610-*.sh` annotated as retired with both measured runs. In the wms2-api repo itself:
`docs/plan/WMS_API_Problem_Areas_Analysis_And_Refactoring_Plan.md` and
`docs/plan/partial/WMS_V2_Horizontal_Scaling_Concurrency_Report.md`, both of which still recommended
*adopting* the deleted utility. Historical/dated references and archived plans left as accurate records
of a decision correct at its date.

### 10.7 Not done, by design

- **PR not opened, nothing pushed, ClickUp not moved** — awaiting the Phase 6 checkpoint.
- **`wms.tenant.lock-timeout-ms` unchanged at 10000** — §9 OQ1, owner decision.
- **Truck loading untouched** — [SBDEV-3418](https://app.clickup.com/t/868m6hue5).
