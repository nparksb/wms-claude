---
title: "Mobile truck loading — transaction boundary and row locking"
ticket: "SBDEV-3418"
ticket_url: "https://app.clickup.com/t/868m6hue5"
type: "bugfix"
priority: "high"
status: "on dev"   # MERGED to develop 2026-09-22 as 20478809 (PR #397). AC-2/AC-4/AC-7 struck and carried by SBDEV-3465.
project: ["wms2"]
version: "v2"
requester: "Nam Park"
created: "2026-09-22"
updated: "2026-09-22"
db_verified: true
base_commit: "b87ec747"   # ⚠ REBASED TWICE on 2026-09-22: f2ee75f1 → 3214a9c3 (SBDEV-3452, inverted P6 — see §5.3) → b87ec747 (14 SBDEV-3410 P2/P4 commits; no overlap with the mobile package, clean rebase)
related:
  - "[[SBDEV-3398-mobile-palletize-transaction-boundary]]"
  - "[[SBDEV-3419]]"
  - "[[SBDEV-3244]]"
  - "[[SBDEV-3250]]"
  - "[[SBDEV-3267]]"
  - "[[SBDEV-3442]]"
  - "[[SBDEV-3458]]"   # filed from this ticket: the leaking ParcelMonitor IT fixture
  - "[[SBDEV-3465]]"   # carries the struck AC-2 / AC-4 / AC-7
tags:
  - plan
  - wms2
  - concurrency
  - transaction-boundary
---

# Mobile truck loading — transaction boundary and row locking

> **This plan does not restate the upstream analysis.** What it would otherwise repeat already exists in
> [[SBDEV-3398-mobile-palletize-transaction-boundary]] §4.4 (the P0 detail section, retained there
> precisely so this ticket could point at it) and in `MobilePalletizeWriteService`'s class javadoc
> on `origin/develop` (the canonical lock order as SBDEV-3419 shipped it). **Read both before
> implementing.** This document carries only what those two do *not* settle, plus the corrections
> measured on 2026-09-22 — three of which contradict the ticket description.
>
> Raw evidence: `SBDEV-3418-evidence/` — `db-field-evidence.md`, `laneA-finders-and-writes.md`,
> `laneB-test-surface.md`, `arch-target-sequence.md`.

**Tier: T3** (data integrity · transaction boundary · lock ordering · multi-path coordination).
Confirmed by triage 2026-09-22, matching the ticket's own assessment.

---

## 1. Problem Statement

`MobileTruckLoadingService.scanGate` carries **zero** `@Transactional` and takes **zero** row locks.
Across roughly seventy lines it writes a BOL header, N BOL positions at three nesting levels, and a
customer-order state — each `save()` in its own `SimpleJpaRepository` transaction, committing
independently.

Two consequences, and they are different in kind:

1. **Non-atomicity.** Any failure part-way through leaves a durable, partially-built BOL. Measured
   under today's code: **2** childless top-level positions on Hydra UAT, which rode through to
   `CLOSED` and onto the manifest (§1.1). 8 exist all-time, but the older 6 predate a March-2025
   rewrite of this path and must not be counted against it.
2. **No serialisation.** Concurrent scans against the same BOL or the same pallet interleave freely.

**What is NOT in scope, despite appearing in the ticket:** the duplicate position numbers. They are a
count-vs-max defect in a *shared* service, not a concurrency defect, so the boundary does not close
them — but note that §1.2's original *evidence* for this has been **withdrawn**, and the defect's
measured exposure under today's code is zero. It stays out of scope; it is no longer a priority.

### 1.1 Field evidence — re-measured 2026-09-22, both tenants, with positive controls

| tenant | duplicate `(billoflading_id, number)` groups | childless top-level positions | positive control |
|---|---|---|---|
| Hydra UAT | 4 (8 rows) | 8 | 28,329 rows / 996 BOLs / 1,060 top-level — all non-zero |
| Hydra prd | 0 | 0 | 671 rows / 37 BOLs / 41 top-level — all non-zero |

Reproduces the ticket's figures exactly (prd has grown 663 → 671 rows since filing, same 37 BOLs).

⚠ **Those all-time figures are the wrong denominator, and an AC must not be written against them.**

The numbering and cleanup code in this path was rewritten in March 2025 (§1.2). Counts spanning the
whole table therefore mix epochs. Cut on the code, not on the calendar:

| defect | all-time | **under today's code** (positions created ≥ 2025-03-26) |
|---|---|---|
| duplicate `(billoflading_id, number)` groups | 4 (8 rows), all 2023-08 / 2024-02 | **0** |
| childless top-level positions | 8 | **2** — `2371386` (2025-07-31) and `2488077` (2025-09-05) |

The 2 survivors are the honest live evidence for this ticket, and only one of them is cleanly a
partial write: `2488077` is `-000000`, i.e. its BOL's first position, with 9 siblings created over
the following 4.5 minutes and no children. `2371386` is `OBOL001369-000033` and is now the **only**
row on its BOL, so 32 siblings existed when it was created and were later removed wholesale — that
reads as a deleted-BOL remnant, not a partial write. An earlier draft of the evidence file called
`2371386` one of "the strongest cases"; that reading is inverted.

- **prd has never produced one** in any epoch. 0 of 41 top-level positions, 0 of 37 BOLs; prd volume
  on this path is ~1.6% of UAT's.
- **An AC of the form "this count stays at zero" is ungradeable** — it already passes against the
  unfixed code.

*⚠ An earlier draft justified the low recent rate with "nothing changed in this code". That is
false: four commits changed exactly this code in March 2025, one of them (`6edf3d12`) titled
"fixed OBOL numbering changes and BOL positions left undeleted when pallet is moved back to
Palletizing location from truck loading" — i.e. the childless-position symptom itself. The
statistical point may still stand; that justification for it does not.*

#### Where the 2025-03-26 cut-off comes from — it is measured, not picked

Classifying every BOL on Hydra UAT by the suffix of its lowest-id position yields three cleanly
time-separated numbering epochs:

| first position's suffix | BOLs | first seen | last seen |
|---|---|---|---|
| `-000001` | 668 | 2021-08-26 | 2025-02-27 |
| no suffix at all (e.g. `OBOL000950`) | 21 | 2025-03-03 | 2025-05-12 |
| `-000000` | 306 | **2025-03-26** | 2026-07-10 |
| `-000033` | 1 | 2025-07-31 | 2025-07-31 |

The middle band is the pre-`cd28153f` implementation, which used a global sequence
(`basicService.generateNumber(...)`) rather than a per-BOL count. `2025-03-26` is the first row
produced by the numbering code that is in the tree today, which is why it is the denominator
boundary.

**The fourth row is row `2371386`, and it independently corroborates the deleted-BOL-remnant
reading above.** Its BOL's *lowest-id surviving* position is numbered `-000033`, so 33 positions
were issued on that BOL before it and none of them survive. That is wholesale removal, not a
partial write — which is what disqualifies it as evidence for this ticket, and it is why the live
count is better read as **1** clean case than 2.

#### Provenance — re-measured 2026-09-22 after Hydra UAT came back

Every figure in §1.1 is now my own measurement. The epoch table above and the denominators below
were briefly attributed to the review lane while UAT was refusing connections; **both have since
been re-run independently and reproduce exactly.**

| epoch-restricted (created ≥ 2025-03-26) | value |
|---|---|
| positions (control) | 7,403 |
| distinct BOLs (control) | 309 |
| top-level positions (control) | 313 |
| pre-epoch rows excluded (control that the filter is not matching everything) | 20,926 |
| **duplicate `(billoflading_id, number)` groups** | **0** |
| **childless top-level positions** | **2** — `2371386 OBOL001369-000033`, `2488077 OBOL001402-000000` |

All four controls are non-zero, so the two zeros/twos are true values rather than a broken filter.
The two childless row ids match the ones derived independently from the all-time query.

### 1.2 ⚠ The duplicate numbers are out of scope — but NOT for the reason an earlier draft gave

> **⚠ WITHDRAWN 2026-09-22, by the independent review lane, and the withdrawal is recorded rather
> than deleted because the retracted argument was published on the ticket.**
>
> An earlier draft of this section derived `number = size() + 1` and fitted a six-row arithmetic
> model to the 2024 duplicate rows, concluding that the collisions were caused by
> `handleTruckOffLoading` shrinking the count. **Two independent errors, both confirmed against
> `origin/develop`:**
>
> 1. **The formula is wrong.** `BasicService.generatePositionNumber` is
>    `String.format(prefix + getFormat(), positionIndex)` with `getFormat()` returning `"%1$06d"` —
>    **there is no `+1`**. The sibling two methods above makes the contrast unmistakable:
>    `generateOrderNumber` does `String.format(prefix + getFormat(), customerOrders.size() + 1)`.
>    `createEntity` passes `bolPositions.size()` unmodified, so `number = size()` and a BOL's first
>    position is `-000000`. The evidence file already contained a counterexample I did not follow
>    up — row `2488077`, numbered `OBOL001402-000000`, which is unreachable under `size()+1`.
> 2. **The data predates the code by 13 months.** The rows are from **2023-08-17** and
>    **2024-02-19**. This repository's first commit is `a685e07b` *"initial checkin the code"*,
>    **2024-07-16**. The `size()`-based numbering arrived in `cd28153f` (**2025-03-18**) and
>    `handleTruckOffLoading` in `6edf3d12` / `839d7f8d` (**2025-03-21 / 03-24**).
>
> So the model was fitted, not derived — it has a free parameter and is equally consistent at two
> different phantom-row counts — and it attributed 2024 rows to code that did not exist until 2025.
> **The paragraph in §2 Bug 3 agonising over "which call site ran that cleanup" was an artifact of
> the same mismatch: in February 2024 neither candidate existed.**

**What survives.** The mechanism is still real *in today's code*: `createEntity` derives the number
from a live count, and `handleTruckOffLoading` deletes rows, so a delete followed by an insert
re-issues a burned number. Nothing about a transaction boundary changes that, because the writers
need not be concurrent.

```java
List<BillofladingPosition> bolPositions = billofladingPositionRepository.findByBillofladingId(billOfLading.getId());
String number = basicService.generatePositionNumber(billOfLading.getNumber(), bolPositions.size());
```

**What does not survive is the evidence.** Every duplicate group on Hydra UAT is from 2023-08 or
2024-02 — i.e. entirely within the pre-`cd28153f` epoch, produced by a numbering implementation that
is no longer in the tree. Under today's code the duplicate-number defect is **latent with no measured
exposure**, which is the same status §4.2.2 correctly assigns to the non-unique finders.

