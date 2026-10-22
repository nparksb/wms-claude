# SBDEV-3418 Lane A — Locking finders and write-path inventory

Read-only fact gathering against `origin/develop` (`f2ee75f1`), repo `v2/wms2-api`. All content
below is quoted from `git show origin/develop:<path>` / `git grep ... origin/develop`, never from
the local checkout (which is on an unrelated branch). Method line numbers are omitted where the
file is likely to drift; every claim carries a `file` + a quoted, distinctive snippet instead.

---

## 1. Locking finders available

### `BillofladingRepository`
Exactly one locking method, single-row:
```java
@Lock(LockModeType.PESSIMISTIC_WRITE)
@Query("SELECT b FROM Billoflading b WHERE b.id = :id")
@RestResource(exported = false)
Optional<Billoflading> findByIdForUpdate(@Param("id") Long id);
```
`file: src/main/java/net/aim_ai/wms/repo/jpa/BillofladingRepository.java`

No other `ForUpdate`/`@Lock` method in the interface (full file read; confirmed by `git grep -n
"ForUpdate\|@Lock" origin/develop -- '*/BillofladingRepository.java'`, one hit block only).

### `UnitloadRepository`
Two locking methods, both single-row:
```java
@Lock(LockModeType.PESSIMISTIC_WRITE)
@Query("SELECT u FROM Unitload u WHERE u.id = :id")
@RestResource(exported = false)
Optional<Unitload> findByIdForUpdate(@Param("id") Long id);
```
```java
@Lock(LockModeType.PESSIMISTIC_WRITE)
@Query("SELECT u FROM Unitload u WHERE u.labelid = :labelid")
@RestResource(exported = false)
Optional<Unitload> findByLabelidForUpdate(@Param("labelid") String labelid);
```
`file: src/main/java/net/aim_ai/wms/repo/jpa/UnitloadRepository.java`

**No multi-row locked finder exists for unitload at all** — no method takes a `List<Long>`/
`Collection<Long>` of unitload ids (or a parent/pallet id) and returns a locked `List<Unitload>`.
The only multi-row unitload finders in the file (`findByCarrierunitloadId`, `findByCarrierunitloadIdIn`,
`findByLabelidIn`, `findByStoragelocationIdIn`) are all plain (unlocked) reads.

### `StockunitRepository`
One single-row `@Lock` method:
```java
@Lock(LockModeType.PESSIMISTIC_WRITE)
@Query("SELECT s FROM Stockunit s WHERE s.id = :id")
@RestResource(exported = false)
Optional<Stockunit> findByIdForUpdate(@Param("id") Long id);
```
One multi-row **native** `FOR UPDATE` query (not a `@Lock` annotation — the lock is baked into the
SQL text), keyed by `itemDataId`, ordered by `amount DESC`, not by id and not by a `List<Long>` of
stockunit ids:
```java
@Query( value = "SELECT stockunit.* FROM stockunit " +
    ...
    "ORDER BY stockUnit.amount DESC " +
    "FOR UPDATE OF stockunit", nativeQuery = true)
// SBDEV-3250 ⚠ MULTI-ROW LOCK, NO LIMIT. This takes a row lock on EVERY picking-area stockunit
// row for the SKU, ...
List<Stockunit> getStockUnitsByItemDataIdForUpdate(@Param("itemDataId") Long itemDataId);
```
`file: src/main/java/net/aim_ai/wms/repo/jpa/StockunitRepository.java`

**No method matches the shape "takes a `List<Long>`/`Collection`, returns a locked `List`, ordered
by id"** — the only multi-row lock is the itemDataId-keyed, amount-ordered one above. `findByUnitloadIdIn`
and `findEligibleByUnitloadIdIn` take `Collection<Long>` but are unlocked plain reads.

### `CustomerorderRepository`
One single-row `@Lock` method, and **nothing else**:
```java
@Lock(LockModeType.PESSIMISTIC_WRITE)
@Query("SELECT c FROM Customerorder c WHERE c.id = :id")
@RestResource(exported = false)
Optional<Customerorder> findByIdForUpdate(@Param("id") Long id);
```
`file: src/main/java/net/aim_ai/wms/repo/jpa/CustomerorderRepository.java`

