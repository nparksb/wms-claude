# SBDEV-3418 — adversarial plan review (independent lane)

**Reviewer:** plan-critic (read-only lane). **Date:** 2026-09-22.
**Target:** `sbdocs/1-Projects/wms2/plan/SBDEV-3418-mobile-truck-loading-transaction-boundary.md`
(mtime 2026-09-22 03:46) and `SBDEV-3418-evidence/`.
**Graded against:** `v2/wms2-api` `origin/develop` @ `f2ee75f16b36723fb97994c52cb79b2c66754f1e`,
read exclusively via `git show origin/develop:<path>` / `git grep … origin/develop`. Local checkout
never read. DB re-derivation via the `nywh-hydra-uat` MCP.

**Verdict: do not implement §1.2 / §4.2.1 as written; the rest of the plan is sound and unusually
well grounded, but four claims are wrong and two acceptance criteria cannot grade what they claim.**

The scope decision the plan actually makes — *boundary + locks in, duplicate numbers out* — survives
this review. What does not survive is the **reasoning offered for it**: the §1.2 arithmetic is fitted
to rows written by code that is not in git and whose numbering formula is demonstrably different
from `origin/develop`'s, and the recommendation that the duplicate-number fix is "the one I would do
first" is backed by **zero** occurrences under today's code across a 7,403-row positive control.

Findings are ordered High → Low. Count: **4 High, 7 Medium, 6 Low**, plus **5 calibration notes**
where I expected the plan to be wrong and it was right.

---

## HIGH

### H1 — §1.2 derives `number = size() + 1` from code that computes `number = size()`. The quoted snippet does not support the stated formula.

The plan writes:

> `BasicService.generatePositionNumber` is pure formatting (`String.format(prefix + getFormat(),
> positionIndex)`), so `number = size() + 1`.

`BasicService.java` on `origin/develop`:

```java
public String generatePositionNumber(String positionKey, Integer positionIndex) {
    String prefix = positionKey + WmsConstants.EntityPrefixes.SEPARATOR;
    String number = String.format(prefix + getFormat(), positionIndex);
```

`getFormat()` returns `"%1$06d"`. There is **no `+1`**. The sibling two methods up makes the contrast
unmistakable — `generateOrderNumber` does `String.format(prefix + getFormat(), customerOrders.size() + 1)`.
And `BillofladingPositionService.createEntity` passes `bolPositions.size()` unmodified:

```java
List<BillofladingPosition> bolPositions = billofladingPositionRepository.findByBillofladingId(billOfLading.getId());
String number = basicService.generatePositionNumber(billOfLading.getNumber(), bolPositions.size());
```

So on `origin/develop`, `number = size()`, and the **first** position on a BOL is numbered `-000000`.

**Empirical confirmation, with the positive control in the same result set.** Classifying every BOL
on Hydra UAT by the suffix of its lowest-id position:

| first position's suffix | BOLs | first seen | last seen |
|---|---|---|---|
| `-000001` | 668 | 2021-08-26 | **2025-02-27** |
| no suffix at all (`OBOL000950`) | 21 | 2025-03-03 | 2025-05-12 |
| `-000000` | **306** | **2025-03-26** | 2026-07-10 |

Three formula epochs, cleanly separated in time. The plan's own evidence file already contains a
counterexample it did not follow up: `db-field-evidence.md` §3 lists row `2488077` with number
`OBOL001402-000000`, and I confirmed it is `bol_first` on its BOL — a `-000000` suffix is
**unreachable** under `size() + 1`.

**Impact.** The §1.2 table is internally consistent under `size()+1` (2 phantom rows), and also
internally consistent under `size()` (3 phantom rows, one of them a `-000000` row). It is a fitted
model with a free parameter, not a derivation — and the version the plan chose is the one today's
code does not implement. Anyone re-deriving §1.2 from `origin/develop` will get a contradiction and
stop trusting the section.

**What I would do:** delete the "so `number = size() + 1`" sentence, state `number = size()` for
today's code, and move the §1.2 table under an explicit "the 2024 epoch used `size()+1`" heading —
see H2, which is why that heading is needed.

---

### H2 — The §1.2 / §2-Bug-3 evidence predates the code it is attributed to by 13 months. `git log` dates every cited symbol.