There is still no unique index to catch it: `(billoflading_id, number)` has no unique constraint on
Hydra prd (`pg_index`), so the database cannot reject a collision.

→ Out of scope either way (§4.2.1), but **demoted from "do first" to "latent"** — see §4.2.

#### Does the B1 BOL lock close it?

For the *concurrent* variant, yes as a side effect: two `scanGate`s on one BOL now serialise before
either counts. ⚠ **This is why B1 is load-bearing even when the header is unchanged** — do not weaken
it to an unlocked read on the grounds that "`scanGate` sometimes doesn't mutate the BOL". It does
**not** close the sequential delete-then-insert variant, and it does not close it against any other
producer of positions for the same BOL that does not take the BOL lock; those producers were not
enumerated.

### 1.3 ⚠ The lesson worth keeping from §1.2's withdrawal

**Date your evidence against the history of the code you are attributing it to.** Nothing in the
original derivation was arithmetically wrong; it fitted every observed number. It was wrong because
the rows and the code come from different epochs, and no amount of internal consistency detects
that. The check is one `git log -S'<symbol>' --date=short` per cited symbol, and it costs seconds.

This compounds with a second-order effect: a fitted model with a free parameter will *always* find a
consistent assignment, so "every number is accounted for" felt like confirmation when it was only
curve-fitting. **A model that cannot fail to fit is not evidence.**

*Instrument note carried over: the `id` gaps were never used as evidence — `pg_sequences` shows this
schema allocates from a shared sequence (`seqentities`), so a gap in one table's ids may be ids
consumed by another.*

---

## 2. Root Cause Analysis

### Bug 1 — no transaction boundary

`scanGate` is not `@Transactional`. With `spring.jpa.open-in-view=false` (set in
`src/main/resources/application.properties`, in both test integration profiles, and rail-pinned by
`SdrEvictionPostCommitAssumptionUnitTest` AC-27), every repository call opens and commits its own
transaction and every returned entity is detached the moment the call returns.

### Bug 2 — no row locks

No locking finder is called anywhere in `scanGate`. The pallet is resolved with `findByLabelid`, the
BOL with `findByName`, the parcels with `findByCarrierunitloadId`, the orders with
`getByParcelIdList` — all plain reads.

### Bug 3 — `handleTruckOffLoading`'s two deletes are not atomic with each other

Reached from `scanGate`, `deleteBolPositionsCarrierIds` and `deleteBolPositionById` each open their
own transaction (both carry Spring's `@Transactional` with default `REQUIRED`, and no caller
transaction is open). The first can commit while the second does not.

> **⚠ The 2024 worked example that used to sit here is WITHDRAWN (2026-09-22).** It traced the
> childless row `987527` to `deleteBolPositionsCarrierIds` committing while `deleteBolPositionById`
> did not, and then flagged as an open mystery that neither call site seemed to explain it. Both the
> attribution and the mystery were artifacts of the epoch error in §1.2: the row is from
> **2024-02-19** and all three symbols were committed in **March 2025**. In February 2024 neither
> call site existed. Recorded rather than deleted because the argument was published on the ticket.

**The mechanism above is a property of today's code and needs no historical row to support it** —
two `@Transactional(REQUIRED)` deletes reached from a caller with no open transaction is two
transactions, by construction. The live evidence for the *outcome* is the 2 post-March-2025 childless
rows in §1.1, of which one (`2488077`) has a clean partial-write shape.

Whether those 2 rows were produced by *this* mechanism specifically is **not established**, and does
not need to be before starting: every candidate mechanism in this section is closed by the same
boundary. AC-4's integration test is the right place to settle it if anyone wants it settled.

### Bug 4 — adding `@Transactional` naively CREATES a new defect

Both deletes are `@Modifying(clearAutomatically = true)` with no `flushAutomatically`, so each issues
`EntityManager.clear()` after executing — detaching **every** managed entity, not just
`BillofladingPosition` ones.

Today that is harmless, because there are no pending writes to lose (Bug 1). **Under a boundary it is
not.** At the current call position, `handleTruckOffLoading` runs after the BOL header update and
after `unitloadBusinessService.transferUnitLoadToLocation(...)`, whose writes would then be pending —
and that method saves the pallet **and recursively every child parcel** (`processTransfer` walks
`findByCarrierunitloadId` under an SBDEV-3091 `visited` guard, saving each).

⚠ **The exposure is wider than the ticket states.** The ticket scopes the hazard to the single
`UPDATE billoflading`. It is the whole pending write set from the header update *and* from
`transferUnitLoadToLocation`'s recursive pallet-plus-children saves.

#### Bug 4a — the competing hypothesis, and why it must be measured rather than reasoned about

`handleTruckOffLoading`'s first statement is `findBolIdByUnitLoadLabelId`, which is
`nativeQuery = true`. Hibernate cannot compute query spaces for a native query with no declared
synchronized spaces, so under `FlushMode.AUTO` it may flush the **entire** persistence context before
executing — in which case the pending writes are already durable and nothing is lost.

Both outcomes are plausible and the ticket is explicit that this must be proven by test. **Two things
are true either way, and they are the residual defect:**

1. **Identity split.** `clear()` detaches regardless of whether it flushed first. Everything read
   before it — the BOL, the pallet — becomes detached, so a later `save()` on it is a `merge`:
   SELECT plus UPDATE against a **new** managed instance, while the stale instance is still
   reachable in local variables. Mutating the stale one after that point writes over the fresh one.
2. **The call is still non-atomic with the rest of the method** unless it is inside the boundary.

⚠ **What the clear does NOT do — corrected during review, and the correction matters.** An earlier
draft of this plan said the merge's fresh SELECT "defeats any lock taken before the clear". **That is
wrong.** A `SELECT … FOR UPDATE` row lock is held by the *database transaction* and is released only
at COMMIT or ROLLBACK. `EntityManager.clear()` acts on the JPA persistence context — it issues no
SQL, touches no connection state, and cannot release a PostgreSQL row lock. After the clear the
transaction still holds every lock it took, no other session can have modified those rows, and the
merge reads exactly the values we locked.

The direction of the effect is in fact the opposite: post-clear, a `findByIdForUpdate` on an
already-locked row is a *fresh* read rather than an upgrade, so no version check runs and it cannot
throw. **The first-touch rule is satisfied again on the far side of a clear.**

This is recorded rather than quietly deleted because the wrong version invites a reviewer to demand
lock re-acquisition after D0 — up to ~142 extra round-trips that buy nothing (⚠ SBDEV-3470 correction: the real max on an order-bearing pallet today is 28 B3+B5 acquisitions, a property of the data, not a bound; the ~142 figure was 1 + 1 + 70 children + up to 70 orders, but the 70-child pallets are inbound with no orders, so on them the scan takes 72 acquisitions and PHASE C rejects it; the 88 stockunits quoted alongside belong to a different pallet, were not part of the sum, and are not locked; see item 6). The two real hazards
are **lost unflushed writes** and the **identity split**, and the mitigation for both is C-9 (no
mutation above D0), not re-locking.

**Moving `handleTruckOffLoading` to the front resolves all of it and is correct under both
hypotheses.** The measurement still matters — see AC-4 — because it decides whether the guard test is
asserting "the write survives" or "the write was never at risk", and a green there must not be
misread as a broken test.

### Bug 5 — the OMS notification cannot stay inside the boundary

`ManageOrderService.customerOrderLoadedToTruck` does repository work (`createOrderBatch`,
`addOrderToOrderBatch`, `unitloadRepository.findById` per order) *before* it reaches
`omsNotificationService.sendAfterCommit`. Inside an open boundary, a repository failure there marks
the session rollback-only; the existing `catch (Exception e)` at the call site swallows it and cannot
undo the marking; the transaction then dies at commit with `UnexpectedRollbackException`. That
surfaces through `TruckLoadingController.scanGate`, which catches only `BusinessException` and
`FacadeException` — so it escapes as a raw HTTP 500 with no operator-legible message.

This is SBDEV-3398 decision D3, and it is why the outer/inner split in §3 is not optional.

### Bug 6 — ⚠ every validation read in `scanGate` becomes a first-touch violation the moment a boundary exists

**This is the bug that will pass every test.** State it as the invariant, not as a list of sites:

> Once `scanGate` runs inside one persistence context, **any row it materialises during validation
> and later locks is a lock UPGRADE, not an acquisition.** Hibernate version-checks on upgrade and
> throws `StaleObjectStateException` from inside the repository call, marking the transaction
> rollback-only. Uncontended it throws nothing — so the whole class of defect is invisible to any
> test that does not reproduce the race.

Today none of these are violations, because with `spring.jpa.open-in-view=false` and no boundary each
repository call gets its own context and each returned entity is immediately detached. **Adding
`@Transactional` creates all of them at once.**

Enumerated against `origin/develop` so the design has a checklist — but fix the rule, not the list:

| read site in `scanGate` today | row class | later locked? |
|---|---|---|
| `unitloadRepository.findByLabelid(palletName)` | Unitload (pallet) | yes — the pallet lock |
| `billofladingRepository.findByName(selectedBOLName)` | Billoflading | yes — the BOL lock |
| `locationRepository.findByName(scannedGateName)` | Location (gate) | **yes, and not by us** — see below |
| `unitloadRepository.findByCarrierunitloadId(pallet.getId())` | Unitload (parcels) | yes — the parcel locks |
| `customerorderRepository.getByParcelIdList(parcelIds)` | Customerorder | yes — the order locks |
| `stockunitRepository.findByUnitloadId(parcel.getId())` | Stockunit | yes, if the design locks stock |
| `customerorderPositionRepository.findByOrderId(order.getId())` | CustomerorderPosition | yes, if the design locks positions |

#### 6a — the gate Location is the non-obvious one, because WE do not take that lock

`scanGate` calls `transferUnitLoadToLocation(pallet, gate, false, …)` — **`ignoreLock = false`**. That
argument gates exactly one thing, and the method's own javadoc says so: *"`ignoreLock` gates exactly
one check in this method: the DESTINATION location's lock."* Inside:

```java
if (!ignoreLock) {
    final Long destinationLocationId = destinationLocation.getId();
    destinationLocation = locationRepository.findByIdForUpdate(destinationLocationId)
        .orElseThrow(() -> new EntityNotFoundException("Location", destinationLocationId));
    entityManager.refresh(destinationLocation);
}
```

