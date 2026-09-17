# SBDEV-3320 — architect consult: minting a Cart unit load at tote scan

**Scope:** read-only architecture consult. Five questions + a reader sweep. No plan, no work breakdown.
**Baseline:** `origin/develop` @ `6dc054e1` (`wms2-api`), `origin/develop` (`wms2-mobile-ui`). The local
`wms2-api` checkout was at `34b897c8`, 3 commits behind; every code citation below is from
`git show origin/develop:<path>`.
**Live data:** Hydra PRD (`wms2-hydra`) and WineCo UAT (`wsl-wineco-uat`), queried 2026-09-11.
**Citation form:** file + a quoted distinctive snippet. Line numbers are given only as a navigation
hint and will drift.

---

## Executive summary

Five things dominate everything else in this consult:

1. **Site 1 (`processPick`) is the cart flow; site 2 (`rapidPickingConnectPackageAndType`) is not.**
   The discriminator already exists and is already load-bearing in four places:
   `section.sectionpickingtype ∈ {TOTES_ON_CART, RAPID_PICKING}`. Site 2 is the `RAPID_PICKING`
   entry point. Mint at site 1 only. (Q1)

2. **`transferUnitLoadToLocation` clears `carrierunitload_id`, and that cuts both ways.** Site 1 calls
   it on the tote immediately after `pickingorderUnitloadService.create(...)`, so **any Cart attach
   placed before that call is silently undone**. The same clear is what releases totes from the Cart
   at packaging — traced statement-by-statement and **verified to fire** (`ignoreLock=true` skips only
   the lock re-fetch, not the clear), so the feared "totes strand on the Cart" outcome does *not*
   happen on that path. It would happen on any caller passing a **stale** `Unitload`, because unlike
   its sibling `transferUnitLoadToCarrier` this method never re-reads the row — a one-line hardening
   worth proposing. (Q3)

3. **`relocateEmptiedContainer` already contains a Cart branch that will throw the first time a Cart
   exists.** It routes `UNIT_LOAD_TYPE_CART → EmptyPallets`; `EmptyPallets` is location type
   `overstock pallet`, whose `location_constraint` rows permit `Case,Pallet` (Hydra PRD) /
   `Pallet` (WineCo UAT) — **not Cart**. This defect is in already-shipped code, not in anything
   SBDEV-3320 would add, and it is currently unreachable only because zero Cart rows exist. It is the
   sharpest runtime risk on the ticket. (Q3)

4. **The mobile UI has no cart scan step** — the entire "cart" surface on `origin/develop` is a static
   subtitle, a menu icon, and a `TOTES_ON_CART → 'Tote'` string mapping. But **mint-per-order is the
   wrong model** and I withdraw it: 26 of 27 WineCo UAT sections are `TOTES_ON_CART`, so a cart would
   be minted on essentially every pick. The Tote — the asset a Cart most resembles, handled in this
   very method — is already modeled as a **durable, reused record with a stable scanned label**
   (`T-0004`, `T-0117`), ~242 live rows serving 481,157 orders. Reuse is correct; the cheapest correct
   reuse is single-repo, but the *faithful* one is multi-repo. (Q4, revised)

5. **The reader sweep found two real behaviour changes and one silent design gap.** A tote with a
   non-null `carrierunitload_id` newly breaks "set stock on hold", newly re-roots the transfer-order
   source picker onto the Cart, and **nothing in `src/main` ever retires a Cart**. (Sweep)

---

## Q1 — Which of the two `pickingorderUnitloadService.create` sites should mint/attach the Cart?

**Answer: site 1 only — `MobilePickingService.processPick`. Not site 2.**

The two sites are not two variants of one flow; they are the two arms of an existing, explicit mode
switch on `section.sectionpickingtype`.

### The discriminator already exists

`model/Section.java` declares `private String sectionpickingtype;`, and
`controller/SectionController.java` publishes exactly two values:

```
types.add(WmsConstants.SectionPickingType.TOTES_ON_CART);
types.add(WmsConstants.SectionPickingType.RAPID_PICKING);
```

Four existing consumers branch on it, and in every one the two arms behave *differently*:

| Consumer | `TOTES_ON_CART` | `RAPID_PICKING` |
|---|---|---|
| `service/SectionService.java` `create(...)` | `// do nothing` | creates a `NoRestriction` location named after the section, in the `Outbound` area |
| `service/CustomerorderService.java` (packaging) | `transferUnitLoadToLocation(pickingTote, emptyTotesLocation, true, …CODE_FINISHED_PACKAGING_MOVE_TOTE…)` — tote returns to the empty pool | `sendToNirvana(pickingTote, …)` — tote is retired |
| `schedulejob/ReplenishOrderJob.java` `mergePickingOrders()` | `sectionRepository.findBySectionpickingtype(WmsConstants.SectionPickingType.TOTES_ON_CART)` — **merging happens only here** | not merged |
| `schedulejob/ReleaseExpiredPickingOrdersFromUserJob.java` | not handled | `getPickingOrdersToReleaseExpiredPickingOrders(…State.PICKED, WmsConstants.SectionPickingType.RAPID_PICKING, date)` |

### Site 2 is the RAPID_PICKING arm

`rapidPickingConnectPackageAndType` is named for it, it is reached only from the rapid screens, and
the mobile UI routes to it by that value — `wms2-mobile-ui/store/picking.js`:

```js
if (result.sectionpickingtype === 'RAPID_PICKING') {
  return 'Rapid'
} else if (result.sectionpickingtype === 'TOTES_ON_CART') {
  return 'Tote'
}
```

Its order selection is `getPickingOrders(boxTypeOpt.get().getId(), section.getId(), 1)` — **amount
1**, one order at a time, keyed on box type. There is no cart in that model; the LPN *is* the parcel.
Minting a Cart there would create a one-child cart per order forever, with no releasing event.

### Site 1 is the TOTES_ON_CART arm, and it is live in production

`processPick` is the regular picking tote scan. Measured on the live databases:

| | Hydra PRD (`wh01_hydra_v2`) | WineCo UAT (`wsl`) |
|---|---|---|
| `MERGE_PICKING_ORDERS` | `true` | `true` (per brief) |
| `PICKING_BOX_PER_CART` | `6` | `6` (per brief) |
| sections | `Main` = TOTES_ON_CART, `Test` = TOTES_ON_CART | 26 × TOTES_ON_CART, 1 × RAPID_PICKING (`test_section`) |

**Hydra PRD has no RAPID_PICKING section at all.** Every production pick on Hydra goes through site 1.
This is a live path, and the mobile UI already labels it as such — `components/picking/selectOrder.vue`
carries `<v-card-subtitle class="pa-0 pt-2">Cart Picking</v-card-subtitle>`.

