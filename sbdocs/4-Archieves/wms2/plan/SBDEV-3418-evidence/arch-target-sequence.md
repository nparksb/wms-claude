# SBDEV-3418 — target statement sequence for `scanGate`

Architect consult, read-only. Everything below is derived from `git show origin/develop:<path>` /
`git grep ... origin/develop` in `v2/wms2-api` at `f2ee75f1`, plus five read-only queries against
Hydra PRD (`wms2-hydra`). The local checkout is on `bugfix/SBDEV-2890-transaction-detail-ul-picks`
and was never read.

Sibling lane input reused rather than re-derived: `SBDEV-3418-evidence/laneA-finders-and-writes.md`
(finder inventory, `transferUnitLoadToLocation` internals, OSIV) and
`SBDEV-3418-evidence/db-field-evidence.md`. Where I rely on Lane A I say so; where I disagree with
it I say so.

---

## 0. Executive answer to the three questions the brief asks directly

1. **Is moving `handleTruckOffLoading` to the FRONT sufficient?** For the first-touch rule, **yes —
   trivially and for the wrong reason.** At the front the persistence context is empty, so the
   `em.clear()` detaches nothing and every subsequent locking finder is its row's first touch. But
   front placement is the **wrong position** and should be rejected: it puts `billoflading_position`
   row locks *ahead of* the `Billoflading` header lock, and `closeBOL` demonstrably takes those two
   in the opposite order (§3, C-7). It also performs a destructive DELETE before any guard has run —
   the exact shape SBDEV-3398 exists to remove. The correct position is a **dedicated phase D0 at
   the head of the write phase**, after all locks and all guards, which is where
   `MobilePalletizeWriteService` puts its own `removeBOLPositionIfExists`.

2. **What else does the clear touch?** It detaches **every** managed entity, not just
   `BillofladingPosition`. Two consequences, and they are not the same consequence:
   - *Lost writes.* Anything mutated-but-unflushed at that instant is discarded outright. Whether
     that happens depends on the native-query flush hypothesis (§4), which cannot be resolved by
     reading — so the sequence must be correct under **both** answers.
   - *Identity split.* Post-clear, a `save()` on a pre-clear reference is a `merge`: SELECT + UPDATE
     against a **new** managed instance, while the stale instance is still reachable in local
     variables. Mutating the stale one after that point writes over the fresh one.
   - ⚠ It does **not** release the row locks — see §5, where I disagree with the brief on this.

3. **Where does `billoflading_position` go?** Phase D0 (after `Billoflading`, after both `Unitload`
   hops, after `Customerorder`). It remains **unranked** and cannot be ranked — `closeBOL` touches
   that table at *two* points with different neighbours (§3, C-7), so no single placement is
   provably cycle-free. The mitigation is the same one SBDEV-3419 accepted for the palletize hop:
   40P01 → `PessimisticLockingFailureException` → operator-legible retry message from the outer
   service, not a 500.

---

## 1. Target phase sequence

New class `MobileTruckLoadingWriteService`, method `scanGate`, annotated exactly as its palletize
counterpart:

```java
@Transactional(value = "tenantTransactionManager", rollbackFor = {BusinessException.class, FacadeException.class})
```
(shape copied from `src/main/java/net/aim_ai/wms/service/mobile/MobilePalletizeWriteService.java`,
`"@Transactional(value = \"tenantTransactionManager\", rollbackFor = {BusinessException.class, FacadeException.class})"`).

`MobileTruckLoadingService` keeps every read-only method it has today (`loadOrder`, `checkPallet`,
`truckLoadingMobileDTOByBolName`, `resolveBOLType`, `getBOLManifestLocations`) and becomes the
non-transactional outer caller for `scanGate`.

### PHASE A — validation and id resolution. SCALAR reads only, no entity touch.