So a `PESSIMISTIC_WRITE` lock **is** taken on the gate row — by a collaborator, on an entity
`scanGate` already materialised at `locationRepository.findByName(...)`. Under a boundary that is a
textbook upgrade. It is easy to miss because no locking finder appears anywhere in `scanGate`'s own
source.

**Design consequence:** resolve the gate by a scalar id projection during validation and let
`transferUnitLoadToLocation`'s `findByIdForUpdate` be the Location row's first touch. The gate's
`name` is needed for the equality check and the mismatch message — the check can run off the id, and
the mismatch branch may materialise freely because it throws.

⚠ **`Location` is also a lock class the canonical table order does not place**, alongside
`billoflading_position`. Two unranked hops, not one. Say so in the javadoc rather than implying the
order is complete.

*Aside, out of scope: `entityManager.refresh(destinationLocation)` at that site is one of the known
backwards refresh-after-lock instances — if the locking read throws, the refresh never runs. Not this
ticket's to fix; do not copy the pattern.*

### Bug 7 — `PessimisticLockingFailureException` has nowhere to land

`TruckLoadingController.scanGate` catches `BusinessException` and `FacadeException` and returns
**HTTP 200** with an `errors` map. It does not catch `PessimisticLockingFailureException`. Once
locks exist, a lock timeout (`wms.tenant.lock-timeout-ms`, applied as `SET LOCAL lock_timeout` per
acquisition) surfaces as a 409 from `RestExceptionHandler` (@Order(0), unscoped), NOT a 500 — an earlier draft of this plan said 500 and was wrong. The outer service translates it to the 200+`errors` shape the handheld renders, exactly as
`MobilePalletizingService.lockContention` does — and must do so **outside** the boundary, because
catching it inside leaves the transaction rollback-only.

### Affected locations

| file | what |
|---|---|
| `service/mobile/MobileTruckLoadingService.java` | `scanGate` — the whole method; becomes the non-transactional outer service |
| `service/mobile/MobileTruckLoadingWriteService.java` | **new** — the boundary, the locks, the write sequence |
| `service/mobile/MobileMoveUnitloadService.java` | `handleTruckOffLoading` — reached inside the new boundary |
| `repo/jpa/BillofladingRepository.java` | new id projection by name |
| `repo/jpa/UnitloadRepository.java` | new id projection — child parcel ids by pallet id, ordered. ⚠ NOT a pallet-id-by-label projection: `existsByLabelid` + `findByLabelidForUpdate` already suffice |
| `repo/jpa/LocationRepository.java` | **new** — `findIdByName` (the Bug 6a fix) and `findNameById`. Omitted from an earlier draft of this table |
| `repo/jpa/CustomerorderRepository.java` | new `(parcelId, orderId)` projection + the `ParcelOrderIdView` interface |
| ~~`repo/jpa/StockunitRepository.java`~~ | **not touched.** B4 reads stockunits unlocked, so no projection is needed |
| `controller/mobile/TruckLoadingController.java` | unchanged — see Bug 7; the translation happens in the outer service |

---

## 3. Design / Proposed Fix

Full derivation, with the per-constraint failure modes and the `closeBOL` statement walk:
`SBDEV-3418-evidence/arch-target-sequence.md`.

### 3.0 Settled constraints — do not relitigate in review

1. **The canonical TABLE lock order is SBDEV-3419's, not the one in this ticket's description.**

   ```
   Billoflading → Unitload (pallet, then parcels asc by PARCEL id) → Stockunit
                → Customerorder asc → CustomerorderPosition
   ```

   ⚠ The ClickUp description still quotes the **withdrawn** order
   (`BOL → UL(pallet) → CO asc → UL(parcels, in CO order)`), which was superseded 2026-09-18.
   Implementing it verbatim re-creates the `(unitload, customerorder)` ABBA that SBDEV-3419 — now
   `on prod` — exists to close, i.e. exactly the failure that caused this ticket to be unbundled from
   SBDEV-3398 in the first place. The order above is derived from `closeBOL`'s **measured** `pg_locks`
   order, not from source read order, and is carried verbatim in `MobilePalletizeWriteService`'s
   class javadoc.

   Two caveats ride with it, both already recorded there and **neither closed by SBDEV-3419**:
   it is a *table* order and does not order rows within the `unitload` set (`closeBOL`'s bulk UPDATE
   carries no `ORDER BY`, its measured plan is a Bitmap Heap Scan, and 27.32% of 480,334
   (pallet, child) pairs have the child physically ahead of its pallet — and a JPQL bulk UPDATE
   cannot carry an `ORDER BY`, so the remedy is a locked pre-pass or native SQL); and
   `billoflading_position` is a class the order does not place at all, so any hop that touches it is
   **unranked rather than proven safe**. "Joined the order" does not mean "cycle-free".

2. **The first-touch rule (SBDEV-3244).** Each row's locking finder must be that row's FIRST touch in
   the transaction. A `@Lock(PESSIMISTIC_WRITE)` re-read of an already-managed entity is a lock
   *upgrade*; Hibernate version-checks on upgrade and throws `StaleObjectStateException` from inside
   the repository call, marking the transaction rollback-only itself. Uncontended it throws nothing,
   **so every test that does not reproduce the race is green either way.** The remedy is scalar id
   projections (a query returning `Long` / `List<Long>` / `boolean` creates no `EntityEntry`).
   `entityManager.refresh(e, lockMode)` is **not** an alternative — `ReplenishorderRepository` records
   that the throw happens inside the repository call, before any later `refresh` could run.

3. **The outer/inner service split**, mirroring `MobilePalletizingService` / `MobilePalletizeWriteService`.

4. **The OMS notification goes outside the boundary** (D3, and Bug 5 above).

### 3.1 What has to be added — measured, not estimated

The description says the restructure needs "scalar id projections … and possibly a multi-row locked
customer-order finder".

⚠ **This section has been wrong twice, in opposite directions. What was actually built (verified
against `git diff origin/develop e64bdb5c -- repo/`) is FIVE projections plus two no-clear deletes
plus one projection interface:**

| method | repository | phase | why |
|---|---|---|---|
| `findIdByName` | `Billoflading` | A4 | BOL id without materialising the entity |
| `findIdByName` | `Location` | A6 | gate id — the Bug 6a fix |
| `findNameById` | `Location` | C1 | the mismatch message, without a second entity |
| `findIdsByCarrierunitloadIdOrderById` | `Unitload` | B3 | child parcel ids, ordered in the QUERY |
| `findParcelOrderIdsByParcelIdIn` → `ParcelOrderIdView` | `Customerorder` | B5 | (parcel, order) pairs as scalars |
| `deleteBolPositionByIdNoClear` · `deleteBolPositionsCarrierIdsNoClear` | `BillofladingPosition` | D0 | the P6 outcome — see §5.3 |

**Two things an earlier draft listed as required turned out NOT to be:**

- *pallet id from label* — unnecessary. §3.2 A probes with the pre-existing `existsByLabelid` and B2
  locks with the pre-existing `findByLabelidForUpdate`, so no pallet-id projection is ever used.
- *stockunit ids from unitload id* — unnecessary. §3.2 B4 reads stockunits UNLOCKED, so there is
  nothing to keep untouched. `StockunitRepository` is not modified by this change at all.

**And NO locked finders were added, because none were needed.** All eight the sequence uses already
exist on develop. The description's "possibly a multi-row locked customer-order finder" is not
required either: B5 loops `findByIdForUpdate` over a sorted id list, which is the pinned
`ParcelMonitorViewService` idiom. Its cost is §4.3 residual 6.

*⚠ §2's "Affected locations" table is the stale one and disagrees with this: it names five
projections including the two that proved unnecessary, and omits `LocationRepository` entirely
even though §3.2 A depends on it. **This table is authoritative; §2's is not.** An auditor reading
§2 would look for five, find three of them, and report a phantom gap.*

*Derivation and blind spot: full-file reads of all six repository interfaces plus
`ReplenishorderRepository`, not keyword grep, so these are exhaustive over each file's declared
methods. Blind spot: a method added on an unmerged branch would not appear.*

### 3.2 Target statement sequence

New class `MobileTruckLoadingWriteService`, annotated exactly as its palletize counterpart:
`@Transactional(value = "tenantTransactionManager", rollbackFor = {BusinessException.class, FacadeException.class})`.
`MobileTruckLoadingService` keeps every read-only method it has today and becomes the
non-transactional outer caller for `scanGate` only.

| phase | what happens | why here |
|---|---|---|
| **A — validate, resolve ids** | `existsByLabelid(palletLabel)` · **new** `findIdByName` on BOL · **new** `findIdByName` on Location · `userRepository.findByName(...)` | **Scalar reads only.** No `EntityEntry`, so nothing in B is an upgrade. The pallet probe stays *ahead* of the BOL resolution to preserve the operator-visible message order — same precedent and same justification as `MobilePalletizeWriteService`'s A3. `User` is an entity touch but nothing locks `User`, so it is harmless |
| **B — acquire locks, canonical order** | B1 `billofladingRepository.findByIdForUpdate(bolId)` · B2 `unitloadRepository.findByLabelidForUpdate(palletLabel)` · B3 **new** `findIdsByCarrierunitloadId` → sort asc → loop `findByIdForUpdate` · B4 stockunits read **unlocked** at the canonical position · B5 **new** `findParcelOrderIdsByParcelIdIn` → distinct, sort asc → loop `findByIdForUpdate` · B6 order positions read **unlocked**, once per order | The table order of §3.0. B4/B6 read unlocked but **at the position where a lock would go**, so adding one later needs no resequencing. B6 also removes an N+1 — develop calls `findByOrderId` once per *stockunit* |
| **C — guards, predicates only** | gate reconciliation · BOL state validation · orphan-parcel check · duplicate-order-per-parcel check | **No mutation.** Develop mutates inside the state switch and raises the orphan/duplicate errors *mid-write-loop*, after positions have already been saved. Moving them here is what makes D0 safe (C-9) |
| **D0 — stale-position purge** | `handleTruckOffLoading(palletLabel)` | The persistence-context barrier. See below |
| **D — writes** | D1 apply pending BOL state/gate, save · D2 `transferUnitLoadToLocation(pallet, gate, false, …)` — its OWN inner `findByIdForUpdate` is the Location row's **first entity touch** · D4–D6 position tree, parcels iterated in **asc parcel-id** order · D7 order states · D8 build the outcome record from the instances in hand **at the end of D** | Everything locked, every guard passed. ⚠ Do **not** add a `locationRepository.findByIdForUpdate(gateId)` of our own here — with A6's scalar projection the gate has no `EntityEntry`, so the inner lock is already an acquisition. See Bug 6a |
| **E — outer service, no transaction** | catch `PessimisticLockingFailureException` → operator-legible `BusinessException`; then the OMS notification in its existing `try/catch` | Both must be outside: catching contention inside leaves the transaction rollback-only (Bug 7); the notification does repository work that would mark it rollback-only (Bug 5) |

