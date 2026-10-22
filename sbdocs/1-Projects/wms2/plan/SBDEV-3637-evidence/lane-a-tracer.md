# SBDEV-3637 — Lane A (tracer): reachability of the Stockunit↔Stockunit lock-ordering residual

**Tree read:** `/home/nampark/dev/wms-claude/.claude/worktrees/wms2-api/SBDEV-3637-readonly`, detached at
`origin/develop` = `ec42f43a` ("Merge pull request #453 … SBDEV-2624-sku-rename-in-place"). Nothing written,
no `mvn`, HEAD untouched.

**Instruments used:** `git grep` (not bare `grep` — ugrep skips binary silently), targeted `sed -n` reads,
and read-only SQL against `nywh-hydra-prd`, `wsl-wineco-uat`, `nywh-hydra-uat`. `c1wh-shipitez-prd` and
`nywh-shipitez-prd` both returned `permission denied for table replenishorder`, so **the production
population below is two reachable tenants, not the fleet** — every "0" in §6 carries that blind spot.

---

## 0. Headline — what changed versus the comment in the code

The `⚠ LOCK ORDERING — NOT PROVED SAFE` block in
`src/main/java/net/aim_ai/wms/service/ReplenishmentOrderMaintenanceService.java` frames the residual as
*"two DIFFERENT orders wanting the same pair in opposite directions"*, i.e. **recalc × recalc**, and leaves
it NOT ESTABLISHED. Three findings move the picture:

1. **Recalc × recalc on a single candidate snapshot is IMPOSSIBLE** — provable from the comparator plus the
   fact that the candidate query is keyed on `itemdata_id` alone (§2). The comment's own
   `!locationId.equals(order.getRequestedlocationId())` story **does not** produce a cycle on its own; it is
   refuted as stated (§2.4).
2. **A different, strictly easier cycle exists that the comment never names: move × move** (§3). Two
   operators moving two pallets of the same SKU onto non-replenishable destinations at the same moment
   produce a clean ABBA with **no third party, no clock, and no stale snapshot** — because each transaction's
   own UL relocation is visible to itself and invisible to the other, so each sees the *other's* source as
   the only candidate and its own as excluded.
3. **A second cycle exists across paths: `ReplenishorderService.redirectSource` already orders its two
   Stockunit locks ASCENDING**, explicitly to close its own cycle, and
   `MobileReplenishService.fulfillMultipleUnitLoadsTx` locks its SU set ascending via a `TreeSet`. The
   maintenance service is the **only** remaining writer in the replenishment family that uses
   current→target instead (§4). That makes this not "a residual we accept" but "one outlier against three
   conformers".

Severity does **not** collapse: the cron sweep is single-flighted per tenant by a PostgreSQL advisory lock,
but **three ungated non-cron entry points run the same code** (§1.3), so "the cron can't race itself" buys
much less than it appears to.

---

## 1. Entry points and concurrency gating — who can actually run `redirectSource` at the same time

### 1.1 The cron sweep IS single-flighted per tenant (new fact, loudly)

`src/main/java/net/aim_ai/wms/schedulejob/ReplenishOrderJob.java` wraps the whole `replenish(tenantName)`
body — including the terminal `replenishmentOrderMaintenanceService.recalculateOpenOrders(false)` — in a
two-key advisory lock:

```java
if (!advisoryLockService.tryLock(AdvisoryLockService.JobLockId.REPLENISH_ORDER, tenantId)) {
    LOG.trace("{} for {} - {} already running elsewhere, skipping this tenant only", …);
    continue;
}
```

and the manual trigger path takes the same two-key lock. `AdvisoryLockService` takes
`pg_try_advisory_lock(?)` on a **pinned raw connection from the landlord DataSource**, so it is
cluster-wide, not JVM-local ("Uses pg_try_advisory_lock() (session-level) to prevent duplicate job
execution across replicas"). A JVM-local `RUNNING` flag sits on top.

⇒ **Two concurrent cron sweeps of the same tenant cannot occur.** High confidence.
*Method:* read both lock sites in `ReplenishOrderJob` plus `AdvisoryLockService`.
*Blind spot:* it protects `replenish()`, nothing else — see 1.3. It also does not protect
`recalculateForItem` when called from anywhere other than inside `replenish()`.

### 1.2 Per-order transaction granularity differs by entry point

* `recalculateOpenOrders` calls `self.recalculateOrder(orderId, ctx)` through the CGLIB proxy, so **each
  order gets its own short REQUIRED transaction** and releases its locks between orders.
* `recalculateForItem` calls `recalculateOrder(orderId, ctx)` with a **plain `this.`** call — deliberate,
  with a long comment — so **every order of that item shares ONE transaction and the locks accumulate**.
  The order ids are ascending (`findIdsByStateAndItemdataId` … `ORDER BY r.id`, with
  `// SBDEV-3622: ascending id, so recalculateForItem locks an item's orders in the same order as the
  attributed reserved cut does`), but **the Stockunit sub-sequence inside that accumulation is not ordered
  at all**.

### 1.3 Three ungated callers reach the same code outside the advisory lock

| Caller | Call | Transaction context | Advisory-locked? |
|---|---|---|---|
| `service/mobile/MobileReplenishService.java:711` | `replenishmentOrderMaintenanceService.recalculateOpenOrders(true)` — **forced**, bypasses the cadence gate | post-commit, no tx; runs on **every** `/multi-unitloads` fulfilment | **No** |
| `service/StockunitService.java:174` (`triggerReplenishmentMaintenance`) | `recalculateForItem(itemDataId)` | reached from `transferStock`, `removeLock` (`:1266`) and others; sometimes inside a caller tx | **No** |
| `service/FixLocationAssignmentService.java:307` | `recalculateForItem(itemDataId)` | inside the FLA write's tx | **No** |

The `MobileReplenishService` one is the important one. Its javadoc says it plainly:

```java
 * … then — only after that transaction has committed and
 * released every pessimistic lock — best-effort runs {@code refillFixedLocations()} /
 * {@code recalculateOpenOrders(true)}.
```

**Two handheld operators finishing a multi-unit-load replenishment at the same moment each kick off a full,
cadence-bypassing sweep, concurrently, with nothing serialising them.** That is the concrete recalc × recalc
concurrency the comment could not name. High confidence; derived by `git grep -n "recalculateOpenOrders\|recalculateForItem" -- src/main`
and reading each hit. *Blind spot:* that grep is token-exact, so an invocation through a functional
reference or reflection would be missed; I saw none, and `redirectSource` is private so the only doors are
these two public methods plus `reassignOrCancelForMovedStockUnit`.

---

## 2. Q1 — Is the recalc × recalc ABBA reachable?

### 2.1 The candidate set is a pure function of the item, not of the order

`repo/jpa/StockunitRepository.java`:

```sql
WHERE su.itemdata_id = :itemDataId
AND su.entity_lock = 0 AND ul.entity_lock = 0 AND loc.entity_lock = 0 AND area.entity_lock = 0
AND area.useforreplenish = true
AND su.amount > su.reservedamount
AND (:excludeLanes = FALSE OR (loc.staginglane IS NOT TRUE AND loc.transferlane IS NOT TRUE))
AND  (:cutCooldownOn = FALSE OR NOT EXISTS (SELECT 1 FROM stockrecord sr_cut …))
ORDER BY su.amount DESC
```

No `su.id <> :current`, and the service pipeline is `.map(this::mapCandidate).sorted(…).findFirst()` — no
`.filter`. **Confirms the comment's second VERIFIED claim.** Every parameter (`itemDataId`, `excludeLanes`,
`cutCooldownOn`, `cutSince`) is item- or clock-derived; **nothing is order-derived**.

