---
title: "WMSv2: Transfer and Club item lists show no warehouse-wide stock figure — only what is staged on the lane"
ticket: "SBDEV-2951"
ticket_url: "https://app.clickup.com/t/868kr4zhb"
type: "bugfix"
priority: "high"
status: "ARCHIVED 2026-08-28 — MERGED to develop 2026-08-15 (API first). ClickUp `on dev`."
    wms2-api    PR #157  merge 945e8e8  bugfix/SBDEV-2951-transfer-club-onhand-quantity
    wms2-web-ui PR  #60  merge f5596fa  bugfix/SBDEV-2951-transfer-club-onhand-column
  Verify 35 pass / 0 fail / 0 skip. API suite 5046 run / 2 fail = develop baseline. Jest 17/17 (355 total).
  Conformance 11/11 ACs. Code review 0 High / 2 Medium FIXED / 7 Low deferred. Security LOW, 0 High.
  NOT DONE: the 10 manual rows M1-M10 (AC5 + AC10 have no automated evidence) — ARCHIVE-GATED on
  manual QA, M3 is the STOP row. No deploy prerequisite — no migration, no sysprop."
project: ["wms2"]
version: "v2"
requester: "Brent (BA)"
created: "2026-08-13"
updated: "2026-08-15"
db_verified: true
related:
  - "SBDEV-2952"
  - "260424-Run_Club_Availability_Exception_Analysis_2026-04-05"
  - "SBDEV-1762-transfer-lane-club-like-depletion"
tags:
  - plan
---

> Acceptance script retired to `sbdocs/4-Archieves/scripts/verify-SBDEV-2951-transfer-club-available-counts-lane-only.sh`
> Implementation worktree(s) removed 2026-08-28: wms2-api/SBDEV-2951, wms2-web-ui/SBDEV-2951
> §5.4's implementation checklist was never ticked; it is a PRE-implementation checklist and the plan shipped. Archived on the §10.1 decisions, all resolved 2026-08-13.

# WMSv2: Transfer and Club item lists show no warehouse-wide stock figure