**Confirmed: no multi-row locked finder exists for customerorder in any shape** — not by id list, not
by any FK. `getByParcelIdList(List<Long> parcelIds)` exists but is an unlocked read returning
`List<Customerorder>`. **This confirms SBDEV-3398 §4.4's claim that one must be ADDED for
customerorder** — there is nothing to reuse; a `findByIdInForUpdate(Collection<Long> ids)` (or
equivalent, `ORDER BY c.id`) does not exist on origin/develop.

### `CustomerorderPositionRepository`
One multi-row `@Lock` method, keyed by a single FK (not a `List<Long>`/`Collection` of position
ids), ordered by id:
```java
@RestResource(exported = false)
@Lock(LockModeType.PESSIMISTIC_WRITE)
@Query("SELECT cp FROM CustomerorderPosition cp WHERE cp.orderId = :orderId ORDER BY cp.id")
// SBDEV-3250 ⚠ MULTI-ROW LOCK: locks every position of the order; orderId is a plain FK, so the row
// count is caller-uncontrolled and is the largest fan-out of the four multi-row @Lock sites.
List<CustomerorderPosition> findByOrderIdForUpdate(@Param("orderId") Long orderId);
```
`file: src/main/java/net/aim_ai/wms/repo/jpa/CustomerorderPositionRepository.java`

This is the canonical shape SBDEV-3418 would follow for `CustomerorderPosition`, but note its
parameter is a single FK id (`orderId`), not a `List<Long>`/`Collection` of position ids — it
matches "multi-row, ordered" but not "takes a `List<Long>`/`Collection`".

### `BillofladingPositionRepository`
**Zero** `ForUpdate`/`@Lock` methods — confirmed by full-file read and by `git grep -n
"ForUpdate\|@Lock" origin/develop -- '*/BillofladingPositionRepository.java'` returning no hits. It
has two `@Modifying` deletes (`deleteBolPositionById`, `deleteBolPositionsCarrierIds`, see §5) but no
locking read of any kind.
`file: src/main/java/net/aim_ai/wms/repo/jpa/BillofladingPositionRepository.java`

**Summary answer to the explicit multi-row question:** none of unitload, stockunit, or
customerorder has a multi-row locked finder shaped "takes a `List<Long>`/`Collection`, returns a
`List`, ordered [by id]". Unitload and customerorder have **no multi-row lock of any shape** at
all; stockunit has one multi-row lock, but it is keyed by a single `itemDataId` scalar and ordered
by `amount`, not by an id list. **SBDEV-3398 §4.4's claim is confirmed**: a customerorder multi-row
locked finder does not exist today and would need to be added — and the same is true for unitload
and (in the `List<Long>`-keyed shape specifically) for stockunit.

---

## 2. Scalar id projection precedents

Established pattern (SBDEV-3244 first-touch rule, restated in the class javadoc of
`MobilePalletizeWriteService`):
```java
// PHASE A's diagnostics are scalar projections ({@code existsByLabelid},
// {@code findIdByParcelLabelId}) — a query returning {@code boolean} or {@code Long} creates no
```
`file: src/main/java/net/aim_ai/wms/service/mobile/MobilePalletizeWriteService.java`

Confirmed existing scalar precedents (repo-wide):
```java
boolean existsByLabelid(@Param("labelid") String labelid);                       // UnitloadRepository
Long findIdByParcelLabelId(@Param("labelId") String labelId);                     // CustomerorderRepository
List<Long> findUnitloadIdsByIdIn(@Param("ids") Collection<Long> ids);             // StockunitRepository
List<Long> findIdsByState(@Param("state") Integer state);                         // ReplenishorderRepository
List<Long> findIdsByStateAndItemdataId(...);                                      // ReplenishorderRepository
Optional<Long> findIdByStateLessThanAndStockunitId(...);                          // ReplenishorderRepository
```

Per sub-question, what exists today vs. what would have to be added for SBDEV-3418:

**(a) BOL id from a BOL name — DOES NOT EXIST, would have to be ADDED.**
`BillofladingRepository` only has:
```java
@RestResource(path = "findByName", rel = "findByName")
Optional<Billoflading> findByName(@Param("name") String name);
```
`file: src/main/java/net/aim_ai/wms/repo/jpa/BillofladingRepository.java` — this materialises the
entity (creates an `EntityEntry`), which is exactly what the first-touch rule forbids before a
later `findByIdForUpdate`. `git grep -n "findIdByName\|Long findId" origin/develop --
'src/main/java/net/aim_ai/wms/repo/jpa/BillofladingRepository.java'` returns no hits — no scalar
sibling exists.