### 2.2 The only per-order difference is `preferredAreaId`

```java
final Long preferredAreaId = currentSource == null ? null :
    unitloadRepository.findById(currentSource.getUnitloadId())
        .flatMap(unitload -> locationRepository.findById(unitload.getStoragelocationId()))
        .map(Location::getAreaId).orElse(null);
…
.sorted(Comparator
    .comparing((StockCandidate c) -> !Objects.equals(preferredAreaId, c.areaId))
    .thenComparing(StockCandidate::getAvailable, Comparator.reverseOrder()))
```

`Boolean` compares `false < true`, so **candidates in the current source's own area sort first**; within a
group, `available = amount − reserved` descending; ties broken by the stream's encounter order, which is the
DB's `ORDER BY su.amount DESC` — deterministic and identical for both callers.

### 2.3 Theorem: one snapshot ⇒ no cycle

Take orders O₁ (current S₁) and O₂ (current S₂). Cross-targeting (O₁→S₂ **and** O₂→S₁) requires both S₁ and
S₂ to be in the shared candidate set **C** of the same item. Then:

* **area(S₁) = area(S₂).** Both comparators are byte-identical (same `preferredAreaId`, same C) ⇒ both pick
  the **same** top candidate T. If T = S₁, O₁ takes the SBDEV-3618 Fix E same-row re-point, which returns
  **before any second lock is taken**; O₂ locks S₂→S₁. One directed edge, no cycle. Symmetrically for T = S₂.
  If T is a third row, both go current→T: a convoy on T, not a cycle.
* **area(S₁) ≠ area(S₂).** O₁'s preferred group is area(S₁), which **contains S₁** (S₁ ∈ C by assumption), so
  O₁'s top is in area(S₁) and cannot be S₂. Contradiction.

⇒ **A recalc × recalc ABBA cannot form within a single candidate snapshot.** Confidence: **high** — it
follows from two quoted code fragments and needs no runtime assumption.

Cross-item is also excluded: the query filters `su.itemdata_id = :itemDataId`, so S₁ can be offered to O₂
only if `S₁.itemdata_id = O₂.itemdataId`. *Blind spot:* nothing structurally pins
`replenishorder.itemdata_id = stockunit.itemdata_id`. The writers preserve it
(`redirectSource` sources candidates from `order.getItemdataId()`; `ReplenishorderService.redirectSource`
checks it explicitly: `if (!Objects.equals(stockUnit.getItemdataId(), replenishOrder.getItemdataId()))`),
but **SKU-rename-in-place (SBDEV-2624, the merge at this very HEAD) mutates `stockunit.itemdata_id`** and I
did not audit whether it re-points bound replen orders. If it does not, a mismatched pair could break the
same-item requirement. **NOT ESTABLISHED** — probe: read `SkuBatchCreateUpdateService` / the SBDEV-2624 diff
for a `replenishorder` update, and run
`SELECT count(*) FROM replenishorder r JOIN stockunit s ON r.stockunit_id=s.id WHERE r.state<700 AND r.itemdata_id<>s.itemdata_id;`.

### 2.4 Verdict on the comment's own `isSourceUsable` story — REFUTED as stated

The comment says the `!locationId.equals(order.getRequestedlocationId())` route makes *both* sources
unusable to their own order *while remaining candidates to the other*. **The second half is what breaks it.**
Being unusable via the location-mismatch route does **not** remove a row from C — C has no location
predicate beyond `area.useforreplenish` and the lane flags. So if S₁ is merely location-mismatched, S₁ is
still in C **and still in O₁'s preferred area**, so O₁ picks S₁ (Fix E re-point, no second lock) and never
reaches for S₂. §2.3 applies and there is no cycle.

What the comment needed, and did not say, is that the current source must be **absent from C**, which
requires a *different* exclusion: `su.amount > su.reservedamount` failing, `entity_lock ≠ 0` on any of the
four joined tables, `area.useforreplenish = false`, a staging/transfer lane under SBDEV-1666, or the
SBDEV-3636 manual-cut cooldown. And both S₁ ∉ C and S₂ ∈ C must hold **in O₁'s snapshot** while the mirror
holds in O₂'s — which §2.3 shows is self-contradictory *in one snapshot*.

Also worth recording: the capacity route **cannot** be the one. `isSourceUsable` returns false when
`share.capacity() ≤ 0`, but `capacity = min(held + free, max(amount,0))` and C requires
`amount > reservedamount` ⇒ `free > 0` ⇒ `capacity > 0`. A row in C is never unusable for capacity.

### 2.5 The three ways the snapshots can diverge — this is where the residual actually lives

