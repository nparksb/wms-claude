---
name: wms2-boxed-long-id-comparison-works-under-128
description: `entity.getTypeId() != other.getId()` on boxed Longs compares REFERENCES — it works only because reference-table ids are 0..6, and inverts past 127
metadata:
  type: reference
---

`ReceivingService.resolvePalletByLabelId` shipped for years with

```java
if (unitLoad.getTypeId() != unitloadType.getId())   // Long != Long
```

`Unitload.getTypeId()` returns `Long`; `AbstractBaseEntity.getId()` returns `Long`. `!=` on two
boxed values compares **references**, and `Long.valueOf` caches only −128…127. So this works purely
because `unitload_type` is a 7-row reference table — measured ids `0 Default, 1 PickLocation,
2 Tote, 3 Package, 4 Case, 5 Pallet, 6 Cart`, identical on all six environments. **Past 127 the two
boxes are distinct objects and the comparison inverts**: every genuine pallet is rejected as the
wrong type and `/setPallet` stops working. Demonstrated at id 200.

Fixed on SBDEV-3004 (extracted to `ReceivingService.requirePalletType`, `.equals()` called on the
**type** side since a PK is never null); the other three members of that guard family
(`MobilePalletizingService:257`/`:350`, `ParcelMonitorViewService:154`) always used `.equals()`.

**CORRECTED 2026-08-25 — the "sweep confirmed none remain" claim in the earlier version of this note
was WRONG.** It covered only *type* comparisons. A wider sweep of `origin/develop`
(`git grep -nE "get[A-Za-z]*Id\(\) (!=|==) [a-zA-Z_].*get[A-Za-z]*Id\(\)" -- src/main`) finds four
live boxed-`Long` identity comparisons. **Check the declared types of BOTH operands before calling any
of them a bug** — `MobileTransferOrderService:348` looks identical and is *fine*, because
`TransferOrderPositionPickSourceDto.getStockUnitId()` returns a primitive `long`, which unboxes the
other side.

| Site | Operands | Status |
|---|---|---|
| `UnitloadBusinessService:283` `unitload.getId() == parent.getCarrierunitloadId()` | `Long` vs `Long`, two *different* rows | **REAL and unmasked.** Measured on `dev_wh01_om1`: **0 of 754,805** unitload ids are ≤127. The `CARRIER_IS_ITS_OWN_CARRIER` cycle guard is therefore unreachable in every real case — and the enclosing `while (parent != null)` carrier walk has no visit set and no iteration bound, so a cycle this dead guard fails to prevent makes a later walk spin forever inside a transaction. `:275`'s trivial A→A self-check still uses `.equals()` and holds. |
| `UnitloadBusinessService:271` `getCarrierunitloadId() != destinationUnitload.getCarrierunitloadId()` | `Long` vs `Long` | Real, but only drives a `LOG.warn` — cosmetic (spurious warnings). |
| `StockunitService:229` `itemdataService.getById(fla.getItemdataId()).getId() != stockUnitItemData.getId()` | `Long` vs `Long` | **Latent, MASKED — and the mask is stronger than first recorded.** Re-checked 2026-08-28 (SBDEV-2996 review): the earlier note credited Hibernate's first-level cache and listed "cache layer" as a mask-*breaker*. Both wrong. `ItemdataService.getById` is **`@Cacheable("itemdata", key=<tenant>+':id:'+#id)`** (`ItemdataService:46`), and BOTH operands reach it — the other side is `stockUnitItemData = itemdataService.getById(stockUnit.getItemdataId())` at `:217`. Equal ids ⇒ identical cache key ⇒ Caffeine returns the *same instance*, so `!=` is false. That is a **stronger** guarantee than the persistence context, because it survives EM boundaries. Residual risk is narrow: an eviction landing between `:217` and `:229` yields two equal-valued distinct boxes and a spurious `"Flow bin has different SKU"`. `ItemdataService` declares no `@CacheEvict` itself. Still **not** confirmed as SBDEV-2924's root cause. |
| `FixLocationAssignmentService:252` `unitLoad.getStoragelocationId() == locationService.getNirvana().getId()` | `Long` vs `Long` | **Latent, MASKED by a small id.** Nirwana's location id is **0** on both `wh01_om1` (v1 prd) and `dev_wh01_om1`, inside the `Long` cache. Breaks only if Nirwana's id ever exceeds 127. |

The lesson generalises: a boxed-`Long` `==`/`!=` can be masked by *either* the −128…127 cache *or* by
Hibernate first-level-cache instance identity. Both masks are accidental, so fix the comparison; but
do not report one as a live defect without establishing which mask (if any) is holding.

**Why no test caught it, and the trap to avoid when writing one:** the happy-path test built its
fixture from `palletType.getId()` — literally the same object — so `!=` was false by *identity*,
not by value; the negative test used 999 vs 1, distinct values *and* distinct boxes, so it threw
the right answer by luck. A correct test needs **equal values in deliberately distinct boxes**
(`Long.valueOf(200L)` twice) plus an `isNotSameAs` assertion, or it silently stops testing anything.

Note CLAUDE.md's "entity comparison by ID, not `.equals()`" is about comparing *entities*. For the
**ids themselves** `.equals()` is required.

**Recurred 2026-09-17 (SBDEV-2620), in the TEST direction.** A new guard used `Objects.equals` correctly,
but every same-pallet fixture used ids `9L`/`42L`/`1L` — all inside the cache — so a deliberate
`Objects.equals` → `==` mutant **SURVIVED**: `9L == 9L` is true by cache identity. PIT scoped to the class
still reported the conditional killed, because PIT negates the branch rather than swapping the operator.
A code-review lane caught it. Fixture ids moved above 66,000 and the mutant then died with an attributable
message. **So: mutation-checking a boxed-`Long` comparison is vacuous unless the fixture ids exceed 127.**