| # | Call | Note |
|---|---|---|
| A1 | `dto.getPalletName()` null/empty → `BusinessException("entityNotFoundForName", Unitload.class.getSimpleName(), palletName)` | pure string check, unchanged |
| A2 | `unitloadRepository.existsByLabelid(palletLabel)` → false ⇒ same `entityNotFoundForName` throw | **scalar**. Kept here, ahead of the BOL resolution, purely to preserve the message ORDER operators see today: on develop the pallet-not-found throw precedes the BOL-not-found throw (`MobileTruckLoadingService.java`, `"Optional<Unitload> palletOpt = unitloadRepository.findByLabelid(truckLoadingMobileDTO.getPalletName());"` sits above `"billofladingRepository.findByName(truckLoadingMobileDTO.getSelectedBOLName())"`). Locking the BOL first would silently swap them. Same precedent and same justification as `MobilePalletizeWriteService`'s A3: *"kept AHEAD of the order lookup because that is the ordering the operator-visible messages rely on today. It is a SCALAR probe, so it creates no EntityEntry"* |
| A3 | `dto.getSelectedBOLName()` null/empty → `BusinessException("entityNotFoundForName", Billoflading.class...)` | unchanged |
| A4 | **NEW** `billofladingRepository.findIdByName(String)` → `Long bolId`; null ⇒ `EntityNotFoundException("BillOfLading not found by name: …")` | **scalar**, must be added — `BillofladingRepository` has only `Optional<Billoflading> findByName(@Param("name") String name)`, which materialises. See §6 on the non-unique hazard |
| A5 | `dto.getScannedGateName()` null/empty → `BusinessException("entityNotFoundForName", Location.class...)` | unchanged |
| A6 | **NEW** `locationRepository.findIdByName(String)` → `Long gateId`; null ⇒ same throw | **scalar**, must be added. `LocationRepository` has `Optional<Location> findByName(@Param("name") String name)` and no scalar sibling (derived from a full read of the interface's declared methods; blind spot: a method added on an unmerged branch). Resolving the gate as an **entity** here is a live first-touch violation — see §3, C-8 |
| A7 | `userRepository.findByName(SecurityContextUtils.getUserName())` → `operator` | entity touch on `User`, which nothing in this transaction locks, so it is harmless. Needed by `BillofladingPositionService.createEntity(Billoflading, User)` |

### PHASE B — acquire locks, in the canonical TABLE order.

| # | Call | Class |
|---|---|---|
| B1 | `billofladingRepository.findByIdForUpdate(bolId).orElseThrow(...)` → `bol` | **Billoflading** |
| B2 | `unitloadRepository.findByLabelidForUpdate(palletLabel).orElseThrow(new BusinessException("entityNotFoundForName", Unitload.class.getSimpleName(), palletLabel))` → `pallet` | **Unitload (pallet)** |
| B3 | **NEW** `unitloadRepository.findIdsByCarrierunitloadId(pallet.getId())` → `List<Long>`, then `.distinct().sorted().forEach(id -> locked.put(id, unitloadRepository.findByIdForUpdate(id).orElseThrow(...)))` into a `LinkedHashMap<Long, Unitload>` | **Unitload (parcels), asc by PARCEL id** |
| B4 | `stockunitRepository.findByUnitloadId(parcelId)` per parcel, iterated in the same asc-parcel-id order; collect into `Map<Long, List<Stockunit>>` | **Stockunit — read UNLOCKED, at the canonical position.** See §3, C-4 for the reasoning and the residual |
| B5 | **NEW** `customerorderRepository.findParcelOrderIdsByParcelIdIn(Collection<Long>)` → `List<ParcelOrderIdView>` (`parcelId`, `orderId`). Derive: (a) the `parcelId → orderId` map, (b) `Set<Long>` of distinct order ids sorted asc, (c) the duplicate and the orphan diagnoses. Then `sortedOrderIds.forEach(id -> customerorderRepository.findByIdForUpdate(id).orElseThrow(...))` | **Customerorder, asc by ORDER id** |
| B6 | `customerorderPositionRepository.findByOrderId(orderId)` once per order, in the same asc order; collect into `Map<Long, List<CustomerorderPosition>>` | **CustomerorderPosition — read UNLOCKED, at the canonical position.** Also removes an N+1: develop calls this once per *stockunit* (`MobileTruckLoadingService.java`, `"for (CustomerorderPosition customerOrderPosition : customerorderPositionRepository.findByOrderId(order.getId()))"` nested inside the stockunit loop) |

### PHASE C — every guard, evaluated against the LOCKED instances. **Predicates only — no mutation.**

| # | Guard | Change from develop |
|---|---|---|
| C1 | Gate reconciliation. If `bol.getOutboundlocationId() == null` ⇒ record `pendingOutboundLocationId = gateId` (do **not** set it). Else if `!bol.getOutboundlocationId().equals(gateId)` ⇒ **NEW** `locationRepository.findNameById(bolOutboundLocId)` (scalar) and throw `BusinessException("scannedAndRequiredGateDiffer", scannedGateName, thatName)` | develop mutates here (`"billOfLading.setOutboundlocationId(gate.getId());"`) and resolves the other location as an entity (`"locationRepository.findById(bolOutboundLocId)"`) |
| C2 | BOL state switch, **validation half only**: `CREATED`/`OPEN` ⇒ record `pendingState = TRUCK_LOADING`; `TRUCK_LOADING` ⇒ no change; `TRANSFER`/`CLOSED`/`CANCELLED` ⇒ `BusinessException("billOfLadingUnxepectedStateFound", …)`; default ⇒ `RuntimeException` | develop mutates inside the `case OPEN:` arm (`"billOfLading.setState(WmsConstants.BillOfLadingState.TRUCK_LOADING);"`) |
| C3 | Orphan parcel: any parcel id in B3 with no entry in B5's map ⇒ `BusinessException("unexpectedUnitLoadDoesNotHaveOrder", parcel.getLabelid())` | develop raises this **inside the write loop**, after earlier `billofladingPositionRepository.save(...)` calls have already run |
| C4 | Duplicate order per parcel: any parcel id mapped to >1 order id ⇒ `BusinessException("Too many orders with the same parcel found")` | same — develop raises it mid-loop (`"throw new BusinessException(\"Too many orders with the same parcel found\");"`) |
| C5 | **PROPOSED, not in develop:** re-evaluate `checkPallet`'s BOL-position state guard here, against locked data. See §6 |

### PHASE D0 — the stale-position purge. A persistence-context barrier.

```
mobileTransferService.handleTruckOffLoading(palletLabel)   // or the no-clear variant, §4
```

Invariants this position guarantees, and each is load-bearing:
- **Zero pending writes exist.** PHASE C is predicate-only by construction, and every entity locked
  in B is clean. So whatever the flush hypothesis (§4) resolves to, nothing can be lost.
- **No managed `BillofladingPosition` exists.** `scanGate`'s only `BillofladingPosition` reads are
  inside `BillofladingPositionService.createEntity`, which runs in PHASE D. That is what makes
  `clearAutomatically` unnecessary on this path.
- Every guard has already passed, so the DELETE only ever runs on a scan that is going to succeed.

### PHASE D — writes. Every row is locked, every guard has passed.

| # | Call |
|---|---|
| D1 | apply `pendingOutboundLocationId` / `pendingState` to `bol`; `billofladingRepository.save(bol)` |
| D2 | `locationRepository.findByIdForUpdate(gateId).orElseThrow(...)` → `gate`. **This is the Location row's first entity touch** |
| D3 | `unitloadBusinessService.transferUnitLoadToLocation(pallet, gate, false, WmsConstants.CODE_TRUCK_LOADING, bol.getNumber(), null)` — its own `locationRepository.findByIdForUpdate(...)` is now a WRITE→WRITE re-lock, not an upgrade (§3, C-8) |
| D4 | `palletBOLPos = billofladingPositionService.createEntity(bol, operator)`; `setSourceId(pallet.getId())`; `save` |
| D5 | per parcel, **in asc parcel-id order** (reuse B3's `LinkedHashMap` iteration order, not `findByCarrierunitloadId`'s): `createEntity` → `setCarrierId(palletBOLPos.getId())`, `setSourceId(parcel.getId())`, `setOrderId(map.get(parcelId))`, `save` |
| D6 | per stockunit of that parcel (B4's map): `createEntity` → `setCarrierId(parcelBOLPos.getId())`, `setItemdataId`, `setAmount`, match `orderpositionId` from B6's map, `save`; keep the existing `LOG.warn("no itemData matches customerOrderPosition in parcel={} …")` fallback |
| D7 | per locked order, asc: `if (order.getState() < LOADED_TO_TRUCK) { setState(LOADED_TO_TRUCK); save; }` |
| D8 | return `new TruckLoadOutcome(lockedOrders, pallet, bol, gate.getName())` — built from the instances **actually in hand at the end of D**, never from pre-D0 references |

### PHASE E — outer service, no transaction open.

`MobileTruckLoadingService.scanGate(dto)`:
```
try { outcome = writeService.scanGate(dto); }
catch (PessimisticLockingFailureException e) { throw lockContention(e, dto.getPalletName()); }

dto.setBolGateName(outcome.bolGateName());
dto.setManifestLocationsOnPallet(null);
dto.setManifestLocationsOnBOL(dto.getSelectedBOLName());

try { manageOrderService.customerOrderLoadedToTruck(outcome.orders(), outcome.pallet(), outcome.bol()); }
catch (Exception e) { LOG.error("OMS notification failed: {} - {}", e.getClass().getSimpleName(), e.getMessage()); }
```
Shape and both javadoc warnings copied verbatim from `MobilePalletizingService`
(`"private void notifyPalletized(PalletizeOutcome outcome)"` and
`"private BusinessException lockContention(PessimisticLockingFailureException cause, String scannedLabel)"`).
The `catch (Exception)` is the one already at the call site on develop; it moves out of the boundary
unchanged. Detached entities crossing the boundary is the established precedent —
`PalletizeOutcome(Customerorder order, Unitload pallet)` does exactly this, and
`ManageOrderService.customerOrderLoadedToTruck` only reads scalar fields plus its own repository
lookups (`"Unitload parcel = unitloadRepository.findById(customerOrder.getParcelId()).orElse(null);"`),
each of which opens its own read transaction with OSIV off.

---

## 2. Row class → id source → locking finder → phase

| Row class | How its id is obtained | Which finder locks it | Phase | Exists today? |
|---|---|---|---|---|
| `Billoflading` | **NEW** scalar `findIdByName(bolName)` | `billofladingRepository.findByIdForUpdate(bolId)` | A4 → B1 | finder yes, projection **no** |
| `Unitload` (pallet) | not needed — label is the key | `unitloadRepository.findByLabelidForUpdate(palletLabel)` | B2 | yes |
| `Unitload` (parcels) | **NEW** scalar `findIdsByCarrierunitloadId(palletId)`, `.distinct().sorted()` | loop `unitloadRepository.findByIdForUpdate(id)` | B3 | finder yes, projection **no** |
| `Stockunit` | n/a | **none — unlocked `findByUnitloadId`** | B4 | n/a |
| `Customerorder` | **NEW** projection `findParcelOrderIdsByParcelIdIn(parcelIds)` → (parcelId, orderId); distinct order ids `.sorted()` | loop `customerorderRepository.findByIdForUpdate(id)` | B5 | finder yes, projection **no** |
| `CustomerorderPosition` | n/a | **none — unlocked `findByOrderId`**, one call per order | B6 | n/a |
| `BillofladingPosition` | `findBolIdByUnitLoadLabelId` + `findBolCarrierIdListByUnitLoadLabelId` (both already scalar) | no read lock exists; the two bulk DELETEs take the row locks | D0 | yes |
| `Location` (gate) | **NEW** scalar `findIdByName(gateName)` | `locationRepository.findByIdForUpdate(gateId)` | A6 → D2 | finder yes, projection **no** |
| `Location` (BOL's existing outbound, throw path only) | `bol.getOutboundlocationId()` | **NEW** scalar `findNameById(id)` — no entity touch, no lock | C1 | **no** (`UnitloadRepository.findNameById` is the shape precedent) |
| `User` (operator) | `SecurityContextUtils.getUserName()` | none needed | A7 | yes |

Five new scalar projections and one new view. Lane A independently reached the same conclusion for
four of them: *"all five id-resolution methods themselves would have to be newly added"*.

### Multi-row locked finder, or a loop over `findByIdForUpdate`?

**The loop, for both parcels and orders.** Grounds:

- The repo already does exactly this, in the sibling path this ticket must not deadlock against:
  ```java
  rawOrders.stream()
          .map(Customerorder::getParcelId)
          .filter(Objects::nonNull)
          .distinct()
          .sorted()
          .forEach(parcelId -> lockedParcels.put(parcelId,
                  unitloadRepository.findByIdForUpdate(parcelId)
                          .orElseThrow(() -> new EntityNotFoundException("UnitLoad", parcelId))));
  ```
  `file: src/main/java/net/aim_ai/wms/service/ParcelMonitorViewService.java`. That block is pinned by
  `ParcelMonitorViewServiceUnitTest#palletise_shouldLockParcelUnitloadsBeforeCustomerorders`, and its
  own comment states the sort key is contractual: *"Sorted by PARCEL id, which is deliberately not
  the customerorder order used below — the two permutations disagree for 47.55% of order/parcel pairs
  on WineCo UAT, so the sort key is part of the contract."* Using the same shape means one pinned
  idiom covers both palletize and truck-load.
- No multi-row locked finder exists for `Unitload` or `Customerorder` in any shape (Lane A, full-file
  reads of both interfaces; blind spot: an unmerged branch), so either option is new code.
- The one multi-row `@Lock` precedent carries a standing warning against the shape:
  `CustomerorderPositionRepository.findByOrderIdForUpdate` is annotated *"SBDEV-3250 ⚠ MULTI-ROW LOCK:
  locks every position of the order; orderId is a plain FK, so the row count is caller-uncontrolled
  … the worst case here is (rows matched) x the bound rather than the bound."*
- A multi-row `SELECT … ORDER BY id FOR UPDATE` does not give the ordering guarantee people assume:
  under concurrent update PostgreSQL re-fetches and re-locks the updated row out of sort position.
  The loop is deterministic by construction.
- `distinct()` is not optional. Two orders can name the same parcel; re-locking an already-managed
  row at the same level is harmless, but the `LinkedHashMap` is also the D5 iteration order, so a
  duplicate would double-write a BOL position.

**Measured fan-out (Hydra PRD, `wms2-hydra`, today):** max parcels on one pallet = **70**; max
stockunits summed across one pallet's parcels = **88**. With `wms.tenant.lock-timeout-ms=3000`
(`src/main/resources/application.properties`) applied **per acquisition**, a worst-case pallet costs
`1 + 1 + 70 + (≤70 orders) ≈ 142` acquisitions → a theoretical worst-case wait of ~7 minutes before
the scan fails. That is a genuine new exposure introduced by this fix and it belongs in the plan's
risk section. Queries in §7.

---

## 3. Ordering constraints, and the failure each violation produces

| # | Constraint | Violating it produces |
|---|---|---|
| **C-1** | `Billoflading` (B1) before both `Unitload` hops | ABBA against `closeBOL`, which takes `billofladingRepository.findByIdForUpdate(bolId)` as its first lock (`BillofladingService.java`, *"Acquire pessimistic lock on the BOL row to prevent concurrent closeBOL"*) and only later bulk-UPDATEs `Unitload`. 40P01 for one of the two sessions |
| **C-2** | pallet (B2) before parcels (B3); parcels **asc by parcel id** | AB/BA with a concurrent `scanGate` or `ParcelMonitorViewService.palletise` on an overlapping parcel set. The palletize javadoc records the measured basis: *"27.32% of 480,334 (pallet, child) pairs have the child physically ahead of its pallet"* |
| **C-3** | parcels (B3) before orders (B5) | The exact cycle SBDEV-3419 closed: a unitload lock taken after a customerorder lock is an ABBA against `closeBOL`, whose order was measured off `pg_locks` by `ClosebolLockOrderProbeIT` |
| **C-4** | `Stockunit` read (B4) between the parcel locks and the order locks | If scanGate ever takes a **lock** here it must be at this position or it re-opens C-3 in the stockunit dimension. Reading unlocked at the right position costs nothing and pre-positions the upgrade |
| **C-5** | orders **asc by order id**, and `distinct()` | Two `scanGate`s on overlapping order sets in opposite id order deadlock. `ParcelMonitorViewService` pins the same key: `rawOrders.sort(Comparator.comparing(Customerorder::getId))` |
| **C-6** | Every locking finder is its row's **first** touch (SBDEV-3244) | `StaleObjectStateException` thrown from **inside** the repository call, marking the transaction rollback-only. Uncontended it throws nothing, so every test that does not reproduce the race is green either way — the failure mode the palletize javadoc calls out in bold |
| **C-7** | `billoflading_position` (D0) after all four canonical classes | Unrankable — see below. Violating the *stated* placement by moving D0 to the front produces a demonstrable cycle against `closeBOL` (next row) |
| **C-8** | The gate `Location` is resolved by **scalar id** in A6 and first touched as an entity by a **locked** read in D2 | This is a **live defect on develop**, not a hypothetical. Today `scanGate` does `locationRepository.findByName(gateName)` (LockMode NONE, creates an `EntityEntry`), and then `transferUnitLoadToLocation` does `locationRepository.findByIdForUpdate(destinationLocationId)` on that same row — a textbook lock upgrade. Under contention on a shared gate that is a `StaleObjectStateException` from inside the repository call. The `Location` row is a **gate**, i.e. the single hottest shared row on this path |
| **C-9** | No mutation may exist above D0 | If the native-query flush hypothesis (§4) is false, the `em.clear()` silently discards the BOL header UPDATE and every unitload UPDATE `transferUnitLoadToLocation` queued. Silent, committed-looking, no exception |
| **C-10** | D0 before any `createEntity` call | `findBolIdByUnitLoadLabelId(palletLabel)` matches `bp.source_id = pallet.id` — i.e. the pallet position D4 just inserted — and `findBolCarrierIdListByUnitLoadLabelId` matches its children. Running the purge after D4/D5 deletes the entire BOL position tree this scan just built |
| **C-11** | WRITE→WRITE re-lock is safe; NONE→WRITE is not | Relied on twice (D2→D3's inner re-lock, and any post-clear re-acquisition). Grounded in `MobilePalletizeWriteService`: *"the entity is already at EntityEntry lock level WRITE (SBDEV-3244), which is Hibernate's highest internal mode, so this is not an upgrade, no version check runs, and nothing can throw"* |

### Why front placement of D0 is specifically rejected

`closeBOL`'s statement order in `BillofladingService.closeBOL` is, reading source top-to-bottom:

1. `billofladingRepository.findByIdForUpdate(bolId)` — **Billoflading** row lock
2. `billofladingPositionRepository.findByBillofladingId(...)` — unlocked read
3. ```java
   entityManager.createQuery("DELETE FROM BillofladingPosition bp WHERE bp.id IN :ids")
           .setParameter("ids", garbageIds)
           .executeUpdate();
   ```
   — a bulk JPQL DELETE, executed immediately, taking **`billoflading_position` row locks** here.
   Conditional on `!garbageIds.isEmpty()`
4. unlocked `findAllById` prefetches of `Customerorder` / `Unitload`
5. `billofladingPositionRepository.saveAll(allBolPosToSave)` / `customerorderRepository.saveAll(...)`
   / `customerorderPositionRepository.saveAll(...)` — dirty entities, UPDATEs deferred to a flush
6. `entityManager.createQuery("UPDATE Unitload u SET u.storagelocationId = :shippedLocationId, …")`
   — **Unitload** row locks
7. `entityManager.createQuery("UPDATE Stockunit s SET s.entityLock = :lock, …")` — **Stockunit**
8. commit flush issues the step-5 UPDATEs — **Customerorder** and **`billoflading_position` again**

So `closeBOL` touches `billoflading_position` at **step 3** (between Billoflading and Unitload) and
again at **step 8** (after Customerorder). Two positions with different neighbours.

- **Front placement** ⇒ `scanGate` holds `bolpos(P)` and waits for `Billoflading(X)`; `closeBOL`
  holds `Billoflading(X)` at step 1 and waits for `bolpos(P)` at step 3. A cycle, from source, with
  no measurement needed.
- **D0 placement** ⇒ `scanGate` holds `Unitload`/`Customerorder` and waits for `bolpos`; `closeBOL`
  can hold `bolpos` at step 3 and want `Unitload` at step 6. Also a cycle.

Both are cycles. D0 is preferred anyway because it is the only placement that also satisfies C-9,
C-10 and the guards-before-destructive-writes rule, and because it matches the pinned precedent
(`MobilePalletizeWriteService` PHASE D, *"the class order must match `ParcelMonitorViewService.palletise`"*).
This is a **choice among unrankable options**, and the plan must say so rather than claim safety.

Instrument note: steps 1–8 are read from source order, **not** measured off `pg_locks`. Its blind
spot is precisely steps 5/8 — Hibernate decides when to flush, so a source reading cannot place
them. `ClosebolLockOrderProbeIT` exists and does measure; extending it to record
`billoflading_position` acquisitions is the concrete next probe and is the only way to turn the
above from "two source-visible positions" into a ranked fact.

---

## 4. The native-query flush hypothesis, and how the sequence depends on it

The hypothesis: `handleTruckOffLoading`'s first statement is
```java
Long bolPositionId = billofladingPositionRepository.findBolIdByUnitLoadLabelId(unitLoadLabel);
```
whose query is `nativeQuery = true`
(`src/main/java/net/aim_ai/wms/repo/jpa/BillofladingPositionRepository.java`,
`"@Query(value = \"select bp.id \" + \"from billoflading_position bp \" + …, nativeQuery = true)"`)
with no declared synchronized query spaces. Hibernate cannot compute affected spaces for such a
query, so under `FlushMode.AUTO` it may conservatively flush the whole session first.

**I have not measured it and neither should the plan assume it.** The sequence above is correct
under both answers:

- **If TRUE** — everything pending is written before the DELETEs, so the `em.clear()` can only cause
  the *identity split*, never a lost write. D0 placement plus C-9 still holds.
- **If FALSE** — pending writes are discarded by the clear. C-9 (no mutation above D0) is then the
  *only* thing preventing silent data loss, which is exactly why C-9 is a hard constraint rather
  than a tidiness preference.

**How to measure it, one test:** inside a `@Transactional` integration test, mutate a managed
`Billoflading` (no `save`, no `flush`), call `findBolIdByUnitLoadLabelId`, then `entityManager.clear()`,
then re-read the row with a fresh `EntityManager`/native query and assert whether the mutation
survived. Green = TRUE, red = FALSE. Do **not** infer it from Hibernate documentation; the repo
already has one case (`UserRoleUserFunctionRepository`, *"`flushAutomatically = true` is an
intentional no-op under this shape"*) where the obvious reading of the annotation was wrong.

### Recommended belt-and-braces: stop relying on the answer

Both deletes are
```java
@Modifying(clearAutomatically = true)
@Transactional
@Query("DELETE FROM BillofladingPosition bp WHERE bp.carrierId IN :carrierIds")
void deleteBolPositionsCarrierIds(@Param("carrierIds") List<Long> carrierIds);
```
`file: src/main/java/net/aim_ai/wms/repo/jpa/BillofladingPositionRepository.java` (the other is
`deleteBolPositionById`, same annotations).

Recommendation, in preference order:

1. **Drop `clearAutomatically` and add `flushAutomatically = true` on both.** `clearAutomatically`
   exists to evict stale managed `BillofladingPosition` instances; if no caller holds one across the
   delete, it is pure cost and pure hazard. `flushAutomatically = true` is already precedented in
   this repo (`UserGroupRepository`, `UserRepository`, `UserRoleRepository`,
   `UserGroupUserRepository`, `UserGroupUserRoleRepository`, `UserRoleUserFunctionRepository` —
   `git grep -n "flushAutomatically" origin/develop -- src/main`). **Required check before doing
   this:** that `MobileMoveUnitloadService.scanDestination` — the other caller — holds no managed
   `BillofladingPosition` across its `handleTruckOffLoading(dto.getUnitLoadLabel())` call. I did not
   verify that; it is a read of one method and belongs in the plan's evidence, not in an assumption.
2. If (1) cannot be cleared, add **no-clear sibling methods** used only by the new write service.
3. If neither, keep the clear and add an explicit post-D0 re-acquisition of `bol` and of every
   `Customerorder` about to be mutated, via `findByIdForUpdate` — post-clear these are fresh reads,
   not upgrades, and the DB lock is already held so each returns immediately. Cost: up to 71 extra
   round-trips on a worst-case pallet.

**Sibling finding, worth its own row on the ticket:** on
`MobileMoveUnitloadService.scanDestination` the same two deletes run **inside an open transaction
today** (that method is `@Transactional(value = "tenantTransactionManager", rollbackFor = …)` and
calls `handleTruckOffLoading` immediately after
`unitloadBusinessService.transferUnitLoadToLocation(sourceUnitLoad, destinationStorageLocation, false, WmsConstants.CODE_TRANSFER, null, null)`),
with pending unitload UPDATEs live at the clear. If the flush hypothesis is FALSE, that is a live
silent-data-loss path on develop that SBDEV-3418 does not touch. Fixing the annotations (option 1)
fixes it; moving `scanGate`'s call does not. Attribution: Lane A established that `scanDestination`
is transactional; the *consequence* is mine.

---

## 5. Where I think the brief is wrong

### 5.1 `em.clear()` does not "defeat any lock taken before the clear"

The brief states: *"any later `save()` on it becomes a merge — a fresh SELECT plus an UPDATE, which
also DEFEATS ANY LOCK taken before the clear."*

A `SELECT … FOR UPDATE` row lock is held by the **database transaction** and is released only at
COMMIT or ROLLBACK. `EntityManager.clear()` operates on the JPA persistence context; it issues no
SQL, touches no connection state, and cannot release a PostgreSQL row lock. After the clear, the
transaction still holds every lock it took, no other session can have modified those rows, and the
merge's fresh SELECT therefore reads exactly the values we locked. Mutual exclusion is intact.

What the clear actually destroys is **Hibernate's `EntityEntry` bookkeeping**, and the direction of
that effect is the opposite of what the brief implies: post-clear, a `findByIdForUpdate` on an
already-locked row is a *fresh* read rather than an upgrade, so it is **safer**, not less safe —
it re-issues `SELECT … FOR UPDATE`, PostgreSQL sees the lock is already ours, and it returns
immediately with no version check. The first-touch rule is satisfied again on the far side of a
clear.

This matters for the plan because it changes which mitigation is required. If the clear defeated
locks, D0 would have to move or the locks would have to be re-taken for correctness. It does not,
so the only real hazards are **lost unflushed writes** (C-9, §4) and the **identity split**
(a stale pre-clear reference mutated after a fresh instance has been loaded). Those are the two
things the sequence defends against, and the mitigations are different from the ones a
"locks are lost" reading would prescribe.

I would not change any of the sequence above on this point — C-9 and the D0 barrier are required
either way — but the plan's rationale should state the real mechanism, because a plan that claims
"the clear drops our locks" will invite a reviewer to add lock re-acquisition that costs 142
round-trips and buys nothing.

### 5.2 Everything else in the brief holds

The canonical TABLE order, the first-touch rule, the outer/inner split, and OMS-outside-the-boundary
all reproduce faithfully against `origin/develop` and I found nothing contradicting them. The
ClickUp description's older order is indeed superseded — `MobilePalletizeWriteService`'s javadoc
carries the current one verbatim (*"Billoflading → Unitload (pallet, then parcels asc by PARCEL id)
→ Stockunit → Customerorder asc → CustomerorderPosition"*) together with the record of the
withdrawal.

---

## 6. What is still unranked or unproven after this change

1. **`billoflading_position` is unranked and cannot be ranked from source** (§3). `closeBOL` touches
   it at two points with different neighbours. Every placement of D0 leaves a source-visible cycle
   with one of them. Accepted residual, same terms as SBDEV-3419's `removeBOLPositionIfExists` hop:
   40P01 → `PessimisticLockingFailureException` → the outer service's operator-legible retry
   message, not a 500. Next probe: extend `ClosebolLockOrderProbeIT` to record
   `billoflading_position` acquisitions off `pg_locks`.
2. **The unitload-vs-unitload cycle against `closeBOL` is untouched by this ticket.** The palletize
   javadoc records it as open: `closeBOL`'s bulk UPDATE carries no `ORDER BY`, its plan is a Bitmap
   Heap Scan, and 27.32% of 480,334 (pallet, child) pairs are physically out of order. `scanGate`
   locking pallet-then-parcels inherits that cycle exactly as `scanPallet` does.
3. **`Location` remains unranked.** C-8 fixes the upgrade, not the ordering. `closeBOL` takes no
   Location lock (it reads `locationRepository.findByName(WmsConstants.STORAGE_LOCATION_SHIPPED)`
   unlocked), so there is no cycle *with closeBOL*; cycles with other `transferUnitLoadToLocation`
   callers are not analysed here.
4. **`Stockunit` and `CustomerorderPosition` are read unlocked**, so `billoflading_position.amount`
   and `.orderposition_id` are non-repeatable reads. I recommend accepting this rather than paying
   88 + N extra lock acquisitions, but the recommendation is **not evidence-backed**: I did not
   enumerate the writers of `stockunit.amount` for a packed parcel already at a gate. Named probe:
   `git grep` the setters plus a UAT query for stock movement on parcels with a `TRUCK_LOADING` BOL
   position. If a real writer exists, swap B4/B6 to `getStockUnitsByItemDataIdForUpdate`-style and
   `findByOrderIdForUpdate` **at the same positions** — the sequence is already correct for it.
5. **`billoflading.name` has no unique index.** Hydra PRD `public.billoflading` carries only
   `billoflading_pkey`; there is no unique index on `name` (derived from `pg_index`, so it would
   miss a constraint enforced only in application code — there is none in
   `BillofladingRepository`). So a scalar `findIdByName` can throw
   `IncorrectResultSizeDataAccessException`. This is **not a regression**: today's
   `Optional<Billoflading> findByName` throws `NonUniqueResultException` on the same input. 0
   duplicate names exist on Hydra PRD today. Same shape applies to `findBolIdByUnitLoadLabelId`,
   which returns a bare `Long` from a query joining `unitload` (labelid **is** uniquely indexed,
   twice) to `billoflading_position.source_id` (**not** unique): 0 sources carry >1 position on
   Hydra PRD today, so the hazard is latent, matching `db-field-evidence.md` §5.
6. **`(billoflading_id, number)` has no unique index on Hydra PRD either** — confirmed against
   `pg_index`. So the duplicate-number defect Lane A traced to
   `BillofladingPositionService.createEntity`'s unlocked read-modify-write
   (`"String number = basicService.generatePositionNumber(billOfLading.getNumber(), bolPositions.size());"`)
   cannot be caught by the database. **The B1 BOL lock closes it for this path as a side effect** —
   two `scanGate`s on the same BOL now serialise at B1, so their `bolPositions.size()` reads cannot
   interleave. It does **not** close it against any other producer of positions for the same BOL
   that does not take the BOL lock; I did not enumerate those producers. Do not weaken B1 to an
   unlocked read on the grounds that "scanGate sometimes doesn't mutate the BOL" — B1 is
   load-bearing for the numbering even when the header is unchanged.
7. **`checkPallet`'s BOL-position state guard is never re-evaluated in `scanGate`** (C5, proposed).
   `checkPallet` and `scanGate` are two separate HTTP POSTs, so its verdict is check-then-act across
   a network round trip. An operator who reaches `scanGate` directly, or whose pallet acquired a
   `CLOSED` position between the two calls, bypasses it. Proposing, not filing, per the ticket
   policy — this is a behaviour change with its own blast radius.
8. **Lock fan-out is a new exposure.** Up to ~142 acquisitions at 3000 ms each on a worst-case Hydra
   PRD pallet. Nothing on develop takes this many locks on the handheld path today. Worth an
   explicit risk row and, ideally, a p99 measurement of parcels-per-pallet rather than the max.

---

## 7. Queries and commands behind the measured claims

```sql
-- unique indexes (Hydra PRD, schema public)
SELECT c.relname, i.relname, ix.indisunique, pg_get_indexdef(i.oid)
FROM pg_index ix JOIN pg_class i ON i.oid=ix.indexrelid JOIN pg_class c ON c.oid=ix.indrelid
JOIN pg_namespace n ON n.oid=c.relnamespace
WHERE c.relname IN ('billoflading','billoflading_position','location','unitload') AND n.nspname='public';
-- → billoflading: PK only, no unique on name
-- → billoflading_position: PK only, no unique on (billoflading_id, number)
-- → location: uk_sahixf1v7f7xns19cbg12d946 UNIQUE (name)
-- → unitload: uq_unitload_labelid + uk_s2ujivixnde5dqb2stih8m2vh, both UNIQUE (labelid)

-- fan-out and latent-duplicate counts (Hydra PRD)
SELECT 'dup_bol_name', count(*) FROM (SELECT name FROM billoflading GROUP BY name HAVING count(*)>1) x
UNION ALL SELECT 'multi_bolpos_per_source', count(*) FROM (SELECT source_id FROM billoflading_position WHERE source_id IS NOT NULL GROUP BY source_id HAVING count(*)>1) y
UNION ALL SELECT 'dup_bolid_number', count(*) FROM (SELECT billoflading_id, number FROM billoflading_position GROUP BY 1,2 HAVING count(*)>1) z
UNION ALL SELECT 'max_stockunits_per_pallet', COALESCE(max(cnt),0) FROM (SELECT p.id, count(su.id) cnt FROM unitload p JOIN unitload c ON c.carrierunitload_id=p.id LEFT JOIN stockunit su ON su.unitload_id=c.id GROUP BY p.id) w
UNION ALL SELECT 'max_parcels_per_pallet', COALESCE(max(cnt),0) FROM (SELECT carrierunitload_id, count(*) cnt FROM unitload WHERE carrierunitload_id IS NOT NULL GROUP BY 1) v;
-- → 0, 0, 0, 88, 70
```

```bash
git show origin/develop:src/main/java/net/aim_ai/wms/service/mobile/MobileTruckLoadingService.java
git show origin/develop:src/main/java/net/aim_ai/wms/service/mobile/MobilePalletizeWriteService.java
git show origin/develop:src/main/java/net/aim_ai/wms/service/mobile/MobilePalletizingService.java
git show origin/develop:src/main/java/net/aim_ai/wms/service/ParcelMonitorViewService.java
git show origin/develop:src/main/java/net/aim_ai/wms/service/BillofladingService.java   # closeBOL
git show origin/develop:src/main/java/net/aim_ai/wms/repo/jpa/{Billoflading,BillofladingPosition,Unitload,Stockunit,Customerorder,CustomerorderPosition,Location}Repository.java
git grep -n "flushAutomatically" origin/develop -- src/main
git grep -n "findByIdForUpdate" origin/develop -- 'src/main/java/net/aim_ai/wms/service'
```

**Blind spots of the instruments above, stated inline where the claims are made, and collected here:**
`git grep`/`git show` against `origin/develop` cannot see an unmerged branch. The `closeBOL`
statement ordering in §3 is a **source** reading, whose specific blind spot is Hibernate-scheduled
flushes (steps 5 and 8) — only `pg_locks` can place those, which is why extending
`ClosebolLockOrderProbeIT` is named as the probe. The `pg_index` query sees database-enforced
uniqueness only, not application-enforced. The Hydra PRD fan-out figures are one tenant at one
moment and are maxima, not a distribution. I did not verify whether
`MobileMoveUnitloadService.scanDestination` holds a managed `BillofladingPosition` across its
`handleTruckOffLoading` call — §4 option 1 depends on that and names it as a required check.
I did not enumerate writers of `stockunit.amount` — §6.4 names that probe. The native-query flush
question in §4 is stated as an open hypothesis with a one-test resolution; nothing in this document
assumes either answer.