**(a) A multi-order transaction's own uncommitted redirects.** `recalculateForItem` processes every
PROCESSABLE order of one item in **one** transaction. After O₁ is redirected, that transaction's *own*
writes (new `reservedamount` on the target, released on the old source) are visible to its next candidate
query but invisible to a concurrent sweep. **The two sides no longer share a snapshot**, and §2.3's premise
fails with no third party involved. Two concurrent `recalculateForItem` calls on the *same* item serialise
on the first (ascending) order row, but **`recalculateForItem` × `recalculateOpenOrders` do not**: the sweep
reaches a given order from a different direction and the two can interleave.
Confidence: **medium-high** that the mechanism is real; **NOT ESTABLISHED** that a concrete interleaving
produces a cycle rather than a convoy — I did not construct one that survives §2.3's parity argument end to
end.

**(b) The manual-cut cooldown clock.** `ManualCutCooldown.current(syspropService)` recomputes `cutSince` per
call, so membership in C is **time-dependent**: a cut row ages out of the window. Combined with one operator
cut landing between the two queries, S₁ can be out of C at τ₁ and in C at τ₂ while S₂ does the reverse. The
timeline that produces a cycle: T₂ locks O₂+S₂ first, queries at τ₂, targets S₁, blocks on S₁ (held by T₁);
T₁ locked O₁+S₁ earlier, queried at τ₁ < τ₂, targeted S₂, blocks on S₂. Consistent. Confidence: **low-medium**
— it needs one operator `MANUAL_ADJUSTMENT` cut inside a sub-second window plus a cooldown-boundary crossing.

**(c) `RecalcContext` is a detached snapshot taken outside any transaction.** `recalculateOpenOrders` is not
`@Transactional`; `buildRecalcContext` runs before the per-order transactions and its
`Map<Long, Unitload> unitloadsById` is **never refreshed for the whole sweep**. `isSourceUsable` then
compares a sweep-start `unitload.getStoragelocationId()` against a freshly-locked
`order.getRequestedlocationId()`. So **any move of a source unit load during a sweep makes that order's
source look unusable to the sweep**, even a move that correctly re-pointed the order. This widens the
"unusable source" population a lot; it is the fuel for (a) and (b), not a cycle by itself.
*(Note the map falls back to a live read on a miss — `return u != null ? Optional.of(u) : unitloadRepository.findById(id);` — so this is staleness on a HIT, not absence on a miss.)*

### 2.6 The structural ceiling nobody has used yet: at most one active order per (item, destination)

`wsl-wineco-uat`, `pg_indexes`:

```sql
CREATE UNIQUE INDEX idx_replenishorder_active_item_dest
  ON public.replenishorder USING btree (itemdata_id, destination_id) WHERE (state < 700);
CREATE UNIQUE INDEX idx_replenishorder_active_item_no_dest
  ON public.replenishorder USING btree (itemdata_id) WHERE ((state < 700) AND (destination_id IS NULL));
```

(both also in `src/main/resources/db/migration/V2.2.00__base_v2_schema.sql:3876` and
`db/v1-to-v2-onboarding/schema/V2.1.04__replenishorder_performance_indexes.sql:40`).

⇒ **Two active same-item orders require two different destinations**, which means either two FLAs for the
item, or one FLA-destination order plus one `destination_id IS NULL` order. The second shape is real
(`generateReplenishmentForItemDataWithoutFixedAssignment` creates null-destination orders; 8 913 of 61 630
replenish orders on `wsl-wineco-uat` have a null destination, and 2 749 items have *ever* had both shapes).
So the index **narrows** recalc × recalc to a specific, uncommon configuration; it does **not** close it.

**This is the single strongest piece of evidence the three prior attempts did not have**, and it should be
cited in whatever replaces the comment.

### 2.7 Q1 verdict

**Recalc × recalc is reachable only through snapshot divergence (§2.5 a/b) *and* a two-active-orders-per-item
configuration (§2.6).** It is **substantially less reachable than the comment implies**, and the specific
mechanism the comment offers is wrong (§2.4). Confidence **medium-high**. It is also **not the cycle that
should drive the fix** — §3 is.

---

## 3. The cycle the comment misses: move × move (highest reachability)

### 3.1 The mechanism

`service/UnitloadBusinessService.java`, `processTransfer`:

```java
unitload.setStoragelocationId(destinationLocation.getId());
unitload = unitloadRepository.save(unitload);
…
if (PickLineActivityCodeClassifier.classify(activityCode, null) == …Bucket.BLOCK_REALIGN) {
    for (Stockunit movedStockUnit : stockunitRepository.findByUnitloadId(unitload.getId())) {
        pickLineRealignmentService.assertNoActivePickFor(movedStockUnit.getId());
        pickLineRealignmentService.realignForMovedStockUnit(movedStockUnit, unitload, destinationLocation);
        replenishmentOrderSourceSyncService.syncForMovedStockUnit(movedStockUnit, destinationLocation);
    }
}
```

The unit load is relocated **before** the replen hook runs, inside the same transaction. So when
`redirectSource` issues its candidate query:

* **Its own moved source is excluded** — the UL now sits in a non-replenishable area (that is precisely the
  branch that routed here: `if (!isReplenishableDestination(destinationLocation)) { …reassignOrCancel…; return; }`),
  and C requires `area.useforreplenish = true`.
* **The other transaction's moved source is still visible at its OLD, replenishable location**, because that
  move is uncommitted.
* `preferredAreaId` resolves to the **new** (non-replenishable) area, so no candidate matches the preferred
  group and ordering collapses to pure `available DESC`.

Two operators, same SKU, two pallets, both moved onto lanes/non-replenishable locations at the same moment:
T₁'s only candidate is S₂, T₂'s only candidate is S₁. **Exact ABBA, no third party, no clock, no staleness.**

Each side's lock sequence is `order → current → target`, so with `id(S₁) < id(S₂)` T₁ runs ascending and T₂
runs descending. PostgreSQL aborts one with `40P01`.

### 3.2 Why this is operationally plausible

* `syncForMovedStockUnit` is reached only under `BLOCK_REALIGN` = `{CODE_MOVE_FIX_ASSIGNMENT,
  CODE_MANUAL_TRANSFER, CODE_TRANSFER, CODE_ON_HOLD}` (`PickLineActivityCodeClassifier`). Those are exactly
  the **operator** moves: web Move Stock (`StockunitService:593`, `CODE_MANUAL_TRANSFER`), handheld Move Unit
  Load (`MobileMoveUnitloadService:427/760/764`, `CODE_TRANSFER`), FLA relocation
  (`FixLocationAssignmentService:165`), on-hold (`StockunitService:788`).