This is the load-bearing one. The plan grades a mechanism against `origin/develop` source and
validates it against rows from **2023-08-17 and 2024-02-19**. The repository's history does not
reach back that far, and every symbol the argument names was written later:

| symbol the plan cites | first appears on `origin/develop` |
|---|---|
| repo root (`a685e07b` *"initial checkin the code"*) | **2024-07-16** |
| `createEntity`'s `size()`-based numbering (`ca28da88` *"updated bill of lading positions and order positions to use the same position number genertor"*) | **2025-03-17** |
| `handleTruckOffLoading` (`6edf3d12` *"fixed OBOL numbering changes and BOL positions left undeleted when pallet is moved back to Palletizing location from truck loading"*) | **2025-03-21** |
| `findBolIdByUnitLoadLabelId`, `findBolCarrierIdListByUnitLoadLabelId`, `deleteBolPositionsCarrierIds` (all three, `8cbfdb82`) | **2025-03-25** |
| `handleTruckOffLoading` wired into `scanGate` (`839d7f8d`, diff adds `+ mobileTransferService.handleTruckOffLoading(...)`) | **2025-03-24** |

Before `ca28da88`, `createEntity` did `basicService.generateNumber(WmsConstants.EntityPrefixes.BILL_OF_LADING, "BILL_OF_LADING")` —
a **global sequence**, not a per-BOL count. That is the source of the 21 no-suffix BOLs in H1's table.

Two consequences, both material:

1. **The §2 Bug-3 attribution is unsupported.** The plan says of the two rows that vanished between
   16:39:22 and 16:39:36 on 2024-02-19: *"the two rows that vanished … are precisely what
   `deleteBolPositionsCarrierIds` removes for that pallet (`findBolCarrierIdListByUnitLoadLabelId`
   returns `{parcel position, pallet position}` …)"*. Those three symbols were committed on
   **2025-03-25**. The plan then spends a paragraph on *"⚠ Not established: which call site ran that
   cleanup … Neither candidate fully explains it"* — the answer is that on 2024-02-19 **neither
   candidate existed**. The mystery it flags as open is an artifact of the epoch mismatch.

2. **The §1.1 recency argument rests on a false premise.** Plan line 78–79:
   *"That does **not** mean it is fixed — nothing changed in this code, and at the all-time rate of
   8/1,060 you would expect ~1.2 occurrences in 166, so observing 0 is unremarkable."* Four commits
   changed exactly this code in March 2025, one of them (`6edf3d12`) literally titled *"BOL positions
   left undeleted when pallet is moved back to Palletizing location from truck loading"* — the
   childless-position symptom. The statistical argument may still be right; the "nothing changed"
   justification for it is not, and it is the load-bearing half.

**What I would do:** re-cut §1.1/§1.2 on the epoch boundary. State the March-2025 commits by SHA,
and re-state the base rate over the post-`2025-03-26` window only (numbers in H3).

---

### H3 — §4.2.1's ranking ("the one I would do first … the only defect here with a proven, reproducible mechanism") inverts the field evidence.

Measured on `nywh-hydra-uat`, restricted to the epoch in which today's numbering code has been
running (created ≥ 2025-03-26), with all controls non-zero in the same `SELECT`:

| measure | value |
|---|---|
| positions created since the formula change | **7,403** (control, non-zero) |
| distinct BOLs | **309** (control, non-zero) |
| top-level positions | **313** (control, non-zero) |
| duplicate `(billoflading_id, number)` groups in that window | **0** |
| latest duplicate group anywhere | **2024-02-19** |
| childless top-level positions in that window | **2** |

So under the code the plan is grading:

- the duplicate-number defect has **0 occurrences in 7,403 positions**, and its entire evidence base
  (4 groups / 8 rows) is 2023-08 and 2024-02 — pre-git, pre-`handleTruckOffLoading`;
- the atomicity defect the plan is actually fixing has **2 occurrences in 313 top-level positions**.

The plan's §4.2.1 nonetheless calls the duplicate-number fix *"This is the one I would do first — it
is the only defect here with a proven, reproducible mechanism"*. On the plan's own instrument the
ranking is backwards. The `size()`-over-a-shrinking-set mechanism **is** still real in today's code
(I am not disputing that), but it is **latent with zero measured exposure**, which is exactly the
status the plan correctly assigns to §4.2.2's non-unique finders.