**(b) pallet unitload id from a pallet label — PARTIALLY EXISTS (existence only), the id itself
would have to be ADDED.**
`UnitloadRepository.existsByLabelid(String labelid)` (quoted above) confirms existence without
touching the entity, but it returns `boolean`, not the id — it cannot resolve the id for a
subsequent step that needs it (e.g. to pass to a different repository's `IN (:ids)` clause). No
`findIdByLabelid`/`Long ... ByLabelid` sibling exists (confirmed by the same UnitloadRepository
grep in §1, whose only scalar hit was `existsByLabelid`).

**(c) child parcel unitload ids from a pallet id — DOES NOT EXIST, would have to be ADDED.**
`UnitloadRepository` has only entity-returning or view-returning finders by `carrierunitloadId`:
```java
List<Unitload> findByCarrierunitloadId(@Param("carrierunitloadId") Long carrierunitloadId);
List<Unitload> findByCarrierunitloadIdIn(@Param("carrierIds") Collection<Long> carrierIds);
Integer findCountByCarrierunitloadId(@Param("carrierunitloadId") Long carrierunitloadId);
```
`file: src/main/java/net/aim_ai/wms/repo/jpa/UnitloadRepository.java` — no `List<Long>` id-only
projection by `carrierunitloadId` exists.

**(d) customerorder ids from a list of parcel ids — DOES NOT EXIST, would have to be ADDED.**
`CustomerorderRepository.getByParcelIdList(List<Long> parcelIds)` returns `List<Customerorder>`
entities (materialises), not scalar ids:
```java
@Query(value = "SELECT DISTINCT(co.*) FROM customerorder co " +
    "INNER JOIN unitload parcel on co.parcel_id = parcel.id " +
    "WHERE parcel.id IN :parcelIds", nativeQuery = true)
List<Customerorder> getByParcelIdList(@Param("parcelIds") List<Long> parcelIds);
```
`findIdByParcelLabelId` (quoted in §2 intro) is scalar but resolves from a single **label**, not a
list of parcel **ids** — different key. No scalar `List<Long>`-in/`List<Long>`-out sibling exists.

**(e) stockunit ids from a unitload id — DOES NOT EXIST, would have to be ADDED.**
`StockunitRepository` has only entity- or count-returning finders keyed by `unitloadId`:
```java
List<Stockunit> findByUnitloadId(@Param("unitloadId") Long unitloadId);
Integer findCountByUnitloadId(@Param("unitloadId") Long unitloadId);
```
`file: src/main/java/net/aim_ai/wms/repo/jpa/StockunitRepository.java`. Note the file DOES have
`findUnitloadIdsByIdIn(Collection<Long> ids)`, but that resolves in the OPPOSITE direction
(stockunit ids → unitload ids), not unitload id → stockunit ids as (e) asks. No matching method
exists in the needed direction.

**Overall for §2:** the *technique* (scalar `boolean`/`Long`/`List<Long>` projections to avoid a
first-touch violation) is well precedented across `UnitloadRepository`, `CustomerorderRepository`,
`StockunitRepository`, and `ReplenishorderRepository`. But of the five specific lookups SBDEV-3418
needs, only (b) is even partially covered (existence, not id) — **all five id-resolution methods
themselves would have to be newly added.**

---

## 3. `UnitloadBusinessService.transferUnitLoadToLocation(...)`

**Signature:**
```java
@Transactional(value = "tenantTransactionManager", rollbackFor = {BusinessException.class, FacadeException.class})
public void transferUnitLoadToLocation(Unitload unitload, Location destinationLocation, boolean ignoreLock, String activityCode, String orderNumber, String comment) throws FacadeException, BusinessException {
```
`file: src/main/java/net/aim_ai/wms/service/UnitloadBusinessService.java`

**`@Transactional`:** yes, on `tenantTransactionManager`, `rollbackFor = {BusinessException.class,
FacadeException.class}`. Propagation is **not specified**, so it is Spring's default —
`Propagation.REQUIRED` (joins the caller's transaction if one is open, starts a new one otherwise).

**Row lock taken:** conditional, not unconditional. When `ignoreLock == false`:
```java
if (!ignoreLock) {
    final Long destinationLocationId = destinationLocation.getId();
    destinationLocation = locationRepository.findByIdForUpdate(destinationLocationId)
        .orElseThrow(() -> new EntityNotFoundException("Location", destinationLocationId));
    entityManager.refresh(destinationLocation);
}
```
This locks the **destination Location only**, via `locationRepository.findByIdForUpdate` (a
`@Lock(PESSIMISTIC_WRITE)` finder on `LocationRepository`, not shown above but same shape as the
repos in §1) followed by `entityManager.refresh(destinationLocation)` — i.e. this method DOES use
`entityManager.refresh(e, lockMode)`-adjacent code (a plain `refresh` after a locked re-fetch, to
force the in-memory instance to reflect the locked row) at the exact place the task brief flags as
"explicitly NOT an alternative" for the first-touch pattern. When `ignoreLock == true` (which is
what `scanGate` passes: `unitloadBusinessService.transferUnitLoadToLocation(pallet, gate, false,
...)` — **note: `scanGate` actually passes `false`, i.e. `ignoreLock=false`**, so the destination
Location lock IS taken on this call path), no other row lock is taken by this method itself. There
is also a conditional Pickingorder pre-lock, but only for `BLOCK_REALIGN` activity codes:
```java
if (PickLineActivityCodeClassifier.classify(activityCode, null) == PickLineActivityCodeClassifier.Bucket.BLOCK_REALIGN) {
    List<Long> treeStockUnitIds = pickLineRealignmentService.collectStockUnitIdsForUnitloadTree(unitload);
    pickLineRealignmentService.lockOwningPickingorders(treeStockUnitIds);
}
```
`scanGate` calls with `activityCode = WmsConstants.CODE_TRUCK_LOADING`, which is documented
elsewhere in the same file as a `PASS_THROUGH` bucket (truck-load is explicitly listed: "PASS_THROUGH
(shipping / truck-load / receiving / putaway / split / nirvana) falls straight through"), so this
branch does **not** fire for `scanGate`'s call.

**Repository SAVE/DELETE/bulk-modifying calls, and on which entity:**
- `unitloadRepository.save(unitload)` — twice: once in `transferUnitLoadToLocation` itself when
  detaching from a parent carrier (`unitload.setCarrierunitloadId(null); unitload =
  unitloadRepository.save(unitload);`), and once inside the private `processTransfer` helper it
  calls (`unitload.setStoragelocationId(destinationLocation.getId()); unitload =
  unitloadRepository.save(unitload);`) — entity: `Unitload`.
- No `DELETE` or bulk `@Modifying` call is made by this method or by `processTransfer`.
- It also calls `unitloadRecordService.recordForTransferUnitLoad(...)` (a service call, not a raw
  repo call — writes an audit `unitload_record` row inside the same transaction by propagation) and,
  conditionally under `BLOCK_REALIGN`, `pickLineRealignmentService.realignForMovedStockUnit(...)`
  and `replenishmentOrderSourceSyncService.syncForMovedStockUnit(...)` — neither fires for
  `scanGate`'s `CODE_TRUCK_LOADING` call, as noted above.

**`flush()`:** none. `grep -n "\.flush(" ` against the full file (985 lines) returns no hits.
`file: src/main/java/net/aim_ai/wms/service/UnitloadBusinessService.java`

**Outbound HTTP/OMS call:** none. `grep -n "RestTemplate\|WebClient\|HttpClient\|OmsApiService\|WmsApiService"` against the full file returns no hits.

**Recursion over child unitloads:** yes, via the private `processTransfer` helper:
```java
List<Unitload> childUnitloadList = unitloadRepository.findByCarrierunitloadId(unitload.getId());

for (Unitload child : childUnitloadList) {
    ...
    processTransfer(child, unitload, unitload, sourceLocation, destinationLocation, activityCode, orderNumber, comment, visited);
}
```
Guarded by a `Set<Long> visited` (SBDEV-3091 cycle protection), each recursive call does its own
`unitloadRepository.save(unitload)` for that child. **This recursion is unconditional** (not
scoped by activity code) — for `scanGate`'s pallet, it walks and re-saves every child parcel
unitload of the pallet.

**Relevance to `em.clear()` risk named in the task brief:** since `transferUnitLoadToLocation` runs
under `Propagation.REQUIRED`, when called from within `scanGate` (once `scanGate` is wrapped
`@Transactional`) all of the above `Unitload` saves (parent, and every recursively-walked child) are
pending, unflushed writes in the shared persistence context at the moment `scanGate` goes on to call
`mobileTransferService.handleTruckOffLoading(...)` — see §5, which shows that call's two deletes are
each independently `@Transactional` with `clearAutomatically = true`.

---

## 4. `BillofladingPositionService.createEntity(Billoflading, User)`

```java
public BillofladingPosition createEntity(Billoflading billOfLading, User operator) {
    LOG.debug("start");

    Client client = clientService.getSystemClient();

    BillofladingPosition billOfLadingPosition = new BillofladingPosition();
    billOfLadingPosition.setBillofladingId(billOfLading.getId());
    List<BillofladingPosition> bolPositions = billofladingPositionRepository.findByBillofladingId(billOfLading.getId());
    String number = basicService.generatePositionNumber(billOfLading.getNumber(), bolPositions.size());
    billOfLadingPosition.setNumber(number);
    billOfLadingPosition.setName(number);
    billOfLadingPosition.setClientId(client.getId());
    billOfLadingPosition.setOperatorId(operator.getId());
    billOfLadingPosition.setState(WmsConstants.BillOfLadingState.TRUCK_LOADING);
    BillofladingPosition bolPosition = billofladingPositionRepository.save(billOfLadingPosition);

    LOG.debug("end   with result {}", billOfLadingPosition);
    return bolPosition;
}
```
`file: src/main/java/net/aim_ai/wms/service/BillofladingPositionService.java`

**Reads:** `clientService.getSystemClient()`; and — the load-bearing one —
`billofladingPositionRepository.findByBillofladingId(billOfLading.getId())`, which materialises
**every existing** `BillofladingPosition` row for this BOL as entities, purely to take
`.size()`.

**Writes:** persists **immediately** — `billofladingPositionRepository.save(billOfLadingPosition)`
is called unconditionally and its result (a managed, persisted entity with a generated id) is
returned. It does **not** return a transient entity.

**Number derivation — confirmed read-modify-write, no lock:**
```java
public String generatePositionNumber(String positionKey, Integer positionIndex) {
    String prefix = positionKey + WmsConstants.EntityPrefixes.SEPARATOR;
    String number = String.format(prefix + getFormat(), positionIndex);
    LOG.trace("position number end with number={}", number);
    return number;
}
```
`file: src/main/java/net/aim_ai/wms/service/BasicService.java`

`generatePositionNumber` itself is pure formatting — it takes `positionIndex` as a plain `Integer`
parameter and does no DB read of its own. **The read-modify-write is entirely inside
`createEntity`**: it reads the *current count* of positions for the BOL
(`bolPositions.size()`), then formats `number` from that count, then saves a new row — with
**no row lock of any kind held across the read-count-format-save sequence**, and no unique
constraint enforced in this code path (only whatever the DB schema does, which is out of scope for
this lane).

**Confirmed as the suspected mechanism:** yes. Two concurrent `createEntity` calls for the same
`billOfLading.getId()` — e.g. two concurrent `scanGate` invocations against the same BOL, or
`scanGate`'s own three sequential-but-unlocked calls (`createEntity` for pallet, then once per
parcel, then once per stock line — see `MobileTruckLoadingService.scanGate:251,260,283` in the
codebase, all calling `billofladingPositionService.createEntity(billOfLading, operator)`) racing
against a second scan — can both read the same `bolPositions.size()` before either has committed
its own insert, producing the same `number` for two different `(billoflading_id, number)` rows.
This is consistent with, and a precise mechanism for, the 4 duplicate `(billoflading_id, number)`
groups measured on Hydra UAT.

---

## 5. `MobileMoveUnitloadService.handleTruckOffLoading(String)` and its two deletes

**The two deletes, exact annotations:**
```java
@Modifying(clearAutomatically = true)
@Transactional
@RestResource(path = "deleteBolPositionById", rel = "deleteBolPositionById")
@Query("DELETE FROM BillofladingPosition bp WHERE bp.id = :bolPositionId")
void deleteBolPositionById(@Param("bolPositionId") Long bolPositionId);

@Modifying(clearAutomatically = true)
@Transactional
@RestResource(path = "deleteBolPositionsCarrierIds", rel = "deleteBolPositionsCarrierIds")
@Query("DELETE FROM BillofladingPosition bp WHERE bp.carrierId IN :carrierIds")
void deleteBolPositionsCarrierIds(@Param("carrierIds") List<Long> carrierIds);
```
`file: src/main/java/net/aim_ai/wms/repo/jpa/BillofladingPositionRepository.java`

- `clearAutomatically`: **yes**, `true` on both — after each delete runs, the persistence context is
  cleared (`EntityManager.clear()`), detaching **every** managed entity in it, not just
  `BillofladingPosition` rows.
- `flushAutomatically`: **not set** on either (defaults to `false` in Spring Data JPA's
  `@Modifying`) — so the delete is flushed by JPQL bulk-operation semantics at execution time (bulk
  `DELETE`/`UPDATE` JPQL always issues its SQL immediately, ignoring the flush-mode setting), but
  Spring Data itself does not additionally call `flush()` before or after.
- The `@Transactional` on both is **Spring's** (`org.springframework.transaction.annotation.Transactional`,
  imported once at the top of the file:
  `import org.springframework.transaction.annotation.Transactional;`), not Jakarta's — and it
  carries **no explicit propagation**, so it defaults to `Propagation.REQUIRED` (joins the caller's
  transaction if open).

**`handleTruckOffLoading` itself — no method-level `@Transactional`:**
```java
public void handleTruckOffLoading(String unitLoadLabel) {
    LOG.debug("handle truck off loading for {}", unitLoadLabel);
    String pattern = syspropService.getSysvalue(WmsConstants.SYSTEM_PROPERTY_STRING_PATTERN_OUTBOUND_PALLET_KEY);
    ...
    if (unitLoadLabel.matches(pattern) || unitLoadLabel.matches(convertedPrintingPattern)) {
        Long bolPositionId = billofladingPositionRepository.findBolIdByUnitLoadLabelId(unitLoadLabel);
        LOG.debug("internal BOL Position ID: {}", bolPositionId);
        if (bolPositionId != null) {
            List<Long> carrierIds = billofladingPositionRepository.findBolCarrierIdListByUnitLoadLabelId(unitLoadLabel);
            billofladingPositionRepository.deleteBolPositionsCarrierIds(carrierIds);
            billofladingPositionRepository.deleteBolPositionById(bolPositionId);
        }
    }
}
```
`file: src/main/java/net/aim_ai/wms/service/mobile/MobileMoveUnitloadService.java`

**`MobileMoveUnitloadService` class/method `@Transactional`:** no class-level `@Transactional` —
the class declaration is a bare `@Service public class MobileMoveUnitloadService {` with no
annotation above it. `handleTruckOffLoading` itself also carries no `@Transactional`.

**`handleTruckOffLoading`'s call sites — TWO, not one:**
```
src/main/java/net/aim_ai/wms/service/mobile/MobileMoveUnitloadService.java:373:            handleTruckOffLoading(dto.getUnitLoadLabel());
src/main/java/net/aim_ai/wms/service/mobile/MobileMoveUnitloadService.java:572:    public void handleTruckOffLoading(String unitLoadLabel) {
src/main/java/net/aim_ai/wms/service/mobile/MobileTruckLoadingService.java:247:        mobileTransferService.handleTruckOffLoading(truckLoadingMobileDTO.getPalletName());
```
(`git grep -n "handleTruckOffLoading(" origin/develop -- 'src/main'`)

1. **`scanDestination`'s call (line 373, the "OTHER call site" the task asks about):** this IS
   inside a transaction. `scanDestination` is annotated:
   ```java
   @Transactional(value = "tenantTransactionManager", rollbackFor = {BusinessException.class, FacadeException.class})
   public void scanDestination(TransferInfoDto dto) throws BusinessException, FacadeException {
   ```
   and the call to `handleTruckOffLoading(dto.getUnitLoadLabel())` sits inside that same method body
   (inside an `if (dto.isMoveStock())`-adjacent branch, after
   `unitloadBusinessService.transferUnitLoadToLocation(sourceUnitLoad, destinationStorageLocation,
   false, WmsConstants.CODE_TRANSFER, null, null);`). So on `scanDestination`'s path,
   `handleTruckOffLoading` (and therefore its two `@Modifying` deletes) already runs transactionally
   today, joining `scanDestination`'s open `tenantTransactionManager` transaction by
   `Propagation.REQUIRED`.

2. **`MobileTruckLoadingService.scanGate`'s call (the one the task is actually about):**
   ```java
   unitloadBusinessService.transferUnitLoadToLocation(pallet, gate, false, WmsConstants.CODE_TRUCK_LOADING, billOfLading.getNumber(), null);
   mobileTransferService.handleTruckOffLoading(truckLoadingMobileDTO.getPalletName());
   ```
   `file: src/main/java/net/aim_ai/wms/service/mobile/MobileTruckLoadingService.java` — and
   `scanGate` itself is declared with **no `@Transactional`**:
   ```java
   public TruckLoadingMobileDto scanGate(TruckLoadingMobileDto truckLoadingMobileDTO) throws FacadeException, BusinessException {
   ```
   A later comment in the same method (around the OMS-notification call, further down) states this
   explicitly and independently confirms it:
   ```java
   // This site took the else-branch today only because its enclosing method is
   // not @Transactional — i.e. it worked BY ACCIDENT. Adding @Transactional
   // would have silently broken it with no test failing.
   ```
   `file: src/main/java/net/aim_ai/wms/service/mobile/MobileTruckLoadingService.java` — so on
   today's `develop`, `handleTruckOffLoading`'s two `@Modifying` deletes run in **their own
   independent transactions** (each `Propagation.REQUIRED` opening a NEW transaction, since no
   caller transaction is open) when reached via `scanGate`, in contrast to the `scanDestination`
   path where they join an existing one.

---

## 6. OSIV

```
spring.jpa.open-in-view=false
```
`file: src/main/resources/application.properties:85` (single non-profiled properties file in
`src/main/resources`; only other files there are `messages.properties` /
`messages_en_US.properties` — no environment-specific profile file exists in `src/main/resources`).

Also set identically in the test-only integration property files (`spring.jpa.open-in-view=false`
at `src/test/resources/application-integration.properties:31` and
`src/test/resources/application-postgres-integration.properties:189`), and pinned by a dedicated
unit test:
```java
@DisplayName("AC-27 spring.jpa.open-in-view must remain false")
...
assertThat(props.getProperty("spring.jpa.open-in-view"))
```
`file: src/test/java/net/aim_ai/wms/unit/config/SdrEvictionPostCommitAssumptionUnitTest.java`

**Consequence for this ticket:** OSIV is OFF, uniformly, everywhere (`src/main`, both test
integration profiles, and rail-tested). Entities read outside an explicit transaction are **not**
managed today — the persistence context closes at the end of the service/transactional method, and
any entity read in a non-`@Transactional` method (such as today's `scanGate`) becomes detached the
moment the repository call returns, with no lazy loading or dirty-checking available afterward. This
is corroborated repo-wide, e.g.:
```
src/main/java/net/aim_ai/wms/repo/jpa/LocationRepository.java:94: // (spring.jpa.open-in-view=false) a locking query here throws TransactionRequiredException.
src/main/java/net/aim_ai/wms/service/SkuPutawayQueryService.java:44: // ({@code spring.jpa.open-in-view=false}): it opens an {@code EntityManager}, never a transaction.
```

---

## Notes on instrument limits / blind spots

- All repository-interface inventories in §1–§2 are from full-file reads (`git show
  origin/develop:<path>`) of all six named repositories plus `ReplenishorderRepository`, not
  keyword grep alone — so the "no multi-row locked finder exists" claims are exhaustive over each
  file's declared methods, not a possibly-incomplete grep match. The blind spot: a method added on
  a branch not yet merged to `origin/develop`, or on v1, would not appear here — out of scope per
  the read-only/`origin/develop`-only brief.
- §3's "no outbound HTTP/OMS call" and "no `flush()`" claims are grep-derived
  (`RestTemplate|WebClient|HttpClient|OmsApiService|WmsApiService` and `\.flush\(` respectively)
  against the full 985-line `UnitloadBusinessService.java`, both zero-hit. Per positive-control
  practice: the same grep vocabulary DOES find real hits elsewhere in the codebase (e.g.
  `WmsApiService`, `OmsApiService` classes exist and are referenced by other services — confirmed by
  `git grep -l OmsApiService origin/develop -- src/main | head` returning multiple files), so the
  zero-hit result in this one file is not an artifact of a broken pattern.
- §5's "two call sites" claim is from `git grep -n "handleTruckOffLoading(" origin/develop --
  'src/main'`, restricted to `src/main`; it would miss a reflective or proxy-mediated call (none is
  plausible here — `handleTruckOffLoading` is a concrete public method on a concrete `@Service`
  class, called by direct field/constructor-injected reference in both cases observed).