**Ticket:** [SBDEV-2951](https://app.clickup.com/t/868kr4zhb)
**Project:** wms2 | **Version:** v2 | **Type:** bugfix
**Priority:** high
**Status:** merged to `develop` 2026-08-15 — ClickUp `on dev`, archive-gated on manual QA (M1–M10)
**Date:** 2026-08-13
**Repos:** `v2/wms2-api` **and** `v2/wms2-web-ui` (two PRs, API first)

> [!warning] **r1 → r2: the Architect pass falsified TWO of r1's load-bearing claims. Read §1.4 and §2.4 before anything else.**
> **H1** — r1 (and the ticket, and my reply to the reporter) said the column is labelled "Available". **It is not.**
> The headers read `Qty at Lane` / `Total at Lane`; `grep -c "text: 'Available'"` returns **0** in all three
> components. The defect is a **missing column**, not a mislabel. The relabel is cancelled (D3').
> **H2** — r1's "mirror the Available Inventory tab's predicate" **excludes the transfer lane itself.** All
> **22** lane-assigned transfer orders point at `TransferLane01`–`06`, which that predicate omits, so r1
> would have rendered `Qty at Lane 500 / On hand 0` on a fully-staged order and made staging *decrease*
> On hand. Basis changed to sink-exclusion (D1').

---

## 0. Affected sites (enumeration before drafting)

### 0.1 API — `v2/wms2-api/src/main/java/net/aim_ai/wms/`

| # | File:line | Construct | Same root cause? | In scope? |
|---|---|---|---|---|
| 1 | `service/TransferOrderService.java:279-284` | `getSKUOverview` — only a lane-scoped figure exists | yes | **yes** — Fix A |
| 2 | `service/CustomerorderBatchService.java:1265-1273` | club equivalent (method at `:1223`), same shape + dead `amount != 0` at `:1269` | yes | **yes** — Fix A |
| 3 | `json/ClubLineSkuDto.java:43-51` | DTO shared by both flows | carrier | **yes** — Fix B (additive) |
| 4 | `repo/jpa/StockunitRepository.java:81-92` `getAmountAvailable` | single-location; **3 callers**; ⚠ **HAL-exported** (no `exported=false`) so its signature is a public contract | correct as-is | **NOT MODIFIED** — sibling added instead |
| 5 | `repo/jpa/UnitloadRepository.java:106-114` | the tab's source predicate | ⚠ **no longer mirrored** (H2) | **NOT MODIFIED, NOT REFERENCED** |
| 6 | `service/mobile/MobileTransferOrderService.java:413-415` `calculateStockOnStagingLane` (`:181`, `:221`, `:375`) | same query, **correctly named**, move arithmetic not display | no | no |
| 7 | `service/TransferOrderService.java:180-196` | SBDEV-1762 sysprop-gated partial depletion, lane-scoped by design | no | no |
| 8 | `controller/TransfersController.java:332-336` `GET /v3/transfers/skus` | passthrough | — | no change |
| 9 | `controller/ClubLineController.java:255` `POST /v3/clubLine/skus` | passthrough | — | no change |
| 10 | `repo/projection/ItemdataOnHandView.java` | **NEW** projection (`…View`, per all 49 local files) | new | **yes** — Fix C |
| 11 | `service/OnHandQuantityService.java` | **NEW** — the one shared method | new | **yes** — Fix C |
| 12 | `service/LocationService.java:117-120` `getClearing()` → `orElse(null)` | r1 would have dereferenced it | — | **no longer touched** — D1' needs no clearing id |

### 0.2 Web UI — `v2/wms2-web-ui/`

| # | File:line | Construct | In scope? |
|---|---|---|---|
| 13 | `processes/transferPicking/itemsTable.vue` — header `:61` **`Qty at Lane`**, `:64` binding, `:93` `showBadge`, `:100` `readyToMove`, `:5` Run gate | primary | **yes** — Fix D, **add column only** |
| 14 | `processes/clubRuns/itemsTable.vue` — header `:98` **`Total at Lane`**, `:101` binding, `:182` `showBadge`, `:153` `disableRun`, `:9` Run gate | primary | **yes** — Fix D, **add column only** |
| 15 | `outbound/transfer/transferDetailsTable.vue` — header `:92` **`Qty at Lane`**, `:95` binding, `:120` `showBadge`, badge only, **no Run button** | third surface | **yes** — Fix D |
| 16 | `store/processes/transferPicking.js:183`, `store/processes/clubRuns.js:201`, `store/outbound/transfer.js:225`, `store/outbound/outboundBols.js:201-208` | four `/skus` callers | **verified only** — ⚠ `outboundBols.itemInfo` has **zero consumers**; it is set and never read |
| 17 | `outbound/pickPack/parcelDetailsTable.vue:142` | `amountAvailable` from a **different** endpoint (`outbound.pickPack.itemInfo`) | no |
| 18 | `outbound/club/batchContentTable.vue:109-115` | column **commented out** (label was also `Qty at Lane`) | no |

---

## 1. Problem Statement

**There is no warehouse-wide stock figure anywhere on the Transfer Picking or Club Run item list.** The only
quantity shown beside "Required" is what currently sits on the order's lane. On any order not yet staged —
which is *every* transfer order before a lane is assigned — that figure is `0`.

For a routine top-up transfer this is harmless: you stage, the number fills in. For the case that raised
the ticket — **pulling all of a product out of the warehouse** — the operator cannot see, per line, how much
exists to pull. The warehouse-wide number exists only on a different tab, one click away, with no
per-line comparison against Required.

**Provenance.** Raised by Brent (BA), 2026-08-13, as *"should we show pickable locations in the transfer
process?"*. Pickable locations **are** already sourced and displayed (§1.3). The missing figure is the defect.

### 1.1 DB verification (protocol §8) — `db_verified: true`

`wms2-wineco-dev` = DB **`dev_wh01_om1`** (wineco/wsl), Flyway head `2.2.16`. **Every figure below was
independently re-measured by the Architect pass and reproduced to the unit.**

| Check | Result |
|---|---|
| transfer: open batches (`type LIKE 'TRANSFER%' AND state = 0`) with **no** lane | **52** |
| club: batches `state < 700` with **no** staging lane | **14** |
| positions displaying `0` | **52 of 54** |
| ~~units of those SKUs actually on hand — 171,004~~ | ⚠ **WITHDRAWN (Critic Minor 1).** Did not reproduce under any of five readings; the original query summed **per position**, not per distinct SKU, over the now-abandoned tab predicate. Correct figure for the 52 zero-display positions: **4 distinct SKUs / 16,989 net units** |
| **SINK TRAP** — units in `Shipped` + `Nirwana` | **2,856,635** |
| **chosen basis** — sink-exclusion, reserved-adjusted, lock-aware (D1') | **409,515** |
| raw within the D1' scope (for the delta decomposition, §2.5) | **431,597** |
| r1's rejected basis — tab predicate, same adjustments | 409,104 ⚠ |
| tab's own displayed basis — raw amount, no lock filter | 429,454 ⚠ |

⚠ The last two rows are the **only** figures in this plan a reviewer cannot independently re-derive, because
the predicate they were measured with is the one D1' abandoned. They are retained solely to show the size of
the decision. **Do not build anything on them.**

⚠ **The defect is NOT confined to laneless orders** (Critic Minor 4): of 34 lane-**assigned** transfer
positions, only **4** have any lane stock at all, so **30 of 34 also display `0`**. AC1's laneless framing
is the cleanest reproduction, not the boundary of the problem.

Both criteria are reproducible **today**: 52 laneless transfer batches, 14 laneless club batches. No fixture
construction needed.

### 1.2 Carrier-hierarchy verification — why a flat aggregate is sound

`calcOptimized` (`TransferOrderService.java:427-445`) recurses into child ULs, fed by a **depth-unbounded**
pre-fetch (`:356-371`). A flat aggregate is equivalent only if nested ULs carry their own location:

| Check | Result |
|---|---|
| stock units on nested ULs | 1,409,621 (87%) |
| …carrying their own `storagelocation_id` | **1,409,621 — all** |
| …with `NULL` location | **0** |
| …whose location differs from their carrier's | **35** |

⚠ **The Architect tested this harder than r1 did** — reproducing the full traversal in SQL (seed → walk up
to roots → walk down to all descendants) and comparing per-SKU totals:

| Metric | Result |
|---|---|
| SKUs compared | **2,682** |
| SKUs where traversal ≠ flat | **0** |
| traversal total vs flat total | **429,454 = 429,454** |

**Exact equivalence.** No recursion needed, nothing double-counted, nothing missed. The 35 divergent rows
are a per-row *display attribution* difference, not a per-SKU total difference.

### 1.3 What is NOT broken — do not "fix" these

- **Pick faces are already sourced and displayed.** `Storage and Picking` (id 51553, the one `useforpicking`
  area) is on both flows' source whitelist: 2,137 locations, 1,354 stock-bearing, 62,797 units. The Location
  column exists at `availableInventory.vue:90` in both. **Adding a location column is the wrong fix.**
- **The tab split is the original confusion's cause, not a defect.**
- **`getAmountAvailable` is correct.** Three callers depend on its lane semantics, and it is HAL-exported.
- ⚠ **`Qty at Lane: 0` is an accurate label.** See §1.4.

### 1.4 ⚠ H1 — CORRECTION: the "Available" label does not exist

r1, **this ticket's original title and body**, and my reply to the reporter all asserted the column is
labelled "Available". Measured:

| Surface | Actual header |
|---|---|
| `processes/transferPicking/itemsTable.vue:61` | **`Qty at Lane`** |
| `processes/clubRuns/itemsTable.vue:98` | **`Total at Lane`** |
| `outbound/transfer/transferDetailsTable.vue:92` | **`Qty at Lane`** |

`grep -c "text: 'Available'"` → **0** in all three. Identical on `origin/develop`; `git log -S"Qty at Lane"`
returns one commit (`3462148 initial check in the code`). **"Available" came from the DTO field name
`amountAvailable`, and nobody checked the rendered header.**

**Consequences:**
- The defect is **a missing column**, not a mislabel. `Qty at Lane: 0` is honest.
- **The relabel is cancelled (D3').** `Qty at Lane` is *more* precise than "Staged": stock can sit on a lane
  without having been staged for *this* order — SBDEV-1762's partial-depletion residue
  (`TransferOrderService.java:180-196`) is exactly that case.
- D2's rationale ("Available must not mean two things") is void; the column is never labelled "Available".
- Ticket title and a correction comment updated 2026-08-13.

---

## 2. Root Cause Analysis

### Bug 1 — the only quantity beside "Required" is lane-scoped, in two clones

`TransferOrderService.java:279-284`:
```java
if (transferLaneId == null) {
    dto.setAmountAvailable(0);
} else {
    Integer amount = stockunitRepository.getAmountAvailable(transferLaneId, itemData.getId());
    dto.setAmountAvailable(amount != null ? amount : 0);
}
```
`CustomerorderBatchService.java:1265-1273` — identical on `getStaginglaneId()`, plus a dead branch at `:1269`.

`StockunitRepository.java:82-92` is single-location by construction (`WHERE location.id = :locationId`),
reserved-adjusted, and lock-aware. **The query is right and the label is right. The figure is simply the
only one there is.**

### 2.1 ⚠⚠ THE LOAD-BEARING CONSTRAINT — `amountAvailable` GATES THE RUN ACTION

**Independently confirmed by the Architect against every cited line.**

| Site | Binding |
|---|---|
| `transferPicking/itemsTable.vue:5` | `:disabled="!readyToMove() \|\| isPacked()"` — **Run Transfer** |
| `transferPicking/itemsTable.vue:100-109` | `readyToMove()` loops `showBadge()` over every row |
| `transferPicking/itemsTable.vue:93-99` | `showBadge(item)` — `item.amountAvailable >= item.amountRequired` |
| `transferPicking/itemsTable.vue:4` | subtitle: *"Still waiting for all inventory to be moved to {lane}"* |
| `clubRuns/itemsTable.vue:9` | `:disabled="disableRun \|\| isClubRun"` — **Run Club Line** |
| `clubRuns/itemsTable.vue:153-174` | `disableRun()` reads `amountAvailable` at `:159` |
| `outbound/transfer/transferDetailsTable.vue:120-126` | badge only, no Run button |

> **REPOINTING `amountAvailable` WOULD MAKE `readyToMove()` / `disableRun` TRUE FOR ANY ORDER WHOSE SKUs
> MERELY EXIST IN THE WAREHOUSE** — Run enabled against an empty lane. **Severe functional regression,
> worse than the reported bug.**

**Hence the fix is STRICTLY ADDITIVE (D4).** New field, new column. `amountAvailable` keeps its value,
name, type — and its gate. **AC6 exists solely to pin this.**

### 2.2 Prior art — cited, not contradicted

`4-Archieves/wms2/plan/260424-Run_Club_Availability_Exception_Analysis_2026-04-05.md` carries **"Fix 5 —
correct misleading 'available' reporting"** (`:165-167`) and at `:116`: *"This can mislead
UI/users/operators into believing staging-lane stock is available when it is only present physically but
fully reserved."*

**Status determined from code:** the repository half shipped (`getAmountAvailable` is reserved-adjusted).
The remaining half is the **tab's** raw-amount display, not a label — see Q1.

Also consulted: `SBDEV-1762` (partial depletion; the reason "Staged" would be a *worse* label),
`260424-phase2-n-plus-1-batch-fetch-implementation-plan.md` and `260424-TRANSFER_ORDER_PERFORMANCE_PLAN.md`
— **both overviews were deliberately reduced from 2×P queries to 2.** A per-SKU on-hand call in the existing
loop reintroduces exactly that N+1. Hence AC8 and Fix C's batch shape.

### 2.3 Why native SQL is FORCED, not chosen

`Stockunit`, `Unitload` and `Location` carry **zero** `@ManyToOne` / `@OneToMany` / `@JoinColumn` — the
monorepo rule is *"no JPA association annotations — manual FK relationships only."* A JPQL
`stockunit → unitload → location` join is therefore **impossible** without adding associations the project
forbids. Native SQL is the only option. (r1 omitted this; it is Fix C's strongest defense.)

Likewise, **reshaping `getAmountAvailable` into a set-based query is not available**: it is HAL-exported at
`/v3/stockunit/search/getAmountAvailable` (`StockunitRepository.java:81`, no `exported=false`), so its
signature is a public contract that no service-layer change can guard. A sibling is required.

### 2.4 ⚠ H2 — CORRECTION: r1's mirrored predicate excluded the transfer lane

r1 mirrored `UnitloadRepository:113` so the item list would "agree with the tab". Measured:

| Location | `staginglane` | `transferlane` | area | in r1's basis? | transfer orders pointing here |
|---|---|---|---|---|---|
| `TransferLane01`–`06` (59200-59205) | **false** | true | `Outbound` | **NO** | **22 — every lane-assigned transfer order** |
| `StagingLane01`–`20` (51619+) | true | false | `Outbound` | yes | 0 |

`getAmountAvailable` keys on `location.id` with **no** area filter, so `Qty at Lane` counts the transfer
lane; r1's predicate did not. Consequences r1 would have shipped:

1. The two columns cover **disjoint** location sets on every transfer order.
2. Staging stock would **decrease** On hand by exactly the amount staged, while the operator watched.
3. A fully-staged order would render **`Qty at Lane 500 / On hand 0`** — reproducing the reported symptom
   on the happy path.
4. **Club would behave the opposite way** (staging lanes carry `staginglane = true`), so the two screens
   this plan exists to align would diverge.

**None of r1's nine acceptance criteria could detect it** — AC5/M7 asserted only `Qty at Lane == Required`.

**Resolved by D1'** (sink-exclusion): the transfer lane is included, so **On hand ⊇ Qty at Lane always**, on
both flows. **AC10 and M10 exist to pin it.**

### 2.5 The reserve/lock axis — decided, and it stands

`calcOptimized:439` sums **raw** `stockUnit.getAmount()` with no reserve or lock filter, so the tab's basis
exceeds a reserved-adjusted, lock-aware one. **D1 (kept): reserved-adjusted + lock-aware.**

⚠ **The principle, stated precisely (narrowed after Critic MJ3).** "Unmovable" here means **reserved or
locked** — nothing more. `On hand` **deliberately includes**:

| bucket inside the 409,515 | net units |
|---|---|
| other storage (non-pickable) | 315,980 |
| pickable areas | 62,618 |
| ⚠ **staging / transfer lanes — i.e. stock staged for _other_ orders** | **28,367** |
| ⚠ `users`-area locations (e.g. `panderson` = 1,418) | **2,547** |
| damaged | 3 |

So roughly **7% of the figure is stock committed to someone else's order** — `StagingLane07` alone holds
27,122 net units — and reserved-adjustment does **not** net that out, because lane stock often carries no
reservation (SBDEV-1762's residue is exactly that). **This is an information-quality trade-off, accepted:**
the column is labelled *On hand*, not *Available to pull*, and per D4 it **never gates an action**, so an
over-report has no functional blast radius. It is recorded here rather than left implicit, and it must be
restated in `onHandByItemdata`'s javadoc — "On hand" is the word the operator interprets.

⚠ **Delta to the tab — corrected arithmetic (Critic MJ5).** r2 computed `429,454 − 409,515 = 19,939` by
subtracting across **two different location scopes** and labelling the result "reserved + locked". Measured
within a single scope:

| | units |
|---|---|
| raw, sink-excluded (D1' scope, no reserve/lock filter) | **431,597** |
| D1' basis (reserved-adjusted + lock-aware) | **409,515** |
| ⇒ **reserved + locked inside the D1' scope** | **22,082** |
| the tab's narrower location set removes 2,143 of those, hence the 19,939 headline | — |

**M6 must expect 22,082-class differences, not 19,939** — and for any SKU with stock in `Palletizing`,
`Damaged`, `Gate_01` or a `users` location the tab comparison will *not* reconcile at all, because those
locations are in D1''s scope and not the tab's. **Documented and expected — not a bug.**

---

## 3. Fix Design

### Fix A — both overviews populate a new on-hand figure (API)

**Before** (transfer; club identical in shape):
```java
for (CustomerorderPosition position : positions) {
    ...
    if (transferLaneId == null) { dto.setAmountAvailable(0); }
    else { Integer amount = stockunitRepository.getAmountAvailable(transferLaneId, itemData.getId());
           dto.setAmountAvailable(amount != null ? amount : 0); }
    skuList.add(dto);
}
```

**After:**
```java
// ONE query for every SKU on the order -- NOT per-position. §2.2: both overviews were deliberately
// reduced to 2 queries; a per-SKU call here reintroduces that N+1. itemdataIds already exists
// (TransferOrderService:252-253 / CustomerorderBatchService:1239) -- reuse it, do not recompute.
Map<Long, Integer> onHand = onHandQuantityService.onHandByItemdata(itemdataIds);

for (CustomerorderPosition position : positions) {
    ...
    // UNCHANGED -- lane-scoped, and it GATES Run Transfer / Run Club Line (§2.1).
    if (transferLaneId == null) { dto.setAmountAvailable(0); }
    else { Integer amount = stockunitRepository.getAmountAvailable(transferLaneId, itemData.getId());
           dto.setAmountAvailable(amount != null ? amount : 0); }

    dto.setAmountOnHand(onHand.getOrDefault(itemData.getId(), 0));   // NEW, additive
    skuList.add(dto);
}
```

Also: collapse the club's dead `amount != 0` branch (`:1269`). ⚠ **Spelled out verbatim, because the
obvious shorthand is a functional regression.** Replace the whole `else` block with exactly:
```java
} else {
    Integer amount = stockunitRepository.getAmountAvailable(orderBatch.getStaginglaneId(), itemData.getId());
    dto.setAmountAvailable(amount != null ? amount : 0);   // identical to the transfer side
}
```
**Do NOT delete the `else` arm** and leave `amountAvailable` null. `null` reaches the UI as `null`, and
`null < required` evaluates **false** in JavaScript, so `disableRun` would return `false` → **Run Club Line
enabled on an empty lane.** That is R1 arriving through a side door, from a change described as cleanup.

⚠ **Both callers use `private final` + explicit constructor** (`TransferOrderService.java:30`,
`CustomerorderBatchService`'s ~29-parameter constructor). Add the dependency there — **not** an
`@Autowired` field. And **both `…UnitTest` classes already exist and use `@InjectMocks`**: the new
constructor parameter needs a matching `@Mock` or Mockito injects `null` silently.

### Fix B — `ClubLineSkuDto` gains `amountOnHand` (additive only)

```java
private Integer amountOnHand;   // warehouse-wide, reserved-adjusted, lock-aware. NOT the Run gate.
public Integer getAmountOnHand() { return amountOnHand; }
public void setAmountOnHand(Integer amountOnHand) { this.amountOnHand = amountOnHand; }
```

Additive. `amountAvailable` keeps its name, type and value — renaming it is the contract break this fix must
not make. Verified: exactly five components read `amountAvailable`; the four store callers read named
properties, and `outboundBols.itemInfo` has **zero consumers**.

### Fix C — `OnHandQuantityService` + one batch projection query

**Why a NEW service (D5', restated with the real reason):** a shared read-only stock home already exists
(`WarehouseStockReportService`), but its basis is **incompatible** — `stock_view.total_stock` excludes
sinks by `entity_lock NOT IN (405,2)` with **no location join and no reserved subtraction**, summing to
**431,597** against this plan's 409,515. Grafting a third basis onto that bean would put two contradictory
"stock" numbers behind one service. And `CustomerorderBatchService` is already 1,312 lines / ~29
constructor parameters. A dedicated bean is the honest home.

```java
@Service
public class OnHandQuantityService {

    private static final Logger LOG = LoggerFactory.getLogger(OnHandQuantityService.class);
    // BOTH constants already exist -- WmsConstants:765 and :775. Do not add either.
    private static final List<String> SINK_LOCATIONS = List.of(
            WmsConstants.STORAGE_LOCATION_NIRVANA,      // "Nirwana" -- note the spelling
            WmsConstants.STORAGE_LOCATION_SHIPPED);     // "Shipped"

    private final StockunitRepository stockunitRepository;

    public OnHandQuantityService(StockunitRepository stockunitRepository) {
        this.stockunitRepository = stockunitRepository;
    }

    /**
     * Warehouse-wide on-hand per SKU, for DISPLAY ONLY.
     *
     * <p>Basis (decision D1'): every location EXCEPT the two terminal sinks, reserved-adjusted and
     * lock-aware. This deliberately does NOT mirror the Available Inventory tab's source predicate --
     * that predicate excludes TransferLane01-06, which every lane-assigned transfer order uses, so
     * mirroring it made On hand DISJOINT from Qty at Lane and made staging decrease this number (§2.4).
     * Consequence of the chosen basis: On hand >= Qty at Lane, always, on both flows.
     *
     * <p>It differs from the tab's displayed rows by reserved + locked stock (19,939 units measured on
     * wineco-dev) because the tab sums RAW amount at calcOptimized:439. Expected -- see §2.5.
     *
     * <p>⚠ NEVER gate an action on this. amountAvailable gates Run Transfer / Run Club Line and is
     * lane-scoped on purpose (§2.1).
     */
    @Transactional(value = "tenantTransactionManager", readOnly = true)
    public Map<Long, Integer> onHandByItemdata(Set<Long> itemdataIds) {
        if (itemdataIds == null || itemdataIds.isEmpty()) {
            return Collections.emptyMap();     // an empty IN (...) is a SQL syntax error
        }
        LOG.debug("start with itemdataIdCount={}", itemdataIds.size());
        return stockunitRepository.sumOnHandByItemdataIds(itemdataIds, SINK_LOCATIONS).stream()
                .collect(Collectors.toMap(ItemdataOnHandView::getItemdataId,
                        v -> v.getAmount() == null ? 0 : v.getAmount().intValue()));
    }
}
```

New query on `StockunitRepository`:
```java
@RestResource(exported = false)   // see design point 2
@Query(value = "SELECT su.itemdata_id AS itemdataId, SUM(su.amount - su.reservedamount) AS amount "
    + "FROM stockunit su "
    + "INNER JOIN unitload ul ON su.unitload_id = ul.id "
    + "INNER JOIN location lo ON ul.storagelocation_id = lo.id "
    + "WHERE su.itemdata_id IN (:itemdataIds) "
    + "AND lo.name NOT IN (:sinkLocationNames) "
    + "AND su.entity_lock = 0 AND ul.entity_lock = 0 AND lo.entity_lock = 0 "
    + "AND su.amount > su.reservedamount "
    + "GROUP BY su.itemdata_id", nativeQuery = true)
List<ItemdataOnHandView> sumOnHandByItemdataIds(@Param("itemdataIds") Collection<Long> itemdataIds,
                                               @Param("sinkLocationNames") Collection<String> sinkLocationNames);
```

```java
public interface ItemdataOnHandView {
    Long getItemdataId();
    BigDecimal getAmount();     // SUM over numeric(_,4) -> BigDecimal. Declared explicitly: the local
                                // convention (StockunitLocationView, StockunitAvailableView) uses
                                // Object getAmount(), against which .intValue() would not compile.
}
```

**Design points, each load-bearing:**

1. **`lo.name NOT IN (:sinkLocationNames)` excludes `Shipped` (2,856,635 units) and `Nirwana`** — the trap
   in this ticket. Shipped alone is 87% of the tenant's stock rows; counting it would look entirely
   plausible and be catastrophically wrong. This is the **established local idiom**: the closest precedent
   is `ReplenishorderRepository.java:174, 192, 209` — `storageLocation.name NOT IN (:nirvana, :shipped)`
   with **two scalar parameters**, which is also acceptable here and sidesteps collection binding entirely;
   `ViewWarehouseLocationReportRepository.java:33` uses hardcoded literals.
   ✅ **Both constants ALREADY EXIST** — `WmsConstants:765` `STORAGE_LOCATION_NIRVANA = "Nirwana"` (note the
   spelling) and `WmsConstants:775` `STORAGE_LOCATION_SHIPPED = "Shipped"`, the latter with 13 call sites
   including `LocationService.getShipped()`. **Do not add either** — r2 wrongly claimed `Shipped` had none,
   which would have produced `variable STORAGE_LOCATION_SHIPPED is already defined`.
   ⚠ The filter is **name-based with no runtime guard** (R9): on a tenant whose sink is not named exactly
   `Shipped`, R2's 2.8M-unit inflation fires **silently** and every grep-based check still passes. M4 is
   the only detector.
2. **`@RestResource(exported = false)`.** `RestConfiguration.java:47` sets
   `RepositoryDetectionStrategies.ANNOTATED`, which selects *repositories*, not methods, and
   `StockunitRepository:26` is annotated — so query methods export **by default**. Confirmed empirically:
   `getAmountAvailable` has no opt-out and *is* live at `/v3/stockunit/search/getAmountAvailable`; six
   siblings opt out explicitly (`:53`, `:68`, `:94`, `:108`, `:166`, `:220`).
3. **Flat aggregate, no carrier recursion** — proven exactly equivalent across 2,682 SKUs (§1.2).
4. **`GROUP BY` returns no row for a SKU with no qualifying stock** — hence `getOrDefault(…, 0)`. A SKU
   with stock only in `Shipped` correctly yields `0` (AC7).
5. **No area join, no clearing-location parameter, no `SOURCE_AREA_NAMES`.** D1' removed all three. This
   **fully decouples the ticket from SBDEV-2952** — there is no duplicated area list to keep in step.
6. **Index support already exists:** `index_stockunit_itemdata_entitylock (itemdata_id, entity_lock)`.
7. **No client filter, deliberately, and this is NOT SBDEV-2777's bug.** `stockunit.client_id` differs from
   `itemdata.client_id` on **0 of 1,622,615** rows (122 distinct client ids present), so keying on
   `itemdata_id` alone cannot mis-aggregate across clients here. Stated because a reviewer who remembers
   SBDEV-2777 will otherwise flag it.

### Fix D — three UI surfaces: ADD a column, change nothing else

Per **D2'/D3'**: **no relabel.** The existing headers are accurate and stay.

1. **Add** a column `On hand` bound to `amountOnHand`, after the existing lane column, in all three of
   `processes/transferPicking/itemsTable.vue`, `processes/clubRuns/itemsTable.vue`,
   `outbound/transfer/transferDetailsTable.vue`.
2. **Change nothing else.** Existing headers, `showBadge`, `readyToMove`, `disableRun` and both `:disabled`
   bindings are untouched. **A diff that touches any of them is a failed implementation.**

Resulting columns — the two screens keep their existing wording, accepted under D3':
```
Transfer Picking / Outbound Transfer:  … | Required | Qty at Lane   | On hand | …
Club Run:                              … | Required | Total at Lane | On hand | …
```

---

## 4. Architecture Overview

```
GET /v3/transfers/skus?orderBatchId=      POST /v3/clubLine/skus
 TransfersController:332                  ClubLineController:255
 TransferOrderService                     CustomerorderBatchService
 .getSKUOverview:245  (un-annotated)      .getClubLineSKUOverview:1223  (un-annotated)
        │                                          │
        ├── amountRequired  ← position.getAmount()                       UNCHANGED
        ├── amountAvailable ← StockunitRepository.getAmountAvailable      UNCHANGED
        │                       (laneId, itemdataId)   [lane-scoped]      ⚠ GATES Run
        └── amountOnHand    ← OnHandQuantityService.onHandByItemdata      NEW
                                 (itemdataIds)          [ONE query]
                                      │   opens its OWN tenant tx -- the callers are un-annotated,
                                      │   so the request runs 1 + P transactions, not 1 (Critic Minor 3)
                        StockunitRepository.sumOnHandByItemdataIds
                          lo.name NOT IN ('Nirwana','Shipped')
                          → sinks out; transfer lane IN → On hand ⊇ Qty at Lane
                                      │
                            ClubLineSkuDto (+ amountOnHand, additive)
         ┌────────────────────────────┼────────────────────────────┐
 transferPicking/         clubRuns/                    outbound/transfer/
 itemsTable.vue           itemsTable.vue               transferDetailsTable.vue
 "Qty at Lane"            "Total at Lane"              "Qty at Lane"
 Run gate unchanged       Run gate unchanged           badge only, no Run
```

| File | Lines | Role |
|---|---|---|
| `service/TransferOrderService.java` | 245-290 | transfer SKU overview |
| `service/CustomerorderBatchService.java` | 1223-1276 | club SKU overview |
| `json/ClubLineSkuDto.java` | 43-51 | shared DTO |
| `repo/jpa/StockunitRepository.java` | 81-92 | lane query (untouched, HAL-exported) |
| `service/OnHandQuantityService.java` | NEW | the one shared on-hand method |
| `repo/projection/ItemdataOnHandView.java` | NEW | projection |

---

## 5. Implementation Steps

### 5.1 Prerequisites — MANDATORY

| Concern | Status |
|---|---|
| DB state | **None.** No migration, no Flyway version, no seed. Read-only addition. |
| Feature flags / sysprops | **None.** Additive display; no gate to roll out behind. |
| Config / env | **N/A** |
| Deploy order | **API first, UI second.** The column renders blank until the field exists — degraded, not broken. |
| Data migration | **N/A** |
| External systems | **None.** No OMS contract change; DTO is UI-facing only. |
| Access | `wms2-wineco-dev` MCP for the manual SQL rows — there is **no** integration lane (§8.3). |
| Monitoring | None added — §7 row 8. |

### 5.2 Phase 1 — API, branch `bugfix/SBDEV-2951-transfer-club-onhand-quantity`

1. ~~`WmsConstants` — add a `STORAGE_LOCATION_SHIPPED` constant~~ — **DELETED (Critic MJ1).** It already
   exists at `WmsConstants:775`. Adding it is a compile error. Reference both existing constants.
2. `repo/projection/ItemdataOnHandView.java` — `Long getItemdataId()`, `BigDecimal getAmount()`.
   ⚠ `StockunitLocationView` already declares `Long getItemdataId(); Object getAmount();` — the same shape.
   It is **not reused** because `Object.intValue()` does not compile; a `BigDecimal`-typed sibling is the
   point. Say so in the interface's javadoc so a reviewer does not "consolidate" them.
3. `repo/jpa/StockunitRepository.java` — `sumOnHandByItemdataIds` + `@RestResource(exported = false)`.
4. `service/OnHandQuantityService.java` — constructor injection, empty-set guard, parameterised debug log.
5. `json/ClubLineSkuDto.java` — additive `amountOnHand`.
6. `service/TransferOrderService.java` — constructor dep, one batch call, `setAmountOnHand` in the loop.
7. `service/CustomerorderBatchService.java` — same, **and** delete the dead `amount != 0` at `:1269`.
8. Unit tests per §8.1, including `OnHandExportUnitTest`. Add `@Mock` for the new dep in the two existing
   `…UnitTest` classes.

### 5.3 Phase 2 — Web UI, branch `bugfix/SBDEV-2951-transfer-club-onhand-column`

9. `processes/transferPicking/itemsTable.vue` — add the column. **Header and gates untouched.**
10. `processes/clubRuns/itemsTable.vue` — same.
11. `outbound/transfer/transferDetailsTable.vue` — same.
12. Jest tests per §8.2, including the four gate-integrity tests.

### 5.4 Implementation checklist

- [ ] `amountAvailable`'s value byte-identical at every call site
- [ ] existing headers `Qty at Lane` / `Total at Lane` **unchanged**
- [ ] `showBadge` / `readyToMove` / `disableRun` untouched in all three components
- [ ] exactly **one** on-hand query per overview call, any position count
- [ ] `UnitloadRepository` neither modified nor referenced
- [ ] `@RestResource(exported = false)` present
- [ ] constructor injection, not `@Autowired` fields; `@Mock` added to both existing unit tests
- [ ] club's dead `amount != 0` branch removed
- [ ] `archunit_store` reverted after any `mvn test`

---

## 6. Backward Compatibility

| Surface | Change | Breaking? |
|---|---|---|
| `ClubLineSkuDto` JSON | `+amountOnHand` | **No** — additive; four callers read named properties |
| `amountAvailable` | none | **No** — deliberately preserved; it is the Run gate |
| Existing column headers | none | **No** — D3' cancelled the relabel |
| `GET /v3/transfers/skus`, `POST /v3/clubLine/skus` | response widened | **No** |
| `getAmountAvailable` (HAL-exported) | none | **No** — untouched precisely because it is public |
| `UnitloadRepository` | none | **No** |
| HAL surface | new query **not** exported | **No** — design point 2 |
| `outboundBols.itemInfo` | wider DTO, zero consumers | **No** |
| Mobile transfer flow | untouched | **No** |

---

## 7. Horizontal Scalability Validation

| # | Concern | Verdict | Evidence |
|---|---|---|---|
| 1 | In-JVM state | **No** | Stateless service; `SINK_LOCATIONS` is an immutable constant |
| 2 | Connection pool math | **No** | One extra query per overview request. ⚠ **Corrected twice:** r1 said "inside the existing request's transaction" (there is none); r2 said "the request's only transaction" (also wrong — the per-position `getAmountAvailable` calls each open their own). Reality: the request runs **1 + P** short transactions and this adds one. Conclusion unchanged — no new pool, no `maxPoolSize` change |
| 3 | Scheduled jobs | **N/A** | none added |
| 4 | Long transactions | **No** | read-only, one aggregate, no external I/O in the boundary |
| 5 | Request affinity | **N/A** | stateless read |
| 6 | Retry / idempotency | **N/A** | read-only |
| 7 | Tenant context | **No** | request thread, `tenantTransactionManager`; no `@Async` |
| 8 | Distributed lock correctness | **No** | no locks acquired; `entity_lock` is *read* as a filter |
| 9 | Cache invalidation | **No** | nothing cached. ⚠ Do **not** add `@Cacheable` — stock changes continuously and a stale on-hand figure is the bug being fixed |
| 10 | External notifications | **N/A** | none |

## 7a. v2-only constraint checklist

| # | Constraint | Verdict | Where |
|---|---|---|---|
| 1 | OSIV disabled (`application.properties:55`) | **Yes** | `readOnly = true`; flat interface projection, no lazy graph crosses the boundary |
| 2 | Transaction manager | **Yes** | `value = "tenantTransactionManager"`; landlord is `@Primary` so a bare `@Transactional` hits the wrong datasource. Precedent: `WarehouseStockReportService.java:70` |
| 3 | `readOnly = true` | **Yes** | Fix C. Both callers are un-annotated (`TransferOrderService:245`, `CustomerorderBatchService:1223`), so **`REQUIRED` (default) is correct and `MANDATORY` would throw** |
| 4 | Caffeine cache invalidation | **N/A** | nothing cached — §7 row 9 |
| 5 | Jakarta namespace | **N/A** | ⚠ r1 claimed compliance vacuously — no proposed file imports `jakarta.*` (all annotations are Spring). Row kept honest rather than deleted |
| 6 | H2-compatible test SQL | ⚠ **No lane exists** | ⚠ **Correcting r1:** there is **no `@DataJpaTest` anywhere** in `src/test`, and `unit/repo/StockunitRepositoryTest.java:17` is `@Disabled("landlord datasource not configured")`. r1 called an H2 test "viable" then declined to write one. **The honest statement: no repository test lane exists.** §8.3 |
| 7 | `BaseControllerTest` | **N/A** | no controller change |
| 8 | Micrometer metrics | **No** | §7 row 8; a display figure on an operator-initiated read needs no counter |

---

## 8. Testing Strategy

### 8.1 Unit lane — Java

| Test class | Method | Criterion |
|---|---|---|
| `OnHandQuantityServiceUnitTest` | `onHandByItemdata_shouldReturnEmptyMap_whenItemdataIdsEmpty` | guards `IN ()` |
| | `onHandByItemdata_shouldMapViewsById` | AC1/AC2 mechanics |
| | `onHandByItemdata_shouldCoerceNullSumToZero` | defensive |
| | `onHandByItemdata_shouldPassBothSinkLocationNames` | **AC7** — pins the sink exclusion at the boundary |
| `OnHandExportUnitTest` | `sumOnHandByItemdataIds_isNotExported` **and** `getAmountAvailable_isStillExported` | **AC9** — reflection only, modelled on `AdviceRepositoryRestExportUnitTest`; pinning the complement stops a later sweep quietly unexporting more |
| `TransferOrderServiceUnitTest` | `getSKUOverview_shouldPopulateAmountOnHand_whenNoTransferLaneAssigned` | **AC1** |
| | `getSKUOverview_shouldLeaveAmountAvailableZero_whenNoTransferLaneAssigned` | **AC4** |
| | `getSKUOverview_shouldQueryOnHandExactlyOnce_regardlessOfPositionCount` | **AC8** |
| `CustomerorderBatchServiceUnitTest` | `getClubLineSKUOverview_shouldPopulateAmountOnHand_whenNoStagingLaneAssigned` | **AC2** |
| | `getClubLineSKUOverview_shouldLeaveAmountAvailableUnchanged` | **AC4** |

### 8.2 Unit lane — Jest

| Spec | Test | Criterion |
|---|---|---|
| `transferPicking/itemsTable.spec.js` | renders `On hand` bound to `amountOnHand` | AC1 |
| | header still reads `Qty at Lane` | **D3'** — pins the *absence* of a relabel |
| | **`readyToMove()` false when `amountAvailable < amountRequired` EVEN IF `amountOnHand >= amountRequired`** | **AC6** |
| | Run Transfer stays `disabled` in that state | **AC6** |
| `clubRuns/itemsTable.spec.js` | same three, header still `Total at Lane` | AC2, D3', **AC6** |
| `outbound/transfer/transferDetailsTable.spec.js` | column present; badge logic unchanged | D2' |

⚠ **AC6 must assert the computed/`disabled` outcome, not the props handed in.** An assertion echoing a prop
is the vacuous-test failure mode recorded from SBDEV-2643.

### 8.3 Integration lane — DOES NOT EXIST, and how the SQL is proven instead

**No repository test lane exists.** SBDEV-2217 blocks Testcontainers; there is no `@DataJpaTest` anywhere;
`StockunitRepositoryTest` is `@Disabled`. **The new native SQL has no automated coverage whatsoever** — the
single biggest gap in this plan, stated plainly rather than hedged. Compensation:

- manual SQL rows **M4–M6, M10** against `dev_wh01_om1`, comparing the query's output to an independently
  written aggregate;
- `mvn clean compile` (catches projection wiring, which incremental compile misses);
- the §9 verify script asserting the predicate's text, so a later edit dropping the sink exclusion is caught
  by grep even though nothing executes the SQL.

### 8.4 Manual test plan (MANDATORY)

| # | Scenario | Steps | Expected |
|---|---|---|---|
| **M1** | Laneless transfer shows real on-hand | open one of the **52** laneless transfer batches | `Qty at Lane 0`, `On hand > 0` for every SKU with stock |
| **M2** | Laneless club run | one of the **14** laneless club batches | same, `Total at Lane 0` |
| **M3** | ⚠ **Gate integrity** | on M1's order confirm **Run Transfer still disabled**; on M2 **Run Club Line still disabled** | disabled, subtitle still shown. **If either is enabled, STOP — that is the §2.1 regression** |
| **M4** | On-hand excludes `Shipped` | SKU with stock **only** in `Shipped` | screen `0`; SQL confirms 0 qualifying |
| **M5** | Reserved-adjusted | SKU with a fully-reserved stock unit | excluded; screen == `SUM(amount - reservedamount)` |
| **M6** | Delta to the tab is explainable | compare `On hand` to the tab's row sum for one SKU. ⚠ **Pick a SKU with NO stock in `Palletizing` / `Damaged` / `Gate_01` / a `users` location** — those are in D1''s scope and not the tab's, so they will not reconcile at all | differs by reserved/locked stock (22,082-class, §2.5) and the 35-row carrier edge (§1.2). Any other difference is a real finding |
| **M7** | Fully-staged regression | ⚠ **subjects are scarce** (Critic Minor 4): of 34 lane-assigned transfer positions only **4** have lane stock, and only **2** sit on an open (`state=0`) batch. Use one of those two, or construct: assign a lane, move stock onto it via the mobile/move-stock path, then reload | `Qty at Lane == Required`, badge green, Run **enabled** — AC5 |
| **M8** | Third surface | Outbound → Transfer → detail | `On hand` present, header and badge unchanged |
| **M9** | Four store callers | Transfer Picking, Club Run, Outbound Transfer, Outbound BOLs | no console error, no blank column |
| **M10** | ⚠ **H2 regression — the one r1 would have shipped** | stage stock onto `TransferLane01` for a transfer order, then read both columns | **`On hand >= Qty at Lane`**, and On hand does **not** decrease as stock is staged. **This is what r1 got wrong** |

### 8.5 Deliberately-skipped coverage

- No automated test of the native SQL — no lane exists (§8.3), compensated by M4–M6, M10.
- No e2e — no Cypress suite covers these screens.
- The tab's own raw-amount overstatement is **not** tested here — Q1, not this ticket's defect.

---

## 9. Acceptance criteria

Verify script: **`sbdocs/9-System/scripts/verify-SBDEV-2951-transfer-club-available-counts-lane-only.sh`**

| # | Criterion | Evidence |
|---|---|---|
| AC1 | Laneless transfer order shows non-zero `On hand` per SKU with stock; `0` only when genuinely none | M1 + `TransferOrderServiceUnitTest` |
| AC2 | Same for a club run with no staging lane | M2 + `CustomerorderBatchServiceUnitTest` |
| AC3 | *(reworded, D1')* `On hand` is **reserved-adjusted, lock-aware, over every location except the two terminal sinks**. Within that scope, reserved+locked stock is **22,082** units (431,597 raw → 409,515); the tab's narrower location set explains the rest. Differing from the tab **is correct** | M5, M6, `V-C1`…`V-C4` |
| AC4 | The lane figure reports exactly today's value, under its existing header | M1, M7 + the two `amountAvailable`-unchanged tests |
| AC5 | Fully-staged order still shows lane figure `== Required` | M7 |
| AC6 | ⚠ **Run Transfer / Run Club Line remain disabled while the lane figure < Required, even when `On hand >= Required`** | M3 + four Jest gate tests |
| AC7 | `On hand` excludes `Shipped` and `Nirwana` | M4 + `…shouldPassBothSinkLocationNames` |
| AC8 | No N+1 — query count independent of position count | `…QueryOnHandExactlyOnce…` |
| AC9 | New query **not** HAL-exported; `getAmountAvailable` still is | `OnHandExportUnitTest` (reflection, not grep) |
| AC10 | ⚠ **`On hand >= Qty at Lane` on a staged transfer order, and On hand does not decrease as stock is staged** | **M10** — pins H2 |
| AC11 | No column header changed; `UnitloadRepository` neither modified nor referenced | Jest header tests + `V-D3`…`V-D5`. ⚠ *(Critic Minor 5)* "not referenced" is **green-by-absence** — it passes on an empty diff. It is therefore paired with `V-C1`, a **positive** row requiring `sumOnHandByItemdataIds` to exist, so the pair cannot both pass on no work |

### 9.1 Verify-script rows — `verify-SBDEV-2951-transfer-club-available-counts-lane-only.sh`

⚠ **This table exists because r2 named the script four times as mitigation (R1, R2, R5, AC11) and specified
zero rows (Critic MJ2).** An unspecified script is this project's highest-frequency failure mode — the
recorded catalogue is fail-open perl helpers, vacuous negatives, unbounded lazy gaps losing containment, rows
naming undefined functions, rows going stale when code moves between files, and green-by-absence-of-work.

| id | Kind | Assertion | Guards |
|---|---|---|---|
| `V-C1` | positive | `sumOnHandByItemdataIds` declared in `StockunitRepository.java` | AC11's positive half |
| `V-C2` | positive | that method's `@Query` contains `NOT IN (:sinkLocationNames)` **(or the two-scalar `(:nirvana, :shipped)` form)** | **R2 — the 2.8M-unit trap** |
| `V-C3` | positive | that `@Query` contains all three `entity_lock = 0` clauses **and** `amount > su.reservedamount` | AC3, D1 |
| `V-C4` | positive | `@RestResource(exported = false)` **immediately precedes** `sumOnHandByItemdataIds` — not merely present in the file | **R4** |
| `V-A1` | positive | `setAmountOnHand(` appears in **both** `TransferOrderService.java` and `CustomerorderBatchService.java` | AC1, AC2 |
| `V-A2` | positive | `setAmountAvailable(0)` **still** present in both services | **R1** |
| `V-A3` | negative | neither service contains `setAmountAvailable(onHand` / `setAmountAvailable(amountOnHand` | **R1** |
| `V-A4` | positive | `onHandByItemdata(` appears **once** per service (batch, not per-position) | **R3 / AC8** |
| `V-D1` | positive | `amountOnHand` bound in all **three** components | AC1, AC2, D2' |
| `V-D2` | positive | `item.amountAvailable >= item.amountRequired` **still** present in all three | **R1 / AC6** |
| `V-D3` | positive | `text: 'Qty at Lane'` present in `transferPicking/itemsTable.vue` **and** `transferDetailsTable.vue` | **R6 / D3'** |
| `V-D4` | positive | `text: 'Total at Lane'` present in `clubRuns/itemsTable.vue` | **R6 / D3'** |
| `V-D5` | negative | `text: 'Staged'` absent from all three | **R6 / D3'** |
| `V-X1` | negative | no new `STORAGE_LOCATION_SHIPPED =` assignment added to `WmsConstants.java` (must remain exactly one) | **Critic MJ1** |
| `V-X2` | negative | `UnitloadRepository.java` contains no `sumOnHand`/`OnHand` reference | **R2b / D6'** |
| `V-T1` | test | `mvn_test_passes OnHandQuantityServiceUnitTest` | §8.1 |
| `V-T2` | test | `mvn_test_passes OnHandQueryContractUnitTest` | AC9, AC3, AC7, AC8 |
| `V-T3` | test | `mvn_test_passes ClubLineSkuDtoOnHandContractUnitTest` | AC1, AC2, AC4 |

⚠ **`V-T2` originally named `OnHandExportUnitTest`, and that row was PERMANENTLY RED — caught by the
Phase 3a conformance lane, not by me.** The TDD gate folded its two export assertions into
`OnHandQueryContractUnitTest` (which carries five more besides) and nobody reconciled the row. Because
`mvn_test_passes` runs with `-DfailIfNoTests=true`, the row failed identically whether the code was perfect
or absent — **it asserted nothing while looking like an honest failure**, the exact mode §12.1 was written
to prevent, reappearing one layer up. Repointed at the class that actually holds the assertions, and `V-T3`
added for the DTO contract. That **strengthens** the row set: 33 rows → 34, and the skip count goes to 0.

**Mandatory negative control, before any code is written:** run the script against unfixed `origin/develop`
and **record the FAIL count in §12.** A script reporting `0 fail` on the unfixed build asserts nothing.
Expected: every positive row FAILs, every negative row PASSes.

⚠ **Authoring constraints, from the recorded failure catalogue:** give every multi-line helper an
`[ -f "$2" ] || return 1` guard (the template's perl helpers exit 0 on a missing file — fail-open); use a
tempered-greedy gap, never `.*?`, for `V-C4`'s adjacency; and strip comments before matching on `V-A3` and
`V-D5` so a commented-out line cannot flip a negative.

---

## 10. Open Questions / Resolved Decisions

### 10.1 Resolved — do not re-open

| # | Decision | Rationale |
|---|---|---|
| **D1** | `On hand` is **reserved-adjusted + lock-aware** | User 2026-08-13. A figure counting unmovable stock is the defect class being fixed |
| **D1'** | **Basis = every location except `Nirvana` + `Shipped`** (409,515), **not** the tab's predicate (409,104) | User 2026-08-13 after **H2** (§2.4). Fixes the disjoint-column defect, closes Q2, drops the area join and the clearing parameter, and **fully decouples this ticket from SBDEV-2952**. Uses the existing idiom at `ViewWarehouseLocationReportRepository.java:33` |
| **D2'** | **All three** surfaces gain the column | User 2026-08-13 |
| **D3'** | ⚠ **NO relabel — existing headers stay** (`Qty at Lane` / `Total at Lane`) | User 2026-08-13 after **H1** (§1.4). r1's "Staged" was chosen on the false premise that the header read "Available"; `Qty at Lane` is *more* precise, since lane stock is not always staged for this order |
| **D4** | **Strictly additive** — new field, `amountAvailable` untouched | Forced by §2.1: repointing enables Run against an empty lane |
| **D5'** | New `OnHandQuantityService`, not a method on `WarehouseStockReportService` | Its `stock_view.total_stock` basis is **incompatible** (431,597; no location join, no reserved subtraction). Two contradictory "stock" numbers behind one bean is worse than a new bean |
| **D6'** | ⚠ **No coupling to SBDEV-2952 at all** | D1' removed the area list. r1's `SOURCE_AREA_NAMES` seam no longer exists and is not needed |

**Alternatives considered and rejected** (recorded because these are the first objections any reviewer raises):

| Alternative | Why rejected |
|---|---|
| **UI-only: fix the tab-split affordance, no API change** | Cheapest by far, one repo, and **immune to H2**. Rejected on two grounds that survive measurement: it requires a **click per SKU** with no per-line comparison against Required, and it points operators at the tab's **raw, overstating basis** (Q1, 22,082 units of reserved/locked stock). ⚠ **The "scan across 54 lines" argument r2 used is WITHDRAWN (Critic MJ4)** — 54 was the tenant-wide total across 53 batches. Per screen: `TRANSFER_OFFSITE` averages **1.02** lines (max 2; **51 of 52** show a single line), so on transfers there is almost nothing to scan and this alternative is stronger than r2 admitted. It holds up better for **club** (avg 4.19, max 27). This is the strongest surviving objection to the whole plan and is beaten on the click-per-SKU and wrong-basis grounds alone |
| **Own-lane-only basis** — `AND (NOT (lo.staginglane OR lo.transferlane) OR lo.id = :ownLaneId)`, i.e. exclude other orders' lanes but keep this order's | **Not adopted, and the omission was a real gap in r2 (Critic MJ3).** It is the coherent midpoint between r1 (exclude all lanes → H2) and D1' (exclude nothing but sinks), it satisfies §2.5's principle exactly, it preserves `On hand >= Qty at Lane` by construction, and both callers already hold the id — one extra parameter. Rejected only because it makes the figure **order-relative**: the same SKU would show different On-hand values on two orders open side by side, which is harder to explain than a 7% over-report on a column that gates nothing. ⚠ **Revisit this first** if operators report the number reads high |
| **Reshape / parameterise `getAmountAvailable`** | It is **HAL-exported** (`:81`, no opt-out, live at `/v3/stockunit/search/getAmountAvailable`); changing its signature is a public-contract break no service-layer guard can contain |
| **JPQL / Criteria instead of native SQL** | **Impossible.** `Stockunit`/`Unitload`/`Location` carry zero JPA associations by project rule (§2.3) |
| **Compute on-hand client-side from the tab's data** | Forces the item list to eagerly fire the per-SKU carrier-traversal `unitLoads` call — the exact N+1 two archived performance plans removed — and yields the **raw** basis, contradicting D1 |
| **Reuse `stock_view` / `WarehouseStockReportService`** | Basis 431,597, no location join, no reserved subtraction — see D5' |

### 10.2 Open

| # | Question | Blocking? | Next action |
|---|---|---|---|
| **Q1** | The Available Inventory tab sums **raw** amount (`calcOptimized:439`), so it overstates by counting fully reserved stock — the unfixed remainder of archived Fix 5 | **No** — AC3 accommodates it | **File a follow-up.** Out of scope: it changes a display operators rely on. **Do not "align" the tab to make AC3 tie out** |
| ~~**Q2**~~ | ~~Should the 2,143 units in `Damaged`, `Palletizing`, `Packaging`, `FinishedPicking`, `Gate_01`, `TransferLane01/02` count?~~ | — | ✅ **CLOSED by D1' — YES, they now count.** Reserved-adjusted, the delta over r1's basis is only **411** units. It is now a decision, not a side effect |

---

## 11. Risks & Mitigations

| # | Risk | Impact | Mitigation |
|---|---|---|---|
| **R1** | Implementer repoints `amountAvailable` instead of adding a field | **Critical** — Run enabled against an empty lane | §2.1 in bold; **AC6**; M3 as a STOP row; four Jest gate tests; verify-script negative on the gate expressions |
| **R2** | On-hand query written without the sink exclusion → counts `Shipped` | **Critical** — inflated by 2,856,635 units, and it looks plausible | Design point 1; **AC7**; M4; `…shouldPassBothSinkLocationNames`; verify script asserts the predicate text |
| **R2b** | ⚠ **A "helpful" reviewer re-mirrors the tab's predicate for AC3 tidiness** | **High** — reintroduces **H2** exactly | §2.4 documents the failure with measurements; **AC10 + M10**; D1'/D6' say the coupling is gone on purpose |
| **R3** | Per-SKU query in the loop → N+1, undoing two archived performance plans | High on large club batches | **AC8**; batch shape is the design; invocation-count test |
| **R4** | New query auto-exported as HAL | Medium | `@RestResource(exported = false)`; **AC9** as a reflection test that also pins the complement |
| **R5** | **No test lane at all for the native SQL** | Medium — a SQL error reaches dev | M4–M6, M10 manual SQL; `mvn clean compile`; verify script pins predicate text. Stated as a real gap, not hedged |
| **R6** | Implementer "helpfully" relabels the headers anyway | Low — undoes D3' | Jest tests assert the headers are **unchanged**; §5.4 checklist |
| **R7** | New constructor param + existing `@InjectMocks` tests → silent `null` injection | Medium — confusing NPEs | Fix A note; §5.2 step 8 |
| **R8** | Reviewer reads the 22,082-unit delta to the tab as a bug | Low — churn | §2.5 measures and decomposes it; AC3 states it is expected |
| **R9** | ⚠ **The sink filter is name-based with no runtime guard.** On a tenant whose sink is not named exactly `Shipped` / `Nirwana`, R2's 2.8M-unit inflation fires **silently** and every grep row still passes | **High on an unseen tenant** | **M4 is the only detector** — run it per tenant, not just on wineco-dev. Design point 1. Consider a startup assertion via `LocationService.getShipped()` if this recurs |
| **R10** | The "cleanup" of the club's dead branch drops the `else` arm → `amountAvailable` null → `null < required` is false in JS → **Run enabled on an empty lane** | **Critical** — R1 by a side door | Fix A spells the replacement out verbatim; `V-A2`; AC6's Jest tests |

---

## 12. Implementation Status

**MERGED to `develop` 2026-08-15 — API first, then UI. ClickUp moved to `on dev`.**
Both merge commits confirmed as ancestors of `origin/develop` via `git merge-base --is-ancestor`.

| Repo | PR | Head | Merge commit | Branch | Diff |
|---|---|---|---|---|---|
| `v2/wms2-api` | [#157](https://github.com/SiteBossInc/wms2-api/pull/157) | `0a063fa` | **`945e8e8`** | `bugfix/SBDEV-2951-transfer-club-onhand-quantity` | 11 files, +851/−7 |
| `v2/wms2-web-ui` | [#60](https://github.com/SiteBossInc/wms2-web-ui/pull/60) | `e1f54ea` | **`f5596fa`** | `bugfix/SBDEV-2951-transfer-club-onhand-column` | 6 files, +352 |

> [!note] The UI head SHA recorded at implementation time was `d737431`; the branch advanced to `e1f54ea` before merge. Branches were not deleted, matching both repos' convention.

### Results

| Gate | Result |
|---|---|
| `mvn clean compile` | clean |
| API full unit suite | **5046 run, 2 failures** — identical to the `develop` baseline (`OptionalSafetyArchTest` drift, `MobilePalletizingServiceTest`); all 6 ArchUnit violations in pre-existing files (`MobileReplenishService:1024`, `PickLineRealignmentService:80,81`, `ReplenishGeneratorService:210`, `UnitloadBusinessService:751,755`) |
| Jest | **17/17** on the 3 new specs; **355 passed** overall |
| Verify script | **`Result: 35 pass, 0 fail, 0 skip`** (shadow root, `VERIFY_RUN_TESTS=1`) — up from the 16/15/2 negative control in §12.1 |
| Conformance (3a) | **11/11 ACs VERIFIED**, every §0 in-scope row |
| Code review (3b) | 0 High, **2 Medium fixed**, 7 Low deferred |
| Security review | **LOW** risk, 0 Critical/High/Medium |

### Tests added

`OnHandQueryContractUnitTest` (7) · `OnHandQuantityServiceUnitTest` (9) · `ClubLineSkuDtoOnHandContractUnitTest` (2) ·
`TransferOrderServiceUnitTest$GetSKUOverview` 4→7 · `CustomerorderBatchServiceUnitTest$GetClubLineSKUOverview` 4→7 ·
3 Jest specs (17).

### Live proof the plan said this change could never have (§8.3)

| Check | Result |
|---|---|
| The query executed against `dev_wh01_om1` | returns 16,013 + 890 + 86 = **16,989** for the laneless positions' SKUs; only 3 of 4 SKUs return, exercising the absent-SKU→0 path |
| **AC10** — positions where `On hand < Qty at Lane` | **0**, across **9,132 (lane, SKU) pairs** (46 carrying real lane stock) |
| Worst live case — 55-SKU club batch | `EXPLAIN ANALYZE` **4.6 ms**, index scan on the existing `(itemdata_id, entity_lock)`; no new index |
| §2.5's delta, decomposed | **22,082 = 1,802 locked + 20,280 reserved** — exact |
| Cross-client | `0 / 1,622,615` rows with `stockunit.client_id <> itemdata.client_id` |

### ⚠ Three defects the review lanes caught that would otherwise have shipped

| Lane | Finding |
|---|---|
| **Conformance** | Verify row `V-T2` named `OnHandExportUnitTest`, a class the TDD gate folded into `OnHandQueryContractUnitTest` and never reconciled. With `-DfailIfNoTests=true` the row failed **identically whether the code was perfect or absent** — it asserted nothing while looking like an honest failure. Repointed; `V-T3` added |
| **Code review (Medium)** | Row `V-D2b` was `has 'amountAvailable' "$V_UI_CLUB"`. That string occurs **four** times in `clubRuns/itemsTable.vue` and only one is the gate — the others include the header binding and **the explanatory comment this ticket added**. Repointing *both* club gates at `amountOnHand` would have left it green, and it is the club half of R1's (Critical) mitigation. Now pins `disableRun`'s `<` and `showBadge`'s `>=` separately (`V-D2b`, `V-D2d`) |
| **Code review (Medium)** | AC8 had no behavioural guard on the **club** side — `count_is … 1` counts textual occurrences, so a call moved *inside* the loop still counts 1. Club is the worse case: a live batch carries **55 SKUs** vs transfers' 1.02 average. Added `getClubLineSKUOverview_shouldQueryOnHandExactlyOnce_regardlessOfPositionCount` |

### ⚠ A measurement in this plan was wrong, and is corrected

R2/R9 framed `lo.name NOT IN (:sinkLocationNames)` as *the* trap, and an executor measurement claimed the guard "excludes 26,872 units so On hand reports 39". **That measurement omitted the `entity_lock` filters.** Measured properly: of **1,602,838** stock rows in `Shipped`+`Nirwana`, **zero** survive the three `entity_lock = 0` filters — every `Shipped` row carries `entity_lock = 405`, every `Nirwana` row `= 2` — and the basis is **identical at 409,515 with and without the name predicate**.

So the **lock filters are the primary sink exclusion** and the name predicate is defence-in-depth (it catches a sink row that somehow carries `entity_lock = 0`, and documents intent). **Keep both.** Consequence: **R9 was overstated** — a tenant whose sink is named differently would still be excluded by the locks, provided it locks its sink rows as this tenant does. `StockunitRepository`'s javadoc now says this.

### Landmines recorded in the architecture docs (Phase 4)

The endpoint tables never enumerated payload fields, so nothing documented was invalidated — but §2.1's finding is durable and is now item **12** of `wms2-transfer-order-workflow.md` §10 and item **11** of `wms2-club-run-workflow.md` §9, cross-linked: `amountAvailable` gates the Run buttons; the club `else` arm is load-bearing because `null < required` is false in JavaScript; and any warehouse-wide sum must exclude the sinks.

### Done 2026-08-15

- **Merged**, API (`945e8e8`) before UI (`f5596fa`), both verified on `origin/develop`.
- **ClickUp** moved `pr submitted` → **`on dev`**, with a comment carrying the merge SHAs and the M3/M4 QA asks.

### NOT done — by design

- **Archiving** — run `archive-plan` **only after manual QA passes**. ⚠ This plan is **archive-gated on M1–M10**: there is no telemetry surface for the display change, so a green automated lane is not evidence the column renders. Archiving also removes the worktrees.
- **The 10 manual rows M1–M10.** AC5 and AC10 have **no** automated evidence (AC10 is proven algebraically and by the 9,132-pair query, but not through the UI); AC1/AC2/AC3/AC7 each have an unverified manual half. **M3 is the STOP row** — if either Run button is enabled on a laneless order, the R1 regression shipped.
- **Deferred findings**: 7 code-review Lows, plus **2 pre-existing security Lows worth their own hygiene ticket** — `StockunitRepository` has four query methods exported to HAL by default, two taking `FOR UPDATE`/`PESSIMISTIC_WRITE` locks, and `getListByStorageLocationId` is exported with **zero callers anywhere**, returning per-location stock with no lock filter.
- **Mobile is untouched** — `MobileTransferOrderService.calculateStockOnStagingLane` correctly stays lane-scoped (move arithmetic, not a DTO), so handheld users do not get this. Confirm with Brent.
- **No deploy prerequisite**: no migration, no Flyway version, no sysprop, no seed.

### Worktrees (kept for review feedback)

`.claude/worktrees/wms2-api/SBDEV-2951` · `.claude/worktrees/wms2-web-ui/SBDEV-2951`
Remove sooner if wanted: `git -C <repo> worktree remove <path>` then `git -C <repo> worktree prune`. `archive-plan` step 5f owns this normally.

### 12.1 Verify-script negative-control baseline — **CAPTURED 2026-08-13, before any code**

```
Result: 16 pass, 15 fail, 2 skip
```

Run against unfixed `develop` via `bash sbdocs/9-System/scripts/verify-SBDEV-2951-transfer-club-available-counts-lane-only.sh`.
**This is the shape a correct baseline must have:** all **15** positive rows (V-C1…C7, V-A1a/b, V-A4a/b,
V-B1, V-D1a/b/c) FAIL because the code does not exist yet, and all **16** preservation rows (V-A2a/b,
V-A3a/b, V-B2, V-D2a/b/c, V-D3a/b, V-D4, V-D5a/b/c, V-X1, V-X2) PASS because nothing is broken yet.
**Final acceptance is `Result: 31 pass, 0 fail` with `VERIFY_RUN_TESTS=1` making it 33.**

⚠ **Two rows were caught permanently red and repaired before this baseline was trusted** — a row no correct
implementation can turn green is indistinguishable from unfinished work:

| Row | Defect | Cause |
|---|---|---|
| `V-C2` | first draft was an **alternation** (`'sumOnHand…\|NOT IN …'`), so it would have gone green on the method **name** alone — never asserting the sink exclusion, i.e. green while R2's 2.86M-unit inflation shipped | vacuous-row failure mode |
| `V-C2`, `V-C4` | **permanently red** — `perl -0777` interpolates `@Query` / `@RestResource` inside the regex as **Perl arrays**, so `(?!\@Query)` became `(?!)`, a lookahead that can never match | ⚠ **NEW failure mode for this vault:** any Java annotation used inside a `has_ml` tempered gap must be written `\@` |
| `V-C4` | tempered on `List<`, but the target method's **own** return type is `List<ItemdataOnHandView>`, so the gap could never reach the method name | tempered on the wrong token; now tempers on `;` |

All three were proven in **both** directions against a synthetic correct implementation and against three
mutilated variants (sink clause removed; `exported = false` removed; annotation moved to a sibling). The
`lacks_code` helper strips comments, and every helper guards `[ -f "$2" ]` first — the template's
`file_not_contains` is `! grep -qE`, which returns **true** on a missing file and has produced false greens
here before.

⚠ **Reach limitation, worth stating before build (Critic):** this fix is **web-UI only.** The mobile
transfer flow is untouched, and `MobileTransferOrderService.calculateStockOnStagingLane` (`:413-416`) stays
lane-scoped — correctly, since `:181`, `:221` and `:375` all feed `amountNeeded <= amountOnTransferLane`
move decisions and never a DTO. **If the operator who raised this works on a handheld, the fix does not
reach them.** Confirm with Brent before Phase 2; a mobile equivalent would be a separate ticket.

### Review history

### 12.3 TDD gate baseline — **RUN AND APPROVED 2026-08-13**

**Worktrees — the executor MUST reuse these; the gate tests live here and nowhere else:**

| Repo | Branch | Worktree |
|---|---|---|
| `v2/wms2-api` | `bugfix/SBDEV-2951-transfer-club-onhand-quantity` | `.claude/worktrees/wms2-api/SBDEV-2951` |
| `v2/wms2-web-ui` | `bugfix/SBDEV-2951-transfer-club-onhand-column` | `.claude/worktrees/wms2-web-ui/SBDEV-2951` |

Both created clean off freshly-fetched `origin/develop`. ⚠ **`develop` moved after this plan's
measurements** (wms2-api `02dc7ca1` / wms2-web-ui `39eedd4`, PRs #155 and #58); every line the plan cites
was re-verified on the new base and all hold — only `WmsConstants` shifted by one line
(`STORAGE_LOCATION_NIRVANA` 766, `STORAGE_LOCATION_SHIPPED` 776).

| Class / spec | Tests | Criteria |
|---|---|---|
| `unit/repo/OnHandQueryContractUnitTest` | 7 | AC3, AC7, AC8, AC9 |
| `unit/json/ClubLineSkuDtoOnHandContractUnitTest` | 2 | AC1, AC2, AC4 |
| `test/components/processes/transferPicking/itemsTableOnHand.spec.js` | 8 | AC1, AC6, AC11 |
| `test/components/processes/clubRuns/itemsTableOnHand.spec.js` | 6 | AC2, AC6, AC11 |
| `test/components/outbound/transfer/transferDetailsTableOnHand.spec.js` | 3 | AC11, D2′ |

```
API:  9 run — 6 fail (gate), 3 pass (pins)
UI:  17 run — 4 fail (gate), 13 pass (pins)
Verify script unchanged at 16 pass / 15 fail / 2 skip (no production code touched)
```

⚠ **16 of the 26 tests PASS on the unfixed build, and that is by design — they are regression pins, not
weak gates.** Plan §2.1: `amountAvailable` gates Run Transfer / Run Club Line, so a test pinning that
behaviour must pass today. **Each is paired with a positive control** so it cannot pass by the gate being
permanently closed (`disableRun stays true` sits beside `disableRun DOES clear once the lane is stocked`).
**The executor may not "fix" a passing pin.**

⚠ **The API tests are reflection-based, and that bought real coverage rather than costing it.**
`OnHandQuantityService`, `ItemdataOnHandView` and `amountOnHand` do not exist yet, so naming those types
would fail at **compile** — which is broken scaffolding, not a failing test. Reflection also reads the
`@Query` **text**, so the new native SQL now has automated coverage of its sink exclusion, its three
`entity_lock` filters, its reserved adjustment and its `IN`/`GROUP BY` set shape — closing most of the gap
§8.3 declared, since no repository test lane exists.

**Deferred to the executor, with cause:** §8.1's `OnHandQuantityServiceUnitTest` and the new methods on
`TransferOrderServiceUnitTest` / `CustomerorderBatchServiceUnitTest` (including AC8's invocation count)
cannot be written before the types exist — they would need to `@Mock` `OnHandQuantityService` and call
`getAmountOnHand()`. Write them as the types appear; `V-A4a/b` hold AC8 meanwhile. ⚠ Both existing classes
use `@InjectMocks` + per-type `@Mock`, so the new constructor dependency **needs a matching `@Mock` or
Mockito injects `null` silently**. `TransferOrderServiceUnitTest` is `@Nested`, so target the **class** —
`-Dtest='Outer#method'` silently runs zero tests and reports success.

**Two gate defects found and fixed while writing the tests:**

| Defect | Fix |
|---|---|
| I wrote `expect(runButton.length >= 0).toBe(true)` — **always true**, the vacuous-assertion mode recorded from SBDEV-2643 | `v-btn` stub now renders a real `<button>`, so the test reads the rendered `disabled` attribute, with a positive control proving it tracks the lane figure |
| The club spec failed **wholesale on setup**: `clubRuns/itemsTable` reads `clubRunDetails.status` in `isClubRun()` (`:143`) but `.state` in `closedClub()` (`:206`) — two names for one concept, both through `getStateCode()`, which does `code[0].code` and **throws** on an unknown name | both set to `'Lane Assigned'` (a real `stateList` entry), with a comment. ⚠ Worth knowing generally: the symptom is *every test in the file failing*, not a useful message |

**AC5 and AC10 remain manual-only** (M7, M10). AC10 was proven **algebraically** by the Critic —
`getAmountAvailable` already filters the identical three `entity_lock` columns plus
`amount > reservedamount`, so the new query's row set is a strict superset for any non-sink location — so
M10 is confirmation, not discovery.

### 12.2 Review history

| Pass | Verdict | Outcome |
|---|---|---|
| Planner r1 | — | draft |
| **Architect r1** | **blocking** | **H1** (label does not exist) and **H2** (transfer lane excluded) both confirmed by independent measurement → D1', D3', new AC10/AC11, Q2 closed, SBDEV-2952 decoupled. M1 moot (no `getClearing()`), M2 (projection name + getter type), M3 (no repo test lane), L1 (§7 row 2), L2 (reflection test), L3+L4 moot. Added §2.3 (native SQL is forced) and the rejected-alternatives table. Confirmed §2.1, §1.2 (exactly, across 2,682 SKUs), sink exclusion, HAL export, `itemdataIds` reuse, propagation, DTO safety |
| **Critic r2** | **ITERATE** — 5 Major | **MJ1** `WmsConstants.STORAGE_LOCATION_SHIPPED` already exists at `:775` with 13 call sites → §5.2 step 1 was a **compile error**; deleted. **MJ2** the verify script was named as mitigation for R1/R2 (both Critical), R5 and AC11 but had **zero specified rows** → §9.1 added, 17 rows + a mandatory pre-implementation negative control. **MJ3** §2.5's "unmovable" principle contradicted D1''s scope by **30,914** units (28,367 on other orders' lanes + 2,547 in `users`) → principle narrowed to "reserved or locked", buckets tabulated, and the missing **own-lane-only** alternative added to §10.1. **MJ4** the "54 lines" argument against the UI-only option was tenant-wide across 53 batches; per screen a transfer shows **1.02** lines (51 of 52 single-line) → claim withdrawn, rejection restated on click-per-SKU + wrong-basis. **MJ5** AC3's 19,939 subtracted across two location scopes → corrected to **22,082** within the D1' scope. Minors applied: the 171,004 figure **withdrawn** (did not reproduce; correct is 4 SKUs / 16,989), §4+§7 row 2 transaction count corrected to **1+P**, AC11 paired with a positive row, M6/M7 given real subject guidance, projection-reuse rationale stated, R9 (name-based sink filter, silent on an unseen tenant) and **R10** (dead-branch cleanup → null → Run enabled, R1 by a side door) added. **Confirmed by independent re-measurement:** 6 of 8 headline figures exact, all four §1.2 carrier figures exact, zero JPA associations, no `@DataJpaTest` anywhere, the projection/alias/collection-binding mechanics all have live precedent — and **AC10 survived a directed attack**: `getAmountAvailable` already filters the identical three `entity_lock = 0` clauses plus `amount > reservedamount`, so `On hand >= Qty at Lane` is algebraic, not empirical |
| Critic r3 | pending | re-run after §9.1's negative control is recorded |
