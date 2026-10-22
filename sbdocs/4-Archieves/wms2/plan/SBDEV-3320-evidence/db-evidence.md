# SBDEV-3320 — DB evidence

Collected 2026-09-11. Envs: **Hydra PRD** (`wh01_hydra_v2`) and **WineCo UAT** (`wsl-wineco-uat`).
Every zero below carries a positive control on the same query.

## 1. Cart has never been instantiated (confirms the ticket)

`unitload_type` LEFT JOIN `unitload`, grouped by type:

| type_id | name | Hydra PRD | WineCo UAT |
|---|---|---|---|
| 0 | Default | 0 | 1 |
| 1 | PickLocation | 141 | 29,401 |
| 2 | Tote | 8 | 1,032 |
| 3 | Package | 155 | 469,623 |
| 4 | Case | 479 | 351,532 |
| 5 | Pallet | 40 | 19,251 |
| **6** | **Cart** | **0** | **0** |

WineCo's controls reproduce the ticket's figures exactly. The zero is real.

## 2. BLOCKER — Tote may not sit on any carrier

`unitload_type` flags, identical on both envs and in the committed seed
(`src/main/resources/db/migration/V2.2.00__base_v2_schema.sql`, the `INSERT INTO public.unitload_type` block):

| name | stockunitallowed | unitloadallowed | onotherunitloadallowed |
|---|---|---|---|
| Tote | true | false | **false** |
| Package | true | false | true |
| Case | true | false | true |
| Pallet | false | true | false |
| **Cart** | **false** | **true** | **false** |

Cart as a *carrier* is fine (`unitloadallowed = true`, identical to Pallet). The blocker is the **Tote**
end: `UnitloadBusinessService` guards with `if (sourceType != null && !sourceType.getOnotherunitloadallowed())`
→ `BusinessException("… with type=Tote not allowed on other unit load")`, thrown before any write.
Palletizing works only because it moves Package/Case, the two types that carry the flag.

Three instruments agree (Hydra, WineCo, committed seed).

## 3. FALSE PREMISE — `PickingorderUnitload.positionindex` is dead

Ticket claims merged orders keep "its own tote slot via `positionindex`".

- Writers in `src/main`: two, both `setPositionindex(-1)` (`PickingorderUnitloadService`, `OrderMonitorViewService`).
- Readers in `src/main`: none.
- WineCo UAT `pickingorder_unitload`: **272,058 rows, one distinct value `-1`**, 2019-10-02 → 2026-09-09.

There is no per-tote slot identity for AC2 to reconcile against.

## 4. The real cart signal — `Section.sectionpickingtype = 'TOTES_ON_CART'`

Already modeled and already driving the live merge: `ReplenishOrderJob` calls
`sectionRepository.findBySectionpickingtype(WmsConstants.SectionPickingType.TOTES_ON_CART)` immediately
before `pickingOrderMergeService.mergePickingOrders(...)`. `WmsConstants.SectionPickingType` comments
`TOTES_ON_CART` as `// regular process`. Both UIs branch on it
(`wms2-mobile-ui/store/picking.js`: `result.sectionpickingtype === 'TOTES_ON_CART'`).

**Scale — this is the normal path, not an edge case.** WineCo UAT `section`: **26 of 27 rows are
`TOTES_ON_CART`**, carrying 66,000+ picking orders (Zone_F 10,818 · Zone_G 9,573 · Zone_D 9,508 · …).
The only `RAPID_PICKING` row is `test_section` (29). A Cart minted per merged picking order is minted on
essentially every picking order at WineCo — so Cart lifecycle/reuse is a first-class design question.

## 5. ⚠ DORMANT DEFECT THIS TICKET WOULD ACTIVATE

`UnitloadBusinessService.relocateEmptiedContainer` and `MobileMoveUnitloadService` both waterfall
**Pallet and Cart** to the `EmptyPallets` location. But `EmptyPallets` is location type `overstock pallet`,
whose `location_constraint` rows do **not** include Cart:

| location | location type | permitted unit-load types |
|---|---|---|
| EmptyPallets | overstock pallet | **Pallet** (WineCo) · **Case, Pallet** (Hydra) |
| EmptyTotes | totes | Tote |
| Clearing / Nirwana | NoRestriction | *(no constraints — unrestricted)* |

So the first time a Cart is emptied, `transferUnitLoadToLocation` throws
`BusinessException("unitloadTypeNotPermittedOnLocation", "Cart", "EmptyPallets", "overstock pallet")`.
It has never fired only because no Cart has ever existed. **The plan must add a Cart→`overstock pallet`
`location_constraint` row (or route Carts elsewhere) or it ships a broken cart-return path.**

Cart is in **no** constraint row at all, so a Cart is currently placeable only on location types that have
zero constraints. WineCo UAT:

| location type | constraint rows | locations | Cart placeable? |
|---|---|---|---|
| System | 0 | 20 | yes |
| NoRestriction | 0 | 120 | yes |
| cases and pallets | 0 | 583 | yes |
| flowbin | 1 (PickLocation) | 2,149 | **no** |
| overstock box | 1 (Case) | 3 | **no** |
| overstock pallet | 1 (Pallet) | 12 | **no** |
| totes | 1 (Tote) | 2 | **no** |
| packages | 1 (Package) | 1 | **no** |

Root cause: `initDB` (`UtilRestController`) loads `unitLoadType_cart` and never uses it, while
`unitLoadType_pallet` gets two `locationConstraintService.createEntity(...)` rows.

## 6. Good news — detach is already handled

`UnitloadBusinessService.transferUnitLoadToLocation` clears the link unconditionally when non-null
("check if this unit load has parent unit load (carrier - pallet or cart) … `unitload.setCarrierunitloadId(null)`"),
independent of the `ignoreLock` argument. The finish-packaging path
(`CustomerorderService`, `TOTES_ON_CART` branch → `transferUnitLoadToLocation(pickingTote, emptyTotesLocation, true, CODE_FINISHED_PACKAGING_MOVE_TOTE, …)`)
therefore detaches a tote from its Cart automatically. No stranded-carrier risk on that path.

## Method and blind spots

- Code claims: `git grep` by symbol over `origin/develop:src/main` (local checkout was 3 commits behind; not used).
  Blind spots: cannot see a Spring Data REST PATCH writing `carrierunitloadId` directly (ungated by the
  type guard by construction), and does not cover `src/test`.
- Carrier sweep counts: 41 `src/main` call sites read carrier children
  (`findByCarrierunitloadId` / `findCountByCarrierunitloadId` / `findByCarrierunitloadIdIn`);
  27 read a unit load's own `getCarrierunitloadId()`.
- DB claims: two live envs, each query run on both where the claim is cross-env.