### One caveat worth recording, not acting on

Site 2 contains two pre-existing id-domain confusions that are unrelated to this ticket but sit in the
same method and will show up in any test you write around it:

```java
CustomerorderPosition coPosition = customerorderPositionRepository.findById(poPositions.get(0).getId())
```

— a `PickingorderPosition` id used as a `CustomerorderPosition` id; and later

```java
for (PickingorderPosition pickPos : pickingorderPositionRepository.findByPickingorderId(orderPosition.getId()))
```

— a `CustomerorderPosition` id used as a `Pickingorder` id. Both are independent of SBDEV-3320.
(Consistent with the standing "fix RAPID_PICKING" item in the RTS roadmap decisions.)

---

## Q2 — How does the code detect "this picking order is a cart order" at scan time?

### What is actually on the model

`model/Pickingorder.java` has **no** cart field, no merged flag and no tote-count. Its complete field
set is: `additionalcontent`, `entityLock`, `customerordernumber`, `manualcreation`, `number`, `prio`,
`state`, `clientId`, `destinationId`, `operatorId`, `sectionId`, `lockedtooperator`,
`pickinginprogress`.

`model/PickingorderUnitload.java` has `positionindex`, but it is dead — `PickingorderUnitloadService.create`
hardcodes `pickingUnitLoad.setPositionindex(-1);` and nothing in `src/main` reads it (confirmed in the
brief: 272,058 UAT rows, one distinct value, 2019→2026).

So every candidate signal is derived, not stored.

### Candidate signals, graded

**A. `pickingOrder.getSectionId()` → `Section.getSectionpickingtype()` — SOUND. Recommended.**

This is the canonical discriminator (see Q1). It is cheap (one `findById`), it is what every other
consumer uses, and the data supports it. Measured on WineCo UAT:

| `pickingorder.state` | `section_id` set | `section_id` NULL |
|---|---|---|
| 600 | 3 | 0 |
| 700 (FINISHED) | 66,113 | 0 |
| 800 (CANCELED) | 21 | 207,629 |

**Zero of 66,137 non-CANCELED rows have a null `section_id`.** The 207,629 nulls are all CANCELED, and
they are written deliberately by `PickingOrderMergeService.mergePickingOrders`, which does
`pickingOrder.setSectionId(null);` on the leftovers it cancels and `pickingOrder.setSectionId(section.getId());`
on the survivor it re-uses. A live order always has a section.

*Blind spots:*
- `sectionpickingtype` is a plain `String` column, not an enum — a tenant with a third value or a typo
  falls through. The existing switches at least fail loudly (`SectionService`: `throw new BusinessException("Type " + sectionPickingType + " not handled…")`;
  `CustomerorderService`: `LOG.error("unknown picking type={}", pickingType); throw …`). A new call site
  should match that, not silently skip the mint.
- `section_id` is a nullable column with no NOT NULL, so the lookup must be null-guarded even though
  the live data has no nulls on live rows. `Section.getSectionpickingtype()` is also nullable —
  `CustomerorderPositionService` already calls `.getSectionpickingtype().equals(...)` unguarded, which
  is a latent NPE; do not copy that shape.
- **It answers "this section does cart picking", not "this order was merged."** Every order in a
  TOTES_ON_CART section gets a Cart under this signal, merged or not. That is defensible (a cart of one
  is still a cart) but it is a different claim from the ticket's wording and should be stated as the
  intended semantics rather than assumed equivalent.

**B. Count of `pickingorder_unitload` rows for the order — NOT SOUND as a detector; useful as a lookup.**

At the *first* tote scan the count is 0 for a merged and an unmerged order alike, so it cannot detect
cart-ness at the moment you need to decide. It also over-counts: rows are never deleted —
`CustomerorderService` does `pickingUnitLoad.setUnitloadId(null); pickingUnitLoad.setState(WmsConstants.State.FINISHED);`
at packaging rather than removing the row — so a naive `count(*)` accumulates across the order's whole
life. Any count must filter on `unitloadId IS NOT NULL` and state.

Where this shape *is* right is answering the different question **"does this order already have a
cart?"**: take any existing `PickingorderUnitload` for the order with a non-null `unitloadId`, load
that `Unitload`, read its `carrierunitloadId`. Non-null ⇒ that is the cart; null ⇒ mint. That is
self-healing, needs no new column, and naturally skips the packaged rows because their `unitloadId`
is already null.

**C. `MERGE_PICKING_ORDERS` sysprop — NOT SOUND alone.**

It gates only whether `ReplenishOrderJob.mergePickingOrders()` runs:

```java
if (!Boolean.parseBoolean(syspropService.getSysvalue(WmsConstants.SYSTEM_PROPERTY_MERGE_PICKING_ORDERS_KEY))) {
```

A TOTES_ON_CART section with merging OFF still does cart picking, one order per cart. Blind spot:
`getSysvalue` is cached ~2 minutes and sysprops are per-client, so this value is not a reliable
synchronous read at scan time.

**D. `PICKING_BOX_PER_CART` — a capacity hint, NOT a detector.**

`ReplenishOrderJob` treats it as a job parameter, not order state: it *returns early* when the value is
`< 1` or `== 1`, and the cap is applied inside the job loop (`if (orders == boxesPerCart) { … pickingOrder = null; … }`).
Nothing writes the achieved count onto the order. Reading it at scan time to conclude "this order
expects up to N totes" is a guess — the job may have run out of candidate orders and produced a batch of
2 when the value says 6.

### Recommendation

Gate the mint on **A**, null-guarded and failing loudly on an unrecognised `sectionpickingtype`; answer
"already has a cart?" with **B**'s lookup form (read the carrier off an existing attached tote), not a
counter. Treat **C** and **D** as configuration for the *merge job*, not as inputs to the mint decision.

---

## Q3 — Where does the Cart live, and would anything reject it?

### The only gate that fires is `LocationConstraintService.isUnitloadTypePermitted`

- `PutawayDestinationValidator` **never runs on this path.** Its own class javadoc says
  *"predicate P2 (suitability), evaluated at CONFIG-WRITE TIME ONLY"* and *"It deliberately does NOT
  run at receive time"*. It is reached from putaway-config writes and `PutawayDestinationQueryService`.
  Not a risk.
- `transferUnitLoadToCarrier` does **not** consult location constraints at all — it checks the two
  unit-load-type flags and then calls `processTransfer`, which does a bare
  `unitload.setStoragelocationId(destinationLocation.getId());`.
- `transferUnitLoadToLocation` **does**:

```java
List<LocationConstraint> locationConstraintList = locationConstraintRepository.findByStoragelocationtypeId(destinationLocation.getTypeId());
if (locationConstraintList != null && !locationConstraintList.isEmpty()) {
    if (!locationConstraintService.isUnitloadTypePermitted(destinationLocation.getTypeId(), unitload.getTypeId())) {
        … throw new BusinessException("unitloadTypeNotPermittedOnLocation", …);
```

`LocationConstraintService` **fails open on an empty constraint set** and closed otherwise:

```java
// THE FAIL-OPEN. Keep the return adjacent to the guard — see the class comment.
if (locationConstraintList == null || locationConstraintList.isEmpty()) {
    return true;
}
```

So the whole question reduces to: *does the destination's `location_type` have any `location_constraint`
rows, and if so is Cart among them?* Cart has none anywhere — `UtilRestController.initDB` loads
`unitLoadType_cart` and never passes it to `locationConstraintService.createEntity(...)`, while Pallet
gets two.

### Measured on both live databases

| Location | `location_type` | permitted unit-load types | Cart accepted? |
|---|---|---|---|
| user locations (area `users`) | `NoRestriction` | *(0 constraint rows)* | **YES** — fail-open. 8 such locations on Hydra PRD; all `users` rows on WineCo UAT |
| `Nirwana` | `NoRestriction` | *(0 rows)* | **YES** |
| `Clearing` | `NoRestriction` | *(0 rows)* | **YES** |
| `EmptyTotes` | `totes` | `Tote` | **NO** |
| `EmptyPallets` | `overstock pallet` | `Case,Pallet` (Hydra PRD) / `Pallet` (WineCo UAT) | **NO** |

### Where the Cart should live: the picker's `userLocation`

It is the only non-virtual location that accepts a Cart on both tenants without a data change, which is
what D1 requires. And it does not need to "follow" the picker, because it *is* the picker: a picking
order has one operator (`operatorId` + `lockedtooperator`), so one cart ↔ one order ↔ one user
location.

Direction of travel is the opposite of the intuition: attaching pulls the tote **to** the cart.
`transferUnitLoadToCarrier` resolves `destinationLocation` from the cart and hands it to `processTransfer`,
which sets the child's `storagelocationId` to it, recursively. The cart does not chase the tote.

### ⚠ The ordering trap — this is load-bearing

`transferUnitLoadToLocation` clears the carrier on its way through (at `:268`, near the END of the method, not at its head):

```java
// check if this unit load has parent unit load (carrier - pallet or cart). If so, remove link to the existing (old) parent
Unitload parentUnitload = null;
if (carrierunitloadId != null) {
    parentUnitload = unitloadRepository.findById(carrierunitloadId)…;
    unitload.setCarrierunitloadId(null);
    unitload = unitloadRepository.save(unitload);
}
```

Site 1 calls exactly that on the tote, right after the `create`:

```java
unitloadBusinessService.transferUnitLoadToLocation(tote, userLocation, false, WmsConstants.CODE_ASSIGN_TOTE, customerOrder.getNumber(), null);
```

**A Cart attach placed before that line is silently undone — no exception, no log, just a null
`carrierunitload_id`.** The attach must go after it. (That comment, incidentally, already names the
cart: the design intent has been in the code all along.)

### Does the packaging path actually clear `carrierunitload_id`? — VERIFIED YES, and the reason matters

This was flagged as the headline stranding risk: if a tote leaves a Cart without the link being cleared,
the Cart is permanently non-empty and both `relocateEmptiedContainer` ("is carrier!") and
`MobileMoveUnitloadService` refuse it forever. Traced rather than assumed. The full statement order of
`transferUnitLoadToLocation` is:

| # | Step | Guarded by `ignoreLock`? | Can it throw before the clear? |
|---|---|---|---|
| 1 | `Long carrierunitloadId = unitload.getCarrierunitloadId();` | no | — |
| 2 | BLOCK_REALIGN pre-walk (`collectStockUnitIdsForUnitloadTree` + `lockOwningPickingorders`) | no — gated on the **activity code** | only for BLOCK_REALIGN codes |
| 3 | `findByIdForUpdate` + `entityManager.refresh(destinationLocation)` | **yes** — skipped when `ignoreLock=true` | — |
| 4 | `destinationLocation.getEntityLock() != NOT_LOCKED` → `FacadeException` | **yes** — skipped | yes, when locked |
| 5 | `FixLocationAssignment` check on the destination | no | yes |
| 6 | location-constraint check → `unitloadTypeNotPermittedOnLocation` | no | yes |
| 7 | **`unitload.setCarrierunitloadId(null); unitload = unitloadRepository.save(unitload);`** | **no** | — |
| 8 | `processTransfer(...)` | no | yes |

So `ignoreLock=true` skips **only steps 3–4** — it does *not* skip the clear. For the packaging call
specifically:

- **Step 2 does not run.** `CODE_FINISHED_PACKAGING_MOVE_TOTE` is in
  `PickLineActivityCodeClassifier.PASS_THROUGH_CODES`, not `BLOCK_REALIGN_CODES` (which is only
  `{CODE_MOVE_FIX_ASSIGNMENT, CODE_MANUAL_TRANSFER, CODE_TRANSFER, CODE_ON_HOLD}`). Site 1's own
  `CODE_ASSIGN_TOTE` is likewise PASS_THROUGH.
- **Step 5 passes trivially** — by this point the tote is empty (`transferStockToUnitLoad` has moved
  every stock unit into the package UL), and `findByCarrierunitloadId(tote)` is empty because a tote has
  no children.
- **Step 6 passes** — destination `EmptyTotes` is type `totes`, permitting `Tote`.
- **Step 1 reads a fresh value** — `CustomerorderService` loads the tote a few lines earlier in the same
  transaction (`Unitload pickingTote = unitloadRepository.findById(customerOrder.getPickingtoteId())…`),
  so it is a managed entity reflecting the committed carrier link from pick time.

**⇒ The clear fires. Totes detach from the Cart at packaging with no new code.** The headline risk is
not realised on this path.

### ⚠ But the instinct was right, aimed one path over: the clear trusts the caller's snapshot

Step 1 reads `carrierunitloadId` from the **caller-supplied** `Unitload`, and is never re-read under
lock. Contrast its sibling `transferUnitLoadToCarrier`, which opens with:

```java
// NOT locked — lock must be held by caller (SBDEV-2232 §3.0)
Unitload unitload = unitloadRepository.findById(staleUnitload.getId()).orElseThrow(…);
```

`transferUnitLoadToLocation` has no equivalent — its parameter is even named `unitload`, not
`staleUnitload`, while `processTransfer`'s *is* named `staleUnitload` and does re-read. So **any caller
that passes a detached or stale `Unitload` loaded before the Cart was attached skips the clear
silently** — no exception, no log — and strands the tote on the Cart permanently.