* A non-replenishable destination is the normal case for Move Stock: any staging lane, transfer lane, QA
  area, damage area, or any area with `useforreplenish = false`.
* The reassign path is **already exercised and green today**:
  `src/test/java/net/aim_ai/wms/service/ReplenReassignOnNonReplenishableMoveIT.java` AC2
  ("move onto a non-replenishable destination with an alternate source reassigns the SAME order") asserts
  `boundStockUnit(REPLEN) == SU_ALT` and `reserved(SU_ALT) == REQUESTED`. So the two-SU lock really is taken
  in production shape; only the second concurrent actor is missing from the test.

**Confidence: high** that the interleaving is constructible; **medium** that it occurs at current production
volumes (see §6 — the per-item active-order ceiling does not apply here, since the two orders are on
different items *or* different destinations, and in fact move × move needs only that the two moved SUs share
an item).

⚠ One dependency I could not close by reading alone: **whether Hibernate auto-flushes the pending
`unitload` UPDATE before the native candidate query**. Spring Data executes `getAvailableReplenishmentSources`
via `EntityManager.createNativeQuery`; Hibernate 6 flushes conservatively for native queries with no declared
synchronized spaces, which would make the own-move visible. If it does **not** flush, the own source stays in
C at its old location — but `preferredAreaId` is still the new, non-replenishable area (it is computed from
the in-memory, already-modified `Unitload`), so S₁ lands in the non-preferred group alongside everything
else and the top is still `max(available)`, which can still be S₂. **The cycle survives either way, but the
"its own source is excluded" clause is NOT ESTABLISHED.** Probe: a one-method IT that moves a UL to a lane
and asserts, inside the same transaction, that `getAvailableReplenishmentSources` does not return the moved
SU.

---

## 4. Q2 — Full lock set on each path, in acquisition order

### 4.1 Recalc path (`recalculateOrder`)

| # | Lock | Site |
|---|---|---|
| 1 | `replenishorder` row, PESSIMISTIC_WRITE | `Replenishorder order = replenishorderRepository.findByIdForUpdate(orderId).orElse(null);` |
| 2 | `stockunit` **current**, PESSIMISTIC_WRITE | `ensureValidSource`: `order.getStockunitId() == null ? null : stockunitRepository.findByIdForUpdate(order.getStockunitId())` |
| 3 | `stockunit` **target**, PESSIMISTIC_WRITE | `redirectSource`: `Stockunit targetStock = stockunitRepository.findByIdForUpdate(candidate.stockUnitId)` |
| 4 | row locks from the UPDATEs on `stockunit` ×2 and `replenishorder` (already held) + `stockrecord` INSERTs (new rows) | `changeReservedAmount` → `stockrecordService.recordChangeReservedAmount` |

`changeReservedAmount` itself adds nothing: `stockunitRepository.findByIdForUpdate(staleStockUnit.getId())`
re-locks a row the caller already holds, then `entityManager.refresh`. `recordChangeReservedAmount` only
*reads* `unitload`, `location`, `itemdata` with plain finders and INSERTs a new `stockrecord`.

**No Location, Unitload or Pickingorder lock is taken anywhere on the recalc path.** *Method:* read every
line of `recalculateOrder → ensureValidSource → isSourceUsable → redirectSource → changeReservedAmount →
recordChangeReservedAmount → releaseHeld → cancelOrder → markCancelled → updateRequestedAmount → shareOf`,
plus `git grep -n "ForUpdate" ` over the two services. *Blind spot:* a bulk `@Modifying` UPDATE reached
indirectly would take row locks invisibly to a `ForUpdate` grep; I saw none on these paths.

On `recalculateForItem`, multiply rows 1–3 by the number of PROCESSABLE orders of the item, all accumulated
in one transaction, orders ascending by id but **stock units in no order at all**.

### 4.2 Move path (`transferUnitLoadToLocation`) — the ticket's claim, VERIFIED with corrections

| # | Lock | Site / condition |
|---|---|---|
| 1 | `pickingorder` rows, **ascending id, deduped**, for every owning PO of every SU on the **whole carrier tree** | `UnitloadBusinessService:235-237` → `pickLineRealignmentService.lockOwningPickingorders(treeStockUnitIds)`; inside: `Set<Long> owningOrderIds = new TreeSet<>(); … for (Long pickingorderId : owningOrderIds) { pickingorderRepository.findByIdForUpdate(pickingorderId); }`. **Only for BLOCK_REALIGN** — which is also the only bucket that reaches the replen hook, so it is always present on this path. |
| 2 | **destination `location`** row, PESSIMISTIC_WRITE | `destinationLocation = locationRepository.findByIdForUpdate(destinationLocationId)…; entityManager.refresh(destinationLocation);` — **skipped when `ignoreLock = true`**. The four operator BLOCK_REALIGN callers pass `false` (`StockunitService:593`, `MobileMoveUnitloadService:427/760/764`, `FixLocationAssignmentService:165`); only `StockunitService:788` (`CODE_ON_HOLD`) passes `true`. |
| 3 | `unitload` row(s) — implicit, at flush | `unitload.setStoragelocationId(...); unitload = unitloadRepository.save(unitload);` per tree node. Not a `FOR UPDATE`; the row lock lands when the UPDATE is flushed. |
| 4 | `pickingorder_position` rows — implicit, at flush | `realignForMovedStockUnit` → `pickingorderPositionRepository.save(pp)` |
| 5 | `replenishorder` row | `syncForMovedStockUnit` / `reassignOrCancelForMovedStockUnit`: `replenishorderRepository.findByIdForUpdate(probeId)` |
| 6 | `stockunit` **current (moved)** | `Stockunit lockedSource = stockunitRepository.findByIdForUpdate(movedStock.getId()).orElse(null);` (SBDEV-3618 Fix D) |
| 7 | `stockunit` **target** | `redirectSource` — the subject line |

**Then steps 5–7 repeat per stock unit on the unit load**, and the whole block repeats per child unit load
in the carrier tree. `stockunitRepository.findByUnitloadId` carries **no `ORDER BY`**, so a multi-SU unit
load accumulates several (order, current, target) triples in an **unspecified** order.