#### ⚠ D0's position is a choice among unrankable options, not a safe placement

**Front placement — what the ticket prescribes — is wrong and should be rejected.** It satisfies the
first-touch rule trivially (an empty context clears nothing), but it puts `billoflading_position` row
locks *ahead of* the `Billoflading` header lock, and it runs a destructive DELETE before any guard
has passed — the exact shape SBDEV-3398 exists to remove.

Reading `closeBOL` top to bottom, it touches `billoflading_position` at **two** points with different
neighbours: a bulk JPQL `DELETE … WHERE bp.id IN :garbageIds` between the `Billoflading` lock and the
`Unitload` bulk update, and again at commit flush after `Customerorder`. So:

- **front placement** ⇒ `scanGate` holds `bolpos(P)`, waits for `Billoflading(X)`; `closeBOL` holds
  `Billoflading(X)`, waits for `bolpos(P)`. A cycle, visible from source, no measurement needed.
- **D0 placement** ⇒ `scanGate` holds `Unitload`/`Customerorder`, waits for `bolpos`; `closeBOL` can
  hold `bolpos` and want `Unitload`. Also a cycle.

⚠ **Both cycles require the two sessions to be on DIFFERENT BOLs — say so, or the section reads as
wrong.** `scanGate`'s B1 and `closeBOL`'s first lock are both
`billofladingRepository.findByIdForUpdate(bolId)`, so on the *same* BOL they serialise on that row
and neither placement can cycle. The cross-BOL case is reachable, and is in fact the case
`handleTruckOffLoading` exists to serve: `findBolIdByUnitLoadLabelId` matches by **pallet label
across all BOLs**, so `scanGate`'s D0 can delete a stale position belonging to the BOL `closeBOL` is
closing. A reader who checks only the same-BOL case will find no cycle and conclude this analysis is
mistaken.

Both are cycles. D0 wins because it is the only placement that also satisfies "no mutation above the
clear", "purge before any `createEntity`" and "guards before destructive writes" — and because it
matches the pinned precedent, `MobilePalletizeWriteService`'s own `removeBOLPositionIfExists`
placement. **Say this in the javadoc. Do not write that the order is cycle-free.**

*Instrument note: that `closeBOL` walk is read from **source order**, not measured off `pg_locks`,
and its blind spot is exactly the flush-ordered steps, because Hibernate decides when those run.
`ClosebolLockOrderProbeIT` already measures this class of thing; extending it to record
`billoflading_position` acquisitions is the concrete next probe, and the only way to turn "two
source-visible positions" into a ranked fact.*

#### D0 must be before every `createEntity`, not merely early

`findBolIdByUnitLoadLabelId` matches `bp.source_id = pallet.id` — which is the pallet position D4
inserts — and `findBolCarrierIdListByUnitLoadLabelId` matches its children. Running the purge after
D4/D5 **deletes the position tree this very scan just built.**

#### Stop depending on the flush hypothesis at all

The sequence above is correct whether Bug 4a resolves true or false, because C-9 guarantees nothing
is pending at D0. But the cheaper structural fix is to change the two finders: **drop
`clearAutomatically` and add `flushAutomatically = true`**. `clearAutomatically` exists to evict
stale managed `BillofladingPosition` instances; if no caller holds one across the delete it is pure
cost and pure hazard. `flushAutomatically = true` is already precedented in this repo on six
`User*`/`UserGroup*` repositories.

⚠ **Required check before doing this, and it is not yet done:** confirm that
`MobileMoveUnitloadService.scanDestination` — the other caller — holds no managed
`BillofladingPosition` across its `handleTruckOffLoading(...)` call. One method read. If it does,
fall back to no-clear sibling methods used only by the new write service.

This is also the only option that fixes the **sibling exposure**: on `scanDestination` those deletes
already run inside an open transaction today, with pending unitload UPDATEs live at the clear. If the
flush hypothesis is false, that is a live silent-data-loss path on develop that moving `scanGate`'s
call does nothing about. See §4.2.3.

⚠ **One precedent looks like it contradicts this and does not — check it before a reviewer does.**
`UserRoleUserFunctionRepository` carries `@Modifying(flushAutomatically = true)` with a javadoc
saying *"`flushAutomatically = true` is a no-op under this shape … nothing is ever queued here"* and
*"Do not describe it as load-bearing"*. The stated condition is **nothing is ever queued**. Here
something is queued — that is the entire hazard — so the flag is load-bearing on this path, not a
no-op. The same javadoc independently reaches our conclusion about the other flag, in almost these
words: *"`clearAutomatically` is deliberately absent … There is no stale entity to evict, and
`em.clear()` would detach the ENTIRE persistence context and discard its pending changes: a caller
wrapping [it] in a larger tenant transaction would silently lose its own managed entities, invisibly
at every call site and invisibly to every mocked-repository test."*

**Leave the bare `@Transactional` on both deletes alone.** The same javadoc records the SBDEV-3250
correction that a bare `@Transactional` on a *repository interface* does **not** resolve to the
`@Primary` landlord manager — that hazard is real for a `@Service`, not here — and it names these
two methods as existing precedent for the bare form. `REQUIRED` merely joins the caller's
transaction; anything else (`REQUIRES_NEW`) would take a second connection and self-deadlock against
the locks the caller already holds.

---

## 4. Scope

### 4.1 In scope

- The boundary and the lock sequence on the truck-loading gate scan.
- Moving `handleTruckOffLoading` ahead of every pending write.
- The five id projections and whatever locked finders §3.2 settles.
- Translating `PessimisticLockingFailureException` into an operator-legible message (Bug 7).
- Keeping the OMS notification outside the boundary (Bug 5).

### 4.2 Out of scope — proposed, not filed

1. **Position numbers derived from `size()` rather than a high-water mark** (§1.2). Mechanism:
   `createEntity` counts live rows, `handleTruckOffLoading` deletes rows, so a delete-then-insert
   re-issues a burned number. Blast radius: `BillofladingPositionService.createEntity` is shared —
   every caller that creates a BOL position. No unique index backstops it.

   ⚠ **Demoted from "do first" to "latent" (2026-09-22).** An earlier draft ranked this first as
   "the only defect here with a proven, reproducible mechanism". That ranking was built on the
   withdrawn §1.2 derivation. Under today's numbering code the measured exposure is **zero
   duplicate groups**; the entire evidence base predates the March-2025 rewrite. The mechanism is
   real in the current tree, but its status is *latent with no measured exposure* — the same status
   as item 2 below, and it should be proposed alongside it rather than ahead of the work that has
   live evidence.
2. **`handleTruckOffLoading`'s non-unique finders.** `findBolIdByUnitLoadLabelId` returns a scalar
   `Long` (→ `IncorrectResultSizeDataAccessException` on >1 row) and
   `findBolCarrierIdListByUnitLoadLabelId` contains a scalar subquery (→ Postgres `21000`). Measured
   exposure today: **0** on both tenants — UAT 10,462 labels all with exactly 1 position, prd 233
   likewise, `max(rows per label) = 1` on both. Latent, not live. Recorded because it is the same
   defect class as the tote-reuse `Optional<>` failures.

   The activation condition is worth stating precisely, because it is not scan-rate-related: the
   query carries no `ORDER BY` and no `LIMIT` and spans **all** BOLs for that label, so what
   activates it is **a pallet re-used across two BOLs without cleanup** — the same shape as the
   tote-reuse family.