Worth noting on the surviving evidence, because it further weakens the childless count too: of the
2 post-change childless rows, only **2488077** is a clean partial-write shape (`-000000`, i.e. the
BOL's first position, with 9 siblings created over the following 4.5 min and no children).
**2371386** is `OBOL001369-000033` and is now the *only* row on its BOL — meaning 32 siblings existed
when it was created and were later removed wholesale. That is a deleted-BOL remnant, not a partial
write. `db-field-evidence.md` §1 calls 1938190 and 2371386 *"the strongest cases"*; for 2371386 that
reading is inverted.

**What I would do:** keep the atomicity fix (it has live evidence, 1–2 rows, and a clean mechanism);
demote §4.2.1 from "do first" to "latent, propose with the §4.2.2 pair"; and say in §1.1 that the
honest live count under today's code is **1–2 rows / 313**, not 8 / 1,060.

---

### H4 — AC-4's stated discriminator cannot distinguish its two hypotheses. It returns the same answer in both worlds.

> ⚠ **A green here is a genuine possible outcome and must not be read as a broken test.** Write the
> assertion so it distinguishes "the write survived because it was flushed" from "the write was never
> at risk" — e.g. **by observing whether the row is visible to a second connection before the clear.**

Visibility to a second connection is decided by **COMMIT**, not by flush. Under READ COMMITTED a
flushed-but-uncommitted `UPDATE` is invisible to every other session. So the probe returns
"not visible" whether Hibernate auto-flushed before the native query or not — it is vacuous, and
worse, it reads as positive evidence for "the write was at risk" in both worlds. This is exactly the
failure mode the plan's own §1.1 warns about for count-stays-at-zero ACs.

**What I would do instead** — two probes that actually separate the hypotheses:

1. **Lock probe (cheapest, no instrumentation).** A flushed `UPDATE unitload …` takes a row lock. From
   a second connection issue `SELECT … FROM unitload WHERE id = ? FOR UPDATE NOWAIT` at the moment
   the clear fires: it errors `55P03` if the write was flushed, returns the row if it was not.
2. **Statement probe.** Register a Hibernate `StatementInspector` (or `hibernate.SQL` at DEBUG) and
   assert on whether the `UPDATE` SQL was emitted before the native `SELECT bp.id …`.

Either is a real kill criterion. The plan is right that the measurement matters; the method it names
cannot perform it.

---

## MEDIUM

### M1 — §3.2's D2 directly contradicts Bug 6a's own prescribed remedy, and buys nothing.

Bug 6a's design consequence says:

> resolve the gate by a scalar id projection during validation and **let `transferUnitLoadToLocation`'s
> `findByIdForUpdate` be the Location row's first touch**.

§3.2 then adds **D2** — `locationRepository.findByIdForUpdate(gateId)` — immediately before D3, so
that `transferUnitLoadToLocation`'s inner lock is *not* the first touch, and justifies it as making
the inner call *"a WRITE→WRITE re-lock rather than an upgrade"*.

Both are safe, but they are different designs and the plan asserts both. D2 is strictly redundant:
with A6's scalar projection there is no `EntityEntry` for the gate, so `transferUnitLoadToLocation`'s
own `findByIdForUpdate` is already an acquisition, not an upgrade. D2 costs one extra round trip on
the single hottest shared row on this path (the gate) and widens the window in which it is held,
for no stated benefit. `arch-target-sequence.md` C-8 carries the same duplication.

**What I would do:** drop D2, keep A6, and say in the javadoc that the gate's first entity touch is
deliberately inside `transferUnitLoadToLocation`. If D2 is kept, state the reason — I could not find
one.

### M2 — AC-1's only obvious natural failure sites are the ones the fix *relocates*. As written it will go green for the wrong reason.

AC-1 requires *"a **natural** failure, not a spy"* injected *"part-way through the write sequence"*.
On `origin/develop` the two natural mid-write failures inside `scanGate` are both `BusinessException`s
raised inside the parcel loop, after `palletBOLPos` and earlier parcel positions have been saved:

```java
if (order == null) {
    throw new BusinessException("unexpectedUnitLoadDoesNotHaveOrder", parcel.getLabelid());
}
```
and the `"Too many orders with the same parcel found"` sibling above it.

§3.2 phase C moves **both** of these ahead of every write (*"orphan-parcel check · duplicate-order-per-parcel
check … Develop … raises the orphan/duplicate errors mid-write-loop, after positions have already been
saved"*). So after the fix the fixture that makes AC-1 red today never reaches the write phase at all.
The test goes green because the guard fired, not because the transaction rolled back — and a mutation
check that removes `@Transactional` stays green too, because C still guards. AC-1 would be a passing
test that protects nothing.

**What I would do:** name the failure site in the AC, and pick one that survives the reordering —
e.g. `itemdataService.getById(stockUnit.getItemdataId())` inside D6 (reached only when
`stock.getOrderpositionId() == null`, throws for an unknown itemdata), or a DB constraint violation
on the last position insert. Then keep the C-guard fixture as a *second* test asserting the guard
now fires before any write, which is a real behaviour change worth pinning.

### M3 — AC-7 is a disjunction that passes under both outcomes, and the plan drops the one AC that would grade B1's load-bearing role.

> **AC-7 — concurrency.** Two operators, same BOL, different pallets: **both must complete or one must
> fail with the contention message**; neither may leave a partial BOL.

With B1 taking `findByIdForUpdate` on the `Billoflading` row, two same-BOL scans always serialise:
the second blocks, then proceeds. "Both complete" is the design's expected outcome and "one fails"
only happens on a `lock_timeout`. The disjunction therefore accepts every outcome the design can
produce, and the trailing "neither may leave a partial BOL" is already AC-1's assertion under a
different fixture.

Meanwhile §1.2 identifies a *concurrent* duplicate-number mechanism and says B1 closes it —
*"⚠ This is why **B1 is load-bearing even when the header is unchanged**"* — and then writes no AC
for it. The §1.1 warning that a duplicate-count AC is ungradeable applies to the **field** count over
a natural window; it does not apply to a forced-concurrency test, where two same-BOL scans against
unfixed code genuinely produce a collision and the count is a real kill criterion.

**What I would do:** replace AC-7's disjunction with two concrete assertions — (a) after two
concurrent same-BOL scans, `SELECT billoflading_id, number FROM billoflading_position GROUP BY 1,2
HAVING count(*) > 1` is empty **and** the same query on the unfixed code is non-empty (the control);
(b) the second scan's positions are numbered above the first's high-water mark. That grades B1
directly. `MobilePalletizeRaceIT` remains the right template.

### M4 — §5.3's SDR blind-spot note is wrong: the repository is withdrawn at the interface level.

> *both methods carry `@RestResource(path = …)`, so they are **invocable over HTTP***

`BillofladingPositionRepository` on `origin/develop` carries, at the **interface** level:

```java
@RepositoryRestResource(collectionResourceRel = "billofladingPosition", path = "billofladingPosition", exported = false)
public interface BillofladingPositionRepository extends PagingAndSortingRepository<BillofladingPosition, Long>, CrudRepository<BillofladingPosition, Long> {
```

`exported = false` there withdraws the **whole** repository from the SDR surface; the per-method
`@RestResource(path = …)` annotations are inert. Neither delete is reachable over HTTP. The
*conclusion* ("that direction is unaffected either way") survives, but the premise is inverted, and
in a repo where SDR exposure is an active security topic an inverted SDR premise in a plan is a
hazard on its own.

### M5 — §5.3 point 4 names the wrong arm of `scanDestination`. The conclusion holds; the citation does not.

> `scanDestination` calls `handleTruckOffLoading` in the **non-flow-bin** arm. The only
> `BillofladingPosition`-materialising call in that method is … `assertParcelCarrierNotShipped(...)`
> … and both of its call sites sit in the **mutually exclusive flow-bin `else if` arm**.

`MobileMoveUnitloadService` on `origin/develop` has three arms:

1. `if (destinationStorageLocation != null && !locationType.getSltname().equals(WmsConstants.STORAGE_LOCATION_TYPE_BOX_RESTRICTION_FLOWBIN))` — contains `handleTruckOffLoading(dto.getUnitLoadLabel());`
2. `} else if (destinationStorageLocation != null) {` — *"the destination location is a flow bin"* — contains **neither** call
3. `} else {` — *"if destination location does not exist … see if the destination label matches an UL"* — contains **both** `billofladingPositionService.assertParcelCarrierNotShipped(sourceUnitLoad);` calls

The two guards are in arm **3**, not the flow-bin arm **2**. Arms 1 and 3 are still mutually
exclusive, so P6 is still discharged — but the review that re-checks this will not find what the plan
says is there, and the plan presents §5.3 as a derived enumeration rather than an inspection.

### M6 — §3.1's "all five id-resolution methods must be added" is badged as measured-and-exhaustive but undercounts by two, and one of the five is not needed.

§3.1 says *"Measured against `origin/develop`, **all five id-resolution methods must be added** — none
exists"*, with an *"exhaustive over each file's declared methods"* derivation note. I re-read all six
interfaces on `origin/develop` and the five rows are individually correct. But:

- §3.2 phase A also requires **`findIdByName` on `LocationRepository`** (`arch-target-sequence.md` A6
  makes it explicit: *"`LocationRepository` has `Optional<Location> findByName(...)` and no scalar
  sibling"`). Confirmed — `LocationRepository` has no scalar name/id projection of any kind.
- §5.4 step 3 additionally requires **`findNameById` on `LocationRepository`** (`arch-target-sequence.md`
  C1). Also confirmed absent.

So the real count is **seven**, not five, and the two missing entries are the two the *sequence*
depends on. Conversely, §3.1 row 2 ("pallet unitload id from label — partial") is not needed at all:
§3.2 A probes with the existing `existsByLabelid` and B2 locks with the existing
`findByLabelidForUpdate(palletLabel)`, so no pallet-id projection is ever used.

A "measured, not estimated" table that misses two required additions is the kind of closed
enumeration the repo's own claim discipline says to distrust. Restate it as **seven**, or scope the
sentence to "the five on the BOL/Unitload/Customerorder/Stockunit axis".

### M7 — AC-3's mutation check and AC-3's assertion contradict each other, and the kill criterion silently depends on AC-4's answer.

AC-3 says both:

> Assert the invariant, not the instance: **no write may be pending when the clear fires.**

and

> Mutation-check by moving the call back after the writes and confirming the test goes red **with a
> message that names the lost write**.

These grade different things. "No write is pending" is checkable regardless of the flush question and
its mutant is reliably red. "Names the lost write" requires a write to actually be lost — which only
happens if Bug 4a resolves **false**. If the native query does force a full flush, moving D0 after the
writes loses nothing, and the prescribed mutation check stays green against a mutant that is genuinely
harmful for the *other* reason (the identity split). The plan sequences AC-4 first in §5.4, so the
answer will be known — but as written AC-3's kill criterion is conditional on it and does not say so.

Pick one: assert "no pending write at D0" and mutation-check on *that* (my recommendation), and keep
"names the lost write" only as a stronger assertion to add if AC-4 comes back false.

---

## LOW

### L1 — `PessimisticLockingFailureException` is Bug **7**, not Bug 6. Three sites.

§2's *Affected locations* table (`controller/mobile/TruckLoadingController.java` — *"unchanged — see
Bug 6"*), §4.1 (*"Translating `PessimisticLockingFailureException` … (Bug 6)"*) and AC-6 (*"not a raw
500 (Bug 6)"*) all point at Bug 6 (first-touch violations). The defect described is Bug 7. Bug 6 is
also mis-referenced as the reason the controller is unchanged, which is the opposite of what Bug 6
says.

### L2 — §6.1's `MobileTruckLoadingServiceUnitTest` warning is incomplete: **three** constructor args go null, not two.

> It omits `@Mock` fields for `itemdataService` and `manageOrderService`, so `@InjectMocks` passes
> `null` for both.

The class declares 13 `@Mock` fields against a 15-arg constructor, and one of the 13 is the wrong
type: it mocks **`SyspropRepository`** where the constructor takes **`SyspropService`**. So
`@InjectMocks` passes `null` for `syspropService`, `itemdataService` **and** `manageOrderService`.
`syspropService` matters for this ticket specifically — `handleTruckOffLoading` opens with
`syspropService.getSysvalue(...)` twice, so a D0-bearing test in that class NPEs before it reaches
the OMS notification the plan warns about.

### L3 — The D0-vs-front deadlock comparison omits the precondition that makes only one of them reachable.

Both `scanGate` (B1) and `closeBOL` take `billofladingRepository.findByIdForUpdate(bolId)` as their
first lock (`BillofladingService.java`, *"Acquire pessimistic lock on the BOL row to prevent
concurrent closeBOL"*). On the **same** BOL they therefore serialise on that row and **neither**
placement can cycle. The D0 cycle the plan describes requires the two sessions to be on *different*
BOLs, with `scanGate`'s D0 deleting a stale position that belongs to `closeBOL`'s BOL — reachable,
because `findBolIdByUnitLoadLabelId` matches by pallet label across all BOLs, and it is precisely the
cross-BOL case `handleTruckOffLoading` exists to serve. Say so; as written a reader checks the
same-BOL case, finds no cycle, and concludes the section is wrong.

### L4 — `transferUnitLoadToLocation` touches two `unitload`/`location` rows the plan's lock set does not enumerate.

Both are benign, both should be in the javadoc's residuals rather than discovered later:

- `Unitload parentUnitload = unitloadRepository.findById(carrierunitloadId)` — fires when the pallet
  itself has a carrier. Not in B's `{pallet, parcels}` set, never locked.
- `Location sourceLocation = locationRepository.findById(storagelocationId)` — the pallet's *current*
  location, a second `Location` row beyond the gate. Residual #3 speaks only of the gate.

There is also `stockunitRepository.findByUnitloadId(unitload.getId())` inside the
`if (fixLocationAssignment != null)` branch — the *pallet's* stock units, disjoint from B4's
*parcel* stock units.

### L5 — §3.2 B4/B6 materialise `Stockunit` and `CustomerorderPosition` entities, and residual #4 should say that is what makes the later swap non-trivial.

Residual #4 says that if a real writer of `stockunit.amount` exists, *"swap to locked finders **at the
same positions** — the sequence is already correct for that."* It is correct positionally, but B4/B6
as written materialise the entities with a plain read, so the swap is not a one-line substitution: it
is a first-touch violation the moment the unlocked read stays in. The swap must **replace** the
unlocked read, not precede it. One sentence; worth having because the plan's own Bug 6 is exactly
this failure mode.

### L6 — `findBolIdByUnitLoadLabelId` has no `ORDER BY` and no `LIMIT`, so §4.2.2's exposure is order-dependent as well as count-dependent.

```java
@Query(value = "select bp.id from billoflading_position bp join unitload u on bp.source_id = u.id where u.labelid = :unitLoadLabelId", nativeQuery = true)
Long findBolIdByUnitLoadLabelId(@Param("unitLoadLabelId") String unitLoadLabelId);
```

§4.2.2 correctly records the `IncorrectResultSizeDataAccessException` risk at >1 row and measures 0
exposure on both tenants. Worth adding that the query also spans **all** BOLs for that label, so the
activation condition is "a pallet re-used across two BOLs without cleanup" rather than anything
scan-rate-related — which is the shape of the tote-reuse family the plan compares it to.

---

## Calibration — things I went after and the plan got right

These were my five best candidates for a wrong answer. All five check out against `origin/develop`,
and I want that on the record so this review is not read as uniformly negative.

1. **Bug 6a (the gate `Location` upgrade) is a real, live defect — the plan did not invent it.**
   `scanGate` materialises the row (`Optional<Location> gateOpt = locationRepository.findByName(truckLoadingMobileDTO.getScannedGateName());`)
   and `UnitloadBusinessService.transferUnitLoadToLocation` locks that same row under `ignoreLock=false`:
   ```java
   if (!ignoreLock) {
       final Long destinationLocationId = destinationLocation.getId();
       destinationLocation = locationRepository.findByIdForUpdate(destinationLocationId)
   ```
   and `scanGate` passes `false`. Under a boundary that is a textbook upgrade, and it is invisible
   from `scanGate`'s own source exactly as the plan says.

2. **Bug 4a's correction is right, and the earlier draft it overrides was wrong.** `EntityManager.clear()`
   issues no SQL and cannot release a PostgreSQL row lock. The plan's decision to record the wrong
   version rather than delete it — specifically to stop a reviewer demanding ~142 re-acquisitions —
   is good practice and it worked on me: that was on my list to propose.

3. **Bug 5 and Bug 7 are both confirmed verbatim.** `ManageOrderService.customerOrderLoadedToTruck`
   runs `createOrderBatch(representative)` (→ `customerorderBatchRepository.findById(...)`) and a
   per-order `unitloadRepository.findById(customerOrder.getParcelId())` **before** reaching
   `omsNotificationService.sendAfterCommit(...)`. `TruckLoadingController.scanGate` catches only
   `BusinessException` and `FacadeException` and returns `ResponseEntity.ok(errorMap)` in both cases.

4. **C-10 (D0 before every `createEntity`) is correct and non-obvious.** `findBolIdByUnitLoadLabelId`
   joins `bp.source_id = u.id`, which is exactly the row D4 inserts; running the purge after D4/D5
   would delete the tree the scan just built. I tried to find a placement between D4 and D5 that
   avoids it — there is none.

5. **No `Pickingorder` lock class is missed.** I expected `transferUnitLoadToLocation`'s SBDEV-2481
   pre-walk (`pickLineRealignmentService.lockOwningPickingorders(treeStockUnitIds)`) to add an
   unranked lock class the plan never mentions. It is gated on
   `PickLineActivityCodeClassifier.classify(activityCode, null) == Bucket.BLOCK_REALIGN`, and the
   in-file javadoc states *"PASS_THROUGH (shipping / **truck-load** / receiving / putaway / split /
   nirvana) falls straight through"*. `CODE_TRUCK_LOADING = "TRUCKLOADING"` is PASS_THROUGH, so no
   `Pickingorder` lock is taken on this path. The plan's silence is correct.

Also correct, spot-checked and not otherwise mentioned: the two frozen `OptionalSafetyArchTest`
entries for `scanGate` exist and are exactly two (`MobileTruckLoadingService.java:190` and `:207`,
plus a third for `truckLoadingMobileDTOByBolName`); `§5.3` step 1's "two Java call sites, both inside
`handleTruckOffLoading`" is exact over `src/main`; `handleTruckOffLoading` has exactly the two callers
claimed; `CustomerorderPositionRepository.findByOrderIdForUpdate` is indeed the multi-row `@Lock`
described, and it does carry `ORDER BY cp.id`; and AC-1 is **not** the vacuous
"count-stays-at-zero" AC the plan warned itself against — it is scoped to an injected failure with a
control, which is the right shape (its problem is M2, not vacuity).

---

## Method, instruments and blind spots

- **Source**: `git show origin/develop:<path>` and `git grep … origin/develop` only, at
  `f2ee75f1`. `git log -S<symbol>` for dating; `git show <sha> -- <path>` to read the introducing
  diffs. Blind spot: `-S` dates when a *string* first entered the tree, so a symbol renamed into
  existence would date late. I cross-checked each with the introducing commit's diff, which showed
  additions, not renames.
- **DB**: `nywh-hydra-uat` MCP. Every aggregate carried its control in the same `SELECT`, so a dropped
  connection errors rather than returning a silent zero (the first call did in fact error with
  *"server closed the connection unexpectedly"* and was retried). Blind spot: I did not re-run the
  prd side; H3's numbers are UAT-only and the plan's prd figures are unchallenged.
- **Epoch inference** (H1/H2): I inferred the formula epochs from the suffix of each BOL's
  lowest-id position plus the commit diffs. Blind spot: the 2021–2024 rows were written by code that
  is in **no** git history available here, so "the 2024 epoch used `size()+1`" is inferred from the
  data fitting, not read from source. What *is* read from source, and is not an inference, is that
  `origin/develop` computes `size()` and that the March-2025 commits changed this code.
- **Not checked**: the failsafe baseline (P4, still open in the plan); `laneB-test-surface.md` beyond
  the four §6.1 predictions; whether Hydra UAT was running v1 or v2 on any given date, which is the
  one fact that would let H2's epoch argument be stated even more sharply.
- I did not edit the plan or any other file.