**Verdict on the ticket's "carrier-tree locks (Location, Pickingorders, other SUs)":**
Location ✅ (destination only, and only when `ignoreLock=false`), Pickingorders ✅ (ascending, whole tree),
"other SUs" ❌ as *pessimistic* locks — other stock units are only read with
`stockunitRepository.findByUnitloadId` (plain finder). They acquire row locks **one at a time, as the loop
reaches each one**, not up front.

**Consequence for the fix:** ascending-id ordering of the two stock-unit locks **inside one
`redirectSource` call** is necessary but **not sufficient on the move path**, because the loop takes
(current_i, target_i), then (current_{i+1}, target_{i+1}) — a globally unordered sequence. The complete fix
for the move path is to order the *whole* per-transaction SU lock set ascending up front, which is precisely
what `PickLineRealignmentService.lockOwningPickingorders` already does for Pickingorders ("Locking ascending
up front is the only way to guarantee a global ascending lock order across the tree — locking on demand
during traversal would lock in tree order, not id order, risking deadlock"). **That comment is the in-repo
precedent and the argument for the stronger shape.** Confidence: high.

### 4.3 The canonical order, as the repo states it

`UnitloadBusinessService:233`: *"Lock order: Pickingorder before Unitload/Stockunit/Location."*
The move path honours it. The recalc path takes `Replenishorder → Stockunit` and touches nothing else, so it
sits entirely below Pickingorder in that hierarchy and cannot invert it.

---

## 5. Q3 — 3-cycles and cycles through other tables

### 5.1 Stockunit ↔ Stockunit, cross-path (REAL, and easier than recalc × recalc) — rank #2

**Three writers already order their Stockunit locks ascending; the maintenance service is the only one that
does not.**

`service/ReplenishorderService.java` (web "Change Source", reached by `/update`, `/updateStockUnit`,
`/changeSourceStockUnit`):

```java
// Ascending-id lock order (D7): closes the redirect-vs-redirect cycle X: A->B / Z: B->A.
if (oldStockUnitId != null && oldStockUnitId < newStockUnitId) {
    oldStockUnit = stockunitRepository.findByIdForUpdate(oldStockUnitId);
    newStockUnit = stockunitRepository.findByIdForUpdate(newStockUnitId);
} else { … }
```

`service/mobile/MobileReplenishService.java`:

```java
SortedSet<Long> lockIds = new TreeSet<>();
for (ResolvedUnitLoad entry : resolved) { lockIds.add(entry.stockunitId); }
if (template.getStockunitId() != null) { lockIds.add(template.getStockunitId()); }
Map<Long, Stockunit> locked = new HashMap<>();
for (Long id : lockIds) { stockunitRepository.findByIdForUpdate(id).ifPresent(su -> locked.put(id, su)); }
```

`PickLineRealignmentService.lockOwningPickingorders` — ascending, for Pickingorder.

So: **web redirect takes {old, new} ascending; maintenance takes {current, target} in that fixed order.**
For the pair (S_a, S_b) with `id(S_a) < id(S_b)`, a web redirect always goes S_a→S_b; a maintenance redirect
whose current is S_b and target is S_a goes S_b→S_a. **ABBA.** Critically, **the web path's guards are all
*after* both locks** (state and `new != old` are checked before, but the reserved/item/eligibility checks
come after), so the candidate-snapshot reasoning of §2.3 gives no protection at all here — the operator
chooses the target.

Same story for the multi-UL mobile path, with an extra twist: `fulfillMultipleUnitLoadsTx` runs maintenance
**inside its own transaction** while holding the template's order lock
(`assignDestinationForMultiUnitLoads` → FLA create → `triggerReplenishmentMaintenance` → `recalculateForItem`;
the javadoc says so: *"Creating the destination's FLA can synchronously run replenishment maintenance"*).
So one transaction mixes **current→target** ordering (from maintenance) with **ascending** ordering (its own
TreeSet block) — the orderings are inconsistent *within a single transaction*.

**Rank #2 after move × move. Confidence: high** that the ordering disagreement exists (quoted code);
**medium** on real-world frequency (it needs an operator using Change Source on one order while the cron or
another path re-sources a second order across the same pair).

### 5.2 Cycles through Location — **NO** (within this family)

The recalc path never takes a Location lock (§4.1); it only does `locationRepository.findById`. The move
path takes the destination Location lock **first**, before any Stockunit lock. So a move holding a Location
and wanting a Stockunit can only be blocked by a holder of that Stockunit; for a cycle that holder would
have to want that Location, and no replenishment path does. Confidence: high within the paths audited.
*Blind spot:* the scan is "paths reachable from `redirectSource` and from `transferUnitLoadToLocation`" —
`StockunitBusinessService.transferStock` (which takes `src-stockunit → src-unitload → src-location →
dst-unitload → dst-stockunit → dst-location`, per its own comment at `:233-235`) **does** hold Stockunit
locks and then want Location locks, so a `transferStock` × move cycle through Location is plausible and is
**out of this lane's scope** — flag it, do not fold it into SBDEV-3637.

### 5.3 Cycles through Pickingorder / pickingorder_position — **NOT from the recalc side**

Recalc only *reads* `pickingorderPositionRepository.sumOpenAmountByPickfromstockunitId` (in `shareOf`) —
no lock, no write. So the recalc side never holds or wants a PO lock. The move side holds POs **before**
SUs. A cycle would need a third actor holding an SU and wanting a PO — the picking paths. Out of scope;
flag it.

### 5.4 `refillFixedLocations` / `calculateOrder(REQUIRES_NEW)` — **NOT a participant here**, but a separate hazard

`ReplenishGeneratorService.calculateOrder(…)` is `@Transactional(REQUIRES_NEW)` and takes
`changeReservedAmount(sourceStock, …)` → a Stockunit lock in a **suspended-parent** sub-transaction. That is
the known "REQUIRES_NEW while holding locks" shape, and PostgreSQL **cannot** see it as a cycle (the parent
is idle-in-transaction, not waiting), so it resolves as `55P03` at `lock_timeout`, not `40P01`. But
`MobileReplenishService` already moved it post-commit on purpose:

```java
 * Previously these ran inside the same locked transaction,
 * which is the same REQUIRES_NEW-while-locks-held anti-pattern as the reported deadlock (plan §5 Fix D);
```

and `ReplenishOrderJob.replenish()` has no outer transaction. **So it does not participate in the
SBDEV-3637 cycle.** Confidence: medium-high. *Blind spot:* I did not enumerate every caller of
`calculateAutomaticOrder` / `refillSingleFixedLocation`; a future caller inside a lock-holding transaction
re-opens it.

### 5.5 Sequences — **not a participant**

`AbstractBaseEntity` uses `@GeneratedValue(SEQUENCE, generator="entity_gen")` on `seqentities` with
`allocationSize = 1`. PostgreSQL sequences are non-transactional and `nextval` takes no row lock. Useful
corollary: **ids are globally monotonic across all tables**, so "ascending id" on Stockunit is equivalent to
"oldest row first".

---

## 6. Production grounding (the DB query the floor requires)

| Tenant | PROCESSABLE orders | items with ≥2 active orders | items with ≥2 FLAs | items with ≥2 candidate SUs | candidates spanning ≥2 areas | `REPLENISHMENT_SWITCHED` rows | `pg_stat_database.deadlocks` |
|---|---|---|---|---|---|---|---|
| `nywh-hydra-prd` | 1 | 0 | — | 1 | 0 | — | **0** (stats_reset 2026-06-11) |
| `wsl-wineco-uat` | 570 | **0** | **0** | 1 042 | **0** | 106 (last 2026-09-04; 4 in 90 d) | **0** |
| `nywh-hydra-uat` | 8 | 0 | 0 | — | — | 0 | **0** |
| `c1wh-shipitez-prd`, `nywh-shipitez-prd` | — | — | — | — | — | — | `permission denied for table replenishorder` |

Also on `wsl-wineco-uat`: `processable_src_in_nonreplen_area = 0`, `processable_src_location_mismatch = 0`,
`processable_null_source = 0` — i.e. **right now** no order has an unusable source. That is a snapshot of a
deliberately transient condition (the cron heals it each pass), so it bounds nothing about the rate.
74 of the 106 `REPLENISHMENT_SWITCHED` rows have a sibling within 5 s — consistent with burst activity on
the redirect path, though most of those are almost certainly sequential within one sweep rather than
concurrent.

**Reading of the zeros.** `deadlocks = 0` across three databases is consistent with "no occurrence", and
`PostgresDeadlockDetectorControlIT` (SBDEV-3419) is the positive control proving that counter is not inert
on `postgres:14-alpine`. But `items_with_2plus_active_orders = 0` everywhere is the more informative number:
**the recalc × recalc configuration is currently absent from every tenant I can read**, and the unique index
(§2.6) explains why. Move × move needs no such configuration — only two same-item source pallets, and 1 042
items on `wsl-wineco-uat` have ≥2 candidates.

⚠ **These are three tenants at one instant, and two of the five production databases refused the query.**
Do not write "no tenant has …" anywhere downstream.

---

## 7. Q4 — Starvation under defer-on-contention

Assume the proposed fix is **ascending-id acquisition + `SKIP LOCKED` (or `NO WAIT`) on the second lock,
deferring to the next pass on contention**.

**Where starvation can bite:**

1. **The move path has no next pass.** `reassignOrCancelForMovedStockUnit` is a one-shot inside an operator's
   HTTP transaction. If the target lock is skipped, `redirectSource` returns false and the caller runs
   `cancelOrder(order, lockedSource, CODE_REPLENISHMENT_CANCELLED)` — **the order is destroyed, not
   deferred**. That is a behaviour regression dressed as a retry: today the operator's move blocks for up to
   `lock_timeout` and usually succeeds. **An acceptance criterion must forbid a skipped lock from reaching
   `cancelOrder` on the move path** — it must surface as a retryable failure (the existing
   `FacadeException`/422 shape) or fall through to the next candidate.
2. **Deterministic candidate ordering makes the loser retry onto the same row.** The ordering is
   `preferredArea first, then available DESC`, with the DB's `amount DESC` as the stable tiebreak. Nothing in
   it depends on the requesting order or on attempt count. So an order that loses a contest for target T will
   be offered **T again** on the next pass, and if the winner's reservation does not change T's membership in
   C, it loses again. The structural tiebreak is `available = amount − reserved`: a successful reservation on
   T *lowers* T's available, which demotes it — **so the common case self-corrects**. The pathological case is
   `available` ties, or a winner whose reservation is released again before the next pass (a cancel loop).
3. **Cadence interacts badly.** `shouldSkipForCadence()` gates `recalculateOpenOrders(false)`; the deferred
   order's next chance is at most `SYSTEM_PROPERTY_REPLENISHMENT_RECALCULATION_CADENCE_SECONDS` away, but
   `recalculateOpenOrders(true)` from `MobileReplenishService` bypasses it. So retry latency is bimodal and
   not operator-visible.
4. **`findIdsByState` has no `ORDER BY`.** `@Query("SELECT r.id FROM Replenishorder r WHERE r.state = :state")`
   — unlike `findIdsByStateAndItemdataId`, which is explicitly `ORDER BY r.id`. Two sweeps may visit orders
   in different physical orders, so "the loser retries after the winner" is not even guaranteed to hold the
   same way twice.

**Concrete tie-breaks worth specifying, in preference order:**

* **(a) Fall through to the *next* candidate instead of deferring.** `findFirst()` becomes "first candidate
  whose lock is obtainable". This is the cheapest real fix: it makes progress in the common case and removes
  the move path's cancel-on-contention regression entirely. Cost: the chosen source may not be the
  highest-available one.
* **(b) Add `ORDER BY su.amount DESC, su.id` to `getAvailableReplenishmentSources`** so the candidate order is
  a total order and not merely a partial one that Postgres happens to stabilise. Cheap, and it also makes any
  test deterministic.
* **(c) Add `ORDER BY r.id` to `findIdsByState`** for the same reason — and to match its sibling.
* **(d) Bound the deferral: log at WARN with a stable token (like the existing
  `SBDEV-3618 STRANDED_RESERVATION`) when the same order defers on the same target twice in a row**, so a
  live-lock is observable rather than silent. Note (per the existing memory) nothing scrapes Prometheus yet,
  so a log token beats a metric.

**Suggested AC:** *"An order that defers because its target was locked must be re-offered a source on a later
pass; on the unit-load-move path a deferral must never cancel the order. Pinned by a test in which thread A
holds the target for longer than one sweep interval and thread B's order is observed PROCESSABLE with a
source after the hold is released."* Confidence in the analysis: **medium-high**; the move-path cancel
regression (point 1) is **high** — it follows directly from
`if (!redirectSource(order, lockedSource, share, false)) { cancelOrder(…); }`.

---

## 8. Q5 — The most economical failing test

### 8.1 Shape: move × move, not recalc × recalc

Use §3, not §2. Rationale: move × move needs **no** candidate-snapshot divergence, **no** two-active-orders
configuration, **no** clock, and the fixture already exists. A recalc × recalc test would have to
manufacture snapshot divergence and would be fragile for exactly the reasons three prior analyses got it
wrong.

**Proposed class:** `src/test/java/net/aim_ai/wms/integration/ReplenishRedirectLockOrderIT.java`,
extending `BasePostgresIntegrationTest`, annotated `@Transactional(propagation = Propagation.NOT_SUPPORTED)`
(the two threads must see each other's committed rows). Model it on
`ReplenReassignOnNonReplenishableMoveIT` for the fixture and on `MoveCronConcurrencyIT` for the
choreography — **not** on anything that drives locks through the raw `JdbcTemplate`
(`MoveCronConcurrencyIT`'s javadoc: *"That template is bound to a standalone `DriverManagerDataSource` in
autocommit, so a `SELECT … FOR UPDATE` issued through it releases its lock at statement end … Two sibling
concurrency ITs in this repo have exactly that defect"*).

### 8.2 Fixture rows (one client, one itemdata — the cross-targeting requires same item)

| Row | Value |
|---|---|
| `client`, `itemdata` | one each |
| `location_area` REPLEN | `useforreplenish = true` |
| `location_area` LANE | `useforreplenish = false` |
| `location` LOC_1, LOC_2 | in AREA_REPLEN |
| `location` LANE_1, LANE_2 | in AREA_LANE (**two distinct destinations**, so the two moves do not serialise on the destination Location lock from §4.2 step 2 — or pass `ignoreLock=true`, as `ReplenReassignOnNonReplenishableMoveIT.move()` already does) |
| `unitload` UL_1 @ LOC_1, UL_2 @ LOC_2 | |
| `stockunit` **S1** on UL_1: `amount=100, reservedamount=10`, id **lower** | O1's source |
| `stockunit` **S2** on UL_2: `amount=100, reservedamount=10`, id **higher** | O2's source |
| `replenishorder` O1: `state=300`, `stockunit_id=S1`, `requestedamount=10`, `destination_id=DEST_1` | |
| `replenishorder` O2: `state=300`, `stockunit_id=S2`, `requestedamount=10`, `destination_id=DEST_2` | **two distinct destinations are mandatory** — `idx_replenishorder_active_item_dest` rejects two active same-item orders otherwise (§2.6). This is the single easiest way to get the fixture wrong. |

No other stock unit of this item exists, so each transaction's candidate list is exactly the other's source.
Equal `available` on both makes the choice unambiguous once each excludes its own.

### 8.3 Choreography

```
barrier = CyclicBarrier(2)
thread A: transferUnitLoadToLocation(UL_1, LANE_1, true, CODE_MANUAL_TRANSFER, …)
thread B: transferUnitLoadToLocation(UL_2, LANE_2, true, CODE_MANUAL_TRANSFER, …)
```

Both threads must hold their **own** source lock before either reaches for the other's. Production code has
no latch, so the barrier cannot sit inside `redirectSource`. Two options, in preference order:

* **Preferred — pre-seize the locks from the test.** Thread A takes `findByIdForUpdate(S1)` inside a
  `TransactionTemplate(tenantTransactionManager)`, signals, waits; thread B does the same for S2; then each
  runs its move **in that same transaction** via the template. This is the shape `MoveCronConcurrencyIT`
  uses for the cron side and it is deterministic. It does change the first-touch ordering slightly (the lock
  is already held when `reassignOrCancelForMovedStockUnit` re-locks — a no-op re-lock, not an upgrade, since
  it is the same lock mode).
* **Fallback — naked race with retries.** Start both moves simultaneously and repeat N times. Flaky; the repo
  already has two timing-flaky concurrency ITs (`OutboxConcurrentEnqueueIT`, `ReplenishDupConcurrencySliceIT`).
  Avoid.

### 8.4 The assertion — and the distinction that is the whole point

**Today's code must produce `40P01` (deadlock_detected), not `55P03` (lock_not_available).**

* `deadlock_timeout` is the PostgreSQL default **1000 ms** (measured `source = default` on Hydra prd and
  WineCo UAT, per `PostgresDeadlockDetectorControlIT`'s javadoc).
* The integration lane sets `wms.tenant.lock-timeout-ms=10000`
  (`src/test/resources/application-postgres-integration.properties:187`), **deliberately diverged from
  production's 3000** (`src/main/resources/application.properties:119`).
* `LockTimeoutHibernateJpaDialect` issues `SET LOCAL lock_timeout` per tenant transaction, **per lock
  acquisition**.

⇒ 10 000 ms ≫ 1 000 ms, so **the deadlock detector always wins in the IT lane** and `40P01` is the correct,
non-flaky expectation. **Do not shorten `wms.tenant.lock-timeout-ms` for this test** — dropping it at or
below `deadlock_timeout` converts a genuine ABBA into a `55P03` that looks exactly like ordinary
contention, which is precisely the misattribution `PostgresDeadlockDetectorControlIT` was written to warn
about.

Assertions, in order:

1. **Precondition / positive control:** assert `current_setting('deadlock_timeout')` and that the effective
   `lock_timeout` inside a tenant transaction exceeds it. Without this the red below is unattributable.
2. **Exactly one side fails.** `assertThat(failures).hasSize(1)` — both failing means the fixture serialised
   them on something else (the destination Location, or the same `requestedlocation`); neither failing means
   the cycle never formed and the test is vacuous.
3. **Unwrap to the SQLSTATE** (walk `getCause()` for a `java.sql.SQLException`, exactly as
   `ReplenishmentOrderMaintenanceService.hasSqlCause` does) and assert
   `getSQLState().equals("40P01")`, with a message naming `55P03` as the wrong answer:
   *"55P03 here means a lock_timeout fired before the detector and this test graded ordinary contention, not
   an ABBA."*
4. **Also assert `pg_stat_database.deadlocks` incremented by 1** — the counter is the instrument the whole
   severity argument rests on, and `PostgresDeadlockDetectorControlIT` already shows how to poll it
   (`PGSTAT_STAT_INTERVAL`, 500 ms; poll, never sleep).
5. **Green-side assertion after the fix:** both moves commit, **both** orders end `PROCESSABLE`, O1 bound to
   S2 and O2 bound to S1 (or, under a `SKIP LOCKED` design, the deferring order is still `PROCESSABLE` with
   a source — **never `CANCELED`**, per §7 point 1). Without this, a fix that simply cancels one order on
   contention would turn the test green while making production worse.

### 8.5 Mutation check for the new assertions (the floor requires it)

* Revert the fix (restore current→target) ⇒ step 3 must go red with `40P01`.
* Replace the fix with "defer and cancel" ⇒ step 5 must go red on `CANCELED`.
* Set `wms.tenant.lock-timeout-ms=500` in the lane ⇒ step 3 must go red with `55P03`, proving the SQLSTATE
  assertion is not a tautology.
* Seed both orders with the **same** `destination_id` ⇒ the fixture insert must fail on
  `idx_replenishorder_active_item_dest` (23505), proving the fixture is pinned to the real constraint.

---

## 9. Ranked hypotheses

| # | Hypothesis | For | Against | Confidence it is reachable |
|---|---|---|---|---|
| **1** | **move × move** — two operator moves of same-item pallets onto non-replenishable destinations | each tx excludes its own source and sees the other's; `preferredAreaId` collapses to a non-replenishable area so ordering is pure `available DESC`; no third party, no clock; AC2 of `ReplenReassignOnNonReplenishableMoveIT` proves the two-SU lock is really taken | needs two operators on the same SKU in the same ~100 ms; the self-exclusion clause depends on Hibernate auto-flushing before the native query (NOT ESTABLISHED, §3.2) | **High** |
| **2** | **web `ReplenishorderService.redirectSource` (ascending) × maintenance `redirectSource` (current→target)** | the ordering disagreement is in quoted code; the web path's guards are all *after* both locks, so no snapshot argument protects it; operator picks the target | needs a Change Source on one order concurrent with a re-source of another across the same pair | **Medium-high** |
| **3** | **multi-UL mobile (ascending TreeSet) × maintenance** — and the *same transaction* mixes both orderings, since `assignDestinationForMultiUnitLoads` runs maintenance inside it | quoted code on both sides; `recalculateOpenOrders(true)` also fires from this service, unlocked | the inner maintenance usually touches the same rows the TreeSet then re-locks (no-ops) | **Medium** |
| **4** | **recalc × recalc via snapshot divergence** (`recalculateForItem`'s own uncommitted writes, or the cooldown clock) | mechanism is real; the ungated `recalculateOpenOrders(true)` supplies the concurrency | requires two active same-item orders, which `idx_replenishorder_active_item_dest` restricts to the two-destination shape — measured **absent on 3/3 readable tenants** | **Low-medium** |
| **5** | **recalc × recalc within one snapshot** (the comment's framing) | — | **disproved** by the comparator + item-keyed-query argument in §2.3 | **Impossible** |
| **6** | 3-cycle through Location or Pickingorder *within this family* | — | recalc takes neither; move takes both strictly before Stockunit | **Not reachable** (but see §5.2: `transferStock` × move is a separate, out-of-scope hazard) |

---

## 10. NOT ESTABLISHED — open items and the probe that settles each

1. **Hibernate auto-flush before `getAvailableReplenishmentSources`.** Does the move transaction's own UL
   relocation make its own source disappear from its own candidate list?
   *Probe:* a single-threaded IT — move a UL to a lane, and inside the same transaction assert the moved SU
   is absent from `getAvailableReplenishmentSources(item, …)`. ~20 lines, no concurrency.
2. **Whether SBDEV-2624 SKU-rename-in-place re-points bound replen orders.** If not, the same-item premise
   of §2.3 can be broken by data.
   *Probe:* read the rename service for a `replenishorder` update; plus the mismatch count query in §2.3.
3. **A concrete recalc × recalc interleaving that survives §2.3's parity argument.** I established the
   mechanism (snapshot divergence) but not an end-to-end trace.
   *Probe:* only worth doing if hypothesis 1 and 2 are fixed and the residual still matters — in which case
   it is cheaper to just order the locks than to keep arguing.
4. **Production frequency.** Two of five production databases refused the query.
   *Probe:* get a read grant on `replenishorder` for `c1wh-shipitez-prd` / `nywh-shipitez-prd`, then re-run
   the §6 query. Until then every "0" in §6 is a three-tenant measurement.
5. **Whether `transferStock` × move forms a Location cycle** (§5.2). Out of SBDEV-3637's scope; it should be
   proposed as its own ticket rather than folded in.

---

## 11. What I would tell the plan author

* **Fix the move path, not just the two lines.** Ordering the two stock-unit locks inside `redirectSource`
  ascending closes hypotheses 2 and 3 and the single-SU case of hypothesis 1. It does **not** close the
  multi-SU carrier-tree case (§4.2), which needs the whole per-transaction Stockunit set locked ascending up
  front — the shape `lockOwningPickingorders` already uses for Pickingorder, in the same file's call chain.
* **Do not add `SKIP LOCKED` on the move path without an explicit non-cancel rule** (§7 point 1). As written,
  a skipped lock cancels the operator's replenishment order.
* **The comment should be replaced, not amended.** Its VERIFIED claims stand; its NOT-ESTABLISHED claim is
  pointed at the wrong cycle and its proposed mechanism (§2.4) is refuted. The three things worth preserving
  in whatever replaces it: the item-keyed candidate query with no self-exclusion; the
  `idx_replenishorder_active_item_dest` ceiling; and the fact that three sibling writers already order
  ascending.
* **Tier.** Multi-file (service + repository `ORDER BY` + test), a lock-topology change, root cause now
  known, no migration, reversible. Reads as **T2 bordering T3** — T3 if the fix extends to the carrier-tree
  set, because that touches the move choke point's global lock order.