That is not hypothetical in this codebase: detached entities reaching services is an established
pattern, documented in `processPick`'s own comment — *"The controller loads these outside a transaction,
so they arrive as detached objects."* Every current caller I checked re-reads first, so nothing is broken
today; the exposure is that Cart attachment makes a previously-harmless staleness newly destructive.

**This is the stranding vector to guard, and it is a one-line hardening**: give
`transferUnitLoadToLocation` the same re-read-by-id opening its sibling already has. Worth proposing on
the ticket regardless of which Q5 option is chosen.

### ⚠⚠ The real runtime failure: `relocateEmptiedContainer` routes Cart to a location that rejects it

`UnitloadBusinessService.relocateEmptiedContainer` already has a Cart branch, added under SBDEV-2001:

```java
switch (type.getName()) {
    case WmsConstants.UNIT_LOAD_TYPE_PALLET:
    case WmsConstants.UNIT_LOAD_TYPE_CART:
        targetLocationName = WmsConstants.STORAGE_LOCATION_EMPTY_PALLETS;
        break;
```

and its javadoc states the intent plainly: *"Pallet, Cart -> EmptyPallets"*. It then calls
`transferUnitLoadToLocation(unitload, target, true, WmsConstants.CODE_CONTAINER_RELOCATED_EMPTYPOOL, …)`.
Note `ignoreLock = true` skips only the destination **lock** re-fetch; the constraint check still runs.

`EmptyPallets` is `overstock pallet`, permitting `Case,Pallet` / `Pallet` — **the constraint list is
non-empty and Cart is not in it**, so `isUnitloadTypePermitted` returns false and the call throws
`BusinessException("unitloadTypeNotPermittedOnLocation", "Cart", "EmptyPallets", "overstock pallet")`.

Six call sites reach `relocateEmptiedContainer`, including two on live paths:
`PickingorderBusinessService` (`relocateEmptiedContainer(pallet, WmsConstants.CODE_PICKING_CARRIER_EMPTY, …)`,
inside pick confirmation) and `BillofladingService` (`relocateEmptiedContainer(unitLoad, WmsConstants.CODE_SEND_TO_NIRVANA, null, null)`).

**This is pre-existing, already-merged code, unreachable today only because zero Cart rows exist.**
SBDEV-3320 makes it reachable. Three ways out, and the choice is a product decision, not an
architectural one:

1. Add a per-tenant `location_constraint (overstock pallet, Cart)` row — **conflicts with D1's "no
   live-tenant data change"**.
2. Never route a Cart through `relocateEmptiedContainer` — the cart-release step retires it via
   `sendToNirvana` (Nirwana is `NoRestriction` with 0 rows, so it is accepted), or leaves it at the
   user location.
3. Change the `case UNIT_LOAD_TYPE_CART:` target. Cheapest, but it edits shipped SBDEV-2001 behaviour.

I would take (2) and leave the SBDEV-2001 switch alone — but the plan must say which, because leaving
it unstated ships a guaranteed exception on the first emptied cart.

### Related: nothing in `src/main` ever retires a Cart

Both retire paths refuse a carrier with children:

```java
if (!unitloadRepository.findByCarrierunitloadId(unitload.getId()).isEmpty()) {
    throw new BusinessException("Can not delete. unitLoad=" + unitload.getId() + " is carrier!");
}
```
(`sendToNirvana`; `relocateEmptiedContainer` has the same guard with `"Can not relocate."`)

That is correct, but it means the Cart's *only* automatic exit is via the last tote detaching — and
the only thing that detaches a tote is `transferUnitLoadToLocation`, which nothing calls on the Cart
itself. **Carts would accumulate at user locations indefinitely unless the ticket adds a release
step.** This is the design gap, not a bug in anything existing.

The tote side, by contrast, already works by accident and is worth protecting: at packaging,
`CustomerorderService` does `transferUnitLoadToLocation(pickingTote, emptyTotesLocation, true, …)`, whose
head clears `carrierunitload_id` — so **totes detach from the Cart at packaging with no new code**, and
they pass the `EmptyTotes` constraint because they are Totes. Any change to that branch would strand
totes on carts.

---

## Q4 — Where does the Cart's label come from?

> **Revised.** My first pass recommended (a) synthetic-per-order on the grounds that it keeps the
> ticket single-repo. The scale datum below overturns that. The question is not really "what string
> goes in `labelid`" — it is **"is a Cart record a durable asset or a per-order token?"**, and the
> codebase has already answered that question for the Tote, in this same method.

### Scale: this is not a rare path

| | WineCo UAT | Hydra PRD |
|---|---|---|
| sections | **26 of 27** `TOTES_ON_CART` (1 × `RAPID_PICKING`, `test_section`) | **2 of 2** `TOTES_ON_CART` |
| `pickingorder` rows | 66,000+ (peak 4,476/month in 2026-03; ~500–800/month recently) | 166 |
| `customerorder` rows | 481,157 | 169 |
| `unitload` rows total | 870,840 | 823 |
| distinct pickers (ever / last 90d) | 56 / 11 | 3 |
| user locations | 116 | 8 |

A Cart minted per merged picking order is minted on **essentially every pick** at both tenants.

### The Tote is the precedent, and it is a reuse model

`unitload` rows by type on WineCo UAT: `Package` 469,623 · `Case` 351,532 · `PickLocation` 29,401 ·
`Pallet` 19,251 · **`Tote` 1,032** · `Default` 1.

Of those 1,032 Tote rows, **790 carry a mangled `-X-<id>` label** (retired via `sendToNirvana`), leaving
~242 live records, of which **227 currently sit on `EmptyTotes`** — the reusable pool. Sample labels:
`T-0004`, `T-0117`, `T-0166`, `T-9996`, `T-9997` — a durable, human-readable, physically-applied scheme.

So: **~242 tote records serve a warehouse that has processed 481,157 customer orders.** The picking
asset is not minted per order; it is scanned, found, and reused.

*(A caution I chased down rather than assumed: `customerorder.historytote` has 198,056 distinct values,
which looks like it contradicts the above. It does not — those values are UUIDs
(`ffff9a64-73ad-4f08-b748-fe1d527bdd50`), i.e. the RAPID_PICKING parcel-LPN shape written by
`rapidPickingConnectPackageAndType`, not `T-####` tote labels.)*

And site 1 **already implements reuse-by-scanned-label**, in code, for the tote:

```java
Optional<Unitload> toteOpt = unitloadRepository.findByLabelid(toteName);
Unitload tote = toteOpt.orElse(null);
…
if (tote == null) {
    … tote = unitloadService.createUnitload(toteName, emptyTotesLocation, type.getId(), client.getId(), WmsConstants.CODE_PICKING);
} else {
    … reclaim-from-finished-order / not-on-empty-totes / not-empty checks …
}
```