3. **`scanDestination` already runs `handleTruckOffLoading` inside a transaction on develop today**,
   so the pending-writes-meet-`clearAutomatically` interaction of Bug 4 already exists on that path,
   unmodified. Belongs on the existing open ticket [SBDEV-3442](https://app.clickup.com/t/868m6xy64),
   which already covers `scanDestination`. **Useful side effect: it makes Bug 4a measurable against
   unmodified develop** — see AC-4.
4. **Re-evaluating `checkPallet`'s BOL-position state guard inside `scanGate`** (C5, proposed).
   `checkPallet` and `scanGate` are two separate HTTP POSTs, so its verdict is check-then-act across
   a network round trip: an operator who reaches `scanGate` directly, or whose pallet acquired a
   `CLOSED` position between the two calls, bypasses it entirely. Blast radius: a behaviour change
   that can reject scans which succeed today. **Proposing, not filing.**
5. **Doc drift found in passing:** `ParcelMonitorViewServiceConcurrencyIT`'s javadoc says it "uses
   `BaseIntegrationTest` (H2 in-memory)"; it actually extends `BasePostgresIntegrationTest`. Free to
   correct.

### 4.3 Residuals this change does NOT close — state them in the javadoc, do not imply safety

1. **`billoflading_position` is unranked and cannot be ranked from source** (§3.2). Accepted on the
   same terms SBDEV-3419 accepted its `removeBOLPositionIfExists` hop: 40P01 →
   `PessimisticLockingFailureException` → operator-legible retry, not a 500.
2. **The unitload-vs-unitload cycle against `closeBOL` is untouched.** `closeBOL`'s bulk UPDATE
   carries no `ORDER BY`, its measured plan is a Bitmap Heap Scan, and 27.32% of 480,334
   (pallet, child) pairs are physically out of order. `scanGate` locking pallet-then-parcels
   inherits it exactly as `scanPallet` does.
3. **`Location` remains unranked.** Bug 6a fixes the *upgrade*, not the *ordering*. `closeBOL` takes
   no Location lock, so there is no cycle with it; cycles with other `transferUnitLoadToLocation`
   callers were not analysed.
4. **`Stockunit` and `CustomerorderPosition` are read unlocked**, so `billoflading_position.amount`
   and `.orderposition_id` are non-repeatable reads. Recommended as an accepted cost rather than
   paying ~88+N extra acquisitions — but ⚠ **that recommendation is not evidence-backed**: the
   writers of `stockunit.amount` for a packed parcel already at a gate were not enumerated. Named
   probe: grep the setters, plus a UAT query for stock movement on parcels carrying a
   `TRUCK_LOADING` BOL position.

   ⚠ If a real writer exists, the locked finder must **replace** B4/B6's unlocked read, not be added
   before or after it. B4/B6 materialise entities, so leaving the plain read in place and adding a
   lock alongside it is a first-touch violation — Bug 6, exactly. The sequence is correct
   *positionally*; the swap is still not a one-line substitution.

5. **`transferUnitLoadToLocation` touches three rows outside the plan's lock set**, all benign, all
   worth naming in the javadoc rather than discovering later:
   `unitloadRepository.findById(carrierunitloadId)` (the pallet's own carrier, when it has one — not
   in B's `{pallet, parcels}` set), `locationRepository.findById(storagelocationId)` (the pallet's
   *current* location, a second `Location` row beyond the gate that residual 3 does not cover), and
   `stockunitRepository.findByUnitloadId(...)` inside its `fixLocationAssignment != null` branch
   (the *pallet's* stock units, disjoint from B4's *parcel* stock units).
6. **Lock fan-out is a new exposure.** ⚠ **Corrected 2026-09-23 by SBDEV-3470: the figures below are wrong.** The 70-parcel pallets are inbound receiving pallets with no orders. The 88 stockunits belong to a different pallet, and stockunits are not locked. Over order-bearing pallets the max is 14 parcels, so 28 B3+B5 acquisitions. That is a property of the data, not a bound: B3 locks every child before PHASE C rejects an order-less pallet. The remedy below is corrected too: a multi-row locked finder does not reduce the lock count or the per-acquisition timeout (it saves only round trips), and it would need `ORDER BY id` inside its query. See the Fan-out note in `MobileTruckLoadingWriteService`. Original text kept for the record: The design locks by looping `findByIdForUpdate` in sorted
   order — the pinned `ParcelMonitorViewService` idiom — rather than adding a multi-row locked
   finder. On a worst-case Hydra prd pallet (measured: **70 parcels, 88 stockunits**) that is up to
   ~142 acquisitions, each bounded by `wms.tenant.lock-timeout-ms`. **Nothing on develop takes this
   many locks on the handheld path today.** ⚠ 142 × a 3 s timeout is a worst case no operator should
   ever meet, but it is the tail this design creates. Measure **p99** parcels-per-pallet, not the
   max, before accepting it — and if the tail is bad, the remedy is a multi-row locked finder at the
   same sequence positions, not a resequencing.
7. **Uniqueness, measured against Hydra prd `pg_index` 2026-09-22** — three design choices depend on
   it, and the answer differs per column:

   | column | unique? | consequence |
   |---|---|---|
   | `location.name` | **yes** — `uk_sahixf1v7f7xns19cbg12d946` | A6's scalar `findIdByName` is safe |
   | `unitload.labelid` | **yes**, twice — `uk_s2ujivixnde5dqb2stih8m2vh` and `uq_unitload_labelid` | B2's `findByLabelidForUpdate` is safe; A2's `existsByLabelid` likewise |
   | `billoflading.name` | **no** — only `billoflading_pkey`, plus a non-unique index on `state` | A4's scalar `findIdByName` can throw `IncorrectResultSizeDataAccessException`. **Not a regression** — today's `Optional<Billoflading> findByName` throws `NonUniqueResultException` on the same input, and 0 duplicate names exist on prd |
   | `(billoflading_id, number)` | **no** — `index_billoflading_position_number` is non-unique | the database cannot reject a duplicate number, by either mechanism in §1.2 |
   | `billoflading_position.source_id` | **no** — `index_billoflading_position_source_id` is non-unique | the latent non-unique-finder hazard in §4.2.2 has no schema-level backstop |

   *Derivation: `pg_index` joined to `pg_class`, filtered to the four tables, reading `indisunique`.
   Blind spot: it sees only database constraints, so a uniqueness rule enforced solely in
   application code would not appear — none exists in `BillofladingRepository`. Measured on prd
   only; UAT was not re-checked for index parity.*

---

## 5. Prerequisites & Implementation Plan

### 5.1 Prerequisites

| # | item | status |
|---|---|---|
| P1 | Read SBDEV-3398 §4.4 and `MobilePalletizeWriteService`'s class javadoc | **done** (2026-09-22) |
| P2 | Confirm nothing downstream consumes a partially-built BOL | **done** — §5.2 |
| P3 | Re-measure the field evidence with positive controls | **done** — §1.1 |
| P4 | Establish the develop baseline for both lanes | in progress |
| P5 | Agree the target statement sequence | **done** — §3.2 |
| P6 | Confirm no caller holds a managed `BillofladingPosition` across the two deletes | **RE-DERIVED at `3214a9c3`** — §5.3. `scanDestination` arm 1 now DOES hold them (guard at `:373`, delete at `:378`, same arm). The new write service does not. ⇒ **no-clear sibling methods scoped to the write service**; leave both existing deletes untouched |
| P7 | Re-verify every §2 / §3 claim against `3214a9c3`, not `f2ee75f1` | **done** — §5.5. Six dependencies checked; only the P6 one moved. `MobilePalletizeRaceIT` re-read: still `@Transactional(NOT_SUPPORTED)` + `BasePostgresIntegrationTest`, still a valid AC-7 template |

### 5.2 The description's open question is answered: nothing consumes a partially-built BOL

Grepped `origin/develop` of all three repos the description names:

- **`wms2-mobile-ui`** — the producer, not a consumer. `store/truckLoading.js` and
  `components/truckLoading/*` drive `loadOrder` → `scanPallet` → `scanGate`; between scans it
  re-reads `GET /truckLoading/truckLoadingInfo/{bolName}`, which returns BOL header fields and
  manifest counts, not position rows.
- **`wms2-web-ui`** — no runtime consumer; the only hits are two Cypress e2e specs driving the same
  producer endpoints.
- **`oms-laravel-api`** — push-only at this point in the flow. `POST /services/call/loadedToTruck`
  (`LegacyWmsController::loadedToTruck`) is what `scanGate` calls, and it sets `parcel_status = 35`;
  it reads no BOL position. The one pull-shaped path,
  `WmsApiService::createTransferAdviceFromBol`, is driven by `finishedShipping` — i.e. `closeBOL`,
  after the BOL is complete.

So the `handleTruckOffLoading` reordering does not need revisiting on those grounds.

*Instrument and blind spot: `git grep` sweeps over `origin/develop` for `billoflading*` /
`TRUCK_LOADING` / `truckLoading` / `loadedToTruck`. Would miss a consumer reaching the rows through a
differently-named projection or a runtime-built SQL string; does not cover `v1/` or
`siteboss-frontend`.*

### 5.3 ⚠ P6 was discharged at `f2ee75f1` and is RE-OPENED at `3214a9c3` — a merge landed under us

> **This is the clearest example in this plan of why a base commit has to be re-checked before
> implementation.** SBDEV-3452 (`86180b4d`, merged as PR #392 on 2026-09-21, i.e. *during* the
> session that wrote this plan) changed 148 lines of `MobileMoveUnitloadService` and **inverted the
> conclusion below.**
>
> It extracted the guards into `assertSourceCarrierNotOnTruck(Unitload)`, which calls both
> `assertParcelCarrierNotShipped` and `assertParcelCarrierNotOnTruck` — **each of which calls
> `billofladingPositionRepository.getBySourceUnitLoadLabelId(...)`, returning
> `List<BillofladingPosition>` entities.** And it placed that call **five lines above** the
> `handleTruckOffLoading` call, in the same arm of the same `@Transactional` method:
>
> ```java
> assertSourceCarrierNotOnTruck(sourceUnitLoad);                                  // :373  materialises positions
> unitloadBusinessService.transferUnitLoadToLocation(sourceUnitLoad, …, false, …); // :375  queues unitload writes
> handleTruckOffLoading(dto.getUnitLoadLabel());                                   // :378  deletes → em.clear()
> ```
>
> **So a caller now demonstrably DOES hold managed `BillofladingPosition` entities across the
> deletes**, which is precisely the condition P6 was checking for. The arm-exclusivity argument below
> described a code shape that no longer exists.
>
> **Two design consequences:**
>
> 1. **§3.2's preferred option — drop `clearAutomatically`, add `flushAutomatically = true` — is
>    withdrawn as "available".** It may now be actively wrong: after the bulk delete removes rows
>    that `scanDestination` holds as managed entities, `clearAutomatically` is doing real work
>    evicting them. Removing it needs its own argument, which nobody has made. Fall back to
>    **no-clear sibling methods used only by the new write service** (§3.2 option 2), which changes
>    nothing for `scanDestination`.
> 2. **§4.2.3's sibling exposure is worse than recorded, not better.** `scanDestination` now has
>    *both* pending unitload writes *and* managed `BillofladingPosition` entities live at the clear.
>
> **Re-derive P6 against `3214a9c3` before implementing.** The enumeration method below is still the
> right method; only its inputs changed.

#### What the enumeration said at `f2ee75f1` — retained for method, not for conclusion

Derived by enumerating the call graph on `origin/develop`, not by inspection of one method:

1. `git grep "deleteBolPositionsCarrierIds\|deleteBolPositionById" -- src/main` gives **two** Java
   call sites, and both are inside `handleTruckOffLoading` itself.
2. `handleTruckOffLoading` has **two** callers: `MobileTruckLoadingService.scanGate` and
   `MobileMoveUnitloadService.scanDestination`.
3. `scanGate` touches no `BillofladingPosition` before the call — its only ones are inside
   `BillofladingPositionService.createEntity`, which runs after.
4. `scanDestination` has **three** arms, and the two calls are in different ones:
   - arm 1, `destinationStorageLocation != null && !`flow-bin — contains
     `handleTruckOffLoading(dto.getUnitLoadLabel())`;
   - arm 2, `else if (destinationStorageLocation != null)` (*"the destination location is a flow
     bin"*) — contains **neither**;
   - arm 3, `else` (destination is not a location; try to match a unit load) — contains **both**
     `billofladingPositionService.assertParcelCarrierNotShipped(...)` calls, which reach
     `getBySourceUnitLoadLabelId` and return entities.

   Arms 1 and 3 are mutually exclusive, so the conclusion holds.

   *⚠ An earlier draft of this point placed the two guards in the flow-bin arm (arm 2). Wrong arm,
   same conclusion — corrected because a reviewer re-checking arm 2 would find nothing there and
   reasonably conclude the enumeration was not actually performed.*

→ **No caller holds a managed `BillofladingPosition` across either delete.** `clearAutomatically` is
therefore pure cost and pure hazard on both, and §3.2's preferred option — drop it, add
`flushAutomatically = true` — is available without the no-clear-sibling fallback.

*Axis and blind spots, stated: this is a `git grep` over `src/main` Java call sites, complete for
compiled Java callers since dispatch here is neither reflective nor proxy-mediated. Blind to v1 and
to unmerged branches.*

*⚠ **Not** a blind spot, contrary to an earlier draft: the SDR surface. That draft said both methods
carry `@RestResource(path = …)` and so "are invocable over HTTP". They are not —
`BillofladingPositionRepository` carries
`@RepositoryRestResource(collectionResourceRel = "billofladingPosition", path = "billofladingPosition", exported = false)`
at the **interface** level, which withdraws the whole repository and makes the per-method
`@RestResource` annotations inert. The conclusion was unaffected, but an inverted SDR premise in a
plan is a hazard of its own in this repo.*

### 5.5 Rebase audit — what SBDEV-3452 did and did not change

`f2ee75f1..3214a9c3` is one functional commit, `86180b4d` *"SBDEV-3452 Allow re-palletizing in
Palletizing; block only across a truck/BOL boundary"*, touching 18 files / +939 −657. Five of those
files are ones this plan depends on. Checked each:

| plan dependency | status at `3214a9c3` |
|---|---|
| `MobileTruckLoadingService` (the change target) | **untouched** — empty diff. Every line number in §2 still lands |
| the two deletes' annotations | **unchanged** — still `@Modifying(clearAutomatically = true)` + bare `@Transactional` |
| `createEntity`'s `size()`-based numbering | **unchanged** — still `generatePositionNumber(bol.getNumber(), bolPositions.size())` |
| the canonical TABLE lock order javadoc | **unchanged** — still verbatim in `MobilePalletizeWriteService` |
| `transferUnitLoadToLocation`'s `if (!ignoreLock)` block | **unchanged** — Bug 6a stands |
| **`MobileMoveUnitloadService`'s guard placement** | ⚠ **CHANGED, and it inverts P6** — §5.3 |

So the plan's design survives the rebase; one prerequisite does not.

⚠ **Still to re-check before implementation (P7).** `BillofladingPositionService` changed 109 lines
and `MobilePalletizeWriteService` 23; I verified only the specific symbols this plan quotes, not the
whole diff. `MobilePalletizeRaceIT` changed 121 lines and a new `MobilePalletizeRepalletizeIT`
(+349) landed — both matter because §6.2 names `MobilePalletizeRaceIT` as the template for AC-7, and
its shape may have moved. Re-read it before cloning it.

**The general rule this episode illustrates, worth more than the specific finding:** a plan's
`base_commit` is a claim with a shelf life. This one expired in under six hours, mid-session, and
nothing signalled it — the merge was discovered only because the gate re-fetched `origin/develop`
before creating the worktree. **Re-fetch and diff the base before the gate, every time**, and treat
any hit in the plan's affected-files list as a prerequisite to re-derive rather than a citation to
re-point.

### 5.4 Order of work

1. **Measure Bug 4a** (AC-4) against unmodified develop on the `scanDestination` path. Record the
   answer on the ticket either way.
2. ⚠ **Do NOT change the two delete annotations.** That step assumed P6, which is re-opened at
   `3214a9c3` (§5.3). Use **no-clear sibling methods** scoped to the new write service instead, and
   leave `scanDestination`'s behaviour untouched. The §4.2.3 sibling exposure is then NOT closed by
   this ticket — record it on [SBDEV-3442](https://app.clickup.com/t/868m6xy64).
3. **Add the five scalar projections** plus `findNameById` on `LocationRepository`, with the
   `@RestResource(exported = false)` treatment the sibling locking finders carry.
4. **Write the failing tests** (AC-1 first), confirm they fail for the right reason.
5. **Extract `MobileTruckLoadingWriteService`** and implement A → E.
6. **Mutation-check every new assertion** with PIT scoped to the changed class.
7. Full suite against the baseline in §6.4 — compare *which* failures, not totals.

---

## 6. Test Plan

### 6.1 Corrections to the inherited predictions — two of three are WRONG

| SBDEV-3398 / ticket prediction | verdict on `origin/develop` @ `f2ee75f1` |
|---|---|
| `OptionalSafetyArchTest` goes red | **WRONG.** Exactly 2 frozen entries exist for `scanGate` (`MobileTruckLoadingService.java:190` and `:207`, the two `isPresent() ? get() : null` ternaries) in `src/test/resources/archunit_store/5fb3fee0-…`. But `freeze.lineMatcher` is unset, so ArchUnit's default `FuzzyViolationLineMatcher` matches by **method signature** and ignores line numbers; and a `mvn test` run **prunes** solved entries rather than failing on them. Moving or removing those call sites will not go red. It would fire only on a `scanGate` **rename** that still calls `.get()`, or a genuinely new unguarded `.get()`. **Do not plan around a red that will not arrive.** |
| `MobileTruckLoadingServiceTest` goes red | **CONFIRMED**, with the mechanism: under `STRICT_STUBS`, `testScanGateSuccessfully` breaks as soon as a new locking finder is called that the mocks do not stub (unstubbed object-returning mock → `null` → NPE), and again via `UnnecessaryStubbingException` for each now-dead stub of a replaced finder. The six guard-clause tests never reach that far. |
| `UnitloadBusinessServiceUnitTest` goes red | **WRONG, with no mechanism by which it could be right.** Zero code-level coupling to `MobileTruckLoadingService` — no import, no field, no mock, no instantiation; the single grep hit is a prose comment in an SBDEV-3341 javadoc. It builds `UnitloadBusinessService` standalone via `@InjectMocks`. A caller-side annotation or statement reorder cannot reach it. |

Also checked and **not** gates here: `NestedCallSiteRailTest` does not scan `MobileTruckLoadingService`
at all (no live `registerSynchronization` — SBDEV-3267 already de-nested it); `HttpInTransactionArchTest`
is direct-call-only by explicit design.

`TestClassTransactionManagerArchTest` **is** a gate, but on the new tests rather than on `src/main`:
its `ALLOWED` list is now empty, so a bare `@Transactional` on a new test class fails it. Both existing
race ITs use the compliant form
`@Transactional(value = "tenantTransactionManager", propagation = Propagation.NOT_SUPPORTED)`.

⚠ There is a **second** test class, `MobileTruckLoadingServiceUnitTest`, and it is a legitimate split
rather than a duplicate — 11 tests, none touching `scanGate`. It declares **13** `@Mock` fields
against a **15**-arg constructor, and one of the 13 is the wrong type: it mocks `SyspropRepository`
where the constructor takes `SyspropService`. So `@InjectMocks` passes `null` for **three**
parameters — `syspropService`, `itemdataService` and `manageOrderService`.

**Do not add a `scanGate` test to that class without fixing all three first.** `syspropService`
matters most for this ticket: `handleTruckOffLoading` opens with two `syspropService.getSysvalue(...)`
calls, so a D0-bearing test there NPEs before it ever reaches the OMS notification. *(An earlier
draft of this section said two mocks were missing; it missed the mistyped one.)*

### 6.2 Acceptance criteria

**AC-1 — atomicity (the failing test first).** Inject a natural failure part-way through the write
sequence and assert that **no** BOL position row, no BOL state change and no customer-order state
change survives. Must fail on unfixed code for the right reason — an assertion about surviving rows,
not an NPE in setup.

⚠ **The failure site must survive phase C's reordering, or this AC goes green for the wrong reason.**
The two obvious natural mid-write failures on develop are both `BusinessException`s raised inside the
parcel loop after positions have already been saved — `"unexpectedUnitLoadDoesNotHaveOrder"` and
`"Too many orders with the same parcel found"`. **Phase C moves both of them ahead of every write.**
A fixture built on either would be red today, green after the fix because the *guard* fired, and
still green under a mutant that removes `@Transactional` — a passing test protecting nothing.

Pick a site that is still inside the write phase after the reordering: `itemdataService.getById(...)`
inside D6 (reached only when `stock.getOrderpositionId() == null`, throws on unknown itemdata) or a
DB constraint violation on the last position insert. **Then keep the guard fixture as a separate
test** asserting the orphan/duplicate errors now fire before any write — that is a real behaviour
change and worth pinning on its own.

⚠ Use a **natural** failure, not a spy. SBDEV-3398 §10.5 landmine 1: a `@Transactional` bean cannot
be stubbed with `@MockitoSpyBean` — Spring re-proxies the spy, so `doThrow(...).when(spy)...` runs
through `CglibAopProxy → TransactionInterceptor`, opens a real transaction *during stubbing*, and
gives `CannotCreateTransactionException` + `UnfinishedStubbingException`.

**AC-2 — the lock order is the canonical one.** Assert the acquisition order matches §3.0's table
order. `ClosebolLockOrderProbeIT` is the template: park a holder connection on a row, submit the
worker through the real Spring-managed service, then poll `pg_blocking_pids()` and snapshot the
blocked backend's held row locks from `pg_locks`. Each assertion carries its own non-vacuity control,
as that class already does.

**AC-3 — `handleTruckOffLoading` precedes every write in the boundary.** Assert the invariant, not
the instance: **no write is pending at D0.** Mutation-check on *that* — move the call back after the
writes and confirm the test goes red.

⚠ **Do not make "the failure message names the lost write" the kill criterion.** That requires a
write to actually be lost, which only happens if AC-4 resolves **false**. If the native query does
force a full flush, moving D0 after the writes loses nothing and the mutant stays green — while
still being genuinely harmful, via the identity split. "No pending write at D0" is checkable either
way and its mutant is reliably red. Add the stronger message assertion only if AC-4 comes back
false.

**AC-4 — settle Bug 4a by measurement, on unmodified develop.** Because `scanDestination` is already
`@Transactional` and already calls `transferUnitLoadToLocation` then `handleTruckOffLoading`, the
native-query-forces-a-full-flush hypothesis can be measured **today, against develop**, with no
change in place. Record the answer on the ticket either way.

⚠ **A green here is a genuine possible outcome and must not be read as a broken test.**

The minimal recipe: inside a `@Transactional` integration test, mutate a managed `Billoflading`
(no `save`, no `flush`), call `findBolIdByUnitLoadLabelId`, then `entityManager.clear()`, then re-read
the row through a fresh `EntityManager` and assert whether the mutation survived. Survived ⇒ the
native query force-flushed; lost ⇒ it did not.

⚠ **Do NOT discriminate by "is the row visible to a second connection".** An earlier draft proposed
that and it is **vacuous**: visibility is decided by COMMIT, not by flush. Under READ COMMITTED a
flushed-but-uncommitted UPDATE is invisible to every other session, so that probe answers "not
visible" in both worlds — and reads as positive evidence for "the write was at risk" either way.
Two probes that do separate them:

1. **Lock probe (cheapest, no instrumentation).** A flushed `UPDATE` holds a row lock. From a second
   connection, at the moment the clear fires, issue `SELECT … FOR UPDATE NOWAIT` on that row: it
   errors `55P03` if the write was flushed, and returns the row if it was not.
2. **Statement probe.** Register a Hibernate `StatementInspector` (or `hibernate.SQL` at DEBUG) and
   assert whether the `UPDATE` was emitted before the native `SELECT bp.id …`.

⚠ **Do not settle this from Hibernate's documentation.** The repo already contains one case where
the obvious reading of a `@Modifying` flag was wrong for the shape it was applied to
(`UserRoleUserFunctionRepository`, *"`flushAutomatically = true` is a no-op under this shape"*).
Measure it.

**AC-5 — the OMS notification is outside the boundary.** `HttpInTransactionArchTest` will **not**
catch this (direct-call-only by design); this AC is the only check. Assert it directly.

**AC-6 — lock contention is operator-legible.** A `PessimisticLockingFailureException` from the write
service must surface through the controller as an `errors` entry. ⚠ Not "instead of a 500" — untranslated it is a **409** with `retryable=true`; this AC grades the handheld-renderable shape, and the cost is that the 409 status and the retryable flag are dropped (Bug 7).

**AC-7 — concurrency, and it must grade B1 specifically.** `MobilePalletizeRaceIT` is the template.

⚠ An earlier draft wrote this as *"both must complete or one must fail with the contention
message"*. That disjunction **accepts every outcome the design can produce** — with B1 holding the
BOL row, two same-BOL scans always serialise, so "both complete" is the expected path and "one
fails" only occurs on a `lock_timeout`. It grades nothing. Replace it with two concrete assertions:

- (a) after two concurrent same-BOL scans,
  `SELECT billoflading_id, number FROM billoflading_position GROUP BY 1,2 HAVING count(*) > 1`
  is **empty** — **and the same query against the unfixed code is non-empty** (that control is what
  makes the assertion a kill rather than a tautology);
- (b) the second scan's positions are numbered above the first scan's high-water mark.

This is the AC that grades B1's load-bearing role (§1.2). Note §1.1's warning that a duplicate-count
AC is ungradeable applies to the **field** count over a natural window — it does not apply here,
where the concurrency is forced and the unfixed-code control genuinely collides.

**Every new assertion gets mutation-checked** — break what it protects, confirm red, confirm the
message names the mutant, restore. Use PIT scoped to the changed class, not a hand-rolled harness.

### 6.3 No verify script

Per the tier router, T3's script is opt-in and capped at 15 rows; nothing here needs one. Every
assertion above belongs in JUnit, where it runs in CI and survives a refactor. The two cross-file
invariants (AC-3, AC-5) are expressible as tests against the real call graph.

### 6.4 Baseline and how to run

- **Unit lane:** `mvn test -Dtest=MobileTruckLoadingServiceTest`. Surefire's defaults cover `*Test.java`;
  its `<excludes>` are `**/*IntegrationTest.java` and `**/*E2ETest.java`.
- **One IT:** `mvn verify -Dit.test=<Class> -Dtest=ZzzNone -Dsurefire.failIfNoSpecifiedTests=false`
  — the pom's own documented recipe. The pom also records that
  `mvn failsafe:integration-test -Dit.test=<Class>` **lies**: it reports `Tests run: 0` + `BUILD
  SUCCESS` for any class, included or not.
- ⚠ Always `clean`. A stale `target/test-classes` makes Maven run test classes that no longer exist
  in source — which is why CI runs `mvn -B -ntp clean verify`.
- ⚠ Never `-Dit.test='!Class'` to exclude; it discards the pom's `<includes>` and runs the entire
  tree. Use `-Dfailsafe.excludes`.
- **No authoritative in-repo baseline exists**, so it was measured fresh.

**Baseline measured 2026-09-22** in a detached worktree at `origin/develop` `f2ee75f1`
(`.claude/worktrees/wms2-api/_baseline-develop`), JDK 21.0.8, `mvn -B -ntp clean test`:

| lane | result |
|---|---|
| surefire (unit) | **6,750 tests, 0 failures, 0 errors, 1 skipped** |
| failsafe (IT) | **481 tests, 0 failures, 0 errors, 31 skipped** |
| overall | **BUILD SUCCESS**, 34:59 min |

Measured 2026-09-22 at `origin/develop` `3214a9c3`, in a detached worktree, against a **freshly
created** Testcontainers container, JDK 21.0.8, `mvn -B -ntp clean verify`.

⚠ **Do not carry these numbers forward as expected values** — they move with every merge (6,745 at
`f2ee75f1`, 6,750 after SBDEV-3452, 6,796 on this branch). Compare *which* failures appear, not
totals, and re-measure at the branch point.

#### Branch result — measured 2026-09-22 at `ed2ed97a`, rebased on `origin/develop` `b87ec747`

| lane | result |
|---|---|
| surefire (unit) | **6,796 tests, 0 failures, 0 errors, 1 skipped** |
| failsafe (IT) | **495 tests, 0 failures, 1 error, 31 skipped** |
| overall | BUILD FAILURE — on that single IT error, which is **pre-existing and not this branch's** |
| wall clock | 13:09 min |

**The one IT error is `ParcelMonitorViewServiceConcurrencyIT`, and it is a defect in that test, not
in this change.** Proven three ways rather than asserted:

1. Both `ParcelMonitorViewServiceConcurrencyIT.java` and `ParcelMonitorViewService.java` are
   **byte-identical** to `origin/develop` on this branch (`shasum` of `git show origin/develop:<f>`
   against the worktree copy). This branch's diff does not touch either.
2. Run it **twice in a row** against an unmodified tree: run 1 passes, run 2 fails with
   `duplicate key value violates unique constraint "index_customerorder_externalnumber",
   Key (externalnumber)=(PARCELMON-ORD-1) already exists`.
3. The class has **no `@AfterEach` and no cleanup of any kind**. It commits its fixture through
   `PROPAGATION_REQUIRES_NEW` and never deletes it, so with
   `testcontainers.reuse.enable=true` the second consecutive run on any machine inherits the row.

So it fails on the **second** build on a developer machine and on any CI runner with a warm reusable
container — a latent flake that has nothing to do with truck loading. Proposed as a separate ticket;
**not** fixed here, because it is another subsystem's test and folding it in would hide it inside an
unrelated PR.

#### ⚠ Two earlier full-suite runs were INVALID, and the reason is worth recording

Attempt A (at `349c219f`) had one real failure — `NeverMatcherNullBlindnessArchTest`, fixed in
`afb67376`. But surefire failing **aborts the build before failsafe**, so that run measured no ITs at
all; a green-looking "unit lane passed" would have been read as a full pass.

Attempt B and C reported **5 IT failures**, including three `Failed to load ApplicationContext`
errors that read exactly like a DI defect in this change. They were **cross-session interference**: a
peer Claude session was running its own `clean verify` in `.claude/worktrees/wms2-api/SBDEV-3410-p5-suite`,
and because `testcontainers.reuse.enable=true` every worktree's IT lane binds to the **same**
`postgres:14-alpine` container. `target/` isolation buys nothing there — the database is global. Root
cause in the log: `FATAL: sorry, too many clients already`. That peer's command also began with a
**global** `docker ps -aq --filter label=org.testcontainers=true | xargs -r docker rm -f`, so either
party can delete the other's database mid-run.

**Check `pgrep -fl "maven|surefire|failsafe"` before debugging a surprising IT result**, and queue
rather than race. The valid run above was taken after waiting on the peer's PID and settling 60s.

#### ⚠ Two earlier baseline runs were wrong, in two different ways. Both were environmental.

This matters more than the numbers, because both produced a wall of credible reds that would have
been handed to an implementer as "develop is broken":

| attempt | result | actual cause |
|---|---|---|
| 1 | IT lane `474 / 0 fail / 2 errors` | **Reused container.** `testcontainers.reuse.enable=true` and the `postgres:14-alpine` serving it had been up four hours. `ParcelMonitorViewServiceConcurrencyIT` collided on fixture residue: `duplicate key … Key (externalnumber)=(PARCELMON-ORD-1)` |
| 2 | IT lane `307 / 0 fail / **57** errors` | **Transient Docker outage.** Every one of the 57 was `Previous attempts to find a Docker environment failed. Will not retry.` — Testcontainers caches that verdict JVM-wide, so one outage becomes 57 identical errors |
| 3 | **green, both lanes** | clean container, healthy Docker |

**So a note in circulation that develop's failsafe lane carries "2 pre-existing errors" is not
confirmed by anything here, and attempt 1 reproduced its count for an unrelated reason.** On a clean
container develop is green. Treat a red IT lane as an environment question first and a code question
second — and never record a baseline taken against a reused container.

---

## 7. Horizontal Scalability Validation

| question | answer |
|---|---|
| Does the change introduce in-JVM state shared across requests? | No |
| Does it rely on single-instance assumptions? | No — the point of the change is to move serialisation into the database |
| Does it add a lock held across an outbound HTTP call? | **No, and this is enforced** — Bug 5 / AC-5 |
| Does it widen a lock window? | Yes, by design — the boundary now spans the whole scan. Bounded by `wms.tenant.lock-timeout-ms` (`SET LOCAL lock_timeout` per acquisition) |
| Could it deadlock against an existing path? | Mitigated by joining SBDEV-3419's table order. ⚠ **Not eliminated** — §3.0 caveat: the order does not rank rows within `unitload`, and `billoflading_position` is unplaced |

---

## 8. Notes

### 8.1 Checked and deliberately NOT in the lock set — do not re-raise

`transferUnitLoadToLocation` contains a `Pickingorder` pre-lock
(`pickLineRealignmentService.lockOwningPickingorders(...)`), which looks at first glance like a lock
class §3.2 fails to place. It is **gated on `BLOCK_REALIGN`**:

```java
if (PickLineActivityCodeClassifier.classify(activityCode, null) == PickLineActivityCodeClassifier.Bucket.BLOCK_REALIGN) {
```

`scanGate` passes `WmsConstants.CODE_TRUCK_LOADING`, which that classifier buckets as
`PASS_THROUGH` (the same file: *"PASS_THROUGH (shipping / truck-load / receiving / putaway / split /
nirvana) falls straight through"*). So the branch cannot fire on this path and the plan's silence
about `Pickingorder` is correct. Recorded because an independent review lane went looking for this
exact gap and had to read the classifier to rule it out.

### 8.2 Landmines carried from SBDEV-3398 §10.5 that this plan did not otherwise predict:

1. A `@Transactional` bean cannot be stubbed with `@MockitoSpyBean` (see AC-1).
2. `TestClassTransactionManagerArchTest` fires for `NOT_SUPPORTED` ITs that commit fixtures. They
   need registration with a justification and FK-ordered cleanup keyed on **unique keys, not ids** —
   the Testcontainers container is reused across builds, so fixed labels collide on the next run.
3. Verify scripts want the **sub-repo** root. Run without `PROJECT_ROOT` they grade the main checkout
   and report a meaningless clean pass. (Not applicable here — §6.3.)

---

## 9. Acceptance & Implementation

### 9.1 Acceptance script

None — see §6.3.

### 9.2 Implementation status

**MERGED to `develop`** as `20478809` (PR #397), 2026-09-22 — a dev deploy; no migration in the
diff, so the Flyway run is a no-op. ClickUp: `on dev`.

⚠ **AC-2, AC-4 and AC-7 were STRUCK, not met.** They are carried by
[[SBDEV-3465]] (T2, test-only). AC-2 and AC-7 are the criteria that grade the concurrency this
ticket exists to fix: the lock order is verified statically but never measured off `pg_locks`, and
no test races two operators. An uncontended test cannot tell a correct lock order from a wrong one —
that is the SBDEV-3244 lesson — so this shipped on construction and review, not on measurement.

Original PR line, for the record: https://github.com/SiteBossInc/wms2-api/pull/397 (2026-09-23).
Six commits on `bugfix/SBDEV-3418-truck-loading-transaction-boundary`, head `ed2ed97a`, based on
`origin/develop` @ `b87ec747`. 17 files, +2,122 / −314. ClickUp: `pr submitted`.

⚠ **Not merged, not deployed.** Merging to `develop` is a dev deploy and runs Flyway; this diff adds
no migration, so that is a boot-time no-op here.

| SHA | what |
|---|---|
| `d607abb6` | the boundary and the canonical lock order |
| `40deb565` | both lanes' Highs; the first-touch fix turned into a rail |
| `54d1fa08` | F16's false 500 premise; F5's two missing tests |
| `349c219f` | the twelve Low findings |
| `afb67376` | seven `never()` matchers the null-blindness rail rejects |
| `ed2ed97a` | the re-review lane's two Mediums and five Lows |

⚠ These SHAs are post-rebase. The review evidence under `SBDEV-3418-evidence/` cites the pre-rebase
`e64bdb5c` and `952fd347`, which are no longer reachable from the branch; the mapping is
`e64bdb5c → d607abb6` and `952fd347 → 40deb565`.

#### Which acceptance criteria are DONE, and which are deliberately deferred

An earlier state of this section said "Not started" while the work was well advanced, and the
deferral below was recorded nowhere — not here, not in the commit message. Both were flagged by the
conformance lane and both are fixed here.

| AC | state | evidence / rationale |
|---|---|---|
| AC-1 atomicity | **DONE** | `MobileTruckLoadingRollbackIT`, 4 soft witnesses, mutation-checked |
| AC-5 OMS outside the boundary | **DONE** | verified independently by the conformance lane |
| AC-6 contention legible | **DONE** | `lockContention` + outer-service unit test |
| AC-3 D0 ordering | **DONE** (added during review) | `InOrder` pin, mutation-checked with an attributable kill |
| **AC-2 lock order by `pg_locks`** | **DEFERRED** | needs a `ClosebolLockOrderProbeIT`-shaped probe. The order is verified *statically* (conformance lane) but not measured at runtime |
| **AC-4 flush-hypothesis measurement** | **DEFERRED** | measurable against unmodified develop on the `scanDestination` path; the sequence is correct either way (C-9), so it does not gate this change |
| **AC-7 concurrency race** | **DEFERRED** | needs a `MobilePalletizeRaceIT`-shaped two-operator IT |

⚠ **The three deferrals are a deliberate scope call, not an oversight, and they are the reason this
is not a complete T3 delivery.** AC-2 and AC-7 are exactly the criteria that grade the concurrency
behaviour this ticket exists to fix — static verification of the lock order is weaker than a
measured one, and no test currently reproduces two concurrent scans. **They must be stated in the
PR body, not just here.** Whoever picks them up should clone `ClosebolLockOrderProbeIT` for AC-2
and `MobilePalletizeRaceIT` for AC-7; both are re-verified as valid templates at `3214a9c3`.

#### Review lanes

| lane | verdict |
|---|---|
| `code-reviewer` | CHANGES REQUESTED — 2 High, 2 Medium, 6 Low |
| `verifier` (conformance) | FAIL at `e64bdb5c` — 1 Blocker, 1 High, 5 Medium, 6 Low |
| `code-reviewer` (re-review of the FIX commits) | CHANGES REQUESTED — 2 Medium, 5 Low, 3 Info. **No correctness defect in production code**; both Mediums were test-adequacy |

⚠ **The third lane exists because review fixes routinely ship unreviewed**, and on this ticket it
earned its cost immediately. It found that the PHASE C guard re-interleaving — which I had defended
with a seven-line comment — had **no test at all**: reverting it left the unit class 11/11 green,
because C3 carries an orphan and no duplicate and C4 a duplicate and no orphan, so neither fixture
can discriminate. It also found AC-1b's second witness structurally vacuous. A justification without
an assertion is the exact shape that lets a later "tidy these two guards together" edit revert
documented behaviour silently.

Both Highs were real and are fixed: the ArchUnit rail registration, and the gate `Location`
first-touch violation whose adjacent comment asserted the opposite. The first-touch rule now has a
**rail** rather than a one-line fix.

#### Findings ledger — every lane finding, closed

| # | severity | resolution |
|---|---|---|
| F1 / H1 | Blocker / High | ArchUnit rail registration — CLOSED |
| F2 / H2 | High | gate `Location` first-touch violation — CLOSED, and generalised into a rail rather than pinned |
| F4 | Medium | first-touch rail added |
| F5 | Medium | C3/C4 guard-ordering tests + AC-1b checked-exception rollback |
| F6 | Medium | no-clear doc contradiction |
| F13 | Medium | `never()` rows given a positive control |
| F16 | Medium | the "bare HTTP 500" premise was false in three places; corrected in both services and here |
| M1 | Medium | unreachable null guard rewritten as an emptiness test |
| M2 | Medium | AC-3 pinned; AC-2/4/7 deferred, recorded above |
| F3 | Medium | `findIdByName` javadoc named an impossible trigger |
| L1 / F10 | Low | `bolGateName` echo was a silent contract change; `TruckLoadOutcome.gateNewlyAssigned` |
| L2 | Low | O(n²) `contains()` under held row locks → `TreeSet` |
| L3 | Low | IT `@AfterEach` null guard + residue is now reported, not swallowed |
| L4 / F11 | Low | guard ordering re-interleaved per parcel to match develop |
| L5 | Low | eight dead `@Mock` fields (the review said five) + two whitespace gaps |
| L6 | Low | A1's vacuous rows labelled; the IT's stale sysprop comment rewritten |
| F7 | Low | §4.3 residuals 4/5/6 added to the class javadoc |
| F8 | Low | the rotted "six other sites" enumeration replaced with its derivation |
| F9 | Low | ArchUnit freeze-store prune — intentionally kept |
| F12 | Info | commit-message wording; corrected in the PR body |
| F14 | Low (plan) | §2 ↔ §3.2 projection count; §3.1 marked authoritative |
| F15 | Low (process) | per-lane worktrees; both removed at close |

| M1 (re-review) | Medium | PHASE C guard interleaving untested → **C5** added, mutation-checked with an attributable kill |
| M2 (re-review) | Medium | AC-1b witness 2 was structurally vacuous → replaced with the gate write + its control |
| L1–L5 (re-review) | Low | orphaned javadoc block; a completeness claim on a hand-maintained lock-set list; an `@AfterEach` comment asserting an impossible failure; `O(1)` → `O(log n)`; a run-on left by F16 |
| I2 (re-review) | Info | the handheld-rendering claim — mine correct and now cited; **both palletize siblings asserted the opposite citing a file that does not exist** |

**Found by the full suite, not by any lane:** `NeverMatcherNullBlindnessArchTest` rejected seven
type-specific matchers inside `never()` in the new tests. None of the targeted runs included that
rail. This is the concrete argument for the full-suite step — a targeted run cannot tell you about a
rail you did not think to name.

#### Still open

1. ~~Full suite on the branch vs the §6.4 baseline~~ — **DONE**, see §6.4. Unit lane clean; the one
   IT error is pre-existing and proven so.
2. ~~Push / PR checkpoint~~ — **DONE**, approved by Nam 2026-09-23; PR #397 open against `develop`.
   Not merged.
3. Remove the three lane worktrees at close: `SBDEV-3418-verify`, `SBDEV-3418-run`,
   `SBDEV-3418-rereview`.
4. ~~Proposed follow-up ticket~~ — **FILED 2026-09-23 as [[SBDEV-3458]]**
   (https://app.clickup.com/t/868m80mpq): `ParcelMonitorViewServiceConcurrencyIT` leaks its
   committed fixture, so every second `mvn verify` is red. T1, test-only. The sibling sweep in that
   ticket confirms it is the **only** instance: of the 19 ITs that commit, three carry no cleanup
   hook, and the other two (`SequenceTransactionServiceConcurrencyIT`, `IdempotencyFilterIT`) are
   safe because they write run-unique values. The rule it states — *an IT that commits must either
   delete what it wrote or write run-unique values* — is the reusable half.

### 9.3 ⚠ Three false readings this ticket produced, all from a contended worktree

Recorded because each one looked like a real result and two were nearly acted on:

1. **`mvn test-compile` reported BUILD SUCCESS on code that does not compile.** Incremental
   compilation did not recompile an unchanged test source whose constructor call no longer matched.
   `clean test-compile` failed immediately. **Always `clean`.**
2. **`Compiling 573 source files` followed by `cannot find symbol` on ordinary `src/main` classes**,
   with `target/classes` only partially written. Not a code defect — a second build in the same
   worktree.
3. **A mutation check reported `exit=1` and was nearly recorded as a kill.** It was
   `Failed to delete target/classes` during `clean`; the test never ran.

The cause is not only concurrent Maven: **two VS Code Java language-server JREs index this worktree
and hold handles on `target/`**, so `clean` can lose the race even with no other build running. The
conformance lane hit the same wall and resolved it the right way — it stopped fighting for the tree
and built in its own detached worktree at the same commit. **For any measurement that has to be
trusted, do that.**