`UnitloadBusinessService.relocateEmptiedContainer` independently classifies Cart as **reusable**,
alongside Pallet and Tote and explicitly *not* alongside the single-use types
(`KNOWN_NON_REUSABLE_TYPE_NAMES = {BOX, PICKLOCATION, PACKAGE, DEFAULT}`). Pallet's row count bears that
out: 19,251 pallets against 481,157 orders.

**Minting a Cart per order would model a reusable physical asset the way the system models a
single-use package.** That is the opposite of what both the code and the data say a Cart is.

### The three options, priced

**A — mint-per-order, synthetic label. Not recommended; this is the option I withdraw.**
Single-repo and cheapest to write. Costs: ~66k+ new `unitload` rows at WineCo and rising (it would pass
Pallet's population within a couple of years and keep going); it contradicts the reusable classification
above; and it *requires* a retire step, which is the one thing that walks straight into the
`EmptyPallets` constraint defect (Q3) — `relocateEmptiedContainer` would throw on the first emptied
cart, so A has to also solve that problem to be shippable at all.

**B — per-picker cart, keyed on the user location. The cheapest *correct* option, single-repo.**
Reuse "the Cart currently at this picker's user location":
`unitloadRepository.findByStoragelocationId(userLocation.getId())` filtered to type Cart — reuse if
found, mint if not. Row count is bounded by the picker population: 11 active pickers / 116 user
locations at WineCo UAT, 3 / 8 on Hydra PRD. The cart is **never retired**, so the `EmptyPallets`
defect is never reached and no retire step is needed. No mobile UI change.

*Blind spots, and one of them is real:*
- It models "this picker's cart", not a physical cart. A picker swapping carts mid-shift is invisible;
  two pickers sharing one cart is unrepresentable.
- **Release-and-reclaim across pickers.** `releaseRegularPickingOrder` Case 3 does
  `pickingOrder.setOperatorId(null); pickingOrder.setState(WmsConstants.State.PROCESSABLE);`, so the
  next claimant is a different user with a different user location — and hence a different cart — while
  the previous picker's cart may still hold that order's totes. Note the existing design already carries
  this exact hazard for the *tote* and tolerates it, because the picker physically carries the tote and
  `processPick` has an explicit reclaim branch (`tote={} reclaimed from finished order={}`). Whatever B
  does here should mirror that branch rather than invent a second convention.
- It gives no answer to "where is cart C-0007", because there is no C-0007.

**C — physical cart scan. The faithful model. Multi-repo.**
Scan a `C-####` label, `findByLabelid`, reuse-or-create — i.e. character-for-character what the tote
already does ten lines above. Row count bounded by the number of physical carts. True asset identity:
you can locate a cart, audit utilisation, and represent a swap. Costs: a new step in
`wms2-mobile-ui/components/picking/` plus store action and endpoint; physical labels printed and applied
to the carts; and a `wms2-mobile-ui` release, which drags in the known `:develop` tag race that can
deploy an older image when two merges land in one build window.

### Answer to the question as asked

**Does correct reuse force the physical-cart-scan option, and therefore multi-repo?**

**No — but only because B redefines "which cart" as "the picker's", which is a weaker claim than the
Tote precedent makes.** If the Cart record needs to mean a *physical cart* — to be located, audited,
swapped, or shared — then **yes, C is required and SBDEV-3320 is multi-repo**, and there is no
single-repo shortcut to it, because nothing but the picker can tell the server which cart they took.

My recommendation: **C is the correct end state; B is a legitimate first increment** that is bounded,
avoids the retire problem entirely, and does not have to be unwound to get to C later (B's
location-derived lookup becomes C's fallback when no scan is supplied). **A should be dropped.** This is
a product call about what a Cart record is for, and it should be made explicitly rather than inherited
from whichever label scheme is easiest to write.

### If a synthetic label is used anyway, one hazard

`Unitload.labelid` is read via `Optional<Unitload> findByLabelid(...)`, so a duplicate label is the same
non-unique-`Optional` shape that bit tote reuse (SBDEV-3287). Do **not** concatenate the picking order
number: the merge service *re-uses* the survivor order, keeping its `number` and setting it back to
`PROCESSABLE` (`pickingOrder.setState(WmsConstants.State.PROCESSABLE); pickingOrder.setSectionId(section.getId());`),
so `CART-<number>` collides across successive cart generations of the same order. Mint through the
existing sequence machinery — `UnitloadBusinessService.mintFreshUnitloadLabel()` exists for exactly this
problem on the pallet-recovery path, and `BasicService.generateNumber(prefix, entity)` backs the rest of
the entity numbering.

---

### Appendix to Q4 — the original single-repo evidence (unchanged and still true)

#### `wms2-mobile-ui` has no cart scan step

Complete result of `git grep -in "cart"` on `origin/develop`, excluding `static/` (fontawesome) and
lockfiles — five hits, none of them a scan:

| File | Hit | What it is |
|---|---|---|
| `components/picking/selectOrder.vue` | `<v-card-subtitle …>Cart Picking</v-card-subtitle>` | a static heading |
| `components/putaway/scanPallet.vue` | `<label …>Scan Pallet / Cart / Unitload</label>` | prompt text on the **putaway** screen |
| `store/picking.js` | `} else if (result.sectionpickingtype === 'TOTES_ON_CART') { return 'Tote' }` | mode routing |
| `store/home.js` | `icon: "far fa-luggage-cart"` | a menu icon |
| `util/menuCatalog.js` | `icon: 'far fa-luggage-cart'` | a menu icon |

There is no component, route, Vuex action, or store field for scanning a cart. Option (b) therefore
requires: a new step in the picking flow, a new API endpoint, and a `wms2-mobile-ui` release — which
also drags in the known `:develop` tag race that can deploy an older image when two merges land in one
build window. **That is a genuine multi-repo ticket.**

#### No physical cart labels exist today

Zero Cart `unitload` rows have ever existed on either tenant, so option C additionally requires printing
and applying `C-####` labels to the physical carts before the feature can be switched on. That is a
warehouse-operations task with a lead time, not a code task — worth sequencing early if C is chosen.

---

## Q5 — Smallest correct code shape for D1

### What the existing guard actually protects

There are **two independent guards**, and only one of them blocks:

```java
if (sourceType != null && !sourceType.getOnotherunitloadallowed()) {
    throw new BusinessException("unitLoad=" + unitload.getLabelid() + " with type=" + sourceType.getName() + " not allowed on other unit load");
}

if (destinationType != null && !destinationType.getUnitloadallowed()) {
    throw new BusinessException("No unit load allowed on unitLoad=" + destinationUnitload.getLabelid() + " with type=" + destinationType.getName());
}
```

- The **destination** guard already permits Cart — `Cart.unitloadallowed = true` (per the brief).
- The **source** guard is the blocker, and it is a statement about the *source type in the abstract*:
  "a thing of this type is never a child of anything." It carries no knowledge of the destination.
  `Tote.onotherunitloadallowed = false` is what stops the attach.

So the protection being asked about is: *totes are top-level containers; do not nest them.* That is a
real invariant elsewhere in the system — a large amount of code assumes a picking tote has no parent
(see the sweep below).

### The three options

**Option 2 — make the existing guard destination-aware (exempt when destination type is Cart).**
Two lines; the cheapest edit. **It also re-opens exactly what the guard protects, and not
theoretically.** The exemption would apply to all eight callers of `transferUnitLoadToCarrier`:

```
service/AdviceService.java                     transferUnitLoadToCarrier(parcel, palletMap.get(...), CODE_ACCEPT_HUB_AND_SPOKE, ...)
service/ParcelMonitorViewService.java  (×2)    transferUnitLoadToCarrier(unitLoad, pallet, CODE_PALLETISING, ...)
service/ReceivingService.java                  transferUnitLoadToCarrier(unitload, carrier, codeReceiving, ...)
service/StockunitService.java                  transferUnitLoadToCarrier(unitLoad, pallet, CODE_MANUAL_SPLIT, ...)
service/mobile/MobileMoveUnitloadService.java  transferUnitLoadToCarrier(sourceUnitLoad, destinationUnitLoad, CODE_TRANSFER, null, null)
service/mobile/MobilePalletizingService.java (×2) transferUnitLoadToCarrier(parcel, pallet, CODE_PALLETISING, ...)
```

The one that matters is `MobileMoveUnitloadService`: its destination is *whatever the operator
scanned*. Today an operator who scans a Cart as the destination for a Tote gets a clean refusal; after
a blanket exemption they would succeed, nesting a tote on a cart outside picking, with no picking
order and nothing to ever release it. **That is a live mobile path and a real regression, so option 2
violates D1's "the global guard must stay in force for every other caller" in substance even though it
leaves the line in place.** Not recommended.

**Option 3 — direct `setCarrierunitloadId` at the mint site**, matching `BillofladingService`
(`parcel.setCarrierunitloadId(pallet.getId());`) and `ParcelMonitorViewService`
(`unitLoad.setCarrierunitloadId(pallet.getId());`, ×2). One line. It skips *everything*:

- the self-reference check (`CARRIER_SELF_REFERENCE`);
- the **ascent** cycle guard and its `Set<Long> seen` — both added by SBDEV-3091 after the original
  compared boxed `Long`s with `==` and was dead for every real id;
- the **descent** cycle guard in `processTransfer`'s `visited` set;
- the parent detach (`if(unitload.getCarrierunitloadId() != null) { parentUnitLoad = … }`);
- `processTransfer`'s storage-location propagation — so the tote's `storagelocationId` would *not*
  follow the cart, and the two would silently disagree;
- `unitloadRecordService.recordForTransferUnitLoad(...)` — **the audit row**. Every other carrier
  attachment in the system writes one; a cart attach would be invisible to container history.

The three existing bypass writers are precedent for "we knowingly skipped the guard on a bulk
palletising loop", not a pattern to extend to a brand-new relationship on a per-scan path. Not
recommended.

**Option 1 — a new `transferUnitLoadToCart(...)` on `UnitloadBusinessService`. Recommended — but in
its shared-core form, not as a copy.**

Naïvely this duplicates ~40 lines, and a copy is a real risk: this method has already accumulated two
SBDEV-3091 fixes that a copy would silently fail to inherit. So the shape should be:

- extract the existing body once into a private core that takes the source-type predicate as a
  parameter (a `boolean allowNestingExemption`, or a small enum);
- `transferUnitLoadToCarrier(...)` keeps its exact current semantics and remains the only method the
  eight existing callers see;
- `transferUnitLoadToCart(Unitload tote, Unitload cart, …)` is the new, **narrow** entry point that
  asserts *source type is Tote* **and** *destination type is Cart* before delegating, and otherwise
  runs every guard, the recursion and the audit unchanged.

That gives, in order of what matters:

1. the global guard stays literally in force for every other caller (D1, satisfied in substance);
2. one implementation of the cycle guards and one audit path — no drift;
3. the exemption is **named and greppable** (`transferUnitLoadToCart`), so it is testable and a future
   reader can see exactly how wide it is: Tote→Cart, nothing else;
4. it states the rule as an invariant ("the source-type gate does not apply for a Tote onto a Cart")
   in one place, rather than as an instance at a call site.

The cost over option 3 is roughly one method plus a parameter on a private method. That is the right
price for keeping the audit row and both cycle guards on a live picking path.

---

## Reader sweep — what now behaves differently because a tote has a non-null `carrierunitload_id`

### Method

1. `git grep -n "findByCarrierunitloadId\|getCarrierunitloadId\|setCarrierunitloadId\|carrierunitload_id" origin/develop -- 'src/main/java/*'`
   → ~100 sites across 30 files.
2. A wider net for anything the accessor grep would miss:
   `git grep -ln "carrierunitload\|carrierUnitload\|CarrierUnitload" origin/develop -- 'src/*'`
   → 80 files including SQL migrations and tests.
3. Split into **UP-readers** (`X.getCarrierunitloadId()` where X could be a picking tote — these are the
   dangerous ones, because a tote that was top-level now has a parent) and **DOWN-readers**
   (`findByCarrierunitloadId(id)` — reachable only with the Cart's id, or with the tote's id, and the
   tote still has no children).
4. For each UP-reader, asked whether a *picking tote* actually reaches it, and checked the answer
   against live data where the answer depended on data rather than code.

**Positive control:** the sweep returned 100+ hits across 30 files, so the instrument is not silently
returning a false zero.

### Blind spots of this method — stated, not hidden

1. **Spring Data REST exposure.** `UnitloadRepository.findByCarrierunitloadId`,
   `findByCarrierunitloadIdIn`, `findDetailsByCarrierunitloadId`, `findCountByCarrierunitloadId` and
   `findEmptyByStoragelocationId` all carry `@RestResource(path = …)` and are exported over `/v3`.
   **Their HTTP consumers are invisible to a `src/main` grep** — both UIs and OMS can call them
   directly. This is the largest hole in the sweep.
2. **SQL that lives only in the database.** `carrierunitload_id` appears in
   `db/migration/V2.2.00__base_v2_schema.sql` and `V2.2.02__lock_report_exclude_shipped.sql`; the tenant
   schemas also carry ~12 VIEWS and pl/pgsql report functions. A Java grep sees none of the deployed
   view/function bodies.
3. **Other repos not swept.** I swept `wms2-mobile-ui` for "cart" (Q4) but not for
   `carrierunitload` consumers generally, and I did not sweep `wms2-web-ui` or `oms-laravel-api` at all.
4. **Reflection / SpEL / string-assembled JPQL** are not covered by a token grep.
5. `git grep` was used throughout, so the ugrep binary-file trap does not apply here.

### HIGH — "set stock on hold" newly refuses a picked tote

`service/StockunitService.java`:

```java
if (stockUnitLoad.getCarrierunitloadId() != null) {
    Optional<Unitload> childUnitLoad = unitloadRepository.findById(stockUnitLoad.getCarrierunitloadId());
    if (childUnitLoad.isPresent()) {
        throw new BusinessException("Can not set lock. Unit load is on another unit load (carrier like pallet). Separate first.");
    }
}
```

A tote holding picked stock that now sits on a Cart can no longer be put on hold. **This is a new
rejection on a live admin path**, and the operator-facing message ("carrier like pallet. Separate
first.") will be actively confusing, because there is no operator-visible way to separate a tote from a
cart. (Note the local variable `childUnitLoad` actually holds the *parent* — pre-existing, and it makes
this site easy to misread.)

### HIGH — the transfer-order source picker re-roots onto the Cart

`service/TransferOrderService.java` resolves each candidate unit load to its **root**:

```java
while (unitLoad.getCarrierunitloadId() != null) {
    carrierCache.put(unitLoad.getId(), unitLoad);
    Optional<Unitload> carrierOpt = unitloadRepository.findById(unitLoad.getCarrierunitloadId());
    …
}
…
if (ulWithoutCarrier.stream().noneMatch(ul -> ul.getId().equals(currentUnitLoad.getId())) && customerOrder.getClientId().equals(currentUnitLoad.getClientId())) {
    ulWithoutCarrier.add(unitLoad);
}
```

The candidate set comes from `UnitloadRepository.getBatchLocationsByItemIdAndTransferableAreas`, whose
WHERE clause **explicitly includes user locations**:

```sql
WHERE su.itemdata_id = :itemDataId
  AND (lo.staginglane = true OR lo.id = :clearingLocationId
       OR area.usefortransfer = true OR area.name = 'users')
```

There is **no entity-lock filter**, so a mid-pick tote sitting at a user location and holding picked
stock of the item is in this population *today*. Today it resolves to itself (carrier null). After the
change it resolves to the **Cart**, and the DTO is built from the cart:
`dto.setUnitLoadId(unitLoad.getId()); dto.setUnitLoadName(unitLoad.getLabelid()); dto.setLocationName(...)`.
The summed amount would still be right (`calc()` recurses down through children), but the operator
would be offered *the cart* as a transfer source instead of the tote. Affects the club / transfer-order
SKU picker.

### HIGH — nothing retires a Cart (design gap)

Covered under Q3. Both `sendToNirvana` and `relocateEmptiedContainer` refuse a carrier with children;
nothing calls either on the Cart. Combined with the `EmptyPallets` constraint finding, the release step
cannot simply reuse `relocateEmptiedContainer`.

### MEDIUM — `findEmptyByStoragelocationId` changes meaning at user locations

`repo/jpa/UnitloadRepository.java`:

```sql
and ul.id not in (select ulc.carrierunitload_id from unitload ulc where ulc.carrierunitload_id = ul.id)
```

This excludes unit loads that *are* carriers. A Cart at a user location is included while empty and
excluded once loaded. Exported over `/v3` as `findEmptyByStoragelocationId` — **HTTP consumers unknown**
(blind spot 1).

### MEDIUM — `findCountByCarrierunitloadId` has a top-level assumption baked in

```sql
SELECT count(*) from unitload where carrierunitload_id IS NULL
   OR carrierunitload_id = CAST(CAST(:carrierunitloadId AS TEXT) AS BIGINT)
```

This counts **every root unit load in the tenant** plus the given carrier's children. Minting carts
shifts that population: each cart adds one root, each attached tote removes one. I found **no Java
caller** — so its only consumers reach it over `/v3` and I cannot enumerate them. Flagging rather than
clearing it.

### MEDIUM — container search and DTOs start showing a cart as the parent

`getDetailViewByKeyword` joins `left join unitload pu on u.carrierunitload_id = pu.id` and folds
`LOWER(pu.labelid)` into its keyword CONCAT, so totes on a cart would newly match a search for the
cart's label, and the `parentContainer` column would start populating for picking totes.
`service/ViewDtoService.java` feeds the id through (`dto.put("carrierunitloadId", result.getCarrierunitloadId())`),
and `service/UnitloadService.java` adds `details.put("carrierunitload", parent.getLabelid())`.
Cosmetic but user-visible.

### MEDIUM — mobile Move Unit Load

`service/mobile/MobileMoveUnitloadService.java` sets
`dto.setUnitLoadCarrierName(unitLoad.getCarrierunitloadId() == null ? null : … .getLabelid())`, so the
Move screen would display a cart for an in-flight picking tote. Its
`transferUnitLoadToCarrier(sourceUnitLoad, destinationUnitLoad, WmsConstants.CODE_TRANSFER, null, null)`
is the specific call site that makes option 2 in Q5 unsafe.

### MEDIUM — putaway already refuses a Cart, with a misleading message

`service/mobile/MobilePutAwayService.java` branches only on Pallet / Box; a scanned Cart falls to
`else if (!isBox) { throw new BusinessException("entityNotFoundForName", Unitload.class.getSimpleName(), putAwayMobileDto.getUnitLoadName()); }`
— i.e. "no such unit load", for a unit load that exists. Pre-existing, but Cart instantiation makes it
reachable, and `wms2-mobile-ui/components/putaway/scanPallet.vue` literally prompts
**"Scan Pallet / Cart / Unitload"**, so the UI invites the scan.

### Cleared, with the reason

- **`CustomerorderRepository.getManifestLocationsByPalletName`** — `JOIN unitload parcel on co.parcel_id = parcel.id
  JOIN unitload pallet on parcel.carrierunitload_id = pallet.id`. Joins on `co.parcel_id`, which is the
  **package** unit load created at packaging, never the picking tote:
  `CustomerorderService` does `customerOrder.setPickingtoteId(null); customerOrder.setParcelId(packageUnitLoad.getId());`
  in the same block. Verified on live data — Hydra PRD: 155 rows with `parcel_id`, 2 with
  `pickingtote_id`, **0 with both**; WineCo UAT: 469,619 with `parcel_id`, **0 with `pickingtote_id`**
  out of 481,157. `CustomerorderRepository:108` and `BillofladingPositionRepository:59` clear for the
  same reason (both join from a BOL position's `source_id`).
- **`BillofladingPositionService.assertParcelCarrierNotShipped`** — reads `parcel.getCarrierunitloadId()`;
  same `parcel_id` argument.
- **`PickingorderBusinessService`** (`if (stockunitUnitLoad.getCarrierunitloadId() != null) { pallet = … }`)
  — reads the carrier of the **pick-from** stock unit's unit load, not the tote.
- **`CustomerorderService.cancelOrder`** — `findByCarrierunitloadId(pickingTote.getId())` walks *down*
  from the tote, which still has no children; the following `sendToNirvana(pickingTote, …)` reaches
  `transferUnitLoadToLocation`, which clears the carrier first. Works, and silently detaches. Worth a test.
- **Down-only walks unaffected** (a picking tote is never under these containers):
  `BillofladingService` (×4), `GoodsReceiptPositionService`, `MobileCycleCountService` (×5),
  `MobileTruckLoadingService`, `StockunitBusinessService` (×2), `FixLocationAssignmentService`,
  `CustomerorderBatchService` (×3), `PickLineRealignmentService`, `MobileInfoService`,
  `ParcelMonitorViewService` (its `pallet.getCarrierunitloadId()` site is guarded by an explicit
  `if (!pallet.getTypeId().equals(type_pallet.getId())) throw new BusinessException("Not a pallet: " …)`).

---

## Existing tests that would break

`git grep -ln "processPick\|rapidPickingConnectPackageAndType\|transferUnitLoadToCarrier\|UNIT_LOAD_TYPE_CART\|\"Cart\"" origin/develop -- 'src/test/*'`:

| File | Exposure |
|---|---|
| `unit/service/mobile/MobilePickingServiceUnitTest.java` | **The main one.** 3,042 lines; ~15 `processPick` tests across four `@Nested` classes (`processPick - Complex Tote Assignment`, `- re-read detached entities (Port 4)`, `- afterCommit for OMS tote assigned (Port 3)`, `- Cancelled Order Fixes`). Every one of them drives the `if (pickingUnitLoad == null)` block. New repository calls inside it return `null`/empty from unstubbed mocks → NPE, unless the mint code is written to tolerate that. |
| `integration/service/mobile/MobilePickingServiceIntegrationTest.java` | Testcontainers; seeded from `src/test/resources/scripts/mobilePickingService.sql` and `mobilePickingService2.sql`, both of which already mention `carrierunitload`. The fixtures would need a `Cart` `unitload_type` row and, for the location-constraint path, a user location with no constraints. |
| `unit/service/UnitloadBusinessServiceUnitTest.java`, `…ReplenBranchTest`, `…ReplenSyncTest` | Pin `transferUnitLoadToCarrier` / `relocateEmptiedContainer` behaviour. A shared-core refactor (Q5 option 1) touches the code they cover. |
| `service/UnitloadBusinessServiceConcurrencyIT.java` | Concurrency IT over the same methods. |
| `unit/service/LocationConstraintServiceUnitTest.java`, `unit/service/PutawayDestinationValidatorUnitTest.java` | Pin the fail-open semantics the Cart decision depends on — should stay green, and if they don't, that is a signal. |
| `unit/service/PickingorderUnitloadServiceUnitTest.java` | Pins `create(...)`, including the dead `setPositionindex(-1)`. |
| `unit/controller/mobile/PickingControllerUnitTest.java` | Controller-level `processPick` wiring. |
| `unit/service/mobile/MobilePalletizingServiceTest.java` / `…UnitTest.java`, `unit/service/ParcelMonitorViewServiceUnitTest.java`, `unit/service/ReceivingServiceUnitTest.java`, `unit/service/StockunitServiceUnitTest.java` | The other `transferUnitLoadToCarrier` callers — these are the regression surface for Q5 option 2, and the reason to prefer option 1. |
| `integration/NestedSendAfterCommitIT.java` | Exercises `processPick`'s OMS notification tail (SBDEV-3267). |

Two mechanics that matter for how these fail:

- `MobilePickingServiceUnitTest extends BaseServiceUnitTest` and **carries no `@MockitoSettings`** — its
  own comment says so — so `MockitoExtension`'s default `STRICT_STUBS` applies. A stub added for one
  test and unused by a sibling fails the sibling with `UnnecessaryStubbingException`.
- The dependencies the mint would need are **already declared as mocks** on that class —
  `sectionRepository`, `unitloadTypeRepository`, `unitloadService`, `unitloadBusinessService`,
  `unitloadRepository`, `pickingorderUnitloadRepository`. So the failure mode is unstubbed-returns-null,
  not a missing mock, and it will present as an NPE deep inside `processPick` rather than as an obvious
  wiring error.

Also worth noting for whoever writes the failing test first: per the repo's own guidance, an outer-level
`@Test` in a class that also has `@Nested` classes is reported under a nested report file, and the outer
class's report reads `Tests run: 0`. Confirm a new test ran via the lane total or
`grep -rl '<methodName>' target/failsafe-reports/`, not from the per-class `.txt`.

---

## Open questions for the product owner

These are decisions, not analysis gaps. Each blocks a concrete line of code.

1. **Is a Cart record a durable physical asset, or a per-order grouping token?** This is the decision
   that sizes the whole ticket (Q4). Asset ⇒ option C, a scanned `C-####` label, **multi-repo**, plus a
   physical labelling rollout. Grouping token ⇒ option B, a per-picker cart keyed on the user location,
   single-repo and bounded. Everything else follows from this answer, and it should not be inherited
   from whichever label scheme is easiest to write.
2. **What retires a Cart?** Nothing does today (Q3). Under option B the answer is "nothing, by design —
   it persists per picker", which is why B sidesteps question 3 entirely. Under A or C it needs an
   explicit release step.
3. **Which of the three `relocateEmptiedContainer` fixes?** Option (1) needs a live-tenant
   `location_constraint` row, which D1 forbids as written. Without a decision, the first emptied cart
   throws — but note this only becomes urgent if a Cart is ever retired, i.e. under Q4 option A or C.
4. **Does "cart order" mean "TOTES_ON_CART section" or "was actually merged"?** The sound signal
   answers the first. If the second is required, there is no stored signal and one would have to be
   added.
5. **Harden `transferUnitLoadToLocation` to re-read the row under lock?** One line, mirrors
   `transferUnitLoadToCarrier`, and closes the only vector by which a tote can strand on a Cart (Q3).
   Independent of the other four; proposable on this ticket since its own tier is well under T3.
